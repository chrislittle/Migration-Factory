# SCAN-FAIL-SHOWN-1: a scan whose engine job stopped with no answer ends the
# wizard's wait.
#
# MEASURED (lab installation, 2026-11-09): the engine job execution of a scan
# ended with the status Failed about 3 minutes after its start. It wrote no
# console line and no line in the run's activity, and the wizard said "Looking
# for machines" for more than 11 minutes, with no end. The wizard reads only
# the run's activity; the engine writes an answer there (assessment ok or fail,
# or the entrypoint's engine:assess fail line) only while it runs.
#
# Azure keeps the status of each execution. The service's five-minute pass
# already lists the executions (TIMER-EXEC-LIST-1); for an assess execution of
# a run that ended with no answer after its start line, it writes the
# engine:assess fail line the wizard reads (Invoke-VmfFacadeEndSilentScan in
# FacadeCore). These are the rules, pure, so every case is run in
# tests/unit/ScanFailShown.Tests.ps1.

# The execution statuses that mean "ended, and not with success". Running and
# Processing still run. Succeeded wrote its answer (an assessment.json moves
# the wizard on). Any other status - Unknown, Degraded, none, or a status a
# later api-version adds - is not an end: nothing is written (the review: no
# Microsoft page says Degraded is final for a job execution, and a fail line
# for a scan that then finishes is a false statement).
$script:VmfScanEndedStatuses = @('Failed', 'Stopped')

function Test-VmfScanExecutionEnded {
    <#
    .SYNOPSIS
        SCAN-FAIL-SHOWN-1: does this execution status mean the job ended, and
        not with success? Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Status)
    [bool]($Status -and $Status -cin $script:VmfScanEndedStatuses)
}

function Get-VmfScanSilentEnd {
    <#
    .SYNOPSIS
        SCAN-FAIL-SHOWN-1: the fail line a scan whose job ended with no answer
        needs, or $null. Pure.
    .DESCRIPTION
        The newest start line of a scan in the run's activity (step engine,
        operation assess - the service writes it after Azure accepted the
        start) names its executions. An execution it names, with a status of
        $script:VmfScanEndedStatuses, gets a line when nothing after that start
        answered: no assessment ok, fail or refused, and no engine:assess fail
        or refused. A scan started again in the same run (Back, then Start
        looking) is a new start; what the earlier scan wrote does not count.
        A log with no start line, or a start that names no execution, gets
        nothing: nothing ties an execution to this scan.
    .PARAMETER Events
        The run's activity, oldest first (Read-VmfEvents).
    .PARAMETER Executions
        The assess executions of this run, as Name and Status.
    .OUTPUTS
        Execution, Status and Detail, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Events,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Executions
    )
    $list = @($Events)
    $startAt = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        if (-not $e) { continue }
        if ([string](Get-VmfRecordField -Object $e -Name 'step') -ceq 'engine' -and
            [string](Get-VmfRecordField -Object $e -Name 'outcome') -cin @('start', 'warn') -and
            [string](Get-VmfRecordField -Object $e -Name 'operation') -ceq 'assess') { $startAt = $i }
    }
    if ($startAt -lt 0) { return $null }
    $named = @(@(Get-VmfRecordField -Object $list[$startAt] -Name 'executions') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    if (-not $named.Count) { return $null }
    for ($i = $startAt + 1; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        if (-not $e) { continue }
        $step = [string](Get-VmfRecordField -Object $e -Name 'step')
        $outcome = [string](Get-VmfRecordField -Object $e -Name 'outcome')
        if ($step -ceq 'assessment' -and $outcome -cin @('ok', 'fail', 'refused')) { return $null }
        if ($step -ceq 'engine:assess' -and $outcome -cin @('fail', 'refused')) { return $null }
    }
    foreach ($x in @($Executions)) {
        if (-not $x) { continue }
        $name = [string]$x.Name
        $status = [string]$x.Status
        if ($name -cnotin $named) { continue }
        if (-not (Test-VmfScanExecutionEnded -Status $status)) { continue }
        return [pscustomobject]@{
            Execution = $name
            Status    = $status
            Detail    = "The engine job execution $name has the status $status in Azure, and the scan recorded no result and no reason."
        }
    }
    $null
}
