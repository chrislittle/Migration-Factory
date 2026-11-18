# IMAGE-SCRIPT-MATCH-1, part 2: is a Linux machine's release on Microsoft's
# list of Linux images that support NVMe?
#
# Microsoft's page enable-nvme-interface lists them ("Supported Linux OS
# images"). Windows follows the Windows half of that page
# (windows-version-below-2019); before this, Linux was asked only for its
# publisher and Azure's DiskControllerTypes, which says what an image CAN do,
# not what is supported (IMAGE-1).
#
# The release is the one the VM agent reports, else the image's - the order
# OSVER-1 uses for the Windows version (Get-VmfLinuxRelease). An image release
# is the lowest release the machine can run: an update in place takes Red Hat
# 8.4 to 8.10. So an image release below a listed minor of its major is
# UNKNOWN, as Get-VmfManaReleaseListing reads the MANA table.
#
# Pure: no Azure call. The list is data/nvme-linux-releases.json.

function Get-VmfNvmeLinuxList {
    <#
    .SYNOPSIS
        Microsoft's list of Linux releases that support NVMe, as shipped.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)
    if (-not $script:VmfNvmeLinuxList -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'nvme-linux-releases.json' }
        $script:VmfNvmeLinuxList = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfNvmeLinuxList
}

function Get-VmfNvmeLinuxListing {
    <#
    .SYNOPSIS
        'listed', 'unlisted' or 'unknown': is this Linux release on Microsoft's
        NVMe list?
    .DESCRIPTION
        unknown   no release, no distribution, a version that is not a number;
                  a reading with no minor release where its major needs one;
                  an IMAGE release below a listed minor of its major.
        unlisted  every other release that no row lists.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Release,
        [Parameter()][AllowNull()]$List
    )
    if (-not $Release -or -not [string]$Release.distroId -or -not [string]$Release.version) { return 'unknown' }
    $m = [regex]::Match(([string]$Release.version).Trim(), '^(\d+)(\.(\d+))?(\.\d+)*$')
    if (-not $m.Success) { return 'unknown' }
    $major = [int]$m.Groups[1].Value
    $minor = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $null }
    $l = if ($List) { $List } else { Get-VmfNvmeLinuxList }
    $rows = @(@($l.releases) | Where-Object { [string]$_.distroId -eq [string]$Release.distroId -and [int]$_.major -eq $major })
    foreach ($row in $rows) {
        if ($null -eq $row.minor) { return 'listed' }
        if ($null -eq $minor) {
            # Every minor release of the major: "9.0 and newer".
            if ([bool]$row.andNewer -and [int]$row.minor -eq 0) { return 'listed' }
            continue
        }
        if ($minor -eq [int]$row.minor -or ([bool]$row.andNewer -and $minor -gt [int]$row.minor)) { return 'listed' }
    }
    if ($rows.Count) {
        if ($null -eq $minor) { return 'unknown' }
        $later = @($rows | Where-Object { [int]$_.minor -gt $minor })
        if ([string]$Release.source -eq 'image' -and $later.Count) { return 'unknown' }
    }
    # Review, 2026-11-15: an image is the lowest release the machine can run,
    # and a machine can be upgraded in place to a release on the list. So an
    # image release whose major has no row is unknown too; only the release
    # the Azure Linux Agent reports is unlisted.
    elseif ([string]$Release.source -eq 'image') { return 'unknown' }
    'unlisted'
}

function Get-VmfLinuxDistroName {
    <#
    .SYNOPSIS
        The name an operator reads for an os-release ID: the name Microsoft's
        NVMe page uses.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$DistroId)
    $names = @{
        ubuntu = 'Ubuntu'; rhel = 'RHEL'; sles = 'SLES'; debian = 'Debian'; ol = 'Oracle Linux'
        almalinux = 'AlmaLinux'; rocky = 'Rocky Linux'; azurelinux = 'Azure Linux'; centos = 'CentOS'
    }
    if ($names.ContainsKey([string]$DistroId)) { return $names[[string]$DistroId] }
    [string]$DistroId
}

function Get-VmfLinuxNvmeJudgement {
    <#
    .SYNOPSIS
        IMAGE-SCRIPT-MATCH-1: the listing of a scanned Linux machine, with the
        note the assessment records. @{ Listing; Release; Note }.
    .DESCRIPTION
        Reads the machine as Resource Graph gives it to the scan: osName and
        osVersionRunning from the VM agent, imagePublisher, imageOffer and
        imageSku from the image reference.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    $field = { param([string]$Name) if ($Vm.PSObject.Properties[$Name]) { [string]$Vm.$Name } else { '' } }
    $release = Get-VmfLinuxRelease -Vm ([pscustomobject]@{
            os = 'Linux'
            runningOsName = (& $field 'osName'); runningOsVersion = (& $field 'osVersionRunning')
            imagePublisher = (& $field 'imagePublisher'); imageOffer = (& $field 'imageOffer'); osVersion = (& $field 'imageSku')
        })
    $listing = Get-VmfNvmeLinuxListing -Release $release
    $note = $null
    if ($release) { $name = "$(Get-VmfLinuxDistroName -DistroId $release.distroId) $($release.version)" }
    switch ($listing) {
        'unlisted' {
            $from = if ([string]$release.source -eq 'agent') { 'The Azure Linux Agent reports this release.' } else { 'The Azure Linux Agent reports no release. The product reads the release from the image of the machine.' }
            $note = "This machine runs $name. Microsoft does not list this release among the Linux images that support NVMe. $from"
        }
        'unknown' {
            if (-not $release) { $note = 'The scan cannot read the Linux release of this machine.' }
            elseif ([string]$release.source -eq 'image' -and -not @(@((Get-VmfNvmeLinuxList).releases) | Where-Object { [string]$_.distroId -eq [string]$release.distroId -and [string]$_.major -eq ([string]$release.version -split '\.')[0] }).Count) {
                $note = "The image of this machine is $name. Microsoft does not list this release among the Linux images that support NVMe. The Azure Linux Agent reports no release."
            }
            elseif ([string]$release.source -eq 'image' -and [string]$release.version -match '\.') {
                $major = ([string]$release.version -split '\.')[0]
                $note = "The image of this machine is $name. Microsoft lists a later release of $(Get-VmfLinuxDistroName -DistroId $release.distroId) $major among the Linux images that support NVMe. The Azure Linux Agent reports no release."
            }
            else { $note = "The scan reads $name, with no minor release. The scan cannot compare this release with the list of Linux images that support NVMe." }
        }
    }
    @{ Listing = $listing; Release = $release; Note = $note }
}
