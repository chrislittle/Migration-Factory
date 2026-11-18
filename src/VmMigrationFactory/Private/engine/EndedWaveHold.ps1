# STALE-WAVE-HOLD-1. A wave worker removes its hold on a machine
# (leases/<machine>.lease) in the finally of worker.ps1, AFTER the state
# machine wrote the machine's final state. A container the platform stops
# between those two writes leaves the hold on a machine whose move ended.
#
# A restore never takes over a wave worker's hold (RESTORE-MID-MOVE-1,
# 2026-10-19), and the wave watchdog runs only while the wave runs: the service
# starts a wave again only for a machine that has not ended. So nothing removed
# that hold, and Restore this machine was refused for a migrated machine until
# somebody used Stop this migration.
#
# Decided 2026-10-30: the service's timer removes it, on these terms -
#   - a WAVE WORKER holds it (never a restore: that job's restart
#     owns its hold, RESTORE-END-JOB-1);
#   - its heartbeat is older than the limit the wave watchdog uses;
#   - the machine's record says a FINAL state - a machine at a working state is
#     resumed by its wave, and its hold stays for that;
#   - no execution of the machine's wave runs (the facade asks Azure, before
#     it calls Remove-VmfEndedWaveHold);
#   - removed only as judged (Remove-VmfExpiredLease -WaveWorkerOnly): a hold
#     renewed or taken in between stays.
# In the same pass, the claim of a MIGRATED or SKIPPED machine is given back,
# by CLAIM-KEPT-AFTER-WAVE-1's one rule (Remove-VmfSettledVmClaim). A failed
# or parked machine keeps its claim: this run still recovers it.

function Get-VmfEndedWaveHolds {
    <#
    .SYNOPSIS
        STALE-WAVE-HOLD-1: the expired holds of wave workers on machines whose
        record says a final state. Read-only.
    .OUTPUTS
        One object per hold: VmId, State, WorkerId.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][int]$TimeoutSeconds = $script:VmfMachineLeaseTimeoutSeconds
    )
    $found = foreach ($lease in @(Get-VmfExpiredLeases -RunPath $RunPath -TimeoutSeconds $TimeoutSeconds)) {
        $holder = [string]$lease.workerId
        $vmId = [string]$lease.vmId
        if (-not $vmId -or (Test-VmfPutBackLeaseHolder -WorkerId $holder)) { continue }
        # A hold on a group of machines (an availability set) has no record,
        # and so is not listed: it refuses no restore, and the next wave's
        # watchdog removes it.
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $vmId
        if (-not $doc -or [string]$doc.state -notin $script:VmfTerminalStates) { continue }
        # WAVE-RUNNING-LEASE-1: the rule the pages say "the service removes the
        # hold" from - so a page says it only of a hold this pass removes.
        if ((Get-VmfMachineHold -State ([string]$doc.state) -Lease $lease -TimeoutSeconds $TimeoutSeconds) -ne 'endedHold') { continue }
        [pscustomobject]@{ VmId = $vmId; State = [string]$doc.state; WorkerId = $holder }
    }
    @($found)
}

function Remove-VmfEndedWaveHold {
    <#
    .SYNOPSIS
        STALE-WAVE-HOLD-1: remove one stopped wave worker's hold on a machine
        whose move ended, and give back the claim of a MIGRATED or SKIPPED
        machine. The caller asked Azure first that no execution of the wave of
        the machine runs.
    .DESCRIPTION
        The record is read again here: a machine that a person sent back to
        work since the listing (a retry) keeps the hold, which its wave's
        watchdog removes. The claim is given back only after this call removed
        the hold, so a claim never goes while a live hold stands.
    .OUTPUTS
        VmId, State, WorkerId, ClaimReleased - or $null when nothing was removed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowEmptyString()][string]$Wave,
        [Parameter()][int]$TimeoutSeconds = $script:VmfMachineLeaseTimeoutSeconds
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc -or [string]$doc.state -notin $script:VmfTerminalStates) { return $null }
    $state = [string]$doc.state
    $lease = Get-VmfLeaseInfo -RunPath $RunPath -VmId $VmId
    $holder = if ($lease) { [string]$lease.workerId } else { '' }
    if (-not (Remove-VmfExpiredLease -RunPath $RunPath -VmId $VmId -TimeoutSeconds $TimeoutSeconds -WaveWorkerOnly)) { return $null }

    $released = $false
    try {
        $claim = Remove-VmfSettledVmClaim -RunPath $RunPath -VmId $VmId
        $released = [bool]($claim -and $claim.Released)
    }
    catch { Write-Warning "The claim of '$(($VmId -split '/')[-1])' was not given back here, and the end of its next wave tries again: $($_.Exception.Message)" }

    $name = ($VmId -split '/')[-1]
    $inWave = if ($Wave) { "wave $Wave" } else { 'any wave of this migration' }
    $free = if ($released) { ' The machine is free for another migration.' } else { '' }
    # STEP-LOG-2: the hold is already removed, so a line that cannot be written
    # must not make this look like a failure.
    Write-VmfStepLine -RunPath $RunPath -Step 'watchdog' -Outcome warn -VmId $VmId `
        -Detail "The worker '$holder' stopped after the state of '$name' became $state, and its hold stayed on the machine. No execution of $inWave runs, so the service removed the hold. No job holds the machine now.$free"
    [pscustomobject]@{ VmId = $VmId; State = $state; WorkerId = $holder; ClaimReleased = $released }
}
