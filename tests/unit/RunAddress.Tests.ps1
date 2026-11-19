#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RUNID-2: a run has ONE identity, and no page spells it by hand.
#
# A run inside a project lives at `project/run`. That string cannot be used
# everywhere, and the product used the wrong one in each place:
#
#   the store      project/run       a path, so the slash belongs
#   the API route  runs/{runId}      ONE segment, so the slash cannot fit
#   a page link    ?run=..&project=  two parameters, or the page loses one
#
# WHAT IT COST, and when. PROJECT-1 made a run live under a project on
# 2026-09-01. The same day the slash was met twice and patched twice, locally -
# the engine dispatch, then assessments/{runId}/approve - and the second commit
# was titled "the same slash, the same fix". It shipped two files and no test.
# So every call site written after it repeated the defect, and on 2026-09-15
# "Plan a migration from this" returned to the start of the wizard with
# four 404s in the browser console.
#
# THE RULE IS THE FIX. Patching seventeen links and seventeen routes would wait
# for the eighteenth. These tests refuse a page that builds any of the three
# shapes itself, so the next one cannot be written.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:dashDir = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages = @(Get-ChildItem $script:dashDir -Filter '*.html' -File)
    # READ AS CODE. Every page explains this rule in a comment, and a comment
    # that quotes the wrong shape would satisfy a text search for it.
    $script:code = @{}
    foreach ($p in $script:pages) {
        $script:code[$p.Name] = Get-VmfCodeOnly -Text ((Get-VmfPageSource -Path $p.FullName)) -Language CStyle
    }
    $script:helpCode = Get-VmfCodeOnly -Path (Join-Path $script:dashDir 'help.js') -Language CStyle
}

Describe 'RUNID-2: the rule lives in one place' {

    It 'finds pages to check, so this cannot pass by reading nothing' {
        $script:pages.Count | Should -BeGreaterThan 5
    }

    It 'help.js owns the three ways of writing a run' {
        foreach ($fn in 'runParse', 'runStorePath', 'runRouteSegment', 'runWithProject', 'runLink') {
            $script:helpCode | Should -Match "function $fn\(" -Because "$fn is the rule"
        }
        $script:helpCode | Should -Match 'const VmfRun = \{'
        $script:helpCode | Should -Match 'VmfRun,'
    }

    It 'and a route segment can never carry the project' {
        # The one line that matters: the segment comes from the RUN, not the id.
        $seg = [regex]::Match($script:helpCode, '(?s)function runRouteSegment\(.*?\n  \}').Value
        $seg | Should -Match 'runParse\(id\)\.run'
    }
}

Describe 'RUNID-2: no page builds a run link by hand' {

    It 'no page writes a query string with run= in it' {
        # `page.html?run=` is the shape that loses the project. 17 of them did.
        $offenders = @()
        foreach ($name in $script:code.Keys) {
            foreach ($line in ($script:code[$name] -split "`n")) {
                if ($line -match '\.html\?run=') { $offenders += "$name : $($line.Trim())" }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'VmfRun.link is the only thing that may write one'
    }

    It 'and every page that links to a run uses the helper' {
        $linkers = @($script:code.Keys | Where-Object { $script:code[$_] -match 'VmfRun\.link\(' })
        $linkers.Count | Should -BeGreaterThan 3 -Because 'several pages link to runs'
    }
}

Describe 'RUNID-2: no page puts an id into a route segment' {

    It 'no page interpolates an id straight into runs/ or assessments/' {
        # `runs/${encodeURIComponent(runId)}` is correct ONLY when runId is
        # bare, and on half these pages it is not. The helper decides.
        $offenders = @()
        foreach ($name in $script:code.Keys) {
            foreach ($line in ($script:code[$name] -split "`n")) {
                if ($line -match '(runs|assessments)/\$\{encodeURIComponent\(') {
                    $offenders += "$name : $($line.Trim())"
                }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'VmfRun.routeSegment is the only thing that may build one'
    }

    It 'and no page splits an id on a slash for itself' {
        # assessments.html did this by hand, correctly, and was the only page
        # that did. One implementation, or the next page copies the other one.
        $offenders = @()
        foreach ($name in $script:code.Keys) {
            if ($script:code[$name] -match "indexOf\('/'\)") { $offenders += $name }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'RUNID-3: no page builds a STORE path from a bare run' {
    # THE THIRD GAP IN THIS FILE'S OWN GUARDS, found in use on the fixed
    # build. The first two watched links and route segments. The log reader
    # composed `${runId}/logs/events.jsonl` - a STORE path - and nothing here
    # looked at those, so it read a project's run at the wrong place and 404d
    # while every other read on the page was correct.
    #
    #   GET .../store/blob?path=assessment-2026-09-15-1829%2Flogs%2Fevents.jsonl  404
    #
    # A guard that knows two of the three ways a run is written is a guard
    # against two thirds of this defect.

    It 'no page interpolates a bare run id into a path' {
        $offenders = @()
        foreach ($name in $script:code.Keys) {
            foreach ($line in ($script:code[$name] -split "`n")) {
                # The PAGE-LEVEL variables only. A helper that takes the id as
                # a parameter and appends a relative path is doing the right
                # thing - the report reader does exactly that, and the caller
                # hands it the full id.
                if ($line -match '\$\{(runId|currentRun)\}/') {
                    $offenders += "$name : $($line.Trim())"
                }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'runPrefix is the only thing that may build one'
    }

    It 'and whatever reads a report is handed the FULL id' {
        # The report reader takes the id as a parameter and appends to it, so
        # it is only ever as right as what the page hands it. The wizard handed
        # it the bare run.
        $script:code['wizard.html'] | Should -Match 'getRunId: \(\) => runFullId\(\)'
        $script:code['wizard.html'] | Should -Not -Match 'getRunId: \(\) => runId'
    }

    It 'and the pages that read a run build their paths through the prefix' {
        foreach ($name in 'wizard.html', 'waves.html') {
            @([regex]::Matches($script:code[$name], 'runPrefix\(\)')).Count |
                Should -BeGreaterThan 2 -Because "$name reads several documents for a run"
        }
    }
}

Describe 'RUNID-2: the pages that read a run know about projects' {

    It 'every page that builds a store path for a run reads the project' {
        # waves.html had NO concept of a project, so it could not read a run
        # that belonged to one - and said "the dashboard may be pointed at the
        # wrong storage account".
        foreach ($name in 'wizard.html', 'waves.html') {
            $script:code[$name] | Should -Match "get\('project'\)" -Because "$name reads a run's documents"
            $script:code[$name] | Should -Match 'VmfRun\.storePath\(' -Because "$name must not compose the path itself"
        }
    }

    It 'and both normalise the identity exactly once' {
        foreach ($name in 'wizard.html', 'waves.html') {
            @([regex]::Matches($script:code[$name], 'VmfRun\.parse\(runId\)')).Count |
                Should -Be 1 -Because "$name must decide what a run is called in one place"
        }
    }
}

Describe 'PROJECT-4: a page that acts on a run SENDS the project' {
    # MEASURED IN THE BROWSER, 2026-09-17, on a corporate install. Accept on
    # the Migrations page gave:
    #
    #   "That record is not there. If it belongs to a project, open it from the
    #    Assessments page or the Migrations page, which name the project in the
    #    link."
    #
    # A run inside a project is `project/run`, and the halves go to DIFFERENT
    # PLACES: the run alone in the address, the project in the BODY. The
    # Migrations page did neither - it put the whole id in the address with the
    # slash escaped, which matches no route, and it never sent the project at
    # all. FIFTEEN actions on that page, every one of them: accept, approve,
    # report, clear a claim, halt, resume, resolve, rebuild, restore, schedule,
    # start a wave, stop, discard.
    #
    # THAT IS THE MAIN OPERATOR PAGE, and it could not do anything at all to a
    # run inside a project - which is every run the product makes now.
    #
    # WHY BOTH GUARDS MISSED IT, which is the part worth keeping:
    #
    #   * the STATIC rule above bans `runs/${encodeURIComponent(` at a call
    #     site. This page had moved that one level up, into its own runSeg, so
    #     there was no literal to find. A rule that reads call sites cannot
    #     follow a defect into a function.
    #   * the JS test RUNS the helpers, which would have caught it - but its
    #     page list was written by hand as two pages, and this was not one.
    #
    # One rule could not see it, the other was not pointed at it. Both are
    # fixed: the JS test finds its pages by looking, and this rule is about
    # SENDING, which no amount of indirection hides.

    It 'every page that posts to a run route carries the project' {
        $senders = @($script:code.Keys | Where-Object { $script:code[$_] -match 'runs/\$\{' })
        @($senders).Count | Should -BeGreaterThan 2 -Because 'several pages act on runs'
        # migrations.html named on purpose: it is the page this was found on,
        # and a discovery bug that dropped it would make this vacuous again.
        $senders | Should -Contain 'migrations.html'

        $missing = foreach ($name in $senders) {
            if ($script:code[$name] -notmatch 'withProject') { $name }
        }
        @($missing) | Should -BeNullOrEmpty `
            -Because 'a run inside a project cannot be found without it, and every action answers "that record is not there"'
    }

    It 'and no page builds a route segment from the FULL id' {
        # The other half of the same defect, and the one the old static rule
        # could not see. `encodeURIComponent(currentRun)` is correct only when
        # currentRun is bare - and on this page it never was.
        $offenders = foreach ($name in $script:code.Keys) {
            foreach ($line in ($script:code[$name] -split "`n")) {
                if ($line -notmatch 'encodeURIComponent\(') { continue }
                if ($line -match 'encodeURIComponent\((currentRun|runId|runFullId\(\))\)') {
                    $offenders += "$name : $($line.Trim())"
                }
            }
        }
        @($offenders) | Should -BeNullOrEmpty -Because 'VmfRun.routeSegment is the only thing that may build one'
    }
}
