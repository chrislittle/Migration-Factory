#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MANUAL-SIZES-1, 2026-09-21. Found by checking the customer deck against the
# product: the product moves more than v4 and v5.
#
# THE MANUAL SAID LESS THAN THE PRODUCT DOES.
#
#     | Source sizes | The D and E series, v4 and v5, ... |
#
# It omitted v2 and v3 sources and never named Fasv7. The manual SHIPS INSIDE
# THE DASHBOARD, so an operator would have believed a v3 machine was out of
# scope - and would never have seen the assessment say otherwise, because they
# would not have scanned it.
#
# THE RULE, NOT THE LIST, is what the page states now. Microsoft's scope is
# recorded in docs/ms-guide-traceability.md against their own
# #target-vm-families section: "only sizes with a same-stem v6/v7 target
# plan". That is what the planner implements - it swaps the version suffix and
# asks the region's catalogue - and a page that states the RULE cannot go
# stale the way a list of versions did.
#
# These checks are deliberately about the SHAPE of the claim rather than its
# exact words. A page that names a version range is the defect; a page that
# names the rule is the fix.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:limits = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'limits.md') -Raw
    $script:rows = @($script:limits -split "`r?`n" | Where-Object { $_ -match '^\|\s*(Source|Target) sizes' })
}

Describe 'MANUAL-SIZES-1: the manual states the size rule, not a list' {

    It 'finds both rows, so this cannot pass by reading nothing' {
        @($script:rows).Count | Should -Be 2
    }

    It 'the source row states the rule the planner implements' {
        # "a size with a v6 or v7 size in the same family" is Microsoft's
        # #target-vm-families scope as recorded in the traceability map, and it
        # is what Test-VmfFamilyHasGeneration asks the catalogue.
        $source = @($script:rows | Where-Object { $_ -match 'Source sizes' })[0]
        $source | Should -Match '(?i)same family'
    }

    It 'and it does not claim a version range narrower than the product' {
        # The defect itself: "v4 and v5" excluded v2 and v3 sources that the
        # product migrates.
        $source = @($script:rows | Where-Object { $_ -match 'Source sizes' })[0]
        $source | Should -Not -Match '(?i)v4 and v5'
    }

    It 'the target row names Fasv7, which the old wording never did' {
        $target = @($script:rows | Where-Object { $_ -match 'Target sizes' })[0]
        $target | Should -Match 'Fasv7'
    }

    It 'and it says v7 depends on the region' {
        # A page that promises v7 everywhere would send somebody looking for a
        # size their region does not have.
        $target = @($script:rows | Where-Object { $_ -match 'Target sizes' })[0]
        $target | Should -Match '(?i)region'
    }
}

Describe 'MANUAL-SIZES-1: the rule the manual states is the one the code runs' {

    It 'the planner asks whether the family has the target generation' {
        # If this function goes, the manual sentence becomes a claim about
        # nothing - which is how the two came apart the first time.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $planner = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1')
        $planner | Should -Match 'function Test-VmfFamilyHasGeneration'
        $planner | Should -Match 'function Get-VmfSizeFamilyPrefix'
    }

    It 'and nothing in the planner gates on a source version' {
        # The manual no longer names a version range, so the code must not
        # either - otherwise the page is the honest one and the code is not.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $planner = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1')
        $planner | Should -Not -Match "-match '_v\[45\]'"
        $planner | Should -Not -Match "sourceVersion"
    }
}
