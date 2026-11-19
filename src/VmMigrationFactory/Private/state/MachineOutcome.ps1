# COUNT-TRUTH-1: what happened to one machine, in one place.
#
# Every count of "migrated" used to ask its own question, and they did not
# agree. On one screen after a six-machine run with one machine put back, the
# Reports page said 4, 6 and "restored 0" - three wrong numbers, three causes
# (REPORT-STALE-1, PUTBACK-COUNT-1, REPORT-RESTORED-1). A machine put back
# keeps the state MIGRATED and gains a `restore` marker, so "is it MIGRATED"
# counts it as a success; and SKIPPED, a machine LEFT OUT, was counted as
# migrated too.
#
# The dashboard has the twin of this in help.js (machineOutcome), and both are
# held to tests/fixtures/machine-outcomes.json.

function Get-VmfMachineOutcome {
    <#
    .SYNOPSIS
        One word for what happened to a machine: migrated, putBack,
        rolledBack, attention, leftOut, working, notStarted or unknown.
    .DESCRIPTION
        Pure: reads the state document it is given and nothing else.
        A machine with no document has not started - its wave has not run.
        A state this version does not know is `unknown`: never counted as a
        success and never as a failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$StateDoc)

    if ($null -eq $StateDoc) { return 'notStarted' }
    $outcome = Get-VmfMachineMoveOutcome -StateDoc $StateDoc
    # FINISH-COUNT-1: a put-back that Azure refused a data disk swap left
    # stopped (swapPending, SWAP-REFUSED-AFTER-STOP-1) waits for a person to
    # use Finish the restore or Finish the rollback - whatever the state and
    # the restore record say. A step still running keeps 'working': the wave
    # worker's rollback writes the swap before it records its stop.
    if ($outcome -ne 'working' -and (Test-VmfSwapPendingRecord -StateDoc $StateDoc)) { return 'attention' }
    $outcome
}

function Test-VmfEntryOutsideRun {
    <#
    .SYNOPSIS
        NOT-IN-WAVE-QUEUED-1: is this plan machine left out of the migration
        as the record and the pages show it?
    .DESCRIPTION
        True when the machine is in no wave (no wave name, or `unscheduled`,
        the planner's word and the only wave the engine skips), the plan would move it (any path but MANUAL
        or EXCLUDED), and it has no state document. No wave takes such a
        machine - the wave editor's Remove put it there - so it never moves
        until a person puts it in a wave again, and the wave editor still
        lists it. It is not part of the migration, so it is never shown with
        it.
        A machine with a state document has history and is always shown. A
        MANUAL or EXCLUDED machine is always shown: the pages say why the plan
        does not move it.
        Pure. help.js has the twin (VmfHelp.outsideRun), and both are held to
        tests/fixtures/entry-outside-run.json.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Entry, [Parameter()][AllowNull()]$StateDoc)
    if ($null -eq $Entry -or $null -ne $StateDoc) { return $false }
    $wave = [string]$Entry.wave
    # Exact case, as the pages compare (JavaScript ===).
    $noWave = -not $wave -or $wave -ceq 'unscheduled'
    $noWave -and ([string]$Entry.path -cnotin @('MANUAL', 'EXCLUDED'))
}

function Test-VmfSwapPendingRecord {
    <#
    .SYNOPSIS
        Does the state document hold a swapPending record? Pure.
    .DESCRIPTION
        FINISH-COUNT-1. Only a record counts: no value, an empty object or a
        list names no swap. A record whose swaps list is empty still counts -
        Finish moves each LUN off it as Azure takes it, and removes the record
        only once the machine has started.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$StateDoc)
    if ($null -eq $StateDoc) { return $false }
    # Assigned, never the output of an if: that would unroll a list of one
    # row into the row, and a list is not a record.
    $sp = $null
    if ($StateDoc -is [System.Collections.IDictionary]) { $sp = $StateDoc['swapPending'] }
    elseif ($StateDoc.PSObject.Properties['swapPending']) { $sp = $StateDoc.PSObject.Properties['swapPending'].Value }
    if ($sp -is [System.Collections.IDictionary]) { return $sp.Count -gt 0 }
    if ($sp -is [System.Management.Automation.PSCustomObject]) { return @($sp.PSObject.Properties).Count -gt 0 }
    $false
}

function Get-VmfMachineMoveOutcome {
    <#
    .SYNOPSIS
        Where the move and a restore left the machine, from its state and its
        restore record alone: Get-VmfMachineOutcome without the swap check.
    .DESCRIPTION
        FINISH-COUNT-1. A report that says which size and controller a
        machine runs on now asks this: a data disk swap that is left keeps
        the size and the controller the put-back gave the machine. Every
        count asks Get-VmfMachineOutcome. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$StateDoc)

    if ($null -eq $StateDoc) { return 'notStarted' }
    $state = if ($StateDoc -is [System.Collections.IDictionary]) { [string]$StateDoc['state'] } else { [string]$StateDoc.state }
    $restore = if ($StateDoc -is [System.Collections.IDictionary]) { $StateDoc['restore'] }
               elseif ($StateDoc.PSObject.Properties['restore']) { $StateDoc.restore } else { $null }

    # STATUS-WORDS-1: a restore as new as the stop ends the stop - the rule of
    # Get-VmfSkipMachineState and Get-VmfDecisionWaiting for the same records.
    # After a restore that worked, a machine that had needed attention still
    # counted as needing a person, and the report listed it with the failures.
    # A migrated machine keeps its put-back unless a later step shows that it
    # moved again after the restore.
    $ends = Test-VmfRestoreEndsStop -StateDoc $StateDoc
    switch ($state) {
        'MIGRATED'               { if ($restore -and $ends -ne $false) { return 'putBack' } else { return 'migrated' } }
        'FAILED_ROLLED_BACK'     { if ($ends -eq $true) { return 'putBack' } else { return 'rolledBack' } }
        'NEEDS_DECISION'         { if ($ends -eq $true) { return 'putBack' } else { return 'attention' } }
        'FAILED_NEEDS_ATTENTION' { if ($ends -eq $true) { return 'putBack' } else { return 'attention' } }
        'SKIPPED'                { return 'leftOut' }
        'PLANNED'                { return 'notStarted' }
        { $_ -in @('PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED',
                   'CONVERTING', 'STARTING', 'VALIDATING') } { return 'working' }
        default                  { return 'unknown' }
    }
}

function Test-VmfRestoreEndsStop {
    <#
    .SYNOPSIS
        STATUS-WORDS-1: is the restore on this record as new as every step on
        it? $true, $false (a later step is on record), or $null (no restore,
        or its time cannot be read - unknown is not a yes). Pure.
    .DESCRIPTION
        With no step that has a time, a restore with a time ends nothing it
        could be older than, so it is $true. The twin of the same rule inside
        help.js's machineOutcome; both are held to
        tests/fixtures/machine-status.json.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$StateDoc)
    if ($null -eq $StateDoc) { return $null }
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $utc = {
        param($v)
        if ($v -is [datetime]) { return $v.ToUniversalTime() }
        if ($null -eq $v -or [string]$v -eq '') { return $null }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$parsed)) { return $parsed }
        $null
    }
    $restore = & $f $StateDoc 'restore'
    if ($null -eq $restore) { return $null }
    $at = & $utc (& $f $restore 'restoredUtc')
    if ($null -eq $at) { return $null }
    $last = $null
    foreach ($h in @(& $f $StateDoc 'history')) {
        if ($null -eq $h) { continue }
        $t = & $utc (& $f $h 'tsUtc')
        if ($null -ne $t -and ($null -eq $last -or $t -gt $last)) { $last = $t }
    }
    if ($null -eq $last) { return $true }
    $at -ge $last
}

function Test-VmfOutcomeWaitsOnPerson {
    <#
    .SYNOPSIS
        Does a machine with this outcome wait for a person? Pure.
    .DESCRIPTION
        RUN-SUMMARY-SWAP-1. attention (a stop, a decision, or a swap a
        put-back left) and rolledBack (a rollback, which offers its choices)
        wait; nothing else does, and an outcome this version does not know
        waits for nobody. The rule of the Migrations page's Waiting on people
        card (help.js outcomeWaitsOnPerson), and of run-status.json's
        summary.waitsOnPerson, which the overview and the migrations list
        read. Both are held to tests/fixtures/machine-outcomes.json.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Outcome)
    # -cin: the outcome words are exact, as in help.js.
    $Outcome -cin @('attention', 'rolledBack')
}

function Get-VmfOutcomeCounts {
    <#
    .SYNOPSIS
        How many machines have each outcome. Every outcome is present, at zero
        when nothing has it, so a reader never mistakes "absent" for "none".
    #>
    [CmdletBinding()]
    param([Parameter()][AllowEmptyCollection()][object[]]$StateDocs = @())

    $counts = [ordered]@{
        migrated = 0; putBack = 0; rolledBack = 0; attention = 0
        leftOut = 0; working = 0; notStarted = 0; unknown = 0
    }
    foreach ($doc in @($StateDocs)) { $counts[(Get-VmfMachineOutcome -StateDoc $doc)]++ }
    [pscustomobject]$counts
}
