# REACH-1: once a day, delete the safety copies whose accepted retention has
# run out.
#
# WHY THIS EXISTS. The wave acceptance screen tells a customer their copies are
# kept for N days. Remove-VmfExpiredSafetyCopies has always been able to honour
# that, and NOTHING HAS EVER CALLED IT - no timer, no job, no button - so the
# promise was true only in the direction that costs money: every snapshot a
# migration took billed indefinitely.
#
# The deletion decision was already made by a person when they accepted the
# wave's retention. This does not make a new decision; it carries out the one
# on record. It is deliberately narrow for the same reason the cmdlet is: only
# machines that reached MIGRATED, only past their own wave's accepted number of
# days.
#
# THERE IS NO INSTALLATION-WIDE OFF SWITCH, and that is deliberate: the whole
# point of retention is that copies expire and are deleted (2026-08-30).
# One was written and taken out again the same day. How long copies are kept is
# already a per-wave lever a person accepts (keepSnapshotDays, 0-90); a setting
# that switched the whole installation off would make every one of those
# accepted answers silently untrue, which is the same defect as the promise
# that nothing enforced in the first place. A wave that wants its copies for
# ninety days says ninety days.
param($Timer)

# RETAIN-UX-1: every pass leaves ONE record at the store root, whether or not
# it found anything - so the safety-copies card can say "last pass 03:30
# today, nothing due", and a pass that has been failing for a month does not
# look like one with nothing to do. Before 2026-09-04 nothing traced the
# cleanup of pending items anywhere.
#
# PERF-RETENTION-TIMEOUT-1: AND EVERY PASS FITS THE SERVICE'S TIME LIMIT.
# Measured on the lab install, 2026-10-27 to 2026-11-02: all 7 daily passes
# stopped at the 5-minute limit, so the runs after the point each reached were
# never examined, the record was never written, and the timeout restarted the
# worker. The timer now fires every hour. The day's cleanup (a cycle) starts at
# 03:30 UTC; each pass stops starting runs at its time budget, writes the
# record with the run it reached, and the next pass starts there. The rules
# are in Private/state/RetentionPass.ps1; schemas/retention-status.schema.json
# is the record.
$passStartedUtc = (Get-Date).ToUniversalTime()
$pass = $null
function Write-RetentionPassRecord {
    param($Root, $Record, [switch]$Final)
    # A record with no finish says a pass is working, or was stopped by the
    # host - and the next pass starts again at resumeAtRunId.
    $now = (Get-Date).ToUniversalTime()
    $Record.finishedUtc = if ($Final) { $now.ToString('o') } else { $null }
    $Record.nextPassUtc = (& (Get-Module VmMigrationFactory) { param($n, $c) Get-VmfRetentionNextPassUtc -NowUtc $n -CycleComplete:$c } $now ([string]::IsNullOrEmpty([string]$Record.resumeAtRunId))).ToString('o')
    try {
        # Through the root writer: the store root is a bare container in Azure,
        # which the ordinary writer refuses as a run path.
        & (Get-Module VmMigrationFactory) { param($r, $d) Write-VmfStoreRootJson -StorePath $r -Name 'retention-status.json' -Document $d -Depth 6 } $Root $Record
    }
    catch { Write-Warning "could not write the retention pass record: $($_.Exception.Message)" }
}

# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $root = Get-VmfFacadeStorePath
    # PERF-RETENTION-TIMEOUT-1: what this pass does, from the record of the
    # last one - start the day's cycle, continue it, or nothing until 03:30.
    $previous = & (Get-Module VmMigrationFactory) { param($r) Read-VmfStoreRootJson -StorePath $r -Name 'retention-status.json' } $root
    $action = & (Get-Module VmMigrationFactory) { param($p, $n) Get-VmfRetentionPassAction -Previous $p -NowUtc $n } $previous $passStartedUtc
    if ($action -eq 'done') {
        Write-Host 'retention: the cleanup of today examined every migration. The next cleanup starts at 03:30 UTC.'
        return
    }
    if ($action -eq 'newCycle') {
        # ATTEST-1: the migration records past their 90 days, first - in their own
        # error handling, so a record that cannot be read does not stop the safety
        # copies below. A record is kept for 90 days after it was last written -
        # when a wave ended, when an administrator downloaded it, or when the
        # migration was deleted. A record whose date cannot be read is kept:
        # unknown is not old. Once a cycle: a day is the unit of the 90.
        try {
            $expired = @(& (Get-Module VmMigrationFactory) { param($r) Remove-VmfExpiredMigrationRecords -StorePath $r } $root)
            foreach ($x in $expired) { Write-Host "removed the migration record '$($x.Name)' - kept until $($x.KeepUntilUtc)" }
        }
        catch { Write-Warning "the migration records could not be checked for expiry: $($_.Exception.Message)" }
    }
    # PROJECT-2: including the runs inside a project. This listed the top level
    # only, so a scheduled wave inside a project never started and a safety
    # copy inside one was never reaped.
    $listed = @(Get-VmfFacadeRunIds -StorePath $root)
    $start = & (Get-Module VmMigrationFactory) { param($p, $a, $ids, $n) New-VmfRetentionPassStart -Previous $p -Action $a -RunIds $ids -NowUtc $n } $previous $action $listed $passStartedUtc
    $pass = $start.Record
    if ($start.StalledRunId) {
        # Two passes were stopped by the host on this run. It is passed over
        # for this cycle and named - on the record the card reads, and in the
        # run's own activity - so it cannot hold up every run after it.
        $stalled = [string]$start.StalledRunId
        Write-Warning "retention: the host stopped two passes on run '$stalled'; it is passed over until the next cleanup"
        try {
            & (Get-Module VmMigrationFactory) { param($sp)
                Write-VmfStepLine -RunPath $sp -Step 'retention' -Outcome fail `
                    -Detail 'The daily cleanup did not complete the check of this migration in the time limit of the service, in two passes. Copies past their retention stay, and you pay for them, until a daily cleanup completes the check.'
            } (Get-VmfFacadeStorePath -RunId $stalled)
        }
        catch { Write-Warning "the line for run '$stalled' could not be written: $($_.Exception.Message)" }
    }
    # Written now: if the host stops this pass before its first run ends, the
    # store says where it was.
    Write-RetentionPassRecord -Root $root -Record $pass
    $runIds = @($start.Runs)
    $next = 0
    foreach ($runId in $runIds) {
        # The budget: stop STARTING runs well inside the limit, so the run
        # started ends and the record is written.
        if (-not (& (Get-Module VmMigrationFactory) { param($s) Test-VmfRetentionTimeLeft -StartedUtc $s } $passStartedUtc)) {
            Write-Host "retention: the time for this pass is spent; the next pass starts at run '$runId'"
            $pass.resumeAtRunId = $runId
            $pass.resumeStops = 0
            break
        }
        $next++
        $pass.runsExamined++
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $ms = [ordered]@{ report = 0; summary = 0; copies = 0 }
        $store = $null
        # EVAL-H10's lesson, applied here from the start: one bad run must not
        # abandon the pass for every run after it in enumeration order.
        try {
            $store = Get-VmfFacadeStorePath -RunId $runId
            # PROJECT-3: only a migration has safety copies. An ASSESSMENT has
            # no plan and never will, so reading one and failing told the operator
            # "copies past their retention are still being kept, and still
            # being billed" about a run that holds no copies - every day, for
            # every assessment. A run with nothing to reap is not a failure.
            # RETAIN-KIND-1: asked of the one rule the pages use.
            # RETAIN-KIND-1 review: and a migration with no plan, or a plan of
            # no machines, has moved nothing and holds no copies. Going on read
            # its missing plan as a failure every day ("still being billed"),
            # the PROJECT-3 defect
            # again, and wrote a report for it. The pages call it set up only.
            $verdict = & (Get-Module VmMigrationFactory) { param($rp)
                $manifest = Read-VmfStoreJson -RunPath $rp -RelPath 'run.json'
                if ((Get-VmfRunKind -Manifest $manifest) -ne 'migration') { return 'notMigration' }
                # The rule the run pages use for "set up only" (RUN-LIFECYCLE-1).
                $planDoc = Read-VmfPlanDocument -RunPath $rp
                if ((Get-VmfRunStage -Plan $planDoc).Stage -eq 'setup') { return 'setup' }
                'migration'
            } $store
            if ($verdict -ne 'migration') { continue }
            # REPORT-AUTO-1 review 3: the daily check of the reports. A report
            # whose write failed, or one older than the newest change (a
            # capacity release, say, which writes no report itself), is written
            # again here - the trigger every warning about a failed write
            # promises. In its own try: a report that cannot be written must not
            # stop the safety copies below, or the next run.
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $state = & (Get-Module VmMigrationFactory) { param($rp) Update-VmfStaleReport -RunPath $rp } $store
                if ($state -ne 'current') { Write-Host "record and report: '$runId' - $state by the daily check" }
            }
            catch { Write-Warning "the report of run '$runId' could not be checked: $($_.Exception.Message)" }
            $ms.report = $sw.ElapsedMilliseconds
            # APPROVE-GROUP-1: and the summary the list on the Migrations page
            # reads - written again where a write failed or a change had no
            # trigger of its own, and given to a migration from before it
            # existed. It writes nothing when the summary is current, and never
            # throws: a warning in the run history says why it failed.
            $sw.Restart()
            $null = & (Get-Module VmMigrationFactory) { param($rp) Update-VmfRunSummary -RunPath $rp -Reason 'dailyCheck' } $store
            $ms.summary = $sw.ElapsedMilliseconds
            $plan = Get-VmfFacadePlanPath -StorePath $store

            # Ask what WOULD go before starting anything. This runs in the
            # function app, which has no rights over customer machines - and
            # needs none, because -WhatIf never reaches the delete. Starting a
            # container job for every run every day, to discover that almost
            # all of them have nothing to do, is the version of this that costs
            # more than the snapshots.
            $sw.Restart()
            $preview = & (Get-Module VmMigrationFactory) { param($rp, $pp)
                Remove-VmfExpiredSafetyCopies -RunPath $rp -PlanPath $pp -WhatIf -DeletedBy 'retention (scheduled)' -WarningAction SilentlyContinue
            } $store $plan
            $ms.copies = $sw.ElapsedMilliseconds
            $eligible = @($preview.Eligible).Count
            # ROLLBACK-DISKS-FIRST-1: the rollback disks that
            # nothing used are due as soon as a move ends, with no waiting
            # days - a cleanup starts for them too.
            $disksDue = @($preview.RollbackDisksBeforeMove).Count
            # MADE-DISK-RECORD-1: and the disks a rollback, a restore or a
            # rebuild made from a copy that nothing used, once the move ended.
            $madeDue = @($preview.MadeDisks).Count
            if ($eligible -eq 0 -and $disksDue -eq 0 -and $madeDue -eq 0) { continue }
            $pass.runsWithCopiesDue++
            $pass.machinesDue += $eligible

            # The engine has the rights to delete; the facade does not. Same
            # split as every other action that touches a customer's resources.
            $r = Invoke-VmfFacadeStartEngine `
                -Principal ([pscustomobject]@{ Identity = 'retention (scheduled)'; Roles = @('Vmf.Operator') }) `
                -Operation 'retention' -RunId $runId `
                -Note "scheduled retention: $eligible machine(s) past their accepted retention, $disksDue machine(s) with rollback disks that nothing used, $madeDue machine(s) with other disks made from the safety copies that nothing used"
            Write-Host "retention: started cleanup for run '$runId' ($eligible machine(s), $disksDue with rollback disks, execution $($r.Execution))"
            $pass.executionsStarted += [ordered]@{ runId = $runId; machines = $eligible; execution = [string]$r.Execution }
        }
        catch {
            $reason = $_.Exception.Message
            Write-Warning "retention pass failed for run '$runId': $reason"
            $pass.failures += [ordered]@{ runId = $runId; reason = $reason }
            # STEP-LOG-6: through Write-VmfStepLine, so a line that cannot be written
            # is a warning in the service log, with its words, and the pass goes on.
            # A run whose folder could not be named has no log to write in.
            if ($store) {
                & (Get-Module VmMigrationFactory) { param($sp, $why)
                    Write-VmfStepLine -RunPath $sp -Step 'retention' -Outcome fail `
                        -Detail "The daily cleanup did not run: $why. The safety copies past their retention stay, and Azure bills them."
                } $store $reason
            }
        }
        finally {
            # PERF-RETENTION-TIMEOUT-1: after EVERY run - also one passed over
            # with continue - the record moves to the next run, so a pass the
            # host stops never makes the next one examine this run again. A
            # trace line per run says which check takes the time.
            $total = $clock.ElapsedMilliseconds
            Write-Host "retention: '$runId' examined in $total ms (report $($ms.report) ms, summary $($ms.summary) ms, copies $($ms.copies) ms)"
            if ($null -eq $pass.slowestRun -or $total -gt [long]$pass.slowestRun.milliseconds) {
                $pass.slowestRun = [ordered]@{ runId = $runId; milliseconds = $total; reportMs = $ms.report; summaryMs = $ms.summary; copiesMs = $ms.copies }
            }
            $pass.resumeAtRunId = if ($next -lt $runIds.Count) { $runIds[$next] } else { $null }
            $pass.resumeStops = 0
            if ($pass.resumeAtRunId) { Write-RetentionPassRecord -Root $root -Record $pass }
        }
    }
    Write-RetentionPassRecord -Root $root -Record $pass -Final
}
catch {
    Write-Warning "retention pass failed before it could read the runs: $($_.Exception.Message)"
    # A pass that failed before it had a record of its own writes one with no
    # cycle start, so the next pass starts the day's cycle again rather than
    # reading this one as done.
    if ($null -eq $pass) {
        $pass = (& (Get-Module VmMigrationFactory) { param($n) New-VmfRetentionPassStart -Action 'newCycle' -RunIds @() -NowUtc $n } $passStartedUtc).Record
        $pass.cycleStartedUtc = $null
        # An unfinished cycle stays unfinished: the next pass starts at the
        # run this one would have started at.
        if ($action -eq 'continue') {
            $pass.cycleStartedUtc = [string]$previous.cycleStartedUtc
            $pass.resumeAtRunId = [string]$previous.resumeAtRunId
        }
    }
    $pass.failures += [ordered]@{ runId = ''; reason = "the pass could not read the runs: $($_.Exception.Message)" }
    try { Write-RetentionPassRecord -Root (Get-VmfFacadeStorePath) -Record $pass -Final } catch { Write-Warning "and could not record that either: $($_.Exception.Message)" }
}
finally {
    Complete-VmfFacadeCallTimings
}
