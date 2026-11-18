#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# BATCH-CYCLECLOUD-SIGNAL-1, 2026-11-03. A machine in an Azure Batch pool in
# user subscription mode, or in an Azure CycleCloud cluster, must never be
# called a standalone machine and moved under the service.
#
# What Microsoft's pages say (read 2026-11-03, quoted in the item):
#   - Batch, user subscription mode: "The underlying Virtual Machine Scale Set
#     resources are created in the same subscription as the Batch account"
#     (Batch security and compliance best practices). So a Batch node is a
#     scale set instance: a Uniform instance is not a virtualMachines
#     resource at all, and a Flexible member carries
#     properties.virtualMachineScaleSet.id - which the scan already excludes.
#     No new signal; a test pins it with a Batch-shaped member.
#   - CycleCloud: "Azure CycleCloud automatically creates and adds three tags
#     to each node" (Tagging Nodes). From 8.2: CycleCloudCluster, format
#     /sites/[site_id]/clusters/[cluster_name], and CycleCloudNodeArray,
#     /sites/[site_id]/clusters/[cluster_name]/nodearrays/[nodearray_name].
#     Up to 8.2: ClusterId, example "Demo(username@mysite:92xy4vgh)", beside
#     ClusterName "Demo". CycleCloud is software in a machine, not an Azure
#     resource provider: there is no Azure record that names its nodes, so
#     its own documented tags, in their documented format, are the signal.
#     A tag NAME alone never decides: ClusterName is a common tag.
#
# The machine is excluded (platform-managed) at the scan, with the evidence,
# and stops untouched at Checking when a plan predates this rule.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # One inventory row, in the shape the discovery query projects it. Tags
    # come from Resource Graph JSON, so they are a PSCustomObject.
    function Global:BcRow {
        param([string]$Name = 'vm1', [AllowNull()]$Tags = $null, [string]$VmssId = '')
        $sub = '00000000-0000-0000-0000-000000000000'
        [pscustomobject]@{
            id = "/subscriptions/$sub/resourceGroups/rg-hpc/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-hpc'; location = 'centralus'; zones = $null
            sku = 'Standard_D2ds_v4'; os = 'Linux'; gen = 'V2'; diskController = 'SCSI'
            osName = 'ubuntu'
            imagePublisher = 'Canonical'; imageOffer = '0001-com-ubuntu-server-jammy'; imageSku = '22_04-lts-gen2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = $VmssId; hibernationEnabled = $false; securityType = ''; dataDiskCount = 0; dataDisks = @()
            tags = $Tags; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = ''; osDiskManagedId = "/subscriptions/$sub/resourceGroups/rg-hpc/providers/Microsoft.Compute/disks/$Name-os"
        }
    }
    function Global:BcSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' },
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
            )
            Restrictions = @()
        }
    }
    function Global:BcKnown {
        @{
            SapSystemVms = @{}; AvdSessionHosts = @{}; AvdPoolTypes = @{}; ManagedPlatformGroups = @{}
            SqlVms = @{}; DiskShares = @{}; NicClusterHints = @{}; SqlAgentVms = @{}
            ResourceGroupOwners = @{ '00000000-0000-0000-0000-000000000000/rg-hpc' = '' }
        }
    }
    # The tags of the documented example node 'scheduler' in cluster 'Demo'
    # (Tagging Nodes, CycleCloud 8.2 and later). The site id is the page's own.
    $script:cc82 = [pscustomobject]@{
        Name = 'scheduler'; ClusterName = 'Demo'; CycleCloudCluster = '/sites/92xy4vgh/clusters/Demo'
        CycleOwner = 'username@mysite:92xy4vgh'; ClusterId = 'Demo(username@mysite:92xy4vgh)'
    }
}
AfterAll { Remove-Item 'function:\BcRow', 'function:\BcSku', 'function:\BcKnown' -ErrorAction SilentlyContinue }

Describe 'BATCH-CYCLECLOUD-SIGNAL-1: the CycleCloud signal, from the documented tags only' {

    It 'CycleCloud 8.2 and later: CycleCloudCluster in its documented format' {
        InModuleScope VmMigrationFactory -Parameters @{ t = $script:cc82 } {
            $r = Test-VmfCycleCloudNode -Tags $t
            $r.IsNode | Should -BeTrue
            @($r.Evidence | Where-Object field -EQ 'tags.CycleCloudCluster').value | Should -Be '/sites/92xy4vgh/clusters/Demo'
        }
    }

    It 'a node array node: CycleCloudNodeArray alone in its documented format is enough' {
        InModuleScope VmMigrationFactory {
            $r = Test-VmfCycleCloudNode -Tags @{ CycleCloudNodeArray = '/sites/92xy4vgh/clusters/Demo/nodearrays/Compute' }
            $r.IsNode | Should -BeTrue
            @($r.Evidence | Where-Object field -EQ 'tags.CycleCloudNodeArray').value | Should -Be '/sites/92xy4vgh/clusters/Demo/nodearrays/Compute'
        }
    }

    It 'CycleCloud 8.2 or earlier: ClusterId in its documented format, with the matching ClusterName' {
        InModuleScope VmMigrationFactory {
            $r = Test-VmfCycleCloudNode -Tags @{ ClusterName = 'Demo'; ClusterId = 'Demo(username@mysite:92xy4vgh)'; CycleOwner = 'username@mysite:92xy4vgh' }
            $r.IsNode | Should -BeTrue
            @($r.Evidence | Where-Object field -EQ 'tags.ClusterId').value | Should -Be 'Demo(username@mysite:92xy4vgh)'
            @($r.Evidence | Where-Object field -EQ 'tags.ClusterName').value | Should -Be 'Demo'
        }
    }

    It 'tag names are matched without case, as Azure treats them' {
        InModuleScope VmMigrationFactory {
            (Test-VmfCycleCloudNode -Tags @{ cyclecloudcluster = '/sites/92xy4vgh/clusters/Demo' }).IsNode | Should -BeTrue
            # And in the Resource Graph shape, an object.
            (Test-VmfCycleCloudNode -Tags ([pscustomobject]@{ CYCLECLOUDCLUSTER = '/sites/92xy4vgh/clusters/Demo' })).IsNode | Should -BeTrue
        }
    }

    It 'the Get-AzVM shape (a Dictionary of strings) is read the same way' {
        InModuleScope VmMigrationFactory {
            $d = [System.Collections.Generic.Dictionary[string, string]]::new()
            $d['CycleCloudCluster'] = '/sites/92xy4vgh/clusters/Demo'
            (Test-VmfCycleCloudNode -Tags $d).IsNode | Should -BeTrue
        }
    }

    It 'never fires on a tag name alone, or a value out of the documented format: <Name>' -TestCases @(
        @{ Name = 'no tags'; Tags = $null }
        @{ Name = 'an empty set'; Tags = @{} }
        @{ Name = 'ClusterName alone (a common tag)'; Tags = @{ ClusterName = 'Demo' } }
        @{ Name = 'CycleOwner alone'; Tags = @{ CycleOwner = 'username@mysite:92xy4vgh' } }
        @{ Name = 'CycleCloudCluster with a free value'; Tags = @{ CycleCloudCluster = 'prod' } }
        @{ Name = 'CycleCloudCluster empty'; Tags = @{ CycleCloudCluster = '' } }
        @{ Name = 'CycleCloudCluster with an extra part'; Tags = @{ CycleCloudCluster = '/sites/92xy4vgh/clusters/Demo/extra' } }
        @{ Name = 'CycleCloudNodeArray with a free value'; Tags = @{ CycleCloudNodeArray = 'Compute' } }
        @{ Name = 'ClusterId with no ClusterName'; Tags = @{ ClusterId = 'Demo(username@mysite:92xy4vgh)' } }
        @{ Name = 'ClusterId for another ClusterName'; Tags = @{ ClusterName = 'Other'; ClusterId = 'Demo(username@mysite:92xy4vgh)' } }
        @{ Name = 'ClusterId with a free value'; Tags = @{ ClusterName = 'Demo'; ClusterId = 'Demo' } }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ t = $Tags } {
            $r = Test-VmfCycleCloudNode -Tags $t
            $r.IsNode | Should -BeFalse
            @($r.Evidence).Count | Should -Be 0
        }
    }
}

Describe 'BATCH-CYCLECLOUD-SIGNAL-1: the scan excludes a CycleCloud node, with the evidence' {

    It 'a CycleCloud node is Excluded, platform-managed, Managed by a service, and says why' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (BcKnown); t = $script:cc82 } {
            $rec = Get-VmfAssessmentRecord -Vm (BcRow -Tags $t) -SkuEntry (BcSku) @f
            $rec.classification | Should -Be 'Excluded'
            $rec.platformManaged | Should -BeTrue
            $rec.workload.type | Should -Be 'managed-by-a-service'
            @($rec.workload.evidence | Where-Object field -EQ 'tags.CycleCloudCluster').value | Should -Be '/sites/92xy4vgh/clusters/Demo'
            (@($rec.notes) -join ' ') | Should -Match 'CycleCloud'
        }
    }

    It 'an older CycleCloud node (ClusterId) is excluded too' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (BcKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (BcRow -Tags ([pscustomobject]@{ ClusterName = 'Demo'; ClusterId = 'Demo(username@mysite:92xy4vgh)' })) -SkuEntry (BcSku) @f
            $rec.classification | Should -Be 'Excluded'
            $rec.workload.type | Should -Be 'managed-by-a-service'
        }
    }

    It 'a machine with ordinary tags, ClusterName among them, stays a standalone machine' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (BcKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (BcRow -Tags ([pscustomobject]@{ ClusterName = 'sql-prod'; env = 'prod' })) -SkuEntry (BcSku) @f
            $rec.classification | Should -Not -Be 'Excluded'
            $rec.platformManaged | Should -BeFalse
            $rec.workload.type | Should -Be 'standalone-vm'
        }
    }

    It 'a CycleCloud node array node in a scale set is excluded once, as a CycleCloud node' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (BcKnown) } {
            $vmss = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hpc/providers/Microsoft.Compute/virtualMachineScaleSets/Demo-compute'
            $rec = Get-VmfAssessmentRecord -Vm (BcRow -VmssId $vmss -Tags ([pscustomobject]@{ CycleCloudNodeArray = '/sites/92xy4vgh/clusters/Demo/nodearrays/Compute' })) -SkuEntry (BcSku) @f
            $rec.classification | Should -Be 'Excluded'
            $rec.workload.type | Should -Be 'managed-by-a-service'
        }
    }
}

Describe 'BATCH-CYCLECLOUD-SIGNAL-1: a Batch node in user subscription mode is a scale set member' {

    It 'a Flexible scale set member made by a Batch pool is Excluded as a scale set member' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (BcKnown) } {
            # The scale set name shape Microsoft's Batch error page shows
            # ('<guid>-azurebatch-VMSS-D'); the name decides nothing - the id does.
            $vmss = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-hpc/providers/Microsoft.Compute/virtualMachineScaleSets/00000000-0000-0000-0000-000000000001-azurebatch-VMSS-D'
            $rec = Get-VmfAssessmentRecord -Vm (BcRow -VmssId $vmss) -SkuEntry (BcSku) @f
            $rec.classification | Should -Be 'Excluded'
            $rec.platformManaged | Should -BeTrue
            $rec.workload.type | Should -Be 'node-pool-or-scale-set'
        }
    }
}

Describe 'BATCH-CYCLECLOUD-SIGNAL-1: Checking asks again, for a plan made before the rule' {

    It 'a CycleCloud node, as Get-AzVM returns it, stops untouched, out of scope' {
        InModuleScope VmMigrationFactory {
            $d = [System.Collections.Generic.Dictionary[string, string]]::new()
            $d['ClusterName'] = 'Demo'
            $d['CycleCloudCluster'] = '/sites/92xy4vgh/clusters/Demo'
            $stop = Get-VmfCycleCloudStop -Vm ([pscustomobject]@{ Name = 'scheduler'; Tags = $d })
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'cycleCloudNode'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match "CycleCloudCluster '/sites/92xy4vgh/clusters/Demo'"
            $stop.Detail | Should -Match 'Nothing on the machine changed\.$'
        }
    }

    It 'an ordinary machine goes on: <Name>' -TestCases @(
        @{ Name = 'no tags'; Tags = $null }
        @{ Name = 'ordinary tags'; Tags = @{ ClusterName = 'sql-prod'; env = 'prod' } }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ t = $Tags } {
            Get-VmfCycleCloudStop -Vm ([pscustomobject]@{ Name = 'vm'; Tags = $t }) | Should -BeNullOrEmpty
        }
    }

    It 'PRECHECK asks it once, with the machine it read, beside the other out-of-scope stops' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $start = $code.IndexOf('function Invoke-VmfStepPrecheck')
        $pre = $code.Substring($start, $code.IndexOf('function Get-VmfSafetyAttempt') - $start)
        ([regex]::Matches($pre, 'Get-VmfCycleCloudStop')).Count | Should -Be 1
        $pre | Should -Match 'Get-VmfCycleCloudStop -Vm \$vm\s'
        $at = $pre.IndexOf('Get-VmfCycleCloudStop')
        $at | Should -BeGreaterThan $pre.IndexOf('$ownDisks = Get-VmfDataDiskScopeDetail')
        # Before any stop a person can accept, any RunCommand and any start.
        # PRECHECK-EXT-READ-1: the extension read is Read-VmfPrecheckExtensions now, with its stop.
        # REBUILD-REMOVE-ACCEPT-1: the identity-loss gate is gone with the rebuild.
        foreach ($later in 'Read-VmfPrecheckExtensions', 'Get-VmfTempDiskContentStop', 'Get-VmfWorkloadCheckStop') {
            $pre.IndexOf($later) | Should -BeGreaterThan $at -Because $later
        }
    }

    It 'the stop is in the stop table: outside the scope of this tool, and the machine untouched' {
        $stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($stops.reasons | Where-Object code -EQ 'cycleCloudNode')
        $r.Count | Should -Be 1
        $r[0].retry | Should -Be 'outOfScope'
        $r[0].machine | Should -Be 'untouched'
        $r[0].meaning | Should -Match 'Nothing on the machine was changed'
        $r[0].title | Should -Match '\(not in scope\)$'
    }
}

Describe 'BATCH-CYCLECLOUD-SIGNAL-1: the words' {

    It 'the excluded reason for a CycleCloud node is in the reasons file, with Microsoft''s tagging page' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $e = $reasons.excluded.'cyclecloud-cluster-node'
        $e | Should -Not -BeNullOrEmpty
        $e.docs.url | Should -Match '^https://learn\.microsoft\.com/.*/azure/cyclecloud/how-to/tag-nodes'
        $e.meaning | Should -Match 'CycleCloudCluster'
    }

    It 'the type Managed by a service names CycleCloud' {
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $reasons.workloadTypes.'managed-by-a-service'.meaning | Should -Match 'CycleCloud'
    }
}
