# The method of a move (REBUILD-PICKER-1, TEMP-DISK-PREVIEW-1,
# REBUILD-REMOVE-PLAN-1).
#
# A move is the in-place upgrade (Path A: the VM is changed where it stands),
# or the in-place upgrade (Preview): Path A for a Windows machine whose move
# changes the kind of temporary disk, which Azure allows only with the preview
# feature VMTempDiskResizePreview registered on the subscription. The product's
# own nouns (PATH-NAME-1).
#
# REBUILD-REMOVE-PLAN-1 (2026-11-07): the rebuild around the same disks
# (Path B) is removed. No plan and no target option gives it. A move whose
# shape nobody measured has no path at all (MANUAL, with the reason): that is
# never worse than a rebuild, which deleted the VM definition.
#
# The method is recorded in target-choices.json (v8) and on each plan entry's
# target.choice (v29): in-place or preview. An earlier file can hold rebuild;
# it is read, and never written.
#
# PURE: no Azure call and no store read.

# TEMP-DISK-PREVIEW-1: the preview feature that lets Azure resize a machine in
# place across the kinds of temporary disk. MEASURED 2026-11-01, 2026-11-02 and
# 2026-11-07 (docs/research/temp-disk-in-place-preview.md): with it registered
# on the subscription, Azure accepted the in-place resize forward and back on
# 23 shapes; without it, the same resize was refused (OperationNotAllowed).
$script:VmfPreviewFeatureNamespace = 'Microsoft.Compute'
$script:VmfPreviewFeatureName = 'VMTempDiskResizePreview'

function Get-VmfPreviewFeatureName {
    <# TEMP-DISK-PREVIEW-1: the namespace and the name of the preview feature, in one place. #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()
    @{ Namespace = $script:VmfPreviewFeatureNamespace; Name = $script:VmfPreviewFeatureName }
}

function Get-VmfAssessedGeneration {
    # The machine's Hyper-V generation as the scan read it: the plan's copy of
    # the assessment records it as 'gen', the scan as gen or hyperVGeneration.
    # '' when neither was read - never a guess.
    param([AllowNull()]$Assessment)
    if (-not $Assessment) { return '' }
    if ($Assessment.PSObject.Properties['gen'] -and [string]$Assessment.gen) { return [string]$Assessment.gen }
    if ($Assessment.PSObject.Properties['hyperVGeneration']) { return [string]$Assessment.hyperVGeneration }
    ''
}

function Test-VmfTempDiskKindChanges {
    <#
    .SYNOPSIS
        REBUILD-REMOVE-PLAN-1: does this move change the kind of temporary disk
        of a Windows machine? Pure.
    .DESCRIPTION
        The moves Azure refuses in place without the preview feature
        (RESIZE-RULE-1, and the control of 2026-11-01: OperationNotAllowed,
        "changing from resource disk to non-resource disk VM size and vice-versa
        is not allowed"). These were the rebuilds until the rebuild was removed.
        A Linux machine is upgraded in place across them (Path A), as before.
        A kind the scan did not read is not the target's kind, so it counts as
        a change: unknown is never read as "the same".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Assessment,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetDiskArch
    )
    if (-not $Assessment) { return $false }
    if ([string]$Assessment.os -ne 'Windows') { return $false }
    $from = [string]$Assessment.sourceDiskArch
    # MEASURED 2026-11-07 (docs/research/temp-disk-in-place-preview.md): a
    # Windows machine with no temporary disk moved in place to a v6 or v7 size
    # with an NVMe temporary disk AND BACK, with the feature NOT registered -
    # six shapes, Intel and AMD. The rollback of each was an NVMe temporary
    # disk to none. Azure reports that NVMe disk as MaxResourceVolumeMB 0, the
    # same as a size with none, so to Azure the kind does not change, either
    # way: a plain in-place upgrade, no feature.
    $pair = @($from, [string]$TargetDiskArch)
    if (($pair -contains 'diskless') -and ($pair -contains 'nvme-temp')) { return $false }
    $from -ne [string]$TargetDiskArch
}

function Test-VmfPreviewShape {
    <#
    .SYNOPSIS
        TEMP-DISK-PREVIEW-1: is this machine of the shape that the preview
        feature VMTempDiskResizePreview moves in place? Pure.
    .DESCRIPTION
        REBUILD-REMOVE-PLAN-1: the shapes that were measured, and no other.
        Windows, a size with a SCSI temporary disk, and:
          Generation 2   to an NVMe temporary disk or to none (v5, v6, v7, Bsv2)
          Generation 1   to no temporary disk (v5, Bsv2) - Generation 1 takes no
                         v6 or v7 size (GEN-V5-1), so it never reaches NVMe
        Measured on F, A v2, D v2, Dv4 and Dasv4 sources, Windows Server 2016 to
        2025. With no target kind named, the source alone is asked. A machine
        whose generation the scan did not read is not of the shape: unknown is
        never a yes. Linux is upgraded in place without the feature.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Assessment,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetDiskArch
    )
    if (-not $Assessment) { return $false }
    $gen = Get-VmfAssessedGeneration -Assessment $Assessment
    if (([string]$Assessment.os -ne 'Windows') -or ([string]$Assessment.sourceDiskArch -ne 'scsi-temp')) { return $false }
    if ($gen -eq 'V2') { return (-not $TargetDiskArch) -or ($TargetDiskArch -in @('nvme-temp', 'diskless')) }
    if ($gen -eq 'V1') { return (-not $TargetDiskArch) -or ($TargetDiskArch -eq 'diskless') }
    $false
}

function Get-VmfTempDiskKindWords {
    # The kind of temporary disk, in the words the screens use.
    param([AllowNull()][AllowEmptyString()][string]$Kind)
    switch ($Kind) {
        'scsi-temp' { 'a SCSI temporary disk' }
        'nvme-temp' { 'an NVMe temporary disk' }
        'diskless'  { 'no temporary disk' }
        default     { 'a kind of temporary disk that the scan did not read' }
    }
}

function Get-VmfNoInPlaceMove {
    <#
    .SYNOPSIS
        REBUILD-REMOVE-PLAN-1: why a Windows machine whose move changes the
        kind of temporary disk has no move - @{ Code; Reason } - or $null when
        the in-place upgrade (Preview) moves it. Pure.
    .DESCRIPTION
        The reason is the target's: a plan records a machine it does not move
        with its reason in planNotes, and the targets step shows the code.
        generation-unknown             the scan did not read the generation
        temp-disk-change-not-measured  any other shape nobody measured
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Assessment,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$TargetDiskArch,
        [Parameter()][string]$TargetGeneration = 'v6'
    )
    if (-not (Test-VmfTempDiskKindChanges -Assessment $Assessment -TargetDiskArch $TargetDiskArch)) { return $null }
    if (Test-VmfPreviewShape -Assessment $Assessment -TargetDiskArch $TargetDiskArch) { return $null }
    $gen = Get-VmfAssessedGeneration -Assessment $Assessment
    if ([string]$Assessment.sourceDiskArch -eq 'scsi-temp' -and $gen -notin @('V1', 'V2')) {
        return @{ Code = 'generation-unknown'
            Reason = ("The scan did not read the generation of this machine. Its move to $TargetGeneration changes the kind of temporary disk, " +
                      'and the product moves it in place only when the generation is known. Scan the machine again.') }
    }
    $from = Get-VmfTempDiskKindWords -Kind ([string]$Assessment.sourceDiskArch)
    $to = Get-VmfTempDiskKindWords -Kind $TargetDiskArch
    @{ Code = 'temp-disk-change-not-measured'
        Reason = ("On $TargetGeneration, this Windows machine changes from $from to $to. " +
                  'The product moves a machine in place only, and it has no measured in-place upgrade for that change, so it does not move this machine.') }
}

function Get-VmfMoveMethod {
    <#
    .SYNOPSIS
        The method of a move: 'preview' for the in-place upgrade that needs
        the preview feature (TEMP-DISK-PREVIEW-1), 'in-place' for every other
        move. Pure.
    .DESCRIPTION
        From the fact the rules recorded (Resolve-VmfEntryTarget Preview),
        never worked out again from size names. REBUILD-REMOVE-PLAN-1: no move
        is a rebuild.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][switch]$Preview)
    if ($Preview) { 'preview' } else { 'in-place' }
}

function Get-VmfEntryMethod {
    <#
    .SYNOPSIS
        REBUILD-PICKER-1 / TEMP-DISK-PREVIEW-1: the method a plan entry
        records (target.choice.method), or '' for an entry older than v23 or
        one with no choice. Reads a plan entry from JSON or one being built. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Entry)
    if (-not $Entry -or -not $Entry.target) { return '' }
    $choice = if ($Entry.target -is [System.Collections.IDictionary]) { $Entry.target['choice'] }
              elseif ($Entry.target.PSObject.Properties['choice']) { $Entry.target.choice } else { $null }
    if (-not $choice) { return '' }
    if ($choice -is [System.Collections.IDictionary]) { return [string]$choice['method'] }
    if ($choice.PSObject.Properties['method']) { return [string]$choice.method }
    ''
}