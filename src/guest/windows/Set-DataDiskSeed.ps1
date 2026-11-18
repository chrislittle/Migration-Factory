<#
.SYNOPSIS
    DISK-1: initialize RAW data disks (GPT/NTFS, letters from E:), then write a
    seed file + its SHA256 to every data volume so a later verify can prove the
    data survived migration. Idempotent - volumes already seeded are skipped.
.DESCRIPTION
    Runs INSIDE the guest via RunCommand, BEFORE conversion. Only touches RAW
    disks, and never disks whose FriendlyName marks them as NVMe temp disks.
    Output contract: schemas/guest-output.schema.json. result: FIXED | NO_CHANGE | BLOCKED
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.0.1'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:changed = $false

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
    if ($Status -eq 'FIXED') { $script:changed = $true }
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema = 'vmf.guest/2'; script = 'Set-DataDiskSeed.ps1'; version = $script:VERSION
        os = $script:osCaption; result = $Result; checks = @($script:checks); warnings = @()
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    # Initialize any RAW data disks (never the NVMe temp disk).
    # NOTE: SerialNumber can be NULL on SCSI disks (v4/v5) - always null-safe.
    $tempSerials = @(Get-PhysicalDisk | Where-Object { $_.FriendlyName -like '*NVMe Direct Disk*' } |
        ForEach-Object { ([string]$_.SerialNumber).Trim() } | Where-Object { $_ })
    $rawDisks = @(Get-Disk | Where-Object {
        $_.PartitionStyle -eq 'RAW' -and -not $_.IsBoot -and
        (([string]$_.SerialNumber).Trim() -notin $tempSerials -or -not ([string]$_.SerialNumber).Trim())
    })
    $nextLetter = [char]'E'
    foreach ($disk in $rawDisks) {
        # Occupied letters include NON-partition volumes: a fresh Azure VM can
        # hold the provisioning DVD at E: (CD-ROM has no partition), which makes
        # New-Partition fail with "access path is already in use" (REH-1).
        $used = @(Get-CimInstance Win32_LogicalDisk | ForEach-Object { $_.DeviceID.Substring(0, 1) }) +
                @(Get-Volume -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DriveLetter }) +
                @(Get-Partition -ErrorAction SilentlyContinue | ForEach-Object { [string]$_.DriveLetter })
        $used = @($used | Where-Object { $_ -and $_ -match '^[A-Za-z]' } | ForEach-Object { $_.ToUpperInvariant() })
        while ([string]$nextLetter -in $used) {
            $nextLetter = [char]([int]$nextLetter + 1)
        }
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | Out-Null
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter $nextLetter
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "vmf-data" -Confirm:$false | Out-Null
        Add-Check "init disk $($disk.Number) -> ${nextLetter}:" 'FIXED' "$([math]::Round($disk.Size/1GB,1)) GB"
        $nextLetter = [char]([int]$nextLetter + 1)
    }

    # Seed every vmf-data volume (and any existing NTFS data volume beyond C:/D:)
    $dataVolumes = @(Get-Volume | Where-Object {
        $_.DriveLetter -and $_.DriveLetter -notin @('C', 'D') -and $_.FileSystemType -eq 'NTFS'
    })
    if ($dataVolumes.Count -eq 0) {
        Add-Check 'data volumes' 'WARN' 'no data volumes found to seed'
        Emit -Result 'NO_CHANGE'; exit 0
    }

    foreach ($vol in $dataVolumes) {
        $root = "$($vol.DriveLetter):\"
        $seedFile = Join-Path $root 'vmf-seed.bin'
        $hashFile = Join-Path $root 'vmf-seed.sha256'
        if ((Test-Path $seedFile) -and (Test-Path $hashFile)) {
            Add-Check "seed $($vol.DriveLetter):" 'PASS' 'already seeded'
            continue
        }
        # RunCommand executes under Windows PowerShell 5.1 (.NET Framework):
        # RandomNumberGenerator::Fill() does not exist there - use Create().GetBytes().
        $bytes = New-Object byte[] (4MB)
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
        [System.IO.File]::WriteAllBytes($seedFile, $bytes)
        $hash = (Get-FileHash -Path $seedFile -Algorithm SHA256).Hash.ToLowerInvariant()
        Set-Content -Path $hashFile -Value $hash -Encoding ascii -NoNewline
        Add-Check "seed $($vol.DriveLetter):" 'FIXED' "sha256=$($hash.Substring(0,12))..."
    }

    if ($script:changed) { Emit -Result 'FIXED' } else { Emit -Result 'NO_CHANGE' }
    exit 0
}
catch {
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
    exit 0
}
