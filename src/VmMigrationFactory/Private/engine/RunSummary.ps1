# APPROVE-GROUP-1: the summary of the WHOLE migration, kept in run-status.json.
#
# run-status.json was a snapshot of the wave that was running, written only by
# Start-VmfWave. Two things followed from that, and the migrations list showed
# both:
#
#   - A migration waiting for a person to approve a wave had no status document
#     at all, so the list called it Planned, the same as one nobody needs to
#     touch.
#   - A migration whose wave 1 finished and whose wave 2 waited counted wave 1
#     only - every machine MIGRATED - and the list called it Completed.
#
# So the document now also carries a summary of the whole migration: every
# wave's machines and states, and what the next wave waits for. It is written
# whenever the migration changes in a way the list shows - a plan saved, a
# wave approved or its settings accepted, the plan signed off, the note about
# machines defined in code accepted, a wave running and ending, a decision, a
# machine left out, a stop, a pause, a rebuild - and once a day by the daily
# check, which also gives one to a migration from before this version.
#
# ONE WRITER (Write-VmfRunStatusDocument) for every write of the document, the
# wave's own included, and it is a compare-and-swap: the read and the write are
# one step (Write-VmfTextDocumentIfVersion, the plan's own writer), and a write
# somebody else made in between means read again and build again. The summary
# is always built from the documents themselves, never patched from an older
# summary - except by the wave's ten-second write, which changes its own
# wave's counts only, because reading every machine of the migration every ten
# seconds would cost more than the wave.
#
# NEVER THROWS FROM AN ACTION (Update-VmfRunSummary). The approval, the save or
# the stop is what matters; a summary that cannot be written is a warning in
# the run history, and the next change or the daily check writes it again.

$script:VmfRunStatusSchemaVersion = 8
# OLD-REBUILD-RESTORE-READERS-1 (v7): no reason rebuilt.
# RUN-SUMMARY-SWAP-1 (v6): waitsOnPerson beside stateCounts - the machines
# whose outcome waits for a person (Test-VmfOutcomeWaitsOnPerson), so a machine
# a restore left stopped with its state MIGRATED is counted. The pages read it.
# RUN-STATUS-OLD-SUMMARY-1 (v8): the contract requires waitsOnPerson and
# restoredStops in the summary and in each wave; every writer gives both.
# RESTORED-HOLD-1 (v5): the stop states a restore can end. A machine in one of
# them whose stop a restore ended (Get-VmfMachineOutcome: putBack) is counted
# in restoredStops beside stateCounts, and waits for no person.
$script:VmfRunStopStates = @('FAILED_ROLLED_BACK', 'NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION')
# The live fields of the running wave, kept as they are by a write that only
# changes the summary.
$script:VmfRunStatusLiveFields = @('wave', 'updatedUtc', 'stateCounts', 'running', 'breaker', 'throttle', 'etaUtc')

function Get-VmfRunWaveMembers {
    <#
    .SYNOPSIS
        A short fingerprint of which machines a wave holds: the version of
        their sorted ids. Two summaries whose wave has the same fingerprint
        count the same machines.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()]$Entries)
    $ids = @(@($Entries) | ForEach-Object { ([string]$_.vmId).ToLowerInvariant() } | Sort-Object)
    Get-VmfDocumentVersion -Text ($ids -join ',')
}

function Get-VmfRunSummary {
    <#
    .SYNOPSIS
        The whole migration in one object: each wave's machines and their
        states, in the order the waves run, and what the next wave waits for.
        Pure apart from -GateOf.
    .PARAMETER States
        vmId -> state. A machine with no record has not started (PLANNED).
    .PARAMETER KnownCounts
        wave -> state counts, for a wave whose counts the caller already holds
        (an unchanged wave of the stored summary). Its machines are not looked
        up in -States.
    .PARAMETER Settled
        RESTORED-HOLD-1: the machines whose stop a restore ended
        (Get-VmfMachineOutcome says putBack). They keep the state of the stop
        in the counts - no state is invented - and do not hold the run. A wave
        in -KnownCounts cannot say which machine stopped, so a stop counted
        there still holds: the store reader reads such a wave again.
    .PARAMETER Waiting
        RUN-SUMMARY-SWAP-1: the machines whose outcome waits for a person
        (Test-VmfOutcomeWaitsOnPerson over Get-VmfMachineOutcome), counted in
        waitsOnPerson. A wave in -KnownCounts counts none: the store reader
        keeps a wave's counts only when its stored count is zero.
    .PARAMETER GateOf
        { param($wave, $unattended) } -> which of the engine's start gates the
        wave fails: 'acknowledgement', 'acceptance', 'approval', 'unknown', or
        $null for none - and, when $unattended is true, 'signOffOutOfDate'
        when the timer's rule for a start nobody presses holds it
        (WAVE-APPROVE-TIMER-WORDS-1). Asked only when nothing else holds the
        wave: for the next wave with $unattended true, because the plan's
        timer and a start time start it; for a wave on its way with no worker
        with $unattended false, because the resume watchdog restarts it on its
        start gates alone.
    .OUTPUTS
        An ordered dictionary in the shape of run-status.schema.json's summary.
        next.waitsFor is one of:
          running          a machine is on its way
          none             every wave has run
          decision         a machine waits for a person (the run holds)
          acknowledgement  the note about machines defined in code is not accepted
          acceptance       the next wave's settings are not accepted
          approval         the next wave is not approved, and the plan is not signed off
          signOffOutOfDate the next wave changed after the plan was signed off: the
                           timer and a start time do not start it, a person does
          unknown          a start gate fails that this does not name
          start            nothing holds the next wave: a person starts it, or
                           its start time, or the signed-off plan
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$States,
        [Parameter(Mandatory)][scriptblock]$GateOf,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][bool]$Halted = $false,
        [Parameter()][AllowNull()][hashtable]$KnownCounts,
        # Does any worker hold a machine of this run (a lease)? A machine at a
        # working state with no worker on it is one a decision re-armed, or one
        # a dead worker left: it waits for its wave to start again, and that
        # start has gates.
        [Parameter()][bool]$Leased = $true,
        [Parameter()][AllowEmptyCollection()][string[]]$Settled = @(),
        [Parameter()][AllowEmptyCollection()][string[]]$Waiting = @()
    )
    $engine = Get-VmfEngineStates
    $settledIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Settled)) { if ($id) { [void]$settledIds.Add([string]$id) } }
    $waitingIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Waiting)) { if ($id) { [void]$waitingIds.Add([string]$id) } }
    $stateOf = { param($id) if ($States.ContainsKey([string]$id)) { [string]$States[[string]$id] } else { $engine.NotStarted } }
    # The waves that run, in the order they run - the same rule the signed-off
    # plan and the pages use (WAVE-ORDER-1). A machine not in a wave, or not
    # moved, is not part of any.
    $order = @(Get-VmfPlanWaveOrder -Plan $Plan)

    $total = [ordered]@{}
    $machines = 0
    $totalRestored = 0
    $totalWaiting = 0
    $working = $null
    $held = $false
    $next = $null
    $waves = foreach ($w in $order) {
        $mine = @(@($Plan.entries) | Where-Object { $_ -and [string]$_.path -eq 'A' -and [string]$_.wave -eq $w })
        $counts = [ordered]@{}
        # RESTORED-HOLD-1 (v5): a wave in -KnownCounts counts none - the
        # store reader reads a wave with a stop again.
        $restoredStops = 0
        $waitingHere = 0
        if ($KnownCounts -and $KnownCounts.ContainsKey($w)) {
            foreach ($k in @($KnownCounts[$w].Keys)) { $counts[[string]$k] = [int]$KnownCounts[$w][$k] }
            if (@($counts.Keys | Where-Object { $_ -in $script:VmfPlanRunHolds -and [int]$counts[$_] -gt 0 }).Count) { $held = $true }
        }
        else {
            foreach ($e in $mine) {
                $s = & $stateOf $e.vmId
                $counts[$s] = 1 + $(if ($counts.Contains($s)) { $counts[$s] } else { 0 })
                # RESTORED-HOLD-1: the rule of Get-VmfNextPlanWave.
                if ($s -in $script:VmfPlanRunHolds -and -not $settledIds.Contains([string]$e.vmId)) { $held = $true }
                if ($s -in $script:VmfRunStopStates -and $settledIds.Contains([string]$e.vmId)) { $restoredStops++ }
                if ($waitingIds.Contains([string]$e.vmId)) { $waitingHere++ }
            }
        }
        foreach ($s in @($counts.Keys)) {
            $n = [int]$counts[$s]
            if ($n -le 0) { continue }
            $total[$s] = $n + $(if ($total.Contains($s)) { $total[$s] } else { 0 })
            if ($s -eq $engine.NotStarted) { if (-not $next) { $next = $w } }
            elseif ($s -notin $engine.Terminal) { if (-not $working) { $working = $w } }
        }
        $machines += $mine.Count
        $totalRestored += $restoredStops
        $totalWaiting += $waitingHere
        [ordered]@{ wave = $w; machines = $mine.Count; members = (Get-VmfRunWaveMembers -Entries $mine); stateCounts = $counts; restoredStops = $restoredStops; waitsOnPerson = $waitingHere }
    }

    # The order of these is the order of Get-VmfNextPlanWave: a machine on its
    # way first, then nothing left, then a machine waiting for a person, then
    # the next wave's own start gates.
    $waitsFor = if ($working) {
            if ($Leased) { 'running' }
            else {
                # The resume watchdog restarts such a wave only when its start
                # gates pass (RESUME-GATE-1), so ask them the same way.
                $gate = & $GateOf $working $false
                if ($gate) { [string]$gate } else { 'running' }
            }
        }
        elseif (-not $next) { 'none' }
        elseif ($held) { 'decision' }
        else {
            $gate = & $GateOf $next $true
            if ($gate) { [string]$gate } else { 'start' }
        }
    $nextWave = if ($working) { $working } elseif ($next) { $next } else { $null }

    [ordered]@{
        writtenUtc  = (Get-Date).ToUniversalTime().ToString('o')
        reason      = $Reason
        halted      = $Halted
        machines    = $machines
        stateCounts = $total
        restoredStops = $totalRestored
        waitsOnPerson = $totalWaiting
        waves       = @($waves)
        next        = [ordered]@{ wave = $nextWave; waitsFor = $waitsFor }
    }
}
function Get-VmfRunSummaryGate {
    <#
    .SYNOPSIS
        Which start gate a wave fails, by name - or $null when it fails none.
    .DESCRIPTION
        Asks Get-VmfWaveStartGate, the one list everything that starts a wave
        uses (RESUME-GATE-1), and names the gate it failed by the gate's own
        name (GATE-WORDS-1: every refusal carries it beside its code). A
        refusal that names a gate not in this list reads as 'unknown': the wave
        waits, and this does not claim to know for what.

        WAVE-APPROVE-TIMER-WORDS-1: with -Unattended, a wave that passes
        every start gate is also asked the timer's own rule for a start nobody
        presses (Get-VmfUnattendedStartRefusal), in the order the timer asks
        it (Get-VmfPlanRunDecision), and its refusal is named by its code,
        signOffOutOfDate. The summary said 'start' for such a wave, so the
        Migrations list put it under Planned - "nothing waits for a person" -
        while the timer held it until a person started it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave,
        # The wave starts with nobody pressing Start: the next wave of a
        # signed-off plan, or a start time.
        [Parameter()][switch]$Unattended,
        # The text of the plan in -Plan, as it was read. Empty for a plan
        # held elsewhere: then no sign-off can consent to it, and the rule
        # adds nothing.
        [Parameter()][AllowEmptyString()][string]$PlanText = ''
    )
    try {
        $gate = Get-VmfWaveStartGate -RunPath $RunPath -PlanPath $PlanPath -Plan $Plan -Wave $Wave
        if (-not $gate -and $Unattended) {
            $gate = Get-VmfUnattendedStartRefusal -RunPath $RunPath -PlanText $PlanText -Wave $Wave
            if ($gate) { return $(if ([string]$gate.Code -eq 'signOffOutOfDate') { 'signOffOutOfDate' } else { 'unknown' }) }
        }
        if (-not $gate) { return $null }
        $name = [string]$gate.Gate
        if ($name -in @('acknowledgement', 'acceptance', 'approval')) { return $name }
        'unknown'
    }
    catch { 'unknown' }
}

function Get-VmfRunSummaryFromStore {
    <#
    .SYNOPSIS
        Get-VmfRunSummary, fed from the store: the plan, the machines' state
        documents, the halt flag and the next wave's start gates.
    .DESCRIPTION
        THE COST IS ONE STORE READ PER MACHINE THAT HAS STARTED, and the
        service makes some of these writes inside a request. So -Quick, for a
        change that moves no machine (a plan saved, a gate passed, a pause):
        a wave of the stored summary that holds the same machines and has none
        on its way keeps its counts, and only the other waves are read. A wave
        a plan edit changed is one nothing has started in (WAVE-MIX-2), so it
        is read at no cost - none of its machines has a document. -Reread
        names the waves whose machines changed (a decision, a machine left
        out), which are read whatever the stored summary says.
    .PARAMETER Plan
        The plan the caller holds, used only when there is no plan at
        -PlanPath (a wave started from a plan held elsewhere).
    .OUTPUTS
        The summary, or $null when the run has no plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][AllowNull()]$Plan,
        [Parameter()][AllowNull()]$Stored,
        [Parameter()][AllowEmptyCollection()][string[]]$Reread = @(),
        [Parameter()][switch]$Quick
    )
    $read = $null
    if ($PlanPath -match '^azblob://' -or (Test-Path -LiteralPath $PlanPath)) { $read = Read-VmfPlanFileVersioned -Path $PlanPath }
    $plan = if ($read) { $read.Plan } else { $Plan }
    if (-not $plan) { return $null }
    $engine = Get-VmfEngineStates
    $moving = @(@($plan.entries) | Where-Object { $_ -and [string]$_.path -eq 'A' -and [string]$_.wave })

    $known = @{}
    if ($Quick -and (Test-VmfRunSummaryShape -Summary $Stored)) {
        foreach ($sw in @($Stored.waves)) {
            if (-not $sw) { continue }
            $name = [string]$sw.wave
            if ($name -in $Reread -or -not $sw.PSObject.Properties['members']) { continue }
            $now = @($moving | Where-Object { [string]$_.wave -eq $name })
            if (-not $now.Count -or [string]$sw.members -ne (Get-VmfRunWaveMembers -Entries $now)) { continue }
            $waveCounts = @{}
            foreach ($prop in $sw.stateCounts.PSObject.Properties) { $waveCounts[$prop.Name] = [int]$prop.Value }
            $onTheWay = @($waveCounts.Keys | Where-Object { $waveCounts[$_] -gt 0 -and $_ -ne $engine.NotStarted -and $_ -notin $engine.Terminal })
            if ($onTheWay.Count) { continue }
            # RESTORED-HOLD-1: a stop counted here may since have been ended by
            # a restore, which changes the record and not the state - so the
            # counts cannot tell. Such a wave is read again.
            $stopped = @($waveCounts.Keys | Where-Object { $waveCounts[$_] -gt 0 -and $_ -in $script:VmfRunStopStates })
            if ($stopped.Count) { continue }
            # RUN-SUMMARY-SWAP-1: a machine a restore left stopped keeps the
            # state MIGRATED, so the counts cannot tell either. A wave whose
            # stored count says a machine waits, or that has no count, is read
            # again; Finish the restore changes the record, not the state.
            $waitingProp = $sw.PSObject.Properties['waitsOnPerson']
            if (-not $waitingProp -or $null -eq $waitingProp.Value -or [int]$waitingProp.Value -ne 0) { continue }
            $known[$name] = $waveCounts
        }
    }

    # Only the machines of the waves not known, and only those with a document.
    $have = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json')) { [void]$have.Add([string]$name) }
    $states = @{}
    $settled = [System.Collections.Generic.List[string]]::new()
    $waiting = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($moving | Where-Object { -not $known.ContainsKey([string]$_.wave) })) {
        $file = (Get-VmfVmKey -VmId ([string]$e.vmId)) + '.json'
        if (-not $have.Contains($file)) { continue }
        $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$file"
        if ($doc -and $doc.state) {
            $states[[string]$e.vmId] = [string]$doc.state
            # RESTORED-HOLD-1: the one rule for "a restore ended the stop".
            $outcome = Get-VmfMachineOutcome -StateDoc $doc
            if ($outcome -eq 'putBack') { $settled.Add([string]$e.vmId) }
            # RUN-SUMMARY-SWAP-1: and for "waits for a person".
            if (Test-VmfOutcomeWaitsOnPerson -Outcome $outcome) { $waiting.Add([string]$e.vmId) }
        }
    }
    # Not GetNewClosure(): a closure is a new module, and cannot see this
    # module's private functions. Names nothing in Get-VmfRunSummary uses, so
    # the call finds these.
    $gateRunPath = $RunPath
    $gatePlanPath = $PlanPath
    $gatePlan = $plan
    $gatePlanText = if ($read) { [string]$read.Text } else { '' }
    $gateOf = { param($w, $unattended)
        Get-VmfRunSummaryGate -RunPath $gateRunPath -PlanPath $gatePlanPath -Plan $gatePlan -Wave $w -Unattended:([bool]$unattended) -PlanText $gatePlanText }
    # RESTORE-ONE-AT-A-TIME-1: only a wave worker's lease means a wave runs. A
    # restore or a rebuild holds its machine with the same file.
    $leased = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'leases' -Extension '.lease' | Where-Object {
        $held = Read-VmfStoreJson -RunPath $RunPath -RelPath "leases/$_" -Depth 6
        $held -and -not (Test-VmfPutBackLeaseHolder -WorkerId ([string]$held.workerId))
    }).Count -gt 0
    Get-VmfRunSummary -Plan $plan -States $states -GateOf $gateOf -Reason $Reason -KnownCounts $known `
        -Halted ([bool](Test-VmfWaveHalted -RunPath $RunPath)) -Leased $leased -Settled @($settled) -Waiting @($waiting)
}
function Test-VmfRunSummaryShape {
    <#
    .SYNOPSIS
        Is this a summary a reader can use? An older document has none, and
        absent reads as "cannot tell" - never as a group.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Summary)
    if (-not $Summary) { return $false }
    foreach ($field in 'waves', 'next', 'stateCounts') {
        if (-not $Summary.PSObject.Properties[$field] -and -not ($Summary -is [System.Collections.IDictionary] -and $Summary.Contains($field))) { return $false }
    }
    [bool]($Summary.next -and [string]$Summary.next.waitsFor)
}

function Update-VmfRunSummaryWave {
    <#
    .SYNOPSIS
        The wave's ten-second write: the stored summary with ONE wave's counts
        replaced by the live ones. Pure. $null when the stored summary cannot
        be patched (none, a summary or a wave with no count of the machines
        that wait for a person or of the stops a restore ended, or the wave is
        not in it) - the caller then builds it from the store.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Summary,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary]$Counts,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][bool]$Halted = $false
    )
    if (-not (Test-VmfRunSummaryShape -Summary $Summary)) { return $null }
    if (-not (@($Summary.waves) | Where-Object { $_ -and [string]$_.wave -eq $Wave })) { return $null }
    # RUN-STATUS-OLD-SUMMARY-1: every summary this version writes holds both
    # counts, for the summary and for each wave (Get-VmfRunSummaryFromStore,
    # Write-VmfRunStatusDocument). One with a count missing is not patched:
    # the caller builds it from the store.
    $field = { param($o, $n) if ($o -is [System.Collections.IDictionary]) { $o[$n] } elseif ($o -and $o.PSObject.Properties[$n]) { $o.PSObject.Properties[$n].Value } else { $null } }
    if ($null -eq (& $field $Summary 'waitsOnPerson') -or $null -eq (& $field $Summary 'restoredStops')) { return $null }
    foreach ($w in @($Summary.waves)) {
        if (-not $w -or $null -eq (& $field $w 'waitsOnPerson') -or $null -eq (& $field $w 'restoredStops')) { return $null }
    }
    $asDict = { param($o)
        $d = [ordered]@{}
        if ($o -is [System.Collections.IDictionary]) { foreach ($k in $o.Keys) { $d[[string]$k] = [int]$o[$k] } }
        elseif ($o) { foreach ($p in $o.PSObject.Properties) { $d[$p.Name] = [int]$p.Value } }
        $d
    }
    $total = [ordered]@{}
    $machines = 0
    $totalRestored = 0
    $stopsIn = { param($d) $n = 0; foreach ($k in @($d.Keys)) { if ($k -in $script:VmfRunStopStates) { $n += [int]$d[$k] } }; $n }
    $totalWaiting = 0
    $waves = foreach ($w in @($Summary.waves)) {
        if (-not $w) { continue }
        # Not $counts: names ignore case, and that is the -Counts parameter.
        $waveCounts = if ([string]$w.wave -eq $Wave) { & $asDict $Counts } else { & $asDict $w.stateCounts }
        $n = 0
        foreach ($k in @($waveCounts.Keys)) {
            $n += $waveCounts[$k]
            $total[$k] = $waveCounts[$k] + $(if ($total.Contains($k)) { $total[$k] } else { 0 })
        }
        $machines += $n
        $patchedWave = [ordered]@{ wave = [string]$w.wave; machines = $n }
        if ($w.PSObject.Properties['members'] -or ($w -is [System.Collections.IDictionary] -and $w.Contains('members'))) { $patchedWave.members = [string]$w.members }
        $patchedWave.stateCounts = $waveCounts
        # RESTORED-HOLD-1: the other waves keep their count; the running wave
        # counts none until the wave's last write builds the summary from the
        # store.
        $kept = if ([string]$w.wave -ne $Wave) { [int](& $field $w 'restoredStops') } else { 0 }
        $patchedWave.restoredStops = $kept
        $totalRestored += $kept
        # The other waves keep their count. The running wave keeps its count
        # moved by the change in its stop states: a new stop waits for a
        # person, and a decision made moves on. A machine a restore left
        # stopped is MIGRATED, which the wave does not run again, so it stays
        # counted.
        $waitingNow = [int](& $field $w 'waitsOnPerson')
        if ([string]$w.wave -eq $Wave) {
            $waitingNow = [Math]::Max(0, $waitingNow + (& $stopsIn $waveCounts) - (& $stopsIn (& $asDict $w.stateCounts)))
        }
        $patchedWave.waitsOnPerson = $waitingNow
        $totalWaiting += $waitingNow
        $patchedWave
    }
    $patched = [ordered]@{
        writtenUtc  = (Get-Date).ToUniversalTime().ToString('o')
        reason      = $Reason
        halted      = $Halted
        machines    = $machines
        stateCounts = $total
        restoredStops = $totalRestored
        waitsOnPerson = $totalWaiting
    }
    $patched.waves = @($waves)
    # The wave is running while its loop runs. When it ends, the loop's
    # last write builds the summary from the store again (waveEnded).
    $patched.next = [ordered]@{ wave = $Wave; waitsFor = 'running' }
    $patched
}

function Merge-VmfRunSummaryPatch {
    <#
    .SYNOPSIS
        After a conflict: keep a summary that was costly to build, when the
        write that landed in between was only the running wave's own. Pure.
    .DESCRIPTION
        The wave's ten-second write changes its own wave's counts and nothing
        else, and with several containers it lands every few seconds. A full
        summary that took longer than that to build would conflict on every
        attempt and never be written. So when the newer summary is such a
        write (reason waveRunning, running) over the SAME waves - every name
        and fingerprint equal - this summary is kept with that wave's counts
        taken from it. Anything else: $null, and the caller builds again.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Mine, [Parameter()][AllowNull()]$Theirs)
    if (-not (Test-VmfRunSummaryShape -Summary $Theirs)) { return $null }
    if ([string]$Theirs.reason -ne 'waveRunning' -or [string]$Theirs.next.waitsFor -ne 'running') { return $null }
    $shape = { param($s) (@(@($s.waves) | ForEach-Object { "$([string]$_.wave)=$([string]$_.members)" }) -join ';') }
    if ((& $shape $Mine) -ne (& $shape $Theirs)) { return $null }
    $running = [string]$Theirs.next.wave
    $theirWave = @($Theirs.waves) | Where-Object { [string]$_.wave -eq $running } | Select-Object -First 1
    if (-not $theirWave) { return $null }
    $counts = [ordered]@{}
    if ($theirWave.stateCounts -is [System.Collections.IDictionary]) { foreach ($k in $theirWave.stateCounts.Keys) { $counts[[string]$k] = [int]$theirWave.stateCounts[$k] } }
    else { foreach ($prop in $theirWave.stateCounts.PSObject.Properties) { $counts[$prop.Name] = [int]$prop.Value } }
    $merged = Update-VmfRunSummaryWave -Summary $Mine -Wave $running -Counts $counts -Reason ([string]$Mine.reason) -Halted ([bool]$Theirs.halted)
    if ($merged) { $merged.writtenUtc = [string]$Mine.writtenUtc }
    $merged
}

function Write-VmfRunStatusDocument {
    <#
    .SYNOPSIS
        THE writer of run-status.json. Reads it, builds the new document, and
        writes it only if nobody wrote it in between - otherwise reads again.
    .DESCRIPTION
        -Live: the running wave's snapshot (the wave's own write). Without it,
        the live fields already in the document are kept as they are, so a
        summary written by an approval does not wipe the counts of the wave
        that ran last - other readers still take those.
        -PatchWave/-PatchCounts: the wave's ten-second write, which changes its
        own wave in the stored summary instead of reading every machine.
        A write that only changes the summary is skipped when the summary would
        not change, so the daily check does not touch every migration.
    .OUTPUTS
        The document as written (or as found, when nothing changed); $null when
        the run has no plan and there is no wave writing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][ValidateSet('planSaved', 'waveApproved', 'planSignedOff', 'optionsAccepted', 'acknowledged', 'waveRunning', 'waveEnded', 'decision', 'machineSkipped', 'runStopped', 'paused', 'resumed', 'putBack', 'dailyCheck')][string]$Reason,
        [Parameter()][string]$RunId,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$Live,
        [Parameter()][string]$PatchWave,
        [Parameter()][AllowNull()][System.Collections.IDictionary]$PatchCounts,
        # The plan the wave holds, for a run whose plan.json is elsewhere.
        [Parameter()][AllowNull()]$Plan,
        # The waves whose machines changed. With it, or for a change that
        # moves no machine, only what changed is read (Get-VmfRunSummaryFromStore -Quick).
        [Parameter()][AllowEmptyCollection()][string[]]$Waves = @(),
        [Parameter()][int]$Attempts = 5
    )
    $quick = ($Reason -in @('planSaved', 'waveApproved', 'planSignedOff', 'optionsAccepted', 'acknowledged', 'paused', 'resumed')) -or @($Waves | Where-Object { $_ }).Count -gt 0
    if (-not $RunId) { $RunId = Split-Path $RunPath -Leaf }
    $handle = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'run-status.json'
    $comparable = { param($s)
        if (-not $s) { return '' }
        $copy = [ordered]@{}
        foreach ($k in 'halted', 'machines', 'stateCounts', 'restoredStops', 'waitsOnPerson', 'waves', 'next') {
            $copy[$k] = if ($s -is [System.Collections.IDictionary]) { $s[$k] } else { $s.$k }
        }
        $copy | ConvertTo-Json -Depth 12 -Compress
    }
    $summary = $null
    $builtFull = $false
    for ($attempt = 1; $attempt -le $Attempts; $attempt++) {
        $text = Read-VmfStoreText -RunPath $RunPath -RelPath 'run-status.json'
        # A document that exists and reads empty (a writer that died between
        # creating it and writing it) is written over, not created again.
        $empty = ($null -eq $text -and (Test-VmfStoreItem -RunPath $RunPath -RelPath 'run-status.json')) -or ($null -ne $text -and -not $text.Trim())
        $existing = $null
        if ($text) { try { $existing = $text | ConvertFrom-Json -Depth 24 } catch { $existing = $null } }
        $stored = if ($existing -and $existing.PSObject.Properties['summary']) { $existing.summary } else { $null }

        # After a conflict a full summary is kept when only the wave's own
        # write landed meanwhile (Merge-VmfRunSummaryPatch); otherwise built again.
        if ($summary -and $builtFull) { $summary = Merge-VmfRunSummaryPatch -Mine $summary -Theirs $stored }
        else { $summary = $null }
        if (-not $summary -and $PatchWave -and $null -ne $PatchCounts) {
            $summary = Update-VmfRunSummaryWave -Summary $stored -Wave $PatchWave -Counts $PatchCounts -Reason $Reason `
                -Halted $(if ($Live -and $Live['breaker']) { [bool]$Live['breaker']['halted'] } else { [bool](Test-VmfWaveHalted -RunPath $RunPath) })
        }
        if (-not $summary) {
            $summary = Get-VmfRunSummaryFromStore -RunPath $RunPath -PlanPath $PlanPath -Reason $Reason -Plan $Plan -Stored $stored -Reread @($Waves | Where-Object { $_ }) -Quick:$quick
            $builtFull = [bool]$summary
        }
        if (-not $summary -and -not $Live) { return $null }
        if (-not $summary) {
            $summary = [ordered]@{ writtenUtc = (Get-Date).ToUniversalTime().ToString('o'); reason = $Reason; halted = $false
                                   machines = 0; stateCounts = [ordered]@{}; restoredStops = 0; waitsOnPerson = 0; waves = @(); next = [ordered]@{ wave = $null; waitsFor = 'none' } }
        }
        if (-not $Live -and $existing -and [int]$existing.schemaVersion -eq $script:VmfRunStatusSchemaVersion -and
            (& $comparable $stored) -eq (& $comparable $summary)) {
            return $existing
        }

        $doc = [ordered]@{ schemaVersion = $script:VmfRunStatusSchemaVersion; runId = $RunId }
        foreach ($field in $script:VmfRunStatusLiveFields) {
            if ($Live) { if ($Live.Contains($field)) { $doc[$field] = $Live[$field] } }
            elseif ($existing -and $existing.PSObject.Properties[$field]) { $doc[$field] = $existing.$field }
        }
        if ($existing -and $existing.PSObject.Properties['runId'] -and [string]$existing.runId -and -not $Live) { $doc.runId = [string]$existing.runId }
        # The pause the summary just read is the one the safety brake's field
        # reports: a resume must not leave the run page saying paused.
        if (-not $Live -and $doc.Contains('breaker') -and $doc.breaker) {
            $brake = [ordered]@{}
            foreach ($prop in $doc.breaker.PSObject.Properties) { $brake[$prop.Name] = $prop.Value }
            $brake.halted = [bool]$summary.halted
            $doc.breaker = $brake
        }
        $doc.summary = $summary

        try {
            if ($null -eq $text -and -not $empty) {
                # Create-if-absent: of two first writers exactly one wins, and
                # the other reads what it wrote and builds again.
                # STORE-CREATE-LOST-ANSWER-1: a stored text that is this document IS
                # this document, whoever wrote it, so it is returned.
                if (Write-VmfStoreJsonExclusive -RunPath $RunPath -RelPath 'run-status.json' -Document $doc -UniqueText) { return $doc }
            }
            elseif ($empty) {
                # An empty document carries no version to check against.
                Write-VmfStoreJson -RunPath $RunPath -RelPath 'run-status.json' -Document $doc
                return $doc
            }
            else {
                Write-VmfTextDocumentIfVersion -Path $handle -Content ($doc | ConvertTo-Json -Depth 24) `
                    -ExpectedVersion (Get-VmfDocumentVersion -Text $text) -WaitMilliseconds 3000
                return $doc
            }
        }
        catch {
            if ("$($_.Exception.Message)" -notmatch '^409') { throw }
        }
        Start-Sleep -Milliseconds (Get-Random -Minimum 20 -Maximum 150)
    }
    throw "409: Other writers changed the status of this migration $Attempts times, so the product did not write it."
}

function Update-VmfRunSummary {
    <#
    .SYNOPSIS
        Write the summary of the whole migration after an action changed it.
        Returns $true when written (or already current). NEVER THROWS.
    .DESCRIPTION
        Called at the end of every action the migrations list shows: the
        action already happened, and a document about it that cannot be
        written must not turn it into a failure. A failure is a warning in the
        run history; the next change, the next wave or the daily check writes
        the summary again. A run with no plan has nothing to summarise and is
        left alone.
    .PARAMETER PlanPath
        The plan the action read. Omitted: the run's own plan.json.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][string]$PlanPath,
        [Parameter(Mandatory)][ValidateSet('planSaved', 'waveApproved', 'planSignedOff', 'optionsAccepted', 'acknowledged', 'waveRunning', 'waveEnded', 'decision', 'machineSkipped', 'runStopped', 'paused', 'resumed', 'putBack', 'dailyCheck')][string]$Reason,
        # The waves whose machines this action changed - read again, and only
        # they (Write-VmfRunStatusDocument).
        [Parameter()][AllowEmptyCollection()][string[]]$Wave = @()
    )
    try {
        if (-not $PlanPath) {
            if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'plan.json')) { return $false }
            $PlanPath = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json'
        }
        [bool](Write-VmfRunStatusDocument -RunPath $RunPath -PlanPath $PlanPath -Reason $Reason -Waves $Wave)
    }
    catch {
        $why = $_.Exception.Message
        Write-VmfStepLine -RunPath $RunPath -Step 'status' -Outcome warn `
            -Detail "The product could not write the status of this migration for the list on the Migrations page: $why. The next change to this migration writes it again, and so does the daily check."
        $false
    }
}

function Update-VmfRunSummaryAfterPutBack {
    <#
    .SYNOPSIS
        RESTORED-HOLD-1: write the summary of the migration after a restore or
        a finish, reading the machine's wave again. Returns $true when written
        (or already current). NEVER THROWS.
    .DESCRIPTION
        A restore that ends a stop changes the machine's record and not its
        state, and nothing wrote the summary after it: the list on the
        Migrations page said the next wave waits for a decision until the next
        change or the daily check. The engine calls this after Restore this
        machine and after Finish the restore or Finish the rollback, with the
        reason putBack (run-status v5). A machine with no record, or no wave
        on it, is written with every wave read.
        RUN-SUMMARY-SWAP-1: after a restore it runs in a finally, so a
        restore whose data disk swap Azure refused - it throws after it
        writes swapPending - is counted in waitsOnPerson at once.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $wave = $null
    try {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
        if ($doc) { $wave = [string](Get-VmfRecordField -Object $doc -Name 'wave') }
    }
    catch { $wave = $null }
    Update-VmfRunSummary -RunPath $RunPath -Reason 'putBack' -Wave @(if ($wave) { $wave })
}