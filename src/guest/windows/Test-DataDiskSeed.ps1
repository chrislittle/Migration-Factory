<#
.SYNOPSIS
    DISK-1 verify: after migration, every data volume's seed file must still
    hash to the value stored beside it, and the volumes must be mounted.
.DESCRIPTION
    Runs INSIDE the guest via RunCommand, AFTER conversion + start. Read-only.
    Output contract: schemas/guest-output.schema.json. result: PASS | FAIL
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.0'
$script:checks = [System.Collections.Generic.List[object]]::new()

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osCaption = '{0} ({1})' -f $os.Caption, $os.Version
    $fail = 0

    $dataVolumes = @(Get-Volume | Where-Object {
        $_.DriveLetter -and $_.DriveLetter -notin @('C', 'D') -and $_.FileSystemType -eq 'NTFS'
    })
    Add-Check 'data volumes present' $(if ($dataVolumes.Count -gt 0) { 'PASS' } else { 'FAIL' }) "count=$($dataVolumes.Count)"
    if ($dataVolumes.Count -eq 0) { $fail++ }

    foreach ($vol in $dataVolumes) {
        $root = "$($vol.DriveLetter):\"
        $seedFile = Join-Path $root 'vmf-seed.bin'
        $hashFile = Join-Path $root 'vmf-seed.sha256'
        if (-not ((Test-Path $seedFile) -and (Test-Path $hashFile))) {
            Add-Check "seed $($vol.DriveLetter):" 'FAIL' 'seed or hash file missing after migration'
            $fail++
            continue
        }
        $expected = (Get-Content $hashFile -Raw).Trim().ToLowerInvariant()
        $actual = (Get-FileHash -Path $seedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -eq $expected) {
            Add-Check "seed $($vol.DriveLetter):" 'PASS' "sha256 intact ($($actual.Substring(0,12))...)"
        }
        else {
            Add-Check "seed $($vol.DriveLetter):" 'FAIL' "hash mismatch: expected $expected actual $actual"
            $fail++
        }
        # bus type evidence for the engine (data disks should be NVMe post-migration)
        $partition = Get-Partition -DriveLetter $vol.DriveLetter -ErrorAction SilentlyContinue
        if ($partition) {
            $disk = Get-Disk -Number $partition.DiskNumber
            Add-Check "bus $($vol.DriveLetter):" 'INFO' "$($disk.BusType) lun-ish disk#$($disk.Number)"
        }
    }

    $result = if ($fail -eq 0) { 'PASS' } else { 'FAIL' }
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Test-DataDiskSeed.ps1'; version = $script:VERSION
        os = $osCaption; result = $result; checks = @($script:checks); warnings = @()
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Test-DataDiskSeed.ps1'; version = $script:VERSION
        os = ''; result = 'FAIL'; checks = @($script:checks); warnings = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
