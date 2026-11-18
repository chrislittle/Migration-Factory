# RESTORE-EMPTY-LUN-1: a LUN that a data disk swap left with NO disk.
#
# Azure swaps a data disk in two updates (SWAP-2UPD-1, Set-VmfVmDataDisks):
# detach the disk on the LUN, then attach the other one. Between them the LUN
# has no disk. A job that stopped there (the platform stopped the container),
# or a swap Azure failed between the two updates, left it so - and the only way
# forward was to attach the disk in Azure, outside the app. Hard rule 12 does
# not allow that, and the rule is that a machine always gets back to
# one moment: its original state, every time.
#
# So the product finishes the swap from where it stands:
#   1. The disk that belongs on the LUN is the disk the swap was putting on it
#      - the disk made from its copy (or, keeping the names, the temporary disk
#      made from it). It is attached only when the record PROVES it: the disk
#      exists, is attached to nothing, and was made from the copy the record
#      names. Any other answer attaches nothing: the machine stays stopped, and
#      the words name the LUN, the disk and the disk the LUN had.
#   2. The LUN gets the settings it had: its caching (the swap's own caching
#      first - None for Premium SSD v2 and Ultra Disk), delete option and write
#      accelerator, as the restore's checkpoint read them before it changed
#      anything (Get-VmfEmptyLunSettings).
#   3. If Azure refuses the disk, the disk the LUN had goes back on it - as
#      Set-VmfVmDataDisks puts the old disks back - and the swap is left on
#      record: the machine stays stopped, and Finish the restore swaps it.

function Get-VmfEmptyLunSettings {
    <#
    .SYNOPSIS
        The caching, delete option and write accelerator a LUN with no disk
        gets its disk back with. Pure.
    .DESCRIPTION
        From the record, never guessed:
          caching           the swap's own caching (-Caching: None for Premium
                            SSD v2 and Ultra Disk); else the LUN as the
                            restore's checkpoint read it before the job changed
                            anything (putBackJob.before); else the caching the
                            capture recorded for the LUN.
          delete option,    the LUN as the checkpoint read it. Not named when
          write accelerator the checkpoint did not read them: the capture is
                            from before the move.
        -Rollback (ROLLBACK-EMPTY-LUN-1): a rollback writes no putBackJob, and
        a putBackJob on the record is an earlier restore's - never this LUN as
        the rollback found it. So the caching is the swap's own, else the
        capture's (this attempt's: a move never changes a data disk), and the
        delete option and Write Accelerator are the capture's
        (writeAcceleratorEnabled, captured per data disk since REBUILD-PROPS-1),
        as Set-VmfVmDataDisks keeps the LUN's own. A capture with no such field
        names none, and Azure keeps its default.
    .OUTPUTS
        @{ Caching; DeleteOption; WriteAccelerator }, or $null when the record
        holds no caching for the LUN.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][int]$Lun,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Caching = '',
        [Parameter()][switch]$Rollback
    )
    if ($Rollback) {
        $capturedDisk = @(@(Get-VmfRecordField -Object (Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'vmConfig') -Name 'dataDisks') |
                Where-Object { $_ -and [int]$_.lun -eq $Lun }) | Select-Object -First 1
        $use = if ($Caching) { $Caching } else { [string](Get-VmfRecordField -Object $capturedDisk -Name 'caching') }
        if (-not $use) { return $null }
        return [pscustomobject]@{ Caching = $use; DeleteOption = [string](Get-VmfRecordField -Object $capturedDisk -Name 'deleteOption'); WriteAccelerator = [bool](Get-VmfRecordField -Object $capturedDisk -Name 'writeAcceleratorEnabled') }
    }
    # FINISH-END-JOB-1: the restore's record, also under a finish over it.
    $job = Get-VmfPutBackJobBehind -Doc $Doc
    $slot = @(@(Get-VmfRecordField -Object (Get-VmfRecordField -Object $job -Name 'before') -Name 'dataDisks') |
            Where-Object { $_ -and [int]$_.lun -eq $Lun }) | Select-Object -First 1

    $captured = @(@(Get-VmfRecordField -Object (Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'vmConfig') -Name 'dataDisks') |
            Where-Object { $_ -and [int]$_.lun -eq $Lun }) | Select-Object -First 1
    $slotCaching = [string](Get-VmfRecordField -Object $slot -Name 'caching')
    $capturedCaching = [string](Get-VmfRecordField -Object $captured -Name 'caching')
    $use = if ($Caching) { $Caching } elseif ($slotCaching) { $slotCaching } else { $capturedCaching }
    if (-not $use) { return $null }
    $fromSlot = [bool]$slot
    [pscustomobject]@{
        Caching          = $use
        DeleteOption     = $(if ($fromSlot) { [string](Get-VmfRecordField -Object $slot -Name 'deleteOption') } else { '' })
        WriteAccelerator = $(if ($fromSlot) { [bool](Get-VmfRecordField -Object $slot -Name 'writeAcceleratorEnabled') } else { $false })
    }
}

function New-VmfEmptyLunUnproven {
    <#
    .SYNOPSIS
        The answer for a disk the record does not prove belongs on a LUN with
        no disk: the sentence names the LUN, why, and the disk the LUN had.
        Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][AllowEmptyString()][string]$HadName = ''
    )
    $had = if ($HadName) { " LUN $Lun had the disk '$HadName'." } else { '' }
    @{ Outcome = 'unproven'; Reason = $Reason
       Why = "LUN $Lun has no disk. $Reason$had The product attaches only a disk that its record proves, so the machine stays stopped." }
}

function New-VmfEmptyLunUnknown {
    <#
    .SYNOPSIS
        FINISH-ATTACH-UNKNOWN-WORDS-1: what Invoke-VmfEmptyLunAttach returns
        when the attach to a LUN with no disk stopped with an error that is
        not a refusal. Pure.
    .DESCRIPTION
        Not a refusal: the machine could not be read, before or after the
        update, or the LUN holds another disk now. Azure did not refuse the
        disk, so the sentence never says so, nor that it tried 3 times; and
        which disk is on the LUN now is not known, so it never says the LUN
        has no disk. The disk the LUN had is not attached either. Outcome
        stays empty (the LUN is not done), with Unknown set: the row then
        says notRead (Set-VmfEmptyLunRow), and Finish reads the LUN before it
        changes anything.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WantName,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Reason,
        [Parameter()][AllowEmptyString()][string]$HadName = ''
    )
    $had = if ($HadName) { " So it did not attach the disk '$HadName' that LUN $Lun had." } else { '' }
    @{ Outcome = 'empty'; Unknown = $true; Reason = $Reason
       Why = "The attach of the disk '$WantName' made from its copy to LUN $Lun stopped with an error that is not a refusal from Azure: $($Reason.TrimEnd('.')). The product does not know which disk is on LUN $Lun now.$had" }
}

function Test-VmfEmptyLunWant {
    <#
    .SYNOPSIS
        Does the record prove the disk that waits for a LUN with no disk? $null
        when it does; else what New-VmfEmptyLunUnproven returns.
    .DESCRIPTION
        The ONE proof (FINISH-EMPTY-LUN-PROOF-1): the restore's resume
        (Invoke-VmfEmptyLunAttach) and Finish the restore / Finish the rollback
        (Complete-VmfDataDiskSwap, before anything changes) both ask it. The
        disk (-Want: id, name, snapshotId) exists, no machine holds it, and
        Azure says it was made from the copy the record names
        (creationData.sourceResourceId). A record that names no copy proves
        nothing (OLD-STATE-READERS-FINISH-1: every row a swap of this version
        leaves names its copy). A disk made from another copy is Foreign: it is not the disk the
        product made. A lost lease ('abandon this VM') is thrown, never said
        as a disk the product could not read (LEASE-LOST-EMPTY-LUN-1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # RunPath and VmId.
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$ReadOpName,
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)]$Want,
        [Parameter()][AllowEmptyString()][string]$HadName = ''
    )
    $wantName = [string]$Want.name
    $no = { param($why) New-VmfEmptyLunUnproven -Lun $Lun -HadName $HadName -Reason $why }
    if (-not [string]$Want.id) { return (& $no "The record names no disk made from its copy for LUN $Lun.") }
    if (-not [string]$Want.snapshotId) { return (& $no "The record names no copy that the disk '$wantName' was made from.") }
    $wantId = [string]$Want.id
    try { $w = Invoke-VmfAzOperation -Name $ReadOpName -RunPath $Context.RunPath -VmId $Context.VmId -Operation { Get-VmfManagedDiskAttachment -DiskId $wantId } }
    catch {
        # LEASE-LOST-EMPTY-LUN-1: a lost lease is not an answer about the disk.
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return (& $no "The product could not read the disk '$wantName' made from its copy: $($_.Exception.Message)")
    }
    if (-not $w.Exists) { return (& $no "The disk '$wantName' made from its copy does not exist.") }
    if ([string]$w.ManagedBy) { return (& $no "The disk '$wantName' made from its copy is attached to '$($w.ManagedBy)'.") }
    if ([string]$w.SourceResourceId -ine [string]$Want.snapshotId) {
        # The disk with that id is not the disk the product made: the record
        # must not name it as the disk that waits (Foreign).
        $foreign = & $no "The disk '$wantName' was made from '$($w.SourceResourceId)', not from the copy '$($Want.snapshotId)'."
        $foreign.Foreign = $true
        return $foreign
    }
    $null
}

function Invoke-VmfEmptyLunAttach {
    <#
    .SYNOPSIS
        Put the disk the record proves belongs on a LUN with no disk, on a
        stopped machine. If Azure refuses it, put the disk the LUN had back.
    .DESCRIPTION
        -Want is the disk the swap was putting on the LUN (id, name, and the
        copy it must be made from - snapshotId). It is attached
        only if it exists, is attached to nothing, and was made from that copy.
        -Fallback is the disk the LUN had (id, name). Each attach is tried again
        while Azure refuses it ($script:VmfSwapRefusedTries in all), as a data
        disk swap is (Invoke-VmfDataDiskSwap). Never throws for a disk.
        LEASE-LOST-EMPTY-LUN-1: a lost lease ('abandon this VM', from the
        heartbeat before each Azure call) is thrown, from each read and each
        attach, as every other engine catch does: the worker that lost it
        attaches nothing more, and its caller writes no record.
    .OUTPUTS
        @{ Outcome; Why; Reason }:
          want      the disk is on the LUN.
          fallback  Azure refused it, and the disk the LUN had is back on it.
                    Reason: Azure's words.
          empty     the LUN still has no disk: Azure refused both, or the disk
                    the LUN had cannot go back. Reason: why.
                    Unknown (FINISH-ATTACH-UNKNOWN-WORDS-1): the attach stopped
                    with an error that is not a refusal, so which disk is on
                    the LUN is not known (New-VmfEmptyLunUnknown). Why: its
                    sentence. Nothing else is attached.
          unproven  nothing was attached: the record does not prove the disk.
                    Why: a sentence that names the LUN and both disks.
                    Foreign: the disk with that id was made from another copy,
                    so it is not the disk the product made, and the record
                    must not name it as the disk that waits.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        # RunPath, VmId and Rg.
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$VmName,
        # The names of the attach and of the disk reads in the run's log: the
        # page has words for each (restore:swapDataDisks, restore:readDataDisk).
        [Parameter(Mandatory)][string]$OpName,
        [Parameter(Mandatory)][string]$ReadOpName,
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)]$Want,
        [Parameter()][AllowNull()]$Fallback,
        [Parameter()][AllowNull()]$Settings
    )
    $wantName = [string]$Want.name
    $hadName = if ($Fallback -and [string]$Fallback.id) { [string]$Fallback.name } else { '' }
    if (-not $Settings) { return (New-VmfEmptyLunUnproven -Lun $Lun -HadName $hadName -Reason "The record holds no caching for LUN $Lun, so the product cannot attach the disk '$wantName' as the LUN had it.") }
    $read = {
        param($id)
        Invoke-VmfAzOperation -Name $ReadOpName -RunPath $Context.RunPath -VmId $Context.VmId -Operation { Get-VmfManagedDiskAttachment -DiskId $id }
    }
    # FINISH-EMPTY-LUN-PROOF-1: one proof for the resume and for Finish.
    $notProven = Test-VmfEmptyLunWant -Context $Context -ReadOpName $ReadOpName -Lun $Lun -Want $Want -HadName $hadName
    if ($notProven) { return $notProven }
    # RESTORE-POWER-READ-1: not $name. Inside the -Operation block, $name is
    # Invoke-VmfAzOperation's own -Name, so the disk was named after the
    # operation (restore:swapDataDisks).
    $attach = {
        param($id, $diskName)
        try {
            Invoke-VmfAzOperation -Name $OpName -RunPath $Context.RunPath -VmId $Context.VmId `
                -MaxAttempts $script:VmfSwapRefusedTries -BaseDelayMs $script:VmfSwapRefusedDelayMs -Operation {
                $answer = Add-VmfVmDataDiskOnEmptyLun -ResourceGroupName $Context.Rg -Name $VmName -Lun $Lun -DiskId $id -DiskName $diskName `
                    -Caching ([string]$Settings.Caching) -DeleteOption ([string]$Settings.DeleteOption) -WriteAccelerator:([bool]$Settings.WriteAccelerator)
                if (-not $answer.Applied) {
                    $refused = [System.InvalidOperationException]::new("Azure did not attach the disk: $($answer.Reason)")
                    $refused.Data['vmfSwapRefused'] = $true
                    $refused.Data['vmfSwapReason'] = [string]$answer.Reason
                    throw $refused
                }
                $answer
            } | Out-Null
            @{ Applied = $true }
        }
        catch {
            # LEASE-LOST-EMPTY-LUN-1: another worker holds the machine now, so
            # this one stops at once and writes nothing more to its record.
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            if ($_.Exception.Data -and $_.Exception.Data['vmfSwapRefused']) { return @{ Applied = $false; Reason = [string]$_.Exception.Data['vmfSwapReason'] } }
            # Not a refusal (a read that failed, another disk on the LUN): where
            # the LUN stands is not known, so nothing else is attached.
            @{ Applied = $false; Reason = $_.Exception.Message; Unknown = $true }
        }
    }
    $first = & $attach ([string]$Want.id) $wantName
    if ($first.Applied) { return @{ Outcome = 'want' } }
    $reason = [string]$first.Reason
    if ($first.Unknown) { return (New-VmfEmptyLunUnknown -Lun $Lun -WantName $wantName -Reason $reason -HadName $hadName) }
    # Refused: the disk the LUN had goes back on it, as Set-VmfVmDataDisks puts
    # the old disks back. Only a disk that exists and is attached to nothing.
    if ($hadName) {
        $f = $null
        try { $f = & $read ([string]$Fallback.id) }
        catch {
            # LEASE-LOST-EMPTY-LUN-1: a lost lease is not "could not read".
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $f = $null
        }
        if ($f -and $f.Exists -and -not [string]$f.ManagedBy) {
            $back = & $attach ([string]$Fallback.id) $hadName
            if ($back.Applied) { return @{ Outcome = 'fallback'; Reason = $reason } }
            $reason = "$($reason.TrimEnd('.')). The disk '$hadName' that LUN $Lun had was not attached to it again either: $($back.Reason)"
        }
        elseif ($f -and -not $f.Exists) { $reason = "$($reason.TrimEnd('.')). The disk '$hadName' that LUN $Lun had does not exist, so it cannot be attached again." }
        elseif ($f) { $reason = "$($reason.TrimEnd('.')). The disk '$hadName' that LUN $Lun had is attached to '$($f.ManagedBy)', so it cannot be attached again." }
        else { $reason = "$($reason.TrimEnd('.')). The product could not read the disk '$hadName' that LUN $Lun had, so it did not attach it again." }
    }
    @{ Outcome = 'empty'; Reason = $reason }
}

function Set-VmfEmptyLunRow {
    <#
    .SYNOPSIS
        The row the record keeps for a LUN that is still left after
        Invoke-VmfEmptyLunAttach (New-VmfSwapLeftRow), as it now stands. Pure.
    .DESCRIPTION
        A LUN with no disk keeps the caching it is to have, for Finish the
        restore. A disk made from another copy is not named as the disk that
        waits (Foreign): Finish then refuses the LUN, and nothing attaches it.
        After fallback the LUN holds the disk it had: the row is a plain swap.
        FINISH-EMPTY-LUN-WORDS-1: the row says so (lunHolds) - had after
        fallback, else none - so the Finish dialog says what is on the LUN.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Row,
        [Parameter(Mandatory)][hashtable]$Fill
    )
    # FINISH-ATTACH-UNKNOWN-WORDS-1: after an attach with no answer, which
    # disk is on the LUN is not known (notRead), never "no disk".
    $holds = if ($Fill.Outcome -eq 'fallback') { 'had' } elseif ($Fill.Unknown) { 'notRead' } else { 'none' }
    $Row | Add-Member -NotePropertyName lunHolds -NotePropertyValue $holds -Force
    if ($Fill.Outcome -eq 'fallback') { return $Row }
    if ([string]$Fill.Caching) { $Row.caching = [string]$Fill.Caching }
    if ($Fill.Foreign) { $Row.diskId = '' }
    $Row
}

function Resolve-VmfEmptyDataLun {
    <#
    .SYNOPSIS
        A LUN with no disk, part way through a data disk swap of a restore or
        a rollback (-Kind): the settings from the machine's record, then
        Invoke-VmfEmptyLunAttach.
    .DESCRIPTION
        For the empty and unproven outcomes, Why is the sentence the record
        keeps for the LUN, and Caching the caching it is to have: Finish the
        restore attaches the disk with it (Complete-VmfDataDiskSwap). The
        caller's row names no disk that waits when Foreign is set
        (Set-VmfEmptyLunRow).
    .OUTPUTS
        What Invoke-VmfEmptyLunAttach returns, with Why for every outcome but
        want, and Caching.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$OpName,
        [Parameter(Mandatory)][int]$Lun,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WantId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$WantName,
        [Parameter()][AllowEmptyString()][string]$SnapshotId = '',
        [Parameter()][AllowEmptyString()][string]$HadId = '',
        [Parameter()][AllowEmptyString()][string]$HadName = '',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Caching = '',
        # ROLLBACK-EMPTY-LUN-1: the rollback's own swap. Its settings come from
        # the capture (Get-VmfEmptyLunSettings -Rollback), and its disk reads
        # are said as the rollback's in the run's log.
        [Parameter()][ValidateSet('restore', 'rollback')][string]$Kind = 'restore'
    )
    $doc = $null
    try { $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId } catch { $doc = $null }
    $settings = Get-VmfEmptyLunSettings -Doc $doc -Lun $Lun -Caching $Caching -Rollback:($Kind -eq 'rollback')
    $result = Invoke-VmfEmptyLunAttach -Context $Context -VmName $VmName -OpName $OpName -ReadOpName "${Kind}:readDataDisk" -Lun $Lun `
        -Want @{ id = $WantId; name = $WantName; snapshotId = $SnapshotId } -Fallback $(if ($HadId) { @{ id = $HadId; name = $HadName } } else { $null }) -Settings $settings
    $result.Caching = if ($settings) { [string]$settings.Caching } else { $null }
    switch ($result.Outcome) {
        'fallback' { $result.Why = [string]$result.Reason }
        # FINISH-ATTACH-UNKNOWN-WORDS-1: an attach with no answer keeps its own
        # sentence - Azure did not refuse it, and the LUN may hold a disk.
        'empty' { if (-not $result.Unknown) { $result.Why = "LUN $Lun has no disk. Azure did not attach the disk '$WantName' made from its copy: $(([string]$result.Reason).TrimEnd('.'))." } }
    }
    $result
}
