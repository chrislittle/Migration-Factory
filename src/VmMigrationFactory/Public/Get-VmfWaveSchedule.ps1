function Get-VmfWaveSchedule {
    <#
    .SYNOPSIS
        SCHED-1: the schedules recorded for a run (all, or one wave's).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][string]$Wave
    )

    if ($Wave) {
        $one = Read-VmfStoreJson -RunPath $RunPath -RelPath "schedules/$Wave.json" -Depth 8
        return @($(if ($one) { $one } else { @() }))
    }
    $all = foreach ($name in Get-VmfStoreNames -RunPath $RunPath -Folder 'schedules' -Extension '.json') {
        Read-VmfStoreJson -RunPath $RunPath -RelPath "schedules/$name" -Depth 8
    }
    return @($all | Where-Object { $_ })
}
