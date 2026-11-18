#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# POWER-ONLY-CHANGED-1, 2026-11-06. STOP-POWER-AS-FOUND-1 puts a machine
# back to the power state Checking found when its move stops before any
# change. When Azure refused that put-back, the machine was recorded
# changed - true, it runs and bills - and its retry and its claim were held
# until a restore. But its disks, size, controller and network
# are as they were, and a stop at Checking has no safety copies to restore.
#
# The ruling (2026-11-06): the machine MUST go back to its power state, and
# a power-off is tried again until it is off, if that is how it was. A machine
# found Stopped (not deallocated) goes back to Stopped, as before. So:
#   1. the put-back is tried again, through the product's Azure retry
#      (Invoke-VmfAzOperation), whatever Azure answers - a bounded number of
#      times, with a wait between;
#   2. still refused: the stop is recorded changed, and names the power
#      state found (history[].powerNotPutBack, vm-state v37). Its retry is
#      not held for this alone (Test-VmfRetryHeld); its claim stays;
#   3. a person's retry puts the power state back FIRST, at Checking, and
#      only then runs the move again; still refused, the retry stops and says
#      so (powerNotPutBack). The record never says untouched while the power
#      differs (Add-VmfStateTransition);
#   4. the cluster check and Stop this migration record the same case the
#      same way;
#   5. a machine whose disks, size, controller or network changed keeps the
#      full hold.
#
# The engine runs for real, with the REAL cluster check, over the power model
# of StopPowerAsFound.Tests.ps1: each call that changes the power sets
# $global:pcPower, and Get-VmfPowerState reads it.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')

    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above.
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'

    function Script:PcPlan {
        param([string]$Os = 'Linux', [string]$Size = 'Standard_D2s_v6', [string]$Controller = 'NVMe')
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = $Size; diskArch = 'diskless'; controller = $Controller }
            path = 'A'; policy = [pscustomobject]@{}; decisions = @()
        }
    }

    function Script:PcFakeVm {
        [pscustomobject]@{
            Id = $script:vmId; Name = 'vm-under-test'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = $global:pcOs; Name = 'vm-os'; DeleteOption = 'Delete'
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
    function Global:PcEngineStep {
        & (Get-Module VmMigrationFactory) { param($rp, $id) [string](Read-VmfStateDoc -RunPath $rp -VmId $id).state } $global:pcRunPath $script:vmId
    }

    # Azure, as a power model. $global:pcFail is a script block asked before
    # each power call with the call's name: it throws to make Azure refuse it.
    function Script:PcMockAzure {
        param([string]$Found = 'PowerState/deallocated', [string]$Os = 'Linux')
        $global:pcOs = $Os
        $global:pcPower = $Found
        $global:pcCalls = [System.Collections.Generic.List[string]]::new()
        $global:pcFail = { param($name) }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:pcPower }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Script:PcFakeVm }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { & $global:pcFail 'snapshot'; '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:pcFail 'deallocate'; $global:pcCalls.Add('deallocate'); $global:pcPower = 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:pcFail 'powerOff'; $global:pcCalls.Add('powerOff'); $global:pcPower = 'PowerState/stopped' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:pcFail 'start'; $global:pcCalls.Add('start'); $global:pcPower = 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:pcCalls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm-os'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { & $global:pcFail "disk:$DiskName"; "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pcCalls.Add('swapOs') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
    }

    function Global:PcOut {
        param([string]$Script, [string]$Result, [object[]]$Checks = @())
        [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
    }

    # The guest. The cluster check answers "not a cluster node", so the move
    # goes on and the record says goingOn. $global:pcAnswers names the answer
    # of any other script.
    function Script:PcMockGuest {
        param([hashtable]$Answers = @{})
        $global:pcAnswers = $Answers
        $global:pcScripts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
            [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            $name = [string]$ScriptString
            $global:pcScripts.Add($name)
            $answer = $global:pcAnswers[$name]
            $out = if ($answer -is [scriptblock]) { & $answer }
                   elseif ($answer) { Global:PcOut $name $answer }
                   else {
                       switch ($name) {
                           'cluster-node-check.sh' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                                   facts = [ordered]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                           # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                           'sriov-unmanaged-check.sh' { [ordered]@{ schema = 'vmf.guest/7'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                           'Test-ClusterNode.ps1' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                                   facts = [ordered]@{ os = 'Windows'; clusterService = 'absent'; clusterKey = 'no'; sqlHadr = 'no' } } }
                           'mana-check.sh' { Global:PcOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                           'Test-ManaReady.ps1' { Global:PcOut $name 'READY' @(@{ name = 'mana adapter bound'; status = 'PASS'; detail = 'Ethernet 3' }) }
                           'Install-ManaDriver.ps1' { Global:PcOut $name 'NO_CHANGE' }
                           # VOLUMES-ONLINE-V5-1: a v5 move on Linux installs the LVM start task;
                           # with no devices file in use it changes nothing.
                           'lvm-devices-task.sh' { Global:PcOut $name 'NO_CHANGE' }
                           'nvme-check.sh' { Global:PcOut $name 'NEEDS_PREP' }
                           'Test-NvmeReady.ps1' { Global:PcOut $name $(if ($global:pcScripts -contains 'Set-NvmeReady.ps1') { 'READY' } else { 'NEEDS_PREP' }) }
                           { $_ -in @('Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1', 'nvme-fix.sh', 'temp-disk-setup.sh') } { Global:PcOut $name 'FIXED' @(@{ name = 'change'; status = 'FIXED'; detail = 'x' }) }
                           default { Global:PcOut $name 'READY' }
                       }
                   }
            $out | ConvertTo-Json -Depth 8 -Compress
        }
    }

    function Script:PcRun {
        param($Plan)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'pc-test'
        }
    }

    function Script:PcStop { param($Doc) @($Doc.history)[-1] }

    function Script:PcRecord {
        $d = & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:runPath $script:vmId
        $d.captured.clusterCheckPower
    }

    # The power calls after the last start of the move - what the stop did.
    function Script:PcAfterLastStart {
        $all = @($global:pcCalls | Where-Object { $_ -in @('deallocate', 'powerOff', 'start') })
        $at = [array]::LastIndexOf($all, 'start')
        if ($at -lt 0 -or $at -eq $all.Count - 1) { return @() }
        @($all[($at + 1)..($all.Count - 1)])
    }
    function Script:PcDoc {
        & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:runPath $script:vmId
    }
}

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface', 'function:\PcEngineStep', 'function:\PcOut' -ErrorAction SilentlyContinue
    Remove-Variable pcOs, pcPower, pcCalls, pcFail, pcAnswers, pcScripts, pcRunPath, pcTries -Scope Global -ErrorAction SilentlyContinue
}

Describe 'POWER-ONLY-CHANGED-1: a put-back that Azure refuses is tried again' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pcRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pc-test' | Out-Null }
        $script:tries = InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'the number of tries is more than one, with a wait between' {
        $script:tries | Should -BeGreaterThan 1
        (InModuleScope VmMigrationFactory { $script:VmfPowerPutBackDelayMs }) | Should -BeGreaterThan 0
    }

    It 'a deallocation Azure refuses twice, then does: the machine ends deallocated, untouched' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        # The first deallocation is the first safety copy's own. The put-back
        # after the refused disk is the second, third and fourth.
        $global:pcTries = 0
        $global:pcFail = {
            param($name)
            if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
            if ($name -eq 'deallocate') { $global:pcTries++; if ($global:pcTries -in 2, 3) { throw 'OperationNotAllowed: the machine is busy.' } }
        }
        $final = Script:PcRun (Script:PcPlan)

        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $stop.machineState | Should -Be 'untouched'
        $stop.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
        $global:pcPower | Should -Be 'PowerState/deallocated'
        $global:pcTries | Should -Be 4
        $stop.detail | Should -Match 'The product deallocated the machine again, as it was before the move\.'
    }

    It 'a deallocation Azure refuses at every try: changed, and the record names the power state found' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        $global:pcTries = 0
        $global:pcFail = {
            param($name)
            if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
            if ($name -eq 'deallocate') { $global:pcTries++; if ($global:pcTries -gt 1) { throw 'OperationNotAllowed: the machine is busy.' } }
        }
        $final = Script:PcRun (Script:PcPlan)

        $stop = Script:PcStop $final
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
        ($global:pcTries - 1) | Should -Be $script:tries -Because 'the put-back is sent the bounded number of times'
        $stop.detail | Should -Match "could not deallocate it again \(.*OperationNotAllowed.*\), after $($script:tries) tries"
        $stop.detail | Should -Match 'Try this machine again to return the machine to the power state Stopped \(deallocated\) first'
        $global:pcPower | Should -Be 'PowerState/running'
    }

    It 'an answer Azure gives as final (403) is tried again too: the rule is to put the machine back' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        $global:pcTries = 0
        $global:pcFail = {
            param($name)
            if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
            if ($name -eq 'deallocate') { $global:pcTries++; if ($global:pcTries -gt 1) { throw 'HTTP 403 AuthorizationFailed - the client has no permission.' } }
        }
        $final = Script:PcRun (Script:PcPlan)

        ($global:pcTries - 1) | Should -Be $script:tries
        (Script:PcStop $final).powerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'a machine found Stopped that Azure does not stop again: the record names Stopped' {
        Script:PcMockAzure -Found 'PowerState/stopped' -Os 'Windows'
        Script:PcMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
        $global:pcTries = 0
        $global:pcFail = { param($name) if ($name -eq 'powerOff') { $global:pcTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        $final = Script:PcRun (Script:PcPlan -Os 'Windows')

        $stop = Script:PcStop $final
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/stopped'
        $global:pcTries | Should -Be $script:tries
        $stop.detail | Should -Match 'return the machine to the power state Stopped first'
    }

    It 'a lost lease in the put-back is never tried again: another worker holds the machine' {
        Script:PcMockAzure -Found 'PowerState/deallocated' -Os 'Windows'
        Script:PcMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
        $global:pcTries = 0
        $global:pcFail = {
            param($name)
            if ($name -eq 'deallocate' -and (Global:PcEngineStep) -eq 'GUEST_PREP') { $global:pcTries++; throw 'The lease of this machine is held by another worker: abandon this VM.' }
        }
        { Script:PcRun (Script:PcPlan -Os 'Windows') } | Should -Throw '*abandon this VM*'
        $global:pcTries | Should -Be 1
    }
}

Describe 'POWER-ONLY-CHANGED-1: the cluster check records the same case the same way' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pcRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pc-test' | Out-Null }
        $script:tries = InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries }
        $script:node = {
            [ordered]@{ schema = 'vmf.guest/4'; script = 'cluster-node-check.sh'; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                facts = [ordered]@{ os = 'Linux'; pacemaker = 'active'; corosync = 'active'; sqlHadr = 'no' } }
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a cluster node, and a deallocation Azure refuses at every try: changed, with the power state found' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest -Answers @{ 'cluster-node-check.sh' = $script:node }
        $global:pcTries = 0
        $global:pcFail = { param($name) if ($name -eq 'deallocate') { $global:pcTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        $final = Script:PcRun (Script:PcPlan)

        $final.state | Should -Be 'NEEDS_DECISION'
        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'clusterNode'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
        $global:pcTries | Should -Be $script:tries
        $stop.detail | Should -Match 'Try this machine again to return the machine to the power state Stopped \(deallocated\) first'
    }

    It 'a cluster node, and a deallocation Azure refuses once, then does: untouched' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest -Answers @{ 'cluster-node-check.sh' = $script:node }
        $global:pcTries = 0
        $global:pcFail = { param($name) if ($name -eq 'deallocate') { $global:pcTries++; if ($global:pcTries -eq 1) { throw 'OperationNotAllowed: the machine is busy.' } } }
        $final = Script:PcRun (Script:PcPlan)

        $stop = Script:PcStop $final
        $stop.machineState | Should -Be 'untouched'
        $global:pcPower | Should -Be 'PowerState/deallocated'
        $global:pcTries | Should -Be 2
    }
}

Describe 'POWER-ONLY-CHANGED-1: a person''s retry puts the power state back first' {
    BeforeAll {
        function Script:PcWritePlan {
            param($Plan)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; entry = $Plan } {
                param($rp, $entry)
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
            }
        }
        function Script:PcRetry {
            # The wave's own start checks are not this item: they pass.
            Mock -ModuleName VmMigrationFactory Get-VmfWaveStartGate { $null }
            Resolve-VmfDecision -RunPath $script:runPath -PlanPath (Join-Path $script:runPath 'plan.json') -VmId $script:vmId `
                -Note 'try again' -ResolvedBy 'operator@example.com'
        }
        # The first attempt: the rollback disk is refused, and so is
        # every try of the put-back. The machine runs, found deallocated.
        function Script:PcFirstAttempt {
            param([string]$Found = 'PowerState/deallocated')
            Script:PcMockAzure -Found $Found
            Script:PcMockGuest
            $plan = Script:PcPlan
            Script:PcWritePlan $plan
            $global:pcFail = {
                param($name)
                if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
                if ($name -in @('deallocate', 'powerOff') -and (Global:PcEngineStep) -eq 'SAFETY_PRISTINE' -and $global:pcPutBack) { throw 'OperationNotAllowed: the machine is busy.' }
            }
            # The put-back is the power call after the disk was refused.
            Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:pcPutBack = $true; & $global:pcFail "disk:$DiskName"; "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
            $global:pcPutBack = $false
            $first = Script:PcRun $plan
            (Script:PcStop $first).powerNotPutBack | Should -Be $Found -Because 'the first attempt ends with the power state not put back'
            $global:pcPower | Should -Be 'PowerState/running'
            $plan
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pcRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pc-test' | Out-Null }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable pcPutBack -Scope Global -ErrorAction SilentlyContinue
    }

    It 'the retry is not held, and is accepted' {
        $null = Script:PcFirstAttempt
        $doc = Script:PcDoc
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
        { Script:PcRetry } | Should -Not -Throw
        (Script:PcDoc).state | Should -Be 'PRECHECK'
    }

    It 'the retry deallocates the machine before anything else, says so, and only then runs the move' {
        $plan = Script:PcFirstAttempt
        Script:PcRetry | Out-Null
        $global:pcCalls.Clear()
        $global:pcScripts.Clear()
        # Azure now takes the deallocation; the rollback disk is still refused.
        $global:pcFail = { param($name) if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' } }
        $final = Script:PcRun $plan

        @($global:pcCalls)[0] | Should -Be 'deallocate' -Because "the power state goes back first (calls: $($global:pcCalls -join ', '))"
        @($global:pcCalls)[1] | Should -Be 'start' -Because 'then Checking starts it for the cluster check, as for any machine found deallocated'
        $back = @($final.history | Where-Object { $_.state -eq 'PRECHECK' -and $_.machineState -eq 'untouched' })
        $back | Should -HaveCount 1
        $back[0].detail | Should -Match 'The product deallocated the machine again, as it was before the move\.'
        # The move ran again, to the same refused disk; the put-back now works.
        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $stop.machineState | Should -Be 'untouched'
        $global:pcPower | Should -Be 'PowerState/deallocated'
    }

    It 'a machine found Stopped goes back to Stopped first' {
        $plan = Script:PcFirstAttempt -Found 'PowerState/stopped'
        Script:PcRetry | Out-Null
        $global:pcCalls.Clear()
        $global:pcPutBack = $false
        $null = Script:PcRun $plan
        @($global:pcCalls)[0] | Should -Be 'powerOff' -Because "calls: $($global:pcCalls -join ', ')"
    }

    It 'a put-back still refused stops the retry at Checking, says so, and does nothing else' {
        $plan = Script:PcFirstAttempt
        Script:PcRetry | Out-Null
        $global:pcCalls.Clear()
        $global:pcScripts.Clear()
        $global:pcTries = 0
        $global:pcFail = { param($name) if ($name -eq 'deallocate') { $global:pcTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        $final = Script:PcRun $plan

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'powerNotPutBack'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
        $global:pcTries | Should -Be (InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries })
        @($global:pcCalls | Where-Object { $_ -ne 'deallocate' }) | Should -BeNullOrEmpty
        @($global:pcScripts) | Should -BeNullOrEmpty -Because 'no script runs in the machine'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot -Times 1 -Exactly -Because 'only the first attempt took a copy'
        $stop.detail | Should -Match 'The product did not try the move again'
        @($final.history | Where-Object { $_.machineState -eq 'untouched' }) | Should -BeNullOrEmpty -Because 'the record never says untouched while the power state differs'
    }

    It 'kill and resume (rule 4): a worker that stops after the put-back, before its line, puts it back again and goes on once' {
        $plan = Script:PcFirstAttempt
        Script:PcRetry | Out-Null
        $global:pcKilled = $false
        $global:pcFail = {
            param($name)
            if ($name -eq 'deallocate' -and (Global:PcEngineStep) -eq 'PRECHECK' -and -not $global:pcKilled) {
                $global:pcKilled = $true
                $global:pcPower = 'PowerState/deallocated'
                throw 'The lease of this machine is held by another worker: abandon this VM.'
            }
        }
        try {
            { Script:PcRun $plan } | Should -Throw '*abandon this VM*'
            Global:PcEngineStep | Should -Be 'PRECHECK'
            @((Script:PcDoc).history | Where-Object { $_.state -eq 'PRECHECK' -and $_.machineState -eq 'untouched' }) | Should -BeNullOrEmpty

            $global:pcFail = { param($name) if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' } }
            $final = Script:PcRun $plan
        }
        finally { Remove-Variable pcKilled -Scope Global -ErrorAction SilentlyContinue }

        @($final.history | Where-Object { $_.state -eq 'PRECHECK' -and $_.machineState -eq 'untouched' }) | Should -HaveCount 1
        (Script:PcStop $final).reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $global:pcPower | Should -Be 'PowerState/deallocated'
    }
}

Describe 'POWER-ONLY-CHANGED-1: the record never says untouched while the power state differs' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'pc-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'pc-test' -VmId $id | Out-Null
        }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a stop that says untouched, after a stop whose power state was not put back, is written changed with that power state' {
        $last = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackDisksBeforeMoveNotMade' `
                -MachineState 'changed' -PowerNotPutBack 'PowerState/stopped' -Detail 'a' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -Detail 'retry' | Out-Null
            $d = Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome fail -ReasonCode 'subscriptionNotReachable' -MachineState 'untouched' -Detail 'b'
            @($d.history)[-1]
        }
        $last.machineState | Should -Be 'changed'
        $last.powerNotPutBack | Should -Be 'PowerState/stopped'
    }

    It 'the line of a put-back that worked says untouched, and a stop after it is as it says' {
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackDisksBeforeMoveNotMade' `
                -MachineState 'changed' -PowerNotPutBack 'PowerState/deallocated' -Detail 'a' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -MachineState 'untouched' -PowerPutBack -Detail 'back' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome fail -ReasonCode 'sizeRetired' -MachineState 'untouched' -Detail 'b'
        }
        @($d.history)[-2].machineState | Should -Be 'untouched'
        @($d.history)[-1].machineState | Should -Be 'untouched'
        @($d.history)[-1].PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
    }

    It 'a machine changed in another way is not given a power state: untouched is written as it is said' {
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'rollbackFailed' -MachineState 'changed' -Detail 'a' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome fail -ReasonCode 'sizeRetired' -MachineState 'untouched' -Detail 'b'
        }
        @($d.history)[-1].machineState | Should -Be 'untouched'
    }

    It 'a power state not put back is only ever written on a changed stop' {
        {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id)
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -ReasonCode 'x' -MachineState 'untouched' -PowerNotPutBack 'PowerState/stopped' -Detail 'a'
            }
        } | Should -Throw '*changed*'
    }

}

Describe 'POWER-ONLY-CHANGED-1: the hold, alone' {
    BeforeAll {
        function Script:PcHeld($History, $Extra = @{}) {
            $doc = [pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; history = @($History | ForEach-Object { [pscustomobject]$_ }) }
            foreach ($k in $Extra.Keys) { $doc | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] }
            InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }
        }
    }

    It 'only the power state not put back: not held' {
        Script:PcHeld @(@{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackDisksBeforeMoveNotMade'; machineState = 'changed'; powerNotPutBack = 'PowerState/deallocated' }) | Should -BeFalse
    }
    It 'changed in another way (a rollback that failed): held, as before' {
        Script:PcHeld @(@{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackFailed'; machineState = 'changed' }) | Should -BeTrue
    }
    It 'a later stop that changed the machine in another way: held' {
        Script:PcHeld @(
            @{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackDisksBeforeMoveNotMade'; machineState = 'changed'; powerNotPutBack = 'PowerState/deallocated' }
            @{ tsUtc = '2026-11-06T11:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackFailed'; machineState = 'changed' }
        ) | Should -BeTrue
    }
    It 'a power state not put back with a data disk swap left: held' {
        Script:PcHeld @(@{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'rollbackDisksBeforeMoveNotMade'; machineState = 'changed'; powerNotPutBack = 'PowerState/deallocated' }) @{ swapPending = [pscustomobject]@{ kind = 'rollback' } } | Should -BeTrue
    }
    It 'a value this build does not know is not a power state: held' {
        Script:PcHeld @(@{ tsUtc = '2026-11-06T10:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; reasonCode = 'x'; machineState = 'changed'; powerNotPutBack = 'PowerState/starting' }) | Should -BeTrue
    }
    It 'Get-VmfPowerOwed: the power state to put back, from the last stop that says where it left the machine' {
        $doc = [pscustomobject]@{ history = @(
            [pscustomobject]@{ state = 'FAILED_NEEDS_ATTENTION'; machineState = 'changed'; powerNotPutBack = 'PowerState/stopped' }
            [pscustomobject]@{ state = 'PRECHECK'; outcome = 'ok' }) }
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -Be 'PowerState/stopped'
        $doc.history += [pscustomobject]@{ state = 'PRECHECK'; machineState = 'untouched' }
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -BeNullOrEmpty
        # Only a changed stop names a power state owed: the field on any other is not read.
        $other = [pscustomobject]@{ history = @([pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; machineState = 'restored'; powerNotPutBack = 'PowerState/stopped' }) }
        (InModuleScope VmMigrationFactory -Parameters @{ d = $other } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -BeNullOrEmpty
    }
}

Describe 'POWER-ONLY-CHANGED-1: Stop this migration records the same case the same way' {
    BeforeAll {
        function Script:PcSeed {
            param([string]$State, [string]$Record, [switch]$GuestChanged)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; st = $State; rec = $Record; gc = [bool]$GuestChanged } {
                param($rp, $id, $st, $rec, $gc)
                $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                    assessment = [ordered]@{ location = 'centralus'; classification = 'ReadyNow' }; target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
                New-VmfStateDoc -RunPath $rp -RunId 'pc-test' -VmId $id -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok -Detail 't' | Out-Null
                if ($rec) { Save-VmfCapturedFacts -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id }) -Facts @{ clusterCheckPower = [ordered]@{ power = 'PowerState/deallocated'; status = $rec; tsUtc = '2026-11-06T09:00:00Z' } } }
                if ($st -ne 'PRECHECK') { Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok -Detail 't' | Out-Null }
                $c = New-VmfVmClaim -RunPath $rp -VmId $id -RunId 'pc-test'
                if (-not $c.Granted) { throw "the test could not claim the machine: $($c.Detail)" }
            }
            if ($GuestChanged) { Mock -ModuleName VmMigrationFactory Test-VmfGuestChangedThisAttempt { $true } }
        }
        function Script:PcStopRun {
            Stop-VmfRun -RunPath $script:runPath -Reason 'closing' -StoppedBy 'operator@example.com' -Force -Confirm:$false | Out-Null
            @((Script:PcDoc).history)[-1]
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pc-test' -Kind 'migration' | Out-Null }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a machine at <State> that Checking started (record <Record>): changed, with the power state found, and its claim stays' -ForEach @(
        @{ State = 'PRECHECK'; Record = 'started' }
        @{ State = 'PRECHECK'; Record = 'goingOn' }
        @{ State = 'SAFETY_PRISTINE'; Record = 'goingOn' }
        @{ State = 'GUEST_PREP'; Record = 'goingOn' }
        @{ State = 'STOPPED'; Record = 'goingOn' }
        @{ State = 'SAFETY_COPY'; Record = 'goingOn' }
    ) {
        Script:PcSeed -State $State -Record $Record
        $line = Script:PcStopRun
        $line.state | Should -Be 'SKIPPED'
        $line.machineState | Should -Be 'changed'
        $line.powerNotPutBack | Should -Be 'PowerState/deallocated'
        $line.detail | Should -Match 'Stopped \(deallocated\)'
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Get-VmfVmClaim -RunPath $rp -VmId $id }) | Should -Not -BeNullOrEmpty
    }

    It 'a machine at Checking that Checking did not start: untouched, as before' {
        Script:PcSeed -State 'PRECHECK' -Record ''
        $line = Script:PcStopRun
        $line.machineState | Should -Be 'untouched'
        $line.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
    }

    It 'a machine the preparation changed keeps the full hold: changed, with no power state' {
        Script:PcSeed -State 'GUEST_PREP' -Record 'goingOn' -GuestChanged
        $line = Script:PcStopRun
        $line.machineState | Should -Be 'changed'
        $line.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
    }

    It 'a machine found running and stopped by the move at <State>: changed, owed Running, and its claim stays' -ForEach @(
        @{ State = 'SAFETY_PRISTINE' }, @{ State = 'STOPPED' }, @{ State = 'SAFETY_COPY' }
    ) {
        Script:PcSeed -State $State -Record ''
        $line = Script:PcStopRun
        $line.machineState | Should -Be 'changed'
        $line.powerNotPutBack | Should -Be 'PowerState/running'
        (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } { param($rp, $id) Get-VmfVmClaim -RunPath $rp -VmId $id }) | Should -Not -BeNullOrEmpty
    }

    It 'a machine that the move changed at <State> keeps the full hold' -ForEach @(
        @{ State = 'CONVERTING' }, @{ State = 'STARTING' }
    ) {
        Script:PcSeed -State $State -Record 'goingOn'
        $line = Script:PcStopRun
        $line.machineState | Should -Be 'changed'
        $line.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
    }
}

Describe 'POWER-ONLY-CHANGED-1: the contract' {
    BeforeAll {
        $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
        $script:schema = Get-Content (Join-Path $script:repo 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
    }
    It 'vm-state is at least v37 (now v39, POWER-AFTER-MOVE-1), and the store writes it' {
        $script:schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
    }
    It 'a history entry may name the power state not returned: Stopped (deallocated), Stopped, or Running' {
        $p = $script:schema.properties.history.items.properties.powerNotPutBack
        $p | Should -Not -BeNullOrEmpty
        @($p.enum) | Should -Be @('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running')
    }
    It 'the sample holds one, and the migration note says it' {
        $sample = Get-Content (Join-Path $script:repo 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
        @($sample.history | Where-Object { $_.PSObject.Properties['powerNotPutBack'] }) | Should -Not -BeNullOrEmpty
        $sample.schemaVersion | Should -Be 51
        Get-Content (Join-Path $script:repo 'docs' 'schema-migrations.md') -Raw | Should -Match 'vm-state v36 -> v37 \(2026-11-06, POWER-ONLY-CHANGED-1\)'
    }
    It 'the stop powerNotPutBack has words, and the retry it offers' {
        $r = (Get-Content (Join-Path $script:repo 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json).reasons | Where-Object code -EQ 'powerNotPutBack'
        $r | Should -Not -BeNullOrEmpty
        $r.machine | Should -Be 'changed'
        $r.retry | Should -Be 'afterFix'
    }
    It 'the product retry of Azure calls is the one mechanism: the put-back marks its error, and Invoke-VmfAzOperation tries it again' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $ops = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOps.ps1')
        $ops | Should -Match "Data\['vmfPowerRefused'\]"
        $work = Get-VmfCodeOnly -Path (Join-Path $script:repo 'src' 'VmMigrationFactory' 'Private' 'engine' 'WorkloadCheck.ps1')
        $work | Should -Match 'MaxAttempts \$script:VmfPowerPutBackTries'
    }
}

Describe 'POWER-ONLY-CHANGED-1: every stop that puts the power state back names it when Azure refuses' {
    BeforeAll {
        function Script:PcSeed {
            param([string]$Found)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; found = $Found } {
                param($rp, $id, $found)
                New-VmfStateDoc -RunPath $rp -RunId 'pc-test' -VmId $id | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    clusterCheckPower = [pscustomobject]@{ power = $found; status = 'goingOn'; tsUtc = '2026-11-06T00:00:00Z' } }) -Force
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        function Script:PcCtx {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
                param($rp, $id)
                New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'pc-test'
            }
        }
        $script:refuseAll = { param($name) if ($name -eq 'deallocate') { throw 'OperationNotAllowed: the machine is busy.' } }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pcRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pc-test' | Out-Null }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a shutdown that fails with nothing changed (deallocationFailed)' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        $global:pcFail = { param($name) if ($name -eq 'deallocate' -and (Global:PcEngineStep) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' } }
        $final = Script:PcRun (Script:PcPlan -Size 'Standard_D2as_v5' -Controller 'SCSI')

        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'deallocationFailed'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'a step at Checking that fails at every attempt, after the cluster check started the machine' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { throw 'The store did not answer.' }
        $global:pcFail = $script:refuseAll
        $final = Script:PcRun (Script:PcPlan)

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PcStop $final
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'the first safety copy, failing at every attempt (EVAL-H4, Resolve-VmfStoppedMachineState -AsFound)' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        $global:pcFail = $script:refuseAll
        $final = Script:PcRun (Script:PcPlan)

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PcStop $final
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'the step limit, at Checking' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        Mock -ModuleName VmMigrationFactory Get-VmfStartedTarget { throw 'The store did not answer.' }
        $global:pcFail = $script:refuseAll
        InModuleScope VmMigrationFactory { $script:pcLimitWas = $script:VmfStateLoopLimit; $script:VmfStateLoopLimit = 2 }
        try { $final = Script:PcRun (Script:PcPlan) }
        finally { InModuleScope VmMigrationFactory { $script:VmfStateLoopLimit = $script:pcLimitWas } }

        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'stepLoopLimit'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'the step limit, at a step that stops the machine' {
        Script:PcMockAzure -Found 'PowerState/deallocated'
        Script:PcMockGuest
        $global:pcFail = $script:refuseAll
        InModuleScope VmMigrationFactory { $script:pcLimitWas = $script:VmfStateLoopLimit; $script:VmfStateLoopLimit = 2 }
        try { $final = Script:PcRun (Script:PcPlan) }
        finally { InModuleScope VmMigrationFactory { $script:VmfStateLoopLimit = $script:pcLimitWas } }

        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'stepLoopLimit'
        $stop.detail | Should -Match 'stopped at SAFETY_PRISTINE'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'a copy that Azure does not make usable in time (safetyCopyNotReady)' {
        Script:PcMockAzure -Found 'PowerState/running'
        Script:PcSeed -Found 'PowerState/deallocated'
        $global:pcFail = $script:refuseAll
        Mock -ModuleName VmMigrationFactory Get-VmfInstantAccessCopyReadiness { @{ 0 = [pscustomobject]@{ lun = 0; Usable = $false; Complete = $false; TakenUtc = '2026-11-05T00:00:00Z' } } }
        Mock -ModuleName VmMigrationFactory Format-VmfCopyState { 'LUN 0 pending' }
        $global:pcPower = 'PowerState/deallocated'
        $c = Script:PcCtx
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $c } { param($c) Wait-VmfInstantAccessCopies -Context $c -MaxMinutes 1 -PollSeconds 0 }

        $r.Reason | Should -Be 'safetyCopyNotReady'
        $r.MachineState | Should -Be 'changed'
        $r.PowerNotPutBack | Should -Be 'PowerState/deallocated'
    }

    It 'a copy that would not last through the move, nothing changed (safetyCopyWindowShort)' {
        Script:PcMockAzure -Found 'PowerState/running'
        Script:PcSeed -Found 'PowerState/deallocated'
        $global:pcFail = $script:refuseAll
        Mock -ModuleName VmMigrationFactory Get-VmfInstantAccessCopyReadiness { @{ 0 = [pscustomobject]@{ lun = 0; Usable = $true; Complete = $false; State = 'InstantAccess'; MinutesLeft = 10 } } }
        Mock -ModuleName VmMigrationFactory Format-VmfCopyState { 'LUN 0 InstantAccess, 10 minutes left' }
        $c = Script:PcCtx
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = $c; rp = $script:runPath; id = $script:vmId } {
            param($c, $rp, $id)
            Test-VmfCopyWindowBeforeConversion -Context $c -Doc (Read-VmfStateDoc -RunPath $rp -VmId $id)
        }

        $r.Reason | Should -Be 'safetyCopyWindowShort'
        $r.MachineState | Should -Be 'changed'
        $r.PowerNotPutBack | Should -Be 'PowerState/deallocated'
    }
}

Describe 'POWER-ONLY-CHANGED-1: a machine found running that Azure does not start again is owed Running (POWER-START-REFUSED-1, folded)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pc-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pcRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pc-test' | Out-Null }
        $script:tries = InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'the first safety copy, failing at every attempt: the start is tried again, then the stop names Running' {
        Script:PcMockAzure -Found 'PowerState/running'
        Script:PcMockGuest
        $global:pcTries = 0
        $global:pcFail = {
            param($name)
            if ($name -eq 'snapshot') { throw 'InternalExecutionError: the snapshot did not finish.' }
            if ($name -eq 'start') { $global:pcTries++; throw 'OperationNotAllowed: the machine is busy.' }
        }
        $final = Script:PcRun (Script:PcPlan)

        $stop = Script:PcStop $final
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/running'
        $global:pcTries | Should -Be $script:tries
        $stop.detail | Should -Match 'the machine was running before the move, and the product could not start it again'
        $stop.detail | Should -Match 'power state Running first'
    }

    It 'a rollback disk that Azure does not make, and a start Azure refuses: the stop names Running' {
        Script:PcMockAzure -Found 'PowerState/running'
        Script:PcMockGuest
        $global:pcStarts = 0
        $global:pcFail = {
            param($name)
            if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
            if ($name -eq 'start') { $global:pcStarts++; if ($global:pcStarts -gt 1) { throw 'OperationNotAllowed: the machine is busy.' } }
        }
        $final = Script:PcRun (Script:PcPlan)

        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/running'
        ($global:pcStarts - 1) | Should -Be $script:tries
    }

    It 'a shutdown that fails and a start Azure refuses (DEALLOC-START-SAID-1, folded): said, and the stop names Running' {
        Script:PcMockAzure -Found 'PowerState/running'
        Script:PcMockGuest
        $global:pcFail = {
            param($name)
            if ($name -eq 'deallocate' -and (Global:PcEngineStep) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' }
            if ($name -eq 'start' -and (Global:PcEngineStep) -eq 'STOPPED') { throw 'OperationNotAllowed: the start is refused.' }
        }
        $final = Script:PcRun (Script:PcPlan -Size 'Standard_D2as_v5' -Controller 'SCSI')

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PcStop $final
        $stop.reasonCode | Should -Be 'deallocationFailed'
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/running'
        $stop.detail | Should -Match 'could not start it again \(.*the start is refused'
    }

    It 'a retry of a machine owed Running starts it first, then runs the move' {
        Script:PcMockAzure -Found 'PowerState/running'
        Script:PcMockGuest
        $plan = Script:PcPlan
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; entry = $plan } {
            param($rp, $entry) Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @($entry) }) -Depth 24
        }
        $global:pcStarts = 0
        $global:pcFail = {
            param($name)
            if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' }
            if ($name -eq 'start') { $global:pcStarts++; if ($global:pcStarts -gt 1) { throw 'OperationNotAllowed: the machine is busy.' } }
        }
        $null = Script:PcRun $plan
        (Script:PcStop (Script:PcDoc)).powerNotPutBack | Should -Be 'PowerState/running'
        $global:pcPower = 'PowerState/deallocated'
        Mock -ModuleName VmMigrationFactory Get-VmfWaveStartGate { $null }
        Resolve-VmfDecision -RunPath $script:runPath -PlanPath (Join-Path $script:runPath 'plan.json') -VmId $script:vmId -Note 'try again' -ResolvedBy 'operator@example.com' | Out-Null
        $global:pcCalls.Clear()
        $global:pcFail = { param($name) if ($name -like 'disk:*asitwas*') { throw 'QuotaExceeded: Azure did not make the disk.' } }
        $final = Script:PcRun $plan

        @($global:pcCalls)[0] | Should -Be 'start' -Because "calls: $($global:pcCalls -join ', ')"
        @($final.history | Where-Object { $_.state -eq 'PRECHECK' -and $_.machineState -eq 'untouched' }) | Should -HaveCount 1
    }
}
