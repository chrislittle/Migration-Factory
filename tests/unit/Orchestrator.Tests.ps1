#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:workerPath = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Workers' 'worker.ps1'))

    # TEMP-LITTER-1: the run folders here were always taken away - and the
    # CLAIM folder beside them was not. A claim lives NEXT TO the run on
    # purpose (RUN-CLAIM-1: two runs in one store share it), so a run folder
    # made straight in the temp folder puts vmf-claims in the temp folder too,
    # as a sibling the test never knew it made. The run folders go inside one
    # folder this file owns, so the claim lands inside it as well.
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'orch'

    function Global:NewWavePlan {
        param([int]$Count = 3, [string]$Wave = 'lab-1', [string]$AvSet = '')
        $entries = for ($i = 1; $i -le $Count; $i++) {
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion)
                vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-w/providers/Microsoft.Compute/virtualMachines/wvm$i"
                wave = $Wave; ring = 'lab'; appGroup = "wvm$i"
                assessment = [pscustomobject]@{
                    classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'
                    platformManaged = $false; availabilitySetId = $AvSet
                }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'
                policy = [pscustomobject]@{ capacityGate = 'BestEffort' }
            }
        }
        [pscustomobject]@{ schemaVersion = 1; entries = @($entries) }
    }
}

AfterAll {
    Remove-Item -Path 'function:\NewWavePlan' -ErrorAction SilentlyContinue
    Remove-VmfTestTemp   # TEMP-LITTER-1; throws if anything survives
}

Describe 'VmfOrchestrator' {
    BeforeEach {
        $script:runPath = Join-Path $script:temp "orch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'orch-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    Context 'Lease selection (Get-VmfNextWaveVm)' {
        It 'each call claims a distinct VM; exhaustion returns null' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 2
                $a = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w1'
                $b = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w2'
                $a.Entry.vmId | Should -Not -Be $b.Entry.vmId
                Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w3' | Should -BeNullOrEmpty
            }
        }

        It 'PREP-ROLLBACK-1 (review 2): a halted wave takes no new machine, but still takes one left mid-rollback' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 2
                foreach ($e in $plan.entries) { New-VmfStateDoc -RunPath $rp -RunId 'orch-test' -VmId $e.vmId | Out-Null }
                Set-VmfRollbackPending -Context @{ RunPath = $rp; VmId = $plan.entries[1].vmId } -Kind 'disks' -State 'GUEST_PREP' -ReasonCode 'guestPrepBlocked' -Detail 'x'
                Set-VmfWaveHalt -RunPath $rp -Reason 'breaker'
                $claim = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w1'
                $claim.Entry.vmId | Should -Be $plan.entries[1].vmId
                Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w2' | Should -BeNullOrEmpty -Because 'nothing new starts in a halted wave'
            }
        }

        It 'skips VMs already in a terminal state' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 2
                New-VmfStateDoc -RunPath $rp -RunId 'orch-test' -VmId $plan.entries[0].vmId | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $plan.entries[0].vmId -NewState 'MIGRATED' -Outcome ok | Out-Null
                $claim = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w1'
                $claim.Entry.vmId | Should -Be $plan.entries[1].vmId
            }
        }

        It 'serializes availability-set members via group locks' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 3 -AvSet '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/availabilitySets/as1'
                $a = Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w1'
                $a | Should -Not -BeNullOrEmpty
                $a.GroupLockId | Should -Match 'group-avset'
                # second worker: all remaining members blocked by the group lock
                Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w2' | Should -BeNullOrEmpty
                # release both -> next member becomes leasable
                Remove-VmfLease -RunPath $rp -VmId $a.Entry.vmId -WorkerId 'w1'
                Remove-VmfLease -RunPath $rp -VmId $a.GroupLockId -WorkerId 'w1'
                (Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w2') | Should -Not -BeNullOrEmpty
            }
        }

        It 'grants nothing while the wave is halted' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 2
                Set-VmfWaveHalt -RunPath $rp -Reason 'test'
                Get-VmfNextWaveVm -RunPath $rp -Plan $plan -Wave 'lab-1' -WorkerId 'w1' | Should -BeNullOrEmpty
            }
        }
    }

    Context 'Circuit breaker' {
        It 'trips on consecutive failures, not on interleaved successes' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 6
                $states = @('MIGRATED', 'FAILED_ROLLED_BACK', 'MIGRATED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK')
                for ($i = 0; $i -lt 6; $i++) {
                    New-VmfStateDoc -RunPath $rp -RunId 'orch-test' -VmId $plan.entries[$i].vmId | Out-Null
                    Add-VmfStateTransition -RunPath $rp -VmId $plan.entries[$i].vmId -NewState $states[$i] -Outcome ok | Out-Null
                    Start-Sleep -Milliseconds 30   # distinct timestamps for ordering
                }
                $breaker = Test-VmfCircuitBreaker -RunPath $rp -Plan $plan -Wave 'lab-1'
                $breaker.Tripped | Should -BeTrue
                $breaker.Consecutive | Should -Be 3
            }
        }

        It 'stays green on healthy outcomes' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 4
                foreach ($entry in $plan.entries) {
                    New-VmfStateDoc -RunPath $rp -RunId 'orch-test' -VmId $entry.vmId | Out-Null
                    Add-VmfStateTransition -RunPath $rp -VmId $entry.vmId -NewState 'MIGRATED' -Outcome ok | Out-Null
                }
                (Test-VmfCircuitBreaker -RunPath $rp -Plan $plan -Wave 'lab-1').Tripped | Should -BeFalse
            }
        }
    }

    Context 'Run status' {
        It 'produces a schema-shaped snapshot with counts and running leases' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                $plan = NewWavePlan -Count 3
                New-VmfStateDoc -RunPath $rp -RunId 'orch-test' -VmId $plan.entries[0].vmId | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $plan.entries[0].vmId -NewState 'MIGRATED' -Outcome ok | Out-Null
                New-VmfLease -RunPath $rp -VmId $plan.entries[1].vmId -WorkerId 'w9' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'orch-test' -VmId $plan.entries[1].vmId | Out-Null

                $status = Write-VmfRunStatus -RunPath $rp -Plan $plan -Wave 'lab-1' -RunId 'orch-test' -ThrottleLimit 2
                $status.stateCounts['MIGRATED'] | Should -Be 1
                $status.stateCounts['PLANNED'] | Should -Be 2
                @($status.running).Count | Should -Be 1
                @($status.running)[0].workerId | Should -Be 'w9'
                Test-Path (Join-Path $rp 'run-status.json') | Should -BeTrue
            }
        }
    }
}

Describe 'Multi-process wave execution (real worker processes, fake engine)' {
    It 'two real workers drain a 4-VM wave via leases without overlap' {
        $runPath = Join-Path $script:temp "mp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $runPath } {
                Initialize-VmfRun -RunPath $rp -RunId 'mp-test' | Out-Null
            }
            $plan = NewWavePlan -Count 4
            $planPath = Join-Path $runPath 'plan.json'
            $plan | ConvertTo-Json -Depth 24 | Set-Content $planPath

            # Fake engine: runs INSIDE the worker process (module already loaded);
            # sleeps briefly to force lease contention, then lands MIGRATED.
            $fakeEngine = Join-Path $runPath 'fake-engine.ps1'
            @'
param($EntryJson, $RunPath, $RunId)
$entry = $EntryJson | ConvertFrom-Json -Depth 24
Start-Sleep -Milliseconds (Get-Random -Minimum 300 -Maximum 900)
& (Get-Module VmMigrationFactory) {
    param($id, $rp, $rid)
    New-VmfStateDoc -RunPath $rp -RunId $rid -VmId $id | Out-Null
    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
} $entry.vmId $RunPath $RunId
'@ | Set-Content $fakeEngine

            $worker = $script:workerPath
            $env:VMF_TEST_ENGINE = $fakeEngine
            try {
                $procs = 1..2 | ForEach-Object {
                    Start-Process pwsh -PassThru -WindowStyle Hidden -ArgumentList @(
                        '-NoProfile', '-File', $worker,
                        '-RunPath', $runPath, '-PlanPath', $planPath, '-Wave', 'lab-1',
                        '-RunId', 'mp-test', '-WorkerId', "test-w$_",
                        # CI-SPEED-2: the worker's idle wait is 30 seconds in
                        # production, and with two workers over four machines
                        # one of them always meets it. That single sleep was 30
                        # of this file's 45 seconds. One second here keeps the
                        # contention entirely real - two processes, real leases,
                        # a real wait that really has to be waited out - and
                        # gives the suite back half a minute.
                        '-IdleWaitSeconds', '1'
                    )
                }
                $deadline = (Get-Date).AddSeconds(90)
                while ((Get-Date) -lt $deadline -and @($procs | Where-Object { -not $_.HasExited }).Count -gt 0) {
                    Start-Sleep -Milliseconds 500
                }
                @($procs | Where-Object { -not $_.HasExited }).Count | Should -Be 0 -Because 'workers must drain and exit'
            }
            finally { Remove-Item Env:\VMF_TEST_ENGINE -ErrorAction SilentlyContinue }

            InModuleScope VmMigrationFactory -Parameters @{ rp = $runPath; plan = $plan } {
                foreach ($entry in $plan.entries) {
                    (Read-VmfStateDoc -RunPath $rp -VmId $entry.vmId).state | Should -Be 'MIGRATED'
                }
                # all leases released
                @(Get-ChildItem (Join-Path $rp 'leases') -Filter '*.lease').Count | Should -Be 0
                # both workers actually participated (leases were contended, not serialized on one)
                $events = Read-VmfEvents -RunPath $rp -Step 'worker'
                $workerIds = @($events | ForEach-Object { $_.detail -replace '^leased by ', '' } | Sort-Object -Unique)
                @($workerIds).Count | Should -BeGreaterOrEqual 1
            }
        }
        finally {
            if (Test-Path $runPath) { Remove-Item $runPath -Recurse -Force }
        }
    }
}

# CI-SPEED-2, 2026-09-09. One test was 33 of this file's 45 seconds, and the
# file was the largest in the suite. It was not the test: the WORKER waits 30
# seconds when every machine is held by another worker, and with two workers
# over four machines one of them always meets that wait.
#
# The wait is now a parameter. Production keeps 30; the test asks for 1. The
# contention stays entirely real - two spawned processes, real leases, a real
# wait that really has to be waited out - and the file runs in 16 seconds.
#
# The danger with a seam like this is somebody "tidying" the default, so the
# default is what these tests are about.
Describe 'CI-SPEED-2: the worker''s idle wait is injectable, and production is unchanged' {

    BeforeAll {
        # This file's own BeforeAll defines $script:workerPath, not a repo root.
        # Reading a path that does not exist made all four of these fail before
        # any mutation - which is how it was caught.
        $script:workerSource = Get-Content $script:workerPath -Raw
    }

    It 'the worker takes an idle wait parameter' {
        $script:workerSource | Should -Match '\[Parameter\(\)\]\[int\]\$IdleWaitSeconds'
    }

    It 'and its DEFAULT IS STILL THE PRODUCTION VALUE of 30 seconds' {
        # If this ever reads 1, a real wave polls its lease store 30 times
        # harder for nothing. The test's speed must not reach production.
        $script:workerSource | Should -Match '\$IdleWaitSeconds = 30'
    }

    It 'the sleep uses the parameter rather than a literal' {
        $script:workerSource | Should -Match 'Start-Sleep -Seconds \$IdleWaitSeconds'
        $script:workerSource | Should -Not -Match 'Start-Sleep -Seconds 30'
    }

    It 'and the multi-process test asks for a short one' {
        $tests = Get-Content $PSCommandPath -Raw
        $tests | Should -Match "'-IdleWaitSeconds', '1'"
    }
}
