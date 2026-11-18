#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# DECIDE-CARRY-KILL-1: a stop between a decision's plan write and its carry
# asked again for the wave's acceptance and approval.
#
# Resolve-VmfDecision writes the decision into the plan, then carries the
# wave's accepted settings, its approval and the plan sign-off onto the plan it
# wrote (Invoke-VmfDecisionCarryForward). A process that stopped between the
# two left the plan with the decision and the records signing the plan from
# before it. That was safe - the start gate refused the wave - but the
# decision made again was refused by that gate, and a carry made again found
# nothing to move. The person had to accept the wave's settings and approve the
# wave again: the approver's record of this exact change was lost.
#
# Now the decision writes a note of the carry it is about to do BEFORE it
# writes the plan (decision-carry/<machine>.json, schemas/decision-carry), and
# removes it after the carry. The next decision call for the machine finishes
# a carry the note names - but only while the plan is still the exact text the
# stopped decision wrote (PLANVER-2 versions). A plan anybody changed since is
# never signed by it.
#
# Rule 4 kill-resume: each test stops the process at one point (a throw from a
# mock of the next step), then makes the decision again, and shows where the
# wave and the machine end up.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:DckSku([string]$Name) {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }) }
    }
    function Global:DckId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:DckVm([string]$Name, [string]$Environment) {
        [ordered]@{
            vmId = (DckId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{ environment = $Environment }; blockers = @(); prepNeeded = @()
        }
    }
    function Global:DckPlanPath($mig) { Join-Path $mig 'plan.json' }
    function Global:DckPlanText($mig) { [System.IO.File]::ReadAllText((DckPlanPath $mig)) }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }

    # Scan, review, targets, plan by a tag: wave-1 holds app-01 and app-02,
    # wave-2 holds web-01 and web-02. Every wave's settings accepted and the
    # run acknowledged.
    function Global:DckPlanned {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dck-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vms = @((DckVm 'app-01' 'dev'), (DckVm 'app-02' 'dev'), (DckVm 'web-01' 'prod'), (DckVm 'web-02' 'prod'))
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-10-01T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = $vms }
        InModuleScope VmMigrationFactory -Parameters @{ r = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        $who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf $who | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json'))
        }
        Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($vms | ForEach-Object { @{ vmId = $_.vmId; option = 'v6' } }) -OnBehalfOf $who | Out-Null
        $mig = "$rp-migration"
        New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath $mig -WaveStrategy 'tags' -AppGroupTag 'environment' -RequireTargets | Out-Null
        Confirm-VmfRunAcknowledgement -RunPath $mig -AcknowledgedBy 'operator@example.com' -Confirm:$false | Out-Null
        foreach ($w in 'wave-1', 'wave-2') {
            Confirm-VmfWaveOptions -RunPath $mig -PlanPath (DckPlanPath $mig) -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        }
        @{ Scan = $rp; Mig = $mig }
    }
    function Global:DckApprove($mig, [string]$Wave) {
        Approve-VmfWave -RunPath $mig -PlanPath (DckPlanPath $mig) -Wave $Wave -Note 'read and approved' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
    }
    function Global:DckGate($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            Test-VmfWaveApproval -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Wave $w
        }
    }
    function Global:DckStartGate($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            $pp = Join-Path $m 'plan.json'
            Get-VmfWaveStartGate -RunPath $m -PlanPath $pp -Plan (Read-VmfJsonDocument -Path $pp) -Wave $w
        }
    }
    function Global:DckAccRel([string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ w = $Wave } { Get-VmfWaveOptionsAcceptancePath -Wave $w }
    }
    function Global:DckDoc($mig, [string]$RelPath) {
        $file = Join-Path $mig ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path $file) { [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -Depth 12 } else { $null }
    }
    # The note of the carry a decision is about to do, as files in the store.
    function Global:DckNotes($mig) {
        @(Get-ChildItem (Join-Path $mig 'decision-carry') -Filter '*.json' -ErrorAction SilentlyContinue)
    }
    function Global:DckState($mig, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; id = $VmId } { [string](Read-VmfStateDoc -RunPath $m -VmId $id).state }
    }
    function Global:DckLines($mig, [string]$Outcome) {
        @(Get-Content (Join-Path $mig 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.step -eq 'decision' -and $_.outcome -eq $Outcome } | ForEach-Object { [string]$_.detail })
    }
    function Global:DckPark($mig, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; vm = $VmId } {
            New-VmfStateDoc -RunPath $m -RunId 'r' -VmId $vm -Wave 'wave-1' | Out-Null
            Add-VmfStateTransition -RunPath $m -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
        }
    }
    function Global:DckDecide($mig, [string]$VmId, [string]$By = 'lead@example.com', [string[]]$Roles = @('Vmf.Approver')) {
        Resolve-VmfDecision -RunPath $mig -PlanPath (DckPlanPath $mig) -VmId $VmId -PolicyOverride @{ onDDataFound = 'proceed' } `
            -Note 'decided' -ResolvedBy $By -ResolvedRoles $Roles
    }
    function Global:DckEntry($mig, [string]$VmId) {
        @((DckPlanText $mig | ConvertFrom-Json -Depth 30).entries | Where-Object { $_.vmId -eq $VmId })[0]
    }
}
AfterAll {
    foreach ($fn in 'DckSku', 'DckId', 'DckVm', 'DckPlanPath', 'DckPlanText', 'DckPlanned', 'DckApprove', 'DckGate', 'DckStartGate',
                    'DckAccRel', 'DckDoc', 'DckNotes', 'DckState', 'DckLines', 'DckPark', 'DckDecide', 'DckEntry') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'DECIDE-CARRY-KILL-1: a stop between the plan write and the carry' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((DckSku 'Standard_D2ds_v6'), (DckSku 'Standard_D2s_v6')) }
        $script:run = DckPlanned
        $script:mig = $script:run.Mig
        DckApprove $script:mig 'wave-1'
        DckApprove $script:mig 'wave-2'
        $script:parked = (DckId 'app-01')
        DckPark $script:mig $script:parked
        $script:accBefore = (DckDoc $script:mig (DckAccRel 'wave-1')).optionsHash

        # Where the process stops. A mock that matches throws, as a process
        # that ends there would leave the store; one that does not match runs
        # the real step.
        $script:stopAtCarry = $false
        $script:stopAtPlanWrite = $false
        $script:stopAtNoteRemove = $false
        $script:refusePlanWrite = $false
        Mock -ModuleName VmMigrationFactory Invoke-VmfDecisionCarryForward -ParameterFilter { $script:stopAtCarry } {
            throw 'The process stopped.'
        }
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion -ParameterFilter { $script:stopAtPlanWrite -and $Path -like '*plan.json' } {
            throw 'The process stopped.'
        }
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion -ParameterFilter { $script:refusePlanWrite -and $Path -like '*plan.json' } {
            throw '409: Somebody changed the plan at the same time, so the product did not save this change. Load the page again, then make the change again.'
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfStoreItemIfVersion -ParameterFilter { $script:stopAtNoteRemove -and $RelPath -like 'decision-carry/*' } {
            throw 'The process stopped.'
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'a stop after the plan write: the wave cannot start and the machine waits; the decision made again finishes the carry and tries the machine again' {
        $script:stopAtCarry = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'

        # Where the stop leaves them: safe, and nothing starts.
        [string](DckEntry $script:mig $script:parked).policy.onDDataFound | Should -Be 'proceed' -Because 'the plan write landed'
        DckState $script:mig $script:parked | Should -Be 'NEEDS_DECISION'
        DckStartGate $script:mig 'wave-1' | Should -Not -BeNullOrEmpty -Because 'the records still sign the plan from before the decision'
        @(DckNotes $script:mig).Count | Should -Be 1 -Because 'the note of the carry was written before the plan'

        # The decision made again.
        $script:stopAtCarry = $false
        $r = DckDecide $script:mig $script:parked 'second-lead@example.com'
        $r.NewState | Should -Be 'PRECHECK'
        DckState $script:mig $script:parked | Should -Be 'PRECHECK'
        DckStartGate $script:mig 'wave-1' | Should -BeNullOrEmpty -Because 'the acceptance and the approval now sign the plan with the decision in it'
        (DckGate $script:mig 'wave-1').Pass | Should -BeTrue
        $ap = DckDoc $script:mig 'approvals/wave-1.json'
        $ap.note | Should -BeExactly 'read and approved' -Because 'the approval is the one the approver gave, carried, never a new one'
        @($ap.amendments).Count | Should -Be 1
        $acc = DckDoc $script:mig (DckAccRel 'wave-1')
        @($acc.amendments).Count | Should -Be 1
        $acc.optionsHash | Should -Not -Be $script:accBefore
        @(DckNotes $script:mig).Count | Should -Be 0 -Because 'a finished carry removes its note'
        @(DckLines $script:mig 'info') | Where-Object { $_ -like '*stopped before*' } | Should -Not -BeNullOrEmpty -Because 'the activity says the product finished a save that stopped'
        # The machine panel shows the machine's history in full: it says so too.
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; id = $script:parked } { [string]@((Read-VmfStateDoc -RunPath $m -VmId $id).history)[-1].detail } |
            Should -BeLike '*The product stopped before it completed the save of the decision by lead@example.com (onDDataFound=proceed). The product completed that save now.*'
    }

    It 'the finished carry names the decision that stopped: who made it and when, not the person who made it again' {
        $script:stopAtCarry = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        $note = [System.IO.File]::ReadAllText(@(DckNotes $script:mig)[0].FullName) | ConvertFrom-Json -DateKind String
        $script:stopAtCarry = $false
        DckDecide $script:mig $script:parked 'second-lead@example.com' | Out-Null
        $amend = @((DckDoc $script:mig 'approvals/wave-1.json').amendments)[0]
        $amend.by | Should -BeExactly 'lead@example.com'
        $amend.change | Should -BeExactly 'onDDataFound=proceed'
        ([string]$note.decidedUtc) | Should -Not -BeNullOrEmpty
        ([datetime]$amend.utc).ToUniversalTime() | Should -Be ([datetime]$note.decidedUtc).ToUniversalTime()
    }

    It 'a stop before the plan write: nothing changed, the decision made again saves and carries as usual, and the old note goes' {
        $text = DckPlanText $script:mig
        $script:stopAtPlanWrite = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        DckPlanText $script:mig | Should -BeExactly $text -Because 'the plan write never landed'
        @(DckNotes $script:mig).Count | Should -Be 1 -Because 'the note is written before the plan'

        $script:stopAtPlanWrite = $false
        $r = DckDecide $script:mig $script:parked
        $r.NewState | Should -Be 'PRECHECK'
        @((DckDoc $script:mig 'approvals/wave-1.json').amendments).Count | Should -Be 1
        @(DckNotes $script:mig).Count | Should -Be 0
    }

    It 'the plan changes after the stop: the carry is never finished onto that plan, and the wave asks again for its settings' {
        $script:stopAtCarry = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        # Somebody changes another machine of the wave after the stop.
        $plan = DckPlanText $script:mig | ConvertFrom-Json -Depth 30
        $other = @($plan.entries | Where-Object { $_.vmId -eq (DckId 'app-02') })[0]
        $other.policy | Add-Member -NotePropertyName onDDataFound -NotePropertyValue 'proceed' -Force
        [System.IO.File]::WriteAllText((DckPlanPath $script:mig), ($plan | ConvertTo-Json -Depth 24), [System.Text.UTF8Encoding]::new($false))

        $script:stopAtCarry = $false
        { DckDecide $script:mig $script:parked } | Should -Throw '400:*wave wave-1 cannot start*'
        $acc = DckDoc $script:mig (DckAccRel 'wave-1')
        $acc.optionsHash | Should -BeExactly $script:accBefore -Because 'a change nobody accepted is never signed by a carry'
        $acc.PSObject.Properties['amendments'] | Should -BeNullOrEmpty
        (DckDoc $script:mig 'approvals/wave-1.json').PSObject.Properties['amendments'] | Should -BeNullOrEmpty
        DckState $script:mig $script:parked | Should -Be 'NEEDS_DECISION'
        @(DckNotes $script:mig).Count | Should -Be 0 -Because 'a note that no longer matches the plan is removed'
    }

    It 'a stop after the carry and before the note is removed: the decision made again records the decision once' {
        $script:stopAtNoteRemove = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        @((DckDoc $script:mig 'approvals/wave-1.json').amendments).Count | Should -Be 1
        @(DckNotes $script:mig).Count | Should -Be 1

        $script:stopAtNoteRemove = $false
        $r = DckDecide $script:mig $script:parked
        $r.NewState | Should -Be 'PRECHECK'
        @((DckDoc $script:mig 'approvals/wave-1.json').amendments).Count | Should -Be 1 -Because 'a carry already done moves nothing'
        @((DckDoc $script:mig (DckAccRel 'wave-1')).amendments).Count | Should -Be 1
        @(DckNotes $script:mig).Count | Should -Be 0
    }

    It "an operator's decision that stopped: the decision made again by an approver carries the acceptance, never the approval" {
        $script:stopAtCarry = $true
        { DckDecide $script:mig $script:parked 'operator@example.com' @('Vmf.Operator') } | Should -Throw '*The process stopped.*'
        $script:stopAtCarry = $false
        try { DckDecide $script:mig $script:parked 'lead@example.com' @('Vmf.Approver') | Out-Null } catch { }
        @((DckDoc $script:mig (DckAccRel 'wave-1')).amendments)[0].by | Should -BeExactly 'operator@example.com'
        $ap = DckDoc $script:mig 'approvals/wave-1.json'
        if ($ap) { $ap.PSObject.Properties['amendments'] | Should -BeNullOrEmpty -Because "an operator's decision never carries the wave's approval" }
        (DckGate $script:mig 'wave-1').Pass | Should -BeFalse -Because 'the wave asks again for its approval, as after any operator decision'
    }

    It 'a plan write refused because somebody else wrote the plan: no note is left' {
        $script:refusePlanWrite = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '409:*'
        @(DckNotes $script:mig).Count | Should -Be 0
    }

    It 'a note of another version is never read: it is removed, and the wave asks again for its records' {
        $script:stopAtCarry = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        $file = @(DckNotes $script:mig)[0].FullName
        $other = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
        $other.schemaVersion = 99
        [System.IO.File]::WriteAllText($file, ($other | ConvertTo-Json -Depth 6), [System.Text.UTF8Encoding]::new($false))

        $script:stopAtCarry = $false
        { DckDecide $script:mig $script:parked } | Should -Throw '400:*wave wave-1 cannot start*'
        (DckDoc $script:mig (DckAccRel 'wave-1')).optionsHash | Should -BeExactly $script:accBefore
        @(DckNotes $script:mig).Count | Should -Be 0
    }

    It 'a record somebody writes while the stopped carry is finished stays as written, and the machine history says so' {
        $script:stopAtCarry = $true
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        $script:stopAtCarry = $false
        # Another approver approves the wave between the finishing carry's read
        # of the approval and its write.
        $script:injected = $false
        Mock -ModuleName VmMigrationFactory Add-VmfAmendment {
            if (-not $script:injected -and $Document.PSObject.Properties['waveVersion']) {
                $script:injected = $true
                Approve-VmfWave -RunPath $script:mig -PlanPath (DckPlanPath $script:mig) -Wave 'wave-1' -Note 'approved again after the stop' `
                    -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            }
            $list = @(if ($Document.PSObject.Properties['amendments']) { @($Document.amendments) }) + @([pscustomobject]$Amendment)
            $Document | Add-Member -NotePropertyName amendments -NotePropertyValue $list -Force
            $Document.schemaVersion = $Version
        }
        $r = DckDecide $script:mig $script:parked
        $script:injected | Should -BeTrue
        (DckDoc $script:mig 'approvals/wave-1.json').note | Should -BeExactly 'approved again after the stop'
        @($r.CarryLeft) | Should -Be @('approval')
        $r.NewState | Should -Be 'PRECHECK'
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:mig; id = $script:parked } { [string]@((Read-VmfStateDoc -RunPath $m -VmId $id).history)[-1].detail } |
            Should -BeLike '*Somebody changed the approval of wave wave-1 while the product saved this decision.*'
    }

    It 'with no stop, the decision leaves no note' {
        (DckDecide $script:mig $script:parked).NewState | Should -Be 'PRECHECK'
        @(DckNotes $script:mig).Count | Should -Be 0
        @(DckLines $script:mig 'info') | Where-Object { $_ -like '*stopped before*' } | Should -BeNullOrEmpty
    }
}

Describe 'DECIDE-CARRY-KILL-1: the note matches its schema' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((DckSku 'Standard_D2ds_v6'), (DckSku 'Standard_D2s_v6')) }
        $script:run = DckPlanned
        $script:mig = $script:run.Mig
        DckApprove $script:mig 'wave-1'
        $script:parked = (DckId 'app-01')
        DckPark $script:mig $script:parked
        Mock -ModuleName VmMigrationFactory Invoke-VmfDecisionCarryForward { throw 'The process stopped.' }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'the note a decision writes is valid against schemas/decision-carry.schema.json' {
        { DckDecide $script:mig $script:parked } | Should -Throw '*The process stopped.*'
        $text = [System.IO.File]::ReadAllText(@(DckNotes $script:mig)[0].FullName)
        $text | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'decision-carry.schema.json') | Should -BeTrue
        $note = $text | ConvertFrom-Json
        $note.vmId | Should -BeExactly $script:parked
        $note.wave | Should -BeExactly 'wave-1'
        $note.carryWaveApproval | Should -BeTrue
        $note.afterPlanVersion | Should -BeExactly (InModuleScope VmMigrationFactory -Parameters @{ t = (DckPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t })
    }

    It 'the sample is valid against the schema' {
        Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'decision-carry.sample.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'decision-carry.schema.json') | Should -BeTrue
    }
}
