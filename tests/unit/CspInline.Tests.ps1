#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CSP-INLINE-1: the dashboard's content security policy allows no inline
# script, and no page needs it to.
#
# Until 2026-11-03 web.config sent `script-src 'self' 'unsafe-inline'`,
# because every page kept its script in a block inside the HTML. With that
# allowance the browser runs any script that reaches a page, so a value a page
# forgot to escape (OUTPUT-ESCAPE-1) would run as the signed-in user. Without
# it, the browser runs only script files the site serves.
#
# The rules, for every page the dashboard deploy publishes (src/dashboard and
# the manual in docs/manual) and every script the repository wrote for them:
#   - a page has no inline <script> block: each page's script is a file with
#     the page's name (wizard.html loads wizard.js);
#   - no markup carries an inline event attribute (onclick= and the rest), in
#     a page, in a manual page, or in markup a script builds as text; a
#     listener does that work;
#   - no link or markup runs a javascript: address;
#   - the policy's script-src names the site itself and nothing that allows
#     inline script: only 'self', or a 'sha256-' hash;
#   - every script a page loads from the site is on the deploy list, so it
#     ships.
# The checks read the RAW files - the files the browser receives - never the
# reconstructed page source (_PageSource.ps1).
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

    # The pages and the repository's own scripts, in the two folders the deploy
    # publishes. A library file (*.min.js, and anything under vendor/) is kept
    # as its package has it; PartPins.Tests.ps1 holds those.
    function script:Get-VmfWebPages([string]$Root) {
        foreach ($dir in 'src/dashboard', 'docs/manual') {
            $full = Join-Path $Root $dir
            if (-not (Test-Path -LiteralPath $full)) { continue }
            Get-ChildItem -LiteralPath $full -Recurse -File |
                Where-Object { $_.Extension -in '.html', '.htm', '.md' }
        }
    }
    function script:Get-VmfOwnWebScripts([string]$Root) {
        foreach ($dir in 'src/dashboard', 'docs/manual') {
            $full = Join-Path $Root $dir
            if (-not (Test-Path -LiteralPath $full)) { continue }
            Get-ChildItem -LiteralPath $full -Recurse -File -Filter '*.js' |
                Where-Object { $_.Name -notlike '*.min.js' -and $_.FullName -notmatch '[\\/]vendor[\\/]' }
        }
    }

    # An inline event attribute inside a tag: `<button onclick=...>`. Markup a
    # script writes as text counts too, because the browser refuses it the
    # same way once it is in the page. A property set from code
    # (`el.onclick = fn`) is not markup, and the tag pattern does not see it.
    $script:handlerInTag = '(?i)<[a-z][\w-]*\b[^<>]*?\son[a-z]+\s*='
    $script:handlerSet = '(?i)setAttribute\(\s*[''"`]on[a-z]+[''"`]'
    $script:jsAddress = '(?i)(?:href|src|action|formaction)\s*=\s*\\?[''"`]?\s*javascript:'

    function script:Find-VmfInlineScript([string]$Root) {
        $out = [System.Collections.Generic.List[object]]::new()
        foreach ($file in @(Get-VmfWebPages -Root $Root)) {
            $rel = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
            $text = [System.IO.File]::ReadAllText($file.FullName)
            # A Markdown page shows its code samples as text, so a fenced block
            # is not markup. Nothing else in it is exempt: docsify puts its
            # HTML into the page as it is.
            if ($file.Extension -eq '.md') { $text = [regex]::Replace($text, '(?ms)^```.*?^```', '') }
            foreach ($m in [regex]::Matches($text, '(?is)<script\b(?<attrs>[^>]*)>(?<body>.*?)</script\s*>')) {
                if ($m.Groups['attrs'].Value -match '(?i)\bsrc\s*=') {
                    if ($m.Groups['body'].Value.Trim()) {
                        $out.Add([pscustomobject]@{ path = $rel; kind = 'inline script'; text = 'a <script src> with a body' })
                    }
                    continue
                }
                $out.Add([pscustomobject]@{ path = $rel; kind = 'inline script'; text = ($m.Value.Substring(0, [Math]::Min(60, $m.Value.Length))) })
            }
            foreach ($m in [regex]::Matches($text, $script:handlerInTag)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'event attribute'; text = $m.Value }) }
            foreach ($m in [regex]::Matches($text, $script:jsAddress)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'javascript address'; text = $m.Value }) }
        }
        foreach ($file in @(Get-VmfOwnWebScripts -Root $Root)) {
            $rel = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
            # The code alone: a comment that names onclick= runs nothing.
            $code = Get-VmfCodeOnly -Path $file.FullName -Language CStyle
            foreach ($m in [regex]::Matches($code, $script:handlerInTag)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'event attribute'; text = $m.Value }) }
            foreach ($m in [regex]::Matches($code, $script:handlerSet)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'event attribute'; text = $m.Value }) }
            foreach ($m in [regex]::Matches($code, $script:jsAddress)) { $out.Add([pscustomobject]@{ path = $rel; kind = 'javascript address'; text = $m.Value }) }
        }
        $out.ToArray()
    }

    function script:Format-VmfInlineScript($Findings) {
        (@($Findings) | ForEach-Object { "$($_.path): $($_.kind): $($_.text)" }) -join "`n"
    }

    # The policy web.config sends, as directive -> tokens.
    function script:Get-VmfPolicy([string]$Root) {
        $config = [System.IO.File]::ReadAllText((Join-Path $Root 'src' 'dashboard' 'web.config'))
        $value = [regex]::Match($config, '<add name="Content-Security-Policy"\s+value="(?<v>[^"]+)"').Groups['v'].Value
        $policy = @{}
        foreach ($part in $value -split ';') {
            $tokens = @($part.Trim() -split '\s+' | Where-Object { $_ })
            if ($tokens.Count) { $policy[$tokens[0].ToLowerInvariant()] = @($tokens | Select-Object -Skip 1) }
        }
        $policy
    }

    # What lets a script run that the site did not serve as a file. A hash is
    # the one inline form the item allows: it names one exact block.
    function script:Find-VmfScriptPolicyGaps([hashtable]$Policy) {
        $gaps = [System.Collections.Generic.List[string]]::new()
        if (-not $Policy.ContainsKey('script-src')) { $gaps.Add('no script-src: scripts fall back to default-src') }
        foreach ($directive in 'script-src', 'script-src-elem', 'script-src-attr', 'default-src') {
            if (-not $Policy.ContainsKey($directive)) { continue }
            foreach ($token in $Policy[$directive]) {
                if ($token -ceq "'self'" -or $token -cmatch "^'sha(256|384|512)-[A-Za-z0-9+/=]+'$") { continue }
                if ($directive -eq 'default-src' -and $token -cnotmatch "^'unsafe-") { continue }
                $gaps.Add("$directive $token")
            }
        }
        $gaps.ToArray()
    }

    # Every script a page loads from the site itself.
    function script:Get-VmfPageScriptFiles([string]$PagePath) {
        $text = [System.IO.File]::ReadAllText($PagePath)
        foreach ($m in [regex]::Matches($text, '(?i)<script\b[^>]*?\ssrc\s*=\s*"(?<s>[^"]+)"')) {
            $s = $m.Groups['s'].Value
            if ($s -match '^(?i)(?:[a-z][a-z0-9+.-]*:|//)') { continue }
            $s
        }
    }

    function script:New-VmfWebFixture([hashtable]$Files) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-csp-' + [guid]::NewGuid().ToString('n'))
        foreach ($k in $Files.Keys) {
            $file = Join-Path $root $k
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
            [System.IO.File]::WriteAllText($file, $Files[$k])
        }
        $script:fixtures.Add($root)
        $root
    }
    $script:fixtures = [System.Collections.Generic.List[string]]::new()
}

AfterAll {
    foreach ($f in $script:fixtures) { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'CSP-INLINE-1: no page needs inline script, and the policy allows none' {

    It 'reads every dashboard page and the manual''s page' {
        $names = @(Get-VmfWebPages -Root $script:repoRoot | ForEach-Object { [System.IO.Path]::GetRelativePath($script:repoRoot, $_.FullName).Replace('\', '/') })
        foreach ($page in 'index.html', 'projects.html', 'assessments.html', 'wizard.html', 'waves.html', 'migrations.html', 'reports.html', 'access.html') {
            $names | Should -Contain "src/dashboard/$page"
        }
        $names | Should -Contain 'docs/manual/index.html'
        @($names | Where-Object { $_ -like '*.md' }).Count | Should -BeGreaterThan 20 -Because 'the manual''s pages are read too'
    }

    It 'the repository as it stands: no inline script block, event attribute or javascript: address' {
        $findings = @(Find-VmfInlineScript -Root $script:repoRoot)
        $findings.Count | Should -Be 0 -Because (Format-VmfInlineScript $findings)
    }

    It 'the policy''s script-src allows the site''s own files and no inline script' {
        $policy = Get-VmfPolicy -Root $script:repoRoot
        $policy['script-src'] | Should -Contain "'self'"
        $gaps = @(Find-VmfScriptPolicyGaps -Policy $policy)
        $gaps.Count | Should -Be 0 -Because ($gaps -join '; ')
    }

    It 'each page with script loads it from a file with the page''s own name' {
        foreach ($page in @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html') + @(Get-Item (Join-Path $script:repoRoot 'docs' 'manual' 'index.html'))) {
            $own = $page.BaseName + '.js'
            @(Get-VmfPageScriptFiles $page.FullName) | Should -Contain $own -Because "$($page.Name) keeps its script in $own"
            Test-Path (Join-Path $page.DirectoryName $own) | Should -BeTrue -Because "$($page.Name) loads $own"
        }
    }

    It 'every script a dashboard page loads from the site is on the deploy list, so it ships' {
        # A file the deploy does not name does not ship, and the deploy still
        # reports success; the page then loads with no script at all.
        $deploy = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1')
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html' |
                ForEach-Object { Get-VmfPageScriptFiles $_.FullName } | Sort-Object -Unique)
        $files | Should -Contain 'wizard.js' -Because 'the page scripts must actually have been found'
        $missing = @($files | Where-Object { $deploy -notmatch ("'" + [regex]::Escape($_) + "'") })
        $missing -join ', ' | Should -BeNullOrEmpty
    }

    It 'the page source a check reads is the page with its own script inline' {
        $raw = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $own = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.js'))
        $source = Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')
        $source | Should -Be ($raw.Replace('<script src="wizard.js"></script>', "<script>`n" + $own + '</script>'))
        $source.Contains('<script src="help.js"></script>') | Should -BeTrue -Because 'a shared file stays as its tag'
        (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html')) | Should -Match 'function renderTargets\b' -Because 'the code of a page includes its own script'
    }

    Context 'each kind of inline script is found (fixtures)' {

        It 'an inline script block in a page, with or without attributes' {
            foreach ($html in '<html><body><script>go()</script></body></html>',
                '<html><body><script type="text/javascript">go()</script></body></html>',
                "<html><body><SCRIPT>`ngo()`n</SCRIPT ></body></html>") {
                $root = New-VmfWebFixture @{ 'src/dashboard/page.html' = $html }
                @(Find-VmfInlineScript -Root $root | Where-Object kind -eq 'inline script').Count | Should -Be 1 -Because $html
            }
        }

        It 'a script tag with src is not inline, unless it also has a body' {
            $root = New-VmfWebFixture @{ 'src/dashboard/page.html' = '<script src="page.js"></script><script src=page.js></script>' }
            @(Find-VmfInlineScript -Root $root).Count | Should -Be 0
            $root = New-VmfWebFixture @{ 'src/dashboard/page.html' = '<script src="page.js">go()</script>' }
            @(Find-VmfInlineScript -Root $root | Where-Object kind -eq 'inline script').Count | Should -Be 1
        }

        It 'an inline block in the manual''s page and in a manual page' {
            $root = New-VmfWebFixture @{ 'docs/manual/index.html' = '<script>window.$docsify = {}</script>' }
            @(Find-VmfInlineScript -Root $root).Count | Should -Be 1
            $root = New-VmfWebFixture @{ 'docs/manual/use/a.md' = "# A`n`n<script>go()</script>`n" }
            @(Find-VmfInlineScript -Root $root).Count | Should -Be 1
        }

        It 'a manual page''s code sample is text, not markup' {
            $root = New-VmfWebFixture @{ 'docs/manual/use/a.md' = "# A`n`n``````html`n<button onclick=""go()"">x</button>`n```````n" }
            @(Find-VmfInlineScript -Root $root).Count | Should -Be 0
        }

        It 'an event attribute in a page, quoted or not, in any case' {
            foreach ($html in '<button class="close" onclick="closeDrill()">x</button>',
                '<body onload=start()>', '<img alt="" src="a.png" OnError="go()">',
                "<div`n  onmouseover = 'go()'>") {
                $root = New-VmfWebFixture @{ 'src/dashboard/page.html' = $html }
                @(Find-VmfInlineScript -Root $root | Where-Object kind -eq 'event attribute').Count | Should -Be 1 -Because $html
            }
        }

        It 'an event attribute in markup a script builds, in any kind of quote' {
            foreach ($js in 'el.innerHTML = ''<button onclick="go()">x</button>'';',
                'el.innerHTML = "<a href=\"#\" onclick=\"go()\">x</a>";',
                'el.innerHTML = `<tr data-x="${esc(x)}" onclick="pick(''${esc(x)}'')"><td>a</td></tr>`;',
                'el.setAttribute(''onclick'', ''go()'');') {
                $root = New-VmfWebFixture @{ 'src/dashboard/page.js' = $js }
                @(Find-VmfInlineScript -Root $root | Where-Object kind -eq 'event attribute').Count | Should -Be 1 -Because $js
            }
        }

        It 'a property or a listener set from code is not an event attribute, and a comment is not code' {
            $js = "el.onclick = () => go();`nel.addEventListener('click', go);`n// <button onclick=""go()""> was here`n/* <a onclick=""x()""> */`nconst onlyOne = '<b>' + n + '</b>';"
            $root = New-VmfWebFixture @{ 'src/dashboard/page.js' = $js }
            @(Find-VmfInlineScript -Root $root).Count | Should -Be 0
        }

        It 'a library file is not read: its package decides what it holds' {
            $root = New-VmfWebFixture @{
                'src/dashboard/lib.min.js'          = 'x.innerHTML = ''<a onclick="go()">x</a>'';'
                'docs/manual/vendor/docsify.js'     = 'x.innerHTML = ''<a onclick="go()">x</a>'';'
            }
            @(Find-VmfInlineScript -Root $root).Count | Should -Be 0
        }

        It 'a javascript: address in a page or in markup a script builds' {
            $root = New-VmfWebFixture @{ 'src/dashboard/page.html' = '<a href="javascript:go()">x</a>' }
            @(Find-VmfInlineScript -Root $root | Where-Object kind -eq 'javascript address').Count | Should -Be 1
            $root = New-VmfWebFixture @{ 'src/dashboard/page.js' = 'a.innerHTML = `<a href="javascript:void(0)">x</a>`;' }
            @(Find-VmfInlineScript -Root $root | Where-Object kind -eq 'javascript address').Count | Should -Be 1
        }
    }

    Context 'each policy that allows inline script is found' {

        It 'unsafe-inline, unsafe-hashes, unsafe-eval or a host in script-src' {
            foreach ($tokens in @("'self' 'unsafe-inline'", "'self' 'unsafe-hashes'", "'self' 'unsafe-eval'", "'self' https:", "'self' *", "'self' 'nonce-abc'", "'self' data:")) {
                $policy = @{ 'script-src' = @($tokens -split ' ') }
                @(Find-VmfScriptPolicyGaps -Policy $policy).Count | Should -BeGreaterThan 0 -Because $tokens
            }
        }

        It 'unsafe-inline in script-src-elem, script-src-attr or default-src' {
            foreach ($directive in 'script-src-elem', 'script-src-attr', 'default-src') {
                $policy = @{ 'script-src' = @("'self'"); $directive = @("'self'", "'unsafe-inline'") }
                @(Find-VmfScriptPolicyGaps -Policy $policy).Count | Should -Be 1 -Because $directive
            }
        }

        It 'no script-src at all' {
            @(Find-VmfScriptPolicyGaps -Policy @{ 'default-src' = @("'self'") }).Count | Should -Be 1
        }

        It 'the site alone, or the site and a hash, is allowed' {
            @(Find-VmfScriptPolicyGaps -Policy @{ 'script-src' = @("'self'") }).Count | Should -Be 0
            @(Find-VmfScriptPolicyGaps -Policy @{ 'script-src' = @("'self'", "'sha256-AbC+/9xyz='") }).Count | Should -Be 0
        }

        It 'reads the policy from web.config as directive and tokens' {
            $root = New-VmfWebFixture @{ 'src/dashboard/web.config' = '<add name="Content-Security-Policy" value="default-src ''self''; script-src ''self'' ''unsafe-inline''; style-src ''self''" />' }
            $policy = Get-VmfPolicy -Root $root
            $policy['script-src'] | Should -Be @("'self'", "'unsafe-inline'")
            @(Find-VmfScriptPolicyGaps -Policy $policy) | Should -Be @("script-src 'unsafe-inline'")
        }
    }
}
