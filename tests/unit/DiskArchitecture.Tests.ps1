#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'Get-VmfDiskArchitecture' {

    Context 'API value authoritative (MaxResourceVolumeMB > 0 => scsi-temp)' {
        It 'classifies <Size> as scsi-temp when API reports a resource disk' -TestCases @(
            @{ Size = 'Standard_E8bds_v5'; Mb = 307200 }
            @{ Size = 'Standard_D2s_v3';   Mb = 16384 }   # predates 'd' naming entirely
            @{ Size = 'Standard_B2ms';     Mb = 16384 }   # no _vN suffix at all
            @{ Size = 'Standard_E4s_v3';   Mb = 32768 }
        ) {
            Get-VmfDiskArchitecture -SizeName $Size -MaxResourceVolumeMB $Mb | Should -Be 'scsi-temp'
        }
    }

    Context 'API zero, name has d => nvme-temp (v6/v7 raw local disk)' {
        It 'classifies <Size> as nvme-temp' -TestCases @(
            @{ Size = 'Standard_E8ads_v7' }
            @{ Size = 'Standard_E8bds_v6' }
            @{ Size = 'Standard_D16ads_v7' }
            @{ Size = 'Standard_D2ds_v6' }
        ) {
            Get-VmfDiskArchitecture -SizeName $Size -MaxResourceVolumeMB 0 | Should -Be 'nvme-temp'
        }
    }

    Context 'API zero, no d => diskless' {
        It 'classifies <Size> as diskless' -TestCases @(
            @{ Size = 'Standard_E8as_v7' }
            @{ Size = 'Standard_D8s_v6' }
            @{ Size = 'Standard_E8s_v5' }
        ) {
            Get-VmfDiskArchitecture -SizeName $Size -MaxResourceVolumeMB 0 | Should -Be 'diskless'
        }
    }

    Context 'Unknown SKU (null API value) falls back to name only' {
        It 'nvme-temp for d-sizes' {
            Get-VmfDiskArchitecture -SizeName 'Standard_E8ads_v7' -MaxResourceVolumeMB $null | Should -Be 'nvme-temp'
        }
        It 'diskless for non-d sizes (name alone cannot prove scsi-temp)' {
            Get-VmfDiskArchitecture -SizeName 'Standard_E8as_v7' -MaxResourceVolumeMB $null | Should -Be 'diskless'
        }
    }

    Context 'Constrained-vCPU size names (e.g. E8-4ds_v5)' {
        It 'still detects the d flag' {
            Get-VmfDiskArchitecture -SizeName 'Standard_E8-4ds_v5' -MaxResourceVolumeMB 0 | Should -Be 'nvme-temp'
        }
    }
}
