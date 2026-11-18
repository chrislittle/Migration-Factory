#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-FONTS-1: the dashboard, and the manual that ships inside it (DOC-4),
# load every style sheet, font and picture from the install itself.
#
# Found 2026-10-23: the first line of the manual's saved docsify theme
# imported two fonts from fonts.googleapis.com. The dashboard's content
# security policy (src/dashboard/web.config) allows styles, fonts and pictures
# from 'self' only, so the browser refused the request on every manual page and
# wrote an error to its console. The policy did its job; nothing in the
# repository said the request was there.
#
# The rules, for every file the dashboard deploy publishes from src/dashboard
# and docs/manual:
#   - a style sheet (a .css file, a <style> block, a style="" attribute) names
#     no outside address in an @import or a url(). data: is not an address;
#   - a page loads no style sheet, script or picture by an outside address
#     (<link href>, <script src>, <img src>);
#   - no file names a web font host at all, so a script cannot add one either;
#   - the product's own scripts and pages name only the hosts the policy lets
#     the page reach (connect-src, frame-src, read from web.config), and the
#     project page a person follows as a link.
# The sign-in library's calls to Microsoft's sign-in are fetches, not loads:
# the policy's connect-src governs them, and FacadeCore.Tests.ps1 holds that.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

    # The hosts that serve web fonts. A name here in a shipped file is a font
    # request from the reader's browser to somebody else.
    $script:fontHosts = @(
        'fonts.googleapis.com', 'fonts.gstatic.com', 'use.typekit.net', 'p.typekit.net',
        'fonts.bunny.net', 'use.fontawesome.com', 'kit.fontawesome.com', 'fast.fonts.net',
        'cloud.typography.com', 'fonts.cdnfonts.com')

    function script:Get-VmfShippedWebFiles([string]$Root) {
        foreach ($dir in 'src/dashboard', 'docs/manual') {
            $full = Join-Path $Root $dir
            if (-not (Test-Path -LiteralPath $full)) { continue }
            Get-ChildItem -LiteralPath $full -Recurse -File |
                Where-Object { $_.Extension -in '.css', '.html', '.htm', '.js' }
        }
    }

    # An address the browser would go outside the install for: a scheme, or
    # // with no scheme. A data: value is inside the page.
    function script:Test-VmfOutsideAddress([string]$Target) {
        $t = $Target.Trim().Trim('"', "'").Trim()
        if ($t -match '^(?i)data:') { return $false }
        $t -match '^(?i)(?:[a-z][a-z0-9+.-]*:|//)'
    }

    # Every outside address a piece of style sheet text loads: @import (with or
    # without url()) and url(). Comments are dropped first: a commented rule
    # loads nothing.
    function script:Get-VmfStyleOutsideLoads([string]$Css) {
        $code = [regex]::Replace($Css, '/\*.*?\*/', '', 'Singleline')
        $found = [System.Collections.Generic.List[string]]::new()
        $import = '(?i)@import\s+(?:url\(\s*)?(?<t>"[^"]*"|''[^'']*''|[^\s;)]+)\s*\)?'
        foreach ($m in [regex]::Matches($code, $import)) {
            if (Test-VmfOutsideAddress $m.Groups['t'].Value) { $found.Add($m.Value) }
        }
        # An @import is read once: its url() is not a second load.
        $code = [regex]::Replace($code, $import, '')
        foreach ($m in [regex]::Matches($code, '(?i)url\(\s*(?<t>"[^"]*"|''[^'']*''|[^)]*)\)')) {
            if (Test-VmfOutsideAddress $m.Groups['t'].Value) { $found.Add($m.Value) }
        }
        $found.ToArray()
    }

    # The style sheet text a page carries: its <style> blocks and its style=""
    # attributes.
    function script:Get-VmfPageStyleText([string]$Html) {
        $parts = foreach ($m in [regex]::Matches($Html, '(?is)<style\b[^>]*>(?<css>.*?)</style>')) { $m.Groups['css'].Value }
        $attrs = foreach ($m in [regex]::Matches($Html, '(?is)\sstyle\s*=\s*(?:"(?<css>[^"]*)"|''(?<css>[^'']*)'')')) { $m.Groups['css'].Value }
        (@($parts) + @($attrs)) -join "`n"
    }

    # The outside addresses a page loads by an element: a style sheet, a
    # script, a picture.
    function script:Get-VmfPageOutsideLoads([string]$Html) {
        $found = [System.Collections.Generic.List[string]]::new()
        foreach ($m in [regex]::Matches($Html, '(?is)<(?:link|script|img|source|iframe)\b[^>]*?\s(?:href|src)\s*=\s*(?<t>"[^"]*"|''[^'']*''|[^\s>]+)[^>]*>')) {
            if (Test-VmfOutsideAddress $m.Groups['t'].Value) { $found.Add($m.Value) }
        }
        $found.ToArray()
    }

    # Every finding for a repository: path and what it loads.
    function script:Find-VmfOutsideLoads([string]$Root) {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($file in @(Get-VmfShippedWebFiles -Root $Root)) {
            $rel = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $styles = switch ($file.Extension) {
                '.css' { $text }
                { $_ -in '.html', '.htm' } { Get-VmfPageStyleText $text }
                default { '' }
            }
            foreach ($load in @(Get-VmfStyleOutsideLoads $styles)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'style'; text = $load }) }
            if ($file.Extension -in '.html', '.htm') {
                foreach ($load in @(Get-VmfPageOutsideLoads $text)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'element'; text = $load }) }
            }
            foreach ($fontHost in $script:fontHosts) {
                if ($text.IndexOf($fontHost, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $out.Add([pscustomobject]@{ path = $rel; kind = 'font host'; text = $fontHost })
                }
            }
        }
        $out.ToArray()
    }

    # The product's own scripts and pages (every shipped file that is not a
    # library file the pin file lists) may name a host only when the
    # dashboard's policy lets the page reach it (connect-src, frame-src), or
    # when it is a link a person follows. Library files name many hosts in
    # their notices and help, and load none of them: the pin keeps them as the
    # package has them, and the rules above read them.
    $script:linkHosts = @{ 'github.com' = 'The help menu links to the project page. A person follows a link; the page loads nothing from it.'
        # REBUILD-PATCH-MODE-1: the list of what a rebuild removes links to Microsoft's patch orchestration modes.
        'learn.microsoft.com' = 'The rebuild list links to a Microsoft documentation page. A person follows a link; the page loads nothing from it.' }
    function script:Get-VmfPolicyHosts([string]$Root) {
        $config = [System.IO.File]::ReadAllText((Join-Path $Root 'src' 'dashboard' 'web.config'))
        $policy = [regex]::Match($config, '<add name="Content-Security-Policy"\s+value="(?<v>[^"]+)"').Groups['v'].Value
        foreach ($directive in $policy -split ';') {
            $words = @($directive.Trim() -split '\s+')
            if ($words[0] -notin 'connect-src', 'frame-src') { continue }
            foreach ($source in $words | Select-Object -Skip 1) {
                $m = [regex]::Match($source, '^https://(?<h>[^/]+)$')
                if ($m.Success) { $m.Groups['h'].Value.ToLowerInvariant() }
            }
        }
    }
    function script:Test-VmfHostAllowed([string]$HostName, [string[]]$Allowed) {
        foreach ($source in $Allowed) {
            if ($source.StartsWith('*.')) { if ($HostName.EndsWith($source.Substring(1))) { return $true } }
            elseif ($HostName -eq $source) { return $true }
        }
        $false
    }
    function script:Find-VmfOwnCodeOutsideHosts([string]$Root) {
        $pin = Get-Content -LiteralPath (Join-Path $Root 'infra' 'part-versions.json') -Raw | ConvertFrom-Json
        $libraries = @($pin.parts | ForEach-Object { @($_.files) } | Where-Object { $_ } | ForEach-Object { $_.path })
        $allowed = @(Get-VmfPolicyHosts -Root $Root)
        foreach ($file in @(Get-VmfShippedWebFiles -Root $Root)) {
            $rel = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
            if ($rel -in $libraries) { continue }
            $code = Get-VmfCodeOnly -Path $file.FullName -Language CStyle
            foreach ($m in [regex]::Matches($code, '(?i)\bhttps?://(?<h>[a-z0-9.-]+)')) {
                $hostName = $m.Groups['h'].Value.ToLowerInvariant()
                if ((Test-VmfHostAllowed $hostName $allowed) -or $script:linkHosts.ContainsKey($hostName)) { continue }
                [pscustomobject]@{ path = $rel; kind = 'own code'; text = $m.Value }
            }
        }
    }

    function script:Format-VmfOutsideLoads($Findings) {
        (@($Findings) | ForEach-Object { "$($_.path) ($($_.kind)): $($_.text)" }) -join '; '
    }

    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:tempRoot = New-VmfTestTemp -Prefix 'nol'
    function script:New-VmfWebFixture([hashtable]$Files) {
        $root = Join-Path $script:tempRoot ([guid]::NewGuid().ToString('N').Substring(0, 8))
        foreach ($name in $Files.Keys) {
            $file = Join-Path $root $name
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force
            [System.IO.File]::WriteAllText($file, $Files[$name])
        }
        $root
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'MANUAL-FONTS-1: the dashboard and the manual load nothing from outside the install' {

    It 'reads the shipped files: the manual theme, its own style sheet, and the dashboard style sheet and pages' {
        $names = @(Get-VmfShippedWebFiles -Root $script:repoRoot | ForEach-Object { [System.IO.Path]::GetRelativePath($script:repoRoot, $_.FullName).Replace('\', '/') })
        $names | Should -Contain 'docs/manual/vendor/vue.css'
        $names | Should -Contain 'docs/manual/manual.css'
        $names | Should -Contain 'docs/manual/index.html'
        $names | Should -Contain 'src/dashboard/app.css'
        $names | Should -Contain 'src/dashboard/index.html'
    }

    It 'the repository as it stands: no style sheet, page or script loads from outside, and none names a font host' {
        $findings = @(Find-VmfOutsideLoads -Root $script:repoRoot)
        $findings.Count | Should -Be 0 -Because (Format-VmfOutsideLoads $findings)
    }

    It 'the product''s own scripts and pages name only hosts the dashboard policy lets them reach, and links a person follows' {
        $hosts = @(Get-VmfPolicyHosts -Root $script:repoRoot)
        $hosts | Should -Contain 'login.microsoftonline.com' -Because 'the policy is read, not assumed'
        $findings = @(Find-VmfOwnCodeOutsideHosts -Root $script:repoRoot)
        $findings.Count | Should -Be 0 -Because (Format-VmfOutsideLoads $findings)
    }

    It 'the manual theme asks no outside host for fonts (the docsify line is removed)' {
        $theme = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'manual' 'vendor' 'vue.css'))
        $theme.Contains('@import') | Should -BeFalse -Because 'the theme imports nothing'
        $theme.Contains('googleapis') | Should -BeFalse -Because 'the theme names no Google font address'
    }

    It 'the dashboard policy still allows styles and fonts from the install only' {
        # If this changes, the rule above is the one that still keeps the
        # pages from asking another host: the policy is the backstop.
        $config = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'web.config'))
        $policy = [regex]::Match($config, '<add name="Content-Security-Policy"\s+value="(?<v>[^"]+)"').Groups['v'].Value
        $policy | Should -Match "(?:^|;)\s*style-src 'self' 'unsafe-inline'\s*(?:;|$)"
        $policy | Should -Not -Match 'font-src' -Because 'fonts take default-src, which is the install alone'
        $policy | Should -Match "(?:^|;)\s*default-src 'self'\s*(?:;|$)"
    }

    Context 'each kind of outside load is found (fixtures)' {

        It 'an @import of an outside style sheet, with url() or without, in any quotes' {
            foreach ($css in '@import url("https://fonts.example.com/css?family=A");',
                "@import url('https://fonts.example.com/a.css');",
                '@import url(https://fonts.example.com/a.css);',
                '@import "https://fonts.example.com/a.css";',
                "@import '//fonts.example.com/a.css';") {
                $root = New-VmfWebFixture @{ 'docs/manual/vendor/theme.css' = "$css body{color:red}" }
                @(Find-VmfOutsideLoads -Root $root | Where-Object kind -eq 'style').Count | Should -Be 1 -Because $css
            }
        }

        It 'a url() of an outside font or picture, in a style sheet file' {
            $root = New-VmfWebFixture @{ 'src/dashboard/app.css' = '@font-face{font-family:X;src:url(https://cdn.example.com/x.woff2) format("woff2")} .a{background:url("http://cdn.example.com/a.png")}' }
            @(Find-VmfOutsideLoads -Root $root | Where-Object kind -eq 'style').Count | Should -Be 2
        }

        It 'a style block or a style attribute in a page' {
            $root = New-VmfWebFixture @{ 'src/dashboard/page.html' = '<html><head><style>@import url(https://cdn.example.com/a.css);</style></head><body><div style="background:url(''https://cdn.example.com/b.png'')"></div></body></html>' }
            @(Find-VmfOutsideLoads -Root $root | Where-Object kind -eq 'style').Count | Should -Be 2
        }

        It 'a page that loads a style sheet, a script or a picture by an outside address' {
            $root = New-VmfWebFixture @{ 'docs/manual/index.html' = '<link rel="stylesheet" href="https://cdn.example.com/a.css"><script src="//cdn.example.com/a.js"></script><img alt="x" src=https://cdn.example.com/a.png>' }
            @(Find-VmfOutsideLoads -Root $root | Where-Object kind -eq 'element').Count | Should -Be 3
        }

        It 'a script that names a font host, even with no load the rules above can see' {
            $root = New-VmfWebFixture @{ 'src/dashboard/help.js' = 'var l = document.createElement("link"); l.href = "https://" + "fonts.googleapis.com/css?family=A";' }
            @(Find-VmfOutsideLoads -Root $root | Where-Object kind -eq 'font host').text | Should -Be 'fonts.googleapis.com'
        }

        It 'what stays inside is no finding: relative addresses, data:, a commented rule, and a sign-in address in script' {
            $root = New-VmfWebFixture @{
                'src/dashboard/app.css'   = '.m{mask:url(logo.svg) center} .d{background:url("data:image/png;base64,AAAA")} /* @import url("https://cdn.example.com/a.css"); */ @import "local.css";'
                'src/dashboard/page.html' = '<link rel="stylesheet" href="app.css"><script src="msal.min.js"></script><img alt="x" src="logo.svg"><script>var a = `https://login.microsoftonline.com/${t}`;</script>'
            }
            @(Find-VmfOutsideLoads -Root $root).Count | Should -Be 0
        }

        It 'the product''s own script names a host the policy does not let it reach: a finding; a library file the pin lists is not read' {
            $root = New-VmfWebFixture @{
                'src/dashboard/web.config'          = '<add name="Content-Security-Policy" value="default-src ''self''; connect-src ''self'' https://*.azurewebsites.net https://login.microsoftonline.com; frame-src https://login.microsoftonline.com" />'
                'infra/part-versions.json'          = '{ "parts": [ { "key": "npm:lib", "files": [ { "path": "src/dashboard/lib.min.js" } ] } ] }'
                'src/dashboard/page.js'             = 'fetch("https://cdn.example.com/x.json"); fetch("https://vmf-api-contoso.azurewebsites.net/api"); var a = "https://login.microsoftonline.com/t"; var r = "https://github.com/contoso/x";'
                'src/dashboard/lib.min.js'          = 'var docs = "https://lib.example.org/help";'
                'docs/manual/page.html'             = '<!-- see https://learn.example.com/a --><script>var u = "https://api.example.net/v1";</script>'
            }
            $found = @(Find-VmfOwnCodeOutsideHosts -Root $root)
            @($found.text | Sort-Object) | Should -Be @('https://api.example.net', 'https://cdn.example.com')
        }

        It 'reads only the folders the dashboard ships: a page elsewhere is not read' {
            $root = New-VmfWebFixture @{ 'docs/architecture/architecture.html' = '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=A">' }
            @(Find-VmfOutsideLoads -Root $root).Count | Should -Be 0
        }
    }
}
