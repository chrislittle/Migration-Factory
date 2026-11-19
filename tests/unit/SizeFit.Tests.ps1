#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SIZE-FIT-1: the planner never picks a smaller machine.
#
# The default transform keeps a size's NUMBER and changes its version. From v3
# on the number is the vCPU count, so the twin has the same shape. On Dv2 it is
# not: Standard_D4_v2 has 8 vCPUs and 28 GiB, and its name twin
# Standard_D4_v5 has 4 vCPUs and 16 GiB. The planner mapped it, and nothing
# said so. Found by the independent review of MAP-FIX-1 (2026-09-28); the
# shapes below are the ones Azure's catalog reports for centralus (2026-09-29).
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:SfSku([string]$Name, [string]$Vcpus, [string]$MemoryGB, [string]$TempMb = '0', [string]$Gens = 'V1,V2', [string]$Available = '') {
        $caps = @(
            [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = $TempMb }
            [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = '4' }
            [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = '8' }
            [pscustomobject]@{ Name = 'HyperVGenerations'; Value = $Gens })
        if ($Vcpus) { $caps += [pscustomobject]@{ Name = 'vCPUs'; Value = $Vcpus } }
        if ($MemoryGB) { $caps += [pscustomobject]@{ Name = 'MemoryGB'; Value = $MemoryGB } }
        if ($Available) { $caps += [pscustomobject]@{ Name = 'vCPUsAvailable'; Value = $Available } }
        [pscustomobject]@{ Name = $Name; Family = 'standardX'; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    function Global:SfCatalog([object[]]$Skus) { $c = @{}; foreach ($s in $Skus) { $c[$s.Name] = $s }; $c }
    function Global:SfPick([string]$Source, [hashtable]$Catalog, [string]$Series = 'v5', [string]$Gen = 'V1') {
        InModuleScope VmMigrationFactory -Parameters @{ s = $Source; c = $Catalog; g = $Series; h = $Gen } {
            param($s, $c, $g, $h) Get-VmfTargetSize -SourceSize $s -CatalogBySize $c -TargetGeneration $g -HyperVGeneration $h
        }
    }
}
AfterAll { Remove-Item function:SfSku, function:SfCatalog, function:SfPick -ErrorAction SilentlyContinue }

Describe 'SIZE-FIT-1: a size''s shape' {
    It 'reads the vCPUs a machine can use - vCPUsAvailable on a constrained size - and its memory' {
        $shape = InModuleScope VmMigrationFactory -Parameters @{ e = (SfSku 'Standard_E8-4ds_v5' '8' '64' -Available '4') } { param($e) Get-VmfSkuShape -SkuEntry $e }
        $shape.Vcpus | Should -Be 4
        $shape.MemoryGB | Should -Be 64
    }

    It 'says nothing it was not told' {
        $shape = InModuleScope VmMigrationFactory -Parameters @{ e = (SfSku 'Standard_X' '' '') } { param($e) Get-VmfSkuShape -SkuEntry $e }
        $shape.Vcpus | Should -BeNullOrEmpty
        $shape.MemoryGB | Should -BeNullOrEmpty
    }

    It 'names the sizes whose number is not the vCPU count, and only those' {
        foreach ($n in 'Standard_D4', 'Standard_DS4', 'Standard_D4_v2', 'Standard_DS11_v2', 'Standard_DS13-4_v2', 'Standard_D2_v2_Promo', 'Standard_A2m_v2') {
            InModuleScope VmMigrationFactory -Parameters @{ n = $n } { param($n) Test-VmfSizeNameIsNotVcpus -SizeName $n } | Should -BeTrue -Because $n
        }
        # A1_v2 to A8_v2 ARE numbered by vCPU (the review of 2026-09-29).
        foreach ($n in 'Standard_D4s_v3', 'Standard_D4_v4', 'Standard_E8s_v5', 'Standard_D4ds_v4', 'Standard_E8-4ds_v5', 'Standard_D2s_v6', 'Standard_A4_v2', 'Standard_A8_v2') {
            InModuleScope VmMigrationFactory -Parameters @{ n = $n } { param($n) Test-VmfSizeNameIsNotVcpus -SizeName $n } | Should -BeFalse -Because $n
        }
    }

    It 'compares both vCPUs and memory, and a known smaller is smaller even when the other is unknown' {
        $cases = @(
            @{ S = @{ Vcpus = 8; MemoryGB = 28 }; T = @{ Vcpus = 4; MemoryGB = 16 }; Want = 'smaller' }
            @{ S = @{ Vcpus = 2; MemoryGB = 14 }; T = @{ Vcpus = 2; MemoryGB = 8 };  Want = 'smaller' }
            @{ S = @{ Vcpus = 2; MemoryGB = 7 };  T = @{ Vcpus = 2; MemoryGB = 8 };  Want = 'fits' }
            @{ S = @{ Vcpus = 8; MemoryGB = $null }; T = @{ Vcpus = 4; MemoryGB = 32 }; Want = 'smaller' }
            @{ S = @{ Vcpus = $null; MemoryGB = 28 }; T = @{ Vcpus = 8; MemoryGB = 32 }; Want = 'unknown' }
        )
        foreach ($c in $cases) {
            InModuleScope VmMigrationFactory -Parameters @{ s = [pscustomobject]$c.S; t = [pscustomobject]$c.T } { param($s, $t) Test-VmfSizeSmaller -Source $s -Target $t } |
                Should -Be $c.Want -Because ($c | ConvertTo-Json -Compress)
        }
    }
}

Describe 'SIZE-FIT-1: the planner never picks a smaller size' {
    It 'Standard_D4_v2 (8 vCPUs, 28 GiB) is not mapped to Standard_D4_v5 (4, 16) - it is refused, with both shapes' {
        $cat = SfCatalog @((SfSku 'Standard_D4_v2' '8' '28' '409600'), (SfSku 'Standard_D4d_v5' '4' '16' '153600'), (SfSku 'Standard_D4_v5' '4' '16'))
        $r = SfPick 'Standard_D4_v2' $cat
        $r.Target | Should -BeNullOrEmpty
        $r.Code | Should -Be 'smaller-than-source'
        $r.Reason | Should -Match 'Standard_D4_v2 has 8 vCPUs and 28 GiB'
        $r.Reason | Should -Match 'Standard_D4d_v5 has 4 vCPUs and 16 GiB'
    }

    It 'Standard_D2_v2 (2 vCPUs, 7 GiB) still goes to Standard_D2d_v5 (2, 8): larger memory is not smaller' {
        $cat = SfCatalog @((SfSku 'Standard_D2_v2' '2' '7' '102400'), (SfSku 'Standard_D2d_v5' '2' '8' '76800'), (SfSku 'Standard_D2_v5' '2' '8'))
        $r = SfPick 'Standard_D2_v2' $cat
        $r.Target | Should -Be 'Standard_D2d_v5'
        $r.Code | Should -Be 'mapped'
    }

    It 'a smaller first candidate falls to a later one that fits' {
        # The d twin reports less memory here; the plain size fits.
        $cat = SfCatalog @((SfSku 'Standard_D2_v2' '2' '7' '102400'), (SfSku 'Standard_D2d_v5' '2' '4' '76800'), (SfSku 'Standard_D2_v5' '2' '8'))
        (SfPick 'Standard_D2_v2' $cat).Target | Should -Be 'Standard_D2_v5'
    }

    It 'an old size missing from the catalog is not planned on its name' {
        $cat = SfCatalog @((SfSku 'Standard_D4d_v5' '4' '16' '153600'), (SfSku 'Standard_D4_v5' '4' '16'))
        $r = SfPick 'Standard_D4_v2' $cat
        $r.Target | Should -BeNullOrEmpty
        $r.Code | Should -Be 'shape-unknown'
    }

    It 'a v3 size missing from the catalog is still planned on its name, as before - Microsoft stops offering v3 in newer subscriptions' {
        $cat = SfCatalog @((SfSku 'Standard_D4ds_v5' '4' '16' '153600'), (SfSku 'Standard_D4s_v5' '4' '16'))
        $r = SfPick 'Standard_D4s_v3' $cat -Gen 'V2'
        $r.Target | Should -Not -BeNullOrEmpty
        $r.Code | Should -Be 'mapped'
    }


    It 'the targets step gets the code, so the screen can say it' {
        $cat = SfCatalog @((SfSku 'Standard_D4_v2' '8' '28' '409600'), (SfSku 'Standard_D4d_v5' '4' '16' '153600'), (SfSku 'Standard_D4_v5' '4' '16'))
        $vm = [pscustomobject]@{ vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/old'
            name = 'old'; location = 'centralus'; classification = 'Blocked'; gen = 'V1'; os = 'Linux'; osVersion = '22_04-lts'
            sourceSize = 'Standard_D4_v2'; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = ''
            dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 0; primaryNicAccelerated = $false; platformManaged = $false
            iacManaged = $false; hibernationEnabled = $false; availabilitySetId = ''; identityType = 'None'; tags = @{}
            blockers = @('gen1-requires-redeploy'); prepNeeded = @(); zones = @() }
        $opt = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } { param($v, $c) Get-VmfAdviceOption -Vm $v -Series 'v5' -RegionCatalog $c }
        @($opt.notSupported) | Should -Contain 'smaller-than-source'
        $opt.supported | Should -BeFalse
    }


    It 'a "use this size instead" suggestion is never smaller than the machine either' {
        # A machine with 4 NICs: the name twin holds 2. The suggestion keeps the
        # source's letters (none on D4_v2): D2_v5 would hold 4 but is smaller
        # than the machine; D8_v5 fits both.
        $sku = { param($n, $v, $m, $nics) $s = SfSku $n $v $m '76800'; ($s.Capabilities | Where-Object Name -eq 'MaxNetworkInterfaces').Value = $nics; $s }
        $cat = SfCatalog @((& $sku 'Standard_D4_v2' '8' '28' '8'), (& $sku 'Standard_D4d_v5' '4' '16' '2'), (& $sku 'Standard_D2_v5' '2' '8' '4'), (& $sku 'Standard_D8_v5' '8' '32' '4'))
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $cat } { param($c) Get-VmfTargetSize -SourceSize 'Standard_D4_v2' -CatalogBySize $c -TargetGeneration 'v5' -HyperVGeneration 'V1' -RequiredNics 4 }
        $r.Code | Should -Be 'too-few-nics'
        $r.Reason | Should -Match 'use Standard_D8_v5 instead'
        $r.Reason | Should -Not -Match 'Standard_D2_v5 instead'
    }

    It 'the version bump has its migration note' {
        Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw | Should -Match 'target-advice v2 -> v3 \(2026-09-29, SIZE-FIT-1\)'
    }

    It 'the screen has words for both codes' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        $page | Should -Match "'smaller-than-source': '"
        $page | Should -Match "'shape-unknown': '"
    }
}
