#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# OLD-FAM-3: the families this tool does not move are named on the
# assessment, as outside its scope, with Microsoft's own route.
#
# Decided 2026-09-29: HPC and FPGA are left out entirely as unsupported; G,
# Gs, Ls and Lsv2 are refused with the reason. There is no technical reason
# behind it - it is a scope choice. So the words say
# SCOPE, never an invented technical limit.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
}

Describe 'OLD-FAM-3: which sizes are out of scope' {
    It 'HPC and FPGA: the H family and NP' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_HC44rs', 'Standard_HC44-16rs', 'Standard_HB120rs_v2', 'Standard_HB176rs_v4', 'Standard_HB368rs_v5', 'Standard_HX176rs', 'Standard_H16r', 'Standard_NP10s', 'Standard_NP40s') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -Be 'hpc-or-fpga-size' -Because $s
            }
        }
    }

    It 'Ls and Lsv2 - the End of Life L series - and no newer L size' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_L4s', 'Standard_L32s', 'Standard_L8s_v2', 'Standard_L80s_v2') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -Be 'local-nvme-storage-size' -Because $s
            }
            foreach ($s in 'Standard_L8s_v3', 'Standard_L8as_v3', 'Standard_L2aos_v4', 'Standard_L16as_v5') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -BeNullOrEmpty -Because "$s is not End of Life"
            }
        }
    }

    It 'G and GS' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_G1', 'Standard_G5', 'Standard_GS1', 'Standard_GS4-8', 'Standard_GS5-16') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -Be 'l-series-replacement' -Because $s
            }
        }
    }

    # GPU-SCOPE-1 rewrote this test: it said "no GPU size it was not asked
    # about" and held NC6s_v3 and NV12s_v3 to no code. GPU sizes then went
    # out of scope (2026-10-09), so they get gpu-size - GpuScope.Tests.ps1.
    It 'nothing the tool moves' {
        InModuleScope VmMigrationFactory {
            foreach ($s in 'Standard_D2s_v4', 'Standard_B2s', 'Standard_F8s_v2', 'Standard_A2_v2', 'Standard_E8-4ds_v5', 'Standard_DC2s_v3', 'Standard_M8ms', '') {
                Get-VmfUnsupportedFamilyCode -SizeName $s | Should -BeNullOrEmpty -Because $s
            }
        }
    }
}

Describe 'OLD-FAM-3: the assessment says so, for every series' {
    It 'a machine on each kind of size gets its blocker from the scan' {
        foreach ($case in @(@('Standard_L8s_v2', 'local-nvme-storage-size'), @('Standard_HC44rs', 'hpc-or-fpga-size'), @('Standard_GS2', 'l-series-replacement'))) {
            $vm = [pscustomobject]@{ vmId = '/s/rg/vm/x1'; name = 'x1'; sku = $case[0]; location = 'centralus'; resourceGroup = 'rg'
                os = 'Linux'; gen = 'V2'; tags = @{}; nicIds = @(); dataDiskCount = 0; osDiskManaged = $true; securityType = '' }
            $r = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } { param($v) Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -NicAcceleratedMap @{} -ManagedPlatformGroups @{} -SapSystemVms @{} -AvdSessionHosts @{} }
            @($r.blockers) | Should -Contain $case[1] -Because $case[0]
        }
    }

    It 'every code has words, a link to Microsoft''s guide, and applies to every series' {
        foreach ($code in 'hpc-or-fpga-size', 'local-nvme-storage-size', 'l-series-replacement') {
            $r = $script:reasons.blockers.$code
            $r | Should -Not -BeNullOrEmpty -Because $code
            $r.docs.url | Should -Match 'retired-sizes-modernization-guide|end-of-life-sizes-list'
            @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
        }
    }

    It 'THE SCOPE RULE: the words say scope, and invent no technical limit' {
        foreach ($code in 'hpc-or-fpga-size', 'local-nvme-storage-size', 'l-series-replacement') {
            $script:reasons.blockers.$code.meaning | Should -Match 'outside the scope of this tool' -Because $code
            $script:reasons.blockers.$code.title | Should -Match 'not in scope' -Because 'the title is what the targets page shows'
            foreach ($field in 'meaning', 'whatToDo') {
                $script:reasons.blockers.$code.$field | Should -Not -Match 'no D or E size has|cannot|impossible|does not survive' -Because "$code $field"
            }
        }
    }

    It 'REVIEW: no route is named that the linked page does not give - HPC and FPGA link the End of Life list' {
        $script:reasons.blockers.'hpc-or-fpga-size'.docs.url | Should -Match 'end-of-life-sizes-list'
        $script:reasons.blockers.'hpc-or-fpga-size'.whatToDo | Should -Not -Match 'HBv|HX|GPU'
    }

    It 'REVIEW: a Generation 1 G machine is offered nothing - no v5 size' {
        $vm = [pscustomobject]@{ vmId = '/s/rg/vm/g1'; name = 'g1'; location = 'centralus'; gen = 'V1'; os = 'Linux'; osVersion = '18.04-LTS'
            classification = 'Blocked'; blockers = @('gen1-requires-redeploy', 'l-series-replacement'); prepNeeded = @(); sourceSize = 'Standard_G2'
            sourceDiskArch = 'scsi-temp'; sourceTempDisks = 1; diskController = ''; dataDiskCount = 0; nicCount = 1; acceleratedNicCount = 0; platformManaged = $false }
        $cat = @{ Standard_G2 = [pscustomobject]@{ Name = 'Standard_G2'; Capabilities = @([pscustomobject]@{ Name = 'vCPUs'; Value = '4' }, [pscustomobject]@{ Name = 'MemoryGB'; Value = '56' }) } }
        $advice = InModuleScope VmMigrationFactory -Parameters @{ v = $vm; c = $cat } {
            param($v, $c) Get-VmfTargetAdvice -Assessment ([pscustomobject]@{ runId = 'x'; vms = @($v) }) -CatalogByLocation @{ centralus = $c }
        }
        $opts = @($advice.machines[0].options)
        @($opts | Where-Object { $_.supported }).Count | Should -Be 0
        @($opts.option) | Should -Be @('v5', 'v6', 'v7')
        @((@($opts | Where-Object { $_.option -eq 'v5' })[0]).notSupported) | Should -Contain 'l-series-replacement'
    }
}