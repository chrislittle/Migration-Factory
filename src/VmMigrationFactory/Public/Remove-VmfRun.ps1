function Remove-VmfRun {
    <#
    .SYNOPSIS
        RUN-LIFECYCLE-1: throw away a migration run - its plan, its records and
        its claims on machines.
    .DESCRIPTION
        A ruling shaped this: a run must be discardable, because
        redoing a migration after a bad attempt is the normal case and a run
        that cannot be thrown away holds its machines for ever.

        What it refuses: a run with a machine part-way through a move. That
        record is what knows how to roll the machine back, and deleting it is
        how a machine gets lost.

        What it insists you decide: safety copies. The run document is the only
        thing that knows those snapshots exist, so deleting it silently would
        leave them billing for ever with nothing to say what they were for.
        Choose -DeleteSafetyCopies or -KeepSafetyCopies deliberately.

        DELETE-CHANGED-FREED-1 (ruling 2026-11-06): a machine whose
        record says it is left changed (Test-VmfMachineLeftChanged) keeps its
        safety copies, also with -DeleteSafetyCopies - they are the only way
        to put it back. The deletion record names the machine and its copies.

        It does NOT touch machines in Azure. It deletes records, and releases
        the machines so another migration can take them on.

        -DeleteSafetyCopies DOES call Azure (DISCARD-ENGINE-1): from the app
        it runs as the engine's 'discard' operation, because the service holds
        neither the module nor the right. Each copy is confirmed gone before
        any record is removed; a copy that is not keeps every record.
    .EXAMPLE
        Remove-VmfRun -RunPath $run -Reason 'first attempt abandoned' -DeleteSafetyCopies
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][switch]$DeleteSafetyCopies,
        [Parameter()][switch]$KeepSafetyCopies,
        [Parameter()][string]$RemovedBy
    )

    # STORE-RESERVED-NAMES-1: one run, never more. A "run" at vmf-records (a
    # run started under that name) is every kept migration record; a "run" at
    # a project's root (a run started under the project's id) is the whole
    # project, machines in the middle of a move included. Asked before the
    # migration record, a machine claim or a safety copy is touched, and the
    # bulk delete asks again of every document (Remove-VmfStorePrefix -Kind run).
    Assert-VmfRunPrefixDeletable -RunPath $RunPath

    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    if (-not $manifest) { throw "There is no run at '$RunPath'." }
    $runId = [string]$manifest.runId

    # ASSESS-LINK-1: here, where the API path cannot route around it. What goes
    # with an assessment is its signed review - the stated authority for every
    # migration planned from it.
    Assert-VmfAssessmentUnused -RunPath $RunPath -Manifest $manifest

    $plan = Read-VmfPlanDocument -RunPath $RunPath -Depth 24
    $stateDocs = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$_" -Depth 24 })

    $verdict = Test-VmfRunDiscardable -Plan $plan -StateDocs $stateDocs
    if (-not $verdict.Ok) { throw $verdict.Detail }

    # RUN-DELETE-RESERVE-1: the store prefix goes with the run, capacity claims
    # included, and a claim that bills is the only record of a reservation in
    # Azure. Asked before anything - the migration record included - is written.
    Assert-VmfNoBillingReservation -RunPath $RunPath

    $snaps = @($verdict.OrphanSnapshots)
    # ROLLBACK-DISKS-FIRST-1: the rollback disks that nothing
    # used are decided with the copies they were made from.
    $rollbackDisksBeforeMove = @($verdict.RollbackDisksBeforeMove)
    # MADE-DISK-RUN-DELETE-1: and the disks a rollback, a restore or a
    # rebuild made from them that nothing uses - the same choice.
    $madeDisks = @($verdict.MadeDisks)
    # DELETE-CHANGED-FREED-1: the machines left changed. Their copies are never
    # in $snaps - the delete always keeps them - and the deletion record names
    # them, because the record of this migration is what goes.
    $changed = @($verdict.ChangedMachines | Where-Object { $_ })
    $changedKept = @($changed | ForEach-Object { @($_.SnapshotIds) } | Where-Object { $_ }).Count
    $keptCount = $changedKept + $(if ($KeepSafetyCopies) { $snaps.Count } else { 0 })
    if (($snaps.Count -gt 0 -or $rollbackDisksBeforeMove.Count -gt 0 -or $madeDisks.Count -gt 0) -and -not ($DeleteSafetyCopies -or $KeepSafetyCopies)) {
        throw ($verdict.Detail + " Re-run with -DeleteSafetyCopies to remove them as well, or -KeepSafetyCopies if you intend to keep them and know where they are.")
    }

    $who = if ($RemovedBy) { $RemovedBy } else {
        try { (Get-VmfSignedInIdentity).Identity } catch { 'unknown' }
    }

    if (-not $PSCmdlet.ShouldProcess("run '$runId'", "Delete this run's records and release its machines")) {
        return [pscustomobject]@{ RunId = $runId; Removed = $false; Detail = 'not confirmed' }
    }


    # Safety copies first: if this fails, the run record still exists and still
    # knows what they were - the opposite order strands them.
    #
    # DISCARD-ENGINE-1 (GitHub issue 427): this needs Az.Resources and the
    # right to delete a customer's snapshots, so it runs in the ENGINE's
    # 'discard' operation, never in the service. Every copy is tried and
    # confirmed gone; one that is not keeps the records whole, so the person
    # can try again, and a second try skips the copies already gone.
    $deletedSnaps = 0
    $alreadyGone = 0
    # Every copy id the run knew at the start, the ones a cleanup already
    # recorded as gone included - what the second check below compares with.
    $idsAtStart = @(foreach ($d in $stateDocs) { Get-VmfSafetyCopyIds -StateDoc $d })
    if ($snaps.Count -gt 0 -and $DeleteSafetyCopies) {
        # S5: whose copy each one is, for the lock note if a lock goes back.
        $owners = @{}
        foreach ($d in $stateDocs) { foreach ($id in @(Get-VmfSafetyCopyIds -StateDoc $d)) { $owners[$id] = ([string]$d.vmId -split '/')[-1] } }
        $copies = Remove-VmfRunSafetyCopies -RunPath $RunPath -SnapshotIds $snaps -Owners $owners -RunId $runId
        $deletedSnaps = @($copies.Deleted).Count
        $alreadyGone = @($copies.AlreadyGone).Count
        # Review 2 item 4: a machine whose copies are ALL gone is recorded the
        # way the daily cleanup records it, so a delete that stops part way
        # does not leave the copies card and Restore pointing at copies that
        # no longer exist. Never for a machine with a copy left: the record
        # means every copy is gone, and the next delete must still find that
        # one. And only while the document still names the same copies.
        $gone = @(@($copies.Deleted) + @($copies.AlreadyGone))
        foreach ($d in $stateDocs) {
            $ids = @(Get-VmfSafetyCopyIds -StateDoc $d)
            if (-not $ids.Count -or ($d.PSObject.Properties['retention'] -and $d.retention -and $d.retention.deletedUtc)) { continue }
            if (@($ids | Where-Object { $_ -notin $gone }).Count -gt 0) { continue }
            $current = @(Get-VmfSafetyCopyIds -StateDoc (Read-VmfStateDoc -RunPath $RunPath -VmId ([string]$d.vmId)))
            if (-not $current.Count -or (Compare-Object -ReferenceObject $ids -DifferenceObject $current)) { continue }
            Set-VmfSafetyCopiesDeleted -RunPath $RunPath -VmId ([string]$d.vmId) -SnapshotIds $ids -KeepDays $null -DeletedBy $who
        }
        if (@($copies.Failed).Count -gt 0) {
            $names = @($copies.Failed | ForEach-Object { $_.Name }) -join ', '
            throw ("$(@($copies.Failed).Count) of $($snaps.Count) safety copies were not deleted: $names. " +
                   'The migration is kept, so nothing is lost track of. The run history gives the reason for each copy. ' +
                   'Correct the cause, then delete the migration again: the copies already deleted are skipped.')
        }
    }
    # ROLLBACK-DISKS-FIRST-1: and the rollback disks that nothing
    # used, by their ids - each read first, none attached. One not deleted
    # keeps every record, as a copy does.
    # MADE-DISK-RUN-DELETE-1: and the disks a rollback or a restore
    # made from a copy that nothing uses, through the same delete - each read
    # by its resource id first, never one that is attached, and a read that
    # fails deletes nothing. Every disk is tried; one not deleted keeps every
    # record, because the record is the only thing that names it.
    if ($DeleteSafetyCopies -and ($rollbackDisksBeforeMove.Count -gt 0 -or $madeDisks.Count -gt 0)) {
        $stops = [System.Collections.Generic.List[string]]::new()
        foreach ($kind in @(
                @{ Disks = $rollbackDisksBeforeMove; What = 'rollback disks'; One = 'the rollback disk ''{0}''' }
                @{ Disks = $madeDisks; What = 'disks that a rollback or a restore made from the copies'; One = 'the disk ''{0}'' that a rollback or a restore made from a copy' })) {
            if (-not @($kind.Disks).Count) { continue }
            $notGone = [System.Collections.Generic.List[string]]::new()
            foreach ($group in @(@($kind.Disks) | Group-Object VmId)) {
                $result = Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $RunPath -VmId ([string]$group.Name) -Disks @($group.Group) -Step 'discard'
                foreach ($f in @($result.Failed)) {
                    $notGone.Add("'$($f.name)' ($($f.why))")
                    # STEP-LOG-4: written after Azure deleted disks and copies. A line
                    # that cannot be written never stops the list of what was not
                    # deleted, or replaces the stop below. The same for the two
                    # refusals after it, and the stop line in the catch.
                    Write-VmfStepLine -RunPath $RunPath -Step 'discard' -Outcome fail -VmId ([string]$group.Name) `
                        -Detail "The product did not delete $($kind.One -f $f.name): $($f.why)."
                }
            }
            if ($notGone.Count) { $stops.Add("$($notGone.Count) of $(@($kind.Disks).Count) $($kind.What) were not deleted: $($notGone -join ', ').") }
        }
        if ($stops.Count) {
            throw (($stops -join ' ') + ' ' +
                   'The migration is kept, so nothing is lost track of. Correct the cause, then delete the migration again: the disks already deleted are skipped.')
        }
    }

    # DISCARD-ENGINE-1 S2: ask again. The copies took minutes to delete, and in
    # that time a retry may have taken NEW copies this run never saw, or a
    # machine may have started to move. Removing the records now would lose
    # the only thing that knows how to put that machine back, and leave its
    # new copies locked and billing with nothing pointing at them.
    $planNow = Read-VmfPlanDocument -RunPath $RunPath -Depth 24
    $docsNow = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$_" -Depth 24 })
    $verdictNow = Test-VmfRunDiscardable -Plan $planNow -StateDocs $docsNow
    # Every copy id now, read from the documents themselves - a machine the
    # delete recorded as gone still counts if a retry gave it new copies.
    $newCopies = @(@(foreach ($d in $docsNow) { Get-VmfSafetyCopyIds -StateDoc $d }) | Where-Object { $_ -and $_ -notin $idsAtStart })
    # Review 2 item 2: and a reservation that bills, asked HERE as well as just
    # before the prefix goes - before the record, the claim release and the
    # deletions line, so a reserve job started during the delete changes none
    # of them.
    $billing = $null
    try { Assert-VmfNoBillingReservation -RunPath $RunPath } catch { $billing = $_.Exception.Message }
    if ($billing) {
        Write-VmfStepLine -RunPath $RunPath -Step 'discard' -Outcome fail `
            -Detail "The migration was not deleted, because an on-demand capacity reservation was made while its safety copies were deleted. $billing"
        throw $billing
    }
    if (-not $verdictNow.Ok -or $newCopies.Count -gt 0) {
        $what = if (-not $verdictNow.Ok) { $verdictNow.Detail }
                else { "New safety copies were taken while the delete ran: $(@($newCopies | ForEach-Object { ($_ -split '/')[-1] }) -join ', ')." }
        Write-VmfStepLine -RunPath $RunPath -Step 'discard' -Outcome fail `
            -Detail "The migration was not deleted, because it changed while its safety copies were deleted. $what"
        throw "The migration changed while its safety copies were deleted, so its records are kept. $what"
    }

    # ATTEST-1: the record of the change outlives the change. Written BEFORE
    # any record is removed, and a delete that cannot write it does not
    # delete: engineering and change management keep this record for 90 days,
    # and a delete that lost it would lose the only account of what was done.
    # N2: and only AFTER every copy is gone, so a record that says 'deleted'
    # is never written for a migration whose delete then stopped.
    # An assessment changed nothing, so it has no record to keep.
    # RECORD-DELETE-1 review 2: which record THIS attempt kept, if any - the stop
    # line below names it, so it can end only this record, never one an earlier
    # attempt kept.
    $keptRecordUtc = $null
    if ((Get-VmfRunKind -Manifest $manifest) -ne 'assessment' -and $plan) {
        try { $keptRecordUtc = [string](New-VmfMigrationRecord -RunPath $RunPath -Reason 'deleted' -GeneratedBy $who).generatedUtc }
        catch {
            $kept = if ($deletedSnaps -gt 0) { "so its records were not deleted ($deletedSnaps safety copies already were)" } else { 'so nothing was deleted' }
            throw "The record of this migration could not be kept, ${kept}: $($_.Exception.Message)"
        }
    }

    # RECORD-DELETE-1 review 1: from here the kept record says 'deleted' while
    # the migration is still whole, so a stop before the run is removed says
    # so in the run history. Without that line a download, which refuses a
    # migration whose delete has begun, would be refused for as long as the
    # migration stays. Remove-VmfStorePrefix is NOT inside: a removal that
    # stopped part way leaves a half-removed run, which a download must keep
    # refusing. And only when THIS attempt kept a record: an attempt that kept
    # none (no plan) has nothing to end, and its line must not end the record
    # an earlier attempt kept over a run that attempt half removed.
    try {
        # Release the machines BEFORE the records go: after the prefix is deleted
        # there is nothing left to say which run held what.
        $released = 0
        foreach ($e in @($plan.entries)) {
            if (-not $e.vmId) { continue }
            if ((Remove-VmfVmClaim -RunPath $RunPath -VmId ([string]$e.vmId) -RunId $runId).Released) { $released++ }
        }

        # The reason for a deletion cannot live inside the thing being deleted.
        # Asking somebody why, writing it into the run log, and then deleting the
        # run log is a question with nowhere to put the answer - so it goes beside
        # the runs, where the machine claims live, and outlives this.
        $auditScope = Get-VmfClaimScopePath -RunPath $RunPath
        try {
            Add-VmfStoreLine -RunPath $auditScope -RelPath 'deletions.jsonl' -Line (
                [ordered]@{
                    tsUtc = (Get-Date).ToUniversalTime().ToString('o')
                    runId = $runId; removedBy = $who; reason = $Reason
                    machinesReleased = $released; safetyCopiesDeleted = $deletedSnaps
                    safetyCopiesAlreadyGone = $alreadyGone
                    safetyCopiesKept = $keptCount
                    machinesLeftChanged = @($changed | ForEach-Object { [ordered]@{ vmId = $_.VmId; safetyCopies = @($_.SnapshotIds) } })
                } | ConvertTo-Json -Compress -Depth 6)
        }
        catch { Write-Warning "The deletion record could not be written: $($_.Exception.Message)" }

        # And once more, immediately before the records go: a reserve job started
        # while this was writing the record and releasing machines (minutes, on a
        # large run) may have made a claim that bills since the first question.
        Assert-VmfNoBillingReservation -RunPath $RunPath
    }
    catch {
        $stopped = $_
        if ($keptRecordUtc) {
            Write-VmfStepLine -RunPath $RunPath -Step 'discard' -Outcome fail -Data @{ keptRecordUtc = $keptRecordUtc } `
                -Detail "The migration was not deleted, because the delete stopped after it kept the record of the migration. $($stopped.Exception.Message)"
        }
        throw $stopped
    }
    $docs = Remove-VmfStorePrefix -RunPath $RunPath -Kind run -Confirm:$false

    [pscustomobject]@{
        RunId = $runId
        Removed = $true
        DocumentsDeleted = $docs
        MachinesReleased = $released
        SafetyCopiesDeleted = $deletedSnaps
        SafetyCopiesAlreadyGone = $alreadyGone
        SafetyCopiesKept = $keptCount
        ChangedMachinesKept = @($changed | ForEach-Object { $_.Name })
        RemovedBy = $who
        Reason = $Reason
    }
}
