#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-EDIT-RUNNING-1: a running wave does not change (2026-09-28:
# refuse, rather than allow and warn).
#
# A running wave's workers hold the plan they read when it started, and every
# lease compares the machine's entry with the stored plan
# (Test-VmfLeasedEntryCurrent). So a waiting machine moved OUT, a machine moved
# IN, or a setting changed would each be silently left untouched by the wave
# that is running - safe, but nobody was told.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines'
    # wave-1: vm1 (working or finished) and vm2 (waiting); wave-2: vm3.
    function Global:ErRun([string]$Vm1State) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-er-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; sub = $script:sub; st = $Vm1State } {
            Initialize-VmfRun -RunPath $rp -RunId 'er-test' | Out-Null
            $e = { param($n, $w) [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/$n"; wave = $w; path = 'A'
                    assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D2ds_v6' }
                    policy = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } } }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'er-test'
                entries = @((& $e 'vm1' 'wave-1'), (& $e 'vm2' 'wave-1'), (& $e 'vm3' 'wave-2')) })
            if ($st) {
                $doc = New-VmfStateDoc -RunPath $rp -RunId 'er-test' -VmId "$sub/vm1" -Wave 'wave-1'
                $doc.state = $st
                Write-VmfStateDoc -RunPath $rp -Document $doc | Out-Null
            }
        }
        $rp
    }
    function Global:ErSave($rp, [hashtable[]]$Waves) {
        Set-VmfWavePlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -ChangedBy 'operator@example.com' -Confirm:$false -Layout @{ waves = $Waves }
    }
    function Global:ErW([string]$Name, [string[]]$Vms, [string]$OnData = 'stop') {
        @{ name = $Name; vmIds = @($Vms | ForEach-Object { "$script:sub/$_" }); capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = $OnData }
    }
}
AfterAll { Remove-Item 'function:\ErRun', 'function:\ErSave', 'function:\ErW' -ErrorAction SilentlyContinue }

Describe 'WAVE-EDIT-RUNNING-1: a running wave does not change' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'moving a waiting machine OUT of a running wave is refused, and nothing is written' {
        $script:rp = ErRun 'CONVERTING'
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { ErSave $script:rp @((ErW 'wave-1' 'vm1'), (ErW 'wave-2' 'vm2', 'vm3')) } |
            Should -Throw '400: Wave wave-1 is running (vm1 is CONVERTING). Change it when the wave has finished. To change it sooner, select Pause new work on the Migrations page and wait for its machines to finish.'
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'moving a machine INTO a running wave is refused - its workers would never take it' {
        $script:rp = ErRun 'CONVERTING'
        { ErSave $script:rp @((ErW 'wave-1' 'vm1', 'vm2', 'vm3'), (ErW 'wave-2' @())) } |
            Should -Throw '400: Wave wave-1 is running*'
    }

    It 'changing a setting of a running wave is refused - its workers would leave the rest untouched' {
        $script:rp = ErRun 'STARTING'
        { ErSave $script:rp @((ErW 'wave-1' 'vm1', 'vm2' -OnData 'proceed'), (ErW 'wave-2' 'vm3')) } |
            Should -Throw '400: Wave wave-1 is running (vm1 is STARTING)*'
    }

    It 'a machine a worker has just taken reads PLANNED, and that counts' {
        $script:rp = ErRun 'PLANNED'
        { ErSave $script:rp @((ErW 'wave-1' 'vm1'), (ErW 'wave-2' 'vm2', 'vm3')) } | Should -Throw '400: Wave wave-1 is running (vm1 is PLANNED)*'
    }

    It 'another wave may still change while this one runs' {
        $script:rp = ErRun 'CONVERTING'
        { ErSave $script:rp @((ErW 'wave-1' 'vm1', 'vm2'), (ErW 'wave-2' 'vm3' -OnData 'proceed')) } | Should -Not -Throw
    }

    It 'a wave that has finished, or whose machine is parked, may change' -ForEach @(
        @{ State = 'MIGRATED' }, @{ State = 'NEEDS_DECISION' }, @{ State = 'FAILED_ROLLED_BACK' },
        @{ State = 'FAILED_NEEDS_ATTENTION' }, @{ State = 'SKIPPED' }) {
        $script:rp = ErRun $State
        { ErSave $script:rp @((ErW 'wave-1' 'vm1', 'vm2' -OnData 'proceed'), (ErW 'wave-2' 'vm3')) } | Should -Not -Throw
    }

    It 'a wave nobody has started may change' {
        $script:rp = ErRun ''
        { ErSave $script:rp @((ErW 'wave-1' 'vm1'), (ErW 'wave-2' 'vm2', 'vm3')) } | Should -Not -Throw
    }

    It 'renaming a running wave is refused - its machines would move to a wave no worker runs' {
        $script:rp = ErRun 'PLANNED'
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { ErSave $script:rp @((ErW 'wave-1b' 'vm1', 'vm2'), (ErW 'wave-2' 'vm3')) } | Should -Throw '400: Wave wave-1 is running (vm1 is PLANNED)*'
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    It 'deleting a running wave is refused - its machines would go back to no wave' {
        $script:rp = ErRun 'PLANNED'
        # WAVE-REMOVE-NOT-SAVED-1: the layout the wave editor sends after Delete -
        # the wave is not in it, and its machines go to no wave.
        $before = Get-Content (Join-Path $script:rp 'plan.json') -Raw
        { ErSave $script:rp @((ErW 'wave-2' 'vm3')) } | Should -Throw '400: Wave wave-1 is running (vm1 is PLANNED)*'
        Get-Content (Join-Path $script:rp 'plan.json') -Raw | Should -BeExactly $before
    }

    Context 'a running wave whose machines hold different settings' {
        # A decision's answer is written to ONE machine (Resolve-VmfDecision),
        # so a running wave can hold vm2 on proceed while vm1 is on stop. The
        # page shows the first machine's value on the card. The independent
        # review reproduced a save of wave-2 alone refused as a change to wave-1.
        BeforeEach {
            $script:rp = ErRun 'CONVERTING'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $script:sub } {
                $plan = Read-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24
                ($plan.entries | Where-Object { $_.vmId -eq "$sub/vm2" }).policy.onDDataFound = 'proceed'
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
            }
        }

        It 'the running wave sent with its machines and no settings: another wave saves, and each machine keeps its own' {
            $running = @{ name = 'wave-1'; vmIds = @("$script:sub/vm1", "$script:sub/vm2") }
            { ErSave $script:rp @($running, (ErW 'wave-2' 'vm3' -OnData 'proceed')) } | Should -Not -Throw
            $plan = Get-Content (Join-Path $script:rp 'plan.json') -Raw | ConvertFrom-Json
            ($plan.entries | Where-Object { $_.vmId -like '*/vm2' }).policy.onDDataFound | Should -Be 'proceed'
            ($plan.entries | Where-Object { $_.vmId -like '*/vm1' }).policy.onDDataFound | Should -Be 'stop'
            ($plan.entries | Where-Object { $_.vmId -like '*/vm3' }).policy.onDDataFound | Should -Be 'proceed'
        }

        It 'the card''s one value sent to every machine IS a change, which is why the page leaves it out' {
            { ErSave $script:rp @((ErW 'wave-1' 'vm1', 'vm2'), (ErW 'wave-2' 'vm3' -OnData 'proceed')) } |
                Should -Throw '400: Wave wave-1 is running (vm1 is CONVERTING)*'
        }
    }
}