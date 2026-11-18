function New-VmfPlan {
    <#
    .SYNOPSIS
        Phase 2 of the factory: turn an assessment into a reviewable migration
        plan - target sizes, paths, customer-named waves, and per-wave policy levers.
        The plan is an artifact: nothing executes until a human approves it.
    .PARAMETER AssessmentPath
        Path to assessment.json from Invoke-VmfAssessment.
    .NOTES
        WAVE-2: no environment vocabulary anywhere. Waves get neutral starting
        names (wave-1..n) the customer renames in the wave editor; every
        policy is a per-wave lever from ONE safe default set, and nothing runs
        until a person accepts the levers for their wave.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$AssessmentPath,
        [Parameter(Mandatory)][string]$OutPath,
        # WAVE-SIZE-REMOVE-1: no wave size. Each group is one wave, whatever its
        # size; how many machines move at once is a setting of the wave.
        # CAP-3: capacity assurance as a user choice.
        # 'BestEffort' = regular on-demand capacity, 'Reserved' = guaranteed
        # capacity for the migration window. Applies to every entry at plan
        # time; the wave editor adjusts it per wave afterwards. (The
        # per-ring hashtable form died with the rings - WAVE-2.)
        [Parameter()][string]$CapacityGate,
        # WAVE-2 lever 8: v6 by default, v7 chosen per wave.
        # Nothing is silently substituted - a machine with no target at the
        # chosen generation is reported, never quietly moved to the other one.
        # GEN-V5-1: or v5, the plain resize - less change, Generation 1 allowed.
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # WAVE-1: how machines are grouped into waves, since a
        # customer estate may carry no useful tags. 'tags' keeps app-tagged
        # machines together (untagged stand alone); 'resourceGroup' migrates a
        # resource group together; 'singleWave' puts every machine in one
        # wave. Availability-set members stay together under every strategy.
        [Parameter()][ValidateSet('tags', 'resourceGroup', 'singleWave', 'none')][string]$WaveStrategy = 'tags',
        # WAVE-1: WHICH tag carries the grouping - a machine may have many.
        [Parameter()][string]$AppGroupTag,
        # ADVISOR-1: the app may not plan without a target chosen
        # for each machine. The hosted engine's plan operation sets this unless
        # the request named one series; a command-line caller that does not set
        # it plans every machine on -TargetGeneration, as before.
        [Parameter()][switch]$RequireTargets,
        # MACHINE-PICK-1: nor without the machines chosen for the
        # migration. Set the same way, by the same operation. Saved targets
        # never stand for the list (TARGETS-NO-LIST-1).
        [Parameter()][switch]$RequireMachineChoice
    )

    if ($CapacityGate) {
        $gateValues = if ($CapacityGate -is [hashtable]) { @($CapacityGate.Values) } else { @([string]$CapacityGate) }
        foreach ($g in $gateValues) {
            if ($g -notin @('BestEffort', 'Reserved')) {
                throw "CapacityGate values must be 'BestEffort' or 'Reserved' (got '$g')."
            }
        }
    }

    $assessment = Read-VmfJsonDocument -Path $AssessmentPath
    Assert-VmfSupportedAssessment -Assessment $assessment -Source $AssessmentPath

    # ADVISOR-1: the target each machine was given on the assessment, when
    # targets were chosen (Set-VmfTargetChoice). Each machine is then planned on
    # ITS OWN series, and a machine with no choice is not moved. With none
    # saved, every machine is planned on -TargetGeneration, as before.
    $assessmentDir = Split-VmfStorePath -Path $AssessmentPath
    $choices = $null
    $choicesText = $null
    $adviceText = $null
    $choiceOf = @{}
    $sizeOf = @{}
    # REBUILD-PICKER-1: the method each saved choice names (target-choices v7).
    $methodOf = @{}
    $disksOf = @{}
    $kernelOf = @{}
    $kernelBy = ''
    $kernelUtc = ''
    # After the review: an assessment nobody reviewed is refused for THAT, below.
    $reviewed = Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'approval.json'
    $hasMachineChoice = Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'machine-choices.json'
    # MACHINE-PICK-1: the machines first, then their targets - the order the
    # wizard asks them in. TARGETS-NO-LIST-1: Set-VmfTargetChoice saves no
    # target without the list, so targets with no list are no shape this
    # version writes, and never stand for the list.
    if ($RequireMachineChoice -and $reviewed -and -not $hasMachineChoice) {
        throw ('No machine was chosen for this migration yet. Choose the machines, then their targets, then plan - ' +
               'open the assessment and select Plan a migration from this.')
    }
    if (-not $hasMachineChoice -and (Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'target-choices.json')) {
        throw 'The targets of this assessment have no list of machines, so choose the machines, then their targets, then plan.'
    }
    if ($RequireTargets -and $reviewed -and
        -not (Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'target-choices.json')) {
        throw ('No target was chosen for these machines yet. Choose the target for each machine, then plan - ' +
               'open the assessment and select Plan a migration from this.')
    }
    if (Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'target-choices.json') {
        $choicesText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $assessmentDir -RelPath 'target-choices.json')
        $choices = $choicesText | ConvertFrom-Json -Depth 20
        # TARGETS-NO-LIST-1: the version Set-VmfTargetChoice writes, only.
        if ([string]$choices.schemaVersion -ne [string](Get-VmfTargetChoicesSchemaVersion)) {
            throw 'The targets of this assessment were saved by an earlier version of this product, so choose the targets again, then plan.'
        }
        # Bound to the scan that was reviewed, by the same hash the approval
        # binds (PLANVER-2: Get-VmfDocumentVersion over the stored text).
        $scanHash = Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $AssessmentPath)
        if ($choices.assessmentHash -and [string]$choices.assessmentHash -ne $scanHash) {
            throw ('The targets were chosen on a different scan of these machines. Choose the targets again ' +
                   'for this assessment, then plan.')
        }
        # OLD-FAM-1 review: and on the target options they were chosen from
        # (PLANVER-2: the version of the stored text). A choice saves no size
        # when the best was taken, so options made again can change the size
        # a machine is planned on - to half the memory, for an A2_v2 that
        # Dl now suits. Choosing again shows the new options first.
        if (Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'target-advice.json') {
            $adviceText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $assessmentDir -RelPath 'target-advice.json')
            $adviceNow = Get-VmfDocumentVersion -Text $adviceText
            if ([string]$choices.adviceVersion -and [string]$choices.adviceVersion -ne $adviceNow) {
                throw ('The targets were chosen on target options that were made again since. Choose the targets again ' +
                       'for this assessment, then plan.')
            }
            # V3-TEMPDISK-1: and on options this version of the rules made. A
            # choice with no size takes the size the rules give NOW, so options
            # from older rules showed a size the plan would not use - a v3
            # machine was shown D4s_v6 and would be planned on D4ds_v6. The
            # targets step refuses to save on older options and makes them
            # again (Set-VmfTargetChoice); the plan holds to the same line.
            $adviceSchema = 0
            [void][int]::TryParse([string]($adviceText | ConvertFrom-Json -Depth 32).schemaVersion, [ref]$adviceSchema)
            if ([string]$choices.adviceVersion -and $adviceSchema -ne (Get-VmfTargetAdviceSchemaVersion)) {
                throw ('The targets were chosen on target options that an earlier version of this product made. Make the ' +
                       'target options again, choose the targets again for this assessment, then plan.')
            }
        }
        foreach ($c in @($choices.choices)) {
            # No time is copied here: it stays in target-choices.json, which
            # travels with the migration. A date re-read from JSON is a date
            # value, not the text that was written (CLAUDE.md, PLANVER-2).
            $choiceOf[[string]$c.vmId] = [ordered]@{
                option = [string]$c.option; source = [string]$c.source; chosenBy = [string]$choices.savedBy.identity
            }
            # OLD-SKU-1B: the size chosen, kept apart - the plan records it as
            # the entry's target size, not in the choice.
            if ($c.PSObject.Properties['size'] -and [string]$c.size) { $sizeOf[[string]$c.vmId] = [string]$c.size }
            # OLD-SKU-1C: the disk types, carried to the entry's policy.
            # HDD-OS-1: and Standard SSD for a Standard HDD OS disk.
            if ($c.PSObject.Properties['disks'] -and [string]$c.disks -in @('os', 'all', 'os-standard-ssd')) { $disksOf[[string]$c.vmId] = [string]$c.disks }
            # MANA-LINUX-KERNEL-1: this machine's own kernel choice, when it has one.
            if ($c.PSObject.Properties['kernel'] -and [string]$c.kernel -in @('stop', 'update')) { $kernelOf[[string]$c.vmId] = [string]$c.kernel }
            # REBUILD-PICKER-1: the method the person saved, held to the path below.
            if ($c.PSObject.Properties['method'] -and [string]$c.method) { $methodOf[[string]$c.vmId] = [string]$c.method }
        }
        # KERNEL-DEFAULT-EARLIER-1: the saved default is always stop
        # (target-choices), so only a machine's own choice updates its kernel.
        # Who chose it, and when - the record a decision carries. Whole
        # seconds, as Set-VmfOwnDecision writes it: ConvertFrom-Json reads the
        # saved time as a date, and a date written back with fractions does
        # not read back the same (PLANVER-2).
        $kernelBy = [string]$choices.savedBy.identity
        $savedAt = $choices.savedUtc
        # A time that cannot be read never stops a plan (review finding 12):
        # the record then carries the time the plan was made.
        $kernelUtc = try {
            if ($savedAt -is [datetime]) { $savedAt.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
            else { [datetime]::Parse([string]$savedAt, [System.Globalization.CultureInfo]::InvariantCulture,
                    [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal).ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
        }
        catch { (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'") }
    }

    # MACHINE-PICK-1: which machines this plan holds. A machine left out gets
    # no entry - so no target and no wave - and stays in the assessment the
    # migration carries, and in its report. $null is every machine: a
    # command-line plan with neither a list nor targets, as before.
    $machinesText = $null
    $chosenIds = $null
    if ($hasMachineChoice) {
        $machinesText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $assessmentDir -RelPath 'machine-choices.json')
        $machineChoice = $machinesText | ConvertFrom-Json -Depth 10
        # Bound to the scan that was reviewed, as the targets are.
        $scanNow = Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path $AssessmentPath)
        if ($machineChoice.assessmentHash -and [string]$machineChoice.assessmentHash -ne $scanNow) {
            throw ('The machines were chosen on a different scan of these machines. Choose the machines again ' +
                   'for this assessment, then plan.')
        }
        # And the targets to this list (PLANVER-2: the version of the stored
        # text). A machine added since has no target, and one taken out still
        # has one - the targets step shows the list as it is now.
        if ($choices -and [string]$choices.machinesVersion -ne (Get-VmfDocumentVersion -Text $machinesText)) {
            throw ('The machines were chosen again after the targets were saved. Save the targets again ' +
                   'for this assessment, then plan.')
        }
        $chosenIds = @{}
        foreach ($id in @($machineChoice.machines)) { $chosenIds[[string]$id] = $true }
    }

    $plannedVms = @($assessment.vms | Where-Object { $null -eq $chosenIds -or $chosenIds.ContainsKey([string]$_.vmId) })
    # REBUILD-REMOVE-PLAN-1: no machine waits for a choice any more. IDENTITY-LOSS-1
    # refused a plan while a machine whose start a rebuild would take its
    # system-assigned identity from had no saved choice.
    # A plan with no entry reads as no plan, and the wizard would wait for it
    # for ever. Refused before anything is written (review of MACHINE-PICK-1).
    if ($null -ne $chosenIds -and -not $plannedVms.Count) {
        throw ('No machine is chosen for this migration. Choose the machines, then their targets, then plan - ' +
               'open the assessment and select Plan a migration from this.')
    }

    # SKU catalogs for target validation + disk-arch classification: one per
    # subscription and region (ID-ADDRESS-1 part 3). A machine is planned on
    # the sizes ITS subscription is offered, never another's.
    $catalogs = Read-VmfMachineCatalogs -Machines @($plannedVms) -IdProperty 'vmId' -RunPath $OutPath

    # WAVE-1: a machine may carry many tags; the plan can name WHICH one means
    # "application" and which means "risk level", instead of being stuck with
    # whatever the scan assumed. Falls back to what the scan recorded.
    $tagValue = {
        param($vm, $key)
        if (-not $key -or -not $vm.tags) { return $null }
        $prop = $vm.tags.PSObject.Properties | Where-Object { $_.Name -ieq $key } | Select-Object -First 1
        if ($prop -and $prop.Value) { [string]$prop.Value } else { $null }
    }

    $prelim = foreach ($vm in $plannedVms) {
        # No ring from a tag. Grouping machines by a tag is an
        # option a customer picks; letting a tag decide how the product TREATS a
        # machine is not. (The ring that used to be assigned here is gone -
        # WAVE-2: no environment vocabulary exists in the contract at all.)
        $appFromTag = & $tagValue $vm $AppGroupTag
        $appGroup = if ($appFromTag) { $appFromTag }
                    elseif ($vm.PSObject.Properties['appGroup'] -and $vm.appGroup -and -not $AppGroupTag) { $vm.appGroup }
                    else { $vm.name }

        $regionCatalog = Get-VmfMachineCatalog -Catalogs $catalogs -VmId ([string]$vm.vmId) -Location ([string]$vm.location)
        if ($null -eq $regionCatalog) { $regionCatalog = @{} }
        # GEN-WAVE-1: one derivation (Resolve-VmfEntryTarget) for "what does
        # this machine become". The per-wave series change that shared it was
        # removed by WAVE-SERIES-GONE-1: the series belongs to the machine.
        $series = $TargetGeneration
        $choice = if ($choices) { $choiceOf[[string]$vm.vmId] }
                  else { [ordered]@{ option = $TargetGeneration; source = 'plan'; chosenBy = $null } }
        if ($choice) { $series = $choice.option }

        # REBUILD-REMOVE-PLAN-1: the method is a fact of the target (Preview),
        # never an input: the saved method is held to it below.
        $t = Resolve-VmfEntryTarget -Assessment $vm -CatalogBySize $regionCatalog `
            -TargetGeneration $series -ChosenSize $(if ($choice) { $sizeOf[[string]$vm.vmId] } else { $null })
        $mapping = $t.Mapping
        $targetDiskArch = $t.DiskArch
        $targetTempDisks = $t.TempDisks
        $nicCount = $t.NicCount
        $path = $t.Path
        $controller = $t.Controller
        if ($choices -and -not $choice -and $path -eq 'A') {
            # ADVISOR-1: targets were chosen, and none for a machine that could
            # have moved - somebody left it out. It is not moved, and the plan
            # says why. Every OTHER answer stands as the existing rule gives it
            # (REVIEW of part 2): a machine already on NVMe stays EXCLUDED, and
            # a blocked one keeps its real reason.
            $mapping = @{ Target = $null; Alternates = @(); Reason = 'No target was chosen for this machine, so it is not moved.' }
            $targetDiskArch = $null
            $targetTempDisks = $null
            $path = 'MANUAL'
        }
        # ADVISE-AN-1 (2026-10-12): the processor maker never changes
        # without the person choosing it. A plan with no saved targets (the
        # command line, one series for every machine) does not move a machine
        # to a size of another maker - the AMD v5 size of the one exception.
        # SIZEMAP-REMOVE-1: a size map a person wrote could name that size and
        # was let through; the size map is gone, so nothing is. A maker that
        # cannot be read is no change - unknown is never read as one.
        elseif (-not $choices -and $path -eq 'A' -and $mapping.Target -and
                ($makerTo = Get-VmfSizeProcessor -SizeName ([string]$mapping.Target)) -and
                ($makerFrom = Get-VmfSizeProcessor -SizeName ([string]$vm.sourceSize)) -and $makerTo -ne $makerFrom) {
            $mapping = @{ Target = $null; Alternates = @()
                Reason = "On $series, the size of this machine is $($mapping.Target), which changes the processor maker. A person chooses that on the targets step: choose its target there, then plan again." }
            $targetDiskArch = $null
            $targetTempDisks = $null
            $path = 'MANUAL'
        }
        # RETIRE-SCOPE-1 (reversing part of V3-RETIRE-1): from one day before
        # Microsoft retires the machine's size, Resolve-VmfEntryTarget above
        # gives it no target and the reason (outside the scope of this tool),
        # so it is not planned. Within the 12 months before, it is planned and
        # the notes give the date (Get-VmfPlanEntryNotes, below). No rollback
        # size is recorded any more.
        [pscustomobject]@{
            vm = $vm; appGroup = $appGroup
            mapping = $mapping; targetDiskArch = $targetDiskArch; path = $path; nicCount = $nicCount; controller = $controller
            targetTempDisks = $targetTempDisks
            series = $series; choice = $choice
            # TEMP-DISK-PREVIEW-1: the move is the in-place upgrade (Preview).
            previewApplied = [bool]($t.Preview -and $path -eq 'A')
            vmId = $vm.vmId
            resourceGroup = [string]$vm.resourceGroup
            availabilitySetId = [string]$vm.availabilitySetId
        }
    }

    # REBUILD-PICKER-1: each moved machine records the method of its move.
    # A person who saved one method is never planned on another: a saved
    # in-place upgrade that the rules now give as a Preview would depend on a
    # preview feature the person was never told about. Refused by name,
    # before anything is written.
    $methodMoved = @(foreach ($p in $prelim) {
            if (-not $p.choice -or $p.path -ne 'A') { continue }
            # TEMP-DISK-PREVIEW-1: a Preview move records preview - the plan
            # says that the move depends on the preview feature, and Checking
            # reads it before any change.
            $method = Get-VmfMoveMethod -Preview:([bool]$p.previewApplied)
            $saved = if ($methodOf.ContainsKey([string]$p.vmId)) { $methodOf[[string]$p.vmId] } else { '' }
            if ($saved -and $saved -ne $method) { [string]$p.vm.name }
            $p.choice = [ordered]@{ option = [string]$p.choice.option; source = [string]$p.choice.source; chosenBy = $p.choice.chosenBy; method = $method }
        })
    if ($methodMoved.Count) {
        throw ("The method saved for these machines is no longer the method of their move: $($methodMoved -join ', '). " +
               'Each one now moves by the in-place upgrade or by the in-place upgrade (Preview), and that is not what was saved. Choose the targets again for this assessment, then plan.')
    }
    $executable = @($prelim | Where-Object { $_.path -eq 'A' })
    $waves = Get-VmfWaveAssignments -Entries $executable -Strategy $WaveStrategy

    $entries = foreach ($p in $prelim) {
        $wave = if ($waves.ContainsKey($p.vmId)) { $waves[$p.vmId] } else { 'unscheduled' }
        $policyParams = @{}
        if ($CapacityGate) { $policyParams.CapacityGateOverride = [string]$CapacityGate }
        $policy = Get-VmfDefaultWavePolicy @policyParams
        # The plan RECORDS the generation it was built against, so a later
        # reader (and the acceptance screen) can see which one was chosen
        # rather than inferring it from the size names. ADVISOR-1: the
        # machine's own series, when targets were chosen per machine.
        $policy.targetGeneration = $p.series
        # AN-PLAN-1: a target that requires accelerated networking, on a machine
        # with it off, is turned on by accepting the wave's settings - one
        # approval, at plan time, not a stop in the middle of the move.
        $plannedAn = Get-VmfPlannedAcceleratedNetworking -Vm $p.vm -TargetSize ([string]$p.mapping.Target)
        if ($plannedAn -and $p.path -eq 'A') { $policy.acceleratedNetworking = $plannedAn }
        # OLD-SKU-1C: the person's disk choice, for a machine this plan moves.
        if ($disksOf.ContainsKey([string]$p.vmId) -and $p.path -eq 'A') { $policy.diskUpgrade = $disksOf[[string]$p.vmId] }
        # MANA-LINUX-KERNEL-1: "Update the kernel", chosen on the targets step -
        # this machine's own choice - for a Linux machine this plan moves to a
        # target that can give MANA. It is the
        # machine's OWN decision (WAVE-LEVER-OVERRIDE-1), so a wave save never
        # writes over it, and the wave's sign-off names the machine.
        $kernelDecision = $null
        if ($choices -and $p.path -eq 'A' -and $p.mapping.Target) {
            $kernelChoice = if ($kernelOf.ContainsKey([string]$p.vmId)) { $kernelOf[[string]$p.vmId] } else { 'stop' }
            # ADVISE-AN-1: the whole record, so the offer also asks the release
            # the VM agent reports (Test-VmfReleaseKnownUnlisted).
            $asEntry = [pscustomobject]@{ assessment = $p.vm
                target = [pscustomobject]@{ size = [string]$p.mapping.Target; controller = [string]$p.controller } }
            # Since 2026-10-12, a kernel update saved for a machine whose running
            # release Microsoft does not list is never planned - it cannot give
            # MANA. AN-MANA-DRIVER-RULE-1: such a machine is never planned on a
            # size that can give MANA either (Resolve-VmfEntryTarget,
            # no-mana-driver), so the note that said why the kernel was not
            # updated has nothing left to say.
            if ($kernelChoice -eq 'update' -and (Test-VmfKernelUpdateOfferedForEntry -PlanEntry $asEntry)) {
                $policy.onDriverBelowFloor = 'updateKernel'
                $kernelDecision = [ordered]@{ setting = 'onDriverBelowFloor'; by = $kernelBy; utc = $kernelUtc }
            }
        }
        # AN-MANA-DRIVER-RULE-1 (2026-11-06): no plan writes ensureOff.
        # ADVISE-AN-1 turned accelerated networking off on the Intel v7 size of
        # a Linux machine with no MANA driver (Get-VmfAnMakerPolicy). Such a
        # machine is now offered no size that can give MANA, and ensureOff left
        # the plan contract at v33.
        $entry = [ordered]@{
            # Derived: this was a literal, and the version gate one file over
            # reads Get-VmfPlanSchemaVersion. Two copies of a number that must
            # never disagree is how a plan comes to declare a version its own
            # reader would refuse.
            schemaVersion = Get-VmfPlanSchemaVersion
            vmId = $p.vm.vmId
            wave = $wave
            appGroup = $p.appGroup
            assessment = [ordered]@{
                classification = [string]$p.vm.classification
                gen = $p.vm.gen
                os = $p.vm.os
                osVersion = $p.vm.osVersion
                # ADVISE-AN-1: carried so the target rules give the same answer
                # on the plan entry (the wave editor's agreement check) as on the
                # assessment - the Linux release decides whether the AMD v5 size
                # is a choice. Additive: the assessment block is open-shaped.
                imagePublisher = $(if ($p.vm.PSObject.Properties['imagePublisher']) { [string]$p.vm.imagePublisher } else { '' })
                imageOffer = $(if ($p.vm.PSObject.Properties['imageOffer']) { [string]$p.vm.imageOffer } else { '' })
                runningOsName = $(if ($p.vm.PSObject.Properties['runningOsName']) { [string]$p.vm.runningOsName } else { '' })
                runningOsVersion = $(if ($p.vm.PSObject.Properties['runningOsVersion']) { [string]$p.vm.runningOsVersion } else { '' })
                sourceSize = $p.vm.sourceSize
                # ROLLBACK-CAPACITY-1 (plan-entry v35): whether Microsoft
                # restricts capacity growth for the series of the size a
                # rollback returns to - from data, so the sign-off of the
                # wave can say once that capacity is not guaranteed.
                sourceCapacityRestricted = Test-VmfSizeCapacityRestricted -SizeName ([string]$p.vm.sourceSize)
                sourceDiskArch = $p.vm.sourceDiskArch
                # SQL-TEMPDB-SIGNOFF-1 (plan-entry v37): the scan found SQL
                # Server on the machine (its warning sql-server-agree-downtime).
                # With sourceDiskArch and target.diskArch, the plan sign-off
                # names each SQL Server machine that moves to an NVMe temporary
                # disk or none (Test-VmfSqlTempdbRisk).
                sqlServerDetected = Test-VmfSqlServerFound -Vm $p.vm
                # TEMPPOOL-1: carried so the PAIR sits on one entry. Comparing
                # it with target.tempDisks is what tells an operator which
                # machines gain drives and which lose their temporary disk.
                sourceTempDisks = $p.vm.sourceTempDisks
                location = $p.vm.location
                blockers = @($p.vm.blockers)
                prepNeeded = @($p.vm.prepNeeded)
                platformManaged = [bool]$p.vm.platformManaged
                iacManaged = [bool]$p.vm.iacManaged
                # HDD-OS-1 (plan-entry v21): the OS disk's type as the scan
                # read it, so the export for pricing says it now and after.
                osDiskType = $(if ($p.vm.PSObject.Properties['osDiskType'] -and [string]$p.vm.osDiskType) { [string]$p.vm.osDiskType } else { $null })
                dataDiskCount = [int]$p.vm.dataDiskCount
                nicCount = [int]$p.nicCount
                # AN-PLAN-1: carried so a later series change can decide
                # accelerated networking the same way the plan did. Null when
                # the scan could not read it.
                acceleratedNicCount = $(if ($p.vm.PSObject.Properties['acceleratedNicCount']) { $p.vm.acceleratedNicCount } else { $null })
                primaryNicAccelerated = $(if ($p.vm.PSObject.Properties['primaryNicAccelerated']) { $p.vm.primaryNicAccelerated } else { $null })
                availabilitySetId = [string]$p.vm.availabilitySetId
                resourceGroup = [string]$p.vm.resourceGroup
                # IDENTITY-UX-1 / IDENTITY-3: the identity's kind, its account,
                # and what the assessment found it can reach - so the wave
                # editor, the acceptance and PRECHECK say the same thing.
                # Additive: the assessment block is open-shaped.
                identityType = $(if ($p.vm.PSObject.Properties['identityType']) { [string]$p.vm.identityType } else { '' })
                identityPrincipalId = $(if ($p.vm.PSObject.Properties['identityPrincipalId']) { [string]$p.vm.identityPrincipalId } else { '' })
                # REBUILD-REMOVE-PLAN-1 (plan-entry v29): rebuildLinks is no
                # longer written - no move rebuilds a machine. An entry an
                # earlier version wrote keeps it, and it still reads.
                # carried so waves can be composed by any tag the fleet uses
                tags = $(if ($p.vm.tags) { $p.vm.tags } else { @{} })
            }
            target = [ordered]@{
                size = $p.mapping.Target
                sizeAlternates = @($p.mapping.Alternates)
                diskArch = $p.targetDiskArch
                # TEMPPOOL-1. Null means the catalog could not size it - the UI
                # must say "cannot tell", never "none".
                tempDisks = $p.targetTempDisks
                # GEN-V5-1: from the series - v5 is SCSI.
                controller = $p.controller
                zone = $(if ($planZone = Get-VmfMachineZone -Machine $p.vm) { $planZone } else { $null })
                # ADVISOR-1: where the series came from - the default a machine
                # started on, a person's change, or the plan's one series.
                choice = $p.choice
                # RETIRE-SCOPE-1: no target.rollbackSize; it left the contract at v33.
            }
            path = $p.path
            policy = $policy
            # PLAN-NOTES-TARGET-1: one function for the notes, which a target
            # changed in the wave editor asks too (Set-VmfMachineTarget).
            planNotes = @(Get-VmfPlanEntryNotes -Mapping $p.mapping -Assessment $p.vm -Controller ([string]$p.controller) -Path ([string]$p.path))
        }
        $own = @($kernelDecision) | Where-Object { $_ }
        if ($own.Count) { $entry.decisions = @($own) }
        # CRG-MOVE-DEMAND-1 (plan-entry v30): the capacity reservation group the
        # scan found the machine in, when the record says. Test-VmfEntryReservable
        # reads it: a machine in a group this migration did not make gets no
        # place in the wave's reservation.
        Add-VmfPlanReservationGroup -Assessment $entry.assessment -Record $p.vm
        # WAVE-AN-NAMES-1: whether the move turns accelerated networking on,
        # worked out from the entry as written - its setting is final here -
        # so the wave settings name every machine it turns on for, not only
        # the ones whose size requires it.
        Set-VmfPlannedAnOutcome -PlanEntry $entry -Confirm:$false -WhatIf:$false
        # MANA-WIN-3: and, by the engine's own rule, whether the move can
        # download the MANA driver - the Run it step shows the note.
        Set-VmfManaDriverDownloadNote -PlanEntry $entry -Confirm:$false -WhatIf:$false
        $entry
    }

    $doc = [ordered]@{
        schemaVersion = 5
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        # WAVE-ORDER-1: the order the waves run in, kept by the plan itself.
        waveOrder     = @($entries | ForEach-Object { [string]$_['wave'] } |
                          Where-Object { $_ -and $_ -ne 'unscheduled' } | Select-Object -Unique)
        assessmentRunId = $assessment.runId
        waveSummary   = @($entries | Group-Object { $_['wave'] } | ForEach-Object { [ordered]@{ wave = $_.Name; count = $_.Count } })
        pathSummary   = @($entries | Group-Object { $_['path'] } | ForEach-Object { [ordered]@{ path = $_.Name; count = $_.Count } })
        entries       = @($entries)
    }
    # ASSESS-PAGE-1: planning turns an assessment into a MIGRATION, and the
    # migration records which assessment it came from. That is the provenance
    # the product has never had - a plan could not say what it was based on, or
    # whether that assessment had been reviewed.
    #
    # The assessment is COPIED in rather than referenced. A migration is a
    # record of a decision made against a particular snapshot of the estate; if
    # somebody re-runs the assessment next month, what this migration was
    # planned from must not change underneath it. The report and the dashboard
    # both read it from here.
    # ASSESS-PAGE-1: an assessment must be REVIEWED before a migration can be
    # planned from it - as in Azure Migrate, an assessment (a report) is
    # required before any migration.
    #
    # Enforced in the engine rather than the wizard, because a wizard-only gate
    # is bypassed by the API path - which is how the app actually runs.
    #
    # The check is on the ASSESSMENT the plan is being built from, which is why
    # it reads beside the assessment file rather than in the migration.
    # NOT Split-Path -Parent: on a blob path it silently returns
    # a backslash-separated path the store no longer recognises, which
    # is how this gate broke planning on the REAL store while every unit test
    # passed. See Split-VmfStorePath.
    $assessmentDir = Split-VmfStorePath -Path $AssessmentPath
    $approval = Read-VmfStoreJson -RunPath $assessmentDir -RelPath 'approval.json' -Depth 6
    if (-not $approval) {
        throw ("Assessment '$([string]$assessment.runId)' has not been reviewed. Somebody has to read what it " +
               'found and approve it before a migration can be planned from it - open it on the Assessments page.')
    }

    $migrationId = Split-Path $OutPath -Leaf
    # A name already carrying a plan is refused, for the same reason: replacing
    # a plan under a migration that may already have moved machines would leave
    # its state documents describing work that plan never asked for.
    if (Test-VmfStoreItem -RunPath $OutPath -RelPath 'plan.json') {
        throw ("'$migrationId' already has a plan. Plan again from the assessment to get a new " +
               'migration rather than replacing this one.')
    }
    # PROJECT-1: a migration belongs to the project it is created in. Warned
    # about rather than blocked when that differs from the assessment's - a plan
    # written somewhere else is unusual but not wrong, and refusing it would be
    # a new gate nobody asked for.
    $migrationProject = Resolve-VmfRunProject -RunPath $OutPath
    $assessmentProject = Resolve-VmfRunProject -RunPath $assessmentDir
    if ($assessmentProject -and $migrationProject -ne $assessmentProject) {
        Write-Warning ("This migration is being created in project " +
            "'$(if ($migrationProject) { $migrationProject } else { 'none' })' from an assessment in " +
            "'$assessmentProject'. They will not appear together.")
    }
    Initialize-VmfRun -RunPath $OutPath -RunId $migrationId -Kind 'migration' `
        -FromAssessment ([string]$assessment.runId) -Project $migrationProject | Out-Null
    if (-not (Test-VmfStoreItem -RunPath $OutPath -RelPath 'assessment.json')) {
        Write-VmfStoreJson -RunPath $OutPath -RelPath 'assessment.json' -Document $assessment -Depth 24
    }
    # ADVISOR-1: the targets it was planned from travel with it, as the
    # assessment does - copied as the stored TEXT, so nothing in it is
    # re-read and re-written differently.
    if ($choicesText -and -not (Test-VmfStoreItem -RunPath $OutPath -RelPath 'target-choices.json')) {
        Write-VmfStoreText -RunPath $OutPath -RelPath 'target-choices.json' -Content $choicesText
    }
    # MACHINE-PICK-1: and the machines chosen, the same way.
    if ($machinesText -and -not (Test-VmfStoreItem -RunPath $OutPath -RelPath 'machine-choices.json')) {
        Write-VmfStoreText -RunPath $OutPath -RelPath 'machine-choices.json' -Content $machinesText
    }
    # WAVE-MIX-2: and the options they were chosen from. Changing one machine's
    # series later offers only what these call supported - the targets step's
    # answer, never a second one.
    if ($choicesText -and (Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'target-advice.json') -and
        -not (Test-VmfStoreItem -RunPath $OutPath -RelPath 'target-advice.json')) {
        Write-VmfStoreText -RunPath $OutPath -RelPath 'target-advice.json' `
            -Content (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $assessmentDir -RelPath 'target-advice.json'))
    }
    # WAVEGEN-HOSTED-1: the size catalog this plan was built with, for the
    # parts of the product that cannot read Azure's (the service). WAVE-MIX-2:
    # with the sizes the machines are ON, which decide a v5 'd' size.
    # ID-ADDRESS-1 part 3: still one copy per region. It holds capabilities
    # only (no restrictions), so it keeps every size any subscription there
    # was offered, once.
    $byRegion = [ordered]@{}
    foreach ($key in @($catalogs.Keys | Sort-Object)) {
        $location = ($key -split '\|', 2)[1]
        if (-not $byRegion.Contains($location)) { $byRegion[$location] = [ordered]@{} }
        foreach ($name in @($catalogs[$key].Keys | Sort-Object)) {
            if (-not $byRegion[$location].Contains($name)) { $byRegion[$location][$name] = $catalogs[$key][$name] }
        }
    }
    foreach ($location in @($byRegion.Keys)) {
        $sources = @($assessment.vms | Where-Object { ([string]$_.location).ToLowerInvariant() -eq $location } | ForEach-Object { [string]$_.sourceSize })
        Save-VmfCatalogSnapshot -RunPath $OutPath -Location $location -Skus @($byRegion[$location].Values) -AlsoKeep $sources
    }

    Write-VmfStoreJson -RunPath $OutPath -RelPath 'plan.json' -Document $doc
    $planPath = Get-VmfStoreItemHandle -RunPath $OutPath -RelPath 'plan.json'
    # STEP-LOG-4: written after the plan is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $OutPath -Step 'plan' -Outcome ok `
        -Detail (($doc.pathSummary | ForEach-Object { "$($_.path)=$($_.count)" }) -join ' ')
    # APPROVE-GROUP-1: the summary of the whole migration, for the list on the
    # Migrations page. Never throws.
    Update-VmfRunSummary -RunPath $OutPath -Reason 'planSaved' | Out-Null

    [pscustomobject]@{
        PlanPath = $planPath
        Total    = @($entries).Count
        Paths    = $doc.pathSummary
        Waves    = $doc.waveSummary
    }
}
