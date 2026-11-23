#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# DAV4-TEMPDISK-1: an AMD v4 machine keeps its temporary disk on v5, v6 and v7,
# and stays on AMD.
#
# Microsoft's size pages (read 2026-10-04, held in data/target-families.json
# sources): every Dav4, Dasv4, Eav4 and Easv4 size has a temporary disk, and
# none of the names has a d - the same as v3 (V3-TEMPDISK-1). Microsoft gives a
# replacement table for v3 only, so the planner kept the name and changed the
# version:
#   - D4as_v4 -> D4as_v6, which has no temporary disk;
#   - D4a_v4  -> tried only Standard_D4a_v6, a size that does not exist (there
#     is no Dav6, only Dasv6 and Dadsv6), and ended "no candidate available in
#     region" - a naming problem reported as a shortage in the region. On v5 it
#     tried D4ad_v5 and D4a_v5, which do not exist either.
# Decided 2026-10-04: the AMD size that keeps a temporary disk
# first (D4ads_v6), the size without one as a size choice on the targets step,
# and never a change of processor.
#
# The catalog below holds the sizes Microsoft's AMD series pages list, read
# from the pinned pages in docs/upstream-docs on 2026-10-04 (Dasv5 to Dadsv7,
# Easv5 to Eadsv7), with their vCPUs and memory, every AMD v4 size, and the
# Intel sizes of the same shapes - so a planner that changed the processor
# would have somewhere to go, and a test would see it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:A4Sku {
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

    # name stem -> vCPUs, memory. The v4 rows are Microsoft's Dav4/Dasv4 and
    # Eav4/Easv4 pages; v5 and v6 have the same sizes; v7 has more, and no E20.
    $script:dSizes = @(@(2, 8), @(4, 16), @(8, 32), @(16, 64), @(32, 128), @(48, 192), @(64, 256), @(96, 384))
    $script:eSizes = @(@(2, 16), @(4, 32), @(8, 64), @(16, 128), @(20, 160), @(32, 256), @(48, 384), @(64, 512), @(96, 672))
    $script:dV7 = $script:dSizes + @(@(128, 512), @(160, 640))
    $script:eV7 = @(@(2, 16), @(4, 32), @(8, 64), @(16, 128), @(32, 256), @(48, 384), @(64, 512), @(96, 768), @(128, 1024), @(160, 1280))

    function Global:A4Catalog([switch]$NoAmdTargets, [switch]$NoD) {
        $c = @{}
        $add = { param($s) $c[$s.Name] = $s }
        foreach ($r in $script:dSizes) {
            & $add (A4Sku "Standard_D$($r[0])a_v4" $r[0] $r[1] (25600 * $r[0]) 'V1,V2')
            & $add (A4Sku "Standard_D$($r[0])as_v4" $r[0] $r[1] (8192 * $r[0]) 'V1,V2')
        }
        foreach ($r in $script:eSizes) {
            & $add (A4Sku "Standard_E$($r[0])a_v4" $r[0] $r[1] (8192 * $r[0]) 'V1,V2')
            & $add (A4Sku "Standard_E$($r[0])as_v4" $r[0] $r[1] (16384 * $r[0]) 'V1,V2')
        }
        foreach ($g in 'v5', 'v6', 'v7') {
            $d = if ($g -eq 'v7') { $script:dV7 } else { $script:dSizes }
            $e = if ($g -eq 'v7') { $script:eV7 } else { $script:eSizes }
            $gens = if ($g -eq 'v5') { 'V1,V2' } else { 'V2' }
            # v5: a SCSI temporary disk. v6 and v7: an NVMe one, which the
            # catalog reports as NVMe disks with no resource volume.
            $dTemp = if ($g -eq 'v5') { 76800 } else { 0 }
            $dNvme = if ($g -eq 'v5') { 0 } else { 1 }
            foreach ($fam in @(@('D', $d), @('E', $e))) {
                foreach ($r in $fam[1]) {
                    $n = "$($fam[0])$($r[0])"
                    if (-not $NoAmdTargets) {
                        if (-not $NoD) { & $add (A4Sku "Standard_$($n)ads_$g" $r[0] $r[1] $dTemp $gens $dNvme) }
                        & $add (A4Sku "Standard_$($n)as_$g" $r[0] $r[1] 0 $gens)
                    }
                    # Intel, the same shapes: where a change of processor would land.
                    & $add (A4Sku "Standard_$($n)ds_$g" $r[0] $r[1] $dTemp $gens $dNvme)
                    & $add (A4Sku "Standard_$($n)s_$g" $r[0] $r[1] 0 $gens)
                }
            }
            # The Dl family, which a Generation 1 machine is offered by shape.
            foreach ($r in $script:dSizes) { & $add (A4Sku "Standard_D$($r[0])lds_$g" $r[0] (2 * $r[0]) $dTemp $gens $dNvme) }
        }
        $c
    }
    function Global:A4Vm {
        param([string]$Size = 'Standard_D4as_v4', [string]$Os = 'Windows', [string]$Gen = 'V2', [string]$Name = 'app-04')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; hyperVGeneration = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
}
AfterAll { Remove-Item 'function:\A4Sku', 'function:\A4Catalog', 'function:\A4Vm' -ErrorAction SilentlyContinue }

Describe 'DAV4-TEMPDISK-1: the data names the size pages, the date, and that the rows are derived' {

    BeforeAll {
        $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        # V4-NAMES-1 added rows for the Intel v4 series with no s (Dv4, Ddv4,
        # Ev4, Edv4), so the AMD rows are the ones whose series has an a.
        $script:amd = @($script:doc.replacements.bySeries | Where-Object { @($_.sourceSeries) -match '^[DE]as?v4$' })
    }

    It 'each AMD v4 series has a row of its own, and every one has a temporary disk on every size' {
        @($script:amd | ForEach-Object { $_.sourceSeries }) | Should -Be @('Dav4', 'Dasv4', 'Eav4', 'Easv4')
        foreach ($r in $script:amd) { $r.everySizeHasTemporaryDisk | Should -BeTrue }
    }

    It 'every target of an AMD v4 row is an AMD series: the planner keeps the processor' {
        foreach ($r in $script:amd) {
            foreach ($g in 'v5', 'v6', 'v7') {
                @($r.targets.$g).Count | Should -Be 2
                foreach ($t in @($r.targets.$g)) { $t | Should -Match '^[DE]a' -Because "$t is a target of $($r.sourceSeries)" }
                @($r.targets.$g | Where-Object { $_ -like '*ad*' }).Count | Should -Be 1 -Because 'one size keeps a temporary disk, one has none'
            }
        }
    }

    It 'the AMD v4 rows say they are derived, and how; the v3 rows say they are stated' {
        foreach ($r in $script:amd) {
            $r.basis | Should -Be 'derived'
            [string]$r.how | Should -Match 'no replacement table for v4'
        }
        foreach ($r in @($script:doc.replacements.bySeries | Where-Object { @($_.sourceSeries) -match 'v3$' })) {
            $r.basis | Should -Be 'stated'
            $r.source | Should -Be 'sizes-v6-v7-modernization-plan'
        }
    }

    It 'each row names its size page as a source, read on 2026-10-04, and the drift check watches it' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        foreach ($r in $script:amd) {
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape($r.source))$" })
            $src.Count | Should -Be 1 -Because "'$($r.source)' must be one of the data file's sources"
            $src[0].readUtc | Should -Be '2026-10-04'
            $src[0].says | Should -Match 'temporary'
            $pinned | Should -Contain $r.source -Because "'$($r.source)' must be watched"
        }
    }

    It 'every page a replacement row rests on is watched - v3 and v4 alike' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        foreach ($name in @($script:doc.replacements.bySeries.source | Select-Object -Unique)) { $pinned | Should -Contain $name }
    }

    It 'finds the row for each AMD v4 size, and none for an Intel v4 size with an s (V4-NAMES-1 gave Dv4 and Ddv4 rows of their own)' {
        InModuleScope VmMigrationFactory {
            (Get-VmfSizeReplacement -SizeName 'Standard_D4a_v4').sourceSeries | Should -Be @('Dav4')
            (Get-VmfSizeReplacement -SizeName 'Standard_D4as_v4').sourceSeries | Should -Be @('Dasv4')
            (Get-VmfSizeReplacement -SizeName 'Standard_E20a_v4').sourceSeries | Should -Be @('Eav4')
            (Get-VmfSizeReplacement -SizeName 'Standard_E8-4as_v4').sourceSeries | Should -Be @('Easv4')
            Get-VmfSizeReplacement -SizeName 'Standard_D4s_v4' | Should -BeNullOrEmpty
            Get-VmfSizeReplacement -SizeName 'Standard_D4ds_v4' | Should -BeNullOrEmpty
            Get-VmfSizeReplacement -SizeName 'Standard_D4as_v5' | Should -BeNullOrEmpty -Because 'Dasv5 is a target, not a source with a row'
        }
    }
}

Describe 'DAV4-TEMPDISK-1: every AMD v4 size, measured' {

    It '<Source> goes to <Default> on <Gen>, with <Other> as the other choice' -ForEach @(
        foreach ($g in 'v5', 'v6', 'v7') {
            foreach ($n in 2, 4, 8, 16, 32, 48, 64, 96) {
                @{ Gen = $g; Source = "Standard_D$($n)a_v4"; Default = "Standard_D$($n)ads_$g"; Other = "Standard_D$($n)as_$g" }
                @{ Gen = $g; Source = "Standard_D$($n)as_v4"; Default = "Standard_D$($n)ads_$g"; Other = "Standard_D$($n)as_$g" }
            }
            foreach ($n in 2, 4, 8, 16, 20, 32, 48, 64, 96) {
                if ($g -eq 'v7' -and $n -eq 20) { continue }
                @{ Gen = $g; Source = "Standard_E$($n)a_v4"; Default = "Standard_E$($n)ads_$g"; Other = "Standard_E$($n)as_$g" }
                @{ Gen = $g; Source = "Standard_E$($n)as_v4"; Default = "Standard_E$($n)ads_$g"; Other = "Standard_E$($n)as_$g" }
            }
        }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); s = $Source; d = $Default; o = $Other; g = $Gen } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration $g
            $r.Target | Should -Be $d
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -Be @($o) -Because 'the AMD size without a temporary disk is the alternate, and no Intel size and no size that does not exist is tried'
        }
    }

    It 'E20a_v4 and E20as_v4 have no v7 size of their own name - Microsoft lists no E20 on Easv7 or Eadsv7, and the refusal says so (V5-SUCCESSOR-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog) } {
            foreach ($s in 'Standard_E20a_v4', 'Standard_E20as_v4') {
                $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v7'
                $r.Target | Should -BeNullOrEmpty
                $r.Code | Should -Be 'not-approved' -Because 'Microsoft lists no such size; that is not a shortage in the region'
                $r.Reason | Should -Match 'have no Standard_E20ads_v7 or Standard_E20as_v7\.'
                $r.Reason | Should -Match 'This region has Standard_E20ads_v6\. Choose v6 for this machine in the Choose each target step, then plan again\.' -Because 'the v7 refusal names the v6 size the same rules give, and where a person chooses it'
            }
        }
    }

    It 'a constrained AMD v4 size keeps its constrained part: E8-4as_v4 tries E8-4ads_v6, then E8-4as_v6' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E8-4as_v4' -TargetGeneration 'v6') | Should -Be @('Standard_E8-4ads_v6', 'Standard_E8-4as_v6')
        }
    }

    It 'a region with no AMD d size gives the AMD size without one - never an Intel size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog -NoD) } {
            (Get-VmfTargetSize -SourceSize 'Standard_D4as_v4' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4as_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D4a_v4' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4as_v6'
        }
    }

    It 'a region with no AMD target says which AMD sizes it looked for, and does not move the machine to Intel' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog -NoAmdTargets) } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4a_v4' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-in-region'
            $r.Reason | Should -Match 'tried: Standard_D4ads_v6, Standard_D4as_v6\)'
        }
    }

    It 'an AMD v4 size with no temporary disk reading in the catalog still goes to the d size - every size has one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog) } {
            $c['Standard_D4as_v4'] = A4Sku 'Standard_D4as_v4' 4 16 $null 'V1,V2'
            (Get-VmfTargetSize -SourceSize 'Standard_D4as_v4' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4ads_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D4as_v4' -CatalogBySize $c -TargetGeneration 'v5').Target | Should -Be 'Standard_D4ads_v5'
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E4a_v4' -TargetGeneration 'v6') | Should -Be @('Standard_E4ads_v6', 'Standard_E4as_v6')
        }
    }

    It 'but a catalog reading of no temporary disk wins over the table' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog) } {
            $c['Standard_D4as_v4'] = A4Sku 'Standard_D4as_v4' 4 16 0 'V1,V2'
            (Get-VmfTargetSize -SourceSize 'Standard_D4as_v4' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4as_v6'
        }
    }

    It 'a named size (a chosen one) takes the place of the row' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog) } {
            (Get-VmfTargetSize -SourceSize 'Standard_D4as_v4' -Size 'Standard_D4as_v6' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D4as_v6'
        }
    }
}

Describe 'DAV4-TEMPDISK-1: no default pairing changes the processor' {

    # The rule, 2026-10-04: AMD stays AMD and Intel stays Intel. Swept
    # over every D and E letter combination a source name can carry, on every
    # source version and every target series, with a temporary disk reading and
    # without one - every size the default transform tries is on the machine's
    # own processor.
    It 'every size the planner tries for a <Family> v<Version> machine is on its own processor' -ForEach @(
        foreach ($f in 'D', 'E') { foreach ($v in 2, 3, 4, 5) { @{ Family = $f; Version = $v } } }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ f = $Family; v = $Version } {
            $crossed = [System.Collections.Generic.List[string]]::new()
            $tried = 0
            foreach ($letters in '', 's', 'd', 'ds', 'a', 'as', 'ad', 'ads', 'l', 'ls', 'ld', 'lds', 'al', 'als', 'ald', 'alds', 'i', 'is', 'id', 'ids', 'b', 'bs', 'bds', 'm', 'ms', 'p', 'ps', 'pds', 'pls', 'plds') {
                $src = "Standard_$($f)4$($letters)_v$v"
                $mine = Get-VmfSizeProcessor -SizeName $src
                foreach ($temp in 0, 51200) {
                    $cat = @{ $src = [pscustomobject]@{ Name = $src; Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = [string]$temp }) } }
                    foreach ($g in 'v5', 'v6', 'v7') {
                        foreach ($cand in @(Get-VmfDefaultSizeCandidates -SourceSize $src -CatalogBySize $cat -TargetGeneration $g)) {
                            $tried++
                            if ((Get-VmfSizeProcessor -SizeName $cand) -ne $mine) { $crossed.Add("$src -> $cand") }
                        }
                    }
                }
            }
            $tried | Should -BeGreaterThan 100
            $crossed | Should -BeNullOrEmpty
        }
    }
}

Describe 'DAV4-TEMPDISK-1: the path is the one the disk categories give' {

    # REBUILD-REMOVE-PLAN-1: the in-place upgrade (Preview), no longer a rebuild.
    It 'Windows: the in-place upgrade (Preview) to v6 - the SCSI temporary disk becomes an NVMe one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            $t.Mapping.Target | Should -Be 'Standard_D4ads_v6'
            $t.DiskArch | Should -Be 'nvme-temp'
            $t.TempDisks | Should -Be 1
            $t.Path | Should -Be 'A'
        }
    }

    It 'Windows: an in-place upgrade (Path A) to v5 on the d size, which keeps a SCSI temporary disk; the in-place upgrade (Preview) on the size without one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $t.Mapping.Target | Should -Be 'Standard_D4ads_v5'
            $t.Path | Should -Be 'A'
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize 'Standard_D4as_v5').Path | Should -Be 'A'
        }
    }

    It 'Linux: an in-place upgrade (Path A)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm -Os 'Linux') } {
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6').Path | Should -Be 'A'
        }
    }
}

Describe 'DAV4-TEMPDISK-1 REVIEW: a source size the catalog does not report' {

    # The independent review: the row's "every size has a temporary disk" chose
    # the size, but the ASSESSMENT read the disk category from the name alone
    # (D4as_v4 has no d, so diskless). Path selection and the engine's page
    # file move read the assessment, so a Windows machine on the size without
    # a temporary disk was planned in place - a resize Azure refuses across
    # disk categories, inside the stopped window. The assessment now takes the
    # same fact from the row, for v3 and AMD v4 alike.
    BeforeAll {
        function Global:A4Record([string]$Size, $Sku = $null, [string]$Os = 'Windows') {
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = $Size; os = $Os; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/a'; nicCount = 1; nicIds = @('/s/rg/nic/a')
            }
            InModuleScope VmMigrationFactory -Parameters @{ v = $vm; s = $Sku } { Get-VmfAssessmentRecord -Vm $v -SkuEntry $s }
        }
    }
    AfterAll { Remove-Item 'function:\A4Record' -ErrorAction SilentlyContinue }

    It '<Size> with no catalog entry is recorded with a SCSI temporary disk, and Windows moves its page file' -ForEach @(
        @{ Size = 'Standard_D4as_v4' }, @{ Size = 'Standard_D4a_v4' }, @{ Size = 'Standard_E8as_v4' }, @{ Size = 'Standard_D4s_v3' }
    ) {
        $r = A4Record $Size
        $r.sourceDiskArch | Should -Be 'scsi-temp'
        $r.sourceTempDisks | Should -Be 1
        @($r.prepNeeded) | Should -Contain 'pagefile'
        (@($r.notes) -join ' ') | Should -Match 'temporary disk'
    }

    It 'a catalog entry with no temporary disk reading is read the same way' {
        $sku = [pscustomobject]@{ Name = 'Standard_D4as_v4'; Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '4' }) }
        (A4Record 'Standard_D4as_v4' $sku).sourceDiskArch | Should -Be 'scsi-temp'
    }

    It 'but a catalog reading wins, and a size with no row keeps the name rule' {
        $none = [pscustomobject]@{ Name = 'Standard_D4as_v4'; Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }) }
        (A4Record 'Standard_D4as_v4' $none).sourceDiskArch | Should -Be 'diskless'
        (A4Record 'Standard_D4s_v4').sourceDiskArch | Should -Be 'diskless' -Because 'Dsv4 has no row'
        (A4Record 'Standard_D4s_v4').sourceTempDisks | Should -BeNullOrEmpty -Because 'unknown is not zero (TEMPPOOL-1)'
    }

    It 'so a Windows machine planned on the size without a temporary disk takes the in-place upgrade (Preview), never a plain resize' {
        $rec = A4Record 'Standard_D4as_v4'
        $vm = A4Vm; $vm.sourceDiskArch = $rec.sourceDiskArch; $vm.sourceTempDisks = $rec.sourceTempDisks
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = $vm } {
            $c.Remove('Standard_D4as_v4')
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D4as_v6').Path | Should -Be 'A'
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize 'Standard_D4as_v5').Path | Should -Be 'A'
            (Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5').Path | Should -Be 'A' -Because 'the v5 d size keeps a SCSI temporary disk'
        }
    }
}

Describe 'DAV4-TEMPDISK-1: the size without a temporary disk is a size choice' {

    It 'an AMD v4 machine has two size choices on v6: the AMD d size, marked best, and the AMD size without one' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
            @($t.SizeChoices | ForEach-Object { $_.size }) | Should -Be @('Standard_D4ads_v6', 'Standard_D4as_v6')
            @($t.SizeChoices | Where-Object { $_.best } | ForEach-Object { $_.size }) | Should -Be @('Standard_D4ads_v6')
        }
    }

    It 'choosing the size without one plans it, and says it was chosen' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm -Size 'Standard_E8a_v4') } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_E8as_v6'
            $t.Mapping.Target | Should -Be 'Standard_E8as_v6'
            $t.Mapping.Reason | Should -Match '^chosen-size'
            $t.TempDisks | Should -Be 0
        }
    }

    It 'an Intel size is not a choice for an AMD machine, and choosing one is refused with the reason' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm) } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D4ds_v6'
            $t.Mapping.Target | Should -BeNullOrEmpty
            $t.Mapping.Code | Should -Be 'chosen-size-gone'
        }
    }

    It 'a planned AMD v4 machine on either size agrees with the rules, so the wave editor does not call it changed' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm) } {
            foreach ($size in 'Standard_D4ads_v6', 'Standard_D4as_v6') {
                $entry = [pscustomobject]@{ assessment = $vm; path = 'A'; target = [pscustomobject]@{ size = $size } }
                Test-VmfPlannedTargetAgrees -Entry $entry -CatalogBySize $c -Current 'v6' | Should -BeTrue -Because "$size is one of its choices"
            }
        }
    }
}

Describe 'DAV4-TEMPDISK-1: a Generation 1 AMD v4 machine on v5' {

    It 'keeps its processor: D2a_v4 goes to D2ads_v5, which it never reached before (it went to Intel by shape)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm -Size 'Standard_D2a_v4' -Gen 'V1') } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $t.Mapping.Target | Should -Be 'Standard_D2ads_v5'
            @(@($t.SizeChoices) | Where-Object best).size | Should -Be @('Standard_D2ads_v5')
        }
    }

    It 'in a region with no AMD v5 size it has no target, and is never sized onto Intel (AMD-SHAPE-1)' {
        # This test pinned the old behaviour, recorded here: with no AMD v5
        # size, the best Intel size by shape was the default. It was
        # decided on 2026-10-05 that a machine keeps its
        # processor maker (AMD-SHAPE-1), so it now has no target, and the
        # reason says that no AMD size fits.
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog -NoAmdTargets); vm = (A4Vm -Size 'Standard_D2a_v4' -Gen 'V1') } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            $t.Mapping.Target | Should -BeNullOrEmpty
            $t.Mapping.Code | Should -Be 'no-amd-shape-fit'
            @($t.SizeChoices).Count | Should -Be 0
        }
    }

    It 'every size it is offered by shape is AMD (AMD-SHAPE-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (A4Catalog); vm = (A4Vm -Size 'Standard_D2a_v4' -Gen 'V1') } {
            $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
            @($t.SizeChoices).Count | Should -BeGreaterThan 1
            foreach ($choice in @($t.SizeChoices)) { Get-VmfSizeProcessor -SizeName ([string]$choice.size) | Should -Be 'AMD' -Because "$($choice.size) is offered" }
        }
    }
}

Describe 'DAV4-TEMPDISK-1: the target options' {

    It 'are version 14 (11 was this item, 12 OLD-FAM-4, 13 GPU-SCOPE-1, 14 AMD-SHAPE-1), and the v5, v6 and v7 options of an AMD v4 machine name the AMD d size and list both' {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((A4Vm)) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (A4Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $advice.schemaVersion | Should -Be 34 -Because 'SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); REBUILD-PICKER-1 made it 23; GEN1-ROUTE-GONE-1 made it 22; IDENTITY-LOSS-1 made it 21; v11 was this item; v12 (OLD-FAM-4) added burstableEnds and v13 (GPU-SCOPE-1) the reason gpu-size, neither of which an AMD v4 machine changes; v14 (AMD-SHAPE-1) keeps the processor maker by shape, which a Generation 2 AMD v4 machine does not use; v15 (BSV2-TARGET-1) the Bsv2 choice of a B v1 machine, and the stage and CPU credits on each size choice; v16 (DISKS-32-1) the reason too-many-data-disks; v17 (AN-ONE-NIC-1) the reason one-accelerated-nic; v18 (ADVISE-AN-1) keptOn and the start that keeps accelerated networking; v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine'
        $m = @($advice.machines)[0]
        foreach ($series in 'v5', 'v6', 'v7') {
            $o = @($m.options) | Where-Object { $_.option -eq $series }
            $o.supported | Should -BeTrue
            $o.targetSize | Should -Be "Standard_D4ads_$series"
            @($o.sizeChoices | ForEach-Object { $_.size }) | Should -Be @("Standard_D4ads_$series", "Standard_D4as_$series")
            (@($o.sizeChoices) | Where-Object { $_.size -eq "Standard_D4as_$series" }).tempDisksTo | Should -Be 0
        }
    }

    It 'an encrypted Windows AMD v4 machine on v5 keeps only the d size, and one size is no choice' {
        # D4ads_v5 is an in-place upgrade; D4as_v5 would be a rebuild, which an
        # encrypted machine is refused (V5-ADE-1).
        $vm = A4Vm; $vm.blockers = @('disk-encryption-present')
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @($vm) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (A4Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $v5 = @(@($advice.machines)[0].options) | Where-Object { $_.option -eq 'v5' }
        $v5.supported | Should -BeTrue
        $v5.targetSize | Should -Be 'Standard_D4ads_v5'
        @($v5.sizeChoices).Count | Should -Be 0
    }

    It 'fit the schema' {
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = @((A4Vm)) }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (A4Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $advice.assessmentHash = '0' * 64
        $json = $advice | ConvertTo-Json -Depth 20
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw
        Test-Json -Json $json -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
    }
}
