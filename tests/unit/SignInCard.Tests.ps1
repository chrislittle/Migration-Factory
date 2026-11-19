#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SIGNIN-1, 2026-09-19. The WIRING half.
#
# tests/js/sign-in-card.test.js drives showSignIn and proves what it builds.
# It says nothing about whether the EIGHT PAGES use it, and that is the whole
# point of this item: the card already existed eight times and had drifted in
# the words, in the markup and in the button.
#
# Read through Get-VmfCodeOnly, so a comment describing the card cannot satisfy
# a check about the card.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages = @(Get-ChildItem -LiteralPath $script:dash -Filter '*.html' -File)
    $script:code = @{}
    foreach ($pg in $script:pages) {
        $script:code[$pg.Name] = Get-VmfCodeOnly -Path $pg.FullName -Language CStyle
    }
    $script:help = Get-VmfCodeOnly -Path (Join-Path $script:dash 'help.js') -Language CStyle
    $script:css  = Get-Content -LiteralPath (Join-Path $script:dash 'app.css') -Raw
}

Describe 'SIGNIN-1: the card is said once' {

    It 'finds the pages, so this cannot pass by scanning nothing' {
        $script:pages.Count | Should -BeGreaterThan 5
        # And every page that signs somebody in is actually covered below.
        @($script:code.Values | Where-Object { $_ -match 'login-view' }).Count |
            Should -Be 8 -Because 'eight pages show a sign-in card'
    }

    It 'no page writes the card out itself' {
        # What each of the eight used to carry, one way or another.
        foreach ($name in $script:code.Keys) {
            $text = $script:code[$name]
            $text | Should -Not -Match 'id="login-btn"' -Because "$name must not build its own button"
            $text | Should -Not -Match 'Sign in with Entra' -Because "$name must not carry the old button words"
            $text | Should -Not -Match 'login-copy'       -Because "$name must not carry its own line"
            $text | Should -Not -Match 'loginCopy'        -Because "$name must not declare its own line"
        }
    }

    It 'and every one of them asks for the shared card instead' {
        $asked = 0
        foreach ($name in $script:code.Keys) {
            $text = $script:code[$name]
            if ($text -notmatch 'login-view') { continue }
            $text | Should -Match 'VmfHelp\.showSignIn\(\)' -Because "$name shows a card, so it must ask for the shared one"
            # An EMPTY host. Markup left inside it would draw twice.
            $text | Should -Match '<div id="login-view"></div>' -Because "$name must leave the card to the builder"
            $asked++
        }
        $asked | Should -Be 8 -Because 'a loop that ran no cases proves nothing'
    }

    It 'no page turns the card on by hand, which would show an empty box' {
        # showSignIn fills it AND shows it. A page that only set display would
        # paint a bordered, empty rectangle.
        foreach ($name in $script:code.Keys) {
            $script:code[$name] | Should -Not -Match "'#login-view'\)\.style\.display = 'block'" `
                -Because "$name must not show the host without filling it"
        }
    }
}

Describe 'SIGNIN-1: the one card is built in the shared file' {

    It 'help.js declares all three strings, and shows all three' {
        foreach ($key in @('signInTitle', 'signInWhat', 'signInBtn')) {
            $script:help | Should -Match "$key`:\s*'" -Because "help.js must declare TEXT.$key"
            $script:help | Should -Match "TEXT\.$key" -Because "a string nothing reads is a string nobody sees"
        }
    }

    It 'and the note under the button is gone, with nothing in its place (SIGNIN-TAGLINE-1)' {
        # Removed 2026-11-07: the note said nothing useful. Read code-only, so a comment
        # about the old note cannot make this pass or fail.
        $script:help | Should -Not -Match 'signInScope'
        $script:help | Should -Not -Match 'signin-scope'
        $script:css  | Should -Not -Match '\.signin-scope' -Because 'a rule for an element nobody builds is dead weight'
    }

    It 'and hands back the button it built, rather than leaving a page to find one' {
        $script:help | Should -Match 'return host\.querySelector\(''#login-btn''\)'
        $script:help | Should -Match 'window\.VmfHelp = \{[^}]*showSignIn'
    }
}

Describe 'SIGNIN-1: the card has ONE look' {

    It 'the card rule is written once, not three times' {
        # It was written here, under .p-access and under .p-waves, with two
        # different widths - which is how the same card came out 430px wide on
        # six pages and 460px on two.
        # Counted by the declaration that MAKES it a card, so the h2 rule and
        # the phone-width padding override beside it do not have to be spelled
        # out here - and a fourth copy of the box would still be caught.
        @([regex]::Matches($script:css, '(?s)#login-view[^{]*\{[^}]*box-shadow')).Count |
            Should -Be 1 -Because 'one rule gives the card its box'
        $script:css | Should -Not -Match '\.p-access #login-view'
        $script:css | Should -Not -Match '\.p-waves #login-view'
    }

    It 'and the gate those two pages also show kept its shape' {
        # Removing the duplicated rules must not have taken the gate's card
        # styling with them - it shared the rule, it was not a copy of it.
        $script:css | Should -Match '\.p-access #gate-view'
        $script:css | Should -Match '\.p-waves #gate-view'
    }

    It 'no page carries an inline style for the button any more' {
        foreach ($name in $script:code.Keys) {
            $script:code[$name] | Should -Not -Match 'font-size:15px;padding:10px 24px' `
                -Because "$name pushed the button's size into its markup"
        }
        $script:css | Should -Match '\.signin-btn \{'
    }
}
