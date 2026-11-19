#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V3-TEMPDISK-1: a v3 machine keeps its temporary disk on v6 and v7.
#
# Microsoft's v6/v7 plan page, section "Retiring v3 workloads" (read
# 2026-10-03, held in data/target-families.json replacements): Dv3 and Dsv3 go
# to Dsv6, Ddsv6, Dasv6 or Dadsv6 (v7 likewise), Ev3 and Esv3 to the E sizes
# with the same letters, and "Every v3 size includes a local temporary disk. If
# the workload uses it, choose" a d size.
#
# What the planner did before, measured on this branch's parent:
#   - D4s_v3 -> D4s_v6, which has no temporary disk;
#   - D4_v3  -> tried only Standard_D4_v6, a size that does not exist, and
#     ended "no candidate available in region" - a naming problem reported as
#     a shortage in the region.
# The decision: the d size Microsoft names first, the size without a
# temporary disk as the other choice - what v5 already did (GEN-V5-1).
#
# The catalog below holds the sizes Microsoft's series pages list (Ddsv6,
# Edsv6, read 2026-10-03) with their vCPUs and memory, and every v3 size.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:V3Sku {
        param([string]$Name, [int]$Vcpus, [double]$Gb, [object]$TempMb = 0, [string]$Gens = 'V2', [int]$NvmeDisks = 0)
        $caps = @(
            [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = ([string]$Gb) }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '16' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
            [pscustomobject]@{ Name = 'PremiumIO'; Value = 'True' })
        if ($null -ne $TempMb) { $caps += [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$TempMb } }
        if ($NvmeDisks -gt 0) {
            $caps += [pscustomobject]@{ Name = 'NvmeDiskSizeInMiB'; Value = [string](225280 * $NvmeDisks) }
            $caps += [pscustomobject]@{ Name = 'NvmeSizePerDiskInMiB'; Value = '225280' }
        }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }

    # Every v3 size Microsoft lists (32): name, vCPUs, memory.
    $script:v3 = @(
        @('D2', 2, 8), @('D4', 4, 16), @('D8', 8, 32), @('D16', 16, 64), @('D32', 32, 128), @('D48', 48, 192), @('D64', 64, 256)
    )
    $script:e3 = @(
        @('E2', 2, 16), @('E4', 4, 32), @('E8', 8, 64), @('E16', 16, 128), @('E20', 20, 160), @('E32', 32, 256), @('E48', 48, 384), @('E64', 64, 432)
    )

    function Global:V3Catalog([switch]$NoD, [switch]$NoS, [switch]$V7, [switch]$NoV7) {
        $c = @{}
        $add = { param($s) $c[$s.Name] = $s }
        foreach ($r in $script:v3) {
            & $add (V3Sku "Standard_$($r[0])_v3" $r[1] $r[2] 51200 'V1,V2')
            & $add (V3Sku "Standard_$($r[0])s_v3" $r[1] $r[2] 16384 'V1,V2')
        }
        foreach ($r in $script:e3) {
            & $add (V3Sku "Standard_$($r[0])_v3" $r[1] $r[2] 51200 'V1,V2')
            & $add (V3Sku "Standard_$($r[0])s_v3" $r[1] $r[2] 32768 'V1,V2')
        }
        & $add (V3Sku 'Standard_E64i_v3' 64 432 51200 'V1,V2')
        & $add (V3Sku 'Standard_E64is_v3' 64 432 32768 'V1,V2')
        $gens = @('v6') + $(if ($V7) { @('v7') } else { @() })
        foreach ($g in $gens) {
            foreach ($n in 2, 4, 8, 16, 32, 48, 64, 96, 128, 192) {
                if (-not $NoD) { & $add (V3Sku "Standard_D$($n)ds_$g" $n (4 * $n) 0 'V2' 1) }
                if (-not $NoS) { & $add (V3Sku "Standard_D$($n)s_$g" $n (4 * $n) 0 'V2') }
            }
            foreach ($n in 2, 4, 8, 16, 20, 32, 48, 64, 96, 128) {
                if (-not $NoD) { & $add (V3Sku "Standard_E$($n)ds_$g" $n (8 * $n) 0 'V2' 1) }
                if (-not $NoS) { & $add (V3Sku "Standard_E$($n)s_$g" $n (8 * $n) 0 'V2') }
            }
            if (-not $NoD) { & $add (V3Sku "Standard_E192ids_$g" 192 1832 0 'V2' 1) }
        }
        # v5, for the v5 rows: the D sizes with and without s, d and not.
        foreach ($n in 2, 4) {
            foreach ($l in 'ds', 's', 'd', '') { & $add (V3Sku "Standard_D$($n)$($l)_v5" $n (4 * $n) $(if ($l -like '*d*') { 76800 } else { 0 }) 'V1,V2') }
        }
        $c
    }
    function Global:V3Vm {
        param([string]$Size = 'Standard_D4s_v3', [string]$Os = 'Windows', [string]$Name = 'web-07')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = 'V2'; hyperVGeneration = 'V2'
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
}
AfterAll { Remove-Item 'function:\V3Sku', 'function:\V3Catalog', 'function:\V3Vm' -ErrorAction SilentlyContinue }

Describe 'V3-TEMPDISK-1: the data is Microsoft''s table, with its page and date' {

    BeforeAll { $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json }

    It 'every v3 series has a row, and every v3 row names the plan page as its source' {
        # DAV4-TEMPDISK-1 added the AMD v4 rows after these, each naming its
        # own size page (Dav4TempDisk.Tests.ps1); this test holds the v3 rows.
        $rows = @($script:doc.replacements.bySeries | Where-Object { @($_.sourceSeries) -match 'v3$' })
        @($rows.sourceSeries) | Should -Be @('Dv3', 'Dsv3', 'Ev3', 'Esv3')
        foreach ($r in $rows) {
            $r.source | Should -Be 'sizes-v6-v7-modernization-plan'
            $r.everySizeHasTemporaryDisk | Should -BeTrue -Because 'Microsoft: every v3 size includes a local temporary disk'
        }
    }

    It 'the rows say what Microsoft''s table says, column by column' {
        $d = @($script:doc.replacements.bySeries)[0].targets
        @($d.v5) | Should -Be @('Dv5', 'Dsv5', 'Ddv5', 'Ddsv5', 'Dasv5', 'Dadsv5')
        @($d.v6) | Should -Be @('Dsv6', 'Ddsv6', 'Dasv6', 'Dadsv6')
        @($d.v7) | Should -Be @('Dsv7', 'Ddsv7', 'Dasv7', 'Dadsv7')
        $e = @($script:doc.replacements.bySeries)[1].targets
        @($e.v6) | Should -Be @('Esv6', 'Edsv6', 'Easv6', 'Eadsv6')
    }

    It 'the page is a named source with the section and the date it was read, and the drift check watches it' {
        $src = @($script:doc.sources | Where-Object { $_.url -match '/sizes-v6-v7-modernization-plan$' })
        $src.Count | Should -Be 1
        $src[0].section | Should -Be 'retiring-v3-workloads'
        $src[0].readUtc | Should -Be '2026-10-03'
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } }) |
            Should -Contain 'sizes-v6-v7-modernization-plan' -Because 'upstream-docs.json v2 names a page without its .md'
    }

    It 'reads a series name the way Microsoft writes it' {
        InModuleScope VmMigrationFactory {
            Get-VmfSizeSeriesName -SizeName 'Standard_D4s_v3' | Should -Be 'Dsv3'
            Get-VmfSizeSeriesName -SizeName 'Standard_D4_v3' | Should -Be 'Dv3'
            Get-VmfSizeSeriesName -SizeName 'Standard_E8-4ds_v6' | Should -Be 'Edsv6'
            Get-VmfSizeSeriesName -SizeName 'Standard_D2' | Should -BeNullOrEmpty
            (Get-VmfSizeReplacement -SizeName 'Standard_E16_v3').sourceSeries | Should -Contain 'Ev3'
            Get-VmfSizeReplacement -SizeName 'Standard_D4s_v4' | Should -BeNullOrEmpty -Because 'Microsoft gives no such table for v4'
        }
    }
}

Describe 'V3-TEMPDISK-1: every v3 size, measured' {

    It '<Source> goes to <Default> on v6, with <Other> as the other choice' -ForEach @(
        foreach ($r in @(@('D2', 2), @('D4', 4), @('D8', 8), @('D16', 16), @('D32', 32), @('D48', 48), @('D64', 64))) {
            @{ Source = "Standard_$($r[0])_v3"; Default = "Standard_$($r[0])ds_v6"; Other = "Standard_$($r[0])s_v6" }
            @{ Source = "Standard_$($r[0])s_v3"; Default = "Standard_$($r[0])ds_v6"; Other = "Standard_$($r[0])s_v6" }
        }
        foreach ($n in 'E2', 'E4', 'E8', 'E16', 'E20', 'E32', 'E48', 'E64') {
            @{ Source = "Standard_$($n)_v3"; Default = "Standard_$($n)ds_v6"; Other = "Standard_$($n)s_v6" }
            @{ Source = "Standard_$($n)s_v3"; Default = "Standard_$($n)ds_v6"; Other = "Standard_$($n)s_v6" }
        }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); s = $Source; d = $Default; o = $Other } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -Be $d
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @($o) -Because 'the size without a temporary disk is the alternate, and no size that does not exist is tried'
        }
    }

    It 'the two isolated sizes have no 64-vCPU v6 size, and are told Microsoft has none, not that the region has none' {
        # Microsoft's Esv6 and Edsv6 pages list one isolated size each,
        # E192is_v6 and E192ids_v6. So E64i_v3 and E64is_v3 have no v6 size
        # of their own. V5-SUCCESSOR-1: the reason says so, names the isolated
        # sizes Microsoft lists, and leaves the size to a person.
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            foreach ($s in 'Standard_E64i_v3', 'Standard_E64is_v3') {
                $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v6'
                $r.Target | Should -BeNullOrEmpty
                $r.Code | Should -Be 'not-approved'
                $r.Reason | Should -Match 'is an isolated size\. Microsoft''s isolated Intel E sizes on v6 are '
                $r.Reason | Should -Match 'A person decides the size of an isolated machine'
            }
        }
    }

    It 'on v7 too: D4_v3 goes to D4ds_v7, then D4s_v7' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog -V7) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v3' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Target | Should -Be 'Standard_D4ds_v7'
            @($r.Alternates) | Should -Be @('Standard_D4s_v7')
        }
    }

    It 'a v7 choice in a region with no v7 names the v6 size the same rules give, never a size that does not exist' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v3' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Code | Should -Be 'not-in-region'
            $r.Reason | Should -Match 'this region has Standard_D4ds_v6\. Choose v6 for this machine in the Choose each target step, then plan again\.'
            $r.Reason | Should -Not -Match 'Standard_D4_v[67]\b'
        }
    }

    It 'a region with no d size gives the size without one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog -NoD) } {
            (Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4s_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D4_v3' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4s_v6'
        }
    }

    It 'a region with neither says which sizes it looked for - the ones Microsoft names' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            # The family has v6 sizes, just not these two: a region with no D v6
            # at all is told that instead (family-not-in-region).
            $c.Remove('Standard_D4ds_v6'); $c.Remove('Standard_D4s_v6')
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v3' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Reason | Should -Match 'tried: Standard_D4ds_v6, Standard_D4s_v6\)'
        }
    }

    It 'a v3 size with no temporary disk reading in the catalog still goes to the d size - every v3 size has one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            $c['Standard_D4s_v3'] = V3Sku 'Standard_D4s_v3' 4 16 $null 'V1,V2'
            (Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4ds_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize @{} -TargetGeneration 'v6').Target | Should -Be 'Standard_D4ds_v6'
        }
    }

    It 'REVIEW: on v5 too, a v3 size with no reading goes to the d size (it went to the plain size before)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            $c['Standard_D4s_v3'] = V3Sku 'Standard_D4s_v3' 4 16 $null 'V1,V2'
            (Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v5').Target | Should -Be 'Standard_D4ds_v5'
        }
    }

    It 'a size name in another case still finds its row' {
        InModuleScope VmMigrationFactory {
            (Get-VmfSizeReplacement -SizeName 'standard_d4s_v3').sourceSeries | Should -Contain 'Dsv3'
        }
    }

    It 'but a catalog reading of no temporary disk wins over the table' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            $c['Standard_D4s_v3'] = V3Sku 'Standard_D4s_v3' 4 16 0 'V1,V2'
            (Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4s_v6'
        }
    }

    It 'v5 is as it was: D4_v3 -> D4d_v5 then D4_v5, D4s_v3 -> D4ds_v5 then D4s_v5' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v3' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be 'Standard_D4d_v5'; @($r.Alternates) | Should -Be @('Standard_D4_v5')
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be 'Standard_D4ds_v5'; @($r.Alternates) | Should -Be @('Standard_D4s_v5')
        }
    }

    It 'a named size (a chosen one) takes the place of the row' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog) } {
            (Get-VmfTargetSize -SourceSize 'Standard_D4s_v3' -Size 'Standard_D4s_v6' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4s_v6'
        }
    }

    It 'a size with no replacement row is not changed, and Dasv4 now has one: <Source> -> <Expected>' -ForEach @(
        # Rewritten for DAV4-TEMPDISK-1: this pinned D4as_v4 -> D4as_v6 so a
        # change would be a decision. It was made on 2026-10-04 - an AMD
        # v4 machine keeps its temporary disk, on AMD - so D4as_v4 now goes to
        # D4ads_v6. The Intel v4 sizes still have no row and keep their name.
        @{ Source = 'Standard_D4as_v4'; Expected = 'Standard_D4ads_v6' }
        @{ Source = 'Standard_D4s_v4';  Expected = 'Standard_D4s_v6' }
        @{ Source = 'Standard_D4ds_v4'; Expected = 'Standard_D4ds_v6' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Source; e = $Expected } {
            $c = @{}
            foreach ($n in 'Standard_D4as_v4', 'Standard_D4s_v4', 'Standard_D4ds_v4', 'Standard_D4as_v6', 'Standard_D4ads_v6', 'Standard_D4s_v6', 'Standard_D4ds_v6') {
                $c[$n] = V3Sku $n 4 16 $(if ($n -like '*_v4' -and $n -ne 'Standard_D4s_v4') { 16384 } else { 0 })
            }
            (Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be $e
        }
    }
}

Describe 'V3-TEMPDISK-1: the path does not change - only the temporary disk is kept' {

    It 'Windows: the in-place upgrade (Preview), no longer a rebuild (REBUILD-REMOVE-PLAN-1) - the SCSI temporary disk becomes an NVMe one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            $t.Mapping.Target | Should -Be 'Standard_D4ds_v6'
            $t.DiskArch | Should -Be 'nvme-temp'
            $t.TempDisks | Should -Be 1
            $t.Path | Should -Be 'A'
        }
    }

    It 'Linux: an in-place upgrade (Path A) as before' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm -Os 'Linux') } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').Path | Should -Be 'A'
        }
    }
}

Describe 'V3-TEMPDISK-1: the size without a temporary disk is a size choice' {

    It 'a v3 machine has two size choices on v6: the d size, marked best, and the size without one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            @($t.SizeChoices | ForEach-Object { $_.size }) | Should -Be @('Standard_D4ds_v6', 'Standard_D4s_v6')
            @($t.SizeChoices | Where-Object { $_.best } | ForEach-Object { $_.size }) | Should -Be @('Standard_D4ds_v6')
            $c0 = @($t.SizeChoices)[0]
            $c0.family | Should -Be 'D'; $c0.variant | Should -Be 'default'; $c0.vcpus | Should -Be 4; $c0.memoryGB | Should -Be 16
        }
    }

    It 'choosing the size without one plans it, and says it was chosen' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D4s_v6'
            $t.Mapping.Target | Should -Be 'Standard_D4s_v6'
            $t.Mapping.Reason | Should -Match '^chosen-size'
            $t.TempDisks | Should -Be 0
            $t.Path | Should -Be 'A'
        }
    }

    It 'a chosen size that is no longer a choice is refused with the reason, never swapped in silence' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            $c.Remove('Standard_D4s_v6')
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D4s_v6'
            $t.Mapping.Target | Should -BeNullOrEmpty
            $t.Mapping.Code | Should -Be 'chosen-size-gone'
            $t.Path | Should -Be 'MANUAL'
        }
    }

    It 'a size without a temporary disk that is smaller than the machine is not offered' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            $c['Standard_D4s_v6'] = V3Sku 'Standard_D4s_v6' 2 8 0
            @((Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').SizeChoices).Count | Should -Be 0
        }
    }

    It 'one size left is no choice' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog -NoS); vm = (V3Vm) } {
            @((Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').SizeChoices).Count | Should -Be 0
        }
    }

    It 'a v4 machine has none' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            $vm.sourceSize = 'Standard_D4ds_v4'; $c['Standard_D4ds_v4'] = V3Sku 'Standard_D4ds_v4' 4 16 153600
            @((Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').SizeChoices).Count | Should -Be 0
        }
    }

    It 'a planned machine on either size agrees with the rules, so the wave editor does not call it changed' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (V3Catalog); vm = (V3Vm) } {
            foreach ($size in 'Standard_D4ds_v6', 'Standard_D4s_v6') {
                $entry = [pscustomobject]@{ assessment = $vm; path = 'A'; target = [pscustomobject]@{ size = $size } }
                Test-VmfPlannedTargetAgrees -Entry $entry -CatalogBySize $c -Current 'v6' | Should -BeTrue -Because "$size is one of its choices"
            }
        }
    }
}

Describe 'V3-TEMPDISK-1: the target options show the default and the other choice' {

    It 'the v6 option names the d size and lists both, each with its own temporary disk count' {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((V3Vm)) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (V3Catalog -V7) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $advice.schemaVersion | Should -Be 33 -Because 'SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); REBUILD-PICKER-1 made it 23; GEN1-ROUTE-GONE-1 made it 22; IDENTITY-LOSS-1 made it 21; v11 (DAV4-TEMPDISK-1), v12 (OLD-FAM-4, burstableEnds), v13 (GPU-SCOPE-1, gpu-size), v14 (AMD-SHAPE-1, the processor maker by shape), v15 (BSV2-TARGET-1, Bsv2 for B v1), v16 (DISKS-32-1, too-many-data-disks), v17 (AN-ONE-NIC-1, one-accelerated-nic) and v18 (ADVISE-AN-1, keptOn) changed no field the v3 machine shows; v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine'
        $m = @($advice.machines)[0]
        foreach ($series in 'v6', 'v7') {
            $o = @($m.options) | Where-Object { $_.option -eq $series }
            $o.supported | Should -BeTrue
            $o.targetSize | Should -Be "Standard_D4ds_$series"
            $o.tempDisksTo | Should -Be 1
            $sizes = @($o.sizeChoices | ForEach-Object { $_.size })
            $sizes | Should -Be @("Standard_D4ds_$series", "Standard_D4s_$series")
            (@($o.sizeChoices) | Where-Object { $_.size -eq "Standard_D4s_$series" }).tempDisksTo | Should -Be 0
            (@($o.sizeChoices) | Where-Object { $_.size -eq "Standard_D4ds_$series" }).tempDisksTo | Should -Be 1
        }
        # REBUILD-REMOVE-PLAN-1: the v6 move of this Windows machine is the in-place
        # upgrade (Preview), so it starts on v6, the first of the Current order.
        $m.start.current | Should -Be 'v6'
    }

    It 'REVIEW: an encrypted Windows v3 machine on v5 keeps only the d size, and one size is no choice' {
        # D4ds_v5 is an in-place upgrade; D4s_v5 would be a rebuild, which an
        # encrypted machine is refused (V5-ADE-1). A list of one is not drawn.
        $vm = V3Vm; $vm.blockers = @('disk-encryption-present')
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($vm) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (V3Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $v5 = @(@($advice.machines)[0].options) | Where-Object { $_.option -eq 'v5' }
        $v5.supported | Should -BeTrue
        $v5.targetSize | Should -Be 'Standard_D4ds_v5'
        @($v5.sizeChoices).Count | Should -Be 0
    }

    It 'the options it writes fit the schema' {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((V3Vm)) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (V3Catalog -V7) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $advice.assessmentHash = '0' * 64
        $json = $advice | ConvertTo-Json -Depth 20
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw
        Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
    }
}
