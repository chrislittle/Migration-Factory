#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# POPUP-1 - the dashboard never asks with a browser box.
#
# Found 2026-09-04, deleting a project: it asked with a big browser popup.
# A popup was not required: the delete button can confirm on the page and
# then show a deleting status, with no popup at all.
#
# Nine places asked with window.confirm() or window.prompt(). A browser box
# ignores the theme, cannot hold a field or a list that reads well, and looks
# like an alarm. Rule 11 already named the right shape - one control with two
# states - and VmfHelp.confirmInPlace is that control, shared by every page.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages = @(Get-ChildItem $script:dash -Filter '*.html' -File)
    $script:help = Get-Content (Join-Path $script:dash 'help.js') -Raw
    $script:css = Get-Content (Join-Path $script:dash 'app.css') -Raw
}

Describe 'POPUP-1: no page asks with a browser box' {

    It 'found the pages, or this file proves nothing' {
        $script:pages.Count | Should -BeGreaterThan 6
    }

    It 'no page and no shared script calls confirm, alert or prompt' {
        # A call, not a word: a comment that says "no confirm box" is allowed
        # to say so. `(?<![\w.$])` keeps a page's own function such as
        # `confirmInPlace(` or `$("#m-confirm")` out of it.
        $rx = '(?<![\w.$-])(?:window\.)?(?:confirm|alert|prompt)\s*\('
        $hits = foreach ($pg in $script:pages) {
            $t = (Get-VmfPageSource -Path $pg.FullName)
            foreach ($m in [regex]::Matches($t, $rx)) { "$($pg.Name): $($m.Value)" }
        }
        foreach ($m in [regex]::Matches($script:help, $rx)) { $hits += "help.js: $($m.Value)" }
        @($hits) -join ', ' | Should -BeNullOrEmpty -Because 'a question belongs in the page, in the theme, with Escape and Cancel'
    }
}

Describe 'POPUP-1: the shared control is the two-state shape rule 11 asks for' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:ctl = [regex]::Match($script:help, '(?s)function confirmInPlace\(.*?\n  \}').Value
    }

    It 'exists and is handed to the pages' {
        $script:ctl | Should -Not -BeNullOrEmpty
        $script:help | Should -Match '(?s)window\.VmfHelp = \{[^}]*confirmInPlace'
    }

    It 'offers Cancel and Escape, and puts the button back with focus' {
        $script:ctl | Should -Match "opts\.cancel"
        $script:ctl | Should -Match "e\.key === 'Escape'"
        # ASKROW-1: the row no longer REPLACES the button. It is anchored to
        # the button's own container and the button stays in place, hidden -
        # so the cell keeps its width, and the confirmation cannot grow out of
        # the card and take Cancel with it. tests/js/ask-row.test.js runs the
        # three ways out; this only says the way back still exists.
        $script:ctl | Should -Match 'removeChild\(row\)'
        $script:ctl | Should -Match 'btn\.style\.visibility = hadVisibility'
        $script:ctl | Should -Match 'btn\.focus\(\)'
    }

    It 'restores the button BEFORE the work runs, so every "Deleting..." status keeps working' {
        $script:ctl.IndexOf('putBack();' + [char]10 + '      onYes(value);') | Should -BeGreaterThan 0
    }

    It 'refuses an empty required answer beside the field rather than after the row has gone' {
        $script:ctl | Should -Match 'opts\.field\.required && !value'
        $script:ctl | Should -Match 'missing\.hidden = false'
    }

    It 'uses the page buttons and the theme tokens, never its own colours' {
        $script:ctl | Should -Match "className = 'btn small'"
        $script:ctl | Should -Match "className = 'btn small ghost'"
        $script:css | Should -Match '\.askrow \{[^}]*var\(--card-2\)'
    }
}

Describe 'POPUP-1: every site that used a box now uses the control, with both answers' {

    It 'the nine sites are on the shared control' {
        $calls = 0
        foreach ($pg in $script:pages) {
            $calls += ([regex]::Matches(((Get-VmfPageSource -Path $pg.FullName)), 'VmfHelp\.confirmInPlace\(')).Count
        }
        $calls | Should -BeGreaterOrEqual 9 -Because 'projects 1, assessments 2, access 3, waves 3'
    }

    It 'every call names a Yes and a Cancel from the page strings' {
        $bad = foreach ($pg in $script:pages) {
            $t = (Get-VmfPageSource -Path $pg.FullName)
            # THE WHOLE CALL, counted by brackets rather than by characters.
            #
            # This read 500 characters and no more, so ROLES-1's rewrite - which
            # turned a one-line desc into a four-part list - pushed `yes` and
            # `cancel` past the end and failed a rule they still obeyed.
            #
            # THE FIRST REPLACEMENT WAS WORSE. A non-greedy regex looked right
            # and matched ONE of this file's FOUR calls, so removing a cancel
            # changed nothing and the test passed on three calls it never read.
            # Hence the count check below: a check that examines nothing must
            # fail, not pass.
            $starts = @([regex]::Matches($t, 'VmfHelp\.confirmInPlace\('))
            $examined = 0
            foreach ($m in $starts) {
                $depth = 0; $end = -1
                for ($i = $m.Index + $m.Length - 1; $i -lt $t.Length; $i++) {
                    if ($t[$i] -eq '(') { $depth++ }
                    elseif ($t[$i] -eq ')') { $depth--; if ($depth -eq 0) { $end = $i; break } }
                }
                if ($end -lt 0) { "$($pg.Name)@$($m.Index) never closes"; continue }
                $examined++
                $call = $t.Substring($m.Index, $end - $m.Index + 1)
                if ($call -notmatch 'yes:\s*UX\.\w+' -or $call -notmatch 'cancel:\s*UX\.\w+') { "$($pg.Name)@$($m.Index)" }
            }
            if ($examined -ne $starts.Count) { "$($pg.Name): read $examined of $($starts.Count) calls" }
        }
        @($bad) -join ', ' | Should -BeNullOrEmpty -Because 'a question with no way back is a trap (rule 11)'
    }

    It 'the reservation note is a field with a refusal for an empty answer' {
        $waves = (Get-VmfPageSource -Path (Join-Path $script:dash 'waves.html'))
        $waves | Should -Match 'field: \{ placeholder: UX\.reserveNoteHint, required: true, missing: UX\.reserveNoNote \}'
    }
}

Describe 'POPUP-3: signing in never opens a window either' {
    # Seen 2026-09-14 on a corporate laptop, opening the Admin page:
    #   "popup_window_error: Error opening popup window ... window.open returned
    #    null or undefined window object"
    # - popups should be nowhere in the product, and this looked like the same
    # defect come back again.
    #
    # IT WAS NOT PUT BACK. The POPUP-1 family above - confirm, alert, prompt -
    # has stayed gone, and the check above is why. This is a SECOND family
    # nothing ever covered: MSAL's own sign-in windows, `loginPopup` and
    # `acquireTokenPopup`, which are real window.open calls. All eight pages
    # used them, so the whole product was unusable in a browser that blocks
    # popups - not just the page he happened to be on.
    #
    # A blocker does not refuse them evenly: a popup opened FROM A CLICK is
    # usually allowed, one opened while a page loads is not. That is why
    # signing in worked and the Admin page, which asks as it loads, did not.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $script:identity = Get-Content (Join-Path $script:repoRoot 'infra' 'identity.bicep') -Raw
        # COMMENT-TRAP-1: help.js EXPLAINS this change, naming both calls, so a
        # check over file text matches its own explanation and can never fail.
        $script:code = @{}
        foreach ($pg in $script:pages) {
            $script:code[$pg.Name] = Get-VmfCodeOnly -Path $pg.FullName -Language CStyle
        }
        $script:code['help.js'] = Get-VmfCodeOnly -Path (Join-Path $script:dash 'help.js') -Language CStyle
    }

    It 'read the pages as code, or this proves nothing' {
        $script:code.Count | Should -BeGreaterThan 7
        # help.js EXPLAINS this change in a comment, quoting the browser error
        # it fixes. That phrase exists nowhere in code. If the first assertion
        # fails the specimen is gone and this guard is measuring nothing; if
        # the second fails the reader is matching comments and every check
        # below is void.
        $script:help | Should -Match 'empty_window_error'
        $script:code['help.js'] | Should -Not -Match 'empty_window_error'
    }

    It 'no page asks the directory through a popup window' {
        $hits = foreach ($name in $script:code.Keys) {
            foreach ($m in [regex]::Matches($script:code[$name], 'acquireTokenPopup|loginPopup|ssoSilent')) {
                "$name : $($m.Value)"
            }
        }
        @($hits) | Should -BeNullOrEmpty -Because 'a blocked popup makes the whole product unusable'
    }

    It 'and every page that signs in uses the shared redirect helpers' {
        # Without this, deleting the sign-in code passes the check above.
        $signsIn = @($script:code.Keys | Where-Object { $script:code[$_] -match 'msalApp\.initialize' })
        @($signsIn).Count | Should -BeGreaterThan 7
        foreach ($name in $signsIn) {
            $script:code[$name] | Should -Match 'VmfHelp\.accountsAfterReturn' -Because "$name must take the account a redirect brings back"
        }
    }

    It 'the shared helper asks only once per session, so a refusal cannot loop' {
        # THE PART THAT MATTERS. A popup that fails leaves the page standing. A
        # redirect that fails comes BACK, and a page that asks again on load
        # leaves again - a loop nobody can stop, on a permission that may never
        # be grantable. The Admin page asks for directory permissions only an
        # administrator can approve, so this is exactly where it would happen.
        $helpCode = $script:code['help.js']
        $helpCode | Should -Match 'vmfInteractiveTried'
        $helpCode | Should -Match 'acquireTokenRedirect'
        $helpCode | Should -Match 'loginRedirect'
        # A failed return must REMEMBER the attempt rather than clear it.
        $helpCode | Should -Match 'catch[\s\S]{0,200}setItem\(INTERACTIVE_TRIED'
    }

    It 'every page is a registered redirect address, or nobody can sign in on it' {
        # Three were missing - assessments, migrations and projects - so a
        # person landing on one of those with no session met a redirect-URI
        # mismatch from Entra. True under the popup flow too; the popup only
        # made it rarer.
        $missing = foreach ($pg in $script:pages) {
            if ($script:identity -notmatch [regex]::Escape("/$($pg.Name)'")) { $pg.Name }
        }
        @($missing) | Should -BeNullOrEmpty -Because 'a page that signs in must be a registered redirect address'
    }
}

Describe 'NO-POPUPS-1: nothing the dashboard shows opens a second window' {
    # Rule since 2026-11-05: no popups anywhere. Found in the lab:
    # Open the full report opened a new window, and where the browser blocked
    # it - a corporate tenant can block popups - the Reports page showed the
    # raw script error "Cannot read properties of null (reading 'document')".
    #
    # POPUP-1 took the browser BOXES, POPUP-3 took the sign-in WINDOWS. This is
    # the third family: a window or a tab the page opens for its own content -
    # window.open, a link or a form with a target, a target set from script.
    # The report shows in the page, the manual and the links open in the same
    # tab, and a file is a download.
    #
    # Read as CODE (COMMENT-TRAP-1): this file and help.js both explain what
    # was removed, naming the calls.

    BeforeAll {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        # THE ALLOW-LIST, by name and with its reason. The file is the
        # sign-in library as Microsoft ships it (DEPS-CURRENT-1 pins it); its
        # popup code is there whether the product calls it or not. What the
        # product calls is held by the popup-call check below.
        $script:vendored = @{
            'msal-browser.min.js'         = 'the sign-in library, as Microsoft ships it'
        }
        $script:shown = @{}
        foreach ($f in @(Get-ChildItem $script:dash -File | Where-Object { $_.Extension -in '.html', '.js' })) {
            if ($script:vendored.ContainsKey($f.Name)) { continue }
            # A page's own script is read through its page (below).
            if ($f.Extension -eq '.js' -and (Test-Path (Join-Path $script:dash ($f.BaseName + '.html')))) { continue }
            $script:shown[$f.Name] = Get-VmfCodeOnly -Path $f.FullName -Language CStyle
        }
        # CSP-INLINE-1: each page's script is its own file beside it (wizard.js
        # beside wizard.html), and Get-VmfCodeOnly reads a page WITH that
        # script in it (_PageSource.ps1). So a page's script is read through
        # its page, never twice.
        $script:shown['manual/index.html'] = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docs' 'manual' 'index.html') -Language CStyle
        $script:manualIndexPath = Join-Path $script:repoRoot 'docs' 'manual' 'index.html'
        $script:manualIndex = $script:shown['manual/index.html']
        $script:manualPages = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Filter '*.md' -File -Recurse)

        # Each way a page can make a second browsing context for its content.
        $script:secondWindow = [ordered]@{
            'a call to open a window'      = '(?<![\w$])(?:window|self|top|parent|globalThis|opener|frames)\s*\.\s*open\s*\('
            'the _blank target'            = '_blank'
            'a target attribute'           = '(?i)(?<![\w.$-])target(?:\s*=\s*\\?["'']|=(?=\w))(?!_self\b|_top\b|_parent\b)'
            'a target set from script'     = '(?i)(?:\.\s*target\s*=\s*["''`]|setAttribute\(\s*["''](?:form)?target["''])'
            'a form target'                = '(?i)\bformtarget\b'
            'an old window call'           = '(?i)\b(?:showModalDialog|showModelessDialog|createPopup)\b'
        }

        # THE ONE EXCEPTION, ruled 2026-11-05: a link to
        # Microsoft Learn opens in a new tab. Only a LINK, only on its own line
        # with rel noopener, and only where the address is a Learn address -
        # written in the markup, or checked by isLearnLink() (an https address
        # whose host is exactly learn.microsoft.com; tests/js/no-popups.test.js
        # runs both copies). A window.open is never allowed.
        $script:newTabKinds = @('the _blank target', 'a target attribute', 'a target set from script')
        function Test-VmfLearnNewTab([string]$Line) {
            ($Line -match 'noopener') -and (
                ($Line -match 'isLearnLink\(') -or
                ($Line -match '(?i)href\s*=\s*\\?["'']https://learn\.microsoft\.com/'))
        }
        # The files where a Learn link opens a new tab. A new place is a new
        # line here, on purpose.
        # REBUILD-PATCH-MODE-1: the rebuild list's link to Microsoft's patch
        # orchestration modes, on migrations.html and wizard.html (VmfHelp.isLearnLink).
        # REBUILD-REMOVE-ACCEPT-1: the patch modes link left migrations.html and
        # wizard.html with the rebuild lists that held it.
        # QUOTA-REQUEST-POLL-1: after Azure refuses a quota increase request, the wave
        # editor links to Microsoft's quota increase page (the address written in the markup).
        $script:learnNewTab = @('assessment-report.js', 'manual/index.html', 'waves.html')

        # THE SECOND EXCEPTION, ruled 2026-11-05 (a new tab is best here):
        # Get help's bug report and feature request open
        # this product's GitHub issue page in a new tab, so the dashboard stays
        # open. Only a LINK, with noopener, checked by isIssueLink() (exactly
        # REPO/issues/new; tests/js/no-popups.test.js runs it), and only in help.js.
        function Test-VmfIssueNewTab([string]$Line) {
            ($Line -match 'noopener') -and ($Line -match 'isIssueLink\(')
        }
        $script:issueNewTab = @('help.js')
        function Get-VmfLineAt([string]$Text, [int]$Index) {
            $start = $Text.LastIndexOf([char]10, [Math]::Max(0, $Index - 1)) + 1
            $end = $Text.IndexOf([char]10, $Index)
            if ($end -lt 0) { $end = $Text.Length }
            $Text.Substring($start, $end - $start)
        }
    }

    It 'read every page and script as code, or this proves nothing' {
        $script:shown.Count | Should -BeGreaterThan 11
        # help.js QUOTES the browser error POPUP-3 fixed, which names the call.
        # In the text and not in the code: if the first fails the specimen is
        # gone; if the second fails the reader keeps comments and every check
        # below is void.
        $script:help | Should -Match 'window\.open returned null'
        $script:shown['help.js'] | Should -Not -Match 'window\.open returned null'
        $script:shown.Keys | Should -Contain 'reports.html'
        $script:shown.Keys | Should -Contain 'assessment-report.js'
        # CSP-INLINE-1: a page's own script is read with the page. Code that
        # is only in reports.js and in the manual's index.js is in what was read.
        $script:shown['reports.html'] | Should -Match 'function closeReport\('
        $script:shown['manual/index.html'] | Should -Match 'function learnLinksInNewTab\('
        $script:shown.Keys | Should -Not -Contain 'reports.js'
    }

    It 'no page, no script and no manual page opens a second window' {
        $script:allowedLearn = [System.Collections.Generic.List[string]]::new()
        $script:allowedIssue = [System.Collections.Generic.List[string]]::new()
        $hits = foreach ($name in $script:shown.Keys) {
            foreach ($kind in $script:secondWindow.Keys) {
                foreach ($m in [regex]::Matches($script:shown[$name], $script:secondWindow[$kind])) {
                    if ($kind -in $script:newTabKinds -and $name -in $script:learnNewTab -and
                        (Test-VmfLearnNewTab (Get-VmfLineAt $script:shown[$name] $m.Index))) {
                        $script:allowedLearn.Add($name); continue
                    }
                    if ($kind -in $script:newTabKinds -and $name -in $script:issueNewTab -and
                        (Test-VmfIssueNewTab (Get-VmfLineAt $script:shown[$name] $m.Index))) {
                        $script:allowedIssue.Add($name); continue
                    }
                    "$name : $kind : $($m.Value)"
                }
            }
        }
        foreach ($md in $script:manualPages) {
            foreach ($m in [regex]::Matches((Get-Content $md.FullName -Raw), '(?i)\btarget\s*=')) {
                "$($md.Name) : a target attribute : $($m.Value)"
            }
        }
        @($hits) -join [char]10 | Should -BeNullOrEmpty -Because 'a blocked window shows a script error, and an allowed one leaves the product (2026-11-05)'
    }

    It 'each pattern finds what it is for, so none of them is a check that cannot fail' {
        $specimens = [ordered]@{
            'a call to open a window'  = "const w = window.open('', 'r');"
            'the _blank target'        = "x.open(url, '_blank')"
            'a target attribute'       = @('<a href="x" target="report">', "'<a target=\`"w\`">'", '<a target=report>', "<form target='w'>")
            'a target set from script' = @("a.target = 'w';", "link.setAttribute('target', 'w')")
            'a form target'            = '<button formtarget="w">'
            'an old window call'       = 'window.showModalDialog(u)'
        }
        foreach ($kind in $script:secondWindow.Keys) {
            foreach ($specimen in @($specimens[$kind])) {
                $specimen | Should -Match $script:secondWindow[$kind] -Because "the pattern for $kind must find its own specimen"
            }
        }
        # And the reads every page does are not a window: an event's target,
        # a link in the same tab, a page's own open() helper.
        $plain = "if (e.target === back) close(); e.target = { size: 1 }; <a href=`"x`" target=`"_self`">; function open() { return menu(); } VmfHelp.open();"
        foreach ($kind in $script:secondWindow.Keys) {
            $plain | Should -Not -Match $script:secondWindow[$kind] -Because "$kind must not match ordinary code"
        }
    }

    It 'the Learn exception is used where it is named, and nowhere it is not' {
        # Rule since 2026-11-05: a Microsoft Learn link opens a new tab.
        @($script:allowedLearn | Sort-Object -Unique) | Should -Be @($script:learnNewTab | Sort-Object)
    }

    It 'the GitHub issue exception is used in help.js, and the menu has no other way to GitHub' {
        # Rule since 2026-11-05: an issue link opens a new tab.
        @($script:allowedIssue | Sort-Object -Unique) | Should -Be @($script:issueNewTab)
        # The old same-tab jump is gone: no script sends this tab to the issue page.
        $script:shown['help.js'] | Should -Not -Match 'location\.href\s*=\s*issueUrl'
        $script:shown['help.js'] | Should -Match 'issueItem\(.bug.'
        $script:shown['help.js'] | Should -Match 'issueItem\(.idea.'
    }

    It 'the issue rule takes an isIssueLink line with noopener, and nothing else' {
        Test-VmfIssueNewTab "const tab = isIssueLink(href) ? 'target=`"_blank`" rel=`"noopener noreferrer`"' : 'rel=`"noreferrer`"';" | Should -BeTrue
        Test-VmfIssueNewTab "const tab = isIssueLink(href) ? 'target=`"_blank`"' : '';" | Should -BeFalse
        Test-VmfIssueNewTab "a.target = '_blank'; a.rel = 'noopener';" | Should -BeFalse
        Test-VmfIssueNewTab '<a href="https://github.com/x/issues/new" target="_blank" rel="noopener">' | Should -BeFalse
    }

    It 'the Learn rule takes a Learn link with noopener, and nothing else' {
        $yes = @(
            '<a href="https://learn.microsoft.com/azure/x" target="_blank" rel="noopener noreferrer">',
            '<a class="d" ${isLearnLink(u) ? ''target="_blank" rel="noopener noreferrer"'' : ''rel="noreferrer"''}',
            "if (isLearnLink(a.href)) { a.target = '_blank'; a.rel = 'noopener noreferrer'; }"
        )
        $no = @(
            '<a href="https://example.com/x" target="_blank" rel="noopener noreferrer">',
            '<a href="https://learn.microsoft.com.example.com/x" target="_blank" rel="noopener">',
            '<a href="https://learn.microsoft.com/azure/x" target="_blank">',
            "if (isLearnLink(a.href)) { a.target = '_blank'; }",
            "a.target = '_blank'; a.rel = 'noopener';"
        )
        foreach ($line in $yes) { Test-VmfLearnNewTab $line | Should -BeTrue -Because $line }
        foreach ($line in $no) { Test-VmfLearnNewTab $line | Should -BeFalse -Because $line }
    }

    It 'the manual opens a link to another site in the same tab' {
        # docsify opens every link to another site in a new tab unless told
        # otherwise (externalLinkTarget, default _blank). A Learn link is
        # given its new tab afterwards, link by link.
        $script:manualIndex | Should -Match "externalLinkTarget: '_self'"
        # After each page is drawn, not once: docsify draws every page anew.
        $script:manualIndex | Should -Match 'hook\.doneEach\(function \(\) \{[^}]{0,160}learnLinksInNewTab\(section\)'
    }

    It 'the product asks the sign-in library for no popup at all' {
        # NO-POPUPS-SIGNOUT-1 took the last one, sign-out, to a redirect, the
        # way POPUP-3 took sign-in and every token request. The allow-list is
        # empty: any popup call fails here.
        $calls = foreach ($name in $script:shown.Keys) {
            foreach ($m in [regex]::Matches($script:shown[$name], '\.\s*(\w+Popup)\s*\(')) { "$name : $($m.Groups[1].Value)" }
        }
        @($calls) -join ', ' | Should -BeNullOrEmpty -Because 'a browser that blocks popups must still sign in, get tokens and sign out'
    }

    It 'the popup check sees a popup call in each form a page writes it' {
        # The check above passes on an empty list, so prove it would find one.
        foreach ($line in @('await app.logoutPopup({ account: a });', 'msalApp.loginPopup(req)', 'x . acquireTokenPopup (r)')) {
            [regex]::Matches($line, '\.\s*(\w+Popup)\s*\(').Count | Should -Be 1 -Because $line
        }
        $script:shown['help.js'] | Should -Match 'logoutRedirect\(' -Because 'help.js is read by this check, and sign-out is its redirect'
    }
}
