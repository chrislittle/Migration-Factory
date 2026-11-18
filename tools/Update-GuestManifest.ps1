<#
.SYNOPSIS
    Regenerate src/guest/manifest.json from the files on disk.
.DESCRIPTION
    Reads each guest script, extracts its declared version ($script:VERSION / VERSION=),
    computes sha256, and rewrites the manifest. Run after ANY edit under src/guest.
    CI fails if the manifest drifts from the files.
#>
[CmdletBinding()]
param(
    [string]$GuestRoot = (Join-Path $PSScriptRoot '..' 'src' 'guest')
)

$ErrorActionPreference = 'Stop'
$GuestRoot = [System.IO.Path]::GetFullPath($GuestRoot)

function Get-DeclaredVersion {
    param([string]$Path)
    $content = Get-Content $Path -Raw
    if ($content -match "\`$script:VERSION\s*=\s*'(\d+\.\d+\.\d+)'") { return $Matches[1] }
    # Bash scripts MUST use VMF_VERSION - plain VERSION gets clobbered when
    # sourcing /etc/os-release (which defines VERSION). Caught by the P0-5 drill.
    if ($content -match '(?m)^VMF_VERSION="(\d+\.\d+\.\d+)"') { return $Matches[1] }
    throw "No version declaration found in $Path (bash scripts must use VMF_VERSION=)"
}

$scripts = foreach ($os in @('windows', 'linux')) {
    $dir = Join-Path $GuestRoot $os
    if (-not (Test-Path $dir)) { continue }
    foreach ($file in Get-ChildItem $dir -File | Sort-Object Name) {
        [ordered]@{
            name    = $file.Name
            os      = $os
            version = Get-DeclaredVersion $file.FullName
            sha256  = (Get-FileHash $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
}

# MANA-WIN-1: a guest script may install a package it downloads (the MANA
# driver). Its pin - name, version, URL, sha256, size - is a set of constants
# IN the script, so the script's own sha256 above already covers it; this
# lists the pin beside it, so what a guest may install is readable in one place.
function Get-DeclaredPackage {
    param([string]$Path, [string]$ScriptName)
    $content = Get-Content $Path -Raw
    if ($content -notmatch "(?m)^\`$script:PACKAGE_NAME\s*=\s*'([^']+)'") { return $null }
    $read = {
        param([string]$Field)
        if ($content -match "(?m)^\`$script:PACKAGE_$Field\s*=\s*'([^']*)'") { return $Matches[1] }
        throw "$Path declares a package but no `$script:PACKAGE_$Field"
    }
    [ordered]@{
        name      = & $read 'NAME'
        script    = $ScriptName
        version   = & $read 'VERSION'
        url       = & $read 'URL'
        sha256    = & $read 'SHA256'
        sizeBytes = [long](& $read 'BYTES')
    }
}

$packages = foreach ($os in @('windows', 'linux')) {
    $dir = Join-Path $GuestRoot $os
    if (-not (Test-Path $dir)) { continue }
    foreach ($file in Get-ChildItem $dir -File | Sort-Object Name) {
        $pkg = Get-DeclaredPackage -Path $file.FullName -ScriptName $file.Name
        if ($pkg) { $pkg }
    }
}

# schemaVersion 2 (MANA-WIN-1): adds `packages`. Nothing reads the number;
# Get-VmfGuestScript reads `scripts` and, for one script, its `packages`.
$manifest = [ordered]@{
    schemaVersion = 2
    generated     = 'tools/Update-GuestManifest.ps1'
    scripts       = @($scripts)
    packages      = @($packages)
}

$outPath = Join-Path $GuestRoot 'manifest.json'
$manifest | ConvertTo-Json -Depth 5 | Set-Content -Path $outPath -Encoding utf8NoBOM
Write-Host "Wrote $outPath ($(@($scripts).Count) scripts, $(@($packages).Count) packages)"
