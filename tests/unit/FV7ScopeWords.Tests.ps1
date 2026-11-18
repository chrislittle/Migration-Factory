#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# F-V7-SCOPE-WORDS-1 (2026-11-14): the scope said "F on v7" as a target
# the product chooses. It is not one. Microsoft lists F among its v7 target
# families, but every F v7 series (Fasv7, Falsv7, Famsv7, Fadsv7, Faldsv7,
# Famdsv7) is AMD, a machine keeps its processor maker, and every F, Fs and
# Fsv2 machine is Intel. The planner chooses Dl, D and E sizes by shape only,
# so no route offers an F size.
#
# The data keeps F on the v7 list, because that list says what Microsoft
# approves. These tests hold the two facts the words rest on, and keep the
# scope lines from claiming F on v7 again.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:families = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
}

Describe 'F-V7-SCOPE-WORDS-1: no route offers an F size, and the scope does not say it does' {
    It 'every F family Microsoft lists on v7 is on a processor other than Intel, the processor of every F machine' {
        $fRows = @(foreach ($row in @($script:families.targetFamilyExamples | Where-Object { $_.generation -eq 'v7' })) {
                foreach ($x in @($row.examples | Where-Object { $_ -match '^F' })) { [pscustomobject]@{ Family = $x; Platform = [string]$row.platform } } })
        $fRows.Count | Should -BeGreaterThan 0 -Because 'the data lists F on v7, so it must name an F family'
        foreach ($r in $fRows) { $r.Platform | Should -Not -Be 'Intel' -Because "$($r.Family) is listed on v7" }
    }

    It 'the planner chooses sizes by shape from the Dl, D and E families only' {
        $planner = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1') -Raw
        $m = [regex]::Match($planner, '\$familyNames = \[ordered\]@\{([^\r\n]*)\}')
        $m.Success | Should -BeTrue -Because 'Get-VmfShapeSizeChoices names its families in one line'
        $keys = @([regex]::Matches($m.Groups[1].Value, '(\w+) = @\(') | ForEach-Object { $_.Groups[1].Value })
        $keys | Should -Be @('Dl', 'D', 'E')
    }

    It 'no scope line names F on v7 as a target: <Name>' -TestCases @(
        # PUBLIC-SYNC-1: the agent files do not ship to the public repository, so there they are not read.
        @{ Name = 'CLAUDE.md'; Rel = 'CLAUDE.md'; Absent = -not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'CLAUDE.md')) }
        @{ Name = 'AGENTS.md'; Rel = 'AGENTS.md'; Absent = -not (Test-Path (Join-Path $PSScriptRoot '..' '..' 'AGENTS.md')) }
        @{ Name = 'the manual start page'; Rel = 'docs/manual/README.md' }
        @{ Name = 'What this product does'; Rel = 'docs/manual/understand/what-it-does.md' }
        @{ Name = 'the architecture document'; Rel = 'docs/architecture/architecture.html' }
    ).Where({ -not $_['Absent'] }) {
        $text = Get-Content (Join-Path $script:repoRoot $Rel) -Raw
        $text | Should -Match 'Dl and E on v5, v6 and v7' -Because 'the scope line must be found, or this proves nothing'
        # The old forms: "v7; F on v7;", "v7, F on v7," and "v7. F on v7.".
        $text | Should -Not -Match '(?i)v7[;,.]\s+F on v7'
    }
}
