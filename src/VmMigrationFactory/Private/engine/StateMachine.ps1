# Per-VM state machine (architecture section 7). One invocation drives one VM from its
# current persisted state to a terminal state. Every step is idempotent and
# checkpointed; a killed worker resumes by simply re-invoking the machine.
#
# Terminal states: MIGRATED, NEEDS_DECISION, FAILED_ROLLED_BACK,
#                  FAILED_NEEDS_ATTENTION, SKIPPED

# EVAL-L2/M15: the engine's state vocabulary, declared ONCE. Three places had
# each grown their own copy of it: the vm-state schema's enum (which never
# gained SAFETY_PRISTINE, so a machine taking its pristine copy wrote a
# document its own contract rejects), and two lifecycle guards plus the
# dashboard, which all tested for a state called QUEUED that nothing has ever
# written - the real first state is PLANNED. Because PLANNED is not QUEUED,
# every merely-planned machine read as "started", so a run that had never run
# reported itself as under way AND refused to be discarded as though a machine
# were mid-conversion. That is exactly the stuck run a lab user could not clear.
$script:VmfWorkingStates = @('PLANNED', 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP',
                             'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING')
$script:VmfTerminalStates = @('MIGRATED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'SKIPPED')

# The state a machine is in before anything has been attempted on it. Named,
# because comparing against a literal is how the QUEUED copies drifted.
$script:VmfNotStartedState = 'PLANNED'

function Get-VmfEngineStates {
    <#
    .SYNOPSIS
        Every state a state document may record, and which kind each is.
    .DESCRIPTION
        The single source the schema enum, the lifecycle guards and the tests
        all read, so a state added to the machine cannot be missing from any
        of them without a test failing.
    .OUTPUTS
        @{ Working = @(...); Terminal = @(...); All = @(...); NotStarted = 'PLANNED' }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    @{
        Working    = @($script:VmfWorkingStates)
        Terminal   = @($script:VmfTerminalStates)
        All        = @($script:VmfWorkingStates) + @($script:VmfTerminalStates)
        NotStarted = $script:VmfNotStartedState
    }
}

# REACH-1: the states that mean a machine wants nothing further. Anything
# else - parked on a decision, rolled back awaiting a retry, needing a person -
# is unfinished business, and unfinished business still needs the capacity
# guarantee that was bought for it.
$script:VmfSettledStates = @('MIGRATED', 'SKIPPED')

function Test-VmfWaveFinished {
    <#
    .SYNOPSIS
        REACH-1: is this wave finished, in the sense that nothing in it will
        need capacity again?
    .DESCRIPTION
        Pure - it reads state counts and returns a verdict, so the close-out
        decision is testable without Azure, a store or a container.

        This is deliberately stricter than "the wave stopped running". A wave
        can settle with machines parked on a decision or rolled back for a
        retry; those machines still intend to migrate, and releasing their
        reservation hands scarce capacity to somebody else and leaves the
        retry to chance.
    .OUTPUTS
        @{ Finished = <bool>; Unfinished = @(<state>...); Reason = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$StateCounts,
        [Parameter()][bool]$Halted
    )
    if ($Halted) {
        return @{ Finished = $false; Unfinished = @()
                  Reason = 'the wave was halted, so the machines in it have not finished' }
    }
    $unfinished = @()
    if ($StateCounts) {
        foreach ($prop in @($StateCounts.PSObject.Properties)) {
            if ([int]$prop.Value -le 0) { continue }
            if ($prop.Name -in $script:VmfSettledStates) { continue }
            $unfinished += "$($prop.Value) $($prop.Name)"
        }
    }
    if ($unfinished.Count -gt 0) {
        return @{ Finished = $false; Unfinished = $unfinished
                  Reason = "the wave still has $($unfinished -join ', ')" }
    }
    @{ Finished = $true; Unfinished = @(); Reason = 'every machine in the wave reached a settled state' }
}

# EVAL-M4: named so the guard, the message and the test all quote one number.
$script:VmfStateLoopLimit = 50
$script:VmfMaxAttempts = @{
    PRECHECK = 2; SAFETY_PRISTINE = 2; GUEST_PREP = 2; SAFETY_COPY = 2; STOPPED = 2
    CONVERTING = 1; STARTING = 1; VALIDATING = 2
}# AN-AMDV7-VF-GAP-1 (2026-11-06): how long VALIDATING waits for the
# accelerated networking adapter when the first read finds none - a read every
# IntervalSeconds, for up to WaitMinutes, then the step fails. Measured on AMD
# Standard_D2as_v7: the virtual function was late on 9 of 20 starts, up to 435
# seconds, and always arrived. Read only through Get-VmfAnAdapterWaitSettings.
$script:VmfAnAdapterWait = @{ IntervalSeconds = 30; WaitMinutes = 15 }

function Get-VmfMoveKind {
    <#
    .SYNOPSIS
        GEN-V5-1: which kind of move a plan entry is.
    .DESCRIPTION
        nvme-conversion  the target controller is NVMe (v6, v7)
        scsi-resize      a SCSI move onto a v5 size - a plain resize, but onto
                         hardware that can require accelerated networking and
                         can give MANA. BSV2-TARGET-1: and onto a Bsv2 size,
                         offered on v5 because its facts are the v5 facts
                         (SCSI, Generation 1 and 2, MANA among its interfaces).
                         Read as a reversion, a Bsv2 move would skip the guest
                         preparation - the MANA driver check, and the page file
                         of a Windows machine whose temporary disk goes away -
                         and would set a disk controller a Generation 1
                         machine cannot take.
        scsi-reversion   any other SCSI target (the SCSI-direction drill: a v6
                         size kept on SCSI) - no preparation, nothing changed
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$PlanEntry)

    if ([string]$PlanEntry.target.controller -eq 'NVMe') { return 'nvme-conversion' }
    if ((Get-VmfSizeGeneration -SizeName ([string]$PlanEntry.target.size)) -eq 'v5') { return 'scsi-resize' }
    $burstable = Get-VmfBurstableTarget -SizeName ([string]$PlanEntry.target.size)
    if ($burstable -and [string]$burstable.option -eq 'v5') { return 'scsi-resize' }
    'scsi-reversion'
}

function Get-VmfPolicy {
    # Resolve a policy value with engine defaults.
    param([Parameter(Mandatory)]$PlanEntry, [Parameter(Mandatory)][string]$Name)
    # WAVE-SAVE-FALSE-1 (issue 424): the wave defaults come from the ONE set a
    # new plan is written with (Get-VmfDefaultWavePolicy - onDDataFound,
    # onDriverBelowFloor, keepSnapshotDays, capacityGate, safetyCopy pristine,
    # requireApproval, throttle). This table was a second copy of five of them
    # and lacked the other two, so the wave editor's save could not ask "what
    # does an absent value mean" in one place, and called every wave changed.
    # FAIL-1 removed `bootFailure` and `validationFailure`: a failed machine
    # always goes back, so there was nothing left for them to choose.
    $defaults = Get-VmfDefaultWavePolicy
    # MANUAL-REVIEW-1: bootableClone is gone. No page wrote it, and its only
    # reader parked the machine with a stop for a feature that was never built.
    # REBUILD-REMOVE-ENGINE-1: onSystemAssignedIdentity is gone with its last
    # reader (the check after an accepted rebuild). No move deletes an identity.
    # AN-1: MANA requires AN on the NIC; default to enforcing it for NVMe
    # targets. SCSI reversions preserve whatever the capture recorded.
    $defaults.acceleratedNetworking = $null   # resolved dynamically below
    # SIGNOFF-NULL-1: the sign-off has ONE reading (Test-VmfApprovalRequired).
    # A stored null fell to the default here and a stored 0 came back as
    # itself, which a caller then read as "off" - while the gate read both
    # another way.
    if ($Name -eq 'requireApproval') { return (Test-VmfApprovalRequired -PlanEntry $PlanEntry) }
    if ($Name -eq 'acceleratedNetworking') {
        $val = if ($PlanEntry.policy -and $PlanEntry.policy.PSObject.Properties[$Name]) { $PlanEntry.policy.$Name } else { $null }
        if ($null -ne $val) { return $val }
        # GEN-V5-1: a v5 move follows the same rule as v6 and v7.
        return $(if ((Get-VmfMoveKind -PlanEntry $PlanEntry) -ne 'scsi-reversion') { 'ensureOn' } else { 'preserve' })
    }
    $val = if ($PlanEntry.policy -and $PlanEntry.policy.PSObject.Properties[$Name]) { $PlanEntry.policy.$Name } else { $null }
    if ($null -eq $val) { $defaults[$Name] } else { $val }
}

function New-VmfContext {
    # Build the per-VM execution context handed to every step handler.
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][string]$WorkerId = 'inline'
    )
    $parts = $PlanEntry.vmId.Trim('/') -split '/'
    @{
        Plan     = $PlanEntry
        RunPath  = $RunPath
        RunId    = $RunId
        WorkerId = $WorkerId
        VmId     = $PlanEntry.vmId
        VmName   = $parts[-1]
        Rg       = $parts[[array]::IndexOf($parts, 'resourceGroups') + 1]
        # ENGINE-SUB-1: the subscription was parsed out of the vmId and then
        # THROWN AWAY here, and every azureops call addresses a machine by
        # resource group and name against whatever subscription the engine
        # happens to be signed in to. Discovery accepts several subscriptions
        # or a whole management group, so a plan can legitimately span them -
        # and 'rg-app01/web01' existing in two subscriptions is an ordinary
        # enterprise shape, not an exotic one. Kept now, and checked at
        # PRECHECK before anything is touched.
        SubscriptionId = $(if ($PlanEntry.vmId -match '(?i)/subscriptions/([0-9a-f-]{36})(/|$)') { $Matches[1] } else { $null })
    }
}

function Test-VmfWaveSubscriptions {
    <#
    .SYNOPSIS
        ENGINE-SUB-1: can this engine act on every machine in the wave?
    .DESCRIPTION
        Pure apart from one context read, so the judgement is testable. The
        engine addresses a machine by resource group and name - unique only
        WITHIN a subscription - while discovery accepts several subscriptions
        or a whole management group, so a plan can legitimately span them.

        Since ENGINE-SUB-1 was fixed a wave may legitimately SPAN subscriptions -
        each machine points the process at its own for the duration of its run.
        So what this checks is no longer "do they all match ours" but "can we
        reach every one of them", asked once, before anything starts. Finding
        out per machine would mean finding out after some of the wave had
        already moved.
    .OUTPUTS
        @{ Pass = <bool>; Detail = <string>; Subscriptions = @(<id>) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Entries,
        # Injectable so the judgement can be tested without Azure. Given one
        # subscription id, it must succeed if the product can reach it and throw
        # if it cannot.
        [Parameter()][scriptblock]$Reach = { param($s) Use-VmfSubscriptionContext -SubscriptionId $s }
    )

    $ids = @(@($Entries) | Where-Object { $_ } | ForEach-Object {
        if ([string]$_.vmId -match '(?i)/subscriptions/([0-9a-f-]{36})(/|$)') { $Matches[1] } else { $null }
    })
    $unknown = @($ids | Where-Object { -not $_ }).Count
    $known = @($ids | Where-Object { $_ } | Sort-Object -Unique)

    if ($unknown -gt 0) {
        return @{ Pass = $false; Subscriptions = $known
                  Detail = "$unknown $(if ($unknown -eq 1) { 'machine in this wave has' } else { 'machines in this wave have' }) a resource id that does not say which subscription they are in, so there is no way to be sure the right machines would be acted on. Re-run the assessment." }
    }
    if ($known.Count -eq 0) {
        return @{ Pass = $false; Subscriptions = @(); Detail = 'this wave has no machines with a usable resource id' }
    }

    # ENGINE-SUB-1, FIXED: a wave MAY now span subscriptions. Each machine
    # points the process at its own subscription for the duration of its run,
    # so "which subscription is the product signed in to" is no longer the
    # question. The question is whether every subscription in the wave can
    # actually be REACHED - because a machine we cannot reach is one we would
    # either fail on late or, before this, address in the wrong place.
    #
    # Checked here, once, before anything starts: finding out per machine means
    # finding out after some of the wave has already moved.
    $unreachable = [System.Collections.Generic.List[string]]::new()
    foreach ($sub in $known) {
        try { $null = & $Reach $sub }
        catch { $unreachable.Add("$sub ($($_.Exception.Message))") }
    }
    if ($unreachable.Count -gt 0) {
        return @{ Pass = $false; Subscriptions = $known
                  Detail = ("The product cannot reach $($unreachable.Count) of the $($known.Count) $(if ($known.Count -eq 1) { 'subscription' } else { 'subscriptions' }) that this wave covers: " +
                            ($unreachable -join '; ') + ". Give it access there, or move those machines to a wave it can run.") }
    }
    @{ Pass = $true; Subscriptions = $known
       Detail = "every machine is in a subscription the product can reach ($($known.Count): $($known -join ', '))" }
}

function Get-VmfStateMutates {
    <#
    .SYNOPSIS
        EVAL-H4/M1: does this state change the machine before it can fail?
    .DESCRIPTION
        machineState is the one field the design says an operator cannot be
        told wrongly - the dashboard renders it as "Nothing on this machine was
        changed". It was ASSIGNED BY ASSUMPTION: an else-branch stamped
        'untouched' on every non-rollback stop, and three paths were wrong.

        SAFETY_PRISTINE deallocates BEFORE it snapshots. SAFETY_COPY runs on a
        machine STOPPED has already deallocated and never starts it. GUEST_PREP
        rewrites the boot path - fstab, GRUB and the initramfs on Linux, the
        boot-driver registry across every ControlSet on Windows - and the fixer
        scripts decide their verdict at the END, after every mutation has run,
        so a BLOCKED result means "changed, then failed".
    .OUTPUTS
        'no'      - cannot have changed anything
        'power'   - may have left the machine stopped
        'guest'   - may have changed the machine itself
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$State)

    switch ($State) {
        'PLANNED'         { 'no' }
        'PRECHECK'        { 'no' }
        'SAFETY_PRISTINE' { 'power' }
        'STOPPED'         { 'power' }
        'SAFETY_COPY'     { 'power' }
        'GUEST_PREP'      { 'guest' }
        default           { 'guest' }
    }
}

function Get-VmfStateLeftMachineState {
    <#
    .SYNOPSIS
        EVAL-M1, STOP-MIDMOVE-FREED-1: where a stop at this state leaves the
        machine, when nothing else said - 'untouched' or 'changed'.
    .DESCRIPTION
        The rule a handler stop is stamped with when the handler names no
        machine state: a state that cannot change anything (Get-VmfStateMutates
        'no') is untouched; GUEST_PREP asks the audit trail of this attempt
        (Test-VmfGuestChangedThisAttempt); every other state is changed.
        Stop-VmfRun asks the same rule for a machine it closes part way
        through its move, so its claim is kept while the record says changed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter()][AllowNull()]$Doc
    )
    if ((Get-VmfStateMutates -State $State) -eq 'no') { return 'untouched' }
    # PREP-ROLLBACK-1 (review F7): the audit trail of this attempt says, since
    # every changing script has an entry from before it ran (review F3).
    if ($State -eq 'GUEST_PREP') {
        if (Test-VmfGuestChangedThisAttempt -Doc $Doc) { return 'changed' }
        return 'untouched'
    }
    'changed'
}

function Resolve-VmfStoppedMachineState {
    <#
    .SYNOPSIS
        EVAL-H4: a state that may have left the machine powered off must SAY
        which, and the only honest way to know is to try starting it.
    .DESCRIPTION
        Any snapshot failure that survived its attempts used to park a
        production machine powered off and tell the operator, in plain English,
        that nothing had been changed - in an overnight wave, it stays down
        until somebody notices it is unreachable. No dashboard page shows power
        state at all.
        -AsFound (STOP-POWER-AS-FOUND-1): the stop changed nothing, so the
        machine goes back to the power state Checking found when it started
        the machine (Restore-VmfPowerAsFound) - deallocated or stopped. Only
        running, or no record, starts it. POWER-AFTER-MOVE-1: a rollback whose
        start failed, or that failed, uses it too, so the machine ends in the
        power state Checking found.
    .OUTPUTS
        @{ MachineState = 'restored'|'changed'; Detail = <string>;
           PowerNotPutBack = the power state found, when only its put-back was
           refused (POWER-ONLY-CHANGED-1) }
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter()][switch]$AsFound)

    if ($AsFound) {
        $back = Restore-VmfPowerAsFound -Context $Context
        # POWER-ONLY-CHANGED-1: a refused put-back names the power state found.
        if ($back) { return @{ MachineState = $(if ($back.Ok) { 'restored' } else { 'changed' }); Detail = $back.Detail; PowerNotPutBack = $back.PowerNotPutBack } }
        # POWER-ONLY-CHANGED-1 (2026-11-06, the other direction): a
        # machine found running that this step stopped is started again with
        # the same tries; still refused, the stop names the power state
        # running, so its retry is not held for this alone.
        $start = Restore-VmfPowerAsFound -Context $Context -Power 'PowerState/running'
        if ($start.Ok) { return @{ MachineState = 'restored'; Detail = 'the machine was stopped by this step and has been started again' } }
        return @{ MachineState = 'changed'; Detail = $start.Detail; PowerNotPutBack = 'PowerState/running' }
    }
    try {
        Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
        return @{ MachineState = 'restored'; Detail = 'the machine was stopped by this step and has been started again' }
    }
    catch {
        return @{
            MachineState = 'changed'
            Detail = "the machine is stopped, and Azure did not start it again ($($_.Exception.Message)). The machine does not run until a person starts it"
        }
    }
}

function Test-VmfPrepRollbackWanted {
    <#
    .SYNOPSIS
        PREP-ROLLBACK-1: does this stop, before the move, put the machine back?
        Pure, apart from reading the audit trail it is given.
    .DESCRIPTION
        Since 2026-10-05 a failure in the preparation rolls the machine back.
        A move is one change window (ONE-WINDOW-1): once the product has
        changed a machine, a stop puts it back at once. CONVERTING, STARTING
        and VALIDATING always did; nothing before them did.

        GUEST_PREP, a stop the step returns: when it is recorded as changed.
        The engine judges that from the audit trail of this attempt
        (Get-VmfGuestChangeThisAttempt), unless the step says it itself - a
        MANA install that added files says changed.
        GUEST_PREP that threw at each attempt, STOPPED and SAFETY_COPY: only
        when the audit trail says a script changed the guest, or may have, in
        this attempt. Review F7: "every throw counts" rolled back machines
        nothing had changed; since review F3 a changing script that never
        answered leaves a STARTED entry, so the audit trail is complete.
        Nothing earlier: PRECHECK and SAFETY_PRISTINE run before any script
        changes the guest.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$State,
        [Parameter()][string]$Next,
        [Parameter()][string]$MachineState,
        [Parameter()][switch]$Exhausted,
        [Parameter()][AllowNull()]$Doc
    )
    switch ($State) {
        'GUEST_PREP' {
            if ($Exhausted) { return (Test-VmfGuestChangedThisAttempt -Doc $Doc) }
            # Review 2, finding 6: a park for a decision too - on a second visit
            # (STOPPED sends a machine back to prepare again) it can come after a
            # fix that changed the guest.
            return ($Next -in @('FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION') -and $MachineState -eq 'changed')
        }
        { $_ -in @('STOPPED', 'SAFETY_COPY') } {
            return ([bool]$Exhausted -and (Test-VmfGuestChangedThisAttempt -Doc $Doc))
        }
    }
    $false
}

function Set-VmfRollbackPending {
    <#
    .SYNOPSIS
        PREP-ROLLBACK-1 (review F2): the checkpoint of a rollback, written
        BEFORE its first change.
    .DESCRIPTION
        A worker that stopped in the middle of a rollback used to resume the
        step that FAILED: reproduced, a machine went STOPPED, SAFETY_COPY,
        CONVERTING and was resized again while half rolled back. Now the loop
        finds this record first and finishes the rollback (Complete-VmfRollback);
        the stop that ends it removes the record in the same write. Every
        automatic rollback writes it: before the move (kind disks), the kernel
        update's put-back, and FAIL-1 after the move (kind full).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('disks', 'full')][string]$Kind,
        [Parameter(Mandatory)][string]$State,
        [Parameter()][string]$ReasonCode,
        [Parameter()][string]$Detail,
        [Parameter()][string]$EvidenceRef,
        [Parameter()][ValidateSet('changed', 'mayHaveChanged')][string]$Change = 'changed',
        [Parameter()][ValidateSet('FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION')][string]$StopState = 'FAILED_ROLLED_BACK'
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $marker = [ordered]@{
        kind        = $Kind
        state       = $State
        reasonCode  = $(if ($ReasonCode) { $ReasonCode } else { 'rolledBack' })
        detail      = [string]$Detail
        evidenceRef = $(if ($EvidenceRef) { $EvidenceRef } else { $null })
        stopState   = $StopState
        startedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        done        = $false
    }
    if ($Kind -eq 'disks') { $marker.change = $Change }
    $doc | Add-Member -NotePropertyName rollbackPending -NotePropertyValue $marker -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
}

function Get-VmfRollbackEmptyLuns {
    <#
    .SYNOPSIS
        SWAP-2UPD-1 for the rollback (review F1): the data disks this attempt
        found whose LUN has no disk now. A read that fails is no answer, and
        returns none - the caller also reads Azure's own words.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)]$Context, [Parameter()][AllowNull()]$Doc)
    $had = @(@($Doc.captured.vmConfig.dataDisks) | Where-Object { $_ -and [string]$_.managedDiskId } | ForEach-Object {
        [pscustomobject]@{ lun = [int]$_.lun; id = [string]$_.managedDiskId; name = [string]$_.name } })
    if (-not $had.Count) { return @() }
    try { @(Get-VmfEmptyDataLuns -RunPath $Context.RunPath -VmId $Context.VmId -ResourceGroupName $Context.Rg -VmName $Context.VmName -Before $had) }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        @()
    }
}

function Complete-VmfRollback {
    <#
    .SYNOPSIS
        PREP-ROLLBACK-1 (review F2): run the rollback the checkpoint names, and
        record the stop that ends it - in the same write that removes the
        checkpoint. Safe to run again: a rollback marked done only records.
    .DESCRIPTION
        The reason code stays the cause, and the machine state says where the
        machine was left. A rollback that fails:
          kind full    rollbackFailed, the machine left as it is (FAIL-1). A
                       disk not made from its copy stops it before any
                       change (ROLLBACK-DISKS-FIRST-1), and the words say so.
          kind disks, before any disk changed (review F5) - the rollback's own
                       stop failed, most often the same stop that just failed:
                       the cause stays the reason, the machine is changed and
                       is started again; Restore puts it back.
          kind disks, after a disk changed: rollbackFailed. Never started with
                       a data-disk LUN that may be empty (review F1, as
                       Restore-VmfVm) - a Linux mount with no nofail stops the
                       boot. Otherwise started again.
        -Resumed (ROLLBACK-DISKS-FIRST-1 review): a worker finishes a rollback
        another worker started. That worker may have stopped the machine,
        set the size back or swapped a disk before it stopped, so a failure
        now is never said as "before it changed the machine" or "before it
        changed a disk" - those words are true only on the first run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Context, [Parameter()][double]$DurationSec = 0, [Parameter()][switch]$Resumed)

    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $pending = $doc.rollbackPending
    $field = { param($n) if ($pending.PSObject.Properties[$n]) { $pending.$n } else { $null } }
    $guest = [string](& $field 'kind') -eq 'disks'
    $state = [string](& $field 'state')
    # MANUAL-REVIEW-1: the stop names the step as the pages show it.
    $stepWord = Get-VmfStepWord -State $state
    $why = [string](& $field 'detail')
    $code = [string](& $field 'reasonCode')
    $okState = if ([string](& $field 'stopState')) { [string](& $field 'stopState') } else { 'FAILED_ROLLED_BACK' }
    # Review F7: "changed" only when a script said it changed something.
    $changeWords = if ([string](& $field 'change') -eq 'mayHaveChanged') { 'may have changed' } else { 'changed' }
    $end = @{ RunPath = $Context.RunPath; VmId = $Context.VmId; Outcome = 'fail'; DurationSec = $DurationSec; ClearProperty = @('rollbackPending') }
    if ([string](& $field 'evidenceRef')) { $end.EvidenceRef = [string](& $field 'evidenceRef') }

    # Review 2, finding 7: only the rollback is inside this try - a store write
    # after a rollback that worked must never read as a failed rollback.
    $failure = $null
    $powerNote = ''
    $machineAfter = 'restored'
    # POWER-AFTER-MOVE-1: the power state to name on the stop, when Azure
    # refused its return at every try.
    $powerLeft = @{}
    $powerDone = $false
    try {
        if (-not (& $field 'done')) { Invoke-VmfRollback -Context $Context -GuestOnly:$guest -Resumed:$Resumed }
        else {
            # Marked done before the retry state was cleared: clear it now.
            # Safe to repeat.
            Clear-VmfRetryState -RunPath $Context.RunPath -VmId $Context.VmId -From 'PRECHECK'
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        if ($_.Exception.Data['vmfRollbackStartOnly']) {
            # Every disk is back; only the start failed. That is a machine as
            # it was, switched off - not a failed rollback (EVAL-H4: try the
            # start again, and say where the power is).
            # POWER-AFTER-MOVE-1: to the power state Checking found - a
            # machine found deallocated is not started again only to be
            # deallocated (Resolve-VmfStoppedMachineState -AsFound).
            $restore = Resolve-VmfStoppedMachineState -Context $Context -AsFound
            $machineAfter = $restore.MachineState
            if ($machineAfter -eq 'changed' -and $restore.PowerNotPutBack) { $powerLeft.PowerNotPutBack = $restore.PowerNotPutBack }
            $powerDone = $true
            $powerNote = " The start after the rollback failed ($($_.Exception.Message)) - $($restore.Detail)."
            # ROLLBACK-CAPACITY-1: Azure had no capacity for the original size at
            # any try. Its own reason, and words that say where every disk and
            # the machine are. A machine found running stays changed in its
            # power state only, so its retry starts it first (POWER-ONLY-CHANGED-1).
            $noCapacitySize = [string]$_.Exception.Data['vmfRollbackNoCapacity']
            # Found running, and the start of the return above worked: Azure had
            # capacity again, the machine runs, and this is no such stop.
            $foundOff = Get-VmfPowerAsFound -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
            if ($noCapacitySize -and $machineAfter -eq 'restored' -and -not $foundOff) { $noCapacitySize = '' }
            if ($noCapacitySize) {
                $noCapacityStop = @{ Reason = 'rollbackNoCapacity'; State = 'FAILED_ROLLED_BACK' }
                $code = $noCapacityStop.Reason
                $okState = $noCapacityStop.State
                $powerNote = " $($_.Exception.Message) $(Get-VmfRollbackNoCapacityWords -Size $noCapacitySize)"
                # Found deallocated or stopped and returned to it: said too.
                if ($machineAfter -eq 'restored' -and $restore.Detail) { $powerNote += " $($restore.Detail)." }
            }
        }
        else { $failure = $_ }
    }

    # SWAP-REFUSED-AFTER-STOP-1 (review MUST FIX 2): a data disk swap this
    # rollback left is on record before anything after the swaps can fail. So
    # with that record, a rollback that failed afterwards - marking itself
    # done, clearing the retry state, the kernel record - is still a machine
    # stopped with disks left: it is never started here, and its stop is
    # recorded, so Finish the rollback can end it (it does what failed).
    $leftOnRecord = Get-VmfSwapPending -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
    $leftIsOurs = [bool]($leftOnRecord -and [string]$leftOnRecord.kind -eq 'rollback')
    # Re-review: Azure did not swap a data disk back, and the record of it
    # could not be written or read back. The machine is stopped; it is never
    # started here, and the stop says what is left and why there is no record.
    # Re-check: whatever part of the record a first write left (a later batch
    # whose write failed), it does not hold every disk - so it is removed and
    # Finish the rollback is not offered: it would start the machine with the
    # rest on their old disks.
    if ($failure -and $failure.Exception.Data['vmfSwapLeftUnrecorded']) {
        if ($leftIsOurs) {
            try { Set-VmfSwapPending -RunPath $Context.RunPath -VmId $Context.VmId -Record $null }
            catch { Write-Warning "The partial record of the data disks that are left could not be removed: $($_.Exception.Message)" }
        }
        return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode 'dataDiskSwapRefused' -MachineState 'changed' `
            -Detail ("The $stepWord step failed, and the rollback did not finish. Azure did not swap these data disks back: $($failure.Exception.Data['vmfSwapLeftWords']). " +
                "The record of them could not be written ($($failure.Exception.Message)), so the machine is left stopped and $(Get-VmfFinishActionName -Kind 'rollback') cannot see them. " +
                "Attach each disk made from its copy to its LUN, then start the machine. Original error: $why")
    }
    if (-not $failure -or $leftIsOurs) {
        # MANA-LINUX-KERNEL-1: the put-back after a failed kernel update is
        # this rollback; the record says when, so GUEST_PREP never asks again.
        if (-not $failure) { Complete-VmfKernelUpdatePutBack -RunPath $Context.RunPath -VmId $Context.VmId }
        # SAFETY-ULTRA-1: a data disk not put back is said in the stop itself,
        # with why - never only in the activity.
        $rbNow = Get-VmfRecordField -Object (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId) -Name 'rollback'
        $notBack = @(@(Get-VmfRecordField -Object $rbNow -Name 'keptDataDisks') | Where-Object { $_ })
        $keptNote = if ($notBack.Count) {
            " The rollback did not restore these data disks, and each keeps the disk it had: $(@($notBack | ForEach-Object { "LUN $($_.lun) '$($_.name)': $($_.why)" }) -join ' ')"
        } else { '' }
        # ROLLBACK-CRG-1: and a capacity reservation group Azure did not put
        # the machine back in - said in the stop too.
        $crgMiss = Get-VmfRecordField -Object $rbNow -Name 'reservationGroupNotBack'
        if ($crgMiss -and [string]$crgMiss.groupId) {
            $keptNote += " $(Get-VmfReservationNotBackWords -GroupId ([string]$crgMiss.groupId) -Why ([string]$crgMiss.why))"
        }
        $crgOut = Get-VmfRecordField -Object $rbNow -Name 'reservationGroupLeft'
        if ($crgOut -and [string]$crgOut.groupId) { $keptNote += " $(Get-VmfReservationLeftWords -GroupId ([string]$crgOut.groupId))" }
        $detail = if ($guest) { "The $stepWord step failed after the preparation $changeWords the machine. The product rolled the machine back from the first safety copy: $why$powerNote$keptNote" }
                  else { "The $stepWord step failed, and the product rolled the machine back to how it was: $why$powerNote$keptNote" }
        # VOLUMES-ONLINE-1: the check inside the machine, before it returns to
        # the power state it was found in - and on the checkpoint, so a resume
        # after that return uses it (Get-VmfRollbackVolumesCheck). Not for a
        # machine left stopped with a data disk swap left: Finish the rollback
        # starts it.
        $volumes = $null
        if (-not $leftIsOurs) { $volumes = Get-VmfRollbackVolumesCheck -Context $Context }
        if ($volumes -and [string]$volumes.verdict -eq 'UNKNOWN') { $detail = "$detail $([string]$volumes.words)" }
        $powerWords = ''
        # SWAP-REFUSED-AFTER-STOP-1: Azure did not swap every data disk back,
        # so the machine is stopped and is not as it was. The stop this
        # rollback would have recorded is kept on the record: Finish the
        # rollback records it once the disks are back and the machine runs.
        # Asked on a resume too (the rollback marked done), so a worker that
        # stopped before this line never records "rolled back".
        $left = $leftOnRecord
        if ($leftIsOurs) {
            $left | Add-Member -NotePropertyName stop -Force -NotePropertyValue ([ordered]@{ state = $okState; reasonCode = $code; machineState = 'restored'; detail = $detail })
            Set-VmfSwapPending -RunPath $Context.RunPath -VmId $Context.VmId -Record $left
            $back = @(@($(if ($rbNow -and $rbNow.osDisk -and [string]$rbNow.osDisk.name) { "the OS disk '$($rbNow.osDisk.name)'" })) +
                @(@($left.swapped) | Where-Object { $_ } | ForEach-Object { "LUN $($_.lun) '$($_.diskName)'" }) | Where-Object { $_ })
            # ROLLBACK-EMPTY-LUN-1: each LUN said as what Azure reports on it
            # now - a LUN with no disk as no disk, never as the disk it had.
            $leftLive = (Get-VmfRollbackLiveLuns -Context $Context).Luns
            $leftDetail = "The $stepWord step failed, and the rollback did not finish. $(Format-VmfRollbackLeft -Swaps @($left.swaps) -Live $leftLive -AzureSaid ([string]$left.error))" +
                " The machine is left stopped, so it never starts with disks from two moments.$(if ($back.Count) { " Back from the first safety copy: $($back -join ', ')." })" +
                $(if ($failure) { " After the swaps, the rollback did not finish its record: $($failure.Exception.Message)." }) +
                " Use $(Get-VmfFinishActionName -Kind 'rollback') on this machine. It swaps only the disks that are left, then starts the machine. Original error: $why"
            return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -Detail $leftDetail -ReasonCode 'dataDiskSwapRefused' -MachineState 'changed'
        }
        # POWER-AFTER-MOVE-1 (2026-11-06: the original power state, on or off,
        # is kept when the work is done): the rollback started the machine
        # to put it back; now it goes to the power state Checking found, with
        # the tries of Invoke-VmfPowerPutBack. Found running, or no record:
        # nothing to do. A resume of a rollback marked done comes here again,
        # and a return to the power state the machine has does nothing.
        # Still refused, the stop names the power state owed.
        if (-not $powerDone) {
            $back = Restore-VmfPowerAsFound -Context $Context -OpName 'rollback:powerAsFound'
            if ($back) {
                $detail = "$detail $($back.Words)"
                $powerWords = " $($back.Words)"
                if ($back.Ok) { Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId -Detail $back.Words }
                else { $machineAfter = 'changed'; $powerLeft.PowerNotPutBack = $back.PowerNotPutBack }
            }
        }
        # VOLUMES-ONLINE-1: a volume that was mounted before the move and is
        # not mounted now is a machine NOT as it was - never "rolled back to
        # how it was" (the full-rollback rule). Changed: a new "as it was"
        # copy of it would be wrong.
        # VOLUMES-RETRY-CHECK-1: so the stop owes a check of the volumes, and
        # so does a check that could not run (unknown is never a pass) - in
        # the same write as the stop. A retry runs that check first
        # (Invoke-VmfVolumesCheckBeforeRetry); a check that found every volume
        # owes nothing.
        $owe = @{ Amend = { param($d) Set-VmfVolumesCheckOwed -Doc $d -Verdict ([string]$volumes.verdict) -Kind 'rollback' } }
        if (-not $volumes) { $owe = @{} }
        if ($volumes -and [string]$volumes.verdict -eq 'MISSING') {
            return Add-VmfStateTransition @end @owe -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode 'volumesNotBack' -MachineState 'changed' @powerLeft `
                -Detail "The $stepWord step failed, and the product rolled the machine back from the first safety copy, but not every volume is back. $([string]$volumes.words) Original error: $why$powerNote$keptNote$powerWords"
        }
        return Add-VmfStateTransition @end @owe -NewState $okState -Detail $detail -ReasonCode $code -MachineState $machineAfter @powerLeft
    }

    $fail = $failure.Exception.Message
    # ROLLBACK-POLICY-DENY-1: an Azure Policy refusal is said as the
    # assignment's name, never as Azure's policy JSON.
    $policyDenial = Get-VmfPolicyDenial -Message (Resolve-VmfOperationError -ErrorRecord $failure).Message
    if ($policyDenial) { $fail = Get-VmfPolicyDenialWords -Denial $policyDenial }
    # ROLLBACK-DISKS-FIRST-1 review: every disk this rollback made bills, and
    # most stops after the disks are made do not name them - so the stop
    # does. Every rollback disk's name ends with the time of its checkpoint.
    $failDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $madeStamp = Get-VmfRollbackStamp -Doc $failDoc
    $madeNames = @(@(Get-VmfRecordField -Object $failDoc -Name 'rollbackDisksDuringRollback') | Where-Object { $_ -and [string]$_.diskName -like "*-$madeStamp" } | ForEach-Object { "'$($_.diskName)'" })
    $madeNote = if ($madeNames.Count) { " The rollback made these disks from the first safety copy, and each is kept: $($madeNames -join ', ')." } else { '' }
    # The decision of 2026-10-11: and the rollback disks
    # before the move that are not on the machine - they bill too, and a
    # person who puts the machine back needs to know they are there.
    $preLeft = @(Get-VmfRollbackDisksBeforeMoveEntries -StateDoc $failDoc | Where-Object { $_.Attempt -eq 'current' -and -not [string]$_.usedUtc -and -not [string]$_.deletedUtc } | ForEach-Object { "'$($_.diskName)'" })
    if ($preLeft.Count) { $madeNote += " The rollback disks made before the move that are not on the machine are kept: $($preLeft -join ', ')." }
    if ($Resumed) {
        # Another worker may have changed the machine before it stopped.
        $failure.Exception.Data.Remove('vmfRollbackUntouched')
        $failure.Exception.Data.Remove('vmfRollbackNoDiskChanged')
    }
    # PREVIEW-PUTBACK-1: a rollback refused for a reason of its own (the
    # preview feature) is stopped with that reason, which says what to do.
    $rbCode = if ([string]$failure.Exception.Data['vmfRollbackReason']) { [string]$failure.Exception.Data['vmfRollbackReason'] } else { 'rollbackFailed' }
    if (-not $guest -and $failure.Exception.Data['vmfRollbackUntouched']) {
        # ROLLBACK-DISKS-FIRST-1: a disk the rollback could not make from its
        # copy, or one that differs, stopped it BEFORE it changed the machine.
        # Still a failed rollback - the move changed the machine - but the
        # words say that the rollback itself changed nothing.
        return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode $rbCode -MachineState 'changed' `
            -Detail "The $stepWord step failed, and the rollback stopped before it changed the machine: $fail The machine is as the failed step left it.$madeNote Original error: $why"
    }
    if (-not $guest -and [string]$failure.Exception.Data['vmfRollbackSizeRefused']) {
        # ROLLBACK-CAPACITY-1, case B: Azure refused the original size, before
        # any disk swap. The machine is stopped on the new size, on the disks
        # the move left - said as that, with its own reason.
        $newSize = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $failDoc.captured -Name 'startedTarget') -Name 'size')
        if (-not $newSize) { $newSize = [string]$Context.Plan.target.size }
        return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode 'rollbackSizeRefused' -MachineState 'changed' `
            -Detail (Get-VmfRollbackSizeRefusedWords -StepWord $stepWord -Size ([string]$failure.Exception.Data['vmfRollbackSizeRefused']) -NewSize $newSize -Why $why -Fail $fail -MadeNote $madeNote -PutBack @($failure.Exception.Data['vmfRollbackPutBack']) -PolicyDenial $policyDenial)
    }
    if (-not $guest) {
        # The one state that cannot claim "as it was". Its disks and the
        # untouched pristine copy both survive; recovery here is a
        # deliberate act, never a retry.
        return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode $rbCode -MachineState 'changed' `
            -Detail "The $stepWord step failed, and the rollback also failed: $fail$madeNote Original error: $why"
    }
    if ($failure.Exception.Data['vmfRollbackNoDiskChanged']) {
        # POWER-AFTER-MOVE-1: to the power state Checking found. The machine
        # stays changed, so no power state is named as owed: Restore this
        # machine returns it too.
        $restore = Resolve-VmfStoppedMachineState -Context $Context -AsFound
        return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode $code -MachineState 'changed' `
            -Detail "The $stepWord step failed after the preparation $changeWords the machine. The rollback stopped before it changed a disk ($fail), so the machine keeps the preparation - $($restore.Detail). Restore it from the first safety copy before you try it again.$madeNote Original error: $why"
    }
    $empty = @(Get-VmfRollbackEmptyLuns -Context $Context -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId))
    if ($empty.Count -or $fail -like "*$script:VmfSwapNeitherWords*") {
        $where = if ($empty.Count) { Format-VmfEmptyDataLuns $empty } else { 'a data disk LUN can have no disk. Attach each disk to its LUN, then start the machine' }
        return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode 'rollbackFailed' -MachineState 'changed' `
            -Detail "The $stepWord step failed after the preparation $changeWords the machine, and the rollback also failed ($fail). The machine is left stopped: $where.$madeNote Original error: $why"
    }
    # POWER-AFTER-MOVE-1: as above, to the power state Checking found.
    $restore = Resolve-VmfStoppedMachineState -Context $Context -AsFound
    return Add-VmfStateTransition @end -NewState 'FAILED_NEEDS_ATTENTION' -ReasonCode 'rollbackFailed' -MachineState 'changed' `
        -Detail "The $stepWord step failed after the preparation $changeWords the machine, and the rollback also failed ($fail) - $($restore.Detail).$madeNote Original error: $why"
}

function Set-VmfPowerReturnPending {
    <#
    .SYNOPSIS
        POWER-AFTER-MOVE-1: the checkpoint of the return to the power state
        Checking found, after a move passed every check of Verifying -
        written BEFORE the return (vm-state v39, powerReturnPending).
    .DESCRIPTION
        A worker killed in the return, or after it and before MIGRATED is on
        record, leaves the machine at VALIDATING. Without this, the next
        worker would run Verifying again on a machine that is deallocated -
        a check that cannot pass - and roll back a move that worked. With it,
        the loop finishes the return first (Complete-VmfPowerReturn) and never
        runs the step again. Removed in the same write as MIGRATED.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('PowerState/deallocated', 'PowerState/stopped')][string]$Power,
        [Parameter()][ValidateSet('MIGRATED')][string]$Next = 'MIGRATED'
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $doc | Add-Member -NotePropertyName powerReturnPending -Force -NotePropertyValue ([ordered]@{
            power = $Power; next = $Next; startedUtc = (Get-Date).ToUniversalTime().ToString('o') })
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
}

function Complete-VmfPowerReturn {
    <#
    .SYNOPSIS
        POWER-AFTER-MOVE-1: return the machine to the power state its
        checkpoint names, and record the state the move ends in - in the same
        write that removes the checkpoint. Safe to run again (rule 4).
    .DESCRIPTION
        The return uses the tries of Invoke-VmfPowerPutBack, and a return to
        the power state the machine has does nothing, so a resume after a
        return that took only records. Still refused, the move is MIGRATED
        all the same - it passed every check - and the entry says changed
        with the power state owed (history[].powerNotPutBack): the machine
        panel offers Return to the power state. A lost lease goes up: the
        next worker finishes it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Context, [Parameter()][double]$DurationSec = 0)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $pending = $doc.powerReturnPending
    $power = [string](Get-VmfRecordField -Object $pending -Name 'power')
    $next = [string](Get-VmfRecordField -Object $pending -Name 'next')
    if (-not $next) { $next = 'MIGRATED' }
    $back = Restore-VmfPowerAsFound -Context $Context -Power $power -OpName 'powerAsFound'
    $owed = @{}
    if ($back.Ok) { Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' -Outcome info -VmId $Context.VmId -Detail $back.Words }
    else { $owed = @{ MachineState = 'changed'; PowerNotPutBack = $power } }
    Add-VmfStateTransition -RunPath $Context.RunPath -VmId $Context.VmId -NewState $next -Outcome ok -DurationSec $DurationSec `
        -Detail $back.Words -ClearProperty @('powerReturnPending') @owed
}

function Add-VmfRollbackDiskDuringRollbackRecord {
    <#
    .SYNOPSIS
        PREP-ROLLBACK-1 (review F4): record a disk a rollback made, the moment
        Azure made it. A rollback that failed afterwards left disks that bill
        and that nothing named.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter()][AllowNull()]$Lun
    )
    # MADE-DISK-RECORD-1: one writer for the three lists (MadeDisks.ps1).
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if (-not $doc) { return }
    if (@(@(Get-VmfRecordField -Object $doc -Name 'rollbackDisksDuringRollback') | Where-Object { $_ -and [string]$_.diskId -eq $DiskId }).Count) { return }
    Add-VmfMadeDiskRecord -Context $Context -List 'rollbackDisksDuringRollback' -DiskId $DiskId -DiskName $DiskName -Lun $Lun
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId `
        -Detail "The rollback made the disk '$DiskName' from the first safety copy$(if ($null -ne $Lun) { ", for LUN $Lun" })."
}

function Set-VmfRollbackRecord {
    <#
    .SYNOPSIS
        IAC-REPORT-1 / PREP-ROLLBACK-1 (review F4): the disks the machine runs
        on after a rollback - written after EACH swap, so a rollback that stops
        part way still names the disk the machine has. -Done also marks the
        checkpoint finished, in the same write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowNull()]$OsDisk,
        [Parameter()][AllowEmptyCollection()][object[]]$DataDisks = @(),
        # SAFETY-ULTRA-1 (vm-state v20): each data disk this rollback did not
        # put back, and why - the machine record says it plainly.
        [Parameter()][AllowEmptyCollection()][object[]]$KeptDataDisks = @(),
        # ROLLBACK-CRG-1 (vm-state v24): the capacity reservation group Azure
        # did not put the machine back in, and why. Passed only with -Done:
        # a resume asks Azure again, and the last write says what is true.
        [Parameter()][AllowNull()]$ReservationNotBack,
        # ROLLBACK-CRG-1 review (vm-state v24): a capacity reservation group the
        # machine left that this migration did not make. With -Done only.
        [Parameter()][AllowNull()]$ReservationLeft,
        [Parameter()][switch]$Done
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    # ROLLBACK-ORIGINALS-LEFT-1 (vm-state v41): each disk these swaps took off
    # the machine, in the same write as the disks put on, added to the disks
    # earlier rollbacks left.
    Add-VmfRollbackOriginalsOnDoc -Doc $doc -OsDisk $OsDisk -DataDisks @($DataDisks)
    $rbRecord = [ordered]@{
            rolledBackUtc = (Get-Date).ToUniversalTime().ToString('o')
            # A = in place with the size back, disks = the disks only, before
            # the move (review F6: record what happened).
            path          = $Path
            # RETIRE-SCOPE-1: no sizeAfter - a rollback always goes to the size
            # the machine had (vm-state v47 removed the field).
            osDisk        = $OsDisk
            dataDisks     = @($DataDisks)
            keptDataDisks = @(@($KeptDataDisks) | Where-Object { $_ } | ForEach-Object { [ordered]@{ lun = [int]$_.lun; name = [string]$_.name; why = [string]$_.why } })
        }
    if ($ReservationNotBack) {
        $rbRecord.reservationGroupNotBack = [ordered]@{ groupId = [string]$ReservationNotBack.groupId; why = [string]$ReservationNotBack.why }
    }
    if ($ReservationLeft) {
        $rbRecord.reservationGroupLeft = [ordered]@{ groupId = [string]$ReservationLeft.groupId }
    }
    $doc | Add-Member -NotePropertyName rollback -Force -NotePropertyValue $rbRecord
    if ($Done -and $doc.PSObject.Properties['rollbackPending'] -and $doc.rollbackPending) {
        $doc.rollbackPending | Add-Member -NotePropertyName done -NotePropertyValue $true -Force
    }
    # MADE-DISK-RECORD-1: a disk the rollback made that the machine runs on now
    # is the machine's own - in the same write, after each swap, so no cleanup
    # ever takes it once a later put-back has swapped it off again.
    $onIds = @(@($(if ($OsDisk) { [string](Get-VmfRecordField -Object $OsDisk -Name 'id') })) + @(@($DataDisks) | Where-Object { $_ } | ForEach-Object { [string](Get-VmfRecordField -Object $_ -Name 'diskId') }) | Where-Object { $_ })
    $null = Set-VmfMadeDiskMarkOnDoc -Doc $doc -DiskIds $onIds -Field 'usedUtc'
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
}
function Invoke-VmfDataSwapBatches {
    <#
    .SYNOPSIS
        Swap the data disks a rollback made onto a stopped machine, in the
        batches Get-VmfSwapBatches gives (SAFETY-ULTRA-1: every other disk,
        then the Premium SSD v2 and Ultra Disk disks), and record each batch
        that took.
    .DESCRIPTION
        SWAP-REFUSED-AFTER-STOP-1: a batch Azure refuses is tried again
        (Invoke-VmfDataDiskSwap). One Azure still refuses keeps its old disks -
        Set-VmfVmDataDisks put them back on their LUNs - and each of its disks
        goes on -LeftList, with the disk still on the LUN. It used to go on
        -KeptList and the machine started with disks from two moments; now the
        caller leaves the machine stopped (Set-VmfSwapPending).
        ROLLBACK-EMPTY-LUN-1: a swap left neither way (SWAP-2UPD-1) no longer
        ends the rollback with a step to do in Azure. Each LUN is read and
        judged (Resolve-VmfRollbackSwapLuns): a LUN with no disk gets the disk
        the record proves, the way the restore does it, and every LUN not on
        its disk from the copy goes on -LeftList. -Resumed reads each LUN
        before the swap, so a worker that stopped between the two updates is
        finished, never swapped twice.
    .OUTPUTS
        The disks swapped in: @(@{ lun; diskId; diskName }).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][AllowNull()]$OsDisk,
        [Parameter()][AllowEmptyCollection()][object[]]$Swaps = @(),
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$KeptList,
        # SWAP-REFUSED-AFTER-STOP-1: each disk Azure did not swap, with the
        # disk still on its LUN (New-VmfSwapLeftRow).
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$LeftList,
        # ROLLBACK-DISKS-FIRST-1: the rollback's mark on a disk made for the
        # rollback that a batch swaps in (Set-VmfRollbackDisksBeforeMoveUsed).
        [Parameter()][AllowEmptyString()][string]$UsedBy = '',
        # ROLLBACK-EMPTY-LUN-1: a worker finishes a rollback another worker
        # started (Complete-VmfRollback -Resumed). Each LUN is read before it
        # is swapped.
        [Parameter()][switch]$Resumed
    )
    $made = [System.Collections.Generic.List[object]]::new()
    # The disk on each LUN before the swap: this attempt's capture. The move
    # never changes a data disk, so that is the disk the LUN holds now.
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $onLun = @{}
    $nameOn = @{}
    foreach ($d in @($doc.captured.vmConfig.dataDisks | Where-Object { $_ })) { $onLun[[int]$d.lun] = [string]$d.managedDiskId; $nameOn[[int]$d.lun] = [string]$d.name }
    # ROLLBACK-EMPTY-LUN-1: what is on each LUN of $LeftList, as last known -
    # so the words never say a LUN keeps a disk it does not have.
    $leftLive = @{}
    # Disks that are on their LUN from the copy: on record at once.
    $tookThese = {
        param([object[]]$these)
        # ROLLBACK-DISKS-FIRST-1: a rollback disk is the
        # machine's own from here - never used again, never deleted.
        Set-VmfRollbackDisksBeforeMoveUsed -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @($these | ForEach-Object { [string]$_.diskId }) -By $UsedBy
        foreach ($s in $these) { $made.Add([ordered]@{ lun = [int]$s.lun; diskId = [string]$s.diskId; diskName = [string]$s.diskName }) }
        # PREP-ROLLBACK-1 (review F4): on record after each swap.
        Set-VmfRollbackRecord -Context $Context -Path $Path -OsDisk $OsDisk -DataDisks @($made) -KeptDataDisks @($KeptList)
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId `
            -Detail "The data disks were restored from the first safety copy: $(@($these | ForEach-Object { "LUN $($_.lun) now uses '$($_.diskName)'" }) -join ', '). The disks they used before are kept."
    }
    # Disks that are not: on record at once, read back (re-review), so a later
    # batch or step that fails cannot lose them. The caller keeps the machine
    # stopped and records what is left.
    $leaveThese = {
        param([object[]]$rows, [string]$reason, $live)
        foreach ($row in $rows) {
            $LeftList.Add($row)
            $leftLive[[int]$row.lun] = if ($null -eq $live) { @{ unread = $true } } else { $live[[int]$row.lun] }
        }
        $words = Format-VmfRollbackLeft -Swaps @($LeftList) -Live $leftLive -AzureSaid $reason
        Save-VmfSwapPendingChecked -RunPath $Context.RunPath -VmId $Context.VmId -Words $words -Record (New-VmfSwapPendingRecord -Kind 'rollback' -Swaps @($LeftList) `
                -Reason $reason -UsedBy $UsedBy -Swapped @($made) -Kept @($KeptList))
        Set-VmfRollbackRecord -Context $Context -Path $Path -OsDisk $OsDisk -DataDisks @($made) -KeptDataDisks @($KeptList)
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome warn -VmId $Context.VmId `
            -Detail "$(Format-VmfRollbackLeft -Swaps $rows -Live $(if ($null -eq $live) { $null } else { $leftLive }) -AzureSaid $reason) The machine stays stopped, so it never starts with disks from two moments."
    }
    foreach ($batch in @(Get-VmfSwapBatches -Swaps $Swaps)) {
        $part = @($batch.Swaps)
        if ($Resumed) {
            # ROLLBACK-EMPTY-LUN-1: a worker may have stopped between the two
            # updates of this swap. Each LUN goes on from where it stands:
            # never swapped twice, and a LUN with no disk gets the disk the
            # record proves (Resolve-VmfRollbackSwapLuns). A read that fails
            # swaps as before - Set-VmfVmDataDisks refuses a LUN with no disk
            # before any change, and the catch below reads again.
            $read = Get-VmfRollbackLiveLuns -Context $Context
            if ($null -ne $read.Luns) {
                $judged = Resolve-VmfRollbackSwapLuns -Context $Context -Swaps $part -Live $read.Luns -OnLun $onLun -NameOn $nameOn -Resumed `
                    -Cause 'the worker stopped between the two updates of its data disk swap'
                if ($judged.Took.Count) { & $tookThese @($judged.Took) }
                if ($judged.Left.Count) { & $leaveThese @($judged.Left) ([string]$judged.Reason) $read.Luns }
                $part = @($judged.Todo)
                if (-not $part.Count) { continue }
            }
        }
        try {
            $swapped = Invoke-VmfDataDiskSwap -Context $Context -VmName $Context.VmName -OpName 'rollback:swapDataDisks' -Swaps $part
        }
        catch {
            # ROLLBACK-EMPTY-LUN-1: a swap left neither way (SWAP-2UPD-1). Each
            # LUN is read: one on the disk from its copy took, one on the disk
            # it had is a refused swap, and one with no disk gets the disk the
            # record proves - or, refused, the disk it had. Whatever is not on
            # its disk from the copy is left on record, so the machine stays
            # stopped and Finish the rollback finishes it. A read that fails
            # leaves every LUN of the batch on record: Finish reads it first.
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            # Said by what happened: the swap did not finish. Never "after 3
            # tries" - a swap that throws is not tried again.
            $neitherWhy = "The data disk swap did not finish: $(([string]$_.Exception.Message).TrimEnd('.'))"
            $read = Get-VmfRollbackLiveLuns -Context $Context
            if ($null -eq $read.Luns) {
                $why = "$neitherWhy. The product did not read the data disks after it: $($read.Why)."
                & $leaveThese @($part | ForEach-Object { New-VmfSwapLeftRow -Swap $_ -OldDiskId ([string]$onLun[[int]$_.lun]) -Why $why -Holds 'notRead' }) $why $null
                continue
            }
            $judged = Resolve-VmfRollbackSwapLuns -Context $Context -Swaps $part -Live $read.Luns -OnLun $onLun -NameOn $nameOn -Why "$neitherWhy." `
                -Cause 'Azure failed between the two updates of its data disk swap'
            if ($judged.Took.Count) { & $tookThese @($judged.Took) }
            if ($judged.Left.Count) { & $leaveThese @($judged.Left) ([string]$judged.Reason) $read.Luns }
            continue
        }
        if ($swapped.Applied) { & $tookThese $part }
        else {
            # Not applied after every try: the swap put the old disks back, so
            # each LUN has the disk it had. The machine must not start like
            # that.
            $back = @{}
            foreach ($s in $part) { $back[[int]$s.lun] = @{ id = [string]$onLun[[int]$s.lun]; name = [string]$nameOn[[int]$s.lun] } }
            & $leaveThese @($part | ForEach-Object { New-VmfSwapLeftRow -Swap $_ -OldDiskId ([string]$onLun[[int]$_.lun]) -Why ([string]$swapped.Reason) -Holds 'had' }) ([string]$swapped.Reason) $back
        }
    }
    @($made)
}

function Update-VmfPathCheckpoint {
    # Persist a sub-checkpoint inside CONVERTING without a state transition.
    # STEP-LOG-1: the line after it has its own handler - a line that cannot be
    # written must not fail the step whose checkpoint is already written.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Checkpoint)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $doc | Add-Member -NotePropertyName pathCheckpoint -NotePropertyValue $Checkpoint -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'checkpoint' -Outcome info -VmId $Context.VmId -Detail $Checkpoint
}

function Clear-VmfRetryState {
    <#
    .SYNOPSIS
        EVAL-H3/H5/L1: forget what a previous attempt got through, so a retry
        actually retries.
    .DESCRIPTION
        pathCheckpoint records how far the conversion got. Nothing ever
        cleared it - not the rollback, not Resolve-VmfDecision. So a machine
        that converted, failed at STARTING, was correctly put back on its v4
        size and pristine disk, and was then retried still carried the
        checkpoint: every gate in CONVERTING was skipped, no ARM work was
        done, and the handler returned "recreation complete." into the
        operator's history and the customer's report - about a machine still on
        SCSI at its old size. Validation then failed by construction, causing a
        SECOND rollback, with the record claiming success each time.

        Attempt counters are the same story more quietly: they are cumulative
        for the life of the document, so a retried machine could start with an
        exhausted budget and roll back on its FIRST validation hiccup while the
        message read "failed after 3 attempts".
    .PARAMETER From
        The state the machine is being re-armed at. Counters at and after it
        are cleared; earlier states keep their history.
    .PARAMETER NewAttempt
        SAFETY-RETRY-1: a PERSON is trying the machine again, so its safety
        copies are taken again. Never the automatic rollback, which also calls
        this: there the copies are the machine's rollback and are still needed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string]$From = 'PRECHECK',
        [Parameter()][switch]$NewAttempt,
        # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: the new attempt of a start on
        # the new size keeps the readings taken before the earlier move
        # (guestBefore, imdsBefore). The rollback put back the disks of the
        # first safety copy, and those readings were taken from them; this
        # attempt cannot take its own without a start on the original size.
        [Parameter()][switch]$KeepReadings
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { return }

    $cleared = [System.Collections.Generic.List[string]]::new()
    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: captured.startOnTarget stays. It
    # belongs to the stop in its stopUtc (Get-VmfStartOnTarget), and a park of
    # that attempt before any change carries it on (Test-VmfStartOnTargetStop).
    if ($doc.PSObject.Properties['pathCheckpoint'] -and $doc.pathCheckpoint) {
        $cleared.Add("conversion checkpoint '$($doc.pathCheckpoint)'")
        $doc.pathCheckpoint = $null
    }

    # Order matters: only states at or after the re-entry point are reset.
    $order = @('PLANNED', 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'STOPPED', 'SAFETY_COPY', 'CONVERTING', 'STARTING', 'VALIDATING')
    $fromIndex = [array]::IndexOf($order, $From)
    if ($fromIndex -lt 0) { $fromIndex = 0 }
    # VERIFY-FP-1 part 3: the guest reading for the evidence record is taken
    # once, on the untouched machine. A machine armed again at guest prep or
    # earlier is untouched again, so it is read again.
    # Only a PERSON's retry: a machine a stop left changed is refused one, so
    # it is untouched. The automatic rollback keeps the first reading - with no
    # pristine copy, the guest prep is still on the machine.
    if ($NewAttempt -and -not $KeepReadings -and $fromIndex -le [array]::IndexOf($order, 'GUEST_PREP') -and $doc.PSObject.Properties['captured'] -and $doc.captured -and
        $doc.captured.PSObject.Properties['guestBefore']) {
        $doc.captured.PSObject.Properties.Remove('guestBefore')
        $cleared.Add('the guest reading taken before the move')
    }
    # IMDS-KEEP-1: the same for the Instance Metadata Service reading.
    # GUEST_PREP keeps a known one over an unknown one, which is right inside
    # one attempt - but a person's retry is a complete new run on a machine
    # that may have been rolled back or restored since, so an answer from the
    # earlier attempt must not stand in for
    # this one. The automatic rollback keeps it: it ends the attempt, and only
    # a person's retry runs GUEST_PREP again.
    if ($NewAttempt -and -not $KeepReadings -and $fromIndex -le [array]::IndexOf($order, 'GUEST_PREP') -and $doc.PSObject.Properties['captured'] -and $doc.captured -and
        $doc.captured.PSObject.Properties['imdsBefore']) {
        $doc.captured.PSObject.Properties.Remove('imdsBefore')
        $cleared.Add('the Instance Metadata Service reading taken before the move')
    }
    # MANA-LINUX-KERNEL-1: the kernel update belongs to the attempt that made
    # it. A person's new attempt at or before GUEST_PREP starts on the machine
    # as it stands, and decides again whether to update the kernel - a record
    # left from the earlier attempt would read as an update still running, or
    # a put-back still owed. The automatic rollback keeps it: it is the record
    # of what was done.
    if ($NewAttempt -and $fromIndex -le [array]::IndexOf($order, 'GUEST_PREP') -and $doc.PSObject.Properties['captured'] -and $doc.captured -and
        $doc.captured.PSObject.Properties['kernelUpdate']) {
        $doc.captured.PSObject.Properties.Remove('kernelUpdate')
        $cleared.Add('the record of the kernel update in an earlier attempt')
    }
    # CLUSTER-NOT-RUNNING-1: the power state Checking found before it started
    # the machine for the cluster check belongs to that attempt. A person's
    # retry is a new run on the machine as it stands now - a machine somebody
    # started since must not be put back to an old power state.
    if ($NewAttempt -and $fromIndex -le [array]::IndexOf($order, 'PRECHECK') -and $doc.PSObject.Properties['captured'] -and $doc.captured -and
        $doc.captured.PSObject.Properties['clusterCheckPower']) {
        $doc.captured.PSObject.Properties.Remove('clusterCheckPower')
        $cleared.Add('the power state found before the cluster check')
    }
    # VOLUMES-RETRY-CHECK-OFF-1: the same for the power state found before the
    # check of the volumes started the machine. The new attempt is taken only
    # after that check returned the machine to it.
    if ($NewAttempt -and $fromIndex -le [array]::IndexOf($order, 'PRECHECK') -and $doc.PSObject.Properties['captured'] -and $doc.captured -and
        $doc.captured.PSObject.Properties['volumesCheckPower']) {
        $doc.captured.PSObject.Properties.Remove('volumesCheckPower')
        $cleared.Add('the power state found before the check of the volumes')
    }
    # AN-AMDV7-VF-GAP-1: the wait for the accelerated networking adapter
    # belongs to one attempt at VALIDATING. Every re-arm reaches VALIDATING
    # again - the rollback, a person's retry and a retry of Verifying alone -
    # so each starts a new wait. The step's own retry and a resumed worker do
    # not come here, and continue the wait on record.
    if ($doc.PSObject.Properties['captured'] -and $doc.captured -and $doc.captured.PSObject.Properties['anAdapterWait']) {
        $doc.captured.PSObject.Properties.Remove('anAdapterWait')
        $cleared.Add('the wait for the accelerated networking adapter')
    }
    # A record belongs to a move that reached MIGRATED. A machine armed again
    # has not, so an earlier record - a pass that did not reach MIGRATED, or a
    # move since put back - goes.
    if ($doc.PSObject.Properties['evidence'] -and $doc.evidence) {
        $doc.PSObject.Properties.Remove('evidence')
        $cleared.Add('the evidence record of an earlier pass')
    }
    if ($doc.attempts) {
        foreach ($prop in @($doc.attempts.PSObject.Properties)) {
            $idx = [array]::IndexOf($order, $prop.Name)
            if ($idx -ge $fromIndex -and [int]$prop.Value -gt 0) {
                $cleared.Add("$($prop.Name) attempt count")
                $doc.attempts.$($prop.Name) = 0
            }
        }
    }

    # SAFETY-RETRY-1: a retry from the first step is a NEW attempt, on a
    # machine that has run since the last one, so it takes NEW safety copies -
    # always (2026-09-28: every retry is a complete run end to end). A
    # rollback restores the pristine copy, and an old one would put back a disk
    # from before the earlier attempt, losing every write since. The earlier
    # copies stay on record, so retention and run deletion find them. A retry
    # that only validates again keeps them - the conversion it checks is
    # theirs. A machine whose rollback failed is not retried at all
    # (Resolve-VmfDecision refuses), so a new copy is never of a changed one.
    # VOLUMES-RETRY-CHECK-1: one changed stop is retried, volumesNotBack - and
    # its new attempt comes here only from Invoke-VmfVolumesCheckBeforeRetry,
    # after every volume mounted before the move is mounted again.
    $keptCopies = $false
    $dataIds = { param($kind) @(Get-VmfDataCopies -Doc $doc -Kind $kind | ForEach-Object { [string]$_.snapshotId } | Where-Object { $_ }) }
    $dataRecords = { param($kind) @(Get-VmfDataCopies -Doc $doc -Kind $kind | Where-Object { $_ -and [string]$_.snapshotId }) }
    if ($NewAttempt -and $From -eq 'PRECHECK' -and $doc.PSObject.Properties['safety'] -and $doc.safety -and
        ([string]$doc.safety.pristineSnapshotId -or [string]$doc.safety.snapshotId -or (& $dataIds 'pristine').Count -or (& $dataIds 'prepared').Count)) {
        $flag = { param($name) if ($doc.safety.PSObject.Properties[$name]) { $doc.safety.$name } else { $null } }
        $idOf = { param($name) if ([string]$doc.safety.$name) { [string]$doc.safety.$name } else { $null } }
        $earlier = @(if ($doc.safety.PSObject.Properties['earlierCopies']) { @($doc.safety.earlierCopies) }) + @([pscustomobject]@{
                pristineSnapshotId = (& $idOf 'pristineSnapshotId'); pristineSnapshotLocked = (& $flag 'pristineSnapshotLocked')
                snapshotId = (& $idOf 'snapshotId'); snapshotLocked = (& $flag 'snapshotLocked')
                # SAFETY-ALL-1: the data disks' copies go with them, as the same
                # records, so their locks stay on record too.
                pristineDataCopies = @(& $dataRecords 'pristine'); dataCopies = @(& $dataRecords 'prepared')
                keptUtc = (Get-Date).ToUniversalTime().ToString('o')
            })
        # ROLLBACK-DISKS-FIRST-1: the rollback disks go with the
        # copies they were made from. This attempt makes its own for its own
        # copies; retention deletes the unused ones (Get-VmfDueRollbackDisksBeforeMove).
        if (& $flag 'rollbackDisksBeforeMove') { $earlier[-1] | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue (& $flag 'rollbackDisksBeforeMove') -Force }
        foreach ($name in 'pristineSnapshotId', 'pristineSnapshotLocked', 'snapshotId', 'snapshotLocked') {
            if ($doc.safety.PSObject.Properties[$name]) { $doc.safety.$name = $null }
        }
        foreach ($name in 'pristineDataCopies', 'dataCopies', 'rollbackDisksBeforeMove') {
            if ($doc.safety.PSObject.Properties[$name]) { $doc.safety.PSObject.Properties.Remove($name) }
        }
        $doc.safety | Add-Member -NotePropertyName earlierCopies -NotePropertyValue @($earlier) -Force
        $keptCopies = $true
    }

    # VOLUMES-RETRY-CHECK-1: a person's new attempt is taken only after the
    # check its record owes has passed (Invoke-VmfVolumesCheckBeforeRetry), so
    # the record goes in the same write that moves the copies - a kill can
    # never leave the copies moved with the check still owed, or the reverse.
    $owedGone = $false
    if ($NewAttempt -and $From -eq 'PRECHECK' -and $doc.PSObject.Properties['volumesCheckOwed']) {
        $doc.PSObject.Properties.Remove('volumesCheckOwed')
        $owedGone = $true
    }

    if ($cleared.Count -gt 0 -or $keptCopies -or $owedGone) {
        Write-VmfStateDoc -RunPath $RunPath -Document $doc
    }
    if ($cleared.Count -gt 0) {
        Write-VmfStepLine -RunPath $RunPath -Step 'rearm' -Outcome info -VmId $VmId `
            -Detail (Get-VmfRearmWords -From $From)
    }
    if ($keptCopies) {
        Write-VmfStepLine -RunPath $RunPath -Step 'safetyCopy' -Outcome info -VmId $VmId `
            -Detail 'The safety copies of the earlier attempt are kept. This attempt takes new ones before it changes the machine.'
    }
}

function Save-VmfCapturedFacts {
    # Merge captured facts (vmConfig, guest inventory) into the state doc.
    # -ReplaceOriginal: ROLLBACK-RETRY-CAPTURE-1 - only PRECHECK passes it, and
    # only while the product has never touched the machine.
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][hashtable]$Facts, [Parameter()][switch]$ReplaceOriginal)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $captured = if ($doc.PSObject.Properties['captured'] -and $doc.captured) {
        $h = @{}; foreach ($p in $doc.captured.PSObject.Properties) { $h[$p.Name] = $p.Value }; $h
    } else { @{} }
    foreach ($k in $Facts.Keys) {
        # ROLLBACK-RETRY-CAPTURE-1: once written, the first capture is replaced
        # only on purpose. A caller that passes it again is ignored here, so no
        # other path can replace it.
        if ($k -eq 'original' -and $captured.ContainsKey('original') -and $captured['original'] -and -not $ReplaceOriginal) { continue }
        $captured[$k] = $Facts[$k]
    }
    $doc | Add-Member -NotePropertyName captured -NotePropertyValue $captured -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
}

##############################################################################
# Step handlers - each returns @{ Next = '<STATE>'; Detail = '...' } or throws.
##############################################################################

function Test-VmfNicLinkedPermissions {
    <#
    .SYNOPSIS
        NIC-JOIN-1: can this identity write the interfaces this move will
        change, INCLUDING the joins Azure checks on what they link to?
    .OUTPUTS
        $null when it can, or the NEEDS_DECISION result naming each resource
        and action it cannot.
    #>
    [CmdletBinding(DefaultParameterSetName = 'Move')]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory, ParameterSetName = 'Move')]$PlanEntry,
        [Parameter(ParameterSetName = 'Move')][AllowNull()]$CapturedNics,
        # RESTORE-PERM-CHECK-1: Restore this machine names the interfaces it
        # writes itself (Get-VmfRestoreNicWrites), and gets its own words.
        [Parameter(Mandatory, ParameterSetName = 'Restore')][AllowEmptyCollection()][string[]]$WriteNicIds
    )
    $for = 'move'
    if ($PSCmdlet.ParameterSetName -eq 'Restore') {
        $for = 'restore'
        $nicWrites = @($WriteNicIds | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ id = [string]$_ } })
    }
    else {
        $anPolicyNow = Get-VmfPolicy -PlanEntry $PlanEntry -Name 'acceleratedNetworking'
        $nicWrites = @(Get-VmfNicAnPlan -CapturedNics $CapturedNics -Policy $anPolicyNow)
    }
    if (-not $nicWrites.Count) { return $null }
    $links = @(foreach ($w in $nicWrites) {
        $wid = [string]$w.id
        $nicLive = Invoke-VmfAzOperation -Name 'nicLinks' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfNetworkInterfaceById -NicId $wid
        }
        Get-VmfNicLinkedActions -Nic $nicLive
    })
    $missingLinks = @(foreach ($scopeGroup in @($links | Group-Object Scope)) {
        $scopeId = [string]$scopeGroup.Name
        $scopePerms = Invoke-VmfAzOperation -Name 'linkedPermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfEffectivePermissions -Scope $scopeId
        }
        foreach ($a in @(Get-VmfMissingActions -RequiredActions @($scopeGroup.Group | ForEach-Object Action) -Permissions $scopePerms)) {
            # STOP-TEXT-SPECIFIC-1: the kind goes with it, so the stop names
            # the resource as Azure does (a subnet, a public IP address).
            [pscustomobject]@{ Scope = $scopeId; Action = $a
                Kind = [string](@($scopeGroup.Group | Where-Object { $_.Action -eq $a } | Select-Object -First 1).Kind) }
        }
    })
    if (-not $missingLinks.Count) { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'permissionMissingNetwork'; Detail = (Format-VmfLinkedMissingMessage -Missing $missingLinks -For $for) }
}

function Resolve-VmfStartOnTarget {
    <#
    .SYNOPSIS
        ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: does this attempt start the machine
        on the new size, with no start on its original size? The record
        (captured.startOnTarget), or $null. See StartOnTarget.ps1.
    .DESCRIPTION
        Asked at the top of Checking. Only a retry from a rollbackNoCapacity
        stop, of a move that needs no change inside the machine before it
        (Test-VmfStartOnTargetShape), of a machine that Azure shows stopped.
        Any other move says why and starts on the original size, as before.

        Kill-resume (rule 4): the new attempt is taken FIRST - only while a
        volume check is owed, which it removes in the same write - then the
        record is saved. A worker killed between the two finds no record and
        no check owed, so it takes no second attempt, and saves the record. A
        worker killed after it finds the record (Get-VmfStartOnTarget).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.RunPath) { return $null }
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $kept = Get-VmfStartOnTarget -Doc $doc
    if ($kept) { return $kept }
    $stop = Get-VmfLastStopEntry -Doc $doc
    if (-not $stop -or -not (Test-VmfStartOnTargetStop -Doc $doc)) { return $null }
    $size = [string](Get-VmfRecordField -Object (Get-VmfOriginalCapture -Doc $doc) -Name 'size')
    $why = Test-VmfStartOnTargetShape -PlanEntry $Context.Plan
    if ($why) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId `
            -Detail (Get-VmfStartOnTargetRefusedWords -Size $size -Why $why)
        return $null
    }
    $power = [string](Invoke-VmfAzOperation -Name 'powerState' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName
        })
    # A machine somebody started since runs on its original size, so the
    # checks run in it before the move, as for any retry.
    if ($power -notin @('PowerState/deallocated', 'PowerState/stopped')) { return $null }
    $owed = Get-VmfPowerOwed -Doc $doc
    # SAFETY-RETRY-1: the new attempt, with new safety copies - taken here,
    # because the volume check that would take it cannot run on a machine
    # that is not started. The readings of the copy these disks came from stay.
    if (Get-VmfVolumesCheckOwed -Doc $doc) {
        Clear-VmfRetryState -RunPath $Context.RunPath -VmId $Context.VmId -From 'PRECHECK' -NewAttempt -KeepReadings
    }
    $stopAt = ConvertTo-VmfUtcTime $stop.tsUtc
    $record = [ordered]@{
        size    = $size
        target  = [string]$Context.Plan.target.size
        power   = $(if ($owed) { $owed } else { $power })
        stopUtc = $(if ($stopAt) { $stopAt.ToString('o') } else { [string]$stop.tsUtc })
        tsUtc   = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-VmfCapturedFacts -Context $Context -Facts @{ startOnTarget = $record }
    $readings = Get-VmfRecordField -Object (Get-VmfRecordField -Object (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId) -Name 'captured') -Name 'guestBefore'
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId `
        -Detail (Get-VmfStartOnTargetPrepWords -Size $size -Target $record.target -ReadingsKept ([bool]$readings))
    [pscustomobject]$record
}

function Invoke-VmfStepPrecheck {
    param([Parameter(Mandatory)]$Context)
    $plan = $Context.Plan

    # ENGINE-SUB-1, FIRST, before any Azure call at all. This engine addresses
    # a machine by resource group and name, which are unique only inside one
    # subscription. If this machine is in a different one, the best case is a
    # confusing not-found; the worst is that a DIFFERENT machine sharing that
    # resource group and name gets deallocated, converted, or on Path B deleted
    # and rebuilt. Every check below talks to Azure, so this has to come before
    # all of them - it was placed after the permissions read first time round,
    # which meant real calls were already being made against the wrong
    # subscription before the guard could speak.
    # ENGINE-SUB-1: the machine's id MUST say which subscription it is in -
    # without that there is no way to be sure the right machine is being acted
    # on, and no way to point the process at the right place. The switch itself
    # happened before this step; what is left to check is that the id was there
    # to switch by, and that the switch took.
    if (-not $Context.SubscriptionId) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'subscriptionNotReachable'
                  Detail = "This machine's resource id does not say which subscription it is in, so there is no way to be sure the right machine would be acted on." }
    }
    $engineSub = Get-VmfEngineSubscriptionId
    if ($engineSub -and $Context.SubscriptionId -ne $engineSub) {
        # Belt and braces. If this fires, the context switch silently did not
        # take, and every call below would address the wrong subscription.
        return @{ Next = 'NEEDS_DECISION'; Reason = 'subscriptionNotReachable'
                  Detail = "This machine is in subscription $($Context.SubscriptionId) but the product is still pointed at $engineSub - switching to the machine's own subscription did not take effect, so it is not safe to continue." }
    }

    # VOLUMES-RETRY-CHECK-1 (2026-11-14): a retry after volumesNotBack,
    # or after a put-back whose volume check could not run, FIRST checks that
    # every volume mounted before the move is mounted again - the first Azure
    # call after the subscription check, before the power state owed goes
    # back (a machine found deallocated would be deallocated before it was
    # checked). Not all mounted, or not known: the stop again, nothing changed
    # in Azure, the safety copies and the reading before the move kept.
    # All mounted: the new attempt is taken now (new safety copies), and
    # Checking goes on as for any retry.
    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: a retry after rollbackNoCapacity of
    # a SCSI move starts the machine on the new size. The volume check, the
    # power state owed and the cluster check below all start the machine on
    # its original size, which Azure had no capacity for, so none of them
    # runs here: the volume comparison and the cluster check run after the
    # start on the new size, and the move returns the power state.
    # The volume check owes nothing on a start on the new size:
    # Resolve-VmfStartOnTarget took the new attempt, which removes the record
    # that owes it, in the same write.
    $startOnTarget = Resolve-VmfStartOnTarget -Context $Context
    $volumesStop = Invoke-VmfVolumesCheckBeforeRetry -Context $Context
    if ($volumesStop) { return $volumesStop }

    # POWER-ONLY-CHANGED-1: the last stop could not put back the power state
    # Checking found (Get-VmfPowerOwed), and a person tried the machine again.
    # Since 2026-11-06 the machine MUST go back to its power state. So the
    # power state goes back FIRST - the first Azure call after the
    # subscription check and a volume check owed (VOLUMES-RETRY-CHECK-1,
    # above) - and only then does the move run again, from a
    # machine as it was. Still refused, the retry stops here and says so: no
    # copy, no script and no start. The line of the put-back says untouched,
    # which ends what is owed; a worker killed before that line puts it back
    # again on the resume, which is safe (Invoke-VmfPowerPutBack reads the
    # machine at each try). The record of the cluster check is not used: the
    # retry dropped it (Clear-VmfRetryState), and this Checking makes a new one.
    # A context with no run (a test of the checks alone) has no record to read.
    $owed = if ($Context.RunPath -and -not $startOnTarget) { Get-VmfPowerOwed -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId) } else { $null }
    if ($owed) {
        $back = Restore-VmfPowerAsFound -Context $Context -Power $owed
        if (-not $back.Ok) {
            return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'powerNotPutBack'; MachineState = 'changed'; PowerNotPutBack = $owed; PowerAsFound = $true
                      Detail = "The product did not try the move again, because $($back.Detail)." }
        }
        Add-VmfStateTransition -RunPath $Context.RunPath -VmId $Context.VmId -NewState 'PRECHECK' -Outcome ok -MachineState 'untouched' -PowerPutBack `
            -Detail "$($back.Words) The product now tries the move again." | Out-Null
    }

    if ($plan.assessment.platformManaged) {
        return @{ Next = 'SKIPPED'; Detail = 'The assessment excluded this machine. Another Azure service manages it, or it is outside the scope of this tool.' }
    }
    # OLD-VERSION-READERS-REMOVE-3: a policy value the contract does not list
    # is refused here, untouched, before any step reads it as a default.
    $policyRefusal = Get-VmfPlanPolicyRefusal -PlanEntry $plan
    if ($policyRefusal) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'policyNotKnown'; Detail = $policyRefusal; MachineState = 'untouched' }
    }
    # V5-GATE-1: the plan keeps the scan's classification, which the scan
    # decided for every series. Judge it against THIS plan's series, as the
    # planner did when it chose the path - a Generation 1 machine is blocked
    # for v6 and ready for v5.
    $series = if ($plan.policy -and $plan.policy.PSObject.Properties['targetGeneration'] -and $plan.policy.targetGeneration) {
                  [string]$plan.policy.targetGeneration } else { 'v6' }
    $judged = Resolve-VmfEntryClassification -Assessment $plan.assessment -TargetGeneration $series
    if ($judged.Classification -in @('Blocked', 'Excluded')) {
        $why = if (@($judged.Blockers).Count) { ": $(@($judged.Blockers) -join ', ')" } else { '' }
        return @{ Next = 'SKIPPED'; Detail = "The assessment classification for $series is '$($judged.Classification)'$why." }
    }
    # RETIRE-SCOPE-1 (REVIEW): the size the plan was made for, asked FIRST,
    # before the refusals a person can correct (permissions, locks,
    # encryption) - nobody should fix a permission and then hear the machine
    # is out of scope. The size the machine has now is asked again below, as
    # soon as it is read.
    $plannedOutOfScope = Get-VmfRetiredScopeDetail -Size ([string]$plan.assessment.sourceSize)
    if ($plannedOutOfScope) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'sizeRetired'; Detail = "$plannedOutOfScope Nothing on the machine changed." }
    }
    # GPU-SCOPE-1: a family the product does not move (a GPU size, OLD-FAM-3's
    # families). A plan made before the rule carries the old assessment, with
    # no blocker, so the classification above passes it - and path A would
    # resize a GPU machine onto a size with no GPU. Asked here, untouched.
    $plannedFamily = Get-VmfFamilyScopeDetail -Size ([string]$plan.assessment.sourceSize)
    if ($plannedFamily) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'sizeOutOfScope'; Detail = "$plannedFamily Nothing on the machine changed." }
    }
    # DISKS-32-1: more than 32 data disks is outside the scope of this tool. A
    # plan made before the rule carries the old assessment, with no blocker,
    # and a v6 or v7 target that takes them. Asked here, untouched; the disks
    # the machine has now are asked again as soon as it is read.
    $plannedDisks = Get-VmfDataDiskScopeDetail -Count (Get-VmfAssessedDataDiskCount -Assessment $plan.assessment)
    if ($plannedDisks) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'tooManyDataDisks'; Detail = "$plannedDisks Nothing on the machine changed." }
    }

    # SAFETYCOPY-CLEAN-1, MANUAL-REVIEW-1: an entry that does not ask for the
    # first safety copy is refused above, as a value the contract does not
    # list (policyNotKnown) - one guard, not two.

    # IAC-2: no per-machine IaC gate. The tag heuristic that used to park a
    # machine here was removed - it could not tell Terraform from Bicep, Pulumi,
    # ARM or Ansible, and read a differently-tagged estate as unmanaged. The
    # customer acknowledges the drift question ONCE for the run instead, which
    # Start-VmfWave requires before the first wave moves.

    # PERM-3: can this identity finish what it is about to start?
    #
    # The PERM-1 drill hit a missing permission PART-WAY THROUGH a move (a
    # rebuild an earlier version made). Because the move and its rollback need
    # the same rights, the gap that broke the migration also broke the
    # recovery meant to cover it, and nothing could put the machine back.
    #
    # So ask first. This is the last moment the answer is free: nothing has been
    # touched, and a refusal costs an operator a role assignment instead of a
    # machine. Asked at the VM's own scope, so grants inherited from the
    # management group, subscription or resource group are already folded in.
    $perms = Invoke-VmfAzOperation -Name 'permissionsCheck' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfEffectivePermissions -Scope $Context.VmId
    }
    # TEMP-DISK-PREVIEW-1: the read of the preview feature is required only of
    # a machine whose saved method is preview (the map's requiredFor).
    $requiredFor = @(if ((Get-VmfEntryMethod -Entry $plan) -eq 'preview') { 'preview' })
    $missingActions = Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions -For $requiredFor) -Permissions $perms
    if (@($missingActions).Count -gt 0) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'permissionsMissing'; Detail = (Format-VmfMissingActionsMessage -Missing $missingActions -Scope $Context.VmId) }
    }

    # SAFETY-3: the lock actions are OPTIONAL - Contributor lacks them, and a
    # migration must not be refused for a protection it can do without. Asked
    # here, once, while the answer is already in hand, and recorded so the
    # lock steps know without asking again. Said on the run page, so nobody
    # believes the copies are protected when they are not.
    $optionalMissing = @(Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions -Optional) -Permissions $perms)
    $lockDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $lockSafety = if ($lockDoc.PSObject.Properties['safety'] -and $lockDoc.safety) { $lockDoc.safety } else { [pscustomobject]@{ snapshotId = $null; cloneVmId = $null } }
    $lockSafety | Add-Member -NotePropertyName locksAllowed -NotePropertyValue ($optionalMissing.Count -eq 0) -Force
    $lockDoc | Add-Member -NotePropertyName safety -NotePropertyValue $lockSafety -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $lockDoc
    if ($optionalMissing.Count -gt 0) {
        Write-VmfEvent -RunPath $Context.RunPath -Step 'lockSnapshot' -Outcome warn -VmId $Context.VmId `
            -Detail "The product's managed identity cannot place resource locks ($($optionalMissing -join ', ')). The safety copies will be taken but not locked, so nothing stops their deletion."
    }

    # TEMP-DISK-PREVIEW-1 (2026-11-02): an in-place upgrade (Preview)
    # needs the preview feature VMTempDiskResizePreview on the subscription,
    # and Azure refuses the resize without it - inside the stopped window. So
    # the feature is read again here, after the permission check (which holds
    # the read) and before anything changes. Not registered, or not read: the
    # machine stops untouched.
    $previewStop = Get-VmfPreviewFeatureGate -Context $Context -PlanEntry $plan
    if ($previewStop) { return $previewStop }

    # ADE is a hard blocker for NVMe (checked for BOTH OSes - gap closure P1-5).
    # GEN-V5-1: v5 keeps Azure Disk Encryption, so a v5 resize goes ahead.
    # REBUILD-REMOVE-PLAN-1: but not the in-place upgrade (Preview), which changes
    # the kind of temporary disk and was never measured with Azure Disk
    # Encryption - so it stays refused for 1.0. The scan refuses it at
    # plan time (disk-encryption-preview) from the OS disk only.
    # ADE-DETECT-ANY-NAME-1: asked below, from two reads Checking makes anyway:
    # the extension by its publisher and type (after Read-VmfPrecheckExtensions),
    # and each disk's own setting (Add-VmfDiskEncryptionFacts).
    $adeStops = ($plan.target.controller -eq 'NVMe' -or (Get-VmfEntryMethod -Entry $plan) -eq 'preview')

    # The power state Checking found: the cluster check and every rollback and restore put
    # the machine back to it. REBUILD-MOVE-HOST-1: a hibernated machine stops
    # below, untouched, with every machine that has hibernation enabled
    # (Get-VmfHostHibernationStop).
    $power = Invoke-VmfAzOperation -Name 'powerState' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName
    }

    # LOCK-1: a resource lock, judged against what the move does.
    #
    # Found while building RETRY-1: nothing looked for locks anywhere. A lock
    # that refuses a change of the move fails it inside the deallocated
    # window, past the point of no return, when it could have been a free stop
    # right here. A ReadOnly lock refuses every change. A CanNotDelete lock
    # does not refuse a resize or a disk swap, so it does not stop the move
    # (REBUILD-REMOVE-LEFTOVERS-1: the rebuild that it stopped is removed).
    $locks = Invoke-VmfAzOperation -Name 'resourceLocks' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfVmResourceLocks -ResourceGroupName $Context.Rg -Name $Context.VmName
    }
    $lockVerdict = Get-VmfLockVerdict -Locks $locks
    if ($lockVerdict.Blocked) {
        return @{ Next = 'NEEDS_DECISION'; Reason = [string]$lockVerdict.Reason; Detail = $lockVerdict.Detail }
    }
    if ($lockVerdict.Detail) {
        Write-VmfEvent -RunPath $Context.RunPath -Step 'precheck' -Outcome info -VmId $Context.VmId `
            -Detail $lockVerdict.Detail
    }

    # AVSET-1: say what we know about the availability set BEFORE the machine is
    # touched. An availability set is pinned to a cluster, and Microsoft's own
    # tooling warns a conversion can fail while other members are still
    # allocated: the set cannot move to hardware supporting the new size until
    # every member is deallocated.
    #
    # AVSET-NOTE-1 settled the rule from Microsoft's resize page: it applies
    # only when the set's current hardware does not offer the new size - so the
    # note now asks that, and warns only when it is true or cannot be known.
    # AVSET-NOT-OFFERED-STOP-1 (2026-11-14): when Azure is definite that
    # the size is not offered AND that another machine of the set runs, it
    # stops the machine here, untouched; every case it cannot tell still only
    # advises. What is not acceptable is
    # silence: if this does fail it fails INSIDE the stopped window, and an
    # operator who was never told will have no idea why.
    $avsetId = if ($plan.assessment.PSObject.Properties['availabilitySetId']) {
        [string]$plan.assessment.availabilitySetId
    } else { $null }
    if ($avsetId) {
        # MISSING-READ-2: a read of the set Azure does not answer is UNKNOWN
        # ($null), never "no other members" - which gave no note at all.
        try {
            $members = @(Invoke-VmfAzOperation -Name 'avsetMembers' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfAvailabilitySetMembers -AvailabilitySetId $avsetId
            })
        }
        catch { $members = $null }
        $others = @($members | Where-Object { $_.Id -ne $Context.VmId })
        if ($null -eq $members -or $others.Count -gt 0) {
            # Unknown must never read as "stopped" - that is the reassuring
            # answer, and it is the one we cannot support.
            $running = @($others | Where-Object { $_.Allocated -ne $false })
            # AVSET-NOT-OFFERED-STOP-1: and the ones Azure SAYS run - only those
            # can make the note a stop.
            $runningKnown = @($others | Where-Object { $_.Allocated -eq $true })
            $names = (@($others | ForEach-Object { $_.Name }) | Select-Object -First 8) -join ', '
            # AVSET-NOTE-1: the rule is CONDITIONAL, and the note said it as a
            # likely failure on every member of every set - then said the
            # product converts them one at a time with the others running,
            # which is the strategy it had just warned against. Microsoft's
            # resize page: every machine in the set must be stopped only when
            # the new size "isn't available on the hardware cluster currently
            # hosting" it. So ask that question, and say only what the answer
            # supports. Measured 2026-09-23: two machines in one set, v4 to v6
            # in westus3, one at a time with the other running - both moved.
            $target = [string]$plan.target.size
            $offered = $null
            try {
                $offered = @(Invoke-VmfAzOperation -Name 'avsetSizes' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                    Get-VmfAvailabilitySetSizes -AvailabilitySetId $avsetId
                })
            }
            catch { $offered = $null }   # unknown - never read as either answer
            $avsetNote = if ($null -eq $members) { Get-VmfAvailabilitySetUnknownNote -TargetSize $target -OfferedSizes $offered }
                else { Get-VmfAvailabilitySetNote -Others $others.Count -Names $names -Running $running.Count `
                    -DefinitelyRunning $runningKnown.Count -TargetSize $target -OfferedSizes $offered }
            # AVSET-NOT-OFFERED-STOP-1 (2026-11-14): the hardware of the
            # set does not offer the target size and another machine of it
            # runs - Azure would refuse the size inside the change window. Stop
            # here, before the capture and before Backing up, untouched.
            if ($avsetNote.Outcome -eq 'stop') {
                return @{ Next = 'NEEDS_DECISION'; Reason = 'availabilitySetSizeNotOffered'; MachineState = 'untouched'
                          Detail = "$($avsetNote.Detail) Nothing on the machine changed." }
            }
            Write-VmfEvent -RunPath $Context.RunPath -Step 'precheck' -Outcome $avsetNote.Outcome -VmId $Context.VmId `
                -Detail $avsetNote.Detail
        }
    }

    # Capture the full pre-mutation config - rollback/recreate source of truth
    $vm = Invoke-VmfAzOperation -Name 'getVm' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName
    }
    # RETIRE-SCOPE-1 (reversing part of V3-RETIRE-1): the rollback. A failed
    # move rolls the machine back to the size it has now, automatically and in
    # the stopped window. From one day before Microsoft retires that size, a
    # machine on it is outside the scope of this tool: refused HERE, before
    # anything changes, and never sent to another size. Within the 12 months
    # before, the move goes on and the log warns. Asked as soon as the size is
    # read, before the refusals a person can correct.
    # ROLLBACK-RETRY-CAPTURE-1: the size a rollback returns to is the FIRST
    # capture's once the product has touched the machine - a retry after a
    # rebuild as the target finds it on the target size, and its rollback
    # still goes back to the size before. Before that, the size it has now.
    $ownSize = [string]$vm.HardwareProfile.VmSize
    $rbDocNow = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $kept = Get-VmfRecordField -Object (Get-VmfRecordField -Object (Get-VmfRecordField -Object $rbDocNow -Name 'captured') -Name 'original') -Name 'vmConfig'
    if ($kept -and [string](Get-VmfRecordField -Object $kept -Name 'size') -and (Test-VmfMachineTouched -Doc $rbDocNow)) { $ownSize = [string](Get-VmfRecordField -Object $kept -Name 'size') }
    # Written every time, $null included, so a row Microsoft moves or removes
    # does not leave an old date for the dialogs to show. A plan entry's
    # target.rollbackSize (plan-entry v18) is not read.
    Save-VmfCapturedFacts -Context $Context -Facts @{ putBackRetirement = (Get-VmfMoveRetirementRecord -Size $ownSize) }
    $outOfScope = Get-VmfRetiredScopeDetail -Size $ownSize -RollbackSize:($ownSize -ne [string]$vm.HardwareProfile.VmSize)
    if ($outOfScope) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'sizeRetired'; Detail = "$outOfScope Nothing on the machine changed." }
    }
    # GPU-SCOPE-1: and the size the machine has (or returns to) now - a machine
    # resized onto a GPU size after its plan was made.
    $ownFamily = Get-VmfFamilyScopeDetail -Size $ownSize
    if ($ownFamily) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'sizeOutOfScope'; Detail = "$ownFamily Nothing on the machine changed." }
    }
    # DISKS-32-1: and the data disks the machine has now - disks added after
    # its plan was made. Counted from the live data disk list only, never the
    # operating system disk; an empty list is none.
    $ownDisks = Get-VmfDataDiskScopeDetail -Count @(@($vm.StorageProfile.DataDisks) | Where-Object { $_ }).Count
    if ($ownDisks) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'tooManyDataDisks'; Detail = "$ownDisks Nothing on the machine changed." }
    }    # PRECHECK-WORKLOAD-1: a storage or backup appliance and a machine with a
    # shared disk are outside the scope of this tool. A plan made from an older
    # assessment has neither blocker, and a disk can become shared after the
    # scan, so Azure is asked again here, from the machine just read - with the
    # other out-of-scope stops, before any stop a person can accept and before
    # any RunCommand in the machine (review, 2026-11-01).
    $workloadScope = Get-VmfWorkloadScopeStop -Context $Context -Vm $vm
    if ($workloadScope) { return $workloadScope }
    # BATCH-CYCLECLOUD-SIGNAL-1: a node of an Azure CycleCloud cluster, from a
    # plan made before the scan excluded it - judged on the machine just read.
    $cycleCloudStop = Get-VmfCycleCloudStop -Vm $vm
    if ($cycleCloudStop) { return $cycleCloudStop }
    # REBUILD-MOVE-HOST-1: a machine on a dedicated host, or with hibernation
    # enabled, from a plan made before the scan excluded it - judged on the
    # machine just read.
    $hostHibernationStop = Get-VmfHostHibernationStop -Vm $vm
    if ($hostHibernationStop) { return $hostHibernationStop }
    # EOL-RELEASE-AN-1: a Linux release past its vendor's end of standard
    # support waits for an approver - after every stop for a machine outside
    # the scope of this tool, and before any RunCommand or change.
    $releaseEolStop = Get-VmfReleaseEndOfLifeStop -PlanEntry $Context.Plan
    if ($releaseEolStop) { return $releaseEolStop }
    $retireWarning = Get-VmfRetirementWarning -Size $ownSize
    if ($retireWarning) {
        Write-VmfEvent -RunPath $Context.RunPath -Step 'precheck' -Outcome warn -VmId $Context.VmId -Detail $retireWarning
    }
    # PRECHECK-EXT-READ-1: a read Azure did not answer stops the machine
    # untouched (extensionsNotRead), never "no extensions".
    $extensionRead = Read-VmfPrecheckExtensions -Context $Context
    if ($extensionRead.Stop) { return $extensionRead.Stop }
    $extensions = $extensionRead.Extensions
    # ADE-DETECT-ANY-NAME-1: the Azure Disk Encryption extension, whatever its
    # name. The list was read above; a list not read stopped the machine there.
    if ($adeStops -and (Test-VmfAdeExtension -Extensions @($extensions))) {
        return Get-VmfAdeStop -Found $true
    }

    # NIC-1: the LAST safe moment to find out the target size cannot hold this
    # machine's network interfaces. Past here it is deallocated and its disks
    # are detached, so the same discovery becomes a failure mid-recreate.
    # Plan time already picked a size that fits; this re-checks against live
    # Azure, because the plan may be old and the machine may have gained a NIC.
    $liveNics = @($vm.NetworkProfile.NetworkInterfaces)
    $liveDataDisks = @($vm.StorageProfile.DataDisks)
    $liveZone = Get-VmfMachineZone -Machine $vm
    if (($liveNics.Count -gt 1 -or $liveDataDisks.Count -gt 0 -or $liveZone) -and $plan.target.size) {
        $region = if ($vm.Location) { [string]$vm.Location } else { [string]$plan.assessment.location }
        $targetSize = [string]$plan.target.size
        # ZONES-1: as the machine's own subscription - zone restrictions and
        # zone numbers belong to it, and a worker drives machines of several.
        $vmSub = Get-VmfSubscriptionId -ResourceId $Context.VmId
        $targetSku = Invoke-VmfAzOperation -Name 'skuCatalog' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            @(Get-VmfSkuCatalog -Location $region -SubscriptionId $vmSub) |
                Where-Object { $_.Name -eq $targetSize } | Select-Object -First 1
        }
        # ZONES-1: a zonal machine runs only on a size Azure offers in its
        # zone. A size can be in the region and not in every zone of it, or
        # restricted in one zone for this subscription. Past here that is a
        # refusal inside the stopped window.
        if ($liveZone) {
            $inZone = Test-VmfSizeInZone -SkuEntry $targetSku -Zone $liveZone -Location $region
            if ($inZone -eq $false) {
                $code = Get-VmfZoneRestrictionCode -SkuEntry $targetSku -Zone $liveZone
                return @{
                    Next = 'NEEDS_DECISION'
                    Reason = 'targetNotInZone'
                    Detail = "Azure does not offer the target size $targetSize in zone $liveZone of $region, where this machine is$(if ($code) { ". Azure gives the reason $code" })."
                }
            }
            if ($null -eq $inZone) {
                $unknown = if ($targetSku) { "The size catalog does not show the zones for $targetSize" } else { "The size catalog for $region does not list $targetSize" }
                Write-VmfEvent -RunPath $Context.RunPath -Step 'precheck' -Outcome info -VmId $Context.VmId `
                    -Detail "$unknown, so this check cannot confirm zone $liveZone."
            }
        }
        $maxNics = Get-VmfSkuMaxNics -SkuEntry $targetSku
        if ($liveNics.Count -gt 1 -and $null -ne $maxNics -and $maxNics -lt $liveNics.Count) {
            return @{
                Next = 'NEEDS_DECISION'
                Reason = 'targetTooFewNics'
                Detail = "This machine has $($liveNics.Count) network interfaces; the target size $($plan.target.size) holds $maxNics."
            }
        }
        # DISK-3: the same last-safe-moment check for data disks. Measured:
        # E8-4ds_v5 holds 32, E8-4ds_v6 holds 24 - a real shrink.
        $maxDataDisks = Get-VmfSkuMaxDataDisks -SkuEntry $targetSku
        if ($liveDataDisks.Count -gt 0 -and $null -ne $maxDataDisks -and $maxDataDisks -lt $liveDataDisks.Count) {
            return @{
                Next = 'NEEDS_DECISION'
                Reason = 'targetTooFewDataDisks'
                Detail = "This machine has $($liveDataDisks.Count) data disks; the target size $($plan.target.size) holds $maxDataDisks."
            }
        }
        # DISK-3: host caching hardware is gone on v6 (measured: 2 of 295
        # sizes have it). Azure keeps the setting, so this is a heads-up
        # about performance, never a refusal.
        $cacheNote = Get-VmfHostCacheNote -DataDisks (@($liveDataDisks) | ForEach-Object {
            [pscustomobject]@{ name = [string]$_.Name; caching = [string]$_.Caching }
        }) -TargetSku $targetSku
        if ($cacheNote) {
            Write-VmfEvent -RunPath $Context.RunPath -Step 'precheck' -Outcome info -VmId $Context.VmId -Detail $cacheNote
        }
    }

    $diskReadErrors = @{}
    $capturedConfig = Get-VmfVmCapture -Vm $vm -DiskReadErrors $diskReadErrors
    # DISK-TYPE-DEALLOCATED-1: every rollback and restore makes each disk on the type
    # recorded here, every rebuild attaches each data disk with its size, and
    # the checks below read the type (a Premium SSD v2 or Ultra Disk, the disk
    # type change). A disk with no type, or a data disk with no size, stops
    # here, untouched, with what Azure said.
    $typeGate = Get-VmfDiskTypeUnknownStop -Capture $capturedConfig -ReadErrors $diskReadErrors
    if ($typeGate) { return $typeGate }
    # SAFETY-ULTRA-1: a Premium SSD v2 or Ultra Disk data disk is put back
    # only with the IOPS, throughput and sector size it has now - read here,
    # from each disk by its id, before anything changes. A disk Azure is still
    # filling from a copy has no instant access copy, so it is refused here.
    $iaGate = Add-VmfInstantAccessDiskFacts -Context $Context -Capture $capturedConfig
    if ($iaGate) { return $iaGate }
    # SAFETY-CMK-1: every disk's encryption type and disk encryption set, read
    # by its id. Each copy and each disk a put-back makes from one is made with
    # these and compared with them. A disk whose key cannot be read exactly is
    # refused here, untouched.
    # ADE-DETECT-ANY-NAME-1: and, from the same read, Azure Disk Encryption on
    # each disk - the only catch for a data disk encrypted with the extension
    # removed or not Succeeded.
    $encGate = Add-VmfDiskEncryptionFacts -Context $Context -Capture $capturedConfig -AdeStops:$adeStops
    if ($encGate) { return $encGate }
    # ROLLBACK-RETRY-CAPTURE-2: a put-back returns a touched machine to its
    # FIRST size, with what it has now. An interface or a data disk added since
    # can be more than that size holds - asked here, before anything changes.
    $putBackGate = Test-VmfPutBackSizeFits -Context $Context -Capture $capturedConfig -Doc $rbDocNow
    if ($putBackGate) { return $putBackGate }
    # AN-ONE-NIC-1: and the TARGET size. A 2-vCPU size allows accelerated
    # networking on one network interface, and the move leaves it on the
    # primary and on every interface that has it now. More than one fails
    # after the stop on every attempt, so it is asked here, untouched.
    $anFitGate = Test-VmfTargetAcceleratedNicsFit -Context $Context -Capture $capturedConfig
    if ($anFitGate) { return $anFitGate }
    # OLD-FAM-1: can the machine's OWN size carry accelerated networking?
    # B1s to B8ms, F1 and the smallest Av2 cannot, and Azure refuses the
    # setting on a network interface of a machine on such a size. The move
    # then turns it on only on the new size, and every rollback and restore turns it off
    # before the old size returns. Null: the catalog did not say.
    # Asked only when the move could turn it on: the primary interface has it off.
    $sourceSku = $null
    $primaryNow = Get-VmfPrimaryNic -Nics $capturedConfig.nics
    if ($primaryNow -and -not [bool]$primaryNow.acceleratedNetworking) {
        $sourceSize = [string]$capturedConfig.size
        $sourceRegion = if ($vm.Location) { [string]$vm.Location } else { [string]$plan.assessment.location }
        $sourceSub = Get-VmfSubscriptionId -ResourceId $Context.VmId
        $sourceSku = Invoke-VmfAzOperation -Name 'skuCatalog' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            @(Get-VmfSkuCatalog -Location $sourceRegion -SubscriptionId $sourceSub) | Where-Object { $_.Name -eq $sourceSize } | Select-Object -First 1
        }
    }
    $sourceAn = Test-VmfSizeTakesAcceleratedNetworking -SkuEntry $sourceSku
    $facts = @{
        vmConfig   = $capturedConfig
        extensions = @($extensions)
        sourceAcceleratedNetworking = $sourceAn
    }
    # ROLLBACK-RETRY-CAPTURE-1: vmConfig is THIS attempt's capture - its
    # copies and its rebuild use the disks it names. The first capture of the
    # machine is kept beside it for every put-back: a retry after a restore or
    # a rebuild finds a machine the product changed, and a put-back to that
    # would not be "as it was". Refreshed only while the product has never
    # touched the machine (a park here, and the customer changed it as asked).
    $docNow = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $original = New-VmfOriginalCaptureRecord -Doc $docNow -Capture $capturedConfig -Extensions @($extensions) -SourceAcceleratedNetworking $sourceAn
    if ($original) { $facts.original = $original }
    Save-VmfCapturedFacts -Context $Context -Facts $facts -ReplaceOriginal:([bool]$original)

    # NIC-JOIN-SCOPE-1: the join on each network interface itself, at its own
    # scope, for EVERY move. The resize and its rollback send the interfaces
    # with the machine, and the interface can be in another resource group,
    # where the machine-scope check above does not reach. Refused while the
    # machine is stopped, the rollback is the same call, so it is asked here.
    $nicJoinGate = Test-VmfNicJoinPermissions -Context $Context -CapturedNics $capturedConfig.nics
    if ($nicJoinGate) { return $nicJoinGate }

    # NIC-JOIN-1: an interface this move will write needs a join on everything
    # it links to - its subnet above all - and Azure checks that on the LINKED
    # resource, which the machine-scope check above never sees. Found inside the
    # stopped window on the first end-to-end run, where it cost a rollback. Here
    # it costs nothing: asked only for interfaces the move will really change,
    # by the same rule CONVERTING uses.
    $linkedGate = Test-VmfNicLinkedPermissions -Context $Context -PlanEntry $plan -CapturedNics $capturedConfig.nics
    if ($linkedGate) { return $linkedGate }
    # SAFETY-CMK-1: and the same for each disk encryption set. A copy or a disk
    # made with a set makes the set a linked scope, which can be in another
    # resource group. Found in the stopped window, it would cost a put-back.
    $desGate = Test-VmfDiskEncryptionSetPermissions -Context $Context -Capture $capturedConfig
    if ($desGate) { return $desGate }
    # ROLLBACK-CRG-1: and the capacity reservation group a put-back returns
    # the machine to, which can be in another resource group too. Found after
    # the stop, a missing grant would cost the machine its group.
    # CRG-JOIN-ATTEMPT-1: and, on a retry, the group of THIS attempt's capture
    # when it is another group - the group the move below acts in.
    $crgGate = Test-VmfReservationJoinPermissions -Context $Context
    if ($crgGate) { return $crgGate }
    # CRG-MOVE-1: and the group the move itself acts in. A machine in a group
    # this migration did not make stays in it through the move, so the group
    # must have a capacity reservation for the target size - Microsoft's own
    # check before a resize. Without one, it stops here, untouched.
    $crgMoveGate = Test-VmfMoveReservationGroup -Context $Context -Capture $capturedConfig -TargetSize ([string]$plan.target.size)
    if ($crgMoveGate) { return $crgMoveGate }
    # UAMI-ASSIGN-1: and each user-assigned managed identity. Every write of
    # the machine assigns it again - on both paths, and in the rollback - and
    # Azure checks the assign on the identity, which can be in another
    # resource group or subscription. MEASURED: found at the first write, it
    # left the machine stopped, because the rollback was refused too.
    $uamiGate = Test-VmfIdentityAssignPermissions -Context $Context -Capture $capturedConfig
    if ($uamiGate) { return $uamiGate }

    # OLD-SKU-1C: disks chosen for Premium SSD. Both checks are answered here,
    # before the first safety copy stops the machine.
    $diskGate = Test-VmfDiskUpgradeReady -Context $Context -PlanEntry $plan -Capture $capturedConfig
    if ($diskGate) { return $diskGate }
    # TARGET-CAPABILITY-PRECHECK-1: and every feature the machine uses -
    # encryption at host, Ultra Disk compatibility in its zone, Premium Storage
    # for a Premium SSD v2 or Ultra Disk - asked of the target size in the live
    # catalog. Azure refuses the resize otherwise, after the stop.
    $featureGate = Test-VmfTargetFeaturesReady -Context $Context -PlanEntry $plan -Capture $capturedConfig
    if ($featureGate) { return $featureGate }


    # PANEL-TRUTH-1: a target that requires accelerated networking, on a
    # machine with it off and no approval in the plan, stops HERE - before the
    # first safety copy stops the machine. It used to stop in Preparing, after
    # that stop and start. The same rule; Preparing keeps its check for the
    # driver half, which needs a reading from inside the machine.
    $anEarly = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $capturedConfig.nics
    if ($anEarly.Stop -and $anEarly.Reason -eq 'acceleratedNetworkingRequired') {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'acceleratedNetworkingRequired'; Detail = $anEarly.Detail }
    }


    # CLUSTER-NOT-RUNNING-1: the power state the machine had before Checking
    # started it for the cluster check. A resume reads running because that
    # check started it; the record says what it was.
    $powerFound = $power
    $clusterPowerRecord = Get-VmfClusterCheckPowerRecord -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
    if ($clusterPowerRecord) { $powerFound = [string]$clusterPowerRecord.power }

    # TEMPCHECK-FIRST-1: files on the temporary disk are asked about HERE,
    # while the machine still runs and before SAFETY_PRISTINE stops it. A stop
    # (deallocation) can empty the temporary disk, so asking after it - as
    # guest preparation used to - could find nothing to lose because it was
    # already lost. A machine that is not running has nothing there to ask
    # about. Nothing has changed the machine yet, and the stop says so.
    # Windows and Linux (LINUX-TEMP-DISK-FILES-1).
    if ($powerFound -eq 'PowerState/running') {
        $tempStop = Get-VmfTempDiskContentStop -Context $Context
        if ($tempStop) { $tempStop.MachineState = 'untouched'; return $tempStop }
    }

    # CLUSTER-DETECT-1: is this machine a cluster node that Azure has no
    # record of? A read-only check inside the machine, before the first
    # safety copy stops it. It is the LAST check that can stop the machine
    # here (re-review of CLUSTER-NOT-RUNNING-1): a machine that is not running
    # is started for it, so every other stop comes first and finds the machine
    # as it was - a machine that parks for another reason is never started,
    # and one that goes on is never left running at a later stop.
    # A cluster node stops here, untouched; an unknown answer stops it too.
    # VF-UNMANAGED-CONFIG-1: on a Linux move with accelerated networking on
    # after it (the decision above), the same start reads whether the network
    # settings set the SR-IOV interface as unmanaged, as Microsoft says. Not
    # set, or no answer, waits for a decision, untouched.
    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: on a start on the new size, the
    # cluster check runs after that start (Get-VmfChecksAfterStartStop).
    $clusterStop = if ($startOnTarget) { $null } else { Get-VmfWorkloadCheckStop -Context $Context -Power $power -SriovCheck:([bool]$anEarly.ExpectFabric -and [string]$plan.assessment.os -eq 'Linux') }

    if ($clusterStop) { return $clusterStop }

    # STATE-TARGET-1: the target this machine starts on, recorded after every
    # check that can park and before anything changes. A resume past this
    # point finishes THIS move (Resolve-VmfStartedTarget). Written every time
    # PRECHECK completes: PRECHECK changes nothing, and it is re-entered only by
    # a fresh attempt - a retry, on the machine as it stands - which starts on
    # whatever the entry says then.
    Save-VmfCapturedFacts -Context $Context -Facts @{ startedTarget = (Get-VmfStartedTarget -PlanEntry $plan) }

    return @{ Next = 'SAFETY_PRISTINE'; Detail = "power=$power" }
}

function Get-VmfSafetyAttempt {
    <#
    .SYNOPSIS
        SAFETY-RETRY-1: which attempt at this machine takes copies now - one
        more than the attempts whose copies were kept on record.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter()][AllowNull()]$Doc)
    if ($Doc -and $Doc.PSObject.Properties['safety'] -and $Doc.safety -and $Doc.safety.PSObject.Properties['earlierCopies']) {
        return @($Doc.safety.earlierCopies).Count + 1
    }
    1
}

function Get-VmfSafetyCopyName {
    <#
    .SYNOPSIS
        SAFETY-RETRY-1: the name of one safety copy. The first attempt keeps
        the names it always had; a later one ends with -a<attempt>, which is
        never cut off by the 75-character limit. SNAPSHOT-NAME-END-1: the name
        never ends with a hyphen (ConvertTo-VmfAzureName).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$Kind,
        [Parameter()][int]$Attempt = 1,
        # SAFETY-ALL-1: a data disk's copy carries its LUN. The OS disk's copy
        # keeps the name it always had.
        [Parameter()][int]$Lun = -1
    )
    $tail = "$(if ($Kind -eq 'pristine') { '-pristine' })$(if ($Lun -ge 0) { "-d$Lun" })$(if ($Attempt -gt 1) { "-a$Attempt" })"
    $base = ('{0}-vmf-{1}' -f $VmName, $RunId) -replace '[^A-Za-z0-9\-]', '-'
    # SNAPSHOT-NAME-END-1: the cut once left a hyphen at the end, and Azure
    # refused the copy. The shared rule cuts and never ends on one.
    ConvertTo-VmfAzureName -Name $base -Suffix $tail -MaxLength 75 -Rule 'snapshot'
}

function Get-VmfStartedTarget {
    <#
    .SYNOPSIS
        STATE-TARGET-1: the parts of a plan entry that decide WHAT a machine
        becomes, and HOW - each one changes what CONVERTING or a rollback does.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)]$PlanEntry)
    $policyValue = { param($name) if ($PlanEntry.policy -and $PlanEntry.policy.PSObject.Properties[$name]) { [string]$PlanEntry.policy.$name } else { '' } }
    # The WHOLE target (size, controller, temporary disk, zone, alternates,
    # choice) - the independent review found the zone missing, which decides
    # the capacity reservation a rebuild lands on - plus the two policy values
    # that follow from the target. size and controller are repeated at the top
    # for the readers that only need those (Restore-VmfVmShell, the report).
    [ordered]@{
        path                  = [string]$PlanEntry.path
        series                = & $policyValue 'targetGeneration'
        acceleratedNetworking = & $policyValue 'acceleratedNetworking'
        # OLD-SKU-1C: the disk types it started to change.
        diskUpgrade           = & $policyValue 'diskUpgrade'
        size                  = [string]$PlanEntry.target.size
        controller            = [string]$PlanEntry.target.controller
        target                = ($PlanEntry.target | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12)
    }
}

function Resolve-VmfStartedTarget {
    <#
    .SYNOPSIS
        STATE-TARGET-1: on a resume past PRECHECK, the plan entry the machine
        must finish on - the one it STARTED on.
    .DESCRIPTION
        A worker runs from the entry it was handed. If a machine is resumed
        after its entry changed - another path, size, controller, disk type or
        series - CONVERTING and the rollback branch on the entry.

        Parking it instead would leave a machine stopped or half changed, so
        a resume finishes the move it started, with the target that was accepted and
        approved, and says so. The changed entry is for the next attempt.
        Returns the entry to use, and what differed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter()][AllowNull()]$Started
    )
    if (-not $Started) { return @{ Entry = $PlanEntry; Changed = @() } }
    $now = Get-VmfStartedTarget -PlanEntry $PlanEntry
    # Named in the product's words, never engine keys (ASD-STE100).
    $pathWords = @{ A = 'in-place upgrade' }
    $say = { param($label, $was, $is) "$label $(if ($is) { $is } else { 'none' }), where it started with $(if ($was) { $was } else { 'none' })" }
    $changed = [System.Collections.Generic.List[string]]::new()
    if ([string]$Started.path -ne [string]$now.path) { $changed.Add((& $say 'the move' $pathWords[[string]$Started.path] $pathWords[[string]$now.path])) }
    if ([string]$Started.series -ne [string]$now.series) { $changed.Add((& $say 'the size series' $Started.series $now.series)) }
    if ([string]$Started.acceleratedNetworking -ne [string]$now.acceleratedNetworking) { $changed.Add((& $say 'the accelerated networking setting' $Started.acceleratedNetworking $now.acceleratedNetworking)) }
    $diskWords = @{ '' = 'no change to the disks'; os = 'Premium SSD for the OS disk'; all = 'Premium SSD for every disk'; 'os-standard-ssd' = 'Standard SSD for the OS disk' }
    $startedDisks = if ($Started.PSObject.Properties['diskUpgrade']) { [string]$Started.diskUpgrade } else { '' }
    if ($startedDisks -ne [string]$now.diskUpgrade) { $changed.Add("the disks: $($diskWords[[string]$now.diskUpgrade]) now, where it started with $($diskWords[$startedDisks])") }
    $targetWords = [ordered]@{ size = 'the size'; controller = 'the disk controller'; diskArch = 'the temporary disk'; zone = 'the zone' }
    $was = $Started.target; $is = $now.target
    foreach ($k in $targetWords.Keys) {
        $w = if ($was -and $was.PSObject.Properties[$k]) { [string]$was.$k } else { '' }
        $i = if ($is -and $is.PSObject.Properties[$k]) { [string]$is.$k } else { '' }
        if ($w -ne $i) { $changed.Add((& $say $targetWords[$k] $w $i)) }
    }
    # Anything else in the target (alternates, the recorded choice) counts too:
    # the whole target is what is put back.
    $rest = { param($t) if (-not $t) { return '' }; $c = $t | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
        foreach ($k in @($targetWords.Keys)) { $c.PSObject.Properties.Remove($k) }; $c | ConvertTo-Json -Depth 12 -Compress }
    if ((& $rest $was) -cne (& $rest $is)) { $changed.Add('the rest of the target') }
    if (-not $changed.Count) { return @{ Entry = $PlanEntry; Changed = @() } }

    # A copy: the plan entry the worker holds is shared with its other reads.
    $entry = $PlanEntry | ConvertTo-Json -Depth 24 | ConvertFrom-Json -Depth 24
    $entry.path = [string]$Started.path
    $entry.target = $Started.target | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    if (-not $entry.policy) { $entry | Add-Member -NotePropertyName policy -NotePropertyValue ([pscustomobject]@{}) -Force }
    foreach ($pair in @(@('targetGeneration', [string]$Started.series), @('acceleratedNetworking', [string]$Started.acceleratedNetworking), @('diskUpgrade', $startedDisks))) {
        if ($pair[1]) { $entry.policy | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] -Force }
        elseif ($entry.policy.PSObject.Properties[$pair[0]]) { $entry.policy.PSObject.Properties.Remove($pair[0]) }
    }
    @{ Entry = $entry; Changed = @($changed) }
}

function Get-VmfSafetyCopyLockNotes {
    <#
    .SYNOPSIS
        SAFETY-3: the sentence on the lock, for whoever finds it in the portal.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmName, [Parameter(Mandatory)][string]$RunId)
    "VMF safety copy of $VmName for migration run $RunId. The product removes this lock and deletes the copy when the wave's accepted retention ends. If you remove this lock by hand, a user can delete this copy. Then a rollback or a restore of this machine cannot use it."
}

function Invoke-VmfSafetyCopyLock {
    <#
    .SYNOPSIS
        SAFETY-3: lock one safety copy, or say plainly why not. Returns
        whether it is locked.
    .DESCRIPTION
        PRECHECK recorded whether this identity may place locks
        (safety.locksAllowed). When it may not, the copy is still taken -
        the migration does not need the lock to be safe, only to be safe
        from OTHER people - and the run page carries the sentence.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][string]$SnapshotName,
        [Parameter(Mandatory)]$Doc
    )
    $refused = $Doc.PSObject.Properties['safety'] -and $Doc.safety -and
               $Doc.safety.PSObject.Properties['locksAllowed'] -and $Doc.safety.locksAllowed -eq $false
    if ($refused) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'lockSnapshot' -Outcome warn -VmId $Context.VmId `
            -Detail "Safety copy $SnapshotName was not locked: the product's managed identity cannot place resource locks. Nothing prevents the deletion of the copy."
        return $false
    }
    $lockNotes = Get-VmfSafetyCopyLockNotes -VmName $Context.VmName -RunId $Context.RunId
    Invoke-VmfAzOperation -Name 'lockSnapshot' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Lock-VmfSnapshot -SnapshotId $SnapshotId -Notes $lockNotes
    } | Out-Null
    $true
}

function Invoke-VmfStepSafetyPristine {
    <#
    SAFETY-2: the "as it was" copy, taken on a STOPPED machine BEFORE guest
    prep touches anything.

    Why it exists: guest prep rewrites the boot path - initramfs and GRUB on
    Linux, boot-driver registry across every ControlSet on Windows. A snapshot
    taken after that is a copy of an already-modified machine, and one taken
    while it runs is crash-consistent on top. Neither is what "put it back"
    means. This costs one extra stop/start, which is accepted for production.

    The stop/start here is harmless to the fused prep/deallocate rule: nothing
    has been prepped yet, so there is nothing a reboot could undo.
    #>
    param([Parameter(Mandatory)]$Context)

    # SAFETYCOPY-CLEAN-1: this step does not read the safety copy setting. It
    # used to skip the copy for `clean`, which left a machine with no rollback;
    # PRECHECK now refuses any entry that does not ask for the copy, and should
    # one ever arrive here regardless, the copy is taken.

    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $onTarget = Get-VmfStartOnTarget -Doc $doc
    # SAFETY-ALL-1: done only when the OS disk AND every data disk have a copy.
    # A kill between them resumes here and takes only what is missing.
    $osOnRecord = [bool]($doc.safety -and $doc.safety.pristineSnapshotId)
    if ($osOnRecord -and (Test-VmfDataCopiesComplete -Doc $doc -Kind 'pristine')) {
        # SAFETY-ULTRA-1: a worker that stopped during the wait for a Premium
        # SSD v2 or Ultra Disk copy resumes here - no new copy, Azure read
        # again. A machine with no such disk makes no call.
        $copyGate = Wait-VmfInstantAccessCopies -Context $Context
        if ($copyGate) { return $copyGate }
        # ROLLBACK-DISKS-FIRST-1 (2026-10-11): a worker that
        # stopped while the rollback disks were made resumes here and
        # gets the same disks; a complete record makes no call.
        $rollbackDisksBeforeMove = New-VmfRollbackDisksBeforeMove -Context $Context
        if ($rollbackDisksBeforeMove) { return $rollbackDisksBeforeMove }
        return @{ Next = 'GUEST_PREP'; Detail = 'The first safety copy was already taken earlier in this migration.' }
    }

    $osDiskId = $doc.captured.vmConfig.osDisk.managedDiskId
    $location = $doc.captured.vmConfig.location
    # SAFETY-CMK-1: the copy asks for the OS disk's own encryption.
    $osEncArgs = Get-VmfEncryptionArgs -Disk $doc.captured.vmConfig.osDisk
    # SAFETY-RETRY-1: each attempt its own name - a snapshot asked for by an
    # existing name comes back as the existing one.
    $snapName = Get-VmfSafetyCopyName -VmName $Context.VmName -RunId $Context.RunId -Kind 'pristine' -Attempt (Get-VmfSafetyAttempt -Doc $doc)

    # Stop FIRST. A snapshot of a running disk is crash-consistent, which is
    # the weakest possible restore point for the one artefact that matters.
    Invoke-VmfAzOperation -Name 'deallocateForPristine' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Stop-VmfVmDeallocated -ResourceGroupName $Context.Rg -Name $Context.VmName
    } | Out-Null

    # FIND-COPY-1: the copy carries what it is on itself, because it outlives
    # this product. Read from the machine's OWN plan entry, like the retention
    # pass does - two waves in one run may have accepted different answers.
    $copyTags = Get-VmfSafetyCopyTags -VmName $Context.VmName -RunId $Context.RunId `
        -RunPath $Context.RunPath -KeepDays (Get-VmfRetentionDays -PlanEntry $Context.Plan)
    if ($osOnRecord) {
        # A resume after the OS copy was taken: only the data disks are left.
        # Stopped first, again - the copies must be of disks nothing writes to,
        # and a stop of a stopped machine is a no-op.
        Invoke-VmfAzOperation -Name 'deallocateForPristine' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Stop-VmfVmDeallocated -ResourceGroupName $Context.Rg -Name $Context.VmName
        } | Out-Null
        $dataCount = Invoke-VmfDataDiskCopies -Context $Context -Kind 'pristine' -Tags $copyTags
        # SAFETY-ULTRA-1: still stopped - every copy usable before the start.
        $copyGate = Wait-VmfInstantAccessCopies -Context $Context
        if ($copyGate) { return $copyGate }
        # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: not on its original size.
        if (-not $onTarget) {
            Invoke-VmfAzOperation -Name 'startAfterPristine' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
            } | Out-Null
        }
        $rollbackDisksBeforeMove = New-VmfRollbackDisksBeforeMove -Context $Context
        if ($rollbackDisksBeforeMove) { return $rollbackDisksBeforeMove }
        return @{ Next = 'GUEST_PREP'; Detail = "The first safety copies of $dataCount $(if ($dataCount -eq 1) { 'data disk are' } else { 'data disks are' }) complete." }
    }
    $snapId = Invoke-VmfAzOperation -Name 'pristineSnapshot' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        New-VmfOsDiskSnapshot -ResourceGroupName $Context.Rg -SnapshotName $snapName `
            -OsDiskId $osDiskId -Location $location -Tags $copyTags @osEncArgs
    }
    # SAFETY-RETRY-1: on record BEFORE the lock. A lock that fails would leave
    # a copy that Azure holds and the record does not, and the next attempt,
    # asking by the same name, would get that copy back.
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $first = if ($doc.safety) { $doc.safety } else { [pscustomobject]@{ snapshotId = $null; cloneVmId = $null } }
    $first | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue $snapId -Force
    $first | Add-Member -NotePropertyName pristineSnapshotLocked -NotePropertyValue $false -Force
    $doc | Add-Member -NotePropertyName safety -NotePropertyValue $first -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc

    # SAFETY-3: locked the moment it exists, so nothing deletes the rollback.
    $locked = Invoke-VmfSafetyCopyLock -Context $Context -SnapshotId $snapId -SnapshotName $snapName -Doc $doc

    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $safety = if ($doc.safety) { $doc.safety } else { [pscustomobject]@{ snapshotId = $null; cloneVmId = $null } }
    $safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue $snapId -Force
    $safety | Add-Member -NotePropertyName pristineSnapshotLocked -NotePropertyValue $locked -Force
    $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc

    # SAFETY-ALL-1: every data disk, at the same stopped moment.
    $dataCount = Invoke-VmfDataDiskCopies -Context $Context -Kind 'pristine' -Tags $copyTags

    # SAFETY-ULTRA-1: the rollback must be usable before anything changes.
    # The machine is still stopped, so a wait loses no write.
    $copyGate = Wait-VmfInstantAccessCopies -Context $Context
    if ($copyGate) { return $copyGate }

    # Back on, so guest prep can run inside it.
    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: not on its original size, which
    # Azure had no capacity for. The machine starts on the new size.
    if (-not $onTarget) {
        Invoke-VmfAzOperation -Name 'startAfterPristine' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
        } | Out-Null
    }

    # ROLLBACK-DISKS-FIRST-1 (2026-10-11): the rollback is
    # BUILT before anything changes. A disk from each first copy, read back,
    # with the machine running again - a disk made from a copy needs no
    # stopped machine. A disk Azure refuses, or one that differs, stops the
    # move here, with nothing on the machine changed.
    $rollbackDisksBeforeMove = New-VmfRollbackDisksBeforeMove -Context $Context
    if ($rollbackDisksBeforeMove) { return $rollbackDisksBeforeMove }

    return @{ Next = 'GUEST_PREP'; Detail = "The first safety copy is $snapName, with $dataCount $(if ($dataCount -eq 1) { 'data disk' } else { 'data disks' })." }
}

function Get-VmfTempDiskContentStop {
    <#
    .SYNOPSIS
        TEMPCHECK-FIRST-1: the stop for files on a machine's SCSI temporary
        disk, or $null. Asked in PRECHECK, while the machine runs and before
        anything stops or changes it (2026-09-28: a move is one change
        window - a machine that stops for a person is left as it was). Asked
        for EVERY target: every move stops (deallocates) the machine, which can
        empty the temporary disk even when the target has one too.
    .DESCRIPTION
        LINUX-TEMP-DISK-FILES-1 (audit 2026-11-14): Windows AND Linux. The wave
        setting onDDataFound shows on every wave, and Microsoft says data on
        the temporary disk might be lost "when you stop the VM", on Linux as on
        Windows (managed-disks-overview, Temporary disk). It was asked only
        for Windows, so a Linux machine lost the files on /mnt with the
        setting at Stop and ask. One stop, one reason, one setting and one
        accept path for both; only the guest script differs.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context)
    $plan = $Context.Plan
    $tempOs = [string]$plan.assessment.os
    if ($tempOs -notin @('Windows', 'Linux') -or $plan.assessment.sourceDiskArch -ne 'scsi-temp') { return $null }
    $tempScript = if ($tempOs -eq 'Linux') { 'temp-disk-content.sh' } else { 'Test-TempDiskContent.ps1' }
    $tc = Invoke-VmfGuestScriptOnVm -ScriptName $tempScript -ResourceGroupName $Context.Rg `
        -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
    if ($tc.result -eq 'BLOCKED') {
        return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The check of the temporary disk inside the machine did not finish: $($tc.error)" }
    }
    # OLD-VERSION-READERS-REMOVE-3: only exactly 'proceed' goes on; any other
    # value stops, as 'stop' does (fail closed).
    if (@($tc.warnings).Count -gt 0 -and -not [string]::Equals([string](Get-VmfPolicy -PlanEntry $plan -Name 'onDDataFound'), 'proceed', [System.StringComparison]::Ordinal)) {
        # Each line is the full path, so it names the drive (D:\) or the mount point (/mnt, /mnt/resource).
        $tempFiles = @($tc.warnings) -join '; '
        $tempDetail = if ($tempOs -eq 'Linux') { "The temporary disk contains these files and folders: $tempFiles" } else { "The temporary disk D: contains these files and folders: $tempFiles" }
        return @{ Next = 'NEEDS_DECISION'; Reason = 'dataOnTempDrive'; Detail = $tempDetail }
    }
    $null
}

function Invoke-VmfPagefileMove {
    <#
    .SYNOPSIS
        Move the page file off the SCSI temporary disk. Returns the stop when
        Move-Pagefile.ps1 is BLOCKED, or $null.
    .DESCRIPTION
        PREP-ROLLBACK-1 (review F7): a BLOCKED run with no FIXED check changed
        nothing - the script records each change as a FIXED check the moment
        it makes it, and reports BLOCKED from its catch with the checks so far.
        When nothing else changed the guest in this attempt either, the stop
        says untouched, and the machine is not rolled back for nothing. Any
        FIXED check, or an earlier change, leaves it to the engine (changed).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context)
    $changedBefore = Test-VmfGuestChangedThisAttempt -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
    $pf = Invoke-VmfGuestScriptOnVm -ScriptName 'Move-Pagefile.ps1' -ResourceGroupName $Context.Rg `
        -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
    if ($pf.result -ne 'BLOCKED') { return $null }
    $stop = @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The move of the Windows page file off the temporary disk did not finish: $($pf.error)" }
    $fixed = @(@($pf.checks) | Where-Object { $_ -and [string]$_.status -eq 'FIXED' })
    if (-not $changedBefore -and -not $fixed.Count) { $stop.MachineState = 'untouched' }
    $stop
}

function Get-VmfScsiMovePrepDetail {
    <#
    .SYNOPSIS
        BSV2-NOTES-1: what GUEST_PREP says when a SCSI move (Get-VmfMoveKind
        'scsi-resize': a v5 or a Bsv2 size) needs no NVMe preparation. Pure.
    .DESCRIPTION
        The move kind says only that the controller stays SCSI. Every move is
        the in-place upgrade (Path A), so the line names it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$PlanEntry)
    $size = [string]$PlanEntry.target.size
    "An $((Get-VmfMoveName -Path 'A').ToLowerInvariant()) to $size. The disk controller stays SCSI, so the machine needs no NVMe preparation."
}

function Get-VmfMoveName {
    <#
    .SYNOPSIS
        BSV2-NOTES-1: the name of a move by its path, as the manual and every
        page name it (understand/how-a-machine-moves.md): 'In-place upgrade'
        for Path A. Pure.
    .DESCRIPTION
        One table, the customer report's ($script:VmfReportMethod), so the
        run history and the report cannot name one move two ways. A test holds
        the pages (UX_PATH, PATH_WORDS, the targets step) to it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Path)
    [string]$script:VmfReportMethod[$Path]
}

function Invoke-VmfStepGuestPrep {
    param([Parameter(Mandatory)]$Context)
    $plan = $Context.Plan
    $os = $plan.assessment.os

    # MANA-LINUX-KERNEL-1: a kernel update failed in this attempt and the
    # worker stopped before the machine went back. Put it back now - never
    # update it again, and never prepare a machine whose update failed.
    $kernelDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if (Test-VmfKernelPutBackPending -Doc $kernelDoc) {
        return @{ Next = 'FAILED_ROLLED_BACK'; PutBack = $true; Reason = 'kernelUpdateFailed'
            Detail = [string](Get-VmfKernelUpdateRecord -Doc $kernelDoc).error }
    }

    $moveKind = Get-VmfMoveKind -PlanEntry $plan

    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: this attempt starts the machine on
    # the new size, so no script runs here - a SCSI move needs no change
    # inside the machine before it (Test-VmfStartOnTargetShape). The checks
    # that read the guest run after the start (Get-VmfChecksAfterStartStop).
    # The accelerated networking decision is saved as for any move, with no
    # driver reading: Checking already stopped a target that requires the
    # setting on a machine with it off, and the driver check runs after the
    # start.
    if (Get-VmfStartOnTarget -Doc $kernelDoc) {
        $onNics = if ($kernelDoc.captured -and $kernelDoc.captured.PSObject.Properties['vmConfig']) { @($kernelDoc.captured.vmConfig.nics) } else { @() }
        $anOn = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $onNics -ManaDriver ''
        Save-VmfCapturedFacts -Context $Context -Facts @{ acceleratedNetworking = @{
                policy = $anOn.Policy; expectFabric = $anOn.ExpectFabric; manaDriver = $null; detail = $anOn.Detail } }
        if ($anOn.Stop) {
            return @{ Next = 'NEEDS_DECISION'; Reason = $(if ($anOn.Reason -eq 'acceleratedNetworkingRequired') { 'acceleratedNetworkingRequired' } else { 'driverBelowFloor' }); Detail = $anOn.Detail; MachineState = 'untouched' }
        }
        return @{ Next = 'STOPPED'; Detail = "The machine starts on $([string]$plan.target.size) after the move. The checks inside the machine run after that start." }
    }

    if ($moveKind -eq 'scsi-reversion') {
        # OLD-STATE-READERS-FINISH-1: this move saves its accelerated
        # networking decision too - the plan's policy, and no fabric expected -
        # so CONVERTING and VALIDATING read the record on every move, and
        # never the plan in its place.
        Save-VmfCapturedFacts -Context $Context -Facts @{ acceleratedNetworking = @{
            policy = (Get-VmfPolicy -PlanEntry $plan -Name 'acceleratedNetworking'); expectFabric = $false; manaDriver = $null; detail = '' } }
        return @{ Next = 'STOPPED'; Detail = 'SCSI target - no guest prep required.' }
    }

    # MANA-LINUX-KERNEL-1 (review finding 2): a kernel update of this attempt
    # is still 'running' on record - the worker stopped after the update
    # script. Start the machine, wait for its agent and read the driver with a
    # guard: a machine that does not come back goes back to its pristine copy,
    # never left on a kernel that does not start.
    $kernelResume = $null
    $kernelOnRecord = Get-VmfKernelUpdateRecord -Doc $kernelDoc
    if ($kernelOnRecord -and [string]$kernelOnRecord.result -eq 'running') {
        $kernelResume = Resume-VmfKernelUpdateReading -Context $Context -Record $kernelOnRecord
        if ($kernelResume.Result) { return $kernelResume.Result }
    }

    # VM must be running for RunCommand
    Invoke-VmfAzOperation -Name 'ensureRunning' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
    } | Out-Null

    # VERIFY-FP-1: the Instance Metadata Service, asked BEFORE anything changes.
    # VALIDATING asks again and fails the move only if it answered here and
    # does not answer there.
    # IMDS-KEEP-2: a retried, resumed or re-prepared GUEST_PREP asks again,
    # and the baseline is the FIRST reading of the attempt, on the untouched
    # machine - like guestBefore below. A later reading never replaces a known
    # one: the preparation can break the network, and a "no" read after it
    # would make the check after the move pass the machine it broke. An
    # unknown on record gives way only to a reading taken before any guest
    # change, which the audit trail says (Test-VmfGuestChangedThisAttempt).
    # A person's retry from the first step starts with none (Clear-VmfRetryState).
    $imdsNow = Get-VmfImdsReading -Context $Context
    $imdsDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $imdsEarlier = if ($imdsDoc.captured -and $imdsDoc.captured.PSObject.Properties['imdsBefore']) { $imdsDoc.captured.imdsBefore } else { $null }
    $imdsKeep = Select-VmfImdsBefore -Earlier $imdsEarlier -Latest $imdsNow -GuestChanged (Test-VmfGuestChangedThisAttempt -Doc $imdsDoc)
    Save-VmfCapturedFacts -Context $Context -Facts @{ imdsBefore = $imdsKeep.Reading }
    $imdsSay = { param($r) switch ([string]$(if ($r) { $r.reached })) { 'yes' { 'the service answered' } 'no' { 'the service did not answer' } default { 'the product could not ask' } } }
    $imdsLine = switch ($imdsKeep.Why) {
        'kept' { "The first Instance Metadata Service reading of this attempt, taken before any change, stays the reading before the move: $(& $imdsSay $imdsKeep.Reading). The reading now: $(& $imdsSay $imdsNow)." }
        'changed' { "A script changed the guest earlier in this attempt, so this Instance Metadata Service reading cannot show the machine as it was. The reading before the move stays unknown. The reading now: $(& $imdsSay $imdsNow)." }
        'replacedUnknown' { "The first Instance Metadata Service reading of this attempt was unknown, and no script has changed the guest yet, so this reading is used: $(& $imdsSay $imdsNow)." }
        default { '' }
    }
    if ($imdsLine) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'GUEST_PREP' -Outcome info -VmId $Context.VmId -Detail $imdsLine
    }

    # VERIFY-FP-1 part 3: the guest's own view BEFORE anything changes - the
    # same read-only script VALIDATING runs, so the evidence record compares
    # like with like. Read once: a resume keeps the first reading, taken on
    # the untouched machine. It is evidence, not a check - a reading that
    # cannot be taken never stops the move. A lost lease still does.
    $prepDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if (-not ($prepDoc.captured -and $prepDoc.captured.PSObject.Properties['guestBefore'])) {
        $viewScript = if ($os -eq 'Windows') { 'Test-GuestValidation.ps1' } else { 'guest-validate.sh' }
        $guestBefore = $null
        try {
            $guestBefore = Invoke-VmfGuestScriptOnVm -ScriptName $viewScript -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath -AsReading
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'GUEST_PREP' -Outcome warn -VmId $Context.VmId `
                -Detail "The product could not read the guest for the evidence record before the move: $($_.Exception.Message)"
        }
        Save-VmfCapturedFacts -Context $Context -Facts @{ guestBefore = $guestBefore }
    }

    # DRIVER-1: check the accelerated-networking driver BEFORE the machine is
    # stopped, while walking away costs nothing. Microsoft is explicit that the
    # platform does not update these drivers in the VM, so a below-floor kernel
    # is a predictable way to land on Boost hardware without accelerated
    # networking. Only a definite FAIL parks; UNKNOWN and INFO are recorded and move
    # on, because this must never block a machine on missing information.
    $driverScript = if ($os -eq 'Windows') { 'Test-ManaReady.ps1' } else { 'mana-check.sh' }
    $driverOut = if ($kernelResume) { $kernelResume.GuestOutput } else {
        Invoke-VmfGuestScriptOnVm -ScriptName $driverScript -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath }
    $driverFacts = ConvertTo-VmfGuestFacts -GuestOutput $driverOut
    if (-not $driverFacts.PSObject.Properties['os']) {
        $driverFacts | Add-Member -NotePropertyName os -NotePropertyValue $os -Force
    }
    # GEN-V5-1: judged against what the target SIZE can give - every v6 and v7
    # size, and Intel v5, can give MANA; AMD v5 cannot.
    $targetMayMana = $moveKind -eq 'nvme-conversion' -or (Test-VmfTargetMayUseMana -SizeName ([string]$plan.target.size)) -ne $false
    $driverVerdict = Get-VmfDriverJudgement -Facts $driverFacts -TargetIsBoost $targetMayMana
    $floorPolicy = Get-VmfPolicy -PlanEntry $plan -Name 'onDriverBelowFloor'
    # OLD-VERSION-READERS-REMOVE-3: exactly 'updateKernel' (ordinal), or the stop.
    $updateKernel = [string]::Equals([string]$floorPolicy, 'updateKernel', [System.StringComparison]::Ordinal)
    # ORACLE-UEK-UPDATE-1 (lab 2026-11-14): a kernel below the floor
    # that the product updates next, as chosen, is said as what happens next,
    # not as FAIL. FAIL stays where the machine will stop.
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome info -VmId $Context.VmId `
        -Detail (Get-VmfDriverCheckLine -Verdict $driverVerdict -UpdateKernel $updateKernel -Os $os -Facts $driverFacts)
    Save-VmfCapturedFacts -Context $Context -Facts @{ driver = @{
        status = $driverVerdict.Status; detail = $driverVerdict.Detail; facts = $driverFacts
    } }
    # AN-PROCEED-NETVSC-1 (2026-11-06): every setting but updateKernel
    # stops here. 'proceed' (Continue) moved a kernel below Microsoft's floor
    # onto hardware whose adapter it cannot drive, and its network ran on the
    # synthetic interface. updateKernel goes on to the update below.
    if ($driverVerdict.Status -eq 'FAIL' -and -not $updateKernel) {
        # PANEL-TRUTH-1's twin, found by ROLLBACK-RETRY-CAPTURE-1's review: the
        # driver reading is read-only and the preparation has not run, so the
        # machine is untouched. Recorded as 'changed' (this step's default),
        # the engine refused its retry and its decision, and the run page told
        # the person to rebuild a machine nothing had changed.
        # KERNEL-OFFER-EDGES-1: where Update the kernel cannot reach the
        # minimum on this machine, the stop says so with its own reason -
        # driverBelowFloor's advice is to choose Update the kernel.
        $belowReach = Get-VmfKernelUpdateReach -Facts $driverFacts
        if ($belowReach) {
            $belowReason = if ($belowReach.Kind -eq 'noRule') { 'kernelUpdateNoRule' } else { 'kernelUpdateCannotReachMinimum' }
            return @{ Next = 'NEEDS_DECISION'; Reason = $belowReason; Detail = "$($driverVerdict.Detail) $($belowReach.Detail)"; MachineState = 'untouched' }
        }
        return @{ Next = 'NEEDS_DECISION'; Reason = 'driverBelowFloor'; Detail = $driverVerdict.Detail; MachineState = 'untouched' }
    }
    # AN-KEEP-1: decide what the move does with accelerated networking NOW,
    # while the machine is running and untouched, and save it - CONVERTING
    # applies it and VALIDATING holds the machine to it. Only a Linux kernel
    # with no MANA driver changes anything (see Resolve-VmfAcceleratedNetworkingForMove).
    $manaDriver = Get-VmfManaDriverPresence -GuestOutput $driverOut -Os $os -Facts $driverFacts
    $prepDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $prepNics = if ($prepDoc.captured -and $prepDoc.captured.PSObject.Properties['vmConfig']) { @($prepDoc.captured.vmConfig.nics) } else { @() }
    $an = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $prepNics -ManaDriver $manaDriver

    # MANA-LINUX-KERNEL-1: a person chose "Update the kernel" for this machine,
    # and the kernel is below Microsoft's floor or has no MANA driver - the two
    # readings that stop the move otherwise. Updated here: after the pristine
    # copy (SAFETY_PRISTINE runs first) and before every script below that
    # prepares the machine, so they prepare the kernel it moves with. Where an
    # update cannot help - a release Microsoft does not list - the machine
    # stops as before, untouched, and the words say why.
    if ($updateKernel -and ($driverVerdict.Status -eq 'FAIL' -or ($an.Stop -and $an.Reason -eq 'driverBelowFloor'))) {
        $missing = if ($driverVerdict.Status -eq 'FAIL') { [string]$driverVerdict.Detail } else { [string]$an.Detail }
        $kernelPlan = Resolve-VmfKernelUpdate -Os $os -Facts $driverFacts
        if (-not $kernelPlan.Update) {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome info -VmId $Context.VmId -Detail $kernelPlan.Detail
            # KERNEL-CHOICE-STOP-ADVICE-1: a release Microsoft does not list has
            # its own reason. driverBelowFloor says to choose Update the kernel,
            # which this machine has; the way out is a release that is listed.
            if ($kernelPlan.Unlisted) {
                return @{ Next = 'NEEDS_DECISION'; Reason = 'releaseNotListedForMana'; Detail = "$missing $($kernelPlan.Detail)"; MachineState = 'untouched' }
            }
            # ORACLE-UEK7-KERNEL-STOP-1: a UEK kernel Microsoft does not list
            # (UEK R7). The release is listed, so the words name the kernel and
            # the UEK R8 repository - never Update the kernel again.
            if ($kernelPlan.UekNotListed) {
                return @{ Next = 'NEEDS_DECISION'; Reason = 'uekKernelNotListedForMana'; Detail = "$missing $($kernelPlan.Detail)"; MachineState = 'untouched' }
            }
            # KERNEL-OFFER-EDGES-1: no rule for the kernel flavour, or an
            # update that cannot reach the minimum - refused before the update
            # script runs, so nothing on the machine changes.
            if ($kernelPlan.NoRule) {
                return @{ Next = 'NEEDS_DECISION'; Reason = 'kernelUpdateNoRule'; Detail = "$missing $($kernelPlan.Detail)"; MachineState = 'untouched' }
            }
            if ($kernelPlan.CannotReach) {
                return @{ Next = 'NEEDS_DECISION'; Reason = 'kernelUpdateCannotReachMinimum'; Detail = "$missing $($kernelPlan.Detail)"; MachineState = 'untouched' }
            }
            return @{ Next = 'NEEDS_DECISION'; Reason = 'driverBelowFloor'; Detail = "$missing $($kernelPlan.Detail)"; MachineState = 'untouched' }
        }
        $kernelUpdated = Invoke-VmfKernelUpdateStep -Context $Context -Facts $driverFacts -TargetMayMana $targetMayMana
        if ($kernelUpdated.Result) { return $kernelUpdated.Result }
        # The machine as it is now, on its new kernel, decides the rest.
        $driverOut = $kernelUpdated.GuestOutput
        $driverFacts = $kernelUpdated.Facts
        $driverVerdict = $kernelUpdated.Verdict
        $manaDriver = $kernelUpdated.Presence
        Save-VmfCapturedFacts -Context $Context -Facts @{ driver = @{
            status = $driverVerdict.Status; detail = $driverVerdict.Detail; facts = $driverFacts
        } }
        $an = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $prepNics -ManaDriver $manaDriver
    }
    elseif ($manaDriver -eq 'present' -and $driverVerdict.Status -ne 'FAIL') {
        # A worker that stopped after the restart: the machine reads as having
        # the driver now, so the update this attempt started is finished.
        Complete-VmfKernelUpdateResume -Context $Context -Facts $driverFacts
    }

    Save-VmfCapturedFacts -Context $Context -Facts @{ acceleratedNetworking = @{
        policy = $an.Policy; expectFabric = $an.ExpectFabric; manaDriver = $manaDriver; detail = $an.Detail
    } }
    if ($an.Detail) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome info -VmId $Context.VmId -Detail $an.Detail
    }
    if ($an.Stop) {
        # PANEL-TRUTH-1: nothing in the guest has been changed yet - the driver
        # reading above is read-only, and the preparation below has not run. Said
        # here, because this step CAN change a machine and would otherwise be
        # recorded as 'changed': the panel then said "This machine is NOT as it
        # was" beside "before anything is changed", and offered to rebuild it.
        if ($an.Reason -eq 'acceleratedNetworkingRequired') {
            return @{ Next = 'NEEDS_DECISION'; Reason = 'acceleratedNetworkingRequired'; Detail = $an.Detail; MachineState = 'untouched' }
        }
        return @{ Next = 'NEEDS_DECISION'; Reason = 'driverBelowFloor'; Detail = $an.Detail; MachineState = 'untouched' }
    }

    # AN-ONE-NIC-2: Checking kept the primary interface off for a release the
    # VM agent reported with no MANA driver. Where the driver read now turns
    # it on after all, the 2-vCPU question is asked again, before any script
    # below changes the guest.
    $prepLocation = if ($prepDoc.captured -and $prepDoc.captured.PSObject.Properties['vmConfig']) { [string]$prepDoc.captured.vmConfig.location } else { '' }
    $anFitNow = Test-VmfGuestPrepAcceleratedNicsFit -Context $Context -CapturedNics $prepNics -Move $an -ManaDriver $manaDriver -Location $prepLocation
    if ($anFitNow) {
        if (Test-VmfGuestChangedThisAttempt -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)) {
            $anFitNow.Detail = ([string]$anFitNow.Detail).Replace(' Nothing on the machine changed.', '')
        }
        else { $anFitNow.MachineState = 'untouched' }
        return $anFitNow
    }

    # MANA-WIN-1: a Windows machine that can land on MANA hardware, with
    # accelerated networking on after the move, gets the MANA driver put in its
    # driver store when the store has none - V5-LAB-1 measured that Windows
    # binds MANA from the store, not from Windows Update. A driver already
    # there is never replaced. Placed BEFORE every script below that changes
    # the guest, so a failed install leaves the machine as it was: only the
    # pristine copy exists, and there is nothing to put back. A re-run after a
    # success finds the driver present and changes nothing.
    if (Test-VmfManaDriverInstallWanted -Os $os -TargetMayMana $targetMayMana -AcceleratedNetworkingAfter ([bool]$an.OnAfter)) {
        $manaOut = Invoke-VmfGuestScriptOnVm -ScriptName 'Install-ManaDriver.ps1' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        $manaPin = @((Get-VmfGuestScript -Name 'Install-ManaDriver.ps1').Packages) | Select-Object -First 1
        $mana = Get-VmfManaDriverInstallOutcome -GuestOutput $manaOut -Package $manaPin
        Save-VmfCapturedFacts -Context $Context -Facts @{ manaDriverInstall = $mana.Record }
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome $(if ($mana.Warn) { 'warn' } else { 'info' }) `
            -VmId $Context.VmId -Detail $mana.Detail
        if ($mana.Stop) {
            # Untouched only when it is true: pnputil added nothing, and no
            # script that changes the guest ran earlier in this attempt (a
            # re-prepare from STOPPED, or a resume, visits this step again).
            # Otherwise the step's own default, changed, is the honest answer.
            $manaStop = @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'manaDriverInstallFailed'; Detail = $mana.Detail }
            # PREP-ROLLBACK-1 (review F7): files pnputil added are a change the
            # audit trail cannot see (a BLOCKED install is not counted there),
            # so this stop says it - and the engine rolls the machine back.
            if ($mana.Added -gt 0) { $manaStop.MachineState = 'changed' }
            elseif (-not (Test-VmfGuestChangedThisAttempt -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId))) {
                $manaStop.MachineState = 'untouched'
            }
            return $manaStop
        }
    }

    # GEN-V5-1: a v5 move changes nothing NVMe. It keeps the storage reading
    # (VALIDATING compares against it) and, on Windows, moves the page file
    # when the temporary disk goes away - that is about the disk, not the
    # controller.
    if ($moveKind -eq 'scsi-resize') {
        $beforeScript = if ($os -eq 'Windows') { 'Test-NvmeReady.ps1' } else { 'nvme-check.sh' }
        $before = Invoke-VmfGuestScriptOnVm -ScriptName $beforeScript -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        Save-VmfCapturedFacts -Context $Context -Facts @{ storageBefore = $before }
        if ($os -eq 'Windows' -and $plan.assessment.sourceDiskArch -eq 'scsi-temp' -and $plan.target.diskArch -ne 'scsi-temp') {
            $pfStop = Invoke-VmfPagefileMove -Context $Context
            if ($pfStop) { return $pfStop }
        }
        # VOLUMES-ONLINE-V5-1 (2026-11-14): every volume mounted before
        # the move is mounted after every start on a new size. On SCSI the disk
        # most likely keeps its device ID, but that is not measured, so a Linux
        # machine whose LVM uses a devices file gets the same one-time start
        # task as a move to NVMe (the NVMe preparation, step 4, one text). It changes the
        # machine, so it is a preparation script (followed by the neutral
        # script), and the machine stops next, with no start between.
        if ($os -ne 'Windows') {
            $lvmTask = Invoke-VmfGuestScriptOnVm -ScriptName 'lvm-devices-task.sh' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
            if ($lvmTask.result -eq 'BLOCKED') {
                # The words of the check that failed, a sentence with its own
                # subject; the script's error alone puts the check name first.
                $why = @(@($lvmTask.checks) | Where-Object { $_ -and [string]$_.status -eq 'FAIL' } | ForEach-Object { [string]$_.detail }) -join ' '
                if (-not $why) { $why = "The script answered: $([string]$lvmTask.error)." }
                return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The product did not complete the Linux preparation for the move. $why" }
            }
        }
        return @{ Next = 'STOPPED'; Detail = (Get-VmfScsiMovePrepDetail -PlanEntry $plan) }
    }

    if ($os -eq 'Windows') {
        $check = Invoke-VmfGuestScriptOnVm -ScriptName 'Test-NvmeReady.ps1' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        # LVM-1 / STORAGE-SPACES-1: keep this reading. It is the only record of
        # what the customer's volume topology looked like BEFORE the move, and
        # VALIDATING has nothing to compare against without it. The ARM capture
        # sees disks; volume groups and storage pools live inside the guest.
        Save-VmfCapturedFacts -Context $Context -Facts @{ storageBefore = $check }
        if ($check.result -eq 'BLOCKED') {
            return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The check of the operating system for NVMe did not finish: $($check.error)" }
        }
        if ($check.result -ne 'READY') {
            $fix = Invoke-VmfGuestScriptOnVm -ScriptName 'Set-NvmeReady.ps1' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
            if ($fix.result -eq 'BLOCKED') {
                return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The preparation of the operating system for NVMe did not finish: $($fix.error)" }
            }
        }

        # Pagefile migration when leaving a scsi-temp source
        if ($plan.assessment.sourceDiskArch -eq 'scsi-temp' -and $plan.target.diskArch -ne 'scsi-temp') {
            $pfStop = Invoke-VmfPagefileMove -Context $Context
            if ($pfStop) { return $pfStop }
        }

        # Temp-disk initializer when landing on an nvme-temp size
        if ($plan.target.diskArch -eq 'nvme-temp' -and $plan.assessment.sourceDiskArch -ne 'nvme-temp') {
            $init = Invoke-VmfGuestScriptOnVm -ScriptName 'Install-TempDiskInit.ps1' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
            if ($init.result -eq 'BLOCKED') {
                return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The install of the task that prepares the temporary disk at each start did not finish: $($init.error)" }
            }
        }
    }
    else {
        # LVM-1: the same pre-migration reading on Linux. nvme-check.sh carries
        # the LVM facts, and running it here is what gives VALIDATING a before.
        $lxCheck = Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-check.sh' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        Save-VmfCapturedFacts -Context $Context -Facts @{ storageBefore = $lxCheck }

        $fix = Invoke-VmfGuestScriptOnVm -ScriptName 'nvme-fix.sh' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        if ($fix.result -eq 'BLOCKED') {
            return @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; Detail = "The preparation of the Linux operating system for NVMe did not finish: $($fix.error)" }
        }
        # LINUX-TEMP-1: record whether this machine has a temporary disk
        # mounted while it still has its OLD hardware. Without it, a /mnt that
        # does not come back can only be noticed afterwards and never compared.
        #
        # LINUX-TEMP-2, found by the Gen1 lab drill 2026-09-25: read from
        # nvme-CHECK.sh, the script that reports it. This read nvme-fix.sh's
        # output, which never carries the answer - so every machine looked like
        # it had no temporary disk, temp-disk-setup.sh was never installed, and
        # a Linux move from a size with a temp disk to a v6 size with one lost
        # /mnt and still passed.
        $tempCheck = @($lxCheck.checks) | Where-Object { [string]$_.name -eq 'temp disk mount' } | Select-Object -First 1
        $hadTempDisk = $null
        if ($tempCheck) {
            $hadTempDisk = ([string]$tempCheck.detail -match '^mounted')
            $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
            $captured = if ($doc.captured) { $doc.captured } else { [pscustomobject]@{} }
            $captured | Add-Member -NotePropertyName tempDiskMounted -NotePropertyValue $hadTempDisk -Force
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue $captured -Force
            Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
        }

        # LINUX-TEMP-1 part 2: install the boot-time initialiser, the twin of
        # the Windows temp-disk task, so the raw NVMe drive is prepared on the
        # first boot of the new size and on every start after it. Installed
        # ONLY for a machine that actually had a temporary disk - a machine
        # born on v6 has no /mnt either (measured), so giving one to a machine
        # that never had it would be a change nobody asked for.
        if ($hadTempDisk -eq $true -and $plan.target.diskArch -eq 'nvme-temp' -and
            $plan.assessment.sourceDiskArch -ne 'nvme-temp') {
            $tempSetup = Invoke-VmfGuestScriptOnVm -ScriptName 'temp-disk-setup.sh' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
            if ($tempSetup.result -eq 'BLOCKED') {
                # Scratch space is never worth failing a healthy migration for.
                # Say so and carry on; VALIDATING reports the drive either way.
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'GUEST_PREP' -Outcome warn -VmId $Context.VmId `
                    -Detail ("The product could not install the task that prepares the temporary disk at each start on the new size " +
                             "($($tempSetup.error)). The rest of the preparation is complete. Anything that uses that drive needs a person to prepare it by hand.")
            }
        }
    }

    return @{ Next = 'STOPPED' }
}

function Invoke-VmfStepSafetyCopy {
    <#
    SAFETY-2: the "ready to convert" copy. Runs AFTER STOPPED, so the machine
    is deallocated and this snapshot is consistent. It captures the machine
    with guest prep applied - which is the right resume point for a failed
    conversion, but is NOT "as it was". The pristine copy taken before prep
    is that, and Restore-VmfVm can pick either.
    #>
    param([Parameter(Mandatory)]$Context)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $osDiskId = $doc.captured.vmConfig.osDisk.managedDiskId
    $location = $doc.captured.vmConfig.location
    # SAFETY-CMK-1: as for the first copy.
    $osEncArgs = Get-VmfEncryptionArgs -Disk $doc.captured.vmConfig.osDisk
    $snapName = Get-VmfSafetyCopyName -VmName $Context.VmName -RunId $Context.RunId -Kind 'prepared' -Attempt (Get-VmfSafetyAttempt -Doc $doc)

    # FIND-COPY-1: as above - both copies of a machine carry the same tags.
    $copyTags = Get-VmfSafetyCopyTags -VmName $Context.VmName -RunId $Context.RunId `
        -RunPath $Context.RunPath -KeepDays (Get-VmfRetentionDays -PlanEntry $Context.Plan)
    $snapId = Invoke-VmfAzOperation -Name 'snapshot' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        New-VmfOsDiskSnapshot -ResourceGroupName $Context.Rg -SnapshotName $snapName `
            -OsDiskId $osDiskId -Location $location -Tags $copyTags @osEncArgs
    }
    # SAFETY-RETRY-1: on record before the lock, as for the pristine copy.
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $first = if ($doc.safety) { $doc.safety } else { [pscustomobject]@{ cloneVmId = $null } }
    $first | Add-Member -NotePropertyName snapshotId -NotePropertyValue $snapId -Force
    $first | Add-Member -NotePropertyName snapshotLocked -NotePropertyValue $false -Force
    $doc | Add-Member -NotePropertyName safety -NotePropertyValue $first -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc

    # SAFETY-3: locked the moment it exists, so nothing deletes the rollback.
    $locked = Invoke-VmfSafetyCopyLock -Context $Context -SnapshotId $snapId -SnapshotName $snapName -Doc $doc

    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    # MERGE, never replace. This used to assign a fresh object, which wiped
    # the pristineSnapshotId written by SAFETY_PRISTINE a few states earlier -
    # so the snapshot existed in Azure but the machine had no record of it, and
    # a pristine restore refused with "no pristine copy". Found by the drill;
    # invisible to every unit test, because each step was correct alone.
    $safety = if ($doc.safety) { $doc.safety } else { [pscustomobject]@{ cloneVmId = $null } }
    $safety | Add-Member -NotePropertyName snapshotId -NotePropertyValue $snapId -Force
    $safety | Add-Member -NotePropertyName snapshotLocked -NotePropertyValue $locked -Force
    if (-not $safety.PSObject.Properties['cloneVmId']) {
        $safety | Add-Member -NotePropertyName cloneVmId -NotePropertyValue $null -Force
    }
    $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc

    # SAFETY-ALL-1: every data disk, with the machine still stopped.
    $dataCount = Invoke-VmfDataDiskCopies -Context $Context -Kind 'prepared' -Tags $copyTags

    return @{ Next = 'CONVERTING'; Detail = "The second safety copy is $snapName, with $dataCount $(if ($dataCount -eq 1) { 'data disk' } else { 'data disks' })." }
}

function Invoke-VmfStepStopped {
    param([Parameter(Mandatory)]$Context)
    $plan = $Context.Plan

    # STORAGE-BEFORE-1. The before-state of the customer's volumes was captured
    # in ONE place, GUEST_PREP. A run that resumes past that step - a machine
    # already at STOPPED from an earlier attempt, or a state doc that predates
    # the capture - never has it, and VALIDATING can then only ever say UNKNOWN.
    # UNKNOWN is the safe verdict, so nobody chased it; the volume drill's
    # Windows machine sat in exactly this shape.
    #
    # VALIDATING cannot go and get a before: by then the guest is on the new
    # controller. THIS is the last moment the machine is up on its original
    # hardware, so this is where an absent before is caught. Reading the doc
    # here costs nothing; the guest call happens only when the capture is
    # missing, so the normal path pays nothing extra.
    #
    # Two invariants the first version of this broke, both pinned by EVAL-M5:
    # a Linux machine is NEVER asked its power state here (that re-verify is a
    # Windows registry problem), so power is read only when a capture is
    # actually absent; and a step handler must cope with no state doc at all
    # (unit tests drive the step directly), so a missing doc simply means there
    # is nothing to compare later and nothing to do now.
    $stateDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $hasBefore = (-not $stateDoc) -or (
        $stateDoc.PSObject.Properties['captured'] -and $stateDoc.captured -and
        $stateDoc.captured.PSObject.Properties['storageBefore'] -and $stateDoc.captured.storageBefore)
    if (-not $hasBefore) {
        $power = Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName
        if ($power -ne 'PowerState/deallocated') {
            $beforeScript = if ($plan.assessment.os -eq 'Windows') { 'Test-NvmeReady.ps1' } else { 'nvme-check.sh' }
            $before = Invoke-VmfGuestScriptOnVm -ScriptName $beforeScript -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
            Save-VmfCapturedFacts -Context $Context -Facts @{ storageBefore = $before }
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'STOPPED' -Outcome info -VmId $Context.VmId `
                -Detail 'This run reached the stop step with no record of the storage volumes. The engine read them now, before the machine stopped.'
        }
        elseif (Get-VmfStartOnTarget -Doc $stateDoc) {
            # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: this attempt never starts
            # the machine on its original size, so it cannot read them.
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'STOPPED' -Outcome warn -VmId $Context.VmId `
                -Detail 'The product has no reading of the storage volumes of this machine from before the move. The machine does not start on its original size in this attempt. The storage check after the move reports UNKNOWN.'
        }
        else {
            # Nothing can be done: the machine is off and its volumes cannot be
            # asked about. Said HERE, where it becomes true, not discovered at
            # the end as a one-word verdict.
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'STOPPED' -Outcome warn -VmId $Context.VmId `
                -Detail 'This run resumed with the machine already stopped and no record of its storage volumes. The engine cannot read them now. The storage check after the move will report UNKNOWN.'
        }
    }

    # FUSED SEQUENCE GUARD: for Windows NVMe conversions, re-verify guest prep
    # IMMEDIATELY before deallocation. Any SCSI boot since prep re-creates
    # StartOverride; converting anyway means INACCESSIBLE_BOOT_DEVICE.
    if ($plan.assessment.os -eq 'Windows' -and $plan.target.controller -eq 'NVMe') {
        $power = Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName
        # EVAL-M5: this re-verified ONLY when the machine was exactly running,
        # while the justification for skipping names exactly one other state -
        # "already deallocated, prep was flushed pre-shutdown". The code applied
        # that justification to stopped, starting, stopping and unknown too. A
        # machine caught at PowerState/starting is BY DEFINITION mid-SCSI-boot,
        # which is precisely when Windows re-creates the stornvme StartOverride,
        # and it was converted without a second look: INACCESSIBLE_BOOT_DEVICE
        # at STARTING, one attempt, a full rollback, a burned window. Invert it -
        # skip only for the state the justification actually covers.
        if ($power -ne 'PowerState/deallocated') {
            $check = Invoke-VmfGuestScriptOnVm -ScriptName 'Test-NvmeReady.ps1' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
            if ($check.result -ne 'READY') {
                # Prep regressed (e.g. a reboot happened) - go back and re-prep.
                return @{ Next = 'GUEST_PREP'; Detail = "Pre-deallocate verify: guest not READY ($($check.result)) - re-prepping." }
            }
        }
        # If already deallocated (resume path), prep state was flushed pre-shutdown - proceed.
    }

    Invoke-VmfAzOperation -Name 'deallocate' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Stop-VmfVmDeallocated -ResourceGroupName $Context.Rg -Name $Context.VmName
    } | Out-Null

    # SAFETY-2: the safety copy comes NEXT, not before - a snapshot of a
    # deallocated disk is consistent, one of a running disk is not.
    return @{ Next = 'SAFETY_COPY'; Detail = 'deallocated' }
}

function Invoke-VmfStepConverting {
    param([Parameter(Mandatory)]$Context)
    $plan = $Context.Plan
    # REBUILD-REMOVE-ENGINE-1: the in-place upgrade is the only move. A wave
    # runs only the entries of path A (Get-VmfWaveOptionsEntries).
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $checkpoint = if ($doc.PSObject.Properties['pathCheckpoint']) { $doc.pathCheckpoint } else { $null }
    $capture = $doc.captured.vmConfig

    # SAFETY-3: the copies are the rollback. Before the first change to the
    # machine, check they are still there - a deleted copy stops the
    # migration here, with the machine untouched, instead of surfacing at
    # restore time.
    $copyIds = @()
    if ($doc.PSObject.Properties['safety'] -and $doc.safety) {
        foreach ($prop in 'pristineSnapshotId', 'snapshotId') {
            if ($doc.safety.PSObject.Properties[$prop] -and $doc.safety.$prop) { $copyIds += [string]$doc.safety.$prop }
        }
        # SAFETY-ALL-1: every data disk's copies are the rollback too.
        foreach ($kind in 'pristine', 'prepared') {
            $copyIds += @(Get-VmfDataCopies -Doc $doc -Kind $kind | ForEach-Object { [string]$_.snapshotId } | Where-Object { $_ })
        }
    }
    if ($copyIds.Count) {
        $missing = @(Invoke-VmfAzOperation -Name 'verifySafetyCopies' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            @($copyIds | Where-Object { -not (Test-VmfSnapshotExists -SnapshotId $_) })
        })
        if ($missing.Count) {
            throw "Safety copy missing before the machine is changed: $($missing -join ', '). The machine is unchanged."
        }
    }
    # SAFETY-ULTRA-1: the rollback must last through the move. Asked only
    # before the first change of CONVERTING (no checkpoint yet), and before
    # accelerated networking below: past that, finishing or putting back is
    # the fastest way out.
    if (-not $checkpoint) {
        $windowStop = Test-VmfCopyWindowBeforeConversion -Context $Context -Doc $doc
        if ($windowStop) { return $windowStop }
        # The review of SAFETY-ULTRA-1: the conversion starts here, and the
        # record says so BEFORE its first change (accelerated networking,
        # below). A worker that stopped after that change resumed with no
        # checkpoint, ran the check above again and, with less time left,
        # could stop the machine as "unchanged" while its interfaces had
        # changed. A resume past this point goes on to finish or roll back.
        Update-VmfPathCheckpoint -Context $Context -Checkpoint 'converting:started'
        $checkpoint = 'converting:started'
    }

    # AN-1: enforce accelerated networking in the deallocated window (both paths).
    # MANA requires AN on the NIC (MS guidance); default ensureOn for NVMe targets.
    # AN-KEEP-1: the policy is the one GUEST_PREP decided and saved.
    $anPolicy = (Get-VmfAcceleratedNetworkingDecision -Doc $doc).Policy
    # NIC-1: accelerated networking is capped BY SIZE, not per NIC - a
    # 2-vCPU size permits it on exactly one interface. Asking for it on
    # every NIC is an ARM rejection inside the deallocated window, so
    # ensureOn touches only the primary and leaves the rest as captured.
    $applyAn = {
        foreach ($change in @(Get-VmfNicAnPlan -CapturedNics $capture.nics -Policy $anPolicy)) {
            $nicId = [string]$change.id
            $nicWant = [bool]$change.enabled
            Invoke-VmfAzOperation -Name 'nicAccelNet' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Set-VmfNicAcceleratedNetworking -NicId $nicId -Enabled $nicWant
            } | Out-Null
        }
    }
    # OLD-FAM-1: a source size that cannot carry accelerated networking gets
    # it only once it is on the new size - never while the old size holds them.
    $anLater = (Get-VmfSourceAcceleratedNetworking -Doc $doc) -eq $false
    if ($anPolicy -ne 'preserve' -and -not $anLater) { & $applyAn }
    $diskRg = ($capture.osDisk.managedDiskId -split '/')[4]
    $diskName = $capture.osDisk.name
    $types = if ($plan.target.controller -eq 'NVMe') { 'SCSI, NVMe' } else { 'SCSI' }
    # GEN-V5-1: a v5 move touches no disk controller setting. The disk needs no
    # new controller, and the machine is given none: a Generation 1 machine
    # has no setting, and Azure refuses one (ROLLBACK-NULL-1). An empty
    # controller also moves a machine that is on NVMe now back to SCSI.
    $isV5 = (Get-VmfMoveKind -PlanEntry $plan) -eq 'scsi-resize'
    $vmController = if ($isV5) { '' } else { [string]$plan.target.controller }

    # ODCR association: when this entry's cell has a RESERVED claim, land the VM
    # on reserved capacity (association requires the deallocated window).
    # Azure does NOT support capacity-reservation association for VMs in
    # availability sets - AvSet members convert on general capacity and their
    # claim slots stay unconsumed.
    $inAvset = [bool]($plan.assessment.PSObject.Properties['availabilitySetId'] -and
        [string]$plan.assessment.availabilitySetId)
    $waveClaim = if ($inAvset) { $null } else { Get-VmfClaimForEntry -RunPath $Context.RunPath -Entry $plan }
    # CRG-MOVE-1: a machine in a capacity reservation group this migration did
    # not make stays in it - PRECHECK checked that the group has a capacity
    # reservation for the target size. The resize leaves it there, and the
    # wave's reservation does not replace it.
    $productGroupIds = @(Get-VmfProductReservationGroupIds -RunPath $Context.RunPath)
    $ownGroup = Get-VmfOwnReservationGroup -Capture $capture -ProductGroupIds $productGroupIds
    # CRG-MOVE-DEMAND-1: the wave's reservation holds a place only for a
    # machine the one rule counted (Test-VmfEntryReservable on the plan entry -
    # what Check the quota counted). A machine the assessment found in its own
    # group got no place; if it is in no group now, joining the wave's group
    # would take a place reserved for another machine, so the reserved count
    # would be lower than the machines that join. It moves with no capacity
    # reservation, and the activity says why.
    $counted = Test-VmfEntryReservable -Entry $plan -ProductGroupIds $productGroupIds
    $plannedOwn = if ($inAvset) { $null } else { Get-VmfOwnReservationGroup -Capture $plan.assessment -ProductGroupIds $productGroupIds }
    $reservedClaim = if ($ownGroup -or -not $counted) { $null } else { $waveClaim }
    if ($ownGroup) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'odcr' -Outcome info -VmId $Context.VmId `
            -Detail ("The machine stays in its capacity reservation group '$(Get-VmfReservationGroupName $ownGroup)'." +
                     $(if ($waveClaim) { ' The capacity reservation of the wave is not used for this machine.' } else { '' }))
    }
    elseif ($inAvset) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'odcr' -Outcome warn -VmId $Context.VmId `
            -Detail 'The machine is in an availability set, so Azure does not allow an on-demand capacity reservation for it.'
    }
    elseif ($plannedOwn) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'odcr' -Outcome warn -VmId $Context.VmId `
            -Detail ("The assessment found the machine in the capacity reservation group '$(Get-VmfReservationGroupName $plannedOwn)', " +
                     'so the capacity reservation of the wave holds no place for it. The machine is no longer in that group, so it moves with no capacity reservation.')
    }
    elseif (-not $reservedClaim) {
        # ID-ADDRESS-1 review: the match now asks the machine's own
        # subscription, so a wave that holds a reservation of this size can
        # still have none this machine may use. Say so; never a silent move on
        # general capacity in a wave somebody reserved.
        $sameCell = @(foreach ($n in @(Get-VmfStoreNames -RunPath $Context.RunPath -Folder 'capacity' -Extension '.json')) {
                $c = Read-VmfStoreJson -RunPath $Context.RunPath -RelPath "capacity/$n" -Depth 12
                if ($c -and $c.state -eq 'RESERVED' -and $c.wave -eq $plan.wave -and $c.size -eq $plan.target.size) { $c }
            })
        if ($sameCell.Count -gt 0) {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'odcr' -Outcome warn -VmId $Context.VmId `
                -Detail ("The wave holds a capacity reservation of $($plan.target.size), but none in this machine's subscription, region and zone. " +
                         'This machine moves with no capacity reservation.')
        }
    }

    if ($checkpoint -notin @('A:diskPatched')) {
        if (-not $isV5) {
            Invoke-VmfAzOperation -Name 'diskPatch' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Set-VmfOsDiskControllerTypes -DiskResourceGroup $diskRg -DiskName $diskName -ControllerTypes $types
            } | Out-Null
        }
        Update-VmfPathCheckpoint -Context $Context -Checkpoint 'A:diskPatched'
    }
    # ORDER (found by REH-1 on real Azure): resize FIRST, associate SECOND.
    # Association validates the VM's CURRENT size against the group's
    # reservations, so associating while still on the source size 409s
    # ("Capacity Reservation with VM size <source> does not exist").
    # Both happen in the deallocated window, so the reservation still
    # guarantees the START.
    Invoke-VmfAzOperation -Name 'resize' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Set-VmfVmSizeAndController -ResourceGroupName $Context.Rg -Name $Context.VmName `
            -Size $plan.target.size -Controller $vmController
    } | Out-Null
    # OLD-SKU-1C: on the new size, which takes Premium SSD; still stopped.
    Invoke-VmfDiskTypeUpgrade -Context $Context -Capture $capture -PlanEntry $plan
    if ($anPolicy -ne 'preserve' -and $anLater) { & $applyAn }
    if ($reservedClaim) {
        Invoke-VmfAzOperation -Name 'odcrAssociate' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Set-VmfVmCapacityReservationGroup -ResourceGroupName $Context.Rg -Name $Context.VmName `
                -GroupId $reservedClaim.Claim.reservation.groupId
        } | Out-Null
        Add-VmfClaimAssociation -RunPath $Context.RunPath -ClaimRelPath $reservedClaim.RelPath -VmId $Context.VmId
    }
    # BSV2-NOTES-1: named as the manual and the report name it.
    return @{ Next = 'STARTING'; Detail = "$(Get-VmfMoveName -Path 'A') to $([string]$plan.target.size) is complete." }
}

function Invoke-VmfStepStarting {
    param([Parameter(Mandatory)]$Context)
    Invoke-VmfAzOperation -Name 'start' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
    } | Out-Null
    Wait-VmfVmAgentReady -ResourceGroupName $Context.Rg -Name $Context.VmName

    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: the machine started on the new size
    # with no start on its original size, so the checks that read the guest
    # run now. A check that stops is a full rollback (RollBack): the safety
    # copies are new copies of the original disks, and the size goes back.
    # Each check only reads (the LVM refresh changes only a list a disk made
    # from a copy needs), so a resume runs them again.
    $startDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $onTarget = Get-VmfStartOnTarget -Doc $startDoc
    if ($onTarget) {
        # POWER-ONLY-CHANGED-1: a machine that owed the power state running
        # runs again - on the new size. Said once, so a rollback after this
        # line does not name a power state the machine has.
        if (Get-VmfPowerOwed -Doc $startDoc) {
            Add-VmfStateTransition -RunPath $Context.RunPath -VmId $Context.VmId -NewState 'STARTING' -Outcome ok -MachineState 'changed' `
                -Detail "The machine runs on $([string]$Context.Plan.target.size) now. It ran before the earlier move too." | Out-Null
        }
        $afterStart = Get-VmfChecksAfterStartStop -Context $Context -Record $onTarget
        if ($afterStart) { return $afterStart }
    }

    # UPST-2, MEASURED on vmf-upst2-win: Windows resets stornvme's
    # IoTimeoutValue on the FIRST boot on NVMe. Prep set 240 in both
    # ControlSets; after the conversion the set it booted from read 10 and the
    # other still read 240. Microsoft's changelog says the same and ships a
    # post-conversion command for it.
    #
    # It has to happen HERE - after the boot that resets it, before VALIDATING
    # judges the machine. Setting it earlier cannot survive, which is the whole
    # point of the finding.
    #
    # A machine left at 10 is not visibly broken. It is a machine that will drop
    # a disk under a transient stall it should have ridden out, which is why
    # this is not left as an advisory.
    if ($Context.Plan.assessment.os -eq 'Windows' -and $Context.Plan.target.controller -eq 'NVMe') {
        $repair = Invoke-VmfGuestScriptOnVm -ScriptName 'Repair-NvmeIoTimeout.ps1' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        if ($repair.result -eq 'BLOCKED') {
            throw "Could not restore the NVMe I/O timeout after the first boot: $($repair.error)"
        }
        # GUEST-2: the guest states this as a declared FACT now -
        # "ControlSet001=10 ControlSet002=240" - rather than one check per
        # ControlSet with a name the contract could never describe.
        $facts = ConvertTo-VmfGuestFacts -GuestOutput $repair
        $before = [string]$facts.ioTimeoutBefore
        if ($before) {
            $wasReset = @(($before -split '\s+') | Where-Object { $_ -and ($_ -split '=')[1] -ne '240' })
            if ($wasReset.Count -gt 0) {
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'STARTING' -Outcome info -VmId $Context.VmId `
                    -Detail "the first boot on NVMe reset the disk I/O timeout in $($wasReset.Count) of the machine's boot configurations ($before) - restored to 240 seconds, which is what Azure NVMe expects"
            }
        }
    }

    return @{ Next = 'VALIDATING' }
}

function Invoke-VmfStepValidating {
    param([Parameter(Mandatory)]$Context)
    $isWindowsGuest = $Context.Plan.assessment.os -eq 'Windows'

    $validationScript = if ($isWindowsGuest) { 'Test-GuestValidation.ps1' } else { 'guest-validate.sh' }
    $result = Invoke-VmfGuestScriptOnVm -ScriptName $validationScript -ResourceGroupName $Context.Rg `
        -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
    # LINUX-TEMP-1: the temporary disk is COMPARED, never failed on. It is
    # scratch space that the move wipes by definition; what matters is telling
    # the operator when a machine that had one no longer does, because anything
    # configured to use it - swap most often - will not find it.
    $stateDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    # VOLUMES-ONLINE-WINDOWS-1: a data disk that was online before the move
    # (captured.guestBefore) and starts offline on the new size is brought
    # online before anything is judged, then the machine is read again - the
    # Windows twin of the Linux start task (nvme-fix.sh step 4).
    if ($isWindowsGuest) {
        $readBefore = if ($stateDoc.captured -and $stateDoc.captured.PSObject.Properties['guestBefore']) { $stateDoc.captured.guestBefore } else { $null }
        $online = Invoke-VmfWindowsDisksOnline -RunPath $Context.RunPath -VmId $Context.VmId -ResourceGroupName $Context.Rg -VmName $Context.VmName `
            -Before $readBefore -After $result -Step 'VALIDATING'
        if ($online.Changed) {
            $result = Invoke-VmfGuestScriptOnVm -ScriptName $validationScript -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        }
    }
    $capturedTemp = if ($stateDoc.captured -and $stateDoc.captured.PSObject.Properties['tempDiskMounted']) {
        [bool]$stateDoc.captured.tempDiskMounted
    } else { $null }
    $tempOutcome = Test-VmfTempDiskOutcome -CapturedMounted $capturedTemp -Checks $result.checks

    # LVM-1 / STORAGE-SPACES-1: did the customer's volume groups
    # and storage pools come back? Nothing else in this step can see it - a data
    # volume group is not boot-critical, so a machine that lost one boots, reports
    # its agent Ready, passes every check above, and is missing the filesystem
    # the application actually uses.
    #
    # This one FAILS, where the temp disk above only reports. The difference is
    # that the temporary disk is scratch the move wipes by definition, and a
    # data volume is the customer's data. Under FAIL-1 a failure here puts the
    # machine back on its original hardware with its pristine disk, which is
    # exactly what somebody would want on discovering a volume missing.
    $storageBefore = if ($stateDoc.captured -and $stateDoc.captured.PSObject.Properties['storageBefore']) {
        $stateDoc.captured.storageBefore
    } else { $null }
    $storage = Test-VmfStorageTopology -Before $storageBefore -After $result
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' -Outcome info -VmId $Context.VmId `
        -Detail "storage volumes: $($storage.Verdict) - $($storage.Detail)"
    #
    # It THROWS rather than returning a terminal state. Every other validation
    # failure here throws, and that is not a style choice: rollback is driven by
    # the exception path, so returning FAILED_ROLLED_BACK directly would record
    # a machine as "put back" WITHOUT PUTTING IT BACK - a lie of exactly the
    # kind this project keeps finding. Caught in review before it shipped.
    if (-not $storage.Ok) {
        throw "Storage volumes are missing after the move: $($storage.Detail)"
    }
    # VOLUMES-ONLINE-1: and every volume the machine had mounted before the
    # move - on Windows and Linux, a plain disk too, not only a volume group
    # or a pool. Compared with the reading of this same script before
    # anything changed (captured.guestBefore). The final lab found
    # /var/crash not mounted on NVMe; this names it, with the reason the
    # stop above gives (storageVolumesLost), and throws like it so the
    # machine is put back.
    $guestBefore = if ($stateDoc.captured -and $stateDoc.captured.PSObject.Properties['guestBefore']) { $stateDoc.captured.guestBefore } else { $null }
    $mountedBack = Test-VmfVolumesBack -Before $guestBefore -After $result -CaseSensitive:(-not $isWindowsGuest)
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' -Outcome info -VmId $Context.VmId `
        -Detail "mounted volumes: $($mountedBack.Verdict) - $($mountedBack.Detail)"
    if (-not $mountedBack.Ok) {
        throw "Storage volumes are missing after the move: $($mountedBack.Detail)"
    }

    # VERIFY-FP-1: the Instance Metadata Service answers only on the primary
    # network interface, and says which size the machine is on. It THROWS on a
    # failure, as every validation here does - rollback is driven by the
    # exception path.
    $imdsBefore = if ($stateDoc.captured -and $stateDoc.captured.PSObject.Properties['imdsBefore']) { $stateDoc.captured.imdsBefore } else { $null }
    $imdsAfter = Get-VmfImdsReading -Context $Context
    $imds = Test-VmfImdsOutcome -Before $imdsBefore -After $imdsAfter -TargetSize ([string]$Context.Plan.target.size)
    # A failure is written once, by the step that catches the throw.
    if (-not $imds.Ok) { throw $imds.Detail }
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' -Outcome info -VmId $Context.VmId -Detail $imds.Detail
    if ($tempOutcome.Changed) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' -Outcome warn -VmId $Context.VmId `
            -Detail $tempOutcome.Detail
    }

    if ($result.result -ne 'PASS') {
        $failed = @($result.checks | Where-Object status -eq 'FAIL' | ForEach-Object { $_.name }) -join ', '
        throw "These checks inside the machine failed: $failed."
    }

    # Boot-bus judgment: the guest reports the bus as a fact; the ENGINE asserts
    # it matches the plan's target controller (so SCSI reversions validate too).
    $busCheckName = if ($isWindowsGuest) { 'boot disk bus' } else { 'root device bus' }
    $busCheck = @($result.checks) | Where-Object { $_.name -eq $busCheckName } | Select-Object -First 1
    if (-not $busCheck) { throw "The checks inside the machine did not report the $busCheckName, so the product cannot confirm the disk controller." }
    $busIsNvme = $busCheck.detail -match '(?i)nvme' -and $busCheck.detail -notmatch '(?i)non-nvme'
    $wantNvme = $Context.Plan.target.controller -eq 'NVMe'
    if ($busIsNvme -ne $wantNvme) {
        throw "The checks inside the machine report the boot disk on '$($busCheck.detail)', and the disk controller of the target is $($Context.Plan.target.controller)."
    }

    # NIC-1: every network interface must have come back, in the same order,
    # with the same primary. A recreate that quietly drops or reorders an
    # adapter leaves a running machine with the wrong network identity - the
    # kind of damage that is only noticed by whatever stops being reachable.
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $capturedNics = @($doc.captured.vmConfig.nics)
    if ($capturedNics.Count -gt 0) {
        $liveVm = Invoke-VmfAzOperation -Name 'getVmNics' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName
        }
        $liveNics = @(foreach ($n in @($liveVm.NetworkProfile.NetworkInterfaces)) {
            [pscustomobject]@{ id = [string]$n.Id; primary = [bool]$n.Primary }
        })
        # A single-NIC machine reports Primary=$false in ARM; it is primary by
        # definition, so compare the shape the capture recorded.
        if ($capturedNics.Count -eq 1 -and $liveNics.Count -eq 1) {
            $liveNics[0].primary = [bool]$capturedNics[0].primary
        }
        $fidelity = Test-VmfNicFidelity -Captured $capturedNics -Live $liveNics
        if (-not $fidelity.Ok) { throw "The check of the network interfaces failed: $($fidelity.Detail)" }
    }

    # TRUST-1: the security posture survived - proven, not assumed. The
    # in-place upgrade should never change it, which is exactly why it is
    # checked - "should never" is an assumption, and this
    # step exists to retire assumptions. An UNKNOWN verdict (a capture from
    # before the field existed) is reported as info, never invented into a
    # pass or a fail.
    $capturedSecurity = $doc.captured.vmConfig.securityProfile
    $liveSecVm = Invoke-VmfAzOperation -Name 'getSecurityProfile' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName
    }
    $liveSecurity = if ($liveSecVm.SecurityProfile) {
        [pscustomobject]@{
            securityType      = [string]$liveSecVm.SecurityProfile.SecurityType
            secureBootEnabled = if ($liveSecVm.SecurityProfile.UefiSettings) { [bool]$liveSecVm.SecurityProfile.UefiSettings.SecureBootEnabled } else { $null }
            vTpmEnabled       = if ($liveSecVm.SecurityProfile.UefiSettings) { [bool]$liveSecVm.SecurityProfile.UefiSettings.VTpmEnabled } else { $null }
        }
    } else { $null }
    $secCheck = Test-VmfSecurityFidelity -Captured $capturedSecurity -Live $liveSecurity
    if (-not $secCheck.Ok) { throw "The check of the security settings failed: $($secCheck.Detail)" }
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' `
        -Outcome $(if ($secCheck.Verdict -eq 'UNKNOWN') { 'warn' } else { 'ok' }) -VmId $Context.VmId `
        -Detail $secCheck.Detail

    # EVAL-C1/H2: the rebuild replays a hand-maintained list of properties, and
    # two of them were missing for months because nothing compared. Managed
    # identity is the only loss in this system that cannot be undone: deleting a
    # VM destroys its service principal, so every role assignment naming it is
    # orphaned. Compare, so the NEXT one somebody forgets fails here instead of
    # being reported as a successful migration.
    $liveIdentity = Invoke-VmfAzOperation -Name 'getIdentityFacts' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfVmIdentityFacts -ResourceGroupName $Context.Rg -Name $Context.VmName
    }
    # REBUILD-REMOVE-ENGINE-1: the in-place upgrade keeps the definition, so a
    # machine keeps its identity - a new object ID is a failure, and nothing
    # excuses it (the acceptance of an identity loss went with the rebuild).
    $rebuildCheck = Test-VmfRebuildFidelity -Captured $doc.captured.vmConfig -Live $liveIdentity
    if (-not $rebuildCheck.Ok) { throw "The check of the machine against its capture failed: $($rebuildCheck.Detail)" }
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' `
        -Outcome $(if ($rebuildCheck.Verdict -eq 'UNKNOWN') { 'warn' } else { 'ok' }) -VmId $Context.VmId `
        -Detail $rebuildCheck.Detail

    # DISK-3: every data disk back on its own LUN with its own cache mode.
    # Applications and mount tooling address disks BY LUN, so a shuffle is
    # silent damage - the machine runs, with the wrong disk in the wrong place.
    $capturedDataDisks = @($doc.captured.vmConfig.dataDisks)
    if ($capturedDataDisks.Count -gt 0) {
        $liveVmDisks = Invoke-VmfAzOperation -Name 'getVmDataDisks' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName
        }
        $liveDataDisks = @(foreach ($d in @($liveVmDisks.StorageProfile.DataDisks)) {
            [pscustomobject]@{
                name = [string]$d.Name; lun = [int]$d.Lun
                caching = [string]$d.Caching; managedDiskId = [string]$d.ManagedDisk.Id
            }
        })
        $diskCheck = Test-VmfDataDiskFidelity -Captured $capturedDataDisks -Live $liveDataDisks
        if (-not $diskCheck.Ok) { throw "The check of the data disks failed: $($diskCheck.Detail)" }
    }

    # REBUILD-PROPS-1: the patch settings,
    # the Spot settings, encryption at host, the boot diagnostics account and
    # each delete option, caching and Write Accelerator - compared, so a
    # setting the move changed fails here instead of passing.
    $liveSettingsVm = Invoke-VmfAzOperation -Name 'getRebuildSettings' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName
    }
    $settingsCheck = Test-VmfRebuildSettingsFidelity -Captured $doc.captured.vmConfig -Live (Get-VmfRebuildSettingsFromVm -Vm $liveSettingsVm)
    if (-not $settingsCheck.Ok) { throw "The check of the machine settings failed: $($settingsCheck.Detail)" }
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' `
        -Outcome ok -VmId $Context.VmId `
        -Detail $settingsCheck.Detail

    # AN-1 + NIC-1: the primary must carry accelerated networking, and no NIC
    # may have silently LOST it. The engine never demands it on a secondary
    # NIC that never had it - the size may not even permit that.
    # AN-KEEP-1: held to the decision GUEST_PREP saved, the same one CONVERTING applied.
    $anDecision = Get-VmfAcceleratedNetworkingDecision -Doc $doc
    $anPolicy = $anDecision.Policy
    if ($anPolicy -ne 'preserve' -and $capturedNics.Count -gt 0) {
        $liveAn = @(foreach ($nic in $capturedNics) {
            $nicName = ($nic.id -split '/')[-1]
            $nicRg = ($nic.id -split '/')[4]
            $live = Invoke-VmfAzOperation -Name "getNic:$nicName" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfNetworkInterface -Name $nicName -ResourceGroupName $nicRg
            }
            [pscustomobject]@{ id = [string]$nic.id; acceleratedNetworking = [bool]$live.EnableAcceleratedNetworking }
        })
        $anCheck = Test-VmfNicAcceleratedNetworking -Captured $capturedNics -Live $liveAn -Policy $anPolicy
        if (-not $anCheck.Ok) { throw "The check of accelerated networking failed: $($anCheck.Detail)" }
    }

    # VAL-1: on NVMe (Boost) targets, ACCELERATED NETWORKING must be live
    # post-migration. The fabric is host-dependent: most v6 hosts bind MANA,
    # but some clusters (observed: E2ads_v6/AMD, REH-2) serve accelerated
    # networking via a classic SR-IOV VF (Mellanox) instead - equally healthy.
    # Guests report both fabrics as facts; the engine accepts either and
    # records which one carried the VM.
    # AN-KEEP-1: unless the plan kept accelerated networking OFF on purpose -
    # then there is no MANA or SR-IOV virtual function to find, and demanding one failed a healthy
    # machine (the drill's Ubuntu 18.04).
    # GEN-V5-1: asked of every move but a reversion. A v5 host may serve MANA or
    # Mellanox - it differs by region and by host - so either counts.
    if ((Get-VmfMoveKind -PlanEntry $Context.Plan) -ne 'scsi-reversion' -and -not $anDecision.ExpectFabric) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome info -VmId $Context.VmId `
            -Detail (Get-VmfAnNotCheckedDetail -Policy $anDecision.Policy)
    }
    # AN-AMDV7-VF-GAP-1: a first read with no adapter waits for it - a read
    # every 30 seconds for up to 15 minutes (the engine's settings,
    # $script:VmfAnAdapterWait), checkpointed - before the step fails. On AMD
    # Standard_D2as_v7 the virtual function was late on 9 of 20 starts.
    $mana = $null
    if ($anDecision.ExpectFabric) {
        $manaScript = if ($isWindowsGuest) { 'Test-ManaReady.ps1' } else { 'mana-check.sh' }
        $adapter = Wait-VmfAcceleratedAdapter -Context $Context -ScriptName $manaScript
        $mana = $adapter.Reading
        # AN-TRAFFIC-VERIFY-1 (2026-11-14: never NetVSC): "in use" is
        # said only when the virtual function counters showed traffic. The
        # wait above fails an adapter whose counters show none; counters the
        # guest could not read are said, and do not stop the move - the same
        # as an Instance Metadata Service reading with no answer.
        $sawTraffic = $adapter.Traffic -and $adapter.Traffic.Verdict -eq 'yes'
        if ($adapter.Fabric.Fabric -eq 'mana') {
            if ($sawTraffic) {
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome ok -VmId $Context.VmId `
                    -Detail 'The network adapter is MANA, and accelerated networking is in use.'
            }
            else {
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome warn -VmId $Context.VmId `
                    -Detail 'The network adapter is MANA. The product could not read its traffic counters, so it cannot say that accelerated networking is in use.'
            }
        }
        elseif ($sawTraffic) {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome info -VmId $Context.VmId `
                -Detail "Accelerated networking is in use on an SR-IOV virtual function that is not MANA, on this host: $($adapter.Fabric.Detail)"
        }
        else {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'validate' -Outcome warn -VmId $Context.VmId `
                -Detail "The network adapter is an SR-IOV virtual function that is not MANA, on this host: $($adapter.Fabric.Detail). The product could not read its traffic counters, so it cannot say that accelerated networking is in use."
        }
    }

    # Extension compare (MS operational validation). The in-place upgrade
    # keeps every extension, so one missing or unhealthy is a failure.
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $capturedExt = @(if ($doc.captured.PSObject.Properties['extensions']) { $doc.captured.extensions })
    if ($capturedExt.Count -gt 0) {
        $liveExt = Invoke-VmfAzOperation -Name 'getExtensions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfVmExtensions -ResourceGroupName $Context.Rg -Name $Context.VmName
        }
        $liveNames = @($liveExt | ForEach-Object { $_.name })
        $missing = @($capturedExt | Where-Object { $_.name -notin $liveNames } | ForEach-Object { $_.name })
        $unhealthy = @($liveExt | Where-Object { $_.name -in @($capturedExt | ForEach-Object { $_.name }) -and $_.provisioningState -ne 'Succeeded' } |
            ForEach-Object { "$($_.name)=$($_.provisioningState)" })
        if ($missing.Count -gt 0 -or $unhealthy.Count -gt 0) {
            $detail = "Missing: $($missing -join ', '). Not in the Succeeded state: $($unhealthy -join ', ')."
            throw "The check of the VM extensions failed. $detail"
        }
    }

    # VERIFY-FP-1 part 3: keep what this step read, beside what the machine was
    # before the move. Every check above has passed; this only records. A
    # record that cannot be written is said and the machine is still MIGRATED
    # - evidence must never stop a move that worked. A lost lease still stops.
    try {
        $evDoc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
        $cap = $evDoc.captured
        $capGet = { param($name) if ($cap -and $cap.PSObject.Properties[$name]) { $cap.$name } else { $null } }
        $driverBefore = & $capGet 'driver'
        $before = ConvertTo-VmfEvidenceSide -VmConfig (& $capGet 'vmConfig') -Imds (& $capGet 'imdsBefore') `
            -Guest (& $capGet 'guestBefore') -Fabric $(if ($driverBefore -and $driverBefore.PSObject.Properties['facts']) { $driverBefore.facts } else { $null })
        $afterVm = Invoke-VmfAzOperation -Name 'evidenceRead' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfVmCapture -Vm (Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName)
        }
        $after = ConvertTo-VmfEvidenceSide -VmConfig ([pscustomobject]$afterVm) -Imds $imdsAfter -Guest $result `
            -Fabric $(if ($mana -and $mana.PSObject.Properties['facts']) { $mana.facts } else { $null })
        Save-VmfEvidence -RunPath $Context.RunPath -VmId $Context.VmId -Before $before -After $after `
            -Planned (Get-VmfEvidencePlanned -PlanEntry $Context.Plan -Doc $evDoc)
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'VALIDATING' -Outcome warn -VmId $Context.VmId `
            -Detail "The product could not keep the evidence record: $($_.Exception.Message). The move passed every check."
    }

    # WAVE-2 lever 6 (decided 2026-08-28): there is deliberately no
    # application check here. The product validates the MACHINE - it booted, the
    # disks are where they were, the boot path is on the controller the plan
    # asked for, the accelerated adapter is bound, the security posture
    # survived. Whether the application came back is the app owner's check,
    # and it belongs in their sign-off, not in a gate that would roll a
    # healthy machine back because a health URL was slow to warm up.
    return @{ Next = 'MIGRATED' }
}

##############################################################################
# Rollback
##############################################################################

function Test-VmfAnOffFirstNeeded {
    <#
    .SYNOPSIS
        ROLLBACK-RETRY-CAPTURE-3: does a put-back need the off pass before
        its first machine update? Pure.
    .DESCRIPTION
        $true only in the shape Azure refuses (measured 2026-10-10): the
        capture recorded the PRIMARY interface off (the move turns it on), and
        ANOTHER interface on; and the size the machine goes back to allows
        accelerated networking on one interface only - 2 vCPUs, or 2 active
        vCPUs on a constrained size (not measured there, so treated as
        capped) - or the catalog does not say. Unknown is never a fit.
        A size with more vCPUs never meets the cap, so its order stays as it
        was.
    .PARAMETER SkuKnown
        $false: answer the interface question alone (is a catalog read worth
        it?). The size then counts as unknown.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Nics,
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][bool]$SkuKnown = $true
    )
    $all = @($Nics | Where-Object { $_ })
    $primary = Get-VmfPrimaryNic -Nics $all
    if (-not $primary -or -not $primary.PSObject.Properties['acceleratedNetworking'] -or $primary.acceleratedNetworking -ne $false) { return $false }
    $otherOn = @($all | Where-Object { -not [object]::ReferenceEquals($_, $primary) -and $_.PSObject.Properties['acceleratedNetworking'] -and $_.acceleratedNetworking -eq $true })
    if (-not $otherOn.Count) { return $false }
    if (-not $SkuKnown -or -not $SkuEntry) { return $true }
    $read = {
        param([string]$Name)
        $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        $value = 0
        if ($cap -and [int]::TryParse([string]$cap.Value, [ref]$value)) { return $value }
        $null
    }
    $vcpus = & $read 'vCPUs'
    if ($null -eq $vcpus -or $vcpus -le 2) { return $true }
    $active = & $read 'vCPUsAvailable'
    ($null -ne $active -and $active -le 2)
}

function Restore-VmfCapturedAcceleratedNetworking {
    <#
    .SYNOPSIS
        ROLLBACK-AN-1: set accelerated networking on each network interface
        back to what the capture recorded before the move.
    .DESCRIPTION
        A move turns it on for the primary interface, before the new size. A
        rollback, and a restore from the first copy, put the machine back as
        it was - so this too. Called with the machine deallocated and on its
        ORIGINAL size (or its interfaces detached), which is what allowed each
        setting before. An interface the capture could not read is left
        alone: unknown is not a value. Azure refusing one is said, and never
        stops the caller - the machine starts with it as the move left it.
    .PARAMETER Kind
        What is putting it back, and the operation prefix: 'rollback' or
        'restore'.
    .PARAMETER OffFirst
        ROLLBACK-RETRY-CAPTURE-3: the first pass, right after the stop and
        before any update of the machine. MEASURED 2026-10-10 on a 2-vCPU
        size with the primary interface off and a second one on: Azure
        accepts the move turning it on for the primary while the machine is
        deallocated, then refuses EVERY machine update - a resize to the size,
        a tag - with VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable
        (a start is accepted). So a rollback's first machine update (leaving
        the reservation, the size, detachVerify, a disk swap) was refused
        inside the stopped window. This pass turns OFF each interface the
        capture recorded off - the move only ever turns one ON, so this is
        the only change that lowers the count. Nothing is turned on here: that
        waits for the original size, in the full set-back, which runs as
        before.
        It runs only in the shape the cap refuses (Test-VmfAnOffFirstNeeded):
        the primary recorded off, ANOTHER interface recorded on, and the size
        the machine goes back to allows it on one interface only (2 vCPUs, or
        2 active vCPUs) or the catalog does not say. Anywhere else the order
        is exactly as before: on a larger size the cap never applies, and an
        early off pass there could leave the primary off on a target size that
        REQUIRES accelerated networking (Intel D and E v5) before a machine
        update - not measured, so not risked. The size catalog is read only
        when the interfaces are in that shape.
        A refusal here is said, is not counted, and is not said as final: the
        full set-back tries again on the original size.
    .PARAMETER Size
        -OffFirst: the size the machine goes back to.
    .PARAMETER Location
        -OffFirst: the region whose size catalog is read.
    .OUTPUTS
        The number of interfaces it could not set back (0 for -OffFirst).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowNull()]$Nics,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter()][switch]$OffFirst,
        [Parameter()][AllowEmptyString()][string]$Size,
        [Parameter()][AllowEmptyString()][string]$Location,
        # ROLLBACK-CAPACITY-1 review: filled with the name of each interface
        # whose setting changed, for the stop that lists what went back.
        [Parameter()][AllowNull()][System.Collections.Generic.List[string]]$ChangedOut
    )
    $changed = [System.Collections.Generic.List[string]]::new()
    $failed = 0
    $eventStep = $Kind
    # RESTORE-WARN-ENDS-1: in a person's restore this line comes in the
    # middle, and the run page reads a 'restore' warn as the END of the
    # restore. So it is info there, as the data disk restore writes it
    # (RESTORE-ALL-1). A rollback keeps warn.
    $notBackOutcome = if ($Kind -eq 'restore') { 'info' } else { 'warn' }
    $known = @($Nics | Where-Object { $_ -and $_.PSObject.Properties['acceleratedNetworking'] -and $null -ne $_.acceleratedNetworking })
    if ($OffFirst) {
        # The catalog is read only for the interface shape the cap refuses.
        if (-not (Test-VmfAnOffFirstNeeded -Nics $Nics -SkuKnown $false)) { return 0 }
        $entry = $null
        if ($Size -and $Location) {
            try {
                $vmSub = Get-VmfSubscriptionId -ResourceId $VmId
                $entry = Invoke-VmfAzOperation -Name "$($Kind):skuCatalog" -RunPath $RunPath -VmId $VmId -Operation {
                    @(Get-VmfSkuCatalog -Location $Location -SubscriptionId $vmSub) | Where-Object { $_.Name -eq $Size } | Select-Object -First 1
                }
            }
            catch {
                if ($_.Exception.Message -match 'abandon this VM') { throw }
                # Unknown is not a fit: the pass runs, as for a 2-vCPU size.
                $entry = $null
            }
        }
        if (-not (Test-VmfAnOffFirstNeeded -Nics $Nics -SkuEntry $entry)) { return 0 }
        $known = @($known | Where-Object { $_.acceleratedNetworking -eq $false })
    }
    foreach ($nic in $known) {
        $nicId = [string]$nic.id
        $want = [bool]$nic.acceleratedNetworking
        $nicName = ($nicId -split '/')[-1]
        try {
            $did = Invoke-VmfAzOperation -Name "$($Kind):nicAccelNet" -RunPath $RunPath -VmId $VmId -Operation {
                Set-VmfNicAcceleratedNetworking -NicId $nicId -Enabled $want
            }
            if ($did -eq $true) {
                $changed.Add($(if ($OffFirst) { $nicName } else { "$nicName $(if ($want) { 'on' } else { 'off' })" }))
                if ($null -ne $ChangedOut) { $ChangedOut.Add($nicName) }
            }
        }
        catch {
            # Lease fencing is not a NIC failure: another worker owns the
            # machine now, and the caller must stop, as everywhere else.
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            if ($OffFirst) {
                Write-VmfStepLine -RunPath $RunPath -Step $eventStep -Outcome $notBackOutcome -VmId $VmId `
                    -Detail "Accelerated networking could not be set back to off first on $($nicName): $($_.Exception.Message). The $Kind tries again before the machine starts."
                continue
            }
            $failed++
            Write-VmfStepLine -RunPath $RunPath -Step $eventStep -Outcome $notBackOutcome -VmId $VmId `
                -Detail "Accelerated networking could not be set back on $($nicName): $($_.Exception.Message). The machine starts with it as the move left it."
        }
    }
    if ($changed.Count) {
        $said = if ($OffFirst) { "Accelerated networking is set back to off first, as the capture recorded it: $($changed -join ', ')." }
                else { "Accelerated networking is set back to how it was: $($changed -join ', ')." }
        Write-VmfStepLine -RunPath $RunPath -Step $eventStep -Outcome info -VmId $VmId -Detail $said
    }
    $failed
}

function Get-VmfRollbackStamp {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: the time in the names of the disks a rollback
        makes - from the rollback's checkpoint, so a resume of the SAME
        rollback asks for the same names. Pure.
    .DESCRIPTION
        The disks are made before the machine stops now, so a worker that
        stops between the two used to leave disks that the resume made again
        under the next minute's names. New-VmfDiskFromSnapshot returns a disk
        of the asked name made from the same copy, so the same names make the
        step safe to run again. With no checkpoint (a caller that runs the
        rollback alone), the time now.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $started = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'rollbackPending') -Name 'startedUtc'
    $stamp = $null
    if ($started) {
        # ConvertFrom-Json can give the instant as a date value or as text.
        try { $stamp = ([datetimeoffset]$started).UtcDateTime.ToString('yyyyMMddHHmm') } catch { $null = $_ }
    }
    if (-not $stamp) { $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmm') }
    # Review: the rollback disks carry the same pattern,
    # '<disk>-asitwas-<minute>'. A rollback that starts in the minute
    # SAFETY_PRISTINE wrote its time would ask for their names, and
    # New-VmfDiskFromSnapshot (the same disk by name, whatever its type) would
    # give a fallback THOSE disks - gone, on another machine, or on another
    # type. Both times are on record, so a resume gets the same answer.
    $rollbackDisksBeforeMove = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'safety') -Name 'rollbackDisksBeforeMove'
    if ($rollbackDisksBeforeMove -and [string](Get-VmfRecordField -Object $rollbackDisksBeforeMove -Name 'stamp') -eq $stamp) { $stamp = "$($stamp)r" }
    $stamp
}

function New-VmfRollbackDisksDuringRollback {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: make every disk a rollback puts back - the OS
        disk and each data disk, from the first copy - BEFORE the rollback
        changes anything on the machine.
    .DESCRIPTION
        A disk made from a copy needs no stopped machine: the copy is already
        taken. Path B always made every disk before it deleted the definition;
        the Path A and the disks-only rollbacks made them only after the stop,
        the reservation, the disk types and the size - so a disk Azure refused,
        or one that came back on another key (SAFETY-CMK-1) or with other
        values (SAFETY-ULTRA-1), left the machine stopped on its old size with
        the converted OS disk.
        Now an OS disk that cannot be made, read back or matched throws here,
        with the machine as the failed step left it, and the exception carries
        vmfRollbackUntouched. Each disk is on record (rollbackDisksDuringRollback) the moment
        Azure made it. A data disk not made keeps its disk and is on the kept
        list, as before (SAFETY-ULTRA-1) - and as Path B does.
    .PARAMETER AttemptShape
        The disks-only rollback: the OS disk on the type it has now
        (PREP-ROLLBACK-1, review F8). Otherwise the type the capture recorded.
    .OUTPUTS
        @{ OsId; OsName; Data = @{ Swaps; Kept } }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Capture,
        [Parameter(Mandatory)][string]$PristineId,
        [Parameter(Mandatory)][string]$Stamp,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter(Mandatory)]$DataPlan,
        [Parameter()][switch]$AttemptShape
    )
    try {
        $current = Invoke-VmfAzOperation -Name 'rollback:osDiskInfo' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfOsDiskInfo -ResourceGroupName $Context.Rg -Name $Context.VmName
        }
        # A NEW disk, never reusing the name: reusing it would mean deleting
        # the disk the machine currently boots from, leaving the snapshot as
        # the only copy - during a rollback, when things are already wrong.
        $newName = Get-VmfBoundedDiskName -BaseName $current.name -Suffix "-asitwas-$Stamp"
        $osSku = if ($AttemptShape) {
            # PREP-ROLLBACK-1 (review F8): the type of the disk the machine has now.
            if ([string]$current.skuName) { [string]$current.skuName } else { [string]$Capture.osDisk.skuName }
        }
        else {
            # OLD-SKU-1C: the type the capture recorded. The disk in use now
            # may have been changed to Premium SSD by this move.
            if ($Capture.osDisk -and [string]$Capture.osDisk.skuName) { [string]$Capture.osDisk.skuName } else { [string]$current.skuName }
        }
        # SAFETY-CMK-1: with the key of the disk the copy was taken of, read
        # back; on record the moment it exists, also when it differs.
        $newId = New-VmfOsDiskFromCopy -Context $Context -OpName 'rollback:createDisk' -ResourceGroupName $Context.Rg -DiskName $newName `
            -SnapshotId $PristineId -Location $current.location -SkuName $osSku -Zone $Zone -Disk $Capture.osDisk `
            -OnMade { param($madeId) Add-VmfRollbackDiskDuringRollbackRecord -Context $Context -DiskId $madeId -DiskName $newName -Lun $null }
        # SAFETY-ALL-1: and each data disk, before any disk is swapped.
        $data = Invoke-VmfDataDiskRestore -Context $Context -RestorePlan $DataPlan -Location $current.location -Zone $Zone
        # SAFETY-ULTRA-MARGIN-1: every data disk, or the rollback stops here,
        # with the machine as the failed step left it.
        Assert-VmfDataDisksAllBack -Kept @($data.Kept)
    }
    catch {
        # Lease fencing is not a refused disk: another worker owns the machine.
        if ($_.Exception.Message -notmatch 'abandon this VM') { $_.Exception.Data['vmfRollbackUntouched'] = $true }
        throw
    }
    $dataWords = if (@($data.Swaps).Count) { " and the data disks $(@($data.Swaps | ForEach-Object { "'$($_.diskName)'" }) -join ', ')" } else { '' }
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId `
        -Detail "The rollback made the operating system disk '$newName'$dataWords from the first safety copy before it changes the machine."
    @{ OsId = [string]$newId; OsName = $newName; Data = $data }
}

function Invoke-VmfRollback {
    <#
    .SYNOPSIS
        FAIL-1: put the machine back as it was - the PRISTINE COPY plus the
        original size and controller.
    .DESCRIPTION
        Unconditional: any failure after the machine was
        touched returns it to the point in time before anything happened. Not a
        policy, not a per-wave lever, not conditional on which step failed.

        The reasoning is a product position rather than a technical default.
        Migrations run in a change window, so there are no writes to preserve -
        nobody plans to roll back a patch and keep the writes either. And the
        support argument settles it: a tool that sometimes leaves a machine in
        an in-between state needs someone to call when it does.

        Restoring the DISK, not just the hardware, is an explicit rule.
        Reverting size and controller alone leaves the guest changes
        prep made - the boot-driver registry across every ControlSet, the
        pagefile moved off D:, the temp-disk task - which is "nearly as it was",
        and nearly is the thing this model exists to avoid.

        The pristine copy presupposes the ORIGINAL hardware: it was taken
        before prep, so its initramfs has no NVMe driver and its registry has
        no stornvme boot entry. Restoring it onto a machine already resized to
        NVMe produces a machine that does not boot. So the disk and the
        hardware always move together, while the machine is stopped.

        ROLLBACK-DISKS-FIRST-1, as decided on 2026-10-11: the
        disks a rollback swaps in were MADE from the first copies, and read
        back, before the move changed anything (New-VmfRollbackDisksBeforeMove, at the
        end of SAFETY_PRISTINE). A rollback reads them once more before the
        stop (Get-VmfRollbackDisksBeforeMoveSet) and only swaps them in - it asks Azure
        for no new disk. The fallback, for a rollback with no usable disks
        made before the move (none made yet for this copy, a disk
        gone or already used, the disks-only rollback on other disk types),
        makes every disk from its copy before the stop, as the first build
        did (New-VmfRollbackDisksDuringRollback); a disk that stops it there leaves the
        machine as the failed step left it.
          Path A        disks read (or, in the fallback, made), stop, accelerated networking off first,
                        reservation, disk types, size and controller, the
                        swaps, accelerated networking, start.
          disks only    disks made, stop, the swaps, start.

        REBUILD-REMOVE-ENGINE-1: there is no rollback by rebuild. Every move
        is Path A.

        -GuestOnly (PREP-ROLLBACK-1): a stop BEFORE CONVERTING, after the
        preparation changed the guest. The hardware, the disk types, the
        reservation and accelerated networking are all still as they were, so
        only the disks go back: the disks from the first copy, stop, the swaps, start.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][switch]$GuestOnly,
        # ROLLBACK-EMPTY-LUN-1: a worker finishes a rollback another worker
        # started. Its data disk swaps read each LUN first
        # (Invoke-VmfDataSwapBatches -Resumed).
        [Parameter()][switch]$Resumed
    )


    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if ($GuestOnly) {
        # PREP-ROLLBACK-1 (review F8): the size, the zone and the disk types
        # of the machine NOW - this attempt's capture. Before CONVERTING
        # nothing changed them, and the first capture can differ after a retry
        # (a rebuild as the target between two attempts): its disk types would
        # be a change, not a rollback. Review F9: no size changes, so the
        # retired-size refusal does not apply.
        $capture = $doc.captured.vmConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    }
    else {
        # ROLLBACK-RETRY-CAPTURE-1: the machine's shape from its FIRST capture,
        # this attempt's disks. A retry after a rebuild as the target found the
        # machine on the target size, and "as it was" is the size before that.
        # RETIRE-SCOPE-1: always that size. A machine on a size Microsoft retires
        # is refused at PRECHECK from one day before the date, so no rollback goes
        # to another size; a captured.putBackRetirement record that V3-RETIRE-1
        # wrote with a current size is not read.
        # OLD-VERSION-READERS-REMOVE-4: a record with no first capture, or one
        # that does not say its capacity reservation group, is not a record
        # this version writes. Not started: said and thrown before anything
        # changes, as the retired-size refusal below is.
        $recordGap = Get-VmfPutBackRecordGap -Doc $doc
        if ($recordGap) {
            $gapWords = $recordGap
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome fail -VmId $Context.VmId -Detail $gapWords
            throw $gapWords
        }
        $capture = Get-VmfPutBackCapture -Doc $doc
        # REVIEW of RETIRE-SCOPE-1: a move that passed PRECHECK before the margin
        # and resumed past the retirement date (a worker that stopped, a wave
        # started again) would stop the machine and ask Azure for a size it
        # refuses. Not started: thrown
        # before anything changes, so the caller records rollbackFailed with these
        # words, and the machine stays as the failed step left it.
        $retiredRefusal = Get-VmfRetiredRollbackRefusal -Size ([string]$capture.size)
        if ($retiredRefusal) {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome fail -VmId $Context.VmId -Detail $retiredRefusal
            throw $retiredRefusal
        }
        # PREVIEW-PUTBACK-1: a Preview move's rollback resizes across the
        # temporary disk kinds again, which needs the preview feature. Asked
        # before any disk is made and before the stop; refused there.
        $previewCheck = Get-VmfPreviewPutBackCheck -Context $Context -Kind 'rollback' -Size ([string]$capture.size) `
            -Method (Get-VmfStartedMoveMethod -Doc $doc -PlanEntry $Context.Plan)
        if ($previewCheck -and $previewCheck.Refuse) {
            # Review of PREVIEW-PUTBACK-1: on a resume, an earlier worker of
            # this rollback may have stopped the machine before it was lost.
            # The record does not say so, so the words say what Azure reports.
            $refusedWords = $previewCheck.Detail
            if ($Resumed) { $refusedWords = "$refusedWords $(Get-VmfPreviewRollbackPowerWords -Context $Context)" }
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome fail -VmId $Context.VmId -Detail $refusedWords
            $refused = [System.InvalidOperationException]::new($refusedWords)
            $refused.Data['vmfRollbackUntouched'] = $true
            $refused.Data['vmfRollbackReason'] = $script:VmfPreviewRollbackReason
            throw $refused
        }
        if ($previewCheck) { Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId -Detail $previewCheck.Detail }
    }
    $pristineId = if ($doc.safety) { [string]$doc.safety.pristineSnapshotId } else { $null }
    $rg = $Context.Rg
    $vmName = $Context.VmName
    # ROLLBACK-DISKS-FIRST-1: the same disk names on a resume of this rollback.
    $stamp = Get-VmfRollbackStamp -Doc $doc
    # ROLLBACK-DISKS-FIRST-1: the mark this rollback puts on each disk made
    # for the rollback that it swaps in - the same on a resume, so a worker
    # that finishes this rollback may swap the same disks again.
    $useToken = "rollback-$stamp"
    # SAFETY-ALL-1: the data disks go back with the OS disk, to the same
    # moment. And every disk is made in the machine's zone - a zonal machine
    # takes no other.
    $zone = Get-VmfMachineZone -Machine $capture
    # ROLLBACK-DISKS-FIRST-1 (2026-10-11): the disks made for
    # the rollback before the move changed anything (New-VmfRollbackDisksBeforeMove).
    # When they are usable the rollback asks Azure for no new disk at all: it
    # only swaps them in. Otherwise - none made yet for this copy, a
    # disk gone or used, the disks-only rollback on other disk types - it
    # makes its disks as before, still before the stop (the fallback).
    $preMade = $null
    $preWords = $null
    if ($pristineId) {
        $pick = Get-VmfRollbackDisksBeforeMoveSet -Context $Context -Doc $doc -Shape $(if ($GuestOnly) { 'disks' } else { 'full' }) -FromSnapshotId $pristineId -UsedBy $useToken
        $preMade = $pick.Set
        $preWords = if ($preMade) { "The rollback uses the disks that the product made from the safety copies before the move changed the machine: $(@(@($preMade.OsName) + @($preMade.Data.Swaps | ForEach-Object { $_.diskName }) | ForEach-Object { "'$_'" }) -join ', '). It asks Azure for no new disk." }
                    else { "The rollback makes its disks from the first safety copy now, before it stops the machine. $($pick.Why)" }
    }
    # SAFETY-ULTRA-1: whether Azure can make a disk from each Premium SSD v2
    # and Ultra Disk copy, read BEFORE the machine stops, on every path. A
    # machine with no such disk makes no call - and nor does a rollback that
    # uses the rollback disks.
    $readiness = if ($pristineId -and -not $preMade) { Get-VmfInstantAccessCopyReadiness -Context $Context -Doc $doc -Kind 'pristine' } else { @{} }
    $dataPlan = if ($pristineId -and -not $preMade) { Get-VmfDataRestorePlan -Doc $doc -Stamp $stamp -AttemptShape:$GuestOnly -CopyReadiness $readiness } else { @{ Restore = @(); Kept = @() } }
    # Every data disk not put back, with why - on the rollback record, and in
    # the words of the stop (Complete-VmfRollback).
    $keptList = [System.Collections.Generic.List[object]]::new()
    # SWAP-REFUSED-AFTER-STOP-1: every data disk Azure did not swap back, even
    # after the tries. With one, the machine is never started.
    $leftList = [System.Collections.Generic.List[object]]::new()
    $keptCount = 0
    $keptLuns = @()
    # IAC-REPORT-1: the disks this rollback makes, recorded on the document.
    $madeOs = $null
    $madeData = @()
    $typesNotBack = 0
    $anNotBack = 0
    $anFirst = $false
    # ROLLBACK-CRG-1: the group Azure did not put the machine back in, if any.
    $crgNotBack = $null
    # ROLLBACK-CRG-1 review: a group the machine left that this migration did
    # not make, if any.
    $crgLeft = $null
    $recordPath = if ($GuestOnly) { 'disks' } else { [string]$Context.Plan.path }
    # ROLLBACK-CAPACITY-1: the start of the full rollback that failed, if any.
    $startFailure = $null

    if (-not $pristineId -and $GuestOnly) {
        # Nothing else to put back: the hardware was never changed. Said before
        # anything stops, so the caller records the stop with these words.
        $noCopy = [System.InvalidOperationException]::new('No first safety copy is recorded, so the preparation cannot be undone. The machine keeps the changes the preparation made.')
        $noCopy.Data['vmfRollbackNoDiskChanged'] = $true
        throw $noCopy
    }
    if (-not $pristineId) {
        # Should be unreachable: the copy is mandatory and the run refuses to
        # start without it. If it ever happens, reverting the hardware is
        # strictly better than doing nothing - but say so, because the machine
        # keeps the guest changes and that is NOT what we promise.
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome warn -VmId $Context.VmId `
            -Detail 'No first safety copy is recorded. The rollback returns the size and the disk controller only, and the machine keeps the changes of the preparation.'
    }

    # UX finding from the FAIL-1 drill (seen live): the
    # rollback did the most consequential work in the whole run - swapping the
    # OS disk, reverting the hardware - and the activity feed showed one line
    # saying "rollback". Every ARM call below now goes through the wrapper, so
    # it narrates itself. That is not only cosmetic: the wrapper is also what
    # retries transient failures and renews the lease, and a rollback dying on
    # a throttle is the worst possible moment to have neither.
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome start -VmId $Context.VmId `
        -Detail "$(if ($GuestOnly) { 'Rolling the disks of the machine back, on its current size' } else { 'Rolling the machine back' }): $($capture.size)$(if ($capture.controller) { "/$($capture.controller)" })$(if ($pristineId) { ', from the copy taken before anything was changed' })"
    if ($preWords) { Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId -Detail $preWords }

    if ($GuestOnly) {
        # PREP-ROLLBACK-1: the hardware is as it was; only the disks go back.
        # No size, controller, disk type, reservation or accelerated networking
        # step - each would be a write to something the move never changed.
        # Order (ROLLBACK-DISKS-FIRST-1): every disk made, stop, the swaps,
        # start (review F12 tests it). A disk that stops the rollback stops it
        # before the stop, with the machine as the failed step left it.
        $diskTouched = $false
        $allSwapped = $false
        try {
            $disks = if ($preMade) { $preMade }
                     else { New-VmfRollbackDisksDuringRollback -Context $Context -Capture $capture -PristineId $pristineId -Stamp $stamp -Zone $zone -DataPlan $dataPlan -AttemptShape }
            $newId = $disks.OsId
            $newName = $disks.OsName
            $data = $disks.Data
            foreach ($k in @($data.Kept)) { $keptList.Add($k) }
            Invoke-VmfAzOperation -Name 'rollback:stop' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Stop-VmfVmDeallocated -ResourceGroupName $rg -Name $vmName
            } | Out-Null
            # Review F5: from here a disk on the machine may change. Before
            # here, a failure leaves the machine as the failed step left it.
            $diskTouched = $true
            Invoke-VmfAzOperation -Name 'rollback:swapDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Set-VmfVmOsDisk -ResourceGroupName $rg -Name $vmName -DiskId $newId -DiskName $newName
            } | Out-Null
            Set-VmfRollbackDisksBeforeMoveUsed -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @([string]$newId) -By $useToken
            $madeOs = [ordered]@{ id = [string]$newId; name = $newName }
            Set-VmfRollbackRecord -Context $Context -Path $recordPath -OsDisk $madeOs -KeptDataDisks @($keptList)
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId `
                -Detail "The operating system disk was restored from the first safety copy. The machine now uses the disk '$newName'. The disk it used before is kept."
            $madeData = @(Invoke-VmfDataSwapBatches -Context $Context -Path $recordPath -OsDisk $madeOs -Swaps @($data.Swaps) -KeptList $keptList -LeftList $leftList -UsedBy $useToken -Resumed:$Resumed)
            if ($leftList.Count) {
                # SWAP-REFUSED-AFTER-STOP-1: stopped, never started, and on
                # record before the rollback is marked done.
                Save-VmfSwapPendingChecked -RunPath $Context.RunPath -VmId $Context.VmId -Record (New-VmfSwapPendingRecord -Kind 'rollback' -Swaps @($leftList) `
                        -Reason ([string]$leftList[-1].why) -UsedBy $useToken -Swapped @($madeData) -Kept @($keptList))
            }
            else {
            $allSwapped = $true
            # ROLLBACK-CAPACITY-1: an allocation failure is tried again.
            Start-VmfRollbackVm -Context $Context -Size ([string]$capture.size)
            }
        }
        catch {
            if (-not $diskTouched) { $_.Exception.Data['vmfRollbackNoDiskChanged'] = $true }
            # Review 2, finding 7: every disk is back and only the start
            # failed. Recorded first, so a resume only records the stop.
            elseif ($allSwapped -and $_.Exception.Message -notmatch 'abandon this VM') {
                Clear-VmfRetryState -RunPath $Context.RunPath -VmId $Context.VmId -From 'PRECHECK'
                Set-VmfRollbackRecord -Context $Context -Path $recordPath -OsDisk $madeOs -DataDisks $madeData -KeptDataDisks @($keptList) -Done
                $_.Exception.Data['vmfRollbackStartOnly'] = $true
            }
            throw
        }
    }
    else {
        # ROLLBACK-DISKS-FIRST-1: every disk from its copy FIRST, before the
        # stop. Making a disk needs no stopped machine, and a disk Azure
        # refuses, or one that differs from the record, then stops the
        # rollback with the machine as the failed step left it - never
        # stopped on its old size with the converted OS disk. The steps after
        # keep their order: ROLLBACK-RETRY-CAPTURE-3 and ROLLBACK-ORDER-1
        # order the machine updates and the swaps, not when a disk is made.
        # The decision of 2026-10-11 goes further: the disks made for
        # the rollback before the move ($preMade) are used when they can be,
        # so nothing here asks Azure for a disk.
        $disks = $null
        if ($preMade) { $disks = $preMade }
        elseif ($pristineId) {
            $disks = New-VmfRollbackDisksDuringRollback -Context $Context -Capture $capture -PristineId $pristineId -Stamp $stamp -Zone $zone -DataPlan $dataPlan
        }
        if ($disks) { foreach ($k in @($disks.Data.Kept)) { $keptList.Add($k) } }
        Invoke-VmfAzOperation -Name 'rollback:stop' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Stop-VmfVmDeallocated -ResourceGroupName $rg -Name $vmName
        } | Out-Null
        # ROLLBACK-RETRY-CAPTURE-3: before ANY machine update below - leaving
        # the reservation, the size, a swap. With the move's own setting on
        # the primary and a second interface on, Azure refuses every update of
        # a 2-vCPU machine (measured 2026-10-10). Only turns OFF; the full
        # set-back after the size still runs.
        # ROLLBACK-CAPACITY-1 review: each setting put back before the size,
        # for the stop when Azure refuses the size.
        $putBack = [System.Collections.Generic.List[string]]::new()
        $anOff = [System.Collections.Generic.List[string]]::new()
        $null = Restore-VmfCapturedAcceleratedNetworking -RunPath $Context.RunPath -VmId $Context.VmId -Nics $capture.nics -Kind 'rollback' -OffFirst `
            -Size ([string]$capture.size) -Location ([string]$capture.location) -ChangedOut $anOff
        if ($anOff.Count) { $putBack.Add("Accelerated networking is off again on these network interfaces: $(($anOff | ForEach-Object { "'$_'" }) -join ', ').") }

        # Reserved capacity is ONE WAY: the group holds the target size only,
        # and Azure refuses to start a VM whose size has no reservation in the
        # group it is attached to. Leaving has to happen BEFORE the size
        # changes or the rollback fails inside the stopped window - the safety
        # net tearing exactly where it is needed. Found by the SAFETY-2 drill.
        # ROLLBACK-CRG-1: only a group the machine was not in before the move.
        # The group it was in goes back after the size, below. Read live, so a
        # resume of this rollback does each only once.
        $crgPlan = Get-VmfReservationPutBack -RunPath $Context.RunPath -VmId $Context.VmId -Rg $rg -VmName $vmName -Kind 'rollback' -Capture $capture
        $crgLeft = Invoke-VmfReservationLeave -RunPath $Context.RunPath -VmId $Context.VmId -Rg $rg -VmName $vmName -Kind 'rollback' -Decision $crgPlan -Size ([string]$capture.size)
        if ($crgPlan.Leave) { $putBack.Add("The machine left the capacity reservation group '$(Get-VmfReservationGroupName ([string]$crgPlan.LeaveGroupId))'.") }

        # OLD-SKU-1C: the disk types go back BEFORE the size. Azure refuses to
        # put a machine on a size that takes no Premium SSD (D4_v2) while a
        # Premium SSD disk is attached. Every disk this move changed is still
        # attached here - Path A never swaps a disk - and the ones made again
        # from a copy above were made on the recorded type anyway.
        # HDD-OS-1: with the type each disk kept - a Standard SSD disk does not
        # stop the put-back; every size takes it.
        $keptTypes = [System.Collections.Generic.List[string]]::new()
        $typesBack = [System.Collections.Generic.List[string]]::new()
        $typesNotBack = Restore-VmfCapturedDiskTypes -RunPath $Context.RunPath -VmId $Context.VmId -Kind 'rollback' `
            -DiskIds (Get-VmfDisksKeptInUse -Capture $capture -Restored $false) -KeptTypes $keptTypes -SetBack $typesBack
        if ($typesBack.Count) { $putBack.Add("These disks have their type from before the move again: $(($typesBack | ForEach-Object { "'$_'" }) -join ', ').") }
        Assert-VmfSizeTakesKeptDisks -RunPath $Context.RunPath -VmId $Context.VmId -Size ([string]$capture.size) `
            -Location ([string]$capture.location) -NotBack $typesNotBack -Kind 'rollback' -KeptTypes $keptTypes `
            -Then "The machine is stopped, on its new size. Set each disk back to its type, then use Restore this machine."
        # OLD-FAM-1: and accelerated networking, when the old size cannot carry it.
        $anFirst = (Get-VmfSourceAcceleratedNetworking -Doc $doc -PutBack) -eq $false
        if ($anFirst) {
            $anBack = [System.Collections.Generic.List[string]]::new()
            $anNotBack = Restore-VmfCapturedAcceleratedNetworking -RunPath $Context.RunPath -VmId $Context.VmId -Nics $capture.nics -Kind 'rollback' -ChangedOut $anBack
            if ($anBack.Count) { $putBack.Add("Accelerated networking is as before the move on these network interfaces: $(($anBack | ForEach-Object { "'$_'" }) -join ', ').") }
        }

        # ROLLBACK-ORDER-1: the hardware goes back BEFORE the disk. The copy was
        # taken before the conversion added NVMe to the disk's allowed
        # controllers, and Azure refuses to swap in a disk that does not allow
        # the machine's CURRENT controller (GEN1-DISTROS-1 lab run: a Red Hat
        # machine left FAILED_NEEDS_ATTENTION). The disk the machine is on now
        # allows both, so setting SCSI back first is always accepted.
        # ROLLBACK-CAPACITY-1, case B: Azure refused the original size (for
        # example NotAvailableForSubscription). No disk is swapped yet, so the
        # machine is stopped on the new size; the stop says that, with its own
        # reason (Complete-VmfRollback).
        try {
            Invoke-VmfAzOperation -Name 'rollback:revertSize' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Set-VmfVmSizeAndController -ResourceGroupName $rg -Name $vmName `
                    -Size $capture.size -Controller $capture.controller
            } | Out-Null
        }
        catch {
            # A lost lease goes up untouched, whatever else its words name.
            # Only Azure's refusal of the size is the size refused; any other
            # failure of the update is a failed rollback (rollbackFailed).
            if ($_.Exception.Message -notmatch 'abandon this VM' -and
                (Get-VmfSizeRefusalCode -Message (Resolve-VmfOperationError -ErrorRecord $_).Message -Size ([string]$capture.size))) {
                $_.Exception.Data['vmfRollbackSizeRefused'] = [string]$capture.size
                $_.Exception.Data['vmfRollbackReason'] = 'rollbackSizeRefused'
                $_.Exception.Data['vmfRollbackPutBack'] = [string[]]@($putBack)
            }
            throw
        }
        # ROLLBACK-CRG-1: the group it was in before the move, on its own size
        # (REH-1: Azure checks the size against the group) and still stopped.
        # A refusal is said and the rollback goes on.
        $crgNotBack = Invoke-VmfReservationRejoin -RunPath $Context.RunPath -VmId $Context.VmId -Rg $rg -VmName $vmName -Kind 'rollback' -Decision $crgPlan -Size ([string]$capture.size)

        if ($disks) {
            # Made before the stop, above (ROLLBACK-DISKS-FIRST-1).
            $newId = $disks.OsId
            $newName = $disks.OsName
            $data = $disks.Data
            Invoke-VmfAzOperation -Name 'rollback:swapDisk' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Set-VmfVmOsDisk -ResourceGroupName $rg -Name $vmName -DiskId $newId -DiskName $newName
            } | Out-Null
            Set-VmfRollbackDisksBeforeMoveUsed -RunPath $Context.RunPath -VmId $Context.VmId -DiskIds @([string]$newId) -By $useToken
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome info -VmId $Context.VmId `
                -Detail "The operating system disk was restored from the first safety copy. The machine now uses the disk '$newName'. The disk it used before is kept."
            $madeOs = [ordered]@{ id = [string]$newId; name = $newName }
            # PREP-ROLLBACK-1 (review F4): on record after each swap.
            Set-VmfRollbackRecord -Context $Context -Path $recordPath -OsDisk $madeOs -KeptDataDisks @($keptList)
            $madeData = @(Invoke-VmfDataSwapBatches -Context $Context -Path $recordPath -OsDisk $madeOs -Swaps @($data.Swaps) -KeptList $keptList -LeftList $leftList -UsedBy $useToken -Resumed:$Resumed)
            if ($leftList.Count) {
                # SWAP-REFUSED-AFTER-STOP-1: on record before anything else, so
                # a worker that stops after this never starts the machine.
                Save-VmfSwapPendingChecked -RunPath $Context.RunPath -VmId $Context.VmId -Record (New-VmfSwapPendingRecord -Kind 'rollback' -Swaps @($leftList) `
                        -Reason ([string]$leftList[-1].why) -UsedBy $useToken -Swapped @($madeData) -Kept @($keptList))
            }
        }

        # ROLLBACK-AN-1: on the original size, before the start - unless it
        # went back first, above.
        if (-not $anFirst) { $anNotBack = Restore-VmfCapturedAcceleratedNetworking -RunPath $Context.RunPath -VmId $Context.VmId -Nics $capture.nics -Kind 'rollback' }

        # SWAP-REFUSED-AFTER-STOP-1: a data disk Azure did not swap back keeps
        # the machine stopped. Everything else is back; Finish the rollback
        # swaps what is left, then starts it.
        # ROLLBACK-CAPACITY-1: an allocation failure is tried again. A start
        # that still fails is a start that failed with every disk back and the
        # machine on its original size - recorded below as done, then said as
        # that (EVAL-H4, as on the disks-only path), never as a failed rollback.
        if (-not $leftList.Count) {
            try { Start-VmfRollbackVm -Context $Context -Size ([string]$capture.size) }
            catch {
                if ($_.Exception.Message -match 'abandon this VM') { throw }
                $startFailure = $_
            }
        }
    }
    # IAC-REPORT-1: what the rollback made, kept across attempts - the machine
    # runs on these disks until something else replaces them, and a definition
    # in code names disks. PREP-ROLLBACK-1 (review 2, finding 5): with the
    # checkpoint marked done in the same write, right after the last Azure
    # call - a worker that stops after this records the stop, and never runs
    # the rollback again (a second stop, swap or rebuild of a machine that is
    # already back).
    # SWAP-REFUSED-AFTER-STOP-1 (review note a): a resume that ran the
    # rollback again and swapped every disk removes the record of a swap an
    # earlier run of it left - before the rollback is marked done.
    if (-not $leftList.Count) {
        $staleLeft = Get-VmfSwapPending -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
        if ($staleLeft -and [string]$staleLeft.kind -eq 'rollback') { Set-VmfSwapPending -RunPath $Context.RunPath -VmId $Context.VmId -Record $null }
    }
    Set-VmfRollbackRecord -Context $Context -Path $recordPath -OsDisk $madeOs -DataDisks $madeData -KeptDataDisks @($keptList) -ReservationNotBack $crgNotBack -ReservationLeft $crgLeft -Done
    $keptCount = $keptList.Count
    # EVAL-H3: the machine is back at the beginning, so the record of how far
    # the last attempt got must go too. Leaving it made a retry skip the whole
    # conversion and report that it had succeeded. It re-reads the document,
    # so the record above stays.
    Clear-VmfRetryState -RunPath $Context.RunPath -VmId $Context.VmId -From 'PRECHECK'
    # MANA-LINUX-KERNEL-1 (review finding 11): the pristine copy holds the
    # kernel from before an update, so a rollback puts that kernel back - the
    # record says when, whatever the update's result was.
    Complete-VmfKernelUpdatePutBack -RunPath $Context.RunPath -VmId $Context.VmId

    if ($startFailure) {
        # ROLLBACK-CAPACITY-1: every disk is back, and the rollback is on record
        # as done; only the start failed. Complete-VmfRollback says so.
        $startFailure.Exception.Data['vmfRollbackStartOnly'] = $true
        throw $startFailure
    }

    if ($leftList.Count) {
        # SWAP-REFUSED-AFTER-STOP-1: the rollback ends with the machine
        # stopped. Complete-VmfRollback reads the record and records the stop.
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome warn -VmId $Context.VmId `
            -Detail "The machine is stopped. Every disk is back from the first safety copy except these data disks. $(Format-VmfRollbackLeft -Swaps @($leftList) -Live (Get-VmfRollbackLiveLuns -Context $Context).Luns) Use $(Get-VmfFinishActionName -Kind 'rollback') on this machine."
        return
    }
    # VOLUMES-ONLINE-1: this line says what the rollback put back in Azure. It
    # said "The machine is back as it was" with no check inside the machine,
    # while a volume was offline (final lab, 2026-11-13). The check comes
    # next, in Complete-VmfRollback, and its own line says what it found.
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome ok -VmId $Context.VmId `
        -Detail "The rollback returned the machine to $($capture.size)$(if ($capture.controller) { "/$($capture.controller)" })$(if ($pristineId) { ', on the disk content it had before the run started' })$(if ($keptCount) { " - except $keptCount $(if ($keptCount -eq 1) { 'data disk' } else { 'data disks' }) left as they were, named above" })$(if ($anNotBack) { " - except accelerated networking on $anNotBack $(if ($anNotBack -eq 1) { 'network interface' } else { 'network interfaces' }), named above" })$(if ($typesNotBack) { " - except the type of $typesNotBack $(if ($typesNotBack -eq 1) { 'disk' } else { 'disks' }), named above" })$(if ($crgNotBack) { " - except its capacity reservation group, named above" })$(if ($crgLeft) { " - and out of the capacity reservation group '$(Get-VmfReservationGroupName ([string]$crgLeft.groupId))', which it was not in before the move" }), and started it. The product now checks the volumes inside the machine."
}

##############################################################################
# Engine loop
##############################################################################

function Invoke-VmfStateMachine {
    <#
    .SYNOPSIS
        Drive one VM from its persisted state to a terminal state.
        Safe to re-invoke after any crash - resumes from the last checkpoint.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][string]$WorkerId = 'inline',
        # Invoked at the top of every state iteration as
        #   & $Heartbeat <RunPath> <VmId> <WorkerId>
        # (lease heartbeat renewal). The block must be SELF-CONTAINED - it runs
        # in this module's scope, so it may only use its parameters and
        # globally-resolvable commands. If it throws (lease lost/reaped), the
        # machine stops mid-state - safe: every step checkpoints, the next
        # holder resumes cleanly.
        [Parameter()][scriptblock]$Heartbeat
    )

    $ctx = New-VmfContext -PlanEntry $PlanEntry -RunPath $RunPath -RunId $RunId -WorkerId $WorkerId
    $doc = New-VmfStateDoc -RunPath $RunPath -RunId $RunId -VmId $ctx.VmId -Wave $PlanEntry.wave


    # STATE-TARGET-1: past PRECHECK, finish the move this machine STARTED -
    # never a different one because the entry changed while it was stopped.
    if (Test-VmfMoveStarted -Doc $doc) {
        $finish = Resolve-VmfStartedTarget -PlanEntry $PlanEntry -Started $doc.captured.startedTarget
        if (@($finish.Changed).Count) {
            # Its own step, so the run page shows the sentence rather than a
            # step label (SAYS_ITSELF). Said as what is true after the move: the
            # plan entry then describes something the machine is not.
            # STEP-LOG-3 (2026-10-16): the machine has STARTED its move -
            # it may be stopped or half rebuilt - so it finishes in one change
            # window even when this line cannot be written. The record keeps
            # captured.startedTarget, and the warning is in the engine's output.
            Write-VmfStepLine -RunPath $RunPath -Step 'targetKept' -Outcome warn -VmId $ctx.VmId `
                -Detail ("The plan for this machine changed after it started: $(@($finish.Changed) -join '; '). " +
                         'The engine finishes the move that started, because a person accepted and approved that move. ' +
                         'The plan entry now differs from the machine. Plan the machine again to use the change.')
            $PlanEntry = $finish.Entry
            $ctx.Plan = $PlanEntry
        }
    }

    # ENGINE-SUB-1: point this process at the MACHINE'S subscription for the
    # whole of its run. Everything below addresses it by resource group and
    # name, which are unique only inside one subscription - so without this the
    # engine could act on a same-named machine in whichever subscription it
    # happened to be signed in to. Proved against two real subscriptions:
    # resolving rg-vmf-lab/vmf-twin from A returns A's machine when the plan
    # meant B's.
    #
    # Safe because a worker process drives ONE machine at a time (see
    # Use-VmfSubscriptionContext). Restored in the finally below.
    $previousAzContext = $null
    if ($ctx.SubscriptionId) {
        try { $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $ctx.SubscriptionId }
        catch {
            # Cannot reach it - no rights, or it does not exist. That is an
            # answer, and parking is the only safe response: proceeding would
            # address the machine against the wrong subscription.
            $detail = "This machine is in subscription $($ctx.SubscriptionId), which the product cannot reach: $($_.Exception.Message)"
            Write-VmfStepLine -RunPath $RunPath -Step 'PLANNED' -Outcome fail -VmId $ctx.VmId -Detail $detail
            return Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState 'NEEDS_DECISION' `
                -Outcome fail -Detail $detail -ReasonCode 'subscriptionNotReachable' -MachineState 'untouched'
        }
    }

    # Every key here must be a declared working state (guarded by test).
    $handlers = @{
        PLANNED     = { @{ Next = 'PRECHECK' } }
        PRECHECK    = ${function:Invoke-VmfStepPrecheck}
        SAFETY_PRISTINE = ${function:Invoke-VmfStepSafetyPristine}
        GUEST_PREP  = ${function:Invoke-VmfStepGuestPrep}
        SAFETY_COPY = ${function:Invoke-VmfStepSafetyCopy}
        STOPPED     = ${function:Invoke-VmfStepStopped}
        CONVERTING  = ${function:Invoke-VmfStepConverting}
        STARTING    = ${function:Invoke-VmfStepStarting}
        VALIDATING  = ${function:Invoke-VmfStepValidating}
    }
    # Steps whose failure triggers automated rollback (subject to policy)
    $rollbackOnFail = @('CONVERTING', 'STARTING', 'VALIDATING')

    # In-step lease renewal (S3-7): long states (GUEST_PREP runs several 60s
    # guest commands) also renew via the azureops wrapper, throttled so rapid
    # small calls don't hammer the store. Cleared in finally - one machine per
    # worker process, so module scope is safe.
    if ($Heartbeat) {
        $hbLast = [ref][datetime]::MinValue
        $hbArgs = @{ Heartbeat = $Heartbeat; RunPath = $RunPath; VmId = $ctx.VmId; WorkerId = $WorkerId; Last = $hbLast }
        $script:VmfOpHeartbeat = {
            if (((Get-Date) - $hbArgs.Last.Value).TotalSeconds -ge 25) {
                & $hbArgs.Heartbeat $hbArgs.RunPath $hbArgs.VmId $hbArgs.WorkerId
                $hbArgs.Last.Value = Get-Date
            }
        }.GetNewClosure()
    }
    try {

    # EVAL-M4: this backstop existed and worked - it stopped the loop - but it
    # stopped it by falling out of the while and returning the state document
    # unchanged. The machine sat in a non-terminal state with no fail
    # transition, no event and no reason code; the worker exited 0, the wave
    # counted it as neither settled nor failed, and the lease expired with
    # nothing to resume because the doc looked mid-flight. The one situation
    # this guard exists for produced the quietest possible outcome.
    # ROLLBACK-DISKS-FIRST-1: the move is complete and on record, so the disks
    # made for its rollback that nothing used go. Never a failure of the move:
    # its own try, and a disk not deleted is said and found again by
    # retention. A block, because a resumed return to the power state
    # (POWER-AFTER-MOVE-1) ends a move too.
    $afterMigrated = {
        try { Remove-VmfUnusedRollbackDisksBeforeMove -Context $ctx }
        catch {
            if ($_.Exception.Message -notmatch 'abandon this VM') {
                Write-VmfStepLine -RunPath $RunPath -Step 'putBack' -Outcome warn -VmId $ctx.VmId `
                    -Detail "The move is complete. The product could not delete the rollback disks, and the daily cleanup tries again: $($_.Exception.Message)"
            }
        }
    }
    $safetyLimit = $script:VmfStateLoopLimit
    while ($doc.state -notin $script:VmfTerminalStates -and $safetyLimit -gt 0) {
        $safetyLimit--
        if ($Heartbeat) { & $Heartbeat $RunPath $ctx.VmId $WorkerId }
        # POWER-AFTER-MOVE-1: a move passed every check, and the worker
        # stopped in its return to the power state Checking found. It is
        # finished FIRST - Verifying never runs again on a machine that may be
        # deallocated now.
        if ($doc.PSObject.Properties['powerReturnPending'] -and $doc.powerReturnPending) {
            Write-VmfStepLine -RunPath $RunPath -Step 'VALIDATING' -Outcome info -VmId $ctx.VmId `
                -Detail 'The move passed every check. The return of the machine to its power state did not finish, and the engine finishes it before anything else.'
            $doc = Complete-VmfPowerReturn -Context $ctx
            if ([string]$doc.state -eq 'MIGRATED') { & $afterMigrated }
            continue
        }
        # PREP-ROLLBACK-1 (review F2): a rollback a worker did not finish is
        # finished FIRST - before any step, so the step that failed never runs
        # again on a half rolled-back machine. Every automatic rollback writes
        # this checkpoint before its first change.
        if ($doc.PSObject.Properties['rollbackPending'] -and $doc.rollbackPending) {
            Write-VmfStepLine -RunPath $RunPath -Step 'rollback' -Outcome info -VmId $ctx.VmId `
                -Detail 'The rollback of this machine did not finish. The engine finishes it before anything else.'
            $doc = Complete-VmfRollback -Context $ctx -Resumed
            continue
        }
        $state = $doc.state
        $handler = $handlers[$state]
        if (-not $handler) { throw "No handler for state '$state'." }

        # PERF-TELEMETRY-ENGINE-1: the run store and ARM calls of this attempt
        # of the step, written on its closing line (ok, retry or fail) as
        # `calls`. The activity line names the machine and the step already.
        Start-VmfStepCallTimings
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome start -VmId $ctx.VmId
            $result = & $handler $ctx
            # MANA-LINUX-KERNEL-1: a step that changed the machine and then
            # stopped asks for it to be put back now, in the same window.
            # PREP-ROLLBACK-1: with the checkpoint, and the disks only - the
            # hardware is as it was in GUEST_PREP. A worker that stops in the
            # middle leaves the checkpoint, and the next one finishes this
            # rollback rather than running all of it again.
            if ($result.PutBack) {
                Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome fail -VmId $ctx.VmId -DurationSec $sw.Elapsed.TotalSeconds -Detail $result.Detail -Data (Stop-VmfStepCallTimings)
                Set-VmfRollbackPending -Context $ctx -Kind 'disks' -State $state -ReasonCode ([string]$result.Reason) -Detail ([string]$result.Detail) -Change 'changed'
                $doc = Complete-VmfRollback -Context $ctx -DurationSec $sw.Elapsed.TotalSeconds
                continue
            }
            # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: a check after the start on the
            # new size stopped the move, so the machine goes back - FAIL-1's
            # full rollback, with the checkpoint first, as a failed step after
            # the move does. The stop keeps the check's reason.
            if ($result.RollBack) {
                Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome fail -VmId $ctx.VmId -DurationSec $sw.Elapsed.TotalSeconds -Detail $result.Detail -Data (Stop-VmfStepCallTimings)
                Set-VmfRollbackPending -Context $ctx -Kind 'full' -State $state -ReasonCode ([string]$result.Reason) -Detail ([string]$result.Detail) `
                    -StopState $(if ($result.StopState) { [string]$result.StopState } else { 'FAILED_ROLLED_BACK' })
                $doc = Complete-VmfRollback -Context $ctx -DurationSec $sw.Elapsed.TotalSeconds
                continue
            }
            # EVAL-M1: this used to stamp 'untouched' on EVERY handler return,
            # under the claim that a handler which returns a stop has mutated
            # nothing. That is false for the whole guest-prep family: the fixer
            # scripts rewrite fstab, GRUB, the initramfs and the boot registry
            # and only then decide they are BLOCKED. A handler may now say what
            # it left behind; otherwise the state decides, and only states that
            # genuinely cannot change anything claim 'untouched'.
            $handlerStop = @{}
            if ($result.Reason) {
                $handlerStop.ReasonCode = [string]$result.Reason
                $handlerStop.MachineState = if ($result.MachineState) {
                        # Review 2, finding 6: a step that says untouched is right
                        # on its first visit only. A fix that reported FIXED in
                        # this attempt (a re-prepare from STOPPED) says otherwise.
                        if ($state -eq 'GUEST_PREP' -and [string]$result.MachineState -eq 'untouched' -and
                            (Get-VmfGuestChangeThisAttempt -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId)) -eq 'changed') { 'changed' }
                        else { [string]$result.MachineState }
                    }
                    # STOP-MIDMOVE-FREED-1: one rule, which Stop-VmfRun asks too.
                    else { Get-VmfStateLeftMachineState -State $state -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId) }
                # POWER-ONLY-CHANGED-1: a step that could not put back the power
                # state found says which, and only a changed stop records it.
                if ($result.PowerNotPutBack -and [string]$handlerStop.MachineState -eq 'changed') { $handlerStop.PowerNotPutBack = [string]$result.PowerNotPutBack }
            }
            # PREP-ROLLBACK-1: a preparation that stops after it changed the
            # machine puts it back, as a failure in the move does.
            if (Test-VmfPrepRollbackWanted -State $state -Next ([string]$result.Next) -MachineState ([string]$handlerStop.MachineState)) {
                Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome fail -VmId $ctx.VmId `
                    -DurationSec $sw.Elapsed.TotalSeconds -Detail $result.Detail -Data (Stop-VmfStepCallTimings)
                $change = Get-VmfGuestChangeThisAttempt -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId)
                if ($change -eq 'none' -or [string]$result.MachineState -eq 'changed') { $change = 'changed' }
                Set-VmfRollbackPending -Context $ctx -Kind 'disks' -State $state -ReasonCode $handlerStop.ReasonCode `
                    -Detail ([string]$result.Detail) -Change $change `
                    -StopState $(if ([string]$result.Next -eq 'NEEDS_DECISION') { 'NEEDS_DECISION' } else { 'FAILED_ROLLED_BACK' })
                $doc = Complete-VmfRollback -Context $ctx -DurationSec $sw.Elapsed.TotalSeconds
                continue
            }
            # STOP-POWER-AS-FOUND-1: a stop that leaves the machine untouched
            # puts back the power state Checking found, when Checking started
            # the machine. A step that puts the power back itself says so
            # (PowerAsFound), so the machine is never put back twice.
            if ($result.Reason -and -not $result.PowerAsFound -and [string]$handlerStop.MachineState -eq 'untouched' -and
                [string]$result.Next -in @('FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK', 'NEEDS_DECISION')) {
                $back = Restore-VmfPowerAsFound -Context $ctx
                if ($back) {
                    $result.Detail = (@([string]$result.Detail, $back.Words) | Where-Object { $_ }) -join ' '
                    if (-not $back.Ok) { $handlerStop.MachineState = 'changed'; $handlerStop.PowerNotPutBack = $back.PowerNotPutBack }
                }
            }
            # POWER-AFTER-MOVE-1: the move passed every check of Verifying -
            # the last step that needs the machine running - so a machine
            # Checking found Stopped (deallocated) or Stopped goes back to that
            # power state now. The checkpoint first, then the return, then
            # MIGRATED in the same write that removes the checkpoint. Found
            # running, or no record: MIGRATED as before.
            $returnTo = if ([string]$result.Next -eq 'MIGRATED') { Get-VmfPowerAsFound -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId) } else { $null }
            if ($returnTo) {
                Set-VmfPowerReturnPending -Context $ctx -Power $returnTo
                $doc = Complete-VmfPowerReturn -Context $ctx -DurationSec $sw.Elapsed.TotalSeconds
            }
            else {
                $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState $result.Next `
                    -Outcome ok -DurationSec $sw.Elapsed.TotalSeconds -Detail $result.Detail @handlerStop
            }
            # STEP-LOG-1: the checkpoint above is the step's record. Every line
            # in this loop goes through Write-VmfStepLine, so a line that cannot
            # be written never puts the machine back to a step it finished.
            Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome ok -VmId $ctx.VmId `
                -DurationSec $sw.Elapsed.TotalSeconds -Detail $result.Detail -Data (Stop-VmfStepCallTimings)
            if ([string]$result.Next -eq 'MIGRATED') { & $afterMigrated }
        }
        catch {
            $err = $_.Exception.Message
            # Lease fencing is NOT a step failure (S3-7): the watchdog reaped
            # this worker's lease and another holder owns the machine now.
            # Rethrow untouched - no fail transition, no attempts, no rollback;
            # the new holder resumes from the checkpointed state doc.
            if ($err -match 'abandon this VM') { throw }
            # ACTIVITY-LINES-1 (56b): the cause, as every Azure call's line
            # says it. The outer message of a network error is only .NET's
            # "An error occurred while sending the request."; the cause is
            # inside it.
            $err = (Resolve-VmfOperationError -ErrorRecord $_).Message

            # attempts bookkeeping
            $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId
            $attempts = if ($doc.attempts -and $doc.attempts.PSObject.Properties[$state]) { [int]$doc.attempts.$state } else { 0 }
            $attempts++
            if (-not $doc.attempts) { $doc | Add-Member -NotePropertyName attempts -NotePropertyValue ([pscustomobject]@{}) -Force }
            $doc.attempts | Add-Member -NotePropertyName $state -NotePropertyValue $attempts -Force
            Write-VmfStateDoc -RunPath $RunPath -Document $doc

            $max = $script:VmfMaxAttempts[$state]
            # ACTIVITY-LINES-1 (56a): an attempt the engine tries again is a
            # retry line, never a fail line - the Activity list drew it red,
            # "Open the machine to see why this step failed", on a step that
            # went on. Red is only for the attempt that ends the step.
            Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome $(if ($attempts -lt $max) { 'retry' } else { 'fail' }) -VmId $ctx.VmId `
                -DurationSec $sw.Elapsed.TotalSeconds -Detail $err -Data ((Stop-VmfStepCallTimings) + @{ attempt = $attempts; maxAttempts = $max })
            if ($attempts -lt $max) {
                $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState $state `
                    -Outcome retry -DurationSec $sw.Elapsed.TotalSeconds -Detail "Attempt $attempts of $max failed: $err"
                continue
            }

            # Exhausted: decide the terminal state.
            #
            # FAIL-1: any failure after the machine was
            # touched puts it back - the pristine copy plus the original size
            # and controller. Not a policy, not a per-wave lever, not
            # conditional on which step failed. The hold-versus-rollback choice
            # that used to live here is gone: a machine is never left on
            # hardware it did not pass on.
            if ($state -in $rollbackOnFail) {
                # Evidence FIRST, then put it back. Capturing before rolling
                # back is what makes universal rollback safe to adopt - the
                # console output of a machine that would not boot survives, so
                # nothing diagnostic is lost by returning it to how it was.
                # That was the only real argument for ever leaving one broken.
                $bdName = $null
                if ($state -eq 'STARTING' -or $state -eq 'VALIDATING') {
                    try {
                        $bd = Get-VmfBootDiagnostics -ResourceGroupName $ctx.Rg -Name $ctx.VmName
                        $bdName = "bootdiag-$($ctx.VmName)-$([guid]::NewGuid().ToString('N').Substring(0,6)).json"
                        Write-VmfStoreText -RunPath $RunPath -RelPath "evidence/$bdName" -Content ($bd | ConvertTo-Json)
                    }
                    catch {
                        # Best effort by design: failing to collect evidence
                        # must never block putting the machine back.
                        Write-VmfStepLine -RunPath $RunPath -Step $state -Outcome warn -VmId $ctx.VmId `
                            -Detail "boot diagnostics could not be captured: $($_.Exception.Message)"
                    }
                }

                # WHY it failed, kept separate from where it left the machine.
                # A specific cause wins over the generic one: an allocation
                # failure during CONVERTING is a capacity problem an operator
                # can act on, and filing it as "rolled back" would discard the
                # only actionable part of it.
                $classified = Get-VmfErrorStopReason -Message $err
                $stopCode =
                    if ($classified -ne 'stepFailedRepeatedly') { $classified }
                    elseif ($state -eq 'STARTING')   { 'bootFailedAfterConversion' }
                    elseif ($state -eq 'VALIDATING') { 'validationFailedAfterConversion' }
                    else { 'rolledBack' }

                # PREP-ROLLBACK-1 (review F2): with the checkpoint, so a worker
                # that stops in the middle never runs this step again - a
                # resume finishes the rollback. Complete-VmfRollback records
                # rollbackFailed when it fails, as before.
                Set-VmfRollbackPending -Context $ctx -Kind 'full' -State $state -ReasonCode $stopCode -Detail $err -EvidenceRef $bdName
                $doc = Complete-VmfRollback -Context $ctx
            }
            elseif (Test-VmfPrepRollbackWanted -State $state -Exhausted -Doc $doc) {
                # PREP-ROLLBACK-1: the preparation changed the machine before
                # this step failed, so it goes back - never started again half
                # prepared, and never reported as untouched.
                $prepCode = if ($state -eq 'STOPPED') { 'deallocationFailed' } else { Get-VmfErrorStopReason -Message $err }
                Set-VmfRollbackPending -Context $ctx -Kind 'disks' -State $state -ReasonCode $prepCode `
                    -Detail ("The $(Get-VmfStepWord -State $state) step failed after $attempts attempts: $err" -replace '(?<![.!?])$', '.') -Change (Get-VmfGuestChangeThisAttempt -Doc $doc)
                $doc = Complete-VmfRollback -Context $ctx -DurationSec $sw.Elapsed.TotalSeconds
            }
            elseif ($state -eq 'STOPPED') {
                # Nothing the preparation changed (PREP-ROLLBACK-1 above takes
                # that case) - restart the VM and stop there.
                # STOP-POWER-AS-FOUND-1: or put back the power state Checking
                # found, when Checking started the machine.
                $back = Restore-VmfPowerAsFound -Context $ctx
                if ($back) {
                    $powerLeft = @{}
                    if (-not $back.Ok) { $powerLeft.PowerNotPutBack = $back.PowerNotPutBack }
                    $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState $(if ($back.Ok) { 'FAILED_ROLLED_BACK' } else { 'FAILED_NEEDS_ATTENTION' }) `
                        -Outcome fail -Detail "Azure did not stop the machine: $err $($back.Words)" `
                        -ReasonCode 'deallocationFailed' -MachineState $(if ($back.Ok) { 'untouched' } else { 'changed' }) @powerLeft
                }
                else {
                    # POWER-ONLY-CHANGED-1, folding DEALLOC-START-SAID-1: a start
                    # that failed here was never said, and the record said
                    # untouched. Now the start is tried again; still refused,
                    # the stop says so and names the power state running.
                    $start = Restore-VmfPowerAsFound -Context $ctx -Power 'PowerState/running'
                    if ($start.Ok) {
                        $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState 'FAILED_ROLLED_BACK' `
                            -Outcome fail -Detail "Azure did not stop the machine: $err The product started the machine again. Nothing on the machine changed." `
                            -ReasonCode 'deallocationFailed' -MachineState 'untouched'
                    }
                    else {
                        $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState 'FAILED_NEEDS_ATTENTION' `
                            -Outcome fail -Detail "Azure did not stop the machine: $err $($start.Words)" `
                            -ReasonCode 'deallocationFailed' -MachineState 'changed' -PowerNotPutBack 'PowerState/running'
                    }
                }
            }
            else {
                # EVAL-H4: this branch used to claim 'untouched' for
                # SAFETY_PRISTINE and SAFETY_COPY as well - but SAFETY_PRISTINE
                # deallocates BEFORE it snapshots, and SAFETY_COPY runs on a
                # machine already deallocated and never starts it. So a snapshot
                # failure parked a production machine POWERED OFF and reported
                # that nothing had been changed. The adjacent STOPPED branch
                # knew to restart before daring to write 'untouched'; these did
                # not. Derive it: what a state can have done, plus what actually
                # happened when we tried to put the power back.
                $mutates = Get-VmfStateMutates -State $state
                $machineState = 'untouched'
                $extra = ''
                # POWER-ONLY-CHANGED-1: the power state found, when only its
                # put-back was refused.
                $powerLeft = @{}
                if ($mutates -eq 'power') {
                    # STOP-POWER-AS-FOUND-1: back to the power state found.
                    $restore = Resolve-VmfStoppedMachineState -Context $ctx -AsFound
                    $machineState = $restore.MachineState
                    $extra = " - $($restore.Detail)"
                    if ($machineState -eq 'changed' -and $restore.PowerNotPutBack) { $powerLeft.PowerNotPutBack = $restore.PowerNotPutBack }
                }
                elseif ($mutates -eq 'guest' -and $state -ne 'GUEST_PREP') {
                    $machineState = 'changed'
                    $extra = ' - the machine itself may have been changed before this failed'
                }
                else {
                    # STOP-POWER-AS-FOUND-1: Checking and Preparing leave the
                    # power as it is, and Checking may have started the machine.
                    $back = Restore-VmfPowerAsFound -Context $ctx
                    if ($back) {
                        $extra = " - $($back.Detail)"
                        if (-not $back.Ok) { $machineState = 'changed'; $powerLeft.PowerNotPutBack = $back.PowerNotPutBack }
                    }
                }
                # GUEST_PREP lands here only when the audit trail says nothing
                # changed in this attempt (PREP-ROLLBACK-1 above takes the
                # rest), so it is untouched.
                $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState 'FAILED_NEEDS_ATTENTION' `
                    -Outcome fail -Detail ("The $(Get-VmfStepWord -State $state) step failed after $attempts attempts: $err$extra" -replace '(?<![.!?])$', '.') `
                    -ReasonCode (Get-VmfErrorStopReason -Message $err) -MachineState $machineState @powerLeft
            }
        }
    }

    $loopDoc = Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId
    if ($doc.state -notin $script:VmfTerminalStates -and [string]$doc.state -in @('GUEST_PREP', 'STOPPED', 'SAFETY_COPY') -and
        (Test-VmfGuestChangedThisAttempt -Doc $loopDoc)) {
        # PREP-ROLLBACK-1 (review F10): the backstop keeps the rule. A machine
        # the preparation changed that went round STOPPED and GUEST_PREP to
        # the limit is rolled back, never started again prepared - and stays
        # a fault in the product to report (FAILED_NEEDS_ATTENTION).
        $detail = "This machine went through $script:VmfStateLoopLimit steps without ever finishing, so it was stopped at $($doc.state) rather than left going round. This is a fault in the product, not something the machine did."
        Write-VmfStepLine -RunPath $RunPath -Step ([string]$doc.state) -Outcome fail -VmId $ctx.VmId -Detail $detail
        Set-VmfRollbackPending -Context $ctx -Kind 'disks' -State ([string]$doc.state) -ReasonCode 'stepLoopLimit' -Detail $detail `
            -Change (Get-VmfGuestChangeThisAttempt -Doc $loopDoc) -StopState 'FAILED_NEEDS_ATTENTION'
        $doc = Complete-VmfRollback -Context $ctx
    }
    if ($doc.state -notin $script:VmfTerminalStates) {
        # Only reachable by exhausting the backstop: the handlers kept handing
        # the machine to one another without ever settling. Say so where a
        # person looks, and put the power back if a state that can stop the
        # machine is where it ended up.
        $mutates = Get-VmfStateMutates -State ([string]$doc.state)
        $machineState = 'untouched'
        $extra = ''
        # POWER-ONLY-CHANGED-1: the power state found, when only its put-back
        # was refused.
        $powerLeft = @{}
        if ($mutates -eq 'power') {
            # STOP-POWER-AS-FOUND-1: back to the power state found.
            $restore = Resolve-VmfStoppedMachineState -Context $ctx -AsFound
            $machineState = $restore.MachineState
            $extra = " - $($restore.Detail)"
            if ($machineState -eq 'changed' -and $restore.PowerNotPutBack) { $powerLeft.PowerNotPutBack = $restore.PowerNotPutBack }
        }
        elseif ($mutates -ne 'no') {
            $machineState = 'changed'
            $extra = ' - the machine itself may have been changed'
        }
        else {
            $back = Restore-VmfPowerAsFound -Context $ctx
            if ($back) {
                $extra = " - $($back.Detail)"
                if (-not $back.Ok) { $machineState = 'changed'; $powerLeft.PowerNotPutBack = $back.PowerNotPutBack }
            }
        }
        $detail = "This machine went through $script:VmfStateLoopLimit steps without ever finishing, so it was stopped at $($doc.state) rather than left going round. This is a fault in the product, not something the machine did.$extra"
        Write-VmfStepLine -RunPath $RunPath -Step ([string]$doc.state) -Outcome fail -VmId $ctx.VmId -Detail $detail
        $doc = Add-VmfStateTransition -RunPath $RunPath -VmId $ctx.VmId -NewState 'FAILED_NEEDS_ATTENTION' `
            -Outcome fail -Detail $detail -ReasonCode 'stepLoopLimit' -MachineState $machineState @powerLeft
    }

    }
    finally {
        $script:VmfOpHeartbeat = $null
        # PERF-TELEMETRY-ENGINE-1: a step a lost lease stopped leaves no
        # record open in this worker.
        $null = Stop-VmfStepCallTimings
        # ENGINE-SUB-1: put the process back where it was, so a worker that
        # goes on to lease a machine in another subscription starts clean and
        # an operator running this inline keeps their own context.
        Restore-VmfSubscriptionContext -Context $previousAzContext
    }

    Read-VmfStateDoc -RunPath $RunPath -VmId $ctx.VmId
}

# WORDS-ROLL-1: the words for "starting again", in the step names the pages
# show. The log said "with a clean slate: CONVERTING attempt count cleared, so
# this attempt is not judged by the last one" - engine vocabulary an operator
# cannot act on.
function Get-VmfStepWord {
    <#
    .SYNOPSIS
        MANUAL-REVIEW-1: the name of a step as the pages show it (UX_STATE in
        migrations.js), for the words of a stop or a retry. An engine line
        named the state (CONVERTING), which no page shows a person.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State)
    # Two steps show Backing up on the pages; the words say which copy.
    $word = @{ PRECHECK = 'Checking'; SAFETY_PRISTINE = 'Backing up (the first safety copy)'; GUEST_PREP = 'Preparing'; STOPPED = 'Shutting down'
               SAFETY_COPY = 'Backing up (the second safety copy)'; CONVERTING = 'Moving'; STARTING = 'Starting up'; VALIDATING = 'Verifying' }[$State]
    if ($word) { $word } else { $State }
}

function Get-VmfRearmWords {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$From)
    "The next attempt starts again at $(Get-VmfStepWord -State $From). Earlier attempts are not counted against it."
}
