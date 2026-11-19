# SCOPE-DATA-1: which PLATFORM a machine may be moved onto.
#
# The planner already asked the region's catalogue whether a family has any v6
# or v7 size. That is the right question for AVAILABILITY and the wrong one for
# SCOPE, because it answers what Azure OFFERS rather than what Microsoft's
# migration guide APPROVES. Measured 2026-09-22:
#
#   Standard_D2ps_v5  family=D  familyInScope=True  target=Standard_D2ps_v6
#
# Both sizes are real. Both are Ampere ARM. Neither appears in any row of the
# guide's target-families table, which lists Intel and AMD only. A confidential
# machine went the same way: Standard_DC2as_v5 planned onto Standard_DC2as_v6,
# held back only by the security-type check, which needs discovery to have READ
# a security type.
#
# WHY THIS IS NOT A LIST OF SIZE NAMES: the table's middle column says
# "Examples", and Ddsv6 - the size most machines here land on - is not in it.
# An allowlist of those names would refuse the product's own primary path. What
# the table can enforce is its PLATFORM column, and a documented letter in the
# size name says which platform a size is on.
#
# Both facts live in data/target-families.json with the date they were read.

function Get-VmfTargetFamilyData {
    <#
    .SYNOPSIS
        Load the approved target platforms that ship with the module.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)

    if (-not $script:VmfTargetFamilies -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'target-families.json' }
        $script:VmfTargetFamilies = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfTargetFamilies
}

function Get-VmfSizeProcessor {
    <#
    .SYNOPSIS
        Which processor a size name says it runs on: Intel, AMD or ARM.
    .DESCRIPTION
        Read from the ADDITIVE FEATURE letters, which Azure documents: 'a' is
        an AMD-based processor and 'p' is an ARM-based processor. A name with
        neither letter is Intel. The letters sit between the vCPU count and the
        version, after any constrained-vCPU part: Standard_E8-4ds_v5 -> 'ds'.

        Returns $null when the name cannot be read. That is "cannot tell", and
        a caller must turn it into a question for a person - never into a pass.
    .OUTPUTS
        'Intel' / 'AMD' / 'ARM' / $null
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName,
        [Parameter()][AllowNull()]$Families
    )

    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    if ($SizeName -notmatch '^Standard_[A-Za-z]+\d+(?:-\d+)?([a-z]*)') { return $null }
    $letters = [string]$Matches[1]

    if (-not $Families) { $Families = Get-VmfTargetFamilyData }

    $found = @()
    foreach ($entry in $Families.processorLetters.PSObject.Properties) {
        if ($letters.IndexOf([string]$entry.Name, [System.StringComparison]::Ordinal) -ge 0) {
            $found += [string]$entry.Value
        }
    }
    $found = @($found | Select-Object -Unique)

    # Two platform letters in one name is a name nobody here understands. Say
    # so rather than picking whichever the data file happened to list first.
    if ($found.Count -gt 1) { return $null }
    if ($found.Count -eq 1) { return $found[0] }
    [string]$Families.defaultProcessor
}

function Get-VmfProcessorLetter {
    <#
    .SYNOPSIS
        AMD-SHAPE-1: the letter a size name carries for a processor - the
        reverse of Get-VmfSizeProcessor, from the same data: 'a' for AMD, ''
        for Intel (the default processor, which has no letter).
    .DESCRIPTION
        Used to build the size names of a processor, so a machine sized by
        shape keeps its processor maker: an AMD machine is offered D4ads_v5,
        never D4ds_v5. Returns $null for a processor the data does not name,
        and a caller must offer nothing for it - never the Intel names.
    .OUTPUTS
        string, or $null
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Processor,
        [Parameter()][AllowNull()]$Families
    )

    if ([string]::IsNullOrWhiteSpace($Processor)) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if ($Processor -eq [string]$Families.defaultProcessor) { return '' }
    foreach ($entry in $Families.processorLetters.PSObject.Properties) {
        if ([string]$entry.Value -eq $Processor) { return [string]$entry.Name }
    }
    $null
}

function Test-VmfSizeApprovedTarget {
    <#
    .SYNOPSIS
        May this product move a machine ONTO this size?
    .DESCRIPTION
        Two questions, both from data/target-families.json:
          - is its series one the guide lists at this generation (D and E, plus
            F at v7 for Fasv7)? This is what keeps the confidential DC and EC
            families out without needing a security type.
          - is its processor an approved platform (Intel or AMD, not ARM)?
        Anything unreadable is refused WITH THAT AS THE REASON, so nobody is
        told a machine is out of scope when the truth is nobody could tell.
    .OUTPUTS
        @{ Approved = <bool>; Why = <string|null> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName,
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        [Parameter()][AllowNull()]$Families,
        # BSV2-TARGET-1: the machine's own size. A burstable target (Bsv2) is
        # approved only for a machine on a size its row names as a source.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SourceSize
    )

    if (-not $Families) { $Families = Get-VmfTargetFamilyData }

    $series = Get-VmfSizeFamilyPrefix -SizeName $SizeName
    $processor = Get-VmfSizeProcessor -SizeName $SizeName -Families $Families

    if (-not $series -or -not $processor) {
        return @{ Approved = $false; Why = "unreadable: this product cannot read a series and a processor from the size name '$SizeName'" }
    }

    # DISKS-32-1 (a scope decision, 2026-10-05): the isolated E104i v5 sizes
    # (E104i, E104id, E104is, E104ids) are not offered. They were the only v5
    # sizes the product could choose that take 64 data disks, and they have 104
    # vCPUs; a machine with more than 32 data disks is outside the scope of
    # the product. Refused here, so no route - the default name, a size choice,
    # or a suggestion - can make one a target. Never refused as
    # the machine's OWN size (review): a machine already on E104is_v5 is not
    # moved onto it, and is told it is already on v5, as before.
    if ($SizeName -match '^Standard_E104i[a-z]*_v5$' -and $SizeName -ne $SourceSize) {
        return @{ Approved = $false; Why = "scope: $SizeName is outside the scope of this tool" }
    }

    # BSV2-TARGET-1 (2026-10-05): Bsv2 is a target of a B v1 machine
    # only, and only on the option whose rules it follows (v5). Any other B
    # size - B v1 itself, Basv2 (AMD), Bpsv2 (Arm64) - has no row, and is
    # refused below, because no target series lists the B family.
    $burstable = Get-VmfBurstableTarget -SizeName $SizeName -Families $Families
    if ($burstable) {
        $for = Get-VmfBurstableTargetFor -SourceSize $SourceSize -TargetGeneration $TargetGeneration -Families $Families
        if (-not $for -or [string]$for.series -ne [string]$burstable.series) {
            return @{ Approved = $false; Why = "series: $SizeName is a $($burstable.series) size, which the product offers only to a machine on a B v1 size, on $($burstable.option)" }
        }
        return @{ Approved = $true; Why = $null }
    }

    $allowedSeries = @($Families.seriesByGeneration.$TargetGeneration)
    if ($allowedSeries -notcontains $series) {
        return @{ Approved = $false; Why = "series: Microsoft does not list the $series family among its $TargetGeneration targets" }
    }

    if (@($Families.approvedProcessors) -notcontains $processor) {
        return @{ Approved = $false; Why = "processor: $SizeName has an $processor processor, and Microsoft lists only $(@($Families.approvedProcessors) -join ' and ') sizes as $TargetGeneration targets" }
    }

    @{ Approved = $true; Why = $null }
}

# GEN-V5-1: what a target series IS. Before v5 every target was NVMe, so code
# read "is the controller NVMe" as "is this a move onto new hardware". v5 is a
# SCSI target on hardware that can still give MANA, and on Intel D and Intel E
# it requires accelerated networking (E since 2026-10-01, DRIFT-5) - so each of those is its own fact, read from
# data/target-families.json, and none is inferred from another. Every v6 size
# requires it too, since 2026-10-27 (DRIFT-11), and no v7 size does.

function Get-VmfSizeGeneration {
    <#
    .SYNOPSIS
        The series version of a size name: Standard_D2ds_v5 -> 'v5'.
    .OUTPUTS
        'v2' .. 'v7', or $null for a name with no version (Standard_D2 is the
        first D series, and nothing here plans from or onto it).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName)

    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    if ($SizeName -match '^Standard_[A-Za-z]+\d+.*_v(\d+)$') { return "v$($Matches[1])" }
    $null
}

function Get-VmfGenerationTraits {
    <#
    .SYNOPSIS
        The recorded traits of a target series, or $null for one that is not a target.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Generation,
        [Parameter()][AllowNull()]$Families
    )

    if ([string]::IsNullOrWhiteSpace($Generation)) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    $Families.generations.$Generation
}

function Get-VmfGenerationController {
    <#
    .SYNOPSIS
        The disk controller a target series uses: v5 SCSI, v6 and v7 NVMe.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Generation,
        [Parameter()][AllowNull()]$Families
    )

    $traits = Get-VmfGenerationTraits -Generation $Generation -Families $Families
    if (-not $traits) { return $null }
    [string]$traits.controller
}

function Get-VmfTargetSizeFacts {
    # The three readings every target question starts from. $null when any of
    # them cannot be read, so each caller returns "cannot tell" the same way.
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)

    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    $traits = Get-VmfGenerationTraits -Generation (Get-VmfSizeGeneration -SizeName $SizeName) -Families $Families
    # BSV2-TARGET-1: a Bsv2 size has traits of its own, from its page. Its
    # name says v2, which is no target series.
    $burstable = Get-VmfBurstableTarget -SizeName $SizeName -Families $Families
    if ($burstable) { $traits = $burstable.traits }
    $series = Get-VmfSizeFamilyPrefix -SizeName $SizeName
    $processor = Get-VmfSizeProcessor -SizeName $SizeName -Families $Families
    if (-not $traits -or -not $series -or -not $processor) { return $null }
    @{ Traits = $traits; Series = $series; Processor = $processor }
}

function Test-VmfTargetRequiresAcceleratedNetworking {
    <#
    .SYNOPSIS
        Does Microsoft say this target size REQUIRES accelerated networking?
    .DESCRIPTION
        True for the Intel D and Intel E v5 sizes and for every D and E v6
        size, Intel and AMD - the rules are the lists
        generations.<series>.acceleratedNetworkingRequired in
        target-families.json. Intel E v5 joined on 2026-10-01, when Microsoft
        changed the Ev5, Esv5, Edv5 and Edsv5 pages from Supported to Required
        (DRIFT-5), and v6 on 2026-10-27, when it changed the sixteen D and E v6
        pages the same way (DRIFT-11). The v7 pages say Supported. Microsoft's
        v5 guide: "Enable Accelerated Networking on the source VM before you
        resize to a series that requires it". False for every other target size.
    .OUTPUTS
        $true / $false, or $null when the size is not in a target series or its
        name cannot be read. $null is never a no: a machine with accelerated
        networking off must not reach a resize Azure may refuse.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)

    $facts = Get-VmfTargetSizeFacts -SizeName $SizeName -Families $Families
    if (-not $facts) { return $null }
    foreach ($rule in @($facts.Traits.acceleratedNetworkingRequired)) {
        if ([string]$rule.series -ceq $facts.Series -and [string]$rule.processor -eq $facts.Processor) { return $true }
    }
    $false
}

function Test-VmfTargetMayUseMana {
    <#
    .SYNOPSIS
        Can this target size give a machine a MANA adapter?
    .DESCRIPTION
        Every v6 and v7 size can. On v5 the Intel sizes can (their pages list
        MANA among their interfaces) and the AMD sizes cannot. So the MANA
        driver question applies to a v5 move on Intel, and not on AMD.
    .OUTPUTS
        $true / $false, or $null when the size cannot be read.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)

    $facts = Get-VmfTargetSizeFacts -SizeName $SizeName -Families $Families
    if (-not $facts) { return $null }
    @($facts.Traits.manaProcessors) -contains $facts.Processor
}

function Get-VmfSizeLifecycleStage {
    <#
    .SYNOPSIS
        Microsoft's lifecycle stage for a size: Current, Extended, End of Life
        or Retired (A v1, OLD-FAM-4).
    .DESCRIPTION
        Read from the lifecycle table in data/target-families.json, which
        names a family, a basis ('stated' when Microsoft names the stage,
        'derived' when it follows from Microsoft's own definitions) and the
        page. Works for a SOURCE size as well as a target, so the advisor can
        show both sides of a move.
    .OUTPUTS
        @{ Stage; Basis; Source; How } or $null when the table does not cover
        the size. Microsoft says the stage differs by family; a family the
        table does not hold is not given one.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)

    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    # OLD-FAM-4: Basic_A0 to Basic_A4 are A v1, the same as Standard_A0 to A7.
    $SizeName = $SizeName -replace '^Basic_', 'Standard_'
    $generation = Get-VmfSizeGeneration -SizeName $SizeName
    # ADVISOR-1: the first sizes carry no version (Standard_D2, Standard_DS2).
    # Microsoft's End of Life list names them as the D-series and DS-series,
    # beside Dv1, so for the stage they are v1.
    if (-not $generation -and $SizeName -cmatch '^Standard_[A-Z]+\d+[a-z]*$') { $generation = 'v1' }
    $series = Get-VmfSizeFamilyPrefix -SizeName $SizeName
    if (-not $generation -or -not $series) { return $null }

    foreach ($row in @($Families.lifecycle.bySeries)) {
        if ([string]$row.family -ceq $series -and @($row.generations) -contains $generation) {
            return @{ Stage = [string]$row.stage; Basis = [string]$row.basis; Source = [string]$row.source; How = [string]$row.how }
        }
    }
    $null
}

function Test-VmfBurstableSize {
    <#
    .SYNOPSIS
        OLD-FAM-4: does this size run on CPU credits?
    .DESCRIPTION
        Microsoft's B family page: traditional sizes give fixed CPU
        performance, and the B series are the only sizes that use CPU credits
        (B v1, Bsv2, Basv2, Bpsv2). The families are data
        (target-families.json burstableFamilies). A name this cannot read is
        not burstable: a B size always reads.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)
    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $false }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    $family = Get-VmfSizeFamilyPrefix -SizeName $SizeName
    [bool]($family -and @($Families.burstableFamilies) -ccontains $family)
}

function Get-VmfSizeSeriesName {
    <#
    .SYNOPSIS
        V3-TEMPDISK-1: a size's series as Microsoft's tables write it -
        Standard_D4s_v3 -> 'Dsv3', Standard_E8-4ds_v6 -> 'Edsv6'.
    .OUTPUTS
        The series, or $null for a name with no version (Standard_D2).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName)
    if ($SizeName -match '^Standard_([A-Z]+)\d+(?:-\d+)?([a-z]*)_(v\d+)$') { return '{0}{1}{2}' -f $Matches[1], $Matches[2], $Matches[3] }
    $null
}

function Get-VmfSizeReplacement {
    <#
    .SYNOPSIS
        V3-TEMPDISK-1: the replacement row for a size's series
        (data/target-families.json replacements), or $null when there is
        none. The v3 rows are Microsoft's table; the AMD v4 rows are derived
        from their size pages (DAV4-TEMPDISK-1, basis 'derived'), and so are
        the Intel v4 rows for Dv4, Ddv4, Ev4 and Edv4 (V4-NAMES-1) and the
        Intel v5 rows for Dv5, Ddv5, Ev5 and Edv5 (V5-NAMES-1).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)
    $series = Get-VmfSizeSeriesName -SizeName $SizeName
    if (-not $series) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    foreach ($row in @($Families.replacements.bySeries)) {
        if (@($row.sourceSeries) -contains $series) { return $row }
    }
    $null
}

function ConvertTo-VmfCanonicalSizeName {
    # V5-SUCCESSOR-1: a size name as Microsoft's pages write it - the family in
    # upper case, the letters in lower case. Azure ignores case in a size name.
    # $null for a name with no version or that cannot be read.
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName)
    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    if ($SizeName -notmatch '^standard_([a-z]+)(\d+(?:-\d+)?)([a-z]*)_v(\d+)$') { return $null }
    'Standard_{0}{1}{2}_v{3}' -f $Matches[1].ToUpperInvariant(), $Matches[2], $Matches[3].ToLowerInvariant(), $Matches[4]
}

function Get-VmfMicrosoftSizeListing {
    <#
    .SYNOPSIS
        V5-SUCCESSOR-1: does Microsoft list a size of this name? Read from
        data/target-families.json microsoftSizes - the size names Microsoft's
        pinned pages list, with the page and the date they were read.
    .DESCRIPTION
        The planner keeps the letters of a size name and changes its version.
        When the region's catalog has no size of that name, that is a fact
        about the region OR a fact about Microsoft, and the two need different
        words: another region can have a size Microsoft lists, and no region
        has one Microsoft does not. This answers the second question, from
        data with a source - never from the catalog.

        Only for the sizes the data covers (covers: a family, its target
        series and its processors). For any other size it answers nothing
        ($null): unknown is never a yes or a no.
    .OUTPUTS
        @{ Listed = $true | $false | $null; Page = <page name, when listed>;
           ReadUtc = <date the pages were read, when covered> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName,
        [Parameter()][AllowNull()]$Families
    )
    $none = @{ Listed = $null; Page = $null; ReadUtc = $null }
    $name = ConvertTo-VmfCanonicalSizeName -SizeName $SizeName
    if (-not $name) { return $none }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if (-not $Families.PSObject.Properties['microsoftSizes']) { return $none }
    $ms = $Families.microsoftSizes
    $family = Get-VmfSizeFamilyPrefix -SizeName $name
    $generation = Get-VmfSizeGeneration -SizeName $name
    $processor = Get-VmfSizeProcessor -SizeName $name -Families $Families
    $covered = $false
    foreach ($c in @($ms.covers)) {
        if ([string]$c.family -ceq $family -and @($c.generations) -contains $generation -and @($c.processors) -contains $processor) { $covered = $true }
    }
    if (-not $covered) { return $none }
    $short = $name.Substring('Standard_'.Length)
    foreach ($pg in @($ms.pages)) {
        if (@($pg.sizes) -ccontains $short) { return @{ Listed = $true; Page = [string]$pg.page; ReadUtc = [string]$ms.readUtc } }
    }
    @{ Listed = $false; Page = $null; ReadUtc = [string]$ms.readUtc }
}

function Test-VmfIsolatedSize {
    <#
    .SYNOPSIS
        V5-SUCCESSOR-1: is this an isolated size? Microsoft's naming
        conventions page: the additive feature letter i is an isolated size
        (data/target-families.json microsoftSizes.isolatedLetter).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName,
        [Parameter()][AllowNull()]$Families
    )
    $name = ConvertTo-VmfCanonicalSizeName -SizeName $SizeName
    if (-not $name) { return $false }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if (-not $Families.PSObject.Properties['microsoftSizes']) { return $false }
    $letter = [string]$Families.microsoftSizes.isolatedLetter
    if (-not $letter -or $name -notmatch '^Standard_[A-Z]+\d+(?:-\d+)?([a-z]*)_v\d+$') { return $false }
    $Matches[1].IndexOf($letter, [System.StringComparison]::Ordinal) -ge 0
}

function Get-VmfMicrosoftIsolatedSizes {
    <#
    .SYNOPSIS
        V5-SUCCESSOR-1: the isolated sizes of a family that Microsoft's pages
        list on a target series, as Standard_ names in ordinal order. Empty
        when the data does not cover them.
    .DESCRIPTION
        SIZE-LISTING-V5-1: with -Processor, only the sizes of that processor
        (Get-VmfSizeProcessor). On v5 Microsoft lists isolated E sizes for
        Intel (E104i, E112ib) and for AMD (E112ia), and a machine keeps its
        processor maker, so an Intel machine is never told an AMD size.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][string]$TargetGeneration,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Processor,
        [Parameter()][AllowNull()]$Families
    )
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if (-not $Families.PSObject.Properties['microsoftSizes']) { return @() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($pg in @($Families.microsoftSizes.pages)) {
        foreach ($s in @($pg.sizes)) {
            $n = "Standard_$s"
            if ((Get-VmfSizeFamilyPrefix -SizeName $n) -ceq $Family -and (Get-VmfSizeGeneration -SizeName $n) -eq $TargetGeneration -and
                (Test-VmfIsolatedSize -SizeName $n -Families $Families) -and -not $names.Contains($n) -and
                (-not $Processor -or (Get-VmfSizeProcessor -SizeName $n -Families $Families) -eq $Processor)) { $names.Add($n) }
        }
    }
    $out = $names.ToArray()
    [array]::Sort($out, [System.StringComparer]::Ordinal)
    $out
}

function Get-VmfSizeSeriesReading {
    <#
    .SYNOPSIS
        The series of a size as this product's data writes it: the family, the
        letters after the size number, and the version, if any -
        Standard_D4s_v3 is Dsv3, Standard_E64is_v3 Eisv3, Standard_DS13-4_v2
        DSv2, Standard_B2ms Bms, Standard_B2ls_v2 Blsv2, Standard_D4 D,
        Basic_A2 A.
    .DESCRIPTION
        The one reading behind lifecycle.retirements sizeSeries (V3-RETIRE-1)
        and burstableTargets (BSV2-TARGET-1). Case is ignored, as Azure ignores
        it in a size name. OLD-FAM-4: the Basic tier (Basic_A0 to Basic_A4) is
        A v1 too.
    .OUTPUTS
        string, or $null for a name it cannot read.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName)
    if ([string]::IsNullOrWhiteSpace($SizeName)) { return $null }
    if ($SizeName -notmatch '^(?:Standard|Basic)_([A-Z]+)\d+(?:-\d+)?([a-z]*?)(?:_(v\d+))?(?:_Promo)?$') { return $null }
    '{0}{1}{2}' -f $Matches[1], $Matches[2], $Matches[3]
}

function Get-VmfBurstableTarget {
    <#
    .SYNOPSIS
        BSV2-TARGET-1: the burstable target series a size belongs to
        (data/target-families.json burstableTargets) - the Bsv2 row for
        Standard_B2s_v2, B2ls_v2 and B2ts_v2 - or $null.
    .DESCRIPTION
        Read by the size's series (Get-VmfSizeSeriesReading), never from a list
        of names: Basv2 (B2as_v2) and Bpsv2 (B2ps_v2) read as series of their
        own and have no row.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName, [Parameter()][AllowNull()]$Families)
    $read = Get-VmfSizeSeriesReading -SizeName $SizeName
    if (-not $read) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if (-not $Families.PSObject.Properties['burstableTargets']) { return $null }
    foreach ($row in @($Families.burstableTargets.series)) {
        if (@($row.sizeSeries) -contains $read) { return $row }
    }
    $null
}

function Get-VmfBurstableTargetFor {
    <#
    .SYNOPSIS
        BSV2-TARGET-1: the burstable target series offered to a machine on
        this size, on this option - the Bsv2 row for a B v1 machine on v5 -
        or $null.
    .DESCRIPTION
        Three questions, all answered by the row: is the machine's size one of
        its sources (B v1: Bls, Bs, Bms), is the option the one the row is
        offered on (v5, the rules Bsv2 follows), and does the machine keep its
        processor maker (AMD-SHAPE-1: B v1 is Intel, and so is Bsv2).
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SourceSize,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetGeneration,
        [Parameter()][AllowNull()]$Families
    )
    $read = Get-VmfSizeSeriesReading -SizeName $SourceSize
    if (-not $read -or -not $TargetGeneration) { return $null }
    if (-not $Families) { $Families = Get-VmfTargetFamilyData }
    if (-not $Families.PSObject.Properties['burstableTargets']) { return $null }
    $maker = Get-VmfSizeProcessor -SizeName $SourceSize -Families $Families
    foreach ($row in @($Families.burstableTargets.series)) {
        if (@($row.sourceSizeSeries) -contains $read -and [string]$row.option -eq $TargetGeneration -and [string]$row.processor -eq [string]$maker) { return $row }
    }
    $null
}