#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LINUX-TEMP-DISK-FILES-1 (audit 2026-11-14, row #40). Every wave shows "If
# files are found on the temporary disk: Stop and ask / Continue - the files
# are deleted", but the check behind it ran only for Windows. A Linux machine
# with files on its temporary disk (/mnt, /mnt/resource, the Azure Linux
# Agent's ResourceDisk.MountPoint) moved and lost them with no stop. Microsoft:
# data on the temporary disk can be lost "when you stop the VM", and every move
# stops (deallocates) the machine
# (https://learn.microsoft.com/en-us/azure/virtual-machines/managed-disks-overview#temporary-disk).
#
# This file holds:
#   - the engine: a Linux machine with a SCSI temporary disk runs
#     temp-disk-content.sh in Checking, with the Windows check's stop, reason,
#     setting and accept path;
#   - the guest script, run here under bash with a stand-in /proc/mounts and
#     /proc/swaps under VMF_TEST_ROOT (the root the shared vmf-temp-disk block
#     already reads).
BeforeDiscovery {
    $script:bash = @(@(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
        @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
        Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps|System32' }) | Select-Object -First 1
}
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:linux = Join-Path $script:repoRoot 'src' 'guest' 'linux'
    $script:scriptFile = Join-Path $script:linux 'temp-disk-content.sh'
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json'
    $script:bash = @(@(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
        @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
        Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps|System32' }) | Select-Object -First 1

    function Global:LtCtx([string]$Os = 'Linux', [string]$From = 'scsi-temp', [string]$To = 'nvme-temp', [string]$OnData = 'stop') {
        @{ Plan = [pscustomobject]@{
                assessment = [pscustomobject]@{ os = $Os; sourceDiskArch = $From }
                target = [pscustomobject]@{ diskArch = $To }
                policy = [pscustomobject]@{ onDDataFound = $OnData } }
           Rg = 'rg'; VmName = 'vm'; VmId = '/vm'; RunPath = (Join-Path ([System.IO.Path]::GetTempPath()) 'vmf-no-store') }
    }

    function Script:LtUnix([string]$Path) {
        if ($IsWindows) { return (& $script:bash -c "cygpath -u '$Path'" | Out-String).Trim() }
        $Path
    }
    # A stand-in machine root: proc/mounts and proc/swaps, the mount points
    # with their items, and etc/waagent.conf when given. The Azure device
    # names are plain files here (Git Bash on Windows cannot make a symbolic
    # link), so readlink -f gives each its own path, and a mount names the
    # device by that path: /dev/disk/azure/resource and
    # /dev/disk/cloud/azure_resource-part1 are the resource disk,
    # /dev/disk/azure/scsi1/lun0 and /dev/disk/azure/data/by-lun/1 are data
    # disks. tests/linux/temp-disk-content.test.sh runs the real links and
    # partitions on CI's Linux job.
    function Script:LtWork {
        param([string[]]$Mounts, [hashtable]$Items = @{}, [string[]]$Swaps = @(), [string]$Waagent, [switch]$NoDevices)
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-lt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $rootDir = Join-Path $work 'root'
        if (-not $NoDevices) {
            foreach ($dev in @('dev/disk/azure/resource', 'dev/disk/cloud/azure_resource-part1', 'dev/disk/azure/scsi1/lun0', 'dev/disk/azure/data/by-lun/1')) {
                $at = Join-Path $rootDir $dev
                [void][System.IO.Directory]::CreateDirectory((Split-Path $at -Parent))
                [System.IO.File]::WriteAllText($at, '')
            }
        }
        [void][System.IO.Directory]::CreateDirectory((Join-Path $rootDir 'proc'))
        [void][System.IO.Directory]::CreateDirectory((Join-Path $rootDir 'etc'))
        [System.IO.File]::WriteAllText((Join-Path $rootDir 'proc' 'mounts'), (($Mounts + '') -join "`n"))
        $swapLines = @('Filename                                Type            Size            Used            Priority') + $Swaps
        [System.IO.File]::WriteAllText((Join-Path $rootDir 'proc' 'swaps'), (($swapLines + '') -join "`n"))
        if ($Waagent) { [System.IO.File]::WriteAllText((Join-Path $rootDir 'etc' 'waagent.conf'), $Waagent) }
        foreach ($dir in $Items.Keys) {
            $at = Join-Path $rootDir ($dir.TrimStart('/'))
            [void][System.IO.Directory]::CreateDirectory($at)
            foreach ($name in @($Items[$dir])) {
                if ($name.EndsWith('/')) { [void][System.IO.Directory]::CreateDirectory((Join-Path $at $name.TrimEnd('/'))) }
                else { [System.IO.File]::WriteAllText((Join-Path $at $name), 'x') }
            }
        }
        $work
    }
    function Script:LtRun([string]$Work) {
        $rootUnix = Script:LtUnix (Join-Path $Work 'root')
        $unixScript = Script:LtUnix $script:scriptFile
        $out = & $script:bash -c "VMF_TEST_ROOT='$rootUnix' bash '$unixScript' 2>/dev/null"
        ($out | Out-String).Trim()
    }
    function Script:LtDoc([string]$Json) {
        Test-Json -Json $Json -SchemaFile $script:schemaFile -ErrorAction Stop | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ j = $Json } { param($j) ConvertFrom-VmfGuestOutput -RawOutput $j }
    }
    $script:agentItems = @('lost+found/', 'DATALOSS_WARNING_README.txt', 'swapfile')
}
AfterAll { Remove-Item 'function:\LtCtx' -ErrorAction SilentlyContinue }

Describe 'LINUX-TEMP-DISK-FILES-1: the engine asks a Linux machine about its temporary disk, as it asks Windows' {
    BeforeEach {
        $global:ltRan = [System.Collections.Generic.List[string]]::new()
        $script:answer = [pscustomobject]@{ result = 'NEEDS_PREP'; warnings = @('/mnt/cache') }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { $global:ltRan.Add($ScriptName); $script:answer }
    }

    It 'files found and the wave says stop: the Linux machine stops for a person, with the reason and setting Windows uses' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTempDiskContentStop -Context (Global:LtCtx)
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'dataOnTempDrive'
            $r.Detail | Should -Be 'The temporary disk contains these files and folders: /mnt/cache'
        }
        @($global:ltRan) | Should -Be @('temp-disk-content.sh')
    }

    It 'files found and the wave says proceed (or the decision accepted the loss): no stop' {
        InModuleScope VmMigrationFactory { Get-VmfTempDiskContentStop -Context (Global:LtCtx -OnData 'proceed') | Should -BeNullOrEmpty }
        @($global:ltRan) | Should -Be @('temp-disk-content.sh')
    }

    It 'a value of the setting that is not exactly proceed stops (fail closed), on Linux too' {
        InModuleScope VmMigrationFactory { (Get-VmfTempDiskContentStop -Context (Global:LtCtx -OnData 'Proceed')).Reason | Should -Be 'dataOnTempDrive' }
    }

    It 'nothing but the system''s own items: no stop' {
        $script:answer = [pscustomobject]@{ result = 'READY'; warnings = @() }
        InModuleScope VmMigrationFactory { Get-VmfTempDiskContentStop -Context (Global:LtCtx) | Should -BeNullOrEmpty }
    }

    It 'the Linux check itself failed: a guest preparation stop, with its error' {
        $script:answer = [pscustomobject]@{ result = 'BLOCKED'; error = 'cannot list /mnt'; warnings = @() }
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTempDiskContentStop -Context (Global:LtCtx)
            $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
            $r.Reason | Should -Be 'guestPrepBlocked'
            $r.Detail | Should -Match 'cannot list /mnt'
        }
    }

    It 'asked even when the target keeps a SCSI temporary disk: every move stops the machine' {
        InModuleScope VmMigrationFactory { (Get-VmfTempDiskContentStop -Context (Global:LtCtx -To 'scsi-temp')).Reason | Should -Be 'dataOnTempDrive' }
    }

    It 'not asked where the machine has no SCSI temporary disk now: <From>' -ForEach @(@{ From = 'diskless' }, @{ From = 'nvme-temp' }) {
        InModuleScope VmMigrationFactory -Parameters @{ from = $From } { param($from) Get-VmfTempDiskContentStop -Context (Global:LtCtx -From $from) | Should -BeNullOrEmpty }
        @($global:ltRan).Count | Should -Be 0
    }

    It 'not asked when the plan names no operating system the product knows' {
        InModuleScope VmMigrationFactory { Get-VmfTempDiskContentStop -Context (Global:LtCtx -Os '') | Should -BeNullOrEmpty }
        @($global:ltRan).Count | Should -Be 0
    }

    It 'Windows still runs its own script, and its Detail has the same form as Linux' {
        $script:answer = [pscustomobject]@{ result = 'NEEDS_PREP'; warnings = @('D:\CustomerData') }
        InModuleScope VmMigrationFactory {
            $r = Get-VmfTempDiskContentStop -Context (Global:LtCtx -Os 'Windows')
            $r.Detail | Should -Be 'The temporary disk D: contains these files and folders: D:\CustomerData'
        }
        @($global:ltRan) | Should -Be @('Test-TempDiskContent.ps1')
    }

    It 'the Windows script writes the same line forms as the Linux script: the full path, then the cut-off line' {
        $win = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-TempDiskContent.ps1')
        $win | Should -Match ([regex]::Escape('$line = [string]$item.FullName'))
        $win | Should -Match ([regex]::Escape("'1 more file or folder'"))
        $win | Should -Match ([regex]::Escape('"$more more files or folders"'))
        $win | Should -Not -Match 'data will be lost|more item\(s\)'
    }

    It 'the stop reason and the wave setting stay OS-neutral: one reason, one setting, one accept path' {
        $g = InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'dataOnTempDrive' }
        $reasons = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($reasons.reasons | Where-Object code -eq 'dataOnTempDrive')[0]
        "$($r.title) $($r.meaning) $($r.whatToDo)" | Should -Not -Match 'Windows|D:'
        $r.decide.lever | Should -Be 'onDDataFound'
        $r.decide.accept | Should -Be 'proceed'
        $g | Should -Not -BeNullOrEmpty
    }
}

Describe 'LINUX-TEMP-DISK-FILES-1: temp-disk-content.sh is a read-only guest script in the contract' {
    It 'starts #!/bin/bash, is in the manifest for linux, and is classed read-only (never followed by the neutral script)' {
        Test-Path $script:scriptFile | Should -BeTrue
        ([System.IO.File]::ReadAllLines($script:scriptFile))[0] | Should -Be '#!/bin/bash'
        $m = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        @($m.scripts | Where-Object { $_.name -eq 'temp-disk-content.sh' -and $_.os -eq 'linux' }).Count | Should -Be 1
        $follow = InModuleScope VmMigrationFactory { @($script:VmfGuestFollowUpScripts) }
        $follow | Should -Not -Contain 'temp-disk-content.sh'
    }

    It 'changes nothing: no command that writes, moves, deletes or mounts' {
        $code = Get-VmfCodeOnly -Path $script:scriptFile
        $code | Should -Not -Match '(?m)(^|[\s;|&(])(rm|mv|cp|mkdir|touch|chmod|chown|mount|umount|mkfs[.\w]*|swapoff|dd|truncate|tee)\s'
        $code | Should -Not -Match '>\s*[^&\s/]' -Because 'no redirect into a file (only 2>/dev/null and >&2)'
    }

    It 'finds the temporary disk with the shared vmf-temp-disk block, word for word' {
        $text = [System.IO.File]::ReadAllText($script:scriptFile) -replace "`r", ''
        $mine = [regex]::Match($text, '(?s)# >>> vmf-temp-disk\b.*?# <<< vmf-temp-disk').Value
        $theirs = [regex]::Match(([System.IO.File]::ReadAllText((Join-Path $script:linux 'guest-validate.sh')) -replace "`r", ''), '(?s)# >>> vmf-temp-disk\b.*?# <<< vmf-temp-disk').Value
        $mine | Should -Not -BeNullOrEmpty
        $mine | Should -Be $theirs
    }
}

Describe 'LINUX-TEMP-DISK-FILES-1: temp-disk-content.sh on a stand-in machine' -Skip:(-not $script:bash) {
    AfterEach { if ($script:work -and (Test-Path $script:work)) { [System.IO.Directory]::Delete($script:work, $true) } }

    It 'only what the system puts there (lost+found, the warning file, the swap file): READY, nothing named' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/disk/azure/resource /mnt ext4 rw 0 0') -Items @{ '/mnt' = $script:agentItems }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.script | Should -Be 'temp-disk-content.sh'
        $doc.result | Should -Be 'READY'
        @($doc.warnings).Count | Should -Be 0
        @($doc.checks | Where-Object name -eq 'temporary disk content')[0].status | Should -Be 'PASS'
    }

    It 'a customer folder and a hidden file on /mnt: NEEDS_PREP, each named, the system items not' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/disk/azure/resource /mnt ext4 rw 0 0') -Items @{ '/mnt' = ($script:agentItems + 'cache/' + '.state') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'NEEDS_PREP'
        @($doc.warnings | Sort-Object) | Should -Be @('/mnt/.state', '/mnt/cache')
        @($doc.checks | Where-Object name -eq 'temporary disk content')[0].status | Should -Be 'WARN'
    }

    It 'the Azure Linux Agent''s mount point from waagent.conf: the files there are named' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/disk/azure/resource /var/scratch ext4 rw 0 0') `
            -Items @{ '/var/scratch' = @('lost+found/', 'job.tmp') } -Waagent "ResourceDisk.Format=y`nResourceDisk.MountPoint=/var/scratch`n"
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'NEEDS_PREP'
        @($doc.warnings) | Should -Be @('/var/scratch/job.tmp')
    }

    It '/mnt/resource, where the agent mounts by default: the files there are named' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/disk/azure/resource /mnt/resource ext4 rw 0 0') -Items @{ '/mnt/resource' = @('lost+found/', 'export.csv') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        @($doc.warnings) | Should -Be @('/mnt/resource/export.csv')
    }

    It 'an active swap file in /proc/swaps is the system''s, whatever its name; a file called swap.img that is not in use is named' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/disk/azure/resource /mnt ext4 rw 0 0') `
            -Items @{ '/mnt' = @('lost+found/', 'swap.0', 'swap.img') } -Swaps @('/mnt/swap.0                             file            2097148         0               -2')
        $doc = Script:LtDoc (Script:LtRun $script:work)
        @($doc.warnings) | Should -Be @('/mnt/swap.img')
    }

    It 'a data disk mounted on a folder of the temporary disk is not named: the move keeps it' {
        $script:work = Script:LtWork -Mounts @('/dev/disk/azure/resource /mnt ext4 rw 0 0', '/dev/disk/azure/scsi1/lun0 /mnt/data xfs rw 0 0') -Items @{ '/mnt' = @('lost+found/', 'data/', 'tmp.bin') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        @($doc.warnings) | Should -Be @('/mnt/tmp.bin')
    }

    It 'a space in a path, written \040 by the kernel in /proc/mounts and /proc/swaps, is read as a space' {
        $bs = [string][char]92
        # cloud-init's source name says it is the temporary disk.
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', "/dev/disk/cloud/azure_resource-part1 /var/my${bs}040scratch ext4 rw 0 0") `
            -Items @{ '/var/my scratch' = @('lost+found/', 'swap 1', 'keep me') } `
            -Swaps @("/var/my${bs}040scratch/swap${bs}0401                       file            2097148         0               -2")
        $doc = Script:LtDoc (Script:LtRun $script:work)
        @($doc.warnings) | Should -Be @('/var/my scratch/keep me')
    }

    It 'no temporary disk on the machine: READY - a /mnt folder on the OS disk is not lost by the move' {
        $script:work = Script:LtWork -NoDevices -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/sdc1 /data xfs rw 0 0') -Items @{ '/mnt' = @('kept.txt'); '/data' = @('db.mdf') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'READY'
        @($doc.warnings).Count | Should -Be 0
        $c = @($doc.checks | Where-Object name -eq 'temporary disk content')[0]
        $c.status | Should -Be 'INFO'
        $c.detail | Should -Be 'The script found no mounted temporary disk.'
    }

    It 'the resource disk is there and not mounted: READY, and the result says it was not read' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0') -Items @{ '/mnt' = @('kept.txt') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'READY'
        @($doc.checks | Where-Object name -eq 'temporary disk content')[0].detail | Should -Be 'The temporary disk is not mounted. The script did not read it.'
    }

    It 'LINUX-MNT-DATA-DISK-1: a managed data disk mounted on <Mp> is not the temporary disk - no stop, the move keeps its files' -ForEach @(
        @{ Mp = '/mnt'; Dev = '/dev/disk/azure/scsi1/lun0' }, @{ Mp = '/mnt/resource'; Dev = '/dev/disk/azure/data/by-lun/1' }) {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', "$Dev $Mp xfs rw 0 0") -Items @{ $Mp = @('lost+found/', 'db.mdf') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'READY'
        @($doc.warnings).Count | Should -Be 0
        @($doc.checks | Where-Object name -eq 'temporary disk identity').Count | Should -Be 0 -Because 'a data disk is known, not unknown'
    }

    It 'LINUX-MNT-DATA-DISK-1: /mnt (and waagent''s mount point) from a device that is neither: not read, no stop, and the result says so' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/sdz1 /mnt ext4 rw 0 0', '/dev/sdy1 /var/scratch ext4 rw 0 0') `
            -Items @{ '/mnt' = @('cache/'); '/var/scratch' = @('job.tmp') } -Waagent "ResourceDisk.MountPoint=/var/scratch`n"
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'READY'
        @($doc.warnings).Count | Should -Be 0
        $c = @($doc.checks | Where-Object name -eq 'temporary disk identity')[0]
        $c.status | Should -Be 'INFO'
        $c.detail | Should -Be 'The script did not read /mnt, /var/scratch, because it cannot identify the device as the temporary disk.'
    }

    It 'the resource disk on any folder is the temporary disk - the device decides, not the name' {
        $script:work = Script:LtWork -Mounts @('/dev/sda1 / ext4 rw 0 0', '/dev/disk/azure/resource /scratch ext4 rw 0 0') -Items @{ '/scratch' = @('lost+found/', 'x.dat') }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        @($doc.warnings) | Should -Be @('/scratch/x.dat')
    }

    It 'more than 40 items: 40 named, then "N more files or folders"' {
        $many = @(1..45 | ForEach-Object { 'f{0:d2}' -f $_ })
        $script:work = Script:LtWork -Mounts @('/dev/disk/azure/resource /mnt ext4 rw 0 0') -Items @{ '/mnt' = $many }
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'NEEDS_PREP'
        @($doc.warnings).Count | Should -Be 41
        @($doc.warnings)[-1] | Should -Be '5 more files or folders'
    }

    It 'a temporary disk that cannot be listed: BLOCKED with the reason - never "nothing found"' {
        $script:work = Script:LtWork -Mounts @('/dev/disk/azure/resource /mnt ext4 rw 0 0')
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'BLOCKED'
        $doc.error | Should -Match '/mnt'
    }

    It 'a name with a double quote, or with a tab, still gives one object in the contract' {
        $script:work = Script:LtWork -Mounts @('/dev/disk/azure/resource /mnt ext4 rw 0 0') -Items @{ '/mnt' = @('lost+found/') }
        # Names Windows cannot hold: made through bash, which maps them.
        $mnt = Script:LtUnix (Join-Path $script:work 'root' 'mnt')
        & $script:bash -c ("cd '$mnt' && printf x > 'a" + '"' + "b' && printf x > `"`$(printf 'c%bd' '\011')`"") | Out-Null
        $doc = Script:LtDoc (Script:LtRun $script:work)
        $doc.result | Should -Be 'NEEDS_PREP'
        @($doc.warnings).Count | Should -Be 2
        @($doc.warnings) | Should -Contain '/mnt/a"b'
    }
}
