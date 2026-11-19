# WAVE-RESUME-PLANNED-1. The service starts a wave again when its execution
# stopped (Invoke-VmfFacadeResumeStalledWaves). It asked only for a machine
# PAST PLANNED, because a wave nobody started is waiting, not stalled. But a
# worker takes a machine's claim and its lease (Get-VmfNextWaveVm) BEFORE the
# state machine writes the machine's record and moves it to PRECHECK. An
# execution that stopped between the two left every machine of the wave at
# PLANNED: the wave waited for ever, and the taken machine's claim kept it from
# other migrations.
#
# These two functions tell "an execution of this wave started and stopped"
# apart from "nobody started this wave", from two facts the product already
# writes on both store backends.

function Get-VmfOpenWaveStarts {
    <#
    .SYNOPSIS
        WAVE-RESUME-PLANNED-1: the waves whose last 'wave start' line no end
        line follows - an execution of the wave that started and did not end.
        Pure: run history lines in, wave names out.
    .DESCRIPTION
        Start-VmfWave writes the 'wave start' line after every start gate
        passed, and a 'wave ok' or 'wave fail' line when the execution ends.
        Each names its wave as data (`wave`). A start line written before that
        named its wave only in its words ("wave=<name> entries=..."), and those
        words are read. An end line that names no wave was written before this
        change: it ends every start before it, so a line this rule cannot place
        never starts a wave again.

        Other lines of the step - a halt, a halt cleared, a container that
        finished its share - end nothing.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()][AllowEmptyCollection()]$Events)

    $open = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Events)) {
        if (-not $e -or [string]$e.step -ne 'wave') { continue }
        $wave = if ($e.PSObject.Properties['wave'] -and [string]$e.wave) { [string]$e.wave } else { '' }
        $outcome = [string]$e.outcome
        if ($outcome -eq 'start') {
            if (-not $wave -and [string]$e.detail -match '^wave=(\S+)') { $wave = $Matches[1] }
            if ($wave -and -not $open.Contains($wave)) { $open.Add($wave) }
        }
        elseif ($outcome -in @('ok', 'fail')) {
            if ($wave) { $null = $open.Remove($wave) } else { $open.Clear() }
        }
    }
    @($open)
}

function Get-VmfWaveTakenBeforeCheck {
    <#
    .SYNOPSIS
        WAVE-RESUME-PLANNED-1: the machines, by wave, that a worker of this run
        took and whose execution stopped before their check started.
    .DESCRIPTION
        A machine is in the list when ALL of these hold:
          - its record says PLANNED, or it has none (a machine past PLANNED is
            the restart's other question, and a settled one is done);
          - THIS RUN holds its claim (the claim is taken under run.json's id,
            Get-VmfNextWaveVm). Only a worker takes a claim, and only after
            its wave started. A worker that leaves a machine untouched gives
            the claim back (WAVE-MIX-2), and so does a settled machine
            (CLAIM-KEPT-AFTER-WAVE-1);
          - its wave has an open start (Get-VmfOpenWaveStarts): an execution
            of the wave started and wrote no end.
        Both facts, because each alone can misfire. A claim alone: a worker
        stopped before it gave the claim back, and a person then moved the
        machine to a wave nobody started. A start alone: an execution that
        stopped before any worker took a machine, which holds nothing - and a
        start of the wave that fails the same way every time would be started
        again on every pass.

        The caller asks this only while no lease in the run is live and the
        run is not halted. The run history is read only when a claimed machine
        is found, so a run that waits for its next wave costs a claim read for
        each machine that has not started, and no more.
    .PARAMETER States
        vmId -> state, of every record in the run (a machine with no record
        has not started).
    .OUTPUTS
        A hashtable: wave -> the vmIds taken. Empty when none.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$States
    )
    $found = @{}
    $run = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    # A run whose own id cannot be read matches no claim: unknown takes nothing.
    $runId = if ($run) { [string]$run.runId } else { '' }

    foreach ($entry in @($Plan.entries | Where-Object { $_ -and [string]$_.vmId -and [string]$_.wave -and [string]$_.path -eq 'A' })) {
        $vmId = [string]$entry.vmId
        $state = if ($States.ContainsKey($vmId)) { [string]$States[$vmId] } else { $script:VmfNotStartedState }
        if ($state -ne $script:VmfNotStartedState) { continue }
        $claim = Get-VmfVmClaim -RunPath $RunPath -VmId $vmId
        if (-not $claim -or -not $runId -or [string]$claim.runId -ne $runId) { continue }
        $wave = [string]$entry.wave
        if (-not $found.ContainsKey($wave)) { $found[$wave] = [System.Collections.Generic.List[string]]::new() }
        $found[$wave].Add($vmId)
    }
    if (-not $found.Count) { return $found }

    $open = @(Get-VmfOpenWaveStarts -Events (Read-VmfEvents -RunPath $RunPath -Step 'wave'))
    $taken = @{}
    foreach ($wave in @($found.Keys)) {
        if ($wave -in $open) { $taken[$wave] = @($found[$wave]) }
    }
    $taken
}


# RETRY-WAIT-SAYS-WHY-1. Final lab, 2026-11-16: after Try this machine again on
# a machine of a finished wave, the page said for 22 minutes that the service
# starts it within about 5 minutes. The service's restart starts nothing while
# any hold in the run has a live heartbeat, nor a wave that fails a start gate,
# and it wrote no line for either. These two functions say which cause holds
# the wave, once per cause, in a line the page reads (step 'resume', code
# 'held', the wave as data). The restart's own start line says 'resumed', and
# that ends the hold.

function Get-VmfResumeLeaseHold {
    <#
    .SYNOPSIS
        RETRY-WAIT-SAYS-WHY-1: which live hold keeps the service from starting
        this wave again, or $null. Pure.
    .DESCRIPTION
        A hold of a worker of THIS wave is not a cause: that worker takes the
        machine (Get-VmfNextWaveVm takes any machine of its wave that is not
        final and not held), so the wave is worked on. Otherwise:
          - a hold of a worker of another wave: HoldBy 'wave', HoldWave that
            wave. The wave of a hold is the wave of the plan entry with its
            machine ID (any letter case), or, for the hold a worker takes on an
            availability set ('group-avset/<set ID in lower case>'), the wave
            of a machine in that set. A worker hold that no entry places names
            no wave (''). Every hold that is not a restore is a wave worker's
            (schemas/lease.schema.json).
          - only a restore ('restore:<operation id>'): HoldBy 'restore'.
        A wave worker is named before a restore, and of several waves the
        first by name, so the cause does not change from pass to pass while
        the holds stay.
    .OUTPUTS
        @{ HoldBy = 'wave' | 'restore'; HoldWave = <wave or ''> } or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Plan,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Leases
    )
    $entries = if ($Plan -and $Plan.entries) { @($Plan.entries | Where-Object { $_ }) } else { @() }
    $waveOfLease = {
        param($lease)
        $id = [string]$lease.vmId
        if ($id -like 'group-avset/*') {
            $set = $id.Substring('group-avset/'.Length)
            foreach ($e in $entries) {
                $a = if ($e.PSObject.Properties['assessment'] -and $e.assessment -and $e.assessment.PSObject.Properties['availabilitySetId']) { [string]$e.assessment.availabilitySetId } else { '' }
                if ($a -and $a.Trim('/').ToLowerInvariant() -eq $set) { return [string]$e.wave }
            }
            return ''
        }
        $entry = @($entries | Where-Object { [string]$_.vmId -ieq $id }) | Select-Object -First 1
        if ($entry) { [string]$entry.wave } else { '' }
    }
    $workerWaves = [System.Collections.Generic.List[string]]::new()
    $restore = $false
    foreach ($lease in @($Leases | Where-Object { $_ })) {
        if ([string]$lease.workerId -like 'restore:*') { $restore = $true; continue }
        $w = & $waveOfLease $lease
        if ($w -ieq $Wave) { return $null }
        $workerWaves.Add($w)
    }
    if ($workerWaves.Count) {
        $named = @($workerWaves | Where-Object { $_ } | Sort-Object -Unique)
        return @{ HoldBy = 'wave'; HoldWave = $(if ($named.Count) { [string]$named[0] } else { '' }) }
    }
    if ($restore) { return @{ HoldBy = 'restore'; HoldWave = '' } }
    $null
}

function ConvertTo-VmfResumeHoldUtc {
    # RETRY-WAIT-SAYS-WHY-1: a stored time as a UTC date value. ConvertFrom-Json
    # gives a date value for an ISO date and a string for anything else, so
    # both spellings of one instant compare as one (CLAUDE.md, PLANVER-2).
    param([AllowNull()]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    $text = [string]$Value
    if (-not $text) { return $null }
    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $parsed }
    $null
}

function Write-VmfResumeHoldLine {
    <#
    .SYNOPSIS
        RETRY-WAIT-SAYS-WHY-1: say why the service does not start this wave
        again - once for each cause, as Set-VmfPlanRunStatus says the plan run
        only when its reason changed.
    .DESCRIPTION
        The line: step 'resume', outcome 'info', no machine ID (a line of a
        machine tells the page that something works on it), and as data the
        wave, code 'held', holdBy, holdWave, gate and reason. The page shows
        the cause on the machines of the wave that wait for the service.

        Once: no line is written when the newest 'held' or 'resumed' line of
        this wave is a 'held' line with the same cause (holdBy, holdWave, gate
        and the words of the gate), written at or after
        -Since - the time of the newest step of a machine of the wave that
        waits (its retry). A retry after the line gets its own line, because
        the page reads only a line written after the retry. The restart's
        start line says 'resumed', so the cause is said again when it comes
        back. A line that cannot be written is said again on the next pass.
    .PARAMETER Hold
        @{ HoldBy = 'wave' | 'restore' | 'gate'; HoldWave; Gate; Reason }.
        For 'gate', Gate is the start gate's code and Reason its words
        (New-VmfStartGateRefusal).
    .PARAMETER Events
        The run's 'resume' lines, read once by the caller for every wave. None
        given: read here.
    .OUTPUTS
        Whether a line was written.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][hashtable]$Hold,
        [Parameter()][AllowNull()]$Since,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Events
    )
    $by = [string]$Hold.HoldBy
    $holdWave = [string]$Hold.HoldWave
    $gate = [string]$Hold.Gate
    $reason = [string]$Hold.Reason
    if ($null -eq $Events) { $Events = @(Read-VmfEvents -RunPath $RunPath -Step 'resume') }
    $last = @($Events | Where-Object {
            $_ -and [string]$_.step -eq 'resume' -and $_.PSObject.Properties['wave'] -and [string]$_.wave -ieq $Wave -and
            $_.PSObject.Properties['code'] -and [string]$_.code -in @('held', 'resumed') }) | Select-Object -Last 1
    if ($last -and [string]$last.code -eq 'held' -and [string]$last.holdBy -eq $by -and [string]$last.holdWave -eq $holdWave -and
        [string]$last.gate -eq $gate -and [string]$last.reason -eq $reason) {
        $sinceUtc = ConvertTo-VmfResumeHoldUtc $Since
        $lastUtc = ConvertTo-VmfResumeHoldUtc $last.tsUtc
        if (-not $sinceUtc -or ($lastUtc -and $lastUtc -ge $sinceUtc)) { return $false }
    }
    $detail = switch ($by) {
        'wave' {
            if ($holdWave) { "A machine in wave $Wave waits for wave $holdWave to finish. Then the service starts wave $Wave again." }
            else { "A machine in wave $Wave waits for a running wave to finish. Then the service starts wave $Wave again." }
        }
        'restore' { "A machine in wave $Wave waits for a restore to finish. Then the service starts wave $Wave again." }
        'gate' { "A machine in wave $Wave waits, because wave $Wave cannot start yet. $reason" }
        default { throw "Write-VmfResumeHoldLine: unknown cause '$by'." }
    }
    $lost = $null
    Write-VmfStepLine -RunPath $RunPath -Step 'resume' -Outcome info -Detail $detail -WarningVariable lost -Data @{
        wave = $Wave; code = 'held'; holdBy = $by; holdWave = $holdWave; gate = $gate; reason = $reason }
    -not $lost
}