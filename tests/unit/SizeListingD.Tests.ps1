#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SIZE-LISTING-D-1: a D machine with no v5, v6 or v7 size of its own name is
# told WHICH fact stops it - Microsoft has no size of that name, or this region
# does not list one - the same as V5-SUCCESSOR-1 and SIZE-LISTING-V5-1 did for
# the E family.
#
# The defect: the size listing (data/target-families.json microsoftSizes)
# covered the E family only. For a D size it said nothing, so every D refusal
# kept the region fact: "no candidate available in region". A Dv2 machine such
# as D11_v2 tries D11_v5, D11_v6 and D11_v7, and Microsoft has none of them - a
# shortage another region could fix, which is false. And a D size Microsoft
# lists, in a region that does not, was not told that Microsoft lists it.
#
# The facts are data: the size names of every D and Dl size page of v5, v6 and
# v7, Intel and AMD, in the general purpose folder, and the four Dn v6 pages
# (Dnsv6, Dndsv6, Dnlsv6, Dnldsv6), which Microsoft keeps in the memory
# optimized folder. A test below holds each list equal to its pinned page, so a
# page that changes (the drift check) fails here until the data is read again.
#
# And an old D size the tool sizes by shape (Dv2) keeps the reason of the shape
# route: a size the catalog gives no vCPUs and memory for is told that, never
# the name rule's answer, which is about a size this machine never tries.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:SLDCatalogFrom {
        param([string]$Fixture)
        $data = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $Fixture) -Raw | ConvertFrom-Json
        $c = @{}
        foreach ($s in @($data.sizes)) {
            $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
            $c[$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps
                LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) }) }
        }
        $c
    }
    # The size names the size tables of a pinned page list, as short names
    # (D8s_v5). A table row starts with the size name.
    function Global:SLDPageSizes {
        param([string]$Path, [string]$Pattern = '^\| Standard\\_(D\d+(?:-\d+)?[a-z]*)\\_(v[5-7])\b')
        $names = foreach ($line in Get-Content $Path) {
            if ($line -match $Pattern) { "$($Matches[1])_$($Matches[2])" }
        }
        @($names | Select-Object -Unique)
    }
    function Global:SLDMachine {
        param([string]$Size, [string]$Gen = 'V2')
        [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-12'
            name = 'app-12'; location = 'centralus'; gen = $Gen; hyperVGeneration = $Gen; os = 'Linux'; osVersion = '22_04-lts-gen2'
            classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            nicCount = 1; dataDiskCount = 0; acceleratedNicCount = 0; platformManaged = $false
        }
    }
    $script:pagesRoot = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines'
    $script:gpRoot = Join-Path $script:pagesRoot 'sizes' 'general-purpose'
    $script:memRoot = Join-Path $script:pagesRoot 'sizes' 'memory-optimized'
    $script:dnPages = @('dndsv6-series', 'dnldsv6-series', 'dnlsv6-series', 'dnsv6-series')
    $script:intelCatalog = SLDCatalogFrom 'intel-v4-catalog-centralus.json'
    $script:intelSizes = @($script:intelCatalog.Keys)
}
AfterAll { Remove-Item 'function:\SLDCatalogFrom', 'function:\SLDPageSizes', 'function:\SLDMachine' -ErrorAction SilentlyContinue }

Describe 'SIZE-LISTING-D-1: the data' {

    BeforeAll {
        $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $script:ms = $script:doc.microsoftSizes
        $script:watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $script:pinned = @(foreach ($f in $script:watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
        $script:gpPages = @(Get-ChildItem $script:gpRoot -File | ForEach-Object { $_.BaseName } | Where-Object { $_ -match '^d[a-z]*v[5-7]-series$' } | Sort-Object)
        $script:dPages = @(@($script:gpPages) + @($script:dnPages) | Sort-Object)
    }

    It 'covers the D family on v5, v6 and v7, Intel and AMD, and still the E family' {
        $d = @($script:ms.covers | Where-Object { $_.family -ceq 'D' })
        $d.Count | Should -Be 1
        @($d[0].generations) | Should -Be @('v5', 'v6', 'v7')
        @($d[0].processors) | Should -Be @('Intel', 'AMD')
        @($script:ms.covers | Where-Object { $_.family -ceq 'E' }).Count | Should -Be 1
        @($script:ms.covers).Count | Should -Be 2
    }

    It 'was read on 2026-11-03, the day the drift check read every pinned page and pinned the Dn v6 pages' {
        $script:ms.readUtc | Should -Be '2026-11-03'
    }

    It 'the pinned D pages of v5, v6 and v7 are the Intel and AMD D and Dl pages, and none is Arm64, confidential or Dn in the general purpose folder' {
        $script:gpPages.Count | Should -Be 24
        @($script:gpPages | Where-Object { $_ -match '^d[cpn]' }) | Should -BeNullOrEmpty
        foreach ($n in 'dv5-series', 'dsv5-series', 'ddv5-series', 'ddsv5-series', 'dasv5-series', 'dadsv5-series', 'dlsv5-series', 'dldsv5-series',
                       'dsv6-series', 'ddsv6-series', 'dasv6-series', 'dadsv6-series', 'dlsv6-series', 'dldsv6-series', 'dalsv6-series', 'daldsv6-series',
                       'dsv7-series', 'ddsv7-series', 'dasv7-series', 'dadsv7-series', 'dlsv7-series', 'dldsv7-series', 'dalsv7-series', 'daldsv7-series') {
            $script:gpPages | Should -Contain $n
        }
    }

    It 'holds every pinned D page of v5, v6 and v7, and the four Dn v6 pages' {
        foreach ($n in $script:dnPages) { Test-Path (Join-Path $script:memRoot "$n.md") | Should -BeTrue -Because "$n must be pinned with its text" }
        foreach ($n in $script:dPages) {
            $script:pinned | Should -Contain $n -Because "the drift check must watch '$n'"
            @($script:ms.pages | Where-Object { $_.page -eq $n }).Count | Should -Be 1 -Because "the data must hold '$n'"
        }
        $inData = @($script:ms.pages | Where-Object { $_.page -match '^d[a-z]*v[5-7]-series$' } | ForEach-Object { [string]$_.page } | Sort-Object)
        $inData | Should -Be $script:dPages
    }

    It 'each D page list is the size table of its pinned page' {
        foreach ($n in $script:dPages) {
            $folder = if ($script:dnPages -contains $n) { $script:memRoot } else { $script:gpRoot }
            $want = @(SLDPageSizes -Path (Join-Path $folder "$n.md"))
            $want.Count | Should -BeGreaterOrEqual 8 -Because "$n has a size table"
            $pg = @($script:ms.pages | Where-Object { $_.page -eq $n })[0]
            @($pg.sizes) | Should -Be $want -Because "the data must be what $n lists"
        }
    }

    It 'the pages say what the refusals rely on: <What>' -ForEach @(
        @{ What = 'Dv5 is D2_v5 to D96_v5'; Page = 'dv5-series'; Has = @('D2_v5', 'D96_v5'); HasNot = @('D11_v5', 'D1_v5') }
        @{ What = 'Dsv7 reaches D372s_v7'; Page = 'dsv7-series'; Has = @('D2s_v7', 'D372s_v7'); HasNot = @() }
        @{ What = 'Dalsv7 reaches D160als_v7'; Page = 'dalsv7-series'; Has = @('D2als_v7', 'D160als_v7'); HasNot = @() }
        @{ What = 'Dnsv6 is D2ns_v6 to D128ns_v6'; Page = 'dnsv6-series'; Has = @('D2ns_v6', 'D128ns_v6'); HasNot = @() }
    ) {
        $pg = @($script:ms.pages | Where-Object { $_.page -eq $Page })[0]
        foreach ($n in $Has) { @($pg.sizes) | Should -Contain $n }
        foreach ($n in $HasNot) { @($pg.sizes) | Should -Not -Contain $n }
    }

    It 'no D size page of v6 or v7 lists a size with no s, and no AMD Dl page of v5 exists' {
        $all = @(foreach ($pg in @($script:ms.pages | Where-Object { $_.page -match '^d' })) { @($pg.sizes) })
        @($all | Where-Object { $_ -match '^D\d+d?_v[67]$' }) | Should -BeNullOrEmpty -Because 'Microsoft has no Dv6, Ddv6, Dv7 or Ddv7 series'
        @($all | Where-Object { $_ -match '^D\d+al' -and $_ -like '*_v5' }) | Should -BeNullOrEmpty -Because 'Microsoft has no Dalsv5 or Daldsv5 series'
        Test-Path (Join-Path $script:gpRoot 'dalsv5-series.md') | Should -BeFalse
    }

    It 'the constrained vCPU page lists no constrained D size on v5, v6 or v7, so the data holds none' {
        $want = @(SLDPageSizes -Path (Join-Path $script:pagesRoot 'constrained-vcpu.md') -Pattern '^\| Standard\\_(DS?\d+-\d+[a-z]*)\\_(v[5-7])\b')
        $want | Should -BeNullOrEmpty
        (Get-Content (Join-Path $script:pagesRoot 'constrained-vcpu.md') -Raw) | Should -Match ([regex]::Escape('| Standard\_DS13-4\_v2 |')) -Because 'the page does list the constrained DS v2 sizes, so the pattern can find a D row'
        $all = @(foreach ($pg in @($script:ms.pages)) { @($pg.sizes) })
        @($all | Where-Object { $_ -match '^D\w*-\d+' }) | Should -BeNullOrEmpty
    }

    It 'every D v5, v6 and v7 size the real centralus catalog lists is one the data holds' {
        $known = @(foreach ($pg in @($script:ms.pages)) { foreach ($s in @($pg.sizes)) { "Standard_$s" } })
        $inRegion = @($script:intelSizes | Where-Object { $_ -match '^Standard_D\d+(-\d+)?[a-z]*_v[5-7]$' })
        $inRegion.Count | Should -Be 168
        foreach ($n in $inRegion) { $known | Should -Contain $n -Because "$n is in the catalog, so Microsoft lists it" }
    }

    It 'every D page is a source of the data file, read on the date the listing gives, and says what it is used for' {
        foreach ($n in $script:dPages) {
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape($n))$" })
            $src.Count | Should -Be 1 -Because "'$n' must be one of the data file's sources"
            $src[0].says | Should -Match 'SIZE-LISTING-D-1'
            # A source with other facts of its own date (dsv5, dv5, ddv5, dsv6)
            # says the date of its listing sentence in the text.
            if ($src[0].readUtc -ne $script:ms.readUtc) {
                $src[0].says | Should -Match "SIZE-LISTING-D-1, read $($script:ms.readUtc)" -Because "the refusal says the pages were read on $($script:ms.readUtc)"
            }
            $folder = if ($script:dnPages -contains $n) { 'memory-optimized' } else { 'general-purpose' }
            $src[0].url | Should -BeExactly "https://learn.microsoft.com/azure/virtual-machines/sizes/$folder/$n"
        }
    }

    It 'the drift check watches the Dn v6 pages and a Dn page of v7, and never an Arm64 or confidential D page' {
        $mem = [string](@($script:watch.folders | Where-Object { $_.path -eq 'azure/virtual-machines/sizes/memory-optimized' })[0].include)
        foreach ($n in 'dnsv6-series', 'dndsv6-series', 'dnlsv6-series', 'dnldsv6-series', 'dnsv7-series', 'dnldsv7-series', 'ensv6-series') {
            $n | Should -Match $mem -Because "a page named $n must be watched"
        }
        $gp = [string](@($script:watch.folders | Where-Object { $_.path -eq 'azure/virtual-machines/sizes/general-purpose' })[0].include)
        foreach ($n in 'dsv5-series', 'dalsv6-series', 'daldsv7-series') { $n | Should -Match $gp }
        foreach ($n in 'dpsv6-series', 'dpldsv5-series', 'dcasv5-series', 'dcesv6-series') {
            $n | Should -Not -Match $gp -Because "$n is Arm64 or confidential, outside the scope of this tool"
            $n | Should -Not -Match $mem
        }
    }
}

Describe 'SIZE-LISTING-D-1: the size listing for D' {

    It '<Size> - Microsoft lists it: <Listed>' -ForEach @(
        @{ Size = 'Standard_D8s_v5'; Listed = $true; Page = 'dsv5-series' }
        @{ Size = 'Standard_D8_v5'; Listed = $true; Page = 'dv5-series' }
        @{ Size = 'Standard_D8ls_v5'; Listed = $true; Page = 'dlsv5-series' }
        @{ Size = 'Standard_D8ads_v5'; Listed = $true; Page = 'dadsv5-series' }
        @{ Size = 'Standard_D8als_v6'; Listed = $true; Page = 'dalsv6-series' }
        @{ Size = 'Standard_D8nds_v6'; Listed = $true; Page = 'dndsv6-series' }
        @{ Size = 'Standard_D192ds_v6'; Listed = $true; Page = 'ddsv6-series' }
        @{ Size = 'Standard_D372s_v7'; Listed = $true; Page = 'dsv7-series' }
        @{ Size = 'Standard_D160alds_v7'; Listed = $true; Page = 'daldsv7-series' }
        @{ Size = 'standard_d8S_v7'; Listed = $true; Page = 'dsv7-series' }
        @{ Size = 'Standard_D11_v5'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D1_v6'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D8_v6'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D8d_v7'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D8als_v5'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D80s_v6'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D8-4s_v6'; Listed = $false; Page = $null }
        @{ Size = 'Standard_D8ns_v7'; Listed = $false; Page = $null }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; l = $Listed; pg = $Page } {
            $r = Get-VmfMicrosoftSizeListing -SizeName $s
            $r.Listed | Should -Be $l
            $r.Page | Should -Be $pg
            $r.ReadUtc | Should -Be (Get-VmfTargetFamilyData).microsoftSizes.readUtc
        }
    }

    It 'answers nothing for a size the data does not cover: <Size>' -ForEach @(
        @{ Size = 'Standard_D8s_v4' }
        @{ Size = 'Standard_D11_v2' }
        @{ Size = 'Standard_DS11_v5' }
        @{ Size = 'Standard_D8ps_v6' }
        @{ Size = 'Standard_F8as_v7' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size } {
            $r = Get-VmfMicrosoftSizeListing -SizeName $s
            $r.Listed | Should -BeNullOrEmpty
            $r.ReadUtc | Should -BeNullOrEmpty
        }
    }

    It 'no isolated D size is listed on v5, v6 or v7' {
        InModuleScope VmMigrationFactory {
            foreach ($g in 'v5', 'v6', 'v7') {
                foreach ($maker in 'Intel', 'AMD') { @(Get-VmfMicrosoftIsolatedSizes -Family 'D' -TargetGeneration $g -Processor $maker) | Should -BeNullOrEmpty }
            }
        }
    }
}

Describe 'SIZE-LISTING-D-1: a D machine, against the sizes Azure offers' {

    It 'a D machine whose size Microsoft lists, and the region does not, is told both on <Series>' -ForEach @(
        @{ Series = 'v5' }
        @{ Series = 'v6' }
        @{ Series = 'v7' }
    ) {
        # Intel: the region's catalog without the one size this machine tries.
        $c = $script:intelCatalog.Clone(); $c.Remove("Standard_D8s_$Series")
        InModuleScope VmMigrationFactory -Parameters @{ c = $c; g = $Series } {
            $read = (Get-VmfTargetFamilyData).microsoftSizes.readUtc
            $r = Get-VmfTargetSize -SourceSize 'Standard_D8s_v4' -CatalogBySize $c -TargetGeneration $g
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Match ([regex]::Escape("no candidate available in region (tried: Standard_D8s_$g). Microsoft lists Standard_D8s_$g (the dsv$($g.Substring(1))-series page, read $read), and this region does not list it."))
            if ($g -eq 'v7') { $r.Reason | Should -Match ([regex]::Escape('This region has Standard_D8s_v6.')) }
        }
    }

    It 'an AMD D machine whose sizes Microsoft lists, in a region with no AMD size, is told the region fact and both pages on <Series>' -ForEach @(
        @{ Series = 'v5' }
        @{ Series = 'v6' }
        @{ Series = 'v7' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:intelCatalog; g = $Series } {
            $read = (Get-VmfTargetFamilyData).microsoftSizes.readUtc
            $v = $g.Substring(1)
            $r = Get-VmfTargetSize -SourceSize 'Standard_D8as_v4' -CatalogBySize $c -TargetGeneration $g
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Match ([regex]::Escape("tried: Standard_D8ads_$g, Standard_D8as_$g)"))
            $r.Reason | Should -Match ([regex]::Escape("Microsoft lists Standard_D8ads_$g (the dadsv$v-series page, read $read) and Standard_D8as_$g (the dasv$v-series page, read $read), and this region does not list them."))
        }
    }

    It 'a <Source> machine is told Microsoft lists no <Tried>, never that its region has none, on <Series>' -ForEach @(
        @{ Source = 'Standard_D11_v2'; Series = 'v5'; Tried = 'Standard_D11_v5' }
        @{ Source = 'Standard_D11_v2'; Series = 'v6'; Tried = 'Standard_D11_v6' }
        @{ Source = 'Standard_D11_v2'; Series = 'v7'; Tried = 'Standard_D11_v7' }
        @{ Source = 'Standard_D15_v2'; Series = 'v5'; Tried = 'Standard_D15_v5' }
        @{ Source = 'Standard_D2_v2'; Series = 'v6'; Tried = 'Standard_D2_v6' }
        @{ Source = 'Standard_D2_v2'; Series = 'v7'; Tried = 'Standard_D2_v7' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:intelCatalog; s = $Source; g = $Series; t = $Tried } {
            $read = (Get-VmfTargetFamilyData).microsoftSizes.readUtc
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration $g
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            $r.NotListed | Should -BeTrue
            $r.Reason | Should -Match ([regex]::Escape("no $g size for this machine is one Microsoft lists: its size pages (read $read) have no $t. This is not a shortage in this region."))
            $r.Reason | Should -Not -Match 'no candidate available in region'
            $r.Reason | Should -Not -Match 'isolated'
        }
    }

    It 'with no catalog, a D size Microsoft does not list is not planned, and one it lists still is' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D11_v2' -TargetGeneration 'v6'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            (Get-VmfTargetSize -SourceSize 'Standard_D8s_v4' -TargetGeneration 'v6').Target | Should -Be 'Standard_D8s_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D8ls_v5' -TargetGeneration 'v7').Target | Should -Be 'Standard_D8ls_v7'
        }
    }

    It 'a D size the region lists is planned, whatever the pages say' {
        # The size number of D11_v2 is not its vCPU count, so the catalog gives
        # its shape (from the real catalog of old sizes), and the D11_v6 the
        # region is made to list has more vCPUs and memory.
        $c = $script:intelCatalog.Clone()
        $c['Standard_D11_v2'] = (SLDCatalogFrom 'old-size-catalog-centralus.json')['Standard_D11_v2']
        $c['Standard_D11_v6'] = [pscustomobject]@{ Name = 'Standard_D11_v6'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $c['Standard_D8s_v6'].Capabilities }
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            (Get-VmfTargetSize -SourceSize 'Standard_D11_v2' -CatalogBySize $c -TargetGeneration 'v6').Target | Should -Be 'Standard_D11_v6'
        }
    }

    It 'every D size of the real centralus catalog still gets a target on v5, v6 and v7' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:intelCatalog } {
            $refused = [System.Collections.Generic.List[string]]::new()
            foreach ($src in @($c.Keys | Where-Object { $_ -match '^Standard_D\d+[a-z]*_v[45]$' } | Sort-Object)) {
                foreach ($g in 'v5', 'v6', 'v7') {
                    $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration $g
                    if (-not $r.Target) { $refused.Add("$src $g -> $($r.Code)") }
                }
            }
            $refused | Should -BeNullOrEmpty
        }
    }
}

Describe 'SIZE-LISTING-D-1: an old D size keeps the reason of the route by shape' {

    BeforeAll {
        $script:oldCatalog = SLDCatalogFrom 'old-size-catalog-centralus.json'
        $script:dv2 = @($script:oldCatalog.Keys | Where-Object { $_ -match '^Standard_D\d+_v2$' } | Sort-Object)
    }

    It 'the real catalog holds the Dv2 sizes, so this cannot pass by reading nothing' {
        $script:dv2.Count | Should -Be 10
        $script:dv2 | Should -Contain 'Standard_D11_v2'
    }

    It 'a Generation 2 Dv2 machine still gets a size by shape on v5, v6 and v7' {
        foreach ($n in $script:dv2) {
            foreach ($g in 'v5', 'v6', 'v7') {
                $t = InModuleScope VmMigrationFactory -Parameters @{ v = (SLDMachine $n); c = $script:oldCatalog; g = $g } {
                    Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g
                }
                $t.Mapping.Target | Should -Match "^Standard_[DE]\d+[a-z]*_$g$" -Because "$n on $g"
            }
        }
    }

    It 'a Dv2 size whose vCPUs and memory the catalog does not give is told so, never that Microsoft lists no size of its name' {
        $wrong = [System.Collections.Generic.List[string]]::new()
        foreach ($n in $script:dv2) {
            $c = $script:oldCatalog.Clone(); $c.Remove($n)
            foreach ($g in 'v5', 'v6', 'v7') {
                $t = InModuleScope VmMigrationFactory -Parameters @{ v = (SLDMachine $n); c = $c; g = $g } {
                    Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g
                }
                if ($t.Mapping.Target -or $t.Mapping.Code -ne 'shape-unknown' -or $t.Mapping.Reason -notmatch [regex]::Escape("does not give the vCPUs and memory of $n")) {
                    $wrong.Add("$n $g -> $($t.Mapping.Code): $($t.Mapping.Reason)")
                }
            }
        }
        $wrong | Should -BeNullOrEmpty
    }

    It 'a Dv2 size that no size by shape fits is told the shape it looked for, never that Microsoft lists no size of its name' {
        # D15_v2 with more vCPUs and memory than any size in the catalog.
        $c = $script:oldCatalog.Clone()
        $caps = @(foreach ($cap in @($c['Standard_D15_v2'].Capabilities)) {
                if ($cap.Name -eq 'vCPUs' -or $cap.Name -eq 'vCPUsAvailable') { [pscustomobject]@{ Name = $cap.Name; Value = '4000' } }
                elseif ($cap.Name -eq 'MemoryGB') { [pscustomobject]@{ Name = $cap.Name; Value = '64000' } }
                else { $cap } })
        $c['Standard_D15_v2'] = [pscustomobject]@{ Name = 'Standard_D15_v2'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
        foreach ($g in 'v5', 'v6', 'v7') {
            $t = InModuleScope VmMigrationFactory -Parameters @{ v = (SLDMachine 'Standard_D15_v2'); c = $c; g = $g } {
                Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g
            }
            $t.Mapping.Target | Should -BeNullOrEmpty
            $t.Mapping.Code | Should -Be 'no-shape-fit' -Because $g
            $t.Mapping.Reason | Should -Match "with at least 4000 vCPUs and 64000 GiB" -Because $g
        }
    }
}
