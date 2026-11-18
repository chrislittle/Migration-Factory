# Planner internals: size mapping, path selection, wave policy defaults, wave batching.
# Pure logic - Azure facts arrive via the assessment; SKU catalogs are passed in.

function Get-VmfSizeFamilyPrefix {
    <#
    .SYNOPSIS
        The family letters of a size name: Standard_D2ds_v4 -> 'D',
        Standard_E8-4ds_v5 -> 'E', Standard_NC6s_v3 -> 'NC'.
    .DESCRIPTION
        Microsoft's v6/v7 migration guidance names the target VM
        families - the D and E series for v6, plus Fasv7 for v7 AMD - and the
        sources are their legacy v2-v5 sizes. Nothing in this code said so.

        This asks the REGION'S CATALOG rather than carrying that list, which is
        why it got Fasv7 right while a comment three files away had it wrong. The default transform builds
        a candidate by swapping the version suffix on ANY family, so an
        F-series, L-series, M-series or GPU machine in the resource group
        produced a candidate like Standard_NC6s_v6 - a size that does not
        exist and never will - which was then dropped by the catalog lookup
        with the reason "no candidate available in region".

        That reads as a regional availability problem an operator might wait
        out or fix by choosing another region. The truth is that the family is
        not part of the v6/v7 programme at all, which is a different fact and
        a different action.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SizeName)
    if ($SizeName -match '^Standard_([A-Za-z]+?)\d') { return $Matches[1].ToUpperInvariant() }
    ''
}

function Test-VmfFamilyHasGeneration {
    <#
    .SYNOPSIS
        Does Azure offer ANY size of this family at the target generation?
    .DESCRIPTION
        Answered from the region's own SKU catalog rather than from a list of
        families written down here - the catalog is what Azure actually offers,
        it is already fetched, and a hard-coded family list would be one more
        copy of a fact that can change.

        Asked about the MIGRATION PATH, not about one generation: a family is
        in scope if it has v6 sizes OR v7 sizes. Asking only about the wave's
        chosen generation gets the wrong answer in a real case - a v7 wave in a
        region where v7 has not landed yet would be told the D family is not
        part of the programme, which is false and would send an operator
        looking in entirely the wrong place. "This family has no v6/v7 at all"
        and "v7 is not in this region yet" are different facts; the second one
        already has its own refusal, which names the v6 size that would work.

        Returns $null when there is no catalog to ask (unit tests, and any
        caller that has not fetched one). Unknown is not a no: an absent
        catalog must never turn into "this family is out of scope".
    .OUTPUTS
        $true / $false / $null (could not tell)
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter()][hashtable]$CatalogBySize = @{},
        # GEN-V5-1: a v5 wave's path is v5 as well as v6 and v7.
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6'
    )
    if ($CatalogBySize.Count -eq 0) { return $null }
    $family = Get-VmfSizeFamilyPrefix -SizeName $SourceSize
    if (-not $family) { return $null }
    # SIZE-TIE-1: key order cannot matter here - any match gives the same yes.
    foreach ($name in $CatalogBySize.Keys) {
        $n = [string]$name
        if ($n -notlike '*_v6' -and $n -notlike '*_v7' -and -not ($TargetGeneration -eq 'v5' -and $n -like '*_v5')) { continue }
        if ((Get-VmfSizeFamilyPrefix -SizeName $n) -eq $family) { return $true }
    }
    $false
}

function Get-VmfTargetSize {
    <#
    .SYNOPSIS
        Map a source size to its target. The default transform swaps the
        version suffix to the machine's target
        generation (capability letters preserved: D2ds_v4 -> D2ds_v6, or
        D2ds_v7 when the wave chose v7), with a d size first where the machine
        has a temporary disk to keep (Get-VmfDefaultSizeCandidates). The result must exist in the region's
        SKU catalog or the next alternate is tried.
    .PARAMETER Size
        One size to check in place of the sizes the default transform tries: a
        size chosen on the targets step, a size by shape, or the AMD size of
        ADVISE-AN-1 - always a size the product offered, never one a person
        wrote. It goes through every gate below and has no alternates. The two
        shape gates do not refuse it: whoever offered it checked the shape
        already, and a constrained size has fewer ACTIVE vCPUs on purpose, so
        a smaller one is planned with the reason saying so. SIZEMAP-REMOVE-1:
        this replaced the one-entry size map these callers built; the size map
        file a person could pass is gone.
    .PARAMETER Why
        With -Size: the start of the reason, which says where the size came
        from. 'chosen-size' when not given.
    .OUTPUTS
        @{ Target = <string|null>; Alternates = @(...); Reason = <string>; Code = <string> }
        Code is the Reason as one word from a fixed list (ADVISOR-1): mapped,
        mapped-unverified, not-in-region, family-not-in-region, not-approved,
        gen1-no-size, too-few-nics, too-few-data-disks, processor-unreadable,
        processor-not-approved, smaller-than-source, shape-unknown (SIZE-FIT-1),
        one-accelerated-nic (AN-ONE-NIC-1).
        A size that is planned also has NotTaken (SIZE-FALLTHROUGH-NOTE-1):
        each size tried before it, @{ size; why } with why one of not-listed,
        not-in-region, not-approved, gen1-no-size, too-few-nics,
        too-few-data-disks, smaller-than-source, shape-unknown,
        one-accelerated-nic, and the facts of that gate. Empty when the first
        size is the target.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][string]$Why = 'chosen-size',
        [Parameter()][hashtable]$CatalogBySize = @{},
        # NIC-1: a size that cannot hold the machine's NICs fails during the
        # RECREATE - after deallocation and disk detach, past the point of no
        # return. So the NIC count is a selection input, not a later check.
        [Parameter()][int]$RequiredNics = 1,
        # DISK-3: same shape as the NIC gate. Measured: E8-4ds_v5 holds 32
        # data disks, E8-4ds_v6 only 24 - a real shrink on a real transform.
        [Parameter()][int]$RequiredDataDisks = 0,
        # WAVE-2 lever 8: v6 by default, v7 opt-in PER WAVE.
        # The generation was hard-coded here; a customer with v7 available in
        # their region had no way to say so, and the product had no way to admit
        # it was choosing for them.
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # GEN-V5-1: 'V1' holds the choice to sizes whose catalog entry lists
        # Generation 1. v5 takes it; v6 and v7 do not. Empty means not known,
        # and is not checked - the assessment asks a person about that machine.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HyperVGeneration,
        # AN-ONE-NIC-1: how many network interfaces have accelerated networking
        # after the move (Get-VmfAcceleratedNicsAfterMove). $null: the scan did
        # not say. One, the default, asks nothing.
        [Parameter()][AllowNull()]$AcceleratedNicsAfter = 1
    )
    $anRefusedCount = $AcceleratedNicsAfter

    $candidates = [System.Collections.Generic.List[string]]::new()
    $families = Get-VmfTargetFamilyData

    if ($Size) {
        $candidates.Add($Size)
    }
    else {
        foreach ($c in @(Get-VmfDefaultSizeCandidates -SourceSize $SourceSize -CatalogBySize $CatalogBySize -TargetGeneration $TargetGeneration -Families $families)) {
            $candidates.Add($c)
        }
    }

    # SCOPE-DATA-1: the SOURCE machine's platform, before anything is chosen
    # for it. Asked here rather than on the candidate so an Arm64 machine is
    # told it is Arm64, instead of being told its region is short of sizes -
    # the rule "say WHICH no it is", one level further down than the family
    # question below. See Private/plan/TargetFamilies.ps1 for the measurement.
    $approvedList = @($families.approvedProcessors) -join ' and '
    $sourceProcessor = Get-VmfSizeProcessor -SizeName $SourceSize -Families $families
    if ($null -eq $sourceProcessor) {
        return @{
            Target = $null; Alternates = @(); Code = 'processor-unreadable'
            Reason = "this product cannot read the processor from the size name '$SourceSize', so it cannot tell whether this machine is in the migration path - a person must look at it"
        }
    }
    if (@($families.approvedProcessors) -notcontains $sourceProcessor) {
        return @{
            Target = $null; Alternates = @(); Code = 'processor-not-approved'
            Reason = ("this machine has an $sourceProcessor processor, and Microsoft lists only $approvedList sizes as v5, v6 and v7 targets. " +
                      $(if ($TargetGeneration -eq 'v5') { "It has no v5 target and needs a plan of its own" } else { "It is not in the v6/v7 migration path and needs a plan of its own" }))
        }
    }

    $tooSmall = [System.Collections.Generic.List[string]]::new()
    $notApproved = [System.Collections.Generic.List[string]]::new()
    $notGen1 = [System.Collections.Generic.List[string]]::new()
    # SIZE-FIT-1: the machine's own shape, compared with every candidate.
    $sourceShape = Get-VmfSkuShape -SkuEntry $(if ($CatalogBySize.ContainsKey($SourceSize)) { $CatalogBySize[$SourceSize] } else { $null })
    $smaller = [System.Collections.Generic.List[string]]::new()
    $shapeUnknown = [System.Collections.Generic.List[string]]::new()
    # AN-ONE-NIC-1: candidates refused for accelerated networking on more than
    # one network interface.
    $anTooSmall = [System.Collections.Generic.List[string]]::new()
    # V5-SUCCESSOR-1: a candidate the region's catalog does not hold is either
    # a size Microsoft does not list at all, or one it lists and this region
    # does not. Asked of the data (Get-VmfMicrosoftSizeListing), never of the
    # catalog, so each refusal below says which fact it is.
    $notListed = [System.Collections.Generic.List[string]]::new()
    $listedNotHere = [System.Collections.Generic.List[string]]::new()
    $listingRead = $null
    # SIZE-FALLTHROUGH-NOTE-1: each size tried before the target, and the gate
    # that refused it, as a code with its facts. The default transform tries
    # the d size first; when it falls through to the size without a temporary
    # disk, the plan (planNotes) and the targets step say which gate it was.
    # A size the product names (-Size) has one candidate, so none.
    $notTaken = [System.Collections.Generic.List[object]]::new()
    foreach ($candidate in $candidates) {
        $inCatalog = $CatalogBySize.ContainsKey($candidate)
        if (-not $inCatalog) {
            $listing = Get-VmfMicrosoftSizeListing -SizeName $candidate -Families $families
            if ($listing.Listed -eq $false) {
                $notListed.Add($candidate)
                $notTaken.Add([ordered]@{ size = $candidate; why = 'not-listed' })
                $listingRead = $listing.ReadUtc
                continue
            }
            if ($listing.Listed -eq $true) { $listedNotHere.Add("$candidate (the $($listing.Page) page, read $($listing.ReadUtc))") }
        }
        if ($CatalogBySize.Count -ne 0 -and -not $inCatalog) {
            $notTaken.Add([ordered]@{ size = $candidate; why = 'not-in-region' })
            continue
        }

        # SCOPE-DATA-1: and the TARGET. The source check above cannot catch a
        # named size (-Size) on a family Microsoft does not list - nor the
        # confidential DC and EC families, whose sizes
        # carry an approved processor and a series that is neither D nor E.
        # BSV2-TARGET-1: with the machine's own size - Bsv2 is approved for a B v1 machine only.
        $approval = Test-VmfSizeApprovedTarget -SizeName $candidate -TargetGeneration $TargetGeneration -Families $families -SourceSize $SourceSize
        if (-not $approval.Approved) {
            $notApproved.Add("$candidate ($($approval.Why))")
            $notTaken.Add([ordered]@{ size = $candidate; why = 'not-approved' })
            continue
        }

        # GEN-V5-1: a Generation 1 machine only fits a size that takes one.
        # Read from the size's own catalog entry, not from the series: Azure
        # is the authority on what it will accept, and v5 is the only target
        # series that does. Absent is "cannot verify", never a fit or a miss.
        $unverified = $false
        $unverifiedWhat = [System.Collections.Generic.List[string]]::new()
        if ($HyperVGeneration -eq 'V1') {
            $gens = if ($inCatalog) { Get-VmfSkuHyperVGenerations -SkuEntry $CatalogBySize[$candidate] } else { $null }
            if ($null -eq $gens) { $unverified = $true; $unverifiedWhat.Add('which machine generations it takes (this machine is Generation 1)') }
            elseif ($gens -notcontains 'V1') {
                $notGen1.Add($candidate)
                $notTaken.Add([ordered]@{ size = $candidate; why = 'gen1-no-size' })
                continue
            }
        }

        # NIC capacity. Unknown is NOT treated as a fit - it is reported, so a
        # missing capability never silently passes a multi-NIC machine.
        $maxNics = if ($inCatalog) { Get-VmfSkuMaxNics -SkuEntry $CatalogBySize[$candidate] } else { $null }
        if ($RequiredNics -gt 1) {
            if ($null -eq $maxNics) { $unverified = $true; $unverifiedWhat.Add("a network interface limit (the machine has $RequiredNics)") }
            elseif ($maxNics -lt $RequiredNics) {
                $tooSmall.Add("$candidate holds $maxNics")
                $notTaken.Add([ordered]@{ size = $candidate; why = 'too-few-nics'; holds = $maxNics; needs = $RequiredNics })
                continue
            }
        }

        if ($RequiredDataDisks -gt 0) {
            $maxDataDisks = if ($inCatalog) { Get-VmfSkuMaxDataDisks -SkuEntry $CatalogBySize[$candidate] } else { $null }
            if ($null -eq $maxDataDisks) { $unverified = $true; $unverifiedWhat.Add("a data disk limit (the machine has $RequiredDataDisks)") }
            elseif ($maxDataDisks -lt $RequiredDataDisks) {
                $tooSmall.Add("$candidate holds $maxDataDisks data disks")
                $notTaken.Add([ordered]@{ size = $candidate; why = 'too-few-data-disks'; holds = $maxDataDisks; needs = $RequiredDataDisks })
                continue
            }
        }

        # SIZE-FIT-1: never a smaller machine. A size named like the source
        # can have fewer vCPUs or less memory (Dv2: D4_v2 has 8 vCPUs, D4_v5
        # has 4). The product never picks one by name. A named size (-Size)
        # was offered by a rule that checked its shape already - a constrained
        # size has fewer active vCPUs on purpose - so it is not refused here.
        $targetShape = Get-VmfSkuShape -SkuEntry $(if ($inCatalog) { $CatalogBySize[$candidate] } else { $null })
        $fit = Test-VmfSizeSmaller -Source $sourceShape -Target $targetShape
        if ($fit -eq 'smaller' -and -not $Size) {
            $smaller.Add("$candidate has $($targetShape.Vcpus) vCPUs and $($targetShape.MemoryGB) GiB")
            $notTaken.Add([ordered]@{ size = $candidate; why = 'smaller-than-source'; vcpus = $targetShape.Vcpus; memoryGB = $targetShape.MemoryGB
                sourceVcpus = $sourceShape.Vcpus; sourceMemoryGB = $sourceShape.MemoryGB })
            continue
        }
        # Unknown matters only where the name says nothing about the shape.
        # From v3 on the number is the vCPU count, so the name gives the shape
        # and the planner keeps the behaviour it had.
        if ($fit -eq 'unknown' -and -not $Size -and (Test-VmfSizeNameIsNotVcpus -SizeName $SourceSize)) {
            $shapeUnknown.Add($candidate)
            $notTaken.Add([ordered]@{ size = $candidate; why = 'shape-unknown' })
            continue
        }

        # AN-ONE-NIC-1: Azure allows accelerated networking on ONE network
        # interface of a 2-vCPU size (NIC-1), and the move leaves it on the
        # primary interface and on every other interface that has it now. With
        # more than one, a 2-vCPU size fails after the stop on every attempt,
        # so it is refused here, as a size too small for the interfaces is. The
        # reason names NO bigger size (2026-10-10, OWNER-QUESTIONS-1 row
        # 31: it doubles the price): the fix is to turn accelerated networking
        # off on the other interfaces (Get-VmfOneAcceleratedNicReason). Unknown - no vCPU count,
        # 2 active vCPUs, or a scan that did not say how many - is planned as
        # unverified, never as a fit; PRECHECK asks Azure again.
        # AN-MANA-DRIVER-RULE-1: one count on every size. AN-ONE-NIC-2 counted
        # fewer on a size where a kernel with no MANA driver kept the primary
        # off; no size keeps it off now.
        $anNote = $null
        $anHere = $AcceleratedNicsAfter
        if ($RequiredNics -gt 1 -and ($null -eq $anHere -or [int]$anHere -gt 1)) {
            $an = Test-VmfSizeAllowsAcceleratedNics -SkuEntry $(if ($inCatalog) { $CatalogBySize[$candidate] } else { $null }) -Count 2
            if ($null -ne $anHere -and $an.Verdict -eq 'tooSmall') {
                $anTooSmall.Add("$candidate has $($an.Vcpus) vCPUs")
                $notTaken.Add([ordered]@{ size = $candidate; why = 'one-accelerated-nic'; vcpus = $an.Vcpus; needs = [int]$anHere })
                $anRefusedCount = $anHere
                continue
            }
            if ($an.Verdict -eq 'tooSmall') {
                $anNote = "the scan did not say on how many network interfaces it is on, and $candidate has $($an.Vcpus) vCPUs, which allows it on one only"
            }
            elseif ($an.Verdict -eq 'unknown') {
                $anNote = if ($null -eq $an.Vcpus) { "Azure reported no vCPU count for $candidate" }
                          else { "$candidate has $($an.Active) active vCPUs" }
            }
        }

        $reason = if ($Size) { $Why } else { 'default-transform' }
        if ($Size -and $fit -eq 'smaller') {
            $reason += " (smaller than the machine: $SourceSize has $($sourceShape.Vcpus) vCPUs and $($sourceShape.MemoryGB) GiB, $candidate has $($targetShape.Vcpus) and $($targetShape.MemoryGB))"
        }
        if ($unverified) {
            $reason += " (capacity could not be verified: Azure reported no $($unverifiedWhat -join ', and no ') for $candidate)"
        }
        if ($anNote) {
            $reason += " (accelerated networking could not be verified on more than one network interface: $anNote)"
        }
        return @{
            Target     = $candidate
            Alternates = @($candidates | Where-Object { $_ -ne $candidate })
            Reason     = $reason
            # ADVISOR-1: the same answer as a code, for a screen to put in words.
            Code       = $(if ($unverified -or $anNote) { 'mapped-unverified' } else { 'mapped' })
            # SIZE-FALLTHROUGH-NOTE-1: the sizes tried before this one, and why
            # each was not taken (Get-VmfSizeNotTakenNote puts it in words).
            NotTaken   = @($notTaken)
        }
    }

    # SCOPE-DATA-1: every candidate existed and none was on a platform the
    # guide lists. Said before the capacity refusals below, because "Azure does
    # not offer this machine a target at all" is a bigger fact than "the target
    # it would have had is too small".
    if ($notApproved.Count -gt 0) {
        # DISKS-32-1: a size refused by a scope decision (the E104i v5 sizes)
        # is one Microsoft DOES list - so the words say scope, not Microsoft.
        $byScope = @($notApproved | Where-Object { $_ -notmatch '\(scope: ' }).Count -eq 0
        return @{
            Target = $null; Alternates = @(); Code = 'not-approved'
            Reason = ($(if ($byScope) { "no target size for this machine is one the product offers on ${TargetGeneration}: " }
                        else { "no target size for this machine is one Microsoft lists as a $TargetGeneration target: " }) +
                      ($notApproved -join '; '))
        }
    }

    # SIZE-FIT-1: every candidate that existed was smaller than the machine.
    # Refused, and said with both shapes, never planned as a quiet downsize.
    if ($smaller.Count -gt 0 -and $tooSmall.Count -eq 0 -and $notGen1.Count -eq 0 -and $anTooSmall.Count -eq 0) {
        return @{
            Target = $null; Alternates = @(); Code = 'smaller-than-source'
            Reason = ("every target size for this machine is smaller than it: $SourceSize has $($sourceShape.Vcpus) vCPUs and $($sourceShape.MemoryGB) GiB, and " +
                      ($smaller -join '; ') + '. The product does not plan a smaller size.')
        }
    }
    if ($shapeUnknown.Count -gt 0 -and $smaller.Count -eq 0 -and $tooSmall.Count -eq 0 -and $notGen1.Count -eq 0 -and $anTooSmall.Count -eq 0) {
        return @{
            Target = $null; Alternates = @(); Code = 'shape-unknown'
            Reason = ("the size number of $SourceSize is not its vCPU count, and this region's catalog does not give the vCPUs and memory of " +
                      "$SourceSize or $($shapeUnknown -join ', '). The product cannot check that the target is not smaller, so it does not plan one.")
        }
    }

    if ($notGen1.Count -gt 0 -and $tooSmall.Count -eq 0 -and $anTooSmall.Count -eq 0) {
        $advice = if ($TargetGeneration -ne 'v5') { ' v5 takes Generation 1 machines. Choose it in the Choose each target step.' } else { '' }
        return @{
            Target = $null; Alternates = @(); Code = 'gen1-no-size'
            Reason = ("this machine is Generation 1, and no target size for it takes Generation 1 machines: " +
                      ($notGen1 -join ', ') + '.' + $advice)
        }
    }

    if ($tooSmall.Count -gt 0) {
        # Do not just refuse - name the smallest size in the same series that
        # WOULD hold them, so the operator has an answer rather than a puzzle.
        $blockedOn = if (@($tooSmall) -match 'data disks') { 'dataDisks' } else { 'nics' }
        if ($blockedOn -eq 'dataDisks') {
            $suggestion = Get-VmfSmallestSizeForDisks -SourceSize $SourceSize -RequiredDataDisks $RequiredDataDisks -CatalogBySize $CatalogBySize -TargetGeneration $TargetGeneration -SourceShape $sourceShape
            $advice = if ($suggestion) { "use $($suggestion.Name) instead (it holds $($suggestion.MaxDataDisks))" } else { 'choose a larger size for it, or detach some disks' }
            return @{
                Target = $null; Alternates = @(); Code = 'too-few-data-disks'
                Reason = "no target size can hold this machine's $RequiredDataDisks data disks ($($tooSmall -join '; ')) - $advice"
            }
        }
        $suggestion = Get-VmfSmallestSizeForNics -SourceSize $SourceSize -RequiredNics $RequiredNics -CatalogBySize $CatalogBySize -TargetGeneration $TargetGeneration -SourceShape $sourceShape
        $advice = if ($suggestion) { "use $($suggestion.Name) instead (it holds $($suggestion.MaxNics))" } else { 'choose a larger size for it, or reduce its network interfaces' }
        return @{
            Target = $null; Alternates = @(); Code = 'too-few-nics'
            Reason = "no target size can hold this machine's $RequiredNics network interfaces ($($tooSmall -join '; ')) - $advice"
        }
    }
    # AN-ONE-NIC-1: unlike the interface refusal above, no bigger size is
    # named. Row 31, option 2 (2026-10-10): never offer one for this.
    if ($anTooSmall.Count -gt 0) {
        return @{
            Target = $null; Alternates = @(); Code = 'one-accelerated-nic'
            Reason = (Get-VmfOneAcceleratedNicReason -AcceleratedNicsAfter $anRefusedCount -Sizes @($anTooSmall))
        }
    }
    # V3-TEMPDISK-1: on v7, the v6 size the same rules would choose, not the
    # name twin - Standard_D4_v6 does not exist, Standard_D4ds_v6 does.
    # V7-REFUSAL-WORDS-1: and only a size v6 TAKES - the size Get-VmfTargetSize
    # gives at v6 with the same inputs, which is the call the Choose each target
    # step makes for its v6 option (Get-VmfAdviceOption). A size the region
    # merely holds sent a machine with 3 network interfaces to Standard_D2ds_v6,
    # which holds 2, and the step does not offer v6 for it. The inner call is
    # at v6, so it never comes back here: only a v7 call asks.
    $v6Instead = $null
    if ($TargetGeneration -eq 'v7' -and $CatalogBySize.Count -gt 0) {
        $v6Instead = [string](Get-VmfTargetSize -SourceSize $SourceSize -CatalogBySize $CatalogBySize -TargetGeneration 'v6' `
                -RequiredNics $RequiredNics -RequiredDataDisks $RequiredDataDisks -HyperVGeneration $HyperVGeneration `
                -AcceleratedNicsAfter $AcceleratedNicsAfter).Target
    }
    # Where a person chooses that size. A wave has no series setting
    # (WAVE-SERIES-GONE-1): the series is the machine's, chosen on the Choose
    # each target step. One sentence for both refusals below, so they cannot
    # say it two ways. Not Change target in the wave editor: a refused machine
    # has no target, so its entry is MANUAL and the wave editor does not list it.
    $v6Advice = 'Choose v6 for this machine in the Choose each target step, then plan again.'
    # V5-SUCCESSOR-1: Microsoft lists no size of any name tried. That is not a
    # shortage in the region - no region and no wait gives the machine one -
    # so it is not said as one (not-in-region). The code is not-approved: no
    # size tried is one Microsoft lists as a target. NotListed tells a caller
    # which not-approved this is (Resolve-VmfEntryTarget says the Generation 1
    # reason first, as it does for not-in-region). No target is invented: an
    # isolated machine is told which isolated sizes Microsoft lists, and that
    # a person chooses among them.
    if ($candidates.Count -gt 0 -and $notListed.Count -eq $candidates.Count) {
        $names = if ($notListed.Count -eq 1) { $notListed[0] } else { (@($notListed)[0..($notListed.Count - 2)] -join ', ') + ' or ' + $notListed[$notListed.Count - 1] }
        $reason = "no $TargetGeneration size for this machine is one Microsoft lists: its size pages (read $listingRead) have no $names. This is not a shortage in this region."
        if (Test-VmfIsolatedSize -SizeName $SourceSize -Families $families) {
            $family = Get-VmfSizeFamilyPrefix -SizeName $SourceSize
            # SIZE-LISTING-V5-1: only the sizes of the machine's processor - it
            # keeps its processor maker, and v5 has isolated AMD E sizes too.
            $isolated = @(Get-VmfMicrosoftIsolatedSizes -Family $family -TargetGeneration $TargetGeneration -Processor $sourceProcessor -Families $families)
            $reason += " $SourceSize is an isolated size."
            $reason += $(if ($isolated.Count -eq 0) { " Microsoft lists no isolated $sourceProcessor $family size on $TargetGeneration." }
                         elseif ($isolated.Count -eq 1) { " Microsoft's isolated $sourceProcessor $family size on $TargetGeneration is $($isolated[0])." }
                         else { " Microsoft's isolated $sourceProcessor $family sizes on $TargetGeneration are $((@($isolated)[0..($isolated.Count - 2)]) -join ', ') and $($isolated[$isolated.Count - 1])." })
            $reason += ' A person decides the size of an isolated machine: the product does not choose one.'
        }
        if ($v6Instead) { $reason += " This region has $v6Instead. $v6Advice" }
        return @{ Target = $null; Alternates = @(); Code = 'not-approved'; NotListed = $true; Reason = $reason }
    }

    # WAVE-2 lever 8: a wave that asked for v7 must NEVER be quietly given v6.
    # Silent substitution is the failure this whole tool argues against, so the
    # refusal names the size that WOULD have worked at the other generation and
    # leaves the choice with a person - the same "turn a refusal into an
    # answer" shape as the NIC and data-disk suggestions above.
    # Say WHICH kind of no this is. A family with no sizes at the
    # target generation is not a regional shortage an operator can wait out or
    # solve by moving region - it is a machine outside the v6/v7 migration
    # path, and the two need different answers.
    $familyInScope = Test-VmfFamilyHasGeneration -SourceSize $SourceSize -CatalogBySize $CatalogBySize -TargetGeneration $TargetGeneration
    if ($familyInScope -eq $false) {
        $family = Get-VmfSizeFamilyPrefix -SizeName $SourceSize
        return @{
            Target = $null; Alternates = @(); Code = 'family-not-in-region'
            # CONF-1 research, 2026-08-30: this used to end "the v6/v7 migration
            # path covers the D and E series", which the guidance itself
            # contradicts - its target-families table lists Fasv7 under v7 AMD.
            # Enumerating families in a message is a fact that drifts; the
            # catalog answer above does not. So state what was actually
            # checked, and stop naming a list.
            # REVIEW-1: said for the series asked. A v5 choice was told about
            # "v6 or v7", which is not what was checked.
            Reason = $(if ($TargetGeneration -eq 'v5') {
                    "Azure offers no v5 size in the $family family in this region, so there is nothing for " +
                    'this machine to move to on v5.'
                } else {
                    "Azure offers no v6 or v7 size in the $family family in this region, so there is nothing for " +
                    "this machine to move to. It is not part of the v6/v7 migration path and needs a plan of its own."
                })
        }
    }
    $reason = "no candidate available in region (tried: $($candidates -join ', '))"
    # V5-SUCCESSOR-1: and where the data says Microsoft lists the size, say so:
    # the region fact is then the whole truth, and another region may have it.
    if ($listedNotHere.Count -gt 0) {
        $reason += ". Microsoft lists $(@($listedNotHere) -join ' and '), and this region does not list $(if ($listedNotHere.Count -eq 1) { 'it' } else { 'them' })."
    }
    # V7-REFUSAL-WORDS-1: last, as its own sentences, so each one ends once.
    if ($v6Instead) {
        $reason += "$(if ($reason.EndsWith('.')) { '' } else { '.' }) This region has $v6Instead. $v6Advice"
    }
    return @{ Target = $null; Alternates = @(); Reason = $reason; Code = 'not-in-region' }
}

function Get-VmfDefaultSizeCandidates {
    <#
    .SYNOPSIS
        The sizes the default transform tries for a machine, in order, when no
        size is named: the size name with its version changed, and before
        it the d size when the machine has a temporary disk to keep.
    .DESCRIPTION
        GEN-V5-1: Microsoft's v5 guide - "Select a d variant when the workload
        requires local scratch space". A v5 d size keeps the temporary disk on
        SCSI, so on Windows the move stays a resize; the plain size would
        change disk architecture and force a rebuild on the move that exists to
        be the less disruptive one. The plain size stays the alternate.

        V3-TEMPDISK-1: the same for v6 and v7, for a source series Microsoft
        gives a replacement table for (data/target-families.json
        replacements - the v3 series, read from the plan page on 2026-10-03).
        "Every v3 size includes a local temporary disk. If the workload uses
        it, choose" a d size. And every v6 and v7 size that table names has an
        s, so a plain v3 size takes one: D4_v3 tries D4ds_v6 then D4s_v6. It
        tried only Standard_D4_v6 before, which does not exist, and the machine
        was reported as one its region had no size for.

        A v3 machine on Windows is rebuilt (Path B) either way: its SCSI
        temporary disk becomes an NVMe one or none, and both change disk
        category. On Linux it is an in-place upgrade either way. So the d size
        keeps the temporary disk and changes no path.

        DAV4-TEMPDISK-1: the AMD v4 series (Dav4, Dasv4, Eav4, Easv4) have a
        row too, derived from their size pages: every size has a temporary
        disk and no d in the name. Their rows name AMD targets only, and the
        letters are kept, so D4a_v4 tries D4ads_v6 then D4as_v6 (there is no
        Dav6) - never an Intel size. No default pairing changes the processor:
        the transform keeps the a or p of the name (a test sweeps every D
        and E letter combination, as a guard for later changes).

        V4-NAMES-1: the Intel v4 series with no s (Dv4, Ddv4, Ev4, Edv4) have
        rows too, derived from their size pages, because Intel D and E on v6
        and v7 have only s sizes: D4_v4 tried only Standard_D4_v6 and D4d_v4
        only Standard_D4d_v6, which do not exist. Now D4_v4 tries D4s_v6 and
        D4d_v4 tries D4ds_v6. Dv4 and Ev4 have no temporary disk (their row
        says so), so no d size is added; Ddv4 and Edv4 have the d in the
        name already. Each gets one size, as Dsv4 and Ddsv4 do.
        V5-NAMES-1: the same rows one version on, for Dv5, Ddv5, Ev5 and
        Edv5 (D4_v5 tries D4s_v6, D4d_v5 tries D4ds_v6). On v5 their row
        names their own series, so the letters are kept there.

        A size whose catalog entry has no temporary disk reading is taken from
        the table when the table says every size of the series has one; a
        reading in the catalog always wins. That holds on v5 too: a v3 machine
        whose catalog entry has no reading now gets the v5 d size, where it got
        the plain size before.
    .OUTPUTS
        string[] - may be empty for a name the transform cannot read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter()][hashtable]$CatalogBySize = @{},
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        [Parameter()][AllowNull()]$Families
    )
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if ($SourceSize -notmatch '^(Standard_[A-Za-z]+\d+(?:-\d+)?)([a-z]*)_v[2-6]$') { return @() }
    $stem = $Matches[1]
    $letters = $Matches[2]

    $replacement = Get-VmfSizeReplacement -SizeName $SourceSize -Families $Families
    $named = if ($replacement) { @($replacement.targets.$TargetGeneration) } else { @() }

    $hasTemp = Test-VmfSourceHasTempDisk -SourceSize $SourceSize -CatalogBySize $CatalogBySize
    if (-not $hasTemp -and $replacement -and $replacement.everySizeHasTemporaryDisk -eq $true) {
        $reading = $CatalogBySize.ContainsKey($SourceSize) -and
            @(@($CatalogBySize[$SourceSize].Capabilities) | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' }).Count -gt 0
        if (-not $reading) { $hasTemp = $true }
    }

    $wanted = [System.Collections.Generic.List[string]]::new()
    if (($TargetGeneration -eq 'v5' -or $replacement) -and $letters -notlike '*d*' -and $hasTemp) {
        $wanted.Add($(if ($letters -like '*s') { $letters.Substring(0, $letters.Length - 1) + 'ds' } else { $letters + 'd' }))
    }
    $wanted.Add($letters)

    $out = [System.Collections.Generic.List[string]]::new()
    $family = Get-VmfSizeFamilyPrefix -SizeName $SourceSize
    foreach ($l in $wanted) {
        $use = $l
        # The letters Microsoft's table names for this series: a size the
        # table does not name, with an s added, when that one is named.
        if ($named.Count -and $named -notcontains "$family$l$TargetGeneration" -and $named -contains "$family$($l)s$TargetGeneration") {
            $use = "$($l)s"
        }
        $size = '{0}{1}_{2}' -f $stem, $use, $TargetGeneration
        if (-not $out.Contains($size)) { $out.Add($size) }
    }
    $out.ToArray()
}

function Get-VmfReplacementSizeChoices {
    <#
    .SYNOPSIS
        V3-TEMPDISK-1: the sizes a machine on a series with a replacement row
        (the v3 series, and the AMD v4 series since DAV4-TEMPDISK-1) may choose
        between - the d size the planner chose, and the size without a
        temporary disk. V4-NAMES-1: a Dv4, Ddv4, Ev4 or Edv4 machine has one
        size to try, so it has no choice here, the same as Dsv4 and Ddsv4.
    .DESCRIPTION
        Each size goes through every gate Get-VmfTargetSize has, as a named
        size (-Size), and must be in the catalog with its vCPUs and
        memory and no smaller than the machine. One size left is no choice,
        and returns nothing. The shape is the one Get-VmfShapeSizeChoices
        gives, so the targets step, the save and the plan treat both alike.
    .OUTPUTS
        @{ size; family; variant; vcpus; activeVcpus; memoryGB; best } for each.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter(Mandatory)][hashtable]$Mapping,
        [Parameter()][hashtable]$CatalogBySize = @{},
        [Parameter()][int]$RequiredNics = 1,
        [Parameter()][int]$RequiredDataDisks = 0,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HyperVGeneration,
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # AN-ONE-NIC-1: passed to every gate, as the interfaces are.
        [Parameter()][AllowNull()]$AcceleratedNicsAfter = 1
    )
    if (-not $Mapping.Target) { return @() }
    $source = Get-VmfSkuShape -SkuEntry $(if ($CatalogBySize.ContainsKey($SourceSize)) { $CatalogBySize[$SourceSize] } else { $null })
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($size in @(@($Mapping.Target) + @($Mapping.Alternates) | Select-Object -Unique)) {
        $size = [string]$size
        if (-not $CatalogBySize.ContainsKey($size)) { continue }
        $m = Get-VmfTargetSize -SourceSize $SourceSize -Size $size -CatalogBySize $CatalogBySize `
            -RequiredNics $RequiredNics -RequiredDataDisks $RequiredDataDisks -TargetGeneration $TargetGeneration -HyperVGeneration $HyperVGeneration -AcceleratedNicsAfter $AcceleratedNicsAfter
        if ([string]$m.Target -ne $size) { continue }
        $shape = Get-VmfSkuShape -SkuEntry $CatalogBySize[$size]
        if ($null -eq $shape.Vcpus -or $null -eq $shape.MemoryGB) { continue }
        if ((Test-VmfSizeSmaller -Source $source -Target $shape) -eq 'smaller') { continue }
        $own = @(@($CatalogBySize[$size].Capabilities) | Where-Object { $_.Name -eq 'vCPUs' } | Select-Object -First 1)
        $ownVcpus = 0
        if (-not ($own.Count -and [int]::TryParse([string]$own[0].Value, [ref]$ownVcpus))) { $ownVcpus = [int]$shape.Vcpus }
        $out.Add([ordered]@{ size = $size; family = (Get-VmfSizeFamilyPrefix -SizeName $size)
                variant = $(if ($size -match '^Standard_[A-Za-z]+\d+-\d+') { 'constrained' } else { 'default' })
                vcpus = $ownVcpus; activeVcpus = [int]$shape.Vcpus; memoryGB = $shape.MemoryGB
                best = ($size -eq [string]$Mapping.Target) })
    }
    if ($out.Count -lt 2 -or -not @($out | Where-Object { $_.best }).Count) { return @() }
    # One item per choice down the pipeline, as Get-VmfShapeSizeChoices does.
    $out
}

function Test-VmfShapeChoiceSource {
    <#
    .SYNOPSIS
        OLD-SKU-1B: does this machine choose its v5 family and size by shape?
        Generation 1 machines, and the old families whose size number is not
        a guide to the size on v5 - the same list the targets step draws its
        second area from (wizard.html oldShape; a test holds the two equal).
        OLD-FAM-1: and the End of Life families with no size of their own
        on v5, v6 or v7 - B v1 (B1s to B20ms), F v1, Fs v1 and Fsv2.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Generation,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SourceSize
    )
    if ($Generation -eq 'V1') { return $true }
    [string]$SourceSize -match '^Standard_((A|D|DS)\d+(-\d+)?m?(_v2)?(_Promo)?|B\d+(ls|s|ms)|F\d+s?(_v2)?)$'
}

function Get-VmfShapeSizeChoices {
    <#
    .SYNOPSIS
        OLD-SKU-1B: the sizes on one series a machine can choose by its shape -
        for each family (Dl, D, E), the smallest size with at least its vCPUs
        AND memory, and E's constrained sizes of that size. OLD-FAM-1 added Dl
        (2 GiB for each vCPU): Microsoft's "Retired VM sizes modernization
        guide" (2026-09-25) names Dlsv5, Dldsv5, Dlsv6 and Dldsv6 for B v1, and
        Dlsv6, Dldsv6, Dlsv5 and Dldsv5 for F, Fs and Fsv2. Without it a
        machine with little memory paid for double. v5 by default; v6 and
        v7 for a Generation 2 machine on an old size (OLD-SKU-V6-1).
    .DESCRIPTION
        From the region's catalog only; nothing is inferred from a name. A
        temporary disk keeps a d size (on v5 a Windows move then stays in
        place; on v6 and v7 the temporary disk is NVMe, and Windows is
        rebuilt, as for any machine that changes disk category); every
        size is an s size, which takes Standard and Premium disks alike. Each
        choice goes through every gate Get-VmfTargetSize has, as a named
        size (-Size): approved target, Generation 1, network interfaces,
        data disks. A constrained size keeps the size and turns cores off for
        software licensed by core, so it has fewer ACTIVE vCPUs on purpose.
        The best choice keeps both with the fewest vCPUs, then the least
        memory, then D before Dl before E. A one-vCPU machine grows to the
        smallest size there is: no Dl, D or E size has one vCPU. No shape for
        the machine: no choices.

        AMD-SHAPE-1 (2026-10-05): a machine keeps its processor maker.
        The names matched were the Intel ones whatever the machine ran on, so
        a Generation 1 machine on an AMD size (Dav4, Dasv4, Eav4, Easv4) was
        offered Intel D, Dl and E v5 sizes. Now the processor letter of the
        machine's size (Get-VmfSizeProcessor, Get-VmfProcessorLetter - the
        'a' of data/target-families.json) is part of every name matched:
        D4ads_v5, E8-4ads_v5, D8alds_v6 for AMD, as D4ds_v5 is for Intel.
        A processor the data cannot give a letter for gets no choices.

        BSV2-TARGET-1 (2026-10-05): a B v1 machine is offered its Bsv2
        size too, FIRST, and it is the best choice - the default target of a
        B v1 machine - with the Dl, D or E size by shape as the other choice.
        Only on the option the Bsv2 row is offered on (v5), and only when a
        Bsv2 size in the region keeps the vCPUs and memory of the machine and
        passes every gate (Get-VmfBurstableSizeChoice). -NoBurstable leaves it
        out, for a machine that cannot take it (Resolve-VmfEntryTarget).
    .OUTPUTS
        @{ size; family; variant = 'default' | 'constrained'; vcpus; activeVcpus;
           memoryGB; best } for each.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter()][hashtable]$CatalogBySize = @{},
        [Parameter()][int]$RequiredNics = 1,
        [Parameter()][int]$RequiredDataDisks = 0,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$HyperVGeneration,
        # OLD-SKU-V6-1: the series whose sizes are chosen. v6 and v7 take
        # Generation 2 only, which the gates below enforce.
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v5',
        [Parameter()][switch]$NoBurstable,
        # AN-ONE-NIC-1: the interfaces with accelerated networking after the
        # move. NOT a gate the sizes climb past (row 31, option 2): the choices
        # are made as for one interface, and a size that cannot take them is
        # then taken out. When that is the best choice, there are no choices.
        [Parameter()][AllowNull()]$AcceleratedNicsAfter = 1
    )
    $source = Get-VmfSkuShape -SkuEntry $(if ($CatalogBySize.ContainsKey($SourceSize)) { $CatalogBySize[$SourceSize] } else { $null })
    if ($null -eq $source.Vcpus -or $null -eq $source.MemoryGB) { return @() }
    # AMD-SHAPE-1: the processor letter of the machine ('a' for AMD, none for Intel).
    $families = Get-VmfTargetFamilyData
    $maker = Get-VmfProcessorLetter -Processor (Get-VmfSizeProcessor -SizeName $SourceSize -Families $families) -Families $families
    if ($null -eq $maker) { return @() }
    $letters = if (Test-VmfSourceHasTempDisk -SourceSize $SourceSize -CatalogBySize $CatalogBySize) { 'ds' } else { 's' }
    # AN-ONE-NIC-1: every gate but accelerated networking - so a family's
    # choice is the size of the machine's own shape, never the next one up
    # because the 2-vCPU size takes accelerated networking on one interface.
    $passes = {
        param([string]$Size)
        $m = Get-VmfTargetSize -SourceSize $SourceSize -Size $Size -CatalogBySize $CatalogBySize `
            -RequiredNics $RequiredNics -RequiredDataDisks $RequiredDataDisks -TargetGeneration $TargetGeneration -HyperVGeneration $HyperVGeneration -AcceleratedNicsAfter 1
        [string]$m.Target -eq $Size
    }
    # ... and every gate, accelerated networking included.
    $passesAn = {
        param([string]$Size)
        $m = Get-VmfTargetSize -SourceSize $SourceSize -Size $Size -CatalogBySize $CatalogBySize `
            -RequiredNics $RequiredNics -RequiredDataDisks $RequiredDataDisks -TargetGeneration $TargetGeneration -HyperVGeneration $HyperVGeneration -AcceleratedNicsAfter $AcceleratedNicsAfter
        [string]$m.Target -eq $Size
    }
    $out = [System.Collections.Generic.List[object]]::new()
    # The family, and the letters between its size number and its capability
    # letters: Dl is D2lds_v5, D2ls_v5 - and on AMD D2alds_v6 (the processor
    # letter comes first, as Microsoft names Daldsv6).
    $familyNames = [ordered]@{ Dl = @('D', "$($maker)l"); D = @('D', $maker); E = @('E', $maker) }
    # SIZE-TIE-1: key order cannot matter here. Each pattern fixes the letters,
    # so a size number has one name, and the sorts below have no equal keys
    # (a constrained size by its active vCPUs, a best choice by its family).
    foreach ($family in $familyNames.Keys) {
        $prefix = $familyNames[$family][0]; $infix = $familyNames[$family][1]
        $plain = foreach ($name in $CatalogBySize.Keys) {
            if ($name -match "^Standard_$($prefix)(\d+)$($infix)$($letters)_$($TargetGeneration)$") { [pscustomobject]@{ Size = $name; Base = [int]$Matches[1] } }
        }
        foreach ($p in @($plain | Sort-Object Base)) {
            $shape = Get-VmfSkuShape -SkuEntry $CatalogBySize[$p.Size]
            if ($null -eq $shape.Vcpus -or $null -eq $shape.MemoryGB) { continue }
            if ($shape.Vcpus -lt $source.Vcpus -or $shape.MemoryGB -lt $source.MemoryGB) { continue }
            if (-not (& $passes $p.Size)) { continue }
            $out.Add([ordered]@{ size = $p.Size; family = $family; variant = 'default'; vcpus = [int]$shape.Vcpus
                    activeVcpus = [int]$shape.Vcpus; memoryGB = $shape.MemoryGB; best = $false })
            if ($family -eq 'E') {
                $constrained = foreach ($name in $CatalogBySize.Keys) {
                    if ($name -match "^Standard_E$($p.Base)-(\d+)$($maker)$($letters)_$($TargetGeneration)$") { [pscustomobject]@{ Size = $name; Active = [int]$Matches[1] } }
                }
                foreach ($c in @($constrained | Sort-Object Active)) {
                    if (-not (& $passes $c.Size)) { continue }
                    $out.Add([ordered]@{ size = $c.Size; family = 'E'; variant = 'constrained'; vcpus = [int]$shape.Vcpus
                            activeVcpus = $c.Active; memoryGB = $shape.MemoryGB; best = $false })
                }
            }
            break
        }
    }
    $rank = @{ D = 0; Dl = 1; E = 2 }
    $defaults = @($out | Where-Object { $_.variant -eq 'default' } | Sort-Object { $_.vcpus }, { $_.memoryGB }, { $rank[$_.family] })
    if ($defaults.Count) { $defaults[0].best = $true }
    # CONSTRAINED-DEFAULT-1: a machine on a constrained vCPU size (DS13-4_v2:
    # 8 vCPUs, 4 active) keeps its active vCPU count by default where a
    # constrained vCPU size with that count is a choice (E8-4ds_v5), never
    # the full size (E8ds_v5, 8 active). Microsoft: "The licensing fees
    # charged for SQL Server are based on the available vCPU count." From the
    # catalog only: vCPUs above vCPUsAvailable. A constrained choice has the
    # memory of its full size, which passed the memory check above. With no
    # such choice, the default is as above (the full size).
    $sourceAll = 0
    $sourceAllCap = @(@($CatalogBySize[$SourceSize].Capabilities) | Where-Object { $_.Name -eq 'vCPUs' }) | Select-Object -First 1
    if ($sourceAllCap -and [int]::TryParse([string]$sourceAllCap.Value, [ref]$sourceAll) -and $sourceAll -gt [int]$source.Vcpus) {
        $keep = @($out | Where-Object { $_.variant -eq 'constrained' -and [int]$_.activeVcpus -eq [int]$source.Vcpus }) | Select-Object -First 1
        if ($keep) {
            foreach ($c in $out) { $c.best = $false }
            $keep.best = $true
        }
    }
    # BSV2-TARGET-1: the Bsv2 size is the default, first in the list.
    if (-not $NoBurstable) {
        $burst = Get-VmfBurstableSizeChoice -SourceSize $SourceSize -CatalogBySize $CatalogBySize -Passes $passes -TargetGeneration $TargetGeneration -Families $families
        if ($burst) {
            foreach ($c in $out) { $c.best = $false }
            $out.Insert(0, $burst)
        }
    }
    # AN-ONE-NIC-1, row 31, option 2 (2026-10-10): never a bigger size
    # for accelerated networking, and never a silent one. The best choice was
    # made above as for one interface; when it cannot take the interfaces, the
    # machine gets no choices and so no target - a 4-vCPU size of another
    # family (a Dl size with the memory of the machine) does not take its place.
    if ($RequiredNics -gt 1 -and $null -ne $AcceleratedNicsAfter -and [int]$AcceleratedNicsAfter -gt 1) {
        $bestNow = @($out | Where-Object { $_.best }) | Select-Object -First 1
        if ($bestNow -and -not (& $passesAn ([string]$bestNow.size))) { return }
        $out = [System.Collections.Generic.List[object]]@($out | Where-Object { & $passesAn ([string]$_.size) })
    }
    # One item per choice down the pipeline: a wrapped list reaches a caller's
    # Where-Object as ONE item (found by this item's own tests).
    $out
}

function Get-VmfBurstableSizeChoice {
    <#
    .SYNOPSIS
        BSV2-TARGET-1: the burstable size a machine is offered on this option -
        the smallest Bsv2 size with at least its vCPUs AND its memory that
        passes every gate - as a size choice marked best, or $null.
    .DESCRIPTION
        Offered only where Get-VmfBurstableTargetFor gives a row: a machine on
        a B v1 size, on v5, keeping its processor maker. The sizes are the
        region's, read by their series (Get-VmfBurstableTarget), so Basv2 and
        Bpsv2 are never among them.

        The SIZE-FIT-1 rule - never fewer vCPUs, never less memory - then the
        fewest vCPUs, then the least memory. A size that fails a gate (network
        interfaces, data disks, Generation 1) is passed over for the next one,
        as for a Dl, D or E size. Between two sizes of one shape the first in
        Get-VmfCatalogSizeNames order wins (SIZE-TIE-1): the catalog is a
        hashtable, and its key order changes from one process to the next.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter()][hashtable]$CatalogBySize = @{},
        # The caller's gate: does this size, named (-Size), pass every check
        # Get-VmfTargetSize has?
        [Parameter(Mandatory)][scriptblock]$Passes,
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v5',
        [Parameter()][AllowNull()]$Families
    )
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    $row = Get-VmfBurstableTargetFor -SourceSize $SourceSize -TargetGeneration $TargetGeneration -Families $Families
    if (-not $row) { return $null }
    $source = Get-VmfSkuShape -SkuEntry $(if ($CatalogBySize.ContainsKey($SourceSize)) { $CatalogBySize[$SourceSize] } else { $null })
    if ($null -eq $source.Vcpus -or $null -eq $source.MemoryGB) { return $null }
    $fits = foreach ($name in @(Get-VmfCatalogSizeNames -CatalogBySize $CatalogBySize)) {
        $own = Get-VmfBurstableTarget -SizeName $name -Families $Families
        if (-not $own -or [string]$own.series -ne [string]$row.series) { continue }
        $shape = Get-VmfSkuShape -SkuEntry $CatalogBySize[$name]
        if ($null -eq $shape.Vcpus -or $null -eq $shape.MemoryGB) { continue }
        if ((Test-VmfSizeSmaller -Source $source -Target $shape) -ne 'fits') { continue }
        [pscustomobject]@{ Size = $name; Vcpus = [double]$shape.Vcpus; MemoryGB = $shape.MemoryGB }
    }
    # -Stable keeps the Get-VmfCatalogSizeNames order between equals.
    foreach ($f in @($fits | Sort-Object -Stable -Property Vcpus, MemoryGB)) {
        if (-not (& $Passes $f.Size)) { continue }
        return [ordered]@{ size = $f.Size; family = [string]$row.series; variant = 'default'; vcpus = [int]$f.Vcpus
            activeVcpus = [int]$f.Vcpus; memoryGB = $f.MemoryGB; best = $true }
    }
    $null
}

function Get-VmfSkuShape {
    <#
    .SYNOPSIS
        SIZE-FIT-1: a size's vCPUs and memory, from the SKU catalog. Either is
        $null when Azure did not report it.
    .DESCRIPTION
        vCPUs is the count the machine can USE: vCPUsAvailable where Azure
        reports it (a constrained size such as E8-4ds_v5 has 8 vCPUs and 4
        available), vCPUs otherwise.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][AllowNull()]$SkuEntry)
    $read = {
        param([string]$Name)
        if (-not $SkuEntry) { return $null }
        $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        if (-not $cap) { return $null }
        $value = 0.0
        if ([double]::TryParse([string]$cap.Value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref]$value)) { return $value }
        return $null
    }
    $vcpus = & $read 'vCPUsAvailable'
    if ($null -eq $vcpus) { $vcpus = & $read 'vCPUs' }
    [pscustomobject]@{ Vcpus = $vcpus; MemoryGB = (& $read 'MemoryGB') }
}

function Test-VmfSizeNameIsNotVcpus {
    <#
    .SYNOPSIS
        SIZE-FIT-1: is this a size whose NUMBER is not its vCPU count?
    .DESCRIPTION
        From v3 on, a D, E or A size's number is its vCPU count (D4s_v3 has 4),
        so its name twin in a newer version has the same shape. The older
        families number otherwise: D v1 and DS v1 (Standard_D4 has 8 vCPUs),
        Dv2 and DSv2 (Standard_D4_v2 has 8, Standard_D11_v2 has 2) with their
        constrained sizes (DS13-4_v2 has 8), and the Av2 memory sizes (A2m_v2).
        A1_v2 to A8_v2 are numbered by vCPU. Measured from the catalog, 2026-09-29. For these a
        name says nothing about the shape, so an unknown shape is not planned.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SizeName)
    $SizeName -match '^Standard_DS?\d+(-\d+)?(_v2)?(_Promo)?$' -or $SizeName -match '^Standard_A\d+m_v2$'
}

function Test-VmfSizeSmaller {
    <#
    .SYNOPSIS
        SIZE-FIT-1: is the target smaller than the machine's own size - fewer
        vCPUs, or less memory? Returns 'smaller', 'fits', or 'unknown'.
    .DESCRIPTION
        The default transform keeps a size's NUMBER and changes its version.
        From v3 on that number is the vCPU count, so the twin has the same
        shape. On Dv2 it is not: Standard_D4_v2 has 8 vCPUs and 28 GiB, and
        its name twin Standard_D4_v5 has 4 and 16. Planned by name, the machine
        would lose half its processors and more than a third of its memory, and
        nothing would say so. The shape is compared on every candidate.

        'unknown' when either size does not report what is compared - never
        read as a fit.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)]$Target
    )
    $known = $true
    foreach ($dim in 'Vcpus', 'MemoryGB') {
        if ($null -eq $Source.$dim -or $null -eq $Target.$dim) { $known = $false; continue }
        if ([double]$Target.$dim -lt [double]$Source.$dim) { return 'smaller' }
    }
    if ($known) { 'fits' } else { 'unknown' }
}

function Get-VmfSkuMaxNics {
    <#
    .SYNOPSIS
        NIC-1: how many network interfaces a size can hold, from the SKU
        catalog. Returns $null when Azure did not report the capability -
        callers must treat that as "cannot verify", never as "fits".
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()]$SkuEntry
    )

    if (-not $SkuEntry) { return $null }
    $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'MaxNetworkInterfaces' } | Select-Object -First 1
    if (-not $cap) { return $null }
    $value = 0
    if ([int]::TryParse([string]$cap.Value, [ref]$value)) { return $value }
    return $null
}

function Get-VmfCatalogSizeNames {
    <#
    .SYNOPSIS
        SIZE-TIE-1: a catalog's size names in one fixed order - every size
        with all its cores first, then the constrained-core sizes, each in
        ordinal order of the name.
    .DESCRIPTION
        A loop that keeps the FIRST of several equal sizes must walk the
        catalog in this order, never in the order of its keys. The catalog is
        a [hashtable], and .NET gives every process its own string hash seed,
        so the key order changes from one run to the next. The suggestion for
        a Standard_E8-4ds_v5 machine with 30 data disks was E16ds_v6, then
        E16-4ds_v6, then E16-8ds_v6, on three runs with one catalog: all three
        read as 16 vCPUs, and the first one met won.

        A constrained-core size (E16-4ds_v6) has fewer ACTIVE vCPUs than its
        name says and costs the same as the full size, so between equals it
        is never the default. Then ordinal order, never culture order: culture
        order differs between machines and can change with the platform, and
        ordinal order is a fact of the name alone.

        Ordinal order compares the CHARACTERS of the name, not the number in
        it: E32-16ds_v6 comes before E32-8ds_v6, because the character "1" is
        before "8". That matters only when the size with all its cores is not
        in the catalog. Kept as approved (2026-10-09); whether a suggestion
        between constrained-core sizes should prefer more or fewer active
        cores is a question in OWNER-QUESTIONS-1.
    .OUTPUTS
        string[] - empty for an empty or absent catalog.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()][hashtable]$CatalogBySize)
    if (-not $CatalogBySize -or $CatalogBySize.Count -eq 0) { return @() }
    $names = [string[]]@($CatalogBySize.Keys)
    [array]::Sort($names, [System.StringComparer]::Ordinal)
    # The same reading of "constrained" as Get-VmfReplacementSizeChoices.
    $full = [System.Collections.Generic.List[string]]::new()
    $constrained = [System.Collections.Generic.List[string]]::new()
    foreach ($name in $names) {
        if ($name -match '^Standard_[A-Za-z]+\d+-\d+') { $constrained.Add($name) } else { $full.Add($name) }
    }
    $full.AddRange($constrained)
    $full.ToArray()
}

function Get-VmfSmallestSizeForNics {
    <#
    .SYNOPSIS
        NIC-1: the cheapest size in the same series that can hold this many
        network interfaces. Turns a refusal into an answer.
    .DESCRIPTION
        Stays inside the source series (D2ds_v4 -> D*ds_v6) so the suggestion
        keeps the machine's capability letters - premium storage, local disk,
        AMD/Intel - rather than silently proposing a different kind of machine.
        Smallest by vCPU count, because that is the cheapest that fits.
        SIZE-TIE-1: between sizes with the same vCPU count, the first in
        Get-VmfCatalogSizeNames order - so the same answer on every run.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter(Mandatory)][int]$RequiredNics,
        [Parameter()][hashtable]$CatalogBySize = @{},
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # SIZE-FIT-1: a suggestion is never smaller than the machine either.
        [Parameter()][AllowNull()]$SourceShape
    )

    if ($SourceSize -notmatch '^Standard_([A-Za-z]+)\d+(?:-\d+)?([a-z]*)_v[2-6]$') { return $null }
    $series = $Matches[1]
    $letters = $Matches[2]

    $best = $null
    # SIZE-TIE-1: a fixed order, so "-lt" below keeps the same one of equals.
    foreach ($name in (Get-VmfCatalogSizeNames -CatalogBySize $CatalogBySize)) {
        if ($name -notmatch "^Standard_$series(\d+)(?:-\d+)?$letters`_$TargetGeneration$") { continue }
        $vcpuGuess = [int]$Matches[1]
        $maxNics = Get-VmfSkuMaxNics -SkuEntry $CatalogBySize[$name]
        if ($null -eq $maxNics -or $maxNics -lt $RequiredNics) { continue }
        if ($SourceShape -and (Test-VmfSizeSmaller -Source $SourceShape -Target (Get-VmfSkuShape -SkuEntry $CatalogBySize[$name])) -eq 'smaller') { continue }
        # DISKS-32-1: never a size the product may not move a machine onto
        # (the E104i v5 sizes, Test-VmfSizeApprovedTarget).
        if (-not (Test-VmfSizeApprovedTarget -SizeName $name -TargetGeneration $TargetGeneration -SourceSize $SourceSize).Approved) { continue }
        if (-not $best -or $vcpuGuess -lt $best.Vcpus) {
            $best = [pscustomobject]@{ Name = $name; MaxNics = $maxNics; Vcpus = $vcpuGuess }
        }
    }
    $best
}

function Get-VmfOneAcceleratedNicReason {
    <#
    .SYNOPSIS
        AN-ONE-NIC-1: the plan's words for the reason one-accelerated-nic, in
        one place - the name rules and the sizes chosen by shape both say
        it. Pure.
    .DESCRIPTION
        Row 31 of OWNER-QUESTIONS-1, option 2 (2026-10-10): NO bigger
        size is offered for this, as the target or as the fix - a 4-vCPU size
        doubles the price. The machine has no target until accelerated
        networking is off on the other interfaces and the machines are
        assessed again. Get-VmfSmallestSizeForAcceleratedNics, which named the
        next size up, was removed with that decision.
    .PARAMETER Sizes
        Each refused size as "<size> has <n> vCPUs".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$AcceleratedNicsAfter,
        [Parameter()][string[]]$Sizes = @()
    )
    ("after the move, $AcceleratedNicsAfter network interfaces of this machine have accelerated networking, and Azure allows it on one only " +
     "on a size with 2 vCPUs ($($Sizes -join '; ')) - turn off accelerated networking on the other network interfaces, then assess the machines again")
}

function Test-VmfSizeAllowsAcceleratedNics {
    <#
    .SYNOPSIS
        AN-ONE-NIC-1: does a size allow accelerated networking on this many
        network interfaces? Pure.
    .DESCRIPTION
        NIC-1, measured: Azure allows it on ONE network interface of a size
        with 2 vCPUs (VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable).
        Verdict:
          fits      - one interface or fewer, or a size with more than 2 vCPUs
          tooSmall  - more than one, on a size with 2 vCPUs
          unknown   - the catalog gives no vCPU count (or no row), or the size
                      is constrained to 2 active vCPUs: whether Azure counts
                      the vCPUs or the active ones is not measured. Never a fit.
        The same rule ROLLBACK-RETRY-CAPTURE-2 applies to a put-back size.
    .OUTPUTS
        @{ Verdict; Vcpus; Active } - Vcpus and Active are $null when the
        catalog does not give them.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter(Mandatory)][int]$Count
    )
    $read = {
        param([string]$Name)
        if (-not $SkuEntry) { return $null }
        $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
        $value = 0
        if ($cap -and [int]::TryParse([string]$cap.Value, [ref]$value)) { return $value }
        $null
    }
    $vcpus = & $read 'vCPUs'
    $active = & $read 'vCPUsAvailable'
    $verdict = if ($Count -le 1) { 'fits' }
               elseif ($null -eq $vcpus) { 'unknown' }
               elseif ($vcpus -le 2) { 'tooSmall' }
               elseif ($null -ne $active -and $active -le 2) { 'unknown' }
               else { 'fits' }
    [pscustomobject]@{ Verdict = $verdict; Vcpus = $vcpus; Active = $active }
}

function Get-VmfAcceleratedNicsAfterMove {
    <#
    .SYNOPSIS
        AN-ONE-NIC-1: on how many network interfaces accelerated networking
        is on after the move, from the scan. Pure.
    .DESCRIPTION
        Every move the product plans has the policy ensureOn (Get-VmfPolicy):
        the PRIMARY interface carries it, and every other interface keeps what
        it has (Get-VmfNicAnPlan) - the engine never turns one off. So the
        count is the interfaces with it now, plus the primary when it is off.
        A decision can turn it off later on AMD v5 only; PRECHECK then reads
        the policy, and the plan stays on the safe side. On a size that can
        give MANA it is always on (AN-MANA-DRIVER-RULE-1).

        $null when the scan cannot say: no count, or one interface on and the
        primary not read (the primary can be that one, or not). A count of two
        or more on is more than one whatever the primary is.

        AN-MANA-DRIVER-RULE-1: AN-ONE-NIC-2 also counted fewer where a kernel
        with no MANA driver kept the primary off (-KeptOffWithoutMana). No
        size keeps it off now, so one count holds on every size.
    .OUTPUTS
        int, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)]$Assessment
    )
    $vm = $Assessment
    $nics = if ($vm.PSObject.Properties['nicCount'] -and [int]$vm.nicCount -gt 0) { [int]$vm.nicCount } else { 1 }
    if ($nics -le 1) { return 1 }
    $count = if ($vm.PSObject.Properties['acceleratedNicCount'] -and $null -ne $vm.acceleratedNicCount) { [int]$vm.acceleratedNicCount } else { $null }
    $primary = if ($vm.PSObject.Properties['primaryNicAccelerated'] -and $null -ne $vm.primaryNicAccelerated) { [bool]$vm.primaryNicAccelerated } else { $null }
    if ($null -eq $count) { return $null }
    if ($null -ne $primary) {
        if ($primary) { return [Math]::Max($count, 1) }
        return $count + 1
    }
    if ($count -eq 0) { return 1 }
    if ($count -ge 2) { return $count }
    $null
}

function Get-VmfSmallestSizeForDisks {
    <#
    .SYNOPSIS
        DISK-3: the cheapest size in the same series that holds this many data
        disks. The disk twin of Get-VmfSmallestSizeForNics, with the same
        SIZE-TIE-1 tie-break.
    .DESCRIPTION
        DISKS-32-1 (a scope decision, 2026-10-05): no suggestion for more than
        32 data disks - such a machine is outside the scope of this tool - and
        never a size the product may not move a machine onto. The isolated
        E104i v5 sizes take 64, and an E64is_v3 machine kept its letters onto
        E104is_v5, which is ruled not to be offered.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$SourceSize,
        [Parameter(Mandatory)][int]$RequiredDataDisks,
        [Parameter()][hashtable]$CatalogBySize = @{},
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # SIZE-FIT-1: a suggestion is never smaller than the machine either.
        [Parameter()][AllowNull()]$SourceShape
    )

    if (Test-VmfTooManyDataDisks -Count $RequiredDataDisks) { return $null }
    if ($SourceSize -notmatch '^Standard_([A-Za-z]+)\d+(?:-\d+)?([a-z]*)_v[2-6]$') { return $null }
    $series = $Matches[1]
    $letters = $Matches[2]

    $best = $null
    # SIZE-TIE-1: a fixed order, so "-lt" below keeps the same one of equals.
    foreach ($name in (Get-VmfCatalogSizeNames -CatalogBySize $CatalogBySize)) {
        if ($name -notmatch "^Standard_$series(\d+)(?:-\d+)?$letters`_$TargetGeneration$") { continue }
        $vcpuGuess = [int]$Matches[1]
        $maxDisks = Get-VmfSkuMaxDataDisks -SkuEntry $CatalogBySize[$name]
        if ($null -eq $maxDisks -or $maxDisks -lt $RequiredDataDisks) { continue }
        if ($SourceShape -and (Test-VmfSizeSmaller -Source $SourceShape -Target (Get-VmfSkuShape -SkuEntry $CatalogBySize[$name])) -eq 'smaller') { continue }
        if (-not (Test-VmfSizeApprovedTarget -SizeName $name -TargetGeneration $TargetGeneration -SourceSize $SourceSize).Approved) { continue }
        if (-not $best -or $vcpuGuess -lt $best.Vcpus) {
            $best = [pscustomobject]@{ Name = $name; MaxDataDisks = $maxDisks; Vcpus = $vcpuGuess }
        }
    }
    $best
}

function Get-VmfSkuMaxDataDisks {
    <#
    .SYNOPSIS
        DISK-3: how many data disks a size can hold. $null when Azure did not
        report it - unknown must never read as "fits".
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$SkuEntry)

    if (-not $SkuEntry) { return $null }
    $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'MaxDataDiskCount' } | Select-Object -First 1
    if (-not $cap) { return $null }
    $value = 0
    if ([int]::TryParse([string]$cap.Value, [ref]$value)) { return $value }
    return $null
}

function Test-VmfSkuHasHostCache {
    <#
    .SYNOPSIS
        DISK-3: does this size have host caching hardware at all?
    .DESCRIPTION
        Measured in centralus: only 2 of 295 v6 sizes report CachedDiskBytes.
        Azure still ACCEPTS a caching setting on a size without it, so this is
        never a blocker - it is what lets the plan warn an operator that a
        cached disk will not actually be cached any more.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$SkuEntry)

    if (-not $SkuEntry) { return $false }
    [bool](@($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'CachedDiskBytes' })
}

function Get-VmfHostCacheNote {
    <#
    .SYNOPSIS
        DISK-3: plain-language warning when host-cached disks move to a size
        that has no host cache. Returns $null when there is nothing to say.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()]$DataDisks,
        [Parameter()][AllowNull()]$TargetSku
    )

    if (Test-VmfSkuHasHostCache -SkuEntry $TargetSku) { return $null }
    $cached = @(@($DataDisks) | Where-Object { [string]$_.caching -and [string]$_.caching -ne 'None' })
    if ($cached.Count -eq 0) { return $null }
    $names = @($cached | ForEach-Object { [string]$_.name }) -join ', '
    "These disks are set to use host caching and the new size has none, so they will read straight from storage: $names. The setting is kept, but expect different disk performance."
}

function Test-VmfDataDiskFidelity {
    <#
    .SYNOPSIS
        DISK-3: did every data disk come back on its own LUN, with its own
        cache mode? Pure comparison - the caller supplies both sides.
    .DESCRIPTION
        Matched by managed disk id, because ARM does not promise array order -
        the LUN is the contract. Applications, fstab entries and mount tooling
        address disks by LUN, so a shuffled LUN is silent damage: the machine
        runs, and the wrong disk is in the wrong place.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Captured,
        [Parameter()][AllowNull()]$Live
    )

    $was = @($Captured)
    $now = @($Live)
    if ($was.Count -ne $now.Count) {
        return [pscustomobject]@{
            Ok = $false
            Detail = "data disk count changed: the machine had $($was.Count) before the move and has $($now.Count) now"
        }
    }

    $liveById = @{}
    foreach ($d in $now) { $liveById[[string]$d.managedDiskId] = $d }

    foreach ($d in $was) {
        $id = [string]$d.managedDiskId
        $name = [string]$d.name
        if (-not $liveById.ContainsKey($id)) {
            return [pscustomobject]@{ Ok = $false; Detail = "data disk '$name' is missing after the move" }
        }
        $live = $liveById[$id]
        if ([int]$live.lun -ne [int]$d.lun) {
            return [pscustomobject]@{
                Ok = $false
                Detail = "data disk '$name' is on LUN $([int]$live.lun) but was on LUN $([int]$d.lun) - anything addressing it by LUN now points at the wrong disk"
            }
        }
        $wasCache = [string]$d.caching
        $nowCache = [string]$live.caching
        if ($wasCache -and $wasCache -ne $nowCache) {
            return [pscustomobject]@{
                Ok = $false
                Detail = "data disk '$name' has caching '$nowCache' after the move but had '$wasCache'"
            }
        }
    }

    [pscustomobject]@{ Ok = $true; Detail = "all $($was.Count) data disks returned on their original LUNs" }
}

function Get-VmfPrimaryNic {
    # The NIC carrying the default route. ARM reports Primary=$false on a
    # single-NIC VM, which is primary by definition - hence the fallback.
    param([Parameter()][AllowNull()]$Nics)
    $all = @($Nics)
    if ($all.Count -eq 0) { return $null }
    $flagged = @($all | Where-Object { [bool]$_.primary }) | Select-Object -First 1
    if ($flagged) { return $flagged }
    $all[0]
}

function Test-VmfSizeTakesAcceleratedNetworking {
    <#
    .SYNOPSIS
        OLD-FAM-1: can a size carry accelerated networking at all? The
        catalog's AcceleratedNetworkingEnabled: $true, $false, or $null when
        it does not say. B1s to B8ms, F1 and some Av2 sizes report False.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$SkuEntry)
    if (-not $SkuEntry) { return $null }
    $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'AcceleratedNetworkingEnabled' } | Select-Object -First 1
    if (-not $cap) { return $null }
    [string]$cap.Value -eq 'True'
}

function Get-VmfSourceAcceleratedNetworking {
    # OLD-FAM-1: what PRECHECK recorded for the machine's own size; $null when
    # the size catalog did not say.
    # -PutBack: ROLLBACK-RETRY-CAPTURE-1 - a put-back returns the machine to
    # the size of its FIRST capture, so it asks what THAT size can carry - and
    # only that (OLD-VERSION-READERS-REMOVE-4: never this attempt's answer in
    # its place). The move asks about the size this attempt found.
    param([Parameter()][AllowNull()]$Doc, [Parameter()][switch]$PutBack)
    $captured = Get-VmfRecordField -Object $Doc -Name 'captured'
    $from = if ($PutBack) { Get-VmfRecordField -Object $captured -Name 'original' } else { $captured }
    Get-VmfRecordField -Object $from -Name 'sourceAcceleratedNetworking'
}

function Get-VmfNicAnPlan {
    <#
    .SYNOPSIS
        NIC-1: which NICs to change accelerated networking on, and to what.
    .DESCRIPTION
        Accelerated networking is capped BY VM SIZE, not per NIC: a 2-vCPU
        size permits it on exactly one interface. Azure proves this at create
        time with VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable,
        and it would prove it again mid-conversion - inside the deallocated
        window, past the point of no return.

        So 'ensureOn' means the PRIMARY NIC carries accelerated networking,
        because that is what MANA binds to. Every other NIC keeps exactly
        what the capture recorded: this engine never tries to switch AN ON
        for a NIC that did not have it. 'preserve' changes nothing.
        OLD-VERSION-READERS-REMOVE-3: 'ensureOff', which turned every NIC off,
        left the plan contract at v33 (no writer gave it since v28), and any
        value but 'ensureOn' changes nothing.
    .OUTPUTS
        Zero or more @{ id; enabled } - only the NICs that need changing.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()]$CapturedNics,
        [Parameter(Mandatory)][string]$Policy
    )

    $nics = @($CapturedNics)
    if ($nics.Count -eq 0 -or $Policy -ne 'ensureOn') { return @() }

    $changes = [System.Collections.Generic.List[object]]::new()
    $primary = Get-VmfPrimaryNic -Nics $nics
    if ($primary -and -not [bool]$primary.acceleratedNetworking) {
        $changes.Add(@{ id = [string]$primary.id; enabled = $true })
    }
    $changes.ToArray()
}

function Test-VmfNicAcceleratedNetworking {
    <#
    .SYNOPSIS
        NIC-1: is accelerated networking where it should be after the move?
    .DESCRIPTION
        The primary must carry it when policy is ensureOn. Every other NIC
        must still have whatever it had - a NIC that silently LOST the
        capability is a regression, even though the engine never adds it.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Captured,
        [Parameter()][AllowNull()]$Live,
        [Parameter(Mandatory)][string]$Policy
    )

    if ($Policy -eq 'preserve') { return [pscustomobject]@{ Ok = $true; Detail = 'accelerated networking left as it was' } }

    $liveById = @{}
    foreach ($n in @($Live)) { $liveById[[string]$n.id] = $n }


    $primary = Get-VmfPrimaryNic -Nics $Captured
    if ($Policy -eq 'ensureOn' -and $primary) {
        $livePrimary = $liveById[[string]$primary.id]
        if (-not [bool]$livePrimary.acceleratedNetworking) {
            return [pscustomobject]@{
                Ok = $false
                Detail = "the main network interface '$(([string]$primary.id).Split('/')[-1])' does not have accelerated networking - MANA needs it"
            }
        }
    }

    foreach ($was in @($Captured)) {
        if (-not [bool]$was.acceleratedNetworking) { continue }
        $now = $liveById[[string]$was.id]
        if (-not [bool]$now.acceleratedNetworking) {
            return [pscustomobject]@{
                Ok = $false
                Detail = "network interface '$(([string]$was.id).Split('/')[-1])' had accelerated networking before the move and does not now"
            }
        }
    }

    [pscustomobject]@{ Ok = $true; Detail = 'accelerated networking is where it should be' }
}

function Test-VmfNicFidelity {
    <#
    .SYNOPSIS
        NIC-1: did every network interface come back, in the same order, with
        the same primary? Pure comparison - the caller supplies both sides.
    .DESCRIPTION
        Order matters: the guest names adapters in attach order, so a
        reordered set is a working VM with the wrong network identity. The
        primary NIC matters more still - it carries the default route.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Captured,
        [Parameter()][AllowNull()]$Live
    )

    $was = @($Captured)
    $now = @($Live)
    if ($was.Count -ne $now.Count) {
        return [pscustomobject]@{
            Ok = $false
            Detail = "network interface count changed: the machine had $($was.Count) before the move and has $($now.Count) now"
        }
    }

    for ($i = 0; $i -lt $was.Count; $i++) {
        $wasId = [string]$was[$i].id
        $nowId = [string]$now[$i].id
        if ($wasId -ne $nowId) {
            return [pscustomobject]@{
                Ok = $false
                Detail = "network interface order changed at position $($i + 1): expected '$($wasId.Split('/')[-1])' but found '$($nowId.Split('/')[-1])'"
            }
        }
        if ([bool]$was[$i].primary -ne [bool]$now[$i].primary) {
            return [pscustomobject]@{
                Ok = $false
                Detail = "the primary network interface changed: '$($wasId.Split('/')[-1])' was $(if ([bool]$was[$i].primary) { 'primary' } else { 'not primary' }) before the move"
            }
        }
    }

    [pscustomobject]@{ Ok = $true; Detail = "all $($was.Count) network interfaces returned in order" }
}

function Get-VmfPathSelection {
    <#
    .SYNOPSIS
        Select the migration path for one assessed VM (architecture section 8).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Assessment,
        # Empty for a machine with no target: GEN-V5-1 gives a Generation 1
        # machine no v6 size, and it is Blocked there, which is decided first.
        [Parameter(Mandatory)][AllowEmptyString()][AllowNull()][string]$TargetDiskArch,
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        # GEN-V5-1 C3: the classification for THIS series. Absent, the scan's own.
        [Parameter()][string]$Classification
    )

    $class = if ($Classification) { $Classification } else { [string]$Assessment.classification }
    if ($Assessment.platformManaged -or $class -eq 'Excluded') { return 'EXCLUDED' }
    if ($class -eq 'Blocked') { return 'MANUAL' }
    # Already there. For an NVMe series that is a machine already on NVMe, as
    # before. For v5 (SCSI) it is a machine already on a v5 size - a SCSI
    # controller says nothing about a v5 wave, since every source has one.
    if ((Get-VmfGenerationController -Generation $TargetGeneration) -eq 'NVMe') {
        if (Test-VmfAlreadyOnNvmeTarget -Assessment $Assessment) { return 'EXCLUDED' }   # READY-NOW-REMOVE-1: and on a Current size
    }
    elseif ((Get-VmfSizeGeneration -SizeName ([string]$Assessment.sourceSize)) -eq $TargetGeneration) { return 'EXCLUDED' }
    if ($Assessment.os -ne 'Windows') { return 'A' }
    # The same kind of temporary disk to Azure - and no temporary disk to an
    # NVMe one, which Azure moves in place with no feature (measured
    # 2026-11-07; Test-VmfTempDiskKindChanges says why).
    if (-not (Test-VmfTempDiskKindChanges -Assessment $Assessment -TargetDiskArch $TargetDiskArch)) { return 'A' }
    # REBUILD-REMOVE-PLAN-1 (2026-11-07): the rebuild around the same
    # disks (Path B) is removed. A Windows machine whose move changes the kind
    # of temporary disk takes the in-place upgrade (Preview) when its shape was
    # measured (Test-VmfPreviewShape) - Path A, which Azure allows only with
    # the preview feature VMTempDiskResizePreview on the subscription, and
    # which Checking reads before any change (Get-VmfPreviewFeatureGate). Any
    # other shape has no move: Resolve-VmfEntryTarget gives the reason
    # (Get-VmfNoInPlaceMove).
    if (Test-VmfPreviewShape -Assessment $Assessment -TargetDiskArch $TargetDiskArch) { return 'A' }
    return 'MANUAL'
}

function Get-VmfDefaultWavePolicy {
    <#
    .SYNOPSIS
        WAVE-2: the ONE set of safe defaults every wave starts from.
    .DESCRIPTION
        This replaces Get-VmfRingPolicy and its four-way lab/canary/nonprod/
        prod table. The ruling: lab, canary, prod and non-prod were invented
        terms that not every customer uses. Every decision is the customer's,
        made during migration planning; a wave can have any name, not one
        from a fixed list; and each setting is a lever to pull per wave.

        So there is no environment vocabulary left to hang defaults on, and
        none is needed: the safe end is the default for every wave, and every
        loosening is a deliberate act - the same principle the pristine-copy
        ruling set. These values were PROVISIONAL pending a
        per-lever pass (WAVE-2 phase C); what is NOT provisional is the shape:
        one set, no taxonomy, and nothing runs until a person has accepted the
        levers for their wave (Confirm-VmfWaveOptions - the engine refuses
        otherwise).

        PHASE C (decided 2026-08-28, lever by lever). These are DEFAULTS,
        not fixed policy: every one is adjustable per wave in the wave editor,
        and every one is shown to a person before they accept the wave.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][string]$CapacityGateOverride)

    $policy = @{
        # Not a lever: the failure model depends on it - the untouched copy is
        # what every rollback path goes back to.
        safetyCopy       = 'pristine'
        # Lever 3, ruled STOP - and per MACHINE, never the wave. The machine
        # with customer files on the temporary disk waits for a person; the rest of
        # the wave carries on. (NEEDS_DECISION is terminal for that machine and
        # is deliberately excluded from the circuit breaker, which counts
        # execution failures - a machine that stopped to ask a question did not
        # fail.)
        onDDataFound     = 'stop'
        # Lever 4, ruled STOP. A kernel below Microsoft's published floor is a
        # known, avoidable way to lose accelerated networking after the move.
        onDriverBelowFloor = 'stop'
        # Lever 7, ruled WIRE IT at 7 days. Read by Remove-VmfExpiredSafetyCopies;
        # a setting nothing enforces is a lie told in the acceptance screen.
        keepSnapshotDays = 7
        # Lever 1, ruled BEST EFFORT: check the target size looks available and
        # go. A wave that wants a held reservation sets Reserved.
        capacityGate     = 'BestEffort'
        # Lever 2, ruled ON. Accepting a wave's options says what it IS;
        # approval says it may RUN NOW. The two are different acts, and the
        # second is the one an operator does after reading the last wave's
        # report - so it defaults on, and a wave that omits the key is treated
        # as requiring it (fail safe, not fail open).
        requireApproval  = $true
        # Lever 8, ruled v6 by default with v7 opt-in per wave. The generation
        # used to be hard-coded in the size transform, so a customer whose
        # region has v7 had no way to say so - and the product never admitted it
        # was choosing for them.
        targetGeneration = 'v6'
        # SCALE-UX-1: how many machines at once, a lever of the wave rather
        # than a number typed at the last second. MACHINES-AT-ONCE-RANGE-1
        # (2026-11-06): Standard, 15 - one engine container. It was 3.
        throttle         = 15
    }
    # acceleratedNetworking is deliberately ABSENT and resolved per machine
    # (Get-VmfPolicy): ensureOn when the target is NVMe - lever 5, ruled ensure
    # on - and preserve for a SCSI reversion, where turning it on would be a
    # change nobody asked for. NIC-1 limits "on" to the primary interface.
    if ($CapacityGateOverride) { $policy.capacityGate = $CapacityGateOverride }
    $policy
}

function Get-VmfWaveAssignments {
    <#
    .SYNOPSIS
        Batch executable entries into waves named "wave-<n>" - neutral
        starting names the customer renames in the wave editor. WAVE-2: no
        environment vocabulary is generated anywhere.
    .PARAMETER Strategy
        WAVE-1: what keeps machines together, since a customer
        estate may carry no useful tags at all.
          tags          - app tag (the original behaviour); untagged machines stand alone
          resourceGroup - machines in one resource group migrate together
          singleWave    - everything in one wave, no size cap
          none          - assign nothing; every machine waits to be placed by
                          hand in the wave editor (WAVE-1 phase 2)
    .OUTPUTS
        Hashtable vmId -> wave name.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Entries,   # objects with vmId, appGroup, resourceGroup, availabilitySetId
        # WAVE-SIZE-REMOVE-1: no wave size. A group is one wave, whatever its
        # size; how many machines move at once is the wave's own setting.
        [Parameter()][ValidateSet('tags', 'resourceGroup', 'singleWave', 'none')][string]$Strategy = 'tags'
    )

    if ($Strategy -eq 'none') { return @{} }   # a blank canvas, composed by hand

    # Machines in one availability set ALWAYS share a wave, whatever the
    # strategy: they are a real dependency group, and the engine serialises
    # them anyway. Previously only an app tag held them together (WAVE-1).
    $groupKeyOf = {
        param($e)
        if ($e.availabilitySetId) { return "avset:$($e.availabilitySetId)" }
        switch ($Strategy) {
            'resourceGroup' { "rg:$($e.resourceGroup)" }
            'singleWave'    { 'all' }
            default         { "app:$($e.appGroup)" }
        }
    }

    $assignment = @{}
    $all = @($Entries)
    if ($all.Count -eq 0) { return $assignment }

    if ($Strategy -eq 'singleWave') {
        foreach ($e in $all) { $assignment[$e.vmId] = 'wave-1' }
        return $assignment
    }

    # WAVE-GROUP-1: ONE GROUP PER WAVE. A wave never holds two groups.
    #
    # This used to PACK: it kept a group from being split, then filled the wave
    # up with the next group, and the next, until the cap. MEASURED 2026-09-16
    # on three resource groups and four machines at the default cap of 25:
    # ONE wave holding all of them. Choosing "group by resource group" produced
    # no grouping at all, which a lab user saw as the wave build failing when
    # grouping by resource group.
    #
    # WAVE-SIZE-REMOVE-1 (2026-11-08): and a group is never CUT. There
    # was a "Most machines in one wave" cap (25) that cut a larger group into
    # consecutive waves. It was removed: the wave settings already hold the
    # concurrency tiers, and a wave of 40 machines is a fair choice. How many machines move at the same time is the wave's How
    # many machines at once (Pilot 5 to Maximum 60), and a wave of any size
    # runs that many at a time until every machine is done. So one group - a
    # tag value, a resource group or an availability set - is one wave.
    # The same estate must always make the same waves: the acceptance gate
    # binds an answer to the plan that was on screen (ACCEPT-HASH-1), so a wave
    # order that came out of the order the estate was READ in is not the same
    # plan twice. Group-Object already returns groups in name order, so this
    # sort changes nothing today and cannot be caught by a test - it is here so
    # the guarantee is stated rather than inherited from a behaviour nobody
    # wrote down. What holds it is the test that asserts the ORDER.
    $groups = @($all | Group-Object -Property { & $groupKeyOf $_ } | Sort-Object Name)
    $waveNum = 0
    foreach ($group in $groups) {
        $waveNum++
        foreach ($member in @($group.Group)) { $assignment[$member.vmId] = 'wave-{0}' -f $waveNum }
    }
    return $assignment
}


function Get-VmfWaveDurationEstimate {
    <#
    .SYNOPSIS
        SCHED-1 / arch section 9: how long a wave is likely to take, so a wave
        that cannot finish inside its maintenance window is never started.
    .DESCRIPTION
        Estimates from OBSERVED history first: machines this run has already
        migrated say more about this fleet than any table can. Only where
        there is no history does it fall back to published expectations -
        resize about 10 minutes, rebuild about 20 (architecture section 8) -
        and it keeps them separate, because a wave of rebuilds is not a wave
        of resizes.

        Machines run THROTTLE at a time, so the wall clock is roughly the
        total work divided by the throttle, plus a safety factor because an
        estimate that runs long inside a change window is the expensive kind
        of wrong.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Entries,          # plan entries for the wave
        [Parameter()]$StateDocs = @(),           # what this run has done so far
        [Parameter()][int]$Throttle = 3,
        [Parameter()][double]$SafetyFactor = 1.25
    )

    $defaults = @{ A = 10.0; B = 20.0; C = 30.0 }

    # observed minutes per path, from machines that actually finished
    $observed = @{}
    foreach ($doc in @($StateDocs)) {
        if ([string]$doc.state -ne 'MIGRATED') { continue }
        $secs = 0.0
        foreach ($h in @($doc.history)) { if ($h.durationSec) { $secs += [double]$h.durationSec } }
        if ($secs -le 0) { continue }
        $path = [string]$doc.path
        if (-not $path) { continue }
        if (-not $observed.ContainsKey($path)) { $observed[$path] = [System.Collections.Generic.List[double]]::new() }
        $observed[$path].Add($secs / 60.0)
    }

    $totalMinutes = 0.0
    $usedObserved = $false
    foreach ($e in @($Entries)) {
        $path = [string]$e.path
        if ($observed.ContainsKey($path) -and $observed[$path].Count -gt 0) {
            $avg = ($observed[$path] | Measure-Object -Average).Average
            $totalMinutes += $avg
            $usedObserved = $true
        }
        else { $totalMinutes += $(if ($defaults.ContainsKey($path)) { $defaults[$path] } else { $defaults['B'] }) }
    }

    $lanes = [math]::Max(1, [math]::Min($Throttle, @($Entries).Count))
    $wallClock = ($totalMinutes / $lanes) * $SafetyFactor

    [pscustomobject]@{
        Machines        = @($Entries).Count
        Throttle        = $lanes
        EstimateMinutes = [math]::Ceiling($wallClock)
        BasedOn         = $(if ($usedObserved) { 'what this run has already done' } else { 'expected times for this kind of move' })
    }
}

function Test-VmfSourceHasTempDisk {
    <#
    .SYNOPSIS
        GEN-V5-1: does the source size have a temporary disk? From the
        catalog's MaxResourceVolumeMB, or a 'd' in the name when there is no
        reading. Every v2 and v3 size has one and has no 'd' in its name, so
        only the catalog can say so for those - without it, the answer here is
        no. For a v3 size Get-VmfDefaultSizeCandidates then asks Microsoft's
        replacement table, which says every v3 size has one (V3-TEMPDISK-1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$SourceSize, [Parameter()][hashtable]$CatalogBySize = @{})

    $maxMb = $null
    if ($CatalogBySize.ContainsKey($SourceSize)) {
        $cap = @($CatalogBySize[$SourceSize].Capabilities) | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' } | Select-Object -First 1
        if ($cap) { $maxMb = [int64]$cap.Value }
    }
    (Get-VmfDiskArchitecture -SizeName $SourceSize -MaxResourceVolumeMB $maxMb) -ne 'diskless'
}

function Get-VmfSkuHyperVGenerations {
    <#
    .SYNOPSIS
        GEN-V5-1: the machine generations a size takes, from the catalog's
        HyperVGenerations capability ('V1,V2'). $null when Azure did not report it.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$SkuEntry)

    if (-not $SkuEntry) { return $null }
    $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'HyperVGenerations' } | Select-Object -First 1
    if (-not $cap -or [string]::IsNullOrWhiteSpace([string]$cap.Value)) { return $null }
    , @(([string]$cap.Value -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}