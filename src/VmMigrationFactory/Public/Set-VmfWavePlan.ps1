function Set-VmfWavePlan {
    <#
    .SYNOPSIS
        WAVE-1 phase 2: rewrite a plan's WAVE LAYOUT - create, rename, delete,
        merge or split waves, move machines between them, and set each wave's
        own policy levers (capacity, sign-off, and what stops a machine).
    .DESCRIPTION
        The planner's automatic grouping is a starting point, not a verdict:
        a customer estate may carry no useful tags, and the migration lead is
        the one who knows what should move together. This cmdlet lets a whole
        runbook be composed by hand while keeping every safety property the
        engine relies on.

        Enforced, and NOT bypassable:
          * every machine named must exist in the plan, and may appear in
            exactly one wave;
          * availability-set members always travel together - splitting one
            across waves is refused (their sizes must stay compatible, and the
            engine serialises them within a wave);
          * a machine that has already started migrating cannot be re-waved;
          * changing a wave's membership or settings invalidates that wave's
            approval, because an approval is bound to the wave it signed off
            (WAVE-APPROVE-1). The stale approval is removed and reported, so
            the wave must be approved again before it can run. Another wave's
            approval stays.

        Naming a wave with no machines removes it, and so does leaving it out.
    .PARAMETER Layout
        @{ waves = @( @{ name = 'payment-tier'; capacityGate = 'Reserved';
                         requireApproval = $true; vmIds = @('...') } ) }
        Only 'name' and 'vmIds' are required per wave; omitted policy fields
        keep each machine's current policy.

        WAVE-REMOVE-NOT-SAVED-1: the layout is the COMPLETE set of waves. A
        machine on a moving path that no wave names goes to no wave
        ('unscheduled'), through the same guards as any move. A MANUAL or
        EXCLUDED machine is never touched. The list of waves may be empty: then
        every moving machine goes to no wave.

        WAVE-LEVER-OVERRIDE-1: a wave may also carry 'changed' - the settings
        the person changed on the wave editor's card, each with the value the
        card showed. With it, a machine that stays in its wave is written only
        for a changed setting, and only when it holds the value the card
        showed; a machine joining the wave takes every setting named. Without
        it (the command line), every setting named is written. Either way a
        setting a decision gave one machine (plan-entry `decisions`) is never
        written over, and each machine that does not follow a setting is named in
        KeptOwnSettings and in the activity.

        WAVE-LEVER-RESET-1: a wave may also carry 'reset' - setting -> the
        machines of that wave that the person sets to use the setting of the wave.
        Each gets the value the wave names, over the value it had and over a
        decision, whose record goes. Named in ResetToWave and in the
        activity. A setting of the whole wave, or a machine of another wave,
        is refused by name. WAVE-KERNEL-LINE-1: no wave has a kernel setting;
        each machine keeps its own choice from the targets step, and a layout
        that names onDriverBelowFloor is refused.
    .PARAMETER ExpectedPlanVersion
        PLAN-WRITE-RACE-1: the plan version the page read (PLANVER-2). The
        page sends every wave's settings on every save, so a save built from a
        page read before a decision would write that decision away. A stored
        version that differs is refused with 409. The facade passes the page's version, or, with none, the version it judged the save on (WAVE-LEVER-OVERRIDE-1).
    .OUTPUTS
        Summary object: waves, moved machine count, approvals invalidated, and
        the machines that do not follow a setting (KeptOwnSettings).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][hashtable]$Layout,
        [Parameter()][string]$ChangedBy = 'unknown',
        [Parameter()][string]$Note = '',
        [Parameter()][string]$ExpectedPlanVersion
    )

    # PLAN-WRITE-RACE-1: the version of the text read, so the write below is
    # refused if anybody wrote the plan in between - and, when the page says
    # which version it read, refused if the plan changed since then too.
    $read = Read-VmfPlanFileVersioned -Path $PlanPath
    if (-not $read) { throw "No plan found at '$PlanPath'." }
    if ($ExpectedPlanVersion -and $read.Version -ne $ExpectedPlanVersion) {
        throw '409: The plan changed after this page read it. Load the page again, then make the change again.'
    }
    $plan = $read.Plan
    $entries = @($plan.entries)
    $byId = @{}
    foreach ($e in $entries) { $byId[[string]$e.vmId] = $e }

    # WAVE-REMOVE-NOT-SAVED-1: the list must be there, and it may be empty -
    # Delete on the last wave sends no wave, and every moving machine then goes
    # to no wave below, through the same guards.
    if (-not $Layout.ContainsKey('waves') -or $null -eq $Layout['waves']) { throw 'Layout.waves is required.' }
    $waves = @($Layout.waves | Where-Object { $null -ne $_ })
    # Each wave's settings, checked and read the way the engine holds them,
    # and its list of changes (WAVE-LEVER-OVERRIDE-1). Throws, by name, before
    # anything is touched.
    $normalized = @(ConvertTo-VmfWaveLayout -Layout $Layout)

    # --- validate before touching anything -------------------------------
    $seen = @{}
    foreach ($w in $waves) {
        $name = [string]$w.name
        if ([string]::IsNullOrWhiteSpace($name)) { throw 'Every wave needs a name.' }
        if ($name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$') {
            throw "Wave name '$name' is not usable - use letters, numbers, dashes, dots or underscores."
        }
        # NOT-IN-WAVE-QUEUED-1: the names the product uses for no wave. The
        # engine skips a wave named unscheduled in any case, and the Migrations
        # page uses unplanned for its own group, so a wave with such a name
        # would not run, or would show no Start. Exactly 'unscheduled' is the
        # planner's own word, and a layout that uses it puts those machines in
        # no wave, as the plan holds them. Every other case of it, and
        # unplanned in any case, is refused. The wave editor refuses all of
        # them as they are typed (reservedWaveName in waves.js).
        if ($name -cne 'unscheduled' -and $name -in @('unscheduled', 'unplanned')) {
            throw "Wave name '$name' is not usable - the product uses this name for the machines that are not in a wave. Use a different name."
        }
        foreach ($vmId in @($w.vmIds)) {
            $id = [string]$vmId
            if (-not $byId.ContainsKey($id)) { throw "'$id' is not part of this plan." }
            if ($seen.ContainsKey($id)) {
                throw "'$(($id -split '/')[-1])' appears in more than one wave ('$($seen[$id])' and '$name')."
            }
            $seen[$id] = $name
        }
    }

    # WAVE-REMOVE-NOT-SAVED-1: a saved layout is the COMPLETE set of waves.
    # The wave editor's Remove and Delete put machines on its left side, and
    # its save sends only the waves on the right - so a machine the layout
    # names in no wave goes to no wave ('unscheduled'). Only a machine on a
    # moving path (a MANUAL or EXCLUDED machine is never touched), and only
    # one that is in a wave now. Each is added to $seen, so it passes every
    # guard below as any other move does: a started machine is refused, an
    # availability set stays together, and a running wave refuses to lose it.
    $dropped = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) {
        $id = [string]$e.vmId
        if (-not $id -or $seen.ContainsKey($id)) { continue }
        if ([string]$e.path -in @('MANUAL', 'EXCLUDED')) { continue }
        if (-not [string]$e.wave -or [string]$e.wave -eq 'unscheduled') { continue }
        $seen[$id] = 'unscheduled'
        $dropped.Add($id)
    }

    # Machines already under way cannot be re-waved.
    foreach ($id in $seen.Keys) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $id -ErrorAction SilentlyContinue
        if ($doc -and $doc.state -and $doc.state -ne 'PLANNED') {
            $current = [string]$byId[$id].wave
            if ($seen[$id] -ne $current) {
                throw "'$(($id -split '/')[-1])' has already started migrating - it cannot be moved to another wave."
            }
        }
    }

    # Availability sets must not straddle waves (also enforced by the planner).
    $avsetWaves = @{}
    foreach ($id in $seen.Keys) {
        $avset = [string]$byId[$id].assessment.availabilitySetId
        if (-not $avset) { continue }
        if ($avsetWaves.ContainsKey($avset) -and $avsetWaves[$avset] -ne $seen[$id]) {
            throw "Machines in the availability set '$(($avset -split '/')[-1])' must stay in one wave - they are a redundancy group and their sizes must stay compatible."
        }
        $avsetWaves[$avset] = $seen[$id]
    }

    # --- apply -----------------------------------------------------------
    $moved = 0
    $touchedWaves = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # APPR-LEVER-1: the waves this edit takes the sign-off requirement OFF.
    $approvalRemoved = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    # WAVE-SAVE-FALSE-1 (issue 424): WHAT changed in each wave, said in the
    # log beside the quota check and the approval it cost. A line that only
    # said "the waves changed" could not be told apart from a false alarm, and
    # on every run it was one. The words are the wave editor's own labels.
    $changes = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[string]]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $noteChange = {
        param([string]$Wave, [string]$Sentence)
        if (-not $changes.ContainsKey($Wave)) { $changes[$Wave] = [System.Collections.Generic.List[string]]::new() }
        if (-not $changes[$Wave].Contains($Sentence)) { $changes[$Wave].Add($Sentence) }
    }
    # 'unscheduled' is the planner's name for machines not in a wave yet, and
    # never shown (PLAIN-LOG-1).
    $waveSaid = { param([string]$Wave) if ($Wave -eq 'unscheduled') { 'the machines not in a wave' } else { "wave $Wave" } }
    $placeSaid = { param([string]$Wave) if ($Wave -eq 'unscheduled') { 'Among the machines not in a wave' } else { "In wave $Wave" } }
    $stopWords = @{ stop = 'Stop and ask'; proceed = 'Continue' }
    $leverWords = @{
        capacityGate             = @{ Label = 'On-demand capacity reservation for this wave'; Said = @{ BestEffort = 'No'; Reserved = 'Yes' } }
        requireApproval          = @{ Label = 'Someone must sign off before this wave runs'; Said = @{ True = 'on'; False = 'off' } }
        onDDataFound             = @{ Label = 'If files are found on the temporary disk'; Said = $stopWords }
        keepSnapshotDays         = @{ Label = 'How long the snapshot is kept'; Unit = ' days' }
        throttle                 = @{ Label = 'How many machines at once' }
    }
    $leverSaid = {
        param([string]$Field, $Value)
        $words = $leverWords[$Field]
        if ($words.Said -and $words.Said.ContainsKey([string]$Value)) { return $words.Said[[string]$Value] }
        "$Value$($words.Unit)"
    }
    # WAVE-LEVER-OVERRIDE-1: which setting is written on which machine, and
    # which machine keeps its own value - judged against the plan as STORED,
    # before any machine moves, by the same rule the service's role checks ask
    # (Get-VmfWaveSettingWrites). A setting the person did not change is not
    # written on a machine that stays in its wave; a setting a decision gave
    # one machine is never written over.
    $judged = Get-VmfWaveSettingWrites -Entries $entries -Waves $normalized
    # MACHINES-AT-ONCE-RANGE-1 (plan-entry v27): every number of machines at
    # once this save writes is one of the four choices - ConvertTo-VmfWaveLayout
    # refuses any other before anything is written (ATONCE-EARLIER-1).
    $resetToWave = [System.Collections.Generic.List[object]]::new()
    foreach ($w in $normalized) {
        $name = $w.Name
        foreach ($vmId in @($w.VmIds)) {
            $entry = $byId[[string]$vmId]
            if ([string]$entry.wave -ne $name) {
                $from = [string]$entry.wave
                $touchedWaves.Add($from) | Out-Null
                $touchedWaves.Add($name) | Out-Null
                $machine = ([string]$vmId -split '/')[-1]
                & $noteChange $from "$(& $placeSaid $from), machine $machine moved to $(& $waveSaid $name)."
                & $noteChange $name "$(& $placeSaid $name), machine $machine moved in from $(& $waveSaid $from)."
                $entry.wave = $name
                $moved++
            }
        }
    }
    # WAVE-REMOVE-NOT-SAVED-1: the machines no wave of the layout names. The
    # wave each one left is touched, so its approval, acceptance, quota check
    # and schedule go as for any other change to it.
    foreach ($id in $dropped) {
        $entry = $byId[$id]
        $from = [string]$entry.wave
        $touchedWaves.Add($from) | Out-Null
        $touchedWaves.Add('unscheduled') | Out-Null
        $machine = ($id -split '/')[-1]
        & $noteChange $from "$(& $placeSaid $from), machine $machine moved to $(& $waveSaid 'unscheduled')."
        & $noteChange 'unscheduled' "$(& $placeSaid 'unscheduled'), machine $machine moved in from $(& $waveSaid $from)."
        $entry.wave = 'unscheduled'
        $moved++
    }
    foreach ($write in @($judged.Writes)) {
        $entry = $byId[$write.VmId]
        $field = $write.Field
        $name = $write.Wave
        # APPR-LEVER-1: taking the sign-off requirement off is the one
        # lever that REMOVES a control rather than sets one, and the
        # engine's gate reads nothing else. An absent value MEANT
        # required, the same reading Test-VmfWaveApproval uses. The
        # facade lets only an approver ask for this; the run log is
        # where it is answered for afterwards.
        if ($field -eq 'requireApproval' -and -not $write.To -and [bool]$write.From) {
            $approvalRemoved.Add($name) | Out-Null
        }
        # EVAL-H7 / WAVE-SAVE-FALSE-1: written only when it changed. A value
        # written that MEANS the same still changes the text, and the
        # acceptance is a hash over each machine's policy text
        # (Get-VmfWaveOptionsHash) - so the wave would be refused as changed
        # with nothing cleared to say so. Get-VmfWaveSettingWrites lists only
        # real changes.
        # WAVE-LEVER-RESET-1: a machine given back the value of its wave. The
        # record of its decision for this setting goes, so a later change on
        # the card reaches it. An assignment keeps the place of the value in
        # the policy, so a value that was already the wave's moves nowhere.
        if ($write.Reset) {
            if ($entry.policy.PSObject.Properties[$field]) { $entry.policy.$field = $write.To }
            else { $entry.policy | Add-Member -NotePropertyName $field -NotePropertyValue $write.To -Force }
            Remove-VmfOwnDecision -PlanEntry $entry -Setting $field -Confirm:$false | Out-Null
            $touchedWaves.Add($name) | Out-Null
            $resetToWave.Add([pscustomobject]@{ Wave = $name; VmId = $write.VmId; Machine = $write.Machine; Setting = $field; Value = $write.To })
            & $noteChange $name ("$(& $placeSaid $name), machine $($write.Machine) now uses the setting of its wave for " +
                "'$($leverWords[$field].Label)': $(& $leverSaid $field $write.To). " +
                $(if ($write.Decided) { "A decision for that machine had set $(& $leverSaid $field $write.From)." } else { "It had $(& $leverSaid $field $write.From)." }))
            continue
        }
        if ($entry.policy.PSObject.Properties[$field]) { $entry.policy.$field = $write.To }
        else { $entry.policy | Add-Member -NotePropertyName $field -NotePropertyValue $write.To -Force }
        $touchedWaves.Add($name) | Out-Null
        & $noteChange $name ("$(& $placeSaid $name), the setting '$($leverWords[$field].Label)' changed from " +
            "$(& $leverSaid $field $write.From) to $(& $leverSaid $field $write.To).")
    }
    # WAVE-LEVER-OVERRIDE-1: each machine that kept its own value, said in the
    # activity - one sentence a wave and setting, and why.
    $keptSaid = @(foreach ($group in @($judged.Kept | Group-Object Wave, Field, Reason)) {
            $first = $group.Group[0]
            $names = @($group.Group | ForEach-Object { $_.Machine } | Sort-Object -Unique)
            $shown = if ($names.Count -gt 10) { "$(@($names | Select-Object -First 10) -join ', ') and $($names.Count - 10) more" } else { $names -join ', ' }
            $label = $leverWords[$first.Field].Label
            $place = & $placeSaid $first.Wave
            if ($names.Count -eq 1) {
                "$place, machine $shown does not follow the setting '$label'. " +
                $(if ($first.Reason -eq 'decision') { 'A decision for that machine set its value.' } else { 'Its value was different from the value of the wave.' })
            }
            else {
                "$place, machines $shown do not follow the setting '$label'. " +
                $(if ($first.Reason -eq 'decision') { 'A decision for each machine set its value.' } else { 'Their values were different from the value of the wave.' })
            }
        })
    $keptOwn = @($judged.Kept | ForEach-Object {
            [pscustomobject]@{ Wave = $_.Wave; VmId = $_.VmId; Machine = $_.Machine; Setting = $_.Field; Value = $_.Value; Reason = $_.Reason }
        })

    # WAVE-EDIT-RUNNING-1 (2026-09-28: refuse): a RUNNING wave does not
    # change. Its workers hold the plan they read when it started, and every
    # lease compares the machine's entry with the stored plan
    # (Test-VmfLeasedEntryCurrent) - so a machine moved out, a machine moved
    # in, or a setting changed would each be silently left untouched by the
    # wave that is running. Asked of every wave this edit touches, against the
    # STORED plan (the one the workers hold), before anything is written. A
    # wave that has finished, or whose machines are parked, may change.
    foreach ($touched in @($touchedWaves)) {
        if (-not $touched -or $touched -eq 'unscheduled') { continue }
        $running = Get-VmfWaveRunningDetail -RunPath $RunPath -Wave $touched
        if ($running) {
            throw "400: Wave $touched is running ($running). Change it when the wave has finished. To change it sooner, select Pause new work on the Migrations page and wait for its machines to finish."
        }
    }

    # WAVE-ORDER-1: the editor sends its waves in the order the person
    # arranged them, and that order is the plan's. Waves the layout did not
    # name keep their place after it.
    $previousOrder = @(if ($plan.PSObject.Properties['waveOrder']) { @($plan.waveOrder) })
    $newOrder = [System.Collections.Generic.List[string]]::new()
    foreach ($name in @($waves | ForEach-Object { [string]$_.name }) + @($previousOrder | ForEach-Object { [string]$_ })) {
        if ($name -and -not $newOrder.Contains($name) -and @($entries | Where-Object { [string]$_.wave -eq $name }).Count) { $newOrder.Add($name) }
    }

    # WAVE-SAVE-FALSE-1 (issue 424): a save that changes nothing writes
    # nothing - the rule the page already keeps (SAVE-STUCK-1), kept here too,
    # because the service is the one place every save passes. A write of the
    # same plan changes its version, which the page quotes back and a plan
    # sign-off of the exact plan is bound to, and voids an approval written
    # before WAVE-APPROVE-1, which signed the whole plan text.
    $orderSame = $plan.PSObject.Properties['waveOrder'] -and ((@($previousOrder) -join '|') -ceq (@($newOrder) -join '|'))
    if ($moved -eq 0 -and $touchedWaves.Count -eq 0 -and $orderSame) {
        # WAVE-LEVER-OVERRIDE-1: a change asked for and kept by every machine
        # it named still writes nothing - and the activity says which machine
        # kept its own value, so the change did not just disappear.
        # STEP-LOG-4: kept a throwing write on purpose. Nothing is saved here,
        # and this line is all the save writes, so a line that cannot be
        # written is an error, with nothing changed.
        if ($keptSaid.Count -and $PSCmdlet.ShouldProcess($PlanPath, 'record the machines that do not follow a setting')) {
            Write-VmfEvent -RunPath $RunPath -Step 'plan' -Outcome ok `
                -Detail "wave layout saved by ${ChangedBy}: no setting changed. $($keptSaid -join ' ')"
        }
        return [pscustomobject]@{
            Waves                 = @($newOrder)
            MovedCount            = 0
            ApprovalsInvalidated  = @()
            AcceptancesCleared    = @()
            CapacityChecksCleared = @()
            SchedulesCancelled    = @()
            KeptOwnSettings       = @($keptOwn)
            ResetToWave           = @()
            ChangedBy             = $ChangedBy
            Unchanged             = $true
        }
    }

    # What changed in each of these waves, as sentences, at most five a wave.
    # A wave that lost its quota check without a change of its own had lost
    # its last machine.
    $whySaid = {
        param([string[]]$Waves)
        foreach ($wv in @($Waves | Sort-Object -Unique)) {
            $said = if ($changes.ContainsKey($wv)) { @($changes[$wv]) }
                    elseif ($wv -eq 'unscheduled') { @('Every machine is in a wave now.') }
                    else { @("Wave $wv has no machines now.") }
            $said | Select-Object -First 5
            if ($said.Count -gt 5) {
                # AN-PROCEED-NETVSC-1 left a wave six settings, so one more
                # change is a real count: say it in the singular.
                $more = if ($said.Count -eq 6) { '1 more change' } else { "$($said.Count - 5) more changes" }
                if ($wv -eq 'unscheduled') { "The machines not in a wave have $more." }
                else { "Wave $wv has $more." }
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($PlanPath, "rewrite wave layout ($moved machines moved)")) { return }

    # CAPACITY follows the waves. A claim is recorded per wave name, so
    # renaming a wave or moving machines between waves leaves claims that
    # describe something that no longer exists - and the engine then refuses to
    # start with "no quota records found", long after the person who moved
    # the machines has gone. Found live: a machine planned as 'unscheduled' was
    # moved into 'testwave', and the wave could not start.
    #
    # WAVE-EDIT-RESERVE-1: but NEVER a claim that bills. This removed every
    # claim of a touched wave in any state, so a reservation kept charging with
    # nothing in the product pointing at it. Asked of every claim first, before
    # anything is removed or written; and again, claim by claim, just before
    # removing it - a reserve job can turn a quota check into a reservation
    # meanwhile. The plan is written after this judgement, so a refusal here
    # leaves the plan as it was; the removals come after the write.
    $liveWaveNames = @($entries | ForEach-Object { [string]$_.wave })
    $toClear = @(foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json')) {
            $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$name" -Depth 12
            if ($claim -and ([string]$claim.wave -in $touchedWaves -or [string]$claim.wave -notin $liveWaveNames)) {
                [pscustomobject]@{ Name = $name; Wave = [string]$claim.wave; State = [string]$claim.state }
            }
        })
    # Every claim is read again and judged BEFORE any is removed, so a refusal
    # never leaves some removed and the plan unsaved.
    $current = @(foreach ($c in $toClear) {
            $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$($c.Name)" -Depth 12
            if ($claim) { [pscustomobject]@{ Name = $c.Name; Wave = $c.Wave; Claim = $claim } }
        })
    foreach ($group in @($current | Group-Object Wave)) {
        $refusal = Get-VmfBillingClaimRefusal -Wave $group.Name -States @($group.Group | ForEach-Object { [string]$_.Claim.state }) -Action 'save again'
        if ($refusal) { throw $refusal }
    }

    # Add-Member -Force rather than assignment: a plan without a waveSummary
    # (hand-written, or written by an older version) is not a reason to fail an
    # edit somebody just made.
    $plan | Add-Member -NotePropertyName waveSummary -Force -NotePropertyValue @(
        $entries | Group-Object { [string]$_.wave } |
            ForEach-Object { [ordered]@{ wave = $_.Name; count = $_.Count } })
    $plan | Add-Member -NotePropertyName waveOrder -Force -NotePropertyValue @($newOrder)
    # PLAN-WRITE-RACE-1: the plan is written BEFORE the quota checks judged
    # above are removed. A save refused here (409) then leaves them, and no
    # line in the log says a removal happened that did not.
    Write-VmfTextDocumentIfVersion -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json') `
        -Content ($plan | ConvertTo-Json -Depth 24) -ExpectedVersion $read.Version

    $clearedCapacity = @()
    foreach ($c in $current) {
        # Read once more, just before it goes: a reserve job can have turned
        # this quota check into a reservation while the plan was written. A
        # record that bills is never removed; the log says what to do.
        $now = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$($c.Name)" -Depth 12
        if (-not $now) { continue }
        if ([string]$now.state -in $script:VmfClaimStatesBilling) {
            # STEP-LOG-4: this line and the two below are written after the plan
            # is saved, so a line that cannot be written is a warning: it never
            # stops the removal of the next quota check, or fails the save.
            Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome warn `
                -Detail "Wave $($c.Wave) got a capacity reservation while its machines changed. Release it on the wave, then check the quota again."
            continue
        }
        if ([string]$now.state -eq 'RELEASED') { Write-VmfReleasedClaimNote -RunPath $RunPath -Claim $now }
        Remove-VmfStoreItem -RunPath $RunPath -RelPath "capacity/$($c.Name)"
        $clearedCapacity += $c.Wave
    }
    $clearedCapacity = @($clearedCapacity | Sort-Object -Unique)
    if ($clearedCapacity.Count -gt 0) {
        # EVAL-H7: RETURNED as well as logged. A save that quietly deletes the
        # only record of a paid reservation, while the page says nothing and
        # the word "capacity" never appears on it, is how an ODCR gets orphaned
        # and keeps billing.
        # PLAIN-LOG-1, 2026-09-25: this read "quota checks cleared for
        # unscheduled - they described the waves as they were ...", which he
        # called confusing. "unscheduled" is the product's internal name for
        # machines not in a wave yet, and "cleared" sounded like a fault. Said
        # now as what happened and what to do, in the product's own words.
        $named = @($clearedCapacity | ForEach-Object { if ($_ -eq 'unscheduled') { 'the machines not in a wave' } else { "wave $_" } })
        Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome warn `
            -Detail ("The waves changed, so the earlier quota check for $($named -join ', ') no longer matched them and was removed. " +
                     "$(@(& $whySaid $clearedCapacity) -join ' ') " +
                     'Use Check the quota on a wave to check it again. A wave is also checked before it starts.')
    }

    # An approval signs off its wave (WAVE-APPROVE-1): a change to a wave -
    # a setting, or a machine that left or joined it - changes the wave's
    # version, so its approval no longer matches and is removed here, by the
    # gate's own rule, judged against the plan as stored now (WAVE-SAVE-FALSE-1).
    # An approval of a wave this edit did not touch still signs that wave, so
    # it stays; only one written before (v1, the whole plan) goes.
    # STALE-APPROVAL-RACE-1: this removed the approval of every changed wave
    # with an ordinary delete after the write, so an approver who approved
    # the plan as saved in that moment lost the approval. The judgement and
    # the delete are now one step, in Remove-VmfStaleWaveApprovals.
    $staleApproved = @(Remove-VmfStaleWaveApprovals -RunPath $RunPath -PlanPath (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json'))
    $invalidated = @($staleApproved | Where-Object { $_ } | Sort-Object -Unique)

    # EVAL-H8: the engine binds an acceptance to a HASH over every entry's vmId
    # and policy, so any edit invalidates it - but both dashboards tested
    # acceptance by FILE PRESENCE, so an edited wave kept its green "Options
    # accepted by ..." chip for a wave the engine would refuse, and because the
    # accept button renders only when the acceptance is ABSENT, there was no
    # control anywhere that could re-accept it. The approval was already
    # cleared here; the acceptance was not. Now both are.
    $acceptancesCleared = @()
    foreach ($wave in $touchedWaves) {
        if (-not $wave) { continue }
        foreach ($accName in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'acceptances' -Extension '.json')) {
            $acc = Read-VmfStoreJson -RunPath $RunPath -RelPath "acceptances/$accName"
            if ($acc -and [string]$acc.wave -eq [string]$wave) {
                Remove-VmfStoreItem -RunPath $RunPath -RelPath "acceptances/$accName"
                $acceptancesCleared += [string]$wave
            }
        }
    }
    $acceptancesCleared = @($acceptancesCleared | Sort-Object -Unique)

    # EVAL-H10: quota checks were cleaned up on a rename and SCHEDULES were
    # not - the word "schedules" did not appear in this file. A schedule naming
    # a wave that no longer has plan entries makes the timer throw on every
    # pass, for ever, and the dashboard reads schedules by existing wave name
    # so the orphan renders nowhere and cannot even be cancelled from the UI.
    $schedulesCleared = @()
    $liveWaves = @($entries | ForEach-Object { [string]$_.wave } | Sort-Object -Unique)
    foreach ($schedName in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'schedules' -Extension '.json')) {
        $sched = Read-VmfStoreJson -RunPath $RunPath -RelPath "schedules/$schedName" -Depth 8
        if (-not $sched) { continue }
        $schedWave = [string]$sched.wave
        if ($schedWave -notin $liveWaves) {
            Remove-VmfStoreItem -RunPath $RunPath -RelPath "schedules/$schedName"
            $schedulesCleared += $schedWave
        }
    }
    $schedulesCleared = @($schedulesCleared | Sort-Object -Unique)

    $detail = "wave layout changed by ${ChangedBy}: $moved machine(s) moved across $($touchedWaves.Count) wave(s)"
    if ($invalidated.Count) { $detail += "; approval cleared for $($invalidated -join ', ')" }
    if ($approvalRemoved.Count) { $detail += "; the sign-off requirement was removed from $(@($approvalRemoved) -join ', ')" }
    if ($acceptancesCleared.Count) { $detail += "; settings must be accepted again for $($acceptancesCleared -join ', ')" }
    if ($clearedCapacity.Count) { $detail += "; quota check cleared for $($clearedCapacity -join ', ')" }
    if ($schedulesCleared.Count) { $detail += "; cancelled the schedule for $($schedulesCleared -join ', '), which no longer exists" }
    # WAVE-SAVE-FALSE-1: what changed, so a person can tell an edit from a
    # false alarm.
    if ($touchedWaves.Count) { $detail += ". $(@(& $whySaid @($touchedWaves | Where-Object { $_ })) -join ' ')" }
    # DECIDE-APPROVAL-STALE-1: the one sentence every writer of the plan uses.
    $untouchedStale = @($staleApproved | Where-Object { $_ -notin $touchedWaves })
    if ($untouchedStale.Count) { $detail += ' ' + (Get-VmfStaleApprovalNote -Wave $untouchedStale) }
    if ($keptSaid.Count) { $detail += " $($keptSaid -join ' ')" }
    if ($Note) { $detail += " - $Note" }
    Write-VmfStepLine -RunPath $RunPath -Step 'plan' -Outcome ok -Detail $detail
    # APPROVE-GROUP-1: the summary of the whole migration, for the list on the
    # Migrations page. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'planSaved' | Out-Null

    [pscustomobject]@{
        Waves                 = @($plan.waveSummary | ForEach-Object { $_.wave })
        MovedCount            = $moved
        ApprovalsInvalidated  = @($invalidated)
        AcceptancesCleared    = @($acceptancesCleared)
        CapacityChecksCleared = @($clearedCapacity)
        SchedulesCancelled    = @($schedulesCleared)
        KeptOwnSettings       = @($keptOwn)
        # WAVE-LEVER-RESET-1: the machines given back the value of their wave.
        ResetToWave           = @($resetToWave)
        ChangedBy             = $ChangedBy
        Unchanged             = $false
    }
}
