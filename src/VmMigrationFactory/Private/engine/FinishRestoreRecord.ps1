# FINISH-NO-RESTORE-RECORD-1: Finish the restore writes the restore's record
# when the restore's job did not.
#
# Restore this machine writes the record of a swap Azure refused (swapPending)
# first, and its own record (restore) with the removal of its checkpoint
# (putBackJob) in a later write. A job killed between the two writes, whose
# resume the service gave up on (RESUME-GIVEUP-KEEP-1), left a swap record and
# a checkpoint marked gaveUp, and no restore record. Finish the restore then
# swapped the disks that were left and started the machine, and:
#   - the machine had no restore record: the panel, the reports and the counts
#     did not say it was restored, nor name the disks it had before;
#   - the checkpoint stayed, so retention kept the safety copies and every disk
#     made for the machine until a later restore finished.
#
# Now the last write of Finish the restore writes the restore's record from
# what the restore saved - its checkpoint (what the person asked for, the
# machine before, the OS disk it put on, what the data disk step did) and the
# swap record (every data disk swapped back, every disk kept) - says that
# Finish wrote it (writtenByFinish), and removes the checkpoint, in the same
# write as it removes the swap record. A restore that wrote its own record
# keeps it, and Finish adds to it as before.
#
# vm-state v32 ties the records together by the restore's engine operation:
# the restore record and the swap record name it (operationId), as the
# checkpoint does. An earlier restore's record on the machine is never taken
# for this restore's. OLD-VERSION-READERS-REMOVE-4: a restore always has a
# checkpoint with an operation id (Restore-VmfVm), so its swap record always
# names it; a swap record that names none matches no record and no
# checkpoint, and Finish says the record of the restore is missing.

function Get-VmfSwapRestoreRecord {
    <#
    .SYNOPSIS
        The record (restore) of the restore that left this machine's swap, or
        $null when the machine has none - also when the record on it is an
        earlier restore's. Pure.
    .DESCRIPTION
        The swap record and the restore record both name the restore's
        operation: the same id is this restore's record. A record that names
        another operation, or none, is not.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $rec = Get-VmfRecordField -Object $Doc -Name 'restore'
    if (-not $rec) { return $null }
    $recOp = [string](Get-VmfRecordField -Object $rec -Name 'operationId')
    $spOp = [string](Get-VmfRecordField -Object (Get-VmfSwapPending -Doc $Doc) -Name 'operationId')
    if ($spOp -and [string]::Equals($recOp, $spOp, [System.StringComparison]::Ordinal)) { return $rec }
    $null
}

function Get-VmfSwapRestoreJob {
    <#
    .SYNOPSIS
        The checkpoint (putBackJob) of the restore that left this machine's
        swap, when it ended - or $null. Pure.
    .DESCRIPTION
        Only a restore's, only one that ended (the service gave up on it, or
        it ended with an answer), and only the one the swap record names.
        Finish refuses a machine whose restore has not ended
        (Get-VmfPutBackJobRefusal), so an open one is never taken here.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    # FINISH-END-JOB-1: also under a finish that stands over it.
    $job = Get-VmfPutBackJobBehind -Doc $Doc
    if (-not $job -or [string]$job.kind -ne 'restore') { return $null }
    if (-not (Get-VmfRecordField -Object $job -Name 'ended')) { return $null }
    $spOp = [string](Get-VmfRecordField -Object (Get-VmfSwapPending -Doc $Doc) -Name 'operationId')
    if (-not $spOp -or -not [string]::Equals($spOp, [string]$job.operationId, [System.StringComparison]::Ordinal)) { return $null }
    $job
}

function New-VmfFinishRestoreRecord {
    <#
    .SYNOPSIS
        The restore record (restore) Finish the restore writes for a restore
        whose job did not write it: from the restore's checkpoint and the
        swap record. $null when there is no checkpoint to write it from. Pure.
    .DESCRIPTION
        Each field is the one the restore writes (Restore-VmfVm's
        $restoreRecord), read from what the restore saved:
          - who asked for it, the note, the copy and the naming: the
            checkpoint (startedBy, note, options);
          - the copy's id: the one the person named, else the safety copy of
            that kind on the machine's record, as the restore chose it;
          - the OS disk before: the checkpoint (before.osDisk), never the
            machine, which runs on the restored disk now;
          - the OS disk now: what the data disk step saved (result), else what
            the OS disk step saved (os); unknown is $null, never a guess;
          - each data disk swapped back: the swap record (swapped), with the
            disk the LUN had from what the data disk step saved, else from the
            checkpoint (before.dataDisks);
          - each data disk kept as it is: the swap record (kept), which every
            swap record holds (OLD-STATE-READERS-FINISH-1; Finish stops before
            any change on one with none).
        -SizeAfter is the size Finish read after it started the machine.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][string]$FinishedBy,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeAfter
    )
    $job = Get-VmfSwapRestoreJob -Doc $Doc
    if (-not $job) { return $null }
    $sp = Get-VmfSwapPending -Doc $Doc
    $opts = Get-VmfRecordField -Object $job -Name 'options'
    $from = [string](Get-VmfRecordField -Object $opts -Name 'from')
    $naming = [string](Get-VmfRecordField -Object $opts -Name 'diskNaming')
    $safety = Get-VmfRecordField -Object $Doc -Name 'safety'
    $copy = [string](Get-VmfRecordField -Object $opts -Name 'snapshotId')
    if (-not $copy) { $copy = [string](Get-VmfRecordField -Object $safety -Name $(if ($from -eq 'pristine') { 'pristineSnapshotId' } else { 'snapshotId' })) }
    $before = Get-VmfRecordField -Object $job -Name 'before'
    $osBefore = Get-VmfRecordField -Object $before -Name 'osDisk'
    $result = Get-VmfRecordField -Object $job -Name 'result'
    $os = Get-VmfRecordField -Object $job -Name 'os'
    $newId = [string](Get-VmfRecordField -Object $result -Name 'newId')
    $newName = [string](Get-VmfRecordField -Object $result -Name 'finalName')
    if (-not $newId) { $newId = [string](Get-VmfRecordField -Object $os -Name 'newId') }
    if (-not $newName) { $newName = [string](Get-VmfRecordField -Object $os -Name 'finalName') }
    $prevId = [string](Get-VmfRecordField -Object $osBefore -Name 'id')
    $prevName = [string](Get-VmfRecordField -Object $osBefore -Name 'name')
    $changed = ($naming -ne 'preserve')
    $data = Get-VmfRecordField -Object $result -Name 'data'

    # The disk each LUN had: what the data disk step replaced, else the
    # machine before the job.
    $had = @{}
    foreach ($d in @(@(Get-VmfRecordField -Object $before -Name 'dataDisks') | Where-Object { $_ })) {
        $had[[int]$d.lun] = @{ id = [string](Get-VmfRecordField -Object $d -Name 'id'); name = [string](Get-VmfRecordField -Object $d -Name 'name') }
    }
    foreach ($r in @(@(Get-VmfRecordField -Object $data -Name 'Replaced') | Where-Object { $_ })) {
        $had[[int]$r.lun] = @{ id = [string]$r.previousDiskId; name = [string]$r.previousDiskName }
    }
    $rows = @{}
    foreach ($r in @(@(Get-VmfRecordField -Object $data -Name 'Replaced') | Where-Object { $_ })) {
        $rows[[int]$r.lun] = [pscustomobject][ordered]@{ lun = [int]$r.lun; previousDiskId = [string]$r.previousDiskId; previousDiskName = [string]$r.previousDiskName
            newDiskId = [string]$r.newDiskId; newDiskName = [string]$r.newDiskName }
    }
    foreach ($s in @(@(Get-VmfRecordField -Object $sp -Name 'swapped') | Where-Object { $_ })) {
        $lun = [int]$s.lun
        $prev = $had[$lun]
        $rows[$lun] = [pscustomobject][ordered]@{ lun = $lun; previousDiskId = $(if ($prev) { [string]$prev.id } else { '' }); previousDiskName = $(if ($prev) { [string]$prev.name } else { '' })
            newDiskId = [string]$s.diskId; newDiskName = [string]$s.diskName }
    }
    $kept = @(Get-VmfRecordField -Object $sp -Name 'kept')
    $now = (Get-Date).ToUniversalTime().ToString('o')
    [ordered]@{
        operationId      = [string]$job.operationId
        restoredUtc      = $now
        restoredBy       = $(if ([string](Get-VmfRecordField -Object $job -Name 'startedBy')) { [string]$job.startedBy } else { $null })
        note             = $(if ([string](Get-VmfRecordField -Object $job -Name 'note')) { [string]$job.note } else { $null })
        fromSnapshotId   = $(if ($copy) { $copy } else { $null })
        fromCopy         = $(if ($from) { $from } else { $null })
        sizeAfter        = $(if ($SizeAfter) { $SizeAfter } else { $null })
        diskNaming       = $(if ($naming) { $naming } else { $null })
        previousDiskId   = $(if ($prevId) { $prevId } else { $null })
        previousDiskName = $(if ($prevName) { $prevName } else { $null })
        newDiskId        = $(if ($newId) { $newId } else { $null })
        newDiskName      = $(if ($newName) { $newName } else { $null })
        diskIdChanged    = $changed
        retainedDiskId   = $(if ($changed -and $prevId) { $prevId } else { $null })
        dataDisks        = @($rows.Keys | Sort-Object | ForEach-Object { $rows[$_] })
        dataDisksKept    = @(@($kept) | Where-Object { $_ } | Sort-Object { [int]$_.lun } | ForEach-Object { [pscustomobject][ordered]@{ lun = [int]$_.lun; name = [string]$_.name; why = [string]$_.why } })
        writtenByFinish  = [pscustomobject][ordered]@{ by = $FinishedBy; utc = $now }
    }
}

function Test-VmfFinishWritesRestoreRecord {
    <#
    .SYNOPSIS
        Will the end of Finish the restore write the restore's record - no
        record of this restore on the machine, and a checkpoint to write it
        from? Pure. Finish reads the size of the machine only then.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    [bool](-not (Get-VmfSwapRestoreRecord -Doc $Doc) -and (Get-VmfSwapRestoreJob -Doc $Doc))
}

function Save-VmfFinishedRestore {
    <#
    .SYNOPSIS
        The write that ends Finish the restore: the swap record goes, the
        restore's record is written when the restore did not write it, and
        the restore's checkpoint goes - in ONE write, so there is never a
        moment with the swap gone and no record of the restore.
    .OUTPUTS
        @{ Wrote = the restore's record was written here; Missing = the
        machine has no record of this restore, and there was nothing to write
        it from }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$FinishedBy,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeAfter,
        # FINISH-END-JOB-1: the finish's own checkpoint. It ends in this write:
        # the record it stood over (prior) is back first, and the rule below
        # then ends it or keeps it.
        [Parameter()][AllowNull()]$FinishToken,
        # VOLUMES-ONLINE-FINISH-1: the verdict of the check of the volumes
        # after the finish started the machine - the record a checked retry
        # reads (volumesCheckOwed) is written in this same write.
        [Parameter()][AllowEmptyString()][AllowNull()][string]$VolumesVerdict
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    Remove-VmfFinishJobOnDoc -Doc $doc -Token $FinishToken
    Set-VmfVolumesCheckOwed -Doc $doc -Verdict $VolumesVerdict -Kind 'restore'
    $out = @{ Wrote = $false; Missing = $false }
    if (-not (Get-VmfSwapRestoreRecord -Doc $doc)) {
        $rec = New-VmfFinishRestoreRecord -Doc $doc -FinishedBy $FinishedBy -SizeAfter $SizeAfter
        if ($rec) {
            $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]$rec) -Force
            $out.Wrote = $true
        }
        else { $out.Missing = $true }
    }
    # RESUME-GIVEUP-KEEP-1: the hold of a restore the service gave up on ends
    # when a restore of the machine finishes - and this one has.
    if (Get-VmfSwapRestoreJob -Doc $doc) { $doc.PSObject.Properties.Remove('putBackJob') }
    if ($doc.PSObject.Properties['swapPending']) { $doc.PSObject.Properties.Remove('swapPending') }
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    $out
}
