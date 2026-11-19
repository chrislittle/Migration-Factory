# SWAP-REFUSED-AFTER-STOP-1: a data disk Azure will not swap after the stop.
#
# Every disk a put-back swaps in is made, and read back, before the machine
# stops (ROLLBACK-DISKS-FIRST-1, SAFETY-ULTRA-MARGIN-1). The swap itself can
# only happen on the stopped machine. When Azure refused one, Set-VmfVmDataDisks
# put the old disks back on their LUNs and the rollback or the restore went on
# and STARTED the machine: the OS disk and the other data disks from the copy,
# this one as it was - disks from two moments, which the full rollback rule
# forbids.
#
# The rule since 2026-10-23: a machine MUST always get back to its original
# state. So:
#   1. a refused swap is tried again, through the product's Azure retry
#      (Invoke-VmfAzOperation, which tries an error marked vmfSwapRefused
#      again);
#   2. still refused, the machine is NEVER started: it stays stopped
#      (deallocated), and its record (swapPending, vm-state v25) names every
#      disk left - the disk still on the LUN, and the disk made from its copy
#      that waits to go on - with Azure's words;
#   3. the app offers Finish the rollback or Finish the restore on the machine
#      (Complete-VmfDataDiskSwap, the engine's 'finish' operation). It swaps
#      ONLY the disks that are left, then starts the machine.

# How many times a refused swap is sent, and the first wait between two tries
# (Invoke-VmfAzOperation doubles it: 15 s, then 30 s). The machine is stopped
# and every disk it needs exists, so a minute of waiting costs nothing that a
# machine started with disks from two moments would not cost more.
$script:VmfSwapRefusedTries = 3
$script:VmfSwapRefusedDelayMs = 15000

function Invoke-VmfDataDiskSwap {
    <#
    .SYNOPSIS
        One batch of data-disk swaps on a stopped machine, tried again while
        Azure refuses it. Returns @{ Applied; Reason }.
    .DESCRIPTION
        Set-VmfVmDataDisks says "not applied" when Azure refused the swap and
        every old disk is back on its LUN - nothing changed, so sending it again
        is safe. That answer is turned into an error marked vmfSwapRefused, which
        Invoke-VmfAzOperation tries again ($script:VmfSwapRefusedTries times in
        all). A swap left neither way (SWAP-2UPD-1) throws, and is never tried
        again; nor is any other error.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # RunPath, VmId and Rg.
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$OpName,
        [Parameter(Mandatory)][object[]]$Swaps
    )
    $part = @($Swaps)
    try {
        Invoke-VmfAzOperation -Name $OpName -RunPath $Context.RunPath -VmId $Context.VmId `
            -MaxAttempts $script:VmfSwapRefusedTries -BaseDelayMs $script:VmfSwapRefusedDelayMs -Operation {
            $answer = Set-VmfVmDataDisks -ResourceGroupName $Context.Rg -Name $VmName -Swaps $part
            if (-not $answer.Applied) {
                $refused = [System.InvalidOperationException]::new("Azure did not swap the data disks: $($answer.Reason)")
                $refused.Data['vmfSwapRefused'] = $true
                $refused.Data['vmfSwapReason'] = [string]$answer.Reason
                throw $refused
            }
            $answer
        }
    }
    catch {
        if ($_.Exception.Data -and $_.Exception.Data['vmfSwapRefused']) {
            return @{ Applied = $false; Reason = [string]$_.Exception.Data['vmfSwapReason'] }
        }
        throw
    }
}

function New-VmfSwapLeftRow {
    <#
    .SYNOPSIS
        One data disk a swap left: the LUN, the disk still on it, and the disk
        made from its copy that waits to go on. Pure.
    .DESCRIPTION
        FINISH-EMPTY-LUN-PROOF-1 (vm-state v28): the row names the copy the
        disk that waits was made from (snapshotId) - the swap's own, or
        -SnapshotId. Finish attaches that disk to a LUN with no disk only when
        Azure says it was made from this copy (Invoke-VmfEmptyLunAttach), as
        the restore's resume does. Every swap of this version names its copy,
        and vm-state v48 requires it: Finish proves nothing for a row with
        none (Test-VmfEmptyLunWant).

        FINISH-EMPTY-LUN-WORDS-1 (vm-state v38): the row says what is on its
        LUN (lunHolds), as the caller found it - had: the disk it names
        (name, oldDiskId); none: no disk; notRead: the product did not read
        the LUN after a swap that did not finish; other: a disk that is
        neither. No -Holds is null only until the caller sets it:
        Set-VmfEmptyLunRow sets it for a LUN found with no disk, and every
        other caller passes it or sets it (MIGRATIONS-PAGE-OLD-READERS-1);
        vm-state v48 requires it on every row a record keeps.
        FINISH-TEMP-DISK-LEFT-1: -OldTemporary - keeping the names, the disk
        on the LUN is the temporary disk made from the copy (step 6), so
        Finish names it as free when the disk under the old name goes on.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Swap,
        [Parameter()][AllowEmptyString()][string]$OldDiskId = '',
        [Parameter()][AllowEmptyString()][string]$Why = '',
        # Keeping the names: the disk that waits is the temporary one.
        [Parameter()][switch]$Temporary,
        # The copy the disk that waits was made from, when the swap does not name it.
        [Parameter()][AllowEmptyString()][string]$SnapshotId = '',
        # FINISH-EMPTY-LUN-WORDS-1: what is on the LUN now, as the caller found it.
        [Parameter()][ValidateSet('', 'had', 'none', 'notRead', 'other')][string]$Holds = '',
        # FINISH-TEMP-DISK-LEFT-1: the disk on the LUN is the temporary disk.
        [Parameter()][switch]$OldTemporary
    )
    $caching = [string](Get-VmfRecordField -Object $Swap -Name 'caching')
    $copy = [string](Get-VmfRecordField -Object $Swap -Name 'snapshotId')
    if (-not $copy) { $copy = $SnapshotId }
    [pscustomobject][ordered]@{
        lun           = [int]$Swap.lun
        name          = [string]$Swap.name
        oldDiskId     = $(if ($OldDiskId) { $OldDiskId } else { $null })
        diskId        = [string]$Swap.diskId
        diskName      = [string]$Swap.diskName
        snapshotId    = $(if ($copy) { $copy } else { $null })
        caching       = $(if ($caching) { $caching } else { $null })
        instantAccess = [bool](Get-VmfRecordField -Object $Swap -Name 'instantAccess')
        temporary     = [bool]$Temporary
        oldTemporary  = [bool]$OldTemporary
        lunHolds      = $(if ($Holds) { $Holds } else { $null })
        why           = $(if ($Why) { $Why } else { $null })
    }
}

function Format-VmfSwapLeft {
    <#
    .SYNOPSIS
        Each data disk a swap left, in words: the disk the LUN keeps, and the
        disk made from its copy that is not on it. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Swaps = @(),
        # RESTORE-EMPTY-LUN-1: the LUNs that have no disk now - said as no
        # disk, never as the disk they had.
        [Parameter()][AllowEmptyCollection()][int[]]$EmptyLuns = @()
    )
    (@($Swaps | Where-Object { $_ } | Sort-Object { [int]$_.lun } | ForEach-Object {
                if ([int]$_.lun -in $EmptyLuns) { "LUN $($_.lun) has no disk, and the disk '$($_.diskName)' made from its copy waits to go on it" }
                else { "LUN $($_.lun) keeps '$($_.name)', not the disk '$($_.diskName)' made from its copy" }
            }) -join '; ')
}

function Format-VmfSwapLeftUnread {
    <#
    .SYNOPSIS
        RESTORE-THROW-STARTS-1: the data disks left on LUNs the product did
        not read after a data disk swap that threw, in words. Pure.
    .DESCRIPTION
        Such a LUN can hold the disk it had, the disk made from its copy, or
        no disk. So it is never said as a disk it keeps: Finish the restore
        reads it before it changes anything.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyCollection()][object[]]$Swaps = @())
    $rows = @($Swaps | Where-Object { $_ } | Sort-Object { [int]$_.lun })
    if (-not $rows.Count) { return '' }
    "A data disk swap did not finish, and the product did not read which disk is on these LUNs after it: $(@($rows | ForEach-Object { "LUN $($_.lun), where the disk '$($_.diskName)' made from its copy waits to go on" }) -join '; ')."
}

function Format-VmfRestoreSwapLeftWords {
    <#
    .SYNOPSIS
        The sentence a restore ends on when data disks are left: each disk
        Azure did not swap back with Azure's words, each LUN with no disk with
        why, and Finish the restore. Pure.
    .DESCRIPTION
        RESTORE-EMPTY-LUN-1: a LUN with no disk (-EmptyLuns) is said with the
        sentence its row keeps - it names the LUN, the disk that waits and why
        - never as a disk it keeps, and never as a step to do in Azure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Swaps = @(),
        [Parameter()][AllowEmptyCollection()][int[]]$EmptyLuns = @(),
        # RESTORE-THROW-STARTS-1: the LUNs the data restore did not read after
        # a swap that threw. A LUN found empty since is said as empty.
        [Parameter()][AllowEmptyCollection()][int[]]$Unread = @(),
        # Re-check: the LUNs that hold a third disk, said by their why.
        [Parameter()][AllowEmptyCollection()][int[]]$Other = @(),
        # FINISH-EMPTY-LUN-WORDS-1: the LUNs whose swap Azure refused on every
        # try. Only these are said "after 3 tries": a swap that threw, and a
        # LUN of a later batch the restore did not swap, were not tried so.
        [Parameter()][AllowEmptyCollection()][int[]]$Refused = @()
    )
    $rows = @($Swaps | Where-Object { $_ } | Sort-Object { [int]$_.lun })
    $plain = @($rows | Where-Object { [int]$_.lun -notin $EmptyLuns -and [int]$_.lun -notin $Unread -and [int]$_.lun -notin $Other })
    $third = @($rows | Where-Object { [int]$_.lun -notin $EmptyLuns -and [int]$_.lun -notin $Unread -and [int]$_.lun -in $Other })
    $notRead = @($rows | Where-Object { [int]$_.lun -notin $EmptyLuns -and [int]$_.lun -in $Unread })
    $empty = @($rows | Where-Object { [int]$_.lun -in $EmptyLuns })
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($notRead.Count) { $parts.Add((Format-VmfSwapLeftUnread -Swaps $notRead)) }
    foreach ($o in $third) { $parts.Add(([string]$o.why).TrimEnd('.') + '.') }
    $refusedRows = @($plain | Where-Object { [int]$_.lun -in $Refused })
    $notBack = @($plain | Where-Object { [int]$_.lun -notin $Refused })
    if ($refusedRows.Count) {
        $parts.Add("Azure did not swap these data disks back after $script:VmfSwapRefusedTries tries: $(Format-VmfSwapLeft -Swaps $refusedRows). Azure said: $(([string]$refusedRows[-1].why).TrimEnd('.')).")
    }
    if ($notBack.Count) {
        $parts.Add("These data disks are not back: $(Format-VmfSwapLeft -Swaps $notBack). $(([string]$notBack[-1].why).TrimEnd('.')).")
    }
    foreach ($e in $empty) {
        # RESTORE-THROW-STARTS-1: the why of a LUN not read is about the read,
        # so a LUN found empty since is said as empty.
        $parts.Add($(if ([string]$e.why -and [int]$e.lun -notin $Unread) { ([string]$e.why).TrimEnd('.') + '.' } else { (Format-VmfSwapLeft -Swaps @($e) -EmptyLuns $EmptyLuns) + '.' }))
    }
    $finish = Get-VmfFinishActionName -Kind 'restore'
    $what = if ($empty.Count) { 'It puts on only the disks that are left, then starts the machine.' } else { 'It swaps only the disks that are left, then starts the machine.' }
    "The restore did not finish, and the machine is left stopped: $($parts -join ' ') The machine never starts with disks from two moments. Use $finish on this machine. $what"
}

function Get-VmfFinishActionName {
    <#
    .SYNOPSIS
        The name of the action that finishes a put-back a refused swap left:
        the words the dashboard's button shows. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind)
    if ($Kind -eq 'rollback') { 'Finish the rollback' } else { 'Finish the restore' }
}

function New-VmfSwapPendingRecord {
    <#
    .SYNOPSIS
        The record of a put-back a refused swap left (vm-state v25,
        swapPending). Pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Swaps,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason,
        # The mark a put-back rollback disk gets when it goes on
        # (Set-VmfRollbackDisksBeforeMoveUsed): 'rollback-<time>', 'restore', or none.
        [Parameter()][AllowEmptyString()][string]$UsedBy = '',
        # The data disks this put-back did swap, each @{ lun; diskId; diskName }.
        [Parameter()][AllowEmptyCollection()][object[]]$Swapped = @(),
        # FINISH-KEPT-DISKS-1 (vm-state v29): each data disk this put-back keeps
        # as it is by design (a shared disk, a disk with no copy, ...), each
        # @{ lun; name; why }. In the same write as the swaps, so the record
        # Finish reads accounts for every data disk on its own: a job killed
        # before the rollback's or the restore's own record left it without them.
        [Parameter()][AllowEmptyCollection()][object[]]$Kept = @(),
        # FINISH-NO-RESTORE-RECORD-1 (vm-state v32): the engine operation of
        # the restore that left the swap - the id its own record (restore) and
        # its checkpoint (putBackJob) carry. A rollback names none.
        [Parameter()][AllowEmptyString()][string]$OperationId = '',
        # POWER-AFTER-MOVE-1 (vm-state v39): a restore - the power state it
        # found when it started, which Finish the restore returns the machine to.
        [Parameter()][AllowEmptyString()][AllowNull()][string]$PowerAtStart = ''
    )
    $rec = [ordered]@{
        kind    = $Kind
        leftUtc = (Get-Date).ToUniversalTime().ToString('o')
        error   = $Reason
        usedBy  = $(if ($UsedBy) { $UsedBy } else { $null })
        swaps   = @($Swaps | Where-Object { $_ })
        swapped = @(@($Swapped) | Where-Object { $_ } | ForEach-Object { [ordered]@{ lun = [int]$_.lun; diskId = [string]$_.diskId; diskName = [string]$_.diskName } })
        kept    = @(@($Kept) | Where-Object { $_ } | Sort-Object { [int]$_.lun } | ForEach-Object { [ordered]@{ lun = [int]$_.lun; name = [string]$_.name; why = [string]$_.why } })
    }
    if ($OperationId) { $rec['operationId'] = $OperationId }
    if ($PowerAtStart) { $rec['powerAtStart'] = $PowerAtStart }
    $rec
}

function Get-VmfSwapPending {
    <#
    .SYNOPSIS
        The machine's record of a put-back a refused swap left, or $null. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $sp = Get-VmfRecordField -Object $Doc -Name 'swapPending'
    if ($sp) { $sp } else { $null }
}

function Set-VmfSwapPending {
    <#
    .SYNOPSIS
        Write the record of a put-back a refused swap left - or, with no
        -Record, remove it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowNull()]$Record
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if ($Record) {
        $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue $Record -Force
    }
    elseif ($doc.PSObject.Properties['swapPending']) { $doc.PSObject.Properties.Remove('swapPending') }
    else { return }
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}

function Get-VmfSwapPendingRefusal {
    <#
    .SYNOPSIS
        The sentence that refuses an action on a machine a refused swap left
        stopped, or $null. Pure. One copy: a restore, a retry and a decision
        all ask it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc, [Parameter()][string]$VmName = 'this machine')
    $sp = Get-VmfSwapPending -Doc $Doc
    if (-not $sp) { return $null }
    $kind = if ([string]$sp.kind -eq 'restore') { 'restore' } else { 'rollback' }
    $action = Get-VmfFinishActionName -Kind $kind
    "Azure did not swap every data disk of '$VmName' back, so the machine is stopped. Use $action on this machine first: it swaps only the disks that are left, then starts the machine."
}

function Add-VmfSwapFinished {
    <#
    .SYNOPSIS
        Record the data disks Azure swapped back for a put-back a refused swap
        left: off swapPending.swaps, onto swapPending.swapped and onto the
        rollback's or the restore's own record of the disks it put on - in one
        write, the moment Azure took them (rule 4).
    .DESCRIPTION
        A rollback disk is marked used first
        (Set-VmfRollbackDisksBeforeMoveUsed): it is the machine's own disk from here, and a
        job that stops between the two writes finds the LUN on that disk and
        records it then.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][object[]]$Rows
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $sp = Get-VmfSwapPending -Doc $doc
    if (-not $sp) { return }
    if ([string]$sp.usedBy) {
        Set-VmfRollbackDisksBeforeMoveUsed -RunPath $RunPath -VmId $VmId -DiskIds @($Rows | ForEach-Object { [string]$_.diskId }) -By ([string]$sp.usedBy)
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
        $sp = Get-VmfSwapPending -Doc $doc
    }
    $luns = @($Rows | ForEach-Object { [int]$_.lun })
    $sp.swaps = @(@($sp.swaps) | Where-Object { $_ -and [int]$_.lun -notin $luns })
    $sp | Add-Member -NotePropertyName swapped -Force -NotePropertyValue @(
        @(@(Get-VmfRecordField -Object $sp -Name 'swapped') | Where-Object { $_ -and [int]$_.lun -notin $luns }) +
        @($Rows | ForEach-Object { [pscustomobject][ordered]@{ lun = [int]$_.lun; diskId = [string]$_.diskId; diskName = [string]$_.diskName } }) |
            Sort-Object { [int]$_.lun })
    if ([string]$sp.kind -eq 'restore') {
        # FINISH-NO-RESTORE-RECORD-1: only the record of the restore that left
        # the swap. An earlier restore's record is never added to: Finish writes
        # this restore's record when it ends (Save-VmfFinishedRestore).
        $rec = Get-VmfSwapRestoreRecord -Doc $doc
        if ($rec) {
            $rec | Add-Member -NotePropertyName dataDisks -Force -NotePropertyValue @(
                @(@(Get-VmfRecordField -Object $rec -Name 'dataDisks') | Where-Object { $_ -and [int]$_.lun -notin $luns }) +
                @($Rows | ForEach-Object {
                        # FINISH-TEMP-DISK-LEFT-1: keeping the names, a LUN that ran
                        # on its temporary disk gets the disk under its old name -
                        # the same name and id it had before the restore, as step 6
                        # records it. The temporary disk is not a disk the machine
                        # had, so the record never names it as one, and the daily
                        # cleanup deletes it (Get-VmfDeletableMadeDisks).
                        $fromTemp = [bool](Get-VmfRecordField -Object $_ -Name 'oldTemporary')
                        [pscustomobject][ordered]@{ lun = [int]$_.lun
                            previousDiskId = $(if ($fromTemp) { [string]$_.diskId } else { [string]$_.oldDiskId }); previousDiskName = $(if ($fromTemp) { [string]$_.diskName } else { [string]$_.name })
                            newDiskId = [string]$_.diskId; newDiskName = [string]$_.diskName } }) | Sort-Object { [int]$_.lun })
        }
    }
    else {
        $rec = Get-VmfRecordField -Object $doc -Name 'rollback'
        # ROLLBACK-ORIGINALS-LEFT-1: the disk each swap took off the machine,
        # in the same write.
        Add-VmfRollbackOriginalsOnDoc -Doc $doc -DataDisks @($Rows)
        if ($rec) {
            $rec | Add-Member -NotePropertyName dataDisks -Force -NotePropertyValue @(
                @(@(Get-VmfRecordField -Object $rec -Name 'dataDisks') | Where-Object { $_ -and [int]$_.lun -notin $luns }) +
                @($Rows | ForEach-Object { [pscustomobject][ordered]@{ lun = [int]$_.lun; diskId = [string]$_.diskId; diskName = [string]$_.diskName } }) | Sort-Object { [int]$_.lun })
        }
    }
    $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue $sp -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}

function Save-VmfSwapPendingChecked {
    <#
    .SYNOPSIS
        SWAP-REFUSED-AFTER-STOP-1 (re-review): write the record of the data
        disks a swap left, then read it back. A write that fails, or a record
        that does not hold them, throws an error marked vmfSwapLeftUnrecorded,
        and the rollback never starts the machine on it: only a record the
        product read back proves what Finish the rollback must swap.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)]$Record,
        # ROLLBACK-EMPTY-LUN-1: the disks left, in the caller's words - a LUN
        # with no disk is said as no disk, never as the disk it had.
        [Parameter()][AllowEmptyString()][string]$Words = ''
    )
    $want = (@(@($Record.swaps) | ForEach-Object { [int]$_.lun } | Sort-Object) -join ',')
    $why = $null
    try {
        Set-VmfSwapPending -RunPath $RunPath -VmId $VmId -Record $Record
        $back = Get-VmfSwapPending -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId)
        $got = if ($back) { (@(@($back.swaps) | Where-Object { $_ } | ForEach-Object { [int]$_.lun } | Sort-Object) -join ',') } else { $null }
        if ($got -ne $want) { $why = 'the record read back does not hold them' }
    }
    catch { $why = $_.Exception.Message }
    if (-not $why) { return }
    $words = if ($Words) { $Words.TrimEnd('.') } else { Format-VmfSwapLeft -Swaps @($Record.swaps) }
    $unrecorded = [System.InvalidOperationException]::new("The record of the data disks that are left could not be written ($why): $words.")
    $unrecorded.Data['vmfSwapLeftUnrecorded'] = $true
    $unrecorded.Data['vmfSwapLeftWords'] = $words
    throw $unrecorded
}
