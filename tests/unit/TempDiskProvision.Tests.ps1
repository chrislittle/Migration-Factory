#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LINUX-TEMP-1 part 2: the Linux twin of Install-TempDiskInit.ps1.
#
# MEASURED on real machines 2026-08-28, which is what settled the design:
#   * a MIGRATED machine (born v4) carries a dangling fstab line pointing at
#     /dev/disk/cloud/azure_resource-part1, written by cloud-init on its first
#     boot while it was still on SCSI hardware;
#   * a machine BORN on v6 has NO such line at all, and also does not mount
#     /mnt. So "no temporary disk on v6" is Azure's normal behaviour, not
#     something this tool broke - and the dangling line IS a migration
#     artifact;
#   * both report the local disk as model "Microsoft NVMe Direct Disk v2",
#     with azure-vm-utils exposing /dev/disk/azure/local/by-index/1 - index 1,
#     NOT the 0 in Microsoft's example, which is why nothing may assume an
#     index or a device order;
#   * the OS disk answers "MSFT NVMe Accelerator", so the two are separable by
#     the answer the device itself gives.
#
# Microsoft's own position (enable-nvme-temp-faqs, retrieved 2026-08-28):
# v6 VMs "come with raw, unformatted NVMe disks", nothing is visible "until
# after they're initialized and formatted", and "it's a best practice to run
# the mounting script automatically every time the VM starts". There is no
# agent version that does it for you - so a boot task is the answer, exactly
# as on Windows.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:setup = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'temp-disk-setup.sh') -Raw
    $script:engine = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
}

Describe 'LINUX-TEMP-1 part 2: identifying the temp disk without ever guessing' {
    It 'identifies by what the DEVICE says, not by device order' {
        # nvme1n1 today, nvme3n1 on a bigger size, and Microsoft'\''s own example
        # used by-index/0 where our machines report by-index/1.
        $script:setup | Should -Match 'by-index'
        $script:setup | Should -Match 'NVMe Direct Disk' -Because 'the documented model string is the fallback identification'
        $script:setup | Should -Not -Match '/dev/nvme1n1[^*]' -Because 'no device may be hard-coded'
    }

    It 'LINUX-TEMP-3: reads the model from /sys, and depends on no package to find the disk' {
        # Gen1 drill, 2026-09-25: on Ubuntu 18.04 the temporary disk stayed raw
        # after the move. The fallback asked the `nvme` command (nvme-cli), and
        # the likely cause is an image without it. /sys needs nothing.
        $code = Get-VmfCodeOnly -Text $script:setup -Language Shell
        $code | Should -Match '/sys/block/.*device/model'
        $code | Should -Not -Match 'nvme id-ctrl' -Because 'nvme-cli is not on every image'
        $code | Should -Not -Match 'command -v nvme'
    }

    # PUBLIC-SYNC-1: this repository's workflows do not ship to the public one.
    It 'LINUX-TEMP-3: CI RUNS the boot task against fake disks, not only reads it' -Skip:(-not (Test-Path (Join-Path $PSScriptRoot '..' '..' '.github' 'workflows' 'ci.yml'))) {
        $ci = Get-Content (Join-Path $script:repoRoot '.github' 'workflows' 'ci.yml') -Raw
        $ci | Should -Match 'tests/linux/\*\.test\.sh'
        Test-Path (Join-Path $script:repoRoot 'tests' 'linux' 'temp-disk-init.test.sh') | Should -BeTrue
    }

    It 'refuses anything that is not a local temp disk' {
        # The OS disk is NVMe too, and it answers "NVMe Accelerator". Formatting
        # it would destroy the machine.
        $script:setup | Should -Match '(?s)Accelerator|os-part|SKIP'
        $script:setup | Should -Match 'mountpoint|MOUNTPOINT|findmnt' -Because 'a disk carrying a mounted filesystem is never touched'
    }

    It 'runs on EVERY boot, because the disk is raw again every time' {
        $script:setup | Should -Match 'systemd|\.service'
        $script:setup | Should -Match 'multi-user\.target'
        $script:setup | Should -Match 'systemctl enable'
    }

    It 'writes the fstab entry the way Microsoft and our own validation expect' {
        $script:setup | Should -Match 'nofail' -Because 'the mount is optional by design - part 1 stopped failing on exactly this'
    }

    It 'removes the stale cloud-image entry, with a backup' {
        # Measured: a born-v6 machine has no such line. Leaving it behind means
        # the machine never matches a native one.
        $script:setup | Should -Match 'azure_resource'
        $script:setup | Should -Match '(?i)\.vmf-bak|backup'
    }

    It 'emits exactly one JSON object on the guest contract' {
        $script:setup | Should -Match '"schema":"vmf\.guest/2"'
        $script:setup | Should -Match 'BLOCKED'
    }

    It 'is listed in the manifest with a correct hash' {
        $manifest = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        $entry = @($manifest.scripts) | Where-Object { $_.name -eq 'temp-disk-setup.sh' }
        $entry | Should -Not -BeNullOrEmpty
        $entry.os | Should -Be 'linux'
        $actual = (Get-FileHash (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'temp-disk-setup.sh') -Algorithm SHA256).Hash.ToLower()
        $entry.sha256 | Should -Be $actual
    }
}

Describe 'LINUX-TEMP-1 part 2: when the engine installs it' {
    It 'installs it during guest prep, like the Windows twin - so it fires on the first boot of the new size' {
        $branch = [regex]::Match($script:engine, '(?s)nvme-fix\.sh.*?
    \}').Value
        $branch | Should -Match 'temp-disk-setup\.sh'
    }

    It 'installs it ONLY for a machine that actually had a temporary disk' {
        # A machine that never had one must not be given one - that is a change
        # nobody asked for, and a born-v6 machine has no /mnt either.
        $branch = [regex]::Match($script:engine, '(?s)nvme-fix\.sh.*?
    \}').Value
        $branch | Should -Match 'tempDiskMounted'
    }

    It 'a failure to set up scratch space never fails a good migration' {
        # The machine is migrated and healthy; the temporary disk is scratch.
        $branch = [regex]::Match($script:engine, '(?s)nvme-fix\.sh.*?
    \}').Value
        $branch | Should -Match "Outcome 'warn'|Outcome warn"
        $branch | Should -Not -Match "tempDiskSetup[^\r\n]*FAILED_NEEDS_ATTENTION"
    }
}
