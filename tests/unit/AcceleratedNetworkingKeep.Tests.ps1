#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# AN-KEEP-1, from the Gen1 Microsoft-route drill (2026-09-25): an Ubuntu 18.04
# machine had accelerated networking OFF. The engine's default for an NVMe
# target switched it ON, the 18.04 kernel has no MANA driver, and VALIDATING
# failed with "neither MANA nor an SR-IOV VF is bound" - so the product rolled
# back a failure it had made itself. Left as it was, the machine would have
# moved with the network it already had.
#
# The rule, from what the machine can be shown to have:
#
#   Linux, and `modinfo mana` finds no driver in the running kernel:
#     off before  -> AN-MANA-DRIVER-RULE-1 (2026-11-06): no longer kept off;
#                    the same as on before (off is not off on a size that
#                    can give MANA - measured)
#     on before   -> the existing driver stop (onDriverBelowFloor): stop and
#                    ask, or, if an approver accepted it, move WITHOUT it
#   Everything else -> exactly as before.
#
# WINDOWS IS DELIBERATELY "everything else". Measured in this repository's own
# run evidence: two Windows machines reported NO mana*.sys before their move
# (2026-09-03 and 2026-09-25) and a bound MANA adapter after it, and both
# passed. Windows installs its in-box driver when the hardware appears, so an
# absent file before the move proves nothing about after it.
#
# Microsoft's per-distribution table is NOT the signal either: it lists the
# RECOMMENDED kernel, and leaves out distributions that do run MANA (Ubuntu
# 20.04, RHEL 8). The kernel either carries the driver or it does not.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    function Global:AnNics([bool]$PrimaryOn, [bool]$SecondOn = $false, [switch]$Two) {
        $n = @([pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic0'; primary = $true; acceleratedNetworking = $PrimaryOn })
        if ($Two) { $n += [pscustomobject]@{ id = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Network/networkInterfaces/nic1'; primary = $false; acceleratedNetworking = $SecondOn } }
        , $n
    }
    function Global:AnPlan([string]$Controller = 'NVMe', [string]$Os = 'Linux', [string]$OnFloor = 'stop', [string]$An = '') {
        $policy = [ordered]@{ onDriverBelowFloor = $OnFloor }
        if ($An) { $policy.acceleratedNetworking = $An }
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/anvm'
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2ds_v4'; sourceDiskArch = 'scsi-temp'; platformManaged = $false }
            # DRIFT-11: v7, not v6. Every v6 size requires accelerated
            # networking since 2026-10-27, so a machine with it off stops for an
            # approver there; the keep-off rule is held on v7, which does not.
            target = [pscustomobject]@{ size = 'Standard_D2ds_v7'; diskArch = 'nvme-temp'; controller = $Controller }
            path = 'A'
            policy = [pscustomobject]$policy
        }
    }
    # What mana-check.sh really says on the drill's Ubuntu 18.04 machine, and
    # on a kernel that carries the driver.
    function Global:AnManaCheck([string]$Module) {
        # 'old': a listed release (22.04) whose kernel has the module but is
        # below Microsoft's floor - the FAIL verdict (AN-PROCEED-NETVSC-1).
        $status = if ($Module -in @('present', 'old')) { 'PASS' } else { 'WARN' }
        [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'mana-check.sh'; version = '1.1.0'; os = 'Ubuntu 18.04.6 LTS'
            result = $(if ($Module -eq 'present') { 'READY' } else { 'NEEDS_PREP' }); warnings = @()
            checks = @(
                [pscustomobject]@{ name = 'kernel'; status = 'INFO'; detail = '5.4.0-1109-azure' }
                [pscustomobject]@{ name = 'mana module available'; status = $status; detail = 'modinfo mana' })
            facts = $(if ($Module -eq 'old') {
                    [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.15.0-1031-azure'; distroId = 'ubuntu'; distroVersion = '22.04'; fabric = 'none' }
                } elseif ($Module -eq 'present') {
                    # RHEL8-MANA-1: a machine WITH the driver is now also one
                    # Microsoft lists - 18.04 with a driver would be 'unlisted'.
                    [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.15.0-1100-azure'; distroId = 'ubuntu'; distroVersion = '22.04'; fabric = 'none' }
                } else {
                    [pscustomobject]@{ os = 'Linux'; kernelVersion = '5.4.0-1109-azure'; distroId = 'ubuntu'; distroVersion = '18.04'; fabric = 'none' }
                }) }
    }
}
AfterAll { Remove-Item 'function:\AnNics', 'function:\AnPlan', 'function:\AnManaCheck' -ErrorAction SilentlyContinue }

Describe 'AN-KEEP-1: does the machine carry a MANA driver, read before the move' {
    It 'Linux: the kernel says so, and absent is a definite answer' {
        InModuleScope VmMigrationFactory {
            Get-VmfManaDriverPresence -GuestOutput (Global:AnManaCheck 'absent') -Os 'Linux' | Should -Be 'absent'
            Get-VmfManaDriverPresence -GuestOutput (Global:AnManaCheck 'present') -Os 'Linux' | Should -Be 'present'
        }
    }

    It 'no answer is UNKNOWN, never absent' {
        InModuleScope VmMigrationFactory {
            Get-VmfManaDriverPresence -GuestOutput $null -Os 'Linux' | Should -Be 'unknown'
            Get-VmfManaDriverPresence -GuestOutput ([pscustomobject]@{ checks = @() }) -Os 'Linux' | Should -Be 'unknown'
        }
    }

    It 'Windows is always UNKNOWN before the move - its driver arrives with the hardware' {
        InModuleScope VmMigrationFactory {
            $win = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana driver file'; status = 'WARN'; detail = 'no mana*.sys found' }) }
            Get-VmfManaDriverPresence -GuestOutput $win -Os 'Windows' | Should -Be 'unknown'
            # A Linux-shaped absent answer on a machine the plan says is Windows
            # is still not trusted as a Windows answer.
            Get-VmfManaDriverPresence -GuestOutput (Global:AnManaCheck 'absent') -Os 'Windows' | Should -Be 'unknown'
        }
    }
}

Describe 'AN-KEEP-1: what happens to accelerated networking on the move' {
    # AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. This said "kept
    # off, and MANA is not demanded" (preserve). Measured 2026-11-06: with the
    # setting off, Azure still attaches the virtual function on a size that
    # can give MANA, so the machine ran on the synthetic interface. Now the
    # move turns it on, and a kernel with no driver stops before any change.
    It 'OFF before, no driver: never kept off - the driver stop, with the machine untouched' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan) -CapturedNics (Global:AnNics $false) -ManaDriver 'absent'
            $r.Policy | Should -Not -Be 'preserve'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
        }
    }

    It 'ON before, no driver: the driver stop, with the machine untouched' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan -OnFloor 'stop') -CapturedNics (Global:AnNics $true) -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
            $r.Detail | Should -Match 'MANA'
        }
    }

    # AN-PROCEED-NETVSC-1 (2026-11-06): rewritten. An approver's
    # Continue moved it as planned with MANA no longer demanded, and on a MANA
    # host it ran on the synthetic interface. There is no Continue now.
    It 'ON before, no driver, and a plan that still says proceed: the driver stop, untouched' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan -OnFloor 'proceed') -CapturedNics (Global:AnNics $true) -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'driverBelowFloor'
        }
    }

    It 'a wave that ASKS for accelerated networking on a kernel with no driver stops - it cannot be given' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan -An 'ensureOn') -CapturedNics (Global:AnNics $false) -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
        }
    }

    # OLD-VERSION-READERS-REMOVE-3: ensureOff left the plan contract at v33.
    # On v7, which can give MANA, a plan that keeps it off (preserve on a
    # primary that is off) is refused in Checking.
    It 'a wave that keeps it off is refused on v7' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan -An 'preserve') -CapturedNics (Global:AnNics $false) -ManaDriver 'absent'
            $r.Stop | Should -BeTrue
            $r.Reason | Should -Be 'acceleratedNetworkingRequired'
        }
    }
    It 'a kernel WITH the driver, or an unknown answer, changes nothing' {
        InModuleScope VmMigrationFactory {
            foreach ($d in 'present', 'unknown') {
                foreach ($on in $true, $false) {
                    $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan) -CapturedNics (Global:AnNics $on) -ManaDriver $d
                    $r.Policy | Should -Be 'ensureOn' -Because "$d, on before = $on"
                    $r.ExpectFabric | Should -BeTrue
                    $r.Stop | Should -BeFalse
                }
            }
        }
    }

    It 'a SCSI target changes nothing: MANA is not demanded there anyway' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan -Controller 'SCSI') -CapturedNics (Global:AnNics $true) -ManaDriver 'absent'
            $r.Policy | Should -Be 'preserve'
            $r.ExpectFabric | Should -BeFalse
            $r.Stop | Should -BeFalse
        }
    }

    It 'with no captured network interfaces there is nothing to reason about: unchanged' {
        InModuleScope VmMigrationFactory {
            $r = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan) -CapturedNics @() -ManaDriver 'absent'
            $r.Policy | Should -Be 'ensureOn'
            $r.Stop | Should -BeFalse
        }
    }
}

Describe 'AN-KEEP-1: the decision made before the move is the one the move uses' {
    It 'the conversion and the validation read the saved decision' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ captured = [pscustomobject]@{ acceleratedNetworking = [pscustomobject]@{ policy = 'preserve'; expectFabric = $false } } }
            $d = Get-VmfAcceleratedNetworkingDecision -Doc $doc
            $d.Policy | Should -Be 'preserve'
            $d.ExpectFabric | Should -BeFalse
        }
    }

    It 'OLD-STATE-READERS-FINISH-1: a record with no saved decision throws; the plan is never read in its place' {
        InModuleScope VmMigrationFactory {
            { Get-VmfAcceleratedNetworkingDecision -Doc ([pscustomobject]@{ captured = [pscustomobject]@{} }) } | Should -Throw '*no accelerated networking decision from Preparing*'
            { Get-VmfAcceleratedNetworkingDecision -Doc $null } | Should -Throw '*no accelerated networking decision*'
        }
    }

    It 'CONVERTING and VALIDATING both use it, and the fast-path check is held to it' {
        $sm = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $converting = [regex]::Match($sm, '(?s)function Invoke-VmfStepConverting.*?\n\}').Value
        $validating = [regex]::Match($sm, '(?s)function Invoke-VmfStepValidating.*?\n\}').Value
        $converting | Should -Match 'Get-VmfAcceleratedNetworkingDecision'
        $validating | Should -Match 'Get-VmfAcceleratedNetworkingDecision'
        $converting | Should -Not -Match "Get-VmfPolicy[^\r\n]*'acceleratedNetworking'"
        $validating | Should -Not -Match "Get-VmfPolicy[^\r\n]*'acceleratedNetworking'"
        # GEN-V5-1: the saved decision alone says whether an accelerated adapter is expected,
        # so a v5 move is held to it too.
        $validating | Should -Match 'if \(\$anDecision\.ExpectFabric\)'
    }
}

Describe 'AN-KEEP-1: validation holds every interface to what it had' {
    # OLD-VERSION-READERS-REMOVE-3: 'ensureOff' left the plan contract at v33,
    # and its validation branch with it.
    BeforeAll {
        $script:captured = Global:AnNics $true $true -Two
    }

    It 'ensureOn is unchanged: an interface that LOST it still fails' {
        InModuleScope VmMigrationFactory -Parameters @{ captured = $script:captured } {
            param($captured)
            $live = @([pscustomobject]@{ id = $captured[0].id; acceleratedNetworking = $true }
                      [pscustomobject]@{ id = $captured[1].id; acceleratedNetworking = $false })
            (Test-VmfNicAcceleratedNetworking -Captured $captured -Live $live -Policy 'ensureOn').Ok | Should -BeFalse
        }
    }
}

Describe 'AN-KEEP-1: RUN the step that decides, before the machine is stopped' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-an-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'an-test' | Out-Null }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            if ($ScriptName -eq 'mana-check.sh') { return Global:AnManaCheck $global:anModule }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'Ubuntu 18.04.6 LTS'
                result = 'READY'; warnings = @(); checks = @() }
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable anModule -Scope Global -ErrorAction SilentlyContinue
    }

    # AN-MANA-DRIVER-RULE-1: rewritten. The drill machine went on with
    # accelerated networking kept off; now it stops untouched for a decision,
    # before anything is stopped, because v7 can give MANA and the move turns
    # accelerated networking on there.
    It 'THE DRILL MACHINE: Ubuntu 18.04, off before, no driver - NEEDS_DECISION, untouched, never kept off' {
        $global:anModule = 'absent'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:AnPlan) -RunPath $rp -RunId 'an-test'
            New-VmfStateDoc -RunPath $rp -RunId 'an-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:AnNics $false) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'driverBelowFloor'
            $r.MachineState | Should -Be 'untouched'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.acceleratedNetworking.policy | Should -Not -Be 'preserve'
        }
    }

    It 'on before, no driver: NEEDS_DECISION, before anything is stopped' {
        $global:anModule = 'absent'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:AnPlan -OnFloor 'stop') -RunPath $rp -RunId 'an-test'
            New-VmfStateDoc -RunPath $rp -RunId 'an-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:AnNics $true) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'driverBelowFloor'
            (Get-VmfStopGuidance -Code $r.Reason).machine | Should -Be 'untouched'
        }
    }

    # AN-PROCEED-NETVSC-1 (2026-11-06): a kernel below Microsoft's floor
    # stopped only under 'stop'; 'proceed' moved it on. Now it stops under every
    # setting but 'updateKernel', which updates the kernel first.
    It 'a kernel below the floor stops untouched even where the plan still says proceed' {
        $global:anModule = 'old'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:AnPlan -OnFloor 'proceed') -RunPath $rp -RunId 'an-test'
            New-VmfStateDoc -RunPath $rp -RunId 'an-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:AnNics $true) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'driverBelowFloor'
            $r.MachineState | Should -Be 'untouched'
        }
    }

    It 'a kernel with the driver goes on as before' {
        $global:anModule = 'present'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:AnPlan) -RunPath $rp -RunId 'an-test'
            New-VmfStateDoc -RunPath $rp -RunId 'an-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:AnNics $false) } }
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
            (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.acceleratedNetworking.policy | Should -Be 'ensureOn'
        }
    }
}

# RHEL8-MANA-1, GEN1-DISTROS-1 lab run 2026-09-25: Red Hat 8.10's kernel HAS a
# `mana` module, so AN-KEEP-1 read the machine as able to drive MANA and switched
# accelerated networking on. On D2ds_v6 the module loaded and nothing bound, and
# VALIDATING put the machine back. Microsoft's MANA table does not list Red Hat 8
# - so the product now follows the table (2026-09-26: it must match the
# Azure documents).
#
# The table (Accelerated Networking overview, read 2026-09-26) lists each
# distribution's MINIMUM release and kernel, so a later minor release of the same
# major is covered (Red Hat 9.8 by the 9.6 row - measured: it got MANA). A
# distribution it does not list is not supported for MANA, unless the kernel is
# 6.14 or later: "For users of non endorsed Linux distributions or utilizing
# custom kernels, we recommend the Linux Kernel 6.14 or later".
Describe 'RHEL8-MANA-1: Microsoft''s MANA table decides, not the module alone' {
    It 'reads the table as a minimum release: a later minor of the same major is covered' {
        InModuleScope VmMigrationFactory {
            (Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion '9.8' -Kernel '5.14.0-687.30.1.el9_8.x86_64').versionId | Should -Be '9.6'
            (Find-VmfManaTableEntry -DistroId 'sles' -DistroVersion '15.8' -Kernel '6.4.0-150800.1').versionId | Should -Be '15.7'
            (Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion '26.04' -Kernel '7.0.0-14-azure').versionId | Should -Be '26.04'
        }
    }

    It 'and an earlier release, or one it never lists, is not covered' {
        InModuleScope VmMigrationFactory {
            Find-VmfManaTableEntry -DistroId 'rhel' -DistroVersion '8.10' -Kernel '4.18.0-553.134.1.el8_10.x86_64' | Should -BeNullOrEmpty
            Find-VmfManaTableEntry -DistroId 'sles' -DistroVersion '15.4' -Kernel '5.14.21-150400.24.1' | Should -BeNullOrEmpty
            Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion '20.04' -Kernel '5.15.0-1070-azure' | Should -BeNullOrEmpty
            Find-VmfManaTableEntry -DistroId 'ubuntu' -DistroVersion '18.04' -Kernel '5.4.0-1109-azure' | Should -BeNullOrEmpty
        }
    }

    It 'tells Oracle''s own kernel (UEK) from its Red Hat kernel, as the table does' {
        InModuleScope VmMigrationFactory {
            $uek = Find-VmfManaTableEntry -DistroId 'ol' -DistroVersion '9.4' -Kernel '6.12.0-100.30.1.el9uek.x86_64'
            $uek.kernelFlavor | Should -Be 'uek'
            $uek.minKernel | Should -Be '6.12.0-100.28.2'
            $rhck = Find-VmfManaTableEntry -DistroId 'ol' -DistroVersion '9.4' -Kernel '5.14.0-570.60.1.0.1.el9_6.x86_64'
            $rhck.minKernel | Should -Be '5.14.0-570.52.1'
            Find-VmfManaTableEntry -DistroId 'ol' -DistroVersion '8.10' -Kernel '5.15.0-300.163.18.el8uek.x86_64' | Should -BeNullOrEmpty -Because 'UEK R7 has no minimum in the table'
        }
    }

    It 'Red Hat 8.10 - the lab machine - has the module and is NOT supported for MANA' {
        InModuleScope VmMigrationFactory {
            $out = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS' }) }
            $facts = [pscustomobject]@{ os = 'Linux'; distroId = 'rhel'; distroVersion = '8.10'; kernelVersion = '4.18.0-553.134.1.el8_10.x86_64' }
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts $facts | Should -Be 'unlisted'
        }
    }

    It 'a listed release with the module is supported; a kernel 6.14 or later is supported anywhere' {
        InModuleScope VmMigrationFactory {
            $out = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS' }) }
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'rhel'; distroVersion = '9.8'; kernelVersion = '5.14.0-687.30.1.el9_8' }) | Should -Be 'present'
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'gentoo'; distroVersion = '2.17'; kernelVersion = '6.14.2' }) | Should -Be 'present'
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '20.04'; kernelVersion = '5.15.0-1070-azure' }) | Should -Be 'unlisted'
        }
    }

    It 'no module is still absent, whatever the table says' {
        InModuleScope VmMigrationFactory {
            $out = [pscustomobject]@{ checks = @([pscustomobject]@{ name = 'mana module available'; status = 'WARN' }) }
            Get-VmfManaDriverPresence -GuestOutput $out -Os 'Linux' -Facts ([pscustomobject]@{ distroId = 'ubuntu'; distroVersion = '22.04'; kernelVersion = '5.15.0-1096-azure' }) | Should -Be 'absent'
        }
    }

    # AN-MANA-DRIVER-RULE-1: rewritten - never kept off now; stop and ask.
    It 'an unlisted release is handled exactly like no driver: stop and ask, on before or off' {
        InModuleScope VmMigrationFactory {
            $off = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan) -CapturedNics (Global:AnNics $false) -ManaDriver 'unlisted'
            $off.Policy | Should -Not -Be 'preserve'
            $off.Stop | Should -BeTrue
            $off.Detail | Should -Match 'Microsoft'
            $on = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry (Global:AnPlan -OnFloor 'stop') -CapturedNics (Global:AnNics $true) -ManaDriver 'unlisted'
            $on.Stop | Should -BeTrue
            $on.Detail | Should -Match 'Microsoft'
        }
    }

    It 'DRIVER-1 now judges Red Hat 9.8 against the 9.6 row instead of calling it unknown' {
        InModuleScope VmMigrationFactory {
            $v = Get-VmfDriverJudgement -Facts ([pscustomobject]@{ os = 'Linux'; distroId = 'rhel'; distroVersion = '9.8'; kernelVersion = '5.14.0-687.30.1.el9_8.x86_64'; fabric = 'mlx5' }) -TargetIsBoost $true
            $v.Status | Should -Be 'PASS'
        }
    }

    It 'the table carries the rows Microsoft added on 2026-09-25' {
        $floors = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json') -Raw | ConvertFrom-Json
        (@($floors.mana.linux.distros) | Where-Object { $_.id -eq 'ubuntu' -and $_.versionId -eq '26.04' }).minKernel | Should -Be '7.0.0-14.14'
        (@($floors.mana.linux.distros) | Where-Object { $_.kernelFlavor -eq 'uek' }).minKernel | Should -Be '6.12.0-100.28.2'
    }
}

Describe 'RHEL8-MANA-1: RUN the step that decides, for the lab''s Red Hat 8.10' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-r8-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'r8-test' | Out-Null }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            if ($ScriptName -eq 'mana-check.sh') {
                return [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'mana-check.sh'; version = '1.1.0'; os = 'Red Hat Enterprise Linux 8.10 (Ootpa)'
                    result = 'READY'; warnings = @()
                    checks = @([pscustomobject]@{ name = 'mana module available'; status = 'PASS'; detail = 'mana.ko.xz' })
                    facts = [pscustomobject]@{ os = 'Linux'; kernelVersion = '4.18.0-553.134.1.el8_10.x86_64'; distroId = 'rhel'; distroVersion = '8.10'; fabric = 'none' } }
            }
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = $ScriptName; version = '1'; os = 'Red Hat Enterprise Linux 8.10 (Ootpa)'
                result = 'READY'; warnings = @(); checks = @() }
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    # AN-MANA-DRIVER-RULE-1: rewritten. It went on with accelerated networking
    # kept off; now it stops and asks, before anything is touched, like a
    # machine with it on.
    It 'off before: it stops and asks, before anything is touched - never kept off' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:AnPlan) -RunPath $rp -RunId 'r8-test'
            New-VmfStateDoc -RunPath $rp -RunId 'r8-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:AnNics $false) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $saved = (Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId).captured.acceleratedNetworking
            $saved.manaDriver | Should -Be 'unlisted'
            $saved.policy | Should -Not -Be 'preserve'
        }
    }

    It 'on before: it stops and asks, before anything is touched' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:AnPlan -OnFloor 'stop') -RunPath $rp -RunId 'r8-test'
            New-VmfStateDoc -RunPath $rp -RunId 'r8-test' -VmId $ctx.VmId | Out-Null
            Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = @{ nics = (Global:AnNics $true) } }
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Detail | Should -Match 'Microsoft'
        }
    }
}
