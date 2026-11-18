#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# UI-PARSE-1: the dashboard's JavaScript must actually parse.
#
# This exists because a single unbalanced parenthesis in DIAG-1 took the WHOLE
# page down - no runs, no rows, no navigation, nothing - and every one of the
# 725 tests passed, because they are all string and regex checks against the
# HTML. A file full of the right substrings can still be a syntax error.
#
# It was caught only because the browser was opened by hand. Trusting the suite
# would have shipped a dead dashboard to a customer, and the failure mode is the
# worst kind: not a wrong number on a screen, but no screen.
#
# So: extract every <script> block and hand it to a real JavaScript parser.
# DISCOVERY time, not run time. -ForEach is expanded while Pester builds the
# test tree, so a list produced in BeforeAll is still empty when it is read -
# and the file then reports "passed" having generated NO per-page tests at all.
# That happened here, which is the same silent-hole shape this file exists for.
BeforeDiscovery {
    $script:pages = @(Get-ChildItem (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard') -Filter '*.html')
}

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:node = (Get-Command node -ErrorAction SilentlyContinue)?.Source
    # Discovery and run are separate scopes, so the list has to exist in both:
    # BeforeDiscovery feeds -ForEach, this feeds the assertions below.
    $script:pages = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.html')
}

Describe 'UI-PARSE-1: every dashboard page is valid JavaScript' {
    It 'found the pages' {
        @($script:pages).Count | Should -BeGreaterThan 2
    }

    It 'and generated one test per page, not zero' {
        # The count is asserted from inside a generated test, so a -ForEach that
        # expanded to nothing cannot report success.
        @($script:pages | ForEach-Object { $_.Name }) | Should -Contain 'index.html'
        @($script:pages | ForEach-Object { $_.Name }) | Should -Contain 'migrations.html'
    }

    It 'a JavaScript parser is available to check them with' {
        # Not skipped when node is missing. A guard that quietly does not run is
        # the shape of problem this whole file exists to stop - and node is
        # present on the GitHub Windows runners CI uses.
        $script:node | Should -Not -BeNullOrEmpty -Because 'node is needed to parse the dashboard, and it ships with the CI runner image'
    }

    It '<_.Name> parses' -ForEach $script:pages {
        $page = $_
        $html = (Get-VmfPageSource -Path $page.FullName)

        # Only inline scripts. A src= reference is a separate file and would be
        # checked on its own.
        $blocks = @([regex]::Matches($html, '(?is)<script(?![^>]*\bsrc=)[^>]*>(.*?)</script>') |
            ForEach-Object { $_.Groups[1].Value })
        @($blocks).Count | Should -BeGreaterThan 0 -Because "$($page.Name) should contain inline script"

        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-parse-$([guid]::NewGuid().ToString('N').Substring(0,8)).mjs"
        try {
            # Joined and parsed as a MODULE: top-level await is legal in the
            # page's scripts, and script-mode parsing would reject it and report
            # a syntax error that is not one.
            ($blocks -join "`n;`n") | Set-Content $tmp -Encoding utf8
            $out = & $script:node --check $tmp 2>&1
            $code = $LASTEXITCODE
            if ($code -ne 0) {
                # Report what the parser said, and where. "It does not parse" is
                # not actionable; "Unexpected token ')' at line N" is.
                $detail = (@($out) -join "`n")
                throw "$($page.Name) does not parse:`n$detail"
            }
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'UI-PARSE-1: and the shared script files, which no page inlines' {
    # THE GAP, found 2026-09-02: the page check above deliberately skips
    # `src=` references, saying they "would be checked on its own" - and
    # nothing checked them. help.js and assessment-report.js are loaded by
    # EVERY page, so a syntax error in one takes the whole product down, and it
    # would have shipped: a broken help.js passed the entire suite that day
    # because only `node --check` on the file itself could see it.
    # A plain variable, not $script: - BeforeDiscovery runs in the DISCOVERY
    # phase and -ForEach is evaluated there, while an It body runs later in the
    # RUN phase. Reading the same $script: name in both is how a list of two
    # arrives as a list of one.
    BeforeDiscovery {
        $sharedJs = @(Get-ChildItem (Join-Path ([System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard') -Filter '*.js' |
            Where-Object { $_.Name -ne 'msal-browser.min.js' })
    }

    It 'found the shared files' {
        $found = @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.js' |
            Where-Object { $_.Name -ne 'msal-browser.min.js' })
        @($found).Count | Should -BeGreaterThan 1 -Because 'help.js and assessment-report.js at least'
    }

    It '<_.Name> parses' -ForEach $sharedJs {
        $file = $_
        $node = (Get-Command node -ErrorAction SilentlyContinue).Source
        $node | Should -Not -BeNullOrEmpty
        $out = & $node --check $file.FullName 2>&1
        $LASTEXITCODE | Should -Be 0 -Because "$($file.Name) is loaded by every page: `n$out"
    }
}

Describe 'UI-PARSE-1: the check itself works' {
    It 'rejects a page whose script is broken - or it proves nothing' {
        # Guard the guard, the same way STATE-3's validator does. If node
        # --check accepted anything, every test above would pass vacuously.
        $script:node | Should -Not -BeNullOrEmpty
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-parse-bad-$([guid]::NewGuid().ToString('N').Substring(0,8)).mjs"
        try {
            # The exact shape of the DIAG-1 defect: one paren too many.
            "const a = ('x' ? 'y' : 'z'));" | Set-Content $tmp -Encoding utf8
            & $script:node --check $tmp 2>&1 | Out-Null
            $LASTEXITCODE | Should -Not -Be 0 -Because 'this is a syntax error and the checker must say so'
        }
        finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'WAVES-API-1: no page calls a function that nobody declares' {
    # The wave editor called `api(...)`, a helper of three OTHER pages. The page
    # parsed, so the check above passed; the boot test ran it in demo mode, where
    # the call sat behind `if (!DEMO_MODE)`. On a real install the editor showed
    # "api is not defined" and nothing else. tests/js/_page-calls.js reads every
    # page's scripts with a real parser and names each bare call that resolves
    # to nothing.
    BeforeDiscovery {
        $callPages = @(Get-ChildItem (Join-Path ([System.IO.Path]::GetFullPath(
            (Join-Path $PSScriptRoot '..' '..'))) 'src' 'dashboard') -Filter '*.html')
    }

    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        $script:callCheck = Join-Path $script:repoRoot 'tests' 'js' '_page-calls.js'

        function script:Get-VmfPageCallFindings([string]$Page) {
            $out = & $script:node --expose-internals $script:callCheck $Page 2>&1
            $text = (@($out) -join "`n")
            if ($LASTEXITCODE -gt 1) { throw "the call check did not run for ${Page}:`n$text" }
            $parsed = $text | ConvertFrom-Json -AsHashtable
            return @($parsed[$Page])
        }
        function script:Get-VmfSnippetCallFindings([string[]]$Code) {
            $tmp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-calls-$([guid]::NewGuid().ToString('N').Substring(0,8)).json"
            try {
                $i = 0
                $sources = @($Code | ForEach-Object { $i++; @{ file = "snippet-$i.js"; code = $_ } })
                ConvertTo-Json -InputObject $sources -Depth 4 | Set-Content $tmp -Encoding utf8
                $out = & $script:node --expose-internals $script:callCheck --sources $tmp 2>&1
                if ($LASTEXITCODE -ne 0) { throw "the call check did not run:`n$(@($out) -join "`n")" }
                return @((@($out) -join "`n") | ConvertFrom-Json | ForEach-Object { $_.name })
            }
            finally { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }

    It '<_.Name> calls no function that the page or a script it loads does not declare' -ForEach $callPages {
        # No known findings: the first run found two (WAVES-API-1 and
        # SKIP-ONE-RUNBODY-1), and both were fixed together.
        $page = $_.Name
        $new = @(Get-VmfPageCallFindings $page |
            ForEach-Object { "$($_.name) at $($_.file) line $($_.line)" })
        $new | Should -BeNullOrEmpty -Because "a call to a name nobody declares throws when it runs: $($new -join '; ')"
    }


    It 'the check finds the call the wave editor made, or it proves nothing' {
        @(Get-VmfSnippetCallFindings @("async function start() { await api('GET', 'scopes'); }")) | Should -Be @('api')
    }

    It 'the check finds a call to a function that is declared only inside another function' {
        @(Get-VmfSnippetCallFindings @('function outer() { function inner() {} inner(); }', 'inner();')) | Should -Be @('inner')
    }

    It 'the check finds new and a tagged template on an undeclared name' {
        $found = @(Get-VmfSnippetCallFindings @('const a = new Missing(); const b = tagged`x`;'))
        $found | Should -Contain 'Missing'
        $found | Should -Contain 'tagged'
    }

    It 'the check accepts a name declared in another script of the page, on the window, or in scope' {
        $code = @(
            'function apiGet(p) { return p; } apiPost(1); helperOnWindow(); sharedConst();',
            'const sharedConst = () => 1; async function apiPost(p, b) { return apiGet(p); } window.helperOnWindow = () => 1;',
            'function f(cb, { pick }, [first], ...rest) { cb(); pick(); first(); rest(); const local = () => 1; local(); hoisted(); { var hoisted = () => 1; } }',
            'try { apiGet(); } catch (fail) { fail(); }',
            'for (const step of []) { step(); } const named = function self() { self(); };',
            'class Thing { go() { return new Thing(); } } setTimeout(() => {}, 1); fetch("x"); String(1); new URL("https://example.com");',
            'const s = "api()"; /* api() */ obj.api(); obj["api"]();'
        )
        @(Get-VmfSnippetCallFindings $code) | Should -BeNullOrEmpty
    }
}
