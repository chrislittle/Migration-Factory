#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CSP-INLINE-1: tools/Test-InertTests.ps1 still sees a page's script after it
# moved out of the page.
#
# The gate's two rules both read the dashboard pages: a regex that lost its
# backslash (a control character in a pattern), and a per-page precondition
# that no page meets any more. Until 2026-11-03 each page's script was inside
# the page, so reading *.html was reading the script. Now each page's script is
# a file with the page's name (wizard.html loads wizard.js), so the first rule
# reads *.js too, and the second reads a page with its own script put back
# (_PageSource.ps1).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:tool = Join-Path $script:repoRoot 'tools' 'Test-InertTests.ps1'
    $script:fixtures = [System.Collections.Generic.List[string]]::new()

    function script:New-VmfInertFixture([hashtable]$Files) {
        $root = Join-Path ([System.IO.Path]::GetTempPath()) ('vmf-inert-' + [guid]::NewGuid().ToString('n'))
        foreach ($k in $Files.Keys) {
            $file = Join-Path $root $k
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $file)
            [System.IO.File]::WriteAllText($file, $Files[$k])
        }
        $script:fixtures.Add($root)
        $root
    }
    function script:Invoke-VmfInertGate([string]$Root) {
        $r = & $script:tool -Path (Join-Path $Root 'tests'), (Join-Path $Root 'src' 'dashboard') -SourceRoot $Root 6>$null
        @($r)[-1]
    }

    # A test file with a per-page precondition on a pattern. Built from parts,
    # so this file does not itself hold the shape the gate looks for: the gate
    # reads this repository's tests too.
    function script:New-VmfPreconditionTest([string]$Pattern) {
        $guard = 'if (' + '$text -notmatch ''' + $Pattern + ''') { continue }'
        @(
            "Describe 'x' {",
            "    It 'every page' {",
            '        foreach ($page in $script:pages) {',
            '            $text = $page.Text',
            "            $guard",
            '            $text | Should -Match ''x''',
            '        }',
            '    }',
            '}'
        ) -join "`n"
    }
}

AfterAll {
    foreach ($f in $script:fixtures) { Remove-Item -LiteralPath $f -Recurse -Force -ErrorAction SilentlyContinue }
}

Describe 'CSP-INLINE-1: the inert-test gate reads a page''s own script file' {

    It 'a control character in a page''s script file is a finding' {
        $root = New-VmfInertFixture @{
            'tests/unit/a.Tests.ps1'  = "Describe 'a' { It 'b' { 1 | Should -Be 1 } }"
            'src/dashboard/page.html' = '<html><body><script src="page.js"></script></body></html>'
            'src/dashboard/page.js'   = 'const re = /a' + [char]8 + "b/;`n"
        }
        $r = Invoke-VmfInertGate -Root $root
        @($r.Findings | Where-Object { $_.Rule -eq 'control-char' -and $_.Where -match 'page\.js' }).Count | Should -Be 1
    }

    It 'a library file is not read: its package decides what it holds' {
        $root = New-VmfInertFixture @{
            'tests/unit/a.Tests.ps1'   = "Describe 'a' { It 'b' { 1 | Should -Be 1 } }"
            'src/dashboard/lib.min.js' = 'var re = /a' + [char]8 + 'b/;'
        }
        @((Invoke-VmfInertGate -Root $root).Findings).Count | Should -Be 0
    }

    It 'the precondition fixture really has the shape the gate looks for' {
        (New-VmfPreconditionTest 'abc') | Should -Match "(?m)^\s*if \(\`$text -notmatch 'abc'\) \{ continue \}"
    }

    It 'a precondition that only a page''s own script meets is not dead' {
        $root = New-VmfInertFixture @{
            'tests/unit/a.Tests.ps1'  = (New-VmfPreconditionTest 'vmfOnlyInTheScript')
            'src/dashboard/page.html' = '<html><body><script src="page.js"></script></body></html>'
            'src/dashboard/page.js'   = "const marker = 'vmfOnlyInTheScript';`n"
        }
        @((Invoke-VmfInertGate -Root $root).Findings | Where-Object Rule -eq 'dead-precondition').Count | Should -Be 0
    }

    It 'and one that no page and no page script meets is still dead' {
        $root = New-VmfInertFixture @{
            'tests/unit/a.Tests.ps1'  = (New-VmfPreconditionTest 'vmfNowhereAtAll')
            'src/dashboard/page.html' = '<html><body><script src="page.js"></script></body></html>'
            'src/dashboard/page.js'   = "const marker = 'vmfOnlyInTheScript';`n"
        }
        @((Invoke-VmfInertGate -Root $root).Findings | Where-Object Rule -eq 'dead-precondition').Count | Should -Be 1
    }
}
