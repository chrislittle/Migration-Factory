#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# DOC-1: the architecture document lives in the repository, and says nothing
# about code that is not there.
#
# Found 2026-09-26: the published document was far from the code. Its last full
# revision was a month old, it named six functions that never existed or were
# renamed, and a second copy (docs/architecture-artifact.html) sat in the
# repository a month staler still. The document now lives here, is published
# from this file, and the same rule the decision-flow map lives under (DOC-2)
# applies: a named function must exist.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:docPath = Join-Path $script:repoRoot 'docs' 'architecture' 'architecture.html'
    $script:doc = Get-Content $script:docPath -Raw
    $script:functions = @(Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -Include '*.ps1', '*.psm1' |
        ForEach-Object { [regex]::Matches((Get-Content $_.FullName -Raw), '(?m)^\s*function\s+([A-Za-z]+-Vmf[A-Za-z0-9]+)') } |
        ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
    $script:namePattern = '\b([A-Z][a-z]+-Vmf[A-Za-z0-9]+)\b'
}

Describe 'DOC-1: one architecture document, in the repository' {

    It 'is here' {
        Test-Path $script:docPath | Should -BeTrue
    }

    It 'and the stale second copy is gone' {
        Test-Path (Join-Path $script:repoRoot 'docs' 'architecture-artifact.html') | Should -BeFalse
    }

    # PUBLIC-SYNC-1: CLAUDE.md is an agent file and does not ship to the public repository.
    It 'CLAUDE.md names this file as the one to change' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'CLAUDE.md'))) {
        (Get-Content (Join-Path $script:repoRoot 'CLAUDE.md') -Raw) | Should -Match 'docs/architecture/architecture\.html'
    }
}

Describe 'DOC-1: every function the document names exists' {

    It 'found the functions in src/ to check against' {
        @($script:functions).Count | Should -BeGreaterThan 200
    }

    It 'found names in the document, so this cannot pass by reading nothing' {
        @([regex]::Matches($script:doc, $script:namePattern)).Count | Should -BeGreaterThan 20
    }

    It 'no name is of a function that is not there' {
        $named = @([regex]::Matches($script:doc, $script:namePattern) | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique
        $missing = @($named | Where-Object {
                $_ -notin $script:functions -and -not (Test-Path (Join-Path $script:repoRoot 'tools' "$_.ps1"))
            })
        $missing -join ', ' | Should -BeNullOrEmpty -Because 'a document describing code that does not exist is worse than none - it manufactures confidence'
    }
}
