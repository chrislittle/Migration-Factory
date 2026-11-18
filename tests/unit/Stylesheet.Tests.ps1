#Requires -Modules @{ ModuleVersion = '5.0'; ModuleName = 'Pester' }
# DARK-1 - one stylesheet, and the rules that keep it one.
#
# The whole site needed one consistent look, built against a template. Of
# three templates compared, Darkly was chosen.
#
# The consistency was the point, not the colour. Every defect found that day
# - mismatched fonts, a clipped card, three names for one action, a button
# wrapping mid-phrase - came from eight pages each carrying their own CSS: 47
# selectors defined identically in three or more of them, and 16 that had
# already drifted apart.
#
# So the CSS lives in ONE file now, and these are the rules that stop it
# scattering again. Each is a rule somebody has already broken, or that the
# move to a dark ground broke on its own.
#
# The full statement of intent, with the reasons, is docs/ux.md.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash     = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:cssPath  = Join-Path $script:dash 'app.css'
    $script:css      = Get-Content $script:cssPath -Raw
    $script:pages    = @(Get-ChildItem $script:dash -Filter '*.html')
}

Describe 'DARK-1: there is exactly one stylesheet' {

    It 'it exists, and every page loads it' {
        Test-Path $script:cssPath | Should -BeTrue
        foreach ($p in $script:pages) {
            ((Get-VmfPageSource -Path $p.FullName)) | Should -Match 'href="app\.css"' -Because "$($p.Name) must load it"
        }
    }

    It 'and no page carries CSS of its own' {
        # RULE 1. The whole point: a page holds markup and behaviour, never
        # appearance.
        $with = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            if ($text -match '<style[\s>]') { $p.Name }
        }
        $with -join ', ' | Should -BeNullOrEmpty -Because 'appearance has one home (docs/ux.md rule 1)'
    }

    It 'every page declares which page it is, so its rules can be scoped' {
        foreach ($p in $script:pages) {
            $name = [IO.Path]::GetFileNameWithoutExtension($p.Name)
            ((Get-VmfPageSource -Path $p.FullName)) | Should -Match "class=`"[^`"]*p-$name" `
                -Because "$($p.Name) needs its body class for the .p-$name section"
        }
    }

    It 'the deploy ships it' {
        # Shipping the pages without the stylesheet is eight unstyled screens.
        (Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw) |
            Should -Match "'app\.css'"
    }
}

Describe 'DARK-1: colour lives in the token block, and nowhere else' {

    It 'no page markup contains a colour literal' {
        # RULE 2. Seven were hiding in inline style="" attributes after the
        # first sweep of <style> blocks, which is why this looks at the whole
        # file rather than at stylesheets.
        $bad = foreach ($p in $script:pages) {
            $text = (Get-VmfPageSource -Path $p.FullName)
            # #add / #acc are element ids and &#9660; is an entity - a colour
            # literal is three, four, six or eight HEX digits and nothing else.
            # `#add` and `#acc` are ELEMENT IDS and `&#9660;` is an entity, so a
            # three-letter hex is ambiguous in markup. A colour literal here is
            # six or eight hex digits, or ANY hex inside a style attribute,
            # where an id cannot appear.
            $hits = @()
            $hits += [regex]::Matches($text, '(?<![\w&])#(?:[0-9a-fA-F]{6}|[0-9a-fA-F]{8})\b') |
                ForEach-Object { $_.Value }
            foreach ($m in [regex]::Matches($text, 'style="([^"]*)"')) {
                $hits += [regex]::Matches($m.Groups[1].Value, '#[0-9a-fA-F]{3,8}\b') |
                    ForEach-Object { $_.Value }
            }
            if ($hits) { "$($p.Name): $((@($hits) | Sort-Object -Unique) -join ' ')" }
        }
        $bad -join '; ' | Should -BeNullOrEmpty -Because 'the stylesheet owns colour (docs/ux.md rule 2)'
    }

    It 'and in the stylesheet, only :root does' {
        $body = [regex]::Replace($script:css, '/\*.*?\*/', '', 'Singleline')
        # THEME-1: there are two token blocks now, and both are :root-level.
        $body = [regex]::Replace($body, ':root[^{]*\{.*?
\}', '', 'Singleline')
        $left = [regex]::Matches($body, '#[0-9a-fA-F]{3,8}\b') | ForEach-Object { $_.Value }
        $left -join ' ' | Should -BeNullOrEmpty -Because 'a rule states a MEANING; :root states a value'
    }

    It 'every meaning carries all of its jobs' {
        # RULE 3. On a white ground one value did four jobs. On this one they
        # separate, and a missing token is a job somebody will do with a
        # literal.
        foreach ($t in 'brand', 'good', 'warn', 'bad') {
            foreach ($suffix in '', '-soft', '-on') {
                $script:css | Should -Match "--$t$suffix\s*:" -Because "--$t$suffix names a real job"
            }
        }
        foreach ($t in '--brand-fill', '--on-fill', '--on-nav', '--on-nav-dim', '--link') {
            $script:css | Should -Match "$t\s*:" -Because "$t names a ground of its own"
        }
    }

    It 'the fill is NOT the text colour ON A DARK GROUND - they pull opposite ways' {
        # Lightening --brand so it reads on a dark card made it worse as a
        # button background: white on it is 2.9:1.
        #
        # THEME-1 narrowed this rule to the theme it belongs to. On WHITE the
        # two jobs pull the SAME way - text wants to be darker and so does a
        # fill under white text - so Spacelab's $primary honestly does both at
        # 5.32 each way, and asserting they differ there would be asserting a
        # coincidence of the dark ground. What must hold in both is that each
        # job clears its own floor, and Theme.Tests.ps1 measures that.
        $dark = [regex]::Match($script:css, ':root\[data-theme="dark"\]\s*\{(.*?)
\}', 'Singleline').Groups[1].Value
        $dark | Should -Not -BeNullOrEmpty -Because 'the dark block must exist'
        $fill = [regex]::Match($dark, '--brand-fill\s*:\s*(#[0-9a-fA-F]{6})').Groups[1].Value
        $text = [regex]::Match($dark, '--brand\s*:\s*(#[0-9a-fA-F]{6})').Groups[1].Value
        $fill | Should -Not -Be $text -Because 'on a dark ground a fill and a foreground are different jobs'

        # and the filled controls take the fill
        $script:css | Should -Match '\.btn \{[^}]*background:var\(--brand-fill\)'
    }
}

Describe 'DARK-1: the cascade cannot be undone by one page' {

    It 'no page section styles a bare element' {
        # RULE 13. `.p-index a` is 0,1,1 and beats `.btn` at 0,1,0 - which is
        # how one page's link colour repainted the primary button, the button
        # being an anchor. Page sections scope classes and ids only.
        $bad = [regex]::Matches($script:css, '(?m)^(\.p-[a-z]+ +[a-z][a-z0-9]*)\s*(?:,|\{)') |
            ForEach-Object { $_.Groups[1].Value }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'a page may not outrank the system'
    }

    It 'and a button that happens to be a link is still a button' {
        $script:css | Should -Match 'a:not\(\.btn\)' -Because 'the link rule must step around buttons'
    }

    It 'no rule paints a bare anchor without stepping around .btn' {
        # The check above catches a page scope one level deep. But `.btn` is
        # only 0,1,0, so ANY selector ending in a bare `a` outranks it - a
        # colour rule three classes deep repaints a button that lands there
        # later, and nothing would say why. So the rule is not "page scopes
        # are careful", it is "an anchor rule always names the exception".
        $bad = [regex]::Matches($script:css, '(?m)^([^{}\r\n]*\ba)\s*(?:,|\{)') |
            ForEach-Object { $_.Groups[1].Value } |
            Where-Object { $_ -notmatch ':not\(\.btn\)' -and $_ -notmatch '\.btn' }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'a .btn is a button wherever it sits'
    }
}

Describe 'DARK-1: the one stylesheet actually ships' {

    It 'app.css is on the deploy list' {
        # A page with no CSS of its own is not degraded by a missing
        # stylesheet, it is UNSTYLED - eight pages at once, from one omission,
        # with a deploy that still says it worked. help.js shipped missing
        # exactly once this way.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match "'app\.css'" -Because 'the pages carry no appearance without it'
    }

    It 'and the deploy checks it answers afterwards' {
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match 'app\.css.*404|404.*app\.css' -Because 'uploaded is not the same as served'
    }
}

Describe 'DARK-1: a component carries its own states' {

    It 'a button that is a link is not underlined' {
        # RULE 5, and the one the move actually broke. `.btn` is an <a> on
        # most pages, and the browser underlines an anchor by default. Every
        # page's own CSS used to say text-decoration:none; collapsing eight
        # copies into one sheet dropped it, and "Assess an estate" and
        # "Review" shipped underlined INSIDE their own boxes.
        #
        # Nothing in the source looked wrong. It was found by reading the
        # computed style off the rendered page - rule 11, applied to
        # decoration rather than colour.
        $script:css | Should -Match '(?m)^\.btn \{[^}]*text-decoration:none' `
            -Because 'the browser underlines anchors and .btn must say otherwise'
    }

    It 'and its label does not break mid-phrase' {
        $script:css | Should -Match '(?m)^\.btn \{[^}]*white-space:nowrap' `
            -Because 'a wrapped label splits the box with it'
    }

    It 'the states a control needs are all present' {
        foreach ($state in ':hover', ':disabled') {
            $script:css | Should -Match "\.btn$state" -Because "a button needs $state or it is one page's exception"
        }
    }
}

Describe 'DARK-1: a token is declared AND used' {

    It 'every token in :root is referenced somewhere' {
        # `--font` and `--mono` were declared here and never referenced once,
        # while `body` and five `.mono` rules each restated their own stack.
        # That is the same defect as a colour literal: the sheet claims to
        # name the font and then does not decide it. A token nothing uses is
        # a comment that looks like a rule.
        $root = [regex]::Match($script:css, '(?s):root\s*\{(.*?)
\}').Groups[1].Value
        $body = $script:css.Substring($script:css.IndexOf('}', $script:css.IndexOf(':root')))
        $unused = foreach ($m in [regex]::Matches($root, '(?m)^\s*(--[a-z0-9-]+)\s*:')) {
            $name = $m.Groups[1].Value
            if ($body -notmatch [regex]::Escape("var($name)")) { $name }
        }
        $unused -join ', ' | Should -BeNullOrEmpty -Because 'a token nothing uses decides nothing'
    }

    It 'and no rule restates a font stack the token already names' {
        # $body is rebuilt here on purpose: an `It` is its own scope, so
        # borrowing the one above would hand [regex]::Matches a $null and this
        # would pass on nothing at all.
        $body = $script:css.Substring($script:css.IndexOf('}', $script:css.IndexOf(':root')))
        $bad = [regex]::Matches($body, '(?m)^([^{
]+)\{([^}]*font-family:(?!var\()[^}]*)\}') |
            ForEach-Object { $_.Groups[1].Value.Trim() }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'the font has one home, like the colour'
    }
}

Describe 'DARK-1: a chip carries the text colour named for it' {

    It 'every --x-soft background takes --x-on, never the bare --x' {
        # RULE 3, and the token set exists ONLY for this. --bad is tuned to
        # read on a CARD; on the --bad-soft chip it is 3.9:1, below the floor.
        # --bad-on is the value for that job and clears 4.58.
        #
        # `.p-migrations .m-err` had the bare token, and the rendered contrast
        # audit could not see it: the element is display:none until a run
        # actually errors, so it has no offsetParent and every sweep skipped
        # it. A colour that only appears on a bad day is exactly the one
        # nobody checks by looking.
        $bad = foreach ($m in [regex]::Matches($script:css, '(?m)^([^{
]+)\{([^}]*)\}')) {
            $decls = $m.Groups[2].Value
            $soft  = [regex]::Match($decls, 'background:var\(--(brand|good|warn|bad)-soft\)')
            if (-not $soft.Success) { continue }
            $fg = [regex]::Match($decls, '(?<![\w-])color:var\(--([a-z-]+)\)')
            if (-not $fg.Success) { continue }          # no text of its own is fine
            $want = "$($soft.Groups[1].Value)-on"
            if ($fg.Groups[1].Value -ne $want) {
                "$($m.Groups[1].Value.Trim()) uses --$($fg.Groups[1].Value), needs --$want"
            }
        }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'a chip is a ground of its own (docs/ux.md rule 3)'
    }
}

Describe 'DARK-1: a page may not restate what the sheet already says' {

    It 'no page rule re-declares the control surface' {
        # Six page rules each set `background:var(--card)` on an input, and
        # all six sat INSIDE a card - which is also --card. So the control was
        # exactly the colour of the thing behind it, separated by one border
        # pixel, and the shared rule that says --bg (recessed, and legible)
        # never applied to any of them.
        #
        # Six copies of a rule are six rules. This is the check that keeps
        # them from coming back one page at a time.
        $bad = [regex]::Matches($script:css, '(?m)^(\.p-[a-z]+ [^{
]*(?:input|select|textarea|searchbox)[^{
]*)\{([^}]*)\}') |
            Where-Object { $_.Groups[2].Value -match 'background:var\(--card\)' } |
            ForEach-Object { $_.Groups[1].Value.Trim() }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'the sheet owns the control surface'
    }

    It 'and no hover paints a surface its own ground already is' {
        # The wave name field hovered from transparent to --card while sitting
        # ON a --card panel: nothing changed but the border, so the control
        # did not announce itself. Same fault, stated as a rule.
        $bad = [regex]::Matches($script:css, '(?m)^(\.p-waves [^{
]*:hover[^{
]*)\{([^}]*)\}') |
            Where-Object { $_.Groups[2].Value -match 'background:var\(--card\)' } |
            ForEach-Object { $_.Groups[1].Value.Trim() }
        $bad -join ' | ' | Should -BeNullOrEmpty -Because 'a wave panel is --card, so --card is invisible on it'
    }
}

Describe 'DARK-1: controls are styled, not inherited' {

    It 'font AND surface, stated once' {
        # RULE 9. `font: inherit` was only half of it - an input with no
        # background falls back to the browser's white.
        $script:css | Should -Match '(?m)^button, input, select, textarea \{[^}]*font: inherit'
        $script:css | Should -Match '(?m)^input, select, textarea \{[^}]*background:var\('
    }

    It 'and keyboard focus is visible' {
        $script:css | Should -Match ':focus-visible \{[^}]*outline:'
    }
}
