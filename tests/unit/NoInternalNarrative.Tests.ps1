#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# NARRATIVE-1: the shipped pages carry no attributed quotes.
#
# Everything in src/dashboard is served to a customer's browser and readable
# with View Source, and the repository itself is intended to go public
# (PUBLIC-1). The comments in those files carried 201 lines of internal
# narrative: 96 lines attributing a quote to a named person, 79 lines of
# quoted speech, dates of internal conversations, and one line naming a
# personal subscription.
#
# NONE OF IT IS A SECURITY LEAK, and it is worth being accurate about that.
# OWASP's test for this (WSTG, Review Web Page Content for Information
# Leakage) and CWE-615 both target credentials, internal addresses, hidden
# endpoints, SQL and debugging output. A search of these files found none of
# that. What was there was somebody's voice, delivered to everybody they sell
# to. That is a privacy and professionalism problem, not a vulnerability.
#
# The TECHNICAL rationale stays - it is why this product does not repeat its
# own history, and a well-commented open-source file is a sign of care. What
# goes is the attribution: a comment must stand on its own, and the story
# behind it lives in the commit that introduced it, reachable from any line
# with git blame.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:shipped = @(
        Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -File |
            Where-Object { $_.Name -notmatch 'msal-browser' }
    )
    # A COMMENT line, in any of the four languages these files hold.
    $script:commentStart = '^\s*(//|\*|/\*|<!--|#)'
}

Describe 'NARRATIVE-1: no attributed quotes in anything the browser receives' {

    It 'finds the shipped files, so this cannot pass by scanning nothing' {
        $script:shipped.Count | Should -BeGreaterThan 10
    }

    It 'no comment attributes a quote to a person' {
        # Deliberately narrow. It matches the ONE shape that kept recurring -
        # a role word followed by a comma or a colon, or that word with a
        # -raised suffix and its kin (the patterns below) - because a gate matches
        # patterns, not judgement. It will not catch a future comment that is
        # indiscreet in a new shape, and saying so here is better than implying
        # the rule is airtight.
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:shipped) {
            $n = 0
            foreach ($line in (Get-Content $file.FullName)) {
                $n++
                if ($line -notmatch $script:commentStart) { continue }
                if ($line -match '(?i)\bowner\b\s*[,:]' -or
                    $line -match '(?i)\bowner-(raised|accepted|found|ruled)\b') {
                    $offenders.Add("$($file.Name):$n")
                }
            }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty `
            -Because 'a comment must stand on its own; the story lives in the commit, reachable with git blame'
    }

    It 'no comment carries a dated internal conversation' {
        # A date on a MEASUREMENT is kept on purpose - knowing when something
        # was measured is what makes it possible to judge whether it is stale.
        # What goes is a date attached to a person saying something, which is
        # the shape above with a timestamp on it.
        $offenders = [System.Collections.Generic.List[string]]::new()
        foreach ($file in $script:shipped) {
            $n = 0
            foreach ($line in (Get-Content $file.FullName)) {
                $n++
                if ($line -notmatch $script:commentStart) { continue }
                if ($line -match '(?i)\b(owner|he|she|they)\b[^.]{0,40}\b202\d-\d{2}-\d{2}\b\s*[:,]') {
                    $offenders.Add("$($file.Name):$n")
                }
            }
        }
        $offenders -join ', ' | Should -BeNullOrEmpty
    }

    It 'the technical rationale is still there - this did not become a silent deletion' {
        # The failure mode of a cleanup like this is that somebody removes the
        # comments instead of rewriting them, and the reasoning goes with them.
        # These are load-bearing notes that were never about a person, and they
        # must survive every future pass over these files.
        $help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
        $help | Should -Match '(?i)cold-?start' -Because 'the 20-40 s facade wake is why reads are off the critical path'
        $help | Should -Match 'STORE_READ_LIMIT'
        $help | Should -Match '(?i)appRoleAssignmentRequired' -Because 'why AADSTS50105 is a definitive no, not an unknown'

        $migrations = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
        $migrations | Should -Match '(?i)accelerated networking' -Because 'the engine judges the driver against the PLAN, not the current fabric'
        $migrations | Should -Match 'APPR-2' -Because 'the approval is bound to the plan the approver saw'

        $waves = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'waves.html'))
        $waves | Should -Match 'LEAK-1' -Because 'which elements survive a render is the whole reason that listener moved'
    }
}
