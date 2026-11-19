#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAIT-1: a page that reads the store says what it is reading.
#
# Owner, twice. 2026-09-15 of the assessments page: "we have nothing saying to
# wait like the overview page for example. we need to show status everywhere."
# 2026-09-16 of the projects page: "this should be everywhere in the app
# nothing should read dead. it loads eventually."
#
# WHAT THE PAGES DO is held in tests/js - projects-waiting, assessments-waiting
# and map-limited drive the real render and load functions. This file holds the
# part those cannot: that a page added LATER does not quietly go back to an
# empty table, which no behaviour test can notice because it would have to know
# the page exists.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:dash = Join-Path $script:repoRoot 'src' 'dashboard'
    # A page that walks the store for RUNS or PROJECTS - the walk that takes
    # seconds. A page reading one run's documents is not this.
    $script:walkers = @(Get-ChildItem $script:dash -Filter '*.html' | Where-Object {
        (Get-VmfCodeOnly -Path $_.FullName) -match "blobList\('', '/'\)|source\.listRuns\(\)|VmfListRuns"
    })
}

Describe 'WAIT-1: nothing reads dead while it loads' {

    It 'there are pages to check, so this cannot pass by finding none' {
        $script:walkers.Count | Should -BeGreaterThan 3 -Because 'the store is walked by more than three pages'
    }

    It 'every page that walks the store declares what it is reading' {
        foreach ($page in $script:walkers) {
            $code = Get-VmfCodeOnly -Path $page.FullName
            $code | Should -Match "waiting:\s*'Reading " -Because "$($page.Name) must say what it is reading"
        }
    }

    It 'and names the thing, rather than saying something is happening' {
        # Five pages all saying "Loading" tell nobody which of them is slow.
        foreach ($page in $script:walkers) {
            $said = [regex]::Match((Get-VmfCodeOnly -Path $page.FullName), "waiting:\s*'(?<s>[^']+)'").Groups['s'].Value
            $said | Should -Not -Match '(?i)^(loading|please wait|working)\.?$' -Because "$($page.Name) says '$said'"
            $said | Should -Match '(?i)^Reading (your |this )\w' -Because "$($page.Name) says '$said'"
        }
    }

    It 'THE DEFECT: and holds its empty message behind the same flag' {
        # The projects page showed an empty card; the assessments page said
        # "Nothing has been assessed yet" in a finished sentence while it was
        # still looking. Both came from painting the absent state before the
        # read had happened.
        foreach ($page in $script:walkers) {
            $code = Get-VmfCodeOnly -Path $page.FullName
            $code | Should -Match '(?m)^let reading = true;' -Because "$($page.Name) must know it has not looked yet"
            # LOADING-LINE-1: or hands the flag to the shared list, which
            # chooses (VmfHelp.listMount; tests/js/loading-line.test.js).
            $code | Should -Match 'if \(reading|reading\s*\?|reading &&|\.update\(\{[^}]*,\s*reading: reading === true' -Because "$($page.Name) must CHOOSE between the two, not paint one of them"
            $code | Should -Match 'reading = false' -Because "$($page.Name) must stop waiting once it has looked"
        }
    }
}
