function Set-VmfMachineTarget {
    <#
    .SYNOPSIS
        WAVE-MIX-2: change ONE machine's size series after planning. Its target
        is recomputed; nothing is planned again.
    .DESCRIPTION
        The size series belongs to each machine (ADVISOR-1), chosen on the
        assessment's targets step. After planning, the only way to change one
        machine was to choose again and plan again - a new migration, and the
        wave arrangement lost. The per-wave series control replaced every
        machine's choice at once and was removed (WAVE-SERIES-GONE-1).

        WHICH SERIES A MACHINE MAY TAKE IS THE TARGETS STEP'S ANSWER, not a new
        one. The target options (target-advice.json) travel with the plan, and
        only an option they call supported is offered. That is where the rules
        live that a bare size lookup does not know - a machine already on v6 or
        v7 is never sent back to v5, a machine on NVMe is never re-planned.

        THE SIZE IS THEN RECOMPUTED, AND MUST AGREE. Resolve-VmfEntryTarget
        runs against the catalog saved with the plan, and its size and path must
        equal the options' - and recomputing the machine's CURRENT series must
        give back its current target. Either disagreement means this plan was
        not made by the rules in use now, and the answer is to plan again, never
        to trust one of the two.

        A CHANGE IS REFUSED WHILE IT COULD REACH A RUNNING ENGINE. The engine's
        workers hold the plan they read at the start of a wave, so a machine
        with no state yet is not proof that nothing will act on the old target.
        Nothing in the machine's WAVE may have a state document or a lease.
        (A worker also refuses a plan whose version of its wave differs from
        the one its wave's start checks passed - see worker.ps1.)

        What a change clears, and why each one:
          * the wave's APPROVAL and its ACCEPTANCE - each described the wave
            as it was, so the new target is shown and signed again.
          * the wave's QUOTA CHECK - it names sizes. A claim that stands for a
            capacity reservation in Azure is NEVER removed: it is the only
            record of something that bills, so the change is refused instead.
          * the plan sign-off follows the plan's version by itself.

        RETRY-SERIES-1: -AfterRollback is for a machine that ROLLED BACK. It is
        running, as it was, and nothing acts on it, so its target may change
        once nothing in its wave is running - the same rule the release of a
        reservation uses (Get-VmfWaveReleaseRefusal). The machine STAYS rolled
        back: it is tried again with Retry once its wave is accepted and
        approved again. Re-arming it here would leave it at PRECHECK waiting on
        a sign-off - reading as running, and refused by Skip and by this.
    .PARAMETER Option
        The series: v5, v6 or v7. Omit it (or use -WhatIf) for the options only.
    .PARAMETER ExpectedPlanVersion
        The plan version the caller read (PLANVER-2). A stored version that
        differs is refused with 409. The facade requires it.
    .PARAMETER CatalogBySize
        size -> SKU for the machine's region. Omit it and the catalog saved
        with the plan is used (WAVEGEN-HOSTED-1).
    .PARAMETER AfterRollback
        RETRY-SERIES-1: the machine rolled back; change its target so it can
        be tried again on it.
    .PARAMETER ChangedBy
        Who asked, when the caller acts for somebody (the facade does).
    .EXAMPLE
        Set-VmfMachineTarget -RunPath $run -VmId $id -WhatIf
    .EXAMPLE
        Set-VmfMachineTarget -RunPath $run -VmId $id -Option v5 -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$VmId,
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$Option,
        [Parameter()][string]$ExpectedPlanVersion,
        [Parameter()][hashtable]$CatalogBySize,
        [Parameter()][string]$ChangedBy,
        [Parameter()][switch]$AfterRollback
    )

    # PLANVER-2: the version is taken over the STORED TEXT, and the plan is
    # parsed from that same text - one read, so the version checked is the
    # version changed.
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'plan.json')) { throw '400: There is no plan in this migration yet.' }
    $read = Read-VmfPlanFileVersioned -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json')
    if ($ExpectedPlanVersion -and $read.Version -ne $ExpectedPlanVersion) {
        throw '409: The plan changed after this page read it. Load the page again, then change the target again.'
    }
    $plan = $read.Plan
    $entry = @($plan.entries | Where-Object { [string]$_.vmId -eq $VmId }) | Select-Object -First 1
    if (-not $entry) { throw "400: This machine is not in the plan: $VmId" }
    $name = ($VmId -split '/')[-1]
    $wave = [string]$entry.wave

    # Only a machine this plan moves. EXCLUDED and MANUAL entries carry too
    # little of the scan (no disk controller) to be judged again here.
    if ([string]$entry.path -ne 'A') {
        throw "400: This plan does not move $name, so its target cannot change here. Choose its target on the targets step, then plan again."
    }

    # Nothing in its wave may have been touched by the engine: a state
    # document or a lease on ANY member means a worker holds this plan.
    # Asked again after the write (below), so it is kept as one question.
    $members = @($plan.entries | Where-Object { [string]$_.wave -eq $wave } | ForEach-Object { [string]$_.vmId })
    $touched = {
        foreach ($id in $members) {
            $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $id -ErrorAction SilentlyContinue
            $lease = Get-VmfLeaseInfo -RunPath $RunPath -VmId $id
            if (($doc -and $doc.state) -or $lease) {
                return "$(($id -split '/')[-1]) is $(if ($doc -and $doc.state) { $doc.state } else { Get-VmfLeaseHolderWords -Lease $lease })"
            }
        }
        $null
    }
    $needsScsi = $false
    if ($AfterRollback) {
        # RETRY-SERIES-1: only a machine that rolled back - running, as it was.
        # Anything else is mid-move, finished, or waiting on a person.
        $own = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId -ErrorAction SilentlyContinue
        # ROLLBACK-SIZE-REFUSED-SERIES-1 (2026-11-14): and a
        # machine whose rollback Azure refused its original size
        # (rollbackSizeRefused) - its way forward is another series, from the
        # first safety copy, restored onto the size this change plans.
        $mayChange = { param($o) [bool]($o -and ([string]$o.state -eq 'FAILED_ROLLED_BACK' -or
                    ([string]$o.state -eq 'FAILED_NEEDS_ATTENTION' -and [string](Get-VmfLastStopEntry -Doc $o).reasonCode -eq 'rollbackSizeRefused'))) }
        if (-not (& $mayChange $own)) {
            throw "400: $name did not roll back, so its target cannot change here."
        }
        # Until a restore, the machine is on the disks the move left, and the
        # first safety copy starts only on SCSI: only a SCSI series.
        $needsScsi = [bool](Get-VmfSizeRefusedStop -Doc $own)
        # Nothing in its wave may be running: a lease, or a state that is not
        # final. Finished and parked machines do not stop it. Asked again after
        # the write, with the machine's own state: a Retry or a Skip of it in
        # between undoes the change.
        $touched = {
            $o = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId -ErrorAction SilentlyContinue
            if (-not (& $mayChange $o)) { return "$name is $(if ($o) { $o.state } else { 'gone' })" }
            Get-VmfWaveReleaseRefusal -RunPath $RunPath -Wave $wave
        }
        $startedBy = & $touched
        if ($startedBy) { throw "400: Wave $wave is running ($startedBy), so the target of $name cannot change now." }
    }
    else {
        $startedBy = & $touched
        if ($startedBy) { throw "400: Wave $wave has started ($startedBy), so the target of $name cannot change now." }
    }

    # The quota check may be cleared; a reservation that bills may not
    # (WAVE-EDIT-RESERVE-1: one rule, shared with the wave editor's save). A
    # released one bills nothing and is cleared, with a line in the activity log.
    $claimsOfWave = {
        @(foreach ($capName in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json')) {
                $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$capName" -Depth 12
                if ($claim -and [string]$claim.wave -eq $wave) { [pscustomobject]@{ Name = $capName; State = [string]$claim.state } }
            })
    }
    $refuseHeld = { param($claims)
        $refusal = Get-VmfBillingClaimRefusal -Wave $wave -States @($claims | ForEach-Object { [string]$_.State }) -Action "change the target of $name"
        if ($refusal) { throw $refusal }
    }
    $waveClaims = & $claimsOfWave
    & $refuseHeld $waveClaims

    # The targets step's answer, saved with the plan.
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'target-advice.json')) {
        throw '400: This plan was made without its target options saved beside it. Plan this migration again to change one target.'
    }
    $advice = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'target-advice.json') | ConvertFrom-Json -Depth 30
    $advised = @($advice.machines | Where-Object { [string]$_.vmId -eq $VmId }) | Select-Object -First 1
    if (-not $advised) { throw "400: The target options saved with this plan do not name $name. Plan this migration again." }

    # WAVEGEN-HOSTED-1: the catalog the plan was built with, saved beside it.
    $loc = [string]$entry.assessment.location
    if (-not $CatalogBySize) { $CatalogBySize = Read-VmfCatalogSnapshot -RunPath $RunPath -Location $loc }
    if (-not $CatalogBySize) {
        throw "400: The size catalog for $loc was not saved with this plan. Plan this migration again."
    }

    $choiceProp = $entry.target.PSObject.Properties['choice']
    $current = if ($choiceProp -and $choiceProp.Value -and $choiceProp.Value.option) { [string]$choiceProp.Value.option }
               elseif ($entry.policy.PSObject.Properties['targetGeneration'] -and $entry.policy.targetGeneration) { [string]$entry.policy.targetGeneration }
               else { 'v6' }

    # The rules in use now must give back the target this machine has.
    $agrees = Test-VmfPlannedTargetAgrees -Entry $entry -CatalogBySize $CatalogBySize -Current $current

    # ADVISE-AN-1 (2026-10-12): the processor maker never changes without
    # the person choosing it on the targets step, where the two targets show
    # side by side. A series whose size would change it is not available here,
    # so the page never offers what the change refuses (second review of
    # 2026-10-12). Back to the maker of the machine itself is no change of maker.
    $makerNow = Get-VmfSizeProcessor -SizeName ([string]$entry.target.size)
    $makerOwn = Get-VmfSizeProcessor -SizeName ([string]$entry.assessment.sourceSize)
    $makerChanges = { param([string]$Size)
        $makerTo = Get-VmfSizeProcessor -SizeName $Size
        [bool]($makerTo -and $makerNow -and $makerTo -ne $makerNow -and $makerTo -ne $makerOwn) }

    $decided = foreach ($series in 'v5', 'v6', 'v7') {
        $o = @($advised.options | Where-Object { [string]$_.option -eq $series }) | Select-Object -First 1
        $t = Resolve-VmfEntryTarget -Assessment $entry.assessment -CatalogBySize $CatalogBySize -TargetGeneration $series
        $why = @(
            # RETIRE-SCOPE-1: the rules in use now say the size is out of
            # scope, whatever the saved options said before the margin.
            # GPU-SCOPE-1: and a family the product does not move, the same way.
            # DISKS-32-1: and more than 32 data disks (the list holds it).
            if (@($t.Blockers | Where-Object { $_ -in (Get-VmfOutOfScopeBlockerCodes) }).Count) { @($t.Blockers | Where-Object { $_ -in (Get-VmfOutOfScopeBlockerCodes) }) }
            elseif (-not $o -or -not $o.supported) { @($(if ($o) { $o.notSupported } else { 'no-options' })) }
            elseif ($o.sizeUnverified -or [string]$t.Mapping.Code -eq 'mapped-unverified') { 'size-unverified' }
            elseif ([string]$t.Mapping.Target -ne [string]$o.targetSize -or [string]$t.Path -ne [string]$o.path) { 'catalog-disagrees' }
            elseif (-not $agrees -and $series -ne $current) { 'plan-disagrees' }
            elseif ($series -ne $current -and (& $makerChanges ([string]$t.Mapping.Target))) { 'processor-change' }
            # ROLLBACK-SIZE-REFUSED-SERIES-1: the first safety copy starts only
            # on a SCSI size, so a machine not restored yet takes no NVMe series.
            elseif ($series -ne $current -and $needsScsi -and [string]$t.Controller -eq 'NVMe') { 'first-copy-needs-scsi' }
        )
        $why = @($why | Where-Object { $_ })
        # GPU-SCOPE-1 review: the CURRENT series too says when the machine is
        # outside the scope of this tool - a plan made before the rule shows
        # its old target as if it would move, and PRECHECK stops it.
        $scope = @($why | Where-Object { $_ -in (Get-VmfOutOfScopeBlockerCodes) })
        [pscustomobject]@{ Option = $series; Result = $t; Why = $why; Scope = $scope
            Supported = (-not $why.Count) -or ($series -eq $current -and -not $scope.Count) }
    }
    $options = @($decided | ForEach-Object {
            [pscustomobject]@{
                option = $_.Option; current = ($_.Option -eq $current)
                supported = $_.Supported
                targetSize = $(if ($_.Option -eq $current) { [string]$entry.target.size } elseif ($_.Supported) { [string]$_.Result.Mapping.Target } else { $null })
                # TEMP-DISK-PREVIEW-1: the move is the in-place upgrade (Preview),
                # which needs the preview feature VMTempDiskResizePreview - the
                # current move as its entry records it, another series as the
                # rules give it. WAVE-PREVIEW-1 / REBUILD-REMOVE-PLAN-1: a change
                # here plans the Preview where the rules give it, and no series
                # is a rebuild (the field rebuild is gone).
                preview = $(if ($_.Option -eq $current) { (Get-VmfEntryMethod -Entry $entry) -eq 'preview' } else { [bool]($_.Supported -and $_.Result.Preview) })
                why = @($(if ($_.Option -ne $current) { $_.Why } else { $_.Scope }))
            } })
    # PlanVersion: the version these options were judged against, for the
    # page to quote back when it applies (PLANVER-2).
    $answer = [ordered]@{ VmId = $VmId; Name = $name; Wave = $wave; Current = $current; CurrentSize = [string]$entry.target.size; Options = $options; Applied = $false; PlanVersion = $read.Version }

    if ($AfterRollback -and $Option -and $Option -eq $current) {
        throw "400: $name is on $current already. Use Try this machine again to try it again on $current."
    }

    if (-not $Option -or $Option -eq $current -or
        -not $PSCmdlet.ShouldProcess("$name in $RunPath", "change the target to $Option")) {
        return [pscustomobject]$answer
    }
    $pick = @($decided | Where-Object Option -EQ $Option)[0]
    # RETIRE-SCOPE-1: from one day before Microsoft retires the machine's size,
    # it is outside the scope of this tool on every series - said as scope, in
    # words, before anything is cleared or written.
    $outOfScope = Get-VmfRetiredScopeDetail -Size ([string]$entry.assessment.sourceSize)
    # GPU-SCOPE-1: and a family the product does not move, in the same words.
    if (-not $outOfScope) { $outOfScope = Get-VmfFamilyScopeDetail -Size ([string]$entry.assessment.sourceSize) }
    # DISKS-32-1: and more than 32 data disks.
    if (-not $outOfScope) { $outOfScope = Get-VmfDataDiskScopeDetail -Count (Get-VmfAssessedDataDiskCount -Assessment $entry.assessment) }
    if ($outOfScope) { throw "400: Nothing changed for $name. $outOfScope" }
    # ADVISE-AN-1 (2026-10-12): a change of the processor maker is
    # refused (processor-change, above), in words that say why.
    if (@($pick.Why) -contains 'processor-change') {
        $makerNew = Get-VmfSizeProcessor -SizeName ([string]$pick.Result.Mapping.Target)
        throw "400: On $Option, $name moves to $($pick.Result.Mapping.Target), an $makerNew size, so its processor changes from $makerNow. Choose that on the targets step, then plan again."
    }
    if ($pick.Why.Count) { throw "400: $name cannot move to $($Option) from this plan ($($pick.Why -join ', ')). Choose its target on the targets step, then plan again." }

    $who = if ($ChangedBy) { $ChangedBy } else { (Get-VmfSignedInIdentity).Identity }
    $t = $pick.Result
    $fromSize = [string]$entry.target.size

    # CLEAR FIRST, WRITE SECOND. A wave that starts between the two finds no
    # acceptance and no approval, and is refused - never started on either
    # target without them. Each record's text is kept, so a change that has to
    # be undone (below) puts back exactly what was there: the plan text is
    # restored byte for byte, so its version, and what the records bind, match.
    # STALE-APPROVAL-RACE-1: a record is taken only as the text that was
    # read (Remove-VmfStoreItemIfVersion, one step), so the undo puts back
    # the text that was removed. It is put back only into an empty place: a
    # record written since (an approval given meanwhile) stays.
    $removed = [System.Collections.Generic.List[object]]::new()
    $putBack = { foreach ($r in $removed) { if ($r.Text) { [void](Write-VmfStoreTextExclusive -RunPath $RunPath -RelPath $r.Rel -Content $r.Text) } } }
    $take = { param($rel)
        for ($i = 0; $i -lt 5; $i++) {
            $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
            if ($null -eq $text) {
                if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath $rel)) { return }
                $text = ''
            }
            if (Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $text)) {
                $removed.Add([pscustomobject]@{ Rel = $rel; Text = $text })
                return
            }
        }
        & $putBack
        throw "409: A record of wave $wave changed while the target of $name was changing. Nothing was changed. Load the page again, then change the target again."
    }
    $invalidated = [ordered]@{ approval = $false; acceptance = $false; capacity = $false }
    $releasedGone = [System.Collections.Generic.List[object]]::new()
    if ($wave -and $wave -ne 'unscheduled') {
        # A reserve job may have turned a quota check into a reservation while
        # this was reading the rest. Read again, just before anything goes.
        $waveClaims = & $claimsOfWave
        & $refuseHeld $waveClaims
        if (Test-VmfStoreItem -RunPath $RunPath -RelPath "approvals/$wave.json") {
            & $take "approvals/$wave.json"
            $invalidated.approval = $true
        }
        # ACCEPT-NAME-1: this wave's acceptance only. The earlier file name was
        # shared by waves wave_1 and wave-1, and this removed it for either.
        $accRel = Resolve-VmfWaveOptionsAcceptancePath -Wave $wave
        if (Test-VmfStoreItem -RunPath $RunPath -RelPath $accRel) {
            & $take $accRel
            $invalidated.acceptance = $true
        }
        foreach ($c in $waveClaims) {
            $now = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$($c.Name)" -Depth 12
            if ($now -and [string]$now.state -in $script:VmfClaimStatesBilling) { & $putBack; & $refuseHeld @([pscustomobject]@{ State = [string]$now.state }) }
            # Said in the log only once the change stands (below): a change
            # that is undone puts the record back, and the line would be false.
            # REPORT-RELEASED-1: kept as history BEFORE the claim is taken, so a
            # stop between here and the log line below loses nothing. Its name
            # comes from the reservation, so the second write replaces it.
            if ($now -and [string]$now.state -eq 'RELEASED') { Save-VmfReleasedClaimHistory -RunPath $RunPath -Claim $now; $releasedGone.Add($now) }
            & $take "capacity/$($c.Name)"
            $invalidated.capacity = $true
        }
    }

    # target.choice is a v15 field, so the entry it is written into says v15 -
    # an older entry's shape is a subset of it.
    $entry | Add-Member -NotePropertyName schemaVersion -Force -NotePropertyValue (Get-VmfPlanSchemaVersion)
    # REBUILD-PICKER-1 (v23): and the method of the new move. WAVE-PREVIEW-1:
    # preview where the rules give the Preview, so Checking reads the feature.
    $entry.target | Add-Member -NotePropertyName choice -Force -NotePropertyValue ([ordered]@{ option = $Option; source = 'person'; chosenBy = $who
            method = (Get-VmfMoveMethod -Preview:([bool]$t.Preview)) })
    $entry.target.size = $t.Mapping.Target
    $entry.target.sizeAlternates = @($t.Mapping.Alternates)
    $entry.target.diskArch = $t.DiskArch
    $entry.target.tempDisks = $t.TempDisks
    $entry.target.controller = $t.Controller
    $entry.path = $t.Path
    $entry.policy | Add-Member -NotePropertyName targetGeneration -Force -NotePropertyValue $Option
    # AN-PLAN-1: the new target may require accelerated networking. The wave's
    # acceptance was cleared above, so the person sees it named again.
    # Both ways, as the planner decides it: set when the target requires it,
    # and ABSENT when it does not - an explicit value left over from the old
    # target is read by the engine as a choice somebody made.
    $plannedAn = Get-VmfPlannedAcceleratedNetworking -Vm $entry.assessment -TargetSize ([string]$t.Mapping.Target)
    if ($plannedAn) { $entry.policy | Add-Member -NotePropertyName acceleratedNetworking -Force -NotePropertyValue $plannedAn }
    elseif ($entry.policy.PSObject.Properties['acceleratedNetworking']) { $entry.policy.PSObject.Properties.Remove('acceleratedNetworking') }
    # OLD-SKU-1C: Premium SSD for the disks stays only on a size that takes
    # it, by the saved target options; otherwise it is cleared, and said.
    # HDD-OS-1: Standard SSD for the OS disk stays on any size - every size
    # takes Standard SSD.
    $diskCleared = $null
    if ($entry.policy.PSObject.Properties['diskUpgrade'] -and [string]$entry.policy.diskUpgrade -in @('os', 'all')) {
        $newOpt = @($advised.options | Where-Object { [string]$_.option -eq $Option }) | Select-Object -First 1
        if (-not $newOpt -or $newOpt.premiumDisks -ne $true) {
            $entry.policy.PSObject.Properties.Remove('diskUpgrade')
            $diskCleared = "The disk types of $name are kept now: the size $($t.Mapping.Target) takes no Premium SSD, or Azure does not say."
        }
    }
    $kernelCleared = $null
    # MANA-LINUX-KERNEL-1 (review): Update the kernel stays only on a target
    # that can give MANA. Otherwise the machine goes back to Stop and ask -
    # the wave default - and its decision record goes with it, and it is said:
    # the sign-off must not name a machine whose kernel will never be updated.
    if ([string]$entry.policy.onDriverBelowFloor -eq 'updateKernel' -and -not (Test-VmfKernelUpdateOfferedForEntry -PlanEntry $entry)) {
        $entry.policy.onDriverBelowFloor = 'stop'
        if ($entry.PSObject.Properties['decisions']) {
            $entry.decisions = @(@($entry.decisions) | Where-Object { $_ -and [string]$_.setting -ne 'onDriverBelowFloor' })
            if (-not @($entry.decisions).Count) { $entry.PSObject.Properties.Remove('decisions') }
        }
        $kernelCleared = "The kernel of $name is not updated now: the size $($t.Mapping.Target) cannot use MANA."
    }
    # AN-MANA-DRIVER-RULE-1 (2026-11-06): no target change writes
    # ensureOff. ADVISE-AN-1 gave a machine that kept its processor maker the
    # setting of its new target (Get-VmfAnMakerPolicy: ensureOff on v6 and
    # v7). A machine with no MANA driver possible is now offered no size that
    # can give MANA (the rules above refuse it, no-mana-driver).
    # WAVE-AN-NAMES-1: and whether the move to the new target turns
    # accelerated networking on, as the plan records it.
    Set-VmfPlannedAnOutcome -PlanEntry $entry -Confirm:$false -WhatIf:$false
    # PLAN-NOTES-TARGET-1: the notes a plan made on the new target has, from
    # the one function New-VmfPlan asks too. This wrote the retirement warning
    # alone (V3-RETIRE-1 review), and the other notes were lost. A plan entry
    # does not carry the disk controller the scan read, so it comes from the
    # target options saved with the plan, which do.
    # RETIRE-SCOPE-1: and no rollback size is written. One an older entry
    # carries (plan-entry v18) is left as it is; nothing reads it.
    $scanController = if ($advised.PSObject.Properties['diskController'] -and $advised.diskController) { [string]$advised.diskController }
                      elseif ($entry.assessment.PSObject.Properties['diskController']) { [string]$entry.assessment.diskController }
                      else { '' }
    $scanned = [pscustomobject]@{ sourceSize = [string]$entry.assessment.sourceSize; diskController = $scanController }
    $entry.planNotes = @(Get-VmfPlanEntryNotes -Mapping $t.Mapping -Assessment $scanned -Controller ([string]$t.Controller) -Path ([string]$t.Path))
    # MANA-WIN-3: and whether the move to the new target can download the
    # MANA driver.
    Set-VmfManaDriverDownloadNote -PlanEntry $entry -Confirm:$false -WhatIf:$false
    # pathSummary is DERIVED from the entries: a change can move an entry an
    # earlier version planned on Path B to Path A.
    $plan | Add-Member -NotePropertyName pathSummary -Force -NotePropertyValue @(
        $plan.entries | Group-Object { [string]$_.path } | ForEach-Object { [ordered]@{ path = $_.Name; count = $_.Count } })
    # PLAN-WRITE-RACE-1: only over the text read above. A plan written by
    # anybody since is a 409 - nothing was written, so the records taken are
    # put back, but only while they still describe the wave: a writer that
    # changed this wave's machines meanwhile made them stale. Any other failure
    # leaves them cleared: whether the write landed is not known, and old
    # sign-offs must not stand on a new plan.
    $written = $plan | ConvertTo-Json -Depth 24
    $planHandle = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json'
    try { Write-VmfTextDocumentIfVersion -Path $planHandle -Content $written -ExpectedVersion $read.Version }
    catch {
        if ("$_" -match '^409') {
            # WAVE-APPROVE-1: "still describe the wave" is the wave's version -
            # the same rule its approval is judged by.
            $waveOf = { param($text) if (-not $text) { return '' } Get-VmfWaveVersion -PlanText ([string]$text) -Wave $wave }
            if ((& $waveOf (Read-VmfTextDocument -Path $planHandle)) -ceq (& $waveOf $read.Text)) { & $putBack }
        }
        throw
    }

    # AND ASK AGAIN. A wave whose start checks passed before the clearing above
    # can have workers that lease a machine between the first question and the
    # write, and run it from the plan as it was. If anything in the wave was
    # taken meanwhile, the change is undone - the plan's text and every record
    # put back - so what runs and what the plan says never differ. (A worker
    # that leases AFTER the write sees the entry changed and leaves it:
    # Test-VmfLeasedEntryCurrent.)
    $startedBy = & $touched
    if ($startedBy) {
        # PLAN-WRITE-RACE-1: put back only over our own text. A plan written by
        # anybody since is theirs; the records stay cleared, which only asks
        # for the wave to be accepted and approved again.
        try {
            Write-VmfTextDocumentIfVersion -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'plan.json') -Content $read.Text `
                -ExpectedVersion (Get-VmfDocumentVersion -Text $written)
        }
        catch {
            throw "409: Wave $wave started while the target of $name was changing ($startedBy), and the plan changed again after that. Load the page again and check the target of $name."
        }
        & $putBack
        throw "409: Wave $wave started while the target of $name was changing ($startedBy). Nothing was changed."
    }
    foreach ($gone in $releasedGone) { Write-VmfReleasedClaimNote -RunPath $RunPath -Claim $gone }
    # WAVE-SAVE-FALSE-1: the change stands, so any other approval that no
    # longer matches is removed - kept, the page called the wave approved and
    # the engine refused it. WAVE-APPROVE-1: another wave's approval signs that
    # wave, which this change did not touch, so it stays; only one written
    # before (v1, the whole plan) goes. Done only now: an undo above restores
    # the plan text, and those approvals with it.
    $staleApprovals = @(Remove-VmfStaleWaveApprovals -RunPath $RunPath -PlanPath $planHandle)

    # STEP-LOG-4: both lines are written after the plan is saved, so a line
    # that cannot be written is a warning, never a failed change.
    if ($invalidated.capacity) {
        Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome warn `
            -Detail ("A target size in wave $wave changed, so its earlier quota check no longer matched and was removed. " +
                     'Use Check the quota on the wave to check it again. The wave is also checked before it starts.')
    }
    Write-VmfStepLine -RunPath $RunPath -Step 'plan' -Outcome ok -VmId $VmId `
        -Detail ("$who changed the target of $name from $current ($fromSize) to $Option ($($t.Mapping.Target))$(if ($AfterRollback -and $needsScsi) { ' after Azure refused its original size' } elseif ($AfterRollback) { ' after it rolled back' }).$(if ($diskCleared) { " $diskCleared" })$(if ($kernelCleared) { " $kernelCleared" })" +
                 $(if ($staleApprovals.Count) { ' ' + (Get-VmfStaleApprovalNote -Wave $staleApprovals) } else { '' }))

    # APPROVE-GROUP-1: the summary of the whole migration, for the list on the
    # Migrations page. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -Reason 'planSaved' | Out-Null

    $answer.Current = $Option
    $answer.CurrentSize = [string]$t.Mapping.Target
    $answer.Options = @($options | ForEach-Object { $_.current = ($_.option -eq $Option); $_ })
    $answer.Applied = $true
    $answer.From = $current
    $answer.FromSize = $fromSize
    $answer.Invalidated = $invalidated
    # The approvals of OTHER waves this change made stale (its own wave's is
    # Invalidated.approval).
    $answer.ApprovalsCleared = @($staleApprovals)
    $answer.ChangedBy = $who
    $answer.DiskChoiceCleared = $diskCleared
    $answer.KernelChoiceCleared = $kernelCleared
    [pscustomobject]$answer
}
