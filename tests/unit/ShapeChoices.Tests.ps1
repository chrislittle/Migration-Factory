#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# OLD-SKU-1B: a Generation 1 machine, or one on an old size, chooses its v5
# FAMILY (D or E) and SIZE (default, or constrained cores).
#
# Decided 2026-09-29: a customer on Generation 1 of the old Dv2 sizes picks the
# family, and a constrained vCPU, customized or default size. Customized cores is OLD-SKU-1D.
#
# Why the engine has to choose by SHAPE here: an old size's number is not its
# vCPU count. D4_v2 has 8 vCPUs and D4_v5 has 4, so its name twin is refused
# as smaller (SIZE-FIT-1), and D v1 names (Standard_D3) carry no version at all
# - both machines got no target. The choice is made from the region's catalog:
# for each family, the smallest v5 size with at least the machine's vCPUs AND
# memory (D has 4 GiB per vCPU, E has 8), plus E's constrained sizes, which keep
# the size and turn cores off for software licensed by core. Every choice goes
# through every gate the planner already has, as a named size (-Size) to
# Get-VmfTargetSize: the region, Generation 1, network interfaces, data disks.

BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_MachineList.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    # vCPUs, vCPUsAvailable (constrained), MemoryGB, temp disk MB, generations,
    # NICs - Azure's own figures for these sizes (centralus, 2026-09-29).
    function Global:ScSku([string]$Name, [double]$Vcpus, [double]$MemoryGB, [string]$TempMb = '0', [string]$Gens = 'V1,V2', [string]$Nics = '4', [object]$Available = $null) {
        $caps = @(
            [pscustomobject]@{ Name = 'vCPUs'; Value = [string]$Vcpus }
            [pscustomobject]@{ Name = 'MemoryGB'; Value = [string]$MemoryGB }
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = $Nics }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }
            # OLD-SKU-1C: an s size takes Premium SSD; D4_v2 and D3 do not.
            [pscustomobject]@{ Name = 'PremiumIO'; Value = $(if ($Name -match 's[a-z]*_v\d+$|^Standard_DS') { 'True' } else { 'False' }) })
        if ($null -ne $Available) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = [string]$Available } }
        [pscustomobject]@{ Name = $Name; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    function Global:ScCatalog {
        $c = @{}
        foreach ($s in @(
                # sources
                (ScSku 'Standard_D2_v2' 2 7 '102400' 'V1'), (ScSku 'Standard_D4_v2' 8 28 '409600' 'V1'),
                (ScSku 'Standard_D13_v2' 8 56 '409600' 'V1'), (ScSku 'Standard_D3' 4 14 '204800' 'V1'),
                (ScSku 'Standard_A4m_v2' 4 32 '40960' 'V1'), (ScSku 'Standard_D2s_v4' 2 8 '0'),
                # D v5 with a temporary disk
                (ScSku 'Standard_D2ds_v5' 2 8 '76800' 'V1,V2' '2'), (ScSku 'Standard_D4ds_v5' 4 16 '153600'),
                (ScSku 'Standard_D8ds_v5' 8 32 '307200'), (ScSku 'Standard_D16ds_v5' 16 64 '614400'),
                # E v5 with a temporary disk, and its constrained sizes
                (ScSku 'Standard_E2ds_v5' 2 16 '76800'), (ScSku 'Standard_E4ds_v5' 4 32 '153600'),
                (ScSku 'Standard_E4-2ds_v5' 4 32 '153600' 'V1,V2' '4' 2),
                (ScSku 'Standard_E8ds_v5' 8 64 '307200'),
                (ScSku 'Standard_E8-4ds_v5' 8 64 '307200' 'V1,V2' '4' 4), (ScSku 'Standard_E8-2ds_v5' 8 64 '307200' 'V1,V2' '4' 2),
                (ScSku 'Standard_E16ds_v5' 16 128 '614400'),
                # no temporary disk
                (ScSku 'Standard_D2s_v5' 2 8 '0'), (ScSku 'Standard_E2s_v5' 2 16 '0'),
                # OLD-FAM-1: Dl v5 (2 GiB for each vCPU), and the End of Life sources
                (ScSku 'Standard_D2lds_v5' 2 4 '76800'), (ScSku 'Standard_D4lds_v5' 4 8 '153600'), (ScSku 'Standard_D8lds_v5' 8 16 '307200'),
                (ScSku 'Standard_B1s' 1 1 '4096'), (ScSku 'Standard_B2s' 2 4 '8192'), (ScSku 'Standard_B4ms' 4 16 '32768'),
                (ScSku 'Standard_F2s_v2' 2 4 '16384'), (ScSku 'Standard_F8s_v2' 8 16 '65536'), (ScSku 'Standard_F4' 4 8 '65536' 'V1'),
                (ScSku 'Standard_A2_v2' 2 4 '20480' 'V1'),
                (ScSku 'Standard_D2lds_v6' 2 4 '0' 'V2'),
                # v6 and v7: Generation 2 only; an NVMe temporary disk reports no MB
                (ScSku 'Standard_D2ds_v6' 2 8 '0' 'V2'), (ScSku 'Standard_D4ds_v6' 4 16 '0' 'V2'), (ScSku 'Standard_D8ds_v6' 8 32 '0' 'V2'),
                (ScSku 'Standard_D16ds_v6' 16 64 '0' 'V2'), (ScSku 'Standard_E2ds_v6' 2 16 '0' 'V2'), (ScSku 'Standard_E8ds_v6' 8 64 '0' 'V2'),
                (ScSku 'Standard_E8-4ds_v6' 8 64 '0' 'V2' '4' 4), (ScSku 'Standard_E8-2ds_v6' 8 64 '0' 'V2' '4' 2),
                (ScSku 'Standard_D8ds_v7' 8 32 '0' 'V2'), (ScSku 'Standard_D16ds_v7' 16 64 '0' 'V2'))) { $c[$s.Name] = $s }
        $c
    }
    function Global:ScChoices([string]$Source, [int]$Nics = 1, [string]$Gen = 'V1', [hashtable]$Catalog = (ScCatalog)) {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Source; c = $Catalog; n = $Nics; g = $Gen } {
            param($s, $c, $n, $g) @(Get-VmfShapeSizeChoices -SourceSize $s -CatalogBySize $c -RequiredNics $n -HyperVGeneration $g)
        }
    }
    function Global:ScPick($choices, $family, $variant = 'default') { @($choices | Where-Object { $_.family -eq $family -and $_.variant -eq $variant }) }
}
AfterAll { Remove-Item function:ScSku, function:ScCatalog, function:ScChoices, function:ScPick -ErrorAction SilentlyContinue }

Describe 'OLD-SKU-1B: the v5 choices, by shape' {
    It 'THE CASE: D4_v2 (8 vCPUs, 28 GiB) gets D8ds_v5 or E8ds_v5 - its name twin D4_v5 has half the vCPUs' {
        $c = ScChoices 'Standard_D4_v2'
        (ScPick $c 'D').size | Should -Be 'Standard_D8ds_v5'
        (ScPick $c 'E').size | Should -Be 'Standard_E8ds_v5'
        (@($c | Where-Object best)).size | Should -Be 'Standard_D8ds_v5' -Because 'both keep 8 vCPUs; D is the smaller change'
    }

    It 'a memory-heavy size is best on E: D13_v2 (8 vCPUs, 56 GiB) needs D16 but only E8' {
        $c = ScChoices 'Standard_D13_v2'
        (ScPick $c 'D').size | Should -Be 'Standard_D16ds_v5'
        (ScPick $c 'E').size | Should -Be 'Standard_E8ds_v5'
        (@($c | Where-Object best)).size | Should -Be 'Standard_E8ds_v5' -Because 'fewer vCPUs for the same memory'
    }

    It 'a D v1 name with no version is sized too: Standard_D3 (4 vCPUs, 14 GiB)' {
        (ScPick (ScChoices 'Standard_D3') 'D').size | Should -Be 'Standard_D4ds_v5'
    }

    It 'E offers its constrained sizes: the same size with fewer active cores' {
        $c = ScChoices 'Standard_D4_v2'
        $con = ScPick $c 'E' 'constrained'
        @($con.size) | Should -Be @('Standard_E8-2ds_v5', 'Standard_E8-4ds_v5')
        ($con | Where-Object size -EQ 'Standard_E8-4ds_v5').activeVcpus | Should -Be 4
        ($con | Where-Object size -EQ 'Standard_E8-4ds_v5').vcpus | Should -Be 8
        @(ScPick $c 'D' 'constrained').Count | Should -Be 0 -Because 'no D v5 size is constrained'
    }

    It 'each choice says its vCPUs and memory, and every default keeps both' {
        foreach ($x in @(ScChoices 'Standard_D13_v2' | Where-Object variant -EQ 'default')) {
            $x.vcpus | Should -BeGreaterOrEqual 8
            $x.memoryGB | Should -BeGreaterOrEqual 56
            $x.activeVcpus | Should -Be $x.vcpus
        }
    }

    It 'a machine with a temporary disk gets a d size; one without gets none' {
        (ScPick (ScChoices 'Standard_D2_v2') 'D').size | Should -Be 'Standard_D2ds_v5'
        (ScPick (ScChoices 'Standard_D2s_v4') 'D').size | Should -Be 'Standard_D2s_v5'
    }

    It 'every gate applies: a size that cannot hold the network interfaces is passed over' {
        # D2ds_v5 holds 2 network interfaces; this machine has 3.
        (ScPick (ScChoices 'Standard_D2_v2' -Nics 3) 'D').size | Should -Be 'Standard_D4ds_v5'
    }

    It 'a Generation 1 machine is offered only sizes that take Generation 1' {
        $cat = ScCatalog
        $cat['Standard_D8ds_v5'] = ScSku 'Standard_D8ds_v5' 8 32 '307200' 'V2'
        (ScPick (ScChoices 'Standard_D4_v2' -Catalog $cat) 'D').size | Should -Be 'Standard_D16ds_v5'
    }

    It 'no shape, no choices: unknown is not a guess' {
        $cat = ScCatalog
        $cat.Remove('Standard_D4_v2')
        @(ScChoices 'Standard_D4_v2' -Catalog $cat).Count | Should -Be 0
    }
}

Describe 'OLD-FAM-1: B v1, F, Fs, Fsv2 and Av2 get a route, with Dl' {
    It 'THE CASE: an A2_v2 (2 vCPUs, 4 GiB) is best on D2lds_v5 - 4 GiB - not D2ds_v5 with twice the memory' {
        $c = ScChoices 'Standard_A2_v2'
        (@($c | Where-Object best)).size | Should -Be 'Standard_D2lds_v5'
        (ScPick $c 'D').size | Should -Be 'Standard_D2ds_v5' -Because 'D is still offered'
    }

    It 'a one-vCPU B1s grows to the smallest size there is: two vCPUs, on Dl' {
        $best = @(ScChoices 'Standard_B1s' -Gen 'V2' | Where-Object best)[0]
        $best.size | Should -Be 'Standard_D2lds_v5'
        $best.vcpus | Should -Be 2
    }

    It 'a B4ms (4 vCPUs, 16 GiB) keeps its memory: on Dl that takes 8 vCPUs, so D4ds_v5 is best' {
        $c = ScChoices 'Standard_B4ms' -Gen 'V2'
        (ScPick $c 'Dl').size | Should -Be 'Standard_D8lds_v5' -Because 'D4lds_v5 has 8 GiB'
        (@($c | Where-Object best)).size | Should -Be 'Standard_D4ds_v5' -Because 'the fewest vCPUs first'
    }

    It 'an Fsv2 machine (2 GiB for each vCPU) is best on Dl; the old D4_v2 rule is unchanged' {
        (@(ScChoices 'Standard_F8s_v2' -Gen 'V2' | Where-Object best)).size | Should -Be 'Standard_D8lds_v5'
        (@(ScChoices 'Standard_D4_v2' | Where-Object best)).size | Should -Be 'Standard_D8ds_v5' -Because 'D8lds_v5 has 16 GiB, less than 28'
    }

    It 'the least memory wins before the family: a B2s (2 vCPUs, 4 GiB) is best on D2lds_v5 (4 GiB), not D2ds_v5 (8)' {
        (@(ScChoices 'Standard_B2s' -Gen 'V2' | Where-Object best)).size | Should -Be 'Standard_D2lds_v5'
    }

    It 'with equal vCPUs AND memory, D is chosen before Dl' {
        $cat = ScCatalog
        # An even tie: a Dl size with the memory of its D twin.
        $cat['Standard_D8lds_v5'] = ScSku 'Standard_D8lds_v5' 8 32 '307200'
        (@(ScChoices 'Standard_D4_v2' -Catalog $cat | Where-Object best)).size | Should -Be 'Standard_D8ds_v5'
    }

    It 'Dl on v6 too, for a Generation 2 machine: a B2s is best on D2lds_v6' {
        $t = InModuleScope VmMigrationFactory -Parameters @{ c = (ScCatalog) } {
            param($c) Resolve-VmfEntryTarget -Assessment ([pscustomobject]@{ vmId = 'b'; name = 'b'; location = 'centralus'; gen = 'V2'; os = 'Linux'
                    classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @(); sourceSize = 'Standard_B2s'; sourceDiskArch = 'scsi-temp'
                    sourceTempDisks = 1; diskController = 'SCSI'; dataDiskCount = 0; nicCount = 1; platformManaged = $false }) -CatalogBySize $c -TargetGeneration 'v6'
        }
        $t.Mapping.Target | Should -Be 'Standard_D2lds_v6'
    }

    It 'the options say what a Dl v5 size demands: Intel D v5 requires accelerated networking, and a B2s has it off' {
        $vm = [pscustomobject]@{ vmId = 'b'; name = 'b'; location = 'centralus'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
            classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @(); sourceSize = 'Standard_B2s'; sourceDiskArch = 'scsi-temp'
            sourceTempDisks = 1; diskController = 'SCSI'; dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 0; platformManaged = $false }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (ScCatalog) } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $m = $advice.machines[0]
        $m.sourceStage.stage | Should -Be 'End of Life' -Because 'B v1 is on the End of Life list'
        $dl = @(@($m.options | Where-Object { $_.option -eq 'v5' })[0].sizeChoices) | Where-Object { $_.size -eq 'Standard_D2lds_v5' }
        $dl.acceleratedNetworking.required | Should -BeTrue
        @($dl.stops) | Should -Be @('acceleratedNetworkingRequired')
    }

    It 'these families choose by shape; their replacements and every newer size do not' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_B1ls', 'Standard_B1s', 'Standard_B20ms', 'Standard_F1', 'Standard_F16', 'Standard_F2s', 'Standard_F72s_v2') {
                Test-VmfShapeChoiceSource -Generation 'V2' -SourceSize $s | Should -BeTrue -Because $s
            }
            foreach ($s in 'Standard_B2s_v2', 'Standard_B2ts_v2', 'Standard_F2as_v6', 'Standard_F4als_v7', 'Standard_D2ls_v5') {
                Test-VmfShapeChoiceSource -Generation 'V2' -SourceSize $s | Should -BeFalse -Because $s
            }
        }
    }
}
Describe 'OLD-SKU-1B: which machines choose this way' {
    It 'Generation 1 machines, and the old families, the same list the page uses' {
        InModuleScope VmMigrationFactory {
            Test-VmfShapeChoiceSource -Generation 'V1' -SourceSize 'Standard_D2s_v4' | Should -BeTrue
            foreach ($s in 'Standard_D2_v2', 'Standard_DS13-4_v2', 'Standard_A4m_v2', 'Standard_A2_v2', 'Standard_D3', 'Standard_DS2') {
                Test-VmfShapeChoiceSource -Generation 'V2' -SourceSize $s | Should -BeTrue -Because $s
            }
            foreach ($s in 'Standard_D2s_v3', 'Standard_D2ds_v4', 'Standard_E8-4ds_v5') {
                Test-VmfShapeChoiceSource -Generation 'V2' -SourceSize $s | Should -BeFalse -Because $s
            }
        }
    }

    It 'the page and the engine hold the same pattern for the old families' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $engine = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'plan' 'Planner.ps1') -Raw
        $pattern = '^Standard_((A|D|DS)\d+(-\d+)?m?(_v2)?(_Promo)?|B\d+(ls|s|ms)|F\d+s?(_v2)?)$'
        $page | Should -Match ([regex]::Escape("/$pattern/i"))
        $engine | Should -Match ([regex]::Escape("'$pattern'"))
    }
}

Describe 'OLD-SKU-1B: the target of such a machine' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:ScVm([string]$Size, [string]$Gen = 'V1') {
            [pscustomobject]@{ vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
                name = 'm'; location = 'centralus'; gen = $Gen; os = 'Linux'; classification = 'Blocked'; blockers = @('gen1-requires-redeploy'); prepNeeded = @()
                sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = ''; dataDiskCount = 1; nicCount = 1; platformManaged = $false }
        }
        # A Generation 2 machine: nothing blocks v6.
        function script:ScVm2([string]$Size, [string]$Os = 'Linux') {
            $v = ScVm $Size 'V2'
            $v.os = $Os; $v.classification = 'ReadyAfterPrep'; $v.blockers = @(); $v.diskController = 'SCSI'
            $v
        }
        function script:ScTarget($vm, [string]$Chosen = '') {
            InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (ScCatalog); ch = $Chosen } {
                param($v, $c, $ch) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize $ch
            }
        }
    }

    It 'THE DEFECT: D4_v2 gets a v5 target at all - the best choice by shape' {
        $t = ScTarget (ScVm 'Standard_D4_v2')
        $t.Mapping.Target | Should -Be 'Standard_D8ds_v5'
        $t.Path | Should -Be 'A'
        @($t.SizeChoices).Count | Should -BeGreaterThan 2
    }

    It 'a chosen size is planned, and it still passes every gate' {
        (ScTarget (ScVm 'Standard_D4_v2') 'Standard_E8-4ds_v5').Mapping.Target | Should -Be 'Standard_E8-4ds_v5'
        (ScTarget (ScVm 'Standard_D4_v2') 'Standard_E8ds_v5').Mapping.Target | Should -Be 'Standard_E8ds_v5'
    }

    It 'a chosen size no longer offered is refused, with the reason - never a quiet swap' {
        $t = ScTarget (ScVm 'Standard_D4_v2') 'Standard_E16-4ds_v5'
        $t.Mapping.Target | Should -BeNullOrEmpty
        $t.Mapping.Code | Should -Be 'chosen-size-gone'
        $t.Path | Should -Be 'MANUAL'
    }

    It 'a Generation 1 machine on a newer size keeps its name twin as the default, and may choose E' {
        $t = ScTarget (ScVm 'Standard_D2s_v4')
        $t.Mapping.Target | Should -Be 'Standard_D2s_v5'
        (@($t.SizeChoices | Where-Object family -EQ 'E')).size | Should -Contain 'Standard_E2s_v5'
    }

    It 'a name twin outside the Intel sizes (AMD D2as_v5) stays the default, listed and marked best' {
        $cat = ScCatalog
        $cat['Standard_D2as_v4'] = ScSku 'Standard_D2as_v4' 2 8 '0' 'V1,V2'
        $cat['Standard_D2as_v5'] = ScSku 'Standard_D2as_v5' 2 8 '0' 'V1,V2'
        $vm = ScVm 'Standard_D2as_v4'; $vm.sourceDiskArch = 'diskless'; $vm.sourceTempDisks = 0
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5'
        }
        $t.Mapping.Target | Should -Be 'Standard_D2as_v5'
        @($t.SizeChoices)[0].size | Should -Be 'Standard_D2as_v5'
        @(@($t.SizeChoices) | Where-Object best).size | Should -Be @('Standard_D2as_v5') -Because 'one best, and it is the planned size'
        # AMD-SHAPE-1: this pinned Intel E2s_v5 among the choices of an AMD
        # machine. It was decided on 2026-10-05 that a machine keeps its
        # processor maker, so it is offered AMD sizes only - this catalog has
        # no AMD E v5 size.
        @($t.SizeChoices).size | Should -Not -Contain 'Standard_E2s_v5'
        foreach ($choice in @($t.SizeChoices)) {
            InModuleScope VmMigrationFactory -Parameters @{ s = [string]$choice.size } { param($s) Get-VmfSizeProcessor -SizeName $s } |
                Should -Be 'AMD' -Because "$($choice.size) is offered to an AMD machine"
        }
    }

    It 'a name twin already among the choices is the best one: Gen1 E8-4ds_v4 stays on E8-4ds_v5' {
        $cat = ScCatalog
        $cat['Standard_E8-4ds_v4'] = ScSku 'Standard_E8-4ds_v4' 8 64 '307200' 'V1,V2' '4' 4
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm 'Standard_E8-4ds_v4'); c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5'
        }
        $t.Mapping.Target | Should -Be 'Standard_E8-4ds_v5'
        @(@($t.SizeChoices) | Where-Object best).size | Should -Be @('Standard_E8-4ds_v5') -Because 'best is the size the machine is planned on'
    }

    It 'a constrained name twin is listed as constrained, with its own vCPUs and its active ones' {
        $cat = ScCatalog
        $cat['Standard_E8-4as_v4'] = ScSku 'Standard_E8-4as_v4' 8 64 '0' 'V1,V2' '4' 4
        $cat['Standard_E8-4as_v5'] = ScSku 'Standard_E8-4as_v5' 8 64 '0' 'V1,V2' '4' 4
        $cat['Standard_E8s_v5'] = ScSku 'Standard_E8s_v5' 8 64 '0'
        $vm = ScVm 'Standard_E8-4as_v4'; $vm.sourceDiskArch = 'diskless'; $vm.sourceTempDisks = 0
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5'
        }
        $twin = @($t.SizeChoices)[0]
        $twin.size | Should -Be 'Standard_E8-4as_v5'
        $twin.variant | Should -Be 'constrained'
        $twin.vcpus | Should -Be 8
        $twin.activeVcpus | Should -Be 4
    }

    It 'the plan note says where the size came from - no size map was written' {
        $best = ScTarget (ScVm 'Standard_D4_v2')
        $best.Mapping.Reason | Should -BeLike 'shape-choice*'
        $chosen = ScTarget (ScVm 'Standard_D4_v2') 'Standard_E8-2ds_v5'
        $chosen.Mapping.Reason | Should -BeLike 'chosen-size*'
        $chosen.Mapping.Reason | Should -Not -BeLike '*size map*'
        $chosen.Mapping.Reason | Should -BeLike '*smaller than the machine*' -Because '2 active vCPUs of 8 is still said'
    }

    It 'OLD-SKU-V6-1 THE CASE: a Generation 2 D4_v2 gets v6 choices by shape - it has no v6 size of its own name' {
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm2 'Standard_D4_v2'); c = (ScCatalog) } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        $t.Mapping.Target | Should -Be 'Standard_D8ds_v6'
        $t.Mapping.Reason | Should -BeLike 'shape-choice (the best v6 size*'
        @($t.SizeChoices).size | Should -Be @('Standard_D8ds_v6', 'Standard_E8ds_v6', 'Standard_E8-2ds_v6', 'Standard_E8-4ds_v6')
        $t.Path | Should -Be 'A' -Because 'a Linux machine resizes in place'
    }

    It 'OLD-SKU-V6-1: the same machine on Windows takes the in-place upgrade (Preview), no longer a rebuild (REBUILD-REMOVE-PLAN-1) - its temporary disk moves from SCSI to NVMe' {
        $vm = ScVm2 'Standard_D4_v2' 'Windows'
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (ScCatalog) } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        $t.Mapping.Target | Should -Be 'Standard_D8ds_v6'
        $t.Path | Should -Be 'A'; $t.Preview | Should -BeTrue
    }

    It 'OLD-SKU-V6-1: v7 offers what the region has - here D only' {
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm2 'Standard_D4_v2'); c = (ScCatalog) } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v7'
        }
        @($t.SizeChoices).size | Should -Be @('Standard_D8ds_v7')
    }

    It 'OLD-SKU-V6-1: a chosen v6 size is planned; one no longer offered is refused' {
        $chosen = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm2 'Standard_D4_v2'); c = (ScCatalog) } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_E8-4ds_v6'
        }
        $chosen.Mapping.Target | Should -Be 'Standard_E8-4ds_v6'
        $gone = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm2 'Standard_D4_v2'); c = (ScCatalog) } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6' -ChosenSize 'Standard_E8-4ds_v5'
        }
        $gone.Mapping.Code | Should -Be 'chosen-size-gone'
        $gone.Mapping.Reason | Should -BeLike '*v6 choices*'
    }

    It 'OLD-SKU-V6-1: no v7 size fits - the reason says what was looked for, not a size that cannot exist' {
        $cat = ScCatalog
        foreach ($k in @($cat.Keys | Where-Object { $_ -like '*_v7' })) { $cat.Remove($k) }
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm2 'Standard_D4_v2'); c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v7'
        }
        $t.Mapping.Code | Should -Be 'no-shape-fit'
        # AMD-SHAPE-1: the sizes are looked for on the processor of the machine only, so the reason names it.
        $t.Mapping.Reason | Should -BeLike '*no v7 Intel Dl, D or E size in this region with at least 8 vCPUs and 28 GiB*'
        $t.Mapping.Reason | Should -Not -BeLike '*D4_v7*'
    }

    It 'OLD-SKU-V6-1: a Generation 1 machine is not sized for v6 at all, even where a catalog does not say which generations a size takes' {
        $cat = ScCatalog
        $cat['Standard_D8ds_v6'] = [pscustomobject]@{ Name = 'Standard_D8ds_v6'; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '8' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '32' },
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }, [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' },
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }) }
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm 'Standard_D4_v2'); c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v6'
        }
        @($t.SizeChoices).Count | Should -Be 0
        $t.Mapping.Target | Should -BeNullOrEmpty
    }

    It 'OLD-SKU-V6-1: the v6 option of a Windows DS13_v2 is offered, and every choice says it is the Preview (REBUILD-REMOVE-PLAN-1)' {
        $vm = ScVm2 'Standard_D4_v2' 'Windows'
        $o = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = (ScCatalog) } {
            param($v, $c) Get-VmfAdviceOption -Vm $v -Series 'v6' -RegionCatalog $c -Families (Get-VmfTargetFamilyData)
        }
        $o.supported | Should -BeTrue
        @($o.sizeChoices).Count | Should -BeGreaterThan 1
        foreach ($c in @($o.sizeChoices)) { $c.path | Should -Be 'A'; $c.preview | Should -BeTrue }
    }

    It 'the rules'' own size is accepted as the chosen size even when the catalog lists no choices' {
        # A Generation 1 machine on D2s_v4 whose catalog gives no memory: no
        # shape, so no choices - but its name twin is still its target.
        $cat = ScCatalog
        $cat['Standard_D2s_v4'] = [pscustomobject]@{ Name = 'Standard_D2s_v4'; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }, [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }) }
        $cat['Standard_D2s_v5'] = [pscustomobject]@{ Name = 'Standard_D2s_v5'; Family = 'x'; ResourceType = 'virtualMachines'; Restrictions = @()
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '0' }, [pscustomobject]@{ Name = 'HyperVGenerations'; Value = 'V1,V2' }
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }, [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '32' }) }
        $vm = ScVm 'Standard_D2s_v4'; $vm.sourceDiskArch = 'diskless'; $vm.sourceTempDisks = 0
        $t = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
            param($v, $c) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration 'v5' -ChosenSize 'Standard_D2s_v5'
        }
        @($t.SizeChoices).Count | Should -Be 0
        $t.Mapping.Target | Should -Be 'Standard_D2s_v5' -Because 'never chosen-size-gone for the rules'' own answer'
    }

    It 'v6 and v7 are untouched for Generation 1: no size choices' {
        # A machine that DOES choose on v5 - Generation 1, on an old size -
        # and a catalog that HAS the v6 and v7 sizes: the Generation 1 gate stops them.
        foreach ($series in 'v6', 'v7') {
            $t = InModuleScope VmMigrationFactory -Parameters @{ v = (ScVm 'Standard_D4_v2'); c = (ScCatalog); g = $series } {
                param($v, $c, $g) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $g
            }
            @($t.SizeChoices).Count | Should -Be 0 -Because $series
        }
        @((ScTarget (ScVm 'Standard_D4_v2')).SizeChoices).Count | Should -BeGreaterThan 0 -Because 'the same machine chooses on v5'
    }
}

Describe 'OLD-SKU-1B: the wave editor reads a chosen size as the plan''s own' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:ScEntry([string]$Size) {
            [pscustomobject]@{ path = 'A'; target = [pscustomobject]@{ size = $Size }
                assessment = [pscustomobject]@{ vmId = 'm'; name = 'm'; location = 'centralus'; gen = 'V1'; os = 'Linux'; classification = 'Blocked'
                    blockers = @('gen1-requires-redeploy'); prepNeeded = @(); sourceSize = 'Standard_D4_v2'; sourceDiskArch = 'scsi-temp'
                    sourceTempDisks = 1; diskController = ''; dataDiskCount = 1; nicCount = 1; platformManaged = $false } }
        }
        function script:ScAgrees([string]$Size, [string]$Current = 'v5') {
            InModuleScope VmMigrationFactory -Parameters @{ e = (ScEntry $Size); c = (ScCatalog); g = $Current } {
                param($e, $c, $g) Test-VmfPlannedTargetAgrees -Entry $e -CatalogBySize $c -Current $g
            }
        }
    }

    It 'THE DEFECT: a machine planned on a chosen size agrees - it is not "plan-disagrees"' {
        ScAgrees 'Standard_E8-4ds_v5' | Should -BeTrue
        ScAgrees 'Standard_E8ds_v5' | Should -BeTrue
    }

    It 'the best choice agrees, as before' {
        ScAgrees 'Standard_D8ds_v5' | Should -BeTrue
    }

    It 'OLD-SKU-V6-1: a Generation 2 machine planned on a chosen v6 size agrees too' {
        $entry = ScEntry 'Standard_E8-4ds_v6'
        $entry.assessment.gen = 'V2'; $entry.assessment.classification = 'ReadyAfterPrep'; $entry.assessment.blockers = @(); $entry.assessment.diskController = 'SCSI'
        $agrees = InModuleScope VmMigrationFactory -Parameters @{ e = $entry; c = (ScCatalog) } {
            param($e, $c) Test-VmfPlannedTargetAgrees -Entry $e -CatalogBySize $c -Current 'v6'
        }
        $agrees | Should -BeTrue
    }

    It 'OLD-SKU-V6-1: a v6 size no longer offered does not agree' {
        $entry = ScEntry 'Standard_E16-4ds_v6'
        $entry.assessment.gen = 'V2'; $entry.assessment.classification = 'ReadyAfterPrep'; $entry.assessment.blockers = @(); $entry.assessment.diskController = 'SCSI'
        InModuleScope VmMigrationFactory -Parameters @{ e = $entry; c = (ScCatalog) } {
            param($e, $c) Test-VmfPlannedTargetAgrees -Entry $e -CatalogBySize $c -Current 'v6'
        } | Should -BeFalse
    }

    It 'a size the rules no longer offer does not agree' {
        ScAgrees 'Standard_E16-4ds_v5' | Should -BeFalse
        ScAgrees 'Standard_D4ds_v5' | Should -BeFalse -Because 'smaller than the machine: never a choice'
    }
}

Describe 'OLD-SKU-1B: a chosen size is saved, planned and kept' {
    BeforeAll {
        . (Join-Path $PSScriptRoot '_PageSource.ps1')
        function script:ScId([string]$Name) { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name" }
        function script:ScVersion($rp, [string]$Name) {
            InModuleScope VmMigrationFactory -Parameters @{ p0 = $rp; n = $Name } {
                if (-not (Test-VmfStoreItem -RunPath $p0 -RelPath $n)) { return '' }
                Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $p0 -RelPath $n))
            }
        }
        function script:ScPrincipal {
            $claims = @(@{ typ = 'preferred_username'; val = 'person@example.com' }, @{ typ = 'roles'; val = 'Vmf.Operator' })
            $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
            ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
        }
        # Through the service, as the page saves.
        function script:ScSave($rp, [string]$Size) {
            $one = [pscustomobject]@{ vmId = (ScId 'old-01'); option = 'v5' }
            if ($Size) { $one | Add-Member -NotePropertyName size -NotePropertyValue $Size }
            Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $rp -Default 'current' -Choices @($one) `
                -AdviceVersion (ScVersion $rp 'target-advice.json') -ChoicesVersion (ScVersion $rp 'target-choices.json')
        }
        function script:ScChoice($rp) {
            @((Get-Content (Join-Path $rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20).choices) | Where-Object vmId -EQ (ScId 'old-01')
        }
    }

    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @((ScCatalog).Values) }
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:mig = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vm = [ordered]@{ vmId = (ScId 'old-01'); name = 'old-01'; resourceGroup = 'rg-app'; location = 'centralus'; zones = @()
            classification = 'Blocked'; gen = 'V1'; os = 'Linux'; osVersion = '18.04-LTS'; sourceSize = 'Standard_D4_v2'
            sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = ''; dataDiskCount = 1; nicCount = 1; acceleratedNicCount = 1
            platformManaged = $false; iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'
            tags = @{ app = 'old-01' }; blockers = @('gen1-requires-redeploy'); prepNeeded = @() }
        # A Generation 2 machine on an old size: v6 by shape (OLD-SKU-V6-1).
        $old2 = [ordered]@{} + $vm
        $old2.vmId = (ScId 'old-02'); $old2.name = 'old-02'; $old2.gen = 'V2'; $old2.classification = 'ReadyAfterPrep'; $old2.blockers = @()
        $old2.diskController = 'SCSI'; $old2.tags = @{ app = 'old-02' }
        # A Generation 2 machine on a newer size: v5 is open to it, with no size choices.
        $new = [ordered]@{} + $vm
        $new.vmId = (ScId 'new-01'); $new.name = 'new-01'; $new.gen = 'V2'; $new.sourceSize = 'Standard_D2s_v4'; $new.sourceDiskArch = 'diskless'
        $new.sourceTempDisks = 0; $new.classification = 'ReadyAfterPrep'; $new.blockers = @(); $new.diskController = 'SCSI'; $new.tags = @{ app = 'new-01' }
        $doc = [ordered]@{ schemaVersion = 17; runId = (Split-Path $script:rp -Leaf); generatedUtc = '2026-09-29T00:00:00Z'
            scope = @{ subscriptions = @() }; summary = @{}; vms = @($vm, $new, $old2) }
        InModuleScope VmMigrationFactory -Parameters @{ p0 = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $p0 -RunId (Split-Path $p0 -Leaf) -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p0 -RelPath 'assessment.json' -Document $d -Depth 24
        }
        Approve-VmfAssessment -RunPath $script:rp -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' } | Out-Null
        New-VmfTargetAdvice -AssessmentPath (Join-Path $script:rp 'assessment.json') | Out-Null
    }
    AfterEach { foreach ($d in $script:rp, $script:mig) { if ($d -and (Test-Path $d)) { Remove-Item $d -Recurse -Force } } }

    It 'the options offer the sizes, and the document matches its schema at version 5' {
        $raw = Get-Content (Join-Path $script:rp 'target-advice.json') -Raw
        $raw | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') | Should -BeTrue
        $v5 = @((@(($raw | ConvertFrom-Json -Depth 30).machines) | Where-Object name -EQ 'old-01').options) | Where-Object option -EQ 'v5'
        $v5.targetSize | Should -Be 'Standard_D8ds_v5'
        @($v5.sizeChoices.size) | Should -Contain 'Standard_E8-4ds_v5'
    }

    It 'THE CASE: E8-4ds_v5 chosen on the page is saved, planned, and read back by the wave editor' {
        ScSave $script:rp 'Standard_E8-4ds_v5' | Out-Null
        $c = ScChoice $script:rp
        $c.size | Should -Be 'Standard_E8-4ds_v5'
        $c.source | Should -Be 'person' -Because 'v5 is where it started, but the size is a person''s change'
        Get-Content (Join-Path $script:rp 'target-choices.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') | Should -BeTrue

        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (ScId 'old-01')
        $entry.target.size | Should -Be 'Standard_E8-4ds_v5'
        $entry.path | Should -Be 'A'

        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (ScId 'old-01') -WhatIf
        $r.CurrentSize | Should -Be 'Standard_E8-4ds_v5'
    }

    It 'no size named: the best choice, stored as none' {
        ScSave $script:rp '' | Out-Null
        (ScChoice $script:rp).size | Should -BeNullOrEmpty
        (ScChoice $script:rp).source | Should -Be 'default'
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        (@((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (ScId 'old-01')).target.size | Should -Be 'Standard_D8ds_v5'
    }

    It 'the best size named is the same as none' {
        ScSave $script:rp 'Standard_D8ds_v5' | Out-Null
        (ScChoice $script:rp).size | Should -BeNullOrEmpty
        (ScChoice $script:rp).source | Should -Be 'default'
    }

    It 'a size that is not one of the choices is refused, and nothing is saved' {
        { ScSave $script:rp 'Standard_D4ds_v5' } | Should -Throw '400*old-01*Standard_D4ds_v5*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
    }

    It 'a size for an option with no size choices is refused' {
        $new = @(@((Get-Content (Join-Path $script:rp 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30).machines) | Where-Object name -EQ 'new-01').options |
            Where-Object option -EQ 'v5'
        $new.supported | Should -BeTrue -Because 'the refusal must be for the size, not the option'
        @($new.sizeChoices).Count | Should -Be 0
        $one = [pscustomobject]@{ vmId = (ScId 'new-01'); option = 'v5'; size = 'Standard_E2s_v5' }
        { Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $script:rp -Default 'current' -Choices @($one) `
            -AdviceVersion (ScVersion $script:rp 'target-advice.json') } | Should -Throw '400*'
    }

    It 'OLD-SKU-V6-1: a v6 size chosen for a Generation 2 machine on an old size is saved and planned' {
        $one = [pscustomobject]@{ vmId = (ScId 'old-02'); option = 'v6'; size = 'Standard_E8-4ds_v6' }
        Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $script:rp -Default 'current' -Choices @($one) `
            -AdviceVersion (ScVersion $script:rp 'target-advice.json') -ChoicesVersion '' | Out-Null
        (@((Get-Content (Join-Path $script:rp 'target-choices.json') -Raw | ConvertFrom-Json -Depth 20).choices) | Where-Object vmId -EQ (ScId 'old-02')).size |
            Should -Be 'Standard_E8-4ds_v6'
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (ScId 'old-02')
        $entry.target.size | Should -Be 'Standard_E8-4ds_v6'
        $entry.path | Should -Be 'A'
    }
    It 'OLD-SKU-1C: Premium SSD for every disk is saved, and planned into the machine''s policy' {
        $one = [pscustomobject]@{ vmId = (ScId 'old-01'); option = 'v5'; disks = 'all' }
        Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $script:rp -Default 'current' -Choices @($one) `
            -AdviceVersion (ScVersion $script:rp 'target-advice.json') -ChoicesVersion '' | Out-Null
        $c = ScChoice $script:rp
        $c.disks | Should -Be 'all'
        $c.source | Should -Be 'person' -Because 'the disk types are a person''s change'
        Get-Content (Join-Path $script:rp 'target-choices.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'target-choices.schema.json') | Should -BeTrue
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (ScId 'old-01')
        $entry.policy.diskUpgrade | Should -Be 'all'
        ($entry | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }

    It 'OLD-SKU-1C: keep is stored as none, and planned as none' {
        ScSave $script:rp '' | Out-Null
        (ScChoice $script:rp).disks | Should -BeNullOrEmpty
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (ScId 'old-01')
        $entry.policy.PSObject.Properties['diskUpgrade'] | Should -BeNullOrEmpty
    }

    It 'OLD-SKU-1C: a size that takes no Premium SSD, or does not say, is refused a disk upgrade; an unknown choice too' {
        $file = Join-Path $script:rp 'target-advice.json'
        $advice = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
        $o = @(@($advice.machines | Where-Object name -EQ 'old-01')[0].options | Where-Object option -EQ 'v5')[0]
        $o.premiumDisks = $null
        foreach ($c in @($o.sizeChoices)) { $c.premiumDisks = $false }
        [IO.File]::WriteAllText($file, ($advice | ConvertTo-Json -Depth 30))
        $v = ScVersion $script:rp 'target-advice.json'
        foreach ($d in 'os', 'all') {
            { Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $script:rp -Default 'current' -AdviceVersion $v `
                -Choices @([pscustomobject]@{ vmId = (ScId 'old-01'); option = 'v5'; disks = $d }) } | Should -Throw '400*does not take Premium SSD*'
        }
        { Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $script:rp -Default 'current' -AdviceVersion $v `
            -Choices @([pscustomobject]@{ vmId = (ScId 'old-01'); option = 'v5'; disks = 'ultra' }) } | Should -Throw '400*unknown disk choice*'
        Test-Path (Join-Path $script:rp 'target-choices.json') | Should -BeFalse
    }

    It 'OLD-SKU-1C: the options say which sizes take Premium SSD' {
        $v5 = @((@((Get-Content (Join-Path $script:rp 'target-advice.json') -Raw | ConvertFrom-Json -Depth 30).machines) | Where-Object name -EQ 'old-01').options) | Where-Object option -EQ 'v5'
        $v5.premiumDisks | Should -BeTrue
        @($v5.sizeChoices | Where-Object { $_.premiumDisks -ne $true }).Count | Should -Be 0 -Because 'every choice is an s size'
    }
    It 'OLD-SKU-1C REVIEW: the wave editor moves a machine to a size that takes no Premium SSD - the disk choice is cleared, and said' {
        $one = [pscustomobject]@{ vmId = (ScId 'old-02'); option = 'v6'; disks = 'all' }
        Invoke-VmfTestFacadeSetTargets -Principal (ScPrincipal) -StorePath $script:rp -Default 'current' -Choices @($one) `
            -AdviceVersion (ScVersion $script:rp 'target-advice.json') -ChoicesVersion '' | Out-Null
        New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets | Out-Null
        # The saved options say v5's size takes no Premium SSD.
        $file = Join-Path $script:mig 'target-advice.json'
        $advice = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
        (@(@($advice.machines | Where-Object name -EQ 'old-02')[0].options | Where-Object option -EQ 'v5'))[0].premiumDisks = $false
        [IO.File]::WriteAllText($file, ($advice | ConvertTo-Json -Depth 30))
        $r = Set-VmfMachineTarget -RunPath $script:mig -VmId (ScId 'old-02') -Option v5 -ChangedBy 'operator@example.com' -Confirm:$false
        $r.Applied | Should -BeTrue
        $r.DiskChoiceCleared | Should -Match 'The disk types of old-02 are kept now'
        $entry = @((Get-Content (Join-Path $script:mig 'plan.json') -Raw | ConvertFrom-Json -Depth 30).entries) | Where-Object vmId -EQ (ScId 'old-02')
        $entry.policy.PSObject.Properties['diskUpgrade'] | Should -BeNullOrEmpty
    }
    It 'OLD-FAM-1 REVIEW: choices saved on target options that were made again since are refused, not planned on a new size' {
        ScSave $script:rp '' | Out-Null
        $file = Join-Path $script:rp 'target-advice.json'
        [IO.File]::WriteAllText($file, [IO.File]::ReadAllText($file) + ' ')
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } |
            Should -Throw '*made again since. Choose the targets again*'
    }
    It 'V3-TEMPDISK-1: choices saved on target options an earlier version made are refused, not planned on the size the rules give now' {
        # A choice with no size takes the rules' size at planning. Options from
        # older rules showed a v3 machine D4s_v6; the plan would use D4ds_v6.
        ScSave $script:rp '' | Out-Null
        $file = Join-Path $script:rp 'target-advice.json'
        $advice = Get-Content $file -Raw | ConvertFrom-Json -Depth 30
        $advice.schemaVersion = 9
        [IO.File]::WriteAllText($file, ($advice | ConvertTo-Json -Depth 30))
        # Bound to THESE options, so only the version can refuse it.
        $cf = Join-Path $script:rp 'target-choices.json'
        $choices = Get-Content $cf -Raw | ConvertFrom-Json -Depth 20
        $choices.adviceVersion = ScVersion $script:rp 'target-advice.json'
        [IO.File]::WriteAllText($cf, ($choices | ConvertTo-Json -Depth 20))
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } |
            Should -Throw '*an earlier version of this product made*'
        # And the same file at this version plans: the version is what refused it.
        $advice.schemaVersion = InModuleScope VmMigrationFactory { Get-VmfTargetAdviceSchemaVersion }
        [IO.File]::WriteAllText($file, ($advice | ConvertTo-Json -Depth 30))
        $choices.adviceVersion = ScVersion $script:rp 'target-advice.json'
        [IO.File]::WriteAllText($cf, ($choices | ConvertTo-Json -Depth 20))
        { New-VmfPlan -AssessmentPath (Join-Path $script:rp 'assessment.json') -OutPath $script:mig -RequireTargets } | Should -Not -Throw
    }
}

Describe 'OLD-SKU-1B: each size choice has the facts of its own size' {
    # DRIFT-5 rewrote THE CASE. It showed D8ds_v5 and E8ds_v5 disagreeing on
    # accelerated networking. On 2026-10-01 Microsoft changed the Intel E v5
    # pages to "Required", so both now require it, and an Intel source is
    # offered only Intel choices. The disagreement this item must catch - one
    # choice carrying the OPTION's facts instead of its own size's - now rests
    # on Premium SSD: the catalog entry for E8ds_v5 is given an INVENTED
    # PremiumIO of False, so the two choices of one machine differ again.
    It 'THE CASE: accelerated networking off - D8ds_v5 and E8ds_v5 both require it and stop for approval; each keeps its own Premium SSD fact' {
        $vm = [pscustomobject]@{ vmId = 'm'; name = 'm'; location = 'centralus'; gen = 'V1'; os = 'Linux'; osVersion = '18.04-LTS'
            classification = 'Blocked'; blockers = @('gen1-requires-redeploy'); prepNeeded = @(); sourceSize = 'Standard_D4_v2'
            sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = ''; dataDiskCount = 1; nicCount = 1
            acceleratedNicCount = 0; platformManaged = $false }
        $cat = ScCatalog
        $eSku = $cat['Standard_E8ds_v5']
        $eSku.Capabilities = @(@($eSku.Capabilities | Where-Object Name -NE 'PremiumIO') + [pscustomobject]@{ Name = 'PremiumIO'; Value = 'False' })
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $v5 = @($advice.machines[0].options) | Where-Object { $_.option -eq 'v5' }
        $v5.targetSize | Should -Be 'Standard_D8ds_v5'
        $v5.premiumDisks | Should -BeTrue
        $d = @($v5.sizeChoices) | Where-Object { $_.size -eq 'Standard_D8ds_v5' }
        $e = @($v5.sizeChoices) | Where-Object { $_.size -eq 'Standard_E8ds_v5' }
        $d.premiumDisks | Should -BeTrue
        $e.premiumDisks | Should -BeFalse -Because 'a choice carries the facts of its own size, not those of the planned size'
        $d.acceleratedNetworking.required | Should -BeTrue
        $d.acceleratedNetworking.turnsOn | Should -BeTrue
        @($d.stops) | Should -Be @('acceleratedNetworkingRequired')
        $e.acceleratedNetworking.required | Should -BeTrue -Because 'Intel E v5 requires it since 2026-10-01 (DRIFT-5)'
        $e.acceleratedNetworking.turnsOn | Should -BeTrue
        @($e.stops) | Should -Be @('acceleratedNetworkingRequired')
        $e.path | Should -Be 'A'
        $e.tempDisksTo | Should -Be 1
    }

    It 'DRIFT-5: two E v4 machines with it off disagree on v5 - AMD E2as_v5 does not require it, Intel E2s_v5 does' {
        $cat = ScCatalog
        $cat['Standard_E2as_v4'] = ScSku 'Standard_E2as_v4' 2 16 '0' 'V1,V2'
        $cat['Standard_E2as_v5'] = ScSku 'Standard_E2as_v5' 2 16 '0' 'V1,V2'
        $cat['Standard_E2s_v4'] = ScSku 'Standard_E2s_v4' 2 16 '0' 'V1,V2'
        $vms = foreach ($pair in @(@('amd', 'Standard_E2as_v4'), @('intel', 'Standard_E2s_v4'))) {
            [pscustomobject]@{ vmId = $pair[0]; name = $pair[0]; location = 'centralus'; gen = 'V2'; os = 'Linux'; osVersion = '22_04-lts-gen2'
                classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @(); sourceSize = $pair[1]
                sourceDiskArch = 'diskless'; sourceTempDisks = 0; diskController = 'SCSI'; dataDiskCount = 0; nicCount = 1
                acceleratedNicCount = 0; platformManaged = $false }
        }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = @($vms); c = $cat } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $amd = @(@($advice.machines | Where-Object vmId -EQ 'amd')[0].options) | Where-Object { $_.option -eq 'v5' }
        $intel = @(@($advice.machines | Where-Object vmId -EQ 'intel')[0].options) | Where-Object { $_.option -eq 'v5' }
        $amd.targetSize | Should -Be 'Standard_E2as_v5'
        $intel.targetSize | Should -Be 'Standard_E2s_v5'
        $amd.acceleratedNetworking.required | Should -BeFalse
        @($amd.stops).Count | Should -Be 0
        $intel.acceleratedNetworking.required | Should -BeTrue
        $intel.acceleratedNetworking.turnsOn | Should -BeTrue
        @($intel.stops) | Should -Be @('acceleratedNetworkingRequired')
    }
}
