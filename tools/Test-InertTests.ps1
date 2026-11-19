<#
.SYNOPSIS
    Find tests that CANNOT FAIL - the ones that pass on nothing.

.DESCRIPTION
    INERT-1. The standing position here is that the tests are the trust
    mechanism. A test that cannot fail is worse than no test, because it looks
    like coverage and nobody goes back to it.

    Four turned up on 2026-09-02, every one by accident:

      1. A `\b` in a pattern had become a literal backspace (0x08), so the
         regex matched nothing and `Should -BeNullOrEmpty` passed on the empty
         result. THREE separate files, one of them guarding a defect that
         had already been reported.
      2. An `It` read a variable assigned in a DIFFERENT `It`. Pester scopes
         each `It`, so it was $null, and `[regex]::Matches($null, ...)` returns
         nothing - which passed.
      3. A rule matched SOURCE TEXT, so commenting out the code it guarded
         still satisfied it.
      4. A per-page precondition went permanently false when DARK-1 moved the
         CSS into one stylesheet. Every page was skipped, the loop body never
         ran, and the rule stopped applying without failing.

    THIS TOOL FINDS (1) AND (4). It does not find (2) or (3), and that is a
    decision rather than an omission.

    (2) was attempted four times. Each version was defeated by a different
    Pester mechanism that injects a variable without an assignment in the body:
    `$script:` in a BeforeAll, `InModuleScope -Parameters @{ p = ... }`,
    `-ForEach` and `-TestCases` data, mock parameter binding. The best version
    still reported 57 findings, and every one sampled was false. A check that
    cries wolf is the thing this tool exists to diagnose - people learn to skip
    it - so the rule was removed rather than shipped noisy.

    (2) and (3) are found by MUTATION TESTING: break the thing the rule
    guards, and see whether anything notices. That is how all four were found
    in the first place, and it is the honest limit of reading source.

    A THIRD RULE WAS BUILT AND REMOVED, like the second: "a UX string declared
    and never used", the same defect as an unused CSS token. It works, and it
    found real dead strings - but a UX object can be read by index
    (UX_STATE[e.step]), enumerated (Object.entries(UX_FILTER)), or spread, and
    none of those name a key. Two exemptions were written and a third case
    appeared immediately. It also surfaced about sixty candidates across five
    pages, which is a cleanup of its own rather than a gate to bolt on mid-
    change. Logged as STRING-SWEEP-1.

    EVERY RULE THAT REMAINS IS PRECISE. Both have found real defects, and
    neither has produced a false positive.

.NOTES
    Exit code 1 when anything is found, so CI can gate on it.
#>
[CmdletBinding()]
param(
    [Parameter()][string[]]$Path = @((Join-Path $PSScriptRoot '..' 'tests'),
                                    (Join-Path $PSScriptRoot '..' 'src' 'dashboard')),
    [Parameter()][string]$SourceRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
# CSP-INLINE-1: a page is read with its own script put back inline.
. (Join-Path $PSScriptRoot '..' 'tests' 'unit' '_PageSource.ps1')
$findings = [System.Collections.Generic.List[object]]::new()
$root = (Resolve-Path $SourceRoot).Path

# CSP-INLINE-1: *.js too. A page's script left its .html for a .js file, and a
# pattern in it is a pattern all the same.
foreach ($file in @($Path | ForEach-Object { Get-ChildItem $_ -Recurse -Include '*.ps1', '*.html', '*.js' } | Where-Object { $_.Name -notlike '*.min.js' })) {
    # An array always: a file of one line is otherwise one string, and indexing
    # it walks its characters.
    $lines = @(Get-Content $file.FullName)
    $text = $lines -join "`n"
    $rel = $file.FullName.Replace($root, '').TrimStart('\', '/')

    # ---- 1. control characters in a pattern -----------------------------
    # A regex escape that lost its backslash becomes the character itself:
    # \b -> 0x08, \f -> 0x0C, \v -> 0x0B. None of them ever match source, so
    # the rule silently stops applying and the test keeps passing.
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $bad = $lines[$i].ToCharArray() | Where-Object { [int]$_ -lt 32 -and $_ -ne "`t" }
        if ($bad) {
            $names = ($bad | ForEach-Object { '0x{0:x2}' -f [int]$_ }) -join ' '
            $findings.Add([pscustomobject]@{
                Rule = 'control-char'; Where = "${rel}:$($i + 1)"
                Detail = "a regex escape lost its backslash and is a literal control character now ($names) - this pattern matches nothing"
            })
        }
    }

    # ---- 2. a precondition that currently skips EVERY case --------------
    # `if (...) { continue }` scopes a rule to the cases it applies to. When
    # the condition goes permanently true the loop body stops running and the
    # test passes on an empty result - which is what DARK-1 did to the card
    # padding rule by moving the CSS out of the pages.
    #
    # Reported only when it excludes everything TODAY. A precondition that
    # still selects some files is doing its job.
    foreach ($m in [regex]::Matches($text, '(?m)^\s*if \(\$text -notmatch ''(?<pat>[^'']+)''\) \{ continue \}')) {
        $pat = $m.Groups['pat'].Value
        # Only when the loop is over the DASHBOARD PAGES. StorePath.Tests uses
        # the same shape over *.ps1 files, and judging that against the pages
        # made this rule cry wolf on its very first run - which is the fault it
        # exists to find.
        # 1600, not 400: the loop declaration can be a long comment away from
        # the precondition, and a window too small made THIS RULE inert - which
        # mutation-testing it caught, and reading it never would have.
        $before = $text.Substring([math]::Max(0, $m.Index - 1600), [math]::Min(1600, $m.Index))
        if ($before -notmatch '\$script:pages|\*\.html|Filter ''\*\.html''') { continue }
        $dash = Join-Path $root 'src' 'dashboard'
        if (-not (Test-Path $dash)) { continue }
        $matching = @(Get-ChildItem $dash -Filter '*.html' | Where-Object {
            (Get-VmfPageSource -Path $_.FullName) -match $pat
        })
        if ($matching.Count -eq 0) {
            $findings.Add([pscustomobject]@{
                Rule = 'dead-precondition'; Where = $rel
                Detail = "skips every page unless it matches '$pat', and NO page matches it now - the loop body never runs and this rule no longer applies to anything"
            })
        }
    }
}

if ($findings.Count) {
    Write-Host "INERT TESTS: $($findings.Count) finding(s)" -ForegroundColor Red
    foreach ($f in $findings) {
        Write-Host ("  [{0}] {1}" -f $f.Rule, $f.Where) -ForegroundColor Yellow
        Write-Host ("      {0}" -f $f.Detail)
    }
}
else {
    Write-Host 'No inert tests found by reading. Mutation testing is still the only way to find the rest.' -ForegroundColor Green
}

[pscustomobject]@{ Count = $findings.Count; Findings = $findings }
if ($findings.Count) { exit 1 }
