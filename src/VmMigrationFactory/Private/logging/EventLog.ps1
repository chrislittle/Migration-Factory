# Structured logging: JSONL event stream per run at <store>/logs/events.jsonl.
# Machine events are the source of truth; console text is a rendering of them.
# Concurrent-append safety lives in the store layer (Add-VmfStoreLine:
# FileShare.ReadWrite whole-line writes on file, append blob on azblob).
#
# EVENTLOG-1: a long run's log is in SEVERAL documents - events.jsonl, then
# events-2.jsonl, and so on, because an append blob holds 50,000 blocks and
# this writes one per event. Neither end of this file has to care: the store
# layer rolls on the way in and walks the parts on the way out.

function Write-VmfEvent {
    <#
    .SYNOPSIS
        Append one structured event line to the run's JSONL log.
    .PARAMETER Data
        Optional extra fields (hashtable) merged into the event - e.g. azure
        request ids, retry counts. Reserved keys are not overridable.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Step,
        # LOG-SAYS-WHY-1: 'refused' is A DECISION THIS PRODUCT MADE, not a
        # breakage. The owner, shown a gate correctly refusing a wave that had
        # no reserved capacity: "why does it say this failed. that's not
        # good." He was right - the gate worked. A safety gate doing its job
        # and an engine falling over shared one outcome, so no screen could
        # ever tell them apart.
        [Parameter(Mandatory)]
        [ValidateSet('start', 'ok', 'retry', 'fail', 'refused', 'skip', 'info', 'warn')]
        [string]$Outcome,
        [Parameter()][string]$VmId,
        [Parameter()][double]$DurationSec,
        [Parameter()][string]$Detail,
        [Parameter()][string]$CorrelationId,
        [Parameter()][hashtable]$Data
    )

    $evt = [ordered]@{
        tsUtc   = (Get-Date).ToUniversalTime().ToString('o')
        step    = $Step
        outcome = $Outcome
    }
    if ($VmId) { $evt.vmId = $VmId }
    if ($DurationSec -gt 0) { $evt.durationSec = [math]::Round($DurationSec, 3) }
    if ($Detail) { $evt.detail = $Detail }
    if ($CorrelationId) { $evt.correlationId = $CorrelationId }
    if ($Data) {
        foreach ($k in $Data.Keys) {
            if ($k -notin @('tsUtc', 'step', 'outcome', 'vmId', 'durationSec', 'detail', 'correlationId')) {
                $evt[$k] = $Data[$k]
            }
        }
    }

    # WRITE-DEPTH-OPEN-1: 24, because -Data comes from the caller. A shallower
    # write saves a deeper part as its type name, with only a warning.
    Add-VmfStoreLine -RunPath $RunPath -RelPath 'logs/events.jsonl' `
        -Line ($evt | ConvertTo-Json -Depth 24 -Compress)
}

function Write-VmfStepLine {
    <#
    .SYNOPSIS
        STEP-LOG-1: write one line to the run history in its own error handler,
        so a line that cannot be written never decides what the engine did.
    .DESCRIPTION
        The engine loop wrote a step's checkpoint and then its "ok" line inside
        the step's one try. A line that could not be written after the
        checkpoint was counted as the step failing: the machine was put back to
        the step it had finished and ran it again, and when that used up the
        step's attempts, CONVERTING, STARTING or VALIDATING rolled back a
        machine that had passed. The same held for every line written after
        the engine had changed something - inside a step, in a rollback that
        had worked, and after an Azure operation that had succeeded (where a
        transient-looking store error even ran the operation again). The
        record line was fixed the same way (REPORT-RECORD-LINE-1).

        The run history is its own append document (EVENTLOG-1), not the state
        document, so a line can fail while the checkpoint is written. The state
        document keeps each step's own entry; what a missing line loses is the
        line. A lost lease still stops the worker.

        Not for a notice written BEFORE the engine changes anything (PRECHECK):
        there a line that cannot be written stops the machine untouched, so the
        notice is never lost. The line that says a started move keeps its
        target uses this helper (STEP-LOG-3): that machine has already changed.

        STEP-LOG-2: the same rule outside one machine's move - the wave halt,
        the stale approvals, the claims, the plan run, the decision carry, the
        restores and the rebuild, the deleted safety copies and the record and
        report. A line written before anything changes may stay a throwing
        write; each one says why where it is written.

        STEP-LOG-4: and in the operator commands - the approvals and
        acceptances, a decision, the plan, the wave layout, a target change,
        a schedule, a skip, a stop, a scan, the report, and the deletes of a
        migration and of expired safety copies.

        STEP-LOG-5: and in the capacity and wave start commands and the
        worker - Reserve and Release capacity, the close-out of a wave, the
        quota check and the quota increase request, the start of a wave and
        its watch loop. A lost line there stopped a release part way (the
        next reservations went on billing), recorded a reservation Azure made
        as not made, reported a wave that ran as failed, or stopped a worker
        with a machine leased.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)]
        [ValidateSet('start', 'ok', 'retry', 'fail', 'refused', 'skip', 'info', 'warn')]
        [string]$Outcome,
        [Parameter()][string]$VmId,
        [Parameter()][double]$DurationSec,
        [Parameter()][string]$Detail,
        [Parameter()][string]$CorrelationId,
        [Parameter()][hashtable]$Data
    )
    try { Write-VmfEvent @PSBoundParameters }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        # STEP-LOG-2: a line of the migration, not of one machine, names none.
        $for = if ($VmId) { " for $VmId" } else { '' }
        # STEP-LOG-2 review: the line's own words go into the engine output, so
        # a fact that is only in the line is not lost with it.
        $said = if ($Detail) { " The line said: $Detail" } else { '' }
        Write-Warning "The run history line '$Step $Outcome'$for could not be written, and the engine goes on: $($_.Exception.Message)$said"
    }
}

function Read-VmfEvents {
    <#
    .SYNOPSIS
        Read the run's event stream back as objects (newest last). Filterable.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][string]$VmId,
        [Parameter()][string]$Step
    )

    $events = Read-VmfStoreLines -RunPath $RunPath -RelPath 'logs/events.jsonl' | ForEach-Object { $_ | ConvertFrom-Json }
    if ($VmId) { $events = $events | Where-Object { $_.vmId -eq $VmId } }
    if ($Step) { $events = $events | Where-Object { $_.step -eq $Step } }
    @($events)
}
