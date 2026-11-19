# GEN-WAVE-1: deciding a machine's TARGET, in one place.
#
# The planner worked this out inline: map the size, classify the target's disk
# architecture, count its temporary disks, then choose the path. That was fine
# while the generation was decided once for the whole plan.
#
# It is not fine now. The contract has always said `policy.targetGeneration` is
# "chosen per wave" - and the wave editor REFUSED to change it, correctly,
# because it could not recompute sizes. Accepting it would have written a plan
# whose policy said v7 and whose sizes still said v6.
#
# So the derivation moves here, and both callers use it: New-VmfPlan when it
# builds the plan. (Set-VmfWaveGeneration used it too, until WAVE-SERIES-GONE-1.)
# Two copies of this would be two answers to "what does this machine become",
# and the second one only runs when somebody is already changing something.

function Resolve-VmfEntryTarget {
    <#
    .SYNOPSIS
        Everything about a machine's target that follows from its source size
        and the chosen generation.
    .PARAMETER Assessment
        The assessed machine: sourceSize, classification, location, nicCount,
        dataDiskCount and whatever Get-VmfPathSelection reads.
    .PARAMETER CatalogBySize
        The region's SKU catalog, keyed by size name. Empty is allowed and
        means "could not verify" rather than "does not exist".
    .OUTPUTS
        @{ Mapping = <Get-VmfTargetSize result>; DiskArch = <string|null>
           TempDisks = <int|null>; Path = 'A'|'MANUAL'|'EXCLUDED'; Preview = <bool> }
        REBUILD-REMOVE-PLAN-1: never Path B.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Assessment,
        [Parameter()][hashtable]$CatalogBySize = @{},
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # OLD-SKU-1B: the v5 size a person chose on the targets step, from
        # the machine's size choices. Empty: the best choice.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ChosenSize
        # REBUILD-REMOVE-PLAN-1: no method parameter. TEMP-DISK-PREVIEW-1 took
        # the method a person saved, because a Preview was a choice beside a
        # rebuild. With the rebuild removed, the Preview is the one move of its
        # shape, and the method is a fact of the target (Preview, below).
    )

    $vm = $Assessment
    $nicCount = if ($vm.PSObject.Properties['nicCount'] -and [int]$vm.nicCount -gt 0) { [int]$vm.nicCount } else { 1 }
    $dataDiskCount = if ($vm.PSObject.Properties['dataDiskCount']) { [int]$vm.dataDiskCount } else { 0 }
    # AN-ONE-NIC-1: the interfaces with accelerated networking after the move.
    # Every size this machine may take is held to it, as to the interfaces.
    $anAfter = Get-VmfAcceleratedNicsAfterMove -Assessment $vm

    # AN-MANA-DRIVER-RULE-1 (2026-11-06): an Intel machine is never
    # offered an AMD size. ADVISE-AN-1 offered one Intel Linux machine with no
    # MANA driver its AMD v5 size as a choice; that exception is gone. An AMD
    # size named for an Intel machine is refused below (chosen-size-gone),
    # never planned as its Intel size in silence: a machine with no size
    # choices would otherwise take its own size.
    $chosenTwin = $null
    $amdForIntel = $ChosenSize -and (Get-VmfSizeProcessor -SizeName $ChosenSize) -eq 'AMD' -and (Get-VmfSizeProcessor -SizeName ([string]$vm.sourceSize)) -eq 'Intel'
    if ($amdForIntel) {
        $chosenTwin = $ChosenSize
        $ChosenSize = $null
    }

    # GEN-V5-1 C3: judged against THIS series. The plan's copy of the
    # assessment records the generation as 'gen'.
    $judged = Resolve-VmfEntryClassification -Assessment $vm -TargetGeneration $TargetGeneration
    $hyperV = if ($vm.PSObject.Properties['gen'] -and $vm.gen) { [string]$vm.gen }
              elseif ($vm.PSObject.Properties['hyperVGeneration']) { [string]$vm.hyperVGeneration }

    $mapping = Get-VmfTargetSize -SourceSize $vm.sourceSize -CatalogBySize $CatalogBySize `
        -RequiredNics $nicCount -RequiredDataDisks $dataDiskCount -TargetGeneration $TargetGeneration -AcceleratedNicsAfter $anAfter `
        -HyperVGeneration $hyperV

    # OLD-SKU-1B: a Generation 1 machine, or one on an old size, chooses its
    # family and size by shape - on v5, and for a Generation 2 machine on v6
    # and v7 too (OLD-SKU-V6-1: an old size has no v6 or v7 size of its own
    # name at all). An old size's name twin is often smaller
    # (D4_v2 has 8 vCPUs, D4_v5 has 4) and a D v1 name has none, so either
    # got no target. The best choice fills that gap; a chosen one is planned
    # only while it is still offered - a choice that is gone is refused with
    # the reason, never swapped for another in silence.
    $sizeChoices = @()
    # BSV2-TARGET-1: whether this machine is offered its Bsv2 size on this
    # option - 'offered'; 'no-fit', no Bsv2 size in the region keeps its vCPUs
    # and memory and passes every gate; 'disk-encryption-preview', the move to
    # it changes the kind of temporary disk, which an encrypted machine may not
    # have (REBUILD-REMOVE-PLAN-1) - or $null where the question does not
    # arise (not a B v1 machine, or not v5).
    $burstableTarget = $null
    # OLD-SIZE-NOVERSION-1: and so it is told that, never what the name rule
    # said. A name with no version (Standard_D2, D v1) gives that rule no size
    # to try, and it answered not-in-region with nothing tried; a v4 size on a
    # v7 option with no v7 in the region was told to go back to v6, which it
    # cannot take either. A family the name rule calls not in the region keeps
    # that reason, unless it is an old size the product sizes by shape (DS v1, F,
    # Fs, B v1): that family is in the migration path, on v5.
    # V5-SUCCESSOR-1: and so is a machine whose size Microsoft does not list on
    # this series (NotListed): v5 takes it, which is the answer it can act on.
    if ($TargetGeneration -ne 'v5' -and $hyperV -eq 'V1' -and -not $mapping.Target -and
        ([string]$mapping.Code -eq 'not-in-region' -or $mapping.NotListed -eq $true -or
         ([string]$mapping.Code -eq 'family-not-in-region' -and (Test-VmfShapeChoiceSource -SourceSize ([string]$vm.sourceSize))))) {
        $mapping = @{ Target = $null; Alternates = @(); Code = 'gen1-no-size'
            Reason = ("This machine is Generation 1, and $TargetGeneration takes Generation 2 machines only. " +
                      'v5 takes Generation 1 machines. Choose it in the Choose each target step.') }
    }
    # v6 and v7 take Generation 2 only: a Generation 1 machine is not sized
    # for them at all, rather than left to a gate a catalog may not answer.
    if (($TargetGeneration -eq 'v5' -or $hyperV -ne 'V1') -and (Test-VmfShapeChoiceSource -Generation $hyperV -SourceSize ([string]$vm.sourceSize))) {
        $sizeChoices = @(Get-VmfShapeSizeChoices -SourceSize ([string]$vm.sourceSize) -CatalogBySize $CatalogBySize `
                -RequiredNics $nicCount -RequiredDataDisks $dataDiskCount -HyperVGeneration $hyperV -TargetGeneration $TargetGeneration -AcceleratedNicsAfter $anAfter)
        $burstableRow = Get-VmfBurstableTargetFor -SourceSize ([string]$vm.sourceSize) -TargetGeneration $TargetGeneration
        if ($burstableRow) {
            $burst = @($sizeChoices | Where-Object { [string]$_.family -eq [string]$burstableRow.series }) | Select-Object -First 1
            $burstableTarget = if ($burst) { 'offered' } else { 'no-fit' }
            # V5-ADE-1: an encrypted machine does not change its kind of
            # temporary disk. Bsv2 has none, so a Windows B v1 machine (which
            # has one) changes it to reach it - a rebuild until
            # REBUILD-REMOVE-PLAN-1, the in-place upgrade (Preview) since, and
            # refused to Azure Disk Encryption either way (2026-11-07:
            # out of scope for 1.0). As the best choice it would close the
            # whole option, where the D or E d size keeps the move in place -
            # so it is not offered to that machine, and the reason says why.
            if ($burst -and @($vm.blockers) -contains 'disk-encryption-present') {
                $burstMb = $null
                $burstCap = @(@($CatalogBySize[[string]$burst.size].Capabilities) | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' }) | Select-Object -First 1
                if ($burstCap) { $burstMb = [int64]$burstCap.Value }
                $burstArch = Get-VmfDiskArchitecture -SizeName ([string]$burst.size) -MaxResourceVolumeMB $burstMb
                if ($judged.Classification -notin @('Excluded', 'Blocked') -and (Test-VmfTempDiskKindChanges -Assessment $vm -TargetDiskArch $burstArch)) {
                    $burstableTarget = 'disk-encryption-preview'
                    $sizeChoices = @(Get-VmfShapeSizeChoices -SourceSize ([string]$vm.sourceSize) -CatalogBySize $CatalogBySize `
                            -RequiredNics $nicCount -RequiredDataDisks $dataDiskCount -HyperVGeneration $hyperV -TargetGeneration $TargetGeneration -NoBurstable -AcceleratedNicsAfter $anAfter)
                }
            }
        }
        # Planned as a named size, so every gate applies, and the reason says
        # where the size came from.
        $byShape = { param($size, [string]$Why)
            Get-VmfTargetSize -SourceSize $vm.sourceSize -Size $size -Why $Why -CatalogBySize $CatalogBySize `
                -RequiredNics $nicCount -RequiredDataDisks $dataDiskCount -TargetGeneration $TargetGeneration -HyperVGeneration $hyperV -AcceleratedNicsAfter $anAfter
        }
        # A name twin the rules already gave (Gen1 D2as_v4 -> D2as_v5) stays
        # the default and the best choice: it is what this machine is planned
        # on when nobody chooses, so the page must show it among the choices.
        $twin = [string]$mapping.Target
        $listed = @($sizeChoices | Where-Object { [string]$_.size -eq $twin })
        if ($twin -and $listed.Count) {
            foreach ($c in $sizeChoices) { $c.best = ([string]$c.size -eq $twin) }
        }
        elseif ($twin -and $twin -match '^Standard_([DE])\d+(-\d+)?') {
            $letter = $Matches[1].ToUpperInvariant(); $constrained = [bool]$Matches[2]
            # vcpus is the size's own count, activeVcpus what it may use (a
            # constrained twin, E8-4as_v5: 8 and 4) - Get-VmfSkuShape gives the second.
            $entryOf = $CatalogBySize[$twin]
            $all = @(@($entryOf.Capabilities) | Where-Object { $_.Name -eq 'vCPUs' } | Select-Object -First 1)
            $twinShape = Get-VmfSkuShape -SkuEntry $entryOf
            $ownVcpus = 0
            if ($all.Count -and [int]::TryParse([string]$all[0].Value, [ref]$ownVcpus) -and $null -ne $twinShape.Vcpus -and $null -ne $twinShape.MemoryGB) {
                foreach ($c in $sizeChoices) { $c.best = $false }
                $sizeChoices = @([ordered]@{ size = $twin; family = $letter; variant = $(if ($constrained) { 'constrained' } else { 'default' })
                        vcpus = $ownVcpus; activeVcpus = [int]$twinShape.Vcpus; memoryGB = $twinShape.MemoryGB; best = $true }) + $sizeChoices
            }
        }
        # The rules' own answer is always the machine's size, listed or not
        # (a catalog that did not give its shape lists nothing).
        if ($ChosenSize -and $ChosenSize -ne $twin) {
            $mapping = if (@($sizeChoices | ForEach-Object { $_.size }) -contains $ChosenSize) { & $byShape $ChosenSize "chosen-size (chosen for this machine on the targets step)" }
                       else { @{ Target = $null; Alternates = @(); Code = 'chosen-size-gone'
                                 Reason = "The size chosen for this machine, $ChosenSize, is no longer one of its $TargetGeneration choices. Choose its target again." } }
        }
        elseif (-not $mapping.Target -and -not @($sizeChoices).Count -and
                ([string]$mapping.Code -in @('family-not-in-region', 'not-in-region') -or $mapping.NotListed -eq $true)) {
            # Say what was looked for. The name rule's answer ("no size in this
            # family", or a size that cannot exist) is not what was checked.
            # SIZE-LISTING-D-1: and "Microsoft lists no size of this name"
            # (NotListed) is the same kind of answer: a Dv2 machine is never
            # sized by name, so D11_v6 is not a size it tried.
            $shape = Get-VmfSkuShape -SkuEntry $(if ($CatalogBySize.ContainsKey([string]$vm.sourceSize)) { $CatalogBySize[[string]$vm.sourceSize] } else { $null })
            if ($null -ne $shape.Vcpus -and $null -ne $shape.MemoryGB) {
                # AMD-SHAPE-1: the sizes were looked for on the processor of the
                # machine only (Get-VmfShapeSizeChoices), so the reason names it.
                # An AMD machine has a code of its own: the screen says that no
                # AMD size fits, which is true where an Intel size would.
                $maker = Get-VmfSizeProcessor -SizeName ([string]$vm.sourceSize)
                # Microsoft has no AMD Dl size on v5, so it is not named there.
                $kind = if ($maker -eq 'AMD' -and $TargetGeneration -eq 'v5') { 'AMD D or E' } else { "$maker Dl, D or E" }
                $mapping = @{ Target = $null; Alternates = @(); Code = $(if ($maker -eq 'AMD') { 'no-amd-shape-fit' } else { 'no-shape-fit' })
                    Reason = ("Azure offers no $TargetGeneration $kind size in this region with at least $($shape.Vcpus) vCPUs and $($shape.MemoryGB) GiB that this machine can take." +
                              $(if ($maker -eq 'AMD') { ' The size keeps the processor of the machine, so the product does not offer an Intel size.' } else { '' })) }
                # OLD-FAM-4: say WHICH limit, when the shape fits and the
                # machine's disks or interfaces do not. Found by running every
                # old size against the real catalog: D14_v2, DS5_v2 and F16 take
                # 64 data disks, and no D, Dl or E v5 size the product chooses by
                # shape takes more than 32 (the isolated E104i sizes take 64, and
                # are not shape choices) - which read as "no size of this shape".
                # DISKS-32-1: a machine with more than 32 is now outside the
                # scope of this tool (below), so this names a size whose limit is
                # under the count of a machine with 32 or fewer.
                $fitsWith = { param([int]$Nics, [int]$Disks, $An = $anAfter)
                    @(Get-VmfShapeSizeChoices -SourceSize ([string]$vm.sourceSize) -CatalogBySize $CatalogBySize `
                        -RequiredNics $Nics -RequiredDataDisks $Disks -HyperVGeneration $hyperV -TargetGeneration $TargetGeneration -AcceleratedNicsAfter $An) }
                # AN-ONE-NIC-1: the sizes of its shape fit everything but the
                # interfaces with accelerated networking after the move. Said
                # first, and no bigger size is named (row 31, option 2).
                $forOne = @(& $fitsWith $nicCount $dataDiskCount 1)
                $bestForOne = @($forOne | Where-Object { $_.best }) | Select-Object -First 1
                if ($nicCount -gt 1 -and $null -ne $anAfter -and [int]$anAfter -gt 1 -and $bestForOne) {
                    $mapping = @{ Target = $null; Alternates = @(); Code = 'one-accelerated-nic'
                        Reason = (Get-VmfOneAcceleratedNicReason -AcceleratedNicsAfter $anAfter -Sizes @("$($bestForOne.size) has $($bestForOne.vcpus) vCPUs")) }
                }
                elseif ($dataDiskCount -gt 0 -and @(& $fitsWith $nicCount 0).Count -gt 0) {
                    $mapping = @{ Target = $null; Alternates = @(); Code = 'too-few-data-disks'
                        Reason = "Azure offers $TargetGeneration $kind sizes in this region with at least $($shape.Vcpus) vCPUs and $($shape.MemoryGB) GiB, but none of the sizes the product chooses from takes $dataDiskCount data disks." }
                }
                elseif ($nicCount -gt 1 -and @(& $fitsWith 1 $dataDiskCount).Count -gt 0) {
                    $mapping = @{ Target = $null; Alternates = @(); Code = 'too-few-nics'
                        Reason = "Azure offers $TargetGeneration $kind sizes in this region with at least $($shape.Vcpus) vCPUs and $($shape.MemoryGB) GiB, but none of the sizes the product chooses from takes $nicCount network interfaces." }
                }
            }
            else {
                # OLD-SIZE-NOVERSION-1: the catalog does not give the shape, so
                # no size can be chosen by it. The name rule's answer - a region
                # with no size, or a family with none - is not what stopped it.
                $mapping = @{ Target = $null; Alternates = @(); Code = 'shape-unknown'
                    Reason = ("This region's catalog does not give the vCPUs and memory of $([string]$vm.sourceSize). " +
                              'The product chooses the target of this machine by its vCPUs and memory, so it cannot choose one.') }
            }
        }
        elseif (-not $mapping.Target) {
            $best = @($sizeChoices | Where-Object { $_.best }) | Select-Object -First 1
            if ($best) {
                # BSV2-TARGET-1: said as what it is - the default of a B v1 machine.
                $why = if ($burstableRow -and [string]$best.family -eq [string]$burstableRow.series) {
                           "shape-choice (the $($best.family) size for the vCPUs and the memory of this machine, the default target of a B v1 machine)" }
                       else { "shape-choice (the best $TargetGeneration size for the vCPUs and the memory of this machine)" }
                $mapping = & $byShape $best.size $why
            }
        }
    }
    elseif ($mapping.Target -and (Get-VmfSizeReplacement -SizeName ([string]$vm.sourceSize))) {
        # V3-TEMPDISK-1: a v3 machine goes to the d size first, and may choose
        # the size without a temporary disk instead - the two sizes Microsoft's
        # table names for it. DAV4-TEMPDISK-1: an AMD v4 machine the same, on
        # the AMD sizes its row names. The same size choices, save and plan as a machine
        # chosen by shape, so a choice is held to every gate the same way.
        # V4-NAMES-1 and V5-NAMES-1: a machine on an Intel v4 or v5 size with
        # no s (Dv4, Ddv4, Ev4, Edv4, Dv5, Ddv5, Ev5, Edv5) has a row too, and one
        # size to try, so it gets no choice here - and a chosen size that is
        # not its own target is refused, as for any machine with a row.
        $sizeChoices = @(Get-VmfReplacementSizeChoices -SourceSize ([string]$vm.sourceSize) -Mapping $mapping -CatalogBySize $CatalogBySize `
                -RequiredNics $nicCount -RequiredDataDisks $dataDiskCount -HyperVGeneration $hyperV -TargetGeneration $TargetGeneration -AcceleratedNicsAfter $anAfter)
        if ($ChosenSize -and $ChosenSize -ne [string]$mapping.Target) {
            if (@($sizeChoices | ForEach-Object { $_.size }) -contains $ChosenSize) {
                $mapping = Get-VmfTargetSize -SourceSize $vm.sourceSize -Size $ChosenSize -Why 'chosen-size (chosen for this machine on the targets step)' -CatalogBySize $CatalogBySize `
                    -RequiredNics $nicCount -RequiredDataDisks $dataDiskCount -TargetGeneration $TargetGeneration -HyperVGeneration $hyperV -AcceleratedNicsAfter $anAfter
            }
            else {
                $mapping = @{ Target = $null; Alternates = @(); Code = 'chosen-size-gone'
                    Reason = "The size chosen for this machine, $ChosenSize, is no longer one of its $TargetGeneration choices. Choose its target again." }
            }
        }
    }

    if ($chosenTwin) {
        $mapping = @{ Target = $null; Alternates = @(); Code = 'chosen-size-gone'
            Reason = "The size chosen for this machine, $chosenTwin, is no longer one of its $TargetGeneration choices. Choose its target again." }
    }
    # AN-MANA-DRIVER-RULE-1 (2026-11-06): a size that can give MANA -
    # every v6 and v7 size, Intel and AMD, Intel v5 and Bsv2
    # (Test-VmfTargetNeedsManaDriver) - is not offered to a machine whose VM
    # agent reports a Linux release with no MANA driver possible
    # (Test-VmfReleaseKnownUnlisted: Microsoft does not list it, and no normal
    # update within its major reaches a release it does). There accelerated
    # networking is always on, and the machine would run on the synthetic
    # interface. It replaces DRIFT-11-OTHER-OPTIONS-1, which asked only of the
    # sizes that REQUIRE accelerated networking, and left v7 and Bsv2 to turn
    # it off. Whether the machine uses accelerated networking today does not
    # matter. So an Intel machine is not moved, and an AMD machine keeps its
    # AMD v5 size. The reason names the release to upgrade to. The advice, the
    # plan and the wave editor all ask here.
    if ($mapping.Target -and (Test-VmfTargetNeedsManaDriver -SizeName ([string]$mapping.Target)) -and (Test-VmfReleaseKnownUnlisted -Vm $vm)) {
        $mapping = @{ Target = $null; Alternates = @(); Code = 'no-mana-driver'
            Reason = (Get-VmfNoManaDriverReason -Vm $vm -Size ([string]$mapping.Target)) }
        $sizeChoices = @()
    }
    # TARGET-CAPABILITY-PRECHECK-1 (2026-11-14): a size that does not
    # support encryption at host, or Ultra Disks in the machine's zone, when
    # the scan found the machine uses it, is not offered - or when the catalog
    # does not say it does, which is never a yes. Azure refuses the resize
    # otherwise, in Moving, after the stop. Each size choice comes through
    # here with its own size, so a choice without the feature is not offered
    # either. A record with no field (a plan entry's copy) asks nothing:
    # Checking asks again from the machine itself.
    if ($mapping.Target) {
        $featureZone = Get-VmfMachineZone -Machine $vm
        $featureSku = if ($CatalogBySize.ContainsKey([string]$mapping.Target)) { $CatalogBySize[[string]$mapping.Target] } else { $null }
        $featureGaps = @(Get-VmfTargetFeatureGaps -EncryptionAtHost ([bool]($vm.encryptionAtHost -eq $true)) -UltraSsdEnabled ([bool]($vm.ultraSsdEnabled -eq $true)) `
                -SkuEntry $featureSku -Zone $featureZone -Location ([string]$vm.location))
        $featureOffer = Get-VmfTargetFeatureOffer -Gaps $featureGaps -Size ([string]$mapping.Target) -Zone $featureZone -Location ([string]$vm.location)
        if ($featureOffer) {
            $mapping = @{ Target = $null; Alternates = @(); Code = $featureOffer.Code; Reason = $featureOffer.Reason }
            $sizeChoices = @()
        }
    }

    $diskArch = $null
    $tempDisks = $null
    if ($mapping.Target) {
        $maxMb = $null
        $targetSku = $null
        if ($CatalogBySize.ContainsKey($mapping.Target)) {
            $targetSku = $CatalogBySize[$mapping.Target]
            $cap = @($targetSku.Capabilities) | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' } | Select-Object -First 1
            if ($cap) { $maxMb = [int64]$cap.Value }
        }
        $diskArch = Get-VmfDiskArchitecture -SizeName $mapping.Target -MaxResourceVolumeMB $maxMb
        # TEMPPOOL-1: null means the catalog could not size it. The UI must say
        # "cannot tell", never "none".
        $tempDisks = Get-VmfTempDiskCount -SkuEntry $targetSku -SizeName $mapping.Target
    }

    # A machine with no target is MANUAL - unless it was never going to move,
    # in which case its own classification already says so.
    $path = if (-not $mapping.Target -and ($judged.Classification -notin @('Excluded', 'Blocked') -or $mapping.Code -eq 'chosen-size-gone')) { 'MANUAL' }
            else { Get-VmfPathSelection -Assessment $vm -TargetDiskArch $diskArch -TargetGeneration $TargetGeneration -Classification $judged.Classification }
    # REBUILD-REMOVE-PLAN-1 (2026-11-07): the move of a Windows machine
    # that changes its kind of temporary disk - a rebuild until then - is the
    # in-place upgrade (Preview) where its shape was measured (Path A from
    # Get-VmfPathSelection), and no move at all where it was not (MANUAL). It
    # is asked only of a machine the series moves: not one Excluded, Blocked,
    # or already there, and not one with no target.
    $blockers = @($judged.Blockers)
    $classification = $judged.Classification
    $kindChanges = [bool]($mapping.Target -and $path -in @('A', 'MANUAL') -and $judged.Classification -notin @('Excluded', 'Blocked') -and
        (Test-VmfTempDiskKindChanges -Assessment $vm -TargetDiskArch $diskArch))

    # V5-ADE-1: a move keeps Azure Disk Encryption only when the kind of
    # temporary disk stays. A rebuild made a new machine around the encrypted
    # disks without the extension that unlocks them; the in-place upgrade
    # (Preview) was never measured with it, and the owner keeps it refused for
    # 1.0 (2026-11-07). So a series whose move changes the kind is closed to a
    # machine the scan found encrypted - the targets step does not offer it,
    # and a plan does not move it. The engine's check stays: it also covers
    # encryption on a data disk only, which the scan cannot see.
    if ($kindChanges -and @($vm.blockers) -contains 'disk-encryption-present') {
        $blockers += 'disk-encryption-preview'
        $classification = 'Blocked'
        $path = 'MANUAL'
        # No target, and the reason in words: a plan records a machine it does
        # not move with its reason in planNotes, and a page must not draw an
        # arrow to a size the machine is not going to.
        $mapping = @{ Target = $null; Alternates = @(); Code = 'disk-encryption-preview'
            Reason = ("This machine uses Azure Disk Encryption, and its move to $TargetGeneration changes the kind of temporary disk, which is the in-place upgrade (Preview). " +
                      'The product does not move an encrypted machine that way, so it does not move it.') }
        $diskArch = $null
        $tempDisks = $null
        $burstableTarget = $null
        $kindChanges = $false
    }
    elseif ($kindChanges -and $path -eq 'MANUAL') {
        # A shape nobody measured: no target, and why (Get-VmfNoInPlaceMove).
        $none = Get-VmfNoInPlaceMove -Assessment $vm -TargetDiskArch $diskArch -TargetGeneration $TargetGeneration
        $mapping = @{ Target = $null; Alternates = @(); Code = $none.Code; Reason = $none.Reason }
        $diskArch = $null
        $tempDisks = $null
        $kindChanges = $false
    }

    # GPU-SCOPE-1: a family the product does not move (OLD-FAM-3, GPU-SCOPE-1)
    # is outside its scope on every series, asked HERE from the size name, the
    # way RETIRE-SCOPE-1 asks about a retired size below. An assessment made
    # before GPU-SCOPE-1 has no gpu-size blocker, and a Generation 1 GPU
    # machine was then given a D or E v5 size by its vCPUs and memory, which
    # has no GPU. The advice, the plan and the wave editor all come through
    # here. An excluded machine keeps its own answer.
    $familyScope = Get-VmfUnsupportedFamilyCode -SizeName ([string]$vm.sourceSize)
    if ($familyScope -and $classification -ne 'Excluded') {
        if (@($blockers) -notcontains $familyScope) { $blockers += $familyScope }
        $classification = 'Blocked'
        $path = 'MANUAL'
        $mapping = @{ Target = $null; Alternates = @(); Code = $familyScope
            Reason = (Get-VmfFamilyScopeDetail -Size ([string]$vm.sourceSize)) }
        $diskArch = $null
        $tempDisks = $null
        $sizeChoices = @()
        $burstableTarget = $null
    }

    # DISKS-32-1: a machine with more than 32 data disks is outside the scope
    # of the product on every series (a scope decision, 2026-10-05). Asked HERE
    # from the count on every call, as the family is above: an assessment made
    # before this change has no too-many-data-disks blocker, and a machine with
    # 64 was then planned onto a v6 or v7 size that takes 64. An excluded
    # machine keeps its own answer. A family out of scope above keeps ITS
    # answer (review): PRECHECK and the wave editor ask the family first, so
    # all three give one reason.
    $diskScope = Get-VmfDataDiskScopeDetail -Count $dataDiskCount
    if ($diskScope -and $classification -ne 'Excluded' -and -not $familyScope) {
        if (@($blockers) -notcontains 'too-many-data-disks') { $blockers += 'too-many-data-disks' }
        $classification = 'Blocked'
        $path = 'MANUAL'
        $mapping = @{ Target = $null; Alternates = @(); Code = 'too-many-data-disks'; Reason = $diskScope }
        $diskArch = $null
        $tempDisks = $null
        $sizeChoices = @()
        $burstableTarget = $null
    }

    # RETIRE-SCOPE-1 (2026-10-04): from one day before Microsoft retires
    # the machine's size, the machine is outside the scope of this tool on
    # every series. Asked HERE, at the moment of asking, not only by the scan:
    # an assessment made before the margin has no size-retired blocker, and
    # the target advice, the plan and the wave editor all come through this
    # function, so none of them can offer what the others refuse. The reason
    # is in words, because a plan records a machine it does not move with its
    # reason in planNotes. An excluded machine keeps its own answer.
    $retiredScope = Get-VmfRetiredScopeDetail -Size ([string]$vm.sourceSize)
    if (($retiredScope -or @($blockers) -contains 'size-retired') -and $classification -ne 'Excluded') {
        if (@($blockers) -notcontains 'size-retired') { $blockers += 'size-retired' }
        $classification = 'Blocked'
        $path = 'MANUAL'
        $mapping = @{ Target = $null; Alternates = @(); Code = 'size-retired'
            Reason = $(if ($retiredScope) { $retiredScope } else { "Microsoft retires $([string]$vm.sourceSize). A machine on a retired size is outside the scope of this tool." }) }
        $diskArch = $null
        $tempDisks = $null
        $sizeChoices = @()
        $burstableTarget = $null
    }

    @{
        Mapping   = $mapping
        DiskArch  = $diskArch
        TempDisks = $tempDisks
        Path      = $path
        NicCount  = $nicCount
        # GEN-V5-1: what the series makes of this machine, and its controller.
        Classification = $classification
        Blockers  = $blockers
        # BSV2-TARGET-1 (review): judged with the target size, so a v5 move
        # that takes the temporary disk away says the page file moves.
        Prep      = (Resolve-VmfEntryClassification -Assessment $vm -TargetGeneration $TargetGeneration -TargetDiskArch $diskArch).Prep
        Controller = Get-VmfGenerationController -Generation $TargetGeneration
        # OLD-SKU-1B: the sizes this machine may choose on this series - by shape,
        # or (V3-TEMPDISK-1) with or without a temporary disk; empty for others.
        SizeChoices = @($sizeChoices)
        # BSV2-TARGET-1: offered, no-fit, disk-encryption-preview, or $null.
        BurstableTarget = $burstableTarget
        # TEMP-DISK-PREVIEW-1 / REBUILD-REMOVE-PLAN-1: the move is the in-place
        # upgrade (Preview), which needs the preview feature
        # VMTempDiskResizePreview on the subscription - only for a machine
        # still moved: a refusal for Azure Disk Encryption and a scope rule
        # above leave no Path A and no target, so no Preview. The plan records
        # the method preview, and Checking reads the feature before any change.
        Preview = [bool]($kindChanges -and $path -eq 'A' -and $mapping.Target)
    }
}

function Test-VmfPlannedTargetAgrees {
    <#
    .SYNOPSIS
        WAVE-MIX-2: do the rules in use now give back the target this planned
        machine has - its size and its path?
    .DESCRIPTION
        OLD-SKU-1B: a machine may be on a size a person chose by shape
        (E8-4ds_v5 rather than the best choice, D8ds_v5), on any series. The rules give that
        size back only when asked for it, so the planned size is passed as the
        chosen size. A size no longer offered comes back refused, and so does
        not agree.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)][hashtable]$CatalogBySize,
        [Parameter(Mandatory)][string]$Current
    )
    $chosen = [string]$Entry.target.size
    # REBUILD-REMOVE-PLAN-1: the method is a fact of the target now, so it is
    # not passed. An entry an earlier version planned on Path B gets Path A
    # (the Preview) back, and does not agree: it is planned again.
    $again = Resolve-VmfEntryTarget -Assessment $Entry.assessment -CatalogBySize $CatalogBySize -TargetGeneration $Current -ChosenSize $chosen
    ([string]$again.Mapping.Target -eq [string]$Entry.target.size) -and ([string]$again.Path -eq [string]$Entry.path)
}
