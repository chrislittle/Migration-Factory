# SAFETY-ALL-1: a safety copy of EVERY disk, not only the OS disk.
#
# The screens and the manual always said "Snapshot of every disk before
# anything is changed". The engine copied the OS disk only. The move itself
# never rewrites a data disk - an in-place upgrade keeps them, a rebuild
# attaches the same ones - so the put-back worked. But:
#   - nothing could bring a data disk back if a step of the move damaged it;
#   - the put-back returned the OS disk to the moment of its copy while the
#     data disks kept everything written after it, so an application with its
#     state on both saw two moments at once.
# Decided 2026-09-29: copy every disk (option 2). Every disk is copied at the
# same stopped moment as the OS disk, and a put-back restores them together.

function Get-VmfDataCopies {
    <#
    .SYNOPSIS
        The data-disk copies on record for one kind: pristine or prepared.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$Doc, [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$Kind)
    $field = if ($Kind -eq 'pristine') { 'pristineDataCopies' } else { 'dataCopies' }
    # One item per copy down the pipeline: callers filter it, and a wrapped
    # array would reach Where-Object as ONE item (found by its own tests).
    if (-not $Doc -or -not $Doc.PSObject.Properties['safety'] -or -not $Doc.safety -or -not $Doc.safety.PSObject.Properties[$field]) { return }
    @($Doc.safety.$field | Where-Object { $_ })
}

# SAFETY-ULTRA-1: Premium SSD v2 and Ultra Disk data disks. SAFETY-ALL-1 took
# their copies and then LEFT them on a put-back, because a new disk of these
# types needs IOPS and throughput the capture did not hold, and a copy of them
# cannot make a disk until Azure has copied it in the background. The rule
# since 2026-10-10: a put-back must go back to the safety copy 100%. So:
#   - PRECHECK reads each such disk by its id and records what a new disk
#     needs (Add-VmfInstantAccessDiskFacts);
#   - the FIRST copy is an instant access snapshot (300 minutes), and the move
#     goes no further until Azure says every such copy is usable - waiting
#     only while the machine is stopped, never while it runs
#     (Wait-VmfInstantAccessCopies);
#   - just before the conversion, a copy with less than 120 minutes of
#     instant access left that is not complete puts the machine back at once
#     (Test-VmfCopyWindowBeforeConversion);
#   - the put-back makes the disk with the recorded values, reads it back and
#     compares, then swaps it in two updates (New-VmfDataDiskFromCopy).
# MEASURED 2026-10-10 (D2s_v4, Ubuntu 22.04; centralus zone 1, swedencentral
# and westus with no zone): every step was accepted for BOTH types, Ultra
# Disk included, and the data on each disk matched the copy moment exactly.
$script:VmfInstantAccessDiskTypes = @{ UltraSSD_LRS = 'Ultra Disk'; PremiumV2_LRS = 'Premium SSD v2' }
# The longest instant access Azure gives (60 to 300 minutes).
$script:VmfInstantAccessMinutes = 300
# How long a stopped machine waits for a copy Azure cannot use yet.
$script:VmfCopyWaitMinutes = 30
# How much instant access must be left before the conversion starts.
$script:VmfCopyMarginMinutes = 120

function Test-VmfDataCopiesComplete {
    <#
    .SYNOPSIS
        Has every data disk the capture recorded got a copy of this kind?
        True for a machine with no data disks.
    .DESCRIPTION
        SAFETY-ULTRA-1: every disk counts for the first copy - it is the way
        back. Only the SECOND copy of a Premium SSD v2 or Ultra Disk does not:
        a person's restore alone uses it, and Azure limits copies of these
        types more than others.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Doc, [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$Kind)
    # Complete means copied AND the lock step finished (locked true, or false
    # where locks are refused). A copy a kill left unlocked is not complete.
    $have = @(Get-VmfDataCopies -Doc $Doc -Kind $Kind | Where-Object { $_.snapshotId -and $null -ne $_.locked } | ForEach-Object { [int]$_.lun })
    foreach ($dd in @($Doc.captured.vmConfig.dataDisks | Where-Object { $_ })) {
        if ($Kind -eq 'prepared' -and $script:VmfInstantAccessDiskTypes.ContainsKey([string]$dd.skuName)) { continue }
        if ($have -notcontains [int]$dd.lun) { return $false }
    }
    $true
}

function Set-VmfDataCopyRecord {
    <#
    .SYNOPSIS
        Record one data-disk copy, merged by LUN into the machine's safety
        record. Never replaces the record (the SAFETY-2 lesson: a replace wiped
        the pristine id once).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$Kind,
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter()][AllowNull()]$Locked,
        # SAFETY-ULTRA-1 (vm-state v20): evidence on an instant access copy -
        # the minutes Azure gave and when it made the copy. Every decision
        # reads the copy again from Azure; nothing decides from these.
        [Parameter()][AllowNull()]$InstantAccessMinutes,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TakenUtc
    )
    $field = if ($Kind -eq 'pristine') { 'pristineDataCopies' } else { 'dataCopies' }
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $safety = if ($doc.PSObject.Properties['safety'] -and $doc.safety) { $doc.safety } else { [pscustomobject]@{ snapshotId = $null; cloneVmId = $null } }
    $old = @(if ($safety.PSObject.Properties[$field]) { @($safety.$field | Where-Object { $_ -and [int]$_.lun -eq $Lun }) }) | Select-Object -First 1
    $list = @(if ($safety.PSObject.Properties[$field]) { @($safety.$field | Where-Object { $_ -and [int]$_.lun -ne $Lun }) })
    $entry = [ordered]@{ lun = $Lun; diskId = $DiskId; snapshotId = $SnapshotId; locked = $Locked }
    # A second write of the same copy (after its lock) keeps the evidence the
    # first write recorded.
    $sameCopy = $old -and [string]$old.snapshotId -eq $SnapshotId
    if ($PSBoundParameters.ContainsKey('InstantAccessMinutes')) { $entry.instantAccessMinutes = $(if ($null -ne $InstantAccessMinutes) { [int]$InstantAccessMinutes } else { $null }) }
    elseif ($sameCopy -and $old.PSObject.Properties['instantAccessMinutes']) { $entry.instantAccessMinutes = $old.instantAccessMinutes }
    if ($PSBoundParameters.ContainsKey('TakenUtc')) { $entry.takenUtc = $(if ($TakenUtc) { $TakenUtc } else { $null }) }
    elseif ($sameCopy -and $old.PSObject.Properties['takenUtc']) { $entry.takenUtc = $(if ($old.takenUtc) { ConvertTo-VmfIsoUtc $old.takenUtc } else { $null }) }
    $list += [pscustomobject]$entry
    $safety | Add-Member -NotePropertyName $field -NotePropertyValue @($list | Sort-Object { [int]$_.lun }) -Force
    $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}

function Invoke-VmfDataDiskCopies {
    <#
    .SYNOPSIS
        Copy every data disk the capture recorded, on a STOPPED machine, and
        lock each copy. Idempotent: a copy on record is not taken again, and a
        copy asked for by an existing name comes back as that copy.
    .OUTPUTS
        The number of data disks copied or already on record.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$Kind,
        [Parameter()][AllowNull()]$Tags
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $disks = @($doc.captured.vmConfig.dataDisks | Where-Object { $_ })
    $location = [string]$doc.captured.vmConfig.location
    $attempt = Get-VmfSafetyAttempt -Doc $doc
    $done = 0
    foreach ($dd in $disks) {
        $lun = [int]$dd.lun
        $onRecord = Get-VmfDataCopies -Doc $doc -Kind $Kind | Where-Object { [int]$_.lun -eq $lun -and $_.snapshotId } | Select-Object -First 1
        if ($onRecord -and $null -ne $onRecord.locked) { $done++; continue }

        # Not $name: Invoke-VmfAzOperation has a -Name parameter, and inside its
        # -Operation block $name is THAT (found by the tests - every copy was
        # named after the operation).
        $copyName = Get-VmfSafetyCopyName -VmName $Context.VmName -RunId $Context.RunId -Kind $Kind -Attempt $attempt -Lun $lun
        # SAFETY-ULTRA-1: the FIRST copy of a Premium SSD v2 or Ultra Disk is
        # an instant access snapshot, so a put-back can make a disk from it at
        # once. The second copy stays an ordinary one: only a person's restore
        # uses it, and an instant access copy adds a restore fee.
        $iaWord = $script:VmfInstantAccessDiskTypes[[string]$dd.skuName]
        $instant = [bool]$iaWord -and $Kind -eq 'pristine'
        # SAFETY-CMK-1: the copy asks for the disk's own encryption.
        $encArgs = Get-VmfEncryptionArgs -Disk $dd
        try {
            $snapId = Invoke-VmfAzOperation -Name "$($Kind)DataSnapshot" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                if ($instant) {
                    New-VmfInstantAccessSnapshot -ResourceGroupName $Context.Rg -SnapshotName $copyName `
                        -DiskId ([string]$dd.managedDiskId) -Location $location -Minutes $script:VmfInstantAccessMinutes -Tags $Tags @encArgs
                }
                else {
                    New-VmfOsDiskSnapshot -ResourceGroupName $Context.Rg -SnapshotName $copyName `
                        -OsDiskId ([string]$dd.managedDiskId) -Location $location -Tags $Tags @encArgs
                }
            }
        }
        catch {
            # SAFETY-ULTRA-1: a first copy Azure refuses stops the move, for
            # EVERY disk type - it is the rollback. Only the second copy of
            # these two types is a warning: nothing automatic uses it.
            if (-not $iaWord -or $instant -or $_.Exception.Message -match 'abandon this VM') { throw }
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'SAFETY_COPY' -Outcome warn -VmId $Context.VmId `
                -Detail "No second copy of the data disk '$($dd.name)' on LUN $lun. Its disk type is $iaWord, and Azure did not make the copy: $($_.Exception.Message). A rollback uses the first copy, and it was taken."
            continue
        }
        # The minutes Azure gave and when it made the copy, as evidence. A
        # read that fails records nothing: the check after the copies reads
        # the copy again, and decides from that.
        $evidence = @{}
        if ($instant) {
            $evidence = @{ InstantAccessMinutes = $null; TakenUtc = $null }
            try {
                $access = Invoke-VmfAzOperation -Name 'readSafetyCopy' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                    Get-VmfSnapshotAccess -SnapshotId $snapId
                }
                $evidence = @{ InstantAccessMinutes = $access.instantAccessDurationMinutes; TakenUtc = [string]$access.timeCreated }
            }
            catch { if ($_.Exception.Message -match 'abandon this VM') { throw } }
        }
        # On record BEFORE the lock (SAFETY-RETRY-1), so a failed lock never
        # leaves a copy Azure holds and the record does not.
        Set-VmfDataCopyRecord -RunPath $Context.RunPath -VmId $Context.VmId -Kind $Kind -Lun $lun `
            -DiskId ([string]$dd.managedDiskId) -SnapshotId $snapId -Locked $null @evidence
        $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
        $locked = Invoke-VmfSafetyCopyLock -Context $Context -SnapshotId $snapId -SnapshotName $copyName -Doc $doc
        Set-VmfDataCopyRecord -RunPath $Context.RunPath -VmId $Context.VmId -Kind $Kind -Lun $lun `
            -DiskId ([string]$dd.managedDiskId) -SnapshotId $snapId -Locked $locked
        $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
        $done++
    }
    $done
}

function Get-VmfDataRestorePlan {
    <#
    .SYNOPSIS
        Which data disks a put-back restores from their pristine copies (or,
        for a person's restore, the copies of the kind they chose), and which
        it leaves as they are, with the reason. Pure: no Azure.
    .DESCRIPTION
        A disk is restored when its pristine copy is on record, is a copy of
        the disk the capture names, and the capture says its type. It is left
        as it is:
          - with no copy on record (a disk attached after the copies, or a
            copy named by its id), or a copy of another disk;
          - with no type recorded (PRECHECK stops such a machine,
            diskTypeNotKnown, so this is refused, never guessed);
          - SAFETY-ULTRA-1, on Premium SSD v2 or Ultra Disk, unless both
            captures name the same one of the two types, this attempt's
            capture holds its IOPS, throughput and sector size, and Azure says
            its copy is usable now (-CopyReadiness, read before the machine
            stops). Values that are not on record leave the disk as it is,
            refused.
        Each is said in the put-back's record - never skipped in silence. Each
        why is whole sentences: the event puts it after the disk's name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][string]$Stamp,
        # RESTORE-ALL-1: Restore this machine uses the copy a person chose.
        [Parameter()][ValidateSet('pristine', 'prepared')][string]$Kind = 'pristine',
        # PREP-ROLLBACK-1 (review F8): the disks-only rollback before the move
        # makes each disk on the type it has NOW (this attempt's capture). The
        # first capture's type would be a change after a retry, not a rollback.
        [Parameter()][switch]$AttemptShape,
        # SAFETY-ULTRA-1: snapshot id -> what Azure said about that copy
        # (Get-VmfInstantAccessCopyReadiness). No entry is no answer, and no
        # answer is never usable.
        [Parameter()][AllowNull()][hashtable]$CopyReadiness
    )
    $restore = [System.Collections.Generic.List[object]]::new()
    $kept = [System.Collections.Generic.List[object]]::new()
    $copies = @(Get-VmfDataCopies -Doc $Doc -Kind $Kind)
    # ROLLBACK-RETRY-CAPTURE-1: the disks of THIS attempt - its copies are of
    # them - each on the type the FIRST capture recorded for its LUN, as the
    # OS disk is (Get-VmfPutBackCapture). After a retry the attempt may have
    # found a disk the move changed to Premium SSD, on a first size that takes
    # none.
    $attemptType = @{}
    $attemptDisk = @{}
    foreach ($d in @($Doc.captured.vmConfig.dataDisks | Where-Object { $_ })) { $attemptType[[int]$d.lun] = [string]$d.skuName; $attemptDisk[[int]$d.lun] = $d }
    $shape = if ($AttemptShape) { $Doc.captured.vmConfig } else { Get-VmfPutBackCapture -Doc $Doc }
    foreach ($dd in @($shape.dataDisks | Where-Object { $_ })) {
        $lun = [int]$dd.lun
        $name = [string]$dd.name
        $copy = $copies | Where-Object { [int]$_.lun -eq $lun -and $_.snapshotId } | Select-Object -First 1
        # Member access reads a field of an object and a key of a hashtable
        # alike (TYPECHANGE-CHECK-1: PSObject.Properties misses hashtable keys).
        $sku = [string]$dd.skuName
        # SAFETY-ULTRA-MARGIN-1: a disk that HAS a copy and still cannot come
        # back from it is refused; one with no copy on record (attached after
        # the copies, or a copy named by its id) is left by design.
        $keep = { param($why, $refused = $true) $kept.Add([pscustomobject]@{ lun = $lun; name = $name; refused = [bool]$refused; why = $why }) }
        if (-not $copy) { & $keep 'No copy of it is on record.' $false; continue }
        if ([string]$copy.diskId -and [string]$dd.managedDiskId -and [string]$copy.diskId -ne [string]$dd.managedDiskId) {
            & $keep "Its copy on record is of another disk, '$($copy.diskId)'."; continue
        }
        if (-not $sku) { & $keep 'Its disk type is not on record.'; continue }
        $row = [pscustomobject]@{
            lun = $lun; name = $name; sourceDiskId = [string]$dd.managedDiskId
            snapshotId = [string]$copy.snapshotId; skuName = $sku
            # The LUN is in the name: two disks whose names differ only past
            # the length Azure allows would otherwise get one name.
            diskName = (Get-VmfBoundedDiskName -BaseName $name -Suffix "-d$lun-asitwas-$Stamp")
        }
        # SAFETY-CMK-1: the key of the disk its copy was taken of - this
        # attempt's capture, as for the values below.
        Add-VmfDiskEncryptionRowFacts -Row $row -Facts $attemptDisk[$lun]
        # SAFETY-ULTRA-1: a Premium SSD v2 or Ultra Disk in EITHER capture.
        $special = @($sku, [string]$attemptType[$lun]) | Where-Object { $_ -and $script:VmfInstantAccessDiskTypes.ContainsKey($_) } | Select-Object -First 1
        if ($special) {
            $why = Get-VmfInstantAccessRestoreRefusal -FirstType $sku -AttemptType ([string]$attemptType[$lun]) `
                -Facts $attemptDisk[$lun] -SnapshotId ([string]$copy.snapshotId) -CopyReadiness $CopyReadiness
            if ($why) { & $keep $why; continue }
            Add-VmfInstantAccessRowFacts -Row $row -Facts $attemptDisk[$lun]
        }
        $restore.Add($row)
    }
    @{ Restore = @($restore); Kept = @($kept) }
}

function Get-VmfInstantAccessRestoreRefusal {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: why a Premium SSD v2 or Ultra Disk data disk cannot
        come back from its copy now - or $null when it can. Pure.
    .DESCRIPTION
        Every why is whole sentences, said after the disk's name. Unknown is
        never a yes: no values on record, no answer about the copy, or an
        answer that the copy is not usable each leaves the disk as it is.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyString()][string]$FirstType,
        [Parameter()][AllowEmptyString()][string]$AttemptType,
        [Parameter()][AllowNull()]$Facts,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter()][AllowNull()][hashtable]$CopyReadiness
    )
    $word = { param($t) if ($script:VmfInstantAccessDiskTypes.ContainsKey($t)) { $script:VmfInstantAccessDiskTypes[$t] } elseif ($t) { $t } else { 'not on record' } }
    if ($AttemptType -and $FirstType -ne $AttemptType) {
        return "Its disk type was $(& $word $FirstType) when the product first read the machine, and it is $(& $word $AttemptType) in this attempt. Azure makes a disk of this type from its copy only as the type that the copy was taken from. Its copy is '$SnapshotId'."
    }
    $missing = @(foreach ($pair in @(@('diskIOPSReadWrite', 'IOPS'), @('diskMBpsReadWrite', 'throughput'), @('logicalSectorSize', 'sector size'))) {
            if ($null -eq (Get-VmfRecordField -Object $Facts -Name $pair[0])) { $pair[1] } })
    if ($missing.Count) {
        return "Its disk type is $(& $word $FirstType), and its $($missing -join ', ') are not on record. Its copy is '$SnapshotId'."
    }
    $ready = if ($CopyReadiness -and $CopyReadiness.ContainsKey($SnapshotId)) { $CopyReadiness[$SnapshotId] } else { $null }
    if (-not $ready) { return "The product did not read whether Azure can make a disk from its copy '$SnapshotId' now." }
    if ([string]$ready.Error) { return "The product could not read its copy '$SnapshotId': $($ready.Error)" }
    if (-not $ready.Usable) {
        return "Azure cannot make a disk from its copy '$SnapshotId' now: the access state is $(if ($ready.State) { $ready.State } else { 'not given' })."
    }
    $null
}

function Add-VmfInstantAccessRowFacts {
    # SAFETY-ULTRA-1: what the new disk is made with, and compared against.
    param([Parameter(Mandatory)]$Row, [Parameter()][AllowNull()]$Facts)
    $add = { param($n, $v) $Row | Add-Member -NotePropertyName $n -NotePropertyValue $v -Force }
    & $add 'instantAccess' $true
    foreach ($n in 'diskIOPSReadWrite', 'diskMBpsReadWrite', 'logicalSectorSize', 'sizeGB') {
        $v = Get-VmfRecordField -Object $Facts -Name $n
        & $add $n $(if ($null -ne $v -and [string]$v -ne '') { [long]$v } else { $null })
    }
    & $add 'diskZones' @(@(Get-VmfRecordField -Object $Facts -Name 'diskZones') | Where-Object { $_ } | ForEach-Object { [string]$_ })
}

function Compare-VmfMadeDiskFacts {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: how the disk Azure made differs from what PRECHECK
        recorded - type, size, zone, IOPS, throughput, sector size. Pure.
        Empty when it matches.
    .DESCRIPTION
        A value Azure did not return is a difference: the put-back puts a disk
        on the machine only when every value is known to match.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter()][AllowNull()]$Got,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone
    )
    if (-not $Got) { return @('Azure returned nothing for it') }
    $diff = [System.Collections.Generic.List[string]]::new()
    if ([string]$Got.skuName -ne [string]$Row.skuName) { $diff.Add("the disk type is $(if ($Got.skuName) { $Got.skuName } else { 'not given' }), not $($Row.skuName)") }
    foreach ($pair in @(@('sizeGB', 'diskSizeGB', 'the size in GiB'), @('diskIOPSReadWrite', 'diskIOPSReadWrite', 'the IOPS'),
                        @('diskMBpsReadWrite', 'diskMBpsReadWrite', 'the throughput in MBps'), @('logicalSectorSize', 'logicalSectorSize', 'the sector size'))) {
        $want = $Row.($pair[0])
        if ($null -eq $want) { continue }
        $have = $Got.($pair[1])
        if ($null -eq $have) { $diff.Add("Azure did not return $($pair[2])"); continue }
        if ([long]$have -ne [long]$want) { $diff.Add("$($pair[2]) is $have, not $want") }
    }
    # The zone the disk had; with none on record, the machine's.
    $wantZones = @(@($Row.diskZones) | Where-Object { $_ })
    if (-not $wantZones.Count -and $Zone) { $wantZones = @($Zone) }
    $haveZones = @(@($Got.zones) | Where-Object { $_ })
    if ((@($wantZones | Sort-Object) -join ',') -ne (@($haveZones | Sort-Object) -join ',')) {
        $diff.Add("the zone is $(if ($haveZones.Count) { $haveZones -join ',' } else { 'none' }), not $(if ($wantZones.Count) { $wantZones -join ',' } else { 'none' })")
    }
    @($diff)
}

function New-VmfDataDiskFromCopy {
    <#
    .SYNOPSIS
        Make one data disk from its copy, for a put-back or a restore. For a
        Premium SSD v2 or Ultra Disk (SAFETY-ULTRA-1): with the recorded IOPS
        and throughput, then read back and compared with the record.
    .OUTPUTS
        @{ Id = <new disk id or $null>; Why = <why it must not go on the
        machine, or $null> }. Id with Why: Azure made a disk that must not be
        used - the caller keeps it on record and keeps the old disk.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter(Mandatory)][string]$OpName
    )
    $instantRow = [bool](Get-VmfRecordField -Object $Row -Name 'instantAccess')
    $iops = if ($instantRow) { Get-VmfRecordField -Object $Row -Name 'diskIOPSReadWrite' } else { $null }
    $mbps = if ($instantRow) { Get-VmfRecordField -Object $Row -Name 'diskMBpsReadWrite' } else { $null }
    # SAFETY-CMK-1: the encryption of the disk the copy was taken of, for every
    # disk type (Add-VmfDiskEncryptionRowFacts). OLD-VERSION-READERS-REMOVE-4:
    # every capture records it; a row without it gets no disk, and the old
    # disk stays.
    $enc = Get-VmfRecordField -Object $Row -Name 'encryption'
    if (-not ($enc -and [string]$enc.type)) {
        return @{ Id = $null; Why = (Get-VmfEncryptionNotOnRecordWords -SnapshotId ([string]$Row.snapshotId) -DiskName $DiskName) }
    }
    $encArgs = @{ EncryptionType = [string]$enc.type; DiskEncryptionSetId = [string]$enc.diskEncryptionSetId }
    try {
        $madeId = Invoke-VmfAzOperation -Name $OpName -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            New-VmfDiskFromSnapshot -ResourceGroupName $ResourceGroupName -DiskName $DiskName -SnapshotId ([string]$Row.snapshotId) `
                -Location $Location -SkuName ([string]$Row.skuName) -Zone $Zone -DiskIopsReadWrite $iops -DiskMBpsReadWrite $mbps @encArgs
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return @{ Id = $null; Why = "Azure did not make a new disk from its copy: $($_.Exception.Message)" }
    }
    # MADE-DISK-RECORD-1: every disk Restore this machine makes is on its
    # record the moment Azure made it, before the read-back - its Azure calls
    # are named 'restore:'. A rollback records its own itself.
    if ($OpName -like 'restore:*') { Add-VmfRestoreDiskRecord -Context $Context -DiskId ([string]$madeId) -DiskName $DiskName -Lun (Get-VmfRecordField -Object $Row -Name 'lun') }
    if (-not $instantRow) {
        # SAFETY-CMK-1: read back and compared like the values below - the
        # disk goes on the machine only when its key is known to match.
        $encWhy = Confirm-VmfMadeDiskEncryption -Context $Context -OpName $OpName -DiskId ([string]$madeId) -DiskName $DiskName -Want $enc
        if ($encWhy) { return @{ Id = [string]$madeId; Why = "$encWhy" } }
        return @{ Id = [string]$madeId; Why = $null }
    }
    try {
        $got = Invoke-VmfAzOperation -Name "$($OpName):readBack" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfManagedDiskFacts -DiskId ([string]$madeId)
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return @{ Id = [string]$madeId; Why = "Azure made the disk '$DiskName', and the product could not read it back to compare it with the record: $(([string]$_.Exception.Message).TrimEnd('.'))." }
    }
    $diff = @(Compare-VmfMadeDiskFacts -Row $Row -Got $got -Zone $Zone)
    # SAFETY-CMK-1: and its encryption, in the same read.
    $encDiff = Get-VmfEncryptionDifference -WantType ([string]$enc.type) -WantSetId ([string]$enc.diskEncryptionSetId) `
        -GotType $(if ($got) { [string]$got.encryptionType } else { '' }) -GotSetId $(if ($got) { [string]$got.diskEncryptionSetId } else { '' })
    if ($encDiff) { $diff += $encDiff }
    if ($diff.Count) {
        return @{ Id = [string]$madeId; Why = "Azure made the disk '$DiskName', but it differs from the record: $($diff -join '; ')." }
    }
    @{ Id = [string]$madeId; Why = $null }
}

function Get-VmfSwapBatches {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: the data-disk swaps in two batches - every other disk
        first, then the Premium SSD v2 and Ultra Disk disks. Pure.
    .DESCRIPTION
        Set-VmfVmDataDisks puts every disk of a batch back when Azure refuses
        the attach, so one refused disk of these types must not keep the
        others from going back. Each batch is two machine updates
        (SWAP-2UPD-1). Returns @(@{ Swaps = @(...) }), empty batches left out.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowEmptyCollection()][object[]]$Swaps = @())
    $plain = @($Swaps | Where-Object { $_ -and -not (Get-VmfRecordField -Object $_ -Name 'instantAccess') })
    $ia = @($Swaps | Where-Object { $_ -and (Get-VmfRecordField -Object $_ -Name 'instantAccess') })
    @(foreach ($b in @($plain, $ia)) { if ($b.Count) { [pscustomobject]@{ Swaps = $b } } })
}

function Assert-VmfDataDisksAllBack {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-MARGIN-1 (2026-10-16): a put-back puts EVERY data
        disk back to its copy, or nothing (the full rollback rule). A disk on
        the kept list that is not a shared disk - one Azure did not make, one
        whose copy cannot be used, one whose sharing could not be read - stops
        the put-back before it changes the machine, naming each disk.
        Only a disk the put-back TRIED to make and could not is refused here
        (marked `refused` where it is made). A disk left by design is not: a
        shared disk (SAFETY-ALL-1), a disk with no copy on record (attached
        after the copies, or a copy named by its id), and the plan's own keeps
        - before a move those are refused up front (ROLLBACK-DISKS-FIRST-1).
        MADE-DISK-NAMED-1: the disks made from copies are named by each
        caller, in ONE list with the OS disk (Get-VmfMadeDataDiskNames) - a
        rollback from its record of the disks it made, a restore in its stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Kept
    )
    $left = @(@($Kept) | Where-Object { $_ -and [bool](Get-VmfRecordField -Object $_ -Name 'refused') })
    if (-not $left.Count) { return }
    $names = @($left | ForEach-Object { "'$($_.name)' on LUN $($_.lun) ($(([string]$_.why).TrimEnd('.')))" })
    throw "$(if ($left.Count -eq 1) { 'A data disk cannot' } else { "$($left.Count) data disks cannot" }) be made from the safety copy: $($names -join '; '). Every disk is restored from its copy, or the product changes nothing."
}

function Get-VmfMadeDataDiskNames {
    <#
    .SYNOPSIS
        MADE-DISK-NAMED-1: every data disk Azure made from a copy for a
        put-back - each disk made to go on the machine (-Made), and each one
        made and then refused on its read-back (a kept row's madeDiskName, set
        where it is made). Each bills, so a stop names each one. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$Made,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Kept
    )
    $refused = @(@($Kept) | Where-Object { $_ } | ForEach-Object { [string](Get-VmfRecordField -Object $_ -Name 'madeDiskName') })
    @(@(@($Made) + $refused) | Where-Object { $_ } | Select-Object -Unique)
}

function Invoke-VmfDataDiskRestore {
    <#
    .SYNOPSIS
        Make a new disk from each pristine data-disk copy the plan names.
        Returns @{ Swaps = @(@{ lun; diskId; diskName; name }); Kept = @(...) }.
        A kept row for a disk Azure made and the read-back refused also has
        madeDiskId and madeDiskName (MADE-DISK-NAMED-1).
        The machine is not changed here - Path A swaps them in, Path B builds
        around them. Called BEFORE any disk is swapped, so a disk Azure will
        not make leaves that disk as it is, never a half-restored machine.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$RestorePlan,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        # RESTORE-ALL-1: the operator's restore uses this too, and its record
        # says 'restore'.
        [Parameter()][ValidateSet('rollback', 'restore')][string]$Step = 'rollback',
        # RECOVER-ALL-DISKS-1: runs with (disk id, disk name, LUN) the moment
        # Azure made each disk - also one the read-back refuses, which bills
        # like any other - so a caller records it before anything can stop.
        [Parameter()][scriptblock]$OnMade
    )
    $opStep = $Step
    $kept = [System.Collections.Generic.List[object]]::new()
    foreach ($k in @($RestorePlan.Kept)) { $kept.Add($k) }
    $swaps = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($RestorePlan.Restore)) {
        # A shared disk (maxShares above 1) is attached to other machines too.
        # A copy on this one would part it from them.
        try {
            $shares = Invoke-VmfAzOperation -Name "${opStep}:readDataDisk" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfDiskShareCount -DiskId $r.sourceDiskId
            }
        }
        catch {
            $kept.Add([pscustomobject]@{ lun = $r.lun; name = $r.name; refused = $true; why = "The product could not read whether other machines share it: $($_.Exception.Message)" })
            continue
        }
        if ([int]$shares -gt 1) {
            $kept.Add([pscustomobject]@{ lun = $r.lun; name = $r.name; shared = $true; why = "It is a shared disk (maxShares $shares), and other machines can use it." })
            continue
        }
        $made = New-VmfDataDiskFromCopy -Context $Context -Row $r -DiskName $r.diskName -ResourceGroupName $Context.Rg `
            -Location $Location -Zone $Zone -OpName "${opStep}:createDataDisk"
        # PREP-ROLLBACK-1 (review F4): on record the moment it exists - also a
        # disk SAFETY-ULTRA-1's read-back refused, which bills like any other.
        if ($made.Id -and $Step -eq 'rollback') { Add-VmfRollbackDiskDuringRollbackRecord -Context $Context -DiskId ([string]$made.Id) -DiskName $r.diskName -Lun $r.lun }
        if ($made.Id -and $OnMade) { & $OnMade ([string]$made.Id) ([string]$r.diskName) ([int]$r.lun) }
        if (-not $made.Id) {
            $kept.Add([pscustomobject]@{ lun = $r.lun; name = $r.name; refused = $true; why = $made.Why })
            continue
        }
        if ($made.Why) {
            # MADE-DISK-NAMED-1: Azure made it, and the read-back refused it.
            # It never goes on the machine, and it bills: every stop names it.
            $kept.Add([pscustomobject]@{ lun = $r.lun; name = $r.name; refused = $true; why = $made.Why
                    madeDiskId = [string]$made.Id; madeDiskName = [string]$r.diskName })
            continue
        }
        $instantRow = [bool](Get-VmfRecordField -Object $r -Name 'instantAccess')
        $swaps.Add([pscustomobject]@{ lun = $r.lun; diskId = [string]$made.Id; diskName = $r.diskName; name = $r.name
                # SAFETY-ULTRA-1: these types take no host caching, and they
                # are swapped in a batch of their own (Get-VmfSwapBatches).
                instantAccess = $instantRow; caching = $(if ($instantRow) { 'None' } else { $null })
                # FINISH-EMPTY-LUN-PROOF-1: the copy it was made from, for the
                # record of a swap that is left (New-VmfSwapLeftRow).
                snapshotId = [string]$r.snapshotId })
    }

    foreach ($k in $kept) {
        # A person's restore is still running: on its step, warn and fail END
        # the page's "putting back" (RESTORE_ENDS), so a disk left is a note.
        Write-VmfStepLine -RunPath $Context.RunPath -Step $Step -Outcome $(if ($Step -eq 'rollback') { 'warn' } else { 'info' }) -VmId $Context.VmId `
            -Detail "The data disk '$($k.name)' on LUN $($k.lun) is left as it is. $($k.why)"
    }
    @{ Swaps = @($swaps); Kept = @($kept) }
}