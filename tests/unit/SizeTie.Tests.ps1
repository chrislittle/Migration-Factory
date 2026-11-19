#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SIZE-TIE-1: the planner's size picks are the same on every run.
#
# Found while copying the planner's rules into a separate tool: a machine on
# Standard_E8-4ds_v5 with 30 data disks was told "use Standard_E16ds_v6
# instead", then Standard_E16-4ds_v6, then Standard_E16-8ds_v6, on three runs
# with the same size catalog. The suggestion walked the catalog's keys and kept
# the FIRST of the sizes with the fewest vCPUs read from the name - and all
# three read as 16. The catalog is a [hashtable], and .NET gives every process
# its own string hash seed, so its key order changes from one run to the next.
#
# The tie-break approved on 2026-10-09: a size with all its cores
# before a constrained-core one (a constrained-core size has fewer active vCPUs
# than its name says, so it is never the default suggestion), then the name in
# ORDINAL order, never culture order. Ordinal compares characters, not numbers:
# E32-16ds_v6 comes before E32-8ds_v6.
#
# Three ways to change a catalog's order, because one alone proves too little:
#   - insertion order, shuffled with fixed seeds and reversed. A hashtable
#     places a key by its hash, so this moves only keys whose buckets collide;
#   - a hashtable with a seeded key comparer, which changes every key's hash,
#     the way a new process does;
#   - real separate processes, which is the defect as it was met.
#
# The catalog is tests/fixtures/intel-v4-catalog-centralus.json (Azure's own
# figures, centralus, read 2026-10-04) for the suggestions, and
# old-size-catalog-centralus.json for the choices by shape.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    if (-not ('VmfTest.SeededNameComparer' -as [type])) {
        Add-Type -TypeDefinition @'
namespace VmfTest {
    // Equal as a PowerShell hashtable is equal (case does not matter), with a
    // hash that changes with the seed - so each seed gives another key order.
    public sealed class SeededNameComparer : System.Collections.IEqualityComparer {
        private readonly int seed;
        public SeededNameComparer(int seed) { this.seed = seed; }
        public new bool Equals(object x, object y) {
            return System.StringComparer.OrdinalIgnoreCase.Equals(x, y);
        }
        public int GetHashCode(object obj) {
            string s = (obj == null ? "" : obj.ToString()).ToUpperInvariant();
            unchecked {
                int h = seed * 486187739;
                foreach (char ch in s) { h = (h ^ ch) * 16777619; }
                return h;
            }
        }
    }
}
'@
    }

    function Global:StLoad([string]$FixtureName) {
        $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $FixtureName) -Raw | ConvertFrom-Json
        @(foreach ($s in @($fixture.sizes)) {
                $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
                [pscustomobject]@{ Name = [string]$s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
            })
    }
    $script:intel = StLoad 'intel-v4-catalog-centralus.json'
    $script:old = StLoad 'old-size-catalog-centralus.json'

    # Every order the tests use, as catalogs: the fixture's own order, its
    # reverse, twelve fixed shuffles, and twelve seeded comparers.
    function Global:StCatalogs([object[]]$Skus, [string[]]$Without = @()) {
        $use = @($Skus | Where-Object { $Without -notcontains $_.Name })
        $orders = [System.Collections.Generic.List[object]]::new()
        $orders.Add($use)
        $reversed = [object[]]$use.Clone(); [array]::Reverse($reversed); $orders.Add($reversed)
        foreach ($seed in 1..12) { $orders.Add(@($use | Get-Random -Count $use.Count -SetSeed $seed)) }
        foreach ($order in $orders) {
            $c = @{}
            foreach ($s in $order) { $c[$s.Name] = $s }
            , $c
        }
        foreach ($seed in 1..12) {
            $c = [hashtable]::new([System.Collections.IEqualityComparer][VmfTest.SeededNameComparer]::new($seed))
            foreach ($s in $use) { $c[$s.Name] = $s }
            , $c
        }
    }
}
AfterAll { Remove-Item function:StLoad, function:StCatalogs -ErrorAction SilentlyContinue }

Describe 'SIZE-TIE-1: the test catalogs really are in different orders' {
    It 'gives the three 16-vCPU E v6 sizes in more than one order' {
        # A test that never changed the order would pass before the fix too.
        $seen = @(foreach ($c in (StCatalogs $script:intel)) {
                @($c.Keys | Where-Object { $_ -in @('Standard_E16ds_v6', 'Standard_E16-4ds_v6', 'Standard_E16-8ds_v6') }) -join ','
            }) | Sort-Object -Unique
        @($seen).Count | Should -BeGreaterThan 2
    }
}

Describe 'SIZE-TIE-1: a suggestion is the same in every catalog order' {
    It 'tells a 30 data disk machine on E8-4ds_v5 to use Standard_E16ds_v6, every time' {
        $answers = foreach ($c in (StCatalogs $script:intel)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4ds_v5' -CatalogBySize $c -RequiredDataDisks 30
                "$($r.Code)|$($r.Reason)"
            }
        }
        @($answers | Sort-Object -Unique).Count | Should -Be 1
        $answers[0] | Should -BeLike 'too-few-data-disks|*use Standard_E16ds_v6 instead (it holds 48)'
    }

    It 'tells a machine with 3 network interfaces on E2ds_v5 to use Standard_E8ds_v6, every time' {
        # E8ds_v6, E8-4ds_v6 and E8-2ds_v6 all hold 4 and all read as 8 vCPUs.
        $answers = foreach ($c in (StCatalogs $script:intel)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                (Get-VmfTargetSize -SourceSize 'Standard_E2ds_v5' -CatalogBySize $c -RequiredNics 3).Reason
            }
        }
        @($answers | Sort-Object -Unique).Count | Should -Be 1
        $answers[0] | Should -BeLike '*use Standard_E8ds_v6 instead (it holds 4)'
    }

    It 'gives the same smallest size for disks and for interfaces, with the size that has all its cores' {
        foreach ($c in (StCatalogs $script:intel)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                (Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E8-4ds_v5' -RequiredDataDisks 30 -CatalogBySize $c).Name | Should -Be 'Standard_E16ds_v6'
                (Get-VmfSmallestSizeForNics -SourceSize 'Standard_E4ds_v5' -RequiredNics 5 -CatalogBySize $c).Name | Should -Be 'Standard_E16ds_v6'
                (Get-VmfSmallestSizeForNics -SourceSize 'Standard_E4-2ds_v5' -RequiredNics 3 -CatalogBySize $c).Name | Should -Be 'Standard_E8ds_v6'
            }
        }
    }

    It 'takes the constrained-core sizes in ordinal order when no size has all its cores' {
        # Without E16ds_v6, the two left are E16-4ds_v6 and E16-8ds_v6. Ordinal
        # order compares the characters of the name, and "4" is before "8".
        foreach ($c in (StCatalogs $script:intel -Without @('Standard_E16ds_v6'))) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                (Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E8-4ds_v5' -RequiredDataDisks 30 -CatalogBySize $c).Name | Should -Be 'Standard_E16-4ds_v6'
            }
        }
    }

    It 'orders constrained-core sizes by the characters of the name, not by the number: E32-16 before E32-8' {
        # Ordinal, as approved - NOT numeric: "1" is before "8", so E32-16ds_v6
        # comes before E32-8ds_v6. It matters only when E32ds_v6 is missing.
        # Whether this should prefer more or fewer active cores is an open
        # question (OWNER-QUESTIONS-1); this pins today's answer.
        # DISKS-32-1: this asked for 50 data disks, to pass the E16 and E20
        # sizes (48). More than 32 is now outside the scope of this tool and
        # gets no suggestion, so the E16, E20 and E32 sizes with all their
        # cores are left out of the catalog instead, with 30 data disks.
        foreach ($c in (StCatalogs $script:intel -Without @('Standard_E32ds_v6', 'Standard_E16ds_v6', 'Standard_E16-4ds_v6', 'Standard_E16-8ds_v6', 'Standard_E20ds_v6'))) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                (Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E8-4ds_v5' -RequiredDataDisks 30 -CatalogBySize $c).Name | Should -Be 'Standard_E32-16ds_v6'
            }
        }
    }

    It 'keeps the smallest size first: a tie-break never wins over fewer vCPUs' {
        # E20ds_v6 holds 48 too, and is larger. The tie-break chooses only
        # between equals.
        foreach ($c in (StCatalogs $script:intel)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                $s = Get-VmfSmallestSizeForDisks -SourceSize 'Standard_E8-4ds_v5' -RequiredDataDisks 30 -CatalogBySize $c
                $s.Vcpus | Should -Be 16
            }
        }
    }
}

Describe 'SIZE-TIE-1: the fixed order of a catalog' {
    It 'puts every size with all its cores first, then the constrained-core sizes, each in ordinal order' {
        InModuleScope VmMigrationFactory {
            # Culture order puts E2as before E2Bs (a before B); ordinal order
            # puts B (0x42) before a (0x61). The hyphen (0x2D) is before every
            # letter and digit, so E16-4ds would come first if constrained
            # sizes were not put last.
            $c = @{ 'Standard_E2as_v6' = 1; 'Standard_E2Bs_v6' = 1; 'Standard_E16-8ds_v6' = 1; 'Standard_E16ds_v6' = 1; 'Standard_E16-4ds_v6' = 1 }
            @(Get-VmfCatalogSizeNames -CatalogBySize $c) | Should -Be @(
                'Standard_E16ds_v6', 'Standard_E2Bs_v6', 'Standard_E2as_v6', 'Standard_E16-4ds_v6', 'Standard_E16-8ds_v6')
        }
    }

    It 'gives nothing for an empty or absent catalog' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfCatalogSizeNames -CatalogBySize @{}).Count | Should -Be 0
            @(Get-VmfCatalogSizeNames -CatalogBySize $null).Count | Should -Be 0
        }
    }

    It 'gives the same order for every catalog order' {
        $orders = foreach ($c in (StCatalogs $script:intel)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } { param($c) @(Get-VmfCatalogSizeNames -CatalogBySize $c) -join ',' }
        }
        @($orders | Sort-Object -Unique).Count | Should -Be 1
    }
}

Describe 'SIZE-TIE-1: what is planned is the same in every catalog order' {
    It 'gives the same choices by shape, in the same order, with the same best' {
        # D13_v2 (8 vCPUs, 56 GiB, Generation 1): D, Dl and E v5 choices, and
        # E8ds_v5's constrained sizes. Order-free already (each size number has
        # one name, and the constrained sizes sort by their active vCPUs) - held
        # here so a later change cannot make it depend on the catalog.
        $lists = foreach ($c in (StCatalogs $script:old)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c } {
                param($c)
                $v5 = @(Get-VmfShapeSizeChoices -SourceSize 'Standard_D13_v2' -CatalogBySize $c -HyperVGeneration 'V1') |
                    ForEach-Object { "$($_.size)$(if ($_.best) { '*' })" }
                $v6 = @(Get-VmfShapeSizeChoices -SourceSize 'Standard_D13_v2' -CatalogBySize $c -HyperVGeneration 'V2' -TargetGeneration 'v6') |
                    ForEach-Object { "$($_.size)$(if ($_.best) { '*' })" }
                ($v5 -join ',') + ' / ' + ($v6 -join ',')
            }
        }
        @($lists | Sort-Object -Unique).Count | Should -Be 1
        # The asterisk marks the best choice.
        $lists[0] | Should -Match 'Standard_E8ds_v5\*,Standard_E8-2ds_v5,Standard_E8-4ds_v5 / '
    }

    It 'plans the same target, path and reason for a machine in every catalog order' {
        $vms = @(
            [pscustomobject]@{ vmId = 'vm-1'; sourceSize = 'Standard_D13_v2'; gen = 'V1'; os = 'Windows'; classification = 'Ready'; blockers = @(); nicCount = 1; dataDiskCount = 0; diskArch = 'scsi-temp'; sourceTempDisks = 1 }
            [pscustomobject]@{ vmId = 'vm-2'; sourceSize = 'Standard_E8-4ds_v5'; gen = 'V2'; os = 'Linux'; classification = 'Ready'; blockers = @(); nicCount = 1; dataDiskCount = 30; diskArch = 'scsi-temp'; sourceTempDisks = 1 }
        )
        $results = foreach ($c in (StCatalogs $script:old)) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $c; vms = $vms } {
                param($c, $vms)
                @(foreach ($vm in $vms) {
                        $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v6'
                        $t5 = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $c -TargetGeneration 'v5'
                        "$($t.Mapping.Target)|$($t.Path)|$($t.Mapping.Reason)|$($t5.Mapping.Target)|$($t5.Path)|$(@($t5.SizeChoices | ForEach-Object { $_.size }) -join ',')"
                    }) -join ' // '
            }
        }
        @($results | Sort-Object -Unique).Count | Should -Be 1
        $results[0] | Should -Match 'use Standard_E16ds_v6 instead'
    }
}

Describe 'SIZE-TIE-1: the same answer in separate processes' {
    It 'gives the same suggestions in two separate PowerShell processes' {
        # In-process orders cannot prove the per-process hash seed is handled:
        # this is the defect as it was met. Each process builds the catalog in
        # the SAME insertion order, so only the process's own seed differs.
        # The child calls pure planner functions only, so it cannot reach Azure.
        $child = Join-Path $TestDrive 'size-tie-child.ps1'
        Set-Content -LiteralPath $child -Encoding utf8 -Value @'
param([string]$RepoRoot)
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $RepoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
$fixture = Get-Content (Join-Path $RepoRoot 'tests' 'fixtures' 'intel-v4-catalog-centralus.json') -Raw | ConvertFrom-Json
$catalog = @{}
foreach ($s in @($fixture.sizes)) {
    $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
    $catalog[[string]$s.name] = [pscustomobject]@{ Name = [string]$s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
}
& (Get-Module VmMigrationFactory) {
    param($catalog)
    [ordered]@{
        disks =(Get-VmfTargetSize -SourceSize 'Standard_E8-4ds_v5' -CatalogBySize $catalog -RequiredDataDisks 30).Reason
        nics  = (Get-VmfTargetSize -SourceSize 'Standard_E2ds_v5' -CatalogBySize $catalog -RequiredNics 3).Reason
    } | ConvertTo-Json -Compress
} $catalog
'@
        # The PowerShell running this test, not whichever pwsh is first on PATH.
        $shell = [Environment]::ProcessPath
        $runs = foreach ($i in 1..2) {
            $out = & $shell -NoProfile -NonInteractive -File $child -RepoRoot $script:repoRoot 2>&1
            $LASTEXITCODE | Should -Be 0 -Because ($out -join ' ')
            ($out | Select-Object -Last 1) | ConvertFrom-Json
        }
        foreach ($r in $runs) {
            $r.disks | Should -BeLike '*use Standard_E16ds_v6 instead (it holds 48)'
            $r.nics | Should -BeLike '*use Standard_E8ds_v6 instead (it holds 4)'
        }
    }
}
