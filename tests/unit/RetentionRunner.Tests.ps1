#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETAIN-UX-1: the daily cleanup leaves a record of every pass.
#
# Question, 2026-09-04: after a migration, does the customer leave the install
# alone while a worker cleans up later? Nothing traced the pending cleanup, so
# it was not clear how that happens. The timer used to write nothing when it found nothing,
# so a pass failing silently for a month looked like one with nothing to do.
# The timer is a function-app script, run by the host, so these are rules
# over its text; the ledger the card computes is tested in tests/js.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:runner = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1') -Raw
    $script:binding = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'function.json') -Raw | ConvertFrom-Json
}

Describe 'RETAIN-UX-1: every retention pass leaves one record at the store root' {
    It 'a cycle starts at 03:30 UTC, and the record names the next pass from the rule the timer follows' {
        # PERF-RETENTION-TIMEOUT-1: the timer fires every hour, and the day's
        # cleanup (a cycle) starts at 03:30 UTC - the hour the page names.
        $script:binding.bindings[0].schedule | Should -Be '0 30 * * * *'
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $retention = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'RetentionPass.ps1')
        $retention | Should -Match '\$script:VmfRetentionCycleHourUtc = 3'
        $retention | Should -Match '\$script:VmfRetentionCycleMinuteUtc = 30'
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'now\.getUTCDate\(\), 3, 30, 0\)' -Because 'the page names the same hour'
        # RETENTION-CARD-CYCLE-1: a next pass the record names that has gone by
        # is replaced on the card by the timer's own minute, half past the hour
        # (help.js retentionPassFacts, Get-VmfRetentionNextPassUtc).
        $help | Should -Match 'now\.getUTCHours\(\), 30, 0\)' -Because 'the card names the timer''s minute while a cycle is unfinished'
        $script:runner | Should -Match '\$Record\.nextPassUtc = .*Get-VmfRetentionNextPassUtc'
    }

    It 'the record is written whether or not anything was due - that is the whole point' {
        # Inside the try, AFTER the loop over runs (not inside it), and again
        # from the outer catch, so a pass that could not even list the runs
        # still says so.
        $script:runner | Should -Match "(?s)foreach \(\`$runId in \`$runIds\) \{.*?\n    \}\n.*?Write-RetentionPassRecord -Root \`$root -Record \`$pass -Final\n\}"
        $script:runner | Should -Match "(?s)catch \{\s*Write-Warning ""retention pass failed before it could read the runs.*?\`$pass\.failures \+= "
        # CORPTEST-1: through the root writer. The ordinary one refused the
        # store root in Azure, so this record was never written there.
        $script:runner | Should -Match "Write-VmfStoreRootJson -StorePath \`$r -Name 'retention-status\.json'"
    }

    It 'counts what it examined, what was due, what it started and what failed' {
        # PERF-RETENTION-TIMEOUT-1: the record is built by New-VmfRetentionPassStart.
        $start = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'RetentionPass.ps1') -Raw
        foreach ($field in 'runsExamined', 'runsWithCopiesDue', 'machinesDue', 'executionsStarted', 'failures', 'lastPassUtc', 'nextPassUtc') {
            $start | Should -Match ("(?m)^\s+$([regex]::Escape($field))\s+= ") -Because $field
        }
        $script:runner | Should -Match '\$Record\.nextPassUtc = '
        $script:runner | Should -Match '\$pass\.runsExamined\+\+'
        $script:runner | Should -Match '\$pass\.machinesDue \+= \$eligible'
        $script:runner | Should -Match "\`$pass\.executionsStarted \+= \[ordered\]@\{ runId = \`$runId; machines = \`$eligible; execution ="
        $script:runner | Should -Match "\`$pass\.failures \+= \[ordered\]@\{ runId = \`$runId; reason = \`$reason \}"
    }

    It 'ROLLBACK-DISKS-FIRST-1: a cleanup starts for rollback disks that are due, with no copy due' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1')
        $code | Should -Match '\$disksDue = @\(\$preview\.RollbackDisksBeforeMove\)\.Count'
        $code | Should -Match 'if \(\$eligible -eq 0 -and \$disksDue -eq 0 -and \$madeDue -eq 0\) \{ continue \}'
        $code | Should -Not -Match 'if \(\$eligible -eq 0\) \{ continue \}' -Because 'copies alone must not decide, or due disks bill until a copy is due'
    }

    It 'a record that cannot be written is a warning, never a failed pass' {
        $script:runner | Should -Match 'catch \{ Write-Warning "could not write the retention pass record'
    }
}

# PERF-RETENTION-TIMEOUT-1: the pass, RUN. Measured on the lab install
# 2026-10-27 to 2026-11-02: 7 of 7 daily passes stopped at the 5-minute limit,
# so the runs after the point each one reached were never examined and the
# record was never written. Each pass now stops starting runs at its budget,
# writes the record with the run it reached, and the next pass starts there.
Describe 'PERF-RETENTION-TIMEOUT-1: a pass that stops part way, and the pass after it' {
    BeforeAll {
        Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
        Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
        . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
        . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
        Block-VmfAzureCalls -TestFile $PSCommandPath
        . (Join-Path $PSScriptRoot '_TempWork.ps1')
        $script:temp = New-VmfTestTemp -Prefix 'retrun'
        $script:retention = Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1'
        $script:schema = Join-Path $script:repoRoot 'schemas' 'retention-status.schema.json'
        $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        $script:oldStore = $env:VMF_STORE_PATH
        # Five migrations of one machine each. r2 has copies due.
        $script:Seed = {
            $root = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            foreach ($run in 'r1', 'r2', 'r3', 'r4', 'r5') {
                InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $root $run); id = $run; vm = $script:vm } {
                    param($rp, $id, $vm)
                    Initialize-VmfRun -RunPath $rp -RunId $id | Out-Null
                    Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                        schemaVersion = 9; runId = $id; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}$id"; wave = 'w1'; path = 'A' }) })
                }
            }
            $env:VMF_STORE_PATH = $root
            # A Mock body runs in a scope of its own, so what the pass looked
            # at goes to a file both can reach (TimerPasses.Tests.ps1).
            $env:VMF_TEST_SEEN = Join-Path $script:temp "seen-$([guid]::NewGuid().ToString('N').Substring(0,8)).txt"
            $root
        }
        $script:Seen = { @(Get-Content $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue | ForEach-Object { ($_ -split '[\\/]')[-1] }) }
        $script:Record = { param($root) Get-Content (Join-Path $root 'retention-status.json') -Raw | ConvertFrom-Json -DateKind String }
        # RETENTION-TEST-CLOCK-1: every pass runs at a pinned time, far from
        # the 03:30 UTC start of a cycle. On the real clock, two passes of one
        # test that straddled the start (03:29:00 UTC, with the slack) fell in
        # two cycles, and two tests failed in a full suite at 03:27 UTC.
        $script:NoonUtc = '2026-11-03T12:00:00.0000000Z'
        $script:Pass = { param($runsAllowed, [string]$AtUtc = $script:NoonUtc)
            $env:VMF_TEST_RUNS_LEFT = [string]$runsAllowed
            $env:VMF_TEST_NOW_UTC = $AtUtc
            Remove-Item $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue
            & $script:retention -Timer $null 3>$null 6>$null
        }
    }
    AfterAll {
        if ($null -eq $script:oldStore) { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue } else { $env:VMF_STORE_PATH = $script:oldStore }
        Remove-Item Env:\VMF_TEST_SEEN, Env:\VMF_TEST_RUNS_LEFT, Env:\VMF_TEST_CAPTURE, Env:\VMF_TEST_CAPTURE_RUN, Env:\VMF_TEST_NOW_UTC -ErrorAction SilentlyContinue
        Remove-VmfTestTemp
    }
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Remove-VmfExpiredMigrationRecords { @() }
        Mock -ModuleName VmMigrationFactory Update-VmfStaleReport {
            Add-Content -Path $env:VMF_TEST_SEEN -Value $RunPath
            # The moment the host could stop the pass: what the store says then.
            $at = if ($env:VMF_TEST_CAPTURE_RUN) { $env:VMF_TEST_CAPTURE_RUN } else { 'r3' }
            if ($env:VMF_TEST_CAPTURE -and $RunPath -like "*$at") {
                Copy-Item (Join-Path $env:VMF_STORE_PATH 'retention-status.json') $env:VMF_TEST_CAPTURE -Force
            }
            'current'
        }
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { }
        Mock -ModuleName VmMigrationFactory Remove-VmfExpiredSafetyCopies {
            if ($RunPath -like '*r2') { return [pscustomobject]@{ Eligible = @([pscustomobject]@{ VmId = 'x' }); RollbackDisksBeforeMove = @(); MadeDisks = @() } }
            [pscustomobject]@{ Eligible = @(); RollbackDisksBeforeMove = @(); MadeDisks = @() }
        }
        Mock Invoke-VmfFacadeStartEngine { [pscustomobject]@{ Execution = 'exec-r2' } }
        # The budget, counted in runs: the clock of a test is not the clock of
        # the service.
        Mock -ModuleName VmMigrationFactory Test-VmfRetentionTimeLeft {
            $left = [int]$env:VMF_TEST_RUNS_LEFT
            $env:VMF_TEST_RUNS_LEFT = [string]($left - 1)
            $left -gt 0
        }
        # The clock of the pass (run.ps1 reads it with Get-Date and no
        # argument): the time the test pins, never the time of day the suite
        # runs at.
        $env:VMF_TEST_NOW_UTC = $script:NoonUtc
        Mock Get-Date {
            [datetime]::Parse($env:VMF_TEST_NOW_UTC, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind)
        }
        Remove-Item Env:\VMF_TEST_CAPTURE, Env:\VMF_TEST_CAPTURE_RUN -ErrorAction SilentlyContinue
    }

    It 'stops at its budget, writes the record with the run it reached, and the next pass starts there' {
        $root = & $script:Seed
        & $script:Pass 2
        (& $script:Seen) | Should -Be @('r1', 'r2')
        $rec = & $script:Record $root
        $rec.runsExamined | Should -Be 2
        $rec.resumeAtRunId | Should -Be 'r3'
        $rec.finishedUtc | Should -Not -BeNullOrEmpty -Because 'the pass ended by itself, the record says so'
        $rec.runsInStore | Should -Be 5
        @($rec.executionsStarted.runId) | Should -Be @('r2')
        Test-Json -Json (Get-Content (Join-Path $root 'retention-status.json') -Raw) -SchemaFile $script:schema | Should -BeTrue

        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r3', 'r4', 'r5') -Because 'a run examined earlier in the cycle is not examined again'
        $rec = & $script:Record $root
        $rec.runsExamined | Should -Be 5 -Because 'every run is examined within the cycle'
        $rec.resumeAtRunId | Should -BeNullOrEmpty
        $rec.passesInCycle | Should -Be 2
        @($rec.executionsStarted.runId) | Should -Be @('r2') -Because 'the cycle keeps what an earlier pass started'
        $rec.failures | Should -BeNullOrEmpty
        Test-Json -Json (Get-Content (Join-Path $root 'retention-status.json') -Raw) -SchemaFile $script:schema | Should -BeTrue
    }

    It 'a pass after the cycle examined every run does nothing, and leaves the record as it is' {
        $root = & $script:Seed
        & $script:Pass 99
        $before = Get-Content (Join-Path $root 'retention-status.json') -Raw
        & $script:Pass 99
        (& $script:Seen) | Should -BeNullOrEmpty
        Get-Content (Join-Path $root 'retention-status.json') -Raw | Should -Be $before
    }

    It 'a pass with no time for one run still writes its record, and examines nothing' {
        $root = & $script:Seed
        & $script:Pass 0
        (& $script:Seen) | Should -BeNullOrEmpty
        $rec = & $script:Record $root
        $rec.resumeAtRunId | Should -Be 'r1'
        $rec.finishedUtc | Should -Not -BeNullOrEmpty
        $rec.runsExamined | Should -Be 0
    }

    It 'KILL-RESUME: the host stops the pass on a run; the next pass starts at that run and finishes the cycle' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        & $script:Pass 99
        # What the store held while r3 was being examined is what a kill leaves.
        $killed = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $killed.resumeAtRunId | Should -Be 'r3'
        $killed.finishedUtc | Should -BeNullOrEmpty -Because 'the pass had not ended'
        $killed.runsExamined | Should -Be 2
        Test-Json -Json (Get-Content $env:VMF_TEST_CAPTURE -Raw) -SchemaFile $script:schema | Should -BeTrue
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'retention-status.json') -Force

        # The pass after it: while on r3 the store counts the stop against r3,
        # and once r3 ends, r4 starts with no stop against it.
        $atR3 = Join-Path $script:temp "r3-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE = $atR3
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r3', 'r4', 'r5')
        $rec = & $script:Record $root
        $rec.runsExamined | Should -Be 5
        $rec.resumeAtRunId | Should -BeNullOrEmpty
        $rec.failures | Should -BeNullOrEmpty
        $mid = Get-Content $atR3 -Raw | ConvertFrom-Json -DateKind String
        $mid.resumeAtRunId | Should -Be 'r3'
        $mid.resumeStops | Should -Be 1
        $mid.finishedUtc | Should -BeNullOrEmpty
    }

    It 'KILL-RESUME: a run that ends after a stop leaves the next run with no stop against it' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        & $script:Pass 99
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'retention-status.json') -Force
        $env:VMF_TEST_CAPTURE_RUN = 'r4'
        & $script:Pass 99
        $mid = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $mid.resumeAtRunId | Should -Be 'r4'
        $mid.resumeStops | Should -Be 0 -Because 'one stop on r3 must not count against r4'
    }

    It 'KILL-RESUME: the host stops the first run of a new cycle; the next pass continues that cycle at it' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        $env:VMF_TEST_CAPTURE_RUN = 'r1'
        & $script:Pass 99
        $killed = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $killed.resumeAtRunId | Should -Be 'r1'
        $killed.finishedUtc | Should -BeNullOrEmpty
        $killed.cycleStartedUtc | Should -Not -BeNullOrEmpty
        Copy-Item $env:VMF_TEST_CAPTURE (Join-Path $root 'retention-status.json') -Force
        Remove-Item Env:\VMF_TEST_CAPTURE
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        (& $script:Record $root).passesInCycle | Should -Be 2 -Because 'it continued the cycle, it did not start another'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfExpiredMigrationRecords -Times 1 -Exactly
    }

    It 'a run the host stopped two passes on is passed over, named on the record and in the run''s activity' {
        $root = & $script:Seed
        $env:VMF_TEST_CAPTURE = Join-Path $script:temp "kill-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
        & $script:Pass 99
        $killed = Get-Content $env:VMF_TEST_CAPTURE -Raw | ConvertFrom-Json -DateKind String
        $killed.resumeStops = 1
        Set-Content -Path (Join-Path $root 'retention-status.json') -Value ($killed | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
        Remove-Item Env:\VMF_TEST_CAPTURE

        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r4', 'r5')
        $rec = & $script:Record $root
        @($rec.failures.runId) | Should -Be @('r3')
        $rec.resumeAtRunId | Should -BeNullOrEmpty
        $rec.runsExamined | Should -Be 5
        Get-Content (Join-Path $root 'r3' 'logs' 'events.jsonl') -Raw | Should -Match 'time limit'
    }

    It 'a new cycle starts the next day from the first run, with every count at zero' {
        $root = & $script:Seed
        & $script:Pass 99
        $rec = & $script:Record $root
        $rec.cycleStartedUtc = [datetime]::Parse($script:NoonUtc).ToUniversalTime().AddDays(-2).ToString('o')
        $rec.failures = @([ordered]@{ runId = 'r9'; reason = 'old' })
        Set-Content -Path (Join-Path $root 'retention-status.json') -Value ($rec | ConvertTo-Json -Depth 6) -Encoding utf8NoBOM
        & $script:Pass 99
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        $rec = & $script:Record $root
        $rec.failures | Should -BeNullOrEmpty
        $rec.passesInCycle | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfExpiredMigrationRecords -Times 2 -Exactly -Because 'once for each of the two cycles'
    }

    It 'the migration records past their 90 days are checked once a cycle, not every hour' {
        $root = & $script:Seed
        & $script:Pass 2
        & $script:Pass 99
        & $script:Pass 99
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfExpiredMigrationRecords -Times 1 -Exactly
    }

    # RETENTION-TEST-CLOCK-1: the start of a cycle, at the second. The timer
    # can fire a little early, so a pass from 03:29:00 UTC (60 seconds of
    # slack) belongs to the cycle that starts at 03:30. A cycle that an early
    # pass starts is RETENTION-EARLY-CYCLE-1: that pass records its own time,
    # so the next pass starts the cycle again.
    It 'a pass at <Second> after a full cycle at <First> starts a new cycle: <NewCycle>' -ForEach @(
        @{ First = '2026-11-03T03:28:59.0000000Z'; Second = '2026-11-03T03:29:00.0000000Z'; NewCycle = $true }
        @{ First = '2026-11-02T03:30:01.0000000Z'; Second = '2026-11-03T03:29:00.0000000Z'; NewCycle = $true }
        @{ First = '2026-11-03T03:30:01.0000000Z'; Second = '2026-11-03T03:30:02.0000000Z'; NewCycle = $false }
        @{ First = '2026-11-03T03:30:01.0000000Z'; Second = '2026-11-04T03:28:59.0000000Z'; NewCycle = $false }
    ) {
        $root = & $script:Seed
        & $script:Pass 99 $First
        (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5')
        $before = Get-Content (Join-Path $root 'retention-status.json') -Raw
        & $script:Pass 99 $Second
        if ($NewCycle) {
            (& $script:Seen) | Should -Be @('r1', 'r2', 'r3', 'r4', 'r5') -Because 'the cycle of the day starts again from the first run'
            $rec = & $script:Record $root
            $rec.passesInCycle | Should -Be 1
            $rec.cycleStartedUtc | Should -Match ('^' + [regex]::Escape($Second.Substring(0, 19))) -Because 'the new cycle starts at this pass'
            Should -Invoke -ModuleName VmMigrationFactory Remove-VmfExpiredMigrationRecords -Times 2 -Exactly -Because 'once for each of the two cycles'
        }
        else {
            (& $script:Seen) | Should -BeNullOrEmpty -Because 'the cycle already examined every run'
            Get-Content (Join-Path $root 'retention-status.json') -Raw | Should -Be $before
            Should -Invoke -ModuleName VmMigrationFactory Remove-VmfExpiredMigrationRecords -Times 1 -Exactly
        }
    }

    It 'a pass that cannot list the runs still writes its record, and the next pass starts the day''s cycle' {
        $root = & $script:Seed
        Mock Get-VmfFacadeRunIds { throw 'the listing was refused' }
        & $script:Pass 99
        $rec = & $script:Record $root
        @($rec.failures.reason) | Should -Match 'the listing was refused'
        $rec.cycleStartedUtc | Should -BeNullOrEmpty -Because 'a failed pass must not read as a finished day'
        Test-Json -Json (Get-Content (Join-Path $root 'retention-status.json') -Raw) -SchemaFile $script:schema | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ Rec = $rec; At = [datetime]::Parse($script:NoonUtc).ToUniversalTime() } { param($Rec, $At) Get-VmfRetentionPassAction -Previous $Rec -NowUtc $At } | Should -Be 'newCycle'
    }

    It 'a pass that cannot list the runs in the middle of a cycle keeps the run it would have started at' {
        $root = & $script:Seed
        & $script:Pass 2
        Mock Get-VmfFacadeRunIds { throw 'the listing was refused' }
        & $script:Pass 99
        $rec = & $script:Record $root
        $rec.resumeAtRunId | Should -Be 'r3'
        $rec.cycleStartedUtc | Should -Not -BeNullOrEmpty
        InModuleScope VmMigrationFactory -Parameters @{ Rec = $rec; At = [datetime]::Parse($script:NoonUtc).ToUniversalTime() } { param($Rec, $At) Get-VmfRetentionPassAction -Previous $Rec -NowUtc $At } | Should -Be 'continue'
    }
    It 'says how long each run took, so the slow check can be found' {
        $root = & $script:Seed
        $env:VMF_TEST_RUNS_LEFT = '99'
        Remove-Item $env:VMF_TEST_SEEN -ErrorAction SilentlyContinue
        $out = & $script:retention -Timer $null 3>$null 6>&1
        $said = @($out | ForEach-Object { [string]$_ }) -join "`n"
        $said | Should -Match "retention: 'r1' examined in \d+ ms \(report \d+ ms, summary \d+ ms, copies \d+ ms\)"
        (& $script:Record $root).slowestRun.runId | Should -BeIn @('r1', 'r2', 'r3', 'r4', 'r5')
    }
}
