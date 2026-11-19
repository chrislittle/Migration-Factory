# VF-UNMANAGED-CONFIG-1, 2026-11-14: does the network manager of a Linux
# machine leave the SR-IOV interface of accelerated networking unmanaged?
#
# Every move to a size that can give the MANA adapter turns accelerated
# networking on, also on a machine that had it off
# (Resolve-VmfAcceleratedNetworkingForMove). Azure then gives the machine an
# SR-IOV virtual function beside the synthetic interface. Microsoft
# (docs/upstream-docs/azure/virtual-network/accelerated-networking-overview.md,
# "Configure drivers to be unmanaged"): "Accelerated Networking requires
# configuring the SR-IOV drivers as unmanaged devices in your network
# settings. This requirement applies to the NVIDIA/Mellanox mlx4_core and
# mlx5_core drivers and to the MANA driver. Images using cloud-init version
# 23.2 or later automatically apply the correct network configuration to
# support Accelerated Networking during provisioning."
#
# The page gives the setting for two stacks, and this file judges only those:
#   NetworkManager    - the udev rule 10-azure-unmanaged-sriov.rules sets
#                       ENV{NM_UNMANAGED}="1" for DRIVERS=="mana|mlx4_core|
#                       mlx5_core". NetworkManager.conf(5) unmanaged-devices
#                       with driver:<name> (exact, no globbing) is the same
#                       setting written in NetworkManager itself.
#   systemd-networkd  - 255 or later: the same rule sets
#                       ENV{ID_NET_MANAGED_BY}="unmanaged". Below 255: the rule
#                       sets AZURE_UNMANAGED_SRIOV=1, and the file
#                       01-azure-unmanaged-sriov.network matches that property
#                       and sets Unmanaged=yes.
#   both              - cloud-init 23.2 or later, unless its network
#                       configuration is disabled (cloud-init docs, "Disabling
#                       network configuration"): then it applied none.
# A rule counts only when it names all three drivers Microsoft names: a rule
# for Mellanox alone leaves the MANA interface managed.
# Another stack (wicked, ifupdown) has no setting on Microsoft's page, so it is
# not judged, and the step line says so (VF-UNMANAGED-OTHER-STACKS-1).
#
# Guests report facts (sriov-unmanaged-check.sh); this file judges them. A
# fact that is missing is UNKNOWN, never "set".

$script:VmfSriovMicrosoftQuote = 'Microsoft says: "Accelerated Networking requires configuring the SR-IOV drivers as unmanaged devices in your network settings."'
$script:VmfSriovFactSeparator = ' ;; '

function Test-VmfCloudInitAppliesSriov {
    <#
    .SYNOPSIS
        Is this cloud-init version 23.2 or later, the version Microsoft names?
        PURE. A version it cannot read is not.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Version)
    $m = [regex]::Match([string]$Version, '^(\d+)\.(\d+)(\.\d+)?$')
    if (-not $m.Success) { return $false }
    $major = [int]$m.Groups[1].Value
    $minor = [int]$m.Groups[2].Value
    ($major -gt 23) -or ($major -eq 23 -and $minor -ge 2)
}

function Split-VmfSriovFactList {
    <#
    .SYNOPSIS
        One fact list of sriov-unmanaged-check.sh as its items: "<file>: <text>"
        each, or the path alone. "none" is no item. PURE.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Value)
    if (-not $Value -or $Value -eq 'none') { return @() }
    @($Value -split [regex]::Escape($script:VmfSriovFactSeparator) | Where-Object { $_ } | ForEach-Object {
        $at = $_.IndexOf(': ')
        if ($at -gt 0) { [pscustomobject]@{ File = $_.Substring(0, $at); Text = $_.Substring($at + 2) } }
        else { [pscustomobject]@{ File = $_; Text = '' } }
    })
}

# The facts of sriov-unmanaged-check.sh in the words an operator reads.
$script:VmfSriovFactWords = [ordered]@{
    cloudInitVersion   = 'the version of cloud-init'
    cloudInitNetwork   = 'the network configuration of cloud-init'
    sriovUdevLines     = 'the udev rules'
    nmUnmanagedDevices = 'the unmanaged-devices setting of NetworkManager'
    sriovNetworkFiles  = 'the systemd-networkd files'
    systemdVersion     = 'the version of systemd'
}

function Join-VmfSriovFactWords {
    <#
    .SYNOPSIS
        The names of missing facts as one phrase: "a", "a and b", "a, b and c". PURE.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][string[]]$Names = @())
    $words = @($Names | ForEach-Object { if ($script:VmfSriovFactWords.Contains($_)) { $script:VmfSriovFactWords[$_] } else { $_ } })
    if ($words.Count -le 1) { return ($words -join '') }
    (($words[0..($words.Count - 2)]) -join ', ') + ' and ' + $words[-1]
}

function Test-VmfSriovRuleNamesDrivers {
    <#
    .SYNOPSIS
        Does this udev rule line name the three drivers Microsoft names - mana,
        mlx4_core and mlx5_core? PURE.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowEmptyString()][string]$Line)
    ($Line -cmatch '(?<![A-Za-z0-9_])mana(?![A-Za-z0-9_])') -and ($Line -cmatch 'mlx4_core') -and ($Line -cmatch 'mlx5_core')
}

function Get-VmfSriovUnmanagedVerdict {
    <#
    .SYNOPSIS
        Do the network settings of this Linux machine leave the SR-IOV
        interface unmanaged, from the facts its guest reported? PURE.
    .DESCRIPTION
        Each active stack that Microsoft gives the setting for (NetworkManager,
        systemd-networkd) must have one of its markers (see the top of this
        file). Not one active: not judged. A fact that is missing, or an
        answer that is not READY: unknown, never set.
    .OUTPUTS
        @{ Verdict = 'set' | 'notSet' | 'notJudged' | 'unknown'; Detail = string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$GuestOutput)
    $unknown = { param($why) @{ Verdict = 'unknown'; Detail = "The product could not read the unmanaged setting for the drivers of accelerated networking. $why" } }
    if (-not $GuestOutput) { return (& $unknown 'The check in the machine sent no answer.') }
    if ([string]$GuestOutput.result -ne 'READY') {
        $err = if ($GuestOutput.PSObject.Properties['error'] -and $GuestOutput.error) { ": $($GuestOutput.error)" } else { '' }
        return (& $unknown "The check in the machine answered $($GuestOutput.result)$err.")
    }
    $facts = ConvertTo-VmfGuestFacts -GuestOutput $GuestOutput
    $has = { param($name) [bool]$facts.PSObject.Properties[$name] -and $null -ne $facts.$name -and [string]$facts.$name -ne '' }
    $fact = { param($name) if (& $has $name) { [string]$facts.$name } else { '' } }

    if (-not (& $has 'networkManager') -or -not (& $has 'networkd')) {
        return (& $unknown 'The check did not report the state of NetworkManager and systemd-networkd.')
    }
    $nmOn = (& $fact 'networkManager') -in $script:VmfActiveUnitStates
    $ndOn = (& $fact 'networkd') -in $script:VmfActiveUnitStates
    if (-not $nmOn -and -not $ndOn) {
        return @{ Verdict = 'notJudged'
                  Detail = "NetworkManager and systemd-networkd are not active on this machine. Microsoft shows the unmanaged setting only for these two. The product did not check the setting." }
    }

    # The facts each active stack needs. Missing is unknown.
    $need = @('cloudInitVersion', 'cloudInitNetwork', 'sriovUdevLines')
    if ($nmOn) { $need += 'nmUnmanagedDevices' }
    if ($ndOn) { $need += @('sriovNetworkFiles', 'systemdVersion') }
    $missing = @($need | Where-Object { -not (& $has $_) })
    if ($missing.Count) { return (& $unknown "The check did not report $(Join-VmfSriovFactWords -Names $missing).") }

    # cloud-init 23.2 or later, with its network configuration not disabled.
    $ciVersion = & $fact 'cloudInitVersion'
    $ciDisabled = (& $fact 'cloudInitNetwork') -eq 'disabled'
    $ciNew = Test-VmfCloudInitAppliesSriov -Version $ciVersion
    $ciCovers = $ciNew -and -not $ciDisabled
    $ciWords = if ($ciVersion -eq 'none') { 'cloud-init is not installed.' }
               elseif (-not [regex]::IsMatch($ciVersion, '^\d+\.\d+(\.\d+)?$')) { 'The product could not read the version of cloud-init.' }
               elseif ($ciDisabled) { "cloud-init version $ciVersion is installed. The network configuration of cloud-init is disabled." }
               elseif (-not $ciNew) { "cloud-init version $ciVersion is installed. Microsoft names version 23.2 or later." }
               else { '' }

    # The udev rule lines in force, by what they set. Each must name the three drivers.
    $rules = @(Split-VmfSriovFactList -Value (& $fact 'sriovUdevLines') | Where-Object { Test-VmfSriovRuleNamesDrivers -Line $_.Text })
    $nmRules = @($rules | Where-Object { $_.Text -cmatch 'ENV\{NM_UNMANAGED\}\s*:?=\s*"1"' })
    $ndRules = @($rules | Where-Object { $_.Text -cmatch 'ENV\{ID_NET_MANAGED_BY\}\s*:?=\s*"unmanaged"' })
    $propRules = @($rules | Where-Object { $_.Text -cmatch 'ENV\{AZURE_UNMANAGED_SRIOV\}\s*:?=\s*"1"' })
    $fileNames = { param($items) (@($items | ForEach-Object { $_.File } | Select-Object -Unique) -join ', ') }

    $found = [System.Collections.Generic.List[string]]::new()
    $notSet = [System.Collections.Generic.List[string]]::new()
    if ($ciCovers) { $found.Add("cloud-init version $ciVersion") }

    if ($nmOn) {
        $nmConf = @(Split-VmfSriovFactList -Value (& $fact 'nmUnmanagedDevices') | Where-Object {
            $tokens = @(($_.Text -split '[;,]') | ForEach-Object { $_.Trim() })
            [System.Linq.Enumerable]::Contains([string[]]$tokens, 'driver:mana', [System.StringComparer]::Ordinal) -and
            [System.Linq.Enumerable]::Contains([string[]]$tokens, 'driver:mlx4_core', [System.StringComparer]::Ordinal) -and
            [System.Linq.Enumerable]::Contains([string[]]$tokens, 'driver:mlx5_core', [System.StringComparer]::Ordinal)
        })
        if ($nmRules.Count) { $found.Add("the udev rule in $(& $fileNames $nmRules)") }
        if ($nmConf.Count) { $found.Add("the unmanaged-devices setting in $(& $fileNames $nmConf)") }
        if (-not $ciCovers -and -not $nmRules.Count -and -not $nmConf.Count) {
            $notSet.Add('This machine uses NetworkManager. The product found no udev rule that sets NM_UNMANAGED to 1 for the drivers mana, mlx4_core and mlx5_core. The product found no unmanaged-devices setting for these drivers.')
        }
    }
    if ($ndOn) {
        $sdText = & $fact 'systemdVersion'
        $sdVersion = 0
        $sdKnown = [int]::TryParse($sdText, [ref]$sdVersion)
        $netFiles = @(Split-VmfSriovFactList -Value (& $fact 'sriovNetworkFiles'))
        $nd255 = $sdKnown -and $sdVersion -ge 255 -and $ndRules.Count
        $ndOld = $propRules.Count -and $netFiles.Count
        if ($nd255) { $found.Add("the udev rule in $(& $fileNames $ndRules), on systemd-networkd $sdVersion") }
        if ($ndOld) { $found.Add("the udev rule in $(& $fileNames $propRules) and the file $(& $fileNames $netFiles)") }
        if (-not $ciCovers -and -not $nd255 -and -not $ndOld) {
            # One fact per sentence: the version, then each marker that is missing.
            $notSet.Add($(if ($sdKnown) { "This machine uses systemd-networkd version $sdVersion." } else { 'This machine uses systemd-networkd. The product could not read its version.' }))
            if ($sdKnown -and $sdVersion -ge 255) {
                $notSet.Add('The product found no udev rule that sets ID_NET_MANAGED_BY to unmanaged for the drivers mana, mlx4_core and mlx5_core.')
            }
            else {
                if (-not $propRules.Count) { $notSet.Add('The product found no udev rule that sets AZURE_UNMANAGED_SRIOV to 1 for the drivers mana, mlx4_core and mlx5_core.') }
                if (-not $netFiles.Count) { $notSet.Add('The product found no file 01-azure-unmanaged-sriov.network that sets Unmanaged=yes.') }
            }
        }
    }

    if ($notSet.Count) {
        $text = @('Accelerated networking is on after the move.', $script:VmfSriovMicrosoftQuote) + @($notSet) + @($ciWords) | Where-Object { $_ }
        return @{ Verdict = 'notSet'; Detail = ($text -join ' ') }
    }
    @{ Verdict = 'set'; Detail = "The network settings of this machine set the drivers of accelerated networking as unmanaged. The product found $($found -join ', and ')." }
}

function Get-VmfSriovUnmanagedAccepted {
    <#
    .SYNOPSIS
        Did an approver accept the move of this machine without the setting
        (onSriovUnmanagedMissing = proceed, by Resolve-VmfDecision)? PURE.
        Exactly 'proceed', compared ordinal: any other value is not.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$PlanEntry)
    if ($null -eq $PlanEntry -or $null -eq $PlanEntry.policy) { return $false }
    $value = if ($PlanEntry.policy -is [System.Collections.IDictionary]) { $PlanEntry.policy['onSriovUnmanagedMissing'] }
             elseif ($PlanEntry.policy.PSObject.Properties['onSriovUnmanagedMissing']) { $PlanEntry.policy.onSriovUnmanagedMissing }
             else { $null }
    $value -is [string] -and [string]::Equals($value, 'proceed', [System.StringComparison]::Ordinal)
}
