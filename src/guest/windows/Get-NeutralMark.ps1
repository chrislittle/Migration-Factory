<#
.SYNOPSIS
    Read the machine name and the time, and nothing else (RUNCMD-REPLAY-1).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, under Windows PowerShell 5.1
    (CLAUDE.md): no ternary, no null-coalescing, no .NET Core-only API.

    WHY THIS EXISTS. Measured 2026-10-11: after a machine went back to disks
    made from its first copy, Azure ran the machine's LAST Run Command again
    when it started. When the last Run Command before the put-back only read
    the machine, nothing came back. So the engine runs this script straight
    after every guest script that changes the machine: if Azure runs the last
    command again, it runs this one, which changes nothing.

    It reads the machine name and the time. It checks nothing about the move,
    so it reads the same on every move: v5, v6, v7, SCSI or NVMe. It writes
    nothing, starts nothing and stops nothing.

    Output contract: schemas/guest-output.schema.json (vmf.guest/2). result:
    READY, or BLOCKED when the script itself failed.
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'

try {
    $name = [string]$env:COMPUTERNAME
    # Invariant: under another culture ':' becomes its time separator, and a
    # Buddhist calendar writes another year (review finding).
    $now = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ', [System.Globalization.CultureInfo]::InvariantCulture)
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Get-NeutralMark.ps1'; version = $script:VERSION
        result = 'READY'
        checks = @(
            [ordered]@{ name = 'machine name'; status = 'INFO'; detail = $name }
            [ordered]@{ name = 'time'; status = 'INFO'; detail = $now }
        )
        warnings = @()
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
catch {
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Get-NeutralMark.ps1'; version = $script:VERSION
        result = 'BLOCKED'; checks = @(); warnings = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
