#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERF-RETENTION-TIMEOUT-1: the daily cleanup works in passes that fit the
# service's time limit, and each pass starts where the last one stopped.
#
# MEASURED on the lab install, 2026-10-27 to 2026-11-02: all 7 passes of
# RetentionRunner stopped at the Functions 5-minute limit. The pass walked
# every run in one go and wrote its record only at the end, so each day the
# runs after the point it reached were never examined (their expired safety
# copies kept billing), the record was never written, and the timeout
# restarted the worker - which stopped a ScheduleRunner pass beside it.
#
# These are the pure rules: when a day's cleanup (a CYCLE) starts, where a
# pass starts inside it, what a pass that the host stopped part way means, and
# when the pass must stop starting runs. The pass itself is RUN, not read, in
# RetentionRunner.Tests.ps1.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'retpass'
    $script:Utc = { param($s) [datetimeoffset]::Parse($s, [cultureinfo]::InvariantCulture).UtcDateTime }
    # A record the way the store gives it back: read as text, dates as text.
    $script:Rec = { param($h) ([pscustomobject]$h | ConvertTo-Json -Depth 6) | ConvertFrom-Json -Depth 6 -DateKind String }
    $script:Runs = @('p1/mig-b', 'loose1', 'p1/mig-a', 'P2/mig', 'p1/asmt1')
}
AfterAll { Remove-VmfTestTemp }

Describe 'PERF-RETENTION-TIMEOUT-1: when the day''s cleanup starts' {
    It 'a cycle starts at 03:30 UTC, the hour the page names (help.js nextRetentionPassUtc)' {
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc } {
            param($Utc)
            Get-VmfRetentionCycleStart -NowUtc (& $Utc '2026-11-02T04:30:05Z') | Should -Be (& $Utc '2026-11-02T03:30:00Z')
            Get-VmfRetentionCycleStart -NowUtc (& $Utc '2026-11-02T02:30:05Z') | Should -Be (& $Utc '2026-11-01T03:30:00Z')
            Get-VmfRetentionCycleStart -NowUtc (& $Utc '2026-11-02T03:30:00Z') | Should -Be (& $Utc '2026-11-02T03:30:00Z')
        }
    }

    It 'a timer that fires a moment early still starts that day''s cycle' {
        # Azure's timer can fire a fraction of a second before the minute. Read
        # against the clock alone, 03:29:59.9 belongs to yesterday's cycle, and
        # the day's cleanup would wait an hour.
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc } {
            param($Utc)
            Get-VmfRetentionCycleStart -NowUtc (& $Utc '2026-11-02T03:29:59.9Z') | Should -Be (& $Utc '2026-11-02T03:30:00Z')
        }
    }
}

Describe 'PERF-RETENTION-TIMEOUT-1: what a pass does, from the record of the last one' {
    It 'with no record, it starts a cycle' {
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc } {
            param($Utc)
            Get-VmfRetentionPassAction -Previous $null -NowUtc (& $Utc '2026-11-02T05:30:00Z') | Should -Be 'newCycle'
        }
    }

    It 'a cycle that examined every run today: the pass does nothing until the next 03:30' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-02T03:30:02.0000000Z'; lastPassUtc = '2026-11-02T04:30:01Z'
                                 finishedUtc = '2026-11-02T04:31:00Z'; resumeAtRunId = $null }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev } {
            param($Utc, $Prev)
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-02T05:30:00Z') | Should -Be 'done'
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-03T03:28:00Z') | Should -Be 'done'
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-03T03:30:01Z') | Should -Be 'newCycle'
        }
    }

    It 'a cycle that has not examined every run continues - also after 03:30 the next day, so the end of the list is never left out' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-01T03:30:02Z'; lastPassUtc = '2026-11-02T02:30:01Z'
                                 finishedUtc = '2026-11-02T02:34:00Z'; resumeAtRunId = 'p1/mig-b' }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev } {
            param($Utc, $Prev)
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-02T03:30:00Z') | Should -Be 'continue'
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-02T03:30:00Z') | Should -Not -Be 'newCycle'
        }
    }

    It 'MIGRATION: a record of schema 1 (written only at the end of a whole pass) is a finished cycle that started at its lastPassUtc' {
        $prev = & $script:Rec @{ schemaVersion = 1; lastPassUtc = '2026-11-02T03:30:04.1234567Z'; runsExamined = 4; failures = @() }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev } {
            param($Utc, $Prev)
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-02T04:30:00Z') | Should -Be 'done'
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-03T03:30:00Z') | Should -Be 'newCycle'
        }
    }

    It 'a record whose dates cannot be read starts a cycle, never ends the day''s cleanup' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = 'not a date'; lastPassUtc = 'x'; resumeAtRunId = $null }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev } {
            param($Utc, $Prev)
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-02T05:30:00Z') | Should -Be 'newCycle'
        }
    }
}

Describe 'PERF-RETENTION-TIMEOUT-1: where a pass starts, and the record it carries' {
    It 'a new cycle examines every run, in one fixed order, with every count at zero' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-01T03:30:02Z'; lastPassUtc = '2026-11-01T03:30:02Z'
                                 finishedUtc = '2026-11-01T03:33:00Z'; resumeAtRunId = $null; runsExamined = 9; machinesDue = 3
                                 failures = @(@{ runId = 'x'; reason = 'old' }); executionsStarted = @(@{ runId = 'x'; machines = 1; execution = 'e' }) }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev; Runs = $script:Runs } {
            param($Utc, $Prev, $Runs)
            $now = & $Utc '2026-11-02T03:30:01Z'
            $s = New-VmfRetentionPassStart -Previous $Prev -Action 'newCycle' -RunIds $Runs -NowUtc $now
            # Ordinal: the order may not change with the culture of the worker.
            @($s.Runs) | Should -Be @('P2/mig', 'loose1', 'p1/asmt1', 'p1/mig-a', 'p1/mig-b')
            $s.StalledRunId | Should -BeNullOrEmpty
            $r = $s.Record
            $r.schemaVersion | Should -Be 2
            $r.cycleStartedUtc | Should -Be $now.ToString('o')
            $r.lastPassUtc | Should -Be $now.ToString('o')
            $r.passesInCycle | Should -Be 1
            $r.runsInStore | Should -Be 5
            $r.runsExamined | Should -Be 0
            $r.machinesDue | Should -Be 0
            @($r.failures).Count | Should -Be 0
            @($r.executionsStarted).Count | Should -Be 0
            $r.resumeAtRunId | Should -Be 'P2/mig' -Because 'a pass the host stops before its first run must come back to it'
            $r.resumeStops | Should -Be 0
            $r.finishedUtc | Should -BeNullOrEmpty -Because 'a record with no finish says a pass is working, or was stopped'
        }
    }

    It 'a pass after one that stopped at its time budget starts AT the run it reached, and keeps the cycle''s counts' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-02T03:30:02Z'; lastPassUtc = '2026-11-02T03:30:02Z'
                                 finishedUtc = '2026-11-02T03:33:40Z'; resumeAtRunId = 'p1/asmt1'; resumeStops = 0; passesInCycle = 1
                                 runsInStore = 5; runsExamined = 2; runsWithCopiesDue = 1; machinesDue = 2
                                 executionsStarted = @(@{ runId = 'loose1'; machines = 2; execution = 'e1' }); failures = @(@{ runId = 'P2/mig'; reason = 'r' }) }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev; Runs = $script:Runs } {
            param($Utc, $Prev, $Runs)
            $now = & $Utc '2026-11-02T04:30:01Z'
            $s = New-VmfRetentionPassStart -Previous $Prev -Action 'continue' -RunIds $Runs -NowUtc $now
            @($s.Runs) | Should -Be @('p1/asmt1', 'p1/mig-a', 'p1/mig-b')
            $r = $s.Record
            $r.cycleStartedUtc | Should -Be '2026-11-02T03:30:02Z'
            $r.lastPassUtc | Should -Be $now.ToString('o')
            $r.passesInCycle | Should -Be 2
            $r.runsExamined | Should -Be 2
            $r.runsWithCopiesDue | Should -Be 1
            $r.machinesDue | Should -Be 2
            @($r.executionsStarted.runId) | Should -Be @('loose1')
            @($r.failures.runId) | Should -Be @('P2/mig')
            $r.resumeStops | Should -Be 0 -Because 'a pass that stopped at its budget was not stopped by the host'
        }
    }

    It 'a run deleted since the last pass: the pass starts at the next name' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-02T03:30:02Z'; finishedUtc = '2026-11-02T03:33:40Z'; resumeAtRunId = 'p1/gone' }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev; Runs = $script:Runs } {
            param($Utc, $Prev, $Runs)
            $s = New-VmfRetentionPassStart -Previous $Prev -Action 'continue' -RunIds $Runs -NowUtc (& $Utc '2026-11-02T04:30:01Z')
            @($s.Runs) | Should -Be @('p1/mig-a', 'p1/mig-b')
        }
    }

    It 'KILL-RESUME: a pass the host stopped part way is counted against the run it was on, and that run is examined again' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-02T03:30:02Z'; lastPassUtc = '2026-11-02T03:30:02Z'
                                 finishedUtc = $null; resumeAtRunId = 'p1/asmt1'; resumeStops = 0; runsExamined = 2 }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev; Runs = $script:Runs } {
            param($Utc, $Prev, $Runs)
            Get-VmfRetentionPassAction -Previous $Prev -NowUtc (& $Utc '2026-11-02T04:30:01Z') | Should -Be 'continue'
            $s = New-VmfRetentionPassStart -Previous $Prev -Action 'continue' -RunIds $Runs -NowUtc (& $Utc '2026-11-02T04:30:01Z')
            @($s.Runs) | Should -Be @('p1/asmt1', 'p1/mig-a', 'p1/mig-b')
            $s.StalledRunId | Should -BeNullOrEmpty
            $s.Record.resumeStops | Should -Be 1
            $s.Record.runsExamined | Should -Be 2
        }
    }

    It 'a run the host stopped two passes on is passed over and named as a failure, so it cannot hold up every run after it' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-02T03:30:02Z'; lastPassUtc = '2026-11-02T04:30:02Z'
                                 finishedUtc = $null; resumeAtRunId = 'p1/asmt1'; resumeStops = 1; runsExamined = 2; failures = @() }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev; Runs = $script:Runs } {
            param($Utc, $Prev, $Runs)
            $s = New-VmfRetentionPassStart -Previous $Prev -Action 'continue' -RunIds $Runs -NowUtc (& $Utc '2026-11-02T05:30:01Z')
            $s.StalledRunId | Should -Be 'p1/asmt1'
            @($s.Runs) | Should -Be @('p1/mig-a', 'p1/mig-b')
            @($s.Record.failures.runId) | Should -Be @('p1/asmt1')
            $s.Record.failures[0].reason | Should -Match 'time limit'
            $s.Record.failures[0].reason | Should -Match ([regex]::Escape("'p1/asmt1'")) -Because 'the card shows the reason alone, so it must name the migration'
            $s.Record.runsExamined | Should -Be 3 -Because 'the pass reached it; the failure says what happened'
            $s.Record.resumeAtRunId | Should -Be 'p1/mig-a'
            $s.Record.resumeStops | Should -Be 0
        }
    }

    It 'the last run of the list stalled: nothing is left, and the record says the cycle examined every run' {
        $prev = & $script:Rec @{ schemaVersion = 2; cycleStartedUtc = '2026-11-02T03:30:02Z'; finishedUtc = $null; resumeAtRunId = 'p1/mig-b'; resumeStops = 1 }
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc; Prev = $prev; Runs = $script:Runs } {
            param($Utc, $Prev, $Runs)
            $s = New-VmfRetentionPassStart -Previous $Prev -Action 'continue' -RunIds $Runs -NowUtc (& $Utc '2026-11-02T05:30:01Z')
            @($s.Runs).Count | Should -Be 0
            $s.Record.resumeAtRunId | Should -BeNullOrEmpty
        }
    }
}

Describe 'PERF-RETENTION-TIMEOUT-1: the time budget and the next pass' {
    It 'stops starting runs well before the 5-minute limit' {
        InModuleScope VmMigrationFactory {
            $started = [datetime]::UtcNow
            Test-VmfRetentionTimeLeft -StartedUtc $started.AddSeconds(-10) | Should -BeTrue
            Test-VmfRetentionTimeLeft -StartedUtc $started.AddSeconds(-209) | Should -BeTrue
            Test-VmfRetentionTimeLeft -StartedUtc $started.AddSeconds(-211) | Should -BeFalse
            Test-VmfRetentionTimeLeft -StartedUtc $started.AddSeconds(-300) | Should -BeFalse
            (Get-Command Test-VmfRetentionTimeLeft).Parameters['BudgetSeconds'].Attributes.Where({ $_ -is [System.Management.Automation.ValidateRangeAttribute] }).MaxRange |
                Should -BeLessThan 300 -Because 'a budget at the limit is no budget'
        }
    }

    It 'names the next 03:30 when the cycle examined every run, and the next hour otherwise' {
        InModuleScope VmMigrationFactory -Parameters @{ Utc = $script:Utc } {
            param($Utc)
            Get-VmfRetentionNextPassUtc -NowUtc (& $Utc '2026-11-02T03:34:00Z') -CycleComplete | Should -Be (& $Utc '2026-11-03T03:30:00Z')
            Get-VmfRetentionNextPassUtc -NowUtc (& $Utc '2026-11-02T03:34:00Z') | Should -Be (& $Utc '2026-11-02T04:30:00Z')
            Get-VmfRetentionNextPassUtc -NowUtc (& $Utc '2026-11-02T23:34:00Z') | Should -Be (& $Utc '2026-11-03T00:30:00Z')
        }
    }

    It 'the timer fires every hour at half past, which includes the 03:30 that starts a cycle' {
        $binding = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'function.json') -Raw | ConvertFrom-Json
        $binding.bindings[0].schedule | Should -Be '0 30 * * * *'
    }
}

Describe 'PERF-RETENTION-TIMEOUT-1: the record is read back from the top of the store' {
    It 'a document that is not there reads as nothing, and its dates stay text' {
        $root = Join-Path $script:temp 'root1'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ Root = $root } {
            param($Root)
            Read-VmfStoreRootJson -StorePath $Root -Name 'retention-status.json' | Should -BeNullOrEmpty
            Write-VmfStoreRootJson -StorePath $Root -Name 'retention-status.json' -Document ([ordered]@{ schemaVersion = 2; lastPassUtc = '2026-11-02T03:30:02.1234567Z' })
            $doc = Read-VmfStoreRootJson -StorePath $Root -Name 'retention-status.json'
            $doc.lastPassUtc | Should -BeOfType [string]
            $doc.lastPassUtc | Should -Be '2026-11-02T03:30:02.1234567Z'
            { Read-VmfStoreRootJson -StorePath $Root -Name 'a/b.json' } | Should -Throw '*not a document name*'
        }
    }

    It 'reads the blob at the top of the container, and a 404 is nothing' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 404; Content = '' } }
            Read-VmfStoreRootJson -StorePath 'azblob://acct/vmf-runs' -Name 'retention-status.json' | Should -BeNullOrEmpty
            Should -Invoke Invoke-VmfStorageRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Uri -eq 'https://acct.blob.core.windows.net/vmf-runs/retention-status.json' }
            Mock Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 200; Content = '{"schemaVersion":2,"lastPassUtc":"2026-11-02T03:30:02Z"}' } }
            (Read-VmfStoreRootJson -StorePath 'azblob://acct/vmf-runs' -Name 'retention-status.json').lastPassUtc | Should -Be '2026-11-02T03:30:02Z'
            Mock Invoke-VmfStorageRequest { [pscustomobject]@{ StatusCode = 403; Content = 'AuthorizationFailure' } }
            { Read-VmfStoreRootJson -StorePath 'azblob://acct/vmf-runs' -Name 'retention-status.json' } | Should -Throw '*HTTP 403*' -Because 'a store that refuses is not a record that is not there'
        }
    }
}
