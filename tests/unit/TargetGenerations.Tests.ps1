#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GEN-V5-1: what a target size series IS, held as data read from Microsoft's
# pages, so nothing downstream guesses it from "is the controller NVMe".
#
# Every fact here was read on 2026-09-26:
#   - the fourteen D and E v5 size pages: Intel D sizes say accelerated
#     networking "Required", every other v5 page says "Supported"; Intel pages
#     list MANA among their interfaces and AMD pages do not; all support
#     Generation 1 and 2.
#   - DRIFT-5 (2026-10-02, Microsoft commit 0ce3ea9 of 2026-10-01): the Ev5,
#     Esv5, Edv5 and Edsv5 pages changed accelerated networking from
#     "Supported" to "Required". So every Intel D and E v5 size requires it
#     now, and the AMD v5 pages still say "Supported".
#   - "Modernize to the v5 VM series": "Enable Accelerated Networking on the
#     source VM before you resize to a series that requires it".
#   - "VM lifecycle overview": v6 and v7 are Current, v4 and v5 are Extended.
#
# Each rule is tested in BOTH directions, because the failure this item must
# not ship is a rule that only ever says yes (or only ever says no).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repoRoot = Join-Path $PSScriptRoot '..' '..'
    $script:dataFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json'
    $script:doc = Get-Content $script:dataFile -Raw | ConvertFrom-Json
}

Describe 'GEN-V5-1: the target series are data with their sources' {

    It 'the data format moved to version 2' {
        $script:doc.schemaVersion | Should -Be 2
    }

    It 'v5 is a target series of the D and E families, and only those' {
        @($script:doc.seriesByGeneration.v5) | Should -Be @('D', 'E')
    }

    It 'every target series has its traits: <Generation>' -ForEach @(
        @{ Generation = 'v5' }, @{ Generation = 'v6' }, @{ Generation = 'v7' }
    ) {
        $g = $script:doc.generations.$Generation
        $g | Should -Not -BeNullOrEmpty
        $g.controller | Should -BeIn @('SCSI', 'NVMe')
        @($g.hyperVGenerations).Count | Should -BeGreaterThan 0

        $g.PSObject.Properties.Name | Should -Contain 'acceleratedNetworkingRequired'
        $g.PSObject.Properties.Name | Should -Contain 'manaProcessors'
    }

    It 'the v5 traits are the ones the pages give' {
        $g = $script:doc.generations.v5
        $g.controller | Should -Be 'SCSI'
        @($g.hyperVGenerations) | Should -Contain 'V1'
        @($g.hyperVGenerations) | Should -Contain 'V2'

        @($g.manaProcessors) | Should -Be @('Intel')
    }

    It 'DRIFT-5: v5 requires accelerated networking on Intel D and Intel E, and on nothing else' {
        # Exactly these two rules: one more (AMD) would stop machines Microsoft
        # lets move with it off, and one fewer lets a machine with it off reach
        # a resize to a size whose page says Required.
        $rules = @($script:doc.generations.v5.acceleratedNetworkingRequired |
            ForEach-Object { "$($_.series)/$($_.processor)" } | Sort-Object)
        $rules | Should -Be @('D/Intel', 'E/Intel')
    }

    It 'DRIFT-5: the page the E v5 rule comes from is a named source, read on or after the change' {
        $src = @($script:doc.sources | Where-Object { $_.url -match '/memory-optimized/ev5-series$' })
        $src.Count | Should -Be 1
        [datetime]$src[0].readUtc | Should -BeGreaterOrEqual ([datetime]'2026-10-01')
        $src[0].says | Should -Match 'Required'
    }

    It 'v6 and v7 are NVMe, Generation 2 only, Current, and MANA on every processor' {
        foreach ($name in 'v6', 'v7') {
            $g = $script:doc.generations.$name
            $g.controller | Should -Be 'NVMe'
            @($g.hyperVGenerations) | Should -Be @('V2')

            @($g.manaProcessors) | Should -Contain 'Intel'
            @($g.manaProcessors) | Should -Contain 'AMD'
        }
        # DRIFT-11 (Microsoft commit 6c2b128, 2026-10-27): every D and E v6
        # page says Required; every v7 page still says Supported.
        @($script:doc.generations.v6.acceleratedNetworkingRequired).Count | Should -Be 4
        @($script:doc.generations.v7.acceleratedNetworkingRequired).Count | Should -Be 0
    }

    It 'the v5 guide, the lifecycle page and a v5 size page are named as sources' {
        $urls = @($script:doc.sources.url)
        $urls | Should -Contain 'https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/sizes-v5-modernization-overview'
        $urls | Should -Contain 'https://learn.microsoft.com/azure/virtual-machines/sizes/lifecycle/lifecycle-overview'
        ($urls | Where-Object { $_ -match 'dsv5-series$' }) | Should -Not -BeNullOrEmpty
    }
}

Describe 'GEN-V5-1: which series a size name is in' {

    It 'reads <Size> as <Expected>' -ForEach @(
        @{ Size = 'Standard_D2ds_v5';   Expected = 'v5' }
        @{ Size = 'Standard_E8-4ds_v5'; Expected = 'v5' }
        @{ Size = 'Standard_D2ds_v6';   Expected = 'v6' }
        @{ Size = 'Standard_D2as_v7';   Expected = 'v7' }
        @{ Size = 'Standard_D2s_v3';    Expected = 'v3' }
        @{ Size = 'Standard_D2';        Expected = $null }
        @{ Size = '';                   Expected = $null }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; expected = $Expected } {
            Get-VmfSizeGeneration -SizeName $size | Should -Be $expected
        }
    }

    It 'the controller a target series uses: v5 SCSI, v6 and v7 NVMe, anything else unknown' {
        InModuleScope VmMigrationFactory {
            Get-VmfGenerationController -Generation 'v5' | Should -Be 'SCSI'
            Get-VmfGenerationController -Generation 'v6' | Should -Be 'NVMe'
            Get-VmfGenerationController -Generation 'v7' | Should -Be 'NVMe'
            Get-VmfGenerationController -Generation 'v4' | Should -BeNullOrEmpty
        }
    }
}

Describe 'GEN-V5-1: accelerated networking a target size requires' {

    It '<Size> requires it: <Expected>' -ForEach @(
        @{ Size = 'Standard_D2s_v5';    Expected = $true }
        @{ Size = 'Standard_D2ds_v5';   Expected = $true }
        @{ Size = 'Standard_D2_v5';     Expected = $true }
        @{ Size = 'Standard_D2ls_v5';   Expected = $true }
        @{ Size = 'Standard_D2as_v5';   Expected = $false }
        @{ Size = 'Standard_D2ads_v5';  Expected = $false }
        # DRIFT-5: the four Intel E v5 pages say Required since 2026-10-01.
        @{ Size = 'Standard_E2_v5';     Expected = $true }
        @{ Size = 'Standard_E2s_v5';    Expected = $true }
        @{ Size = 'Standard_E2d_v5';    Expected = $true }
        @{ Size = 'Standard_E2ds_v5';   Expected = $true }
        @{ Size = 'Standard_E8-4ds_v5'; Expected = $true }
        @{ Size = 'Standard_E2as_v5';   Expected = $false }
        @{ Size = 'Standard_E2ads_v5';  Expected = $false }
        # DRIFT-11: every v6 size since 2026-10-27.
        @{ Size = 'Standard_E2ds_v6';   Expected = $true }
        @{ Size = 'Standard_D2ds_v6';   Expected = $true }
        @{ Size = 'Standard_E2ds_v7';   Expected = $false }
        @{ Size = 'Standard_D2s_v7';    Expected = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; expected = $Expected } {
            Test-VmfTargetRequiresAcceleratedNetworking -SizeName $size | Should -Be $expected
        }
    }

    It 'a size it cannot read gives no answer - not a no' {
        # "Does not require" would let a machine with it off reach a resize
        # Azure may refuse. Unknown must reach a person.
        InModuleScope VmMigrationFactory {
            foreach ($bad in 'nonsense', '', 'Standard_D2ds_v4') {
                $null -eq (Test-VmfTargetRequiresAcceleratedNetworking -SizeName $bad) |
                    Should -BeTrue -Because "'$bad' is not a size in a target series"
            }
        }
    }
}

Describe 'GEN-V5-1: whether a target size can give a machine MANA' {

    It '<Size> may use MANA: <Expected>' -ForEach @(
        @{ Size = 'Standard_D2ds_v5';   Expected = $true }
        @{ Size = 'Standard_E2s_v5';    Expected = $true }
        @{ Size = 'Standard_D2as_v5';   Expected = $false }
        @{ Size = 'Standard_E2ads_v5';  Expected = $false }
        @{ Size = 'Standard_D2ds_v6';   Expected = $true }
        @{ Size = 'Standard_D2as_v6';   Expected = $true }
        @{ Size = 'Standard_F2as_v7';   Expected = $true }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; expected = $Expected } {
            Test-VmfTargetMayUseMana -SizeName $size | Should -Be $expected
        }
    }

    It 'a size it cannot read gives no answer' {
        InModuleScope VmMigrationFactory {
            foreach ($bad in 'nonsense', '', 'Standard_D2ds_v4', 'Standard_D2aps_v6') {
                $null -eq (Test-VmfTargetMayUseMana -SizeName $bad) | Should -BeTrue -Because "'$bad' cannot be read"
            }
        }
    }
}

Describe 'GEN-V5-1: the scope check accepts v5 as a target series' {

    It 'an Intel and an AMD v5 size are approved' {
        InModuleScope VmMigrationFactory {
            (Test-VmfSizeApprovedTarget -SizeName 'Standard_D2ds_v5' -TargetGeneration 'v5').Approved | Should -BeTrue
            (Test-VmfSizeApprovedTarget -SizeName 'Standard_E4as_v5' -TargetGeneration 'v5').Approved | Should -BeTrue
        }
    }

    It 'an Arm64, a confidential and an F v5 size are not' {
        InModuleScope VmMigrationFactory {
            (Test-VmfSizeApprovedTarget -SizeName 'Standard_D2ps_v5' -TargetGeneration 'v5').Approved | Should -BeFalse
            (Test-VmfSizeApprovedTarget -SizeName 'Standard_DC2as_v5' -TargetGeneration 'v5').Approved | Should -BeFalse
            (Test-VmfSizeApprovedTarget -SizeName 'Standard_F2s_v5' -TargetGeneration 'v5').Approved | Should -BeFalse
        }
    }
}

Describe 'GEN-V5-1: the lifecycle stage of every source and target series' {

    # Since 2026-09-26, the advisor shows these terms for each size a machine
    # moves from and to. Microsoft says the stage differs by family, so the
    # data names a family, a basis and the page it was read from.

    It '<Size> is <Stage> (<Basis>)' -ForEach @(
        @{ Size = 'Standard_D2s_v3';    Stage = 'End of Life'; Basis = 'stated' }
        @{ Size = 'Standard_D2_v2';     Stage = 'End of Life'; Basis = 'stated' }
        @{ Size = 'Standard_E4s_v3';    Stage = 'End of Life'; Basis = 'stated' }
        @{ Size = 'Standard_D2ds_v4';   Stage = 'Extended';    Basis = 'stated' }
        @{ Size = 'Standard_D2as_v4';   Stage = 'Extended';    Basis = 'stated' }
        @{ Size = 'Standard_D2ds_v5';   Stage = 'Extended';    Basis = 'stated' }
        @{ Size = 'Standard_E8-4ds_v5'; Stage = 'Extended';    Basis = 'stated' }
        @{ Size = 'Standard_E4ds_v4';   Stage = 'Extended';    Basis = 'derived' }
        @{ Size = 'Standard_D2ds_v6';   Stage = 'Current';     Basis = 'stated' }
        @{ Size = 'Standard_E2as_v7';   Stage = 'Current';     Basis = 'stated' }
        @{ Size = 'Standard_F2as_v7';   Stage = 'Current';     Basis = 'derived' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size; stage = $Stage; basis = $Basis } {
            $r = Get-VmfSizeLifecycleStage -SizeName $size
            $r.Stage | Should -Be $stage
            $r.Basis | Should -Be $basis
        }
    }

    It 'a derived stage says how it was derived' {
        foreach ($row in @($script:doc.lifecycle.bySeries | Where-Object basis -eq 'derived')) {
            [string]$row.how | Should -Not -BeNullOrEmpty
        }
    }

    It 'a series the data does not cover has no stage - never a guess' {
        # Microsoft: "For other families, check the family page". An L or M
        # machine is not in this table, and "Extended" would be invented.
        # ADVISOR-1 took Standard_D2 off this list: Microsoft's End of Life
        # list names the original D-series, so it now has a stated stage
        # (TargetAdvice.Tests.ps1). A B-series size stood in for it: Bsv2, since OLD-FAM-1 gave B v1 its stated End of Life stage.
        # BSV2-TARGET-1 gave Bsv2 its derived Current stage, so a GPU size stands in now.
        InModuleScope VmMigrationFactory {
            foreach ($other in 'Standard_L8s_v3', 'Standard_M8ms', 'Standard_NC6s_v3', 'nonsense', '') {
                Get-VmfSizeLifecycleStage -SizeName $other | Should -BeNullOrEmpty -Because "'$other' is not in the table"
            }
        }
    }

    It 'the v3 retirement date is held, from Microsoft''s End of Life list' {
        $r = @($script:doc.lifecycle.retirements)[0]
        @($r.series) | Should -Be @('Dv3', 'Dsv3', 'Ev3', 'Esv3')
        $r.retiresUtc | Should -Be '2029-11-15'
    }

    It 'every page a stage rests on is a named source AND is watched by the drift check' {
        # Since 2026-09-26, the drift check tracks these pages. A stage read
        # from a page nobody watches becomes wrong without anybody knowing.
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        $cited = @($script:doc.lifecycle.bySeries.source) + @($script:doc.lifecycle.retirements.source) | Select-Object -Unique
        $cited.Count | Should -BeGreaterThan 0
        foreach ($name in $cited) {
            @($script:doc.sources.url | Where-Object { $_ -match "/$([regex]::Escape($name))$" }).Count |
                Should -Be 1 -Because "'$name' must be one of the data file's sources"
            # DOCS-DRIFT-LEARN-1: a watched page is named by its Learn page, with no file extension.
            $pinned | Should -Contain $name -Because "'$name' must be watched"
        }
    }

    It 'the D and E family pages are watched - Microsoft says a family''s stage is read there' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        $pinned | Should -Contain 'd-family'
        $pinned | Should -Contain 'e-family'
    }

    It 'and so are the v5 spec files the MANA fact comes from' {
        # DOCS-DRIFT-LEARN-1: Learn has no page for a spec file; it serves the
        # size page with the spec file expanded in place. So each spec file is
        # watched THROUGH the size page that includes it, and that page must be
        # pinned.
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        foreach ($spec in 'dsv5-series-specs', 'ddsv5-series-specs', 'dasv5-series-specs', 'esv5-series-specs', 'easv5-series-specs') {
            $holder = @($watch.folders | Where-Object { $_.PSObject.Properties['includes'] -and @($_.includes.name) -contains $spec })
            $holder.Count | Should -Be 1 -Because "$spec must be listed as an include"
            $page = @($holder[0].includes | Where-Object { $_.name -eq $spec })[0].includedIn
            @($holder[0].pages.name) | Should -Contain $page -Because "$spec is watched through $page"
        }
    }
}
