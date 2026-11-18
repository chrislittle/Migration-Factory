#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# IMAGE-1: the tool supports only OS images that Microsoft supports and
# publishes.
#
# Measured from the real image API (api-version 2024-07-01) while scoping this,
# and it splits the requirement in two:
#
#   CAN it boot on NVMe?   Azure answers, per image version, via the
#                          DiskControllerTypes feature. Gen1 images report
#                          "SCSI"; Gen2 images report "SCSI, NVMe". That is a
#                          FACT, so the engine reads it rather than guessing.
#   IS it supported?       Azure does NOT answer this. OpenLogic CentOS 7.9 is
#                          end-of-life and cheerfully reports "SCSI, NVMe".
#                          Support is a curated judgement, so it lives as
#                          versioned DATA in data/supported-images.json.
#
# A machine may only migrate when both are satisfied. Nothing overrides the
# support answer (DRIFT-12, 2026-11-12: the override was reachable from
# no page or service call, so it is removed).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'IMAGE-1: the support matrix is data, not code' {
    It 'ships with the module and parses' {
        $path = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json'
        Test-Path $path | Should -BeTrue
        $doc = Get-Content $path -Raw | ConvertFrom-Json
        $doc.schemaVersion | Should -Be 1
        $doc.updatedUtc | Should -Not -BeNullOrEmpty -Because 'a support list without a date cannot be reviewed'
        @($doc.publishers).Count | Should -BeGreaterThan 5
    }

    It 'every entry says which OS it is for and how supported it is' {
        $doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json') -Raw | ConvertFrom-Json
        foreach ($p in @($doc.publishers)) {
            $p.publisher | Should -Not -BeNullOrEmpty
            $p.support | Should -BeIn @('microsoft-published', 'endorsed', 'unsupported')
            if ($p.support -eq 'unsupported') {
                $p.note | Should -Not -BeNullOrEmpty -Because 'refusing something requires saying why'
            }
        }
    }
}

Describe 'IMAGE-1: classifying the image a machine is running' {
    It 'accepts an image Microsoft publishes' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'MicrosoftWindowsServer' -Offer 'WindowsServer' -Sku '2022-datacenter-g2'
            $r.Supported | Should -BeTrue
            $r.Status | Should -Be 'microsoft-published'
        }
    }

    It 'accepts an endorsed Linux distribution' {
        InModuleScope VmMigrationFactory {
            (Get-VmfImageSupport -Publisher 'Canonical' -Offer '0001-com-ubuntu-server-jammy' -Sku '22_04-lts-gen2').Supported |
                Should -BeTrue
        }
    }

    It 'refuses a publisher the matrix marks unsupported, and says why' {
        # OpenLogic CentOS: end of life, yet its image still advertises NVMe.
        # This is exactly the case Azure's own signal cannot catch.
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'OpenLogic' -Offer 'CentOS' -Sku '7_9-gen2'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unsupported'
            $r.Reason | Should -Match '(?i)end of life'
        }
    }

    It 'refuses a publisher it has never heard of rather than assuming the best' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'some-vendor-xyz' -Offer 'appliance' -Sku '1.0'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unknown-publisher'
        }
    }

    It 'treats a machine built from a custom image as unverifiable, not as fine' {
        # No publisher means a managed image or gallery version: there is no
        # marketplace record to ask, so nothing can be confirmed about it.
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher '' -Offer '' -Sku '' -ImageId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/i/versions/1.0.0'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'custom-image'
            $r.Reason | Should -Match '(?i)custom'
        }
    }

}

Describe 'IMAGE-1: can the image actually boot on NVMe?' {
    It 'reads the controller types Azure reports for the image' {
        InModuleScope VmMigrationFactory {
            $features = @(
                [pscustomobject]@{ name = 'DiskControllerTypes'; value = 'SCSI, NVMe' }
                [pscustomobject]@{ name = 'IsAcceleratedNetworkSupported'; value = 'True' }
            )
            Test-VmfImageSupportsNvme -Features $features | Should -BeTrue
        }
    }

    It 'a Gen1 image reporting SCSI only cannot go to NVMe' {
        # Measured: WindowsServer 2016-Datacenter and 2019-Datacenter (Gen1)
        # both report DiskControllerTypes = SCSI.
        InModuleScope VmMigrationFactory {
            Test-VmfImageSupportsNvme -Features @([pscustomobject]@{ name = 'DiskControllerTypes'; value = 'SCSI' }) |
                Should -BeFalse
        }
    }

    It 'says UNKNOWN when Azure reported nothing, rather than guessing either way' {
        InModuleScope VmMigrationFactory {
            Test-VmfImageSupportsNvme -Features @() | Should -BeNullOrEmpty
            Test-VmfImageSupportsNvme -Features $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'IMAGE-1: the assessment refuses machines it cannot vouch for' {
    BeforeAll {
        function Global:ImgRow {
            param([string]$Pub, [string]$Sku = 'x', [string]$Offer = 'o', [string]$Os = 'Linux', [string]$ImageId = '')
            [pscustomobject]@{
                id = "/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm-$Pub"
                name = "vm"; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = $Os; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = $Pub; imageOffer = $Offer; imageSku = $Sku; imageId = $ImageId
                vmssId = ''; hibernationEnabled = $false; securityType = ''
                dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
            }
        }
    }
    AfterAll { Remove-Item 'function:\ImgRow' -ErrorAction SilentlyContinue }

    It 'a supported image is not blocked' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (Global:ImgRow 'Canonical' '22_04-lts-gen2')
            @($r.blockers) | Should -Not -Contain 'image-not-supported'
            $r.imageSupport | Should -Be 'endorsed'
        }
    }

    It 'an end-of-life image is BLOCKED, and the record says which' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (Global:ImgRow 'OpenLogic' '7_9-gen2')
            $r.classification | Should -Be 'Blocked'
            @($r.blockers) | Should -Contain 'image-not-supported'
            (@($r.notes) -join ' ') | Should -Match '(?i)end of life'
        }
    }

    It 'a custom image is BLOCKED' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (Global:ImgRow '' 'x' 'o' 'Linux' '/subscriptions/s/img/1')
            $r.classification | Should -Be 'Blocked'
            @($r.blockers) | Should -Contain 'image-not-supported'
            $r.imageSupport | Should -Be 'custom-image'
        }
    }

    It 'nothing lets an unsupported image through, and the other blockers still apply' {
        # DRIFT-12: the image override is removed (ImageNoOverride.Tests.ps1).
        InModuleScope VmMigrationFactory {
            $row = Global:ImgRow 'OpenLogic' '7_9-gen2'
            $row.gen = 'V1'
            $r = Get-VmfAssessmentRecord -Vm $row
            $r.classification | Should -Be 'Blocked'
            @($r.blockers) | Should -Contain 'image-not-supported'
            @($r.blockers) | Should -Contain 'gen1-requires-redeploy'
        }
    }

    # CLIENT-IMAGE-DATA-1 (2026-11-14): the support list said
    # MicrosoftWindowsDesktop is "microsoft-published" (supported) while the
    # scan excludes every machine of that publisher as a client operating
    # system. The scan's answer is the rule (scope ruling 2026-08-28),
    # so the list must say the same. Walk every Windows publisher the list
    # names, ask the scan, and fail on any disagreement.
    It 'CLIENT-IMAGE-DATA-1: the support list and the scan agree on every Windows publisher' {
        $doc = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'supported-images.json') -Raw | ConvertFrom-Json
        $windows = @($doc.publishers | Where-Object { $_.os -eq 'Windows' })
        $windows.Count | Should -BeGreaterThan 2
        $clientSeen = 0
        foreach ($entry in $windows) {
            $r = InModuleScope VmMigrationFactory -Parameters @{ pub = [string]$entry.publisher } {
                param($pub)
                Get-VmfAssessmentRecord -Vm (Global:ImgRow $pub 'sku1' 'offer1' 'Windows')
            }
            $excludedAsClient = ($r.classification -eq 'Excluded') -and ((@($r.notes) -join ' ') -match 'client operating system')
            if ($excludedAsClient) {
                $clientSeen++
                [string]$entry.support | Should -Be 'unsupported' -Because "the scan excludes every $($entry.publisher) machine as a client operating system, so the support list must not call it supported"
            }
            else {
                [string]$entry.support | Should -Not -Be 'unsupported' -Because "the scan does not exclude $($entry.publisher) as a client operating system"
            }
        }
        $clientSeen | Should -BeGreaterThan 0 -Because 'the walk must reach the client publisher, or it proves nothing'
    }

    It 'CLIENT-IMAGE-DATA-1: a client image gets its client reason only, not a second image reason' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAssessmentRecord -Vm (Global:ImgRow 'MicrosoftWindowsDesktop' 'win11-24h2-entn' 'windows-11' 'Windows')
            $r.classification | Should -Be 'Excluded'
            (@($r.notes) -join ' ') | Should -Match 'client operating system'
            @($r.blockers) | Should -Not -Contain 'image-not-supported'
        }
    }
}

Describe 'IMAGE-1: the image facts reach the record' {
    It 'the live image lookup goes through the azureops boundary' {
        # GEN1-IMAGE-1 moved the lookup out of the assessment into
        # Get-VmfMachineImageNvme, which asks for more than one image. The
        # rule is unchanged: every image read is an azureops call, retried.
        $src = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1')
        $src | Should -Match 'Get-VmfMachineImageNvme -Vm \$vm'
        # Both halves of the answer reach the record: the verdict, and the
        # note that says which image gave it (a mutation dropped the note and
        # every other test still passed).
        $src | Should -Match '-ImageNvmeSupported \$imageNvme\.Nvme'
        $src | Should -Match '-ImageNvmeNote \$imageNvme\.Note'
        $img = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'ImageSupport.ps1')
        ([regex]::Matches($img, 'Invoke-VmfAzOperation -Name "image')).Count | Should -Be 3
        $img | Should -Not -Match 'Invoke-AzRestMethod'
    }

    It 'a definite NO from Azure blocks, and silence does not' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
                name = 'vm'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = 'Canonical'; imageOffer = 'o'; imageSku = '22_04-lts-gen2'; imageId = ''
                vmssId = ''; hibernationEnabled = $false; securityType = ''
                dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
            }
            @((Get-VmfAssessmentRecord -Vm $row -ImageNvmeSupported $false).blockers) |
                Should -Contain 'image-cannot-boot-nvme'
            @((Get-VmfAssessmentRecord -Vm $row -ImageNvmeSupported $null).blockers) |
                Should -Not -Contain 'image-cannot-boot-nvme'
            @((Get-VmfAssessmentRecord -Vm $row -ImageNvmeSupported $true).blockers) |
                Should -Not -Contain 'image-cannot-boot-nvme'
        }
    }
}

# GEN1-IMAGE-1, lab drill 2026-09-25: two Windows machines were taken from Gen1
# to Gen2 by Microsoft's own route (MBR2GPT, then the Trusted Launch upgrade),
# and the scan still refused them with image-cannot-boot-nvme. It asked Azure
# about the image each machine was BUILT from - 2022-datacenter and
# 2019-datacenter, the Gen1 images, which report SCSI only. That answer is
# about the Gen1 image, not about the machine the upgrade made.
#
# Measured the same day (api-version 2024-07-01, centralus): Azure publishes
# the Gen1 and Gen2 editions of one build with the SAME version number -
# 2022-datacenter and 2022-datacenter-g2 are both 20348.5622.260906, V1 and
# V2, and only the V2 one reports NVMe. The Gen2 names are not regular:
# 2022-datacenter-g2, 2019-datacenter-gensecond, and 18.04-LTS pairs with
# 18_04-lts-gen2. So a name only nominates a candidate; the version number
# and the architecture confirm it, and anything unconfirmed is UNKNOWN.
Describe 'GEN1-IMAGE-1: a machine upgraded to Gen2 is judged as it is now' {
    BeforeAll {
        function Global:ImgFacts {
            param([string]$Sku, [string]$Gen, [object]$Nvme, [string]$Version = '20348.5622.260906', [string]$Arch = 'x64')
            [pscustomobject]@{ sku = $Sku; version = $Version; hyperVGeneration = $Gen; architecture = $Arch; nvme = $Nvme }
        }
        # The real listing of the WindowsServer offer, cut to the names that
        # could be mistaken for a Gen2 edition of 2019-datacenter or 2022-datacenter.
        $script:windowsSkus = @('2019-Datacenter', '2019-Datacenter-Core', '2019-datacenter-core-g2',
            '2019-datacenter-gensecond', '2019-datacenter-gs', '2019-datacenter-gs-g2',
            '2019-datacenter-smalldisk-g2', '2022-datacenter', '2022-datacenter-azure-edition',
            '2022-datacenter-core-g2', '2022-datacenter-g2', '2022-datacenter-smalldisk-g2')
    }
    AfterAll { Remove-Item 'function:\ImgFacts' -ErrorAction SilentlyContinue }

    It 'finds the Gen2 edition by each of the three names Microsoft uses, and nothing near them' {
        InModuleScope VmMigrationFactory -Parameters @{ skus = $script:windowsSkus } {
            param($skus)
            @(Get-VmfGen2ImageSkuCandidates -Sku '2022-datacenter' -SkuNames $skus) | Should -Be @('2022-datacenter-g2')
            @(Get-VmfGen2ImageSkuCandidates -Sku '2019-Datacenter' -SkuNames $skus) | Should -Be @('2019-datacenter-gensecond')
            @(Get-VmfGen2ImageSkuCandidates -Sku '18.04-LTS' -SkuNames @('18.04-LTS', '18_04-lts-arm64', '18_04-lts-gen2')) |
                Should -Be @('18_04-lts-gen2')
            @(Get-VmfGen2ImageSkuCandidates -Sku '22_04-lts' -SkuNames @('22_04-lts', '22_04-lts-arm64', '22_04-lts-gen2')) |
                Should -Be @('22_04-lts-gen2')
        }
    }

    It 'finds nothing when there is nothing to find' {
        InModuleScope VmMigrationFactory -Parameters @{ skus = $script:windowsSkus } {
            param($skus)
            @(Get-VmfGen2ImageSkuCandidates -Sku '2016-Datacenter' -SkuNames $skus).Count | Should -Be 0
            @(Get-VmfGen2ImageSkuCandidates -Sku '2022-datacenter' -SkuNames $null).Count | Should -Be 0
            @(Get-VmfGen2ImageSkuCandidates -Sku '' -SkuNames $skus).Count | Should -Be 0
        }
    }

    It 'the upgraded Windows machine is judged by the Gen2 edition of its build: YES' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' `
                -Image (Global:ImgFacts '2022-datacenter' 'V1' $false) `
                -Gen2Editions @(Global:ImgFacts '2022-datacenter-g2' 'V2' $true)
            $r.Nvme | Should -BeTrue
            $r.Note | Should -Match '2022-datacenter-g2'
            $r.Note | Should -Match '20348\.5622\.260906'
        }
    }

    It 'a Gen2 edition of a DIFFERENT build confirms nothing: UNKNOWN, not yes' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' `
                -Image (Global:ImgFacts '2022-datacenter' 'V1' $false) `
                -Gen2Editions @(Global:ImgFacts '2022-datacenter-g2' 'V2' $true -Version '20348.5500.260801')
            $r.Nvme | Should -BeNullOrEmpty
            $r.Note | Should -Match '(?i)cannot tell'
        }
    }

    It 'a Gen2 edition for another processor, or one that is not Gen2, confirms nothing' {
        InModuleScope VmMigrationFactory {
            $img = Global:ImgFacts '22_04-lts' 'V1' $false
            (Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' -Image $img `
                -Gen2Editions @(Global:ImgFacts '22_04-lts-gen2' 'V2' $true -Arch 'Arm64')).Nvme | Should -BeNullOrEmpty
            (Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' -Image $img `
                -Gen2Editions @(Global:ImgFacts '22_04-lts-gen2' 'V1' $true)).Nvme | Should -BeNullOrEmpty
        }
    }

    It 'no Gen2 edition at all: UNKNOWN, and the record says why' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' -Image (Global:ImgFacts '2016-Datacenter' 'V1' $false) -Gen2Editions @()
            $r.Nvme | Should -BeNullOrEmpty
            $r.Note | Should -Match '(?i)Generation 1 image'
        }
    }

    It 'the Gen2 edition of the same build says NO: that NO stands' {
        InModuleScope VmMigrationFactory {
            (Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' -Image (Global:ImgFacts 'x' 'V1' $false) `
                -Gen2Editions @(Global:ImgFacts 'x-g2' 'V2' $false)).Nvme | Should -BeFalse
        }
    }

    It 'a machine that is STILL Gen1 keeps the Gen1 answer, whatever a Gen2 edition says' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfImageNvmeAnswer -VmGeneration 'V1' -Image (Global:ImgFacts '2022-datacenter' 'V1' $false) `
                -Gen2Editions @(Global:ImgFacts '2022-datacenter-g2' 'V2' $true)
            $r.Nvme | Should -BeFalse
            $r.Note | Should -BeNullOrEmpty
        }
    }

    It 'a real NO from a Gen2 image is never set aside' {
        # Only a Gen1 IMAGE under a Gen2 MACHINE is the mismatch this fixes.
        InModuleScope VmMigrationFactory {
            (Resolve-VmfImageNvmeAnswer -VmGeneration 'V2' -Image (Global:ImgFacts 'x-g2' 'V2' $false) `
                -Gen2Editions @(Global:ImgFacts 'x-g3' 'V2' $true)).Nvme | Should -BeFalse
        }
    }

    It 'a Gen1 image that already says YES needs no second question' {
        # Measured: Canonical 22_04-lts is V1 and reports "SCSI, NVMe".
        InModuleScope VmMigrationFactory {
            Test-VmfImageNeedsGen2Edition -VmGeneration 'V2' -Image (Global:ImgFacts '22_04-lts' 'V1' $true) | Should -BeFalse
            Test-VmfImageNeedsGen2Edition -VmGeneration 'V2' -Image (Global:ImgFacts '2022-datacenter' 'V1' $false) | Should -BeTrue
            Test-VmfImageNeedsGen2Edition -VmGeneration 'V2' -Image $null | Should -BeFalse
        }
    }

    It 'RUN: the lookup asks Azure about the Gen2 edition only when the machine needs it' {
        InModuleScope VmMigrationFactory -Parameters @{ skus = $script:windowsSkus } {
            param($skus)
            Mock Get-VmfImageSkuNames { $skus }
            Mock Get-VmfImageVersionFacts {
                switch ($Sku) {
                    '2022-datacenter'    { Global:ImgFacts '2022-datacenter' 'V1' $false }
                    '2022-datacenter-g2' { Global:ImgFacts '2022-datacenter-g2' 'V2' $true }
                    default { $null }
                }
            }
            $vm = [pscustomobject]@{ location = 'centralus'; gen = 'V2'
                imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter' }
            $r = Get-VmfMachineImageNvme -Vm $vm
            $r.Nvme | Should -BeTrue
            Should -Invoke Get-VmfImageVersionFacts -Times 1 -Exactly -ParameterFilter { $Sku -eq '2022-datacenter-g2' }

            $vm.gen = 'V1'
            (Get-VmfMachineImageNvme -Vm $vm).Nvme | Should -BeFalse
            Should -Invoke Get-VmfImageSkuNames -Times 1 -Exactly -Because 'a machine that is still Gen1 needs no second question'
        }
    }

    It 'RUN: a machine with no marketplace image asks Azure nothing' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfImageVersionFacts { throw 'must not be called' }
            $r = Get-VmfMachineImageNvme -Vm ([pscustomobject]@{ location = 'centralus'; gen = 'V2'; imagePublisher = ''; imageOffer = ''; imageSku = '' })
            $r.Nvme | Should -BeNullOrEmpty
        }
    }

    It 'RUN: the assessment record carries the note that says which image answered' {
        InModuleScope VmMigrationFactory {
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
                name = 'vm'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = 'MicrosoftWindowsServer'; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter'; imageId = ''
                vmssId = ''; hibernationEnabled = $false; securityType = 'TrustedLaunch'
                dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
            }
            $r = Get-VmfAssessmentRecord -Vm $row -ImageNvmeSupported $true -ImageNvmeNote 'the note that says which image answered'
            @($r.blockers) | Should -Not -Contain 'image-cannot-boot-nvme'
            @($r.notes) | Should -Contain 'the note that says which image answered'
        }
    }
}
