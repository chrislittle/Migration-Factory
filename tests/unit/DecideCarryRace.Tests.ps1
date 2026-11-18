#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# DECIDE-CARRY-RACE-1: a decision could write over a wave approval given in the
# same moment.
#
# When an approver accepts a decision, Invoke-VmfDecisionCarryForward reads the
# wave's acceptance, the wave's approval and the plan sign-off, writes the
# decision on each, and writes it back. The write was an ordinary write, so a
# record somebody wrote between the read and the write was lost: the carry put
# the older record, with the older name, time and note, over it.
#
# Now each record is written only if it still holds the text that was read
# (PLANVER-2 versions, written with Write-VmfTextDocumentIfVersion: If-Match on
# blob storage, the lock file on the file backend). A record that changed is
# left as it is, and the carry says so in its result and in the run history.
# The decision itself stays saved; the engine's own gates then judge whatever
# record is stored against the plan as stored, so the wave starts only with a
# record that covers the decision.
#
# The race tests put the other writer in the window through the real writers
# (Approve-VmfWave, Confirm-VmfWaveOptions, Approve-VmfPlan) and drive the
# decision through Resolve-VmfDecision.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:DcrSku([string]$Name) {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }) }
    }
    function Global:DcrId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:DcrVm([string]$Name, [string]$Environment) {
        [ordered]@{
            vmId = (DcrId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{ environment = $Environment }; blockers = @(); prepNeeded = @()
        }
    }
    function Global:DcrPlanPath($mig) { Join-Path $mig 'plan.json' }
    function Global:DcrPlanText($mig) { [System.IO.File]::ReadAllText((DcrPlanPath $mig)) }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }

    # Scan, review, targets, plan by a tag: wave-1 holds app-01 and app-02
    # (dev), wave-2 holds web-01 and web-02 (prod). Every wave's settings
    # accepted and the run acknowledged.
    function Global:DcrPlanned {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dcr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vms = @((DcrVm 'app-01' 'dev'), (DcrVm 'app-02' 'dev'), (DcrVm 'web-01' 'prod'), (DcrVm 'web-02' 'prod'))
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
            Confirm-VmfWaveOptions -RunPath $mig -PlanPath (DcrPlanPath $mig) -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        }
        @{ Scan = $rp; Mig = $mig }
    }
    function Global:DcrApprove($mig, [string]$Wave, [string]$Note = 'read and approved') {
        Approve-VmfWave -RunPath $mig -PlanPath (DcrPlanPath $mig) -Wave $Wave -Note $Note `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
    }
    function Global:DcrGate($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            Test-VmfWaveApproval -RunPath $m -PlanPath (Join-Path $m 'plan.json') -Wave $w
        }
    }
    function Global:DcrStartGate($mig, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; w = $Wave } {
            $pp = Join-Path $m 'plan.json'
            Get-VmfWaveStartGate -RunPath $m -PlanPath $pp -Plan (Read-VmfJsonDocument -Path $pp) -Wave $w
        }
    }
    # ACCEPT-NAME-1: the acceptance file name has a code from the wave.
    function Global:DcrAccRel([string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ w = $Wave } { Get-VmfWaveOptionsAcceptancePath -Wave $w }
    }
    function Global:DcrDoc($mig, [string]$RelPath) {
        $file = Join-Path $mig ($RelPath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (Test-Path $file) { [System.IO.File]::ReadAllText($file) | ConvertFrom-Json -Depth 12 } else { $null }
    }
    function Global:DcrState($mig, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; id = $VmId } { [string](Read-VmfStateDoc -RunPath $m -VmId $id).state }
    }
    function Global:DcrLastHistory($mig, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; id = $VmId } { [string]@((Read-VmfStateDoc -RunPath $m -VmId $id).history)[-1].detail }
    }
    function Global:DcrWarnLines($mig) {
        @(Get-Content (Join-Path $mig 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.step -eq 'decision' -and $_.outcome -eq 'warn' } | ForEach-Object { [string]$_.detail })
    }
    function Global:DcrPark($mig, [string]$VmId) {
        InModuleScope VmMigrationFactory -Parameters @{ m = $mig; vm = $VmId } {
            New-VmfStateDoc -RunPath $m -RunId 'r' -VmId $vm -Wave 'wave-1' | Out-Null
            Add-VmfStateTransition -RunPath $m -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
        }
    }
    # An approver accepts the decision the machine waits for: the decision that
    # carries the wave's records.
    function Global:DcrDecide($mig, [string]$VmId) {
        Resolve-VmfDecision -RunPath $mig -PlanPath (DcrPlanPath $mig) -VmId $VmId -PolicyOverride @{ onDDataFound = 'proceed' } `
            -Note 'decided' -ResolvedBy 'lead@example.com' -ResolvedRoles @('Vmf.Approver')
    }
}
AfterAll {
    foreach ($fn in 'DcrSku', 'DcrId', 'DcrVm', 'DcrPlanPath', 'DcrPlanText', 'DcrPlanned', 'DcrApprove', 'DcrGate', 'DcrStartGate',
                    'DcrDoc', 'DcrAccRel', 'DcrState', 'DcrLastHistory', 'DcrWarnLines', 'DcrPark', 'DcrDecide') {
        Remove-Item "function:\$fn" -ErrorAction SilentlyContinue
    }
}

Describe 'DECIDE-CARRY-RACE-1: a record written while a decision is saved is never written over' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((DcrSku 'Standard_D2ds_v6'), (DcrSku 'Standard_D2s_v6')) }
        $script:run = DcrPlanned
        $script:mig = $script:run.Mig
        DcrApprove $script:mig 'wave-1'
        DcrApprove $script:mig 'wave-2'
        $script:parked = (DcrId 'app-01')
        DcrPark $script:mig $script:parked
        $script:injected = $false
        # Which record's window the other writer acts in, and what it does.
        $script:isTarget = { param($Document) $false }
        $script:inWindow = { }
        # The carry reads a record, writes the decision on it (Add-VmfAmendment),
        # and writes it back. The other writer acts between the read and the
        # write, in the first call for the record under test.
        Mock -ModuleName VmMigrationFactory Add-VmfAmendment {
            if (-not $script:injected -and (& $script:isTarget $Document)) {
                $script:injected = $true
                & $script:inWindow
            }
            $list = @(if ($Document.PSObject.Properties['amendments']) { @($Document.amendments) }) + @([pscustomobject]$Amendment)
            $Document | Add-Member -NotePropertyName amendments -NotePropertyValue $list -Force
            $Document.schemaVersion = $Version
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an approver approves the wave between the read and the write: the new approval stays as written, and the machine is tried again' {
        $script:isTarget = { param($Document) [bool]$Document.PSObject.Properties['waveVersion'] }
        $script:inWindow = { DcrApprove $script:mig 'wave-1' 'approved again after the decision' }
        $r = DcrDecide $script:mig $script:parked
        $script:injected | Should -BeTrue -Because 'the approver acted between the read and the write'
        $doc = DcrDoc $script:mig 'approvals/wave-1.json'
        $doc.note | Should -BeExactly 'approved again after the decision' -Because 'the carry never writes the older approval over a new one'
        $doc.PSObject.Properties['amendments'] | Should -BeNullOrEmpty -Because 'the carry left the new approval as it is'
        (DcrGate $script:mig 'wave-1').Pass | Should -BeTrue -Because 'the new approval signs the wave with the decision in it'
        $r.NewState | Should -Be 'PRECHECK'
        @($r.CarryLeft) | Should -Be @('approval')
        $warn = @(DcrWarnLines $script:mig)
        $warn.Count | Should -Be 1
        $warn[0] | Should -BeLike 'The approval of wave wave-1 changed while the product saved this decision.*kept it as it is*'
        # The machine panel shows the machine's history in full: it says so too.
        (DcrLastHistory $script:mig $script:parked) | Should -BeLike '*Somebody changed the approval of wave wave-1 while the product saved this decision. The product kept that record as it is.*'
    }

    It 'an operator accepts the wave settings between the read and the write: the new acceptance stays as written' {
        $script:isTarget = { param($Document) [bool]$Document.PSObject.Properties['optionsHash'] }
        $script:inWindow = {
            Confirm-VmfWaveOptions -RunPath $script:mig -PlanPath (DcrPlanPath $script:mig) -Wave 'wave-1' -AcceptedBy 'second-operator@example.com' -Confirm:$false | Out-Null
        }
        $r = DcrDecide $script:mig $script:parked
        $script:injected | Should -BeTrue
        $acc = DcrDoc $script:mig (DcrAccRel 'wave-1')
        $acc.acceptedBy | Should -BeExactly 'second-operator@example.com'
        $acc.PSObject.Properties['amendments'] | Should -BeNullOrEmpty
        DcrStartGate $script:mig 'wave-1' | Should -BeNullOrEmpty -Because 'the new acceptance covers the wave with the decision in it'
        $r.NewState | Should -Be 'PRECHECK'
        @($r.CarryLeft) | Should -Be @('acceptance')
        @(DcrWarnLines $script:mig)[0] | Should -BeLike 'The accepted settings of wave wave-1 changed while the product saved this decision.*'
        # The approval, which nobody touched, is still carried.
        @((DcrDoc $script:mig 'approvals/wave-1.json').amendments).Count | Should -Be 1
    }

    It 'an approval that does not cover the decision lands in the window: it is left, then removed as out of date, and the wave cannot start' {
        $script:isTarget = { param($Document) [bool]$Document.PSObject.Properties['waveVersion'] }
        $script:inWindow = {
            $file = Join-Path $script:mig 'approvals' 'wave-1.json'
            $other = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
            $other.waveVersion = 'f' * 64
            $other.note = 'an approval of another wave-1'
            [System.IO.File]::WriteAllText($file, ($other | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        }
        { DcrDecide $script:mig $script:parked } | Should -Throw '400: The change (onDDataFound=proceed) is saved, but wave wave-1 cannot start now*'
        $script:injected | Should -BeTrue
        DcrDoc $script:mig 'approvals/wave-1.json' | Should -BeNullOrEmpty -Because 'the out-of-date approval is removed, never moved onto the decision'
        (DcrGate $script:mig 'wave-1').Pass | Should -BeFalse
        DcrState $script:mig $script:parked | Should -Be 'NEEDS_DECISION' -Because 'the machine is not tried again'
        $entry = @((DcrPlanText $script:mig | ConvertFrom-Json -Depth 30).entries | Where-Object { $_.vmId -eq $script:parked })[0]
        [string]$entry.policy.onDDataFound | Should -Be 'proceed' -Because 'the decision itself is saved'
        @(DcrWarnLines $script:mig) | Where-Object { $_ -like 'The approval of wave wave-1 changed*' } | Should -Not -BeNullOrEmpty
    }

    It 'the approval is removed in the window: the carry does not write it back, and the wave cannot start' {
        $script:isTarget = { param($Document) [bool]$Document.PSObject.Properties['waveVersion'] }
        $script:inWindow = { Remove-Item (Join-Path $script:mig 'approvals' 'wave-1.json') -Force }
        { DcrDecide $script:mig $script:parked } | Should -Throw '400:*cannot start now*'
        $script:injected | Should -BeTrue
        DcrDoc $script:mig 'approvals/wave-1.json' | Should -BeNullOrEmpty -Because 'a removed approval is never written back by a carry'
        DcrState $script:mig $script:parked | Should -Be 'NEEDS_DECISION'
    }

    It 'with nobody in the window, every record is carried and nothing is said about a record left' {
        $r = DcrDecide $script:mig $script:parked
        $r.NewState | Should -Be 'PRECHECK'
        @($r.CarryLeft) | Should -BeNullOrEmpty
        @(DcrWarnLines $script:mig) | Should -BeNullOrEmpty
        (DcrLastHistory $script:mig $script:parked) | Should -Not -BeLike '*Somebody changed*'
        $doc = DcrDoc $script:mig 'approvals/wave-1.json'
        $doc.note | Should -BeExactly 'read and approved'
        @($doc.amendments).Count | Should -Be 1
        @((DcrDoc $script:mig (DcrAccRel 'wave-1')).amendments).Count | Should -Be 1
        (DcrGate $script:mig 'wave-1').Pass | Should -BeTrue
    }
}

Describe 'DECIDE-CARRY-RACE-1: a plan sign-off given while a decision is saved is never written over' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((DcrSku 'Standard_D2ds_v6'), (DcrSku 'Standard_D2s_v6')) }
        $script:run = DcrPlanned
        $script:mig = $script:run.Mig
        Approve-VmfPlan -RunPath $script:mig -PlanPath (DcrPlanPath $script:mig) -Note 'every wave read' -OnBehalfOf $script:who | Out-Null
        $script:parked = (DcrId 'app-01')
        DcrPark $script:mig $script:parked
        $script:injected = $false
        $script:isTarget = { param($Document) [bool]$Document.PSObject.Properties['waves'] }
        $script:inWindow = { Approve-VmfPlan -RunPath $script:mig -PlanPath (DcrPlanPath $script:mig) -Note 'signed off again after the decision' -OnBehalfOf $script:who | Out-Null }
        Mock -ModuleName VmMigrationFactory Add-VmfAmendment {
            if (-not $script:injected -and (& $script:isTarget $Document)) {
                $script:injected = $true
                & $script:inWindow
            }
            $list = @(if ($Document.PSObject.Properties['amendments']) { @($Document.amendments) }) + @([pscustomobject]$Amendment)
            $Document | Add-Member -NotePropertyName amendments -NotePropertyValue $list -Force
            $Document.schemaVersion = $Version
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an approver signs off the plan between the read and the write: the new sign-off stays as written' {
        $r = DcrDecide $script:mig $script:parked
        $script:injected | Should -BeTrue
        $pa = DcrDoc $script:mig 'plan-approval.json'
        $pa.note | Should -BeExactly 'signed off again after the decision'
        $pa.PSObject.Properties['amendments'] | Should -BeNullOrEmpty
        $pa.planHash | Should -BeExactly (InModuleScope VmMigrationFactory -Parameters @{ t = (DcrPlanText $script:mig) } { Get-VmfDocumentVersion -Text $t })
        $r.NewState | Should -Be 'PRECHECK'
        @($r.CarryLeft) | Should -Be @('signOff')
        @(DcrWarnLines $script:mig)[0] | Should -BeLike 'The plan sign-off changed while the product saved this decision.*'
        (DcrLastHistory $script:mig $script:parked) | Should -BeLike '*Somebody changed the plan sign-off while the product saved this decision.*'
    }

    It 'the wave approval changes in the window: it is left and removed, and the sign-off that records the decision covers the wave' {
        # The v3 sign-off moves with an approver's decision (WAVE-APPROVE-1),
        # whatever happened to the wave's approval file: the approver's
        # acceptance of this one decision is itself its approval, and the
        # sign-off names it in an amendment.
        $script:isTarget = { param($Document) [bool]$Document.PSObject.Properties['waveVersion'] }
        $script:inWindow = {
            $file = Join-Path $script:mig 'approvals' 'wave-1.json'
            $other = [System.IO.File]::ReadAllText($file) | ConvertFrom-Json
            $other.waveVersion = 'f' * 64
            [System.IO.File]::WriteAllText($file, ($other | ConvertTo-Json -Depth 8), [System.Text.UTF8Encoding]::new($false))
        }
        $r = DcrDecide $script:mig $script:parked
        $script:injected | Should -BeTrue
        @($r.CarryLeft) | Should -Be @('approval')
        @($r.ApprovalsCleared) | Should -Be @('wave-1') -Because 'the approval left is out of date, so it is removed'
        @($r.ApprovalsToRenew) | Should -BeNullOrEmpty -Because 'the carried sign-off covers the wave'
        $pa = DcrDoc $script:mig 'plan-approval.json'
        @($pa.amendments)[-1].by | Should -Be 'lead@example.com'
        @($pa.amendments)[-1].change | Should -Be 'onDDataFound=proceed'
        (DcrGate $script:mig 'wave-1').Pass | Should -BeTrue
        $r.NewState | Should -Be 'PRECHECK'
    }
}

Describe 'DECIDE-CARRY-RACE-1: Write-VmfStoreTextIfVersion writes a store document only over the text that was read' {
    BeforeAll {
        $script:v1 = InModuleScope VmMigrationFactory { Get-VmfDocumentVersion -Text '{"a":1}' }
    }

    Context 'on the file backend' {
        BeforeEach {
            $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dcr-w-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            New-Item -ItemType Directory -Path (Join-Path $script:rp 'approvals') -Force | Out-Null
            $script:file = Join-Path $script:rp 'approvals' 'w1.json'
            [System.IO.File]::WriteAllText($script:file, '{"a":1}', [System.Text.UTF8Encoding]::new($false))
        }
        AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

        It 'writes the document when it still holds the version read' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath $rp -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeTrue
            [System.IO.File]::ReadAllText($script:file) | Should -BeExactly '{"a":"ours"}'
            Test-Path "$($script:file).lock" | Should -BeFalse -Because 'the write takes the lock and gives it back'
        }

        It 'leaves a document somebody wrote after the read as it is' {
            [System.IO.File]::WriteAllText($script:file, '{"a":"theirs"}', [System.Text.UTF8Encoding]::new($false))
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath $rp -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeFalse
            [System.IO.File]::ReadAllText($script:file) | Should -BeExactly '{"a":"theirs"}'
        }

        It 'does not write a document that is gone' {
            Remove-Item $script:file -Force
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath $rp -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeFalse
            Test-Path $script:file | Should -BeFalse
        }
    }

    Context 'on blob storage' {
        BeforeEach {
            $script:calls = [System.Collections.Generic.List[object]]::new()
            $script:stored = '{"a":1}'
            $script:getCode = 200
            $script:putCode = 201
            Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
                $script:calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers; Body = $Body })
                if ($Method -eq 'GET') {
                    return [pscustomobject]@{ StatusCode = $script:getCode; Content = $script:stored; Headers = @{ ETag = @('"0x8D1"') } }
                }
                [pscustomobject]@{ StatusCode = $script:putCode; Content = '' }
            }
        }

        It 'the write carries If-Match with the ETag of the text it checked' {
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeTrue
            $put = @($script:calls | Where-Object Method -eq 'PUT')
            $put.Count | Should -Be 1
            $put[0].Headers['If-Match'] | Should -Be '"0x8D1"'
            $put[0].Uri | Should -Match 'acct\.blob\.core\.windows\.net/cont/run-1/approvals/w1\.json$'
            $put[0].Body | Should -BeExactly '{"a":"ours"}'
        }

        It 'a version that differs is left, and no write is sent' {
            $script:stored = '{"a":"theirs"}'
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeFalse
            @($script:calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
        }

        It 'a write between the check and the write fails the If-Match: left' {
            $script:putCode = 412
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeFalse
        }

        It 'a document that is gone is not written' {
            $script:getCode = 404
            InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } | Should -BeFalse
            @($script:calls | Where-Object Method -eq 'PUT').Count | Should -Be 0
        }

        It 'a store that does not answer is an error, not a record left' {
            $script:getCode = 500
            { InModuleScope VmMigrationFactory -Parameters @{ v = $script:v1 } {
                Write-VmfStoreTextIfVersion -RunPath 'azblob://acct/cont/run-1' -RelPath 'approvals/w1.json' -Content '{"a":"ours"}' -ExpectedVersion $v
            } } | Should -Throw '*HTTP 500*'
        }
    }
}

Describe 'DECIDE-CARRY-RACE-1: the carry on blob storage' {
    # A store in memory that answers as blob storage does: an ETag per text,
    # and a PUT with If-Match refused (412) when the ETag differs.
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((DcrSku 'Standard_D2ds_v6'), (DcrSku 'Standard_D2s_v6')) }
        $script:run = DcrPlanned
        $script:mig = $script:run.Mig
        DcrApprove $script:mig 'wave-1'
        $planText = DcrPlanText $script:mig
        $plan = $planText | ConvertFrom-Json -Depth 30
        $entry = @($plan.entries | Where-Object { $_.wave -eq 'wave-1' })[0]
        $entry.policy | Add-Member -NotePropertyName onDDataFound -NotePropertyValue 'proceed' -Force
        $script:beforeText = $planText
        $script:afterText = $plan | ConvertTo-Json -Depth 24
        $script:vm = [string]$entry.vmId
        $script:base = 'https://acct.blob.core.windows.net/cont/run-1'
        $script:blobs = @{}
        $script:etag = 0
        $script:put = { param([string]$Uri, [string]$Text) $script:etag++; $script:blobs[$Uri] = @{ Content = $Text; ETag = "`"0x$($script:etag)`"" } }
        & $script:put "$($script:base)/approvals/wave-1.json" ([System.IO.File]::ReadAllText((Join-Path $script:mig 'approvals' 'wave-1.json')))
        $script:approverText = '{"schemaVersion":2,"wave":"wave-1","note":"approved again after the decision","waveVersion":"x"}'
        $script:when = ''
        $script:calls = [System.Collections.Generic.List[object]]::new()
        Mock -ModuleName VmMigrationFactory Invoke-VmfStorageRequest {
            $script:calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Headers = $Headers })
            $isApproval = $Uri -like '*/approvals/wave-1.json'
            $gets = @($script:calls | Where-Object { $_.Method -eq 'GET' -and $_.Uri -like '*/approvals/wave-1.json' }).Count
            # The approver writes after the carry's read (before the write's own
            # check), or after that check (before the PUT).
            if ($isApproval -and $script:when -eq 'beforeCheck' -and $Method -eq 'GET' -and $gets -eq 2) { & $script:put $Uri $script:approverText }
            if ($isApproval -and $script:when -eq 'beforePut' -and $Method -eq 'PUT') { & $script:put $Uri $script:approverText }
            $blob = $script:blobs[$Uri]
            if ($Method -eq 'GET') {
                if (-not $blob) { return [pscustomobject]@{ StatusCode = 404; Content = ''; Headers = @{} } }
                return [pscustomobject]@{ StatusCode = 200; Content = $blob.Content; Headers = @{ ETag = @($blob.ETag) } }
            }
            if ($Method -eq 'PUT') {
                $match = if ($Headers) { $Headers['If-Match'] } else { $null }
                if ($match -and (-not $blob -or $blob.ETag -ne $match)) { return [pscustomobject]@{ StatusCode = 412; Content = '' } }
                & $script:put $Uri ([string]$Body)
                return [pscustomobject]@{ StatusCode = 201; Content = '' }
            }
            [pscustomobject]@{ StatusCode = 404; Content = '' }
        }
        $script:lines = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { $script:lines.Add("$Outcome|$Detail") }
        $script:carry = {
            InModuleScope VmMigrationFactory -Parameters @{ bt = $script:beforeText; at = $script:afterText; vm = $script:vm } {
                $before = Get-VmfDecisionSnapshot -Text $bt -Wave 'wave-1'
                Invoke-VmfDecisionCarryForward -RunPath 'azblob://acct/cont/run-1' -PlanPath 'azblob://acct/cont/run-1/plan.json' -Before $before -AfterText $at `
                    -VmId $vm -Change 'onDDataFound=proceed' -ResolvedBy 'lead@example.com' -CarryWaveApproval
            }
        }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'with nobody in the window, the approval is carried with If-Match on the text read' {
        $r = & $script:carry
        $r.Approval | Should -BeTrue
        @($r.Left) | Should -BeNullOrEmpty
        $put = @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -like '*/approvals/wave-1.json' })
        $put.Count | Should -Be 1
        $put[0].Headers['If-Match'] | Should -Be '"0x1"'
        @(($script:blobs["$($script:base)/approvals/wave-1.json"].Content | ConvertFrom-Json).amendments).Count | Should -Be 1
    }

    It 'the approver writes after the carry read the approval: no write is sent, and the approver''s approval stays' {
        $script:when = 'beforeCheck'
        $r = & $script:carry
        $r.Approval | Should -BeFalse
        @($r.Left) | Should -Be @('approval')
        @($script:calls | Where-Object { $_.Method -eq 'PUT' -and $_.Uri -like '*/approvals/wave-1.json' }).Count | Should -Be 0
        $script:blobs["$($script:base)/approvals/wave-1.json"].Content | Should -BeExactly $script:approverText
        @($script:lines | Where-Object { $_ -like 'warn|The approval of wave wave-1 changed*' }).Count | Should -Be 1
    }

    It 'the approver writes after the write''s own check: the If-Match refuses it, and the approver''s approval stays' {
        $script:when = 'beforePut'
        $r = & $script:carry
        $r.Approval | Should -BeFalse
        @($r.Left) | Should -Be @('approval')
        $script:blobs["$($script:base)/approvals/wave-1.json"].Content | Should -BeExactly $script:approverText
    }
}
