<#
.SYNOPSIS
    Bring online the data disks the engine names, and turn off read-only on
    the data disks it names (VOLUMES-ONLINE-WINDOWS-1).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, under Windows PowerShell 5.1
    (CLAUDE.md): no ternary, no null-coalescing, no .NET Core-only API.

    After a start on new disks - a move, a rollback, a restore, a finish - a
    data disk can start offline (the SAN policy keeps a disk Windows reads as
    new offline) or read-only, and its volumes are then not mounted. The
    engine compares the 'data disks' fact of Test-GuestValidation.ps1 with the
    reading before the move, and names ONLY the disks that were online (and
    writable) then. This script changes only those: Set-Disk -IsOffline
    $false, then Set-Disk -IsReadOnly $false. A disk the customer kept offline
    or read-only is never named, so it stays so. Nothing else changes.

    Parameters (Run Command's own parameters): OnlineKeys and WritableKeys,
    each a list of disk keys (Get-VmfDiskKey) - one text joined by commas, or
    an array; any part that is not a disk key is not used.

    Output contract: schemas/guest-output.schema.json (vmf.guest/2). result:
    FIXED (a disk changed), NO_CHANGE, or BLOCKED (nothing changed, and a disk
    could not be changed, or the script itself failed). Each disk is a check:
    'disk online' or 'disk writable', FIXED with "disk <number>", or FAIL with
    "disk <number>: <why>".
#>
param(
    [string[]]$OnlineKeys = @(),
    [string[]]$WritableKeys = @()
)

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'
# VOLUMES-ONLINE-WINDOWS-1: the key of a disk - the same text in
# Test-GuestValidation.ps1 and Set-DataDisksOnline.ps1 (a test holds them
# equal). The partition table's own ID: gpt: and the disk GUID, or mbr: and
# the signature in 8 hex digits. A disk made from a snapshot keeps it, and so
# does the same disk on NVMe; the disk number can change. A disk with neither
# (RAW, or a signature of 0) has no key, and the product never changes it.
function Get-VmfDiskKey {
    param($Disk)
    $style = [string]$Disk.PartitionStyle
    if ($style -eq 'GPT') {
        $g = ([string]$Disk.Guid).Trim().TrimStart('{').TrimEnd('}').ToLowerInvariant()
        if ($g -match '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') { return ('gpt:' + $g) }
        return ''
    }
    if ($style -eq 'MBR' -and $null -ne $Disk.Signature -and [uint32]$Disk.Signature -ne 0) {
        return ('mbr:' + ([uint32]$Disk.Signature).ToString('x8'))
    }
    ''
}

# The disks to change, then each change. Online first: Windows changes the
# read-only flag of an online disk only.
function Set-VmfDataDisksOnline {
    param([string[]]$OnlineKeys, [string[]]$WritableKeys)
    $keysOf = {
        param([string[]]$Value)
        $keys = New-Object 'System.Collections.Generic.List[string]'
        foreach ($part in @((@($Value) -join ',') -split '[,\s]+')) {
            $k = ([string]$part).Trim().ToLowerInvariant()
            if ($k -match '^(gpt:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|mbr:[0-9a-f]{8})$' -and -not $keys.Contains($k)) { $keys.Add($k) }
        }
        , $keys
    }
    $wantOnline = & $keysOf $OnlineKeys
    $wantWritable = & $keysOf $WritableKeys
    $checks = New-Object 'System.Collections.Generic.List[object]'
    $disks = @(Get-Disk | Sort-Object Number | Where-Object { -not $_.IsBoot -and -not $_.IsSystem })
    foreach ($d in $disks) {
        $k = Get-VmfDiskKey $d
        if (-not $k -or -not $wantOnline.Contains($k) -or -not $d.IsOffline) { continue }
        try {
            Set-Disk -Number $d.Number -IsOffline $false
            $checks.Add([ordered]@{ name = 'disk online'; status = 'FIXED'; detail = ('disk {0}' -f $d.Number) })
        }
        catch { $checks.Add([ordered]@{ name = 'disk online'; status = 'FAIL'; detail = ('disk {0}: {1}' -f $d.Number, $_.Exception.Message) }) }
    }
    foreach ($d in $disks) {
        $k = Get-VmfDiskKey $d
        if (-not $k -or -not $wantWritable.Contains($k) -or -not $d.IsReadOnly) { continue }
        try {
            Set-Disk -Number $d.Number -IsReadOnly $false
            $checks.Add([ordered]@{ name = 'disk writable'; status = 'FIXED'; detail = ('disk {0}' -f $d.Number) })
        }
        catch { $checks.Add([ordered]@{ name = 'disk writable'; status = 'FAIL'; detail = ('disk {0}: {1}' -f $d.Number, $_.Exception.Message) }) }
    }
    $checks.ToArray()
}

try {
    $checks = @(Set-VmfDataDisksOnline -OnlineKeys $OnlineKeys -WritableKeys $WritableKeys)
    $fixed = @($checks | Where-Object { $_.status -eq 'FIXED' }).Count
    $failed = @($checks | Where-Object { $_.status -eq 'FAIL' })
    $result = 'NO_CHANGE'
    if ($fixed -gt 0) { $result = 'FIXED' }
    elseif ($failed.Count -gt 0) { $result = 'BLOCKED' }
    $doc = [ordered]@{
        schema = 'vmf.guest/2'; script = 'Set-DataDisksOnline.ps1'; version = $script:VERSION
        result = $result; checks = @($checks); warnings = @()
    }
    if ($result -eq 'BLOCKED') { $doc.error = (@($failed | ForEach-Object { $_.detail }) -join '; ') }
    $doc | ConvertTo-Json -Depth 4 -Compress
    exit 0
}
catch {
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Set-DataDisksOnline.ps1'; version = $script:VERSION
        result = 'BLOCKED'; checks = @(); warnings = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 4 -Compress
    exit 0
}