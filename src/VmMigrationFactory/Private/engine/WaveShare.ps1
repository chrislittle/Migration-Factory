# REPORT-AUTO-1 review 1: a wave split over containers (SCALE-2) is finished
# by the LAST container. One whose workers are done while another container
# still works returns early with FinishedShare - and the engine used to close
# the wave out and write the record and report after it all the same. So a
# half-finished report could land after the last container's whole one, and
# the close-out warned that reservations were "STILL HELD" while the wave was
# still running in the other container.

function Test-VmfWaveShareOnly {
    <#
    .SYNOPSIS
        True when a Start-VmfWave result is one container's share of a wave
        that another container still runs - so the wave has not closed, and
        nothing that belongs to a closed wave may happen after it. Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Result)
    if ($null -eq $Result) { return $false }
    $p = $Result.PSObject.Properties['FinishedShare']
    [bool]($p -and $p.Value)
}
