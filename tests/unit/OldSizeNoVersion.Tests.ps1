#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-SIZE-NOVERSION-1: a size with no version in its name gets the right reason.
#
# REVIEW-1 found that Standard_D2 (D v1) was told `not-in-region` - "no
# candidate available in region (tried: )". The default transform changes the
# version in a size name, so a name with no version gives it no size to try,
# and its fallback said the region had none. OLD-FAM-4's table: D v1, DS v1, F,
# Fs and B v1 already get a target BY SHAPE (Resolve-VmfEntryTarget), so the
# route was there. What was left were the two cases where the shape route
# gives no size and the name rule's false answer came through:
#   - a Generation 1 machine on v6 or v7, which take Generation 2 only. D v1
#     said `not-in-region`; DS v1, F, Fs and B v1 said `family-not-in-region`
#     ("not part of the v6/v7 migration path"). Both false: v5 takes it.
#   - a size whose vCPUs and memory the region's catalog does not give, so no
#     size can be chosen by shape. The same two false codes came through.
# The fix reuses the codes the targets step already has words for:
# gen1-no-size and shape-unknown.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'old-size-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:catalog = @{}
    foreach ($s in @($fixture.sizes)) {
        $caps = @(foreach ($c in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $c.Name; Value = [string]$c.Value } })
        $script:catalog[$s.name] = [pscustomobject]@{
            Name = $s.name; ResourceType = 'virtualMachines'; Capabilities = $caps; Restrictions = @()
            LocationInfo = @([pscustomobject]@{ Location = 'centralus'; Zones = @($s.zones) })
        }
    }
    # Every size in the real catalog with no version in its name.
    $script:noVersion = @($script:catalog.Keys | Where-Object { $_ -match '^Standard_[A-Za-z]+\d+[a-z]*$' } | Sort-Object)

    function Global:NvMachine([string]$Size, [string]$Gen) {
        [pscustomobject]@{
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/m'
            name = 'm'; location = 'centralus'; gen = $Gen; os = 'Linux'; osVersion = '22_04-lts'
            classification = 'ReadyAfterPrep'; blockers = @(); prepNeeded = @()
            sourceSize = $Size; sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = 'SCSI'
            nicCount = 1; dataDiskCount = 0; acceleratedNicCount = 0; platformManaged = $false
        }
    }
    function Global:NvResolve($Vm, [hashtable]$Catalog, [string]$Series) {
        InModuleScope VmMigrationFactory -Parameters @{ v = $Vm; c = $Catalog; s = $Series } {
            param($v, $c, $s) Resolve-VmfEntryTarget -Assessment $v -CatalogBySize $c -TargetGeneration $s
        }
    }
    function Global:NvWithout([string]$Size) {
        $c = $script:catalog.Clone(); $c.Remove($Size); $c
    }
}
AfterAll { Remove-Item function:NvMachine, function:NvResolve, function:NvWithout -ErrorAction SilentlyContinue }

Describe 'OLD-SIZE-NOVERSION-1: the sizes with no version in their name, from the real catalog' {

    It 'the fixture holds them, so this cannot pass by reading nothing' {
        foreach ($n in 'Standard_D1', 'Standard_D2', 'Standard_D4', 'Standard_D11', 'Standard_D14', 'Standard_DS2', 'Standard_F2', 'Standard_F2s', 'Standard_B2s') {
            $script:noVersion | Should -Contain $n
        }
        $script:noVersion.Count | Should -BeGreaterThan 30
    }

    It 'Standard_D2 keeps its route by shape: a target on v5, v6 and v7 for Generation 2, and on v5 for Generation 1' {
        foreach ($s in 'v5', 'v6', 'v7') {
            $t = NvResolve (NvMachine 'Standard_D2' 'V2') $script:catalog $s
            $t.Mapping.Target | Should -Match "^Standard_D\d+l?ds_$s$" -Because $s
            $t.Mapping.Code | Should -Be 'mapped' -Because $s
        }
        (NvResolve (NvMachine 'Standard_D2' 'V1') $script:catalog 'v5').Mapping.Target | Should -Be 'Standard_D2ds_v5'
    }

    It 'a Generation 1 machine on v6 or v7 is told it is Generation 1, never that the region or the family has no size' {
        $wrong = [System.Collections.Generic.List[string]]::new()
        foreach ($n in $script:noVersion) {
            foreach ($s in 'v6', 'v7') {
                $t = NvResolve (NvMachine $n 'V1') $script:catalog $s
                if ($t.Mapping.Target -or $t.Mapping.Code -ne 'gen1-no-size' -or
                    $t.Mapping.Reason -notmatch "Generation 1" -or $t.Mapping.Reason -notmatch "$s takes Generation 2 machines only" -or
                    $t.Mapping.Reason -notmatch 'v5 takes Generation 1 machines') {
                    $wrong.Add("$n $s -> $($t.Mapping.Code): $($t.Mapping.Reason)")
                }
            }
        }
        $wrong | Should -BeNullOrEmpty
    }

    It 'a size whose vCPUs and memory the catalog does not give is told so, on every series and generation' {
        $wrong = [System.Collections.Generic.List[string]]::new()
        foreach ($n in $script:noVersion) {
            $c = NvWithout $n
            foreach ($gen in 'V1', 'V2') {
                foreach ($s in $(if ($gen -eq 'V1') { @('v5') } else { @('v5', 'v6', 'v7') })) {
                    $t = NvResolve (NvMachine $n $gen) $c $s
                    if ($t.Mapping.Target -or $t.Mapping.Code -ne 'shape-unknown' -or
                        $t.Mapping.Reason -notmatch [regex]::Escape("does not give the vCPUs and memory of $n")) {
                        $wrong.Add("$n $gen $s -> $($t.Mapping.Code): $($t.Mapping.Reason)")
                    }
                }
            }
        }
        $wrong | Should -BeNullOrEmpty
    }

    It 'no size with no version is ever told not-in-region or family-not-in-region' {
        $wrong = [System.Collections.Generic.List[string]]::new()
        foreach ($n in $script:noVersion) {
            foreach ($c in @($script:catalog, (NvWithout $n))) {
                foreach ($gen in 'V1', 'V2') {
                    foreach ($s in 'v5', 'v6', 'v7') {
                        $code = (NvResolve (NvMachine $n $gen) $c $s).Mapping.Code
                        if ($code -in @('not-in-region', 'family-not-in-region')) { $wrong.Add("$n $gen $s -> $code") }
                    }
                }
            }
        }
        $wrong | Should -BeNullOrEmpty
    }

    It 'the option on the targets step carries the same reason' {
        $o = InModuleScope VmMigrationFactory -Parameters @{ v = (NvMachine 'Standard_D2' 'V2'); c = (NvWithout 'Standard_D2') } {
            param($v, $c) Get-VmfAdviceOption -Vm $v -Series 'v6' -RegionCatalog $c
        }
        @($o.notSupported) | Should -Be @('shape-unknown')
        $o = InModuleScope VmMigrationFactory -Parameters @{ v = (NvMachine 'Standard_D2' 'V1'); c = $script:catalog } {
            param($v, $c) Get-VmfAdviceOption -Vm $v -Series 'v7' -RegionCatalog $c
        }
        @($o.notSupported) | Should -Be @('gen1-no-size')
    }

    It 'the targets step has words for both reasons' {
        $page = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'wizard.html'))
        foreach ($code in 'gen1-no-size', 'shape-unknown') { $page | Should -Match "'$code': '" }
    }
}

Describe 'OLD-SIZE-NOVERSION-1: the true reasons of other sizes do not change' {

    It 'a family outside the migration path is still told so, Generation 1 or not' {
        foreach ($gen in 'V1', 'V2') {
            $c = @{ 'Standard_D2ds_v6' = $script:catalog['Standard_D2ds_v6'] }
            $t = NvResolve (NvMachine 'Standard_L8s_v3' $gen) $c 'v6'
            $t.Mapping.Code | Should -Be 'family-not-in-region' -Because $gen
        }
    }

    It 'a Generation 1 machine on a v4 size, on a v7 option the region has no size for, is told it is Generation 1, not to go back to v6' {
        $c = $script:catalog.Clone()
        foreach ($k in @($c.Keys | Where-Object { $_ -like '*_v7' })) { $c.Remove($k) }
        $t = NvResolve (NvMachine 'Standard_D2ds_v4' 'V1') $c 'v7'
        $t.Mapping.Code | Should -Be 'gen1-no-size'
        # V7-REFUSAL-WORDS-1: the v7 refusal's v6 advice now reads this way.
        $t.Mapping.Reason | Should -Not -Match 'Choose v6 for this machine'
    }

    It 'a size with a version and a known shape keeps the code the name rule gives' {
        $c = $script:catalog.Clone()
        foreach ($k in @($c.Keys | Where-Object { $_ -like '*_v7' })) { $c.Remove($k) }
        $t = NvResolve (NvMachine 'Standard_D2ds_v4' 'V2') $c 'v7'
        $t.Mapping.Code | Should -Be 'not-in-region'
    }
}
