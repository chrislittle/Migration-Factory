# REPORT-AUTO-1: the record and the report, written together, by the engine.
#
# Decided 2026-10-02: the report is written automatically - no
# button - whenever a wave finishes and whenever a machine is put back. Before
# this a migration had a report only when somebody pressed "Produce the
# report", and the engineering kind went to a file the Reports page never
# opened (REPORT-OWN-1).
#
# One call keeps the migration record and then writes the report, at the same
# moment. The report's five main sections - results, moves, machines,
# exceptions and sign-off - are rendered from THAT record, so they say what the
# kept record says. Its follow-up sections (the changes for infrastructure
# code, the capacity table and what the scan could not read) are still read from the run's own documents by New-VmfReport,
# at the same moment, from the same store.
#
# The triggers: a wave that closed, a restore, and Stop this migration. And because a
# write can fail and a change can come with no trigger (a capacity release, for
# one), the daily timer asks Update-VmfStaleReport of every migration and
# writes both again where the report or the kept record is missing, failed
# last time, or is older than the newest change the record holds. Each write
# leaves its own line in the run history to compare with: 'report' and, since
# REPORT-RECORD-LINE-1, 'record'.
#
# NEVER THROWS. The machines moved, or were put back; a document about it that
# cannot be written must not turn that into a failed operation. Each half has
# its own try, a failure is a warning in the run history in words a person can
# act on, and the daily check writes both again. Writing twice gives the same
# report: it carries no time of writing (New-VmfReport).

function Save-VmfRecordAndReport {
    <#
    .SYNOPSIS
        Keep the migration record and write the report. Returns
        { record; report } - whether each was written. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][ValidateSet('waveClosed', 'putBack', 'stopped', 'dailyCheck')][string]$Reason
    )
    $after = switch ($Reason) {
        'waveClosed' { 'after this wave' } 'putBack' { 'after this restore' }
        'stopped' { 'after the migration was stopped' } 'dailyCheck' { 'by the daily check' }
    }
    $again = 'The daily check of the reports writes it again, and so does the next wave or restore.'
    # The warning must not become the failure: a store that refuses the
    # document may refuse the log line too.
    $warn = { param($step, $text) Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome warn -Detail $text }
    $done = [ordered]@{ record = $false; report = $false }

    $record = $null
    try {
        $record = New-VmfMigrationRecord -RunPath $RunPath -Reason $Reason
        $done.record = $true
    }
    catch {
        & $warn 'record' "The migration record could not be written ${after}: $($_.Exception.Message). $again"
    }

    try {
        # With no record kept, the report builds its own from the store - the
        # same function, so its main sections still say what the record would.
        $reportParams = @{ OutPath = $RunPath }
        if ($record) { $reportParams.Record = $record }
        New-VmfReport @reportParams | Out-Null
        $done.report = $true
    }
    catch {
        & $warn 'report' "The report could not be written ${after}: $($_.Exception.Message). $again"
    }
    [pscustomobject]$done
}

function Update-VmfStaleReport {
    <#
    .SYNOPSIS
        REPORT-AUTO-1 review 3: the daily check. Writes the record and the
        report again for a migration whose report or kept record is missing,
        whose last write of either failed, or which is older than the newest
        change the record holds.
    .DESCRIPTION
        REPORT-RECORD-LINE-1: the record is judged as the report is. Keeping
        it leaves a 'record' line (New-VmfMigrationRecord), in the shape the
        report's 'report' line has; before that line existed, a record that
        failed while the report after it was written looked current here.
    .OUTPUTS
        'written', 'failed' (it tried and the record or the report could not
        be written - a warning says why), or 'current' (nothing to do).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RunPath)
    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 8
    # RETAIN-KIND-1: the one rule for what a run is.
    if ((Get-VmfRunKind -Manifest $manifest) -ne 'migration') { return 'current' }

    $record = Get-VmfMigrationRecordFromStore -RunPath $RunPath -Reason 'dailyCheck'
    $lastChange = Get-VmfRecordLastChange -Record $record
    $writes = @(@($record.runActivity) | Where-Object { $_ } | ForEach-Object {
            $step = [string](Get-VmfRecordField -Object $_ -Name 'step')
            if ($step -notin @('report', 'record')) { return }
            [pscustomobject]@{ step = $step; outcome = [string](Get-VmfRecordField -Object $_ -Name 'outcome')
                               at = ConvertTo-VmfRecordUtc (Get-VmfRecordField -Object $_ -Name 'tsUtc') }
        } | Where-Object { $_.at } | Sort-Object at)
    $lastOk = @($writes | Where-Object { $_.step -eq 'report' -and $_.outcome -eq 'ok' }) | Select-Object -Last 1
    $lastWarn = @($writes | Where-Object { $_.outcome -eq 'warn' }) | Select-Object -Last 1
    $hasReport = Test-VmfStoreItem -RunPath $RunPath -RelPath 'customer-report.html'
    # The record's own newest line and its kept document, found the way
    # New-VmfMigrationRecord keeps it.
    $lastRecord = @($writes | Where-Object { $_.step -eq 'record' }) | Select-Object -Last 1
    $lastRecordOk = @($writes | Where-Object { $_.step -eq 'record' -and $_.outcome -eq 'ok' }) | Select-Object -Last 1
    $recordName = Get-VmfRecordName -RunId ([string]$record.runId) -Project ([string]$record.project)
    $recordScope = Get-VmfRecordScope -StorePath (Get-VmfStoreRootOf -RunPath $RunPath -Project ([string]$record.project))
    $hasRecord = Test-VmfStoreItem -RunPath $recordScope -RelPath $recordName

    $stale = if ($lastWarn -and (-not $lastOk -or $lastWarn.at -gt $lastOk.at)) { $true }
             elseif ($lastRecord -and $lastRecord.outcome -eq 'warn') { $true }
             elseif (-not $lastChange) { $false }
             elseif (-not $hasReport -or -not $lastOk) { $true }
             elseif (-not $hasRecord -or -not $lastRecordOk) { $true }
             else { $lastChange -gt $lastOk.at -or $lastChange -gt $lastRecordOk.at }
    if (-not $stale) { return 'current' }
    $r = Save-VmfRecordAndReport -RunPath $RunPath -Reason 'dailyCheck'
    if ($r.report -and $r.record) { 'written' } else { 'failed' }
}

function Get-VmfStateDocVersion {
    <#
    .SYNOPSIS
        REPORT-AFTER-SWAP-LEFT-1: the version (PLANVER-2) of a machine's
        record as it is stored now, or '' when the machine has no record.
        Throws when the store cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath ('state/' + (Get-VmfVmKey -VmId $VmId) + '.json')
    if ($null -eq $text) { return '' }
    Get-VmfDocumentVersion -Text ([string]$text)
}

function Save-VmfRecordAndReportAfterRestore {
    <#
    .SYNOPSIS
        REPORT-AFTER-SWAP-LEFT-1: keep the record and write the report after a
        restore that THREW, when that restore wrote its record. Returns $true
        when it wrote them, $false when it had no reason to.
    .DESCRIPTION
        A restore whose data disk swap Azure refused writes swapPending and
        its own record, and then throws, so the machine stays stopped for
        Finish the restore. So does a restore that leaves a LUN with no disk,
        and one whose data disk stopped part way on a machine that runs again.
        The engine wrote the record and the report only after a restore that
        returned, so they said "migrated" until the daily check.

        This restore wrote its record when the record names its engine
        operation (restore.operationId, as FINISH-NO-RESTORE-RECORD-1 reads
        it) and the machine's document changed during the operation: its
        version now is not -VersionBefore, read by the engine before the
        restore. A version not known before ('') does not stop the write.
        A refusal before the stop writes no record, and the report is built
        from the records, so writing it again would say the same - it is not
        written. Nor for a refused resume of a restore that already wrote its
        record: the document did not change.

        Throws only when the machine's record cannot be read; the engine says
        that in its output, and the restore's own error stands. The write
        itself never throws (Save-VmfRecordAndReport).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowEmptyString()][string]$OperationId,
        [Parameter()][AllowEmptyString()][string]$VersionBefore = ''
    )
    if (-not $OperationId) { return $false }
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath ('state/' + (Get-VmfVmKey -VmId $VmId) + '.json')
    if ($null -eq $text) { return $false }
    $doc = ([string]$text) | ConvertFrom-Json -Depth 64
    $rec = Get-VmfRecordField -Object $doc -Name 'restore'
    if (-not $rec) { return $false }
    if (-not [string]::Equals([string](Get-VmfRecordField -Object $rec -Name 'operationId'), $OperationId, [System.StringComparison]::Ordinal)) { return $false }
    if ($VersionBefore -and [string]::Equals((Get-VmfDocumentVersion -Text ([string]$text)), $VersionBefore, [System.StringComparison]::Ordinal)) { return $false }
    Save-VmfRecordAndReport -RunPath $RunPath -Reason 'putBack' | Out-Null
    $true
}