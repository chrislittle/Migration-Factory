function Remove-VmfExpiredSafetyCopies {
    <#
    .SYNOPSIS
        WAVE-2 lever 7: delete the safety copies of machines that have been
        migrated for longer than their wave's accepted retention.
    .DESCRIPTION
        keepSnapshotDays sat in the contract unread for weeks. It now defaults
        to 7 days and is wired - because the acceptance screen promises a
        customer their copies are kept for N days, and until now the truth was
        forever, until someone noticed the storage bill.

        This is the only code in the product that deletes the last copy of a
        machine as it was before migration, so it is deliberately narrow:

          * only machines that reached MIGRATED. Parked, failed and in-flight
            machines keep their copies at any age - those are the machines
            somebody may still need to roll back.
          * the clock starts when the machine reached MIGRATED.
          * the retention is read per machine from its own plan entry, because
            two waves in one run may have accepted different answers.
          * an unreadable retention keeps the copies and SAYS so.
          * deletion is recorded on the machine's state document, so a later
            restore attempt can say what happened instead of failing with a
            snapshot that mysteriously does not exist.

        ROLLBACK-DISKS-FIRST-1: it also deletes the disks made for the way
        back that nothing used - a machine's earlier attempts' at any time,
        and this attempt's once its move has ended (MIGRATED,
        FAILED_ROLLED_BACK, SKIPPED). A machine that waits for a decision or
        needs attention keeps them. Never a disk that is attached.

        MADE-DISK-RECORD-1 (decided 2026-10-23): and the disks a
        rollback, Restore this machine or Rebuild this machine made from a copy
        that nothing used, once the machine's move has ended
        (Get-VmfDueMadeDisks). Each is read first: never one that is attached,
        and never one a refused swap still waits to put on the machine. A
        machine a restore, a rebuild or a wave holds now keeps every disk.

        Deleting a customer's restore points is never a side effect of starting
        a wave - it is an act somebody runs, or schedules, on purpose. REACH-1
        wires the scheduled half: the facade's daily RetentionRunner previews
        each run with -WhatIf and starts an engine job only for runs that
        actually have something expired, and the app has a button. Until then
        NOTHING ran it, so the acceptance screen's promise that copies are kept
        for N days was true only in the direction that costs money.
    .EXAMPLE
        Remove-VmfExpiredSafetyCopies -RunPath $run -PlanPath $run/plan.json -WhatIf
        Show what would be deleted, and why, without touching anything.
    .EXAMPLE
        Remove-VmfExpiredSafetyCopies -RunPath $run -PlanPath $run/plan.json -Wave 'first-five'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter()][string]$Wave,
        # Testability: the age rule is evaluated against this, not the clock.
        [Parameter()][datetime]$AsOfUtc = [datetime]::UtcNow,
        [Parameter()][string]$DeletedBy
    )

    $planText = Read-VmfTextDocument -Path $PlanPath
    if (-not $planText) { throw "No plan found at '$PlanPath'." }
    $plan = $planText | ConvertFrom-Json -Depth 24
    $entries = @($plan.entries)
    if ($Wave) { $entries = @($entries | Where-Object { $_.wave -eq $Wave }) }
    if (-not $entries) { throw "No machines to consider$(if ($Wave) { " in wave '$Wave'" }) - nothing to delete." }

    $docs = @(foreach ($e in $entries) { Read-VmfStateDoc -RunPath $RunPath -VmId $e.vmId })
    $found = Get-VmfExpiredSafetyCopies -StateDocs @($docs | Where-Object { $_ }) -PlanEntries $entries -NowUtc $AsOfUtc

    $who = if ($DeletedBy) { $DeletedBy } else {
        try { (Get-VmfSignedInIdentity).Identity } catch { 'unknown' }
    }

    $deleted = [System.Collections.Generic.List[object]]::new()
    # RETENTION-LOCK-PUTBACK-1: machines with a copy that was not deleted.
    $notDeleted = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $found.Eligible) {
        $name = ($item.VmId -split '/')[-1]
        $target = "$name (migrated $($item.AgeDays) days ago, kept for $($item.KeepDays))"
        if (-not $PSCmdlet.ShouldProcess($target, 'Delete the safety copies')) { continue }

        # SAFETY-3: the product's own lock comes off first - it is the one
        # thing that would refuse the delete. COPY-DELETE-LOCK-RACE-1: the
        # unlock waits until Azure no longer lists the lock, and the delete
        # takes ScopeLocked as temporary for a fixed number of tries.
        # RETENTION-LOCK-PUTBACK-1: through the SAME code as Delete the copies
        # as well (Remove-VmfRunSafetyCopies). A refused delete gets its lock
        # back, with the note the copy got when it was taken, and a 'retention'
        # fail line names the copy, Azure's words and whether the lock is back.
        # Before, the error left this function: the copy stayed with no lock,
        # and the machines after it were not cleaned.
        $doc = @($docs | Where-Object { $_ -and [string]$_.vmId -eq [string]$item.VmId }) | Select-Object -First 1
        $runIdForLock = if ($doc -and $doc.PSObject.Properties['runId'] -and $doc.runId) { [string]$doc.runId } else { Split-Path $RunPath -Leaf }
        $owners = @{}
        foreach ($snapId in @($item.SnapshotIds)) { if ($snapId) { $owners[[string]$snapId] = $name } }
        # Review of COPY-DELETE-LOCK-RACE-1: eligibility is read once, and the lock
        # read-back makes each machine's delete take about a minute longer. A
        # machine a restore or a wave holds now keeps its copies and its locks -
        # asked again just before the unlock, as the disk loops below ask.
        if (Test-VmfMachineHeldNow -RunPath $RunPath -VmId $item.VmId) { continue }
        $copies = Remove-VmfRunSafetyCopies -RunPath $RunPath -SnapshotIds @($item.SnapshotIds) -Owners $owners -RunId $runIdForLock `
            -Step 'retention' -VmId $item.VmId
        if (@($copies.Failed).Count) {
            # Not recorded as deleted: the next daily cleanup tries the copies
            # that are left, and counts the ones gone as already gone.
            $notDeleted.Add([pscustomobject]@{ VmId = $item.VmId; Failed = @($copies.Failed) })
            continue
        }

        # Record BEFORE claiming success anywhere else: a machine whose copies
        # are gone but whose document still points at them is the confusing
        # failure this record exists to prevent (the same class as the merge
        # bug the safety drill found).
        Set-VmfSafetyCopiesDeleted -RunPath $RunPath -VmId $item.VmId -SnapshotIds @($item.SnapshotIds) `
            -KeepDays $item.KeepDays -DeletedBy $who -AsOfUtc $AsOfUtc

        # RETAIN-SHOW-1: a sentence a person reads in the activity log. The
        # scheduled pass signs as an account, so it is named for what it is.
        $by = if ($who -eq 'retention (scheduled)') { 'The daily cleanup' } else { $who }
        # STEP-LOG-4: every line below is written after Azure deleted something,
        # so a line that cannot be written is a warning: it never stops the
        # cleanup of the next machine, or loses the list of what it deleted.
        Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome ok -VmId $item.VmId `
            -Detail ("$by deleted the $(@($item.SnapshotIds).Count) safety copies of this machine. " +
                     "It was migrated $([math]::Round([double]$item.AgeDays)) days ago, and its wave keeps copies for $($item.KeepDays) days.")
        $deleted.Add($item)
    }

    foreach ($s in $found.Skipped) {
        Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome warn -VmId $s.VmId -Detail $s.Reason
    }

    # ROLLBACK-DISKS-FIRST-1: the rollback disks that nothing
    # used, once the machine's move has ended - and an earlier attempt's at any
    # time (Get-VmfDueRollbackDisksBeforeMove). Not the copies, so no waiting days. Each
    # is read first, and one attached to anything is kept.
    # MADE-DISK-RECORD-1: a machine a restore, a rebuild or a wave holds now
    # keeps every disk - that job may be about to put one on the machine. Asked
    # again just before each delete.
    $diskDocs = @($docs | Where-Object { $_ -and -not (Test-VmfMachineHeldNow -RunPath $RunPath -VmId ([string]$_.vmId)) })
    $disksDue = @(Get-VmfDueRollbackDisksBeforeMove -StateDocs $diskDocs)
    $disksDeleted = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $disksDue) {
        $name = ($item.VmId -split '/')[-1]
        if (-not $PSCmdlet.ShouldProcess($name, "Delete $(@($item.Disks).Count) rollback disks that nothing used")) { continue }
        if (Test-VmfMachineHeldNow -RunPath $RunPath -VmId $item.VmId) { continue }
        $result = Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $RunPath -VmId $item.VmId -Disks @($item.Disks) -Step 'retention'
        $by = if ($who -eq 'retention (scheduled)') { 'The daily cleanup' } else { $who }
        if (@($result.Deleted).Count) {
            Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome ok -VmId $item.VmId `
                -Detail "$by deleted the rollback disks of this machine, which nothing used: $(@($result.Deleted | ForEach-Object { "'$_'" }) -join ', ')."
            $disksDeleted.Add([pscustomobject]@{ VmId = $item.VmId; Disks = @($result.Deleted) })
        }
        if (@($result.Failed).Count) {
            Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome warn -VmId $item.VmId `
                -Detail "$by did not delete these rollback disks of this machine: $(@($result.Failed | ForEach-Object { "'$($_.name)' ($($_.why))" }) -join ', ')."
        }
    }

    # MADE-DISK-RECORD-1: the disks a rollback or a restore made
    # from a copy that nothing used, once the move has ended. Not the copies,
    # so no waiting days. Each is read first, and one attached to anything is
    # kept and marked used.
    $madeDue = @(Get-VmfDueMadeDisks -StateDocs $diskDocs)
    $madeDeleted = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $madeDue) {
        $name = ($item.VmId -split '/')[-1]
        if (-not $PSCmdlet.ShouldProcess($name, "Delete $(@($item.Disks).Count) disks made from the safety copies that nothing used")) { continue }
        if (Test-VmfMachineHeldNow -RunPath $RunPath -VmId $item.VmId) { continue }
        $by = if ($who -eq 'retention (scheduled)') { 'The daily cleanup' } else { $who }
        # MADE-DISK-RECORD-1 review: a restore that died after it
        # deleted the machine's definition leaves its disks attached to
        # nothing - and they can be what rebuilds the machine. So the cleanup
        # deletes them only when Azure says the machine exists. "Not found"
        # keeps them, and so does a read that fails: unknown never deletes.
        $notHere = Get-VmfMachineAbsentReason -RunPath $RunPath -VmId $item.VmId
        if ($notHere) {
            Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome warn -VmId $item.VmId `
                -Detail "$by kept these disks, which a rollback or a restore made from the safety copies of this machine: $(@($item.Disks | ForEach-Object { "'$($_.diskName)'" }) -join ', '). $notHere The cleanup does not delete a disk of a machine that Azure does not show."
            continue
        }
        $result = Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $RunPath -VmId $item.VmId -Disks @($item.Disks) -Step 'retention'
        if (@($result.Deleted).Count) {
            Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome ok -VmId $item.VmId `
                -Detail "$by deleted these disks, which a rollback or a restore made from the safety copies of this machine and nothing used: $(@($result.Deleted | ForEach-Object { "'$_'" }) -join ', ')."
            $madeDeleted.Add([pscustomobject]@{ VmId = $item.VmId; Disks = @($result.Deleted) })
        }
        if (@($result.Failed).Count) {
            Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome warn -VmId $item.VmId `
                -Detail "$by did not delete these disks, which a rollback or a restore made from the safety copies of this machine: $(@($result.Failed | ForEach-Object { "'$($_.name)' ($($_.why))" }) -join ', ')."
        }
        if (@($result.InUse).Count) {
            Write-VmfStepLine -RunPath $RunPath -Step 'retention' -Outcome info -VmId $item.VmId `
                -Detail "These disks made from the safety copies are attached to a machine, so the product keeps them: $(@($result.InUse | ForEach-Object { "'$($_.name)' on '$($_.managedBy)'" }) -join ', ')."
        }
    }

    [pscustomobject]@{
        Considered = $entries.Count
        # REACH-1: what WOULD go. Under -WhatIf nothing is deleted, so without
        # this a preview returns an empty result that reads exactly like
        # "nothing to do" - and the scheduler needs to tell those apart.
        Eligible   = @($found.Eligible)
        Deleted    = @($deleted)
        # RETENTION-LOCK-PUTBACK-1: each machine with a copy that was not deleted, with Azure's reason and whether its lock is back.
        NotDeleted = @($notDeleted)
        Skipped    = @($found.Skipped)
        # ROLLBACK-DISKS-FIRST-1: what would go and what went, of the disks
        # made for the rollback. The scheduler starts a cleanup for either.
        RollbackDisksBeforeMove        = @($disksDue)
        RollbackDisksBeforeMoveDeleted = @($disksDeleted)
        # MADE-DISK-RECORD-1: the same, for the disks a rollback, a restore or
        # a rebuild made from a copy. The scheduler starts a cleanup for them.
        MadeDisks           = @($madeDue)
        MadeDisksDeleted    = @($madeDeleted)
        DeletedBy  = $who
    }
}
