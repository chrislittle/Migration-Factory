function Set-VmfWaveSchedule {
    <#
    .SYNOPSIS
        SCHED-1: schedule a wave to start later instead of now.
    .DESCRIPTION
        A schedule is a CONTRACT DOCUMENT like every other decision the product
        records - schedules/<wave>.json in the run store - not a hidden timer
        somewhere. That is what makes it visible in the dashboard, cancellable
        before it fires, and auditable afterwards.

        The approval gate stays AHEAD of the schedule: scheduling a wave is not
        approving it. When the time comes, an unapproved wave is left alone and
        reported rather than started, so a schedule can never be used to slip
        past sign-off.
    .EXAMPLE
        Set-VmfWaveSchedule -RunPath .\run1 -Wave prod-1 -RunAtUtc (Get-Date).AddHours(8) -ScheduledBy 'lead@contoso.com' -Note 'change window'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][datetime]$RunAtUtc,
        [Parameter()][string]$ScheduledBy = 'unknown',
        [Parameter(Mandatory)][string]$Note,
        # MACHINES-AT-ONCE-RANGE-1: no number of machines at once. A scheduled
        # wave starts at its own number as it is when the time comes, so a
        # change on the wave editor after the schedule is never lost.
        # Arch section 9: a wave that cannot finish inside its window should
        # not start. Recorded now, enforced when the window is reached.
        [Parameter()][int]$WindowMinutes
    )

    $runAt = $RunAtUtc.ToUniversalTime()
    if ($runAt -le (Get-Date).ToUniversalTime()) {
        throw "The time to start '$Wave' is already in the past - pick a time in the future, or start the wave now."
    }
    # SCHEDULE-SCHEMA-1: a window is a number of minutes more than 0, or none
    # (0). A negative window was written, and the wave then never fitted it.
    if ($WindowMinutes -lt 0) {
        throw "400: The time window for '$Wave' must be a number of minutes that is more than 0. To schedule the wave with no time window, leave the window empty."
    }
    # The schema requires a name of who scheduled the wave.
    if ([string]::IsNullOrWhiteSpace($ScheduledBy)) { $ScheduledBy = 'unknown' }
    # SCHEDULE-START-ONCE-1: a new time written over a start on record would
    # lose the record, and the wave would start again at the new time.
    $refusal = Get-VmfScheduleStartRefusal -Schedule (Read-VmfStoreJson -RunPath $RunPath -RelPath "schedules/$Wave.json" -Depth 8) -Wave $Wave
    if ($refusal) { throw $refusal }
    if (-not $PSCmdlet.ShouldProcess($Wave, "schedule to start at $($runAt.ToString('u'))")) { return }

    $doc = [ordered]@{
        schemaVersion = (Get-VmfWaveScheduleSchemaVersion)
        wave          = $Wave
        runAtUtc      = $runAt.ToString('o')
        scheduledUtc  = (Get-Date).ToUniversalTime().ToString('o')
        scheduledBy   = $ScheduledBy
        note          = $Note
        windowMinutes = $(if ($WindowMinutes) { $WindowMinutes } else { $null })
        state         = 'pending'
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath "schedules/$Wave.json" -Document $doc
    # STEP-LOG-4: written after the schedule is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'schedule' -Outcome ok `
        -Detail "wave $Wave scheduled for $($runAt.ToString('u')) by ${ScheduledBy}: $Note"
    # SCHEDULE-PASS-DUE-1: after the schedule is saved, the five-minute pass
    # checks this run, so the wave starts at its time. Never throws.
    Add-VmfRunScheduleDue -RunPath $RunPath -Reason 'schedule' | Out-Null

    [pscustomobject]$doc
}
