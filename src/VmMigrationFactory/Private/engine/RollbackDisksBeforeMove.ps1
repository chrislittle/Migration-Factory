# ROLLBACK-DISKS-FIRST-1, reworked by the decision of 2026-10-11: a put-back
# must never be blocked, and it must be 100% safe.
#
# The first build made every disk from its copy at the START of each put-back,
# before it stopped the machine. That moved a refusal to a better moment, but a
# put-back still depended on Azure accepting a new disk request at put-back
# time - quota, a policy, a key, a region short of capacity - which is exactly
# when things are already wrong. So the rollback is BUILT before the move
# changes anything:
#
#   - SAFETY_PRISTINE, once the first copies are taken and usable (SAFETY-ULTRA-1
#     waits for them), makes a disk from each - the OS disk and every data disk
#     a put-back restores, with the type, size, zone, IOPS, throughput, sector
#     size and key the read-backs require - and reads each one back. Before
#     guest prep, accelerated networking or the size change anything.
#   - A disk Azure refuses, or one that differs, stops the move with the
#     machine as it was. The disks already made are deleted, or named when a
#     delete fails - never left billing on no record.
#   - Every put-back from the first copy (the Path A, Path B and disks-only
#     rollbacks, Restore this machine) only swaps these disks in. The disks are
#     read once more before the stop; a put-back that finds one gone, or on
#     another machine, makes its disks as before (New-VmfRollbackDisksDuringRollback) - the
#     fallback, also before the stop.
#   - A move that completes deletes the ones nothing used. Retention deletes
#     the rest once the machine's move has ended (Get-VmfDueRollbackDisksBeforeMove).
#
# Each disk exists twice for the length of the move: its own, and the one made
# for the rollback. That is the price of a put-back that asks Azure for nothing
# new.

function Get-VmfRollbackDisksBeforeMoveRecord {
    <#
    .SYNOPSIS
        The rollback disks of THIS attempt (safety.rollbackDisksBeforeMove),
        or $null. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'safety') -Name 'rollbackDisksBeforeMove'
}

function Set-VmfRollbackDisksBeforeMoveRecord {
    <#
    .SYNOPSIS
        Write this attempt's record of the rollback disks.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId, [Parameter(Mandatory)]$Record)
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $safety = if ($doc.PSObject.Properties['safety'] -and $doc.safety) { $doc.safety } else { [pscustomobject]@{ snapshotId = $null; cloneVmId = $null } }
    $safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue $Record -Force
    $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}

function Add-VmfRollbackDisksBeforeMoveEntry {
    <#
    .SYNOPSIS
        Put one disk on the record the moment Azure made it - also one that
        differs, which bills like any other. Merged by disk id, so a resume
        that gets the same disk back writes it once.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][hashtable]$Entry)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $rec = Get-VmfRollbackDisksBeforeMoveRecord -Doc $doc
    if (-not $rec) { return }
    $list = @(@(Get-VmfRecordField -Object $rec -Name 'disks') | Where-Object { $_ })
    $same = @($list | Where-Object { [string]$_.diskId -eq [string]$Entry.diskId }) | Select-Object -First 1
    if ($same) {
        # Made again under a name this record once deleted (the step ran
        # again after a refusal's cleanup): it exists, and bills, again.
        if ([string]$same.deletedUtc) {
            $same | Add-Member -NotePropertyName deletedUtc -NotePropertyValue $null -Force
            Set-VmfRollbackDisksBeforeMoveRecord -RunPath $Context.RunPath -VmId $Context.VmId -Record $rec
        }
        return
    }
    $row = [ordered]@{
        lun = $(if ($null -ne $Entry.lun) { [int]$Entry.lun } else { $null })
        name = [string]$Entry.name; diskId = [string]$Entry.diskId; diskName = [string]$Entry.diskName
        snapshotId = [string]$Entry.snapshotId; skuName = [string]$Entry.skuName
        instantAccess = [bool]$Entry.instantAccess
        madeUtc = (Get-Date).ToUniversalTime().ToString('o'); usedUtc = $null; deletedUtc = $null
    }
    $rec | Add-Member -NotePropertyName disks -NotePropertyValue @($list + @([pscustomobject]$row)) -Force
    Set-VmfRollbackDisksBeforeMoveRecord -RunPath $Context.RunPath -VmId $Context.VmId -Record $rec
}

function New-VmfRollbackDisksBeforeMove {
    <#
    .SYNOPSIS
        Make the disks a put-back swaps in, from the first safety copies,
        BEFORE the move changes anything. Called at the end of SAFETY_PRISTINE.
    .DESCRIPTION
        Idempotent and checkpointed: the time in every name is written before
        the first disk is made, so a worker that stops part way resumes with
        the same names, and New-VmfDiskFromSnapshot returns the disk it made
        (same copy, zone and key) - never a second one. A complete record
        returns at once.

        The OS disk on the type of the first capture (the type a full rollback
        puts back), in the machine's zone, with the key of the disk its copy
        was taken of, read back (New-VmfOsDiskFromCopy). Each data disk by
        Get-VmfDataRestorePlan's rules, made and read back by
        New-VmfDataDiskFromCopy (SAFETY-ULTRA-1, SAFETY-CMK-1). A shared disk
        is left, as every put-back leaves it. Any other disk the put-back
        could not restore - one the plan keeps, one Azure refuses, one that
        differs, a share count that cannot be read - stops the move.
    .OUTPUTS
        $null when every disk is made, or the stop: FAILED_NEEDS_ATTENTION,
        rollbackDisksBeforeMoveNotMade, untouched (or changed, when the machine could not
        be started again).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context)

    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $pristineId = [string](Get-VmfRecordField -Object $doc.safety -Name 'pristineSnapshotId')
    $rec = Get-VmfRollbackDisksBeforeMoveRecord -Doc $doc
    if ($rec -and $rec.complete -and [string]$rec.pristineSnapshotId -eq $pristineId) { return $null }

    $capture = Get-VmfPutBackCapture -Doc $doc
    $attempt = $doc.captured.vmConfig
    $zone = Get-VmfMachineZone -Machine $capture
    $location = [string]$attempt.location
    if (-not $rec -or [string]$rec.pristineSnapshotId -ne $pristineId) {
        # The checkpoint, before the first disk: its time is in every name.
        $rec = [pscustomobject][ordered]@{
            stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm')
            pristineSnapshotId = $pristineId
            zone = $(if ($zone) { $zone } else { $null })
            complete = $false
            disks = @()
            kept = @()
        }
        Set-VmfRollbackDisksBeforeMoveRecord -RunPath $Context.RunPath -VmId $Context.VmId -Record $rec
    }
    $stamp = [string]$rec.stamp

    $refusal = $null
    $kept = [System.Collections.Generic.List[object]]::new()
    try {
        if (-not $pristineId) { throw 'No first safety copy is on record.' }
        $osEntry = $attempt.osDisk
        $osSku = if ($capture.osDisk -and [string]$capture.osDisk.skuName) { [string]$capture.osDisk.skuName } else { [string]$osEntry.skuName }
        $osName = Get-VmfBoundedDiskName -BaseName ([string]$osEntry.name) -Suffix "-asitwas-$stamp"
        $osSource = [string]$osEntry.name
        try {
            $null = New-VmfOsDiskFromCopy -Context $Context -OpName 'putBack:createDisk' -ResourceGroupName $Context.Rg -DiskName $osName `
                -SnapshotId $pristineId -Location $location -SkuName $osSku -Zone $zone -Disk $capture.osDisk `
                -OnMade { param($madeId) Add-VmfRollbackDisksBeforeMoveEntry -Context $Context -Entry @{ lun = $null; name = $osSource; diskId = $madeId; diskName = $osName; snapshotId = $pristineId; skuName = $osSku } }
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            throw "The operating system disk '$osName' was not made from its copy: $($_.Exception.Message)"
        }

        $readiness = Get-VmfInstantAccessCopyReadiness -Context $Context -Doc $doc -Kind 'pristine'
        $plan = Get-VmfDataRestorePlan -Doc $doc -Stamp $stamp -CopyReadiness $readiness
        foreach ($k in @($plan.Kept)) {
            throw "The data disk '$($k.name)' on LUN $($k.lun) cannot be made from its copy. $($k.why)"
        }
        foreach ($r in @($plan.Restore)) {
            try {
                $shares = Invoke-VmfAzOperation -Name 'putBack:readDataDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                    Get-VmfDiskShareCount -DiskId $r.sourceDiskId
                }
            }
            catch {
                if ($_.Exception.Message -match 'abandon this VM') { throw }
                throw "The product could not read whether other machines share the data disk '$($r.name)' on LUN $($r.lun): $($_.Exception.Message)"
            }
            if ([int]$shares -gt 1) {
                # A shared disk is attached to other machines too: every
                # put-back leaves it, and says so (SAFETY-ALL-1).
                $kept.Add([pscustomobject][ordered]@{ lun = [int]$r.lun; name = [string]$r.name; shared = $true; why = "It is a shared disk (maxShares $shares), and other machines can use it." })
                continue
            }
            $made = New-VmfDataDiskFromCopy -Context $Context -Row $r -DiskName $r.diskName -ResourceGroupName $Context.Rg `
                -Location $location -Zone $zone -OpName 'putBack:createDataDisk'
            if ($made.Id) {
                Add-VmfRollbackDisksBeforeMoveEntry -Context $Context -Entry @{ lun = [int]$r.lun; name = [string]$r.name; diskId = [string]$made.Id; diskName = [string]$r.diskName
                    snapshotId = [string]$r.snapshotId; skuName = [string]$r.skuName; instantAccess = [bool](Get-VmfRecordField -Object $r -Name 'instantAccess') }
            }
            if (-not $made.Id -or $made.Why) {
                throw "The data disk '$($r.diskName)' for LUN $($r.lun) was not made from its copy. $($made.Why)"
            }
        }
    }
    catch {
        # Lease fencing is not a refused disk: another worker owns the machine
        # now, and finishes this with the same names.
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $refusal = $_.Exception.Message
    }

    if (-not $refusal) {
        $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
        $rec = Get-VmfRollbackDisksBeforeMoveRecord -Doc $doc
        $rec | Add-Member -NotePropertyName kept -NotePropertyValue @($kept) -Force
        $rec | Add-Member -NotePropertyName complete -NotePropertyValue $true -Force
        Set-VmfRollbackDisksBeforeMoveRecord -RunPath $Context.RunPath -VmId $Context.VmId -Record $rec
        $names = @(@($rec.disks) | Where-Object { $_ } | ForEach-Object { "'$($_.diskName)'" })
        $keptWords = if ($kept.Count) { " Every rollback leaves these data disks as they are: $(@($kept | ForEach-Object { "LUN $($_.lun) '$($_.name)': $($_.why)" }) -join ' ')" } else { '' }
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'SAFETY_PRISTINE' -Outcome info -VmId $Context.VmId `
            -Detail "The product made the rollback disks from the first safety copies, before it changes the machine: $($names -join ', '). A rollback only puts these disks on the machine.$keptWords"
        return $null
    }

    # Refused: nothing on the machine was changed. Every disk made for the
    # rollback is deleted - none is left billing on no record.
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $mine = @(@(Get-VmfRecordField -Object (Get-VmfRollbackDisksBeforeMoveRecord -Doc $doc) -Name 'disks') | Where-Object { $_ -and -not [string]$_.deletedUtc })
    $cleanup = Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $Context.RunPath -VmId $Context.VmId -Disks $mine -Step 'SAFETY_PRISTINE'
    $cleanWords = ''
    if (@($cleanup.Deleted).Count) { $cleanWords += " The rollback disks are deleted: $(@($cleanup.Deleted | ForEach-Object { "'$_'" }) -join ', ')." }
    if (@($cleanup.Failed).Count) { $cleanWords += " These rollback disks were not deleted, and each bills until somebody deletes it: $(@($cleanup.Failed | ForEach-Object { "'$($_.name)' ($($_.why))" }) -join ', ')." }
    # The machine runs, as it did before the move: SAFETY_PRISTINE started it
    # after the copies, and a resume may have found it stopped.
    # STOP-POWER-AS-FOUND-1: a machine that Checking found deallocated or
    # stopped, and started for the cluster check, goes back to that power state.
    $machineState = 'untouched'
    $powerWords = ''
    # POWER-ONLY-CHANGED-1: the power state found, when only its put-back was
    # refused.
    $powerNotPutBack = $null
    $back = Restore-VmfPowerAsFound -Context $Context
    if ($back) {
        $powerWords = " $($back.Words)"
        if (-not $back.Ok) { $machineState = 'changed'; $powerNotPutBack = $back.PowerNotPutBack }
    }
    else {
        # POWER-ONLY-CHANGED-1 (2026-11-06, the other direction): the
        # start is tried again; still refused, the stop names the power state
        # running, so its retry is not held for this alone.
        $start = Restore-VmfPowerAsFound -Context $Context -Power 'PowerState/running' -OpName 'putBack:ensureRunning'
        if (-not $start.Ok) {
            $machineState = 'changed'
            $powerNotPutBack = 'PowerState/running'
            $powerWords = " $($start.Words)"
        }
    }
    @{
        Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'rollbackDisksBeforeMoveNotMade'; MachineState = $machineState; PowerAsFound = $true; PowerNotPutBack = $powerNotPutBack
        Detail = "The move stopped before it changed the machine, because the product could not make every rollback disk from the first safety copies. $refusal$cleanWords$powerWords"
    }
}

function Get-VmfRollbackDisksBeforeMoveSet {
    <#
    .SYNOPSIS
        The rollback disks, in the shape a put-back swaps them
        in - or why a put-back cannot use them, and makes its own (the
        fallback, New-VmfRollbackDisksDuringRollback or the restore's own disks).
    .DESCRIPTION
        Usable only when ALL of this holds; anything else is the fallback,
        said in the run history:
          - a record for this attempt, complete, made from the copy this
            put-back restores from (none until the end of SAFETY_PRISTINE
            makes them);
          - no disk of it used by an earlier put-back, and none deleted;
          - for the disks-only rollback (-Shape disks), every disk on the type
            and in the zone this attempt's capture records - it puts back the
            disks the machine has now, which a retry after a rebuild as the
            target can differ from;
          - each LUN the caller restores (-Luns) has its disk;
          - Azure still has each disk, attached to nothing or to this machine
            (a resume after a swap) - read now, before the stop. A read that
            fails is no answer, and no answer is never a yes.
    .OUTPUTS
        @{ Set = @{ OsId; OsName; Data = @{ Swaps; Kept }; Ids } or $null; Why }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][ValidateSet('full', 'disks')][string]$Shape,
        [Parameter(Mandatory)][string]$FromSnapshotId,
        [Parameter()][AllowNull()][int[]]$Luns,
        # A rollback that a worker did not finish is finished by the next one
        # (Complete-VmfRollback -Resumed). Disks marked used BY THIS ROLLBACK
        # (its checkpoint's time) are its own, already on the machine - the
        # resume swaps the same disks again, never makes others. Any other use
        # (an earlier rollback, a restore) means the machine runs on them, and
        # a put-back from the copy needs new disks.
        [Parameter()][AllowEmptyString()][string]$UsedBy = ''
    )
    $no = { param($why) @{ Set = $null; Why = $why } }
    $rec = Get-VmfRollbackDisksBeforeMoveRecord -Doc $Doc
    if (-not $rec) { return (& $no 'No rollback disks are on record for this safety copy.') }
    if ([string]$rec.pristineSnapshotId -ne $FromSnapshotId) { return (& $no 'The rollback disks are from another safety copy.') }
    if (-not $rec.complete) { return (& $no 'The rollback disks are not complete.') }
    $all = @(@($rec.disks) | Where-Object { $_ })
    $used = @($all | Where-Object { [string]$_.usedUtc -and -not ($UsedBy -and [string](Get-VmfRecordField -Object $_ -Name 'usedBy') -eq $UsedBy) })
    if ($used.Count) { return (& $no "An earlier rollback or restore already put the rollback disks on the machine: $(@($used | ForEach-Object { "'$($_.diskName)'" }) -join ', ').") }
    $gone = @($all | Where-Object { [string]$_.deletedUtc })
    if ($gone.Count) { return (& $no "The product deleted the rollback disks: $(@($gone | ForEach-Object { "'$($_.diskName)'" }) -join ', ').") }
    $os = $all | Where-Object { $null -eq $_.lun } | Select-Object -First 1
    if (-not $os) { return (& $no 'No rollback disk of the operating system disk is on record.') }
    $data = @($all | Where-Object { $null -ne $_.lun })

    if ($Shape -eq 'disks') {
        # PREP-ROLLBACK-1 (review F8): the disks-only rollback makes each disk
        # on the type it has now.
        $attempt = $Doc.captured.vmConfig
        $differs = [System.Collections.Generic.List[string]]::new()
        if ([string]$attempt.osDisk.skuName -ne [string]$os.skuName) { $differs.Add("the operating system disk is $($attempt.osDisk.skuName) now, and '$($os.diskName)' is $($os.skuName)") }
        foreach ($d in $data) {
            $now = @($attempt.dataDisks) | Where-Object { $_ -and [int]$_.lun -eq [int]$d.lun } | Select-Object -First 1
            if (-not $now -or [string]$now.skuName -ne [string]$d.skuName) { $differs.Add("the data disk on LUN $($d.lun) is $(if ($now) { $now.skuName } else { 'not there' }) now, and '$($d.diskName)' is $($d.skuName)") }
        }
        $zoneNow = Get-VmfMachineZone -Machine $attempt
        if ([string]$zoneNow -ne [string]$rec.zone) { $differs.Add("the machine is in zone $(if ($zoneNow) { $zoneNow } else { 'none' }) now, and the disks were made in zone $(if ($rec.zone) { $rec.zone } else { 'none' })") }
        if ($differs.Count) { return (& $no "The rollback disks do not match this attempt: $($differs -join '; ').") }
    }
    if ($PSBoundParameters.ContainsKey('Luns')) {
        $missing = @(@($Luns) | Where-Object { $_ -notin @($data | ForEach-Object { [int]$_.lun }) })
        if ($missing.Count) { return (& $no "No rollback disk of the data disk is on record for LUN $($missing -join ', ').") }
        $data = @($data | Where-Object { [int]$_.lun -in @($Luns) })
    }

    # Read now, before the stop: a disk somebody deleted, or attached to
    # another machine, would be found inside the stopped window otherwise.
    foreach ($d in @(@($os) + $data)) {
        $diskId = [string]$d.diskId
        try {
            $live = Invoke-VmfAzOperation -Name 'putBack:readDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfManagedDiskAttachment -DiskId $diskId
            }
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            return (& $no "The product could not read the rollback disk '$($d.diskName)': $($_.Exception.Message)")
        }
        if (-not $live.Exists) { return (& $no "Azure no longer has the rollback disk '$($d.diskName)'.") }
        if ([string]$live.ManagedBy -and [string]$live.ManagedBy -ne [string]$Context.VmId) {
            return (& $no "The rollback disk '$($d.diskName)' is attached to '$($live.ManagedBy)'.")
        }
    }
    $swaps = @($data | ForEach-Object {
            [pscustomobject]@{ lun = [int]$_.lun; diskId = [string]$_.diskId; diskName = [string]$_.diskName; name = [string]$_.name
                # SAFETY-ULTRA-1: these types take no host caching, and they are
                # swapped in a batch of their own (Get-VmfSwapBatches).
                instantAccess = [bool]$_.instantAccess; caching = $(if ([bool]$_.instantAccess) { 'None' } else { $null })
                # FINISH-EMPTY-LUN-PROOF-1: the copy it was made from, for the
                # record of a swap that is left (New-VmfSwapLeftRow).
                snapshotId = [string]$_.snapshotId } })
    $keptRows = @(@(Get-VmfRecordField -Object $rec -Name 'kept') | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ lun = [int]$_.lun; name = [string]$_.name; why = [string]$_.why } })
    @{
        Set = @{ OsId = [string]$os.diskId; OsName = [string]$os.diskName; Data = @{ Swaps = $swaps; Kept = $keptRows }
                 Ids = @(@($os) + $data | ForEach-Object { [string]$_.diskId }) }
        Why = $null
    }
}

function Set-VmfRollbackDisksBeforeMoveUsed {
    <#
    .SYNOPSIS
        Mark the rollback disks that a put-back put on the
        machine. A used disk is the machine's own disk from then on: no
        put-back uses it again, and nothing ever deletes it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId, [Parameter()][AllowEmptyCollection()][string[]]$DiskIds = @(),
          # Who put it on: 'rollback-<checkpoint time>' or 'restore'. A
          # resume of the same rollback may use its own disks again.
          [Parameter()][AllowEmptyString()][string]$By = '')
    $ids = @($DiskIds | Where-Object { $_ })
    if (-not $ids.Count) { return }
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $rec = Get-VmfRollbackDisksBeforeMoveRecord -Doc $doc
    if (-not $rec) { return }
    $changed = $false
    foreach ($d in @(@($rec.disks) | Where-Object { $_ -and [string]$_.diskId -in $ids -and -not [string]$_.usedUtc })) {
        $d | Add-Member -NotePropertyName usedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
        $d | Add-Member -NotePropertyName usedBy -NotePropertyValue $(if ($By) { $By } else { $null }) -Force
        $changed = $true
    }
    if ($changed) { Set-VmfRollbackDisksBeforeMoveRecord -RunPath $RunPath -VmId $VmId -Record $rec }
}

function Set-VmfRollbackDisksBeforeMoveMark {
    <#
    .SYNOPSIS
        Mark one rollback disk as deleted or used, wherever it
        is on record - this attempt's, or an earlier attempt's
        (safety.earlierCopies, SAFETY-RETRY-1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId, [Parameter(Mandatory)][string]$DiskId,
          [Parameter(Mandatory)][ValidateSet('deletedUtc', 'usedUtc')][string]$Field)
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc -or -not $doc.PSObject.Properties['safety'] -or -not $doc.safety) { return }
    $holders = @(@($doc.safety) + @(Get-VmfRecordField -Object $doc.safety -Name 'earlierCopies') | Where-Object { $_ })
    $hit = $false
    foreach ($h in $holders) {
        $rec = Get-VmfRecordField -Object $h -Name 'rollbackDisksBeforeMove'
        foreach ($d in @(Get-VmfRecordField -Object $rec -Name 'disks')) {
            if ($d -and [string]$d.diskId -eq $DiskId) { $d | Add-Member -NotePropertyName $Field -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force; $hit = $true }
        }
    }
    if (-not $hit) { return }
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}

function Remove-VmfRollbackDisksBeforeMoveEntries {
    <#
    .SYNOPSIS
        Delete rollback disks, by their ids - never one that is
        attached. Each is read first: a disk already gone is marked deleted, a
        disk attached to anything is marked used and kept. Never throws for a
        disk: it returns what it deleted and what it did not, with why.
        MADE-DISK-RECORD-1: a disk a put-back made from a copy (a row with
        List, from Get-VmfDueMadeDisks) is marked on its own list - the same
        reads, the same rule.
        DISK-ID-SCOPE-1: a disk id that is not a managed disk of this machine
        - another type, another subscription, or a resource group where the
        product makes no disk for it (Get-VmfMadeDiskResourceGroups) - is
        refused before any Azure call, and named in Failed. The record keeps it.
    .OUTPUTS
        @{ Deleted = @(<disk name>); Failed = @(@{ name; why }); InUse = @(@{ name; managedBy }) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowEmptyCollection()][object[]]$Disks = @(),
        [Parameter(Mandatory)][string]$Step
    )
    $deleted = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()
    $inUse = [System.Collections.Generic.List[object]]::new()
    # DISK-ID-SCOPE-1: where the product makes disks for this machine, from
    # its record. A record that cannot be read gives the machine's own
    # resource group only - never a wider set.
    $scopeDoc = try { Read-VmfStateDoc -RunPath $RunPath -VmId $VmId } catch { $null }
    $scopeRgs = @(try { Get-VmfMadeDiskResourceGroups -StateDoc $scopeDoc -VmId $VmId } catch { @() })
    foreach ($d in @($Disks | Where-Object { $_ -and [string]$_.diskId })) {
        $diskId = [string]$d.diskId
        try { Assert-VmfDiskInMachineScope -DiskId $diskId -MachineId $VmId -ResourceGroupNames $scopeRgs }
        catch {
            $failed.Add([pscustomobject]@{ name = [string]$d.diskName; why = $_.Exception.Message })
            continue
        }
        $madeList = [string](Get-VmfRecordField -Object $d -Name 'List')
        $mark = { param($field)
            if ($madeList) { Set-VmfMadeDiskMark -RunPath $RunPath -VmId $VmId -DiskIds @($diskId) -Field $field }
            else { Set-VmfRollbackDisksBeforeMoveMark -RunPath $RunPath -VmId $VmId -DiskId $diskId -Field $field } }
        try {
            $live = Invoke-VmfAzOperation -Name "$($Step):readRollbackDisksBeforeMove" -RunPath $RunPath -VmId $VmId -Operation {
                Get-VmfManagedDiskAttachment -DiskId $diskId
            }
            if ($live.Exists -and [string]$live.ManagedBy) {
                # On a machine: it is in use, so it is never deleted.
                & $mark 'usedUtc'
                $inUse.Add([pscustomobject]@{ name = [string]$d.diskName; managedBy = [string]$live.ManagedBy })
                continue
            }
            if ($live.Exists) {
                Invoke-VmfAzOperation -Name "$($Step):deleteRollbackDisksBeforeMove" -RunPath $RunPath -VmId $VmId -Operation {
                    Remove-VmfManagedDiskById -DiskId $diskId -MachineId $VmId -ResourceGroupNames $scopeRgs
                } | Out-Null
            }
            & $mark 'deletedUtc'
            $deleted.Add([string]$d.diskName)
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $why = $_.Exception.Message
            # CANNOTDELETE-RESTORE-1: a refused delete reads the locks that
            # refuse it (Get-VmfDeleteBlockingLocks, the read Restore this
            # machine makes), so the record names the lock and not only the
            # words of Azure. A read that fails keeps those words.
            $locks = @()
            try {
                $locks = @(Invoke-VmfAzOperation -Name "$($Step):readLocks" -RunPath $RunPath -VmId $VmId -Operation {
                        Get-VmfDeleteBlockingLocks -ResourceGroupName (Get-VmfResourceGroupName -ResourceId $diskId) -DiskName (($diskId -split '/')[-1])
                    } | Where-Object { $_ })
            }
            catch {
                if ($_.Exception.Message -match 'abandon this VM') { throw }
                $locks = @()
            }
            if ($locks.Count) { $why = "a resource lock prevents the delete: $($locks -join ', ')" }
            $failed.Add([pscustomobject]@{ name = [string]$d.diskName; why = $why; locked = [bool]$locks.Count })
        }
    }
    @{ Deleted = @($deleted); Failed = @($failed); InUse = @($inUse) }
}

function Remove-VmfUnusedRollbackDisksBeforeMove {
    <#
    .SYNOPSIS
        The move is complete: delete every rollback disk that no
        put-back used - this attempt's and the earlier attempts'. Called after
        MIGRATED is on record. Never fails the move: a disk not deleted is
        said, and retention deletes it later (Get-VmfDueRollbackDisksBeforeMove).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $due = @(Get-VmfRollbackDisksBeforeMoveEntries -StateDoc $doc | Where-Object { -not [string]$_.usedUtc -and -not [string]$_.deletedUtc })
    if (-not $due.Count) { return }
    $result = Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $Context.RunPath -VmId $Context.VmId -Disks $due -Step 'putBack'
    if (@($result.Deleted).Count) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'putBack' -Outcome info -VmId $Context.VmId `
            -Detail "The move is complete, so the product deleted the rollback disks: $(@($result.Deleted | ForEach-Object { "'$_'" }) -join ', '). The safety copies are kept for the days the wave keeps them."
    }
    if (@($result.Failed).Count) {
        # CANNOTDELETE-RESTORE-1: the daily cleanup meets the same lock.
        $lockWords = if (@($result.Failed | Where-Object { [bool](Get-VmfRecordField -Object $_ -Name 'locked') }).Count) { ' The daily cleanup cannot delete a disk while a resource lock prevents the delete.' } else { '' }
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'putBack' -Outcome warn -VmId $Context.VmId `
            -Detail "The move is complete. These rollback disks were not deleted, and the daily cleanup tries again: $(@($result.Failed | ForEach-Object { "'$($_.name)' ($($_.why))" }) -join ', ').$lockWords"
    }
    if (@($result.InUse).Count) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'putBack' -Outcome info -VmId $Context.VmId `
            -Detail "These rollback disks are attached to a machine, so the product keeps them: $(@($result.InUse | ForEach-Object { "'$($_.name)' on '$($_.managedBy)'" }) -join ', ')."
    }
}
