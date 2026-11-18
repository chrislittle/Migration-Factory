#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# VOLUMES-RETRY-CHECK-1. Decided 2026-11-14: after a
# volumesNotBack stop, the operator mounts the volume inside the machine, then
# selects Try this machine again. The retry FIRST checks that every volume
# mounted before the move is mounted again - the check VOLUMES-ONLINE-1 runs
# after a put-back (on Linux the devices file refresh, then the guest
# validation reading, then the comparison with captured.guestBefore). All
# mounted: the retry goes on as any person's retry - a complete new run with
# new safety copies (SAFETY-RETRY-1). Not all: it stops again with
# volumesNotBack, naming the volumes, and changes nothing in Azure - no copy,
# no stop, and the safety copies and the reading before the move stay on
# record, so Restore this machine and a later retry still have them.
#
# The same first step for the check that could not run (UNKNOWN) after a
# rollback or a restore: the machine is restored, a retry is allowed, and its
# first step is the same check.
#
# What owes the check is a record, volumesCheckOwed (vm-state v50), written in
# the same write as the stop that owes it and removed in the same write as the
# new attempt's re-arm (Clear-VmfRetryState -NewAttempt) - never by the service.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
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
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
}

# The global stand-ins and values go when the file ends. A Get-AzVM stand-in
# left behind gave a later file's Get-AzVM mock this shape, with no -UserData.
AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface', 'function:\VrDoc', 'function:\VrOut', 'function:\VrPending', 'function:\VrPhase' -ErrorAction SilentlyContinue
    Remove-Variable vrFail, vrKill, vrOrder, vrOs, vrPower, vrRunPath, vrValidate -Scope Global -ErrorAction SilentlyContinue
}

Describe 'VOLUMES-RETRY-CHECK-1: the record that owes the check' {
    It 'MISSING owes it as volumesNotBack, UNKNOWN as notChecked, and MATCH removes it' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION' }
            Set-VmfVolumesCheckOwed -Doc $doc -Verdict 'MISSING' -Kind 'rollback'
            $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
            $doc.volumesCheckOwed.kind | Should -Be 'rollback'
            [string]$doc.volumesCheckOwed.tsUtc | Should -Not -BeNullOrEmpty
            Set-VmfVolumesCheckOwed -Doc $doc -Verdict 'UNKNOWN' -Kind 'restore'
            $doc.volumesCheckOwed.reason | Should -Be 'notChecked'
            $doc.volumesCheckOwed.kind | Should -Be 'restore'
            Set-VmfVolumesCheckOwed -Doc $doc -Verdict 'MATCH' -Kind 'restore'
            $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
            Get-VmfVolumesCheckOwed -Doc $doc | Should -BeNullOrEmpty
        }
    }

    It 'no verdict (no check ran) leaves the record as it is' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION' }
            Set-VmfVolumesCheckOwed -Doc $doc -Verdict 'MISSING' -Kind 'rollback'
            Set-VmfVolumesCheckOwed -Doc $doc -Verdict '' -Kind 'restore'
            (Get-VmfVolumesCheckOwed -Doc $doc).reason | Should -Be 'volumesNotBack'
        }
    }

    It 'a person''s new attempt removes it in the same write as the re-arm; the automatic rollback''s re-arm keeps it' {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vrc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } {
                param($rp)
                Initialize-VmfRun -RunPath $rp -RunId 'vrc' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'vrc' -VmId '/vm/1' -Wave 'w1' | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId '/vm/1'
                Set-VmfVolumesCheckOwed -Doc $doc -Verdict 'MISSING' -Kind 'rollback'
                Write-VmfStateDoc -RunPath $rp -Document $doc
                Clear-VmfRetryState -RunPath $rp -VmId '/vm/1' -From 'PRECHECK'
                (Get-VmfVolumesCheckOwed -Doc (Read-VmfStateDoc -RunPath $rp -VmId '/vm/1')).reason | Should -Be 'volumesNotBack'
                Clear-VmfRetryState -RunPath $rp -VmId '/vm/1' -From 'PRECHECK' -NewAttempt
                Get-VmfVolumesCheckOwed -Doc (Read-VmfStateDoc -RunPath $rp -VmId '/vm/1') | Should -BeNullOrEmpty
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'VOLUMES-RETRY-CHECK-1: Try this machine again is allowed for volumesNotBack only' {
    It 'volumesNotBack with the check owed is not held; every other changed stop still is' {
        InModuleScope VmMigrationFactory {
            $owed = [pscustomobject]@{ reason = 'volumesNotBack'; kind = 'rollback'; tsUtc = '2026-11-14T10:00:00Z' }
            $stop = { param($code) [pscustomobject]@{ tsUtc = '2026-11-14T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = $code; machineState = 'changed' } }
            Test-VmfRetryHeld -Doc ([pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; volumesCheckOwed = $owed; history = @(& $stop 'volumesNotBack') }) | Should -BeFalse
            Test-VmfRetryHeld -Doc ([pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; history = @(& $stop 'volumesNotBack') }) | Should -BeTrue -Because 'no record owes the check, so a retry would skip it'
            Test-VmfRetryHeld -Doc ([pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; volumesCheckOwed = $owed; history = @(& $stop 'rollbackFailed') }) | Should -BeTrue
            Test-VmfRetryHeld -Doc ([pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; volumesCheckOwed = $owed; swapPending = [pscustomobject]@{ kind = 'rollback' }; history = @(& $stop 'volumesNotBack') }) | Should -BeTrue
        }
    }

    It 'VOLUMES-NOT-CHECKED-WORDS-1: volumesNotChecked with the check owed is not held either, and without the record it is' {
        InModuleScope VmMigrationFactory {
            $owed = [pscustomobject]@{ reason = 'notChecked'; kind = 'rollback'; tsUtc = '2026-11-15T10:00:00Z' }
            $stop = [pscustomobject]@{ tsUtc = '2026-11-15T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = 'volumesNotChecked'; machineState = 'changed' }
            Test-VmfRetryHeld -Doc ([pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; volumesCheckOwed = $owed; history = @($stop) }) | Should -BeFalse
            Test-VmfRetryHeld -Doc ([pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; history = @($stop) }) | Should -BeTrue
        }
        $cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'retry-held.json') -Raw | ConvertFrom-Json -Depth 20).cases
        @($cases | Where-Object { $_.why -like 'VOLUMES-NOT-CHECKED-WORDS-1*' -and $_.held -eq $false }).Count | Should -BeGreaterOrEqual 1
        @($cases | Where-Object { $_.why -like 'VOLUMES-NOT-CHECKED-WORDS-1*' -and $_.held -eq $true }).Count | Should -BeGreaterOrEqual 1
    }

    It 'the shared fixture has the cases, so the run page decides the same' {
        $cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'retry-held.json') -Raw | ConvertFrom-Json -Depth 20).cases
        @($cases | Where-Object { $_.why -like 'VOLUMES-RETRY-CHECK-1*' }).Count | Should -BeGreaterOrEqual 3
        @($cases | Where-Object { $_.why -like 'VOLUMES-RETRY-CHECK-1*' -and $_.held -eq $false }).Count | Should -BeGreaterOrEqual 1
        @($cases | Where-Object { $_.why -like 'VOLUMES-RETRY-CHECK-1*' -and $_.held -eq $true }).Count | Should -BeGreaterOrEqual 2
    }
}

Describe 'VOLUMES-RETRY-CHECK-1: the retry checks the volumes first' {
    BeforeAll {
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'

        function Script:VrPlan {
            param([string]$Os = 'Linux')
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                    sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
                target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
                path = 'A'; policy = [pscustomobject]@{}; decisions = @()
            }
        }
        function Script:VrFakeVm {
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
        function Global:VrDoc { & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $global:vrRunPath $script:vmId }
        function Global:VrPending { $d = Global:VrDoc; if ($d -and $d.PSObject.Properties['rollbackPending']) { $d.rollbackPending } else { $null } }

        function Script:VrMockAzure {
            param([string]$Found = 'PowerState/running', [string]$Os = 'Linux')
            $global:vrPower = $Found
            $global:vrOrder = [System.Collections.Generic.List[string]]::new()
            $global:vrFail = { param($name) }
            $global:vrOs = $Os
            Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
            Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
            Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { & $global:vrFail 'permissions'; $global:vrOrder.Add('permissions'); @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:vrPower }
            Mock -ModuleName VmMigrationFactory Get-AzVM { Script:VrFakeVm -Os $global:vrOs }
            Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:vrOrder.Add('snapshot'); "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap-$($global:vrOrder.Count)" }
            Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { "$SnapshotId/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
            Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:vrFail 'deallocate'; $global:vrOrder.Add('deallocate'); $global:vrPower = 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:vrFail 'powerOff'; $global:vrOrder.Add('powerOff'); $global:vrPower = 'PowerState/stopped' }
            Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:vrFail 'start'; $global:vrOrder.Add('start'); $global:vrPower = 'PowerState/running' }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { & $global:vrFail 'agentReady'; $global:vrOrder.Add('agentReady') }
            Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:vrOrder.Add("size:$Size") }
            Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm-os'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' } }
            Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
            Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:vrOrder.Add('swapOs') }
            Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
            Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
            Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{ fetchedUtc = '2026-11-14T00:00:00Z' } }
            Mock -ModuleName VmMigrationFactory Get-VmfVmIdentityFacts { [pscustomobject]@{ systemAssigned = $false; principalId = $null; userAssigned = @() } }
            # The retry asks the wave's start gates; this wave can start.
            Mock -ModuleName VmMigrationFactory Get-VmfWaveStartGate { $null }
        }

        function Global:VrOut {
            param([string]$Script, [string]$Result, [object[]]$Checks = @())
            [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
        }
        # The reading of the validation script, by where the engine is: before
        # the move, after it, after a rollback, and at the check of the retry
        # (Checking, while a record owes the check). $global:vrValidate holds
        # the mounted volumes for each.
        function Global:VrPhase {
            $d = Global:VrDoc
            if ($d -and [string]$d.state -eq 'PRECHECK' -and $d.PSObject.Properties['volumesCheckOwed'] -and $d.volumesCheckOwed) { return 'retryCheck' }
            if (Global:VrPending) { return 'afterRollback' }
            if ($d -and [string]$d.state -eq 'VALIDATING') { return 'afterMove' }
            'before'
        }
        function Script:VrMockGuest {
            param([hashtable]$Validate)
            $global:vrValidate = $Validate
            Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
                [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                    Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                    Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
                $name = [string]$ScriptString
                $phase = Global:VrPhase
                $global:vrOrder.Add("script:$name")
                if ($global:vrValidate.ContainsKey("throw:$($phase):$name")) { throw $global:vrValidate["throw:$($phase):$name"] }
                $out = switch ($name) {
                    'cluster-node-check.sh' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; warnings = @()
                            checks = @(@{ name = 'lvm devices file'; status = 'INFO'; detail = 'in use (/etc/lvm/devices/system.devices): 1 physical volume(s), every one found' })
                            facts = [ordered]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                    # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                    'sriov-unmanaged-check.sh' { [ordered]@{ schema = 'vmf.guest/7'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                    'Test-ClusterNode.ps1' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                            facts = [ordered]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } } }
                    'mana-check.sh' { Global:VrOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                    'Test-ManaReady.ps1' { Global:VrOut $name 'READY' @(@{ name = 'mana driver'; status = 'PASS'; detail = 'bound' }) }
                    'Install-ManaDriver.ps1' { Global:VrOut $name 'NO_CHANGE' @(@{ name = 'mana driver in store'; status = 'PASS'; detail = 'present' }) }
                    { $_ -in @('guest-validate.sh', 'Test-GuestValidation.ps1') } {
                        $bus = if ($name -like '*.sh') { @{ name = 'root device bus'; status = 'INFO'; detail = $(if ($phase -eq 'afterMove') { 'nvme (/dev/nvme0n1p1)' } else { 'non-nvme (/dev/sda1)' }) } }
                               else { @{ name = 'boot disk bus'; status = 'INFO'; detail = $(if ($phase -eq 'afterMove') { 'NVMe' } else { 'SCSI' }) } }
                        $global:vrOrder.Add("phase:$phase")
                        Global:VrOut $name 'PASS' @($bus, @{ name = 'mounted volumes'; status = 'INFO'; detail = [string]$global:vrValidate[$phase] })
                    }
                    'lvm-devices-refresh.sh' { $global:vrOrder.Add("refresh:$phase"); Global:VrOut $name 'NO_CHANGE' @(@{ name = 'lvm devices refresh'; status = 'PASS'; detail = 'every physical volume is in the devices file' }) }
                    default { Global:VrOut $name 'READY' }
                }
                $out | ConvertTo-Json -Depth 8 -Compress
            }
        }
        function Script:VrRunMachine {
            param($Plan)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } { param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'vrc-test' }
        }
        function Script:VrWritePlan {
            param($Plan)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; entry = $Plan } {
                param($rp, $entry)
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
            }
        }
        function Script:VrRetry {
            param([string]$ReturnTo)
            $a = @{ RunPath = $script:runPath; PlanPath = (Join-Path $script:runPath 'plan.json'); VmId = $script:vmId; Note = 'the volume is mounted'; ResolvedBy = 'operator@example.com' }
            if ($ReturnTo) { $a.ReturnTo = $ReturnTo }
            Resolve-VmfDecision @a
        }
        function Script:VrLines { param([string]$Step) & (Get-Module VmMigrationFactory) { param($rp, $s) @(Read-VmfEvents -RunPath $rp | Where-Object { [string]$_.step -eq $s }) } $script:runPath $Step }
        function Script:VrAfter([string]$Marker) {
            $all = @($global:vrOrder); $at = [array]::LastIndexOf($all, $Marker)
            @($all | Select-Object -Skip ($at + 1))
        }
        # The first attempt: a volume lost after the move, and still lost
        # after the rollback - the stop volumesNotBack. The machine was found
        # running, so the rollback leaves it running.
        function Script:VrNotBack {
            param([string]$Os = 'Linux', [hashtable]$Validate)
            Script:VrMockAzure -Os $Os
            Script:VrMockGuest $Validate
            $plan = Script:VrPlan -Os $Os
            Script:VrWritePlan $plan
            $first = Script:VrRunMachine $plan
            $first.state | Should -Be 'FAILED_NEEDS_ATTENTION' -Because ([string]@($first.history)[-1].detail)
            @($first.history)[-1].reasonCode | Should -Be 'volumesNotBack'
            $plan
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vrc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:vrRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'vrc-test' | Out-Null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'the stop volumesNotBack owes the check, in the same write, and the retry is allowed' {
        $null = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $doc = Global:VrDoc
        $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
        $doc.volumesCheckOwed.kind | Should -Be 'rollback'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
    }

    It 'the service re-arms the machine but takes no new attempt: the copies, the reading before the move and the record stay until the check passes' {
        $null = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $before = Global:VrDoc
        $r = Script:VrRetry
        $r.NewState | Should -Be 'PRECHECK'
        $doc = Global:VrDoc
        $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
        [string]$doc.safety.pristineSnapshotId | Should -Be ([string]$before.safety.pristineSnapshotId)
        [string]$doc.safety.pristineSnapshotId | Should -Not -BeNullOrEmpty
        $doc.safety.PSObject.Properties['earlierCopies'] | Should -BeNullOrEmpty
        $doc.captured.guestBefore | Should -Not -BeNullOrEmpty
    }

    It 'a retry that skips Checking is refused while the check is owed' {
        $null = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        { Script:VrRetry -ReturnTo 'VALIDATING' } | Should -Throw -ExpectedMessage '400:*'
        (Global:VrDoc).state | Should -Be 'FAILED_NEEDS_ATTENTION'
    }

    It 'every volume mounted again: the check runs first, then the retry goes on as a new attempt with new safety copies' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $firstCopy = [string](Global:VrDoc).safety.pristineSnapshotId
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot; /var/crash'
        $global:vrValidate.afterMove = '/; /boot; /var/crash'
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
        $order = @($global:vrOrder)
        $order[0..4] | Should -Be @('agentReady', 'script:lvm-devices-refresh.sh', 'refresh:retryCheck', 'script:neutral-mark.sh', 'script:guest-validate.sh') -Because "order: $($order -join ', ')"
        [array]::IndexOf($order, 'phase:retryCheck') | Should -BeLessThan ([array]::IndexOf($order, 'permissions'))
        [array]::IndexOf($order, 'phase:retryCheck') | Should -BeLessThan ([array]::IndexOf($order, 'snapshot'))
        $doc = Global:VrDoc
        $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
        @($doc.safety.earlierCopies).Count | Should -Be 1
        [string]@($doc.safety.earlierCopies)[0].pristineSnapshotId | Should -Be $firstCopy
        [string]$doc.safety.pristineSnapshotId | Should -Not -Be $firstCopy -Because 'SAFETY-RETRY-1: a person''s retry takes new copies'
        @(Script:VrLines 'PRECHECK' | Where-Object { $_.detail -match 'Every volume that was mounted before the move is mounted again: /, /boot, /var/crash\.' }) | Should -Not -BeNullOrEmpty -Because ((Script:VrLines 'PRECHECK' | ForEach-Object { "[$($_.outcome)] $($_.detail)" }) -join ' | ')
    }

    It 'a volume still not mounted: it stops again with volumesNotBack, names the volume, and changes nothing' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $was = Global:VrDoc
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot'
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotBack'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'These volumes were mounted before the move and are not mounted now: /var/crash\.'
        @($global:vrOrder | Where-Object { $_ -in @('snapshot', 'deallocate', 'powerOff', 'start', 'swapOs', 'permissions') -or $_ -like 'size:*' }) | Should -BeNullOrEmpty -Because "nothing in Azure changes: $(@($global:vrOrder) -join ', ')"
        $doc = Global:VrDoc
        [string]$doc.safety.pristineSnapshotId | Should -Be ([string]$was.safety.pristineSnapshotId)
        $doc.safety.PSObject.Properties['earlierCopies'] | Should -BeNullOrEmpty
        ($doc.captured.guestBefore | ConvertTo-Json -Depth 10 -Compress) | Should -Be ($was.captured.guestBefore | ConvertTo-Json -Depth 10 -Compress)
        $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse -Because 'the person can mount it and try again'
    }

    It 'the check cannot run (the guest does not answer): it stops again with volumesNotChecked and says why' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate['throw:retryCheck:lvm-devices-refresh.sh'] = 'RunCommand timed out.'
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        # VOLUMES-NOT-CHECKED-WORDS-1: its own reason - nothing found a volume
        # not mounted, because nothing was checked.
        $stop.reasonCode | Should -Be 'volumesNotChecked'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'The product could not check the volumes inside the machine \(RunCommand timed out\)\.'
        $stop.detail | Should -Not -Match 'after the (rollback|restore|retry)' -Because 'the stop says to mount the volume and try again'
        @(Script:VrLines 'PRECHECK' | Where-Object { $_.detail -match 'could not check the volumes' }) | Should -Not -BeNullOrEmpty -Because 'the check writes on the step it runs in'
        @($global:vrOrder | Where-Object { $_ -in @('snapshot', 'deallocate', 'permissions') }) | Should -BeNullOrEmpty
        (Global:VrDoc).volumesCheckOwed | Should -Not -BeNullOrEmpty
    }

    # VOLUMES-RETRY-CHECK-OFF-1: a machine that is not running is started for
    # the check, the way the cluster check starts one (CLUSTER-NOT-RUNNING-1),
    # and returned to the power state it had - whatever the check finds.
    It 'a machine that is Stopped (deallocated), every volume mounted: started, checked, deallocated again, and then the retry goes on' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/deallocated'
        $global:vrValidate.retryCheck = '/; /boot; /var/crash'
        $global:vrValidate.afterMove = '/; /boot; /var/crash'
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
        $order = @($global:vrOrder)
        $order[0..1] | Should -Be @('start', 'agentReady') -Because "order: $($order -join ', ')"
        [array]::IndexOf($order, 'phase:retryCheck') | Should -BeGreaterThan 1
        $back = [array]::IndexOf($order, 'deallocate')
        $back | Should -BeGreaterThan ([array]::IndexOf($order, 'phase:retryCheck')) -Because "order: $($order -join ', ')"
        $back | Should -BeLessThan ([array]::IndexOf($order, 'permissions')) -Because 'the machine is back in its power state before Checking reads it'
        $global:vrPower | Should -Be 'PowerState/deallocated' -Because 'POWER-AFTER-MOVE-1: the move ends in the power state Checking found'
        $lines = @(Script:VrLines 'PRECHECK' | ForEach-Object { [string]$_.detail })
        @($lines | Where-Object { $_ -eq 'Azure shows the machine as Stopped (deallocated). The product starts the machine for the check of the volumes. Then it returns the machine to the power state Stopped (deallocated).' }) | Should -Not -BeNullOrEmpty -Because ($lines -join ' | ')
        $doc = Global:VrDoc
        $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
        $doc.captured.PSObject.Properties['volumesCheckPower'] | Should -BeNullOrEmpty -Because 'the new attempt drops the record of the start for the check'
    }

    It 'a machine that is Stopped (deallocated), a volume still not mounted: started, checked, deallocated again, then the stop - no copy' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/deallocated'
        $global:vrValidate.retryCheck = '/; /boot'
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotBack'
        $stop.machineState | Should -Be 'changed'
        $stop.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
        $stop.detail | Should -Match 'These volumes were mounted before the move and are not mounted now: /var/crash\.'
        $stop.detail | Should -Match 'The product started the machine to run the check, then made it deallocated again\.'
        @($global:vrOrder | Where-Object { $_ -in @('start', 'deallocate') }) | Should -Be @('start', 'deallocate') -Because "order: $(@($global:vrOrder) -join ', ')"
        @($global:vrOrder | Where-Object { $_ -in @('snapshot', 'permissions', 'swapOs') }) | Should -BeNullOrEmpty
        $global:vrPower | Should -Be 'PowerState/deallocated'
        (Global:VrDoc).volumesCheckOwed.reason | Should -Be 'volumesNotBack'
    }

    It 'a machine that is Stopped: it goes back to Stopped, not Stopped (deallocated)' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/stopped'
        $global:vrValidate.retryCheck = '/; /boot'
        $null = Script:VrRunMachine $plan
        @($global:vrOrder | Where-Object { $_ -in @('start', 'deallocate', 'powerOff') }) | Should -Be @('start', 'powerOff')
        $global:vrPower | Should -Be 'PowerState/stopped'
    }

    It 'a machine in another power state (Starting) is not started: the check does not run, and the stop is volumesNotChecked with the power state' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/starting'
        $final = Script:VrRunMachine $plan
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotChecked'
        $stop.detail | Should -Match 'Starting'
        @($global:vrOrder | Where-Object { $_ -like 'script:*' -or $_ -in @('start', 'snapshot', 'deallocate') }) | Should -BeNullOrEmpty
    }

    It 'the start for the check is refused: the machine goes back to its power state, and the stop is volumesNotChecked' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/deallocated'
        $global:vrFail = { param($name) if ($name -eq 'start') { throw 'OperationNotAllowed: the start is refused.' } }
        $final = Script:VrRunMachine $plan
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotChecked'
        $stop.detail | Should -Match 'the start is refused'
        @($global:vrOrder | Where-Object { $_ -like 'script:*' -or $_ -eq 'snapshot' }) | Should -BeNullOrEmpty
        @($global:vrOrder) | Should -Contain 'deallocate' -Because 'a start that failed part way can leave the machine running'
    }

    It 'the return to the power state is refused after a check that passed: the retry stops with powerNotPutBack, the check still owed' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/deallocated'
        $global:vrValidate.retryCheck = '/; /boot; /var/crash'
        $global:vrFail = { param($name) if ($name -eq 'deallocate') { throw 'Conflict: another operation is in progress.' } }
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'powerNotPutBack'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
        $stop.detail | Should -Match 'Every volume that was mounted before the move is mounted again'
        $stop.detail | Should -Match 'could not make it deallocated again'
        @($global:vrOrder | Where-Object { $_ -in @('snapshot', 'permissions') }) | Should -BeNullOrEmpty
        $doc = Global:VrDoc
        $doc.volumesCheckOwed | Should -Not -BeNullOrEmpty -Because 'the new attempt is not taken'
        $doc.safety.PSObject.Properties['earlierCopies'] | Should -BeNullOrEmpty
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
    }

    It 'kill and resume (rule 4): a worker killed after the start for the check puts the machine back on the resume, and does not start it twice' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrPower = 'PowerState/deallocated'
        $global:vrValidate.retryCheck = '/; /boot'
        $global:vrKill = $false
        $global:vrFail = { param($name)
            if ($name -eq 'agentReady' -and (Global:VrPhase) -eq 'retryCheck' -and -not $global:vrKill) {
                $global:vrKill = $true
                throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
            } }
        { Script:VrRunMachine $plan } | Should -Throw '*abandon this VM*'
        $global:vrPower | Should -Be 'PowerState/running' -Because 'the kill came after the start'
        $rec = (Global:VrDoc).captured.volumesCheckPower
        $rec.power | Should -Be 'PowerState/deallocated' -Because 'the power state is on record before the start'
        $rec.status | Should -Be 'started'
        $global:vrOrder.Clear()
        $final = Script:VrRunMachine $plan
        @($final.history)[-1].reasonCode | Should -Be 'volumesNotBack'
        @($global:vrOrder) | Should -Not -Contain 'start' -Because 'the machine runs: the record says this check started it'
        @($global:vrOrder) | Should -Contain 'deallocate'
        $global:vrPower | Should -Be 'PowerState/deallocated' -Because 'the record, not what Azure says now, names the power state to return to'
    }

    It 'a power state the stop could not put back: the check runs first, while the machine runs, and only then does the power state go back' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        & (Get-Module VmMigrationFactory) { param($rp, $id)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            @($d.history)[-1] | Add-Member -NotePropertyName powerNotPutBack -NotePropertyValue 'PowerState/deallocated' -Force
            Write-VmfStateDoc -RunPath $rp -Document $d } $script:runPath $script:vmId
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot; /var/crash'
        $global:vrValidate.afterMove = '/; /boot; /var/crash'
        $null = Script:VrRunMachine $plan
        $order = @($global:vrOrder)
        [array]::IndexOf($order, 'phase:retryCheck') | Should -BeGreaterOrEqual 0 -Because "order: $($order -join ', ')"
        [array]::IndexOf($order, 'phase:retryCheck') | Should -BeLessThan ([array]::IndexOf($order, 'deallocate')) -Because "order: $($order -join ', ')"
    }

    It 'a power state the stop could not put back stays owed when the check stops the retry again' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        & (Get-Module VmMigrationFactory) { param($rp, $id)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            @($d.history)[-1] | Add-Member -NotePropertyName powerNotPutBack -NotePropertyValue 'PowerState/deallocated' -Force
            Write-VmfStateDoc -RunPath $rp -Document $d } $script:runPath $script:vmId
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot'
        $final = Script:VrRunMachine $plan
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'volumesNotBack'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
        @($global:vrOrder) | Should -Not -Contain 'deallocate'
    }
    It 'Windows: only the validation script runs, then the retry goes on' {
        $plan = Script:VrNotBack -Os 'Windows' -Validate @{ before = 'C:\; F:\'; afterMove = 'C:\'; afterRollback = 'C:\' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = 'C:\; F:\'
        $global:vrValidate.afterMove = 'C:\; F:\'
        # These stand-ins give no accelerated networking adapter on Windows, so
        # Verifying rolls the new attempt back; its check then finds every volume.
        $global:vrValidate.afterRollback = 'C:\; F:\'
        $null = Script:VrRunMachine $plan
        @($global:vrOrder | Select-Object -First 3) | Should -Be @('agentReady', 'script:Test-GuestValidation.ps1', 'phase:retryCheck')
        @($global:vrOrder) | Should -Contain 'snapshot' -Because 'the check passed, so the retry took new safety copies'
        (Global:VrDoc).PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
    }

    It 'the check that could not run after the rollback: the machine is rolled back, the check is owed, and the retry checks first' {
        Script:VrMockAzure
        Script:VrMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; 'throw:afterRollback:lvm-devices-refresh.sh' = 'RunCommand timed out.' }
        $plan = Script:VrPlan
        Script:VrWritePlan $plan
        $first = Script:VrRunMachine $plan
        $first.state | Should -Be 'FAILED_ROLLED_BACK'
        $doc = Global:VrDoc
        $doc.volumesCheckOwed.reason | Should -Be 'notChecked'
        $doc.volumesCheckOwed.kind | Should -Be 'rollback'
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot'
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($final.history)[-1].reasonCode | Should -Be 'volumesNotBack'
        @($global:vrOrder | Where-Object { $_ -eq 'snapshot' }) | Should -BeNullOrEmpty
    }

    It 'a rollback whose check found every volume owes nothing' {
        Script:VrMockAzure
        Script:VrMockGuest @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot; /var/crash' }
        $plan = Script:VrPlan
        $first = Script:VrRunMachine $plan
        $first.state | Should -Be 'FAILED_ROLLED_BACK'
        (Global:VrDoc).PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
    }

    It 'kill and resume (rule 4): a worker killed in the check runs the whole check again, and then goes on' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot; /var/crash'
        $global:vrValidate.afterMove = '/; /boot; /var/crash'
        $global:vrKill = $false
        $global:vrFail = { param($name)
            if ($name -eq 'agentReady' -and (Global:VrPhase) -eq 'retryCheck' -and -not $global:vrKill) {
                $global:vrKill = $true
                throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
            } }
        { Script:VrRunMachine $plan } | Should -Throw '*abandon this VM*'
        $doc = Global:VrDoc
        $doc.state | Should -Be 'PRECHECK'
        $doc.volumesCheckOwed | Should -Not -BeNullOrEmpty -Because 'the check did not pass'
        $doc.captured.guestBefore | Should -Not -BeNullOrEmpty
        $global:vrOrder.Clear()
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'MIGRATED'
        @($global:vrOrder | Where-Object { $_ -eq 'phase:retryCheck' }).Count | Should -Be 1
        @((Global:VrDoc).safety.earlierCopies).Count | Should -Be 1
    }

    It 'kill and resume (rule 4): a worker killed after the check passed does not check again and takes the copies once' {
        $plan = Script:VrNotBack -Validate @{ before = '/; /boot; /var/crash'; afterMove = '/; /boot'; afterRollback = '/; /boot' }
        $null = Script:VrRetry
        $global:vrOrder.Clear()
        $global:vrValidate.retryCheck = '/; /boot; /var/crash'
        $global:vrValidate.afterMove = '/; /boot; /var/crash'
        $global:vrKill = $false
        $global:vrFail = { param($name)
            if ($name -eq 'permissions' -and -not $global:vrKill) {
                $global:vrKill = $true
                throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
            } }
        { Script:VrRunMachine $plan } | Should -Throw '*abandon this VM*'
        $doc = Global:VrDoc
        $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
        @($doc.safety.earlierCopies).Count | Should -Be 1
        $global:vrOrder.Clear()
        $final = Script:VrRunMachine $plan
        $final.state | Should -Be 'MIGRATED'
        @($global:vrOrder | Where-Object { $_ -eq 'phase:retryCheck' }) | Should -BeNullOrEmpty
        @((Global:VrDoc).safety.earlierCopies).Count | Should -Be 1 -Because 'the old copies moved once'
    }

    Context 'Restore this machine' {
        BeforeAll {
            $script:rsSub = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute'
            $script:rsVm = "$($script:rsSub)/virtualMachines/app01"
            function Script:VrRestoreRun {
                param([string]$Before, [switch]$Owed)
                $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-vrc-rst-$([guid]::NewGuid().ToString('N').Substring(0,8))"
                InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $script:rsVm; sub = $script:rsSub; before = $Before; owed = [bool]$Owed } {
                    param($rp, $vmId, $sub, $before, $owed)
                    Initialize-VmfRun -RunPath $rp -RunId 'vrc-rst' | Out-Null
                    New-VmfStateDoc -RunPath $rp -RunId 'vrc-rst' -VmId $vmId -Wave 'lab-1' | Out-Null
                    $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
                    $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = "$sub/snapshots/app01-snap"; cloneVmId = $null }) -Force
                    $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                            guestBefore = [pscustomobject]@{ schema = 'vmf.guest/2'; script = 'guest-validate.sh'; version = '1.0.0'; result = 'PASS'; warnings = @()
                                checks = @([pscustomobject]@{ name = 'mounted volumes'; status = 'INFO'; detail = $before }) } }) -Force
                    $doc | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @([pscustomobject]@{ script = 'guest-validate.sh'; version = '1.0.0'; sha256 = ('a' * 64); tsUtc = '2026-11-13T00:00:00Z'; result = 'READING'; evidenceRef = 'evidence/x.txt' }) -Force
                    $doc.state = 'MIGRATED'
                    if ($owed) { Set-VmfVolumesCheckOwed -Doc $doc -Verdict 'MISSING' -Kind 'rollback' }
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
            function Script:VrRestoreAzure {
                $global:vrPower = 'PowerState/running'
                $global:vrOrder = [System.Collections.Generic.List[string]]::new()
                $global:vrFail = { param($name) }
                Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 } }
                Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
                Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
                Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:vrOrder.Add('swapOs') }
                Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
                Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
                Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
                Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
                Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
                Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:vrPower }
                Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:vrOrder.Add('deallocate'); $global:vrPower = 'PowerState/deallocated' }
                Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { $global:vrOrder.Add('powerOff'); $global:vrPower = 'PowerState/stopped' }
                Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:vrOrder.Add('start'); $global:vrPower = 'PowerState/running' }
                Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { $global:vrOrder.Add('agentReady') }
            }
            function Script:VrRestoreDoc { param($rp) & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $rp $script:rsVm }
        }
        AfterEach { if ($script:rsRun -and (Test-Path $script:rsRun)) { Remove-Item $script:rsRun -Recurse -Force } }

        It 'a volume missing after the restore owes the check, and the retry is allowed after it' {
            $script:rsRun = Script:VrRestoreRun -Before '/; /boot; /var/crash'
            Script:VrRestoreAzure
            Script:VrMockGuest @{ before = '/; /boot' }
            { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false } | Should -Throw -ExpectedMessage '*/var/crash*'
            $doc = Script:VrRestoreDoc $script:rsRun
            $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
            $doc.volumesCheckOwed.kind | Should -Be 'restore'
            (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
        }

        It 'a restore whose check finds every volume removes a check owed from before' {
            $script:rsRun = Script:VrRestoreRun -Before '/; /boot; /var/crash' -Owed
            Script:VrRestoreAzure
            Script:VrMockGuest @{ before = '/; /boot; /var/crash' }
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
            (Script:VrRestoreDoc $script:rsRun).PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
        }

        It 'a restore whose check could not run owes the check as notChecked' {
            $script:rsRun = Script:VrRestoreRun -Before '/; /boot; /var/crash'
            Script:VrRestoreAzure
            Script:VrMockGuest @{ before = '/; /boot; /var/crash'; 'throw:before:lvm-devices-refresh.sh' = 'RunCommand timed out.' }
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
            (Script:VrRestoreDoc $script:rsRun).volumesCheckOwed.reason | Should -Be 'notChecked'
        }

        # VOLUMES-RESTORE-MIGRATED-1: Restore this machine on a migrated machine
        # left a volume not mounted. The machine stays MIGRATED, so Try this
        # machine again is not offered. Check the volumes on the machine panel
        # starts the engine operation checkvolumes (Invoke-VmfVolumesCheck): the
        # check of the retry, with no move. Only a check that measures every
        # volume mounted again ends the changed state.
        Context 'Check the volumes (the engine operation checkvolumes)' {
            BeforeAll {
                function Script:VrRestoreMissing {
                    $script:rsRun = Script:VrRestoreRun -Before '/; /boot; /var/crash'
                    Script:VrRestoreAzure
                    Script:VrMockGuest @{ before = '/; /boot' }
                    { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false } | Should -Throw -ExpectedMessage '*/var/crash*'
                    $d = Script:VrRestoreDoc $script:rsRun
                    $d.state | Should -Be 'MIGRATED'
                    @($d.history)[-1].reasonCode | Should -Be 'volumesNotBack'
                    $global:vrOrder.Clear()
                }
                function Script:VrCheck { Invoke-VmfVolumesCheck -RunPath $script:rsRun -VmId $script:rsVm -By 'operator@example.com' -CorrelationId 'op-check-1' -Confirm:$false }
            }

            It 'the restore says to mount the volume and select Check the volumes' {
                Script:VrRestoreMissing
                @((Script:VrRestoreDoc $script:rsRun).history)[-1].detail | Should -Match 'Mount each volume inside the machine. Then select Check the volumes\.'
            }

            It 'every volume mounted again: the record owes nothing, and the machine is restored - still MIGRATED' {
                Script:VrRestoreMissing
                $global:vrValidate.before = '/; /boot; /var/crash'
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'MATCH'
                $doc = Script:VrRestoreDoc $script:rsRun
                $doc.state | Should -Be 'MIGRATED'
                $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
                $last = @($doc.history)[-1]
                $last.outcome | Should -Be 'ok'
                $last.machineState | Should -Be 'restored'
                $last.detail | Should -BeExactly 'Every volume that was mounted before the move is mounted again: /, /boot, /var/crash. operator@example.com asked for the check.'
                @($global:vrOrder | Where-Object { $_ -in @('start', 'deallocate', 'powerOff', 'swapOs') }) | Should -BeNullOrEmpty -Because 'the machine runs, and the check changes no disk'
                (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
            }

            It 'a volume still not mounted: the machine stays changed, the check stays owed, and the stop names the volume' {
                Script:VrRestoreMissing
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'MISSING'
                $doc = Script:VrRestoreDoc $script:rsRun
                $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
                $last = @($doc.history)[-1]
                $last.outcome | Should -Be 'fail'
                $last.reasonCode | Should -Be 'volumesNotBack'
                $last.machineState | Should -Be 'changed'
                $last.detail | Should -Match 'These volumes were mounted before the move and are not mounted now: /var/crash\.'
                $last.detail | Should -Match 'Mount each volume inside the machine. Then select Check the volumes\.'
            }

            It 'the check cannot run: volumesNotChecked, the machine stays changed, and the record that owes the check does not change' {
                Script:VrRestoreMissing
                $global:vrValidate['throw:before:lvm-devices-refresh.sh'] = 'RunCommand timed out.'
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'UNKNOWN'
                $doc = Script:VrRestoreDoc $script:rsRun
                $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack' -Because 'unknown never replaces a volume found not mounted'
                $last = @($doc.history)[-1]
                $last.reasonCode | Should -Be 'volumesNotChecked'
                $last.machineState | Should -Be 'changed'
                $last.detail | Should -Match 'The product could not check the volumes inside the machine \(RunCommand timed out\)\.'
            }

            It 'a check owed as notChecked that now finds a volume not mounted owes it as volumesNotBack - measured' {
                $script:rsRun = Script:VrRestoreRun -Before '/; /boot; /var/crash'
                Script:VrRestoreAzure
                Script:VrMockGuest @{ before = '/; /boot; /var/crash'; 'throw:before:lvm-devices-refresh.sh' = 'RunCommand timed out.' }
                $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
                (Script:VrRestoreDoc $script:rsRun).volumesCheckOwed.reason | Should -Be 'notChecked'
                Script:VrMockGuest @{ before = '/; /boot' }
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'MISSING'
                $doc = Script:VrRestoreDoc $script:rsRun
                $doc.volumesCheckOwed.reason | Should -Be 'volumesNotBack'
                $doc.volumesCheckOwed.kind | Should -Be 'restore'
            }
            It 'a machine that is Stopped (deallocated): started for the check, then deallocated again' {
                Script:VrRestoreMissing
                $global:vrPower = 'PowerState/deallocated'
                $global:vrValidate.before = '/; /boot; /var/crash'
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'MATCH'
                @($global:vrOrder | Where-Object { $_ -in @('start', 'deallocate') }) | Should -Be @('start', 'deallocate')
                $global:vrPower | Should -Be 'PowerState/deallocated'
                $last = @((Script:VrRestoreDoc $script:rsRun).history)[-1]
                $last.machineState | Should -Be 'restored'
                $last.detail | Should -Match 'The product started the machine to run the check, then made it deallocated again\.'
            }

            It 'the return to the power state is refused: the volumes are measured back, and the power state is owed for Return to the power state' {
                Script:VrRestoreMissing
                $global:vrPower = 'PowerState/deallocated'
                $global:vrValidate.before = '/; /boot; /var/crash'
                Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:vrOrder.Add('deallocate'); throw 'Conflict: another operation is in progress.' }
                $null = Script:VrCheck
                $doc = Script:VrRestoreDoc $script:rsRun
                $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty -Because 'every volume was measured mounted'
                $last = @($doc.history)[-1]
                $last.machineState | Should -Be 'changed'
                $last.powerNotPutBack | Should -Be 'PowerState/deallocated'
                $last.detail | Should -Match 'Select Return to the power state'
                (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -Be 'PowerState/deallocated'
            }

            It 'kill and resume (rule 4): a job killed after the start for the check returns the machine when it runs again' {
                Script:VrRestoreMissing
                $global:vrPower = 'PowerState/deallocated'
                $global:vrValidate.before = '/; /boot'
                $global:vrKill = $false
                Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady {
                    $global:vrOrder.Add('agentReady')
                    if (-not $global:vrKill) { $global:vrKill = $true; throw 'VMF-TEST-KILLED: the process is gone - abandon this VM' }
                }
                { Script:VrCheck } | Should -Throw '*abandon this VM*'
                $global:vrPower | Should -Be 'PowerState/running'
                (Script:VrRestoreDoc $script:rsRun).captured.volumesCheckPower.status | Should -Be 'started'
                $global:vrOrder.Clear()
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'MISSING'
                @($global:vrOrder) | Should -Not -Contain 'start'
                $global:vrPower | Should -Be 'PowerState/deallocated'
            }

            It 'VOLUMES-CHECK-JOB-STOP-1 kill and resume: a job that ends between the start and the return leaves the record started; the service marks it, and the check it starts again returns the machine' {
                Script:VrRestoreMissing
                $global:vrPower = 'PowerState/deallocated'
                $global:vrValidate.before = '/; /boot; /var/crash'
                $global:vrKill = $false
                # The throw comes after the check, before the return: the
                # validation script is the last call before it.
                Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
                    $global:vrOrder.Add('deallocate')
                    if (-not $global:vrKill) { $global:vrKill = $true; throw 'VMF-TEST-KILLED: the process is gone - abandon this VM' }
                    $global:vrPower = 'PowerState/deallocated'
                }
                { Script:VrCheck } | Should -Throw '*abandon this VM*'
                $global:vrPower | Should -Be 'PowerState/running' -Because 'the job ended before the return'
                $doc = Script:VrRestoreDoc $script:rsRun
                (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) (Get-VmfVolumesCheckStarted -Doc $d).power }) | Should -Be 'PowerState/deallocated'
                $doc.volumesCheckOwed | Should -Not -BeNullOrEmpty -Because 'nothing was written after the check'
                (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsRun; id = $script:rsVm } { param($rp, $id) Set-VmfVolumesCheckStopped -RunPath $rp -VmId $id }) | Should -Be 'resume'
                $global:vrOrder.Clear()
                $r = Script:VrCheck
                $r.Verdict | Should -Be 'MATCH'
                @($global:vrOrder) | Should -Not -Contain 'start'
                $global:vrPower | Should -Be 'PowerState/deallocated'
                $doc = Script:VrRestoreDoc $script:rsRun
                (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfVolumesCheckStarted -Doc $d }) | Should -BeNullOrEmpty
                $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
            }

            It 'VOLUMES-CHECK-JOB-STOP-1: a start on record with nothing owed any more: the check returns the machine only' {
                Script:VrRestoreMissing
                InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsRun; id = $script:rsVm } { param($rp, $id)
                    $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                    $d.PSObject.Properties.Remove('volumesCheckOwed')
                    $d.captured | Add-Member -NotePropertyName volumesCheckPower -Force -NotePropertyValue ([pscustomobject]@{ power = 'PowerState/stopped'; status = 'started'; tsUtc = '2026-11-15T10:00:00Z' })
                    Write-VmfStateDoc -RunPath $rp -Document $d
                }
                $global:vrOrder.Clear()
                $r = Script:VrCheck
                $r.Verdict | Should -BeNullOrEmpty
                @($global:vrOrder | Where-Object { $_ -like 'script:*' }) | Should -BeNullOrEmpty -Because 'nothing owes the check'
                @($global:vrOrder) | Should -Contain 'powerOff'
                $global:vrPower | Should -Be 'PowerState/stopped'
                (Script:VrRestoreDoc $script:rsRun).captured.volumesCheckPower.status | Should -Be 'putBack'
            }
            It 'a record that owes no check: nothing runs, and nothing is written' {
                $script:rsRun = Script:VrRestoreRun -Before '/; /boot; /var/crash'
                Script:VrRestoreAzure
                Script:VrMockGuest @{ before = '/; /boot; /var/crash' }
                $was = @((Script:VrRestoreDoc $script:rsRun).history).Count
                $r = Script:VrCheck
                $r.Verdict | Should -BeNullOrEmpty
                $r.Detail | Should -Match 'owes no check'
                @($global:vrOrder) | Should -BeNullOrEmpty
                @((Script:VrRestoreDoc $script:rsRun).history).Count | Should -Be $was
            }

            It 'under the hold, the record is read again: a check that a job ended in between runs nothing' {
                Script:VrRestoreMissing
                $global:vrHoldRp = $script:rsRun; $global:vrHoldVm = $script:rsVm
                Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease {
                    & (Get-Module VmMigrationFactory) {
                        $d = Read-VmfStateDoc -RunPath $global:vrHoldRp -VmId $global:vrHoldVm
                        $d.PSObject.Properties.Remove('volumesCheckOwed')
                        Write-VmfStateDoc -RunPath $global:vrHoldRp -Document $d
                    }
                    $null
                }
                $was = @((Script:VrRestoreDoc $script:rsRun).history).Count
                $r = Script:VrCheck
                $r.Verdict | Should -BeNullOrEmpty
                @($global:vrOrder) | Should -BeNullOrEmpty
                @((Script:VrRestoreDoc $script:rsRun).history).Count | Should -Be $was
                Remove-Variable vrHoldRp, vrHoldVm -Scope Global -ErrorAction SilentlyContinue
            }
            It 'a machine a job works on, or with a data disk swap left, is refused before anything runs' {
                Script:VrRestoreMissing
                InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rsRun; id = $script:rsVm } { param($rp, $id)
                    $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                    $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kind = 'restore' }) -Force
                    (Get-VmfVolumesCheckRefusal -Doc $d -VmName 'app01') | Should -Match 'Finish the restore'
                    $d.PSObject.Properties.Remove('swapPending')
                    $d.state = 'CONVERTING'
                    (Get-VmfVolumesCheckRefusal -Doc $d -VmName 'app01') | Should -Match 'CONVERTING'
                    $d.state = 'MIGRATED'
                    Get-VmfVolumesCheckRefusal -Doc $d -VmName 'app01' | Should -BeNullOrEmpty
                    $d.state = 'CONVERTING'
                    Write-VmfStateDoc -RunPath $rp -Document $d
                }
                { Script:VrCheck } | Should -Throw '*CONVERTING*'
                @($global:vrOrder) | Should -BeNullOrEmpty
            }
        }
    }
}

Describe 'VOLUMES-RETRY-CHECK-1: the contract and the words' {
    It 'vm-state v50 declares volumesCheckOwed, and the sample and the migration note follow' {
        $s = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $s.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $o = $s.properties.volumesCheckOwed
        $o | Should -Not -BeNullOrEmpty
        @($o.properties.reason.enum) | Should -Be @('volumesNotBack', 'notChecked')
        @($o.properties.kind.enum) | Should -Be @('rollback', 'restore')
        (Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json).schemaVersion | Should -Be 51
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match 'vm-state v49 -> v50'
    }

    It 'the stop says the approved sentence, and sends the person to Try this machine again' {
        $g = InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'volumesNotBack' }
        $g.whatToDo | Should -BeExactly 'Mount the volume inside the machine, then select Try this machine again. The product first checks that every volume mounted before the move is mounted again.'
        $g.machine | Should -Be 'changed'
        # 'unlikely': the page adds its line for the retry kind, and the what-to-do
        # already says to select Try this machine again (stop-card-once.test.js).
        $g.retry | Should -Be 'unlikely'
    }

    It 'the service never removes the record: only the engine''s new attempt does' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Resolve-VmfDecision.ps1')
        $code | Should -Not -Match "Remove\(\s*'volumesCheckOwed'"
        $code | Should -Not -Match 'Set-VmfVolumesCheckOwed'
        $code | Should -Match 'Get-VmfVolumesCheckOwed'
    }
}
