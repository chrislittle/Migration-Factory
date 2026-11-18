#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETAIN-KIND-1, 2026-10-05: one rule for what a run is.
#
# The daily check and the pages decided the kind of a run each their own way.
# OLD-VERSION-READERS-REMOVE-6 (2026-11-12): Initialize-VmfRun writes the kind
# on every manifest, and the contract requires it, so a manifest with no kind
# is not known - it is no longer read as a migration from before the
# assessment split, which no store holds.
#
# One rule, once in each language: Get-VmfRunKind here, VmfHelp.runKind in
# the pages (tests/js/run-kind.test.js). Both are held to
# tests/fixtures/run-kinds.json. And the retention pass is RUN, not read.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'run-kinds.json') -Raw | ConvertFrom-Json
    $script:retention = Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1'
}

Describe 'RETAIN-KIND-1: one rule for what a run is' {
    It 'the engine answers every case in the fixture the pages are held to' {
        foreach ($c in $script:fixture.cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ m = $c.manifest } { Get-VmfRunKind -Manifest $m }
            $got | Should -Be $c.kind -Because "$($c.manifest | ConvertTo-Json -Compress): $($c.why)"
        }
    }

    It 'and answers it for a manifest read back from JSON, the way every caller holds one' {
        InModuleScope VmMigrationFactory {
            Get-VmfRunKind -Manifest ('{"runId":"r1"}' | ConvertFrom-Json) | Should -BeNullOrEmpty
            Get-VmfRunKind -Manifest ('{"runId":"r1","kind":"assessment"}' | ConvertFrom-Json) | Should -Be 'assessment'
            Get-VmfRunKind -Manifest ([ordered]@{ runId = 'r1' }) | Should -BeNullOrEmpty -Because 'a dictionary, as a test or a writer builds one'
            Get-VmfRunKind -Manifest ([ordered]@{ runId = 'r1'; kind = 'migration' }) | Should -Be 'migration'
        }
    }

    It 'the manifest writer writes the kind on every manifest, so no reader needs to guess it' {
        InModuleScope VmMigrationFactory {
            $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rk-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                $m = Initialize-VmfRun -RunPath $rp -RunId 'r1'
                Get-VmfRunKind -Manifest $m | Should -Be 'migration' -Because 'the default kind is written, not left out'
                $rp2 = "$rp-a"
                Get-VmfRunKind -Manifest (Initialize-VmfRun -RunPath $rp2 -RunId 'a1' -Kind assessment) | Should -Be 'assessment'
            }
            finally { Remove-Item $rp, "$rp-a" -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }

    It 'the daily check, the report checks and the run removals ask the one rule' {
        foreach ($rel in @('src/facade/app/RetentionRunner/run.ps1',
                           'src/VmMigrationFactory/Private/report/RecordAndReport.ps1',
                           'src/VmMigrationFactory/Public/New-VmfReport.ps1',
                           'src/VmMigrationFactory/Public/Remove-VmfAbandonedRuns.ps1',
                           'src/VmMigrationFactory/Public/Remove-VmfRun.ps1')) {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot $rel)
            $code | Should -Match 'Get-VmfRunKind -Manifest \$manifest' -Because $rel
            $code | Should -Not -Match '\$manifest\.kind' -Because "$rel decides the kind itself"
        }
    }

    It 'the pages that list runs ask VmfHelp.runKind' {
        # index.html asks twice: the project's count and the run itself.
        # PAGE-LOAD-1 removed the third, PERF-RUNS-LIST-1's choice of which
        # runs wait for the list of runs - that list is no longer asked for.
        # migrations.html asks twice: the list, and the run a link names, read
        # beside the list (MIGRATIONS-LOAD-1, drawNamedRun).
        foreach ($p in @(@('index.html', 2), @('migrations.html', 2), @('projects.html', 1), @('assessments.html', 1))) {
            $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' $p[0]) -Language CStyle
            ([regex]::Matches($code, 'VmfHelp\.runKind\(')).Count | Should -Be $p[1] -Because $p[0]
            $code | Should -Not -Match 'manifest\.kind\b' -Because "$($p[0]) decides the kind itself"
        }
    }
}

Describe 'RETAIN-KIND-1: the daily check, run' {
    BeforeAll {
        # A run whose manifest names no kind (with a plan, and with none), a
        # migration, an assessment, and a migration not planned yet. One machine
        # in each plan: a plan of none is set up only.
        $script:seedStore = {
            $root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rk-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $write = {
                param($rel, $doc)
                $full = Join-Path $root $rel
                New-Item -ItemType Directory -Path (Split-Path $full) -Force | Out-Null
                Set-Content -Path $full -Value ($doc | ConvertTo-Json -Depth 8) -Encoding utf8NoBOM
            }
            $entry = { param($run) @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$run-vm"
                                                 wave = 'wave-1'; path = 'A' }) }
            & $write 'old1/run.json'   ([ordered]@{ schemaVersion = 7; runId = 'old1'; createdUtc = '2026-08-20T10:00:00Z' })
            & $write 'old1/plan.json'  ([ordered]@{ schemaVersion = 9; runId = 'old1'; entries = (& $entry 'old1') })
            & $write 'new1/run.json'   ([ordered]@{ schemaVersion = 9; runId = 'new1'; kind = 'migration' })
            & $write 'new1/plan.json'  ([ordered]@{ schemaVersion = 9; runId = 'new1'; entries = (& $entry 'new1') })
            & $write 'asmt1/run.json'  ([ordered]@{ schemaVersion = 9; runId = 'asmt1'; kind = 'assessment' })
            & $write 'scan0/run.json'  ([ordered]@{ schemaVersion = 7; runId = 'scan0'; createdUtc = '2026-08-20T09:00:00Z' })
            & $write 'setup1/run.json' ([ordered]@{ schemaVersion = 9; runId = 'setup1'; kind = 'migration' })
            & $write 'empty1/run.json' ([ordered]@{ schemaVersion = 9; runId = 'empty1'; kind = 'migration' })
            & $write 'empty1/plan.json' ([ordered]@{ schemaVersion = 9; runId = 'empty1'; entries = @() })
            $root
        }
        $script:oldStorePath = $env:VMF_STORE_PATH
    }
    AfterAll {
        if ($null -eq $script:oldStorePath) { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue } else { $env:VMF_STORE_PATH = $script:oldStorePath }
    }

    Context 'which runs it takes' {
        BeforeAll {
            $script:storeRoot = & $script:seedStore
            $env:VMF_STORE_PATH = $script:storeRoot
            Mock -ModuleName VmMigrationFactory Remove-VmfExpiredSafetyCopies { [pscustomobject]@{ Eligible = @() } }
            Mock -ModuleName VmMigrationFactory Update-VmfStaleReport { 'current' }
            Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { }
            & $script:retention -Timer $null 3>$null
        }
        AfterAll { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

        It 'a run whose manifest names no kind is not known, so it is not taken as a migration' {
            Should -Invoke -Scope Context -ModuleName VmMigrationFactory Remove-VmfExpiredSafetyCopies -Times 0 -Exactly -ParameterFilter { $RunPath -like '*old1' }
            Should -Invoke -Scope Context -ModuleName VmMigrationFactory Update-VmfStaleReport -Times 0 -Exactly -ParameterFilter { $RunPath -like '*old1' }
            Should -Invoke -Scope Context -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 0 -Exactly -ParameterFilter { $RunPath -like '*old1' }
        }

        It 'a migration that says so gets them too, and an assessment still does not' {
            Should -Invoke -Scope Context -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 1 -Exactly -ParameterFilter { $RunPath -like '*new1' }
            Should -Invoke -Scope Context -ModuleName VmMigrationFactory Update-VmfRunSummary -Times 0 -Exactly -ParameterFilter { $RunPath -like '*asmt1' }
            Should -Invoke -Scope Context -ModuleName VmMigrationFactory Remove-VmfExpiredSafetyCopies -Times 0 -Exactly -ParameterFilter { $RunPath -like '*asmt1' }
        }

        It 'a run with no plan, or a plan of no machines - a run with no kind, a migration not planned yet - is left alone' {
            foreach ($run in 'scan0', 'setup1', 'empty1') {
                foreach ($fn in 'Remove-VmfExpiredSafetyCopies', 'Update-VmfStaleReport', 'Update-VmfRunSummary') {
                    Should -Invoke -Scope Context -ModuleName VmMigrationFactory $fn -Times 0 -Exactly -ParameterFilter { $RunPath -like "*$run" } -Because "$run, $fn"
                }
            }
        }
    }

    Context 'with the real cleanup asked what would go' {
        BeforeAll {
            $script:storeRoot = & $script:seedStore
            $env:VMF_STORE_PATH = $script:storeRoot
            Mock -ModuleName VmMigrationFactory Update-VmfStaleReport { 'current' }
            & $script:retention -Timer $null 3>$null
        }
        AfterAll { if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force } }

        It 'the pass records no failure for any of the six runs' {
            $record = Get-Content (Join-Path $script:storeRoot 'retention-status.json') -Raw | ConvertFrom-Json
            $record.failures | Should -BeNullOrEmpty
            $record.runsExamined | Should -Be 6
        }

        It 'and writes no "still being billed" line into a run that holds no copies' {
            foreach ($run in 'old1', 'new1', 'asmt1', 'scan0', 'setup1', 'empty1') {
                $log = Join-Path $script:storeRoot $run 'logs' 'events.jsonl'
                if (Test-Path $log) { Get-Content $log -Raw | Should -Not -Match 'still being billed' -Because $run }
            }
        }
    }
}
Describe 'RETAIN-KIND-1: the report check looks at a migration only' {
    It 'Update-VmfStaleReport looks at a migration, and answers current for a run with no kind or an assessment without looking' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rk-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            New-Item -ItemType Directory -Path $rp -Force | Out-Null
            @{ schemaVersion = 9; runId = 'm1'; kind = 'migration' } | ConvertTo-Json | Set-Content (Join-Path $rp 'run.json') -Encoding utf8NoBOM
            Mock -ModuleName VmMigrationFactory Get-VmfMigrationRecordFromStore { throw 'LOOKED' }
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Update-VmfStaleReport -RunPath $rp } } | Should -Throw '*LOOKED*'
            @{ schemaVersion = 7; runId = 'old1' } | ConvertTo-Json | Set-Content (Join-Path $rp 'run.json') -Encoding utf8NoBOM
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Update-VmfStaleReport -RunPath $rp } | Should -Be 'current'
            @{ schemaVersion = 9; runId = 'a1'; kind = 'assessment' } | ConvertTo-Json | Set-Content (Join-Path $rp 'run.json') -Encoding utf8NoBOM
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Update-VmfStaleReport -RunPath $rp } | Should -Be 'current'
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}
