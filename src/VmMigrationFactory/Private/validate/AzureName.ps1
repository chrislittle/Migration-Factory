# SNAPSHOT-NAME-END-1: the one rule for every name the product makes for an
# Azure resource. Pure: no Azure call.

# Microsoft, "Naming rules and restrictions for Azure resources"
# (learn.microsoft.com/azure/azure-resource-manager/management/resource-name-rules),
# Microsoft.Compute:
#   snapshots - 1-80, alphanumerics, underscores, periods and hyphens; start
#               with an alphanumeric; end with an alphanumeric or an underscore.
#   disks     - 1-80, alphanumerics, underscores and hyphens. But Azure names
#               a Linux machine's own OS disk '<vm>_OsDisk_1_<guid>', and a
#               Linux machine name may hold a period, so a disk name the
#               product derives from it can too. The disk rule checks ONLY the
#               length and that the name is not empty: a derived disk name is
#               made inside the stopped window (rollback, restore), and a throw
#               for a character Azure already accepted on the source disk would
#               leave the machine stopped or half restored (review of
#               SNAPSHOT-NAME-END-1). Get-VmfBoundedDiskName keeps its own
#               trim, and its suffix always ends with the time stamp.
#   capacityReservationGroups - not on the page. The product makes them from
#               alphanumerics and hyphens only, and they end with a code;
#               80 is the product's own bound, the limit of the rows above.
$script:VmfAzureNameRules = @{
    snapshot                 = @{ Max = 80; Allowed = '^[A-Za-z0-9_.\-]+$'; Start = '^[A-Za-z0-9]'; End = '[A-Za-z0-9_]$' }
    disk                     = @{ Max = 80; Allowed = '^[\s\S]+$'; Start = '^[\s\S]'; End = '[\s\S]$' }
    capacityReservationGroup = @{ Max = 80; Allowed = '^[A-Za-z0-9\-]+$'; Start = '^[A-Za-z0-9]'; End = '[A-Za-z0-9]$' }
}

function ConvertTo-VmfAzureName {
    <#
    .SYNOPSIS
        SNAPSHOT-NAME-END-1: a resource name Azure accepts - the name cut so
        that the name and the suffix fit in MaxLength, with no character at its
        start or end that the rule does not allow there.
    .DESCRIPTION
        The suffix is never cut. Characters come off the START of the name
        only when the rule does not allow them there, and off the END of the
        whole name only when the rule does not allow them there - so a name
        that was valid before is the same. The final lab day 2 (2026-11-17)
        found the cause: Get-VmfSafetyCopyName cut a name just after a hyphen,
        and Azure refused the safety copy ("The value of parameter
        snapshot.name is invalid"). A name that cannot be made valid throws
        here, before any call to Azure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Name,
        [Parameter()][AllowEmptyString()][string]$Suffix = '',
        [Parameter(Mandatory)][int]$MaxLength,
        [Parameter(Mandatory)][ValidateSet('snapshot', 'disk', 'capacityReservationGroup')][string]$Rule
    )
    $r = $script:VmfAzureNameRules[$Rule]
    if ($MaxLength -gt $r.Max) { throw "A $Rule name can have at most $($r.Max) characters, not $MaxLength." }
    $room = $MaxLength - $Suffix.Length
    if ($room -lt 1) { throw "The suffix '$Suffix' leaves no room for a $Rule name of at most $MaxLength characters." }

    $base = $Name
    while ($base.Length -gt 0 -and -not ($base -cmatch $r.Start)) { $base = $base.Substring(1) }
    if ($base.Length -gt $room) { $base = $base.Substring(0, $room) }
    # Only the end of the WHOLE name is judged. A suffix that ends well keeps a
    # hyphen before it ('--pristine' was valid, and stays).
    if (-not $Suffix) {
        while ($base.Length -gt 0 -and -not ($base -cmatch $r.End)) { $base = $base.Substring(0, $base.Length - 1) }
    }
    $made = "$base$Suffix"

    if (-not $base -or $made.Length -gt $MaxLength -or -not ($made -cmatch $r.Allowed) -or
        -not ($made -cmatch $r.Start) -or -not ($made -cmatch $r.End)) {
        throw "'$made' is not a valid Azure $Rule name: it must have 1 to $MaxLength characters that the $Rule naming rule allows, and start and end with characters it allows there."
    }
    $made
}
