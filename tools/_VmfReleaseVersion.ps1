# The version a release names, in ONE place (PUBLIC-PIPELINE-1).
#
# A release is the module manifest's ModuleVersion, and README.md states the
# same number as "Version **x.y.z**" (DIST-1a: the README went stale once
# when 0.2.0 shipped). tools/New-VmfRelease.ps1 sets both with the pattern
# below, and the public repository's release workflow reads both through
# Get-VmfReleaseVersion before it tags. Two copies of the pattern would drift,
# and the copy that drifted would be the one nobody ran.

function Get-VmfReadmeVersionPattern {
    <#
    .SYNOPSIS
        The regular expression of README.md's version line for one version.
    #>
    param([Parameter(Mandatory)][string]$Version)
    "Version \*\*$([regex]::Escape($Version))\*\*"
}

function Get-VmfReleaseVersion {
    <#
    .SYNOPSIS
        The module version of the tree at -Root, after a check that it is
        three numbers and that README.md states it exactly once.
    #>
    param([Parameter(Mandatory)][string]$Root)
    $manifest = Join-Path $Root 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
    $number = [string](Import-PowerShellDataFile -LiteralPath $manifest).ModuleVersion
    if ($number -notmatch '^\d+\.\d+\.\d+$') {
        throw "The module version '$number' is not three numbers, so it cannot be a release tag."
    }
    $readme = Join-Path $Root 'README.md'
    $text = if (Test-Path -LiteralPath $readme -PathType Leaf) { [System.IO.File]::ReadAllText($readme) } else { '' }
    $found = @([regex]::Matches($text, (Get-VmfReadmeVersionPattern $number))).Count
    if ($found -ne 1) {
        throw "README.md states 'Version **$number**' $found time(s), and the manifest says $number. A release names one version: set the README line with tools/New-VmfRelease.ps1."
    }
    $number
}
