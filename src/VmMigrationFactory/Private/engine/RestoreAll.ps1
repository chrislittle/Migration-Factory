# RESTORE-ALL-1: Restore this machine puts back every disk.
#
# SAFETY-ALL-1 copied every disk and made the AUTOMATIC put-back restore them
# all. The operator's restore still replaced the OS disk only, so a person who
# restored a machine got an OS disk of one moment and data disks of another.
# Now each data disk comes back from the copy the person chose, with the same
# rules as the put-back (Get-VmfDataRestorePlan), in the machine's zone, and
# under the naming choice the person made for the OS disk - one choice for
# every disk (2026-09-29).

function Get-VmfKnownDataDiskIds {
    <#
    .SYNOPSIS
        The data disk IDs this machine's record knows: the captured disks, and
        the disks a rollback or an earlier restore made. Pure.
    .DESCRIPTION
        A restore replaces - and, keeping the names, DELETES - the disk on each
        LUN. The dashboard names the disks from this same record, so a disk the
        record does not know is one the person was never shown: somebody
        attached it outside the product. It is left, never replaced.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Doc)
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($d in @($Doc.captured.vmConfig.dataDisks | Where-Object { $_ })) { $ids.Add([string]$d.managedDiskId) }
    if ($Doc.PSObject.Properties['rollback'] -and $Doc.rollback) {
        foreach ($d in @($Doc.rollback.dataDisks | Where-Object { $_ })) { $ids.Add([string]$d.diskId) }
    }
    if ($Doc.PSObject.Properties['restore'] -and $Doc.restore -and $Doc.restore.PSObject.Properties['dataDisks']) {
        foreach ($d in @($Doc.restore.dataDisks | Where-Object { $_ })) { $ids.Add([string]$d.newDiskId) }
    }
    @($ids | Where-Object { $_ })
}

function Get-VmfDisksInUseByRecord {
    <#
    .SYNOPSIS
        The disks this machine runs on, as its record knows them: the captured
        disks, then each disk a rollback or a restore from a copy made, newest
        last. Pure.
    .DESCRIPTION
        After a rollback or a restore gave the machine new disks, the disks the
        capture names are not the disks it runs on. The page names disks the
        same way (restoreDiskNames).
    .OUTPUTS
        @{ Os = @{ id; name }; Data = @(@{ lun; id; name }) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Doc)
    $vm = $Doc.captured.vmConfig
    $os = @{ id = [string]$vm.osDisk.managedDiskId; name = [string]$vm.osDisk.name }
    $data = @{}
    foreach ($d in @($vm.dataDisks | Where-Object { $_ })) { $data[[int]$d.lun] = @{ id = [string]$d.managedDiskId; name = [string]$d.name } }
    $at = { param($v) if ($v) { try { [datetimeoffset]$v } catch { [datetimeoffset]::MinValue } } else { [datetimeoffset]::MinValue } }
    $made = [System.Collections.Generic.List[object]]::new()
    $rb = if ($Doc.PSObject.Properties['rollback']) { $Doc.rollback } else { $null }
    $rs = if ($Doc.PSObject.Properties['restore']) { $Doc.restore } else { $null }
    if ($rb) {
        $made.Add(@{ at = (& $at $rb.rolledBackUtc)
                os = $(if ($rb.osDisk -and [string]$rb.osDisk.id) { @{ id = [string]$rb.osDisk.id; name = [string]$rb.osDisk.name } })
                data = @(@($rb.dataDisks | Where-Object { $_ }) | ForEach-Object { @{ lun = [int]$_.lun; id = [string]$_.diskId; name = [string]$_.diskName } }) })
    }
    if ($rs -and [string]$rs.newDiskId) {
        $made.Add(@{ at = (& $at $rs.restoredUtc); os = @{ id = [string]$rs.newDiskId; name = [string]$rs.newDiskName }
                data = @(@($(if ($rs.PSObject.Properties['dataDisks']) { $rs.dataDisks }) | Where-Object { $_ }) | ForEach-Object { @{ lun = [int]$_.lun; id = [string]$_.newDiskId; name = [string]$_.newDiskName } }) })
    }
    foreach ($m in @($made | Sort-Object { $_.at })) {
        if ($m.os) { $os = $m.os }
        foreach ($d in @($m.data)) { $data[[int]$d.lun] = @{ id = $d.id; name = $d.name } }
    }
    @{ Os = [pscustomobject]$os
       Data = @($data.Keys | Sort-Object | ForEach-Object { [pscustomobject]@{ lun = [int]$_; id = $data[$_].id; name = $data[$_].name } }) }
}
function Get-VmfMadeDiskTypes {
    <#
    .SYNOPSIS
        The disks a rollback or a restore made for this machine, each with the
        type the capture recorded for its place. Pure.
    .DESCRIPTION
        A put-back to the original size sets disk types back first
        (OLD-SKU-1C), by the move's records - which name the CAPTURED disks
        only. A disk the product made later is on the moved type when a
        second-copy restore made it, and the original size can refuse it.
    .OUTPUTS
        A hashtable: disk ID -> captured type.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Doc)
    $out = @{}
    # ROLLBACK-RETRY-CAPTURE-1: the types of the FIRST capture, by place.
    $vm = Get-VmfPutBackCapture -Doc $Doc
    $osType = if ($vm.osDisk) { [string]$vm.osDisk.skuName } else { '' }
    $dataType = { param($lun) [string](@($vm.dataDisks) | Where-Object { $_ -and [int]$_.lun -eq [int]$lun } | Select-Object -First 1).skuName }
    $rb = if ($Doc.PSObject.Properties['rollback']) { $Doc.rollback } else { $null }
    $rs = if ($Doc.PSObject.Properties['restore']) { $Doc.restore } else { $null }
    if ($rb -and $rb.osDisk -and [string]$rb.osDisk.id -and $osType) { $out[[string]$rb.osDisk.id] = $osType }
    if ($rs -and [string]$rs.newDiskId -and $osType) { $out[[string]$rs.newDiskId] = $osType }
    foreach ($d in @($(if ($rb) { $rb.dataDisks }) | Where-Object { $_ })) { $ty = & $dataType $d.lun; if ($ty) { $out[[string]$d.diskId] = $ty } }
    foreach ($d in @($(if ($rs -and $rs.PSObject.Properties['dataDisks']) { $rs.dataDisks }) | Where-Object { $_ })) { $ty = & $dataType $d.lun; if ($ty) { $out[[string]$d.newDiskId] = $ty } }
    $out
}

function Get-VmfOperatorDataRestorePlan {
    <#
    .SYNOPSIS
        Which data disks Restore this machine replaces, and which it leaves
        with the reason. Pure: no Azure.
    .DESCRIPTION
        The put-back's rules (no copy, a copy of another disk, no type, and
        SAFETY-ULTRA-1's rules for Premium SSD v2 and Ultra Disk), then the
        machine as it is NOW: a restore replaces the disk that is on each LUN,
        which may not be the one the capture names - a rollback or an earlier
        restore gave it a new name.
          - A LUN with no disk now is left: nothing is there to replace.
          - A disk the record does not know is left (Get-VmfKnownDataDiskIds).
          - SAFETY-ULTRA-1: a Premium SSD v2 or Ultra Disk comes back only as
            the type its copy was taken from, so a disk on another type now is
            left. Keeping the names, a disk is not deleted while a copy of it
            in instant access is not complete: that copy depends on its disk
            until Azure finishes copying it (Microsoft, instant access
            snapshots), and deleting the disk would lose it.
          - A disk the capture never saw has no copy, and is left.
        A shared disk is found by the caller, which asks Azure.
        The first copy goes back on the type the capture recorded; the second
        keeps the type the disk has now, as the OS disk does.
        new: each new disk goes beside the machine. preserve: each new disk
        takes the current disk's name, in the current disk's resource group
        (ID-ADDRESS-1), after a temporary disk beside the machine frees it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$Kind,
        [Parameter()][AllowEmptyCollection()][object[]]$Live = @(),
        [Parameter(Mandatory)][string]$Stamp,
        [Parameter(Mandatory)][ValidateSet('new', 'preserve')][string]$Naming,
        # SAFETY-ULTRA-1: Get-VmfInstantAccessCopyReadiness -Kind all, read
        # before the machine stops.
        [Parameter()][AllowNull()][hashtable]$CopyReadiness
    )
    $base = Get-VmfDataRestorePlan -Doc $Doc -Stamp $Stamp -Kind $Kind -CopyReadiness $CopyReadiness
    $known = @(Get-VmfKnownDataDiskIds -Doc $Doc)
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($base.Kept)) { $kept.Add($k) }
    $restore = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($base.Restore)) {
        $lun = [int]$r.lun
        $now = @($Live) | Where-Object { $_ -and [int]$_.lun -eq $lun } | Select-Object -First 1
        if (-not $now) { $kept.Add([pscustomobject]@{ lun = $lun; name = $r.name; why = "No data disk is on LUN $lun now." }); continue }
        if (-not [string]$now.id) { $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$now.name; why = 'It is not a managed disk.' }); continue }
        if ($known -notcontains [string]$now.id) {
            $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$now.name; why = "The disk on LUN $lun now is not a disk that the record of this machine names. Somebody attached it outside the product." })
            continue
        }
        $instantRow = [bool](Get-VmfRecordField -Object $r -Name 'instantAccess')
        $nowSpecial = $script:VmfInstantAccessDiskTypes.ContainsKey([string]$now.skuName)
        if (($instantRow -or $nowSpecial) -and [string]$now.skuName -and [string]$now.skuName -ne [string]$r.skuName) {
            $typeWord = { param($t) if ($script:VmfInstantAccessDiskTypes.ContainsKey($t)) { $script:VmfInstantAccessDiskTypes[$t] } else { $t } }
            $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$now.name
                why = "Its disk type is $(& $typeWord ([string]$now.skuName)) now, and its copy was taken from a disk on $(& $typeWord ([string]$r.skuName)). Azure makes a Premium SSD v2 or Ultra Disk from its copy only as the type that the copy was taken from." })
            continue
        }
        $preserve = $Naming -eq 'preserve'
        if ($preserve -and $CopyReadiness) {
            $dependent = @($CopyReadiness.Values | Where-Object { $_ -and [string]$_.diskId -eq [string]$now.id -and -not ($_.Complete -and -not [string]$_.Error) })
            if ($dependent.Count) {
                $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$now.name
                    why = "Keeping the names deletes this disk, and a copy of it depends on it until Azure finishes copying it: $(@($dependent | ForEach-Object { "'$($_.snapshotId)' ($(if ($_.State) { $_.State } else { 'access state not read' }))" }) -join ', '). Try again later, or give the restored disks new names." })
                continue
            }
        }
        # SAFETY-ULTRA-1: these types are made on the type, IOPS and
        # throughput on record, whichever copy - never on the type now.
        $sku = if ($Kind -eq 'prepared' -and [string]$now.skuName -and -not $instantRow) { [string]$now.skuName } else { [string]$r.skuName }
        $row = [pscustomobject]@{
            lun = $lun; name = [string]$now.name; sourceDiskId = [string]$now.id
            snapshotId = [string]$r.snapshotId; skuName = $sku
            diskName = $(if ($preserve) { [string]$now.name } else { Get-VmfBoundedDiskName -BaseName ([string]$now.name) -Suffix "-d$lun-restored-$Stamp" })
            currentId = [string]$now.id; currentName = [string]$now.name; currentResourceGroup = [string]$now.resourceGroup
            tempName = $(if ($preserve) { Get-VmfBoundedDiskName -BaseName ([string]$now.name) -Suffix "-d$lun-rtmp-$Stamp" } else { $null })
            # SAFETY-CMK-1: the key of the disk its copy was taken of, whichever copy.
            encryption = (Get-VmfRecordField -Object $r -Name 'encryption')
        }
        if ($instantRow) {
            foreach ($n in 'instantAccess', 'diskIOPSReadWrite', 'diskMBpsReadWrite', 'logicalSectorSize', 'sizeGB', 'diskZones') {
                $row | Add-Member -NotePropertyName $n -NotePropertyValue $r.$n -Force
            }
        }
        $restore.Add($row)
    }
    $capturedLuns = @($Doc.captured.vmConfig.dataDisks | Where-Object { $_ } | ForEach-Object { [int]$_.lun })
    foreach ($extra in @($Live | Where-Object { $_ -and [int]$_.lun -notin $capturedLuns })) {
        $kept.Add([pscustomobject]@{ lun = [int]$extra.lun; name = [string]$extra.name; why = 'No copy of it is on record.' })
    }
    @{ Restore = @($restore); Kept = @($kept | Sort-Object { [int]$_.lun }) }
}

function Invoke-VmfOperatorDataRestore {
    <#
    .SYNOPSIS
        Put the data disks back from the plan, on a STOPPED machine, under the
        person's naming choice. Never throws for a disk: it says where each
        disk stands, and the caller records that before it says anything else.
    .DESCRIPTION
        new       Make each disk from its copy, then swap them all in with ONE
                  update. The current disks stay in Azure, detached.
        preserve  One disk at a time, the OS disk's way: a temporary disk from
                  the copy goes on the LUN, the current disk is DELETED only
                  then, the new disk takes its name in its resource group,
                  goes on the LUN, and the temporary disk goes. A step that
                  fails STOPS the data phase: the disks after it are not
                  touched, and the failing LUN's state is said exactly - the
                  machine then runs on a disk made from the copy, with a name
                  that says temporary, and nobody may clean that up blind.
        SWAP-REFUSED-AFTER-STOP-1: a swap Azure refuses is tried again
        (Invoke-VmfDataDiskSwap). A disk Azure still will not swap goes on Left,
        never on Kept: the LUN keeps the disk it had while the others come back
        from the copy, so the caller must not start the machine.
        RESTORE-THROW-STARTS-1: so does every LUN the restore cannot prove is
        back after a swap that threw - Azure cannot be read, or the LUN holds
        another disk - and every LUN after it that waits for its disk. Kept
        holds only a disk the restore leaves as it is (a shared disk, a disk
        with no copy, a Premium SSD v2 or Ultra Disk Azure cannot use) and a
        LUN that runs on its temporary disk, made from the copy.
        RESTORE-INLOOP-TEMP-1: keeping the names, this function makes no
        temporary disk. Each LUN it takes has one already: on the LUN
        (-AlreadyOnTemp) or made before the stop (-TempMade, by
        New-VmfOperatorTempDataDisks). A LUN with neither is refused before
        any data disk changes, and the error is marked so that the caller
        never starts the machine (vmfRestoreStranded) - a LUN kept as it is
        would let the machine start with disks from two moments.
    .OUTPUTS
        @{ Replaced = @(@{ lun; previousDiskId; previousDiskName; newDiskId; newDiskName })
           Kept = @(@{ lun; name; why }); Left = @(New-VmfSwapLeftRow ...);
           Unread = @(<LUN of Left the product did not read after a swap that threw, or after an attach to a LUN with no disk that stopped with an error that is not a refusal>);
           Other = @(<LUN of Left that holds a disk that is neither its own nor the copy's>);
           Refused = @(<LUN of Left whose swap Azure refused on every try>);
           Failure = <string or $null> }
        FINISH-EMPTY-LUN-WORDS-1: each row of Left says what is on its LUN
        (lunHolds), and only a LUN on Refused is said "after 3 tries".
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('new', 'preserve')][string]$Naming,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        # LUN -> disk ID of a temporary disk already on the LUN (a resume).
        # Keeping the names starts at step 4 for those LUNs.
        [Parameter()][hashtable]$AlreadyOnTemp = @{},
        # ROLLBACK-DISKS-FIRST-1, new names: what Invoke-VmfDataDiskRestore
        # made before the machine stopped. Given, nothing is made here.
        [Parameter()][AllowNull()][hashtable]$Made,
        # ROLLBACK-DISKS-FIRST-1, keeping the names: LUN -> the temporary disk
        # New-VmfOperatorTempDataDisks made before the stop, not on its LUN
        # yet. Those LUNs start at step 3. RESTORE-INLOOP-TEMP-1: every LUN
        # of the plan is here or on -AlreadyOnTemp, or nothing changes.
        [Parameter()][hashtable]$TempMade = @{},
        # SWAP-REFUSED-AFTER-STOP-1 (re-review): the caller's view of the data
        # restore if it throws part way. Left: the disks left so far. Pending:
        # LUN -> each disk not yet proven on its copy, as a row Finish the
        # restore can swap. The caller never starts a machine with either.
        [Parameter()][AllowNull()][hashtable]$Progress,
        # RESTORE-END-JOB-1, keeping the names: LUN -> $true when the disk the
        # LUN had is deleted already (a job that stopped after step 4). The
        # resume starts those LUNs at step 5.
        [Parameter()][hashtable]$CurrentGone = @{},
        # PRESERVE-USED-MARK-1: the mark on a rollback disk that a
        # swap puts on the machine (Set-VmfRollbackDisksBeforeMoveUsed), given when the
        # restore uses those disks. Empty: nothing is marked here.
        [Parameter()][AllowEmptyString()][string]$UsedBy = ''
    )
    $replaced = [System.Collections.Generic.List[object]]::new()
    $kept = [System.Collections.Generic.List[object]]::new()
    $left = [System.Collections.Generic.List[object]]::new()
    # RESTORE-THROW-STARTS-1: the LUNs of $left whose disk the product did not
    # read after a swap that threw - said as not read, never as a disk kept.
    $unread = [System.Collections.Generic.List[int]]::new()
    # Review: and those that hold a third disk - neither the disk they had nor
    # the disk made from the copy. Said by their why, never as a disk kept.
    $other = [System.Collections.Generic.List[int]]::new()
    # FINISH-EMPTY-LUN-WORDS-1: and those whose swap Azure refused on every try.
    $refused = [System.Collections.Generic.List[int]]::new()
    if ($null -ne $Progress) { $Progress.Left = $left; $Progress.Pending = @{} }
    $pend = { param($leftRowValue) if ($null -ne $Progress) { $Progress.Pending[[int]$leftRowValue.lun] = $leftRowValue } }
    $unpend = { param($lunValue) if ($null -ne $Progress) { $Progress.Pending.Remove([int]$lunValue) } }
    # Set when the first data disk swap starts: from then on the caller never
    # starts the machine on a result it did not get.
    $began = { if ($null -ne $Progress) { $Progress.Began = $true } }
    # PRESERVE-USED-MARK-1: a rollback disk is the machine's own
    # the moment its swap takes - on record before anything else, as the
    # rollback does per batch (Invoke-VmfDataSwapBatches). A process that
    # stops after the swap must never leave it for the daily cleanup.
    $tookUsed = { param([string[]]$ids) if ($UsedBy) { Set-VmfRollbackDisksBeforeMoveUsed -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @($ids | Where-Object { $_ }) -By $UsedBy } }
    foreach ($k in @($Plan.Kept)) { $kept.Add($k) }
    $done = { param($f) @{ Replaced = @($replaced); Kept = @($kept | Sort-Object { [int]$_.lun }); Left = @($left | Sort-Object { [int]$_.lun }); Unread = @($unread | Sort-Object -Unique); Other = @($other | Sort-Object -Unique); Refused = @($refused | Sort-Object -Unique); Failure = $f } }
    # Every note here is 'info': the restore is still running, and on its
    # step warn and fail END the page's "putting back" (RESTORE_ENDS). The
    # restore's own last event says how it ended.
    # STEP-LOG-2: the machine is stopped and its disks are changing. A line
    # that cannot be written must not leave this function: the restore's catch
    # would start the machine part way through and report the restore failed.
    $say = { param($outcome, $detail) $null = $outcome; Write-VmfStepLine -RunPath $Context.RunPath -Step 'restore' -Outcome info -VmId $Context.VmId -Detail $detail }
    # RESTORE-EMPTY-LUN-1: after a swap that threw, a LUN Azure left with no
    # disk between the two updates is filled (Resolve-VmfEmptyDataLun). $null
    # when the LUN cannot be read: the caller keeps its answer.
    # RESTORE-THROW-STARTS-1 (review): a LUN that holds a disk is said as that
    # disk - Outcome 'want' when it is the disk the swap put on, 'holds' with
    # its id and name otherwise - never as a LUN nobody read.
    $fillIfEmpty = { param([int]$lunValue, [hashtable]$a)
        $liveNow = $null
        try {
            $liveNow = @(Invoke-VmfAzOperation -Name 'restore:dataDiskInfo' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                    @(Get-VmfDataDiskInfo -ResourceGroupName $Context.Rg -Name $VmName)
                })
        }
        catch { return $null }
        $on = @($liveNow | Where-Object { $_ -and [int]$_.lun -eq $lunValue }) | Select-Object -First 1
        if ($on -and [string]$on.id -ieq [string]$a.WantId) { return @{ Outcome = 'want' } }
        if ($on) { return @{ Outcome = 'holds'; Id = [string]$on.id; Name = $(if ([string]$on.name) { [string]$on.name } else { ([string]$on.id -split '/')[-1] }) } }
        Resolve-VmfEmptyDataLun -Context $Context -VmName $VmName -Lun $lunValue @a
    }
    $holdsWhy = { param($stepWhy, $fill) "$(([string]$stepWhy).TrimEnd('.')). LUN $lun holds the disk '$($fill.Name)' now." }
    $rows = @($Plan.Restore)

    if ($Naming -eq 'new') {
        # Kept disks are said where the disks are made, whatever happens next.
        $made = if ($Made) { $Made } else { Invoke-VmfDataDiskRestore -Context $Context -RestorePlan $Plan -Location $Location -Zone $Zone -Step 'restore' }
        $kept.Clear(); foreach ($k in @($made.Kept)) { $kept.Add($k) }
        $swaps = @($made.Swaps)
        if (-not $swaps.Count) { return (& $done $null) }
        foreach ($s in $swaps) {
            $planRow = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
            & $pend (New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -Holds 'notRead')
        }
        # SAFETY-ULTRA-1: every other disk first, then the Premium SSD v2 and
        # Ultra Disk disks, so one refused disk of those types keeps no other
        # disk from coming back (Get-VmfSwapBatches).
        $batches = @(Get-VmfSwapBatches -Swaps $swaps)
        for ($b = 0; $b -lt $batches.Count; $b++) {
            $part = @($batches[$b].Swaps)
            try {
                & $began
                $swapped = Invoke-VmfDataDiskSwap -Context $Context -VmName $VmName -OpName 'restore:swapDataDisks' -Swaps $part
            }
            catch {
                # Some LUNs took and some did not: Azure's report names each.
                $why = "The data disk swap did not finish: $($_.Exception.Message)"
                # SWAP-PARTIAL-START-1 (the rule since 2026-10-23: the machine MUST
                # always get back to its original state): a swap left half done is a
                # refused swap for each LUN that kept its disk. Each LUN is read
                # again: one on the disk from the copy is replaced, one on the
                # disk it had is left on record - the machine then stays stopped
                # (the caller) and Finish the restore swaps it.
                # RESTORE-THROW-STARTS-1: a LUN the product cannot prove is back
                # - it holds another disk, or the read fails - is left on
                # record too, never kept: kept tells the caller the machine can
                # start. Finish the restore reads Azure for it first.
                $liveNow = $null
                $readWhy = ''
                try {
                    $liveNow = @(Invoke-VmfAzOperation -Name 'restore:dataDiskInfo' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                            @(Get-VmfDataDiskInfo -ResourceGroupName $Context.Rg -Name $VmName)
                        })
                }
                catch { $liveNow = $null; $readWhy = ([string]$_.Exception.Message).TrimEnd('.') }
                if ($null -ne $liveNow) {
                    $tookRows = [System.Collections.Generic.List[object]]::new()
                    $halfRows = [System.Collections.Generic.List[object]]::new()
                    $emptyLuns = [System.Collections.Generic.List[int]]::new()
                    $otherRows = [System.Collections.Generic.List[object]]::new()
                    $otherWords = [System.Collections.Generic.List[string]]::new()
                    # RESUME-ATTACH-UNKNOWN-WORDS-1: the LUNs whose attach to no
                    # disk stopped with an error that is not a refusal, said by
                    # the attach's own sentence - never as no disk, never as kept.
                    $unknownLuns = [System.Collections.Generic.List[int]]::new()
                    $unknownWords = [System.Collections.Generic.List[string]]::new()
                    foreach ($s in $part) {
                        $planRow = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                        $onLun = @($liveNow) | Where-Object { $_ -and [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                        $onId = if ($onLun) { [string]$onLun.id } else { '' }
                        if ($onId -and $onId -ieq [string]$s.diskId) { $tookRows.Add([pscustomobject]@{ swap = $s; plan = $planRow }) }
                        elseif ($onId -and $onId -ieq [string]$planRow.currentId) { $halfRows.Add((New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -Why $why -Holds 'had')) }
                        elseif (-not $onId -and $planRow) {
                            # RESTORE-EMPTY-LUN-1: Azure failed between the two
                            # updates and left the LUN with no disk. It gets the
                            # disk made from its copy, or, refused, the disk it had.
                            $fill = Resolve-VmfEmptyDataLun -Context $Context -VmName $VmName -OpName 'restore:swapDataDisks' -Lun ([int]$s.lun) `
                                -WantId ([string]$s.diskId) -WantName ([string]$s.diskName) -SnapshotId ([string]$planRow.snapshotId) `
                                -HadId ([string]$planRow.currentId) -HadName ([string]$planRow.currentName) -Caching ([string](Get-VmfRecordField -Object $s -Name 'caching'))
                            if ($fill.Outcome -eq 'want') { $tookRows.Add([pscustomobject]@{ swap = $s; plan = $planRow }); continue }
                            if ($fill.Unknown) { $unknownLuns.Add([int]$s.lun); $unknownWords.Add(([string]$fill.Why).TrimEnd('.')); $unread.Add([int]$s.lun) }
                            elseif ($fill.Outcome -ne 'fallback') { $emptyLuns.Add([int]$s.lun) }
                            $halfRows.Add((Set-VmfEmptyLunRow -Row (New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -Why ([string]$fill.Why)) -Fill $fill))
                        }
                        else {
                            # RESTORE-THROW-STARTS-1: another disk. Left, so Finish
                            # the restore reads it and refuses it before any change.
                            $holds = "LUN $($s.lun) holds the disk '$(if ($onLun -and [string]$onLun.name) { [string]$onLun.name } else { $onId })' now - not the disk it had, nor the disk made from its copy"
                            $otherWords.Add($holds)
                            $otherRows.Add((New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -SnapshotId ([string]$planRow.snapshotId) -Why "$($why.TrimEnd('.')). $holds." -Holds 'other'))
                            $other.Add([int]$s.lun)
                        }
                    }
                    & $tookUsed @($tookRows | ForEach-Object { [string]$_.swap.diskId })
                    foreach ($s in $part) { & $unpend $s.lun }
                    foreach ($tr in $tookRows) {
                        $replaced.Add([pscustomobject][ordered]@{ lun = [int]$tr.swap.lun; previousDiskId = [string]$tr.plan.currentId; previousDiskName = [string]$tr.plan.currentName
                                newDiskId = [string]$tr.swap.diskId; newDiskName = [string]$tr.swap.diskName })
                    }
                    foreach ($hr in $halfRows) { $left.Add($hr) }
                    foreach ($or in $otherRows) { $left.Add($or) }
                    if (-not $halfRows.Count -and -not $otherRows.Count) {
                        & $say 'info' "The data disks were restored from the safety copy: $(@($tookRows | ForEach-Object { "LUN $($_.swap.lun) now uses '$($_.swap.diskName)'" }) -join ', '). The disks they used before are kept."
                        continue
                    }
                    $saidRows = @($halfRows | Where-Object { [int]$_.lun -notin $unknownLuns })
                    $notBack = @(@($(if ($saidRows.Count) { Format-VmfSwapLeft -Swaps $saidRows -EmptyLuns @($emptyLuns) })) + @($unknownWords) + @($otherWords) | Where-Object { $_ })
                    & $say 'warn' "The data disk swap took on some LUNs and not others. $(if ($tookRows.Count) { "Back from the safety copy: $(@($tookRows | ForEach-Object { "LUN $($_.swap.lun) '$($_.swap.diskName)'" }) -join ', '). " })Not back: $($notBack -join '; '). Azure said: $($why -replace '^The data disk swap did not finish: ', '')"
                    continue
                }
                # RESTORE-THROW-STARTS-1: the read failed, so no LUN of this
                # batch is proven back. Each is left with the disk that waits
                # for it, and so is each LUN of a later batch: the restore does
                # not swap them now, and the machine stays stopped (the caller).
                foreach ($s in $part) {
                    $planRow = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                    $left.Add((New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -SnapshotId ([string]$planRow.snapshotId) `
                            -Why "$($why.TrimEnd('.')). The product could not read the data disks after it ($readWhy), so it does not know which disk is on LUN $($s.lun)." -Holds 'notRead'))
                    $unread.Add([int]$s.lun)
                    & $unpend $s.lun
                }
                foreach ($later in @($batches | Select-Object -Skip ($b + 1))) {
                    foreach ($s in @($later.Swaps)) {
                        $planRow = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                        $left.Add((New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -SnapshotId ([string]$planRow.snapshotId) `
                                -Why "$($why.TrimEnd('.')). The restore stopped at an earlier data disk swap, so it did not swap the disk '$($s.diskName)' made from its copy onto LUN $($s.lun)." -Holds 'had'))
                        & $unpend $s.lun
                    }
                }
                & $say 'fail' "$($why.TrimEnd('.')). The product could not read the data disks after it ($readWhy). The machine stays stopped, and the record names each data disk that is left: $(@($left | ForEach-Object { "LUN $($_.lun)" }) -join ', ')."
                return (& $done $why)
            }
            if (-not $swapped.Applied) {
                # Not applied after every try: the swap put the current disks
                # back on their LUNs. SWAP-REFUSED-AFTER-STOP-1: left, and the
                # machine stays stopped (the caller), never started like that.
                $leftRows = @($part | ForEach-Object {
                        $s = $_
                        $planRow = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                        New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$planRow.currentId) -Why ([string]$swapped.Reason) -Holds 'had' })
                foreach ($leftRow in $leftRows) { $left.Add($leftRow); $refused.Add([int]$leftRow.lun); & $unpend $leftRow.lun }
                & $say 'warn' "Azure did not swap these data disks back after $script:VmfSwapRefusedTries tries: $(Format-VmfSwapLeft -Swaps $leftRows). Azure said: $($swapped.Reason)."
                continue
            }
            & $tookUsed @($part | ForEach-Object { [string]$_.diskId })
            foreach ($s in $part) {
                & $unpend $s.lun
                $row = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
                $replaced.Add([pscustomobject][ordered]@{ lun = [int]$s.lun; previousDiskId = [string]$row.currentId; previousDiskName = [string]$row.currentName
                        newDiskId = [string]$s.diskId; newDiskName = [string]$s.diskName })
            }
            & $say 'info' "The data disks were restored from the safety copy: $(@($part | ForEach-Object { "LUN $($_.lun) now uses '$($_.diskName)'" }) -join ', '). The disks they used before are kept."
        }
        return (& $done $null)
    }

    # preserve: one disk at a time. Every disk left is said as it is left.
    # RESTORE-INLOOP-TEMP-1: first, every LUN has its temporary disk, made
    # from the copy before the stop - or nothing here changes. The machine is
    # stopped, and its OS disk can be back from the copy already, so a LUN
    # left as it is would start it with disks from two moments: the error is
    # marked, and the caller leaves the machine stopped.
    $noTemp = @(Get-VmfDataLunsWithoutTemp -Rows $rows -TempMade $TempMade -AlreadyOnTemp $AlreadyOnTemp)
    if ($noTemp.Count) {
        $madeTemp = @($rows | Where-Object { -not $AlreadyOnTemp.ContainsKey([int]$_.lun) -and [string]$TempMade[[int]$_.lun] } | ForEach-Object { "'$($_.tempName)'" })
        $noTempWhy = "The restore changed no data disk, and the machine stays stopped. $(@($noTemp | ForEach-Object { "LUN $($_.lun) '$($_.currentName)'" }) -join ', ') $(if ($noTemp.Count -eq 1) { 'has' } else { 'have' }) no temporary disk made from the copy. Every data disk is restored from its copy, or the machine does not start." +
            $(if ($madeTemp.Count) { " The disks made from the copy are kept: $($madeTemp -join ', ')." } else { '' })
        try { Write-VmfStepLine -RunPath $Context.RunPath -Step 'restore' -Outcome fail -VmId $Context.VmId -Detail $noTempWhy } catch { $null = $_ }
        $noTempStop = [System.InvalidOperationException]::new($noTempWhy)
        $noTempStop.Data['vmfRestoreStranded'] = $true
        throw $noTempStop
    }
    foreach ($k in @($Plan.Kept)) { & $say 'warn' "The data disk '$($k.name)' on LUN $($k.lun) is left as it is. $($k.why)" }
    # Re-review: each LUN whose temporary disk exists and is not on it yet.
    # FINISH-EMPTY-LUN-WORDS-1: -Holds, what is on the LUN as the caller found it.
    $tempRowOf = { param($r, $id, [string]$holds = '')
        New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = [int]$r.lun; diskId = [string]$id; diskName = [string]$r.tempName; name = [string]$r.currentName
                caching = $(if (Get-VmfRecordField -Object $r -Name 'instantAccess') { 'None' } else { $null }); instantAccess = [bool](Get-VmfRecordField -Object $r -Name 'instantAccess')
                snapshotId = [string]$r.snapshotId }) `
            -OldDiskId ([string]$r.currentId) -Temporary -Holds $holds }
    foreach ($r in $rows) { if (-not $AlreadyOnTemp.ContainsKey([int]$r.lun) -and $TempMade.ContainsKey([int]$r.lun)) { & $pend (& $tempRowOf $r $TempMade[[int]$r.lun] 'notRead') } }
    for ($i = 0; $i -lt $rows.Count; $i++) {
        $row = $rows[$i]
        $lun = [int]$row.lun
        # SAFETY-ULTRA-1: Premium SSD v2 and Ultra Disk take no host caching.
        $rowCaching = if (Get-VmfRecordField -Object $row -Name 'instantAccess') { 'None' } else { $null }
        $stopHere = {
            param($why, $ownLeft = $false)
            if (-not $ownLeft) { $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$row.currentName; why = $why }) }
            foreach ($later in @($rows | Select-Object -Skip ($i + 1))) {
                # RESTORE-THROW-STARTS-1: a LUN already on its temporary disk
                # runs on the copy's moment, and is said so.
                if ($AlreadyOnTemp.ContainsKey([int]$later.lun)) {
                    $kept.Add([pscustomobject]@{ lun = [int]$later.lun; name = [string]$later.currentName
                            why = "The restore stopped at an earlier data disk. This LUN runs on the temporary disk '$($later.tempName)', made from the copy, and the disk '$($later.currentName)' is kept." })
                    continue
                }
                # Re-review (the same rule): a LUN not touched holds the disk
                # it had while the others came back from the copy. Its
                # temporary disk was made before the stop (RESTORE-INLOOP-TEMP-1:
                # every LUN here has one), so it is left on record and the
                # machine stays stopped; Finish the restore puts that disk on.
                # ROLLBACK-DISKS-FIRST-1: a disk that bills is named.
                $laterRow = & $tempRowOf $later $TempMade[[int]$later.lun] 'had'
                $laterRow.why = "The restore stopped at an earlier data disk, so this disk is not touched. The disk made from its copy is kept: '$($later.tempName)'."
                $left.Add($laterRow); & $unpend $later.lun
            }
            & $say 'fail' "LUN ${lun}: $why"
            & $done "LUN ${lun}: $why"
        }
        if ($AlreadyOnTemp.ContainsKey($lun)) { $tempId = [string]$AlreadyOnTemp[$lun] }
        else {
        # 1 and 2 - the sharing read and the temporary disk - ran before the
        # stop (New-VmfOperatorTempDataDisks, RESTORE-INLOOP-TEMP-1).
        $tempId = [string]$TempMade[$lun]
        # 3. On the LUN. Refused: nothing changed, and the current disk stays.
        # FINISH-EMPTY-LUN-PROOF-1: the temporary disk is made from the copy.
        $tempSwap = [pscustomobject]@{ lun = $lun; diskId = $tempId; diskName = $row.tempName; name = [string]$row.currentName; caching = $rowCaching
            instantAccess = [bool](Get-VmfRecordField -Object $row -Name 'instantAccess'); snapshotId = [string]$row.snapshotId }
        $onTemp = $null
        try {
            & $began
            $onTemp = Invoke-VmfDataDiskSwap -Context $Context -VmName $VmName -OpName 'restore:swapTempData' -Swaps @($tempSwap)
        }
        catch {
            # Re-review: the swap onto the temporary disk did not finish, so
            # the LUN is not proven on the copy - left on record (Finish reads
            # the LUN and refuses one it does not recognise).
            $stepWhy = $_.Exception.Message
            # RESTORE-EMPTY-LUN-1: a LUN Azure left with no disk between the two
            # updates gets the temporary disk, or, refused, the disk it had -
            # then this LUN goes on as a swap that took or one Azure refused.
            $fill = & $fillIfEmpty $lun @{ OpName = 'restore:swapTempData'; WantId = [string]$tempId; WantName = [string]$row.tempName
                SnapshotId = [string]$row.snapshotId; HadId = [string]$row.currentId; HadName = [string]$row.currentName; Caching = [string]$rowCaching }
            if ($fill -and $fill.Outcome -eq 'want') { $onTemp = @{ Applied = $true } }
            elseif ($fill -and $fill.Outcome -eq 'fallback') { $onTemp = @{ Applied = $false; Reason = [string]$fill.Why } }
            else {
                $leftRow = & $tempRowOf $row $tempId
                if ($fill -and $fill.Outcome -eq 'holds') {
                    # Read, and on a disk: said as that disk.
                    # Re-check: only the disk the LUN had is its name; a third
                    # disk is named in why alone (Finish refuses it by its ID).
                    if ([string]$fill.Id -ieq [string]$leftRow.oldDiskId) { $leftRow.name = [string]$fill.Name; $leftRow.lunHolds = 'had' } else { $other.Add($lun); $leftRow.lunHolds = 'other' }
                    $leftRow.why = & $holdsWhy $stepWhy $fill
                }
                else {
                    $leftRow.why = $(if ($fill) { [string]$fill.Why } else { $stepWhy })
                    if (-not $fill) { $unread.Add($lun); $leftRow.lunHolds = 'notRead' }
                    if ($fill) { $leftRow = Set-VmfEmptyLunRow -Row $leftRow -Fill $fill }
                    # RESUME-ATTACH-UNKNOWN-WORDS-1: an attach with no answer
                    # leaves the LUN not read, so the restore never ends on it
                    # as a disk it keeps.
                    if ($fill -and $fill.Unknown) { $unread.Add($lun) }
                }
                $left.Add($leftRow); & $unpend $lun
                return (& $stopHere $leftRow.why $true)
            }
        }
        if (-not $onTemp.Applied) {
            # SWAP-REFUSED-AFTER-STOP-1: refused after every try. The LUN
            # keeps its disk, nothing is deleted, and the machine stays
            # stopped (the caller); the other LUNs go on.
            $leftRow = New-VmfSwapLeftRow -Swap $tempSwap -OldDiskId ([string]$row.currentId) -Why ([string]$onTemp.Reason) -Temporary -Holds 'had'
            $left.Add($leftRow)
            $refused.Add($lun)
            & $unpend $lun
            & $say 'warn' "Azure did not swap this data disk back after $script:VmfSwapRefusedTries tries: $(Format-VmfSwapLeft -Swaps @($leftRow)). Azure said: $($onTemp.Reason)."
            continue
        }
        }
        # The LUN runs on the copy now (its temporary disk).
        & $tookUsed @($tempId)
        & $unpend $lun
        # 4. Only now is the current disk deleted: it is detached.
        # RESTORE-END-JOB-1: a resume whose earlier job deleted it already
        # goes on at step 5.
        if (-not $CurrentGone.ContainsKey($lun)) {
        try {
            Invoke-VmfAzOperation -Name 'restore:removeOriginalData' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Remove-VmfManagedDisk -ResourceGroupName $row.currentResourceGroup -DiskName $row.currentName
            } | Out-Null
        }
        catch { return (& $stopHere "It runs on the temporary disk '$($row.tempName)', made from the copy. Azure did not delete the disk '$($row.currentName)', so its name is still in use: $($_.Exception.Message)") }
        & $say 'info' "Deleted the data disk '$($row.currentName)' on LUN $lun to reuse its name."
        }
        # 5. The new disk under the old name, where the old disk was.
        $final = New-VmfDataDiskFromCopy -Context $Context -Row $row -DiskName $row.currentName -ResourceGroupName $row.currentResourceGroup `
            -Location $Location -Zone $Zone -OpName 'restore:createDataDisk'
        if (-not $final.Id) { return (& $stopHere "It runs on the temporary disk '$($row.tempName)', made from the copy. The disk '$($row.currentName)' is deleted, and $($final.Why)") }
        if ($final.Why) { return (& $stopHere "It runs on the temporary disk '$($row.tempName)', made from the copy. The disk '$($row.currentName)' was deleted. $($final.Why)") }
        $finalId = [string]$final.Id
        # 6. On the LUN.
        $onFinal = $null
        try {
            # SWAP-REFUSED-AFTER-STOP-1: tried again too. Still refused, the
            # LUN runs on the temporary disk, which is the copy's moment.
            $onFinal = Invoke-VmfDataDiskSwap -Context $Context -VmName $VmName -OpName 'restore:swapFinalData' `
                -Swaps @([pscustomobject]@{ lun = $lun; diskId = $finalId; diskName = $row.currentName; caching = $rowCaching })
        }
        catch {
            $stepWhy = $_.Exception.Message
            # RESTORE-EMPTY-LUN-1: left with no disk between the two updates,
            # the LUN gets the disk made under its name, or, refused, its
            # temporary disk back - then it goes on as a swap that took or one
            # Azure refused. With neither, it stays on record with no disk.
            $fill = & $fillIfEmpty $lun @{ OpName = 'restore:swapFinalData'; WantId = [string]$finalId; WantName = [string]$row.currentName
                SnapshotId = [string]$row.snapshotId; HadId = [string]$tempId; HadName = [string]$row.tempName; Caching = [string]$rowCaching }
            if ($fill -and $fill.Outcome -eq 'want') { $onFinal = @{ Applied = $true } }
            elseif ($fill -and $fill.Outcome -eq 'fallback') { $onFinal = @{ Applied = $false; Reason = [string]$fill.Why } }
            else {
                # RESTORE-THROW-STARTS-1: the LUN holds a disk, or Azure cannot
                # be read. Either way it is not proven back: left on record
                # with the disk under its name, never kept, so the machine
                # stays stopped and Finish the restore reads the LUN first.
                $finalWhy = if ($fill -and $fill.Outcome -eq 'holds') { & $holdsWhy "The swap of the disk '$($row.currentName)', made from the copy, onto LUN $lun did not finish: $(([string]$stepWhy).TrimEnd('.'))" $fill }
                elseif ($fill) { [string]$fill.Why } else { "The swap of the disk '$($row.currentName)', made from the copy, onto LUN $lun did not finish: $(([string]$stepWhy).TrimEnd('.')). The product did not prove which disk is on LUN $lun now." }
                # FINISH-TEMP-DISK-LEFT-1: the disk the LUN had is its temporary
                # disk (name, oldDiskId, oldTemporary), never the disk under its
                # name - so the Finish dialog names the disk that is on the LUN,
                # and Finish names the temporary disk as free when it is done.
                $finalRow = New-VmfSwapLeftRow -Swap ([pscustomobject]@{ lun = $lun; diskId = [string]$finalId; diskName = [string]$row.currentName; name = [string]$row.tempName
                        caching = $rowCaching; instantAccess = [bool](Get-VmfRecordField -Object $row -Name 'instantAccess'); snapshotId = [string]$row.snapshotId }) `
                    -OldDiskId ([string]$tempId) -Why $finalWhy -OldTemporary
                if ($fill -and $fill.Outcome -eq 'holds') { if ([string]$fill.Id -ieq [string]$tempId) { $finalRow.name = [string]$fill.Name; $finalRow.lunHolds = 'had' } else { $other.Add($lun); $finalRow.lunHolds = 'other' } }
                elseif ($fill) { $finalRow = Set-VmfEmptyLunRow -Row $finalRow -Fill $fill; if ($fill.Unknown) { $unread.Add($lun) } } else { $unread.Add($lun); $finalRow.lunHolds = 'notRead' }
                $left.Add($finalRow)
                return (& $stopHere $finalWhy $true)
            }
        }
        if (-not $onFinal.Applied) {
            return (& $stopHere "It runs on the temporary disk '$($row.tempName)', made from the copy. The new disk '$($row.currentName)' exists and is not attached. Azure did not swap it: $($onFinal.Reason)")
        }
        $replaced.Add([pscustomobject][ordered]@{ lun = $lun; previousDiskId = [string]$row.currentId; previousDiskName = [string]$row.currentName
                newDiskId = [string]$finalId; newDiskName = [string]$row.currentName })
        # 7. The temporary disk goes. If it stays, the restore is still done.
        try {
            Invoke-VmfAzOperation -Name 'restore:removeTempData' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Remove-VmfManagedDisk -ResourceGroupName $Context.Rg -DiskName $row.tempName
            } | Out-Null
            # MADE-DISK-RECORD-1: gone, so no restore names it again.
            Set-VmfMadeDiskMark -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @([string]$tempId) -Field 'deletedUtc'
        }
        catch { & $say 'warn' "The temporary disk '$($row.tempName)' is not attached and was not deleted: $($_.Exception.Message). Delete it when you are sure." }
    }
    if ($replaced.Count) {
        & $say 'info' "The data disks were restored from the safety copy and kept their names: $(@($replaced | ForEach-Object { "LUN $($_.lun) '$($_.newDiskName)'" }) -join ', ')."
    }
    & $done $null
}

function New-VmfOperatorTempDataDisks {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: keeping the names, make the temporary disk of
        each data disk from its copy BEFORE Restore this machine stops the
        machine - steps 1 and 2 of keeping the names. RESTORE-INLOOP-TEMP-1:
        they run only here; Invoke-VmfOperatorDataRestore takes no LUN
        without its temporary disk.
    .DESCRIPTION
        A disk made from a copy needs no stopped machine. A disk that cannot
        be made, or that differs from the record, leaves its LUN as it is -
        the same rule as step 2 - and is returned on Kept with why; the caller
        adds it to the plan, which says each one. Never throws for a disk.
    .OUTPUTS
        @{ Temp = @{ <lun> = <temporary disk id> }; Kept = @(@{ lun; name; why }) }
        A kept row for a temporary disk Azure made and the read-back refused
        also has madeDiskId and madeDiskName (MADE-DISK-NAMED-1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone
    )
    $temp = @{}
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($Plan.Restore)) {
        $lun = [int]$row.lun
        $leave = { param($why, $shared = $false, $refused = $false) $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$row.currentName; shared = [bool]$shared; refused = [bool]$refused; why = $why }) }
        # 1. A shared disk is left, as the put-back leaves it.
        try { $shares = Invoke-VmfAzOperation -Name 'restore:readDataDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation { Get-VmfDiskShareCount -DiskId $row.currentId } }
        catch { & $leave "The product could not read whether other machines share it: $($_.Exception.Message)" $false $true; continue }
        if ([int]$shares -gt 1) { & $leave "It is a shared disk (maxShares $shares), and other machines can use it." $true; continue }
        # 2. The temporary disk, read back (SAFETY-ULTRA-1, SAFETY-CMK-1).
        $made = New-VmfDataDiskFromCopy -Context $Context -Row $row -DiskName $row.tempName -ResourceGroupName $Context.Rg `
            -Location $Location -Zone $Zone -OpName 'restore:createTempData'
        if (-not $made.Id) { & $leave $made.Why $false $true; continue }
        if ($made.Why) {
            # MADE-DISK-NAMED-1: Azure made it, and the read-back refused it.
            # It never goes on the LUN, and it bills: the stop names it.
            $kept.Add([pscustomobject]@{ lun = $lun; name = [string]$row.currentName; shared = $false; refused = $true; why = $made.Why
                    madeDiskId = [string]$made.Id; madeDiskName = [string]$row.tempName })
            continue
        }
        $temp[$lun] = [string]$made.Id
    }
    @{ Temp = $temp; Kept = @($kept) }
}

function Get-VmfDataLunsWithoutTemp {
    <#
    .SYNOPSIS
        RESTORE-INLOOP-TEMP-1: keeping the names, each row of the plan that has
        no temporary disk made from its copy - not on its LUN already
        (-AlreadyOnTemp), not made before the stop (-TempMade) - and is not on
        -Kept, the disks the restore leaves by design. Pure.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter()][AllowNull()][hashtable]$TempMade = @{},
        [Parameter()][AllowNull()][hashtable]$AlreadyOnTemp = @{},
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Kept = @()
    )
    if ($null -eq $TempMade) { $TempMade = @{} }
    if ($null -eq $AlreadyOnTemp) { $AlreadyOnTemp = @{} }
    $keptLuns = @(@($Kept) | Where-Object { $_ } | ForEach-Object { [int]$_.lun })
    @(@($Rows) | Where-Object {
            $_ -and -not [string]$TempMade[[int]$_.lun] -and -not [string]$AlreadyOnTemp[[int]$_.lun] -and [int]$_.lun -notin $keptLuns
        })
}

function Assert-VmfDataTempDisksMade {
    <#
    .SYNOPSIS
        RESTORE-INLOOP-TEMP-1: keeping the names, every data disk the restore
        puts back has its temporary disk, made from its copy, BEFORE the
        machine stops - or the restore stops here, with the machine as it was.
        A disk on -Kept is left by design (a shared disk) or refused already
        (Assert-VmfDataDisksAllBack); any other disk with no temporary disk
        stops the restore, naming each one. It never vanishes from the restore.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter()][AllowNull()][hashtable]$TempMade = @{},
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Kept = @()
    )
    $missing = @(Get-VmfDataLunsWithoutTemp -Rows $Rows -TempMade $TempMade -Kept $Kept)
    if (-not $missing.Count) { return }
    $names = @($missing | ForEach-Object { "'$($_.currentName)' on LUN $($_.lun)" })
    throw "$(if ($missing.Count -eq 1) { 'A data disk has' } else { "$($missing.Count) data disks have" }) no temporary disk made from its copy: $($names -join ', '). Every disk is restored from its copy, or the product changes nothing."
}

function Get-VmfEmptyDataLuns {
    <#
    .SYNOPSIS
        SWAP-2UPD-1: the data disks the machine had before the restore whose
        LUN has NO disk now. A data disk is swapped in two updates, so a swap
        that stopped between them leaves one - and the machine must not start.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter()][AllowEmptyCollection()][object[]]$Before = @()
    )
    $had = @($Before | Where-Object { $_ -and [string]$_.id })
    if (-not $had.Count) { return }
    $now = @(Invoke-VmfAzOperation -Name 'restore:dataDiskInfo' -RunPath $RunPath -VmId $VmId -Operation {
        @(Get-VmfDataDiskInfo -ResourceGroupName $ResourceGroupName -Name $VmName)
    })
    $filled = @($now | Where-Object { $_ } | ForEach-Object { [int]$_.lun })
    @($had | Where-Object { [int]$_.lun -notin $filled })
}

function Format-VmfEmptyDataLuns {
    <# .SYNOPSIS SWAP-2UPD-1: each empty LUN and the disk it had, for a person to attach. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyCollection()][object[]]$Empty = @())
    ((@($Empty) | ForEach-Object { "LUN $($_.lun) has no disk - it had '$($_.name)' ($($_.id))" }) -join '; ') + '. Attach each disk to its LUN, then start the machine'
}

function Invoke-VmfResumableDataRestore {
    <#
    .SYNOPSIS
        RESTORE-END-JOB-1: Invoke-VmfOperatorDataRestore for a restore that may
        be a resume. With -Resuming, the data disks of a job that stopped while
        it swapped them are read first, and each LUN goes on from where it
        stands - never swapped twice, never deleted twice.
    .DESCRIPTION
        Without -Resuming this is Invoke-VmfOperatorDataRestore, unchanged.

        With -Resuming, each LUN the plan restores is read (Get-VmfDataDiskInfo,
        and Get-VmfManagedDiskAttachment for the disk the LUN had):
          new names   on the disk made from its copy: done. On the disk it had:
                      swapped now.
          keeping the names
                      on its temporary disk: goes on from step 4 (the disk it
                      had is deleted, unless it is gone already). On a disk of its own name that was made from the
                      copy: done, and its temporary disk is deleted. On the disk
                      it had (not made from the copy): from step 3.
        A LUN with no disk, or with any other disk, is never guessed: it is
        left on record (Left) with the disk that waits for it, so the machine
        is never started and Finish the restore or a person deals with it -
        the rule Finish has (Complete-VmfDataDiskSwap).
    .OUTPUTS
        What Invoke-VmfOperatorDataRestore returns, with the LUNs already done
        on Replaced and the LUNs that are neither on Left.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][ValidateSet('new', 'preserve')][string]$Naming,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter()][hashtable]$AlreadyOnTemp = @{},
        [Parameter()][AllowNull()][hashtable]$Made,
        [Parameter()][hashtable]$TempMade = @{},
        [Parameter()][AllowNull()][hashtable]$Progress,
        # PRESERVE-USED-MARK-1: passed on (Invoke-VmfOperatorDataRestore).
        [Parameter()][AllowEmptyString()][string]$UsedBy = '',
        [Parameter()][switch]$Resuming
    )
    $pass = @{ Context = $Context; VmName = $VmName; Naming = $Naming; Location = $Location; Zone = $Zone; Progress = $Progress; UsedBy = $UsedBy }
    if (-not $Resuming) {
        return (Invoke-VmfOperatorDataRestore @pass -Plan $Plan -AlreadyOnTemp $AlreadyOnTemp -Made $Made -TempMade $TempMade)
    }
    $rows = @(@($Plan.Restore) | Where-Object { $_ })
    $done = [System.Collections.Generic.List[object]]::new()
    $unknown = [System.Collections.Generic.List[object]]::new()
    # Before anything is read, every LUN the plan restores counts as not
    # proven on its copy: a read that fails here must keep the machine
    # stopped (the caller never starts it on Pending), never start it on
    # disks of two moments. Done holds the LUNs proven done, for the record.
    $tempOf = { param($lunValue) if ($AlreadyOnTemp.ContainsKey([int]$lunValue)) { [string]$AlreadyOnTemp[[int]$lunValue] } elseif ($TempMade.ContainsKey([int]$lunValue)) { [string]$TempMade[[int]$lunValue] } else { '' } }
    # FINISH-EMPTY-LUN-WORDS-1: -Holds, what is on the LUN as the caller found it.
    $waitingRow = { param($r, $why, [string]$holds = '')
        if ($Naming -eq 'new') {
            $s = @(@($Made.Swaps) | Where-Object { $_ -and [int]$_.lun -eq [int]$r.lun }) | Select-Object -First 1
            if (-not $s) { return $null }
            return (New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$r.currentId) -Why $why -Holds $holds)
        }
        $tid = & $tempOf $r.lun
        $w = [pscustomobject]@{ lun = [int]$r.lun; diskId = $tid; diskName = [string]$r.tempName; name = [string]$r.currentName
            caching = $(if (Get-VmfRecordField -Object $r -Name 'instantAccess') { 'None' } else { $null }); instantAccess = [bool](Get-VmfRecordField -Object $r -Name 'instantAccess')
            snapshotId = [string]$r.snapshotId }
        New-VmfSwapLeftRow -Swap $w -OldDiskId ([string]$r.currentId) -Temporary -Why $why -Holds $holds
    }
    if ($null -ne $Progress) {
        $Progress.Began = $true
        $Progress.Left = [System.Collections.Generic.List[object]]::new()
        $Progress.Pending = @{}
        $Progress.Done = $done
        foreach ($r in $rows) { $w = & $waitingRow $r '' 'notRead'; if ($w) { $Progress.Pending[[int]$r.lun] = $w } }
    }
    $settle = { param($lunValue) if ($null -ne $Progress) { $Progress.Pending.Remove([int]$lunValue) } }
    $live = @(Invoke-VmfAzOperation -Name 'restore:dataDiskInfo' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            @(Get-VmfDataDiskInfo -ResourceGroupName $Context.Rg -Name $VmName)
        })
    $onLun = { param($lunValue) $d = @($live) | Where-Object { $_ -and [int]$_.lun -eq [int]$lunValue } | Select-Object -First 1; if ($d) { [string]$d.id } else { '' } }
    $readDisk = { param($id) Invoke-VmfAzOperation -Name 'restore:readDataDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation { Get-VmfManagedDiskAttachment -DiskId $id } }
    $holds = { param($id) if ($id) { "the disk '$(($id -split '/')[-1])'" } else { 'no disk' } }
    $doneRow = { param($r, $newId, $newName)
        & $settle $r.lun
        [pscustomobject][ordered]@{ lun = [int]$r.lun; previousDiskId = [string]$r.currentId; previousDiskName = [string]$r.currentName; newDiskId = [string]$newId; newDiskName = [string]$newName } }
    # Neither: it stays Pending, now with why, so a read that fails after it
    # still keeps the machine stopped with this LUN on record.
    $neither = { param($r, $now)
        $w = & $waitingRow $r "The job stopped while it swapped this data disk, and LUN $($r.lun) holds $(& $holds $now) now - not the disk it had, nor the disk made from its copy." $(if ($now) { 'other' } else { 'none' })
        if ($null -ne $Progress -and $w) { $Progress.Pending[[int]$r.lun] = $w }
        $w }
    $say = { param($detail) Write-VmfStepLine -RunPath $Context.RunPath -Step 'restore' -Outcome info -VmId $Context.VmId -Detail $detail }
    # RESTORE-EMPTY-LUN-1: a LUN with no disk - the job stopped between the
    # two updates of its swap (SWAP-2UPD-1). It gets the disk the record
    # proves belongs there, or, refused, the disk it had (Resolve-VmfEmptyDataLun).
    # $left: the row the record keeps for a LUN that is not done.
    $fillEmpty = { param($r, $wantId, $wantName, $caching, $op)
        Resolve-VmfEmptyDataLun -Context $Context -VmName $VmName -OpName $op -Lun ([int]$r.lun) -WantId ([string]$wantId) -WantName ([string]$wantName) `
            -SnapshotId ([string]$r.snapshotId) -HadId ([string]$r.currentId) -HadName ([string]$r.currentName) -Caching $caching }
    $left = { param($r, $row) if ($null -ne $Progress -and $row) { $Progress.Pending[[int]$r.lun] = $row }; $row }
    $filledWords = { param($r, $wantName) & $say "LUN $($r.lun) had no disk: the job stopped between the two updates of its data disk swap. The disk '$wantName' made from its copy is on it now." }
    $backWords = { param($r, $wantName, $reason) & $say "LUN $($r.lun) had no disk: the job stopped between the two updates of its data disk swap. Azure did not attach the disk '$wantName' made from its copy ($(([string]$reason).TrimEnd('.'))), so the disk '$($r.currentName)' that it had is back on it." }

    if ($Naming -eq 'new') {
        $todo = [System.Collections.Generic.List[object]]::new()
        foreach ($s in @(@($Made.Swaps) | Where-Object { $_ })) {
            $r = $rows | Where-Object { [int]$_.lun -eq [int]$s.lun } | Select-Object -First 1
            $now = & $onLun $s.lun
            if ($now -and $now -ieq [string]$s.diskId) { $done.Add((& $doneRow $r $s.diskId $s.diskName)); continue }
            if ($now -and $r -and $now -ieq [string]$r.currentId) { $todo.Add($s); continue }
            if (-not $now -and $r) {
                $fill = & $fillEmpty $r $s.diskId $s.diskName ([string](Get-VmfRecordField -Object $s -Name 'caching')) 'restore:swapDataDisks'
                if ($fill.Outcome -eq 'want') { & $filledWords $r $s.diskName; $done.Add((& $doneRow $r $s.diskId $s.diskName)); continue }
                $row = Set-VmfEmptyLunRow -Row (New-VmfSwapLeftRow -Swap $s -OldDiskId ([string]$r.currentId) -Why ([string]$fill.Why)) -Fill $fill
                if ($fill.Outcome -eq 'fallback') { & $backWords $r $s.diskName $fill.Reason }
                $unknown.Add((& $left $r $row)); continue
            }
            $unknown.Add((& $neither $r $now))
        }
        $todoLuns = @($todo | ForEach-Object { [int]$_.lun })
        $leftMade = @{ Swaps = @($todo); Kept = @($Made.Kept) }
        $leftPlan = @{ Restore = @($rows | Where-Object { [int]$_.lun -in $todoLuns }); Kept = @($Plan.Kept) }
        $onTemp = $AlreadyOnTemp; $gone = @{}
    }
    else {
        $keep = [System.Collections.Generic.List[object]]::new()
        $onTemp = @{}; foreach ($k in $AlreadyOnTemp.Keys) { $onTemp[[int]$k] = $AlreadyOnTemp[$k] }
        $gone = @{}
        # Its name is on the disk made from the copy: done. Only the temporary
        # disk is left to delete.
        $doneUnderName = { param($r, $tempId)
            if ($tempId) {
                $temp = & $readDisk $tempId
                if ($temp.Exists -and -not [string]$temp.ManagedBy) {
                    try {
                        Invoke-VmfAzOperation -Name 'restore:removeTempData' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                            Remove-VmfManagedDisk -ResourceGroupName $Context.Rg -DiskName ([string]$r.tempName)
                        } | Out-Null
                        Set-VmfMadeDiskMark -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @($tempId) -Field 'deletedUtc'
                    }
                    catch { & $say "The temporary disk '$($r.tempName)' is not attached and was not deleted: $($_.Exception.Message). Delete it when you are sure." }
                }
                elseif (-not $temp.Exists) { Set-VmfMadeDiskMark -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @($tempId) -Field 'deletedUtc' }
            }
            $done.Add((& $doneRow $r $r.currentId $r.currentName))
        }
        foreach ($r in $rows) {
            $lun = [int]$r.lun
            $tempId = & $tempOf $lun
            $now = & $onLun $lun
            if (-not $now -and $tempId) {
                # RESTORE-EMPTY-LUN-1: the LUN gets its temporary disk, made from
                # the copy, and goes on from there as a LUN on its temporary disk
                # does - whichever of its two swaps the job stopped in. Refused,
                # the disk the LUN had goes back: the disk under its name, which
                # is the original before step 4 and the disk made from the copy
                # after step 5.
                $instantCaching = if (Get-VmfRecordField -Object $r -Name 'instantAccess') { 'None' } else { '' }
                $fill = & $fillEmpty $r $tempId $r.tempName $instantCaching 'restore:swapTempData'
                if ($fill.Outcome -eq 'want') { & $filledWords $r $r.tempName; $now = $tempId }
                elseif ($fill.Outcome -eq 'fallback') {
                    $had = & $readDisk ([string]$r.currentId)
                    if ([string]$had.SourceResourceId -ieq [string]$r.snapshotId) {
                        # The disk under its name, made from the copy: done.
                        & $say "LUN $($r.lun) had no disk: the job stopped between the two updates of its data disk swap. Azure did not attach the temporary disk '$($r.tempName)' ($(([string]$fill.Reason).TrimEnd('.'))), so the disk '$($r.currentName)' made from the copy is on it now."
                        & $doneUnderName $r $tempId; continue
                    }
                    & $backWords $r $r.tempName $fill.Reason
                    $unknown.Add((& $left $r (& $waitingRow $r ([string]$fill.Why) 'had'))); continue
                }
                else { $unknown.Add((& $left $r (Set-VmfEmptyLunRow -Row (& $waitingRow $r ([string]$fill.Why)) -Fill $fill))); continue }
            }
            if ($tempId -and $now -and $now -ieq $tempId) {
                # On its temporary disk: from step 4. The disk it had is gone
                # already, or the disk under its name was made from the copy.
                $onTemp[$lun] = $tempId
                $had = & $readDisk ([string]$r.currentId)
                if (-not $had.Exists -or [string]$had.SourceResourceId -ieq [string]$r.snapshotId) { $gone[$lun] = $true }
                $keep.Add($r); continue
            }
            if ($now -and $now -ieq [string]$r.currentId) {
                $had = & $readDisk ([string]$r.currentId)
                if ([string]$had.SourceResourceId -ieq [string]$r.snapshotId) { & $doneUnderName $r $tempId; continue }
                # The disk it had: from step 3.
                $keep.Add($r); continue
            }
            $unknown.Add((& $neither $r $now))
        }
        $leftMade = $Made
        $leftPlan = @{ Restore = @($keep); Kept = @($Plan.Kept) }
    }
    if ($done.Count) { & $say "The data disks a stopped job swapped already are on record: $(@($done | ForEach-Object { "LUN $($_.lun) '$($_.newDiskName)'" }) -join ', ')." }
    try {
        $result = if (@($leftPlan.Restore).Count) {
            Invoke-VmfOperatorDataRestore @pass -Plan $leftPlan -AlreadyOnTemp $onTemp -Made $leftMade -TempMade $TempMade -CurrentGone $gone
        } else { @{ Replaced = @(); Kept = @(@($(if ($Naming -eq 'new' -and $Made) { $Made.Kept } else { $Plan.Kept })) | Where-Object { $_ } | Sort-Object { [int]$_.lun }); Left = @(); Unread = @(); Other = @(); Refused = @(); Failure = $null } }
    }
    catch {
        # The caller never starts the machine on a LUN this could not prove:
        # the inner restore put its own view on Progress, and these join it.
        if ($null -ne $Progress) {
            $Progress.Began = $true
            $Progress.Done = $done
            if ($Progress.Left -is [System.Collections.Generic.List[object]]) { foreach ($u in $unknown) { $Progress.Left.Add($u) } } else { $Progress.Left = @(@($Progress.Left) + @($unknown)) }
        }
        throw
    }
    @{
        Replaced = @(@($done) + @($result.Replaced) | Where-Object { $_ } | Sort-Object { [int]$_.lun })
        Kept     = @($result.Kept)
        Left     = @(@($result.Left) + @($unknown) | Where-Object { $_ } | Sort-Object { [int]$_.lun })
        Unread   = @(@($result.Unread) | Where-Object { $null -ne $_ })
        Other    = @(@($result.Other) | Where-Object { $null -ne $_ })
        Refused  = @(@($result.Refused) | Where-Object { $null -ne $_ })
        Failure  = $result.Failure
    }
}