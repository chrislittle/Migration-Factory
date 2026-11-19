# ADVISOR-1: the target options for each machine, before the waves.
#
# Microsoft's order is assess, then choose each machine's target, then group
# the machines into waves. This is the middle step. For every machine it lists
# each size series - v5, v6 and v7 - with the facts about that option, and
# whether this product supports it. A Generation 1 machine gets the same three:
# v5 takes it, and v6 and v7 need Generation 2. The product has no route from
# Generation 1 to Generation 2 (GEN1-UPGRADE-1, GEN1-ROUTE-GONE-1). It also names the option the machine STARTS on under
# each of the migration's two defaults, named after Microsoft's lifecycle
# stages: Current (v6) and Extended (v5). A person then accepts or changes
# each machine's target.
#
# FACTS ONLY. Nothing here judges an option better or worse; it states what
# the option is. Every fact comes from a function the planner or the engine
# already uses - Resolve-VmfEntryTarget for the size, the path and the
# blockers, the target-families data for the lifecycle stage and accelerated
# networking - so the advice and the plan cannot give two answers.
#
# The document carries codes, never sentences. The screen puts them in words.
#
# PURE: no Azure call and no store read. New-VmfTargetAdvice reads the catalog
# and writes the document.

function Get-VmfLifecycleChange {
    <#
    .SYNOPSIS
        Does a move from one size to another change Microsoft's lifecycle
        stage? 'up', 'same', 'down' or 'unknown'.
    .DESCRIPTION
        End of Life, then Extended, then Current. A v4 to v5 move is 'same':
        both are Extended, and it must never be shown as a move to a newer
        stage. A size the lifecycle table does not cover gives 'unknown'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$FromSize,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ToSize,
        [Parameter()][AllowNull()]$Families
    )
    $rank = @{ 'End of Life' = 0; 'Extended' = 1; 'Current' = 2 }
    $from = Get-VmfSizeLifecycleStage -SizeName $FromSize -Families $Families
    $to = Get-VmfSizeLifecycleStage -SizeName $ToSize -Families $Families
    if (-not $from -or -not $to -or -not $rank.ContainsKey($from.Stage) -or -not $rank.ContainsKey($to.Stage)) { return 'unknown' }
    $delta = $rank[$to.Stage] - $rank[$from.Stage]
    if ($delta -gt 0) { 'up' } elseif ($delta -lt 0) { 'down' } else { 'same' }
}

function Get-VmfAdviceStage {
    # The stage of one size, as the document holds it: the stage and whether
    # Microsoft states it or it follows from Microsoft's definitions.
    param([AllowNull()][AllowEmptyString()][string]$SizeName, $Families)
    $s = Get-VmfSizeLifecycleStage -SizeName $SizeName -Families $Families
    if (-not $s) { return $null }
    [ordered]@{ stage = $s.Stage; basis = $s.Basis }
}

function Get-VmfAdviceOption {
    <#
    .SYNOPSIS
        One size series for one machine: whether it is supported and the facts
        about it.
    .PARAMETER RegionCatalog
        The machine's region, size name -> SKU. $null means the region's sizes
        could not be read, and then NOTHING is supported: unknown is not a yes.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter(Mandatory)][ValidateSet('v5', 'v6', 'v7')][string]$Series,
        [Parameter()][AllowNull()][hashtable]$RegionCatalog,
        [Parameter()][AllowNull()]$Families,
        # OLD-SKU-1B: the facts of one of the option's size choices.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ChosenSize
    )

    $option = [ordered]@{
        option = $Series; supported = $false; notSupported = @()
        targetSize = $null; sizeUnverified = $false; path = $null
        # SIZE-FALLTHROUGH-NOTE-1 (v29): the sizes the default transform tried
        # before targetSize, and the gate that refused each (Get-VmfTargetSize
        # NotTaken) - most often the d size, so the temporary disk goes. Empty
        # when the first size is the target, or the size was named.
        sizesNotTaken = @()
        blockers = @(); prep = @()
        move = $(if ((Get-VmfGenerationController -Generation $Series) -eq 'NVMe') { 'nvme-conversion' } else { 'scsi-resize' })
        # TEMP-DISK-PREVIEW-1 (v24), REBUILD-REMOVE-PLAN-1 (v28): the move is
        # the in-place upgrade (Preview), which needs the preview feature
        # VMTempDiskResizePreview on the subscription (Resolve-VmfEntryTarget
        # Preview). False for every other move. No option is a rebuild: the
        # field rebuild is gone.
        preview = $false
        tempDisksFrom = $(if ($Vm.PSObject.Properties['sourceTempDisks'] -and $null -ne $Vm.sourceTempDisks) { [int]$Vm.sourceTempDisks } else { $null })
        tempDisksTo = $null
        targetStage = $null; stageChange = 'unknown'
        acceleratedNetworking = [ordered]@{ required = $null; mayUseMana = $null; turnsOn = $null; keptOn = $null; keptOnWhy = $null }
        stops = @()
        # OLD-SKU-1B: the family and size choices of a Generation 1 machine or
        # one on an old size (on v6 and v7 too since OLD-SKU-V6-1); empty for
        # every other option.
        sizeChoices = @()
        # OLD-SKU-1C: the target size takes Premium SSD disks. Null: the
        # catalog does not say, which is never read as a yes.
        premiumDisks = $null
        # OLD-FAM-4: the machine is on a burstable size (CPU credits) and the
        # target is not - a change in how it uses its CPU, and in its cost.
        # Null when there is no target.
        burstableEnds = $null
        # BSV2-TARGET-1: the machine is on a burstable size and so is the
        # target (Bsv2) - it keeps its CPU credits. Null when there is no target.
        burstableKept = $null
        # BSV2-TARGET-1: whether a B v1 machine is offered its Bsv2 size on this
        # option - offered, no-fit, disk-encryption-rebuild - or null where the
        # question does not arise. The screen says why it is not.
        burstableTarget = $null
        # ADVISE-AN-1: the target size has another processor maker than the
        # machine. The one exception that offered one (an AMD v5 size for an
        # Intel machine) is gone (AN-MANA-DRIVER-RULE-1), so a supported
        # option is always false. Null when there is no target.
        processorChange = $null
        # ...and the maker of the target size (Get-VmfSizeProcessor), for the words.
        processor = $null
        # REBUILD-REMOVE-PLAN-1: no identity field. IDENTITY-LOSS-1 said what a
        # rebuild did to the system-assigned identity; an in-place upgrade,
        # with or without the preview feature, keeps it.
    }

    if ($null -eq $RegionCatalog) {
        $option.notSupported = @('region-not-read')
        return $option
    }

    $t = Resolve-VmfEntryTarget -Assessment $Vm -CatalogBySize $RegionCatalog -TargetGeneration $Series -ChosenSize $ChosenSize
    $size = [string]$t.Mapping.Target
    $option.blockers = @($t.Blockers)
    $option.prep = @($t.Prep)
    $option.path = [string]$t.Path
    $option.preview = [bool]$t.Preview
    $option.sizeChoices = @($t.SizeChoices)
    $option.burstableTarget = $t.BurstableTarget
    $sourceGeneration = Get-VmfSizeGeneration -SizeName ([string]$Vm.sourceSize)

    $why = @(
        if ($t.Classification -eq 'Excluded') { 'excluded' }
        elseif (@($t.Blockers).Count) { @($t.Blockers) }
        elseif ($Series -eq 'v5' -and $sourceGeneration -in @('v6', 'v7')) { 'source-is-newer' }
        elseif (-not $size) { [string]$t.Mapping.Code }
        elseif ($t.Path -eq 'EXCLUDED') {
            if ((Get-VmfGenerationController -Generation $Series) -eq 'NVMe') { 'already-on-nvme' } else { 'already-on-series' }
        }
        elseif ($t.Path -ne 'A') { 'no-path' }
    )
    $option.notSupported = @($why | Where-Object { $_ })

    if ($size) {
        $option.targetSize = $size
        $option.sizesNotTaken = @(@($t.Mapping.NotTaken) | Where-Object { $_ } | ForEach-Object { [ordered]@{ size = [string]$_.size; why = [string]$_.why } })
        $option.processor = Get-VmfSizeProcessor -SizeName $size
        $option.processorChange = ($option.processor -ne (Get-VmfSizeProcessor -SizeName ([string]$Vm.sourceSize)))
        $option.premiumDisks = Test-VmfDiskPremiumCapable -SkuEntry $(if ($RegionCatalog.ContainsKey($size)) { $RegionCatalog[$size] } else { $null })
        $option.sizeUnverified = ([string]$t.Mapping.Code -eq 'mapped-unverified')
        $option.tempDisksTo = $t.TempDisks
        $option.move = [string](Get-VmfMoveKind -PlanEntry ([pscustomobject]@{ target = [pscustomobject]@{ size = $size; controller = $t.Controller } }))
        $option.targetStage = Get-VmfAdviceStage -SizeName $size -Families $Families
        $option.stageChange = Get-VmfLifecycleChange -FromSize ([string]$Vm.sourceSize) -ToSize $size -Families $Families
        $fromBurstable = Test-VmfBurstableSize -SizeName ([string]$Vm.sourceSize) -Families $Families
        $toBurstable = Test-VmfBurstableSize -SizeName $size -Families $Families
        $option.burstableEnds = $fromBurstable -and -not $toBurstable
        $option.burstableKept = $fromBurstable -and $toBurstable

        # Accelerated networking, by the TARGET SIZE. A scan that did not
        # record the machine's accelerated interfaces gives unknown, never a no.
        $required = Test-VmfTargetRequiresAcceleratedNetworking -SizeName $size -Families $Families
        # The engine decides this from the PRIMARY interface
        # (Resolve-VmfAcceleratedNetworkingForMove). AN-PRIMARY-1: the scan
        # records the primary's setting by the engine's rule, so that decides.
        # An assessment written before it has only the count, which settles one
        # interface, or none on at all - not several with some on, where the
        # primary may be the one that is off. That stays unknown, never a no
        # (REVIEW-1; Test-VmfUsesAcceleratedNetworking reads it).
        # BSV2-NOTES-1: and the move turns it on wherever the engine does - for
        # every move but a SCSI reversion, not only where the size requires it
        # (Get-VmfAnTurnsOn). A Bsv2 move turned it on and was shown Off -> Off.
        $release = Get-VmfLinuxRelease -Vm $Vm
        $turnsOn = Get-VmfAnTurnsOn -Vm $Vm -TargetSize $size -Move ([string]$option.move) -Required $required
        $mayUseMana = Test-VmfTargetMayUseMana -SizeName $size -Families $Families
        # ADVISE-AN-1: whether the accelerated networking the machine uses
        # today keeps working on this size - the adapter the size can give, and
        # whether the operating system drives it. Unknown stays unknown.
        $kept = Get-VmfAnKeptOn -Os ([string]$Vm.os) -UsesAn (Test-VmfUsesAcceleratedNetworking -Vm $Vm) -Move ([string]$option.move) `
            -MayUseMana $mayUseMana -Listing (Get-VmfManaReleaseListing -Release $release) -ReleaseSource $(if ($release) { [string]$release.source } else { '' })
        $option.acceleratedNetworking = [ordered]@{
            required = $required
            mayUseMana = $mayUseMana
            turnsOn = $turnsOn
            keptOn = $kept.KeptOn
            keptOnWhy = $kept.Why
        }
        # A stop a person can clear: the engine parks the machine untouched and
        # an approver accepts it. A fact to show, not a reason to refuse.
        # BSV2-NOTES-1: only where the size REQUIRES it - a size that does not
        # turns it on with no stop.
        if ($turnsOn -eq $true -and $required -eq $true) { $option.stops = @('acceleratedNetworkingRequired') }
    }

    $option.supported = (@($option.notSupported).Count -eq 0)

    # OLD-SKU-1B: each size choice carries the facts that follow from ITS
    # size - accelerated networking, the temporary disk, the Preview - worked
    # out the same way as the option's own. A choice this machine cannot take
    # (a change of the kind of temporary disk, refused for Azure Disk
    # Encryption or never measured) is not offered.
    if (-not $ChosenSize -and @($option.sizeChoices).Count) {
        $option.sizeChoices = @(foreach ($c in @($option.sizeChoices)) {
                $sub = Get-VmfAdviceOption -Vm $Vm -Series $Series -RegionCatalog $RegionCatalog -Families $Families -ChosenSize ([string]$c.size)
                if (-not $sub.supported -or [string]$sub.targetSize -ne [string]$c.size) { continue }
                $item = [ordered]@{}
                foreach ($k in @($c.Keys)) { $item[$k] = $c[$k] }
                # ADVISE-AN-1: the processor maker of the size, by the product's one
                # rule (Get-VmfSizeProcessor, target-families.json processorLetters),
                # so a list that mixes makers can say which is which.
                $item.processor = Get-VmfSizeProcessor -SizeName ([string]$c.size)
                # BSV2-TARGET-1: and its lifecycle stage and CPU credits. A Bsv2
                # choice (Current, keeps the credits) and a Dl, D or E choice
                # (Extended, ends them) differ in both on one option - OLD-FAM-4
                # left them on the option while every choice had the same. And its
                # prep: a choice with no temporary disk moves the page file (review).
                # TEMP-DISK-PREVIEW-1: and whether its move is the Preview.
                foreach ($k in 'path', 'preview', 'tempDisksTo', 'sizeUnverified', 'acceleratedNetworking', 'stops', 'premiumDisks',
                    'targetStage', 'stageChange', 'burstableEnds', 'burstableKept', 'prep') { $item[$k] = $sub[$k] }
                $item
            })
        # V3-TEMPDISK-1: the two sizes of a v3 machine (and of an AMD v4
        # machine, DAV4-TEMPDISK-1; an Intel v4 machine with a row has one
        # size and no choice, V4-NAMES-1) are a choice only while
        # both stay. An encrypted Windows machine on v5 keeps the d size (in
        # place) and loses the other (it changes the kind of temporary disk),
        # and one size is no choice -
        # the same rule Get-VmfReplacementSizeChoices applies before this.
        if ((Get-VmfSizeReplacement -SizeName ([string]$Vm.sourceSize) -Families $Families) -and
            (@($option.sizeChoices).Count -lt 2 -or -not @($option.sizeChoices | Where-Object { $_.best }).Count)) {
            $option.sizeChoices = @()
        }
    }
    $option
}

function Get-VmfTargetAdvice {
    <#
    .SYNOPSIS
        The target options for every machine in an assessment (ADVISOR-1).
    .PARAMETER Assessment
        The assessment document (assessment.json).
    .PARAMETER CatalogByLocation
        location -> (size name -> SKU), for every region that was read.
    .PARAMETER RegionsNotRead
        Regions whose sizes could not be read. Their machines get no
        supported option and no starting target.
    .OUTPUTS
        An ordered dictionary matching schemas/target-advice.schema.json,
        without assessmentHash (the caller binds it).
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Assessment,
        [Parameter()][hashtable]$CatalogByLocation = @{},
        [Parameter()][string[]]$RegionsNotRead = @()
    )

    $families = Get-VmfTargetFamilyData
    $locations = @($Assessment.vms | ForEach-Object { [string]$_.location } | Sort-Object -Unique)
    $regions = foreach ($loc in $locations) {
        [ordered]@{ location = $loc; read = ($CatalogByLocation.ContainsKey($loc) -and $RegionsNotRead -notcontains $loc) }
    }
    $readSet = @($regions | Where-Object { $_.read } | ForEach-Object { $_.location })

    $machines = foreach ($vm in @($Assessment.vms)) {
        $loc = [string]$vm.location
        $catalog = if ($readSet -contains $loc) { $CatalogByLocation[$loc] } else { $null }

        $options = [System.Collections.Generic.List[object]]::new()
        foreach ($s in 'v5', 'v6', 'v7') {
            $options.Add((Get-VmfAdviceOption -Vm $vm -Series $s -RegionCatalog $catalog -Families $families))
        }
        $supported = @($options | Where-Object { $_.supported } | ForEach-Object { $_.option })
        $first = { param([string[]]$order) foreach ($o in $order) { if ($supported -contains $o) { return $o } }; $null }
        # BSV2-TARGET-1 (2026-10-05): Bsv2 is the DEFAULT target of a B
        # v1 machine, under both defaults - it is Current, and it keeps the
        # credits. The option whose target is a Bsv2 size (v5) comes first;
        # with none, the defaults are as before.
        $burstableStart = @($options | Where-Object { $_.supported -and $_.targetSize -and (Get-VmfBurstableTarget -SizeName ([string]$_.targetSize) -Families $families) } |
                ForEach-Object { [string]$_.option }) | Select-Object -First 1
        $currentOrder = @('v6', 'v7', 'v5')
        $extendedOrder = @('v5', 'v6', 'v7')
        # ADVISE-AN-1 (2026-10-10): accelerated networking first. A
        # machine that uses it today does not start on an option where it
        # certainly stops working, when another supported option certainly
        # keeps it (Select-VmfAnKeepingStart). Unknown changes nothing.
        $startCurrent = Select-VmfAnKeepingStart -Options $options -Order $currentOrder `
            -Start $(if ($burstableStart) { $burstableStart } else { & $first $currentOrder })
        $startExtended = Select-VmfAnKeepingStart -Options $options -Order $extendedOrder `
            -Start $(if ($burstableStart) { $burstableStart } else { & $first $extendedOrder })
        $release = Get-VmfLinuxRelease -Vm $vm
        # AN-MANA-DRIVER-RULE-1 (2026-11-06): ADVISE-AN-1 gave an Intel
        # Linux machine with no MANA driver no start, and a choice between its
        # Intel v7 size with accelerated networking off and an AMD v5 size
        # (the decide reason processor-or-an). Both are gone: such a machine
        # is offered no size that can give MANA, and never an AMD size, so it
        # has no target, and the screen says which release to upgrade to.
        # REBUILD-REMOVE-PLAN-1 (2026-11-07): and the two start rules
        # that moved a machine off a rebuild are gone with the rebuild -
        # IDENTITY-LOSS-1's (Select-VmfIdentityKeepingStart, the decide reason
        # identity) and REBUILD-PICKER-1's (Select-VmfInPlaceStart). The start
        # is the first supported option in the order of the default. Where that
        # is the in-place upgrade (Preview), the targets step says which
        # subscription needs the preview feature and how to register it.

        [ordered]@{
            vmId = [string]$vm.vmId
            name = [string]$vm.name
            os = [string]$vm.os
            osVersion = [string]$vm.osVersion
            gen = $(if ($vm.gen) { [string]$vm.gen } else { $null })
            location = $loc
            sourceSize = [string]$vm.sourceSize
            # ADVISE-AN-1: the processor maker of the size now (Get-VmfSizeProcessor).
            processor = (Get-VmfSizeProcessor -SizeName ([string]$vm.sourceSize))
            # The Details panel shows each option as before -> after.
            diskController = $(if ($vm.diskController) { [string]$vm.diskController } else { $null })
            # HDD-OS-1: the type of the OS disk, as the scan read it from the
            # disk (Standard_LRS is Standard HDD). The targets step offers
            # Standard SSD for it only when it is Standard HDD. Null when the
            # scan could not read it, or is older than assessment v5.
            osDiskType = $(if ($vm.PSObject.Properties['osDiskType'] -and [string]$vm.osDiskType) { [string]$vm.osDiskType } else { $null })
            sourceStage = (Get-VmfAdviceStage -SizeName ([string]$vm.sourceSize) -Families $families)
            # IDENTITY-LOSS-1: the identity the scan read, in Azure's own words.
            # Null when the scan did not read it, which is never read as no
            # identity. REBUILD-REMOVE-PLAN-1: the account (object ID) is no
            # longer carried - nothing deletes the identity it named.
            identityType = $(if ($vm.PSObject.Properties['identityType'] -and [string]$vm.identityType) { [string]$vm.identityType } else { $null })
            acceleratedNicCount = $(if ($vm.PSObject.Properties['acceleratedNicCount'] -and $null -ne $vm.acceleratedNicCount) { [int]$vm.acceleratedNicCount } else { $null })
            # ADVISE-AN-1: the Linux release the accelerated networking answers
            # were made from, and where it was read. Null for a machine that is
            # not Linux.
            linuxRelease = $(if ([string]$vm.os -match '^(?i)linux$') {
                    [ordered]@{
                        distroId = $(if ($release) { [string]$release.distroId } else { $null })
                        version = $(if ($release) { [string]$release.version } else { $null })
                        source = $(if ($release) { [string]$release.source } else { $null })
                        mana = (Get-VmfManaReleaseListing -Release $release)
                        # AN-MANA-DRIVER-RULE-1: the release to upgrade to, for a
                        # machine with no MANA driver possible - null otherwise,
                        # and null when Microsoft lists no later release of it.
                        manaUpgrade = $(if (Test-VmfReleaseKnownUnlisted -Vm $vm) { Get-VmfManaUpgradeRelease -Release $release } else { $null })
                    }
                } else { $null })
            # RHEL-EUS-TARGET-NOTE-1 (v31): the RHEL image on the EUS
            # repositories the machine was made from, when its kernel for MANA
            # needs a later minor release (Get-VmfEusImage). What the scan
            # read, never the repositories it uses now; it changes no offer.
            eusImage = (Get-VmfEusImage -Vm $vm)
            options = @($options)
            # The two defaults are Microsoft's lifecycle stages. Current is v6
            # (v7 is Current too); Extended is v5. Each falls back to the other
            # supported options, and to nothing. v7 is a choice a person makes
            # for any machine where it is supported - every option is judged on
            # its own.
            start = [ordered]@{ current = $startCurrent; extended = $startExtended }
        }
    }

    [ordered]@{
        schemaVersion = (Get-VmfTargetAdviceSchemaVersion)
        assessmentId = [string]$Assessment.runId
        assessmentHash = $null
        generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        regions = @($regions)
        machines = @($machines)
    }
}

# The version of target-advice.json, in one place: the engine writes it and the
# save refuses any other. v2 (2026-09-26) named the two defaults after
# Microsoft's lifecycle stages, current and extended. v4 (V5-ADE-1) added the
# reason disk-encryption-rebuild. v5 (OLD-SKU-1B) added each option's
# sizeChoices. v6 (OLD-SKU-V6-1) gives them on v6 and v7 too. v7 (OLD-SKU-1C)
# says whether each size takes Premium SSD disks. v8 (OLD-FAM-1) adds the Dl
# family to the size choices, and B v1, F, Fs and Fsv2 as sources. v9 (OLD-FAM-3)
# adds the reasons for the families the product does not move. v10 (V3-TEMPDISK-1)
# gives a v3 machine the d size on v6 and v7, and the size without a temporary
# disk as a size choice on v5, v6 and v7. v11 (DAV4-TEMPDISK-1) does the same
# for a machine on an AMD v4 size (Dav4, Dasv4, Eav4, Easv4), on AMD.
# v12 (OLD-FAM-4) adds each option's burstableEnds and the reason size-retired.
# v13 (GPU-SCOPE-1) adds the reason gpu-size: a v12 file can offer a Generation 1
# GPU machine a D or E v5 size, so it is refused and made again.
# v14 (AMD-SHAPE-1) keeps the processor maker of a machine sized by shape, and
# adds the reason no-amd-shape-fit: a v13 file can offer an AMD machine an
# Intel size, so it is refused and made again.
# v15 (BSV2-TARGET-1) offers a B v1 machine its Bsv2 size on v5, as the best
# choice and where it starts under both defaults (sizeChoices family Bsv2),
# adds burstableKept and burstableTarget to each option, and gives each size
# choice its own targetStage, stageChange, burstableEnds, burstableKept and prep: a
# v14 file offers no Bsv2, so it is refused and made again.
# v16 (DISKS-32-1) adds the reason too-many-data-disks: a machine with more than
# 32 data disks is outside the scope of this tool. A v15 file can offer such a
# machine a v6 or v7 size that takes 64, so it is refused and made again.
# v17 (AN-ONE-NIC-1) adds the reason one-accelerated-nic: a 2-vCPU size is not
# offered to a machine with accelerated networking on more than one network
# interface after the move. A v16 file offers it, and the move fails after the
# stop, so it is refused and made again.
# v18 (ADVISE-AN-1) adds acceleratedNetworking.keptOn and keptOnWhy to each
# option and size choice, and linuxRelease to each machine, and a machine that
# uses accelerated networking today starts on an option that keeps it where one
# certainly does: a v17 file can start such a machine where it stops working,
# so it is refused and made again.
# v20 (HDD-OS-1) adds osDiskType to each machine: the targets step offers
# Standard SSD for an OS disk that is Standard HDD. A v19 file has no type, so
# it could offer nothing, and it is refused and made again.
# v21 (IDENTITY-LOSS-1) adds identity to each option and size choice, and
# identityType and identityPrincipalId to each machine; a machine with a
# system-assigned identity starts on a target that keeps it where one does,
# and decide may give the reason identity. A v20 file can start such a machine
# where a rebuild deletes its identity, so it is refused and made again.
# v23 (REBUILD-PICKER-1) starts every machine whose move would rebuild it on an
# option that upgrades it in place, when one loses nothing more. A v22 file can
# start such a machine on the rebuild, so it is refused and made again.
# v24 (TEMP-DISK-PREVIEW-1) adds preview to each option and size choice: the
# rebuild of a Windows machine with a SCSI temporary disk is offered as an
# in-place upgrade that needs the preview feature VMTempDiskResizePreview. A
# v23 file has no preview, so the save could not accept one; it is refused and
# made again.
# v26 (DRIFT-11-OTHER-OPTIONS-1) adds the reason an-required-no-mana: a v6 or
# Intel v5 size is not offered to a machine whose VM agent reports a Linux
# release Microsoft does not list for MANA. A v25 file offers it, so it is
# refused and made again.
# v27 (AN-MANA-DRIVER-RULE-1) refuses every size that can give MANA - v7 and
# Bsv2 as well as v6 and Intel v5 - to a machine whose VM agent reports a Linux
# release with no MANA driver possible, with the reason no-mana-driver in place
# of an-required-no-mana; adds linuxRelease.manaUpgrade, the release to
# upgrade to; and drops the decide reason processor-or-an. A v26 file offers
# Intel v7 with accelerated networking off, or an AMD size to an Intel
# machine, so it is refused and made again.
# v28 (REBUILD-REMOVE-PLAN-1) removes the rebuild around the same disks: no
# option and no size choice has path B, and the fields rebuild and identity,
# the machine fields identityPrincipalId and decide, and the reason
# disk-encryption-rebuild are gone. preview says the move is the in-place
# upgrade (Preview), now also for Generation 1. It adds the reasons
# disk-encryption-preview, generation-unknown and temp-disk-change-not-measured.
# A v27 file offers rebuilds, so it is refused and made again.
# v31 (RHEL-EUS-TARGET-NOTE-1) adds eusImage to each machine: the targets step
# says that a Red Hat machine was made from an image on the EUS repositories,
# beside Update the kernel. A v30 file has no eusImage, so it is refused and
# made again.
# v32 (IMAGE-SCRIPT-MATCH-1) adds the reason linux-release-not-on-nvme-list:
# a Linux machine whose release is not on Microsoft's list of Linux images
# that support NVMe has no v6 or v7 option and keeps v5. A v31 file offers
# v6 or v7 to it, so it is refused and made again.
# v33 (TARGET-CAPABILITY-PRECHECK-1) adds the reasons no-encryption-at-host and
# no-ultra-disk: a size that does not support encryption at host, or Ultra
# Disks in the machine's zone, is not offered to a machine that uses it. A v32
# file offers it, and Azure refuses the resize after the stop, so it is refused
# and made again.
function Get-VmfTargetAdviceSchemaVersion { 33 }

# The version of target-choices.json (schemas/target-choices.schema.json) that
# Set-VmfTargetChoice writes and New-VmfPlan reads. v9 (TARGETS-NO-LIST-1):
# every file names the list of machines it was saved against
# (machinesVersion), the kernel default, and on each choice its size, disks,
# method (in-place or preview) and kernel, null for none. New-VmfPlan refuses
# a file of any other version: nothing is public before 1.0, so no store
# holds one an earlier version wrote.
function Get-VmfTargetChoicesSchemaVersion { 9 }
