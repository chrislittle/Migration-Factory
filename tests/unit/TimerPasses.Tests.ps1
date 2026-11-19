#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PROJECT-3: the two timer passes, RUN rather than read.
#
# WHY THIS FILE EXISTS. RetentionRunner.Tests.ps1 and the schedule tests before
# it are rules over the TEXT of these scripts - "it must call the shared run
# finder", "it must write the pass record after the loop". Both still pass
# today. Neither noticed that PROJECT-2 handed the run finder a variable that
# has no value at that point in either script, so both passes died before they
# looked at a single run: no safety copy reaped, no scheduled wave started, and
# nothing said so anywhere a person looks.
#
# A text rule cannot catch that, because the text is right. Only running it can.
#
# These passes are function-app scripts, so running them needs three things and
# no Azure: a store on disk (VMF_STORE_PATH), the two modules imported, and the
# handful of calls that would reach ARM replaced. Everything else is the real
# script, including the walk this file exists to hold.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    # These passes are real scripts, so an unmocked Azure call in one would go
    # to the network rather than fail. The guard is the floor; it goes on
    # before this file's own mocks so those still win.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:retention = Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1'
    $script:schedule  = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'

    # The store as a lab install had it, 2026-09-16: one project holding a
    # migration, an assessment, and the `logs` folder the old retention pass
    # left behind - plus a run outside any project, which installs from before
    # projects still have.
    function Script:SeedStore {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        $write = {
            param($rel, $doc)
            $full = Join-Path $root $rel
            New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
            Set-Content -Path $full -Value ($doc | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
        }
        & $write 'p1/project.json'        ([ordered]@{ schemaVersion = 1; projectId = 'p1'; name = 'Project one' })
        & $write 'p1/mig1/run.json'       ([ordered]@{ schemaVersion = 1; runId = 'mig1'; kind = 'migration' })
        & $write 'p1/mig1/plan.json'      ([ordered]@{ schemaVersion = 9; runId = 'mig1'; entries = @() })
        & $write 'p1/asmt1/run.json'      ([ordered]@{ schemaVersion = 1; runId = 'asmt1'; kind = 'assessment' })
        & $write 'p1/asmt1/assessment.json' ([ordered]@{ schemaVersion = 1; vms = @() })
        & $write 'loose1/run.json'        ([ordered]@{ schemaVersion = 1; runId = 'loose1'; kind = 'migration' })
        & $write 'loose1/plan.json'       ([ordered]@{ schemaVersion = 9; runId = 'loose1'; entries = @() })
        # Not JSON, and not a run. This is the debris, byte for byte in shape.
        New-Item -ItemType Directory -Path (Join-Path $root 'p1/logs') -Force | Out-Null
        Set-Content -Path (Join-Path $root 'p1/logs/events.jsonl') -Encoding utf8NoBOM `
            -Value '{"tsUtc":"2026-09-16T03:30:04Z","step":"retention","outcome":"fail","detail":"No plan found"}'
        New-Item -ItemType Directory -Path (Join-Path $root 'vmf-claims') -Force | Out-Null
        $root
    }
}

Describe 'PROJECT-3: the run finder tells runs from the folders beside them' {
    BeforeAll { $script:storeRoot = Script:SeedStore }
    AfterAll { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

    It 'finds the migration, the assessment and the loose run - and nothing else' {
        $found = @(Get-VmfFacadeRunIds -StorePath $script:storeRoot)
        $found | Should -Be @('loose1', 'p1/asmt1', 'p1/mig1')
    }

    It 'THE DEFECT: an event log beside a project every run is NOT a fourth run' {
        # A drill reported "4 inside one" for a project holding three.
        @(Get-VmfFacadeRunIds -StorePath $script:storeRoot) | Should -Not -Contain 'p1/logs'
    }

    It 'matches the folder name whole, so a run may be called what it likes' {
        Test-VmfFacadeRunFolder -Path 'p1/logs'        | Should -BeFalse
        Test-VmfFacadeRunFolder -Path 'logs'           | Should -BeFalse
        Test-VmfFacadeRunFolder -Path 'vmf-claims'     | Should -BeFalse
        Test-VmfFacadeRunFolder -Path 'p1/logs-of-war' | Should -BeTrue
        Test-VmfFacadeRunFolder -Path 'my-logs'        | Should -BeTrue
    }

    It 'the service and the browser are held to the same list of cases' {
        $cases = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'not-a-run-folders.json') -Raw | ConvertFrom-Json
        foreach ($c in $cases.cases) {
            (Test-VmfFacadeRunFolder -Path $c.path) | Should -Be $c.isRun -Because "$($c.path): $($c.why)"
        }
    }
}

Describe 'PROJECT-3: the retention pass, run' {
    BeforeAll {
        $script:storeRoot = Script:SeedStore
        $env:VMF_STORE_PATH = $script:storeRoot
        Mock -ModuleName VmMigrationFactory Remove-VmfExpiredSafetyCopies { [pscustomobject]@{ Eligible = @() } }
    }
    AfterAll {
        Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force }
    }

    It 'reaches the runs at all - the regression PROJECT-2 shipped' {
        & $script:retention -Timer $null 3>$null
        $record = Get-Content (Join-Path $script:storeRoot 'retention-status.json') -Raw | ConvertFrom-Json
        # The variable defect made EVERY pass end here instead.
        @($record.failures | ForEach-Object { $_.reason }) |
            Should -Not -Contain 'the pass could not read the runs: '
        ($record.failures | Where-Object { $_.reason -like '*could not read the runs*' }) |
            Should -BeNullOrEmpty -Because 'the pass must get past the listing'
        $record.runsExamined | Should -BeGreaterThan 0
    }

    It 'says nothing alarming about a run that has no copies to keep' {
        & $script:retention -Timer $null 3>$null
        # An assessment has no plan and never will. It used to collect "copies
        # past their retention are still being kept, and still being billed".
        Test-Path (Join-Path $script:storeRoot 'p1/asmt1/logs/events.jsonl') | Should -BeFalse
        $record = Get-Content (Join-Path $script:storeRoot 'retention-status.json') -Raw | ConvertFrom-Json
        $record.failures | Should -BeNullOrEmpty
    }

    It 'never writes into the folder that is not a run' {
        $before = Get-Content (Join-Path $script:storeRoot 'p1/logs/events.jsonl') -Raw
        & $script:retention -Timer $null 3>$null
        (Get-Content (Join-Path $script:storeRoot 'p1/logs/events.jsonl') -Raw) | Should -Be $before
        Test-Path (Join-Path $script:storeRoot 'p1/logs/logs') | Should -BeFalse -Because 'a log inside a log is how this compounds'
    }
}

Describe 'PROJECT-3: the schedule pass, run' {
    BeforeAll {
        $script:storeRoot = Script:SeedStore
        $env:VMF_STORE_PATH = $script:storeRoot
        # A Mock body runs later, in a scope of its own. A list held in a
        # variable here reads back as $null from the It, so the record of what
        # the pass looked at goes where both can reach it: the store on disk.
        $script:seenFile = Join-Path $script:storeRoot 'seen.txt'
        Mock Invoke-VmfFacadeReleaseDueSchedules {
            Add-Content -Path (Join-Path $env:VMF_STORE_PATH 'seen.txt') -Value $RunId; @()
        }
        Mock Invoke-VmfFacadeResumeStalledWaves { @() }
    }
    AfterAll {
        Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force }
    }

    It 'looks at every run, including the one inside a project' {
        # SCHED-1's whole promise: a wave scheduled for the small hours starts.
        # The variable defect meant this loop never ran a single time.
        & $script:schedule -Timer $null 3>$null
        $seen = @(Get-Content $script:seenFile -ErrorAction SilentlyContinue)
        $seen | Should -Contain 'p1/mig1'
        $seen | Should -Contain 'loose1'
    }

    It 'and never at the folder beside them' {
        $seen = @(Get-Content $script:seenFile -ErrorAction SilentlyContinue)
        $seen | Should -Not -BeNullOrEmpty -Because 'an empty record would pass this for the wrong reason'
        $seen | Should -Not -Contain 'p1/logs'
        Test-Path (Join-Path $script:storeRoot 'p1/logs/logs') | Should -BeFalse
    }
}
