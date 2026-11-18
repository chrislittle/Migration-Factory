#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TARGETS-AREAS-1 (GitHub issue 422) - the two areas of the Choose each target
# step are named for HOW the target is chosen, and every row shows the VM
# generation.
#
# The areas were titled "Generation 2 machines" and "Generation 1 machines and
# older sizes", but the page splits them with oldShape(): Generation 1, OR an
# older size with no size of the same name on v5. So a Generation 2 machine on
# DS2_v2 sat under a Generation 1 title, and with no Generation column the
# title was the only thing on the page that spoke of generation.
#
# tests/js/targets-step.test.js RUNS the row and area functions with machines
# shaped like the target advice. This file checks what a run cannot: that the
# step draws through those functions, and that the manual says the same. It
# reads the page through Get-VmfCodeOnly, so a comment that still names an old
# title or call cannot satisfy a check.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:wizCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html') -Language CStyle
    function script:TaSlice([string]$From, [string]$To) {
        $a = $script:wizCode.IndexOf($From)
        $b = $script:wizCode.IndexOf($To, [Math]::Max($a, 0))
        if ($a -lt 0 -or $b -lt 0) { throw "could not find '$From' .. '$To' in the code of wizard.html" }
        $script:wizCode.Substring($a, $b - $a)
    }
    $script:manualPlan = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'plan.md') -Raw
}

Describe 'TARGETS-AREAS-1: the areas say how the target is chosen' {
    It 'declares the two titles, and no title named for a generation' {
        $script:wizCode | Should -Match ([regex]::Escape("tAreaSame: 'Same size, newer version',")) -Because 'approved words, 2026-10-12'
        $script:wizCode | Should -Match ([regex]::Escape("tAreaShape: 'Choose a family and size',"))
        $script:wizCode | Should -Not -Match '\btAreaGen2\b'
        $script:wizCode | Should -Not -Match '\btAreaOld\b'
        $script:wizCode | Should -Not -Match "'Generation 1 machines and older sizes'"
        $script:wizCode | Should -Not -Match "'Generation 2 machines'"
    }

    It 'splits the machines once, by oldShape, into those two titles' {
        $areas = TaSlice 'function tAreasHtml(' 'function renderTargets('
        $areas | Should -Match ([regex]::Escape("area('same', UX.tAreaSame, machines.filter(m => !oldShape(m)), '')"))
        $areas | Should -Match ([regex]::Escape("area('shape', UX.tAreaShape, machines.filter(oldShape), UX.tAreaShapeHelp)"))
    }

    It 'the step draws its areas through tAreasHtml, the function the page test runs' {
        $render = TaSlice 'function renderTargets(' 'async function saveTargets('
        $render | Should -Match ([regex]::Escape('${tAreasHtml(machines)}'))
        # No second drawing of the rows or the areas inside the step itself.
        $render | Should -Not -Match 'const tRow = '
        $render | Should -Not -Match 'const area = '
        $render | Should -Not -Match 'UX\.tArea'
    }
}

Describe 'TARGETS-AREAS-1: every row shows the VM generation' {
    It 'the heading of both areas has a Generation column' {
        $areas = TaSlice 'function tAreasHtml(' 'function renderTargets('
        $areas | Should -Match ([regex]::Escape('<th>${esc(UX.colGen)}</th>'))
    }

    It 'each row fills it from the generation Azure reports, with the words the review step uses' {
        $row = TaSlice 'function tTargetRow(' 'function tAreasHtml('
        $row | Should -Match ([regex]::Escape('<td class="t-gen">${esc(advGenLabel(m.gen))}</td>'))
        # one more column, so the Details row spans one more
        # MANA-LINUX-KERNEL-1 added a kernel column and KERNEL-UX-1 moved the
        # choice into Details, so the details row spans 7 again.
        # ADVISE-AN-1 (2026-10-12) removed the tick box column, so the
        # Details row is one cell over the seven columns.
        $row | Should -Match ([regex]::Escape('<tr class="t-detail"><td colspan="7">'))
    }
}

Describe 'TARGETS-AREAS-1: the manual says what the page shows' {
    It 'names the two new titles and the Generation column' {
        $script:manualPlan | Should -Match ([regex]::Escape('**Same size, newer version**'))
        $script:manualPlan | Should -Match ([regex]::Escape('**Choose a family and size**'))
        $script:manualPlan | Should -Match ([regex]::Escape('**Generation**'))
    }

    It 'no manual page names an old title' {
        $pages = Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -Filter '*.md'
        foreach ($page in $pages) {
            $text = (Get-VmfPageSource -Path $page.FullName)
            $text | Should -Not -Match 'Generation 1 machines and older sizes' -Because $page.Name
            $text | Should -Not -Match ([regex]::Escape('**Generation 2 machines**')) -Because $page.Name
        }
    }
}
