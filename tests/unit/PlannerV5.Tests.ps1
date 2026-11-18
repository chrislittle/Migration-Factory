#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# GEN-V5-1 C2: the planner chooses v5 target sizes.
#
# Microsoft's v5 guide (read 2026-09-26) is what these tests hold the planner to:
#   - the v5 targets are the D and E families, Intel and AMD;
#   - "Every v3 size includes a local temporary disk. If the workload uses it,
#     choose a d-suffixed target size" (the v6/v7 plan page), and the v5 guide:
#     "Select a d variant when the workload requires local scratch space";
#   - the D and E v5 series take Generation 1 AND Generation 2 machines.
#
# The d variant is chosen FIRST for a source with a temporary disk, and the
# plain size is kept as the alternate. The reason is the product's own: on
# Windows, a move that loses the temporary disk changes disk architecture, which
# Azure refuses as a resize - so the plain size would force a rebuild (Path B)
# on the move whose whole point is being the less disruptive one.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function New-Sku {
        param([string]$Name, [object]$TempMb = $null, [string]$Gens = 'V1,V2')
        $caps = @([pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' },
                  [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' })
        if ($null -ne $TempMb) { $caps += [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$TempMb } }
        if ($Gens) { $caps += [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens } }
        [pscustomobject]@{ Name = $Name; Capabilities = $caps }
    }

    $script:catalog = @{}
    foreach ($sku in @(
            (New-Sku 'Standard_D2s_v3' 16384), (New-Sku 'Standard_D2_v3' 51200), (New-Sku 'Standard_E2s_v3' 32768),
            (New-Sku 'Standard_D2ds_v4' 76800), (New-Sku 'Standard_D2s_v4' 0), (New-Sku 'Standard_D2as_v4' 16384),
            (New-Sku 'Standard_D2ds_v5' 76800), (New-Sku 'Standard_D2s_v5' 0), (New-Sku 'Standard_D2d_v5' 76800),
            (New-Sku 'Standard_D2_v5' 0), (New-Sku 'Standard_E2ds_v5' 76800), (New-Sku 'Standard_E2s_v5' 0),
            (New-Sku 'Standard_D2as_v5' 0), (New-Sku 'Standard_D2ads_v5' 76800),
            (New-Sku 'Standard_D2ds_v6' 0 'V2'), (New-Sku 'Standard_D2s_v6' 0 'V2'))) {
        $script:catalog[$sku.Name] = $sku
    }
}

Describe 'GEN-V5-1 C2: the default transform onto v5' {

    It 'a v4 d size goes to the same v5 d size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v5').Target | Should -Be 'Standard_D2ds_v5'
        }
    }

    It 'a v4 size with no temporary disk keeps none' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $c -TargetGeneration 'v5').Target | Should -Be 'Standard_D2s_v5'
        }
    }

    It 'a v3 size, which has a temporary disk, goes to the d size first: <Source> -> <Expected>' -ForEach @(
        @{ Source = 'Standard_D2s_v3'; Expected = 'Standard_D2ds_v5'; Plain = 'Standard_D2s_v5' }
        @{ Source = 'Standard_D2_v3';  Expected = 'Standard_D2d_v5';  Plain = 'Standard_D2_v5' }
        @{ Source = 'Standard_E2s_v3'; Expected = 'Standard_E2ds_v5'; Plain = 'Standard_E2s_v5' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; source = $Source; expected = $Expected; plain = $Plain } {
            $r = Get-VmfTargetSize -SourceSize $source -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be $expected
            @($r.Alternates) | Should -Contain $plain -Because 'the size with no temporary disk stays an alternate'
        }
    }

    It 'an AMD v4 size with a temporary disk goes to the AMD d size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2as_v4' -CatalogBySize $c -TargetGeneration 'v5').Target | Should -Be 'Standard_D2ads_v5'
        }
    }

    It 'and falls back to the plain size when the region has no d size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $noD = @{} + $c
            $noD.Remove('Standard_D2ds_v5')
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v3' -CatalogBySize $noD -TargetGeneration 'v5').Target | Should -Be 'Standard_D2s_v5'
        }
    }

    It 'on v6 a v3 size goes to the d size too: Standard_D2s_v3 -> Standard_D2ds_v6, then Standard_D2s_v6' {
        # This pinned D2s_v3 -> D2s_v6 on purpose: the v6 choice for v3 was
        # left to V3-TEMPDISK-1. It was decided on 2026-10-03 - the d size
        # Microsoft's v3 table names first, as on v5 - so the rule changed here.
        # The whole v3 table is measured in V3TempDisk.Tests.ps1.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D2ds_v6'
            @($r.Alternates) | Should -Contain 'Standard_D2s_v6'
        }
    }

    It 'an Arm64 machine is refused on v5 too, and told why' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ps_v4' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Arm64'
            $r.Reason | Should -Match 'v5'
        }
    }
}

Describe 'GEN-V5-1 C2: a Generation 1 machine gets a size that takes Generation 1' {

    It 'a v5 size that lists V1 is chosen' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v5' -HyperVGeneration 'V1').Target |
                Should -Be 'Standard_D2ds_v5'
        }
    }

    It 'a size that lists only V2 is refused, and the reason says Generation 1' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v6' -HyperVGeneration 'V1'
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Generation 1'
        }
    }

    It 'a Generation 2 machine is not held to it' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v6' -HyperVGeneration 'V2').Target |
                Should -Be 'Standard_D2ds_v6'
        }
    }

    It 'a size whose generations Azure did not report is chosen but marked unverified - not refused, not passed silently' {
        InModuleScope VmMigrationFactory {
            $sku = [pscustomobject]@{ Name = 'Standard_D2ds_v5'; Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' }) }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize @{ 'Standard_D2ds_v5' = $sku } -TargetGeneration 'v5' -HyperVGeneration 'V1'
            $r.Target | Should -Be 'Standard_D2ds_v5'
            $r.Reason | Should -Match 'could not be verified'
            $r.Reason | Should -Match 'Generation 1'
        }
    }
}

Describe 'GEN-V5-1 C2: a v5 d size is a SCSI temporary disk' {

    It '<Size> with no catalog reading is <Expected>' -ForEach @(
        @{ Size = 'Standard_D2ds_v5'; Expected = 'scsi-temp' }
        @{ Size = 'Standard_D2ds_v4'; Expected = 'scsi-temp' }
        @{ Size = 'Standard_E8-4ds_v5'; Expected = 'scsi-temp' }
        @{ Size = 'Standard_D2ds_v6'; Expected = 'nvme-temp' }
        @{ Size = 'Standard_D2ds_v7'; Expected = 'nvme-temp' }
        @{ Size = 'Standard_D2s_v5';  Expected = 'diskless' }
    ) {
        # Before this, a v5 d size with no catalog reading was called
        # nvme-temp - true of v6 and v7 only. v5 has no NVMe at all.
        Get-VmfDiskArchitecture -SizeName $Size -MaxResourceVolumeMB $null | Should -Be $Expected
    }

    It 'the catalog still wins where it has a reading' {
        Get-VmfDiskArchitecture -SizeName 'Standard_D2s_v3' -MaxResourceVolumeMB 16384 | Should -Be 'scsi-temp'
        Get-VmfDiskArchitecture -SizeName 'Standard_D2ds_v6' -MaxResourceVolumeMB 0 | Should -Be 'nvme-temp'
    }
}

Describe 'GEN-V5-1 C2: the path a v5 move takes' {

    BeforeAll {
        function script:Win { param($Size, $Arch, $Controller = 'SCSI')
            [pscustomobject]@{ vmId = 'x'; sourceSize = $Size; os = 'Windows'; classification = 'Ready'; sourceDiskArch = $Arch
                diskController = $Controller; nicCount = 1; dataDiskCount = 0; hyperVGeneration = 'V2' } }
    }

    It 'Windows, v4 d to v5 d: a resize (Path A) - the temporary disk stays SCSI' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; vm = (Win 'Standard_D2ds_v4' 'scsi-temp') } {
            $r = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $r.Mapping.Target | Should -Be 'Standard_D2ds_v5'
            $r.DiskArch | Should -Be 'scsi-temp'
            $r.Path | Should -Be 'A'
        }
    }

    It 'Windows, v3 to v5: a resize too, because the d size keeps the temporary disk' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; vm = (Win 'Standard_D2s_v3' 'scsi-temp') } {
            $r = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $r.Mapping.Target | Should -Be 'Standard_D2ds_v5'
            $r.Path | Should -Be 'A'
        }
    }

    It 'the same v4 machine on a v6 wave is the in-place upgrade (Preview), no longer a rebuild (REBUILD-REMOVE-PLAN-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; vm = (Win 'Standard_D2ds_v4' 'scsi-temp') } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').Path | Should -Be 'A'
        }
    }

    It 'a machine already on v5 has nothing to do on a v5 wave' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; vm = (Win 'Standard_D2ds_v5' 'scsi-temp') } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5').Path | Should -Be 'EXCLUDED'
        }
    }

    It 'a machine on NVMe is still excluded from a v6 wave, as before' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; vm = (Win 'Standard_D2ds_v6' 'nvme-temp' 'NVMe') } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').Path | Should -Be 'EXCLUDED'
        }
    }

    It 'a Generation 1 machine is held to a size that takes it, through the plan too' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:catalog; vm = (Win 'Standard_D2ds_v4' 'scsi-temp') } {
            $vm.hyperVGeneration = 'V1'
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').Mapping.Target | Should -BeNullOrEmpty
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5').Mapping.Target | Should -Be 'Standard_D2ds_v5'
        }
    }
}

Describe 'GEN-V5-1 C2: the family check knows v5' {

    It 'a D machine is in the path for a v5 wave where the region has D v5 sizes only' {
        InModuleScope VmMigrationFactory {
            $only5 = @{ 'Standard_D2s_v5' = [pscustomobject]@{ Name = 'Standard_D2s_v5' } }
            Test-VmfFamilyHasGeneration -SourceSize 'Standard_D2s_v4' -CatalogBySize $only5 -TargetGeneration 'v5' | Should -BeTrue
        }
    }
}
