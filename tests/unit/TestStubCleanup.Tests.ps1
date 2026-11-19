#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TEST-STUB-1: a stand-in for `az` that one test file defines must be gone
# before the next file runs.
#
# `Remove-Item function:global:az` removes NOTHING, and says nothing: the
# ID-ADDRESS-1 review measured it on 2026-09-28. Three cleanups used that form,
# so a stand-in stayed loaded and answered the `az` calls of the files that ran
# after it. A test with no stand-in of its own got a made-up answer, not a failure.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:testFiles = @(Get-ChildItem (Join-Path $script:repoRoot 'tests') -Recurse -Filter '*.ps1' |
        Where-Object { $_.FullName -ne $PSCommandPath })
    # Remove-Item and its aliases, as a whole word.
    $script:removeVerb = '(?<![\w-])(Remove-Item|ri|rm|del)\s'
    # The code without comments, with a backtick line continuation joined, so
    # a path on the next line is seen with its command.
    function script:CodeOf($file) { (Get-VmfCodeOnly -Path $file.FullName) -replace '`\r?\n\s*', ' ' }
}

Describe 'TEST-STUB-1: a stand-in function is removed in the form that removes it' {
    It 'PowerShell still ignores the function:global: form, which is why this file exists' {
        function global:VmfStubProbe { 'stub' }
        try {
            Remove-Item function:global:VmfStubProbe -ErrorAction SilentlyContinue
            [bool](Get-Command VmfStubProbe -CommandType Function -ErrorAction SilentlyContinue) | Should -BeTrue
            Remove-Item function:VmfStubProbe
            [bool](Get-Command VmfStubProbe -CommandType Function -ErrorAction SilentlyContinue) | Should -BeFalse
        }
        finally { Remove-Item function:VmfStubProbe -ErrorAction SilentlyContinue }
    }

    It 'no test file removes a function through function:global:' {
        $found = foreach ($file in $script:testFiles) {
            $code = CodeOf $file
            if ($code -match "(?i)$script:removeVerb[^\r\n]*function:[\\/]?global:") { $file.Name }
        }
        @($found) | Should -BeNullOrEmpty
    }

    It 'every global az or azd stand-in is matched by a removal that works' {
        # Counted, not just found: one working removal in a file must not
        # excuse a second stand-in in the same file.
        $missing = foreach ($file in $script:testFiles) {
            $code = CodeOf $file
            foreach ($name in 'az', 'azd') {
                $defined = ([regex]::Matches($code, "(?i)function\s+global:$name\s*[\(\{]")).Count
                $removed = ([regex]::Matches($code, "(?i)$script:removeVerb[^\r\n]*'?function:[\\/]?$name(?=['\s,]|$)", 'Multiline')).Count
                if ($removed -lt $defined) { "$($file.Name): $name defined $defined, removed $removed" }
            }
        }
        @($missing) | Should -BeNullOrEmpty
    }

    It 'the checks see the other spellings of a removal' {
        # Mutation guard for the two patterns above.
        $probe = "function global:az { }`nri ``" + "`n    'function:\az'"
        $code = $probe -replace '`\r?\n\s*', ' '
        ([regex]::Matches($code, "(?i)$script:removeVerb[^\r\n]*'?function:[\\/]?az(?=['\s,]|$)", 'Multiline')).Count | Should -Be 1
        "Remove-Item 'function:\az-helper'" -match "(?i)$script:removeVerb[^\r\n]*'?function:[\\/]?az(?=['\s,]|$)" | Should -BeFalse
    }
}
