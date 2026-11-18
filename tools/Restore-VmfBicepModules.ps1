<#
.SYNOPSIS
    CI-BICEP-RESTORE-1: put the registry modules of the templates into this
    machine's Bicep cache, while the network is open.

.DESCRIPTION
    The tests compile the templates with `az bicep build`, and they run
    behind the network floor (TEST-AZURE-GUARD-1: every test process has a
    proxy at 0.0.0.0). So Bicep cannot download a registry module during the
    tests: it must already be in the cache (.bicep in the user's profile).

    A machine that compiled the templates before has the cache. A new
    machine does not, and every `br/public:` module fails with BCP192.
    Found on main CI run 39158910940, on a new on-demand pool machine.

    This finds each .bicep file under infra/ and lab/ that uses a registry
    module (`br:` or `br/` in a module or import reference) or an extension
    (bicepconfig.json maps it to a registry), and runs
    `az bicep restore --file <file>` for each. A file with none is skipped,
    so the step stays fast.

      - CI: tools/Sync-VmfBicepVersion.ps1 runs this after the pinned Bicep
        is in place. A restore that fails fails the step, with the file and
        the error.
      - A local run: tools/Invoke-VmfPesterParallel.ps1 runs this with
        -BestEffort before it sets the floor. A failure is a warning.

.PARAMETER Root
    The repository root. Defaults to the folder above tools.

.PARAMETER Az
    The az command. Tests give a stand-in.

.PARAMETER BestEffort
    Warn for each file that fails, and do not stop.

.PARAMETER RetryDelaySeconds
    The pause before a failed file is tried the second and last time. 10 by default.
.PARAMETER ListOnly
    List the files that would be restored, and call no az.
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot '..'),
    [string]$Az = 'az',
    [switch]$BestEffort,
    [switch]$ListOnly,
    # A file that fails is tried once more after this pause: a short refusal
    # from the registry must not fail a whole CI job.
    [int]$RetryDelaySeconds = 10
)

$ErrorActionPreference = 'Stop'
$Root = [System.IO.Path]::GetFullPath($Root)

function Test-VmfRegistryReference {
    # A registry module or import ('br:...', 'br/public:...'), or an extension
    # statement. A line that is only a comment does not count.
    param([string]$Path)
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $text = $line.TrimStart()
        if ($text.StartsWith('//')) { continue }
        if ($text -match '''br[:/]' -or $text -match '^extension\s') { return $true }
    }
    $false
}

$files = @(foreach ($folder in 'infra', 'lab') {
        $dir = Join-Path $Root $folder
        if (Test-Path -LiteralPath $dir) { Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.bicep' }
    }) | Sort-Object FullName
$targets = @($files | Where-Object { Test-VmfRegistryReference -Path $_.FullName })

$restored = [System.Collections.Generic.List[string]]::new()
$failed = [System.Collections.Generic.List[object]]::new()
foreach ($file in $targets) {
    $name = [System.IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
    if ($ListOnly) { $restored.Add($name); continue }
    $out = @(& $Az bicep restore --file $file.FullName 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        Write-Warning "az bicep restore --file $name ended with exit code $code. Trying it once more in $RetryDelaySeconds seconds."
        if ($RetryDelaySeconds -gt 0) { Start-Sleep -Seconds $RetryDelaySeconds }
        $out = @(& $Az bicep restore --file $file.FullName 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    }
    if ($code -eq 0) {
        $restored.Add($name)
        continue
    }
    $detail = (@($out | Where-Object { $_ -match 'Error|ERROR' }) + @($out) | Select-Object -First 1)
    if (-not $detail) { $detail = 'no output' }
    $failed.Add([pscustomobject]@{ File = $name; ExitCode = $code; Error = ($out -join ' ').Trim() })
    if ($BestEffort) {
        Write-Warning "az bicep restore --file $name ended with exit code $code. A test that compiles this template can fail with BCP192. $detail"
    }
}

if ($failed.Count -and -not $BestEffort) {
    $lines = $failed | ForEach-Object { "$($_.File): az bicep restore ended with exit code $($_.ExitCode): $($_.Error)" }
    throw "The registry modules of $($failed.Count) template(s) were not restored. The tests compile these templates with the network closed, so they would fail. $($lines -join ' | ')"
}
if (-not $ListOnly) { Write-Host "Restored the registry modules of $($restored.Count) template(s): $($restored -join ', ')." }
[pscustomobject]@{ Restored = @($restored); Failed = @($failed) }
