#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# BRAND-1 - the product has a mark and a name, and every page wears them.
#
# Since 2026-09-07 the header shows a big logo in place of the plain text
# "VMF + migration dashboard", which did not brand the tool.
#
# LOGO-SERVERS-1 (2026-11-02, chosen from mock-ups): the bars
# became server units, the header mark moves once when a page opens, and the
# browser tab has its own drawing made for 16 pixels. So there are two files:
#
#   mark.svg  - the mark ("2b"). help.js draws it inline in the header, in
#               currentColor, so app.css can move its parts; the sign-in card
#               and the manual banner use the same file as a still CSS mask.
#   logo.svg  - the tab icon ("C"). Every page already asks for logo.svg as
#               its icon, so the icon kept the name.
#
# These tests hold the approved geometry, the motion and its two traps, and the
# copies that must not drift.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    $script:pages = @(Get-ChildItem $script:dash -Filter '*.html')
    $script:css = Get-Content (Join-Path $script:dash 'app.css') -Raw
    $script:logo = Get-Content (Join-Path $script:dash 'logo.svg') -Raw
    $script:markPath = Join-Path $script:dash 'mark.svg'
    $script:mark = if (Test-Path $script:markPath) { Get-Content $script:markPath -Raw } else { '' }
    $script:helpJs = Get-Content (Join-Path $script:dash 'help.js') -Raw

    # The approved geometry, written as the formula it was given in,
    # so a test reads the same numbers the mock-up drew.
    function Format-VmfNum([double]$n) { ([math]::Round($n, 3)).ToString([cultureinfo]::InvariantCulture) }
    function Get-VmfRoundRectPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
        $f = { param($v) Format-VmfNum $v }
        'M{0} {1}H{2}A{4} {4} 0 0 1 {3} {5}V{6}A{4} {4} 0 0 1 {2} {7}H{0}A{4} {4} 0 0 1 {8} {6}V{5}A{4} {4} 0 0 1 {0} {1}Z' -f `
            (& $f ($x + $r)), (& $f $y), (& $f ($x + $w - $r)), (& $f ($x + $w)), (& $f $r), (& $f ($y + $r)),
            (& $f ($y + $h - $r)), (& $f ($y + $h)), (& $f $x)
    }
    function Get-VmfCirclePath([double]$cx, [double]$cy, [double]$r) {
        'M{0} {1}A{2} {2} 0 1 0 {3} {1}A{2} {2} 0 1 0 {0} {1}Z' -f (Format-VmfNum ($cx - $r)), (Format-VmfNum $cy), (Format-VmfNum $r), (Format-VmfNum ($cx + $r))
    }
    # unit(x,y): a 15 x 6.6 body, three drive bays, one status light. The bays
    # and the light are sub-paths of the body, so even-odd makes them holes.
    function Get-VmfUnitPath([double]$x, [double]$y) {
        $w = 15; $h = 6.6; $cy = $y + $h / 2
        $parts = @(Get-VmfRoundRectPath $x $y $w $h 1.5)
        foreach ($i in 0..2) { $parts += Get-VmfRoundRectPath ($x + 1.8 + $i * 2.6) ($cy - 1.7) 1.6 3.4 0.5 }
        $parts += Get-VmfCirclePath ($x + $w - 2.6) $cy 1.25
        $parts -join ''
    }
    # The drawing elements of an SVG, comments out and whitespace between tags
    # gone, so two copies compare as drawings and not as layouts.
    function Get-VmfDrawing([string]$svg) {
        $s = [regex]::Replace($svg, '<!--[\s\S]*?-->', '')
        $start = $s.IndexOf('</title>')
        $s = $s.Substring($start + 8, $s.LastIndexOf('</svg>') - $start - 8)
        ([regex]::Replace($s, '>\s+<', '><')).Trim()
    }
}

Describe 'BRAND-1: one mark, drawn once' {

    It 'the mark exists and is a real drawing, not a placeholder' {
        foreach ($svg in $script:logo, $script:mark) {
            $svg | Should -Match '<svg'
            $svg | Should -Match 'viewBox="0 0 32 32"'
            # It has to say what it is: the tab icon and the mask both read it,
            # and a screen reader reads the icon.
            $svg | Should -Match '<title>Migration Factory</title>'
        }
    }

    It 'the waiting units are dimmed with OPACITY, because a mask reads alpha' {
        # A paler blue would look right as an icon and vanish in the header: a
        # CSS mask throws the colour away and keeps only the alpha channel.
        $script:mark | Should -Match '<g class="vmf-mark-wait" opacity="\.55">'
        $script:logo | Should -Match 'opacity="\.5"'
    }

    It 'the header draws the mark inline in currentColor, so it follows the theme' {
        $script:mark | Should -Match '<svg [^>]*fill="currentColor"'
        $script:mark | Should -Match 'stroke="currentColor"'
        # No colour of its own: the header, the card and the banner paint it.
        $script:mark | Should -Not -Match '#[0-9a-fA-F]{3,6}\b'
        $script:css | Should -Match '\.brand \.logo \{[^}]*color:currentColor|\.brand \.logo svg \{'
    }

    It 'every page carries the same lockup - mark, then name' {
        foreach ($page in $script:pages) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Match '<span class="logo" aria-hidden="true"></span>' -Because "$($page.Name) must show the mark"
            $text | Should -Match '<span class="b-1">Migration</span><span class="b-2">Factory</span>' -Because "$($page.Name) must show the name"
            $text | Should -Not -Match '>VMF<' -Because "$($page.Name) should not still show the old text mark"
        }
    }

    It 'and every page names itself in the browser tab, under the product name' {
        foreach ($page in $script:pages) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Match '<title>Migration Factory - [^<]+</title>' -Because "$($page.Name) needs its own tab name"
        }
    }

    It 'and every page asks for the icon' {
        foreach ($page in $script:pages) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Match '<link rel="icon" href="logo\.svg" type="image/svg\+xml">' -Because "$($page.Name) has no tab icon"
        }
    }
}

Describe 'LOGO-SERVERS-1: the mark shows server units (design 2b)' {

    It 'has two waiting units, each with three drive bays and a status light, cut out' {
        $wait = [regex]::Match($script:mark, '<g class="vmf-mark-wait" opacity="\.55">([\s\S]*?)</g>')
        $wait.Success | Should -BeTrue
        $wait.Groups[1].Value | Should -Match ([regex]::Escape('<path fill-rule="evenodd" d="' + (Get-VmfUnitPath 2.6 4.4) + '"/>'))
        $wait.Groups[1].Value | Should -Match ([regex]::Escape('<path fill-rule="evenodd" d="' + (Get-VmfUnitPath 2.6 21) + '"/>'))
    }

    It 'has the moving unit in the middle, offset right, outside the dimmed group' {
        $outside = [regex]::Replace($script:mark, '<g class="vmf-mark-wait"[\s\S]*?</g>', '')
        $outside | Should -Match ([regex]::Escape('<path class="vmf-mark-move" fill-rule="evenodd" d="' + (Get-VmfUnitPath 6.4 12.7) + '"/>'))
    }

    It 'has the arrow head ahead of it, with round ends, measured as 100 long' {
        $head = [regex]::Match($script:mark, '<path class="vmf-mark-head"[^>]*/>').Value
        $head | Should -Match 'd="M23\.6 11\.2 L28\.4 16 L23\.6 20\.8"'
        $head | Should -Match 'fill="none"'
        $head | Should -Match 'stroke-width="3\.4"'
        $head | Should -Match 'stroke-linecap="round"'
        $head | Should -Match 'stroke-linejoin="round"'
        # The stray-dot trap: the dash is the line's exact length only when the
        # browser is told how long the line is.
        $head | Should -Match 'pathLength="100"'
    }

    It 'cuts the bays and lights out as real holes, never as a painted colour' {
        # The mark is used as a CSS mask and sits on any background. A bay
        # painted white would show white on the dark header.
        foreach ($m in [regex]::Matches($script:mark, '<path [^>]*class="vmf-mark-(?:move)"[^>]*/>|<g class="vmf-mark-wait"[\s\S]*?</g>')) {
            $m.Value | Should -Match 'fill-rule="evenodd"'
        }
        $script:mark | Should -Not -Match 'fill="(?:white|#fff|#ffffff|black|#000)"'
        $script:mark | Should -Not -Match '<mask'
    }

    It 'is the finished drawing with no motion at all: nothing in the file hides a part' {
        # prefers-reduced-motion turns the animation off. What is left must be
        # the whole mark, so the file itself carries no dash and no zero opacity.
        $script:mark | Should -Not -Match 'stroke-dash'
        $script:mark | Should -Not -Match 'opacity="0"'
        $script:mark | Should -Not -Match 'transform='
    }
}

Describe 'LOGO-SERVERS-1: help.js draws the header from the same drawing' {

    It 'holds the drawing of mark.svg, element for element' {
        $m = [regex]::Match($script:helpJs, 'const MARK_DRAWING =([\s\S]*?);')
        $m.Success | Should -BeTrue -Because 'help.js keeps the header drawing in MARK_DRAWING'
        $inline = (-join ([regex]::Matches($m.Groups[1].Value, "'([^']*)'") | ForEach-Object { $_.Groups[1].Value })).Trim()
        $inline | Should -Be (Get-VmfDrawing $script:mark) -Because 'copy the drawing elements of src/dashboard/mark.svg into MARK_DRAWING in help.js'
    }

    It 'puts it into the header mark of every page, inside one svg in currentColor' {
        $m = [regex]::Match($script:helpJs, 'function installMark\(\) \{[\s\S]*?\n  \}')
        $m.Success | Should -BeTrue
        $m.Value | Should -Match "querySelectorAll\('\.brand \.logo'\)"
        $m.Value | Should -Match 'viewBox="0 0 32 32"'
        $m.Value | Should -Match 'fill="currentColor"'
        $m.Value | Should -Match 'MARK_DRAWING'
        $script:helpJs | Should -Match '(?m)^  installMark\(\);'
    }

    It 'declares nothing the browser owns: the whole file is one closed function' {
        # A page script with a top-level `const top` stops before it draws:
        # top belongs to the browser. help.js keeps every name inside one
        # function, so nothing it names can meet a browser global.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = (Get-VmfCodeOnly -Text $script:helpJs -Language CStyle).Trim()
        $code | Should -Match '^\(function \(\) \{'
        $code | Should -Match '\}\)\(\);$'
    }
}

Describe 'LOGO-SERVERS-1: the mark moves once when a page opens' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function Get-VmfCssRule([string]$selector) {
            [regex]::Match($script:css, '(?m)^' + [regex]::Escape($selector) + '\s*\{([^}]*)\}').Groups[1].Value
        }
        function Get-VmfKeyframes([string]$name) {
            [regex]::Match($script:css, '@keyframes ' + [regex]::Escape($name) + '\s*\{((?:[^{}]*\{[^}]*\})*)\s*\}').Groups[1].Value
        }
    }

    It 'the header has no mask: the drawing is inline, so its parts can move' {
        (Get-VmfCssRule '.brand .logo') | Should -Not -Match 'mask'
        (Get-VmfCssRule '.brand .logo svg') | Should -Match 'width:100%'
    }

    It 'the waiting units fade in over 0.45 s' {
        $rule = Get-VmfCssRule '.brand .logo .vmf-mark-wait'
        $rule | Should -Match 'animation:vmf-mark-in \.45s ease-out both'
        (Get-VmfKeyframes 'vmf-mark-in') | Should -Match 'from\s*\{\s*opacity:0;?\s*\}'
    }

    It 'the moving unit slides 4 units right as it fades in, over 0.45 s' {
        $rule = Get-VmfCssRule '.brand .logo .vmf-mark-move'
        $rule | Should -Match 'animation:vmf-mark-slide \.45s ease-out both'
        $frames = Get-VmfKeyframes 'vmf-mark-slide'
        $frames | Should -Match 'from\s*\{[^}]*opacity:0'
        $frames | Should -Match 'from\s*\{[^}]*transform:translateX\(-4px\)'
    }

    It 'the arrow head draws itself in 0.4 s after 0.35 s, hidden until it starts' {
        $rule = Get-VmfCssRule '.brand .logo .vmf-mark-head'
        $rule | Should -Match 'animation:vmf-mark-draw \.4s ease-out \.35s both'
        # The dash belongs to the animation only, so with no animation the
        # whole line shows.
        $rule | Should -Not -Match 'stroke-dash'
        $frames = Get-VmfKeyframes 'vmf-mark-draw'
        $frames | Should -Match '0%\s*\{[^}]*stroke-dasharray:100 100'
        $frames | Should -Match '0%\s*\{[^}]*stroke-dashoffset:100'
        # The stray-dot trap: a round cap on a dash of length zero is a dot.
        $frames | Should -Match '0%\s*\{[^}]*opacity:0'
        $frames | Should -Match '1%\s*\{[^}]*opacity:1'
        $frames | Should -Match '100%\s*\{[^}]*stroke-dasharray:100 100'
        $frames | Should -Match '100%\s*\{[^}]*stroke-dashoffset:0'
    }

    It 'then nothing moves: no part of the mark loops' {
        foreach ($sel in '.brand .logo .vmf-mark-wait', '.brand .logo .vmf-mark-move', '.brand .logo .vmf-mark-head') {
            (Get-VmfCssRule $sel) | Should -Not -Match 'infinite|alternate|iteration' -Because "$sel runs once"
        }
    }

    It 'with prefers-reduced-motion: reduce, no animation runs' {
        $media = [regex]::Matches($script:css, '@media\s*\(prefers-reduced-motion:\s*reduce\)\s*\{([^{}]*\{[^}]*\})+\s*\}') |
            Where-Object { $_.Value -match '\.brand \.logo' }
        @($media).Count | Should -Be 1
        $media[0].Value | Should -Match '\.brand \.logo svg \*\s*\{\s*animation:none'
    }
}

Describe 'LOGO-SERVERS-1: the still mark and the tab icon' {

    It 'the sign-in card uses mark.svg as its mask' {
        $script:css | Should -Match '\.signin-mark \{[^}]*mask:url\(mark\.svg\)'
        $script:css | Should -Not -Match 'mask:url\(logo\.svg\)'
    }

    It 'the tab icon is design C: three larger units, no bays' {
        $script:logo | Should -Match '<rect x="1\.5" y="1\.5" width="17" height="9" rx="2" opacity="\.5"/>'
        $script:logo | Should -Match '<rect x="1\.5" y="21\.5" width="17" height="9" rx="2" opacity="\.5"/>'
    }

    It 'the moving unit keeps its status light as a real hole' {
        $want = '<path fill-rule="evenodd" d="' + (Get-VmfRoundRectPath 5.5 11.5 17 9 2) + (Get-VmfCirclePath 18.2 16 1.9) + '"/>'
        $script:logo | Should -Match ([regex]::Escape($want))
        $script:logo | Should -Not -Match '<mask'
    }

    It 'and the arrow head is heavier' {
        $script:logo | Should -Match '<path d="M25 11 L30 16 L25 21" fill="none" stroke="currentColor" stroke-width="3\.6" stroke-linecap="round" stroke-linejoin="round"/>'
    }

    It 'has its own colour for a light and a dark browser' {
        $script:logo | Should -Match '<svg [^>]*fill="currentColor"'
        $script:logo | Should -Match 'svg\s*\{\s*color:\s*#446e9b;?\s*\}'
        $script:logo | Should -Match '@media \(prefers-color-scheme: dark\)\s*\{\s*svg\s*\{\s*color:\s*#8fb3d9;?\s*\}\s*\}'
    }

    It 'and keeps the layout of the mark: waiting above and below, moving in the middle and offset right, the arrow ahead' {
        # Two drawings for two sizes, one arrangement - so the tab and the
        # header never tell two stories.
        foreach ($case in @(
                @{ svg = $script:logo; waitX = 1.5; waitTop = 1.5; waitBottom = 21.5; moveX = 5.5; moveRight = 22.5; moveMid = 16; headBack = 25; headY = 16 },
                @{ svg = $script:mark; waitX = 2.6; waitTop = 4.4; waitBottom = 21; moveX = 6.4; moveRight = 21.4; moveMid = 16; headBack = 23.6; headY = 16 })) {
            $case.waitTop | Should -BeLessThan $case.waitBottom
            $case.moveX | Should -BeGreaterThan $case.waitX
            $case.moveMid | Should -Be 16
            $case.headBack | Should -BeGreaterThan $case.moveRight
            $case.headY | Should -Be 16
        }
        $script:logo | Should -Match ([regex]::Escape((Get-VmfRoundRectPath 5.5 11.5 17 9 2)))
        $script:mark | Should -Match ([regex]::Escape((Get-VmfUnitPath 6.4 12.7)))
    }

    It 'the screenshots of the manual show the finished mark, not a frame of its motion' {
        $shots = Get-Content (Join-Path $script:repoRoot 'tools' 'manual-shots.js') -Raw
        $shots | Should -Match "name: 'prefers-reduced-motion', value: 'reduce'"
    }
}

Describe 'LOGO-SERVERS-1: the report wears the same mark, still' {
    # The migration report, the shared report and the printed report are
    # documents, so their mark does not move. It is mark.svg's drawing with
    # the motion hooks (class, pathLength) taken out, in one colour - the
    # module ships without the dashboard folder, so it holds a copy, and this
    # test derives the copy from mark.svg so the two cannot drift.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:reportSrc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'report' 'ReportHtml.ps1') -Raw
        $script:reportLogo = [regex]::Match($script:reportSrc, "(?m)^\`$script:VmfReportLogo = '([^']*)'").Groups[1].Value
    }

    It 'is mark.svg''s drawing, element for element, with no motion' {
        $still = [regex]::Replace((Get-VmfDrawing $script:mark), ' (?:class|pathLength)="[^"]*"', '')
        $script:reportLogo | Should -BeExactly ('<svg viewBox="0 0 32 32" aria-hidden="true"><g fill="currentColor">' + $still + '</g></svg>')
    }

    It 'has the server units and their holes' {
        $script:reportLogo | Should -Match ([regex]::Escape('<path fill-rule="evenodd" d="' + (Get-VmfUnitPath 6.4 12.7) + '"/>'))
        $script:reportLogo | Should -Not -Match 'class=|pathLength|animation'
    }
}
Describe 'BRAND-1: the manual wears the same mark' {
    # The manual ships INSIDE the dashboard and is copied whole, so it keeps
    # its own copy of the drawing beside it - a manual that needs another
    # folder to render is not self-contained, which is the whole reason its
    # vendor files sit next to it.
    #
    # Two copies of a drawing is exactly how a brand drifts, so this asserts
    # they are the same bytes rather than trusting anybody to remember.
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:manualDir = Join-Path $script:repoRoot 'docs' 'manual'
        $script:manualHtml = (Get-VmfPageSource -Path (Join-Path $script:manualDir 'index.html'))
        $script:manualCss = Get-Content (Join-Path $script:manualDir 'manual.css') -Raw
    }

    It 'the manual has the mark and the tab icon, byte for byte the dashboard files' {
        foreach ($name in 'logo.svg', 'mark.svg') {
            $a = Get-FileHash (Join-Path $script:dash $name) -Algorithm SHA256
            $b = Get-FileHash (Join-Path $script:manualDir $name) -Algorithm SHA256
            $b.Hash | Should -Be $a.Hash -Because "copy src/dashboard/$name over docs/manual/$name when the mark changes"
        }
    }

    It 'the banner shows the mark and the product name' {
        $script:manualHtml | Should -Match 'class="m-logo"'
        $script:manualHtml | Should -Match '<span class="b-1">Migration</span><span class="b-2">Factory</span>'
        $script:manualCss | Should -Match 'mask: url\(mark\.svg\)'
        $script:manualCss | Should -Not -Match 'mask: url\(logo\.svg\)'
        $script:manualCss | Should -Match '\.m-logo \{[^}]*background: currentColor'
    }

    It 'and the manual has a tab icon too' {
        $script:manualHtml | Should -Match '<link rel="icon" href="logo\.svg" type="image/svg\+xml">'
    }
}

Describe 'BRAND-1: the mark actually reaches the browser' {
    # Two ways a logo ships broken, both of which this project has already been
    # bitten by with a different file type.

    It 'IIS is told what an .svg is, or it answers 404' {
        # HOST-1: IIS 404s any extension with no MIME map. That is how the
        # dashboard once loaded and could not read its own .json configuration.
        # A missing mark fails more quietly and just as completely.
        $webConfig = Get-Content (Join-Path $script:dash 'web.config') -Raw
        $webConfig | Should -Match '<mimeMap fileExtension="\.svg" mimeType="image/svg\+xml" />'
    }

    It 'the publish ships both drawings, because that list is explicit' {
        # A file not named in Deploy-VmfDashboard.ps1 does not ship, and the
        # deploy still reports success. help.js shipped missing exactly once
        # that way and broke every page.
        $deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
        $deploy | Should -Match "'logo\.svg'"
        $deploy | Should -Match "'mark\.svg'"
    }
}
