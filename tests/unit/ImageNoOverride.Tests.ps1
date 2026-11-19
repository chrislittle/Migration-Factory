#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRIFT-12 (decided 2026-11-12): an image the product does not support
# blocks the machine, and nothing lets it through.
#
# IMAGE-1 had an operator override - a list of accepted images passed to the
# scan, recorded in the assessment's scope as acceptedImages. No page and no
# service call could pass it: the dashboard, the service and the engine
# operations never named it. So every reason that said "accept the image" told
# the operator to do something the product gives no way to do.
#
# The blocking stays exactly as it was: an unknown publisher, an unknown
# offer, an image on the list as unsupported (Azure Linux 4.0 in preview
# among them) and a custom or gallery image all keep the blocker
# image-not-supported. What goes is the override, and every word about it.
# The assessment format goes to version 16 (contract-first: its scope no
# longer declares acceptedImages).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:data = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data'
}

Describe 'DRIFT-12: no image override exists' {
    It '<Command> has no AcceptedImages parameter' -ForEach @(
        @{ Command = 'Get-VmfImageSupport' }, @{ Command = 'Get-VmfAssessmentRecord' }, @{ Command = 'Invoke-VmfAssessment' }
    ) {
        $cmd = InModuleScope VmMigrationFactory -Parameters @{ n = $Command } { param($n) Get-Command $n }
        $cmd | Should -Not -BeNullOrEmpty
        $cmd.Parameters.ContainsKey('AcceptedImages') | Should -BeFalse
    }

    It 'no code in src names an accepted image or the accepted-by-operator status' {
        $files = Get-ChildItem (Join-Path $script:repoRoot 'src') -Recurse -File -Include '*.ps1', '*.psm1', '*.js'
        $hits = @(foreach ($f in $files) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -match '(?i)acceptedImages|accepted-by-operator') { $f.FullName.Substring($script:repoRoot.Length) }
        })
        $hits -join ', ' | Should -BeNullOrEmpty
    }

    It 'a scan refuses the parameter instead of ignoring it' {
        { Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath (Join-Path $TestDrive 'scan') -AcceptedImages @('OpenLogic/CentOS/7_9-gen2') } |
            Should -Throw "*parameter cannot be found*AcceptedImages*"
    }
}

Describe 'DRIFT-12: the assessment format has no acceptedImages (version 16)' {
    BeforeAll {
        $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json
    }

    It 'the schema is version 16, and its scope does not declare acceptedImages' {
        $script:schema.properties.schemaVersion.const | Should -Be 17
        $script:schema.properties.scope.properties.PSObject.Properties.Name | Should -Not -Contain 'acceptedImages'
        $script:schema.properties.scope.additionalProperties | Should -BeFalse -Because 'so a scope with the old field is refused'
    }

    It 'the version is held in one place, and only 16 is read' {
        InModuleScope VmMigrationFactory {
            Get-VmfAssessmentSchemaVersion | Should -Be 17
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 15 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 18 }) } | Should -Throw '*understands up to 17*'
        }
    }

    It 'the sample is version 16 with no acceptedImages, and matches the schema' {
        $path = Join-Path $script:repoRoot 'schemas' 'samples' 'assessment.sample.json'
        $text = Get-Content $path -Raw
        ($text | ConvertFrom-Json).schemaVersion | Should -Be 17
        $text | Should -Not -Match 'acceptedImages'
        $text | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') | Should -BeTrue
    }

    It 'a scope with acceptedImages does not match the schema' {
        $doc = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'assessment.sample.json') -Raw | ConvertFrom-Json -AsHashtable
        $doc.scope.acceptedImages = @()
        ($doc | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'the migration note says what version 16 removed' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## assessment v15 -> v16 \(2026-11-12, DRIFT-12\)'
        $section = [regex]::Match($notes, '(?ms)^## assessment v15 -> v16.*?(?=^## |\z)').Value
        $section | Should -Match 'acceptedImages'
    }
}

Describe 'DRIFT-12: each image reason states the fact and the result' {
    It 'a custom image' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher '' -Offer '' -Sku '' -ImageId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/galleries/g/images/i/versions/1.0.0'
            $r.Supported | Should -BeFalse
            $r.Reason | Should -BeExactly 'This machine runs a custom image, so the product cannot check its support. The product does not move this machine.'
        }
    }

    It 'an unknown publisher' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'some-vendor-xyz' -Offer 'appliance' -Sku '1.0'
            $r.Supported | Should -BeFalse
            $r.Reason | Should -BeExactly "The product does not recognize the publisher 'some-vendor-xyz'. The product does not move this machine."
        }
    }

    It 'an unknown offer of a known publisher' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfImageSupport -Publisher 'microsoftazurelinux' -Offer 'azurelinux-4-test' -Sku '4'
            $r.Supported | Should -BeFalse
            $r.Reason | Should -BeExactly "The product does not recognize the offer 'azurelinux-4-test' of the publisher 'microsoftazurelinux'. The product does not move this machine."
        }
    }

    It 'an image on the list as unsupported: <Publisher>' -ForEach @(
        @{ Publisher = 'microsoftazurelinux'; Offer = 'azurelinux-4'; Words = 'Microsoft says that Azure Linux 4.0 is in preview, for evaluation and testing only, and not for production use. The product does not move this machine.' }
        @{ Publisher = 'OpenLogic'; Offer = 'CentOS'; Words = 'CentOS reached end of life, and no one releases fixes for it. The image still reports NVMe support. The product does not move this machine.' }
        @{ Publisher = 'center-for-internet-security-inc'; Offer = 'cis-ubuntu'; Words = 'This is a hardened image from a third party. Microsoft does not support its guest agent and drivers. The product does not move this machine.' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ pub = $Publisher; off = $Offer; w = $Words } {
            param($pub, $off, $w)
            $r = Get-VmfImageSupport -Publisher $pub -Offer $off -Sku 'x'
            $r.Supported | Should -BeFalse
            $r.Status | Should -Be 'unsupported'
            $r.Reason | Should -BeExactly $w
        }
    }

    It 'the finding image-not-supported says what is true, with no acceptance' {
        $reasons = Get-Content (Join-Path $script:data 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $reasons.blockers.'image-not-supported'.whatToDo | Should -BeExactly 'The product does not move this machine. The support matrix in the manual lists the images that the product moves.'
    }

    It 'the finding verify-custom-image-nvme-ready says what is true, with no acceptance' {
        $reasons = Get-Content (Join-Path $script:data 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $entry = @($reasons.PSObject.Properties.Value | ForEach-Object { $_.'verify-custom-image-nvme-ready' } | Where-Object { $_ })[0]
        $entry.whatToDo | Should -BeExactly 'The product does not move a machine that comes from a custom image. The support matrix in the manual lists the images that the product moves.'
    }

    It 'no shipped word tells an operator to accept an image' {
        $files = @(Get-ChildItem (Join-Path $script:repoRoot 'docs' 'manual') -Recurse -File -Filter '*.md') +
                 @(Get-ChildItem $script:data -File -Filter '*.json') +
                 @(Get-ChildItem (Join-Path $script:repoRoot 'src' 'dashboard') -Recurse -File -Include '*.js', '*.html')
        $hits = @(foreach ($f in $files) {
            $t = [System.IO.File]::ReadAllText($f.FullName)
            if ($t -match '(?i)accept (the|this) image|accept it explicitly|records your acceptance|accepted this image') { $f.Name }
        })
        $hits -join ', ' | Should -BeNullOrEmpty
    }
}

Describe 'DRIFT-12: a blocked machine stays blocked' {
    It '<Name> is Blocked with image-not-supported' -ForEach @(
        @{ Name = 'CentOS'; Pub = 'OpenLogic'; Offer = 'CentOS'; Sku = '7_9-gen2'; ImageId = '' }
        @{ Name = 'Azure Linux 4.0'; Pub = 'microsoftazurelinux'; Offer = 'azurelinux-4'; Sku = '4'; ImageId = '' }
        @{ Name = 'an unknown publisher'; Pub = 'some-vendor-xyz'; Offer = 'appliance'; Sku = '1.0'; ImageId = '' }
        @{ Name = 'a custom image'; Pub = ''; Offer = ''; Sku = ''; ImageId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/images/img1' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ pub = $Pub; off = $Offer; sku = $Sku; id = $ImageId } {
            param($pub, $off, $sku, $id)
            $row = [pscustomobject]@{
                id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; zones = @()
                sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
                imagePublisher = $pub; imageOffer = $off; imageSku = $sku; imageId = $id
                vmssId = ''; hibernationEnabled = $false; securityType = ''
                dataDiskCount = 0; nicCount = 1; availabilitySetId = ''; tags = $null
            }
            $r = Get-VmfAssessmentRecord -Vm $row
            $r.classification | Should -Be 'Blocked'
            @($r.blockers) | Should -Contain 'image-not-supported'
            (@($r.notes) -join ' ') | Should -Match 'The product does not move this machine\.'
        }
    }
}
