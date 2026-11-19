# CLUSTER-DETECT-1, 2026-10-31: the scan's HINTS that a machine may be a
# cluster node that Azure has no record of.
#
# The design (2026-10-26): read-only hints - a machine may be a cluster node,
# and a person confirms - from facts the scan already may read. A hint gives a warning that
# a person confirms. It never blocks - a web server behind a load balancer
# fires one too - and the machine is never called standalone with certainty
# when one fired. Checking reads inside the machine before it moves, and that
# is where a cluster node stops (Get-VmfWorkloadCheckStop).
#
# The three hints:
#   - a network interface in a load balancer backend pool (the interface's
#     own record; the role does not read load balancers - 2026-10-27,
#     OWNER-QUESTIONS-1 row 42 - so floating IP is not looked at);
#   - more than one IP configuration on a network interface (an availability
#     group listener or a cluster IP address);
#   - the SQL IaaS Agent extension.

function Get-VmfClusterHintFacts {
    <#
    .SYNOPSIS
        The cluster hints that fired for one machine, and the ones the scan
        could not read. PURE.
    .PARAMETER NicClusterHints
        Get-VmfNicFacts ClusterHints: lowercased nic id -> @{ ipConfigCount;
        pools }. $null = not read; an interface that is absent = not read.
    .PARAMETER SqlAgentVms
        Get-VmfSqlIaaSAgentVmIds Ids: lowercased vm id -> extension type.
        $null = not read.
    .OUTPUTS
        @{ Fired = @( [ordered]@{ field; value } ); Unread = @( field names ) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter()][AllowNull()][hashtable]$NicClusterHints,
        [Parameter()][AllowNull()][hashtable]$SqlAgentVms
    )
    $fired = [System.Collections.Generic.List[object]]::new()
    $unread = [System.Collections.Generic.List[string]]::new()
    $nics = @(@($(if ($Vm.PSObject.Properties['nicIds']) { $Vm.nicIds })) | Where-Object { $_ } |
        ForEach-Object { if ($_.PSObject.Properties['id']) { [string]$_.id } else { [string]$_ } } | Where-Object { $_ })
    foreach ($nic in $nics) {
        $key = $nic.ToLowerInvariant()
        if ($null -eq $NicClusterHints -or -not $NicClusterHints.ContainsKey($key)) {
            if ($unread -notcontains 'networkInterface.ipConfigurations') { $unread.Add('networkInterface.ipConfigurations') }
            continue
        }
        $h = $NicClusterHints[$key]
        foreach ($pool in @($h.pools)) {
            if ($pool) { $fired.Add([ordered]@{ field = 'ipConfigurations.loadBalancerBackendAddressPools'; value = [string]$pool }) }
        }
        if ([int]$h.ipConfigCount -gt 1) {
            $fired.Add([ordered]@{ field = 'networkInterface.ipConfigurations'; value = "$([int]$h.ipConfigCount) ($nic)" })
        }
    }
    if ($null -eq $SqlAgentVms) { $unread.Add('extensions.type') }
    else {
        $vmKey = ([string]$Vm.id).ToLowerInvariant()
        if ($SqlAgentVms.ContainsKey($vmKey)) { $fired.Add([ordered]@{ field = 'extensions.type'; value = [string]$SqlAgentVms[$vmKey] }) }
    }
    @{ Fired = @($fired); Unread = @($unread) }
}
