#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# INTERPOLATED-PATTERN-1, 2026-09-21. The cause of FLAKY-STOP-1, found the
# first time a failure was allowed to say why.
#
# A check in StopReasons.Tests.ps1 built its regular expression as a
# DOUBLE-QUOTED PowerShell string, and wrote the literal dollar the regex
# needed as `\$doc`:
#
#     "... (?=\r?\n\s*(break|\}|\$doc|Write-Vmf))"
#
# THE ESCAPE CHARACTER IN A DOUBLE-QUOTED STRING IS A BACKTICK, NOT A
# BACKSLASH. So that is a backslash followed by an INTERPOLATION of $doc, and
# whatever $doc happened to hold was spliced into the pattern.
#
# Nine test files assign $doc. Pester keeps them reachable, so the pattern
# depended on which files had run before and what they had left behind:
#
#   $doc empty      -> the alternative silently matched nothing, and the check
#                      passed for a reason nobody intended
#   $doc with text  -> Invalid pattern, and the test failed with an exception
#                      about a regular expression rather than about the engine
#
# THREE OF SIX FULL RUNS. It was called intermittent for a day because the
# runner printed only the test's NAME - see SAY-WHY-1.
#
# THE RULE, NOT THE INSTANCE: a regular expression is DATA. It must not be
# built from a string that interpolates, because the thing being escaped and
# the thing doing the escaping belong to two different languages.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))

    # Read with the PARSER. A text search cannot tell a double-quoted string
    # from a single-quoted one, and this whole defect is about which it is.
    $script:suspects = foreach ($file in (Get-ChildItem (Join-Path $script:repoRoot 'tests') -Recurse -Filter *.ps1 -File)) {
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$errors)
        if (@($errors).Count -gt 0) { continue }
        $expandable = $ast.FindAll({ param($n)
            $n -is [System.Management.Automation.Language.ExpandableStringExpressionAst] }, $true)
        foreach ($s in $expandable) {
            if ($s.Extent.Text -match '\\\$') {
                [pscustomobject]@{ File = $file.Name; Line = $s.Extent.StartLineNumber; Text = $s.Extent.Text }
            }
        }
    }

    # The three that are NOT patterns. `function:\` is a PowerShell DRIVE, the
    # backslash is a path separator, and the variable is meant to interpolate.
    # A category, never "looks fine".
    $script:allowed = @('"function:\$fn"', '"function:\$f"')
}

Describe 'INTERPOLATED-PATTERN-1: a backslash-dollar in a double-quoted string' {

    It 'finds the strings to judge, so this cannot pass by reading nothing' {
        # If the walk breaks, every check below passes on an empty list.
        @($script:suspects).Count | Should -BeGreaterThan 0
    }

    It 'every one is a path, not a pattern' {
        $bad = @($script:suspects | Where-Object { $_.Text -notin $script:allowed })
        ($bad | ForEach-Object { "$($_.File):$($_.Line) $($_.Text)" }) -join "`n" |
            Should -BeNullOrEmpty -Because 'in a double-quoted string \$ is a backslash and an INTERPOLATION - write `$ for a literal dollar'
    }

    It 'and the pattern that caused this is fixed' {
        $src = Get-Content (Join-Path $script:repoRoot 'tests' 'unit' 'StopReasons.Tests.ps1') -Raw
        $src | Should -Match 'break\|\\\}\|\\`\$doc\|Write-Vmf' -Because 'the dollar is escaped for PowerShell, so the regex sees a literal one'
    }

    It 'and the pattern compiles whatever is in scope' {
        # THE BEHAVIOUR, not the spelling. Set a $doc that would break a
        # pattern that still interpolated, and build the real one.
        $doc = 'a value (with) |metacharacters| and an unclosed ['
        $pattern = "(?s)Add-VmfStateTransition[^\r\n]*-NewState '(FAILED_NEEDS_ATTENTION|FAILED_ROLLED_BACK)'.{0,400}?(?=\r?\n\s*(break|\}|\`$doc|Write-Vmf))"
        $pattern | Should -Match '\\\$doc' -Because 'the built pattern holds a literal dollar, not the value of $doc'
        { [regex]::Matches('x', $pattern) } | Should -Not -Throw
        # And the trap itself, so this test proves the mechanism rather than
        # asserting it. BUILT THE WAY INTERPOLATION BUILDS IT - a backslash,
        # then the VALUE of $doc - rather than written out as "\$doc", which
        # would put the very defect this file forbids into the file that
        # forbids it. The census above caught exactly that and was right to.
        $old = '(?=\r?\n\s*(break|\}|\' + $doc + '|Write-Vmf))'
        { [regex]::Matches('x', $old) } | Should -Throw -Because 'this is what the check was doing for a day'
    }
}
