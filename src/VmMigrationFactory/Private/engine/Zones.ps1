# ZONES-1: a machine in an availability zone takes only disks made in that
# zone, and only a size Azure offers in that zone. One rule, read in one place.

function Get-VmfMachineZone {
    <#
    .SYNOPSIS
        ZONES-1: the machine's availability zone. Empty for a regional machine.
    .DESCRIPTION
        Takes a capture (captured.vmConfig) or a live machine: both carry
        zones. Every disk the product makes from a copy passes this as -Zone -
        a disk made from a copy has no zone unless it is given one, and a
        zonal machine refuses it at the swap or the rebuild.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Machine)

    if ($null -eq $Machine) { return '' }
    $first = @($Machine.zones | Where-Object { $_ }) | Select-Object -First 1
    if ($first) { [string]$first } else { '' }
}

function Test-VmfSizeInZone {
    <#
    .SYNOPSIS
        ZONES-1: does Azure offer this size in this zone, to this subscription?
    .DESCRIPTION
        $true, $false, or $null when the catalog entry does not say - and
        unknown is never read as either answer. A regional machine has no zone
        to match, so any size the region offers is $true.
        Two ways the answer is no: a restriction on the subscription that
        covers the zone or the whole region (Get-VmfZoneRestrictionCode), or a
        size the region offers only in its other zones (LocationInfo.Zones).
        Read the entry AS the machine's subscription: both belong to it.
    .PARAMETER Location
        The region. The LocationInfo entry for it is read, never merely the
        first: an extended location carries an entry with no zones.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter()][AllowEmptyString()][string]$Location
    )

    if (-not $Zone) { return $true }
    if ($null -eq $SkuEntry) { return $null }
    if (Get-VmfZoneRestrictionCode -SkuEntry $SkuEntry -Zone $Zone) { return $false }
    $infos = @(@($SkuEntry.LocationInfo) | Where-Object { $_ })
    if ($Location) {
        $flat = { param($s) ([string]$s -replace '\s', '').ToLowerInvariant() }
        $infos = @($infos | Where-Object { (& $flat $_.Location) -eq (& $flat $Location) })
    }
    $info = $infos | Select-Object -First 1
    if (-not $info -or $null -eq $info.Zones) { return $null }
    return (@($info.Zones) -contains $Zone)
}

function Get-VmfZoneRestrictionCode {
    <#
    .SYNOPSIS
        ZONES-1: Azure's reason code for a restriction that keeps this size out
        of this zone for the subscription - one on the zone, or on the whole
        region. Empty when there is none. Every restriction is read, never the
        first alone: a size can be restricted in zone 1 and offered in zone 2.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone
    )

    if ($null -eq $SkuEntry) { return '' }
    $hit = @($SkuEntry.Restrictions) | Where-Object {
        $_ -and ([string]$_.Type -eq 'Location' -or
            ($Zone -and [string]$_.Type -eq 'Zone' -and (@($_.RestrictionInfo.Zones) -contains $Zone)))
    } | Select-Object -First 1
    if ($hit) { $code = [string]$hit.ReasonCode; if ($code) { $code } else { 'restricted' } } else { '' }
}
