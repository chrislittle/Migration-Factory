#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az stubs: functions shadow cmdlets, so these win over any installed Az.Compute
    # (which would otherwise impose typed parameter binding on mocked calls).
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Update-AzVM { param($ResourceGroupName, $VM) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # SQLVM-REREAD-1: Checking reads the SQL virtual machine resource before a rebuild; none here.
    # DCR-READ-1: Checking reads the data collection rule associations before a rebuild; none here.

    function Script:NewPlanEntry {
        param(
            [string]$Os = 'Linux',
            [string]$Path = 'A',
            [string]$SourceArch = 'diskless',
            [string]$TargetArch = 'diskless',
            [hashtable]$Policy = @{}
        )
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{
                classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = $SourceArch
                platformManaged = $false
            }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = $TargetArch; controller = 'NVMe' }
            path = $Path
            policy = [pscustomobject]$Policy
            # REBUILD-ACCEPT-1: every rebuild needs a person's acceptance that
            # names the machine and its extensions (none here: the mocks read
            # none). These tests are about the steps after PRECHECK.
            decisions = @(if ($Path -eq 'B') { [pscustomobject]@{ setting = 'rebuild'; by = 'approver@example.com'; utc = '2026-11-01T00:00:00Z'; extensions = @() } })
        }
    }

    function Script:NewFakeAzVm {
        [pscustomobject]@{
            Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
            Name = 'vm-under-test'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{
                    OsType = 'Linux'; Name = 'vm-os'
                    # DISK-TYPE-DEALLOCATED-1: the model of a running machine gives
                    # the type; PRECHECK refuses a disk with none.
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; StorageAccountType = 'Premium_LRS' }
                    DeleteOption = 'Delete'
                }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    function Script:EngineStep {
        # VERIFY-FP-FLAKY-1: the step the engine is in, read from the machine's
        # state document. A mock that answers differently before and after a
        # step must ask THIS, never count its own calls: the engine retries a
        # step that fails, and a retry repeats every call the step makes, so a
        # count moves every later answer by one.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $d = Read-VmfStateDoc -RunPath $rp -VmId '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
            # No document means the helper read the wrong machine - say so,
            # rather than answer as if the move had not started.
            if (-not $d) { throw 'EngineStep found no state document for vm-under-test.' }
            [string]$d.state
        }
    }

    function Script:MockHappyAzureOps {
        # Baseline mocks for a clean end-to-end run; individual tests override.
        # CLUSTER-DETECT-1: the cluster check at Checking finds no cluster node
        # here - ClusterDetect.Tests.ps1 and the tests below that pass
        # -RealClusterCheck are where it is under test.
        param([switch]$RealClusterCheck)
        if (-not $RealClusterCheck) { Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null } }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        # OLD-FAM-1: PRECHECK asks what the source size can carry when the
        # primary interface has accelerated networking off. An empty catalog
        # answers "not said" - the order the engine always had.
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
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
        Mock -ModuleName VmMigrationFactory Get-AzVM { Script:NewFakeAzVm }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
        # SAFETY-3: every copy is locked when taken and checked before CONVERTING.
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface {
            [pscustomobject]@{ EnableAcceleratedNetworking = $true }
        }
        # FAIL-1: rollback now restores the PRISTINE DISK as well as the
        # hardware, so it needs the disk operations too. Without these the
        # rollback throws and every rollback test lands in
        # FAILED_NEEDS_ATTENTION - which is how the old 'hold' test kept
        # passing after the hold was removed, for entirely the wrong reason.
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-lab'
                               location = 'centralus'; skuName = 'Premium_LRS' }
        }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm1-osdisk-asitwas' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
        # ROLLBACK-DISKS-FIRST-1: SAFETY_PRISTINE makes the rollback disks,
        # a put-back reads them before its stop, and a completed move deletes them.
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
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
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Update-AzVM', 'function:\Get-AzNetworkInterface' -ErrorAction SilentlyContinue
}

Describe 'VmfStateMachine' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'sm-test' | Out-Null
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    Context 'Happy paths' {
        It 'Path A (Linux) runs PLANNED through MIGRATED with checkpoints' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                    'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                    'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                    'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                    default             { throw "unexpected guest script $ScriptName" }
                }
            }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'MIGRATED'
            $final.pathCheckpoint | Should -Be 'A:diskPatched'
            $final.safety.snapshotId | Should -Match 'snap1'
            $final.captured.vmConfig.size | Should -Be 'Standard_D2s_v4'
            $states = @($final.history | ForEach-Object { $_.state })
            $states | Should -Contain 'PRECHECK'
            $states | Should -Contain 'CONVERTING'
            $states[-1] | Should -Be 'MIGRATED'
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 1 -Exactly
        }

        It 'ROLLBACK-DISKS-FIRST-1: the way back is made after the first copy and before guest prep, and a completed move deletes it' {
            Script:MockHappyAzureOps
            $global:smOrder = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:smOrder.Add("copy:$SnapshotName"); "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/$SnapshotName" }
            Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:smOrder.Add("make:$DiskName"); "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { $global:smOrder.Add("delete:$(($DiskId -split '/')[-1])") }
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:smOrder.Add('size') }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                $global:smOrder.Add("guest:$ScriptName")
                switch ($ScriptName) {
                    'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                    'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                    'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                    'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                    default             { throw "unexpected guest script $ScriptName" }
                }
            }
            try {
                $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
                $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                    Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                }
                $final.state | Should -Be 'MIGRATED'
                $order = @($global:smOrder)
                $copy = [array]::IndexOf($order, ($order | Where-Object { $_ -like 'copy:*-pristine' } | Select-Object -First 1))
                $make = [array]::IndexOf($order, ($order | Where-Object { $_ -like 'make:vm-os-asitwas-*' } | Select-Object -First 1))
                $fix = [array]::IndexOf($order, 'guest:nvme-fix.sh')
                $make | Should -BeGreaterThan $copy -Because "made from the first copy (order: $($order -join ', '))"
                $make | Should -BeLessThan $fix -Because 'made before guest prep changes anything'
                $make | Should -BeLessThan ([array]::IndexOf($order, 'size'))
                @($order | Where-Object { $_ -like 'make:*' }) | Should -HaveCount 1 -Because 'one rollback disk, and the move itself makes none'
                $order[-1] | Should -BeLike 'delete:vm-os-asitwas-*' -Because 'the move completed and nothing used it'
                $rec = $final.safety.rollbackDisksBeforeMove
                @($rec.disks)[0].deletedUtc | Should -Not -BeNullOrEmpty
                @($rec.disks)[0].usedUtc | Should -BeNullOrEmpty
            }
            finally { Remove-Variable smOrder -Scope Global -ErrorAction SilentlyContinue }
        }
    }

    Context 'Kill-resume' {
        # REBUILD-REMOVE-ENGINE-1: the Path B resume (B:shellDeleted) is gone with
        # its steps; RebuildRemoveEngine.Tests.ps1 proves such a machine stops.
        It 'resumes Path A from A:diskPatched without repeating the disk patch' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                if ($ScriptName -match 'Mana|mana') {
                    [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS' }); warnings = @() }
                }
                else { [pscustomobject]@{ result = 'PASS'; checks = @(
                    @{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' },
                    @{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }
                ); warnings = @() } }
            }

            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A'
            # Seed state as a crashed run: CONVERTING, OS disk already patched, config captured
            $fakeVm = Script:NewFakeAzVm
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; fakeVm = $fakeVm } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = (Get-VmfVmCapture -Vm $fakeVm) }
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
                Set-VmfTestAnDecision -RunPath $rp -VmId $plan.vmId -PlanEntry $plan
                Update-VmfPathCheckpoint -Context $ctx -Checkpoint 'A:diskPatched'
            }

            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'MIGRATED'
            # Resume must NOT repeat completed sub-steps:
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes -Times 0
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 1 -Exactly
        }
    }

    Context 'STATE-TARGET-1: a machine finishes the move it started' {
        # A worker runs from the plan entry it was handed. If a machine is
        # resumed after the entry changed - another path, size or controller -
        # nothing noticed, and CONVERTING and the rollback branch on the entry's
        # path. The target a machine starts on is now recorded in PRECHECK,
        # before anything changes, and a resume finishes THAT move.
        BeforeEach {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                if ($ScriptName -match 'Mana|mana') {
                    [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS' }); warnings = @() }
                }
                else { [pscustomobject]@{ result = 'PASS'; checks = @(
                    @{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' },
                    @{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }
                ); warnings = @() } }
            }
        }

        It 'PRECHECK records the target the machine starts on, before anything changes' {
            $plan = Script:NewPlanEntry -Path 'A'
            $plan.policy | Add-Member -NotePropertyName targetGeneration -NotePropertyValue 'v6'
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'stop here - abandon this VM.' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw
                $t = (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.startedTarget
                $t.path | Should -Be 'A'
                $t.size | Should -Be 'Standard_D2s_v6'
                $t.controller | Should -Be 'NVMe'
                $t.target.diskArch | Should -Be 'diskless'
                $t.series | Should -Be 'v6'
            }
        }

        It 'a machine resumed at A:diskPatched with the entry now giving another size is moved to the size it started on' {
            $started = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $fakeVm = Script:NewFakeAzVm
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $started; fakeVm = $fakeVm } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = (Get-VmfVmCapture -Vm $fakeVm)
                    startedTarget = (Get-VmfStartedTarget -PlanEntry $plan) }
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
                Set-VmfTestAnDecision -RunPath $rp -VmId $plan.vmId -PlanEntry $plan
                Update-VmfPathCheckpoint -Context $ctx -Checkpoint 'A:diskPatched'
            }
            # The entry changed after the machine started.
            $changed = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'diskless'
            $changed.target.size = 'Standard_D2s_v5'
            $changed.target.controller = 'SCSI'

            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $changed } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 1 -Exactly -ParameterFilter { $Size -eq 'Standard_D2s_v6' -and $Controller -eq 'NVMe' } `
                -Because 'on the size and controller it started on, not the changed entry''s v5 on SCSI'
            $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp }
            $kept = @($events | Where-Object { $_.step -eq 'targetKept' -and $_.outcome -eq 'warn' })
            $kept.Count | Should -Be 1
            $kept[0].detail | Should -Match 'the size Standard_D2s_v5, where it started with Standard_D2s_v6'
            $kept[0].detail | Should -Match 'Plan the machine again to use the change'
        }

        It 'STEP-LOG-3: the line that says the move keeps its target cannot be written - the machine still finishes the move it started' {
            $started = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $fakeVm = Script:NewFakeAzVm
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $started; fakeVm = $fakeVm } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = (Get-VmfVmCapture -Vm $fakeVm)
                    startedTarget = (Get-VmfStartedTarget -PlanEntry $plan) }
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
                Set-VmfTestAnDecision -RunPath $rp -VmId $plan.vmId -PlanEntry $plan
                Update-VmfPathCheckpoint -Context $ctx -Checkpoint 'A:diskPatched'
            }
            $changed = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'diskless'
            $changed.target.size = 'Standard_D2s_v5'
            $changed.target.controller = 'SCSI'
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'targetKept' } { throw 'The run history cannot be written' }

$final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $changed } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' -WarningVariable w -WarningAction SilentlyContinue
                $script:smWarned = @($w)
            }
            $warned = InModuleScope VmMigrationFactory { $script:smWarned }
            @($final)[0].state | Should -Be 'MIGRATED' -Because 'a line that cannot be written never leaves a machine mid-move'
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'targetKept' } -Times 1 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 1 -Exactly -ParameterFilter { $Size -eq 'Standard_D2s_v6' -and $Controller -eq 'NVMe' } `
                -Because 'the move it started, not the changed entry'
            (@($warned) -join "`n") | Should -Match "targetKept warn.*could not be written" -Because 'the engine output keeps the notice'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $changed.vmId } {
                (Read-VmfStateDoc -RunPath $rp -VmId $id).captured.startedTarget.size | Should -Be 'Standard_D2s_v6' -Because 'the record still says which move started'
            }
        }
        It 'an unchanged entry resumes with no warning' {
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $fakeVm = Script:NewFakeAzVm
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; fakeVm = $fakeVm } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = (Get-VmfVmCapture -Vm $fakeVm)
                    startedTarget = (Get-VmfStartedTarget -PlanEntry $plan) }
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
                Set-VmfTestAnDecision -RunPath $rp -VmId $plan.vmId -PlanEntry $plan
                Update-VmfPathCheckpoint -Context $ctx -Checkpoint 'A:diskPatched'
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'MIGRATED'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'targetKept' }).Count | Should -Be 0
            }
        }

        It 'every part of the target is found and put back, each on its own: <Part>' -ForEach @(
            @{ Part = 'path'; Change = { param($e) $e.path = 'A' }; Check = { param($e) $e.path -eq 'B' } },
            @{ Part = 'size'; Change = { param($e) $e.target.size = 'Standard_D4s_v6' }; Check = { param($e) $e.target.size -eq 'Standard_D2s_v6' } },
            @{ Part = 'controller'; Change = { param($e) $e.target.controller = 'SCSI' }; Check = { param($e) $e.target.controller -eq 'NVMe' } },
            @{ Part = 'temporary disk'; Change = { param($e) $e.target.diskArch = 'diskless' }; Check = { param($e) $e.target.diskArch -eq 'nvme-temp' } },
            @{ Part = 'zone'; Change = { param($e) $e.target | Add-Member -NotePropertyName zone -NotePropertyValue '2' -Force }; Check = { param($e) -not $e.target.PSObject.Properties['zone'] } },
            @{ Part = 'alternates'; Change = { param($e) $e.target | Add-Member -NotePropertyName alternates -NotePropertyValue @('Standard_D2as_v6') -Force }; Check = { param($e) -not $e.target.PSObject.Properties['alternates'] } },
            @{ Part = 'series'; Change = { param($e) $e.policy | Add-Member -NotePropertyName targetGeneration -NotePropertyValue 'v7' -Force }; Check = { param($e) $e.policy.targetGeneration -eq 'v6' } },
            @{ Part = 'accelerated networking'; Change = { param($e) $e.policy | Add-Member -NotePropertyName acceleratedNetworking -NotePropertyValue 'ensureOn' -Force }; Check = { param($e) -not $e.policy.PSObject.Properties['acceleratedNetworking'] } }) {
            $started = Script:NewPlanEntry -Os 'Windows' -Path 'B' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $started.policy | Add-Member -NotePropertyName targetGeneration -NotePropertyValue 'v6'
            InModuleScope VmMigrationFactory -Parameters @{ s = $started; change = $Change; check = $Check } {
                $record = Get-VmfStartedTarget -PlanEntry $s | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
                $now = $s | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
                & $change $now
                $r = Resolve-VmfStartedTarget -PlanEntry $now -Started $record
                @($r.Changed).Count | Should -Be 1
                & $check $r.Entry | Should -BeTrue
                # The worker's own copy is never changed.
                & $check $now | Should -BeFalse
            }
        }

        It 'a retry that re-enters PRECHECK starts on the entry as it is NOW, and records that' {
            # A fresh attempt - after a rollback - is where a changed entry applies.
            $plan = Script:NewPlanEntry -Path 'A'
            $old = Script:NewPlanEntry -Path 'A'; $old.target.size = 'Standard_D4s_v6'
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'stop here - abandon this VM.' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; old = $old } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $ctx = New-VmfContext -PlanEntry $old -RunPath $rp -RunId 'sm-test'
                Save-VmfCapturedFacts -Context $ctx -Facts @{ startedTarget = (Get-VmfStartedTarget -PlanEntry $old) }
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.startedTarget.size | Should -Be 'Standard_D2s_v6'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.step -eq 'targetKept' }).Count | Should -Be 0
            }
        }

        It 'a PRECHECK that parks the machine records no target - nothing started' {
            # A plan whose policy holds a value the contract does not list parks
            # at the top of PRECHECK (policyNotKnown) - a park, with nothing
            # started. MANUAL-REVIEW-1: it was a bootable clone, a stop that is
            # gone. OLD-VERSION-READERS-REMOVE-1: Path B was the park here before.
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $plan.policy | Add-Member -NotePropertyName safetyCopy -NotePropertyValue 'clean' -Force
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'NEEDS_DECISION'
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                @($doc.history)[-1].reasonCode | Should -Be 'policyNotKnown'
                (-not $doc.captured -or -not $doc.captured.PSObject.Properties['startedTarget']) | Should -BeTrue
            }
        }

        It 'a machine that started before this was recorded resumes as it always did' {
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $fakeVm = Script:NewFakeAzVm
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; fakeVm = $fakeVm } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $ctx = New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                Save-VmfCapturedFacts -Context $ctx -Facts @{ vmConfig = (Get-VmfVmCapture -Vm $fakeVm) }
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'CONVERTING' -Outcome ok | Out-Null
                Set-VmfTestAnDecision -RunPath $rp -VmId $plan.vmId -PlanEntry $plan
                Update-VmfPathCheckpoint -Context $ctx -Checkpoint 'A:diskPatched'
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'MIGRATED'
            }
        }
    }

    Context 'ROLLBACK-RETRY-CAPTURE-1: a retry never overwrites the capture a put-back uses' {
        # PRECHECK captured the machine again on every attempt and wrote over
        # captured.vmConfig - and every put-back read that field as "how it
        # was". After a rollback that failed and a rebuild as the TARGET, the
        # retry captured the machine on the target size, and a later rollback
        # put it back THERE. The first capture is now kept, once, beside the
        # attempt's own (captured.original, vm-state v16).
        BeforeEach {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            # The machine as a rebuild as the target left it: another size, and
            # an OS disk made from a copy. The function exists in this scope, so
            # the mocks below can call it.
            function Script:RebuiltVm {
                $v = Script:NewFakeAzVm
                $v.HardwareProfile.VmSize = 'Standard_D4s_v4'
                $v.StorageProfile.OsDisk.Name = 'vm-os-rec'
                $v.StorageProfile.OsDisk.ManagedDisk.Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os-rec'
                $v
            }
        }

        It 'PRECHECK keeps the first capture through a kill and resume, and through a retry; the retry records its own' {
            $plan = Script:NewPlanEntry -Path 'A'
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'stop here - abandon this VM.' }
            $first = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                $doc.captured.original.vmConfig.size | Should -Be 'Standard_D2s_v4'
                $doc.schemaVersion | Should -Be 51   # v16 added captured.original; v22 (ROLLBACK-DISKS-FIRST-1) holds it, RECOVER-ALL-DISKS-1 v23, ROLLBACK-CRG-1 v24, SWAP-REFUSED-AFTER-STOP-1 v25, MADE-DISK-RECORD-1 v26, RESTORE-END-JOB-1 v27, FINISH-EMPTY-LUN-PROOF-1 v28, FINISH-KEPT-DISKS-1 v29, RESTORE-EARLIER-DELETE-1 v40
                $at = [string]$doc.captured.original.capturedUtc
                # Killed and resumed: PRECHECK runs again on the same attempt.
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw
                [string](Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.original.capturedUtc | Should -Be $at
                $at
            }
            Mock -ModuleName VmMigrationFactory Get-AzVM { Script:RebuiltVm }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; at = $first } {
                # A person's retry: a new attempt from the first step.
                Clear-VmfRetryState -RunPath $rp -VmId $plan.vmId -From 'PRECHECK' -NewAttempt
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                $doc.captured.vmConfig.size | Should -Be 'Standard_D4s_v4' -Because 'the attempt records the machine as it finds it'
                $doc.captured.vmConfig.osDisk.name | Should -Be 'vm-os-rec'
                $doc.captured.original.vmConfig.size | Should -Be 'Standard_D2s_v4' -Because 'the first capture is never written again'
                $doc.captured.original.vmConfig.osDisk.name | Should -Be 'vm-os'
                [string]$doc.captured.original.capturedUtc | Should -Be $at
            }
        }

        It 'a machine the product never touched has its first capture refreshed - its owner changed it as the stop asked' {
            $plan = Script:NewPlanEntry -Path 'A'
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'stop here - abandon this VM.' }
            Mock -ModuleName VmMigrationFactory Get-AzVM { Script:RebuiltVm }
            $original = Script:NewFakeAzVm
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; ov = $original } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                Save-VmfCapturedFacts -Context ([pscustomobject]@{ RunPath = $rp; VmId = $plan.vmId }) -Facts @{
                    vmConfig = (Get-VmfVmCapture -Vm $ov)
                    original = [ordered]@{ vmConfig = (Get-VmfVmCapture -Vm $ov); extensions = @(); sourceAcceleratedNetworking = $null; capturedUtc = '2026-10-01T08:00:00Z' } }
                # The first attempt parked at PRECHECK, before anything was touched.
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'targetTooFewNics' -MachineState 'untouched' -Detail 'too many interfaces' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                $doc.captured.original.vmConfig.size | Should -Be 'Standard_D4s_v4' -Because 'nothing the product did made the earlier capture "how it was"'
            }
        }

        It 'a rollback after that retry puts the machine back to the FIRST capture (Path A), on the attempt''s own disk' {
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            Mock -ModuleName VmMigrationFactory Get-AzVM { Script:RebuiltVm }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'boot failure' }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{} }
            $original = Script:NewFakeAzVm
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan; ov = $original } {
                New-VmfStateDoc -RunPath $rp -RunId 'sm-test' -VmId $plan.vmId -Wave 'w1' | Out-Null
                $cap = Get-VmfVmCapture -Vm $ov
                $cap.nics[0].acceleratedNetworking = $false
                Save-VmfCapturedFacts -Context ([pscustomobject]@{ RunPath = $rp; VmId = $plan.vmId }) -Facts @{
                    original = [ordered]@{ vmConfig = $cap; extensions = @(); sourceAcceleratedNetworking = $null; capturedUtc = '2026-10-01T08:00:00Z' } }
                # The earlier attempt touched the machine (it took a copy), so the first
                # capture stands; a person's retry then put it back at PRECHECK.
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'SAFETY_PRISTINE' -Outcome ok | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $plan.vmId -NewState 'PRECHECK' -Outcome ok | Out-Null
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -ParameterFilter {
                $Size -eq 'Standard_D2s_v4' -and $Controller -eq 'SCSI' } -Times 1 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -ParameterFilter { $Size -eq 'Standard_D4s_v4' } -Times 0
            # Accelerated networking as the first capture found it.
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking -ParameterFilter { $Enabled -eq $false }
            # The copy is of the disk this attempt found.
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -ParameterFilter { $OsDiskId -match 'vm-os-rec$' }
        }
    }

    Context 'VERIFY-FP-1: the Instance Metadata Service, before and after' {
        # IMDS answers only on the primary network interface (Microsoft), so an
        # answer before the move and none after means that interface did not
        # come back. Every validation failure rolls back (FAIL-1).
        BeforeEach {
            Script:MockHappyAzureOps
            # VERIFY-FP-FLAKY-1: the answer is picked by the step the engine is
            # in - [0] before the conversion, [1] from CONVERTING on - never by
            # counting calls. The engine retries a step that fails (GUEST_PREP
            # twice, VALIDATING twice), and every retry asks again, so a count
            # put the "after" answer into the reading before the move whenever
            # a step retried. That is how this Context failed once on CI.
            $script:imdsAnswers = @('yes', 'yes')
            $script:imdsSize = 'Standard_D2s_v6'
            $script:prepFailsLeft = 0
            # IMDS-KEEP-1: the answers GUEST_PREP gets, one per time it asks,
            # in order - 'unknown' is a run command that failed. When it is
            # empty, GUEST_PREP gets [0] above. Each test that sets it also
            # asserts the step really asked again.
            $script:imdsPrepQueue = @()
            $script:manaAbandonsLeft = 0
            # IMDS-KEEP-2: nvme-fix.sh, the Linux preparation, starts and then
            # throws each message here once, in order - leaving the STARTED
            # entry a real changing script leaves in the audit trail (the guest
            # may have changed). Then GUEST_PREP is retried, or resumed.
            $script:fixThrows = @()
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                if ($ScriptName -eq 'nvme-fix.sh' -and @($script:fixThrows).Count) {
                    $fixMessage = @($script:fixThrows)[0]
                    $script:fixThrows = @($script:fixThrows | Select-Object -Skip 1)
                    InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; vm = $VmId } {
                        Write-VmfGuestAuditEntry -RunPath $rp -VmId $vm -Entry ([pscustomobject]@{
                                script = 'nvme-fix.sh'; result = 'STARTED'; tsUtc = (Get-Date).ToUniversalTime().ToString('o')
                                evidenceRef = "runcmd-nvme-fix.sh-$([guid]::NewGuid().ToString('N').Substring(0, 8)).txt" })
                    }
                    throw $fixMessage
                }
                if ($ScriptName -match 'Mana|mana' -and $script:manaAbandonsLeft -gt 0) {
                    # A worker that loses its lease in the middle of the step:
                    # the engine stops the machine where it is, and the next
                    # worker resumes it (a kill, then a resume).
                    $script:manaAbandonsLeft--
                    throw 'lease lost for vm-under-test - abandon this VM.'
                }
                if ($ScriptName -match 'Mana|mana' -and $script:prepFailsLeft -gt 0) {
                    $script:prepFailsLeft--
                    throw 'The run command did not finish in time.'
                }
                if ($ScriptName -eq 'imds-check.sh') {
                    $after = (Script:EngineStep) -in @('CONVERTING', 'STARTING', 'VALIDATING')
                    $answer = $script:imdsAnswers[$(if ($after) { 1 } else { 0 })]
                    if (-not $after -and @($script:imdsPrepQueue).Count) {
                        $answer = @($script:imdsPrepQueue)[0]
                        $script:imdsPrepQueue = @($script:imdsPrepQueue | Select-Object -Skip 1)
                    }
                    if ($answer -eq 'unknown') { throw 'The run command did not finish in time.' }
                    $facts = if ($answer -eq 'yes') { [pscustomobject]@{ os = 'Linux'; imdsReached = 'yes'; imdsVmSize = $(if ($after) { $script:imdsSize } else { 'Standard_D2s_v4' }) } }
                             else { [pscustomobject]@{ os = 'Linux'; imdsReached = 'no' } }
                    return [pscustomobject]@{ schema = 'vmf.guest/2'; result = 'READY'; checks = @(); facts = $facts; warnings = @() }
                }
                if ($ScriptName -match 'Mana|mana') {
                    [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS' }); warnings = @() }
                }
                else { [pscustomobject]@{ result = 'PASS'; checks = @(
                    @{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' },
                    @{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }
                ); warnings = @() } }
            }
        }

        It 'answered before and after, on the target size: the move completes, and the reading before is kept' {
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'MIGRATED'
                $b = (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore
                $b.reached | Should -Be 'yes'
                $b.vmSize | Should -Be 'Standard_D2s_v4'
            }
        }

        It 'answered before and not after: the machine is rolled back, and the log says why' {
            $script:imdsAnswers = @('yes', 'no')
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'FAILED_ROLLED_BACK'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.detail -match 'answered before the move and does not answer now' }).Count | Should -BeGreaterThan 0
            }
        }

        It 'never answered - a static address inside the guest: the move completes' {
            $script:imdsAnswers = @('no', 'no')
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'MIGRATED'
            }
        }

        It 'answers after the move with a size that is not the target: the machine is rolled back' {
            $script:imdsSize = 'Standard_D4s_v6'
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                (Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test').state | Should -Be 'FAILED_ROLLED_BACK'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.detail -match "reports the size Standard_D4s_v6, and the plan's target is Standard_D2s_v6" }).Count | Should -BeGreaterThan 0
            }
        }

        # VERIFY-FP-FLAKY-1: GUEST_PREP asks IMDS and then may fail and be
        # retried (two attempts), which asks again. The answers above used to be
        # picked by counting calls, so one retry made the second "before" read
        # take the "after" answer - and on CI this test once saw MIGRATED.
        It 'answered before and not after, with the preparation step retried once: still rolled back' {
            $script:imdsAnswers = @('yes', 'no')
            $script:prepFailsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.detail -match 'answered before the move and does not answer now' }).Count | Should -BeGreaterThan 0
            }
        }

        It 'answered before and after, with the preparation step retried once: the reading before is from the source size' {
            $script:prepFailsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                $final.state | Should -Be 'MIGRATED'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.vmSize | Should -Be 'Standard_D2s_v4'
            }
        }

        # IMDS-KEEP-1: a retried GUEST_PREP asks again. Before this, its answer
        # always replaced the first one, so a run command that failed on the
        # retry dropped a "yes" - and VALIDATING could no longer fail a machine
        # whose primary interface did not come back.
        It 'IMDS-KEEP-1: answered, then unknown on the retry, then not after: the "yes" is kept and the machine is rolled back' {
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('yes', 'unknown')
            $script:prepFailsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                $b = (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore
                $b.reached | Should -Be 'yes'
                $b.vmSize | Should -Be 'Standard_D2s_v4'
                @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.detail -match 'taken before any change, stays the reading before the move: the service answered\. The reading now: the product could not ask\.' }).Count | Should -Be 1
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.detail -match 'answered before the move and does not answer now' }).Count | Should -BeGreaterThan 0
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the retried step really asked again'
        }

        It 'IMDS-KEEP-1: unknown, then answered on the retry before any change: the known reading is taken' {
            # IMDS-KEEP-2: the retry comes from the driver check, which reads
            # and changes nothing, so the second ask is still on the untouched
            # machine - and the log says why it is used.
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('unknown', 'yes')
            $script:prepFailsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.reached | Should -Be 'yes'
                @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.detail -match 'was unknown, and no script has changed the guest yet, so this reading is used: the service answered\.' }).Count | Should -Be 1
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the retried step really asked again'
        }

        It 'IMDS-KEEP-2: answered, then a known "no" on a retry before any change: the first reading stays' {
            # IMDS-KEEP-1 pinned the opposite here (a newer known reading
            # replaced the older one) while the question was open. Since
            # 2026-10-09: the first reading of the attempt is the baseline, and
            # a later one never replaces it.
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('yes', 'no')
            $script:prepFailsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.reached | Should -Be 'yes'
                @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.detail -match 'stays the reading before the move: the service answered\. The reading now: the service did not answer\.' }).Count | Should -Be 1
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the retried step really asked again'
        }

        It 'IMDS-KEEP-2, the reported example: answered, the preparation changed the guest, "no" on the retry, "no" after: rolled back' {
            # Before the move the network works; the preparation (nvme-fix.sh)
            # starts and the run command fails, so the guest may have changed;
            # the retried GUEST_PREP reads "no". Before this item that "no"
            # replaced the "yes", the check after the move compared "no" with
            # "no", and the machine was MIGRATED.
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('yes', 'no')
            $script:fixThrows = @('The run command did not finish in time.')
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                @($doc.guestExecutions | Where-Object { $_.script -eq 'nvme-fix.sh' -and $_.result -eq 'STARTED' }).Count | Should -Be 1 -Because 'the retry follows a change on record'
                $doc.captured.imdsBefore.reached | Should -Be 'yes'
                $doc.captured.imdsBefore.vmSize | Should -Be 'Standard_D2s_v4'
                @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.detail -match 'stays the reading before the move: the service answered\. The reading now: the service did not answer\.' }).Count | Should -Be 1
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
                @(Read-VmfEvents -RunPath $rp | Where-Object { $_.detail -match 'answered before the move and does not answer now' }).Count | Should -BeGreaterThan 0
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the retried step really asked again'
            @($script:fixThrows).Count | Should -Be 0 -Because 'the preparation really started and failed'
        }

        It 'IMDS-KEEP-2: unknown, the preparation changed the guest, then answered on the retry: the reading stays unknown' {
            # The answer after the change cannot show the machine as it was, so
            # it never becomes the baseline. An unknown before never fails a
            # move, so the "no" after does not stop it.
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('unknown', 'yes')
            $script:fixThrows = @('The run command did not finish in time.')
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.reached | Should -Be 'unknown'
                @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.detail -match 'cannot show the machine as it was\. The reading before the move stays unknown\. The reading now: the service answered\.' }).Count | Should -Be 1
                $final.state | Should -Be 'MIGRATED'
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the retried step really asked again'
        }

        It 'IMDS-KEEP-2 kill-resume: the worker stops inside the preparation, and the resumed step reads "no": the "yes" stays' {
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('yes', 'no')
            $script:fixThrows = @('lease lost for vm-under-test - abandon this VM.')
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw '*abandon this VM*'
                $mid = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                $mid.state | Should -Be 'GUEST_PREP' -Because 'the worker stopped inside the step'
                $mid.captured.imdsBefore.reached | Should -Be 'yes'
                Test-VmfGuestChangedThisAttempt -Doc $mid | Should -BeTrue -Because 'the preparation started before the worker stopped'

                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.reached | Should -Be 'yes'
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the resumed step asked again'
        }

        It 'IMDS-KEEP-1: did not answer, then unknown on the retry: the "no" is kept, and the log says the service did not answer' {
            $script:imdsAnswers = @('no', 'no')
            $script:imdsPrepQueue = @('no', 'unknown')
            $script:prepFailsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a retried preparation step'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.reached | Should -Be 'no'
                @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.detail -match 'stays the reading before the move: the service did not answer\. The reading now: the product could not ask\.' }).Count | Should -Be 1
                $final.state | Should -Be 'MIGRATED' -Because 'never answered: the static-address case'
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the retried step really asked again'
        }

        It 'IMDS-KEEP-1 kill-resume: a worker stops after the reading, and the resumed step cannot ask: the "yes" is kept' {
            $script:imdsAnswers = @('yes', 'no')
            $script:imdsPrepQueue = @('yes', 'unknown')
            $script:manaAbandonsLeft = 1
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw '*abandon this VM*'
                $mid = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
                $mid.state | Should -Be 'GUEST_PREP' -Because 'the worker stopped inside the step'
                $mid.captured.imdsBefore.reached | Should -Be 'yes'

                $final = Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).captured.imdsBefore.reached | Should -Be 'yes'
                $final.state | Should -Be 'FAILED_ROLLED_BACK'
            }
            @($script:imdsPrepQueue).Count | Should -Be 0 -Because 'the resumed step asked again'
        }
    }

    Context 'STEP-LOG-1: a log line that cannot be written never decides what a step did' {
        # The step's checkpoint and its "ok" line in the run history shared
        # the loop's one error handler. A line that could not be written after
        # the checkpoint was counted as the step failing: the machine was put
        # back to the step it had finished and ran it again - and when that
        # used up the step's attempts, CONVERTING, STARTING or VALIDATING
        # rolled back a machine that had passed. Each line now has its own
        # handler, as the record line has (REPORT-RECORD-LINE-1).
        BeforeEach {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Write-Warning { }
            $script:prepImdsAsks = 0
            $script:validateFailsLeft = 0
            $script:prepFailsLeft = 0
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                $step = Script:EngineStep
                if ($ScriptName -eq 'imds-check.sh') {
                    if ($step -eq 'GUEST_PREP') { $script:prepImdsAsks++ }
                    $size = if ($step -in @('CONVERTING', 'STARTING', 'VALIDATING')) { 'Standard_D2s_v6' } else { 'Standard_D2s_v4' }
                    return [pscustomobject]@{ schema = 'vmf.guest/2'; result = 'READY'; checks = @(); warnings = @()
                        facts = [pscustomobject]@{ os = 'Linux'; imdsReached = 'yes'; imdsVmSize = $size } }
                }
                if ($ScriptName -match 'Mana|mana') {
                    if ($step -eq 'GUEST_PREP' -and $script:prepFailsLeft -gt 0) { $script:prepFailsLeft--; throw 'The run command did not finish in time.' }
                    return [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS' }); warnings = @() }
                }
                if ($ScriptName -eq 'guest-validate.sh' -and $step -eq 'VALIDATING' -and $script:validateFailsLeft -gt 0) {
                    $script:validateFailsLeft--
                    throw 'The run command did not finish in time.'
                }
                [pscustomobject]@{ result = 'PASS'; checks = @(
                    @{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' },
                    @{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }
                ); warnings = @() }
            }
        }

        It 'the "ok" line of a finished step cannot be written: the step does not run again, and a warning says so' {
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'GUEST_PREP' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $script:prepImdsAsks | Should -Be 1 -Because 'GUEST_PREP ran once - a line that was not written is not a step that failed'
            @($final.history | Where-Object { $_.outcome -eq 'retry' }).Count | Should -Be 0
            @($final.history | Where-Object { $_.state -eq 'STOPPED' -and $_.outcome -eq 'ok' }).Count | Should -Be 1 -Because 'the checkpoint is the record of the step, and it was written once'
            Should -Invoke -ModuleName VmMigrationFactory Write-Warning -ParameterFilter { $Message -match 'GUEST_PREP' -and $Message -match 'could not be written' -and $Message -match 'store did not answer' } -Times 1 -Exactly
        }

        It 'VALIDATING passes on its second attempt and its "ok" line cannot be written: the machine is MIGRATED, never rolled back' {
            # The loop's line is the one with the step's duration; the step's own
            # lines in the middle of its work are left out (see the work item).
            # Before: the failed line counted as VALIDATING's second failure,
            # used up its attempts, and FAIL-1 rolled back a machine that had
            # passed every check.
            $script:validateFailsLeft = 1
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'VALIDATING' -and $Outcome -eq 'ok' -and $DurationSec -gt 0 } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            @($final.history | Where-Object { $_.state -eq 'VALIDATING' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'this test is about a step that passed on its last attempt'
            $final.state | Should -Be 'MIGRATED'
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0 -Because 'nothing was rolled back'
        }

        It 'the "start" line of a step cannot be written: the step still runs, and is not counted as failed' {
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'VALIDATING' -and $Outcome -eq 'start' } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            @($final.history | Where-Object { $_.outcome -eq 'retry' }).Count | Should -Be 0
        }

        It 'a step fails and its "fail" line cannot be written: the failure is still counted, and the retry runs' {
            $script:prepFailsLeft = 1
            # ACTIVITY-LINES-1: the line of an attempt that is tried again is a retry line.
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'GUEST_PREP' -and $Outcome -in @('fail', 'retry') } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and $_.outcome -eq 'retry' }).Count | Should -Be 1
            $final.state | Should -Be 'MIGRATED'
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'GUEST_PREP' -and $Outcome -in @('fail', 'retry') } -Scope It -Times 1 -Because 'the line of the attempt was really asked for'
        }

        It 'the line after a conversion checkpoint cannot be written: CONVERTING is not run again' {
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'checkpoint' } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $final.pathCheckpoint | Should -Be 'A:diskPatched'
            @($final.history | Where-Object { $_.state -eq 'CONVERTING' -and $_.outcome -eq 'retry' }).Count | Should -Be 0
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 1 -Exactly
        }

        It 'kill-resume: a worker that stops at the "ok" line - the resume goes on from the checkpoint, and never prepares again' {
            $script:okAbandonsLeft = 1
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'GUEST_PREP' -and $Outcome -eq 'ok' -and $script:okAbandonsLeft -gt 0 } {
                $script:okAbandonsLeft--
                throw 'lease lost for vm-under-test - abandon this VM.'
            }
            $plan = Script:NewPlanEntry
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                { Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' } | Should -Throw '*abandon this VM*' -Because 'a lost lease still stops the worker'
                (Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId).state | Should -Be 'STOPPED' -Because 'the checkpoint was written before the line'
            }
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $script:prepImdsAsks | Should -Be 1 -Because 'the resume started at STOPPED'
        }

        It 'review: no line inside VALIDATING can be written on its last attempt - MIGRATED, never rolled back' {
            # Every line the step writes between its checks - the Instance
            # Metadata Service, the security and rebuild lines, and the rest -
            # each after a check passed. The first build's test selected only the
            # loop's line (the one with a duration); this one selects the step's own.
            $script:validateFailsLeft = 1
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'VALIDATING' -and $Outcome -in @('ok', 'info', 'warn') -and -not $DurationSec } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            @($final.history | Where-Object { $_.state -eq 'VALIDATING' -and $_.outcome -eq 'retry' }).Count | Should -Be 1 -Because 'the second attempt is the last one'
            $final.state | Should -Be 'MIGRATED'
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'VALIDATING' -and $Outcome -in @('ok', 'info', 'warn') -and -not $DurationSec } -Scope It -Times 1 -Because 'the mock really selected a line inside the step'
        }

        It 'review: the rearm line after a rollback that worked cannot be written - restored, never "rollback failed"' {
            # VALIDATING fails on both attempts, so the whole machine is put
            # back. Clear-VmfRetryState writes its line after the rollback's
            # done checkpoint.
            $script:validateFailsLeft = 2
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'rearm' } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            $stop = @($final.history)[-1]
            $stop.reasonCode | Should -Not -Be 'rollbackFailed'
            $stop.machineState | Should -Be 'restored'
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'rearm' } -Scope It -Times 1 -Because 'the line was really asked for'
        }

        It 'review: the STARTING line after the NVMe I/O timeout repair cannot be written - MIGRATED, never rolled back' {
            # STARTING has one attempt, and this line is written on most Windows
            # NVMe moves, after the start, the agent wait and the repair.
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'Test-NvmeReady.ps1'       { [pscustomobject]@{ result = 'READY'; checks = @(); warnings = @() } }
                    'Test-TempDiskContent.ps1' { [pscustomobject]@{ result = 'READY'; checks = @(); warnings = @() } }
                    'Move-Pagefile.ps1'        { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                    'Install-TempDiskInit.ps1' { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                    'Test-GuestValidation.ps1' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' }); warnings = @() } }
                    # The declared fact (GUEST-2): one boot configuration was reset.
                    'Repair-NvmeIoTimeout.ps1' { [pscustomobject]@{ schema = 'vmf.guest/2'; result = 'FIXED'; checks = @(); warnings = @(); facts = [pscustomobject]@{ ioTimeoutBefore = 'ControlSet001=10 ControlSet002=240' } } }
                    'Test-ManaReady.ps1'       { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS'; detail = 'Ethernet 3' }); warnings = @() } }
                    'Install-ManaDriver.ps1'   { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                    default                    { throw "unexpected guest script $ScriptName" }
                }
            }
            Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'STARTING' -and $Outcome -eq 'info' } { throw 'The store did not answer.' }
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'STARTING' -and $Outcome -eq 'info' } -Scope It -Times 1 -Because 'the repair line was really asked for'
            $final.state | Should -Be 'MIGRATED'
        }

        It 'review: Write-VmfStepLine takes only the outcomes Write-VmfEvent takes' {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
                { Write-VmfStepLine -RunPath $rp -Step 'x' -Outcome 'done' } | Should -Throw '*does not belong to the set*'
                $set = { param($cmd) @((Get-Command $cmd).Parameters['Outcome'].Attributes | Where-Object { $_ -is [System.Management.Automation.ValidateSetAttribute] })[0].ValidValues }
                @(& $set 'Write-VmfStepLine') | Should -Be @(& $set 'Write-VmfEvent')
            }
        }

        It 'no line written after the engine changed something goes to the run history without its own handler' {
            # The parser, not the text: a comment that names the command is not a
            # call. EVERY file of the engine is scanned, so a new file is covered
            # without anybody adding it here (fail closed): the steps, the
            # rollback, what they call after a checkpoint (Clear-VmfRetryState,
            # Add-VmfRollbackDiskDuringRollbackRecord, the kernel put-back, the disk types, the
            # data disk copies) and every Azure operation write through
            # Write-VmfStepLine. One kind stays throwing on purpose: PRECHECK,
            # which changes nothing. The targetKept notice joined the helper
            # (STEP-LOG-3): its machine has started its move.
            # STEP-LOG-2 swept the rest of the engine - the wave level, the plan
            # run, the claims, the decision carry, the restores and the rebuild,
            # the deleted safety copies, the summary and the record and report -
            # and the two restore commands, Restore-VmfVm and
            # Restore-VmfVmShell. EventLog.ps1 is where both writers live.
            # STEP-LOG-4 added every other exported command and the worker:
            # every file in Public and Workers is scanned, so a new command is
            # covered without anybody adding it here. STEP-LOG-5 swept the
            # capacity and wave start commands and the worker, so only the file
            # where both writers live is left out.
            $module = (Resolve-Path (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory')).Path
            $notSwept = @('Private/logging/EventLog.ps1')
            foreach ($rel in $notSwept) { Test-Path (Join-Path $module $rel) | Should -BeTrue -Because "$rel is on the list, so it must exist" }
            $files = @(@(foreach ($folder in 'Private', 'Public', 'Workers') {
                        Get-ChildItem -Path (Join-Path $module $folder) -Recurse -Filter '*.ps1' | ForEach-Object { $_.FullName.Substring($module.Length + 1).Replace('\', '/') } }) |
                Where-Object { $_ -notin $notSwept })
            $files.Count | Should -BeGreaterThan 60 -Because 'the scan reads the whole engine and every operator command'
            $files | Should -Contain 'Private/azureops/AzureOps.ps1'
            $files | Should -Contain 'Private/engine/RestoreDiskResume.ps1'
            $files | Should -Contain 'Public/Restore-VmfVm.ps1'
            $files | Should -Contain 'Public/Resolve-VmfDecision.ps1'
            # STEP-LOG-5: the capacity and wave start commands and the worker.
            foreach ($rel in 'Public/New-VmfWaveReservation.ps1', 'Public/Remove-VmfCapacityReservations.ps1', 'Public/Invoke-VmfWaveCloseOut.ps1',
                'Public/Request-VmfQuota.ps1', 'Public/Test-VmfQuota.ps1', 'Public/Start-VmfWave.ps1', 'Workers/worker.ps1') {
                $files | Should -Contain $rel
            }
            # STEP-LOG-6: and every script of the service (src/facade) - the
            # engine start, the resume and schedule passes, the delete, the
            # timer passes - which writes into the run history through the
            # module. Every file is read, so a new endpoint is covered without
            # anybody adding it here.
            $facade = (Resolve-Path (Join-Path $module '..' 'facade')).Path
            $pathOf = @{}
            foreach ($rel in $files) { $pathOf[$rel] = Join-Path $module $rel }
            $service = @(Get-ChildItem -Path $facade -Recurse -File -Include '*.ps1', '*.psm1' | ForEach-Object {
                    $rel = 'facade/' + $_.FullName.Substring($facade.Length + 1).Replace('\', '/')
                    $pathOf[$rel] = $_.FullName
                    $rel })
            $service | Should -Contain 'facade/FacadeCore/FacadeCore.psm1'
            $service | Should -Contain 'facade/app/ScheduleRunner/run.ps1'
            $service | Should -Contain 'facade/app/RetentionRunner/run.ps1'
            $files = @($files + $service)
            # The lines kept as throwing writes on purpose, by file, function,
            # step and outcome, with how many. Each is written BEFORE anything
            # changes, so a line that cannot be written stops with nothing
            # changed:
            # - Restore-VmfVm and Restore-VmfVmShell: the retirement refusal and
            #   warning, and the start line (Restore-VmfVm: and the line that
            #   says which disks it WILL use), all before a disk is made. The
            #   line that names the disks it MADE uses the handler;
            # - Invoke-VmfRestoreRebuild: the old ID of a system-assigned
            #   identity, before the delete destroys it - the only place the ID
            #   survives (as PRECHECK records it for the move's rebuild);
            # - Remove-VmfRunSafetyCopies: the line before a copy's lock comes
            #   off. It is the only record that the copy may be unlocked, so a
            #   line that cannot be written keeps the lock on;
            # - STEP-LOG-4: Invoke-VmfAssessment's start line, before the scan
            #   reads anything; and Set-VmfWavePlan's line for a save that
            #   changes nothing, which is all that save writes.
            # - SWAP-REFUSED-AFTER-STOP-1: Complete-VmfDataDiskSwap's start
            #   line (Finish the rollback / Finish the restore), before it reads
            #   or changes the machine.
            $kept = @{
                'Public/Complete-VmfDataDiskSwap.ps1|Complete-VmfDataDiskSwap|finish|start'    = 1
                # PREVIEW-PUTBACK-1: the refusal, and the line that the preview feature
                # is registered, both before the restore job and before anything changes.
                # OLD-REBUILD-RESTORE-READERS-1: the refusal of the first copy of a
                # machine an earlier version rebuilt is gone.
                # RESTORE-PERM-CHECK-1: and the refusal for a missing permission, before
                # the restore job and before anything changes.
                'Public/Restore-VmfVm.ps1|Restore-VmfVm|putBack|fail'                          = 3
                'Public/Restore-VmfVm.ps1|Restore-VmfVm|putBack|info'                          = 1
                'Public/Restore-VmfVm.ps1|Restore-VmfVm|putBack|warn'                          = 1
                'Public/Restore-VmfVm.ps1|Restore-VmfVm|restore|start'                         = 1
                'Public/Restore-VmfVm.ps1|Restore-VmfVm|restore|info'                          = 1
                # RETENTION-LOCK-PUTBACK-1: the same line, written before the lock comes off,
                # now under the caller's step (discardCopy, or retention for the daily cleanup).
                'Private/engine/RunSafetyCopies.ps1|Remove-VmfRunSafetyCopies|$Step|info'       = 1
                # REBUILD-REMOVE-ACCEPT-1: PRECHECK's lines of who accepted the loss of
                # the identity and the rebuild (Write-VmfAcceptanceLineOnce) are gone
                # with the acceptances.

                # CRG-MOVE-1: PRECHECK's line that the move keeps the machine in its own
                # capacity reservation group, written before anything changes, so it throws.
                'Private/engine/ReservationMove.ps1|Test-VmfMoveReservationGroup|precheck|info' = 1
                'Public/Invoke-VmfAssessment.ps1|Invoke-VmfAssessment|assessment|start'        = 1
                'Public/Set-VmfWavePlan.ps1|Set-VmfWavePlan|plan|ok'                           = 1
                # STEP-LOG-5: a quota increase preview changes nothing, and its line
                # is its only answer, which the page waits for.
                'Public/Request-VmfQuota.ps1|Request-VmfQuota|quotaPreview|info'               = 1
                # STEP-LOG-6: the delete of a migration writes its start line,
                # and its "discarded by" line, before the engine starts or a
                # record is removed; and the line that ends a restore's row is
                # written before its record is marked, so a lost line keeps the
                # record and the next pass ends the row (RESTORE-END-LOST-1).
                'facade/FacadeCore/FacadeCore.psm1|Invoke-VmfFacadeDiscardRun|discard|start'   = 1
                'facade/FacadeCore/FacadeCore.psm1|Invoke-VmfFacadeDiscardRun|run|ok'          = 1
                'facade/FacadeCore/FacadeCore.psm1|Invoke-VmfFacadeResumeStalledPutBacks|"engine:$k"|fail' = 1
                # SCAN-FAIL-SHOWN-1: the line that ends the wait of a scan whose job
                # ended with no answer changes nothing else; a lost line is written
                # by the next pass, which finds no answer after the start.
                'facade/FacadeCore/FacadeCore.psm1|Invoke-VmfFacadeEndSilentScan|engine:assess|fail' = 1
            }
            $argOf = { param($c, $name)
                $els = @($c.CommandElements)
                for ($i = 0; $i -lt $els.Count - 1; $i++) {
                    if ($els[$i] -is [System.Management.Automation.Language.CommandParameterAst] -and $els[$i].ParameterName -eq $name) {
                        $v = $els[$i + 1]
                        if ($v -is [System.Management.Automation.Language.StringConstantExpressionAst]) { return $v.Value }
                        return $v.Extent.Text
                    }
                }
                ''
            }
            $found = @{}
            $bare = foreach ($rel in $files) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($pathOf[$rel], [ref]$null, [ref]$null)
                foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-VmfEvent' }, $true)) {
                    $fn = $c.Parent; while ($fn -and -not ($fn -is [System.Management.Automation.Language.FunctionDefinitionAst])) { $fn = $fn.Parent }
                    if ($fn.Name -eq 'Invoke-VmfStepPrecheck') { continue }
                    $key = "$rel|$($fn.Name)|$(& $argOf $c 'Step')|$(& $argOf $c 'Outcome')"
                    $found[$key] = 1 + $(if ($found.ContainsKey($key)) { $found[$key] } else { 0 })
                    if (-not $kept.ContainsKey($key) -or $found[$key] -gt $kept[$key]) { "$rel line $($c.Extent.StartLineNumber) in $($fn.Name) ($key)" }
                }
            }
            @($bare) | Should -BeNullOrEmpty
            # STEP-LOG-2 review: and no line goes to the run history around both
            # writers - a bare append to logs/events.jsonl. Only EventLog.ps1
            # (not scanned) may append there.
            $around = foreach ($rel in $files) {
                $ast = [System.Management.Automation.Language.Parser]::ParseFile($pathOf[$rel], [ref]$null, [ref]$null)
                foreach ($c in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Add-VmfStoreLine' }, $true)) {
                    if ($c.Extent.Text -match 'events') { "$rel line $($c.Extent.StartLineNumber)" }
                }
            }
            @($around) | Should -BeNullOrEmpty
            # Each kept line is still there, so the list cannot outlive its reason.
            foreach ($k in $kept.Keys) { $found[$k] | Should -Be $kept[$k] -Because "$k is kept as a throwing write" }
            # And the kept ones are still there, so this test cannot pass by finding nothing.
            $sm = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path (Join-Path $module 'Private/engine/StateMachine.ps1')).Path, [ref]$null, [ref]$null)
            $loop = $sm.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-VmfStateMachine' }, $true)
            @($loop.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-VmfEvent' }, $true)).Count | Should -Be 0 -Because 'STEP-LOG-3: targetKept writes through Write-VmfStepLine too'
            $pre = $sm.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-VmfStepPrecheck' }, $true)
            @($pre.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-VmfEvent' }, $true)).Count | Should -BeGreaterThan 0 -Because 'PRECHECK stays a throwing write'
            @($loop.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Write-VmfStepLine' }, $true)).Count | Should -BeGreaterThan 5
        }
    }

    Context 'Fused prep-stop guard' {
        It 're-preps when the pre-deallocate verify finds the guest regressed' {
            Script:MockHappyAzureOps
            # By the step and how often the STOPPED verify has run, not by a
            # count of every call (VERIFY-FP-FLAKY-1): a retried GUEST_PREP
            # asks again, and a count gave both NEEDS_PREP answers to it, so
            # the guard this test is about never fired.
            #   GUEST_PREP, first visit: NEEDS_PREP -> triggers fix
            #   STOPPED verify, first:   NEEDS_PREP -> regression! back to GUEST_PREP
            #   GUEST_PREP again:        READY
            #   STOPPED verify again:    READY -> proceed
            $script:stoppedVerifies = 0
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'Test-NvmeReady.ps1' {
                        $step = Script:EngineStep
                        if ($step -eq 'STOPPED') { $script:stoppedVerifies++ }
                        $r = if (($step -eq 'STOPPED' -and $script:stoppedVerifies -eq 1) -or
                                 ($step -eq 'GUEST_PREP' -and $script:stoppedVerifies -eq 0)) { 'NEEDS_PREP' } else { 'READY' }
                        [pscustomobject]@{ result = $r; checks = @(); warnings = @() }
                    }
                    'Set-NvmeReady.ps1'        { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                    'Test-TempDiskContent.ps1' { [pscustomobject]@{ result = 'READY'; checks = @(); warnings = @() } }
                    'Move-Pagefile.ps1'        { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                    'Install-TempDiskInit.ps1' { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                    'Test-GuestValidation.ps1' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' }); warnings = @() } }
                    # UPST-2: the first boot on NVMe resets the I/O timeout, so
                    # STARTING puts it back before VALIDATING judges anything.
                    'Repair-NvmeIoTimeout.ps1' { [pscustomobject]@{ result = 'FIXED'; checks = @(@{ name = 'fact:ControlSet001.ioTimeoutBefore'; status = 'INFO'; detail = '10' }); warnings = @() } }
                    'Test-ManaReady.ps1'       { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana adapter bound'; status = 'PASS' }); warnings = @() } }
                    # MANA-WIN-1: the driver store already has MANA - and on
                    # the second visit it would, after any install.
                    'Install-ManaDriver.ps1'   { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                }
            }

            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'MIGRATED'
            $guestPreps = @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' })
            @($guestPreps).Count | Should -BeGreaterOrEqual 2 -Because 'the fused guard must send the VM back for re-prep'
            @($final.history | Where-Object { $_.state -eq 'GUEST_PREP' -and [string]$_.detail -match 'Pre-deallocate verify' }).Count | Should -Be 1 -Because 'it is the STOPPED verify that sent it back, not a retry'
        }
    }

    Context 'Failure handling and rollback' {
        It 'a boot failure reverts to the original size and controller (Path A)' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'agent did not report Ready - possible boot failure' }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{ screenshotUri = 'https://x/screenshot.bmp' } }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            # Rollback = second Set-VmfVmSizeAndController call with the ORIGINAL size
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -ParameterFilter {
                $Size -eq 'Standard_D2s_v4' -and $Controller -eq 'SCSI'
            } -Times 1 -Exactly
            # Boot-diag evidence captured
            @(Get-ChildItem (Join-Path $script:runPath 'evidence') -Filter 'bootdiag-*').Count | Should -Be 1
        }

        It 'a stale plan asking for the removed hold STILL rolls back' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'boot failure' }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{ screenshotUri = 'x' } }

            # FAIL-1: `bootFailure: hold` used to leave a machine on hardware
            # it never booted on. The lever is gone from the contract, but a
            # plan written before that still carries the key - and it must not
            # resurrect the behaviour. Any failure puts the machine back.
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A' -Policy @{ bootFailure = 'hold' }
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -ParameterFilter {
                $Size -eq 'Standard_D2s_v4' -and $Controller -eq 'SCSI'
            } -Times 1 -Exactly
            $last = @($final.history)[-1]
            $last.machineState | Should -Be 'restored'
            $last.reasonCode | Should -Be 'bootFailedAfterConversion'
        }

        It 'the rollback restores the PRISTINE DISK, not just the hardware' {
            # An explicit ruling. Reverting size and controller alone
            # leaves everything guest prep wrote - the boot-driver registry
            # across every ControlSet, the pagefile moved off D:, the temp-disk
            # task. That is "nearly as it was", and nearly is what this model
            # exists to avoid.
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'boot failure' }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{} }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'FAILED_ROLLED_BACK'

            # A disk built from the PRISTINE snapshot, and attached.
            $pristine = $final.safety.pristineSnapshotId
            $pristine | Should -Not -BeNullOrEmpty
            Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -ParameterFilter {
                $SnapshotId -eq $pristine
            } -Times 1 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
        }

        It 'evidence is captured BEFORE the machine is put back' {
            # This ordering is what makes universal rollback safe to adopt: the
            # console output of a machine that would not boot survives, so
            # nothing diagnostic is lost by returning it to how it was.
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'boot failure' }
            $script:diagBeforeSwap = $null
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $script:diagBeforeSwap = $script:sawDiag }
            $script:sawDiag = $false
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { $script:sawDiag = $true; @{} }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            } | Out-Null

            $script:diagBeforeSwap | Should -BeTrue -Because 'the evidence must exist before the disk is swapped back'
        }

        It 'a failure that cannot collect evidence still puts the machine back' {
            # Best effort by design. Losing a screenshot must never cost the
            # machine its rollback.
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'boot failure' }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { throw 'boot diagnostics unavailable' }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            @($final.history)[-1].machineState | Should -Be 'restored'
        }

        It 'failed rollback lands in FAILED_NEEDS_ATTENTION with both errors recorded' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'boot failure' }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{} }
            # Rollback path calls Stop-VmfVmDeallocated first - make it fail.
            # The stops before it are SAFETY_PRISTINE's and STOPPED's; the
            # rollback runs while the state is still STARTING. Picked by the
            # step, not by a count (VERIFY-FP-FLAKY-1): a retried
            # SAFETY_PRISTINE stops again, and a count then failed STOPPED.
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
                if ((Script:EngineStep) -notin @('SAFETY_PRISTINE', 'STOPPED')) { throw 'rollback stop failed' }
            }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            $last = @($final.history)[-1]
            $last.detail | Should -Match 'the rollback also failed'
            $last.detail | Should -Match 'boot failure'
            # The ONE state that may not claim "as it was".
            $last.machineState | Should -Be 'changed'
            $last.reasonCode | Should -Be 'rollbackFailed'
        }

        It 'a failed PRISTINE copy stops the migration before anything is changed' {
            # NEW since the pristine copy became universal, and worth asserting
            # on its own: it is now the FIRST thing that touches the machine, so
            # a stop failure here means nothing has been modified at all. If the
            # copy cannot be taken, the migration must not continue - that is
            # the point of making it universal.
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'did not reach PowerState/deallocated (timeout)' }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -BeIn @('FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION')
            # nothing was converted, and no guest change was attempted
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0
        }

        It 'deallocation failure restarts the VM untouched (FAILED_ROLLED_BACK)' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
            }
            # The pristine stop must SUCCEED so this still tests what it says:
            # the deallocation before conversion failing. Picked by the step,
            # not by a count (VERIFY-FP-FLAKY-1).
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
                if ((Script:EngineStep) -eq 'STOPPED') { throw 'did not reach PowerState/deallocated (timeout)' }
            }

            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0
            Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1
        }
    }

    Context 'Parking and exclusion' {
        It 'ADE-encrypted VM parks as NEEDS_DECISION before any mutation' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $true }

            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].detail | Should -Match 'Disk Encryption'
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
        }

        It 'platform-managed member is SKIPPED' {
            Script:MockHappyAzureOps
            $plan = Script:NewPlanEntry
            $plan.assessment.platformManaged = $true
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'SKIPPED'
        }

        # REBUILD-MOVE-HOST-1: a machine with hibernation enabled, or on a
        # dedicated host, is outside the scope of this tool. A plan made before
        # the scan excluded it stops at Checking, before any copy and any stop.
        It 'a machine with hibernation enabled stops at Checking, untouched: no copy, no stop' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Get-AzVM {
                $v = Script:NewFakeAzVm
                $v.AdditionalCapabilities = [pscustomobject]@{ UltraSSDEnabled = $false; HibernationEnabled = $true }
                $v
            }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].reasonCode | Should -Be 'hibernationEnabled'
            @($final.history)[-1].machineState | Should -Be 'untouched'
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
        }

        It 'a machine on a dedicated host stops at Checking, untouched: no copy, no stop' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Get-AzVM {
                $v = Script:NewFakeAzVm
                $v | Add-Member -NotePropertyName Host -NotePropertyValue ([pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/hostGroups/hg1/hosts/host1' }) -Force
                $v
            }
            $plan = Script:NewPlanEntry
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].reasonCode | Should -Be 'dedicatedHost'
            @($final.history)[-1].detail | Should -Match "dedicated host 'host1'"
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
        }

        # CLUSTER-DETECT-1: a cluster node that Azure has no record of stops
        # at Checking, before any safety copy and any stop. The machine is
        # untouched, and nothing else ran in it.
        It 'a Windows failover cluster node stops at Checking, untouched: no copy, no stop, no preparation' {
            Script:MockHappyAzureOps -RealClusterCheck
            $global:smCluster = [System.Collections.Generic.List[string]]::new()
            try {
                Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                    $global:smCluster.Add($ScriptName)
                    switch ($ScriptName) {
                        'Test-ClusterNode.ps1' { [pscustomobject]@{ schema = 'vmf.guest/4'; result = 'READY'; checks = @(); warnings = @()
                                facts = [pscustomobject]@{ os = 'Windows'; clusterService = 'running'; clusterKey = 'yes'; sqlHadr = 'no' } } }
                        default { throw "unexpected guest script $ScriptName" }
                    }
                }
                $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A'
                $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                    Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
                }
                $final.state | Should -Be 'NEEDS_DECISION'
                $last = @($final.history)[-1]
                $last.reasonCode | Should -Be 'clusterNode'
                $last.machineState | Should -Be 'untouched'
                $last.detail | Should -Match 'ClusSvc'
                @($global:smCluster) | Should -Be @('Test-ClusterNode.ps1')
                Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0 -Exactly
                Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
            }
            finally { Remove-Variable smCluster -Scope Global -ErrorAction SilentlyContinue }
        }

        # PRECHECK-WORKLOAD-1: a plan from an assessment made before
        # DETECT-PATTERNS-1 carries no shared disk and no appliance blocker.
        # Checking asks Azure again, and the machine stops untouched.
        It 'a plan from an older assessment, on a machine with a shared disk now, stops at Checking untouched: no copy, no stop, no script' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Get-AzVM {
                $v = Script:NewFakeAzVm
                $v.StorageProfile.DataDisks = @([pscustomobject]@{ Lun = 0; Name = 'vm-quorum'; Caching = 'None'; DiskSizeGB = 8; DeleteOption = 'Detach'
                        ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-quorum'; StorageAccountType = 'Premium_LRS' } })
                $v
            }
            Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ($DiskId -match 'vm-quorum') { 2 } else { 1 } }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "unexpected guest script $ScriptName" }
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            $last = @($final.history)[-1]
            $last.reasonCode | Should -Be 'sharedDisk'
            $last.machineState | Should -Be 'untouched'
            $last.detail | Should -Match "'vm-quorum' on LUN 0 has maxShares 2"
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        }

        It 'a plan from an older assessment, on a storage appliance, stops at Checking untouched' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Get-AzVM {
                $v = Script:NewFakeAzVm
                $v.StorageProfile.ImageReference = [pscustomobject]@{ Publisher = 'rubrik-inc'; Offer = 'rubrik-cloud-cluster'; Sku = 'cc'; Id = $null; CommunityGalleryImageId = $null; SharedGalleryImageId = $null }
                $v
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "unexpected guest script $ScriptName" }
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].reasonCode | Should -Be 'storageAppliance'
            @($final.history)[-1].machineState | Should -Be 'untouched'
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        }

        # NVA-PRECHECK-1: a plan from an assessment made before NVA-PLAN-1 has
        # no blocker on a network virtual appliance made from a gallery copy of
        # its Marketplace image. Checking reads the purchase plan again.
        It 'a plan from an older assessment, on a gallery firewall with a Marketplace plan, stops at Checking untouched: no copy, no stop, no script' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Get-AzVM {
                $v = Script:NewFakeAzVm
                $v.StorageProfile.ImageReference = [pscustomobject]@{ Publisher = $null; Offer = $null; Sku = $null
                    Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/galleries/g/images/fw/versions/1.0.0'
                    CommunityGalleryImageId = $null; SharedGalleryImageId = $null }
                $v | Add-Member -NotePropertyName Plan -NotePropertyValue ([pscustomobject]@{ Name = 'byol'; Publisher = 'paloaltonetworks'; Product = 'vmseries-flex'; PromotionCode = $null }) -Force
                $v
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "unexpected guest script $ScriptName" }
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            $last = @($final.history)[-1]
            $last.reasonCode | Should -Be 'networkVirtualAppliance'
            $last.machineState | Should -Be 'untouched'
            $last.detail | Should -Match "plan\.product 'vmseries-flex'"
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        }

        # Review of PRECHECK-WORKLOAD-1: an appliance is asked about with the
        # other out-of-scope stops, so it never first gets a stop a person can
        # accept, and nothing runs inside it.
        It 'an appliance whose target requires accelerated networking it has off stops as an appliance: no decision stop first, and no RunCommand' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $false } }
            Mock -ModuleName VmMigrationFactory Get-AzVM {
                $v = Script:NewFakeAzVm
                $v.StorageProfile.ImageReference = [pscustomobject]@{ Publisher = 'rubrik-inc'; Offer = 'rubrik-cloud-cluster'; Sku = 'cc'; Id = $null; CommunityGalleryImageId = $null; SharedGalleryImageId = $null }
                $v
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "unexpected guest script $ScriptName" }
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history | Where-Object { $_.reasonCode } | ForEach-Object reasonCode) | Should -Be @('storageAppliance')
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts -Times 0 -Exactly
        }

        It 'a machine that is not a cluster node goes on and moves' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'cluster-node-check.sh' { [pscustomobject]@{ schema = 'vmf.guest/4'; result = 'READY'; checks = @(); warnings = @()
                            facts = [pscustomobject]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                    # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                    'sriov-unmanaged-check.sh' { [pscustomobject]@{ schema = 'vmf.guest/7'; result = 'READY'; checks = @(); warnings = @(); facts = [pscustomobject]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                    'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                    'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                    'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                    'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                    default             { throw "unexpected guest script $ScriptName" }
                }
            }
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -ParameterFilter { $ScriptName -eq 'cluster-node-check.sh' } -Times 1 -Exactly
        }

        It 'a cluster check whose Run Command fails is tried again, then the machine stops untouched - never moved as if alone' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                if ($ScriptName -eq 'Test-ClusterNode.ps1') { throw 'RunCommand on vm-under-test returned no result - verify the VM is running.' }
                throw "unexpected guest script $ScriptName"
            }
            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            @($final.history)[-1].machineState | Should -Be 'untouched'
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -ParameterFilter { $ScriptName -eq 'Test-ClusterNode.ps1' } -Times 2 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        }

        # CLUSTER-NOT-RUNNING-1 (2026-10-31: start it, check, put it back).
        It 'a deallocated cluster node is started for the check, deallocated again, and stops at Checking untouched' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                if ($ScriptName -eq 'cluster-node-check.sh') {
                    return [pscustomobject]@{ schema = 'vmf.guest/4'; result = 'READY'; checks = @(); warnings = @()
                        facts = [pscustomobject]@{ os = 'Linux'; pacemaker = 'active'; corosync = 'active'; sqlHadr = 'no' } }
                }
                throw "unexpected guest script $ScriptName"
            }
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].reasonCode | Should -Be 'clusterNode'
            @($final.history)[-1].machineState | Should -Be 'untouched'
            Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 1 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0 -Exactly
            $final.captured.clusterCheckPower.status | Should -Be 'putBack'
        }

        # Re-review of CLUSTER-NOT-RUNNING-1: every other stop at Checking comes
        # before the cluster check, so a machine that parks for one of them is
        # never started, and stays as it was.
        It 'a deallocated machine that stops for accelerated networking is never started, and stays deallocated' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Resolve-VmfAcceleratedNetworkingForMove {
                @{ Stop = $true; Reason = 'acceleratedNetworkingRequired'; Detail = 'The target size requires accelerated networking.' }
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { throw "unexpected guest script $ScriptName" }
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].reasonCode | Should -Be 'acceleratedNetworkingRequired'
            Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0 -Exactly
            $final.captured.PSObject.Properties['clusterCheckPower'] | Should -BeNullOrEmpty
        }

        It 'a deallocated machine that is not a cluster node is started for the check and moves, as it did before the check existed' {
            Script:MockHappyAzureOps -RealClusterCheck
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'cluster-node-check.sh' { [pscustomobject]@{ schema = 'vmf.guest/4'; result = 'READY'; checks = @(); warnings = @()
                            facts = [pscustomobject]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                    # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                    'sriov-unmanaged-check.sh' { [pscustomobject]@{ schema = 'vmf.guest/7'; result = 'READY'; checks = @(); warnings = @(); facts = [pscustomobject]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                    'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                    'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                    'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                    'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                    default             { throw "unexpected guest script $ScriptName" }
                }
            }
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $final.captured.clusterCheckPower.status | Should -Be 'goingOn'
            $final.captured.clusterCheckPower.power | Should -Be 'PowerState/deallocated'
        }

        It 'non-standard D:\ data with park policy stops before conversion' {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'Test-NvmeReady.ps1' { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                    # TEMPCHECK-FIRST-1: the read-only check reports the files.
                    'Test-TempDiskContent.ps1' { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @('D:\CustomerData') } }
                    default              { [pscustomobject]@{ result = 'PASS'; checks = @(); warnings = @() } }
                }
            }

            $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'scsi-temp' -TargetArch 'nvme-temp' -Policy @{ onDDataFound = 'stop' }
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test'
            }

            $final.state | Should -Be 'NEEDS_DECISION'
            @($final.history)[-1].detail | Should -Match 'CustomerData'

            # It is NOT converted - that is what "stops before conversion" means.
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0
            # TEMPCHECK-FIRST-1 (one change window): and NOTHING inside the
            # machine was changed first - no NVMe driver setting, no page file.
            Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm -Times 0 -ParameterFilter { $ScriptName -in @('Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1') }

            # TEMPCHECK-FIRST-1: and it is NOT stopped either. The files are asked
            # about in PRECHECK, while the machine runs - the pristine copy's stop
            # (deallocation) can empty the temporary disk, so asking after it
            # could find nothing because it was already lost. The stop says the
            # machine is untouched, because it is.
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
            Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 0
            @($final.history)[-1].machineState | Should -Be 'untouched'
        }
    }
}

Describe 'VAL-1: MANA validation on Boost targets' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-val1-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'val1-test' | Out-Null
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'fails validation when NEITHER MANA nor an SR-IOV VF is bound on an NVMe target' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                # AN-KEEP-1: the kernel HAS a MANA driver, so the machine moves
                # and the check below is what fails it. With no driver at all it
                # now stops before the move (the AN-KEEP-1 Describe below).
                'mana-check.sh'     {
                    if ((Script:EngineStep) -eq 'VALIDATING') { $global:smAnReads++ }
                    [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(@{ name = 'mana module available'; status = 'PASS' }); warnings = @() }
                }
                default             { throw "unexpected guest script $ScriptName" }
            }
        }
        $global:smAnReads = 0
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
        }
        $validatingReads = $global:smAnReads
        Remove-Variable smAnReads -Scope Global -ErrorAction SilentlyContinue
        # FAIL-1: a machine that fails validation is put back, not left on
        # hardware it did not pass on. The check is what this test is about;
        # the terminal state just follows the universal rule now.
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        # AN-AMDV7-VF-GAP-1: only after the wait for the adapter, which the stop names.
        @($final.history)[-1].detail | Should -BeLike 'The Verifying step failed, and the product rolled the machine back to how it was: The accelerated networking adapter did not become ready in 15 minutes. The product checked it 32 times, and found no MANA interface and no SR-IOV virtual function.*'
        @($final.history)[-1].reasonCode | Should -Be 'validationFailedAfterConversion'
        # 31 reads in the step's first attempt, and one in its retry - not a second 15 minutes.
        $validatingReads | Should -Be 32
    }

    It 'AN-AMDV7-VF-GAP-1: kill and resume during the wait - the next worker continues the same wait, with no attempt used and no read counted twice' {
        Script:MockHappyAzureOps
        $global:smAnReads = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                'mana-check.sh' {
                    if ((Script:EngineStep) -ne 'VALIDATING') {
                        return [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana module available'; status = 'PASS' }); warnings = @() }
                    }
                    $global:smAnReads++
                    # The worker loses its lease on the fourth read of the wait.
                    if ($global:smAnReads -eq 4) { throw "Lease for 'vm-under-test' is held by 'worker-2', not 'worker-1' - abandon this VM." }
                    # The virtual function arrives on the sixth read.
                    if ($global:smAnReads -ge 6) { return [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth1'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                    [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'mana module available'; status = 'PASS' }); warnings = @() }
                }
                default { throw "unexpected guest script $ScriptName" }
            }
        }
        try {
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
            } } | Should -Throw '*abandon this VM*'
            $mid = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; vm = $plan.vmId } { Read-VmfStateDoc -RunPath $rp -VmId $vm }
            $mid.state | Should -Be 'VALIDATING'
            $mid.captured.anAdapterWait.reads | Should -Be 3 -Because 'three reads finished before the worker stopped'
            [int]$(if ($mid.attempts.PSObject.Properties['VALIDATING']) { $mid.attempts.VALIDATING } else { 0 }) | Should -Be 0 -Because 'a lost lease is not a failed attempt'

            # The next worker resumes the machine.
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $final.captured.PSObject.Properties['anAdapterWait'] | Should -BeNullOrEmpty -Because 'the wait ended'
            [int]$(if ($final.attempts.PSObject.Properties['VALIDATING']) { $final.attempts.VALIDATING } else { 0 }) | Should -Be 0
            $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp } | ForEach-Object { [string]$_.detail })
            @($lines | Where-Object { $_ -like 'The accelerated networking adapter is not ready yet.*' }) | Should -HaveCount 1
            @($lines | Where-Object { $_ -like 'The accelerated networking adapter is still not ready. The product continues the wait that started at *' }) | Should -HaveCount 1
            # Reads 1-3 before the stop; read 4 threw and is not counted; reads 5 and 6 after it.
            @($lines | Where-Object { $_ -match '^The accelerated networking adapter is ready after \d+ seconds\. The product checked it 5 times\.$' }) | Should -HaveCount 1
        }
        finally { Remove-Variable smAnReads -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'passes validation on an SR-IOV (Mellanox) host where MANA is absent (REH-2: E2ads_v6/AMD)' {
        # Some v6 clusters serve accelerated networking via SR-IOV VF instead of
        # MANA. Networking is accelerated and healthy - the engine must accept
        # the fabric it finds and record which one, not hard-require MANA.
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                # AN-KEEP-1: this fixture used to say the kernel had NO MANA
                # driver. It now does, so the test keeps testing what it is about
                # - either fabric passes - and the no-driver case has its own
                # Describe below, under the rule that now applies to it.
                'mana-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(
                                        @{ name = 'mana module available'; status = 'PASS' },
                                        @{ name = 'sriov vf bound'; status = 'PASS'; detail = 'eth1 (mlx5_core)' }
                                      ); warnings = @() } }
                default             { throw "unexpected guest script $ScriptName" }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
        }
        $final.state | Should -Be 'MIGRATED'
        # fabric recorded for the report/operator
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            $fabricEvents = @(Read-VmfEvents -RunPath $rp -Step 'validate' | Where-Object { $_.detail -match 'SR-IOV' })
            $fabricEvents.Count | Should -BeGreaterThan 0
        }
    }

    Context 'AN-TRAFFIC-VERIFY-1: "in use" only when the virtual function counters show traffic' {
        BeforeEach {
            Script:MockHappyAzureOps
            Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
                switch ($ScriptName) {
                    'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                    'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                    'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                    'mana-check.sh' {
                        $checks = @(@{ name = 'mana module available'; status = 'PASS' })
                        if ((Script:EngineStep) -ne 'VALIDATING') { return [pscustomobject]@{ result = 'READY'; checks = $checks; warnings = @() } }
                        $checks += @{ name = $global:smAtvAdapter; status = 'PASS'; detail = 'using MANA driver' }
                        $facts = [pscustomobject]@{ os = 'Linux' }
                        if ($global:smAtvTraffic) {
                            $facts | Add-Member -NotePropertyName vfTraffic -NotePropertyValue $global:smAtvTraffic
                            $checks += @{ name = 'vf carrying traffic (eth0)'; status = 'INFO'; detail = "vf_rx_packets=0 vf_tx_packets=0 ($global:smAtvTraffic)" }
                        }
                        [pscustomobject]@{ result = 'READY'; checks = $checks; facts = $facts; warnings = @() }
                    }
                    default { throw "unexpected guest script $ScriptName" }
                }
            }
            $global:smAtvAdapter = 'interface enP1s1'
        }
        AfterEach { Remove-Variable smAtvTraffic, smAtvAdapter -Scope Global -ErrorAction SilentlyContinue }

        It 'MANA present and its counters show no traffic: Verifying fails, the machine is rolled back, and the stop says why' {
            $global:smAtvTraffic = 'no'
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
            }
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            @($final.history)[-1].reasonCode | Should -Be 'validationFailedAfterConversion'
            @($final.history)[-1].detail | Should -BeLike 'The Verifying step failed, and the product rolled the machine back to how it was: The accelerated networking adapter is present, but its packet counters showed no traffic in 15 minutes. The product checked it 32 times.*'
            $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp } | ForEach-Object { [string]$_.detail })
            @($lines | Where-Object { $_ -match 'accelerated networking is in use|Accelerated networking is in use' }) | Should -HaveCount 0 -Because 'never said of a machine whose adapter carried no traffic'
        }

        It 'MANA present with traffic: the machine migrates, and the "in use" line is written' {
            $global:smAtvTraffic = 'yes'
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $ev = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp -Step 'validate' })
            @($ev | Where-Object { $_.detail -eq 'The network adapter is MANA, and accelerated networking is in use.' -and $_.outcome -eq 'ok' }) | Should -HaveCount 1
        }

        It 'an SR-IOV virtual function with traffic: the machine migrates, and its "in use" line is written' {
            $global:smAtvTraffic = 'yes'
            $global:smAtvAdapter = 'sriov vf bound enP1s1'
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $ev = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp -Step 'validate' })
            @($ev | Where-Object { $_.detail -like 'Accelerated networking is in use on an SR-IOV virtual function that is not MANA, on this host: *' }) | Should -HaveCount 1
        }

        It 'counters the guest could not read: the machine migrates, a warning says so, and nothing says "in use"' -ForEach @(
            @{ adapter = 'interface enP1s1'; line = 'The network adapter is MANA. The product could not read its traffic counters, so it cannot say that accelerated networking is in use.' },
            @{ adapter = 'sriov vf bound enP1s1'; line = 'The network adapter is an SR-IOV virtual function that is not MANA, on this host: using MANA driver. The product could not read its traffic counters, so it cannot say that accelerated networking is in use.' }) {
            $global:smAtvTraffic = 'unknown'
            $global:smAtvAdapter = $adapter
            $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
            $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'val1-test'
            }
            $final.state | Should -Be 'MIGRATED'
            $ev = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp -Step 'validate' })
            @($ev | Where-Object { $_.detail -eq $line -and $_.outcome -eq 'warn' }) | Should -HaveCount 1
            @($ev | Where-Object { $_.detail -match '(?i)and accelerated networking is in use|^Accelerated networking is in use' }) | Should -HaveCount 0
        }
    }
}

Describe 'AN-KEEP-1: a kernel with NO MANA driver, on a machine that uses accelerated networking' {
    # REH-2's machine, as it really was: no MANA driver in the kernel, and a v6
    # host that served accelerated networking through a Mellanox virtual
    # function instead. The old VAL-1 fixture migrated it straight through.
    # Now the product stops first, because on a MANA host the same machine
    # would have no working network. AN-PROCEED-NETVSC-1 (2026-11-06):
    # nobody may accept that - an earlier plan's Continue stops it too.
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ank-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'ank-test' | Out-Null
        }
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                'mana-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(
                                        @{ name = 'mana module available'; status = 'WARN' },
                                        @{ name = 'sriov vf bound'; status = 'PASS'; detail = 'eth1 (mlx5_core)' }
                                      ); warnings = @() } }
                default             { throw "unexpected guest script $ScriptName" }
            }
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'by default it stops and asks, before the machine is touched' {
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A' -Policy @{}
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'ank-test'
        }
        $final.state | Should -Be 'NEEDS_DECISION'
        @($final.history).state | Should -Not -Contain 'STOPPED' -Because 'the machine must be untouched'
    }

    It 'AN-PROCEED-NETVSC-1: an earlier plan''s Continue stops it as well, untouched' {
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A' -Policy @{ onDriverBelowFloor = 'proceed' }
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'ank-test'
        }
        $final.state | Should -Be 'NEEDS_DECISION'
        @($final.history).state | Should -Not -Contain 'STOPPED' -Because 'the machine must be untouched'
    }

    It 'and on a MANA host, where NOTHING binds, Continue does not move it onto the synthetic interface' {
        # No MANA driver and no virtual function: the machine would run on the
        # synthetic interface only. Before the ruling, an approver accepted
        # that and the machine migrated.
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                'mana-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(
                                        @{ name = 'mana module available'; status = 'WARN' },
                                        @{ name = 'sriov vf bound'; status = 'INFO'; detail = 'no SR-IOV VF interface up' }
                                      ); warnings = @() } }
                default             { throw "unexpected guest script $ScriptName" }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A' -Policy @{ onDriverBelowFloor = 'proceed' }
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'ank-test'
        }
        $final.state | Should -Be 'NEEDS_DECISION'
        @($final.history).state | Should -Not -Contain 'STOPPED' -Because 'the machine must be untouched'
    }
}

Describe 'DISK-2: per-disk perf property stripping' {
    It 'nulls DiskIOPSReadWrite/DiskMBpsReadWrite on Ultra/PremiumV2 data disks' {
        InModuleScope VmMigrationFactory {
            $vm = [pscustomobject]@{
                StorageProfile = [pscustomobject]@{
                    DataDisks = @(
                        [pscustomobject]@{ Name = 'ultra0'; DiskIOPSReadWrite = 5000; DiskMBpsReadWrite = 200 },
                        [pscustomobject]@{ Name = 'std1' }   # no perf props at all
                    )
                }
            }
            $out = Clear-VmfDiskPerfProperties -Vm $vm
            $out.StorageProfile.DataDisks[0].DiskIOPSReadWrite | Should -BeNullOrEmpty
            $out.StorageProfile.DataDisks[0].DiskMBpsReadWrite | Should -BeNullOrEmpty
            $out.StorageProfile.DataDisks[1].Name | Should -Be 'std1'
        }
    }

    It 'Set-VmfVmSizeAndController sends a stripped payload to Update-AzVM' {
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            [pscustomobject]@{
                HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_E8bds_v5' }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    DataDisks = @([pscustomobject]@{ Name = 'ultra0'; DiskIOPSReadWrite = 5000; DiskMBpsReadWrite = 200 })
                }
            }
        }
        Mock -ModuleName VmMigrationFactory Update-AzVM {
            if ($null -ne $VM.StorageProfile.DataDisks[0].DiskIOPSReadWrite) {
                throw '409 PropertyChangeNotAllowed: DiskIOPSReadWrite'
            }
            [pscustomobject]@{ StatusCode = 'OK' }
        }
        InModuleScope VmMigrationFactory {
            { Set-VmfVmSizeAndController -ResourceGroupName 'rg' -Name 'vm1' -Size 'Standard_E8ads_v7' -Controller 'NVMe' } |
                Should -Not -Throw
        }
        Should -Invoke -ModuleName VmMigrationFactory Update-AzVM -Times 1 -Exactly
    }
}

Describe 'Direction-aware boot-bus validation' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dir-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'dir-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'SCSI reversion validates when the guest reports a non-NVMe boot bus' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'Test-GuestValidation.ps1' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'boot disk bus'; status = 'INFO'; detail = 'SCSI' }); warnings = @() } }
                default                    { [pscustomobject]@{ result = 'READY'; checks = @(); warnings = @() } }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Windows' -Path 'A' -SourceArch 'nvme-temp' -TargetArch 'scsi-temp'
        $plan.target.controller = 'SCSI'
        $plan.target.size = 'Standard_D2ds_v4'
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'dir-test'
        }
        $final.state | Should -Be 'MIGRATED'
    }

    It 'fails when the reported bus contradicts the target controller' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'non-nvme (/dev/sda1)' }); warnings = @() } }
                default             { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'dir-test'
        }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($final.history)[-1].detail | Should -Match 'report the boot disk on .+, and the disk controller of the target is NVMe'
    }
}

Describe 'AN-1: accelerated networking policy' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-an-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'an-test' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'policy defaults: ensureOn for NVMe targets, preserve for SCSI; explicit wins' {
        InModuleScope VmMigrationFactory {
            $nvmePlan = [pscustomobject]@{ target = [pscustomobject]@{ controller = 'NVMe' }; policy = [pscustomobject]@{} }
            Get-VmfPolicy -PlanEntry $nvmePlan -Name 'acceleratedNetworking' | Should -Be 'ensureOn'
            $scsiPlan = [pscustomobject]@{ target = [pscustomobject]@{ controller = 'SCSI' }; policy = [pscustomobject]@{} }
            Get-VmfPolicy -PlanEntry $scsiPlan -Name 'acceleratedNetworking' | Should -Be 'preserve'
            $override = [pscustomobject]@{ target = [pscustomobject]@{ controller = 'NVMe' }; policy = [pscustomobject]@{ acceleratedNetworking = 'preserve' } }
            Get-VmfPolicy -PlanEntry $override -Name 'acceleratedNetworking' | Should -Be 'preserve'
        }
    }

    It 'enables AN on NICs in the deallocated window when the capture shows it off' {
        Script:MockHappyAzureOps
        # The PRECHECK capture sees AN off; the post-enforcement VALIDATING
        # read sees it on. Picked by the step, not by a count
        # (VERIFY-FP-FLAKY-1): a retried PRECHECK captures again.
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface {
            [pscustomobject]@{ EnableAcceleratedNetworking = ((Script:EngineStep) -ne 'PRECHECK') }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS' }); warnings = @() } }
                default             { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        # DRIFT-11: every v6 size requires accelerated networking, and the capture
        # reads it off, so the plan turns it on as the accepted wave settings do.
        $plan.policy | Add-Member -NotePropertyName acceleratedNetworking -NotePropertyValue 'ensureOn' -Force
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'an-test'
        }
        $final.state | Should -Be 'MIGRATED'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking -ParameterFilter { $Enabled -eq $true } -Times 1
    }

    It 'validation fails under ensureOn when the live NIC flag is off' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface {
            [pscustomobject]@{ EnableAcceleratedNetworking = $false }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }); warnings = @() } }
                default             { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        # DRIFT-11: every v6 size requires accelerated networking, and the capture
        # reads it off, so the plan turns it on as the accepted wave settings do.
        $plan.policy | Add-Member -NotePropertyName acceleratedNetworking -NotePropertyValue 'ensureOn' -Force
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'an-test'
        }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($final.history)[-1].detail | Should -Match 'The check of accelerated networking failed'
    }
}

Describe 'Lease fencing during steps (S3-7 live finding)' {
    # The watchdog may reap a lease mid-step; the next heartbeat then throws
    # "abandon this VM". That is FENCING, not a step failure: the machine must
    # never be rolled back or parked for it - the worker rethrows and the next
    # leaseholder resumes from the checkpointed state doc.
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sm-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'sm-test' | Out-Null
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a lost lease aborts the run without a failure transition or rollback' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() }
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            throw "Lease for 'vm' is held by 'worker-2', not 'worker-1' - abandon this VM."
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
                Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' | Out-Null
            }
        } | Should -Throw '*abandon this VM*'
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
        }
        $doc.state | Should -Not -BeIn @('FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION') `
            -Because 'fencing is not a failure - the next worker resumes this machine'
    }

    It 'clears the azureops heartbeat hook when the run ends' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'     { [pscustomobject]@{ result = 'NEEDS_PREP'; checks = @(); warnings = @() } }
                'nvme-fix.sh'       { [pscustomobject]@{ result = 'NO_CHANGE'; checks = @(); warnings = @() } }
                'guest-validate.sh' { [pscustomobject]@{ result = 'PASS'; checks = @(); warnings = @() } }
                'mana-check.sh'     { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                default             { throw "unexpected guest script $ScriptName" }
            }
        }
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sm-test' `
                -WorkerId 'w1' -Heartbeat { param($a, $b, $c) } | Out-Null
            $script:VmfOpHeartbeat | Should -BeNullOrEmpty
        }
    }
}

Describe 'STORAGE-BEFORE-1: a resumed run still gets a before-state of its volumes' {
    # The before-state was captured in one place, GUEST_PREP. A run resuming
    # past it - a machine already at STOPPED - never had one, and VALIDATING
    # could only say UNKNOWN. These seed the state doc at STOPPED with NO
    # capture, exactly the resume shape, and run the machine from there.

    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sb1-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            Initialize-VmfRun -RunPath $rp -RunId 'sb1' | Out-Null
        }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    BeforeAll {
        # Pester 5 runs a Describe body at DISCOVERY; functions declared there
        # are gone by the time an It runs. Helpers live in BeforeAll, like the
        # file's own NewPlanEntry and MockHappyAzureOps.
    function Script:SeedAtStopped {
        # A REAL doc with one fact missing, not a hand-built one. Run the
        # machine once through the mocks so PRECHECK and GUEST_PREP capture
        # everything they normally do, then rewind the state to STOPPED and
        # strip storageBefore - exactly a run that resumed past the capture, or
        # whose doc predates it. A hand-built doc was too thin for the steps
        # after STOPPED and failed for reasons unrelated to the fix.
        param($Plan, [string]$RunPath)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; plan = $Plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sb1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $plan.vmId
            $doc.state = 'STOPPED'
            $captured = @{}
            foreach ($p in $doc.captured.PSObject.Properties) { if ($p.Name -ne 'storageBefore') { $captured[$p.Name] = $p.Value } }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue $captured -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        # the seeding run's own guest calls must not count
        $script:beforeCalls = 0
    }

    function Script:MockGuestForResume {
        param([string]$Os)
        $script:beforeCalls = 0
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm {
            switch ($ScriptName) {
                'nvme-check.sh'            { $script:beforeCalls++
                    [pscustomobject]@{ result = 'READY'; warnings = @(); checks = @(
                        @{ name = 'lvm root'; status = 'INFO'; detail = 'root is on LVM (/dev/mapper/rootvg-rootlv)' }
                        @{ name = 'lvm topology'; status = 'INFO'; detail = '1 volume group(s), 2 logical volume(s)' }
                        @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
                        @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' }) } }
                'Test-NvmeReady.ps1'       { $script:beforeCalls++
                    [pscustomobject]@{ result = 'READY'; warnings = @(); checks = @(
                        @{ name = 'storage pools'; status = 'INFO'; detail = 'none' }) } }
                'nvme-fix.sh'              { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                'Repair-NvmeIoTimeout.ps1' { [pscustomobject]@{ result = 'FIXED'; checks = @(); warnings = @() } }
                'mana-check.sh'            { [pscustomobject]@{ result = 'READY'; checks = @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }); warnings = @() } }
                'guest-validate.sh'        { [pscustomobject]@{ result = 'PASS'; warnings = @(); checks = @(
                        @{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }
                        @{ name = 'lvm root'; status = 'INFO'; detail = 'root is on LVM (/dev/mapper/rootvg-rootlv)' }
                        @{ name = 'lvm topology'; status = 'INFO'; detail = '1 volume group(s), 2 logical volume(s)' }
                        @{ name = 'lvm volume groups complete'; status = 'INFO'; detail = 'all groups have every disk' }
                        @{ name = 'lvm volumes mounted'; status = 'INFO'; detail = 'every LVM entry in fstab is mounted' }) } }
                'Test-GuestValidation.ps1' { [pscustomobject]@{ result = 'PASS'; warnings = @(); checks = @(
                        @{ name = 'boot disk bus'; status = 'INFO'; detail = 'NVMe' }
                        @{ name = 'storage pools'; status = 'INFO'; detail = 'none' }) } }
                default                    { throw "unexpected guest script $ScriptName" }
            }
        }
    }
    }

    It 'a run resumed at STOPPED with the machine still up reads the volumes BEFORE stopping, and VALIDATING can then judge them' {
        Script:MockHappyAzureOps
        Script:MockGuestForResume -Os 'Linux'
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        Script:SeedAtStopped -Plan $plan -RunPath $script:runPath

        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sb1'
        }

        $final.state | Should -Be 'MIGRATED'
        $script:beforeCalls | Should -Be 1 -Because 'the missing before-state is read exactly once, at STOPPED'
        $final.captured.storageBefore | Should -Not -BeNullOrEmpty
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp }
        @($events | Where-Object { $_.step -eq 'STOPPED' -and $_.detail -match 'read them now, before the machine stopped' }).Count | Should -Be 1
        $verdict = @($events | Where-Object { $_.detail -match 'storage volumes:' })[-1].detail
        $verdict | Should -Match 'storage volumes: MATCH' -Because 'a before now exists, so the comparison is real'
        $verdict | Should -Not -Match 'UNKNOWN'
    }

    It 'a run resumed with the machine ALREADY off says so at STOPPED, and the verdict names the missing side' {
        Script:MockHappyAzureOps
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Script:MockGuestForResume -Os 'Linux'
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        Script:SeedAtStopped -Plan $plan -RunPath $script:runPath

        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sb1'
        }

        $final.state | Should -Be 'MIGRATED'
        $script:beforeCalls | Should -Be 0 -Because 'an off machine cannot be asked, and must not be started to ask it'
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp }
        $warn = @($events | Where-Object { $_.step -eq 'STOPPED' -and $_.outcome -eq 'warn' })
        $warn.Count | Should -Be 1 -Because 'the impossibility is said where it becomes true'
        $warn[0].detail | Should -Match 'cannot read them now'
        $verdict = @($events | Where-Object { $_.detail -match 'storage volumes:' })[-1].detail
        $verdict | Should -Match 'storage volumes: UNKNOWN'
        $verdict | Should -Match 'volumes before the move' -Because 'the verdict names WHICH side is missing'
        $verdict | Should -Not -Match 'before or after'
    }

    It 'and a normal run - GUEST_PREP captured it - does not read the volumes a second time at STOPPED' {
        Script:MockHappyAzureOps
        Script:MockGuestForResume -Os 'Linux'
        $plan = Script:NewPlanEntry -Os 'Linux' -Path 'A'
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sb1'
        }
        $final.state | Should -Be 'MIGRATED'
        $script:beforeCalls | Should -Be 1 -Because 'GUEST_PREP read it; STOPPED found it present and asked nothing'
    }
}
