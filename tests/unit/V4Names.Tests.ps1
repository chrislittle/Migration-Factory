#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V4-NAMES-1: an Intel v4 size with no s gets a v6 or v7 size that exists.
#
# The planner kept the letters of a size name and changed its version. Intel D
# and E on v6 and v7 have only s sizes (Dsv6, Ddsv6, Esv6, Edsv6 and the v7
# twins - there is no Dv6, Ddv6, Ev6 or Edv6), so:
#   - D4_v4  (Dv4, no temporary disk) tried only Standard_D4_v6;
#   - D4d_v4 (Ddv4, a temporary disk)  tried only Standard_D4d_v6;
#   - E8_v4 and E8d_v4 the same on E.
# None exists, and each machine was told "no candidate available in region" -
# a naming fact reported as a shortage in the region. Measured on main at
# 668a1812 against the real catalog below: all 30 Dv4, Ddv4, Ev4 and Edv4
# sizes, on v6 and on v7.
#
# The rule, from Microsoft's size pages (read 2026-10-04, held in
# data/target-families.json sources): Dv4 and Ev4 have no temporary disk, Ddv4
# and Edv4 have one on every size. So the planner adds the s and keeps the
# rest: D4_v4 -> D4s_v6, D4d_v4 -> D4ds_v6. Intel stays Intel. No size choice
# is added: a machine with no temporary disk is not offered one, and a machine
# with one keeps it - the same as Dsv4 and Ddsv4, which already had their v6
# sizes.
#
# The catalog is tests/fixtures/intel-v4-catalog-centralus.json: every Intel D
# and E v4 size and every Intel D and E size on v5, v6 and v7 that Azure lists
# in centralus (read 2026-10-04).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'intel-v4-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:sizes = @($fixture.sizes)
    function Global:I4Catalog {
        $c = @{}
        foreach ($s in $script:sizes) {
            $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
            $c[$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
        }
        $c
    }
    function Global:I4Vm {
        param([string]$Size = 'Standard_D4_v4', [string]$Os = 'Windows', [string]$Gen = 'V2', [string]$Arch = 'diskless', $Temp = 0)
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-04"
            name = 'app-04'; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; hyperVGeneration = $Gen
            os = $Os; osVersion = $(if ($Os -eq 'Windows') { '2022-datacenter-g2' } else { '22_04-lts-gen2' })
            sourceSize = $Size; sourceDiskArch = $Arch; sourceTempDisks = $Temp
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
}
AfterAll { Remove-Item 'function:\I4Catalog', 'function:\I4Vm' -ErrorAction SilentlyContinue }

Describe 'V4-NAMES-1: the data' {

    BeforeAll {
        $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $script:intel = @($script:doc.replacements.bySeries | Where-Object { @($_.sourceSeries) -match '^[DE]d?v4$' })
    }

    It 'Dv4, Ddv4, Ev4 and Edv4 each have a row; Ddv4 and Edv4 have a temporary disk on every size, Dv4 and Ev4 on none' {
        @($script:intel | ForEach-Object { $_.sourceSeries }) | Should -Be @('Dv4', 'Ddv4', 'Ev4', 'Edv4')
        foreach ($r in $script:intel) {
            $r.everySizeHasTemporaryDisk | Should -Be ([string]$r.sourceSeries -like '?dv4') -Because "$($r.sourceSeries) is read from its size page"
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
        }
    }

    It 'the rows say they are derived, and how' {
        foreach ($r in $script:intel) {
            $r.basis | Should -Be 'derived'
            [string]$r.how | Should -Match 'no replacement table for v4'
            [string]$r.how | Should -Match 'Intel'
        }
    }

    It 'each row names its own size page as a source, read on 2026-10-04, and the drift check watches it' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        foreach ($r in $script:intel) {
            $r.source | Should -Be "$(([string]$r.sourceSeries).ToLowerInvariant())-series"
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape($r.source))$" })
            $src.Count | Should -Be 1 -Because "'$($r.source)' must be one of the data file's sources"
            $src[0].readUtc | Should -Be '2026-10-04'
            $src[0].says | Should -Match 'temporary disk'
            $src[0].says | Should -Match 'Intel'
            $pinned | Should -Contain $r.source -Because "'$($r.source)' must be watched"
        }
    }

    It 'the pinned pages say what the rows say: no local storage on Dv4 and Ev4, one temporary disk on each Ddv4 and Edv4 size' {
        $root = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines' 'sizes'
        foreach ($pg in @('general-purpose/dv4-series', 'memory-optimized/ev4-series')) {
            (Get-Content (Join-Path $root "$pg.md") -Raw) | Should -Match 'No local storage present in this series'
        }
        foreach ($pg in @('general-purpose/ddv4-series', 'memory-optimized/edv4-series')) {
            $text = Get-Content (Join-Path $root "$pg.md") -Raw
            $text | Should -Not -Match 'No local storage present'
            $text | Should -Match '\| Standard\\_[DE]2d\\_v4 \| 1 \| 75 \|'
        }
    }

    It 'finds the row for each of the four series, and none for Dsv4, Ddsv4, Esv4 or Edsv4' {
        InModuleScope VmMigrationFactory {
            (Get-VmfSizeReplacement -SizeName 'Standard_D4_v4').sourceSeries | Should -Be @('Dv4')
            (Get-VmfSizeReplacement -SizeName 'Standard_D4d_v4').sourceSeries | Should -Be @('Ddv4')
            (Get-VmfSizeReplacement -SizeName 'Standard_E20_v4').sourceSeries | Should -Be @('Ev4')
            (Get-VmfSizeReplacement -SizeName 'Standard_E64d_v4').sourceSeries | Should -Be @('Edv4')
            foreach ($s in 'Standard_D4s_v4', 'Standard_D4ds_v4', 'Standard_E8s_v4', 'Standard_E8-4ds_v4') {
                Get-VmfSizeReplacement -SizeName $s | Should -BeNullOrEmpty -Because "$s already has a size of its own name on v6"
            }
        }
    }
}

Describe 'V4-NAMES-1: every Intel v4 size, against the sizes Azure offers' {

    BeforeAll { $script:cat = I4Catalog }

    It 'the catalog holds every Intel D and E v4 size, 80 of them' {
        @($script:cat.Keys | Where-Object { $_ -match '_v4$' }).Count | Should -Be 80
        foreach ($n in 2, 4, 8, 16, 32, 48, 64) { $script:cat.ContainsKey("Standard_D$($n)_v4") | Should -BeTrue }
        $script:cat.ContainsKey('Standard_D4_v6') | Should -BeFalse -Because 'Azure has no Dv6'
        $script:cat.ContainsKey('Standard_E8d_v7') | Should -BeFalse -Because 'Azure has no Edv7'
    }

    It '<Source> goes to <Target> on <Gen>' -ForEach @(
        foreach ($g in 'v5', 'v6', 'v7') {
            $s = if ($g -eq 'v5') { '' } else { 's' }
            foreach ($n in 2, 4, 8, 16, 32, 48, 64) {
                @{ Gen = $g; Source = "Standard_D$($n)_v4"; Target = "Standard_D$($n)$($s)_$g" }
                @{ Gen = $g; Source = "Standard_D$($n)d_v4"; Target = "Standard_D$($n)d$($s)_$g" }
            }
            foreach ($n in 2, 4, 8, 16, 20, 32, 48, 64) {
                @{ Gen = $g; Source = "Standard_E$($n)_v4"; Target = "Standard_E$($n)$($s)_$g" }
                @{ Gen = $g; Source = "Standard_E$($n)d_v4"; Target = "Standard_E$($n)d$($s)_$g" }
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

    It 'every Intel v4 size that gets a target keeps its processor, its temporary disk or its lack of one, and is not made smaller' {
        # The fixture is Intel only, so an AMD twin of every Intel s and ds
        # size on v5, v6 and v7 is added here: a planner that changed the
        # processor would then have somewhere to go, and this test would see it.
        $withAmd = I4Catalog
        foreach ($k in @($withAmd.Keys | Where-Object { $_ -match '^Standard_[DE]\d+(-\d+)?d?s_v[567]$' })) {
            $amd = $k -replace '^(Standard_[DE]\d+(?:-\d+)?)(d?s_v\d)$', '${1}a${2}'
            $withAmd[$amd] = [pscustomobject]@{ Name = $amd; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $withAmd[$k].Capabilities }
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = $withAmd } {
            $c.ContainsKey('Standard_D4as_v6') | Should -BeTrue
            $c.ContainsKey('Standard_E8ads_v7') | Should -BeTrue
            $bad = [System.Collections.Generic.List[string]]::new()
            $planned = 0
            foreach ($src in @($c.Keys | Where-Object { $_ -match '_v4$' } | Sort-Object)) {
                $srcTemp = (Get-VmfTempDiskCount -SkuEntry $c[$src] -SizeName $src) -gt 0
                $srcShape = Get-VmfSkuShape -SkuEntry $c[$src]
                foreach ($g in 'v5', 'v6', 'v7') {
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
            $planned | Should -BeGreaterThan 200
            $bad | Should -BeNullOrEmpty
        }
    }

    It 'no Intel v4 size is told its region has no size when the region has one in its own family and letters' {
        # The defect: a naming fact reported as a shortage. Every refusal left
        # is a size Azure really does not list (below).
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $refused = foreach ($src in @($c.Keys | Where-Object { $_ -match '_v4$' } | Sort-Object)) {
                foreach ($g in 'v5', 'v6', 'v7') {
                    $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration $g
                    if (-not $r.Target) { "$src $g" }
                }
            }
            # The constrained Esv4 and Edsv4 sizes on v7 (Azure lists no
            # constrained E v7 size), and the isolated E80is_v4 and E80ids_v4
            # (no isolated 80-vCPU size on v5, v6 or v7). Left, as the work
            # item says.
            foreach ($x in @($refused)) {
                $x | Should -Match '^Standard_E(\d+-\d+d?s_v4 v7|80id?s_v4 v[567])$' -Because "$x is refused"
            }
            @($refused).Count | Should -Be 24 -Because '9 constrained Esv4 and 9 Edsv4 sizes on v7, and E80is_v4 and E80ids_v4 on three series'
        }
    }

    It 'a constrained Esv4 size on v7 is refused with the v6 size that would work; the isolated E80is_v4 is refused on every series' {
        # V5-SUCCESSOR-1: Microsoft lists constrained E v7 sizes for AMD only,
        # and no 80-vCPU isolated size on v6 or v7, so those refusals say that
        # Microsoft has no such size. SIZE-LISTING-V5-1: on v5 too - Microsoft
        # lists no E80is or E80ids v5 size (SizeListingV5.Tests.ps1).
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4s_v4' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Code | Should -Be 'not-approved'
            $r.Reason | Should -Match 'This region has Standard_E8-4s_v6\. Choose v6 for this machine in the Choose each target step, then plan again\.'
            foreach ($g in 'v5', 'v6', 'v7') {
                (Get-VmfTargetSize -SourceSize 'Standard_E80is_v4' -CatalogBySize $c -TargetGeneration $g).Code | Should -Be 'not-approved'
            }
        }
    }

    It 'a v7 refusal for a Dv4 machine names the v6 size the same rules give, never a name that does not exist' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            foreach ($k in @($c.Keys | Where-Object { $_ -like '*_v7' })) { $c.Remove($k) }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v4' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Code | Should -Be 'not-in-region'
            $r.Reason | Should -Match 'tried: Standard_D4s_v7\)'
            # V7-REFUSAL-WORDS-1: the series is the machine's, not the wave's.
            $r.Reason | Should -Match 'this region has Standard_D4s_v6\. Choose v6 for this machine in the Choose each target step, then plan again\.$'
            $r.Reason | Should -Not -Match '(?i)the wave is set'
        }
    }

    It 'a region with no Intel s size says which sizes it looked for, and does not move the machine to another processor' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            foreach ($k in @($c.Keys | Where-Object { $_ -match '^Standard_D\d+d?s_v6$' })) { $c.Remove($k) }
            $c['Standard_D4as_v6'] = [pscustomobject]@{ Name = 'Standard_D4as_v6'; Capabilities = @() }
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4d_v4' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'tried: Standard_D4ds_v6\)'
        }
    }
}

Describe 'V4-NAMES-1: the temporary disk reading' {

    It 'a catalog reading wins: a Dv4 size the catalog says has a temporary disk is given the d size first, and the size without one as its other choice' {
        # The rule every series has (GEN-V5-1, V3-TEMPDISK-1): the size that
        # keeps a temporary disk first, and the size without one after it.
        InModuleScope VmMigrationFactory -Parameters @{ c = (I4Catalog) } {
            ($c['Standard_D4_v4'].Capabilities | Where-Object Name -eq 'MaxResourceVolumeMB').Value = '153600'
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4_v4' -CatalogBySize $c -TargetGeneration 'v6') | Should -Be @('Standard_D4ds_v6', 'Standard_D4s_v6')
        }
    }

    It 'with no reading, the page decides: Dv4 has none, Ddv4 has one' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4_v4' -TargetGeneration 'v6') | Should -Be @('Standard_D4s_v6')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E8_v4' -TargetGeneration 'v7') | Should -Be @('Standard_E8s_v7')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_D4d_v4' -TargetGeneration 'v6') | Should -Be @('Standard_D4ds_v6')
            @(Get-VmfDefaultSizeCandidates -SourceSize 'Standard_E8d_v4' -TargetGeneration 'v5') | Should -Be @('Standard_E8d_v5')
        }
    }

    It 'the assessment records what the page says for a size the catalog does not report: one temporary disk on Ddv4, none known on Dv4' {
        $rec = {
            param([string]$Size)
            $vm = [pscustomobject]@{
                id = '/s/rg/vm/a'; name = 'a'; resourceGroup = 'rg'; location = 'centralus'
                sku = $Size; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
                osDiskManagedId = '/s/rg/disks/a'; nicCount = 1; nicIds = @('/s/rg/nic/a')
            }
            InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { Get-VmfAssessmentRecord -Vm $v -SkuEntry $null }
        }
        $dd = & $rec 'Standard_D4d_v4'
        $dd.sourceDiskArch | Should -Be 'scsi-temp'
        $dd.sourceTempDisks | Should -Be 1
        @($dd.prepNeeded) | Should -Contain 'pagefile'
        $d = & $rec 'Standard_D4_v4'
        $d.sourceDiskArch | Should -Be 'diskless'
        @($d.prepNeeded) | Should -Not -Contain 'pagefile'
    }
}

Describe 'V4-NAMES-1: the path, the size choices and the options' {

    BeforeAll { $script:cat = I4Catalog }

    It 'Windows <Source> on <Gen> takes the path its s twin <Twin> takes: <Path>' -ForEach @(
        @{ Source = 'Standard_D4_v4'; Twin = 'Standard_D4s_v4'; Arch = 'diskless'; Temp = 0; Gen = 'v6'; Path = 'A' }
        @{ Source = 'Standard_E8_v4'; Twin = 'Standard_E8s_v4'; Arch = 'diskless'; Temp = 0; Gen = 'v7'; Path = 'A' }
        @{ Source = 'Standard_D4d_v4'; Twin = 'Standard_D4ds_v4'; Arch = 'scsi-temp'; Temp = 1; Gen = 'v6'; Path = 'A' }
        @{ Source = 'Standard_E8d_v4'; Twin = 'Standard_E8ds_v4'; Arch = 'scsi-temp'; Temp = 1; Gen = 'v7'; Path = 'A' }
        @{ Source = 'Standard_D4d_v4'; Twin = 'Standard_D4ds_v4'; Arch = 'scsi-temp'; Temp = 1; Gen = 'v5'; Path = 'A' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; tw = $Twin; a = $Arch; tmp = $Temp; g = $Gen; want = $Path } {
            $mine = Resolve-VmfEntryTarget -Assessment (I4Vm -Size $s -Arch $a -Temp $tmp) -CatalogBySize $c -TargetGeneration $g
            $twin = Resolve-VmfEntryTarget -Assessment (I4Vm -Size $tw -Arch $a -Temp $tmp) -CatalogBySize $c -TargetGeneration $g
            # On v6 and v7 both go to the same size; v5 keeps the letters (D4d_v5, D4ds_v5).
            if ($g -ne 'v5') { $mine.Mapping.Target | Should -Be $twin.Mapping.Target -Because 'the size without an s and its s twin go to the same size' }
            $mine.Mapping.Target | Should -Not -BeNullOrEmpty
            $mine.Path | Should -Be $want
            $twin.Path | Should -Be $want
            $mine.DiskArch | Should -Be $twin.DiskArch
        }
    }

    It 'Linux: an in-place upgrade (Path A)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            (Resolve-VmfEntryTarget -Assessment (I4Vm -Size 'Standard_D4d_v4' -Os 'Linux' -Arch 'scsi-temp' -Temp 1) -CatalogBySize $c -TargetGeneration 'v6').Path | Should -Be 'A'
        }
    }

    It 'no size choice is added: a Dv4 machine is not offered a temporary disk, and a Ddv4 machine keeps its own' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            @((Resolve-VmfEntryTarget -Assessment (I4Vm -Size 'Standard_D4_v4') -CatalogBySize $c -TargetGeneration 'v6').SizeChoices) | Should -BeNullOrEmpty
            @((Resolve-VmfEntryTarget -Assessment (I4Vm -Size 'Standard_D4d_v4' -Arch 'scsi-temp' -Temp 1) -CatalogBySize $c -TargetGeneration 'v6').SizeChoices) | Should -BeNullOrEmpty
            $t = Resolve-VmfEntryTarget -Assessment (I4Vm -Size 'Standard_D4_v4') -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_D4ds_v6'
            $t.Mapping.Code | Should -Be 'chosen-size-gone' -Because 'a size the machine was never offered is not planned'
        }
    }

    It 'a planned Dv4 machine agrees with the rules, so the wave editor does not call it changed' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $entry = [pscustomobject]@{ assessment = (I4Vm -Size 'Standard_D4_v4'); path = 'A'; target = [pscustomobject]@{ size = 'Standard_D4s_v6' } }
            Test-VmfPlannedTargetAgrees -Entry $entry -CatalogBySize $c -Current 'v6' | Should -BeTrue
        }
    }

    It 'a Generation 1 Dv4 machine on v6 is told the true reason - v6 takes Generation 2 only - not that its region has no size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v4' -CatalogBySize $c -TargetGeneration 'v6' -HyperVGeneration 'V1'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'gen1-no-size'
        }
    }

    It 'the target options of a Dv4 and an Edv4 machine are supported on v6 and v7, name the s size, and list no size choices' {
        $vms = @((I4Vm -Size 'Standard_D4_v4'), (I4Vm -Size 'Standard_E8d_v4' -Arch 'scsi-temp' -Temp 1))
        $vms[1].vmId = $vms[1].vmId -replace 'app-04$', 'app-05'; $vms[1].name = 'app-05'
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = $vms }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (I4Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $want = @{ 'app-04' = @{ v5 = 'Standard_D4_v5'; v6 = 'Standard_D4s_v6'; v7 = 'Standard_D4s_v7' }
                   'app-05' = @{ v5 = 'Standard_E8d_v5'; v6 = 'Standard_E8ds_v6'; v7 = 'Standard_E8ds_v7' } }
        foreach ($m in @($advice.machines)) {
            foreach ($series in 'v5', 'v6', 'v7') {
                $o = @($m.options) | Where-Object { $_.option -eq $series }
                $o.supported | Should -BeTrue -Because "$($m.name) on $series"
                $o.targetSize | Should -Be $want[[string]$m.name][$series]
                @($o.sizeChoices).Count | Should -Be 0
            }
        }
        $advice.assessmentHash = '0' * 64
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw
        Test-Json -Json ($advice | ConvertTo-Json -Depth 20) -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
    }
}
