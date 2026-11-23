<#
.SYNOPSIS
    S3-3 engine entrypoint. Operation + parameters arrive as environment
    variables (Container Apps Job env overrides at start time):
      VMF_OPERATION      assess | plan | wave | restore | finish |
                         reserve | release | quota | quotacheck | retention |
                         advise | discard | deleteearlier | deletemade |
                         checkvolumes  (required)
      VMF_RUN_ID         run id -> store prefix      (required)
      VMF_STORE_ACCOUNT / VMF_STORE_CONTAINER        (from job definition)
      VMF_SCOPE_RG       assess: resource group allowlist, comma-separated
      VMF_SCOPE_SUBS     assess: comma-separated subscription ids (SCOPE-1)
      VMF_SCOPE_MG       assess: management group id (SCOPE-1)
      VMF_CAPACITY_GATE  plan: BestEffort | Reserved for every ring (CAP-3);
                         unset = ring defaults
      VMF_WAVE_STRATEGY  plan: tags | resourceGroup | singleWave | none (WAVE-1)
      VMF_APP_TAG        plan: which tag names the application (WAVE-1)
      (removed) VMF_RING_TAG       plan: which tag names the risk level (WAVE-1)
      VMF_MIGRATION_ID   plan: the migration to create from the assessment
                         named by VMF_RUN_ID (ASSESS-PAGE-1)
      VMF_WAVE           wave: wave name
      VMF_WAVE_VERSION   wave: the wave version the timer judged; the wave
                         does not start if the plan's wave differs
      VMF_SCHEDULE_START wave: the start id of a scheduled start; the wave
                         removes its schedule, or puts it back to pending
                         when the wave differs (SCHEDULE-WAVE-VERSION-1)
      VMF_VM_ID          restore: the machine to put back (RESTORE-1)
                         finish: the machine a refused data-disk swap left
                         stopped (SWAP-REFUSED-AFTER-STOP-1)
                         deleteearlier: the machine whose restore kept its
                         earlier managed disks (RESTORE-EARLIER-DELETE-1)
                         deletemade: the machine whose disks made from the
                         safety copies are deleted (MADE-DISK-DELETE-1)
                         checkvolumes: the machine whose record owes a check
                         of its volumes (VOLUMES-RESTORE-MIGRATED-1)
      VMF_DISK_SET       deleteearlier: restore (default) | rollback - the original
                         disks a rollback swapped off (ROLLBACK-ORIGINALS-LEFT-1)
      VMF_DISK_NAMING    restore: new (default) | preserve
      VMF_ACCEPT_PRESERVE_RISK  restore: 'true' to allow the destructive
                         preserve path, which deletes the existing disk
      VMF_RESTORED_BY    restore/finish/discard/deleteearlier/deletemade/checkvolumes: the validated user who asked for it
      VMF_NOTE           restore/finish/discard: the recorded reason
      VMF_DISK_SOURCE    restore: prepared (default) | pristine (RESTORE-COPY-1).
                         pristine predates the guest preparation, so it
                         also returns the machine to its original size
                         and disk controller
      VMF_RESUME_ID      restore/finish: the operation id of a
                         restore or a finish whose job stopped part
                         way. The service's timer sets it; the engine starts
                         THAT job again from its last step, with what its
                         record says the person asked for (RESTORE-END-JOB-1,
                         FINISH-END-JOB-1)
      VMF_THROTTLE       wave: worker count          (default 15)
      VMF_QUOTA_HEADROOM quota: extra vCPUs to ask for beyond the plan
      VMF_QUOTA_WHATIF   quota: 'true' to preview without filing anything
      AZURE_CLIENT_ID    user-assigned MI client id  (from job definition)
    Exit code 0 = operation completed (wave: settled - inspect the run store
    for per-VM outcomes; parked/held VMs are settled states, not failures).
#>
$ErrorActionPreference = 'Stop'
# SAFETY-3 drill, 2026-09-05: the scheduled retention run stopped at "Are you
# sure you want to perform this action?" - Remove-VmfExpiredSafetyCopies is
# ConfirmImpact High, this container has nobody to answer, and the call below
# never said -Confirm:$false. So the daily cleanup REACH-1 promised had never
# once finished in the container. Hard rule 7: no prompt anywhere in the
# execution path. Both belts: nothing here may ask, and the call says so too.
$ConfirmPreference = 'None'

# SCAN-FAIL-SHOWN-1: a console line before anything that can fail. A scan's
# execution ended Failed on the lab installation (2026-11-09) with NO console
# line: the first line came after the settings check, the module load and the
# sign-in, so a failure in any of them said nothing about where. Now the job
# says it started, and a failure before the operation names its step. The run
# store cannot be written before the module loads and the sign-in works, so
# this is the console log only; the service's five-minute pass writes the
# run's line for a scan that ended with no answer (Invoke-VmfFacadeEndSilentScan).
Write-Host "engine: starting operation=$($env:VMF_OPERATION) run=$($env:VMF_PROJECT)$(if ($env:VMF_PROJECT) { '/' })$($env:VMF_RUN_ID)"
$startStep = 'read the required settings'
try {
    foreach ($required in 'VMF_OPERATION', 'VMF_RUN_ID', 'VMF_STORE_ACCOUNT', 'VMF_STORE_CONTAINER') {
        if (-not (Get-Item "Env:$required" -ErrorAction SilentlyContinue).Value) {
            throw "Engine misconfigured: $required is not set."
        }
    }

    $startStep = 'load the module'
    Import-Module /app/src/VmMigrationFactory/VmMigrationFactory.psd1 -Force
    # FACADE-PASS-SHARE-1: Azure PowerShell's data collection off for this process
    # before the sign-in. Each Az call sends usage data from a thread-pool thread
    # that waits for the send, and the store calls then wait for a free thread.
    # Az.Accounts is loaded first: the setting changes nothing until it is.
    # Process scope, nothing written to disk; a refused setting never stops the
    # engine.
    $startStep = 'load Az.Accounts'
    Import-Module Az.Accounts
    try { $null = & (Get-Module VmMigrationFactory) { Set-VmfAzDataCollectionOff } } catch { Write-Host "engine: Azure PowerShell data collection not turned off: $($_.Exception.Message)" }
    $startStep = 'sign in with the managed identity'
    Connect-AzAccount -Identity -AccountId $env:AZURE_CLIENT_ID | Out-Null
}
catch {
    Write-Host "engine: operation=$($env:VMF_OPERATION) FAILED before it started, at the step '$startStep': $($_.Exception.Message)"
    throw
}

# PROJECT-1: a run may live INSIDE a project, and the project is a path
# segment. It arrives as its own variable rather than baked into VMF_RUN_ID
# because the facade route cannot carry a slash - IIS rejects an encoded one,
# which is a 404 with no explanation. Measured, 2026-09-01.
$runPrefix = if ($env:VMF_PROJECT) { "$($env:VMF_PROJECT)/$($env:VMF_RUN_ID)" } else { $env:VMF_RUN_ID }
$runPath = "azblob://$($env:VMF_STORE_ACCOUNT)/$($env:VMF_STORE_CONTAINER)/$runPrefix"
Write-Host "engine: operation=$($env:VMF_OPERATION) run=$runPath"

# STORE-RESERVED-NAMES-1: the engine refuses an address that is not a run even
# when the service forgets to: a folder the product keeps (vmf-records,
# vmf-claims, logs) or a project's root. Asked before the first write into the
# run (the version line below), so a refused start leaves nothing there.
try {
    & (Get-Module VmMigrationFactory) { param($rp)
        Assert-VmfRunNames -RunPath $rp
        Assert-VmfNotProject -RunPath $rp
    } $runPath
}
catch {
    Write-Host "engine: operation=$($env:VMF_OPERATION) REFUSED before it started: $($_.Exception.Message)"
    throw
}

# VERSION-1: which build is doing this. Into the container log AND the run's
# activity log, BEFORE the operation - so a refused operation has a version in
# its log too, and a support bundle can say which code ran the migration it
# describes. Through the module, because Write-VmfEvent is private (the
# refusal wrapper below had exactly that defect and never worked once). A
# failure to record the version must not become a failed operation.
$engineVersion = Get-VmfVersion
Write-Host "engine: version=$($engineVersion.version)$(if ($engineVersion.warning) { ' (' + $engineVersion.warning + ')' })"

# DISCARD-ENGINE-1 S4: a discard whose run is already gone (a second start, or
# a failure after the records went) must write NOTHING under its prefix - one
# log line there is a ghost run in every listing. Asked before each write.
function Find-VmfEngineRun {
    if ($env:VMF_OPERATION -ne 'discard') { return $true }
    try { [bool](& (Get-Module VmMigrationFactory) { param($rp) Read-VmfStoreJson -RunPath $rp -RelPath 'run.json' -Depth 4 } $runPath) }
    catch { $false }
}

# RESTORE-END-LOST-1: one id for this operation. The restore's start line and
# this script's fail line both carry it, so the Migrations page ends the
# restore that failed and not another restore of the same machine.
$engineRunId = [guid]::NewGuid().ToString()
# RESTORE-END-JOB-1: a resume is the SAME operation - its id is on the first
# job's start line, in its lease holder and in its checkpoint, so the page ends
# that restore on this job's fail line, and the lease is taken over, not fought.
# FINISH-END-JOB-1: and a finish.
$resumeId = if ($env:VMF_OPERATION -in @('restore', 'finish') -and $env:VMF_RESUME_ID) { [string]$env:VMF_RESUME_ID } else { '' }
if ($resumeId) { $engineRunId = $resumeId }

$runThere = Find-VmfEngineRun
if (-not $runThere) { Write-Host 'engine: the run is already gone; nothing is written under it' }
try {
    & (Get-Module VmMigrationFactory) { param($rp, $step, $v, $op, $there) if (-not $there) { return }
        Write-VmfEvent -RunPath $rp -Step $step -Outcome info -Detail ("Engine version {0} started the {1} operation." -f $v.version, $op) -Data @{ engineVersion = $v.version; engineCommit = $v.commit; engineBuiltUtc = $v.builtUtc }
    } $runPath "engine:$($env:VMF_OPERATION)" $engineVersion $env:VMF_OPERATION $runThere
}
catch {
    Write-Host "engine: the version could not be written to the run store: $($_.Exception.Message)"
}

# WHY THIS WRAPPER EXISTS. The engine used to refuse a wave - a gate not
# satisfied, a quota check missing - by throwing, which crashed the
# container. The reason went into the container log and NOWHERE ELSE, so every
# screen showed a run that had started and then simply stopped: a user
# pressed start, nothing happened, and nothing anywhere said why.
#
# A refusal is an ANSWER, and it belongs in the run store with everything else
# the run knows about itself. The exit code still fails, so the job is still
# failed; what changes is that the run can now say what happened.
try {
switch ($env:VMF_OPERATION) {
    'assess' {
        # SCOPE-1: explicit subscriptions and/or a management group win; the
        # job identity's home subscription is only the fallback.
        $scope = @{}
        if ($env:VMF_SCOPE_SUBS) { $scope.Subscriptions = @($env:VMF_SCOPE_SUBS -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        if ($env:VMF_SCOPE_MG) { $scope.ManagementGroup = $env:VMF_SCOPE_MG }
        if (-not $scope.Subscriptions -and -not $scope.ManagementGroup) {
            $scope.Subscriptions = @((Get-AzContext).Subscription.Id)
        }
        # SCOPE-RG-LIST-1: a LIST, the way VMF_SCOPE_SUBS already is. This
        # wrapped one value in an array, so the allowlist its own documentation
        # names could only ever hold one entry - and an estate spread across
        # several resource groups could be scanned only by taking the whole
        # subscription, which in a work tenant means reading machines nobody
        # asked about.
        if ($env:VMF_SCOPE_RG) {
            $scope.ResourceGroups = @($env:VMF_SCOPE_RG -split '[,;]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        }
        $r = Invoke-VmfAssessment -Scope $scope -OutPath $runPath -RunId $env:VMF_RUN_ID
        Write-Host "assessed $($r.Total) machines -> $($r.AssessmentPath)"
    }
    'advise' {
        # ADVISOR-1: the target options for each machine, written beside the
        # reviewed assessment. The service starts this when the review is
        # approved; it runs here because only the engine can read Azure's
        # size catalog.
        $r = New-VmfTargetAdvice -AssessmentPath "$runPath/assessment.json"
        Write-Host "target options for $($r.Machines) machines, $($r.WithTarget) with a supported target$(if (@($r.RegionsNotRead).Count) { '; not read: ' + (@($r.RegionsNotRead) -join ', ') })"
    }
    'plan' {
        # ASSESS-PAGE-1: planning reads an ASSESSMENT and writes a MIGRATION -
        # two different objects. They used to be one, which is why scanning an
        # estate left something sitting in the run list looking like an
        # abandoned migration. VMF_RUN_ID names the assessment;
        # VMF_MIGRATION_ID names the migration the facade created for it.
        $migrationId = if ($env:VMF_MIGRATION_ID) { $env:VMF_MIGRATION_ID } else { "$($env:VMF_RUN_ID)-migration" }
        $migrationPrefix = if ($env:VMF_PROJECT) { "$($env:VMF_PROJECT)/$migrationId" } else { $migrationId }
        $migrationPath = "azblob://$($env:VMF_STORE_ACCOUNT)/$($env:VMF_STORE_CONTAINER)/$migrationPrefix"
        Write-Host "engine: planning from assessment '$($env:VMF_RUN_ID)' into migration '$migrationId'"
        $planParams = @{ AssessmentPath = "$runPath/assessment.json"; OutPath = $migrationPath }
        # CAP-3: the operator's plan-time capacity choice, when one was made.
        # V7-UX-1: the generation the machines move to. New-VmfPlan has taken
        # this since WAVE-2 and NOTHING EVER PASSED IT, so every migration run
        # from the app planned v6 while the run page displayed "v6 - the current
        # generation" as though somebody had chosen it. A setting you can see
        # and cannot set is worse than one that is not there.
        if ($env:VMF_TARGET_GENERATION) { $planParams.TargetGeneration = $env:VMF_TARGET_GENERATION }
        # ADVISOR-1: the app plans from the target chosen for each machine, and
        # this is where that is enforced - here, not in a page, because the API
        # reaches this too. Only a request that names one series goes without.
        else { $planParams.RequireTargets = $true }
        # MACHINE-PICK-1: and only from the machines chosen for it - a request
        # that names one series too, so no path from the app plans a machine
        # nobody chose. Targets saved before the list existed stand for it.
        $planParams.RequireMachineChoice = $true
        if ($env:VMF_CAPACITY_GATE) { $planParams.CapacityGate = $env:VMF_CAPACITY_GATE }
        # WAVE-1: how machines are grouped into waves (tags are not a given).
        if ($env:VMF_WAVE_STRATEGY) { $planParams.WaveStrategy = $env:VMF_WAVE_STRATEGY }
        if ($env:VMF_APP_TAG) { $planParams.AppGroupTag = $env:VMF_APP_TAG }
        $r = New-VmfPlan @planParams
        Write-Host "planned $($r.Total) entries across waves: $(@($r.Waves | ForEach-Object { $_.wave }) -join ', ')"
        # The wave capacity gate requires claims. Hosted 'plan' owns the whole
        # plan-time stage - found by the S3-7 smoke: CLI rehearsals ran the
        # forecast as a separate step the facade could not trigger.
        $claims = @(Test-VmfQuota -PlanPath "$migrationPath/plan.json" -OutPath $migrationPath)
        Write-Host "capacity: $($claims.Count) claims recorded"
    }
    'wave' {
        if (-not $env:VMF_WAVE) { throw 'Engine misconfigured: VMF_WAVE is required for the wave operation.' }
        # MACHINES-AT-ONCE-RANGE-1: the service always names this container's share; with none, Standard (15, one container).
        $throttle = if ($env:VMF_THROTTLE) { [int]$env:VMF_THROTTLE } else { 15 }
        # SCALE-2: this container's share, the wave's total, and which one of
        # how many this is - so the record says the total and the log says
        # which container wrote each line.
        $waveParams = @{ PlanPath = "$runPath/plan.json"; Wave = $env:VMF_WAVE; RunPath = $runPath; ThrottleLimit = $throttle }
        if ($env:VMF_THROTTLE_TOTAL) { $waveParams.ThrottleTotal = [int]$env:VMF_THROTTLE_TOTAL }
        if ($env:VMF_CONTAINER) { $waveParams.Container = [string]$env:VMF_CONTAINER }
        # WAVE-APPROVE-1 (review 4): the wave version the timer judged. The
        # wave refuses to start if its own read of the wave differs.
        if ($env:VMF_WAVE_VERSION) { $waveParams.WaveVersion = [string]$env:VMF_WAVE_VERSION }
        # SCHEDULE-WAVE-VERSION-1: the start id of a scheduled start. The wave
        # removes its schedule when it starts, and puts it back to pending
        # when its read of the wave differs from the version the pass judged.
        if ($env:VMF_SCHEDULE_START) { $waveParams.ScheduleStartId = [string]$env:VMF_SCHEDULE_START }
        $r = Start-VmfWave @waveParams
        Write-Host "wave $($env:VMF_WAVE) settled: $($r.StateCounts | ConvertTo-Json -Compress) halted=$($r.Halted)"

        # REACH-1 close-out, ruled 2026-08-30: release is AUTOMATIC here,
        # with a button for the cases this deliberately will not cover. An
        # unused reservation bills until somebody deletes it, and "somebody
        # remembers" is not a cost control - it is how the lab ended up with
        # nine orphaned disks earlier this week.
        #
        # But only when the wave is genuinely FINISHED. A machine still parked
        # on a decision, or rolled back and awaiting a retry, still needs the
        # capacity guarantee that was bought for it; giving it back would hand
        # scarce capacity to somebody else and leave the retry to chance. So
        # anything other than "every machine reached MIGRATED or SKIPPED" holds
        # the reservations and SAYS SO, because held capacity that nobody
        # mentions is silent money.
        # REPORT-AUTO-1 review 1 (SCALE-2): a container that finished only its
        # share, while another container still runs the wave, closes nothing.
        # The last container closes the wave out and writes the record and the
        # report; one written here could land after that one, half finished.
        $shareOnly = & (Get-Module VmMigrationFactory) { param($x) Test-VmfWaveShareOnly -Result $x } $r
        if ($shareOnly) {
            Write-Host "wave $($env:VMF_WAVE): this container finished its share; another container closes the wave"
        }
        else {
            Invoke-VmfWaveCloseOut -RunPath $runPath -Wave $env:VMF_WAVE -Result $r
            # ATTEST-1 and REPORT-AUTO-1: every time a wave ends, the migration's
            # record is kept again for another 90 days, and the report is written
            # from it - so both exist without anybody pressing anything. Neither
            # may fail the wave: the machines moved. The function says any failure
            # in the run history and never throws; this try is for a defect in the
            # call itself.
            try {
                & (Get-Module VmMigrationFactory) { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'waveClosed' | Out-Null } $runPath
            }
            catch {
                Write-Host "engine: the record and the report could not be written after this wave: $($_.Exception.Message)"
            }
        }
    }
    'restore' {
        # RESTORE-1: put a machine's disks back to a safety copy - the OS disk and,
        # since RESTORE-ALL-1, every data disk. Long
        # enough to need the job rather than an HTTP call, like every other
        # operation here.
        if (-not $env:VMF_VM_ID) { throw 'Engine misconfigured: VMF_VM_ID is required for the restore operation.' }
        $restoreParams = @{
            RunPath    = $runPath
            VmId       = $env:VMF_VM_ID
            RestoredBy = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            Note       = [string]$env:VMF_NOTE
            Confirm    = $false
            CorrelationId = $engineRunId
        }
        if ($env:VMF_DISK_NAMING) { $restoreParams.DiskNaming = $env:VMF_DISK_NAMING }
        if ($env:VMF_ACCEPT_PRESERVE_RISK -eq 'true') { $restoreParams.AcceptPreserveRisk = $true }
        # RESTORE-COPY-1: WHICH safety copy. Restore-VmfVm has always taken
        # either, and nothing between the app and here carried the choice - so
        # every restore from the dashboard used the default, the PREPARED copy,
        # which keeps the machine on the new hardware. An operator asking to put
        # a machine back the way it was could not get that from the app.
        if ($env:VMF_DISK_SOURCE) { $restoreParams.From = $env:VMF_DISK_SOURCE }
        # RESTORE-END-JOB-1: everything the person asked for comes from the
        # record of the restore it resumes.
        if ($resumeId) { $restoreParams.Resume = $true }
        # REPORT-AFTER-SWAP-LEFT-1: the version of the machine's record before
        # the restore, so a restore that throws writes the record and the
        # report only when it changed the record. One that cannot be read is
        # not known, and never stops the restore.
        $stateVersionBefore = ''
        try {
            $stateVersionBefore = [string](& (Get-Module VmMigrationFactory) { param($rp, $id) Get-VmfStateDocVersion -RunPath $rp -VmId $id } $runPath $env:VMF_VM_ID)
        }
        catch { $stateVersionBefore = '' }
        $restoreReturned = $false
        try {
            $r = Restore-VmfVm @restoreParams
            $restoreReturned = $true
        }
        finally {
            # RESTORED-HOLD-1: a restore that ends a stop changes what the list
            # on the Migrations page says the next wave waits for.
            # RUN-SUMMARY-SWAP-1: in a finally, because a restore whose data
            # disk swap Azure refused throws after it writes swapPending, and
            # the machine it leaves stopped waits for a person - the overview
            # and the list count it from this summary. Never throws.
            try {
                & (Get-Module VmMigrationFactory) { param($rp, $id) Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId $id } $runPath $env:VMF_VM_ID
            }
            catch {
                Write-Host "engine: the status of this migration could not be written after this restore: $($_.Exception.Message)"
            }
            # REPORT-AFTER-SWAP-LEFT-1: a restore whose data disk swap Azure
            # refused writes its record and swapPending, then throws - and the
            # write after it never ran, so the saved record and report said
            # migrated until the daily check. Here, only for a restore that
            # threw and wrote its record (Save-VmfRecordAndReportAfterRestore).
            # A failure is a line here; the restore's own error stands.
            if (-not $restoreReturned) {
                try {
                    & (Get-Module VmMigrationFactory) { param($rp, $id, $op, $before) Save-VmfRecordAndReportAfterRestore -RunPath $rp -VmId $id -OperationId $op -VersionBefore $before | Out-Null } $runPath $env:VMF_VM_ID $engineRunId $stateVersionBefore
                }
                catch {
                    Write-Host "engine: the record and the report could not be written after this restore: $($_.Exception.Message)"
                }
            }
        }
        Write-Host "restored $($r.VmId) from $($r.RestoredFromSnapshotId); disk=$($r.NewDiskName) idChanged=$($r.DiskIdChanged) dataDisks=$(@($r.DataDisks | ForEach-Object { "$($_.lun):$($_.newDiskName)" }) -join ',') dataDisksKept=$(@($r.DataDisksKept).Count)"
        # REPORT-AUTO-1: a machine put back changes what the record and the
        # report say. Written after a restore that finished; neither may fail
        # the restore, which has already happened.
        try {
            & (Get-Module VmMigrationFactory) { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' | Out-Null } $runPath
        }
        catch {
            Write-Host "engine: the record and the report could not be written after this restore: $($_.Exception.Message)"
        }
    }
    # REBUILD-REMOVE-RECOVER-1: no operation rebuild. Rebuild this machine
    # (UX-STUCK-1) is gone with the rebuild around the same disks: no move
    # deletes a definition, so no machine needs one built again.
    'finish' {
        # SWAP-REFUSED-AFTER-STOP-1: Finish the rollback / Finish the restore.
        # A rollback or a restore whose data-disk swap Azure refused left the
        # machine stopped, with every disk it needs already made. This swaps
        # only the disks that are left, then starts the machine.
        if (-not $env:VMF_VM_ID) { throw 'Engine misconfigured: VMF_VM_ID is required for the finish operation.' }
        $finishParams = @{
            RunPath    = $runPath
            VmId       = $env:VMF_VM_ID
            FinishedBy = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            Note       = [string]$env:VMF_NOTE
            Confirm    = $false
            # RESTORE-ONE-AT-A-TIME-1: on the start line, and the name the job
            # holds the machine under.
            CorrelationId = $engineRunId
        }
        # FINISH-END-JOB-1: who asked for it and why come from the record of
        # the finish it resumes.
        if ($resumeId) { $finishParams.Resume = $true }
        $r = Complete-VmfDataDiskSwap @finishParams
        Write-Host "finished $($r.Kind) of $($r.VmId): $(@($r.Swapped | ForEach-Object { "$($_.lun):$($_.diskName)" }) -join ',') started=$($r.Started)"
        # REPORT-AUTO-1: the machine runs on every disk from the copy now, so
        # the record and the report change as they do after a restore.
        try {
            & (Get-Module VmMigrationFactory) { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' | Out-Null } $runPath
        }
        catch {
            Write-Host "engine: the record and the report could not be written after this finish: $($_.Exception.Message)"
        }
        # RESTORED-HOLD-1: as after a restore - a finish ends the stop a data
        # disk swap that was left kept. Never throws.
        try {
            & (Get-Module VmMigrationFactory) { param($rp, $id) Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId $id } $runPath $env:VMF_VM_ID
        }
        catch {
            Write-Host "engine: the status of this migration could not be written after this finish: $($_.Exception.Message)"
        }
    }
    'powerback' {
        # POWER-ONLY-CHANGED-1 (2026-11-06): return each machine whose
        # power state the product changed and did not return - one machine
        # (VMF_VM_ID), or every such machine of the run - to the power state it
        # was found in. Leave this machine out, Stop this migration and the
        # machine panel start it; the service has no right to change a machine.
        $powerParams = @{
            RunPath       = $runPath
            By            = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            Note          = [string]$env:VMF_NOTE
            CorrelationId = $engineRunId
            Confirm       = $false
        }
        if ($env:VMF_VM_ID) { $powerParams.VmId = $env:VMF_VM_ID }
        $r = @(Restore-VmfMachinePower @powerParams)
        Write-Host "powerback: $(@($r | ForEach-Object { "$(($_.VmId -split '/')[-1])=$(if ($_.Returned) { 'returned' } else { 'not returned' })" }) -join ', ')"
    }
    'deleteearlier' {
        # RESTORE-EARLIER-DELETE-1 (approved design, 2026-10-25): Delete
        # these disks on the machine's panel. It deletes only the earlier
        # managed disks the restore's own record names, by resource id, skips
        # a disk attached to any machine, and records each one it deleted, so
        # the panel's list empties. Nothing starts it but a person.
        if (-not $env:VMF_VM_ID) { throw 'Engine misconfigured: VMF_VM_ID is required for the deleteearlier operation.' }
        $deleteParams = @{
            RunPath       = $runPath
            VmId          = $env:VMF_VM_ID
            By            = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            CorrelationId = $engineRunId
            Confirm       = $false
        }
        # ROLLBACK-ORIGINALS-LEFT-1: the original disks a rollback swapped off,
        # with the same reads, refusals and record (Delete these disks under
        # Original disks, not in use).
        if ($env:VMF_DISK_SET) { $deleteParams.Set = $env:VMF_DISK_SET }
        $r = Remove-VmfRestoreEarlierDisks @deleteParams
        Write-Host "deleteearlier: $(($r.VmId -split '/')[-1]) deleted=$(@($r.Deleted) -join ',') skipped=$(@($r.Skipped | ForEach-Object { $_.name }) -join ',')"
    }
    'deletemade' {
        # MADE-DISK-DELETE-1 (2026-11-08): Delete these disks
        # now on the machine's panel. It deletes only the managed disks a
        # put-back made that the record says nothing uses
        # (Get-VmfDeletableMadeDisks), by resource id, keeps a disk attached to
        # any machine, and marks each one it deleted, so the panel's list
        # empties. Nothing starts it but a person.
        if (-not $env:VMF_VM_ID) { throw 'Engine misconfigured: VMF_VM_ID is required for the deletemade operation.' }
        $madeParams = @{
            RunPath       = $runPath
            VmId          = $env:VMF_VM_ID
            By            = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            CorrelationId = $engineRunId
            Confirm       = $false
        }
        $r = Remove-VmfMadeDisks @madeParams
        Write-Host "deletemade: $(($r.VmId -split '/')[-1]) deleted=$(@($r.Deleted) -join ',') skipped=$(@($r.Skipped | ForEach-Object { $_.name }) -join ',')"
    }
    'checkvolumes' {
        # VOLUMES-RESTORE-MIGRATED-1: Check the volumes on the machine's panel.
        # Restore this machine on a migrated machine can leave a volume not
        # mounted, and a migrated machine has no Try this machine again. This
        # runs the check of the volumes that a retry runs first, with no move:
        # only a check that finds every volume mounted again records the
        # machine restored. Nothing starts it but a person.
        if (-not $env:VMF_VM_ID) { throw 'Engine misconfigured: VMF_VM_ID is required for the checkvolumes operation.' }
        $checkParams = @{
            RunPath       = $runPath
            VmId          = $env:VMF_VM_ID
            By            = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            CorrelationId = $engineRunId
            Confirm       = $false
        }
        $r = Invoke-VmfVolumesCheck @checkParams
        Write-Host "checkvolumes: $(($r.VmId -split '/')[-1]) verdict=$($r.Verdict)"
        # The machine's record changed, so the record, the report and the
        # status of the migration are written again, as after a restore.
        try {
            & (Get-Module VmMigrationFactory) { param($rp) Save-VmfRecordAndReport -RunPath $rp -Reason 'putBack' | Out-Null } $runPath
        }
        catch {
            Write-Host "engine: the record and the report could not be written after this check: $($_.Exception.Message)"
        }
        try {
            & (Get-Module VmMigrationFactory) { param($rp, $id) Update-VmfRunSummaryAfterPutBack -RunPath $rp -VmId $id } $runPath $env:VMF_VM_ID
        }
        catch {
            Write-Host "engine: the status of this migration could not be written after this check: $($_.Exception.Message)"
        }
    }
    'reserve' {
        # REACH-1 / ODCR-GAP-1: reserving capacity used to be a PowerShell
        # command an operator ran by hand, while the wave editor offered
        # "Reserved and guaranteed" as a choice - so a customer could pick a
        # guarantee the product had no way to obtain. This is that control.
        #
        # It SPENDS: an ODCR bills at the VM rate from the moment it exists,
        # used or not. That is why it is an explicit action a person takes and
        # never something that happens because a wave was scheduled.
        if (-not $env:VMF_WAVE) { throw 'Engine misconfigured: VMF_WAVE is required for the reserve operation.' }
        $r = New-VmfWaveReservation -OutPath $runPath -Wave $env:VMF_WAVE
        if ($r.Refused) {
            Write-Host "reserve $($env:VMF_WAVE): refused - $($r.Refused)"
        }
        elseif ($r.NothingReservable) {
            Write-Host "reserve $($env:VMF_WAVE): nothing to reserve - every machine is in an availability set, and Azure does not allow a capacity reservation for such a machine"
        }
        elseif ($r.AllOrNothing) {
            Write-Host "reserve $($env:VMF_WAVE): NOT reserved - $($r.Blocked.Count) cell(s) could not be reserved and $(@($r.Unconfirmed).Count) not confirmed, so the $($r.Released.Count) that succeeded were released"
        }
        else {
            Write-Host "reserve $($env:VMF_WAVE): reserved $($r.Reserved.Count) cell(s)"
        }
    }
    'release' {
        # The other half. Close-out does this automatically for a finished
        # wave; this is the button, for a wave that will not run, one that
        # ended with machines still parked, or capacity reserved by mistake.
        if (-not $env:VMF_WAVE) { throw 'Engine misconfigured: VMF_WAVE is required for the release operation.' }
        # WAVE-EDIT-RESERVE-1: never under machines that may be using it. The
        # page hides the button then, but a page shows what it read when it
        # loaded - this is the guard that holds.
        $busy = & (Get-Module VmMigrationFactory) { param($rp, $w) Get-VmfWaveReleaseRefusal -RunPath $rp -Wave $w } $runPath $env:VMF_WAVE
        if ($busy) {
            & (Get-Module VmMigrationFactory) { param($rp, $d) Write-VmfEvent -RunPath $rp -Step 'odcr' -Outcome refused -Detail $d } $runPath `
                "The product did not release the on-demand capacity reservation for wave $($env:VMF_WAVE): machines of the wave are migrating ($busy), and they can use it. Release it when the wave has finished."
            throw "release refused: wave $($env:VMF_WAVE) is migrating ($busy)"
        }
        $r = Remove-VmfCapacityReservations -OutPath $runPath -Wave $env:VMF_WAVE
        Write-Host "release $($env:VMF_WAVE): released $(@($r.Released).Count) on-demand capacity reservation(s)"
        # RESERVING-STUCK-1: one Azure would not release now is still on the
        # wave and may bill. The run fails so the page does not say done.
        if (@($r.NotReleased).Count -gt 0) {
            throw "release $($env:VMF_WAVE): the product did not release $(@($r.NotReleased).Count) on-demand capacity reservation(s). The activity log says why."
        }
    }
    'quotacheck' {
        # QUOTA-BUTTON-1: the wave editor's "Check the quota" button. It called
        # a READ of the stored records, which saving the waves had just cleared,
        # so it answered "not enough" in a second without asking Azure anything.
        # This asks Azure: the SKU catalog and the quota usage for the wave's
        # sizes. It reserves nothing and spends nothing, and it never replaces a
        # record of a reservation.
        if (-not $env:VMF_WAVE) { throw 'Engine misconfigured: VMF_WAVE is required for the quotacheck operation.' }
        $r = Test-VmfQuota -PlanPath "$runPath/plan.json" -OutPath $runPath -Wave $env:VMF_WAVE
        Write-Host "quotacheck $($env:VMF_WAVE): $(@($r.Claims).Count) record(s), $(@($r.Blocked).Count) blocked"
    }
    'quota' {
        # REACH-1: asking Azure for more quota. Read-only unless it actually
        # files, which is why the what-if form is available from the app too -
        # an operator should be able to see what would be asked for before
        # anything is asked.
        $quotaParams = @{ OutPath = $runPath }
        if ($env:VMF_QUOTA_HEADROOM) { $quotaParams.HeadroomVcpus = [int]$env:VMF_QUOTA_HEADROOM }
        if ($env:VMF_QUOTA_WHATIF -eq 'true') { $quotaParams.WhatIfOnly = $true }
        # Request-VmfQuota returns ONE summary; counting it said "1" whatever
        # it did. And a request that could not be made is said.
        $r = Request-VmfQuota @quotaParams
        if ($env:VMF_QUOTA_WHATIF -eq 'true') { Write-Host "quota: $(@($r.All).Count) request(s) previewed" }
        else { Write-Host "quota: $(@($r.Submitted).Count) request(s) submitted, $(@($r.Failed).Count) failed - the activity log says why" }
    }
    'retention' {
        # REACH-1: the safety copies. The plan records how long they are kept
        # and NOTHING HAS EVER ENFORCED IT - no timer, no job, no button - so
        # every snapshot a migration took billed indefinitely. Runs on a timer
        # now, and can be run on demand.
        $retParams = @{
            RunPath   = $runPath
            PlanPath  = "$runPath/plan.json"
            DeletedBy = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'retention (scheduled)' })
            Confirm   = $false   # the decision was made when the wave's retention was accepted
        }
        if ($env:VMF_WAVE) { $retParams.Wave = $env:VMF_WAVE }
        $r = @(Remove-VmfExpiredSafetyCopies @retParams)
        Write-Host "retention: removed $($r.Count) expired safety copy/copies"
    }
    'discard' {
        # DISCARD-ENGINE-1 (GitHub issue 427): delete a migration WITH its
        # safety copies. The service checked the request and started this; it
        # has neither the module nor the right to delete a customer's copies.
        # Remove-VmfRun checks everything again, deletes and confirms every
        # copy, and removes the records only when every copy is gone. A copy
        # that is not throws, which the catch below writes into the run's log
        # - the run is still there to hold it.
        $discardParams = @{
            RunPath            = $runPath
            Reason             = $(if ($env:VMF_NOTE) { $env:VMF_NOTE } else { 'deleted from the dashboard' })
            RemovedBy          = $(if ($env:VMF_RESTORED_BY) { $env:VMF_RESTORED_BY } else { 'unknown' })
            DeleteSafetyCopies = $true
            Confirm            = $false   # the person confirmed on the page
        }
        $r = Remove-VmfRun @discardParams
        Write-Host "discard: removed the run; $($r.SafetyCopiesDeleted) safety copies deleted, $($r.SafetyCopiesAlreadyGone) already gone, $($r.MachinesReleased) machines released"
    }
    default { throw "Unknown VMF_OPERATION '$($env:VMF_OPERATION)' (assess | plan | advise | wave | restore | finish | reserve | release | quota | quotacheck | retention | discard | deleteearlier | deletemade | checkvolumes)." }
}
}
catch {
    $reason = $_.Exception.Message
    Write-Host "engine: operation=$($env:VMF_OPERATION) FAILED: $reason"
    try {
        # S4: not under a discard's deleted prefix - that would be a ghost run.
        if (Find-VmfEngineRun) {
        # THROUGH the module. Write-VmfEvent is PRIVATE - not exported - so a
        # bare call from this script's scope cannot see it, and every refusal
        # this wrapper exists to record died with "The term 'Write-VmfEvent' is
        # not recognized". Found by the PERM-2 roles drill, whose wave was
        # refused for naming a wave that did not exist: the container log said
        # so and the run store said nothing, which is exactly the failure
        # described above. The wrapper had never worked.
        # RESTORE-END-LOST-1: a restore or a rebuild names its machine. A
        # failed restore writes no record, and its own last line can be lost
        # (STEP-LOG-2); the Migrations page then ends "Restoring" on THIS line,
        # for the machine it names and the restore whose start line carries
        # the same id. Empty for an operation with no machine.
        # WIZARD-PLAN-FAIL-1: a plan's line goes in the ASSESSMENT's log, and
        # the migration may never get a run.json. It names the migration it was
        # planning, so the wizard that waits for that migration's plan can tell
        # this refusal from the refusal of an earlier plan of the same assessment.
        $failData = if ($env:VMF_OPERATION -eq 'plan' -and $env:VMF_MIGRATION_ID) { @{ migrationId = [string]$env:VMF_MIGRATION_ID } } else { $null }
        & (Get-Module VmMigrationFactory) { param($rp, $step, $why, $vm, $cid, $data)
            Write-VmfEvent -RunPath $rp -Step $step -Outcome fail -Detail $why -VmId $vm -CorrelationId $cid -Data $data
        } $runPath "engine:$($env:VMF_OPERATION)" $reason ([string]$env:VMF_VM_ID) $engineRunId $failData
        }
    }
    catch {
        # Recording the reason must not replace it with a different failure.
        Write-Host "engine: the reason could not be written to the run store: $($_.Exception.Message)"
    }
    throw
}
