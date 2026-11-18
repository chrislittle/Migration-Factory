#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SECURITY-MD-1: how to report a security problem privately, and what the
# project does with the report.
#
# Before this item there was no SECURITY.md, and the only issue templates were
# bug and feature. A person who found a vulnerability had one place to write it:
# a PUBLIC issue, which tells every reader how to use it before a fix exists.
#
# The contact is GitHub's private vulnerability reporting, never an address
# (CLAUDE.md rule 13: nobody real is named in this repository).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:securityPath = Join-Path $script:repoRoot 'SECURITY.md'
    $script:policyPath   = Join-Path $script:repoRoot 'docs' 'security-policy.md'
    $script:security = if (Test-Path $script:securityPath) { Get-Content $script:securityPath -Raw } else { '' }
    $script:policy   = if (Test-Path $script:policyPath)   { Get-Content $script:policyPath -Raw }   else { '' }
}

Describe 'SECURITY-MD-1: SECURITY.md tells a reporter how to report privately' {

    It 'exists at the repository root, where GitHub looks for it' {
        Test-Path $script:securityPath | Should -BeTrue
    }

    It 'names GitHub private vulnerability reporting by its own name' {
        $script:security | Should -Match '(?i)private vulnerability reporting'
    }

    It 'tells the reporter how to open the private report form: the Security tab, then Report a vulnerability' {
        $script:security | Should -Match '(?im)^\d+\.\s.*\*\*Security\*\* tab'
        $script:security | Should -Match '(?im)^\d+\.\s.*\*\*Report a vulnerability\*\*'
    }

    It 'names no GitHub account - a link to the repository by its account names its owner (rule 13)' {
        # Any absolute link to a repository on github.com carries the account
        # name in its path. The Security tab step needs none.
        $script:security | Should -Not -Match '(?i)github\.com/(?!en/)[\w.-]+/[\w.-]+'
        $script:policy   | Should -Not -Match '(?i)github\.com/(?!en/)[\w.-]+/[\w.-]+'
    }

    It 'tells the reporter not to open a public issue' {
        $script:security | Should -Match '(?i)do not open a public issue'
    }

    It 'gives no email address as the contact - the contact is the private report form' {
        $script:security | Should -Not -Match '[\w.+-]+@[\w-]+\.[\w.-]+'
    }

    It 'says what to include in a report' {
        $script:security | Should -Match '(?im)^#+\s*What to include'
    }

    It 'says what happens next, and when' {
        $script:security | Should -Match '(?im)^#+\s*What happens next'
        $script:security | Should -Match '\b7 days\b'
    }

    It 'links to the severity scale and the fix deadlines' {
        $script:security | Should -Match '\(docs/security-policy\.md\)'
    }
}

Describe 'SECURITY-MD-1: the severity scale and the fix deadlines' {

    It 'are in docs/, not in the manual that ships inside the dashboard' {
        Test-Path $script:policyPath | Should -BeTrue
        $inManual = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Filter '*.md' -Recurse |
            Where-Object { (Get-Content $_.FullName -Raw) -match '(?i)private vulnerability reporting' })
        $inManual.Count | Should -Be 0 -Because 'the manual is for the operator of the product, not for the people who develop it (DOCS-SPLIT-1)'
    }

    It 'give triage within 7 days' {
        $script:policy | Should -Match '(?i)triage[^.\n]*\b7 days\b|\b7 days\b[^.\n]*triage'
    }

    It 'give each severity its fix target: <Severity> in <Days> days' -ForEach @(
        @{ Severity = 'Critical';  Days = 30 }
        @{ Severity = 'Important'; Days = 30 }
        @{ Severity = 'Moderate';  Days = 90 }
        @{ Severity = 'Low';       Days = 365 }
    ) {
        # One table row per severity: | Critical | ... | 30 days |
        $script:policy | Should -Match "(?m)^\|\s*$Severity\s*\|[^\n]*\|\s*$Days days\s*\|\s*$"
    }

    It 'list exactly the four severities, in order' {
        $rows = [regex]::Matches($script:policy, '(?m)^\|\s*(Critical|Important|Moderate|Low|High|Medium)\s*\|') |
            ForEach-Object { $_.Groups[1].Value }
        @($rows) | Should -Be @('Critical', 'Important', 'Moderate', 'Low')
    }

    It 'say how the security label is used' {
        $script:policy | Should -Match '(?i)label'
        $script:policy | Should -Match '`security`'
    }
}

Describe 'SECURITY-MD-1: the wording gate reads both pages' {

    It 'lists SECURITY.md and the policy page as sources, and reads words from each' {
        $sources = @(& (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -ListSources 6>$null)
        $security = @($sources -match '^SECURITY\s')
        $policy   = @($sources -match '^security-policy\s')
        $security.Count | Should -Be 1
        $policy.Count   | Should -Be 1
        $security[0] | Should -Not -Match '\b0 string'
        $policy[0]   | Should -Not -Match '\b0 string'
    }
}
