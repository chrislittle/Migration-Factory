<#
.SYNOPSIS
    Install the boot-time initializer for v6/v7 NVMe temp disks: writes
    NVMeTempDiskInit.ps1 to the VM and registers the AzureNVMeTempDiskInit
    scheduled task (SYSTEM, AtStartup, priority 0).
.DESCRIPTION
    Runs INSIDE the guest via Azure RunCommand, BEFORE conversion (the task fires
    on first boot of the new size). Idempotent - re-registers the task.

    The initializer identifies temp disks via the official Azure method
    (PhysicalDisk FriendlyName contains 'NVMe Direct Disk'), correlates by serial,
    refuses to touch non-RAW disks, and stripes multiple disks into one D:\ via
    a Simple storage pool. A Wait-ForDrive snippet is written for dependent tasks.

    WHERE THE FILE GOES, AND WHY IT MOVED. This script used to write the
    initializer to C:\AdminScripts. A new first-level folder under C:\ inherits
    "Authenticated Users: Modify" from the root of the drive, so every
    authenticated user on the machine could rewrite the file that a SYSTEM boot
    task then executes. That is SYSTEM code execution, with persistence, on
    every Windows machine that migrates to an nvme-temp size.

    The install folder is now %ProgramData%\VmMigrationFactory and this script
    does not trust the folder it finds. Before it writes anything it:
      - refuses a junction or a link at the install path (a link makes the
        write land at a path somebody else chose);
      - refuses a folder that a principal who is not an administrator owns,
        because an owner can always give itself permissions again;
      - creates the folder with an explicit DACL - full control for SYSTEM and
        the local Administrators group, read and execute for Users, inheritance
        OFF - and reads the DACL back to make sure it is the one on disk.
    Each file gets the same DACL. The scheduled task is registered only after
    all of that holds, and it runs the full path to powershell.exe.

    The folder can be owned by an administrator ACCOUNT rather than by SYSTEM
    or by the Administrators group: Windows makes the CREATOR the owner, so an
    administrator, an installer or a management agent that made the folder
    first owns it as a user SID. That machine is legitimate, so the owner test
    accepts a member of the local Administrators group. It never accepts an
    owner who is not an administrator - that owner is the attack the move
    exists to stop.

    Output contract: schemas/guest-output.schema.json. result: FIXED | BLOCKED
#>

param(
    # Empty means %ProgramData%\VmMigrationFactory - see Get-DefaultInstallPath.
    [string]$InstallPath
)

$ErrorActionPreference = 'Stop'
$script:VERSION = '1.1.0'
$script:checks = [System.Collections.Generic.List[object]]::new()
$script:warnings = [System.Collections.Generic.List[string]]::new()
$script:osCaption = ''
$script:adminSidCache = $null

function Add-Check {
    param([string]$Name, [string]$Status, [string]$Detail = '')
    $script:checks.Add([ordered]@{ name = $Name; status = $Status; detail = $Detail })
}

function Add-Warning {
    param([string]$Text)
    [void]$script:warnings.Add($Text)
}

function Emit {
    param([string]$Result, [string]$ErrorDetail = $null)
    $doc = [ordered]@{
        schema  = 'vmf.guest/2'
        script  = 'Install-TempDiskInit.ps1'
        version = $script:VERSION
        os      = $script:osCaption
        result  = $Result
        checks  = @($script:checks)
        warnings = @($script:warnings)
    }
    if ($ErrorDetail) { $doc.error = $ErrorDetail }
    $doc | ConvertTo-Json -Depth 6 -Compress
}

# --------------------------------------------------------------------------
# Install-path safety. Windows PowerShell 5.1 on .NET Framework only - no
# .NET Core API, no ternary, no null-coalescing, on any path.
# --------------------------------------------------------------------------

function Get-DefaultInstallPath {
    # ProgramData, not a new folder under C:\. The folder this script creates
    # carries its own protected DACL, so what the parent grants does not reach
    # it - but a first-level folder under the drive root is also the folder
    # every user can create FIRST, which is the race this whole file is about.
    $programData = $env:ProgramData
    if (-not $programData) { $programData = Join-Path $env:SystemDrive 'ProgramData' }
    return (Join-Path $programData 'VmMigrationFactory')
}

function Get-LocalAdminSidList {
    # ADSI rather than Get-LocalGroupMember: on Windows PowerShell 5.1
    # Get-LocalGroupMember throws when a member SID does not resolve to a name,
    # which is ordinary on a machine that once held a domain or Entra account.
    # The WinNT provider hands back the raw SIDs and never has to resolve them.
    if ($null -ne $script:adminSidCache) { return $script:adminSidCache }
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    # The group name is localized; the SID is not. Translate, then bind.
    $groupName = ($adminsSid.Translate([System.Security.Principal.NTAccount]).Value -split '\\')[-1]
    $group = [ADSI]("WinNT://./$groupName,group")
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($member in @($group.Invoke('Members'))) {
        $bytes = $member.GetType().InvokeMember('objectSid', 'GetProperty', $null, $member, $null)
        $found.Add((New-Object System.Security.Principal.SecurityIdentifier($bytes, 0)).Value)
    }
    $script:adminSidCache = $found
    return $script:adminSidCache
}

function Test-AdministrativeSid {
    param([string]$Sid)
    if ($Sid -eq 'S-1-5-18') { return $true }          # LocalSystem
    if ($Sid -eq 'S-1-5-32-544') { return $true }      # BUILTIN\Administrators
    # TrustedInstaller, which owns much of what Windows Update installs.
    if ($Sid -eq 'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464') { return $true }
    # Built-in Administrator (RID 500), Domain Admins (512), Schema Admins
    # (518), Enterprise Admins (519) - administrative by definition.
    if ($Sid -match '^S-1-5-21-\d+-\d+-\d+-(500|512|518|519)$') { return $true }
    # And the case that matters most in practice: Windows makes the CREATOR the
    # owner, so a folder an administrator made is owned by that person's SID.
    foreach ($member in (Get-LocalAdminSidList)) {
        if ($member -eq $Sid) { return $true }
    }
    return $false
}

function Get-ReparseProblem {
    param([string]$Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) { return $null }
    if (([int]$item.Attributes -band [int][System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        return "$Path is a junction or a link, so it points at a path somebody else chose"
    }
    return $null
}

function Get-OwnerProblem {
    param([string]$Path)
    $sid = ''
    try {
        $sid = (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return "cannot read the owner of ${Path}: $($_.Exception.Message)"
    }
    if (-not $sid) { return "$Path has no owner this script can read" }
    $isAdmin = $false
    try { $isAdmin = Test-AdministrativeSid -Sid $sid }
    catch {
        # Fail closed. A machine where group membership cannot be read is a
        # machine where "this owner is safe" cannot be shown to be true.
        return "cannot tell whether the owner of $Path ($sid) is an administrator: $($_.Exception.Message)"
    }
    if (-not $isAdmin) {
        $name = ''
        try { $name = " ($((New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value))" }
        catch { $name = '' }
        return "$Path is owned by $sid$name, which is not an administrator"
    }
    return $null
}

function New-ProtectedSecurity {
    param([string]$Kind)
    $systemSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
    $usersSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
    if ($Kind -eq 'Directory') {
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    }
    else {
        $security = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    # $true, $false: protect the DACL and drop what the parent grants. This is
    # the line that keeps "Authenticated Users: Modify" out of the folder.
    $security.SetAccessRuleProtection($true, $false)
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readAndRun = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($systemSid, $full, $inherit, $propagation, $allow)))
    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($adminsSid, $full, $inherit, $propagation, $allow)))
    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($usersSid, $readAndRun, $inherit, $propagation, $allow)))
    return $security
}

function Get-DaclProblem {
    param([string]$Path)
    $acl = $null
    try { $acl = Get-Acl -LiteralPath $Path }
    catch { return "cannot read the permissions of ${Path}: $($_.Exception.Message)" }
    if (-not $acl.AreAccessRulesProtected) {
        return "$Path still inherits permissions from its parent folder"
    }
    $writeRights = [int]([System.Security.AccessControl.FileSystemRights]::Write -bor
        [System.Security.AccessControl.FileSystemRights]::Delete -bor
        [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [System.Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    # SIDs, not names: an account that does not resolve must still be judged.
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { continue }
        if (([int]$rule.FileSystemRights -band $writeRights) -eq 0) { continue }
        $sid = $rule.IdentityReference.Value
        $isAdmin = $false
        try { $isAdmin = Test-AdministrativeSid -Sid $sid }
        catch { return "cannot tell whether $sid, which can write to $Path, is an administrator" }
        if (-not $isAdmin) {
            return "$Path gives write permissions to $sid, which is not an administrator"
        }
    }
    return $null
}

function Protect-InstallPath {
    param([string]$Path)
    # Returns a sentence that says what is wrong, or nothing when the folder is
    # safe for a SYSTEM boot task to run a file from.
    $problem = Get-ReparseProblem -Path $Path
    if ($problem) { return $problem }
    if ([System.IO.File]::Exists($Path)) { return "$Path is a file, and this script needs a folder there" }

    $security = New-ProtectedSecurity -Kind 'Directory'
    if ([System.IO.Directory]::Exists($Path)) {
        $problem = Get-OwnerProblem -Path $Path
        if ($problem) { return $problem }
        # An administrator owns it, so the owner is not the threat and there is
        # no reason to take a folder away from the installer or the agent that
        # made it. The DACL IS the threat, so that is what gets replaced.
        [System.IO.Directory]::SetAccessControl($Path, $security)
    }
    else {
        # CreateDirectory(String, DirectorySecurity) writes the DACL as part of
        # the create, so the folder is never open for a moment. It also does
        # NOTHING to a folder that already exists - which is why the read-back
        # below is not decoration: it is what catches a folder somebody created
        # in the moment between the test above and this line.
        [System.IO.Directory]::CreateDirectory($Path, $security) | Out-Null
    }

    $problem = Get-ReparseProblem -Path $Path
    if ($problem) { return $problem }
    if (-not [System.IO.Directory]::Exists($Path)) { return "$Path is not a folder after this script tried to make one" }
    $problem = Get-OwnerProblem -Path $Path
    if ($problem) { return $problem }
    return (Get-DaclProblem -Path $Path)
}

function Write-ProtectedFile {
    param([string]$Path, [string]$Content)
    $problem = Get-ReparseProblem -Path $Path
    if ($problem) { return $problem }
    # Delete, then write. A name that is already a hard link points at a file
    # somewhere else, and writing through it writes THERE. Deleting removes the
    # link and leaves the other file with its own content.
    if ([System.IO.File]::Exists($Path)) { Remove-Item -LiteralPath $Path -Force }
    Set-Content -LiteralPath $Path -Value $Content -Encoding UTF8 -Force
    [System.IO.File]::SetAccessControl($Path, (New-ProtectedSecurity -Kind 'File'))
    return (Get-DaclProblem -Path $Path)
}

function Remove-LegacyInstall {
    param([string]$Path)
    # The files this script wrote to C:\AdminScripts before the install folder
    # moved. THE SAME TWO GATES AS THE NEW PATH, and for a sharper reason: this
    # runs as SYSTEM, any authenticated user can create C:\AdminScripts, and a
    # junction needs no privilege at all. A delete that follows the junction is
    # a SYSTEM delete at a path that user chose.
    #
    # A folder this script cannot vouch for is LEFT ALONE rather than treated
    # as a failure. The boot task no longer points at it, and stopping the
    # migration for it would hand every user on the machine a way to stop it.
    if (-not [System.IO.Directory]::Exists($Path)) {
        Add-Check 'old install folder' 'PASS' "nothing at $Path"
        return
    }
    $problem = Get-ReparseProblem -Path $Path
    if (-not $problem) { $problem = Get-OwnerProblem -Path $Path }
    if ($problem) {
        Add-Check 'old install folder' 'WARN' "left as it is: $problem"
        Add-Warning "This script did not remove anything from ${Path}: $problem. The boot task does not use that folder now."
        return
    }

    # The line each file carries when this tool is the one that wrote it. A
    # file that does not say it is ours is somebody else's file with our name.
    $ours = [ordered]@{
        'NVMeTempDiskInit.ps1'            = 'installed by VmMigrationFactory'
        'Wait-ForDrive-D.ps1.snippet.txt' = 'initialized by AzureNVMeTempDiskInit'
    }
    foreach ($name in $ours.Keys) {
        $file = Join-Path $Path $name
        if (-not [System.IO.File]::Exists($file)) { continue }
        $fileProblem = Get-ReparseProblem -Path $file
        if (-not $fileProblem) { $fileProblem = Get-OwnerProblem -Path $file }
        if (-not $fileProblem) {
            $text = ''
            try { $text = Get-Content -LiteralPath $file -Raw -ErrorAction Stop }
            catch { $text = '' }
            if ([string]$text -notmatch [regex]::Escape($ours[$name])) {
                $fileProblem = "$file does not carry the line this tool writes into it"
            }
        }
        if ($fileProblem) {
            Add-Check "old file $name" 'WARN' "left as it is: $fileProblem"
            Add-Warning "This script did not remove ${file}: $fileProblem"
            continue
        }
        # SEC-F1-FLAKE-1 WAS NOT A FLAKY TEST. It was this line.
        #
        # A file written moments ago can still be held open by the antivirus
        # scanner, and Windows answers a delete with:
        #   The process cannot access the file ... it is being used by
        #   another process.
        #
        # $ErrorActionPreference is 'Stop' at the top of this script, so an
        # unguarded delete ENDS THE WHOLE SCRIPT - during a migration, on a
        # customer's machine, in the one place where every other failure in
        # this function warns and carries on.
        #
        # MEASURED 2026-09-09, after five sightings all read as test flakiness:
        # the test failed in 3 of 8 full suite runs and never when its file ran
        # alone, because a full run writes thousands of files and the scanner
        # falls behind. The test was right every time.
        #
        # Retry briefly - the lock lasts milliseconds - and if it still will
        # not go, warn and continue. A file left behind is untidy. A guest
        # script that stops half way through is a failed migration.
        #
        # Windows PowerShell 5.1 only: no ternary, no ?? - see CLAUDE.md.
        $removed = $false
        $lastProblem = ''
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            try {
                Remove-Item -LiteralPath $file -Force -ErrorAction Stop
                $removed = $true
                break
            }
            catch {
                $lastProblem = $_.Exception.Message
                if ($attempt -lt 5) { Start-Sleep -Milliseconds (100 * $attempt) }
            }
        }
        if (-not $removed) {
            Add-Check "old file $name" 'WARN' "left as it is: $lastProblem"
            Add-Warning "This script did not remove ${file}: $lastProblem"
            continue
        }
        Add-Check "old file $name" 'FIXED' "removed $file"
    }
    Add-Check 'old install folder' 'PASS' "$Path is left as it is - it can hold files this tool did not write"
}

$initializerContent = @'
# NVMeTempDiskInit.ps1 - installed by VmMigrationFactory (Install-TempDiskInit.ps1)
# Initializes the raw Azure NVMe temp disk(s) as D:\ at every boot. Safe: only touches RAW disks.
$logFile = "C:\Windows\Temp\NVMeTempDiskInit.log"
if ((Test-Path $logFile) -and ((Get-Item $logFile).Length -ge 500KB)) {
    for ($i = 3; $i -ge 1; $i--) { if (Test-Path "$logFile.$i") { Move-Item "$logFile.$i" "$logFile.$($i+1)" -Force } }
    Move-Item $logFile "$logFile.1" -Force
}
function Log { param($m) "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $m" | Out-File $logFile -Append }
Log "NVMe temp disk initializer started."

$physDisks = @(Get-PhysicalDisk | Where-Object { $_.FriendlyName -like "*NVMe Direct Disk*" })
if ($physDisks.Count -eq 0) { Log "No NVMe Direct Disk found - nothing to do."; exit 0 }

$candidates = @()
foreach ($pd in $physDisks) {
    # Null-safe serial handling: SCSI disks may have no serial at all
    $pdSerial = ([string]$pd.SerialNumber).Trim()
    if (-not $pdSerial) { Log "ERROR: NVMe temp physical disk has no serial - cannot correlate. Aborting."; exit 1 }
    $d = Get-Disk | Where-Object { ([string]$_.SerialNumber).Trim() -eq $pdSerial } | Select-Object -First 1
    if (-not $d) { Log "ERROR: cannot correlate physical disk serial $pdSerial. Aborting."; exit 1 }
    $candidates += $d
}
$rawDisks = @($candidates | Where-Object { $_.PartitionStyle -eq "RAW" })
if ($rawDisks.Count -eq 0) { Log "All temp disks already initialized."; exit 0 }
if ($rawDisks.Count -ne $candidates.Count) { Log "WARNING: partial init detected ($($rawDisks.Count)/$($candidates.Count) RAW) - aborting."; exit 1 }

function Set-LetterD { param($DiskNumber, $PartitionNumber)
    if (Get-Partition | Where-Object { $_.DriveLetter -eq "D" }) { Log "WARNING: D: in use, keeping auto letter."; return }
    Set-Partition -DiskNumber $DiskNumber -PartitionNumber $PartitionNumber -NewDriveLetter D
}
try {
    if ($candidates.Count -eq 1) {
        $disk = $candidates[0]
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | Out-Null
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        if ($part.DriveLetter -ne "D") { Set-LetterD $disk.Number $part.PartitionNumber
            $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber }
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "Temporary Storage" -Confirm:$false | Out-Null
        Log "SUCCESS: single NVMe temp disk initialized as $($part.DriveLetter):\"
    } else {
        $poolName = "NVMeTempPool"
        $existing = Get-StoragePool -FriendlyName $poolName -ErrorAction SilentlyContinue
        if ($existing) {
            $existing | Get-VirtualDisk -ErrorAction SilentlyContinue | Remove-VirtualDisk -Confirm:$false -ErrorAction SilentlyContinue
            $existing | Remove-StoragePool -Confirm:$false
        }
        $subsystem = Get-StorageSubSystem | Where-Object { $_.FriendlyName -like "Windows Storage*" } | Select-Object -First 1
        $null = New-StoragePool -FriendlyName $poolName -StorageSubSystemUniqueId $subsystem.UniqueId -PhysicalDisks $physDisks
        $vdisk = New-VirtualDisk -StoragePoolFriendlyName $poolName -FriendlyName "NVMeTempDisk" `
            -ResiliencySettingName Simple -NumberOfColumns $candidates.Count -UseMaximumSize
        $disk = $null
        for ($i = 0; $i -lt 10 -and -not $disk; $i++) { $disk = $vdisk | Get-Disk -ErrorAction SilentlyContinue; if (-not $disk) { Start-Sleep 2 } }
        if (-not $disk) { Log "ERROR: virtual disk did not surface."; exit 1 }
        Initialize-Disk -Number $disk.Number -PartitionStyle GPT -PassThru | Out-Null
        $part = New-Partition -DiskNumber $disk.Number -UseMaximumSize -AssignDriveLetter
        if ($part.DriveLetter -ne "D") { Set-LetterD $disk.Number $part.PartitionNumber
            $part = Get-Partition -DiskNumber $disk.Number -PartitionNumber $part.PartitionNumber }
        Format-Volume -Partition $part -FileSystem NTFS -NewFileSystemLabel "Temporary Storage" -Confirm:$false | Out-Null
        Log "SUCCESS: $($candidates.Count)-disk striped pool initialized as $($part.DriveLetter):\"
    }
} catch { Log "ERROR during initialization: $_"; exit 1 }
'@

$waitSnippet = @'
# Wait for D:\ (initialized by AzureNVMeTempDiskInit) - paste at the TOP of any
# startup task that depends on D:\ (e.g. SQL Server tempdb init).
$maxWait = 120; $elapsed = 0
while (-not (Test-Path "D:\") -and $elapsed -lt $maxWait) { Start-Sleep -Seconds 5; $elapsed += 5 }
if (-not (Test-Path "D:\")) { Write-Error "D:\ not available after $maxWait seconds."; exit 1 }
'@

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $script:osCaption = '{0} ({1})' -f $os.Caption, $os.Version

    if (-not $InstallPath) { $InstallPath = Get-DefaultInstallPath }

    # Nothing below writes a file, and no task is registered, until the folder
    # holds a DACL this script has read back from disk.
    $problem = Protect-InstallPath -Path $InstallPath
    if ($problem) {
        Add-Check 'install folder' 'FAIL' $problem
        Emit -Result 'BLOCKED' -ErrorDetail "A SYSTEM boot task cannot safely run a file from ${InstallPath}: $problem"
        exit 0
    }
    Add-Check 'install folder' 'FIXED' "$InstallPath gives full control to SYSTEM and Administrators, read and execute to Users, and inherits nothing"

    $initFile = Join-Path $InstallPath 'NVMeTempDiskInit.ps1'
    $problem = Write-ProtectedFile -Path $initFile -Content $initializerContent
    if ($problem) {
        Add-Check 'initializer script' 'FAIL' $problem
        Emit -Result 'BLOCKED' -ErrorDetail "Cannot write the initializer safely: $problem"
        exit 0
    }
    Add-Check 'initializer script' 'FIXED' "written to $initFile"

    $snippetFile = Join-Path $InstallPath 'Wait-ForDrive-D.ps1.snippet.txt'
    $problem = Write-ProtectedFile -Path $snippetFile -Content $waitSnippet
    if ($problem) {
        Add-Check 'wait-for-drive snippet' 'FAIL' $problem
        Emit -Result 'BLOCKED' -ErrorDetail "Cannot write the wait-for-drive snippet safely: $problem"
        exit 0
    }
    Add-Check 'wait-for-drive snippet' 'FIXED' "written to $snippetFile"

    # The full path, not the name: Task Scheduler searches the system PATH for
    # a bare name, and the PATH is not this script's to trust.
    $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not [System.IO.File]::Exists($powerShellExe)) {
        Add-Check 'scheduled task' 'FAIL' "$powerShellExe is not on this machine"
        Emit -Result 'BLOCKED' -ErrorDetail "Windows PowerShell is not at $powerShellExe, so the boot task has nothing safe to run"
        exit 0
    }
    $action = New-ScheduledTaskAction -Execute $powerShellExe `
        -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$initFile`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) `
        -Priority 0 -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest

    Unregister-ScheduledTask -TaskName 'AzureNVMeTempDiskInit' -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName 'AzureNVMeTempDiskInit' -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal `
        -Description 'Initializes Azure NVMe temp disk (D:) on each boot (VmMigrationFactory)' | Out-Null
    Add-Check 'scheduled task' 'FIXED' 'AzureNVMeTempDiskInit registered (SYSTEM, AtStartup, priority 0)'

    # LAST, on purpose. The task now points at the new file, so removing the
    # old one cannot leave a registered task aimed at a file that is gone.
    $legacyPath = Join-Path $env:SystemDrive 'AdminScripts'
    if ([System.IO.Path]::GetFullPath($InstallPath).TrimEnd('\') -ne [System.IO.Path]::GetFullPath($legacyPath).TrimEnd('\')) {
        Remove-LegacyInstall -Path $legacyPath
    }

    # Deliberately NOT run here: this is still the original VM with no NVMe temp disk.
    Emit -Result 'FIXED'
    exit 0
}
catch {
    Emit -Result 'BLOCKED' -ErrorDetail $_.Exception.Message
    exit 0
}
