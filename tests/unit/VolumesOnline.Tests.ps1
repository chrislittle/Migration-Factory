#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VOLUMES-ONLINE-1 (final lab, 2026-11-13). The goal: on every OS type, each
# volume is online as it was before, after a migration and after a rollback.
#
# What the lab found, on Oracle Linux 9.7 (LVM root, D2s_v4 -> D2s_v6): LVM's
# devices file (/etc/lvm/devices/system.devices) names each physical volume by
# its device ID (sys_wwid). On NVMe the disk has another device ID, so LVM did
# not use the PV: /var/crash (rootvg-crashlv) was not mounted, and the move
# rolled back. The disks the rollback made from the safety copies have NEW
# device IDs too, so the volume stayed offline - and the engine said "The
# machine is back as it was", having run no check inside the machine.
#
# This file holds:
#   - the guest scripts, run here under bash with stand-ins for the LVM tools:
#     the refresh after a put-back (lvm-devices-refresh.sh), the one-time start
#     task the preparation installs (nvme-fix.sh), and the facts that
#     guest-validate.sh and cluster-node-check.sh report;
#   - the Windows list of mounted volumes (Test-GuestValidation.ps1);
#   - the engine's comparison with the reading before the move, after the move
#     (Verifying), after a rollback and after Restore this machine, with a
#     kill and resume of each (rule 4).
BeforeDiscovery {
    # The -Skip of the bash Describes is read while Pester discovers them.
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    $script:bash = Get-VmfTestBash
}
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # Every disk made from a copy is read back and its key compared, so the
    # fake Azure answers the read (as PowerAfterMove.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:linux = Join-Path $script:repoRoot 'src' 'guest' 'linux'
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json'

    # TEST-BASH-WSL-1: the bash every shell test uses (WSL on a Windows PC
    # that has it, else Git's bash; the native one on Linux), and a path in
    # the form it reads.
    $script:bash = Get-VmfTestBash

    function Script:VoUnix([string]$Path) { ConvertTo-VmfTestBashPath -Path $Path }

    # Stand-ins for the LVM tools and the few others the scripts call. Their
    # state is files in $VMF_STUB_STATE:
    #   ids      one line per disk now: "<device> <device ID> <PV UUID with dashes>"
    #   mounted  one mount point per line;  mountfail  mount points mount refuses
    #   lvs      what lvs prints;  vgs  what vgs prints;  calls  every call
    # The devices file is $VMF_LVM_DEVICES_FILE. pvs shows a PV only when the
    # devices file names its device ID now - the rule lvmdevices(8) gives -
    # unless it is called with --devicesfile "".
    $script:stubs = [ordered]@{
        lvmconfig = @'
#!/bin/bash
echo "lvmconfig $*" >> "$VMF_STUB_STATE/calls"
case "$*" in
  *use_devicesfile*) echo "${VMF_STUB_USE:-1}" ;;
  *devicesfile*) echo '"system.devices"' ;;
esac
exit 0
'@
        pvs = @'
#!/bin/bash
S="$VMF_STUB_STATE"; F="$VMF_LVM_DEVICES_FILE"
all=0; fields=pv_uuid
while [ $# -gt 0 ]; do
  case "$1" in
    --devicesfile) all=1; shift ;;
    -o) fields="$2"; shift ;;
  esac
  shift
done
while read -r dev idname uuid; do
  [ -n "$dev" ] || continue
  if [ $all -eq 0 ]; then grep -q "IDNAME=$idname " "$F" 2>/dev/null || continue; fi
  if [ "$fields" = "pv_uuid" ]; then echo "  $uuid"; else echo "  $dev $uuid"; fi
done < "$S/ids"
exit 0
'@
        lvmdevices = @'
#!/bin/bash
S="$VMF_STUB_STATE"; F="$VMF_LVM_DEVICES_FILE"
echo "lvmdevices $*" >> "$S/calls"
case "$1" in
  --help)
    echo "  --check"; echo "  --update"; echo "  --adddev"; echo "  --delpvid"
    [ "${VMF_STUB_REFRESH:-1}" = 1 ] && echo "  --refresh"
    exit 0 ;;
  --update)
    [ "$2" = "--refresh" ] || exit 0
    [ "${VMF_STUB_REFRESH_WORKS:-1}" = 1 ] || exit 5
    : > "$S/df.tmp"
    while IFS= read -r line; do
      pvid=$(printf '%s\n' "$line" | grep -o 'PVID=[^ ]*' | sed 's/PVID=//')
      new=""
      if [ -n "$pvid" ]; then
        while read -r dev idname uuid; do
          u=$(printf '%s' "$uuid" | tr -d '-')
          [ "$u" = "$pvid" ] && new="IDTYPE=sys_wwid IDNAME=$idname DEVNAME=$dev PVID=$pvid PART=2"
        done < "$S/ids"
      fi
      if [ -n "$new" ]; then echo "$new" >> "$S/df.tmp"; else echo "$line" >> "$S/df.tmp"; fi
    done < "$F"
    mv "$S/df.tmp" "$F"; exit 0 ;;
  --delpvid) grep -v "PVID=$2 " "$F" > "$S/df.tmp"; mv "$S/df.tmp" "$F"; exit 0 ;;
  --adddev)
    while read -r dev idname uuid; do
      [ "$dev" = "$2" ] && echo "IDTYPE=sys_wwid IDNAME=$idname DEVNAME=$dev PVID=$(printf '%s' "$uuid" | tr -d '-') PART=2" >> "$F"
    done < "$S/ids"
    exit 0 ;;
esac
exit 0
'@
        vgchange = @'
#!/bin/bash
echo "vgchange $*" >> "$VMF_STUB_STATE/calls"
[ -f "$VMF_STUB_STATE/lvs.after" ] && cp "$VMF_STUB_STATE/lvs.after" "$VMF_STUB_STATE/lvs"
exit 0
'@
        lvs = @'
#!/bin/bash
cat "$VMF_STUB_STATE/lvs" 2>/dev/null
exit 0
'@
        vgs = @'
#!/bin/bash
cat "$VMF_STUB_STATE/vgs" 2>/dev/null
exit 0
'@
        findmnt = @'
#!/bin/bash
S="$VMF_STUB_STATE"; mp=""; src=0
for a in "$@"; do case "$a" in -n|-o) ;; SOURCE) src=1 ;; *) mp="$a" ;; esac; done
if [ $src -eq 1 ]; then
  s=$(awk -v m="$mp" '$1 == m { print $2 }' "$S/sources" 2>/dev/null)
  if [ -n "$s" ]; then echo "$s"; exit 0; fi
  # VOLUMES-MNT-DATA-DISK-1: like findmnt, nothing for a mount point that is
  # not mounted (root is always mounted).
  if [ "$mp" = "/" ] || grep -qxF -- "$mp" "$S/mounted" 2>/dev/null; then echo "/dev/mapper/rootvg-rootlv"; exit 0; fi
  exit 1
fi
grep -qxF -- "$mp" "$S/mounted" 2>/dev/null
'@
        mount = @'
#!/bin/bash
S="$VMF_STUB_STATE"
echo "mount $*" >> "$S/calls"
if grep -qxF -- "$1" "$S/mountfail" 2>/dev/null; then echo "mount: $1: special device does not exist." >&2; exit 32; fi
echo "$1" >> "$S/mounted"
exit 0
'@
        udevadm = @'
#!/bin/bash
echo "udevadm $*" >> "$VMF_STUB_STATE/calls"
exit 0
'@
        systemctl = @'
#!/bin/bash
echo "systemctl $*" >> "$VMF_STUB_STATE/calls"
if [ "$1" = is-active ]; then echo inactive; exit 3; fi
exit 0
'@
        # VOLUMES-MNT-DATA-DISK-1: findfs resolves a UUID= or LABEL= source
        # from state/uuids ("<source> <device>"); nothing for one not listed.
        findfs = @'
#!/bin/bash
awk -v s="$1" '$1 == s { print $2; found = 1 } END { exit !found }' "$VMF_STUB_STATE/uuids" 2>/dev/null
'@
        logger = @'
#!/bin/bash
exit 0
'@
    }

    # One work folder: bin (the stand-ins), state, the devices file, an fstab
    # and a root for the files a script installs.
    function Script:VoWork {
        param([string[]]$Ids, [string[]]$DevFile, [string[]]$Fstab, [string[]]$Mounted = @(), [string[]]$MountFail = @(), [string[]]$Lvs = @(), [string[]]$Vgs = @())
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        foreach ($d in 'bin', 'state', 'root', 'etc') { $null = New-Item -ItemType Directory -Path (Join-Path $work $d) -Force }
        foreach ($k in $script:stubs.Keys) { [System.IO.File]::WriteAllText((Join-Path $work 'bin' $k), ($script:stubs[$k] -replace "`r", '')) }
        $w = { param($name, $lines) [System.IO.File]::WriteAllText((Join-Path $work $name), ((@($lines) -join "`n") + $(if (@($lines).Count) { "`n" } else { '' }))) }
        & $w 'state/ids' $Ids
        & $w 'state/mounted' $Mounted
        & $w 'state/mountfail' $MountFail
        & $w 'state/lvs' $Lvs
        & $w 'state/vgs' $Vgs
        & $w 'state/calls' @()
        & $w 'etc/system.devices' $DevFile
        & $w 'etc/fstab' $Fstab
        $work
    }

    # Run one guest script under bash with the stand-ins first on the PATH.
    function Script:VoRun {
        param([string]$Work, [string]$Script, [hashtable]$Env = @{})
        $bin = Script:VoUnix (Join-Path $Work 'bin')
        $all = @{ VMF_STUB_STATE = (Script:VoUnix (Join-Path $Work 'state')); VMF_LVM_DEVICES_FILE = (Script:VoUnix (Join-Path $Work 'etc' 'system.devices'))
                  VMF_FSTAB = (Script:VoUnix (Join-Path $Work 'etc' 'fstab')); VMF_TEST_ROOT = (Script:VoUnix (Join-Path $Work 'root')) }
        foreach ($k in $Env.Keys) { $all[$k] = $Env[$k] }
        $envWords = ($all.Keys | Sort-Object | ForEach-Object { "$_='$($all[$_])'" }) -join ' '
        $target = if ([System.IO.Path]::IsPathRooted($Script)) { $Script } else { Join-Path $script:linux $Script }
        $unixScript = Script:VoUnix $target
        $out = Invoke-VmfTestBash -ArgumentList @('-c', "chmod +x '$bin'/*; PATH='$($bin):'`$PATH $envWords bash '$unixScript' 2>/dev/null")
        ($out | Out-String).Trim()
    }
    function Script:VoDoc([string]$Json) {
        Test-Json -Json $Json -SchemaFile $script:schemaFile -ErrorAction Stop | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ j = $Json } { ConvertFrom-VmfGuestOutput -RawOutput $j }
    }
    function Script:VoCheck($Doc, [string]$Name) { @($Doc.checks | Where-Object { $_.name -eq $Name }) | Select-Object -First 1 }
    function Script:VoState([string]$Work, [string]$Name) { [System.IO.File]::ReadAllText((Join-Path $Work $Name)) }

    # The lab's shape: the root PV was on the SCSI disk, named by its old
    # device ID; now the same PV is on another device with another ID.
    $script:pvUuid = 'aaaaaa-bbbb-cccc-dddd-eeee-ffff-000001'
    $script:pvid = 'aaaaaabbbbccccddddeeeeffff000001'
    $script:devHeader = @('# LVM uses devices listed in this file.', '# Created by LVM command lvmdevices', 'VERSION=1.1.5', 'PRODUCT_UUID=00000000-0000-0000-0000-000000000000')
    $script:oldEntry = "IDTYPE=sys_wwid IDNAME=naa.60022480old0000000000000000000001 DEVNAME=/dev/sda3 PVID=$($script:pvid) PART=3"
    $script:newIds = @("/dev/sdb3 naa.60022480new0000000000000000000002 $($script:pvUuid)")
    $script:fstab = @(
        '# /etc/fstab'
        '/dev/mapper/rootvg-rootlv / xfs defaults 0 0'
        'UUID=0000-boot /boot xfs defaults 0 0'
        'UUID=0000-efi /boot/efi vfat defaults,uid=0,gid=0 0 2'
        '/dev/mapper/rootvg-crashlv /var/crash xfs defaults 0 0'
        '/dev/mapper/rootvg-swaplv none swap defaults 0 0'
        '/dev/mapper/rootvg-optlv /opt/manual xfs noauto 0 0'
        'server.example.com:/share /mnt/share nfs defaults 0 0'
        '/dev/disk/cloud/azure_resource-part1 /mnt auto defaults,nofail 0 2')
}

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface', 'function:\VoEngineStep', 'function:\VoOut', 'function:\VoPending' -ErrorAction SilentlyContinue
    Remove-Variable voPower, voOrder, voFail, voAnswers, voRunPath, voKill, voValidate -Scope Global -ErrorAction SilentlyContinue
}

Describe 'VOLUMES-ONLINE-1: the engine compares the mounted volumes with the reading before the move' {
    BeforeAll {
        function Script:VoGuest($Mounted, [hashtable[]]$More = @()) {
            [pscustomobject]@{ checks = @(@(if ($null -ne $Mounted) { [pscustomobject]@{ name = 'mounted volumes'; status = 'INFO'; detail = $Mounted } }) + @($More | ForEach-Object { [pscustomobject]$_ })) }
        }
        function Script:VoBack($b, $a, [switch]$Case) {
            InModuleScope VmMigrationFactory -Parameters @{ b = $b; a = $a; c = [bool]$Case } { param($b, $a, $c) Test-VmfVolumesBack -Before $b -After $a -CaseSensitive:$c }
        }
    }

    It 'every volume mounted before is mounted after: MATCH, and the volumes are named' {
        $r = Script:VoBack (Script:VoGuest '/; /boot; /var/crash') (Script:VoGuest '/; /boot; /var/crash') -Case
        $r.Verdict | Should -Be 'MATCH'
        $r.Ok | Should -BeTrue
        @($r.Missing) | Should -BeNullOrEmpty
        $r.Detail | Should -Match '/var/crash'
    }

    It 'a volume mounted before and not after: MISSING, not Ok, and it names that volume only' {
        $r = Script:VoBack (Script:VoGuest '/; /boot; /var/crash') (Script:VoGuest '/; /boot') -Case
        $r.Verdict | Should -Be 'MISSING'
        $r.Ok | Should -BeFalse
        @($r.Missing) | Should -Be @('/var/crash')
        $r.Detail | Should -Match '/var/crash'
        $r.Detail | Should -Not -Match '/boot\b.*not mounted'
    }

    It 'more volumes after than before is not a failure - only losing one is' {
        (Script:VoBack (Script:VoGuest '/') (Script:VoGuest '/; /data') -Case).Verdict | Should -Be 'MATCH'
    }

    It 'Windows letters compare without case; Linux paths compare with case' {
        (Script:VoBack (Script:VoGuest 'C:\; F:\') (Script:VoGuest 'c:\; f:\')).Verdict | Should -Be 'MATCH'
        (Script:VoBack (Script:VoGuest '/Data') (Script:VoGuest '/data') -Case).Verdict | Should -Be 'MISSING'
    }

    It "'none' is a real answer: no volume before and none after matches" {
        (Script:VoBack (Script:VoGuest 'none') (Script:VoGuest 'none') -Case).Verdict | Should -Be 'MATCH'
        (Script:VoBack (Script:VoGuest '/data') (Script:VoGuest 'none') -Case).Verdict | Should -Be 'MISSING'
        # 'none' is no volume, never a mount point named none.
        (Script:VoBack (Script:VoGuest 'none') (Script:VoGuest '/data') -Case).Verdict | Should -Be 'MATCH'
        # Read as the engine reads it (one assignment), inside the module: an empty
        # list is not $null (not asked). Counting the pipeline output from outside
        # InModuleScope depends on how the empty array travels, not on the rule.
        (InModuleScope VmMigrationFactory -Parameters @{ g = (Script:VoGuest 'none') } { param($g) $v = Get-VmfMountedVolumes -GuestOutput $g; $null -ne $v -and @($v).Count -eq 0 }) | Should -BeTrue
    }

    It 'a side that was not asked is UNKNOWN - never a pass, never a fail - and the words say which side' {
        $r = Script:VoBack $null (Script:VoGuest '/') -Case
        $r.Verdict | Should -Be 'UNKNOWN'
        $r.Ok | Should -BeTrue
        $r.Detail | Should -Match 'before'
        $r = Script:VoBack (Script:VoGuest '/') (Script:VoGuest $null) -Case
        $r.Verdict | Should -Be 'UNKNOWN'
        $r.Detail | Should -Match 'after'
    }

    It 'the devices file fact is read from the check the guest scripts report' {
        $f = { param($d) InModuleScope VmMigrationFactory -Parameters @{ g = (Script:VoGuest $null @(@{ name = 'lvm devices file'; status = 'INFO'; detail = $d })) } { param($g) Get-VmfLvmDevicesFileFact -GuestOutput $g } }
        $x = & $f 'in use (/etc/lvm/devices/system.devices): 2 physical volume(s), 1 not found: abc'
        $x.State | Should -Be 'inUse'; $x.NotFound | Should -Be 1; $x.Total | Should -Be 2
        $x = & $f 'in use (/etc/lvm/devices/system.devices): 1 physical volume(s), every one found'
        $x.State | Should -Be 'inUse'; $x.NotFound | Should -Be 0
        (& $f 'not in use').State | Should -Be 'notInUse'
        (& $f 'LVM is not installed').State | Should -Be 'noLvm'
        (InModuleScope VmMigrationFactory { Get-VmfLvmDevicesFileFact -GuestOutput ([pscustomobject]@{ checks = @() }) }).State | Should -Be 'unknown'
    }
}

Describe 'VOLUMES-ONLINE-1: the LVM blocks are one text in every script' -Skip:(-not $script:bash) {
    It 'each marked block reads the same wherever it is, and is where it must be' {
        # VOLUMES-ONLINE-V5-1: the start task is installed by nvme-fix.sh (a
        # move to NVMe) and by lvm-devices-task.sh (a move to v5 or Bsv2) -
        # one text, vmf-lvm-task.
        $want = @{ 'vmf-lvm-facts' = @('cluster-node-check.sh', 'guest-validate.sh', 'lvm-devices-refresh.sh', 'lvm-devices-task.sh', 'nvme-fix.sh'); 'vmf-lvm-refresh' = @('lvm-devices-refresh.sh', 'lvm-devices-task.sh', 'nvme-fix.sh'); 'vmf-temp-disk' = @('guest-validate.sh', 'lvm-devices-refresh.sh', 'temp-disk-content.sh')
                   'vmf-lvm-task' = @('lvm-devices-task.sh', 'nvme-fix.sh') }
        foreach ($block in $want.Keys) {
            $seen = @{}
            foreach ($f in Get-ChildItem $script:linux -Filter '*.sh') {
                $text = [System.IO.File]::ReadAllText($f.FullName) -replace "`r", ''
                $found = [regex]::Matches($text, "(?s)# >>> $block\b.*?# <<< $block")
                foreach ($m in $found) { $seen[$f.Name] = @(@($seen[$f.Name]) + $m.Value | Where-Object { $_ }) }
            }
            @($seen.Keys | Sort-Object) | Should -Be @($want[$block] | Sort-Object) -Because "the $block block is in these scripts"
            $all = @($seen.Values | ForEach-Object { $_ })
            @($all | Sort-Object -Unique).Count | Should -Be 1 -Because "every copy of $block is the same text"
        }
        # nvme-fix.sh carries both blocks again inside the start task it writes.
        $fix = [System.IO.File]::ReadAllText((Join-Path $script:linux 'nvme-fix.sh'))
        [regex]::Matches($fix, '# >>> vmf-lvm-facts').Count | Should -Be 2
        [regex]::Matches($fix, '# >>> vmf-lvm-refresh').Count | Should -Be 1
        $task = [System.IO.File]::ReadAllText((Join-Path $script:linux 'lvm-devices-task.sh'))
        [regex]::Matches($task, '# >>> vmf-lvm-facts').Count | Should -Be 2
        [regex]::Matches($task, '# >>> vmf-lvm-refresh').Count | Should -Be 1
        [regex]::Matches($task, '# >>> vmf-lvm-task').Count | Should -Be 1
    }
}

Describe 'VOLUMES-ONLINE-V5-1: lvm-devices-task.sh installs the same one-time start task for a move to v5 or Bsv2' -Skip:(-not $script:bash) {
    AfterEach { if ($script:work -and (Test-Path $script:work)) { [System.IO.Directory]::Delete($script:work, $true) } }

    It 'the devices file is in use: the task and its unit are written and enabled, and the devices file is not changed' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-task.sh')
        $doc.result | Should -Be 'FIXED'
        $c = Script:VoCheck $doc 'lvm devices file'
        $c.status | Should -Be 'FIXED'
        $c.detail | Should -Match 'vmf-lvm-devices-refresh\.service'
        $c.detail | Should -Match 'at the first start after the move'
        Test-Path (Join-Path $script:work 'root' 'usr' 'local' 'sbin' 'vmf-lvm-devices-refresh.sh') | Should -BeTrue
        $u = [System.IO.File]::ReadAllText((Join-Path $script:work 'root' 'etc' 'systemd' 'system' 'vmf-lvm-devices-refresh.service'))
        $u | Should -Match '(?m)^Before=local-fs-pre\.target$'
        (Script:VoState $script:work 'state/calls') | Should -Match 'systemctl enable vmf-lvm-devices-refresh\.service'
        (Script:VoState $script:work 'etc/system.devices') | Should -Match 'IDNAME=naa\.60022480old'
        (Script:VoState $script:work 'etc/fstab') | Should -Be ((@($script:fstab) -join "`n") + "`n") -Because 'a v5 move changes nothing else: no fstab rewrite, no initramfs'
    }

    It 'run again, it says the task is there and changes nothing' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $null = Script:VoRun $script:work 'lvm-devices-task.sh'
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-task.sh')
        $doc.result | Should -Be 'NO_CHANGE'
        (Script:VoCheck $doc 'lvm devices file').status | Should -Be 'PASS'
    }

    It 'the devices file is not in use: nothing is installed, NO_CHANGE' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-task.sh' @{ VMF_STUB_USE = '0' })
        $doc.result | Should -Be 'NO_CHANGE'
        (Script:VoCheck $doc 'lvm devices file').detail | Should -Be 'not in use'
        Test-Path (Join-Path $script:work 'root' 'etc' 'systemd' 'system' 'vmf-lvm-devices-refresh.service') | Should -BeFalse
    }

    It 'the task enable fails: BLOCKED, and the check says so' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        [System.IO.File]::WriteAllText((Join-Path $script:work 'bin' 'systemctl'), "#!/bin/bash`necho `"systemctl `$*`" >> `"`$VMF_STUB_STATE/calls`"`n[ `"`$1`" = enable ] && exit 1`nexit 0`n")
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-task.sh')
        $doc.result | Should -Be 'BLOCKED'
        $c = Script:VoCheck $doc 'lvm devices file'
        $c.status | Should -Be 'FAIL'
        $c.detail | Should -Match '^The product could not enable vmf-lvm-devices-refresh\.service\. '
    }

    It 'after the move the task it installed refreshes the file and removes itself' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $null = Script:VoRun $script:work 'lvm-devices-task.sh'
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'ids'), "/dev/sdb3 naa.60022480new0000000000000000000002 $($script:pvUuid)`n")
        $task = Join-Path $script:work 'root' 'usr' 'local' 'sbin' 'vmf-lvm-devices-refresh.sh'
        $null = Script:VoRun $script:work $task
        (Script:VoState $script:work 'etc/system.devices') | Should -Match 'IDNAME=naa\.60022480new'
        Test-Path $task | Should -BeFalse
    }

    It 'keeps its shebang: a payload with none runs under sh (CLAUDE.md)' {
        ([System.IO.File]::ReadAllLines((Join-Path $script:linux 'lvm-devices-task.sh')))[0] | Should -Be '#!/bin/bash'
    }

    It 'is in the manifest, is a preparation script, and so is followed by the neutral script' {
        InModuleScope VmMigrationFactory {
            (Get-VmfGuestScript -Name 'lvm-devices-task.sh').Os | Should -Be 'linux'
            $script:VmfGuestChangerScripts | Should -Contain 'lvm-devices-task.sh'
            $script:VmfGuestFollowUpScripts | Should -Contain 'lvm-devices-task.sh'
        }
    }
}

Describe 'VOLUMES-ONLINE-1: lvm-devices-refresh.sh after a rollback or a restore' -Skip:(-not $script:bash) {
    AfterEach { if ($script:work -and (Test-Path $script:work)) { [System.IO.Directory]::Delete($script:work, $true) } }

    It 'the PV is on a new device ID: lvmdevices --update --refresh, a backup first, vgchange -aay, then /var/crash is mounted' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab `
            -Mounted @('/', '/boot', '/boot/efi') -Lvs @('  active') -Vgs @()
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'lvs.after'), "  active`n  active`n")
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh')
        $doc.result | Should -Be 'FIXED'
        (Script:VoCheck $doc 'lvm devices file').detail | Should -Match '1 not found'
        $r = Script:VoCheck $doc 'lvm devices refresh'
        $r.status | Should -Be 'FIXED'
        $r.detail | Should -Match 'lvmdevices --update --refresh'
        $file = Script:VoState $script:work 'etc/system.devices'
        $file | Should -Match 'IDNAME=naa\.60022480new'
        $file | Should -Not -Match 'IDNAME=naa\.60022480old'
        $file | Should -Match 'VERSION=1\.1\.5' -Because 'the header lines stay'
        @(Get-ChildItem (Join-Path $script:work 'etc') -Filter 'system.devices.vmf-bak*') | Should -HaveCount 1 -Because 'the file is copied before it changes'
        $calls = Script:VoState $script:work 'state/calls'
        $calls | Should -Match 'vgchange -aay'
        (Script:VoCheck $doc 'lvm activation').status | Should -Be 'FIXED'
        $m = Script:VoCheck $doc 'fstab mounts after refresh'
        $m.status | Should -Be 'FIXED'
        $m.detail | Should -Match '/var/crash'
        $mounted = Script:VoState $script:work 'state/mounted'
        $mounted | Should -Match '(?m)^/var/crash$'
        foreach ($not in '/opt/manual', '/mnt/share', '/mnt', 'none') {
            $calls | Should -Not -Match "mount $([regex]::Escape($not))(\s|$)" -Because "$not is noauto, a network share, the temporary disk or swap"
        }
    }

    It 'a copy that is there is kept: the devices file is copied once, never over an earlier copy' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi')
        [System.IO.File]::WriteAllText((Join-Path $script:work 'etc' 'system.devices.vmf-bak'), "THE FIRST COPY`n")
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh')
        $doc.result | Should -Be 'FIXED'
        (Script:VoState $script:work 'etc/system.devices.vmf-bak') | Should -Be "THE FIRST COPY`n"
        @(Get-ChildItem (Join-Path $script:work 'etc') -Filter 'system.devices.vmf-bak*') | Should -HaveCount 1
    }

    It 'the temporary disk at a path of its own is not mounted by it' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab @($script:fstab + 'UUID=0000-scr /data/scratch ext4 defaults 0 2') -Mounted @('/', '/boot', '/boot/efi')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:work 'root' 'etc') -Force
        [System.IO.File]::WriteAllText((Join-Path $script:work 'root' 'etc' 'waagent.conf'), "ResourceDisk.Format=y`nResourceDisk.MountPoint=/data/scratch`n")
        # VOLUMES-MNT-DATA-DISK-1: known by its device - the UUID resolves to the resource disk.
        $null = New-Item -ItemType Directory -Path (Join-Path $script:work 'root' 'dev' 'disk' 'azure') -Force
        $res = Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'resource'
        [System.IO.File]::WriteAllText($res, '')
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'uuids'), "UUID=0000-scr $(Script:VoUnix $res)1`n")
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh')
        (Script:VoState $script:work 'state/calls') | Should -Not -Match 'mount /data/scratch'
        (Script:VoCheck $doc 'fstab mounts after refresh').detail | Should -Match '/var/crash'
    }

    It 'VOLUMES-MNT-DATA-DISK-1: a data disk on /mnt that is not mounted is mounted; the resource disk entry is not' {
        $fstab = @($script:fstab | Where-Object { $_ -notmatch ' /mnt auto ' }) + 'UUID=0000-mnt /mnt xfs defaults 0 2' + 'UUID=0000-res /mnt/resource ext4 defaults,nofail 0 2'
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $fstab -Mounted @('/', '/boot', '/boot/efi')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'scsi1') -Force
        $res = Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'resource'
        $lun = Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'scsi1' 'lun0'
        [System.IO.File]::WriteAllText($res, ''); [System.IO.File]::WriteAllText($lun, '')
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'uuids'), "UUID=0000-mnt $(Script:VoUnix $lun)1`nUUID=0000-res $(Script:VoUnix $res)1`n")
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh')
        $calls = Script:VoState $script:work 'state/calls'
        $calls | Should -Match '(?m)^mount /mnt$'
        $calls | Should -Not -Match 'mount /mnt/resource'
        (Script:VoCheck $doc 'fstab mounts after refresh').detail | Should -Match '/mnt( |$)'
    }

    It 'an lvm2 with no --refresh: the old entry goes by its PVID (--delpvid) and the device is added again (--adddev)' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi')
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh' @{ VMF_STUB_REFRESH = '0' })
        $doc.result | Should -Be 'FIXED'
        (Script:VoCheck $doc 'lvm devices refresh').detail | Should -Match 'lvmdevices --adddev'
        $calls = Script:VoState $script:work 'state/calls'
        $calls | Should -Match "lvmdevices --delpvid $($script:pvid)"
        $calls | Should -Match 'lvmdevices --adddev /dev/sdb3'
        $calls | Should -Not -Match 'lvmdevices --update --refresh'
        (Script:VoState $script:work 'etc/system.devices') | Should -Match 'IDNAME=naa\.60022480new'
    }

    It 'a --refresh that finds nothing falls back to --delpvid and --adddev' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi')
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh' @{ VMF_STUB_REFRESH_WORKS = '0' })
        $doc.result | Should -Be 'FIXED'
        (Script:VoCheck $doc 'lvm devices refresh').detail | Should -Match 'lvmdevices --adddev'
    }

    It 'the devices file is not in use: nothing is written, nothing is activated or mounted' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi')
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh' @{ VMF_STUB_USE = '0' })
        $doc.result | Should -Be 'NO_CHANGE'
        (Script:VoCheck $doc 'lvm devices file').detail | Should -Be 'not in use'
        $calls = Script:VoState $script:work 'state/calls'
        $calls | Should -Not -Match 'lvmdevices --(update|adddev|delpvid)'
        $calls | Should -Not -Match 'vgchange'
        $calls | Should -Not -Match 'mount '
    }

    It 'every PV is found and every entry is mounted: NO_CHANGE, and the file is not copied' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi', '/var/crash') -Lvs @('  active')
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh')
        $doc.result | Should -Be 'NO_CHANGE'
        (Script:VoCheck $doc 'lvm devices refresh').status | Should -Be 'PASS'
        @(Get-ChildItem (Join-Path $script:work 'etc') -Filter 'system.devices.vmf-bak*') | Should -BeNullOrEmpty
    }

    It 'a PV on no device at all: BLOCKED, and the check names the PVID; a mount that fails is named too' {
        $script:work = Script:VoWork -Ids @() -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi') -MountFail @('/var/crash')
        $doc = Script:VoDoc (Script:VoRun $script:work 'lvm-devices-refresh.sh')
        $doc.result | Should -Be 'BLOCKED'
        $r = Script:VoCheck $doc 'lvm devices refresh'
        $r.status | Should -Be 'FAIL'
        $r.detail | Should -Match $script:pvid
        $m = Script:VoCheck $doc 'fstab mounts after refresh'
        $m.status | Should -Be 'FAIL'
        $m.detail | Should -Match '/var/crash'
    }

    It 'keeps its shebang: a payload with none runs under sh (CLAUDE.md)' {
        ([System.IO.File]::ReadAllLines((Join-Path $script:linux 'lvm-devices-refresh.sh')))[0] | Should -Be '#!/bin/bash'
    }
}

Describe 'VOLUMES-ONLINE-1: nvme-fix.sh installs a one-time start task that refreshes the devices file on NVMe' -Skip:(-not $script:bash) {
    AfterEach { if ($script:work -and (Test-Path $script:work)) { [System.IO.Directory]::Delete($script:work, $true) } }

    It 'the devices file is in use: the task and its unit are written, ordered before the file systems mount, and enabled' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $doc = Script:VoDoc (Script:VoRun $script:work 'nvme-fix.sh')
        $c = Script:VoCheck $doc 'lvm devices file'
        $c.status | Should -Be 'FIXED'
        $c.detail | Should -Match 'vmf-lvm-devices-refresh\.service'
        $task = Join-Path $script:work 'root' 'usr' 'local' 'sbin' 'vmf-lvm-devices-refresh.sh'
        $unit = Join-Path $script:work 'root' 'etc' 'systemd' 'system' 'vmf-lvm-devices-refresh.service'
        Test-Path $task | Should -BeTrue
        Test-Path $unit | Should -BeTrue
        $u = [System.IO.File]::ReadAllText($unit)
        $u | Should -Match '(?m)^DefaultDependencies=no$'
        $u | Should -Match '(?m)^After=.*systemd-remount-fs\.service' -Because 'the task writes /etc/lvm/devices, so the root file system must be writable'
        $u | Should -Match '(?m)^Before=local-fs-pre\.target$' -Because 'the volume groups must be active before fstab is mounted'
        $u | Should -Match '(?m)^WantedBy=sysinit\.target$'
        $u | Should -Match '(?m)^ExecStart=/usr/local/sbin/vmf-lvm-devices-refresh\.sh$'
        ([System.IO.File]::ReadAllLines($task))[0] | Should -Be '#!/bin/bash'
        (Script:VoState $script:work 'state/calls') | Should -Match 'systemctl enable vmf-lvm-devices-refresh\.service'
        (Script:VoState $script:work 'etc/system.devices') | Should -Match 'IDNAME=naa\.60022480old' -Because 'the preparation changes nothing in the devices file itself'
    }

    It 'run again, it changes nothing new and says the task is there' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $null = Script:VoRun $script:work 'nvme-fix.sh'
        $doc = Script:VoDoc (Script:VoRun $script:work 'nvme-fix.sh')
        (Script:VoCheck $doc 'lvm devices file').status | Should -Be 'PASS'
    }

    It 'the devices file is not in use: nothing is installed' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $doc = Script:VoDoc (Script:VoRun $script:work 'nvme-fix.sh' @{ VMF_STUB_USE = '0' })
        $c = Script:VoCheck $doc 'lvm devices file'
        $c.status | Should -Be 'PASS'
        $c.detail | Should -Be 'not in use'
        Test-Path (Join-Path $script:work 'root' 'etc' 'systemd' 'system' 'vmf-lvm-devices-refresh.service') | Should -BeFalse
    }

    It 'at the first start on NVMe the task refreshes the file, activates the groups, and removes itself' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $null = Script:VoRun $script:work 'nvme-fix.sh'
        # The move: the same PV, another device and device ID.
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'ids'), "/dev/nvme0n1p3 eui.0025384c0000000000000002 $($script:pvUuid)`n")
        $task = Join-Path $script:work 'root' 'usr' 'local' 'sbin' 'vmf-lvm-devices-refresh.sh'
        $null = Script:VoRun $script:work $task
        (Script:VoState $script:work 'etc/system.devices') | Should -Match 'IDNAME=eui\.0025384c'
        $calls = Script:VoState $script:work 'state/calls'
        $calls | Should -Match 'udevadm settle'
        $calls | Should -Match 'vgchange -aay'
        $calls | Should -Match 'systemctl disable vmf-lvm-devices-refresh\.service'
        Test-Path $task | Should -BeFalse -Because 'a one-time task removes itself'
        Test-Path (Join-Path $script:work 'root' 'etc' 'systemd' 'system' 'vmf-lvm-devices-refresh.service') | Should -BeFalse
    }

    It 'a start where a PV is still not found ends the task too: once only, the copy kept, and Verifying finds the volume' {
        # Before: the task stayed and ran - and copied the file - at every
        # start. A PV that is on no device is not found by a later start
        # either; Verifying finds its volume not mounted and rolls back.
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $null = Script:VoRun $script:work 'nvme-fix.sh'
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'ids'), '')
        $task = Join-Path $script:work 'root' 'usr' 'local' 'sbin' 'vmf-lvm-devices-refresh.sh'
        $null = Script:VoRun $script:work $task
        Test-Path $task | Should -BeFalse
        $calls = Script:VoState $script:work 'state/calls'
        $calls | Should -Match 'systemctl disable vmf-lvm-devices-refresh\.service'
        $calls | Should -Match 'vgchange -aay'
        @(Get-ChildItem (Join-Path $script:work 'etc') -Filter 'system.devices.vmf-bak*') | Should -HaveCount 1
    }
}

Describe 'VOLUMES-ONLINE-1: guest-validate.sh reports the mounted volumes and the devices file' -Skip:(-not $script:bash) {
    AfterEach { if ($script:work -and (Test-Path $script:work)) { [System.IO.Directory]::Delete($script:work, $true) } }

    It 'mounted volumes: every fstab mount point that is mounted, but not swap, noauto, a network share or the temporary disk' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab `
            -Mounted @('/', '/boot', '/boot/efi', '/var/crash', '/opt/manual', '/mnt/share', '/mnt') -Lvs @('  rootlv rootvg') -Vgs @('  rootvg 0')
        $doc = Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')
        (Script:VoCheck $doc 'mounted volumes').detail | Should -Be '/; /boot; /boot/efi; /var/crash'
        # Swap is never mounted and a start does not mount noauto: neither is a
        # volume group that did not assemble.
        (Script:VoCheck $doc 'lvm volumes mounted').detail | Should -Be 'every LVM entry in fstab is mounted'
    }

    It 'the temporary disk is not a mounted volume: by the agent setting, and by the device Azure names, at any path' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) `
            -Fstab @($script:fstab + 'UUID=0000-scr /data/scratch ext4 defaults,nofail 0 2' + 'UUID=0000-res /resource2 ext4 defaults 0 2' + 'UUID=0000-dat /data ext4 defaults 0 2') `
            -Mounted @('/', '/boot', '/boot/efi', '/var/crash', '/data/scratch', '/resource2', '/data') -Vgs @('  rootvg 0')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:work 'root' 'etc'), (Join-Path $script:work 'root' 'dev' 'disk' 'azure') -Force
        [System.IO.File]::WriteAllText((Join-Path $script:work 'root' 'etc' 'waagent.conf'), "ResourceDisk.MountPoint=/data/scratch`n")
        $res = Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'resource'
        [System.IO.File]::WriteAllText($res, '')
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'sources'), "/data/scratch $(Script:VoUnix $res)1`n/resource2 $(Script:VoUnix $res)1`n/data /dev/sdc1`n")
        $doc = Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')
        (Script:VoCheck $doc 'mounted volumes').detail | Should -Be '/; /boot; /boot/efi; /var/crash; /data'
    }

    It 'VOLUMES-MNT-DATA-DISK-1: a managed data disk mounted on /mnt is a mounted volume; the resource disk on /mnt is not; a device that is not known is compared' {
        $fstab = @($script:fstab | Where-Object { $_ -notmatch ' /mnt auto ' }) + 'UUID=0000-mnt /mnt xfs defaults 0 2'
        $mounted = @('/', '/boot', '/boot/efi', '/var/crash', '/mnt')
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $fstab -Mounted $mounted -Vgs @('  rootvg 0')
        $null = New-Item -ItemType Directory -Path (Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'scsi1') -Force
        $res = Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'resource'
        $lun = Join-Path $script:work 'root' 'dev' 'disk' 'azure' 'scsi1' 'lun0'
        [System.IO.File]::WriteAllText($res, ''); [System.IO.File]::WriteAllText($lun, '')
        # The data disk (LUN 0) on /mnt: compared.
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'sources'), "/mnt $(Script:VoUnix $lun)1`n")
        (Script:VoCheck (Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')) 'mounted volumes').detail | Should -Be '/; /boot; /boot/efi; /var/crash; /mnt'
        # The resource disk on /mnt: the temporary disk, not compared.
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'sources'), "/mnt $(Script:VoUnix $res)1`n")
        (Script:VoCheck (Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')) 'mounted volumes').detail | Should -Be '/; /boot; /boot/efi; /var/crash'
        # A device that is neither, with no resource disk link at all: compared, never left out.
        Remove-Item $res
        [System.IO.File]::WriteAllText((Join-Path $script:work 'state' 'sources'), "/mnt /dev/sdq1`n")
        (Script:VoCheck (Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')) 'mounted volumes').detail | Should -Be '/; /boot; /boot/efi; /var/crash; /mnt'
    }

    It 'the devices file fact names the PV LVM does not use' {
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi')
        $doc = Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')
        (Script:VoCheck $doc 'lvm devices file').detail | Should -Match "in use \(.*system\.devices\): 1 physical volume\(s\), 1 not found: $($script:pvid)"
    }

    It 'a devices file that hides the root volume group is 0 groups, and the LVM entry is NOT MOUNTED - so the comparison fails it' {
        # The lab after the rollback: pvs and vgs show nothing, root still runs
        # from the initramfs, /var/crash is not mounted. Before, the topology
        # block was skipped when vgs showed nothing, and the comparison said
        # MATCH.
        $script:work = Script:VoWork -Ids $script:newIds -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab -Mounted @('/', '/boot', '/boot/efi') -Vgs @() -Lvs @()
        $doc = Script:VoDoc (Script:VoRun $script:work 'guest-validate.sh')
        (Script:VoCheck $doc 'lvm topology').detail | Should -Be '0 volume group(s), 0 logical volume(s)'
        (Script:VoCheck $doc 'lvm volumes mounted').detail | Should -Match 'NOT MOUNTED:.*/var/crash'
        $before = [pscustomobject]@{ checks = @(
            [pscustomobject]@{ name = 'lvm root'; status = 'INFO'; detail = 'root is on LVM (/dev/mapper/rootvg-rootlv)' }
            [pscustomobject]@{ name = 'lvm topology'; status = 'INFO'; detail = '1 volume group(s), 4 logical volume(s)' }
            [pscustomobject]@{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' }) }
        (InModuleScope VmMigrationFactory -Parameters @{ b = $before; a = $doc } { param($b, $a) Test-VmfStorageTopology -Before $b -After $a }).Verdict | Should -Be 'MISMATCH'
    }
}

Describe 'VOLUMES-ONLINE-1: Checking reads the devices file as a fact' -Skip:(-not $script:bash) {
    AfterEach { if ($script:work -and (Test-Path $script:work)) { [System.IO.Directory]::Delete($script:work, $true) } }

    It 'cluster-node-check.sh reports it, and its answer stays READY' {
        $same = @("/dev/sda3 naa.60022480old0000000000000000000001 $($script:pvUuid)")
        $script:work = Script:VoWork -Ids $same -DevFile @($script:devHeader + $script:oldEntry) -Fstab $script:fstab
        $doc = Script:VoDoc (Script:VoRun $script:work 'cluster-node-check.sh' @{ VMF_MSSQL_CONF = '/nonexistent/mssql.conf' })
        $doc.result | Should -Be 'READY'
        (Script:VoCheck $doc 'lvm devices file').detail | Should -Match 'in use \(.*\): 1 physical volume\(s\), every one found'
    }
}

Describe 'VOLUMES-ONLINE-1: the Windows list of mounted volumes' {
    BeforeAll {
        $file = Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-GuestValidation.ps1'
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($file, [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-VmfMountedVolumeList' }, $true)
        $script:winFn = if ($fn) { $fn.Extent.Text } else { $null }
        $script:winText = Get-VmfCodeOnly -Path $file
    }

    It 'the script reports the list as the check the engine reads' {
        $script:winFn | Should -Not -BeNullOrEmpty
        $script:winText | Should -Match "Add-Check 'mounted volumes' 'INFO'"
        $script:winText | Should -Match 'Get-VmfMountedVolumeList'
    }

    It 'drive letters and folder paths are listed; the temporary disk and the volume GUID paths are not' {
        $list = & {
            . ([scriptblock]::Create($script:winFn))
            function Get-Partition { @(
                [pscustomobject]@{ DiskNumber = 0; AccessPaths = @('C:\', '\\?\Volume{0000-c}\') }
                [pscustomobject]@{ DiskNumber = 0; AccessPaths = @('\\?\Volume{0000-sys}\') }
                [pscustomobject]@{ DiskNumber = 1; AccessPaths = @('D:\', '\\?\Volume{0000-d}\') }
                [pscustomobject]@{ DiskNumber = 2; AccessPaths = @('F:\', 'C:\mount\logs\', '\\?\Volume{0000-f}\') }
                [pscustomobject]@{ DiskNumber = 3; AccessPaths = @('E:\', '\\?\Volume{0000-e}\') }) }
            function Get-Disk { @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Virtual HD' }
                [pscustomobject]@{ Number = 1; FriendlyName = 'Virtual HD' }
                [pscustomobject]@{ Number = 2; FriendlyName = 'Msft Virtual Disk' }
                [pscustomobject]@{ Number = 3; FriendlyName = 'Microsoft NVMe Direct Disk' }) }
            function Get-Volume { @() }
            # D: holds Azure's warning file: it is the SCSI temporary disk.
            function Test-Path { param([string]$LiteralPath) $LiteralPath -eq 'D:\DATALOSS_WARNING_README.txt' }
            Get-VmfMountedVolumeList
        }
        @($list) | Should -Be @('C:\', 'C:\mount\logs\', 'F:\')
    }

    It 'a volume labelled Temporary Storage is left out with its folders, also when the warning file was deleted' {
        $list = & {
            . ([scriptblock]::Create($script:winFn))
            function Get-Partition { @(
                [pscustomobject]@{ DiskNumber = 0; AccessPaths = @('C:\') }
                [pscustomobject]@{ DiskNumber = 1; AccessPaths = @('D:\', 'C:\tempmount\') }
                [pscustomobject]@{ DiskNumber = 2; AccessPaths = @('F:\') }) }
            function Get-Disk { @(
                [pscustomobject]@{ Number = 0; FriendlyName = 'Virtual HD' }
                [pscustomobject]@{ Number = 1; FriendlyName = 'Virtual HD' }
                [pscustomobject]@{ Number = 2; FriendlyName = 'Msft Virtual Disk' }) }
            function Get-Volume { @(
                [pscustomobject]@{ DriveLetter = 'C'; DriveType = 'Fixed'; FileSystemLabel = 'Windows' }
                [pscustomobject]@{ DriveLetter = 'D'; DriveType = 'Fixed'; FileSystemLabel = 'Temporary Storage' }
                [pscustomobject]@{ DriveLetter = 'F'; DriveType = 'Fixed'; FileSystemLabel = 'Data' }) }
            function Test-Path { param([string]$LiteralPath) $false }
            Get-VmfMountedVolumeList
        }
        @($list) | Should -Be @('C:\', 'F:\')
    }

    It 'a drive letter that only Get-Volume shows (a dynamic disk volume) is listed too' {
        $list = & {
            . ([scriptblock]::Create($script:winFn))
            function Get-Partition { @([pscustomobject]@{ DiskNumber = 0; AccessPaths = @('C:\') }) }
            function Get-Disk { @([pscustomobject]@{ Number = 0; FriendlyName = 'Virtual HD' }) }
            function Get-Volume { @([pscustomobject]@{ DriveLetter = 'G'; DriveType = 'Fixed' }, [pscustomobject]@{ DriveLetter = 'C'; DriveType = 'Fixed' }, [pscustomobject]@{ DriveLetter = 'H'; DriveType = 'CD-ROM' }) }
            function Test-Path { param([string]$LiteralPath) $false }
            Get-VmfMountedVolumeList
        }
        @($list) | Should -Be @('C:\', 'G:\')
    }

    It 'stays Windows PowerShell 5.1: no ternary, no null-coalescing, no pwsh-only syntax in the function' {
        $script:winFn | Should -Not -Match '\?\?'
        $script:winFn | Should -Not -Match '\s\?\s.*\s:\s'
    }
}

Describe 'VOLUMES-ONLINE-1: Verifying, a rollback and Restore this machine compare the volumes' {
    BeforeAll {
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'

        function Script:VoPlan {
            param([string]$Os = 'Linux', [string]$Size = 'Standard_D2s_v6', [string]$Controller = 'NVMe')
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
                target = [pscustomobject]@{ size = $Size; diskArch = 'diskless'; controller = $Controller }
                path = 'A'; policy = [pscustomobject]@{}; decisions = @()
            }
        }
        function Script:VoFakeVm {
            param([string]$Os = 'Linux')
            [pscustomobject]@{
                Id = $script:vmId; Name = 'vm-under-test'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = $Os; Name = 'vm-os'; DeleteOption = 'Delete'
                        ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(); ImageReference = $null
                }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true }) }
                Zones = @(); Tags = @{}
                LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        function Global:VoEngineStep { & (Get-Module VmMigrationFactory) { param($rp, $id) [string](Read-VmfStateDoc -RunPath $rp -VmId $id).state } $global:voRunPath $script:vmId }
        function Global:VoPending { & (Get-Module VmMigrationFactory) { param($rp, $id) $d = Read-VmfStateDoc -RunPath $rp -VmId $id; if ($d -and $d.PSObject.Properties['rollbackPending']) { $d.rollbackPending } else { $null } } $global:voRunPath $script:vmId }

        function Script:VoMockAzure {
            param([string]$Found = 'PowerState/running', [string]$Os = 'Linux')
            $global:voPower = $Found
            $global:voOrder = [System.Collections.Generic.List[string]]::new()
            $global:voFail = { param($name) }
            $global:voOs = $Os
            Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
            Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
            Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:voPower }
            Mock -ModuleName VmMigrationFactory Get-AzVM { Script:VoFakeVm -Os $global:voOs }
            Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
            Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
            Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:voFail 'deallocate'; $global:voOrder.Add('deallocate'); $global:voPower = 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:voFail 'powerOff'; $global:voOrder.Add('powerOff'); $global:voPower = 'PowerState/stopped' }
            Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:voFail 'start'; $global:voOrder.Add('start'); $global:voPower = 'PowerState/running' }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { $global:voOrder.Add('agentReady') }
            Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:voOrder.Add("size:$Size") }
            Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm-os'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' } }
            Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
            Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:voOrder.Add('swapOs') }
            Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
            Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
            Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{ fetchedUtc = '2026-11-13T00:00:00Z' } }
            Mock -ModuleName VmMigrationFactory Get-VmfVmIdentityFacts { [pscustomobject]@{ systemAssigned = $false; principalId = $null; userAssigned = @() } }
        }

        function Global:VoOut {
            param([string]$Script, [string]$Result, [object[]]$Checks = @())
            [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
        }
        # The reading of the validation script, by where the engine is: before
        # the move (Preparing), after it (Verifying), and after a rollback.
        # $global:voValidate holds the mounted volumes for each.
        function Script:VoMockGuest {
            param([hashtable]$Validate)
            $global:voValidate = $Validate
            # VOLUMES-ONLINE-WINDOWS-1: the phase in which Set-DataDisksOnline.ps1
            # ran, and the parameters it was given.
            $global:voOnlineIn = $null
            $global:voParams = $null
            Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
                [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                    Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                    Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
                $name = [string]$ScriptString
                $global:voOrder.Add("script:$name")
                $phase = if (Global:VoPending) { 'afterRollback' } elseif ((Global:VoEngineStep) -eq 'VALIDATING') { 'afterMove' } else { 'before' }
                if ($global:voValidate.ContainsKey('restore') -and -not (Global:VoEngineStep)) { $phase = 'restore' }
                if ($global:voValidate.ContainsKey("throw:$name")) { throw $global:voValidate["throw:$name"] }
                $out = switch ($name) {
                    'cluster-node-check.sh' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; warnings = @()
                            checks = @(@{ name = 'lvm devices file'; status = 'INFO'; detail = 'in use (/etc/lvm/devices/system.devices): 1 physical volume(s), every one found' })
                            facts = [ordered]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                    # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                    'sriov-unmanaged-check.sh' { [ordered]@{ schema = 'vmf.guest/7'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                    'Test-ClusterNode.ps1' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                            facts = [ordered]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } } }
                    'mana-check.sh' { Global:VoOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                    'Test-ManaReady.ps1' { Global:VoOut $name 'READY' @(@{ name = 'mana driver'; status = 'PASS'; detail = 'bound' }) }
                    # A MANA driver already in the store: the install changes nothing.
                    'Install-ManaDriver.ps1' { Global:VoOut $name 'NO_CHANGE' @(@{ name = 'mana driver in store'; status = 'PASS'; detail = 'present' }) }
                    { $_ -in @('guest-validate.sh', 'Test-GuestValidation.ps1') } {
                        $bus = if ($name -like '*.sh') { @{ name = 'root device bus'; status = 'INFO'; detail = $(if ($phase -eq 'afterMove' -and -not $global:voValidate.ContainsKey('scsiAfterMove')) { 'nvme (/dev/nvme0n1p1)' } else { 'non-nvme (/dev/sda1)' }) } }
                               else { @{ name = 'boot disk bus'; status = 'INFO'; detail = $(if ($phase -eq 'afterMove' -and -not $global:voValidate.ContainsKey('scsiAfterMove')) { 'NVMe' } else { 'SCSI' }) } }
                        $global:voOrder.Add("phase:$phase")
                        # After Set-DataDisksOnline.ps1 ran in this phase, the reading is "<phase>+online".
                        $at = if ($global:voOnlineIn -eq $phase -and $global:voValidate.ContainsKey("$phase+online")) { "$phase+online" } else { $phase }
                        $checks = @($bus, @{ name = 'mounted volumes'; status = 'INFO'; detail = [string]$global:voValidate[$at] })
                        if ($global:voValidate.ContainsKey("disks:$at")) { $checks += @{ name = 'data disks'; status = 'INFO'; detail = [string]$global:voValidate["disks:$at"] } }
                        Global:VoOut $name 'PASS' $checks
                    }
                    'Set-DataDisksOnline.ps1' {
                        $global:voOnlineIn = $phase
                        $global:voParams = $Parameter
                        Global:VoOut $name 'FIXED' @(@{ name = 'disk online'; status = 'FIXED'; detail = 'disk 2' })
                    }
                    'lvm-devices-task.sh' { Global:VoOut $name 'FIXED' @(@{ name = 'lvm devices file'; status = 'FIXED'; detail = 'The product installed vmf-lvm-devices-refresh.service.' }) }
                    'lvm-devices-refresh.sh' { Global:VoOut $name 'FIXED' @(@{ name = 'lvm devices refresh'; status = 'FIXED'; detail = 'lvmdevices --update --refresh found each physical volume on its new device' }) }
                    default { Global:VoOut $name 'READY' }
                }
                $out | ConvertTo-Json -Depth 8 -Compress
            }
        }
        function Script:VoRunMachine {
            param($Plan)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } { param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'vo-test' }
        }
        function Script:VoDocNow { & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:runPath $script:vmId }
        function Script:VoLines { param([string]$Step) & (Get-Module VmMigrationFactory) { param($rp, $s) @(Read-VmfEvents -RunPath $rp | Where-Object { [string]$_.step -eq $s }) } $script:runPath $Step }
        function Script:VoScriptsAfter([string]$Marker) {
            $all = @($global:voOrder); $at = [array]::LastIndexOf($all, $Marker)
            @($all | Select-Object -Skip ($at + 1))
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:voRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'vo-test' | Out-Null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'every volume back after the move: MIGRATED, and Verifying says it compared the mounted volumes' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot; /var/crash' }
        (Script:VoRunMachine (Script:VoPlan)).state | Should -Be 'MIGRATED'
        @(Script:VoLines 'VALIDATING' | Where-Object { $_.detail -match '^mounted volumes: MATCH' }) | Should -Not -BeNullOrEmpty
    }

    It 'Checking records the devices file fact, and says it' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/'; afterMove = '/' }
        $null = Script:VoRunMachine (Script:VoPlan)
        $doc = Script:VoDocNow
        $doc.captured.lvmDevicesFile.state | Should -Be 'inUse'
        $doc.captured.lvmDevicesFile.detail | Should -Match 'every one found'
        @(Script:VoLines 'PRECHECK' | Where-Object { $_.detail -match 'devices file' }) | Should -Not -BeNullOrEmpty
    }

    It 'a volume missing after the move: Verifying names it, the reason is storageVolumesLost, and the machine rolls back' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot; /var/crash' }
        $final = Script:VoRunMachine (Script:VoPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'storageVolumesLost'
        $stop.machineState | Should -Be 'restored'
        $stop.detail | Should -Match '/var/crash'
    }

    It 'Linux, after the rollback: the refresh runs, then the check, before the machine returns to its power state; all back is a rollback' {
        Script:VoMockAzure -Found 'PowerState/deallocated'
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot; /var/crash' }
        $final = Script:VoRunMachine (Script:VoPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($final.history)[-1].machineState | Should -Be 'restored'
        $after = @(Script:VoScriptsAfter 'swapOs')
        $want = @('start', 'agentReady', 'script:lvm-devices-refresh.sh', 'script:neutral-mark.sh', 'script:guest-validate.sh', 'phase:afterRollback', 'deallocate')
        @($after | Where-Object { $_ -in $want }) | Should -Be $want -Because "order: $($after -join ', ')"
        @(Script:VoLines 'rollback' | Where-Object { $_.detail -match 'Every volume that was mounted before the move is mounted again' -and $_.detail -match '/var/crash' }) | Should -Not -BeNullOrEmpty
        @(Script:VoLines 'rollback' | Where-Object { $_.detail -match 'The machine is back as it was' }) | Should -BeNullOrEmpty -Because 'the rollback line says what was put back, and the check says the rest'
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
    }

    It 'a volume still missing after the rollback: FAILED_NEEDS_ATTENTION, volumesNotBack, changed - never "back as it was" - and the power still goes back' {
        Script:VoMockAzure -Found 'PowerState/deallocated'
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $final = Script:VoRunMachine (Script:VoPlan)
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotBack'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'These volumes were mounted before the move and are not mounted now: /var/crash\.'
        $global:voPower | Should -Be 'PowerState/deallocated'
        # VOLUMES-RETRY-CHECK-1: the retry is allowed, and checks the volumes first (VolumesRetryCheck.Tests.ps1).
        (InModuleScope VmMigrationFactory -Parameters @{ d = $final } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse -Because 'the retry checks the volumes before it takes a new "as it was" copy'
        (InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'volumesNotBack' }).machine | Should -Be 'changed'
    }

    It 'the check cannot run after the rollback: the stop says so plainly and stays a rollback; unknown is not changed' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot' }
        $global:voValidate['throw:lvm-devices-refresh.sh'] = 'RunCommand timed out.'
        $final = Script:VoRunMachine (Script:VoPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = @($final.history)[-1]
        $stop.detail | Should -Match 'The product could not check the volumes inside the machine after the rollback'
        $stop.detail | Should -Match 'RunCommand timed out'
    }

    It 'a volume group short after the rollback, every mount point mounted: still not back' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/; /data'; afterMove = '/'; afterRollback = '/; /data' }
        Mock -ModuleName VmMigrationFactory Test-VmfStorageTopology { if ((Global:VoPending)) { @{ Ok = $false; Verdict = 'MISMATCH'; Detail = 'a volume group or pool is missing one or more of its disks: datavg(1 missing)' } } else { @{ Ok = $true; Verdict = 'MATCH'; Detail = 'x' } } }
        $final = Script:VoRunMachine (Script:VoPlan)
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotBack'
        $stop.detail | Should -Match 'datavg'
    }

    It 'the check asks a machine that does not run nothing, and says it could not check' {
        Script:VoMockAzure -Found 'PowerState/deallocated'
        Script:VoMockGuest @{ restore = '/' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) New-VmfStateDoc -RunPath $rp -RunId 'vo-test' -VmId $id -Wave 'w1' | Out-Null }
        $r = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id)
            Invoke-VmfVolumesCheckAfterPutBack -RunPath $rp -VmId $id -ResourceGroupName 'rg-lab' -VmName 'vm-under-test' -Os 'Linux' -Kind 'restore' }
        $r.verdict | Should -Be 'UNKNOWN'
        $r.words | Should -Match 'The product could not check the volumes inside the machine after the restore'
        $r.words | Should -Match 'Stopped \(deallocated\)|deallocated'
        @($global:voOrder | Where-Object { $_ -like 'script:*' -or $_ -eq 'agentReady' }) | Should -BeNullOrEmpty
    }

    It 'Windows, after the rollback: only the validation script runs - Windows has no devices file' {
        Script:VoMockAzure -Os 'Windows'
        Script:VoMockGuest @{ before = 'C:\; F:\'; afterMove = 'C:\'; afterRollback = 'C:\; F:\' }
        $final = Script:VoRunMachine (Script:VoPlan -Os 'Windows')
        $final.state | Should -Be 'FAILED_ROLLED_BACK' -Because ([string]@($final.history)[-1].detail)
        @($final.history)[-1].reasonCode | Should -Be 'storageVolumesLost' -Because ([string]@($final.history)[-1].detail)
        $after = @(Script:VoScriptsAfter 'swapOs')
        @($after | Where-Object { $_ -like 'script:*' }) | Should -Be @('script:Test-GuestValidation.ps1')
    }

    It 'VOLUMES-ONLINE-V5-1: a Linux move to v5 installs the start task in Preparing, followed by the neutral script, then the machine stops' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot; /var/crash'; scsiAfterMove = $true }
        $final = Script:VoRunMachine (Script:VoPlan -Size 'Standard_D2s_v5' -Controller 'SCSI')
        $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
        $all = @($global:voOrder)
        $at = [array]::IndexOf($all, 'script:lvm-devices-task.sh')
        $at | Should -BeGreaterThan -1 -Because "order: $($all -join ', ')"
        $all[$at + 1] | Should -Be 'script:neutral-mark.sh' -Because 'the task changes the machine (RUNCMD-REPLAY-1)'
        @($all | Select-Object -Skip ($at + 2) | Where-Object { $_ -notlike 'phase:*' }) | Select-Object -First 1 | Should -Be 'deallocate' -Because 'the preparation is followed at once by the stop'
        @($all | Where-Object { $_ -eq 'script:nvme-fix.sh' }) | Should -BeNullOrEmpty -Because 'a v5 move needs no NVMe preparation'
        (Script:VoDocNow).guestExecutions | Where-Object { $_.script -eq 'lvm-devices-task.sh' } | Should -Not -BeNullOrEmpty
    }

    It 'VOLUMES-ONLINE-V5-1: a v5 move whose start task cannot be enabled stops in Preparing and says why' {
        Script:VoMockAzure
        Script:VoMockGuest @{ before = '/'; afterMove = '/'; afterRollback = '/' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand -ParameterFilter { [string]$ScriptString -eq 'lvm-devices-task.sh' } {
            $global:voOrder.Add('script:lvm-devices-task.sh')
            [ordered]@{ schema = 'vmf.guest/2'; script = 'lvm-devices-task.sh'; version = '1.0.0'; result = 'BLOCKED'; warnings = @(); error = 'lvm devices file: The product could not enable vmf-lvm-devices-refresh.service. in use (/etc/lvm/devices/system.devices): 1 physical volume(s), every one found.'
                checks = @(@{ name = 'lvm devices file'; status = 'FAIL'; detail = 'The product could not enable vmf-lvm-devices-refresh.service. in use (/etc/lvm/devices/system.devices): 1 physical volume(s), every one found.' }) } | ConvertTo-Json -Depth 6 -Compress
        }
        $final = Script:VoRunMachine (Script:VoPlan -Size 'Standard_D2s_v5' -Controller 'SCSI')
        $stop = @($final.history | Where-Object { $_.reasonCode -eq 'guestPrepBlocked' })
        $stop | Should -Not -BeNullOrEmpty -Because ([string]@($final.history)[-1].detail)
        @($stop)[0].detail | Should -Match 'The product did not complete the Linux preparation for the move\. The product could not enable vmf-lvm-devices-refresh\.service\.'
    }

    It 'VOLUMES-ONLINE-V5-1: a Windows move to v5 runs no LVM task' {
        Script:VoMockAzure -Os 'Windows'
        Script:VoMockGuest @{ before = 'C:\'; afterMove = 'C:\' }
        $null = Script:VoRunMachine (Script:VoPlan -Os 'Windows' -Size 'Standard_D2s_v5' -Controller 'SCSI')
        @($global:voOrder | Where-Object { $_ -eq 'script:lvm-devices-task.sh' }) | Should -BeNullOrEmpty
    }

    It 'VOLUMES-ONLINE-WINDOWS-1: Verifying brings online a data disk that was online before the move, reads again, and the mounted volumes compare MATCH' {
        Script:VoMockAzure -Os 'Windows'
        Script:VoMockGuest @{ before = 'C:\; F:\'; 'disks:before' = 'mbr:0000000f=2:online:writable'
            afterMove = 'C:\'; 'disks:afterMove' = 'mbr:0000000f=2:offline:writable'
            'afterMove+online' = 'C:\; F:\'; 'disks:afterMove+online' = 'mbr:0000000f=2:online:writable' }
        $null = Script:VoRunMachine (Script:VoPlan -Os 'Windows')
        # The harness has no accelerated networking adapter on Windows, so the move stops later in Verifying; the volumes passed first.
        @(Script:VoLines 'VALIDATING' | Where-Object { $_.detail -match '^mounted volumes: MATCH' }) | Should -Not -BeNullOrEmpty
        @(Script:VoLines 'VALIDATING' | Where-Object { $_.detail -match '^mounted volumes: MISSING' }) | Should -BeNullOrEmpty -Because 'the machine is read again after the disk is online, before the comparison'
        $global:voParams.OnlineKeys | Should -Be 'mbr:0000000f'
        $global:voParams.ContainsKey('WritableKeys') | Should -BeFalse -Because 'an empty list is never sent: how Run Command renders an empty parameter is not measured'
        $all = @($global:voOrder)
        $at = [array]::IndexOf($all, 'script:Set-DataDisksOnline.ps1')
        $at | Should -BeGreaterThan -1 -Because "order: $($all -join ', ')"
        @($all | Select-Object -Skip ($at + 1) | Where-Object { $_ -like 'script:*' } | Select-Object -First 2) | Should -Be @('script:Get-NeutralMark.ps1', 'script:Test-GuestValidation.ps1')
        @(Script:VoLines 'VALIDATING' | Where-Object { $_.detail -eq 'The product changed the status of these data disks to Online: disk 2.' }) | Should -Not -BeNullOrEmpty
    }

    It 'VOLUMES-ONLINE-WINDOWS-1: a data disk the customer kept offline before the move is left offline' {
        Script:VoMockAzure -Os 'Windows'
        Script:VoMockGuest @{ before = 'C:\'; 'disks:before' = 'mbr:0000000a=3:offline:writable'
            afterMove = 'C:\'; 'disks:afterMove' = 'mbr:0000000a=3:offline:writable' }
        $null = Script:VoRunMachine (Script:VoPlan -Os 'Windows')
        @(Script:VoLines 'VALIDATING' | Where-Object { $_.detail -match '^mounted volumes: MATCH' }) | Should -Not -BeNullOrEmpty
        @($global:voOrder | Where-Object { $_ -eq 'script:Set-DataDisksOnline.ps1' }) | Should -BeNullOrEmpty
    }

    It 'VOLUMES-ONLINE-WINDOWS-1: after a rollback a data disk offline is brought online before the comparison, and the rollback says so' {
        Script:VoMockAzure -Os 'Windows'
        Script:VoMockGuest @{ before = 'C:\; F:\'; 'disks:before' = 'mbr:0000000f=2:online:writable'
            afterMove = 'C:\'; 'disks:afterMove' = 'mbr:0000000f=2:online:writable'
            afterRollback = 'C:\'; 'disks:afterRollback' = 'mbr:0000000f=2:offline:readonly'
            'afterRollback+online' = 'C:\; F:\'; 'disks:afterRollback+online' = 'mbr:0000000f=2:online:writable' }
        $final = Script:VoRunMachine (Script:VoPlan -Os 'Windows')
        $final.state | Should -Be 'FAILED_ROLLED_BACK' -Because ([string]@($final.history)[-1].detail)
        @($final.history)[-1].machineState | Should -Be 'restored'
        $global:voParams.OnlineKeys | Should -Be 'mbr:0000000f'
        $global:voParams.WritableKeys | Should -Be 'mbr:0000000f'
        @(Script:VoLines 'rollback' | Where-Object { $_.detail -eq 'The product changed the status of these data disks to Online: disk 2.' }) | Should -Not -BeNullOrEmpty
        @(Script:VoLines 'rollback' | Where-Object { $_.detail -match 'Every volume that was mounted before the move is mounted again: C:\\, F:\\' }) | Should -Not -BeNullOrEmpty
    }

    It 'kill and resume (rule 4): a worker killed at the power return after the check finds the check on record and never runs it again' {
        Script:VoMockAzure -Found 'PowerState/deallocated'
        Script:VoMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $global:voKill = $false
        $global:voFail = { param($name)
            $p = Global:VoPending
            if ($name -eq 'deallocate' -and $p -and $p.PSObject.Properties['volumes'] -and -not $global:voKill) {
                $global:voKill = $true
                $global:voPower = 'PowerState/deallocated'
                throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
            } }
        { Script:VoRunMachine (Script:VoPlan) } | Should -Throw '*abandon this VM*'
        $pending = Global:VoPending
        $pending | Should -Not -BeNullOrEmpty
        $pending.volumes.verdict | Should -Be 'MISSING' -Because 'the check is on the checkpoint before the return'
        $global:voOrder.Clear()
        $final = Script:VoRunMachine (Script:VoPlan)
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($final.history)[-1].reasonCode | Should -Be 'volumesNotBack'
        @($global:voOrder | Where-Object { $_ -like 'script:*' }) | Should -BeNullOrEmpty -Because 'a machine returned to Stopped (deallocated) is not checked again'
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
    }

    Context 'Restore this machine' {
        BeforeAll {
            $script:rsSub = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute'
            $script:rsVm = "$($script:rsSub)/virtualMachines/app01"
            function Script:VoRestoreRun {
                param([string]$Before, [string]$Script = 'guest-validate.sh')
                $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vo-rst-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $script:rsVm; sub = $script:rsSub; before = $Before; scr = $Script } {
                    param($rp, $vmId, $sub, $before, $scr)
                    Initialize-VmfRun -RunPath $rp -RunId 'vo-rst' | Out-Null
                    New-VmfStateDoc -RunPath $rp -RunId 'vo-rst' -VmId $vmId -Wave 'lab-1' | Out-Null
                    $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
                    $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = "$sub/snapshots/app01-snap"; cloneVmId = $null }) -Force
                    $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                            guestBefore = [pscustomobject]@{ schema = 'vmf.guest/2'; script = $scr; version = '1.0.0'; result = 'PASS'; warnings = @()
                                checks = @([pscustomobject]@{ name = 'mounted volumes'; status = 'INFO'; detail = $before }) } }) -Force
                    $doc | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @([pscustomobject]@{ script = $scr; version = '1.0.0'; sha256 = ('a' * 64); tsUtc = '2026-11-13T00:00:00Z'; result = 'READING'; evidenceRef = 'evidence/x.txt' }) -Force
                    $doc.state = 'MIGRATED'
                    $null = Add-VmfTestMachineCapture $doc 'app01' "$sub/disks/app01-osdisk"
                    $null = Complete-VmfTestCapture $doc
                    Write-VmfStateDoc -RunPath $rp -Document $doc
                    $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                        schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'lab-1'; ring = 'lab'
                        assessment = [ordered]@{ iacManaged = $false; location = 'centralus' }
                        target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
                    Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
                }
                $rp
            }
            function Script:VoRestoreAzure {
                param([string]$Now = 'PowerState/running')
                $global:voPower = $Now
                $global:voOrder = [System.Collections.Generic.List[string]]::new()
                $global:voFail = { param($name) }
                Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 } }
                Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
                Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
                Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:voOrder.Add('swapOs') }
                Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
                Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
                Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
                Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
                Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
                Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:voPower }
                Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:voFail 'deallocate'; $global:voOrder.Add('deallocate'); $global:voPower = 'PowerState/deallocated' }
                Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:voFail 'powerOff'; $global:voOrder.Add('powerOff'); $global:voPower = 'PowerState/stopped' }
                Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:voFail 'start'; $global:voOrder.Add('start'); $global:voPower = 'PowerState/running' }
                Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { $global:voOrder.Add('agentReady') }
            }
            function Script:VoRestoreDoc { param($rp) & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $rp $script:rsVm }
        }
        AfterEach {
            if ($script:rsRun -and (Test-Path $script:rsRun)) { Remove-Item $script:rsRun -Recurse -Force }
            if ($script:rsSnap -and (Test-Path $script:rsSnap)) { Remove-Item $script:rsSnap -Recurse -Force }
        }

        It 'Linux: after the agent answers, the refresh and the check run before the machine returns to its power state; all back says so' {
            $script:rsRun = Script:VoRestoreRun -Before '/; /boot; /var/crash'
            Script:VoRestoreAzure -Now 'PowerState/deallocated'
            Script:VoMockGuest @{ restore = '/; /boot; /var/crash' }
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
            $after = @(Script:VoScriptsAfter 'swapOs')
            $want = @('start', 'agentReady', 'script:lvm-devices-refresh.sh', 'script:neutral-mark.sh', 'script:guest-validate.sh', 'deallocate')
            # The restore waits for the agent, and so does the check: once or twice is the same.
            @($after | Where-Object { $_ -in $want } | Select-Object -Unique) | Should -Be $want -Because "order: $($after -join ', ')"
            $doc = Script:VoRestoreDoc $script:rsRun
            $doc.restore | Should -Not -BeNullOrEmpty
            @($doc.history | Where-Object { $_.reasonCode -eq 'volumesNotBack' }) | Should -BeNullOrEmpty
            @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp } $script:rsRun | Where-Object { $_.step -eq 'restore' -and $_.detail -match 'Every volume that was mounted before the move is mounted again' }) | Should -Not -BeNullOrEmpty
        }

        It 'a volume missing after the restore: the restore is recorded, the stop says it, and the machine is changed' {
            $script:rsRun = Script:VoRestoreRun -Before '/; /boot; /var/crash'
            Script:VoRestoreAzure
            Script:VoMockGuest @{ restore = '/; /boot' }
            { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false } | Should -Throw -ExpectedMessage '*These volumes were mounted before the move and are not mounted now: /var/crash.*'
            $doc = Script:VoRestoreDoc $script:rsRun
            $doc.restore | Should -Not -BeNullOrEmpty -Because 'the disks are back; the record says so'
            $last = @($doc.history)[-1]
            $last.reasonCode | Should -Be 'volumesNotBack'
            $last.machineState | Should -Be 'changed'
            $last.state | Should -Be 'MIGRATED'
        }

        It 'Windows: no refresh, only the validation script' {
            $script:rsRun = Script:VoRestoreRun -Before 'C:\; F:\' -Script 'Test-GuestValidation.ps1'
            Script:VoRestoreAzure
            Script:VoMockGuest @{ restore = 'C:\; F:\' }
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
            @($global:voOrder | Where-Object { $_ -like 'script:*' }) | Should -Be @('script:Test-GuestValidation.ps1')
        }

        It 'kill and resume (rule 4): the check is in the checkpoint, and a resume after the return never runs it again' {
            $script:rsRun = Script:VoRestoreRun -Before '/; /boot; /var/crash'
            $script:rsSnap = "$($script:rsRun)-snap"
            Script:VoRestoreAzure -Now 'PowerState/deallocated'
            Script:VoMockGuest @{ restore = '/; /boot' }
            $global:voKill = @{ run = $script:rsRun; snap = $script:rsSnap; done = $false }
            $global:voFail = { param($name)
                if ($name -eq 'deallocate' -and @($global:voOrder) -contains 'agentReady' -and -not $global:voKill.done) {
                    $global:voKill.done = $true
                    $global:voPower = 'PowerState/deallocated'
                    Copy-Item -Path $global:voKill.run -Destination $global:voKill.snap -Recurse
                    throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
                } }
            { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -CorrelationId 'op-vo' -Confirm:$false } | Should -Throw
            Remove-Item $script:rsRun -Recurse -Force
            Copy-Item -Path $script:rsSnap -Destination $script:rsRun -Recurse
            (Script:VoRestoreDoc $script:rsRun).putBackJob.volumes.verdict | Should -Be 'MISSING'
            $global:voOrder.Clear()
            { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Resume -CorrelationId 'op-vo' -Confirm:$false } | Should -Throw -ExpectedMessage '*/var/crash*'
            @($global:voOrder | Where-Object { $_ -like 'script:*' }) | Should -BeNullOrEmpty -Because 'the resume uses the check on the checkpoint'
            @((Script:VoRestoreDoc $script:rsRun).history)[-1].reasonCode | Should -Be 'volumesNotBack'
        }
    }
}

Describe 'VOLUMES-ONLINE-1: the contract and the words' {
    It 'vm-state declares the check on the rollback checkpoint and on the restore checkpoint (v49, and v50 since VOLUMES-RETRY-CHECK-1)' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $s.properties.schemaVersion.const | Should -Be 51
        $s.properties.rollbackPending.properties.volumes | Should -Not -BeNullOrEmpty
        $s.properties.putBackJob.properties.volumes | Should -Not -BeNullOrEmpty
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'vm-state v48 -> v49'
    }

    It 'the stop reason has its words, and sends the person to mount the volume and try again (VOLUMES-RETRY-CHECK-1)' {
        $g = InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'volumesNotBack' }
        $g | Should -Not -BeNullOrEmpty
        $g.machine | Should -Be 'changed'
        $g.retry | Should -Be 'unlikely'
    }

    It 'lvm-devices-refresh.sh is in the manifest and is followed by the neutral script, and is not a preparation script' {
        InModuleScope VmMigrationFactory {
            (Get-VmfGuestScript -Name 'lvm-devices-refresh.sh').Os | Should -Be 'linux'
            $script:VmfGuestFollowUpScripts | Should -Contain 'lvm-devices-refresh.sh'
            $script:VmfGuestChangerScripts | Should -Not -Contain 'lvm-devices-refresh.sh'
        }
    }
}
