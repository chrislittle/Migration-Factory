#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OVERVIEW-RUNNING-STALE-1, 2026-11-13: the run status lists only machines that
# are really moving.
#
# WHAT WAS WRONG. Write-VmfRunStatus put every machine of the wave that had a
# lease into `running`, whatever its state and however old the lease. A worker
# checkpoints MIGRATED and then deletes the rollback disks it made before the
# move (Remove-VmfUnusedRollbackDisksBeforeMove) while it still holds the
# lease; the lease goes only in the worker's finally. The wave's monitor saw
# MIGRATED, found nothing pending, and wrote the wave's last status with the
# lease still there - so the status said one machine was moving, and nothing
# writes the live fields again after a wave ends. The Overview showed a
# finished migration under Running now.
#
# THE RULE. A machine is in `running` when a wave worker holds a lease on it
# that is not past its expiry (Test-VmfMachineLeaseExpired), and its state is
# not final (Get-VmfEngineStates Terminal). The wave's last write
# (-WaveEnded) lists none: the wave is over.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'ors'

    function Global:OrsPlan {
        param([int]$Count = 1)
        $entries = for ($i = 1; $i -le $Count; $i++) {
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-contoso/providers/Microsoft.Compute/virtualMachines/vm$i"
                wave = 'wave-demo'; ring = 'lab'; appGroup = "vm$i"
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                                                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ capacityGate = 'BestEffort' }
            }
        }
        [pscustomobject]@{ schemaVersion = 1; entries = @($entries) }
    }

    # One machine: a state (or none: no document), and a lease of a given age
    # (or none).
    function Global:OrsMachine {
        param([string]$RunPath, $Entry, [string]$State, [int]$LeaseAgeSeconds = -1, [string]$WorkerId = 'ors-w1')
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $Entry.vmId; st = $State; age = $LeaseAgeSeconds; wid = $WorkerId } {
            if ($st) {
                New-VmfStateDoc -RunPath $rp -RunId 'ors' -VmId $id | Out-Null
                if ($st -ne 'PLANNED') { Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok | Out-Null }
            }
            if ($age -ge 0) {
                New-VmfLease -RunPath $rp -VmId $id -WorkerId $wid | Out-Null
                if ($age -gt 0) {
                    $file = Get-VmfLeasePath -RunPath $rp -VmId $id
                    $lease = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
                    $old = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
                    $lease.heartbeatUtc = $old; $lease.acquiredUtc = $old
                    Set-Content -LiteralPath $file -Value ($lease | ConvertTo-Json -Depth 6) -NoNewline
                }
            }
        }
    }

    # The status as the engine builds it, and what it hands to the writer -
    # the document the Overview reads.
    function Global:OrsStatus {
        param([string]$RunPath, $Plan, [switch]$WaveEnded)
        $global:OrsWritten = $null
        Mock -ModuleName VmMigrationFactory Write-VmfRunStatusDocument { $global:OrsWritten = $Live; $null }
        $s = InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; wavePlan = $Plan; ended = [bool]$WaveEnded } {
            Write-VmfRunStatus -RunPath $rp -Plan $wavePlan -Wave 'wave-demo' -RunId 'ors' -WaveEnded:$ended
        }
        @($global:OrsWritten.running).Count | Should -Be @($s.running).Count -Because 'the written document says what the snapshot says'
        $s
    }
}

AfterAll {
    Remove-Item -Path 'function:\OrsPlan', 'function:\OrsMachine', 'function:\OrsStatus' -ErrorAction SilentlyContinue
    Remove-Variable OrsWritten -Scope Global -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'OVERVIEW-RUNNING-STALE-1: the run status lists only machines that are moving' {
    BeforeEach {
        $script:rp = Join-Path $script:temp "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { Initialize-VmfRun -RunPath $rp -RunId 'ors' | Out-Null }
        $script:plan = OrsPlan -Count 1
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'THE REGRESSION: a MIGRATED machine whose worker still holds the lease is not running' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'MIGRATED' -LeaseAgeSeconds 0
        $s = OrsStatus -RunPath $script:rp -Plan $script:plan
        @($s.running).Count | Should -Be 0
        $s.stateCounts['MIGRATED'] | Should -Be 1 -Because 'the counts are untouched'
    }

    It 'no machine in a final state is running, for every final state of the state machine' {
        $terminal = InModuleScope VmMigrationFactory { (Get-VmfEngineStates).Terminal }
        @($terminal).Count | Should -BeGreaterThan 3
        $plan = OrsPlan -Count @($terminal).Count
        for ($i = 0; $i -lt @($terminal).Count; $i++) {
            OrsMachine -RunPath $script:rp -Entry $plan.entries[$i] -State @($terminal)[$i] -LeaseAgeSeconds 0
        }
        @((OrsStatus -RunPath $script:rp -Plan $plan).running).Count | Should -Be 0
    }

    It 'a lease past its expiry is not running: its worker stopped' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'CONVERTING' -LeaseAgeSeconds 1200
        @((OrsStatus -RunPath $script:rp -Plan $script:plan).running).Count | Should -Be 0
    }

    It 'a live lease on a moving machine is running, with its state and worker' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'CONVERTING' -LeaseAgeSeconds 60
        $s = OrsStatus -RunPath $script:rp -Plan $script:plan
        @($s.running).Count | Should -Be 1
        @($s.running)[0].state | Should -Be 'CONVERTING'
        @($s.running)[0].workerId | Should -Be 'ors-w1'
    }

    It 'a machine a worker has taken, with no state document yet, is running (PLANNED is a working state)' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State '' -LeaseAgeSeconds 0
        $s = OrsStatus -RunPath $script:rp -Plan $script:plan
        @($s.running).Count | Should -Be 1
        @($s.running)[0].state | Should -Be 'PLANNED'
    }

    It 'the wave''s last write lists no machine, even with a live lease on a working machine' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'CONVERTING' -LeaseAgeSeconds 0
        @((OrsStatus -RunPath $script:rp -Plan $script:plan -WaveEnded).running).Count | Should -Be 0
        @((OrsStatus -RunPath $script:rp -Plan $script:plan).running).Count | Should -Be 1 -Because 'only the last write'
    }

    It 'kill and resume: a worker killed after MIGRATED and before its lease went gives the same answer on every write' {
        # The worker checkpointed MIGRATED and died in its rollback-disk
        # cleanup: the lease stays, and its heartbeat stops.
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'MIGRATED' -LeaseAgeSeconds 30
        @((OrsStatus -RunPath $script:rp -Plan $script:plan).running).Count | Should -Be 0
        # The monitor writes again (a re-run of the same step).
        @((OrsStatus -RunPath $script:rp -Plan $script:plan).running).Count | Should -Be 0
        # The watchdog reaps the lease once it is old; the answer is the same.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:plan.entries[0].vmId } {
            Remove-VmfLease -RunPath $rp -VmId $id -Force
        }
        $s = OrsStatus -RunPath $script:rp -Plan $script:plan -WaveEnded
        @($s.running).Count | Should -Be 0
        $s.stateCounts['MIGRATED'] | Should -Be 1
    }

    It 'a restore''s hold is still not a running worker of the wave (RESTORE-ONE-AT-A-TIME-1)' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'CONVERTING' -LeaseAgeSeconds 0 -WorkerId 'restore:op-1'
        @((OrsStatus -RunPath $script:rp -Plan $script:plan).running).Count | Should -Be 0
    }

    It 'the wave passes its own lease limit to the status, the limit its watchdog uses' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $wave = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        ([regex]::Matches($wave, 'Write-VmfRunStatus [^\n]*-LeaseTimeoutSeconds \$LeaseTimeoutSeconds')).Count | Should -Be 2
    }

    It 'the limit decides: a lease younger than the limit is live, older is not' {
        OrsMachine -RunPath $script:rp -Entry $script:plan.entries[0] -State 'CONVERTING' -LeaseAgeSeconds 300
        $short = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; wavePlan = $script:plan } {
            Mock Write-VmfRunStatusDocument { $null }
            Write-VmfRunStatus -RunPath $rp -Plan $wavePlan -Wave 'wave-demo' -RunId 'ors' -LeaseTimeoutSeconds 120
        }
        @($short.running).Count | Should -Be 0
        $long = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; wavePlan = $script:plan } {
            Mock Write-VmfRunStatusDocument { $null }
            Write-VmfRunStatus -RunPath $rp -Plan $wavePlan -Wave 'wave-demo' -RunId 'ors' -LeaseTimeoutSeconds 900
        }
        @($long.running).Count | Should -Be 1
    }
}
