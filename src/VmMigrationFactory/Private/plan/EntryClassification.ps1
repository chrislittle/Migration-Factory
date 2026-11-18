# GEN-V5-1 C3: the scan records facts; the PLAN judges them against the size
# series the wave chose.
#
# Before v5 every blocker blocked every target, so the scan could decide
# "Blocked" once and the plan could trust it. v5 takes Generation 1 machines,
# keeps Azure Disk Encryption and has no NVMe, so four of the scan's blockers
# do not apply to it. Each reason in data/assessment-reasons.json names the
# series it applies to (appliesTo), and this is the one place that reads it.

function Get-VmfAssessmentReasonData {
    <#
    .SYNOPSIS
        Load the assessment reasons that ship with the module.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param()

    if (-not $script:VmfAssessmentReasons) {
        $file = Join-Path $script:VmfModuleRoot 'data' 'assessment-reasons.json'
        $script:VmfAssessmentReasons = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfAssessmentReasons
}

function Resolve-VmfEntryClassification {
    <#
    .SYNOPSIS
        A machine's classification for ONE size series, from the reasons the
        scan recorded.
    .DESCRIPTION
        Keeps the blockers and prep items that apply to the series, and
        classifies from those. A code the data does not know applies to every
        series: a reason from a newer scan is not a pass.

        BSV2-TARGET-1 (review): -TargetDiskArch, once the target size is
        known. On v5 the page file moves too when the temporary disk goes
        away (GUEST_PREP moves it on a scsi-resize to a size with none) - onto
        a Bsv2 size, or onto a v5 size with no d (D4s_v5 for a v3 machine).
        The data names v6 and v7 for 'pagefile', where every Windows machine
        that has one loses it; on v5 that depends on the size, so it is
        decided here. migrations.html judgeForSeries applies the same rule,
        and tests/fixtures/prep-by-target.json holds both to it.
    .OUTPUTS
        @{ Classification; Blockers = @(...); Prep = @(...) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Assessment,
        [Parameter()][ValidateSet('v5', 'v6', 'v7')][string]$TargetGeneration = 'v6',
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetDiskArch
    )

    $reasons = Get-VmfAssessmentReasonData
    $applies = {
        param($group, $code)
        $entry = $reasons.$group.PSObject.Properties[[string]$code]
        if (-not $entry -or -not $entry.Value.PSObject.Properties['appliesTo']) { return $true }
        @($entry.Value.appliesTo) -contains $TargetGeneration
    }

    $blockers = @(@($Assessment.blockers) | Where-Object { $_ -and (& $applies 'blockers' $_) })
    $prep = @(@($Assessment.prepNeeded) | Where-Object { $_ -and (& $applies 'prep' $_) })
    if ($TargetGeneration -eq 'v5' -and $TargetDiskArch -and $TargetDiskArch -ne 'scsi-temp' -and
        @($Assessment.prepNeeded) -contains 'pagefile' -and $prep -notcontains 'pagefile') { $prep += 'pagefile' }

    $own = [string]$Assessment.classification
    $classification =
        if ($own -eq 'Excluded' -or $Assessment.platformManaged) { 'Excluded' }
        elseif ($blockers.Count -gt 0) { 'Blocked' }
        # Blocked by the scan, for reasons that do not apply here. The same
        # rule the scan uses for a machine with no blocker at all.
        elseif ($own -eq 'Blocked') { 'ReadyAfterPrep' }
        else { $own }

    @{ Classification = $classification; Blockers = $blockers; Prep = $prep }
}

function Test-VmfAlreadyOnNvmeTarget {
    <#
    .SYNOPSIS
        READY-NOW-REMOVE-1: true when a machine already on NVMe has no move to
        an NVMe series (v6, v7).
    .DESCRIPTION
        A machine on NVMe has a move to v6 or v7 when the lifecycle data puts
        its size in a stage that is not Current: Ebsv5 and Ebdsv5 are
        Extended. Microsoft's Eb family page lists Ebsv6 and Ebdsv6 beside
        them, with "higher remote storage performance compared to the
        previous generation", but no page calls Ebsv6 or Ebdsv6 their
        replacement (EB-COMMENT-1; target-families.json, V5-SUCCESSOR-1,
        says the same). A machine on a
        Current size (v6, v7) is already there. A size the data holds no stage
        for gets no move: unknown is not a yes. The stage comes from
        Get-VmfSizeLifecycleStage, never from the size name. A machine on SCSI
        is never already there.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Assessment)
    if ([string]$Assessment.diskController -ne 'NVMe') { return $false }
    $stage = Get-VmfSizeLifecycleStage -SizeName ([string]$Assessment.sourceSize)
    (-not $stage) -or [string]$stage.Stage -eq 'Current'
}
