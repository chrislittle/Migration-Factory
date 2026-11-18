# VmMigrationFactory root module - loads the Public/ and Private/ function files.

# Callers' $ErrorActionPreference does NOT cross the module boundary (PowerShell
# preference-inheritance gap). Without this pin, a failed Az cmdlet writes a
# non-terminating error and execution continues into success bookkeeping -
# REH-1 recorded a quota record RELEASED although the Azure delete 409'd.
# Inside this module, every unhandled error is terminating.
$ErrorActionPreference = 'Stop'

# PERF-PROFILE-1: every path a function builds starts here. The files load as
# ONE script block (below), so a function has no file of its own and
# $PSScriptRoot inside it is empty. PerfProfile.Tests.ps1 fails on any use.
$script:VmfModuleRoot = $PSScriptRoot

$public  = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Public')  -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)
$private = @(Get-ChildItem -Path (Join-Path $PSScriptRoot 'Private') -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue)

# PERF-PROFILE-1: ONE script block for all the files, not one each.
#
# The service imports this module in its start-up script, once for each new
# instance AND once for each new runspace (Microsoft's PowerShell guide for
# Functions). The lab install measured 7.0 s from the start of that script to
# the first Az message. MEASURED HERE, 2026-11-02, a fresh pwsh each time:
# dot-sourcing the 148 files one at a time took about 1,800 ms; the same files
# as one script block took about 220 ms. The cost is per script block, not per
# byte. The engine imports this module too, and gets the same gain.
#
# What it costs: an error position names this joined text, not the file. A
# parse error, or an error while the files load, is put back to its file and
# line below. An error later, inside a function, names the function.
$source = [System.Text.StringBuilder]::new()
$starts = [System.Collections.Generic.List[object]]::new()
$line = 1
foreach ($file in @($private + $public)) {
    $text = [System.IO.File]::ReadAllText($file.FullName)
    $starts.Add([pscustomobject]@{ Line = $line; File = $file.FullName })
    # The line break after each file keeps a last line with none (a comment, a
    # line continuation) from joining the first line of the next file.
    [void]$source.Append($text).Append("`n")
    $line += ($text.Length - $text.Replace("`n", '').Length) + 1
}
$fileAt = {
    param([int]$At)
    $hit = $starts | Where-Object { $_.Line -le $At } | Select-Object -Last 1
    if ($hit) { '{0}: line {1}' -f $hit.File, ($At - $hit.Line + 1) } else { "line $At" }
}

# LOADER-REIMPORT-1: [scriptblock]::Create, not Parser.ParseInput. Create asks
# PowerShell's own process-wide cache first, keyed on the EXACT text
# (CompiledScriptBlock.cs, TryGetCachedScriptBlock, v7.4.6 and master). So a
# second Import-Module -Force of the same files does not parse or compile them
# again - the files one at a time had that from the same cache, by path and
# text (ExternalScriptInfo.cs). ParseInput skips the cache: on a CI runner a
# repeat import took 528-737 ms against 194-258 ms before. An edited file is new
# text, so it is parsed again. The cache gives back a Clone() with no session
# state, so each runspace gets its own functions and module scope - the same
# rule the files one at a time had in every runspace of the service.
$block = $null
try { $block = [scriptblock]::Create($source.ToString()) }
catch {
    $parseError = $_.Exception
    while ($parseError -and $parseError -isnot [System.Management.Automation.ParseException]) { $parseError = $parseError.InnerException }
    if (-not $parseError) { throw }
    $first = $parseError.Errors[0]
    throw ('Failed to load {0}: {1}' -f (& $fileAt $first.Extent.StartLineNumber), $first.Message)
}
try { . $block }
catch { throw ('Failed to load {0}: {1}' -f (& $fileAt $_.InvocationInfo.ScriptLineNumber), $_) }
Remove-Variable -Name source, starts, line, text, fileAt, block, parseError, first -ErrorAction SilentlyContinue

Export-ModuleMember -Function $public.BaseName
