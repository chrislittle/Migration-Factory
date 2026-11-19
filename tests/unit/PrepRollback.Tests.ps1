#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PREP-ROLLBACK-1 (2026-10-05): the machine is rolled back.
#
# A move is one change window: once the product has changed a machine, a stop
# puts it back at once (ONE-WINDOW-1). The rule held for a failure in the move
# itself - CONVERTING, STARTING, VALIDATING - and nowhere before it. A
# preparation script that failed after it rewrote the boot path left the
# machine half prepared as FAILED_NEEDS_ATTENTION. A shutdown or a second copy
# that failed after the preparation started the prepared machine again, and the
# shutdown's stop said "nothing was changed".
#
# Now each of those puts the machine back from the first safety copy. The
# hardware was never changed before CONVERTING, so the way back swaps the disks
# only: stop, the disks from the first copy, start. It never rebuilds a Path B
# machine, whose definition is still whole at that point.
#
# The review of the first build (F1-F12) is tested here too: the checkpoint a
# rollback writes before its first change, and the resume that finishes it; the
# audit entry a changing script gets BEFORE it runs; the disks a rollback made;
# a failed rollback that never starts a machine with an empty LUN.
#
# The guest runs through the REAL Invoke-VmfGuestScriptOnVm, so the audit trail
# is the one the product writes: only the run command and the script asset are
# stand-ins (the asset's content is its name, which the run command reads).
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')

    function Global:Get-AzVM { param($ResourceGroupName, $Name, [switch]$Status) throw 'stub' }
    function Global:Update-AzVM { param($ResourceGroupName, $VM) throw 'stub' }
    function Global:Get-AzNetworkInterface { param($Name, $ResourceGroupName) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above, so its mocks and this file's own take the same shape.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # SQLVM-REREAD-1: Checking reads the SQL virtual machine resource before a rebuild; none here.
    # DCR-READ-1: Checking reads the data collection rule associations before a rebuild; none here.
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm-under-test'
    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute'

    function Script:PrPlan {
        param([string]$Os = 'Linux', [string]$Path = 'A', [string]$SourceArch = 'diskless', [string]$TargetArch = 'diskless',
              [string]$Size = 'Standard_D2s_v6', [string]$Controller = 'NVMe')
        [pscustomobject]@{
            schemaVersion = (Get-VmfTestPlanEntryVersion)
            vmId = $script:vmId
            wave = 'w1'; ring = 'lab'
            assessment = [pscustomobject]@{
                classification = 'ReadyAfterPrep'; gen = 'V2'; os = $Os
                sourceSize = 'Standard_D2s_v4'; sourceDiskArch = $SourceArch
                platformManaged = $false
            }
            target = [pscustomobject]@{ size = $Size; diskArch = $TargetArch; controller = $Controller }
            path = $Path
            policy = [pscustomobject]@{}
            # REBUILD-ACCEPT-1: a rebuild needs a person's acceptance that names
            # the machine and its extensions (none here: the mocks read none).
            decisions = @(if ($Path -eq 'B') { [pscustomobject]@{ setting = 'rebuild'; by = 'approver@example.com'; utc = '2026-11-01T00:00:00Z'; extensions = @() } })
        }
    }

    function Script:PrFakeVm {
        param([string]$Os = 'Linux')
        [pscustomobject]@{
            Id = $script:vmId
            Name = 'vm-under-test'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2s_v4' }
            StorageProfile = [pscustomobject]@{
                DiskControllerType = 'SCSI'
                OsDisk = [pscustomobject]@{
                    OsType = $Os; Name = 'vm-os'
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

    # Every Azure call a whole run makes. Each one that changes the machine
    # adds a word to $global:prCalls, so a test can read the order.
    function Script:PrMockAzure {
        param([string]$Os = 'Linux')
        $global:prOs = $Os
        $global:prCalls = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfAdeExtension { $false }
        # SAFETY-CMK-1: PRECHECK reads each disk's encryption by its id.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmResourceLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @('*'); notActions = @() }) }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Get-AzVM { Script:PrFakeVm -Os $global:prOs }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1' }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1/providers/Microsoft.Authorization/locks/vmf-safety-copy' }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:prCalls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:prCalls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:prCalls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmExtensions { , @() }
        Mock -ModuleName VmMigrationFactory Get-AzNetworkInterface { [pscustomobject]@{ EnableAcceleratedNetworking = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS' }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:prCalls.Add("create:$DiskName"); "/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:prCalls.Add('swapOs') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
    }

    # One guest output, as a script prints it.
    function Global:PrOut {
        param([string]$Script, [string]$Result, [object[]]$Checks = @(), [string]$Err = '')
        $o = [ordered]@{ schema = 'vmf.guest/2'; script = $Script; version = '1.0.0'; result = $Result; checks = @($Checks); warnings = @() }
        if ($Err) { $o.error = $Err }
        $o
    }

    # The guest: each test names the answer of the script that matters - a
    # result, or a script block that returns an output or throws. The real
    # Invoke-VmfGuestScriptOnVm runs, so the audit trail is the product's own.
    function Script:PrMockGuest {
        param([hashtable]$Answers = @{})
        $global:prAnswers = $Answers
        $global:prScripts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName VmMigrationFactory Get-VmfGuestScript {
            [pscustomobject]@{ Name = $Name; Version = '1.0.0'; Sha256 = ('a' * 64); Content = $Name
                Os = $(if ($Name -like '*.sh') { 'linux' } else { 'windows' })
                Packages = @([pscustomobject]@{ version = '2.0.18.52'; sha256 = ('b' * 64); url = 'https://download.microsoft.com/x' }) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-VmfRunCommand {
            $name = [string]$ScriptString
            $global:prScripts.Add($name)
            $answer = $global:prAnswers[$name]
            $out = if ($answer -is [scriptblock]) { & $answer }
                   elseif ($answer) { Global:PrOut $name $answer -Err "$name could not finish" }
                   else {
                       switch ($name) {
                           'mana-check.sh'      { Global:PrOut $name 'READY' @(@{ name = 'interface eth0'; status = 'PASS'; detail = 'using MANA driver' }) }
                           'Test-ManaReady.ps1' { Global:PrOut $name 'READY' @(@{ name = 'mana adapter bound'; status = 'PASS'; detail = 'Ethernet 3' }) }
                           'Install-ManaDriver.ps1' { Global:PrOut $name 'NO_CHANGE' }
                           # VOLUMES-ONLINE-V5-1: a v5 move on Linux installs the LVM start task;
                           # with no devices file in use it changes nothing.
                           'lvm-devices-task.sh' { Global:PrOut $name 'NO_CHANGE' }
                           'nvme-check.sh'      { Global:PrOut $name 'NEEDS_PREP' }
                           # READY once the fix ran, as on a real machine - STOPPED checks it again.
                           'Test-NvmeReady.ps1' { Global:PrOut $name $(if ($global:prScripts -contains 'Set-NvmeReady.ps1') { 'READY' } else { 'NEEDS_PREP' }) }
                           { $_ -in @('Set-NvmeReady.ps1', 'Move-Pagefile.ps1', 'Install-TempDiskInit.ps1', 'nvme-fix.sh', 'temp-disk-setup.sh') } { Global:PrOut $name 'FIXED' @(@{ name = 'change'; status = 'FIXED'; detail = 'x' }) }
                           default              { Global:PrOut $name 'READY' }
                       }
                   }
            $out | ConvertTo-Json -Depth 8 -Compress
        }
    }

    function Script:PrRun {
        param($Plan)
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; plan = $Plan } {
            Invoke-VmfStateMachine -PlanEntry $plan -RunPath $rp -RunId 'pr-test'
        }
    }

    function Script:PrStop {
        param($Doc)
        @($Doc.history)[-1]
    }

    function Script:PrDoc {
        & (Get-Module VmMigrationFactory) { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } $script:runPath $script:vmId
    }

    # The step the engine is in, from the machine's state document.
    function Global:PrEngineStep {
        param([string]$RunPath)
        & (Get-Module VmMigrationFactory) { param($rp, $id) [string](Read-VmfStateDoc -RunPath $rp -VmId $id).state } $RunPath $script:vmId
    }

    # True once the rollback has begun - read from the run's own event log, so a
    # mock can fail the step and let the way back through.
    function Global:PrRollbackStarted {
        param([string]$RunPath)
        $log = Join-Path $RunPath 'logs' 'events.jsonl'
        (Test-Path $log) -and [bool](Select-String -Path $log -Pattern '"step":"rollback"' -SimpleMatch -Quiet)
    }

    # A machine at GUEST_PREP, past its first copy, with one data disk - for the
    # tests that drive the rollback itself (review F1, F4, F8, F12).
    function Script:PrDataDiskRun {
        param([string]$Kind = 'disks', [string]$OsSkuNow = 'Premium_LRS', [string]$OsSkuFirst = '', [string]$SizeFirst = '')
        $rp = $script:runPath
        & (Get-Module VmMigrationFactory) {
            param($rp, $id, $sub, $kind, $osSkuNow, $osSkuFirst, $sizeFirst)
            New-VmfStateDoc -RunPath $rp -RunId 'pr-test' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $vmConfig = [pscustomobject]@{ name = 'vm-under-test'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'
                zones = @(); osDisk = [pscustomobject]@{ name = 'vm-os'; skuName = $osSkuNow; managedDiskId = "$sub/disks/vm-os" }
                dataDisks = @([pscustomobject]@{ name = 'vm-data0'; lun = 0; managedDiskId = "$sub/disks/vm-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS' })
                nics = @(); tags = @{} }
            $captured = [pscustomobject]@{ vmConfig = $vmConfig }
            if ($osSkuFirst) {
                $first = $vmConfig | ConvertTo-Json -Depth 10 | ConvertFrom-Json
                $first.osDisk.skuName = $osSkuFirst
                if ($sizeFirst) { $first.size = $sizeFirst }
                $captured | Add-Member -NotePropertyName original -NotePropertyValue ([pscustomobject]@{ vmConfig = $first; extensions = @(); capturedUtc = '2026-10-01T00:00:00Z' })
            }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue $captured -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/vm-pristine"; pristineSnapshotLocked = $true
                    pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm-data0"; snapshotId = "$sub/snapshots/vm-pristine-d0"; locked = $true }) }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'GUEST_PREP' -Outcome ok | Out-Null
            $ctx = New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'pr-test'
            Set-VmfRollbackPending -Context $ctx -Kind $kind -State 'GUEST_PREP' -ReasonCode 'guestPrepBlocked' -Detail 'nvme-fix.sh could not finish'
        } $rp $script:vmId $script:sub $Kind $OsSkuNow $OsSkuFirst $SizeFirst
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = 'x'; name = 'x' }) }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:prCalls.Add('swapData'); @{ Applied = $true } }
    }

    function Script:PrComplete {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            $ctx = New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'pr-test'
            Complete-VmfRollback -Context $ctx
        }
    }

    # After the rollback began, the calls the machine received.
    function Script:PrAfterRollback {
        $all = @($global:prCalls)
        $at = [array]::IndexOf($all, ($all | Where-Object { $_ -like 'create:*asitwas*' } | Select-Object -First 1))
        if ($at -lt 0) { return @() }
        @($all[$at..($all.Count - 1)])
    }
}

AfterAll {
    Remove-Item -Path 'function:\Get-AzVM', 'function:\Update-AzVM', 'function:\Get-AzNetworkInterface', 'function:\PrRollbackStarted', 'function:\PrEngineStep', 'function:\PrOut' -ErrorAction SilentlyContinue
    Remove-Variable prOs, prAnswers, prCalls, prScripts -Scope Global -ErrorAction SilentlyContinue
}

Describe 'PREP-ROLLBACK-1: a stop after the preparation changed the machine puts it back' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pr-test' | Out-Null }
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable prRunPath, prAbandoned -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a Linux preparation script that fails is rolled back from the first copy, disks only, in the order disk - stop - swap - start' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-fix.sh' = 'BLOCKED' }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'guestPrepBlocked' -Because 'why it stopped stays the preparation, not the rollback'
        $stop.machineState | Should -Be 'restored'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0 -Because 'the hardware was never changed, so nothing sets it back'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking -Times 0 -Because 'accelerated networking changes only in CONVERTING'
        # Review F12: the order, from the rollback's own calls.
        # ROLLBACK-DISKS-FIRST-1 (rewritten on purpose): the disk is made
        # BEFORE the stop, so a disk Azure refuses stops the rollback with the
        # machine as the failed step left it.
        $tail = @(@($global:prCalls)[-4..-1])
        $tail[0] | Should -BeLike 'create:*asitwas*'
        $tail[1] | Should -Be 'stop'
        $tail[2] | Should -Be 'swapOs'
        $tail[3] | Should -Be 'start' -Because 'the machine runs again after the swap'
        @($global:prCalls | Where-Object { $_ -eq 'swapOs' }).Count | Should -Be 1
        # Review F4 and F6: on record, as what happened.
        $final.rollback.osDisk.name | Should -Match 'asitwas' -Because 'the disk the machine runs on now is on record'
        $final.rollback.path | Should -Be 'disks' -Because 'the disks went back, the machine was not rebuilt'
        @($final.rollbackDisksDuringRollback).Count | Should -Be 1
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty -Because 'the stop removes the checkpoint in the same write'
    }

    It 'PERF-TELEMETRY-ENGINE-1: the fail line of a preparation stop that is rolled back carries its call times' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-fix.sh' = 'BLOCKED' }
        $final = Script:PrRun (Script:PrPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            param($rp) @(Read-VmfEvents -RunPath $rp -Step 'GUEST_PREP' | Where-Object { $_.outcome -eq 'fail' -and $null -ne $_.PSObject.Properties['durationSec'] }) })
        $lines.Count | Should -Be 1
        $lines[0].calls.v | Should -Be 1 -Because 'the line that closes the step holds its run store and ARM times'
    }

    It 'STEP-LOG-1: a preparation stop whose "fail" line cannot be written is still rolled back, and the script is not run again' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-fix.sh' = 'BLOCKED' }
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'GUEST_PREP' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        (Script:PrStop $final).reasonCode | Should -Be 'guestPrepBlocked'
        @($global:prScripts | Where-Object { $_ -eq 'nvme-fix.sh' }).Count | Should -Be 1 -Because 'a line that was not written never runs a changing script again'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'a preparation script that throws at every attempt is rolled back: its STARTED entry says it may have changed the machine' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-fix.sh' = { throw 'Run command timed out after 60 seconds.' } }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PrStop $final
        $stop.machineState | Should -Be 'restored'
        $stop.detail | Should -Match 'timed out'
        $stop.detail | Should -Match 'may have changed' -Because 'review F7: no script said it changed anything'
        @($final.guestExecutions | Where-Object { $_.script -eq 'nvme-fix.sh' -and $_.result -eq 'STARTED' }).Count | Should -Be 2
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'review F7: a step that throws at every attempt BEFORE any changing script is not rolled back, and is untouched' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-check.sh' = { throw 'The guest agent is not ready.' } }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        (Script:PrStop $final).machineState | Should -Be 'untouched'
        (Script:PrStop $final).detail | Should -Not -Match 'changed'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0
    }

    It 'review F7: a read-only check that is BLOCKED is untouched, and not rolled back' {
        Script:PrMockAzure -Os 'Windows'
        Script:PrMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'BLOCKED' }
        $final = Script:PrRun (Script:PrPlan -Os 'Windows')

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        (Script:PrStop $final).machineState | Should -Be 'untouched'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0
    }

    It 'review F7: a v5 page file move BLOCKED before any change is untouched; one BLOCKED after a change is rolled back' {
        Script:PrMockAzure -Os 'Windows'
        Script:PrMockGuest -Answers @{ 'Move-Pagefile.ps1' = 'BLOCKED' }
        $final = Script:PrRun (Script:PrPlan -Os 'Windows' -Size 'Standard_D2s_v5' -Controller 'SCSI' -SourceArch 'scsi-temp' -TargetArch 'diskless')
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        (Script:PrStop $final).machineState | Should -Be 'untouched'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0

        Remove-Item $script:runPath -Recurse -Force
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pr-test' | Out-Null }
        Script:PrMockGuest -Answers @{ 'Move-Pagefile.ps1' = { Global:PrOut 'Move-Pagefile.ps1' 'BLOCKED' @(@{ name = 'auto-managed pagefile'; status = 'FIXED'; detail = 'disabled' }) -Err 'Access denied' } }
        $final = Script:PrRun (Script:PrPlan -Os 'Windows' -Size 'Standard_D2s_v5' -Controller 'SCSI' -SourceArch 'scsi-temp' -TargetArch 'diskless')
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        (Script:PrStop $final).machineState | Should -Be 'restored'
    }

    It 'a preparation stop that changed nothing is NOT rolled back' {
        # MANA-WIN-1: an install that added nothing, before any other script.
        Script:PrMockAzure -Os 'Windows'
        Script:PrMockGuest -Answers @{ 'Install-ManaDriver.ps1' = 'BLOCKED'; 'Test-ManaReady.ps1' = {
            Global:PrOut 'Test-ManaReady.ps1' 'NEEDS_PREP' @(@{ name = 'mana driver in store'; status = 'INFO'; detail = 'no' }) } }
        $final = Script:PrRun (Script:PrPlan -Os 'Windows' -Path 'A')

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        (Script:PrStop $final).machineState | Should -Be 'untouched'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0 -Because 'a rollback of a machine nothing changed costs a stop and every write since the first copy, for nothing'
    }

    It 'review F7: a MANA install that added files and then failed is rolled back' {
        Script:PrMockAzure -Os 'Windows'
        Script:PrMockGuest -Answers @{ 'Install-ManaDriver.ps1' = { Global:PrOut 'Install-ManaDriver.ps1' 'BLOCKED' @(@{ name = 'packages added'; status = 'INFO'; detail = '7' }) -Err 'pnputil added 7 of 8 INF files.' }
            'Test-ManaReady.ps1' = { Global:PrOut 'Test-ManaReady.ps1' 'NEEDS_PREP' @(@{ name = 'mana driver in store'; status = 'INFO'; detail = 'no' }) } }
        $final = Script:PrRun (Script:PrPlan -Os 'Windows' -Path 'A')

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        (Script:PrStop $final).reasonCode | Should -Be 'manaDriverInstallFailed'
        (Script:PrStop $final).machineState | Should -Be 'restored'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'a shutdown that fails after the preparation changed the machine is rolled back' {
        Script:PrMockAzure
        Script:PrMockGuest
        $global:prRunPath = $script:runPath
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            $global:prCalls.Add('stop')
            if ((Global:PrEngineStep -RunPath $global:prRunPath) -eq 'STOPPED' -and -not (Global:PrRollbackStarted -RunPath $global:prRunPath)) { throw 'OperationNotAllowed: the machine is busy.' }
        }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'deallocationFailed'
        $stop.machineState | Should -Be 'restored'
        $stop.detail | Should -Not -Match 'untouched' -Because 'the preparation had changed it; that word was the defect'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'review F5: a shutdown that fails, and fails again for the rollback, keeps its reason - the machine is changed, started again, no disk swapped' {
        Script:PrMockAzure
        Script:PrMockGuest
        $global:prRunPath = $script:runPath
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            if ((Global:PrEngineStep -RunPath $global:prRunPath) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' }
        }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'deallocationFailed' -Because 'no disk changed, so this is not a failed rollback'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'Restore'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0
        @($global:prCalls)[-1] | Should -Be 'start'
    }

    It 'a shutdown that fails when the preparation changed nothing still starts the machine again, untouched' {
        # v5 with no temporary disk change: GUEST_PREP reads, and changes nothing.
        Script:PrMockAzure
        Script:PrMockGuest
        $global:prRunPath = $script:runPath
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            if ((Global:PrEngineStep -RunPath $global:prRunPath) -eq 'STOPPED') { throw 'OperationNotAllowed: the machine is busy.' }
        }
        $final = Script:PrRun (Script:PrPlan -Size 'Standard_D2as_v5' -Controller 'SCSI')

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'deallocationFailed'
        $stop.machineState | Should -Be 'untouched'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0
        $stop.detail | Should -Match 'The product started the machine again\. Nothing on the machine changed\.'
    }

    It 'review F3: a fix that changed the registry and then threw, then a READY check, then a failed shutdown - is rolled back, never "untouched"' {
        Script:PrMockAzure -Os 'Windows'
        $global:prFixRuns = 0
        $global:prRunPath = $script:runPath
        Script:PrMockGuest -Answers @{
            'Set-NvmeReady.ps1'  = { $global:prFixRuns++; throw 'Run command timed out after 60 seconds.' }
            'Test-NvmeReady.ps1' = { Global:PrOut 'Test-NvmeReady.ps1' $(if ($global:prFixRuns -gt 0) { 'READY' } else { 'NEEDS_PREP' }) }
        }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            $global:prCalls.Add('stop')
            if ((Global:PrEngineStep -RunPath $global:prRunPath) -eq 'STOPPED' -and -not (Global:PrRollbackStarted -RunPath $global:prRunPath)) { throw 'OperationNotAllowed: the machine is busy.' }
        }
        try { $final = Script:PrRun (Script:PrPlan -Os 'Windows') } finally { Remove-Variable prFixRuns -Scope Global -ErrorAction SilentlyContinue }

        @($final.guestExecutions | Where-Object { $_.script -eq 'Set-NvmeReady.ps1' }).Count | Should -Be 1 -Because 'the second attempt found it READY and skipped the fix'
        @($final.guestExecutions | Where-Object { $_.script -eq 'Set-NvmeReady.ps1' })[0].result | Should -Be 'STARTED' -Because 'it never answered, and the entry from before it ran says so'
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        (Script:PrStop $final).machineState | Should -Be 'restored'
        (Script:PrStop $final).detail | Should -Match 'may have changed'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'a second copy that fails after the preparation changed the machine is rolled back' {
        Script:PrMockAzure
        Script:PrMockGuest
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot {
            if ($SnapshotName -notmatch 'pristine') { throw 'SnapshotQuotaExceeded' }
            '/subscriptions/s/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/snap1'
        }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        (Script:PrStop $final).machineState | Should -Be 'restored'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'a rollback that fails after the swap is said, and the power is put back - and the disk it made is on record (review F4, F12)' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-fix.sh' = 'BLOCKED' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:prCalls.Add('swapOs'); throw 'OperationNotAllowed: the disk is in use.' }
        $final = Script:PrRun (Script:PrPlan)

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'rollbackFailed'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'the disk is in use'
        $stop.detail | Should -Match 'could not finish' -Because 'the original cause stays on record'
        $stop.detail | Should -Match 'started again' -Because 'a machine the rollback stopped is started again'
        @($global:prCalls)[-1] | Should -Be 'start' -Because 'review F12: the words must be true'
        @($final.rollbackDisksDuringRollback | Where-Object { $_.diskName -match 'asitwas' -and $null -eq $_.lun }).Count | Should -Be 1 -Because 'a disk that bills is never on no record'
        $final.PSObject.Properties['rollback'] | Should -BeNullOrEmpty -Because 'no swap took, so the machine runs on the disk it had'
    }

    It 'review 2, finding 6: a park for a decision on a second visit, after a fix changed the guest, is rolled back and stays a decision' {
        Script:PrMockAzure
        Script:PrMockGuest
        # A machine at GUEST_PREP in an attempt whose fix already ran (STOPPED
        # sent it back), parked now for its driver.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId; sub = $script:sub } {
            New-VmfStateDoc -RunPath $rp -RunId 'pr-test' -VmId $id | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{ name = 'vm-under-test'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'
                osDisk = [pscustomobject]@{ name = 'vm-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm-os" }; dataDisks = @(); nics = @(); zones = @() } }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null; pristineSnapshotId = "$sub/snapshots/p"; pristineSnapshotLocked = $true }) -Force
            $doc | Add-Member -NotePropertyName guestExecutions -NotePropertyValue @([pscustomobject]@{ script = 'nvme-fix.sh'; version = '1.0.0'; sha256 = ('a' * 64); tsUtc = (Get-Date).ToUniversalTime().AddSeconds(1).ToString('o'); result = 'FIXED'; evidenceRef = 'evidence/x' }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'GUEST_PREP' -Outcome ok | Out-Null
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDriverJudgement { @{ Status = 'FAIL'; Detail = 'The kernel has no MANA driver.' } }
        $plan = Script:PrPlan
        $plan.policy = [pscustomobject]@{ onDriverBelowFloor = 'stop' }
        $final = Script:PrRun $plan
        $final.state | Should -Be 'NEEDS_DECISION'
        (Script:PrStop $final).machineState | Should -Be 'restored' -Because 'the fix had changed it; untouched was true only on the first visit'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }

    It 'review F10: a prepared machine that goes round to the loop limit is rolled back, and stays a fault to report' {
        Script:PrMockAzure -Os 'Windows'
        # The check never reads READY, so STOPPED sends the machine back to prepare again, and again.
        Script:PrMockGuest -Answers @{ 'Test-NvmeReady.ps1' = 'NEEDS_PREP' }
        InModuleScope VmMigrationFactory { $script:prLimitWas = $script:VmfStateLoopLimit; $script:VmfStateLoopLimit = 8 }
        try { $final = Script:PrRun (Script:PrPlan -Os 'Windows') }
        finally { InModuleScope VmMigrationFactory { $script:VmfStateLoopLimit = $script:prLimitWas } }

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'stepLoopLimit'
        $stop.machineState | Should -Be 'restored'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
    }
}

Describe 'PREP-ROLLBACK-1 review F2: a worker that stops during a rollback - the next one finishes it' {
    BeforeAll {
        # The first swap of the rollback loses the lease: the worker dies there.
        function Script:PrDieAtFirstSwap {
            Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk {
                $global:prCalls.Add('swapOs')
                if (-not $global:prAbandoned) { $global:prAbandoned = $true; throw 'Lease lost - abandon this VM.' }
            }
        }
    }
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pr-test' | Out-Null }
        $global:prAbandoned = $false
    }
    AfterEach {
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
        Remove-Variable prRunPath, prAbandoned -Scope Global -ErrorAction SilentlyContinue
    }

    It 'Path A, a preparation stop: the worker dies in the rollback; the resume finishes it and never goes on to CONVERTING' {
        Script:PrMockAzure
        Script:PrMockGuest -Answers @{ 'nvme-fix.sh' = 'BLOCKED' }
        Script:PrDieAtFirstSwap
        { Script:PrRun (Script:PrPlan) } | Should -Throw '*abandon this VM*'
        (Script:PrDoc).rollbackPending.kind | Should -Be 'disks' -Because 'the checkpoint was written before the first change'

        $final = Script:PrRun (Script:PrPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        (Script:PrStop $final).reasonCode | Should -Be 'guestPrepBlocked'
        @($final.history | Where-Object { $_.state -in @('STOPPED', 'SAFETY_COPY', 'CONVERTING') }).Count | Should -Be 0
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
    }

    It 'Path A, FAIL-1 after the move: the resume finishes the rollback and never runs CONVERTING again' {
        Script:PrMockAzure
        Script:PrMockGuest
        Script:PrDieAtFirstSwap
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            $global:prCalls.Add("size:$Size")
            if ($Size -eq 'Standard_D2s_v6') { throw 'The resize was refused.' }
        }
        { Script:PrRun (Script:PrPlan) } | Should -Throw '*abandon this VM*'
        (Script:PrDoc).rollbackPending.kind | Should -Be 'full'

        $final = Script:PrRun (Script:PrPlan)
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:prCalls | Where-Object { $_ -eq 'size:Standard_D2s_v6' }).Count | Should -Be 1 -Because 'CONVERTING ran once, before the rollback - never again'
    }

    It 'ROLLBACK-DISKS-FIRST-1 review: a resume whose disk Azure now refuses never says the rollback changed nothing' {
        # The first worker stopped the machine and set the size back before it
        # died at the swap. On the resume, the disks are made again first, and
        # Azure refuses one: "before it changed the machine" would be false.
        Script:PrMockAzure
        Script:PrMockGuest
        Script:PrDieAtFirstSwap
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            $global:prCalls.Add("size:$Size")
            if ($Size -eq 'Standard_D2s_v6') { throw 'The resize was refused.' }
        }
        { Script:PrRun (Script:PrPlan) } | Should -Throw '*abandon this VM*'
        @($global:prCalls | Where-Object { $_ -eq 'size:Standard_D2s_v4' }).Count | Should -Be 1 -Because 'the first worker set the size back before it died'
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { throw 'QuotaExceeded: Azure did not make the disk.' }

        $final = Script:PrRun (Script:PrPlan)
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'rollbackFailed'
        $stop.detail | Should -Not -Match 'before it changed the machine' -Because 'the first worker changed it'
        $stop.detail | Should -Match 'the rollback also failed: QuotaExceeded'
        $stop.detail | Should -Match "The rollback made these disks from the first safety copy, and each is kept: '.*asitwas" -Because 'the first worker made the disks, and they bill'
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B rollback is gone with its step.
    It 'a checkpoint marked done only records the stop - it does not roll the machine back twice' {
        Script:PrMockAzure
        Script:PrDataDiskRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.rollbackPending | Add-Member -NotePropertyName done -NotePropertyValue $true -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $final = Script:PrComplete
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0
    }
}

Describe 'PREP-ROLLBACK-1: the disks-only rollback, with a data disk (review F1, F4, F8, F9, F12)' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Initialize-VmfRun -RunPath $rp -RunId 'pr-test' | Out-Null }
        Script:PrMockAzure
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'makes every disk, stops, swaps the OS disk and then the data disk, starts - and records each disk' {
        Script:PrDataDiskRun
        $final = Script:PrComplete
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $calls = @($global:prCalls)
        # ROLLBACK-DISKS-FIRST-1 (rewritten on purpose): every disk, data
        # disks too, is made before the stop.
        $calls[0] | Should -BeLike 'create:*asitwas*'
        $calls[1] | Should -BeLike 'create:vm-data0-d0-asitwas*'
        $calls[2] | Should -Be 'stop'
        $calls[3] | Should -Be 'swapOs'
        $calls[4] | Should -Be 'swapData'
        $calls[5] | Should -Be 'start'
        $calls.Count | Should -Be 6
        @($final.rollbackDisksDuringRollback).Count | Should -Be 2
        @($final.rollback.dataDisks)[0].lun | Should -Be 0
        $final.rollback.path | Should -Be 'disks'
    }

    It 'review F1, ROLLBACK-EMPTY-LUN-1: a data disk swap that leaves a LUN empty and a disk the record cannot prove - the machine is left STOPPED, never started, and Finish the rollback is offered' {
        Script:PrDataDiskRun
        $global:prWords = InModuleScope VmMigrationFactory { $script:VmfSwapNeitherWords }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:prCalls.Add('swapData'); throw "$global:prWords The swap took on some LUNs and not others." }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        try { $final = Script:PrComplete } finally { Remove-Variable prWords -Scope Global -ErrorAction SilentlyContinue }

        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = Script:PrStop $final
        # ROLLBACK-EMPTY-LUN-1: the disk made from the copy cannot be read
        # here, so nothing is attached; the LUN waits on record for Finish the
        # rollback - never a step to do in Azure.
        $stop.reasonCode | Should -Be 'dataDiskSwapRefused'
        $stop.detail | Should -Match 'left STOPPED'
        $stop.detail | Should -Match 'LUN 0 has no disk'
        $stop.detail | Should -Match 'Finish the rollback'
        $stop.detail | Should -Not -Match 'Attach each'
        @($final.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
        @(Script:PrAfterRollback) | Should -Not -Contain 'start' -Because 'a Linux mount with no nofail stops the boot'
        $final.rollback.osDisk.name | Should -Match 'asitwas' -Because 'review F4: the OS swap took, and the record names the disk the machine has'
    }

    It 'review F1: Azure''s own words keep the machine stopped even when the LUNs cannot be read' {
        Script:PrDataDiskRun
        $global:prWords = InModuleScope VmMigrationFactory { $script:VmfSwapNeitherWords }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { throw "$global:prWords Detaching them failed part way." }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { throw 'The read was refused.' }
        try { $final = Script:PrComplete } finally { Remove-Variable prWords -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @(Script:PrAfterRollback) | Should -Not -Contain 'start'
    }

    It 'review F8 and F9: the disks go back on the type they have now, with the current size named - and a retired first size refuses nothing' {
        Script:PrDataDiskRun -OsSkuNow 'Premium_LRS' -OsSkuFirst 'Standard_LRS' -SizeFirst 'Standard_D2_v3'
        Mock -ModuleName VmMigrationFactory Get-VmfRetiredRollbackRefusal { 'Microsoft retired this size.' }
        $final = Script:PrComplete
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfRetiredRollbackRefusal -Times 0
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -ParameterFilter { $DiskName -like 'vm1-osdisk-asitwas*' -and $SkuName -eq 'Premium_LRS' } -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -ParameterFilter { $SkuName -eq 'Standard_LRS' } -Times 0
        $log = Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') -Raw
        $log | Should -Match 'Standard_D2s_v4' -Because 'the size the machine has now'
        $log | Should -Not -Match 'Standard_D2_v3'
    }

    It 'review 2, finding 7: every disk back and only the start failed - restored, never "rollback failed"' {
        Script:PrDataDiskRun
        $global:prStarts = 0
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:prCalls.Add('start'); $global:prStarts++; if ($global:prStarts -eq 1) { throw 'OperationNotAllowed: the host is busy.' } }
        try { $final = Script:PrComplete } finally { Remove-Variable prStarts -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'guestPrepBlocked'
        $stop.machineState | Should -Be 'restored' -Because 'the second start worked'
        $stop.detail | Should -Match 'host is busy'
    }

    It 'review 2, finding 5: a worker that stops after the last call of the rollback - the resume only records, never swaps again' {
        Script:PrDataDiskRun
        $global:prDied = $false
        Mock -ModuleName VmMigrationFactory Clear-VmfRetryState { if (-not $global:prDied) { $global:prDied = $true; throw 'Lease lost - abandon this VM.' } }
        try {
            { Script:PrComplete } | Should -Throw '*abandon this VM*'
            $global:prCalls.Clear()
            $final = Script:PrComplete
        }
        finally { Remove-Variable prDied -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:prCalls).Count | Should -Be 0 -Because 'the machine is back; a second stop and swap would lose the writes since'
    }

    It 'STEP-LOG-1: the last line of a rollback that worked cannot be written - restored, never "rollback failed"' {
        Script:PrDataDiskRun
        Mock -ModuleName VmMigrationFactory Write-Warning { }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'rollback' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $final = Script:PrComplete
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'guestPrepBlocked' -Because 'the machine is back; the line is not the rollback'
        $stop.machineState | Should -Be 'restored'
        Should -Invoke -ModuleName VmMigrationFactory Write-Warning -ParameterFilter { $Message -match 'could not be written' } -Times 1 -Exactly
    }

    It 'the way back refuses with no first copy, before it stops anything - and keeps the cause' {
        Script:PrDataDiskRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; id = $script:vmId } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety.pristineSnapshotId = $null
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $final = Script:PrComplete
        $stop = Script:PrStop $final
        $stop.reasonCode | Should -Be 'guestPrepBlocked'
        $stop.machineState | Should -Be 'changed'
        $stop.detail | Should -Match 'first safety copy'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
    }
}

Describe 'PREP-ROLLBACK-1: the rules, pure' {
    It 'Test-VmfPrepRollbackWanted: <Name>' -ForEach @(
        @{ Name = 'GUEST_PREP, changed';                 State = 'GUEST_PREP';  Next = 'FAILED_NEEDS_ATTENTION'; Ms = 'changed';   Ex = $false; Changed = $false; Want = $true }
        @{ Name = 'GUEST_PREP, untouched';               State = 'GUEST_PREP';  Next = 'FAILED_NEEDS_ATTENTION'; Ms = 'untouched'; Ex = $false; Changed = $true;  Want = $false }
        @{ Name = 'GUEST_PREP, a decision';              State = 'GUEST_PREP';  Next = 'NEEDS_DECISION';         Ms = 'untouched'; Ex = $false; Changed = $false; Want = $false }
        @{ Name = 'GUEST_PREP, goes on';                 State = 'GUEST_PREP';  Next = 'STOPPED';                Ms = '';          Ex = $false; Changed = $true;  Want = $false }
        @{ Name = 'GUEST_PREP threw, changed';           State = 'GUEST_PREP';  Next = '';                       Ms = '';          Ex = $true;  Changed = $true;  Want = $true }
        @{ Name = 'GUEST_PREP threw, nothing changed';   State = 'GUEST_PREP';  Next = '';                       Ms = '';          Ex = $true;  Changed = $false; Want = $false }
        @{ Name = 'STOPPED threw, prepared';             State = 'STOPPED';     Next = '';                       Ms = '';          Ex = $true;  Changed = $true;  Want = $true }
        @{ Name = 'STOPPED threw, nothing prepared';     State = 'STOPPED';     Next = '';                       Ms = '';          Ex = $true;  Changed = $false; Want = $false }
        @{ Name = 'SAFETY_COPY threw, prepared';         State = 'SAFETY_COPY'; Next = '';                       Ms = '';          Ex = $true;  Changed = $true;  Want = $true }
        @{ Name = 'SAFETY_COPY threw, nothing prepared'; State = 'SAFETY_COPY'; Next = '';                       Ms = '';          Ex = $true;  Changed = $false; Want = $false }
        @{ Name = 'SAFETY_PRISTINE threw';               State = 'SAFETY_PRISTINE'; Next = '';                   Ms = '';          Ex = $true;  Changed = $true;  Want = $false }
        @{ Name = 'PRECHECK threw';                      State = 'PRECHECK';    Next = '';                       Ms = '';          Ex = $true;  Changed = $true;  Want = $false }
        @{ Name = 'CONVERTING threw (its own rollback)'; State = 'CONVERTING';  Next = '';                       Ms = '';          Ex = $true;  Changed = $true;  Want = $false }
    ) {
        InModuleScope VmMigrationFactory -Parameters $_ {
            Mock Test-VmfGuestChangedThisAttempt { $Changed }
            Test-VmfPrepRollbackWanted -State $State -Next $Next -MachineState $Ms -Exhausted:$Ex -Doc ([pscustomobject]@{}) | Should -Be $Want
        }
    }

    It 'the audit trail: <Name>' -ForEach @(
        @{ Name = 'a MANA driver the product added';    Script = 'Install-ManaDriver.ps1'; Result = 'FIXED';      Earlier = $false; Want = 'changed' }
        @{ Name = 'a MANA driver that was there';       Script = 'Install-ManaDriver.ps1'; Result = 'NO_CHANGE';  Earlier = $false; Want = 'none' }
        @{ Name = 'a MANA install that failed';         Script = 'Install-ManaDriver.ps1'; Result = 'BLOCKED';    Earlier = $false; Want = 'none' }
        @{ Name = 'a MANA install, nothing pinned';     Script = 'Install-ManaDriver.ps1'; Result = 'NEEDS_PREP'; Earlier = $false; Want = 'none' }
        @{ Name = 'a MANA install that never answered'; Script = 'Install-ManaDriver.ps1'; Result = 'STARTED';    Earlier = $false; Want = 'mayHaveChanged' }
        @{ Name = 'a MANA driver added in an EARLIER attempt'; Script = 'Install-ManaDriver.ps1'; Result = 'FIXED'; Earlier = $true; Want = 'none' }
        @{ Name = 'a fix that never answered';          Script = 'Set-NvmeReady.ps1';      Result = 'STARTED';    Earlier = $false; Want = 'mayHaveChanged' }
        @{ Name = 'a fix that was BLOCKED';             Script = 'nvme-fix.sh';            Result = 'BLOCKED';    Earlier = $false; Want = 'mayHaveChanged' }
        @{ Name = 'a fix that changed nothing';         Script = 'nvme-fix.sh';            Result = 'NO_CHANGE';  Earlier = $false; Want = 'none' }
        @{ Name = 'a kernel update that never answered'; Script = 'kernel-update.sh';      Result = 'STARTED';    Earlier = $false; Want = 'mayHaveChanged' }
        @{ Name = 'a read-only check that was BLOCKED'; Script = 'Test-NvmeReady.ps1';     Result = 'BLOCKED';    Earlier = $false; Want = 'none' }
        @{ Name = 'a fix in an EARLIER attempt';        Script = 'Set-NvmeReady.ps1';      Result = 'FIXED';      Earlier = $true;  Want = 'none' }
    ) {
        InModuleScope VmMigrationFactory -Parameters $_ {
            $now = (Get-Date).ToUniversalTime()
            $ran = if ($Earlier) { $now.AddMinutes(-10) } else { $now }
            $doc = [pscustomobject]@{
                history = @([pscustomobject]@{ state = 'PRECHECK'; tsUtc = $now.AddMinutes(-5).ToString('o') })
                guestExecutions = @([pscustomobject]@{ script = $Script; tsUtc = $ran.ToString('o'); result = $Result }) }
            Get-VmfGuestChangeThisAttempt -Doc $doc | Should -Be $Want
            Test-VmfGuestChangedThisAttempt -Doc $doc | Should -Be ($Want -ne 'none')
        }
    }
}
