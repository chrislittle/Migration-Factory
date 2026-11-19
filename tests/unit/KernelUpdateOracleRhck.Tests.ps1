#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# KERNEL-UPDATE-OL-RHCK-1 (final lab, 2026-11-16): Oracle Linux 9.7 (image
# ol97-lvm-gen2 9.7.3) set to start the Red Hat Compatible Kernel
# 5.14.0-570.51.1.0.1.el9_6 with grubby, with the image's UEK R8 kernel
# 6.12.0-202.76.4.2.el9uek still installed. Update the kernel chose the package
# `kernel` - right - but took the newest kernel in /boot of EITHER family as
# "the kernel installed": the UEK kernel, which sorts above every 5.14 kernel.
# It answered FIXED, set no default boot kernel (grubby ran on UEK only), the
# machine restarted on its old RHCK kernel, and the engine rolled it back with
# "not on the installed kernel 6.12.0-202.76.4.2.el9uek".
#
# The rule now: on Red Hat, its rebuilds and Oracle Linux, the update stays in
# the family the machine runs (RHCK `kernel`, UEK `kernel-uek`); the newest
# kernel of THAT family is made the default boot kernel with grubby, read back;
# and the engine compares the kernel the machine starts on with that default.
BeforeDiscovery {
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    $script:testBash = Get-VmfTestBash
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_TestBash.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:rhckOld = '5.14.0-570.51.1.0.1.el9_6.x86_64'
    $script:rhckNew = '5.14.0-570.52.1.0.1.el9_6.x86_64'
    $script:uekR8 = '6.12.0-202.76.4.2.el9uek.x86_64'
    $script:uekR7 = '5.15.0-326.224.5.1.el9uek.x86_64'

    # Runs kernel-update.sh on a fake machine: its os-release, its kernels in
    # /boot, and stand-ins for uname, rpm, dnf and grubby on PATH. dnf adds
    # vmlinuz-<New> when New is given; grubby keeps the default boot kernel
    # in a file, so a set is read back. -GrubbyKeeps: grubby says it set the
    # default, and the default does not change.
    function script:Invoke-KernelUpdateFake {
        param(
            [string]$Id = 'ol', [string]$Version = '9.7',
            [string]$Running, [string[]]$Boot = @(), [string]$New = '',
            [string]$Default = '', [switch]$GrubbyKeeps
        )
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-olr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $bin = Join-Path $work 'bin'
        $root = Join-Path $work 'root'
        foreach ($d in $bin, (Join-Path $root 'etc'), (Join-Path $root 'boot')) { $null = New-Item -ItemType Directory -Path $d -Force }
        try {
            $lf = "`n"
            [System.IO.File]::WriteAllText((Join-Path $root 'etc' 'os-release'), "ID=$Id${lf}VERSION_ID=`"$Version`"${lf}PRETTY_NAME=`"$Id $Version`"$lf")
            foreach ($k in @($Running) + $Boot) { [System.IO.File]::WriteAllText((Join-Path $root 'boot' "vmlinuz-$k"), '') }
            [System.IO.File]::WriteAllText((Join-Path $work 'default.txt'), $Default)
            [System.IO.File]::WriteAllText((Join-Path $work 'pm.log'), '')
            $stubs = @{
                uname  = '#!/bin/bash' + $lf + 'echo "$FAKE_KERNEL"' + $lf
                rpm    = '#!/bin/bash' + $lf + 'exit 0' + $lf
                dnf    = '#!/bin/bash' + $lf + 'echo "dnf $*" >> "$FAKE_LOG"' + $lf +
                         'if [ -n "$FAKE_NEW" ]; then : > "$VMF_TEST_ROOT/boot/vmlinuz-$FAKE_NEW"; fi' + $lf + 'exit 0' + $lf
                grubby = '#!/bin/bash' + $lf + 'echo "grubby $*" >> "$FAKE_LOG"' + $lf +
                         'case "$1" in' + $lf +
                         '  --default-kernel) cat "$FAKE_DEFAULT_FILE"; echo; exit 0 ;;' + $lf +
                         '  --set-default) if [ -z "$FAKE_GRUBBY_KEEPS" ]; then printf %s "$2" > "$FAKE_DEFAULT_FILE"; fi; exit 0 ;;' + $lf +
                         'esac' + $lf + 'exit 0' + $lf
            }
            foreach ($n in $stubs.Keys) { [System.IO.File]::WriteAllText((Join-Path $bin $n), $stubs[$n]) }
            $b = ConvertTo-VmfTestBashPath -Path $bin
            $env = @{
                VMF_TEST_ROOT     = (ConvertTo-VmfTestBashPath -Path $root)
                FAKE_KERNEL       = $Running
                FAKE_NEW          = $New
                FAKE_LOG          = (ConvertTo-VmfTestBashPath -Path (Join-Path $work 'pm.log'))
                FAKE_DEFAULT_FILE = (ConvertTo-VmfTestBashPath -Path (Join-Path $work 'default.txt'))
                FAKE_GRUBBY_KEEPS = $(if ($GrubbyKeeps) { '1' } else { '' })
            }
            $scriptPath = ConvertTo-VmfTestBashPath -Path (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'kernel-update.sh')
            $raw = Invoke-VmfTestBash -Environment $env -ArgumentList @('-c', "chmod +x '$b'/*; PATH='$($b):'`$PATH bash '$scriptPath' 2>/dev/null")
            $json = ($raw | Out-String).Trim()
            [pscustomobject]@{
                Json    = $json
                Doc     = ($json | ConvertFrom-Json)
                Log     = [System.IO.File]::ReadAllText((Join-Path $work 'pm.log'))
                Default = [System.IO.File]::ReadAllText((Join-Path $work 'default.txt')).Trim()
            }
        }
        finally { [System.IO.Directory]::Delete($work, $true) }
    }
    function script:Get-Check($Doc, [string]$Name) { @($Doc.checks) | Where-Object { $_.name -eq $Name } | Select-Object -First 1 }
}

Describe 'KERNEL-UPDATE-OL-RHCK-1: kernel-update.sh stays in the kernel family the machine runs' {
    It 'the f-olr machine: RHCK running, UEK R8 installed, a newer RHCK in the base repository - the RHCK update is the kernel installed, and it is made the default' -Skip:(-not $script:testBash) {
        $r = Invoke-KernelUpdateFake -Running $script:rhckOld -Boot @($script:uekR8) -New $script:rhckNew -Default "/boot/vmlinuz-$($script:rhckOld)"
        Test-Json -Json $r.Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
        $r.Doc.result | Should -Be 'FIXED'
        (Get-Check $r.Doc 'kernel package').detail | Should -Be 'kernel'
        $r.Log | Should -Match 'dnf -y upgrade kernel(\s|$)'
        $r.Log | Should -Not -Match 'kernel-uek'
        (Get-Check $r.Doc 'kernel installed').detail | Should -Be $script:rhckNew -Because 'a UEK kernel in /boot is not the RHCK update'
        $r.Log | Should -Match ([regex]::Escape("grubby --set-default /boot/vmlinuz-$($script:rhckNew)"))
        $r.Log | Should -Not -Match 'set-default /boot/vmlinuz-6\.12'
        $r.Default | Should -Be "/boot/vmlinuz-$($script:rhckNew)"
        $c = Get-Check $r.Doc 'default boot kernel'
        $c.status | Should -Be 'FIXED'
        $c.detail | Should -Be $script:rhckNew
        (Get-Check $r.Doc 'default boot kernel before').detail | Should -Be "/boot/vmlinuz-$($script:rhckOld)"
    }

    It 'the f-olr machine with no newer RHCK in the repositories: NO_CHANGE, and the UEK kernel is not made the default' -Skip:(-not $script:testBash) {
        $r = Invoke-KernelUpdateFake -Running $script:rhckOld -Boot @($script:uekR8) -Default "/boot/vmlinuz-$($script:rhckOld)"
        $r.Doc.result | Should -Be 'NO_CHANGE'
        (Get-Check $r.Doc 'kernel installed').detail | Should -Be $script:rhckOld
        $r.Log | Should -Not -Match 'set-default'
        $r.Default | Should -Be "/boot/vmlinuz-$($script:rhckOld)"
    }

    It 'a UEK machine with a newer RHCK in /boot: the UEK R8 update is the kernel installed and the default' -Skip:(-not $script:testBash) {
        $r = Invoke-KernelUpdateFake -Running $script:uekR7 -Boot @('5.14.0-611.5.1.0.1.el9_7.x86_64') -New $script:uekR8 -Default "/boot/vmlinuz-$($script:uekR7)"
        $r.Doc.result | Should -Be 'FIXED'
        (Get-Check $r.Doc 'kernel package').detail | Should -Be 'kernel-uek'
        (Get-Check $r.Doc 'kernel installed').detail | Should -Be $script:uekR8
        $r.Default | Should -Be "/boot/vmlinuz-$($script:uekR8)"
        (Get-Check $r.Doc 'default boot kernel').detail | Should -Be $script:uekR8
    }

    It 'a RHCK update that is already the default: grubby changes nothing, and the default is said' -Skip:(-not $script:testBash) {
        $r = Invoke-KernelUpdateFake -Running $script:rhckOld -Boot @($script:uekR8, $script:rhckNew) -Default "/boot/vmlinuz-$($script:rhckNew)"
        $r.Doc.result | Should -Be 'FIXED'
        $r.Log | Should -Not -Match 'set-default'
        $c = Get-Check $r.Doc 'default boot kernel'
        $c.status | Should -Be 'INFO'
        $c.detail | Should -Be $script:rhckNew
    }

    It 'grubby says it set the default, and the default read back is another kernel: BLOCKED after the package manager ran' -Skip:(-not $script:testBash) {
        $r = Invoke-KernelUpdateFake -Running $script:rhckOld -Boot @($script:uekR8) -New $script:rhckNew -Default "/boot/vmlinuz-$($script:rhckOld)" -GrubbyKeeps
        $r.Doc.result | Should -Be 'BLOCKED'
        (Get-Check $r.Doc 'package manager ran').detail | Should -Be 'yes'
        (Get-Check $r.Doc 'default boot kernel').status | Should -Be 'WARN'
        $r.Doc.error | Should -Match ([regex]::Escape("The default boot kernel is /boot/vmlinuz-$($script:rhckOld)"))
    }

    # Review, 2026-11-16: a variant kernel (+debug, +rt, +64k) of the same
    # release sorts above the plain kernel, so it was read as a newer kernel
    # and made the default. A variant counts only when the running kernel is
    # the same variant.
    It 'a plain kernel with +debug and +rt kernels in /boot and nothing new from dnf: NO_CHANGE, and no variant is made the default' -Skip:(-not $script:testBash) {
        $plain = '5.14.0-570.52.1.el9_6.x86_64'
        $r = Invoke-KernelUpdateFake -Id 'rhel' -Version '9.6' -Running $plain -Boot @("$plain+debug", "$plain+rt") -Default "/boot/vmlinuz-$plain"
        $r.Doc.result | Should -Be 'NO_CHANGE'
        (Get-Check $r.Doc 'kernel installed').detail | Should -Be $plain
        $r.Log | Should -Not -Match 'set-default'
        $r.Default | Should -Be "/boot/vmlinuz-$plain"
    }

    It 'a plain kernel with +debug and +rt kernels in /boot and a newer plain kernel from dnf: the plain kernel is installed and the default' -Skip:(-not $script:testBash) {
        $plain = '5.14.0-570.52.1.el9_6.x86_64'
        $newer = '5.14.0-570.60.1.el9_6.x86_64'
        $r = Invoke-KernelUpdateFake -Id 'rhel' -Version '9.6' -Running $plain -Boot @("$plain+debug", "$newer+debug", "$newer+rt") -New $newer -Default "/boot/vmlinuz-$plain"
        $r.Doc.result | Should -Be 'FIXED'
        (Get-Check $r.Doc 'kernel installed').detail | Should -Be $newer
        $r.Default | Should -Be "/boot/vmlinuz-$newer"
    }

    It 'a +rt kernel stays on +rt: a newer plain kernel in /boot is not its update' -Skip:(-not $script:testBash) {
        $rt = '5.14.0-570.52.1.el9_6.x86_64+rt'
        $r = Invoke-KernelUpdateFake -Id 'rhel' -Version '9.6' -Running $rt -Boot @('5.14.0-570.70.1.el9_6.x86_64') -New '5.14.0-570.60.1.el9_6.x86_64+rt' -Default "/boot/vmlinuz-$rt"
        $r.Doc.result | Should -Be 'FIXED'
        (Get-Check $r.Doc 'kernel installed').detail | Should -Be '5.14.0-570.60.1.el9_6.x86_64+rt'
        $r.Default | Should -Be '/boot/vmlinuz-5.14.0-570.60.1.el9_6.x86_64+rt'
    }

    It 'Red Hat itself: the newer kernel is made the default too, from the same rule' -Skip:(-not $script:testBash) {
        $r = Invoke-KernelUpdateFake -Id 'rhel' -Version '9.6' -Running '5.14.0-570.12.1.el9_6.x86_64' -New '5.14.0-570.60.1.el9_6.x86_64' -Default '/boot/vmlinuz-5.14.0-570.12.1.el9_6.x86_64'
        $r.Doc.result | Should -Be 'FIXED'
        $r.Default | Should -Be '/boot/vmlinuz-5.14.0-570.60.1.el9_6.x86_64'
    }
}

Describe 'KERNEL-UPDATE-OL-RHCK-1: the engine compares the kernel the machine starts on with the default boot kernel' {
    It 'Get-VmfKernelUpdateOutcome reads the default boot kernel the script set, and only from INFO or FIXED' {
        InModuleScope VmMigrationFactory {
            $out = { param([string]$Status, [string]$Default) [pscustomobject]@{ result = 'FIXED'; checks = @(
                        [pscustomobject]@{ name = 'kernel before'; status = 'INFO'; detail = '5.14.0-570.51.1.0.1.el9_6.x86_64' }
                        [pscustomobject]@{ name = 'kernel installed'; status = 'INFO'; detail = '5.14.0-570.52.1.0.1.el9_6.x86_64' }
                        [pscustomobject]@{ name = 'default boot kernel'; status = $Status; detail = $Default }) } }
            (Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'FIXED' '5.14.0-570.52.1.0.1.el9_6.x86_64')).KernelDefault | Should -Be '5.14.0-570.52.1.0.1.el9_6.x86_64'
            (Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'INFO' '5.14.0-570.52.1.0.1.el9_6.x86_64')).KernelDefault | Should -Be '5.14.0-570.52.1.0.1.el9_6.x86_64'
            (Get-VmfKernelUpdateOutcome -GuestOutput (& $out 'WARN' 'grubby is not on this machine')).KernelDefault | Should -BeNullOrEmpty
            $none = [pscustomobject]@{ result = 'FIXED'; checks = @([pscustomobject]@{ name = 'kernel installed'; status = 'INFO'; detail = 'x' }) }
            (Get-VmfKernelUpdateOutcome -GuestOutput $none).KernelDefault | Should -BeNullOrEmpty
        }
    }

    It 'the f-olr restart onto the old RHCK kernel names the default boot kernel, not a UEK kernel' {
        InModuleScope VmMigrationFactory {
            $c = Get-VmfKernelUpdateRecheck -Presence 'present' -Verdict @{ Status = 'FAIL'; Detail = 'kernel 5.14.0-570.51.1.0.1.el9_6.x86_64 is below the published minimum 5.14.0-570.52.1 for ol 9.7' } `
                -KernelBefore '5.14.0-570.51.1.0.1.el9_6.x86_64' -KernelInstalled '5.14.0-570.52.1.0.1.el9_6.x86_64' `
                -KernelDefault '5.14.0-570.52.1.0.1.el9_6.x86_64' -KernelAfter '5.14.0-570.51.1.0.1.el9_6.x86_64'
            $c.Ok | Should -BeFalse
            $c.Detail | Should -Match '^The machine started on kernel 5\.14\.0-570\.51\.1\.0\.1\.el9_6\.x86_64, not on the default boot kernel 5\.14\.0-570\.52\.1\.0\.1\.el9_6\.x86_64\.'
        }
    }

    It 'a start on the default boot kernel is not called a mismatch, whatever kernel installed says' {
        InModuleScope VmMigrationFactory {
            $c = Get-VmfKernelUpdateRecheck -Presence 'absent' -Verdict @{ Status = 'FAIL' } -KernelBefore 'a' -KernelInstalled 'b' -KernelDefault 'c' -KernelAfter 'c'
            $c.Detail | Should -Not -Match 'not on the'
            $c.Detail | Should -Match '^The machine started on kernel c\.'
        }
    }

    It 'with no default boot kernel reported, the installed kernel is the one compared, as before' {
        InModuleScope VmMigrationFactory {
            (Get-VmfKernelUpdateRecheck -Presence 'absent' -Verdict @{ Status = 'FAIL' } -KernelBefore 'a' -KernelInstalled 'b' -KernelAfter 'a').Detail | Should -Match 'not on the installed kernel b'
        }
    }
}
