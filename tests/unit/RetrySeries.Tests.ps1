#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RETRY-SERIES-1: a machine that rolled back can be tried again on another
# size series (2026-09-28: on the run page, beside the machine).
#
# WAVE-MIX-2 refuses a target change once anything in the machine's wave has a
# state, because the wave's workers hold the plan they read. That also refused
# the most useful case: a machine that rolled back on v6 and should try v5.
# A rolled-back machine is running, as it was, and nothing acts on it - so its
# target may change when nothing in its wave is running. It STAYS rolled back:
# the independent review found that re-arming it at once left it at PRECHECK
# waiting on a sign-off, reading as running and refused by Skip. Try this
# machine again runs it once the wave is accepted and approved again.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:RsSku([string]$Name, [string]$TempMb = '0', [string]$Gens = 'V2') {
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
                [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }) }
    }
    function Global:RsId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
    function Global:RsVm([string]$Name) {
        [ordered]@{
            vmId = (RsId $Name); name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); classification = 'ReadyAfterPrep'; gen = 'V2'
            os = 'Linux'; osVersion = '22_04-lts-gen2'; sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'
            sourceTempDisks = 1; diskController = 'SCSI'
            dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = 'shop' }
            blockers = @(); prepNeeded = @()
        }
    }
    # Two machines planned on v6. -OneWave puts both in wave-1 (the planner
    # makes the first wave a one-machine pilot).
    function Global:RsPlanned([switch]$OneWave) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $rp -Leaf); generatedUtc = '2026-09-28T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @((RsVm 'app-01'), (RsVm 'app-02')) }
        InModuleScope VmMigrationFactory -Parameters @{ p = $rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId (Split-Path $p -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $rp 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ p = $rp } {
            Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p -RelPath 'target-advice.json'))
        }
        Set-VmfTestTargetChoice -RunPath $rp -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @(@{ vmId = (RsId 'app-01'); option = 'v6' }, @{ vmId = (RsId 'app-02'); option = 'v6' }) `
            -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        $mig = "$rp-migration"
        New-VmfPlan -AssessmentPath (Join-Path $rp 'assessment.json') -OutPath $mig | Out-Null
        if ($OneWave) {
            InModuleScope VmMigrationFactory -Parameters @{ p = $mig } {
                $plan = Read-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Depth 30
                foreach ($e in $plan.entries) { $e.wave = 'wave-1' }
                Write-VmfStoreJson -RunPath $p -RelPath 'plan.json' -Document $plan -Depth 30
            }
        }
        @{ Scan = $rp; Mig = $mig }
    }
    # A machine that reached a state, written the way the engine writes it.
    function Global:RsState($mig, [string]$Name, [string]$State, [string]$Reason = '') {
        InModuleScope VmMigrationFactory -Parameters @{ p = $mig; id = (RsId $Name); st = $State; rc = $Reason } {
            $wave = [string](@((Read-VmfPlanDocument -RunPath $p).entries) | Where-Object vmId -EQ $id).wave
            New-VmfStateDoc -RunPath $p -RunId 'rs-test' -VmId $id -Wave $wave | Out-Null
            $t = @{ RunPath = $p; VmId = $id; NewState = $st; Outcome = 'ok' }
            if ($rc) { $t.Outcome = 'fail'; $t.ReasonCode = $rc; $t.MachineState = 'restored'; $t.Detail = 'STARTING failed; the machine was rolled back to how it was.' }
            Add-VmfStateTransition @t | Out-Null
        }
    }
    function Global:RsEntry($mig, [string]$Name) { @((Get-Content (Join-Path $mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (RsId $Name) }
    function Global:RsDoc($mig, [string]$Name) { InModuleScope VmMigrationFactory -Parameters @{ p = $mig; id = (RsId $Name) } { Read-VmfStateDoc -RunPath $p -VmId $id } }
    function Global:RsTry($mig, [string]$Name, [string]$Option = 'v5') {
        Set-VmfMachineTarget -RunPath $mig -VmId (RsId $Name) -Option $Option -AfterRollback -ChangedBy 'operator@example.com' -Confirm:$false
    }
}
AfterAll { Remove-Item 'function:\RsSku', 'function:\RsId', 'function:\RsVm', 'function:\RsPlanned', 'function:\RsState', 'function:\RsEntry', 'function:\RsDoc', 'function:\RsTry' -ErrorAction SilentlyContinue }

Describe 'RETRY-SERIES-1: try a rolled-back machine again on another series' {

    BeforeEach {
        $script:catalog = @((RsSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (RsSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (RsSku 'Standard_D2ds_v6'), (RsSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    Context 'the machine rolled back, and nothing in its wave is running' {
        BeforeEach {
            $script:run = RsPlanned -OneWave
            $script:mig = $script:run.Mig
            $script:wave = [string](RsEntry $script:mig 'app-01').wave
            [string](RsEntry $script:mig 'app-02').wave | Should -Be $script:wave -Because 'the fixture puts both in one wave'
            RsState $script:mig 'app-01' 'FAILED_ROLLED_BACK' 'bootFailedAfterConversion'
            RsState $script:mig 'app-02' 'MIGRATED'
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $script:wave } {
                Write-VmfStoreJson -RunPath $p -RelPath "approvals/$w.json" -Document @{ wave = $w; approvedBy = @{ identity = 'approver@example.com' } }
                Write-VmfStoreJson -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) -Document @{ wave = $w; acceptedBy = 'operator@example.com' }
            }
        }

        It 'a preview offers the other series, and writes nothing' {
            $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
            $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (RsId 'app-01') -AfterRollback -WhatIf
            $r.Current | Should -Be 'v6'
            (@($r.Options) | Where-Object option -EQ 'v5').supported | Should -BeTrue
            $r.PlanVersion | Should -Not -BeNullOrEmpty -Because 'the page quotes it back when it applies (PLANVER-2)'
            Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
        }

        It 'the machine takes the new target and stays rolled back, for Try this machine again' {
            $r = RsTry $script:mig 'app-01'
            $r.Applied | Should -BeTrue
            $e = RsEntry $script:mig 'app-01'
            $e.target.size | Should -Be 'Standard_D2ds_v5'
            $e.policy.targetGeneration | Should -Be 'v5'
            $e.target.choice.chosenBy | Should -Be 'operator@example.com'
            (RsDoc $script:mig 'app-01').state | Should -Be 'FAILED_ROLLED_BACK' -Because 're-armed now it would wait at PRECHECK on a sign-off, and Skip refuses PRECHECK'
            (RsDoc $script:mig 'app-02').state | Should -Be 'MIGRATED' -Because 'nothing else in the wave changes'
        }

        It 'the wave''s acceptance and sign-off are asked for again - the new target is shown and signed' {
            RsTry $script:mig 'app-01' | Out-Null
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $script:wave } {
                Test-VmfStoreItem -RunPath $p -RelPath "approvals/$w.json" | Should -BeFalse
                Test-VmfStoreItem -RunPath $p -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave $w) | Should -BeFalse
            }
        }

        It 'the activity log says who, from what, to what, and that it rolled back' {
            RsTry $script:mig 'app-01' | Out-Null
            $events = InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfEvents -RunPath $p }
            @($events | Where-Object { $_.step -eq 'plan' -and $_.detail -match 'operator@example.com changed the target of app-01 from v6 \(Standard_D2ds_v6\) to v5 \(Standard_D2ds_v5\) after it rolled back' }).Count | Should -Be 1
        }

        It 'the machine can still be left out afterwards - it is not stuck' {
            RsTry $script:mig 'app-01' | Out-Null
            { Skip-VmfVm -RunPath $script:mig -VmId (RsId 'app-01') -Reason 'not this time' -SkippedBy 'operator@example.com' -Confirm:$false } | Should -Not -Throw
        }

        It 'the series it has now is not a change: Retry does that, and nothing is written' {
            $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
            { RsTry $script:mig 'app-01' 'v6' } | Should -Throw '400: app-01 is on v6 already*'
            Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
            (RsDoc $script:mig 'app-01').state | Should -Be 'FAILED_ROLLED_BACK'
        }

        It 'a Retry or a Skip of the machine while the target is written undoes the change' {
            # The re-ask after the write reads the machine's own state again.
            $script:reads = 0
            Mock -ModuleName VmMigrationFactory Read-VmfStateDoc {
                $script:reads++
                [pscustomobject]@{ state = $(if ($script:reads -le 2) { 'FAILED_ROLLED_BACK' } else { 'SKIPPED' }) }
            } -ParameterFilter { $VmId -like '*/app-01' }
            $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
            { RsTry $script:mig 'app-01' } | Should -Throw '409: *(app-01 is SKIPPED)*Nothing was changed*'
            Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
        }

        It 'a reservation that bills refuses it, as any target change' {
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $script:wave } {
                Write-VmfStoreJson -RunPath $p -RelPath 'capacity/c1.json' -Document @{ wave = $w; state = 'RESERVED' }
            }
            { RsTry $script:mig 'app-01' } | Should -Throw '*Release it on the wave*'
            (RsDoc $script:mig 'app-01').state | Should -Be 'FAILED_ROLLED_BACK'
        }

        It 'a machine taken while the target was changing undoes the change' {
            # The re-ask after the write: a wave started meanwhile.
            $script:asked = 0
            Mock -ModuleName VmMigrationFactory Get-VmfWaveReleaseRefusal { $script:asked++; if ($script:asked -gt 1) { 'app-02 is held by a worker' } }
            $before = Get-Content (Join-Path $script:mig 'plan.json') -Raw
            { RsTry $script:mig 'app-01' } | Should -Throw '409: *Nothing was changed*'
            Get-Content (Join-Path $script:mig 'plan.json') -Raw | Should -BeExactly $before
            (RsDoc $script:mig 'app-01').state | Should -Be 'FAILED_ROLLED_BACK'
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; w = $script:wave } {
                Test-VmfStoreItem -RunPath $p -RelPath "approvals/$w.json" | Should -BeTrue -Because 'every record is put back'
            }
        }
    }

    # ROLLBACK-SIZE-REFUSED-SERIES-1 (2026-11-14): Azure refused
    # the original size in the rollback, so the machine is stopped on its new
    # size (FAILED_NEEDS_ATTENTION, rollbackSizeRefused). Its way forward is
    # another series: Change to v5, then Restore this machine from the first
    # safety copy, which goes onto the v5 size the change plans.
    Context 'the rollback stopped because Azure refused the original size' {
        BeforeEach {
            $script:catalog = @((RsSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (RsSku 'Standard_D2s_v5' '0' 'V1,V2'),
                                (RsSku 'Standard_D2ds_v6'), (RsSku 'Standard_D2s_v6'), (RsSku 'Standard_D2ds_v7'), (RsSku 'Standard_D2s_v7'))
            $script:run = RsPlanned -OneWave
            $script:mig = $script:run.Mig
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (RsId 'app-01') } {
                $wave = [string](@((Read-VmfPlanDocument -RunPath $p).entries) | Where-Object vmId -EQ $id).wave
                New-VmfStateDoc -RunPath $p -RunId 'rs-test' -VmId $id -Wave $wave | Out-Null
                Add-VmfStateTransition -RunPath $p -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome 'fail' -ReasonCode 'rollbackSizeRefused' -MachineState 'changed' `
                    -Detail 'The Verifying step failed, and the rollback stopped: Azure refused the original size Standard_D2ds_v4 (NotAvailableForSubscription).' | Out-Null
            }
            RsState $script:mig 'app-02' 'MIGRATED'
        }

        It 'Change to v5 is offered, and a series on NVMe is not: the first safety copy starts only on SCSI' {
            $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (RsId 'app-01') -AfterRollback -WhatIf
            (@($r.Options) | Where-Object option -EQ 'v5').supported | Should -BeTrue
            $v7 = @($r.Options) | Where-Object option -EQ 'v7'
            $v7.supported | Should -BeFalse
            @($v7.why) | Should -Contain 'first-copy-needs-scsi' -Because "why: $(@($v7.why) -join ', ')"
        }

        It 'the machine takes v5 and stays where it is, for Restore this machine' {
            $r = RsTry $script:mig 'app-01'
            $r.Applied | Should -BeTrue
            (RsEntry $script:mig 'app-01').target.size | Should -Be 'Standard_D2ds_v5'
            (RsDoc $script:mig 'app-01').state | Should -Be 'FAILED_NEEDS_ATTENTION'
            $events = InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig } { Read-VmfEvents -RunPath $p }
            @($events | Where-Object { $_.step -eq 'plan' -and $_.detail -match 'to v5 \(Standard_D2ds_v5\) after Azure refused its original size\.' }).Count | Should -Be 1
        }

        It 'v7 is refused until the machine is restored' {
            { RsTry $script:mig 'app-01' 'v7' } | Should -Throw '*first-copy-needs-scsi*'
        }

        It 'after a restore, a series on NVMe is a choice again: the machine is on its first safety copy' {
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (RsId 'app-01') } {
                $d = Read-VmfStateDoc -RunPath $p -VmId $id
                $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = (Get-Date).ToUniversalTime().AddMinutes(5).ToString('o') }) -Force
                Write-VmfStateDoc -RunPath $p -Document $d
            }
            $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (RsId 'app-01') -AfterRollback -WhatIf
            @((@($r.Options) | Where-Object option -EQ 'v7').why) | Should -Not -Contain 'first-copy-needs-scsi'
        }

        It 'another stop that left the machine changed is still refused' {
            InModuleScope VmMigrationFactory -Parameters @{ p = $script:mig; id = (RsId 'app-01') } {
                Add-VmfStateTransition -RunPath $p -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome 'fail' -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'The rollback also failed.' | Out-Null
            }
            { RsTry $script:mig 'app-01' } | Should -Throw '400: app-01 did not roll back*'
        }
    }

    Context 'when it is refused' {
        It 'a machine that did not roll back: <State>' -ForEach @(
            @{ State = 'MIGRATED' }, @{ State = 'NEEDS_DECISION' }, @{ State = 'FAILED_NEEDS_ATTENTION' }, @{ State = 'CONVERTING' }) {
            $script:run = RsPlanned
            RsState $script:run.Mig 'app-01' $State
            { RsTry $script:run.Mig 'app-01' } | Should -Throw "400: app-01 did not roll back*"
        }

        It 'a machine that has not started - its target changes the ordinary way' {
            $script:run = RsPlanned
            { RsTry $script:run.Mig 'app-01' } | Should -Throw '400: app-01 did not roll back*'
        }

        It 'another machine of its wave is running: <State>' -ForEach @(@{ State = 'CONVERTING' }, @{ State = 'PLANNED' }) {
            $script:run = RsPlanned -OneWave
            RsState $script:run.Mig 'app-01' 'FAILED_ROLLED_BACK' 'bootFailedAfterConversion'
            RsState $script:run.Mig 'app-02' $State
            $before = Get-Content (Join-Path $script:run.Mig 'plan.json') -Raw
            { RsTry $script:run.Mig 'app-01' } | Should -Throw "400: Wave * is running (app-02 is $State)*"
            Get-Content (Join-Path $script:run.Mig 'plan.json') -Raw | Should -BeExactly $before
        }

        It 'without -AfterRollback, a wave that has started is still refused (WAVE-MIX-2)' {
            $script:run = RsPlanned
            RsState $script:run.Mig 'app-01' 'FAILED_ROLLED_BACK' 'bootFailedAfterConversion'
            { Set-VmfMachineTarget -RunPath $script:run.Mig -VmId (RsId 'app-01') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false } |
                Should -Throw '400: Wave * has started*'
        }
    }
}

Describe 'RETRY-SERIES-1: the service route' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        function Global:RsPrincipal([string]$Role) {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = $Role })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\RsPrincipal' -ErrorAction SilentlyContinue }

    BeforeEach {
        $script:catalog = @((RsSku 'Standard_D2ds_v5' '76800' 'V1,V2'), (RsSku 'Standard_D2s_v5' '0' 'V1,V2'),
                            (RsSku 'Standard_D2ds_v6'), (RsSku 'Standard_D2s_v6'))
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:catalog }
        $script:run = RsPlanned
        RsState $script:run.Mig 'app-01' 'FAILED_ROLLED_BACK' 'bootFailedAfterConversion'
    }
    AfterEach {
        foreach ($d in $script:run.Scan, $script:run.Mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } }
    }

    It 'an operator changes it; the identity is the signed-in user, and the preview''s version is quoted back' {
        $p = Invoke-VmfFacadeSetMachineTarget -Principal (RsPrincipal 'Vmf.Operator') -StorePath $script:run.Mig -VmId (RsId 'app-01') -AfterRollback -Preview
        $r = Invoke-VmfFacadeSetMachineTarget -Principal (RsPrincipal 'Vmf.Operator') -StorePath $script:run.Mig -VmId (RsId 'app-01') `
            -Option v5 -PlanVersion $p.PlanVersion -AfterRollback
        $r.Applied | Should -BeTrue
        (RsEntry $script:run.Mig 'app-01').target.choice.chosenBy | Should -Be 'person@example.com'
    }

    It 'a viewer may not' {
        { Invoke-VmfFacadeSetMachineTarget -Principal (RsPrincipal 'Vmf.Viewer') -StorePath $script:run.Mig -VmId (RsId 'app-01') -Option v5 -PlanVersion 'x' -AfterRollback } |
            Should -Throw '403*'
    }

    It 'the route passes afterRollback through' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostSetMachineTarget' 'run.ps1')
        $code | Should -Match '-AfterRollback:\(\[bool\]\$body\.afterRollback\)'
    }
}
