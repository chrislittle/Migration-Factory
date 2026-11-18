#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NO CONTROL CHARACTERS IN SOURCE. This has now cost real time three times, and
# each time the symptom pointed somewhere else entirely.
#
#   1. A regex written through a shell heredoc took a literal BACKSPACE where
#      `\b` was meant. The test it belonged to stopped matching anything and
#      stayed GREEN. It was caught only because that test had a paired "is this
#      finding anything?" partner.
#   2. `C:\actions-runner` became `C:` + a literal BEL where `\a` was meant,
#      while writing the fix for the release runner - found within a minute,
#      because the path then did not exist.
#   3. `'.\vmfadmin'` in tools/Initialize-VmfCiRunner.ps1 held a literal
#      VERTICAL TAB where `\v` was meant, and had done since 2026-09-07. It sat
#      in the COMMENT that tells a person how to register the runner service,
#      so the instruction was quietly wrong and nothing could ever have failed.
#
# The pattern is one thing: a backslash followed by a, b, f, n, r, t or v, in a
# string written through a layer that reads C escapes. PowerShell does not use
# backslash escapes at all, so in this repository the character is ALWAYS an
# accident, and it is invisible in every editor and in every diff.
#
# A comment cannot fail a build, which is exactly why the third one lasted. So
# the guard is not "does the code work" - it is "is the byte there at all".
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    # Everything this repository writes. Not the manual's images, not anything
    # vendored (docsify ships minified files that legitimately hold odd bytes).
    $script:sourceFiles = @(
        foreach ($dir in 'src', 'tools', 'tests', 'infra', 'schemas', 'samples', '.github') {
            $path = Join-Path $script:repoRoot $dir
            if (Test-Path $path) {
                Get-ChildItem $path -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1', '*.sh', '*.yml', '*.yaml', '*.json', '*.js', '*.html', '*.css', '*.bicep' |
                    Where-Object { $_.FullName -notmatch '\\(vendor|node_modules|manual\\vendor)\\' }
            }
        }
    )
}

Describe 'source hygiene: and no escape MAKES one when the script runs' {
    <#
        THE TWIN OF EVERYTHING ABOVE, and this file said it could not happen:
        "PowerShell does not use backslash escapes at all". True, and beside
        the point - PowerShell has its OWN escape character, and it is the
        backtick somebody reaches for to make a word look like code.

        MEASURED 2026-09-15, on a corporate machine, in the message
        that tells a person how to unblock their own install:

            it is installed and reports no version, so az cannot read its
            metadata and z containerapp will fail

        The source said `az containerapp`, written with backticks so it would
        read as a command. In a DOUBLE-QUOTED string, backtick-a is the BELL
        character - so the operator was told to repair a command called
        'z containerapp', with an invisible beep in front of it.

        The rules above cannot see this: the file holds a legal backtick and a
        legal 'a'. The control character exists only once the string is
        evaluated, which is the moment a person reads it.

        So this reads the STRINGS, through the PowerShell parser, and fails on
        an escape that produces a control character: a, b, e, f, v and 0.
        Backtick-n, backtick-r and backtick-t are left alone - those are
        written on purpose.
    #>

    It 'no expandable string carries an escape that makes a control character' {
        $offenders = [System.Collections.Generic.List[string]]::new()
        $scripts = @($script:sourceFiles | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' })
        $scripts.Count | Should -BeGreaterThan 50 -Because 'a check that reads nothing passes'
        foreach ($f in $scripts) {
            $tokens = $null
            $errs = $null
            [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs) | Out-Null
            foreach ($t in $tokens) {
                if ($t.Kind -notin @([System.Management.Automation.Language.TokenKind]::StringExpandable,
                                     [System.Management.Automation.Language.TokenKind]::HereStringExpandable)) { continue }
                # The pattern holds a backtick and a BRACKET, so it cannot
                # match itself - and this string is single-quoted anyway.
                if ($t.Text -match '`[abefv0]') {
                    $offenders.Add("$($f.Name):$($t.Extent.StartLineNumber)")
                }
            }
        }
        $offenders -join '; ' | Should -BeNullOrEmpty -Because 'the reader sees a control character where a word was meant'
    }
}

Describe 'source hygiene: no control character survives an edit' {

    It 'found a real number of files to check, or this proves nothing' {
        # The lesson from UX-WAVE-3: a narrow check that finds nothing is not
        # evidence of absence.
        @($script:sourceFiles).Count | Should -BeGreaterThan 200
    }

    It 'no source file holds a control character' {
        # Tab, carriage return and line feed are the only ones a text file may
        # hold. Everything else - backspace, bell, vertical tab, form feed -
        # arrived by accident.
        $bad = foreach ($file in $script:sourceFiles) {
            $text = [System.IO.File]::ReadAllText($file.FullName)
            $hits = [regex]::Matches($text, '[\x00-\x08\x0b\x0c\x0e-\x1f]')
            if ($hits.Count) {
                $line = ($text.Substring(0, $hits[0].Index) -split "`n").Count
                $code = [int][char]$hits[0].Value
                "$($file.Name):$line holds character $code ($($hits.Count) in the file)"
            }
        }
        $bad -join '; ' | Should -BeNullOrEmpty -Because 'a control character in source is always an accident, and it is invisible in a diff'
    }
}
