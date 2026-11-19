# ID-ADDRESS-1 part 3: the size catalog of a machine is the catalog of ITS
# subscription in ITS region.
#
# Azure answers the size list as a subscription: a restriction
# (NotAvailableForSubscription) belongs to one, and so do its zone numbers. The
# scan, the target options and the plan read the catalog once per REGION, in
# whatever subscription the session was in, and gave that answer to every
# machine in the region. A machine in another subscription was then judged on
# sizes that subscription may not have. The quota check and the engine already
# read per subscription (ZONES-1); these helpers give the other three the same
# rule, and Get-VmfSkuCatalog keeps the cache per subscription and region.

function Get-VmfCatalogKey {
    <#
    .SYNOPSIS
        The key of a machine's catalog: its subscription and its region. Pure.
    .DESCRIPTION
        The subscription comes from the machine's resource ID
        (Get-VmfSubscriptionId). An ID that carries none gives an empty
        subscription: that catalog is read in the session's subscription, as
        before, and is never shared with a machine whose ID names one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$VmId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Location
    )
    $sub = Get-VmfSubscriptionId -ResourceId $VmId
    '{0}|{1}' -f $(if ($sub) { $sub.ToLowerInvariant() } else { '' }), $Location.ToLowerInvariant()
}

function Read-VmfMachineCatalogs {
    <#
    .SYNOPSIS
        Read the size catalog once for each subscription and region the
        machines are in.
    .PARAMETER Machines
        Objects with a location and a resource ID (the property IdProperty names).
    .PARAMETER NotRead
        When given, a read that fails adds its key here and the others go on.
        When not given, a read that fails stops the caller.
    .PARAMETER NotReadReason
        With NotRead: each key that failed -> the error text Azure gave.
    .PARAMETER NotReadError
        With NotRead: each key that failed -> the whole error, as
        Resolve-VmfOperationError gives it (Message, StatusCode, ErrorCode).
        SCAN-PARTIAL-SUBS-1: the scan records Azure's reason and the kind of
        failure, so a person sees why and how to fix it. A temporary failure
        never gets here: Invoke-VmfAzOperation tried it again first.
    .OUTPUTS
        A hashtable: catalog key (Get-VmfCatalogKey) -> (size name -> SKU entry).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][object[]]$Machines,
        [Parameter(Mandatory)][string]$IdProperty,
        [Parameter()][string]$RunPath,
        [Parameter()][AllowNull()][System.Collections.Generic.List[string]]$NotRead,
        [Parameter()][AllowNull()][hashtable]$NotReadReason,
        [Parameter()][AllowNull()][hashtable]$NotReadError
    )
    $catalogs = @{}
    $reads = [ordered]@{}
    foreach ($m in @($Machines | Where-Object { $_ })) {
        $location = [string]$m.location
        if (-not $location) { continue }
        $vmId = [string]$m.$IdProperty
        $key = Get-VmfCatalogKey -VmId $vmId -Location $location
        if (-not $reads.Contains($key)) {
            $sub = Get-VmfSubscriptionId -ResourceId $vmId
            $reads[$key] = @{ Location = $location; Subscription = $(if ($sub) { $sub } else { '' }) }
        }
    }
    foreach ($key in @($reads.Keys)) {
        $location = $reads[$key].Location
        $sub = $reads[$key].Subscription
        $opArgs = @{ Name = $(if ($sub) { "skuCatalog:$sub/$location" } else { "skuCatalog:$location" }) }
        if ($RunPath) { $opArgs.RunPath = $RunPath }
        try {
            $catalog = Invoke-VmfAzOperation @opArgs -Operation {
                Get-VmfSkuCatalog -Location $location -SubscriptionId $sub
            }
        }
        catch {
            if ($null -ne $NotRead) {
                $NotRead.Add($key)
                if ($null -ne $NotReadReason) { $NotReadReason[$key] = [string]$_.Exception.Message }
                if ($null -ne $NotReadError) { $NotReadError[$key] = Resolve-VmfOperationError -ErrorRecord $_ }
                continue
            }
            throw
        }
        $bySize = @{}
        foreach ($entry in @($catalog)) { if ($entry) { $bySize[[string]$entry.Name] = $entry } }
        $catalogs[$key] = $bySize
    }
    $catalogs
}

function Get-VmfMachineCatalog {
    <#
    .SYNOPSIS
        One machine's catalog (size name -> SKU entry), or $null when it was
        not read. Pure. Never the catalog of another subscription.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][hashtable]$Catalogs,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$VmId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Location
    )
    $key = Get-VmfCatalogKey -VmId $VmId -Location $Location
    if ($Catalogs.ContainsKey($key)) { $Catalogs[$key] } else { $null }
}
