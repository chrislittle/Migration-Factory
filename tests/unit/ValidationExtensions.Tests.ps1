#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # SQLVM-REREAD-1: Checking reads the SQL virtual machine resource before a rebuild; none here.
    # DCR-READ-1: Checking reads the data collection rule associations before a rebuild; none here.
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    function Script:NewVxPlan {
        param([string]$Os = 'Linux', [string]$Path = 'A', [string]$SourceArch = 'diskless',
              [string]$TargetArch = 'diskless', [hashtable]$Policy = @{})
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vx/providers/Microsoft.Compute/virtualMachines/vx-vm'
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{
                classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = $SourceArch; platformManaged = $false
            }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = $TargetArch; controller = 'NVMe' }
            path = $Path
            policy = [pscustomobject]$Policy
            # REBUILD-ACCEPT-1: a rebuild needs a person's acceptance that names
            # the machine and its extensions - the one the mocks read at PRECHECK.
            decisions = @(if ($Path -eq 'B') { [pscustomobject]@{ setting = 'rebuild'; by = 'approver@example.com'; utc = '2026-11-01T00:00:00Z'; extensions = @('MonitoringAgent') } })
        }
    }

    function Script:NewVxFakeVm {
        [pscustomobject]@{
            Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vx/providers/Microsoft.Compute/virtualMachines/vx-vm'
            Name = 'vx-vm'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{
                    OsType = 'Linux'; Name = 'vx-os'
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vx/providers/Microsoft.Compute/disks/vx-os'; StorageAccountType = 'Premium_LRS' }
                    DeleteOption = 'Delete'
                }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @() }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    function Script:VxEngineStep {
        # VERIFY-FP-FLAKY-1: the step the engine is in, read from the machine's
        # state document. A mock that answers differently before and after a
        # step asks THIS, never counts its own calls: the engine retries a
        # step that fails, and a retry repeats every call the step makes.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $d = Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-vx/providers/Microsoft.Compute/virtualMachines/vx-vm'
            if (-not $d) { throw 'VxEngineStep found no state document for vx-vm.' }
            [string]$d.state
        }
    }

    function Script:MockVxHappy {
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        # PERM-3: PRECHECK now asks Azure what this identity may do before it
        # touches anything. Without a mock these tests reach REAL ARM (they got
        # HTTP 404s), which unit tests must never do. A fully privileged identity
        # is the right default here - the refusal itself is covered in
        # PermissionPreflight.Tests.ps1.
        # LOCK-1: PRECHECK now reads resource locks before anything is touched.
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
            @([pscustomobject]@{ actions = @('*'); notActions = @() })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Script:NewVxFakeVm }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/snap/id' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/snap/id/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        # ROLLBACK-DISKS-FIRST-1: SAFETY_PRISTINE makes the disks for the way
        # back; a rollback reads them before its stop; a completed move deletes them.
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
    }

    function Script:MockVxRollback {
        # VALIDATION-EXT-TEST-1: every call a Path A rollback makes, so a
        # failure in VALIDATING ends FAILED_ROLLED_BACK and never on a
        # rollback that died on an unmocked call. The calls are recorded in
        # order, so a test can see the rollback really ran.
        $global:vxRollback = @{ calls = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:vxRollback.calls.Add("size:$Size$(if ($Controller) { "/$Controller" })") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:vxRollback.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:vxRollback.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { [pscustomobject]@{ serialConsoleLog = '' } }
    }
    function Script:MockVxLinuxGuest {
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS' }); warnings = @() } }
                default             { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
            }
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

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface' -ErrorAction SilentlyContinue
}

Describe 'Validation extensions (P3-3)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vx-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'vx-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'Path A: a captured extension that is missing fails validation, and the machine goes back (FAIL-1)' {
        # VALIDATION-EXT-TEST-1: FAIL-1 removed `validationFailure`; a failure
        # after the change always puts the machine back. This test used to ask
        # for 'hold' and mocked no rollback, so the rollback died on an unmocked
        # disk swap and the test passed on 'rollbackFailed'. Now every call the
        # rollback makes is mocked, and the twin test below runs the SAME mocks
        # with the extension present and ends MIGRATED - so the extension check
        # is the only thing that decides the outcome.
        Script:MockVxHappy
        Script:MockVxLinuxGuest
        Script:MockVxRollback
        # PRECHECK captures the extensions; VALIDATING finds one gone.
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions {
            if ((Script:VxEngineStep) -ne 'VALIDATING') {
                , @([ordered]@{ name = 'OmsAgentForLinux'; publisher = 'M'; type = 'T'; provisioningState = 'Succeeded' })
            }
            else { , @() }
        }
        $plan = Script:NewVxPlan
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'vx-test'
        }
        $last = @($final.history)[-1]
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $last.reasonCode | Should -Be 'validationFailedAfterConversion'
        $last.detail | Should -Match 'The check of the VM extensions failed'
        $last.detail | Should -Match 'OmsAgentForLinux'
        # The rollback really ran: the original size, then the disk made for
        # the way back, then a start.
        $global:vxRollback.calls -join ' > ' | Should -Match 'size:Standard_D2s_v6/NVMe > .*size:Standard_D2s_v4/SCSI > os:vx-os-asitwas-\d+ > start$'
    }

    It 'Path A: the same machine with the captured extension present is MIGRATED (the control for the test above)' {
        Script:MockVxHappy
        Script:MockVxLinuxGuest
        Script:MockVxRollback
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions {
            , @([ordered]@{ name = 'OmsAgentForLinux'; publisher = 'M'; type = 'T'; provisioningState = 'Succeeded' })
        }
        $plan = Script:NewVxPlan
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'vx-test'
        }
        $final.state | Should -Be 'MIGRATED'
        # The check was asked: VALIDATING read the extensions.
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfVmExtensions -Times 2 -Scope It
        @($global:vxRollback.calls | Where-Object { $_ -like 'os:*' }).Count | Should -Be 0
    }

    It 'Path A: a captured extension that is present but not Succeeded fails validation, and the machine goes back' {
        Script:MockVxHappy
        Script:MockVxLinuxGuest
        Script:MockVxRollback
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions {
            $ps = if ((Script:VxEngineStep) -ne 'VALIDATING') { 'Succeeded' } else { 'Failed' }
            , @([ordered]@{ name = 'OmsAgentForLinux'; publisher = 'M'; type = 'T'; provisioningState = $ps })
        }
        $plan = Script:NewVxPlan
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'vx-test'
        }
        $last = @($final.history)[-1]
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $last.reasonCode | Should -Be 'validationFailedAfterConversion'
        $last.detail | Should -Match 'Not in the Succeeded state: OmsAgentForLinux=Failed'
    }
    # REBUILD-REMOVE-ENGINE-1: no move rebuilds, so a missing extension never warns; the Path A tests above hold every move to it.
    It 'validation is about the MACHINE - no application check runs here' {
        # WAVE-2 lever 6 (ruled): the workload probe was REMOVED. The
        # tool validates what it changed; whether the app came back is checked
        # at sign-off, by the application team. This test exists so nobody quietly adds an
        # application gate back into the path where a failure rolls a healthy
        # machine back.
        Script:MockVxHappy
        Script:MockVxLinuxGuest
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        $plan = Script:NewVxPlan
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'vx-test'
        }
        $final.state | Should -Be 'MIGRATED'

        # VALIDATION-EXT-TEST-1: the module's CODE, never its comments - a
        # comment that explains the removal must not fail this, and a probe
        # put back in any engine file must.
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = (Get-ChildItem (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1' |
            ForEach-Object { Get-VmfCodeOnly -Path $_.FullName }) -join "`n"
        $code | Should -Not -BeNullOrEmpty
        $code | Should -Not -Match 'workloadProbe'
        Get-Command Test-VmfWorkloadProbe -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
    }
}
