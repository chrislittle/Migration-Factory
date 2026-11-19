function Test-VmfWaveWindow {
    <#
    .SYNOPSIS
        SCHED-1 / arch section 9: would this wave finish inside its
        maintenance window? Answered before it starts, not discovered halfway.
    .DESCRIPTION
        A wave that overruns its change window is worse than one that never
        started: machines are mid-migration when the window closes. So a
        scheduled wave carrying a window is checked first, and refused with
        the numbers if it will not fit.

        Returns the verdict AND the reasoning, so the answer can be shown to
        a person rather than just enforced.
    .EXAMPLE
        Test-VmfWaveWindow -RunPath .\run1 -PlanPath .\run1\plan.json -Wave prod-1 -WindowMinutes 240
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][int]$WindowMinutes
    )

    $plan = Read-VmfPlanFile -Path $PlanPath -Depth 24
    $entries = @(@($plan.entries) | Where-Object { [string]$_.wave -eq $Wave -and $_.path -eq 'A' })
    if (-not $entries.Count) { throw "Wave '$Wave' has no machines to migrate." }

    $docs = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$_" })

    # MACHINES-AT-ONCE-RANGE-1: the wave's own number, read when the check
    # runs - never a number a schedule kept from when it was made.
    $throttle = Get-VmfWaveThrottle -Entries @(@($plan.entries) | Where-Object { [string]$_.wave -eq $Wave })
    $estimate = Get-VmfWaveDurationEstimate -Entries $entries -StateDocs $docs -Throttle $throttle
    $fits = $estimate.EstimateMinutes -le $WindowMinutes

    [pscustomobject]@{
        Wave            = $Wave
        Fits            = $fits
        WindowMinutes   = $WindowMinutes
        EstimateMinutes = $estimate.EstimateMinutes
        Machines        = $estimate.Machines
        Throttle        = $estimate.Throttle
        BasedOn         = $estimate.BasedOn
        Reason          = $(if ($fits) {
            "about $($estimate.EstimateMinutes) minutes for $($estimate.Machines) machines, inside the $WindowMinutes minute window"
        } else {
            "about $($estimate.EstimateMinutes) minutes for $($estimate.Machines) machines, longer than the $WindowMinutes minute window - start it in a longer window, raise how many run at once, or split the wave"
        })
    }
}
