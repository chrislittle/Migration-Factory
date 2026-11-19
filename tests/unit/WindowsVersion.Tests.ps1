#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# WINVER-1: the Windows version rule read "2012-R2-Datacenter" as 20122.
#
# It took EVERY digit in the image SKU, so the "R2" joined the year:
#   2012-R2-Datacenter  -> 20122   (read as newer than 2019 - not blocked)
#   2008-R2-SP1         -> 200821  (the same)
#   2022-datacenter-g2  -> 20222   (right answer, by luck)
# So a Windows Server 2012 R2 machine was never held back by the "Azure supports
# NVMe on Windows Server 2019 and later" rule. Found by GEN-V5-1's tests on
# 2026-09-26, while adding a second rule that reads the same number.
#
# The version is the first four-digit number in the SKU. Every SKU the rule
# read correctly before gives the same number now.

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function script:Row([string]$Sku) {
        [pscustomobject]@{
            id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/w'
            name = 'w'; resourceGroup = 'rg'; location = 'centralus'; zones = @(); sku = 'Standard_D2s_v3'; os = 'Windows'; gen = 'V2'
            diskController = 'SCSI'; imagePublisher = 'MicrosoftWindowsServer'; imageSku = $Sku; vmssId = ''
            hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; tags = $null; identityType = 'None'; identityPrincipalId = ''
        }
    }
}

Describe 'WINVER-1: the Windows version is read from the SKU correctly' {

    It '<Sku> is held back from NVMe: <Expected>' -ForEach @(
        @{ Sku = '2012-R2-Datacenter';                 Expected = $true }
        @{ Sku = '2012-r2-datacenter-gensecond';       Expected = $true }
        @{ Sku = '2008-R2-SP1';                        Expected = $true }
        @{ Sku = '2012-Datacenter';                    Expected = $true }
        @{ Sku = '2016-Datacenter';                    Expected = $true }
        @{ Sku = '2016-datacenter-gensecond';          Expected = $true }
        @{ Sku = '2019-Datacenter';                    Expected = $false }
        @{ Sku = '2019-datacenter-core-smalldisk-g2';  Expected = $false }
        @{ Sku = '2022-datacenter-g2';                 Expected = $false }
        @{ Sku = '2022-datacenter-azure-edition';      Expected = $false }
        @{ Sku = '2025-datacenter-g2';                 Expected = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ row = (Row $Sku); expected = $Expected } {
            $rec = Get-VmfAssessmentRecord -Vm $row
            (@($rec.blockers) -contains 'windows-version-below-2019') | Should -Be $expected
        }
    }

    It 'a SKU with no four-digit number is not given a version' {
        # Not held back by this rule, as before: an unreadable name is not a
        # version, and the image rules decide what happens to it.
        InModuleScope VmMigrationFactory -Parameters @{ row = (Row 'datacenter') } {
            @((Get-VmfAssessmentRecord -Vm $row).blockers) | Should -Not -Contain 'windows-version-below-2019'
        }
    }
}

# OSVER-1: the RUNNING version decides, not the image the machine was made from.
#
# Question, 2026-09-29: does Azure report the real OS after an in-place
# upgrade, which people do all the time? It does:
# the VM agent reports the running operating system (instanceView.osName),
# and the scan already reads it for the client-Windows check. The version rule
# read the image SKU only - so a machine upgraded in place from 2016 to 2019
# stayed held back from v6 and v7, and a SQL Server image (whose SKU names the
# SQL edition, not Windows) was never judged at all.
#
# The running name wins when the agent reported one. A machine that is
# deallocated, or has no agent, reports none, and the image decides as before.
# And Azure's own NVMe answer for the IMAGE (a 2016 image reports SCSI only)
# gives way to it the same way - as GEN1-IMAGE-1 does for generation.
# When the two disagree, the record says so.
Describe 'OSVER-1: the running Windows version decides' {
    BeforeAll {
        function script:RunRow([string]$Sku, [string]$OsName, [string]$Publisher = 'MicrosoftWindowsServer', [string]$Offer = 'WindowsServer') {
            $r = Row $Sku
            $r.imagePublisher = $Publisher
            $r | Add-Member -NotePropertyName imageOffer -NotePropertyValue $Offer -Force
            $r | Add-Member -NotePropertyName osName -NotePropertyValue $OsName -Force
            $r
        }
        function script:Judge($row, $Nvme = $null) { InModuleScope VmMigrationFactory -Parameters @{ row = $row; nvme = $Nvme } { param($row, $nvme) Get-VmfAssessmentRecord -Vm $row -ImageNvmeSupported $nvme } }
    }

    It 'THE DEFECT: a 2016 image upgraded in place to 2019 is not held back from NVMe' {
        $rec = Judge (RunRow '2016-Datacenter' 'Windows Server 2019 Datacenter')
        @($rec.blockers) | Should -Not -Contain 'windows-version-below-2019'
        @($rec.notes) -join ' ' | Should -Match 'runs Windows Server 2019.*image is Windows Server 2016'
    }

    It 'THE DEFECT, END TO END: with Azure''s real answer for a 2016 image (SCSI only), the upgraded machine is still not held back' {
        # Measured 2026-09-29: 2016-Datacenter and 2016-datacenter-gensecond
        # both report DiskControllerTypes SCSI. Without this, the version rule
        # opened v6 and the image rule closed it again.
        $rec = Judge (RunRow '2016-Datacenter' 'Windows Server 2019 Datacenter') $false
        @($rec.blockers) | Should -Not -Contain 'windows-version-below-2019'
        @($rec.blockers) | Should -Not -Contain 'image-cannot-boot-nvme'
        @($rec.notes) -join ' ' | Should -Match "image, Windows Server 2016, cannot use NVMe disks\. The machine now runs Windows Server 2019"
    }

    It 'the image''s NVMe answer still decides when the machine is not upgraded past it, or its versions are not known' {
        @((Judge (RunRow '2016-Datacenter' 'Windows Server 2016 Datacenter') $false).blockers) | Should -Contain 'image-cannot-boot-nvme'
        @((Judge (RunRow '2016-Datacenter' '') $false).blockers) | Should -Contain 'image-cannot-boot-nvme' -Because 'no running name: unknown is not a pass'
        @((Judge (RunRow '' 'Windows Server 2019 Datacenter' '' '') $false).blockers) | Should -Contain 'image-cannot-boot-nvme' -Because 'a custom image has no version of its own to be newer than'
        @((Judge (RunRow '2019-Datacenter' 'Windows Server 2019 Datacenter') $false).blockers) | Should -Contain 'image-cannot-boot-nvme' -Because 'the image is not older than what it runs'
        @((Judge (RunRow '2012-R2-Datacenter' 'Windows Server 2016 Datacenter') $false).blockers) | Should -Contain 'image-cannot-boot-nvme' -Because '2016 cannot use NVMe either'
    }

    It 'and the other way: a 2019 image running 2016 is held back' {
        @((Judge (RunRow '2019-Datacenter' 'Windows Server 2016 Datacenter')).blockers) | Should -Contain 'windows-version-below-2019'
    }

    It 'a machine that reports no running name is judged by its image, as before' {
        @((Judge (RunRow '2016-Datacenter' '')).blockers) | Should -Contain 'windows-version-below-2019'
        @((Judge (RunRow '2022-datacenter-g2' '')).blockers) | Should -Not -Contain 'windows-version-below-2019'
    }

    It 'the same version from both says nothing extra' {
        @((Judge (RunRow '2022-datacenter-g2' 'Windows Server 2022 Datacenter')).notes) -join ' ' | Should -Not -Match 'image is Windows Server'
    }

    It '2012 R2 running is held back from v5 too (the PowerShell rule); 2016 running is not' {
        @((Judge (RunRow '2016-Datacenter' 'Windows Server 2012 R2 Datacenter')).blockers) | Should -Contain 'windows-version-not-proven'
        @((Judge (RunRow '2012-R2-Datacenter' 'Windows Server 2016 Datacenter')).blockers) | Should -Not -Contain 'windows-version-not-proven'
    }

    It 'Azure Edition and 2025 names read correctly' {
        @((Judge (RunRow '2022-datacenter-azure-edition' 'Windows Server 2022 Datacenter: Azure Edition')).blockers) | Should -Not -Contain 'windows-version-below-2019'
        @((Judge (RunRow '2025-datacenter-g2' 'Windows Server 2025 Datacenter')).blockers) | Should -Not -Contain 'windows-version-below-2019'
    }

    It 'a SQL Server image is judged by the Windows it runs, or by the Windows its offer names' {
        @((Judge (RunRow 'enterprise' 'Windows Server 2016 Datacenter' 'MicrosoftSQLServer' 'sql2017-ws2016')).blockers) | Should -Contain 'windows-version-below-2019'
        @((Judge (RunRow 'enterprise' '' 'MicrosoftSQLServer' 'sql2017-ws2016')).blockers) | Should -Contain 'windows-version-below-2019'
        @((Judge (RunRow 'enterprise' '' 'MicrosoftSQLServer' 'sql2022-ws2022')).blockers) | Should -Not -Contain 'windows-version-below-2019'
    }

    It 'a custom image is judged by the Windows it runs' {
        @((Judge (RunRow '' 'Windows Server 2016 Datacenter' '' '')).blockers) | Should -Contain 'windows-version-below-2019'
        @((Judge (RunRow '' 'Windows Server 2019 Datacenter' '' '')).blockers) | Should -Not -Contain 'windows-version-below-2019'
    }

    It 'a running name that is not Windows Server gives no version' {
        # A client name is excluded by its own rule; an unreadable name is not a year.
        InModuleScope VmMigrationFactory {
            (Get-VmfWindowsServerYear -OsName 'Windows 10 Enterprise' -ImagePublisher '' -ImageOffer '' -ImageSku '').Year | Should -BeNullOrEmpty
            (Get-VmfWindowsServerYear -OsName 'Windows Server Datacenter' -ImagePublisher '' -ImageOffer '' -ImageSku '').Year | Should -BeNullOrEmpty
        }
    }
}
