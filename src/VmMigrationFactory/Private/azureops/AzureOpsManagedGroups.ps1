# WORKLOAD-1 (AKS + Databricks): ask the platform which resource groups it
# MANAGES, instead of guessing from names or tags.
#
# The AKS review settled the facts:
# - Standard AKS node pools are Uniform-VMSS-backed, and Uniform instances are
#   not Microsoft.Compute/virtualMachines resources AT ALL - they never enter
#   the product's inventory. Nothing to guard; a scope fact.
# - The shapes that DO appear as standalone VMs are the exposure: the newer
#   "Virtual Machines" node pools and legacy availability-set pools. Neither
#   carries a vmssId.
# - The old guards for those were a NAMING CONVENTION (resourceGroup -match
#   '^MC_' - customers can rename the node RG, and an ordinary RG named MC_*
#   would false-positive) and a TAG (aks-managed-poolName - the rule:
#   no tags decide anything). Both are gone.
#
# The authoritative record: the cluster object itself declares
# properties.nodeResourceGroup - the real name, whatever it was named. And
# Databricks has the identical shape: the workspace declares
# managedResourceGroupId, and its cluster VMs live there. One Resource Graph
# query covers both.
#
# SCAN-SCOPE-READS-1 (ruled 2026-11-14): the query
# carries the subscriptions of the machines found, like the SAP and workload
# reads (SCOPE-1). It used to carry NO scope, which Resource Graph reads as
# every subscription the identity can see. An assessment reads nothing outside
# the scope the person chose.
# Nothing is lost for AKS: Microsoft's AKS FAQ says you cannot "specify a
# different subscription for the node resource group", so a node in a scanned
# machine's subscription has its cluster in that same subscription. For
# Databricks NO Microsoft page was found that says the managed resource group
# is always in the workspace's subscription (Microsoft's REST examples show it
# so; that is an example, not a rule), so it is NOT claimed here. A managed
# resource group in the scope whose workspace is outside it is still caught:
# Databricks writes the workspace id in the group's managedBy, and
# Get-VmfResourceGroupOwners reads that for every group in the same
# subscriptions.

$script:VmfManagedGroupsQuery = @'
Resources
| where type =~ 'microsoft.containerservice/managedclusters'
     or type =~ 'microsoft.databricks/workspaces'
| project type, name, subscriptionId,
          nodeResourceGroup = tostring(properties.nodeResourceGroup),
          managedResourceGroupId = tostring(properties.managedResourceGroupId)
'@

function Get-VmfManagedPlatformGroups {
    <#
    .SYNOPSIS
        Every resource group a platform declares it manages, with the owner
        named: AKS node resource groups and Databricks managed resource
        groups.
    .OUTPUTS
        @{ Groups = hashtable ('subId/rgName' lowercased -> 'AKS cluster ''x''' etc.);
           Verified = bool; Detail = string }
    .NOTES
        Same honesty contract as the AVD enumeration: cannot read it = cannot
        claim a machine is not a node (the drill rule) - the caller REFUSES
        the scan on Verified = $false, by rule.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # The subscriptions the scanned machines are in (SCAN-SCOPE-READS-1).
        [Parameter(Mandatory)][string[]]$Subscriptions
    )

    $groups = @{}
    try {
        $skipToken = $null
        do {
            $body = @{ query = $script:VmfManagedGroupsQuery; options = @{ '$top' = 500 }; subscriptions = @($Subscriptions) }
            if ($skipToken) { $body.options['$skipToken'] = $skipToken }
            $parsed = Invoke-VmfResourceGraphQuery -Body $body
            foreach ($row in @($parsed.data)) {
                if ($row.type -match 'managedclusters') {
                    $rg = [string]$row.nodeResourceGroup
                    if ($rg) { $groups["$([string]$row.subscriptionId)/$rg".ToLowerInvariant()] = "AKS cluster '$($row.name)'" }
                }
                else {
                    # managedResourceGroupId is a full ARM id: /subscriptions/{s}/resourceGroups/{rg}
                    if ([string]$row.managedResourceGroupId -match '(?i)/subscriptions/([^/]+)/resourceGroups/([^/]+)') {
                        $groups["$($Matches[1])/$($Matches[2])".ToLowerInvariant()] = "Databricks workspace '$($row.name)'"
                    }
                }
            }
            $skipToken = $parsed.'$skipToken'
        } while ($skipToken)
    }
    catch {
        return @{ Groups = $groups; Verified = $false
                  Detail = "could not enumerate AKS clusters and Databricks workspaces ($($_.Exception.Message)) - platform-managed membership CANNOT be verified" }
    }
    @{ Groups = $groups; Verified = $true
       Detail = "The scan read $(@($Subscriptions).Count) $(if (@($Subscriptions).Count -eq 1) { 'subscription' } else { 'subscriptions' }) in the scan scope. It found $($groups.Count) platform-managed $(if ($groups.Count -eq 1) { 'resource group' } else { 'resource groups' })." }
}
