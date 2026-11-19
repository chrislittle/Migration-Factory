#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NAV-1 - the shared navigation bar is a CONTRACT, and every page must keep it.
#
# Found 2026-09-02: on the overview page, 'Get help' went to
# .../index.html# instead of opening help.
#
# The cause was that the bar was half shared. `help.js`
# DRAWS the whole bar, including the "Get help" tab - so a new page gets the
# tab for free and looks finished. But the tab's click handler is attached by
# `VmfHelp.install()`, which each page must CALL. A page that forgets gets a
# control that looks real and behaves like a dead link to '#'.
#
# Three pages had forgotten: index.html (new that day) and, for longer than
# anybody noticed, projects.html and assessments.html.
#
# Nothing checked it. "Every page has a nav container" was tested; "every page
# makes the nav WORK" was not - which is the difference between markup and a
# working control. This file owns that contract now.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages    = @(Get-ChildItem $script:dash -Filter '*.html')
    $script:help     = Get-Content (Join-Path $script:dash 'help.js') -Raw
    $script:appCss   = Get-Content (Join-Path $script:dash 'app.css') -Raw
}

Describe 'NAV-1: every page that shows the bar makes it work' {

    It 'found the pages, or this file is checking nothing' {
        @($script:pages).Count | Should -BeGreaterThan 5
    }

    It 'a page with a nav container loads the file that fills it' {
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -match '<nav class="topnav">' -and $text -notmatch 'src="help\.js"') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'an empty bar is worse than no bar'
    }

    It 'and a page that loads it ATTACHES the handlers it draws' {
        # THE BUG. installNav() draws the Get help tab; install() makes it work.
        # Drawing without attaching is how a dead link ships looking finished.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -match 'src="help\.js"' -and $text -notmatch 'VmfHelp\.install\(') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'the Get help tab is a control, not decoration'
    }

    It 'the Get help tab really is drawn by the shared file, not per page' {
        # If a page drew its own, the check above would pass while the tab
        # behaved differently from every other page.
        $script:help | Should -Match "id=`"nav-help`""
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -match 'id="nav-help"') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'one bar, drawn once'
    }

    It 'every tab in the bar points at a page that exists' {
        # A tab to a file that is not there is the same class of defect, and the
        # migrations.html rename was one rename away from causing it.
        $hrefs = [regex]::Matches($script:help, "href:\s*'([^']+\.html)'") |
            ForEach-Object { $_.Groups[1].Value }
        @($hrefs).Count | Should -BeGreaterThan 4
        foreach ($h in $hrefs) {
            Test-Path (Join-Path $script:dash $h) | Should -BeTrue -Because "the bar offers $h"
        }
    }

    It 'and the deploy ships every page the bar offers' {
        # Shipping the bar but not one of its destinations is a 404 a person
        # reaches by clicking, not by typing.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $hrefs = [regex]::Matches($script:help, "href:\s*'([^']+\.html)'") |
            ForEach-Object { $_.Groups[1].Value }
        foreach ($h in $hrefs) {
            $deploy | Should -Match ([regex]::Escape("'$h'")) -Because "the bar offers $h"
        }
    }
}

Describe 'NAV-1: cards contain their own text' {

    It 'no card puts prose straight into .card, which has no padding' {
        # Found: card text was cut off.
        #
        # `.card` carries overflow:hidden and no padding - the padding lives in
        # `.cardbody`. A card that skips the wrapper renders its copy flush
        # against the left edge and CLIPS it on the right, which is what the
        # first-run panel did.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            # DARK-1 SILENTLY DISABLED THIS TEST. The precondition asked each
            # PAGE whether it defined .cardbody - true while every page carried
            # its own CSS, and false for all eight the moment that CSS moved to
            # app.css. Every page was skipped, the loop body never ran, and the
            # test kept passing on an empty result for a defect already
            # reported. The rule belongs to the stylesheet now, so ask it.
            if ($script:appCss -notmatch '\.cardbody\s*\{') { continue }
            # BOUNDED. `.*?` under (?s) is not confined to one card - it crossed
            # 159 lines of wizard.html, from the card() helper into a different
            # function, and reported a card that does not exist. The header's
            # content is "anything that is not the end of the header", which is
            # what was meant all along.
            $m = [regex]::Matches($text, '(?s)<div class="card"[^>]*>\s*<div class="ch">(?:(?!</div>).)*</div>\s*<(p|ul|ol)\b')
            if ($m.Count) { "$($p.Name) ($($m.Count))" }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'the copy needs .cardbody or it is clipped'
    }
}

Describe 'ENTRY-1: starting an assessment' {

    It 'the front door offers it' {
        # Only the migrations page offered 'assess an estate', because that
        # page used to BE the front door. The primary
        # action stayed behind when the door moved.
        # NOT $home - see the CLAUDE.md trap list.
        $frontDoor = (Get-VmfPageSource -Path (Join-Path $script:dash 'index.html'))
        $frontDoor | Should -Match 'assess-btn'
        $frontDoor | Should -Match "href=`"wizard\.html`""
    }

    It 'and so does the page that lists them' {
        $assess = (Get-VmfPageSource -Path (Join-Path $script:dash 'assessments.html'))
        $assess | Should -Match 'assess-btn'
    }

    It 'under ONE name, not three' {
        # It was "Assess an estate" on migrations, "Scan for machines" in the
        # assessments empty state, and "New assessment" on projects. Three
        # names for one action is the same fault as three words for one noun.
        #
        # Projects keeps its own wording on purpose: that button carries the
        # project, so it is a different, narrower action.
        $names = @()
        foreach ($f in 'index.html', 'assessments.html', 'migrations.html') {
            $text = (Get-VmfPageSource -Path (Join-Path $script:dash $f))
            $names += [regex]::Matches($text, "(?m)^\s*(?:assessBtn|scanBtn|menuBtn)\s*:\s*'([^']*)'") |
                ForEach-Object { $_.Groups[1].Value }
        }
        @($names).Count | Should -BeGreaterThan 2 -Because 'all three pages must name it'
        @($names | Sort-Object -Unique).Count | Should -Be 1 -Because "one action, one name - found: $($names -join ' / ')"
    }
}

Describe 'NAV-1: the bar looks the same everywhere' {

    It 'no page styles form controls in the browser default font' {
        # Found: fonts differed across many pages, for example in the
        # drop-down lists on the admin page.
        #
        # A <select>, <input>, <button> or <textarea> does NOT inherit the page
        # font - the browser gives it the system one. So a page with controls
        # and no rule renders them in a different typeface from everything
        # around them, which is exactly what he saw.
        # DARK-1: stated ONCE, in the one stylesheet, rather than eight times.
        # That is the point of the file - and it is why this check moved:
        # asserting it per page would now assert the opposite of the rule.
        $appCss = Get-Content (Join-Path $script:dash 'app.css') -Raw
        $appCss | Should -Match '(?m)^button, input, select, textarea \{[^}]*font: inherit' `
            -Because 'a control must be set in the page font'

        # And every page that has a control must LOAD that stylesheet.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -notmatch '<(select|input|textarea|button)') { continue }
            if ($text -notmatch 'href="app\.css"') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'a page with controls must load the stylesheet that styles them'
    }
}
