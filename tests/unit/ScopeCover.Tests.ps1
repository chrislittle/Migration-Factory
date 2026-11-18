#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SCOPE-COVER-1, 2026-09-19. The WIRING half.
#
# tests/js/scope-cover.test.js drives scopeRowsWithCoverage through every
# combination, and that is the logic. It says nothing about whether the page
# ever CALLS it, whether the rows it is handed carry the two fields it reads,
# or whether a management group's children are asked for - and SCOPE-LAG-1
# proved that shape of hole is real: all ten of its logic tests passed with the
# recorder deleted from the call site.
#
# Read through Get-VmfCodeOnly, so a comment describing the mechanism cannot
# satisfy a check about the mechanism.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'access.html') -Language CStyle
}

Describe 'SCOPE-COVER-1: the page asks, and renders the answer' {

    It 'the list is marked before it is drawn' {
        # ACCESS-PAIR-COVER-1: after the web service read access each row
        # gets from a wider place (tests/js/access-pair-cover.test.js).
        $script:code | Should -Match 'const shown = scopeRowsWithCoverage\(\s*scopeRowsWithServiceCover\(\s*merged\.rows'
    }

    It 'and the mark is drawn, naming the place that covers it' {
        $script:code | Should -Match 'r\.coveredBy \? .*UX\.scopeCoveredBy\.replace\(''\{place\}'', r\.coveredBy\)'
    }

    It 'with one line saying what to do instead, shown only when a row carries the mark' {
        # A permanent sentence under a table that usually has nothing to
        # explain is noise, and noise is how a real warning stops being read.
        $script:code | Should -Match 'shown\.some\(r => r\.coveredBy\) \?[^?]*UX\.scopeCoveredWhy'
    }
}

Describe 'SCOPE-COVER-1: the rows carry what the logic reads' {

    It 'every listed grant carries the Azure scope it was made at' {
        # Without this the function compares undefined to undefined and marks
        # nothing, forever, with no error anywhere.
        $script:code | Should -Match 'rows\.push\(\{[^}]*scope: a\.properties\.scope'
    }

    It 'and its mode, which is what ranks the permission' {
        # NOT the displayed words. Ranking by a display string would break
        # silently the day somebody rewords the column, which has happened to
        # tests in this repository twice.
        $script:code | Should -Match 'rows\.push\(\{[^}]*mode,'
        $script:code | Should -Match "function scopeReach\(mode\) \{ return mode === 'migrate'"
        $script:code | Should -Not -Match 'scopeReach\(\w+\.what\)'
    }

    It 'a grant just made carries both too, so it is judged on the same load' {
        # SCOPE-LAG-1 shows a new row before Azure lists it. A row that skipped
        # these two would appear unmarked and gain the mark two minutes later,
        # which is the confusion this item exists to remove.
        $script:code | Should -Match "scopeLagNote\('added'[\s\S]{0,600}mode: mode === 'migrate'"
        $script:code | Should -Match "scopeLagNote\('added'[\s\S]{0,600}scope: created\.properties\?\.scope"
    }
}

Describe 'SCOPE-COVER-1: unknown is never shown as adds nothing' {

    It 'a management group is asked about, because the ids cannot prove it' {
        $script:code | Should -Match 'await scopeDescendants\(merged\.rows'
        $script:code | Should -Match 'descendants\?api-version=2021-04-01'
    }

    It 'and only when a row is actually at that level' {
        # Most estates have none. A call per load for a fact nobody needs is
        # how a page gets slow.
        $script:code | Should -Match 'filter\(s => isManagementGroupScope\(s\)\)'
    }

    It 'a descendants call that failed leaves the group out of the map entirely' {
        # The alternative - an empty Set - would read as "nothing is under it",
        # which is a measured answer this page never made.
        $script:code | Should -Match 'function scopeDescendants\([\s\S]{0,600}catch \(e\) \{'
        $script:code | Should -Not -Match 'map\.set\(scopeNormalize\(g\), new Set\(\)\)'
    }
}
