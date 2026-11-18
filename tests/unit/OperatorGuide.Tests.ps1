#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DOC-3 - documentation inside the app.
#
# The documentation must reach the app, perhaps by taking the GitHub docs
# and showing them in the app.
#
# The tension is real: docs that live only in the repo are invisible to
# an operator mid-run, and docs COPIED into the app drift from the repo. That
# problem is already solved twice here - stop-reasons.json and
# assessment-reasons.json are copied at DEPLOY time from the engine's own file,
# never maintained twice. This is the third use of the same answer.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:guidePath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'operator-guide.json'
    $script:guide = Get-Content $script:guidePath -Raw | ConvertFrom-Json
    $script:help = Get-Content (Join-Path $script:repoRoot 'src' 'dashboard' 'help.js') -Raw
    $script:deploy = Get-Content (Join-Path $script:repoRoot 'tools' 'Deploy-VmfDashboard.ps1') -Raw
}

Describe 'DOC-3: there is exactly ONE copy' {
    It 'lives with the engine data, and the deploy ships it' {
        Test-Path $script:guidePath | Should -BeTrue
        $script:deploy | Should -Match "operator-guide\.json"
    }

    It 'and there is NO second copy under src/dashboard' {
        # The failure this pattern exists to stop, and one already made here:
        # two pages carried their own partial copies of the blocker wording and
        # both were missing five of the seven entries.
        @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Filter 'operator-guide.json' -Recurse).Count |
            Should -Be 0 -Because 'the deploy copies it; a checked-in copy would drift'
    }
}

Describe 'DOC-3: it covers the screens a person can actually be on' {
    It 'every page in the navigation has a guide entry' {
        # Derived from the nav itself rather than a list restated here, so a new
        # tab cannot ship without its explanation.
        $navBlock = [regex]::Match($script:help, '(?ms)const NAV = \[(.*?)\];').Groups[1].Value
        $navBlock | Should -Not -BeNullOrEmpty
        $hrefs = [regex]::Matches($navBlock, "href:\s*'([^']+)'") | ForEach-Object { $_.Groups[1].Value }
        @($hrefs).Count | Should -BeGreaterThan 2
        foreach ($h in $hrefs) {
            $script:guide.screens.PSObject.Properties.Name | Should -Contain $h -Because "$h is a tab a person can land on"
        }
    }

    It 'and so do the screens reached from it' {
        foreach ($p in 'wizard.html', 'waves.html') {
            $script:guide.screens.PSObject.Properties.Name | Should -Contain $p
        }
    }

    It 'every entry actually says something in all three parts' {
        foreach ($prop in $script:guide.screens.PSObject.Properties) {
            $s = $prop.Value
            $s.title     | Should -Not -BeNullOrEmpty -Because "$($prop.Name) needs a title"
            $s.what      | Should -Not -BeNullOrEmpty -Because "$($prop.Name) needs to say what the screen is"
            @($s.howToRead).Count | Should -BeGreaterThan 0 -Because "$($prop.Name) needs at least one thing to read"
            $s.nextStep  | Should -Not -BeNullOrEmpty -Because "$($prop.Name) needs to say what to do next"
        }
    }
}

Describe 'DOC-3: it speaks the way every other operator string has to' {
    It 'is written to ASD-STE100, like every other operator string' {
        # This carried its own banned list, which included 'NVMe' - the rule
        # that forced the assessment wording to say "the new disk type" and
        # name nothing. STE-1 replaced it with ONE vocabulary that bans OUR
        # machinery and allows the reader's own subject.
        $ste = & (Join-Path $script:repoRoot 'tools' 'Test-SimplifiedEnglish.ps1') -Source 'operator-guide' 6>$null
        @($ste.Findings | ForEach-Object { "$($_.Id): $($_.Detail)" }) -join '; ' | Should -BeNullOrEmpty
    }
}

Describe 'DOC-3: the help button no longer sends you away' {
    It 'opens the guide in the app instead of the GitHub readme' {
        # This was the complaint: a person mid-migration was sent OUT of the
        # product to read about the product.
        $script:help | Should -Match "if \(kind === 'lost'\) \{ guideDialog\(\); return; \}"
        $script:help | Should -Match 'async function guideDialog'
    }

    It 'but still offers the full manual, and falls back to it if the guide cannot load' {
        # DOC-4: the way onward is the manual, which ships with the dashboard,
        # never GitHub - a person mid-migration is not sent out of the product.
        # A help button that does nothing is worse than one that sends you away.
        $script:help | Should -Match 'guideMissing'
        $fn = [regex]::Match($script:help, '(?ms)async function guideDialog\(\) \{.*?\n  \}').Value
        $fn | Should -Match 'openManual\(\)' -Because 'the manual, in this tab (NO-POPUPS-1)'
        $fn | Should -Not -Match 'REPO'
    }

    It 'and asks ONE rule which page it is on' {
        # The guide first referenced the menu's local `page`, which is an
        # undefined variable there and something no syntax check would catch.
        $script:help | Should -Match 'const currentPage = \(\)'
        $fn = [regex]::Match($script:help, '(?ms)async function guideDialog\(\) \{.*?\n  \}').Value
        $fn | Should -Match 'currentPage\(\)'
        $fn | Should -Not -Match '\bguide\.screens\[page\]'
    }
}
