<#
.SYNOPSIS
    DOC-4: re-take every screenshot the manual shows, from the dashboard's own
    pages in sample-data mode.
.DESCRIPTION
    Serves src/dashboard on a local port, copies the two reason files beside
    the pages for the duration (the deploy ships them; a checkout does not),
    drives a headless Microsoft Edge over the DevTools protocol
    (tools/manual-shots.js), and writes the pictures to docs/manual/images.
    Run it after any change to a page the manual shows, and commit the
    pictures with the change.

    MANUAL-SHOTS-1: two pictures show what the module writes, not a page: the
    report of a migration, and the look of the migration record. For the run,
    this also puts beside the pages the report's look (Get-VmfReportLook, the
    text the service returns) and a report written by New-VmfReport from a
    small sample migration (tools/New-VmfManualSampleRun.ps1). Both are
    deleted afterwards, with the sample migration.
.PARAMETER Port
    The local port to serve the pages on.
.PARAMETER Only
    The pictures to take, by file name. Without it, every picture is taken.
.EXAMPLE
    ./tools/Export-VmfManualScreenshots.ps1
.EXAMPLE
    ./tools/Export-VmfManualScreenshots.ps1 -Only report.png, wizard-run.png
#>
[CmdletBinding()]
param(
    [Parameter()][int]$Port = 8129,
    [Parameter()][string[]]$Only
)
$ErrorActionPreference = 'Stop'
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$dash = Join-Path $repoRoot 'src' 'dashboard'
$data = Join-Path $repoRoot 'src' 'VmMigrationFactory' 'data'
$out = Join-Path $repoRoot 'docs' 'manual' 'images'

$edge = @('C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe', 'C:\Program Files\Microsoft\Edge\Application\msedge.exe') |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $edge) { throw 'Microsoft Edge was not found. The screenshots need a headless browser.' }
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'node was not found.' }

$temp = @()
foreach ($f in 'assessment-reasons.json', 'stop-reasons.json') {
    $target = Join-Path $dash $f
    if (-not (Test-Path $target)) { Copy-Item (Join-Path $data $f) $target; $temp += $target }
}
$sampleRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-manual-run-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$server = $null
try {
    # MANUAL-SHOTS-1: the report's look and a sample report, from the module.
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory') -Force
    $look = Join-Path $dash 'manual-report-look.json'
    [System.IO.File]::WriteAllText($look, ((& (Get-Module VmMigrationFactory) { Get-VmfReportLook }) | ConvertTo-Json -Depth 3))
    $temp += $look
    $null = & (Join-Path $PSScriptRoot 'New-VmfManualSampleRun.ps1') -RunPath $sampleRun
    $report = Join-Path $dash 'manual-sample-report.html'
    Copy-Item (New-VmfReport -OutPath $sampleRun) $report -Force
    $temp += $report

    $server = Start-Process -FilePath 'python' -ArgumentList @('-m', 'http.server', "$Port", '--directory', $dash) -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $shotArgs = @($edge, "http://127.0.0.1:$Port", $out)
    if ($Only) { $shotArgs += ($Only -join ',') }
    & node (Join-Path $PSScriptRoot 'manual-shots.js') @shotArgs
    if ($LASTEXITCODE -ne 0) { throw "the screenshot run failed ($LASTEXITCODE)" }
}
finally {
    if ($server -and -not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    foreach ($t in $temp) { Remove-Item $t -Force -ErrorAction SilentlyContinue }
    if (Test-Path $sampleRun) { Remove-Item $sampleRun -Recurse -Force -ErrorAction SilentlyContinue }
}
Get-ChildItem $out -Filter '*.png' | Select-Object Name, Length
