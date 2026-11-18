# PERF-RETENTION-TIMEOUT-1: the daily cleanup works in passes that fit the
# service's time limit.
#
# MEASURED on the lab install, 2026-10-27 to 2026-11-02: all 7 passes of the
# service's RetentionRunner stopped at the Azure Functions 5-minute limit. The
# pass walked every run in one go and wrote its record only at the end, so:
# every run after the point it reached was never examined, and the expired
# safety copies there kept billing; the record was never written, so the
# Safety copies card showed an old pass; and the timeout restarted the worker,
# which also stopped a ScheduleRunner pass beside it. On a Consumption plan the
# limit goes to 10 minutes and no more, so raising it moves the defect.
#
# THE SHAPE. The day's cleanup is a CYCLE that starts at 03:30 UTC - the hour
# the pages name. The timer fires every hour. Each pass examines runs, in one
# fixed order, until its time budget is spent, then writes the record with the
# run it reached (resumeAtRunId), and the next pass starts there. When the
# cycle has examined every run, the passes until the next 03:30 do nothing. So
# every run is examined each day, and a store that needs more than a day of
# passes still reaches its last run: an unfinished cycle always continues.
#
# WHY NOT THE ENGINE. The engine job has no 5-minute limit, but the
# examination is reads the service can do with no right over a customer's
# machine, and the split is on purpose (RetentionRunner): the service previews
# with -WhatIf, and starts the engine - which holds the rights - only for a
# run that has something to delete. A daily engine job for every store would
# cost a container start for the many days with nothing due, and give the
# reads to the identity that can delete.
#
# A PASS THE HOST STOPS. The record is written at the start of a pass, after
# every run, and at the end. A record with no finishedUtc is a pass that is
# working or was stopped: the next pass starts again AT the run it was on, and
# counts the stop against that run (resumeStops). A run that two passes were
# stopped on is passed over and named as a failure - one run that cannot be
# examined in the time must not hold up every run after it, every day.
#
# Nothing here deletes anything, or decides what is due. That is still
# Remove-VmfExpiredSafetyCopies, and Get-VmfSafetyCopyIds behind it.

# The cycle starts at 03:30 UTC. help.js nextRetentionPassUtc names the same
# hour on the Safety copies card; RetentionRunner.Tests.ps1 holds both.
$script:VmfRetentionCycleHourUtc = 3
$script:VmfRetentionCycleMinuteUtc = 30
# The timer fires a fraction of a second early at times. A pass that early
# still belongs to the cycle that starts at the minute.
$script:VmfRetentionCycleSlackSeconds = 60
# A run the host stopped this many passes on is passed over.
$script:VmfRetentionStopsBeforeSkip = 2

function Get-VmfRetentionCycleStart {
    <#
    .SYNOPSIS
        The start of the cycle a pass at this time belongs to: the latest
        03:30 UTC at or before it.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)][datetime]$NowUtc)
    $at = $NowUtc.ToUniversalTime().AddSeconds($script:VmfRetentionCycleSlackSeconds)
    $start = [datetime]::new($at.Year, $at.Month, $at.Day, $script:VmfRetentionCycleHourUtc, $script:VmfRetentionCycleMinuteUtc, 0, [System.DateTimeKind]::Utc)
    if ($start -gt $at) { $start = $start.AddDays(-1) }
    $start
}

function ConvertFrom-VmfRetentionDate {
    # A date from the record, which is text (Read-VmfStoreRootJson). $null
    # when it is not a date: unknown is never "today".
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    $parsed = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [cultureinfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsed)) { return $parsed.UtcDateTime }
    $null
}

function Get-VmfRetentionRecordField {
    param($Record, [string]$Name)
    if ($null -eq $Record) { return $null }
    $prop = $Record.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    $null
}

function Get-VmfRetentionPassAction {
    <#
    .SYNOPSIS
        What a pass does, from the record of the last one: 'newCycle',
        'continue' or 'done'.
    .DESCRIPTION
        continue - the cycle has a run it has not examined (resumeAtRunId).
                   Also after the next 03:30: an unfinished cycle always
                   continues, so the end of the list is never left out.
        done     - the cycle examined every run, and it started at or after
                   this cycle's 03:30.
        newCycle - anything else: no record, a record whose dates cannot be
                   read, or a finished cycle from an earlier day.

        MIGRATION (schema 1 to 2): a schema 1 record was written only at the
        end of a whole pass, so it is a finished cycle that started at its
        lastPassUtc.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Previous,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    if ($null -eq $Previous) { return 'newCycle' }
    $version = [int](Get-VmfRetentionRecordField $Previous 'schemaVersion')
    if ($version -ge 2 -and -not [string]::IsNullOrEmpty([string](Get-VmfRetentionRecordField $Previous 'resumeAtRunId'))) {
        return 'continue'
    }
    $started = if ($version -ge 2) { ConvertFrom-VmfRetentionDate (Get-VmfRetentionRecordField $Previous 'cycleStartedUtc') }
               else { ConvertFrom-VmfRetentionDate (Get-VmfRetentionRecordField $Previous 'lastPassUtc') }
    if ($null -eq $started) { return 'newCycle' }
    if ($started -ge (Get-VmfRetentionCycleStart -NowUtc $NowUtc)) { return 'done' }
    'newCycle'
}

function New-VmfRetentionPassStart {
    <#
    .SYNOPSIS
        The runs a pass examines, in order, and the record it starts with.
    .DESCRIPTION
        The order is ordinal on the run id, so it does not change with the
        culture of the worker, and a run deleted since the last pass moves the
        start to the next name.

        A new cycle starts every count at zero. A pass that continues a cycle
        keeps its counts, its failures and the engine jobs it started, so the
        record says what the whole day's cleanup did - the Safety copies card
        reads it as one pass.

        The record it returns has resumeAtRunId set to the first run of the
        pass and no finishedUtc: written at once, it is what the store holds if
        the host stops this pass before its first run ends.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Previous,
        [Parameter(Mandatory)][ValidateSet('newCycle', 'continue')][string]$Action,
        [Parameter()][AllowEmptyCollection()][string[]]$RunIds = @(),
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $now = $NowUtc.ToUniversalTime()
    $sorted = [System.Collections.Generic.List[string]]::new()
    foreach ($id in @($RunIds)) { if (-not [string]::IsNullOrEmpty($id)) { $sorted.Add([string]$id) } }
    $sorted.Sort([System.StringComparer]::Ordinal)

    $record = [ordered]@{
        schemaVersion     = 2
        cycleStartedUtc   = $now.ToString('o')
        lastPassUtc       = $now.ToString('o')
        finishedUtc       = $null
        passesInCycle     = 1
        runsInStore       = $sorted.Count
        runsExamined      = 0
        runsWithCopiesDue = 0
        machinesDue       = 0
        executionsStarted = @()
        failures          = @()
        resumeAtRunId     = $null
        resumeStops       = 0
        slowestRun        = $null
        nextPassUtc       = $null
    }
    $runs = @($sorted)
    $stalled = $null

    if ($Action -eq 'continue') {
        $f = { param($n) Get-VmfRetentionRecordField $Previous $n }
        $carriedStart = [string](& $f 'cycleStartedUtc')
        if ($carriedStart) { $record.cycleStartedUtc = $carriedStart }
        $record.passesInCycle = [int](& $f 'passesInCycle') + 1
        foreach ($n in 'runsExamined', 'runsWithCopiesDue', 'machinesDue') { $record[$n] = [int](& $f $n) }
        $record.executionsStarted = @(@(& $f 'executionsStarted') | Where-Object { $null -ne $_ } | ForEach-Object {
            [ordered]@{ runId = [string]$_.runId; machines = [int]$_.machines; execution = [string]$_.execution } })
        $record.failures = @(@(& $f 'failures') | Where-Object { $null -ne $_ } | ForEach-Object {
            [ordered]@{ runId = [string]$_.runId; reason = [string]$_.reason } })
        $slow = & $f 'slowestRun'
        if ($slow) { $record.slowestRun = $slow }

        $cursor = [string](& $f 'resumeAtRunId')
        # A record with no finish: the host stopped the pass on this run.
        $stops = if ([string]::IsNullOrEmpty([string](& $f 'finishedUtc'))) { [int](& $f 'resumeStops') + 1 } else { 0 }
        if ($stops -ge $script:VmfRetentionStopsBeforeSkip) {
            $stalled = $cursor
            $runs = @($sorted | Where-Object { [string]::CompareOrdinal($_, $cursor) -gt 0 })
            $record.runsExamined++
            $record.failures += [ordered]@{ runId = $cursor
                reason = "The service stopped $stops passes at its time limit during the check of migration '$cursor'. The next daily cleanup checks it again." }
            $stops = 0
        }
        else {
            $runs = @($sorted | Where-Object { [string]::CompareOrdinal($_, $cursor) -ge 0 })
        }
        $record.resumeStops = $stops
    }
    $record.resumeAtRunId = if ($runs.Count) { $runs[0] } else { $null }
    [pscustomobject]@{ Record = $record; Runs = $runs; StalledRunId = $stalled }
}

function Get-VmfRetentionNextPassUtc {
    <#
    .SYNOPSIS
        When the next pass with work to do runs: the next 03:30 UTC when the
        cycle examined every run, otherwise the next timer, at half past the
        hour.
    #>
    [CmdletBinding()]
    [OutputType([datetime])]
    param(
        [Parameter(Mandatory)][datetime]$NowUtc,
        [switch]$CycleComplete
    )
    $now = $NowUtc.ToUniversalTime()
    if ($CycleComplete) {
        $next = [datetime]::new($now.Year, $now.Month, $now.Day, $script:VmfRetentionCycleHourUtc, $script:VmfRetentionCycleMinuteUtc, 0, [System.DateTimeKind]::Utc)
        if ($next -le $now) { $next = $next.AddDays(1) }
        return $next
    }
    $next = [datetime]::new($now.Year, $now.Month, $now.Day, $now.Hour, $script:VmfRetentionCycleMinuteUtc, 0, [System.DateTimeKind]::Utc)
    if ($next -le $now) { $next = $next.AddHours(1) }
    $next
}

function Test-VmfRetentionTimeLeft {
    <#
    .SYNOPSIS
        $true while a pass may start another run.
    .DESCRIPTION
        The host stops a function at 5 minutes: the Consumption plan's
        default, as host.json sets no functionTimeout.
        A pass stops STARTING runs at 210 seconds: the run it has started
        must still end, and the record must still be written, inside the
        limit. A run that does not end in time is what resumeStops is for.

        TIMER-PASS-LIMIT-1: the rule is Test-VmfPassTimeLeft
        (SchedulePass.ps1), which the schedule pass asks too.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][datetime]$StartedUtc,
        [Parameter()][ValidateRange(1, 240)][int]$BudgetSeconds = 210
    )
    Test-VmfPassTimeLeft -StartedUtc $StartedUtc -BudgetSeconds $BudgetSeconds
}
