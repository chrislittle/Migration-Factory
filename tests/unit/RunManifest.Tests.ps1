#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ASSESS-PAGE-1 - an assessment is not a run.
#
# An assessment needs its own page: it made no sense for an assessment to
# go into the runs list and sit there.
#
# Everything in the store was a run. Scanning an estate created one, and if
# nobody migrated it sat in the run list looking like an abandoned migration.
# An assessment is not a failed run: it answers a question on its own, it gets
# re-run and compared, it is the thing that gets signed off, and it is read-only
# and deliberately broad where a migration writes and should be narrow.
#
# The manifest is what tells them apart, so it is a contract now rather than an
# informal file that happened to carry a run id.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'run-manifest.schema.json'
    # DERIVED, not pinned. Ten fixtures used to carry the literal version, so a
    # bump was ten edits and the failure it produced ("expected 8, got 9") said
    # nothing about what actually changed. The same fix the capacity-claim tests
    # already took.
    $script:manifestVersion = (Get-Content $script:schemaFile -Raw | ConvertFrom-Json).properties.schemaVersion.const

    function Global:ManifestValidates($doc) {
        try { Test-Json -Json ($doc | ConvertTo-Json -Depth 10) -SchemaFile $script:schemaFile -ErrorAction Stop }
        catch { $false }
    }
    # ASSESS-PAGE-1: planning refuses an unreviewed assessment, so tests about
    # what planning DOES have to review one first. That the gate fires at all is
    # covered separately, below.
    function Global:ApproveAssessment {
        param($Path)
        InModuleScope VmMigrationFactory -Parameters @{ p = $Path } {
            Approve-VmfAssessment -RunPath $p -Note 'test: reviewed' `
                -OnBehalfOf @{ Identity = 'tester@example.com'; TenantId = 't' }
        } | Out-Null
    }
    function Global:NewRun {
        param([string]$Kind = 'migration', [string]$From, $Scope)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-man-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $p = @{ rp = $rp; kind = $Kind; from = $From; scope = $Scope }
        InModuleScope VmMigrationFactory -Parameters $p {
            # NOT $args - PowerShell owns that name. It has worked here by
            # luck; CLAUDE.md records the same shape killing a whole file with
            # "Cannot overwrite variable HOME" and naming nothing you wrote.
            $callArgs = @{ RunPath = $rp; RunId = 'man-test'; Kind = $kind }
            if ($from) { $callArgs.FromAssessment = $from }
            if ($scope) { $callArgs.Scope = $scope }
            Initialize-VmfRun @callArgs
        } | Out-Null
        $rp
    }
}
AfterAll { Remove-Item 'function:\ApproveAssessment', 'function:\ManifestValidates', 'function:\NewRun' -ErrorAction SilentlyContinue }

Describe 'ASSESS-PAGE-1: the manifest says which of the two things this is' {

    It 'an assessment validates' {
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'assessment'; runId = 'a1'
            createdUtc = '2026-08-31T00:00:00Z' }) | Should -BeTrue
    }

    It 'a migration planned from an assessment validates, and records which one' {
        # The traceability the product did not have: a migration could not say
        # what it was based on, or whether that assessment had been reviewed.
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'migration'; runId = 'm1'
            createdUtc = '2026-08-31T00:00:00Z'; fromAssessment = 'a1' }) | Should -BeTrue
    }

    It 'a manifest with NO kind is refused' {
        # Not defaulted. A default would silently put every object on one of the
        # two pages, and being wrong there is worse than being absent.
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; runId = 'x'
            createdUtc = '2026-08-31T00:00:00Z' }) | Should -BeFalse
    }

    It 'an invented kind is refused' {
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'something-else'; runId = 'x'
            createdUtc = '2026-08-31T00:00:00Z' }) | Should -BeFalse
    }

    It 'an assessment cannot claim to come FROM an assessment' {
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'assessment'; runId = 'a1'
            createdUtc = '2026-08-31T00:00:00Z'; fromAssessment = 'a0' }) | Should -BeFalse
    }

    It 'a migration carries no scan scope of its own - it inherits the assessment''s' {
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'migration'; runId = 'm1'
            createdUtc = '2026-08-31T00:00:00Z'; scope = @{ subscriptions = @('s') } }) | Should -BeFalse
    }

    It 'an assessment records what it scanned, so the page need not open it' {
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'assessment'; runId = 'a1'
            createdUtc = '2026-08-31T00:00:00Z'
            scope = [ordered]@{ subscriptions = @('sub-1'); managementGroup = $null; resourceGroups = @('rg-a') } }) |
            Should -BeTrue
    }

    It 'and an invented field is still rejected' {
        ManifestValidates ([ordered]@{ schemaVersion = $script:manifestVersion; kind = 'assessment'; runId = 'a1'
            createdUtc = '2026-08-31T00:00:00Z'; somethingNew = 'x' }) | Should -BeFalse
    }
}

Describe 'ASSESS-PAGE-1: what the store actually writes' {
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'writes a manifest that validates against the contract' {
        # The contract and the writer must agree, or the contract is decoration.
        $script:rp = NewRun -Kind 'assessment'
        $doc = Get-Content (Join-Path $script:rp 'run.json') -Raw | ConvertFrom-Json
        ManifestValidates $doc | Should -BeTrue
        $doc.kind | Should -Be 'assessment'
        $doc.schemaVersion | Should -Be $script:manifestVersion
    }

    It 'a migration records the assessment it came from' {
        $script:rp = NewRun -Kind 'migration' -From 'a-123'
        $doc = Get-Content (Join-Path $script:rp 'run.json') -Raw | ConvertFrom-Json
        ManifestValidates $doc | Should -BeTrue
        $doc.fromAssessment | Should -Be 'a-123'
    }

    It 'an assessment records its scope' {
        $script:rp = NewRun -Kind 'assessment' -Scope @{ subscriptions = @('sub-1'); resourceGroups = @('rg-a') }
        $doc = Get-Content (Join-Path $script:rp 'run.json') -Raw | ConvertFrom-Json
        ManifestValidates $doc | Should -BeTrue
        $doc.scope.subscriptions | Should -Be @('sub-1')
    }

    It 'refuses a kind the contract does not allow, at the door' {
        # Better to fail where the object is created than to write something no
        # page can place.
        { NewRun -Kind 'nonsense' } | Should -Throw
    }

    It 'is idempotent - re-initialising does not change what the object is' {
        # Every operation calls this. If a later call could overwrite the kind,
        # planning a migration would silently turn its assessment into one.
        $script:rp = NewRun -Kind 'assessment'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            Initialize-VmfRun -RunPath $rp -RunId 'man-test' -Kind 'migration'
        } | Out-Null
        (Get-Content (Join-Path $script:rp 'run.json') -Raw | ConvertFrom-Json).kind | Should -Be 'assessment'
    }
}

Describe 'ASSESS-PAGE-1: planning turns an assessment into a migration' {
    BeforeEach {
        $script:aPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-a-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-m-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ a = $script:aPath } {
            Initialize-VmfRun -RunPath $a -RunId (Split-Path $a -Leaf) -Kind 'assessment' `
                -Scope @{ Subscriptions = @('sub-1') } | Out-Null
        }
        # The smallest assessment New-VmfPlan will accept: one machine it can
        # place, so the plan has an entry and the manifest gets written.
        @{
            schemaVersion = 17
            runId = (Split-Path $script:aPath -Leaf)
            generatedUtc = '2026-08-31T00:00:00Z'
            scope = @{ subscriptions = @('sub-1'); managementGroup = $null; tagFilter = $null
                       resourceGroups = @() }
            summary = @{}
            vms = @()
        } | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $script:aPath 'assessment.json')
    }
    AfterEach {
        foreach ($leftover in $script:aPath, $script:mPath) {
            if ($leftover -and (Test-Path $leftover)) { Remove-Item $leftover -Recurse -Force }
        }
    }

    It 'the migration is a MIGRATION and names the assessment it came from' {
        ApproveAssessment $script:aPath
        New-VmfPlan -AssessmentPath (Join-Path $script:aPath 'assessment.json') -OutPath $script:mPath | Out-Null
        $m = Get-Content (Join-Path $script:mPath 'run.json') -Raw | ConvertFrom-Json
        $m.kind | Should -Be 'migration'
        $m.fromAssessment | Should -Be (Split-Path $script:aPath -Leaf)
        ManifestValidates $m | Should -BeTrue
    }

    It 'the assessment is COPIED into the migration, not referenced' {
        # A migration records a decision made against a particular snapshot of
        # the estate. If somebody re-runs the assessment next month, what this
        # migration was planned from must not change underneath it - and the
        # report and the dashboard both read it from the migration.
        ApproveAssessment $script:aPath
        New-VmfPlan -AssessmentPath (Join-Path $script:aPath 'assessment.json') -OutPath $script:mPath | Out-Null
        Test-Path (Join-Path $script:mPath 'assessment.json') | Should -BeTrue
    }

    It 'and the assessment itself is untouched - still an assessment, still no plan' {
        ApproveAssessment $script:aPath
        New-VmfPlan -AssessmentPath (Join-Path $script:aPath 'assessment.json') -OutPath $script:mPath | Out-Null
        (Get-Content (Join-Path $script:aPath 'run.json') -Raw | ConvertFrom-Json).kind | Should -Be 'assessment'
        Test-Path (Join-Path $script:aPath 'plan.json') | Should -BeFalse -Because 'the plan belongs to the migration'
    }
}

Describe 'ASSESS-PAGE-1: the engine and the app agree on the split' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $script:core  = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1') -Raw
        $script:wiz   = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
    }

    It 'the plan operation writes to the MIGRATION, never back into the assessment' {
        # The bug this prevents is quiet: planning into the assessment leaves an
        # object that is an assessment by manifest and a migration by content,
        # so it appears on the wrong page and carries a plan nobody expects.
        $planBranch = [regex]::Match($script:entry, "(?s)'plan'\s*\{.*?
    \}").Value
        $planBranch | Should -Match 'VMF_MIGRATION_ID'
        $planBranch | Should -Match 'OutPath = \$migrationPath'
        $planBranch | Should -Not -Match 'OutPath = \$runPath'
    }

    It 'the quota check follows the migration too' {
        # It ran against $runPath, which is now the assessment. Claims written
        # there would be invisible to the wave that needs them.
        $planBranch = [regex]::Match($script:entry, "(?s)'plan'\s*\{.*?
    \}").Value
        $planBranch | Should -Match 'Test-VmfQuota -PlanPath "\$migrationPath/plan\.json" -OutPath \$migrationPath'
    }

    It 'the facade names the migration and hands the id back' {
        # Generated by the facade rather than the engine because the CALLER has
        # to be told: without the id in the response the wizard sits watching
        # the assessment for a plan being written somewhere else.
        $script:core | Should -Match "-eq 'plan'"
        $script:core | Should -Match 'migrationId = '
        $script:core | Should -Match 'VMF_MIGRATION_ID'
    }

    It 'and only for a plan - every other operation returns null' {
        $script:core | Should -Match '\$migrationId = \$null'
    }

    It 'the wizard follows the migration it was given' {
        $script:wiz | Should -Match 'started\.migrationId'
        $script:wiz | Should -Match 'runId = started\.migrationId'
    }

    It 'the start response is camelCase, like every read endpoint here' {
        # PowerShell callers do not care; the dashboard is JavaScript and does.
        # A response that is PascalCase in one place and camelCase in another is
        # a trap that shows up as a field silently reading undefined.
        $script:core | Should -Match 'operation   ='
        $script:core | Should -Match 'migrationId ='
        $script:core | Should -Match 'startedBy   ='
    }
}

Describe 'ASSESS-PAGE-1: a name already in use is refused, not overwritten' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dup-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp } {
            Initialize-VmfRun -RunPath $p -RunId 'dup-test' -Kind 'assessment' | Out-Null
        }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'scanning again over a FINISHED assessment is refused' {
        # Nothing used to stop this: the manifest was reused and assessment.json
        # was replaced, so the earlier scan was silently thrown away - and any
        # migration planned from it was left pointing at data it was never
        # planned from.
        '{ "vms": [] }' | Set-Content (Join-Path $script:rp 'assessment.json')
        { Invoke-VmfAssessment -Scope @{ Subscriptions = @('s') } -OutPath $script:rp -RunId 'dup-test' } |
            Should -Throw '*has already been assessed*'
    }

    It 'but a scan that FAILED part way can be retried under its own name' {
        # The test is a finished scan, not merely a manifest. A run that crashed
        # before writing anything must not be locked out of its own name.
        Test-Path (Join-Path $script:rp 'assessment.json') | Should -BeFalse
        # It gets past the guard and on to the scan itself, which needs Azure -
        # forbidden here. That it reaches Azure at all IS the proof: the guard
        # let it through. Should -Not -Throw would mean 'throws nothing', which
        # is a different and untrue claim.
        $msg = ''
        try { Invoke-VmfAssessment -Scope @{ Subscriptions = @('s') } -OutPath $script:rp -RunId 'dup-test' }
        catch { $msg = $_.Exception.Message }
        $msg | Should -Not -Match 'has already been assessed'
        $msg | Should -Match 'reached the real Azure' -Because 'it got past the name guard and on to the scan'
    }

    It 'and scanning over a MIGRATION is refused by name' {
        $m = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dupm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ p = $m } {
                Initialize-VmfRun -RunPath $p -RunId 'dup-mig' -Kind 'migration' | Out-Null
            }
            { Invoke-VmfAssessment -Scope @{ Subscriptions = @('s') } -OutPath $m -RunId 'dup-mig' } |
                Should -Throw '*is a migration, not an assessment*'
        }
        finally { if (Test-Path $m) { Remove-Item $m -Recurse -Force } }
    }

    It 'planning over a migration that already has a plan is refused' {
        # Replacing a plan under a migration that may already have moved
        # machines would leave its state documents describing work that plan
        # never asked for.
        #
        # The setup uses a real assessment and a real migration rather than one
        # path pretending to be both - an earlier version did that and was
        # caught by the guard that an assessment cannot be a migration.
        $a = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dpa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $m = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dpm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ ap = $a; mp = $m } {
                Initialize-VmfRun -RunPath $ap -RunId 'dup-a' -Kind 'assessment' | Out-Null
                Initialize-VmfRun -RunPath $mp -RunId 'dup-plan' -Kind 'migration' | Out-Null
            }
            @{ schemaVersion = 17; runId = 'dup-a'; generatedUtc = '2026-08-31T00:00:00Z'
               scope = @{ subscriptions = @() }; summary = @{}; vms = @() } |
                ConvertTo-Json -Depth 8 | Set-Content (Join-Path $a 'assessment.json')
            ApproveAssessment $a
            '{ "entries": [] }' | Set-Content (Join-Path $m 'plan.json')
            { New-VmfPlan -AssessmentPath (Join-Path $a 'assessment.json') -OutPath $m } |
                Should -Throw '*already has a plan*'
        }
        finally {
            foreach ($d in $a, $m) { if (Test-Path $d) { Remove-Item $d -Recurse -Force } }
        }
    }

    It 'the wizard names an ASSESSMENT, not a migration' {
        # Stale after the split: the wizard starts by scanning, and the
        # migration gets its name later from the assessment it came from.
        $wiz = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $wiz | Should -Match 'assessment-\$\{d\.getFullYear'
        $wiz | Should -Match "runName: 'Name for this assessment'"
    }
}
