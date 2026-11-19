<#
.SYNOPSIS
    BICEP-PIN-1: make the Bicep CLI on this runner the pinned version, before
    a CI step runs Bicep.

.DESCRIPTION
    infra/bicep-version.json pins the ONE Bicep CLI version CI uses (since
    2026-10-18). A workflow job runs this before its first step that runs
    Bicep: the templates compile, and the tests (they compile the templates
    with `az bicep build`).

      1. Read the pin.
      2. Ask az which Bicep it runs (`az bicep version`).
      3. ONLY when that is not the pin: `az bicep install --version v<pin>`.
         A newer version is replaced too - the pin decides, not the newest.
      4. Ask again, and fail when it is still not the pin.

      5. CI-BICEP-RESTORE-1: restore the registry modules of the templates
         (tools/Restore-VmfBicepModules.ps1), and fail when one is not
         restored. The tests compile the templates behind the network floor,
         so a new machine with no Bicep cache must get the modules here.

    So a runner that already has the pin installs nothing, and a runner that has
    another version gets the pin once and keeps it. Nothing upgrades Bicep
    at each start of a machine any more.

    THE BICEP az RUNS. In CI, az runs a bicep it finds on PATH unless its
    setting bicep.use_binary_from_path says no (default "if_found_in_ci"),
    and `az bicep install` does not change that one. A GitHub-hosted image
    has bicep on PATH. So this sets the setting's environment variable,
    AZURE_BICEP_USE_BINARY_FROM_PATH=false, for its own az calls and, through
    GITHUB_ENV, for every later step of the job.

.PARAMETER PinPath
    The pin file. Defaults to infra/bicep-version.json.

.PARAMETER Az
    The az command. Tests give a stand-in.

.PARAMETER RestoreRoot
    The repository whose templates' registry modules are restored. Defaults
    to this one. Tests give a folder of their own.
#>
[CmdletBinding()]
param(
    [string]$PinPath = (Join-Path $PSScriptRoot '..' 'infra' 'bicep-version.json'),
    [string]$Az = 'az',
    [string]$RestoreRoot = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'

$pinned = [string](Get-Content -LiteralPath $PinPath -Raw | ConvertFrom-Json).version
if ($pinned -notmatch '^\d+\.\d+\.\d+$') {
    throw "$PinPath pins '$pinned', which is not a Bicep version (three numbers, for example 1.2.3)."
}

$env:AZURE_BICEP_USE_BINARY_FROM_PATH = 'false'
if ($env:GITHUB_ENV) { Add-Content -LiteralPath $env:GITHUB_ENV -Value 'AZURE_BICEP_USE_BINARY_FROM_PATH=false' }

function Get-VmfBicepVersion {
    # "Bicep CLI version 1.2.3 (abc1234)", or a line that says there is none.
    $out = @(& $Az bicep version 2>&1 | ForEach-Object { "$_" })
    $m = [regex]::Match(($out -join "`n"), 'Bicep CLI version (\d+\.\d+\.\d+)')
    [pscustomobject]@{ Version = $(if ($m.Success) { $m.Groups[1].Value } else { '' }); Text = ($out -join ' ').Trim() }
}

function Invoke-VmfModuleRestore {
    # CI-BICEP-RESTORE-1: with the pinned Bicep, and with the network open.
    param([string]$Root)
    @((& (Join-Path $PSScriptRoot 'Restore-VmfBicepModules.ps1') -Root $Root -Az $Az).Restored)
}

$before = Get-VmfBicepVersion
if ($before.Version -eq $pinned) {
    Write-Host "Bicep $pinned is the pinned version. Nothing to install."
    $restored = Invoke-VmfModuleRestore -Root $RestoreRoot
    return [pscustomobject]@{ Pinned = $pinned; Before = $before.Version; Version = $pinned; Installed = $false; Restored = $restored }
}

Write-Host "This runner has $(if ($before.Version) { "Bicep $($before.Version)" } else { "no Bicep ($($before.Text))" }). Installing the pinned $pinned."
$out = @(& $Az bicep install --version "v$pinned" 2>&1 | ForEach-Object { "$_" })
$code = $LASTEXITCODE
$out | ForEach-Object { Write-Host "  $_" }
if ($code -ne 0) {
    throw "az bicep install --version v$pinned ended with exit code $code`: $($out -join ' ')"
}

$after = Get-VmfBicepVersion
if ($after.Version -ne $pinned) {
    throw "After the install, az runs Bicep '$($after.Version)' ($($after.Text)), not the pinned $pinned."
}
Write-Host "Bicep $pinned installed. It was $(if ($before.Version) { $before.Version } else { 'not installed' })."
$restored = Invoke-VmfModuleRestore -Root $RestoreRoot
[pscustomobject]@{ Pinned = $pinned; Before = $before.Version; Version = $after.Version; Installed = $true; Restored = $restored }
