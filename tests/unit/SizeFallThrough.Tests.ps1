#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SIZE-FALLTHROUGH-TEST-1: the default transform tries its sizes in order.
#
# Get-VmfDefaultSizeCandidates gives a machine with a temporary disk two sizes:
# the d size first, then the size without one (Standard_D4s_v3 -> D4ds_v6, then
# D4s_v6). Get-VmfTargetSize takes the first size that passes every gate. The
# size-map tests that showed a later size being taken went with the size map
# (SIZEMAP-REMOVE-1). What was still tested, found before this file:
#   - the d size missing from the region catalog (V3TempDisk "a region with no
#     d size", PlannerV5 "falls back to the plain size");
#   - the d size smaller than the machine (SizeFit "a smaller first candidate").
# Not tested before: the data disk gate, the network interface gate, the
# Generation 1 gate and the accelerated networking gate on the first size,
# nor what the plan records for the size it falls through to.
#
# The catalogs below are made for each gate. In Azure the d size and the size
# without one have the same limits, so most of these cannot happen with real
# sizes; they hold the loop to its rule, which a later size table can need.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:FtSku {
        param([string]$Name, [int]$Vcpus = 4, [double]$Gb = 16, [object]$TempMb = 0, [string]$Gens = 'V2',
              [int]$Nics = 4, [int]$Disks = 16, [int]$NvmeDisks = 0)
        $caps = @(
            [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$Gb }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = [string]$Nics }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = [string]$Disks }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
            [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' }
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$TempMb })
        if ($NvmeDisks -gt 0) {
            $caps += [pscustomobject]@{ Name = 'NvmeDiskSizeInMiB'; Value = [string](225280 * $NvmeDisks) }
            $caps += [pscustomobject]@{ Name = 'NvmeSizePerDiskInMiB'; Value = '225280' }
        }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }

    # The machine: Standard_D4s_v3 (4 vCPUs, 16 GiB, a temporary disk). Its
    # sizes, in the order the default transform tries them, on v6 and on v5.
    # -D and -Plain replace the d size or the size without one.
    function Global:FtCatalog {
        param($D6, $Plain6, $D5, $Plain5, [switch]$NoD6, [switch]$NoD5)
        $c = @{}
        $c['Standard_D4s_v3'] = FtSku 'Standard_D4s_v3' 4 16 16384 'V1,V2'
        $c['Standard_D2s_v3'] = FtSku 'Standard_D2s_v3' 2 8 16384 'V1,V2'
        if (-not $NoD6) { $c['Standard_D4ds_v6'] = $(if ($D6) { $D6 } else { FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -NvmeDisks 1 }) }
        $c['Standard_D4s_v6'] = $(if ($Plain6) { $Plain6 } else { FtSku 'Standard_D4s_v6' 4 16 0 'V2' })
        if (-not $NoD5) { $c['Standard_D4ds_v5'] = $(if ($D5) { $D5 } else { FtSku 'Standard_D4ds_v5' 4 16 153600 'V1,V2' }) }
        $c['Standard_D4s_v5'] = $(if ($Plain5) { $Plain5 } else { FtSku 'Standard_D4s_v5' 4 16 0 'V1,V2' })
        # Other D v6 and v5 sizes, so the region has the family.
        $c['Standard_D8ds_v6'] = FtSku 'Standard_D8ds_v6' 8 32 0 'V2' -NvmeDisks 1
        $c['Standard_D8s_v6'] = FtSku 'Standard_D8s_v6' 8 32 0 'V2'
        $c
    }

    function Global:FtVm {
        param([string]$Size = 'Standard_D4s_v3', [string]$Os = 'Windows', [int]$Disks = 1, [int]$Nics = 1,
              [object]$AcceleratedNics = 1, [string]$Gen = 'V2')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-01"
            name = 'app-01'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; hyperVGeneration = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1
            diskController = 'SCSI'; dataDiskCount = $Disks; nicCount = $Nics
            acceleratedNicCount = $AcceleratedNics; primaryNicAccelerated = $true
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''
            identityType = 'None'; tags = @{}; blockers = @(); prepNeeded = @(); zones = @()
        }
    }
}
AfterAll { Remove-Item 'function:\FtSku', 'function:\FtCatalog', 'function:\FtVm' -ErrorAction SilentlyContinue }

Describe 'SIZE-FALLTHROUGH-TEST-1: the order the default transform tries' {

    It 'with every gate passed, the d size is the target and the size without one is the alternate' {
        # The control for every test below: the same machine and catalog, and
        # only the one change each test makes.
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredDataDisks 6 -RequiredNics 3
            $r.Target | Should -Be 'Standard_D4ds_v6'
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @('Standard_D4s_v6')
        }
    }
}

Describe 'SIZE-FALLTHROUGH-TEST-1: the first size fails a gate, and the next size is the target' {

    It 'the d size holds too few data disks: the size without one is the target' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredDataDisks 6
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.Code | Should -Be 'mapped'
            $r.Reason | Should -Be 'default-transform'
            @($r.Alternates) | Should -Be @('Standard_D4ds_v6') -Because 'the size it fell through stays in the record as the other size'
        }
    }

    It 'the d size holds too few network interfaces: the size without one is the target' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -Nics 2 -NvmeDisks 1)) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 3
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @('Standard_D4ds_v6')
        }
    }

    It 'the d size is not in the region catalog: the size without one is the target' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog -NoD6) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @('Standard_D4ds_v6')
        }
    }

    It 'a Generation 1 machine, and the v5 d size does not take Generation 1: the v5 size without one is the target' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog -D5 (FtSku 'Standard_D4ds_v5' 4 16 153600 'V2')) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v5' -HyperVGeneration 'V1'
            $r.Target | Should -Be 'Standard_D4s_v5'
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @('Standard_D4ds_v5')
        }
    }

    It 'the d size is smaller than the machine: the size without one is the target' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 8 0 'V2' -NvmeDisks 1)) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be 'Standard_D4s_v6'
            $r.Code | Should -Be 'mapped'
        }
    }

    It 'two interfaces with accelerated networking, and the d size has 2 vCPUs: the size without one is the target' {
        # Standard_D2s_v3: 2 vCPUs. The size without a temporary disk is given
        # 4 vCPUs here so it passes; the gate is what is under test.
        $c = FtCatalog
        $c['Standard_D2ds_v6'] = FtSku 'Standard_D2ds_v6' 2 8 0 'V2' -NvmeDisks 1
        $c['Standard_D2s_v6'] = FtSku 'Standard_D2s_v6' 4 16 0 'V2'
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 2 -AcceleratedNicsAfter 2
            $r.Target | Should -Be 'Standard_D2s_v6'
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @('Standard_D2ds_v6')
        }
    }
}

Describe 'SIZE-FALLTHROUGH-TEST-1: when no size passes, the refusal names every size tried' {

    It 'both sizes hold too few data disks: the refusal names both, in order' {
        $c = FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1) -Plain6 (FtSku 'Standard_D4s_v6' 4 16 0 'V2' -Disks 4)
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredDataDisks 6
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'too-few-data-disks'
            $r.Reason | Should -Match ([regex]::Escape('Standard_D4ds_v6 holds 4 data disks; Standard_D4s_v6 holds 4 data disks'))
        }
    }

    It 'the d size fails one gate and the other size another: the refusal names both' {
        $c = FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -Nics 2 -NvmeDisks 1) -Plain6 (FtSku 'Standard_D4s_v6' 4 16 0 'V2' -Disks 4)
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 3 -RequiredDataDisks 6
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Standard_D4ds_v6 holds 2'
            $r.Reason | Should -Match 'Standard_D4s_v6 holds 4 data disks'
        }
    }
}

Describe 'SIZE-FALLTHROUGH-TEST-1: what the plan and the targets step get for the size it falls through to' {

    It 'the machine''s target is the size without a temporary disk, with no temporary disk, and the d size as the alternate' {
        $c = FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = $c; vm = (FtVm -Disks 6) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            $t.Mapping.Target | Should -Be 'Standard_D4s_v6'
            @($t.Mapping.Alternates) | Should -Be @('Standard_D4ds_v6')
            $t.DiskArch | Should -Be 'diskless'
            $t.TempDisks | Should -Be 0 -Because 'the plan entry compares this with sourceTempDisks (TEMPPOOL-1), and that is how the plan shows the temporary disk goes'
        }
    }

    It 'on v5, a Windows machine that falls through to the size without a temporary disk takes the in-place upgrade (Preview), never a plain resize (REBUILD-REMOVE-PLAN-1)' {
        $c = FtCatalog -D5 (FtSku 'Standard_D4ds_v5' 4 16 153600 'V1,V2' -Disks 4)
        InModuleScope VmMigrationFactory -Parameters @{ c = $c; vm = (FtVm -Disks 6) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $t.Mapping.Target | Should -Be 'Standard_D4s_v5'
            $t.Path | Should -Be 'A' -Because 'the size without a temporary disk changes the disk architecture, which Azure allows on Windows only with the preview feature'; $t.Preview | Should -BeTrue
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (FtCatalog); vm = (FtVm -Disks 6) } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5').Path | Should -Be 'A' -Because 'the control: the d size keeps the move in place'
        }
    }

    It 'the targets step shows the size it falls through to, and that the machine has no temporary disk after the move' {
        $c = FtCatalog -D6 (FtSku 'Standard_D4ds_v6' 4 16 0 'V2' -Disks 4 -NvmeDisks 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = $c; vm = (FtVm -Disks 6) } {
            $opt = Get-VmfAdviceOption -Vm $vm -Series 'v6' -RegionCatalog $c
            $opt.targetSize | Should -Be 'Standard_D4s_v6'
            $opt.tempDisksTo | Should -Be 0
            @($opt.notSupported) | Should -BeNullOrEmpty
        }
    }
}
