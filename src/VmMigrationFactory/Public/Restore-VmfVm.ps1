function Restore-VmfVm {
    <#
    .SYNOPSIS
        RESTORE-1: put a machine's disks back to a safety copy taken during
        its migration - the OS disk and, since RESTORE-ALL-1, every data disk. The disaster path, for when reverting configuration is
        not enough because the disk content itself is wrong.
    .DESCRIPTION
        Every migration takes a snapshot at SAFETY_COPY and records its id.
        This is the command that claims it: build a disk from that snapshot,
        swap it into the machine, and bring the machine back up.

        SCOPE, deliberately narrow: this restores DISK CONTENT ONLY. It never
        changes the machine's size or controller for a PREPARED copy - that is
        what the rollback path does. A PRISTINE copy is different: it predates
        guest prep, so it can only boot on the original hardware, and restoring
        it reverts size and controller too. Reverting those is otherwise what the
        automated rollback does, and quietly doing both would surprise an
        operator who asked for one. Run the rollback as well if the machine
        also needs its original size back.

        THE DISK IDENTITY PROBLEM (the reason -DiskNaming exists): a disk built
        from a snapshot is a NEW Azure resource with a NEW id. Anything bound
        to the old id - Terraform state, backup instances, resource locks,
        disk-scoped role assignments - sees that as drift or breakage. Managed
        disks cannot be renamed, and two disks cannot share a name, so there
        are exactly two honest options:

          new       ALWAYS THE DEFAULT. The restored disk gets a new name;
                    the current disk is KEPT, detached, and nothing is
                    destroyed. Nothing in the product puts it back: from the
                    first copy that would change the size and the disk
                    controller again (RESTORE-DIALOG-WORDS-1). The machine
                    panel lists each kept disk from the record. The id change
                    is reported in the machine record and run history, never
                    silent.
          preserve  OPT-IN, AND DESTRUCTIVE. The restored disk ends up with the
                    ORIGINAL name and resource id, so anything that refers to
                    the disk by name or id still finds it - but its tags, role
                    assignments and backup are not copied, and getting there
                    DELETES the current disk to free its name. Once that delete
                    succeeds, the data written after the snapshot is gone. The
                    safety copies are then the only copies, and the daily
                    cleanup deletes them when the retention of the wave ends.

        The default is never inferred. An earlier draft auto-selected
        'preserve' for machines that looked IaC-managed, but that fact is a
        TAG HEURISTIC (a managed-by/provisioner tag valued terraform/tf/
        opentofu) that the product never asks anyone to confirm - far too weak a
        signal to pick a destructive path on someone's behalf. Choosing
        'preserve' is a human decision, made explicitly, every time.
    .PARAMETER DiskNaming
        new (default, non-destructive) or preserve (destructive - deletes each
        current disk that the restore swaps, OS and data; requires
        -AcceptPreserveRisk).
        One choice covers every disk (RESTORE-ALL-1).
    .PARAMETER Resume
        RESTORE-END-JOB-1: start again the restore whose operation id is
        -CorrelationId, from the last step it saved (putBackJob on the
        machine's record). Everything the person asked for - the copy, the
        naming, who and why - is read from that record, never from this
        call. The service's timer starts it when the job of the restore
        stopped part way.
    .EXAMPLE
        Restore-VmfVm -RunPath .\run1 -VmId $vmId -RestoredBy 'lead@contoso.com' -Note 'did not boot after conversion'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][ValidateSet('new', 'preserve')][string]$DiskNaming = 'new',
        # 'preserve' deletes the pre-migration disk. That has to be said out
        # loud by the caller, not buried in a default.
        [Parameter()][switch]$AcceptPreserveRisk,
        [Parameter()][string]$SnapshotId,
        # SAFETY-2: which copy to go back to. 'prepared' is the clean snapshot
        # taken just before conversion - the right resume point for a failed
        # convert. 'pristine' is the copy taken BEFORE guest prep rewrote the
        # boot path, and is the only one that is genuinely "as it was"; it
        # exists only when the ring policy asked for it.
        [Parameter()][ValidateSet('prepared', 'pristine')][string]$From = 'prepared',
        [Parameter()][string]$RestoredBy = 'unknown',
        [Parameter()][AllowEmptyString()][string]$Note = '',
        # RESTORE-END-LOST-1: the engine operation's id, on the start line. The
        # engine's own fail line carries the same id, so the Migrations page
        # ends THIS restore on it and not another restore of the machine.
        [Parameter()][string]$CorrelationId,
        # REBUILD-REMOVE-RECOVER-1: no -AcceptIdentityLoss. No restore
        # rebuilds a machine, so none deletes a system-assigned identity.
        [Parameter()][switch]$Resume
    )

    # VMID-CASE-1: the ID as this run's record spells it, whatever case it came in.
    $VmId = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { throw "No record of '$VmId' in this run." }
    # RESTORE-END-JOB-1: a resume is the SAME restore - what the person asked
    # for comes from its checkpoint, never from the call that started it
    # again. Anything else is refused while a restore of this
    # machine has not ended: it resumes by itself, and a second job would
    # start from a machine that is part way.
    $jobToken = $null
    $resumedFrom = ''
    if ($Resume) {
        $jobToken = Get-VmfPutBackJobToken -RunPath $RunPath -VmId $VmId -Kind 'restore' -OperationId $CorrelationId
        $resumedFrom = [string]$jobToken.Job.phase
        $opts = $jobToken.Job.options
        $From = [string]$opts.from
        $DiskNaming = [string]$opts.diskNaming
        $AcceptPreserveRisk = [switch][bool]$opts.acceptPreserveRisk
        $SnapshotId = [string]$opts.snapshotId
        $RestoredBy = [string]$jobToken.Job.startedBy
        $Note = [string]$jobToken.Job.note
    }
    else {
        $jobRefusal = Get-VmfPutBackJobRefusal -Doc $doc -VmName (($VmId -split '/')[-1])
        if ($jobRefusal) { throw $jobRefusal }
        # RESTORE-MID-MOVE-1 (2026-10-19): a machine whose move
        # has not ended belongs to its wave, also when the wave's worker died.
        # Refused here, before the hold and before anything is read from
        # Azure. A resume above is not asked: it finishes what it started.
        $midMove = Get-VmfPutBackMidMoveRefusal -Doc $doc -VmName (($VmId -split '/')[-1]) -Kind 'restore'
        if ($midMove) { throw $midMove }
    }
    # Has the job ended this step (now, or before it was started again)? And
    # had it, when this resume started? Every step below asks one of them.
    $stepDone = { param($p) $null -ne $jobToken -and (Test-VmfPutBackJobPast -Job $jobToken.Job -Phase $p) }
    $wasDone = { param($p) [bool]$resumedFrom -and (Test-VmfPutBackJobPast -Job ([pscustomobject]@{ kind = 'restore'; phase = $resumedFrom }) -Phase $p) }
    $resumePastMade = & $wasDone 'made'
    # SWAP-REFUSED-AFTER-STOP-1: a machine a refused data-disk swap left
    # stopped is finished first - by the action that swaps only the disks that
    # are left. A restore over it would make new disks for every LUN again.
    # RESTORE-END-JOB-1: a resume is not "over it" - the swap it left is its
    # own, and it goes on to write its record.
    if (-not $Resume) {
        $swapRefusal = Get-VmfSwapPendingRefusal -Doc $doc -VmName (($VmId -split '/')[-1])
        if ($swapRefusal) { throw $swapRefusal }
    }

    $snapshot = if ($SnapshotId) { $SnapshotId }
                elseif ($From -eq 'pristine') { [string]$doc.safety.pristineSnapshotId }
                else { [string]$doc.safety.snapshotId }
    if (-not $snapshot -and $From -eq 'pristine') {
        # A guard: every move takes the first safety copy before it changes
        # the machine, and the page offers only the copies the record holds.
        throw "The record of '$(($VmId -split '/')[-1])' holds no first safety copy, so the restore cannot use it."
    }
    # WAVE-2 lever 7: copies deleted under the wave's retention are GONE on
    # purpose. Saying so is the difference between an answer and a mystery -
    # without this the caller gets "snapshot not found" from Azure and has no
    # idea whether it was ever taken.
    if (-not $resumePastMade -and $doc.PSObject.Properties['retention'] -and $doc.retention -and $doc.retention.deletedUtc) {
        # DISCARD-ENGINE-1: a delete of the migration writes the same record
        # with no retention days - no retention deleted them, so none is named.
        $why = if ($null -ne $doc.retention.keepDays) { ", because this machine had been migrated longer than the $($doc.retention.keepDays) days its wave was set to keep them" } else { ', when the migration was deleted with its safety copies' }
        throw "The safety copies for '$(($VmId -split '/')[-1])' were deleted on $($doc.retention.deletedUtc) by $($doc.retention.deletedBy)$why. There is nothing left to restore from."
    }
    if (-not $snapshot) {
        throw "No safety copy is on record for '$(($VmId -split '/')[-1])', so there is nothing to restore from."
    }

    # SEC-1 / F10. Every action in the product addresses the resource ID,
    # which is Azure's unique string for a resource, to get it right.
    #
    # Everything below addresses the machine by resource group and name - a
    # pair that is unique only INSIDE one subscription. The engine container
    # signs in with `Connect-AzAccount -Identity` naming no subscription, so
    # without this the deallocate, the disk swap and the disk delete would land
    # on whichever same-named machine the ambient context resolved.
    # ENGINE-SUB-1 recorded exactly that, reproduced against two real
    # subscriptions, and then fixed it for the wave path alone; this is the
    # same rule on the path an operator drives.
    #
    # A process-wide switch is safe here, and only here, for the reason the
    # helper documents: the engine runs ONE operation per container and exits.
    # The service serves several requests on one worker, and never calls this -
    # the two commands it does call address snapshots by their resource id and
    # need no context at all.
    #
    # The body below is deliberately NOT re-indented into this try. Adding a
    # level to two hundred lines would bury the one real change in a whole-file
    # diff, and several tests read this source by shape.
    $subscriptionId = Assert-VmfResourceId -ResourceId $VmId -Kind 'virtual machine'
    $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $subscriptionId
    $machineLease = $null
    # RESTORE-ORIGINAL-DELETE-RESTART-1: the words a restore that did not happen ends
    # with, kept on its checkpoint as it is marked ended (ended.why).
    $endWhy = ''
    try {
    # RESTORE-ONE-AT-A-TIME-1: one restore of a machine at a time,
    # and none while a wave worker holds it. Taken before anything is read from
    # Azure and before the start line, so a second restore is refused with the
    # machine untouched and never opens a restore on the page. Released in the
    # finally below; a resume of THIS restore (the same operation id) takes it
    # over (MachineLease.ps1).
    $machineLease = Enter-VmfMachineLease -RunPath $RunPath -VmId $VmId -Holder (Get-VmfMachineLeaseHolder -Kind 'restore' -CorrelationId $CorrelationId)

    $rg = ($VmId -split '/')[4]
    $vmName = ($VmId -split '/')[-1]

    $naming = $DiskNaming
    if ($naming -eq 'preserve' -and -not $AcceptPreserveRisk) {
        # A guard: the page sends the acceptance with this choice, and the
        # service refuses the choice without it.
        throw "Keeping the original disk names deletes each current disk of '$vmName' that the restore swaps. The delete was not accepted, so the restore did not start."
    }

    # RESTORE-END-JOB-1: a resume reads the machine as it was BEFORE the job
    # changed it, from the checkpoint - after the swap, the machine's OS disk
    # is the restored one, and a restore of it would restore the restore. The
    # time in every disk name is the first job's, so every disk it asks Azure
    # for is the disk the first job made (New-VmfDiskFromSnapshot).
    if ($Resume) {
        $beforeRec = $jobToken.Job.before
        $current = $beforeRec.osDisk
        $liveData = @(@($beforeRec.dataDisks) | Where-Object { $_ })
        $stamp = [string]$jobToken.Job.stamp
    }
    else {
    $current = Invoke-VmfAzOperation -Name 'osDiskInfo' -RunPath $RunPath -VmId $VmId -Operation {
        Get-VmfOsDiskInfo -ResourceGroupName $rg -Name $vmName
    }
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm')

    # RESTORE-ALL-1: every data disk comes back too, from the copy of the same
    # kind, under the same naming choice. Only from a RECORDED copy: a copy a
    # caller names by ID is an OS disk copy, and its data disks' moment is
    # unknown - putting them back from another would mix two moments again.
    $liveData = @(Invoke-VmfAzOperation -Name 'restore:dataDiskInfo' -RunPath $RunPath -VmId $VmId -Operation {
        @(Get-VmfDataDiskInfo -ResourceGroupName $rg -Name $vmName)
    })
    }
    $recordedCopy = if ($From -eq 'pristine') { [string]$doc.safety.pristineSnapshotId } else { [string]$doc.safety.snapshotId }
    # ROLLBACK-SIZE-REFUSED-SERIES-1 (2026-11-14): Azure refused
    # the original size in the rollback, and a person changed the series with
    # Change to v5 - so the first copy goes back onto the target size of the
    # plan (RestoreOntoTarget.ps1). Decided once, when the restore starts, and
    # kept in its checkpoint: a resume uses that size whatever the plan says
    # by then. A refusal changes nothing.
    $onto = $null
    if ($Resume) {
        $jobOpts = $jobToken.Job.options
        if ([string](Get-VmfRecordField -Object $jobOpts -Name 'ontoSize')) {
            $onto = @{ Size = [string]$jobOpts.ontoSize; Option = [string](Get-VmfRecordField -Object $jobOpts -Name 'ontoOption')
                       OriginalSize = [string](Get-VmfRecordField -Object $jobOpts -Name 'ontoOriginal'); Refusal = $null }
        }
    }
    elseif ($From -eq 'pristine' -and (Test-VmfStoreItem -RunPath $RunPath -RelPath 'plan.json')) {
        $ontoEntry = @(@((Read-VmfPlanDocument -RunPath $RunPath).entries) | Where-Object { [string]$_.vmId -eq $VmId }) | Select-Object -First 1
        $onto = Get-VmfRestoreOntoTarget -Doc $doc -PlanEntry $ontoEntry -From $From -RecordedCopy ($snapshot -eq $recordedCopy)
    }
    if ($onto -and $onto.Refusal) { throw $onto.Refusal }
    # RESTORE-END-JOB-1: past the step that made the disks, everything the
    # steps before the stop decided is in the checkpoint (made).
    $madeRec = if ($resumePastMade) { $jobToken.Job.made } else { $null }
    $dataPlan = if ($madeRec) {
        @{ Restore = @(@($madeRec.dataPlan.Restore) | Where-Object { $_ }); Kept = @(@($madeRec.dataPlan.Kept) | Where-Object { $_ }) }
    } elseif ($snapshot -eq $recordedCopy) {
        # SAFETY-ULTRA-1: whether Azure can make a disk from each Premium SSD
        # v2 and Ultra Disk copy - every copy on record, so keeping the names
        # never deletes a disk a copy still depends on. Read before the stop.
        $copyReadiness = Get-VmfInstantAccessCopyReadiness -Context ([pscustomobject]@{ RunPath = $RunPath; VmId = $VmId }) -Doc $doc -Kind 'all'
        Get-VmfOperatorDataRestorePlan -Doc $doc -Kind $From -Live $liveData -Stamp $stamp -Naming $naming -CopyReadiness $copyReadiness
    } else {
        @{ Restore = @(); Kept = @($liveData | ForEach-Object { [pscustomobject]@{ lun = [int]$_.lun; name = [string]$_.name; why = 'The restore uses a copy named by its ID, so the data disks stay as they are.' } }) }
    }
    # A shared disk is left, as the put-back leaves it - found now, so the lock
    # check and the words below name only the disks the restore replaces.
    # RESTORE-SHARE-READ-WORDS-1: the read comes before any disk is made or
    # the machine is stopped, so a refused read says so, and names the disk.
    # Thrown, never written as a step line: -WhatIf reads it too.
    $shared = @(if (-not $madeRec) { foreach ($row in @($dataPlan.Restore)) {
        try {
            $shares = Invoke-VmfAzOperation -Name 'restore:readDataDisk' -RunPath $RunPath -VmId $VmId -Operation { Get-VmfDiskShareCount -DiskId $row.currentId }
        }
        catch {
            throw "The restore stopped before it changed the machine: the product could not read whether the data disk '$($row.currentName)' on LUN $([int]$row.lun) is shared: $($_.Exception.Message) The machine is as it was before the restore."
        }
        if ([int]$shares -gt 1) { [pscustomobject]@{ lun = [int]$row.lun; name = [string]$row.currentName; why = "It is a shared disk (maxShares $shares), and other machines can use it." } }
    } })
    if ($shared.Count) {
        $dataPlan = @{ Restore = @($dataPlan.Restore | Where-Object { [int]$_.lun -notin @($shared | ForEach-Object lun) })
            Kept = @(@($dataPlan.Kept) + $shared | Sort-Object { [int]$_.lun }) }
    }
    # OLD-SKU-1C with RESTORE-ALL-1: the disks IN USE now go back to their
    # type before the original size. A rollback or an earlier restore may have
    # put new disks on the machine, which no move record names - a second copy
    # restore makes them on the moved type - so for a disk the RECORD says the
    # product made, the captured type is the one it goes back to.
    # ROLLBACK-RETRY-CAPTURE-1: "as it was" is the machine's FIRST capture -
    # its size, controller, accelerated networking and disk types - on this
    # attempt's disks. A retry after a rebuild as the target captured the
    # machine on the target size.
    # CRG-ROLLBACK-ATTEMPT-GROUP-1: the group of this attempt, unless it is a
    # group of this migration.
    $capturedVm = Get-VmfPutBackCapture -Doc $doc -ProductGroupIds @(Get-VmfProductReservationGroupIds -RunPath $RunPath)
    # ROLLBACK-SIZE-REFUSED-SERIES-1: the size the first copy goes back on.
    $backSize = if ($onto) { [string]$onto.Size } else { [string]$capturedVm.size }
    $inUse =@(@([string]$current.id) + @($liveData | Where-Object { $_.id } | ForEach-Object { [string]$_.id }))
    $typeBack = Get-VmfMadeDiskTypes -Doc $doc
    $deleting = @(@($current.name) + @($dataPlan.Restore | ForEach-Object { [string]$_.currentName }))

    # RETIRE-SCOPE-1 (reversing part of V3-RETIRE-1): the first copy goes back
    # on the size the machine had. From one day before Microsoft retires that
    # size, a return to it is outside the scope of this tool: refused below,
    # before the machine is stopped. Within the 12 months before, it goes on
    # and the log warns. The other copy keeps the size the machine has now.
    # RESTORE-END-JOB-1: a resume does not ask again - the check was passed
    # when the restore started, and a stop part way is never a reason to
    # leave a machine part way.
    $retireCheck = $null
    if ($From -eq 'pristine' -and -not $Resume) {
        $retireCheck = Get-VmfPutBackRetirementCheck -Size $backSize -VmName $vmName
    }
    if ($Resume) { $sizeNow = [string]$beforeRec.sizeNow }
    else {
        $sizeNow = Invoke-VmfAzOperation -Name 'restore:sizeBefore' -RunPath $RunPath -VmId $VmId -Operation {
            Get-VmfVmSize -ResourceGroupName $rg -Name $vmName
        }
    }

    # PREVIEW-PUTBACK-1: the first copy of a Preview move goes back on the
    # original size in place, across the temporary disk kinds again - which
    # Azure allows only with the preview feature registered. Read before
    # anything is made or stopped, and refused below, as the retirement is.
    # A resume does not ask again, for the reason the retirement gives.
    $previewCheck = $null
    # ROLLBACK-SIZE-REFUSED-SERIES-1: a restore onto the target size refuses a
    # Preview move above (Get-VmfRestoreOntoTarget), so it asks nothing here.
    if ($From -eq 'pristine' -and -not $Resume -and -not $onto) {
        $previewCheck = Get-VmfPreviewPutBackCheck -Kind 'restore' -Size ([string]$capturedVm.size) -SizeNow ([string]$sizeNow) `
            -Method (Get-VmfStartedMoveMethod -Doc $doc) `
            -Context ([pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; SubscriptionId = $subscriptionId; Rg = $rg; VmName = $vmName })
    }

    # ROLLBACK-DISKS-FIRST-1 (2026-10-11): from the first copy
    # of this attempt, the rollback disks before the move changed
    # anything (New-VmfRollbackDisksBeforeMove) - read now, before the stop, and only
    # swapped in. Asking Azure for no new disk is what makes a put-back that
    # cannot be refused. Anything else makes its disks below, as before: the
    # second copy, a copy named by its ID, no rollback disks on record for
    # this copy, disks already used or deleted, or one Azure no longer has.
    $preMade = $null
    $preWords = $null
    if ($madeRec) {
        $preMade = if ($madeRec.preMade) {
            @{ OsName = [string]$madeRec.preMade.OsName; OsId = [string]$madeRec.preMade.OsId; Ids = @(@($madeRec.preMade.Ids) | Where-Object { $_ })
               Data = @{ Swaps = @(@($madeRec.preMade.Data.Swaps) | Where-Object { $_ }); Kept = @(@($madeRec.preMade.Data.Kept) | Where-Object { $_ }) } }
        } else { $null }
    }
    elseif ($From -eq 'pristine' -and $snapshot -eq $recordedCopy) {
        $pick = Get-VmfRollbackDisksBeforeMoveSet -Context ([pscustomobject]@{ RunPath = $RunPath; VmId = $VmId }) -Doc $doc -Shape 'full' -FromSnapshotId $snapshot `
            -Luns @($dataPlan.Restore | ForEach-Object { [int]$_.lun })
        $preMade = $pick.Set
        $preWords = if ($preMade) { "The restore uses the disks that the product made from the safety copies before the move changed the machine: $(@(@($preMade.OsName) + @($preMade.Data.Swaps | ForEach-Object { $_.diskName }) | ForEach-Object { "'$_'" }) -join ', '). It asks Azure for no new disk before the stop." }
                    else { "The restore makes its disks from the first safety copy before it stops the machine. $($pick.Why)" }
        if ($preMade -and $naming -eq 'preserve') {
            # Keeping the names, the rollback disks are the
            # temporary disks: the machine runs on them while each name is
            # freed, and each goes once the disk under its name is on.
            foreach ($row in @($dataPlan.Restore)) {
                $mine = @($preMade.Data.Swaps) | Where-Object { [int]$_.lun -eq [int]$row.lun } | Select-Object -First 1
                $row | Add-Member -NotePropertyName tempName -NotePropertyValue ([string]$mine.diskName) -Force
            }
        }
    }

    # A delete-blocking lock is found BEFORE anything moves. Discovering it
    # halfway through 'preserve' would strand the machine on a temporary disk.
    # RESTORE-ALL-1: on every disk the restore would delete, not the OS disk alone.
    # CANNOTDELETE-RESTORE-1: and on every temporary disk it deletes, beside
    # the machine. A lock on the resource group of the machine refused those
    # deletes with the machine stopped, when the disks it replaces are in
    # another resource group. The default naming deletes no disk.
    if ($naming -eq 'preserve' -and -not $madeRec) {
        $lockTargets = @([pscustomobject]@{ rg = $current.resourceGroup; name = $current.name; temporary = $false }) +
            @($dataPlan.Restore | ForEach-Object { [pscustomobject]@{ rg = [string]$_.currentResourceGroup; name = [string]$_.currentName; temporary = $false } })
        $tempOsName = if ($preMade) { [string]$preMade.OsName } else { Get-VmfBoundedDiskName -BaseName $current.name -Suffix "-rtmp-$stamp" }
        $lockTargets += @([pscustomobject]@{ rg = $rg; name = $tempOsName; temporary = $true }) +
            @($dataPlan.Restore | Where-Object { [string]$_.tempName } | ForEach-Object { [pscustomobject]@{ rg = $rg; name = [string]$_.tempName; temporary = $true } })
        foreach ($target in $lockTargets) {
            $locks = Invoke-VmfAzOperation -Name 'restore:lockCheck' -RunPath $RunPath -VmId $VmId -Operation {
                Get-VmfDeleteBlockingLocks -ResourceGroupName $target.rg -DiskName $target.name
            }
            if (@($locks).Count -gt 0) {
                if ($target.temporary) {
                    throw "Restore cannot keep the original disk names. A resource lock ($($locks -join ', ')) on the resource group '$($target.rg)' prevents the delete of the temporary disk '$($target.name)'. Remove the lock, or restore again and select Yes for Keep its current managed disks."
                }
                throw "Restore cannot keep the original disk names. A resource lock ($($locks -join ', ')) prevents the delete of '$($target.name)'. Remove the lock, or restore again and select Yes for Keep its current managed disks."
            }
        }
        Write-Warning "Restoring '$vmName' with the original disk names will DELETE these disks: $(($deleting | ForEach-Object { "'$_'" }) -join ', '). The safety copies will then be the only copies, and the daily cleanup deletes them when the retention of the wave ends."
    }

    # RESTORE-PERM-CHECK-1: every permission Azure checks on a resource that
    # the writes of this restore link to - the network interfaces and the
    # user-assigned identities each update sends, the capacity reservation
    # group, and each safety copy and disk encryption set of a disk made from
    # a copy - with the checks of Checking (RestorePermissions.ps1). Asked
    # before any disk is made and before the stop, and refused below after
    # -WhatIf has returned, as the retirement is. Not asked when a check above
    # refuses already. A resume does not ask again: it finishes the restore
    # it started, and never leaves a machine part way.
    $permStop = $null
    if (-not $Resume -and -not ($retireCheck -and $retireCheck.Refuse) -and -not ($previewCheck -and $previewCheck.Refuse)) {
        # No disk is made from a copy when the restore uses the disks made
        # before the move under their own names (ROLLBACK-DISKS-FIRST-1).
        $copyIds = @()
        $copyDisks = @()
        if (-not ($preMade -and $naming -ne 'preserve')) {
            $copyIds = @(@($snapshot) + @($dataPlan.Restore | ForEach-Object { [string]$_.snapshotId }) | Where-Object { $_ })
            $copyDisks = @(@($capturedVm.osDisk) + @($dataPlan.Restore | ForEach-Object {
                        $enc = Get-VmfRecordField -Object $_ -Name 'encryption'
                        if ($enc) { [pscustomobject]@{ encryptionType = [string]$enc.type; diskEncryptionSetId = [string]$enc.diskEncryptionSetId } }
                    }) | Where-Object { $null -ne $_ })
        }
        $permStop = Get-VmfRestorePermissionStop -Context ([pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Rg = $rg; VmName = $vmName }) `
            -From $From -PutBackCapture $capturedVm -CopyIds $copyIds -CopyDisks $copyDisks
    }

    $finalName = if ($madeRec) { [string]$madeRec.finalName }
                 elseif ($naming -eq 'preserve') { $current.name }
                 else { Get-VmfBoundedDiskName -BaseName $current.name -Suffix "-restored-$stamp" }

    $dataWords = if (@($dataPlan.Restore).Count) { " and $(@($dataPlan.Restore).Count) data disk(s)" } else { '' }
    $action = if ($naming -eq 'preserve') {
        "restore the OS disk$dataWords from the safety copy $snapshot, DELETING the disks $(($deleting | ForEach-Object { "'$_'" }) -join ', ') to reuse their names"
    } else {
        "restore the OS disk$dataWords from the safety copy $snapshot as new disks (the current disks are kept)"
    }
    if ($retireCheck -and $retireCheck.Refuse) { $action += ", which is REFUSED: $($retireCheck.Detail)" }
    if ($previewCheck -and $previewCheck.Refuse) { $action += ", which is REFUSED: $($previewCheck.Detail)" }
    if ($permStop) { $action += ", which is REFUSED: $permStop" }
    if ($Resume) { $action = "start again the restore that stopped part way ($action), from its last step '$resumedFrom'" }
    if (-not $PSCmdlet.ShouldProcess($vmName, $action)) { return }
    # Said and refused after -WhatIf has returned, and before the machine is
    # stopped. Under their own step, which says itself on the run page.
    # STEP-LOG-2: these four lines - the retirement refusal and warning, the
    # start, and the line that says which disks the restore WILL use - are
    # written before the restore makes or changes anything, so a line that cannot be written stops the restore
    # with the machine as it was. Every line after them goes through
    # Write-VmfStepLine: a line that cannot be written must never start the
    # machine on a half-restored disk, nor report a restore that worked as
    # failed.
    if ($retireCheck -and $retireCheck.Refuse) {
        Write-VmfEvent -RunPath $RunPath -Step 'putBack' -Outcome fail -VmId $VmId -Detail $retireCheck.Detail
        throw $retireCheck.Detail
    }
    if ($retireCheck -and $retireCheck.Warn) {
        Write-VmfEvent -RunPath $RunPath -Step 'putBack' -Outcome warn -VmId $VmId -Detail $retireCheck.Detail
    }
    # PREVIEW-PUTBACK-1: refused before the restore job, the start line, any
    # disk made or the stop.
    if ($previewCheck -and $previewCheck.Refuse) {
        Write-VmfEvent -RunPath $RunPath -Step 'putBack' -Outcome fail -VmId $VmId -Detail $previewCheck.Detail
        throw $previewCheck.Detail
    }
    if ($previewCheck) { Write-VmfEvent -RunPath $RunPath -Step 'putBack' -Outcome info -VmId $VmId -Detail $previewCheck.Detail }
    # RESTORE-PERM-CHECK-1: refused as the preview check is - before the
    # restore job, the start line, any disk made or the stop.
    if ($permStop) {
        Write-VmfEvent -RunPath $RunPath -Step 'putBack' -Outcome fail -VmId $VmId -Detail $permStop
        throw $permStop
    }

    # POWER-AFTER-MOVE-1 (2026-11-06, POWER-FOUND-AGE-1): the restore
    # ends with the machine in the power state it had when the restore
    # started - read here, before anything changes, and kept in the
    # checkpoint. A resume uses the first reading: the machine it finds may be
    # one this restore started.
    $powerAtStart = $null
    if ($Resume) {
        $powerAtStart = [string](Get-VmfRecordField -Object $jobToken.Job -Name 'powerAtStart')
        # RESTORE-END-JOB-1: the same restore, started again. Not a start line:
        # the page keeps the restore open on its first one, and this line
        # keeps it current.
        Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome info -VmId $VmId `
            -Detail "The restore started again after its job stopped. It goes on from the last step it saved, with the disks it made."
    }
    else {
    # RESTORE-END-JOB-1 (rule 4): the checkpoint, before the start line and
    # before anything changes. If it cannot be written, the restore stops here.
    $powerAtStart = Get-VmfJobStartPower -RunPath $RunPath -VmId $VmId -Step 'restore' -JobWords 'the restore'
    $jobToken = New-VmfPutBackJob -RunPath $RunPath -VmId $VmId -Kind 'restore' -OperationId $(if ($CorrelationId) { $CorrelationId } else { [guid]::NewGuid().ToString() }) `
        -StartedBy $RestoredBy -Note $Note -Stamp $stamp -PowerAtStart $powerAtStart `
        -Options @{ from = $From; diskNaming = $naming; acceptPreserveRisk = [bool]$AcceptPreserveRisk; snapshotId = $(if ($SnapshotId) { $SnapshotId } else { $null })
            # ROLLBACK-SIZE-REFUSED-SERIES-1 (vm-state v51): the size this
            # restore puts the machine on, so a resume uses the same one.
            ontoSize = $(if ($onto) { [string]$onto.Size } else { $null }); ontoOption = $(if ($onto) { [string]$onto.Option } else { $null })
            ontoOriginal = $(if ($onto) { [string]$onto.OriginalSize } else { $null }) } `
        -Before ([pscustomobject][ordered]@{ osDisk = $current; dataDisks = @($liveData); sizeNow = [string]$sizeNow })
    Write-VmfEvent -RunPath $RunPath -Step 'restore' -Outcome start -VmId $VmId -CorrelationId $CorrelationId `
        -Detail "restoring from safety copy (naming=$naming) by $RestoredBy"
    if ($preWords) { Write-VmfEvent -RunPath $RunPath -Step 'restore' -Outcome info -VmId $VmId -Detail $preWords }
    }
    # MADE-DISK-RECORD-1 (rule 4): the disks an earlier restore made from the
    # copies and did not finish with are on the record from the moment Azure
    # made them. They bill, so each restore names them.
    # RESTORE-END-JOB-1: a resume's own disks are not an earlier restore's.
    $earlierMade = @(if (-not $Resume) { Get-VmfUnusedMadeDisks -Doc $doc -List 'restoreDisks' })
    if ($earlierMade.Count) {
        Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome info -VmId $VmId `
            -Detail "An earlier restore made these disks from the safety copy, and the machine does not run on them: $(@($earlierMade | ForEach-Object { "'$($_.diskName)'" }) -join ', '). Each one costs money until it is deleted. The daily cleanup deletes them when the move of this machine has ended."
    }

    $controllerNow = [string]$current.controller
    # ZONES-1: a zonal machine takes only a disk made in its zone.
    $zone = Get-VmfMachineZone -Machine $capturedVm
    # ID-ADDRESS-1: a restore that keeps the name makes the new disk where the
    # old one was - its own resource group, read from its ID - so the name
    # means the same disk it did. A new name goes beside the machine.
    $finalRg = if ($naming -eq 'preserve') { $current.resourceGroup } else { $rg }
    # OLD-SKU-1C: the pristine copy goes back on the type the capture
    # recorded; the prepared copy keeps the machine's new setup, and its type.
    $newSku = [string]$current.skuName
    if ($From -eq 'pristine' -and $capturedVm.osDisk -and [string]$capturedVm.osDisk.skuName) {
        $newSku = [string]$capturedVm.osDisk.skuName
    }
    # ROLLBACK-ORDER-1: a disk that will go into a machine that stays on NVMe
    # is given NVMe first - the prepared copy, which keeps the new size by
    # design. It is the same change the conversion made to the original disk.
    # ROLLBACK-DISKS-FIRST-1: asked of the controller the machine has WHEN the
    # disk goes in - the captured one for the first copy, which sets the
    # hardware back first - because the disk is now made before the stop.
    $controllerAtSwap = if ($From -eq 'pristine' -and [string]$capturedVm.size) { [string]$capturedVm.controller } else { $controllerNow }
    $allowController = {
        param([string]$DiskName, [string]$DiskResourceGroup = $rg)
        if ($controllerAtSwap -eq 'NVMe') {
            Invoke-VmfAzOperation -Name 'restore:allowNvme' -RunPath $RunPath -VmId $VmId -Operation {
                Set-VmfOsDiskControllerTypes -DiskResourceGroup $DiskResourceGroup -DiskName $DiskName -ControllerTypes 'SCSI, NVMe'
            } | Out-Null
        }
    }
    $restoreContext = [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Rg = $rg }

    # ROLLBACK-DISKS-FIRST-1: every disk from its copy BEFORE the stop. Making
    # a disk needs no stopped machine, so an OS disk Azure refuses, or one on
    # another key or that cannot be read back (SAFETY-CMK-1), stops the
    # restore with the machine as it was - never stopped on its old size with
    # the disk it had. Keeping the names, the temporary disks are made here;
    # each final disk can only be made once the disk whose name it takes is
    # deleted. A data disk not made keeps its disk, as before.
    $tempName = $null
    $tempId = $null
    $newId = $null
    $dataMade = $null
    $pre = $null
    $tempData = @{}
    # ROLLBACK-DISKS-FIRST-1 review: the disks made before the stop that are
    # not on the machine yet. Each bills, so a restore that stops names them.
    $osMade = [System.Collections.Generic.List[string]]::new()
    $dataPending = @()
    if ($madeRec) {
        # RESTORE-END-JOB-1: the disks made before the stop, from the
        # checkpoint. Nothing is made again.
        $tempName = if ([string]$madeRec.tempName) { [string]$madeRec.tempName } else { $null }
        $tempId = if ([string]$madeRec.tempId) { [string]$madeRec.tempId } else { $null }
        $newId = if ([string]$madeRec.newId) { [string]$madeRec.newId } else { $null }
        $dataMade = if ($madeRec.dataMade) { @{ Swaps = @(@($madeRec.dataMade.Swaps) | Where-Object { $_ }); Kept = @(@($madeRec.dataMade.Kept) | Where-Object { $_ }) } } else { $null }
        $tempData = if ($madeRec.tempData) { ConvertTo-VmfJobHashtable -Value $madeRec.tempData -IntKeys } else { @{} }
        $dataPending = @(@($madeRec.dataPending) | Where-Object { $_ })
    }
    else {
        try {
            # RESTORE-INLOOP-TEMP-1: keeping the names, each data disk the plan
            # puts back, before any is dropped for want of a temporary disk.
            $preserveRows = @($dataPlan.Restore)
            if ($preMade -and $naming -eq 'preserve') {
                # The rollback disk is the temporary disk.
                $tempName = $preMade.OsName
                $tempId = $preMade.OsId
                & $allowController $tempName
                foreach ($s in @($preMade.Data.Swaps)) { $tempData[[int]$s.lun] = [string]$s.diskId }
            }
            elseif ($preMade) {
                $newId = $preMade.OsId
                $finalName = $preMade.OsName
                & $allowController $finalName
                $dataMade = @{ Swaps = @($preMade.Data.Swaps); Kept = @($dataPlan.Kept) }
            }
            elseif ($naming -eq 'preserve') {
                # A managed disk cannot be renamed and two disks cannot share a
                # name, so the original name is freed by parking the machine on a
                # temporary restored disk first. Two creations is the honest price
                # of keeping the disk identity stable.
                $tempName = Get-VmfBoundedDiskName -BaseName $current.name -Suffix "-rtmp-$stamp"
                # SAFETY-CMK-1: with the key of the disk the copy was taken of,
                # read back before it goes on the machine.
                $tempId = New-VmfOsDiskFromCopy -Context $restoreContext -OpName 'restore:createTemp' `
                    -ResourceGroupName $rg -DiskName $tempName -SnapshotId $snapshot -Location $current.location -SkuName $newSku -Zone $zone `
                    -Disk $capturedVm.osDisk -OnMade { $osMade.Add($tempName) }
                & $allowController $tempName
                $pre = New-VmfOperatorTempDataDisks -Context $restoreContext -Plan $dataPlan -Location $current.location -Zone $zone
                $tempData = $pre.Temp
                $dataPlan = @{ Restore = @($dataPlan.Restore | Where-Object { $tempData.ContainsKey([int]$_.lun) })
                    Kept = @(@($dataPlan.Kept) + @($pre.Kept) | Sort-Object { [int]$_.lun }) }
            }
            else {
                # SAFETY-CMK-1: as the temporary disk above.
                $newId = New-VmfOsDiskFromCopy -Context $restoreContext -OpName 'restore:createDisk' `
                    -ResourceGroupName $finalRg -DiskName $finalName -SnapshotId $snapshot -Location $current.location -SkuName $newSku -Zone $zone `
                    -Disk $capturedVm.osDisk -OnMade { $osMade.Add($finalName) }
                & $allowController $finalName $finalRg
                $dataMade = Invoke-VmfDataDiskRestore -Context $restoreContext -RestorePlan $dataPlan -Location $current.location -Zone $zone -Step 'restore'
            }
            # SAFETY-ULTRA-MARGIN-1: every data disk back to its copy, or the
            # restore stops here, before it stops the machine.
            Assert-VmfDataDisksAllBack -Kept $(if ($dataMade) { @($dataMade.Kept) } else { @($dataPlan.Kept) })
            # RESTORE-INLOOP-TEMP-1: keeping the names, the stopped window takes
            # only LUNs whose temporary disk exists. A disk with none and not
            # kept by design stops the restore here - it never drops out of the
            # restore, to start later on the disk it has now.
            if ($naming -eq 'preserve') { Assert-VmfDataTempDisksMade -Rows $preserveRows -TempMade $tempData -Kept @($dataPlan.Kept) }
            # RESTORE-ONE-AT-A-TIME-1: the last point where nothing changed. A
            # job that took the machine meanwhile stops this one here.
            Assert-VmfMachineLeaseHeld -Token $machineLease
            # RESTORE-END-JOB-1 (rule 4): every decision and every disk made
            # before the stop, saved before the stop - or the restore stops
            # here, with the machine as it was.
            $pendingNames = @($(if ($dataMade) { @($dataMade.Swaps) | ForEach-Object { [string]$_.diskName } } else { @($dataPlan.Restore) | ForEach-Object { [string]$_.tempName } }) | Where-Object { $_ })
            $tempRec = $null
            if ($tempData.Count) { $tempRec = [ordered]@{}; foreach ($k in $tempData.Keys) { $tempRec[[string]$k] = [string]$tempData[$k] }; $tempRec = [pscustomobject]$tempRec }
            Save-VmfPutBackJobStep -Token $jobToken -Phase 'made' -MustWrite -Data @{ made = [pscustomobject][ordered]@{
                    dataPlan = [pscustomobject]@{ Restore = @($dataPlan.Restore); Kept = @($dataPlan.Kept) }
                    preMade = $(if ($preMade) { [pscustomobject]@{ OsName = [string]$preMade.OsName; OsId = [string]$preMade.OsId; Ids = @($preMade.Ids)
                                Data = [pscustomobject]@{ Swaps = @($preMade.Data.Swaps); Kept = @($preMade.Data.Kept) } } } else { $null })
                    finalName = [string]$finalName
                    tempName = $tempName; tempId = $tempId; newId = $newId
                    dataMade = $(if ($dataMade) { [pscustomobject]@{ Swaps = @($dataMade.Swaps); Kept = @($dataMade.Kept) } } else { $null })
                    tempData = $tempRec
                    dataPending = @($pendingNames)
                } }
        }
        catch {
            # MADE-DISK-NAMED-1: every disk this restore made bills, so the
            # stop names each one in one list - the OS disk, each data disk
            # made to go on the machine, and each one Azure made and the
            # read-back refused.
            $dataNames = if ($dataMade) { Get-VmfMadeDataDiskNames -Made @(@($dataMade.Swaps) | ForEach-Object { [string]$_.diskName }) -Kept @($dataMade.Kept) }
                         elseif ($pre) { Get-VmfMadeDataDiskNames -Made @(@($dataPlan.Restore) | Where-Object { $pre.Temp.ContainsKey([int]$_.lun) } | ForEach-Object { [string]$_.tempName }) -Kept @($pre.Kept) }
                         else { @() }
            $madeList = @(@(@($osMade) + @($dataNames)) | Where-Object { $_ } | ForEach-Object { "'$_'" })
            $madeWords = if ($madeList.Count -eq 1) { " The disk made from the safety copy is kept: $($madeList[0])." }
                         elseif ($madeList.Count) { " The disks made from the safety copy are kept: $($madeList -join ', ')." }
                         else { '' }
            $stopWhy = "The restore stopped before it changed the machine: $($_.Exception.Message) The machine is as it was before the restore.$madeWords"
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail $stopWhy
            throw $stopWhy
        }
        $dataPending = @($(if ($dataMade) { @($dataMade.Swaps) | ForEach-Object { [string]$_.diskName } } else { @($dataPlan.Restore) | ForEach-Object { [string]$_.tempName } }) | Where-Object { $_ })
        $madeNames = @(@($(if ($tempName) { $tempName } else { $finalName })) + $dataPending | Where-Object { $_ } | ForEach-Object { "'$_'" })
        if (-not $preMade) {
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome info -VmId $VmId `
                -Detail "The restore made the disks $($madeNames -join ', ') from the safety copy before it stops the machine."
        }
    }
    # Names the disks made before the stop that are not on the machine.
    $osPending = if ($tempName) { $tempName } else { $finalName }
    $pendingWords = {
        $left = @(@($osPending) + @($dataPending) | Where-Object { $_ } | ForEach-Object { "'$_'" })
        if ($left.Count) { " The disks made from the safety copy that are not on the machine are kept: $($left -join ', ')." } else { '' }
    }
    # RESTORE-INLOOP-TEMP-1 (rule 4): a resume, keeping the names, asks the
    # checkpoint the same before it changes anything more - each data disk it
    # puts back has its temporary disk, made before the stop. A checkpoint
    # that names none for a LUN is refused, never made good in the stopped
    # window. The restore before the stop asked it already.
    if ($madeRec -and $naming -eq 'preserve' -and -not (& $stepDone 'dataSwapped')) {
        try { Assert-VmfDataTempDisksMade -Rows @($dataPlan.Restore) -TempMade $tempData -Kept @($dataPlan.Kept) }
        catch {
            $resumeWhy = "The restore did not go on after its job stopped, and it changed nothing more on the machine: $($_.Exception.Message)$(& $pendingWords)"
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail $resumeWhy
            throw $resumeWhy
        }
    }

    # RESTORE-END-JOB-1: a resume past the stop does not stop the machine
    # again.
    if (-not (& $stepDone 'stopped')) {
    try {
        Invoke-VmfAzOperation -Name 'restore:stop' -RunPath $RunPath -VmId $VmId -Operation {
            Stop-VmfVmDeallocated -ResourceGroupName $rg -Name $vmName
        } | Out-Null
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM' -or -not (& $pendingWords)) { throw }
        $stopWhy = "The restore could not stop the machine: $($_.Exception.Message)$(& $pendingWords)"
        Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail $stopWhy
        throw $stopWhy
    }
    Save-VmfPutBackJobStep -Token $jobToken -Phase 'stopped'
    }

    # The restore's record (RESTORE-ALL-1), built in one place: after the
    # stopped window, and in its catch when a data disk swap is left
    # (SWAP-REFUSED-AFTER-STOP-1), where the size is not read.
    $restoreRecord = {
        param($sizeValue)
        $idChanged = ($naming -ne 'preserve')
        [ordered]@{
            # FINISH-NO-RESTORE-RECORD-1 (vm-state v32): the restore's engine
            # operation, as its checkpoint and its swap record name it - so
            # Finish the restore never takes an earlier restore's record for it.
            operationId            = $(if ($jobToken) { [string]$jobToken.Job.operationId } else { $null })
            restoredUtc            = (Get-Date).ToUniversalTime().ToString('o')
            # POWER-AFTER-MOVE-1 (v39): the power state the restore found when
            # it started - the newest reading a later rebuild keeps.
            powerAtStart           = $(if ($powerAtStart) { [string]$powerAtStart } else { $null })
            restoredBy             = $RestoredBy
            note                   = $Note
            fromSnapshotId         = $snapshot
            fromCopy               = $From
            # A pristine restore reverts the hardware, so the machine may no longer
            # be on the size the plan named. Record what it actually ended on: the
            # dashboard was showing the PLAN (source -> target) and calling it the
            # machine, which after a put-back is simply wrong.
            sizeAfter              = $(if ($null -ne $sizeValue) { [string]$sizeValue } else { $null })
            diskNaming             = $naming
            # REBUILD-REMOVE-RECOVER-1: no "rebuilt" (vm-state v15) - no restore
            # rebuilds a machine. A record an earlier version wrote keeps it.
            previousDiskId         = $current.id
            previousDiskName       = $current.name
            newDiskId              = $newId
            newDiskName            = $finalName
            diskIdChanged          = $idChanged
            retainedDiskId         = $(if ($idChanged) { $current.id } else { $null })
            # RESTORE-ALL-1 (vm-state v14): every data disk it replaced, and every
            # one it left, with the reason.
            dataDisks              = @($dataResult.Replaced)
            # FINISH-KEPT-DISKS-1: also when the data restore threw part way
            # and gave no result - the disks it keeps by design are in its plan.
            dataDisksKept          = @(& $keptOf)
            # ROLLBACK-SIZE-REFUSED-SERIES-1 (vm-state v51): the restore put the
            # first copy on the target size of the plan, not on the original
            # size Azure refused. Absent or null for any other restore.
            ontoTarget             = $(if ($onto) { [ordered]@{ option = [string]$onto.Option; size = [string]$onto.Size
                                                                originalSize = [string]$onto.OriginalSize; reasonCode = 'rollbackSizeRefused' } } else { $null })
        }
    }
    # SWAP-REFUSED-AFTER-STOP-1: what the restore writes when a data disk swap
    # is left, used by the stopped window and its catch alike.
    $dataResult = $null
    # Re-review: the data restore's own view while it runs. If it throws part
    # way, $dataResult is never set; what it left, and every LUN not proven on
    # its copy, still count, so the machine is never started on them.
    $dataProgress = @{}
    $swapLeftOf = {
        if ($dataResult) { return @(@($dataResult.Left) | Where-Object { $_ }) }
        if (-not $dataProgress['Began']) { return @() }
        @(@($dataProgress['Left']) + @($(if ($dataProgress['Pending']) { $dataProgress['Pending'].Values })) | Where-Object { $_ } | Sort-Object { [int]$_.lun })
    }
    # FINISH-KEPT-DISKS-1: each data disk the restore keeps as it is by design
    # - from its result, or, when the data restore threw part way, from what
    # it decided before the stop (the disks made, or its plan).
    $keptOf = {
        if ($dataResult) { return @(@($dataResult.Kept) | Where-Object { $_ }) }
        @(@($(if ($dataMade) { $dataMade.Kept } else { $dataPlan.Kept })) | Where-Object { $_ } | Sort-Object { [int]$_.lun })
    }
    $recordSwapLeft = {
        $leftRows = @(& $swapLeftOf)
        if (-not $leftRows.Count) { return }
        # RESTORE-END-JOB-1: a resume that stopped part way through the data
        # disks knows the LUNs it proved done (Progress.Done).
        $swappedRows = if ($dataResult) { @($dataResult.Replaced) } else { @($dataProgress['Done']) }
        Set-VmfSwapPending -RunPath $RunPath -VmId $VmId -Record (New-VmfSwapPendingRecord -Kind 'restore' -Swaps $leftRows `
                -Reason ([string]$leftRows[-1].why) -UsedBy $(if ($preMade) { 'restore' } else { '' }) `
                -Swapped @(@($swappedRows) | Where-Object { $_ } | ForEach-Object { @{ lun = [int]$_.lun; diskId = [string]$_.newDiskId; diskName = [string]$_.newDiskName } }) `
                -Kept @(& $keptOf) -OperationId $(if ($jobToken) { [string]$jobToken.Job.operationId } else { '' }) -PowerAtStart $powerAtStart)
    }
    # From here the machine is DOWN. Anything that goes wrong must still leave
    # it running - a disaster-recovery tool that abandons a machine powered off
    # has made the outage worse (found by the RESTORE-1 drill).
    try {

    # ROLLBACK-RETRY-CAPTURE-3: the first copy on its size again - so, right
    # after the stop and BEFORE any machine update (leaving the reservation,
    # the size, the disk swap), each interface the capture recorded off goes
    # off. Azure refuses every update of a 2-vCPU machine with two interfaces
    # on (measured 2026-10-10), and the move turns the primary on. It only
    # turns OFF; the set-back after the size still runs.
    # RESTORE-END-JOB-1: this step and the hardware below are one checkpoint
    # (hardware). Each part sets a state, so a resume that does them again
    # changes nothing that is already set.
    $hardwareDone = & $stepDone 'hardware'
    if ($From -eq 'pristine' -and $backSize -and -not $hardwareDone) {
        $null = Restore-VmfCapturedAcceleratedNetworking -RunPath $RunPath -VmId $VmId -Nics $capturedVm.nics -Kind 'restore' -OffFirst `
            -Size $backSize -Location ([string]$current.location)
    }

    # SAFETY-2: the pristine copy presupposes the ORIGINAL hardware. Its
    # initramfs has no NVMe driver and its registry has no stornvme boot entry,
    # because it was taken before guest prep put them there. Putting that disk
    # on a machine already resized to NVMe produces a machine that does not
    # boot - a safety copy nobody can actually restore. So going back to "as it
    # was" means the size and controller go back too, while the machine is
    # still stopped. The prepared copy needs none of this: it was taken with
    # prep applied, so it boots on the new hardware.
    #
    # ROLLBACK-ORDER-1: and the hardware goes back FIRST, before any disk is
    # swapped in. A copy keeps the controllers its disk allowed when it was
    # taken - SCSI only, for a machine whose image never said NVMe - and Azure
    # refuses to swap in a disk that does not allow the machine's CURRENT
    # controller. It did exactly that in the GEN1-DISTROS-1 lab run.
    if ($From -eq 'pristine' -and -not $hardwareDone) {
        # ROLLBACK-SIZE-REFUSED-SERIES-1: onto the target size of the plan,
        # with the controller of the first capture (SCSI, or none on
        # Generation 1, ROLLBACK-NULL-1) - a v5 or Bsv2 size takes both.
        $capturedSize = $backSize
        $capturedController = [string]$capturedVm.controller
        if ($capturedSize) {
            # Reserved capacity is ONE WAY (confirmed): a group is created
            # to hold the v6 TARGET and nothing ever reserves the original size.
            # So going back always means leaving the group - and it has to happen
            # before the size changes, because Azure refuses to start a VM whose
            # size has no reservation in the group it is attached to:
            #   Capacity Reservation with VM size Standard_D2s_v4 does not exist
            #   in the Capacity Reservation Group '...'   (409)
            # That failed the restore inside the stopped window - the safety net
            # tearing exactly where it is needed. Found by the SAFETY-2 drill.
            # ROLLBACK-CRG-1: only a group the machine was not in before the
            # move is left (Invoke-VmfReservationLeave, restore:leaveReservation)
            # - and the group it was in goes back after the size, below.
            $crgPlan = Get-VmfReservationPutBack -RunPath $RunPath -VmId $VmId -Rg $rg -VmName $vmName -Kind 'restore' -Capture $capturedVm
            $null = Invoke-VmfReservationLeave -RunPath $RunPath -VmId $VmId -Rg $rg -VmName $vmName -Kind 'restore' -Decision $crgPlan -Size $capturedSize
            # What the original size refuses goes back before it.
            $before = Restore-VmfForOriginalSize -RunPath $RunPath -VmId $VmId -Doc $doc -Size $capturedSize -Location $current.location -DiskIds $inUse -TypeBack $typeBack
            Invoke-VmfAzOperation -Name 'restore:revertHardware' -RunPath $RunPath -VmId $VmId -Operation {
                Set-VmfVmSizeAndController -ResourceGroupName $rg -Name $vmName `
                    -Size $capturedSize -Controller $capturedController
            } | Out-Null
            # ROLLBACK-CRG-1: on its own size, still stopped. A refusal is said
            # and the restore goes on.
            $null = Invoke-VmfReservationRejoin -RunPath $RunPath -VmId $VmId -Rg $rg -VmName $vmName -Kind 'restore' -Decision $crgPlan -Size $capturedSize
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome info -VmId $VmId `
                -Detail $(if ($onto) { Get-VmfRestoreOntoTargetWords -Onto $onto -Controller $capturedController }
                          else { "The machine is back on the size $capturedSize, with the $capturedController disk controller. The first safety copy is from before the guest changes that let it start on the new size." })
            # ROLLBACK-AN-1: back on the original size, so accelerated
            # networking goes back to how the capture found it too.
            if (-not $before.AnDone) { $null = Restore-VmfCapturedAcceleratedNetworking -RunPath $RunPath -VmId $VmId -Nics $capturedVm.nics -Kind 'restore' }
        }
        Save-VmfPutBackJobStep -Token $jobToken -Phase 'hardware'
    }

    # RESTORE-END-JOB-1: each OS disk step saves when it ends. A resume that
    # finds a delete not saved asks Azure first (Remove-VmfDiskForResume):
    # keeping the name, the disk made under it has the original's resource id,
    # and only the copy it was made from tells the two apart.
    if ($naming -eq 'preserve') {
        if (-not (& $stepDone 'osOnTemp')) {
        # The temporary disk was made, read back and given its controller
        # before the stop (ROLLBACK-DISKS-FIRST-1).
        Invoke-VmfAzOperation -Name 'restore:swapTemp' -RunPath $RunPath -VmId $VmId -Operation {
            Set-VmfVmOsDisk -ResourceGroupName $rg -Name $vmName -DiskId $tempId -DiskName $tempName
        } | Out-Null
        # ROLLBACK-DISKS-FIRST-1: a rollback disk that a put-back
        # put on the machine is never used again, nor deleted by a cleanup.
        if ($preMade) { Set-VmfRollbackDisksBeforeMoveUsed -RunPath $RunPath -VmId $VmId -DiskIds @([string]$tempId) -By 'restore' }
        Save-VmfPutBackJobStep -Token $jobToken -Phase 'osOnTemp'
        }
        $osPending = $null
        # RESTORE-ORIGINAL-DELETE-RESTART-1 (2026-11-11): a
        # delete of the original OS disk that Azure refuses - after the lock
        # check passed - puts that disk back and starts the machine as it was
        # (Invoke-VmfRestoreOriginalBack). The catch of the stopped window
        # started it on the temporary disk, with the data disks of now. A
        # resume past originalKept goes on with the rollback, never with the
        # delete.
        $keptWhy = $null
        if ((& $stepDone 'originalKept') -and -not (& $stepDone 'originalRemoved')) {
            $keptWhy = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $jobToken.Job -Name 'originalKept') -Name 'why')
            if (-not $keptWhy) { $keptWhy = 'Azure did not say why.' }
        }
        if (-not $keptWhy -and -not (& $stepDone 'originalRemoved')) {
        try {
            if (& $wasDone 'osOnTemp') {
                $null = Remove-VmfDiskForResume -RunPath $RunPath -VmId $VmId -DiskId ([string]$current.id) -ResourceGroupName $current.resourceGroup -DiskName $current.name -NotFrom $snapshot
            }
            else {
            Invoke-VmfAzOperation -Name 'restore:removeOriginal' -RunPath $RunPath -VmId $VmId -Operation {
                Remove-VmfManagedDisk -ResourceGroupName $current.resourceGroup -DiskName $current.name
            } | Out-Null
            }
        }
        catch {
            # A lost hold of the machine: another job has it, so this one
            # changes nothing more.
            if ($_.Exception.Message -match 'abandon this VM') {
                $lostHold = [System.InvalidOperationException]::new($_.Exception.Message)
                $lostHold.Data['vmfRestoreStranded'] = $true
                throw $lostHold
            }
            $keptWhy = [string]$_.Exception.Message
            Save-VmfPutBackJobStep -Token $jobToken -Phase 'originalKept' -Data @{ originalKept = [pscustomobject]@{ why = $keptWhy } }
        }
        if (-not $keptWhy) { Save-VmfPutBackJobStep -Token $jobToken -Phase 'originalRemoved' }
        }
        if ($keptWhy) {
            # Only the temporary data disks this restore made are deleted. The
            # rollback disks before the move stay, unused.
            $tempDataDisks = @(if (-not $preMade) {
                    @($dataPlan.Restore) | Where-Object { [string]$_.tempName -and $tempData.ContainsKey([int]$_.lun) } |
                        ForEach-Object { [pscustomobject]@{ name = [string]$_.tempName; id = [string]$tempData[[int]$_.lun] } } })
            try {
                $back = Invoke-VmfRestoreOriginalBack -RunPath $RunPath -VmId $VmId -ResourceGroupName $rg -VmName $vmName -Original $current -Why $keptWhy `
                    -TempName $tempName -TempId $tempId -TempDataDisks $tempDataDisks -JobToken $jobToken -PowerAtStart $powerAtStart
                $endWhy = [string]$back.Words
                $backEnd = [System.InvalidOperationException]::new($endWhy)
            }
            catch { $backEnd = [System.InvalidOperationException]::new($_.Exception.Message) }
            # Said already. The catch below starts nothing on any disk.
            $backEnd.Data['vmfRestoreStranded'] = $true
            throw $backEnd
        }
        if (-not (& $stepDone 'osSwapped')) {
        # Only now can the disk that keeps the name be made: the name was in
        # use until the original was deleted. SAFETY-CMK-1: read back too.
        $newId = New-VmfOsDiskFromCopy -Context $restoreContext -OpName 'restore:createDisk' `
            -ResourceGroupName $finalRg -DiskName $finalName -SnapshotId $snapshot -Location $current.location -SkuName $newSku -Zone $zone `
            -Disk $capturedVm.osDisk
        $osPending = $finalName
        & $allowController $finalName $finalRg
        }
    }

    # With a new name the disk was made before the stop; keeping the name,
    # just above.
    if (-not (& $stepDone 'osSwapped')) {
    Invoke-VmfAzOperation -Name 'restore:swapDisk' -RunPath $RunPath -VmId $VmId -Operation {
        Set-VmfVmOsDisk -ResourceGroupName $rg -Name $vmName -DiskId $newId -DiskName $finalName
    } | Out-Null
    Save-VmfPutBackJobStep -Token $jobToken -Phase 'osSwapped' -Data @{ os = [pscustomobject]@{ newId = [string]$newId; finalName = [string]$finalName } }
    }
    else { $newId = [string]$jobToken.Job.os.newId; $finalName = [string]$jobToken.Job.os.finalName }
    if ($preMade) { Set-VmfRollbackDisksBeforeMoveUsed -RunPath $RunPath -VmId $VmId -DiskIds @([string]$newId) -By 'restore' }
    # MADE-DISK-RECORD-1: a disk this restore made is the machine's own once it
    # is on the machine. Never throws.
    Set-VmfMadeDiskMark -RunPath $RunPath -VmId $VmId -DiskIds @([string]$newId) -Field 'usedUtc'
    $osPending = $null

    if ($tempName -and -not (& $stepDone 'tempRemoved')) {
        # CANNOTDELETE-RESTORE-1: the OS disk is on the machine under its own
        # name now, so a temporary disk Azure does not delete is said, and the
        # restore goes on - as for a temporary data disk. A throw here started
        # the machine on the restored OS disk with the data disks of another
        # moment. A lost hold of the machine still stops it.
        try {
            if (& $wasDone 'osSwapped') {
                $null = Remove-VmfDiskForResume -RunPath $RunPath -VmId $VmId -DiskId ([string]$tempId) -ResourceGroupName $rg -DiskName $tempName -RemoveOp 'restore:removeTemp'
            }
            else {
            Invoke-VmfAzOperation -Name 'restore:removeTemp' -RunPath $RunPath -VmId $VmId -Operation {
                Remove-VmfManagedDisk -ResourceGroupName $rg -DiskName $tempName
            } | Out-Null
            }
            # MADE-DISK-RECORD-1: gone, so no restore names it again.
            Set-VmfMadeDiskMark -RunPath $RunPath -VmId $VmId -DiskIds @([string]$tempId) -Field 'deletedUtc'
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome warn -VmId $VmId `
                -Detail "The temporary disk '$tempName' is not attached and was not deleted: $(([string]$_.Exception.Message).TrimEnd('.')). Delete it when you are sure."
        }
        Save-VmfPutBackJobStep -Token $jobToken -Phase 'tempRemoved'
    }

    # RESTORE-ALL-1: the data disks, still stopped, in the machine's zone.
    # ROLLBACK-DISKS-FIRST-1: the disks made before the stop, swapped in now.
    # From here the data restore names each disk it does not put on.
    # RESTORE-END-JOB-1: a resume past the OS disk reads each LUN first, and
    # each goes on from where it stands (Invoke-VmfResumableDataRestore).
    $dataPending = @()
    if (& $stepDone 'dataSwapped') { $dataResult = $jobToken.Job.result.data }
    else {
    $dataResult = Invoke-VmfResumableDataRestore -Context $restoreContext `
        -VmName $vmName -Plan $dataPlan -Naming $naming -Location $current.location -Zone $zone -Made $dataMade -TempMade $tempData -Progress $dataProgress `
        -UsedBy $(if ($preMade) { 'restore' } else { '' }) -Resuming:(& $wasDone 'osSwapped')
    Save-VmfPutBackJobStep -Token $jobToken -Phase 'dataSwapped' -Data @{ result = [pscustomobject]@{ newId = [string]$newId; finalName = [string]$finalName; data = $dataResult } }
    }
    # SWAP-REFUSED-AFTER-STOP-1 (review): on record the moment the data restore
    # says a swap is left - before any other call that can fail - so nothing
    # after it can start the machine or leave it stopped with no record.
    & $recordSwapLeft
    # MADE-DISK-RECORD-1: each data disk now on the machine. Never throws.
    Set-VmfMadeDiskMark -RunPath $RunPath -VmId $VmId -DiskIds @(@($dataResult.Replaced) | Where-Object { $_ } | ForEach-Object { [string]$_.newDiskId }) -Field 'usedUtc'
    if ($preMade) {
        # New names: the disk on each LUN restored is the one made for the way
        # back. Keeping the names: each LUN restored ran on it as its
        # temporary disk.
        $doneLuns = @($dataResult.Replaced | ForEach-Object { [int]$_.lun })
        Set-VmfRollbackDisksBeforeMoveUsed -RunPath $RunPath -VmId $VmId -DiskIds @(@($dataResult.Replaced | ForEach-Object { [string]$_.newDiskId }) +
            @($preMade.Data.Swaps | Where-Object { [int]$_.lun -in $doneLuns } | ForEach-Object { [string]$_.diskId })) -By 'restore'
    }

    # SWAP-2UPD-1: a data disk is swapped in two updates, so a swap that stops
    # between them can leave a LUN with NO disk. A machine is never started
    # like that - a Linux mount with no nofail stops the boot. It stays
    # stopped, the record says where each disk stands, and the error says
    # which disk to attach.
    $leftStopped = @(Get-VmfEmptyDataLuns -RunPath $RunPath -VmId $VmId -ResourceGroupName $rg -VmName $vmName -Before $liveData)
    # SWAP-REFUSED-AFTER-STOP-1: and never with a data disk Azure did not swap
    # back, even after the tries - the LUN keeps the disk it had while the
    # other disks are back from the copy. Stopped, and recorded below.
    $swapLeft = @(@($dataResult.Left) | Where-Object { $_ })
    if (-not $leftStopped.Count -and -not $swapLeft.Count -and -not (& $stepDone 'started')) {
        Invoke-VmfAzOperation -Name 'restore:start' -RunPath $RunPath -VmId $VmId -Operation {
            Start-VmfVm -ResourceGroupName $rg -Name $vmName
        } | Out-Null
        Invoke-VmfAzOperation -Name 'restore:agentReady' -RunPath $RunPath -VmId $VmId -Operation {
            Wait-VmfVmAgentReady -ResourceGroupName $rg -Name $vmName
        } | Out-Null
        Save-VmfPutBackJobStep -Token $jobToken -Phase 'started'
    }

    }
    catch {
        $failure = $_.Exception.Message
        # RESTORE-INLOOP-TEMP-1: a data restore that keeps the machine stopped
        # on purpose (RestoreAll.ps1) has said so, with each disk. Nothing here
        # may start the machine.
        if ($_.Exception.Data['vmfRestoreStranded']) { throw $failure }
        # ROLLBACK-DISKS-FIRST-1 review: a disk made before the stop bills.
        $failure = "$failure$((& $pendingWords).TrimEnd('.'))"
        # SWAP-REFUSED-AFTER-STOP-1 (review MUST FIX 1): a data disk swap is
        # left, so the machine is never started here, whatever else failed -
        # it would run on disks from two moments. The swap goes on record (once
        # more, in case the first write is what failed) with the restore's own
        # record, and the machine stays stopped for Finish the restore.
        $leftInCatch = @(& $swapLeftOf)
        if ($leftInCatch.Count) {
            $recordNote = ''
            try {
                & $recordSwapLeft
                $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
                $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject](& $restoreRecord $null)) -Force
                # ROLLBACK-SIZE-REFUSED-SERIES-1: the size is set already.
                if ($onto -and (& $stepDone 'hardware')) { Set-VmfOriginalSizeOnto -Doc $doc -Onto $onto -OperationId $(if ($jobToken) { [string]$jobToken.Job.operationId } else { '' }) }
                Write-VmfStateDoc -RunPath $RunPath -Document $doc
            }
            catch { $recordNote = " The machine's record could not be written: $($_.Exception.Message)" }
            # RESTORE-EMPTY-LUN-1: a LUN with no disk is said as no disk.
            $emptyInCatch = @()
            try { $emptyInCatch = @(Get-VmfEmptyDataLuns -RunPath $RunPath -VmId $VmId -ResourceGroupName $rg -VmName $vmName -Before $liveData | ForEach-Object { [int]$_.lun }) } catch { $emptyInCatch = @() }
            # RESTORE-THROW-STARTS-1: a LUN the data restore did not read is
            # said as not read, never as a disk it keeps.
            $unreadInCatch = @(if ($dataResult) { @($dataResult.Unread) | Where-Object { $null -ne $_ -and [int]$_ -notin $emptyInCatch } | ForEach-Object { [int]$_ } })
            $otherInCatch = @(if ($dataResult) { @($dataResult.Other) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ } })
            $refusedInCatch = @($leftInCatch | Where-Object { [int]$_.lun -notin $unreadInCatch -and [int]$_.lun -notin $otherInCatch })
            $otherWords = @($leftInCatch | Where-Object { [int]$_.lun -notin $unreadInCatch -and [int]$_.lun -in $otherInCatch } | ForEach-Object { ([string]$_.why).TrimEnd('.') + '.' })
            $notReadWords = Format-VmfSwapLeftUnread -Swaps @($leftInCatch | Where-Object { [int]$_.lun -in $unreadInCatch })
            $leftWords = "The restore did not finish, and the machine is left STOPPED: $(@(@($(if ($refusedInCatch.Count) { "Azure did not swap these data disks back: $(Format-VmfSwapLeft -Swaps $refusedInCatch -EmptyLuns $emptyInCatch)." })) + @($notReadWords) + @($otherWords) | Where-Object { $_ }) -join ' ') Use $(Get-VmfFinishActionName -Kind 'restore') on this machine. Restore failure: $failure$recordNote"
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail $leftWords
            throw $leftWords
        }
        $landedOn = '(unknown)'
        $empty = @()
        try { $empty = @(Get-VmfEmptyDataLuns -RunPath $RunPath -VmId $VmId -ResourceGroupName $rg -VmName $vmName -Before $liveData) } catch { $empty = @() }
        if ($empty.Count) {
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId `
                -Detail "The restore did not finish, and the machine is left STOPPED: $(Format-VmfEmptyDataLuns $empty). $failure"
            throw "The restore did not finish, and the machine is left STOPPED: $(Format-VmfEmptyDataLuns $empty). Restore failure: $failure"
        }
        try {
            Invoke-VmfAzOperation -Name 'restore:recoverStart' -RunPath $RunPath -VmId $VmId -Operation {
                Start-VmfVm -ResourceGroupName $rg -Name $vmName
            } | Out-Null
            $landedOn = (Get-VmfOsDiskInfo -ResourceGroupName $rg -Name $vmName).name
            # STEP-LOG-2: the machine is started. A line that cannot be written
            # must not land in the catch below, which says it is DOWN.
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome warn -VmId $VmId `
                -Detail "The restore did not complete, and the machine started again on the disk '$landedOn': $failure"
        }
        catch {
            Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId `
                -Detail "The restore did not complete, and Azure did not start the machine. The machine is stopped. Restore failure: $failure Start failure: $($_.Exception.Message)"
            throw "The restore did not complete, and Azure did not start the machine. The machine is stopped. Restore failure: $failure. Start failure: $($_.Exception.Message)"
        }
        # POWER-AFTER-MOVE-1: the machine was started to recover it; it goes
        # back to the power state the restore found when it started, and the
        # words say where it is. A refusal is written as owed.
        $failBack = Invoke-VmfJobPowerReturn -RunPath $RunPath -VmId $VmId -Step 'restore' -Power $powerAtStart -Before 'the restore' -RecordRefusal
        if ($failBack -and $failBack.Ok) {
            throw "The restore did not complete: $failure. The machine was restarted on disk '$landedOn'. $($failBack.Words)"
        }
        throw "The restore did not complete: $failure. The machine has been restarted and is running on disk '$landedOn'.$(if ($failBack) { " $($failBack.Words)" })"
    }

    # POWER-AFTER-MOVE-1 (2026-11-06: a machine ends in the power state it
    # had at the start, on or off): the restore started the machine, and
    # waited for its agent, to show it boots. Now it goes back to the power
    # state the restore found when it started ($powerAtStart, kept in its
    # checkpoint). A resume past 'started' comes here again, and a
    # return to the power state the machine has does nothing. A machine left
    # stopped for a data disk is not started, so there is nothing to return.
    $powerBack = $null
    # VOLUMES-ONLINE-1: the check inside the machine, while it runs and before
    # the return - the disks made from a safety copy have new device IDs, and
    # an LVM devices file left a volume offline after a put-back in the final
    # lab. On the checkpoint (putBackJob.volumes) before the return, so a
    # resume after it uses the result and never asks a stopped machine.
    $volumes = $null
    if (-not $leftStopped.Count -and -not $swapLeft.Count) {
        $keptCheck = if ($jobToken) { Get-VmfRecordField -Object $jobToken.Job -Name 'volumes' } else { $null }
        if ($keptCheck -and [string](Get-VmfRecordField -Object $keptCheck -Name 'verdict')) { $volumes = $keptCheck }
        else {
            $volumes = [pscustomobject](Invoke-VmfVolumesCheckAfterPutBack -RunPath $RunPath -VmId $VmId -ResourceGroupName $rg -VmName $vmName `
                    -Os (Get-VmfGuestOsFromRecord -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId)) -Kind 'restore')
            Save-VmfPutBackJobData -Token $jobToken -Data @{ volumes = $volumes }
        }
        $powerBack = Invoke-VmfJobPowerReturn -RunPath $RunPath -VmId $VmId -Step 'restore' -Power $powerAtStart -Before 'the restore'
    }
    $volumesLost = [bool]($volumes -and [string]$volumes.verdict -eq 'MISSING')

    $idChanged = ($naming -ne 'preserve')
    # Through the boundary like every other ARM call - the module-wide guard
    # caught this one bare within minutes of it being written.
    # SWAP-REFUSED-AFTER-STOP-1 (review note b): with a swap left, the swap is
    # on record already, and a size that cannot be read is written as unknown.
    # MISSING-READ-1: and with none left. The read throws now when Azure does
    # not answer (it was an empty size), and the machine is restored: a size
    # Azure does not give is unknown, never a reason to leave the restore with
    # no record (FINISH-NO-RESTORE-RECORD-1). A lost lease still stops it.
    try {
        $sizeAfter = Invoke-VmfAzOperation -Name 'restore:sizeAfter' -RunPath $RunPath -VmId $VmId -Operation {
            Get-VmfVmSize -ResourceGroupName $rg -Name $vmName
        }
    }
    catch {
        if (-not $swapLeft.Count -and $_.Exception.Message -match 'abandon this VM') { throw }
        $sizeAfter = $null
    }

    $record = & $restoreRecord $sizeAfter
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]$record) -Force
    # ROLLBACK-SIZE-REFUSED-SERIES-1: in the same write as the restore's
    # record, the size the machine is on now becomes the first capture's, so
    # every later rollback and restore returns it there.
    if ($onto) { Set-VmfOriginalSizeOnto -Doc $doc -Onto $onto -OperationId $(if ($jobToken) { [string]$jobToken.Job.operationId } else { '' }) }
    # RESTORE-END-JOB-1: the checkpoint goes in the same write as the record
    # that ends the restore - there is never a moment with neither.
    Remove-VmfPutBackJobOnDoc -Doc $doc -Token $jobToken
    # SWAP-REFUSED-AFTER-STOP-1 (vm-state v25): in the same write as the
    # restore's record - every data disk left, and what Finish the restore
    # needs to swap it.
    if ($swapLeft.Count) {
        $doc | Add-Member -NotePropertyName swapPending -Force -NotePropertyValue (New-VmfSwapPendingRecord -Kind 'restore' -Swaps $swapLeft `
                -Reason ([string]$swapLeft[-1].why) -UsedBy $(if ($preMade) { 'restore' } else { '' }) `
                -Swapped @(@($dataResult.Replaced) | ForEach-Object { @{ lun = [int]$_.lun; diskId = [string]$_.newDiskId; diskName = [string]$_.newDiskName } }) `
                -Kept @(& $keptOf) -OperationId $(if ($jobToken) { [string]$jobToken.Job.operationId } else { '' }) -PowerAtStart $powerAtStart)
    }
    # VOLUMES-RETRY-CHECK-1: in the same write as the restore's record - a
    # volume not mounted, or a check that could not run, owes the next retry
    # a check of the volumes first; a check that found every volume removes a
    # record from before. No check (a data disk left) leaves it as it is.
    if ($volumes) { Set-VmfVolumesCheckOwed -Doc $doc -Verdict ([string]$volumes.verdict) -Kind 'restore' }
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    # POWER-AFTER-MOVE-1: a return Azure refused at every try is owed, after
    # the record of the restore, so the machine panel offers its return.
    if ($powerBack -and -not $powerBack.Ok) {
        Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState ([string]$doc.state) -Outcome fail -MachineState 'changed' `
            -PowerNotPutBack $powerBack.PowerNotPutBack -Detail $powerBack.Words | Out-Null
    }
    # VOLUMES-ONLINE-1: a volume that was mounted before the move and is not
    # mounted now - after the record, so the restore is on it, and as its own
    # stop: the machine is changed, never "restored". A retry checks the
    # volumes first (VOLUMES-RETRY-CHECK-1): a new "as it was" copy of a
    # machine with a volume offline would be wrong.
    if ($volumesLost) {
        Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState ([string]$doc.state) -Outcome fail -MachineState 'changed' -ReasonCode 'volumesNotBack' `
            -Detail "The restore swapped on the disks from the safety copy. Not every volume is mounted. $([string]$volumes.words) $(Get-VmfVolumesCheckNextStep)" | Out-Null
    }
    # SKIP-CHANGED-FREED-1: a machine left out while it was changed kept its
    # claim in this run. The record now says it is restored, so the claim
    # goes - by the settled-claim rule, which still keeps it while a data disk
    # swap is left. Never a failed restore: the end of a wave asks again.
    try { Remove-VmfSettledVmClaim -RunPath $RunPath -VmId $VmId | Out-Null }
    catch { Write-Warning "The claim of '$vmName' was not released: $($_.Exception.Message)" }

    # The id change must be REPORTED, never silent - this is the line an
    # operator needs when their next terraform plan shows a replacement.
    # MANUAL-REVIEW-1: shown word for word when the restore ends with a swap
    # left, so each part is a sentence.
    $idLine = if ($idChanged) {
        "The OS disk is a new managed disk, $finalName. Change any configuration that names $($current.name)."
    } else {
        "The OS disk has the name and resource ID of the earlier disk, $finalName. The restore did not copy its tags, role assignments or backup."
    }
    $restoredCount = @($dataResult.Replaced).Count; $keptCount = @($dataResult.Kept).Count
    $dataLine = if ($restoredCount -or $keptCount) {
        " $(if ($restoredCount -eq 1) { '1 data disk is' } else { "$restoredCount data disks are" }) restored, and $(if ($keptCount -eq 1) { '1 data disk stays as it was' } else { "$keptCount data disks stay as they were" })."
    } else { '' }
    $doneLine = "$RestoredBy restored the machine from a safety copy. $idLine$dataLine$(if ($Note) { " Note: $Note" })$(if ($powerBack) { " $($powerBack.Words)" })$(if ($volumes -and [string]$volumes.words) { " $([string]$volumes.words)" })"
    # Two literal outcomes: the page reads this file for every outcome a
    # restore can end on (putback-gone.test.js).
    # STEP-LOG-2: the restore is done and its record is kept, so a line that
    # cannot be written never reports it as failed.
    $swapLeftWords = if ($swapLeft.Count) { Format-VmfRestoreSwapLeftWords -Swaps $swapLeft -EmptyLuns @($leftStopped | ForEach-Object { [int]$_.lun }) -Unread @(@($dataResult.Unread) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) -Other @(@($dataResult.Other) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) -Refused @(@($dataResult.Refused) | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) } else { '' }
    # SWAP-REFUSED-AFTER-STOP-1: the one line that ends the restore on the
    # page is a fail line then - the machine is stopped.
    if ($swapLeft.Count) { Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome fail -VmId $VmId -Detail "$swapLeftWords $doneLine" }
    elseif ($dataResult.Failure -or $volumesLost) { Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome warn -VmId $VmId -Detail $doneLine }
    else { Write-VmfStepLine -RunPath $RunPath -Step 'restore' -Outcome ok -VmId $VmId -Detail $doneLine }
    # RESTORE-EMPTY-LUN-1: a LUN with no disk that the record names as a swap
    # that is left is Finish the restore's to end, in the app. Only a LUN the
    # record does not name still says which disk goes on it.
    $leftLuns = @($swapLeft | ForEach-Object { [int]$_.lun })
    $emptyUnnamed = @($leftStopped | Where-Object { [int]$_.lun -notin $leftLuns })
    if ($emptyUnnamed.Count) {
        throw "The OS disk is restored, and the machine is left STOPPED: $(Format-VmfEmptyDataLuns $emptyUnnamed). $($dataResult.Failure) The machine's record lists each data disk and where it stands."
    }
    if ($swapLeft.Count) {
        throw "$swapLeftWords$(if ($dataResult.Failure) { " $($dataResult.Failure)" }) The machine's record lists each data disk and where it stands."
    }
    # RESTORE-ALL-1: a data disk that stopped part way is said AFTER the record
    # is written and the machine runs - the record says where each disk stands.
    if ($dataResult.Failure) {
        # POWER-AFTER-MOVE-1: running only when it was found running.
        $runningWords = if ($powerBack -and $powerBack.Ok) { 'The machine is restored and in the power state it was found in' } else { 'The machine is restored and running' }
        throw "$runningWords, and its OS disk is restored. Not every data disk is: $($dataResult.Failure) The machine's record lists each data disk and where it stands."
    }
    # VOLUMES-ONLINE-1: said after the record, as a data disk is above.
    if ($volumesLost) {
        throw "The restore swapped on the disks from the safety copy. Not every volume is mounted. $([string]$volumes.words)"
    }

    [pscustomobject]@{
        VmId                    = $VmId
        RestoredFromSnapshotId  = $snapshot
        DiskNaming              = $naming
        PreviousDiskId          = $current.id
        NewDiskId               = $newId
        NewDiskName             = $finalName
        DiskIdChanged           = $idChanged
        RetainedDiskId          = $record.retainedDiskId
        DataDisks               = @($dataResult.Replaced)
        DataDisksKept           = @($dataResult.Kept)
        RestoredBy              = $RestoredBy
    }

    }
    finally {
        # RESTORE-END-JOB-1: a restore that ends here without its record ended
        # with an answer it said - never resumed. Never throws.
        # Only a job that held the machine did anything: a resume the hold
        # refused stays open, and the timer asks again.
        if ($machineLease) { Close-VmfPutBackJob -Token $jobToken -Why $endWhy }
        # RESTORE-ONE-AT-A-TIME-1: on every exit. Never throws.
        Exit-VmfMachineLease -Token $machineLease
        # Put it back whatever happened, so the next operation in this process
        # starts where it expected to.
        Restore-VmfSubscriptionContext -Context $previousAzContext
    }
}
