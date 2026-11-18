#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERF-TELEMETRY-ENGINE-1: the engine job records the time of the run store
# and Azure Resource Manager calls of each step of a machine.
#
# PERF-TELEMETRY-1 gave the service one VMF-CALLS line per call. The engine
# started no record, so the counting in the store seam did nothing there. Now
# the state machine starts the SAME record (Start-VmfCallTimings) at each step
# and writes its summary on the step's closing line in the activity log - the
# `calls` field of the ok, retry or fail line of that step, for that machine.
#
# WHY THE ACTIVITY LOG AND NOT THE CONSOLE. A worker's console output goes to
# a file in the container (Start-VmfWave redirects it, EVAL-M3), never to the
# Container Apps console log in Log Analytics. And the activity log line
# already names the machine and the step, so nothing needs a join. It adds no
# line and no append to the store: the field rides on a line the engine
# writes anyway, and nothing reaches the workspace's 0.2 GB daily cap.
#
# WHAT THE ENGINE RECORD NAMES. Only the run store calls go in `slow` and
# `ops`: each Azure operation already has its own `azureops:<name>` line with
# its time, and an ARM operation of more than a second is normal (a stop, a
# start), so it would push the store calls out of the ten kept. The ARM total
# is still counted, so `other` is the engine's own time. The redaction is the
# service's (ConvertTo-VmfCallTarget).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:sas = 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/state/vm-a.json?sv=2024-01-01&sig=SECRETSIGNATURE'
}

Describe 'PERF-TELEMETRY-ENGINE-1: the record of one step' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { throw 'The engine wrote a VMF-CALLS line. Its record goes on the step line.' }
    }
    AfterEach {
        InModuleScope VmMigrationFactory { $script:VmfCallTimings = $null; $script:VmfCallTimingInterimMs = 240000; $script:VmfCallTimingArmDepth = 0 }
    }

    It 'gives the step''s store, token and ARM totals and the engine''s own time, as the service''s record does' {
        InModuleScope VmMigrationFactory {
            Start-VmfStepCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/run.json' -Status 200 -DurationMs 30
            Add-VmfCallTiming -Kind store -Method PUT -Target 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/logs/events.jsonl?comp=appendblock' -Status 201 -DurationMs 40
            Add-VmfCallTiming -Kind token -Operation 'storage' -DurationMs 5
            Add-VmfCallTiming -Kind arm -Operation 'stopVm' -DurationMs 90000
            $data = Stop-VmfStepCallTimings
            $data.Keys | Should -Be @('calls')
            $c = $data.calls
            $c.v | Should -Be 1
            $c.store.n | Should -Be 2
            $c.store.ms | Should -Be 70
            $c.token.ms | Should -Be 5
            $c.arm.n | Should -Be 1
            $c.arm.ms | Should -Be 90000
            $c.ms | Should -BeGreaterOrEqual 0
            $c.Contains('other') | Should -BeTrue
            $c.Contains('partial') | Should -BeFalse -Because 'the engine never writes a part line, so the field says nothing'
        }
    }

    It 'names only run store calls in slow and ops - an Azure operation has its own activity line' {
        InModuleScope VmMigrationFactory {
            Start-VmfStepCallTimings
            Add-VmfCallTiming -Kind arm -Operation 'stopVm' -DurationMs 90000
            Add-VmfCallTiming -Kind arm -Method GET -Target '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-a' -Status 500 -DurationMs 2000
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/run.json' -Status 200 -DurationMs 1500
            Add-VmfCallTiming -Kind token -Operation 'storage' -DurationMs 1200
            $c = (Stop-VmfStepCallTimings).calls
            @($c.slow).Count | Should -Be 1
            $c.slow[0].k | Should -Be 'store'
            $c.slow[0].target | Should -Be 'p1/r1/run.json'
            @($c.ops.Keys) | Should -Be @('store read')
            $c.arm.n | Should -Be 2 -Because 'the ARM calls are still counted, so other is the engine''s own time'
            $c.arm.fail | Should -Be 1
            $c.token.n | Should -Be 1
        }
    }

    It 'keeps ten store calls even when many ARM operations take more than a second' {
        InModuleScope VmMigrationFactory {
            Start-VmfStepCallTimings
            foreach ($i in 1..12) { Add-VmfCallTiming -Kind arm -Operation "op$i" -DurationMs (5000 + $i) }
            foreach ($i in 1..10) { Add-VmfCallTiming -Kind store -Method GET -Target "https://acct.blob.core.windows.net/vmf-runs/p1/r1/s$i.json" -Status 200 -DurationMs (1000 + $i) }
            $c = (Stop-VmfStepCallTimings).calls
            @($c.slow).Count | Should -Be 10
            @($c.slow | Where-Object { $_.k -ne 'store' }).Count | Should -Be 0
            $c.slowDropped | Should -Be 0
        }
    }

    It 'never names a token, an account or a query string (the service''s redaction)' {
        InModuleScope VmMigrationFactory -Parameters @{ sas = $script:sas } {
            param($sas)
            Start-VmfStepCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target $sas -Status 403 -DurationMs 20
            $json = (Stop-VmfStepCallTimings) | ConvertTo-Json -Depth 10 -Compress
            $json | Should -Not -Match 'SECRETSIGNATURE'
            $json | Should -Not -Match 'sig='
            $json | Should -Not -Match 'acct'
            $json | Should -Match ([regex]::Escape('"target":"p1/r1/state/vm-a.json"'))
        }
    }

    It 'writes no part line, however long the step takes - a step of the engine can take an hour' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingInterimMs = 0
            Start-VmfStepCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/run.json' -Status 200 -DurationMs 30
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/run.json' -Status 200 -DurationMs 30
            $null = Stop-VmfStepCallTimings
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfCallTimingLine -Times 0 -Exactly
    }

    It 'ends the record, so nothing is counted after the step and the next step starts at zero' {
        InModuleScope VmMigrationFactory {
            Start-VmfStepCallTimings
            Add-VmfCallTiming -Kind store -Method GET -Target 'https://acct.blob.core.windows.net/vmf-runs/p1/r1/run.json' -Status 200 -DurationMs 30
            $script:VmfCallTimingArmDepth = 2
            $null = Stop-VmfStepCallTimings
            $script:VmfCallTimings | Should -BeNullOrEmpty
            $script:VmfCallTimingArmDepth | Should -Be 0 -Because 'an operation a lost lease stopped leaves no depth behind for the next record'
            $script:VmfCallTimingArmDepth = 3
            Start-VmfStepCallTimings
            $script:VmfCallTimingArmDepth | Should -Be 0
            (Stop-VmfStepCallTimings).calls.store.n | Should -Be 0
        }
    }

    It 'gives an empty table, and never throws, when no record is open' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimings = $null
            $data = Stop-VmfStepCallTimings
            $data | Should -BeOfType [hashtable]
            $data.Count | Should -Be 0
        }
    }

    It 'gives an empty table, and never throws, when the record is broken' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimings = @{ Kinds = 'not a table' }
            $data = Stop-VmfStepCallTimings
            $data.Count | Should -Be 0
            $script:VmfCallTimings | Should -BeNullOrEmpty
        }
    }

    It 'never fails the step when the record cannot start' {
        Mock -ModuleName VmMigrationFactory Start-VmfCallTimings { throw 'no record' }
        InModuleScope VmMigrationFactory { { Start-VmfStepCallTimings } | Should -Not -Throw }
    }
}

Describe 'PERF-TELEMETRY-ENGINE-1: the service''s record is as before' {
    AfterEach { InModuleScope VmMigrationFactory { $script:VmfCallTimings = $null } }

    It 'a record the service starts still names ARM calls and token waits, and writes its part line' {
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { }
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            Add-VmfCallTiming -Kind arm -Operation 'stopVm' -DurationMs 5000
            Add-VmfCallTiming -Kind token -Operation 'storage' -DurationMs 5
            $s = Get-VmfCallTimingSummary
            @($s.slow).Count | Should -Be 1
            $s.slow[0].k | Should -Be 'arm'
            @($s.ops.Keys | Sort-Object) | Should -Be @('arm stopVm', 'token storage')
            $s.Contains('partial') | Should -BeTrue
            $script:VmfCallTimingInterimMs = 0
            Add-VmfCallTiming -Kind arm -Operation 'startVm' -DurationMs 5
            $script:VmfCallTimingInterimMs = 240000
        }
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfCallTimingLine -Times 1 -Exactly
    }
}
