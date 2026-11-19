#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# CONSTRAINED-DEFAULT-1: a machine on a constrained vCPU size keeps its ACTIVE
# vCPU count by default, where Microsoft lists a constrained vCPU size with
# that count on the target version.
#
# Microsoft, constrained-vcpu.md (Example workload): "The licensing fees
# charged for SQL Server are based on the available vCPU count." A machine on
# Standard_DS13-4_v2 (8 vCPUs, 4 active) was planned by default on E8ds_v5
# (8 active), with E8-4ds_v5 only a choice on the targets step - so software
# licensed by core could cost twice as much, and nothing said so.
#
# Run against REAL sizes: every constrained vCPU size of the old families in
# tests/fixtures/old-size-catalog-centralus.json (DS11-1_v2 to DS14-8_v2),
# and the E v4 constrained vCPU sizes in intel-v4-catalog-centralus.json, each
# through Resolve-VmfEntryTarget - what the target advice (the targets step)
# and the plan both read.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:catalog = @{}
    foreach ($f in 'old-size-catalog-centralus.json', 'intel-v4-catalog-centralus.json') {
        $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' $f) -Raw | ConvertFrom-Json
        foreach ($s in @($fixture.sizes)) {
            $caps = @(foreach ($q in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $q.Name; Value = [string]$q.Value } })
            $script:catalog[$s.name] = [pscustomobject]@{
                Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps
                Restrictions = @(@($s.restrictions) | ForEach-Object { [pscustomobject]@{ Type = $_.type; ReasonCode = $_.reasonCode; RestrictionInfo = [pscustomobject]@{ Zones = @($_.zones) } } })
                LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
            }
        }
    }
    function Global:CdCap($Entry, [string]$Name) {
        $c = @($Entry.Capabilities | Where-Object { $_.Name -eq $Name })
        if ($c.Count) { [string]$c[0].Value } else { $null }
    }
    function Global:CdTarget([string]$Size, [string]$Gen, [string]$Series, [int]$Nics = 1) {
        $e = $script:catalog[$Size]
        $temp = [int](CdCap $e 'MaxResourceVolumeMB')
        $vm = [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            name = 'm'; location = 'centralus'; gen = $Gen; os = 'Linux'; osVersion = '22_04-lts'
            classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = $(if ($temp -gt 0) { 'scsi-temp' } else { 'diskless' })
            sourceTempDisks = $(if ($temp -gt 0) { 1 } else { 0 }); diskController = 'SCSI'
            nicCount = $Nics; dataDiskCount = 1; acceleratedNicCount = 1; platformManaged = $false
        }
        InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $script:catalog; s = $Series } {
            param($v, $c, $s) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s
        }
    }
    function Global:CdShape([string]$Size) {
        $e = $script:catalog[$Size]
        [pscustomobject]@{ Vcpus = [int](CdCap $e 'vCPUs'); Active = [int](CdCap $e 'vCPUsAvailable'); MemoryGB = [double](CdCap $e 'MemoryGB') }
    }
}
AfterAll { Remove-Item function:CdCap, function:CdTarget, function:CdShape -ErrorAction SilentlyContinue }

Describe 'CONSTRAINED-DEFAULT-1: an old constrained vCPU size keeps its active vCPUs by default' {
    It 'the fixture holds every DS v2 constrained vCPU size, each with fewer active vCPUs than vCPUs' {
        foreach ($n in 'DS11-1_v2', 'DS12-1_v2', 'DS12-2_v2', 'DS13-2_v2', 'DS13-4_v2', 'DS14-4_v2', 'DS14-8_v2') {
            $script:catalog.ContainsKey("Standard_$n") | Should -BeTrue -Because "Standard_$n is a source to test"
            $sh = CdShape "Standard_$n"
            $sh.Active | Should -BeLessThan $sh.Vcpus -Because "Standard_$n is a constrained vCPU size"
        }
    }

    It 'THE CASE: Standard_DS13-4_v2 (8 vCPUs, 4 active) is planned on E8-4ds_v5, not E8ds_v5 (8 active)' {
        $t = CdTarget 'Standard_DS13-4_v2' 'V1' 'v5'
        $t.Mapping.Target | Should -Be 'Standard_E8-4ds_v5'
        @(@($t.SizeChoices) | Where-Object best).size | Should -Be @('Standard_E8-4ds_v5') -Because 'one best choice, and it is the planned size'
        @($t.SizeChoices).size | Should -Contain 'Standard_E8ds_v5' -Because 'the full size stays a choice'
    }

    It 'each one keeps its active vCPUs where Microsoft lists that constrained vCPU size: <Source> (<Gen>) on <Series> is <Expected>' -TestCases @(
        @{ Source = 'Standard_DS12-2_v2'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E4-2ds_v5' }
        @{ Source = 'Standard_DS12-2_v2'; Gen = 'V2'; Series = 'v5'; Expected = 'Standard_E4-2ds_v5' }
        @{ Source = 'Standard_DS12-2_v2'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E4-2ds_v6' }
        @{ Source = 'Standard_DS13-2_v2'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E8-2ds_v5' }
        @{ Source = 'Standard_DS13-2_v2'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E8-2ds_v6' }
        @{ Source = 'Standard_DS13-4_v2'; Gen = 'V2'; Series = 'v5'; Expected = 'Standard_E8-4ds_v5' }
        @{ Source = 'Standard_DS13-4_v2'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E8-4ds_v6' }
        @{ Source = 'Standard_DS14-4_v2'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E16-4ds_v5' }
        @{ Source = 'Standard_DS14-4_v2'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E16-4ds_v6' }
        @{ Source = 'Standard_DS14-8_v2'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E16-8ds_v5' }
        @{ Source = 'Standard_DS14-8_v2'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E16-8ds_v6' }
    ) {
        $t = CdTarget $Source $Gen $Series
        $t.Mapping.Target | Should -Be $Expected
        @(@($t.SizeChoices) | Where-Object best).size | Should -Be @($Expected)
        $src = CdShape $Source; $dst = CdShape $Expected
        $dst.Active | Should -Be $src.Active -Because 'the active vCPU count is kept'
        $dst.MemoryGB | Should -BeGreaterOrEqual $src.MemoryGB -Because 'never less memory'
        $t.Mapping.Reason | Should -BeLike 'shape-choice*'
        $t.Mapping.Reason | Should -Not -BeLike '*smaller than the machine*'
    }

    It 'every constrained source and option: where a choice keeps the active vCPUs and the memory, it is the default' {
        $checked = 0
        foreach ($src in @($script:catalog.Keys | Where-Object { $_ -match '^Standard_DS\d+-\d+_v2$' } | Sort-Object)) {
            $sh = CdShape $src
            foreach ($gen in @((CdCap $script:catalog[$src] 'HyperVGenerations') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
                foreach ($s in $(if ($gen -eq 'V1') { @('v5') } else { @('v5', 'v6', 'v7') })) {
                    $t = CdTarget $src $gen $s
                    $keep = @(@($t.SizeChoices) | Where-Object { [int]$_.activeVcpus -eq $sh.Active -and [double]$_.memoryGB -ge $sh.MemoryGB })
                    if ($keep.Count) {
                        $checked++
                        $t.Mapping.Target | Should -Be ([string]$keep[0].size) -Because "$src ($gen) on $s has $($sh.Active) active vCPUs"
                        $keep[0].variant | Should -Be 'constrained'
                    }
                }
            }
        }
        $checked | Should -BeGreaterOrEqual 10 -Because 'this cannot pass by finding nothing'
    }

    It 'with no constrained vCPU size of that active count, the default is the full size, as before: <Source> on <Series>' -TestCases @(
        # DS11-1_v2 (2 vCPUs, 1 active): Microsoft lists no constrained vCPU
        # size with 1 active vCPU. DS12-1_v2 (4, 1 active) the same. And no
        # Intel E v7 constrained vCPU size is listed (only AMD ones).
        @{ Source = 'Standard_DS11-1_v2'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E2ds_v5' }
        @{ Source = 'Standard_DS12-1_v2'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E4ds_v5' }
        @{ Source = 'Standard_DS13-4_v2'; Gen = 'V2'; Series = 'v7'; Expected = 'Standard_E8ds_v7' }
    ) {
        $t = CdTarget $Source $Gen $Series
        $t.Mapping.Target | Should -Be $Expected
        @(@($t.SizeChoices) | Where-Object best).size | Should -Be @($Expected)
    }

    It 'a machine on a full size keeps the full size: DS13_v2 (8 vCPUs, all active) is not given a constrained vCPU size' {
        foreach ($src in 'Standard_DS13_v2', 'Standard_D13_v2', 'Standard_DS14_v2') {
            if (-not $script:catalog.ContainsKey($src)) { continue }
            $t = CdTarget $src 'V1' 'v5'
            @(@($t.SizeChoices) | Where-Object best)[0].variant | Should -Be 'default' -Because "$src has all its vCPUs active"
        }
        (CdTarget 'Standard_DS13_v2' 'V1' 'v5').Mapping.Target | Should -Be 'Standard_E8ds_v5'
    }

    It 'a machine with all its vCPUs active keeps the full size even when a constrained vCPU size has its count' {
        # A size of 4 vCPUs, all active, and 56 GiB: its smallest E size is
        # E8ds_v5 (64 GiB), and E8-4ds_v5 has 4 active vCPUs. The machine
        # did not choose constrained vCPUs, so the full size is the default.
        $saved = $script:catalog['Standard_DS13_v2']
        $caps = @(foreach ($c in $saved.Capabilities) {
                $v = switch ($c.Name) { 'vCPUs' { '4' } 'vCPUsAvailable' { '4' } 'MemoryGB' { '56' } default { $c.Value } }
                [pscustomobject]@{ Name = $c.Name; Value = $v } })
        $script:catalog['Standard_DS13_v2'] = [pscustomobject]@{ Name = $saved.Name; ResourceType = 'virtualMachines'; Capabilities = $caps
            Restrictions = @(); LocationInfo = $saved.LocationInfo }
        try {
            $t = CdTarget 'Standard_DS13_v2' 'V1' 'v5'
            @($t.SizeChoices).size | Should -Contain 'Standard_E8-4ds_v5' -Because 'the constrained vCPU size with 4 active vCPUs is a choice'
            $t.Mapping.Target | Should -Be 'Standard_E8ds_v5'
        }
        finally { $script:catalog['Standard_DS13_v2'] = $saved }
    }

    It 'the constrained vCPU default still passes every gate: two network interfaces on DS13-4_v2' {
        $t = CdTarget 'Standard_DS13-4_v2' 'V1' 'v5' -Nics 2
        $t.Mapping.Target | Should -Be 'Standard_E8-4ds_v5'
    }
}

Describe 'CONSTRAINED-DEFAULT-1: an E v3 or v4 constrained vCPU size keeps its name twin' {
    It '<Source> (<Gen>) on <Series> is <Expected>' -TestCases @(
        @{ Source = 'Standard_E4-2s_v4'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E4-2s_v5' }
        @{ Source = 'Standard_E8-4ds_v4'; Gen = 'V1'; Series = 'v5'; Expected = 'Standard_E8-4ds_v5' }
        @{ Source = 'Standard_E8-4ds_v4'; Gen = 'V2'; Series = 'v5'; Expected = 'Standard_E8-4ds_v5' }
        @{ Source = 'Standard_E8-4ds_v4'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E8-4ds_v6' }
        @{ Source = 'Standard_E16-4s_v4'; Gen = 'V2'; Series = 'v6'; Expected = 'Standard_E16-4s_v6' }
        @{ Source = 'Standard_E64-16ds_v4'; Gen = 'V2'; Series = 'v5'; Expected = 'Standard_E64-16ds_v5' }
    ) {
        $t = CdTarget $Source $Gen $Series
        $t.Mapping.Target | Should -Be $Expected
        (CdShape $Expected).Active | Should -Be (CdShape $Source).Active
    }

    It 'E v3: Standard_E8-4s_v3 (8 vCPUs, 4 active) keeps 4 active vCPUs on v5 and v6' {
        # Not in the fixture: the E v3 constrained vCPU size has the shape of
        # its v4 twin (Microsoft's constrained-vcpu page lists both).
        $script:catalog['Standard_E8-4s_v3'] = [pscustomobject]@{ Name = 'Standard_E8-4s_v3'; ResourceType = 'virtualMachines'
            Capabilities = $script:catalog['Standard_E8-4s_v4'].Capabilities; Restrictions = @(); LocationInfo = @() }
        try {
            (CdTarget 'Standard_E8-4s_v3' 'V1' 'v5').Mapping.Target | Should -Be 'Standard_E8-4s_v5'
            (CdTarget 'Standard_E8-4s_v3' 'V2' 'v6').Mapping.Target | Should -Be 'Standard_E8-4s_v6'
        }
        finally { $script:catalog.Remove('Standard_E8-4s_v3') }
    }
}
