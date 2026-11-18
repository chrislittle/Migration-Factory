#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VF-UNMANAGED-CONFIG-1, 2026-11-14. Every move to a size that can give the
# MANA adapter turns accelerated networking on, also on a Linux machine that
# had it off. Microsoft (accelerated-networking-overview.md, "Configure
# drivers to be unmanaged"): "Accelerated Networking requires configuring the
# SR-IOV drivers as unmanaged devices in your network settings." Nothing read
# that, so a machine whose network manager takes the virtual function could
# lose its network after the change and be rolled back.
#
# Decided 2026-11-14: a read in Checking, before any change,
# Linux only, for a move with accelerated networking on after it. NetworkManager
# or systemd-networkd with no marker waits for a person's decision (accept, or
# leave out). No answer is never a pass. Guests report facts; the engine judges.
# A real bash: on Windows, the WSL launchers named bash print nothing without
# a distribution, so they are not one. Found at discovery, for -Skip.
BeforeDiscovery {
    $script:suBashFound = [bool](@(@(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
        @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
        Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps|System32' }).Count)
}
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # Microsoft's rule, as azure-vm-utils ships it (udev/10-azure-unmanaged-sriov.rules).
    $script:msRule = 'SUBSYSTEM=="net", ACTION!="remove", DRIVERS=="mana|mlx4_core|mlx5_core", ATTR{flags}=="0x?[89ABCDEF]??", ENV{AZURE_UNMANAGED_SRIOV}="1", ENV{ID_NET_MANAGED_BY}="unmanaged", ENV{NM_UNMANAGED}="1"'

    # One answer of sriov-unmanaged-check.sh. Every fact is given; a test
    # changes the ones it is about.
    function Global:SuOut {
        param([hashtable]$Facts = @{}, [string]$Result = 'READY', [string]$ErrorText = '')
        $f = [ordered]@{
            os = 'Linux'; networkManager = 'inactive'; networkd = 'inactive'; wicked = 'inactive'; ifupdown = 'no'
            systemdVersion = '249'; cloudInitVersion = 'none'; cloudInitNetwork = 'enabled'
            sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none'
        }
        foreach ($k in $Facts.Keys) { if ($null -eq $Facts[$k]) { $f.Remove($k) } else { $f[$k] = $Facts[$k] } }
        $o = [ordered]@{ schema = 'vmf.guest/7'; script = 'sriov-unmanaged-check.sh'; version = '1.0.0'; result = $Result
            checks = @(); facts = [pscustomobject]$f; warnings = @() }
        if ($ErrorText) { $o.error = $ErrorText }
        [pscustomobject]$o
    }
    function Global:SuVerdict($o) {
        InModuleScope VmMigrationFactory -Parameters @{ o = $o } { param($o) Get-VmfSriovUnmanagedVerdict -GuestOutput $o }
    }
}
AfterAll { Remove-Item 'function:\SuOut', 'function:\SuVerdict' -ErrorAction SilentlyContinue }

Describe 'VF-UNMANAGED-CONFIG-1: the engine judges the facts against Microsoft''s markers' {

    It 'NetworkManager with Microsoft''s udev rule: set' {
        $v = SuVerdict (SuOut -Facts @{ networkManager = 'active'; sriovUdevLines = "/usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)" })
        $v.Verdict | Should -Be 'set'
        $v.Detail | Should -Match '10-azure-unmanaged-sriov\.rules'
    }

    It 'NetworkManager with no marker and no cloud-init: not set, and the words quote Microsoft and name what is missing' {
        $v = SuVerdict (SuOut -Facts @{ networkManager = 'active' })
        $v.Verdict | Should -Be 'notSet'
        $v.Detail | Should -Match ([regex]::Escape('Accelerated Networking requires configuring the SR-IOV drivers as unmanaged devices in your network settings.'))
        $v.Detail | Should -Match 'NetworkManager'
        $v.Detail | Should -Match 'NM_UNMANAGED'
        $v.Detail | Should -Match 'unmanaged-devices'
        $v.Detail | Should -Match 'cloud-init is not installed'
    }

    It 'NetworkManager with cloud-init <Version>: <Verdict>' -TestCases @(
        @{ Version = '23.2'; Verdict = 'set' }
        @{ Version = '23.2.1'; Verdict = 'set' }
        @{ Version = '24.1.3'; Verdict = 'set' }
        @{ Version = '23.1.2'; Verdict = 'notSet' }
        @{ Version = '22.4'; Verdict = 'notSet' }
        @{ Version = 'garbled'; Verdict = 'notSet' }
    ) {
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; cloudInitVersion = $Version })).Verdict | Should -Be $Verdict
    }

    It 'cloud-init 23.2 or later whose network configuration is disabled applied none: not set, and said' {
        $v = SuVerdict (SuOut -Facts @{ networkManager = 'active'; cloudInitVersion = '24.1'; cloudInitNetwork = 'disabled' })
        $v.Verdict | Should -Be 'notSet'
        $v.Detail | Should -Match 'network configuration of cloud-init is disabled'
    }

    It 'a rule that leaves out the MANA driver is not Microsoft''s rule: not set' {
        $line = '/etc/udev/rules.d/68-sriov.rules: SUBSYSTEM=="net", DRIVERS=="mlx4_core|mlx5_core", ENV{NM_UNMANAGED}="1"'
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; sriovUdevLines = $line })).Verdict | Should -Be 'notSet'
    }

    It 'a rule that sets NM_UNMANAGED to 0 is not the setting: not set' {
        $line = '/etc/udev/rules.d/10-x.rules: SUBSYSTEM=="net", DRIVERS=="mana|mlx4_core|mlx5_core", ENV{NM_UNMANAGED}="0"'
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; sriovUdevLines = $line })).Verdict | Should -Be 'notSet'
    }

    It 'NetworkManager with a rule for systemd-networkd only: not set' {
        $line = '/etc/udev/rules.d/10-x.rules: SUBSYSTEM=="net", DRIVERS=="mana|mlx4_core|mlx5_core", ENV{ID_NET_MANAGED_BY}="unmanaged"'
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; sriovUdevLines = $line })).Verdict | Should -Be 'notSet'
    }

    It 'NetworkManager with unmanaged-devices that names the three drivers: set' {
        $v = SuVerdict (SuOut -Facts @{ networkManager = 'active'; nmUnmanagedDevices = '/etc/NetworkManager/conf.d/99-azure.conf: driver:mana;driver:mlx4_core;driver:mlx5_core' })
        $v.Verdict | Should -Be 'set'
        $v.Detail | Should -Match 'unmanaged-devices'
    }

    It 'unmanaged-devices that names only two drivers: not set' {
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; nmUnmanagedDevices = '/etc/NetworkManager/NetworkManager.conf: driver:mlx4_core;driver:mlx5_core' })).Verdict | Should -Be 'notSet'
    }

    It 'unmanaged-devices with a driver name that only starts the same is not the driver (exact match): not set' {
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; nmUnmanagedDevices = '/etc/NetworkManager/NetworkManager.conf: driver:manax;driver:mlx4_core;driver:mlx5_core' })).Verdict | Should -Be 'notSet'
    }

    It 'two lines in one fact are read apart' {
        $lines = "/etc/udev/rules.d/1.rules: SUBSYSTEM==""net"", ENV{FOO}=""1"" ;; /usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)"
        (SuVerdict (SuOut -Facts @{ networkManager = 'active'; sriovUdevLines = $lines })).Verdict | Should -Be 'set'
    }

    It 'systemd-networkd 255 or later with the rule: set' {
        (SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = '255'; sriovUdevLines = "/usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)" })).Verdict | Should -Be 'set'
    }

    It 'systemd-networkd below 255 with the rule alone: not set, and the words name the .network file' {
        $v = SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = '249'; sriovUdevLines = "/usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)" })
        $v.Verdict | Should -Be 'notSet'
        $v.Detail | Should -Match 'systemd-networkd'
        $v.Detail | Should -Match '01-azure-unmanaged-sriov\.network'
    }

    It 'systemd-networkd below 255: the words say which marker is missing, the file or the rule, one fact per sentence' {
        $rule = "/usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)"
        $onlyRule = SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = '249'; sriovUdevLines = $rule })
        $onlyRule.Detail | Should -Match ([regex]::Escape('This machine uses systemd-networkd version 249.'))
        $onlyRule.Detail | Should -Match ([regex]::Escape('The product found no file 01-azure-unmanaged-sriov.network that sets Unmanaged=yes.'))
        $onlyRule.Detail | Should -Not -Match 'AZURE_UNMANAGED_SRIOV to 1'
        $onlyFile = SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = '249'; sriovNetworkFiles = '/usr/lib/systemd/network/01-azure-unmanaged-sriov.network' })
        $onlyFile.Detail | Should -Match ([regex]::Escape('The product found no udev rule that sets AZURE_UNMANAGED_SRIOV to 1 for the drivers mana, mlx4_core and mlx5_core.'))
        $onlyFile.Detail | Should -Not -Match 'found no file'
        $noVersion = SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = 'unknown' })
        $noVersion.Detail | Should -Match ([regex]::Escape('This machine uses systemd-networkd. The product could not read its version.'))
    }

    It 'a missing fact is named in words an operator knows, never by its key' {
        $v = SuVerdict (SuOut -Facts @{ networkManager = 'active'; cloudInitVersion = $null; nmUnmanagedDevices = $null })
        $v.Verdict | Should -Be 'unknown'
        $v.Detail | Should -Match ([regex]::Escape('The check did not report the version of cloud-init and the unmanaged-devices setting of NetworkManager.'))
        $v.Detail | Should -Not -Match 'cloudInitVersion|nmUnmanagedDevices'
    }
    It 'systemd-networkd below 255 with the rule and the .network file: set' {
        (SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = '249'
            sriovUdevLines = "/usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)"
            sriovNetworkFiles = '/usr/lib/systemd/network/01-azure-unmanaged-sriov.network' })).Verdict | Should -Be 'set'
    }

    It 'systemd-networkd below 255 with the .network file and no rule: not set (nothing sets the property)' {
        (SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = '249'; sriovNetworkFiles = '/usr/lib/systemd/network/01-azure-unmanaged-sriov.network' })).Verdict | Should -Be 'notSet'
    }

    It 'systemd-networkd with a systemd version it cannot read and only the 255 marker: not set' {
        (SuVerdict (SuOut -Facts @{ networkd = 'active'; systemdVersion = 'unknown'; sriovUdevLines = "/usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules: $($script:msRule)" })).Verdict | Should -Be 'notSet'
    }

    It 'systemd-networkd with cloud-init 23.2 or later (Ubuntu): set' {
        (SuVerdict (SuOut -Facts @{ networkd = 'active'; cloudInitVersion = '24.4.1' })).Verdict | Should -Be 'set'
    }

    It 'both active: each must be set - NetworkManager set and systemd-networkd not is not set' {
        $line = '/etc/udev/rules.d/10-x.rules: SUBSYSTEM=="net", DRIVERS=="mana|mlx4_core|mlx5_core", ENV{NM_UNMANAGED}="1"'
        $v = SuVerdict (SuOut -Facts @{ networkManager = 'active'; networkd = 'active'; sriovUdevLines = $line })
        $v.Verdict | Should -Be 'notSet'
        $v.Detail | Should -Match 'systemd-networkd'
        $v.Detail | Should -Not -Match 'This machine uses NetworkManager[^.]*not'
    }

    It 'a stack Microsoft names no setting for (wicked, ifupdown): not judged, and it says so' {
        $v = SuVerdict (SuOut -Facts @{ wicked = 'active'; ifupdown = 'yes' })
        $v.Verdict | Should -Be 'notJudged'
        $v.Detail | Should -Match 'NetworkManager'
        $v.Detail | Should -Match 'systemd-networkd'
    }

    It 'UNKNOWN, never set: <Name>' -TestCases @(
        @{ Name = 'no answer'; Out = $null }
        @{ Name = 'BLOCKED'; Facts = @{ networkManager = 'active' }; Result = 'BLOCKED' }
        @{ Name = 'no networkManager fact'; Facts = @{ networkManager = $null } }
        @{ Name = 'no networkd fact'; Facts = @{ networkd = $null } }
        @{ Name = 'NetworkManager active, no udev fact'; Facts = @{ networkManager = 'active'; sriovUdevLines = $null } }
        @{ Name = 'NetworkManager active, no cloud-init fact'; Facts = @{ networkManager = 'active'; cloudInitVersion = $null } }
        @{ Name = 'NetworkManager active, no unmanaged-devices fact'; Facts = @{ networkManager = 'active'; nmUnmanagedDevices = $null } }
        @{ Name = 'networkd active, no .network fact'; Facts = @{ networkd = 'active'; sriovNetworkFiles = $null } }
    ) {
        $o = if ($Name -eq 'no answer') { $null } else { SuOut -Facts $Facts -Result $(if ($Result) { $Result } else { 'READY' }) -ErrorText 'read failed' }
        (SuVerdict $o).Verdict | Should -Be 'unknown'
    }
}

Describe 'VF-UNMANAGED-CONFIG-1: Checking runs the read after the cluster check, before any change' {
    BeforeAll {
        $script:suVm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm'
        function Global:SuCtx([hashtable]$Policy = @{}) {
            @{ Plan = [pscustomobject]@{ assessment = [pscustomobject]@{ os = 'Linux' }; policy = [pscustomobject]$Policy }
               Rg = 'rg'; VmName = 'vm'; VmId = $script:suVm; RunPath = $script:suRun }
        }
        function Global:SuAlone {
            [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'cluster-node-check.sh'; version = '1.1.0'; result = 'READY'; checks = @(); warnings = @()
                facts = [pscustomobject]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } }
        }
        function Global:SuNode {
            [pscustomobject]@{ schema = 'vmf.guest/4'; script = 'cluster-node-check.sh'; version = '1.1.0'; result = 'READY'; checks = @(); warnings = @()
                facts = [pscustomobject]@{ os = 'Linux'; pacemaker = 'active'; corosync = 'active'; sqlHadr = 'no' } }
        }
    }
    AfterAll { Remove-Item 'function:\SuCtx', 'function:\SuAlone', 'function:\SuNode' -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:suRun = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-su-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:suRun; id = $script:suVm } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'su' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'su' -VmId $id | Out-Null
        }
        $global:su = @{ cluster = (SuAlone); sriov = (SuOut -Facts @{ networkManager = 'active' }); ran = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            $global:su.ran.Add($ScriptName)
            $a = if ($ScriptName -eq 'sriov-unmanaged-check.sh') { $global:su.sriov } else { $global:su.cluster }
            if ($a -is [scriptblock]) { & $a } else { $a }
        }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
    }
    AfterEach {
        Remove-Variable su -Scope Global -ErrorAction SilentlyContinue
        if ($script:suRun -and (Test-Path $script:suRun)) { [System.IO.Directory]::Delete($script:suRun, $true) }
    }

    It 'not set on a running machine: it waits for a decision, untouched, and the words come from the verdict' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'sriovNotUnmanaged'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'SR-IOV drivers as unmanaged devices'
            $stop.Detail | Should -Match 'Nothing in the machine changed\.$'
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
        @($global:su.ran) | Should -Be @('cluster-node-check.sh', 'sriov-unmanaged-check.sh')
    }

    It 'set: the move goes on, and the step line says what was found' {
        $global:su.sriov = SuOut -Facts @{ networkManager = 'active'; cloudInitVersion = '23.4' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck | Should -BeNullOrEmpty
            Should -Invoke Write-VmfStepLine -Times 1 -ParameterFilter { $Outcome -eq 'info' -and $Detail -match 'cloud-init' }
        }
    }

    It 'not judged (a stack Microsoft names nothing for): the move goes on, and the step line says it' {
        $global:su.sriov = SuOut -Facts @{ wicked = 'active' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck | Should -BeNullOrEmpty
            Should -Invoke Write-VmfStepLine -Times 1 -ParameterFilter { $Outcome -eq 'info' -and $Detail -match 'systemd-networkd' }
        }
    }

    It 'without the switch the read does not run (Windows, or no accelerated networking after the move)' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' | Should -BeNullOrEmpty
        }
        @($global:su.ran) | Should -Be @('cluster-node-check.sh')
    }

    It 'a cluster node stops first, and the read does not run' {
        $global:su.cluster = SuNode
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            (Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck).Reason | Should -Be 'clusterNode'
        }
        @($global:su.ran) | Should -Be @('cluster-node-check.sh')
    }

    It 'an approver accepted it for this machine: the read does not run, the move goes on, and the step line says who decided' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx -Policy @{ onSriovUnmanagedMissing = 'proceed' }) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck | Should -BeNullOrEmpty
            Should -Invoke Write-VmfStepLine -Times 1 -ParameterFilter { $Outcome -eq 'info' -and $Detail -match 'approver accepted' }
        }
        @($global:su.ran) | Should -Be @('cluster-node-check.sh')
    }

    It 'any other value of the setting is not an acceptance: <Value>' -TestCases @(
        @{ Value = 'stop' }, @{ Value = 'Proceed' }, @{ Value = 'proceed ' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx -Policy @{ onSriovUnmanagedMissing = $Value }) } {
            (Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck).Reason | Should -Be 'sriovNotUnmanaged'
        }
    }

    It 'an answer of BLOCKED is unknown: it waits for a decision with its own reason, and names the error' {
        $global:su.sriov = SuOut -Result 'BLOCKED' -ErrorText 'no systemctl to read the network services'
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck
            $stop.Next | Should -Be 'NEEDS_DECISION'
            $stop.Reason | Should -Be 'sriovUnmanagedNotChecked'
            $stop.MachineState | Should -Be 'untouched'
            $stop.Detail | Should -Match 'no systemctl'
        }
    }

    It 'on a running machine, a Run Command that fails is the product''s rule: the error goes up to the step, never a pass' {
        $global:su.sriov = { throw 'RunCommand on vm returned no result - verify the VM is running.' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            { Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/running' -SriovCheck } | Should -Throw '*returned no result*'
        }
    }

    It 'a deallocated machine: started for the checks, not set, deallocated again, and stopped untouched' {
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' -SriovCheck
            $stop.Reason | Should -Be 'sriovNotUnmanaged'
            $stop.MachineState | Should -Be 'untouched'
            Should -Invoke Start-VmfVm -Times 1 -Exactly
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
        }
    }

    It 'a deallocated machine whose read fails: put back, then it waits with the unknown reason - never left running' {
        $global:su.sriov = { throw 'RunCommand on vm returned no result - verify the VM is running.' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            $stop = Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' -SriovCheck
            $stop.Reason | Should -Be 'sriovUnmanagedNotChecked'
            $stop.Detail | Should -Match 'returned no result'
            Should -Invoke Stop-VmfVmDeallocated -Times 1 -Exactly
        }
    }

    It 'a lost lease during the read touches nothing more' {
        $global:su.sriov = { throw 'Lease lost - abandon this VM' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            { Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' -SriovCheck } | Should -Throw '*abandon this VM*'
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
        }
    }

    It 'a deallocated machine that is set goes on, running: the record says goingOn' {
        $global:su.sriov = SuOut -Facts @{ networkManager = 'active'; cloudInitVersion = '23.4' }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SuCtx) } {
            Get-VmfWorkloadCheckStop -Context $c -Power 'PowerState/deallocated' -SriovCheck | Should -BeNullOrEmpty
            Should -Invoke Stop-VmfVmDeallocated -Times 0 -Exactly
            $d = Read-VmfStateDoc -RunPath $c.RunPath -VmId $c.VmId
            $d.captured.clusterCheckPower.status | Should -Be 'goingOn'
        }
    }
}

Describe 'VF-UNMANAGED-CONFIG-1: PRECHECK asks for the read only for a Linux move with accelerated networking on after it' {
    It 'the call passes the switch from the decision Checking already made, and from the plan''s operating system' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match ([regex]::Escape("Get-VmfWorkloadCheckStop -Context `$Context -Power `$power -SriovCheck:([bool]`$anEarly.ExpectFabric -and [string]`$plan.assessment.os -eq 'Linux')"))
    }

    It 'the read is followed by the neutral script, as the cluster check is (RUNCMD-REPLAY-1)' {
        InModuleScope VmMigrationFactory { $script:VmfGuestFollowUpScripts } | Should -Contain 'sriov-unmanaged-check.sh'
    }
}

Describe 'VF-UNMANAGED-CONFIG-1: the contracts' {
    BeforeAll {
        $script:stops = (Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons
    }

    It '<Code>: a decision an approver accepts with onSriovUnmanagedMissing = proceed, which may return the power state' -TestCases @(
        @{ Code = 'sriovNotUnmanaged' }, @{ Code = 'sriovUnmanagedNotChecked' }
    ) {
        $r = @($script:stops | Where-Object code -EQ $Code)[0]
        $r | Should -Not -BeNullOrEmpty
        $r.decide.lever | Should -Be 'onSriovUnmanagedMissing'
        $r.decide.accept | Should -Be 'proceed'
        $r.decide.approver | Should -BeTrue
        $r.machine | Should -Be 'untouched'
        $r.machinePowerBack | Should -BeTrue
        $r.retry | Should -Be 'afterFix'
    }

    It 'the setting is in the policy contract: stop or proceed, and nothing else' {
        InModuleScope VmMigrationFactory {
            (Get-VmfPolicyLevers)['onSriovUnmanagedMissing'] | Should -Be @('stop', 'proceed')
            (Get-VmfStoredPolicyValues)['onSriovUnmanagedMissing'] | Should -Be @('stop', 'proceed')
            (Test-VmfPolicyOverride -Override @{ onSriovUnmanagedMissing = 'proceed' }).Ok | Should -BeTrue
            (Test-VmfPolicyOverride -Override @{ onSriovUnmanagedMissing = 'maybe' }).Ok | Should -BeFalse
            Get-VmfPlanPolicyRefusal -PlanEntry ([pscustomobject]@{ policy = [pscustomobject]@{ onSriovUnmanagedMissing = 'Proceed' } }) | Should -Not -BeNullOrEmpty
        }
    }

    It 'plan-entry v36 declares it, and the sample is valid with it' {
        $schemaPath = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
        $s = Get-Content $schemaPath -Raw | ConvertFrom-Json -Depth 40
        $s.properties.schemaVersion.const | Should -Be 37
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion } | Should -Be 37
        @($s.properties.policy.properties.onSriovUnmanagedMissing.enum) | Should -Be @('stop', 'proceed')
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json -Depth 40
        $sample.schemaVersion | Should -Be 37
        $sample.policy | Add-Member -NotePropertyName onSriovUnmanagedMissing -NotePropertyValue 'proceed' -Force
        ($sample | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath | Should -BeTrue
        $sample.policy.onSriovUnmanagedMissing = 'continue'
        ($sample | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'the guest contract vmf.guest/7 declares every fact, and the reader takes it' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -Raw | ConvertFrom-Json
        @($schema.properties.schema.enum) | Should -Contain 'vmf.guest/7'
        foreach ($f in 'networkManager', 'networkd', 'wicked', 'ifupdown', 'systemdVersion', 'cloudInitVersion', 'cloudInitNetwork', 'sriovUdevLines', 'sriovNetworkFiles', 'nmUnmanagedDevices') {
            $schema.properties.facts.properties.PSObject.Properties[$f] | Should -Not -BeNullOrEmpty -Because $f
        }
        $json = '{"schema":"vmf.guest/7","script":"sriov-unmanaged-check.sh","version":"1.0.0","result":"READY","checks":[],"facts":{"os":"Linux","networkManager":"active"}}'
        (ConvertFrom-VmfGuestOutput -RawOutput $json).result | Should -Be 'READY'
    }

    It 'the script is in the manifest, starts with the bash shebang, and only reads' {
        $manifest = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'manifest.json') -Raw | ConvertFrom-Json
        @($manifest.scripts | Where-Object { $_.name -eq 'sriov-unmanaged-check.sh' -and $_.os -eq 'linux' }).Count | Should -Be 1
        $lin = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'sriov-unmanaged-check.sh') -Raw
        $lin | Should -Match '^#!/bin/bash'
        $lcode = Get-VmfCodeOnly -Language Shell -Text $lin
        $lcode | Should -Not -Match '\bsystemctl\s+(start|stop|restart|enable|disable|mask|kill|reload)\b'
        $lcode | Should -Not -Match '\b(tee|touch|rm|mv|cp|nmcli|udevadm\s+(trigger|control)|ln|chmod|sed\s+-i)\b'
        ($lcode -replace '2>/dev/null', '' -replace '>/dev/null', '' -replace '2>&1', '') | Should -Not -Match '>'
    }
}

Describe 'VF-UNMANAGED-CONFIG-1: the Linux script, run here with stand-ins' {
    BeforeAll {
        $script:suBash = @(@(Get-Command bash -All -CommandType Application -ErrorAction SilentlyContinue | ForEach-Object Source) +
            @(if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'Git' 'bin' 'bash.exe' }) |
            Where-Object { $_ -and (Test-Path $_) -and $_ -notmatch 'WindowsApps|System32' }) | Select-Object -First 1
        # Runs the script with a fake root and stand-ins for systemctl and
        # cloud-init. -Files maps a path under the root to its text.
        function Global:SuRunScript {
            param([hashtable]$Files = @{}, [string]$Active = 'NetworkManager', [string]$CloudInit = '', [string]$SystemdVersion = '249')
            $work = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-su-sh-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            $null = New-Item -ItemType Directory -Path (Join-Path $work 'bin'), (Join-Path $work 'root') -Force
            try {
                $sysctl = "#!/bin/bash`nif [ `"`$1`" = --version ]; then echo 'systemd $SystemdVersion (stand-in)'; exit 0; fi`nif [ `"`$1`" = is-active ] && [ `"`$2`" = '$Active' ]; then echo active; exit 0; fi`necho inactive`nexit 3`n"
                [System.IO.File]::WriteAllText((Join-Path $work 'bin' 'systemctl'), $sysctl)
                if ($CloudInit) {
                    [System.IO.File]::WriteAllText((Join-Path $work 'bin' 'cloud-init'), "#!/bin/bash`necho '/usr/bin/cloud-init $CloudInit'`n")
                }
                foreach ($k in $Files.Keys) {
                    $full = Join-Path (Join-Path $work 'root') $k
                    $null = New-Item -ItemType Directory -Path (Split-Path $full) -Force
                    [System.IO.File]::WriteAllText($full, $Files[$k])
                }
                $u = { param($w) (& $script:suBash -c "cygpath -u '$w'" | Out-String).Trim() }
                $unixBin = & $u (Join-Path $work 'bin')
                $unixRoot = & $u (Join-Path $work 'root')
                $unixScript = & $u (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'sriov-unmanaged-check.sh')
                # Only the stand-ins and the basic tools: no cloud-init of this PC.
                $out = & $script:suBash -c "chmod +x '$unixBin'/*; PATH='$($unixBin):/usr/bin:/bin' VMF_ROOT='$unixRoot' bash '$unixScript'"
                ($out | Out-String).Trim()
            }
            finally { [System.IO.Directory]::Delete($work, $true) }
        }
    }
    AfterAll { Remove-Item 'function:\SuRunScript' -ErrorAction SilentlyContinue }

    It 'Microsoft''s rule in /usr/lib under NetworkManager: one object in the contract, and the engine says set' -Skip:(-not $script:suBashFound) {
        $json = SuRunScript -Files @{ 'usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules' = "# comment line with NM_UNMANAGED`n$($script:msRule)`n" }
        Test-Json -Json $json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'guest-output.schema.json') -ErrorAction Stop | Should -BeTrue
        $doc = ConvertFrom-VmfGuestOutput -RawOutput $json
        $doc.result | Should -Be 'READY'
        $doc.facts.networkManager | Should -Be 'active'
        $doc.facts.networkd | Should -Be 'inactive'
        $doc.facts.cloudInitVersion | Should -Be 'none'
        $doc.facts.sriovUdevLines | Should -Match '^/usr/lib/udev/rules\.d/10-azure-unmanaged-sriov\.rules: SUBSYSTEM'
        $doc.facts.sriovUdevLines | Should -Not -Match 'comment line'
        (SuVerdict $doc).Verdict | Should -Be 'set'
    }

    It 'a file of the same name in /etc replaces the one in /usr/lib (udev(7)): an empty one turns it off' -Skip:(-not $script:suBashFound) {
        $json = SuRunScript -Files @{ 'usr/lib/udev/rules.d/10-azure-unmanaged-sriov.rules' = "$($script:msRule)`n"; 'etc/udev/rules.d/10-azure-unmanaged-sriov.rules' = '' }
        $doc = ConvertFrom-VmfGuestOutput -RawOutput $json
        $doc.facts.sriovUdevLines | Should -Be 'none'
        (SuVerdict $doc).Verdict | Should -Be 'notSet'
    }

    It 'cloud-init with network configuration disabled, the .network file, unmanaged-devices and ifupdown are read' -Skip:(-not $script:suBashFound) {
        $json = SuRunScript -Active 'systemd-networkd' -CloudInit '23.4.4-0ubuntu0~22.04.1' -SystemdVersion '249' -Files @{
            'etc/cloud/cloud.cfg.d/99-disable-network-config.cfg' = "network: {config: disabled}`n"
            'usr/lib/systemd/network/01-azure-unmanaged-sriov.network' = "[Match]`nProperty=AZURE_UNMANAGED_SRIOV=1`n`n[Link]`nUnmanaged=yes`n"
            'etc/NetworkManager/conf.d/90-sriov.conf' = "[keyfile]`nunmanaged-devices=driver:mana;driver:mlx4_core;driver:mlx5_core`n"
            'etc/network/interfaces' = "auto lo`niface lo inet loopback`nauto eth0`niface eth0 inet dhcp`n"
        }
        $doc = ConvertFrom-VmfGuestOutput -RawOutput $json
        $doc.facts.networkd | Should -Be 'active'
        $doc.facts.systemdVersion | Should -Be '249'
        $doc.facts.cloudInitVersion | Should -Be '23.4.4'
        $doc.facts.cloudInitNetwork | Should -Be 'disabled'
        $doc.facts.sriovNetworkFiles | Should -Be '/usr/lib/systemd/network/01-azure-unmanaged-sriov.network'
        $doc.facts.nmUnmanagedDevices | Should -Be '/etc/NetworkManager/conf.d/90-sriov.conf: driver:mana;driver:mlx4_core;driver:mlx5_core'
        $doc.facts.ifupdown | Should -Be 'yes'
        (SuVerdict $doc).Verdict | Should -Be 'notSet' -Because 'the .network file alone sets nothing, and cloud-init applied no network configuration'
    }

    It 'no systemctl: BLOCKED, which the engine reads as unknown' -Skip:(-not $script:suBashFound) {
        $work = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-su-nb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $null = New-Item -ItemType Directory -Path $work -Force
        try {
            # A PATH with only the tools the script needs, and no systemctl.
            $bin = Join-Path $work 'bin'
            $null = New-Item -ItemType Directory -Path $bin -Force
            $u = { param($w) (& $script:suBash -c "cygpath -u '$w'" | Out-String).Trim() }
            $unixBin = & $u $bin
            $unixScript = & $u (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'sriov-unmanaged-check.sh')
            foreach ($tool in 'sed', 'tr', 'grep', 'head', 'cat', 'basename', 'sort', 'awk') {
                & $script:suBash -c "ln -s `"`$(command -v $tool)`" '$unixBin/$tool' 2>/dev/null || cp `"`$(command -v $tool)`" '$unixBin/$tool'" | Out-Null
            }
            $json = (& $script:suBash -c "PATH='$unixBin' VMF_ROOT='$(& $u $work)' /bin/bash '$unixScript'" | Out-String).Trim()
            $doc = ConvertFrom-VmfGuestOutput -RawOutput $json
            $doc.result | Should -Be 'BLOCKED'
            (SuVerdict $doc).Verdict | Should -Be 'unknown'
        }
        finally { [System.IO.Directory]::Delete($work, $true) }
    }
}
