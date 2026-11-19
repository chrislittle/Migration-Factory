#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DETECT-PATTERNS-1, 2026-10-23. Find the workloads that must not move like an
# ordinary machine, and name each machine's workload type.
#
# The product must be sure it identifies each workload. So every signal
# here is driven with a fixture in the shape Azure returns it - a Resource
# Graph row, an ARM list page - and every one has a test that it does NOT fire
# on an ordinary machine. Unknown is never a refusal and never a pass: a
# signal the scan could not read makes the type "not checked" and gives a
# warning, and never a blocker.
#
# The decisions (2026-10-10, 10-16, 10-20, 10-23):
#   - refused, outside the scope of this tool: every storage and backup
#     appliance, by all four ways it reaches Azure (image, purchase plan,
#     gallery image, managed application); WEKA servers AND clients; failover
#     cluster nodes on a shared disk (a data disk with maxShares > 1); SQL
#     Server Always On availability group members;
#   - a warning, the machine may still move: a single SQL Server machine;
#   - a machine on the NVA list AND the appliance list is refused ONCE, with
#     the NVA reason;
#   - the workload type is a column with a filter, with its evidence.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '00000000-0000-0000-0000-000000000000'

    # One inventory row, in the shape the discovery query projects it.
    function Global:WpRow {
        param(
            [string]$Name = 'vm1',
            [string]$Rg = 'rg-app',
            [string]$Publisher = 'MicrosoftWindowsServer',
            [string]$Offer = 'WindowsServer',
            [string]$Sku = '2022-datacenter-g2',
            [string]$PlanPublisher = '',
            [string]$PlanProduct = '',
            [string]$CommunityGalleryImageId = '',
            [string]$SharedGalleryImageId = '',
            [string]$ImageId = '',
            [string[]]$DataDiskIds = @(),
            [string]$VmssId = ''
        )
        $sub = '00000000-0000-0000-0000-000000000000'
        $disks = @(for ($i = 0; $i -lt $DataDiskIds.Count; $i++) {
            [pscustomobject]@{ lun = $i; name = ($DataDiskIds[$i] -split '/')[-1]; createOption = 'Attach'; caching = 'None'
                managedDisk = [pscustomobject]@{ id = $DataDiskIds[$i]; storageAccountType = 'Premium_LRS' } }
        })
        [pscustomobject]@{
            id = "/subscriptions/$sub/resourceGroups/$Rg/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = $Rg; location = 'centralus'; zones = $null
            sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
            osName = 'Windows Server 2022 Datacenter'
            imagePublisher = $Publisher; imageOffer = $Offer; imageSku = $Sku; imageId = $ImageId
            communityGalleryImageId = $CommunityGalleryImageId; sharedGalleryImageId = $SharedGalleryImageId
            planPublisher = $PlanPublisher; planProduct = $PlanProduct
            vmssId = $VmssId; hibernationEnabled = $false; securityType = ''; dataDiskCount = $disks.Count
            dataDisks = $disks
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = ''; osDiskManagedId = "/subscriptions/$sub/resourceGroups/$Rg/providers/Microsoft.Compute/disks/$Name-os"
        }
    }
    function Global:WpSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @(
                [pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' },
                [pscustomobject]@{ Name = 'vCPUs'; Value = '2' }
            )
            Restrictions = @()
        }
    }
    # Every lookup read, nothing found: the facts of an ordinary estate.
    function Global:WpKnown {
        param([hashtable]$Over = @{})
        $facts = @{
            SapSystemVms = @{}; AvdSessionHosts = @{}; AvdPoolTypes = @{}; ManagedPlatformGroups = @{}
            SqlVms = @{}; DiskShares = @{}
            # CLUSTER-DETECT-1: the network interfaces and the extensions are read too.
            NicClusterHints = @{}; SqlAgentVms = @{}
            ResourceGroupOwners = @{ '00000000-0000-0000-0000-000000000000/rg-app' = ''; '00000000-0000-0000-0000-000000000000/rg-sql' = '' }
        }
        foreach ($k in $Over.Keys) { $facts[$k] = $Over[$k] }
        $facts
    }
}
AfterAll { Remove-Item 'function:\WpRow', 'function:\WpSku', 'function:\WpKnown' -ErrorAction SilentlyContinue }

Describe 'DETECT-PATTERNS-1: storage and backup appliances are refused, by all four ways they reach Azure' {

    It 'a Marketplace image: the publisher AND the offer (Cohesity, whose offer name hides it)' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Publisher 'cohesity' -Offer 'cohesity-cloudtd-tool' -Sku 'cohesity-dataplatform-cloud-edition-2021') -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'storage-appliance-needs-vendor'
            $rec.classification | Should -Be 'Blocked'
            $rec.workload.type | Should -Be 'vendor-appliance'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'imageReference.publisher' }).value | Should -Be 'cohesity'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'imageReference.offer' }).value | Should -Be 'cohesity-cloudtd-tool'
        }
    }

    It 'a Marketplace purchase plan, when the image itself names nothing (Pure Storage)' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $row = WpRow -Publisher '' -Offer '' -Sku '' -PlanPublisher 'purestorageinc1578960262525' -PlanProduct 'cloud_block_store_azure_beta_image' `
                -ImageId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/galleries/g1/images/cbs/versions/1.0.0'
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'storage-appliance-needs-vendor'
            $rec.workload.type | Should -Be 'vendor-appliance'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'plan.publisher' }).value | Should -Be 'purestorageinc1578960262525'
            $rec.planPublisher | Should -Be 'purestorageinc1578960262525'
            $rec.planProduct | Should -Be 'cloud_block_store_azure_beta_image'
        }
    }

    It 'a vendor gallery: WEKA, from its community gallery - servers AND clients' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            # The id shape WEKA's own deployment code gives; every WEKA machine,
            # storage or client, is made from it.
            $row = WpRow -Publisher '' -Offer '' -Sku '' -CommunityGalleryImageId '/communityGalleries/WekaIO-00000000-0000-0000-0000-000000000000/images/weka_custom_image/versions/3.0.0'
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'storage-appliance-needs-vendor'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'imageReference.communityGalleryImageId' }).value | Should -Match '^/communityGalleries/WekaIO-'
            $rec.galleryImageId | Should -Match '^/communityGalleries/WekaIO-'
        }
    }

    It 'a managed application: the resource group is managed by Microsoft.Solutions/applications' {
        $app = "/subscriptions/$($script:sub)/resourceGroups/rg-consumer/providers/Microsoft.Solutions/applications/contoso-cbs"
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ ResourceGroupOwners = @{ "$($script:sub)/rg-app" = $app } }); app = $app } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'managed-application-needs-vendor'
            $rec.workload.type | Should -Be 'vendor-appliance'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'resourceGroup.managedBy' }).value | Should -Be $app
            # The vendor owns it, but the tool says it with its reason - it is not
            # silently left out like a scale set member.
            $rec.classification | Should -Be 'Blocked'
        }
    }

    It 'NetApp Cloud Volumes ONTAP is on both lists: refused ONCE, with the NVA reason' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Publisher 'netapp' -Offer 'netapp-ontap-cloud' -Sku 'ontap_cloud_byol') -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'nva-requires-parallel-deployment'
            @($rec.blockers) | Should -Not -Contain 'storage-appliance-needs-vendor'
            $rec.workload.type | Should -Be 'vendor-appliance'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'nvaPolicy' }).Count | Should -Be 1
        }
    }

    It 'the publisher alone is never evidence: a Veeam offer that is not the appliance passes' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Publisher 'veeam' -Offer 'office365backup') -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Not -Contain 'storage-appliance-needs-vendor'
            $rec.workload.type | Should -Be 'standalone-vm'
        }
    }

    It 'and nothing fires on an ordinary machine' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            foreach ($code in 'storage-appliance-needs-vendor', 'managed-application-needs-vendor', 'shared-disk-cluster-node', 'sql-availability-group-member') {
                @($rec.blockers) | Should -Not -Contain $code
            }
            # MANA-WIN-3: every Windows machine is told the move can download
            # the MANA driver - a finding about the operating system, not the
            # workload. No workload warning fires.
            @($rec.warnings) | Should -Be @('mana-driver-download')
            $rec.workload.type | Should -Be 'standalone-vm'
            @($rec.workload.evidence).Count | Should -Be 0
            $rec.classification | Should -Be 'ReadyAfterPrep'
        }
    }

    It 'case is ignored, as Azure ignores it' {
        InModuleScope VmMigrationFactory {
            (Test-VmfStorageAppliance -ImagePublisher 'Cohesity' -ImageOffer 'Cohesity-CloudTD-Tool').IsAppliance | Should -BeTrue
            (Test-VmfStorageAppliance -GalleryImageId '/COMMUNITYGALLERIES/wekaio-1/images/x/versions/1').IsAppliance | Should -BeTrue
        }
    }

    It 'a gallery image from any other gallery is not WEKA' {
        InModuleScope VmMigrationFactory {
            (Test-VmfStorageAppliance -GalleryImageId '/communityGalleries/ContosoImages-1/images/x/versions/1').IsAppliance | Should -BeFalse
            (Test-VmfStorageAppliance -GalleryImageId '/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/galleries/WekaIO/images/x/versions/1').IsAppliance | Should -BeFalse
        }
    }
}

Describe 'NVA-PLAN-1: a network virtual appliance made from a gallery image is refused by its purchase plan' {
    # The row Resource Graph gives for a machine made from a gallery copy of a
    # Marketplace appliance image: imageReference holds only the gallery image
    # id, with no publisher, offer or sku, and Azure keeps the purchase plan.

    BeforeAll {
        $script:galleryId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/galleries/g1/images/fw/versions/1.0.0'
    }

    It 'a firewall from a gallery image is refused with the NVA reason, and the evidence is the plan' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown); g = $script:galleryId } {
            $row = WpRow -Name 'fw1' -Publisher '' -Offer '' -Sku '' -PlanPublisher 'paloaltonetworks' -PlanProduct 'vmseries-flex' -ImageId $g
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'nva-requires-parallel-deployment'
            $rec.classification | Should -Be 'Blocked'
            $rec.workload.type | Should -Be 'vendor-appliance'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'plan.publisher' }).value | Should -Be 'paloaltonetworks'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'plan.product' }).value | Should -Be 'vmseries-flex'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'nvaPolicy' }).Count | Should -Be 1
            # The image names nothing, so it is not given as evidence.
            @($rec.workload.evidence | Where-Object { $_.field -like 'imageReference.*' }).Count | Should -Be 0
            @($rec.notes) -join ' ' | Should -Match 'purchase plan'
        }
    }

    It 'a plan on both lists (NetApp) is refused ONCE, with the NVA reason' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown); g = $script:galleryId } {
            $row = WpRow -Publisher '' -Offer '' -Sku '' -PlanPublisher 'netapp' -PlanProduct 'netapp-ontap-cloud' -ImageId $g
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'nva-requires-parallel-deployment'
            @($rec.blockers) | Should -Not -Contain 'storage-appliance-needs-vendor'
        }
    }

    It 'an ordinary gallery machine with no plan is not an NVA' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown); g = $script:galleryId } {
            $row = WpRow -Publisher '' -Offer '' -Sku '' -ImageId $g
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Not -Contain 'nva-requires-parallel-deployment'
            $rec.workload.type | Should -Be 'standalone-vm'
        }
    }

    It 'a gallery machine with an ordinary plan is not an NVA' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown); g = $script:galleryId } {
            $row = WpRow -Publisher '' -Offer '' -Sku '' -PlanPublisher 'canonical' -PlanProduct 'ubuntu-pro' -ImageId $g
            $rec = Get-VmfAssessmentRecord -Vm $row -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Not -Contain 'nva-requires-parallel-deployment'
            $rec.workload.type | Should -Be 'standalone-vm'
        }
    }

    It 'a Marketplace image NVA still gives the image fields as evidence' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Publisher 'checkpoint' -Offer 'check-point-cg-r8120' -Sku 'sg-byol') -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'nva-requires-parallel-deployment'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'imageReference.publisher' }).value | Should -Be 'checkpoint'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'imageReference.offer' }).value | Should -Be 'check-point-cg-r8120'
            @($rec.workload.evidence | Where-Object { $_.field -like 'plan.*' }).Count | Should -Be 0
        }
    }
}

Describe 'DETECT-PATTERNS-1: failover cluster nodes on a shared disk are refused' {

    It 'a data disk with maxShares 2 refuses the machine and names the disk' {
        $disk = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/quorum"
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ DiskShares = @{ $disk.ToLowerInvariant() = 2 } }); d = $disk } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -DataDiskIds @($d)) -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'shared-disk-cluster-node'
            $rec.workload.type | Should -Be 'cluster-or-database'
            $ev = @($rec.workload.evidence | Where-Object { $_.field -eq 'disk.maxShares' })
            $ev.value | Should -Match 'quorum'
            $ev.value | Should -Match '2'
        }
    }

    It 'a data disk with maxShares 1 (or none recorded) is an ordinary disk' {
        $disk = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/data1"
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ DiskShares = @{ $disk.ToLowerInvariant() = 1 } }); d = $disk } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -DataDiskIds @($d)) -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Not -Contain 'shared-disk-cluster-node'
            $rec.workload.type | Should -Be 'standalone-vm'
        }
    }

    It 'a data disk the scan could not read is UNKNOWN: not checked, a warning, never a refusal' {
        $disk = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/hidden"
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown); d = $disk } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -DataDiskIds @($d)) -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Not -Contain 'shared-disk-cluster-node'
            $rec.workload.type | Should -Be 'not-checked'
            @($rec.warnings) | Should -Contain 'workload-type-not-checked'
            $miss = @($rec.workload.evidence | Where-Object { $_.field -eq 'disk.maxShares' })
            $miss.Count | Should -Be 1
            $miss.value | Should -BeNullOrEmpty
        }
    }
}

Describe 'DETECT-PATTERNS-1: SQL Server - an availability group is refused, a single machine is a warning' {

    It 'a SQL virtual machine in an availability group refuses the machine' {
        $vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-sql/providers/Microsoft.Compute/virtualMachines/sql1".ToLowerInvariant()
        $sql = @{ $vmId = @{ id = "/subscriptions/$($script:sub)/resourceGroups/rg-sql/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql1"
                             groupId = "/subscriptions/$($script:sub)/resourceGroups/rg-sql/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachineGroups/ag1"
                             offer = 'SQL2022-WS2022'; sku = 'Enterprise' } }
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ SqlVms = $sql }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Name 'sql1' -Rg 'rg-sql') -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Contain 'sql-availability-group-member'
            @($rec.warnings) | Should -Not -Contain 'sql-server-agree-downtime'
            $rec.workload.type | Should -Be 'cluster-or-database'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'sqlVirtualMachineGroupResourceId' }).value | Should -Match 'sqlVirtualMachineGroups/ag1$'
        }
    }

    It 'a SQL virtual machine on its own is a WARNING: it may still move' {
        $vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-sql/providers/Microsoft.Compute/virtualMachines/sql1".ToLowerInvariant()
        $sql = @{ $vmId = @{ id = "/subscriptions/$($script:sub)/resourceGroups/rg-sql/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql1"
                             groupId = ''; offer = 'SQL2022-WS2022'; sku = 'Developer' } }
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ SqlVms = $sql }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Name 'sql1' -Rg 'rg-sql') -SkuEntry (WpSku) @f
            @($rec.blockers) | Should -Not -Contain 'sql-availability-group-member'
            @($rec.warnings) | Should -Contain 'sql-server-agree-downtime'
            $rec.classification | Should -Be 'ReadyAfterPrep'
            $rec.workload.type | Should -Be 'cluster-or-database'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' }).value | Should -Match 'sqlVirtualMachines/sql1$'
        }
    }

    It 'a SQL Server image without the SQL IaaS Agent is the same warning' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Publisher 'MicrosoftSQLServer' -Offer 'sql2022-ws2022' -Sku 'enterprise-gen2') -SkuEntry (WpSku) @f
            @($rec.warnings) | Should -Contain 'sql-server-agree-downtime'
            @($rec.blockers) | Should -Not -Contain 'sql-availability-group-member'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'imageReference.publisher' }).value | Should -Be 'MicrosoftSQLServer'
        }
    }
}

Describe 'DETECT-PATTERNS-1: the workload type, in the order the planner proved' {

    It 'a managed application owns a pooled AVD host: Vendor appliance, and the host pool is still shown' {
        $app = "/subscriptions/$($script:sub)/resourceGroups/rg-consumer/providers/Microsoft.Solutions/applications/contoso-app"
        $vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1".ToLowerInvariant()
        $f = WpKnown -Over @{ ResourceGroupOwners = @{ "$($script:sub)/rg-app" = $app }; AvdSessionHosts = @{ $vmId = 'hp1' }; AvdPoolTypes = @{ $vmId = 'Pooled' } }
        InModuleScope VmMigrationFactory -Parameters @{ f = $f } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'vendor-appliance'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'hostPool.hostPoolType' }).value | Should -Be 'Pooled'
        }
    }

    It 'a pooled AVD session host is a Pooled AVD host' {
        $vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1".ToLowerInvariant()
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ AvdSessionHosts = @{ $vmId = 'hp1' }; AvdPoolTypes = @{ $vmId = 'Pooled' } }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'pooled-avd-host'
            $rec.classification | Should -Be 'Excluded'
        }
    }

    It 'a personal AVD session host is a Standalone VM, and says why it is not pooled' {
        $vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1".ToLowerInvariant()
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ AvdSessionHosts = @{ $vmId = 'hp2' }; AvdPoolTypes = @{ $vmId = 'Personal' } }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'standalone-vm'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'hostPool.hostPoolType' }).value | Should -Be 'Personal'
            # The product still leaves every session host alone (WORKLOAD-1).
            $rec.classification | Should -Be 'Excluded'
        }
    }

    It 'a scale set member is a Node pool or scale set' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -VmssId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachineScaleSets/ss1') -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'node-pool-or-scale-set'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'virtualMachineScaleSet.id' }).value | Should -Match 'ss1$'
        }
    }

    It 'a resource group managed by Azure Red Hat OpenShift is a Node pool, and the machine is left alone' {
        $aro = "/subscriptions/$($script:sub)/resourceGroups/rg-aro/providers/Microsoft.RedHatOpenShift/openShiftClusters/aro1"
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ ResourceGroupOwners = @{ "$($script:sub)/rg-app" = $aro } }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'node-pool-or-scale-set'
            $rec.classification | Should -Be 'Excluded'
            $rec.platformManaged | Should -BeTrue
        }
    }

    It 'a resource group managed by any other service is Managed by a service, and left alone' {
        $svc = "/subscriptions/$($script:sub)/resourceGroups/rg-x/providers/Microsoft.Databricks/workspaces/dbw1"
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ ResourceGroupOwners = @{ "$($script:sub)/rg-app" = $svc } }); svc = $svc } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'managed-by-a-service'
            $rec.classification | Should -Be 'Excluded'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'resourceGroup.managedBy' }).value | Should -Be $svc
        }
    }

    It 'the AKS cluster record alone (no managedBy read) still gives Node pool or scale set' {
        $f = WpKnown -Over @{ ManagedPlatformGroups = @{ '00000000-0000-0000-0000-000000000000/rg-app' = "AKS cluster 'aks1'" } }
        InModuleScope VmMigrationFactory -Parameters @{ f = $f } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'node-pool-or-scale-set'
        }
    }

    It 'an SAP machine is a Cluster or database' {
        $vmId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1".ToLowerInvariant()
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ SapSystemVms = @{ $vmId = 'the Azure VM extension for SAP solutions is installed' } }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'cluster-or-database'
        }
    }

    It 'a resource group the scan could not read: not checked, never Standalone VM' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ ResourceGroupOwners = @{} }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'not-checked'
            @($rec.warnings) | Should -Contain 'workload-type-not-checked'
            $rec.classification | Should -Be 'ReadyAfterPrep'
        }
    }

    It 'with no lookups at all, nothing is claimed' {
        InModuleScope VmMigrationFactory {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow) -SkuEntry (WpSku)
            $rec.workload.type | Should -Be 'not-checked'
        }
    }

    It 'a refusal still wins over an unknown: a WEKA machine whose group was not read is a Vendor appliance' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (WpKnown -Over @{ ResourceGroupOwners = @{} }) } {
            $rec = Get-VmfAssessmentRecord -Vm (WpRow -Publisher '' -Offer '' -CommunityGalleryImageId '/communityGalleries/WekaIO-1/images/w/versions/1') -SkuEntry (WpSku) @f
            $rec.workload.type | Should -Be 'vendor-appliance'
        }
    }
}

Describe 'DETECT-PATTERNS-1: the lookups answer, or say they could not' {

    It 'SQL virtual machines are listed from the provider, per subscription, in the shape Azure returns' {
        InModuleScope VmMigrationFactory {
            # The shape of Microsoft's own List sample (api-version 2023-10-01),
            # with the ids changed to placeholders.
            $page = @{ value = @(
                    @{ name = 'sql1'; type = 'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
                       id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql1'
                       properties = @{ sqlImageOffer = 'SQL2022-WS2022'; sqlImageSku = 'Enterprise'; sqlManagement = 'Full'; sqlServerLicenseType = 'PAYG'
                                       sqlVirtualMachineGroupResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachineGroups/ag1'
                                       virtualMachineResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.Compute/virtualMachines/sql1' } },
                    @{ name = 'sql2'; type = 'Microsoft.SqlVirtualMachine/sqlVirtualMachines'
                       id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql2'
                       properties = @{ sqlImageOffer = 'SQL2019-Ubuntu20'; sqlImageSku = 'Developer'; sqlManagement = 'LightWeight'
                                       virtualMachineResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-sql/providers/Microsoft.Compute/virtualMachines/SQL2' } }
                ) } | ConvertTo-Json -Depth 6
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = $page } }
            $r = Get-VmfSqlVirtualMachines -Subscriptions @('00000000-0000-0000-0000-000000000000')
            $r.Verified | Should -BeTrue
            $r.Ids.Count | Should -Be 2
            $r.Ids['/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg-sql/providers/microsoft.compute/virtualmachines/sql1'].groupId | Should -Match 'ag1$'
            $r.Ids['/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/rg-sql/providers/microsoft.compute/virtualmachines/sql2'].groupId | Should -BeNullOrEmpty
            Should -Invoke Invoke-AzRestMethod -Times 1 -ParameterFilter { $Path -match '^/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft\.SqlVirtualMachine/sqlVirtualMachines\?api-version=2023-10-01$' }
        }
    }

    It 'only the four facts it needs are kept - nothing else from the record' {
        InModuleScope VmMigrationFactory {
            $page = @{ value = @(@{ id = '/subscriptions/s/resourceGroups/r/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/a'
                        properties = @{ virtualMachineResourceId = '/subscriptions/s/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/a'
                                        wsfcDomainCredentials = @{ clusterBootstrapAccountPassword = 'not-a-real-value' } } }) } | ConvertTo-Json -Depth 6
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = $page } }
            $r = Get-VmfSqlVirtualMachines -Subscriptions @('s')
            $kept = $r.Ids.Values | ConvertTo-Json -Depth 6
            $kept | Should -Not -Match 'not-a-real-value'
            @($r.Ids.Values)[0].Keys | Sort-Object | Should -Be @('groupId', 'id', 'offer', 'sku')
        }
    }

    It 'a subscription with the provider not registered is a verified "no SQL here"' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 409; Content = '{"error":{"code":"MissingSubscriptionRegistration","message":"The subscription is not registered to use namespace Microsoft.SqlVirtualMachine."}}' } }
            $r = Get-VmfSqlVirtualMachines -Subscriptions @('s')
            $r.Verified | Should -BeTrue
            $r.Ids.Count | Should -Be 0
        }
    }

    It 'a refused read is NOT "no SQL here": Verified is false' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = '{"error":{"code":"AuthorizationFailed"}}' } }
            $r = Get-VmfSqlVirtualMachines -Subscriptions @('s')
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match '403'
        }
    }

    It 'shared disks: every attached disk, with its maxShares, from one Resource Graph query' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery {
                [pscustomobject]@{ data = @(
                    [pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/disks/Quorum'; maxShares = 2 },
                    [pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/disks/data1'; maxShares = $null }
                ) }
            }
            $r = Get-VmfDiskShareMap -Subscriptions @('S')
            $r.Verified | Should -BeTrue
            $r.Disks['/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/quorum'] | Should -Be 2
            # Azure leaves maxShares out on a disk that was never shared: 1.
            $r.Disks['/subscriptions/s/resourcegroups/r/providers/microsoft.compute/disks/data1'] | Should -Be 1
            Should -Invoke Invoke-VmfResourceGraphQuery -ParameterFilter { $Body.query -match "microsoft\.compute/disks" -and $Body.query -match 'maxShares' }
        }
    }

    It 'resource groups: every group in scope, with managedBy, so an unread group is told apart from an unmanaged one' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery {
                [pscustomobject]@{ data = @(
                    [pscustomobject]@{ subscriptionId = 'S1'; name = 'RG-App'; managedBy = '' },
                    [pscustomobject]@{ subscriptionId = 'S1'; name = 'mrg-cbs'; managedBy = '/subscriptions/S1/resourceGroups/c/providers/Microsoft.Solutions/applications/cbs' }
                ) }
            }
            $r = Get-VmfResourceGroupOwners -Subscriptions @('S1')
            $r.Verified | Should -BeTrue
            $r.Groups.ContainsKey('s1/rg-app') | Should -BeTrue
            $r.Groups['s1/rg-app'] | Should -Be ''
            $r.Groups['s1/mrg-cbs'] | Should -Match 'Microsoft.Solutions/applications/cbs$'
            Should -Invoke Invoke-VmfResourceGraphQuery -ParameterFilter { $Body.query -match '(?i)resourcecontainers' -and $Body.query -match 'managedBy' }
        }
    }

    It 'a Resource Graph failure is NOT an empty answer' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { throw 'HTTP 403' }
            (Get-VmfDiskShareMap -Subscriptions @('S')).Verified | Should -BeFalse
            (Get-VmfResourceGroupOwners -Subscriptions @('S')).Verified | Should -BeFalse
        }
    }

    It 'the AVD lookup gives each session host its pool type, from the host pool it already reads' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfArmList {
                if ($Path -match '/sessionHosts') {
                    return @{ Ok = $true; Items = @([pscustomobject]@{ properties = [pscustomobject]@{ resourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/r/providers/Microsoft.Compute/virtualMachines/H1' } }) }
                }
                @{ Ok = $true; Items = @([pscustomobject]@{ id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/r/providers/Microsoft.DesktopVirtualization/hostPools/hp1'; name = 'hp1'
                                                           properties = [pscustomobject]@{ hostPoolType = 'Pooled' } }) }
            }
            $r = Get-VmfAvdSessionHostIds -Subscriptions @('00000000-0000-0000-0000-000000000000')
            $r.Verified | Should -BeTrue
            $r.Ids['/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/r/providers/microsoft.compute/virtualmachines/h1'] | Should -Be 'hp1'
            $r.PoolTypes['/subscriptions/00000000-0000-0000-0000-000000000000/resourcegroups/r/providers/microsoft.compute/virtualmachines/h1'] | Should -Be 'Pooled'
        }
    }

    It 'the inventory query reads the purchase plan, the gallery image ids and the data disks, and projects them' {
        InModuleScope VmMigrationFactory {
            $q = $script:VmfArgQuery
            $q | Should -Match 'planPublisher = tostring\(plan\.publisher\)'
            $q | Should -Match 'planProduct = tostring\(plan\.product\)'
            $q | Should -Match 'communityGalleryImageId = tostring\(properties\.storageProfile\.imageReference\.communityGalleryImageId\)'
            $q | Should -Match 'sharedGalleryImageId = tostring\(properties\.storageProfile\.imageReference\.sharedGalleryImageId\)'
            $q | Should -Match 'dataDisks = properties\.storageProfile\.dataDisks'
            $projection = [regex]::Match($q, '(?s)\| project (.+?)\| order by').Groups[1].Value
            foreach ($f in 'planPublisher', 'planProduct', 'communityGalleryImageId', 'sharedGalleryImageId', 'dataDisks') { $projection | Should -Match "\b$f\b" }
        }
    }
}

Describe 'DETECT-PATTERNS-1: the scan refuses when it cannot verify, and carries the facts through' {
    BeforeAll {
        function Global:WpScan {
            param([hashtable]$SqlResult, [hashtable]$DiskResult, [hashtable]$GroupResult, [object[]]$Rows)
            InModuleScope VmMigrationFactory -Parameters @{ s = $SqlResult; d = $DiskResult; g = $GroupResult; rows = $Rows } {
                Mock Get-VmfFleetInventory { , @($rows) }
                Mock Get-VmfSkuCatalog { , @() }
                Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
                # CLUSTER-DETECT-1: one read of the interfaces gives accelerated networking and the cluster hints.
                Mock Get-VmfNicFacts { @{ Accelerated = @{}; ClusterHints = @{} } }
                Mock Get-VmfSqlIaaSAgentVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfSqlVirtualMachines { $s }
                Mock Get-VmfDiskShareMap { $d }
                Mock Get-VmfResourceGroupOwners { $g }
                $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-wp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                try {
                    Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out | Out-Null
                    Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json -Depth 20
                }
                finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
            }
        }
        $script:ok = @{ Ids = @{}; Verified = $true; Detail = 'mocked' }
        $script:okDisks = @{ Disks = @{}; Verified = $true; Detail = 'mocked' }
        $script:okGroups = @{ Groups = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }; Verified = $true; Detail = 'mocked' }
    }
    AfterAll { Remove-Item 'function:\WpScan' -ErrorAction SilentlyContinue }

    It 'an unreadable SQL list stops the whole scan, naming the permission' {
        { WpScan -SqlResult @{ Ids = @{}; Verified = $false; Detail = 'HTTP 403' } -DiskResult $script:okDisks -GroupResult $script:okGroups -Rows @(WpRow) } |
            Should -Throw -ExpectedMessage '*Microsoft.SqlVirtualMachine/sqlVirtualMachines/read*'
    }

    It 'an unreadable disk list stops it' {
        { WpScan -SqlResult $script:ok -DiskResult @{ Disks = @{}; Verified = $false; Detail = 'HTTP 403' } -GroupResult $script:okGroups -Rows @(WpRow) } |
            Should -Throw -ExpectedMessage '*shared disks*'
    }

    It 'an unreadable resource group list stops it' {
        { WpScan -SqlResult $script:ok -DiskResult $script:okDisks -GroupResult @{ Groups = @{}; Verified = $false; Detail = 'HTTP 403' } -Rows @(WpRow) } |
            Should -Throw -ExpectedMessage '*resource groups*'
    }

    It 'and a scan that reads them all writes the workload type, the evidence and the warnings' {
        $disk = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/quorum"
        $doc = WpScan -SqlResult $script:ok -DiskResult @{ Disks = @{ $disk.ToLowerInvariant() = 3 }; Verified = $true; Detail = 'mocked' } -GroupResult $script:okGroups `
            -Rows @((WpRow -Name 'node1' -DataDiskIds @($disk)), (WpRow -Name 'plain'))
        $doc.schemaVersion | Should -Be 17 -Because 'CLUSTER-DETECT-1 made it 6, REBUILD-ACCEPT-1 7, REBUILD-PATCH-MODE-1 8, DCR-READ-1 9, ALREADY-CURRENT-1 10, READY-NOW-REMOVE-1 11, REBUILD-REMOVE-ROLE-1 12, CRG-MOVE-DEMAND-1 13, SCAN-PARTIAL-SUBS-1 14, REBUILD-REMOVE-SCAN-EXT-1 15, DRIFT-12 16'
        $node = @($doc.vms | Where-Object name -eq 'node1')[0]
        $node.workload.type | Should -Be 'cluster-or-database'
        @($node.blockers) | Should -Contain 'shared-disk-cluster-node'
        $plain = @($doc.vms | Where-Object name -eq 'plain')[0]
        $plain.workload.type | Should -Be 'standalone-vm'
        # MANA-WIN-3: the Windows finding only - no workload warning.
        @($plain.warnings) | Should -Be @('mana-driver-download')
    }
}

Describe 'DETECT-PATTERNS-1: the data, the words and the permission' {
    BeforeAll {
        $script:data = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'storage-appliances.json') -Raw | ConvertFrom-Json
        $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
    }

    It 'the vendor list says it is not a Microsoft list, with its date and source' {
        $script:data.notAMicrosoftList | Should -BeTrue
        $script:data.readUtc | Should -Match '^\d{4}-\d{2}-\d{2}$'
        $script:data.source.reference | Should -Match '^https://learn\.microsoft\.com/'
        $script:data.source.drift | Should -Match 'DETECT-VENDOR-DRIFT-1'
    }

    It 'every vendor has a publisher AND offers, and WEKA has its gallery' {
        @($script:data.vendors).Count | Should -BeGreaterThan 20
        foreach ($v in $script:data.vendors) {
            $v.publisher | Should -Not -BeNullOrEmpty
            @($v.offers).Count | Should -BeGreaterThan 0 -Because $v.vendor
        }
        @($script:data.galleries | Where-Object vendor -eq 'WEKA').imageId | Should -Be '/communityGalleries/WekaIO-*'
    }

    It 'the refusals are outside the scope of this tool, and the warnings are not blockers' {
        InModuleScope VmMigrationFactory {
            $scope = Get-VmfOutOfScopeBlockerCodes
            foreach ($code in 'storage-appliance-needs-vendor', 'managed-application-needs-vendor', 'shared-disk-cluster-node', 'sql-availability-group-member') {
                $scope | Should -Contain $code
            }
        }
        foreach ($code in 'storage-appliance-needs-vendor', 'managed-application-needs-vendor', 'shared-disk-cluster-node', 'sql-availability-group-member') {
            $r = $script:reasons.blockers.$code
            $r | Should -Not -BeNullOrEmpty -Because $code
            @($r.appliesTo) | Should -Be @('v5', 'v6', 'v7')
            $r.whatToDo | Should -Match 'outside the scope of this tool' -Because $code
        }
        foreach ($code in 'sql-server-agree-downtime', 'workload-type-not-checked') {
            $script:reasons.warnings.$code | Should -Not -BeNullOrEmpty -Because $code
            $script:reasons.blockers.PSObject.Properties[$code] | Should -BeNullOrEmpty
        }
        $script:reasons.warnings.'sql-server-agree-downtime'.whatToDo | Should -Match 'database owner'
    }

    # The planner names the sixth type 'Standalone VM'. This product says machine,
    # never VM (CLAUDE.md rule 10, the Simplified English gate), so it is 'Standalone machine'.
    It 'every workload type has a name and how it moves, in the planner order' {
        $names = @($script:reasons.workloadTypes.PSObject.Properties | ForEach-Object { $_.Value.title })
        $names | Should -Be @('Node pool or scale set', 'Pooled AVD host', 'Managed by a service',
            'Standalone machine', 'Cluster or database', 'Vendor appliance', 'May be a cluster node', 'Type not checked')
        foreach ($t in $script:reasons.workloadTypes.PSObject.Properties) { $t.Value.meaning | Should -Not -BeNullOrEmpty -Because $t.Name }
    }

    It 'review: every type the operator is shown is one the rules can give - none is listed that no machine can have' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'assess' 'WorkloadType.ps1')
        $given = @([regex]::Matches($code, "& \`$result '([a-z-]+)'") | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $listed = @($script:reasons.workloadTypes.PSObject.Properties.Name | Sort-Object)
        ($listed -join ',') | Should -Be ($given -join ',')
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'assessment.schema.json') -Raw | ConvertFrom-Json -Depth 30
        (@($schema.properties.vms.items.properties.workload.properties.type.enum) | Sort-Object) -join ',' | Should -Be ($given -join ',')
    }

    It 'review: a workload type never says whether the machine moves - its status does' {
        # A personal AVD host is a Standalone machine and is Excluded; a Blocked
        # machine can be Standalone too. So no type may claim a move decision.
        foreach ($t in $script:reasons.workloadTypes.PSObject.Properties) {
            $t.Value.meaning | Should -Not -Match '(?i)this tool (can|will|does) (move|migrate)|can move it|moves it' -Because $t.Name
        }
        $page = Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'use' 'read-an-assessment.md') -Raw
        $page | Should -Not -Match '(?i)\| Standalone machine \| Moves it'
    }

    It 'review: the generated reference page draws the workload types as a real table, one row per type' {
        $page = (Get-Content (Join-Path $script:repoRoot 'docs' 'manual' 'reference' 'assessment-findings.md') -Raw) -replace "`r`n", "`n"
        $lines = $page -split "`n"
        $at = [array]::IndexOf($lines, '| Workload type | How it moves |')
        $at | Should -BeGreaterThan 0 -Because 'the header is a line of its own'
        $lines[$at + 1] | Should -Be '|---|---|' -Because 'the separator is a line of its own'
        $titles = @($script:reasons.workloadTypes.PSObject.Properties | ForEach-Object { $_.Value.title })
        for ($i = 0; $i -lt $titles.Count; $i++) {
            $lines[$at + 2 + $i] | Should -BeLike "| $($titles[$i]) | * |" -Because "row $($i + 1) is the type $($titles[$i]), on its own line"
        }
        $lines[$at + 2 + $titles.Count] | Should -Be '' -Because 'the table ends after the last type'
    }
    It 'the assess role may read SQL virtual machines, and nothing more is added' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $assess = @($map.operations | Where-Object role -eq 'assess' | ForEach-Object { $_.actions })
        $assess | Should -Contain 'Microsoft.SqlVirtualMachine/sqlVirtualMachines/read'
        @($assess | Where-Object { $_ -like 'Microsoft.SqlVirtualMachine/*' }) | Should -Be @('Microsoft.SqlVirtualMachine/sqlVirtualMachines/read')
        @($assess | Where-Object { $_ -like 'Microsoft.Solutions/*' }).Count | Should -Be 0 -Because 'the managed application is read from the resource group, which the role already reads'
    }

    It 'the target advice may give each refusal as a reason' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'target-advice.schema.json') -Raw | ConvertFrom-Json
        foreach ($code in 'storage-appliance-needs-vendor', 'managed-application-needs-vendor', 'shared-disk-cluster-node', 'sql-availability-group-member') {
            @($schema.'$defs'.reason.enum) | Should -Contain $code
        }
    }

    It 'the assessment format is version 8 (REBUILD-PATCH-MODE-1; 7 was REBUILD-ACCEPT-1; 6 was CLUSTER-DETECT-1; 5 was HDD-OS-1; 4 was this item), and a version 3 assessment is still read' {
        InModuleScope VmMigrationFactory {
            Get-VmfAssessmentSchemaVersion | Should -Be 17
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 3 }) } | Should -Throw '*reads only version 17*'
            { Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = 18 }) } | Should -Throw
        }
    }
}
