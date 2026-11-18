#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# WAVE-AN-NAMES-1: the wave settings name every machine whose move turns
# accelerated networking on.
#
# The wave editor's acceptance and the Run it step listed "Machines that get
# accelerated networking turned on" from the plan entry's own setting,
# policy.acceleratedNetworking = ensureOn - which the planner writes only where
# the target size REQUIRES it (AN-PLAN-1). Every other move but a SCSI
# reversion has no setting, and the engine's default is ensureOn
# (Get-VmfPolicy): the move turns the primary interface on. In the lab run of
# 2026-10-11 two Bsv2 moves turned it on, and the row said None.
#
# Decided 2026-10-23: keep the words, and list every machine whose move
# turns it on. The engine works the answer out from the plan entry
# (Get-VmfPlannedAnOutcome, the advice's own rule Get-VmfAnTurnsOn) and
# records it on the entry (acceleratedNetworkingOutcome, plan-entry v20); the
# pages read the record. A Linux machine whose kernel decides (AN-KEEP-1) is
# named on its own row. The acceptance hash covers the record.

BeforeDiscovery {
    # The fixture's cases name the tests, so they are read before discovery.
    $fixtureFile = Join-Path $PSScriptRoot '..' 'fixtures' 'an-outcome.json'
    $script:discoveredCases = @((Get-Content $fixtureFile -Raw | ConvertFrom-Json -Depth 20).cases | Where-Object { $_.recorded } |
            ForEach-Object { @{ name = $_.name; case = $_ } })
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'wan'

    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'an-outcome.json') -Raw | ConvertFrom-Json -Depth 20
    $script:recorded = @($script:fixture.cases | Where-Object { $_.recorded })

    function Global:WanOutcome($Entry) {
        InModuleScope VmMigrationFactory -Parameters @{ e = $Entry } { param($e) Get-VmfPlannedAnOutcome -PlanEntry $e }
    }
    function Global:WanId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }

    # The catalogs Bsv2Notes.Tests.ps1 reads, as the SKU list the planner asks.
    function Global:WanSkus([string]$File) {
        $doc = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $File) -Raw | ConvertFrom-Json
        foreach ($s in @($doc.sizes)) {
            $caps = @(foreach ($c in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $c.Name; Value = [string]$c.Value } })
            [pscustomobject]@{
                Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
                Family = $(if ($s.PSObject.Properties['family']) { [string]$s.family } else { 'standardX' })
                Restrictions = @(); LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
            }
        }
    }
    $script:skus = @(WanSkus 'old-size-catalog-centralus.json') + @(WanSkus 'bsv2-catalog-centralus.json')

    function Global:WanVm {
        param([string]$Name, [string]$Size, [string]$Gen = 'V2', [string]$Os = 'Linux', [object]$Primary = $false, [string]$Release = '22.04')
        $sku = @($script:skus | Where-Object Name -EQ $Size)[0]
        $tempMb = [int](@($sku.Capabilities | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' })[0].Value)
        [pscustomobject]@{
            vmId = (WanId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); gen = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2019-datacenter' } else { 'custom' })
            runningOsName = $(if ($Os -eq 'Linux' -and $Release) { 'ubuntu' } else { '' })
            runningOsVersion = $(if ($Os -eq 'Linux') { $Release } else { '' })
            classification = 'ReadyAfterPrep'; blockers = @(if ($Gen -eq 'V1') { 'gen1-requires-redeploy' }); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $(if ($tempMb -gt 0) { 'scsi-temp' } else { 'diskless' }); sourceTempDisks = $(if ($tempMb -gt 0) { 1 } else { 0 })
            diskController = $(if ($Gen -eq 'V1') { '' } else { 'SCSI' }); dataDiskCount = 1; nicCount = 1
            acceleratedNicCount = $(if ($null -eq $Primary) { $null } elseif ($Primary) { 1 } else { 0 })
            primaryNicAccelerated = $Primary; platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
        }
    }
    # An approved scan, its target advice, the saved targets, and the plan.
    # A machine with no saved target is not moved (path MANUAL).
    function Global:WanPlanned([object[]]$Vms, [hashtable]$Options) {
        $rp = Join-Path $script:temp "wan-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-10-24T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ r = $rp; d = $doc } {
            param($r, $d)
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $rp } {
            param($r) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
        Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($Options.Keys | ForEach-Object { @{ vmId = (WanId $_); option = $Options[$_] } }) `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath "$rp-migration" | Out-Null
        "$rp-migration"
    }
    function Global:WanEntry([string]$Mig, [string]$Name) {
        @((Get-Content (Join-Path $Mig 'plan.json') -Raw | ConvertFrom-Json -Depth 40).entries) | Where-Object vmId -EQ (WanId $Name)
    }
}
AfterAll {
    Remove-Item 'function:\WanOutcome', 'function:\WanId', 'function:\WanSkus', 'function:\WanVm', 'function:\WanPlanned', 'function:\WanEntry' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'WAVE-AN-NAMES-1: the engine works out, from the plan entry, whether the move turns accelerated networking on' {

    It '<name>' -ForEach $script:discoveredCases {
        $got = WanOutcome $case.entry
        $got | Should -Not -BeNullOrEmpty
        if ($null -eq $case.outcome.turnsOn) { $null -eq $got.turnsOn | Should -BeTrue -Because "it is unknown: $($case.outcome.unknownWhy)" }
        else { $got.turnsOn | Should -Be $case.outcome.turnsOn }
        if ($null -eq $case.outcome.unknownWhy) { $null -eq $got.unknownWhy | Should -BeTrue }
        else { $got.unknownWhy | Should -BeExactly $case.outcome.unknownWhy }
    }

    # AN-MANA-DRIVER-RULE-1: the reason 'kernel' is gone - a missing MANA driver no longer keeps the primary off.
    It 'the fixture covers all three rows and the one reason a move decides' {
        @($script:recorded | ForEach-Object row | Sort-Object -Unique) | Should -Be @('decides', 'none', 'on')
        @($script:recorded | ForEach-Object { $_.outcome.unknownWhy } | Where-Object { $_ } | Sort-Object -Unique) | Should -Be @('nics')
    }

    It 'a machine that does not move gets no answer: <path>' -ForEach @(@{ path = 'MANUAL' }, @{ path = 'EXCLUDED' }) {
        $e = ($script:recorded[0].entry | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $e.path = $path
        WanOutcome $e | Should -BeNullOrEmpty
    }

    It 'an entry with no target size gets no answer' {
        $e = ($script:recorded[0].entry | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
        $e.target.size = $null
        WanOutcome $e | Should -BeNullOrEmpty
    }

    # OLD-VERSION-READERS-REMOVE-6: the pages read an entry with no record as
    # none (help.js anOutcomeRow), so every such case in the fixture must be one
    # the engine gives no answer for - never a move it did not record.
    It 'every fixture case with no record is an entry the engine gives no answer for' {
        $unrecorded = @($script:fixture.cases | Where-Object { -not $_.recorded })
        $unrecorded.Count | Should -BeGreaterThan 0
        foreach ($c in $unrecorded) {
            WanOutcome ($c.entry | ConvertTo-Json -Depth 10 | ConvertFrom-Json) | Should -BeNullOrEmpty -Because $c.name
            $c.row | Should -Be 'none' -Because $c.name
        }
    }

    # The record must say what the move WILL do. Each case is run through the
    # engine's own decision (Resolve-VmfAcceleratedNetworkingForMove) with
    # every reading GUEST_PREP can make of the driver, and every primary
    # setting the scan could not rule out. Where those agree, the record gives
    # that answer; where they differ, the record says the move decides.
    It 'every recorded answer is the one the engine gives for that move: <name>' -ForEach $script:discoveredCases {
        $a = $case.entry.assessment
        $primaries = if ($null -eq $a.primaryNicAccelerated) { @($false, $true) } else { @([bool]$a.primaryNicAccelerated) }
        $unlisted = [string]$a.runningOsVersion -eq '18.04'
        # AN-NAMES-KERNEL-1: a release Microsoft does not list reads as 'present'
        # with a kernel of 6.14 or later (Get-VmfManaDriverPresence), so both readings.
        $drivers = if ($a.os -eq 'Windows') { @('unknown') } elseif ($unlisted) { @('unlisted', 'present') } else { @('present', 'absent') }
        $answers = @(foreach ($on in $primaries) {
                foreach ($drv in $drivers) {
                    InModuleScope VmMigrationFactory -Parameters @{ e = $case.entry; on = $on; drv = $drv } {
                        param($e, $on, $drv)
                        $nics = @([pscustomobject]@{ id = 'nic0'; primary = $true; acceleratedNetworking = $on })
                        $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $e -CapturedNics $nics -ManaDriver $drv
                        # A stop for an approver leaves the planned setting: a move that goes on turns it on.
                        [bool]($r.OnAfter -and -not $on)
                    }
                }
            })
        $got = WanOutcome $case.entry
        if (@($answers | Sort-Object -Unique).Count -gt 1) { $null -eq $got.turnsOn | Should -BeTrue -Because 'the readings differ, so the move decides' }
        else { $got.turnsOn | Should -Be $answers[0] }
    }

    It 'with no setting of its own, the answer is the target advice''s own (Get-VmfAnTurnsOn) - one rule' {
        foreach ($case in @($script:recorded | Where-Object { -not $_.entry.policy.PSObject.Properties['acceleratedNetworking'] -and $null -ne $_.entry.assessment.primaryNicAccelerated })) {
            $advice = InModuleScope VmMigrationFactory -Parameters @{ e = $case.entry } {
                param($e)
                Get-VmfAnTurnsOn -Vm $e.assessment -TargetSize ([string]$e.target.size) -Move (Get-VmfMoveKind -PlanEntry $e) `
                    -Required (Test-VmfTargetRequiresAcceleratedNetworking -SizeName ([string]$e.target.size))
            }
            $got = WanOutcome $case.entry
            if ($null -eq $advice) { $null -eq $got.turnsOn | Should -BeTrue -Because $case.name } else { $got.turnsOn | Should -Be $advice -Because $case.name }
        }
    }
}

Describe 'WAVE-AN-NAMES-1: the plan records the answer on each machine that moves' {
    BeforeAll {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:skus }
        # The two machines of the lab run of 2026-10-11, and one left out.
        $script:mig = WanPlanned -Vms @(
            (WanVm -Name 'mx-b2s' -Size 'Standard_B2s'),
            (WanVm -Name 'mx-b2w' -Size 'Standard_B2ms' -Gen 'V1' -Os 'Windows'),
            (WanVm -Name 'mx-left' -Size 'Standard_B2s')
        ) -Options @{ 'mx-b2s' = 'v5'; 'mx-b2w' = 'v5' }
    }

    It 'THE DEFECT: the Windows Bsv2 move that turns it on says so, with no setting of its own' {
        $e = WanEntry $script:mig 'mx-b2w'
        $e.target.size | Should -Be 'Standard_B2s_v2'
        $e.policy.PSObject.Properties['acceleratedNetworking'] | Should -BeNullOrEmpty -Because 'the size does not require it, so the plan sets nothing'
        $e.acceleratedNetworkingOutcome.turnsOn | Should -BeTrue
    }

    # AN-MANA-DRIVER-RULE-1: rewritten - it said the kernel decides. Nothing keeps it off now.
    It 'the Linux Bsv2 move says it turns accelerated networking on' {
        $e = WanEntry $script:mig 'mx-b2s'
        $e.target.size | Should -Be 'Standard_B2ls_v2'
        $e.acceleratedNetworkingOutcome.turnsOn | Should -BeTrue
        $null -eq $e.acceleratedNetworkingOutcome.unknownWhy | Should -BeTrue
    }

    It 'a machine with no saved target is not in the plan' {
        WanEntry $script:mig 'mx-left' | Should -BeNullOrEmpty
    }

    It 'the entries say the plan version (v24 since REBUILD-ACCEPT-1), and match the contract' {
        $schema = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
        foreach ($name in 'mx-b2s', 'mx-b2w') {
            $e = WanEntry $script:mig $name
            $e.schemaVersion | Should -Be 37
            Test-Json -Json ($e | ConvertTo-Json -Depth 30) -SchemaFile $schema -ErrorAction Stop | Should -BeTrue
        }
    }
}

Describe 'WAVE-AN-NAMES-1: the record is written on the entry, as the plan stores it' {
    BeforeAll { $script:moving = $script:recorded[1].entry | ConvertTo-Json -Depth 10 }

    It 'a plan entry being built (a dictionary) gets the record and says the plan version' {
        $e = $script:moving | ConvertFrom-Json -AsHashtable
        $e['schemaVersion'] = 19
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Set-VmfPlannedAnOutcome -PlanEntry $e -Confirm:$false }
        $e['acceleratedNetworkingOutcome'].turnsOn | Should -BeTrue
        $e['schemaVersion'] | Should -Be 37
    }

    It 'a stored entry gets the record and says the plan version' {
        $e = $script:moving | ConvertFrom-Json
        $e | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 19
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Set-VmfPlannedAnOutcome -PlanEntry $e -Confirm:$false }
        $e.acceleratedNetworkingOutcome.turnsOn | Should -BeTrue
        $e.schemaVersion | Should -Be 37
    }

    It 'an entry that does not move loses a record it had: <kind>' -ForEach @(@{ kind = 'dictionary' }, @{ kind = 'stored' }) {
        $e = if ($kind -eq 'dictionary') { $script:moving | ConvertFrom-Json -AsHashtable } else { $script:moving | ConvertFrom-Json }
        if ($kind -eq 'dictionary') { $e['path'] = 'MANUAL'; $e['acceleratedNetworkingOutcome'] = @{ turnsOn = $true; unknownWhy = $null } }
        else { $e.path = 'MANUAL'; $e | Add-Member -NotePropertyName acceleratedNetworkingOutcome -NotePropertyValue ([pscustomobject]@{ turnsOn = $true; unknownWhy = $null }) }
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Set-VmfPlannedAnOutcome -PlanEntry $e -Confirm:$false }
        if ($kind -eq 'dictionary') { $e.Contains('acceleratedNetworkingOutcome') | Should -BeFalse }
        else { $e.PSObject.Properties['acceleratedNetworkingOutcome'] | Should -BeNullOrEmpty }
    }

    It 'the same answer again leaves the text as it was - a property moved would void an approval' {
        $e = $script:moving | ConvertFrom-Json
        $e | Add-Member -NotePropertyName acceleratedNetworkingOutcome -NotePropertyValue ([pscustomobject]@{ turnsOn = $true; unknownWhy = $null })
        $e | Add-Member -NotePropertyName decisions -NotePropertyValue @()
        $e | Add-Member -NotePropertyName schemaVersion -NotePropertyValue 20
        $before = $e | ConvertTo-Json -Depth 10
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Set-VmfPlannedAnOutcome -PlanEntry $e -Confirm:$false }
        ($e | ConvertTo-Json -Depth 10) | Should -BeExactly $before
    }

    It 'a new answer replaces the old one where it stands' {
        $e = $script:moving | ConvertFrom-Json
        $e | Add-Member -NotePropertyName acceleratedNetworkingOutcome -NotePropertyValue ([pscustomobject]@{ turnsOn = $false; unknownWhy = $null })
        $e | Add-Member -NotePropertyName decisions -NotePropertyValue @()
        InModuleScope VmMigrationFactory -Parameters @{ e = $e } { param($e) Set-VmfPlannedAnOutcome -PlanEntry $e -Confirm:$false }
        $e.acceleratedNetworkingOutcome.turnsOn | Should -BeTrue
        @($e.PSObject.Properties.Name)[-1] | Should -Be 'schemaVersion' -Because 'the record keeps its place, before decisions'
        @($e.PSObject.Properties.Name).IndexOf('acceleratedNetworkingOutcome') | Should -BeLessThan @($e.PSObject.Properties.Name).IndexOf('decisions')
    }
}

Describe 'WAVE-AN-NAMES-1: a target changed in the wave editor records the answer of the new target' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:skus }
        $script:mig2 = WanPlanned -Vms @((WanVm -Name 'win-d2' -Size 'Standard_D2_v2' -Os 'Windows')) -Options @{ 'win-d2' = 'v5' }
    }

    It 'moved from a v5 size to a v6 size, it stays turned on, and the record is rewritten from the new target' {
        $before = WanEntry $script:mig2 'win-d2'
        $before.acceleratedNetworkingOutcome.turnsOn | Should -BeTrue
        $r = Set-VmfMachineTarget -RunPath $script:mig2 -VmId (WanId 'win-d2') -Option v6 -ChangedBy 'operator@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        $after = WanEntry $script:mig2 'win-d2'
        $after.policy.targetGeneration | Should -Be 'v6'
        $after.acceleratedNetworkingOutcome.turnsOn | Should -BeTrue
        $after.schemaVersion | Should -Be 37
    }

    It 'a record the new target makes untrue is replaced: the scan now reads the primary as on' {
        # A record written from other facts must not survive a recompute.
        $planFile = Join-Path $script:mig2 'plan.json'
        $plan = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 40
        $e = @($plan.entries)[0]
        $e.assessment.primaryNicAccelerated = $true
        $e.assessment.acceleratedNicCount = 1
        if ($e.policy.PSObject.Properties['acceleratedNetworking']) { $e.policy.PSObject.Properties.Remove('acceleratedNetworking') }
        [System.IO.File]::WriteAllText($planFile, ($plan | ConvertTo-Json -Depth 40))
        (WanEntry $script:mig2 'win-d2').acceleratedNetworkingOutcome.turnsOn | Should -BeTrue -Because 'the old record is still there'
        Set-VmfMachineTarget -RunPath $script:mig2 -VmId (WanId 'win-d2') -Option v6 -ChangedBy 'operator@example.com' -Confirm:$false | Out-Null
        (WanEntry $script:mig2 'win-d2').acceleratedNetworkingOutcome.turnsOn | Should -BeFalse
    }
}

Describe 'WAVE-AN-NAMES-1: a decision that sets accelerated networking records the new answer, and keeps the acceptance' {
    BeforeEach {
        $script:vm = WanId 'dec-01'
        $script:rp = Join-Path $script:temp "wan-dec-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            param($rp, $vm)
            Initialize-VmfRun -RunPath $rp -RunId 'wan-dec' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'wan-dec' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'acceleratedNetworkingRequired' `
                -Detail 'Microsoft requires accelerated networking on Standard_D2ds_v6' | Out-Null
        }
        # The primary is off, and the plan keeps it off (preserve), so the
        # record says nothing turns on.
        $entry = [ordered]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'w1'; path = 'A'
            assessment = [ordered]@{ os = 'Windows'; sourceSize = 'Standard_D2ds_v4'; nicCount = 1; acceleratedNicCount = 0; primaryNicAccelerated = $false }
            target = [ordered]@{ size = 'Standard_D2ds_v6'; diskArch = 'nvme-temp'; controller = 'NVMe' }
            policy = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop'; acceleratedNetworking = 'preserve' }
            acceleratedNetworkingOutcome = [ordered]@{ turnsOn = $false; unknownWhy = $null }
        }
        $script:pp = Join-Path $script:rp 'plan.json'
        [ordered]@{ schemaVersion = 5; assessmentRunId = 'wan-dec'; entries = @($entry) } | ConvertTo-Json -Depth 12 | Set-Content $script:pp -Encoding utf8NoBOM
        Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $script:pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        Approve-VmfPlan -RunPath $script:rp -PlanPath $script:pp -Note 'approved' -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' | Out-Null
    }

    It 'the decision ensureOn turns it on, the record says so, and the wave stays accepted' {
        Resolve-VmfDecision -RunPath $script:rp -PlanPath $script:pp -VmId $script:vm -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } `
            -Note 'go' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') | Out-Null
        $entries = @((Get-Content $script:pp -Raw | ConvertFrom-Json -Depth 20).entries)
        $entries[0].policy.acceleratedNetworking | Should -Be 'ensureOn'
        $entries[0].acceleratedNetworkingOutcome.turnsOn | Should -BeTrue -Because 'the record follows the decision'
        $gate = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; e = $entries } { param($rp, $e) Test-VmfWaveOptionsAccepted -RunPath $rp -Entries $e -Wave 'w1' }
        $gate.Pass | Should -BeTrue -Because "the decision carries the acceptance forward over the new record: $($gate.Detail)"
    }

    It 'a decision about another setting leaves the record as it is' {
        # Saved, and then refused a retry: the wave's approval was for the
        # wave as it was. The plan is what this reads.
        try {
            Resolve-VmfDecision -RunPath $script:rp -PlanPath $script:pp -VmId $script:vm -PolicyOverride @{ onDDataFound = 'proceed' } `
                -Note 'go' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') | Out-Null
        }
        catch { "$_" | Should -Match 'is saved' }
        @((Get-Content $script:pp -Raw | ConvertFrom-Json -Depth 20).entries)[0].policy.onDDataFound | Should -Be 'proceed'
        $entries = @((Get-Content $script:pp -Raw | ConvertFrom-Json -Depth 20).entries)
        $entries[0].acceleratedNetworkingOutcome.turnsOn | Should -BeFalse
    }
}
Describe 'WAVE-AN-NAMES-1 (ACCEPT-HASH-1): the acceptance covers what it shows' {
    BeforeAll {
        $script:policy = [pscustomobject]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort' }
        function Global:WanHash($Entries) { InModuleScope VmMigrationFactory -Parameters @{ e = $Entries } { param($e) Get-VmfWaveOptionsHash -Entries $e } }
    }
    AfterAll { Remove-Item 'function:\WanHash' -ErrorAction SilentlyContinue }

    It 'an entry with no record hashes exactly as before, so no earlier acceptance is voided' {
        $e = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/a'; policy = $script:policy }
        $canon = '{0}|{1}' -f '/s/a', ($script:policy | ConvertTo-Json -Depth 8 -Compress)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try { $want = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))) -replace '-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
        WanHash @($e) | Should -BeExactly $want
    }

    It 'THE GAP: a record that changes, with the same settings, changes the hash' {
        $on = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/a'; policy = $script:policy; acceleratedNetworkingOutcome = [pscustomobject]@{ turnsOn = $true; unknownWhy = $null } }
        $off = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/a'; policy = $script:policy; acceleratedNetworkingOutcome = [pscustomobject]@{ turnsOn = $false; unknownWhy = $null } }
        $decides = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/a'; policy = $script:policy; acceleratedNetworkingOutcome = [pscustomobject]@{ turnsOn = $null; unknownWhy = 'kernel' } }
        $bare = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/a'; policy = $script:policy }
        @((WanHash @($on)), (WanHash @($off)), (WanHash @($decides)), (WanHash @($bare))) | Sort-Object -Unique | Should -HaveCount 4
    }

    It 'the start gate refuses a wave whose record changed after it was accepted' {
        $rp = Join-Path $script:temp "wan-gate-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'wan-gate' | Out-Null }
        $entry = [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (WanId 'g-01'); wave = 'w1'; path = 'A'
            policy = [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort' }
            acceleratedNetworkingOutcome = [ordered]@{ turnsOn = $false; unknownWhy = $null } }
        $pp = Join-Path $rp 'plan.json'
        [ordered]@{ schemaVersion = 5; assessmentRunId = 'wan-gate'; entries = @($entry) } | ConvertTo-Json -Depth 12 | Set-Content $pp -Encoding utf8NoBOM
        Confirm-VmfWaveOptions -RunPath $rp -PlanPath $pp -Wave 'w1' -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        $entry.acceleratedNetworkingOutcome.turnsOn = $true
        [ordered]@{ schemaVersion = 5; assessmentRunId = 'wan-gate'; entries = @($entry) } | ConvertTo-Json -Depth 12 | Set-Content $pp -Encoding utf8NoBOM
        $entries = @((Get-Content $pp -Raw | ConvertFrom-Json -Depth 20).entries)
        $gate = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $entries } { param($rp, $e) Test-VmfWaveOptionsAccepted -RunPath $rp -Entries $e -Wave 'w1' }
        $gate.Pass | Should -BeFalse
        $gate.Code | Should -Be 'changed'
    }
}

Describe 'WAVE-AN-NAMES-1: the contract (rule 1)' {
    It 'plan-entry is v20 or later in the schema and in the module (v24 since REBUILD-ACCEPT-1)' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $schema.properties.schemaVersion.const | Should -Be 37
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion } | Should -Be 37
    }

    It 'the schema declares the record: turnsOn true, false or null, and why it is unknown' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $p = $schema.properties.acceleratedNetworkingOutcome
        $p | Should -Not -BeNullOrEmpty
        @($p.required) | Should -Be @('turnsOn', 'unknownWhy')
        @($p.properties.turnsOn.type) | Should -Be @('boolean', 'null')
        @($p.properties.unknownWhy.enum) | Should -Be @('kernel', 'nics', $null)
        @($schema.required) | Should -Not -Contain 'acceleratedNetworkingOutcome' -Because 'an entry written before v20 still reads'
    }

    It 'the schema refuses a reason it does not know' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $sample.acceleratedNetworkingOutcome.unknownWhy = 'guess'
        Test-Json -Json ($sample | ConvertTo-Json -Depth 40) -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'the shipped sample holds the record' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $sample.PSObject.Properties['acceleratedNetworkingOutcome'] | Should -Not -BeNullOrEmpty
    }

    It 'the migration note says what changed and how an older plan reads' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## plan-entry v19 -> v20 \(2026-10-24, WAVE-AN-NAMES-1\)'
        $notes | Should -Match 'acceleratedNetworkingOutcome'
    }

    It 'a plan of v19 entries still reads' {
        $plan = [pscustomobject]@{ schemaVersion = 5; entries = @([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/a'; wave = 'w1'; path = 'A'; policy = [pscustomobject]@{} }) }
        { InModuleScope VmMigrationFactory -Parameters @{ p = $plan } { param($p) ConvertTo-VmfSupportedPlan -Plan $p } } | Should -Not -Throw
    }
}
