#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-CROSS-RUN-1: a restore in an older migration while a newer one holds
# the machine.
#
# A lease lives UNDER a migration, so it fences the jobs of one migration only
# (RESTORE-ONE-AT-A-TIME-1). Between migrations the fence is the store-wide
# machine claim (RUN-CLAIM-1). A machine migrated in migration A is released at
# the end of A's wave; migration B can then claim it and move it. A's panel
# still offers Restore this machine, Rebuild this machine and Finish, and each
# took only A's lease - so both jobs could stop the machine and change its
# disks at the same time.
#
# Decided 2026-10-23: refuse them while another live migration holds
# the claim - a safety block for a case nobody has seen. Allowed again once
# that migration no longer holds it (released, or its migration is gone). The
# engine refuses before anything changes, and the service before a job starts.
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

    $script:SUB = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute'
    $global:XrVm = "$script:SUB/virtualMachines/app01"

    # One store with two migrations: run-old (the machine's record, its copy)
    # and run-new (a newer migration of the same machine).
    function Global:XrNewStore {
        param([ValidateSet('copy', 'stranded', 'swapLeft')][string]$Shape = 'copy')
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-xr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $store | Out-Null
        $global:XrStore = $store
        $global:XrOld = Join-Path $store 'run-old'
        $global:XrNew = Join-Path $store 'run-new'
        & (Get-Module VmMigrationFactory) { param($old, $new, $vmId, $sub, $shape)
            Initialize-VmfRun -RunPath $old -RunId 'run-old' | Out-Null
            Initialize-VmfRun -RunPath $new -RunId 'run-new' | Out-Null
            New-VmfStateDoc -RunPath $old -RunId 'run-old' -VmId $vmId -Wave 'lab-1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $old -VmId $vmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                snapshotId = "$sub/snapshots/app01-snap"; cloneVmId = $null }) -Force
            $doc.state = 'MIGRATED'
            if ($shape -eq 'stranded') {
                $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{
                        name = 'app01'; osType = 'Windows'; location = 'centralus'
                        size = 'Standard_D2ds_v4'; controller = 'SCSI'
                        osDisk = [pscustomobject]@{ name = 'app01-osdisk'; managedDiskId = "$sub/disks/app01-osdisk"; deleteOption = 'Delete'; skuName = 'Premium_LRS' }
                        dataDisks = @(); nics = @()
                    } }) -Force
                $doc.state = 'FAILED_NEEDS_ATTENTION'
            }
            if ($shape -eq 'swapLeft') {
                $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @();
                    kind = 'restore'; leftUtc = '2026-10-23T10:00:00Z'; error = 'OperationNotAllowed: the disk is in use'; usedBy = ''
                    swaps = @([pscustomobject]@{ lun = 0; name = 'app01-data0'; oldDiskId = "$sub/disks/app01-data0"; diskId = "$sub/disks/app01-data0-new"; diskName = 'app01-data0-new'; caching = 'None'; instantAccess = $false })
                    swapped = @() }) -Force
            }
            $null = Add-VmfTestMachineCapture $doc 'app01' "$sub/disks/app01-osdisk"
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $old -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'lab-1'; ring = 'lab'
                assessment = [ordered]@{ location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $old -RelPath 'plan.json' -Document $plan -Depth 24
        } $global:XrOld $global:XrNew $global:XrVm $script:SUB $Shape
        $store
    }
    # The newer migration claims the machine, the way its wave's worker does.
    function Global:XrClaim([string]$RunPath, [string]$RunId) {
        $r = & (Get-Module VmMigrationFactory) { param($rp, $v, $id) New-VmfVmClaim -RunPath $rp -VmId $v -RunId $id } $RunPath $global:XrVm $RunId
        if (-not $r.Granted) { throw "the test could not claim the machine: $($r.Detail)" }
    }
    function Global:XrRelease([string]$RunPath, [string]$RunId) {
        $null = & (Get-Module VmMigrationFactory) { param($rp, $v, $id) Remove-VmfVmClaim -RunPath $rp -VmId $v -RunId $id } $RunPath $global:XrVm $RunId
    }
    function Global:XrLeaseHolder {
        $l = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfLeaseInfo -RunPath $rp -VmId $v } $global:XrOld $global:XrVm
        if ($l) { [string]$l.workerId } else { '' }
    }
    function Global:XrEvents([string]$Step) {
        @(& (Get-Module VmMigrationFactory) { param($rp) @(Read-VmfEvents -RunPath $rp) } $global:XrOld |
            Where-Object { $_.step -eq $Step -and $_.outcome -eq 'start' })
    }

    function Script:MockRestoreOps {
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
    }
    function Script:MockRebuildOps {
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $false }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2ds_v4' }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedAcceleratedNetworking { }
        Mock -ModuleName VmMigrationFactory Restore-VmfCapturedDiskTypes { @() }
        Mock -ModuleName VmMigrationFactory Assert-VmfSizeTakesKeptDisks { }
        Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementCheck { $null }
    }
    function Script:MockFinishOps {
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
    }
    function Script:CleanUp {
        & (Get-Module VmMigrationFactory) { $script:VmfMachineLeaseToken = $null; $script:VmfOpHeartbeat = $null }
        if ($global:XrStore -and (Test-Path $global:XrStore)) { Remove-Item $global:XrStore -Recurse -Force }
    }
}

AfterAll {
    Remove-Variable XrVm, XrStore, XrOld, XrNew -Scope Global -ErrorAction SilentlyContinue
    Remove-Item 'function:\XrNewStore', 'function:\XrClaim', 'function:\XrRelease', 'function:\XrLeaseHolder', 'function:\XrEvents' -ErrorAction SilentlyContinue
}

Describe 'RESTORE-CROSS-RUN-1: the question - does another live migration hold the machine?' {
    BeforeEach { XrNewStore | Out-Null }
    AfterEach { Script:CleanUp }

    It 'names the other migration while it holds the machine' {
        XrClaim $global:XrNew 'run-new'
        $why = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfOtherRunClaimRefusal -RunPath $rp -VmId $v } $global:XrOld $global:XrVm
        $why | Should -BeLike "The migration 'run-new' holds 'app01' now*one migration at a time*"
        $why | Should -BeLike '*Try again after that migration migrates it, or skips or stops it with no change on it, or after you delete that migration.'
    }

    It 'no refusal when <Case>' -ForEach @(
        @{ Case = 'nothing holds the machine'; Setup = { } }
        @{ Case = 'this migration holds it'; Setup = { XrClaim $global:XrOld 'run-old' } }
        @{ Case = 'the other migration released it (its wave ended)'; Setup = { XrClaim $global:XrNew 'run-new'; XrRelease $global:XrNew 'run-new' } }
        @{ Case = 'the other migration is gone (deleted)'; Setup = { XrClaim $global:XrNew 'run-new'; Remove-Item $global:XrNew -Recurse -Force } }) {
        & $Setup
        $why = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfOtherRunClaimRefusal -RunPath $rp -VmId $v } $global:XrOld $global:XrVm
        $why | Should -BeNullOrEmpty
    }

    It 'finds the claim whatever the letter case of the ID' {
        XrClaim $global:XrNew 'run-new'
        $why = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfOtherRunClaimRefusal -RunPath $rp -VmId $v } $global:XrOld $global:XrVm.ToUpperInvariant()
        $why | Should -BeLike "The migration 'run-new' holds*"
    }

    It 'a claim with no migration path recorded is read as alive: unknown never lets two migrations change one machine' {
        & (Get-Module VmMigrationFactory) { param($rp, $v)
            $scope = Get-VmfClaimScopePath -RunPath $rp
            Write-VmfStoreJson -RunPath $scope -RelPath (Get-VmfClaimRelPath -VmId $v) -Document ([ordered]@{ schemaVersion = 1; vmId = $v; runId = 'run-older-code' })
        } $global:XrOld $global:XrVm
        $why = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfOtherRunClaimRefusal -RunPath $rp -VmId $v } $global:XrOld $global:XrVm
        $why | Should -BeLike "The migration 'run-older-code' holds*"
    }

    It 'a migration whose own id cannot be read is not the holder: the claim of another live migration still refuses' {
        XrClaim $global:XrNew 'run-new'
        Remove-Item (Join-Path $global:XrOld 'run.json') -Force
        $why = & (Get-Module VmMigrationFactory) { param($rp, $v) Get-VmfOtherRunClaimRefusal -RunPath $rp -VmId $v } $global:XrOld $global:XrVm
        $why | Should -BeLike "The migration 'run-new' holds*"
    }

    It 'the lease is not taken when the claim refuses, so nothing is left to release' {
        XrClaim $global:XrNew 'run-new'
        { & (Get-Module VmMigrationFactory) { param($rp, $v) Enter-VmfMachineLease -RunPath $rp -VmId $v -Holder 'restore:op-1' } $global:XrOld $global:XrVm } |
            Should -Throw "The migration 'run-new' holds 'app01' now*"
        XrLeaseHolder | Should -Be ''
    }
}

Describe 'RESTORE-CROSS-RUN-1: Restore this machine (Restore-VmfVm) in the older migration' {
    BeforeEach { XrNewStore | Out-Null; Script:MockRestoreOps }
    AfterEach { Script:CleanUp }

    It 'is refused before any Azure call and before its start line while a newer migration holds the machine' {
        XrClaim $global:XrNew 'run-new'
        { Restore-VmfVm -RunPath $global:XrOld -VmId $global:XrVm -CorrelationId 'op-1' -Confirm:$false } |
            Should -Throw "*The migration 'run-new' holds 'app01' now*"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfOsDiskInfo -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0 -Exactly
        (XrEvents 'restore').Count | Should -Be 0 -Because 'with no start line the page never opens a restore'
        XrLeaseHolder | Should -Be ''
        Should -Invoke -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext -Times 1 -Exactly
    }

    It 'runs again once the newer migration released the machine' {
        XrClaim $global:XrNew 'run-new'
        XrRelease $global:XrNew 'run-new'
        $r = Restore-VmfVm -RunPath $global:XrOld -VmId $global:XrVm -CorrelationId 'op-2' -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 1 -Exactly
    }

    It 'runs when the migration that held the claim is gone (Test-VmfClaimHolderAlive)' {
        XrClaim $global:XrNew 'run-new'
        Remove-Item $global:XrNew -Recurse -Force
        $r = Restore-VmfVm -RunPath $global:XrOld -VmId $global:XrVm -CorrelationId 'op-3' -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
    }

    It 'runs while its own migration holds the claim' {
        XrClaim $global:XrOld 'run-old'
        $r = Restore-VmfVm -RunPath $global:XrOld -VmId $global:XrVm -CorrelationId 'op-4' -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
    }

    It 'stops before the stop when a newer migration claims the machine while the restore made its disks' {
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            XrClaim $global:XrNew 'run-new'
            "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName"
        }
        { Restore-VmfVm -RunPath $global:XrOld -VmId $global:XrVm -CorrelationId 'op-5' -Confirm:$false 3>$null } |
            Should -Throw "*before it changed the machine*The migration 'run-new' holds 'app01' now*"
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        XrLeaseHolder | Should -Be '' -Because 'the refusal releases the restore''s own hold'
    }
}

# REBUILD-REMOVE-RECOVER-1: removed with Rebuild this machine (Restore-VmfVmShell).

Describe 'RESTORE-CROSS-RUN-1: Finish the restore (Complete-VmfDataDiskSwap) in the older migration' {
    BeforeEach { XrNewStore -Shape swapLeft | Out-Null; Script:MockFinishOps }
    AfterEach { Script:CleanUp }

    It 'is refused before any Azure call and before its start line while a newer migration holds the machine' {
        XrClaim $global:XrNew 'run-new'
        { Complete-VmfDataDiskSwap -RunPath $global:XrOld -VmId $global:XrVm -FinishedBy 'operator@example.com' -CorrelationId 'op-1' -Confirm:$false } |
            Should -Throw "*The migration 'run-new' holds 'app01' now*"
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDataDiskInfo -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        (XrEvents 'finish').Count | Should -Be 0
        XrLeaseHolder | Should -Be ''
    }

    It 'goes past the fence once the newer migration released the machine' {
        XrClaim $global:XrNew 'run-new'
        XrRelease $global:XrNew 'run-new'
        # The mocked machine has no disk on LUN 0, and the disk that waits for
        # it does not exist (RESTORE-EMPTY-LUN-1: Finish attaches only a disk
        # that exists), so Finish refuses on its own rule - after its start
        # line, which proves the fence let it in.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
        { Complete-VmfDataDiskSwap -RunPath $global:XrOld -VmId $global:XrVm -FinishedBy 'operator@example.com' -CorrelationId 'op-2' -Confirm:$false } |
            Should -Throw '*LUN 0*'
        (XrEvents 'finish').Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDataDiskInfo -Times 1 -Exactly
    }
}

Describe 'RESTORE-CROSS-RUN-1: the service refuses before a job starts' {
    BeforeAll {
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    BeforeEach {
        XrNewStore | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $global:XrStore)
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
        Script:CleanUp
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
    }

    It 'refuses a <Operation> in the older migration while a newer one holds the machine, and the dialog names it' -ForEach @(
        @{ Operation = 'restore' }, @{ Operation = 'finish' }) {
        XrClaim $global:XrNew 'run-new'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-old' -Note 'n' -VmId $global:XrVm } |
            Should -Throw "400: The migration 'run-new' holds 'app01' now*"
    }

    It 'lets a <Operation> through once the newer migration no longer holds the machine' -ForEach @(
        @{ Operation = 'restore' }, @{ Operation = 'finish' }) {
        XrClaim $global:XrNew 'run-new'
        XrRelease $global:XrNew 'run-new'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation $Operation -RunId 'run-old' -Note 'n' -VmId $global:XrVm } |
            Should -Throw 'reached the engine start'
    }

    It 'lets a restore through while its own migration holds the machine' {
        XrClaim $global:XrOld 'run-old'
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'run-old' -Note 'n' -VmId $global:XrVm } |
            Should -Throw 'reached the engine start'
    }
}
