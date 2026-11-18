#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SIZE-LISTING-V5-1: a machine with no v5 size of its own name is told WHICH
# fact stops it - Microsoft has no size of that name, or this region does not
# list one - the same as V5-SUCCESSOR-1 did for v6 and v7.
#
# The defect: the size listing (data/target-families.json microsoftSizes)
# covered the E family on v6 and v7 only. On v5 it said nothing, so a v5
# refusal kept the region fact. The real centralus catalog has one:
# Standard_E80is_v4 and Standard_E80ids_v4 try Standard_E80is_v5 and
# Standard_E80ids_v5, which Microsoft does not list (its isolated E v5 sizes
# are the E104i and E112i sizes). The machine read "no candidate available in
# region" - a shortage another region could fix, which is false.
#
# The facts are data: the size names of every E size page of v5 (Esv5, Edsv5,
# Ev5, Edv5, Easv5, Eadsv5 and the Eb v5 page ebdsv5-ebsv5-series) and the v5
# rows of the constrained vCPU page. A test below holds each list equal to its
# pinned page, so a page that changes (the drift check) fails here until the
# data is read again.
#
# And an isolated machine is told only the isolated sizes of ITS processor: on
# v5 Microsoft lists isolated AMD E sizes too (E112ias_v5, E112iads_v5), and a
# machine keeps its processor maker.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'intel-v4-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:sizes = @($fixture.sizes)
    function Global:SL5Catalog {
        $c = @{}
        foreach ($s in $script:sizes) {
            $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
            $c[$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
        }
        $c
    }
    # The size names the size tables of a pinned page list, as short names
    # (E8s_v5). A table row starts with the size name. The Edv5 page writes
    # its isolated size as "Standard\_E104id\_v52": a footnote mark that lost
    # its superscript. The version is one digit, so a digit after it is not
    # part of the name (Azure lists Standard_E104id_v5; a test below says so).
    function Global:SL5PageSizes {
        param([string]$Path, [string]$Pattern = '^\| Standard\\_(E\d+(?:-\d+)?[a-z]*)\\_(v[5-7])\d?\b')
        $names = foreach ($line in Get-Content $Path) {
            if ($line -match $Pattern) { "$($Matches[1])_$($Matches[2])" }
        }
        @($names | Select-Object -Unique)
    }
    $script:pagesRoot = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines'
    $script:memRoot = Join-Path $script:pagesRoot 'sizes' 'memory-optimized'
    $script:v5Pages = @('esv5-series', 'edsv5-series', 'ev5-series', 'edv5-series', 'easv5-series', 'eadsv5-series', 'ebdsv5-ebsv5-series')
}
AfterAll { Remove-Item 'function:\SL5Catalog', 'function:\SL5PageSizes' -ErrorAction SilentlyContinue }

Describe 'SIZE-LISTING-V5-1: the data' {

    BeforeAll {
        $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $script:ms = $script:doc.microsoftSizes
        $script:watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $script:pinned = @(foreach ($f in $script:watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
    }

    It 'covers the E family on v5, v6 and v7, Intel and AMD' {
        # SIZE-LISTING-D-1 covers the D family too (SizeListingD.Tests.ps1).
        $e = @($script:ms.covers | Where-Object { $_.family -ceq 'E' })
        $e.Count | Should -Be 1
        @($e[0].generations) | Should -Be @('v5', 'v6', 'v7')
        @($e[0].processors) | Should -Be @('Intel', 'AMD')
    }

    It 'holds every E size page of v5 that the drift check pins, the Eb v5 page too' {
        $onDisk = @(Get-ChildItem $script:memRoot -File | ForEach-Object { $_.BaseName } |
            Where-Object { $_ -match '^e[a-z]*v5-series$' -or $_ -match '^e[a-z]*v5-e[a-z]*v5-series$' } | Sort-Object)
        $onDisk | Should -Be @($script:v5Pages | Sort-Object)
        foreach ($n in $script:v5Pages) {
            $script:pinned | Should -Contain $n -Because "the drift check must watch '$n'"
            @($script:ms.pages | Where-Object { $_.page -eq $n }).Count | Should -Be 1 -Because "the data must hold '$n'"
        }
    }

    It 'each v5 size page list is the size table of its pinned page: <Page>' -ForEach @(
        @{ Page = 'esv5-series'; First = 'E2s_v5'; Last = 'E104is_v5' }
        @{ Page = 'edsv5-series'; First = 'E2ds_v5'; Last = 'E104ids_v5' }
        @{ Page = 'ev5-series'; First = 'E2_v5'; Last = 'E104i_v5' }
        @{ Page = 'edv5-series'; First = 'E2d_v5'; Last = 'E104id_v5' }
        @{ Page = 'easv5-series'; First = 'E2as_v5'; Last = 'E112ias_v5' }
        @{ Page = 'eadsv5-series'; First = 'E2ads_v5'; Last = 'E112iads_v5' }
    ) {
        $want = @(SL5PageSizes -Path (Join-Path $script:memRoot "$Page.md"))
        $want.Count | Should -Be 10
        $want[0] | Should -BeExactly $First
        $want[-1] | Should -BeExactly $Last
        $pg = @($script:ms.pages | Where-Object { $_.page -eq $Page })[0]
        @($pg.sizes) | Should -Be $want -Because "the data must be what $Page lists"
    }

    It 'the Eb v5 page list is the size table of its pinned page, Ebsv5 and Ebdsv5 with the isolated E112ib sizes' {
        $want = @(SL5PageSizes -Path (Join-Path $script:memRoot 'ebdsv5-ebsv5-series.md'))
        $want | Should -Contain 'E8bs_v5'
        $want | Should -Contain 'E96bds_v5'
        $want | Should -Contain 'E112ibs_v5'
        $want | Should -Contain 'E112ibds_v5'
        @($want | Where-Object { $_ -notmatch '^E\d+i?bd?s_v5$' }) | Should -BeNullOrEmpty
        $pg = @($script:ms.pages | Where-Object { $_.page -eq 'ebdsv5-ebsv5-series' })[0]
        @($pg.sizes) | Should -Be $want
    }

    It 'the Edv5 page writes its isolated size with a footnote mark, and Azure lists the size without it' {
        (Get-Content (Join-Path $script:memRoot 'edv5-series.md') -Raw) | Should -Match ([regex]::Escape('Standard\_E104id\_v52 |'))
        $script:sizes.name | Should -Contain 'Standard_E104id_v5'
        $script:sizes.name | Should -Not -Contain 'Standard_E104id_v52'
    }

    It 'the constrained list holds every constrained E size on v5, v6 and v7 that the constrained vCPU page lists' {
        $pg = @($script:ms.pages | Where-Object { $_.page -eq 'constrained-vcpu' })[0]
        $want = @(SL5PageSizes -Path (Join-Path $script:pagesRoot 'constrained-vcpu.md') -Pattern '^\| Standard\\_(E\d+-\d+[a-z]*)\\_(v[5-7])\d?\b')
        @($want | Where-Object { $_ -like '*_v5' }).Count | Should -Be 44
        $want.Count | Should -Be 96
        @($pg.sizes) | Should -Be $want
        foreach ($n in 'E8-4s_v5', 'E8-4ds_v5', 'E8-4as_v5', 'E8-4ads_v5') { @($pg.sizes) | Should -Contain $n }
    }

    It 'every E v5 size the real centralus catalog lists is one the data holds' {
        $known = @(foreach ($pg in @($script:ms.pages)) { foreach ($s in @($pg.sizes)) { "Standard_$s" } })
        $inRegion = @($script:sizes.name | Where-Object { $_ -match '^Standard_E\d+(-\d+)?[a-z]*_v5$' })
        $inRegion.Count | Should -BeGreaterThan 70
        foreach ($n in $inRegion) { $known | Should -Contain $n -Because "$n is in the catalog, so Microsoft lists it" }
    }

    It 'every page is a source of the data file, read on the date the listing gives' {
        foreach ($pg in @($script:ms.pages)) {
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape([string]$pg.page))$" })
            $src.Count | Should -Be 1 -Because "'$($pg.page)' must be one of the data file's sources"
            # A source with other facts of its own date (ev5, edv5) says the
            # date of its listing sentence in the text.
            if ($src[0].readUtc -ne $script:ms.readUtc) {
                $src[0].says | Should -Match "SIZE-LISTING-(V5|D)-1, read $($script:ms.readUtc)" -Because "the refusal says the pages were read on $($script:ms.readUtc)"
            }
        }
        foreach ($n in $script:v5Pages) {
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape($n))$" })
            $src[0].says | Should -Match 'SIZE-LISTING-V5-1'
        }
    }

    It 'the drift check watches the Eb v5 page, and a combined page name of v5, v6 or v7' {
        $include = [string](@($script:watch.folders | Where-Object { $_.path -eq 'azure/virtual-machines/sizes/memory-optimized' })[0].include)
        foreach ($n in 'ebdsv5-ebsv5-series', 'ebdsv6-ebsv6-series', 'ebdsv7-ebsv7-series', 'esv5-series', 'eadsv5-series') {
            $n | Should -Match $include -Because "a page named $n must be watched"
        }
        foreach ($n in 'ecsv5-ecdsv5-series', 'epsv5-epdsv5-series') {
            $n | Should -Not -Match $include -Because "$n is a confidential or Arm64 page, outside the scope of this tool"
        }
    }
}

Describe 'SIZE-LISTING-V5-1: the size listing on v5' {

    It '<Size> - Microsoft lists it: <Listed>' -ForEach @(
        @{ Size = 'Standard_E8s_v5'; Listed = $true; Page = 'esv5-series' }
        @{ Size = 'Standard_E8_v5'; Listed = $true; Page = 'ev5-series' }
        @{ Size = 'Standard_E104id_v5'; Listed = $true; Page = 'edv5-series' }
        @{ Size = 'Standard_E112ias_v5'; Listed = $true; Page = 'easv5-series' }
        @{ Size = 'Standard_E8bs_v5'; Listed = $true; Page = 'ebdsv5-ebsv5-series' }
        @{ Size = 'Standard_E112ibds_v5'; Listed = $true; Page = 'ebdsv5-ebsv5-series' }
        @{ Size = 'Standard_E8-4s_v5'; Listed = $true; Page = 'constrained-vcpu' }
        @{ Size = 'Standard_E8-4as_v5'; Listed = $true; Page = 'constrained-vcpu' }
        @{ Size = 'Standard_E80is_v5'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E80ids_v5'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E8a_v5'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E64i_v5'; Listed = $false; Page = $null }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; l = $Listed; pg = $Page } {
            $r = Get-VmfMicrosoftSizeListing -SizeName $s
            $r.Listed | Should -Be $l
            $r.Page | Should -Be $pg
            $r.ReadUtc | Should -Be (Get-VmfTargetFamilyData).microsoftSizes.readUtc
        }
    }

    It 'the isolated E sizes Microsoft lists on v5, for each processor' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfMicrosoftIsolatedSizes -Family 'E' -TargetGeneration 'v5' -Processor 'Intel') |
                Should -Be @('Standard_E104i_v5', 'Standard_E104id_v5', 'Standard_E104ids_v5', 'Standard_E104is_v5', 'Standard_E112ibds_v5', 'Standard_E112ibs_v5')
            @(Get-VmfMicrosoftIsolatedSizes -Family 'E' -TargetGeneration 'v5' -Processor 'AMD') |
                Should -Be @('Standard_E112iads_v5', 'Standard_E112ias_v5')
            @(Get-VmfMicrosoftIsolatedSizes -Family 'E' -TargetGeneration 'v6' -Processor 'AMD') | Should -BeNullOrEmpty
        }
    }
}

Describe 'SIZE-LISTING-V5-1: the isolated E v4 sizes on v5, against the sizes Azure offers' {

    BeforeAll { $script:cat = SL5Catalog }

    It '<Source> on v5 is told Microsoft lists no such size, which isolated Intel sizes it lists, and that a person decides' -ForEach @(
        @{ Source = 'Standard_E80is_v4'; Tried = 'Standard_E80is_v5' }
        @{ Source = 'Standard_E80ids_v4'; Tried = 'Standard_E80ids_v5' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; t = $Tried } {
            $read = (Get-VmfTargetFamilyData).microsoftSizes.readUtc
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            $r.NotListed | Should -BeTrue
            $r.Reason | Should -Match "no v5 size for this machine is one Microsoft lists: its size pages \(read $read\) have no $([regex]::Escape($t))\."
            $r.Reason | Should -Match 'This is not a shortage in this region\.'
            $r.Reason | Should -Not -Match 'no candidate available in region'
            $r.Reason | Should -Match "$([regex]::Escape($s)) is an isolated size\."
            $r.Reason | Should -Match ([regex]::Escape("Microsoft's isolated Intel E sizes on v5 are Standard_E104i_v5, Standard_E104id_v5, Standard_E104ids_v5, Standard_E104is_v5, Standard_E112ibds_v5 and Standard_E112ibs_v5."))
            $r.Reason | Should -Not -Match 'E112ia' -Because 'a machine keeps its processor maker'
            $r.Reason | Should -Match 'A person decides the size of an isolated machine: the product does not choose one\.'
        }
    }

    It 'with no catalog, E80is_v4 is not planned on v5, and an E v4 size whose v5 size Microsoft lists still is' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E80is_v4' -TargetGeneration 'v5'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            (Get-VmfTargetSize -SourceSize 'Standard_E8s_v4' -TargetGeneration 'v5').Target | Should -Be 'Standard_E8s_v5'
            (Get-VmfTargetSize -SourceSize 'Standard_E8-4ds_v4' -TargetGeneration 'v5').Target | Should -Be 'Standard_E8-4ds_v5'
        }
    }

    It 'of every E v4 size in the real catalog, on v5 only E80is_v4 and E80ids_v4 get no target, and neither is told the region fact' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $refused = @{}
            foreach ($src in @($c.Keys | Where-Object { $_ -match '^Standard_E.*_v4$' } | Sort-Object)) {
                $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration 'v5'
                if (-not $r.Target) { $refused[$src] = [string]$r.Code }
            }
            @($refused.Keys | Sort-Object) | Should -Be @('Standard_E80ids_v4', 'Standard_E80is_v4')
            foreach ($k in $refused.Keys) { $refused[$k] | Should -Be 'not-approved' }
        }
    }

    It 'an E v5 size the region lists is planned, whatever the pages say' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $c['Standard_E80is_v5'] = [pscustomobject]@{ Name = 'Standard_E80is_v5'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $c['Standard_E80is_v4'].Capabilities }
            $r = Get-VmfTargetSize -SourceSize 'Standard_E80is_v4' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Target | Should -Be 'Standard_E80is_v5'
        }
    }

    It 'an AMD E v4 machine whose v5 size Microsoft lists, in a region that does not, is told the region fact and the page' {
        # The fixture is Intel only, so the region has no AMD size.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $read = (Get-VmfTargetFamilyData).microsoftSizes.readUtc
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8as_v4' -CatalogBySize $c -TargetGeneration 'v5'
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'tried: Standard_E8ads_v5, Standard_E8as_v5\)'
            $r.Reason | Should -Match "Microsoft lists Standard_E8ads_v5 \(the eadsv5-series page, read $read\) and Standard_E8as_v5 \(the easv5-series page, read $read\), and this region does not list them"
        }
    }
}
