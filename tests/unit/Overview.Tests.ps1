#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# HOME-1 - the front door.
#
# index.html was the migrations page - a leftover from when Migrations WAS
# the product. So the name
# of the whole tool opened one of its five areas, and somebody arriving for the
# first time landed in the middle of the thing rather than at the start of it.
#
# The migrations list is migrations.html now. index.html answers the two
# questions a person actually arrives with: WHAT IS HAPPENING, and WHAT NEEDS
# ME.
#
# THE RULE THIS PAGE LIVES BY: it must never invent a number. An overview that
# summarises is an overview that can disagree with the pages beneath it - and a
# disagreement here is worse than no overview, because this is the screen a
# person trusts BEFORE they look at anything else. So every figure is counted
# from the store documents, and every figure links to the page that owns it.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    # NOT $script:home: $HOME is a read-only automatic variable, and assigning
    # it takes the whole FILE down with "Cannot overwrite variable HOME",
    # naming nothing that appears in this test. Same family as the $p rule in
    # CLAUDE.md - do not borrow a name the shell already owns.
    $script:overview = (Get-VmfPageSource -Path (Join-Path $script:dash 'index.html'))
    $script:runs     = (Get-VmfPageSource -Path (Join-Path $script:dash 'migrations.html'))
    $script:help     = Get-Content (Join-Path $script:dash 'help.js') -Raw
}

Describe 'HOME-1: the pages swapped places properly' {

    It 'the migrations page exists under its own name' {
        Test-Path (Join-Path $script:dash 'migrations.html') | Should -BeTrue
        $script:runs | Should -Match 'loadRuns' -Because 'this is the run list, moved not rewritten'
    }

    It 'and index.html is no longer that page' {
        $script:overview | Should -Not -Match 'function loadRuns'
        $script:overview | Should -Match '(?i)Overview'
    }

    It 'nothing still points a person at the old address' {
        # A link to index.html?run= would now open the overview with a parameter
        # it ignores - a dead end that looks like a working link.
        foreach ($f in Get-ChildItem $script:dash -Filter '*.html') {
            ((Get-VmfPageSource -Path $f.FullName)) | Should -Not -Match 'index\.html\?run=' -Because "$($f.Name) must use the new address"
        }
        $script:help | Should -Not -Match 'index\.html\?run='
    }

    It 'the navigation offers both, and the front door first' {
        $script:help | Should -Match "href: 'index\.html'"
        $script:help | Should -Match "href: 'migrations\.html'"
        $frontDoor = $script:help.IndexOf("href: 'index.html'")
        $migr = $script:help.IndexOf("href: 'migrations.html'")
        $frontDoor | Should -BeGreaterThan -1
        $frontDoor | Should -BeLessThan $migr -Because 'the front door comes before one of the rooms'
    }

    It 'the ROOT address belongs to the overview, in three places that must agree' {
        # The root address (https://vmf-dash-examplesuffix...) opened the
        # migrations page, not the overview.
        #
        # The server was right; the NAV was not. help.js falls back to a
        # filename when the address ends in a slash - which is the root - and
        # the blanket rename turned that fallback from index.html into
        # migrations.html. So at the root the Migrations tab highlighted, the
        # help opened the migrations topic, and a support bundle recorded the
        # wrong page. A rename that treats a DEFAULT as a LINK.
        $script:help | Should -Not -Match "pop\(\) \|\| 'migrations\.html'"
        @([regex]::Matches($script:help, "pop\(\) \|\| 'index\.html'")).Count |
            Should -Be 3 -Because 'the nav, the help topic and the support bundle all fall back to the default document'

        # And IIS is told which file that is, rather than inheriting its
        # built-in order.
        $webConfig = Get-Content (Join-Path $script:dash 'web.config') -Raw
        $webConfig | Should -Match '<defaultDocument'
        $webConfig | Should -Match '<add value="index\.html" />'
    }

    It 'the moved page has its own name in the tab' {
        # Every other page says which one it is. This one said just "VMF
        # Migration Dashboard", which was fine while it WAS the dashboard.
        # BRAND-1 renamed the tab to the product's own name.
        $script:runs | Should -Match '<title>Migration Factory - Migrations</title>'
    }

    It 'the deploy ships both pages' {
        # Shipping one and not the other is a 404 on the address people reach
        # for first.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match "'index\.html'"
        $deploy | Should -Match "'migrations\.html'"
    }

    It 'and the in-app guide covers the new page' {
        $guide = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'operator-guide.json') -Raw | ConvertFrom-Json
        $guide.screens.PSObject.Properties.Name | Should -Contain 'index.html'
        $guide.screens.PSObject.Properties.Name | Should -Contain 'migrations.html'
    }
}

Describe 'HOME-1: it reports, it does not compute' {

    It 'reads the store with the viewer own token, like every other read page' {
        # STORE-READ-1: the browser no longer holds a token for the storage
        # account - it holds one for the service, and the service reads. The
        # rule is the one it always was: the read is made AS THE VIEWER, so
        # what they may see is decided per person and not once for the app.
        $script:overview | Should -Match 'access_as_user' -Because 'the read is made as the person, not as the app'
        $script:overview | Should -Not -Match 'storage\.azure\.com'
        $script:overview | Should -Match 'blobList'
        $script:overview | Should -Match 'blobJson'
    }

    It 'changes nothing - there is no write path on this page at all' {
        # An overview with a button is an overview somebody acts on without
        # having looked at the thing they are acting on.
        #
        # The marker used to be "this page has no facade token". It cannot be
        # any more - reading needs one now - so the rule names the writes
        # themselves: no verb, and no caller that carries one.
        $script:overview | Should -Not -Match "method: 'POST'"
        $script:overview | Should -Not -Match "method:\s*['`"]" -Because 'the only verb here is GET, which is the default'
        $script:overview | Should -Not -Match 'VmfHelp\.(apiPost|apiFetch)\(' -Because 'those are how a page acts'
        # and the only things it does call are the read helpers. PAGE-LOAD-1
        # added the third, storeDocs: many documents read in one call, a GET.
        # STORE-HOLDS-ONE-1 added storeHolds: it asks a listing the page holds,
        # and calls nothing.
        $calls = @([regex]::Matches($script:overview, 'VmfHelp\.(store\w+)\(') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $calls | Should -Be @('storeBlob', 'storeDocs', 'storeHolds', 'storeList')
    }

    It 'takes the machine states that need a person from the same list the run page uses' {
        # Two lists would drift, and the drift would show as an overview that
        # says everything is fine while the run page says otherwise.
        # OVERVIEW-SUMMARY-1: the overview keeps no list at all now. It asks
        # help.js, whose runGroup the migrations list groups by, and
        # tests/js/overview-summary.test.js holds every page's copy to it.
        $code = Get-VmfCodeOnly -Text $script:overview -Language CStyle
        $code | Should -Not -Match 'const PROBLEM_STATES'
        $code | Should -Match 'VmfHelp\.runGroup\('
        $code | Should -Match 'VmfHelp\.runWaitingCount\('
        # OLD-VERSION-READERS-REMOVE-6: the engine's count of the machines that
        # wait for a person, never the stop states counted in its place.
        $code | Should -Not -Match 'runProblemCount'
        (Get-VmfCodeOnly -Text $script:help -Language CStyle) | Should -Not -Match 'runProblemCount'
        $script:help | Should -Match "PROBLEM_STATES = \['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'\]"
        $script:runs | Should -Match "PROBLEM_STATES = \['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'\]"
    }

    It 'counts from the documents rather than from a tally' {
        # stateCounts is the engine's own count, and running is the engine's own
        # list. The page adds them up; it does not keep its own record.
        $script:overview | Should -Match 'stateCounts'
        $script:overview | Should -Match 'run-status\.json'
        $script:overview | Should -Match 'approval\.json' -Because 'reviewed is a document, not a guess'
    }

    It 'every panel opens the page that owns its numbers' {
        # PAGE-SCALE-OVERVIEW-1: each row of the one list opens its migration,
        # or the review of its assessment (VmfHelp.listHref builds the
        # address). PAGE-SCALE-REPORTS-1: the Safety copies card, which linked
        # each migration with VmfRun.link, moved to the Reports page.
        # OVERVIEW-MORE-LINE-1: the line below the list that linked Projects and
        # Reports is gone; both are in the top navigation. Only the first
        # visit's "Create a project" button still opens the Projects page.
        $script:overview | Should -Match "dest: \{ page: 'migrations', run: r\.id \}"
        $script:overview | Should -Match "dest: \{ page: 'wizard', run: r\.id \}"
        $script:overview | Should -Match "<a class=`"btn`" href=`"projects\.html`">"
        $script:overview | Should -Not -Match "href=`"reports\.html`""
    }

    It 'escapes everything it renders' {
        # Run ids, project names and wave names all come off the store.
        #
        # Only the lines that BUILD HTML are examined - a fetch URL is full of
        # `${cfg.storageAccount}` and that is not output, so scanning the whole
        # file just produces noise and teaches somebody to widen the exception
        # list until the check means nothing.
        $htmlLines = @($script:overview -split "`n" | Where-Object { $_ -match '<(td|th|tr|a |span|div|h1|h2|p|button)' })
        @($htmlLines).Count | Should -BeGreaterThan 10 -Because 'a check that reads nothing passes everything'

        $bare = foreach ($line in $htmlLines) {
            foreach ($m in [regex]::Matches($line, '\$\{[^}]*\}')) {
                $v = $m.Value
                if ($v -match '^\$\{\s*esc\(' -or $v -match 'encodeURIComponent\(') { continue }
                # A number the page counted itself is not attacker-controlled.
                if ($v -match '^\$\{[rp]\.(attention|running|found|assessments|migrations)\}$') { continue }
                # A ternary that escapes inside both arms is escaped.
                if ($v -match 'esc\(') { continue }

                "$($line.Trim()) -> $v"
            }
        }
        @($bare) -join '; ' | Should -BeNullOrEmpty -Because 'store content must not be interpolated raw'
        # PAGE-SCALE-REPORTS-1: the one helper the loop trusted (runLink) left
        # with the Safety copies card, so the loop trusts nothing now.
        $script:overview | Should -Not -Match 'runLink'
    }
}

Describe 'HOME-1: the states a person actually arrives in' {

    It 'an empty tenant is told what to do, once' {
        # A wall of empty panels says nothing except that the product is empty.
        $script:overview | Should -Match 'firstTitle'
        $script:overview | Should -Match "!state\.projects\.length && !state\.runs\.length"
        $script:overview | Should -Match 'projects\.html'
    }

    It 'opens on the tile with something to do, and hides nothing until a person selects' {
        # PAGE-SCALE-OVERVIEW-1 replaced the panels that were absent when empty
        # with four count tiles that are always drawn. The list opens on
        # Waiting for a person, or the first tile with rows
        # (VmfHelp.listDefaultTile; page-scale-list.test.js runs it).
        $script:overview | Should -Match "VmfHelp\.listMount\(\`$\('#ov-list'\), \{ id: 'ov', preferred: 'person'"
        $script:help | Should -Match 'function listDefaultTile\('
    }

    It 'and runs outside a project are still shown' {
        # The command line can make one. Hiding them is how somebody
        # concludes their migration has vanished.
        $script:overview | Should -Match 'loose'
    }

    It 'says it is reading before it has anything to show' {
        $script:overview | Should -Match 'UX\.working'
    }
}
