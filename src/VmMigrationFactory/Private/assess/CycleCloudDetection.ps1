# BATCH-CYCLECLOUD-SIGNAL-1, 2026-11-03: a machine in an Azure CycleCloud
# cluster is the cluster's, not a standalone machine.
#
# CycleCloud is software that runs in a machine of the customer's. It is NOT
# an Azure resource provider: no Azure record (a managedBy, a provider list)
# names the machines it makes, so the product's rule "read the service's own
# record, never a tag" (WORKLOAD-1, AKS) has no record to read here. What
# CycleCloud gives instead is its own tags, which Microsoft documents
# (Tagging Nodes, learn.microsoft.com/azure/cyclecloud/how-to/tag-nodes,
# read 2026-11-03): "Azure CycleCloud automatically creates and adds three
# tags to each node", on "the VM, nic, and disk resources":
#   - CycleCloudCluster   /sites/[site_id]/clusters/[cluster_name]
#                         ("Available from CycleCloud v8.2 onwards")
#   - CycleCloudNodeArray /sites/[site_id]/clusters/[cluster_name]/nodearrays/[nodearray_name]
#                         (a node of a node array, from 8.2)
#   - ClusterId           "Available on CycleCloud v8.2 or earlier"; the
#                         page's example is "Demo(username@mysite:92xy4vgh)"
#                         beside ClusterName "Demo".
#
# A TAG NAME ALONE NEVER DECIDES. ClusterName is a common tag on ordinary
# machines, and CycleOwner's documented format and example disagree, so
# neither is a signal by itself. Each signal is a documented tag WITH a value
# in its documented format, and ClusterId only beside the ClusterName it
# starts with. Azure tag names are not case-sensitive, so neither is this.
#
# Azure Batch needs no tag (Batch security and compliance best practices,
# read 2026-11-03): in user subscription mode "The underlying Virtual Machine
# Scale Set resources are created in the same subscription as the Batch
# account". A Batch node is a scale set instance, which the scan already
# excludes (vmssId). Not measured on Azure: BATCH-CYCLECLOUD-PROOF-1.

$script:VmfCycleCloudClusterPattern = '^/sites/[^/]+/clusters/[^/]+$'
$script:VmfCycleCloudNodeArrayPattern = '^/sites/[^/]+/clusters/[^/]+/nodearrays/[^/]+$'
# [cluster_name]([username]@[site_name]:[site_id])
$script:VmfCycleCloudClusterIdPattern = '^(?<cluster>[^()]+)\((?<user>[^()@]+)@(?<site>[^():]+):(?<siteId>[^()]+)\)$'

function Get-VmfTagValue {
    <#
    .SYNOPSIS
        One tag's value by its name, without case, from the tags in any shape
        the product reads them: a Resource Graph object, a hashtable, or the
        Dictionary Get-AzVM returns. PURE. $null when the tag is not there.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Tags, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Tags) { return $null }
    if ($Tags -is [System.Collections.IDictionary]) {
        foreach ($k in @($Tags.Keys)) { if ([string]$k -ieq $Name) { return [string]$Tags[$k] } }
        return $null
    }
    foreach ($prop in @($Tags.PSObject.Properties)) { if ($prop.Name -ieq $Name) { return [string]$prop.Value } }
    $null
}

function Test-VmfCycleCloudNode {
    <#
    .SYNOPSIS
        Is this machine a node of an Azure CycleCloud cluster, by the tags
        CycleCloud documents? PURE.
    .OUTPUTS
        @{ IsNode = bool; Evidence = @( [ordered]@{ field; value } ) }
        The evidence names each tag (tags.<name>) and its value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Tags)

    $evidence = [System.Collections.Generic.List[object]]::new()
    $cluster = Get-VmfTagValue -Tags $Tags -Name 'CycleCloudCluster'
    if ($cluster -and $cluster -cmatch $script:VmfCycleCloudClusterPattern) {
        $evidence.Add([ordered]@{ field = 'tags.CycleCloudCluster'; value = $cluster })
    }
    $nodeArray = Get-VmfTagValue -Tags $Tags -Name 'CycleCloudNodeArray'
    if ($nodeArray -and $nodeArray -cmatch $script:VmfCycleCloudNodeArrayPattern) {
        $evidence.Add([ordered]@{ field = 'tags.CycleCloudNodeArray'; value = $nodeArray })
    }
    $clusterId = Get-VmfTagValue -Tags $Tags -Name 'ClusterId'
    $clusterName = Get-VmfTagValue -Tags $Tags -Name 'ClusterName'
    if ($clusterId -and $clusterName -and $clusterId -cmatch $script:VmfCycleCloudClusterIdPattern -and
        $Matches['cluster'] -ceq $clusterName) {
        $evidence.Add([ordered]@{ field = 'tags.ClusterId'; value = $clusterId })
        $evidence.Add([ordered]@{ field = 'tags.ClusterName'; value = $clusterName })
    }
    @{ IsNode = ($evidence.Count -gt 0); Evidence = @($evidence) }
}

function Get-VmfCycleCloudEvidenceText {
    <#
    .SYNOPSIS
        The evidence as words: tag 'value', tag 'value'. PURE.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable]$Verdict)
    @(@($Verdict.Evidence) | ForEach-Object { "$(([string]$_.field) -replace '^tags\.', '') '$($_.value)'" }) -join ', '
}
