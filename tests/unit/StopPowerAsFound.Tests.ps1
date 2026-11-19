#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STOP-POWER-AS-FOUND-1, 2026-11-05 (seen in the lab on the DISK-TYPE-DEALLOCATED-1
# run): a machine that was deallocated when its move started was left running,
# and billed, when the move stopped before it changed anything.
#
# Checking starts a machine that is not running for the cluster check, and
# records the power state it found (captured.clusterCheckPower, status
# goingOn). Every stop after that start and before the first change used to
# START the machine ("as it was before the move") whatever the record said.
#
# Now one rule: a stop that leaves the machine untouched puts back the power
# state the record holds - deallocated with Stop-VmfVmDeallocated, stopped
# with Stop-VmfVmPoweredOff - the way the cluster check itself does. Running,
# or no record: it starts the machine, as before. A put-back that fails is
# said, and the machine is recorded changed.
#
# The engine runs for real here, with the REAL cluster check (so the record is
# the one the product writes). Azure is a small power model: each call that
# changes the power sets $global:spPower, and Get-VmfPowerState reads it.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above.
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'

    function Script:SpPlan {
        param([string]$Os = 'Linux', [string]$Size = 'Standard_D2s_v6', [string]$Controller = 'NVMe')
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = $Size; diskArch = 'diskless'; controller = $Controller }
            path = 'A'; policy = [pscustomobject]@{}; decisions = @()
        }
    }

    function Script:SpFakeVm {
        [pscustomobject]@{
            Id = $script:vmId; Name = 'vm-under-test'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = $global:spOs; Name = 'vm-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    # The step the engine is in, from the machine's state document.
    function Global:SpEngineStep {
        & (Get-Module VmMigrationFactory) { param($rp, $id) [string](Read-VmfStateDoc -RunPath $rp -VmId $id).state } $global:spRunPath $script:vmId
    }

    # Azure, as a power model. $global:spFail is a script block asked before
    # each power call with the call's name: it throws to make Azure refuse it.
    function Script:SpMockAzure {
        param([string]$Found = 'PowerState/deallocated', [string]$Os = 'Linux')
        $global:spOs = $Os
        $global:spPower = $Found
        $global:spCalls = [System.Collections.Generic.List[string]]::new()
        $global:spFail = { param($name) }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:spPower }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Script:SpFakeVm }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { & $global:spFail 'snapshot'; '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:spFail 'deallocate'; $global:spCalls.Add('deallocate'); $global:spPower = 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:spFail 'powerOff'; $global:spCalls.Add('powerOff'); $global:spPower = 'PowerState/stopped' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:spFail 'start'; $global:spCalls.Add('start'); $global:spPower = 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:spCalls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm-os'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { & $global:spFail "disk:$DiskName"; "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:spCalls.Add('swapOs') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
    }

    function Global:SpOut {
        param([string]$Script, [string]$Result, [object[]]$Checks = @())
        [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
    }

    # The guest. The cluster check answers "not a cluster node", so the move
    # goes on and the record says goingOn. $global:spAnswers names the answer
    # of any other script.
    function Script:SpMockGuest {
        param([hashtable]$Answers = @{})
        $global:spAnswers = $Answers
        $global:spScripts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
            [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            $name = [string]$ScriptString
            $global:spScripts.Add($name)
            $answer = $global:spAnswers[$name]
            $out = if ($answer -is [scriptblock]) { & $answer }
                   elseif ($answer) { Global:SpOut $name $answer }
                   else {
                       switch ($name) {
                           'cluster-node-check.sh' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                                   facts = [ordered]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                           # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                           'sriov-unmanaged-check.sh' { [ordered]@{ schema = 'vmf.guest/7'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                           'Test-ClusterNode.ps1' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                                   facts = [ordered]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } } }
                           'mana-check.sh' { Global:SpOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                           'Test-ManaReady.ps1' { Global:SpOut $name 'READY' @(@{ name = 'mana adapter bound'; status = 'PASS'; detail = 'Ethernet 3' }) }
                           'Install-ManaDriver.ps1' { Global:SpOut $name 'NO_CHANGE' }
                           # VOLUMES-ONLINE-V5-1: a v5 move on Linux installs the LVM start task;
                           # with no devices file in use it changes nothing.
                           'lvm-devices-task.sh' { Global:SpOut $name 'NO_CHANGE' }
                           'nvme-check.sh' { Global:SpOut $name 'NEEDS_PREP' }
                           'Test-NvmeReady.ps1' { Global:SpOut $name $(if ($global:spScripts -contains 'Set-NvmeReady.ps1') { 'READY' } else { 'NEEDS_PREP' }) }
                           { $_ -in @('Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1', 'nvme-fix.sh', 'temp-disk-setup.sh') } { Global:SpOut $name 'FIXED' @(@{ name = 'change'; status = 'FIXED'; detail = 'x' }) }
                           default { Global:SpOut $name 'READY' }
                       }
                   }
            $out | ConvertTo-Json -Depth 8 -Compress
        }
    }

    function Script:SpRun {
        param($Plan)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'sp-test'
        }
    }

    function Script:SpStop { param($Doc) @($Doc.history)[-1] }

    function Script:SpRecord {
        $d = & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:runPath $script:vmId
        $d.captured.clusterCheckPower
    }

    # The power calls after the last start of the move - what the stop did.
    function Script:SpAfterLastStart {
        $all = @($global:spCalls | Where-Object { $_ -in @('deallocate', 'powerOff', 'start') })
        $at = [array]::LastIndexOf($all, 'start')
        if ($at -lt 0 -or $at -eq $all.Count - 1) { return @() }
        @($all[($at + 1)..($all.Count - 1)])
    }
}

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface', 'function:\SpEngineStep', 'function:\SpOut' -ErrorAction SilentlyContinue
    Remove-Variable spOs, spPower, spCalls, spFail, spAnswers, spScripts, spRunPath -Scope Global -ErrorAction SilentlyContinue
}

Describe 'STOP-POWER-AS-FOUND-1: a stop before any change puts back the power state that Checking found' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:spRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'sp-test' | Out-Null }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    Context 'Safety copies: a rollback disk that Azure does not make (rollbackDisksBeforeMoveNotMade)' {
        It 'a machine found <Found> ends <Found>, untouched, and the stop says so' -ForEach @(
            @{ Found = 'PowerState/deallocated'; Words = 'The product deallocated the machine again, as it was before the move\.'; After = @('deallocate') }
            @{ Found = 'PowerState/stopped'; Words = 'The product stopped the machine again, as it was before the move\.'; After = @('powerOff') }
        ) {
            Script:SpMockAzure -Found $Found
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' } }
            $final = Script:SpRun (Script:SpPlan)

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
            $stop.machineState | Should -Be 'untouched'
            $global:spPower | Should -Be $Found -Because 'the machine goes back to the power state the cluster check found'
            $stop.detail | Should -Match $Words
            @(Script:SpAfterLastStart) | Should -Be $After -Because "one put-back, never two (calls: $($global:spCalls -join ', '))"
        }

        It 'a machine found running is started again, as before, and the stop says nothing of a power state put back' {
            Script:SpMockAzure -Found 'PowerState/running'
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' } }
            $final = Script:SpRun (Script:SpPlan)

            (Script:SpStop $final).reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
            (Script:SpStop $final).machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/running'
            (Script:SpStop $final).detail | Should -Not -Match 'as it was before the move'
            Script:SpRecord | Should -BeNullOrEmpty -Because 'the cluster check started nothing'
        }

        It 'a put-back that Azure refuses is said, and the machine is recorded changed' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest
            $global:spDeallocs = 0
            $global:spFail = {
                param($name)
                if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
                if ($name -eq 'deallocate') { $global:spDeallocs++; if ($global:spDeallocs -gt 1) { throw 'OperationNotAllowed: the machine is busy.' } }
            }
            try { $final = Script:SpRun (Script:SpPlan) }
            finally { Remove-Variable spDeallocs -Scope Global -ErrorAction SilentlyContinue }

            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
            $stop.machineState | Should -Be 'changed'
            $stop.detail | Should -Match 'The machine was deallocated before the move, and the product could not deallocate it again'
            $stop.detail | Should -Match 'OperationNotAllowed'
            $global:spPower | Should -Be 'PowerState/running'
        }
    }

    Context 'Preparing: a stop that changed nothing' {
        It 'a read-only check that is BLOCKED, on a machine found <Found>, ends <Found>, untouched' -ForEach @(
            @{ Found = 'PowerState/deallocated'; Words = 'The product deallocated the machine again, as it was before the move\.' }
            @{ Found = 'PowerState/stopped'; Words = 'The product stopped the machine again, as it was before the move\.' }
        ) {
            Script:SpMockAzure -Found $Found -Os 'Windows'
            Script:SpMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
            $final = Script:SpRun (Script:SpPlan -Os 'Windows')

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            $stop = Script:SpStop $final
            $stop.machineState | Should -Be 'untouched'
            $global:spPower | Should -Be $Found
            $stop.detail | Should -Match $Words
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0
        }

        It 'a put-back that Azure refuses is said, and the machine is recorded changed' {
            Script:SpMockAzure -Found 'PowerState/deallocated' -Os 'Windows'
            Script:SpMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
            $global:spFail = { param($name) if ($name -eq 'deallocate' -and (Global:SpEngineStep) -eq 'GUEST_PREP') { throw 'OperationNotAllowed: the machine is busy.' } }
            $final = Script:SpRun (Script:SpPlan -Os 'Windows')

            $stop = Script:SpStop $final
            $stop.machineState | Should -Be 'changed'
            $stop.detail | Should -Match 'The machine was deallocated before the move, and the product could not deallocate it again \(OperationNotAllowed'
            $global:spPower | Should -Be 'PowerState/running'
        }

        It 'a machine found running stays running, as before' {
            Script:SpMockAzure -Found 'PowerState/running' -Os 'Windows'
            Script:SpMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
            $final = Script:SpRun (Script:SpPlan -Os 'Windows')

            (Script:SpStop $final).machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/running'
            (Script:SpStop $final).detail | Should -Not -Match 'as it was before the move'
        }

        It 'a step that throws at every attempt before any change, on a machine found deallocated, ends deallocated' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest -Answers @{ 'nvme-check.sh' = { throw 'The guest agent is not ready.' } }
            $final = Script:SpRun (Script:SpPlan)

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            (Script:SpStop $final).machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/deallocated'
            (Script:SpStop $final).detail | Should -Match 'the product deallocated the machine again, as it was before the move'
        }
    }

    Context 'Preparing: a step that throws at every attempt, and a put-back that Azure refuses' {
        It 'is said, and the machine is recorded changed' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest -Answers @{ 'nvme-check.sh' = { throw 'The guest agent is not ready.' } }
            $global:spFail = { param($name) if ($name -eq 'deallocate' -and (Global:SpEngineStep) -eq 'GUEST_PREP') { throw 'OperationNotAllowed: the machine is busy.' } }
            $final = Script:SpRun (Script:SpPlan)

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            (Script:SpStop $final).machineState | Should -Be 'changed'
            (Script:SpStop $final).detail | Should -Match 'the machine was deallocated before the move, and the product could not deallocate it again'
        }
    }

    Context 'Shutting down: a deallocation that fails when nothing changed (deallocationFailed)' {
        It 'a machine found stopped is stopped again, untouched' {
            Script:SpMockAzure -Found 'PowerState/stopped'
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -eq 'deallocate' -and (Global:SpEngineStep) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' } }
            $final = Script:SpRun (Script:SpPlan -Size 'Standard_D2as_v5' -Controller 'SCSI')

            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'deallocationFailed'
            $stop.machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/stopped'
            $stop.detail | Should -Match 'The product stopped the machine again, as it was before the move\.'
            $stop.detail | Should -Not -Match 'restarted'
        }

        It 'a machine found deallocated that Azure does not deallocate again is said, and recorded changed' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -eq 'deallocate' -and (Global:SpEngineStep) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' } }
            $final = Script:SpRun (Script:SpPlan -Size 'Standard_D2as_v5' -Controller 'SCSI')

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'deallocationFailed'
            $stop.machineState | Should -Be 'changed'
            $stop.detail | Should -Match 'The machine was deallocated before the move, and the product could not deallocate it again'
        }

        It 'a machine found running is started again, as before' {
            Script:SpMockAzure -Found 'PowerState/running'
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -eq 'deallocate' -and (Global:SpEngineStep) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' } }
            $final = Script:SpRun (Script:SpPlan -Size 'Standard_D2as_v5' -Controller 'SCSI')

            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            (Script:SpStop $final).machineState | Should -Be 'untouched'
            (Script:SpStop $final).detail | Should -Match 'The product started the machine again\. Nothing on the machine changed\.'
            $global:spPower | Should -Be 'PowerState/running'
        }
    }

    Context 'Safety copies: a copy that fails at every attempt (EVAL-H4)' {
        It 'a machine found <Found> ends <Found>, and the stop says so' -ForEach @(
            @{ Found = 'PowerState/deallocated'; Words = 'the product deallocated the machine again, as it was before the move'; Starts = 1 }
            @{ Found = 'PowerState/stopped'; Words = 'the product stopped the machine again, as it was before the move'; Starts = 2 }
        ) {
            Script:SpMockAzure -Found $Found
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -eq 'snapshot') { throw 'InternalExecutionError: the snapshot did not finish.' } }
            $final = Script:SpRun (Script:SpPlan)

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            $stop = Script:SpStop $final
            $stop.machineState | Should -Be 'restored'
            $global:spPower | Should -Be $Found
            $stop.detail | Should -Match $Words
            # The cluster check starts it; a stopped machine is started once more, to power it off.
            @($global:spCalls | Where-Object { $_ -eq 'start' }) | Should -HaveCount $Starts -Because "calls: $($global:spCalls -join ', ')"
        }

        It 'a machine found running is started again, as before' {
            Script:SpMockAzure -Found 'PowerState/running'
            Script:SpMockGuest
            $global:spFail = { param($name) if ($name -eq 'snapshot') { throw 'InternalExecutionError: the snapshot did not finish.' } }
            $final = Script:SpRun (Script:SpPlan)

            (Script:SpStop $final).machineState | Should -Be 'restored'
            $global:spPower | Should -Be 'PowerState/running'
            (Script:SpStop $final).detail | Should -Match 'has been started again'
        }
    }

    Context 'Checking: a step that throws after the cluster check started the machine' {
        It 'a machine found deallocated ends deallocated, untouched' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest
            Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { throw 'The store did not answer.' }
            $final = Script:SpRun (Script:SpPlan)

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            (Script:SpStop $final).machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/deallocated'
            (Script:SpStop $final).detail | Should -Match 'the product deallocated the machine again, as it was before the move'
        }

        It 'a machine found running stays running, with no words of a put-back' {
            Script:SpMockAzure -Found 'PowerState/running'
            Script:SpMockGuest
            Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { throw 'The store did not answer.' }
            $final = Script:SpRun (Script:SpPlan)

            (Script:SpStop $final).machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/running'
            @($global:spCalls | Where-Object { $_ -in @('deallocate', 'powerOff') }) | Should -HaveCount 0
        }
    }

    Context 'The step limit: a machine that goes round, stopped before any change' {
        It 'a machine found deallocated ends deallocated' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest
            InModuleScope VmMigrationFactory { $script:spLimitWas = $script:VmfStateLoopLimit; $script:VmfStateLoopLimit = 2 }
            try { $final = Script:SpRun (Script:SpPlan) }
            finally { InModuleScope VmMigrationFactory { $script:VmfStateLoopLimit = $script:spLimitWas } }

            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'stepLoopLimit'
            $global:spPower | Should -Be 'PowerState/deallocated' -Because "calls: $($global:spCalls -join ', ')"
            $stop.detail | Should -Match 'the product deallocated the machine again, as it was before the move'
        }

        It 'a machine that ends at Checking, after the cluster check started it, ends deallocated' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest
            # Checking throws after the cluster check, so the limit ends it at Checking.
            Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { throw 'The store did not answer.' }
            InModuleScope VmMigrationFactory { $script:spLimitWas = $script:VmfStateLoopLimit; $script:VmfStateLoopLimit = 2 }
            try { $final = Script:SpRun (Script:SpPlan) }
            finally { InModuleScope VmMigrationFactory { $script:VmfStateLoopLimit = $script:spLimitWas } }

            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'stepLoopLimit'
            $stop.detail | Should -Match 'stopped at PRECHECK'
            $stop.machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/deallocated' -Because "calls: $($global:spCalls -join ', ')"
            $stop.detail | Should -Match 'the product deallocated the machine again, as it was before the move'
        }
    }

    Context 'A permission stop at Checking on a resume, after the cluster check started the machine (NIC-JOIN-SCOPE-1)' {
        It 'the join on the network interface missing on the resume: the machine ends deallocated, untouched' {
            Script:SpMockAzure -Found 'PowerState/deallocated'
            Script:SpMockGuest
            # The first worker passes the cluster check (which starts the
            # machine and records goingOn), then loses its lease.
            Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { throw 'The lease of this machine is held by another worker: abandon this VM.' }
            { Script:SpRun (Script:SpPlan) } | Should -Throw '*abandon this VM*'
            $global:spPower | Should -Be 'PowerState/running' -Because 'the cluster check started it'
            (Script:SpRecord).status | Should -Be 'goingOn'
            Global:SpEngineStep | Should -Be 'PRECHECK'

            # The resume: the join on the network interface is gone now, so
            # Checking stops at the new gate, before the cluster check.
            Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { $null }
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
                if ($Scope -like '*/networkInterfaces/nic1') { return @([pscustomobject]@{ actions = @('Microsoft.Network/networkInterfaces/read'); notActions = @() }) }
                @([pscustomobject]@{ actions = @('*'); notActions = @() })
            }
            $final = Script:SpRun (Script:SpPlan)

            $stop = Script:SpStop $final
            $stop.reasonCode | Should -Be 'permissionMissingNetworkInterface'
            $stop.machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/deallocated' -Because "calls: $($global:spCalls -join ', ')"
            $stop.detail | Should -Match 'the product deallocated the machine again, as it was before the move'
        }
    }

    Context 'Kill and resume (rule 4)' {
        It 'a worker that stops in the put-back: the next worker puts the machine back and records one stop' {
            Script:SpMockAzure -Found 'PowerState/deallocated' -Os 'Windows'
            Script:SpMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
            # The put-back deallocates, then the worker loses its lease before
            # it records the stop.
            $global:spKilled = $false
            $global:spFail = {
                param($name)
                if ($name -eq 'deallocate' -and (Global:SpEngineStep) -eq 'GUEST_PREP' -and -not $global:spKilled) {
                    $global:spKilled = $true
                    $global:spPower = 'PowerState/deallocated'
                    throw 'The lease of this machine is held by another worker: abandon this VM.'
                }
            }
            try {
                { Script:SpRun (Script:SpPlan -Os 'Windows') } | Should -Throw '*abandon this VM*'
                Global:SpEngineStep | Should -Be 'GUEST_PREP' -Because 'nothing recorded the stop'
                (Script:SpRecord).status | Should -Be 'goingOn' -Because 'the record stays until the stop is on record, so the resume knows what to put back'

                $final = Script:SpRun (Script:SpPlan -Os 'Windows')
            }
            finally { Remove-Variable spKilled -Scope Global -ErrorAction SilentlyContinue }

            $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
            (Script:SpStop $final).machineState | Should -Be 'untouched'
            $global:spPower | Should -Be 'PowerState/deallocated'
            @($final.history | Where-Object { $_.state -eq 'FAILED_NEEDS_ATTENTION' }) | Should -HaveCount 1
        }

        It 'a person''s retry drops the record, so a machine somebody started since is never put back to an old power state' {
            Script:SpMockAzure -Found 'PowerState/deallocated' -Os 'Windows'
            Script:SpMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
            $null = Script:SpRun (Script:SpPlan -Os 'Windows')
            Script:SpRecord | Should -Not -BeNullOrEmpty
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt
            }
            Script:SpRecord | Should -BeNullOrEmpty
        }
    }
}

Describe 'STOP-POWER-AS-FOUND-1: the copy waits at Backing up and Moving' {
    BeforeAll {
        function Script:SpSeed {
            param([string]$Found)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; found = $Found } {
                param($rp, $id, $found)
                New-VmfStateDoc -RunPath $rp -RunId 'sp-test' -VmId $id | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $cap = [pscustomobject]@{}
                if ($found -ne 'PowerState/running') {
                    $cap | Add-Member -NotePropertyName clusterCheckPower -NotePropertyValue ([pscustomobject]@{ power = $found; status = 'goingOn'; tsUtc = '2026-11-05T00:00:00Z' })
                }
                $doc | Add-Member -NotePropertyName captured -NotePropertyValue $cap -Force
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        function Script:SpCtx {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id)
                New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'sp-test'
            }
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'sp-test' | Out-Null }
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'safetyCopyNotReady, a machine found <Found>: it ends <Found>, untouched' -ForEach @(
        @{ Found = 'PowerState/deallocated'; Calls = @('deallocate'); Words = 'the product deallocated the machine again, as it was before the move' }
        @{ Found = 'PowerState/stopped'; Calls = @('start', 'powerOff'); Words = 'the product stopped the machine again, as it was before the move' }
        @{ Found = 'PowerState/running'; Calls = @('start'); Words = 'has been started again' }
    ) {
        Script:SpMockAzure -Found 'PowerState/deallocated'
        Script:SpSeed -Found $Found
        Mock -ModuleName VmMigrationFactory Get-VmfInstantAccessCopyReadiness { @{ 0 = [pscustomobject]@{ lun = 0; Usable = $false; Complete = $false; TakenUtc = '2026-11-05T00:00:00Z' } } }
        Mock -ModuleName VmMigrationFactory Format-VmfCopyState { 'LUN 0 pending' }
        $c = Script:SpCtx
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $c } { param($c) Wait-VmfInstantAccessCopies -Context $c -MaxMinutes 1 -PollSeconds 0 }

        $r.Reason | Should -Be 'safetyCopyNotReady'
        $r.MachineState | Should -Be 'untouched'
        $r.PowerAsFound | Should -BeTrue
        $global:spPower | Should -Be $Found
        $r.Detail | Should -Match $Words
        @($global:spCalls) | Should -Be $Calls
    }

    It 'safetyCopyWindowShort, nothing changed, a machine found <Found>: it ends <Found>, untouched' -ForEach @(
        @{ Found = 'PowerState/deallocated'; Calls = @('deallocate'); Words = 'the product deallocated the machine again, as it was before the move' }
        @{ Found = 'PowerState/running'; Calls = @('start'); Words = 'has been started again' }
    ) {
        Script:SpMockAzure -Found 'PowerState/deallocated'
        Script:SpSeed -Found $Found
        Mock -ModuleName VmMigrationFactory Get-VmfInstantAccessCopyReadiness { @{ 0 = [pscustomobject]@{ lun = 0; Usable = $true; Complete = $false; State = 'InstantAccess'; MinutesLeft = 10 } } }
        Mock -ModuleName VmMigrationFactory Format-VmfCopyState { 'LUN 0 InstantAccess, 10 minutes left' }
        $c = Script:SpCtx
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $c; rp = $script:runPath; id = $script:vmId } {
            param($c, $rp, $id)
            Test-VmfCopyWindowBeforeConversion -Context $c -Doc (Read-VmfStateDoc -RunPath $rp -VmId $id)
        }

        $r.Reason | Should -Be 'safetyCopyWindowShort'
        $r.MachineState | Should -Be 'untouched'
        $r.PowerAsFound | Should -BeTrue
        $global:spPower | Should -Be $Found
        $r.Detail | Should -Match $Words
        @($global:spCalls) | Should -Be $Calls
    }
}

Describe 'STOP-POWER-AS-FOUND-1: the rule, alone' {
    It 'Get-VmfPowerAsFound: <Name>' -ForEach @(
        @{ Name = 'found deallocated, going on'; Record = @{ power = 'PowerState/deallocated'; status = 'goingOn' }; Want = 'PowerState/deallocated' }
        @{ Name = 'found stopped, going on'; Record = @{ power = 'PowerState/stopped'; status = 'goingOn' }; Want = 'PowerState/stopped' }
        @{ Name = 'found deallocated, started for the check'; Record = @{ power = 'PowerState/deallocated'; status = 'started' }; Want = 'PowerState/deallocated' }
        @{ Name = 'already put back by the cluster check'; Record = @{ power = 'PowerState/deallocated'; status = 'putBack' }; Want = $null }
        @{ Name = 'found running'; Record = @{ power = 'PowerState/running'; status = 'goingOn' }; Want = $null }
        @{ Name = 'no record'; Record = $null; Want = $null }
    ) {
        $doc = [pscustomobject]@{ captured = [pscustomobject]@{} }
        if ($Record) { $doc.captured | Add-Member -NotePropertyName clusterCheckPower -NotePropertyValue ([pscustomobject]$Record) }
        $got = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerAsFound -Doc $d }
        $got | Should -Be $Want
    }
}

Describe 'STOP-POWER-WORDS-1: the reason pages say the power state the stop puts back' {
    # STOP-POWER-AS-FOUND-1 made these three stops put back the power state
    # Checking found (Restore-VmfPowerAsFound), but their meanings in
    # stop-reasons.json still said only that the product started the machine
    # again. A machine that was deallocated before the move is deallocated
    # again, and the page must say so - and say what a refused put-back does.
    BeforeAll {
        $script:powerReasons = (Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons
    }

    It '<Code>: a machine that was running, or that has no record, started again' -ForEach @(
        @{ Code = 'deallocationFailed' }, @{ Code = 'safetyCopyNotReady' }, @{ Code = 'safetyCopyWindowShort' }
    ) {
        $r = $script:powerReasons | Where-Object code -EQ $Code
        $r.meaning | Should -Match 'If the machine was running before the move, or the product has no record of its power state, the product started it again\.'
    }

    It '<Code>: a machine that was deallocated or stopped went back to that power state' -ForEach @(
        @{ Code = 'deallocationFailed' }, @{ Code = 'safetyCopyNotReady' }, @{ Code = 'safetyCopyWindowShort' }
    ) {
        $r = $script:powerReasons | Where-Object code -EQ $Code
        $r.meaning | Should -Match 'If the machine was not running before the move, the product stopped it again, in the same power state that it had\.'
    }

    It '<Code>: a put-back that fails is said, and the panel says the machine is not as it was' -ForEach @(
        # POWER-ONLY-CHANGED-1 folded DEALLOC-START-SAID-1: a failed start is said too.
        @{ Code = 'deallocationFailed'; Failed = 'could not start it or stop it again' }
        @{ Code = 'safetyCopyNotReady'; Failed = 'could not start it or stop it again' }
        @{ Code = 'safetyCopyWindowShort'; Failed = 'could not start it or stop it again' }
    ) {
        $r = $script:powerReasons | Where-Object code -EQ $Code
        $r.meaning | Should -Match "Then nothing on the machine changed\. If the product $Failed, the stop says so\. The panel then says that the machine is not as it was\."
    }

    It 'deallocationFailed says a failed start: the engine now tries the start again and records it (POWER-ONLY-CHANGED-1, folding DEALLOC-START-SAID-1)' {
        # Rewritten to the new rule: the STOPPED branch with no record used to
        # swallow a failed start and record untouched. It now says it, and the
        # stop names the power state Running (PowerOnlyChanged.Tests.ps1).
        ($script:powerReasons | Where-Object code -EQ 'deallocationFailed').meaning | Should -Match 'could not start it or stop it again'
    }

    It '<Code>: no sentence says the machine started again with no condition' -ForEach @(
        @{ Code = 'deallocationFailed' }, @{ Code = 'safetyCopyNotReady' }, @{ Code = 'safetyCopyWindowShort' }
    ) {
        $r = $script:powerReasons | Where-Object code -EQ $Code
        foreach ($s in @($r.meaning -split '(?<=\.)\s+')) {
            if ($s -match 'started (the machine|it) again') { $s | Should -Match '^If the machine was running before the move' -Because "$Code says: $s" }
        }
    }
}

Describe 'STOP-POWER-WORDS-1 review: no word says nothing changed when a refused put-back changed it' {
    # Review, 2026-11-06: safetyCopyNotReady said "Nothing on the machine
    # changed." with no condition, and its page line said "Nothing on this
    # machine was changed." - false after a put-back that failed, which
    # Wait-VmfInstantAccessCopies records changed.
    BeforeAll {
        $script:wordsReasons = (Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons
        $script:wordsPage = Get-Content (Join-Path $PSScriptRoot '..' '..' 'docs' 'manual' 'reference' 'stop-reasons.md') -Raw
        function Script:WordsSection([string]$Title) {
            $at = $script:wordsPage.IndexOf("## $Title")
            if ($at -lt 0) { return '' }
            $next = $script:wordsPage.IndexOf("`n## ", $at + 3)
            if ($next -lt 0) { $script:wordsPage.Substring($at) } else { $script:wordsPage.Substring($at, $next - $at) }
        }
    }

    It '<Code>: every "nothing changed" sentence follows the put-back, never before it' -ForEach @(
        @{ Code = 'deallocationFailed' }, @{ Code = 'safetyCopyNotReady' }, @{ Code = 'safetyCopyWindowShort' }
    ) {
        $r = $script:wordsReasons | Where-Object code -EQ $Code
        foreach ($s in @(([string]$r.title), @($r.meaning -split '(?<=\.)\s+')) | ForEach-Object { $_ }) {
            if ($s -match '(?i)nothing on (the machine|it|this machine) (was )?changed|machine was not changed') {
                $s | Should -BeExactly 'Then nothing on the machine changed.' -Because "$Code says: $s"
            }
        }
    }

    It '<Code>: says that its power state can come back wrong (machinePowerBack)' -ForEach @(
        @{ Code = 'deallocationFailed' }, @{ Code = 'safetyCopyNotReady' }, @{ Code = 'safetyCopyWindowShort' }
    ) {
        ($script:wordsReasons | Where-Object code -EQ $Code).machinePowerBack | Should -BeTrue
    }

    It '<Code>: the page line names a failed return to the power state, and <Rollback>' -ForEach @(
        @{ Code = 'deallocationFailed'; Rollback = 'a rollback'; Line = 'Nothing was changed, the product rolled the machine back, or the machine is not in its power state from before the move. The panel of the machine says which.' }
        @{ Code = 'safetyCopyNotReady'; Rollback = 'no rollback'; Line = 'Nothing on this machine was changed, or the machine is not in its power state from before the move. The panel of the machine says which.' }
        @{ Code = 'safetyCopyWindowShort'; Rollback = 'a rollback'; Line = 'Nothing was changed, the product rolled the machine back, or the machine is not in its power state from before the move. The panel of the machine says which.' }
    ) {
        $r = $script:wordsReasons | Where-Object code -EQ $Code
        $section = Script:WordsSection ([string]$r.title)
        $section | Should -Not -BeNullOrEmpty -Because "the page has the entry $Code"
        $section | Should -Match ([regex]::Escape("**The machine:** $Line"))
        $section | Should -Not -Match 'the tool'
    }

    It 'safetyCopyNotReady never says the product rolled the machine back: SAFETY_PRISTINE has no rollback' {
        $r = $script:wordsReasons | Where-Object code -EQ 'safetyCopyNotReady'
        Script:WordsSection ([string]$r.title) | Should -Not -Match 'rolled'
    }
}