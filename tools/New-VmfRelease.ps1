<#
.SYNOPSIS
    DIST-1a: prepare a release - set the version and commit it.
.DESCRIPTION
    THE NORMAL WAY TO RELEASE IS THE BUTTON, not this script: Actions ->
    Release -> Run workflow, and type the number. Since 2026-09-08, a release
    needs nobody to run a script by hand.

    This is what the button RUNS. The rules that refuse a release live here,
    in one place, so the workflow and a person cutting one by hand cannot
    apply different ones - and the copy that drifted would be the one nobody
    ran.

    A release is a tag whose name equals the manifest's ModuleVersion, and
    README.md states the same number. Doing that by hand is edits in places
    that must agree, and the release refuses a tag when they do not.

    This makes the two agree by construction, and stops before anything
    outward-facing: it does NOT tag, run the checks or push.
    VERSION-BUMP-TESTED-TREE-1 (2026-11-20): it used to run the checks and
    then change the version, so the commit it tagged was one no check had run
    on, and tests/unit/Readme.Tests.ps1 failed on it. Now the button's
    tools/New-VmfReleaseTag.ps1 checks that CI passed on the head of main
    first, runs this to commit the version on top of that exact commit, and
    pushes and tags it (RELEASE-FLOW-RESTORE-1).

    IT REFUSES rather than repairs. A dirty tree, a branch that is not main, a
    version that does not move forward, or a tag that already exists all stop
    it, because each one produces a release that says something untrue about
    what is in it.
.PARAMETER Version
    The new version, e.g. 0.2.0. Below 1.0.0 the contract can still change,
    which is what the release marks itself as. 1.0.0 is the one number with a
    promise in it: the schemas, the cmdlet names and the install path are
    stable.
.PARAMETER AllowBranch
    Prepare from a branch other than main. For rehearsing the steps; a release
    that ships must come from main, which is the history CI judges.
.EXAMPLE
    ./tools/New-VmfRelease.ps1 -Version 0.2.0
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [switch]$AllowBranch
)

$ErrorActionPreference = 'Stop'
# PUBLIC-PIPELINE-1: the README line's pattern is shared with the public
# repository's release workflow, which refuses a README that disagrees.
. (Join-Path $PSScriptRoot '_VmfReleaseVersion.ps1')
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$manifest = Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
# The README states the version too, and it went stale the moment 0.2.0 shipped
# - a review found it there. A number written by hand in a second place is a
# number that is wrong, so this sets both and a test compares them.
$readme = Join-Path $repoRoot 'README.md'
$tag = "v$Version"

function Assert-GitOk([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "git failed ($LASTEXITCODE): $Step" }
}

# --- 1. refuse anything that would make the release describe itself wrongly ---
$branch = git -C $repoRoot rev-parse --abbrev-ref HEAD
Assert-GitOk 'read the branch'
if ($branch -ne 'main' -and -not $AllowBranch) {
    throw "Releases come from main, and this is '$branch'. Merge first, or pass -AllowBranch to rehearse."
}

$dirty = git -C $repoRoot status --porcelain
Assert-GitOk 'read the working tree'
if ($dirty) {
    throw "The working tree has changes, so the tag would not describe what is committed:`n$dirty"
}

$existing = git -C $repoRoot tag --list $tag
Assert-GitOk 'list tags'
if ($existing) { throw "The tag $tag already exists. A released version is never re-cut; choose the next number." }

$current = (Import-PowerShellDataFile $manifest).ModuleVersion
if ([version]$Version -le [version]$current) {
    throw "The manifest is already at $current, so $Version does not move forward. A version that goes backwards makes every stamp ambiguous."
}

# --- 2. set and commit ------------------------------------------------------
# No check runs here (VERSION-BUMP-TESTED-TREE-1): CI already passed on the
# commit this goes on top of, and this changes only the version.
if ($PSCmdlet.ShouldProcess("$current -> $Version", 'set the module version and commit it')) {
    Write-Host "1/2 setting ModuleVersion to $Version..."
    $text = Get-Content $manifest -Raw
    $pattern = "ModuleVersion(\s*)= '$([regex]::Escape($current))'"
    if (@([regex]::Matches($text, $pattern)).Count -ne 1) {
        throw "The manifest does not state ModuleVersion = '$current' exactly once, so it cannot be set safely by this script."
    }
    $text = [regex]::Replace($text, $pattern, "ModuleVersion`$1= '$Version'")
    Set-Content $manifest -Value $text -Encoding utf8NoBOM -NoNewline

    $readmeText = Get-Content $readme -Raw
    $readmePattern = Get-VmfReadmeVersionPattern $current
    if (@([regex]::Matches($readmeText, $readmePattern)).Count -ne 1) {
        throw "README.md does not state Version **$current** exactly once, so it cannot be set safely by this script."
    }
    $readmeText = [regex]::Replace($readmeText, $readmePattern, "Version **$Version**")
    Set-Content $readme -Value $readmeText -Encoding utf8NoBOM -NoNewline

    Write-Host "2/2 committing $tag..."
    git -C $repoRoot add -- $manifest $readme
    Assert-GitOk 'stage the manifest'
    git -C $repoRoot commit -m "Release $tag"
    Assert-GitOk 'commit the version'

    Write-Host ''
    Write-Host "Committed the version $Version. Nothing is tagged or pushed."
    Write-Host 'The Release button pushes this commit to main and tags it.'
    Write-Host ''
}
