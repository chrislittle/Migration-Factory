#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# COMMENT-TRAP-1 - the tests for the thing other tests read code through.
#
# A dozen checks in this suite assert that a file does or does not contain a
# string, having first removed its comments. Every one of them is exactly as
# good as the removal, so the removal gets its own tests - and they are written
# from the four times the trap actually bit, not from imagination.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'COMMENT-TRAP-1: PowerShell comments go, and nothing else does' {

    It 'removes a whole-line comment' {
        $code = Get-VmfCodeOnly -Language PowerShell -Text @'
# az storage blob upload
$kept = 1
'@
        $code | Should -Not -Match 'az storage blob upload'
        $code | Should -Match '\$kept = 1'
    }

    It 'removes a TRAILING comment, which is what the first fix missed' {
        # The mutation that walked past a line-based strip:
        #   $started = $null # az containerapp job start
        # The words were still in the file and the call was gone.
        $code = Get-VmfCodeOnly -Language PowerShell -Text '$started = $null # az containerapp job start'
        $code | Should -Not -Match 'containerapp job start'
        $code | Should -Match '\$started = \$null'
    }

    It 'and a block comment, however many lines it runs to' {
        $code = Get-VmfCodeOnly -Language PowerShell -Text @'
<#
  az storage blob upload
#>
$kept = 2
'@
        $code | Should -Not -Match 'az storage blob upload'
        $code | Should -Match '\$kept = 2'
    }

    It 'KEEPS a hash that is inside a string' {
        # The reason this uses the parser. A pattern cannot tell these apart,
        # and deleting the second one would make a `Should -Not -Match` pass
        # when the code really does say it.
        $code = Get-VmfCodeOnly -Language PowerShell -Text '$url = "https://x/y#frag"   # a comment'
        $code | Should -Match 'y#frag'
        $code | Should -Not -Match 'a comment'
    }

    It 'and does not join two words when it takes a comment out' {
        # A comment replaced by nothing can weld its neighbours into a token
        # that was never in the file - and that token could match.
        $code = Get-VmfCodeOnly -Language PowerShell -Text "az <# x #>storage"
        $code | Should -Not -Match 'azstorage'
    }
}

Describe 'COMMENT-TRAP-1: the same holds for JavaScript and bicep' {

    It 'removes a line comment and a trailing one' {
        $code = Get-VmfCodeOnly -Language CStyle -Text @'
// blob.core.windows.net
const kept = 1;   // blob.core.windows.net
'@
        $code | Should -Not -Match 'blob\.core\.windows\.net'
        $code | Should -Match 'const kept = 1;'
    }

    It 'removes a block comment' {
        $code = Get-VmfCodeOnly -Language CStyle -Text @'
/* storage.azure.com
   more of it */
const kept = 2;
'@
        $code | Should -Not -Match 'storage\.azure\.com'
        $code | Should -Match 'const kept = 2;'
    }

    It 'KEEPS a marker inside every kind of string literal' {
        # A URL in a string is the case that matters: '//' appears in every one
        # of them, and treating it as a comment would delete the rest of the
        # line - silently making a page look like it calls nothing.
        foreach ($q in "'", '"', '`') {
            $code = Get-VmfCodeOnly -Language CStyle -Text "const u = ${q}https://acct.blob.core.windows.net/c${q};"
            $code | Should -Match 'blob\.core\.windows\.net' -Because "a URL in a $q string is not a comment"
            $code | Should -Match 'const u ='
        }
    }

    It 'and an escaped quote does not end the string early' {
        # Without this the scanner leaves the string at the wrong place and
        # reads the rest of the line as code - or as a comment.
        $code = Get-VmfCodeOnly -Language CStyle -Text 'const s = "a \" https://kept.example/x";'
        $code | Should -Match 'kept\.example'
    }

    It 'keeps the line count, so line-based checks downstream still line up' {
        $text = "a" + "`n" + "// gone" + "`n" + "b"
        $code = Get-VmfCodeOnly -Language CStyle -Text $text
        @($code -split "`n").Count | Should -Be 3
        $code | Should -Not -Match 'gone'
    }
}

Describe 'COMMENT-TRAP-1: it reads a file and picks the language from it' {

    It 'a .ps1 goes through the PowerShell parser' {
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-codeonly-$([guid]::NewGuid()).ps1"
        '$x = 1 # az storage blob upload' | Set-Content $probe -Encoding utf8NoBOM
        try {
            (Get-VmfCodeOnly -Path $probe) | Should -Not -Match 'az storage blob upload'
        }
        finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }

    It 'and anything else is read as C-style' {
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-codeonly-$([guid]::NewGuid()).js"
        'const x = 1; // blob.core.windows.net' | Set-Content $probe -Encoding utf8NoBOM
        try {
            (Get-VmfCodeOnly -Path $probe) | Should -Not -Match 'blob\.core\.windows\.net'
        }
        finally { Remove-Item $probe -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'COMMENT-TRAP-1: and the tests that need it use it' {

    It 'no test file strips comments by dropping lines any more' {
        # THE WHOLE POINT. Nine files carried
        #   Where-Object { $_.TrimStart() -notlike '#*' }
        # or its // twin, and every one of them had the trailing-comment hole.
        # A test that reads its own file is exempt: this one names the pattern
        # in order to forbid it.
        $bad = foreach ($f in Get-ChildItem $PSScriptRoot -Filter '*.Tests.ps1' -File) {
            if ($f.Name -eq 'CodeOnly.Tests.ps1') { continue }
            $text = Get-Content $f.FullName -Raw
            if ($text -match "notlike '#\*'" -or $text -match "notmatch '\^.s\*\(//") { $f.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'Get-VmfCodeOnly is the one way, and it is the only correct one'
    }

    It 'CODEONLY-2: a regex literal does not turn the rest of the file into a string' {
        # THE DEFECT. The old scanner had a stated KNOWN LIMIT - a regex
        # containing a comment marker - and claimed "no file in this repository
        # has one". The limit was wider than stated (a QUOTE in a regex is just
        # as bad) and the claim was false: the dashboard's HTML escaper is
        #     String(v ?? '').replace(/[&<>"']/g, ...)
        # From that line on, EVERY comment in assessment-report.js came back
        # unstripped, so a test asking "is this call gone?" searched text that
        # still held the comment explaining why it went.
        $t = @'
const esc = (v) => String(v).replace(/[&<>"']/g, c => c);
var a = 1; // THIS MUST GO
'@
        $code = Get-VmfCodeOnly -Text $t -Language CStyle
        $code | Should -Not -Match 'THIS MUST GO'
        $code | Should -Match '\[&<>' -Because 'the regex is CODE and is kept whole'
    }

    It 'and a slash that is DIVISION is not read as a regex' {
        # The other direction. Reading `a / b` as a literal would swallow to
        # the next slash and lose real code.
        $code = Get-VmfCodeOnly -Text "const r = total / count; // THIS MUST GO`nconst q = a / b / c;" -Language CStyle
        $code | Should -Not -Match 'THIS MUST GO'
        $code | Should -Match 'total / count'
        $code | Should -Match 'a / b / c'

        # THE PIN for stopping at the end of the line. `}` is in the set - it
        # has to be, a regex often follows a block - so `{} / 2` reads as a
        # literal that never closes. Without the guard the scan runs into the
        # NEXT line and eats the comment there. A mutation dropping it passed
        # every other test here.
        $c2 = Get-VmfCodeOnly -Text "const e = {} / 2;`nvar f = 1; // THIS MUST GO" -Language CStyle
        $c2 | Should -Not -Match 'THIS MUST GO'
        $c2 | Should -Match 'const e = \{\} / 2;' -Because 'and the division survives intact'
    }

    It 'and a regex after return, or one holding a slash, is still understood' {
        $code = Get-VmfCodeOnly -Text 'function f(s) { return /a\/\/b/.test(s); } // THIS MUST GO' -Language CStyle
        $code | Should -Not -Match 'THIS MUST GO'
        $code | Should -Match 'test\(s\)' -Because 'the // INSIDE the literal is not a comment'

        # And a slash inside a CHARACTER CLASS does not end the literal either.
        # Without that, the regex below ends early, the quote inside the class
        # is read as opening a string, and everything after it desyncs - the
        # same failure as the escaper, one level down. A mutation removing the
        # class tracking passed every other test here.
        $t2 = "const re = /[/']/; const s = 'x'; // THIS MUST GO"
        $c2 = Get-VmfCodeOnly -Text $t2 -Language CStyle
        $c2 | Should -Not -Match 'THIS MUST GO'
        $c2 | Should -Match "const s = 'x';" -Because 'and the code after it is untouched'

        # THE PIN for the keyword list. After a WORD a slash is division, so a
        # regex can only follow one of a few keywords - and `return /x/` is the
        # everyday one. Without it the quote inside the literal opens a string
        # and everything after desyncs. A mutation dropping `return` passed
        # every other test here.
        $t3 = "function g(s) { return /x'y/.test(s); } const z = 'k'; // THIS MUST GO"
        $c3 = Get-VmfCodeOnly -Text $t3 -Language CStyle
        $c3 | Should -Not -Match 'THIS MUST GO'
        $c3 | Should -Match "const z = 'k';"
    }

    It 'CODEONLY-2: a closing HTML tag is not a regex, and an HTML comment IS a comment' {
        # These files are pages. `</div>` after a `<` looked like the start of a
        # regex and ate the line; and nothing handled <!-- --> at all, so the
        # apostrophe in "the viewer's own identity" inside the dashboard's
        # banner comment opened a string that never closed.
        $t = @'
<!-- the viewer's own identity, which needed a second permission -->
<div class="x">text</div>
<script>var a = 1; // THIS MUST GO
</script>
'@
        $code = Get-VmfCodeOnly -Text $t -Language CStyle
        $code | Should -Not -Match 'THIS MUST GO'
        $code | Should -Not -Match 'viewer' -Because 'an HTML comment is a comment'
        $code | Should -Match 'class="x"' -Because 'the markup between them is kept'

        # THE PIN for '<' being out of the regex-start set. A mutation putting
        # it back passed every other test here, because the pages this repo has
        # happen to survive it - so the rule was real and unguarded. With '<'
        # in the set, the slash of `</div>` opens a false regex that swallows
        # the rest of the line, and the comment after it lives.
        $one = Get-VmfCodeOnly -Text '<div>a</div> // THIS MUST GO' -Language CStyle
        $one | Should -Not -Match 'THIS MUST GO'
        $one | Should -Match '<div>a</div>' -Because 'and the tag itself is untouched'
    }

    It 'CODEONLY-2: a comment inside a template literal interpolation is a real comment' {
        # `${ ... }` holds JavaScript. Treating the whole literal as one string
        # kept those comments, and two dashboard pages hide an operator-facing
        # comment in exactly that place.
        $t = 'const h = `<td>${' + "`n" + '  // THIS MUST GO' + "`n" + '  esc(p.id) }</td>`;'
        $code = Get-VmfCodeOnly -Text $t -Language CStyle
        $code | Should -Not -Match 'THIS MUST GO'
        $code | Should -Match 'esc\(p\.id\)' -Because 'the code around it is kept'
        $code | Should -Match '<td>' -Because 'and so is the markup'

        # THE PIN for counting braces inside the interpolation. A NESTED brace
        # must not end it - `${ f({a:1}) ... }` closes two - or the literal
        # resumes early and everything after the first brace is read as text
        # again, comments included. A mutation dropping the count passed every
        # other test here, because the simple cases close only one.
        $t2 = 'const h = `<td>${ f({a:1})' + "`n" + '  // THIS MUST GO' + "`n" + '  }</td>`;'
        $c2 = Get-VmfCodeOnly -Text $t2 -Language CStyle
        $c2 | Should -Not -Match 'THIS MUST GO'
        $c2 | Should -Match 'f\(\{a:1\}\)' -Because 'and the object literal survives'
    }

    It 'CODEONLY-2: bicep triple-quoted strings do not desync the scanner' {
        # identity.bicep is full of @description blocks whose prose contains
        # apostrophes. Read as three separate quotes they left the scanner
        # inside a string, and the next https:// in a real parameter was then
        # eaten as a comment.
        $q3 = "'" * 3
        $t = "@description($q3" + "A key that makes each install's registrations distinct." + "`n" +
             "It is the product's own name.$q3)`n" +
             "param dashboardOrigin string = 'https://vmf-dash-x.azurewebsites.net'`n" +
             'var q = 1 // THIS MUST GO'
        $code = Get-VmfCodeOnly -Text $t -Language CStyle
        $code | Should -Not -Match 'THIS MUST GO'
        $code | Should -Match 'vmf-dash-x\.azurewebsites\.net' `
            -Because 'THE DANGEROUS ONE: the scanner used to delete this, so a Should -Not -Match on it PASSED while it sat in the template'
    }

    It 'CODEONLY-2: every JavaScript, HTML and bicep file this repository has comes back clean' {
        # The measurement that found this, kept as the guard. Before the fix,
        # 8 of the 11 files the tests read through here were affected. A file
        # added later with a new shape of literal fails HERE, rather than by
        # quietly making somebody else's absence check vacuous.
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $files = @(Get-ChildItem (Join-Path $root 'src') -Include '*.js', '*.html' -Recurse -File) +
                 @(Get-ChildItem (Join-Path $root 'infra') -Filter '*.bicep' -Recurse -File)
        $files.Count | Should -BeGreaterThan 10 -Because 'a guard over nothing proves nothing'
        $bad = foreach ($f in $files) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            $left = @($code -split "`n" | Where-Object { $_.TrimStart().StartsWith('//') }).Count
            if ($left -gt 0) { "$($f.Name): $left comment line(s) survived" }
        }
        $bad -join '; ' | Should -BeNullOrEmpty
    }

    It 'and no address is DELETED from one' {
        # The same sweep in the other direction. Stripping a comment must never
        # take code with it, and a line ending at `'https: ` is the fingerprint
        # of the scanner having lost its place.
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $files = @(Get-ChildItem (Join-Path $root 'src') -Include '*.js', '*.html' -Recurse -File) +
                 @(Get-ChildItem (Join-Path $root 'infra') -Filter '*.bicep' -Recurse -File)
        $bad = foreach ($f in $files) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -match "'https: " -or $code -match '"https: ') { $f.Name }
        }
        $bad -join ', ' | Should -BeNullOrEmpty -Because 'an address cut at its // means the scanner lost its place'
    }

    It 'and the helper is not discovered as a test file itself' {
        # Named with a leading underscore and no .Tests, like _AzureGuard.ps1.
        Test-Path (Join-Path $PSScriptRoot '_CodeOnly.ps1') | Should -BeTrue
        (Get-ChildItem $PSScriptRoot -Filter '_CodeOnly.Tests.ps1' -File) | Should -BeNullOrEmpty
    }
}
