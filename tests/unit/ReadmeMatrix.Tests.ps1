# README-MATRIX-1: the README's support matrix summary says only what the full
# support matrix says. Since 2026-10-31, the README section is a short form of
# the support matrix, with a link that takes a customer to the main matrix.
# The full matrix is generated from the product's data; the summary is written
# by hand, so this check is what stops the two from drifting apart.

BeforeAll {
    $script:repoRoot = Resolve-Path (Join-Path $PSScriptRoot '..' '..')
    $script:readme = Get-Content -Raw (Join-Path $script:repoRoot 'README.md')
    $script:matrix = Get-Content -Raw (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'support-matrix.md')

    # Rows of every markdown table in a block of text, as arrays of trimmed cells.
    function Get-VmfTableRows {
        param([string]$Text)
        foreach ($line in ($Text -split "`n")) {
            $l = $line.Trim()
            if (-not $l.StartsWith('|') -or $l -match '^\|[\s|:-]+\|$') { continue }
            ,@($l.Trim('|').Split('|') | ForEach-Object { $_.Trim() })
        }
    }
    function Get-VmfSection {
        param([string]$Text, [string]$Heading)
        $at = $Text.IndexOf("## $Heading")
        if ($at -lt 0) { return '' }
        $rest = $Text.Substring($at + 3)
        $next = $rest.IndexOf("`n## ")
        if ($next -ge 0) { $rest = $rest.Substring(0, $next) }
        $rest
    }

    $script:summaryRows = @(Get-VmfTableRows (Get-VmfSection $script:readme 'Support matrix (summary)') |
        Where-Object { $_[0] -notin @('Machine generation', 'Operating system') })
    $script:matrixRows = @{}
    foreach ($h in 'Machine generation', 'Windows') {
        foreach ($r in (Get-VmfTableRows (Get-VmfSection $script:matrix $h))) {
            if ($r.Count -ge 3 -and $r[0] -notin @('Machine generation', 'Operating system')) {
                $script:matrixRows[$r[0]] = $r
            }
        }
    }
}

Describe 'README-MATRIX-1: the README summary matches the full support matrix' {

    It 'the README has the summary, and it links to the full matrix' {
        $script:readme | Should -Match '## Support matrix \(summary\)'
        $script:readme | Should -Match '\]\(docs/manual/reference/support-matrix\.md\)'
    }

    It 'reads enough rows that a pass means something' {
        # SUPPORT-MATRIX-2: 6, after the Generation 1 to Generation 2 row went
        # (2026-10-31: Generation 1 to Generation 2 is not supported at all).
        @($script:summaryRows).Count | Should -BeGreaterOrEqual 6
        $script:matrixRows.Count | Should -BeGreaterOrEqual 6
    }

    It 'every row it shows is a row of the full matrix, with the same status for each target' {
        $compared = 0
        foreach ($row in $script:summaryRows) {
            if ($row[0] -eq 'Linux') { continue }   # the matrix lists Linux by image, not in one row
            $script:matrixRows.ContainsKey($row[0]) | Should -BeTrue -Because "'$($row[0])' must be a row of the full matrix"
            $m = $script:matrixRows[$row[0]]
            $row[1] | Should -Be $m[1] -Because "the v5 column for '$($row[0])'"
            $row[2] | Should -Be $m[2] -Because "the v6 and v7 column for '$($row[0])'"
            $compared++
        }
        $compared | Should -BeGreaterOrEqual 6
    }

    It 'gives each target column the label the full matrix gives it' {
        # SUPPORT-MATRIX-2: the matrix stopped writing "v5 and Bsv2", because
        # Bsv2 is one series of the B family, not a peer of v5. The summary
        # must not keep the old label.
        foreach ($h in 'Machine generation', 'Operating system') {
            $mine = @(Get-VmfTableRows (Get-VmfSection $script:readme 'Support matrix (summary)') | Where-Object { $_[0] -eq $h })
            $section = if ($h -eq 'Operating system') { 'Windows' } else { $h }
            $theirs = @(Get-VmfTableRows (Get-VmfSection $script:matrix $section) | Where-Object { $_[0] -eq $h })
            $mine.Count | Should -Be 1 -Because "the summary has a '$h' table"
            $theirs.Count | Should -Be 1 -Because "the matrix has a '$h' table"
            $mine[0][1] | Should -Be $theirs[0][1]
            $mine[0][2] | Should -Be $theirs[0][2]
        }
    }
    It 'shows every machine generation and Windows row the full matrix has' {
        $shown = @($script:summaryRows | ForEach-Object { $_[0] })
        foreach ($k in $script:matrixRows.Keys) {
            $shown | Should -Contain $k -Because "the full matrix has a row for '$k'"
        }
    }
}
