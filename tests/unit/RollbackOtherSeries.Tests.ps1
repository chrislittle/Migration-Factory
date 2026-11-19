#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-NO-CAPACITY-OTHER-SERIES-1 and ROLLBACK-SIZE-REFUSED-SERIES-1.
# Decided 2026-11-14: when a rollback cannot finish, the machine can move to
# another series, for example v5. That is a fresh run from the original disks,
# with new safety copies, and v5 stays on SCSI. It is offered as the way
# forward from BOTH stops.
#
# Case A, rollbackNoCapacity: every disk is back and the machine is stopped on
# its original size, which Azure has no capacity for. A retry of a move onto
# v5 starts the machine on the new size: Checking does not start it, the
# copies are new copies of the original disks, Converting resizes the stopped
# machine, and the checks that read the guest run after the start on v5.
#
# Case B, rollbackSizeRefused: the machine is stopped on the NEW size, on the
# disks the move left. Change to v5, then Restore this machine from the first
# safety copy, puts the first copy on the v5 size of the plan - and that size
# is what every later rollback returns to.
#
# Capacity cannot be forced in a lab, so Azure's answers are mocks: no capacity
# for the original size from the moment the machine leaves it.
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
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
}
AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface', 'function:\RoDoc', 'function:\RoOut' -ErrorAction SilentlyContinue
    Remove-Variable roFail, roOrder, roOs, roPower, roRunPath, roSize, roNoCapacity, roRefuse, roValidate, roScripts, roKill, roNames -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: which moves start on the new size' {
    It 'a SCSI move onto v5 needs no change inside the machine before it' {
        InModuleScope VmMigrationFactory {
            $e = { param($os, $size, $arch = 'diskless', $src = 'diskless', $ctl = 'SCSI')
                [pscustomobject]@{ assessment = [pscustomobject]@{ os = $os; sourceDiskArch = $src }; target = [pscustomobject]@{ size = $size; controller = $ctl; diskArch = $arch } } }
            Test-VmfStartOnTargetShape -PlanEntry (& $e 'Linux' 'Standard_D2s_v5') | Should -BeNullOrEmpty
            Test-VmfStartOnTargetShape -PlanEntry (& $e 'Windows' 'Standard_D2as_v5') | Should -BeNullOrEmpty -Because 'AMD v5 cannot give MANA'
            Test-VmfStartOnTargetShape -PlanEntry (& $e 'Windows' 'Standard_D2ads_v5' 'scsi-temp' 'scsi-temp') | Should -BeNullOrEmpty -Because 'the temporary disk stays'
        }
    }
    It 'refuses <Why>' -TestCases @(
        @{ Why = 'notScsi'; Os = 'Linux'; Size = 'Standard_D2s_v6'; Ctl = 'NVMe'; Arch = 'diskless'; Src = 'diskless' }
        @{ Why = 'pageFile'; Os = 'Windows'; Size = 'Standard_D2as_v5'; Ctl = 'SCSI'; Arch = 'diskless'; Src = 'scsi-temp' }
        @{ Why = 'manaDriver'; Os = 'Windows'; Size = 'Standard_D2s_v5'; Ctl = 'SCSI'; Arch = 'diskless'; Src = 'diskless' }
    ) {
        InModuleScope VmMigrationFactory -Parameters @{ w = $Why; os = $Os; size = $Size; ctl = $Ctl; arch = $Arch; src = $Src } {
            param($w, $os, $size, $ctl, $arch, $src)
            $entry = [pscustomobject]@{ assessment = [pscustomobject]@{ os = $os; sourceDiskArch = $src }; target = [pscustomobject]@{ size = $size; controller = $ctl; diskArch = $arch } }
            Test-VmfStartOnTargetShape -PlanEntry $entry | Should -Be $w
            Get-VmfStartOnTargetRefusedWords -Size 'Standard_D2s_v4' -Why $w | Should -Match '^This move needs the machine to run on Standard_D2s_v4 before the change\. '
        }
    }
    It 'a record belongs to the stop it was decided from, and a later stop ends it' {
        InModuleScope VmMigrationFactory {
            $stop = [pscustomobject]@{ tsUtc = '2026-11-14T10:00:00.0000000Z'; state = 'FAILED_ROLLED_BACK'; reasonCode = 'rollbackNoCapacity'; machineState = 'changed' }
            $retry = [pscustomobject]@{ tsUtc = '2026-11-14T11:00:00Z'; state = 'PRECHECK'; outcome = 'ok' }
            $rec = [pscustomobject]@{ size = 'Standard_D2s_v4'; target = 'Standard_D2s_v5'; power = 'PowerState/running'; stopUtc = '2026-11-14T10:00:00.0000000Z'; tsUtc = '2026-11-14T11:00:01Z' }
            $doc = [pscustomobject]@{ history = @($stop, $retry); captured = [pscustomobject]@{ startOnTarget = $rec } }
            (Get-VmfLastStopEntry -Doc $doc).reasonCode | Should -Be 'rollbackNoCapacity' -Because 'the entry of the retry is not a stop'
            Get-VmfStartOnTarget -Doc $doc | Should -Not -BeNullOrEmpty
            Get-VmfStartOnTargetPower -Doc $doc | Should -Be 'PowerState/running'
            # ConvertFrom-Json gives a date value: the same instant still matches.
            $doc.history[0].tsUtc = [datetime]::Parse('2026-11-14T10:00:00Z').ToUniversalTime()
            Get-VmfStartOnTarget -Doc $doc | Should -Not -BeNullOrEmpty
            $later = [pscustomobject]@{ tsUtc = '2026-11-14T12:00:00Z'; state = 'FAILED_ROLLED_BACK'; reasonCode = 'rollbackNoCapacity'; machineState = 'changed' }
            $doc.history = @($stop, $retry, $later)
            Get-VmfStartOnTarget -Doc $doc | Should -BeNullOrEmpty -Because 'a record of an earlier attempt is not this attempt''s'
        }
    }
    It 'the power state the move returns to: deallocated and stopped from the record, running owes a start' {
        InModuleScope VmMigrationFactory {
            $stop = [pscustomobject]@{ tsUtc = '2026-11-14T10:00:00Z'; state = 'FAILED_ROLLED_BACK'; reasonCode = 'rollbackNoCapacity' }
            foreach ($p in 'PowerState/deallocated', 'PowerState/stopped') {
                $doc = [pscustomobject]@{ history = @($stop); captured = [pscustomobject]@{ startOnTarget = [pscustomobject]@{ power = $p; stopUtc = '2026-11-14T10:00:00Z' } } }
                Get-VmfPowerAsFound -Doc $doc | Should -Be $p
            }
            $doc = [pscustomobject]@{ history = @($stop); captured = [pscustomobject]@{ startOnTarget = [pscustomobject]@{ power = 'PowerState/running'; stopUtc = '2026-11-14T10:00:00Z' } } }
            Get-VmfPowerAsFound -Doc $doc | Should -BeNullOrEmpty -Because 'a machine found running stays running after the move'
            # The record of the cluster check, when there is one, decides as before.
            $doc.captured | Add-Member -NotePropertyName clusterCheckPower -NotePropertyValue ([pscustomobject]@{ power = 'PowerState/stopped'; status = 'goingOn' })
            Get-VmfPowerAsFound -Doc $doc | Should -Be 'PowerState/stopped'
        }
    }
}

Describe 'ROLLBACK-SIZE-REFUSED-SERIES-1: the restore onto the target size, by the shared fixture' {
    It 'every case gives the answer the run page gives' {
        $cases = (Get-Content (Join-Path $script:repoRoot 'tests' 'fixtures' 'restore-onto-target.json') -Raw | ConvertFrom-Json -Depth 30).cases
        @($cases).Count | Should -BeGreaterOrEqual 8
        foreach ($c in $cases) {
            $got = InModuleScope VmMigrationFactory -Parameters @{ d = $c.doc; e = $c.entry; f = $c.from } {
                param($d, $e, $f)
                Get-VmfRestoreOntoTarget -Doc $d -PlanEntry $e -From $(if ($f) { $f } else { 'pristine' })
            }
            if ($null -eq $c.onto) { $got | Should -BeNullOrEmpty -Because $c.why }
            else {
                $got.Size | Should -Be $c.onto.size -Because $c.why
                $got.Option | Should -Be $c.onto.option -Because $c.why
                $got.OriginalSize | Should -Be $c.onto.originalSize -Because $c.why
                [bool]$got.Refusal | Should -Be ([bool]$c.onto.refused) -Because $c.why
            }
        }
    }
}

Describe 'Both stops, through the state machine' {
    BeforeAll {
        $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
        $script:original = 'Standard_D2s_v4'

        function Script:RoPlan {
            param([string]$Os = 'Linux', [string]$Series = 'v6')
            $target = switch ($Series) {
                'v6' { [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' } }
                'v5' { [pscustomobject]@{ size = 'Standard_D2s_v5'; diskArch = 'diskless'; controller = 'SCSI'
                        choice = [pscustomobject]@{ option = 'v5'; source = 'person'; chosenBy = 'operator@example.com'; method = 'inPlace' } } }
            }
            [pscustomobject]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
                assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                    sourceSize = $script:original; sourceDiskArch = 'diskless'; platformManaged = $false }
                target = $target; path = 'A'; policy = [pscustomobject]@{ targetGeneration = $Series }; decisions = @()
            }
        }
        function Script:RoFakeVm {
            [pscustomobject]@{
                Id = $script:vmId; Name = 'vm-under-test'; Location = 'centralus'
                HardwareProfile = [pscustomobject]@{ VmSize = $global:roSize }
                StorageProfile = [pscustomobject]@{
                    DiskControllerType = 'SCSI'
                    OsDisk = [pscustomobject]@{ OsType = $global:roOs; Name = 'vm-os'; DeleteOption = 'Delete'
                        ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; StorageAccountType = 'Premium_LRS' } }
                    DataDisks = @(); ImageReference = $null
                }
                NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true }) }
                Zones = @(); Tags = @{}
                LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
                Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
            }
        }
        function Global:RoDoc { & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $global:roRunPath $script:vmId }

        function Script:RoMockAzure {
            param([string]$Os = 'Linux', [string]$Found = 'PowerState/running')
            $global:roPower = $Found
            $global:roSize = $script:original
            $global:roNoCapacity = $false
            $global:roRefuse = ''
            $global:roOs = $Os
            $global:roKill = @{}
            $global:roNames = [System.Collections.Generic.List[string]]::new()
            $global:roOrder = [System.Collections.Generic.List[string]]::new()
            Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
            Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
            Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
            Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
            Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
                if ($global:roKill['permissions']) { $global:roKill.Remove('permissions'); throw 'The lease was lost: abandon this VM.' }
                $global:roOrder.Add('permissions'); @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:roPower }
            Mock -ModuleName VmMigrationFactory Get-AzVM { Script:RoFakeVm }
            Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:roSize }
            Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:roOrder.Add('snapshot'); $global:roNames.Add($SnapshotName); "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/$SnapshotName" }
            Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { "$SnapshotId/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
            Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:roOrder.Add('deallocate'); $global:roPower = 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { $global:roOrder.Add('powerOff'); $global:roPower = 'PowerState/stopped' }
            # Azure has no capacity for the original size from the moment the
            # machine leaves it.
            Mock -ModuleName VmMigrationFactory Start-VmfVm {
                if ($global:roNoCapacity -and $global:roSize -eq $script:original) {
                    $global:roOrder.Add("startRefused:$($global:roSize)")
                    throw 'Allocation failed. We do not have sufficient capacity for the requested VM size in this region. ErrorCode: AllocationFailed'
                }
                $global:roOrder.Add("start:$($global:roSize)"); $global:roPower = 'PowerState/running'
            }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady {
                if ($global:roKill['agent']) { $global:roKill.Remove('agent'); throw 'The lease was lost: abandon this VM.' }
                $global:roOrder.Add('agentReady') }
            Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
                if ($global:roRefuse -and $Size -eq $global:roRefuse) {
                    throw "Operation could not be completed as it results in exceeding approved quota. ErrorCode: NotAvailableForSubscription. The size $Size is not available."
                }
                $global:roOrder.Add("size:$Size")
                if ($global:roSize -eq $script:original -and $Size -ne $script:original) { $global:roNoCapacity = $true }
                $global:roSize = $Size
            }
            Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
            Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
            Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
            Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm-os'; id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'SCSI' } }
            Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
            Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:roOrder.Add("disk:$DiskName"); "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:roOrder.Add("swapOs:$DiskName") }
            Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
            Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
            Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
            Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
            Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{ fetchedUtc = '2026-11-14T00:00:00Z' } }
            Mock -ModuleName VmMigrationFactory Get-VmfVmIdentityFacts { [pscustomobject]@{ systemAssigned = $false; principalId = $null; userAssigned = @() } }
            Mock -ModuleName VmMigrationFactory Get-VmfWaveStartGate { $null }
        }
        function Global:RoOut {
            param([string]$Script, [string]$Result, [object[]]$Checks = @())
            [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
        }
        # The guest answers by the size the machine runs on. $global:roValidate
        # holds the mounted volumes for each size; $global:roScripts can make a
        # script answer otherwise ("<size>:<script>").
        function Script:RoMockGuest {
            param([hashtable]$Validate)
            $global:roValidate = $Validate
            $global:roScripts = @{}
            Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
                [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                    Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                    Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
            }
            Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
                $name = [string]$ScriptString
                $global:roOrder.Add("script:$name@$($global:roSize)")
                if ($global:roScripts.ContainsKey("$($global:roSize):$name")) { return $global:roScripts["$($global:roSize):$name"] }
                $out = switch ($name) {
                    'cluster-node-check.sh' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; warnings = @(); checks = @()
                            facts = [ordered]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                    'Test-ClusterNode.ps1' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                            facts = [ordered]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } } }
                    'mana-check.sh' { Global:RoOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                    # VF-UNMANAGED-CONFIG-1: the network settings set the virtual function as unmanaged (systemd-networkd before 255 with cloud-init's setting).
                    'sriov-unmanaged-check.sh' { [ordered]@{ schema = 'vmf.guest/7'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                    'Test-ManaReady.ps1' { Global:RoOut $name 'READY' @(@{ name = 'mana driver'; status = 'PASS'; detail = 'bound' }) }
                    { $_ -in @('guest-validate.sh', 'Test-GuestValidation.ps1') } {
                        $nvme = $global:roSize -like '*_v6'
                        $bus = if ($name -like '*.sh') { @{ name = 'root device bus'; status = 'INFO'; detail = $(if ($nvme) { 'nvme (/dev/nvme0n1p1)' } else { 'non-nvme (/dev/sda1)' }) } }
                               else { @{ name = 'boot disk bus'; status = 'INFO'; detail = $(if ($nvme) { 'NVMe' } else { 'SCSI' }) } }
                        Global:RoOut $name 'PASS' @($bus, @{ name = 'mounted volumes'; status = 'INFO'; detail = [string]$global:roValidate[$global:roSize] })
                    }
                    'lvm-devices-refresh.sh' { Global:RoOut $name 'NO_CHANGE' @(@{ name = 'lvm devices refresh'; status = 'PASS'; detail = 'every physical volume is in the devices file' }) }
                    'Install-ManaDriver.ps1' { Global:RoOut $name 'NO_CHANGE' @(@{ name = 'mana driver in store'; status = 'PASS'; detail = 'present' }) }
                    default { Global:RoOut $name 'READY' }
                }
                $out | ConvertTo-Json -Depth 8 -Compress
            }
        }
        function Script:RoRun { param($Plan) InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } { param($rp, $plan) Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'ro-test' } }
        function Script:RoWritePlan {
            param($Plan)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; entry = $Plan } {
                param($rp, $entry)
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
            }
        }
        function Script:RoRetry {
            Resolve-VmfDecision -RunPath $script:runPath -PlanPath (Join-Path $script:runPath 'plan.json') -VmId $script:vmId -Note 'try it again on v5' -ResolvedBy 'operator@example.com'
        }
        function Script:RoLines { param([string]$Step) & (Get-Module VmMigrationFactory) { param($rp, $s) @(Read-VmfEvents -RunPath $rp | Where-Object { [string]$_.step -eq $s }) } $script:runPath $Step }
        # The two reports, from the machine's record: the migration record's
        # row, and the row of the report of changes for code.
        function Script:RoReports {
            $doc = Global:RoDoc
            $plan = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Read-VmfPlanDocument -RunPath $rp }
            $record = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; p = $plan } {
                param($d, $p) ConvertTo-VmfMigrationRecord -Manifest @{ runId = 'ro-test' } -Plan $p -StateDocs @($d) -GeneratedBy 'operator@example.com' -Reason 'downloaded' }
            $iac = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) @(Get-VmfIacChangeRows -StateDocs @($d)) }
            @{ Row = @($record.machines)[0]; Iac = @($iac)[0] }
        }
        function Script:RoBefore([string]$A, [string]$B) {
            $all = @($global:roOrder)
            $ia = [array]::IndexOf($all, $A); $ib = [array]::IndexOf($all, $B)
            ($ia -ge 0 -and $ib -ge 0 -and $ia -lt $ib)
        }
        # The first attempt: a move to v6 that Verifying fails (a volume not
        # mounted), and a rollback that finds no capacity for the original
        # size at any try - rollbackNoCapacity, every disk back.
        function Script:RoNoCapacity {
            param([string]$Os = 'Linux', [string]$Found = 'PowerState/running')
            Script:RoMockAzure -Os $Os -Found $Found
            Script:RoMockGuest @{ 'Standard_D2s_v4' = '/; /boot; /var/crash'; 'Standard_D2s_v6' = '/; /boot'; 'Standard_D2s_v5' = '/; /boot; /var/crash' }
            $plan = Script:RoPlan -Os $Os
            Script:RoWritePlan $plan
            $first = Script:RoRun $plan
            $first.state | Should -Be 'FAILED_ROLLED_BACK' -Because ([string]@($first.history)[-1].detail)
            @($first.history)[-1].reasonCode | Should -Be 'rollbackNoCapacity'
            $global:roSize | Should -Be $script:original -Because 'every disk is back and the size went back'
            $global:roPower | Should -Be 'PowerState/deallocated'
        }
        # The person's Change to v5: the plan entry as Set-VmfMachineTarget
        # writes it (RetrySeries.Tests.ps1 holds that cmdlet).
        function Script:RoToV5 { param([string]$Os = 'Linux') $p = Script:RoPlan -Os $Os -Series 'v5'; Script:RoWritePlan $p; $p }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ro-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:roRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'ro-test' | Out-Null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    Context 'Case A: a retry on v5 after rollbackNoCapacity' {
        It 'THE CASE: the machine never starts on its original size; it is resized while stopped, started on v5, and checked after that start' {
            Script:RoNoCapacity
            $firstCopy = [string](Global:RoDoc).safety.pristineSnapshotId
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roOrder.Clear(); $global:roNames.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            $order = @($global:roOrder)
            @($order | Where-Object { $_ -like 'startRefused:*' -or $_ -eq "start:$($script:original)" }) | Should -BeNullOrEmpty -Because "no start on the original size: $($order -join ', ')"
            @($order | Where-Object { $_ -like "script:*@$($script:original)" }) | Should -BeNullOrEmpty -Because 'no script runs on the original size'
            Script:RoBefore 'snapshot' 'size:Standard_D2s_v5' | Should -BeTrue -Because "the new copies come before the change: $($order -join ', ')"
            Script:RoBefore 'size:Standard_D2s_v5' 'start:Standard_D2s_v5' | Should -BeTrue -Because "resized first, then started: $($order -join ', ')"
            Script:RoBefore 'start:Standard_D2s_v5' 'script:cluster-node-check.sh@Standard_D2s_v5' | Should -BeTrue -Because 'the cluster check runs after the start'
            Script:RoBefore 'script:lvm-devices-refresh.sh@Standard_D2s_v5' 'script:cluster-node-check.sh@Standard_D2s_v5' | Should -BeTrue -Because 'the LVM devices file first, as after a put-back'
            Script:RoBefore 'script:mana-check.sh@Standard_D2s_v5' 'script:guest-validate.sh@Standard_D2s_v5' | Should -BeTrue -Because 'the driver check before Verifying'            # VF-UNMANAGED-CONFIG-1: the check of the network settings for accelerated networking runs after the start too, before the driver check.
            Script:RoBefore 'script:cluster-node-check.sh@Standard_D2s_v5' 'script:sriov-unmanaged-check.sh@Standard_D2s_v5' | Should -BeTrue -Because "the network settings after the cluster check: $($order -join ', ')"
            Script:RoBefore 'script:sriov-unmanaged-check.sh@Standard_D2s_v5' 'script:mana-check.sh@Standard_D2s_v5' | Should -BeTrue -Because 'and before the driver check, as at Checking'

            $doc = Global:RoDoc
            # SAFETY-RETRY-1: new copies of the original disks, the old ones kept.
            @($doc.safety.earlierCopies).Count | Should -Be 1
            [string]@($doc.safety.earlierCopies)[0].pristineSnapshotId | Should -Be $firstCopy
            [string]$doc.safety.pristineSnapshotId | Should -Not -Be $firstCopy
            @($global:roNames | Where-Object { $_ -notmatch '-a2' }) | Should -BeNullOrEmpty -Because "every copy of the second attempt is named -a2: $(@($global:roNames) -join ', ')"
            $doc.PSObject.Properties['volumesCheckOwed'] | Should -BeNullOrEmpty
            $doc.captured.startOnTarget.size | Should -Be $script:original
            $doc.captured.startOnTarget.target | Should -Be 'Standard_D2s_v5'
            $doc.captured.startOnTarget.power | Should -Be 'PowerState/running' -Because 'the machine owed the power state running'
            $global:roPower | Should -Be 'PowerState/running' -Because 'a machine found running is running after the move'
            @(Script:RoLines 'PRECHECK' | Where-Object { $_.detail -match '^Azure had no capacity for Standard_D2s_v4, so the product does not start the machine on it\.' }) | Should -Not -BeNullOrEmpty
            @(Script:RoLines 'VALIDATING' | Where-Object { $_.detail -match 'mounted volumes: MATCH' }) | Should -Not -BeNullOrEmpty -Because 'Verifying compares with the reading the first attempt took of these disks'
        }

        It 'Verifying compares the volumes with the reading the earlier attempt took of these disks: one missing on v5 rolls it back' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roValidate['Standard_D2s_v5'] = '/; /boot'
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            @($final.history)[-1].reasonCode | Should -Be 'rollbackNoCapacity' -Because 'the rollback finds no capacity again'
            @($final.history)[-1].detail | Should -Match '/var/crash'
            $global:roSize | Should -Be $script:original -Because 'the rollback returns the original size'
            @($global:roOrder | Where-Object { $_ -like 'swapOs:*' }) | Should -Not -BeNullOrEmpty -Because 'the disks go back from the new copies'
        }

        It 'a cluster node found after the start on v5 is rolled back, and the stop keeps the reason' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roScripts['Standard_D2s_v5:cluster-node-check.sh'] = ([ordered]@{ schema = 'vmf.guest/4'; script = 'cluster-node-check.sh'; version = '1.0.0'; result = 'READY'; warnings = @(); checks = @()
                    facts = [ordered]@{ os = 'Linux'; pacemaker = 'active'; corosync = 'active'; sqlHadr = 'no' } } | ConvertTo-Json -Depth 6 -Compress)
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            $stop = @($final.history)[-1]
            $stop.detail | Should -Match 'The product does not move a cluster node\. The check ran after the start on Standard_D2s_v5, so the product rolls the machine back\.'
            $global:roSize | Should -Be $script:original
            @($global:roOrder | Where-Object { $_ -like 'script:guest-validate.sh@*' }) | Should -BeNullOrEmpty -Because 'Verifying does not run'
            @(Script:RoLines 'STARTING' | Where-Object { $_.outcome -eq 'fail' }) | Should -Not -BeNullOrEmpty
        }

        It 'network settings that do not set the virtual function as unmanaged, found after the start on v5: rolled back, and the stop keeps the reason (VF-UNMANAGED-CONFIG-1)' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roScripts['Standard_D2s_v5:sriov-unmanaged-check.sh'] = ([ordered]@{ schema = 'vmf.guest/7'; script = 'sriov-unmanaged-check.sh'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                    facts = [ordered]@{ os = 'Linux'; networkManager = 'active'; networkd = 'inactive'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = 'none'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } | ConvertTo-Json -Depth 6 -Compress)
            # Azure has capacity again when the rollback starts the machine, so the stop is the check's own.
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:roOrder.Add("size:$Size"); $global:roSize = $Size; if ($Size -eq $script:original) { $global:roNoCapacity = $false } }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'NEEDS_DECISION' -Because ((@($final.history) | ForEach-Object { "$($_.state)/$($_.reasonCode): $($_.detail)" }) -join ' || ')
            $stop = @($final.history)[-1]
            $stop.reasonCode | Should -Be 'sriovNotUnmanaged'
            $stop.machineState | Should -Be 'restored' -Because 'the full rollback put the disks and the original size back'
            $stop.detail | Should -Match 'The check ran after the start on Standard_D2s_v5, so the product rolls the machine back\.'
            $global:roSize | Should -Be $script:original
            @($global:roOrder | Where-Object { $_ -like 'swapOs:*' }) | Should -Not -BeNullOrEmpty -Because 'the disks go back from the new copies'
            @($global:roOrder | Where-Object { $_ -in @('script:mana-check.sh@Standard_D2s_v5', 'script:guest-validate.sh@Standard_D2s_v5') }) | Should -BeNullOrEmpty -Because 'no later check runs on v5'
        }

        # The check after the start runs only for a Linux move that turns
        # accelerated networking on, and not when an approver accepted the move
        # without the setting (VF-UNMANAGED-CONFIG-1 at Checking does the same).
        It 'accelerated networking off after the move: the check of the network settings does not run after the start on v5' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            Mock -ModuleName VmMigrationFactory Get-VmfAcceleratedNetworkingDecision { @{ Policy = 'preserve'; ExpectFabric = $false } }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ((@($final.history) | ForEach-Object { "$($_.state)/$($_.reasonCode): $($_.detail)" }) -join ' || ')
            @($global:roOrder) | Should -Contain 'script:cluster-node-check.sh@Standard_D2s_v5' -Because 'the checks after the start ran'
            @($global:roOrder) | Should -Not -Contain 'script:sriov-unmanaged-check.sh@Standard_D2s_v5' -Because "accelerated networking is off after the move: $(@($global:roOrder) -join ', ')"
        }

        It 'an approver accepted the move without the setting (onSriovUnmanagedMissing = proceed): the line says so, and no script runs after the start on v5' {
            Script:RoNoCapacity
            $plan = Script:RoPlan -Series 'v5'
            $plan.policy | Add-Member -NotePropertyName onSriovUnmanagedMissing -NotePropertyValue 'proceed' -Force
            Script:RoWritePlan $plan
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ((@($final.history) | ForEach-Object { "$($_.state)/$($_.reasonCode): $($_.detail)" }) -join ' || ')
            @($global:roOrder) | Should -Not -Contain 'script:sriov-unmanaged-check.sh@Standard_D2s_v5'
            @(Script:RoLines 'STARTING' | Where-Object { $_.detail -eq 'An approver accepted the move of this machine without the unmanaged setting. The product did not check the setting again.' }) | Should -Not -BeNullOrEmpty
        }

        It 'Windows: the check of the network settings never runs after the start on the new size' {
            Script:RoNoCapacity -Os 'Windows'
            # AMD v5 cannot give MANA, so a Windows machine needs no change inside it first and starts on the new size.
            $plan = Script:RoPlan -Os 'Windows' -Series 'v5'
            $plan.target.size = 'Standard_D2as_v5'
            $global:roValidate['Standard_D2as_v5'] = '/; /boot; /var/crash'
            Script:RoWritePlan $plan
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $null = Script:RoRun $plan
            # Verifying is not the subject here: the stand-in guest gives no Windows adapter, so only the checks after the start are asked.
            @($global:roOrder) | Should -Contain 'script:Test-ClusterNode.ps1@Standard_D2as_v5' -Because "the machine started on the new size and the checks after the start ran: $(@($global:roOrder) -join ', ')"
            @($global:roOrder | Where-Object { $_ -like 'script:sriov-unmanaged-check.sh@*' }) | Should -BeNullOrEmpty
        }

        It 'no answer from that check after the start on v5: rolled back with sriovUnmanagedNotChecked' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roScripts['Standard_D2s_v5:sriov-unmanaged-check.sh'] = ([ordered]@{ schema = 'vmf.guest/7'; script = 'sriov-unmanaged-check.sh'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux' } } | ConvertTo-Json -Depth 6 -Compress)
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:roOrder.Add("size:$Size"); $global:roSize = $Size; if ($Size -eq $script:original) { $global:roNoCapacity = $false } }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            @($final.history)[-1].reasonCode | Should -Be 'sriovUnmanagedNotChecked' -Because ((@($final.history) | ForEach-Object { "$($_.state)/$($_.reasonCode): $($_.detail)" }) -join ' || ')
            $global:roSize | Should -Be $script:original
        }

        It 'with capacity again for the original size, the rollback of a check after the start ends as the check''s own stop' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roScripts['Standard_D2s_v5:mana-check.sh'] = (Global:RoOut 'mana-check.sh' 'READY' @(@{ name = 'interface eth0'; status = 'INFO'; detail = 'no MANA driver' }) | ConvertTo-Json -Depth 6 -Compress)
            Mock -ModuleName VmMigrationFactory Get-VmfDriverJudgement { [pscustomobject]@{ Status = 'FAIL'; Detail = 'The kernel 5.4.0 is below the minimum kernel for MANA.' } }
            # Azure has capacity again when the rollback starts the machine.
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:roOrder.Add("size:$Size"); $global:roSize = $Size; if ($Size -eq $script:original) { $global:roNoCapacity = $false } }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'NEEDS_DECISION' -Because ((@($final.history) | ForEach-Object { "$($_.state)/$($_.reasonCode): $($_.detail)" }) -join ' || ')
            @($final.history)[-1].reasonCode | Should -Be 'driverBelowFloor'
            @($final.history)[-1].machineState | Should -Be 'restored' -Because ((@($final.history)[-1] | ConvertTo-Json -Depth 5 -Compress))
        }

        It 'with capacity for the original size STILL missing, the rollback of a check after the start ends in rollbackNoCapacity, with true words' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roScripts['Standard_D2s_v5:mana-check.sh'] = (Global:RoOut 'mana-check.sh' 'READY' @(@{ name = 'interface eth0'; status = 'INFO'; detail = 'no MANA driver' }) | ConvertTo-Json -Depth 6 -Compress)
            Mock -ModuleName VmMigrationFactory Get-VmfDriverJudgement { [pscustomobject]@{ Status = 'FAIL'; Detail = 'The kernel 5.4.0 is below the minimum kernel for MANA.' } }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            $stop = @($final.history)[-1]
            $stop.reasonCode | Should -Be 'rollbackNoCapacity'
            $stop.machineState | Should -Be 'changed' -Because 'the machine ran on v5 and is stopped now: its power state is owed'
            $stop.powerNotPutBack | Should -Be 'PowerState/running'
            $stop.detail | Should -Match 'The kernel 5\.4\.0 is below the minimum kernel for MANA\. The check ran after the start on Standard_D2s_v5, so the product rolls the machine back\.'
            $stop.detail | Should -Match 'Azure has no capacity for Standard_D2s_v4 now \(AllocationFailed\)\.'
            $stop.detail | Should -Match 'Every disk is back from the first safety copy\. The machine is stopped on Standard_D2s_v4\.'
            $stop.detail | Should -Match 'Or select Change to v5\.'
            $global:roSize | Should -Be $script:original -Because 'the size went back'
            $global:roPower | Should -Be 'PowerState/deallocated' -Because 'the machine is stopped, as the words say'
            $order = @($global:roOrder)
            [array]::LastIndexOf($order, "size:$($script:original)") | Should -BeGreaterThan ([array]::IndexOf($order, 'start:Standard_D2s_v5')) -Because "the rollback after the start: $($order -join ', ')"
            @($order | Where-Object { $_ -like 'swapOs:*' }) | Should -Not -BeNullOrEmpty -Because 'every disk went back from the new copy'
            (InModuleScope VmMigrationFactory -Parameters @{ d = (Global:RoDoc) } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse -Because 'the person can try again on v5'
            (InModuleScope VmMigrationFactory -Parameters @{ d = (Global:RoDoc) } { param($d) Test-VmfStartOnTargetStop -Doc $d }) | Should -BeTrue -Because 'the next retry starts on v5 again'
        }

        It 'kill-resume: a worker killed in Starting after the start on v5 runs the checks again, and never starts the machine on its original size' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roKill['agent'] = $true
            $global:roOrder.Clear()
            { Script:RoRun $plan } | Should -Throw '*abandon this VM*'
            (Global:RoDoc).state | Should -Be 'STARTING'
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            @($global:roOrder | Where-Object { $_ -like 'startRefused:*' -or $_ -like "*@$($script:original)" }) | Should -BeNullOrEmpty
            @($global:roOrder | Where-Object { $_ -eq 'script:cluster-node-check.sh@Standard_D2s_v5' }).Count | Should -Be 1 -Because 'the killed worker did not reach the check'
            @((Global:RoDoc).safety.earlierCopies).Count | Should -Be 1
        }

        It 'kill-resume: a worker killed in Checking after the record takes no second attempt' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roKill['permissions'] = $true
            { Script:RoRun $plan } | Should -Throw '*abandon this VM*'
            $mid = Global:RoDoc
            $mid.captured.startOnTarget | Should -Not -BeNullOrEmpty
            @($mid.safety.earlierCopies).Count | Should -Be 1
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            @((Global:RoDoc).safety.earlierCopies).Count | Should -Be 1 -Because 'the copies moved once'
        }

        It 'kill-resume: the new attempt taken and no record yet (killed between the two writes) takes no second attempt' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            # What the worker had written when it stopped: the new attempt only.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt -KeepReadings }
            $guestBefore = ((Global:RoDoc).captured.guestBefore | ConvertTo-Json -Depth 10 -Compress)
            $guestBefore | Should -Not -Be 'null' -Because 'the readings stay'
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            @((Global:RoDoc).safety.earlierCopies).Count | Should -Be 1
            @($global:roOrder | Where-Object { $_ -like 'startRefused:*' }) | Should -BeNullOrEmpty -Because ((@($global:roOrder) -join ', ') + ' ## ' + ((Script:RoLines 'PRECHECK' | ForEach-Object { $_.detail }) -join ' || '))
        }

        It 'a machine found deallocated goes back to deallocated after the move on v5' {
            Script:RoNoCapacity
            # The first attempt found it deallocated: nothing owed.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                $last = @($d.history)[-1]
                $last.machineState = 'restored'
                $last.PSObject.Properties.Remove('powerNotPutBack')
                Write-VmfStateDoc -RunPath $rp -Document $d
            }
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            (Global:RoDoc).captured.startOnTarget.power | Should -Be 'PowerState/deallocated'
            $global:roPower | Should -Be 'PowerState/deallocated' -Because 'POWER-AFTER-MOVE-1: the power state as found'
        }

        It 'a stop at Checking before the change starts a machine that owed running again, and says so - never untouched while it is off' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @([pscustomobject]@{ Name = 'freeze'; Level = 'ReadOnly'; Scope = $script:vmId }) }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'NEEDS_DECISION'
            $stop = @($final.history)[-1]
            $stop.machineState | Should -Be 'changed' -Because 'Azure had no capacity to start it, so its power state is still owed'
            $stop.powerNotPutBack | Should -Be 'PowerState/running'
            @($global:roOrder | Where-Object { $_ -like 'size:*' }) | Should -BeNullOrEmpty
            # POWER-ONLY-CHANGED-1: the product tries the start, and says so.
            @($global:roOrder | Where-Object { $_ -like 'startRefused:*' }) | Should -Not -BeNullOrEmpty -Because "the start was tried: $(@($global:roOrder) -join ', ')"
            $stop.detail | Should -Match 'could not start it again'
        }

        It 'after a park at Checking of that attempt, the next retry still starts on the new size' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @([pscustomobject]@{ Name = 'freeze'; Level = 'ReadOnly'; Scope = $script:vmId }) }
            $parked = Script:RoRun $plan
            $parked.state | Should -Be 'NEEDS_DECISION'
            # The person removes the lock, and tries the machine again.
            Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            @($global:roOrder | Where-Object { $_ -like 'startRefused:*' -or $_ -like "*@$($script:original)" }) | Should -BeNullOrEmpty -Because "$(@($global:roOrder) -join ', ')"
        }

        It 'only that chain: a record of an older attempt, or a park after a change, does not carry on' {
            InModuleScope VmMigrationFactory {
                $nc = [pscustomobject]@{ tsUtc = '2026-11-14T10:00:00Z'; state = 'FAILED_ROLLED_BACK'; reasonCode = 'rollbackNoCapacity'; machineState = 'changed'; powerNotPutBack = 'PowerState/running' }
                $park = [pscustomobject]@{ tsUtc = '2026-11-14T11:00:00Z'; state = 'NEEDS_DECISION'; reasonCode = 'resourceLockReadOnly'; machineState = 'changed'; powerNotPutBack = 'PowerState/running' }
                $rec = { param($at) [pscustomobject]@{ startOnTarget = [pscustomobject]@{ stopUtc = $at; power = 'PowerState/running' } } }
                Test-VmfStartOnTargetStop -Doc ([pscustomobject]@{ history = @($nc) }) | Should -BeTrue
                Test-VmfStartOnTargetStop -Doc ([pscustomobject]@{ history = @($nc, $park); captured = (& $rec '2026-11-14T10:00:00Z') }) | Should -BeTrue
                Test-VmfStartOnTargetStop -Doc ([pscustomobject]@{ history = @($nc, $park) }) | Should -BeFalse -Because 'no record of that attempt'
                Test-VmfStartOnTargetStop -Doc ([pscustomobject]@{ history = @($nc, $park); captured = (& $rec '2026-11-13T10:00:00Z') }) | Should -BeFalse -Because 'a record of an older attempt'
                $restored = [pscustomobject]@{ tsUtc = '2026-11-14T11:00:00Z'; state = 'NEEDS_DECISION'; reasonCode = 'clusterNode'; machineState = 'restored' }
                Test-VmfStartOnTargetStop -Doc ([pscustomobject]@{ history = @($nc, $restored); captured = (& $rec '2026-11-14T10:00:00Z') }) | Should -BeFalse -Because 'Azure started it again: it runs'
                $failed = [pscustomobject]@{ tsUtc = '2026-11-14T11:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackFailed'; machineState = 'changed' }
                Test-VmfStartOnTargetStop -Doc ([pscustomobject]@{ history = @($nc, $failed); captured = (& $rec '2026-11-14T10:00:00Z') }) | Should -BeFalse -Because 'a machine left changed'
            }
        }

        It 'a move that needs a change inside the machine first starts on the original size, as before, and says why' {
            Script:RoNoCapacity -Os 'Windows'
            $plan = Script:RoToV5 -Os 'Windows'
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Not -Be 'MIGRATED'
            @($global:roOrder | Where-Object { $_ -like 'size:*' }) | Should -BeNullOrEmpty -Because 'nothing changed'
            (Global:RoDoc).captured.PSObject.Properties['startOnTarget'] | Should -BeNullOrEmpty
            @(Script:RoLines 'PRECHECK' | Where-Object { $_.detail -match 'This move needs the machine to run on Standard_D2s_v4 before the change\. The target size can give the MANA adapter' }) | Should -Not -BeNullOrEmpty
        }

        It 'a machine somebody started since is checked on its original size, as any retry' {
            Script:RoNoCapacity
            $plan = Script:RoToV5
            $null = Script:RoRetry
            $global:roNoCapacity = $false
            $global:roPower = 'PowerState/running'
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            (Global:RoDoc).captured.PSObject.Properties['startOnTarget'] | Should -BeNullOrEmpty
            Script:RoBefore 'script:cluster-node-check.sh@Standard_D2s_v4' 'size:Standard_D2s_v5' | Should -BeTrue -Because 'the checks run before the change'
        }

        It 'a retry on the series it had (v6) starts on the original size first, as before' {
            Script:RoNoCapacity
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $final = Script:RoRun (Script:RoPlan)
            @($global:roOrder | Where-Object { $_ -like 'size:*' }) | Should -BeNullOrEmpty
            (Global:RoDoc).captured.PSObject.Properties['startOnTarget'] | Should -BeNullOrEmpty
            $final.state | Should -Not -Be 'MIGRATED'
        }
    }

    Context 'Case B: Azure refused the original size in the rollback' {
        BeforeEach {
            Script:RoMockAzure
            Script:RoMockGuest @{ 'Standard_D2s_v4' = '/; /boot; /var/crash'; 'Standard_D2s_v6' = '/; /boot'; 'Standard_D2s_v5' = '/; /boot; /var/crash' }
            $script:planV6 = Script:RoPlan
            Script:RoWritePlan $script:planV6
            $global:roRefuse = $script:original
            $first = Script:RoRun $script:planV6
            $first.state | Should -Be 'FAILED_NEEDS_ATTENTION' -Because ([string]@($first.history)[-1].detail)
            @($first.history)[-1].reasonCode | Should -Be 'rollbackSizeRefused'
            $global:roSize | Should -Be 'Standard_D2s_v6'
        }

        It 'Restore this machine from the first copy goes onto the v5 size of the plan, and the record says so' {
            $null = Script:RoToV5
            $global:roOrder.Clear()
            $r = Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'move it to v5' -Confirm:$false
            $r | Should -Not -BeNullOrEmpty
            $global:roSize | Should -Be 'Standard_D2s_v5'
            @($global:roOrder | Where-Object { $_ -eq "size:$($script:original)" }) | Should -BeNullOrEmpty -Because 'never the size Azure refused'
            $doc = Global:RoDoc
            $doc.restore.ontoTarget.size | Should -Be 'Standard_D2s_v5'
            $doc.restore.ontoTarget.option | Should -Be 'v5'
            $doc.restore.ontoTarget.originalSize | Should -Be $script:original
            $doc.restore.sizeAfter | Should -Be 'Standard_D2s_v5'
            $doc.captured.original.vmConfig.size | Should -Be 'Standard_D2s_v5'
            $doc.captured.original.sizeReplaced.size | Should -Be $script:original
            (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse -Because 'the restore mends the stop'
            @(Script:RoLines 'restore' | Where-Object { $_.detail -match '^Azure refused the original size Standard_D2s_v4, so the restore put the machine on Standard_D2s_v5' }) | Should -Not -BeNullOrEmpty
        }

        It 'then Try this machine again moves it, and its rollback returns it to the v5 size - never the size Azure refused' {
            $plan = Script:RoToV5
            $null = Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'move it to v5' -Confirm:$false
            $null = Script:RoRetry
            Mock -ModuleName VmMigrationFactory Test-VmfNicFidelity { @{ Ok = $false; Detail = 'the interface nic1 is not on the machine' } }
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'FAILED_ROLLED_BACK' -Because ([string]@($final.history)[-1].detail)
            @($global:roOrder | Where-Object { $_ -eq "size:$($script:original)" }) | Should -BeNullOrEmpty
            $global:roSize | Should -Be 'Standard_D2s_v5'
            # The reports: before is the size the machine had, now the v5 size,
            # and the sentence says why - never "not changed".
            $r = Script:RoReports
            $r.Row.before.size | Should -Be $script:original
            $r.Row.now.size | Should -Be 'Standard_D2s_v5'
            $r.Row.now.basis | Should -Be 'the restore record. Azure refused Standard_D2s_v4 in a rollback. A restore then changed the size of the machine to Standard_D2s_v5.'
            $r.Iac.size | Should -Be 'Standard_D2s_v4 to Standard_D2s_v5. Azure refused Standard_D2s_v4 in a rollback. A restore then changed the size of the machine to Standard_D2s_v5.'
        }

        It 'then Try this machine again moves it to MIGRATED' {
            $plan = Script:RoToV5
            $null = Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'move it to v5' -Confirm:$false
            $null = Script:RoRetry
            $global:roOrder.Clear()
            $final = Script:RoRun $plan
            $final.state | Should -Be 'MIGRATED' -Because ([string]@($final.history)[-1].detail)
            $r = Script:RoReports
            $r.Row.before.size | Should -Be $script:original -Because 'before is the size the machine had, not the v5 size the restore put on the first capture'
            $r.Row.now.size | Should -Be 'Standard_D2s_v5'
            $r.Row.now.basis | Should -Match 'Azure refused Standard_D2s_v4 in a rollback. A restore then changed the size of the machine to Standard_D2s_v5\.$'
            $r.Iac.size | Should -Be 'Standard_D2s_v4 to Standard_D2s_v5. Azure refused Standard_D2s_v4 in a rollback. A restore then changed the size of the machine to Standard_D2s_v5.'
        }

        It 'a machine with no restore onto the size keeps its report words as before' {
            $r = Script:RoReports
            $r.Row.before.size | Should -Be $script:original
            $r.Iac.size | Should -Not -Match 'Azure refused'
        }

        It 'with the plan still on v6, the restore goes to the original size, as before' {
            $global:roRefuse = ''
            $global:roNoCapacity = $false
            $null = Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'the restriction is gone' -Confirm:$false
            $global:roSize | Should -Be $script:original
            $doc = Global:RoDoc
            $doc.restore.ontoTarget | Should -BeNullOrEmpty
            $doc.captured.original.vmConfig.size | Should -Be $script:original
        }

        It 'a machine in a capacity reservation group of its own is refused before anything changes' {
            $null = Script:RoToV5
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                $d.captured.original.vmConfig.capacityReservationGroupId = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/crg-own'
                Write-VmfStateDoc -RunPath $rp -Document $d
            }
            $global:roOrder.Clear()
            { Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'v5' -Confirm:$false } |
                Should -Throw "*capacity reservation group 'crg-own'*"
            @($global:roOrder | Where-Object { $_ -like 'size:*' -or $_ -eq 'deallocate' -or $_ -like 'disk:*' }) | Should -BeNullOrEmpty
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Get-VmfPutBackRetirementRefusal -RunPath $rp -VmId $id } |
                Should -Match "capacity reservation group 'crg-own'" -Because 'the service refuses it before a job starts'
        }

        It 'a Preview move is refused that restore by the service and the engine, with no read of the preview feature' {
            $null = Script:RoToV5
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                $d.captured.startedTarget.target | Add-Member -NotePropertyName choice -Force -NotePropertyValue ([pscustomobject]@{ option = 'v6'; method = 'preview' })
                Write-VmfStateDoc -RunPath $rp -Document $d
            }
            Mock -ModuleName VmMigrationFactory Get-VmfPreviewFeatureState { throw 'the feature is not read for this restore' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Get-VmfPreviewPutBackRefusal -RunPath $rp -VmId $id } |
                Should -Match 'in-place upgrade \(Preview\), and the product does not restore it onto another size'
            $global:roOrder.Clear()
            { Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'v5' -Confirm:$false } |
                Should -Throw '*in-place upgrade (Preview)*'
            @($global:roOrder | Where-Object { $_ -like 'size:*' -or $_ -eq 'deallocate' -or $_ -like 'disk:*' }) | Should -BeNullOrEmpty
        }

        It 'kill-resume: a restore started again uses the size it decided when it started, whatever the plan says now' {
            $null = Script:RoToV5
            # The platform stopped the container: the job's finally never ran.
            Mock -ModuleName VmMigrationFactory Close-VmfPutBackJob { }
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'The job of the restore stopped.' }
            { Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -From 'pristine' -RestoredBy 'operator@example.com' -Note 'v5' -CorrelationId 'op-ro-1' -Confirm:$false } | Should -Throw
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:roOrder.Add("swapOs:$DiskName") }
            $job = (Global:RoDoc).putBackJob
            $job | Should -Not -BeNullOrEmpty -Because 'the stopped job left its checkpoint'
            $job.options.ontoSize | Should -Be 'Standard_D2s_v5'
            # The plan changes back to v6 meanwhile.
            Script:RoWritePlan $script:planV6
            $null = Restore-VmfVm -RunPath $script:runPath -VmId $script:vmId -Resume -CorrelationId 'op-ro-1' -Confirm:$false
            (Global:RoDoc).restore.ontoTarget.size | Should -Be 'Standard_D2s_v5'
        }
    }
}

Describe 'The words of both stops' {
    It 'rollbackNoCapacity names Change to v5 and says that move starts on the new size' {
        InModuleScope VmMigrationFactory {
            $w = Get-VmfRollbackNoCapacityWords -Size 'Standard_D2s_v3'
            $w | Should -Match 'Or select Change to v5\.'
            $w | Should -Match 'A move to v5 changes the size first, and then starts the machine\.'
            $w | Should -Not -Match 'also starts the machine on'
            (Get-VmfStopGuidance -Code 'rollbackNoCapacity').whatToDo | Should -Match 'Change to v5'
            (Get-VmfStopGuidance -Code 'rollbackSizeRefused').whatToDo | Should -Match 'The restore changes the machine to the v5 size\.'
        }
    }
}
