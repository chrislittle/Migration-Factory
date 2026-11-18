#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISK-3: every data disk must come back with the right LUN and cache
# settings, because they can differ per disk.
#
# Verified state before this work: capture records lun/caching per disk and
# the recreate replays both - but NOTHING ever checked the result. A disk
# that came back on the wrong LUN, or lost its cache mode, would leave a
# running machine that looks healthy and behaves differently. Applications
# and fstab/mount tooling address disks BY LUN, so a shuffle is silent damage.
#
# Measured from the real centralus catalog while scoping this:
#   - two v5 sizes lose data-disk capacity on the default v6 transform
#     (E8-4ds_v5 and E8-4s_v5: 32 -> 24), so the same gate NIC-1 needed
#     applies to disk count.
#   - only 2 of 295 v6 sizes report CachedDiskBytes, i.e. host caching
#     hardware is effectively gone on v6. Azure still ACCEPTS the caching
#     setting (the lab has migrated ReadOnly-cached disks all day), so this
#     is an operator-visible performance change, not a blocker.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:Dd {
        param([string]$Name, [int]$Lun, [string]$Caching = 'None', [string]$Id = '')
        [pscustomobject]@{
            name = $Name; lun = $Lun; caching = $Caching
            managedDiskId = $(if ($Id) { $Id } else { "/subscriptions/s/disks/$Name" })
            sizeGB = 8
        }
    }
    function Global:DiskSku {
        param([string]$Name, $MaxDataDisks, [switch]$HostCache)
        $caps = [System.Collections.Generic.List[object]]::new()
        if ($null -ne $MaxDataDisks) { $caps.Add([pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = "$MaxDataDisks" }) }
        if ($HostCache) { $caps.Add([pscustomobject]@{ Name = 'CachedDiskBytes'; Value = '53687091200' }) }
        [pscustomobject]@{ Name = $Name; ResourceType = 'virtualMachines'; Capabilities = @($caps) }
    }
    # a size carrying BOTH caps, for the combined-gate test
    function Global:NicSkuForDisk {
        param([string]$Name, [int]$MaxNics, [int]$MaxDataDisks)
        [pscustomobject]@{
            Name = $Name; ResourceType = 'virtualMachines'
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxNetworkInterfaces'; Value = "$MaxNics" },
                [pscustomobject]@{ Name = 'MaxDataDiskCount'; Value = "$MaxDataDisks" }
            )
        }
    }
}
AfterAll { Remove-Item 'function:\Dd', 'function:\DiskSku', 'function:\NicSkuForDisk' -ErrorAction SilentlyContinue }

Describe 'DISK-3: every data disk must come back on its own LUN' {
    It 'passes when every disk returns on the same LUN with the same cache mode' {
        InModuleScope VmMigrationFactory {
            $disks = @((Global:Dd 'data0' 0 'None'), (Global:Dd 'data1' 3 'ReadOnly'), (Global:Dd 'data2' 7 'ReadWrite'))
            (Test-VmfDataDiskFidelity -Captured $disks -Live $disks).Ok | Should -BeTrue
        }
    }

    It 'fails when a disk comes back on a DIFFERENT LUN' {
        # The real damage case: LUNs 0,3,7 re-assigned as 0,1,2 leaves every
        # mount point and application binding pointing at the wrong disk.
        InModuleScope VmMigrationFactory {
            $was = @((Global:Dd 'data0' 0), (Global:Dd 'data1' 3), (Global:Dd 'data2' 7))
            $now = @((Global:Dd 'data0' 0), (Global:Dd 'data1' 1), (Global:Dd 'data2' 2))
            $r = Test-VmfDataDiskFidelity -Captured $was -Live $now
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match 'data1'
            $r.Detail | Should -Match '3'
        }
    }

    It 'fails when a disk lost its cache mode' {
        InModuleScope VmMigrationFactory {
            $was = @((Global:Dd 'data0' 0 'ReadOnly'))
            $now = @((Global:Dd 'data0' 0 'None'))
            $r = Test-VmfDataDiskFidelity -Captured $was -Live $now
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match '(?i)caching|cache'
            $r.Detail | Should -Match 'ReadOnly'
        }
    }

    It 'fails when a disk did not come back at all' {
        InModuleScope VmMigrationFactory {
            $was = @((Global:Dd 'data0' 0), (Global:Dd 'data1' 3))
            $now = @((Global:Dd 'data0' 0))
            $r = Test-VmfDataDiskFidelity -Captured $was -Live $now
            $r.Ok | Should -BeFalse
            $r.Detail | Should -Match '(?i)2'
            $r.Detail | Should -Match '(?i)1'
        }
    }

    It 'matches disks by identity, not by array position' {
        # ARM does not promise array order; the LUN is the contract.
        InModuleScope VmMigrationFactory {
            $was = @((Global:Dd 'data0' 0 'ReadOnly'), (Global:Dd 'data1' 3 'None'))
            $now = @((Global:Dd 'data1' 3 'None'), (Global:Dd 'data0' 0 'ReadOnly'))
            (Test-VmfDataDiskFidelity -Captured $was -Live $now).Ok | Should -BeTrue
        }
    }

    It 'a machine with no data disks is fine' {
        InModuleScope VmMigrationFactory {
            (Test-VmfDataDiskFidelity -Captured @() -Live @()).Ok | Should -BeTrue
        }
    }
}

Describe 'DISK-3: the target size must be able to hold the disks' {
    It 'reads MaxDataDiskCount, and reports unknown rather than guessing' {
        InModuleScope VmMigrationFactory {
            Get-VmfSkuMaxDataDisks -SkuEntry (Global:DiskSku 'Standard_D2s_v6' 8) | Should -Be 8
            Get-VmfSkuMaxDataDisks -SkuEntry (Global:DiskSku 'Standard_D2s_v6' $null) | Should -BeNullOrEmpty
            Get-VmfSkuMaxDataDisks -SkuEntry $null | Should -BeNullOrEmpty
        }
    }

    It 'refuses a named size that cannot hold the data disks, and takes one that can' {
        # E8-4ds_v5 holds 32 data disks; E8-4ds_v6 holds 24. Measured, real.
        # SIZEMAP-REMOVE-1: a named size (a chosen one) has no alternates.
        InModuleScope VmMigrationFactory {
            $catalog = @{
                'Standard_E8-4ds_v6' = (Global:DiskSku 'Standard_E8-4ds_v6' 24)
                'Standard_E16ds_v6'  = (Global:DiskSku 'Standard_E16ds_v6' 32)
            }
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4ds_v5' -Size 'Standard_E8-4ds_v6' -CatalogBySize $catalog -RequiredDataDisks 30
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'too-few-data-disks'
            (Get-VmfTargetSize -SourceSize 'Standard_E8-4ds_v5' -Size 'Standard_E16ds_v6' -CatalogBySize $catalog -RequiredDataDisks 30).Target |
                Should -Be 'Standard_E16ds_v6'
        }
    }

    It 'refuses when nothing holds them, naming both numbers' {
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_E8-4ds_v6' = (Global:DiskSku 'Standard_E8-4ds_v6' 24) }
            $r = Get-VmfTargetSize -SourceSize 'Standard_E8-4ds_v5' -CatalogBySize $catalog -RequiredDataDisks 30
            $r.Target | Should -BeNullOrEmpty
            $r.Reason | Should -Match '30'
            $r.Reason | Should -Match '24'
            $r.Reason | Should -Match '(?i)data disk'
        }
    }

    It 'does not gate a machine whose disks fit, and never gates on zero disks' {
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_D2s_v6' = (Global:DiskSku 'Standard_D2s_v6' 8) }
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredDataDisks 4).Target |
                Should -Be 'Standard_D2s_v6'
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredDataDisks 0).Target |
                Should -Be 'Standard_D2s_v6'
        }
    }

    It 'the NIC gate and the disk gate both apply - whichever fails, fails' {
        InModuleScope VmMigrationFactory {
            $catalog = @{ 'Standard_D2s_v6' = (Global:NicSkuForDisk 'Standard_D2s_v6' 2 4) }
            $nicFail = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredNics 4 -RequiredDataDisks 2
            $nicFail.Target | Should -BeNullOrEmpty
            $diskFail = Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredNics 2 -RequiredDataDisks 9
            $diskFail.Target | Should -BeNullOrEmpty
            (Get-VmfTargetSize -SourceSize 'Standard_D2s_v4' -CatalogBySize $catalog -RequiredNics 2 -RequiredDataDisks 4).Target |
                Should -Be 'Standard_D2s_v6'
        }
    }
}

Describe 'DISK-3: host caching disappears on v6, and the operator is told' {
    It 'knows a size has no host cache hardware' {
        InModuleScope VmMigrationFactory {
            Test-VmfSkuHasHostCache -SkuEntry (Global:DiskSku 'Standard_D2ds_v4' 4 -HostCache) | Should -BeTrue
            Test-VmfSkuHasHostCache -SkuEntry (Global:DiskSku 'Standard_D2ds_v6' 8) | Should -BeFalse
        }
    }

    It 'warns when cached disks move to a size with no host cache - without blocking' {
        # Measured: only 2 of 295 v6 sizes report CachedDiskBytes. Azure still
        # accepts the setting, so this is a performance note, not a refusal.
        InModuleScope VmMigrationFactory {
            $disks = @((Global:Dd 'data0' 0 'ReadOnly'), (Global:Dd 'data1' 1 'None'))
            $note = Get-VmfHostCacheNote -DataDisks $disks -TargetSku (Global:DiskSku 'Standard_D2ds_v6' 8)
            $note | Should -Match 'data0'
            $note | Should -Not -Match 'data1'
            $note | Should -Match '(?i)host cach'
        }
    }

    It 'says nothing when no disk was cached, or the target still caches' {
        InModuleScope VmMigrationFactory {
            $uncached = @((Global:Dd 'data0' 0 'None'))
            Get-VmfHostCacheNote -DataDisks $uncached -TargetSku (Global:DiskSku 'Standard_D2ds_v6' 8) | Should -BeNullOrEmpty
            $cached = @((Global:Dd 'data0' 0 'ReadOnly'))
            Get-VmfHostCacheNote -DataDisks $cached -TargetSku (Global:DiskSku 'Standard_D2ds_v4' 4 -HostCache) | Should -BeNullOrEmpty
        }
    }
}
