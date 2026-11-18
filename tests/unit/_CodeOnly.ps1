# COMMENT-TRAP-1: a file's CODE, with its comments removed.
#
# THE TRAP, four times on 2026-09-10 and 2026-09-11. Many checks here read a
# whole file and assert that a string is present or absent:
#
#   $publish | Should -Not -Match 'az storage blob upload'
#
# The file still SAYS that string - in a comment, explaining the call that was
# removed and why. That history is worth keeping, and it is indistinguishable
# from the call itself to anything that matches on the raw text. So the check
# passes or fails for the wrong reason, and nobody can tell which.
#
# It bit twice in STORE-READ-1 (both times a `Should -Not -Match` that could
# never fail), once in NSP-3, and ONCE MORE IN THE FIX FOR IT. That fix dropped
# lines beginning with a comment marker, and a mutation walked straight past:
#
#   $started = $null # az containerapp job start
#
# A TRAILING comment on a line of code - which is exactly the form somebody
# writes when they disable something, and exactly the form a line-based strip
# keeps. Nine test files carried that strip.
#
# So this is one helper, and it does not guess:
#
#   * PowerShell goes through the PARSER. It tokenises the file and says which
#     spans are comments, so a '#' inside a string stays and a comment anywhere
#     goes.
#   * JavaScript, bicep and shell go through a scanner that tracks string
#     state, because there is no parser for them here. It is tested against the
#     cases that matter, including a trailing comment and a marker inside a
#     string.
#
# THREE LANGUAGES, NOT TWO. The first version of this helper sent .sh files to
# the C-style scanner, which looks for // and finds nothing in a bash file - so
# mana-check.sh kept every one of its comments and a guest-contract check
# started failing on an explanation. Caught by the suite, not by reading.
#
# Dot-sourced, not named *.Tests.ps1, so Pester does not discover it - the same
# arrangement as _AzureGuard.ps1. `CodeOnly.Tests.ps1` tests THIS FILE, because
# a check that reads code-with-comments-removed is only ever as good as the
# removal.

. (Join-Path $PSScriptRoot '_PageSource.ps1')

function Get-VmfCodeOnly {
    <#
    .SYNOPSIS
        The text of a file with its comments removed, exactly.
    .PARAMETER Path
        The file to read. Its extension chooses the language unless -Language
        says otherwise.
    .PARAMETER Text
        The text to strip, when it did not come from a file.
    .PARAMETER Language
        'PowerShell', 'CStyle' or 'Shell'. CStyle covers JavaScript, bicep and
        HTML script blocks - anything using // and /* */. Shell covers .sh,
        where a comment is # to the end of the line.
    .OUTPUTS
        [string]. A comment is replaced by a single space, never deleted
        outright, so removing one cannot join two tokens into a third.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(ParameterSetName = 'Path', Mandatory)][string]$Path,
        [Parameter(ParameterSetName = 'Text', Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter()][ValidateSet('PowerShell', 'CStyle', 'Shell')][string]$Language
    )

    if ($PSCmdlet.ParameterSetName -eq 'Path') {
        # CSP-INLINE-1: a page's code includes its own script, which now lives
        # in a file with the page's name (_PageSource.ps1).
        $Text = Get-VmfPageSource -Path $Path
        if (-not $Language) {
            $Language = switch ([System.IO.Path]::GetExtension($Path)) {
                '.ps1'  { 'PowerShell' }
                '.psm1' { 'PowerShell' }
                '.psd1' { 'PowerShell' }
                '.sh'   { 'Shell' }
                '.bash' { 'Shell' }
                default { 'CStyle' }
            }
        }
    }
    if (-not $Language) { $Language = 'CStyle' }
    if ([string]::IsNullOrEmpty($Text)) { return '' }

    if ($Language -eq 'PowerShell') {
        # THE PARSER, not a pattern. It knows a '#' inside a string from one
        # that starts a comment, and it finds block comments too.
        $tokens = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$null)
        $out = $Text
        # Back to front, so removing one span does not move the next one.
        $comments = @($tokens | Where-Object { $_.Kind -eq 'Comment' }) |
            Sort-Object { $_.Extent.StartOffset } -Descending
        foreach ($t in $comments) {
            $start = $t.Extent.StartOffset
            $length = $t.Extent.EndOffset - $start
            $out = $out.Remove($start, $length).Insert($start, ' ')
        }
        return $out
    }

    # CStyle and Shell. No parser is available for these here, so this tracks
    # the two things a pattern cannot: whether the marker is inside a string,
    # and whether a slash opens a regular expression rather than a comment.
    #
    # CODEONLY-2, 2026-09-11. This used to state, as a KNOWN LIMIT, that a
    # regex literal containing a comment marker was not understood, and that
    # "no file in this repository has one". BOTH HALVES WERE WRONG.
    #
    # The limit was wider than stated: a regex containing a QUOTE desyncs the
    # scanner just as badly as one containing a slash, because the quote opens
    # a string that never closes. And the dashboard's own HTML escaper is
    # exactly that:
    #
    #     const esc = (v) => String(v ?? '').replace(/[&<>"']/g, ...)
    #
    # From that line on, every comment in assessment-report.js came back
    # UNSTRIPPED - so a test asking "is this call gone?" searched text that
    # still held the comment explaining why it went.
    #
    # The same desync ATE REAL CODE in bicep. identity.bicep's
    #     param dashboardOrigin string = 'https://vmf-dash-...'
    # came back as `'https: ` - the scanner was outside a string when it met
    # the address and read the // as a comment. A `Should -Not -Match` on that
    # address then PASSED while the address sat in the template: a check
    # reporting a result it never measured, which is the defect class this
    # helper exists to prevent.
    #
    # Measured before the fix: 8 of the 11 JavaScript, HTML and bicep files the
    # tests read through here were affected.
    #
    # HANDLED NOW: regex literals (told from division by the token before them,
    # the standard heuristic) and bicep's ''' multi-line strings. Both are KEPT
    # - they are code, not commentary - they simply no longer confuse the
    # scanner about where they end.
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $i = 0
    $n = $Text.Length
    $quote = $null          # the character that opened the current string
    # The last character that was neither whitespace nor comment, and the last
    # complete word. A slash after a VALUE is division (`a / b`); after an
    # operator, an opening bracket, a statement end or one of the keywords
    # below, it opens a regex. This is how a JavaScript tokenizer tells the two
    # apart without parsing, and it is enough here.
    $prevSig = [char]0
    $word = ''
    $lastWord = ''
    # A template literal's ${ ... } holds REAL CODE, and a comment inside it is
    # a real comment. Treating the whole literal as one string left those in -
    # two dashboard pages hide an operator-facing comment inside an
    # interpolation. One entry per open interpolation, holding how many plain
    # braces are still to close before the literal resumes.
    $interpStack = [System.Collections.Generic.List[int]]::new()
    # NOTE the absence of '<'. A JavaScript tokenizer lists it - `a < /re/` is
    # legal - but these files are HTML with script inside, and every closing
    # tag is `</`. Treating that as the start of a regex ate the rest of the
    # line and desynced three pages that had been fine. '>' STAYS, because an
    # arrow function before a regex (`x => /re/.test(y)`) is everyday code.
    $regexBefore = @('(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';',
                     '+', '-', '*', '%', '>', '~', '^', "`n")
    $regexKeywords = @('return', 'typeof', 'case', 'in', 'of', 'do', 'else',
                       'yield', 'await', 'delete', 'void', 'instanceof', 'new')
    while ($i -lt $n) {
        $c = $Text[$i]
        $next = if ($i + 1 -lt $n) { $Text[$i + 1] } else { [char]0 }

        if ($quote) {
            [void]$sb.Append($c)
            if ($c -eq '\') {
                # an escape takes the next character with it, whatever it is
                if ($i + 1 -lt $n) { [void]$sb.Append($next); $i += 2; continue }
            }
            elseif ($quote -eq '`' -and $c -eq '$' -and $next -eq '{') {
                # back to CODE until the matching brace
                [void]$sb.Append($next)
                $interpStack.Add(0)
                $quote = $null
                $prevSig = '{'
                $i += 2
                continue
            }
            elseif ($c -eq $quote) { $quote = $null; $prevSig = $c }
            $i++
            continue
        }

        # An HTML COMMENT. These files are pages, not scripts: the dashboard's
        # own banner comment is <!-- ... --> and runs to 60 lines. Nothing
        # handled it, so the apostrophe in "the viewer's own identity" opened a
        # string that never closed, and every // below it survived. Same defect
        # as the regex one, different marker.
        if ($Language -eq 'CStyle' -and $c -eq '<' -and ($i + 3) -lt $n -and
            $Text[$i + 1] -eq '!' -and $Text[$i + 2] -eq '-' -and $Text[$i + 3] -eq '-') {
            [void]$sb.Append(' ')
            $i += 4
            while ($i -lt $n) {
                if ($Text[$i] -eq '-' -and ($i + 2) -lt $n -and
                    $Text[$i + 1] -eq '-' -and $Text[$i + 2] -eq '>') { $i += 3; break }
                # newlines are kept, so line numbers downstream do not shift
                if ($Text[$i] -eq "`n") { [void]$sb.Append("`n") }
                $i++
            }
            continue
        }

        # Bicep's multi-line string. JavaScript cannot contain ''' - that would
        # be an empty string followed by an unterminated one - so three single
        # quotes are unambiguous. identity.bicep is full of them in its
        # @description blocks, and read as three separate quotes they leave the
        # scanner inside a string: the bicep half of the defect above.
        if ($Language -eq 'CStyle' -and $c -eq "'" -and $next -eq "'" -and
            ($i + 2) -lt $n -and $Text[$i + 2] -eq "'") {
            [void]$sb.Append("'''")
            $i += 3
            while ($i -lt $n) {
                if ($Text[$i] -eq "'" -and ($i + 2) -lt $n -and
                    $Text[$i + 1] -eq "'" -and $Text[$i + 2] -eq "'") {
                    [void]$sb.Append("'''")
                    $i += 3
                    break
                }
                [void]$sb.Append($Text[$i])
                $i++
            }
            $prevSig = "'"
            $lastWord = ''
            continue
        }

        # A backtick is a template literal in JavaScript and command
        # substitution in shell, so it opens a string only in CStyle.
        if ($c -eq '"' -or $c -eq "'" -or ($c -eq '`' -and $Language -eq 'CStyle')) {
            $quote = $c
            [void]$sb.Append($c)
            $i++
            continue
        }

        if ($Language -eq 'Shell' -and $c -eq '#') {
            # In shell a hash begins a comment only at the start of a word, so
            # `echo a#b` keeps its hash and `#!/bin/bash` loses its line. The
            # shebang is a comment to the interpreter too; nothing here asserts
            # on it, and the guest scripts' own shebang rule is tested where it
            # belongs.
            $prev = if ($i -gt 0) { $Text[$i - 1] } else { [char]0 }
            if ($i -eq 0 -or $prev -eq ' ' -or $prev -eq "`t" -or $prev -eq "`n" -or $prev -eq "`r" -or
                $prev -eq ';' -or $prev -eq '(' -or $prev -eq '&') {
                [void]$sb.Append(' ')
                while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
                continue
            }
        }

        if ($Language -eq 'CStyle' -and $c -eq '/' -and $next -eq '/') {
            # to the end of the line, and the newline is KEPT: line numbers and
            # line-based matching downstream must not shift.
            [void]$sb.Append(' ')
            while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
            continue
        }

        if ($Language -eq 'CStyle' -and $c -eq '/' -and $next -eq '*') {
            [void]$sb.Append(' ')
            $i += 2
            while ($i -lt $n) {
                if ($Text[$i] -eq '*' -and ($i + 1 -lt $n) -and $Text[$i + 1] -eq '/') { $i += 2; break }
                # newlines inside a block comment are kept, for the same reason
                if ($Text[$i] -eq "`n") { [void]$sb.Append("`n") }
                $i++
            }
            continue
        }

        # A REGULAR EXPRESSION, kept whole. Checked AFTER the two comment
        # branches, so // and /* still win - a regex can begin with neither.
        $wordish = [string]$prevSig -cmatch '[A-Za-z0-9_$]'
        if ($Language -eq 'CStyle' -and $c -eq '/' -and
            ($prevSig -eq [char]0 -or $regexBefore -contains [string]$prevSig -or
             ($wordish -and $regexKeywords -contains $lastWord))) {
            [void]$sb.Append($c)
            $i++
            $inClass = $false
            while ($i -lt $n) {
                $rc = $Text[$i]
                # A newline means this was division after all, not a literal.
                if ($rc -eq "`n") { break }
                [void]$sb.Append($rc)
                if ($rc -eq '\' -and ($i + 1) -lt $n) { [void]$sb.Append($Text[$i + 1]); $i += 2; continue }
                # a slash inside [ ... ] does not end the literal
                if ($rc -eq '[') { $inClass = $true }
                elseif ($rc -eq ']') { $inClass = $false }
                elseif ($rc -eq '/' -and -not $inClass) { $i++; break }
                $i++
            }
            while ($i -lt $n -and [string]$Text[$i] -cmatch '[a-z]') { [void]$sb.Append($Text[$i]); $i++ }
            # a completed regex is a VALUE, so a slash after it is division
            $prevSig = ')'
            $word = ''
            $lastWord = ''
            continue
        }

        # Inside an interpolation, count braces so the literal resumes at the
        # RIGHT one - `${ a ? {x:1} : {} }` closes three and resumes on the
        # last.
        if ($interpStack.Count -gt 0 -and $c -eq '{') {
            $interpStack[$interpStack.Count - 1] = $interpStack[$interpStack.Count - 1] + 1
        }
        elseif ($interpStack.Count -gt 0 -and $c -eq '}') {
            if ($interpStack[$interpStack.Count - 1] -eq 0) {
                $interpStack.RemoveAt($interpStack.Count - 1)
                [void]$sb.Append($c)
                $quote = '`'
                $prevSig = '}'
                $word = ''
                $i++
                continue
            }
            $interpStack[$interpStack.Count - 1] = $interpStack[$interpStack.Count - 1] - 1
        }

        [void]$sb.Append($c)
        if ([string]$c -cmatch '[A-Za-z0-9_$]') {
            $word += $c
        }
        else {
            if ($word) { $lastWord = $word }
            $word = ''
        }
        # Spaces and tabs do NOT count: `a = /re/` must still see the `=`. A
        # NEWLINE does, because it ends a statement and a slash on the next
        # line cannot be dividing by anything.
        if ($c -eq "`n") { $prevSig = "`n" }
        elseif (-not [char]::IsWhiteSpace($c)) { $prevSig = $c }
        $i++
    }
    return $sb.ToString()
}
