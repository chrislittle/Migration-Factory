#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REPORT-THEME-1 (GitHub issue 426): the report follows the dashboard's light or
# dark choice on screen, and the record download looks like it. (It printed
# light until REPORT-AUTO-1; see decision 2 below.)
#
# The decisions, 2026-10-02:
#   1. On screen the report follows the dashboard's choice. The PAGE marks the
#      document before the frame gets it - nothing runs inside the sandbox, and
#      the sandbox stays empty (SEC-REPORT-1). The stylesheet has a dark
#      palette keyed on that mark, at token level, and is correct with no mark.
#   2. Printing and every downloaded file stay light. REVERSED on
#      2026-10-02 (REPORT-AUTO-1): the person's theme is honoured everywhere.
#      A print follows the theme the document shows; the stored report has no
#      mark, because no person wrote it; the record download is marked with
#      the theme the person sees when they save it. The tests below that held
#      "light" are rewritten to that rule, each saying so.
#   3. The record download uses the report's SAME stylesheet - one copy.
#   4. The report link is on the row, without expanding it.
#
# This file holds the stylesheet, the service and the page's structure.
# tests/js/report-theme.test.js RUNS the page's functions.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # The stylesheet the module EMITS - not the source text that builds it.
    $script:css = InModuleScope VmMigrationFactory { $script:VmfReportCss }

    function Get-RtTokens([string]$Block) {
        $h = @{}
        foreach ($m in [regex]::Matches($Block, '(--[a-z0-9-]+)\s*:\s*([^;]+);')) {
            $h[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
        }
        $h
    }
    # The body of the first rule whose selector is exactly $Selector, with
    # spaces around the punctuation ignored. Token blocks hold no nested braces.
    function Get-RtBlock([string]$Text, [string]$Selector) {
        $pattern = ([regex]::Escape($Selector) -replace ',', '\s*,\s*') + '\s*\{([^{}]*)\}'
        $m = [regex]::Match($Text, $pattern)
        if ($m.Success) { $m.Groups[1].Value } else { $null }
    }
    # The text inside an @media rule, to its matching brace.
    function Get-RtMedia([string]$Text, [string]$Query) {
        $m = [regex]::Match($Text, '@media\s*' + $Query + '\s*\{')
        if (-not $m.Success) { return $null }
        $depth = 1; $i = $m.Index + $m.Length
        while ($i -lt $Text.Length -and $depth -gt 0) {
            if ($Text[$i] -eq '{') { $depth++ } elseif ($Text[$i] -eq '}') { $depth-- }
            $i++
        }
        [pscustomobject]@{ Body = $Text.Substring($m.Index + $m.Length, $i - 1 - ($m.Index + $m.Length)); Start = $m.Index }
    }
    function Get-RtContrast([string]$A, [string]$B) {
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
        (([math]::Max($x, $y)) + 0.05) / (([math]::Min($x, $y)) + 0.05)
    }

    $script:lightBlock = Get-RtBlock $script:css ':root,:root[data-theme="light"]'
    $script:darkBlock = Get-RtBlock $script:css ':root[data-theme="dark"]'
    $script:systemMedia = Get-RtMedia $script:css '\(\s*prefers-color-scheme\s*:\s*dark\s*\)'
    $script:printMedia = Get-RtMedia $script:css 'print'
    $script:light = Get-RtTokens $script:lightBlock
    $script:dark = Get-RtTokens $script:darkBlock

    $script:appCss = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'app.css') -Raw
    $script:appLight = Get-RtTokens ([regex]::Match($script:appCss, ':root, :root\[data-theme="light"\]\s*\{(.*?)\n\}', 'Singleline').Groups[1].Value)
    $script:appDark = Get-RtTokens ([regex]::Match($script:appCss, ':root\[data-theme="dark"\]\s*\{(.*?)\n\}', 'Singleline').Groups[1].Value)

    $script:pageRaw = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'reports.html'))
    $script:page = Get-VmfCodeOnly -Text $script:pageRaw -Language CStyle
    function Get-RtPageFunction([string]$Name) {
        [regex]::Match($script:page, "(?s)(?:async )?function $Name\(.*?\n\}").Value
    }
}

Describe 'REPORT-THEME-1: the report stylesheet has the dashboard''s three states' {
    It 'light is the root, and the light mark' {
        $script:lightBlock | Should -Not -BeNullOrEmpty -Because 'no mark and data-theme="light" share the light palette'
        @($script:light.Keys).Count | Should -BeGreaterThan 15
        $script:lightBlock | Should -Match 'color-scheme\s*:\s*light' -Because 'the browser furniture goes the same way as the page'
    }

    It 'the dark mark has its own palette' {
        $script:darkBlock | Should -Not -BeNullOrEmpty -Because 'the page marks the document dark when the dashboard is dark'
        $script:darkBlock | Should -Match 'color-scheme\s*:\s*dark'
    }

    It 'with no mark, a dark system gets the dark palette - and a light mark still wins' {
        $script:systemMedia | Should -Not -BeNullOrEmpty -Because 'a document with no mark follows the operating system'
        $inner = Get-RtBlock $script:systemMedia.Body ':root:not([data-theme="light"])'
        $inner | Should -Not -BeNullOrEmpty -Because 'the light mark must override the system, as theme.js lets a choice override it'
        $tokens = Get-RtTokens $inner
        foreach ($k in $script:dark.Keys) { $tokens[$k] | Should -Be $script:dark[$k] -Because "$k is the same dark value with or without the mark" }
    }

    It 'both palettes name the same tokens' {
        $onlyLight = @($script:light.Keys | Where-Object { -not $script:dark.ContainsKey($_) })
        $onlyDark = @($script:dark.Keys | Where-Object { -not $script:light.ContainsKey($_) })
        ($onlyLight + $onlyDark) -join ', ' | Should -BeNullOrEmpty -Because 'a token one palette forgets takes the other palette''s value'
    }

    It 'the palettes are the dashboard''s own values' {
        # One look across the product: a report token that app.css also names
        # holds the same value in the same theme.
        $drift = foreach ($pair in @(@($script:light, $script:appLight, 'light'), @($script:dark, $script:appDark, 'dark'))) {
            foreach ($k in $pair[0].Keys) {
                if ($pair[1].ContainsKey($k) -and $pair[0][$k] -ne $pair[1][$k]) { "$($pair[2]) ${k}: report $($pair[0][$k]), app.css $($pair[1][$k])" }
            }
        }
        $drift -join '; ' | Should -BeNullOrEmpty
        @($script:dark.Keys | Where-Object { $script:appDark.ContainsKey($_) }).Count | Should -BeGreaterThan 12 -Because 'otherwise this compares nothing'
    }

    It 'every colour outside the token blocks is a token, so the dark palette reaches every rule' {
        $rules = $script:css
        foreach ($b in @($script:lightBlock, $script:darkBlock, (Get-RtBlock $script:systemMedia.Body ':root:not([data-theme="light"])'))) {
            $rules = $rules.Replace($b, '')
        }
        $print = Get-RtBlock $script:printMedia.Body ':root[data-theme],:root:not([data-theme])'
        if ($print) { $rules = $rules.Replace($print, '') }
        $left = @([regex]::Matches($rules, '#[0-9a-fA-F]{3,8}\b|rgba?\(|hsla?\(') | ForEach-Object { $_.Value })
        $left -join ' ' | Should -BeNullOrEmpty -Because 'a literal in a rule stays light in the dark palette'
    }

    It 'every text and chip pair clears 4.5:1, in both palettes' {
        $pairs = @(
            @('--body', '--bg'), @('--body', '--card'), @('--ink', '--card'), @('--ink', '--card-2'),
            @('--muted', '--card'), @('--muted', '--bg'), @('--quiet-on', '--card-2'),
            @('--brand', '--card'), @('--brand', '--bg'), @('--on-nav', '--nav'),
            @('--good-on', '--good-soft'), @('--warn-on', '--warn-soft'), @('--bad-on', '--bad-soft'), @('--brand-on', '--brand-soft'))
        $low = foreach ($name in 'light', 'dark') {
            $t = if ($name -eq 'light') { $script:light } else { $script:dark }
            foreach ($p in $pairs) {
                $r = Get-RtContrast $t[$p[0]] $t[$p[1]]
                if ($r -lt 4.5) { '{0}: {1} on {2} is {3:N2}' -f $name, $p[0], $p[1], $r }
            }
        }
        $low -join '; ' | Should -BeNullOrEmpty
    }

    It 'a grey chip and the wave line use the chip token, not the muted one' {
        # --muted on --card-2 is 4.46 on the dark ground. app.css found the
        # same thing and made --quiet-on for it.
        $script:css | Should -Match '\.pill\.quiet\{[^}]*color:var\(--quiet-on\)'
        $script:css | Should -Match 'tr\.wave \.w\{[^}]*color:var\(--quiet-on\)'
    }
}

# REPORT-AUTO-1 REWROTE these two Describes. They held printing and the stored
# report to light - REPORT-THEME-1's rule, which was reversed on
# 2026-10-02: the user's theme preference is honoured everywhere.
Describe 'REPORT-AUTO-1: a print follows the theme the document shows' {
    It 'the print rule sets no palette and no colour scheme, so the theme reaches paper' {
        $script:printMedia | Should -Not -BeNullOrEmpty
        $script:printMedia.Body | Should -Not -Match '--[a-z0-9-]+\s*:' -Because 'a token set in print would force one palette whatever the screen shows'
        $script:printMedia.Body | Should -Not -Match '(?<!-)color-scheme' -Because 'nothing in print re-themes the root'
        $script:printMedia.Body | Should -Not -Match 'data-theme'
    }

    It 'a dark print keeps its dark ground: the colours print exactly as shown' {
        # Review 2: a browser leaves backgrounds out of a print by default. A
        # dark report then prints its light text on white paper - unreadable.
        $root = Get-RtBlock $script:printMedia.Body ':root'
        $root | Should -Not -BeNullOrEmpty
        $root | Should -Match '(?<![-\w])print-color-adjust\s*:\s*exact'
        $root | Should -Match '-webkit-print-color-adjust\s*:\s*exact'
    }

    It 'a wide table prints whole: the box does not scroll on paper, and a long value breaks' {
        # Independent review: the record's tables sit in .box{overflow-x:auto},
        # and its step details hold resource ids with no break point. On paper
        # a scrolling box is cut off, and the record exists to be printed.
        $script:printMedia.Body | Should -Match '\.box\{[^}]*overflow:visible'
        $script:printMedia.Body | Should -Match 'td\{[^}]*overflow-wrap:anywhere'
    }
}

Describe 'REPORT-AUTO-1: the stored report has no mark, and follows the reader''s system' {
    It 'the stored report carries no theme mark, and carries the one stylesheet' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rtheme-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'theme-run' | Out-Null }
            $html = Get-Content (New-VmfReport -OutPath $rp) -Raw
            $html | Should -Match '<html lang="en">'
            $html | Should -Not -Match '<html[^>]*data-theme' -Because 'no person wrote it, so no person''s choice is on it'
            $html | Should -Match ([regex]::Escape($script:css)) -Because 'the stored report carries the one stylesheet'
        }
        finally { if (Test-Path $rp) { Remove-Item $rp -Recurse -Force } }
    }

    It 'with no mark, a light system gets the light palette' {
        # The light block's selector names the bare root, so a document with no
        # mark and no dark system preference is light.
        $script:css | Should -Match '(?m)^:root,:root\[data-theme="light"\]\{'
    }

    It 'with no mark, a dark system gets the dark palette' {
        # The dark rule inside the system query applies to a root that is NOT
        # marked light - an unmarked root is not - and :root:not(...) is more
        # specific than :root, so it wins over the light block.
        $inner = Get-RtBlock $script:systemMedia.Body ':root:not([data-theme="light"])'
        $inner | Should -Not -BeNullOrEmpty
        (Get-RtTokens $inner)['--bg'] | Should -Be $script:dark['--bg']
        $script:systemMedia.Body | Should -Not -Match ':root\s*\{' -Because 'a bare :root here would also take a root marked light'
    }
}

Describe 'REPORT-THEME-1: the record reads the report''s stylesheet from the service' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:fnDir = Join-Path $script:repoRoot 'src' 'facade' 'app' 'GetReportStyle'
        $script:core = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        function Global:RtPrincipal([string[]]$Roles) {
            $claims = @(@{ typ = 'preferred_username'; val = 'viewer@example.com' }) + @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
    }
    AfterAll { Remove-Item 'function:\RtPrincipal' -ErrorAction SilentlyContinue }

    It 'the module gives the stylesheet and the mark it puts in the report - the same text, not a copy' {
        $look = InModuleScope VmMigrationFactory { Get-VmfReportLook }
        $look.stylesheet | Should -BeExactly $script:css
        $look.logo | Should -BeExactly (InModuleScope VmMigrationFactory { $script:VmfReportLogo })
    }

    It 'the service answers GET report-style with it, to every role' {
        $cfg = Get-Content (Join-Path $script:fnDir 'function.json') -Raw | ConvertFrom-Json
        $trigger = @($cfg.bindings | Where-Object { $_.type -eq 'httpTrigger' })[0]
        $trigger.route | Should -Be 'report-style'
        @($trigger.methods) | Should -Be @('get')
        Get-VmfCodeOnly -Path (Join-Path $script:fnDir 'run.ps1') | Should -Match 'Get-VmfFacadeReportStyle -Principal'
        foreach ($role in 'Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin') {
            $r = Get-VmfFacadeReportStyle -Principal (RtPrincipal @($role))
            $r.stylesheet | Should -BeExactly $script:css -Because "$role reads it"
            $r.logo | Should -Match '^<svg '
        }
    }

    It 'and to nobody without a role' {
        { Get-VmfFacadeReportStyle -Principal $null } | Should -Throw '*401*'
        { Get-VmfFacadeReportStyle -Principal (RtPrincipal @()) } | Should -Throw '*403*'
    }

    It 'reads it from the module, never a second copy' {
        $fn = [regex]::Match($script:core, '(?s)function Get-VmfFacadeReportStyle.*?\n\}').Value
        $fn | Should -Match 'Get-VmfReportLook'
        $fn | Should -Not -Match '--card|\{color:'
        (Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1')).FunctionsToExport |
            Should -Contain 'Get-VmfFacadeReportStyle'
    }
}

Describe 'REPORT-THEME-1: the Reports page holds no copy of the look, and the sandbox is unchanged' {
    It 'no rule of the report stylesheet is written in the page' {
        $selectors = @([regex]::Matches($script:css, '(?m)(?:^|\})([.a-z][a-z0-9 .,>:-]*)\{') | ForEach-Object { $_.Groups[1].Value.Trim() } |
            Where-Object { $_ -match '^\.' } | Select-Object -Unique)
        $selectors.Count | Should -BeGreaterThan 10 -Because 'otherwise this compares nothing'
        $copied = @($selectors | Where-Object { $script:pageRaw.Contains("$_{") })
        $copied -join ', ' | Should -BeNullOrEmpty
        $script:pageRaw | Should -Not -Match '--card-2\s*:|--brand-soft\s*:' -Because 'the palette lives in the module'
    }

    It 'the record carries no style of its own: no inline style, no colour, no font' {
        $fn = Get-RtPageFunction 'recordHtml'
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Not -Match 'style='
        $fn | Should -Not -Match '#[0-9a-fA-F]{3,8}\b|rgba?\(|font-family|border-collapse'
        $fn | Should -Match 'look\.stylesheet' -Because 'it uses the stylesheet the service gave'
    }

    It 'the module''s own mark passes the page''s drawing rule, so the record keeps it' {
        # The page takes a mark only in the report's own shape. If the module's
        # mark gains an element the rule does not name, the record loses it
        # without a word - so the two are held together here.
        $m = [regex]::Match((Get-RtPageFunction 'recordHtml'), 'const drawing = /(.+)/;')
        $m.Success | Should -BeTrue
        $logo = InModuleScope VmMigrationFactory { $script:VmfReportLogo }
        $logo | Should -Match $m.Groups[1].Value
    }

    # REPORT-AUTO-1 REWROTE this: it held the record to light. The record is
    # marked with the theme the person sees when they save it, through the one
    # guard the page uses - only 'dark' or 'light' is ever written.
    # tests/js/report-auto.test.js RUNS the download with each theme.
    It 'the record is marked from the theme it is given, and only ever dark or light' {
        $fn = Get-RtPageFunction 'recordHtml'
        $fn | Should -Match "const mark = theme === 'dark' \? 'dark' : 'light';"
        $fn | Should -Match "const root = '<html lang=`"en`" data-theme=`"' \+ mark \+ '`">';"
        $fn | Should -Match 'return `<!doctype html>\$\{root\}<head>'
    }

    It 'the download asks for the look and the theme this page shows, and passes both to the record' {
        $fn = Get-RtPageFunction 'downloadRecord'
        $fn | Should -Match 'recordHtml\(rec, await reportLook\(\), theme\)'
        $fn | Should -Match 'VmfTheme\.current\(\)' -Because 'choice() can say "system", which is not a palette'
        Get-RtPageFunction 'reportLook' | Should -Match "apiCall\('GET', 'report-style'\)"
    }

    It 'SEC-REPORT-1: the frame''s sandbox is ONE empty attribute, set before the report goes in' {
        $fn = Get-RtPageFunction 'openReport'
        $fn | Should -Not -BeNullOrEmpty
        @([regex]::Matches($script:page, 'sandbox')).Count | Should -Be 1 -Because 'one place sets it, and nothing adds to it'
        $fn | Should -Match "frame\.setAttribute\('sandbox', ''\);"
        $script:page | Should -Not -Match 'allow-(scripts|same-origin|popups|forms|top)'
        $fn.IndexOf("setAttribute('sandbox'") | Should -BeLessThan $fn.IndexOf('frame.srcdoc') -Because 'the frame is locked before the report is in it'
    }

    It 'the page marks the report from the theme it SHOWS, before it hands it to the frame' {
        $fn = Get-RtPageFunction 'openReport'
        $fn | Should -Match 'frame\.srcdoc = markTheme\(html, theme\);'
        $fn | Should -Match 'VmfTheme\.current\(\)' -Because 'choice() can say "system", which is not a palette'
        $fn | Should -Not -Match 'VmfTheme\.choice\(\)'
        $fn | Should -Not -Match 'write\(\s*html\b|\+\s*html\b' -Because 'the report never goes into a window that shares this origin'
    }

    It 'the report link is on the row, and pressing it does not open the row' {
        # PAGE-SCALE-REPORTS-1: the row is the shared list's; the page gives it
        # the button and listens for the press.
        Get-RtPageFunction 'runRow' | Should -Match 'x\.hasReport && !x\.setupOnly \? \[\{ text: UX\.fullReport, action: ''report'''
        $fn = Get-RtPageFunction 'onListClick'
        $fn | Should -Match 'button\[data-action="report"\]'
        $fn | Should -Match 'openReport\('
        $fn.IndexOf('openReport(') | Should -BeLessThan $fn.IndexOf('openDetail(') -Because 'the button is answered before the name, and returns'
        Get-RtPageFunction 'showDetail' | Should -Not -Match 'data-report|fullReport' -Because 'one place for the link, not two'
    }
}
