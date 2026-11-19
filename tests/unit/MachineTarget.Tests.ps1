#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# WAVE-MIX-2: change ONE machine's size series after planning.
#
# The series belongs to each machine (ADVISOR-1). Before this, the only way to
# change one machine after planning was to choose again and plan again - a new
# migration, and the wave arrangement lost. Set-VmfMachineTarget recomputes the
# one machine with the planner's own derivation, and clears what described its
# wave as it was: the approval, the acceptance and the quota check.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:MtSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:MtId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:MtVm([string]$Name, [string]$Size, [string]$Gen, [string]$Arch, [string]$Class, [string[]]$Blockers, [int]$An = 1, [string]$Controller = 'SCSI') {
        [ordered]@{
            vmId = (MtId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); classification = $Class; gen = $Gen
            os = 'Linux'; osVersion = '22_04-lts-gen2'; sourceSize = $Size; sourceDiskArch = $Arch
            sourceTempDisks = $(if ($Arch -eq 'scsi-temp') { 1 } else { 0 }); diskController = $Controller
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = $An; primaryNicAccelerated = ($An -gt 0)
            platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
            blockers = @($Blockers); prepNeeded = @()
        }
    }
    # A planned migration: app-01 (Generation 2, planned on v6) and legacy-01
    # (Generation 1, planned on v5), one machine to a wave.
    function Global:MtPlanned([int]$AppAn = 1, [object[]]$Vms, [object[]]$Choices) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        if (-not $Vms) {
            $Vms = @((MtVm 'app-01' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'ReadyAfterPrep' @() $AppAn),
                     (MtVm 'legacy-01' 'Standard_D2s_v4' 'V1' 'diskless' 'Blocked' @('gen1-requires-redeploy')))
            $Choices = @(@{ vmId = (MtId 'app-01'); option = 'v6' }, @{ vmId = (MtId 'legacy-01'); option = 'v5' })
        }
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-09-27T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $adviceVersion = MtVersion $rp 'target-advice.json'
        Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @($Choices) `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        $mig = "$rp-migration"
        New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath $mig | Out-Null
        @{ Scan = $rp; Mig = $mig }
    }
    function Global:MtVersion($rp, [string]$Name) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; n = $Name } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath $n))
        }
    }
    function Global:MtPlan($mig) { Get-Content (Join-Path $mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30 }
    function Global:MtEntry($mig, [string]$Name) { @((MtPlan $mig).entries) | Where-Object vmId -EQ (MtId $Name) }
}
AfterAll { Remove-Item 'function:\MtSku', 'function:\MtId', 'function:\MtVm', 'function:\MtPlanned', 'function:\MtVersion', 'function:\MtPlan', 'function:\MtEntry' -ErrorAction SilentlyContinue }

Describe 'WAVE-MIX-2: changing one machine''s target after planning' {

    BeforeEach {
        $script:catalog = @((MtSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (MtSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (MtSku 'Standard_D2ds_v6'), (MtSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:run = MtPlanned
        $script:mig = $script:run.Mig
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'a preview lists each series with its size, or why not, and writes nothing' {
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'legacy-01') -WhatIf
        $r.Applied | Should -BeFalse
        $r.Current | Should -Be 'v5'
        $v5 = @($r.Options) | Where-Object option -EQ 'v5'
        $v5.supported | Should -BeTrue
        $v5.current | Should -BeTrue
        $v5.targetSize | Should -Be 'Standard_D2s_v5'
        $v6 = @($r.Options) | Where-Object option -EQ 'v6'
        $v6.supported | Should -BeFalse
        $v6.targetSize | Should -BeNullOrEmpty
        @($v6.why) | Should -Contain 'gen1-requires-redeploy' -Because 'the targets step''s own reason, not a second judgement'
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'no -Option is a preview too' {
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        (Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01')).Applied | Should -BeFalse
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'applying recomputes that machine the way the planner does, and records the person' {
        $otherBefore = (MtEntry $script:mig 'legacy-01') | ConvertTo-Json -Depth 20
        $waveBefore = (MtEntry $script:mig 'app-01').wave
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        $r.From | Should -Be 'v6'
        $r.FromSize | Should -Be 'Standard_D2ds_v6'
        $r.CurrentSize | Should -Be 'Standard_D2ds_v5'
        $app = MtEntry $script:mig 'app-01'
        $app.target.size | Should -Be 'Standard_D2ds_v5'
        $app.target.controller | Should -Be 'SCSI' -Because 'GEN-V5-1: v5 is a SCSI move'
        $app.policy.targetGeneration | Should -Be 'v5'
        $app.target.choice.option | Should -Be 'v5'
        $app.target.choice.source | Should -Be 'person'
        $app.target.choice.chosenBy | Should -Be 'operator@example.com'
        $app.path | Should -Be 'A'
        # REBUILD-PICKER-1 (plan-entry v23): the method of the new move.
        $app.target.choice.method | Should -Be 'in-place'
        $app.wave | Should -Be $waveBefore -Because 'the machine keeps its place; only planning again would move it'
        ((MtEntry $script:mig 'legacy-01') | ConvertTo-Json -Depth 20) | Should -Be $otherBefore
        $events = InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfEvents -RunPath $p -Step 'plan' }
        @($events | Where-Object { $_.detail -match 'operator@example.com changed the target of app-01 from v6' }).Count | Should -Be 1
    }

    It 'what it writes is a plan the planner''s own reader accepts' {
        Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false | Out-Null
        { InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfPlanDocument -RunPath $p } } | Should -Not -Throw
        (MtPlan $script:mig).pathSummary | Where-Object path -EQ 'A' | ForEach-Object count | Should -Be 2
    }

    It 'a series the machine cannot take is refused, and nothing is written' {
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'legacy-01') -Option v6 -ChangedBy 'operator@example.com' -Confirm:$false } |
            Should -Throw '400: legacy-01 cannot move to v6*'
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'PLANVER-2: a plan that changed after the page read it is refused with 409; the version it read is accepted' {
        $version = MtVersion $script:mig 'plan.json'
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ExpectedPlanVersion ('0' * 64) -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '409:*'
        (MtEntry $script:mig 'app-01').policy.targetGeneration | Should -Be 'v6'
        (Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ExpectedPlanVersion $version -ChangedBy 'x@example.com' -Confirm:$false).Applied |
            Should -BeTrue
        MtVersion $script:mig 'plan.json' | Should -Not -Be $version -Because 'a plan sign-off follows the version, so it is asked again'
    }

    It 'a machine the engine has taken is refused - even while its state still reads PLANNED' {
        # New-VmfStateDoc writes PLANNED when a worker takes the machine, before
        # PRECHECK. A check for "not PLANNED" would let this through.
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (MtId 'app-01') } {
            New-VmfStateDoc -RunPath $p -RunId 'mt' -VmId $id -Wave 'wave-1' | Out-Null
        }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '400: Wave * has started (app-01 is PLANNED)*'
    }

    It 'a machine whose wave has started is refused, even while it has no state of its own' {
        # Workers hold the plan they read when the wave started, so "not
        # started yet" is not proof nothing will act on the old target.
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (MtId 'app-01'); w = $wave } {
            # A second machine in the same wave, leased by a worker.
            $plan = Read-VmfPlanDocument -RunPath $p
            $twin = $plan.entries[0].PSObject.Copy()
            $twin.vmId = $id -replace 'app-01$', 'app-02'
            $twin.wave = $w
            $plan.entries = @($plan.entries) + $twin
            Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document $plan -Depth 24
            Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfLeaseRelPath -VmId $twin.vmId) -Document @{ vmId = $twin.vmId; workerId = 'worker-1' } -Depth 4
        }
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw "400: Wave $wave has started (app-02 is held by a worker)*"
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'a wave with a capacity reservation in Azure is refused, and its claim is kept' {
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "capacity/claim-$w.json" -Document @{ wave = $w; state = 'RESERVED' } -Depth 4
        }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '400: Wave * has an on-demand capacity reservation in Azure (RESERVED)*'
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Test-VmfStoreItem -RunPath $p -RelPath "capacity/claim-$w.json" | Should -BeTrue
        }
        (MtEntry $script:mig 'app-01').policy.targetGeneration | Should -Be 'v6'
    }

    It 'a plan made without its target options is refused' {
        Remove-Item (Join-Path $script:mig 'target-advice.json')
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -WhatIf } | Should -Throw '400: This plan was made without its target options*'
    }

    It 'a series whose size the saved catalog no longer gives the same way is not offered' {
        # The catalog saved with the plan loses the v5 'd' size: a recompute
        # would pick a different size than the targets step offered.
        $file = Join-Path $script:mig 'catalog' 'centralus.json'
        $cat = Get-Content $file -Raw | ConvertFrom-Json -Depth 12
        $cat.sizes = @($cat.sizes | Where-Object name -NE 'Standard_D2ds_v5')
        $cat | ConvertTo-Json -Depth 12 | Set-Content $file
        $v5 = @((Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -WhatIf).Options) | Where-Object option -EQ 'v5'
        $v5.supported | Should -BeFalse
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '400: app-01 cannot move to v5 from this plan*'
    }

    It 'a machine whose plan the rules in use now do not give back is offered nothing else' {
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (MtId 'app-01') } {
            $plan = Read-VmfPlanDocument -RunPath $p
            ($plan.entries | Where-Object vmId -EQ $id).target.size = 'Standard_D4ds_v6'
            Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -WhatIf
        @($r.Options | Where-Object { -not $_.current -and $_.supported }).Count | Should -Be 0
        @((@($r.Options) | Where-Object option -EQ 'v5').why) | Should -Contain 'plan-disagrees'
    }

    It 'a machine that is not in the plan is refused' {
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'nobody-01') -Option v5 -Confirm:$false } | Should -Throw '400: This machine is not in the plan*'
    }

    It 'clears the approval, the acceptance and the quota check of its own wave; another wave keeps its acceptance and quota check' {
        $mine = (MtEntry $script:mig 'app-01').wave
        $other = (MtEntry $script:mig 'legacy-01').wave
        $mine | Should -Not -Be $other
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; a = $mine; b = $other } {
            foreach ($w in $a, $b) {
                Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w } -Depth 4
                Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) -Document @{ wave = $w } -Depth 4
                Write-VmfStoreJson -RunPath $p -RelPath "capacity/claim-$w.json" -Document @{ wave = $w } -Depth 4
            }
        }
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false
        $r.Invalidated.approval | Should -BeTrue
        $r.Invalidated.acceptance | Should -BeTrue
        $r.Invalidated.capacity | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; a = $mine; b = $other } {
            Test-VmfStoreItem -RunPath $p -RelPath "approvals/$a.json" | Should -BeFalse
            Test-VmfStoreItem -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $a) | Should -BeFalse
            Test-VmfStoreItem -RunPath $p -RelPath "capacity/claim-$a.json" | Should -BeFalse
            # WAVE-SAVE-FALSE-1 rewrote this line: it pinned the OTHER wave's
            # approval as kept. An approval signs the whole plan text
            # (Test-VmfWaveApproval), so after any write it can no longer pass
            # the gate - and kept, the page showed it as approved with no way
            # to approve again. The acceptance and the quota check describe
            # only their own wave, and stay.
            Test-VmfStoreItem -RunPath $p -RelPath "approvals/$b.json" | Should -BeFalse
            Test-VmfStoreItem -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $b) | Should -BeTrue
            Test-VmfStoreItem -RunPath $p -RelPath "capacity/claim-$b.json" | Should -BeTrue
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-2: a file under the name from before ACCEPT-NAME-1 is not read, so it is never cleared (it names <Holder>)' -ForEach @(
        @{ Holder = 'wave-1'; Cleared = $false }, @{ Holder = 'wave_1'; Cleared = $false }) {
        # Only an earlier version wrote acceptances/wave-options-wave-1.json, and
        # nothing is public before 1.0. The acceptance of wave_1 has its own name.
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; app = (MtId 'app-01'); h = $Holder } {
            $plan = Read-VmfPlanDocument -RunPath $p
            foreach ($e in $plan.entries) { $e.wave = $(if ($e.vmId -eq $app) { 'wave_1' } else { 'wave-1' }) }
            Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document $plan -Depth 24
            Write-VmfStoreJson -RunPath $p -RelPath 'acceptances/wave-options-wave-1.json' -Document @{ wave = $h } -Depth 4
        }
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false
        $r.Invalidated.acceptance | Should -Be $Cleared
        Test-Path (Join-Path $script:mig 'acceptances' 'wave-options-wave-1.json') | Should -Be (-not $Cleared)
    }

    It 'WAVE-APPROVE-1: a real approval of another wave still signs that wave, so it is kept and not named' {
        # Rewritten. An approval signed the WHOLE plan, so this pinned the other
        # wave's approval removed and named (WAVE-SAVE-FALSE-1). An approval now
        # signs its own wave (2026-10-05), and a target change in one
        # wave leaves another's approval standing.
        $other = (MtEntry $script:mig 'legacy-01').wave
        Approve-VmfWave -RunPath $script:mig -PlanPath (Join-Path $script:mig 'plan.json') -Wave $other -Note 'read and approved' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; b = $other } {
            (Test-VmfWaveApproval -RunPath $p -PlanPath (Join-Path $p 'plan.json') -Wave $b).Pass | Should -BeTrue -Because 'it matched the plan it signed'
        }
        (MtEntry $script:mig 'app-01').wave | Should -Not -Be $other -Because 'the machine changed is in another wave'
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        @($r.ApprovalsCleared).Count | Should -Be 0
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; b = $other } {
            Test-VmfStoreItem -RunPath $p -RelPath "approvals/$b.json" | Should -BeTrue
            (Test-VmfWaveApproval -RunPath $p -PlanPath (Join-Path $p 'plan.json') -Wave $b).Pass | Should -BeTrue
            $said = @(Read-VmfStoreLines -RunPath $p -RelPath 'logs/events.jsonl' | ForEach-Object { ($_ | ConvertFrom-Json).detail }) -join ' '
            $said | Should -Not -Match ([regex]::Escape("The approval of wave $b"))
        }
    }

    It 'clears first and writes second: a plan that fails to write leaves the wave unable to start, not started on old sign-offs' {
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w } -Depth 4
            Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) -Document @{ wave = $w } -Depth 4
        }
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        # PLAN-WRITE-RACE-1: the plan is written through the conditional write.
        Mock -ModuleName VmMigrationFactory Write-VmfTextDocumentIfVersion { throw 'the store refused the write' }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '*the store refused the write*'
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Test-VmfStoreItem -RunPath $p -RelPath "approvals/$w.json" | Should -BeFalse
            Test-VmfStoreItem -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) | Should -BeFalse
        }
    }

    It 'PLAN-WRITE-RACE-1: another writer between the read and the write - a 409, their plan kept, every record put back' {
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w } -Depth 4
            Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) -Document @{ wave = $w } -Depth 4
        }
        # The other writer lands after the records were taken, just before the write.
        Mock -ModuleName VmMigrationFactory Get-VmfPlannedAcceleratedNetworking {
            $file = Join-Path $script:mig 'plan.json'
            $p = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
            $p | Add-Member -NotePropertyName waveOrder -NotePropertyValue @('theirs') -Force
            [System.IO.File]::WriteAllText($file, ($p | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
            $null
        }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '409: Somebody changed the plan*'
        @((MtPlan $script:mig).waveOrder) | Should -Be @('theirs')
        (MtEntry $script:mig 'app-01').policy.targetGeneration | Should -Be 'v6'
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Test-VmfStoreItem -RunPath $p -RelPath "approvals/$w.json" | Should -BeTrue -Because 'nothing was written, so nothing was signed away'
            Test-VmfStoreItem -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) | Should -BeTrue
        }
    }

    It 'PLAN-WRITE-RACE-1: after a 409, records are NOT put back if the other writer changed this wave - they would describe machines it no longer has' {
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w } -Depth 4
            Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) -Document @{ wave = $w } -Depth 4
        }
        Mock -ModuleName VmMigrationFactory Get-VmfPlannedAcceleratedNetworking {
            $file = Join-Path $script:mig 'plan.json'
            $p = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
            (@($p.entries) | Where-Object { $_.vmId -like '*/app-01' }).policy | Add-Member -NotePropertyName onDDataFound -NotePropertyValue 'proceed' -Force
            [System.IO.File]::WriteAllText($file, ($p | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
            $null
        }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '409: Somebody changed the plan*'
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Test-VmfStoreItem -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) | Should -BeFalse -Because 'the wave changed, so it is accepted again'
        }
    }

    It 'PLAN-WRITE-RACE-1: an undo that meets a plan changed again says so, and does not write over it' {
        $wave = (MtEntry $script:mig 'app-01').wave
        $script:leaseAsks = 0
        Mock -ModuleName VmMigrationFactory Get-VmfLeaseInfo {
            $script:leaseAsks++
            if ($script:leaseAsks -gt 1) {
                # A worker took a machine, and somebody wrote the plan too.
                $file = Join-Path $script:mig 'plan.json'
                $p = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
                $p | Add-Member -NotePropertyName waveOrder -NotePropertyValue @('theirs') -Force
                [System.IO.File]::WriteAllText($file, ($p | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
                @{ workerId = 'worker-1' }
            }
        }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw "409: Wave $wave started while the target of app-01 was changing*and the plan changed again after that*"
        @((MtPlan $script:mig).waveOrder) | Should -Be @('theirs') -Because 'the other writer''s plan is not written over'
    }

    It 'a worker that takes a machine in its wave DURING the change undoes it: the plan and every record put back exactly' {
        # Independent review, finding 3: the wave's start checks passed before
        # the clearing, its workers were still starting, and one leased a
        # machine after the first question and before the write.
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w; by = 'a@example.com' } -Depth 4
            Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) -Document @{ wave = $w } -Depth 4
            Write-VmfStoreJson -RunPath $p -RelPath "capacity/claim-$w.json" -Document @{ wave = $w; state = 'QUOTA_VERIFIED' } -Depth 4
        }
        $files = @('plan.json', "approvals/$wave.json", "capacity/claim-$wave.json") + @(InModuleScope VmMigrationFactory -Parameters @{ w = $wave } { Get-VmfWaveOptionsAcceptancePath -Wave $w })
        $before = @{}; foreach ($f in $files) { $before[$f] = Get-Content (Join-Path $script:mig $f) -Raw }
        $script:leaseAsks = 0
        Mock -ModuleName VmMigrationFactory Get-VmfLeaseInfo { $script:leaseAsks++; if ($script:leaseAsks -gt 1) { @{ workerId = 'worker-1' } } }
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw "409: Wave $wave started while the target of app-01 was changing*Nothing was changed."
        foreach ($f in $files) { Get-Content (Join-Path $script:mig $f) -Raw | Should -BeExactly $before[$f] -Because "$f is put back as it was" }
    }

    It 'a quota check that becomes a reservation while the change reads is kept, and nothing is changed' {
        # Independent review, finding 4: a reserve job turns QUOTA_VERIFIED into
        # RESERVING; that claim is then the only record of what bills.
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w } -Depth 4
            Write-VmfStoreJson -RunPath $p -RelPath "capacity/claim-$w.json" -Document @{ wave = $w; state = 'QUOTA_VERIFIED' } -Depth 4
        }
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        $script:claimReads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            $script:claimReads++
            [pscustomobject]@{ wave = $script:waveName; state = $(if ($script:claimReads -ge 3) { 'RESERVING' } else { 'QUOTA_VERIFIED' }) }
        } -ParameterFilter { $RelPath -like 'capacity/*' }
        $script:waveName = $wave
        { Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '400: Wave * has an on-demand capacity reservation that Azure is still making (RESERVING)*'
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
        Test-Path (Join-Path $script:mig "capacity/claim-$wave.json") | Should -BeTrue
        Test-Path (Join-Path $script:mig "approvals/$wave.json") | Should -BeTrue -Because 'what was cleared before the refusal is put back'
    }

    It 'a released reservation bills nothing: the change goes ahead, and the activity log keeps what the record said' {
        # WAVE-EDIT-RESERVE-1 changed this: refusing left no way forward, and a
        # kept RELEASED claim stops the wave starting again anyway.
        $wave = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } {
            Write-VmfStoreJson -RunPath $p -RelPath "capacity/claim-$w.json" -Depth 4 -Document @{
                wave = $w; state = 'RELEASED'; size = 'Standard_D2ds_v6'; region = 'centralus' }
        }
        (Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false).Applied | Should -BeTrue
        Test-Path (Join-Path $script:mig "capacity/claim-$wave.json") | Should -BeFalse
        $ev = InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfEvents -RunPath $p -Step 'capacity' }
        @($ev | Where-Object { $_.detail -match 'released on-demand capacity reservation' -and $_.detail -match 'Standard_D2ds_v6' }).Count | Should -Be 1
    }

    It 'choosing the series it already has changes nothing' {
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        (Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v6 -Confirm:$false).Applied | Should -BeFalse
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'STEP-LOG-4: the change line cannot be written - the change is saved and returned, and the list is told' {
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'plan' } { throw 'The store did not answer.' }
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false -WarningVariable w -WarningAction SilentlyContinue
        $r.Applied | Should -BeTrue
        (MtEntry $script:mig 'app-01').policy.targetGeneration | Should -Be 'v5'
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -BeLike "*'plan ok' for $(MtId 'app-01') could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'planSaved' } -Times 1 -Exactly
    }

    It 'STEP-LOG-4: the line that says the quota check was removed cannot be written - the change line is still written' {
        $mine = (MtEntry $script:mig 'app-01').wave
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; a = $mine } {
            Write-VmfStoreJson -RunPath $p -RelPath "capacity/claim-$a.json" -Document @{ wave = $a } -Depth 4
        }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' } { throw 'The store did not answer.' }
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false -WarningAction SilentlyContinue
        $r.Applied | Should -BeTrue
        $r.Invalidated.capacity | Should -BeTrue
        $events = InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfEvents -RunPath $p -Step 'plan' }
        @($events | Where-Object { $_.detail -match 'changed the target of app-01' }).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'capacity' } -Times 1 -Exactly
    }
}

Describe 'WAVE-MIX-2: accelerated networking follows the new target (AN-PLAN-1)' {
    BeforeEach {
        # DRIFT-11: v7 too. Every v6 size requires accelerated networking since
        # 2026-10-27, so v7 is the series where the plan leaves it absent.
        $script:catalog = @((MtSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (MtSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (MtSku 'Standard_D2ds_v6'), (MtSku 'Standard_D2s_v6'), (MtSku 'Standard_D2ds_v7'), (MtSku 'Standard_D2s_v7'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:run = MtPlanned -AppAn 0
        $script:mig = $script:run.Mig
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'a machine with it off, moved to Intel D v5, has it turned on by the plan' {
        Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false | Out-Null
        (MtEntry $script:mig 'app-01').policy.acceleratedNetworking | Should -Be 'ensureOn'
    }

    It 'planned on v6 it is turned on too: every v6 size requires it (DRIFT-11)' {
        (MtEntry $script:mig 'app-01').policy.acceleratedNetworking | Should -Be 'ensureOn' -Because 'planned on v6 directly'
    }

    It 'and on to v7 it is ABSENT again, as the planner leaves it - never a choice nobody made' {
        # Independent review, finding 2: an explicit ensureOn left behind is
        # read by the engine as a decision, and can switch it on for a size
        # that does not require it - now v7 (DRIFT-11).
        Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false | Out-Null
        Set-VmfMachineTarget -RunPath $script:mig -VmId (MtId 'app-01') -Option v7 -ChangedBy 'x@example.com' -Confirm:$false | Out-Null
        (MtEntry $script:mig 'app-01').policy.PSObject.Properties['acceleratedNetworking'] | Should -BeNullOrEmpty
    }
}

Describe 'WAVE-MIX-2: the service route' {
    BeforeAll {
        function Global:MtPrincipal([string]$Role) {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = $Role })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\MtPrincipal' -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:catalog = @((MtSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (MtSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (MtSku 'Standard_D2ds_v6'), (MtSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:run = MtPlanned
        $script:mig = $script:run.Mig
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an operator changes it; the identity is the signed-in user, never the body' {
        $r = Invoke-VmfFacadeSetMachineTarget -Principal (MtPrincipal 'Vmf.Operator') -StorePath $script:mig -VmId (MtId 'app-01') `
            -Option v5 -PlanVersion (MtVersion $script:mig 'plan.json')
        $r.Applied | Should -BeTrue
        (MtEntry $script:mig 'app-01').target.choice.chosenBy | Should -Be 'person@example.com'
    }

    It 'a preview writes nothing and needs no version' {
        $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
        $r = Invoke-VmfFacadeSetMachineTarget -Principal (MtPrincipal 'Vmf.Operator') -StorePath $script:mig -VmId (MtId 'app-01') -Preview
        @($r.Options).Count | Should -Be 3
        Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'a viewer may not, an apply without the plan version is refused, and a stale version is a 409' {
        { Invoke-VmfFacadeSetMachineTarget -Principal (MtPrincipal 'Vmf.Viewer') -StorePath $script:mig -VmId (MtId 'app-01') -Option v5 -PlanVersion 'x' } |
            Should -Throw '403*'
        { Invoke-VmfFacadeSetMachineTarget -Principal (MtPrincipal 'Vmf.Operator') -StorePath $script:mig -VmId (MtId 'app-01') -Option v5 } |
            Should -Throw '400*version*'
        { Invoke-VmfFacadeSetMachineTarget -Principal (MtPrincipal 'Vmf.Operator') -StorePath $script:mig -VmId (MtId 'app-01') -Option v5 -PlanVersion ('0' * 64) } |
            Should -Throw '409*'
        (MtEntry $script:mig 'app-01').policy.targetGeneration | Should -Be 'v6'
    }

    It 'the route passes the version and the preview through, and says 409 for a conflict' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetMachineTarget' 'run.ps1')
        $code | Should -Match '-PlanVersion \(\[string\]\$body\.planVersion\)'
        $code | Should -Match '-Preview:\(\[bool\]\$body\.preview\)'
        $code | Should -Match "'\^409'.*Conflict"
    }

    It 'the route is POST runs/{runId}/plan/target' {
        $fj = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetMachineTarget' 'function.json') -Raw | ConvertFrom-Json
        $http = @($fj.bindings) | Where-Object type -eq 'httpTrigger'
        $http.route | Should -Be 'runs/{runId}/plan/target'
        @($http.methods) | Should -Be @('post')
    }
}

Describe 'WAVE-MIX-2: the source decides what a machine may become' {
    BeforeEach {
        $script:catalog = @((MtSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (MtSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (MtSku 'Standard_D2ds_v6'), (MtSku 'Standard_D2s_v6'), (MtSku 'Standard_D2s_v7'),
                            # A v3 size has a temporary disk and no 'd' in its name:
                            # only the catalog says so.
                            (MtSku 'Standard_D2s_v3' '16384'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'a machine already on NVMe is never re-planned here' {
        $script:run = MtPlanned -Vms @((MtVm 'app-01' 'Standard_D2ds_v4' 'V2' 'scsi-temp' 'ReadyAfterPrep' @()),
                                      (MtVm 'new-06' 'Standard_D2s_v6' 'V2' 'diskless' 'ReadyNow' @() 1 'NVMe')) `
                                -Choices @(@{ vmId = (MtId 'app-01'); option = 'v6' })
        # MACHINE-PICK-1: new-06 has no saved target, so it was not chosen and
        # the plan holds no entry for it (it was an EXCLUDED entry before). It
        # is still never re-planned here.
        MtEntry $script:run.Mig 'new-06' | Should -BeNullOrEmpty
        { Set-VmfMachineTarget -RunPath $script:run.Mig -VmId (MtId 'new-06') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false } |
            Should -Throw '400: This machine is not in the plan*'
    }

    It 'a v3 machine changed to v5 gets the d size the targets step offered, because the saved catalog keeps its source size' {
        $script:run = MtPlanned -Vms @((MtVm 'old-03' 'Standard_D2s_v3' 'V2' 'scsi-temp' 'ReadyAfterPrep' @())) `
                                -Choices @(@{ vmId = (MtId 'old-03'); option = 'v6' })
        $advice = Get-Content (Join-Path $script:run.Mig 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30
        $offered = (@($advice.machines[0].options) | Where-Object option -EQ 'v5').targetSize
        $offered | Should -Be 'Standard_D2ds_v5'
        $r = Set-VmfMachineTarget -RunPath $script:run.Mig -VmId (MtId 'old-03') -Option v5 -ChangedBy 'x@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        (MtEntry $script:run.Mig 'old-03').target.size | Should -Be $offered
    }

    It 'the catalog saved with the plan is size-catalog v2, keeps the source size, and matches its schema; a v1 file still does' {
        # Independent review, finding 5: the file changed shape with no version.
        $script:run = MtPlanned -Vms @((MtVm 'old-03' 'Standard_D2s_v3' 'V2' 'scsi-temp' 'ReadyAfterPrep' @())) `
                                -Choices @(@{ vmId = (MtId 'old-03'); option = 'v6' })
        $schema = Join-Path $script:repoRoot 'schemas' 'size-catalog.schema.json'
        $text = Get-Content (Join-Path $script:run.Mig 'catalog' 'centralus.json') -Raw
        { Test-Json -Json $text -SchemaFile $schema -ErrorAction Stop } | Should -Not -Throw
        $doc = $text | ConvertFrom-Json
        $doc.schemaVersion | Should -Be 2
        @($doc.sizes.name) | Should -Contain 'Standard_D2s_v3'
        $v1 = @{ schemaVersion = 1; location = 'centralus'; readUtc = '2026-09-01T00:00:00Z'
                 sizes = @(@{ name = 'Standard_D2s_v6'; family = 'standardDSv6Family'; capabilities = @() }) } | ConvertTo-Json -Depth 6
        { Test-Json -Json $v1 -SchemaFile $schema -ErrorAction Stop } | Should -Not -Throw
    }
}

Describe 'WAVE-MIX-2: a worker leaves a machine whose entry changed after its wave started' {
    # Independent review, finding 1: a worker runs from the plan it read at the
    # start. A waiting machine moved to another wave, or given a new target,
    # must not be moved on what the plan no longer says.
    BeforeAll {
        $script:wmRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:workerScript = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'
        function Global:WmEntry([int]$i) {
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-w/providers/Microsoft.Compute/virtualMachines/wm$i"
                wave = 'w1'; path = 'A'; assessment = [ordered]@{ location = 'centralus'; availabilitySetId = '' }
                target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [ordered]@{ requireApproval = $true } }
        }
    }
    AfterAll { Remove-Item 'function:\WmEntry' -ErrorAction SilentlyContinue }
    AfterEach { if (Test-Path $script:wmRoot) { Remove-Item $script:wmRoot -Recurse -Force } }

    It 'the same entry is current; a new wave, a new size, or no entry is not' {
        New-Item -ItemType Directory -Path $script:wmRoot -Force | Out-Null
        $planFile = Join-Path $script:wmRoot 'plan.json'
        @{ schemaVersion = 1; entries = @((WmEntry 1)) } | ConvertTo-Json -Depth 12 | Set-Content $planFile
        $held = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 12
        InModuleScope VmMigrationFactory -Parameters @{ f = $planFile; e = $held.entries[0] } {
            (Test-VmfLeasedEntryCurrent -PlanPath $f -Entry $e).Current | Should -BeTrue
        }
        foreach ($case in @(
                @{ Change = { param($x) $x.wave = 'w2' }; Why = 'moved to wave w2' },
                @{ Change = { param($x) $x.target.size = 'Standard_D2s_v5' }; Why = 'target or its settings changed' },
                @{ Change = { param($x) $x.policy.requireApproval = $false }; Why = 'target or its settings changed' })) {
            $stored = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 12
            & $case.Change $stored.entries[0]
            $stored | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $script:wmRoot 'plan2.json')
            InModuleScope VmMigrationFactory -Parameters @{ f = (Join-Path $script:wmRoot 'plan2.json'); e = $held.entries[0]; why = $case.Why } {
                $r = Test-VmfLeasedEntryCurrent -PlanPath $f -Entry $e
                $r.Current | Should -BeFalse
                $r.Reason | Should -Match $why
            }
        }
        @{ schemaVersion = 1; entries = @((WmEntry 2)) } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $script:wmRoot 'plan3.json')
        InModuleScope VmMigrationFactory -Parameters @{ f = (Join-Path $script:wmRoot 'plan3.json'); e = $held.entries[0] } {
            (Test-VmfLeasedEntryCurrent -PlanPath $f -Entry $e).Reason | Should -Match 'no longer in the plan'
        }
    }

    It 'a real worker: the second machine''s target changes while the first runs, and the second is left untouched' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:wmRoot } { Initialize-VmfRun -RunPath $rp -RunId 'wm-run' | Out-Null }
        $planFile = Join-Path $script:wmRoot 'plan.json'
        @{ schemaVersion = 1; entries = @((WmEntry 1), (WmEntry 2)) } | ConvertTo-Json -Depth 12 | Set-Content $planFile
        # The fake engine finishes machine 1, and while it runs somebody changes
        # machine 2's target in the stored plan.
        $fake = Join-Path $script:wmRoot 'fake-engine.ps1'
        @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
$planFile = Join-Path $RunPath 'plan.json'
$plan = Get-Content $planFile -Raw | ConvertFrom-Json -Depth 24
($plan.entries | Where-Object { $_.vmId -like '*wm2' }).target.size = 'Standard_D2s_v5'
$plan | ConvertTo-Json -Depth 24 | Set-Content $planFile
& (Get-Module VmMigrationFactory) { param($id, $rp, $rid)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId
'@ | Set-Content $fake
        $env:VMF_TEST_ENGINE = $fake
        try {
            & pwsh -NoProfile -File $script:workerScript -RunPath $script:wmRoot -PlanPath $planFile -Wave 'w1' -RunId 'wm-run' `
                -WorkerId 'worker-t3' -IdleWaitSeconds 1 *> $null
        }
        finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }
        $two = (WmEntry 2).vmId
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:wmRoot; one = (WmEntry 1).vmId; two = $two } {
            (Read-VmfStateDoc -RunPath $rp -VmId $one).state | Should -Be 'MIGRATED'
            Read-VmfStateDoc -RunPath $rp -VmId $two -ErrorAction SilentlyContinue | Should -BeNullOrEmpty -Because 'nothing touched it'
            Get-VmfLeaseInfo -RunPath $rp -VmId $two | Should -BeNullOrEmpty -Because 'its lease was given back'
            $ev = @(Read-VmfEvents -RunPath $rp -Step 'worker' | Where-Object { $_.vmId -eq $two -and $_.outcome -eq 'refused' })
            $ev.Count | Should -Be 1
            $ev[0].detail | Should -Match 'its target or its settings changed'
        }
    }
}

Describe 'WAVE-MIX-2: a worker takes no machine from a plan that changed after the start checks' {
    BeforeEach {
        $script:catalog = @((MtSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (MtSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (MtSku 'Standard_D2ds_v6'), (MtSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:run = MtPlanned
        $script:mig = $script:run.Mig
        $script:workerScript = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'refuses, leases nothing, exits non-zero and says why' {
        $wave = (MtEntry $script:mig 'app-01').wave
        $out = & pwsh -NoProfile -File $script:workerScript -RunPath $script:mig -PlanPath (Join-Path $script:mig 'plan.json') `
            -Wave $wave -RunId (Split-Path $script:mig -Leaf) -WorkerId 'worker-t1' -WaveVersion ('0' * 64) 2>&1
        $LASTEXITCODE | Should -Be 3
        ($out -join ' ') | Should -Match 'The plan changed after wave'
        @(Get-ChildItem (Join-Path $script:mig 'leases') -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $script:mig 'state') -Filter *.json -ErrorAction SilentlyContinue).Count | Should -Be 0
        $events = InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfEvents -RunPath $p -Step 'worker' }
        @($events | Where-Object { $_.outcome -eq 'refused' -and $_.detail -match 'worker-t1 took no machine' }).Count | Should -Be 1
    }

    It 'a worker given the version its start checks passed proceeds' {
        $wave = (MtEntry $script:mig 'app-01').wave
        $fake = Join-Path $script:mig 'fake-engine.ps1'
        @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
& (Get-Module VmMigrationFactory) { param($id, $rp, $rid)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId
'@ | Set-Content $fake
        $env:VMF_TEST_ENGINE = $fake
        try {
            & pwsh -NoProfile -File $script:workerScript -RunPath $script:mig -PlanPath (Join-Path $script:mig 'plan.json') `
                -Wave $wave -RunId (Split-Path $script:mig -Leaf) -WorkerId 'worker-t2' -IdleWaitSeconds 1 *> $null `
                -WaveVersion (InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $wave } { Get-VmfWaveVersion -PlanText (Read-VmfTextDocument -Path (Join-Path $p 'plan.json')) -Wave $w })
            $LASTEXITCODE | Should -Be 0
        }
        finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (MtId 'app-01') } {
            (Read-VmfStateDoc -RunPath $p -VmId $id).state | Should -Be 'MIGRATED'
        }
    }

    It 'Start-VmfWave hands every worker the version its start checks passed' {
        # WAVE-APPROVE-1: the version of the WAVE, from the same one read -
        # rewritten from the whole plan's version (WaveApprovePerWave.Tests.ps1
        # runs workers on both sides of it).
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $code | Should -Match "'-WaveVersion', \`$checkedWaveVersion"
        # One read: the version handed on is the version of the plan the checks judged.
        $code | Should -Match '\$read = Read-VmfPlanFileVersioned -Path \$PlanPath'
        $code | Should -Match '\$checkedWaveVersion = Get-VmfWaveVersion -PlanText \$read\.Text -Wave \$Wave'
        $code | Should -Match '\$plan = \$read\.Plan'
    }

    It 'the worker asks whether the leased entry is current BEFORE anything touches the machine' {
        $code = Get-VmfCodeOnly -Path $script:workerScript
        $ask = $code.IndexOf('Test-VmfLeasedEntryCurrent')
        $ask | Should -BeGreaterThan 0
        $ask | Should -BeLessThan $code.IndexOf('VMF_TEST_ENGINE) {')
        $ask | Should -BeLessThan $code.IndexOf('Invoke-VmfStateMachine')
    }
}
