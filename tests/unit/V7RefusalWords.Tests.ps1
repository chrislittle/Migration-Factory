#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# V7-REFUSAL-WORDS-1: a v7 refusal names the v6 size only when v6 takes the
# machine, and says where a person chooses it.
#
# The refusal said "this machine can move if the wave is set back to v6", and
# a wave has no series setting (WAVE-SERIES-GONE-1). It also named the first v6
# size the region holds, with none of the v6 checks: a Standard_D2ds_v4 machine
# with 3 network interfaces was told to choose v6, and Standard_D2ds_v6 holds 2,
# so the Choose each target step does not offer v6 for it. The v6 size is now
# the one Get-VmfTargetSize gives at v6, with the same inputs - the call the
# targets step makes for its v6 option.
#
# The catalog is tests/fixtures/intel-v4-catalog-centralus.json (read
# 2026-10-04), as V4Names.Tests.ps1 uses it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $fixture = Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'intel-v4-catalog-centralus.json') -Raw | ConvertFrom-Json
    $script:all = @{}
    foreach ($s in @($fixture.sizes)) {
        $caps = @(foreach ($cap in $s.capabilities.PSObject.Properties) { [pscustomobject]@{ Name = $cap.Name; Value = [string]$cap.Value } })
        $script:all[$s.name] = [pscustomobject]@{ Name = $s.name; ResourceType = 'virtualMachines'; Restrictions = @(); Capabilities = $caps }
    }
    # The same region with no v7 size: the not-in-region refusal.
    $script:noV7 = @{}
    foreach ($k in @($script:all.Keys | Where-Object { $_ -notlike '*_v7' })) { $script:noV7[$k] = $script:all[$k] }
    $script:advice = 'Choose v6 for this machine in the Choose each target step, then plan again\.'
}

Describe 'V7-REFUSAL-WORDS-1: the v7 refusal names v6 only where v6 takes the machine' {

    It 'not-in-region, common case: the v6 size and the step, as the last sentence' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:noV7; a = $script:advice } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D4_v4' -CatalogBySize $c -TargetGeneration 'v7'
            $r.Code | Should -Be 'not-in-region'
            # SIZE-LISTING-D-1: Microsoft lists Standard_D4s_v7, so the region
            # fact names its page before the v6 size.
            $read = (Get-VmfTargetFamilyData).microsoftSizes.readUtc
            $r.Reason | Should -Match "\(tried: Standard_D4s_v7\)\. Microsoft lists Standard_D4s_v7 \(the dsv7-series page, read $read\), and this region does not list it\. This region has Standard_D4s_v6\. $a$"
        }
    }

    It 'not-approved, common case: the v6 size and the step, as the last sentence' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:all; a = $script:advice } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4s_v4' -CatalogBySize $c -TargetGeneration 'v7' -RequiredDataDisks 1
            $r.Code | Should -Be 'not-approved'
            $r.Reason | Should -Match "This region has Standard_E8-4s_v6\. $a$"
        }
    }

    It 'not-in-region: a machine with 3 network interfaces is not sent to Standard_D2ds_v6, which holds 2' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:noV7 } {
            (Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 3).Code |
                Should -Be 'too-few-nics' -Because 'v6 does not take this machine, so the targets step does not offer it'
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v7' -RequiredNics 3
            $r.Code | Should -Be 'not-in-region'
            $r.Reason | Should -Not -Match 'Choose v6'
            $r.Reason | Should -Not -Match 'This region has'
        }
    }

    It 'not-approved: a machine with 32 data disks is not sent to Standard_E8-4s_v6, which holds 24' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:all } {
            (Get-VmfTargetSize -SourceSize 'Standard_E8-4s_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredDataDisks 32).Code |
                Should -Be 'too-few-data-disks'
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4s_v4' -CatalogBySize $c -TargetGeneration 'v7' -RequiredDataDisks 32
            $r.Code | Should -Be 'not-approved'
            $r.Reason | Should -Not -Match 'Choose v6'
            $r.Reason | Should -Not -Match 'This region has'
        }
    }

    It 'the v6 check uses the inputs of the v7 call: one network interface fewer, and v6 is named again' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:noV7; a = $script:advice } {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v7' -RequiredNics 2
            $r.Reason | Should -Match "This region has Standard_D2ds_v6\. $a$"
        }
    }

    It 'the v6 check asks v6 once, and a v6 refusal never gives v6 advice' {
        InModuleScope VmMigrationFactory -Parameters @{ c = $script:noV7 } {
            Mock Get-VmfDefaultSizeCandidates { @('Standard_D2ds_v6') } -ParameterFilter { $TargetGeneration -eq 'v6' }
            Mock Get-VmfDefaultSizeCandidates { @('Standard_D2ds_v7') } -ParameterFilter { $TargetGeneration -eq 'v7' }
            $null = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v7'
            Should -Invoke Get-VmfDefaultSizeCandidates -Times 1 -Exactly -ParameterFilter { $TargetGeneration -eq 'v7' }
            Should -Invoke Get-VmfDefaultSizeCandidates -Times 1 -Exactly -ParameterFilter { $TargetGeneration -eq 'v6' }
            $v6 = Get-VmfTargetSize -SourceSize 'Standard_D2ds_v4' -CatalogBySize $c -TargetGeneration 'v6' -RequiredNics 3
            $v6.Reason | Should -Not -Match 'Choose v6'
        }
    }

    It 'no refusal names the wave as the place to choose a series, and no sentence has two full stops' {
        InModuleScope VmMigrationFactory -Parameters @{ all = $script:all; nov7 = $script:noV7 } {
            foreach ($case in @(
                    @{ c = $nov7; s = 'Standard_D4_v4'; n = 1; d = 0 }, @{ c = $all; s = 'Standard_E8-4s_v4'; n = 1; d = 1 },
                    @{ c = $nov7; s = 'Standard_D2ds_v4'; n = 3; d = 0 }, @{ c = $all; s = 'Standard_E8-4s_v4'; n = 1; d = 32 })) {
                $r = Get-VmfTargetSize -SourceSize $case.s -CatalogBySize $case.c -TargetGeneration 'v7' -RequiredNics $case.n -RequiredDataDisks $case.d
                $r.Reason | Should -Not -Match '(?i)wave'
                $r.Reason | Should -Not -Match '\.\.'
            }
        }
    }
}
