function Remove-VmfWaveSchedule {
    <#
    .SYNOPSIS
        SCHED-1: cancel a scheduled wave before it fires. Cancelling is
        recorded - a schedule that quietly disappeared would be worse than one
        that never existed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][string]$CancelledBy = 'unknown',
        [Parameter()][AllowEmptyString()][string]$Note = ''
    )

    $existing = Read-VmfStoreJson -RunPath $RunPath -RelPath "schedules/$Wave.json" -Depth 8
    if (-not $existing) { throw "No schedule is recorded for wave '$Wave'." }
    # SCHEDULE-START-ONCE-1: a start on record is a start made, or being made.
    # A cancel now would say the wave did not start; the schedule pass removes
    # the start time itself.
    $refusal = Get-VmfScheduleStartRefusal -Schedule $existing -Wave $Wave
    if ($refusal) { throw $refusal }
    if (-not $PSCmdlet.ShouldProcess($Wave, 'cancel the scheduled start')) { return }

    Remove-VmfStoreItem -RunPath $RunPath -RelPath "schedules/$Wave.json"
    # STEP-LOG-4: written after the schedule is removed, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'schedule' -Outcome info `
        -Detail "scheduled start of wave $Wave cancelled by ${CancelledBy}$(if ($Note) { ": $Note" })"

    [pscustomobject]@{ Wave = $Wave; Cancelled = $true; CancelledBy = $CancelledBy; WasDueUtc = $existing.runAtUtc }
}
