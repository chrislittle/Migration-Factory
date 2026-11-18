# Wave orchestration primitives (architecture section 9). Workers share NO
# memory - every coordination decision goes through the state store: leases for
# mutual exclusion, state docs for progress, a halt flag for the breaker.

function Set-VmfWaveHalt {
    <#
    .SYNOPSIS
        Halt a wave: no NEW leases are granted; in-flight VMs run to a safe
        state. Written by the breaker or an operator; workers only read it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][string]$Reason = 'operator halt'
    )
    Write-VmfStoreJson -RunPath $RunPath -RelPath 'halt.flag' -Document ([ordered]@{
        haltedUtc = (Get-Date).ToUniversalTime().ToString('o')
        reason    = $Reason
    })
    # STEP-LOG-2: the halt is in force once the flag is written. A line that
    # cannot be written must not report the halt as failed, nor stop the list
    # below from showing it.
    Write-VmfStepLine -RunPath $RunPath -Step 'wave' -Outcome warn -Detail "HALTED: $Reason"
    # APPROVE-GROUP-1: the list shows a paused migration. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'paused' | Out-Null
}

function Test-VmfWaveHalted {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RunPath)
    Test-VmfStoreItem -RunPath $RunPath -RelPath 'halt.flag'
}

function Test-VmfApprovalRequired {
    <#
    .SYNOPSIS
        SIGNOFF-NULL-1: does this plan entry require a person's sign-off
        before its wave runs? The ONE answer every reader uses.
    .DESCRIPTION
        Fails safe: only a stored boolean false turns the sign-off off. A
        missing policy, a missing key, null, 0, an empty string, the text
        'false' - anything else - reads as required (WAVE-2 lever 2,
        ruled: approval is on by default).
        Four readers used to answer for themselves, and a stored null or 0
        was required to some and not to others: the engine's gate passed a
        wave the pages showed as waiting, or named Approve while the page
        offered no Approve button.
        The pages hold the same rule (VmfHelp.approvalRequired in
        src/dashboard/help.js); tests/fixtures/approval-required.json holds
        both to the same cases.
    .OUTPUTS
        [bool]
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$PlanEntry)
    $policy = $null
    if ($PlanEntry -is [System.Collections.IDictionary]) { $policy = $PlanEntry['policy'] }
    elseif ($null -ne $PlanEntry -and $PlanEntry.PSObject.Properties['policy']) { $policy = $PlanEntry.policy }
    $value = $null
    if ($policy -is [System.Collections.IDictionary]) { $value = $policy['requireApproval'] }
    elseif ($null -ne $policy -and $policy.PSObject.Properties['requireApproval']) { $value = $policy.requireApproval }
    -not ($value -is [bool] -and -not $value)
}

function Test-VmfWaveApproval {
    <#
    .SYNOPSIS
        APPR-1 gate: a requireApproval wave passes only with an approval
        artifact that still signs THIS WAVE of the current plan text
        (WAVE-APPROVE-1: Test-VmfWaveApprovalCurrent). Fails closed.
    .PARAMETER PlanText
        The plan text to judge. Start-VmfWave passes the text its other checks
        judged and its workers compare, so every check speaks of one plan.
        Omitted: the plan is read from PlanPath.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][AllowEmptyString()][string]$PlanText
    )

    $planText = if ($PSBoundParameters.ContainsKey('PlanText')) { $PlanText } else { Read-VmfTextDocument -Path $PlanPath }
    $plan = $planText | ConvertFrom-Json -Depth 24
    $entries = @($plan.entries | Where-Object { $_.wave -eq $Wave })
    # WAVE-2 lever 2 (ruled): approval is ON by default, and an entry
    # that says NOTHING about it is treated as requiring approval. The old
    # reading - absent means not required - meant a hand-written or partially
    # migrated plan silently lost its gate, which is the failure direction this
    # gate exists to prevent. Only an explicit false switches it off.
    # SIGNOFF-NULL-1: the one rule, so a stored null or 0 reads as required
    # here as it does on every page.
    $required = @($entries | Where-Object { Test-VmfApprovalRequired -PlanEntry $_ })
    if ($required.Count -eq 0) {
        return @{ Pass = $true; Detail = 'this wave was set not to need a separate approval' }
    }

    # PLANRUN-1: a plan sign-off whose plan version is the plan's version now
    # passes every wave in it - fail-closed exactly like a wave approval. Since
    # WAVE-APPROVE-1 a sign-off writes one approval per wave as well, so this
    # carries only a sign-off for the exact plan (one written before, or one a
    # decision carried forward).
    $planSigned = Test-VmfPlanSignedOff -RunPath $RunPath -PlanText $planText
    $approval = Read-VmfStoreJson -RunPath $RunPath -RelPath "approvals/$Wave.json" -Depth 8
    if (-not $approval) {
        if ($planSigned.Pass) { return @{ Pass = $true; Detail = $planSigned.Detail } }
        # GATE-WORDS-1: the words are in data/start-gates.json, with the code.
        return (New-VmfStartGateRefusal -Code 'notApproved' -Wave $Wave)
    }
    # WAVE-APPROVE-1: the one rule, the same one Approve-VmfWave signs with and
    # Remove-VmfStaleWaveApprovals judges by - this wave's version (PLANVER-2).
    if (-not (Test-VmfWaveApprovalCurrent -Approval $approval -Wave $Wave -PlanText $planText)) {
        if ($planSigned.Pass) { return @{ Pass = $true; Detail = $planSigned.Detail } }
        return (New-VmfStartGateRefusal -Code 'approvalOutOfDate' -Wave $Wave)
    }
    @{ Pass = $true; Detail = "approved by $($approval.approvedBy.identity) at $($approval.approvedUtc)" }
}

function Remove-VmfStaleWaveApprovals {
    <#
    .SYNOPSIS
        WAVE-SAVE-FALSE-1: remove every wave approval that no longer matches
        the plan, after a write of the plan.
    .DESCRIPTION
        The writers removed only the approval of the wave they changed, so an
        approval that had stopped matching stayed in place: the page showed
        "Approved by ..." with no Approve button, and the engine refused to
        start the wave. Every approval that no longer signs its wave of the
        plan as written is removed here, by the gate's own rule
        (Test-VmfWaveApprovalCurrent), and the waves are returned so the
        caller says so.
        WAVE-APPROVE-1: an approval signs its own wave, so a change to wave-2
        removes wave-2's approval and keeps wave-1's. An approval written
        before (v1, the whole plan) stops matching at any change, and goes.
        The page trusts an approval file that exists, so this removal is what
        keeps "Approved by" on the screen true.
        STALE-APPROVAL-RACE-1: judged against the plan AS STORED, read after
        the approval, and removed only if the approval still holds the text
        that was judged (Remove-VmfStoreItemIfVersion, one step). It was
        judged against a text the caller read first and removed by an
        ordinary delete, so another writer's save and an approval of that
        newer plan in the moment between lost a valid approval. An approval
        that changed is judged again. And if the plan changed after the
        judgement to a wave the removed approval signs, it is put back, and
        judged again. An empty approval is removed; one that cannot be read,
        or keeps changing, is kept and the run history says so.
    .PARAMETER PlanPath
        The plan's handle. Read here, for each approval, after the approval.
    .OUTPUTS
        The names of the waves whose approval was removed.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath
    )
    $files = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'approvals' -Extension '.json')
    if (-not $files.Count) { return @() }
    # The gate reads approvals/<wave>.json for wave <wave>, so the file name
    # is the wave this approval is judged for.
    # Ordinal throughout: wave-1 and WAVE-1 are two waves with two files on
    # blob storage, and a dictionary or a unique that ignores case would judge
    # one by the other's version.
    $judge = {
        param([string]$approvalText, [string]$w, [string]$planText)
        $doc = $null
        try { if ($approvalText) { $doc = $approvalText | ConvertFrom-Json -Depth 8 } } catch { $doc = $null }
        Test-VmfWaveApprovalCurrent -Approval $doc -Wave $w -WaveVersion (Get-VmfWaveVersion -PlanText $planText -Wave $w)
    }
    $waveName = { param([string]$w) if ($w -eq 'unscheduled') { 'the machines not in a wave' } else { "wave $w" } }
    $gone = foreach ($file in $files) {
        $rel = "approvals/$file"
        $w = [System.IO.Path]::GetFileNameWithoutExtension($file)
        # An approval that changes while it is judged is judged again, and so
        # is one put back. One that keeps changing is kept, and the run
        # history says so - the gate still judges it on its own.
        $settled = $false
        for ($try = 0; $try -lt 5; $try++) {
            # The approval FIRST, the plan SECOND: an approval written after
            # the plan was read could sign a plan newer than the one judged.
            $approvalText = $null
            try { $approvalText = Read-VmfStoreText -RunPath $RunPath -RelPath $rel }
            catch {
                # No text, so no version to remove it by.
                # STEP-LOG-2: every caller has written the plan by now, and the
                # approvals before this one may be removed. A line that cannot
                # be written must not stop the removal of the others, nor
                # report the caller's saved change as failed.
                Write-VmfStepLine -RunPath $RunPath -Step 'approval' -Outcome warn `
                    -Detail "The product could not read the approval of $(& $waveName $w), so it did not remove it. The engine checks the approval again before the wave starts."
                $settled = $true
                break
            }
            if ($null -eq $approvalText) {
                # No file is gone. An EMPTY file signs nothing: it is judged,
                # and removed by the version of its empty text.
                if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath $rel)) { $settled = $true; break }
                $approvalText = ''
            }
            $planText = [string](Read-VmfTextDocument -Path $PlanPath)
            if (& $judge $approvalText $w $planText) { $settled = $true; break }
            if (-not (Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $approvalText))) { continue }
            # Removed. A plan written since the judgement may sign it again.
            $planAfter = [string](Read-VmfTextDocument -Path $PlanPath)
            if (-not [string]::Equals((Get-VmfDocumentVersion -Text $planAfter), (Get-VmfDocumentVersion -Text $planText), [System.StringComparison]::Ordinal) -and
                (& $judge $approvalText $w $planAfter)) {
                # Only into an empty place: a newer approval stays. Then judged
                # again: a writer after the read above can have made it out of
                # date, and its own removal found no approval to judge.
                [void](Write-VmfStoreTextExclusive -RunPath $RunPath -RelPath $rel -Content $approvalText)
                continue
            }
            $w
            $settled = $true
            break
        }
        if (-not $settled) {
            Write-VmfStepLine -RunPath $RunPath -Step 'approval' -Outcome warn `
                -Detail "The approval of $(& $waveName $w) changed while the product checked it, so the product kept it. The engine checks the approval again before the wave starts."
        }
    }
    $unique = [string[]]@([System.Linq.Enumerable]::Distinct([string[]]@($gone | Where-Object { $_ }), [System.StringComparer]::Ordinal))
    [System.Array]::Sort($unique, [System.StringComparer]::Ordinal)
    @($unique)
}

function Get-VmfStaleApprovalNote {
    <#
    .SYNOPSIS
        The sentence each writer of the plan adds to its activity line for the
        approvals Remove-VmfStaleWaveApprovals removed. Empty for none.
    .DESCRIPTION
        DECIDE-APPROVAL-STALE-1: a wave save and a target change said it, each
        in its own copy of the words, and a decision that went through said
        nothing - so a person who approved a wave found it unapproved with no
        line saying why. One sentence for the activity line of every writer
        (a decision that is refused says it in its refusal).
        -StillCovered names waves that can start without the removed approval:
        a decision carries the plan sign-off past its write, and a current
        sign-off passes every wave. Telling a person to approve those again
        would send them to a button the page does not show.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Wave,
        [Parameter()][AllowEmptyCollection()][string[]]$StillCovered = @()
    )
    $name = { param([string]$w) if ($w -eq 'unscheduled') { 'the machines not in a wave' } else { "wave $w" } }
    @(@($Wave | Where-Object { $_ } | ForEach-Object {
        "The approval of $(& $name $_) signed the plan before this change. Approve the wave again."
    }) + @($StillCovered | Where-Object { $_ } | ForEach-Object {
        "The approval of $(& $name $_) signed the plan before this change, so it was removed. The wave can still start without it."
    })) -join ' '
}

function Test-VmfRunAcknowledged {
    <#
    .SYNOPSIS
        IAC-2: has the customer been told about infrastructure-as-code drift,
        and did a named person accept it for this run?

    .DESCRIPTION
        The product used to GUESS which machines were IaC-managed from a handful of
        tags and stop those machines. It could not tell Terraform from Bicep,
        Pulumi, ARM or Ansible, and read a differently-tagged estate as
        unmanaged - a guess driving a decision. It now tells the customer once,
        plainly, and records that someone accepted it.

        Checked HERE, in the engine, and not only in the wizard: an
        acknowledgement the UI enforces is bypassed by anyone starting a run
        through the API, which is how the engine job actually runs.

        One acknowledgement covers the run, not each wave - it is a statement
        about the estate, and asking again per wave would train people to click
        it without reading.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string]$RunPath)

    $ack = Read-VmfStoreJson -RunPath $RunPath -RelPath 'acknowledgements/infrastructure-as-code.json' -Depth 6
    # GATE-WORDS-1: the refusal names the missing step and the button. The
    # statement itself is shown by the dialog that button opens - repeated
    # here, it filled the Try again dialog with ten sentences before the one
    # that said what to do. An acknowledgement must name a person, because it
    # is the audit trail.
    if (-not $ack) { return (New-VmfStartGateRefusal -Code 'notAcknowledged') }
    if (-not [string]$ack.acknowledgedBy) { return (New-VmfStartGateRefusal -Code 'acknowledgedByNobody') }
    @{ Pass = $true; Detail = "acknowledged by $($ack.acknowledgedBy) at $($ack.acknowledgedUtc)" }
}

function Get-VmfNextWaveVm {
    <#
    .SYNOPSIS
        Atomically claim the next eligible VM of a wave for a worker.
        Eligible = in the wave, path A, not in a terminal state, not leased,
        and its availability-set group lock (if any) is acquirable.
    .OUTPUTS
        @{ Entry = <plan entry>; GroupLockId = <string|null> } or $null when no
        work is currently leasable (worker should exit or back off).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$WorkerId
    )

    # PREP-ROLLBACK-1 (review 2, finding 1): a halted wave takes no new work -
    # but finishing a rollback a worker left is not new work. The breaker
    # trips on exactly the failures that start rollbacks, so a machine left
    # mid-rollback is still taken, to be put back.
    $halted = Test-VmfWaveHalted -RunPath $RunPath

    $terminal = @('MIGRATED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'SKIPPED')
    $entries = @($Plan.entries | Where-Object { $_.wave -eq $Wave -and $_.path -eq 'A' })

    foreach ($entry in $entries) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $entry.vmId
        if ($doc -and $doc.state -in $terminal) { continue }
        if ($halted -and -not ($doc -and $doc.PSObject.Properties['rollbackPending'] -and $doc.rollbackPending)) { continue }

        # Availability-set serialization: one conversion per AvSet at a time.
        $groupLockId = $null
        # Null-safe: an entry with no assessment block used to crash the worker
        # here with "cannot index into a null array" - a sparse plan entry is
        # not a reason to take a worker down.
        $avset = if ($entry.assessment -and $entry.assessment.PSObject.Properties['availabilitySetId']) {
            [string]$entry.assessment.availabilitySetId
        } else { '' }
        if ($avset) {
            # VMID-CASE-1: in lower case. Each machine records its set by its
            # own reference, so two members can name one set in two letter
            # cases - and blob storage names are case sensitive, so the lock
            # named from each held nothing against the other.
            $groupLockId = 'group-avset/' + $avset.Trim('/').ToLowerInvariant()
            $groupLease = New-VmfLease -RunPath $RunPath -VmId $groupLockId -WorkerId $WorkerId
            if (-not $groupLease) { continue }   # another worker is converting in this AvSet
        }

        # RUN-CLAIM-1: the store-wide gate. A lease fences other workers in THIS
        # run; the claim fences other RUNS. Without it two runs over one
        # resource group can convert the same machine at the same time, inside
        # the deallocated window. Taken before the lease, so a machine another
        # run holds is never even leased here.
        $runIdForClaim = [string](Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6).runId
        $claim = New-VmfVmClaim -RunPath $RunPath -VmId $entry.vmId -RunId $runIdForClaim
        if (-not $claim.Granted) {
            # STEP-LOG-2: the availability set lock is held. A line that could
            # not be written left it held, and no worker took another machine
            # of the set until the lease ran out.
            Write-VmfStepLine -RunPath $RunPath -Step 'claim' -Outcome warn -VmId $entry.vmId -Detail $claim.Detail
            if ($groupLockId) { Remove-VmfLease -RunPath $RunPath -VmId $groupLockId -WorkerId $WorkerId }
            continue
        }

        $lease = New-VmfLease -RunPath $RunPath -VmId $entry.vmId -WorkerId $WorkerId
        if (-not $lease) {
            if ($groupLockId) { Remove-VmfLease -RunPath $RunPath -VmId $groupLockId -WorkerId $WorkerId }
            continue
        }

        # DELETE-UNSTARTED-WAVE-1: ask for the pause AGAIN, now that this
        # worker holds the machine. Stop this migration pauses the run, then
        # looks again for a live hold (Stop-VmfRun). So either Stop sees this hold
        # and refuses, or this sees the pause and gives the machine back - a
        # worker that looked before the pause and held the machine after
        # Stop's look moved a machine Stop had just left out. The claim goes
        # back only if this call took it (Taken): one the run held before is a machine
        # part-way through its move, and Stop keeps that claim.
        if (Test-VmfWaveHalted -RunPath $RunPath) {
            $now = Read-VmfStateDoc -RunPath $RunPath -VmId $entry.vmId
            if (-not ($now -and $now.PSObject.Properties['rollbackPending'] -and $now.rollbackPending)) {
                Remove-VmfLease -RunPath $RunPath -VmId $entry.vmId -WorkerId $WorkerId
                if ($groupLockId) { Remove-VmfLease -RunPath $RunPath -VmId $groupLockId -WorkerId $WorkerId }
                if ($claim.Taken) {
                    $null = Remove-VmfVmClaim -RunPath $RunPath -VmId $entry.vmId -RunId $runIdForClaim
                }
                continue
            }
        }

        return @{ Entry = $entry; GroupLockId = $groupLockId }
    }
    return $null
}

function Test-VmfLeasedEntryCurrent {
    <#
    .SYNOPSIS
        WAVE-MIX-2: is the entry a worker just leased still the entry the plan
        holds? Asked after the lease and before anything touches the machine.
    .DESCRIPTION
        A worker runs every machine from the plan it read when its wave started.
        A machine waiting for a slot can be moved to another wave, or have its
        target changed, while that worker is alive - and the worker would then
        move it on what the plan no longer says, unaccepted and unapproved.
        So the stored entry is read again at the moment the machine is taken.
        Any difference in its wave, path or target means: leave it.

        REBUILD-ACCEPT-MACHINE-1: a difference in its policy or its decisions
        is what a person's decision on a stopped machine of the running wave
        writes (Resolve-VmfDecision) - and a rebuild acceptance changes the
        decisions only, which this check did not compare. MEASURED in the lab
        on 2026-11-04: the worker took the machine again 31 seconds after the
        decision, with its own copy of the entry, and Checking stopped it again
        for the extension the decision had accepted. So such a difference is
        run on the STORED entry when the wave, as stored now, passes its start
        gates (Get-VmfWaveStartGate - the gates the decision asked before it
        put the machine back); else the machine is left untouched. Only with
        -RunPath: the gates are read from the run.
    .OUTPUTS
        @{ Current = <bool>; Reason = <string>; Entry = <the entry to run>;
           Changed = <bool: Entry is the stored entry, not the held one> }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)]$Entry,
        [Parameter()][string]$RunPath = ''
    )
    $read = Read-VmfPlanFileVersioned -Path $PlanPath
    $stored = $read.Plan
    $now = @($stored.entries | Where-Object { [string]$_.vmId -eq [string]$Entry.vmId }) | Select-Object -First 1
    if (-not $now) { return [pscustomobject]@{ Current = $false; Reason = 'it is no longer in the plan'; Entry = $null; Changed = $false } }
    if ([string]$now.wave -ne [string]$Entry.wave) { return [pscustomobject]@{ Current = $false; Reason = "it was moved to wave $($now.wave)"; Entry = $null; Changed = $false } }
    $left = [pscustomobject]@{ Current = $false; Reason = 'its target or its settings changed'; Entry = $null; Changed = $false }
    $json = { param($v) ConvertTo-Json -InputObject $v -Depth 12 -Compress }
    $field = { param($e, [string]$n) if ($e.PSObject.Properties[$n]) { $e.$n } else { $null } }
    $shape = { param($e) [ordered]@{ path = $e.path; target = $e.target } | ConvertTo-Json -Depth 12 -Compress }
    if ((& $shape $now) -cne (& $shape $Entry)) { return $left }
    $settings = { param($e) & $json ([ordered]@{ policy = (& $field $e 'policy'); decisions = @(@(& $field $e 'decisions') | Where-Object { $null -ne $_ }) }) }
    if ((& $settings $now) -ceq (& $settings $Entry)) { return [pscustomobject]@{ Current = $true; Reason = ''; Entry = $Entry; Changed = $false } }
    if (-not $RunPath) { return $left }
    $gate = Get-VmfWaveStartGate -RunPath $RunPath -PlanPath $PlanPath -Plan $stored -Wave ([string]$now.wave)
    if ($gate) { return $left }
    [pscustomobject]@{ Current = $true; Reason = ''; Entry = $now; Changed = $true }
}

function Test-VmfWavePending {
    <#
    .SYNOPSIS
        True while any wave entry is not yet terminal.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave
    )
    $terminal = @('MIGRATED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'SKIPPED')
    foreach ($entry in @($Plan.entries | Where-Object { $_.wave -eq $Wave -and $_.path -eq 'A' })) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $entry.vmId
        if (-not $doc -or $doc.state -notin $terminal) { return $true }
    }
    return $false
}

function Test-VmfCapacityExhausted {
    <#
    .SYNOPSIS
        SCALE-1: has this wave run into a wall that every remaining machine
        will hit too?
    .DESCRIPTION
        The circuit breaker beside this one counts failures of
        ANY kind, and its thresholds are tuned for the ordinary case where
        failures are independent - a bad image here, a locked resource there.
        Capacity is not like that. When a region runs out of a size, or a
        subscription's quota family is full, EVERY remaining machine in the
        cell fails for the same reason, and each one pays the full price of
        finding out: a deallocate, a convert attempt, and a rollback.

        The quota record cannot help, because it is a PLAN-TIME reading -
        that is exactly why it carries checkedUtc - and nothing re-reads it as
        a wave consumes cores. So the signal has to come from the failures
        themselves, which already carry a classified reason code.

        Two capacity failures in the same cell is not bad luck. Halt, and let a
        person decide whether to wait, move region, or ask for quota - all of
        which are better than watching the rest of the wave fail one at a time.

        CLAUDE.md: a QuotaExceeded error NAMES THE REAL FAMILY, and the family
        cannot be inferred from the size name. So the message is captured
        verbatim - it is ground truth about a mapping the product otherwise has
        to guess.
    .OUTPUTS
        @{ Exhausted = bool; Count = int; Cells = @(string); Detail = string; Evidence = @(string) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave,
        # Two is not a coincidence; one can be a genuinely transient allocation
        # failure that a retry clears.
        [Parameter()][int]$Limit = 2
    )

    $hits = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Plan.entries | Where-Object { $_.wave -eq $Wave -and $_.path -eq 'A' })) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $entry.vmId
        if (-not $doc) { continue }
        foreach ($h in @($doc.history)) {
            # STOP-TEXT-SPECIFIC-1: a quota failure has its own code now, and
            # it still counts here - the family Azure names comes from it.
            if ([string]$h.reasonCode -notin @('capacityUnavailable', 'quotaExceeded')) { continue }
            $cell = '{0}@{1}' -f [string]$entry.target.size, [string]$entry.assessment.location
            $hits.Add([pscustomobject]@{ Cell = $cell; Detail = [string]$h.detail })
            break   # one machine counts once, however many attempts it made
        }
    }

    if ($hits.Count -lt $Limit) {
        return @{ Exhausted = $false; Count = $hits.Count; Cells = @(); Detail = ''; Evidence = @() }
    }
    $cells = @($hits | ForEach-Object { $_.Cell } | Sort-Object -Unique)
    # The family Azure named, if it named one. This is the only place that
    # mapping is ever stated by the authority on it.
    # Two things this got wrong first time and are worth stating: the family
    # name comes BEFORE the word quota in Azure's message ("exceeding approved
    # standardDDSv6Family quota"), and family names contain DIGITS
    # (standardDDSv6Family), so a letters-only class silently matches nothing.
    $families = @($hits | ForEach-Object {
        if ($_.Detail -match '(?i)quota' -and $_.Detail -match '([A-Za-z][A-Za-z0-9]*[Ff]amily)') { $Matches[1] }
    } | Where-Object { $_ } | Sort-Object -Unique)
    $famNote = if ($families.Count -gt 0) { " Azure named the quota family as $($families -join ', ')." } else { '' }
    @{
        Exhausted = $true
        Count = $hits.Count
        Cells = $cells
        Evidence = @($hits | ForEach-Object { $_.Detail } | Where-Object { $_ } | Select-Object -First 3)
        Detail = ("$($hits.Count) machines could not be allocated in $($cells -join ', '). " +
                  "Every remaining machine of that size in this region would fail the same way, and each one " +
                  "would first stop and roll back, so the wave is paused.$famNote")
    }
}

function Test-VmfCircuitBreaker {
    <#
    .SYNOPSIS
        Breaker math from state docs (never from worker signals): trip on N
        consecutive failures OR failure rate above threshold across the last
        window of terminal outcomes.
    .OUTPUTS
        @{ Tripped = bool; Consecutive = int; Rate = double; Detail = string }
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][int]$ConsecutiveLimit = 3,
        [Parameter()][double]$RateLimit = 0.2,
        [Parameter()][int]$RateWindow = 10
    )

    $failStates = @('FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION')
    $terminal = $failStates + @('MIGRATED')   # NEEDS_DECISION/SKIPPED are not execution outcomes

    # Order terminal outcomes by their final transition time
    $outcomes = foreach ($entry in @($Plan.entries | Where-Object { $_.wave -eq $Wave -and $_.path -eq 'A' })) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $entry.vmId
        if ($doc -and $doc.state -in $terminal) {
            [pscustomobject]@{
                tsUtc  = [datetime]::Parse(@($doc.history)[-1].tsUtc, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
                failed = ($doc.state -in $failStates)
            }
        }
    }
    $ordered = @($outcomes | Sort-Object tsUtc)

    $consecutive = 0
    for ($i = $ordered.Count - 1; $i -ge 0; $i--) {
        if ($ordered[$i].failed) { $consecutive++ } else { break }
    }
    $window = @($ordered | Select-Object -Last $RateWindow)
    $rate = if ($window.Count -gt 0) { (@($window | Where-Object failed).Count / $window.Count) } else { 0.0 }

    $tripped = ($consecutive -ge $ConsecutiveLimit) -or ($window.Count -ge 5 -and $rate -gt $RateLimit)
    @{
        Tripped     = $tripped
        Consecutive = $consecutive
        Rate        = [math]::Round($rate, 3)
        Detail      = "consecutive=$consecutive/$ConsecutiveLimit rate=$([math]::Round($rate*100))% over last $($window.Count)"
    }
}

function Test-VmfOtherContainersWorking {
    <#
    .SYNOPSIS
        SCALE-2: is any OTHER container still working this run - a live lease
        held by a worker that is not one of mine?
    .DESCRIPTION
        A container whose own workers have all finished must not declare the
        wave done while another container's workers hold machines. The lease
        heartbeat is the same liveness fact the watchdog uses. Pure over the
        lease files: a test can write them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$MyWorkerIds,
        [Parameter()][int]$TimeoutSeconds = 900
    )
    $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-$TimeoutSeconds)
    $others = foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'leases' -Extension '.lease')) {
        $lease = Read-VmfStoreJson -RunPath $RunPath -RelPath "leases/$name" -Depth 6
        if (-not $lease -or [string]$lease.workerId -in $MyWorkerIds) { continue }
        # RESTORE-ONE-AT-A-TIME-1: a restore holds its machine with
        # the same lease, and is no container of this wave. Counted, it made
        # every container leave quietly and nobody end the wave.
        if (Test-VmfPutBackLeaseHolder -WorkerId ([string]$lease.workerId)) { continue }
        $hb = [datetime]::MinValue
        if (-not [datetime]::TryParse([string]$lease.heartbeatUtc, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$hb)) { continue }
        if ($hb -ge $cutoff) { [string]$lease.vmId }
    }
    $others = @($others)
    [pscustomobject]@{ Working = ($others.Count -gt 0); Machines = $others }
}

function Write-VmfRunStatus {
    <#
    .SYNOPSIS
        Snapshot the wave's live state to run-status.json (schema
        run-status.schema.json) - the console renderer's and cockpit's feed -
        with the summary of the whole migration beside it (APPROVE-GROUP-1).
    .DESCRIPTION
        Every ten seconds the summary changes this wave's counts only
        (Update-VmfRunSummaryWave); with -WaveEnded it is built from the store
        again, which is the "when a wave ends" write. A write that fails says
        so in the console and the wave goes on: the status is a report about
        the wave, never a reason to stop it. The returned snapshot is the one
        built, written or not.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][int]$ThrottleLimit = 0,
        # SCALE-2: how many containers work this wave (the record says the
        # TOTAL at once in limit, and this beside it).
        [Parameter()][int]$Containers = 1,
        # APPROVE-GROUP-1: the plan the wave read, for the summary of the
        # whole migration. Omitted: the run's own plan.json.
        [Parameter()][string]$PlanPath,
        # APPROVE-GROUP-1: the wave's last write - the summary is built from
        # the store, so it says what the NEXT wave waits for.
        [Parameter()][switch]$WaveEnded,
        # OVERVIEW-RUNNING-STALE-1: the lease limit the wave's watchdog uses.
        [Parameter()][int]$LeaseTimeoutSeconds = $script:VmfMachineLeaseTimeoutSeconds
    )

    # OVERVIEW-RUNNING-STALE-1: `running` is the machines that are moving now -
    # the Overview's Running now and its Machines moving read nothing else. It
    # listed every machine with a lease, so a machine that was MIGRATED while
    # its worker still held the lease (the worker deletes the rollback disks
    # after the MIGRATED checkpoint, and gives the lease back only after that)
    # was in the wave's last write, and nothing writes the live fields again:
    # a finished migration stayed under Running now. A machine in a final
    # state, or under a lease past its limit (its worker stopped), is not
    # moving; and the wave's last write lists none, because the wave is over.
    $counts = @{}
    $running = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($Plan.entries | Where-Object { $_.wave -eq $Wave -and $_.path -eq 'A' })) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $entry.vmId
        $state = if ($doc) { $doc.state } else { 'PLANNED' }
        $counts[$state] = 1 + $(if ($counts.ContainsKey($state)) { $counts[$state] } else { 0 })

        if ($WaveEnded -or $state -in $script:VmfTerminalStates) { continue }
        $lease = Get-VmfLeaseInfo -RunPath $RunPath -VmId $entry.vmId
        # RESTORE-ONE-AT-A-TIME-1: a restore is no worker of the wave.
        if ($lease -and -not (Test-VmfPutBackLeaseHolder -WorkerId ([string]$lease.workerId)) -and
            -not (Test-VmfMachineLeaseExpired -Lease $lease -TimeoutSeconds $LeaseTimeoutSeconds)) {
            $running.Add([ordered]@{
                vmId = $entry.vmId; state = $state
                sinceUtc = $lease.acquiredUtc; workerId = $lease.workerId
            })
        }
    }

    $breaker = Test-VmfCircuitBreaker -RunPath $RunPath -Plan $Plan -Wave $Wave
    $live = [ordered]@{
        wave = $Wave
        updatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        stateCounts = $counts
        running = @($running)
        breaker = [ordered]@{
            halted = (Test-VmfWaveHalted -RunPath $RunPath)
            consecutiveFailures = $breaker.Consecutive
            recentFailureRate = $breaker.Rate
        }
        throttle = [ordered]@{ limit = $ThrottleLimit; containers = $Containers; recent429s = 0 }
        etaUtc = $null
    }
    $status = [ordered]@{ schemaVersion = $script:VmfRunStatusSchemaVersion; runId = $RunId }
    foreach ($k in $live.Keys) { $status[$k] = $live[$k] }
    if (-not $PlanPath) { $PlanPath = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json' }
    $write = @{ RunPath = $RunPath; PlanPath = $PlanPath; RunId = $RunId; Live = $live; Plan = $Plan }
    if ($WaveEnded) { $write.Reason = 'waveEnded' }
    else { $write.Reason = 'waveRunning'; $write.PatchWave = $Wave; $write.PatchCounts = $counts }
    try {
        $written = Write-VmfRunStatusDocument @write
        if ($written -and $written.Contains('summary')) { $status.summary = $written.summary }
    }
    catch {
        Write-Warning "[wave $Wave] the run status could not be written: $($_.Exception.Message)"
        # The last write is the one the list keeps, so its failure is said
        # where a person reads it; the daily check writes it again.
        if ($WaveEnded) {
            Write-VmfStepLine -RunPath $RunPath -Step 'status' -Outcome warn `
                -Detail "The product could not write the status of this migration for the list on the Migrations page: $($_.Exception.Message). The next change to this migration writes it again, and so does the daily check."
        }
    }
    $status
}

function Get-VmfClaimForEntry {
    <#
    .SYNOPSIS
        Find the RESERVED quota record (and its file path) matching a plan
        entry's wave/region/zone/target size. Null when none exists (BestEffort
        waves have no reservations).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Entry
    )

    # ID-ADDRESS-1: and the SUBSCRIPTION, from the machine's own ID. A wave
    # can hold machines of several subscriptions, each with a reservation of
    # the same size, and a machine can only use a group in its own.
    $entrySub = Get-VmfSubscriptionId -ResourceId ([string]$Entry.vmId)
    if (-not $entrySub) { return $null }
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json')) {
        $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$name" -Depth 12
        $groupSub = if ($claim.PSObject.Properties['reservation'] -and $claim.reservation) { Get-VmfSubscriptionId -ResourceId ([string]$claim.reservation.groupId) } else { $null }
        # RESERVE-COVER-1: the cell is matched by the one predicate the
        # Reserved gate's coverage rule uses, so the gate and the attach can
        # never mean two different cells.
        if ($claim.state -eq 'RESERVED' -and $groupSub -eq $entrySub -and
            (Test-VmfClaimCellMatchesEntry -Claim $claim -Entry $Entry)) {
            return @{ Claim = $claim; RelPath = "capacity/$name" }
        }
    }
    return $null
}

function Add-VmfClaimAssociation {
    <#
    .SYNOPSIS
        Record that a VM consumed a slot of a reservation (for release-time
        disassociation and utilization reporting).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$ClaimRelPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath $ClaimRelPath -Depth 12
    $existing = @(if ($claim.PSObject.Properties['associatedVmIds']) { $claim.associatedVmIds })
    if ($VmId -notin $existing) {
        $claim | Add-Member -NotePropertyName associatedVmIds -NotePropertyValue (@($existing) + @($VmId)) -Force
        $claim.reservation.consumedInstances = @($existing).Count + 1
        Write-VmfStoreJson -RunPath $RunPath -RelPath $ClaimRelPath -Document $claim -Depth 12
    }
}

function Remove-VmfClaimAssociation {
    <#
    .SYNOPSIS
        Record that a VM is no longer on a reservation.

        The "in use" figure the operator sees is this ledger, not a live reading
        from Azure, so anything that detaches a machine has to say so or the
        number stays high forever - claiming capacity is working when nothing is
        on it. The put-back detaches (reservations are one way: the group holds
        the target size only), which is exactly that case.

        Searches every claim in the run rather than being told which one, because
        the caller putting a machine back knows the VM, not the claim.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity')) {
        $rel = "capacity/$name"
        $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath $rel -Depth 12
        $existing = @(if ($claim.PSObject.Properties['associatedVmIds']) { $claim.associatedVmIds })
        if ($VmId -in $existing) {
            $remaining = @($existing | Where-Object { $_ -ne $VmId })
            $claim | Add-Member -NotePropertyName associatedVmIds -NotePropertyValue $remaining -Force
            $claim.reservation.consumedInstances = @($remaining).Count
            Write-VmfStoreJson -RunPath $RunPath -RelPath $rel -Document $claim -Depth 12
        }
    }
}

function Get-VmfIacStatement {
    <#
    .SYNOPSIS
        The words a person is asked to accept before a run can start.

        Defined ONCE, here, so the wizard, the command line and the engine's own
        refusal all say the same thing. A gate whose wording drifts between
        surfaces is a gate nobody can be held to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    # IAC-WORDS-1: true for every move. v5 keeps the SCSI disk controller, and
    # a move keeps the machine's disks - only a rollback or a restore makes new
    # ones. The wizard and the run page show these words exactly; a
    # test holds them to it.
    # LAB-UX-1: a restore replaces every disk since RESTORE-ALL-1 and can keep
    # the disk names (-DiskNaming preserve). REBUILD-REMOVE-RECOVER-1: no move
    # and no restore rebuilds a machine, so the statement says no rebuild.
    # A stored acknowledgement keeps the words its person was shown, and
    # nothing compares it with these.
    # IAC-NOTE-LIST-1: these words were approved on 2026-11-08. The pages
    # show them as a lead, one list item for each change, and a closing line;
    # joined with a space, those are this statement, which a test holds.
    'Terraform, Bicep, Pulumi, ARM templates and Ansible keep their own definition of each machine. ' +
    'This migration makes these changes, and those definitions do not know about them: ' +
    'The size of the machine changes. ' +
    'A move to v6 or v7 changes the disk controller from SCSI to NVMe. ' +
    'A move can change accelerated networking. ' +
    'A move can change the disk type to Standard SSD or Premium SSD. ' +
    'A rollback or a restore puts the machine on new disks, made from its safety copies. A restore can keep the disk names. ' +
    'The next apply can undo these changes, or replace the machine. ' +
    'Reconcile your definitions after the migration.'
}

function Get-VmfWaveOptionsEntries {
    <#
    .SYNOPSIS
        ACCEPT-SET-1: the entries a wave's accepted settings cover - ONE answer
        for every caller of Get-VmfWaveOptionsHash.
    .DESCRIPTION
        The machines of the wave that MOVE: path A, the set Start-VmfWave
        runs. The callers used to disagree - the wave start hashed these, and
        the acceptance, the start gate and a decision's carry-forward hashed
        every entry in the wave - so a wave holding a machine that does not
        move was accepted over one set, started against the other, and refused
        as changed for ever. A setting on a machine that does not move decides
        nothing, so it is not what anybody accepts.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()]$Plan,
        [Parameter(Mandatory)][string]$Wave
    )
    @(@($Plan.entries) | Where-Object { $_ -and [string]$_.wave -eq $Wave -and [string]$_.path -eq 'A' })
}

function Get-VmfWaveOptionsHash {
    <#
    .SYNOPSIS
        WAVE-2: a stable hash over a wave's MEMBERSHIP and LEVERS, so an
        acceptance is bound to exactly what was accepted.
    .DESCRIPTION
        Canonical form: each entry's (vmId, policy) serialised compactly and
        sorted by vmId, then SHA256. Editing any lever, adding a machine or
        removing one changes the hash and invalidates the acceptance - the
        same binding wave APPROVAL has to the plan hash, for the same reason:
        accepting one thing must not authorise a different thing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Entries)

    # WAVE-AN-NAMES-1: and the record of whether the move turns accelerated
    # networking on, which the acceptance names the machines from - so a
    # change to it voids the acceptance as a change to a setting does. Only
    # when the entry has one: an entry written before v20 hashes as it always
    # did, and no earlier acceptance is voided by an upgrade.
    $canon = @($Entries | Sort-Object { [string]$_.vmId } | ForEach-Object {
        $line = '{0}|{1}' -f [string]$_.vmId, ($_.policy | ConvertTo-Json -Depth 8 -Compress)
        if ($_.PSObject.Properties['acceleratedNetworkingOutcome']) {
            $line += '|an=' + ($_.acceleratedNetworkingOutcome | ConvertTo-Json -Depth 4 -Compress)
        }
        $line
    }) -join "`n"
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($canon))
        ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function ConvertTo-VmfCanonicalJson {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: one JSON value written in ONE canonical form, by this
        code alone - the bytes a wave version hashes.
    .DESCRIPTION
        An approval is written by the service and checked by the engine, which
        run on two different PowerShell installs. A version that went through
        ConvertFrom-Json and ConvertTo-Json would depend on how each install
        reads and writes JSON, and any difference between them would make the
        engine refuse every approval, or keep a stale one. So the stored text
        is read with System.Text.Json, which never turns a text into a date,
        and written here, by these rules and nothing else:
          * an object: its properties sorted by name, ordinally; two of one
            name (JSON allows it) by their written value;
          * an array: its items in order;
          * a string: a quote, the text, a quote. Only the quote and the
            backslash are escaped with a backslash, and a character below
            U+0020 as \u and four lower-case hex digits. Everything else is
            written as it is (and hashed as UTF-8);
          * a string that is an ISO date and time - the form ConvertFrom-Json
            turns into a date, yyyy-MM-ddTHH:mm:ss with an optional fraction
            and zone - is written as its instant: with a zone, the UTC time as
            yyyy-MM-ddTHH:mm:ss.fffffffZ; with none, the same digits with no
            zone, because it names no instant. Every plan writer reads the
            plan with ConvertFrom-Json and writes it again, which rewrites
            these ("...00.1230000Z" becomes "...00.123Z", an offset becomes the
            offset of the computer), so this keeps a rewrite of another wave
            from changing this wave's version;
          * a number: a whole number that fits 64 bits as its digits; any other
            as its shortest round-trip double ("R"), in the invariant culture -
            so 1, 1.0 and 1.00 are one value, as a rewrite makes them;
          * true, false and null as the words. A property that is null is
            written; a property that is missing is not - they differ.
        Pure: no store, no clock, no culture.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Text.Json.JsonElement]$Element)
    $sb = [System.Text.StringBuilder]::new()
    Add-VmfCanonicalJson -Builder $sb -Element $Element
    $sb.ToString()
}

function Add-VmfCanonicalJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Text.StringBuilder]$Builder,
        [Parameter(Mandatory)][System.Text.Json.JsonElement]$Element
    )
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    switch ($Element.ValueKind) {
        ([System.Text.Json.JsonValueKind]::Object) {
            $pairs = [System.Collections.Generic.List[object]]::new()
            foreach ($prop in $Element.EnumerateObject()) {
                $pairs.Add([pscustomobject]@{ Name = $prop.Name; Text = (ConvertTo-VmfCanonicalJson -Element $prop.Value) })
            }
            $sorted = [object[]]$pairs.ToArray()
            [System.Array]::Sort($sorted, [System.Comparison[object]] {
                    param($a, $b)
                    $c = [string]::CompareOrdinal([string]$a.Name, [string]$b.Name)
                    if ($c -ne 0) { return $c }
                    [string]::CompareOrdinal([string]$a.Text, [string]$b.Text)
                })
            [void]$Builder.Append('{')
            for ($i = 0; $i -lt $sorted.Count; $i++) {
                if ($i) { [void]$Builder.Append(',') }
                Add-VmfCanonicalString -Builder $Builder -Text ([string]$sorted[$i].Name)
                [void]$Builder.Append(':').Append([string]$sorted[$i].Text)
            }
            [void]$Builder.Append('}')
        }
        ([System.Text.Json.JsonValueKind]::Array) {
            [void]$Builder.Append('[')
            $first = $true
            foreach ($item in $Element.EnumerateArray()) {
                if (-not $first) { [void]$Builder.Append(',') }
                $first = $false
                Add-VmfCanonicalJson -Builder $Builder -Element $item
            }
            [void]$Builder.Append(']')
        }
        ([System.Text.Json.JsonValueKind]::String) {
            $text = $null
            try { $text = $Element.GetString() } catch { $text = $Element.GetRawText() }
            Add-VmfCanonicalString -Builder $Builder -Text (ConvertTo-VmfCanonicalInstant -Text $text)
        }
        ([System.Text.Json.JsonValueKind]::Number) {
            [long]$whole = 0
            if ($Element.TryGetInt64([ref]$whole)) { [void]$Builder.Append($whole.ToString($inv)) }
            else { [void]$Builder.Append($Element.GetDouble().ToString('R', $inv)) }
        }
        ([System.Text.Json.JsonValueKind]::True) { [void]$Builder.Append('true') }
        ([System.Text.Json.JsonValueKind]::False) { [void]$Builder.Append('false') }
        default { [void]$Builder.Append('null') }
    }
}

function Add-VmfCanonicalString {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Text.StringBuilder]$Builder, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    [void]$Builder.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq [char]34) { [void]$Builder.Append([char]92).Append([char]34) }
        elseif ($ch -eq [char]92) { [void]$Builder.Append([char]92).Append([char]92) }
        elseif ($code -lt 32) { [void]$Builder.Append([char]92).Append('u').Append($code.ToString('x4', [System.Globalization.CultureInfo]::InvariantCulture)) }
        else { [void]$Builder.Append($ch) }
    }
    [void]$Builder.Append('"')
}

function ConvertTo-VmfCanonicalInstant {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: an ISO date-and-time text as its instant, in one fixed
        form; any other text as it is. See ConvertTo-VmfCanonicalJson.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    if ($Text -notmatch '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,7})?(Z|[+-]\d{2}:?\d{2})?$') { return $Text }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    if ($Matches[2]) {
        $at = [System.DateTimeOffset]::MinValue
        if ([System.DateTimeOffset]::TryParse($Text, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$at)) {
            return $at.UtcDateTime.ToString('yyyy-MM-dd''T''HH:mm:ss.fffffff', $inv) + 'Z'
        }
        return $Text
    }
    $local = [datetime]::MinValue
    if ([datetime]::TryParse($Text, $inv, [System.Globalization.DateTimeStyles]::None, [ref]$local)) {
        return $local.ToString('yyyy-MM-dd''T''HH:mm:ss.fffffff', $inv)
    }
    $Text
}

function Get-VmfWaveVersions {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: the version of each named wave of a STORED plan text,
        from one read of that text. A hashtable: wave -> version.
    .DESCRIPTION
        A wave approval signs ITS wave, not the plan (2026-10-05: each
        wave's approval signs only its own wave's machines and settings). This
        is what it signs: SHA-256, lower-case hex, over
          * the plan-wide fields that change what every wave does: the plan's
            format version (schemaVersion) and the assessment it was planned
            from (assessmentRunId). Every engine setting is stored on each
            machine's entry - the wave-wide ones (capacity, sign-off, how many
            at once) on every entry of the wave - so they are in the entries.
          * the wave's name, so an approval copied to another wave matches
            nothing;
          * every entry of the wave, whole - target, path, policy, decisions,
            the assessment block: everything a worker reads for a machine -
            sorted by vmId. Every path, not only A: a machine that does
            not move today and is changed to move is a change to the wave.
        Left out on purpose: waveOrder (when a wave runs is a change window,
        not a second signature - Approve-VmfPlan), and waveSummary,
        pathSummary and generatedUtc (derived, or fixed at planning).
        THE WAVE'S ENTRIES ARE CHOSEN THE WAY THE WORKER CHOOSES THEM
        (Get-VmfNextWaveVm: -eq, which ignores case; and PowerShell finds the
        properties entries, wave and vmId whatever their case), so nothing a
        worker of this wave would take is outside the version.
        Each entry, and each plan-wide field, is written by
        ConvertTo-VmfCanonicalJson from the stored text read with
        System.Text.Json - never through ConvertFrom-Json or ConvertTo-Json,
        whose behaviour belongs to each PowerShell install. The service writes
        an approval and the engine checks it, on two different installs.
        THIS DEPARTS FROM THE LETTER OF PLANVER-2, which hashes the stored
        text as it is: every plan writer rewrites the whole plan to change one
        wave, which changes the text of the other waves (measured: the first
        rewrite turns '...09:12:00.1230000Z' into '...09:12:00.123Z'), so a
        hash of the text as it is would ask again for waves nobody changed.
        The spirit stays: only stored text is accepted, never an object a
        caller holds; the engine computes it on both sides of every comparison,
        and the page never does.
        The result is keyed ordinally: two waves whose names differ only in
        case are two versions.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlanText,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Wave
    )
    $doc = $null
    $plan = $null
    if (-not [string]::IsNullOrWhiteSpace($PlanText)) {
        $doc = [System.Text.Json.JsonDocument]::Parse($PlanText)
        $plan = $doc.RootElement
    }
    try {
        # A property found the way PowerShell finds one: its name, whatever
        # the case, the first of that name.
        $propOf = {
            param($element, [string]$name)
            if ($null -eq $element -or $element.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { return $null }
            foreach ($prop in $element.EnumerateObject()) {
                if ([string]::Equals($prop.Name, $name, [System.StringComparison]::OrdinalIgnoreCase)) { return , $prop.Value }
            }
            $null
        }
        $textOf = {
            param($element)
            if ($null -eq $element) { return '' }
            switch ($element.ValueKind) {
                ([System.Text.Json.JsonValueKind]::String) { $element.GetString() }
                ([System.Text.Json.JsonValueKind]::Null) { '' }
                default { $element.GetRawText() }
            }
        }
        $planWide = if ($null -ne $plan) {
            @(foreach ($name in 'schemaVersion', 'assessmentRunId') {
                    $v = & $propOf $plan $name
                    if ($null -eq $v) { "$name missing" } else { "$name $(ConvertTo-VmfCanonicalJson -Element $v)" }
                }) -join ' '
        } else { 'no plan' }
        $entries = [System.Collections.Generic.List[object]]::new()
        $list = if ($null -ne $plan) { & $propOf $plan 'entries' } else { $null }
        if ($null -ne $list -and $list.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
            foreach ($e in $list.EnumerateArray()) {
                if ($e.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) { continue }
                $line = [string](& $textOf (& $propOf $e 'vmId')) + '|' + (ConvertTo-VmfCanonicalJson -Element $e)
                $entries.Add([pscustomobject]@{ Wave = [string](& $textOf (& $propOf $e 'wave')); Line = $line })
            }
        }
        $out = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::Ordinal)
        foreach ($w in $Wave) {
            if ($out.ContainsKey($w)) { continue }
            $sorted = [string[]]@($entries | Where-Object { $_.Wave -eq $w } | ForEach-Object { $_.Line })
            [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
            $canon = (@('vmf-wave-version 2', "plan $planWide", "wave $w") + $sorted) -join "`n"
            $out[$w] = Get-VmfDocumentVersion -Text $canon
        }
        , $out
    }
    finally { if ($doc) { $doc.Dispose() } }
}

function Get-VmfWaveVersion {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: the version of ONE wave of a stored plan text - what a
        wave approval signs, and what a wave's workers compare. See
        Get-VmfWaveVersions.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$PlanText,
        [Parameter(Mandatory)][string]$Wave
    )
    $versions = Get-VmfWaveVersions -PlanText $PlanText -Wave @($Wave)
    $versions[$Wave]
}

function Test-VmfWaveApprovalCurrent {
    <#
    .SYNOPSIS
        WAVE-APPROVE-1: does this wave approval still sign the wave as the
        stored plan text holds it? The ONE rule the gate, the removal of stale
        approvals and a decision's carry-forward all use.
    .DESCRIPTION
        An approval carries waveVersion and is current while it equals the
        wave's version now. OLD-VERSION-READERS-REMOVE-2: an approval with no
        waveVersion is not current - only an earlier version wrote one (signed
        by planHash alone), and nothing is public before 1.0.
        Compared ordinally: a version is lower-case hex, and a comparison that
        ignores case or culture can only accept more.
    .PARAMETER WaveVersion
        Get-VmfWaveVersion of the plan text for this wave, when the caller has
        it already.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Approval,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][AllowEmptyString()][string]$PlanText = '',
        [Parameter()][string]$WaveVersion
    )
    if (-not $Approval) { return $false }
    $signedWave = if ($Approval.PSObject.Properties['waveVersion']) { [string]$Approval.waveVersion } else { '' }
    if (-not $signedWave) { return $false }
    $now = if ($WaveVersion) { $WaveVersion } else { Get-VmfWaveVersion -PlanText $PlanText -Wave $Wave }
    [string]::Equals($signedWave, $now, [System.StringComparison]::Ordinal)
}

function Test-VmfWaveOptionsAccepted {
    <#
    .SYNOPSIS
        WAVE-2: has a named person accepted THIS wave's levers, as they
        currently stand?
    .DESCRIPTION
        Checked in the engine, not only in any UI - a gate the wizard enforces
        is bypassed by the API path, which is how the engine job actually
        runs (the IAC-2 lesson, applied again). Three honest outcomes:
        no acceptance at all; an acceptance for a DIFFERENT shape of the wave
        (levers or membership changed since - re-accept, the record says who
        accepted what); or accepted and current.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Entries,
        [Parameter(Mandatory)][string]$Wave
    )

    $rel = Resolve-VmfWaveOptionsAcceptancePath -Wave $Wave
    $doc = $null
    try { $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath $rel } catch { }
    # DECIDE-KEEP-1: a Code as well as a sentence, so a caller can tell "never
    # accepted" from "accepted, then changed" without reading the words.
    # GATE-WORDS-1: the words are in data/start-gates.json. Defaults exist, but
    # a default nobody looked at is a decision nobody made, so they still need
    # accepting. A change to the settings or to the machines of the wave voids
    # the acceptance. No date in the words: ConvertFrom-Json turns the stored
    # time into a local date value, which printed in the server's format.
    if (-not $doc) { return (New-VmfStartGateRefusal -Code 'notAccepted' -Wave $Wave) }
    $current = Get-VmfWaveOptionsHash -Entries $Entries
    if ([string]$doc.optionsHash -ne $current) {
        return (New-VmfStartGateRefusal -Code 'changed' -Wave $Wave -By ([string]$doc.acceptedBy))
    }
    @{ Pass = $true; Code = 'current'; Detail = "options accepted by $($doc.acceptedBy) on $($doc.acceptedUtc)" }
}

function Get-VmfWaveOptionsAcceptancePath {
    <#
    .SYNOPSIS
        The name of a wave's options acceptance file. Pure. Every caller that
        reads or writes the record asks Resolve-VmfWaveOptionsAcceptancePath,
        which also finds a file written under the earlier name.
    .DESCRIPTION
        ACCEPT-NAME-1, the CLAIM-NAME-1 shape. The readable part is the rule
        the product always used: every character but a letter, a number or a
        dash made a dash. A wave name may hold dots and underscores too
        (Set-VmfWavePlan), so wave_1, wave.1 and wave-1 got ONE file, and
        accepting one wave replaced the other wave's acceptance. The code after
        it is made from the wave as it is (Get-VmfNameCode), so two waves never
        share a file.
        Lower case, and the code ignores case, because the engine reads Wave_1
        and wave_1 as one wave (-eq, Get-VmfWaveOptionsEntries): its gate and
        its writer must find one file, and on blob storage a name in another
        case is another file. That the wave editor accepts both names is
        WAVE-CASE-1.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Wave)
    $readable = $Wave -replace '[^A-Za-z0-9\-]', '-'
    "acceptances/wave-options-$($readable.ToLowerInvariant())-$(Get-VmfNameCode -Part @($Wave)).json"
}

function Resolve-VmfWaveOptionsAcceptancePath {
    <#
    .SYNOPSIS
        ACCEPT-NAME-1: which file holds a wave's options acceptance. One place,
        because the writer (Confirm-VmfWaveOptions), the start gate, a
        decision that carries it forward and a change of one machine's target
        must agree.
    .DESCRIPTION
        The name from Get-VmfWaveOptionsAcceptancePath. OLD-VERSION-READERS-REMOVE-2:
        the name from before ACCEPT-NAME-1 is not read - only an earlier
        version wrote it, and nothing is public before 1.0.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Wave)
    Get-VmfWaveOptionsAcceptancePath -Wave $Wave
}

# The versions of the records a decision can carry forward (DECIDE-KEEP-1).
# WAVE-APPROVE-1: a wave approval v2 signs its wave (waveVersion) and can carry
# amendments; a plan sign-off v3 is written with one wave approval per wave and
# stays the consent for the plan to run on after a change to one wave.
# IDENTITY-LOSS-1: a wave options acceptance v4 names each machine whose
# system-assigned identity it lets a rebuild delete (identityLoss).
# REBUILD-ACCEPT-1: a v5 acceptance names each machine it lets the engine
# rebuild around the same disks, with the extensions shown (rebuild).
# DCR-READ-1: v7 - a follow-up of a rebuild may name the data collection rule associations.
# REBUILD-REMOVE-ACCEPT-1: v8 writes no identityLoss and no rebuild - nobody
# accepts a rebuild any more. OLD-VERSION-READERS-REMOVE-1: v9 - both left the
# contract.
function Get-VmfWaveOptionsAcceptanceSchemaVersion { 9 }
# SQL-TEMPDB-SIGNOFF-1 (v4): sqlTempdbChecked, the SQL Server machines the
# approver confirmed they checked where tempdb is.
function Get-VmfPlanApprovalSchemaVersion { 4 }
# IDENTITY-LOSS-1: a wave approval v3 names each machine whose system-assigned
# identity it lets a rebuild delete (identityLoss).
# REBUILD-REMOVE-ACCEPT-1: v4 writes no identityLoss. OLD-VERSION-READERS-REMOVE-1:
# v5 - it left the contract, and waveVersion is required.
function Get-VmfWaveApprovalSchemaVersion { 5 }
