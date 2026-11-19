#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# CLUSTER-DETECT-1, 2026-10-31. A cluster node that Azure has no record of was
# moved as if it were alone: the scan blocked an availability group member
# only when Azure built the group (a SQL virtual machine group), so a group
# built by hand, SQL Server from media, a Pacemaker cluster and a Windows
# failover cluster with no shared disk were all "standalone".
#
# The ruling (2026-10-26, made wider 2026-10-27):
#   - a standalone SQL Server machine moves; its warning stays;
#   - ANY cluster node is blocked, not only a SQL Server node;
#   - no elevated or risky access is asked for to find one.
# So two parts:
#   (a) the scan: read-only HINTS from facts it already may read - a load
#       balancer backend pool on the network interface, more than one IP
#       configuration, the SqlIaaSAgent extension. A hint is a warning,
#       "may be a cluster node, confirm" - never a block, and never
#       "standalone" with certainty.
#   (b) Checking: a read-only guest script, before any safety copy or stop,
#       reports facts, and the ENGINE judges them. ClusSvc running or the key
#       HKLM\Cluster on Windows, pacemaker or corosync active on Linux, is a
#       cluster node, whatever runs on it. The SQL reads only name the kind.
#       A check that cannot run is UNKNOWN, never "not a cluster node".
BeforeDiscovery {
    # TEST-BASH-WSL-1: the -Skip of the bash test is read at discovery.
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    $script:testBash = Get-VmfTestBash
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '00000000-0000-0000-0000-000000000000'
    $script:nicId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Network/networkInterfaces/vm1-nic"
    $script:poolId = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Network/loadBalancers/lb-sql/backendAddressPools/pool1"

    # One inventory row, in the shape the discovery query projects it.
    function Global:CdRow {
        param([string]$Name = 'vm1', [string[]]$NicIds = @(), [string[]]$DataDiskIds = @(), [string]$Publisher = 'MicrosoftWindowsServer')
        $sub = '00000000-0000-0000-0000-000000000000'
        $nics = @(for ($i = 0; $i -lt $NicIds.Count; $i++) {
            [pscustomobject]@{ id = $NicIds[$i]; properties = [pscustomobject]@{ primary = ($i -eq 0) } } })
        $disks = @(for ($i = 0; $i -lt $DataDiskIds.Count; $i++) {
            [pscustomobject]@{ lun = $i; name = "d$i"; createOption = 'Attach'; caching = 'None'
                managedDisk = [pscustomobject]@{ id = $DataDiskIds[$i]; storageAccountType = 'Premium_LRS' } } })
        [pscustomobject]@{
            id = "/subscriptions/$sub/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/$Name"
            name = $Name; resourceGroup = 'rg-app'; location = 'centralus'; zones = $null
            sku = 'Standard_D2ds_v4'; os = 'Windows'; gen = 'V2'; diskController = 'SCSI'
            osName = 'Windows Server 2022 Datacenter'
            imagePublisher = $Publisher; imageOffer = 'WindowsServer'; imageSku = '2022-datacenter-g2'; imageId = ''
            communityGalleryImageId = ''; sharedGalleryImageId = ''; planPublisher = ''; planProduct = ''
            vmssId = ''; hibernationEnabled = $false; securityType = ''; dataDiskCount = $disks.Count; dataDisks = $disks
            nicCount = $nics.Count; nicIds = $nics
            tags = $null; identityType = 'None'; identityPrincipalId = ''
            adeOsDiskEnabled = ''; licenseType = ''; osDiskManagedId = "/subscriptions/$sub/resourceGroups/rg-app/providers/Microsoft.Compute/disks/$Name-os"
        }
    }
    function Global:CdSku {
        [pscustomobject]@{
            Name = 'Standard_D2ds_v4'; ResourceType = 'virtualMachines'; Family = 'StandardDDSv4Family'
            Capabilities = @([pscustomobject]@{ Name = 'MaxResourceVolumeMB'; Value = '76800' }, [pscustomobject]@{ Name = 'vCPUs'; Value = '2' })
            Restrictions = @()
        }
    }
    # Every lookup read, nothing found: the facts of an ordinary estate. The
    # network interface and the extension lists are read too.
    function Global:CdKnown {
        param([hashtable]$Over = @{})
        $facts = @{
            SapSystemVms = @{}; AvdSessionHosts = @{}; AvdPoolTypes = @{}; ManagedPlatformGroups = @{}
            SqlVms = @{}; DiskShares = @{}; NicClusterHints = @{}; SqlAgentVms = @{}
            ResourceGroupOwners = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }
        }
        foreach ($k in $Over.Keys) { $facts[$k] = $Over[$k] }
        $facts
    }
    function Global:CdNicHint([int]$IpConfigs = 1, [string[]]$Pools = @()) { @{ ipConfigCount = $IpConfigs; pools = @($Pools) } }
}
AfterAll { Remove-Item 'function:\CdRow', 'function:\CdSku', 'function:\CdKnown', 'function:\CdNicHint' -ErrorAction SilentlyContinue }

Describe 'CLUSTER-DETECT-1 (a): the scan gives a hint, a warning to confirm, never a block' {

    It 'a network interface in a load balancer backend pool: may be a cluster node, and the pool is named' {
        $hints = @{ $script:nicId.ToLowerInvariant() = (CdNicHint -Pools @($script:poolId)) }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $hints }); nic = $script:nicId; pool = $script:poolId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            @($rec.warnings) | Should -Contain 'cluster-node-confirm'
            $rec.workload.type | Should -Be 'may-be-cluster-node'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'ipConfigurations.loadBalancerBackendAddressPools' }).value | Should -Be $pool
            # A hint never blocks.
            @($rec.blockers).Count | Should -Be 0
            $rec.classification | Should -Be 'ReadyAfterPrep'
        }
    }

    It 'more than one IP configuration on a network interface: may be a cluster node, and the count is named' {
        $hints = @{ $script:nicId.ToLowerInvariant() = (CdNicHint -IpConfigs 3) }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $hints }); nic = $script:nicId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            @($rec.warnings) | Should -Contain 'cluster-node-confirm'
            $rec.workload.type | Should -Be 'may-be-cluster-node'
            $ev = @($rec.workload.evidence | Where-Object { $_.field -eq 'networkInterface.ipConfigurations' })
            $ev.Count | Should -Be 1
            $ev[0].value | Should -Match '^3 '
            $ev[0].value | Should -Match 'vm1-nic'
        }
    }

    It 'exactly one IP configuration is an ordinary interface' {
        $hints = @{ $script:nicId.ToLowerInvariant() = (CdNicHint -IpConfigs 1) }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $hints }); nic = $script:nicId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            @($rec.warnings) | Should -Not -Contain 'cluster-node-confirm'
            $rec.workload.type | Should -Be 'standalone-vm'
        }
    }

    It 'the SqlIaaSAgent extension: may be a cluster node' {
        $vmKey = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1".ToLowerInvariant()
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ SqlAgentVms = @{ $vmKey = 'SqlIaaSAgent' } }) } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow) -SkuEntry (CdSku) @f
            @($rec.warnings) | Should -Contain 'cluster-node-confirm'
            $rec.workload.type | Should -Be 'may-be-cluster-node'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'extensions.type' }).value | Should -Be 'SqlIaaSAgent'
        }
    }

    It 'a standalone SQL Server machine keeps its warning, and the hint is shown beside it' {
        $vmKey = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1".ToLowerInvariant()
        $sql = @{ $vmKey = @{ id = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines/vm1"; groupId = ''; offer = 'SQL2022-WS2022'; sku = 'Standard' } }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ SqlVms = $sql; SqlAgentVms = @{ $vmKey = 'SqlIaaSAgent' } }) } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow) -SkuEntry (CdSku) @f
            @($rec.warnings) | Should -Contain 'sql-server-agree-downtime'
            @($rec.warnings) | Should -Contain 'cluster-node-confirm'
            # A fact Azure records wins the type; the hint is evidence beside it.
            $rec.workload.type | Should -Be 'cluster-or-database'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'extensions.type' }).Count | Should -Be 1
            $rec.classification | Should -Be 'ReadyAfterPrep'
        }
    }

    It 'a machine the scan already blocks as a cluster node gets no hint to confirm' {
        $disk = "/subscriptions/$($script:sub)/resourceGroups/rg-app/providers/Microsoft.Compute/disks/quorum"
        $hints = @{ $script:nicId.ToLowerInvariant() = (CdNicHint -IpConfigs 2) }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $hints; DiskShares = @{ $disk.ToLowerInvariant() = 2 } }); nic = $script:nicId; d = $disk } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic) -DataDiskIds @($d)) -SkuEntry (CdSku) @f
            @($rec.blockers) | Should -Contain 'shared-disk-cluster-node'
            @($rec.warnings) | Should -Not -Contain 'cluster-node-confirm'
            $rec.workload.type | Should -Be 'cluster-or-database'
        }
    }

    It 'nothing fires on an ordinary machine: one interface, one IP configuration, no pool, no extension' {
        $hints = @{ $script:nicId.ToLowerInvariant() = (CdNicHint) }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $hints }); nic = $script:nicId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            @($rec.warnings) | Should -Be @('mana-driver-download')
            $rec.workload.type | Should -Be 'standalone-vm'
            @($rec.workload.evidence).Count | Should -Be 0
        }
    }

    It 'the network interfaces not read: UNKNOWN - not checked, never standalone, never a hint' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $null }); nic = $script:nicId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            $rec.workload.type | Should -Be 'not-checked'
            @($rec.warnings) | Should -Contain 'workload-type-not-checked'
            @($rec.warnings) | Should -Not -Contain 'cluster-node-confirm'
            $miss = @($rec.workload.evidence | Where-Object { $_.field -eq 'networkInterface.ipConfigurations' })
            $miss.Count | Should -Be 1
            $miss[0].value | Should -BeNullOrEmpty
        }
    }

    It 'one interface the read did not return: UNKNOWN too' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown); nic = $script:nicId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            $rec.workload.type | Should -Be 'not-checked'
        }
    }

    It 'the extension list not read: UNKNOWN' {
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ SqlAgentVms = $null }) } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow) -SkuEntry (CdSku) @f
            $rec.workload.type | Should -Be 'not-checked'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'extensions.type' -and $null -eq $_.value }).Count | Should -Be 1
        }
    }

    It 'a hint AND a fact not read: not checked wins the type, and the hint warning still shows' {
        $hints = @{ $script:nicId.ToLowerInvariant() = (CdNicHint -IpConfigs 2) }
        InModuleScope VmMigrationFactory -Parameters @{ f = (CdKnown -Over @{ NicClusterHints = $hints; SqlVms = $null }); nic = $script:nicId } {
            $rec = Get-VmfAssessmentRecord -Vm (CdRow -NicIds @($nic)) -SkuEntry (CdSku) @f
            $rec.workload.type | Should -Be 'not-checked'
            @($rec.warnings) | Should -Contain 'workload-type-not-checked'
            @($rec.warnings) | Should -Contain 'cluster-node-confirm'
            @($rec.workload.evidence | Where-Object { $_.field -eq 'networkInterface.ipConfigurations' }).value | Should -Match '^2 '
        }
    }
}

Describe 'CLUSTER-DETECT-1 (a): the reads, with the access the scan already has' {

    It 'one Resource Graph read of the network interfaces gives accelerated networking AND the hints' {
        InModuleScope VmMigrationFactory -Parameters @{ nic = $script:nicId; pool = $script:poolId } {
            Mock Invoke-VmfResourceGraphQuery {
                @{ data = @(
                        [pscustomobject]@{ id = $nic; accelerated = $true; ipConfigurations = @(
                                [pscustomobject]@{ name = 'ipconfig1'; properties = [pscustomobject]@{ loadBalancerBackendAddressPools = @([pscustomobject]@{ id = $pool }) } },
                                [pscustomobject]@{ name = 'ipconfig2'; properties = [pscustomobject]@{ } }) }
                        [pscustomobject]@{ id = '/x/nic-plain'; accelerated = $false; ipConfigurations = @([pscustomobject]@{ name = 'ipconfig1'; properties = [pscustomobject]@{ } }) })
                   '$skipToken' = $null }
            }
            $r = Get-VmfNicFacts -Subscriptions @('S')
            Should -Invoke Invoke-VmfResourceGraphQuery -Times 1 -Exactly
            $r.Accelerated[$nic.ToLowerInvariant()] | Should -BeTrue
            $r.Accelerated['/x/nic-plain'] | Should -BeFalse
            $r.ClusterHints[$nic.ToLowerInvariant()].ipConfigCount | Should -Be 2
            @($r.ClusterHints[$nic.ToLowerInvariant()].pools) | Should -Be @($pool)
            $r.ClusterHints['/x/nic-plain'].ipConfigCount | Should -Be 1
            @($r.ClusterHints['/x/nic-plain'].pools).Count | Should -Be 0
        }
    }

    It 'the query reads the IP configurations of the interface, and never the load balancer' {
        InModuleScope VmMigrationFactory {
            $q = $script:VmfArgNicQuery
            $q | Should -Match "networkinterfaces"
            $q | Should -Match 'ipConfigurations = properties\.ipConfigurations'
            $q | Should -Not -Match '(?i)microsoft\.network/loadbalancers'
        }
    }

    It 'the SqlIaaSAgent extension, by its publisher and type, keyed by the machine' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery {
                @{ data = @([pscustomobject]@{ id = '/subscriptions/S/resourceGroups/R/providers/Microsoft.Compute/virtualMachines/SQL1/extensions/SqlIaaSExtension'; extType = 'SqlIaaSAgent' })
                   '$skipToken' = $null }
            }
            $r = Get-VmfSqlIaaSAgentVmIds -Subscriptions @('S')
            $r.Verified | Should -BeTrue
            $r.Ids['/subscriptions/s/resourcegroups/r/providers/microsoft.compute/virtualmachines/sql1'] | Should -Be 'SqlIaaSAgent'
            $q = $script:VmfSqlAgentExtensionQuery
            $q | Should -Match "microsoft\.compute/virtualmachines/extensions"
            $q | Should -Match 'Microsoft\.SqlServer\.Management'
            $q | Should -Match "'SqlIaaSAgent'"
            $q | Should -Match "'SqlIaaSAgentLinux'"
        }
    }

    It 'an extension read that fails is not verified - the caller reads it as unknown' {
        InModuleScope VmMigrationFactory {
            Mock Invoke-VmfResourceGraphQuery { throw 'Resource Graph did not answer.' }
            $r = Get-VmfSqlIaaSAgentVmIds -Subscriptions @('S')
            $r.Verified | Should -BeFalse
            $r.Detail | Should -Match 'did not answer'
        }
    }

    It 'neither read is a new permission: the assessment role already holds both, and nothing reads a load balancer' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $assess = @($map.operations | Where-Object role -EQ 'assess' | ForEach-Object { $_.actions })
        $assess | Should -Contain 'Microsoft.Network/networkInterfaces/read'
        $assess | Should -Contain 'Microsoft.Compute/virtualMachines/extensions/read'
        @($map.operations | ForEach-Object { $_.actions } | Where-Object { $_ -like 'Microsoft.Network/loadBalancers/read' }).Count | Should -Be 0
    }
}

Describe 'CLUSTER-DETECT-1 (a): the scan writes the hints, and a read that fails is said, not hidden' {
    BeforeAll {
        function Global:CdScan {
            param([scriptblock]$Nic, [scriptblock]$Agent, [object[]]$Rows)
            InModuleScope VmMigrationFactory -Parameters @{ nic = $Nic; agent = $Agent; rows = $Rows } {
                Mock Get-VmfFleetInventory { , @($rows) }
                Mock Get-VmfSkuCatalog { , @() }
                Mock Get-VmfMachineImageNvme { @{ Nvme = $null; Note = $null } }
                Mock Get-VmfNicFacts $nic
                Mock Get-VmfSqlIaaSAgentVmIds $agent
                Mock Get-VmfAvdSessionHostIds { @{ Ids = @{}; PoolTypes = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfSapSystemVmIds { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfManagedPlatformGroups { @{ Groups = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfSqlVirtualMachines { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfDiskShareMap { @{ Disks = @{}; Verified = $true; Detail = 'mocked' } }
                Mock Get-VmfResourceGroupOwners { @{ Groups = @{ '00000000-0000-0000-0000-000000000000/rg-app' = '' }; Verified = $true; Detail = 'mocked' } }
                $out = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                try {
                    Invoke-VmfAssessment -Scope @{ Subscriptions = @('00000000-0000-0000-0000-000000000000') } -OutPath $out | Out-Null
                    Get-Content (Join-Path $out 'assessment.json') -Raw | ConvertFrom-Json -Depth 20
                }
                finally { if (Test-Path $out) { Remove-Item $out -Recurse -Force -ErrorAction SilentlyContinue } }
            }
        }
    }
    AfterAll { Remove-Item 'function:\CdScan' -ErrorAction SilentlyContinue }

    It 'a scan that reads them writes the type, the evidence and the warning, as assessment version 6' {
        $nicKey = $script:nicId.ToLowerInvariant()
        $doc = CdScan -Rows @((CdRow -NicIds @($script:nicId)), (CdRow -Name 'plain')) `
            -Nic ([scriptblock]::Create("@{ Accelerated = @{ '$nicKey' = `$true }; ClusterHints = @{ '$nicKey' = @{ ipConfigCount = 2; pools = @() } } }")) `
            -Agent { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
        $doc.schemaVersion | Should -Be 17 -Because 'CLUSTER-DETECT-1 made it 6, REBUILD-ACCEPT-1 7, REBUILD-PATCH-MODE-1 8, DCR-READ-1 9, ALREADY-CURRENT-1 10, READY-NOW-REMOVE-1 11, REBUILD-REMOVE-ROLE-1 12, CRG-MOVE-DEMAND-1 13, SCAN-PARTIAL-SUBS-1 14, REBUILD-REMOVE-SCAN-EXT-1 15, DRIFT-12 16'
        $node = @($doc.vms | Where-Object name -EQ 'vm1')[0]
        $node.workload.type | Should -Be 'may-be-cluster-node'
        @($node.warnings) | Should -Contain 'cluster-node-confirm'
        $node.primaryNicAccelerated | Should -BeTrue -Because 'the same read still gives accelerated networking'
        $plain = @($doc.vms | Where-Object name -EQ 'plain')[0]
        $plain.workload.type | Should -Be 'standalone-vm'
        @($doc.notRead).Count | Should -Be 0
    }

    It 'a failed interface read: the scan goes on, says what it did not read, and calls no machine standalone' {
        $doc = CdScan -Rows @((CdRow -NicIds @($script:nicId))) -Nic { throw 'Resource Graph did not answer.' } `
            -Agent { @{ Ids = @{}; Verified = $true; Detail = 'mocked' } }
        @($doc.notRead | ForEach-Object subject) | Should -Contain 'acceleratedNetworking'
        @($doc.notRead | ForEach-Object subject) | Should -Contain 'clusterHints'
        $doc.vms[0].workload.type | Should -Be 'not-checked'
    }

    It 'a failed extension read: the same' {
        $nicKey = $script:nicId.ToLowerInvariant()
        $doc = CdScan -Rows @((CdRow -NicIds @($script:nicId))) `
            -Nic ([scriptblock]::Create("@{ Accelerated = @{ '$nicKey' = `$false }; ClusterHints = @{ '$nicKey' = @{ ipConfigCount = 1; pools = @() } } }")) `
            -Agent { @{ Ids = @{}; Verified = $false; Detail = 'could not read' } }
        @($doc.notRead | ForEach-Object subject) | Should -Contain 'clusterHints'
        @($doc.notRead | ForEach-Object subject) | Should -Not -Contain 'acceleratedNetworking'
        $doc.vms[0].workload.type | Should -Be 'not-checked'
    }
}

Describe 'CLUSTER-DETECT-1 (b): the engine judges the facts the guest reports' {

    BeforeAll {
        function Global:CdOut([hashtable]$Facts, [string]$Result = 'READY', [string]$ErrorText = '') {
            $o = [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'x'; version = '1.0.0'; result = $Result; checks = @(); facts = [pscustomobject]$Facts; warnings = @() }
            if ($ErrorText) { $o | Add-Member -NotePropertyName error -NotePropertyValue $ErrorText }
            $o
        }
    }
    AfterAll { Remove-Item 'function:\CdOut' -ErrorAction SilentlyContinue }

    It 'Windows: <Name>' -TestCases @(
        @{ Name = 'ClusSvc running is a cluster node'; Svc = 'running'; Key = 'no'; Sql = 'no'; Want = 'node' }
        @{ Name = 'the key HKLM\Cluster alone is a cluster node'; Svc = 'installed'; Key = 'yes'; Sql = 'no'; Want = 'node' }
        @{ Name = 'the key with ClusSvc absent is a cluster node'; Svc = 'absent'; Key = 'yes'; Sql = 'no'; Want = 'node' }
        @{ Name = 'ClusSvc installed and not running, no key, is not a node'; Svc = 'installed'; Key = 'no'; Sql = 'no'; Want = 'not-a-node' }
        @{ Name = 'nothing at all is not a node'; Svc = 'absent'; Key = 'no'; Sql = 'no'; Want = 'not-a-node' }
        @{ Name = 'HADR_Enabled alone does not decide: not a node'; Svc = 'absent'; Key = 'no'; Sql = 'yes'; Want = 'not-a-node' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ o = (CdOut @{ os = 'Windows'; clusterService = $Svc; clusterKey = $Key; sqlHadr = $Sql }); want = $Want } {
            (Get-VmfClusterNodeVerdict -Os 'Windows' -GuestOutput $o).Verdict | Should -Be $want
        }
    }

    It 'Linux: <Name>' -TestCases @(
        @{ Name = 'pacemaker active is a cluster node'; Pm = 'active'; Cs = 'inactive'; Sql = 'no'; Want = 'node' }
        @{ Name = 'corosync active is a cluster node'; Pm = 'inactive'; Cs = 'active'; Sql = 'no'; Want = 'node' }
        @{ Name = 'pacemaker starting is a cluster node'; Pm = 'activating'; Cs = 'inactive'; Sql = 'no'; Want = 'node' }
        @{ Name = 'both inactive is not a node'; Pm = 'inactive'; Cs = 'inactive'; Sql = 'no'; Want = 'not-a-node' }
        @{ Name = 'both failed is not a node'; Pm = 'failed'; Cs = 'failed'; Sql = 'no'; Want = 'not-a-node' }
        @{ Name = 'hadr.hadrenabled alone does not decide: not a node'; Pm = 'inactive'; Cs = 'inactive'; Sql = 'yes'; Want = 'not-a-node' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ o = (CdOut @{ os = 'Linux'; pacemaker = $Pm; corosync = $Cs; sqlHadr = $Sql }); want = $Want } {
            (Get-VmfClusterNodeVerdict -Os 'Linux' -GuestOutput $o).Verdict | Should -Be $want
        }
    }

    It 'the SQL read names the kind of cluster in the reason, on both systems' {
        InModuleScope VmMigrationFactory -Parameters @{
            w = (CdOut @{ os = 'Windows'; clusterService = 'running'; clusterKey = 'yes'; sqlHadr = 'yes' })
            wn = (CdOut @{ os = 'Windows'; clusterService = 'running'; clusterKey = 'yes'; sqlHadr = 'no' })
            l = (CdOut @{ os = 'Linux'; pacemaker = 'active'; corosync = 'active'; sqlHadr = 'yes' }) } {
            $win = Get-VmfClusterNodeVerdict -Os 'Windows' -GuestOutput $w
            $win.Detail | Should -Match 'Windows Server failover cluster'
            $win.Detail | Should -Match 'HADR_Enabled'
            $win.Detail | Should -Match 'availability group'
            (Get-VmfClusterNodeVerdict -Os 'Windows' -GuestOutput $wn).Detail | Should -Not -Match 'availability group'
            $lin = Get-VmfClusterNodeVerdict -Os 'Linux' -GuestOutput $l
            $lin.Detail | Should -Match 'Pacemaker'
            $lin.Detail | Should -Match 'hadr\.hadrenabled'
        }
    }

    It 'UNKNOWN, never "not a node": <Name>' -TestCases @(
        @{ Name = 'no answer'; Os = 'Windows'; Facts = $null; Result = 'READY' }
        @{ Name = 'the script reported BLOCKED'; Os = 'Windows'; Facts = @{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no' }; Result = 'BLOCKED' }
        @{ Name = 'Windows with no clusterService fact'; Os = 'Windows'; Facts = @{ os = 'Windows'; clusterKey = 'no' }; Result = 'READY' }
        @{ Name = 'Windows with no clusterKey fact'; Os = 'Windows'; Facts = @{ os = 'Windows'; clusterService = 'absent' }; Result = 'READY' }
        @{ Name = 'Windows with a value it does not know'; Os = 'Windows'; Facts = @{ os = 'Windows'; clusterService = 'paused'; clusterKey = 'no' }; Result = 'READY' }
        @{ Name = 'Linux with no corosync fact'; Os = 'Linux'; Facts = @{ os = 'Linux'; pacemaker = 'inactive' }; Result = 'READY' }
        @{ Name = 'Linux with no pacemaker fact'; Os = 'Linux'; Facts = @{ os = 'Linux'; corosync = 'inactive' }; Result = 'READY' }
        @{ Name = 'an operating system it does not know'; Os = 'Plan9'; Facts = @{ os = 'Plan9' }; Result = 'READY' }
    ) {
        $o = if ($null -eq $Facts) { $null } else { CdOut -Facts $Facts -Result $Result -ErrorText 'read failed' }
        InModuleScope VmMigrationFactory -Parameters @{ o = $o; os = $Os } {
            (Get-VmfClusterNodeVerdict -Os $os -GuestOutput $o).Verdict | Should -Be 'unknown'
        }
    }
}

Describe 'CLUSTER-DETECT-1 (b): Checking stops a cluster node before anything changes' {
    BeforeAll {
        $script:cdVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
        function Global:CdCtx([string]$Os = 'Windows') {
            @{ Plan = [pscustomobject]@{ assessment = [pscustomobject]@{ os = $Os } }
               Rg = 'rg'; VmName = 'vm'; VmId = $script:cdVm; RunPath = $script:cdRun }
        }
        function Global:CdNode([string]$Os = 'Windows') {
            if ($Os -eq 'Windows') {
                [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                    facts = [pscustomobject]@{ os = 'Windows'; clusterService = 'running'; clusterKey = 'yes'; sqlHadr = 'no' } }
            }
            else {
                [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'cluster-node-check.sh'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                    facts = [pscustomobject]@{ os = 'Linux'; pacemaker = 'active'; corosync = 'active'; sqlHadr = 'yes' } }
            }
        }
        function Global:CdAlone {
            [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                facts = [pscustomobject]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } }
        }
        function Global:CdRecord {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:cdRun; id = $script:cdVm } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                if ($d.captured -and $d.captured.PSObject.Properties['clusterCheckPower']) { $d.captured.clusterCheckPower } else { $null }
            }
        }
    }
    AfterAll { Remove-Item 'function:\CdCtx', 'function:\CdNode', 'function:\CdAlone', 'function:\CdRecord' -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:cdRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cd-sm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:cdRun; id = $script:cdVm } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'cd' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'cd' -VmId $id | Out-Null
        }
        $global:cdRan = [System.Collections.Generic.List[string]]::new()
        $global:cdAnswer = $null
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:cdRan.Add($ScriptName)
            if ($global:cdAnswer -is [scriptblock]) { & $global:cdAnswer } else { $global:cdAnswer }
        }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { }
    }
    AfterEach {
        Remove-Variable cdRan, cdAnswer -Scope Global -ErrorAction SilentlyContinue
        if ($script:cdRun -and (Test-Path $script:cdRun)) { [System.IO.Directory]::Delete($script:cdRun, $true) }
    }

    It 'a running Windows cluster node stops at Checking, untouched, out of scope - the Windows script, and no start' {
        $global:cdAnswer = CdNode
        InModuleScope VmMigrationFactory -Parameters @{ c = (CdCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running'
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'clusterNode'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'ClusSvc'
            Should -Invoke Start-VmfVm -Times 0 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
        @($global:cdRan) | Should -Be @('Test-ClusterNode.ps1')
        CdRecord | Should -BeNullOrEmpty -Because 'a machine that was running is not started, so there is nothing to put back'
    }

    It 'a Linux cluster node: the Linux script' {
        $global:cdAnswer = CdNode -Os 'Linux'
        InModuleScope VmMigrationFactory -Parameters @{ c = (CdCtx -Os 'Linux') } {
            (Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running').Reason | Should -Be 'clusterNode'
        }
        @($global:cdRan) | Should -Be @('cluster-node-check.sh')
    }

    It 'a machine that is not a node goes on, and the facts are written down' {
        $global:cdAnswer = CdAlone
        InModuleScope VmMigrationFactory -Parameters @{ c = (CdCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' | Should -BeNullOrEmpty
            Should -Invoke Write-VmfStepLine -Times 1 -ParameterFilter { $Outcome -eq 'info' -and $Detail -match 'not a cluster node' }
        }
    }

    It 'a check that answers BLOCKED is unknown: the machine stops, untouched, parked like every cluster stop, and is never called alone' {
        $global:cdAnswer = [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'BLOCKED'; checks = @()
            facts = [pscustomobject]@{ os = 'Windows' }; warnings = @(); error = 'WMI did not answer' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (CdCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running'
            $stop.Reason | Should -Be 'clusterNodeNotChecked'
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'WMI did not answer'
        }
    }

    It 'an operating system the plan does not name parks the same way' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (CdCtx -Os '') } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running'
            $stop.Reason | Should -Be 'clusterNodeNotChecked'
            $stop.Next | Should -Be 'NEEDS_DECISION'
        }
    }

    It 'on a running machine, a Run Command that fails is the product''s existing rule: the error goes up to the step, never a pass' {
        $global:cdAnswer = { throw 'RunCommand on vm returned no result - verify the VM is running.' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (CdCtx) } {
            { Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' } | Should -Throw '*returned no result*'
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
    }
}

Describe 'CLUSTER-NOT-RUNNING-1: a machine that is not running is started for the check, and put back when it must not move' {
    BeforeAll {
        $script:cdVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
        function Global:NrCtx { @{ Plan = [pscustomobject]@{ assessment = [pscustomobject]@{ os = 'Windows' } }; Rg = 'rg'; VmName = 'vm'; VmId = $script:cdVm; RunPath = $script:cdRun } }
        function Global:NrNode {
            [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                facts = [pscustomobject]@{ os = 'Windows'; clusterService = 'running'; clusterKey = 'yes'; sqlHadr = 'no' } }
        }
        function Global:NrAlone {
            [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                facts = [pscustomobject]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } }
        }
        function Global:NrRecord {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:cdRun; id = $script:cdVm } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                if ($d.captured -and $d.captured.PSObject.Properties['clusterCheckPower']) { $d.captured.clusterCheckPower } else { $null }
            }
        }
    }
    AfterAll { Remove-Item 'function:\NrCtx', 'function:\NrNode', 'function:\NrAlone', 'function:\NrRecord' -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:cdRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cd-nr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:cdRun; id = $script:cdVm } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'cd' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'cd' -VmId $id | Out-Null
        }
        $global:nr = @{ answer = $null; atStart = 'not called'; startFails = $null; agentFails = $null; putBackFails = $null; ran = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:nr.ran.Add($ScriptName)
            if ($global:nr.answer -is [scriptblock]) { & $global:nr.answer } else { $global:nr.answer }
        }
        # The record as it stands when the start is issued: written first.
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            $global:nr.atStart = NrRecord
            if ($global:nr.startFails) { throw $global:nr.startFails }
        }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { if ($global:nr.agentFails) { throw $global:nr.agentFails } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { if ($global:nr.putBackFails) { throw $global:nr.putBackFails } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { if ($global:nr.putBackFails) { throw $global:nr.putBackFails } }
        # POWER-ONLY-CHANGED-1: the put-back to stopped is the one rule of
        # Restore-VmfPowerAsFound now (Invoke-VmfPowerPutBack): it reads the
        # power state first, and starts a machine that is deallocated before it
        # stops it. The machine this check started is running.
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
    }
    AfterEach {
        Remove-Variable nr -Scope Global -ErrorAction SilentlyContinue
        if ($script:cdRun -and (Test-Path $script:cdRun)) { [System.IO.Directory]::Delete($script:cdRun, $true) }
    }

    It 'a deallocated cluster node: written down, started, checked, deallocated again, and stopped untouched' {
        $global:nr.answer = NrNode
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated'
            $stop.Reason | Should -Be 'clusterNode'
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'deallocated again'
            Should -Invoke Start-VmfVm -Times 1 -Exactly
            Should -Invoke Wait-VmfVmAgentReady -Times 1 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
            Should -Invoke Stop-VmfVmPoweredOff -Times 0 -Exactly
        }
        $global:nr.atStart.power | Should -Be 'PowerState/deallocated' -Because 'the power state is written down before the start'
        $global:nr.atStart.status | Should -Be 'started'
        @($global:nr.ran) | Should -Be @('Test-ClusterNode.ps1')
        (NrRecord).status | Should -Be 'putBack'
    }

    It 'a stopped machine whose check gives no answer goes back to stopped, not deallocated, and stops untouched' {
        $global:nr.answer = [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'Test-ClusterNode.ps1'; version = '1.0.0'; result = 'BLOCKED'; checks = @(); warnings = @()
            facts = [pscustomobject]@{ os = 'Windows' }; error = 'WMI did not answer' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/stopped'
            $stop.Reason | Should -Be 'clusterNodeNotChecked'
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'stopped again'
            Should -Invoke Stop-VmfVmPoweredOff -Times 1 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
    }

    It 'a deallocated machine that is not a cluster node goes on, running, and is not put back' {
        $global:nr.answer = NrAlone
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' | Should -BeNullOrEmpty
            Should -Invoke Start-VmfVm -Times 1 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
        (NrRecord).status | Should -Be 'goingOn'
        (NrRecord).power | Should -Be 'PowerState/deallocated'
    }

    It 'a start that fails: the machine is put back, it stops unknown, and no script runs' {
        $global:nr.startFails = 'VM vm did not reach PowerState/running within 360s.'
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated'
            $stop.Reason | Should -Be 'clusterNodeNotChecked'
            $stop.Detail | Should -Match 'did not reach PowerState/running'
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
        }
        @($global:nr.ran).Count | Should -Be 0
    }

    It 'a Run Command that fails on a machine the check started: put back, then stopped - never left running' {
        $global:nr.answer = { throw 'RunCommand on vm returned no result - verify the VM is running.' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated'
            $stop.Reason | Should -Be 'clusterNodeNotChecked'
            $stop.Detail | Should -Match 'returned no result'
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
        }
    }

    It 'a put-back that fails is said: the stop says the machine is running, and the machine is changed' {
        $global:nr.answer = NrNode
        $global:nr.putBackFails = 'Deallocate was refused.'
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated'
            $stop.Reason | Should -Be 'clusterNode'
            $stop.MachineState | Should -Be 'changed'
            $stop.Detail | Should -Match 'could not make it deallocated again'
            $stop.Detail | Should -Match 'Deallocate was refused'
            $stop.Detail | Should -Match 'running now'
            Should -Invoke Write-VmfStepLine -Times 1 -ParameterFilter { $Outcome -eq 'warn' -and $Detail -match 'could not make it deallocated again' }
        }
        (NrRecord).status | Should -Be 'started' -Because 'the put-back is still owed'
    }

    It 'kill-resume: killed after the start, before the check - the resume reads the record, not the running machine, and puts it back' {
        $global:nr.answer = NrNode
        $global:nr.agentFails = 'Lease lost - abandon this VM'
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            { Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' } | Should -Throw '*abandon this VM*'
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly -Because 'a lost lease touches nothing more'
        }
        (NrRecord).status | Should -Be 'started'
        @($global:nr.ran).Count | Should -Be 0
        # The next worker: the machine reads running, because the check started it.
        $global:nr.agentFails = $null
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running'
            $stop.Reason | Should -Be 'clusterNode'
            $stop.MachineState | Should -Be 'untouched'
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
        }
        $global:nr.atStart.power | Should -Be 'PowerState/deallocated' -Because 'the record of the first worker is kept, never written over with running'
        (NrRecord).status | Should -Be 'putBack'
    }

    It 'kill-resume: killed after the check, before the put-back - the resume checks again and puts it back' {
        $global:nr.answer = NrNode
        $global:nr.putBackFails = 'Lease lost - abandon this VM'
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            { Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' } | Should -Throw '*abandon this VM*'
        }
        (NrRecord).status | Should -Be 'started'
        $global:nr.putBackFails = $null
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running'
            $stop.Reason | Should -Be 'clusterNode'
            $stop.MachineState | Should -Be 'untouched'
        }
        @($global:nr.ran) | Should -Be @('Test-ClusterNode.ps1', 'Test-ClusterNode.ps1') -Because 'the check only reads, so it runs again'
        (NrRecord).status | Should -Be 'putBack'
    }

    It 'a person''s retry from the first step drops the record, so a machine started since is not put back to an old state' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            Save-VmfCapturedFacts -Context $c -Facts @{ clusterCheckPower = [ordered]@{ power = 'PowerState/deallocated'; status = 'goingOn' } }
            Clear-VmfRetryState -RunPath $c.RunPath -VmId $c.VmId -From 'PRECHECK' -NewAttempt
        }
        NrRecord | Should -BeNullOrEmpty
        $global:nr.answer = NrNode
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' | Out-Null
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
    }

    It 'the automatic re-entry keeps the record: a check started earlier in this attempt is still put back' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            Save-VmfCapturedFacts -Context $c -Facts @{ clusterCheckPower = [ordered]@{ power = 'PowerState/deallocated'; status = 'goingOn' } }
            Clear-VmfRetryState -RunPath $c.RunPath -VmId $c.VmId -From 'PRECHECK'
        }
        (NrRecord).status | Should -Be 'goingOn'
        # Checking runs again in the same attempt: the machine reads running
        # because the check started it, and a cluster node goes back to deallocated.
        $global:nr.answer = NrNode
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx) } {
            (Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running').Reason | Should -Be 'clusterNode'
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
        }
    }

    It 'a power state it cannot put back (<Power>) is never started: unknown, untouched, and the stop says what to wait for' -TestCases @(
        @{ Power = 'PowerState/starting' }, @{ Power = 'PowerState/stopping' }, @{ Power = 'PowerState/deallocating' }, @{ Power = '' },
        @{ Power = 'PowerState/unknown' }
    ) {
        $global:nr.answer = NrNode
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx); pw = $Power } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power $pw
            $stop.Reason | Should -Be 'clusterNodeNotChecked'
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.MachineState | Should -Be 'untouched'
            # POWER-WAIT-WORDS-1: never a raw Azure code, never "make it running".
            $stop.Detail | Should -Not -Match 'PowerState'
            $stop.Detail | Should -Not -Match 'Make it'
            $stop.Detail | Should -Match 'then select Try this machine again\. Nothing on the machine changed\.$'
            Should -Invoke Start-VmfVm -Times 0 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
            Should -Invoke Stop-VmfVmPoweredOff -Times 0 -Exactly
        }
        @($global:nr.ran).Count | Should -Be 0
        NrRecord | Should -BeNullOrEmpty
    }

    # POWER-WAIT-WORDS-1, 2026-11-08: the old text ("Make it running")
    # was unclear. Deallocating is the approved
    # sentence, word for word; the others follow its shape with the portal's
    # status words (approved 2026-11-08 - see the item file).
    It 'the stop for a machine in the power state <Power> is, word for word: <Want>' -TestCases @(
        @{ Power = 'PowerState/deallocating'; Want = 'The machine was being deallocated when the check started, so the product did not start it. Wait until Azure shows the machine as Stopped (deallocated), then select Try this machine again. Nothing on the machine changed.' }
        @{ Power = 'PowerState/stopping'; Want = 'The machine was being stopped when the check started, so the product did not start it. Wait until Azure shows the machine as Stopped or Stopped (deallocated), then select Try this machine again. Nothing on the machine changed.' }
        @{ Power = 'PowerState/starting'; Want = 'Azure was starting the machine when the check started, so the product did not run the check. Wait until Azure shows the machine as Running, then select Try this machine again. Nothing on the machine changed.' }
        @{ Power = 'PowerState/unknown'; Want = 'Azure did not show the machine as Running, Stopped or Stopped (deallocated) when the check started, so the product did not start it. Wait until Azure shows one of these states, then select Try this machine again. Nothing on the machine changed.' }
        @{ Power = ''; Want = 'Azure did not show the machine as Running, Stopped or Stopped (deallocated) when the check started, so the product did not start it. Wait until Azure shows one of these states, then select Try this machine again. Nothing on the machine changed.' }
        @{ Power = 'PowerState/creating'; Want = 'Azure did not show the machine as Running, Stopped or Stopped (deallocated) when the check started, so the product did not start it. Wait until Azure shows one of these states, then select Try this machine again. Nothing on the machine changed.' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx); pw = $Power; want = $Want } {
            (Get-VmfWorkloadCheckStop -Context $c -Power $pw).Detail | Should -BeExactly $want
        }
    }

    It 'the activity line for a machine the check starts names the portal status (<Power>), never the Azure code' -TestCases @(
        @{ Power = 'PowerState/deallocated'; Status = 'Stopped (deallocated)' }, @{ Power = 'PowerState/stopped'; Status = 'Stopped' }
    ) {
        $global:nr.answer = NrAlone
        InModuleScope VmMigrationFactory -Parameters @{ c = (NrCtx); pw = $Power; status = $Status } {
            Get-VmfWorkloadCheckStop -Context $c -Power $pw | Out-Null
            Should -Invoke Write-VmfStepLine -Times 1 -Exactly -ParameterFilter {
                $Detail -ceq "Azure shows the machine as $status. The product starts it to run the check that finds a cluster node, and stops it again if the machine must not move."
            }
            Should -Invoke Write-VmfStepLine -Times 0 -Exactly -ParameterFilter { $Detail -match 'PowerState' }
        }
    }

    It 'every action is one the product already holds: start, deallocate and power off are in the execute role' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $execute = @($map.operations | Where-Object role -EQ 'execute' | ForEach-Object { $_.actions })
        foreach ($a in 'Microsoft.Compute/virtualMachines/start/action', 'Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/powerOff/action') {
            $execute | Should -Contain $a
        }
    }
}
Describe 'CLUSTER-DETECT-1 (b): where the check runs, and the scripts that read the machine' {

    It 'PRECHECK runs it once, as the LAST check that can stop the machine - after every other stop, so a machine it starts is never left running at a later one' {
        # Re-review of CLUSTER-NOT-RUNNING-1: a machine the check started and
        # found alone was left running when a later stop parked it.
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $start = $code.IndexOf('function Invoke-VmfStepPrecheck')
        $end = $code.IndexOf('function Get-VmfSafetyAttempt')
        $pre = $code.Substring($start, $end - $start)
        ([regex]::Matches($pre, 'Get-VmfWorkloadCheckStop')).Count | Should -Be 1
        $at = $pre.IndexOf('Get-VmfWorkloadCheckStop')
        $at | Should -BeGreaterThan $pre.IndexOf('$power = ')
        $at | Should -BeGreaterThan $pre.IndexOf("Reason = 'acceleratedNetworkingRequired'")
        $at | Should -BeGreaterThan $pre.IndexOf("Reason = 'captureNotReproducible'")
        $at | Should -BeGreaterThan $pre.IndexOf('Get-VmfIdentityLossGate')
        $at | Should -BeGreaterThan $pre.IndexOf('Get-VmfTempDiskContentStop')
        # After it, nothing returns a stop: the next return is the way on.
        $after = $pre.Substring($at)
        $after = $after.Substring($after.IndexOf('if ($clusterStop) { return $clusterStop }') + 'if ($clusterStop) { return $clusterStop }'.Length)
        @([regex]::Matches($after, '\breturn\b')).Count | Should -Be 1
        $after | Should -Match "return @\{ Next = 'SAFETY_PRISTINE'"
        $pre | Should -Match 'Get-VmfWorkloadCheckStop -Context \$Context -Power \$power'
    }

    It 'the temporary disk check asks the power state found before any start, so a resume after the start does not read the machine as running' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match "if \(\`$powerFound -eq 'PowerState/running'\) \{\s+\`$tempStop = Get-VmfTempDiskContentStop"
        $code | Should -Match 'if \(\$clusterPowerRecord\) \{ \$powerFound = \[string\]\$clusterPowerRecord\.power \}'
    }

    It 'the scripts read only: no service is started or stopped, no registry value or file is written' {
        $win = Get-VmfCodeOnly -Language PowerShell -Path (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-ClusterNode.ps1')
        $win | Should -Not -Match '(?i)\b(Set|New|Remove|Start|Stop|Restart|Suspend|Clear|Rename)-[A-Za-z]+'
        $win | Should -Not -Match '(?i)Invoke-Sqlcmd|sqlcmd|Out-File|Add-Content'
        $win | Should -Not -Match '\?\?' -Because 'Windows PowerShell 5.1 has no null-coalescing'
        $win | Should -Not -Match '\s\?\s' -Because 'Windows PowerShell 5.1 has no ternary'
        $lin = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'cluster-node-check.sh') -Raw
        $lin | Should -Match '^#!/bin/bash'
        $lcode = Get-VmfCodeOnly -Language Shell -Text $lin
        $lcode | Should -Not -Match '\bsystemctl\s+(start|stop|restart|enable|disable|mask|kill)\b'
        $lcode | Should -Not -Match '\b(tee|touch|rm|mv|cp|sqlcmd|crm|pcs)\b'
        # No redirect at all, but the ones that throw output away.
        ($lcode -replace '2>/dev/null', '' -replace '>/dev/null', '' -replace '2>&1', '') | Should -Not -Match '>'
    }

    It 'the Windows script reads the three facts the ruling names' {
        $win = Get-VmfCodeOnly -Language PowerShell -Path (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-ClusterNode.ps1')
        $win | Should -Match "Name='ClusSvc'"
        $win | Should -Match 'HKLM:\\Cluster'
        $win | Should -Match 'HADR_Enabled'
        $win | Should -Match 'vmf\.guest/4'
    }

    It 'the Linux script reads the three facts the ruling names' {
        $lin = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'cluster-node-check.sh') -Raw
        $lin | Should -Match 'is-active'
        $lin | Should -Match 'pacemaker'
        $lin | Should -Match 'corosync'
        $lin | Should -Match '/var/opt/mssql/mssql\.conf'
        $lin | Should -Match 'hadrenabled'
    }

    It 'the guest contract declares every cluster fact, and both scripts are in the manifest' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -Raw | ConvertFrom-Json
        foreach ($f in 'clusterService', 'clusterKey', 'sqlHadr', 'pacemaker', 'corosync') {
            $schema.properties.facts.properties.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty -Because $f
        }
        @($schema.properties.schema.enum) | Should -Contain 'vmf.guest/4'
        $manifest = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        @($manifest.scripts | Where-Object { $_.name -eq 'Test-ClusterNode.ps1' -and $_.os -eq 'windows' }).Count | Should -Be 1
        @($manifest.scripts | Where-Object { $_.name -eq 'cluster-node-check.sh' -and $_.os -eq 'linux' }).Count | Should -Be 1
    }

    It 'the reader takes a vmf.guest/4 answer' {
        $json = '{"schema":"vmf.guest/4","script":"Test-ClusterNode.ps1","version":"1.0.0","result":"READY","checks":[],"facts":{"os":"Windows","clusterService":"absent","clusterKey":"no","sqlHadr":"no"}}'
        (ConvertFrom-VmfGuestOutput -RawOutput $json).result | Should -Be 'READY'
    }

    It 'the Windows script, run here, prints one object in the output contract with the facts' {
        $out = & pwsh -NoProfile -File (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-ClusterNode.ps1')
        $json = ($out | Out-String).Trim()
        Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
        $doc = ConvertFrom-VmfGuestOutput -RawOutput $json
        $doc.result | Should -Be 'READY'
        $doc.facts.clusterService | Should -BeIn @('running', 'installed', 'absent')
        $doc.facts.clusterKey | Should -BeIn @('yes', 'no')
        $doc.facts.sqlHadr | Should -BeIn @('yes', 'no')
    }

    # TEST-BASH-WSL-1: the bash every shell test uses (_TestBash.ps1).
    It 'the Linux script, run here with stand-ins for systemctl, prints one object in the contract and reads mssql.conf' -Skip:(-not $script:testBash) {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-cd-sh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $null = New-Item -ItemType Directory -Path (Join-Path $work 'bin') -Force
        try {
            # A stand-in systemctl: pacemaker active, every other unit inactive.
            $stub = "#!/bin/bash`nif [ `"`$1`" = is-active ] && [ `"`$2`" = pacemaker ]; then echo active; exit 0; fi`necho inactive`nexit 3`n"
            [System.IO.File]::WriteAllText((Join-Path $work 'bin' 'systemctl'), $stub)
            $conf = Join-Path $work 'mssql.conf'
            [System.IO.File]::WriteAllText($conf, "[sqlagent]`nenabled = true`n`n[hadr]`nhadrenabled = 1`n")
            $script = Join-Path $script:repoRoot 'src' 'guest' 'linux' 'cluster-node-check.sh'
            $unixBin = ConvertTo-VmfTestBashPath -Path (Join-Path $work 'bin')
            $unixConf = ConvertTo-VmfTestBashPath -Path $conf
            $unixScript = ConvertTo-VmfTestBashPath -Path $script
            $out = Invoke-VmfTestBash -ArgumentList @('-c', "chmod +x '$unixBin/systemctl'; PATH='$($unixBin):'`$PATH VMF_MSSQL_CONF='$unixConf' bash '$unixScript'")
            $json = ($out | Out-String).Trim()
            Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
            $doc = ConvertFrom-VmfGuestOutput -RawOutput $json
            $doc.result | Should -Be 'READY'
            $doc.facts.pacemaker | Should -Be 'active'
            $doc.facts.corosync | Should -Be 'inactive'
            $doc.facts.sqlHadr | Should -Be 'yes'
            InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { (Get-VmfClusterNodeVerdict -Os 'Linux' -GuestOutput $d).Verdict } | Should -Be 'node'
        }
        finally { [System.IO.Directory]::Delete($work, $true) }
    }
}

Describe 'CLUSTER-DETECT-1: the words an operator reads' {
    BeforeAll {
        $script:reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'assessment-reasons.json') -Raw | ConvertFrom-Json
        $script:stops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
    }

    It 'the hint is a warning, never a blocker, and says a person confirms' {
        $w = $script:reasons.warnings.'cluster-node-confirm'
        $w | Should -Not -BeNullOrEmpty
        $script:reasons.blockers.PSObject.Properties['cluster-node-confirm'] | Should -BeNullOrEmpty
        $w.meaning | Should -Match 'may be'
        $w.meaning | Should -Match 'can still move'
        @($w.appliesTo) | Should -Be @('v5', 'v6', 'v7')
        $script:reasons.workloadTypes.'may-be-cluster-node'.title | Should -Be 'May be a cluster node'
    }

    It 'a cluster node at Checking is outside the scope of this tool, and the machine is untouched' {
        $r = @($script:stops.reasons | Where-Object code -EQ 'clusterNode')[0]
        $r.retry | Should -Be 'outOfScope'
        $r.machine | Should -Be 'untouched'
        # POWER-ONLY-CHANGED-1: nothing changed once the power state is back; a refused return is said.
        $r.meaning | Should -Match 'Then nothing on the machine changed\.'
        $r.meaning | Should -Match 'If Azure refused to stop it again, the stop says so\.'
        $n = @($script:stops.reasons | Where-Object code -EQ 'clusterNodeNotChecked')[0]
        $n.machine | Should -Be 'untouched'
        $n.retry | Should -Be 'afterFix'
    }
}
