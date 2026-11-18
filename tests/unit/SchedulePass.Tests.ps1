#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
TIMER-PASS-LIMIT-1: the service's five-minute schedule pass fits the 5-minute
limit of an Azure Functions call, and no run waits for ever.

MEASURED (PERF-ANALYSIS-1, FACADE-TIMER-QUEUE-1): ScheduleRunner took a median
of 77 s a pass on 2026-11-02 and grows with the store; two passes reached the
5-minute limit, which restarts the worker. It walked the runs in one fixed
order, so on a store that always needs more than 5 minutes the same runs came
last every time and were never checked: a scheduled wave there did not start,
and a stopped wave or restore there did not start again. Nothing said so.

The same mechanism as the daily cleanup (PERF-RETENTION-TIMEOUT-1): a time
budget, a record at the store root with the run the pass reached, and the next
pass going on from there.

SCHEDULE-PASS-DUE-1 (schema 2 of the record): a pass checks only the runs of
the due record (schedule-due.json), and once an hour every run (the sweep).
ScheduleDue.Tests.ps1 holds the due record's own rules and the store calls a
pass makes. These tests hold the rules of the pass (with a fake clock) and the
real script, run on a store on disk.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'schedpass'
    $script:schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'
    $script:schema = Join-Path $script:repoRoot 'schemas' 'schedule-status.schema.json'
    $script:dueSchema = Join-Path $script:repoRoot 'schemas' 'schedule-due.schema.json'
    $script:at = [datetime]::new(2026, 11, 3, 10, 5, 0, [System.DateTimeKind]::Utc)
}
AfterAll { Remove-VmfTestTemp }

Describe 'TIMER-PASS-LIMIT-1: the time budget, on a fake clock' {
    It 'a pass stops starting runs at 210 seconds, well inside the 5-minute limit' {
        InModuleScope VmMigrationFactory -Parameters @{ at = $script:at } {
            Test-VmfPassTimeLeft -StartedUtc $at -NowUtc $at.AddSeconds(10) | Should -BeTrue
            Test-VmfPassTimeLeft -StartedUtc $at -NowUtc $at.AddSeconds(209) | Should -BeTrue
            Test-VmfPassTimeLeft -StartedUtc $at -NowUtc $at.AddSeconds(211) | Should -BeFalse
            Test-VmfPassTimeLeft -StartedUtc $at -NowUtc $at.AddSeconds(300) | Should -BeFalse
            (Get-Command Test-VmfPassTimeLeft).Parameters['BudgetSeconds'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateRangeAttribute] }).MaxRange |
                Should -BeLessThan 300 -Because 'a budget at the limit is no budget'
        }
    }

    It 'with no clock given it reads the real one' {
        InModuleScope VmMigrationFactory {
            Test-VmfPassTimeLeft -StartedUtc ([datetime]::UtcNow.AddSeconds(-5)) | Should -BeTrue
            Test-VmfPassTimeLeft -StartedUtc ([datetime]::UtcNow.AddSeconds(-400)) | Should -BeFalse
        }
    }

    It 'the daily cleanup asks the same rule' {
        Mock -ModuleName VmMigrationFactory Test-VmfPassTimeLeft { $false }
        InModuleScope VmMigrationFactory { Test-VmfRetentionTimeLeft -StartedUtc ([datetime]::UtcNow) | Should -BeFalse }
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfPassTimeLeft -Times 1 -Exactly
    }
}

Describe 'SCHEDULE-PASS-DUE-1: which runs a pass checks, and the record it starts with' {
    BeforeAll {
        $script:Start = { param($prev, [string[]]$due, [string[]]$ids, [bool]$sweep = $true)
            InModuleScope VmMigrationFactory -Parameters @{ p = $prev; d = $due; i = $ids; s = $sweep; n = $script:at } {
                param($p, $d, $i, $s, $n) New-VmfSchedulePassStart -Previous $p -DueRunIds $d -RunIds $i -Sweep:$s -NowUtc $n }
        }
        $script:ids = @('r3', 'r1', 'p1/r5', 'r4', 'r2')
        # A record of schema 2. -Open: a sweep is open at $cursor. -On: the
        # host stopped that pass while it checked this run.
        $script:Rec = { param([string]$cursor, [switch]$Open, [string]$On, [int]$stops = 0, [string]$Last = '2026-11-03T09:30:00.0000000Z')
            [pscustomobject]@{ schemaVersion = 2; lastPassUtc = '2026-11-03T10:00:00.0000000Z'
                finishedUtc = $(if ($On) { $null } else { '2026-11-03T10:03:30.0000000Z' })
                resumeAtRunId = $(if ($cursor) { $cursor } else { $null })
                checkingRunId = $(if ($On) { $On } else { $null }); checkingStops = $stops
                sweepStartedUtc = $(if ($Open) { '2026-11-03T09:55:00.0000000Z' } else { $null })
                lastSweepUtc = $(if ($Last) { $Last } else { $null }) }
        }
    }

    It 'no record: a sweep of every run, in ordinal order of run id' {
        $s = & $script:Start $null @() $script:ids
        @($s.DueRuns).Count | Should -Be 0
        $s.SweepRuns | Should -Be @('p1/r5', 'r1', 'r2', 'r3', 'r4')
        $s.Record.schemaVersion | Should -Be 2
        $s.Record.resumeAtRunId | Should -Be 'p1/r5'
        $s.Record.sweepStartedUtc | Should -Be $script:at.ToString('o') -Because 'a new sweep starts now'
        $s.Record.finishedUtc | Should -BeNullOrEmpty -Because 'written at once, it says a pass works now'
        $s.Record.runsInStore | Should -Be 5
        $s.PassedOverRunId | Should -BeNullOrEmpty
        Test-Json -Json ($s.Record | ConvertTo-Json -Depth 6) -SchemaFile $script:schema | Should -BeTrue
    }

    It 'no sweep: only the due runs, in ordinal order, and the last sweep is kept' {
        $s = & $script:Start (& $script:Rec $null) @('r4', 'r2') @() $false
        $s.DueRuns | Should -Be @('r2', 'r4')
        @($s.SweepRuns).Count | Should -Be 0
        $s.Record.runsDue | Should -Be 2
        $s.Record.runsInStore | Should -Be 0
        $s.Record.sweepStartedUtc | Should -BeNullOrEmpty
        $s.Record.lastSweepUtc | Should -Be '2026-11-03T09:30:00.0000000Z'
        $s.Record.resumeAtRunId | Should -BeNullOrEmpty
    }

    It 'a run that is due is not checked again in the sweep of the same pass' {
        $s = & $script:Start $null @('r2') $script:ids
        $s.DueRuns | Should -Be @('r2')
        $s.SweepRuns | Should -Be @('p1/r5', 'r1', 'r3', 'r4')
    }

    It 'an open sweep goes on from its run to the end of the list: it does not go round' {
        $s = & $script:Start (& $script:Rec 'r3' -Open) @() $script:ids
        $s.SweepRuns | Should -Be @('r3', 'r4')
        $s.Record.sweepStartedUtc | Should -Be '2026-11-03T09:55:00.0000000Z' -Because 'the sweep keeps the time it started'
    }

    It 'the run of an open sweep was deleted: the sweep goes on at the next name' {
        $s = & $script:Start (& $script:Rec 'r2a' -Open) @() $script:ids
        $s.SweepRuns | Should -Be @('r3', 'r4')
    }

    It 'a sweep that ended: the next sweep starts at the first run' {
        $s = & $script:Start (& $script:Rec 'r3') @() $script:ids
        $s.SweepRuns | Should -Be @('p1/r5', 'r1', 'r2', 'r3', 'r4')
        $s.Record.sweepStartedUtc | Should -Be $script:at.ToString('o')
    }

    It 'the host stopped the last pass on a run of the sweep: the sweep goes on at it, and counts the stop' {
        $s = & $script:Start (& $script:Rec 'r3' -Open -On 'r3') @() $script:ids
        $s.SweepRuns[0] | Should -Be 'r3'
        $s.StoppedRunId | Should -Be 'r3'
        $s.StoppedCount | Should -Be 1
        $s.PassedOverRunId | Should -BeNullOrEmpty
    }

    It 'the host stopped the last pass on a due run: it is checked last of the due runs' {
        $s = & $script:Start (& $script:Rec $null -On 'r2') @('r1', 'r2', 'r3') @() $false
        $s.DueRuns | Should -Be @('r1', 'r3', 'r2') -Because 'one run the host stops on must not keep the other due runs from their check'
        $s.StoppedCount | Should -Be 1
    }

    It 'two stops on one run: it is passed over for this pass only, in the due runs and in the sweep' {
        $s = & $script:Start (& $script:Rec 'r3' -Open -On 'r3' 1) @('r3', 'r1') $script:ids
        $s.PassedOverRunId | Should -Be 'r3'
        $s.DueRuns | Should -Be @('r1')
        $s.SweepRuns | Should -Be @('r4')
        $s.Record.passedOverRunId | Should -Be 'r3'
        $s.StoppedRunId | Should -BeNullOrEmpty
        $s.StoppedCount | Should -Be 0 -Because 'a stop on r3 is not a stop on another run'
    }

    It 'a stop against a run that was deleted since is not counted against another' {
        $s = & $script:Start (& $script:Rec 'r2a' -Open -On 'r2a' 1) @() $script:ids
        $s.PassedOverRunId | Should -BeNullOrEmpty
        $s.StoppedRunId | Should -BeNullOrEmpty
        $s.SweepRuns[0] | Should -Be 'r3'
    }

    It 'a record of schema 1 is read as no record: the first pass of schema 2 checks every run' {
        $v1 = [pscustomobject]@{ schemaVersion = 1; finishedUtc = $null; resumeAtRunId = 'r3'; resumeStops = 1 }
        $s = & $script:Start $v1 @() $script:ids
        $s.SweepRuns | Should -Be @('p1/r5', 'r1', 'r2', 'r3', 'r4')
        $s.PassedOverRunId | Should -BeNullOrEmpty
        InModuleScope VmMigrationFactory -Parameters @{ p = $v1; n = $script:at } { param($p, $n)
            Test-VmfScheduleSweepOpen -Previous $p -DueUsable $true -NowUtc $n | Should -BeTrue }
    }

    It 'an empty store: no run, and a record that says so' {
        $s = & $script:Start (& $script:Rec 'r3' -Open) @() @()
        @($s.SweepRuns).Count | Should -Be 0
        $s.Record.resumeAtRunId | Should -BeNullOrEmpty
        $s.Record.runsInStore | Should -Be 0
    }

    # Security review: a record that parses but holds a field of the wrong
    # type made every later pass stop before its first run, for ever.
    It 'a record with a field of the wrong type is read as no record: <Why>' -ForEach @(
        @{ Why = 'schemaVersion is text'; Json = '{"schemaVersion":"x","resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1}' }
        @{ Why = 'checkingStops is text'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":"abc"}' }
        @{ Why = 'checkingStops is past Int32'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":99999999999}' }
        @{ Why = 'checkingStops is below zero'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":-3}' }
        @{ Why = 'checkingStops is a fraction'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1.5}' }
        @{ Why = 'schemaVersion is the text 2'; Json = '{"schemaVersion":"2","resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1}' }
        @{ Why = 'schemaVersion is a fraction'; Json = '{"schemaVersion":2.5,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1}' }
        @{ Why = 'resumeAtRunId is a number'; Json = '{"schemaVersion":2,"resumeAtRunId":5,"finishedUtc":null,"checkingRunId":"r3","checkingStops":1}' }
        @{ Why = 'checkingRunId is an object'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":{"a":1},"checkingStops":1}' }
        @{ Why = 'finishedUtc is a number'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":7,"checkingRunId":"r3","checkingStops":1}' }
        @{ Why = 'sweepStartedUtc is not a time'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1,"sweepStartedUtc":"soon"}' }
        @{ Why = 'lastSweepUtc is a number'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1,"lastSweepUtc":3}' }
        @{ Why = 'the record is a list'; Json = '[1,2]' }
        @{ Why = 'the record is a number'; Json = '5' }
        @{ Why = 'the record is text'; Json = '"r3"' }
    ) {
        $prev = $Json | ConvertFrom-Json -DateKind String
        $s = & $script:Start $prev @() $script:ids
        $s.SweepRuns | Should -Be @('p1/r5', 'r1', 'r2', 'r3', 'r4')
        $s.StoppedCount | Should -Be 0
        $s.PassedOverRunId | Should -BeNullOrEmpty
        Test-Json -Json ($s.Record | ConvertTo-Json -Depth 6) -SchemaFile $script:schema | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ p = $prev; n = $script:at } { param($p, $n)
            Test-VmfScheduleSweepOpen -Previous $p -DueUsable $true -NowUtc $n | Should -BeTrue -Because 'a record that cannot be used starts a sweep' }
    }

    It 'a record whose field cannot be read at all does not stop the pass, and counts no stop' {
        $prev = [pscustomobject]@{ schemaVersion = 2; finishedUtc = $null; checkingStops = 1; resumeAtRunId = 'r3' }
        $prev | Add-Member -MemberType ScriptProperty -Name checkingRunId -Value { throw 'the field cannot be read' }
        { & $script:Start $prev @() $script:ids } | Should -Not -Throw
        $s = & $script:Start $prev @() $script:ids
        $s.SweepRuns | Should -Be @('p1/r5', 'r1', 'r2', 'r3', 'r4')
        $s.StoppedCount | Should -Be 0
    }

    It 'a count of stops that is large but whole is read as enough to pass the run over' {
        $prev = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":50,"sweepStartedUtc":"2026-11-03T09:55:00Z"}' | ConvertFrom-Json -DateKind String
        $s = & $script:Start $prev @() $script:ids
        $s.PassedOverRunId | Should -Be 'r3'
    }

    It 'a run listed twice is checked once' {
        $s = & $script:Start $null @('r2', 'r2') @('r1', 'r2', 'r1')
        $s.DueRuns | Should -Be @('r2')
        $s.SweepRuns | Should -Be @('r1')
    }
}

Describe 'TIMER-PASS-LIMIT-1: the put-back pass reads the machine records again when they are old' {
    It 'records read in the last 30 seconds are given, as they are' {
        $docs = @([pscustomobject]@{ vmId = 'a' }, [pscustomobject]@{ vmId = 'b' })
        $got = InModuleScope VmMigrationFactory -Parameters @{ d = $docs; at = $script:at } { param($d, $at)
            Select-VmfScheduleStateDocs -StateDocs $d -ReadUtc $at -NowUtc $at.AddSeconds(29) }
        @($got).Count | Should -Be 2
    }

    It 'records read longer ago are not given, so the pass reads them again just before it decides' {
        $docs = @([pscustomobject]@{ vmId = 'a' })
        $got = InModuleScope VmMigrationFactory -Parameters @{ d = $docs; at = $script:at } { param($d, $at)
            Select-VmfScheduleStateDocs -StateDocs $d -ReadUtc $at -NowUtc $at.AddSeconds(31) }
        $null -eq $got | Should -BeTrue
    }

    It 'no records read stays no records read' {
        $got = InModuleScope VmMigrationFactory -Parameters @{ at = $script:at } { param($at)
            Select-VmfScheduleStateDocs -StateDocs $null -ReadUtc $at -NowUtc $at }
        $null -eq $got | Should -BeTrue
    }

    It 'a run with no machine record is an empty list, not "read them yourself"' {
        $got = InModuleScope VmMigrationFactory -Parameters @{ at = $script:at } { param($at)
            , (Select-VmfScheduleStateDocs -StateDocs @() -ReadUtc $at -NowUtc $at) }
        $null -eq $got | Should -BeFalse
        @($got).Count | Should -Be 0
    }

    It 'the script gives the put-back pass the records through this rule, with the time they were read' {
        $code = Get-VmfCodeOnly -Path $script:schedule
        $code | Should -Match '\$stateDocsReadUtc = \(Get-Date\)\.ToUniversalTime\(\)\s*\r?\n\s*try \{ \$stateDocs = @\(Get-VmfFacadeRunStateDocs -StorePath \$store\) \}'
        $code | Should -Match 'Select-VmfScheduleStateDocs -StateDocs \$d -ReadUtc \$t'
        $code | Should -Match 'Invoke-VmfFacadeResumeStalledPutBacks -StorePath \$store -RunId \$runId -StateDocs \$putBackDocs'
    }
}

# The real script, on a store on disk: five migrations, with the per-run
# checks replaced by mocks that write what they saw to a file (a Mock body runs
# in a scope of its own).
Describe 'SCHEDULE-PASS-DUE-1: the schedule pass, run' {
    BeforeAll {
        $script:oldStore = $env:VMF_STORE_PATH
        $script:Seed = {
            $root = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            foreach ($run in 'r1', 'r2', 'r3', 'r4', 'r5') {
                $rp = Join-Path $root $run
                New-Item -ItemType Directory -Path $rp -Force | Out-Null
                Set-Content -Path (Join-Path $rp 'run.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 1; runId = $run; kind = 'migration' } | ConvertTo-Json)
                Set-Content -Path (Join-Path $rp 'plan.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 9; runId = $run; entries = @() } | ConvertTo-Json)
            }
            $env:VMF_STORE_PATH = $root
            $env:VMF_TEST_SEEN = Join-Path $script:temp "seen-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
            $root
        }
        $script:Seen = { @(Get-Content $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue) }
        $script:RecordText = { param($root) Get-Content (Join-Path $root 'schedule-status.json') -Raw }
        $script:Record = { param($root) & $script:RecordText $root | ConvertFrom-Json -DateKind String }
        $script:DueText = { param($root) Get-Content (Join-Path $root 'schedule-due.json') -Raw }
        $script:DueIds = { param($root) @((& $script:DueText $root | ConvertFrom-Json -DateKind String).runs | ForEach-Object { [string]$_.runId }) }
        $script:Pass = { param($runsAllowed)
            $env:VMF_TEST_RUNS_LEFT = [string]$runsAllowed
            Remove-Item $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue
            & $script:schedule -Timer $null 3>$null 6>$null
        }
        # The last sweep an hour and a half ago: the next pass sweeps.
        $script:AgeSweep = { param($root)
            $rec = Get-Content (Join-Path $root 'schedule-status.json') -Raw | ConvertFrom-Json -DateKind String
            $rec.lastSweepUtc = [datetime]::UtcNow.AddMinutes(-90).ToString('o')
            $rec | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $root 'schedule-status.json') -Encoding utf8NoBOM
        }
        # A machine record, as a wave leaves it.
        $script:State = { param($root, $run, [string]$state)
            $dir = Join-Path $root $run 'state'
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            @{ vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$run-a"; state = $state } |
                ConvertTo-Json | Set-Content (Join-Path $dir "$run-a.json") -Encoding utf8NoBOM
        }
        $script:Mark = { param($root, $run, [int]$hold = 0)
            InModuleScope VmMigrationFactory -Parameters @{ r = $root; i = $run; h = $hold } { param($r, $i, $h)
                Add-VmfScheduleDueRun -StorePath $r -RunId $i -Reason 'engine' -HoldMinutes $h | Should -BeTrue }
        }
    }
    AfterAll {
        if ($null -eq $script:oldStore) { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue } else { $env:VMF_STORE_PATH = $script:oldStore }
        Remove-Item Env:\VMF_TEST_SEEN, Env:\VMF_TEST_RUNS_LEFT, Env:\VMF_TEST_CAPTURE, Env:\VMF_TEST_CAPTURE_RUN, Env:\VMF_TEST_MARK_RUN, Env:\VMF_TEST_LISTED -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Mock Invoke-VmfFacadeReleaseDueSchedules {
            Add-Content -Path $env:VMF_TEST_SEEN -Value $RunId
            # The moment the host could stop the pass: what the store says then.
            if ($env:VMF_TEST_CAPTURE -and $RunId -eq $env:VMF_TEST_CAPTURE_RUN) {
                Copy-Item (Join-Path $env:VMF_STORE_PATH 'schedule-status.json') $env:VMF_TEST_CAPTURE -Force
                $dueFile = Join-Path $env:VMF_STORE_PATH 'schedule-due.json'
                if (Test-Path $dueFile) { Copy-Item $dueFile "$($env:VMF_TEST_CAPTURE).due" -Force }
            }
            # An engine start marks the run while the pass checks it.
            if ($env:VMF_TEST_MARK_RUN -and $RunId -eq $env:VMF_TEST_MARK_RUN) {
                & (Get-Module VmMigrationFactory) { param($r, $i) Add-VmfScheduleDueRun -StorePath $r -RunId $i -Reason 'engine' | Out-Null } $env:VMF_STORE_PATH $RunId
            }
            @()
        }
        Mock Get-VmfFacadeRunStateDocs { @() }
        Mock Invoke-VmfFacadeResumeStalledWaves { @() }
        Mock Invoke-VmfFacadeRemoveEndedWaveHolds { @() }
        Mock Invoke-VmfFacadeResumeStalledPutBacks { @() }
        Mock Invoke-VmfFacadeContinuePlan { $null }
        # Azure, faked: no execution of the engine runs.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        # The budget, counted in runs: the clock of a test is not the clock of
        # the service.
        Mock -ModuleName VmMigrationFactory Test-VmfPassTimeLeft {
            $left = [int]$env:VMF_TEST_RUNS_LEFT
            $env:VMF_TEST_RUNS_LEFT = [string]($left - 1)
            $left -gt 0
        }
        Remove-Item Env:\VMF_TEST_CAPTURE, Env:\VMF_TEST_CAPTURE_RUN, Env:\VMF_TEST_MARK_RUN -ErrorAction SilentlyContinue
    }

    It 'the first pass checks every run once and writes both records; the next pass checks no run and lists none' {
        $root = & $script:Seed
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        $rec = & $script:Record $root
        $rec.runsChecked | Should -Be 5
        $rec.runsNotChecked | Should -Be 0
        $rec.resumeAtRunId | Should -BeNullOrEmpty
        $rec.sweepStartedUtc | Should -BeNullOrEmpty -Because 'the sweep ended'
        $rec.lastSweepUtc | Should -Not -BeNullOrEmpty
        $rec.finishedUtc | Should -Not -BeNullOrEmpty
        $rec.slowestRun.runId | Should -BeIn @('r1', 'r2', 'r3', 'r4', 'r5')
        Test-Json -Json (& $script:RecordText $root) -SchemaFile $script:schema | Should -BeTrue
        Test-Json -Json (& $script:DueText $root) -SchemaFile $script:dueSchema | Should -BeTrue
        @(& $script:DueIds $root).Count | Should -Be 0 -Because 'no run has anything due'

        Mock Get-VmfFacadeRunIds { throw 'a pass with nothing due must not list the runs' }
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty
        Should -Invoke Get-VmfFacadeRunIds -Times 0 -Exactly
        $rec = & $script:Record $root
        $rec.runsChecked | Should -Be 0
        $rec.runsInStore | Should -Be 0
        $rec.finishedUtc | Should -Not -BeNullOrEmpty
    }

    It 'a run an engine start marked is checked by the next pass, and leaves the record when nothing more is due' {
        $root = & $script:Seed
        & $script:Pass 99
        & $script:Mark $root 'r3'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r3')
        (& $script:Record $root).runsDue | Should -Be 1
        @(& $script:DueIds $root).Count | Should -Be 0
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty
    }

    It 'a run with a stopped machine stays in the record, and is checked each pass until the machine is not stopped' {
        $root = & $script:Seed
        Mock Get-VmfFacadeRunStateDocs { @(Get-ChildItem (Join-Path $StorePath 'state') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
        & $script:State $root 'r4' 'STOPPED'
        & $script:Pass 99
        @(& $script:DueIds $root) | Should -Be @('r4') -Because 'the sweep found it'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r4')
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r4')
        & $script:State $root 'r4' 'MIGRATED'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r4')
        @(& $script:DueIds $root).Count | Should -Be 0
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty
    }

    It 'THE SAFETY NET: a run that is due but not in the record is found by the next sweep, and then checked each pass' {
        $root = & $script:Seed
        Mock Get-VmfFacadeRunStateDocs { @(Get-ChildItem (Join-Path $StorePath 'state') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
        & $script:Pass 99
        # A wave that stopped, with no mark: started from PowerShell, or a mark
        # that could not be written.
        & $script:State $root 'r3' 'CONVERTING'
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty -Because 'nothing marked it, and the last sweep is new'
        & $script:AgeSweep $root
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        @(& $script:DueIds $root) | Should -Be @('r3')
        $due = (& $script:DueText $root | ConvertFrom-Json -DateKind String).runs[0]
        $due.reason | Should -Be 'sweep'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r3')
    }

    It 'a mark written while the pass checks the run is kept, though the pass found nothing due' {
        $root = & $script:Seed
        & $script:Pass 99
        & $script:Mark $root 'r2'
        $before = (& $script:DueText $root | ConvertFrom-Json -DateKind String).runs[0].markId
        $env:VMF_TEST_MARK_RUN = 'r2'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r2')
        @(& $script:DueIds $root) | Should -Be @('r2') -Because 'the mark came after the pass read the record'
        (& $script:DueText $root | ConvertFrom-Json -DateKind String).runs[0].markId | Should -Not -Be $before
        Remove-Item Env:\VMF_TEST_MARK_RUN
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r2')
        @(& $script:DueIds $root).Count | Should -Be 0
    }

    It 'an engine start holds its run in the record for its time, whatever the pass finds' {
        $root = & $script:Seed
        & $script:Pass 99
        & $script:Mark $root 'r5' 15
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r5')
        @(& $script:DueIds $root) | Should -Be @('r5') -Because 'Azure can list a new execution late'
        $text = (& $script:DueText $root) -replace '"holdUntilUtc": "[^"]+"', ('"holdUntilUtc": "' + [datetime]::UtcNow.AddMinutes(-1).ToString('o') + '"')
        Set-Content -Path (Join-Path $root 'schedule-due.json') -Value $text -Encoding utf8NoBOM
        & $script:Pass 99
        @(& $script:DueIds $root).Count | Should -Be 0
    }

    It 'a run of the record that an engine still runs for stays in it' {
        $root = & $script:Seed
        & $script:Pass 99
        & $script:Mark $root 'r1'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        & $script:Pass 99
        @(& $script:DueIds $root) | Should -Be @('r1')
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -ParameterFilter { $RunId -eq 'r1' -and 'wave' -in $Operation -and 'restore' -in $Operation -and 'finish' -in $Operation }
    }

    It 'a question to Azure that fails keeps the run: unknown is never "nothing due"' {
        $root = & $script:Seed
        & $script:Pass 99
        & $script:Mark $root 'r1'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { throw 'ARM did not answer' }
        & $script:Pass 99
        @(& $script:DueIds $root) | Should -Be @('r1')
    }

    It 'a scheduled wave whose time has not come: the run waits in the record until that time' {
        $root = & $script:Seed
        & $script:Pass 99
        $sd = Join-Path $root 'r2' 'schedules'
        New-Item -ItemType Directory -Path $sd -Force | Out-Null
        $when = [datetime]::UtcNow.AddHours(3).ToString('o')
        @{ schemaVersion = 1; wave = 'w1'; state = 'pending'; runAtUtc = $when; scheduledBy = 'operator@example.com'; note = 'n' } | ConvertTo-Json | Set-Content (Join-Path $sd 'w1.json') -Encoding utf8NoBOM
        InModuleScope VmMigrationFactory -Parameters @{ r = $root } { param($r) Add-VmfScheduleDueRun -StorePath $r -RunId 'r2' -Reason 'schedule' | Out-Null }
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r2')
        $entry = (& $script:DueText $root | ConvertFrom-Json -DateKind String).runs[0]
        ([datetime]::Parse($entry.nextUtc).ToUniversalTime() - [datetime]::Parse($when).ToUniversalTime()).TotalSeconds | Should -BeLessThan 1
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty -Because 'its time has not come'
        # The time comes.
        $text = (& $script:DueText $root) -replace '"nextUtc": "[^"]+"', ('"nextUtc": "' + [datetime]::UtcNow.AddMinutes(-1).ToString('o') + '"')
        Set-Content -Path (Join-Path $root 'schedule-due.json') -Value $text -Encoding utf8NoBOM
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r2')
    }

    It 'a run of the record that is not in the store is not checked, leaves the record, and gets no folder' {
        $root = & $script:Seed
        & $script:Pass 99
        & $script:Mark $root 'gone-run'
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty
        Test-Path (Join-Path $root 'gone-run') | Should -BeFalse
        @(& $script:DueIds $root).Count | Should -Be 0
    }

    It 'a run of the record with machine records but no run.json is checked, as the sweep would check its folder' {
        $root = & $script:Seed
        & $script:Pass 99
        Remove-Item (Join-Path $root 'r4' 'run.json')
        & $script:State $root 'r4' 'MIGRATED'
        & $script:Mark $root 'r4'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r4')
    }
    It 'a record of the runs to check that cannot be read: the pass says so and checks every run' {
        $root = & $script:Seed
        & $script:Pass 99
        Mock -ModuleName VmMigrationFactory Read-VmfScheduleDue { throw 'HTTP 403 refused' }
        $env:VMF_TEST_RUNS_LEFT = '99'
        Remove-Item $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue
        $said = & $script:schedule -Timer $null 3>&1 6>$null | ForEach-Object { [string]$_ }
        ($said -join "`n") | Should -Match 'could not read the record of the runs to check: HTTP 403 refused\. This pass checks every run\.'
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
    }

    It 'a record of the runs to check that cannot be used: the pass checks every run and writes over it' {
        $root = & $script:Seed
        & $script:Pass 99
        Set-Content -Path (Join-Path $root 'schedule-due.json') -Value '{"schemaVersion":"one","runs":7}' -Encoding utf8NoBOM
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        Test-Json -Json (& $script:DueText $root) -SchemaFile $script:dueSchema | Should -BeTrue
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty
    }

    It 'a record of the runs to check that cannot be written: the sweep is not over, and the next pass checks every run' {
        $root = & $script:Seed
        Mock -ModuleName VmMigrationFactory Update-VmfScheduleDue { throw 'HTTP 403 refused' }
        $env:VMF_TEST_RUNS_LEFT = '99'
        $said = & $script:schedule -Timer $null 3>&1 6>$null | ForEach-Object { [string]$_ }
        ($said -join "`n") | Should -Match 'could not write the record of the runs to check: HTTP 403 refused\. The next pass checks every run\.'
        (& $script:Record $root).lastSweepUtc | Should -BeNullOrEmpty
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
    }

    It 'THE DEFECT: a store longer than the budget - the sweep reaches every run over the passes, and then ends' {
        $root = & $script:Seed
        & $script:Pass 2
        (& $script:Seen) | Should -Be @('r1', 'r2')
        $rec = & $script:Record $root
        $rec.resumeAtRunId | Should -Be 'r3'
        $rec.runsChecked | Should -Be 2
        $rec.runsNotChecked | Should -Be 3
        $rec.sweepStartedUtc | Should -Not -BeNullOrEmpty -Because 'the sweep is open'
        $rec.finishedUtc | Should -Not -BeNullOrEmpty -Because 'the pass ended by itself, before the limit'
        Test-Json -Json (& $script:RecordText $root) -SchemaFile $script:schema | Should -BeTrue

        & $script:Pass 2
        (& $script:Seen) | Should -Be @('r3', 'r4')
        & $script:Pass 2
        (& $script:Seen) | Should -Be @('r5') -Because 'the sweep goes to the end of the list: r5 is not left for ever'
        $rec = & $script:Record $root
        $rec.resumeAtRunId | Should -BeNullOrEmpty
        $rec.sweepStartedUtc | Should -BeNullOrEmpty
        $rec.lastSweepUtc | Should -Not -BeNullOrEmpty
        & $script:Pass 2
        (& $script:Seen) | Should -BeNullOrEmpty
    }

    It 'due runs come first, and a sweep the budget stopped goes on after them in the next pass' {
        $root = & $script:Seed
        & $script:Mark $root 'r4'
        & $script:Pass 2
        (& $script:Seen) | Should -Be @('r4', 'r1')
        (& $script:Record $root).resumeAtRunId | Should -Be 'r2'
        & $script:Mark $root 'r5'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r5', 'r2', 'r3', 'r4') -Because 'the due run first, then the sweep from its place to the end; r5 is not checked twice'
    }

    It 'a pass that stops says so in the service log: how many runs it did not check, and where the next starts' {
        $root = & $script:Seed
        $env:VMF_TEST_RUNS_LEFT = '2'
        $said = & $script:schedule -Timer $null 3>&1 6>&1 | ForEach-Object { [string]$_ }
        ($said -join "`n") | Should -Match "schedule: the time for this pass is spent after 2 of 5 runs\. 3 runs were not checked; the next pass starts at run 'r3'"
    }

    It 'a pass with no time for one run still writes its record, and checks nothing' {
        $root = & $script:Seed
        & $script:Pass 0
        (& $script:Seen) | Should -BeNullOrEmpty
        $rec = & $script:Record $root
        $rec.resumeAtRunId | Should -Be 'r1'
        $rec.runsNotChecked | Should -Be 5
        $rec.finishedUtc | Should -Not -BeNullOrEmpty
    }

    It 'KILL-RESUME: the host stops the pass on a run of the sweep; the next pass goes on at that run' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE_RUN = 'r3'
        & $script:Pass 99
        # What the store held while r3 was checked is what a stop leaves.
        $killed = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $killed.checkingRunId | Should -Be 'r3'
        $killed.resumeAtRunId | Should -Be 'r3'
        $killed.finishedUtc | Should -BeNullOrEmpty -Because 'the pass had not ended'
        $killed.runsChecked | Should -Be 2
        Test-Json -Json (Get-Content $env:VMF_TEST_CAPTURE -Raw) -SchemaFile $script:schema | Should -BeTrue
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'schedule-status.json') -Force
        Remove-Item (Join-Path $root 'schedule-due.json') -ErrorAction SilentlyContinue

        $atR3 = Join-Path $script:temp "r3-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE = $atR3
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r3', 'r4', 'r5')
        $mid = Get-Content $atR3 -Raw | ConvertFrom-Json -DateKind String
        $mid.checkingStops | Should -Be 1 -Because 'the stop is counted against r3 while r3 is checked'
        $rec = & $script:Record $root
        $rec.checkingRunId | Should -BeNullOrEmpty
        $rec.checkingStops | Should -Be 0
        $rec.passedOverRunId | Should -BeNullOrEmpty
        $rec.lastSweepUtc | Should -Not -BeNullOrEmpty
    }

    It 'KILL-RESUME: the host stops the pass on its first run; the store already says where it was' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE_RUN = 'r1'
        & $script:Pass 99
        $killed = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $killed.checkingRunId | Should -Be 'r1'
        $killed.finishedUtc | Should -BeNullOrEmpty -Because 'the record was written before the first run'
        $killed.runsChecked | Should -Be 0
    }

    It 'KILL-RESUME: the host stops the pass on a due run, before it wrote what it found; the next pass checks the due runs again' {
        $root = & $script:Seed
        Mock Get-VmfFacadeRunStateDocs { @(Get-ChildItem (Join-Path $StorePath 'state') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }) }
        & $script:Pass 99
        & $script:Mark $root 'r2'
        & $script:Mark $root 'r4'
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE_RUN = 'r4'
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r2', 'r4')
        # What a stop on r4 leaves: the pass record on r4, and the record of
        # the runs to check as the pass found it.
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'schedule-status.json') -Force
        Copy-Item "$($env:VMF_TEST_CAPTURE).due" (Join-Path $root 'schedule-due.json') -Force
        @(& $script:DueIds $root) | Should -Be @('r2', 'r4') -Because 'nothing is written into it before the runs end'
        Remove-Item Env:\VMF_TEST_CAPTURE
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r2', 'r4') -Because 'r4, which the host stopped on, comes last'
        @(& $script:DueIds $root).Count | Should -Be 0
        (& $script:Record $root).checkingRunId | Should -BeNullOrEmpty
    }

    It 'KILL-RESUME: two stops on one run pass it over for one pass, it is named, and the next pass checks it' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE_RUN = 'r3'
        & $script:Pass 99
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'schedule-status.json') -Force
        Remove-Item (Join-Path $root 'schedule-due.json') -ErrorAction SilentlyContinue
        & $script:Pass 99
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'schedule-status.json') -Force
        Remove-Item (Join-Path $root 'schedule-due.json') -ErrorAction SilentlyContinue
        Remove-Item Env:\VMF_TEST_CAPTURE

        $env:VMF_TEST_RUNS_LEFT = '99'
        Remove-Item $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue
        $said = & $script:schedule -Timer $null 3>&1 6>$null | ForEach-Object { [string]$_ }
        (& $script:Seen) | Should -Be @('r4', 'r5')
        ($said -join "`n") | Should -Match "schedule: the host stopped two passes on run 'r3'; this pass passes it over, and the next pass that reaches it checks it again"
        $line = Get-Content (Join-Path $root 'r3' 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Select-Object -Last 1
        $line.step | Should -Be 'schedule'
        $line.outcome | Should -Be 'fail'
        $line.detail | Should -Match 'did not complete the check of this migration'
        (& $script:Record $root).passedOverRunId | Should -Be 'r3'
        @(& $script:DueIds $root) | Should -Be @('r3') -Because 'the next pass checks it, not only the next sweep'

        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r3') -Because 'the next pass checks it again'
    }

    It 'a record that cannot be read: the pass says so and checks every run from the first' {
        $root = & $script:Seed
        Mock -ModuleName VmMigrationFactory Read-VmfStoreRootJson { throw 'HTTP 403 refused' }
        $said = & $script:schedule -Timer $null 3>&1 6>$null | ForEach-Object { [string]$_ }
        ($said -join "`n") | Should -Match 'could not read the schedule pass record: HTTP 403 refused'
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
    }

    It 'a record with a field of the wrong type: the pass checks every run and writes over the file (<Why>)' -ForEach @(
        @{ Why = 'schemaVersion is text'; Json = '{"schemaVersion":"x","resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":1}' }
        @{ Why = 'checkingStops is text'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":"abc"}' }
        @{ Why = 'checkingStops is past Int32'; Json = '{"schemaVersion":2,"resumeAtRunId":"r3","finishedUtc":null,"checkingRunId":"r3","checkingStops":99999999999}' }
    ) {
        $root = & $script:Seed
        Set-Content -Path (Join-Path $root 'schedule-status.json') -Value $Json -Encoding utf8NoBOM
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        Test-Json -Json (& $script:RecordText $root) -SchemaFile $script:schema | Should -BeTrue -Because 'the bad file is written over'
        (& $script:Record $root).finishedUtc | Should -Not -BeNullOrEmpty
        & $script:Pass 99
        (& $script:Record $root).finishedUtc | Should -Not -BeNullOrEmpty -Because 'the pass after it is not stopped either'
    }

    It 'a start that throws on the record falls back to no record, says so, and checks every run' {
        $root = & $script:Seed
        & $script:Pass 99
        # A call with no record is not mocked: it runs the real rule.
        Mock -ModuleName VmMigrationFactory New-VmfSchedulePassStart { throw 'a field the rules did not foresee' } -ParameterFilter { $null -ne $Previous }
        Remove-Item $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue
        $env:VMF_TEST_RUNS_LEFT = '99'
        $said = & $script:schedule -Timer $null 3>&1 6>$null | ForEach-Object { [string]$_ }
        ($said -join "`n") | Should -Match 'the schedule pass record could not be used: a field the rules did not foresee\. This pass checks every run\.'
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        (& $script:Record $root).finishedUtc | Should -Not -BeNullOrEmpty
    }

    It 'a record that cannot be written is a warning, and the pass checks every run' {
        $root = & $script:Seed
        Mock -ModuleName VmMigrationFactory Write-VmfStoreRootJson { throw 'HTTP 403 refused' }
        $said = & $script:schedule -Timer $null 3>&1 6>$null | ForEach-Object { [string]$_ }
        ($said -join "`n") | Should -Match 'could not write the schedule pass record: HTTP 403 refused'
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
    }

    It 'records that are old by the put-back pass are not given to it, and the stalled-wave pass still gets them' {
        $root = & $script:Seed
        Mock Get-VmfFacadeRunStateDocs { @([pscustomobject]@{ vmId = 'a' }) }
        Mock -ModuleName VmMigrationFactory Select-VmfScheduleStateDocs { $null }
        & $script:Pass 99
        Should -Invoke Invoke-VmfFacadeResumeStalledWaves -Times 5 -Exactly -ParameterFilter { @($StateDocs).Count -eq 1 }
        Should -Invoke Invoke-VmfFacadeResumeStalledPutBacks -Times 5 -Exactly -ParameterFilter { $null -eq $StateDocs }
        Should -Invoke -ModuleName VmMigrationFactory Select-VmfScheduleStateDocs -Times 5 -Exactly -ParameterFilter { @($StateDocs).Count -eq 1 -and $ReadUtc -is [datetime] }
    }

    It 'records still fresh are given to the put-back pass' {
        $root = & $script:Seed
        Mock Get-VmfFacadeRunStateDocs { @([pscustomobject]@{ vmId = 'a' }) }
        & $script:Pass 99
        Should -Invoke Invoke-VmfFacadeResumeStalledPutBacks -Times 5 -Exactly -ParameterFilter { @($StateDocs).Count -eq 1 }
    }

    It 'a run whose folder cannot be named does not stop the pass, and the record moves on' {
        $root = & $script:Seed
        Mock Get-VmfFacadeStorePath { throw 'no such run' } -ParameterFilter { $RunId -eq 'r2' }
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r3', 'r4', 'r5')
        $rec = & $script:Record $root
        $rec.finishedUtc | Should -Not -BeNullOrEmpty
        $rec.runsChecked | Should -Be 5
    }
}

# Starting a wave twice must be impossible. The real release of due schedules,
# with the engine and the schedule replaced: a pass that checks a run again
# after a stop asks again, and starts nothing a second time.
Describe 'TIMER-PASS-LIMIT-1: a pass that checks a run again starts no wave twice' {
    BeforeAll {
        $script:oldStore2 = $env:VMF_STORE_PATH
    }
    AfterAll {
        if ($null -eq $script:oldStore2) { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue } else { $env:VMF_STORE_PATH = $script:oldStore2 }
        Remove-Item Env:\VMF_TEST_STARTS, Env:\VMF_TEST_KEEP_SCHEDULE, Env:\VMF_TEST_CAPTURE, Env:\VMF_TEST_RUNS_LEFT -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $root = Join-Path $script:temp "w-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        foreach ($run in 'r1', 'r2') {
            $rp = Join-Path $root $run
            New-Item -ItemType Directory -Path $rp -Force | Out-Null
            Set-Content -Path (Join-Path $rp 'run.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 1; runId = $run; kind = 'migration' } | ConvertTo-Json)
            Set-Content -Path (Join-Path $rp 'plan.json') -Encoding utf8NoBOM -Value (@{ schemaVersion = 9; runId = $run; entries = @() } | ConvertTo-Json)
        }
        # r2 has wave w1 due now: a file stands for its schedule.
        Set-Content -Path (Join-Path $root 'r2' 'due-w1') -Value 'due'
        $script:wroot = $root
        $env:VMF_STORE_PATH = $root
        $env:VMF_TEST_STARTS = Join-Path $script:temp "starts-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
        $env:VMF_TEST_RUNS_LEFT = '99'
        # SCHEDULE-START-ONCE-1: the schedule pass reads the schedules, records
        # the start and removes the schedule through these three.
        Mock -ModuleName VmMigrationFactory Get-VmfScheduleStep {
            if (Test-Path (Join-Path $RunPath 'due-w1')) {
                [pscustomobject]@{ Wave = 'w1'; Step = 'due'; Version = ('a' * 64)
                    Schedule = [pscustomobject]@{ wave = 'w1'; throttle = 2; scheduledBy = 'operator@example.com'; note = 'n'; state = 'pending' } }
            }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfScheduleStartRecord { [pscustomobject]@{ StartId = ('c' * 32); Version = ('b' * 64) } }
        Mock -ModuleName VmMigrationFactory Remove-VmfStartedSchedule {
            # A stop between the start and this line leaves the schedule.
            if (-not $env:VMF_TEST_KEEP_SCHEDULE) { Remove-Item (Join-Path $RunPath 'due-w1') -Force }
            $true
        }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = $true; Detail = 'approved' } }
        Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { $null }
        # Azure, faked: an execution started for a wave is listed as running.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning {
            [bool](Get-Content $env:VMF_TEST_STARTS -ErrorAction SilentlyContinue | Where-Object { $_ -eq "$RunId/$Wave" })
        }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine {
            Add-Content -Path $env:VMF_TEST_STARTS -Value "$RunId/$Wave"
            if ($env:VMF_TEST_CAPTURE) { Copy-Item (Join-Path $env:VMF_STORE_PATH 'schedule-status.json') $env:VMF_TEST_CAPTURE -Force }
            [pscustomobject]@{ Execution = 'exec-1' }
        }
        Mock Get-VmfFacadeRunStateDocs { @() }
        Mock Invoke-VmfFacadeResumeStalledWaves { @() }
        Mock Invoke-VmfFacadeRemoveEndedWaveHolds { @() }
        Mock Invoke-VmfFacadeResumeStalledPutBacks { @() }
        Mock Invoke-VmfFacadeContinuePlan { $null }
        Remove-Item Env:\VMF_TEST_KEEP_SCHEDULE, Env:\VMF_TEST_CAPTURE -ErrorAction SilentlyContinue
    }

    It 'the host stops the pass after the start; the next pass checks that run again and starts nothing' {
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        & $script:schedule -Timer $null 3>$null 6>$null
        @(Get-Content $env:VMF_TEST_STARTS) | Should -Be @('r2/w1')
        $killed = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $killed.checkingRunId | Should -Be 'r2'
        $killed.finishedUtc | Should -BeNullOrEmpty
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $script:wroot 'schedule-status.json') -Force
        Remove-Item (Join-Path $script:wroot 'schedule-due.json') -ErrorAction SilentlyContinue
        Remove-Item Env:\VMF_TEST_CAPTURE
        & $script:schedule -Timer $null 3>$null 6>$null
        @(Get-Content $env:VMF_TEST_STARTS) | Should -Be @('r2/w1')
    }

    It 'the stop came before the schedule was cleared: the run of the wave is listed, so nothing starts again' {
        $env:VMF_TEST_KEEP_SCHEDULE = '1'
        & $script:schedule -Timer $null 3>$null 6>$null
        & $script:schedule -Timer $null 3>$null 6>$null
        @(Get-Content $env:VMF_TEST_STARTS) | Should -Be @('r2/w1')
    }
}

Describe 'TIMER-PASS-LIMIT-1: the timer and the record' {
    It 'the timer still fires every five minutes' {
        $binding = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'function.json') -Raw | ConvertFrom-Json
        $binding.bindings[0].schedule | Should -Be '0 */5 * * * *'
    }

    It 'the record is written through the root writer, at the start, before every run and at the end' {
        $code = Get-VmfCodeOnly -Path $script:schedule
        $code | Should -Match "Write-VmfStoreRootJson -StorePath \`$r -Name 'schedule-status\.json'"
        $code | Should -Match "Read-VmfStoreRootJson -StorePath \`$r -Name 'schedule-status\.json'"
        $code | Should -Match '(?s)\$pass\.checkingRunId = \$runId.*?Write-SchedulePassRecord -Root \$root -Record \$pass\s*\r?\n\s*\$clock = '
        $code | Should -Match '(?s)foreach \(\$runId in \$runIds\) \{.*?\n    \}\n.*Write-SchedulePassRecord -Root \$root -Record \$pass -Final'
    }

    It 'what a pass found goes into the due record after the runs, before the final record' {
        $code = Get-VmfCodeOnly -Path $script:schedule
        $code | Should -Match '(?s)foreach \(\$runId in \$runIds\) \{.*?\n    \}\n.*Update-VmfScheduleDue -StorePath \$r -Changes \$c.*Write-SchedulePassRecord -Root \$root -Record \$pass -Final'
    }
}
