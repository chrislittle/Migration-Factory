<#
.SYNOPSIS
    DIAG-1: collect everything about a migration run into one file for support.

.DESCRIPTION
    The operator-side twin of the dashboard's "Get help". Same bundle, gathered
    from the run store directly, for the two cases the browser cannot serve:

      - the dashboard itself is the problem, or cannot be reached
      - the run is finished, archived, or belongs to a subscription whose
        operator would rather not open a browser at all

    It also emits the Log Analytics queries support will ask for. The QUERIES,
    not their results: running them needs workspace access this script may not
    have, and a query someone can paste is more useful than an empty result set
    that looks like an answer. The workspace is outside the run store's
    perimeter (STORE-LOGS-WORKSPACE-PERIMETER-1), so a pasted query needs only
    the person's own role on it.

    WHAT IT CARRIES: run ids, machine names, states, history, events, plan,
    quota records, approvals, schedules. That is the point of it.

    WHAT IT DOES NOT: tokens, keys, connection strings or SAS. The store is read
    with the caller's own Azure sign-in and nothing durable is written into the
    bundle. Guest evidence files are referenced by name, not inlined - they can
    be large, and support can ask for a specific one.

.PARAMETER RunPath
    The run to collect, e.g. azblob://acct/container/run-id or a local path.

.PARAMETER OutPath
    Where to write the bundle. Defaults to ./vmf-support-<run>-<utc>.json

.PARAMETER EventLimit
    How many of the most recent events to include. The newest explain a failure,
    so the TAIL is kept, and the bundle records that it was truncated.

.EXAMPLE
    ./tools/Export-VmfSupportBundle.ps1 -RunPath azblob://vmfstate/vmf-runs/run-7
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunPath,
    [Parameter()][string]$OutPath,
    [Parameter()][int]$EventLimit = 2000,
    [Parameter()][string]$LogAnalyticsWorkspace
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../src/VmMigrationFactory/VmMigrationFactory.psd1" -Force

function Read-Safely {
    param([string]$Rel, $Fallback = $null)
    try { & (Get-Module VmMigrationFactory) { param($rp, $r) Read-VmfStoreJson -RunPath $rp -RelPath $r -Depth 30 } $RunPath $Rel }
    catch { $Fallback }
}
function Get-NamesSafely {
    param([string]$Folder)
    try { @(& (Get-Module VmMigrationFactory) { param($rp, $f) Get-VmfStoreNames -RunPath $rp -Folder $f } $RunPath $Folder) }
    catch { @() }
}

Write-Host "Collecting support bundle for $RunPath" -ForegroundColor Cyan

$runId = ($RunPath.TrimEnd('/') -split '[/\\]')[-1]
# The @( ) goes OUTSIDE the Where-Object, not inside. A pipeline that emits one
# object returns a SCALAR, and ConvertTo-Json then writes `machines` as an
# object instead of an array - so a one-machine run produced a differently
# SHAPED bundle than a fleet, and anything parsing machines[] would find
# nothing. Caught by exporting a real single-machine run.
$machines  = @(@(foreach ($n in (Get-NamesSafely 'state'))     { if ($n -like '*.json') { Read-Safely "state/$n" } })     | Where-Object { $_ })
$claims    = @(@(foreach ($n in (Get-NamesSafely 'capacity'))  { if ($n -like '*.json') { Read-Safely "capacity/$n" } })  | Where-Object { $_ })
$approvals = @(@(foreach ($n in (Get-NamesSafely 'approvals')) { if ($n -like '*.json') { Read-Safely "approvals/$n" } }) | Where-Object { $_ })
$schedules = @(@(foreach ($n in (Get-NamesSafely 'schedules')) { if ($n -like '*.json') { Read-Safely "schedules/$n" } }) | Where-Object { $_ })

$events = @()
try {
    # EVENTLOG-1: Read-VmfStoreLines, not Read-VmfStoreText. A log that filled
    # carries on in a second document, and the bundle is the one thing that
    # must hold the whole run - it is collected by somebody already stuck.
    $lines = & (Get-Module VmMigrationFactory) { param($rp) Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl' } $RunPath
    $events = @($lines | ForEach-Object { $_ | ConvertFrom-Json })
}
catch { $events = @() }
$eventsTotal = $events.Count
$truncated = $eventsTotal -gt $EventLimit
if ($truncated) { $events = $events[-$EventLimit..-1] }

# The queries support will ask for. Emitted as TEXT so they can be pasted by
# someone who has workspace access, rather than run here and returned empty.
$kql = [ordered]@{
    engineJobFailures = @"
ContainerAppConsoleLogs_CL
| where TimeGenerated > ago(7d)
| where ContainerName_s startswith 'vmf-engine'
| where Log_s has_any ('FAILED', 'throw', 'Exception', '$runId')
| project TimeGenerated, Log_s
| order by TimeGenerated desc
"@
    facadeRequests = @"
AppRequests
| where TimeGenerated > ago(7d)
| where Success == false
| project TimeGenerated, Name, ResultCode, DurationMs, OperationId
| order by TimeGenerated desc
"@
    facadeExceptions = @"
AppExceptions
| where TimeGenerated > ago(7d)
| project TimeGenerated, ProblemId, OuterMessage, OperationId
| order by TimeGenerated desc
"@
}

$bundle = [ordered]@{
    bundle       = 'vmf.support/1'
    generatedUtc = (Get-Date).ToUniversalTime().ToString('o')
    generatedBy  = 'Export-VmfSupportBundle.ps1'
    run          = $RunPath
    runId        = $runId
    whatThisIs   = 'Everything the run store holds about one migration run, for sending to support.'
    whatItContains = @(
        'the run status, the plan, and the assessment it came from',
        'one record per machine: state, history, checkpoints, and what ran inside it',
        "the activity log$(if ($truncated) { " (the most recent $EventLimit entries of $eventsTotal)" })",
        'quota records, approvals and schedules',
        'the Log Analytics queries support will ask for - the queries, not their results'
    )
    whatItDoesNotContain = @(
        'no tokens, keys, connection strings or SAS - the store is read with the caller''s own Azure sign-in and nothing durable is written here',
        'guest evidence files are listed by name rather than inlined; ask support which one is wanted'
    )
    versions = [ordered]@{
        module      = (Get-Module VmMigrationFactory).Version.ToString()
        powerShell  = $PSVersionTable.PSVersion.ToString()
        os          = [System.Runtime.InteropServices.RuntimeInformation]::OSDescription
    }
    runStatus    = Read-Safely 'run-status.json'
    run_         = Read-Safely 'run.json'
    plan         = Read-Safely 'plan.json'
    assessment   = Read-Safely 'assessment.json'
    machines     = @($machines)
    capacityClaims = @($claims)
    approvals    = @($approvals)
    schedules    = @($schedules)
    evidenceFiles = @(Get-NamesSafely 'evidence')
    events       = @($events)
    eventsTruncated = $truncated
    eventsTotal  = $eventsTotal
    logAnalytics = [ordered]@{
        workspace = $LogAnalyticsWorkspace
        note      = 'Run these where the workspace lives. They are not run here because this script may not have access, and an empty result set looks like an answer.'
        queries   = $kql
    }
}

if (-not $OutPath) {
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $OutPath = "./vmf-support-$runId-$stamp.json"
}
$bundle | ConvertTo-Json -Depth 40 | Set-Content $OutPath -Encoding utf8

$size = [math]::Round((Get-Item $OutPath).Length / 1KB, 1)
Write-Host ""
Write-Host "  machines : $($machines.Count)"
Write-Host "  events   : $($events.Count)$(if ($truncated) { " of $eventsTotal (most recent kept)" })"
Write-Host "  claims   : $($claims.Count)   approvals: $($approvals.Count)   schedules: $($schedules.Count)"
Write-Host ""
Write-Host "Wrote $OutPath ($size KB)" -ForegroundColor Green
Write-Host "It carries run ids and machine names, and no tokens or keys. Send it with a note about what you were doing." -ForegroundColor Cyan

[pscustomobject]@{ Path = $OutPath; Machines = $machines.Count; Events = $events.Count; SizeKB = $size }
