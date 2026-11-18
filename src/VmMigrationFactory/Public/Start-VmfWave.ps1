function Start-VmfWave {
    <#
    .SYNOPSIS
        Execute one wave of a migration plan: throttled worker processes lease
        per-VM state machines from the state store, with a watchdog, circuit
        breaker, and live status. The parent process never converts anything -
        it only spawns, monitors, reaps, and reports.
    .PARAMETER WhatIfOnly
        Render the wave's planned actions per VM without spawning anything.
    .PARAMETER CapacityGate
        Overrides the ring policy's capacityGate for the pre-flight check.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][int]$ThrottleLimit = 5,
        # SCALE-2: when more than one container works this wave, the wave's
        # TOTAL "at once" (recorded in run status, so a resume restarts the
        # same shape) and which container this is, as "i/N". Alone: 0 and
        # '1/1', which is every wave before SCALE-2.
        [Parameter()][int]$ThrottleTotal = 0,
        [Parameter()][string]$Container = '1/1',
        # EVAL-H1: this was 180 while the engine performs single waits of up to
        # 600 seconds (a first boot onto new hardware) and 360 (a large
        # deallocate). The heartbeat now ticks inside those waits, so 180 would
        # in principle be safe - but a lease shorter than the longest thing the
        # engine does is the engine contradicting itself, and any wait somebody
        # adds without a heartbeat would reap a healthy worker again. The
        # derived test in LeaseBudget.Tests.ps1 fails if a longer wait appears.
        [Parameter()][int]$LeaseTimeoutSeconds = 900,
        [Parameter()][int]$ConsecutiveFailureLimit = 3,
        [Parameter()][double]$FailureRateLimit = 0.2,
        [Parameter()][switch]$WhatIfOnly,
        [Parameter()][switch]$SkipCapacityGate,
        # WAVE-APPROVE-1 (review 4): the version of THIS WAVE a caller judged
        # (Get-VmfWaveVersion) - the timer's next wave of a signed-off plan.
        # The timer judges on one read and this starts on another, so a wave
        # whose own read differs does not start: the same mechanism as each
        # worker's -WaveVersion. Omitted, this judges its own read, as before.
        [Parameter()][string]$WaveVersion,
        # SCHEDULE-WAVE-VERSION-1: the start id of a scheduled start
        # (VMF_SCHEDULE_START). With -WaveVersion: a read of the wave that is
        # the judged version removes the schedule; one that differs puts it
        # back to pending, so the wave stays scheduled.
        [Parameter()][string]$ScheduleStartId
    )

    # WAVE-MIX-2: the plan is read ONCE, as text. The acceptance and the
    # approval judge this copy (the quota check reads the file again, which can
    # only refuse more), and each worker is told the version of THIS WAVE of
    # it: a worker whose own read gives another version takes no machine, so
    # an edit to the wave made between these checks and the workers' start can
    # never run unchecked.
    # WAVE-APPROVE-1: the WAVE's version, not the whole plan's. What lets this
    # wave start - the acceptance, the approval, the subscriptions and the
    # quota records of its machines - is read from this wave's entries and the
    # plan-wide fields, all inside the wave version (Get-VmfWaveVersion). The
    # quota check also counts the whole plan's family totals, but a change
    # there can only make it refuse. So an equal wave version means nothing
    # that let this wave start has changed on the worker's read. Comparing the
    # whole plan refused a wave whose approval an edit to ANOTHER wave had kept.
    $read = Read-VmfPlanFileVersioned -Path $PlanPath
    if (-not $read) { throw "No plan found at '$PlanPath'." }
    $checkedWaveVersion = Get-VmfWaveVersion -PlanText $read.Text -Wave $Wave
    $plan = $read.Plan
    # ACCEPT-SET-1: the machines of the wave that move - one rule, shared with
    # the acceptance, the start gate and a decision's carry-forward.
    $entries = @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $Wave)
    if ($entries.Count -eq 0) { throw "Wave '$Wave' has no executable entries in $PlanPath." }
    $runId = Split-Path $RunPath -Leaf
    Initialize-VmfRun -RunPath $RunPath -RunId $runId | Out-Null

    if ($WhatIfOnly) {
        Write-Host "Wave '$Wave' - planned actions (nothing will execute):"
        foreach ($entry in $entries) {
            $name = ($entry.vmId -split '/')[-1]
            Write-Host ("  {0,-30} {1} -> {2}  Path {3}" -f $name, $entry.assessment.sourceSize,
                $entry.target.size, $entry.path)
        }
        return [pscustomobject]@{ Wave = $Wave; Planned = $entries.Count; Executed = 0; WhatIf = $true }
    }

    # WAVE-APPROVE-1 (review 4): the start the timer decided is for the wave
    # it judged. Ordinal: a version is lower-case hex.
    if ($WaveVersion -and -not [string]::Equals($checkedWaveVersion, $WaveVersion, [System.StringComparison]::Ordinal)) {
        # STARTS-SOON-WORDS-1: only the service's own start (the signed-off plan
        # continuing, FacadeCore) passes -WaveVersion, so both checks are its own.
        # Thrown, as every start gate here is: the migration's page shows the
        # first sentence under "The start of a wave did not work".
        # SCHEDULE-WAVE-VERSION-1: a scheduled start. The service's pass left
        # the schedule on record for this run to settle; the wave did not
        # start, so the schedule goes back to pending - only the record of
        # THIS start, version-checked - and the pass judges the wave as it is
        # now. Put back BEFORE the throw, so the words are true when read.
        if ($ScheduleStartId) {
            $back = $false
            try { $back = [bool](Reset-VmfScheduleStartRecord -RunPath $RunPath -Wave $Wave -StartId $ScheduleStartId) }
            catch { Write-Warning "the schedule of wave $Wave could not be set to pending again: $($_.Exception.Message)" }
            if ($back) {
                throw "Wave $Wave changed after the service checked it for its scheduled start, so it did not start. It stays scheduled, and the service checks it again on its next pass."
            }
            throw "Wave $Wave changed after the service checked it for its scheduled start, so it did not start. The engine could not keep its schedule, so the wave is not scheduled. To start it, select Start this wave."
        }
        throw "Wave $Wave changed after the service checked it for this start, so it did not start. The service checks the wave again at its next check."
    }
    # SCHEDULE-WAVE-VERSION-1: this run reads the wave the scheduled start
    # judged, so the start time goes now. Only the record of THIS start. A
    # removal that fails never stops the wave: the service removes the start
    # time after this run, and never starts the wave again for it.
    if ($ScheduleStartId) {
        try {
            if (Remove-VmfScheduleOfStart -RunPath $RunPath -Wave $Wave -StartId $ScheduleStartId) {
                Write-VmfStepLine -RunPath $RunPath -Step 'schedule' -Outcome info -Detail "Wave $Wave started at its scheduled time, and the engine removed its start time."
            }
        }
        catch {
            Write-VmfStepLine -RunPath $RunPath -Step 'schedule' -Outcome warn -Detail "Wave $Wave started at its scheduled time, but the engine could not remove its start time: $(([string]$_.Exception.Message).TrimEnd('.')). The service removes it when this run ends, and does not start the wave again."
        }
    }

    # APPR-1 approval gate: engine-enforced, fails closed, no skip switch by
    # design - an unapproved wave must never start from ANY interface.
    # WAVE-2 lever 2: approval defaults ON, and a wave that says nothing about
    # it is treated as requiring it. Only an explicit requireApproval=false
    # turns the gate off, and that is a per-wave decision a person accepts.
    # IAC-2: before ANY wave moves, the drift question must have been put to a
    # person and accepted. Checked in the engine rather than the wizard, because
    # a wizard-only gate is bypassed by the API path - which is how the engine
    # job actually runs.
    # GATE-WORDS-1: each gate refusal is the gate's own two sentences - what is
    # missing, then which button does it. The migration's page shows the FIRST
    # sentence of the last failure (splitFailure) under "The start of a wave
    # did not work", so a lead such as "Wave X cannot start." would hide the
    # reason behind Show. "options gate failed" was the engine talking to itself.
    $ackGate = Test-VmfRunAcknowledged -RunPath $RunPath
    if (-not $ackGate.Pass) {
        throw [string]$ackGate.Detail
    }

    # WAVE-2: for every wave created, a user must select the options. Defaults
    # can be set, but they must be clicked and accepted. Engine-enforced for the same reason the IaC gate is - a
    # wizard-only gate is bypassed by the API path. Bound by hash to the
    # wave's exact levers and membership, so an edit after acceptance means
    # accepting again.
    # ACCEPT-SET-1: the entries every caller hashes, from one place.
    $optionsGate = Test-VmfWaveOptionsAccepted -RunPath $RunPath -Entries (Get-VmfWaveOptionsEntries -Plan $plan -Wave $Wave) -Wave $Wave
    if (-not $optionsGate.Pass) {
        # DECIDE-KEEP-1: said in the log with the wave and a code, so the page
        # can show "changed since accepted" and offer to accept again. Its own
        # chip trusted an acceptance file that exists, and a run stuck here had
        # no way out from the screen.
        if ($optionsGate.Code -eq 'changed') {
            Write-VmfOptionsChangedRefusal -RunPath $RunPath -Wave $Wave -Detail $optionsGate.Detail | Out-Null
        }
        throw [string]$optionsGate.Detail
    }

    # RUN-CLAIM-1: does another migration already hold any of these machines?
    # The lease-time claim is the real gate, but finding out HERE means finding
    # out before a wave starts rather than machine by machine during one.
    $runIdForClaims = [string](Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6).runId
    $claimGate = Test-VmfVmClaims -RunPath $RunPath -Entries $entries -RunId $runIdForClaims
    if (-not $claimGate.Pass) {
        throw "Wave '$Wave' cannot start: $($claimGate.Detail)"
    }

    # ENGINE-SUB-1: refuse the whole wave up front rather than parking every
    # machine in it one at a time. This engine addresses machines by resource
    # group and name, which are unique only inside a subscription, so a wave
    # holding machines from another one cannot be run safely from here.
    $subGate = Test-VmfWaveSubscriptions -Entries $entries
    if (-not $subGate.Pass) {
        Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome fail -Data @{ wave = $Wave } -Detail $subGate.Detail
        throw "Wave '$Wave' cannot start: $($subGate.Detail)"
    }

    # WAVE-APPROVE-1: on the text read above - the text the workers' version
    # comes from - so the approval and the workers speak of one plan.
    $approvalGate = Test-VmfWaveApproval -RunPath $RunPath -PlanPath $PlanPath -Wave $Wave -PlanText $read.Text
    if (-not $approvalGate.Pass) {
        throw [string]$approvalGate.Detail
    }

    # GPU-SCOPE-1 review: a wave whose every machine still to run is outside
    # the scope of this tool needs no capacity - the quota check writes no
    # record for it, and the gate would wait for one for ever. It starts, and
    # PRECHECK stops each machine untouched with its own reason.
    $noCapacity = $false
    if (-not $SkipCapacityGate) {
        $noCapacity = Resolve-VmfWaveNeedsNoCapacity -RunPath $RunPath -Entries $entries
        # Once per wave: with several containers, each one asks this.
        if ($noCapacity -and ($Container -notmatch '^(\d+)/' -or $Matches[1] -eq '1')) {
            Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome info -Data @{ wave = $Wave } `
                -Detail "Each machine of wave '$Wave' that is still to run is outside the scope of this tool, so no machine uses capacity. Each machine stops at Checking with its reason."
        }
    }

    # QUOTA-STARTED-TWICE-1: the capacity gate judges only the machines that do
    # NOT continue a move they started (Get-VmfContinuingMoves: past PRECHECK,
    # in a working state). Such a machine finishes the move it started
    # (STATE-TARGET-1) or fails at its resize and rolls back - one change
    # window. Judged here, it was asked for twice once Azure's usage counted it
    # on its target size, and a refused restart left it stopped mid-move. The
    # quota check still counts the need of one not yet resized, first. A
    # machine rolled back, or waiting for a decision, starts again from
    # PRECHECK on its next run, so it is judged like one not started. When
    # every machine still to run continues a move, the start asks nothing
    # about quota.
    $onlyStarted = $false
    $gateEntries = $entries
    if (-not $SkipCapacityGate -and -not $noCapacity) {
        $startedIds = @(Get-VmfContinuingMoves -RunPath $RunPath | ForEach-Object { $_.VmId })
        $gateEntries = @($entries | Where-Object { [string]$_.vmId -notin $startedIds })
        $doneIds = @(Get-VmfFinishedVmIds -RunPath $RunPath)
        $startedOpen = @($entries | Where-Object { [string]$_.vmId -in $startedIds })
        $leftOut = @(Get-VmfLeftOutVmIds -RunPath $RunPath -Entries $gateEntries -FinishedVmIds $doneIds)
        $notStartedOpen = @($gateEntries | Where-Object { [string]$_.vmId -notin $leftOut })
        if ($startedOpen.Count -gt 0 -and $notStartedOpen.Count -eq 0) {
            $onlyStarted = $true
            if ($Container -notmatch '^(\d+)/' -or $Matches[1] -eq '1') {
                Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome info -Data @{ wave = $Wave } `
                    -Detail "Each machine of wave '$Wave' that is still to run has started its move, so the start checks no quota. Each machine finishes its move, or rolls back."
            }
        }
    }
    # Capacity gate per the wave's lever (architecture section 10)
    if (-not $SkipCapacityGate -and -not $noCapacity -and -not $onlyStarted) {
        # OLD-VERSION-READERS-REMOVE-3: failed closed - a value that is not
        # BestEffort is the Reserved gate (Get-VmfCapacityGate).
        $gate = Get-VmfCapacityGate -PlanEntry $entries[0]
        # ODCR-GAP-1 (2026-09, CLOSED): this used to say that nothing in the
        # product called New-VmfWaveReservation, so a Reserved wave could
        # never start. That is no longer true - the wave editor has a Reserve
        # capacity control, the facade dispatches it, and the engine runs it.
        # The comment outlived the gap it described, which is its own small
        # version of the defect below: a message about a state nobody
        # re-checked.
        $generalNote = $null
        # ODCR-STATE-1: which sentence is true of these claims is pure logic,
        # so it lives in Get-VmfReservedCapacityRefusal and
        # Get-VmfReservedCoverRefusal where a test can drive every state. This
        # reads the store and throws.
        $readWaveClaims = {
            @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json' |
                ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$_" -Depth 12 } |
                Where-Object { $_.wave -eq $Wave })
        }
        $waveClaims = @(& $readWaveClaims)
        # RESERVE-COVER-1: the machines decide, not the records. Machines that
        # are MIGRATED or SKIPPED need none - the quota check leaves them out
        # of the demand on purpose - so a restart of a part-finished wave is
        # not refused for them. GPU-SCOPE-1: nor does a machine outside the
        # scope of this tool whose move has not started (Get-VmfLeftOutVmIds).
        # RESERVE-COVER-2: on BOTH gates. The BestEffort start used to check
        # the quota only when the wave had no records at all, so a partial set
        # passed and the machines of the missing cell moved with their quota
        # never checked.
        $finished = @(Get-VmfLeftOutVmIds -RunPath $RunPath -Entries $gateEntries)
        # CRG-MOVE-DEMAND-1: a machine in its own capacity reservation group
        # is judged on its quota check, as an availability set member is - by
        # the one rule, which needs this run's groups.
        $productGroupIds = @(Get-VmfProductReservationGroupIds -RunPath $RunPath)
        $noRecord = @(Get-VmfReservedCoverageGaps -Gate $gate -Claims $waveClaims -Entries $gateEntries -FinishedVmIds $finished -ProductGroupIds $productGroupIds |
            Where-Object Kind -eq 'noRecord')
        # RESERVE-RECHECK-1: EVERY start checks the quota of the wave again. A
        # start used to trust the records when every machine had one, so a
        # resumed wave started on a record that could be weeks old, and
        # something else may have used the quota since. A record of a
        # reservation is never replaced by the check (Test-VmfQuota keeps it).
        # Checking headroom is READ-ONLY - it verifies quota and reserves
        # nothing - so demanding that a person run it by hand, from a
        # dashboard that cannot run it, is a workflow gap rather than a
        # safety gate. Do it, say so, and judge the answer.
        # AVSET-RESERVE-1: choosing Reserved is a change to the wave, and a
        # change clears its quota records. Refusing here said "reserve
        # capacity" to a wave of availability-set machines, which can never
        # hold a reservation.
        # RESERVE-COVER-1: and when SOME machines have no record - a check
        # that stopped half way, or another container still writing the
        # same records. Each container completes the set itself rather than
        # wait for another: the records written are the same, and a record
        # of a reservation is never replaced.
        # RESERVE-COVER-2: the check is of THIS wave, on both gates. The
        # BestEffort start checked every wave of the plan, which rewrote
        # every other wave's records each time one cell of this one was
        # missing. The family totals are still the whole plan's.
        Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome info `
            -Detail $(if ($waveClaims.Count -eq 0) { "Wave '$Wave' has no quota check on record. The product checks the quota now. This check reserves nothing." }
                      elseif ($noRecord.Count -gt 0) { "$($noRecord.Count) $(if ($noRecord.Count -eq 1) { 'machine' } else { 'machines' }) of wave '$Wave' $(if ($noRecord.Count -eq 1) { 'has' } else { 'have' }) no quota record. The product checks the quota now. This check reserves nothing." }
                      else { "The product checks the quota of wave '$Wave' again, because a quota record can be old. This check reserves nothing." })
        # RESERVE-RECHECK-1 review: a check that does not finish - Azure does
        # not answer, or answers with nothing - refuses the start with its own
        # code and two sentences. What Azure said goes in the log.
        try { Test-VmfQuota -PlanPath $PlanPath -OutPath $RunPath -Wave $Wave -LeaveOutStarted | Out-Null }
        catch {
            $why = [string]$_.Exception.Message
            $open = @(Get-VmfLeftOutVmIds -RunPath $RunPath -Entries $gateEntries)
            $named = @($gateEntries | Where-Object { [string]$_.vmId -notin $open } | ForEach-Object {
                    [pscustomobject]@{ Name = ([string]$_.vmId -split '/')[-1]; Size = [string]$_.target.size } })
            $failed = New-VmfStartGateRefusal -Code 'quotaCheckFailed' -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $named)
            Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome refused -Detail ([string]$failed.Detail) `
                -Data @{ wave = $Wave; code = [string]$failed.Code; error = $why }
            throw [string]$failed.Detail
        }
        $waveClaims = @(& $readWaveClaims)

        if ($gate -ne 'Reserved') {
            # RESERVE-COVER-2: a machine still without a record refuses the
            # start, named with its size - GATE-WORDS-1's code and two
            # sentences, as the Reserved gate says it. Checking the quota of
            # the wave in the wave editor is what writes it.
            $stillNone = @(Get-VmfReservedCoverageGaps -Gate $gate -Claims $waveClaims -Entries $gateEntries -FinishedVmIds $finished -ProductGroupIds $productGroupIds |
                Where-Object Kind -eq 'noRecord')
            if ($stillNone.Count -gt 0) {
                $refusal = Get-VmfReservedCoverRefusal -Gate $gate -Wave $Wave -Gaps $stillNone
                # LOG-SAYS-WHY-1: REFUSED, not failed - nothing broke.
                Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome refused -Detail ([string]$refusal.Detail) `
                    -Data @{ wave = $Wave; code = [string]$refusal.Code }
                throw [string]$refusal.Detail
            }
        }
        else {
            # AVSET-RESERVE-1 and RESERVE-COVER-1: the PLAN's machines decide.
            # Each one not yet done needs a record of its own cell; one with
            # none is named, with its size.
            $openEntries = @($gateEntries | Where-Object { [string]$_.vmId -notin $finished })
            $reservableMachines = Get-VmfReservableEntryCount -Entries $openEntries -ProductGroupIds $productGroupIds
            $refusal = Get-VmfReservedCapacityRefusal -Claims $waveClaims -Wave $Wave -ReservableMachines $reservableMachines -ProductGroupIds $productGroupIds `
                -Entries $gateEntries -FinishedVmIds $finished -AsRecord
            if ($refusal) {
                # LOG-SAYS-WHY-1: REFUSED, not failed. Nothing broke - this
                # wave asked for a capacity guarantee it does not hold, and the
                # gate said so before anything moved. Recorded as a failure it
                # sat in the log in red beside real breakages.
                # GATE-WORDS-1: a refusal for machines carries its code (and the
                # wave) in the event, so nothing has to read the words.
                $said = if ($refusal -is [System.Collections.IDictionary]) { [string]$refusal.Detail } else { [string]$refusal }
                # STEP-LOG-5: one write, so the line has one handler.
                $line = @{ RunPath = $RunPath; Step = 'capacity'; Outcome = 'refused'; Detail = $said }
                if ($refusal -is [System.Collections.IDictionary]) { $line.Data = @{ wave = $Wave; code = [string]$refusal.Code } }
                Write-VmfStepLine @line
                throw $said
            }
            # AVSET-RESERVE-1: machines in an availability set move on general
            # capacity. Said once the whole gate has passed, below.
            $generalNote = Get-VmfReservedGeneralNote -Claims @(Select-VmfClaimsOfOpenMachines -Claims $waveClaims -Entries $openEntries) -Wave $Wave -ReservableMachines $reservableMachines
        }
        # RESERVE-RECHECK-1: a machine judged on its quota check alone (every
        # machine of a BestEffort wave, or one in an availability set) whose
        # record the check above wrote BLOCKED - quota used since the last
        # check, or a size Azure no longer offers there. GATE-WORDS-1's code
        # and two sentences, which say quota; the gate's own detail below
        # said "Capacity gate ... [BLOCKED]".
        $quotaGaps = @(Get-VmfReservedCoverageGaps -Gate $gate -Claims $waveClaims -Entries $gateEntries -FinishedVmIds $finished -ProductGroupIds $productGroupIds |
            Where-Object Kind -eq 'quota')
        $quotaRefusal = if ($quotaGaps.Count -gt 0) { Get-VmfReservedCoverRefusal -Gate $gate -Wave $Wave -Gaps $quotaGaps }
        if ($quotaRefusal) {
            Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome refused -Detail ([string]$quotaRefusal.Detail) `
                -Data @{ wave = $Wave; code = [string]$quotaRefusal.Code }
            throw [string]$quotaRefusal.Detail
        }
        $capacity = Test-VmfQuotaAndReservation -OutPath $RunPath -Wave $Wave -Gate $gate -Entries $gateEntries
        if (-not $capacity.Pass) {
            throw "Capacity gate ($gate) failed for wave '$Wave': $($capacity.Detail)."
        }
        # Once per wave: with several containers, each one runs this gate.
        if ($generalNote -and ($Container -notmatch '^(\d+)/' -or $Matches[1] -eq '1')) {
            Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome info -Detail $generalNote -Data @{ wave = $Wave }
        }
    }

    $workerScript = Join-Path $script:VmfModuleRoot 'Workers' 'worker.ps1'
    $workerScript = [System.IO.Path]::GetFullPath($workerScript)
    $workerCount = [math]::Min($ThrottleLimit, $entries.Count)
    # SCALE-2: the record carries the wave's total, this container's place,
    # and worker ids unique across containers (a lease names its worker).
    $containerCount = 1
    $containerIndex = 1
    if ($Container -match '^(\d+)/(\d+)$') { $containerIndex = [int]$Matches[1]; $containerCount = [int]$Matches[2] }
    $totalWorkers = if ($ThrottleTotal -gt 0) { $ThrottleTotal } else { $workerCount }
    $workerPrefix = if ($containerCount -gt 1) { "worker-c$containerIndex-" } else { 'worker-' }
    $containerTag = if ($containerCount -gt 1) { "Container $containerIndex/$containerCount" } else { '' }

    Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome start -Data @{ wave = $Wave } `
        -Detail ("wave=$Wave entries=$($entries.Count) workers=$workerCount" + $(if ($containerCount -gt 1) { " container=$containerIndex/$containerCount total=$totalWorkers" } else { '' }))
    # SCHEDULE-PASS-DUE-1: the wave has started, and it can stop part way, so
    # the five-minute pass checks this run, held 15 minutes until the workers
    # take their machines. Never throws.
    Add-VmfRunScheduleDue -RunPath $RunPath -Reason 'engine' -EngineStart | Out-Null

    # EVAL-M3: somewhere for a worker's last words to go. Without this, a worker
    # that died before its first lease left no trace anywhere.
    $workerLogDir = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-workers-$runId"
    if (-not (Test-Path $workerLogDir)) { New-Item -ItemType Directory -Path $workerLogDir -Force | Out-Null }

    $workers = for ($i = 1; $i -le $workerCount; $i++) {
        # -WindowStyle is Windows-only; the S3-3 container runs this on Linux.
        $spawn = @{
            FilePath     = 'pwsh'
            PassThru     = $true
            ArgumentList = @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $workerScript,
                '-RunPath', $RunPath, '-PlanPath', $PlanPath, '-Wave', $Wave,
                '-RunId', $runId, '-WorkerId', "$workerPrefix$i", '-WaveVersion', $checkedWaveVersion
            )
        }
        if ($IsWindows) { $spawn.WindowStyle = 'Hidden' }
        # EVAL-M3: workers were spawned with no output capture and no exit-code
        # check, so a systematic failure - a module import error in the image, a
        # bad plan path, a plan-data defect of the kind this orchestrator has
        # already been bitten by - produced "wave ok PLANNED=12" and a job
        # reported Succeeded, with the machines rendered as "Queued - waiting
        # for its turn" and nothing anywhere saying no worker ever leased one.
        $spawn.RedirectStandardOutput = Join-Path $workerLogDir "worker-$i.out.log"
        $spawn.RedirectStandardError  = Join-Path $workerLogDir "worker-$i.err.log"
        Start-Process @spawn
    }

    # SCALE-UX-1: what the workers weigh, where they run. The sizing table's
    # per-worker budget rested on a local idle measurement; this writes the
    # real number into the run - every pass into the peak, a reading into the
    # activity log about once a minute, and the peak at the end.
    $memPeak = $null
    $memPass = 0

    # Monitor loop: watchdog + breaker + status until the wave settles.
    # STEP-LOG-5: every line here goes through Write-VmfStepLine. A line that
    # cannot be written stopped this loop while the workers still ran, so the
    # wave's status stopped changing and the claims were not given back.
    while ($true) {
        Start-Sleep -Seconds 10

        $memSample = Get-VmfWorkerMemorySample -Workers $workers
        $memPeak = Update-VmfMemoryPeak -Peak $memPeak -Sample $memSample
        if ((($memPass++) % 6) -eq 0 -and $memSample.alive -gt 0) {
            Write-VmfStepLine -RunPath $RunPath -Step 'engine:memory' -Outcome info `
                -Detail ($(if ($containerTag) { "$containerTag - " } else { '' }) + ("Workers: {0} alive, {1} MB each on average, {2} MB the largest{3}." -f $memSample.alive, $memSample.avgMB, $memSample.maxMB,
                    $(if ($null -ne $memSample.containerMB) { ", container $($memSample.containerMB) MB" } else { '' }))) `
                -Data @{ alive = $memSample.alive; minMB = $memSample.minMB; avgMB = $memSample.avgMB; maxMB = $memSample.maxMB
                         containerMB = $memSample.containerMB; cgroup = $memSample.cgroup }
        }

        # Watchdog: reap leases whose heartbeat expired (dead workers)
        foreach ($expired in @(Get-VmfExpiredLeases -RunPath $RunPath -TimeoutSeconds $LeaseTimeoutSeconds)) {
            # LEASE-HEARTBEAT-RACE-1: removed only as judged. A holder that
            # renewed since the list keeps its lease, and nothing is said.
            if (-not (Remove-VmfExpiredLease -RunPath $RunPath -VmId $expired.vmId -TimeoutSeconds $LeaseTimeoutSeconds)) { continue }
            # RESTORE-ONE-AT-A-TIME-1: a restore's hold is not resumed.
            Write-VmfStepLine -RunPath $RunPath -Step 'watchdog' -Outcome warn -VmId $expired.vmId `
                -Detail (Get-VmfReapedLeaseWords -Lease $expired)
        }

        # Breaker: computed from state docs; halting = stop granting leases
        if (-not (Test-VmfWaveHalted -RunPath $RunPath)) {
            # SCALE-1: capacity exhaustion first, because it is
            # the failure the generic breaker is worst at. The breaker counts
            # failures of any kind on thresholds tuned for INDEPENDENT ones; a
            # region out of a size fails every remaining machine of that size
            # for the same reason, and each one pays a deallocate, a convert
            # attempt and a rollback to discover it. Two in a cell is enough.
            $capacity = Test-VmfCapacityExhausted -RunPath $RunPath -Plan $plan -Wave $Wave
            if ($capacity.Exhausted) {
                Set-VmfWaveHalt -RunPath $RunPath -Reason $capacity.Detail
                Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome refused -Detail $capacity.Detail
                foreach ($e in @($capacity.Evidence)) {
                    Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome info -Detail "Azure said: $e"
                }
            }
            else {
                $breaker = Test-VmfCircuitBreaker -RunPath $RunPath -Plan $plan -Wave $Wave `
                    -ConsecutiveLimit $ConsecutiveFailureLimit -RateLimit $FailureRateLimit
                if ($breaker.Tripped) {
                    Set-VmfWaveHalt -RunPath $RunPath -Reason "circuit breaker: $($breaker.Detail)"
                }
            }
        }

        $status = Write-VmfRunStatus -RunPath $RunPath -Plan $plan -Wave $Wave -RunId $runId -ThrottleLimit $totalWorkers -Containers $containerCount -LeaseTimeoutSeconds $LeaseTimeoutSeconds -PlanPath $PlanPath
        $countsText = (@($status.stateCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')
        Write-Host ("[wave $Wave] $countsText" + $(if ($status.breaker.halted) { '  ** HALTED **' }))

        $pending = Test-VmfWavePending -RunPath $RunPath -Plan $plan -Wave $Wave
        $aliveWorkers = @($workers | Where-Object { -not $_.HasExited })
        if (-not $pending) { break }
        if ($aliveWorkers.Count -eq 0) {
            # SCALE-2: my workers are done but the wave is not - if ANOTHER
            # container's workers still hold machines, this one leaves
            # quietly. The tally belongs to whoever finishes last; the stall
            # watchdog covers the case where nobody does.
            if ($containerCount -gt 1) {
                $myIds = @(for ($k = 1; $k -le $workerCount; $k++) { "$workerPrefix$k" })
                $others = Test-VmfOtherContainersWorking -RunPath $RunPath -MyWorkerIds $myIds -TimeoutSeconds $LeaseTimeoutSeconds
                if ($others.Working) {
                    Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome info `
                        -Detail "$containerTag has finished its share of wave $Wave. The other engine containers still work on $($others.Machines.Count) $(if ($others.Machines.Count -eq 1) { 'machine' } else { 'machines' })."
                    return [pscustomobject]@{
                        Wave        = $Wave
                        StateCounts = [pscustomobject]$status.stateCounts
                        Halted      = [bool]$status.breaker.halted
                        StatusPath  = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'run-status.json'
                        Container   = "$containerIndex/$containerCount"
                        FinishedShare = $true
                    }
                }
            }
            # Workers gone but work pending: halted, contended-out, or crashed.
            # EVAL-M3: which of those it is matters enormously, and this used to
            # be a bare break followed by an unconditional "wave ok".
            $failed = @($workers | Where-Object { $_.ExitCode -ne 0 })
            if (-not (Test-VmfWaveHalted -RunPath $RunPath) -and $failed.Count -eq $workers.Count -and $workers.Count -gt 0) {
                $lastWords = foreach ($w in $failed | Select-Object -First 3) {
                    $errFile = Join-Path $workerLogDir "worker-$([array]::IndexOf(@($workers), $w) + 1).err.log"
                    if (Test-Path $errFile) {
                        $tail = (Get-Content $errFile -Tail 3 -ErrorAction SilentlyContinue) -join ' '
                        if ($tail) { $tail.Substring(0, [Math]::Min(300, $tail.Length)) }
                    }
                }
                $why = if ($lastWords) { ($lastWords -join ' | ') } else { 'they left no output' }
                Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome fail -Data @{ wave = $Wave } `
                    -Detail ("Every worker stopped without migrating anything, so this wave did nothing. " +
                             "Exit codes: $(@($failed | ForEach-Object { $_.ExitCode }) -join ', '). What they said: $why")
                # APPROVE-GROUP-1: the wave ends here too, and the list must not
                # keep saying it is running. Never throws.
                Update-VmfRunSummary -RunPath $RunPath -PlanPath $PlanPath -Reason 'waveEnded' | Out-Null
                throw ("Wave '$Wave' migrated nothing: all $($workers.Count) workers exited without doing any work. " +
                       "This is a failure of the run itself, not of a machine. What the workers said: $why")
            }
            break
        }
    }

    # RUN-CLAIM-1: give back the machines this run is finished with. A machine
    # that is MIGRATED or SKIPPED is done; one that FAILED or is waiting for a
    # person stays claimed, because this run is still the one recovering it -
    # Skip this machine and Stop the run release those (FREE-MACHINE-GONE-1).
    # CLAIM-KEPT-AFTER-WAVE-1: the worker already gave each one back where it
    # settled; this is the second pass, for a machine whose worker stopped
    # between its last checkpoint and that release. One rule for both.
    foreach ($entry in $entries) {
        Remove-VmfSettledVmClaim -RunPath $RunPath -VmId $entry.vmId | Out-Null
    }

    # SCALE-UX-1: the peak, with the worker count it was seen at - the number
    # the sizing table needs, written where a support bundle will carry it.
    if ($memPeak -and $memPeak.samples -gt 0 -and $memPeak.workerMB -gt 0) {
        Write-VmfStepLine -RunPath $RunPath -Step 'engine:memory' -Outcome info `
            -Detail ($(if ($containerTag) { "$containerTag - " } else { '' }) + ("Peak memory: {0} MB for one worker, seen with {1} workers alive{2}." -f $memPeak.workerMB, $memPeak.workersAtPeak,
                $(if ($memPeak.containerMB) { ", $($memPeak.containerMB) MB for the container" } else { '' }))) `
            -Data @{ peakWorkerMB = $memPeak.workerMB; workersAtPeak = $memPeak.workersAtPeak; peakContainerMB = $memPeak.containerMB; samples = $memPeak.samples }
    }

    # Final tally. APPROVE-GROUP-1: and the summary of the whole migration,
    # built from the store, so the list says what the next wave waits for.
    $final = Write-VmfRunStatus -RunPath $RunPath -Plan $plan -Wave $Wave -RunId $runId -ThrottleLimit $totalWorkers -Containers $containerCount -LeaseTimeoutSeconds $LeaseTimeoutSeconds -PlanPath $PlanPath -WaveEnded
    Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome ok -Data @{ wave = $Wave } -Detail (
        (@($final.stateCounts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' '))

    [pscustomobject]@{
        Wave        = $Wave
        StateCounts = [pscustomobject]$final.stateCounts
        Halted      = [bool]$final.breaker.halted
        StatusPath  = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'run-status.json'
    }
}
