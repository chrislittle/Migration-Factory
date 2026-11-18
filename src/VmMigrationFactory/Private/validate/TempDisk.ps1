# LINUX-TEMP-1 (found live in a demo, 2026-08-28).
#
# Two machines migrated correctly to D2ds_v6/NVMe and were then held with
# "Guest validation FAILED: fstab mounts", because the cloud image's temp-disk
# entry no longer resolved. Such machines must not always fail.
#
# Not failing is only half the answer. A machine delivered without its
# temporary disk, and nobody told, is worse than one held - plenty of Linux
# workloads put swap or scratch on /mnt. So the guest reports what it has, the
# capture recorded what it had, and this compares the two: never a failure,
# always an answer.
#
# The v6 temporary disk is an NVMe namespace that arrives RAW on every start.
# Whether anything re-creates a filesystem on it belongs to the machine's own
# image or to a boot task we may install later - not to a validation gate.

function Test-VmfTempDiskOutcome {
    <#
    .SYNOPSIS
        Compare the temporary disk before and after the move.
    .PARAMETER CapturedMounted
        Whether a temporary disk was mounted BEFORE. $null when the machine
        was captured before this fact existed - which stays unknown, and is
        never read as "it was fine".
    .OUTPUTS
        @{ Ok = <bool>; Changed = <bool>; Detail = <string> }
        Ok is always true: this is never the thing that fails a migration.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$CapturedMounted,
        [Parameter()][AllowNull()]$Checks
    )

    $check = @($Checks) | Where-Object { $_ -and [string]$_.name -eq 'temp disk mount' } | Select-Object -First 1
    $afterMounted = $null
    if ($check) { $afterMounted = ([string]$check.status -eq 'PASS') }
    $afterDetail = if ($check) { [string]$check.detail } else { '' }

    if ($null -eq $CapturedMounted) {
        return @{
            Ok = $true; Changed = $false
            Detail = 'the temporary disk cannot be compared - this machine was captured before that was recorded, so what it had before is not known'
        }
    }
    if (-not [bool]$CapturedMounted) {
        return @{ Ok = $true; Changed = $false; Detail = 'no temporary disk was mounted before the move either' }
    }
    if ($afterMounted) {
        return @{ Ok = $true; Changed = $false; Detail = "the temporary disk is there: $afterDetail" }
    }

    # The case that started all this. Say it in the words an operator needs,
    # including what to do, because "not mounted" alone is a puzzle.
    $extra = if ($afterDetail -match 'raw') {
        ' On the new size, it is a raw device with nothing on it yet.'
    } else { '' }
    @{
        Ok = $true; Changed = $true
        Detail = ("This machine's temporary disk (/mnt) was mounted before the move and is not mounted now.$extra " +
                  'Nothing on a temporary disk survives a move - it is scratch space that is wiped whenever the machine stops - ' +
                  'but anything configured to use it, swap most often, will not find it until it is prepared again.')
    }
}
