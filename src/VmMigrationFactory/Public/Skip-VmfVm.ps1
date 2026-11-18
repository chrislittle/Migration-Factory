function Skip-VmfVm {
    <#
    .SYNOPSIS
        SKIP-ONE-1: leave ONE machine out of a migration, so the rest can
        finish.
    .DESCRIPTION
        A machine parked below the MANA kernel floor held its wave, and
        nothing could skip that one machine in the wave.

        `SKIPPED` has always been a state, and the only thing that ever set it
        was `Stop-VmfRun`, which closes out the WHOLE run. So at a parked
        machine the choices were rebuild it, accept the risk, or try again.
        "Leave this one out and let the others finish" existed nowhere - not
        in the engine, not in the service, not in the app.

        THIS TOUCHES NOTHING IN AZURE. It records that the machine is not
        going to migrate in this run, with the reason and who gave it, and
        releases the run's claim so another migration may take the machine
        later - except a machine the stop left CHANGED, whose claim this run
        keeps until a restore mends it (SKIP-CHANGED-FREED-1);
        `ClaimReleased` says which.

        IT IS NOT "NOTHING HAPPENED TO THIS MACHINE", and the caller must not
        pretend otherwise. Skipping leaves the machine exactly as it is. The
        returned `MachineState` says where the stop that parked it left it -
        untouched, restored, changed, or $null when nothing on record says
        (Get-VmfSkipMachineState, SKIP-PREPARED-WORDS-1). It is the value the
        engine recorded on the stop, never the steps the history holds: a
        preparation that changed the guest is rolled back before the machine
        parks, so "it was prepared" was false on a machine that rolled back.

        A machine being worked on RIGHT NOW is refused: a live worker owns it,
        and marking it skipped underneath would leave two things believing
        they hold one machine. Same reason `Stop-VmfRun` refuses a live lease.
    .PARAMETER RunPath
        The migration run.
    .PARAMETER VmId
        The machine to leave out. It must be in this run's plan.
    .PARAMETER Reason
        Why. Recorded with the decision - a machine that did not migrate is a
        decision somebody owns.
    .PARAMETER SkippedBy
        Who asked, when the caller acts for somebody. The facade does.
    .EXAMPLE
        Skip-VmfVm -RunPath $run -VmId $id -Reason 'kernel below the floor; migrating it after patching'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Reason,
        [Parameter()][string]$SkippedBy
    )

    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    if (-not $manifest) { throw "There is no run at '$RunPath'." }
    $runId = [string]$manifest.runId

    $plan = Read-VmfPlanDocument -RunPath $RunPath -Depth 24
    $entry = @($plan.entries) | Where-Object { $_ -and [string]$_.vmId -eq $VmId } | Select-Object -First 1
    if (-not $entry) {
        throw "'$VmId' is not in this migration's plan, so there is nothing to leave out."
    }
    # VMID-CASE-1: from here, the ID as the plan spells it. The entry was found
    # ignoring case; the record is kept, and read by the worker, under the
    # plan's spelling - a record under another spelling is one no worker reads.
    $VmId = [string]$entry.vmId

    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $state = if ($doc) { [string]$doc.state } else { 'PLANNED' }

    # Already done is not something to skip, and recording "skipped" for a
    # machine that moved would be a false record of what happened to it.
    if ($state -eq 'MIGRATED') {
        throw "'$VmId' has already migrated, so it cannot be left out."
    }
    if ($state -eq 'SKIPPED') {
        # Hard rule 4: safe to re-run, and it says so rather than writing a
        # second identical line into the machine's history.
        return [pscustomobject]@{
            VmId = $VmId; RunId = $runId; AlreadySkipped = $true
            ClaimReleased = $false; MachineState = $null; SkippedBy = $SkippedBy; Reason = $Reason
        }
    }

    # SETTLED states are the ones a person can act on. Anything else is a
    # machine a worker is driving right now.
    $parked = @('PLANNED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION')
    if ($state -notin $parked) {
        throw ("'$VmId' is still working - it is at '$state'. Stop the run, or wait for it to " +
               'reach a point where somebody can decide, then leave it out.')
    }

    $who = if ($SkippedBy) { $SkippedBy } else { (Get-VmfSignedInIdentity).Identity }
    if (-not $PSCmdlet.ShouldProcess($VmId, "leave out of run '$runId'")) { return }

    # SKIP-PREPARED-WORDS-1: where the stop left the machine, from the value
    # the engine recorded. A machine that has not started is untouched.
    $started = @(@($(if ($doc) { $doc.history })) | Where-Object { $_ -and [string]$_.state -and [string]$_.state -ne 'PLANNED' })
    $machineState = if (-not $started.Count) { 'untouched' } else { Get-VmfSkipMachineState -Doc $doc }

    if (-not $doc) {
        New-VmfStateDoc -RunPath $RunPath -RunId $runId -VmId $VmId -Wave ([string]$entry.wave) | Out-Null
    }
    Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState 'SKIPPED' -Outcome skip `
        -Detail "left out by ${who}: $Reason" | Out-Null

    # The claim is what stops another migration taking this machine. A run
    # that has given up on it must not go on holding it - unless the stop
    # left the machine CHANGED (SKIP-CHANGED-FREED-1). Another migration asks
    # only the claim, and its first safety copy would take the changed machine
    # as "as it was", so a later rollback of it would put back the changed
    # machine. This run keeps it until Restore this machine or Rebuild this
    # machine mends it (Test-VmfMachineLeftChanged, the rule the settled-claim
    # release and Stop-VmfRun ask too). It is still left out: the wave goes on.
    $released = $false
    if ($machineState -ne 'changed') {
        $released = (Remove-VmfVmClaim -RunPath $RunPath -VmId $VmId -RunId $runId).Released
    }

    # STEP-LOG-4: written after the machine is SKIPPED and its claim released, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'skip' -Outcome skip -VmId $VmId `
        -Detail "left out by ${who}: $Reason"

    # APPROVE-GROUP-1: the list on the Migrations page counts this machine as
    # left out. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'machineSkipped' -Wave ([string]$entry.wave) | Out-Null

    # POWER-ONLY-CHANGED-1 (2026-11-06: a machine the product turned on at
    # any step, and then left out or stopped, must be turned off again): the
    # power state the product changed and did not return. This touches
    # nothing in Azure; the service starts the engine operation 'powerback'
    # (Restore-VmfMachinePower), which returns it and then gives back the
    # claim, and the machine panel offers it again while it is owed.
    $powerOwed = Get-VmfPowerOwed -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId)

    [pscustomobject]@{
        VmId = $VmId; RunId = $runId; AlreadySkipped = $false
        ClaimReleased = [bool]$released; MachineState = $machineState
        SkippedBy = $who; Reason = $Reason; PowerOwed = $powerOwed
    }
}
