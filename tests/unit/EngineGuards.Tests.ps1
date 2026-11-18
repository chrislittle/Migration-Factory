#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-M4, M5 and M6 - three guards that existed, ran, and let the thing they
# guarded against happen anyway.
#
# M4  The state machine has a 50-iteration backstop against handler loops. It
#     worked: it stopped the loop. It stopped it by falling out of the while
#     and returning the document unchanged - non-terminal state, no fail
#     transition, no event, no reason code. The worker exited 0, the wave
#     counted the machine as neither settled nor failed, and the lease expired
#     with nothing to resume because the document still looked mid-flight. The
#     one situation the guard exists for produced the quietest possible outcome.
#
# M5  The fused-sequence guard re-verified guest prep before deallocating -
#     but ONLY when the power state was exactly PowerState/running. Its own
#     comment justifies skipping for exactly one other state, "already
#     deallocated". The code applied that justification to stopped, starting,
#     stopping and unknown too. PowerState/starting is BY DEFINITION a machine
#     mid-SCSI-boot, which is precisely when Windows re-creates the stornvme
#     StartOverride key that prep removed - so the one state most likely to
#     have regressed was the one that skipped the check.
#
# M6  Test-VmfAdeExtension read the extension with -ErrorAction SilentlyContinue
#     and returned $false on anything that was not a success. A throttle, a 5xx
#     or a reset socket was therefore indistinguishable from "not installed",
#     and because nothing threw, the azureops retry wrapper never saw it. This
#     is the only ADE detection in the product, and encryption is a hard
#     blocker for NVMe, so a transient failure let an encrypted machine through
#     a gate the code calls a hard stop - the truth arriving at STARTING, after
#     the deallocate and the convert.
BeforeAll {
    # A run path under TEMP, never a relative one. `RunPath = 'x'` here wrote
    # `./x/logs/events.jsonl` into whatever directory the runner started in -
    # the repository - and that litter was committed by accident (99da035).
    $script:scratch = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-scratch-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    New-Item -ItemType Directory -Path $script:scratch -Force | Out-Null
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Get-AzVMExtension { param($ResourceGroupName, $VMName, $Name) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw

    # Everything PRECHECK asks Azure, answered "fine", so a test can reach the
    # one gate it is about.
    function Script:MockPrecheckClear {
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { & $Operation }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfMissingActions { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfLockVerdict { @{ Blocked = $false; Detail = $null } }
    }

    # A REAL loop the engine can enter: for a Windows NVMe target, GUEST_PREP
    # ends by returning STOPPED, and STOPPED re-verifies the guest and returns
    # to GUEST_PREP when it is not READY. A guest that never becomes READY -
    # a fixer that reports success and a checker that keeps saying no, which is
    # exactly what a half-applied StartOverride fix looks like - is therefore a
    # genuine non-terminating cycle, driven here through the real handlers.
    function Script:MockNeverReadyGuest {
        Script:MockPrecheckClear
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Get-VmfDriverJudgement { @{ Status = 'UNKNOWN'; Detail = 'not measured in this test' } }
        Mock -ModuleName VmMigrationFactory Save-VmfCapturedFacts { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'Test-ManaReady.ps1' { [pscustomobject]@{ result = 'READY'; checks = @(); warnings = @() } }
                'Test-NvmeReady.ps1' { [pscustomobject]@{ result = 'NOT_READY'; checks = @(); warnings = @() } }
                'Set-NvmeReady.ps1'  { [pscustomobject]@{ result = 'CHANGED'; checks = @(); warnings = @() } }
                # MANA-WIN-1: the driver store already has MANA.
                'Install-ManaDriver.ps1' { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                default              { [pscustomobject]@{ result = 'OK'; checks = @(); warnings = @() } }
            }
        }
    }

    function Script:NewPlanEntry {
        param([string]$Os = 'Linux', [string]$Path = 'A', [hashtable]$Policy = @{})
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
            wave = 'w1'
            assessment = [pscustomobject]@{
                classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false
            }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = $Path
            policy = [pscustomobject]$Policy
        }
    }
    # ENGINE-SUB-1: these fixtures build machines in 00000000-0000-0000-0000-000000000000.
    # Pin the engine to the same subscription so the cross-subscription
    # guard is not the thing under test here - EngineSubscription.Tests.ps1
    # is where that behaviour is asserted.
    Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
    # ENGINE-SUB-1: the state machine now points the PROCESS at each machine's
    # own subscription before doing anything. These fixtures use an invented
    # subscription id, so the switch has to be mocked - these tests are about
    # what the engine DOES, not about whether Azure has heard of the id.
    # EngineSubscription.Tests.ps1 and the cross-subscription lab drill are
    # where the switch itself is proved.
    Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
    Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
}

# ONE top-level AfterAll. A second one REPLACES the first in Pester 5 rather
# than adding to it, so the scratch directory added here on 2026-09-01 was
# never removed - 19 of them accumulated in TEMP before anybody noticed. The
# same shape as the `x/` litter, moved somewhere nobody looks.
AfterAll {
    Remove-Item 'function:\Get-AzVMExtension' -ErrorAction SilentlyContinue
    if ($script:scratch -and (Test-Path $script:scratch)) { Remove-Item $script:scratch -Recurse -Force }
}

Describe 'EVAL-M6: the encryption check can say "I could not tell"' {
    # ADE-DETECT-ANY-NAME-1: Test-VmfAdeExtension no longer asks Azure by two
    # fixed names. It reads the list Checking already read, by publisher and
    # type; the read itself carries the unknown (extensionsNotRead), and each
    # disk's own setting is the second signal (AdeDetectAnyName.Tests.ps1).
    It 'returns TRUE when the extension is there and succeeded' {
        InModuleScope VmMigrationFactory {
            $x = @([ordered]@{ name = 'AzureDiskEncryption'; publisher = 'Microsoft.Azure.Security'; type = 'AzureDiskEncryption'; provisioningState = 'Succeeded' })
            Test-VmfAdeExtension -Extensions $x | Should -BeTrue
        }
    }

    It 'returns FALSE when the list Azure returned has no such extension' {
        InModuleScope VmMigrationFactory {
            $x = @([ordered]@{ name = 'AzureMonitorWindowsAgent'; publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorWindowsAgent'; provisioningState = 'Succeeded' })
            Test-VmfAdeExtension -Extensions $x | Should -BeFalse
        }
    }

    It 'a list Azure could not return is a stop, never "not installed"' {
        # The defect: this used to be indistinguishable from "not installed".
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:scratch } {
            param($rp)
            Mock Invoke-VmfAzOperation { & $Operation }
            Mock Get-VmfVmExtensions { throw 'Operation returned an invalid status code: TooManyRequests' }
            $r = Read-VmfPrecheckExtensions -Context @{ RunPath = $rp; VmId = 'vm1'; Rg = 'rg'; VmName = 'vm1' }
            $r.Stop | Should -Not -BeNullOrEmpty -Because 'unknown must be its own answer, not $false'
            $r.Stop.Reason | Should -Be 'extensionsNotRead'
            $null -eq $r.Extensions | Should -BeTrue
        }
    }

    It 'a real answer from either extension still wins among the others' {
        InModuleScope VmMigrationFactory {
            $x = @(
                [ordered]@{ name = 'monitor'; publisher = 'Microsoft.Azure.Monitor'; type = 'AzureMonitorLinuxAgent'; provisioningState = 'Failed' }
                [ordered]@{ name = 'AzureDiskEncryptionForLinux'; publisher = 'Microsoft.Azure.Security'; type = 'AzureDiskEncryptionForLinux'; provisioningState = 'Succeeded' }
            )
            Test-VmfAdeExtension -Extensions $x | Should -BeTrue
        }
    }
}

Describe 'EVAL-M6: an unknown answer parks the machine rather than guessing' {
    # ADE-DETECT-ANY-NAME-1: PRECHECK reaches these stops from the extension
    # list and each disk's read; AdeDetectAnyName.Tests.ps1 drives the step.
    It 'the unknown stop is diskEncryptionUnknown, and the machine is untouched' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAdeStop -Found $null -UnknownSay "the data disk 'vm1-data0' on LUN 0"
            $r.Next | Should -Be 'NEEDS_DECISION'
            $r.Reason | Should -Be 'diskEncryptionUnknown'
            $r.MachineState | Should -Be 'untouched' -Because 'PRECHECK cannot have changed anything'
            $r.Detail | Should -Match "vm1-data0" -Because 'the stop names the disk'
        }
    }

    It 'TERMS-AUDIT-1 review: the unknown line names no NVMe controller, so it is true for an in-place upgrade (Preview) to v5 on SCSI' {
        # The check runs for an NVMe move AND for the in-place upgrade (Preview).
        # The line said "not compatible with the NVMe disk controller of the new
        # size", which is false for a move to a v5 size on SCSI.
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAdeStop -Found $null -UnknownSay "the OS disk 'vm1-os'"
            $r.Detail | Should -Not -Match 'NVMe'
            $r.Detail | Should -Match 'v6 or v7 size'
            # REBUILD-REMOVE-PLAN-1: no new move is a rebuild; the line names the move the
            # product does not make with encryption, the in-place upgrade (Preview).
            $r.Detail | Should -Match 'in-place upgrade \(Preview\)'
        }
    }

    It 'and the stop is one an operator can act on' {
        InModuleScope VmMigrationFactory {
            $g = Get-VmfStopGuidance -Code 'diskEncryptionUnknown'
            $g | Should -Not -BeNullOrEmpty
            $g.whatToDo | Should -Match '(?i)portal|see whether'
            $g.machine | Should -Be 'untouched'
        }
    }

    It 'a definite YES still parks on the original code, with the original words' {
        InModuleScope VmMigrationFactory {
            $r = Get-VmfAdeStop -Found $true
            $r.Reason | Should -Be 'diskEncryptionPresent'
            $r.Detail | Should -Be 'Azure Disk Encryption is enabled on this machine.'
        }
    }
}

Describe 'EVAL-M5: only a deallocated machine skips the pre-deallocate re-verify' {
    It 'the guard tests for deallocated, not for running' {
        $fn = [regex]::Match($script:sm, '(?s)function Invoke-VmfStepStopped.*?\r?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match "\`$power -ne 'PowerState/deallocated'"
        $fn | Should -Not -Match "\`$power -eq 'PowerState/running'" `
            -Because 'every non-deallocated state may have booted since prep'
    }

    It 'a machine caught mid-boot IS re-verified - the case that used to convert blind' {
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/starting' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            [pscustomobject]@{ result = 'NOT_READY'; checks = @(); warnings = @() }
        }
        $plan = Script:NewPlanEntry -Os 'Windows'
        $ctx = [pscustomobject]@{ Plan = $plan; Rg = 'rg-lab'; VmName = 'vm-under-test'
                                  VmId = $plan.vmId; RunPath = $script:scratch }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { Invoke-VmfStepStopped -Context $c }
        $r.Next | Should -Be 'GUEST_PREP' -Because 'a machine that has booted since prep has lost its StartOverride fix'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 1 -Exactly
    }

    It 'a running machine is re-verified, as it always was' {
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            [pscustomobject]@{ result = 'NOT_READY'; checks = @(); warnings = @() }
        }
        $plan = Script:NewPlanEntry -Os 'Windows'
        $ctx = [pscustomobject]@{ Plan = $plan; Rg = 'rg-lab'; VmName = 'vm-under-test'
                                  VmId = $plan.vmId; RunPath = $script:scratch }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { Invoke-VmfStepStopped -Context $c }
        $r.Next | Should -Be 'GUEST_PREP'
    }

    It 'an already-deallocated machine skips it and proceeds - prep was flushed pre-shutdown' {
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw 'must not be called' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { & $Operation }
        $plan = Script:NewPlanEntry -Os 'Windows'
        $ctx = [pscustomobject]@{ Plan = $plan; Rg = 'rg-lab'; VmName = 'vm-under-test'
                                  VmId = $plan.vmId; RunPath = $script:scratch }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { Invoke-VmfStepStopped -Context $c }
        $r.Next | Should -Be 'SAFETY_COPY'
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0 -Exactly
    }

    It 'a Linux machine is not asked at all - this is a Windows registry problem' {
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { throw 'must not be called' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { & $Operation }
        $plan = Script:NewPlanEntry -Os 'Linux'
        $ctx = [pscustomobject]@{ Plan = $plan; Rg = 'rg-lab'; VmName = 'vm-under-test'
                                  VmId = $plan.vmId; RunPath = $script:scratch }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { Invoke-VmfStepStopped -Context $c }
        $r.Next | Should -Be 'SAFETY_COPY'
    }
}

Describe 'EVAL-M4: a machine that never settles is stopped LOUDLY' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-loop-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
        # Start the machine AT the cycle rather than walking the whole of
        # PRECHECK to reach it - the loop is what is under test, and a resumed
        # worker legitimately begins from a checkpointed state like this.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $script:vmId } {
            Initialize-VmfRun -RunPath $rp -RunId 'loop-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'loop-test' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'GUEST_PREP' -Outcome ok -Detail 'seeded' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'ends in a terminal state instead of falling out of the loop mid-flight' {
        # Driven through the real handlers, not a stubbed one: this is the
        # engine's own GUEST_PREP <-> STOPPED cycle.
        Script:MockNeverReadyGuest
        $plan = Script:NewPlanEntry -Os 'Windows'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'loop-test'
        }

        $terminal = InModuleScope VmMigrationFactory { (Get-VmfEngineStates).Terminal }
        $doc.state | Should -BeIn $terminal -Because 'a non-terminal return is a machine nothing will ever pick up again'
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
    }

    It 'names the reason, and the reason has guidance behind it' {
        Script:MockNeverReadyGuest
        $plan = Script:NewPlanEntry -Os 'Windows'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'loop-test'
        }
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'stepLoopLimit'
        $last.outcome | Should -Be 'fail'
        InModuleScope VmMigrationFactory { (Get-VmfStopGuidance -Code 'stepLoopLimit') } |
            Should -Not -BeNullOrEmpty
    }

    It 'says it plainly, and does not blame the machine' {
        Script:MockNeverReadyGuest
        $plan = Script:NewPlanEntry -Os 'Windows'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'loop-test'
        }
        @($doc.history)[-1].detail | Should -Match 'never finishing|without ever finishing'
        @($doc.history)[-1].detail | Should -Match 'fault in the product'
    }

    It 'writes an event, so the run log shows it too' {
        Script:MockNeverReadyGuest
        $plan = Script:NewPlanEntry -Os 'Windows'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'loop-test' | Out-Null
        }
        $fails = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            @(Read-VmfEvents -RunPath $rp | Where-Object { $_.outcome -eq 'fail' })
        }
        @($fails).Count | Should -BeGreaterThan 0
    }

    It 'the limit is declared once, not spelled out in three places' {
        InModuleScope VmMigrationFactory { $script:VmfStateLoopLimit } | Should -Be 50
        $body = [regex]::Match($script:sm, '(?s)function Invoke-VmfStateMachine.*').Value
        $body | Should -Match '\$safetyLimit = \$script:VmfStateLoopLimit'
    }
}

Describe 'LINUX-TRANSIENT-1: a stop step run again after a failed deallocate checks the guest again first' {
    # In the lab a socket error at the stop step was not tried again, and the
    # WHOLE step ran a second time. That is safe only if the second run asks
    # the guest again before it deallocates: the step holds no checkpoint that
    # lets it skip the check.
    It 'each deallocate comes after its own check of the guest' {
        $global:VmfLtOrder = [System.Collections.Generic.List[string]]::new()
        try {
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
            Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation { & $Operation }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                $global:VmfLtOrder.Add("check:$ScriptName")
                [pscustomobject]@{ result = 'READY'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
                $global:VmfLtOrder.Add('deallocate')
                if (@($global:VmfLtOrder | Where-Object { $_ -eq 'deallocate' }).Count -eq 1) {
                    throw 'Unable to read data from the transport connection: the request ended.'
                }
            }
            $plan = Script:NewPlanEntry -Os 'Windows'
            $ctx = [pscustomobject]@{ Plan = $plan; Rg = 'rg-lab'; VmName = 'vm-under-test'
                                      VmId = $plan.vmId; RunPath = $script:scratch }
            { InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { Invoke-VmfStepStopped -Context $c } } | Should -Throw
            $r = InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { Invoke-VmfStepStopped -Context $c }
            $r.Next | Should -Be 'SAFETY_COPY'
            @($global:VmfLtOrder) | Should -Be @('check:Test-NvmeReady.ps1', 'deallocate', 'check:Test-NvmeReady.ps1', 'deallocate') `
                -Because 'a step run again must never deallocate without the fused sequence guard'
        }
        finally { Remove-Variable -Name VmfLtOrder -Scope Global -ErrorAction SilentlyContinue }
    }
}
