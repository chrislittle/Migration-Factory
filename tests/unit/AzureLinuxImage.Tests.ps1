#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRIFT-12 (upstream drift issue 918): Azure Linux 4 images.
#
# Microsoft's automatic guest patching page added the row publisher Microsoft,
# offer azurelinux-4, SKUs 4 and 4-arm64. Azure has no such publisher.
# MEASURED 2026-11-12 (az vm image list-skus and az vm image show, read only):
# publisher Microsoft is "not found" in centralus, eastus, westus2, westus3 and
# westeurope; the image is microsoftazurelinux:azurelinux-4, SKUs 4, 4-fips,
# 4-arm64 and 4-arm64-fips, version 4.0.2026110902, Generation 2,
# DiskControllerTypes "SCSI, NVMe". Microsoft's Azure Linux page agrees
# (learn.microsoft.com/azure/azure-linux/azure-linux-vm-vmss-overview, read
# 2026-11-12): "published to Azure Marketplace under the microsoftazurelinux
# publisher", and Azure Linux 4.0 "is now in preview and is strictly limited to
# evaluation and testing purposes. It's not suitable for production use."
# DRIFT-13 (issue 976, read 2026-11-20): that preview note is gone from the page,
# and the endorsed-distros page lists Azure Linux. The machine stays blocked,
# now with the reason that the guest scripts do not support Azure Linux 4.0.
#
# So the support list names the publisher Azure records, for the azurelinux-<n>
# offers only, as not supported with the reason, so the scan blocks it.
# The release reader reads the same entry: the target advice reads azurelinux 4,
# which the MANA table lists.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:matrixPath = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json'
}

Describe 'DRIFT-12: the support list names Azure Linux 4 as Azure records it' {
    BeforeAll {
        $script:doc = Get-Content $script:matrixPath -Raw | ConvertFrom-Json
        $script:al = @($script:doc.publishers | Where-Object { $_.publisher -eq 'microsoftazurelinux' })
    }

    It 'has one entry for publisher microsoftazurelinux, for the azurelinux-<n> offers only' {
        $script:al.Count | Should -Be 1
        $script:al[0].os | Should -Be 'Linux'
        $script:al[0].offerPattern | Should -Be '^azurelinux-(\d+)$'
    }

    It 'says it is not supported, because the guest scripts do not support Azure Linux 4.0 (DRIFT-13: no longer a preview)' {
        $script:al[0].support | Should -Be 'unsupported'
        $script:al[0].note | Should -Match 'do not support Azure Linux 4\.0'
        $script:al[0].note | Should -Match 'The product does not move this machine\.'
    }

    It 'names its source and the date it was read' {
        $script:al[0].source | Should -Be 'https://learn.microsoft.com/azure/azure-linux/azure-linux-vm-vmss-overview'
        $script:al[0].readUtc | Should -Be '2026-11-20'
    }

    It 'has no entry for the publisher Microsoft: Azure has none, and it would cover every Microsoft image' {
        @($script:doc.publishers | Where-Object { $_.publisher -eq 'Microsoft' }).Count | Should -Be 0
    }

    It 'the support list date moved with the change' {
        # IMAGE-SCRIPT-MATCH-1 moved it again, to 2026-11-14, and DRIFT-13 to 2026-11-20.
        $script:doc.updatedUtc | Should -Be '2026-11-20'
    }
}

Describe 'DRIFT-12: the scan judges an Azure Linux 4 machine by that entry' {
    It 'microsoftazurelinux azurelinux-4 <Sku> is not supported, and the reason names the guest scripts' -ForEach @(
        @{ Sku = '4' }, @{ Sku = '4-fips' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ sku = $Sku } {
            param($sku)
            $r = Get-VmfImageSupport -Publisher 'microsoftazurelinux' -Offer 'azurelinux-4' -Sku $sku
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unsupported'
            $r.Reason | Should -Match 'do not support Azure Linux 4\.0'
        }
    }

    It 'reads the publisher with any case, as Azure ignores it' {
        InModuleScope VmMigrationFactory {
            (Get-VmfImageSupport -Publisher 'MicrosoftAzureLinux' -Offer 'AzureLinux-4' -Sku '4').Status | Should -Be 'unsupported'
        }
    }

    It 'another offer of that publisher is not on the list, and the reason names the publisher and the offer' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'microsoftazurelinux' -Offer 'azurelinux-4-test' -Sku '4'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unknown-offer'
            $r.Reason | Should -Match 'microsoftazurelinux'
            $r.Reason | Should -Match 'azurelinux-4-test'
        }
    }

    It 'the publisher Microsoft with offer azurelinux-4 (the patching page spelling) is a publisher the product does not know' {
        InModuleScope VmMigrationFactory {
            (Get-VmfImageSupport -Publisher 'Microsoft' -Offer 'azurelinux-4' -Sku '4').Status | Should -Be 'unknown-publisher'
        }
    }

    It 'an entry with no offer pattern still covers every offer of its publisher (Canonical)' {
        # IMAGE-SCRIPT-MATCH-1 refused MicrosoftCBLMariner by offer, so it no
        # longer has an entry for all its offers.
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'Canonical' -Offer 'ubuntu-24_04-lts' -Sku 'server'
            $r.Supported | Should -BeTrue
            $r.Status | Should -Be 'endorsed'
        }
    }

    It 'the scan blocks the machine with image-not-supported, and its note names the guest scripts' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-al4'
                name = 'vm'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = 'microsoftazurelinux'; imageOffer = 'azurelinux-4'; imageSku = '4'; imageId = ''
                vmssId = ''; hibernationEnabled = $false; securityType = ''
                dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
            }
            $r = Get-VmfAssessmentRecord -Vm $row
            @($r.blockers) | Should -Contain 'image-not-supported'
            $r.imageSupport | Should -Be 'unsupported'
            (@($r.notes) -join ' ') | Should -Match 'do not support Azure Linux 4\.0'
        }
    }
}

Describe 'DRIFT-12: the release of an Azure Linux 4 image' {
    It '<Publisher>:<Offer>:<Sku> reads as <Expected>' -ForEach @(
        @{ Publisher = 'microsoftazurelinux'; Offer = 'azurelinux-4'; Sku = '4'; Expected = 'azurelinux 4' }
        @{ Publisher = 'microsoftazurelinux'; Offer = 'azurelinux-4'; Sku = '4-fips'; Expected = 'azurelinux 4' }
        @{ Publisher = 'MicrosoftAzureLinux'; Offer = 'AzureLinux-4'; Sku = '4'; Expected = 'azurelinux 4' }
        @{ Publisher = 'microsoftazurelinux'; Offer = 'azurelinux-4-test'; Sku = '4'; Expected = 'none' }
        @{ Publisher = 'Microsoft'; Offer = 'azurelinux-4'; Sku = '4'; Expected = 'none' }
        @{ Publisher = 'MicrosoftCBLMariner'; Offer = 'azure-linux-3'; Sku = 'azure-linux-3-gen2'; Expected = 'azurelinux 3' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ pub = $Publisher; off = $Offer; sku = $Sku; want = $Expected } {
            param($pub, $off, $sku, $want)
            $r = Get-VmfImageRelease -Publisher $pub -Offer $off -Sku $sku
            $got = if ($r) { "$($r.distroId) $($r.version)" } else { 'none' }
            $got | Should -Be $want
        }
    }

    It 'a stopped machine (no agent reading) on the image is Azure Linux 4 from its image, which the MANA table lists' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{ os = 'Linux'; runningOsName = ''; runningOsVersion = ''
                imagePublisher = 'microsoftazurelinux'; imageOffer = 'azurelinux-4'; osVersion = '4' }
            $r = Get-VmfLinuxRelease -Vm $vm
            $r.distroId | Should -Be 'azurelinux'
            $r.version | Should -Be '4'
            $r.source | Should -Be 'image'
            Get-VmfManaReleaseListing -Release $r | Should -Be 'listed'
        }
    }
}

Describe 'DRIFT-12: an Azure Linux 4 Arm64 machine is refused by its size, as every Arm64 machine is' {
    It 'Standard_D2pds_v6 (the size an Arm64 image needs) stops as an Arm64 machine' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTargetSize -SourceSize 'Standard_D2pds_v6' -TargetGeneration 'v7'
            $r.Target | Should -BeNullOrEmpty
            $r.Code | Should -Be 'processor-not-approved'
        }
    }
}
