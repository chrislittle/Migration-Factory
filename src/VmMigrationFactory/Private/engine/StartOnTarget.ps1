# ROLLBACK-NO-CAPACITY-OTHER-SERIES-1 (decided 2026-11-14): a machine
# that a rollback left stopped on its original size, because Azure had no
# capacity for that size (rollbackNoCapacity), moves to another series, for
# example v5. That is a fresh run from the original disks, with new safety
# copies, and v5 stays on SCSI.
#
# A retry starts the machine on its original size first: the power state it
# owes (POWER-ONLY-CHANGED-1), the start for the cluster check
# (CLUSTER-NOT-RUNNING-1), the volume check a rollback owes
# (VOLUMES-RETRY-CHECK-1) and the guest scripts of Preparing all need it
# running. While Azure has no capacity for that size, each of them stops the
# retry again. So such a retry STARTS THE MACHINE ON THE NEW SIZE (vm-state
# v51, captured.startOnTarget):
#
#   Checking     every check that reads Azure runs as for any retry; the
#                volume check owed, the power state owed and the cluster check
#                do not start the machine. The new attempt is taken here
#                (new safety copies, -a2 and on), and the readings the earlier
#                attempt took of these disks are kept (guestBefore,
#                imdsBefore, storageBefore): the rollback put back the disks
#                of the first safety copy, and those readings were taken from
#                the disks that copy holds.
#   Safety copy  taken with the machine stopped, as always; the machine is not
#                started after it.
#   Preparing    runs no script: it saves the accelerated networking decision
#                with no driver reading, as Checking already judges it.
#   Converting   resizes the stopped machine to the v5 size, as always.
#   Starting     starts it on the new size, then runs the checks that need the
#                guest (Get-VmfChecksAfterStartStop): the LVM devices file on
#                Linux, the cluster check, the SR-IOV unmanaged check on a
#                Linux move that turns accelerated networking on, and the
#                driver check. A check that
#                stops is a full rollback (the safety copies are new copies of
#                the original disks, and the size goes back).
#   Verifying    as always, against the readings that were kept.
#
# Only a move that needs no change inside the machine before it qualifies
# (Test-VmfStartOnTargetShape): a SCSI move (v5 or Bsv2), and not a Windows
# machine whose page file must leave the temporary disk, nor one that needs the
# MANA driver in its driver store. Any other retry starts the machine on its
# original size first, as before, and says why.
#
# Everything here is pure: the step handlers in StateMachine.ps1 and
# WorkloadCheck.ps1 make the Azure calls.

$script:VmfLastStopStates = @('FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION')

function ConvertTo-VmfUtcTime {
    <#
    .SYNOPSIS
        A history time as a UTC date, or $null when it cannot be read. Pure.
    .DESCRIPTION
        ConvertFrom-Json turns an ISO date into a date value, so a time read
        back from the store can be either form.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if (-not $Value) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$parsed)) { return $parsed }
    $null
}

function Get-VmfLastStopEntry {
    <#
    .SYNOPSIS
        The newest history entry that stopped the machine for a person - a
        stop state with a reason code - or $null. Pure.
    .DESCRIPTION
        A person's retry adds an entry for Checking after it, so the last entry
        is not always the stop: this reads back to it.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    @(@(& $f $Doc 'history') | Where-Object {
            $_ -and [string](& $f $_ 'state') -in $script:VmfLastStopStates -and [string](& $f $_ 'reasonCode') }) | Select-Object -Last 1
}

function Test-VmfStartOnTargetShape {
    <#
    .SYNOPSIS
        Can this move start the machine on the new size, with no start on its
        original size before it? $null when it can, else why not:
        'notScsi', 'pageFile' or 'manaDriver'. Pure.
    .DESCRIPTION
        Only a move that needs no change inside the machine before it:
          notScsi     the target is not a SCSI move onto v5 or Bsv2
                      (Get-VmfMoveKind scsi-resize). A move to NVMe prepares
                      the guest before the stop, or the machine does not boot.
          pageFile    a Windows machine whose SCSI temporary disk goes away:
                      the page file moves off it inside the machine first.
          manaDriver  a Windows machine on a size that can give MANA: the MANA
                      driver goes into the driver store first (MANA-WIN-1). A
                      size that cannot be read is not a no.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$PlanEntry)
    if ((Get-VmfMoveKind -PlanEntry $PlanEntry) -ne 'scsi-resize') { return 'notScsi' }
    $windows = [string]$PlanEntry.assessment.os -eq 'Windows'
    if ($windows -and [string]$PlanEntry.assessment.sourceDiskArch -eq 'scsi-temp' -and [string]$PlanEntry.target.diskArch -ne 'scsi-temp') { return 'pageFile' }
    if ($windows -and (Test-VmfTargetMayUseMana -SizeName ([string]$PlanEntry.target.size)) -ne $false) { return 'manaDriver' }
    $null
}

function Get-VmfStartOnTargetRefusedWords {
    <#
    .SYNOPSIS
        What Checking says when a retry after rollbackNoCapacity must start the
        machine on its original size first. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Size,
        [Parameter(Mandatory)][ValidateSet('notScsi', 'pageFile', 'manaDriver')][string]$Why
    )
    $on = if ($Size) { $Size } else { 'its original size' }
    $because = switch ($Why) {
        'notScsi' { 'The target size is not a v5 or Bsv2 size, so the move prepares the machine for NVMe before it changes the size.' }
        'pageFile' { 'The temporary disk of this Windows machine goes away, so the move puts the page file on another disk before it changes the size.' }
        'manaDriver' { 'The target size can give the MANA adapter, so the move puts the MANA driver in the driver store of this Windows machine before it changes the size.' }
    }
    "This move needs the machine to run on $on before the change. $because"
}

function Test-VmfStartOnTargetStop {
    <#
    .SYNOPSIS
        Does the last stop let a retry start the machine on the new size? Pure.
    .DESCRIPTION
        The rollbackNoCapacity stop does. So does a stop of an attempt that
        started on the new size and stopped before it changed anything (a park
        at Checking, untouched, or changed only in its power state): the
        machine is still stopped on its original size, on the disks of the
        first safety copy. Its record names the stop before it (stopUtc), so a
        record of any older attempt does not carry on.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $stops = @(@(& $f $Doc 'history') | Where-Object {
            $_ -and [string](& $f $_ 'state') -in $script:VmfLastStopStates -and [string](& $f $_ 'reasonCode') })
    if (-not $stops.Count) { return $false }
    $last = $stops[-1]
    if ([string](& $f $last 'reasonCode') -eq 'rollbackNoCapacity') { return $true }
    if ($stops.Count -lt 2) { return $false }
    $prior = & $f (& $f $Doc 'captured') 'startOnTarget'
    if (-not $prior) { return $false }
    $was = ConvertTo-VmfUtcTime (& $f $prior 'stopUtc')
    $before = ConvertTo-VmfUtcTime (& $f $stops[-2] 'tsUtc')
    if ($null -eq $was -or $null -eq $before -or $was -ne $before) { return $false }
    $left = [string](& $f $last 'machineState')
    [bool]($left -eq 'untouched' -or ($left -eq 'changed' -and [string](& $f $last 'powerNotPutBack')))
}

function Get-VmfStartOnTarget {
    <#
    .SYNOPSIS
        The record that this attempt starts the machine on the new size
        (captured.startOnTarget, vm-state v51), or $null. Pure.
    .DESCRIPTION
        Only while it belongs to the stop the machine was tried again from:
        its stopUtc is the time of the last stop (Get-VmfLastStopEntry). A
        record an earlier attempt wrote, before a later stop, is not this
        attempt's.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $record = & $f (& $f $Doc 'captured') 'startOnTarget'
    if (-not $record) { return $null }
    $stop = Get-VmfLastStopEntry -Doc $Doc
    if (-not $stop) { return $null }
    $was = ConvertTo-VmfUtcTime (& $f $record 'stopUtc')
    $now = ConvertTo-VmfUtcTime (& $f $stop 'tsUtc')
    if ($null -eq $was -or $null -eq $now -or $was -ne $now) { return $null }
    $record
}

function Get-VmfStartOnTargetPower {
    <#
    .SYNOPSIS
        The power state this attempt returns the machine to, from its
        startOnTarget record - 'PowerState/deallocated', 'PowerState/stopped',
        'PowerState/running', or $null. Pure.
    .DESCRIPTION
        The record holds the power state the machine owed (a machine found
        running before the earlier move), else the power state Checking read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $record = Get-VmfStartOnTarget -Doc $Doc
    if (-not $record) { return $null }
    $power = [string](Get-VmfRecordField -Object $record -Name 'power')
    if ($power -in @('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running')) { return $power }
    $null
}

function Get-VmfStartOnTargetPrepWords {
    <#
    .SYNOPSIS
        What Preparing says when this attempt starts the machine on the new
        size. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Size,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Target,
        [Parameter()][bool]$ReadingsKept
    )
    $kept = if ($ReadingsKept) { 'Verifying compares the machine with the readings that the earlier attempt took of these disks.' }
            else { 'The product has no reading of this machine from before the move, so Verifying cannot compare the volumes.' }
    "Azure had no capacity for $Size, so the product does not start the machine on it. " +
        "The product changes the size to $Target, and then starts the machine. " +
        "The checks inside the machine run after that start. $kept"
}
