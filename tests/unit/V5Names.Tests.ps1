#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V5-NAMES-1: an Intel v5 size with no s gets a v6 and v7 size that exists.
#
# The defect V4-NAMES-1 fixed for v4, one version later. The planner keeps the
# letters of a size name and changes its version. Intel D and E on v6 and v7
# have only s sizes (Dsv6, Ddsv6, Esv6, Edsv6 and the v7 twins - there is no
# Dv6, Ddv6, Ev6 or Edv6), so:
#   - D4_v5  (Dv5, no temporary disk) tried only Standard_D4_v6;
#   - D4d_v5 (Ddv5, a temporary disk)  tried only Standard_D4d_v6;
#   - E8_v5 and E8d_v5 the same on E.
# None exists, and each machine was told "no candidate available in region"
# (not-in-region) - a naming fact reported as a shortage in the region.
# Measured on fix/maker-check-1 at 1e1ac43a against the real catalog below:
# all 34 Dv5, Ddv5, Ev5 and Edv5 sizes, on v6 and on v7.
#
# The rule, from Microsoft's size pages (read 2026-10-17, held in
# data/target-families.json sources): Dv5 and Ev5 have no temporary disk, Ddv5
# and Edv5 have one on every size. So the planner adds the s and keeps the
# rest: D4_v5 -> D4s_v6, D4d_v5 -> D4ds_v6. Intel stays Intel. No size choice
# is added - the same rule V4-NAMES-1 gave Dv4, Ddv4, Ev4 and Edv4.
#
# The catalog is tests/fixtures/intel-v4-catalog-centralus.json: every Intel D
# and E size on v4, v5, v6 and v7 that Azure lists in centralus (read
# 2026-10-04). Its v5 sizes are the sources here.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'intel-v4-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:sizes = @($fixture.sizes)
    function Global:I5Catalog {
        $c = @{}
        foreach ($s in $script:sizes) {
            $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
            $c[$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
        }
        $c
    }
    function Global:I5Vm {
        param([string]$Size = 'Standard_D4_v5', [string]$Os = 'Windows', [string]$Gen = 'V2', [string]$Arch = 'diskless', $Temp = 0)
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-04"
            name = 'app-04'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; hyperVGeneration = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = $Size; sourceDiskArch = $Arch; sourceTempDisks = $Temp
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
    # The four series this item fixes, by the size-name rule Microsoft's pages use.
    $script:fixedSeries = '^Standard_[DE]\d+d?_v5$'
}
AfterAll { Remove-Item 'function:\I5Catalog', 'function:\I5Vm' -ErrorAction SilentlyContinue }

Describe 'V5-NAMES-1: the data' {

    BeforeAll {
        $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $script:intel = @($script:doc.replacements.bySeries | Where-Object { @($_.sourceSeries) -match '^[DE]d?v5$' })
    }

    It 'Dv5, Ddv5, Ev5 and Edv5 each have a row; Ddv5 and Edv5 have a temporary disk on every size, Dv5 and Ev5 on none' {
        @($script:intel | ForEach-Object { $_.sourceSeries }) | Should -Be @('Dv5', 'Ddv5', 'Ev5', 'Edv5')
        foreach ($r in $script:intel) {
            @($r.sourceSeries).Count | Should -Be 1
            $r.everySizeHasTemporaryDisk | Should -Be ([string]$r.sourceSeries -like '?dv5') -Because "$($r.sourceSeries) is read from its size page"
        }
    }

    It 'every target is an Intel series of the same family, one with a temporary disk and one without' {
        foreach ($r in $script:intel) {
            $family = ([string]$r.sourceSeries).Substring(0, 1)
            foreach ($g in 'v5', 'v6', 'v7') {
                @($r.targets.$g).Count | Should -Be 2
                foreach ($t in @($r.targets.$g)) { $t | Should -Match "^$($family)d?s?$g$" -Because "$t is a target of $($r.sourceSeries): Intel, no a and no p" }
                @($r.targets.$g | Where-Object { $_ -like "$($family)d*" }).Count | Should -Be 1
            }
            # v6 and v7 name only s sizes - that is the defect this fixes.
            foreach ($g in 'v6', 'v7') { foreach ($t in @($r.targets.$g)) { $t | Should -Match "s$g$" } }
            # v5 is the machine's own series: the row names the series with
            # and without a temporary disk, so the letters are kept there.
            @($r.targets.v5) | Should -Be @("$($family)v5", "$($family)dv5")
        }
    }

    It 'every v6 and v7 target is a series Microsoft has a size page for' {
        $root = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'sizes'
        foreach ($r in $script:intel) {
            $folder = if (([string]$r.sourceSeries).StartsWith('D')) { 'general-purpose' } else { 'memory-optimized' }
            foreach ($g in 'v6', 'v7') {
                foreach ($t in @($r.targets.$g)) {
                    Test-Path (Join-Path $root $folder "$($t.ToLowerInvariant())-series.md") | Should -BeTrue -Because "$t must be a series Microsoft lists"
                }
            }
        }
    }

    It 'the rows say they are derived, and how' {
        foreach ($r in $script:intel) {
            $r.basis | Should -Be 'derived'
            [string]$r.how | Should -Match 'no replacement table for v5'
            [string]$r.how | Should -Match 'Intel'
        }
    }

    It 'each row names its own size page as a source, read on 2026-10-17, and the drift check watches it' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        foreach ($r in $script:intel) {
            $r.source | Should -Be "$(([string]$r.sourceSeries).ToLowerInvariant())-series"
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape($r.source))$" })
            $src.Count | Should -Be 1 -Because "'$($r.source)' must be one of the data file's sources"
            $src[0].readUtc | Should -Be '2026-10-17'
            $src[0].says | Should -Match 'V5-NAMES-1'
            $src[0].says | Should -Match 'temporary disk'
            $src[0].says | Should -Match 'Intel'
            $pinned | Should -Contain $r.source -Because "'$($r.source)' must be watched"
        }
    }

    It 'the E v5 page keeps the DRIFT-5 fact it was already the source for' {
        $src = @($script:doc.sources | Where-Object { $_.url -match '/memory-optimized/ev5-series$' })
        $src[0].says | Should -Match 'DRIFT-5: Accelerated Networking Required'
    }

    It 'the pinned pages say what the rows say: no local storage on Dv5 and Ev5, one temporary disk on each Ddv5 and Edv5 size' {
        $root = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'sizes'
        foreach ($pg in @('general-purpose/dv5-series', 'memory-optimized/ev5-series')) {
            (Get-Content (Join-Path $root "$pg.md") -Raw) | Should -Match 'No local storage present in this series'
        }
        foreach ($pg in @('general-purpose/ddv5-series', 'memory-optimized/edv5-series')) {
            $text = Get-Content (Join-Path $root "$pg.md") -Raw
            $text | Should -Not -Match 'No local storage present'
            $text | Should -Match '\| Standard\\_[DE]2d\\_v5 \| 1 \| 75 \|'
        }
        foreach ($pg in @('general-purpose/dv5-series', 'general-purpose/ddv5-series', 'memory-optimized/ev5-series', 'memory-optimized/edv5-series')) {
            (Get-Content (Join-Path $root "$pg.md") -Raw) | Should -Match '\| Processor \|[^\r\n]*Intel'
        }
    }

    It 'finds the row for each of the four series, and none for the s, constrained, Dl, Eb or isolated v5 sizes' {
        InModuleScope VmMigrationFactory {
            (Get-VmfSizeReplacement -SizeName 'Standard_D4_v5').sourceSeries | Should -Be @('Dv5')
            (Get-VmfSizeReplacement -SizeName 'Standard_D96d_v5').sourceSeries | Should -Be @('Ddv5')
            (Get-VmfSizeReplacement -SizeName 'Standard_E20_v5').sourceSeries | Should -Be @('Ev5')
            (Get-VmfSizeReplacement -SizeName 'Standard_E64d_v5').sourceSeries | Should -Be @('Edv5')
            foreach ($s in 'Standard_D4s_v5', 'Standard_D4ds_v5', 'Standard_E8s_v5', 'Standard_E8-4ds_v5', 'Standard_D4ls_v5', 'Standard_D4lds_v5',
                'Standard_E8bs_v5', 'Standard_E8bds_v5', 'Standard_E104i_v5', 'Standard_E104id_v5', 'Standard_E104is_v5', 'Standard_E112ibs_v5') {
                Get-VmfSizeReplacement -SizeName $s | Should -BeNullOrEmpty -Because "$s is not one of the four series this item fixes"
            }
        }
    }
}

Describe 'V5-NAMES-1: every Intel v5 size, against the sizes Azure offers' {

    BeforeAll { $script:cat = I5Catalog }

    It 'the catalog holds every Dv5, Ddv5, Ev5 and Edv5 size, 34 of them, and no Dv6 or Edv7' {
        @($script:cat.Keys | Where-Object { $_ -match $script:fixedSeries }).Count | Should -Be 34
        $script:cat.ContainsKey('Standard_D4_v6') | Should -BeFalse -Because 'Azure has no Dv6'
        $script:cat.ContainsKey('Standard_E8d_v7') | Should -BeFalse -Because 'Azure has no Edv7'
    }

    It '<Source> goes to <Target> on <Gen>' -ForEach @(
        foreach ($g in 'v6', 'v7') {
            foreach ($n in 2, 4, 8, 16, 32, 48, 64, 96) {
                @{ Gen = $g; Source = "Standard_D$($n)_v5"; Target = "Standard_D$($n)s_$g" }
                @{ Gen = $g; Source = "Standard_D$($n)d_v5"; Target = "Standard_D$($n)ds_$g" }
            }
            foreach ($n in 2, 4, 8, 16, 20, 32, 48, 64, 96) {
                @{ Gen = $g; Source = "Standard_E$($n)_v5"; Target = "Standard_E$($n)s_$g" }
                @{ Gen = $g; Source = "Standard_E$($n)d_v5"; Target = "Standard_E$($n)ds_$g" }
            }
        }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; t = $Target; g = $Gen } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration $g
            $r.Target | Should -Be $t
            $r.Code | Should -Be 'mapped'
            @($r.Alternates) | Should -BeNullOrEmpty -Because 'one size keeps what the machine has; no size that does not exist is tried'
        }
    }

    It 'on v5 each of the 34 sizes keeps its own size, as before' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; f = $script:fixedSeries } {
            foreach ($src in @($c.Keys | Where-Object { $_ -match $f })) {
                (Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration 'v5').Target | Should -Be $src
            }
        }
    }

    It 'no Dv5, Ddv5, Ev5 or Edv5 size is told its region has no size, on v6 or v7' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; f = $script:fixedSeries } {
            $bad = foreach ($src in @($c.Keys | Where-Object { $_ -match $f } | Sort-Object)) {
                foreach ($g in 'v6', 'v7') {
                    $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration $g
                    if (-not $r.Target -or $r.Code -eq 'not-in-region') { "$src $g $($r.Code)" }
                }
            }
            @($bad) | Should -BeNullOrEmpty
        }
    }

    It 'every Intel v5 size that gets a target keeps its processor, its temporary disk or its lack of one, and is not made smaller' {
        # The fixture is Intel only, so an AMD twin of every Intel s and ds
        # size on v5, v6 and v7 is added here: a planner that changed the
        # processor would then have somewhere to go, and this test would see it.
        $withAmd = I5Catalog
        foreach ($k in @($withAmd.Keys | Where-Object { $_ -match '^Standard_[DE]\d+(-\d+)?d?s_v[567]$' })) {
            $amd = $k -replace '^(Standard_[DE]\d+(?:-\d+)?)(d?s_v\d)$', '${1}a${2}'
            $withAmd[$amd] = [pscustomobject]@{ Name = $amd; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $withAmd[$k].Capabilities }
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = $withAmd } {
            $c.ContainsKey('Standard_D4as_v6') | Should -BeTrue
            $c.ContainsKey('Standard_E8ads_v7') | Should -BeTrue
            $bad = [System.Collections.Generic.List[string]]::new()
            $planned = 0
            foreach ($src in @($c.Keys | Where-Object { $_ -match '^Standard_[DE]\d+(-\d+)?[a-z]*_v5$' -and $_ -notmatch '^Standard_[DE]\d+(-\d+)?[a-z]*a[a-z]*_v5$' } | Sort-Object)) {
                $srcTemp = (Get-VmfTempDiskCount -SkuEntry $c[$src] -SizeName $src) -gt 0
                $srcShape = Get-VmfSkuShape -SkuEntry $c[$src]
                foreach ($g in 'v6', 'v7') {
                    $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration $g
                    if (-not $r.Target) { continue }
                    $planned++
                    $t = [string]$r.Target
                    if (-not $c.ContainsKey($t)) { $bad.Add("$src -> $t on ${g}: not a size Azure offers") }
                    if ((Get-VmfSizeProcessor -SizeName $t) -ne 'Intel') { $bad.Add("$src -> $t on ${g}: not Intel") }
                    if (((Get-VmfTempDiskCount -SkuEntry $c[$t] -SizeName $t) -gt 0) -ne $srcTemp) { $bad.Add("$src -> $t on ${g}: the temporary disk changes") }
                    if ((Test-VmfSizeSmaller -Source $srcShape -Target (Get-VmfSkuShape -SkuEntry $c[$t])) -eq 'smaller') { $bad.Add("$src -> $t on ${g}: smaller") }
                }
            }
            $planned | Should -BeGreaterThan 180
            $bad | Should -BeNullOrEmpty
        }
    }

    It 'the only Intel v5 sizes left with no v6 or v7 size are the ones Microsoft gives none in this region' {
        # Each is a size Azure does not list with that name on that series,
        # and none is one of the four series this item fixes. V5-SUCCESSOR-1
        # holds them: the constrained Esv5 and Edsv5 sizes on v7 (Azure lists
        # no constrained E v7 size in centralus), the Ebsv5 and Ebdsv5 sizes
        # (Ebsv6 and Ebdsv6 exist, but not in centralus; there is no Ebsv7),
        # and the isolated E104i and E112ib v5 sizes (no isolated size of that
        # name on v6 or v7). V5-SUCCESSOR-1 gave each the fact that stops it:
        # see V5Successor.Tests.ps1.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $refused = foreach ($src in @($c.Keys | Where-Object { $_ -match '_v5$' } | Sort-Object)) {
                foreach ($g in 'v6', 'v7') {
                    $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration $g
                    if (-not $r.Target) { "$src $g" }
                }
            }
            foreach ($x in @($refused)) {
                $x | Should -Match '^Standard_E(\d+-\d+d?s_v5 v7|\d+bd?s_v5 v[67]|112ibd?s_v5 v[67]|104id?s?_v5 v[67])$' -Because "$x is refused"
            }
            @($refused).Count | Should -Be 66 -Because '22 constrained sizes on v7, 16 Eb sizes and 2 E112ib sizes on v6 and v7, and 4 E104i sizes on v6 and v7'
        }
    }

    It 'a v7 refusal for a Dv5 machine names the v6 size the same rules give, never a name that does not exist' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            foreach ($k in @($c.Keys | Where-Object { $_ -like '*_v7' })) { $c.Remove($k) }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v5' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Code | Should -Be 'not-in-region'
            $r.Reason | Should -Match 'tried: Standard_D4s_v7\)'
            $r.Reason | Should -Match 'this region has Standard_D4s_v6\. Choose v6 for this machine in the Choose each target step, then plan again\.'
            $r.Reason | Should -Not -Match '(?i)the wave is set'
        }
    }

    It 'a region with no Intel s size says which sizes it looked for, and does not move the machine to another processor' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            foreach ($k in @($c.Keys | Where-Object { $_ -match '^Standard_E\d+d?s_v6$' })) { $c.Remove($k) }
            $c['Standard_E8ads_v6'] = [pscustomobject]@{ Name = 'Standard_E8ads_v6'; Capabilities = @() }
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8d_v5' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'tried: Standard_E8ds_v6\)'
        }
    }
}

Describe 'V5-NAMES-1: the temporary disk reading' {

    It 'a catalog reading wins: a Dv5 size the catalog says has a temporary disk is given the d size first, and the size without one after it' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (I5Catalog) } {
            ($c['Standard_D4_v5'].Capabilities | Where-Object Name -eq 'MaxResourceVolumeMB').Value = '153600'
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4_v5' -CatalogBySize $c -TargetGeneration 'v6') | Should -Be @('Standard_D4ds_v6', 'Standard_D4s_v6')
        }
    }

    It 'with no reading, the page decides: Dv5 and Ev5 have none, Ddv5 and Edv5 have one' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4_v5' -TargetGeneration 'v6') | Should -Be @('Standard_D4s_v6')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E8_v5' -TargetGeneration 'v7') | Should -Be @('Standard_E8s_v7')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4d_v5' -TargetGeneration 'v6') | Should -Be @('Standard_D4ds_v6')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E8d_v5' -TargetGeneration 'v7') | Should -Be @('Standard_E8ds_v7')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E8d_v5' -TargetGeneration 'v5') | Should -Be @('Standard_E8d_v5')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4_v5' -TargetGeneration 'v5') | Should -Be @('Standard_D4_v5')
        }
    }

    It 'the assessment records what the page says for a size the catalog does not report: one temporary disk on Ddv5, none known on Dv5' {
        $rec = {
            param([string]$Size)
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = $Size; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/a'; nicCount = 1; nicIds = @('/s/rg/nic/a')
            }
            InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v -SkuEntry $null }
        }
        $dd = & $rec 'Standard_E8d_v5'
        $dd.sourceDiskArch | Should -Be 'scsi-temp'
        $dd.sourceTempDisks | Should -Be 1
        @($dd.prepNeeded) | Should -Contain 'pagefile'
        $d = & $rec 'Standard_E8_v5'
        $d.sourceDiskArch | Should -Be 'diskless'
        @($d.prepNeeded) | Should -Not -Contain 'pagefile'
    }
}

Describe 'V5-NAMES-1: the path, the size choices and the options' {

    BeforeAll { $script:cat = I5Catalog }

    It 'Windows <Source> on <Gen> takes the path its s twin <Twin> takes: <Path>' -ForEach @(
        @{ Source = 'Standard_D4_v5'; Twin = 'Standard_D4s_v5'; Arch = 'diskless'; Temp = 0; Gen = 'v6'; Path = 'A' }
        @{ Source = 'Standard_E8_v5'; Twin = 'Standard_E8s_v5'; Arch = 'diskless'; Temp = 0; Gen = 'v7'; Path = 'A' }
        @{ Source = 'Standard_D4d_v5'; Twin = 'Standard_D4ds_v5'; Arch = 'scsi-temp'; Temp = 1; Gen = 'v6'; Path = 'A' }
        @{ Source = 'Standard_E8d_v5'; Twin = 'Standard_E8ds_v5'; Arch = 'scsi-temp'; Temp = 1; Gen = 'v7'; Path = 'A' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; tw = $Twin; a = $Arch; tmp = $Temp; g = $Gen; want = $Path } {
            $mine = Resolve-VmfEntryTarget -Assessment (I5Vm -Size $s -Arch $a -Temp $tmp) -CatalogBySize $c -TargetGeneration $g
            $twin = Resolve-VmfEntryTarget -Assessment (I5Vm -Size $tw -Arch $a -Temp $tmp) -CatalogBySize $c -TargetGeneration $g
            $mine.Mapping.Target | Should -Not -BeNullOrEmpty
            $mine.Mapping.Target | Should -Be $twin.Mapping.Target -Because 'the size without an s and its s twin go to the same size'
            $mine.Path | Should -Be $want
            $twin.Path | Should -Be $want
            $mine.DiskArch | Should -Be $twin.DiskArch
        }
    }

    It 'Linux: an in-place upgrade (Path A)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            (Resolve-VmfEntryTarget -Assessment (I5Vm -Size 'Standard_D4d_v5' -Os 'Linux' -Arch 'scsi-temp' -Temp 1) -CatalogBySize $c -TargetGeneration 'v6').Path | Should -Be 'A'
        }
    }

    It 'no size choice is added: a Dv5 machine is not offered a temporary disk, and a Ddv5 machine keeps its own' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            @((Resolve-VmfEntryTarget -Assessment (I5Vm -Size 'Standard_D4_v5') -CatalogBySize $c -TargetGeneration 'v6').SizeChoices) | Should -BeNullOrEmpty
            @((Resolve-VmfEntryTarget -Assessment (I5Vm -Size 'Standard_D4d_v5' -Arch 'scsi-temp' -Temp 1) -CatalogBySize $c -TargetGeneration 'v6').SizeChoices) | Should -BeNullOrEmpty
            $t = Resolve-VmfEntryTarget -Assessment (I5Vm -Size 'Standard_D4_v5') -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D4ds_v6'
            $t.Mapping.Code | Should -Be 'chosen-size-gone' -Because 'a size the machine was never offered is not planned'
        }
    }

    It 'a planned Ev5 machine agrees with the rules, so the wave editor does not call it changed' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $entry = [pscustomobject]@{ assessment = (I5Vm -Size 'Standard_E8_v5'); path = 'A'; target = [pscustomobject]@{ size = 'Standard_E8s_v6' } }
            Test-VmfPlannedTargetAgrees -Entry $entry -CatalogBySize $c -Current 'v6' | Should -BeTrue
        }
    }

    It 'a Generation 1 Dv5 machine on v6 is told the true reason - v6 takes Generation 2 only - not that its region has no size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v5' -CatalogBySize $c -TargetGeneration 'v6' -HyperVGeneration 'V1'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'gen1-no-size'
        }
    }

    It 'the target options: a Dv5 and an Edv5 machine are supported on v6 and v7 with the s size and no size choices; on v5 they are already on the series' {
        $vms = @((I5Vm -Size 'Standard_D4_v5'), (I5Vm -Size 'Standard_E8d_v5' -Arch 'scsi-temp' -Temp 1), (I5Vm -Size 'Standard_D4_v4'))
        $vms[1].vmId = $vms[1].vmId -replace 'app-04$', 'app-05'; $vms[1].name = 'app-05'
        $vms[2].vmId = $vms[2].vmId -replace 'app-04$', 'app-06'; $vms[2].name = 'app-06'
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = $vms }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (I5Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $want = @{ 'app-04' = @{ v6 = 'Standard_D4s_v6'; v7 = 'Standard_D4s_v7' }
                   'app-05' = @{ v6 = 'Standard_E8ds_v6'; v7 = 'Standard_E8ds_v7' } }
        foreach ($m in @($advice.machines | Where-Object { $_.name -in 'app-04', 'app-05' })) {
            foreach ($series in 'v6', 'v7') {
                $o = @($m.options) | Where-Object { $_.option -eq $series }
                $o.supported | Should -BeTrue -Because "$($m.name) on $series"
                $o.targetSize | Should -Be $want[[string]$m.name][$series]
                $o.processorChange | Should -BeFalse
                @($o.sizeChoices).Count | Should -Be 0
            }
            $v5 = @($m.options) | Where-Object { $_.option -eq 'v5' }
            $v5.supported | Should -BeFalse
            @($v5.notSupported) | Should -Be @('already-on-series') -Because 'a v5 machine is already on v5, as before'
        }
        # The v5 target itself still works: a Dv4 machine goes to D4_v5, a
        # resize on SCSI, and Intel D v5 requires accelerated networking.
        $v4 = @($advice.machines | Where-Object { $_.name -eq 'app-06' })[0]
        $o5 = @($v4.options) | Where-Object { $_.option -eq 'v5' }
        $o5.supported | Should -BeTrue
        $o5.targetSize | Should -Be 'Standard_D4_v5'
        $o5.move | Should -Be 'scsi-resize'
        $o5.acceleratedNetworking.required | Should -BeTrue
        $advice.assessmentHash = '0' * 64
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw
        Test-Json -Json ($advice | ConvertTo-Json -Depth 20) -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
    }
}
