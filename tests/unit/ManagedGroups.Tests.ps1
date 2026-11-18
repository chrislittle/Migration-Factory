#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WORKLOAD-1 (AKS + Databricks): ask the platform which resource groups it
# manages, instead of guessing from names or tags.
#
# The AKS review settled the facts: Uniform-VMSS nodes never enter this
# inventory at all (they are not Microsoft.Compute/virtualMachines resources);
# the exposure is the shapes that DO appear as standalone VMs - the newer
# "Virtual Machines" node pools and legacy availability-set pools, neither
# carrying a vmssId. The cluster declares its real nodeResourceGroup; the
# Databricks workspace declares its managedResourceGroupId. Same mechanism,
# one query, and the same refusal contract as AVD: unverified = no scan.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:Row {
        param([string]$Id = '/subscriptions/sub-a/resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1',
              [string]$Rg = 'rg1')
        [pscustomobject]@{
            id = $Id; name = 'vm1'; resourceGroup = $Rg; location = 'centralus'
            sku = 'Standard_D4s_v5'; gen = 'V2'; os = 'Linux'; osVersion = ''
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'
            vmssId = ''; hibernationEnabled = $false; securityType = ''
            tags = $null; nics = @(); dataDiskCount = 0; maxResourceVolumeMB = 0
        }
    }
}

Describe 'WORKLOAD-1: the managed-groups enumeration' {
    It 'collects AKS node RGs and Databricks managed RGs from ONE query, keyed by subscription' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery {
                [pscustomobject]@{ data = @(
                    [pscustomobject]@{ type = 'microsoft.containerservice/managedclusters'; name = 'aks1'
                                       subscriptionId = 'SUB-A'; nodeResourceGroup = 'My-Custom-Node-RG'; managedResourceGroupId = '' },
                    [pscustomobject]@{ type = 'microsoft.databricks/workspaces'; name = 'dbw1'
                                       subscriptionId = 'sub-b'; nodeResourceGroup = ''
                                       managedResourceGroupId = '/subscriptions/SUB-B/resourceGroups/databricks-rg-dbw1-abc' }
                ) }
            }
            $r = Get-VmfManagedPlatformGroups -Subscriptions @('sub-a', 'sub-b')
            $r.Verified | Should -BeTrue
            $r.Groups.Count | Should -Be 2
            # lowercased keys, so casing can never make a node look standalone
            $r.Groups['sub-a/my-custom-node-rg'] | Should -Match "AKS cluster 'aks1'"
            $r.Groups['sub-b/databricks-rg-dbw1-abc'] | Should -Match "Databricks workspace 'dbw1'"
        }
    }

    It 'pages through $skipToken - a cluster on page two is still found' {
        InModuleScope VmMigrationFactory {
            $script:calls = 0
            Mock Invoke-VmfResourceGraphQuery {
                $script:calls++
                if ($script:calls -eq 1) {
                    [pscustomobject]@{ data = @(
                        [pscustomobject]@{ type = 'microsoft.containerservice/managedclusters'; name = 'aks1'
                                           subscriptionId = 's1'; nodeResourceGroup = 'rg-a'; managedResourceGroupId = '' })
                        '$skipToken' = 'more' }
                }
                else {
                    [pscustomobject]@{ data = @(
                        [pscustomobject]@{ type = 'microsoft.containerservice/managedclusters'; name = 'aks2'
                                           subscriptionId = 's1'; nodeResourceGroup = 'rg-b'; managedResourceGroupId = '' }) }
                }
            }
            $r = Get-VmfManagedPlatformGroups -Subscriptions @('sub-a', 'sub-b')
            $r.Groups.Count | Should -Be 2
            $r.Groups['s1/rg-b'] | Should -Match 'aks2'
        }
    }

    It 'a refused query is NOT verified - cannot read it, cannot claim a machine is not a node' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { throw 'AuthorizationFailed' }
            $r = Get-VmfManagedPlatformGroups -Subscriptions @('sub-a', 'sub-b')
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match 'CANNOT be verified'
        }
    }
}

Describe 'WORKLOAD-1: the rule uses the platform declaration, never the name' {
    It 'a VM in a cluster-declared node RG is EXCLUDED, whatever the RG is called' {
        $vm = Script:Row -Rg 'totally-ordinary-name'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null `
                -ManagedPlatformGroups @{ 'sub-a/totally-ordinary-name' = "AKS cluster 'aks1'" }
        }
        $rec.classification | Should -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Match "AKS cluster 'aks1'"
        @($rec.notes) -join ' ' | Should -Match "platform's own record"
    }

    It 'a Databricks managed RG excludes the same way' {
        $vm = Script:Row -Id '/subscriptions/sub-b/resourceGroups/databricks-rg-x/providers/Microsoft.Compute/virtualMachines/vm1' -Rg 'databricks-rg-x'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null `
                -ManagedPlatformGroups @{ 'sub-b/databricks-rg-x' = "Databricks workspace 'dbw1'" }
        }
        $rec.classification | Should -Be 'Excluded'
        @($rec.notes) -join ' ' | Should -Match 'Databricks'
    }

    It 'an RG merely NAMED like a node RG is an ordinary machine - the convention is dead' {
        # MC_* was a naming convention: customers can rename the real node RG
        # (missed member) and an ordinary RG named MC_* false-positived. Only
        # the platform declaration decides now.
        $vm = Script:Row -Rg 'MC_looks_like_aks_centralus'
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null -ManagedPlatformGroups @{}
        }
        $rec.classification | Should -Not -Be 'Excluded'
    }

    It 'the SAME RG name in a DIFFERENT subscription does not misfire - keys carry the subscription' {
        $vm = Script:Row  # sub-a/rg1
        $rec = InModuleScope VmMigrationFactory -Parameters @{ v = $vm } {
            Get-VmfAssessmentRecord -Vm $v -SkuEntry $null `
                -ManagedPlatformGroups @{ 'sub-OTHER/rg1' = "AKS cluster 'elsewhere'" }
        }
        $rec.classification | Should -Not -Be 'Excluded'
    }

    It 'the AKS tag is gone from the rules - no tag decides anything' {
        $rules = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'Rules.ps1') -Raw
        $rules | Should -Not -Match "aks-managed-poolName' -or"
        $rules | Should -Not -Match "-contains 'aks-managed-poolName'"
        $rules | Should -Not -Match "resourceGroup -match '\^MC_'"
    }
}

Describe 'WORKLOAD-1: the assessment refuses when it cannot verify' {
    BeforeAll {
        $script:assess = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Invoke-VmfAssessment.ps1') -Raw
    }

    It 'unverified managed groups THROW with the fix named - never a scan with less' {
        $script:assess | Should -Match 'Cannot verify which resource groups belong to AKS clusters or Databricks workspaces'
        $script:assess | Should -Match 'Nothing has been assessed'
    }

    It 'and the refusal is real: a refusing query stops the whole assessment' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfFleetInventory { , @([pscustomobject]@{
                id = '/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
                name = 'vm1'; resourceGroup = 'rg'; location = 'centralus'; sku = 'Standard_D4s_v5'
            }) }
            Mock Get-VmfSkuCatalog { , @() }
            # CLUSTER-DETECT-1: one read of the interfaces gives accelerated networking and the cluster hints.
            Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
            Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            # SAP-1: the scan asks this too, and refuses when it cannot be answered.
            Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
            Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $false; Detail = 'HTTP 403' } }
            $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            try {
                { Invoke-VmfAssessment -Scope @{ Subscriptions = @('s1') } -OutPath $out } |
                    Should -Throw -ExpectedMessage '*AKS clusters or Databricks workspaces*'
            }
            finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
        }
    }
}
