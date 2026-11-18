#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-MID-MOVE-1: a restore is refused while the move of the machine has
# not ended - also when its wave worker stopped.
#
# Found by RESTORE-ONE-AT-A-TIME-1: Restore this machine showed for any machine
# with a safety copy, also one at STOPPED or CONVERTING whose worker stopped.
# The restore took the dead worker's hold over after 900 seconds and put the
# disks back - and the restarted wave then took the machine (its state was
# still CONVERTING) and went on with the move, on the restored disks.
#
# Decided 2026-10-19: the wave's own resume and rollback own a machine
# the wave started. A restore is refused while a machine is mid-move, even when
# its worker died; it is offered only after the move ended, and Stop this
# migration is the way to get the machine back now. A restore never takes over
# a wave worker's hold. On marking the machine restored so the wave skips it:
# wrong - "retry must work, never assume something dies".
#
# Every working state comes from the engine's own list (Get-VmfEngineStates),
# never from a hand list, so a state added to the machine is refused too.
BeforeDiscovery {
    $root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $root 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    $states = InModuleScope VmMigrationFactory { Get-VmfEngineStates }
    $script:workingCases = @($states.Working | ForEach-Object { @{ State = $_ } })
    $script:endedCases = @($states.Terminal | ForEach-Object { @{ State = $_ } })
}

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:SUB = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines'
    $script:DISKS = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks'
    $global:MmVm = "$script:SUB/app01"

    # A machine with a safety copy and the captured configuration a rebuild
    # needs, at the state the test names.
    function Script:MmRun {
        param([Parameter(Mandatory)][string]$State, [string]$Root)
        $rp = if ($Root) { Join-Path $Root 'run-x' } else { Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mm-$([guid]::NewGuid().ToString('N').Substring(0,8))" }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $global:MmVm; disks = $script:DISKS; st = $State } {
            Initialize-VmfRun -RunPath $rp -RunId 'run-x' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'run-x' -VmId $vmId -Wave 'lab-1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                snapshotId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/app01-snap'
                cloneVmId = $null }) -Force
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                vmConfig = [pscustomobject]@{
                    name = 'app01'; osType = 'Windows'; location = 'centralus'
                    size = 'Standard_D2ds_v4'; controller = 'SCSI'
                    osDisk = [pscustomobject]@{ name = 'app01-osdisk'; managedDiskId = "$disks/app01-osdisk"; deleteOption = 'Delete'; skuName = 'Premium_LRS' }
                    dataDisks = @(); nics = @()
                } }) -Force
            $doc.state = $st
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'lab-1'; ring = 'lab'
                assessment = [ordered]@{ location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $global:MmRun = $rp
        $rp
    }

    function Global:MmSetLease([string]$Holder, [int]$AgeSeconds = 0) {
        & (Get-Module VmMigrationFactory) { param($rp, $v, $h, $age)
            $when = (Get-Date).ToUniversalTime().AddSeconds(-$age).ToString('o')
            Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $v) -Document ([ordered]@{ vmId = $v; workerId = $h; acquiredUtc = $when; heartbeatUtc = $when })
        } $global:MmRun $global:MmVm $Holder $AgeSeconds
    }
    function Global:MmLeaseText {
        & (Get-Module VmMigrationFactory) { param($rp, $v) Read-VmfStoreText -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $v) } $global:MmRun $global:MmVm
    }
    function Global:MmDoc {
        & (Get-Module VmMigrationFactory) { param($rp, $v) Read-VmfStateDoc -RunPath $rp -VmId $v } $global:MmRun $global:MmVm
    }
    function Global:MmEvents {
        & (Get-Module VmMigrationFactory) { param($rp) @(Read-VmfEvents -RunPath $rp) } $global:MmRun
    }

    function Script:MmMockAzure {
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName"
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        # The rebuild (Restore-VmfVmShell).
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $false }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedDiskTypes { @() }
        Mock -ModuleName VmMigrationFactory Assert-VmfSizeTakesKeptDisks { }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementCheck { $null }
    }

    # Nothing in Azure was asked or changed, and nothing on the record moved.
    function Script:MmAssertUntouched([string]$State, [string]$Step) {
        Should -Invoke -ModuleName VmMigrationFactory Use-VmfSubscriptionContext -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfOsDiskInfo -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfVmExists -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        $doc = MmDoc
        $doc.state | Should -Be $State -Because 'the refusal leaves the machine to the wave'
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty -Because 'no restore was started'
        $doc.PSObject.Properties['restore'] | Should -BeNullOrEmpty
        @(MmEvents | Where-Object { $_.step -eq $Step -and $_.outcome -eq 'start' }).Count | Should -Be 0
    }

    function Script:MmCleanUp {
        InModuleScope VmMigrationFactory { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if ($global:MmRun -and (Test-Path $global:MmRun)) { Remove-Item $global:MmRun -Recurse -Force }
    }
}

AfterAll {
    Remove-Variable MmRun, MmVm -Scope Global -ErrorAction SilentlyContinue
    Remove-Item 'function:\MmSetLease', 'function:\MmLeaseText', 'function:\MmDoc', 'function:\MmEvents' -ErrorAction SilentlyContinue
}

Describe 'RESTORE-MID-MOVE-1: the refusal, from the engine''s own list of states' {
    It 'a machine at <State> is refused, and the words say the move has not ended and name Stop this migration' -ForEach $script:workingCases {
        $why = InModuleScope VmMigrationFactory -Parameters @{ st = $State } {
            Get-VmfPutBackMidMoveRefusal -Doc ([pscustomobject]@{ state = $st }) -VmName 'app01' -Kind 'restore'
        }
        $why | Should -Match "The move of 'app01' has not ended"
        $why | Should -Match $State
        $why | Should -Match 'Stop this migration'
    }

    It 'a machine at <State> (the move ended) is not refused' -ForEach $script:endedCases {
        InModuleScope VmMigrationFactory -Parameters @{ st = $State } {
            Get-VmfPutBackMidMoveRefusal -Doc ([pscustomobject]@{ state = $st }) -VmName 'app01' -Kind 'restore'
        } | Should -BeNullOrEmpty
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).

    It 'a machine with no record is not refused here (the restore says there is no record)' {
        InModuleScope VmMigrationFactory { Get-VmfPutBackMidMoveRefusal -Doc $null -VmName 'app01' -Kind 'restore' } | Should -BeNullOrEmpty
    }

    It 'the rule reads the engine''s list, not a list of its own' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'state' 'PutBackJob.ps1')
        $fn = [regex]::Match($code, '(?s)function Get-VmfPutBackMidMoveRefusal \{.*?\n\}').Value
        $fn | Should -Not -BeNullOrEmpty
        $fn | Should -Match '\(Get-VmfEngineStates\)\.Working'
        $fn | Should -Not -Match "'CONVERTING'"
    }
}

Describe 'RESTORE-MID-MOVE-1: Restore-VmfVm refuses a machine whose move has not ended, untouched' {
    BeforeEach { Script:MmMockAzure }
    AfterEach { Script:MmCleanUp }

    It 'refuses a restore of a machine at <State>, with no wave worker holding it, before any Azure call' -ForEach $script:workingCases {
        Script:MmRun -State $State | Out-Null
        { Restore-VmfVm -RunPath $global:MmRun -VmId $global:MmVm -CorrelationId 'op-1' -Confirm:$false } |
            Should -Throw "*The move of 'app01' has not ended*Stop this migration*"
        Script:MmAssertUntouched -State $State -Step 'restore'
        MmLeaseText | Should -BeNullOrEmpty -Because 'the refusal takes no hold'
    }

    It 'refuses a restore of a machine at <State> whose wave worker stopped (its hold is older than the limit), and leaves the hold' -ForEach $script:workingCases {
        Script:MmRun -State $State | Out-Null
        MmSetLease 'run-x-w1' -AgeSeconds 2000
        $before = MmLeaseText
        { Restore-VmfVm -RunPath $global:MmRun -VmId $global:MmVm -CorrelationId 'op-1' -Confirm:$false } |
            Should -Throw "*The move of 'app01' has not ended*"
        Script:MmAssertUntouched -State $State -Step 'restore'
        MmLeaseText | Should -Be $before -Because 'the hold of the wave worker is the wave''s to end'
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).

    It 'a restore after the move ended (<State>) still works' -ForEach $script:endedCases {
        Script:MmRun -State $State | Out-Null
        $r = Restore-VmfVm -RunPath $global:MmRun -VmId $global:MmVm -CorrelationId 'op-1' -Confirm:$false 3>$null
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1 -Exactly
        MmLeaseText | Should -BeNullOrEmpty -Because 'the restore released its hold'
    }

    # REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).
}

Describe 'RESTORE-MID-MOVE-1: no restore takes a wave worker''s hold' {
    BeforeEach { Script:MmMockAzure; Script:MmRun -State 'MIGRATED' | Out-Null }
    AfterEach { Script:MmCleanUp }

    It 'a <Kind> is refused by a wave worker''s hold that is older than the limit, and the hold stays' -ForEach @(
        @{ Kind = 'restore' }, @{ Kind = 'rebuild' }) {
        MmSetLease 'run-x-w1' -AgeSeconds 2000
        $before = MmLeaseText
        { InModuleScope VmMigrationFactory -Parameters @{ rp = $global:MmRun; v = $global:MmVm; h = "${Kind}:op-2" } {
            Enter-VmfMachineLease -RunPath $rp -VmId $v -Holder $h
        } } | Should -Throw "A wave migrates 'app01' now*Stop this migration*"
        MmLeaseText | Should -Be $before
    }

    It 'the refusal of a wave worker''s hold does not promise that the hold ends by itself' {
        MmSetLease 'run-x-w1' -AgeSeconds 2000
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ rp = $global:MmRun; v = $global:MmVm } { Enter-VmfMachineLease -RunPath $rp -VmId $v -Holder 'restore:op-2' } }
        catch { $err = $_.Exception.Message }
        $err | Should -Not -BeNullOrEmpty
        $err | Should -Not -Match 'try again after'
    }

    It 'Restore-VmfVm of a migrated machine with an expired wave worker''s hold is refused before it makes a disk' {
        MmSetLease 'run-x-w1' -AgeSeconds 2000
        { Restore-VmfVm -RunPath $global:MmRun -VmId $global:MmVm -CorrelationId 'op-2' -Confirm:$false } | Should -Throw "*A wave migrates 'app01' now*"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfOsDiskInfo -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        (MmLeaseText) | Should -Match 'run-x-w1'
    }

    It 'the expired hold of a restore whose job died is still taken over (RESTORE-ONE-AT-A-TIME-1)' -ForEach @(
        @{ Holder = 'restore:dead' }) {
        MmSetLease $Holder -AgeSeconds 2000
        $t = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:MmRun; v = $global:MmVm } { Enter-VmfMachineLease -RunPath $rp -VmId $v -Holder 'restore:op-2' 3>$null }
        $t.Holder | Should -Be 'restore:op-2'
    }

    It 'kill-resume: a restore resumes under its own hold, also one older than the limit' {
        MmSetLease 'restore:op-5' -AgeSeconds 2000
        $t = InModuleScope VmMigrationFactory -Parameters @{ rp = $global:MmRun; v = $global:MmVm } { Enter-VmfMachineLease -RunPath $rp -VmId $v -Holder 'restore:op-5' }
        $t.Holder | Should -Be 'restore:op-5'
    }

    It 'the service asks the same: an expired wave worker''s hold refuses, an expired restore''s does not' {
        MmSetLease 'run-x-w1' -AgeSeconds 2000
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:MmRun; v = $global:MmVm } { Get-VmfMachineLeaseRefusal -RunPath $rp -VmId $v } |
            Should -Match "A wave migrates 'app01' now"
        MmSetLease 'restore:dead' -AgeSeconds 2000
        InModuleScope VmMigrationFactory -Parameters @{ rp = $global:MmRun; v = $global:MmVm } { Get-VmfMachineLeaseRefusal -RunPath $rp -VmId $v } |
            Should -BeNullOrEmpty
    }
}

Describe 'RESTORE-MID-MOVE-1: the service refuses before a job starts' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mm-store-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $script:store)
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { throw 'reached the engine start' }
    }
    AfterEach {
        InModuleScope FacadeCore { $script:VmfResumeDispatch = $null }
        if ($script:store -and (Test-Path $script:store)) { Remove-Item $script:store -Recurse -Force }
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
    }

    It 'refuses a <Operation> of a machine at CONVERTING with a 400 in the engine''s words' -ForEach @(
        @{ Operation = 'restore' }) {
        Script:MmRun -State 'CONVERTING' -Root $script:store | Out-Null
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-x' -Note 'n' -VmId $global:MmVm } |
            Should -Throw "400: The move of 'app01' has not ended*Stop this migration*"
    }

    It 'refuses a restore of a machine at <State>' -ForEach $script:workingCases {
        Script:MmRun -State $State -Root $script:store | Out-Null
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:MmVm } |
            Should -Throw '400: The move of*'
    }

    It 'finds the machine whatever the letter case the page sent' {
        Script:MmRun -State 'STOPPED' -Root $script:store | Out-Null
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:MmVm.ToUpperInvariant() } |
            Should -Throw '400: The move of*'
    }

    It 'lets a restore of a machine whose move ended (<State>) through' -ForEach $script:endedCases {
        Script:MmRun -State $State -Root $script:store | Out-Null
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:MmVm } |
            Should -Throw 'reached the engine start'
    }

    It 'the timer''s resume of a restore is not refused for the state: it finishes what it started' {
        Script:MmRun -State 'CONVERTING' -Root $script:store | Out-Null
        InModuleScope FacadeCore { $script:VmfResumeDispatch = 'op-1' }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:MmVm } |
            Should -Throw 'reached the engine start'
    }

    It 'refuses a restore of a migrated machine whose wave worker''s hold is older than the limit' {
        Script:MmRun -State 'MIGRATED' -Root $script:store | Out-Null
        MmSetLease 'run-x-w1' -AgeSeconds 2000
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-x' -Note 'n' -VmId $global:MmVm } |
            Should -Throw "400: A wave migrates 'app01' now*"
    }
}
