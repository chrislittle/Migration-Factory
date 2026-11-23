#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# BSV2-TARGET-1: Bsv2 is the default target of a B v1 machine.
#
# OWNER-QUESTIONS-1 row 19, decided 2026-10-05: Bsv2 (Intel, the processor of
# B v1) is the DEFAULT target of a B v1 machine, with the D or E size by shape
# as the other choice. Basv2 is not offered (it is AMD).
#
# Before: a B v1 machine (B1ls to B20ms) was sized by shape onto a Dl, D or E
# size, and the advice said it lost its CPU credits (OLD-FAM-4). Bsv2 was not a
# target family at all.
#
# The facts, from Microsoft (data/target-families.json, with the pages):
#   - the Bsv2 page: eleven sizes, B2ts_v2 to B32s_v2, Intel, CPU credits, no
#     local storage, Generation 1 and Generation 2 Supported, accelerated
#     networking Supported (not Required), MANA among its interfaces;
#   - the retired sizes modernization guide: Bv1 goes to Bsv2/Basv2 first,
#     and the B and Bav2 disk controller type is SCSI.
# So Bsv2 follows the v5 rules - a SCSI resize that takes Generation 1 - and
# is offered on the v5 option, as its first size choice.
#
# The catalog: every B size Azure offers in centralus
# (tests/fixtures/bsv2-catalog-centralus.json, read 2026-10-09: B v1, Bsv2,
# Basv2, Bpsv2) with every Intel D, Dl and E size of OLD-FAM-4's fixture.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # One catalog entry per size, as Get-VmfSkuCatalog gives it.
    function Global:BsEntries([string]$File) {
        $doc = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $File) -Raw | ConvertFrom-Json
        foreach ($s in @($doc.sizes)) {
            $caps = @(foreach ($p in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $p.Name; Value = [string]$p.Value } })
            [pscustomobject]@{
                Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
                Family = $(if ($s.PSObject.Properties['family']) { [string]$s.family } else { 'standardX' })
                Restrictions = @(); LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
            }
        }
    }
    $script:bEntries = @(BsEntries 'bsv2-catalog-centralus.json')
    $script:oldEntries = @(BsEntries 'old-size-catalog-centralus.json')

    # -Without: a regular expression; the sizes it matches are left out.
    # -Reverse: the same sizes added in the other order (SIZE-TIE-1).
    function Global:BsCatalog([string]$Without = '', [switch]$Reverse, [scriptblock]$Change) {
        $all = @($script:oldEntries) + @($script:bEntries)
        if ($Reverse) { [array]::Reverse($all) }
        $c = @{}
        foreach ($e in $all) {
            if ($Without -and $e.Name -match $Without) { continue }
            $c[$e.Name] = $e
        }
        if ($Change) { & $Change $c }
        $c
    }
    function Global:BsCap($Entry, [string]$Name) {
        $c = @($Entry.Capabilities | Where-Object { $_.Name -eq $Name })
        if ($c.Count) { [string]$c[0].Value } else { $null }
    }

    function Global:BsVm {
        param([string]$Size = 'Standard_B2ms', [string]$Gen = 'V2', [string]$Os = 'Linux', [int]$Nics = 1, [int]$Disks = 0,
              [switch]$Encrypted, [string]$Name = 'burst-01')
        $temp = [int](BsCap $script:bEntries.Where({ $_.Name -eq $Size })[0] 'MaxResourceVolumeMB')
        $blockers = @(if ($Gen -eq 'V1') { 'gen1-requires-redeploy' }; if ($Encrypted) { 'disk-encryption-present' })
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = @(); gen = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter' } else { '22_04-lts' })
            classification = $(if ($blockers.Count) { 'Blocked' } else { 'ReadyAfterPrep' }); blockers = $blockers; prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $(if ($temp -gt 0) { 'scsi-temp' } else { 'diskless' }); sourceTempDisks = $(if ($temp -gt 0) { 1 } else { 0 })
            diskController = $(if ($Gen -eq 'V1') { '' } else { 'SCSI' }); dataDiskCount = $Disks; nicCount = $Nics
            acceleratedNicCount = 0; primaryNicAccelerated = $false; platformManaged = $false; iacManaged = $false
            hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{ app = $Name }
        }
    }
    function Global:BsTarget($Vm, [hashtable]$Catalog, [string]$Series = 'v5', [string]$Chosen = '') {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = $Catalog; g = $Series; ch = $Chosen } {
            param($v, $c, $g, $ch) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g -ChosenSize $ch
        }
    }
    function Global:BsAdvice([object[]]$Vms, [hashtable]$Catalog) {
        $doc = [pscustomobject]@{ runId = 'scan-b'; vms = @($Vms) }
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = $Catalog } } {
            param($d, $c) Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
    }
    function Global:BsOption($Machine, [string]$Series) { @($Machine.options | Where-Object { $_.option -eq $Series })[0] }
    function Global:BsSizes($Choices) { @(@($Choices) | ForEach-Object { [string]$_.size }) }

    # The B v1 sizes and their Bsv2 size: the smallest Bsv2 size on Microsoft's
    # Bsv2 page with at least the vCPUs AND the memory of the B v1 size on
    # Microsoft's Bv1 page. Written out, so the rule is checked against a
    # table a person can read, not against a copy of itself.
    $script:expected = [ordered]@{
        'Standard_B1ls'  = 'Standard_B2ts_v2'   # 1 vCPU, 0.5 GiB -> 2, 1
        'Standard_B1s'   = 'Standard_B2ts_v2'   # 1, 1   -> 2, 1
        'Standard_B1ms'  = 'Standard_B2ls_v2'   # 1, 2   -> 2, 4 (B2ts_v2 has 1 GiB)
        'Standard_B2s'   = 'Standard_B2ls_v2'   # 2, 4   -> 2, 4
        'Standard_B2ms'  = 'Standard_B2s_v2'    # 2, 8   -> 2, 8
        'Standard_B4ms'  = 'Standard_B4s_v2'    # 4, 16  -> 4, 16
        'Standard_B8ms'  = 'Standard_B8s_v2'    # 8, 32  -> 8, 32
        'Standard_B12ms' = 'Standard_B16s_v2'   # 12, 48 -> 16, 64 (B16ls_v2 has 32 GiB)
        'Standard_B16ms' = 'Standard_B16s_v2'   # 16, 64 -> 16, 64
        'Standard_B20ms' = 'Standard_B32s_v2'   # 20, 80 -> 32, 128 (B32ls_v2 has 64 GiB)
    }
}
AfterAll {
    Remove-Item 'function:\BsEntries', 'function:\BsCatalog', 'function:\BsCap', 'function:\BsVm', 'function:\BsTarget',
        'function:\BsAdvice', 'function:\BsOption', 'function:\BsSizes' -ErrorAction SilentlyContinue
}

Describe 'BSV2-TARGET-1: the facts are data, with their pages' {
    BeforeAll { $script:families = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json }

    It 'the Bsv2 row names its sizes, its sources, its processor, its option and its facts' {
        $row = @($script:families.burstableTargets.series | Where-Object { $_.series -eq 'Bsv2' })
        $row.Count | Should -Be 1
        @($row[0].sizeSeries) | Should -Be @('Btsv2', 'Blsv2', 'Bsv2')
        @($row[0].sourceSizeSeries) | Should -Be @('Bls', 'Bs', 'Bms')
        $row[0].processor | Should -Be 'Intel'
        $row[0].option | Should -Be 'v5' -Because 'Bsv2 is SCSI and takes Generation 1: the v5 rules'
        $row[0].traits.controller | Should -Be 'SCSI'
        @($row[0].traits.hyperVGenerations) | Should -Be @('V1', 'V2')
        @($row[0].traits.acceleratedNetworkingRequired).Count | Should -Be 0 -Because 'the page says Supported, not Required'
        @($row[0].traits.manaProcessors) | Should -Be @('Intel') -Because 'the page lists MANA among its interfaces'
        $row[0].temporaryDisk | Should -BeFalse -Because 'No local storage present in this series'
    }

    It 'every page the row and its lifecycle stage name is a source, read today or earlier' {
        $urls = @($script:families.sources | ForEach-Object { ([string]$_.url).TrimEnd('/').Split('/')[-1] })
        $row = @($script:families.burstableTargets.series)[0]
        foreach ($name in $row.source, $row.controllerSource, $row.manaSource) { $urls | Should -Contain $name }
        $row.controllerMeasured | Should -Match 'DiskControllerTypes' -Because 'the catalog is the second source for SCSI'
        $stage = @($script:families.lifecycle.bySeries | Where-Object { $_.family -eq 'B' -and @($_.generations) -contains 'v2' })
        $stage.Count | Should -Be 1
        $stage[0].stage | Should -Be 'Current'
        $stage[0].basis | Should -Be 'derived' -Because 'Microsoft names no stage for Bsv2; it is the newest B series'
        $urls | Should -Contain $stage[0].source
        $stage[0].how | Should -Not -BeNullOrEmpty
    }

    It 'Basv2 and Bpsv2 have no row: they are never a target' {
        $all = @($script:families.burstableTargets.series | ForEach-Object { @($_.sizeSeries) })
        foreach ($s in 'Basv2', 'Balsv2', 'Batsv2', 'Bpsv2', 'Bplsv2', 'Bptsv2') { $all | Should -Not -Contain $s }
    }

    It 'the drift check watches the Bsv2 page and pins it' {
        $baseline = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $folder = @($baseline.folders | Where-Object { $_.path -eq 'azure/virtual-machines/sizes/general-purpose' })[0]
        'bsv2-series' | Should -Match $folder.include
        'basv2-series' | Should -Not -Match $folder.include
        'bpsv2-series' | Should -Not -Match $folder.include
        @($folder.pages | Where-Object { $_.name -eq 'bsv2-series' }).Count | Should -Be 1
        Test-Path (Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'sizes' 'general-purpose' 'bsv2-series.md') | Should -BeTrue
    }
}

Describe 'BSV2-TARGET-1: a size is read as Bsv2 by its series, never by a list of names' {
    It '<Size> is <Want>' -ForEach @(
        @{ Size = 'Standard_B2s_v2'; Want = 'Bsv2' }, @{ Size = 'Standard_B2ls_v2'; Want = 'Bsv2' }, @{ Size = 'Standard_B2ts_v2'; Want = 'Bsv2' }
        @{ Size = 'Standard_B32s_v2'; Want = 'Bsv2' }
        @{ Size = 'Standard_B2as_v2'; Want = '' }, @{ Size = 'Standard_B2als_v2'; Want = '' }, @{ Size = 'Standard_B2ats_v2'; Want = '' }
        @{ Size = 'Standard_B2ps_v2'; Want = '' }, @{ Size = 'Standard_B2pls_v2'; Want = '' }
        @{ Size = 'Standard_B2ms'; Want = '' }, @{ Size = 'Standard_D2s_v5'; Want = '' }, @{ Size = 'Standard_DS2_v2'; Want = '' }
    ) {
        $row = InModuleScope VmMigrationFactory -Parameters @{ s = $Size } { param($s) Get-VmfBurstableTarget -SizeName $s }
        [string]$row.series | Should -Be $Want
    }

    It 'the engine reads a size as Bsv2 exactly where the pages do (tests/fixtures/bsv2-size-names.json)' {
        $fx = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'bsv2-size-names.json') -Raw | ConvertFrom-Json
        @($fx.sizes).Count | Should -BeGreaterThan 10
        foreach ($s in @($fx.sizes)) {
            $row = InModuleScope VmMigrationFactory -Parameters @{ n = [string]$s.size } { param($n) Get-VmfBurstableTarget -SizeName $n }
            [bool]$row | Should -Be ([bool]$s.bsv2) -Because "$($s.size) - tests/js/bsv2-series.test.js holds the page to the same list"
        }
    }

    It 'a Bsv2 size has the v5 facts: a SCSI resize, accelerated networking not required, MANA possible, the Current stage' {
        InModuleScope VmMigrationFactory {
            Get-VmfMoveKind -PlanEntry ([pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_B2s_v2'; controller = 'SCSI' } }) | Should -Be 'scsi-resize'
            Test-VmfTargetRequiresAcceleratedNetworking -SizeName 'Standard_B2s_v2' | Should -BeFalse
            Test-VmfTargetMayUseMana -SizeName 'Standard_B2s_v2' | Should -BeTrue
            (Get-VmfSizeLifecycleStage -SizeName 'Standard_B2s_v2').Stage | Should -Be 'Current'
            # Basv2 has no facts here: it is not a target.
            Test-VmfTargetRequiresAcceleratedNetworking -SizeName 'Standard_B2as_v2' | Should -BeNullOrEmpty
            Get-VmfMoveKind -PlanEntry ([pscustomobject]@{ target = [pscustomobject]@{ size = 'Standard_B2as_v2'; controller = 'SCSI' } }) | Should -Be 'scsi-reversion'
        }
    }
}

Describe 'BSV2-TARGET-1: a B v1 machine starts on its Bsv2 size, with the D or E size as the other choice' {
    It 'every B v1 size, Generation <Gen>: the smallest Bsv2 size that is not smaller, then the Dl, D or E sizes' -ForEach @(
        @{ Gen = 'V2' }, @{ Gen = 'V1' }
    ) {
        $catalog = BsCatalog
        $failures = [System.Collections.Generic.List[string]]::new()
        foreach ($src in $script:expected.Keys) {
            $t = BsTarget (BsVm -Size $src -Gen $Gen) $catalog
            $want = $script:expected[$src]
            if ([string]$t.Mapping.Target -ne $want) { $failures.Add("$src planned on '$($t.Mapping.Target)', not $want ($($t.Mapping.Code))"); continue }
            $best = @($t.SizeChoices | Where-Object best)
            if ($best.Count -ne 1 -or $best[0].size -ne $want -or $best[0].family -ne 'Bsv2') { $failures.Add("$src best is not $want") }
            if ([string]@($t.SizeChoices)[0].family -ne 'Bsv2') { $failures.Add("$src - Bsv2 is not the first choice") }
            $others = @($t.SizeChoices | Where-Object { $_.family -ne 'Bsv2' })
            if (-not $others.Count) { $failures.Add("$src has no D or E choice") }
            foreach ($o in $others) { if ($o.family -notin @('Dl', 'D', 'E') -or $o.size -notmatch '^Standard_[DE]\d+(-\d+)?l?d?s_v5$') { $failures.Add("$src offers $($o.size) ($($o.family))") } }
            if (@($t.SizeChoices | Where-Object family -EQ 'Bsv2').Count -ne 1) { $failures.Add("$src offers more than one Bsv2 size") }
            if ($t.BurstableTarget -ne 'offered') { $failures.Add("$src burstable target is '$($t.BurstableTarget)'") }
            if ($t.Path -ne 'A') { $failures.Add("$src (Linux) path $($t.Path)") }
            # Never smaller (SIZE-FIT-1), checked against the catalog itself.
            $s = $catalog[$src]; $d = $catalog[$want]
            if ([double](BsCap $d 'vCPUs') -lt [double](BsCap $s 'vCPUs') -or [double](BsCap $d 'MemoryGB') -lt [double](BsCap $s 'MemoryGB')) { $failures.Add("$src -> $want is smaller") }
        }
        $failures -join "`n" | Should -BeNullOrEmpty
    }

    It 'no Bsv2 size of the region is a better fit than the one chosen: fewer vCPUs, or as many with less memory' {
        $catalog = BsCatalog
        $bsv2 = @($catalog.Keys | Where-Object { $_ -match '^Standard_B\d+[lt]?s_v2$' })
        $bsv2.Count | Should -Be 11 -Because 'the eleven sizes of the page are in the fixture'
        foreach ($src in $script:expected.Keys) {
            $s = $catalog[$src]
            $fits = @($bsv2 | Where-Object { [double](BsCap $catalog[$_] 'vCPUs') -ge [double](BsCap $s 'vCPUs') -and [double](BsCap $catalog[$_] 'MemoryGB') -ge [double](BsCap $s 'MemoryGB') } |
                Sort-Object { [double](BsCap $catalog[$_] 'vCPUs') }, { [double](BsCap $catalog[$_] 'MemoryGB') })
            $fits[0] | Should -Be $script:expected[$src] -Because "the table for $src agrees with the catalog"
        }
    }

    It 'the D or E size by shape is still there, and a person may choose it' {
        $catalog = BsCatalog
        $t = BsTarget (BsVm -Size 'Standard_B2ms') $catalog
        BsSizes $t.SizeChoices | Should -Contain 'Standard_D2ds_v5' -Because 'B2ms has a temporary disk, so the d size'
        BsSizes $t.SizeChoices | Should -Contain 'Standard_D4lds_v5' -Because 'the Dl size with 8 GiB'
        BsSizes $t.SizeChoices | Should -Contain 'Standard_E2ds_v5'
        $c = BsTarget (BsVm -Size 'Standard_B2ms') $catalog -Chosen 'Standard_D2ds_v5'
        $c.Mapping.Target | Should -Be 'Standard_D2ds_v5'
        $c.Mapping.Reason | Should -Match '^chosen-size'
        $c.Path | Should -Be 'A'
    }

    It 'the Bsv2 size grows to hold the network interfaces, and with too many there is none' {
        $catalog = BsCatalog
        # B2ms holds 3 network interfaces; B2s_v2 holds 2, B4ls_v2 holds 3 (the catalog).
        $t = BsTarget (BsVm -Size 'Standard_B2ms' -Nics 3) $catalog
        $t.Mapping.Target | Should -Be 'Standard_B4ls_v2'
        $t.BurstableTarget | Should -Be 'offered'
        # B12ms holds 6; no Bsv2 size holds more than 4.
        $n = BsTarget (BsVm -Size 'Standard_B12ms' -Nics 6) $catalog
        @($n.SizeChoices | Where-Object family -EQ 'Bsv2').Count | Should -Be 0
        $n.BurstableTarget | Should -Be 'no-fit'
        $n.Mapping.Target | Should -Match '^Standard_[DE]\d+l?ds_v5$'
    }


    It 'is the same answer whatever order the catalog was read in' {
        foreach ($src in 'Standard_B1s', 'Standard_B12ms', 'Standard_B20ms') {
            $a = BsTarget (BsVm -Size $src) (BsCatalog)
            $b = BsTarget (BsVm -Size $src) (BsCatalog -Reverse)
            (BsSizes $b.SizeChoices) -join ',' | Should -Be ((BsSizes $a.SizeChoices) -join ',') -Because $src
            $b.Mapping.Target | Should -Be $a.Mapping.Target
        }
    }
}

Describe 'BSV2-TARGET-1: when Bsv2 is not offered, the D or E size is the default and the reason is said' {
    It 'a region with no Bsv2 size: the D or E size, and no-fit' {
        $catalog = BsCatalog -Without '^Standard_B\d+[lt]?s_v2$'
        $t = BsTarget (BsVm -Size 'Standard_B2ms') $catalog
        $t.Mapping.Target | Should -Be 'Standard_D2ds_v5' -Because 'OLD-FAM-1: the fewest vCPUs, then the least memory, D before Dl before E'
        @($t.SizeChoices | Where-Object family -EQ 'Bsv2').Count | Should -Be 0
        $t.BurstableTarget | Should -Be 'no-fit'
    }

    It 'a region with Basv2 and Bpsv2 only: never offered, and no-fit' {
        $catalog = BsCatalog -Without '^Standard_B\d+[lt]?s_v2$'
        @($catalog.Keys | Where-Object { $_ -match '^Standard_B\d+a' }).Count | Should -BeGreaterThan 5 -Because 'the Basv2 sizes are in this catalog'
        $t = BsTarget (BsVm -Size 'Standard_B2ms') $catalog
        @(BsSizes $t.SizeChoices | Where-Object { $_ -match '^Standard_B' }).Count | Should -Be 0
        $t.BurstableTarget | Should -Be 'no-fit'
    }

    It 'a Gen 1 machine where the catalog says the Bsv2 sizes take Generation 2 only: no Bsv2, and no-fit' {
        $catalog = BsCatalog -Change {
            param($c)
            foreach ($k in @($c.Keys | Where-Object { $_ -match '^Standard_B\d+[lt]?s_v2$' })) {
                $e = $c[$k]
                $caps = @($e.Capabilities | Where-Object { $_.Name -ne 'HyperVGenerations' }) + [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V2' }
                $c[$k] = [pscustomobject]@{ Name = $e.Name; ResourceType = $e.ResourceType; Capabilities = $caps; Family = $e.Family; Restrictions = @(); LocationInfo = $e.LocationInfo }
            }
        }
        $g1 = BsTarget (BsVm -Size 'Standard_B2ms' -Gen 'V1') $catalog
        $g1.BurstableTarget | Should -Be 'no-fit'
        $g1.Mapping.Target | Should -Be 'Standard_D2ds_v5'
        $g2 = BsTarget (BsVm -Size 'Standard_B2ms' -Gen 'V2') $catalog
        $g2.Mapping.Target | Should -Be 'Standard_B2s_v2' -Because 'a Generation 2 machine still takes it'
    }

    # REBUILD-REMOVE-PLAN-1: the in-place upgrade (Preview), no longer a rebuild.
    It 'a Windows machine with a temporary disk moves onto Bsv2, which has none, by the in-place upgrade (Preview)' {
        $t = BsTarget (BsVm -Size 'Standard_B2ms' -Os 'Windows') (BsCatalog)
        $t.Mapping.Target | Should -Be 'Standard_B2s_v2'
        $t.Path | Should -Be 'A' -Because 'Windows changes disk category in place only with the preview feature: scsi-temp to diskless'
        $t.Preview | Should -BeTrue
        $t.DiskArch | Should -Be 'diskless'
        $d = BsTarget (BsVm -Size 'Standard_B2ms' -Os 'Windows') (BsCatalog) -Chosen 'Standard_D2ds_v5'
        $d.Path | Should -Be 'A' -Because 'the D size keeps the temporary disk'
    }

    It 'an encrypted Windows machine: the move to Bsv2 is refused, so it starts on the D or E size in place' {
        $t = BsTarget (BsVm -Size 'Standard_B2ms' -Os 'Windows' -Encrypted) (BsCatalog)
        $t.BurstableTarget | Should -Be 'disk-encryption-preview'
        @($t.SizeChoices | Where-Object family -EQ 'Bsv2').Count | Should -Be 0
        $t.Mapping.Target | Should -Be 'Standard_D2ds_v5'
        $t.Path | Should -Be 'A'
        @($t.Blockers) | Should -Not -Contain 'disk-encryption-preview'
        # Linux is moved in place onto Bsv2, encrypted or not.
        $l = BsTarget (BsVm -Size 'Standard_B2ms' -Encrypted) (BsCatalog)
        $l.Mapping.Target | Should -Be 'Standard_B2s_v2'
        $l.BurstableTarget | Should -Be 'offered'
    }
}

Describe 'BSV2-TARGET-1 (review): a v5 move that takes the temporary disk away says the page file moves' {
    It '<name>' -ForEach @((Get-Content (Join-Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))) 'tests' 'fixtures' 'prep-by-target.json') -Raw | ConvertFrom-Json).cases |
            ForEach-Object { @{ name = $_.name; case = $_ } }) {
        $a = [pscustomobject]@{ classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @($case.prepNeeded); diskController = 'SCSI'; platformManaged = $false }
        $got = InModuleScope VmMigrationFactory -Parameters @{ a = $a; s = [string]$case.series; d = [string]$case.targetDiskArch } {
            param($a, $s, $d) (Resolve-VmfEntryClassification -Assessment $a -TargetGeneration $s -TargetDiskArch $d).Prep
        }
        (@($got) | Sort-Object) -join ',' | Should -Be ((@($case.prep) | Sort-Object) -join ',') -Because 'tests/js/bsv2-series.test.js holds the page to the same cases'
    }

    It 'the Windows B v1 option and its Bsv2 choice list it; the d size does not' {
        $vm = BsVm -Size 'Standard_B2ms' -Os 'Windows'; $vm.prepNeeded = @('stornvme', 'pagefile')
        $o = BsOption @((BsAdvice @($vm) (BsCatalog)).machines)[0] 'v5'
        @($o.prep) | Should -Contain 'pagefile'
        @(@($o.sizeChoices | Where-Object family -EQ 'Bsv2')[0].prep) | Should -Contain 'pagefile'
        @(@($o.sizeChoices | Where-Object size -EQ 'Standard_D2ds_v5')[0].prep) | Should -Not -Contain 'pagefile' -Because 'the d size keeps the temporary disk'
        $t = BsTarget $vm (BsCatalog) -Chosen 'Standard_D2ds_v5'
        @($t.Prep) | Should -Not -Contain 'pagefile'
    }
}

Describe 'BSV2-TARGET-1: Bsv2 is for a B v1 machine on v5 only' {
    It 'a <Size> machine (Generation <Gen>) is never offered Bsv2' -ForEach @(
        @{ Size = 'Standard_DS2_v2'; Gen = 'V1' }, @{ Size = 'Standard_D2_v2'; Gen = 'V2' }, @{ Size = 'Standard_A2_v2'; Gen = 'V1' }
        @{ Size = 'Standard_F2s_v2'; Gen = 'V2' }, @{ Size = 'Standard_F2'; Gen = 'V1' }
    ) {
        $vm = BsVm -Size 'Standard_B2ms' -Gen $Gen
        $vm.sourceSize = $Size
        foreach ($s in 'v5', 'v6', 'v7') {
            $t = BsTarget $vm (BsCatalog) $s
            @(BsSizes $t.SizeChoices | Where-Object { $_ -match '^Standard_B' }).Count | Should -Be 0 -Because "$Size on $s"
            [string]$t.Mapping.Target | Should -Not -Match '^Standard_B' -Because "$Size on $s"
            $t.BurstableTarget | Should -BeNullOrEmpty -Because "$Size on $s - the question does not arise"
        }
    }

    It 'the row is offered to a B v1 machine, on v5, of its own processor maker only (AMD-SHAPE-1)' {
        InModuleScope VmMigrationFactory {
            $f = Get-VmfTargetFamilyData | ConvertTo-Json -Depth 20 | ConvertFrom-Json
            (Get-VmfBurstableTargetFor -SourceSize 'Standard_B2ms' -TargetGeneration 'v5' -Families $f).series | Should -Be 'Bsv2'
            foreach ($g in 'v6', 'v7') { Get-VmfBurstableTargetFor -SourceSize 'Standard_B2ms' -TargetGeneration $g -Families $f | Should -BeNullOrEmpty -Because $g }
            Get-VmfBurstableTargetFor -SourceSize 'Standard_D2s_v4' -TargetGeneration 'v5' -Families $f | Should -BeNullOrEmpty
            Get-VmfBurstableTargetFor -SourceSize 'Standard_B2s_v2' -TargetGeneration 'v5' -Families $f | Should -BeNullOrEmpty -Because 'Bsv2 is a target, not a source'
            # Every B v1 size is Intel, so the maker is proven on the data: a row for another maker is not offered.
            @($f.burstableTargets.series)[0].processor = 'AMD'
            Get-VmfBurstableTargetFor -SourceSize 'Standard_B2ms' -TargetGeneration 'v5' -Families $f | Should -BeNullOrEmpty
        }
    }

    It 'a B v1 machine is not offered Bsv2 on v6 or v7' {
        foreach ($s in 'v6', 'v7') {
            $t = BsTarget (BsVm -Size 'Standard_B2ms') (BsCatalog) $s
            @(BsSizes $t.SizeChoices | Where-Object { $_ -match '^Standard_B' }).Count | Should -Be 0 -Because $s
            $t.BurstableTarget | Should -BeNullOrEmpty -Because $s
        }
    }

    It 'a named Bsv2 size for another machine is refused as not approved' {
        $catalog = BsCatalog -Change { param($c) $c['Standard_D2s_v4'] = $c['Standard_D2s_v5'] }
        $m = InModuleScope VmMigrationFactory -Parameters @{ c = $catalog } {
            param($c) Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -Size 'Standard_B2s_v2' -CatalogBySize $c -TargetGeneration 'v5'
        }
        [string]$m.Target | Should -BeNullOrEmpty
        $m.Code | Should -Be 'not-approved'
    }

    It 'the gate refuses Bsv2 for a B v1 machine on v6, and Basv2 and Bpsv2 on v5' {
        $catalog = BsCatalog
        foreach ($case in @(@('v6', 'Standard_B2s_v2'), @('v7', 'Standard_B2s_v2'), @('v5', 'Standard_B2as_v2'), @('v5', 'Standard_B2ps_v2'))) {
            $m = InModuleScope VmMigrationFactory -Parameters @{ c = $catalog; g = $case[0]; s = $case[1] } {
                param($c, $g, $s) Get-VmfTargetSize -SourceSize 'Standard_B2ms' -Size $s -CatalogBySize $c -TargetGeneration $g
            }
            [string]$m.Target | Should -BeNullOrEmpty -Because "$($case[1]) on $($case[0])"
            $m.Code | Should -Be 'not-approved' -Because "$($case[1]) on $($case[0])"
        }
        $ok = InModuleScope VmMigrationFactory -Parameters @{ c = $catalog } {
            param($c) Get-VmfTargetSize -SourceSize 'Standard_B2ms' -Size 'Standard_B2s_v2' -CatalogBySize $c -TargetGeneration 'v5'
        }
        $ok.Target | Should -Be 'Standard_B2s_v2'
    }


    It 'a chosen Basv2 size is refused, never planned' {
        $t = BsTarget (BsVm -Size 'Standard_B2ms') (BsCatalog) -Chosen 'Standard_B2as_v2'
        [string]$t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'chosen-size-gone'
    }
}

Describe 'BSV2-TARGET-1: the target options' {
    BeforeAll {
        $script:schema = Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json'
        $script:adv = BsAdvice @((BsVm -Size 'Standard_B2ms' -Name 'b2'), (BsVm -Size 'Standard_B2ms' -Gen 'V1' -Name 'b1'), (BsVm -Size 'Standard_B2ms' -Os 'Windows' -Encrypted -Name 'enc')) (BsCatalog)
        $script:none = BsAdvice @((BsVm -Size 'Standard_B2ms' -Name 'b2')) (BsCatalog -Without '^Standard_B\d+[lt]?s_v2$')
    }

    It 'match their schema, version 15' {
        foreach ($a in $script:adv, $script:none) {
            $a.assessmentHash = 'h'
            $a.schemaVersion | Should -Be 34 -Because 'SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); v23 (REBUILD-PICKER-1) the in-place start; v22 (GEN1-ROUTE-GONE-1) took the Generation 1 route out; v18 (ADVISE-AN-1) added keptOn; v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine; v21 (IDENTITY-LOSS-1) what each target does to the system-assigned identity'
            ($a | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $script:schema | Should -BeTrue
        }
    }

    It 'a B v1 machine starts on Bsv2 under both defaults' {
        foreach ($m in @($script:adv.machines | Where-Object { $_.name -in @('b2', 'b1') })) {
            $m.start.current | Should -Be 'v5' -Because "$($m.name) - Bsv2 is offered on the v5 option"
            $m.start.extended | Should -Be 'v5'
            (BsOption $m 'v5').targetSize | Should -Be 'Standard_B2s_v2'
        }
    }

    It 'with no Bsv2 size, the defaults are as before: v6 for Current, v5 for Extended' {
        $m = @($script:none.machines)[0]
        $m.start.current | Should -Be 'v6'
        $m.start.extended | Should -Be 'v5'
        (BsOption $m 'v5').burstableTarget | Should -Be 'no-fit'
        (BsOption $m 'v5').supported | Should -BeTrue
        (BsOption $m 'v6').burstableTarget | Should -BeNullOrEmpty
    }

    It 'the v5 option says the machine keeps its CPU credits, and the stage goes up to Current' {
        $o = BsOption (@($script:adv.machines | Where-Object name -EQ 'b2')[0]) 'v5'
        $o.burstableTarget | Should -Be 'offered'
        $o.burstableKept | Should -BeTrue
        $o.burstableEnds | Should -BeFalse
        $o.targetStage.stage | Should -Be 'Current'
        $o.stageChange | Should -Be 'up'
        $o.move | Should -Be 'scsi-resize'
        $o.acceleratedNetworking.required | Should -BeFalse
        $o.acceleratedNetworking.mayUseMana | Should -BeTrue
        $o.stops.Count | Should -Be 0 -Because 'accelerated networking is not required on Bsv2'
    }

    It 'each size choice carries its own CPU credits and lifecycle stage' {
        $o = BsOption (@($script:adv.machines | Where-Object name -EQ 'b2')[0]) 'v5'
        $b = @($o.sizeChoices | Where-Object family -EQ 'Bsv2')[0]
        $b.burstableKept | Should -BeTrue
        $b.burstableEnds | Should -BeFalse
        $b.targetStage.stage | Should -Be 'Current'
        $b.stageChange | Should -Be 'up'
        $b.best | Should -BeTrue
        $d = @($o.sizeChoices | Where-Object { $_.family -eq 'Dl' })[0]
        $d.burstableEnds | Should -BeTrue
        $d.burstableKept | Should -BeFalse
        $d.targetStage.stage | Should -Be 'Extended'
        $d.stageChange | Should -Be 'up'
        $d.acceleratedNetworking.required | Should -BeTrue -Because 'Intel Dl v5 requires it'
        @($d.stops) | Should -Contain 'acceleratedNetworkingRequired' -Because 'B2ms cannot carry accelerated networking, so it is off'
    }

    It 'the encrypted Windows machine says why it has no Bsv2 size, and starts on the D or E size' {
        $m = @($script:adv.machines | Where-Object name -EQ 'enc')[0]
        $o = BsOption $m 'v5'
        $o.burstableTarget | Should -Be 'disk-encryption-preview'
        $o.supported | Should -BeTrue
        $o.targetSize | Should -Be 'Standard_D2ds_v5'
        $o.burstableEnds | Should -BeTrue
        @($o.sizeChoices | Where-Object family -EQ 'Bsv2').Count | Should -Be 0
    }

    It 'the sample matches the schema' {
        $sample = Join-Path $script:repoRoot 'schemas' 'samples' 'target-advice.sample.json'
        Get-Content $sample -Raw | Test-Json -SchemaFile $script:schema | Should -BeTrue
        (Get-Content $sample -Raw | ConvertFrom-Json).schemaVersion | Should -Be 34 -Because 'SIZE-FALLTHROUGH-NOTE-1 made it 29 (sizesNotTaken); REBUILD-REMOVE-PLAN-1 made it 28 (no rebuild); AN-MANA-DRIVER-RULE-1 made it 27 (the reason no-mana-driver); DRIFT-11-OTHER-OPTIONS-1 made it 26 (the reason an-required-no-mana); NO-PLAN-SCOPE-1 made it 25 (the reason purchase-plan-out-of-scope); TEMP-DISK-PREVIEW-1 made it 24 (preview); v23 (REBUILD-PICKER-1) the in-place start; v22 (GEN1-ROUTE-GONE-1) took the Generation 1 route out; v18 (ADVISE-AN-1) added keptOn; v19 (DETECT-PATTERNS-1) four workload reasons outside the scope of this tool; v20 (HDD-OS-1) the OS disk type of each machine; v21 (IDENTITY-LOSS-1) what each target does to the system-assigned identity'
    }
}

Describe 'BSV2-TARGET-1: a planned B v1 machine, and its quota' {
    BeforeEach {
        $script:bsRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-bs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:bsCatalogList = @((BsCatalog).Values)
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { $script:bsCatalogList }
        Mock -ModuleName VmMigrationFactory Get-VmfVmUsage {
            @([pscustomobject]@{ Name = [pscustomobject]@{ Value = 'standardBsv2Family' }; CurrentValue = 0; Limit = 100 }) }
        $vm = BsVm -Size 'Standard_B2ms' -Name 'b2'
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:bsRun -Leaf); generatedUtc = '2026-10-09T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($vm) }
        InModuleScope VmMigrationFactory -Parameters @{ r = $script:bsRun; d = $doc } {
            param($r, $d)
            Initialize-VmfRun -RunPath $r -RunId (Split-Path $r -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $r -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $script:bsRun -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:bsRun 'assessment.json') | Out-Null
        $adviceVersion = InModuleScope VmMigrationFactory -Parameters @{ r = $script:bsRun } {
            param($r) Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $r -RelPath 'target-advice.json')) }
        # The default, saved as the page saves it: the option, and no size.
        Set-VmfTestTargetChoice -RunPath $script:bsRun -Default 'current' -ExpectedAdviceVersion $adviceVersion -ExpectedChoicesVersion '' `
            -Choices @(@{ vmId = $vm.vmId; option = 'v5' }) -OnBehalfOf @{ Identity = 'operator@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:bsRun 'assessment.json') -OutPath "$script:bsRun-migration" | Out-Null
        $script:bsPlan = Get-Content (Join-Path "$script:bsRun-migration" 'plan.json') -Raw | ConvertFrom-Json -Depth 40
    }
    AfterEach {
        foreach ($d in $script:bsRun, "$script:bsRun-migration") { if ($d -and (Test-Path $d)) { [System.IO.Directory]::Delete($d, $true) } }
    }

    It 'is planned on its Bsv2 size, as a SCSI resize on v5, and the rules give the same target again' {
        $e = @($script:bsPlan.entries)[0]
        $e.target.size | Should -Be 'Standard_B2s_v2'
        $e.policy.targetGeneration | Should -Be 'v5'
        $e.path | Should -Be 'A'
        InModuleScope VmMigrationFactory -Parameters @{ e = $e; c = (BsCatalog) } {
            param($e, $c)
            Get-VmfMoveKind -PlanEntry $e | Should -Be 'scsi-resize'
            Test-VmfPlannedTargetAgrees -Entry $e -CatalogBySize $c -Current 'v5' | Should -BeTrue
        }
    }

    It 'the quota check reads the family from the catalog, never from the name' {
        $r = Test-VmfQuota -PlanPath (Join-Path "$script:bsRun-migration" 'plan.json') -OutPath "$script:bsRun-migration"
        @($r.Claims).Count | Should -Be 1
        @($r.Claims)[0].size | Should -Be 'Standard_B2s_v2'
        @($r.Claims)[0].vmFamily | Should -Be 'standardBsv2Family' -Because 'the catalog says so (az vm list-skus, 2026-10-09)'
        @($r.Claims)[0].state | Should -Be 'QUOTA_VERIFIED'
    }
}
