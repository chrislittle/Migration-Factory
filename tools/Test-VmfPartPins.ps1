<#
.SYNOPSIS
    DEPS-CURRENT-1: each outside part the repository uses matches its pin, and
    none is missing from the pin file.

.DESCRIPTION
    infra/part-versions.json pins every part the product ships that does not
    update by itself. This check reads the repository, with no network:

      - every reference to a pinned part names the pinned version: each
        Dockerfile FROM, each Bicep registry module and extension, each saved
        library file in src/dashboard (by its sha256), and each test tool
        version in the scripts the pin names;
      - every outside part the repository references is in the pin file,
        either pinned or listed under updatesItself with the reason it takes
        its own fixes. Without this, the daily watch covers only the parts that
        existed on the day it was written. PINS-COVER-2 added a Functions
        extension bundle in a host.json, a container image in a template, a
        template parameters file or a workflow job, and every .js, .mjs and
        .css file in src/dashboard and docs/manual that ownFiles does not list
        as a file the repository wrote;
      - every file on ownFiles is there, and none is also a pinned part's file;
      - every pinned part is still used, so the file holds no dead entry;
      - no pin is under its floor (minimumVersion): the first release that
        fixes the advisories its minimumWhy names (MANUAL-MERMAID-1).

    tests/unit/PartPins.Tests.ps1 runs it on the repository and fails on any
    finding. The daily upstream-drift run reads the pins and reports a newer
    version (tools/Test-VmfPartPinDrift.ps1).

.PARAMETER Root
    The repository. Defaults to the one this script is in.

.PARAMETER PinPath
    The pin file. Defaults to infra/part-versions.json under -Root.

.EXAMPLE
    ./tools/Test-VmfPartPins.ps1
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [string]$PinPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_VmfPartPins.ps1')
$Root = [System.IO.Path]::GetFullPath($Root)
if (-not $PinPath) { $PinPath = Join-Path $Root 'infra' 'part-versions.json' }

$pin = Read-VmfPartPins -Path $PinPath
$refs = Find-VmfOutsidePartReferences -Root $Root
$findings = Test-VmfPartPinsAgainst -Root $Root -Pin $pin -References $refs

if ($findings.Count) {
    foreach ($f in $findings) { Write-Host "PART PIN ($($f.kind)) $($f.key) in $($f.path): $($f.detail)" }
}
else {
    Write-Host "Every outside part matches its pin: $(@($pin.parts).Count) pinned, $($refs.Count) references read."
}

[pscustomobject]@{
    Parts      = @($pin.parts).Count
    References = $refs
    Findings   = $findings
}
