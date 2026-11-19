#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# SCAN-SCOPE-NULL-1: a scan's scope lists hold no null.
#
# `@($x)` of a value that is not there is not an empty list: it is a list with
# one null in it. The scan wrote its scope that way, so a scan with no resource
# group filter saved "resourceGroups": [null], and a scan of a management group saved
# "subscriptions": [null] - in assessment.json and in run.json. Both schemas
# allow only text in those lists. New-VmfProject wrote its scope the same way.
#
# These tests run a WHOLE scan and check the SAVED documents against their
# schemas, because the contract test checks a sample written by hand, and the
# scan tests read the machine records only - which is why nobody saw it.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:assessSchema = Join-Path $script:repoRoot 'schemas' 'assessment.schema.json'
    $script:manifestSchema = Join-Path $script:repoRoot 'schemas' 'run-manifest.schema.json'
    $script:projectSchema = Join-Path $script:repoRoot 'schemas' 'project.schema.json'

    # One whole scan of one machine, every read mocked. Gives back the saved
    # assessment.json and run.json as text.
    function Global:SsnScan([hashtable]$Scope) {
        $row = [pscustomobject]@{
            id = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"; name = 'vm1'
            resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2s_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'; osName = 'ubuntu'; osVersionRunning = '22.04'
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $null; identityType = 'None'; identityPrincipalId = ''; adeOsDiskEnabled = ''; licenseType = ''
            osDiskManagedId = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os"
        }
        $params = @{ row = $row; scope = $Scope }
        InModuleScope VmMigrationFactory -Parameters $params {
            param($row, $scope)
            Mock Get-VmfFleetInventory { , @($row) }
            Mock Get-VmfSkuCatalog { , @() }
            Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
            # CLUSTER-DETECT-1: one read of the interfaces gives accelerated networking and the cluster hints.
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfDiskShareMap { @{ Disks = @{}; Types = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfResourceGroupOwners { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ssn-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                $call = @{ Scope = $scope; OutPath = $out }
                Invoke-VmfAssessment @call | Out-Null
                [pscustomobject]@{
                    Assessment = Get-Content (Join-Path $out 'assessment.json') -Raw
                    Manifest   = Get-Content (Join-Path $out 'run.json') -Raw
                }
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
}

AfterAll {
    Remove-Item function:SsnScan -ErrorAction SilentlyContinue
}

Describe 'SCAN-SCOPE-NULL-1: a scan saves its scope lists with no null in them' {
    It 'a scan with no resource group filter saves an assessment that matches its schema, with the list empty and no acceptedImages' {
        $saved = SsnScan -Scope @{ Subscriptions = @($script:subId) }
        $saved.Assessment | Test-Json -SchemaFile $script:assessSchema | Should -BeTrue
        $a = $saved.Assessment | ConvertFrom-Json -Depth 20 -AsHashtable
        $a.scope.ContainsKey('resourceGroups') | Should -BeTrue -Because 'the list is always there, empty when there is no filter'
        $a.scope.ContainsKey('acceptedImages') | Should -BeFalse -Because 'DRIFT-12 removed the image override (assessment v16)'
        @($a.scope.resourceGroups).Count | Should -Be 0
        $saved.Assessment | Should -Not -Match '\[\s*null\s*\]'
        @($a.scope.subscriptions) | Should -Be @($script:subId)
    }

    It 'the run manifest of that scan matches its schema, with no null in its resource group list' {
        $saved = SsnScan -Scope @{ Subscriptions = @($script:subId) }
        $saved.Manifest | Test-Json -SchemaFile $script:manifestSchema | Should -BeTrue
        $m = $saved.Manifest | ConvertFrom-Json -Depth 20 -AsHashtable
        @($m.scope.resourceGroups).Count | Should -Be 0
        $saved.Manifest | Should -Not -Match '\[\s*null\s*\]'
    }

    It 'a scan of a management group, with no subscription named, saves an empty subscription list in both documents' {
        $saved = SsnScan -Scope @{ ManagementGroup = 'mg-contoso' }
        $saved.Assessment | Test-Json -SchemaFile $script:assessSchema | Should -BeTrue
        $saved.Manifest | Test-Json -SchemaFile $script:manifestSchema | Should -BeTrue
        $a = $saved.Assessment | ConvertFrom-Json -Depth 20 -AsHashtable
        $m = $saved.Manifest | ConvertFrom-Json -Depth 20 -AsHashtable
        @($a.scope.subscriptions).Count | Should -Be 0
        @($m.scope.subscriptions).Count | Should -Be 0
        $a.scope.managementGroup | Should -Be 'mg-contoso'
    }

    It 'a scan WITH a filter keeps every value it was given, in order' {
        $saved = SsnScan -Scope @{ Subscriptions = @($script:subId); ResourceGroups = @('rg-app', 'rg-web') }
        $saved.Assessment | Test-Json -SchemaFile $script:assessSchema | Should -BeTrue
        $a = $saved.Assessment | ConvertFrom-Json -Depth 20 -AsHashtable
        @($a.scope.resourceGroups) | Should -Be @('rg-app', 'rg-web')
        $m = $saved.Manifest | ConvertFrom-Json -Depth 20 -AsHashtable
        @($m.scope.resourceGroups) | Should -Be @('rg-app', 'rg-web')
        @($m.scope.subscriptions) | Should -Be @($script:subId)
    }

    It 'a filter of ONE resource group is still saved as a list' {
        $saved = SsnScan -Scope @{ Subscriptions = @($script:subId); ResourceGroups = 'rg-app' }
        $saved.Assessment | Test-Json -SchemaFile $script:assessSchema | Should -BeTrue
        $saved.Assessment | Should -Match '"resourceGroups":\s*\[\s*"rg-app"\s*\]'
        $saved.Manifest | Should -Match '"resourceGroups":\s*\[\s*"rg-app"\s*\]'
    }
}

Describe 'SCAN-SCOPE-NULL-1: a project saves its scope lists with no null in them' {
    BeforeEach {
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ssnp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        $script:who = @{ Identity = 'operator@example.com' }
    }
    AfterEach { if ($script:store -and (Test-Path $script:store)) { Remove-Item $script:store -Recurse -Force } }

    It 'a scope with no resource group and no subscription (as the service gives it from a request) saves a project that matches its schema' {
        $scope = '{"subscriptions":null,"managementGroup":"mg-contoso","resourceGroups":null}' | ConvertFrom-Json
        New-VmfProject -StorePath $script:store -ProjectId 'ssn-one' -Name 'One' -Scope $scope -OnBehalfOf $script:who | Out-Null
        $text = Get-Content (Join-Path $script:store 'ssn-one' 'project.json') -Raw
        $text | Test-Json -SchemaFile $script:projectSchema | Should -BeTrue
        $text | Should -Not -Match '\[\s*null\s*\]'
        $doc = $text | ConvertFrom-Json -Depth 10 -AsHashtable
        @($doc.scope.subscriptions).Count | Should -Be 0
        @($doc.scope.resourceGroups).Count | Should -Be 0
    }

    It 'a project scope WITH values keeps every one' {
        New-VmfProject -StorePath $script:store -ProjectId 'ssn-two' -Name 'Two' -OnBehalfOf $script:who `
            -Scope @{ Subscriptions = @($script:subId); ResourceGroups = @('rg-app', 'rg-web') } | Out-Null
        $text = Get-Content (Join-Path $script:store 'ssn-two' 'project.json') -Raw
        $text | Test-Json -SchemaFile $script:projectSchema | Should -BeTrue
        $doc = $text | ConvertFrom-Json -Depth 10 -AsHashtable
        @($doc.scope.subscriptions) | Should -Be @($script:subId)
        @($doc.scope.resourceGroups) | Should -Be @('rg-app', 'rg-web')
    }
}
