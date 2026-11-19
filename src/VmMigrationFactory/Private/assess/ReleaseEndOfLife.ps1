# EOL-RELEASE-AN-1 (decided 2026-11-14): is a Linux release past its
# vendor's end of standard support?
#
# Microsoft supports accelerated networking on every Azure endorsed Linux
# distribution "as long as the vendors don't mark them as end of life (EOL)"
# (accelerated-networking-overview, machines with Mellanox adapters). The
# support list goes by publisher, so each admitted release's standard end of
# support is data (data/linux-release-eol.json), read from the vendor's page.
#
# The vendors sell extended support after that date, so the product states the
# date and asks a person to accept it (Checking: linuxReleaseEndOfLife). It
# never refuses the machine, and never calls it unsupported.
#
# Only the release the Azure Linux Agent reports is past a date. An image is
# the lowest release a machine can run, so an image release past its date is
# unknown, never past.
#
# Pure: no Azure call.

function Get-VmfLinuxReleaseEolList {
    <#
    .SYNOPSIS
        The vendors' end of standard support of each admitted Linux release.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)
    if (-not $script:VmfLinuxReleaseEolList -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'linux-release-eol.json' }
        $script:VmfLinuxReleaseEolList = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfLinuxReleaseEolList
}

function Get-VmfLinuxReleaseEol {
    <#
    .SYNOPSIS
        @{ Status = 'past' | 'current' | 'unknown'; Row; Text } for a Linux
        release (Get-VmfLinuxRelease) on a day.
    .DESCRIPTION
        past     the Azure Linux Agent reports the release, and its standard
                 support ended before Now (at the end of the day or month the
                 vendor gives).
        current  its standard support has not ended. An image release that
                 has not ended is current: a release only goes up in place.
        unknown  no release, a release this data has no row for, a reading
                 with no minor where the vendor dates each minor, or an image
                 release that has ended.
        Text is the fact an operator reads, for past only.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Release,
        [Parameter()][datetime]$Now = [datetime]::UtcNow,
        [Parameter()][AllowNull()]$List
    )
    $unknown = @{ Status = 'unknown'; Row = $null; Text = $null }
    if (-not $Release -or -not [string]$Release.distroId -or -not [string]$Release.version) { return $unknown }
    $m = [regex]::Match(([string]$Release.version).Trim(), '^(\d+)(\.(\d+))?(\.\d+)*$')
    if (-not $m.Success) { return $unknown }
    $major = [int]$m.Groups[1].Value
    $minor = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $null }
    $l = if ($List) { $List } else { Get-VmfLinuxReleaseEolList }
    $rows = @(@($l.releases) | Where-Object { [string]$_.distroId -eq [string]$Release.distroId -and [int]$_.major -eq $major })
    $row = @($rows | Where-Object { $null -eq $_.minor }) | Select-Object -First 1
    if (-not $row -and $null -ne $minor) { $row = @($rows | Where-Object { $null -ne $_.minor -and [int]$_.minor -eq $minor }) | Select-Object -First 1 }
    if (-not $row) { return $unknown }

    $date = [string]$row.endOfStandardSupport
    $invariant = [System.Globalization.CultureInfo]::InvariantCulture
    $byDay = $date -match '^\d{4}-\d{2}-\d{2}$'
    $first = [datetime]::ParseExact($(if ($byDay) { $date } else { "$date-01" }), 'yyyy-MM-dd', $invariant, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    $end = if ($byDay) { $first.AddDays(1) } else { $first.AddMonths(1) }
    if ($Now.ToUniversalTime() -lt $end) { return @{ Status = 'current'; Row = $row; Text = $null } }
    if ([string]$Release.source -ne 'agent') { return $unknown }
    $when = if ($byDay) { 'on ' + $first.ToString('d MMMM yyyy', $invariant) } else { 'in ' + $first.ToString('MMMM yyyy', $invariant) }
    @{
        Status = 'past'; Row = $row
        Text = "$($row.vendor) ended standard support for $($row.label) $when. Microsoft supports accelerated networking only on releases that the vendor has not marked as end of life."
    }
}
