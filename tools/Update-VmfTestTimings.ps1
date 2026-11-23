<#
.SYNOPSIS
    CI-SHARD-MEASURE-1: write tests/test-timings.json - the measured seconds
    of each test file, which CI's shares are balanced on - from the Pester
    output of a CI run or of a run on this machine.
.DESCRIPTION
    tools/Invoke-VmfPesterParallel.ps1 writes one line for each test file it
    ran, "vmf-test-seconds <seconds> <file>": always for a share (-Shard), and
    for a full run with -ShowTimings. This tool reads those lines and writes
    the timings file.

    A file this measurement did not run keeps the time the file already
    gives it. A file that is no longer in the test folder is removed. The
    file is never written by a CI run: CI only reads it, so every share of a
    run sees the same numbers.

    Measure on the CI runners when you can (-RunId): those are the machines
    the shares run on. A run on this machine works too, but its groups run at
    the same time and share the processor, so its times are larger and less
    even.
.PARAMETER RunId
    A GitHub Actions run of ci.yml. The tool reads the log of each of its
    "Gates and unit tests n of m" jobs with gh (CI-FOUR-SHARES-1 named them so).
.PARAMETER LogPath
    Saved output of tools/Invoke-VmfPesterParallel.ps1 (or saved CI job
    logs), instead of -RunId.
.PARAMETER Source
    What the file says the times were measured on, for -LogPath. Default
    'saved Pester output'. With -RunId it is 'CI run <id>'.
.PARAMETER TestRoot
    The test folder the file names are relative to. Default tests/unit.
.PARAMETER OutPath
    Default tests/test-timings.json.
.EXAMPLE
    ./tools/Update-VmfTestTimings.ps1 -RunId 39158910940
.EXAMPLE
    ./tools/Invoke-VmfPesterParallel.ps1 -ShowTimings *> pester.log
    ./tools/Update-VmfTestTimings.ps1 -LogPath pester.log
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Run')][long]$RunId,
    [Parameter(Mandatory, ParameterSetName = 'Log')][string[]]$LogPath,
    [Parameter(ParameterSetName = 'Log')][string]$Source = 'saved Pester output',
    [Parameter()][string]$TestRoot = (Join-Path $PSScriptRoot '..' 'tests' 'unit'),
    [Parameter()][string]$OutPath = (Join-Path $PSScriptRoot '..' 'tests' 'test-timings.json')
)

$ErrorActionPreference = 'Stop'

function Get-VmfTimingLines {
    <#
    .SYNOPSIS
        The seconds of each test file named in a text, by file. A CI log puts
        a time stamp before each line, so the line may start anywhere. A file
        named twice keeps its larger time.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $found = @{}
    foreach ($m in [regex]::Matches($Text, '(?m)vmf-test-seconds (\d+(?:\.\d+)?) (\S+\.Tests\.ps1)\s*$')) {
        $value = [double]::Parse($m.Groups[1].Value, [System.Globalization.CultureInfo]::InvariantCulture)
        $key = $m.Groups[2].Value
        if (-not $found.ContainsKey($key) -or $found[$key] -lt $value) { $found[$key] = $value }
    }
    $found
}

function Get-VmfRunPesterLogs {
    <#
    .SYNOPSIS
        The log text of each "Gates and unit tests n of m" job of one CI run, read with gh.
    #>
    param([Parameter(Mandatory)][long]$Id)
    $jobs = & gh run view $Id --json jobs | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "gh could not read run $Id (exit $LASTEXITCODE)." }
    $pester = @($jobs.jobs | Where-Object { $_.name -match '^Gates and unit tests \d+ of \d+' })
    if (-not $pester.Count) { throw "Run $Id has no 'Gates and unit tests n of m' job." }
    foreach ($job in $pester) {
        if ($job.status -ne 'completed' -or ($job.conclusion -ne 'success' -and $job.conclusion -ne 'failure')) {
            throw "The job '$($job.name)' of run $Id is '$($job.status) $($job.conclusion)': read a run whose Pester jobs ended."
        }
        # The job's own log, which GitHub gives as soon as the job ends - "gh
        # run view --log" gives nothing until the whole run ends.
        $text = (& gh api --allow-escape-sequences "repos/{owner}/{repo}/actions/jobs/$($job.databaseId)/logs") -join "`n"
        if ($LASTEXITCODE -ne 0) { throw "gh could not read the log of '$($job.name)' (exit $LASTEXITCODE)." }
        $text
    }
}

function Merge-VmfTestTimings {
    <#
    .SYNOPSIS
        The new timings: measured files get their new time, other files keep
        the time they had, and a file not in the test folder now is removed.
        Ordered by name, ordinal, so the file changes only where a time does.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][hashtable]$Old,
        [Parameter(Mandatory)][hashtable]$Measured,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Present
    )
    $merged = @{}
    foreach ($key in $Present) {
        if ($Measured.ContainsKey($key)) { $merged[$key] = [Math]::Round([double]$Measured[$key], 1) }
        elseif ($Old.ContainsKey($key)) { $merged[$key] = [double]$Old[$key] }
    }
    $names = [string[]]@($merged.Keys)
    [Array]::Sort($names, [System.StringComparer]::Ordinal)
    $ordered = [ordered]@{}
    foreach ($name in $names) { $ordered[$name] = $merged[$name] }
    $ordered
}

$texts = if ($PSCmdlet.ParameterSetName -eq 'Run') { @(Get-VmfRunPesterLogs -Id $RunId) }
         else { @($LogPath | ForEach-Object { [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $_).Path) }) }
$measured = @{}
foreach ($text in $texts) {
    $lines = Get-VmfTimingLines -Text $text
    foreach ($key in $lines.Keys) { if (-not $measured.ContainsKey($key) -or $measured[$key] -lt $lines[$key]) { $measured[$key] = $lines[$key] } }
}
if (-not $measured.Count) {
    throw 'The output names no test file time (no "vmf-test-seconds" line). Give a share run, or a run with -ShowTimings.'
}

$root = (Resolve-Path -LiteralPath $TestRoot).Path
$present = @(Get-ChildItem -LiteralPath $root -Filter '*.Tests.ps1' -Recurse -File |
    ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_.FullName).Replace('\', '/') })
$old = @{}
if (Test-Path -LiteralPath $OutPath -PathType Leaf) {
    $data = [System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $OutPath).Path) | ConvertFrom-Json
    foreach ($prop in @($data.seconds.PSObject.Properties)) { $old[[string]$prop.Name] = [double]$prop.Value }
}
$seconds = Merge-VmfTestTimings -Old $old -Measured $measured -Present $present
$source = if ($PSCmdlet.ParameterSetName -eq 'Run') { "CI run $RunId" } else { $Source }
$out = [ordered]@{
    about    = 'CI-SHARD-MEASURE-1: the seconds of each test file, which CI splits the tests by. Written by tools/Update-VmfTestTimings.ps1; CI only reads it.'
    measured = [DateTime]::UtcNow.ToString('yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
    source   = $source
    seconds  = $seconds
}
$json = ($out | ConvertTo-Json -Depth 4) -replace "`r`n", "`n"
$fullOut = [System.IO.Path]::GetFullPath($OutPath)
[System.IO.File]::WriteAllText($fullOut, $json + "`n", [System.Text.UTF8Encoding]::new($false))
$measuredHere = @($present | Where-Object { $measured.ContainsKey($_) }).Count
Write-Host ('{0}: {1} test files measured ({2}), {3} kept from before, {4} with no time.' -f $fullOut, $measuredHere, $source, (@($seconds.Keys).Count - $measuredHere), ($present.Count - @($seconds.Keys).Count))