#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRIFT-12 (upstream drift issue 918): Microsoft's naming conventions page
# (learn.microsoft.com/azure/virtual-machines/vm-naming-conventions, read
# 2026-11-12) added "H = High core density" to the SUBFAMILY row. A subfamily
# letter is upper case and sits after the family letter, before the vCPU count
# (the C of DC and EC is one). It is not a lower case additive feature letter.
#
# The product reads size names in several places. These tests prove that a
# size with the subfamily letter H (Standard_DH16s_v7, a shape the page allows;
# no such size is in the catalog the product reads today) is:
#   - never read as AMD, Arm64 or an isolated size;
#   - never offered as a target: its family reads as DH, which no target
#     series lists, and the saved catalog does not keep it;
#   - never taken for the H family (HPC), which the product refuses as a
#     source - and a real source keeps its answer.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'DRIFT-12: the subfamily letter H is read as part of the family' {
    It '<Size> reads as family <Family>' -ForEach @(
        @{ Size = 'Standard_DH16s_v7'; Family = 'DH' }
        @{ Size = 'Standard_EH8ds_v6'; Family = 'EH' }
        @{ Size = 'Standard_DH16as_v7'; Family = 'DH' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size) Get-VmfSizeFamilyPrefix -SizeName $size
        } | Should -BeExactly $Family
    }

    It '<Size> runs on <Processor>' -ForEach @(
        @{ Size = 'Standard_DH16s_v7'; Processor = 'Intel' }
        @{ Size = 'Standard_EH8ds_v6'; Processor = 'Intel' }
        @{ Size = 'Standard_DH16as_v7'; Processor = 'AMD' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size) Get-VmfSizeProcessor -SizeName $size
        } | Should -BeExactly $Processor
    }

    It '<Size> is not an isolated size' -ForEach @(
        @{ Size = 'Standard_DH16s_v7' }, @{ Size = 'Standard_EH8ds_v6' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size) Test-VmfIsolatedSize -SizeName $size
        } | Should -BeFalse
    }
}

Describe 'DRIFT-12: a size with the subfamily letter H is never a target' {
    It '<Size> is not approved on <Gen>, because no target series lists its family' -ForEach @(
        @{ Size = 'Standard_DH16s_v7'; Gen = 'v7' }
        @{ Size = 'Standard_EH8ds_v6'; Gen = 'v6' }
        @{ Size = 'Standard_DH16ds_v5'; Gen = 'v5' }
    ) {
        $r = InModuleScope VmMigrationFactory -Parameters @{ size = $Size; gen = $Gen } {
            param($size, $gen) Test-VmfSizeApprovedTarget -SizeName $size -TargetGeneration $gen -SourceSize 'Standard_D16ds_v4'
        }
        $r.Approved | Should -BeFalse
        $r.Why | Should -Match '^series:'
    }

    It 'the saved catalog keeps D, E and F target sizes and drops the DH and EH sizes' {
        $kept = InModuleScope VmMigrationFactory {
            $skus = foreach ($n in 'Standard_D16ds_v6', 'Standard_DH16s_v7', 'Standard_EH8ds_v6', 'Standard_E8s_v7') {
                [pscustomobject]@{ Name = $n; Family = 'x'; Capabilities = @() }
            }
            @(Get-VmfTargetCatalogSubset -Skus $skus | ForEach-Object { $_.name })
        }
        $kept | Should -Be @('Standard_D16ds_v6', 'Standard_E8s_v7')
    }

    It 'the default transform of a D source never names a DH size, even when the region has one' {
        $r = InModuleScope VmMigrationFactory {
            $cap = { param($v, $nics, $disks) @([pscustomobject]@{ Name = 'vCPUs'; Value = "$v" }, [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = "$nics" },
                    [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = "$disks" }, [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '64' }) }
            $catalog = @{
                'Standard_DH16s_v7' = [pscustomobject]@{ Name = 'Standard_DH16s_v7'; Capabilities = (& $cap 16 8 32) }
                'Standard_D16s_v4' = [pscustomobject]@{ Name = 'Standard_D16s_v4'; Capabilities = (& $cap 16 8 32) }
            }
            Get-VmfTargetSize -SourceSize 'Standard_D16s_v4' -CatalogBySize $catalog -TargetGeneration 'v7'
        }
        $r.Target | Should -Not -Be 'Standard_DH16s_v7'
        @($r.Alternates) | Should -Not -Contain 'Standard_DH16s_v7'
    }
}

Describe 'DRIFT-12: the subfamily letter H is not the H family' {
    It '<Size> is not refused as an HPC size' -ForEach @(
        @{ Size = 'Standard_DH16s_v5' }, @{ Size = 'Standard_EH8ds_v4' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size) Get-VmfUnsupportedFamilyCode -SizeName $size
        } | Should -BeNullOrEmpty
    }

    It 'the H family is still refused: <Size>' -ForEach @(
        @{ Size = 'Standard_HB120rs_v3' }, @{ Size = 'Standard_H16r' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size) Get-VmfUnsupportedFamilyCode -SizeName $size
        } | Should -Be 'hpc-or-fpga-size'
    }

    It 'a real source keeps its answer: <Size> is <Processor>, family <Family>, not refused' -ForEach @(
        @{ Size = 'Standard_D16ds_v4'; Processor = 'Intel'; Family = 'D' }
        @{ Size = 'Standard_E8as_v5'; Processor = 'AMD'; Family = 'E' }
        @{ Size = 'Standard_F8s_v2'; Processor = 'Intel'; Family = 'F' }
    ) {
        $got = InModuleScope VmMigrationFactory -Parameters @{ size = $Size } {
            param($size) @{ p = Get-VmfSizeProcessor -SizeName $size; f = Get-VmfSizeFamilyPrefix -SizeName $size; c = Get-VmfUnsupportedFamilyCode -SizeName $size }
        }
        $got.p | Should -BeExactly $Processor
        $got.f | Should -BeExactly $Family
        $got.c | Should -BeNullOrEmpty
    }
}

Describe 'DRIFT-12: the naming source entry says what the page says now' {
    It 'names H as a subfamily letter, and the date it was read' {
        $doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $src = @($doc.sources | Where-Object { $_.url -eq 'https://learn.microsoft.com/azure/virtual-machines/vm-naming-conventions' })
        $src.Count | Should -Be 1
        $src[0].readUtc | Should -Be '2026-11-12'
        $src[0].says | Should -Match 'subfamily letter H is high core density'
    }
}
