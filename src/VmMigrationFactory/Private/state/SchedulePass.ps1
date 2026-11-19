# TIMER-PASS-LIMIT-1: the service's five-minute schedule pass fits the
# service's time limit, and every run is reached in turn.
#
# MEASURED (PERF-ANALYSIS-1, FACADE-TIMER-QUEUE-1): ScheduleRunner took a
# median of 54 s a pass on 2026-10-26 and 77 s on 2026-11-02, it grows with
# the store, and two passes reached the Azure Functions 5-minute limit
# (FunctionTimeoutException), which also restarts the worker and stops the
# other calls in it. The pass walked the runs in one fixed order, so on a store
# that always needs more than 5 minutes the same runs came last every time and
# were never checked: a scheduled wave there did not start, and a stopped wave
# or restore there did not start again. Nothing said so.
#
# THE SAME MECHANISM AS THE DAILY CLEANUP (PERF-RETENTION-TIMEOUT-1,
# RetentionPass.ps1). The pass stops STARTING runs at its time budget, writes a
# record at the store root with the run it reached (resumeAtRunId), and the
# next pass starts there.
#
# SCHEDULE-PASS-DUE-1 (schema 2 of the record): a pass checks only the runs of
# the due record (ScheduleDue.ps1) - the runs a check can act on - and once an
# hour every run in the store (the sweep), in ordinal order of run id. A sweep
# the budget stops goes on from resumeAtRunId in the next pass, to the end of
# the list, so every run is reached in each sweep and no run is always last.
#
# A PASS THE HOST STOPS. The record is written at the start of a pass, before
# every run (checkingRunId: the run it is on), and at the end. A record with
# no finishedUtc and a checkingRunId is a pass the host stopped on that run:
# the stop is counted (checkingStops), and a due run with a stop is checked
# last of the due runs. A run that two passes were stopped on is passed over
# for one pass and named - one run that cannot be checked in the time must not
# hold up every run after it. The next pass checks it again.
#
# STARTING A WAVE TWICE. Nothing here starts anything. A run checked again
# after a stop asks the same questions as before, and each start already asks
# Azure first whether a run of that wave (or that restore) goes on
# (Test-VmfFacadeEngineRunning, ENGINE-START-PART-1, RESTORE-ONE-AT-A-TIME-1).
# Two passes do not overlap. Microsoft's timer trigger page (Learn,
# functions-bindings-timer, ms.date 2026-06-21, section "Scale-out") says a
# timer function runs on a single instance across all instances, and: "It will
# not trigger again if there is an outstanding invocation still running." It
# names no hosting plan there, so it does not say it for the Consumption plan
# by name; TIMER-SINGLETON-LAB-1 reads it on the lab install.

# The name of the record at the store root.
$script:VmfSchedulePassRecordName = 'schedule-status.json'
# A run the host stopped this many passes on is passed over for one pass.
$script:VmfScheduleStopsBeforeSkip = 2
# A machine record read longer ago than this is read again before the
# put-back pass judges it (the FACADE-TIMER-QUEUE-1 review).
$script:VmfScheduleStateDocsMaxAgeSeconds = 30

function Test-VmfPassTimeLeft {
    <#
    .SYNOPSIS
        $true while a timer pass of the service may start another run.
    .DESCRIPTION
        The host stops a function at 5 minutes: the Consumption plan's
        default, as host.json sets no functionTimeout. A pass stops STARTING
        runs at 210 seconds: the run it has started must still end, and the
        record must still be written, inside the limit. A run that does not
        end in time is what checkingStops is for.

        One rule for both timer passes: the daily cleanup asks it through
        Test-VmfRetentionTimeLeft, the schedule pass asks it here.
    .PARAMETER NowUtc
        The clock. The service gives none; a test gives its own.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][datetime]$StartedUtc,
        [Parameter()][ValidateRange(1, 240)][int]$BudgetSeconds = 210,
        [Parameter()][datetime]$NowUtc = [datetime]::UtcNow
    )
    ($NowUtc.ToUniversalTime() - $StartedUtc.ToUniversalTime()).TotalSeconds -lt $BudgetSeconds
}

function New-VmfSchedulePassStart {
    <#
    .SYNOPSIS
        The runs a schedule pass checks, in order - the due runs, then the
        runs of the sweep - and the record it starts with.
    .DESCRIPTION
        SCHEDULE-PASS-DUE-1: a pass checks the runs of the due record first
        (DueRunIds, Select-VmfScheduleDueRuns), in ordinal order of run id.
        With -Sweep it then checks the runs of the store (RunIds) that it did
        not check as due: a sweep that is open goes on from the record's
        resumeAtRunId (or the first run after it, when that run was deleted)
        to the end of the list; a new sweep starts at the first run. The
        order is ordinal on the run id, so it does not change with the
        culture of the worker.

        A record with no finishedUtc and a checkingRunId is a pass the host
        stopped on that run. The stop is counted; at two, that run is passed
        over for this pass (PassedOverRunId), and the next pass checks it
        again. A due run with one stop is checked LAST of the due runs, so it
        cannot keep the other due runs from their check.

        The record it returns has no finishedUtc: written at once, it is what
        the store holds if the host stops this pass before its first run ends.
    .OUTPUTS
        Record, DueRuns, SweepRuns, PassedOverRunId, StoppedRunId and
        StoppedCount (the stops to write while that run is checked).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Previous,
        [Parameter()][AllowEmptyCollection()][string[]]$DueRunIds = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$RunIds = @(),
        [Parameter()][switch]$Sweep,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $sortedOf = { param($ids)
        $list = [System.Collections.Generic.List[string]]::new()
        foreach ($id in @($ids)) {
            if (-not [string]::IsNullOrEmpty($id) -and -not $list.Contains([string]$id)) { $list.Add([string]$id) }
        }
        $list.Sort([System.StringComparer]::Ordinal)
        , $list
    }
    $due = & $sortedOf $DueRunIds
    $listed = if ($Sweep) { & $sortedOf $RunIds } else { [System.Collections.Generic.List[string]]::new() }

    $read = Get-VmfSchedulePassCursor -Previous $Previous
    $stopped = $read.StoppedRunId
    $stops = $read.Stops

    # A stop is counted against a run only while the run is still there: a
    # run deleted since gives no other run a stop.
    if ($stopped -and -not $due.Contains($stopped) -and -not $listed.Contains($stopped)) { $stopped = $null; $stops = 0 }
    $passedOver = $null
    if ($stopped -and $stops -ge $script:VmfScheduleStopsBeforeSkip) { $passedOver = $stopped; $stopped = $null; $stops = 0 }

    $dueRuns = [System.Collections.Generic.List[string]]::new()
    foreach ($id in $due) { if ($id -ne $passedOver -and $id -ne $stopped) { $dueRuns.Add($id) } }
    if ($stopped -and $due.Contains($stopped)) { $dueRuns.Add($stopped) }

    $open = $Sweep -and [bool]$read.SweepStartedUtc
    $sweepRuns = [System.Collections.Generic.List[string]]::new()
    if ($Sweep) {
        foreach ($id in $listed) {
            if ($open -and $read.Cursor -and [string]::CompareOrdinal($id, $read.Cursor) -lt 0) { continue }
            if ($id -eq $passedOver -or $due.Contains($id)) { continue }
            $sweepRuns.Add($id)
        }
    }

    $record = [ordered]@{
        schemaVersion   = 2
        lastPassUtc     = $NowUtc.ToUniversalTime().ToString('o')
        finishedUtc     = $null
        runsInStore     = $listed.Count
        runsDue         = $dueRuns.Count
        runsChecked     = 0
        runsNotChecked  = 0
        resumeAtRunId   = $(if ($sweepRuns.Count) { $sweepRuns[0] } else { $null })
        checkingRunId   = $null
        checkingStops   = 0
        passedOverRunId = $passedOver
        sweepStartedUtc = $(if (-not $Sweep) { $null } elseif ($open) { [string]$read.SweepStartedUtc } else { $NowUtc.ToUniversalTime().ToString('o') })
        lastSweepUtc    = $(if ($read.LastSweepUtc) { [string]$read.LastSweepUtc } else { $null })
        slowestRun      = $null
    }
    [pscustomobject]@{
        Record = $record; DueRuns = @($dueRuns); SweepRuns = @($sweepRuns); PassedOverRunId = $passedOver
        StoppedRunId = $stopped; StoppedCount = $stops
    }
}

function Get-VmfSchedulePassCursor {
    <#
    .SYNOPSIS
        What the last pass left, read from its record: Valid, Cursor (the
        next run of an open sweep), StoppedRunId and Stops (the run the host
        stopped that pass on, and the stops counted against it, this one
        included), SweepStartedUtc and LastSweepUtc.
    .DESCRIPTION
        THE RECORD IS DATA FROM THE STORE, AND NEVER STOPS A PASS (security
        review of TIMER-PASS-LIMIT-1). A record that parses as JSON but holds a
        field of the wrong type made the cast throw, before the first run, in
        every pass, for ever. So every field is read with a type check, and
        anything that does not fit is read as NO RECORD (Valid $false): the
        pass starts a sweep at the first run, and its start record writes over
        the bad file.
          - schemaVersion: the number 2, and nothing else. A record of
            schema 1 (TIMER-PASS-LIMIT-1) is read as no record: the first pass
            of SCHEDULE-PASS-DUE-1 checks every run (migration note).
          - resumeAtRunId, finishedUtc, checkingRunId: text, or null.
          - checkingStops: a whole number from 0 to 1000; read as 0 to the
            number of stops that pass a run over.
          - sweepStartedUtc, lastSweepUtc: a time as text, or null.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()]$Previous)
    $none = [pscustomobject]@{ Valid = $false; Cursor = $null; StoppedRunId = $null; Stops = 0; SweepStartedUtc = $null; LastSweepUtc = $null }
    if ($null -eq $Previous) { return $none }
    $field = { param($n) $prop = $Previous.PSObject.Properties[$n]; if ($prop) { $prop.Value } else { $null } }
    $text = { param($v) $null -eq $v -or $v -is [string] }
    $version = & $field 'schemaVersion'
    if (-not ($version -is [int] -or $version -is [long]) -or $version -ne 2) { return $none }
    $cursor = & $field 'resumeAtRunId'
    $finished = & $field 'finishedUtc'
    $checking = & $field 'checkingRunId'
    $started = & $field 'sweepStartedUtc'
    $last = & $field 'lastSweepUtc'
    foreach ($v in @($cursor, $finished, $checking, $started, $last)) { if (-not (& $text $v)) { return $none } }
    foreach ($v in @($started, $last)) {
        if (-not [string]::IsNullOrEmpty($v) -and $null -eq (ConvertFrom-VmfScheduleDueTime -Value $v)) { return $none }
    }
    $raw = & $field 'checkingStops'
    $count = 0
    if ($null -ne $raw) {
        if (-not ($raw -is [int] -or $raw -is [long])) { return $none }
        if ($raw -lt 0 -or $raw -gt 1000) { return $none }
        $count = [int]$raw
    }
    $stoppedOn = $null
    $stops = 0
    # A record with no finish and a run it was on: the host stopped that pass
    # on that run. A record that finished ended by itself: no stop.
    if ([string]::IsNullOrEmpty($finished) -and -not [string]::IsNullOrEmpty($checking)) {
        $stoppedOn = $checking
        $stops = [Math]::Min($count + 1, $script:VmfScheduleStopsBeforeSkip)
    }
    [pscustomobject]@{
        Valid = $true
        Cursor = $(if ([string]::IsNullOrEmpty($cursor)) { $null } else { $cursor })
        StoppedRunId = $stoppedOn; Stops = $stops
        SweepStartedUtc = $(if ([string]::IsNullOrEmpty($started)) { $null } else { $started })
        LastSweepUtc = $(if ([string]::IsNullOrEmpty($last)) { $null } else { $last })
    }
}

function Select-VmfScheduleStateDocs {
    <#
    .SYNOPSIS
        The machine records the put-back pass may judge from: the ones read
        for the run, or $null when they were read too long ago - the pass
        then reads them itself.
    .DESCRIPTION
        FACADE-TIMER-QUEUE-1 review: a run's machine records are read once,
        before the stalled-wave pass, and given to the put-back pass after the
        hold pass. A put-back job that ends or starts again between the read
        and the put-back decision is not seen in a record that old. So a read
        older than 30 seconds is not given: the put-back pass reads the
        records again just before it decides.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$StateDocs,
        [Parameter(Mandatory)][datetime]$ReadUtc,
        [Parameter()][datetime]$NowUtc = [datetime]::UtcNow,
        [Parameter()][int]$MaxAgeSeconds = $script:VmfScheduleStateDocsMaxAgeSeconds
    )
    if ($null -eq $StateDocs) { return $null }
    if (($NowUtc.ToUniversalTime() - $ReadUtc.ToUniversalTime()).TotalSeconds -gt $MaxAgeSeconds) { return $null }
    # Given back as one list, also when it holds one record or none.
    , @($StateDocs)
}
