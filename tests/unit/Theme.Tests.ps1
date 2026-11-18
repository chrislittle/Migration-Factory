#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# THEME-1 / SIGNOUT-1 - two themes the person chooses between, and a way out.
#
# Since 2026-09-02: the 'dark' theme is based on Bootswatch Darkly and the
# 'light' theme on Spacelab, and normal UX practice gives the user a control
# to choose between them. There was also no sign-out for a user, which is
# needed to test the RBAC roles one identity at a time.
#
# A SECOND PALETTE IS NOT A COPY OF THE FIRST WITH THE VALUES SWAPPED. It is a
# second set of answers to the same questions, and the questions have different
# answers on white: Bootswatch holds itself to 2.65:1 and we hold 4.5, so four
# of Spacelab's published colours needed darkening where only five of Darkly's
# twenty needed lightening. The eye forgives low contrast on white. A projector
# in a bright room does not.
#
# The rules here are the ones that keep the two sets ANSWERING THE SAME
# QUESTIONS - every token in both, no colour outside them, and both measured.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:css      = Get-Content (Join-Path $script:dash 'app.css') -Raw
    $script:help     = Get-Content (Join-Path $script:dash 'help.js') -Raw
    $script:theme    = Get-Content (Join-Path $script:dash 'theme.js') -Raw
    $script:pages    = @(Get-ChildItem $script:dash -Filter '*.html')

    function Get-Block([string]$Selector) {
        $m = [regex]::Match($script:css, [regex]::Escape($Selector) + '\s*\{(.*?)\n\}', 'Singleline')
        if (-not $m.Success) { return $null }
        $m.Groups[1].Value
    }
    function Get-Tokens([string]$Block) {
        $h = @{}
        foreach ($m in [regex]::Matches($Block, '(--[a-z0-9-]+)\s*:\s*([^;]+);')) {
            $h[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
        }
        $h
    }
    # Contrast, the same maths the browser is judged by. Hex only - an alpha
    # has no ratio until you know what is behind it, and those are checked on
    # the rendered page instead.
    function Get-Contrast([string]$A, [string]$B) {
        function Get-Lin([string]$Hex) {
            $c = $Hex.TrimStart('#')
            if ($c.Length -eq 3) { $c = ($c.ToCharArray() | ForEach-Object { "$_$_" }) -join '' }
            $v = 0..2 | ForEach-Object {
                $x = [Convert]::ToInt32($c.Substring($_ * 2, 2), 16) / 255
                if ($x -le 0.03928) { $x / 12.92 } else { [math]::Pow(($x + 0.055) / 1.055, 2.4) }
            }
            0.2126 * $v[0] + 0.7152 * $v[1] + 0.0722 * $v[2]
        }
        $x = Get-Lin $A; $y = Get-Lin $B
        $hi = [math]::Max($x, $y); $lo = [math]::Min($x, $y)
        ($hi + 0.05) / ($lo + 0.05)
    }

    $script:light = Get-Tokens (Get-Block ':root, :root[data-theme="light"]')
    $script:dark  = Get-Tokens (Get-Block ':root[data-theme="dark"]')
}

Describe 'THEME-1: there are exactly two palettes, and they answer the same questions' {

    It 'both blocks exist and are not empty' {
        @($script:light.Keys).Count | Should -BeGreaterThan 20 -Because 'the light block must carry the whole set'
        @($script:dark.Keys).Count  | Should -BeGreaterThan 20 -Because 'the dark block must carry the whole set'
    }

    It 'every colour the dark theme names, the light theme names too' {
        # THE failure mode of a second theme: one token is forgotten, so it
        # falls through to the other theme's value and one word on one page is
        # unreadable. Nobody finds that by looking, because it is one word.
        $missing = $script:dark.Keys | Where-Object { -not $script:light.ContainsKey($_) }
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a token missing from light inherits a DARK value'
    }

    It 'and the dark theme overrides every colour the light theme sets' {
        # The other direction. --font and --radius are deliberately shared:
        # they are not colour and do not change with the ground.
        $shared = '--font', '--mono', '--radius'
        $missing = $script:light.Keys |
            Where-Object { $_ -notin $shared -and -not $script:dark.ContainsKey($_) }
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a colour left behind keeps the LIGHT value on a dark page'
    }

    It 'no two MEANINGS share a value' {
        # What this protects is a pasted semantic value - `--good-soft` given
        # `--warn-soft`'s colour, which looks fine and quietly makes two states
        # identical. It deliberately ignores the `--on-*` family and the
        # surfaces: white legitimately does three jobs at once on a light card
        # and `--ink` is honestly white on a dark one, and listing every such
        # coincidence would turn a rule into a table of exceptions.
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            $meanings = @()
            foreach ($m in 'brand', 'good', 'warn', 'bad') {
                foreach ($suffix in '', '-soft', '-on') { $meanings += "--$m$suffix" }
            }
            $dupes = $meanings |
                Where-Object { $set.t.ContainsKey($_) } |
                Group-Object { $set.t[$_] } |
                Where-Object Count -gt 1 |
                ForEach-Object { ($_.Group | Sort-Object) -join '=' } |
                # Darkly's amber reads on its own chip, so --warn and --warn-on
                # are equal on purpose. That is the only one.
                Where-Object { $_ -ne '--warn=--warn-on' }
            $dupes -join ' | ' | Should -BeNullOrEmpty `
                -Because "$($set.n): two meanings with one colour cannot be told apart"
        }
    }
}

Describe 'THEME-1: both palettes clear the contrast floor' {

    It 'text reads on the WORST surface it can land on, in both themes' {
        # RULE 11, applied to the theme that did not exist yesterday - and to
        # the mistake made writing it. Text is checked against BOTH the card
        # and the page, because which of those is worse flips with the theme:
        #
        #   dark   page #222 is DARKER than card #303030 -> the card is worst
        #   light  card #fff is LIGHTER than page #f8f9fa -> the PAGE is worst
        #
        # The light tokens were first derived against the card, and four of
        # them passed there and failed on the page. Checking one surface is
        # checking the theme you happened to be looking at.
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            foreach ($surface in '--card', '--bg') {
                foreach ($tok in '--ink', '--body', '--muted', '--brand', '--good', '--warn', '--bad', '--link') {
                    $r = Get-Contrast $set.t[$tok] $set.t[$surface]
                    $r | Should -BeGreaterThan 4.5 `
                        -Because "$($set.n) $tok on $surface is $([math]::Round($r,2))"
                }
            }
        }
    }

    It 'the quiet chip carries text that reads on --card-2' {
        # A quiet pill paints its OWN background, so its text sits on a chip
        # like every other pill - it just never looked like one, being grey.
        # `--muted` was landing at exactly 4.50 on the dark theme, which is no
        # headroom at all: nest it in a hovered row and it goes under.
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            $r = Get-Contrast $set.t['--quiet-on'] $set.t['--card-2']
            $r | Should -BeGreaterThan 4.5 -Because "$($set.n): the quiet pill is $([math]::Round($r,2))"
        }
    }

    It 'and --muted reads on every plain surface it can land on' {
        # --card-2 is a third surface and was not being checked. On light it is
        # the DARKEST plain one, so it decides the value; on dark it is the
        # lightest. Either way it is the one that was missed.
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            foreach ($surface in '--bg', '--card', '--card-2') {
                $r = Get-Contrast $set.t['--muted'] $set.t[$surface]
                $r | Should -BeGreaterThan 4.5 -Because "$($set.n) --muted on $surface is $([math]::Round($r,2))"
            }
        }
    }

    It 'and a chip that hosts secondary text redefines --muted rather than listing selectors' {
        # Three chips had --muted text on them at 3.3 to 4.0. Enumerating those
        # three would fix those three and wait for the fourth; redefining the
        # token ON the chip fixes every descendant, now and later.
        foreach ($chip in '\.kpi\.alert', '\.run-panel \.row\.sel', '\.result\.sel') {
            $script:css | Should -Match "$chip\s*\{[^}]*--muted:var\(--(bad|brand|good|warn)-on\)" `
                -Because "a --*-soft chip is a ground of its own"
        }
    }

    It 'a chip carries text that reads ON THE CHIP' {
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            foreach ($m in 'brand', 'good', 'warn', 'bad') {
                $r = Get-Contrast $set.t["--$m-on"] $set.t["--$m-soft"]
                $r | Should -BeGreaterThan 4.5 -Because "$($set.n) --$m-on on --$m-soft is $([math]::Round($r,2))"
            }
        }
    }

    It 'and a filled control carries its own label' {
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            $r = Get-Contrast $set.t['--on-fill'] $set.t['--brand-fill']
            $r | Should -BeGreaterThan 4.5 -Because "$($set.n): white on the button is $([math]::Round($r,2))"
            # MADE-DISK-DELETE-1: the red fill of a delete that cannot be undone.
            $r3 = Get-Contrast $set.t['--on-fill'] $set.t['--bad-fill']
            $r3 | Should -BeGreaterThan 4.5 -Because "$($set.n): white on the red button is $([math]::Round($r3,2))"
            $r2 = Get-Contrast $set.t['--on-nav'] $set.t['--nav']
            $r2 | Should -BeGreaterThan 4.5 -Because "$($set.n): text on the navigation bar is $([math]::Round($r2,2))"
        }
    }

    It 'the surfaces are actually distinguishable from each other' {
        # A card the colour of the page is not a card. Small ratios, but not 1.
        foreach ($set in @{n='light';t=$script:light}, @{n='dark';t=$script:dark}) {
            foreach ($pair in @('--bg','--card'), @('--card','--card-2'), @('--card','--line')) {
                $r = Get-Contrast $set.t[$pair[0]] $set.t[$pair[1]]
                $r | Should -BeGreaterThan 1.03 -Because "$($set.n): $($pair[0]) and $($pair[1]) are the same colour"
            }
        }
    }
}

Describe 'THEME-1: the stamp lands before the page is painted' {

    It 'every page loads theme.js in the head, BEFORE the stylesheet' {
        # A theme applied after first paint is a flash of the wrong colours on
        # every navigation. The script is separate from help.js for exactly
        # this reason - help.js loads at the end of the body.
        foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            $t = $text.IndexOf('src="theme.js"')
            $c = $text.IndexOf('href="app.css"')
            $t | Should -BeGreaterThan -1 -Because "$($p.Name) must load theme.js"
            $t | Should -BeLessThan $c -Because "$($p.Name) must stamp the theme before the stylesheet"
            $text.Substring(0, $t) | Should -Not -Match '<body' -Because "$($p.Name) must load it in the head"
        }
    }

    It 'and it is loaded synchronously' {
        foreach ($p in $script:pages) {
            $tag = [regex]::Match(((Get-VmfPageSource -Path $p.FullName)), '<script[^>]*src="theme\.js"[^>]*>').Value
            $tag | Should -Not -Match 'defer|async' -Because "$($p.Name): defer puts the stamp back after paint"
        }
    }

    It 'the stamp reads the person first, then the operating system' {
        $script:theme | Should -Match "localStorage"
        $script:theme | Should -Match "prefers-color-scheme"
        $script:theme | Should -Match "setAttribute\('data-theme'"
        # Storage THROWS in a browser set to block site data - it does not
        # merely return null. A dashboard must not die of a remembered choice.
        $script:theme | Should -Match '(?s)function stored\(\).*?catch'
        $script:theme | Should -Match '(?s)function remember\(v\).*?catch'
    }

    It 'the control SHOWS the current theme, and offers the others' {
        # THEME-2 REVERSED THIS. It was a two-state button labelled with the
        # DESTINATION - "Dark theme" while you were on light - on the reasoning
        # that a control naming its current state reads as a status light.
        #
        # A theme control should show the current theme, and from there you
        # change to another. The old shape also had a second
        # problem the label hid: naming the destination means it can never show
        # where you are, and a two-state toggle has no way back to following
        # the operating system once it is pressed.
        #
        # A picker shows the current setting by definition and has room for
        # that third state, which is the one the app starts in.
        $script:theme | Should -Match "function choice\(\)"
        $script:theme | Should -Match "light: 'Light'"
        $script:theme | Should -Match "dark: 'Dark'"
        $script:theme | Should -Match "system: 'Follow the system'"
        $script:help  | Should -Match "createElement\('select'\)"
        $script:help  | Should -Match "for \(const v of \['light', 'dark', 'system'\]\)"
    }

    It 'and choosing to follow the system FORGETS the stored choice' {
        # Otherwise "follow the system" would be a third stored value that
        # merely looked like following it, and the next OS change would do
        # nothing.
        $script:theme | Should -Match "(?s)if \(v === 'system'\).*?removeItem\(KEY\).*?apply\(osPrefers\(\)\)"
    }

    It 'and it is deployed' {
        (Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw) |
            Should -Match "'theme\.js'" -Because 'a page that cannot load it renders unthemed'
    }
}

Describe 'SIGNOUT-1: a person can sign out' {

    It 'the shared bar draws the control, so no page can forget it' {
        $script:help | Should -Match "id = 'nav-signout'"
        # Not drawn per page - that is the mistake this file has watched twice.
        $bad = foreach ($p in $script:pages) {
            if (((Get-VmfPageSource -Path $p.FullName)) -match 'id="nav-signout"') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'one bar, drawn once'
    }

    It 'it clears the Entra session, not only our own storage' {
        # Clearing the token cache alone signs them straight back in on the
        # next click, silently - the opposite of what testing two roles needs.
        # NO-POPUPS-SIGNOUT-1: by redirect, so a browser that blocks popups
        # signs out too.
        # Read as code: help.js says in a comment what sign-out used before.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js')
        $code | Should -Match '(?s)async function signOut.*?\.logoutRedirect\('
        $code | Should -Not -Match 'logoutPopup'
    }

    It 'a sign-out the library refuses still gets them out' {
        $script:help | Should -Match '(?s)catch[^}]*sessionStorage\.clear'
        $script:help | Should -Match '(?s)async function signOut.*?location\.reload'
    }

    It 'every page hands over the MSAL instance it owns' {
        # As a GETTER: install() runs at boot, before msalApp is built, so
        # passing the value would pass undefined for the life of the page.
        foreach ($p in $script:pages) {
            ((Get-VmfPageSource -Path $p.FullName)) | Should -Match 'getMsal:\s*\(\)\s*=>\s*msalApp' `
                -Because "$($p.Name) must give the shared control something to sign out of"
        }
    }

    It 'and it is hidden until there is somebody to sign out' {
        # It starts hidden and is revealed by identity() - the one place that
        # knows whether anybody is signed in. This used to watch #who with a
        # MutationObserver, which was the right tool while the PAGES wrote that
        # text; now the shared bar writes it, so watching would be watching
        # ourselves. One mechanism, not two.
        $script:help | Should -Match 'out\.hidden = true'
        $script:help | Should -Match '(?s)function identity.*?out\.hidden = !who\.textContent\.trim\(\)'
        $script:help | Should -Not -Match 'MutationObserver' -Because 'the bar sets the text, so there is nothing to observe'
    }

    It 'it says Sign out, the word Entra uses' {
        $script:help | Should -Match "signOut: 'Sign out'"
    }
}

Describe 'BAR-1: the bar is BUILT, not found' {

    It 'no page declares the identity element - the shared bar creates it' {
        # Seen 2026-09-02 on two screens: on the admin page the signed-in
        # name moved far to the left, and the theme and sign-out controls
        # were missing.
        #
        # installRight() looked for `.topbar .right` and RETURNED QUIETLY when
        # a page had none. access.html had none, so the admin page lost both
        # controls and its name sat wherever the nav left it. Seven pages had
        # the markup and one did not, which is what "shared" means when the
        # sharing stops at the page boundary.
        #
        # A shared control cannot ask the page for somewhere to live.
        $bad = foreach ($p in $script:pages) {
            if (((Get-VmfPageSource -Path $p.FullName)) -match 'id="who"') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'help.js creates #who so no page can omit it'
    }

    It 'and help.js creates the right-hand section when the page has none' {
        $script:help | Should -Match "right = document\.createElement\('span'\)"
        $script:help | Should -Match "who = document\.createElement\('span'\)"
        $script:help | Should -Not -Match "if \(!right \|\| right\.querySelector" `
            -Because 'returning quietly on a missing container is how the admin bar shipped empty'
    }

    It 'the identity is computed ONCE, not once per page' {
        # It was six spellings across eight pages - account.username on two,
        # account?.name ?? account?.username on four, a third on assessments -
        # so admin showed a display name and overview showed an address.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -match "\`$\('#who'\)\s*\.\s*(textContent|title)") { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'the shared bar owns the identity text'

        foreach ($p in $script:pages) {
            ((Get-VmfPageSource -Path $p.FullName)) | Should -Match 'VmfHelp\.identity\(' `
                -Because "$($p.Name) must ask for the one answer"
        }
    }

    It 'and it shows the ADDRESS, because two people can share a name' {
        # Two different Entra ID users can have the same first and last
        # name, as two test identities here did. A
        # display name cannot tell them apart; a UPN always can.
        $script:help | Should -Match 'account\.username \|\| account\.name' `
            -Because 'the address disambiguates and the display name does not'
        $script:help | Should -Match 'who\.title = \(account && account\.name\)' `
            -Because 'the display name still belongs somewhere'
    }
}

Describe 'THEME-1: the controls belong to the person, not to a page' {

    It 'both sit in the bar and are styled by the shared sheet' {
        $script:css | Should -Match '\.navbtn \{'
        $script:css | Should -Match '\.navbtn\[hidden\] \{ display:none'
        # They sit ON the navigation colour, so they take the nav token set.
        $script:css | Should -Match '\.navbtn \{[^}]*color:var\(--on-nav-dim\)'
    }

    It 'no page draws its own theme button' {
        $bad = foreach ($p in $script:pages) {
            if (((Get-VmfPageSource -Path $p.FullName)) -match 'id="nav-theme"') { $p.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'DIALOG-1: the help dialogs follow the theme' {
    # Found 2026-09-03: the About dialog followed neither the light nor the
    # dark theme. The shared dialog in help.js
    # painted a white card, slate text and a blue button of its own - on every
    # help dialog since HELP-2 - because DARK-1 moved the PAGES to tokens and
    # never reached this file.
    It 'help.js paints no colour of its own - every colour is a theme token' {
        $script:help | Should -Not -Match '(?i)(color|background|border(-[a-z]+)?)\s*:\s*#[0-9a-f]{3,8}\b'
        $script:help | Should -Match 'background:var\(--card\)'
        $script:help | Should -Match 'color:var\(--muted\)'
    }

    It 'and the dialog buttons are the page buttons, not a third design' {
        $dlg = [regex]::Match($script:help, '(?s)function dialog\(.*?\n  \}').Value
        $dlg | Should -Match "className = b\.primary \? 'btn' : 'btn ghost'"
        $dlg | Should -Not -Match 'background:#'
    }
}

Describe 'NAV-1: a page''s own controls go to a second row, so the tabs keep one line' {
    # Seen 2026-09-04 on screen: while migrations ran, the navigation bar
    # was not aligned with the bar on the other pages.
    It 'help.js moves what a page wrote into the right-hand group to a toolbar row under the bar' {
        $right = [regex]::Match($script:help, '(?s)function installRight\(\).*?\n  \}').Value
        $right | Should -Match "Array\.from\(right\.children\)\.filter\(el => el\.id !== 'who'\)"
        $right | Should -Match "toolbar\.className = 'toolbar'"
        $right | Should -Match "bar\.insertAdjacentElement\('afterend', toolbar\)"
        $right | Should -Match 'for \(const el of own\) \{ toolbar\.appendChild\(el\); \}'
    }

    It 'the toolbar row is styled from the nav token set and hidden when empty' {
        $rule = [regex]::Match($script:css, '(?m)^\.toolbar \{(.*)\}$').Groups[1].Value
        # TOOLBAR-LIGHT-1: the header colour, SOLID. --nav-hover is a tint meant
        # to sit ON the header; below it, it sat on the near-white page under
        # white text in the light theme. This line used to require the tint.
        $rule | Should -Match 'background:var\(--nav\);'
        $rule | Should -Not -Match 'background:var\(--nav-hover\)'
        $rule | Should -Match 'color:var\(--on-nav-dim\)'
        $rule | Should -Match 'flex-wrap:wrap'
        $script:css | Should -Match '\.toolbar:empty \{ display:none; \}'
    }

    It 'and no page styles the right-hand group into a wrapping catch-all any more' {
        $script:css | Should -Not -Match '\.p-migrations \.topbar \.right'
        $script:css | Should -Match '\.p-migrations \.toolbar'
    }
}
