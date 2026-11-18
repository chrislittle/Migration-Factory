# PLANRUN-1: sign off the plan, and let it run.
#
# The engine runs ONE wave and its container exits. Nothing ever started the
# next one, so an eight-wave plan was eight returns to the console - and three
# approved waves once sat idle because nothing was coming for them.
#
# THE RULE, agreed 2026-09-23:
#
#   When a wave finishes, the next one starts - UNLESS it has a start time in
#   the future (then it waits for that time), or a machine is parked for a
#   decision (then the run holds).
#
# "Run it all now" is simply the case where no wave has a time. One mechanism.
#
# Everything here decides; nothing here starts anything. The facade's timer
# asks Get-VmfNextPlanWave and does the starting, with the same guards the
# stalled-wave resume already has against starting twice.

# The states a machine is in while an engine is working on it.
$script:VmfPlanRunWorking = @('PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED',
                              'CONVERTING', 'STARTING', 'VALIDATING')
# A machine here needs a PERSON. The ruling: finish the current wave,
# then hold - a reason true of one machine (the first case was a kernel below
# the network driver floor) is probably true of the next wave's machines too, and carrying
# on turns one decision into eight.
$script:VmfPlanRunHolds = @('NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION')

function Get-VmfPlanWaveOrder {
    <#
    .SYNOPSIS
        The plan's waves in the order they run. Only waves with a machine the
        engine moves (path A).
    .DESCRIPTION
        WAVE-ORDER-1: the plan's own `waveOrder` - the order the person
        arranged in the wave editor - decides, and a wave it does not name
        follows in the order it first appears. This used to be first appearance
        alone, which is the order of the MACHINES, alphabetical by name: a plan
        whose editor showed gen2-wave first ran gen1-wave first, because a
        machine called vmf-e2e-g1 sorts before vmf-e2e-lin. Found by the first
        end-to-end run of ADVISOR-1. The pages read the same rule
        (VmfHelp.waveOrder), so what is shown is what runs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Plan)
    $present = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Plan.entries)) {
        if (-not $e -or [string]$e.path -ne 'A') { continue }
        $w = [string]$e.wave
        if (-not $w -or $w -eq 'unscheduled' -or $present.Contains($w)) { continue }
        $present.Add($w)
    }
    $order = [System.Collections.Generic.List[string]]::new()
    if ($Plan.PSObject.Properties['waveOrder']) {
        foreach ($w in @($Plan.waveOrder)) {
            $name = [string]$w
            if ($present.Contains($name) -and -not $order.Contains($name)) { $order.Add($name) }
        }
    }
    foreach ($w in $present) { if (-not $order.Contains($w)) { $order.Add($w) } }
    @($order)
}

function Test-VmfPlanSignedOff {
    <#
    .SYNOPSIS
        Is there a plan sign-off for THIS version of the plan? Fails closed:
        no document, or one for an older version, is not signed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][AllowEmptyString()][string]$PlanText)
    $approval = Read-VmfStoreJson -RunPath $RunPath -RelPath 'plan-approval.json' -Depth 6
    if (-not $approval) { return @{ Pass = $false; Detail = 'the plan has not been signed off'; Approval = $null } }
    if (-not $PlanText -or (Get-VmfDocumentVersion -Text $PlanText) -ne [string]$approval.planHash) {
        return @{ Pass = $false; Detail = 'the plan changed after it was signed off, so it must be signed off again'; Approval = $approval }
    }
    @{ Pass = $true; Detail = "the plan was signed off by $($approval.approvedBy.identity) at $($approval.approvedUtc)"; Approval = $approval }
}

function Test-VmfPlanRunConsent {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: has somebody consented to this plan running on by
        itself - each next wave started when the one before it finishes?
    .DESCRIPTION
        A sign-off of v3 is written with one approval per wave, and each wave's
        own approval is its gate (Get-VmfWaveStartGate asks it before the timer
        starts anything). So the consent survives a change to one wave: that
        wave asks again for its approval, and the run waits at it, while the
        others keep theirs. That is the rule - a change to one wave
        asks again for that wave only. Approve-VmfPlan writes only v4, which
        keeps the v3 rule of one approval per wave (MIGRATIONS-PAGE-OLD-READERS-1,
        SQL-TEMPDB-SIGNOFF-1), so the version is not read.
        ExactPlan says which: true when the sign-off is for the plan as it is
        now, false when the consent is a sign-off of an earlier version - and
        then a wave starts by itself only on an approval that is still current
        (Test-VmfPlanRunWaveSigned).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][AllowEmptyString()][string]$PlanText)
    $signed = Test-VmfPlanSignedOff -RunPath $RunPath -PlanText $PlanText
    $approval = $signed.Approval
    if ($signed.Pass) { $signed.ExactPlan = $true; return $signed }
    if ($approval -and $PlanText) {
        return @{ Pass = $true; Approval = $approval; ExactPlan = $false
            Detail = "the plan was signed off by $($approval.approvedBy.identity) at $($approval.approvedUtc), and each wave is started only with its own approval" }
    }
    $signed.ExactPlan = $false
    $signed
}

function Test-VmfPlanRunWaveSigned {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: may the TIMER start this wave on a sign-off of an
        earlier plan version? Only when the wave's own approval - the one the
        sign-off wrote, or one given since - still signs the wave as it is.
    .DESCRIPTION
        The approval gate passes a wave set not to need approval with no
        approval at all, which is right for a person who starts it by hand.
        But a start nobody presses must rest on something an approver signed.
        Before this item the consent itself lapsed at any change; now it stays,
        so the wave's approval has to: "Sign off all" writes one for every wave,
        and a change to the wave removes it. A person can still start such a
        wave by hand, as before.
    .OUTPUTS
        $null when it may, or the refusal (code signOffOutOfDate).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlanText,
        [Parameter(Mandatory)][string]$Wave
    )
    $approval = $null
    try { $approval = Read-VmfStoreJson -RunPath $RunPath -RelPath "approvals/$Wave.json" -Depth 8 } catch { $approval = $null }
    if (Test-VmfWaveApprovalCurrent -Approval $approval -Wave $Wave -PlanText $PlanText) { return $null }
    New-VmfStartGateRefusal -Code 'signOffOutOfDate' -Wave $Wave
}

function Get-VmfUnattendedStartRefusal {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: the one rule for a start nobody presses - the next
        wave of a signed-off plan (the timer) and a scheduled start.
    .DESCRIPTION
        On a v3 sign-off of an EARLIER plan version, a wave starts by itself
        only on its own approval, still current (Test-VmfPlanRunWaveSigned) -
        even a wave set not to need one when a person starts it. The second
        review found the schedule release asked only the approval gate, so a
        wave set not to need approval and changed after the sign-off started
        at its time with no approver looking. A sign-off of the exact plan, or
        no sign-off at all, adds nothing here: the approval gate decides, as
        before.
    .PARAMETER Consent
        Test-VmfPlanRunConsent of the same text, when the caller has it.
    .OUTPUTS
        $null when the wave may start by itself, or the refusal (signOffOutOfDate).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlanText,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()]$Consent
    )
    if (-not $Consent) { $Consent = Test-VmfPlanRunConsent -RunPath $RunPath -PlanText $PlanText }
    if ($Consent.Pass -and -not $Consent.ExactPlan) { return (Test-VmfPlanRunWaveSigned -RunPath $RunPath -PlanText $PlanText -Wave $Wave) }
    $null
}

function Get-VmfNextPlanWave {
    <#
    .SYNOPSIS
        What a signed-off plan does next, decided from what the store says.
        Pure: no store, no Azure.
    .OUTPUTS
        Wave: the wave to start now, or $null. Reason: start, notSigned,
        halted, running, held, notStarted, scheduled, done. Detail: a sentence.
        After: the wave before it. Throttle: its "how many at once".
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Plan,
        # vmId -> state. A machine with no record has not started.
        [Parameter(Mandatory)][hashtable]$States,
        [Parameter(Mandatory)][bool]$SignedOff,
        [Parameter(Mandatory)][bool]$Halted,
        # Waves with a start time still pending.
        [Parameter()][AllowEmptyCollection()][string[]]$ScheduledWaves = @(),
        # RESTORED-HOLD-1: the machines whose stop a restore ended
        # (Get-VmfMachineOutcome says putBack). They keep the state of the
        # stop, and no longer wait for a person, so they do not hold the run.
        [Parameter()][AllowEmptyCollection()][string[]]$Settled = @()
    )
    $none = { param($reason, $detail) [pscustomobject]@{ Wave = $null; Reason = $reason; Detail = $detail; After = $null; Throttle = $null } }
    $settledIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @($Settled)) { if ($id) { [void]$settledIds.Add([string]$id) } }

    if (-not $SignedOff) { return & $none 'notSigned' 'the plan has not been signed off, so no wave starts on its own' }
    if ($Halted) { return & $none 'halted' 'the run is paused, so no wave starts on its own until somebody resumes it' }

    $entries = @($Plan.entries | Where-Object { $_ -and [string]$_.path -eq 'A' -and [string]$_.wave -and [string]$_.wave -ne 'unscheduled' })
    $stateOf = { param($id) if ($States.ContainsKey([string]$id)) { [string]$States[[string]$id] } else { 'PLANNED' } }

    $working = @($entries | Where-Object { (& $stateOf $_.vmId) -in $script:VmfPlanRunWorking })
    if ($working.Count) { return & $none 'running' "A wave is running. The engine works on $($working.Count) $(if ($working.Count -eq 1) { 'machine' } else { 'machines' })." }

    $held = @($entries | Where-Object { (& $stateOf $_.vmId) -in $script:VmfPlanRunHolds -and -not $settledIds.Contains([string]$_.vmId) })
    if ($held.Count) {
        $names = (@($held | ForEach-Object { ([string]$_.vmId -split '/')[-1] }) | Select-Object -First 5) -join ', '
        return & $none 'held' "The run holds until a person acts on $($held.Count) $(if ($held.Count -eq 1) { 'machine that waits' } else { 'machines that wait' }): $names"
    }

    # The FIRST wave is started by a person - Start, or its own start time.
    # Signing the plan off is consent for the run to carry on once it has
    # begun; it is not itself the moment the first machine stops.
    $begun = @($entries | Where-Object { (& $stateOf $_.vmId) -notin @('PLANNED', 'SKIPPED') })
    if (-not $begun.Count) {
        return & $none 'notStarted' 'the first wave starts when somebody starts it, or at its start time'
    }

    $order = @(Get-VmfPlanWaveOrder -Plan $Plan)
    $previous = $null
    foreach ($w in $order) {
        $mine = @($entries | Where-Object { [string]$_.wave -eq $w })
        $notStarted = @($mine | Where-Object { (& $stateOf $_.vmId) -eq 'PLANNED' })
        if (-not $notStarted.Count) { $previous = $w; continue }
        if ($w -in $ScheduledWaves) {
            return [pscustomobject]@{ Wave = $null; Reason = 'scheduled'; After = $previous; Throttle = $null
                Detail = "wave $w has a start time, so it waits for that time" }
        }
        # MACHINES-AT-ONCE-RANGE-1: the wave's number by the one rule.
        return [pscustomobject]@{
            Wave = $w; Reason = 'start'; After = $previous
            Throttle = (Get-VmfWaveThrottle -Entries $mine)
            Detail = $(if ($previous) { "wave $previous finished, so wave $w starts" } else { "wave $w is the first wave of the signed-off plan" })
        }
    }
    & $none 'done' 'every wave of the plan has run'
}

function Get-VmfPlanRunDecision {
    <#
    .SYNOPSIS
        Get-VmfNextPlanWave, fed from the store, with the engine's own start
        gates checked for the wave it names.
    .DESCRIPTION
        The facade's timer calls this every pass. A wave it would start and the
        engine would then refuse - settings not accepted, the estate not
        acknowledged - is reported here as `gate` rather than started, because
        starting a container every five minutes to be refused is noise in the
        run log and a bill.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$PlanPath)

    $planText = Read-VmfTextDocument -Path $PlanPath
    if (-not $planText) {
        return [pscustomobject]@{ Wave = $null; Reason = 'notSigned'; Detail = 'there is no plan'; After = $null; Throttle = $null }
    }
    $plan = $planText | ConvertFrom-Json -Depth 24
    # WAVE-APPROVE-1: the CONSENT to run on, not a gate - the wave it names is
    # still asked every start gate below, its own approval included.
    $signed = Test-VmfPlanRunConsent -RunPath $RunPath -PlanText $planText
    # FACADE-TIMER-QUEUE-1: Get-VmfNextPlanWave answers notSigned and halted
    # before it looks at a machine, so those answers are given before the
    # machine records are read. The timer asks this of every run every five
    # minutes, and most runs are not signed off.
    if (-not $signed.Pass) { return (Get-VmfNextPlanWave -Plan $plan -States @{} -SignedOff $false -Halted $false) }
    if (Test-VmfWaveHalted -RunPath $RunPath) { return (Get-VmfNextPlanWave -Plan $plan -States @{} -SignedOff $true -Halted $true) }
    $states = @{}
    $settled = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json')) {
        $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$name"
        if ($doc -and $doc.vmId) {
            $states[[string]$doc.vmId] = [string]$doc.state
            # RESTORED-HOLD-1: the one rule for "a restore ended the stop".
            if ((Get-VmfMachineOutcome -StateDoc $doc) -eq 'putBack') { $settled.Add([string]$doc.vmId) }
        }
    }
    $scheduled = @(Get-VmfWaveSchedule -RunPath $RunPath | ForEach-Object { [string]$_.wave } | Where-Object { $_ })
    $d = Get-VmfNextPlanWave -Plan $plan -States $states -SignedOff $true -Halted $false -ScheduledWaves $scheduled -Settled @($settled)
    if (-not $d.Wave) { return $d }

    $gate = Get-VmfWaveStartGate -RunPath $RunPath -PlanPath $PlanPath -Plan $plan -Wave $d.Wave
    # WAVE-APPROVE-1: a start nobody presses, on a sign-off of an earlier plan
    # version, needs the wave's own approval to be current - even for a wave
    # set not to need one when a person starts it. One rule with the
    # scheduled start (Get-VmfUnattendedStartRefusal).
    if (-not $gate) { $gate = Get-VmfUnattendedStartRefusal -RunPath $RunPath -PlanText $planText -Wave $d.Wave -Consent $signed }
    if ($gate) {
        # GATE-WORDS-1: the migration's page shows this line under the wave.
        # GateWave and GateCode: the timer logs a refusal for changed settings,
        # so the page offers Review & accept options, which the line names.
        return [pscustomobject]@{ Wave = $null; Reason = 'gate'; After = $d.After; Throttle = $null
            GateWave = $d.Wave; GateCode = [string]$gate.Code
            Detail = "$(Get-VmfStartGateLine -Name waveWaits -Wave $d.Wave) $($gate.Detail)" }
    }
    # WAVE-APPROVE-1 (review 4): the version of the wave these checks judged.
    # The timer hands it to the engine, and Start-VmfWave refuses a start whose
    # own read of the wave differs - the mechanism its workers already use.
    $d | Add-Member -NotePropertyName WaveVersion -NotePropertyValue (Get-VmfWaveVersion -PlanText $planText -Wave $d.Wave) -Force
    $d
}

function Get-VmfWaveStartGate {
    <#
    .SYNOPSIS
        The first of the engine's start gates this wave would fail, or $null.
    .DESCRIPTION
        RESUME-GATE-1: one list, used by everything that starts a wave on its
        own - the next wave of a signed-off plan, and the timer that restarts a
        stalled wave. The restart asked none of them, so a wave the engine
        refused was restarted every five minutes and refused every time: twelve
        containers an hour on the first end-to-end run, for nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave
    )
    # ACCEPT-SET-1: the same entries the acceptance and the wave start hash.
    $entries = @(Get-VmfWaveOptionsEntries -Plan $Plan -Wave $Wave)
    foreach ($gate in @(
        (Test-VmfRunAcknowledged -RunPath $RunPath),
        (Test-VmfWaveOptionsAccepted -RunPath $RunPath -Entries $entries -Wave $Wave),
        (Test-VmfWaveApproval -RunPath $RunPath -PlanPath $PlanPath -Wave $Wave))) {
        if (-not $gate.Pass) { return $gate }
    }
    $null
}

function Write-VmfOptionsChangedRefusal {
    <#
    .SYNOPSIS
        DECIDE-KEEP-1 / RESUME-GATE-1: say, once, that a wave was refused
        because its settings changed after they were accepted - the line the
        run page reads to offer the acceptance again.
    .DESCRIPTION
        Once: a refusal is written only if the wave's latest acceptance line is
        not already one. A new acceptance writes an "ok" line, so the next
        refusal after it is written again. Without this the page would get a
        line every five minutes, and a restart that no longer starts the engine
        would write none, leaving the page offering no way out.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$Wave, [Parameter(Mandatory)][string]$Detail)
    $last = @(Read-VmfEvents -RunPath $RunPath -Step 'acceptance' | Where-Object {
            ($_.PSObject.Properties['wave'] -and [string]$_.wave -eq $Wave) -or [string]$_.detail -match "wave '$([regex]::Escape($Wave))'" }) |
        Select-Object -Last 1
    if ($last -and [string]$last.outcome -eq 'refused') { return $false }
    # STEP-LOG-2: a decision's retry writes this after it saved the plan, and a
    # line that could not be written replaced the refusal the person must read.
    # A line that is lost is written at the next refusal: "once" reads the run
    # history, which then has no refusal.
    # Returns whether the line was written.
    $lost = $null
    Write-VmfStepLine -RunPath $RunPath -Step 'acceptance' -Outcome refused -Detail $Detail -Data @{ wave = $Wave; code = 'optionsChanged' } -WarningVariable lost
    -not $lost
}
function Set-VmfPlanRunStatus {
    <#
    .SYNOPSIS
        Record what the signed-off plan is doing next (plan-run.json), and add
        a line to the run log only when that CHANGED.
    .DESCRIPTION
        The timer decides every five minutes. A held run would otherwise log
        "the run holds" twelve times an hour, which buries the one line that
        matters. A plan nobody signed off records nothing - that is every run
        made before PLANRUN-1, and there is nothing to say about it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Decision,
        [Parameter()][string]$Execution
    )
    if ($Decision.Reason -eq 'notSigned') { return $false }
    $last = Read-VmfStoreJson -RunPath $RunPath -RelPath 'plan-run.json' -Depth 4
    $started = $Decision.Reason -eq 'start'
    if (-not $started -and $last -and [string]$last.reason -eq $Decision.Reason -and [string]$last.detail -eq $Decision.Detail) {
        return $false
    }
    $doc = [ordered]@{
        schemaVersion = 1
        reason        = [string]$Decision.Reason
        detail        = [string]$Decision.Detail
        wave          = $(if ($started) { [string]$Decision.Wave } else { $null })
        execution     = $(if ($Execution) { $Execution } else { $null })
        updatedUtc    = (Get-Date).ToUniversalTime().ToString('o')
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath 'plan-run.json' -Document $doc -Depth 4
    # STEP-LOG-2: written after the record, and for a start after the engine
    # job started. A line that cannot be written must not report that start as
    # failed.
    Write-VmfStepLine -RunPath $RunPath -Step 'planrun' -Outcome $(if ($started) { 'ok' } else { 'info' }) -Detail ([string]$Decision.Detail)
    $true
}