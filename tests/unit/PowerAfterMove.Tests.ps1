#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# POWER-AFTER-MOVE-1, 2026-11-06. A machine that Checking found Stopped
# (deallocated) or Stopped is started by the product to work on it: the
# cluster check, the guest scripts, Starting and Verifying. Before this item,
# a move that ended - migrated, or rolled back - left it running, and the
# customer paid for a machine they had turned off.
#
# The rulings (2026-11-06): the product MUST put the VM back to its power
# state, and retry the power-off if the machine was off. Whatever the original
# state was, on or off, is kept when the work is done.
#
# So the machine ends in the power state Checking found (the record
# captured.clusterCheckPower, Get-VmfPowerAsFound) at the end of:
#   - a move that passed Verifying (MIGRATED): the return comes AFTER every
#     check of Verifying, with a checkpoint (powerReturnPending, vm-state
#     v39) written before it, so a worker killed in the return finishes it
#     and never verifies a deallocated machine again;
#   - a rollback (Complete-VmfRollback): the rollback starts the machine to
#     put it back, then the return;
#   - Restore this machine, Rebuild this machine, Finish the rollback and
#     Finish the restore (their own files test them).
# The return uses the tries of POWER-ONLY-CHANGED-1 (Invoke-VmfPowerPutBack).
# Still refused, the stop names the power state owed (history[].powerNotPutBack)
# and the machine panel offers Return to the power state. A machine found
# running stays running.
#
# The engine runs for real, with the REAL cluster check, over a power model:
# each call that changes the power sets $global:pamPower, and
# Get-VmfPowerState reads it. $global:pamOrder holds every power call and
# every guest script, in order.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')

    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
    $script:repo = Join-Path $PSScriptRoot '..' '..'

    function Script:PamPlan {
        param([string]$Os = 'Linux')
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{ classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = 'diskless'; platformManaged = $false }
            target = [pscustomobject]@{ size = 'Standard_D2s_v6'; diskArch = 'diskless'; controller = 'NVMe' }
            path = 'A'; policy = [pscustomobject]@{}; decisions = @()
        }
    }

    function Script:PamFakeVm {
        [pscustomobject]@{
            Id = $script:vmId; Name = 'vm-under-test'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{ OsType = 'Linux'; Name = 'vm-os'; DeleteOption = 'Delete'
                    ManagedDisk = [pscustomobject]@{ Id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/vm-os'; StorageAccountType = 'Premium_LRS' } }
                DataDisks = @(); ImageReference = $null
            }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @([pscustomobject]@{ Id = '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Network/networkInterfaces/nic1'; Primary = $true }) }
            Zones = @(); Tags = @{}
            LicenseType = $null; AvailabilitySetReference = $null; ProximityPlacementGroup = $null
            Priority = $null; Identity = $null; AdditionalCapabilities = $null; DiagnosticsProfile = $null
        }
    }

    function Global:PamEngineStep {
        & (Get-Module VmMigrationFactory) { param($rp, $id) [string](Read-VmfStateDoc -RunPath $rp -VmId $id).state } $global:pamRunPath $script:vmId
    }
    function Global:PamPending {
        & (Get-Module VmMigrationFactory) { param($rp, $id) $d = Read-VmfStateDoc -RunPath $rp -VmId $id; if ($d.PSObject.Properties['powerReturnPending']) { $d.powerReturnPending } else { $null } } $global:pamRunPath $script:vmId
    }

    # Azure, as a power model. $global:pamFail is asked before each power call
    # with the call's name: it throws to make Azure refuse it.
    function Script:PamMockAzure {
        param([string]$Found = 'PowerState/deallocated')
        $global:pamPower = $Found
        $global:pamOrder = [System.Collections.Generic.List[string]]::new()
        $global:pamFail = { param($name) }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; skuName = 'Premium_LRS'; diskSizeGB = 30; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:pamPower }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Script:PamFakeVm }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:pamFail 'deallocate'; $global:pamOrder.Add('deallocate'); $global:pamPower = 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:pamFail 'powerOff'; $global:pamOrder.Add('powerOff'); $global:pamPower = 'PowerState/stopped' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:pamFail 'start'; $global:pamOrder.Add('start'); $global:pamPower = 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:pamOrder.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm-os'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pamOrder.Add('swapOs') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = '' } }
        Mock -ModuleName VmMigrationFactory Get-VmfBootDiagnostics { @{ fetchedUtc = '2026-11-06T00:00:00Z' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmIdentityFacts { [pscustomobject]@{ systemAssigned = $false; principalId = $null; userAssigned = @() } }
    }

    function Global:PamOut {
        param([string]$Script, [string]$Result, [object[]]$Checks = @())
        [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
    }

    # The guest: not a cluster node, a preparation that changes nothing, and a
    # check after the move that passes - unless $global:pamAnswers names
    # another answer for a script.
    function Script:PamMockGuest {
        param([hashtable]$Answers = @{})
        $global:pamAnswers = $Answers
        Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
            [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            $name = [string]$ScriptString
            $global:pamOrder.Add("script:$name")
            $answer = $global:pamAnswers[$name]
            $out = if ($answer -is [scriptblock]) { & $answer }
                   elseif ($answer) { Global:PamOut $name $answer }
                   else {
                       switch ($name) {
                           'cluster-node-check.sh' { [ordered]@{ schema = 'vmf.guest/4'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @()
                                   facts = [ordered]@{ os = 'Linux'; pacemaker = 'inactive'; corosync = 'inactive'; sqlHadr = 'no' } } }
                           # VF-UNMANAGED-CONFIG-1: the network settings leave the virtual function unmanaged (cloud-init 23.4).
                           'sriov-unmanaged-check.sh' { [ordered]@{ schema = 'vmf.guest/7'; script = $name; version = '1.0.0'; result = 'READY'; checks = @(); warnings = @(); facts = [ordered]@{ os = 'Linux'; networkManager = 'inactive'; networkd = 'active'; wicked = 'inactive'; ifupdown = 'no'; systemdVersion = '249'; cloudInitVersion = '23.4'; cloudInitNetwork = 'enabled'; sriovUdevLines = 'none'; sriovNetworkFiles = 'none'; nmUnmanagedDevices = 'none' } } }
                           'mana-check.sh' { Global:PamOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                           'nvme-check.sh' { Global:PamOut $name 'READY' }
                           'guest-validate.sh' { Global:PamOut $name 'PASS' @(@{ name = 'root device bus'; status = 'INFO'; detail = 'nvme (/dev/nvme0n1p1)' }) }
                           default { Global:PamOut $name 'READY' }
                       }
                   }
            $out | ConvertTo-Json -Depth 8 -Compress
        }
    }

    function Script:PamRun {
        param($Plan)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'pam-test'
        }
    }
    function Script:PamDoc {
        & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:runPath $script:vmId
    }
    function Script:PamStop { param($Doc) @($Doc.history)[-1] }
    # The power calls after the last guest script - what the end of the move did.
    function Script:PamAfterLastScript {
        $all = @($global:pamOrder)
        $at = -1
        for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i] -like 'script:*') { $at = $i } }
        @($all | Select-Object -Skip ($at + 1) | Where-Object { $_ -in @('deallocate', 'powerOff', 'start') })
    }
    function Script:PamLines {
        param([string]$Step)
        & (Get-Module VmMigrationFactory) { param($rp, $s) @(Read-VmfEvents -RunPath $rp | Where-Object { [string]$_.step -eq $s }) } $script:runPath $Step
    }
}

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Get-AzNetworkInterface', 'function:\PamEngineStep', 'function:\PamOut', 'function:\PamPending' -ErrorAction SilentlyContinue
    Remove-Variable pamPower, pamOrder, pamFail, pamAnswers, pamRunPath, pamTries, pamKilled -Scope Global -ErrorAction SilentlyContinue
}

Describe 'POWER-AFTER-MOVE-1: a move that passes ends in the power state Checking found' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pam-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pamRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pam-test' | Out-Null }
        $script:tries = InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'found Stopped (deallocated): migrated, then deallocated after the last check of Verifying, and the record says so' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest
        $final = Script:PamRun (Script:PamPlan)

        $final.state | Should -Be 'MIGRATED'
        $global:pamPower | Should -Be 'PowerState/deallocated'
        @(Script:PamAfterLastScript) | Should -Be @('deallocate') -Because "the return comes after Verifying ran its last script (order: $($global:pamOrder -join ', '))"
        $stop = Script:PamStop $final
        $stop.state | Should -Be 'MIGRATED'
        $stop.detail | Should -Match 'The product deallocated the machine again, as it was before the move\.'
        $stop.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
        $final.PSObject.Properties['powerReturnPending'] | Should -BeNullOrEmpty -Because 'the checkpoint goes in the same write as MIGRATED'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $final } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -BeNullOrEmpty
        @(Script:PamLines 'VALIDATING' | Where-Object { $_.detail -match 'The product deallocated the machine again' }) | Should -HaveCount 1 -Because 'the Activity says it'
    }

    It 'found Stopped: migrated, then stopped again' {
        Script:PamMockAzure -Found 'PowerState/stopped'
        Script:PamMockGuest
        $final = Script:PamRun (Script:PamPlan)

        $final.state | Should -Be 'MIGRATED'
        $global:pamPower | Should -Be 'PowerState/stopped'
        @(Script:PamAfterLastScript) | Should -Be @('powerOff')
        (Script:PamStop $final).detail | Should -Match 'The product stopped the machine again, as it was before the move\.'
    }

    It 'found running: migrated and running, as before - nothing is stopped after the move' {
        Script:PamMockAzure -Found 'PowerState/running'
        Script:PamMockGuest
        $final = Script:PamRun (Script:PamPlan)

        $final.state | Should -Be 'MIGRATED'
        $global:pamPower | Should -Be 'PowerState/running'
        @(Script:PamAfterLastScript) | Should -BeNullOrEmpty
        (Script:PamStop $final).detail | Should -Not -Match 'as it was before the move'
    }

    It 'the checkpoint is on record before the return, and names the power state and MIGRATED' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest
        $global:pamSeen = $null
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and (Global:PamEngineStep) -eq 'VALIDATING') { $global:pamSeen = Global:PamPending } }
        try {
            $null = Script:PamRun (Script:PamPlan)
            $global:pamSeen | Should -Not -BeNullOrEmpty -Because 'a worker killed in the return must know what to finish'
            $global:pamSeen.power | Should -Be 'PowerState/deallocated'
            $global:pamSeen.next | Should -Be 'MIGRATED'
        }
        finally { Remove-Variable pamSeen -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'a return Azure refuses at every try: MIGRATED, changed, and the power state owed - the panel then offers its return' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest
        $global:pamTries = 0
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and (Global:PamEngineStep) -eq 'VALIDATING') { $global:pamTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        $final = Script:PamRun (Script:PamPlan)

        $final.state | Should -Be 'MIGRATED'
        $stop = Script:PamStop $final
        $stop.machineState | Should -Be 'changed'
        $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
        $global:pamTries | Should -Be $script:tries
        $stop.detail | Should -Match "could not deallocate it again \(.*OperationNotAllowed.*\), after $($script:tries) tries"
        (InModuleScope VmMigrationFactory -Parameters @{ d = $final } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -Be 'PowerState/deallocated'
        $global:pamPower | Should -Be 'PowerState/running'
    }

    It 'kill and resume (rule 4): a worker killed in the return finishes it, and never runs Verifying again' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest
        $global:pamKilled = $false
        $global:pamFail = {
            param($name)
            if ($name -eq 'deallocate' -and (Global:PamEngineStep) -eq 'VALIDATING' -and -not $global:pamKilled) {
                $global:pamKilled = $true
                throw 'The lease of this machine is held by another worker: abandon this VM.'
            }
        }
        { Script:PamRun (Script:PamPlan) } | Should -Throw '*abandon this VM*'
        Global:PamEngineStep | Should -Be 'VALIDATING'
        Global:PamPending | Should -Not -BeNullOrEmpty
        $global:pamPower | Should -Be 'PowerState/running'

        $global:pamOrder.Clear()
        $final = Script:PamRun (Script:PamPlan)
        $final.state | Should -Be 'MIGRATED'
        @($global:pamOrder | Where-Object { $_ -like 'script:*' }) | Should -BeNullOrEmpty -Because 'a deallocated machine is never verified again'
        @($global:pamOrder) | Should -Be @('deallocate')
        $global:pamPower | Should -Be 'PowerState/deallocated'
        @($final.history | Where-Object { $_.state -eq 'MIGRATED' }) | Should -HaveCount 1
        $final.PSObject.Properties['powerReturnPending'] | Should -BeNullOrEmpty
    }

    It 'a resume after the machine was returned, and before MIGRATED was written, writes MIGRATED once and changes nothing' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest
        $global:pamKilled = $false
        # The return took, and the worker was killed before its record.
        $global:pamFail = {
            param($name)
            if ($name -eq 'deallocate' -and (Global:PamEngineStep) -eq 'VALIDATING' -and -not $global:pamKilled) {
                $global:pamKilled = $true
                $global:pamPower = 'PowerState/deallocated'
                throw 'The lease of this machine is held by another worker: abandon this VM.'
            }
        }
        { Script:PamRun (Script:PamPlan) } | Should -Throw '*abandon this VM*'
        $global:pamPower | Should -Be 'PowerState/deallocated'
        $global:pamOrder.Clear()
        $final = Script:PamRun (Script:PamPlan)
        $final.state | Should -Be 'MIGRATED'
        @($global:pamOrder | Where-Object { $_ -in @('start', 'powerOff') -or $_ -like 'script:*' }) | Should -BeNullOrEmpty
        $global:pamPower | Should -Be 'PowerState/deallocated'
    }
}

Describe 'POWER-AFTER-MOVE-1: a rollback ends in the power state Checking found' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pam-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pamRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pam-test' | Out-Null }
        $script:tries = InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries }
        # The check after the move fails at every attempt: FAIL-1 rolls it back.
        $script:failValidate = @{ 'guest-validate.sh' = 'FAIL' }
        # The preparation's fixer answers BLOCKED: it decides at the end, after
        # its changes ran, so the guest may have changed, and PREP-ROLLBACK-1
        # rolls the disks back.
        $script:prepChangedThenBlocked = @{ 'nvme-check.sh' = 'NEEDS_PREP'; 'nvme-fix.sh' = 'BLOCKED' }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'found Stopped (deallocated): rolled back, started by the rollback, then deallocated, and the stop says so' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:failValidate
        $final = Script:PamRun (Script:PamPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PamStop $final
        $stop.machineState | Should -Be 'restored'
        $stop.detail | Should -Match 'The product deallocated the machine again, as it was before the move\.'
        $global:pamPower | Should -Be 'PowerState/deallocated'
        $all = @($global:pamOrder)
        # VOLUMES-ONLINE-1: the check of the volumes inside the machine runs
        # between the start and the return, so only the power calls are read.
        $power = @($all | Where-Object { $_ -in @('start', 'deallocate', 'powerOff') })
        $power[-2..-1] | Should -Be @('start', 'deallocate') -Because "the rollback starts the machine, then it is returned (order: $($all -join ', '))"
        @($all | Select-Object -Skip ([array]::LastIndexOf($all, 'start'))) | Should -Contain 'script:guest-validate.sh' -Because 'the volumes are checked while the machine runs'
        @(Script:PamLines 'rollback' | Where-Object { $_.detail -match 'The product deallocated the machine again' }) | Should -HaveCount 1 -Because 'the Activity says it'
    }

    It 'found Stopped: rolled back, then stopped again' {
        Script:PamMockAzure -Found 'PowerState/stopped'
        Script:PamMockGuest -Answers $script:failValidate
        $final = Script:PamRun (Script:PamPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $global:pamPower | Should -Be 'PowerState/stopped'
    }

    It 'found running: rolled back and running, as before' {
        Script:PamMockAzure -Found 'PowerState/running'
        Script:PamMockGuest -Answers $script:failValidate
        $final = Script:PamRun (Script:PamPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $global:pamPower | Should -Be 'PowerState/running'
        # VOLUMES-ONLINE-1: only the check inside the machine comes after the start.
        @($global:pamOrder | Where-Object { $_ -in @('start', 'deallocate', 'powerOff') })[-1] | Should -Be 'start'
        (Script:PamStop $final).detail | Should -Not -Match 'as it was before the move'
    }

    It 'a return Azure refuses at every try: changed, the power state owed, and the retry is not held' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:failValidate
        $global:pamTries = 0
        $global:pamRolled = $false
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pamOrder.Add('swapOs'); $global:pamRolled = $true }
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and $global:pamRolled -and $global:pamPower -eq 'PowerState/running') { $global:pamTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        try {
            $final = Script:PamRun (Script:PamPlan)
            $final.state | Should -Be 'FAILED_ROLLED_BACK'
            $stop = Script:PamStop $final
            $stop.machineState | Should -Be 'changed'
            $stop.powerNotPutBack | Should -Be 'PowerState/deallocated'
            $global:pamTries | Should -Be $script:tries
            (InModuleScope VmMigrationFactory -Parameters @{ d = $final } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
        }
        finally { Remove-Variable pamRolled -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'kill and resume (rule 4): a worker killed in the return after the rollback returns it again and records the stop once' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:failValidate
        $global:pamKilled = $false
        $global:pamRolled = $false
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pamOrder.Add('swapOs'); $global:pamRolled = $true }
        $global:pamFail = {
            param($name)
            if ($name -eq 'deallocate' -and $global:pamRolled -and $global:pamPower -eq 'PowerState/running' -and -not $global:pamKilled) {
                $global:pamKilled = $true
                throw 'The lease of this machine is held by another worker: abandon this VM.'
            }
        }
        try {
            { Script:PamRun (Script:PamPlan) } | Should -Throw '*abandon this VM*'
            (Script:PamDoc).rollbackPending.done | Should -BeTrue
            $global:pamOrder.Clear()
            $final = Script:PamRun (Script:PamPlan)
        }
        finally { Remove-Variable pamRolled -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:pamOrder) | Should -Be @('deallocate') -Because 'the rollback is not run again; only the return'
        $global:pamPower | Should -Be 'PowerState/deallocated'
        @($final.history | Where-Object { $_.state -eq 'FAILED_ROLLED_BACK' }) | Should -HaveCount 1
    }

    It 'a rollback of the preparation (found Stopped (deallocated)): rolled back, then deallocated' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:prepChangedThenBlocked
        $final = Script:PamRun (Script:PamPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK' -Because "the preparation changed the guest, then stopped: $((Script:PamStop $final).detail)"
        (Script:PamStop $final).machineState | Should -Be 'restored'
        (Script:PamStop $final).detail | Should -Match 'The product deallocated the machine again, as it was before the move\.'
        $global:pamPower | Should -Be 'PowerState/deallocated'
        # VOLUMES-ONLINE-1: the check of the volumes runs between the start and
        # the return, so only the power calls are read.
        @($global:pamOrder | Where-Object { $_ -in @('start', 'deallocate', 'powerOff') })[-2..-1] | Should -Be @('start', 'deallocate')
    }

    It 'a rollback of the preparation whose start fails: returned to Stopped (deallocated), not started again, and restored' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:prepChangedThenBlocked
        $global:pamRolled = $false
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pamOrder.Add('swapOs'); $global:pamRolled = $true }
        $global:pamFail = { param($name) if ($name -eq 'start' -and $global:pamRolled) { throw 'AllocationFailed: no capacity.' } }
        try {
            $final = Script:PamRun (Script:PamPlan)
            $stop = Script:PamStop $final
            $final.state | Should -Be 'FAILED_ROLLED_BACK' -Because $stop.detail
            $stop.machineState | Should -Be 'restored'
            $global:pamPower | Should -Be 'PowerState/deallocated'
            $stop.detail | Should -Match 'The product deallocated the machine again, as it was before the move'
            @($global:pamOrder | Select-Object -Skip ([array]::LastIndexOf(@($global:pamOrder), 'swapOs'))) | Should -Be @('swapOs', 'deallocate') -Because 'only the first start is refused; the machine is never started again to be deallocated'
        }
        finally { Remove-Variable pamRolled -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'a rollback of the preparation that cannot stop the machine: it tries to return it to Stopped (deallocated), never only to start it' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:prepChangedThenBlocked
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and (Global:PamEngineStep) -eq 'GUEST_PREP') { throw 'OperationNotAllowed: the machine is busy.' } }
        $final = Script:PamRun (Script:PamPlan)
        $stop = Script:PamStop $final
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION' -Because $stop.detail
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'could not deallocate it again'
        $stop.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
    }

    It 'a rollback of the preparation that fails after it changed a disk: changed, and returned to Stopped (deallocated), with no power state owed' {
        Script:PamMockAzure -Found 'PowerState/deallocated'
        Script:PamMockGuest -Answers $script:prepChangedThenBlocked
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pamOrder.Add('swapOs'); throw 'Conflict: the disk is busy.' }
        $final = Script:PamRun (Script:PamPlan)
        $stop = Script:PamStop $final
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION' -Because $stop.detail
        $stop.machineState | Should -Be 'changed'
        $stop.PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty -Because 'the machine is changed in another way, so its retry stays held'
        $global:pamPower | Should -Be 'PowerState/deallocated'
        $stop.detail | Should -Match 'as it was before the move'
    }
}

Describe 'POWER-AFTER-MOVE-1: the record and the return, alone' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pam-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pamRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pam-test' | Out-Null }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a stop that says restored while a power state is owed is written changed, with the power state' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            New-VmfStateDoc -RunPath $rp -RunId 'pam-test' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail -MachineState 'changed' -PowerNotPutBack 'PowerState/deallocated' | Out-Null
            $d = Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome fail -MachineState 'restored'
            @($d.history)[-1].machineState | Should -Be 'changed'
            @($d.history)[-1].powerNotPutBack | Should -Be 'PowerState/deallocated'
        }
    }

    It 'the line of a return that worked may say restored' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            New-VmfStateDoc -RunPath $rp -RunId 'pam-test' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome fail -MachineState 'changed' -PowerNotPutBack 'PowerState/deallocated' | Out-Null
            $d = Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome ok -MachineState 'restored' -PowerPutBack
            @($d.history)[-1].machineState | Should -Be 'restored'
            Get-VmfPowerOwed -Doc $d | Should -BeNullOrEmpty
        }
    }

    It 'Get-VmfPowerBackMachineState: where a return leaves the record - <Why>' -ForEach @(
        @{ Why = 'a migrated machine is changed: it is on its new size'; State = 'MIGRATED'; Extra = @{}; Want = 'changed' }
        @{ Why = 'a machine rolled back is restored'; State = 'FAILED_ROLLED_BACK'; Extra = @{}; Want = 'restored' }
        @{ Why = 'a machine Restore this machine put back is restored'; State = 'FAILED_NEEDS_ATTENTION'; Extra = @{ restore = [pscustomobject]@{ restoredUtc = '2026-11-06T02:00:00Z' } }; Want = 'restored' }
        # A rollback can end in NEEDS_DECISION (a park on a second visit to
        # Preparing) or FAILED_NEEDS_ATTENTION (the step limit): its record says it.
        @{ Why = 'a rollback that parked the machine for a decision is restored'; State = 'NEEDS_DECISION'; Extra = @{ rollback = [pscustomobject]@{ rolledBackUtc = '2026-11-06T02:00:00Z' } }; Want = 'restored' }
        @{ Why = 'a rollback that ended at the step limit is restored'; State = 'FAILED_NEEDS_ATTENTION'; Extra = @{ rollback = [pscustomobject]@{ rolledBackUtc = '2026-11-06T02:00:00Z' } }; Want = 'restored' }
        @{ Why = 'a line that says restored in this attempt is restored'; State = 'FAILED_NEEDS_ATTENTION'; Extra = @{ more = @([pscustomobject]@{ tsUtc = '2026-11-06T02:00:00Z'; state = 'FAILED_NEEDS_ATTENTION'; machineState = 'restored' }) }; Want = 'restored' }
        @{ Why = 'a rollback of an earlier attempt does not count: this stop came before any change'; State = 'NEEDS_DECISION'; Extra = @{ rollback = [pscustomobject]@{ rolledBackUtc = '2026-11-05T23:00:00Z' } }; Want = 'untouched' }
        @{ Why = 'a restore of an earlier attempt does not count'; State = 'NEEDS_DECISION'; Extra = @{ restore = [pscustomobject]@{ restoredUtc = '2026-11-05T23:00:00Z' } }; Want = 'untouched' }
        @{ Why = 'a restored line of an earlier attempt does not count'; State = 'NEEDS_DECISION'; Extra = @{ before = @([pscustomobject]@{ tsUtc = '2026-11-06T00:30:00Z'; state = 'FAILED_ROLLED_BACK'; machineState = 'restored' }) }; Want = 'untouched' }
        @{ Why = 'a stop before any change, with no rollback, is untouched'; State = 'NEEDS_DECISION'; Extra = @{}; Want = 'untouched' }
        @{ Why = 'a machine left out before any change is untouched'; State = 'SKIPPED'; Extra = @{}; Want = 'untouched' }
    ) {
        # The attempt starts at the Checking line of 01:00.
        $history = @($(if ($Extra.ContainsKey('before')) { $Extra.before })) + @([pscustomobject]@{ tsUtc = '2026-11-06T01:00:00Z'; state = 'PRECHECK'; outcome = 'ok' }) + @($(if ($Extra.ContainsKey('more')) { $Extra.more }))
        $fields = @{ state = $State; history = $history }
        foreach ($k in @($Extra.Keys | Where-Object { $_ -notin @('more', 'before') })) { $fields[$k] = $Extra[$k] }
        $doc = [pscustomobject]$fields
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerBackMachineState -Doc $d }) | Should -Be $Want
    }
}

Describe 'POWER-AFTER-MOVE-1: Return to the power state, after a move' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pam-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $global:pamRunPath = $script:runPath
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pam-test' | Out-Null }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document ([ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1' }) }) -Depth 24
        }
        Script:PamMockAzure -Found 'PowerState/running'
        Mock -ModuleName VmMigrationFactory Enter-VmfMachineLease { 'lease' }
        Mock -ModuleName VmMigrationFactory Exit-VmfMachineLease { }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    It 'a migrated machine owed Stopped (deallocated): returned, the line says changed (the move changed it), and nothing is owed' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            New-VmfStateDoc -RunPath $rp -RunId 'pam-test' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok -MachineState 'changed' -PowerNotPutBack 'PowerState/deallocated' | Out-Null
        }
        $out = Restore-VmfMachinePower -RunPath $script:runPath -VmId $script:vmId -By 'operator@example.com' -Confirm:$false
        $out.Returned | Should -BeTrue
        $global:pamPower | Should -Be 'PowerState/deallocated'
        $doc = Script:PamDoc
        $doc.state | Should -Be 'MIGRATED'
        @($doc.history)[-1].machineState | Should -Be 'changed'
        @($doc.history)[-1].PSObject.Properties['powerNotPutBack'] | Should -BeNullOrEmpty
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -BeNullOrEmpty
    }

    It 'a rolled-back machine owed Stopped (deallocated): returned, and the line says restored' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            param($rp, $id)
            New-VmfStateDoc -RunPath $rp -RunId 'pam-test' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'FAILED_ROLLED_BACK' -Outcome fail -MachineState 'changed' -PowerNotPutBack 'PowerState/deallocated' | Out-Null
        }
        $null = Restore-VmfMachinePower -RunPath $script:runPath -VmId $script:vmId -By 'operator@example.com' -Confirm:$false
        $doc = Script:PamDoc
        @($doc.history)[-1].machineState | Should -Be 'restored'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
    }
}

# POWER-FOUND-AGE-1, folded in (approved 2026-11-06): a job a person starts later keeps the power state the machine
# had when THAT JOB started, read from Azure at its start - never Checking's
# record from the move.
Describe 'POWER-AFTER-MOVE-1: Restore this machine ends in the power state it found when it started' {    BeforeAll {
        $script:rsSub = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute'
        $script:rsVm = "$($script:rsSub)/virtualMachines/app01"
        function Script:PamRestoreRun {
            param([string]$Found)
            $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pam-rst-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $script:rsVm; sub = $script:rsSub; found = $Found } {
                param($rp, $vmId, $sub, $found)
                Initialize-VmfRun -RunPath $rp -RunId 'pam-rst' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'pam-rst' -VmId $vmId -Wave 'lab-1' | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
                $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = "$sub/snapshots/app01-snap"; cloneVmId = $null }) -Force
                if ($found) {
                    $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                            clusterCheckPower = [pscustomobject]@{ power = $found; status = 'goingOn'; tsUtc = '2026-11-06T00:00:00Z' } }) -Force
                }
                $doc.state = 'MIGRATED'
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
        function Script:PamJobAzure {
            # The power state of the machine when the job starts.
            param([string]$Now = 'PowerState/running')
            $global:pamPower = $Now
            $global:pamOrder = [System.Collections.Generic.List[string]]::new()
            $global:pamFail = { param($name) }
            Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 } }
            Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
            Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pamOrder.Add('swapOs') }
            Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
            Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
            Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
            Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
            Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:pamPower }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { & $global:pamFail 'deallocate'; $global:pamOrder.Add('deallocate'); $global:pamPower = 'PowerState/deallocated' }
            Mock -ModuleName VmMigrationFactory Stop-VmfVmPoweredOff { & $global:pamFail 'powerOff'; $global:pamOrder.Add('powerOff'); $global:pamPower = 'PowerState/stopped' }
            Mock -ModuleName VmMigrationFactory Start-VmfVm { & $global:pamFail 'start'; $global:pamOrder.Add('start'); $global:pamPower = 'PowerState/running' }
            Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { $global:pamOrder.Add('agentReady') }
        }
        function Script:PamJobDoc { param($rp, $id) & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $rp $id }
    }
    AfterEach {
        if ($script:rsRun -and (Test-Path $script:rsRun)) { Remove-Item $script:rsRun -Recurse -Force }
        if ($script:rsSnap -and (Test-Path $script:rsSnap)) { Remove-Item $script:rsSnap -Recurse -Force }
    }

    It 'found running when the restore starts: restored and running - also when Checking found it deallocated at the move' {
        $script:rsRun = Script:PamRestoreRun -Found 'PowerState/deallocated'
        Script:PamJobAzure -Now 'PowerState/running'
        $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
        $global:pamPower | Should -Be 'PowerState/running'
        @($global:pamOrder)[-1] | Should -Be 'agentReady' -Because "nothing stops it after the start (order: $($global:pamOrder -join ', '))"
        (Script:PamJobDoc $script:rsRun $script:rsVm).restore | Should -Not -BeNullOrEmpty
    }

    It 'found Stopped (deallocated) when the restore starts: restored, started to show it boots, then deallocated, and the line says so' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/deallocated'
        $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
        $global:pamPower | Should -Be 'PowerState/deallocated'
        @($global:pamOrder)[-3..-1] | Should -Be @('start', 'agentReady', 'deallocate') -Because "the return comes after the agent answered (order: $($global:pamOrder -join ', '))"
        $line = @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp } $script:rsRun | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'ok' })
        $line[-1].detail | Should -Match 'The product deallocated the machine again, as it was before the restore'
        $doc = Script:PamJobDoc $script:rsRun $script:rsVm
        $doc.restore | Should -Not -BeNullOrEmpty
        $doc.restore.powerAtStart | Should -Be 'PowerState/deallocated' -Because 'a later rebuild keeps the newest reading on record'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -BeNullOrEmpty
    }

    It 'found Stopped when the restore starts: restored, then Stopped again' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/stopped'
        $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
        $global:pamPower | Should -Be 'PowerState/stopped'
        @($global:pamOrder)[-1] | Should -Be 'powerOff'
    }

    It 'the reading is in the checkpoint before the restore changes anything' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/deallocated'
        $global:pamSeen = 'none'
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and $global:pamSeen -eq 'none') {
                $j = (& (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $global:pamRsRun $global:pamRsVm).putBackJob
                $global:pamSeen = if ($j -and $j.PSObject.Properties['powerAtStart']) { [string]$j.powerAtStart } else { '' } } }
        $global:pamRsRun = $script:rsRun; $global:pamRsVm = $script:rsVm
        try {
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
            $global:pamSeen | Should -Be 'PowerState/deallocated' -Because 'the first stop of the restore comes after the reading is kept'
        }
        finally { Remove-Variable pamSeen, pamRsRun, pamRsVm -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'kill and resume (rule 4): a restore killed after it started the machine returns it to the power state of its first reading, and never reads it again' {
        $script:rsRun = Script:PamRestoreRun
        $script:rsSnap = "$($script:rsRun)-snap"
        Script:PamJobAzure -Now 'PowerState/deallocated'
        # The process dies at the return: the store as it was then is what a
        # new container finds, and the machine runs.
        $global:pamKill = @{ run = $script:rsRun; snap = $script:rsSnap; done = $false }
        $global:pamFail = { param($name)
            if ($name -eq 'deallocate' -and @($global:pamOrder) -contains 'agentReady' -and -not $global:pamKill.done) {
                $global:pamKill.done = $true
                Copy-Item -Path $global:pamKill.run -Destination $global:pamKill.snap -Recurse
                # Said as a lost lease: the only error a return never tries again.
                throw 'VMF-TEST-KILLED: the process is gone - abandon this VM'
            } }
        try {
            { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -CorrelationId 'op-pam' -Confirm:$false } | Should -Throw
            Remove-Item $script:rsRun -Recurse -Force
            Copy-Item -Path $script:rsSnap -Destination $script:rsRun -Recurse
            (Script:PamJobDoc $script:rsRun $script:rsVm).putBackJob.powerAtStart | Should -Be 'PowerState/deallocated'
            $global:pamPower | Should -Be 'PowerState/running'
            $global:pamReads = 0
            Mock -ModuleName VmMigrationFactory Get-VmfPowerState { $global:pamReads++; $global:pamPower }
            $global:pamOrder.Clear()
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Resume -CorrelationId 'op-pam' -Confirm:$false
            $global:pamPower | Should -Be 'PowerState/deallocated'
            @($global:pamOrder | Where-Object { $_ -eq 'start' }) | Should -BeNullOrEmpty -Because 'the resume does not start the machine again'
            $global:pamReads | Should -Be 0 -Because 'the resume keeps the first reading, and never reads a machine the restore started'
            (Script:PamJobDoc $script:rsRun $script:rsVm).restore | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Variable pamKill, pamReads -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'a power state Azure does not give: the restore goes on, says so, and the machine runs at the end' {
        $script:rsRun = Script:PamRestoreRun -Found 'PowerState/deallocated'
        Script:PamJobAzure -Now 'PowerState/deallocated'
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { throw 'The service did not answer.' }
        $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
        $global:pamPower | Should -Be 'PowerState/running'
        @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp } $script:rsRun | Where-Object { $_.detail -match 'could not read the power state of the machine before the restore' }) | Should -Not -BeNullOrEmpty
    }

    It 'a power state the product does not return to (starting): not kept, and the machine runs at the end' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/deallocated'
        $global:pamFirst = $true
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { if ($global:pamFirst) { $global:pamFirst = $false; 'PowerState/starting' } else { $global:pamPower } }
        try {
            $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
            $global:pamPower | Should -Be 'PowerState/running'
            @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp } $script:rsRun | Where-Object { $_.detail -match "in the power state Starting before the restore" }) | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Variable pamFirst -Scope Global -ErrorAction SilentlyContinue }
    }

    It 'a return Azure refuses at every try: the restore is recorded, and the power state is owed after it' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/deallocated'
        $global:pamTries = 0
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and @($global:pamOrder) -contains 'agentReady') { $global:pamTries++; throw 'OperationNotAllowed: the machine is busy.' } }
        $null = Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false
        $global:pamTries | Should -Be (InModuleScope VmMigrationFactory { $script:VmfPowerPutBackTries })
        $doc = Script:PamJobDoc $script:rsRun $script:rsVm
        $doc.restore | Should -Not -BeNullOrEmpty
        $last = @($doc.history)[-1]
        $last.state | Should -Be 'MIGRATED'
        $last.machineState | Should -Be 'changed'
        $last.powerNotPutBack | Should -Be 'PowerState/deallocated'
        $last.detail | Should -Match 'could not deallocate it again'
    }

    It 'a restore that fails and starts the machine to recover it: returned to Stopped (deallocated), and the error says so, not running' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/deallocated'
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'OperationNotAllowed: the swap was refused' }
        { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false } | Should -Throw -ExpectedMessage '*The product deallocated the machine again, as it was before the restore*'
        $global:pamPower | Should -Be 'PowerState/deallocated'
    }

    It 'a restore that fails, and a return Azure refuses at every try: the error says running, and the power state is owed' {
        $script:rsRun = Script:PamRestoreRun
        Script:PamJobAzure -Now 'PowerState/deallocated'
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'OperationNotAllowed: the swap was refused' }
        $global:pamFail = { param($name) if ($name -eq 'deallocate' -and @($global:pamOrder) -contains 'start') { throw 'OperationNotAllowed: the machine is busy.' } }
        { Restore-VmfVm -RunPath $script:rsRun -VmId $script:rsVm -Confirm:$false } | Should -Throw -ExpectedMessage '*running on disk*could not deallocate it again*'
        $last = @((Script:PamJobDoc $script:rsRun $script:rsVm).history)[-1]
        $last.machineState | Should -Be 'changed'
        $last.powerNotPutBack | Should -Be 'PowerState/deallocated'
    }
}

# REBUILD-REMOVE-RECOVER-1: the Describe of Rebuild this machine (its power
# state from the record, Get-VmfRecordedPower) is gone with the action.

Describe 'POWER-AFTER-MOVE-1: the contract' {
    BeforeAll {
        $script:schema = Get-Content (Join-Path $script:repo 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
    }

    It 'vm-state is v39, and the store writes v39' {
        $script:schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
    }

    It 'the checkpoint of the return after a move is in the schema: the power state and the state it ends in' {
        $schemaProp = $script:schema.properties.powerReturnPending
        $schemaProp | Should -Not -BeNullOrEmpty
        @($schemaProp.required) | Should -Contain 'power'
        @($schemaProp.required) | Should -Contain 'next'
        @($schemaProp.properties.power.enum) | Should -Be @('PowerState/deallocated', 'PowerState/stopped')
        @($schemaProp.properties.next.enum) | Should -Be @('MIGRATED')
    }

    It 'a restore keeps the power state it found when it started: in its checkpoint and in the record of a swap it leaves' {
        foreach ($schemaProp in @($script:schema.properties.putBackJob.properties.powerAtStart, $script:schema.properties.swapPending.properties.powerAtStart)) {
            $schemaProp | Should -Not -BeNullOrEmpty
            @($schemaProp.enum) | Should -Be @('PowerState/running', 'PowerState/deallocated', 'PowerState/stopped', $null)
        }
    }

    It 'the sample is v39, and the migration note says it' {
        $sample = Get-Content (Join-Path $script:repo 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 51
        Get-Content (Join-Path $script:repo 'docs' 'schema-migrations.md') -Raw | Should -Match 'vm-state v38 -> v39 \(2026-11-06, POWER-AFTER-MOVE-1\)'
    }
}
