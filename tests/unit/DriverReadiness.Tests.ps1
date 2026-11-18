#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DRIVER-1: must the product update or validate the MANA or Mellanox driver
# version in any OS for a move to be safe?
#
# The follow-up question: does the product actually KNOW the right versions?
# Researched rather than guessed (sources recorded in data/driver-floors.json):
#
#   MANA on Linux    Microsoft publishes a per-distribution minimum kernel
#                    table. That is a real floor and it is copied verbatim.
#   MANA on Windows  NO published minimum driver version exists. The guidance
#                    is "in-box driver, keep updates applied". So the version
#                    is recorded as a FACT and never judged against a number
#                    this tool made up.
#   Mellanox         NO version floor exists at all. The published rule is
#                    "any endorsed distro the vendor has not marked EOL",
#                    which is a SUPPORT question IMAGE-1 already answers.
#
# The rule throughout: never invent a floor, and never turn "unknown" into a
# pass or a fail. The gate that actually protects a machine stays behavioural -
# VALIDATING requires the accelerated adapter bound and healthy after the move.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
}

Describe 'DRIVER-1: the floors are sourced data, not invented numbers' {
    BeforeAll {
        $script:floors = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'driver-floors.json') -Raw | ConvertFrom-Json
    }

    It 'every floor carries a source and a date it was retrieved' {
        @($script:floors.sources).Count | Should -BeGreaterThan 0
        # The floors are Microsoft's. ORACLE-UEK7-KERNEL-STOP-1: the only other
        # source is Oracle's own documentation, for where UEK R8 comes from
        # (mana.linux.uekR8), and it names no floor.
        $oracle = @($script:floors.mana.linux.uekR8.sources)
        # KERNEL-OFFER-EDGES-1: the kernel series a release's repositories give,
        # and SUSE's kernel-azure numbers, come from Debian and SUSE themselves
        # (mana.linux.updateCannotReach); they name no floor either.
        $reach = $script:floors.mana.linux.updateCannotReach
        $vendor = @(@($reach.releases) + @($reach.flavours) | ForEach-Object { @($_.sources) })
        foreach ($s in @($script:floors.sources)) {
            if ($oracle -contains $s.url) { $s.url | Should -Match '^https://docs\.oracle\.com/' }
            elseif ($vendor -contains $s.url) { $s.url | Should -Match '^https://(packages\.debian\.org|backports\.debian\.org|ftp\.suse\.com)/' }
            else { $s.url | Should -Match '^https://learn\.microsoft\.com/' }
            $s.retrievedUtc | Should -Not -BeNullOrEmpty
        }
        $script:floors.updatedUtc | Should -Not -BeNullOrEmpty
    }

    It 'records NO floor where Microsoft publishes none' {
        # This is the point of the whole item: the absence is deliberate and
        # explained, so nobody later "fills in the gap" with a guess.
        $script:floors.mana.windows.minDriverVersion | Should -BeNullOrEmpty
        $script:floors.mana.windows.note | Should -Match '(?i)no minimum'
        $script:floors.mellanox.minDriverVersion | Should -BeNullOrEmpty
        $script:floors.mellanox.note | Should -Match '(?i)no version floor'
    }

    It 'carries the published per-distribution kernel floors' {
        $ubuntu2204 = @($script:floors.mana.linux.distros) | Where-Object { $_.id -eq 'ubuntu' -and $_.versionId -eq '22.04' }
        $ubuntu2204.minKernel | Should -Be '5.15.0-1096.105'
        $rhel96 = @($script:floors.mana.linux.distros) | Where-Object { $_.id -eq 'rhel' -and $_.versionId -eq '9.6' }
        $rhel96.minKernel | Should -Be '5.14.0-570.52.1'
        @($script:floors.mana.linux.distros).Count | Should -BeGreaterThan 15
    }
}

Describe 'DRIVER-1: comparing kernel versions without lying' {
    It 'compares the ordinary case' {
        InModuleScope VmMigrationFactory {
            Compare-VmfKernelVersion -Running '5.15.0-1139' -Floor '5.15.0-1096.105' | Should -Be 1
            Compare-VmfKernelVersion -Running '5.15.0-1000' -Floor '5.15.0-1096.105' | Should -Be -1
            Compare-VmfKernelVersion -Running '5.15.0-1096.105' -Floor '5.15.0-1096.105' | Should -Be 0
        }
    }

    It 'ignores the noise distributions add around the numbers' {
        InModuleScope VmMigrationFactory {
            # Ubuntu appends -azure/-generic; Red Hat prefixes kernel- and
            # suffixes .el9_6. Neither changes the ordering.
            Compare-VmfKernelVersion -Running '5.15.0-1139-azure' -Floor '5.15.0-1096.105' | Should -Be 1
            Compare-VmfKernelVersion -Running '5.14.0-570.60.1.el9_6' -Floor 'kernel-5.14.0-570.52.1.el9_6' | Should -Be 1
            Compare-VmfKernelVersion -Running '5.14.0-570.12.1.el9_6' -Floor 'kernel-5.14.0-570.52.1.el9_6' | Should -Be -1
        }
    }

    It 'compares numerically, not as text' {
        InModuleScope VmMigrationFactory {
            # '9' vs '10' as strings would order the wrong way round
            Compare-VmfKernelVersion -Running '6.10.0' -Floor '6.9.0' | Should -Be 1
        }
    }

    It 'returns UNKNOWN rather than a wrong answer when it cannot tell' {
        InModuleScope VmMigrationFactory {
            Compare-VmfKernelVersion -Running '' -Floor '5.15.0' | Should -BeNullOrEmpty
            Compare-VmfKernelVersion -Running 'not-a-version' -Floor '5.15.0' | Should -BeNullOrEmpty
            Compare-VmfKernelVersion -Running '5.15.0' -Floor $null | Should -BeNullOrEmpty
        }
    }
}

Describe 'DRIVER-1: judging what the guest reported' {
    It 'passes a Linux machine at or above its published floor' {
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{
                fabric = 'mana'; os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'
                kernelVersion = '5.15.0-1139-azure'
            }
            $r = Get-VmfDriverJudgement -Facts $facts
            $r.Status | Should -Be 'PASS'
            $r.Detail | Should -Match '5.15.0-1096.105'
        }
    }

    It 'FAILS a Linux machine below its published floor, quoting both versions' {
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{
                fabric = 'mana'; os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'
                kernelVersion = '5.15.0-1020-azure'
            }
            $r = Get-VmfDriverJudgement -Facts $facts
            $r.Status | Should -Be 'FAIL'
            $r.Detail | Should -Match '5.15.0-1020'
            $r.Detail | Should -Match '5.15.0-1096.105'
        }
    }

    It 'a distribution absent from the table is UNKNOWN, never a failure' {
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{
                fabric = 'mana'; os = 'Linux'; distroId = 'gentoo'; distroVersion = '2.17'
                kernelVersion = '6.1.0'
            }
            $r = Get-VmfDriverJudgement -Facts $facts
            $r.Status | Should -Be 'UNKNOWN'
            $r.Detail | Should -Match '(?i)not listed|no published'
        }
    }

    It 'Windows MANA reports the driver version as a fact and judges nothing' {
        # Microsoft publishes no floor. Inventing one would be the failure.
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{ fabric = 'mana'; os = 'Windows'; driverVersion = '1.0.2.0' }
            $r = Get-VmfDriverJudgement -Facts $facts
            $r.Status | Should -Be 'INFO'
            $r.Detail | Should -Match '1\.0\.2\.0'
        }
    }

    It 'and it still does when os is the CAPTION the guest really sends' {
        # THE bug the UPST-2 drill found, and the reason this test exists in
        # this shape. The Windows guest emitted no `fact:os`, so the engine fell
        # back to the OS caption - and the check was an EXACT match against
        # 'Windows'. Every Windows machine was therefore judged against the
        # MANA-on-Linux kernel floor, found no kernel, and reported UNKNOWN.
        #
        # The old test passed because it asserted the idealised value the code
        # wanted rather than the string a machine actually sends. That is the
        # third time this session a test has encoded the same wrong assumption
        # as the code it was checking, so this one uses the caption observed on
        # a real machine.
        InModuleScope VmMigrationFactory {
            foreach ($caption in @(
                'Microsoft Windows Server 2022 Datacenter (10.0.20348)',
                'Microsoft Windows Server 2019 Datacenter (10.0.17763)',
                'Windows'
            )) {
                $facts = [pscustomobject]@{ fabric = 'mana'; os = $caption; driverVersion = '1.0.2.0' }
                $r = Get-VmfDriverJudgement -Facts $facts -TargetIsBoost $true
                $r.Status | Should -Be 'INFO' -Because "'$caption' is a Windows machine"
                $r.Status | Should -Not -Be 'UNKNOWN'
            }
        }
    }

    It 'a Windows machine with NO kernel fact never falls into the Linux floor check' {
        # The symptom as it actually appeared in the run log:
        #   driverCheck info UNKNOWN: the machine did not report its kernel version
        # A Windows machine has no kernel version and must never be asked for one.
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{ fabric = 'mana'; os = 'Microsoft Windows Server 2022 Datacenter (10.0.20348)' }
            $r = Get-VmfDriverJudgement -Facts $facts -TargetIsBoost $true
            $r.Detail | Should -Not -Match 'kernel version'
        }
    }

    It 'the guests SAY which OS they are, so the engine never has to infer it' {
        $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        (Get-Content (Join-Path $root 'src' 'guest' 'windows' 'Test-ManaReady.ps1') -Raw) |
            Should -Match "Add-Fact 'os' 'Windows'"
        (Get-Content (Join-Path $root 'src' 'guest' 'linux' 'mana-check.sh') -Raw) |
            Should -Match 'add_fact "os" "Linux"'
    }

    It 'a machine STAYING on Mellanox is INFO - the support question belongs to IMAGE-1' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfDriverJudgement -TargetIsBoost $false -Facts ([pscustomobject]@{ fabric = 'mlx5'; os = 'Linux'; kernelVersion = '5.15.0-1139' })
            $r.Status | Should -Be 'INFO'
            $r.Detail | Should -Match '(?i)Microsoft publishes no minimum driver version'
        }
    }

    It 'a machine with no accelerated fabric, and not heading to Boost, is reported plainly' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfDriverJudgement -TargetIsBoost $false -Facts ([pscustomobject]@{ fabric = 'none'; os = 'Linux' })
            $r.Status | Should -Be 'INFO'
            $r.Detail | Should -Match '(?i)no accelerated'
        }
    }

    It 'DRILL REGRESSION: judges the fabric the machine is MOVING TO, not the one it has' {
        # Found by the DRIVER-1 drill, which is the only way this could have
        # been found: before migration a v4 machine sits on MELLANOX, so
        # judging its CURRENT fabric answered "Mellanox has no floor" and
        # waved a below-floor kernel straight through. The machine then
        # migrated and failed validation post-move with MANA unbound - exactly
        # the outcome this check exists to predict.
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{
                fabric = 'mlx5'          # what it runs TODAY, on v4 hardware
                os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'
                kernelVersion = '5.15.0-1008-azure'   # the real kernel from the drill
            }
            $r = Get-VmfDriverJudgement -Facts $facts -TargetIsBoost $true
            $r.Status | Should -Be 'FAIL' -Because 'it is heading for MANA hardware whatever it runs now'
            $r.Detail | Should -Match '5.15.0-1096.105'
            $r.Detail | Should -Match '(?i)Microsoft Azure Network Adapter'
        }
    }

    It 'the same machine is NOT failed when it is not going to Boost' {
        InModuleScope VmMigrationFactory {
            $facts = [pscustomobject]@{
                fabric = 'mlx5'; os = 'Linux'; distroId = 'ubuntu'; distroVersion = '22.04'
                kernelVersion = '5.15.0-1008-azure'
            }
            (Get-VmfDriverJudgement -Facts $facts -TargetIsBoost $false).Status | Should -Be 'INFO'
        }
    }

    It 'reports UNKNOWN when the guest told us nothing' {
        InModuleScope VmMigrationFactory {
            (Get-VmfDriverJudgement -Facts $null).Status | Should -Be 'UNKNOWN'
        }
    }
}

Describe 'DRIVER-1: the guests report structured facts, not prose' {
    # CLAUDE.md: guests report facts, the ENGINE judges. A version buried in a
    # sentence cannot be compared to anything.
    It 'the Linux MANA check emits kernel, distro and driver as their own fields' {
        $sh = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'mana-check.sh') -Raw
        foreach ($field in 'kernelVersion', 'distroId', 'distroVersion', 'fabric', 'driverVersion') {
            $sh | Should -Match ([regex]::Escape($field)) -Because "the engine needs '$field' as a field"
        }
    }

    It 'the Linux check looks for Mellanox as well as MANA' {
        $sh = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'mana-check.sh') -Raw
        $sh | Should -Match 'mlx5'
    }

    It 'the Linux check proves traffic is really on the accelerated path' {
        # Microsoft's own verification: if the VF counters are zero or do not
        # move, the machine is not actually using accelerated networking - which
        # "driver is present" would never reveal.
        $sh = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'linux' 'mana-check.sh') -Raw
        $sh | Should -Match 'vf_rx_packets|vf_tx_packets'
    }

    It 'the Windows MANA check emits the driver version as its own field' {
        $ps = Get-Content (Join-Path $script:repoRoot 'src' 'guest' 'windows' 'Test-ManaReady.ps1') -Raw
        $ps | Should -Match 'driverVersion'
        $ps | Should -Match 'fabric'
    }
}

Describe 'DRIVER-1: the check actually runs, before the machine is stopped' {
    # GUEST_PREP is the last state before SAFETY_COPY and STOPPED, so parking
    # here costs nothing: the machine is still running and untouched.
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-drv-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'drv-test' | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    function Global:DrvGuestOut {
        param([string]$Kernel)
        [pscustomobject]@{
            schema = 'vmf.guest/2'; script = 'mana-check.sh'; version = '1.1.0'
            os = 'Ubuntu 22.04'; result = 'READY'; warnings = @()
            checks = @(
                [pscustomobject]@{ name = 'fact:kernelVersion'; status = 'INFO'; detail = $Kernel }
                [pscustomobject]@{ name = 'fact:distroId'; status = 'INFO'; detail = 'ubuntu' }
                [pscustomobject]@{ name = 'fact:distroVersion'; status = 'INFO'; detail = '22.04' }
                [pscustomobject]@{ name = 'fact:fabric'; status = 'INFO'; detail = 'mana' }
            )
        }
    }

    function Global:DrvPlan {
        param([string]$Policy = 'stop')
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/drvvm'
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = 'Linux'
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'
            policy = [pscustomobject]@{ onDriverBelowFloor = $Policy }
        }
    }

    It 'PARKS a machine whose kernel is below the published floor - untouched' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { Global:DrvGuestOut -Kernel '5.15.0-1020-azure' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:DrvPlan 'stop') -RunPath $rp -RunId 'drv-test'
            New-VmfStateDoc -RunPath $rp -RunId 'drv-test' -VmId $ctx.VmId | Out-Null
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Detail | Should -Match '5.15.0-1096.105'
            # RETRY-1 split these apart: the engine states the FACT for this
            # machine (which kernel, which floor), and the stop reason carries
            # what it means and that nothing was changed - said once, in one
            # place, instead of three times over in the detail string.
            $r.Reason | Should -Be 'driverBelowFloor'
            (Get-VmfStopGuidance -Code $r.Reason).machine | Should -Be 'untouched'
            # ROLLBACK-RETRY-CAPTURE-1's review: and the step SAYS so. Without it the
            # state machine recorded this guest step's default, 'changed', and the
            # engine refused the retry and the decision of an untouched machine.
            $r.MachineState | Should -Be 'untouched'
        }
    }

    It 'AN-PROCEED-NETVSC-1: parks it as well where an earlier plan says Continue - nobody accepts a network that does not work' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { Global:DrvGuestOut -Kernel '5.15.0-1020-azure' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:DrvPlan 'proceed') -RunPath $rp -RunId 'drv-test'
            New-VmfStateDoc -RunPath $rp -RunId 'drv-test' -VmId $ctx.VmId | Out-Null
            # Since 2026-11-06, a move is not allowed if the network will not
            # work with AN. A plan saved before the ruling can still hold
            # 'proceed'; the machine parks untouched all the same.
            $r = Invoke-VmfStepGuestPrep -Context $ctx
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'driverBelowFloor'
            $r.MachineState | Should -Be 'untouched'
        }
    }

    It 'does NOT park on a kernel that meets the floor' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { Global:DrvGuestOut -Kernel '5.15.0-1139-azure' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:DrvPlan 'stop') -RunPath $rp -RunId 'drv-test'
            New-VmfStateDoc -RunPath $rp -RunId 'drv-test' -VmId $ctx.VmId | Out-Null
            # SAFETY-2: guest prep now hands STRAIGHT to the stop, with the
            # safety copy taken after it - the fused rule got stricter, not
            # looser. The intent here is unchanged: it must not park.
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
        }
    }

    It 'never parks on UNKNOWN - missing information must not block a machine' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'mana-check.sh'; version = '1.1.0'
                os = 'Whatever'; result = 'READY'; warnings = @(); checks = @() }
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:DrvPlan 'stop') -RunPath $rp -RunId 'drv-test'
            New-VmfStateDoc -RunPath $rp -RunId 'drv-test' -VmId $ctx.VmId | Out-Null
            # SAFETY-2: guest prep now hands STRAIGHT to the stop, with the
            # safety copy taken after it - the fused rule got stricter, not
            # looser. The intent here is unchanged: it must not park.
            (Invoke-VmfStepGuestPrep -Context $ctx).Next | Should -Be 'STOPPED'
        }
    }

    It 'records the verdict on the machine, whatever it was' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { Global:DrvGuestOut -Kernel '5.15.0-1139-azure' }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $ctx = New-VmfContext -PlanEntry (Global:DrvPlan 'stop') -RunPath $rp -RunId 'drv-test'
            New-VmfStateDoc -RunPath $rp -RunId 'drv-test' -VmId $ctx.VmId | Out-Null
            Invoke-VmfStepGuestPrep -Context $ctx | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $ctx.VmId
            $doc.captured.driver.status | Should -Be 'PASS'
            $doc.captured.driver.facts.kernelVersion | Should -Be '5.15.0-1139-azure'
            $events = Read-VmfEvents -RunPath $rp
            ($events | Where-Object { $_.step -eq 'driverCheck' }) | Should -Not -BeNullOrEmpty
        }
    }
}
