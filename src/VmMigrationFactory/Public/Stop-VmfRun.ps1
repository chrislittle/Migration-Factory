function Stop-VmfRun {
    <#
    .SYNOPSIS
        Give up on a run: close out every machine that has not finished, so the
        run can settle and be thrown away.
    .DESCRIPTION
        Found with a run that could not be removed: there was no option to
        cancel a run.

        Because every path assumed a machine eventually reaches an end state
        through the engine. A machine whose worker died, or whose virtual
        machine has since been deleted, never does - and the only per-machine
        action available put it BACK into the pipeline, which is exactly wrong
        when there is nothing left to migrate.

        This touches nothing in Azure. It marks unfinished machines as skipped,
        with the reason and who gave it, releases the run's claims so those
        machines are free for another migration, and pauses the wave so no
        worker picks anything up while it happens. A machine the record says
        is left CHANGED keeps its claim (SKIP-CHANGED-FREED-1,
        Test-VmfMachineLeftChanged): another migration would take its first
        safety copy of the changed machine. Restore this machine, Rebuild this
        machine and Leave this machine out release it once it is mended.

        A machine that is mid-conversion RIGHT NOW is a different matter: a
        live worker is still driving it, and marking it skipped underneath that
        worker would leave two things believing they own one machine. So a live
        lease refuses unless -Force, which is for the case where the worker is
        known to be gone.
    .EXAMPLE
        Stop-VmfRun -RunPath $run -Reason 'lab machines deleted; closing the run out'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][switch]$Force,
        [Parameter()][string]$StoppedBy,
        [Parameter()][int]$LeaseTimeoutSeconds = 900
    )

    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    if (-not $manifest) { throw "There is no run at '$RunPath'." }
    $runId = [string]$manifest.runId
    $plan = Read-VmfPlanDocument -RunPath $RunPath -Depth 24

    $terminal = @('MIGRATED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'SKIPPED')
    $entries = @($plan.entries) | Where-Object { $_ -and $_.vmId }

    if (-not $PSCmdlet.ShouldProcess("run '$runId'", 'End the migration of every unfinished machine')) {
        return [pscustomobject]@{ RunId = $runId; Stopped = $false; Detail = 'not confirmed' }
    }

    $who = if ($StoppedBy) { $StoppedBy } else {
        try { (Get-VmfSignedInIdentity).Identity } catch { 'unknown' }
    }

    # A worker that is still alive is still driving its machine. There is no
    # "list live leases", so this is every lease MINUS the ones the watchdog
    # would already consider dead - which is the same rule the watchdog uses,
    # deliberately, so the two can never disagree about who is alive.
    $liveHolds = {
        $all = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'leases' -Extension '.lease')
        $expired = @(Get-VmfExpiredLeases -RunPath $RunPath -TimeoutSeconds $LeaseTimeoutSeconds |
            ForEach-Object { Get-VmfLeaseRelPath -VmId $_.vmId })
        @($all | Where-Object { "leases/$_" -notin @($expired) }).Count
    }
    # RESTORE-ONE-AT-A-TIME-1: a restore holds its machine the same way.
    $holdsWords = { param([int]$n) "A worker or a restore still holds $n machine(s) in this run and may be changing one right now. Let it reach a safe point, or re-run with -Force if you know that job is gone." }

    # DELETE-UNSTARTED-WAVE-1: look, pause, look again.
    # FIRST a look with nothing written: a live hold refuses here, and the run
    # is never paused. A pause, even for a moment, ends a working wave early -
    # each worker that finishes a machine sees it and takes no more - so a
    # refused Stop must write none (review, 2026-11-16).
    if (-not $Force) {
        $n = & $liveHolds
        if ($n -gt 0) { throw (& $holdsWords $n) }
    }

    # THEN the pause, so nothing new is picked up while this runs. Stop this
    # migration is offered between waves, when the next wave can be starting
    # now: its worker looks for the pause, then holds a machine, and asks for
    # the pause again once it holds one (Get-VmfNextWaveVm). So after the pause
    # is written, either the second look below sees that hold and Stop
    # refuses, or the worker sees the pause and gives the machine back.
    # Created only where there is no pause, so a refusal removes only the pause
    # this call wrote, as it wrote it - never the breaker's or a person's.
    # A hold that appears between the two looks is the one case a refused Stop
    # leaves a pause in place for a moment (STOP-REFUSED-PAUSE-WINDOW-1).
    $ownPause = $null
    if (-not (Test-VmfWaveHalted -RunPath $RunPath)) {
        $pauseText = [ordered]@{
            haltedUtc = (Get-Date).ToUniversalTime().ToString('o')
            reason    = "run stopped by ${who}: $Reason"
        } | ConvertTo-Json -Depth 4
        if (Write-VmfStoreTextExclusive -RunPath $RunPath -RelPath 'halt.flag' -Content $pauseText -UniqueText) { $ownPause = $pauseText }
    }
    if (-not $Force) {
        # Any end of this look but "no live hold" - a hold, or a store that
        # failed - removes the pause this call wrote. A refused Stop leaves the
        # run as it was.
        $cleared = $false
        try {
            $n = & $liveHolds
            if ($n -gt 0) { throw (& $holdsWords $n) }
            $cleared = $true
        }
        finally {
            if (-not $cleared -and $ownPause) {
                $null = Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath 'halt.flag' -ExpectedVersion (Get-VmfDocumentVersion -Text $ownPause)
            }
        }
    }
    # STOP-STATE-SHOWN-1: no HALTED line. The page reads one as the wave safety
    # brake ("The wave paused itself automatically after repeated failures"),
    # and nothing failed: a person stopped the migration, which the 'run' line
    # below says. The list reads the pause from the summary. Never throws.
    if ($ownPause) { Update-VmfRunSummary -RunPath $RunPath -Reason 'paused' | Out-Null }

    # STOP-STATE-SHOWN-1: the record of the stop, which the Migrations page
    # reads to say Stopped - who, when, the note - and to tell a wave the stop
    # ended before it started from a wave that completed
    # (schemas/run-stop.schema.json). Read before any machine is closed out:
    # a wave not started is one in which no machine had a state past PLANNED.
    $docOf = @{}
    foreach ($entry in $entries) { $docOf[[string]$entry.vmId] = Read-VmfStateDoc -RunPath $RunPath -VmId ([string]$entry.vmId) }
    $stateOf = { param($id) $d = $docOf[[string]$id]; if ($d) { [string]$d.state } else { '' } }
    $moved = @($entries | Where-Object { [string]$_.path -eq 'A' -and [string]$_.wave -and [string]$_.wave -ne 'unscheduled' })
    $notStarted = @($moved | ForEach-Object { [string]$_.wave } | Sort-Object -Unique | Where-Object {
            $w = $_
            -not @($moved | Where-Object { [string]$_.wave -eq $w -and (& $stateOf $_.vmId) -and (& $stateOf $_.vmId) -ne 'PLANNED' }).Count
        })
    $closing = @($entries | Where-Object { (& $stateOf $_.vmId) -notin $terminal } | ForEach-Object { [string]$_.vmId })

    # STOP-STATE-SHOWN-1: and every scheduled start of the run goes, so no
    # scheduled start begins a wave of a stopped migration - the service's
    # schedule pass starts a due wave without asking about the pause, and the
    # page showed the start and Cancel the scheduled start after the stop. A
    # start on record goes too: the engine run of that start finds no schedule
    # to remove, and its workers take no machine of a paused run. Listed here,
    # and removed only after the record names them.
    $schedWaves = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'schedules' -Extension '.json' |
        ForEach-Object { [System.IO.Path]::GetFileNameWithoutExtension([string]$_) })

    # The record is CREATED ONCE (review): the first stop's record wins. A
    # second stop, or this stop run again after it ended part way through its
    # closing (hard rule 4), reads machines it already closed out - built from
    # that state, the record said no wave was left unstarted, and the page drew
    # it Complete again. It is written before any machine is closed out and
    # before any schedule goes, so the first try's record names them all.
    $null = Write-VmfStoreJsonExclusive -RunPath $RunPath -RelPath 'stopped.json' -UniqueText -Document ([ordered]@{
        schemaVersion    = 1
        runId            = $runId
        stoppedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        stoppedBy        = $who
        note             = $Reason
        wavesNotStarted  = @($notStarted)
        machines         = @($closing)
        schedulesRemoved = @($schedWaves)
    })

    foreach ($wave in $schedWaves) {
        Remove-VmfStoreItem -RunPath $RunPath -RelPath "schedules/$wave.json"
        Write-VmfStepLine -RunPath $RunPath -Step 'schedule' -Outcome info -Detail "Stop this migration removed the scheduled start of wave $wave."
    }
    $closed = 0
    $released = 0
    $kept = 0
    $powerOwed = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in $entries) {
        $vmId = [string]$entry.vmId
        Remove-VmfLease -RunPath $RunPath -VmId $vmId -Force -ErrorAction SilentlyContinue
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $vmId
        $state = if ($doc) { [string]$doc.state } else { '' }
        if ($state -notin $terminal) {
            if (-not $doc) { New-VmfStateDoc -RunPath $RunPath -RunId $runId -VmId $vmId -Wave ([string]$entry.wave) | Out-Null }
            if ($doc -and $doc.PSObject.Properties['rollbackPending'] -and $doc.rollbackPending) {
                # PREP-ROLLBACK-1 (review 2, finding 1): a rollback a worker did
                # not finish. Closing it as "left out" would hide a machine that
                # may be stopped, with some disks swapped. Say so, where a person
                # looks, and drop the checkpoint with the same write.
                Add-VmfStateTransition -RunPath $RunPath -VmId $vmId -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail `
                    -Detail "run stopped by ${who} while the rollback of this machine was not finished: $Reason. The machine may be stopped, and some disks may be swapped. Restore it from the first safety copy, or rebuild it." `
                    -ReasonCode 'rollbackFailed' -MachineState 'changed' -ClearProperty @('rollbackPending') | Out-Null
            }
            else {
                # STOP-MIDMOVE-FREED-1: where the close leaves the machine, by
                # the rule a stop in that step is stamped with
                # (Get-VmfStateLeftMachineState). A machine part way through its
                # move was closed with nothing on record, read as not changed,
                # and freed: another migration then copied the half-moved
                # machine as it was. A machine that never started is untouched.
                $left = Get-VmfStateLeftMachineState -State $(if ($state) { $state } else { 'PLANNED' }) -Doc $doc
                $leftWords = if ($left -eq 'changed') { ". The move of this machine was not finished, so it may not be as it was. Restore it from the first safety copy, or rebuild it." } else { '' }
                # POWER-ONLY-CHANGED-1: Checking started a machine it found
                # deallocated or stopped, and nothing else changed yet. This
                # touches nothing in Azure, so the machine may run: recorded
                # changed in its power state only, as a stop whose put-back
                # Azure refused is recorded.
                $powerLeft = @{}
                $powerOnly = Get-VmfPowerOnlyLeft -State $state -Doc $doc
                if ($powerOnly) {
                    $left = 'changed'
                    $powerLeft.PowerNotPutBack = $powerOnly
                    $leftWords = ". The product changed the power state of this machine, and it was $(Get-VmfPowerStateName -Power $powerOnly) before the move. Nothing else on the machine changed. The product returns it to that power state."
                }
                Add-VmfStateTransition -RunPath $RunPath -VmId $vmId -NewState 'SKIPPED' -Outcome skip `
                    -MachineState $left -Detail "run stopped by ${who}: $Reason$leftWords" @powerLeft | Out-Null
            }
            $closed++
        }
        # SKIP-CHANGED-FREED-1: read again, after the line above - a rollback
        # a worker did not finish is closed out as changed just now.
        # POWER-ONLY-CHANGED-1: every machine whose power state the product
        # changed and did not return - closed out just now, or parked by an
        # earlier stop. The service starts the engine operation 'powerback'
        # for them (Restore-VmfMachinePower); this touches nothing in Azure.
        $leftDoc = Read-VmfStateDoc -RunPath $RunPath -VmId $vmId
        if (Get-VmfPowerOwed -Doc $leftDoc) { $powerOwed.Add($vmId) }
        if (Test-VmfMachineLeftChanged -Doc $leftDoc) { $kept++; continue }
        if ((Remove-VmfVmClaim -RunPath $RunPath -VmId $vmId -RunId $runId).Released) { $released++ }
    }

    # A broken log must not strand a run. Found on a real store: an older run's
    # events.jsonl was a block blob, so appending returned 409 and the run
    # could not be closed out or removed at all. The action is what matters;
    # the line about it is best-effort, and its failure is reported rather than
    # swallowed.
    # STEP-LOG-4: through the one helper, so the scan covers it. The warning
    # goes to the engine output, and the result still carries it.
    # STOP-STATE-SHOWN-1: "1 machine", not "1 machines".
    $machinesWord = if ($closed -eq 1) { 'machine' } else { 'machines' }
    Write-VmfStepLine -RunPath $RunPath -Step 'run' -Outcome ok -Detail "run stopped by ${who}: $Reason (the migration of $closed $machinesWord ended)" `
        -WarningVariable lostLine
    $logWarning = if ($lostLine) { @($lostLine | ForEach-Object { [string]$_ }) -join ' ' } else { $null }

    # REPORT-AUTO-1 review 3: the machines it closed out change what the
    # record and the report say. Written now, as after a wave; it never
    # throws, and a failure is a warning the daily check repairs.
    Save-VmfRecordAndReport -RunPath $RunPath -Reason 'stopped' | Out-Null
    # APPROVE-GROUP-1: and the summary the list on the Migrations page reads.
    # Never throws.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'runStopped' | Out-Null

    [pscustomobject]@{
        RunId = $runId
        Stopped = $true
        MachinesClosedOut = $closed
        MachinesReleased = $released
        MachinesKept = $kept
        PowerOwed = @($powerOwed)
        StoppedBy = $who
        Reason = $Reason
        LogWarning = $logWarning
    }
}
