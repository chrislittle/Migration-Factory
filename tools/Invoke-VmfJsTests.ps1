<#
.SYNOPSIS
    ASSESS-LIST-1: run the dashboard's behavioural JavaScript tests.
.DESCRIPTION
    Every other test of the dashboard is a GREP - does this page contain that
    string. Those catch a control that was deleted; they cannot catch one that
    is wired wrongly, and this project has shipped three defects of exactly that
    shape: a key read from the wrong object, a gate reading the first truthy
    field of an MSAL error, and a block that reported hidden while the computed
    style stayed visible.

    No install and no dependencies. Node is already on both CI runner images,
    so this costs one step. A missing node is reported rather than skipped -
    a check that quietly does not run is the thing the inert-test detector
    exists to stop.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path = (Join-Path $PSScriptRoot '..' 'tests' 'js'),
    # TEST-JS-TIMER-HANG-1: the time one file may take. Measured 2026-11-07 on
    # a Windows PC: the slowest file took about 25 seconds (html-sinks), the
    # whole set about 2 minutes. 300 is twelve times the slowest, for a loaded
    # or a small runner, and well inside the CI gates job's 20 minutes.
    [Parameter()][ValidateRange(1, 3600)][int]$TimeoutSeconds = 300
)

$ErrorActionPreference = 'Stop'
$node = Get-Command node -ErrorAction SilentlyContinue
if (-not $node) { throw 'node was not found, so the dashboard behaviour tests did not run.' }

$files = @(Get-ChildItem -LiteralPath $Path -Filter '*.test.js' -File | Sort-Object Name)
if (-not $files.Count) { throw "no *.test.js under $Path - this runner would pass on nothing." }

# TEST-JS-HANG-1: the exit code alone is not proof. A test that waits for a
# promise that never settles lets node end with exit code 0 before the harness
# prints anything, so a file passes only when it also printed its summary,
# "<label>: N/N passed", with at least one test. (A run with a failure prints
# ", N FAILED" after it and exits 1.) The harness itself fails such
# a file (beforeExit); this catches a file that does not use the harness, or a
# harness that lost that guard.
$summary = '^\S.*: \d+/(\d+) passed$'

# TEST-JS-TIMER-HANG-1: the harness's beforeExit guard comes only when node has
# nothing left to do. A test that waits forever while a timer repeats (a page's
# poll, a setInterval) keeps node busy, so node never ends, and neither did
# this run: CI stopped at the gates job's limit with no line naming the file,
# and every builder on the PC waited behind the suite lock. So each file runs
# with a time limit, and a file past it is stopped - with every process it
# started - and fails with "did not end in N seconds".
# Each line of a file's output, then whether it ended inside the limit.
function Invoke-VmfJsTestFile([string]$Node, [string]$File, [int]$Seconds) {
    $info = [System.Diagnostics.ProcessStartInfo]::new($Node)
    $info.ArgumentList.Add($File)
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $info.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $info.WorkingDirectory = (Get-Location).ProviderPath
    $proc = [System.Diagnostics.Process]::Start($info)
    try {
        # Read both streams at the same time, or a file that writes a lot to
        # one of them fills its pipe and waits on this run for ever.
        $stdout = $proc.StandardOutput.ReadToEndAsync()
        $stderr = $proc.StandardError.ReadToEndAsync()
        $ended = $proc.WaitForExit($Seconds * 1000)
        if (-not $ended) {
            try { $proc.Kill($true) } catch [System.InvalidOperationException] { $null = $_ } # it ended in between
            $null = $proc.WaitForExit(10000)
        }
        # Bounded too: a process the file left behind can hold the pipes open.
        try { $null = [System.Threading.Tasks.Task]::WaitAll(@($stdout, $stderr), 10000) } catch [System.AggregateException] { $null = $_ } # a failed read keeps what the other gave
        $text = @($stdout, $stderr) | Where-Object { $_.IsCompletedSuccessfully } | ForEach-Object { $_.Result }
        $lines = @(($text -join "`n") -split '\r?\n' | Where-Object { $_ -ne '' })
        [pscustomobject]@{ Ended = $ended; Code = $(if ($ended) { $proc.ExitCode } else { $null }); Lines = $lines }
    } finally {
        $proc.Dispose()
    }
}

$failed = [System.Collections.Generic.List[string]]::new()
foreach ($file in $files) {
    $result = Invoke-VmfJsTestFile -Node $node.Source -File $file.FullName -Seconds $TimeoutSeconds
    $out = $result.Lines
    $out
    if (-not $result.Ended) {
        $failed.Add("$($file.Name) (did not end in $TimeoutSeconds seconds)")
        "$($file.Name): did not end in $TimeoutSeconds seconds, so it was stopped and FAILED"
        continue
    }
    $code = $result.Code
    $line = @($out | Where-Object { $_ -match $summary }) | Select-Object -Last 1
    $counted = $line -and $line -match $summary -and [int]$Matches[1] -gt 0
    if ($code -ne 0) {
        $failed.Add("$($file.Name) (exit code $code)")
    } elseif (-not $counted) {
        $failed.Add("$($file.Name) (exit code 0, but no 'N/N passed' line - its tests did not all run)")
        "$($file.Name): ended with exit code 0 and no 'N/N passed' line, so it FAILED"
    }
}
if ($failed.Count) { throw "$($failed.Count) JavaScript test file(s) failed: $($failed -join '; ')." }
[pscustomobject]@{ Files = $files.Count; Count = 0 }
