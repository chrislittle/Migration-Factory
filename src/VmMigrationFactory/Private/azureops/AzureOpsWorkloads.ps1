# DETECT-PATTERNS-1: the three reads that find workloads which must not move
# like an ordinary machine. Each one answers, or says it could not - a read
# that fails is never "nothing found" (the AVD and SAP contract). The scan
# refuses when any of them cannot be verified.
#
# The signals were proven on Azure by a separate lifecycle planner tool's test
# builds (2026-10-09, 2026-10-10, 2026-10-16, 2026-10-17): a SQL Server machine
# registered with the SQL IaaS Agent, a shared disk on two machines, AKS,
# Databricks, and a service catalog managed application. The availability
# group field and Azure Red Hat OpenShift come from Microsoft's documentation
# only.

function Get-VmfSqlVirtualMachines {
    <#
    .SYNOPSIS
        Every SQL virtual machine resource (the SQL IaaS Agent's record) in the
        scanned subscriptions, keyed by the machine it points to.
    .DESCRIPTION
        Microsoft.SqlVirtualMachine/sqlVirtualMachines, listed per
        subscription from the provider (api-version 2023-10-01). The record
        lives in the machine's own resource group, so the scan's subscriptions
        are enough.

        WHY THE PROVIDER AND NOT RESOURCE GRAPH: Resource Graph silently leaves
        out a type the caller may not read. An installation whose role predates
        this read would then see "no SQL anywhere" and pass an availability
        group member as a single machine. The provider answers 403, which this
        turns into Verified = $false, and the scan refuses.

        ONLY FOUR FACTS ARE KEPT: the record's id, its availability group
        (sqlVirtualMachineGroupResourceId), and its image offer and edition.
        The record has other properties - the REST reference lists
        wsfcDomainCredentials, and the specification does not mark them
        write-only - so nothing else is kept, logged or written.
    .OUTPUTS
        @{ Ids = @{ lowercased vm id = @{ id; groupId; offer; sku } };
           Verified = bool; Detail = string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Subscriptions)

    $ids = @{}
    foreach ($sub in @($Subscriptions | Where-Object { $_ } | Sort-Object -Unique)) {
        $list = Get-VmfArmList -Path "/subscriptions/$sub/providers/Microsoft.SqlVirtualMachine/sqlVirtualMachines?api-version=2023-10-01"
        if (-not $list.Ok) {
            # A subscription that never registered the provider has no SQL
            # virtual machine records: a real, verified answer.
            if ($list.StatusCode -eq 404 -or
                ($list.Content -and $list.Content -match 'MissingSubscriptionRegistration|NoRegisteredProviderFound|InvalidResourceNamespace|SubscriptionNotRegistered')) {
                continue
            }
            return @{ Ids = @{}; Verified = $false
                      Detail = "could not list SQL virtual machines in $sub (HTTP $($list.StatusCode))" }
        }
        foreach ($item in @($list.Items)) {
            $vmId = [string]$item.properties.virtualMachineResourceId
            if (-not $vmId) { continue }
            $ids[$vmId.ToLowerInvariant()] = @{
                id      = [string]$item.id
                groupId = [string]$item.properties.sqlVirtualMachineGroupResourceId
                offer   = [string]$item.properties.sqlImageOffer
                sku     = [string]$item.properties.sqlImageSku
            }
        }
    }
    @{ Ids = $ids; Verified = $true
       Detail = "$($ids.Count) SQL virtual machine record(s) found" }
}

# REBUILD-REMOVE-ROLE-1: DCR-READ-1's read of each machine's data collection
# rule associations was here. Only the acceptance of a rebuild showed them, and
# the rebuild is gone, so the scan no longer reads them and neither role holds
# Microsoft.Insights/dataCollectionRuleAssociations/read.

$script:VmfArgDiskShareQuery = @'
Resources
| where type =~ 'microsoft.compute/disks'
| where isnotempty(managedBy)
| project id, maxShares = toint(properties.maxShares), sku = tostring(sku.name), tags
'@

function Get-VmfDiskShareMap {
    <#
    .SYNOPSIS
        maxShares of every ATTACHED managed disk in the scanned subscriptions.
    .DESCRIPTION
        A disk with maxShares above 1 can be attached to more than one machine
        at once: a failover cluster's shared disk. Resource Graph has no list
        of the machines on such a disk (managedByExtended was EMPTY in the
        planner's test with two machines on one disk), so the rules start from
        each machine's own data disks and look each one up here.

        EVERY attached disk is returned, not only the shared ones, so a disk
        the caller could not read (absent here) is told apart from a disk that
        is not shared: the first is unknown, the second is an answer. A managed
        disk is in its machine's subscription.

        HDD-OS-1: and each disk's type - the disk resource's sku.name, the
        field Microsoft's own list of Standard HDD OS disks reads. The machine's
        own record of a disk's type can be older than the disk (OLD-SKU-1C), so
        the disk is asked. A disk with no type read is left out of Types:
        unknown, never a type.

        HDD-OS-ASR-PROBE-1: and each disk that Azure Site Recovery made, from
        the disk's tags in the same read (Microsoft.Compute/disks/read, which
        the scan already holds). The probe of 2026-11-09 read every OS disk of
        a replication, a test failover and a failover: the disk Site Recovery
        made carries the tag ASR-ReplicaDisk (the replica) or ASR-FODisk (the
        disk a test failover or a failover runs on). Nothing else marks it:
        the failover disk has the source disk's own name, and createOption
        Restore is on any disk made from a snapshot. Only the tag NAME is read,
        in any case (Azure tag names are case-insensitive); a value is not.
    .OUTPUTS
        @{ Disks = @{ lowercased disk id = [int] maxShares };
           Types = @{ lowercased disk id = sku name };
           SiteRecovery = @{ lowercased disk id = $true }; Verified; Detail }
        A disk with no maxShares recorded reads 1, Azure's default.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Subscriptions)

    $disks = @{}
    $types = @{}
    $siteRecovery = @{}
    try {
        $skipToken = $null
        do {
            $body = @{ query = $script:VmfArgDiskShareQuery; options = @{ '$top' = 500 }; subscriptions = @($Subscriptions) }
            if ($skipToken) { $body.options['$skipToken'] = $skipToken }
            $parsed = Invoke-VmfResourceGraphQuery -Body $body
            foreach ($row in @($parsed.data)) {
                if (-not $row.id) { continue }
                $shares = if ($null -eq $row.maxShares -or [string]$row.maxShares -eq '') { 1 } else { [int]$row.maxShares }
                $disks[([string]$row.id).ToLowerInvariant()] = $shares
                if ($row.PSObject.Properties['sku'] -and [string]$row.sku) { $types[([string]$row.id).ToLowerInvariant()] = [string]$row.sku }
                if ($row.PSObject.Properties['tags'] -and (Test-VmfSiteRecoveryDiskTags -Tags $row.tags)) { $siteRecovery[([string]$row.id).ToLowerInvariant()] = $true }
            }
            $skipToken = $parsed.'$skipToken'
        } while ($skipToken)
    }
    catch {
        return @{ Disks = @{}; Types = @{}; SiteRecovery = @{}; Verified = $false; Detail = "could not read the managed disks ($($_.Exception.Message))" }
    }
    @{ Disks = $disks; Types = $types; SiteRecovery = $siteRecovery; Verified = $true; Detail = "$($disks.Count) attached disk(s) read" }
}

# HDD-OS-ASR-PROBE-1: the tag names that mark a disk Azure Site Recovery made,
# as the probe of 2026-11-09 read them (docs/backlog, HDD-OS-ASR-PROBE-1).
$script:VmfSiteRecoveryDiskTagNames = @('ASR-ReplicaDisk', 'ASR-FODisk')

function Test-VmfSiteRecoveryDiskTags {
    <#
    .SYNOPSIS
        True when a disk's tags hold a tag NAME that marks a disk Azure Site
        Recovery made (ASR-ReplicaDisk or ASR-FODisk), in any case. Pure.
    .DESCRIPTION
        Azure tag names are case-insensitive (Microsoft's tag-resources page,
        Limitations), so the name is compared without case. A value is never
        read: a tag of another name whose value says ASR-FODisk is not a mark.
        No tags, or tags in a shape this does not know, is false.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Tags)

    if ($null -eq $Tags) { return $false }
    $names = if ($Tags -is [System.Collections.IDictionary]) { @($Tags.Keys | ForEach-Object { [string]$_ }) }
    elseif ($Tags -is [pscustomobject]) { @($Tags.PSObject.Properties.Name) }
    else { @() }
    foreach ($name in $names) {
        foreach ($mark in $script:VmfSiteRecoveryDiskTagNames) {
            if ([string]::Equals($name, $mark, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    $false
}

# CLUSTER-DETECT-1: the SQL IaaS Agent extension, a HINT that a machine may be
# a cluster node (design of 2026-10-26). Read through Resource Graph over
# virtual machine extensions, with the access the scan already has
# (Microsoft.Compute/virtualMachines/extensions/read) - the read the SAP check
# makes. SqlIaaSAgent is the Windows extension, SqlIaaSAgentLinux the Linux one.
$script:VmfSqlAgentExtensionQuery = @'
Resources
| where type =~ 'microsoft.compute/virtualmachines/extensions'
| extend publisher = tostring(properties.publisher), extType = tostring(properties.type)
| where publisher =~ 'Microsoft.SqlServer.Management'
| where extType in~ ('SqlIaaSAgent', 'SqlIaaSAgentLinux')
| project id, extType
'@

function Get-VmfSqlIaaSAgentVmIds {
    <#
    .SYNOPSIS
        CLUSTER-DETECT-1: the machines that carry the SQL IaaS Agent extension.
    .DESCRIPTION
        A hint, never a block: the extension is on every SQL Server machine
        registered with the SQL IaaS Agent, alone or in a cluster. The scan
        gives such a machine the warning that it may be a cluster node, and
        Checking reads inside the machine before it moves.
    .OUTPUTS
        @{ Ids = @{ lowercased vm id = extension type }; Verified = bool; Detail = string }
        Verified = $false means the question could not be answered, which is
        NOT "no extension here". The caller reads it as unknown.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Subscriptions)

    $ids = @{}
    try {
        $skipToken = $null
        do {
            $body = @{ query = $script:VmfSqlAgentExtensionQuery; options = @{ '$top' = 500 }; subscriptions = @($Subscriptions) }
            if ($skipToken) { $body.options['$skipToken'] = $skipToken }
            $parsed = Invoke-VmfResourceGraphQuery -Body $body
            foreach ($row in @($parsed.data)) {
                # The extension's id is the machine's id plus /extensions/<name>.
                $extId = [string]$row.id
                $cut = $extId.LastIndexOf('/extensions/', [System.StringComparison]::OrdinalIgnoreCase)
                if ($cut -lt 1) { continue }
                $ids[$extId.Substring(0, $cut).ToLowerInvariant()] = [string]$row.extType
            }
            $skipToken = $parsed.'$skipToken'
        } while ($skipToken)
    }
    catch {
        return @{ Ids = @{}; Verified = $false; Detail = "could not read the virtual machine extensions ($($_.Exception.Message))" }
    }
    @{ Ids = $ids; Verified = $true; Detail = "$($ids.Count) machine(s) carry the SQL IaaS Agent extension" }
}

$script:VmfArgResourceGroupOwnerQuery = @'
ResourceContainers
| where type =~ 'microsoft.resources/subscriptions/resourcegroups'
| project subscriptionId, name, managedBy = tostring(managedBy)
'@

function Get-VmfResourceGroupOwners {
    <#
    .SYNOPSIS
        Every resource group in the scanned subscriptions, with the resource
        that manages it (managedBy), or '' when nothing does.
    .DESCRIPTION
        A service that makes its own resource group writes its resource id in
        the group's managedBy: AKS, Azure Red Hat OpenShift, Databricks - and
        an Azure managed application, whose vendor owns the machines in it.
        The service is read from the id (the part after /providers/), NEVER
        from the group's name, which a customer can choose.

        EVERY group is returned, so a group the caller could not read (absent)
        is unknown, not "managed by nothing".
    .OUTPUTS
        @{ Groups = @{ 'subid/rgname' lowercased = managedBy or '' }; Verified; Detail }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string[]]$Subscriptions)

    $groups = @{}
    try {
        $skipToken = $null
        do {
            $body = @{ query = $script:VmfArgResourceGroupOwnerQuery; options = @{ '$top' = 500 }; subscriptions = @($Subscriptions) }
            if ($skipToken) { $body.options['$skipToken'] = $skipToken }
            $parsed = Invoke-VmfResourceGraphQuery -Body $body
            foreach ($row in @($parsed.data)) {
                if (-not $row.name) { continue }
                $groups["$([string]$row.subscriptionId)/$([string]$row.name)".ToLowerInvariant()] = [string]$row.managedBy
            }
            $skipToken = $parsed.'$skipToken'
        } while ($skipToken)
    }
    catch {
        return @{ Groups = @{}; Verified = $false; Detail = "could not read the resource groups ($($_.Exception.Message))" }
    }
    @{ Groups = $groups; Verified = $true; Detail = "$($groups.Count) resource group(s) read" }
}
