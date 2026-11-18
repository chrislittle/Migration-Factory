# SCHED-1: every five minutes, start any wave whose scheduled time has come.
# The schedule lives in the run store as a document, so this releases
# decisions somebody already recorded rather than holding state of its own -
# which is what makes a schedule visible and cancellable right up to the
# moment it fires.
param($Timer)

# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
# TIMER-EXEC-LIST-1: one list of the engine's executions answers every "does a
# run go on?" question of this pass, read again after anything in the pass
# starts an execution, and after 30 seconds. The put-back pass asked Azure for
# every page once for each open restore. A start still reads Azure itself.
Start-VmfFacadeEngineListPass
try {
    $root = Get-VmfFacadeStorePath
    # TIMER-PASS-LIMIT-1: AND EVERY PASS FITS THE SERVICE'S TIME LIMIT.
    # Measured (PERF-ANALYSIS-1): a median of 77 s a pass on 2026-11-02, growing
    # with the store, and two passes reached the 5-minute limit, which restarts
    # the worker. Now each pass stops STARTING runs at its time budget, writes
    # schedule-status.json with the run it reached, and the next pass goes on
    # from there - the mechanism of the daily cleanup
    # (PERF-RETENTION-TIMEOUT-1). The rules are in
    # Private/state/SchedulePass.ps1; schemas/schedule-status.schema.json is
    # the record.
    # SCHEDULE-PASS-DUE-1: AND A PASS READS ONLY WHAT IS DUE. Every pass read
    # every run - about 530 store calls and the whole 210-second budget - though
    # almost no run had anything due. Now a pass checks the runs of the due
    # record (schedule-due.json, Private/state/ScheduleDue.ps1): the runs an
    # engine start, a schedule or a plan sign-off marked, and the runs a check
    # still acts on. Once an hour it also checks every run (the sweep), and adds
    # to the record any run it finds a fact for - the safety net for a mark that
    # was lost.
    $passStartedUtc = (Get-Date).ToUniversalTime()
    $pass = $null
    function Write-SchedulePassRecord {
        param($Root, $Record, [switch]$Final)
        # A record with no finish says a pass is working, or was stopped by the
        # host - on checkingRunId, when it names one.
        $Record.finishedUtc = if ($Final) { (Get-Date).ToUniversalTime().ToString('o') } else { $null }
        try {
            # Through the root writer: the store root is a bare container in
            # Azure, which the ordinary writer refuses as a run path.
            & (Get-Module VmMigrationFactory) { param($r, $d) Write-VmfStoreRootJson -StorePath $r -Name 'schedule-status.json' -Document $d -Depth 6 } $Root $Record
        }
        catch { Write-Warning "schedule: could not write the schedule pass record: $($_.Exception.Message)" }
    }
    $previous = $null
    # A record that cannot be read is not a reason to check nothing: the pass
    # checks every run, as it did before there was a record.
    try { $previous = & (Get-Module VmMigrationFactory) { param($r) Read-VmfStoreRootJson -StorePath $r -Name 'schedule-status.json' } $root }
    catch { Write-Warning "schedule: could not read the schedule pass record: $($_.Exception.Message). This pass checks every run." }
    # SCHEDULE-PASS-DUE-1: the due record. One that cannot be read, is not
    # there, or cannot be used starts a sweep at once, so a run it lost is
    # found in this pass or the next ones.
    $due = $null
    try { $due = & (Get-Module VmMigrationFactory) { param($r) Read-VmfScheduleDue -StorePath $r } $root }
    catch { Write-Warning "schedule: could not read the record of the runs to check: $($_.Exception.Message). This pass checks every run." }
    $dueUsable = [bool]($due -and $due.Exists -and $due.Valid)
    $dueEntries = if ($due) { @($due.Entries) } else { @() }
    # The mark id of each run when the pass read the record: a run is removed
    # only while it still holds it (Merge-VmfScheduleDueChanges).
    $seenMarks = @{}
    foreach ($e in $dueEntries) { $seenMarks[[string]$e['runId']] = [string]$e['markId'] }
    $dueIds = @(& (Get-Module VmMigrationFactory) { param($e, $n) Select-VmfScheduleDueRuns -Entries $e -NowUtc $n } $dueEntries $passStartedUtc |
        Where-Object { Test-VmfFacadeRunFolder -Path ([string]$_) })
    $sweep = $true
    try { $sweep = [bool](& (Get-Module VmMigrationFactory) { param($p, $u, $n) Test-VmfScheduleSweepOpen -Previous $p -DueUsable $u -NowUtc $n } $previous $dueUsable $passStartedUtc) }
    catch { Write-Warning "schedule: could not decide whether this pass checks every run: $($_.Exception.Message). This pass checks every run." }
    # enumerate runs the same way the run list does: container prefixes
    # PROJECT-2: including the runs inside a project. This listed the top level
    # only, so a scheduled wave inside a project never started and a safety
    # copy inside one was never reaped.
    # SCHEDULE-PASS-DUE-1: only when this pass checks every run.
    $listed = if ($sweep) { @(Get-VmfFacadeRunIds -StorePath $root) } else { @() }
    # A record that cannot be used is read as no record, so a bad file never
    # stops every pass: this pass checks every run, and its start record below
    # writes over the file (the security review).
    try { $start = & (Get-Module VmMigrationFactory) { param($p, $d, $ids, $s, $n) New-VmfSchedulePassStart -Previous $p -DueRunIds $d -RunIds $ids -Sweep:$s -NowUtc $n } $previous $dueIds $listed $sweep $passStartedUtc }
    catch {
        Write-Warning "schedule: the schedule pass record could not be used: $($_.Exception.Message). This pass checks every run."
        if (-not $sweep) { $sweep = $true; $listed = @(Get-VmfFacadeRunIds -StorePath $root) }
        $start = & (Get-Module VmMigrationFactory) { param($d, $ids, $n) New-VmfSchedulePassStart -Previous $null -DueRunIds $d -RunIds $ids -Sweep -NowUtc $n } $dueIds $listed $passStartedUtc
    }
    $pass = $start.Record
    $changes = [System.Collections.Generic.List[object]]::new()
    if ($start.PassedOverRunId) {
        # Two passes were stopped by the host on this run. It is passed over
        # for this pass and named - in the service log and in the run's own
        # activity - so it cannot hold up every run after it. The next pass
        # checks it again.
        $passedOver = [string]$start.PassedOverRunId
        Write-Warning "schedule: the host stopped two passes on run '$passedOver'; this pass passes it over, and the next pass that reaches it checks it again"
        try {
            & (Get-Module VmMigrationFactory) { param($sp)
                Write-VmfStepLine -RunPath $sp -Step 'schedule' -Outcome fail `
                    -Detail 'The service did not complete the check of this migration in its time limit, in two passes. A scheduled wave, a stopped wave or a stopped restore here waits until a pass completes the check.'
            } (Get-VmfFacadeStorePath -RunId $passedOver)
        }
        catch { Write-Warning "the line for run '$passedOver' could not be written: $($_.Exception.Message)" }
        # SCHEDULE-PASS-DUE-1: and it stays in (or goes into) the record of the
        # runs to check, so the next pass checks it - not only the next sweep.
        $changes.Add([pscustomobject]@{ RunId = $passedOver; SeenMarkId = $(if ($seenMarks.ContainsKey($passedOver)) { $seenMarks[$passedOver] } else { $null }); Needed = $true; NextUtc = $null })
    }
    # Written now: if the host stops this pass before its first run ends, the
    # store says where it was.
    Write-SchedulePassRecord -Root $root -Record $pass
    # The due runs first, then the runs of the sweep.
    $dueRuns = @($start.DueRuns)
    $sweepRuns = @($start.SweepRuns)
    $runIds = @($dueRuns) + @($sweepRuns)
    $sweepEnded = $sweep
    $next = 0
    foreach ($runId in $runIds) {
        $inSweep = $next -ge $dueRuns.Count
        # The budget: stop STARTING runs well inside the limit, so the run
        # started ends and the record is written. Said in the service log, with
        # the count: nothing about a run left for the next pass is silent.
        if (-not (& (Get-Module VmMigrationFactory) { param($s) Test-VmfPassTimeLeft -StartedUtc $s } $passStartedUtc)) {
            $left = $runIds.Count - $next
            Write-Warning "schedule: the time for this pass is spent after $next of $($runIds.Count) runs. $left runs were not checked; the next pass starts at run '$runId'"
            $pass.runsNotChecked = $left
            # A sweep goes on from its first run not checked. A due run not
            # checked stays in the record, and the next pass checks it first.
            $pass.resumeAtRunId = if ($inSweep) { $runId } elseif ($sweepRuns.Count) { $sweepRuns[0] } else { $null }
            $sweepEnded = $false
            break
        }
        $next++
        # SCHEDULE-PASS-DUE-1: a run of the due record that is not in the store
        # any more (deleted, or a name the store refuses) is not checked - a
        # check that wrote a line there would make a folder for it again. It
        # leaves the record. "In the store" is the sweep's own rule: a folder
        # with anything in it (Test-VmfStoreRunPresent). A store that does not
        # answer is not "gone".
        if (-not $inSweep) {
            $gone = $false
            try {
                $runPath = Get-VmfFacadeStorePath -RunId $runId
                try { $gone = -not [bool](& (Get-Module VmMigrationFactory) { param($sp) Test-VmfStoreRunPresent -RunPath $sp } $runPath) }
                catch { $gone = $false }
            }
            catch { $gone = $true }
            if ($gone) {
                $changes.Add([pscustomobject]@{ RunId = $runId; SeenMarkId = $(if ($seenMarks.ContainsKey($runId)) { $seenMarks[$runId] } else { $null }); Needed = $false; NextUtc = $null })
                $pass.runsChecked++
                continue
            }
        }
        # Before the run: the run the pass is on, so a pass the host stops is
        # counted against it.
        $pass.checkingRunId = $runId
        $pass.checkingStops = if ($start.StoppedRunId -and $runId -eq [string]$start.StoppedRunId) { [int]$start.StoppedCount } else { 0 }
        if ($inSweep) { $pass.resumeAtRunId = $runId }
        Write-SchedulePassRecord -Root $root -Record $pass
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # EVAL-H10: this try/catch used to sit OUTSIDE the loop, so one bad run
            # abandoned the pass for every run after it in enumeration order -
            # every five minutes, for ever. A schedule naming a wave with no plan
            # entries (the wave was renamed after it was scheduled) makes
            # Test-VmfWaveWindow throw, which is permanent, not transient, so the
            # comment's promise that "the next pass retries" was never true for it.
            # And because the failure was swallowed, the invocation recorded as a
            # SUCCESS - so the project's own support query, AppRequests where
            # Success == false, could not find it either.
            $store = Get-VmfFacadeStorePath -RunId $runId
            # Two jobs, two records. Seen 2026-09-05 on screen, two
            # red "schedule" lines: the RESUME check had failed (the engine job
            # was gone for ten minutes during a rebuild) and the one shared catch
            # called it "a scheduled wave could not be released" - in a run that
            # had no schedule at all. Each failure now says what it is.
            try {
                $released = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $store -RunId $runId)
                foreach ($r in $released) {
                    Write-Host "started scheduled wave '$($r.Wave)' in run '$runId' (execution $($r.Execution))"
                }
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "schedule pass failed for run '$runId': $reason"
                # Say it where a person will see it, not only in a platform log.
                # STEP-LOG-6: through Write-VmfStepLine, so a line that cannot be written
                # is a warning in the service log, with its words, and the pass goes on.
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'schedule' -Outcome fail `
                        -Detail "A scheduled wave could not be released: $why. Scheduled waves in this run will not start until this is dealt with."
                } $store $reason
            }
            # FACADE-TIMER-QUEUE-1: the run's machine records, read ONCE for the
            # stalled-wave pass and the put-back pass. Each read every record
            # itself, and a pass took 60 to 133 seconds on the lab installation.
            # A read that fails gives them nothing, so each reads for itself and a
            # failure is said in its own record, as before.
            $stateDocs = $null
            $stateDocsReadUtc = (Get-Date).ToUniversalTime()
            try { $stateDocs = @(Get-VmfFacadeRunStateDocs -StorePath $store) }
            catch { $stateDocs = $null }
            # RESUME-1: and start again any wave that stopped mid-flight with
            # nobody working on it. Same pass, same cadence, same visibility.
            try {
                $resumed = @(Invoke-VmfFacadeResumeStalledWaves -StorePath $store -RunId $runId -StateDocs $stateDocs)
                foreach ($r in $resumed) {
                    Write-Host "resumed stalled wave '$($r.Wave)' in run '$runId' (execution $($r.Execution))"
                }
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "resume check failed for run '$runId': $reason"
                # STEP-LOG-6: through Write-VmfStepLine, so a line that cannot be written
                # is a warning in the service log, with its words, and the pass goes on.
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'resume' -Outcome fail `
                        -Detail "The engine could not be checked for a wave that stopped mid-flight: $why. A stopped wave in this run will not be restarted until this is dealt with."
                } $store $reason
            }
            # STALE-WAVE-HOLD-1: and remove the hold a stopped wave worker left on
            # a machine whose move ended, so a restore of it is not refused. Its
            # own record: a failure here is not a wave's.
            try {
                $freed = @(Invoke-VmfFacadeRemoveEndedWaveHolds -StorePath $store -RunId $runId)
                foreach ($r in $freed) {
                    Write-Host "removed the hold of the stopped worker '$($r.WorkerId)' on '$($r.VmId)' at $($r.State) in run '$runId'"
                }
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "ended-hold check failed for run '$runId': $reason"
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'watchdog' -Outcome fail `
                        -Detail "The service could not check for a hold that a stopped worker left on a machine whose move ended: $why. It asks again on the next pass."
                } $store $reason
            }
            # RESTORE-END-JOB-1: and start again a restore whose job
            # stopped part way - the same pass and the same questions as a wave.
            # Its own record: a failure here is not a wave's.
            try {
                # TIMER-PASS-LIMIT-1 (the FACADE-TIMER-QUEUE-1 review): the
                # records were read before the stalled-wave and hold passes. A
                # put-back job that ended or started again since is not seen in
                # them, so records older than 30 seconds are read again here.
                $putBackDocs = & (Get-Module VmMigrationFactory) { param($d, $t) Select-VmfScheduleStateDocs -StateDocs $d -ReadUtc $t } $stateDocs $stateDocsReadUtc
                $putBacks = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath $store -RunId $runId -StateDocs $putBackDocs)
                foreach ($r in $putBacks) {
                    Write-Host "$($r.Action) the $($r.Kind) of '$($r.VmId)' in run '$runId' (operation $($r.OperationId)$(if ($r.Execution) { ", execution $($r.Execution)" }))"
                }
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "restore resume check failed for run '$runId': $reason"
                # STEP-LOG-6: through Write-VmfStepLine, so a line that cannot be written
                # is a warning in the service log, with its words, and the pass goes on.
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'resume' -Outcome fail `
                        -Detail "The service could not check for a restore that stopped part way: $why. It asks again on the next pass."
                } $store $reason
            }            # VOLUMES-CHECK-JOB-STOP-1: and return a machine that Check the
            # volumes started and whose job stopped before the return. Its own
            # record: a failure here is not a restore's.
            try {
                $volumeChecks = @(Invoke-VmfFacadeResumeStalledVolumeChecks -StorePath $store -RunId $runId -StateDocs $putBackDocs)
                foreach ($r in $volumeChecks) {
                    Write-Host "$($r.Action) the check of the volumes of '$($r.VmId)' in run '$runId'$(if ($r.Execution) { " (execution $($r.Execution))" })"
                }
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "volume check resume failed for run '$runId': $reason"
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'resume' -Outcome fail `
                        -Detail "The service could not check for a check of the volumes that did not finish: $why. It asks again on the next pass."
                } $store $reason
            }

            # SCAN-FAIL-SHOWN-1: and end the wizard's wait for a scan whose job
            # ended with no answer - from the list of executions this pass
            # keeps. Its own record, in the service log only: a check of the
            # service that failed is not a fact about the run, and the next
            # pass asks again.
            try {
                $silent = Invoke-VmfFacadeEndSilentScan -StorePath $store -RunId $runId
                if ($silent) {
                    Write-Host "ended the scan of run '$runId': the engine job execution $($silent.Execution) has the status $($silent.Status) and the scan wrote no answer"
                }
            }
            catch {
                Write-Warning "scan end check failed for run '$runId': $($_.Exception.Message). It asks again on the next pass."
            }
            # PLANRUN-1: and when a wave of a signed-off plan has finished, start
            # the next one - unless it has a start time, or a machine is waiting
            # for a person. After the resume check on purpose: a stalled wave is
            # finished before anything new begins.
            try {
                $continued = Invoke-VmfFacadeContinuePlan -StorePath $store -RunId $runId
                if ($continued) {
                    Write-Host "started wave '$($continued.Wave)' of the signed-off plan in run '$runId' (execution $($continued.Execution))"
                }
            }
            catch {
                $reason = $_.Exception.Message
                Write-Warning "plan continue check failed for run '$runId': $reason"
                # STEP-LOG-6: through Write-VmfStepLine, so a line that cannot be written
                # is a warning in the service log, with its words, and the pass goes on.
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'planrun' -Outcome fail `
                        -Detail "The next wave of the signed-off plan could not be started: $why. It will be tried again on the next pass."
                } $store $reason
            }
            # ODCR-STATUS-1: and read from Azure a capacity reservation whose
            # quota record is stuck at RESERVING, when no reserve or release job
            # of the run runs - by the resource ID the engine recorded before
            # it asked. Its own record, in the service log only: a read that
            # failed is not a fact about the run, the next pass reads it again,
            # and the page keeps its 60-minute rule for a record never read.
            $reservingLeft = $null
            try {
                $reading = Invoke-VmfFacadeReadReservingClaims -StorePath $store -RunId $runId
                foreach ($o in @($reading.Outcomes)) {
                    if ($o.Outcome -in @('held', 'failed', 'gone', 'making')) {
                        Write-Host "capacity reservation for $($o.Size) in $($o.Region) in run '$runId': $($o.Outcome) (provisioningState $($o.ProvisioningState))"
                    }
                }
                $reservingLeft = @($reading.Remaining)
            }
            catch {
                Write-Warning "capacity reservation check failed for run '$runId': $($_.Exception.Message). It asks again on the next pass."
            }
            # SCHEDULE-PASS-DUE-1: does a check still act on this run? Asked
            # after the checks, from the machine records read for them: a check
            # that started an engine marked the run again (a new mark id), so
            # the record keeps it whatever this finds. A run the record holds
            # and no fact names is asked of Azure too - an execution of a wave,
            # a restore or a finish that runs keeps it. An answer that cannot
            # be had keeps the run: unknown is never "nothing due".
            try {
                # ODCR-STATUS-1: the records still at RESERVING, as the check
                # above left them; $null when it failed, and then read again.
                $need = & (Get-Module VmMigrationFactory) { param($sp, $d, $r) Get-VmfRunScheduleNeed -RunPath $sp -StateDocs $d -ReservingClaims $r } $store $stateDocs $reservingLeft
                $needed = $null -ne $need.NextUtc
                if (-not $needed -and $seenMarks.ContainsKey($runId)) {
                    $needed = Test-VmfFacadeRunJobRunning -RunId $runId
                    $need = [pscustomobject]@{ NextUtc = $null; Reason = $(if ($needed) { 'engineRuns' } else { $null }) }
                }
                $changes.Add([pscustomobject]@{
                    RunId = $runId; SeenMarkId = $(if ($seenMarks.ContainsKey($runId)) { $seenMarks[$runId] } else { $null })
                    Needed = [bool]$needed
                    NextUtc = $(if ($needed -and $need.NextUtc) { ([datetime]$need.NextUtc).ToUniversalTime().ToString('o') } else { $null })
                })
            }
            catch {
                Write-Warning "schedule: could not decide whether run '$runId' has more to check: $($_.Exception.Message). The run stays in the record of the runs to check."
                $changes.Add([pscustomobject]@{ RunId = $runId; SeenMarkId = $(if ($seenMarks.ContainsKey($runId)) { $seenMarks[$runId] } else { $null }); Needed = $true; NextUtc = $null })
            }
        }
        catch {
            # Only naming the run's folder can reach here: each check above has
            # its own record. One run must not abandon the pass.
            Write-Warning "schedule pass failed for run '$runId': $($_.Exception.Message)"
        }
        finally {
            # After EVERY run the record moves on, so a pass the host stops
            # never counts a stop against a run it had finished.
            $pass.runsChecked++
            $took = $clock.ElapsedMilliseconds
            if ($null -eq $pass.slowestRun -or $took -gt [long]$pass.slowestRun.milliseconds) {
                $pass.slowestRun = [ordered]@{ runId = $runId; milliseconds = $took }
            }
            $pass.checkingRunId = $null
            $pass.checkingStops = 0
            if ($inSweep) {
                $at = $next - $dueRuns.Count
                $pass.resumeAtRunId = if ($at -lt $sweepRuns.Count) { $sweepRuns[$at] } else { $null }
            }
        }
    }
    # SCHEDULE-PASS-DUE-1: what the pass found goes into the due record, in one
    # version-checked write - after the runs, so a pass the host stops leaves
    # the record as it was, and the next pass checks the same runs again. A
    # record nothing changed is not written. A sweep is over only once the
    # record holds what it found: else the next pass starts a sweep again.
    $recorded = $true
    if ($changes.Count -or -not $dueUsable) {
        try {
            $recorded = [bool](& (Get-Module VmMigrationFactory) { param($r, $c) Update-VmfScheduleDue -StorePath $r -Changes $c } $root @($changes))
            if (-not $recorded) { Write-Warning 'schedule: the record of the runs to check changed at the same time five times, so this pass did not write what it found. The next pass checks every run.' }
        }
        catch {
            $recorded = $false
            Write-Warning "schedule: could not write the record of the runs to check: $($_.Exception.Message). The next pass checks every run."
        }
    }
    $pass.checkingRunId = $null
    $pass.checkingStops = 0
    if ($sweep -and $sweepEnded) {
        $pass.resumeAtRunId = $null
        if ($recorded) {
            $pass.sweepStartedUtc = $null
            $pass.lastSweepUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
    }
    if (-not $recorded) { $pass.lastSweepUtc = $null }
    Write-SchedulePassRecord -Root $root -Record $pass -Final
}
catch {
    # Only reading the records and listing the runs can reach here now; a
    # single run's failure is handled above and no longer abandons the others.
    Write-Warning "schedule pass failed before it could read the runs: $($_.Exception.Message)"
}
finally {
    # The worker can run a request next: it never reads a list this pass kept.
    Stop-VmfFacadeEngineListPass
    Complete-VmfFacadeCallTimings
}
