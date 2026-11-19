#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# The README is the front door, and the first thing anybody reads.
#
# Found 2026-09-08, the day after v0.2.0 shipped: the README still said 0.1.0
# everywhere, and it was not good. It must be the front door to the manual,
# and its install section said only azd up.
#
# Three faults, and only one of them was about words:
#
#   1. THE VERSION WAS WRITTEN BY HAND, so it was wrong the moment a release
#      happened. VERSION-1 exists to end exactly this, and the README was the
#      one place it had not reached.
#   2. THE INSTALL SECTION SAID `azd up` AND NOTHING ELSE. The real sequence is
#      six commands and four tools installed first. A reader would have been
#      stopped at the first one.
#   3. It described the manual rather than routing anybody into it.
#
# These tests hold the two that can be checked. Whether the prose is any good
# is a reviewer's call, not a test's.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:readme   = Get-Content (Join-Path $script:repoRoot 'README.md') -Raw
    $script:manifest = Import-PowerShellDataFile (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1')
    $script:release  = Get-Content (Join-Path $script:repoRoot 'tools' 'New-VmfRelease.ps1') -Raw
}

Describe 'the README states the version the product reports' {

    It 'names the manifest version, and names it exactly once' {
        # Exactly once because New-VmfRelease rewrites it by that pattern and
        # refuses when it is not unique - a second copy would be set or missed
        # at random.
        $pattern = "Version \*\*$([regex]::Escape($script:manifest.ModuleVersion))\*\*"
        @([regex]::Matches($script:readme, $pattern)).Count |
            Should -Be 1 -Because "the README must say $($script:manifest.ModuleVersion), which is what Get-VmfVersion reports"
    }

    It 'holds no OTHER version number that could be mistaken for it' {
        # A stale number somewhere else in the page is the same defect in a new
        # place. One number is NOT a claim about this product and is allowed
        # by name: the Azure CLI minimum, which is a requirement. (Before 1.0
        # the page also named 1.0.0 as a milestone, and this test refused
        # "Version **1.0.0**" - which failed the 1.0.0 release itself.)
        $allowed = @($script:manifest.ModuleVersion, '2.61.0')
        $others = @([regex]::Matches($script:readme, '\b\d+\.\d+\.\d+\b') |
            ForEach-Object { $_.Value } | Where-Object { $_ -notin $allowed })
        $others -join ', ' | Should -BeNullOrEmpty -Because 'one number, one source'
    }

    It 'and the release script sets it, so it cannot be forgotten' {
        $script:release | Should -Match "\`$readme = Join-Path \`$repoRoot 'README\.md'"
        # PUBLIC-PIPELINE-1: the pattern is shared with the public release
        # workflow, which refuses a README that disagrees with the manifest.
        $script:release | Should -Match '\$readmePattern = Get-VmfReadmeVersionPattern \$current'
        [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..' '..' 'tools' '_VmfReleaseVersion.ps1')) | Should -Match ([regex]::Escape('"Version \*\*$([regex]::Escape($Version))\*\*"'))
        # Staged with the manifest, in the same commit. A README updated but
        # not committed would be a dirty tree the NEXT release refuses.
        $script:release | Should -Match 'git -C \$repoRoot add -- \$manifest \$readme'
    }
}

Describe 'the README tells the truth about installing' {

    It 'names every tool a person must install first' {
        # `azd up` alone stopped a reader at the first command. The manual's
        # Before you install page is the source for this list.
        foreach ($tool in 'Azure CLI', 'Azure Developer CLI', 'PowerShell 7', 'Git') {
            $script:readme | Should -BeLike "*$tool*" -Because "a reader cannot run the install without $tool"
        }
    }

    It 'says Docker is NOT needed, because every reader assumes it is' {
        $script:readme | Should -Match '(?i)Docker is not'
    }

    It 'gives the commands in the order they are run, not just the last one' {
        $order = 'az login', 'az account set', 'azd auth login', 'git clone', 'azd up'
        $at = foreach ($cmd in $order) { $script:readme.IndexOf($cmd) }
        $at | Should -Not -Contain -1 -Because 'each command in the install sequence appears'
        for ($i = 1; $i -lt $at.Count; $i++) {
            $at[$i] | Should -BeGreaterThan $at[$i - 1] -Because "'$($order[$i])' comes after '$($order[$i-1])'"
        }
    }

    It 'names what the install needs of the reader: the role, the region and the cost' {
        $script:readme | Should -Match '(?i)\*\*Owner\*\*'
        $script:readme | Should -Match '(?i)workload profiles'
        $script:readme | Should -Match '(?i)while the platform is idle'
        $script:readme | Should -Not -Match '\$\s?\d' -Because 'a price lives on Microsoft''s pricing pages, linked from Costs (MANUAL-REVIEW-1)'
    }

    It 'says the install leaves a product with the permission the reader chose, and points to After the install' {
        # It said the install leaves a product that can do nothing yet. The
        # default answer of the install is scan and migrate (preprovision.ps1),
        # so that was false for most installs (MANUAL-REVIEW-1).
        $script:readme | Should -Match '(?i)holds the permission over machines that you chose'
        $script:readme | Should -Not -Match '(?i)no permission over any machine|can do nothing yet'
        $script:readme | Should -Match 'install/after-install\.md'
    }
}

Describe 'README-2: the front page is held to the same words as every other page' {

    # It was the only operator-facing page the ASD-STE100 gate did not read.
    # It said "so neither route can quietly rot", and a metaphor like "rot"
    # does not belong on an operator-facing page.
    #
    # It could not join the gate before DOCS-SPLIT-2, when the layout table and
    # the development commands moved to CLAUDE.md. What is left is a page for a
    # reader.

    It 'the wording gate reads the README' {
        $gate = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Raw
        $gate | Should -Match "\`$readme = Join-Path \`$Root 'README\.md'"
        $gate | Should -Match "Name = 'README'"
    }

    It 'and the metaphors that were found in it are rules now, not memories' {
        # A document does not rot and a page is not a door. Both make a reader
        # translate a picture back into the fact it stands for.
        $gate = Get-Content (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Raw
        $vague = [regex]::Match($gate, '(?s)\$script:VagueOrIdiom = @\((.*?)
\)').Groups[1].Value
        $vague | Should -Not -BeNullOrEmpty
        foreach ($word in "'rot'", "'front door'", "'load-bearing'") {
            $vague | Should -BeLike "*$word*" -Because "$word was written into an operator-facing page"
        }
    }

    It 'the page count it claims is the page count the manual has' {
        # It said 45 after DOCS-SPLIT-1 moved a page out and left 44. A number
        # written by hand in a second place is a number that goes wrong - the
        # same fault as the version, in the same file, three hours apart.
        $pages = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Filter '*.md' -Recurse |
            Where-Object { $_.Name -notin '_sidebar.md', 'README.md' })
        $claimed = [regex]::Match($script:readme, '(\d+) pages').Groups[1].Value
        $claimed | Should -Not -BeNullOrEmpty -Because 'the README says how big the manual is'
        [int]$claimed | Should -Be $pages.Count
    }
}

Describe 'LICENCE-1: the product says what a person may do with it' {

    # There was no LICENSE file until 2026-09-08, so the code was all rights
    # reserved - copyright is automatic and publishing grants nothing. There is
    # no commercial plan for the code, so the licence is Apache 2.0.

    BeforeAll {
        $script:licencePath = Join-Path $script:repoRoot 'LICENSE'
    }

    It 'the LICENSE file exists and is the Apache 2.0 text, unmodified' {
        # UNMODIFIED matters: GitHub detects the licence by matching the text,
        # and a repository whose licence it cannot name is one a corporate
        # reviewer has to read by hand. The file was fetched from apache.org
        # rather than typed.
        Test-Path $script:licencePath | Should -BeTrue
        $text = Get-Content $script:licencePath -Raw
        $text | Should -Match 'Apache License'
        $text | Should -Match 'Version 2\.0, January 2004'
        $text | Should -Match 'http://www\.apache\.org/licenses/'
        # The clause that is doing real work for a tool that rebuilds machines.
        $text | Should -Match 'WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND'
    }

    It 'the module manifest names the same licence' {
        # A person who installs the module sees the manifest, not the repository.
        $script:manifest.Copyright | Should -Match '(?i)Apache License, Version 2\.0'
        $script:manifest.PrivateData.PSData.LicenseUri | Should -Match 'LICENSE$'
    }

    It 'the README points at it, and no longer says there is none' {
        $script:readme | Should -Match '\[Apache License 2\.0\]\(LICENSE\)'
        $script:readme | Should -Match '(?i)no warranty'
        $script:readme | Should -Not -Match '(?i)and no licence'
    }
}

Describe 'the README is a front door, not a second manual' {

    It 'routes a reader by what they came to do' {
        $script:readme | Should -Match '(?i)## Where to go'
        foreach ($page in 'understand/what-it-does.md', 'journey/the-whole-journey.md',
                          'use/when-a-machine-stops.md', 'install/step-by-step.md') {
            $script:readme | Should -BeLike "*$page*" -Because "the front door must reach $page"
        }
    }

    It 'every manual link it makes resolves to a file that exists' {
        # A front door with a dead link is worse than no front door. The manual
        # has its own link test; this one covers the way in.
        $links = [regex]::Matches($script:readme, '\]\((docs/[^)#]+)\)') | ForEach-Object { $_.Groups[1].Value }
        @($links).Count | Should -BeGreaterThan 15 -Because 'a narrow check that finds nothing proves nothing'
        $dead = foreach ($link in ($links | Sort-Object -Unique)) {
            if (-not (Test-Path (Join-Path $script:repoRoot $link))) { $link }
        }
        $dead -join ', ' | Should -BeNullOrEmpty
    }

    It 'points at the manual as THE documentation rather than describing it' {
        $script:readme | Should -Match "(?i)\[The manual\]\(docs/manual/README\.md\) is the product's"
    }
}
