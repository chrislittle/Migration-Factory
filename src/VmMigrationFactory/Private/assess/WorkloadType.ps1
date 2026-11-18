# DETECT-PATTERNS-1: each machine's WORKLOAD TYPE, and the evidence for it.
#
# Microsoft's v6/v7 modernization guide ("Discover", "Workload modernization
# categories") sorts workloads into seven patterns, and the pattern decides how
# a machine moves. The names and the ORDER below are the ones a separate
# lifecycle planner tool proved with test builds (2026-10-09 to 2026-10-17):
#
#   1. Vendor appliance        - a network virtual appliance (Microsoft's MANA
#                                NVA policy list), a storage or backup
#                                appliance (our own list), or a machine in an
#                                Azure managed application. Judged FIRST: a
#                                machine in a managed application is a vendor
#                                appliance even when it is also a session host.
#   2. Managed by a service    - its resource group is managed by a service
#                                that is not a node pool (Databricks, ...),
#                                or it is a node of an Azure CycleCloud
#                                cluster, by the tags CycleCloud documents
#                                (BATCH-CYCLECLOUD-SIGNAL-1).
#   3. Node pool or scale set  - AKS or Azure Red Hat OpenShift manage its
#                                group, or it is a scale set member.
#   4. Pooled AVD host         - a session host of a Pooled host pool. A
#                                Personal host moves as a standalone machine.
#   5. Cluster or database     - SQL Server, an availability group, a shared
#                                disk, SAP.
#   -  May be a cluster node   - CLUSTER-DETECT-1: a hint fired (a load
#                                balancer backend pool, more than one IP
#                                configuration, the SQL IaaS Agent extension)
#                                and no fact above did. A hint is not proof,
#                                so it is not Cluster or database; and it is
#                                never Standalone machine. Not Microsoft's.
#   6. Standalone machine      - every machine that is in no other type. So
#                                EVERY signal must be known to say it.
#   -  Type not checked        - a signal the scan could not read. Unknown is
#                                never Standalone machine, never a refusal.
#                                It wins over May be a cluster node, and the
#                                hints are shown with it.
#   (The planner says 'Standalone VM'; this product says machine, never VM.)
#   (Microsoft's pattern D, a cluster in a service, is compute that is not in
#    the customer's subscription at all: no machine in a scan ever has it, so
#    it is not a type here. WORKLOAD-TYPE-D-1 tracks it.)
#
# EACH TYPE CARRIES ITS EVIDENCE: the Azure field and the value that decided
# it, so a person can check the answer in the portal. A signal that was not
# read is evidence too, with no value.

function Get-VmfResourceGroupOwnerKind {
    <#
    .SYNOPSIS
        What kind of resource manages a resource group, from its managedBy id.
        PURE. Read from the resource TYPE after /providers/, never from the
        group's name, which a customer can choose.
    .OUTPUTS
        'managed-application', 'node-pool', 'service', or '' when nothing does.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$ManagedBy)

    if ([string]::IsNullOrWhiteSpace($ManagedBy)) { return '' }
    $parts = $ManagedBy -split '(?i)/providers/', 2
    $type = if ($parts.Count -eq 2) { $parts[1] } else { '' }
    if ($type -like 'Microsoft.Solutions/applications/*') { return 'managed-application' }
    if ($type -like 'Microsoft.ContainerService/managedClusters/*' -or
        $type -like 'Microsoft.RedHatOpenShift/openShiftClusters/*') { return 'node-pool' }
    'service'
}

function Get-VmfWorkloadType {
    <#
    .SYNOPSIS
        The workload type of one machine, and the evidence. PURE.
    .PARAMETER Facts
        A hashtable the assessment rules build. Each signal is $null when it
        was NOT READ, which is different from read-and-absent:
          Nva           - Test-VmfNvaImage result (IsNva, and the Evidence of
                          the image or the purchase plan that decided it)
          Appliance     - Test-VmfStorageAppliance result
          GroupOwner    - the resource group's managedBy ('' = none; $null = not read)
          Platform      - the AKS or Databricks record that declares the group
                          ('' = none; $null = not read)
          CycleCloud    - Test-VmfCycleCloudNode result (IsNode, Evidence)
          VmssId        - the scale set id ('' = none)
          AvdPool       - the host pool name ('' = not a session host; $null = not read)
          AvdPoolType   - Pooled or Personal ('' = the pool gave none)
          Sql           - the SQL virtual machine record (@{} keys id, groupId),
                          '' = none, $null = not read
          ImagePublisher- the image publisher, for a SQL Server image
          SharedDisks   - @( @{ id; shares } ) disks with maxShares above 1
          UnreadDisks   - @( disk ids ) the scan could not read
          Sap           - why the machine is SAP ('' = not SAP; $null = not read)
          ClusterHints  - @( @{ field; value } ) the cluster hints that fired
                          (Get-VmfClusterHintFacts)
          UnreadHints   - @( field names ) the hints the scan could not read
    .OUTPUTS
        [ordered]@{ type; evidence = @( [ordered]@{ field; value } ) }
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][hashtable]$Facts)

    $evidence = [System.Collections.Generic.List[object]]::new()
    $add = { param($field, $value) $evidence.Add([ordered]@{ field = [string]$field; value = $(if ($null -eq $value) { $null } else { [string]$value }) }) }
    $result = { param($type) [ordered]@{ type = $type; evidence = @($evidence) } }
    $owner = $Facts.GroupOwner
    $ownerKind = Get-VmfResourceGroupOwnerKind -ManagedBy ([string]$owner)
    # The host pool is shown with whatever type wins: a session host whose
    # group a managed application owns keeps its host pool (the planner, 0.9.0).
    $avdLine = {
        if ($Facts.AvdPool) { & $add 'hostPool.hostPoolType' $(if ($Facts.AvdPoolType) { $Facts.AvdPoolType } else { $null }) }
    }

    # 1. Vendor appliance.
    if ($Facts.Nva -and $Facts.Nva.IsNva) {
        # The image or the purchase plan, whichever decided it (NVA-PLAN-1).
        foreach ($e in @($Facts.Nva.Evidence)) { if ($e) { & $add $e.field $e.value } }
        & $add 'nvaPolicy' 'Configure Marketplace Network Virtual Appliances (NVAs) to add a MANA support tag'
        & $avdLine
        return (& $result 'vendor-appliance')
    }
    if ($Facts.Appliance -and $Facts.Appliance.IsAppliance) {
        foreach ($e in @($Facts.Appliance.Evidence)) { & $add $e.field $e.value }
        & $avdLine
        return (& $result 'vendor-appliance')
    }
    if ($ownerKind -eq 'managed-application') {
        & $add 'resourceGroup.managedBy' $owner
        & $avdLine
        return (& $result 'vendor-appliance')
    }

    # 2 and 3. A service owns the resource group, or the machine is in a pool.
    if ($ownerKind -eq 'service') {
        & $add 'resourceGroup.managedBy' $owner
        return (& $result 'managed-by-a-service')
    }
    if ($Facts.Platform -and [string]$Facts.Platform -like 'Databricks*') {
        & $add 'workspaces.managedResourceGroupId' $Facts.Platform
        return (& $result 'managed-by-a-service')
    }
    # BATCH-CYCLECLOUD-SIGNAL-1: a CycleCloud node, by the tags CycleCloud
    # documents - before the scale set, so a node array member says CycleCloud.
    if ($Facts.CycleCloud -and $Facts.CycleCloud.IsNode) {
        foreach ($e in @($Facts.CycleCloud.Evidence)) { & $add $e.field $e.value }
        return (& $result 'managed-by-a-service')
    }
    if ($ownerKind -eq 'node-pool') {
        & $add 'resourceGroup.managedBy' $owner
        return (& $result 'node-pool-or-scale-set')
    }
    if ($Facts.Platform) {
        & $add 'managedClusters.nodeResourceGroup' $Facts.Platform
        return (& $result 'node-pool-or-scale-set')
    }
    if ($Facts.VmssId) {
        & $add 'virtualMachineScaleSet.id' $Facts.VmssId
        return (& $result 'node-pool-or-scale-set')
    }

    # 4. A pooled desktop.
    if ($Facts.AvdPool -and [string]$Facts.AvdPoolType -eq 'Pooled') {
        & $add 'hostPool.hostPoolType' 'Pooled'
        return (& $result 'pooled-avd-host')
    }

    # 5. A database or a cluster. Every fact that fired is shown.
    if ($Facts.Sql) {
        & $add 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' $Facts.Sql.id
        if ($Facts.Sql.groupId) { & $add 'sqlVirtualMachineGroupResourceId' $Facts.Sql.groupId }
    }
    if ([string]$Facts.ImagePublisher -eq 'MicrosoftSQLServer') { & $add 'imageReference.publisher' $Facts.ImagePublisher }
    foreach ($d in @($Facts.SharedDisks)) { if ($d) { & $add 'disk.maxShares' "$($d.shares) ($($d.id))" } }
    if ($Facts.Sap) { & $add 'sap' $Facts.Sap }
    # CLUSTER-DETECT-1: a hint that fired is shown beside the facts.
    $hints = @(@($Facts.ClusterHints) | Where-Object { $_ })
    $addHints = { foreach ($h in $hints) { & $add $h.field $h.value } }
    if ($evidence.Count) { & $addHints; & $avdLine; return (& $result 'cluster-or-database') }

    # 6. Standalone machine - only when every signal was read.
    if ($null -eq $owner) { & $add 'resourceGroup.managedBy' $null }
    if ($null -eq $Facts.Platform) { & $add 'managedClusters.nodeResourceGroup' $null }
    if ($null -eq $Facts.AvdPool) { & $add 'sessionHosts.resourceId' $null }
    elseif ($Facts.AvdPool -and -not $Facts.AvdPoolType) { & $add 'hostPool.hostPoolType' $null }
    if ($null -eq $Facts.Sql) { & $add 'Microsoft.SqlVirtualMachine/sqlVirtualMachines' $null }
    foreach ($id in @($Facts.UnreadDisks)) { if ($id) { & $add 'disk.maxShares' $null } }
    if ($null -eq $Facts.Sap) { & $add 'sap' $null }
    foreach ($field in @($Facts.UnreadHints)) { if ($field) { & $add $field $null } }
    if ($evidence.Count) { & $addHints; return (& $result 'not-checked') }

    # CLUSTER-DETECT-1: every signal was read, and a hint fired. Not proof of
    # a cluster, and never standalone.
    if ($hints.Count) { & $addHints; & $avdLine; return (& $result 'may-be-cluster-node') }

    # A personal desktop moves as a standalone machine: say why it is not pooled.
    & $avdLine
    & $result 'standalone-vm'
}
