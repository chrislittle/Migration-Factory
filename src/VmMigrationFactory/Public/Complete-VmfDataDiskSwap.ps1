function Complete-VmfDataDiskSwap {
    <#
    .SYNOPSIS
        SWAP-REFUSED-AFTER-STOP-1: Finish the rollback, or Finish the restore -
        swap the data disks a refused swap left, then start the machine.
    .DESCRIPTION
        A rollback or a restore whose data-disk swap Azure refused, also when
        it was tried again, leaves the machine STOPPED with every disk it needs
        already made: its record (swapPending) names each LUN, the disk still
        on it, and the disk made from its copy that waits to go on. This swaps
        ONLY those disks - never one that is back already - and then starts the
        machine. It never makes a disk and never deletes one.

        Checkpointed and safe to run again (rule 4):
          - every LUN Azure took is on record the moment it took, so a job that
            stops part way leaves only the LUNs that are still left;
          - a LUN that already holds the disk made from its copy is recorded,
            not swapped again (Azure took it, and the job stopped before the
            record said so);
          - with every disk on, a second run only starts the machine.
        A LUN that holds a disk which is neither the one it had nor the one
        made from its copy is refused before anything changes: somebody
        changed the machine, and the product does not guess. A LUN with no
        disk gets the disk that waits only with the proof the restore's resume
        gives it (Test-VmfEmptyLunWant): it exists, no machine holds it, and
        Azure made it from the copy the record names (FINISH-EMPTY-LUN-PROOF-1).

        Still refused: the machine stays stopped, the record keeps every disk
        left with Azure's new words, and the error says so. A rollback ends
        with the stop it would have recorded (kept on swapPending.stop); a
        restore adds each disk to its record.
    .PARAMETER FinishedBy
        Who asked for it - on the start line, as a restore records RestoredBy.
    .PARAMETER CorrelationId
        The engine operation's id (RESTORE-END-LOST-1): on the start line, and
        the name the job holds the machine under.
    .PARAMETER Resume
        FINISH-END-JOB-1: start again the finish with the id -CorrelationId,
        whose job stopped part way. Who asked for it and why come from its
        checkpoint (putBackJob, kind finish), never from the call. The
        service's timer starts it (Invoke-VmfFacadeResumeStalledPutBacks).
    .EXAMPLE
        Complete-VmfDataDiskSwap -RunPath .\run1 -VmId $vmId -FinishedBy 'lead@contoso.com' -Note 'Azure accepts the swap now'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string]$FinishedBy = 'unknown',
        [Parameter()][AllowEmptyString()][string]$Note = '',
        [Parameter()][string]$CorrelationId,
        [Parameter()][switch]$Resume
    )

    # VMID-CASE-1: the ID as this run's record spells it.
    $VmId = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { throw "No record of '$VmId' in this run." }
    $vmName = ($VmId -split '/')[-1]
    # FINISH-END-JOB-1: a resume is the SAME finish - who asked for it and why
    # come from its checkpoint, never from the call that started it again (the
    # record Finish the restore writes names who asked for it).
    $jobToken = $null
    if ($Resume) {
        $jobToken = Get-VmfPutBackJobToken -RunPath $RunPath -VmId $VmId -Kind 'finish' -OperationId $CorrelationId
        $FinishedBy = [string]$jobToken.Job.startedBy
        $Note = [string]$jobToken.Job.note
    }
    else {
        # RESTORE-END-JOB-1: a restore whose job stopped resumes by itself and
        # writes its own record; a finish over it would swap disks the resume then
        # records as left again. FINISH-END-JOB-1: and so does a finish.
        $jobRefusal = Get-VmfPutBackJobRefusal -Doc $doc -VmName $vmName
        if ($jobRefusal) { throw $jobRefusal }
    }
    $sp = Get-VmfSwapPending -Doc $doc
    if (-not $sp -and -not $Resume) { throw "Nothing is left to finish on '$vmName': its record names no data disk swap that is left." }
    $kind = if ($sp) { if ([string]$sp.kind -eq 'restore') { 'restore' } else { 'rollback' } }
            elseif ([string]$jobToken.Job.options.finishes -eq 'restore') { 'restore' } else { 'rollback' }
    $action = Get-VmfFinishActionName -Kind $kind
    # A rollback whose stop is not recorded yet is still a wave worker's.
    if ($sp -and $kind -eq 'rollback' -and -not (Get-VmfRecordField -Object $sp -Name 'stop')) {
        throw "The rollback of '$vmName' has not recorded its stop yet. Wait until its wave ends, then use $action."
    }
    $leftNow = @(if ($sp) { @($sp.swaps) | Where-Object { $_ } })
    # Re-check: Finish starts the machine, so its record must account for every
    # data disk the machine had - back from the copy, waiting, or left by
    # design on the rollback's or the restore's own record. A LUN in no list is
    # one the product cannot prove is back: refused, and nothing changes.
    # FINISH-KEPT-DISKS-1: the swap record names the kept disks too, written
    # with the swaps (New-VmfSwapPendingRecord, every caller) - a job killed
    # before its own record still leaves a record that accounts for them.
    # OLD-STATE-READERS-FINISH-1: a swap record with no list of kept disks is
    # no record this version writes, and stops here, before anything changes.
    if ($sp -and -not ($sp.PSObject.Properties['kept'] -or ($sp -is [System.Collections.IDictionary] -and $sp.Contains('kept')))) {
        throw "The record of the data disk swap of '$vmName' does not list the data disks it keeps, so $action does not change the machine."
    }
    $keptRec = @(Get-VmfRecordField -Object $sp -Name 'kept')
    $accounted = @(@($leftNow) + @(Get-VmfRecordField -Object $sp -Name 'swapped') + $keptRec | Where-Object { $_ } | ForEach-Object { [int]$_.lun })
    $unaccounted = @(if ($sp) { @($doc.captured.vmConfig.dataDisks) | Where-Object { $_ -and [int]$_.lun -notin $accounted } })
    if ($unaccounted.Count) {
        throw "The record of '$vmName' does not say where these data disks stand: $(@($unaccounted | ForEach-Object { "LUN $($_.lun) '$($_.name)'" }) -join ', '). The product cannot prove they are back, so $action does not change the machine."
    }
    $what = if ($leftNow.Count) { "swap the data disks that are left ($(Format-VmfSwapLeft -Swaps $leftNow)), then start the machine" } else { 'start the machine: every data disk is back' }
    if (-not $PSCmdlet.ShouldProcess($vmName, "$action - $what")) { return }

    # SEC-1 / F10: every call below addresses the machine in ITS subscription.
    $subscriptionId = Assert-VmfResourceId -ResourceId $VmId -Kind 'virtual machine'
    $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $subscriptionId
    $machineLease = $null
    try {
        # RESTORE-ONE-AT-A-TIME-1: one job changes a machine at a time - this
        # one holds it the way a restore does.
        $machineLease = Enter-VmfMachineLease -RunPath $RunPath -VmId $VmId -Holder (Get-VmfMachineLeaseHolder -Kind 'restore' -CorrelationId $CorrelationId)
        $rg = ($VmId -split '/')[4]
        $context = [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Rg = $rg }
        if ($Resume) {
            # FINISH-END-JOB-1: the same finish, started again. Not a start
            # line: the page keeps the finish open on its first one, and this
            # line keeps it current.
            Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome info -VmId $VmId `
                -Detail "$action started again after its job stopped. It swaps only the data disks that are left, then starts the machine."
        }
        else {
            # FINISH-END-JOB-1 (rule 4): the checkpoint, before the start line
            # and before anything is asked of Azure. If it cannot be written,
            # the finish stops here, and nothing has changed. The record of an
            # earlier restore on the machine (one that ended - an
            # open one refuses the finish above) goes inside it as prior,
            # whole: what that restore read of the machine (the caching an
            # empty LUN takes, Get-VmfEmptyLunSettings), its hold, and what
            # Finish the restore writes its record from (FINISH-NO-RESTORE-RECORD-1).
            # Every end of the finish puts it back, or ends it by the rule of
            # Save-VmfFinishedRestore.
            $jobToken = New-VmfPutBackJob -RunPath $RunPath -VmId $VmId -Kind 'finish' -OperationId $(if ($CorrelationId) { $CorrelationId } else { [guid]::NewGuid().ToString() }) `
                -StartedBy $FinishedBy -Note $Note -Options @{ finishes = $kind } -Stamp ((Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm'))
            Write-VmfEvent -RunPath $RunPath -Step 'finish' -Outcome start -VmId $VmId -CorrelationId $CorrelationId `
                -Detail "$action, by $FinishedBy$(if ($Note) { ": $Note" })"
        }
        # Read again under the hold: another job may have finished it.
        $sp = Get-VmfSwapPending -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId)
        if (-not $sp) {
            # FINISH-END-JOB-1: the checkpoint ends with it.
            $endDoc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
            Remove-VmfFinishJobOnDoc -Doc $endDoc -Token $jobToken
            Write-VmfStateDoc -RunPath $RunPath -Document $endDoc
            Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome ok -VmId $VmId -Detail "Nothing is left to finish on '$vmName'. Another job finished it."
            return [pscustomobject]@{ VmId = $VmId; Kind = $kind; Swapped = @(); Started = $false }
        }
        $finished = [System.Collections.Generic.List[object]]::new()
        $powerBack = $null
        $volumes = $null
        $lostWords = ''
        try {
            $left = @(@($sp.swaps) | Where-Object { $_ })
            if ($left.Count) {
                # Every LUN is read, and judged, before anything changes.
                $live = @(Invoke-VmfAzOperation -Name "${kind}:dataDiskInfo" -RunPath $RunPath -VmId $VmId -Operation {
                        @(Get-VmfDataDiskInfo -ResourceGroupName $rg -Name $vmName)
                    })
                $todo = [System.Collections.Generic.List[object]]::new()
                $already = [System.Collections.Generic.List[object]]::new()
                $empties = [System.Collections.Generic.List[object]]::new()
                foreach ($s in $left) {
                    $now = @($live) | Where-Object { $_ -and [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                    $nowId = if ($now) { [string]$now.id } else { '' }
                    if ($nowId -and $nowId -ieq [string]$s.diskId) { $already.Add($s); continue }
                    # Review note c: only the disk the record names - a row with none is refused.
                    if ($nowId -and [string]$s.oldDiskId -and $nowId -ieq [string]$s.oldDiskId) { $todo.Add($s); continue }
                    # RESTORE-EMPTY-LUN-1: a LUN with NO disk - a swap stopped
                    # between its two updates. The disk the record names for it
                    # goes on only when the record proves it; judged here,
                    # before anything changes. FINISH-EMPTY-LUN-PROOF-1: the
                    # proof the restore's resume gives (Test-VmfEmptyLunWant) -
                    # it exists, no machine holds it, and Azure made it from
                    # the copy the record names (vm-state v28).
                    if (-not $nowId -and [string]$s.diskId) {
                        $notThis = Test-VmfEmptyLunWant -Context $context -ReadOpName "${kind}:readDataDisk" -Lun ([int]$s.lun) -HadName ([string]$s.name) `
                            -Want @{ id = [string]$s.diskId; name = [string]$s.diskName; snapshotId = [string](Get-VmfRecordField -Object $s -Name 'snapshotId') }
                        if ($notThis) {
                            $cannot = [System.InvalidOperationException]::new("$(([string]$notThis.Why).TrimEnd('.')). Nothing is changed: the machine is as it was before $action.")
                            $cannot.Data['vmfFinishSaid'] = $true
                            throw $cannot
                        }
                        $empties.Add($s); continue
                    }
                    $holds = if ($nowId) { "the disk '$([string]$now.name)' ($nowId)" } else { 'no disk' }
                    $changed = [System.InvalidOperationException]::new("LUN $($s.lun) of '$vmName' holds $holds - not the disk it had, '$($s.name)', nor the disk '$($s.diskName)' made from its copy. Somebody changed the machine, so the product swaps nothing. The machine is as it was before $action.")
                    $changed.Data['vmfFinishSaid'] = $true
                    throw $changed
                }
                # Azure took these before a job that stopped could say so.
                if ($already.Count) {
                    Add-VmfSwapFinished -RunPath $RunPath -VmId $VmId -Rows @($already)
                    foreach ($s in $already) { $finished.Add($s) }
                }
                if ($todo.Count -or $empties.Count) {
                    Invoke-VmfAzOperation -Name "${kind}:stop" -RunPath $RunPath -VmId $VmId -Operation {
                        Stop-VmfVmDeallocated -ResourceGroupName $rg -Name $vmName
                    } | Out-Null
                }
                $still = [System.Collections.Generic.List[object]]::new()
                $stillEmpty = [System.Collections.Generic.List[int]]::new()
                $reason = ''
                # FINISH-EMPTY-LUN-WORDS-1: a LUN whose disk the record did not
                # prove at the attach - Azure was not asked for it, so it is said
                # by its own words, never as a swap Azure refused 3 times.
                $unproven = [System.Collections.Generic.List[object]]::new()
                # FINISH-ATTACH-UNKNOWN-WORDS-1: and a LUN whose attach stopped
                # with an error that is not a refusal - Azure did not refuse it,
                # and which disk is on it now is not known (notRead).
                $unknownLuns = [System.Collections.Generic.List[int]]::new()
                $azureSaid = ''
                # RESTORE-EMPTY-LUN-1: each LUN with no disk first, on the stopped
                # machine, with the settings the record holds for it. Refused,
                # the disk it had goes back on it (Invoke-VmfEmptyLunAttach).
                foreach ($s in $empties) {
                    # ROLLBACK-EMPTY-LUN-1: a rollback's LUN takes the capture's
                    # settings - a putBackJob is an earlier restore's.
                    $settings = Get-VmfEmptyLunSettings -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId) -Lun ([int]$s.lun) -Caching ([string]$s.caching) -Rollback:($kind -eq 'rollback')
                    # FINISH-EMPTY-LUN-PROOF-1: the copy the record names. A row
                    # that names none was refused above, before any change.
                    $copy = [string](Get-VmfRecordField -Object $s -Name 'snapshotId')
                    $put = Invoke-VmfEmptyLunAttach -Context $context -VmName $vmName -OpName "${kind}:swapDataDisks" -ReadOpName "${kind}:readDataDisk" -Lun ([int]$s.lun) `
                        -Want @{ id = [string]$s.diskId; name = [string]$s.diskName; snapshotId = $copy } `
                        -Fallback $(if ([string]$s.oldDiskId) { @{ id = [string]$s.oldDiskId; name = [string]$s.name } } else { $null }) -Settings $settings
                    if ($put.Outcome -eq 'want') {
                        # On record the moment Azure took it (rule 4).
                        Add-VmfSwapFinished -RunPath $RunPath -VmId $VmId -Rows @($s)
                        $finished.Add($s)
                        Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome info -VmId $VmId `
                            -Detail "LUN $($s.lun) had no disk. The disk '$($s.diskName)' made from its copy is on it now."
                        continue
                    }
                    $ownWords = $put.Outcome -eq 'unproven' -or [bool]$put.Unknown
                    $reason = if ($ownWords) { [string]$put.Why } else { [string]$put.Reason }
                    if ($put.Unknown) { $unknownLuns.Add([int]$s.lun) }
                    elseif ($put.Outcome -ne 'fallback') { $stillEmpty.Add([int]$s.lun) }
                    if ($ownWords) { $unproven.Add([pscustomobject]@{ Row = $s; Why = [string]$put.Why }) }
                    else { $azureSaid = [string]$put.Reason }
                    $still.Add($s)
                }
                # SAFETY-ULTRA-1: every other disk first, then Premium SSD v2
                # and Ultra Disk, so one refusal of those keeps no other back.
                foreach ($batch in @(Get-VmfSwapBatches -Swaps @($todo))) {
                    $part = @($batch.Swaps)
                    $swapped = Invoke-VmfDataDiskSwap -Context $context -VmName $vmName -OpName "${kind}:swapDataDisks" -Swaps $part
                    if ($swapped.Applied) {
                        # On record the moment Azure took it (rule 4).
                        Add-VmfSwapFinished -RunPath $RunPath -VmId $VmId -Rows $part
                        foreach ($s in $part) { $finished.Add($s) }
                        Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome info -VmId $VmId `
                            -Detail "The data disks are swapped back: $(@($part | ForEach-Object { "LUN $($_.lun) now uses '$($_.diskName)'" }) -join ', ')."
                    }
                    else {
                        $reason = [string]$swapped.Reason
                        $azureSaid = $reason
                        foreach ($s in $part) { $still.Add($s) }
                    }
                }
                if ($still.Count) {
                    $rec = Get-VmfSwapPending -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId)
                    $rec.error = $reason
                    # FINISH-EMPTY-LUN-WORDS-1: each row says what is on its LUN
                    # now - no disk, or the disk it had (put back, or never taken
                    # off). Finish read every LUN before it changed anything.
                    foreach ($s in @($rec.swaps)) {
                        $s | Add-Member -NotePropertyName why -NotePropertyValue $reason -Force
                        $s | Add-Member -NotePropertyName lunHolds -NotePropertyValue $(if ([int]$s.lun -in $stillEmpty) { 'none' } elseif ([int]$s.lun -in $unknownLuns) { 'notRead' } else { 'had' }) -Force
                    }
                    Set-VmfSwapPending -RunPath $RunPath -VmId $VmId -Record $rec
                    $unprovenLuns = @($unproven | ForEach-Object { [int]$_.Row.lun })
                    $askedRows = @($still | Where-Object { [int]$_.lun -notin $unprovenLuns })
                    $stillParts = [System.Collections.Generic.List[string]]::new()
                    foreach ($u in $unproven) { $stillParts.Add(([string]$u.Why).TrimEnd('.') + '.') }
                    if ($askedRows.Count) {
                        $stillParts.Add("Azure did not swap these data disks back after $script:VmfSwapRefusedTries tries: $(Format-VmfSwapLeft -Swaps @($askedRows) -EmptyLuns @($stillEmpty)). Azure said: $($azureSaid.TrimEnd('.')).")
                    }
                    # FINISH-ATTACH-UNKNOWN-WORDS-1: a LUN whose attach had no
                    # answer is read again by the next finish, before any change.
                    $useAgain = if ($askedRows.Count) { " Use $action again when Azure accepts the swap." } elseif ($unknownLuns.Count) { " Use $action again." } else { '' }
                    $readFirst = if ($unknownLuns.Count) { ' It reads each LUN before it changes the machine.' } else { '' }
                    $stillWords = "$($stillParts -join ' ') The machine stays stopped, so it never starts with disks from two moments.$useAgain$readFirst"
                    $refused = [System.InvalidOperationException]::new($stillWords)
                    $refused.Data['vmfFinishSaid'] = $true
                    throw $refused
                }
            }
            # FINISH-END-JOB-1 (rule 4): every data disk is back, and the
            # machine starts once - a resume after this step was saved does
            # not start it again.
            Save-VmfPutBackJobStep -Token $jobToken -Phase 'dataSwapped'
            if (-not (Test-VmfPutBackJobPast -Job $jobToken.Job -Phase 'started')) {
                Invoke-VmfAzOperation -Name "${kind}:start" -RunPath $RunPath -VmId $VmId -Operation {
                    Start-VmfVm -ResourceGroupName $rg -Name $vmName
                } | Out-Null
                Save-VmfPutBackJobStep -Token $jobToken -Phase 'started'
            }
            if ($kind -eq 'restore') {
                Invoke-VmfAzOperation -Name 'restore:agentReady' -RunPath $RunPath -VmId $VmId -Operation {
                    Wait-VmfVmAgentReady -ResourceGroupName $rg -Name $vmName
                } | Out-Null
            }
            # VOLUMES-ONLINE-FINISH-1: the machine now runs on disks made from
            # the safety copies, with new device IDs - the check of the
            # rollback and the restore (VOLUMES-ONLINE-1), while it runs and
            # before it returns to its power state. On the finish's checkpoint
            # first (putBackJob.volumes), so a resume after the return uses it
            # and never asks a stopped machine.
            $volumes = Get-VmfFinishVolumesCheck -RunPath $RunPath -VmId $VmId -ResourceGroupName $rg -VmName $vmName -Kind $kind -Token $jobToken
            # POWER-AFTER-MOVE-1 (since 2026-11-06, the machine ends in its
            # original power state, on or off): every disk is back and
            # the machine started; now it goes back to its power state. The
            # machine is stopped when a finish starts - the swap that is left
            # keeps it so - so the finish never reads its own start: Finish the
            # rollback ends the automatic rollback, and returns the power state
            # Checking found; Finish the restore ends the restore, and returns
            # the power state the restore found when it started
            # (swapPending.powerAtStart). A resume past 'started' comes here
            # again, and a return to the power state the machine has does
            # nothing.
            $powerBack = if ($kind -eq 'rollback') { Invoke-VmfJobPowerReturn -RunPath $RunPath -VmId $VmId -Step 'finish' -AtMove }
                         else { Invoke-VmfJobPowerReturn -RunPath $RunPath -VmId $VmId -Step 'finish' -Power ([string](Get-VmfRecordField -Object $sp -Name 'powerAtStart')) -Before 'the restore' }
        }
        catch {
            # Every disk that went back is on record already. The line ends the
            # page's "finishing", and the record says what is left.
            $why = $_.Exception.Message
            $more = if ($_.Exception.Data['vmfFinishSaid']) { '' } else { " Every data disk that is back is on the machine's record. Use $action again." }
            Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome fail -VmId $VmId -Detail "$action did not finish: $why$more"
            throw "$action did not finish: $why$more"
        }

        # The machine runs on every disk from the copy. The record says so in
        # one write, and the swap record goes in the same write.
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
        $sp = Get-VmfSwapPending -Doc $doc
        $done = @(@($sp.swapped) | Where-Object { $_ } | Sort-Object { [int]$_.lun } | ForEach-Object { "LUN $($_.lun) '$($_.diskName)'" })
        $doneWords = "$action swapped the data disks that were left and started the machine. The data disks from the safety copy: $($done -join ', ').$(if ($powerBack) { " $($powerBack.Words)" })"
        # Keeping the names, a LUN Azure refused runs on its temporary disk -
        # the copy's moment - and the disk it had keeps its name, not attached.
        foreach ($tmp in @($finished | Where-Object { [bool](Get-VmfRecordField -Object $_ -Name 'temporary') })) {
            $doneWords += " LUN $($tmp.lun) runs on the temporary disk '$($tmp.diskName)', made from the copy. The disk '$($tmp.name)' it had is kept, and is not attached."
        }
        # FINISH-TEMP-DISK-LEFT-1: keeping the names, a LUN that ran on its
        # temporary disk now has the disk under its old name. The temporary
        # disk is free: no record names it as a disk the machine has (Add-
        # VmfSwapFinished), so the daily cleanup deletes it, as it deletes a
        # temporary disk step 7 could not (Get-VmfDeletableMadeDisks).
        foreach ($tmp in @($finished | Where-Object { [bool](Get-VmfRecordField -Object $_ -Name 'oldTemporary') })) {
            $doneWords += " The temporary disk '$($tmp.name)' that LUN $($tmp.lun) ran on is not attached. It costs money until it is deleted. The daily cleanup deletes it when the move of this machine has ended."
        }
        if ($kind -eq 'rollback') {
            # Review MUST FIX 2: what a rollback that failed after its swaps
            # could not do. Both are safe to repeat.
            Clear-VmfRetryState -RunPath $RunPath -VmId $VmId -From 'PRECHECK'
            Complete-VmfKernelUpdatePutBack -RunPath $RunPath -VmId $VmId
            $stop = Get-VmfRecordField -Object $sp -Name 'stop'
            # POWER-AFTER-MOVE-1: a return Azure refused at every try makes the
            # stop changed, with the power state owed.
            $owed = @{ MachineState = [string]$stop.machineState }
            if ($powerBack -and -not $powerBack.Ok) { $owed = @{ MachineState = 'changed'; PowerNotPutBack = $powerBack.PowerNotPutBack } }
            # VOLUMES-ONLINE-FINISH-1: a volume that was mounted before the
            # move and is not mounted now is a machine NOT as it was - the
            # stop volumesNotBack, changed, in place of the stop the rollback
            # kept (as Complete-VmfRollback records it). A check that could
            # not run is said in the stop, which stays the rollback.
            $endState = [string]$stop.state; $endCode = [string]$stop.reasonCode; $endDetail = "$([string]$stop.detail) $doneWords"
            $verdict = if ($volumes) { [string]$volumes.verdict } else { '' }
            if ($verdict -eq 'MISSING') {
                $endState = 'FAILED_NEEDS_ATTENTION'; $endCode = 'volumesNotBack'; $owed.MachineState = 'changed'
                $endDetail = "$endDetail $([string]$volumes.words)"
            }
            elseif ($verdict -eq 'UNKNOWN') { $endDetail = "$endDetail $([string]$volumes.words)" }
            # FINISH-END-JOB-1: the checkpoint ends in the same write.
            # VOLUMES-RETRY-CHECK-1: and the record a checked retry reads, in
            # the same write as the stop.
            Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState $endState -Outcome fail -ReasonCode $endCode `
                -Detail $endDetail -ClearProperty @('swapPending') `
                -Amend { param($d) Remove-VmfFinishJobOnDoc -Doc $d -Token $jobToken; Set-VmfVolumesCheckOwed -Doc $d -Verdict $verdict -Kind 'rollback' } @owed | Out-Null
        }
        else {
            # FINISH-NO-RESTORE-RECORD-1: a restore whose job stopped before it
            # wrote its record, and that the service stopped starting again,
            # gets its record here, from what it saved - with the size read now
            # that the machine runs. A size Azure does not give is unknown,
            # never a reason to leave the machine with no record.
            $sizeNow = $null
            if (Test-VmfFinishWritesRestoreRecord -Doc $doc) {
                try {
                    $sizeNow = [string](Invoke-VmfAzOperation -Name 'restore:sizeAfter' -RunPath $RunPath -VmId $VmId -Operation {
                            Get-VmfVmSize -ResourceGroupName $rg -Name $vmName
                        })
                }
                catch { $sizeNow = $null }
            }
            # The swap record, the restore's record and its checkpoint, in one write.
            # FINISH-END-JOB-1: and the finish's own checkpoint, with the record it
            # stood over (prior) put back or ended by the same rule.
            # VOLUMES-RETRY-CHECK-1: the record a checked retry reads goes in
            # the same write as the end of the restore.
            $saved = Save-VmfFinishedRestore -RunPath $RunPath -VmId $VmId -FinishedBy $FinishedBy -SizeAfter $sizeNow -FinishToken $jobToken `
                -VolumesVerdict $(if ($volumes) { [string]$volumes.verdict } else { '' })
            if ($saved.Wrote) {
                $doneWords += " The job of the restore stopped before it wrote its record, so $action wrote the record of the restore from what the restore saved."
            }
            elseif ($saved.Missing) {
                $doneWords += " The machine's record does not hold the record of this restore, and the product did not save what it needs to write it."
            }
            # POWER-AFTER-MOVE-1: a return Azure refused at every try is owed,
            # after the record of the restore.
            if ($powerBack -and -not $powerBack.Ok) {
                $stateNow = [string](Read-VmfStateDoc -RunPath $RunPath -VmId $VmId).state
                Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState $stateNow -Outcome fail -MachineState 'changed' `
                    -PowerNotPutBack $powerBack.PowerNotPutBack -Detail $powerBack.Words | Out-Null
            }
            # VOLUMES-ONLINE-FINISH-1: a volume not mounted - after the record,
            # as Restore this machine does: the machine is changed.
            if ($volumes -and [string]$volumes.verdict -eq 'MISSING') {
                $lostWords = "$action swapped the other data disks. $([string]$volumes.words)"
                $stateNow = [string](Read-VmfStateDoc -RunPath $RunPath -VmId $VmId).state
                Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState $stateNow -Outcome fail -MachineState 'changed' -ReasonCode 'volumesNotBack' `
                    -Detail $lostWords | Out-Null
            }
        }
        if ($volumes -and [string]$volumes.words) { $doneWords += " $([string]$volumes.words)" }
        # SKIP-CHANGED-FREED-1: a machine left out while a swap was left kept
        # its claim in this run. With no swap left, the settled-claim rule
        # decides from the record: a restore that ends here releases it, and a
        # rollback that ends here is back at its stop, which keeps it.
        try { Remove-VmfSettledVmClaim -RunPath $RunPath -VmId $VmId | Out-Null }
        catch { Write-Warning "The claim of '$vmName' was not released: $($_.Exception.Message)" }
        # VOLUMES-ONLINE-FINISH-1: a restore that did not bring every volume
        # back ends as Restore this machine does - a warn line, then the error.
        if ($kind -eq 'restore' -and $lostWords) {
            Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome warn -VmId $VmId -Detail $doneWords
            throw $lostWords
        }
        Write-VmfStepLine -RunPath $RunPath -Step 'finish' -Outcome ok -VmId $VmId -Detail $doneWords
        [pscustomobject]@{ VmId = $VmId; Kind = $kind; Swapped = @($finished | ForEach-Object { [pscustomobject]@{ lun = [int]$_.lun; diskName = [string]$_.diskName } }); Started = $true }
    }
    finally {
        # FINISH-END-JOB-1: a finish that ends here with its checkpoint still
        # on the record ended with an answer it said - never resumed. Only a
        # job that held the machine did anything: a resume the hold refused
        # stays open, and the timer asks again. Never throws.
        if ($machineLease) { Close-VmfPutBackJob -Token $jobToken }
        Exit-VmfMachineLease -Token $machineLease
        Restore-VmfSubscriptionContext -Context $previousAzContext
    }
}
