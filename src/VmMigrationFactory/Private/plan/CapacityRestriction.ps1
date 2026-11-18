# ROLLBACK-CAPACITY-1 (2026-11-14): is the original size of a machine
# in a series whose capacity growth Microsoft restricts?
#
# Microsoft's pinned page retirements-and-capacity-restrictions, section
# Impacted VM series, lists them (data/target-families.json
# lifecycle.capacityRestrictions). Azure might not approve more quota, new
# deployments or capacity expansion for them, and quota is not capacity. A
# rollback returns a machine to its original size, so it can find no capacity
# for that size. The product gives no guarantee of capacity, and the sign-off
# of a wave that holds such a machine says so (plan-entry
# assessment.sourceCapacityRestricted, written by New-VmfPlan).
#
# Read from the data; nothing here names a series. No Azure call.

function Test-VmfSizeCapacityRestricted {
    <#
    .SYNOPSIS
        $true when the size is in a series of lifecycle.capacityRestrictions,
        $false when it is not, $null when the size cannot be read (unknown is
        never a yes or a no).
    .DESCRIPTION
        The series is read the way the data's sizeSeries is written
        (Get-VmfSizeSeriesReading, the reading of lifecycle.retirements):
        Standard_D4s_v3 is Dsv3, Standard_DS2_v2 DSv2, Standard_B2ms Bms.
        Case is ignored, as Azure ignores it in a size name.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)
    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    # The reading takes the family in upper case, as the data writes it.
    $name = if ($SizeName -match '^(?i)(standard|basic)_([a-z]+)(.*)$') { '{0}_{1}{2}' -f ($Matches[1].Substring(0, 1).ToUpperInvariant() + $Matches[1].Substring(1).ToLowerInvariant()), $Matches[2].ToUpperInvariant(), $Matches[3].ToLowerInvariant() } else { $SizeName }
    $read = Get-VmfSizeSeriesReading -SizeName $name
    if (-not $read) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    $rows = $Families.lifecycle.PSObject.Properties['capacityRestrictions']
    if (-not $rows -or -not $rows.Value) { return $null }
    [bool](@($rows.Value.sizeSeries) -ccontains $read)
}
