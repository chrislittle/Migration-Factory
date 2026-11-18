#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# A test of the flow found the Start over button did nothing - and before
# that, a column nothing fed, a link to settings that looked like a different
# page, and a nav entry that vanished between pages. Each was found by a person
# clicking it, which is the most expensive way to find any of them.
#
# A rendered control that nothing listens to is mechanically detectable, so it
# should never reach a person again. This walks every dashboard page and fails
# when a button exists with no handler, or an action attribute nothing binds.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:pages = @('index', 'reports', 'waves', 'wizard', 'access') | ForEach-Object {
        [pscustomobject]@{ Name = "$_.html"; Text = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' "$_.html")) }
    }
    # A control counts as WIRED when the script refers to it at all - by
    # selector, by getElementById, or through a variable it was assigned to.
    # The rule is deliberately generous: this is here to catch a control the
    # code never mentions (the owner clicked one), not to police style, and a
    # noisy lint is one somebody switches off.
    function Script:IsWired([string]$text, [string]$id) {
        $e = [regex]::Escape($id)
        return ($text -match "'#$e'") -or ($text -match "`"#$e`"") -or
               ($text -match "getElementById\('$e'\)") -or ($text -match "getElementById\(`"$e`"\)")
    }
    function Script:ToCamel([string]$attr) {
        ($attr -split '-' | ForEach-Object -Begin { $i = 0 } -Process {
            if ($i -eq 0) { $_ } else { $_.Substring(0,1).ToUpper() + $_.Substring(1) }
            $i++
        }) -join ''
    }
}

Describe 'Every control on a dashboard page does something' {
    It 'no button is rendered with nothing listening to it' {
        $dead = foreach ($page in $script:pages) {
            # buttons declared in the static markup with a fixed id
            foreach ($m in [regex]::Matches($page.Text, '<button[^>]*\bid="([a-zA-Z0-9_-]+)"')) {
                $id = $m.Groups[1].Value
                if (-not (Script:IsWired $page.Text $id)) { "$($page.Name): <button id=`"$id`"> is rendered but the script never refers to it" }
            }
        }
        $dead -join '; ' | Should -BeNullOrEmpty -Because 'a button that does nothing is worse than no button - "start over" was found this way'
    }

    It 'every data-action attribute the markup renders is bound somewhere' {
        $dead = foreach ($page in $script:pages) {
            $attrs = [regex]::Matches($page.Text, '\bdata-([a-z][a-z0-9-]*)="\$\{') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            foreach ($a in $attrs) {
                $camel = [regex]::Replace($a, '-(.)', { param($m) $m.Groups[1].Value.ToUpper() })
                # bound either by attribute selector or read through .dataset
                # a selector may carry a value: [data-mf="x"] is just as bound
                if ($page.Text -notmatch "\[data-$a[\]=]" -and $page.Text -notmatch "dataset\.$camel") {
                    "$($page.Name): data-$a is rendered but nothing ever reads it"
                }
            }
        }
        $dead -join '; ' | Should -BeNullOrEmpty
    }

    It 'every nav entry exists on every page, so the options never move' {
        # Still the guarantee; its source moved. The bar used to be copied into
        # each page, which is how the labels drifted apart - one page said
        # Migrations while five said Runs. It is rendered from help.js now, so
        # what each page owes is the container and the script, and the entries
        # are asserted once where they are defined.
        foreach ($page in $script:pages) {
            $page.Text | Should -Match '<nav class="topnav"></nav>' -Because "$($page.Name) must carry the bar"
            $page.Text | Should -Match 'src="help.js"' -Because "$($page.Name) must load what renders it"
        }
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        foreach ($id in 'assess', 'runs', 'reports', 'access') {
            $help | Should -Match "id: '$id'" -Because 'every page gets the same options from one place'
        }
        $help | Should -Match 'id="nav-help"'
    }

    It 'the same setting is called the same thing on every page it appears' {
        # The "change them first" link seemed to lead to a page that did not
        # set the settings - it did, but every lever had a different name
        # there, so they did not read as the same settings.
        $wizard = ($script:pages | Where-Object Name -eq 'wizard.html').Text
        $waves  = ($script:pages | Where-Object Name -eq 'waves.html').Text
        # TERM-1: every label is audited for the real Azure term, written in
        # ASD-STE100. Three of the four labels this pinned were
        # invented - there is no "fast networking" and no "temporary drive" in
        # Azure, and "capacity for the move" named no Azure concept at all. The
        # rule here is that the two pages AGREE, so it survives the rename; it
        # is the strings that had to change.
        foreach ($phrase in 'On-demand capacity reservation for this wave',
                            'If files are found on the temporary disk',
                            # WAVE-KERNEL-LINE-1: the kernel setting of a wave is gone; its row stays on both.
                            'Machines whose kernel the product updates if it has no MANA driver',
                            'How long the snapshot is kept') {
            $wizard | Should -Match ([regex]::Escape($phrase))
            $waves  | Should -Match ([regex]::Escape($phrase)) -Because "the wave editor must call it what the wizard calls it: $phrase"
        }
    }
}

Describe 'What the pages need is what the deploy actually ships' {
    # Found by deploying: help.js is shared by every page, was not in the
    # deploy script's file list, and shipping without it would not just remove
    # the help option - each page's script would stop at the point it installs
    # it. A page that references a file the packager does not carry is a
    # broken page, and it is checkable here.
    It 'every local script a page loads is in the deploy package list' {
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $needed = foreach ($page in $script:pages) {
            [regex]::Matches($page.Text, '<script src="([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
        }
        foreach ($file in @($needed | Sort-Object -Unique)) {
            if ($file -match '^https?://') { continue }
            $deploy | Should -Match ([regex]::Escape($file)) -Because "the dashboard pages load $file, so the deploy has to ship it"
        }
    }

    It 'and the deploy REFUSES rather than skipping a file it cannot find' {
        # The complement. The list is now checked against what the pages load,
        # but the packager copied "if it exists" - so a file renamed without
        # updating the list still produced a successful deploy of a broken
        # site, which is exactly how help.js went missing. A listed file that
        # is absent is a mistake, not an option.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $loop = [regex]::Match($deploy, "(?s)foreach \(\`$f in 'index\.html'.*?
    \}").Value
        $loop | Should -Not -BeNullOrEmpty
        $loop | Should -Match 'throw "Refusing to publish'
        $loop | Should -Not -Match 'if \(Test-Path \`$src\) \{ Copy-Item'
    }

    It 'a page still works if a shared file is ever missing' {
        foreach ($page in $script:pages) {
            if ($page.Text -match 'VmfHelp\.install') {
                $page.Text | Should -Match 'if \(window\.VmfHelp\) VmfHelp\.install' -Because "$($page.Name) must lose the help option, not the whole page"
            }
        }
    }
}

Describe 'No function is written and then never called' {
    # focusWaveFromHash was written to make "change them first" land on the
    # right wave, and never called - so the link kept dropping people at the
    # top of a page about arranging machines, which is what the owner reported
    # twice. A function nobody calls is the same defect as a button nobody
    # binds, and it is just as checkable.
    It 'every function a page declares is referenced somewhere in that page' {
        $orphans = foreach ($page in $script:pages) {
            $declared = [regex]::Matches($page.Text, '(?m)^\s*(?:async\s+)?function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(') |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
            foreach ($fn in $declared) {
                # count every mention; a declaration alone means nothing calls it
                $mentions = ([regex]::Matches($page.Text, "\b$([regex]::Escape($fn))\b")).Count
                if ($mentions -le 1) { "$($page.Name): $fn() is declared and never used" }
            }
        }
        $orphans -join '; ' | Should -BeNullOrEmpty -Because 'a function nobody calls is a feature that silently does not exist'
    }
}

Describe 'A refusal reaches the person who pressed the button' {
    # The owner pressed Start, the engine refused a minute later, and nothing
    # anywhere said so - the reason went to the container log and nowhere else.
    # Two halves: the engine has to RECORD it, and the page has to SHOW it.
    It 'the engine writes the reason it refused into the run store' {
        # This test used to assert the exact TEXT of a bare Write-VmfEvent
        # call - and passed for as long as that call could never work.
        # Write-VmfEvent is private, so a bare call from the entrypoint's own
        # scope always failed, and every refusal this wrapper exists to record
        # was lost. Found live by the PERM-2 roles drill, not by this test.
        #
        # So assert the PROPERTY - that the call is made somewhere it can
        # actually resolve - rather than the spelling of one line.
        $entry = Get-Content (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1') -Raw
        $entry | Should -Match 'try \{'
        $entry | Should -Match 'Write-VmfEvent'
        $entry | Should -Match '-Outcome fail'
        $entry | Should -Match '& \(Get-Module VmMigrationFactory\)' -Because 'Write-VmfEvent is private - a bare call cannot see it'
        $entry | Should -Match '(?s)catch \{.*?throw' -Because 'the job must still fail - recording the reason is not swallowing it'
    }

    It 'the wizard watches after starting, and says what the engine said' {
        $wiz = ($script:pages | Where-Object Name -eq 'wizard.html').Text
        # WATCH-1: the LOOP is shared; only the question is per-page.
        $wiz | Should -Match 'VmfHelp\.watchRun'
        $wiz | Should -Match 'function watchForRefusal'
        $wiz | Should -Match 'watchForRefusal\(startedAtUtc\)'
        $wiz | Should -Match "outcome === 'fail'"
        $wiz | Should -Match 'UX\.refused'
    }

    It 'it only reports failures from THIS start, not older ones' {
        # A run that failed yesterday must not be reported as this attempt.
        # WATCH-1 moved the window itself into VmfHelp.watchRun, so the page
        # now says WHERE the window starts and help.js applies it. Both halves
        # are checked: a page that forgot to pass sinceMs would silently report
        # yesterday's failure, and the filter is what makes passing it mean
        # anything.
        $wiz = ($script:pages | Where-Object Name -eq 'wizard.html').Text
        $wiz | Should -Match 'sinceMs: Date\.parse\(sinceUtc\)'
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'Date\.parse\(e\.tsUtc\) < sinceMs'
    }
}

Describe 'WATCH-1: one polling loop, not one per page' {

    It 'no page keeps its own deadline loop' {
        # There were three functions called watchForRefusal. Two were the same
        # function; the third watched a capacity CLAIM and only shared the
        # name. What was genuinely triplicated was the LOOP - and the loop is
        # where the subtle rules live, the load-bearing one being that A READ
        # FAILURE KEEPS WATCHING. Treat a thrown read as a verdict and a slow
        # blob write reports itself as a failure.
        # COMMENT-TRAP-1, found live: this read the WHOLE file, so a comment
        # explaining why a page must not keep its own deadline contained the
        # very text being searched for, and the rule failed on the page that
        # was obeying it. Read the code only.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        $bad = foreach ($page in (Get-ChildItem $dash -Filter '*.html')) {
            $text = Get-VmfCodeOnly -Path $page.FullName
            if ($text -match 'deadline = Date\.now\(\)') { $page.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'the loop belongs to help.js'
    }

    It 'and help.js owns it, with the rule that a bad read is not an answer' {
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match 'async function watchRun'
        $help | Should -Match 'window\.VmfHelp = \{[^}]*watchRun'
        # The catch is deliberate and must stay empty of verdicts.
        $help | Should -Match '(?s)async function watchRun.*?catch \(e\) \{[^}]*one bad read is not an answer'
    }

    It 'every page that watches says what IT is waiting for, and nothing more' {
        # The page supplies `scan`; precedence genuinely differs between them -
        # waves prefers "nothing to reserve" over a failure, the wizard prefers
        # a failure over "it started" - so that logic stays on the page.
        $dash = Join-Path $script:repoRoot 'src' 'dashboard'
        foreach ($name in 'migrations.html', 'waves.html', 'wizard.html') {
            $text = (Get-VmfPageSource -Path (Join-Path $dash $name))
            $text | Should -Match 'VmfHelp\.watchRun\(' -Because "$name watches a run"
            $text | Should -Match 'scan:' -Because "$name must say what it is waiting for"
        }
    }
}

Describe 'COLD-1: the wizard says it is loading before it waits on the facade' {

    It 'draws the project step with a loading message BEFORE awaiting /projects' {
        # On the first run of the wizard, the project step took about 30
        # seconds. The facade is a PowerShell function on a Consumption plan and
        # cold-starts in 20-40 s. That wait is a hosting decision (INSTALL-1).
        # The BLANK PANEL during the wait was ours: the step body was filled
        # only after the project list arrived, so the header sat over nothing.
        #
        # The fix is an ORDER, so the assertion is positional: the loading
        # card must be written to the element before the await.
        $wiz = ($script:pages | Where-Object Name -eq 'wizard.html').Text
        $fn = [regex]::Match($wiz, '(?s)async function renderProjectPick\(el\) \{.*?
\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $loadAt = $fn.IndexOf('UX.s0Loading')
        $waitAt = $fn.IndexOf("await api('GET', 'projects')")
        $loadAt | Should -BeGreaterThan -1 -Because 'the loading message must be rendered at all'
        $waitAt | Should -BeGreaterThan -1
        $loadAt | Should -BeLessThan $waitAt -Because 'saying "loading" after the wait is not saying it'
        $wiz | Should -Match "s0Loading:\s*'Loading your projects"
    }

    It 'LOADING-WORDS-1: the loading line says only that it loads, and quotes no wait time' {
        # Until 2026-11-12, the line said "The first request after a quiet
        # period can take up to a minute", a time measured before the speed
        # fixes. Read from the page's strings table, not the whole file.
        $wiz = ($script:pages | Where-Object Name -eq 'wizard.html').Text
        $table = [regex]::Match($wiz, '(?s)UX-STRINGS-BEGIN(.*?)UX-STRINGS-END').Groups[1].Value
        $table | Should -Not -BeNullOrEmpty
        $entry = [regex]::Match($table, "(?m)^\s*s0Loading\s*:\s*'([^']*)'")
        $entry.Success | Should -BeTrue
        $entry.Groups[1].Value | Should -BeExactly 'Loading your projects.'
    }
}
