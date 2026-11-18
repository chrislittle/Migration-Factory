function Get-VmfVersion {
    <#
    .SYNOPSIS
        VERSION-1: which build of this product is running.
    .DESCRIPTION
        Until 2026-09-03 nothing in the product could say what version it was.
        The manifest said 0.1.0 and nothing read it; the engine image was
        tagged `dev`; the dashboard promised bug reports "with the page and
        version filled in" and filled in no version. Owner, asked how a
        customer would ever take an update: there was no answer, because there
        was nothing to update FROM.

        TWO FACTS, TWO SOURCES, ONE ANSWER.

        The NUMBER is the manifest's ModuleVersion - the one place a version
        was ever written, and the thing a release tag must equal (DIST-1).
        The BUILD is `build.json` beside the manifest, written by the install for every
        build and never committed: the commit it was built from and when. The
        version string is the two joined the way semver joins them:
        `0.1.0+1fee594`. A checkout with no stamp reads `0.1.0+local`, which
        is a true statement about it.

        A stamp that names a DIFFERENT number than the manifest is a packaging
        fault, and it is REPORTED rather than thrown: the manifest number is
        used, and `warning` says what disagreed. An endpoint that dies when
        asked its version is worse than one that answers with a caveat.
    .PARAMETER ModulePath
        The module directory holding the manifest and, when the install built it, the
        stamp. Defaults to this module's own. A parameter so the stamp logic
        can be tested against a copy without writing into the checkout.
    .OUTPUTS
        version   the full string, e.g. 0.1.0+1fee594
        number    the manifest's ModuleVersion
        build     the short commit, or 'local'
        commit    the full commit, or null
        builtUtc  when the install built it, or null
        source    'stamp' or 'local'
        warning   null, or one sentence when the stamp and manifest disagree
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][string]$ModulePath = $script:VmfModuleRoot
    )

    $manifestPath = Join-Path $ModulePath 'VmMigrationFactory.psd1'
    $manifest = Import-PowerShellDataFile -LiteralPath $manifestPath
    $number = [string]$manifest.ModuleVersion
    if (-not $number) { throw "The module manifest at $manifestPath has no ModuleVersion." }

    $stampPath = Join-Path $ModulePath 'build.json'
    $stamp = $null
    if (Test-Path -LiteralPath $stampPath) {
        $stamp = Get-Content -LiteralPath $stampPath -Raw | ConvertFrom-Json
    }

    $warning = $null
    $commit = $null
    $builtUtc = $null
    $build = 'local'
    $source = 'local'
    if ($stamp -and [string]$stamp.commit) {
        $commit = [string]$stamp.commit
        $build = $commit.Substring(0, [Math]::Min(7, $commit.Length))
        # ConvertFrom-Json turns an ISO timestamp into a [datetime], and
        # [string] on that gives '09/03/2026 12:00:00' - the reader's locale,
        # and no longer the ISO text the stamp held. Found by the first test run.
        # Put it back the way it was written: ISO 8601, UTC.
        $rawBuilt = if ($stamp.PSObject.Properties['builtUtc']) { $stamp.builtUtc } else { $null }
        $builtUtc = if ($rawBuilt -is [datetime]) { $rawBuilt.ToUniversalTime().ToString('o') }
                    elseif ($rawBuilt) { [string]$rawBuilt }
                    else { $null }
        $source = 'stamp'
        $stamped = if ($stamp.PSObject.Properties['moduleVersion']) { [string]$stamp.moduleVersion } else { '' }
        if ($stamped -and $stamped -ne $number) {
            $warning = "The build stamp was written for version $stamped and the manifest says $number. The manifest wins; the package was assembled from two revisions."
        }
    }

    [pscustomobject]@{
        version  = "$number+$build"
        number   = $number
        build    = $build
        commit   = $commit
        builtUtc = $builtUtc
        source   = $source
        warning  = $warning
    }
}
