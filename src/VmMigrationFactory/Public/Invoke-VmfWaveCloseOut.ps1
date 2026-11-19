function Invoke-VmfWaveCloseOut {
    <#
    .SYNOPSIS
        REACH-1: give a finished wave's capacity reservation back, and say so
        loudly when it is being held instead.
    .DESCRIPTION
        Ruled 2026-08-30: release is automatic at close-out, with a
        button for everything this deliberately will not cover. An unused
        On-Demand Capacity Reservation bills at the VM rate until somebody
        deletes it, and "somebody remembers" is not a cost control.

        It releases only when every machine in the wave reached a settled
        state. A machine parked on a decision, or rolled back awaiting a
        retry, still intends to migrate - handing its guarantee back would
        give scarce capacity to somebody else and leave the retry to chance.

        Every outcome is written to the run's event stream, including the one
        where nothing happened, because capacity that is quietly still held
        is exactly the money nobody notices.
    .OUTPUTS
        @{ Action = 'released'|'held'|'none'; Released = <int>; Reason = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        # The Start-VmfWave result: StateCounts + Halted.
        [Parameter()][AllowNull()]$Result
    )

    # REPORT-AUTO-1 review 1: one container's share of a wave another
    # container still runs. The wave has not closed, so there is nothing to
    # release and nothing to warn about yet; the last container closes it.
    if (Test-VmfWaveShareOnly -Result $Result) {
        return @{ Action = 'none'; Released = 0; Reason = 'another container is still running this wave' }
    }

    # Is there anything to release at all? A BestEffort wave never reserved
    # anything, and asking for a capacity resource group it does not need would
    # turn a successful wave into a failed job.
    $held = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$_" -Depth 12 } |
        Where-Object { $_.wave -eq $Wave -and $_.state -in @('RESERVED', 'CONSUMED') })
    if ($held.Count -eq 0) {
        return @{ Action = 'none'; Released = 0; Reason = 'this wave reserved no capacity' }
    }

    $verdict = Test-VmfWaveFinished -StateCounts $Result.StateCounts -Halted ([bool]$Result.Halted)
    if (-not $verdict.Finished) {
        # MANUAL-REVIEW-1 (2026-11-13): an on-demand capacity
        # reservation bills until every machine of the wave has ended and the
        # product releases it, or until a person selects Release.
        $countSaid = if ($held.Count -eq 1) { '1 on-demand capacity reservation' } else { "$($held.Count) on-demand capacity reservations" }
        $detail = ("Wave '$Wave' keeps its $countSaid, and Azure bills them, because $($verdict.Reason). " +
                   'The product releases them when every machine of the wave has ended. To release them now, select Release on the wave.')
        Write-VmfStepLine -RunPath $RunPath -Step 'odcr' -Outcome warn -Detail $detail
        return @{ Action = 'held'; Released = 0; Reason = $verdict.Reason }
    }

    try {
        # RESERVING-STUCK-1 found this counting the ONE result object, so it
        # said "released 1" whatever it released. It is the list inside.
        $outcome = Remove-VmfCapacityReservations -OutPath $RunPath -Wave $Wave
        $released = @($outcome.Released)
        $left = @($outcome.NotReleased)
        $releasedSaid = if ($released.Count -eq 1) { '1 on-demand capacity reservation' } else { "$($released.Count) on-demand capacity reservations" }
        $leftSaid = if ($left.Count -eq 1) { '1 was' } else { "$($left.Count) were" }
        if ($left.Count -gt 0) {
            Write-VmfStepLine -RunPath $RunPath -Step 'odcr' -Outcome warn `
                -Detail ("Every machine of wave '$Wave' has ended. The product released $releasedSaid, and $leftSaid not released, so Azure can still bill them. " +
                         'Select Release on the wave.')
        }
        else {
            Write-VmfStepLine -RunPath $RunPath -Step 'odcr' -Outcome ok `
                -Detail "Wave '$Wave' finished. The product released $releasedSaid, and Azure accepted the release."
        }
        @{ Action = 'released'; Released = $released.Count; Reason = $verdict.Reason }
    }
    catch {
        # Close-out failing must not fail the wave: the machines migrated. But
        # this is the case that silently bills, so it is said as loudly as the
        # run store allows.
        Write-VmfStepLine -RunPath $RunPath -Step 'odcr' -Outcome fail `
            -Detail ("Every machine of wave '$Wave' has ended, but the product did not release its on-demand capacity reservations, and Azure bills them: $($_.Exception.Message). " +
                     'Select Release on the wave.')
        @{ Action = 'held'; Released = 0; Reason = "release failed: $($_.Exception.Message)" }
    }
}
