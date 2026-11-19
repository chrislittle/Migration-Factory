# TARGET-CAPABILITY-PRECHECK-1 (2026-11-14): a target size must support
# every feature the machine uses. Before this, the capture recorded encryption
# at host and Ultra Disk compatibility and only Verifying compared them - after
# the move. Nothing read the target size's capabilities, so Azure refused the
# resize in Moving, after the stop, and the rollback put the machine back and
# discarded every write since the first copy.
#
# Microsoft, lifecycle-overview.md, Modernize to newer sizes: "Make sure that
# the new size supports all features that your workload requires."
#
# Every answer comes from the size catalog the product already reads
# (Get-VmfSkuCatalog): no new Azure call. $true, $false, or $null when the
# catalog does not say - and $null is "cannot verify", never "fits" (NIC-1).
#
# PURE: no Azure call and no store read. The target advice, the plan and the
# wave editor ask through Resolve-VmfEntryTarget; Checking asks through
# Test-VmfTargetFeaturesReady (Private/engine/TargetFeatureGate.ps1).

function Get-VmfSkuCapabilityValue {
    # One capability of a catalog entry, as text, or $null when the entry does
    # not give it.
    param([AllowNull()]$Capabilities, [string]$Name)
    $cap = @(@($Capabilities) | Where-Object { $_ -and [string]$_.Name -eq $Name }) | Select-Object -First 1
    if ($cap) { [string]$cap.Value } else { $null }
}

function Test-VmfSkuEncryptionAtHost {
    <#
    .SYNOPSIS
        Does this size support encryption at host? The catalog capability
        EncryptionAtHostSupported. $null when the entry does not give it.
    .DESCRIPTION
        Microsoft, disk-encryption.md, Encryption at host restrictions: "VM
        size support varies by region and generation." So the answer is read
        from the region's catalog, never from the size name.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$SkuEntry)
    if (-not $SkuEntry) { return $null }
    $v = Get-VmfSkuCapabilityValue -Capabilities $SkuEntry.Capabilities -Name 'EncryptionAtHostSupported'
    if ($null -eq $v) { return $null }
    $v -eq 'True'
}

function Test-VmfSkuUltraDisk {
    <#
    .SYNOPSIS
        Does this size support Ultra Disks where the machine is? $true, $false,
        or $null when the catalog does not say.
    .DESCRIPTION
        Microsoft, disks-enable-ultra-ssd.md, Determine VM size and region
        availability, gives two reads:
        - A machine in an availability zone: the size's LocationInfo
          ZoneDetails for the region. "If there was no response from the
          command, then the selected VM size is not supported with Ultra
          Disks in the selected region." So a ZoneDetails list with no entry
          for the zone that says UltraSSDAvailable True is a no. A location
          entry that is not there, or ZoneDetails not given at all, is not a
          read, and stays unknown.
        - A machine with no zone ("VMs with no redundancy options"): the
          size's capability UltraSSDAvailable - "UltraSSDAvailable True
          indicates whether the VM size supports Ultra Disks in this region."
          That is Microsoft's own read for this case, so it is the one used.
          Not given is unknown.
    .PARAMETER Location
        The region. Only the LocationInfo entry for it is read.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter()][AllowEmptyString()][string]$Location
    )
    if (-not $SkuEntry) { return $null }
    if (-not $Zone) {
        $v = Get-VmfSkuCapabilityValue -Capabilities $SkuEntry.Capabilities -Name 'UltraSSDAvailable'
        if ($null -eq $v) { return $null }
        return ($v -eq 'True')
    }
    $flat = { param($s) ([string]$s -replace '\s', '').ToLowerInvariant() }
    $info = @(@($SkuEntry.LocationInfo) | Where-Object { $_ -and (& $flat $_.Location) -eq (& $flat $Location) }) | Select-Object -First 1
    if (-not $info -or $null -eq $info.ZoneDetails) { return $null }
    foreach ($detail in @($info.ZoneDetails)) {
        if (-not $detail -or @($detail.Name) -notcontains $Zone) { continue }
        if ((Get-VmfSkuCapabilityValue -Capabilities $detail.Capabilities -Name 'UltraSSDAvailable') -eq 'True') { return $true }
    }
    $false
}

# The disk types that need a size that supports Premium Storage (PremiumIO).
# Microsoft, disks-deploy-premium-v2.md: a Premium SSD v2 disk goes on "a VM in
# the same region and availability zone that supports Premium Storage"; an
# Ultra Disk needs Ultra Disk compatibility, which the machine's own setting
# asks above, and its size takes Premium Storage too. Premium SSD is not here:
# every target a machine with a Premium SSD disk can be given is an s size.
$script:VmfPremiumStorageDiskTypes = @('PremiumV2_LRS', 'UltraSSD_LRS')
# Azure's names for them, for the words.
$script:VmfPremiumStorageDiskWords = @{ PremiumV2_LRS = 'Premium SSD v2'; UltraSSD_LRS = 'Ultra Disk' }

function Get-VmfTargetFeatureGaps {
    <#
    .SYNOPSIS
        Each feature the machine uses that the target size does not support,
        or that the catalog does not say it supports. Empty: every feature
        fits, or the machine uses none. Pure.
    .PARAMETER EncryptionAtHost
        The machine uses encryption at host. Only $true asks the size.
    .PARAMETER UltraSsdEnabled
        The machine has Ultra Disk compatibility enabled. Only $true asks.
    .PARAMETER Disks
        The machine's disks with skuName and name (a capture). A Premium SSD v2
        or Ultra Disk asks the size for Premium Storage.
    .OUTPUTS
        @{ feature = 'encryptionAtHost' | 'ultraDisk' | 'premiumStorage';
           supported = $false | $null; disk; diskType } for each gap.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][bool]$EncryptionAtHost,
        [Parameter()][bool]$UltraSsdEnabled,
        [Parameter()][AllowNull()][object[]]$Disks = @(),
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter()][AllowEmptyString()][string]$Location
    )
    $gaps = [System.Collections.Generic.List[object]]::new()
    if ($EncryptionAtHost) {
        $s = Test-VmfSkuEncryptionAtHost -SkuEntry $SkuEntry
        if ($s -ne $true) { $gaps.Add([pscustomobject]@{ feature = 'encryptionAtHost'; supported = $s; disk = $null; diskType = $null }) }
    }
    if ($UltraSsdEnabled) {
        $s = Test-VmfSkuUltraDisk -SkuEntry $SkuEntry -Zone $Zone -Location $Location
        if ($s -ne $true) { $gaps.Add([pscustomobject]@{ feature = 'ultraDisk'; supported = $s; disk = $null; diskType = $null }) }
    }
    $premiumDisks = @(@($Disks) | Where-Object { $_ -and [string]$_.skuName -in $script:VmfPremiumStorageDiskTypes })
    if ($premiumDisks.Count) {
        $s = Test-VmfDiskPremiumCapable -SkuEntry $SkuEntry
        if ($s -ne $true) {
            foreach ($d in $premiumDisks) {
                $gaps.Add([pscustomobject]@{ feature = 'premiumStorage'; supported = $s; disk = [string]$d.name; diskType = [string]$d.skuName })
            }
        }
    }
    @($gaps)
}

function Get-VmfFeaturePlace {
    # Where the machine is, for the words: "zone 2 of centralus", or the region.
    param([AllowNull()][AllowEmptyString()][string]$Zone, [AllowEmptyString()][string]$Location)
    if ($Zone) { "zone $Zone of $Location" } else { $Location }
}

function Get-VmfTargetFeatureOffer {
    <#
    .SYNOPSIS
        For the target advice, the plan and the wave editor: the code and the
        reason of the first gap, or $null. The code is what the targets step
        puts in words; the reason is what a plan records in planNotes.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object[]]$Gaps = @(),
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter()][AllowEmptyString()][string]$Location
    )
    $first = @($Gaps | Where-Object { $_ }) | Select-Object -First 1
    if (-not $first) { return $null }
    switch ([string]$first.feature) {
        'encryptionAtHost' {
            @{ Code = 'no-encryption-at-host'
                Reason = "This machine uses encryption at host. Azure does not say that the size $Size supports encryption at host, so the product does not offer this size." }
        }
        'ultraDisk' {
            @{ Code = 'no-ultra-disk'
                Reason = ("This machine has Ultra Disk compatibility enabled. Azure does not say that the size $Size supports Ultra Disks in " +
                          "$(Get-VmfFeaturePlace -Zone $Zone -Location $Location), so the product does not offer this size.") }
        }
        default { $null }
    }
}

function Get-VmfTargetFeatureDetail {
    <#
    .SYNOPSIS
        For Checking: one sentence for each gap, naming the feature and the
        size - and whether the size does not support it, or Azure does not say.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$Gaps,
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter()][AllowEmptyString()][string]$Location
    )
    $place = Get-VmfFeaturePlace -Zone $Zone -Location $Location
    $lines = foreach ($g in @($Gaps | Where-Object { $_ })) {
        $no = $g.supported -eq $false
        switch ([string]$g.feature) {
            'encryptionAtHost' {
                if ($no) { "This machine uses encryption at host, and the size $Size does not support it." }
                else { "This machine uses encryption at host, and Azure does not say whether the size $Size supports it." }
            }
            'ultraDisk' {
                if ($no) { "This machine has Ultra Disk compatibility enabled, and the size $Size does not support Ultra Disks in $place." }
                else { "This machine has Ultra Disk compatibility enabled, and Azure does not say whether the size $Size supports Ultra Disks in $place." }
            }
            'premiumStorage' {
                $type = if ($script:VmfPremiumStorageDiskWords.ContainsKey([string]$g.diskType)) { $script:VmfPremiumStorageDiskWords[[string]$g.diskType] } else { [string]$g.diskType }
                if ($no) { "The disk '$($g.disk)' has the type $type, and the size $Size does not support Premium Storage." }
                else { "The disk '$($g.disk)' has the type $type, and Azure does not say whether the size $Size supports Premium Storage." }
            }
        }
    }
    @($lines) -join ' '
}
