#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V5-SUCCESSOR-1: a machine with no v6 or v7 size of its own name is told
# WHICH fact stops it - Microsoft has no size of that name, or this region does
# not list one - and never that its region has no size when Microsoft has none.
#
# The default transform keeps the letters of a size name and changes the
# version. After V5-NAMES-1 every Intel v5 size refused on v6 or v7 in the real
# centralus catalog (66 refusals) was told "no candidate available in region"
# (not-in-region). For most of them Microsoft has no size of that name at all:
#   - Ebsv5 and Ebdsv5 on v7: Microsoft has no Ebsv7 or Ebdsv7 series;
#   - E112ibs_v5 and E112ibds_v5: the Ebsv6 and Ebdsv6 pages have no 112-vCPU
#     size, and there is no Eb series on v7;
#   - E104i_v5, E104id_v5, E104is_v5, E104ids_v5: no E104i size on v6 or v7;
#   - the constrained Esv5 and Edsv5 sizes on v7: Microsoft's constrained vCPU
#     page lists constrained E v7 sizes for AMD only (E8-4as_v7, E8-4ads_v7).
# Only the Ebsv5 and Ebdsv5 sizes on v6 are a region fact: Microsoft lists
# E8bs_v6 and E8bds_v6, and centralus does not.
#
# The facts are data: data/target-families.json microsoftSizes, the size names
# Microsoft's pinned pages list for the E family on v6 and v7, Intel and AMD,
# read 2026-10-23. A test below holds each list equal to its pinned page, so a
# page that changes (the drift check) fails here until the data is read again.
# A size the region's catalog lists is always planned: Azure is the authority
# on what exists, and the data only answers for a size the catalog does not
# hold. Nothing is inferred from a missing catalog entry alone.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'intel-v4-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:sizes = @($fixture.sizes)
    function Global:S5Catalog {
        $c = @{}
        foreach ($s in $script:sizes) {
            $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
            $c[$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
        }
        $c
    }
    function Global:S5Vm {
        param([string]$Size = 'Standard_E8bs_v5', [string]$Gen = 'V2', [string]$Name = 'app-07')
        [pscustomobject]@{
            vmId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; location = 'centralus'; classification = 'ReadyAfterPrep'; gen = $Gen; hyperVGeneration = $Gen
            os = 'Linux'; osVersion = '22_04-lts-gen2'
            sourceSize = $Size; sourceDiskArch = 'diskless'; sourceTempDisks = 0
            diskController = 'SCSI'; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1; primaryNicAccelerated = $true
            platformManaged = $false; blockers = @(); prepNeeded = @()
        }
    }
    # The size names a pinned page's tables list, as Standard_* names. A table
    # row starts with the size name; Microsoft wrote one row as
    # "Standard\_E4-2ds\_v6 4", so only the name part is taken.
    function Global:S5PageSizes {
        param([string]$Path, [string]$Pattern = '^\| (Standard\\_E\d+(?:-\d+)?[a-z]*\\_v[67])\b')
        $names = foreach ($line in Get-Content $Path) {
            if ($line -match $Pattern) { $Matches[1].Replace('\_', '_') }
        }
        @($names | Select-Object -Unique)
    }
    $script:pagesRoot = Join-Path $script:repoRoot 'docs' 'upstream-docs' 'azure' 'virtual-machines'
}
AfterAll { Remove-Item 'function:\S5Catalog', 'function:\S5Vm', 'function:\S5PageSizes' -ErrorAction SilentlyContinue }

Describe 'V5-SUCCESSOR-1: the data' {

    BeforeAll {
        $script:doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'target-families.json') -Raw | ConvertFrom-Json
        $script:ms = $script:doc.microsoftSizes
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $script:pinned = @(foreach ($f in $watch.folders) { foreach ($pg in @($f.pages)) { [string]$pg.name } })
    }

    It 'covers the E family on v6 and v7 (and v5 since SIZE-LISTING-V5-1), Intel and AMD, read on 2026-11-03 (SIZE-LISTING-D-1 read every page again)' {
        $script:ms | Should -Not -BeNullOrEmpty
        $script:ms.readUtc | Should -Be '2026-11-03'
        # SIZE-LISTING-D-1 covers the D family too (SizeListingD.Tests.ps1).
        $e = @($script:ms.covers | Where-Object { $_.family -ceq 'E' })
        $e.Count | Should -Be 1
        @($e[0].generations) | Should -Be @('v5', 'v6', 'v7')
        @($e[0].processors) | Should -Be @('Intel', 'AMD')
    }

    It 'every page is pinned, is one of the data sources read on the date the listing gives, and says what it is used for' {
        foreach ($pg in @($script:ms.pages)) {
            $script:pinned | Should -Contain ([string]$pg.page) -Because "the drift check must watch '$($pg.page)'"
            $src = @($script:doc.sources | Where-Object { $_.url -match "/$([regex]::Escape([string]$pg.page))$" })
            $src.Count | Should -Be 1 -Because "'$($pg.page)' must be one of the data file's sources"
            # SIZE-LISTING-V5-1: a source with other facts of its own date
            # (ev5, edv5) says the date of its listing sentence in the text.
            if ($src[0].readUtc -ne $script:ms.readUtc) { $src[0].says | Should -Match "SIZE-LISTING-(V5|D)-1, read $($script:ms.readUtc)" }
            $src[0].says | Should -Match 'V5-SUCCESSOR-1|SIZE-LISTING-V5-1|SIZE-LISTING-D-1'
        }
    }

    It 'holds every E size page of v6 and v7 that the drift check pins, on Intel and AMD - so a size not in the data is one Microsoft does not list' {
        $folder = Join-Path $script:pagesRoot 'sizes' 'memory-optimized'
        # Every pinned E page of v6 or v7 but the Arm64 ones (ep); the
        # confidential ones (ec) are the EC family and are not pinned.
        $onDisk = @(Get-ChildItem $folder -File | ForEach-Object { $_.BaseName } | Where-Object { $_ -match '^e[a-z]*v[67]-series$' -and $_ -notmatch '^e[a-z]*p[a-z]*v' } | Sort-Object)
        $onDisk.Count | Should -Be 12
        $inData = @($script:ms.pages | Where-Object { $_.page -ne 'constrained-vcpu' -and $_.page -match '^e[a-z-]*v[67]-series$' } | ForEach-Object { [string]$_.page } | Sort-Object)
        $inData | Should -Be $onDisk
        @($script:ms.pages | Where-Object { $_.page -eq 'constrained-vcpu' }).Count | Should -Be 1
    }

    It 'each size page list is the size table of its pinned page' {
        foreach ($pg in @($script:ms.pages | Where-Object { $_.page -ne 'constrained-vcpu' -and $_.page -match '^e[a-z-]*v[67]-series$' })) {
            $file = Join-Path $script:pagesRoot 'sizes' 'memory-optimized' "$($pg.page).md"
            $want = @(S5PageSizes -Path $file | ForEach-Object { $_ -replace '^Standard_', '' })
            $want.Count | Should -BeGreaterThan 8
            @($pg.sizes) | Should -Be $want -Because "the data must be what $($pg.page) lists"
        }
    }

    It 'the constrained list is every constrained E size on v6 and v7 the constrained vCPU page lists, and it has no Intel v7 size' {
        $pg = @($script:ms.pages | Where-Object { $_.page -eq 'constrained-vcpu' })[0]
        $want = @(S5PageSizes -Path (Join-Path $script:pagesRoot 'constrained-vcpu.md') -Pattern '^\| (Standard\\_E\d+-\d+[a-z]*\\_v[67])\b' | ForEach-Object { $_ -replace '^Standard_', '' })
        $want.Count | Should -Be 52
        @($pg.sizes | Where-Object { $_ -match '_v[67]$' }) | Should -Be $want
        @($pg.sizes | Where-Object { $_ -match '^E\d+-\d+d?s_v7$' }) | Should -BeNullOrEmpty -Because 'the page lists constrained E v7 sizes for AMD only'
        @($pg.sizes) | Should -Contain 'E8-4s_v6'
        @($pg.sizes) | Should -Contain 'E8-4ads_v7'
    }

    It 'every E v6 and v7 size the real centralus catalog lists is one the data holds' {
        $known = @(foreach ($pg in @($script:ms.pages)) { foreach ($s in @($pg.sizes)) { "Standard_$s" } })
        $inRegion = @($script:sizes.name | Where-Object { $_ -match '^Standard_E\d+(-\d+)?[a-z]*_v[67]$' })
        $inRegion.Count | Should -BeGreaterThan 40
        foreach ($n in $inRegion) { $known | Should -Contain $n -Because "$n is in the catalog, so Microsoft lists it" }
    }

    It 'the letter for an isolated size is read from the naming conventions page' {
        $script:ms.isolatedLetter | Should -BeExactly 'i'
        (Get-Content (Join-Path $script:pagesRoot 'vm-naming-conventions.md') -Raw) | Should -Match 'i = isolated size'
        $src = @($script:doc.sources | Where-Object { $_.url -match '/vm-naming-conventions$' })
        $src[0].says | Should -Match 'i is an isolated size'
    }

    It 'the drift check watches every E page of v6 and v7 and the Eb family page, and a combined page name too' {
        $watch = Get-Content (Join-Path $script:repoRoot 'docs' 'upstream-docs.json') -Raw | ConvertFrom-Json
        $include = [string](@($watch.folders | Where-Object { $_.path -eq 'azure/virtual-machines/sizes/memory-optimized' })[0].include)
        foreach ($n in 'esv6-series', 'ensv6-series', 'endsv6-series', 'ebdsv6-series', 'eadsv7-series', 'eb-family', 'ebdsv7-ebsv7-series') {
            $n | Should -Match $include -Because "a page named $n must be watched"
        }
        $script:pinned | Should -Contain 'eb-family'
        $script:pinned | Should -Contain 'constrained-vcpu'
    }

    It 'the Eb family page names no Eb series on v7' {
        $text = Get-Content (Join-Path $script:pagesRoot 'sizes' 'memory-optimized' 'eb-family.md') -Raw
        $text | Should -Match '### Ebsv6 and Ebdsv6-series'
        $text | Should -Not -Match 'Eb[a-z]*v7'
        $src = @($script:doc.sources | Where-Object { $_.url -match '/memory-optimized/eb-family$' })
        $src.Count | Should -Be 1
        $src[0].readUtc | Should -Be '2026-11-03'
        $src[0].says | Should -Match 'No Eb series on v7'
    }

    It 'the pinned pages say what the item says: Eb only on v6, and no 112-vCPU or 104-vCPU size on v6 or v7' {
        $all = @(foreach ($pg in @($script:ms.pages)) { @($pg.sizes | Where-Object { $_ -match '_v[67]$' }) })
        @($all | Where-Object { $_ -match '^E\d+b' -and $_ -like '*_v7' }) | Should -BeNullOrEmpty
        @($all | Where-Object { $_ -match '^E(112|104)' }) | Should -BeNullOrEmpty
        $all | Should -Contain 'E96bds_v6'
        $all | Should -Contain 'E192ibs_v6'
    }
}

Describe 'V5-SUCCESSOR-1: the size listing' {

    It '<Size> - Microsoft lists it: <Listed>' -ForEach @(
        @{ Size = 'Standard_E8bs_v6'; Listed = $true; Page = 'ebsv6-series' }
        @{ Size = 'Standard_E96bds_v6'; Listed = $true; Page = 'ebdsv6-series' }
        @{ Size = 'Standard_E8-4s_v6'; Listed = $true; Page = 'constrained-vcpu' }
        @{ Size = 'Standard_E8-4ads_v7'; Listed = $true; Page = 'constrained-vcpu' }
        @{ Size = 'Standard_E372is_v7'; Listed = $true; Page = 'esv7-series' }
        @{ Size = 'Standard_E8bs_v7'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E112ibs_v6'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E104i_v7'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E8-4s_v7'; Listed = $false; Page = $null }
        @{ Size = 'Standard_E8-4as_v6'; Listed = $false; Page = $null }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; l = $Listed; pg = $Page } {
            $r = Get-VmfMicrosoftSizeListing -SizeName $s
            $r.Listed | Should -Be $l
            $r.Page | Should -Be $pg
            $r.ReadUtc | Should -Be '2026-11-03'
        }
    }

    It 'answers nothing for a size the data does not cover: <Size>' -ForEach @(
        @{ Size = 'Standard_D4ps_v6' }
        @{ Size = 'Standard_E8s_v4' }
        @{ Size = 'Standard_E80is_v4' }
        @{ Size = 'Standard_E2ps_v6' }
        @{ Size = 'Standard_F8s_v7' }
        @{ Size = 'not a size' }
        @{ Size = '' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size } {
            (Get-VmfMicrosoftSizeListing -SizeName $s).Listed | Should -BeNullOrEmpty
        }
    }

    It 'reads a size name the way Azure does, ignoring case' {
        InModuleScope VmMigrationFactory {
            (Get-VmfMicrosoftSizeListing -SizeName 'standard_e8BS_v6').Listed | Should -BeTrue
        }
    }

    It 'the isolated E sizes Microsoft lists on <Gen>' -ForEach @(
        @{ Gen = 'v6'; Want = @('Standard_E192ibds_v6', 'Standard_E192ibs_v6', 'Standard_E192ids_v6', 'Standard_E192is_v6') }
        @{ Gen = 'v7'; Want = @('Standard_E372ids_v7', 'Standard_E372is_v7') }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ g = $Gen; w = $Want } {
            @(Get-VmfMicrosoftIsolatedSizes -Family 'E' -TargetGeneration $g) | Should -Be $w
            @(Get-VmfMicrosoftIsolatedSizes -Family 'E' -TargetGeneration $g -Processor 'Intel') | Should -Be $w
        }
    }

    It 'knows an isolated size by its letter: <Size> <Isolated>' -ForEach @(
        @{ Size = 'Standard_E104i_v5'; Isolated = $true }
        @{ Size = 'Standard_E112ibds_v5'; Isolated = $true }
        @{ Size = 'Standard_E64is_v3'; Isolated = $true }
        @{ Size = 'Standard_E8bs_v5'; Isolated = $false }
        @{ Size = 'Standard_E8-4ds_v5'; Isolated = $false }
        @{ Size = 'Standard_D4ls_v5'; Isolated = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Size; i = $Isolated } {
            Test-VmfIsolatedSize -SizeName $s | Should -Be $i
        }
    }
}

Describe 'V5-SUCCESSOR-1: every refused Intel v5 size, against the sizes Azure offers' {

    BeforeAll { $script:cat = S5Catalog }

    It 'an Ebsv5 or Ebdsv5 machine on v7 is told Microsoft has no size of that name, not that its region has none: <Source>' -ForEach @(
        foreach ($n in 2, 4, 8, 16, 32, 48, 64, 96) { @{ Source = "Standard_E$($n)bs_v5"; Tried = "Standard_E$($n)bs_v7" }; @{ Source = "Standard_E$($n)bds_v5"; Tried = "Standard_E$($n)bds_v7" } }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; t = $Tried } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v7'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            $r.NotListed | Should -BeTrue
            $r.Reason | Should -Match "no v7 size for this machine is one Microsoft lists: its size pages \(read 2026-11-03\) have no $([regex]::Escape($t))\."
            $r.Reason | Should -Match 'This is not a shortage in this region\.'
            $r.Reason | Should -Not -Match 'no candidate available in region'
            $r.Reason | Should -Not -Match 'isolated'
        }
    }

    It 'an Ebsv5 or Ebdsv5 machine on v6 is told the region fact, and that Microsoft lists the size: <Source>' -ForEach @(
        foreach ($n in 2, 4, 8, 16, 32, 48, 64, 96) {
            @{ Source = "Standard_E$($n)bs_v5"; Tried = "Standard_E$($n)bs_v6"; Page = 'ebsv6-series' }
            @{ Source = "Standard_E$($n)bds_v5"; Tried = "Standard_E$($n)bds_v6"; Page = 'ebdsv6-series' }
        }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; t = $Tried; pg = $Page } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v6'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Match "tried: $([regex]::Escape($t))\)"
            $r.Reason | Should -Match "Microsoft lists $([regex]::Escape($t)) \(the $pg page, read 2026-11-03\), and this region does not list it\."
        }
    }

    It 'an isolated machine is told Microsoft has no size of that name, which isolated sizes it lists, and that a person decides: <Source> on <Gen>' -ForEach @(
        foreach ($g in 'v6', 'v7') {
            foreach ($s in 'Standard_E104i_v5', 'Standard_E104id_v5', 'Standard_E104is_v5', 'Standard_E104ids_v5', 'Standard_E112ibs_v5', 'Standard_E112ibds_v5') {
                @{ Source = $s; Gen = $g; Tried = ($s -replace '_v5$', "_$g") }
            }
        }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; g = $Gen; t = $Tried } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration $g
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            $r.NotListed | Should -BeTrue
            $r.Reason | Should -Match "have no $([regex]::Escape($t))\."
            $r.Reason | Should -Match "$([regex]::Escape($s)) is an isolated size\."
            $want = if ($g -eq 'v6') { 'Standard_E192ibds_v6, Standard_E192ibs_v6, Standard_E192ids_v6 and Standard_E192is_v6' } else { 'Standard_E372ids_v7 and Standard_E372is_v7' }
            $r.Reason | Should -Match "Microsoft's isolated Intel E sizes on $g are $([regex]::Escape($want))\."
            $r.Reason | Should -Match 'A person decides the size of an isolated machine: the product does not choose one\.'
        }
    }

    It 'a constrained Esv5 or Edsv5 machine on v7 is told Microsoft has no size of that name, and the v6 size that works: <Source>' -ForEach @(
        foreach ($p in '4-2', '8-2', '8-4', '16-4', '16-8', '32-8', '32-16', '64-16', '64-32', '96-24', '96-48') {
            foreach ($l in 's', 'ds') { @{ Source = "Standard_E$($p)$($l)_v5"; Tried = "Standard_E$($p)$($l)_v7"; V6 = "Standard_E$($p)$($l)_v6" } }
        }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat; s = $Source; t = $Tried; v6 = $V6 } {
            $r = Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration 'v7'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            $r.Reason | Should -Match "have no $([regex]::Escape($t))\."
            # V7-REFUSAL-WORDS-1: a wave has no series setting (WAVE-SERIES-GONE-1).
            $r.Reason | Should -Match "This region has $([regex]::Escape($v6))\. Choose v6 for this machine in the Choose each target step, then plan again\."
            $r.Reason | Should -Not -Match '(?i)the wave is set'
        }
    }

    It 'of the 66 refusals, only the 16 Eb sizes on v6 say not-in-region; the other 50 say Microsoft lists no such size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $codes = @{}
            foreach ($src in @($c.Keys | Where-Object { $_ -match '_v5$' } | Sort-Object)) {
                foreach ($g in 'v6', 'v7') {
                    $r = Get-VmfTargetSize -SourceSize $src -CatalogBySize $c -TargetGeneration $g
                    if ($r.Target) { continue }
                    $codes["$src $g"] = [string]$r.Code
                }
            }
            $codes.Count | Should -Be 66
            $region = @($codes.Keys | Where-Object { $codes[$_] -eq 'not-in-region' } | Sort-Object)
            $region.Count | Should -Be 16
            foreach ($k in $region) { $k | Should -Match '^Standard_E\d+bd?s_v5 v6$' }
            @($codes.Keys | Where-Object { $codes[$_] -eq 'not-approved' }).Count | Should -Be 50
        }
    }

    It 'a size the region lists is planned, whatever the pages say' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $c['Standard_E8-4s_v7'] = [pscustomobject]@{ Name = 'Standard_E8-4s_v7'; Capabilities = $c['Standard_E8-4s_v6'].Capabilities }
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4s_v5' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Target | Should -Be 'Standard_E8-4s_v7'
            $r.Code | Should -Be 'mapped'
        }
    }

    It 'with no catalog, a size Microsoft does not list is never planned, and one it lists still is' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8bs_v5' -TargetGeneration 'v7'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'not-approved'
            (Get-VmfTargetSize -SourceSize 'Standard_E8bs_v5' -TargetGeneration 'v6').Target | Should -Be 'Standard_E8bs_v6'
        }
    }

    It 'an AMD machine whose two v6 sizes Microsoft lists, in a region that lists neither, is told the region fact for both' {
        # The fixture is Intel only, so the region has no AMD size.
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8as_v4' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Code | Should -Be 'not-in-region'
            $r.Reason | Should -Match 'tried: Standard_E8ads_v6, Standard_E8as_v6\)'
            $r.Reason | Should -Match 'Microsoft lists Standard_E8ads_v6 \(the eadsv6-series page, read 2026-11-03\) and Standard_E8as_v6 \(the easv6-series page, read 2026-11-03\), and this region does not list them'
        }
    }

    It 'when Microsoft lists one of the sizes tried and not the other, the region fact is said, for the size it lists' {
        Mock Get-VmfMicrosoftSizeListing -ModuleName VmMigrationFactory -ParameterFilter { $SizeName -eq 'Standard_E8ads_v6' } -MockWith { @{ Listed = $false; Page = $null; ReadUtc = '2026-10-23' } }
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8as_v4' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Microsoft lists Standard_E8as_v6 \(the easv6-series page, read 2026-11-03\), and this region does not list it'
            $r.Reason | Should -Not -Match 'Microsoft lists Standard_E8ads_v6'
        }
    }

    It 'a source the data does not cover keeps the region fact, with no page named: an F size on v7 (SIZE-LISTING-D-1 covers D now)' {
        # The region lists an F v7 size, so the family is in the region, and
        # not the one this machine tries. The listing covers D and E only.
        $c = $script:cat.Clone()
        $c['Standard_F8as_v7'] = [pscustomobject]@{ Name = 'Standard_F8as_v7'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $c['Standard_D8s_v6'].Capabilities }
        InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_F8s_v2' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Not -Match 'Microsoft lists'
        }
    }

    It 'a D size Microsoft lists on v6, in a region that does not, keeps the region fact and names the page (SIZE-LISTING-D-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D8as_v4' -CatalogBySize $c -TargetGeneration 'v6'
            $r.Code | Should -Be 'not-in-region'
            $r.NotListed | Should -BeNullOrEmpty
            $r.Reason | Should -Match 'Microsoft lists Standard_D8ads_v6 \(the dadsv6-series page, read 2026-11-03\)'
        }
    }
}

Describe 'V5-SUCCESSOR-1: the plan and the target options' {

    BeforeAll { $script:cat = S5Catalog }

    It 'a Generation 1 Ebsv5 machine on v7 is told the Generation 1 reason first, as a Generation 1 Dv5 machine is' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $t = Resolve-VmfEntryTarget -Assessment (S5Vm -Size 'Standard_E8bs_v5' -Gen 'V1') -CatalogBySize $c -TargetGeneration 'v7'
            $t.Mapping.Target | Should -BeNullOrEmpty
            $t.Mapping.Code | Should -Be 'gen1-no-size'
        }
    }

    It 'a Generation 2 Ebsv5 machine on v7 is planned as MANUAL with the reason that Microsoft lists no such size' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:cat } {
            $t = Resolve-VmfEntryTarget -Assessment (S5Vm -Size 'Standard_E8bs_v5') -CatalogBySize $c -TargetGeneration 'v7'
            $t.Mapping.Code | Should -Be 'not-approved'
            $t.Path | Should -Be 'MANUAL'
        }
    }

    It 'the target options: an Ebsv5 machine is not supported on v7 because Microsoft lists no such size, and on v6 because the region does not list it' {
        $vms = @((S5Vm -Size 'Standard_E8bs_v5'), (S5Vm -Size 'Standard_E104is_v5' -Name 'app-08'))
        $doc = [pscustomobject]@{ schemaVersion = 17; runId = 'scan-1'; vms = $vms }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; c = @{ centralus = (S5Catalog) } } {
            Get-VmfTargetAdvice -Assessment $d -CatalogByLocation $c
        }
        $eb = @($advice.machines | Where-Object { $_.name -eq 'app-07' })[0]
        @((@($eb.options) | Where-Object { $_.option -eq 'v7' }).notSupported) | Should -Contain 'not-approved'
        @((@($eb.options) | Where-Object { $_.option -eq 'v7' }).notSupported) | Should -Not -Contain 'not-in-region'
        @((@($eb.options) | Where-Object { $_.option -eq 'v6' }).notSupported) | Should -Contain 'not-in-region'
        $iso = @($advice.machines | Where-Object { $_.name -eq 'app-08' })[0]
        foreach ($g in 'v6', 'v7') {
            @((@($iso.options) | Where-Object { $_.option -eq $g }).notSupported) | Should -Contain 'not-approved'
        }
        $advice.assessmentHash = '0' * 64
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw
        Test-Json -Json ($advice | ConvertTo-Json -Depth 20) -Schema $schema -ErrorAction SilentlyContinue | Should -BeTrue
    }
}
