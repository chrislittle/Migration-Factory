function Resolve-VmfDecision {
    <#
    .SYNOPSIS
        Resolve a NEEDS_DECISION parking state for one VM: record the decision,
        optionally override the plan entry's policy, and re-arm the VM so the
        next wave invocation picks it up (architecture section 7 - a parking
        state is "resolved by editing the plan and re-running").
    .DESCRIPTION
        The override applies to ONLY the named VM's plan entry - resolutions
        are per-VM audit events, never blanket policy changes. Each setting it
        changes is recorded on that entry (plan-entry v17 `decisions`), so a
        wave save never writes over it (WAVE-LEVER-OVERRIDE-1). The state doc
        returns to PRECHECK, which re-verifies every fact just-in-time before
        anything mutates, so a stale parked VM can never skip its checks.
    .EXAMPLE
        Resolve-VmfDecision -RunPath $run -PlanPath $plan -VmId $id `
            -PolicyOverride @{ onDDataFound = 'proceed' } `
            -Note 'Terraform reconciliation workflow acknowledged by app team' `
            -ResolvedBy 'operator@example.com'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][hashtable]$PolicyOverride,
        # PRECHECK re-runs the whole machine (facts re-verified just-in-time).
        # VALIDATING re-runs only the non-mutating validation pass - for
        # FAILED_NEEDS_ATTENTION holds where the conversion itself succeeded
        # (e.g. a validation-logic fix) and a full re-conversion cycle would
        # be pointless churn. Parks (NEEDS_DECISION) always restart at
        # PRECHECK: nothing was verified yet.
        # RETRY-1: the operator no longer picks this. "Run the safety checks
        # again" versus "only repeat the final health checks" was engine
        # vocabulary dressed as a question, and the engine already knows the
        # answer: a machine whose conversion succeeded and whose VALIDATING
        # pass failed re-validates; everything else starts over at PRECHECK,
        # which re-verifies every fact just-in-time. Left overridable for an
        # engineer, defaulted to derived for everyone else.
        [Parameter()][ValidateSet('PRECHECK', 'VALIDATING')][string]$ReturnTo,
        [Parameter(Mandatory)][string]$Note,
        [Parameter()][string]$ResolvedBy = [Environment]::UserName,
        # DECIDE-ROLE-1: the caller may accept THE decision this machine waits
        # for, and nothing else - the service sets this for an approver who is
        # not an operator. Everything else this call can do is a retry, and a
        # retry is the operator's. So it is refused before anything is written
        # unless the machine waits for a decision, the change names exactly
        # that decision's setting, and the value is exactly its accepting one.
        [Parameter()][switch]$DecisionOnly,
        # DECIDE-ROLE-1: the roles that let the caller do this, written into
        # the event beside the name, so the record shows which rule allowed it.
        [Parameter()][string[]]$ResolvedRoles = @()
        # REBUILD-REMOVE-ACCEPT-1: -IdentityLossPrincipalId and
        # -RebuildExtensions are gone. No decision accepts the loss of an
        # identity or a rebuild any more: 'rebuild' and
        # 'onSystemAssignedIdentity' are not settings (Test-VmfPolicyOverride
        # refuses them by name), and a plan that rebuilds stops in PRECHECK.
    )

    # VMID-CASE-1: the ID as this run's record spells it, whatever case it came in.
    $VmId = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { throw "No state document for '$VmId' in this run." }
    # RETRY-1: FAILED_ROLLED_BACK belongs here too. A machine that failed and
    # was put back automatically is the single best retry candidate there is -
    # it is running, as it was, and the cause is usually named in its own
    # history. Refusing it meant the safest failure in the system was the one
    # an operator could not act on.
    if ($doc.state -notin @('NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK')) {
        throw "VM '$VmId' is not waiting for a person (current state: $($doc.state)) - nothing to retry."
    }
    if ($DecisionOnly) {
        $name = ($VmId -split '/')[-1]
        if ($doc.state -ne 'NEEDS_DECISION') {
            throw "400: Nothing changed for $name, because it does not wait for a decision. An operator can try it again."
        }
        # The park the machine waits at NOW - the last history entry, a
        # NEEDS_DECISION park with nothing rebuilt or restored since. The run
        # page asks the same rule (decision-waiting.json).
        $parkedBy = Get-VmfWaitingDecisionStop -Document $doc
        $guide = if ($parkedBy) { Get-VmfStopGuidance -Code ([string]$parkedBy.reasonCode) } else { $null }
        $decide = if ($guide -and $guide.PSObject.Properties['decide']) { $guide.decide } else { $null }
        if (-not $decide) {
            throw "400: Nothing changed for $name, because its stop has no decision to accept. An operator can try it again."
        }
        $sent = @(if ($PolicyOverride) { @($PolicyOverride.Keys) })
        # Assigned, not taken from an if: an if's output unrolls a one-item
        # list into its item, and a list would pass as the text in it.
        $value = $null
        if ($sent.Count -ge 1) { $value = $PolicyOverride[$sent[0]] }
        # ORDINAL, not -ceq: PowerShell compares text by culture even with
        # case, and a culture ignores zero-width characters and soft hyphens,
        # so 'pro' + U+200B + 'ceed' compared equal to 'proceed' and was
        # stored as eight characters the pages never read as proceed.
        $ordinal = [System.StringComparison]::Ordinal
        if ($sent.Count -ne 1 -or -not [string]::Equals([string]$sent[0], [string]$decide.lever, $ordinal) -or
            $value -isnot [string] -or -not [string]::Equals($value, [string]$decide.accept, $ordinal)) {
            throw "400: Nothing changed for $name. Its stop accepts one change only: $($decide.lever) set to $($decide.accept)."
        }
    }
    # WAVE-APPROVE-1: is this an APPROVER accepting the one decision the
    # machine waits for - its setting, exactly its accepting value, and
    # nothing else (DECIDE-ROLE-1's single decision)? Only then does the
    # decision carry the wave's approval past its write. Any other change -
    # an operator's, another setting, more than one - is a change to the wave
    # that no approver saw, so the wave asks again for its approval.
    $approverAccepts = $false
    $sentKeys = @(if ($PolicyOverride) { @($PolicyOverride.Keys) })
    $ordinalRole = { param([string]$role) @($ResolvedRoles | Where-Object { [string]::Equals([string]$_, $role, [System.StringComparison]::Ordinal) }).Count -gt 0 }
    if ($doc.state -eq 'NEEDS_DECISION' -and $sentKeys.Count -eq 1 -and ((& $ordinalRole 'Vmf.Approver') -or (& $ordinalRole 'Vmf.Admin'))) {
        $waitsAt = Get-VmfWaitingDecisionStop -Document $doc
        $howTo = if ($waitsAt) { Get-VmfStopGuidance -Code ([string]$waitsAt.reasonCode) } else { $null }
        $accept = if ($howTo -and $howTo.PSObject.Properties['decide']) { $howTo.decide } else { $null }
        $sentValue = $PolicyOverride[$sentKeys[0]]
        $approverAccepts = [bool]($accept -and [string]::Equals([string]$sentKeys[0], [string]$accept.lever, [System.StringComparison]::Ordinal) -and
            $sentValue -is [string] -and [string]::Equals($sentValue, [string]$accept.accept, [System.StringComparison]::Ordinal))
    }
    if (-not $ReturnTo) { $ReturnTo = Get-VmfRetryEntryState -Document $doc }
    if ($ReturnTo -eq 'VALIDATING' -and $doc.state -eq 'NEEDS_DECISION') {
        throw "A NEEDS_DECISION park must return to PRECHECK - its facts were never verified. -ReturnTo VALIDATING is only for FAILED_NEEDS_ATTENTION holds."
    }

    # SAFETY-RETRY-1: a retry from the first step is a complete new run, with
    # new safety copies. A machine a stop left CHANGED (a failed rollback) is not as it was, so
    # a new "as it was" copy of it would be wrong: it is rebuilt or restored
    # first (the run page offers both), and then tried again.
    # ROLLBACK-RETRY-CAPTURE-1: the rule is Test-VmfRetryHeld, so the run page
    # can be held to the same cases (tests/fixtures/retry-held.json) and offer
    # Try this machine again only where this would accept it.
    # SWAP-REFUSED-AFTER-STOP-1: and nothing at all - a retry, a validation
    # again or a decision - while a refused swap keeps the machine stopped.
    $swapRefusal = Get-VmfSwapPendingRefusal -Doc $doc -VmName (($VmId -split '/')[-1])
    if ($swapRefusal) { throw "400: $swapRefusal" }
    # RESTORE-END-JOB-1: nor while a restore of the machine has
    # not ended - it resumes by itself, and a wave on the machine would change
    # it under that job.
    $jobRefusal = Get-VmfPutBackJobRefusal -Doc $doc -VmName (($VmId -split '/')[-1])
    if ($jobRefusal) { throw "400: $jobRefusal" }
    if ($ReturnTo -eq 'PRECHECK' -and (Test-VmfRetryHeld -Doc $doc)) {
        $name = ($VmId -split '/')[-1]
        throw "400: The last stop left $name changed, so it is not as it was. Restore it first, then try it again."
    }
    # VOLUMES-RETRY-CHECK-1: a machine whose record owes a check of its
    # volumes is tried again from Checking only, where that check is the
    # first step. Verifying alone would skip it.
    $volumesOwed = Get-VmfVolumesCheckOwed -Doc $doc
    if ($volumesOwed -and $ReturnTo -ne 'PRECHECK') {
        $name = ($VmId -split '/')[-1]
        throw "400: Nothing changed for $name. The product must first check that every volume mounted before the move is mounted again, and that check is the first step of Checking."
    }

    # DECIDE-CARRY-KILL-1: a decision on this machine whose process stopped
    # after its plan write and before its carry is finished first - while the
    # plan is still the text it wrote - so the wave's records sign that plan
    # and the gate below can pass. Only the carry: what it moved is said in the
    # run history, and the decision made again goes on as usual.
    $finished = Complete-VmfPendingDecisionCarry -RunPath $RunPath -PlanPath $PlanPath -VmId $VmId

    # PLAN-WRITE-RACE-1: the version of the text read, so the write below is
    # refused if anybody wrote the plan in between.
    $read = Read-VmfPlanFileVersioned -Path $PlanPath
    if (-not $read) { throw "There is no plan at $PlanPath." }
    $plan = $read.Plan
    $entry = @($plan.entries) | Where-Object { $_.vmId -eq $VmId } | Select-Object -First 1
    if (-not $entry) { throw "There is no plan entry for '$VmId' in $PlanPath." }

    if ($PolicyOverride) {
        # EVAL-H12: refuse a setting the product does not have, by name. The old
        # behaviour accepted anything, echoed it into the history so it looked
        # handled, did nothing - and, because any key changes the wave-options
        # hash, refused the ENTIRE WAVE at its next start for a wave nobody
        # edited. REBUILD-REMOVE-ACCEPT-1: 'rebuild' was checked apart, as the
        # acceptance of a rebuild; it is now a setting the product does not
        # have, like any other.
        $overrideCheck = Test-VmfPolicyOverride -Override $PolicyOverride
        if (-not $overrideCheck.Ok) { throw "That change cannot be applied: $($overrideCheck.Detail)" }
    }

    # RETRY-GATE-1: a machine re-armed in a wave that cannot start waits at
    # PRECHECK for an acceptance or a sign-off nobody is told about. There it
    # reads as running, Skip and a second retry refuse it, and the wave editor
    # and a reservation release treat the wave as running. So the retry asks
    # the engine's own start gates - the list the restart timer asks before it
    # starts a wave again - and refuses before anything is changed, in the
    # gate's own words, so the person knows the step that is missing. The one
    # line it may write is the refusal for changed settings (GATE-WORDS-1).
    $wave = [string]$entry.wave
    $machine = ($VmId -split '/')[-1]
    # A started machine cannot leave its wave (Set-VmfWavePlan refuses), so
    # this is a record the engine cannot start, said as a refusal.
    if (-not $wave) { throw "400: Nothing changed for $machine, because its plan entry names no wave, and only a wave starts a machine." }
    $refuseFor = { param($gate, [string]$lead)
        # GATE-WORDS-1: a refusal for changed settings tells the person to
        # select Review & accept options again. The page offers that button
        # only after the engine logs this refusal (acceptanceRefused), as the
        # wave start and the restart timer already do. Said once.
        if ([string]$gate.Code -eq 'changed') {
            Write-VmfOptionsChangedRefusal -RunPath $RunPath -Wave $wave -Detail ([string]$gate.Detail) | Out-Null
        }
        $why = ([string]$gate.Detail).Trim()
        if ($why -notmatch '[.!?]$') { $why += '.' }
        throw "400: $lead $why Then try this machine again."
    }
    $gate = Get-VmfWaveStartGate -RunPath $RunPath -PlanPath $PlanPath -Plan $plan -Wave $wave
    if ($gate) { & $refuseFor $gate "Nothing changed for $machine, because wave $wave cannot start." }

    # DECIDE-APPROVAL-STALE-1: the approvals this decision's write removed, and
    # of those the waves that cannot start without one now. A retry with no
    # setting change writes no plan, so it removes none.
    $staleApprovals = @()
    $approvalsToRenew = @()
    $carryLeft = @(if ($finished) { @($finished.Left) })
    if ($PolicyOverride) {
        # DECIDE-KEEP-1: read what the wave's acceptance and the plan sign-off
        # are bound to BEFORE the write, so they can be carried past it.
        # PLAN-WRITE-RACE-1: from the text read above - the text the write is
        # checked against - not from a second read.
        $before = Get-VmfDecisionSnapshot -Text $read.Text -Wave ([string]$entry.wave)

        foreach ($k in $PolicyOverride.Keys) {
            # WAVE-LEVER-OVERRIDE-1: what the setting MEANT before, so the same
            # decision made again keeps its record (below).
            $before_k = ConvertTo-VmfPolicyLeverValue -Name ([string]$k) -Value (Get-VmfPolicy -PlanEntry $entry -Name ([string]$k))
            $after_k = ConvertTo-VmfPolicyLeverValue -Name ([string]$k) -Value $PolicyOverride[$k]
            $same_k = $null -ne $before_k -and $null -ne $after_k -and $before_k -is $after_k.GetType() -and $before_k -eq $after_k
            # A value already STORED as this answer is left where it is.
            # Add-Member -Force removes a property and adds it again at the
            # end, so writing the same answer reordered the policy and changed
            # the plan text with nothing changed.
            $stored_k = ($entry.policy -is [pscustomobject] -and $entry.policy.PSObject.Properties[[string]$k]) -or
                        ($entry.policy -is [System.Collections.IDictionary] -and $entry.policy.Contains($k))
            # OLD-VERSION-READERS-REMOVE-3: a count (keepSnapshotDays, throttle)
            # is stored as a whole number, never as the text it was sent as, so
            # PRECHECK's rule (Get-VmfPlanPolicyRefusal) never stops a value a
            # decision wrote. Test-VmfPolicyOverride has already checked it.
            $kind_k = (Get-VmfPolicyLevers)[[string]$k]
            $write_k = if ($kind_k -is [string] -and $kind_k -in @('days', 'machines')) { $after_k } else { $PolicyOverride[$k] }
            if ($same_k -and $stored_k) { }
            elseif ($entry.policy -is [pscustomobject]) {
                $entry.policy | Add-Member -NotePropertyName $k -NotePropertyValue $write_k -Force
            }
            else { $entry.policy[$k] = $write_k }
            # WAVE-LEVER-OVERRIDE-1: and SAY that this machine's value is its
            # own. Nothing recorded it, so the wave editor drew a wave's
            # settings from its first machine and the next save wrote the
            # card's value over this answer - or spread it to the whole wave.
            # A wave save never writes over a setting recorded here.
            # Not for a setting of the WAVE (capacity, sign-off, how many at
            # once): the engine reads one value for the wave, so the next
            # change of the wave writes it on every machine.
            # The same decision made again (the value already its own) keeps
            # the record it has: a new time on it would change the entry, and
            # an approval signs the wave's entries (WAVE-APPROVE-1) - so a
            # retry after approving the wave again would void the approval
            # again, every time (RETRY-GATE-1).
            $ownNeeded = -not (Test-VmfWaveWideField -Setting ([string]$k)) -and -not ($same_k -and (Test-VmfOwnDecision -PlanEntry $entry -Setting ([string]$k)))
            if ($ownNeeded) {
                Set-VmfOwnDecision -PlanEntry $entry -Setting ([string]$k) -By $ResolvedBy -Confirm:$false
            }
        }
        # WAVE-AN-NAMES-1: a decision that sets accelerated networking changes
        # whether the move turns it on, so the record follows it. An answer
        # that stays the same is left as it is.
        # MANA-WIN-3: and the note that the move can download the MANA driver.
        if ($PolicyOverride.ContainsKey('acceleratedNetworking')) {
            Set-VmfPlannedAnOutcome -PlanEntry $entry -Confirm:$false -WhatIf:$false
            Set-VmfManaDriverDownloadNote -PlanEntry $entry -Confirm:$false -WhatIf:$false
        }
        $written = $plan | ConvertTo-Json -Depth 24

        $change = (@($PolicyOverride.Keys | Sort-Object | ForEach-Object { "$_=$($PolicyOverride[$_])" }) -join ', ')
        # DECIDE-CARRY-KILL-1: the note of the carry below, written BEFORE the
        # plan, so a process that stops between the plan write and the carry
        # leaves what the next call needs to finish it. Removed after the
        # carry; a refused plan write removes it at once.
        $decidedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $noteRel = Get-VmfDecisionCarryNotePath -VmId $VmId
        $noteText = New-VmfDecisionCarryNoteText -Before $before -AfterText $written -VmId $VmId -Change $change `
            -ResolvedBy $ResolvedBy -DecidedUtc $decidedUtc -CarryWaveApproval:$approverAccepts
        $noteVersion = Get-VmfDocumentVersion -Text $noteText
        Write-VmfStoreText -RunPath $RunPath -RelPath $noteRel -Content $noteText
        try { Write-VmfTextDocumentIfVersion -Path $PlanPath -Content $written -ExpectedVersion $read.Version }
        catch {
            # A refusal (409) means this plan was never written, so its note
            # names nothing. Anything else may have written it: the note stays.
            if (([string]$_.Exception.Message).StartsWith('409:', [System.StringComparison]::Ordinal)) {
                [void](Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $noteRel -ExpectedVersion $noteVersion)
            }
            throw
        }

        # DECIDE-CARRY-RACE-1: each record is written back only over the text
        # the carry read. One written since is left as it is, said in the run
        # history and named in CarryLeft. The decision stays saved either way:
        # the removal and the start gate below judge the records as STORED, so
        # the machine is tried again only if they cover this decision.
        $carried = Invoke-VmfDecisionCarryForward -RunPath $RunPath -PlanPath $PlanPath -Before $before -AfterText $written -VmId $VmId `
            -Change $change -ResolvedBy $ResolvedBy -CarryWaveApproval:$approverAccepts -DecidedUtc $decidedUtc
        $carryLeft = @($carryLeft) + @($carried.Left)
        # DECIDE-CARRY-KILL-1: the carry is done, so its note goes - only the
        # text this call wrote.
        [void](Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $noteRel -ExpectedVersion $noteVersion)

        # WAVE-SAVE-FALSE-1, applied here by RETRY-GATE-1's review: an approval
        # this write left out of date is removed as every other plan writer
        # removes them - kept, the run page shows "Approved by ..." with no
        # Approve button, while the engine refuses the wave. WAVE-APPROVE-1: a
        # wave approval signs its own wave, and the carry above moved this
        # wave's, so only an approval written before (v1, the whole plan) goes.
        # Judged against the plan as STORED NOW, as the other writers judge it:
        # the carry moved the approval onto the text this decision wrote, and
        # a writer landing after it made that out of date. Judged against our
        # own text, the file stayed - "Approved by" on the page, a refusal in
        # the engine. Removing by the stored plan can only remove more.
        $staleApprovals = @(Remove-VmfStaleWaveApprovals -RunPath $RunPath -PlanPath $PlanPath)

        # RETRY-GATE-1: an approval the carry could not keep - one already out
        # of date, or a v1 one - leaves a wave that cannot start after this
        # write, so the machine is not re-armed - the change stays written,
        # and is said, with the person's note on the record.
        $after = Read-VmfPlanFileVersioned -Path $PlanPath
        # DECIDE-APPROVAL-STALE-1: a decision carries the plan sign-off past
        # its write, and a current sign-off passes every wave of the plan
        # (Test-VmfWaveApproval), so a removed approval is not always a step
        # to take again. The engine's own approval gate says which waves now
        # need one; the others can start without it.
        $approvalsToRenew = @($staleApprovals | Where-Object { -not (Test-VmfWaveApproval -RunPath $RunPath -PlanPath $PlanPath -Wave $_).Pass })
        $gate = Get-VmfWaveStartGate -RunPath $RunPath -PlanPath $PlanPath -Plan $after.Plan -Wave $wave
        if ($gate) {
            $gone = if ($staleApprovals.Count) { " The approval of wave $(@($staleApprovals) -join ', ') no longer matched the plan and was removed." } else { '' }
            # STEP-LOG-4: written after the plan is saved, so a line that cannot be
            # written never replaces the refusal that says the change is saved.
            Write-VmfStepLine -RunPath $RunPath -Step 'decision' -Outcome refused -VmId $VmId `
                -Detail "$ResolvedBy changed $change for this machine: $Note. Wave $wave cannot start now, so the machine was not tried again.$gone" `
                -Data @{ change = $change; wave = $wave; resolvedRoles = @($ResolvedRoles) }
            & $refuseFor $gate "The change ($change) is saved, but wave $wave cannot start now, so $machine was not tried again.$gone"
        }
    }

    $last = @($doc.history)[-1]
    $parkDetail = $last.detail
    $parkCode = [string]$last.reasonCode
    # REBUILD-ACCEPT-MACHINE-1: the machine's history in product words. It
    # read "<note>.. policy: rebuild=accept. Re-armed at PRECHECK for the next
    # wave run." - a second full stop after a note that had one, and engine
    # words. A setting is named by its plan name (DECISION-LINE-NAMES-1).
    $overrideText = -join @(if ($PolicyOverride) {
            foreach ($k in @($PolicyOverride.Keys | Sort-Object)) { " The setting $k of this machine is now $($PolicyOverride[$k])." }
        })
    $stageName = if ($ReturnTo -eq 'VALIDATING') { 'Verifying' } else { 'Checking' }
    # EVAL-H3/L1: a machine being re-armed must not be judged by the attempt
    # that failed, and must not skip work a previous attempt got through. The
    # docstring already promised "a stale parked VM can never skip its checks";
    # nothing had made that true.
    # SAFETY-RETRY-1: a person's retry is a new attempt, with its own copies.
    # VOLUMES-RETRY-CHECK-1: but not yet when the record owes a check of the
    # volumes. The service cannot run a script inside the machine, so the
    # engine checks first, at Checking, and takes the new attempt only when
    # every volume is mounted again (Invoke-VmfVolumesCheckBeforeRetry). Until
    # then the copies, the reading before the move and the record stay as
    # they are, so a check that fails changes nothing.
    if (-not $volumesOwed) { Clear-VmfRetryState -RunPath $RunPath -VmId $VmId -From $ReturnTo -NewAttempt }

    # DECIDE-APPROVAL-STALE-1: the write above removed every wave approval it
    # made stale - since WAVE-APPROVE-1 only approvals written before, which
    # signed the whole plan text. Said here, as a wave save and a
    # target change say it, so a person who approved one of those waves reads
    # why it is unapproved, and whether it must be approved again. Nothing
    # said it before. The activity shows this line on the screen when it names
    # a wave (approvalsCleared), and the machine's history carries it too.
    $covered = @($staleApprovals | Where-Object { $_ -notin $approvalsToRenew })
    $approvalNote = if ($staleApprovals.Count) { ' ' + (Get-VmfStaleApprovalNote -Wave $approvalsToRenew -StillCovered $covered) } else { '' }
    $noteSaid = if ($Note -match '[.!?]$') { $Note } else { "$Note." }
    # DECIDE-CARRY-RACE-1: and in the machine's history, which the machine
    # panel shows in full: a record somebody changed while this decision was
    # saved was kept as they wrote it, without this decision on it.
    $leftNames = @($carryLeft | ForEach-Object {
        switch ($_) { 'acceptance' { "the accepted settings of wave $wave" } 'approval' { "the approval of wave $wave" } default { 'the plan sign-off' } } })
    $leftNote = -join @($leftNames | ForEach-Object { " Somebody changed $_ while the product saved this decision. The product kept that record as it is." })
    # DECIDE-CARRY-KILL-1: and a save of an earlier decision that this call
    # completed, so the panel says why the wave's records name that decision.
    $finishNote = if ($finished) { " The product stopped before it completed the save of the decision by $($finished.DecidedBy) ($($finished.Change)). The product completed that save now." } else { '' }
    $updated = Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState $ReturnTo -Outcome ok `
        -Detail "Decision resolved by ${ResolvedBy}: $noteSaid$overrideText The machine returns to $stageName.$approvalNote$finishNote$leftNote"
    # STEP-LOG-4: written after the machine is re-armed, so a line that cannot
    # be written never reports the decision as failed.
    # MIGRATIONS-DECISION-WORDS-1: the button the operator selected, so the
    # Migrations page names it - Try this machine again sends no setting
    # change (retry), Accept this and continue sends one (accept). Judged as
    # the plan write above judges it.
    $choice = if ($PolicyOverride) { 'accept' } else { 'retry' }
    Write-VmfStepLine -RunPath $RunPath -Step 'decision' -Outcome ok -VmId $VmId `
        -Detail $(if ($approvalNote) { "Decision resolved by ${ResolvedBy}: $noteSaid$approvalNote" } else { "resolved by ${ResolvedBy}: $Note" }) `
        -Data @{ choice = $choice; reasonCode = $parkCode; returnTo = $ReturnTo; approvalsCleared = @($staleApprovals); approvalsToRenew = @($approvalsToRenew); resolvedRoles = @($ResolvedRoles) }
    # APPROVE-GROUP-1: the list on the Migrations page counts this machine
    # again. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -PlanPath $PlanPath -Reason 'decision' -Wave ([string]$entry.wave) | Out-Null
    # SCHEDULE-PASS-DUE-1: the machine is back at a working state, and when no
    # part of its wave runs the five-minute pass starts it again ("Waits for the
    # service's next check"), so the pass checks this run. Never throws.
    Add-VmfRunScheduleDue -RunPath $RunPath -Reason 'decision' | Out-Null

    [pscustomobject]@{
        VmId       = $VmId
        NewState   = $updated.state
        ParkReason = $parkDetail
        ReasonCode = $parkCode
        ReturnTo   = $ReturnTo
        ResolvedBy = $ResolvedBy
        Note       = $Note
        # The waves whose approval this decision removed, and of those the
        # waves that must be approved again before they start - for the page.
        ApprovalsCleared = @($staleApprovals)
        ApprovalsToRenew = @($approvalsToRenew)
        # DECIDE-CARRY-RACE-1: the records this decision was not written on,
        # because somebody changed them while it was saved (acceptance,
        # approval, signOff).
        CarryLeft        = @($carryLeft)
    }
}
