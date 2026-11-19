# ROLLBACK-SIZE-REFUSED-SERIES-1 (decided 2026-11-14): Azure refused a
# machine's original size during a rollback (rollbackSizeRefused), so the
# machine is stopped on its NEW size, on the disks the move left. The way
# forward is a move to another series from the first safety copy.
#
# Three steps, each an existing action of the machine panel:
#   1. Change to v5 (RETRY-SERIES-1, Set-VmfMachineTarget -AfterRollback) is
#      offered for this stop too. Until a restore, only a SCSI series (v5,
#      Bsv2): the first safety copy is from before the guest changes for NVMe,
#      so it starts only on SCSI.
#   2. Restore this machine from the copy Before the migration puts the disks
#      of the first safety copy back ONTO THE TARGET SIZE OF THE PLAN, not onto
#      the original size Azure refused (Get-VmfRestoreOntoTarget). That
#      changes what "restored" means here: the machine is as it was, every disk
#      from the first safety copy and every setting from the first capture, on
#      another size. The record says it (restore.ontoTarget, vm-state v51), and
#      the first capture's size becomes that size (captured.original
#      .sizeReplaced keeps the size Azure refused), so every later rollback and
#      restore returns the machine to it - never to the size Azure refused.
#   3. Try this machine again moves it, as any retry after a restore.
#
# The rule is pure and held to tests/fixtures/restore-onto-target.json, with the
# run page's restoreOntoTarget (migrations.js), so the dialog names the size the
# engine uses.

function Get-VmfSizeRefusedStop {
    <#
    .SYNOPSIS
        The rollbackSizeRefused stop the machine waits at, with no restore
        since it - or $null. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $stop = Get-VmfLastStopEntry -Doc $Doc
    if (-not $stop -or [string](& $f $stop 'reasonCode') -ne 'rollbackSizeRefused') { return $null }
    $restored = ConvertTo-VmfUtcTime (& $f (& $f $Doc 'restore') 'restoredUtc')
    $stoppedAt = ConvertTo-VmfUtcTime (& $f $stop 'tsUtc')
    if ($restored -and (-not $stoppedAt -or $restored -gt $stoppedAt)) { return $null }
    $stop
}

function Get-VmfRestoreOntoTarget {
    <#
    .SYNOPSIS
        Does a restore from the first safety copy go onto the target size of
        the plan, not the original size? $null when it does not, else
        @{ Size; Option; OriginalSize; Refusal }. Pure.
    .DESCRIPTION
        It does when all of these hold:
          - the restore reads the first safety copy on record (pristine);
          - the machine waits at a rollbackSizeRefused stop, with no restore
            since it (Get-VmfSizeRefusedStop);
          - the plan moves the machine (path A) to a size on SCSI - a person
            changed its series with Change to v5 - that is not the original
            size. The first safety copy starts on any SCSI size.
        Refusal says why such a restore does not start, with nothing changed:
          - the first capture has a capacity reservation group of its own:
            its reservations are for the original size, and Azure does not
            start a machine whose size has no reservation in its group;
          - the move was, or would be, the in-place upgrade (Preview): it
            changes the kind of temporary disk, which was never measured on a
            restore onto another size.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][AllowNull()]$PlanEntry,
        [Parameter()][AllowEmptyString()][string]$From = 'pristine',
        [Parameter()][bool]$RecordedCopy = $true
    )
    if ($From -ne 'pristine' -or -not $RecordedCopy -or -not $PlanEntry -or -not $Doc) { return $null }
    if (-not (Get-VmfSizeRefusedStop -Doc $Doc)) { return $null }
    if ([string]$PlanEntry.path -ne 'A' -or [string]$PlanEntry.target.controller -eq 'NVMe') { return $null }
    $first = Get-VmfOriginalCapture -Doc $Doc
    $original = [string](Get-VmfRecordField -Object $first -Name 'size')
    $size = [string]$PlanEntry.target.size
    if (-not $size -or $size -eq $original) { return $null }
    $option = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $PlanEntry.target -Name 'choice') -Name 'option')
    if (-not $option) { $option = [string](Get-VmfRecordField -Object $PlanEntry.policy -Name 'targetGeneration') }
    $vm = (([string]$PlanEntry.vmId) -split '/')[-1]
    $refusal = $null
    $group = (Get-VmfCapturedReservationGroup -Capture $first).GroupId
    if ($group) {
        $refusal = "Nothing changed for $vm. The machine is in the capacity reservation group '$(($group -split '/')[-1])', which holds no capacity reservation for $size."
    }
    elseif ((Get-VmfStartedMoveMethod -Doc $Doc) -eq 'preview' -or (Get-VmfEntryMethod -Entry $PlanEntry) -eq 'preview') {
        $refusal = "Nothing changed for $vm. The move is an in-place upgrade (Preview), and the product does not restore it onto another size."
    }
    @{ Size = $size; Option = $option; OriginalSize = $original; Refusal = $refusal }
}

function Get-VmfRestoreOntoTargetForRun {
    <#
    .SYNOPSIS
        Get-VmfRestoreOntoTarget for a machine of a run: its record and its
        plan entry, read from the store. $null when either is not there.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId, [Parameter()][AllowNull()]$Doc)
    if (-not $Doc) { $Doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId }
    if (-not $Doc -or -not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'plan.json')) { return $null }
    $plan = Read-VmfPlanDocument -RunPath $RunPath
    $entry = @(@($plan.entries) | Where-Object { [string]$_.vmId -eq $VmId }) | Select-Object -First 1
    Get-VmfRestoreOntoTarget -Doc $Doc -PlanEntry $entry -From 'pristine'
}

function Get-VmfRestoreOntoTargetWords {
    <#
    .SYNOPSIS
        What the restore says when it puts the machine on the target size of
        the plan. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Onto, [Parameter()][AllowEmptyString()][string]$Controller)
    $on = if ($Controller) { " with the $Controller disk controller" } else { '' }
    "Azure refused the original size $($Onto.OriginalSize), so the restore put the machine on $($Onto.Size)$on. " +
        "That is the size of $($Onto.Option) in the plan. Every later rollback and restore returns the machine to $($Onto.Size)."
}

function Set-VmfOriginalSizeOnto {
    <#
    .SYNOPSIS
        After a restore onto the target size of the plan: that size becomes
        the size of the first capture, and the size Azure refused is kept
        beside it (captured.original.sizeReplaced, vm-state v51). Changes the
        document only; the caller writes it, in the same write as the
        restore's record. Pure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Doc, [Parameter(Mandatory)]$Onto, [Parameter()][AllowEmptyString()][string]$OperationId)
    $original = $Doc.captured.original
    if (-not $original -or -not $original.vmConfig) { return }
    if ($original.PSObject.Properties['sizeReplaced'] -and $original.sizeReplaced -and [string]$original.vmConfig.size -eq [string]$Onto.Size) { return }
    $original | Add-Member -NotePropertyName sizeReplaced -Force -NotePropertyValue ([pscustomobject][ordered]@{
            size = [string]$Onto.OriginalSize; by = 'restore'; reasonCode = 'rollbackSizeRefused'
            operationId = $(if ($OperationId) { $OperationId } else { $null }); utc = (Get-Date).ToUniversalTime().ToString('o') })
    $original.vmConfig | Add-Member -NotePropertyName size -NotePropertyValue ([string]$Onto.Size) -Force
}

function Get-VmfSizeReplaced {
    <#
    .SYNOPSIS
        After a restore onto the target size of the plan: the size the first
        capture read (which Azure refused) and the size the restore put the
        machine on - @{ Original; Onto } - or $null. Pure.
    .DESCRIPTION
        Set-VmfOriginalSizeOnto makes the restore's size the first capture's,
        so every put-back returns there. A report that says what the machine
        was BEFORE the migration reads the original size from here, never from
        the first capture (Get-VmfPutBackCapture), which now holds the v5 size.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $original = & $f (& $f $Doc 'captured') 'original'
    $replaced = & $f $original 'sizeReplaced'
    $was = [string](& $f $replaced 'size')
    if (-not $was) { return $null }
    @{ Original = $was; Onto = [string](& $f (& $f $original 'vmConfig') 'size') }
}

function Get-VmfSizeReplacedWords {
    <#
    .SYNOPSIS
        The sentence a report says beside a size that a restore onto the target
        size of the plan replaced. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Replaced)
    "Azure refused $($Replaced.Original) in a rollback. A restore then changed the size of the machine to $($Replaced.Onto)."
}
