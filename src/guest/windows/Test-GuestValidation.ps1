<#
.SYNOPSIS
    Post-migration guest validation: NVMe controller live, disks mounted,
    temp disk state, pagefile placement.
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand AFTER conversion + start.
    Read-only. The engine compares `checks` against the pre-migration inventory
    captured at PRECHECK.

    Output contract: schemas/guest-output.schema.json. result: PASS | FAIL
#>

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.2.0'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:facts = [ordered]@{}

# GUEST-2: facts are DECLARED fields now, not checks with a naming convention.
# They used to travel as "fact:<name>" checks because the contract had nowhere
# to put them - which meant nothing declared which facts existed, so a guest
# could simply omit one and nothing noticed. That is how every Windows machine
# came to report an UNKNOWN driver state.
function Add-Fact {
    param([string]$Name, [string]$Value)
    $script:facts[$Name] = [string]$Value
}

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

# VOLUMES-ONLINE-1: the volumes this machine has mounted, a FACT the engine
# compares with the reading before the move ("volumes online as they were
# before"). Each access path of a partition - a drive letter or a folder - and
# each fixed drive letter Get-Volume gives (a volume on a dynamic disk has no
# partition access path). Left out: a volume GUID path (\\?\Volume{...}) and
# the temporary disk - a disk Azure names NVMe Direct Disk, this tool's own
# NVMeTempDisk, a volume labelled Temporary Storage (the label Azure gives the
# SCSI temporary disk, and Install-TempDiskInit.ps1 the NVMe one), or the drive
# with Azure's DATALOSS_WARNING_README.txt. Any one is enough, so a deleted
# file alone never makes the temporary disk a volume to compare. The
# move changes the temporary disk by design; the check of the temporary disk
# below judges it. Windows PowerShell 5.1: no pwsh-only syntax.
function Get-VmfMountedVolumeList {
    $tempDisks = @{}
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) {
        $fn = [string]$d.FriendlyName
        if ($fn -like '*NVMe Direct Disk*' -or $fn -eq 'NVMeTempDisk') { $tempDisks[[int]$d.Number] = $true }
    }
    $paths = New-Object 'System.Collections.Generic.List[string]'
    $skip = New-Object 'System.Collections.Generic.List[string]'
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue)
    foreach ($v in $volumes) {
        if ($v.DriveLetter -and [string]$v.FileSystemLabel -eq 'Temporary Storage') { $skip.Add("$($v.DriveLetter):\") }
    }
    foreach ($p in @(Get-Partition -ErrorAction SilentlyContinue)) {
        foreach ($a in @($p.AccessPaths)) {
            $s = [string]$a
            if (-not $s -or $s.StartsWith('\\?\')) { continue }
            if ($tempDisks.ContainsKey([int]$p.DiskNumber)) { $skip.Add($s); continue }
            # A folder on the partition of a Temporary Storage drive goes with it.
            if (@(@($p.AccessPaths) | Where-Object { $skip.Contains([string]$_) }).Count -gt 0) { continue }
            if (-not $paths.Contains($s)) { $paths.Add($s) }
        }
    }
    foreach ($v in $volumes) {
        if (-not $v.DriveLetter -or [string]$v.DriveType -ne 'Fixed') { continue }
        $s = "$($v.DriveLetter):\"
        if ($skip.Contains($s) -or $paths.Contains($s)) { continue }
        $paths.Add($s)
    }
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $paths) {
        # Only a drive root holds Azure's warning file.
        if ($s.Length -eq 3 -and (Test-Path -LiteralPath ($s + 'DATALOSS_WARNING_README.txt'))) { continue }
        $out.Add($s)
    }
    $list = $out.ToArray()
    [Array]::Sort($list, [StringComparer]::OrdinalIgnoreCase)
    $list
}

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
# VOLUMES-ONLINE-WINDOWS-1: each data disk and whether it is online and
# writable - a FACT. The engine compares it with the reading before the move,
# and brings online only a disk that was online then (Set-DataDisksOnline.ps1).
# Not the OS disk (IsBoot or IsSystem), and not a disk with no key.
function Get-VmfDataDiskStateList {
    $out = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue | Sort-Object Number)) {
        if ($d.IsBoot -or $d.IsSystem) { continue }
        $k = Get-VmfDiskKey $d
        if (-not $k) { continue }
        $on = 'online'
        if ($d.IsOffline) { $on = 'offline' }
        $rw = 'writable'
        if ($d.IsReadOnly) { $rw = 'readonly' }
        $out.Add(('{0}={1}:{2}:{3}' -f $k, [int]$d.Number, $on, $rw))
    }
    $out.ToArray()
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $osCaption = '{0} ({1})' -f $os.Caption, $os.Version
    $fail = 0

    # Boot bus is reported as a FACT - the engine judges it against the plan's
    # target controller (a reversion to SCSI is as valid as a move to NVMe).
    $disks = @(Get-Disk)
    $nvmeDisks = @($disks | Where-Object { $_.BusType -eq 'NVMe' })
    $bootDisk = $disks | Where-Object { $_.IsBoot } | Select-Object -First 1
    Add-Check 'boot disk bus' 'INFO' ([string]$bootDisk.BusType)
    Add-Check 'disk inventory' 'INFO' ("total=$($disks.Count) nvme=$($nvmeDisks.Count); " +
        (($disks | ForEach-Object { "disk$($_.Number):$($_.BusType):$([math]::Round($_.Size/1GB))GB:$($_.PartitionStyle)" }) -join ' '))

    # stornvme state is a fact too (must be Running on NVMe boots; harmless on SCSI)
    $svc = Get-Service stornvme -ErrorAction SilentlyContinue
    Add-Check 'stornvme service' 'INFO' ([string]$svc.Status)

    # UPST-2: the I/O timeout, reported per ControlSet as a FACT - the engine
    # decides what it means, because on a SCSI reversion 240 is not required.
    # Measured on vmf-upst2-win: the first boot on NVMe reset the booted
    # ControlSet from 240 to 10, so validation that never looked would have
    # called that machine healthy.
    # GUEST-2: ONE flat fact carrying every ControlSet, not one per set with a
    # dynamic name - a declared facts contract cannot describe names it cannot
    # know in advance.
    $ioPairs = [System.Collections.Generic.List[string]]::new()
    foreach ($cs in @(Get-ChildItem 'HKLM:\SYSTEM' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -match '^ControlSet\d+$' } | ForEach-Object { $_.PSChildName })) {
        $io = (Get-ItemProperty "HKLM:\SYSTEM\$cs\Services\stornvme\Parameters" -Name 'IoTimeoutValue' -ErrorAction SilentlyContinue).IoTimeoutValue
        $ioPairs.Add("$cs=$(if ($null -eq $io) { 'not set' } else { $io })") | Out-Null
    }
    if ($ioPairs.Count -gt 0) { Add-Fact 'ioTimeout' (($ioPairs) -join ' ') }

    # Volumes with letters (engine compares to captured set)
    $vols = @(Get-Volume | Where-Object { $_.DriveLetter })
    Add-Check 'volumes' 'INFO' (($vols | ForEach-Object { "$($_.DriveLetter):$([math]::Round($_.Size/1GB))GB:$($_.FileSystemType)" }) -join ' ')

    # VOLUMES-ONLINE-1: the mounted volumes the engine compares. A listing that
    # cannot be read reports nothing, which the engine reads as unknown.
    try {
        $mounted = @(Get-VmfMountedVolumeList)
        Add-Check 'mounted volumes' 'INFO' $(if ($mounted.Count -gt 0) { $mounted -join '; ' } else { 'none' })
    }
    catch { $null = $_ }

    # VOLUMES-ONLINE-WINDOWS-1: each data disk, online or offline, writable or
    # read-only. A listing that cannot be read reports nothing.
    try {
        $dataDisks = @(Get-VmfDataDiskStateList)
        Add-Check 'data disks' 'INFO' $(if ($dataDisks.Count -gt 0) { $dataDisks -join '; ' } else { 'none' })
    }
    catch { $null = $_ }

    # STORAGE-SPACES-1 (raised 2026-08-30): a CUSTOMER'S storage pool on
    # their data disks - the Windows analogue of LVM on data disks, and it fails
    # the same quiet way.
    #
    # A pool spanning several data disks is not boot-critical. The machine comes
    # up, the agent reports Ready, the boot disk is on NVMe, the drivers are
    # bound, and every check above passes. The only thing missing is the volume
    # holding the application's data - because a Path B recreate detaches and
    # reattaches the data disks, and a pool missing a member surfaces as
    # Degraded or Detached with its virtual disk offline.
    #
    # FACTS ONLY. The engine judges these against what the machine had before;
    # nothing here decides anything, per the SCSI-direction rule.
    #
    # Our own temp-disk pool is EXCLUDED by name. This tool creates exactly one
    # pool, 'NVMeTempPool', from disks whose friendly name is 'NVMe Direct Disk'
    # - reporting it here as if it were the customer's would be noise, and
    # confusing noise at that.
    $ourPool = 'NVMeTempPool'
    try {
        $pools = @(Get-StoragePool -ErrorAction SilentlyContinue |
            Where-Object { -not $_.IsPrimordial -and $_.FriendlyName -ne $ourPool })
        if ($pools.Count -gt 0) {
            # THE AGGREGATED PAIR, in the SAME shape Test-NvmeReady.ps1 emits.
            # This is the contract the ENGINE parses (Get-VmfStorageFacts), and
            # for a long time only the prep script spoke it: the validator
            # emitted per-pool names, so the after side reported nothing the
            # comparison recognised and every machine WITH a pool came back
            # UNKNOWN - which is neither pass nor fail, so the check protected
            # nothing exactly when it mattered. Machines with NO pools compared
            # fine, which is why it looked healthy. Found by the volume drill,
            # 2026-09-01.
            Add-Check 'storage pools' 'INFO' (($pools | ForEach-Object {
                "$($_.FriendlyName)[health=$($_.HealthStatus);disks=$(@($_ | Get-PhysicalDisk -ErrorAction SilentlyContinue).Count)]" }) -join ' ')
            $allVds = @(Get-VirtualDisk -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -ne 'NVMeTempDisk' })
            Add-Check 'storage volumes' 'INFO' (($allVds | ForEach-Object {
                "$($_.FriendlyName)[health=$($_.HealthStatus);state=$($_.OperationalStatus)]" }) -join ' ')

            # The per-pool detail stays: it is what a PERSON reads when the
            # comparison says something is wrong.
            foreach ($p in $pools) {
                Add-Check "storage pool $($p.FriendlyName)" 'INFO' (
                    "health=$($p.HealthStatus) state=$($p.OperationalStatus) " +
                    "disks=$(@($p | Get-PhysicalDisk -ErrorAction SilentlyContinue).Count)")
            }
            # The virtual disks are what actually carry the data. A pool can look
            # present while its virtual disk is detached, which is the case that
            # loses a filesystem without losing a machine.
            $vds = @(Get-VirtualDisk -ErrorAction SilentlyContinue |
                Where-Object { $_.FriendlyName -ne 'NVMeTempDisk' })
            foreach ($vd in $vds) {
                Add-Check "storage volume $($vd.FriendlyName)" 'INFO' (
                    "health=$($vd.HealthStatus) state=$($vd.OperationalStatus) attached=$(
                        [bool](Get-Disk -ErrorAction SilentlyContinue |
                            Where-Object { $_.FriendlyName -eq $vd.FriendlyName }))")
            }
            # Any physical disk the pool expects and cannot see. This is the
            # single most useful number after a recreate.
            $lost = @(Get-PhysicalDisk -ErrorAction SilentlyContinue |
                Where-Object { $_.OperationalStatus -match 'Lost|Unrecognized|Removed' })
            if ($lost.Count -gt 0) {
                Add-Check 'storage pool disks missing' 'INFO' (
                    "MISSING: " + (($lost | ForEach-Object { "$($_.FriendlyName)=$($_.OperationalStatus)" }) -join ', '))
            }
            else { Add-Check 'storage pool disks missing' 'INFO' 'every pooled disk is present' }
        }
        else {
            # 'none' is the word Get-VmfStorageFacts reads as a real zero.
            Add-Check 'storage pools' 'INFO' 'none'
            Add-Check 'storage volumes' 'INFO' 'none'
        }
    }
    catch {
        # An image without the Storage module is not a failure - it is an image
        # that cannot be asked. Unknown must never read as "none".
        Add-Check 'storage pools' 'INFO' "could not be inspected on this image: $($_.Exception.Message)"
    }

    # Temp disk: if NVMe Direct Disk hardware exists, D: should be formatted (init task ran)
    $tempPhys = @(Get-PhysicalDisk | Where-Object { $_.FriendlyName -like '*NVMe Direct Disk*' })
    if ($tempPhys.Count -gt 0) {
        $dVol = Get-Volume -DriveLetter D -ErrorAction SilentlyContinue
        if ($dVol -and $dVol.FileSystemType -eq 'NTFS') {
            Add-Check 'nvme temp disk D:' 'PASS' "formatted NTFS, $([math]::Round($dVol.Size/1GB))GB"
        }
        else {
            Add-Check 'nvme temp disk D:' 'FAIL' 'NVMe Direct Disk present but D: not formatted - init task may have failed'
            $fail++
        }
    }
    else { Add-Check 'nvme temp disk D:' 'INFO' 'no NVMe Direct Disk hardware (diskless size or pre-v6)' }

    # Pagefile placement
    $pf = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue)
    if ($pf.Count -gt 0) { Add-Check 'pagefile' 'INFO' (($pf | ForEach-Object { $_.Name }) -join ', ') }
    else { Add-Check 'pagefile' 'WARN' 'no active pagefile' }

    $result = if ($fail -eq 0) { 'PASS' } else { 'FAIL' }
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Test-GuestValidation.ps1'; version = $script:VERSION
        os = $osCaption; result = $result; checks = @($script:checks); facts = $script:facts; warnings = @()
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
catch {
    [ordered]@{
        schema = 'vmf.guest/2'; script = 'Test-GuestValidation.ps1'; version = $script:VERSION
        os = ''; result = 'FAIL'; checks = @($script:checks); facts = $script:facts; warnings = @()
        error = $_.Exception.Message
    } | ConvertTo-Json -Depth 6 -Compress
    exit 0
}
