#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LVM-1 / STORAGE-SPACES-1 - did the customer's volumes come back?
#
# The reason it needs a comparison of its own: a volume group
# or storage pool on DATA disks is not boot-critical. After a Path B recreate
# the machine comes up, the agent reports Ready, the boot disk is on NVMe, the
# drivers are bound, and every other check in VALIDATING passes - while the
# filesystem holding the application's data is absent, because the recreate
# detached and reattached the data disks and the group came back a member short.
#
# Nothing else in the engine can see it. The ARM-level capture sees DISKS;
# volume groups and storage pools live inside the guest.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Script:Guest([hashtable[]]$Checks) {
        [pscustomobject]@{ checks = @($Checks | ForEach-Object { [pscustomobject]$_ }) }
    }
    # A Linux machine with two groups and three volumes, all whole.
    function Script:LinuxHealthy {
        Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'LVM volumes present, root is not on one (/dev/sda1)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '2 volume group(s), 3 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' })
    }
    # LVM-ROOT-1: a machine whose ROOT is on LVM, which every test above this
    # line lacked - all of them said 'root is not on one (/dev/sda1)'.
    #
    # It is the case the volume drill deliberately scoped OUT, because Ubuntu's
    # marketplace root is not on LVM and RHEL's is. It is also the case where a
    # volume group IS boot-critical: the group must assemble in the initramfs
    # before the root filesystem can mount at all. When it does not, the machine
    # does not come up, the guest cannot answer, and the ONLY correct verdict is
    # UNKNOWN - never a pass.
    function Script:LinuxRootOnLvm {
        Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'root is on LVM (/dev/mapper/rootvg-rootlv)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '1 volume group(s), 2 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' })
    }
    function Script:WindowsHealthy {
        Script:Guest @(
            @{ name = 'storage pools'; status = 'INFO'; detail = 'datapool[health=Healthy;disks=4]' }
            @{ name = 'storage volumes'; status = 'INFO'; detail = 'datavol[health=Healthy;state=OK]' }
            @{ name = 'storage pool disks missing'; status = 'INFO'; detail = 'every pooled disk is present' })
    }
    function Script:Verdict($Before, $After) {
        InModuleScope VmMigrationFactory -Parameters @{ b = $Before; a = $After } {
            Test-VmfStorageTopology -Before $b -After $a }
    }
}

Describe 'LVM-1: a Linux volume group that came back short FAILS' {
    It 'a machine whose groups are all whole passes' {
        (Script:Verdict (Script:LinuxHealthy) (Script:LinuxHealthy)).Verdict | Should -Be 'MATCH'
    }

    It 'a group missing a disk is a MISMATCH, and names the group' {
        # The exact shape a Path B recreate produces: the disks came back, one
        # short, and LVM will not activate an incomplete group.
        $after = Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'LVM volumes present, root is not on one (/dev/sda1)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '2 volume group(s), 3 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'INCOMPLETE: datavg(1 missing)' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' })
        $r = Script:Verdict (Script:LinuxHealthy) $after
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Ok | Should -BeFalse
        $r.Detail | Should -Match 'datavg'
        $r.Detail | Should -Match 'missing one or more of its disks'
    }

    It 'a volume the machine expects but has not mounted is a MISMATCH' {
        # This is the case `nofail` hides from the ordinary fstab check, and
        # nofail is what Microsoft recommends for Azure data disks.
        $after = Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'LVM volumes present, root is not on one (/dev/sda1)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '2 volume group(s), 3 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'
               detail = 'NOT MOUNTED: /data(/dev/mapper/datavg-datalv) - the volume group did not assemble' })
        $r = Script:Verdict (Script:LinuxHealthy) $after
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match '/data'
    }

    It 'losing a whole volume group is a MISMATCH' {
        $after = Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'LVM volumes present, root is not on one (/dev/sda1)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '1 volume group(s), 1 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' })
        $r = Script:Verdict (Script:LinuxHealthy) $after
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match '2 volume group\(s\) or storage pool\(s\) before'
    }

    It 'a machine with no LVM at all matches, and says so plainly' {
        $none = Script:Guest @(@{ name = 'lvm root'; status = 'INFO'; detail = 'no LVM in use' })
        $r = Script:Verdict $none $none
        $r.Verdict | Should -Be 'MATCH'
        $r.Detail | Should -Match 'uses no volume groups'
    }

    It 'MORE volumes than before is not a failure' {
        # Somebody adding storage during a maintenance window is not this
        # check's business. Only losing something is.
        $after = Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'LVM volumes present, root is not on one (/dev/sda1)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '3 volume group(s), 5 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' })
        (Script:Verdict (Script:LinuxHealthy) $after).Verdict | Should -Be 'MATCH'
    }
}

Describe 'LVM-ROOT-1: a root on LVM is judged like any other group, and proven so' {
    # The engine treats a root VG as a volume group, which is right - but no
    # test said so, and "it should work the same" is the assumption that this
    # project keeps finding to be false. These are cheap; the drill is not.

    It 'a root on LVM that came back whole passes' {
        (Script:Verdict (Script:LinuxRootOnLvm) (Script:LinuxRootOnLvm)).Verdict | Should -Be 'MATCH'
    }

    It 'and the root volume group is COUNTED, not skipped for being the root' {
        # If a root VG were ignored, a machine whose only group is the root
        # would look like a machine with no LVM - and losing it would pass.
        $facts = InModuleScope VmMigrationFactory -Parameters @{ g = (Script:LinuxRootOnLvm) } {
            Get-VmfStorageFacts -Guest $g
        }
        $facts.Groups | Should -Be 1
        $facts.Volumes | Should -Be 2
        $facts.Reported | Should -BeTrue
    }

    It 'losing the root volume group is a MISMATCH, not a pass' {
        # The boot-critical case. A machine whose ONLY group is the root and
        # which comes back reporting none has not "simplified" - it has failed
        # to assemble the group its root filesystem lives on.
        $after = Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'no LVM in use' })
        (Script:Verdict (Script:LinuxRootOnLvm) $after).Verdict | Should -Be 'MISMATCH'
    }

    It 'a root group that came back a disk short is a MISMATCH, and names it' {
        $after = Script:Guest @(
            @{ name = 'lvm root'; status = 'INFO'; detail = 'root is on LVM (/dev/mapper/rootvg-rootlv)' }
            @{ name = 'lvm topology'; status = 'INFO'; detail = '1 volume group(s), 2 logical volume(s)' }
            @{ name = 'lvm volume groups complete'; status = 'INFO';
               detail = 'INCOMPLETE: rootvg is missing 1 of 2 disks' }
            @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' })
        $v = Script:Verdict (Script:LinuxRootOnLvm) $after
        $v.Verdict | Should -Be 'MISMATCH'
        $v.Detail | Should -Match 'rootvg'
    }

    It 'a machine that did not come back at all is UNKNOWN, never a pass' {
        # THE ONE THAT MATTERS MOST on an LVM root. If the group does not
        # assemble, the machine does not boot, and nothing answers. A verdict
        # of MATCH here would report a dead machine as migrated.
        $silent = Script:Guest @()
        (Script:Verdict (Script:LinuxRootOnLvm) $silent).Verdict | Should -Be 'UNKNOWN'
    }
}

Describe 'STORAGE-SPACES-1: the same comparison works on Windows' {
    It 'a healthy pool matches' {
        (Script:Verdict (Script:WindowsHealthy) (Script:WindowsHealthy)).Verdict | Should -Be 'MATCH'
    }

    It 'a pool that lost a disk is a MISMATCH' {
        $after = Script:Guest @(
            @{ name = 'storage pools'; status = 'INFO'; detail = 'datapool[health=Degraded;disks=3]' }
            @{ name = 'storage volumes'; status = 'INFO'; detail = 'datavol[health=Unhealthy;state=Detached]' }
            @{ name = 'storage pool disks missing'; status = 'INFO'; detail = 'MISSING: PhysicalDisk3=Lost' })
        $r = Script:Verdict (Script:WindowsHealthy) $after
        $r.Verdict | Should -Be 'MISMATCH'
        $r.Detail | Should -Match 'PhysicalDisk3'
    }

    It 'a pool that vanished entirely is a MISMATCH' {
        $after = Script:Guest @(@{ name = 'storage pools'; status = 'INFO'; detail = 'none' })
        (Script:Verdict (Script:WindowsHealthy) $after).Verdict | Should -Be 'MISMATCH'
    }

    It 'a machine with no pools matches' {
        $none = Script:Guest @(@{ name = 'storage pools'; status = 'INFO'; detail = 'none' })
        (Script:Verdict $none $none).Verdict | Should -Be 'MATCH'
    }
}

Describe 'LVM-1 / STORAGE-SPACES-1: unknown is neither a pass nor a fail' {
    It 'an older guest script that reported nothing gives UNKNOWN' {
        # Failing here would roll back healthy machines because a script is out
        # of date; passing would be the silent loss this exists to prevent.
        $silent = Script:Guest @(@{ name = 'nvme driver'; status = 'INFO'; detail = 'active' })
        $r = Script:Verdict $silent $silent
        $r.Verdict | Should -Be 'UNKNOWN'
        $r.Ok | Should -BeTrue -Because 'not knowing must not roll a machine back'
        $r.Detail | Should -Match 'cannot say whether they are complete'
    }

    It 'an image whose tooling could not be asked gives UNKNOWN, never "none"' {
        $cannot = Script:Guest @(@{ name = 'storage pools'; status = 'INFO'
            detail = 'could not be inspected on this image: the term Get-StoragePool is not recognized' })
        (Script:Verdict $cannot $cannot).Verdict | Should -Be 'UNKNOWN'
    }

    It 'and a machine asked BEFORE but not after is UNKNOWN, not a pass' {
        $silent = Script:Guest @(@{ name = 'nvme driver'; status = 'INFO'; detail = 'active' })
        (Script:Verdict (Script:LinuxHealthy) $silent).Verdict | Should -Be 'UNKNOWN'
    }
}

Describe 'LVM-1 / STORAGE-SPACES-1: the engine captures before and judges after' {
    BeforeAll { $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw }

    It 'GUEST_PREP records the topology on BOTH platforms' {
        # Without a before there is nothing to compare, and the check would be
        # permanently UNKNOWN - which is worse than not having it, because it
        # looks like coverage.
        @([regex]::Matches($script:sm, 'storageBefore = \$(check|lxCheck)')).Count | Should -Be 2
    }

    It 'VALIDATING compares them' {
        $script:sm | Should -Match 'Test-VmfStorageTopology -Before \$storageBefore -After \$result'
    }

    It 'and it THROWS on a mismatch, so the machine is actually put back' {
        # Returning a terminal state here would record a machine as "put back"
        # WITHOUT putting it back - rollback is driven by the exception path.
        # Caught in review before it shipped.
        $script:sm | Should -Match 'throw "Storage volumes are missing after the move'
        $script:sm | Should -Not -Match "Next = 'FAILED_ROLLED_BACK'; Reason = 'storageVolumesLost'"
    }

    It 'the failure has its own reason code and guidance' {
        InModuleScope VmMigrationFactory {
            (Get-VmfErrorStopReason -Message 'Storage volumes are missing after the move: a pool is missing a disk') |
                Should -Be 'storageVolumesLost'
            $g = Get-VmfStopGuidance -Code 'storageVolumesLost'
            $g | Should -Not -BeNullOrEmpty
            $g.machine | Should -Be 'restored'
            # VOLUMES-ONLINE-1: the reason also covers a plain volume that was
            # mounted before the move (Test-VmfVolumesBack in Verifying), not
            # only a volume group or a pool, so the words name both.
            $g.meaning | Should -Match '(?i)only that volume is missing'
            $g.meaning | Should -Match 'mounted before the move'
        }
    }
}
