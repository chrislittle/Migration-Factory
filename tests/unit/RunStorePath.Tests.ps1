#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PROJECT-2: every endpoint that acts on a run knows about projects.
#
# A run inside a project lives at `project/run`. The route can only carry
# `runs/{runId}` - one segment - so the project travels beside it.
#
# SEVENTEEN endpoints take a run id. FOUR composed the project back on, each in
# its own expression. THIRTEEN did not, and for a run inside a project they
# looked where it is not:
#
#   No plan found at 'azblob://.../vmf-runs/<run>/plan.json'
#
# MEASURED on a real install, 2026-09-15, where EVERY run is inside a
# project: saving a plan failed, capacity said nothing had been worked out, and
# accepting the settings answered "the plan version being accepted is required"
# - because the step that reads the plan to find its version had found no plan.
#
# AND THREE PLACES ENUMERATED ONE LEVEL DEEP, so a project folder came back
# looking like a run and the runs inside it were never seen. One of them is the
# schedule pass: A SCHEDULED WAVE INSIDE A PROJECT NEVER STARTED, with no error
# anywhere, because nothing ever looked in the folder it was in.
#
# A right answer written out four times is a wrong answer thirteen times. These
# tests refuse an endpoint that composes its own.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:appDir = Join-Path $script:repoRoot 'src' 'facade' 'app'
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # Every endpoint, with its route and its code.
    $script:endpoints = @(
        Get-ChildItem $script:appDir -Filter 'function.json' -Recurse | ForEach-Object {
            $doc = Get-Content $_.FullName -Raw | ConvertFrom-Json
            $route = @($doc.bindings | Where-Object { $_.type -eq 'httpTrigger' } |
                ForEach-Object { [string]$_.route }) | Select-Object -First 1
            $runPs1 = Join-Path $_.Directory.FullName 'run.ps1'
            [pscustomobject]@{
                Name  = $_.Directory.Name
                Route = $route
                Code  = if (Test-Path $runPs1) { Get-VmfCodeOnly -Path $runPs1 } else { '' }
            }
        })
    $script:core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
}

Describe 'PROJECT-2: one place knows how a run is addressed' {

    It 'finds endpoints to check, so this cannot pass by reading nothing' {
        $script:endpoints.Count | Should -BeGreaterThan 20
        @($script:endpoints | Where-Object { $_.Route -match '\{runId\}' }).Count |
            Should -BeGreaterThan 10 -Because 'most of the API is about a run'
    }

    It 'the helper exists and is exported' {
        $script:core | Should -Match 'function Get-VmfFacadeRunStorePath'
        $manifest = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Raw
        $manifest | Should -Match "'Get-VmfFacadeRunStorePath'"
        $manifest | Should -Match "'Get-VmfFacadeRunIds'"
    }

    It 'and it reads the project from a body OR a query' {
        # A POST carries it in the body, a GET in the query. An endpoint that
        # only looked at one would work for half the API.
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeRunStorePath \{.*?\n\}').Value
        $fn | Should -Match '\$Request\.Body\.project'
        $fn | Should -Match '\$Request\.Query\.project'
    }

    It 'EVERY endpoint that takes a run id resolves its path through the helper' {
        $offenders = @()
        foreach ($e in $script:endpoints) {
            # An HTTP endpoint that takes a run id from its ROUTE. The two
            # timer passes have no route: they take the id from the enumerator,
            # which already returns `project/run`, so their call is correct.
            if (-not $e.Route) { continue }
            if ($e.Route -notmatch '\{runId\}') { continue }
            if (-not $e.Code) { continue }
            if ($e.Code -notmatch 'Get-VmfFacadeStorePath|Get-VmfFacadeRunStorePath') { continue }
            if ($e.Code -notmatch 'Get-VmfFacadeRunStorePath -Request') {
                $offenders += $e.Name
            }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty -Because 'thirteen of them composed their own and looked where the run is not'
    }

    It 'and none of them composes the project by hand any more' {
        # Four did, each in its own expression, and being right four times is
        # what made thirteen wrong ones invisible.
        $offenders = @()
        foreach ($e in $script:endpoints) {
            if ($e.Code -match 'Get-VmfFacadeStorePath -RunId \$\(if \(\$project\)') { $offenders += $e.Name }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'PROJECT-2: nothing enumerates the store one level deep' {

    It 'the enumerator tells a project from a run the way the dashboard does' {
        # A top-level prefix is a PROJECT if project.json sits inside it, and a
        # RUN if not. The same rule as listRunsAcrossProjects, which the pages
        # have used since ASSESS-LIST-1.
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeRunIds \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match 'project\.json'
        # PROJECT-3 moved the list of folders that are not runs into
        # Test-VmfFacadeRunFolder, because the browser has to agree with it.
        $fn | Should -Match 'Test-VmfFacadeRunFolder'
    }

    It 'and every place that walks the store uses it' {
        # /api/runs, the retention pass and the schedule pass each had their
        # own listing, and all three stopped at the top level. PAGE-LOAD-1
        # removed /api/runs: no page asked for it any more.
        foreach ($name in 'RetentionRunner', 'ScheduleRunner') {
            $e = $script:endpoints | Where-Object { $_.Name -eq $name }
            $e | Should -Not -BeNullOrEmpty -Because "$name should exist"
            $e.Code | Should -Match 'Get-VmfFacadeRunIds -StorePath' -Because "$name must see runs inside projects"
            $e.Code | Should -Not -Match 'comp=list&delimiter' -Because "$name must not list the store itself"
        }
    }

    It 'PROJECT-3: and hands it the container root it just resolved, not some other variable' {
        # THIS IS WHAT THE RULE ABOVE MISSED. Both timer passes called the
        # walker, exactly as required - with a variable that has no value at
        # that point in the script. So both passes died before they looked at a
        # single run: no safety copy reaped, no scheduled wave started, and the
        # test above stayed green because the CALL was there.
        # What the passes actually do is held in tests/unit/TimerPasses.Tests.ps1.
        foreach ($name in 'RetentionRunner', 'ScheduleRunner') {
            $e = $script:endpoints | Where-Object { $_.Name -eq $name }
            $root = [regex]::Match($e.Code, '(?m)^\s*\$(?<v>\w+) = Get-VmfFacadeStorePath\s*$').Groups['v'].Value
            $root | Should -Not -BeNullOrEmpty -Because "$name must resolve the container root before it walks it"
            $e.Code | Should -Match ([regex]::Escape("Get-VmfFacadeRunIds -StorePath `$$root")) `
                -Because "$name must walk the root it resolved, and it resolved `$$root"
        }
    }
}

Describe 'PROJECT-3: a folder beside the runs is not a run' {

    It 'the service knows the rule, in one place' {
        $script:core | Should -Match 'function Test-VmfFacadeRunFolder'
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeRunIds \{.*?\n\}').Value
        # Both branches of the walk - the blob listing and the local one.
        ([regex]::Matches($fn, 'Test-VmfFacadeRunFolder')).Count | Should -BeGreaterOrEqual 4 `
            -Because 'the top level and a project''s children, in both branches'
    }

    It 'and so does every page that walks the store itself' {
        # The overview walks the store in its own load(); every other page goes
        # through listRunsAcrossProjects. Both must apply the same rule, or a
        # folder that is not a run is asked for a run record it cannot have -
        # which is the 404 seen on the front page, 2026-09-16.
        # EVERY page, found by looking rather than by naming two. The first
        # version of this rule listed help.js and index.html, which are the two
        # I had just edited - and projects.html walks the store as well, so the
        # rule passed over the page that still had the defect. A guard that
        # holds only the files its author remembered is the defect it exists
        # to refuse.
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        $pages = @(Get-ChildItem $dash -File | Where-Object { $_.Extension -in '.html', '.js' })
        $pages.Count | Should -BeGreaterThan 5 -Because 'this must not pass by finding nothing'
        foreach ($page in $pages.Name) {
            $code = Get-VmfCodeOnly -Path (Join-Path $dash $page)
            foreach ($walk in [regex]::Matches($code, "blobList\((?<a>'',|``\`$\{\w+\}/``),\s*'/'\)")) {
                $tail = $code.Substring($walk.Index, [Math]::Min(220, $code.Length - $walk.Index))
                $tail | Should -Match 'runFolderIsRun' `
                    -Because "$page walks the store at $($walk.Value) and must skip what is not a run"
            }
        }
    }
}
