#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SWAP-REFUSED-AFTER-STOP-1: a data disk Azure will not swap after the stop.
#
# The disks a put-back swaps in are made before the stop (ROLLBACK-DISKS-FIRST-1,
# SAFETY-ULTRA-MARGIN-1), but the swap itself happens after it. When Azure
# refused one, Set-VmfVmDataDisks put the old disk back on its LUN, and the
# rollback or the restore then STARTED the machine with the other disks back
# from the copy and this one as it was - disks from two moments.
#
# Since 2026-10-23 the machine MUST always get back to its original state. So a refused
# swap is tried again through the product's own Azure retry; still refused, the
# machine stays stopped, its record names every disk and Azure's words, and the
# app offers Finish the rollback / Finish the restore, which swaps only the
# disks that are left and then starts the machine.
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

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"

    # A machine with an OS disk and two Premium SSD data disks, both copied.
    function Global:SwNewRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Initialize-VmfRun -RunPath $rp -RunId 'sw' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'sw' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'
                        zones = @('2')
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk" }
                        dataDisks = @(
                            [pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS' }
                            [pscustomobject]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$sub/disks/vm1-data1"; caching = 'None'; sizeGB = 256; skuName = 'Premium_LRS' })
                        nics = @(); tags = @{} } }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/vm1-pristine"; pristineSnapshotLocked = $true
                    pristineDataCopies = @(
                        [pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0"; snapshotId = "$sub/snapshots/vm1-pristine-d0"; locked = $true }
                        [pscustomobject]@{ lun = 1; diskId = "$sub/disks/vm1-data1"; snapshotId = "$sub/snapshots/vm1-pristine-d1"; locked = $true }) }) -Force
            $doc.state = 'CONVERTING'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:SwCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{ safetyCopy = 'pristine' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sw'
        }
    }
    function Global:SwDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:SwLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    function Global:SwEdit($rp, [scriptblock]$Change) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; change = $Change } {
            param($rp, $id, $change)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            & $change $doc
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }

    # Azure, as the mocks see it: which disk is on each LUN, and which LUNs it
    # refuses to swap. A batch that holds a refused LUN is refused whole, with
    # the old disks back on their LUNs - what Set-VmfVmDataDisks does.
    function Global:SwAzure {
        $global:sw = @{ calls = [System.Collections.Generic.List[string]]::new(); dataCalls = 0; refuse = @(); refuseTimes = 99; throwOn = $null
            luns = @{ 0 = "$($script:sub)/disks/vm1-data0"; 1 = "$($script:sub)/disks/vm1-data1" }; startThrows = 0
            # RESTORE-EMPTY-LUN-1: the copy each disk was made from, the disks
            # attached to another machine, and how many attaches to an empty
            # LUN Azure refuses.
            sources = @{}; elsewhere = @(); refuseAttach = 0 }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:sw.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            if ($global:sw.startThrows -gt 0) { $global:sw.startThrows--; throw 'process stopped' }
            $global:sw.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:sw.calls.Add('size') }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = "$($script:sub)/disks/vm1-osdisk"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:sw.calls.Add("create:$DiskName"); $global:sw.sources["$($script:sub)/disks/$DiskName"] = $SnapshotId; "$($script:sub)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $by = if (@($global:sw.elsewhere) -contains $DiskId) { "$($script:sub)/virtualMachines/other-vm" } elseif (@($global:sw.luns.Values) -contains $DiskId) { $script:vmId } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = $by; SourceResourceId = [string]$global:sw.sources[$DiskId] }
        }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:sw.calls.Add("attach:${Lun}:$(($DiskId -split '/')[-1])/$Caching")
            $have = [string]$global:sw.luns[[int]$Lun]
            if ($have) { if ($have -eq $DiskId) { return @{ Applied = $true } }; throw "Machine 'vm1' has the disk '$have' on LUN $Lun." }
            if ($global:sw.refuseAttach -gt 0) { $global:sw.refuseAttach--; return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk cannot be attached' } }
            $global:sw.luns[[int]$Lun] = $DiskId
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:sw.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.dataCalls++
            $luns = @($Swaps | ForEach-Object { [int]$_.lun })
            $global:sw.calls.Add("data:$($luns -join ',')")
            if ($global:sw.throwOn -and @($luns | Where-Object { $_ -in $global:sw.throwOn }).Count) { throw 'the engine process stopped here' }
            if (@($luns | Where-Object { $_ -in $global:sw.refuse }).Count -and $global:sw.refuseTimes -gt 0) {
                $global:sw.refuseTimes--
                return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk is in use' }
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @($global:sw.luns.Keys | Sort-Object | ForEach-Object {
                    $id = [string]$global:sw.luns[$_]
                    [pscustomobject]@{ lun = [int]$_; id = $id; name = ($id -split '/')[-1]; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' } })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        # POWER-AFTER-MOVE-1: the power state a restore reads when it starts -
        # running, unless a test says so.
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/running' }
    }
}
AfterAll { Remove-Item function:SwNewRun, function:SwCtx, function:SwDoc, function:SwLog, function:SwEdit, function:SwAzure -ErrorAction SilentlyContinue }

Describe 'SWAP-REFUSED-AFTER-STOP-1: a refused swap is tried again, through the product''s Azure retry' {
    BeforeEach { SwAzure }
    AfterEach { Remove-Variable sw -Scope Global -ErrorAction SilentlyContinue }

    It 'Invoke-VmfAzOperation tries an error marked as a refused swap again; an unmarked refusal it tries once' {
        InModuleScope VmMigrationFactory {
            $script:n = 0
            $marked = {
                $script:n++
                $e = [System.InvalidOperationException]::new('OperationNotAllowed: refused')
                $e.Data['vmfSwapRefused'] = $true
                throw $e
            }
            { Invoke-VmfAzOperation -Name 'swapTest' -MaxAttempts 3 -BaseDelayMs 1 -Operation $marked } | Should -Throw '*refused*'
            $script:n | Should -Be 3
            $script:n = 0
            { Invoke-VmfAzOperation -Name 'swapTest' -MaxAttempts 3 -BaseDelayMs 1 -Operation { $script:n++; throw 'OperationNotAllowed: refused' } } | Should -Throw '*refused*'
            $script:n | Should -Be 1 -Because 'an unmarked error that is not temporary keeps its old rule'
        }
    }

    It 'Invoke-VmfDataDiskSwap: refused twice, then taken - it took, on the third try' {
        $global:sw.refuse = @(0); $global:sw.refuseTimes = 2
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = @{ RunPath = $null; VmId = $script:vmId; Rg = 'rg-app' } } {
            param($c) Invoke-VmfDataDiskSwap -Context $c -VmName 'vm1' -OpName 'rollback:swapDataDisks' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/d/new0'; diskName = 'new0' })
        }
        $r.Applied | Should -BeTrue
        $global:sw.dataCalls | Should -Be 3
    }

    It 'Invoke-VmfDataDiskSwap: refused on every try - three tries, then not applied with Azure''s words; never more' {
        $global:sw.refuse = @(0)
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = @{ RunPath = $null; VmId = $script:vmId; Rg = 'rg-app' } } {
            param($c) Invoke-VmfDataDiskSwap -Context $c -VmName 'vm1' -OpName 'rollback:swapDataDisks' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/d/new0'; diskName = 'new0' })
        }
        $r.Applied | Should -BeFalse
        $r.Reason | Should -Be 'OperationNotAllowed: the disk is in use'
        $global:sw.dataCalls | Should -Be (InModuleScope VmMigrationFactory { $script:VmfSwapRefusedTries })
        (InModuleScope VmMigrationFactory { $script:VmfSwapRefusedTries }) | Should -Be 3
    }

    It 'a swap left neither way is not tried again (SWAP-2UPD-1): it throws at once' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:sw.dataCalls++; throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 0: NO DISK." }) }
        { InModuleScope VmMigrationFactory -Parameters @{ c = @{ RunPath = $null; VmId = $script:vmId; Rg = 'rg-app' } } {
                param($c) Invoke-VmfDataDiskSwap -Context $c -VmName 'vm1' -OpName 'rollback:swapDataDisks' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/d/new0'; diskName = 'new0' })
            } } | Should -Throw '*neither swapped nor as they were*'
        $global:sw.dataCalls | Should -Be 1
    }
}

Describe 'SWAP-REFUSED-AFTER-STOP-1: the rollback never starts a machine with disks from two moments' {
    BeforeEach { SwAzure; $script:rp = SwNewRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sw -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: Azure refuses the data disks on every try - the machine stays stopped, and the record names each disk' {
        $global:sw.refuse = @(0, 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.dataCalls | Should -Be 3 -Because 'one batch, tried three times'
        $doc = SwDoc $script:rp
        $sp = $doc.swapPending
        $sp.kind | Should -Be 'rollback'
        $sp.error | Should -Be 'OperationNotAllowed: the disk is in use'
        @($sp.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        ($sp.swaps | Where-Object lun -EQ 1).name | Should -Be 'vm1-data1'
        ($sp.swaps | Where-Object lun -EQ 1).oldDiskId | Should -Be "$($script:sub)/disks/vm1-data1"
        ($sp.swaps | Where-Object lun -EQ 1).diskName | Should -Match '^vm1-data1-d1-asitwas-'
        ($sp.swaps | Where-Object lun -EQ 1).diskId | Should -Match '/disks/vm1-data1-d1-asitwas-'
        # FINISH-EMPTY-LUN-PROOF-1: each row names the copy its disk was made from.
        @($sp.swaps | ForEach-Object { [string]$_.snapshotId }) | Should -Be @("$($script:sub)/snapshots/vm1-pristine-d0", "$($script:sub)/snapshots/vm1-pristine-d1")
        $sp.usedBy | Should -Match '^rollback-'
        # FINISH-EMPTY-LUN-WORDS-1: Azure put the old disks back, and the record says so.
        @($sp.swaps | ForEach-Object { [string]$_.lunHolds }) | Should -Be @('had', 'had')
        # Not "left by design": a disk the swap left is not a kept disk.
        @($doc.rollback.keptDataDisks).Count | Should -Be 0
        @($doc.rollback.dataDisks).Count | Should -Be 0
        $doc.rollback.osDisk.name | Should -Match '^vm1-osdisk-asitwas-'
        $doc.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion })
        $log = SwLog $script:rp
        $log | Should -Match 'after 3 tries'
        $log | Should -Match "LUN 1 keeps 'vm1-data1'"
        $log | Should -Not -Match 'and running'
    }

    It 'FINISH-KEPT-DISKS-1, <Name>: the record of the waiting swap names each data disk the rollback keeps as it is' -ForEach @(
        @{ Name = 'Path A'; GuestOnly = $false }, @{ Name = 'GuestOnly'; GuestOnly = $true }) {
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ([string]$DiskId -like '*/vm1-data1') { 2 } else { 1 } }
        $global:sw.refuse = @(0)
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); g = $GuestOnly } { param($c, $g) Invoke-VmfRollback -Context $c -GuestOnly:$g }
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
        @($doc.swapPending.kept | ForEach-Object lun) | Should -Be @(1)
        $doc.swapPending.kept[0].why | Should -Match 'shared'
    }

    It 'FINISH-KEPT-DISKS-1: each swap record the rollback writes between its batches names the kept disks - <How>' -ForEach @(
        @{ How = 'a refused batch' }, @{ How = 'a refused batch, then a batch left neither way' }) {
        # Two batches, one LUN each. The record each batch writes is the one a
        # worker killed right after it leaves.
        Mock -ModuleName VmMigrationFactory Get-VmfSwapBatches { @(@($Swaps) | Sort-Object { [int]$_.lun } | ForEach-Object { [pscustomobject]@{ Swaps = @($_) } }) }
        $global:sw.how = $How
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            if ([int]@($Swaps)[0].lun -eq 0) { return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk is in use' } }
            if ($global:sw.how -like '*neither*') { throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 1: NO DISK." }) }
            return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk is in use' }
        }
        $sub = $script:sub
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); sub = $sub } {
            param($c, $sub)
            $kept = [System.Collections.Generic.List[object]]::new()
            $kept.Add([pscustomobject]@{ lun = 7; name = 'vm1-shared7'; why = 'It is a shared disk (maxShares 2), and other machines can use it.' })
            $left = [System.Collections.Generic.List[object]]::new()
            $swaps = @(
                [pscustomobject]@{ lun = 0; name = 'vm1-data0'; diskId = "$sub/disks/new0"; diskName = 'new0'; instantAccess = $false }
                [pscustomobject]@{ lun = 1; name = 'vm1-data1'; diskId = "$sub/disks/new1"; diskName = 'new1'; instantAccess = $false })
            try { $null = Invoke-VmfDataSwapBatches -Context $c -Path 'A' -OsDisk $null -Swaps $swaps -KeptList $kept -LeftList $left -UsedBy 'rollback-x' } catch { $null = $_ }
        }
        $sp = (SwDoc $script:rp).swapPending
        @($sp.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        @($sp.kept | ForEach-Object lun) | Should -Be @(7)
    }

    It 'Path A: refused once, then taken - the machine starts, and nothing is left' {
        $global:sw.refuse = @(0, 1); $global:sw.refuseTimes = 1
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:sw.calls[-1] | Should -Be 'start'
        $doc = SwDoc $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($doc.rollback.dataDisks | ForEach-Object lun) | Should -Be @(0, 1)
    }

    It 'the stop names every disk, Azure''s words and Finish the rollback; the machine is changed, and the stop it would have recorded is kept' {
        $global:sw.refuse = @(0, 1)
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.machineState | Should -Be 'changed'
        $last.detail | Should -Match 'OperationNotAllowed: the disk is in use'
        $last.detail | Should -Match "LUN 0 keeps 'vm1-data0'"
        $last.detail | Should -Match "LUN 1 keeps 'vm1-data1'"
        $last.detail | Should -Match "'vm1-osdisk-asitwas-"
        $last.detail | Should -Match 'Finish the rollback'
        $last.detail | Should -Match 'the resize failed'
        $doc.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
        $doc.swapPending.stop.state | Should -Be 'FAILED_ROLLED_BACK'
        $doc.swapPending.stop.reasonCode | Should -Be 'rolledBack'
        $doc.swapPending.stop.machineState | Should -Be 'restored'
        $doc.swapPending.stop.detail | Should -Match 'the resize failed'
        # The new reason has guidance, as every stop must.
        (InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'dataDiskSwapRefused' }).whatToDo | Should -Match 'Finish the rollback'
    }

    It 'GuestOnly (a stop before the move): the same - stopped, never started' {
        $global:sw.refuse = @(0, 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        $global:sw.calls | Should -Not -Contain 'start'
        (SwDoc $script:rp).swapPending.kind | Should -Be 'rollback'
    }

    It 'review MUST FIX 2: a <Kind> rollback that throws after the swap is on record never starts the machine, records the stop, and Finish ends it' -ForEach @(
        @{ Kind = 'full' }, @{ Kind = 'disks' }) {
        $global:sw.refuse = @(0, 1)
        $global:sw.clears = 0
        Mock -ModuleName VmMigrationFactory Clear-VmfRetryState { $global:sw.clears++; if ($global:sw.clears -eq 1) { throw 'The store did not answer.' } }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); k = $Kind } {
            param($c, $k)
            Set-VmfRollbackPending -Context $c -Kind $k -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($doc.history)[-1].reasonCode | Should -Be 'dataDiskSwapRefused'
        @($doc.history)[-1].detail | Should -Match 'The store did not answer'
        $doc.swapPending.stop.state | Should -Be 'FAILED_ROLLED_BACK'
        $global:sw.refuse = @()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.calls[-1] | Should -Be 'start'
        (SwDoc $script:rp).state | Should -Be 'FAILED_ROLLED_BACK'
        $global:sw.clears | Should -BeGreaterThan 1 -Because 'the finish clears what the rollback could not'
    }

    It 're-review 2: a swap record that cannot be written - <Why> - never starts a <Kind> rollback; it stops with the reason' -ForEach @(
        @{ Kind = 'disks'; Why = 'the write fails' }, @{ Kind = 'full'; Why = 'the write fails' }, @{ Kind = 'disks'; Why = 'the write is lost' }) {
        $global:sw.refuse = @(0, 1)
        if ($Why -eq 'the write fails') { Mock -ModuleName VmMigrationFactory Set-VmfSwapPending { throw 'The store did not answer.' } }
        else { Mock -ModuleName VmMigrationFactory Set-VmfSwapPending { } }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); k = $Kind } {
            param($c, $k)
            Set-VmfRollbackPending -Context $c -Kind $k -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($doc.history)[-1].reasonCode | Should -Be 'dataDiskSwapRefused'
        @($doc.history)[-1].machineState | Should -Be 'changed'
        @($doc.history)[-1].detail | Should -Match 'could not be written'
        @($doc.history)[-1].detail | Should -Match "LUN 1 keeps 'vm1-data1'"
    }

    It 're-check: two refused batches, the first record written and the second <How> - never Finish, never started' -ForEach @(
        @{ How = 'refused by the store' }, @{ How = 'silently lost' }) {
        Mock -ModuleName VmMigrationFactory Get-VmfSwapBatches { @(@($Swaps) | Sort-Object { [int]$_.lun } | ForEach-Object { [pscustomobject]@{ Swaps = @($_) } }) }
        $global:sw.refuse = @(0, 1)
        $global:sw.saves = 0
        $global:sw.how = $How
        Mock -ModuleName VmMigrationFactory Set-VmfSwapPending {
            $global:sw.saves++
            if ($global:sw.saves -ge 2 -and $Record) {
                if ($global:sw.how -eq 'refused by the store') { throw 'The store did not answer.' }
                return
            }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $RunPath; id = $VmId; r = $Record } {
                param($rp, $id, $r)
                $d = Read-VmfStateDoc -RunPath $rp -VmId $id
                if ($r) { $d | Add-Member -NotePropertyName swapPending -NotePropertyValue $r -Force }
                elseif ($d.PSObject.Properties['swapPending']) { $d.PSObject.Properties.Remove('swapPending') }
                $null = Complete-VmfTestCapture $d
                Write-VmfStateDoc -RunPath $rp -Document $d
            }
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match 'could not be written'
        $last.detail | Should -Match "LUN 0 keeps 'vm1-data0'"
        $last.detail | Should -Match "LUN 1 keeps 'vm1-data1'"
        $last.detail | Should -Not -Match 'It swaps only the disks that are left' -Because 'Finish cannot see every disk, so it is not offered'
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty -Because 'a partial record would let Finish start the machine'
    }
    It 're-review 2, ROLLBACK-EMPTY-LUN-1: a refused batch, then a later batch left neither way - the LUN with no disk gets its disk from the copy, the refused one is on record, and the machine is never started' {
        Mock -ModuleName VmMigrationFactory Get-VmfSwapBatches { @(@($Swaps) | Sort-Object { [int]$_.lun } | ForEach-Object { [pscustomobject]@{ Swaps = @($_) } }) }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            if ([int]@($Swaps)[0].lun -eq 0) { return @{ Applied = $false; Reason = 'OperationNotAllowed: the disk is in use' } }
            $global:sw.luns.Remove(1)
            throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 1: NO DISK." })
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        @($doc.history)[-1].reasonCode | Should -Be 'dataDiskSwapRefused'
        # ROLLBACK-EMPTY-LUN-1: the rollback itself finds LUN 1 with no disk
        # and attaches the disk made from its copy (RESTORE-EMPTY-LUN-1 had
        # left that to Finish). Azure still refuses LUN 0, so it starts nothing.
        @($global:sw.calls | Where-Object { $_ -like 'attach:1:*' }).Count | Should -Be 1
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
        @($doc.swapPending.swapped | ForEach-Object lun) | Should -Be @(1)
        $doc.swapPending.stop | Should -Not -BeNullOrEmpty
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } | Should -Throw -ExpectedMessage "*LUN 0 keeps 'vm1-data0'*stays stopped*"
        $global:sw.calls | Should -Not -Contain 'start'
        @((SwDoc $script:rp).swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
    }
    It 'review note a: a rollback run again that swaps every disk removes a swap record left by its earlier run' {
        SwEdit $script:rp { param($d) $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'rollback'; leftUtc = '2026-10-23T10:00:00Z'; error = 'x'; swaps = @([pscustomobject]@{ lun = 1; name = 'vm1-data1'; diskId = '/d/x'; diskName = 'x' }); swapped = @() }) -Force }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:sw.calls[-1] | Should -Be 'start'
        (SwDoc $script:rp).PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
    }
    It 'kill and resume: a worker that stops after the rollback, before its stop is written, records the stop that keeps it stopped' {
        $global:sw.refuse = @(0, 1)
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            # The worker stops here: the rollback ran, its stop is not written.
            Invoke-VmfRollback -Context $c
        }
        (SwDoc $script:rp).rollbackPending.done | Should -BeTrue
        $before = $global:sw.calls.Count
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $global:sw.calls.Count | Should -Be $before -Because 'the resume runs nothing on the machine again'
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($doc.history)[-1].reasonCode | Should -Be 'dataDiskSwapRefused'
    }
}

Describe 'ROLLBACK-EMPTY-LUN-1: a rollback that Azure, or a stopped worker, leaves between the two updates of a data disk swap' {
    # SWAP-2UPD-1: a data disk is swapped in two updates - detach, then attach.
    # Between them the LUN has no disk. The rollback now finishes the swap the
    # way the restore does (RESTORE-EMPTY-LUN-1, Resolve-VmfEmptyDataLun): the
    # disk the record proves belongs on the LUN goes on it, or, refused, the
    # disk the LUN had goes back and the LUN is a refused swap on swapPending,
    # for Finish the rollback. Never a step to do in Azure (rule 12).
    BeforeEach {
        SwAzure; $script:rp = SwNewRun
        # Set-VmfVmDataDisks as Azure does it: a LUN with no disk is refused
        # before any update.
        $global:sw.neither = $null
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.dataCalls++
            $luns = @($Swaps | ForEach-Object { [int]$_.lun })
            $global:sw.calls.Add("data:$($luns -join ',')")
            foreach ($l in $luns) { if (-not $global:sw.luns.ContainsKey($l)) { throw "Machine 'vm1' has no data disk on LUN $l to put a copy back on." } }
            if ($global:sw.neither) { & $global:sw.neither $Swaps }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        $global:sw.neitherWords = InModuleScope VmMigrationFactory { $script:VmfSwapNeitherWords }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sw -Scope Global -ErrorAction SilentlyContinue }

    It '<Name>: Azure fails between the two updates and leaves LUN 0 with no disk - the rollback attaches the disk made from its copy, with the caching and delete option the capture holds, then starts the machine' -ForEach @(
        @{ Name = 'Path A'; GuestOnly = $false }, @{ Name = 'disks only'; GuestOnly = $true }) {
        SwEdit $script:rp { param($d)
            ($d.captured.vmConfig.dataDisks | Where-Object lun -EQ 0) | Add-Member -NotePropertyName deleteOption -NotePropertyValue 'Delete' -Force
            ($d.captured.vmConfig.dataDisks | Where-Object lun -EQ 0) | Add-Member -NotePropertyName writeAcceleratorEnabled -NotePropertyValue $true -Force }
        # LUN 1 took; LUN 0 was detached and not attached.
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others. ARM reports LUN 0: NO DISK." }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); g = $GuestOnly } {
            param($c, $g)
            Set-VmfRollbackPending -Context $c -Kind $(if ($g) { 'disks' } else { 'full' }) -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $calls = @($global:sw.calls)
        $attach = @($calls | Where-Object { $_ -like 'attach:0:*' })
        $attach.Count | Should -Be 1
        $attach[0] | Should -Match '^attach:0:vm1-data0-d0-asitwas-.+/ReadOnly$' -Because 'the caching the capture holds for LUN 0'
        Should -Invoke -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun -ParameterFilter { $Lun -eq 0 -and $DeleteOption -eq 'Delete' -and $WriteAccelerator } -Times 1 -Exactly -Because 'the delete option and Write Accelerator the capture holds for LUN 0'
        $calls[-1] | Should -Be 'start'
        [array]::IndexOf($calls, $attach[0]) | Should -BeLessThan ([array]::IndexOf($calls, 'start')) -Because 'the machine starts only after every LUN has its disk from the copy'
        $global:sw.luns[0] | Should -Match '/disks/vm1-data0-d0-asitwas-'
        $global:sw.luns[1] | Should -Match '/disks/vm1-data1-d1-asitwas-'
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.history)[-1].machineState | Should -Be 'restored'
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($doc.rollback.dataDisks | ForEach-Object { [int]$_.lun } | Sort-Object) | Should -Be @(0, 1)
        SwLog $script:rp | Should -Match 'LUN 0 had no disk'
        SwLog $script:rp | Should -Match 'azureops:rollback:readDataDisk' -Because 'the rollback''s disk reads are said as the rollback''s'
        SwLog $script:rp | Should -Not -Match 'azureops:restore:readDataDisk'
        @($doc.history)[-1].detail | Should -Not -Match 'Attach each'
    }

    It 'Azure refuses the disk made from the copy on the empty LUN - the disk the LUN had goes back, the machine stays stopped, and Finish the rollback swaps it' {
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others. ARM reports LUN 0: NO DISK." }
        # Every try of the disk made from the copy is refused; the disk LUN 0
        # had goes back on the first try.
        $global:sw.refuseAttach = 3
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.luns[0] | Should -Be "$($script:sub)/disks/vm1-data0" -Because 'the disk LUN 0 had is back on it'
        $global:sw.luns[1] | Should -Match '/disks/vm1-data1-d1-asitwas-'
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:vm1-data0-d0-asitwas-*' }).Count | Should -Be 3
        $global:sw.calls | Should -Contain 'attach:0:vm1-data0/ReadOnly'
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match "LUN 0 keeps 'vm1-data0'"
        $last.detail | Should -Match 'Finish the rollback'
        $last.detail | Should -Not -Match 'Attach each'
        $sp = $doc.swapPending
        @($sp.swaps | ForEach-Object lun) | Should -Be @(0)
        @($sp.swapped | ForEach-Object lun) | Should -Be @(1)
        ($sp.swaps | Where-Object lun -EQ 0).oldDiskId | Should -Be "$($script:sub)/disks/vm1-data0"
        ($sp.swaps | Where-Object lun -EQ 0).lunHolds | Should -Be 'had' -Because 'the disk LUN 0 had is back on it'
        $sp.stop.state | Should -Be 'FAILED_ROLLED_BACK'
        $global:sw.neither = $null
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.calls[-1] | Should -Be 'start'
        (SwDoc $script:rp).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'the record does not prove the disk for the empty LUN (another machine holds it) - nothing is attached, the stop says LUN 0 has no disk, never a disk it keeps, and Finish the rollback attaches it once it is free' {
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others. ARM reports LUN 0: NO DISK." }
        $global:sw.busy = $true
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $by = if ($global:sw.busy -and $DiskId -like '*-d0-asitwas-*') { "$($script:sub)/virtualMachines/other-vm" } elseif (@($global:sw.luns.Values) -contains $DiskId) { $script:vmId } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = $by; SourceResourceId = [string]$global:sw.sources[$DiskId] }
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' }) | Should -BeNullOrEmpty
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.luns.ContainsKey(0) | Should -BeFalse
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match 'LUN 0 has no disk'
        $last.detail | Should -Match 'other-vm'
        $last.detail | Should -Not -Match "LUN 0 keeps"
        SwLog $script:rp | Should -Not -Match 'LUN 0 keeps' -Because 'the run''s activity says the LUN has no disk too'
        $last.detail | Should -Not -Match 'Attach each'
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
        @($doc.swapPending.swapped | ForEach-Object lun) | Should -Be @(1)
        $doc.swapPending.swaps[0].lunHolds | Should -Be 'none'
        $global:sw.busy = $false
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:*' }).Count | Should -Be 1
        $global:sw.calls[-1] | Should -Be 'start'
    }

    # RESUME-ATTACH-UNKNOWN-WORDS-1: the attach to the empty LUN stops with an
    # error that is not a refusal. Which disk is on LUN 0 is not known, so the
    # words the rollback says when it leaves the LUN never say it has no disk
    # or keeps the disk it had: they say the product did not read it.
    It 'RESUME-ATTACH-UNKNOWN-WORDS-1: the attach to the empty LUN stops with an error that is not a refusal (<Case>) - the rollback never says "LUN 0 has no disk" or "LUN 0 keeps" from that attach, and the machine stays stopped' -ForEach @(
        @{ Case = 'the disk went on before the error'; Landed = $true }
        @{ Case = 'the LUN still has no disk'; Landed = $false }) {
        $global:sw.landed = $Landed
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others. ARM reports LUN 0: NO DISK." }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:sw.calls.Add("attach:${Lun}:$(($DiskId -split '/')[-1])")
            if ($global:sw.landed) { $global:sw.luns[[int]$Lun] = $DiskId }
            throw 'Machine vm1 could not be read'
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' }).Count | Should -Be 1 -Because 'asked once, and the disk LUN 0 had is not attached'
        $left = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
                Where-Object { $_.step -eq 'rollback' -and $_.outcome -eq 'warn' -and [string]$_.detail -like '*The machine stays stopped, so it never starts with disks from two moments*' })
        $left.Count | Should -Be 1
        $left[0].detail | Should -Not -Match 'LUN 0 has no disk' -Because 'the attach gave no answer'
        $left[0].detail | Should -Not -Match 'LUN 0 keeps'
        $left[0].detail | Should -Match 'did not read which disk is on these LUNs after the data disk swap: LUN 0,'
        SwLog $script:rp | Should -Match 'The product does not know which disk is on LUN 0 now' -Because 'the attach''s own sentence is in the run''s activity'
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $doc.swapPending.swaps[0].lunHolds | Should -Be 'notRead'
        @($doc.history)[-1].detail | Should -Not -Match 'LUN 0 keeps'
    }
    # LEASE-LOST-EMPTY-LUN-1: the wave worker loses its lease while its
    # rollback fills the LUN with no disk. The heartbeat before each Azure call
    # throws "... abandon this VM". The worker must stop there: another worker
    # may hold the machine now, and a record written after the loss can write
    # over that worker's record and lose the list of the disks it made.
    It 'LEASE-LOST-EMPTY-LUN-1, kill: the lease is lost at <Where> of the empty LUN - the rollback throws the lost lease and writes nothing to the machine''s record after it' -ForEach @(
        @{ Where = 'the read of the disk made from its copy'; Beat = 2; RefuseAttach = 0; Attaches = 0 }
        @{ Where = 'the attach of the disk made from its copy'; Beat = 3; RefuseAttach = 0; Attaches = 0 }
        @{ Where = 'the read of the disk the LUN had, after Azure refused the attach'; Beat = 6; RefuseAttach = 3; Attaches = 3 }) {
        $global:sw.refuseAttach = $RefuseAttach
        $global:sw.rp = $script:rp; $global:sw.vmId = $script:vmId
        $global:sw.armed = $false; $global:sw.beats = 0; $global:sw.loseAt = $Beat; $global:sw.docAtLoss = $null
        # LUN 1 took; LUN 0 was detached and not attached. The beats count from
        # here: 1 is the read of each LUN after the swap.
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            $global:sw.armed = $true
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others. ARM reports LUN 0: NO DISK." }
        $threw = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            # The heartbeat as a wave worker sets it (Invoke-VmfAzOperation runs
            # it before every Azure call). From the lost beat on, another worker
            # holds the lease; the record as it stands then is kept to compare.
            $script:VmfOpHeartbeat = {
                if (-not $global:sw.armed) { return }
                $global:sw.beats++
                if ($global:sw.beats -lt $global:sw.loseAt) { return }
                if ($null -eq $global:sw.docAtLoss) { $global:sw.docAtLoss = Read-VmfStateDoc -RunPath $global:sw.rp -VmId $global:sw.vmId | ConvertTo-Json -Depth 40 }
                throw "Lease for 'vm1' is held by 'worker-2', not 'worker-1' - abandon this VM."
            }
            try { Complete-VmfRollback -Context $c | Out-Null; '' }
            catch { [string]$_.Exception.Message }
            finally { $script:VmfOpHeartbeat = $null }
        }
        $threw | Should -Match 'abandon this VM' -Because 'a worker that lost its lease stops at once'
        $global:sw.docAtLoss | Should -Not -BeNullOrEmpty -Because "the lease was lost at beat $Beat"
        (SwDoc $script:rp | ConvertTo-Json -Depth 40) | Should -Be $global:sw.docAtLoss -Because 'nothing is written to the machine''s record after the lease is lost: not swapPending, not the rollback record'
        (SwDoc $script:rp).PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:*' }).Count | Should -Be $Attaches -Because 'nothing is attached after the lease is lost'
        $global:sw.calls | Should -Not -Contain 'attach:0:vm1-data0/ReadOnly' -Because 'the disk LUN 0 had is not attached after the lease is lost'
        $global:sw.calls | Should -Not -Contain 'start'
    }

    It 'RESUME-ATTACH-UNKNOWN-WORDS-1: Resolve-VmfRollbackSwapLuns, a resumed rollback whose attach to the empty LUN stops with an error that is not a refusal - the LUN is left as not read, and Format-VmfRollbackLeft says it so' {
        Mock -ModuleName VmMigrationFactory Resolve-VmfEmptyDataLun {
            @{ Outcome = 'empty'; Unknown = $true; Reason = 'x'; Caching = 'None'
               Why = "The attach of the disk 'new0' made from its copy to LUN 0 stopped with an error that is not a refusal from Azure: x. The product does not know which disk is on LUN 0 now." }
        }
        $out = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $live = @{ 1 = @{ id = '/d/old1'; name = 'old1' } }
            $j = Resolve-VmfRollbackSwapLuns -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id; VmName = 'vm1'; Rg = 'rg' }) -Resumed `
                -Swaps @([pscustomobject]@{ lun = 0; diskId = '/d/new0'; diskName = 'new0'; name = 'old0' }) -Live $live `
                -OnLun @{ 0 = '/d/old0' } -NameOn @{ 0 = 'old0' } -Cause 'the worker stopped between the two updates of its data disk swap'
            @{ J = $j; Live = $live; Words = (Format-VmfRollbackLeft -Swaps @($j.Left) -Live $live) }
        }
        @($out.J.Left | ForEach-Object lun) | Should -Be @(0)
        $out.J.Left[0].lunHolds | Should -Be 'notRead'
        $out.Live[0].unread | Should -BeTrue
        $out.Words | Should -Match 'did not read which disk is on these LUNs after the data disk swap: LUN 0,'
        $out.Words | Should -Not -Match 'LUN 0 has no disk|LUN 0 keeps'
    }

    It 'the swap throws and the read after it fails - every LUN of the batch is on record, the machine stays stopped, and the words say the product did not read them' {
        $global:sw.neither = { param($batch) $global:sw.luns.Remove(0); $global:sw.readFails = $true
            throw "$($global:sw.neitherWords) Detaching them failed part way." }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            if ($global:sw.readFails) { throw 'The read was refused.' }
            @($global:sw.luns.Keys | Sort-Object | ForEach-Object { $id = [string]$global:sw.luns[$_]; [pscustomobject]@{ lun = [int]$_; id = $id; name = ($id -split '/')[-1] } })
        }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match 'did not read'
        $last.detail | Should -Not -Match 'keeps'
        $last.detail | Should -Match 'Finish the rollback'
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        @($doc.swapPending.swaps | ForEach-Object { [string]$_.lunHolds }) | Should -Be @('notRead', 'notRead')
        $global:sw.readFails = $false
        $global:sw.neither = $null
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:*' }).Count | Should -Be 1
        $global:sw.calls[-1] | Should -Be 'start'
    }

    It 'the swap throws and LUN 0 holds another disk now - it is on record and said as that disk, and the machine stays stopped' {
        $global:sw.neither = { param($batch) $global:sw.luns[0] = "$($script:sub)/disks/somebody-else"
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others." }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' }) | Should -BeNullOrEmpty
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match "LUN 0 holds the disk 'somebody-else'"
        $last.detail | Should -Not -Match "LUN 0 keeps"
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Contain 0
        ($doc.swapPending.swaps | Where-Object lun -EQ 0).lunHolds | Should -Be 'other'
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } | Should -Throw -ExpectedMessage '*somebody-else*swaps nothing*'
    }

    It 'kill and resume, <Kind>: the worker stops between the two updates of the swap - the resume attaches the disk to the empty LUN, swaps nothing twice, then starts the machine' -ForEach @(
        @{ Kind = 'full' }, @{ Kind = 'disks' }) {
        # The worker stops after Azure took LUN 1 and detached LUN 0.
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw 'Lease lost - abandon this VM.' }
        {
            InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); k = $Kind } {
                param($c, $k)
                Set-VmfRollbackPending -Context $c -Kind $k -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
                Complete-VmfRollback -Context $c
            }
        } | Should -Throw '*abandon this VM*'
        (SwDoc $script:rp).rollbackPending | Should -Not -BeNullOrEmpty -Because 'the checkpoint resumes the rollback'
        $global:sw.neither = $null
        $global:sw.calls.Clear()
        $global:sw.dataCalls = 0
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $calls = @($global:sw.calls)
        $global:sw.dataCalls | Should -Be 0 -Because 'LUN 1 has its disk from the copy already, and LUN 0 has no disk to swap'
        @($calls | Where-Object { $_ -like 'attach:0:*' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like 'attach:1:*' }).Count | Should -Be 0
        $calls[-1] | Should -Be 'start'
        $global:sw.luns[0] | Should -Match '/disks/vm1-data0-d0-asitwas-'
        $global:sw.luns[1] | Should -Match '/disks/vm1-data1-d1-asitwas-'
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $doc.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
        @($doc.rollback.dataDisks | ForEach-Object { [int]$_.lun } | Sort-Object) | Should -Be @(0, 1)
    }

    It 'kill and resume: the resume finds LUN 0 on another disk - it is on record, nothing is swapped onto it, and the machine stays stopped' {
        $global:sw.neither = { param($batch) $global:sw.luns.Remove(0); $global:sw.luns.Remove(1); throw 'Lease lost - abandon this VM.' }
        {
            InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
                param($c)
                Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
                Complete-VmfRollback -Context $c
            }
        } | Should -Throw '*abandon this VM*'
        $global:sw.neither = $null
        $global:sw.luns[0] = "$($script:sub)/disks/somebody-else"
        $global:sw.calls.Clear()
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'data:*0*' }) | Should -BeNullOrEmpty
        @($global:sw.calls | Where-Object { $_ -like 'attach:1:*' }).Count | Should -Be 1
        $global:sw.luns[0] | Should -Be "$($script:sub)/disks/somebody-else"
        @($doc.history)[-1].reasonCode | Should -Be 'dataDiskSwapRefused'
        @($doc.history)[-1].detail | Should -Match "LUN 0 holds the disk 'somebody-else'"
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
    }

    It 'the settings come from the capture, never from a restore record a rollback did not write (a putBackJob of an earlier restore)' {
        SwEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName putBackJob -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; ended = '2026-10-20T10:00:00Z'
                    before = [pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 0; caching = 'ReadWrite'; deleteOption = 'Detach'; writeAcceleratorEnabled = $true }) } }) -Force }
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others." }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:*' }) | Should -Match '/ReadOnly$'
        Should -Invoke -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun -ParameterFilter { $Lun -eq 0 -and -not $WriteAccelerator } -Times 1 -Exactly
    }

    It 'the swap throws (<How>) with LUN 1 still on the disk it had and LUN 0 with no disk - LUN 0 gets its disk from the copy, LUN 1 is a swap Azure did not finish, and Finish the rollback swaps it' -ForEach @(
        @{ How = 'left neither way'; Neither = $true }, @{ How = 'another error'; Neither = $false }) {
        $global:sw.useNeither = $Neither
        $global:sw.neither = { param($batch) $global:sw.luns.Remove(0)
            if ($global:sw.useNeither) { throw "$($global:sw.neitherWords) Detaching them failed part way." }
            throw 'Conflict: the machine is busy with another operation.' }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:*' }).Count | Should -Be 1
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match "Azure did not finish the swap of these data disks: LUN 1 keeps 'vm1-data1'"
        $last.detail | Should -Not -Match 'after 3 tries' -Because 'a swap left neither way is never tried again'
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(1)
        @($doc.swapPending.swapped | ForEach-Object lun) | Should -Be @(0)
        ($doc.swapPending.swaps | Where-Object lun -EQ 1).oldDiskId | Should -Be "$($script:sub)/disks/vm1-data1"
        ($doc.swapPending.swaps | Where-Object lun -EQ 1).lunHolds | Should -Be 'had'
        $global:sw.neither = $null
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.calls | Should -Contain 'data:1'
        $global:sw.calls[-1] | Should -Be 'start'
    }

    It 'kill and resume: the worker stops with LUN 0 detached and LUN 1 not swapped yet - the resume attaches LUN 0 and swaps LUN 1 as usual, then starts the machine' {
        $global:sw.neither = { param($batch) $global:sw.luns.Remove(0); throw 'Lease lost - abandon this VM.' }
        {
            InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
                param($c)
                Set-VmfRollbackPending -Context $c -Kind 'disks' -State 'GUEST_PREP' -ReasonCode 'guestPrepBlocked' -Detail 'the script failed'
                Complete-VmfRollback -Context $c
            }
        } | Should -Throw '*abandon this VM*'
        $global:sw.neither = $null
        $global:sw.calls.Clear()
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } { param($c) Complete-VmfRollback -Context $c -Resumed }
        $calls = @($global:sw.calls)
        @($calls | Where-Object { $_ -like 'attach:0:*' }).Count | Should -Be 1
        @($calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:1')
        $calls[-1] | Should -Be 'start'
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        @($doc.rollback.dataDisks | ForEach-Object { [int]$_.lun } | Sort-Object) | Should -Be @(0, 1)
    }

    It 'a LUN left with no disk, and the record of it cannot be written - the stop says LUN 0 has no disk, never a disk it keeps' {
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others." }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $by = if ($DiskId -like '*-d0-asitwas-*') { "$($script:sub)/virtualMachines/other-vm" } elseif (@($global:sw.luns.Values) -contains $DiskId) { $script:vmId } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = $by; SourceResourceId = [string]$global:sw.sources[$DiskId] }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfSwapPending { if ($Record) { throw 'The store did not answer.' } }
        $doc = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c
        }
        $global:sw.calls | Should -Not -Contain 'start'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'dataDiskSwapRefused'
        $last.detail | Should -Match 'could not be written'
        $last.detail | Should -Match 'LUN 0 has no disk'
        $last.detail | Should -Not -Match 'LUN 0 keeps'
    }

    It 'Resolve-VmfRollbackSwapLuns: each LUN judged by the disk on it now - after a swap that threw, and on a resume' {
        Mock -ModuleName VmMigrationFactory Resolve-VmfEmptyDataLun {
            switch ($Lun) {
                2 { @{ Outcome = 'want' } }
                3 { @{ Outcome = 'fallback'; Reason = 'OperationNotAllowed: refused'; Why = 'OperationNotAllowed: refused' } }
                default { @{ Outcome = 'unproven'; Why = "LUN $Lun has no disk. The record does not prove it."; Caching = 'None' } }
            }
        }
        $out = InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            $swaps = @(0..5 | ForEach-Object { [pscustomobject]@{ lun = $_; name = "old$_"; diskId = "/d/new$_"; diskName = "new$_"; snapshotId = "/s/copy$_" } })
            $onLun = @{}; $nameOn = @{}
            foreach ($i in 0..5) { $onLun[$i] = "/d/old$i"; $nameOn[$i] = "old$i" }
            $fresh = { @{ 0 = @{ id = '/d/new0'; name = 'new0' }; 1 = @{ id = '/d/old1'; name = 'old1' }; 5 = @{ id = '/d/other'; name = 'other' } } }
            $liveAfter = & $fresh
            $after = Resolve-VmfRollbackSwapLuns -Context $c -Swaps $swaps -Live $liveAfter -OnLun $onLun -NameOn $nameOn -Why 'W.' -Cause 'c'
            $liveResumed = & $fresh
            $resumed = Resolve-VmfRollbackSwapLuns -Context $c -Swaps $swaps -Live $liveResumed -OnLun $onLun -NameOn $nameOn -Cause 'c' -Resumed
            @{ After = $after; Resumed = $resumed; Live = $liveAfter }
        }
        @($out.After.Took | ForEach-Object lun) | Should -Be @(0, 2)
        @($out.After.Todo).Count | Should -Be 0
        @($out.After.Left | ForEach-Object lun) | Should -Be @(1, 3, 4, 5)
        ($out.After.Left | Where-Object lun -EQ 1).why | Should -Be 'W.'
        ($out.After.Left | Where-Object lun -EQ 1).oldDiskId | Should -Be '/d/old1'
        ($out.After.Left | Where-Object lun -EQ 5).why | Should -Match "LUN 5 holds the disk 'other' now"
        ($out.After.Left | Where-Object lun -EQ 4).why | Should -Match 'LUN 4 has no disk'
        $out.Live[2].id | Should -Be '/d/new2' -Because 'the disk is on LUN 2 now'
        $out.Live[3].id | Should -Be '/d/old3' -Because 'the disk LUN 3 had is back on it'
        $out.Live.ContainsKey(4) | Should -BeFalse -Because 'LUN 4 still has no disk'
        @($out.Resumed.Took | ForEach-Object lun) | Should -Be @(0, 2)
        @($out.Resumed.Todo | ForEach-Object lun) | Should -Be @(1) -Because 'a resume swaps a LUN that still has the disk it had'
        @($out.Resumed.Left | ForEach-Object lun) | Should -Be @(3, 4, 5)
        Should -Invoke -ModuleName VmMigrationFactory Resolve-VmfEmptyDataLun -ParameterFilter { $Kind -eq 'rollback' -and $HadId -eq "/d/old$Lun" -and $SnapshotId -eq "/s/copy$Lun" } -Times 6 -Exactly
    }

    It 'Format-VmfRollbackLeft: each LUN said as what is on it now' {
        $rows = @(
            [pscustomobject]@{ lun = 0; name = 'old0'; oldDiskId = '/d/old0'; diskId = '/d/new0'; diskName = 'new0'; why = 'OperationNotAllowed: in use' }
            [pscustomobject]@{ lun = 1; name = 'old1'; oldDiskId = '/d/old1'; diskId = '/d/new1'; diskName = 'new1'; why = 'LUN 1 has no disk. The record does not prove it.' }
            [pscustomobject]@{ lun = 2; name = 'old2'; oldDiskId = '/d/old2'; diskId = '/d/new2'; diskName = 'new2'; why = 'x' }
            [pscustomobject]@{ lun = 3; name = 'old3'; oldDiskId = '/d/old3'; diskId = '/d/new3'; diskName = 'new3'; why = 'x' }
            [pscustomobject]@{ lun = 4; name = 'old4'; oldDiskId = '/d/old4'; diskId = '/d/new4'; diskName = 'new4'; why = 'x' })
        $live = @{ 0 = @{ id = '/d/old0'; name = 'old0' }; 3 = @{ id = '/d/new3'; name = 'new3' }; 4 = @{ id = '/d/other'; name = 'other' } }
        $w = InModuleScope VmMigrationFactory -Parameters @{ r = $rows; l = $live } { param($r, $l) Format-VmfRollbackLeft -Swaps $r -Live $l -AzureSaid 'OperationNotAllowed: in use' }
        $w | Should -Match "after 3 tries: LUN 0 keeps 'old0'"
        $w | Should -Match 'LUN 1 has no disk. The record does not prove it.'
        $w | Should -Match "LUN 2 has no disk, and the disk 'new2' made from its copy waits to go on it"
        $w | Should -Match "LUN 3 has the disk 'new3' made from its copy now"
        $w | Should -Match "LUN 4 holds the disk 'other' now"
        $w | Should -Not -Match 'LUN [1-4] keeps'
        $unread = InModuleScope VmMigrationFactory -Parameters @{ r = $rows } { param($r) Format-VmfRollbackLeft -Swaps $r -Live $null }
        $unread | Should -Match 'did not read'
        $unread | Should -Not -Match 'keeps'
    }

    It 'Get-VmfEmptyLunSettings -Rollback: the swap''s own caching first, then the capture''s caching, delete option and Write Accelerator; never a putBackJob' {
        $doc = [pscustomobject]@{
            putBackJob = [pscustomobject]@{ before = [pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 3; caching = 'ReadWrite'; deleteOption = 'Detach'; writeAcceleratorEnabled = $true }) } }
            captured   = [pscustomobject]@{ vmConfig = [pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 3; caching = 'ReadOnly'; deleteOption = 'Delete'; writeAcceleratorEnabled = $true }; [pscustomobject]@{ lun = 5; caching = 'None' }) } } }
        $s = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 3 -Rollback }
        $s.Caching | Should -Be 'ReadOnly'
        $s.DeleteOption | Should -Be 'Delete'
        $s.WriteAccelerator | Should -BeTrue -Because 'the capture holds Write Accelerator on for LUN 3'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 5 -Rollback }).WriteAccelerator | Should -BeFalse -Because 'a capture with no Write Accelerator field names none'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 3 -Rollback -Caching 'None' }).Caching | Should -Be 'None'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 4 -Rollback }) | Should -BeNullOrEmpty
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfEmptyLunSettings -Doc $d -Lun 3 }).Caching | Should -Be 'ReadWrite' -Because 'a restore still reads its own record first'
    }

    It 'Resolve-VmfEmptyDataLun -Kind rollback: the capture''s settings, and the disk reads said as the rollback''s' {
        Mock -ModuleName VmMigrationFactory Invoke-VmfEmptyLunAttach { @{ Outcome = 'want' } }
        $sub = $script:sub
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A'); sub = $sub } {
            param($c, $sub)
            $null = Resolve-VmfEmptyDataLun -Kind 'rollback' -Context $c -VmName 'vm1' -OpName 'rollback:swapDataDisks' -Lun 0 -WantId "$sub/disks/new0" -WantName 'new0' -HadId "$sub/disks/vm1-data0" -HadName 'vm1-data0'
            $null = Resolve-VmfEmptyDataLun -Context $c -VmName 'vm1' -OpName 'restore:swapDataDisks' -Lun 0 -WantId "$sub/disks/new0" -WantName 'new0' -HadId "$sub/disks/vm1-data0" -HadName 'vm1-data0'
        }
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfEmptyLunAttach -ParameterFilter { $ReadOpName -eq 'rollback:readDataDisk' -and $Settings.Caching -eq 'ReadOnly' } -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Invoke-VmfEmptyLunAttach -ParameterFilter { $ReadOpName -eq 'restore:readDataDisk' } -Times 1 -Exactly
    }
    It 'Finish the rollback attaches a disk to an empty LUN with the capture''s settings, never a putBackJob''s' {
        $global:sw.neither = { param($batch) foreach ($s in $batch) { if ([int]$s.lun -eq 1) { $global:sw.luns[1] = [string]$s.diskId } }; $global:sw.luns.Remove(0)
            throw "$($global:sw.neitherWords) The swap took on some LUNs and not others." }
        $global:sw.busy = $true
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $by = if ($global:sw.busy -and $DiskId -like '*-d0-asitwas-*') { "$($script:sub)/virtualMachines/other-vm" } elseif (@($global:sw.luns.Values) -contains $DiskId) { $script:vmId } else { '' }
            [pscustomobject]@{ Exists = $true; ManagedBy = $by; SourceResourceId = [string]$global:sw.sources[$DiskId] }
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SwCtx $script:rp 'A') } {
            param($c)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'CONVERTING' -ReasonCode 'rolledBack' -Detail 'the resize failed'
            Complete-VmfRollback -Context $c | Out-Null
        }
        SwEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName putBackJob -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; ended = '2026-10-20T10:00:00Z'
                    before = [pscustomobject]@{ dataDisks = @([pscustomobject]@{ lun = 0; caching = 'ReadWrite'; deleteOption = 'Detach'; writeAcceleratorEnabled = $true }) } }) -Force
            ($d.captured.vmConfig.dataDisks | Where-Object lun -EQ 0) | Add-Member -NotePropertyName deleteOption -NotePropertyValue 'Delete' -Force }
        $global:sw.busy = $false
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'attach:0:*' }) | Should -Match '/ReadOnly$'
        Should -Invoke -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun -ParameterFilter { $Lun -eq 0 -and $DeleteOption -eq 'Delete' -and -not $WriteAccelerator } -Times 1 -Exactly
        $global:sw.calls[-1] | Should -Be 'start'
    }
}

Describe 'SWAP-REFUSED-AFTER-STOP-1: Restore this machine never starts a machine with disks from two moments' {
    BeforeAll {
        function Global:SwRestoreRun {
            $rp = SwNewRun
            SwEdit $rp { param($d) $d.state = 'MIGRATED' }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id)
                $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                            assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                            target = [ordered]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe'; zone = '2' }; path = 'A'; policy = [ordered]@{} }) }
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
            }
            $rp
        }
    }
    AfterAll { Remove-Item function:SwRestoreRun -ErrorAction SilentlyContinue }
    BeforeEach {
        SwAzure
        $script:rp = SwRestoreRun
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = "$($script:sub)/disks/vm1-osdisk"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'SCSI' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2ds_v4' }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:sw.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $true }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sw -Scope Global -ErrorAction SilentlyContinue }

    It 'new names: refused on every try - the machine stays stopped, the restore record says what came back, and the error names Finish the restore' {
        $global:sw.refuse = @(0, 1)
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.dataCalls | Should -Be 3
        # FINISH-EMPTY-LUN-WORDS-1: refused on every try, so said "after 3 tries".
        $fail = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'fail' })[-1].detail
        $fail | Should -Match "Azure did not swap these data disks back after 3 tries: LUN 0 keeps 'vm1-data0'"
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object { [string]$_.lunHolds }) | Should -Be @('had', 'had')
        $doc.restore.newDiskName | Should -Match 'restored'
        @($doc.restore.dataDisks).Count | Should -Be 0
        $doc.swapPending.kind | Should -Be 'restore'
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        ($doc.swapPending.swaps | Where-Object lun -EQ 0).oldDiskId | Should -Be "$($script:sub)/disks/vm1-data0"
        ($doc.swapPending.swaps | Where-Object lun -EQ 0).diskName | Should -Match '-d0-restored-'
        # FINISH-EMPTY-LUN-PROOF-1: each row names the copy its disk was made from.
        @($doc.swapPending.swaps | ForEach-Object { [string]$_.snapshotId }) | Should -Be @("$($script:sub)/snapshots/vm1-pristine-d0", "$($script:sub)/snapshots/vm1-pristine-d1")
        # The page ends its "putting back" on a fail line of the restore step.
        $ends = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.step -eq 'restore' -and $_.outcome -in @('warn', 'fail', 'ok') })
        $ends.Count | Should -Be 1
        $ends[0].outcome | Should -Be 'fail'
    }

    It 'keeping the names: the LUN whose temporary disk Azure will not swap is left; the other is done, and the machine stays stopped' {
        $global:sw.refuse = @(1)
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*left STOPPED*'
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.calls | Should -Not -Contain 'delete:vm1-data1' -Because 'a disk whose LUN still holds it is never deleted'
        $doc = SwDoc $script:rp
        @($doc.restore.dataDisks | ForEach-Object lun) | Should -Be @(0)
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(1)
        $doc.swapPending.swaps[0].diskName | Should -Match '-d1-rtmp-'
        $doc.swapPending.swaps[0].name | Should -Be 'vm1-data1'
        # FINISH-EMPTY-LUN-PROOF-1: the temporary disk is made from the copy too.
        $doc.swapPending.swaps[0].snapshotId | Should -Be "$($script:sub)/snapshots/vm1-pristine-d1"
    }

    It 'SWAP-PARTIAL-START-1, new names: Azure takes LUN 0 and not LUN 1 of one batch - the machine stays stopped, LUN 1 is left on record, and Finish swaps only it' {
        # The rule: a swap left half done is the same as one refused.
        # It used to record both disks as kept and START the machine, because
        # no LUN was empty.
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.dataCalls++
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            if (@($Swaps).Count -gt 1) {
                $first = @($Swaps)[0]; $global:sw.luns[[int]$first.lun] = [string]$first.diskId
                throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords The swap took on some LUNs and not others." })
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        @($doc.restore.dataDisks | ForEach-Object lun) | Should -Be @(0) -Because 'Azure took LUN 0'
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(1)
        $doc.swapPending.swaps[0].name | Should -Be 'vm1-data1'
        $doc.swapPending.swaps[0].why | Should -Match 'neither swapped nor as they were'
        # FINISH-EMPTY-LUN-WORDS-1: LUN 1 holds the disk it had, and the swap
        # threw, so it is never said "after 3 tries".
        $doc.swapPending.swaps[0].lunHolds | Should -Be 'had'
        $fail = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'fail' })[-1].detail
        $fail | Should -Not -Match 'after 3 tries'
        @($doc.restore.dataDisksKept).Count | Should -Be 0
        # Finish: a second run of the swap, for LUN 1 alone, then the start.
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:1')
        $global:sw.calls[-1] | Should -Be 'start'
        @((SwDoc $script:rp).restore.dataDisks | ForEach-Object lun) | Should -Be @(0, 1)
    }

    It 'RESTORE-EMPTY-LUN-1 (was SWAP-PARTIAL-START-1): a half-done swap that left a LUN with NO disk - the restore attaches the disk made from its copy to it, and Finish swaps the LUN that kept its disk' {
        # It used to stop with "attach each disk to its LUN": a step in Azure,
        # outside the app.
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            if ($global:sw.dataCalls++ -eq 0) {
                $global:sw.luns.Remove(1)
                throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 1: NO DISK." })
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'attach:1:*' }).Count | Should -Be 1
        $global:sw.luns[1] | Should -BeLike '*vm1-data1-d1-restored-*'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0) -Because 'LUN 1 holds its disk from the copy; LUN 0 kept the disk it had'
        @($doc.swapPending.swapped | ForEach-Object { [int]$_.lun }) | Should -Be @(1)
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:0')
        $global:sw.calls[-1] | Should -Be 'start'
        @((SwDoc $script:rp).restore.dataDisks | ForEach-Object lun) | Should -Be @(0, 1)
    }
    It 'RESTORE-EMPTY-LUN-1, keeping the names: Azure fails between the two updates of the swap <Which> - the restore attaches <Disk> to the empty LUN and goes on, and the machine starts with every disk from the copy' -ForEach @(
        @{ Which = 'onto the temporary disk'; Disk = 'the temporary disk'; Temp = $true; Attached = 'attach:0:vm1-data0-d0-rtmp-*/ReadOnly' }
        @{ Which = 'onto the disk under the old name'; Disk = 'the disk under the old name'; Temp = $false; Attached = 'attach:0:vm1-data0/ReadOnly' }) {
        $global:sw.failTemp = $Temp
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            $first = @($Swaps)[0]
            $isTemp = [string]$first.diskName -like '*-rtmp-*'
            if ([int]$first.lun -eq 0 -and $isTemp -eq $global:sw.failTemp -and -not $global:sw.failed) {
                $global:sw.failed = $true
                $global:sw.luns.Remove(0)
                throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 0: NO DISK." })
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null | Out-Null
        @($global:sw.calls | Where-Object { $_ -like $Attached }).Count | Should -Be 1
        $global:sw.calls[-1] | Should -Be 'start'
        $global:sw.luns[0] | Should -Be "$($script:sub)/disks/vm1-data0"
        $doc = SwDoc $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($doc.restore.dataDisks | ForEach-Object lun) | Should -Be @(0, 1)
    }
    It 'FINISH-EMPTY-LUN-PROOF-1, keeping the names: the swap onto the disk under the old name leaves LUN 0 with no disk and Azure refuses both disks - the row names the copy the disk under the old name was made from' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            $first = @($Swaps)[0]
            if ([int]$first.lun -eq 0 -and [string]$first.diskName -notlike '*-rtmp-*' -and -not $global:sw.failed) {
                $global:sw.failed = $true
                $global:sw.luns.Remove(0)
                throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 0: NO DISK." })
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        $global:sw.refuseAttach = 99
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*left STOPPED*'
        $global:sw.calls | Should -Not -Contain 'start'
        $row = @((SwDoc $script:rp).swapPending.swaps | Where-Object { [int]$_.lun -eq 0 })
        $row.Count | Should -Be 1
        $row[0].diskName | Should -Be 'vm1-data0'
        $row[0].snapshotId | Should -Be "$($script:sub)/snapshots/vm1-pristine-d0"
    }
    It 'RESTORE-EMPTY-LUN-1: a LUN left with no disk, and the first write of the record fails - the words still say the LUN has no disk, never a disk it keeps' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            $global:sw.luns.Remove(1)
            throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 1: NO DISK." })
        }
        # Both attaches refused on every try: LUN 1 stays empty, on record.
        $global:sw.refuseAttach = 6
        $global:sw.recordWrites = 0
        Mock -ModuleName VmMigrationFactory Set-VmfSwapPending -ParameterFilter { $null -ne $Record -and (++$global:sw.recordWrites) -eq 1 } { throw 'The store did not answer.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_.Exception.Message }
        $err | Should -Match 'left STOPPED'
        $err | Should -Match "LUN 1 has no disk, and the disk 'vm1-data1-d1-restored-\d+' made from its copy waits to go on it"
        $err | Should -Not -Match 'LUN 1 keeps'
        $global:sw.calls | Should -Not -Contain 'start'
    }
    It 'RESTORE-EMPTY-LUN-1: a half-done swap, and Azure refuses the disk made from the copy on the empty LUN - the disk it had goes back on it, and the machine stays stopped for Finish' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            $global:sw.luns.Remove(1)
            throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 1: NO DISK." })
        }
        $global:sw.refuseAttach = 3
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.luns[1] | Should -Be "$($script:sub)/disks/vm1-data1" -Because 'the disk the LUN had is back on it'
        @((SwDoc $script:rp).swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
    }

    # RESUME-ATTACH-UNKNOWN-WORDS-1: the attach to the empty LUN stops with an
    # error that is not a refusal. Which disk is on the LUN is not known, so
    # the restore never says "LUN 1 has no disk" or "LUN 1 keeps" from that
    # attach: its step line says the attach's own sentence, and the sentence
    # it ends on says the LUN as not read - or as no disk only when its own
    # read after the attach finds no disk there.
    It 'RESUME-ATTACH-UNKNOWN-WORDS-1, new names: a half-done swap leaves LUN 1 with no disk, and the attach stops with an error that is not a refusal (<Case>) - never "LUN 1 has no disk" from the attach, never "LUN 1 keeps", and the machine stays stopped' -ForEach @(
        @{ Case = 'the disk went on before the error'; Landed = $true }
        @{ Case = 'the LUN still has no disk'; Landed = $false }) {
        $global:sw.landed = $Landed
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            if ($global:sw.dataCalls++ -eq 0) {
                $global:sw.luns.Remove(1)
                throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 1: NO DISK." })
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:sw.calls.Add("attach:${Lun}:$(($DiskId -split '/')[-1])")
            if ($global:sw.landed) { $global:sw.luns[[int]$Lun] = $DiskId }
            throw 'Machine vm1 could not be read'
        }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_.Exception.Message }
        $err | Should -Match 'left STOPPED'
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' }).Count | Should -Be 1 -Because 'asked once, and the disk LUN 1 had is not attached'
        $events = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'restore' })
        $step = @($events | Where-Object { [string]$_.detail -like '*took on some LUNs and not others*' })
        $step.Count | Should -Be 1
        $step[0].detail | Should -Match 'stopped with an error that is not a refusal from Azure: Machine vm1 could not be read'
        $step[0].detail | Should -Match 'The product does not know which disk is on LUN 1 now'
        $step[0].detail | Should -Not -Match 'LUN 1 has no disk' -Because 'the attach gave no answer'
        $step[0].detail | Should -Not -Match 'LUN 1 keeps'
        $step[0].detail | Should -Match "LUN 0 keeps 'vm1-data0'" -Because 'LUN 0 was read on the disk it had'
        $err | Should -Not -Match 'LUN 1 keeps'
        if ($Landed) {
            $err | Should -Not -Match 'LUN 1 has no disk' -Because 'LUN 1 holds a disk'
            $err | Should -Match 'did not read which disk is on these LUNs after it: LUN 1,'
        }
        else { $err | Should -Match "LUN 1 has no disk, and the disk 'vm1-data1-d1-restored-\d+' made from its copy waits to go on it" -Because 'the restore read LUN 1 after the attach and found no disk' }
        $row = @((SwDoc $script:rp).swapPending.swaps | Where-Object { [int]$_.lun -eq 1 })
        $row.Count | Should -Be 1
        $row[0].lunHolds | Should -Be 'notRead'
    }
    It 'RESUME-ATTACH-UNKNOWN-WORDS-1, keeping the names: the swap <Which> leaves LUN 0 with no disk, and the attach puts the disk on and stops with an error that is not a refusal - the restore never ends on "LUN 0 keeps" or "LUN 0 has no disk"' -ForEach @(
        @{ Which = 'onto the temporary disk'; Temp = $true }
        @{ Which = 'onto the disk under the old name'; Temp = $false }) {
        $global:sw.failTemp = $Temp
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:sw.calls.Add("data:$(@($Swaps | ForEach-Object { [int]$_.lun }) -join ',')")
            $first = @($Swaps)[0]
            $isTemp = [string]$first.diskName -like '*-rtmp-*'
            if ([int]$first.lun -eq 0 -and $isTemp -eq $global:sw.failTemp -and -not $global:sw.failed) {
                $global:sw.failed = $true
                $global:sw.luns.Remove(0)
                throw (InModuleScope VmMigrationFactory { "$script:VmfSwapNeitherWords LUN 0: NO DISK." })
            }
            foreach ($s in $Swaps) { $global:sw.luns[[int]$s.lun] = [string]$s.diskId }
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:sw.calls.Add("attach:${Lun}:$(($DiskId -split '/')[-1])")
            $global:sw.luns[[int]$Lun] = $DiskId
            throw 'Machine vm1 could not be read'
        }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } catch { $err = $_.Exception.Message }
        $err | Should -Match 'left STOPPED'
        $global:sw.calls | Should -Not -Contain 'start'
        $err | Should -Not -Match 'LUN 0 keeps'
        $err | Should -Not -Match 'LUN 0 has no disk'
        $err | Should -Match 'did not read which disk is on these LUNs after it: LUN 0,'
        $step = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'restore' -and [string]$_.detail -like '*not a refusal from Azure*' })
        $step.Count | Should -BeGreaterThan 0
        @($step | Where-Object { [string]$_.detail -match 'LUN 0 has no disk' }) | Should -BeNullOrEmpty
        (@((SwDoc $script:rp).swapPending.swaps | Where-Object { [int]$_.lun -eq 0 }))[0].lunHolds | Should -Be 'notRead'
    }

    It 'review MUST FIX 1: after a refused swap, a read of the data disks that fails never starts the machine, and the record is written' {
        # The restore's catch started the machine when it could not see an
        # empty LUN, and swapPending was written only after the try.
        $global:sw.refuse = @(0, 1)
        $global:sw.infoReads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            $global:sw.infoReads++
            if ($global:sw.infoReads -gt 1) {
                # The swap is on record before this read, which can fail.
                $global:sw.onRecordFirst = [bool]((Get-ChildItem (Join-Path $script:rp 'state') -Filter '*.json' | Get-Content -Raw) -match '"swapPending"')
                throw 'ResourceNotFound: the read failed'
            }
            @($global:sw.luns.Keys | Sort-Object | ForEach-Object {
                    $id = [string]$global:sw.luns[$_]
                    [pscustomobject]@{ lun = [int]$_; id = $id; name = ($id -split '/')[-1]; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' } })
        }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        $doc.restore | Should -Not -BeNullOrEmpty -Because 'Finish the restore adds its disks to the record'
        $global:sw.onRecordFirst | Should -BeTrue -Because 'the swap is on record before any call after the data restore that can fail'
    }

    It 're-review 1: the data restore throws part way, after a LUN was left - never started, and every LUN not proven on its copy is on record' {
        # Keeping the names: LUN 0 refused, and the product fails before LUN 1
        # is tried. LUN 1 still holds the disk it had: also not back.
        $global:sw.refuse = @(0)
        $global:sw.rowCalls = 0
        # The first two rows are the LUNs waiting; the third is the refused LUN 0.
        Mock -ModuleName VmMigrationFactory New-VmfSwapLeftRow -ParameterFilter { (++$global:sw.rowCalls) -eq 3 } { throw 'a defect in the middle of the data restore' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        @($doc.swapPending.swaps | Where-Object { -not $_.temporary }) | Should -BeNullOrEmpty
        ($doc.swapPending.swaps | Where-Object lun -EQ 1).oldDiskId | Should -Be "$($script:sub)/disks/vm1-data1"
        # FINISH-EMPTY-LUN-PROOF-1: a LUN not proven on its copy names the copy too.
        @($doc.swapPending.swaps | ForEach-Object { [string]$_.snapshotId }) | Should -Be @("$($script:sub)/snapshots/vm1-pristine-d0", "$($script:sub)/snapshots/vm1-pristine-d1")
    }
    It 'FINISH-EMPTY-LUN-WORDS-1, new names: the data restore throws before any LUN is left - each LUN waiting is on record as not read' {
        $global:sw.refuse = @(0, 1)
        $global:sw.rowCalls = 0
        # The first two rows are the LUNs waiting; the third is the refused LUN 0.
        Mock -ModuleName VmMigrationFactory New-VmfSwapLeftRow -ParameterFilter { (++$global:sw.rowCalls) -eq 3 } { throw 'a defect in the middle of the data restore' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw -ExpectedMessage '*left STOPPED*'
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        @($doc.swapPending.swaps | ForEach-Object { [string]$_.lunHolds }) | Should -Be @('notRead', 'notRead')
    }
    It 'review note b: a read of the size after a refused swap that fails leaves the swap on record' {
        $global:sw.refuse = @(0, 1)
        $global:sw.sizeReads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:sw.sizeReads++; if ($global:sw.sizeReads -gt 1) { throw 'ResourceNotFound: no size' }; 'Standard_D2ds_v4' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw
        $global:sw.calls | Should -Not -Contain 'start'
        @((SwDoc $script:rp).swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        (SwDoc $script:rp).restore | Should -Not -BeNullOrEmpty -Because 'the restore record is written with the size unknown'
    }

    It 'FINISH-KEPT-DISKS-1: the record of the waiting swap names each data disk the restore keeps as it is, in the same write' {
        # LUN 1 is a shared disk: the restore keeps it as it is, by design.
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ([string]$DiskId -like '*/vm1-data1') { 2 } else { 1 } }
        $global:sw.refuse = @(0)
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
        @($doc.swapPending.kept | ForEach-Object lun) | Should -Be @(1)
        $doc.swapPending.kept[0].name | Should -Be 'vm1-data1'
        $doc.swapPending.kept[0].why | Should -Match 'shared disk'
        @($doc.restore.dataDisksKept | ForEach-Object lun) | Should -Be @(1)
    }
    It 'FINISH-KEPT-DISKS-1: the data restore throws part way with a shared disk kept - the restore record and the swap record both name the kept disk, and Finish the restore ends it' {
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ([string]$DiskId -like '*/vm1-data1') { 2 } else { 1 } }
        $global:sw.refuse = @(0)
        $global:sw.rowCalls = 0
        # New names: the first row is LUN 0 waiting; the second is LUN 0 refused.
        Mock -ModuleName VmMigrationFactory New-VmfSwapLeftRow -ParameterFilter { (++$global:sw.rowCalls) -eq 2 } { throw 'a defect in the middle of the data restore' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0)
        @($doc.swapPending.kept | ForEach-Object lun) | Should -Be @(1)
        @($doc.restore.dataDisksKept | ForEach-Object lun) | Should -Be @(1) -Because 'the data restore gave no result, and the disks it keeps by design are known from its plan'
        # POWER-AFTER-MOVE-1: the record of the swap keeps the power state the
        # restore found when it started, for Finish the restore.
        $doc.swapPending.powerAtStart | Should -Be 'PowerState/running'
        $global:sw.refuse = @()
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:0')
        $global:sw.calls[-1] | Should -Be 'start'
        $global:sw.luns[1] | Should -Be "$($script:sub)/disks/vm1-data1" -Because 'a kept disk is never touched'
    }

    It 'a restore is refused while a swap is left: Finish the rollback comes first' {
        SwEdit $script:rp { param($d) $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kind = 'rollback'; swaps = @([pscustomobject]@{ lun = 1 }) }) -Force }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw -ExpectedMessage '*Finish the rollback*'
        $global:sw.calls | Should -Not -Contain 'stop'
    }
}

Describe 'SWAP-REFUSED-AFTER-STOP-1: Finish the rollback / Finish the restore (Complete-VmfDataDiskSwap)' {
    BeforeAll {
        # A machine a rollback left stopped: its OS disk and LUN 0 back from
        # the copy, LUN 1 (plain) and LUN 2 (Premium SSD v2) not.
        function Global:SwLeftRun([string]$Kind = 'rollback') {
            $rp = SwNewRun
            SwEdit $rp {
                param($d)
                $d.state = 'FAILED_NEEDS_ATTENTION'
                $d.history = @($d.history) + @([pscustomobject]@{ tsUtc = (Get-Date).ToUniversalTime().ToString('o'); state = 'FAILED_NEEDS_ATTENTION'; outcome = 'fail'; reasonCode = 'dataDiskSwapRefused'; machineState = 'changed'; detail = 'left' })
                $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
                $d | Add-Member -NotePropertyName rollback -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-10-23T10:00:00Z'; path = 'A'
                        osDisk = [pscustomobject]@{ id = "$sub/disks/vm1-osdisk-asitwas-x"; name = 'vm1-osdisk-asitwas-x' }
                        dataDisks = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0-d0-asitwas-x"; diskName = 'vm1-data0-d0-asitwas-x' }); keptDataDisks = @() }) -Force
                $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @();
                        kind = $Kind; leftUtc = '2026-10-23T10:00:00Z'; error = 'OperationNotAllowed: the disk is in use'; usedBy = 'rollback-x'
                        swaps = @(
                            [pscustomobject]@{ lun = 1; name = 'vm1-data1'; oldDiskId = "$sub/disks/vm1-data1"; diskId = "$sub/disks/vm1-data1-d1-asitwas-x"; diskName = 'vm1-data1-d1-asitwas-x'; caching = $null; instantAccess = $false; snapshotId = "$sub/snapshots/vm1-pristine-d1"; lunHolds = 'had' }
                            [pscustomobject]@{ lun = 2; name = 'vm1-data2'; oldDiskId = "$sub/disks/vm1-data2"; diskId = "$sub/disks/vm1-data2-d2-asitwas-x"; diskName = 'vm1-data2-d2-asitwas-x'; caching = 'None'; instantAccess = $true; snapshotId = "$sub/snapshots/vm1-pristine-d2"; lunHolds = 'had' })
                        swapped = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0-d0-asitwas-x"; diskName = 'vm1-data0-d0-asitwas-x' })
                        stop = [pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; reasonCode = 'rolledBack'; machineState = 'restored'; detail = 'CONVERTING failed; the machine was rolled back to how it was: the resize failed' } }) -Force
                if ($Kind -eq 'restore') {
                    $d.state = 'MIGRATED'
                    $d.history = @($d.history | Select-Object -First 1)
                    $d.swapPending.PSObject.Properties.Remove('stop')
                    $d.swapPending.usedBy = ''
                    # A restore's swap record and its own record name its operation (vm-state v32).
                    $d.swapPending | Add-Member -NotePropertyName operationId -NotePropertyValue 'op-0' -Force
                    $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ operationId = 'op-0'; restoredUtc = '2026-10-23T10:00:00Z'; restoredBy = 'operator@example.com'; fromCopy = 'pristine'
                            newDiskName = 'vm1-osdisk-restored-x'; newDiskId = "$sub/disks/vm1-osdisk-restored-x"; diskNaming = 'new'
                            dataDisks = @([pscustomobject]@{ lun = 0; previousDiskId = "$sub/disks/vm1-data0"; previousDiskName = 'vm1-data0'; newDiskId = "$sub/disks/vm1-data0-d0-asitwas-x"; newDiskName = 'vm1-data0-d0-asitwas-x' })
                            dataDisksKept = @() }) -Force
                }
            }
            # The disks that wait were made from the copies the rows name, as Azure says.
            if ($global:sw) { foreach ($k in 1, 2) { $global:sw.sources["$($script:sub)/disks/vm1-data$k-d$k-asitwas-x"] = "$($script:sub)/snapshots/vm1-pristine-d$k" } }
            $rp
        }
    }
    AfterAll { Remove-Item function:SwLeftRun -ErrorAction SilentlyContinue }
    BeforeEach {
        SwAzure
        $global:sw.luns = @{ 0 = "$($script:sub)/disks/vm1-data0-d0-asitwas-x"; 1 = "$($script:sub)/disks/vm1-data1"; 2 = "$($script:sub)/disks/vm1-data2" }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sw -Scope Global -ErrorAction SilentlyContinue }

    It 'rollback: swaps only the disks left - the plain one first - starts the machine, and records the stop the rollback would have' {
        $script:rp = SwLeftRun
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:1', 'data:2')
        $calls = @($global:sw.calls)
        [array]::IndexOf($calls, 'stop') | Should -BeLessThan ([array]::IndexOf($calls, 'data:1')) -Because 'the swaps run on a stopped machine'
        $calls[-1] | Should -Be 'start'
        $doc = SwDoc $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $last = @($doc.history)[-1]
        $last.reasonCode | Should -Be 'rolledBack'
        $last.machineState | Should -Be 'restored'
        $last.detail | Should -Match 'the resize failed'
        $last.detail | Should -Match 'Finish the rollback'
        @($doc.rollback.dataDisks | ForEach-Object lun) | Should -Be @(0, 1, 2)
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
    }

    It 'restore: swaps the disks left, starts the machine, and adds each to the restore record' {
        $script:rp = SwLeftRun -Kind 'restore'
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.calls[-1] | Should -Be 'start'
        $doc = SwDoc $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        $doc.state | Should -Be 'MIGRATED'
        @($doc.restore.dataDisks | ForEach-Object lun) | Should -Be @(0, 1, 2)
        ($doc.restore.dataDisks | Where-Object lun -EQ 1).previousDiskName | Should -Be 'vm1-data1'
        ($doc.restore.dataDisks | Where-Object lun -EQ 1).newDiskName | Should -Be 'vm1-data1-d1-asitwas-x'
        # Its own step, which opens and ends the page's "finishing" as a
        # restore's step does.
        $ends = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'finish' })
        $ends[0].outcome | Should -Be 'start'
        $ends[-1].outcome | Should -Be 'ok'
        @($ends | Where-Object { $_.outcome -in @('ok', 'warn', 'fail') }).Count | Should -Be 1
    }

    # POWER-AFTER-MOVE-1 (2026-11-06: the original power state, on or off, is
    # kept when the work is done): Finish starts the machine; one that
    # Checking found Stopped (deallocated) goes back to it.
    # The rollback keeps the power state Checking found (the record of the
    # move); the restore keeps the one it found when it started
    # (swapPending.powerAtStart) - POWER-FOUND-AGE-1, folded in.
    It 'POWER-AFTER-MOVE-1, <Kind>: a machine that was Stopped (deallocated) is started, then deallocated again, and the record says so' -ForEach @(
        @{ Kind = 'rollback' }, @{ Kind = 'restore' }) {
        $script:rp = SwLeftRun -Kind $Kind
        if ($Kind -eq 'rollback') { SwEdit $script:rp { param($d) $d.captured | Add-Member -NotePropertyName clusterCheckPower -Force -NotePropertyValue ([pscustomobject]@{ power = 'PowerState/deallocated'; status = 'goingOn'; tsUtc = '2026-10-23T09:00:00Z' }) } }
        else { SwEdit $script:rp { param($d) $d.swapPending | Add-Member -NotePropertyName powerAtStart -Force -NotePropertyValue 'PowerState/deallocated' } }
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls)[-2..-1] | Should -Be @('start', 'stop') -Because "the return comes after the start (calls: $($global:sw.calls -join ', '))"
        $doc = SwDoc $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -BeNullOrEmpty
        if ($Kind -eq 'rollback') {
            $last = @($doc.history)[-1]
            $last.state | Should -Be 'FAILED_ROLLED_BACK'
            $last.machineState | Should -Be 'restored'
            $last.detail | Should -Match 'The product deallocated the machine again, as it was before the move'
        }
        (SwLog $script:rp) | Should -Match "The product deallocated the machine again, as it was before the $(if ($Kind -eq 'rollback') { 'move' } else { 'restore' })"
    }

    It 'POWER-AFTER-MOVE-1, <Kind>: a return Azure refuses at every try is owed - changed, with Stopped (deallocated)' -ForEach @(
        @{ Kind = 'rollback' }, @{ Kind = 'restore' }) {
        $script:rp = SwLeftRun -Kind $Kind
        if ($Kind -eq 'rollback') { SwEdit $script:rp { param($d) $d.captured | Add-Member -NotePropertyName clusterCheckPower -Force -NotePropertyValue ([pscustomobject]@{ power = 'PowerState/deallocated'; status = 'goingOn'; tsUtc = '2026-10-23T09:00:00Z' }) } }
        else { SwEdit $script:rp { param($d) $d.swapPending | Add-Member -NotePropertyName powerAtStart -Force -NotePropertyValue 'PowerState/deallocated' } }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { if (@($global:sw.calls) -contains 'start') { throw 'OperationNotAllowed: the machine is busy.' }; $global:sw.calls.Add('stop') }
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $doc = SwDoc $script:rp
        $last = @($doc.history)[-1]
        $last.machineState | Should -Be 'changed'
        $last.powerNotPutBack | Should -Be 'PowerState/deallocated'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfPowerOwed -Doc $d }) | Should -Be 'PowerState/deallocated'
        (InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Test-VmfRetryHeld -Doc $d }) | Should -BeFalse
    }

    It 'POWER-AFTER-MOVE-1: Finish the restore of a machine that was running when the restore started stays running - also when Checking found it deallocated at the move' {
        $script:rp = SwLeftRun -Kind 'restore'
        SwEdit $script:rp { param($d)
            $d.captured | Add-Member -NotePropertyName clusterCheckPower -Force -NotePropertyValue ([pscustomobject]@{ power = 'PowerState/deallocated'; status = 'goingOn'; tsUtc = '2026-10-23T09:00:00Z' })
            $d.swapPending | Add-Member -NotePropertyName powerAtStart -Force -NotePropertyValue 'PowerState/running' }
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.calls[-1] | Should -Be 'start'
    }

    It 'POWER-AFTER-MOVE-1: a restore that leaves a swap keeps the power state it found when it started on the record of the swap' {
        $rec = InModuleScope VmMigrationFactory { New-VmfSwapPendingRecord -Kind 'restore' -Swaps @() -Reason 'e' -PowerAtStart 'PowerState/stopped' }
        $rec['powerAtStart'] | Should -Be 'PowerState/stopped'
        (InModuleScope VmMigrationFactory { New-VmfSwapPendingRecord -Kind 'rollback' -Swaps @() -Reason 'e' }).Contains('powerAtStart') | Should -BeFalse
    }

    It 'POWER-AFTER-MOVE-1: a machine found running (no record) is started and stays running, as before' {
        $script:rp = SwLeftRun
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.calls[-1] | Should -Be 'start'
    }

    It 'still refused: the machine stays stopped, and the record keeps each disk left with Azure''s new words' {
        $script:rp = SwLeftRun
        $global:sw.refuse = @(2)
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage "*LUN 2 keeps 'vm1-data2'*stays stopped*Finish the rollback*"
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(2) -Because 'LUN 1 went back and is on record'
        @($doc.swapPending.swapped | ForEach-Object lun) | Should -Be @(0, 1)
        $doc.swapPending.error | Should -Be 'OperationNotAllowed: the disk is in use'
        @($doc.rollback.dataDisks | ForEach-Object lun) | Should -Be @(0, 1)
    }

    It 'kill and resume: a finish that stops after the first batch swaps only the other when it runs again' {
        $script:rp = SwLeftRun
        $global:sw.throwOn = @(2)
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } | Should -Throw
        @((SwDoc $script:rp).swapPending.swaps | ForEach-Object lun) | Should -Be @(2) -Because 'the first batch is on record the moment it took'
        $global:sw.throwOn = $null
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:2')
        $global:sw.calls[-1] | Should -Be 'start'
        (SwDoc $script:rp).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'kill and resume: a LUN Azure swapped before the record was written is not swapped again' {
        $script:rp = SwLeftRun
        # Azure took LUN 1 and the process stopped before the record said so.
        $global:sw.luns[1] = "$($script:sub)/disks/vm1-data1-d1-asitwas-x"
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:2')
        @((SwDoc $script:rp).rollback.dataDisks | ForEach-Object lun) | Should -Be @(0, 1, 2)
    }

    It 'kill and resume: every swap done and the start not - a second run only starts the machine' {
        $script:rp = SwLeftRun
        $global:sw.startThrows = 1
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } | Should -Throw
        $doc = SwDoc $script:rp
        @($doc.swapPending.swaps).Count | Should -Be 0
        $doc.state | Should -Be 'FAILED_NEEDS_ATTENTION' -Because 'the machine is not running yet'
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -BeNullOrEmpty
        $global:sw.calls[-1] | Should -Be 'start'
        (SwDoc $script:rp).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'a LUN that holds a disk the record does not name: refused before anything changes' {
        $script:rp = SwLeftRun
        $global:sw.luns[1] = "$($script:sub)/disks/somebody-else"
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage "*LUN 1*somebody-else*"
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -BeNullOrEmpty
        $global:sw.calls | Should -Not -Contain 'start'
    }

    It 'review note c: a row that does not name the disk the LUN had is refused, whatever disk is on the LUN' {
        $script:rp = SwLeftRun
        SwEdit $script:rp { param($d) $d.swapPending.swaps[0].oldDiskId = $null }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*LUN 1*'
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -BeNullOrEmpty
    }
    It 're-check: a record that does not account for every data disk of the machine is refused - Finish never starts on it' {
        $script:rp = SwLeftRun
        # LUN 1 is in no list: not swapped back, not waiting, not kept.
        SwEdit $script:rp { param($d) $d.swapPending.swaps = @($d.swapPending.swaps | Where-Object { [int]$_.lun -ne 1 }) }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*LUN 1*'
        $global:sw.calls | Should -Not -Contain 'start'
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -BeNullOrEmpty
    }
    It 'FINISH-KEPT-DISKS-1, <Kind>: a disk the record of the waiting swap names as kept is accounted for, with no kept list on the <Kind> record - Finish swaps the rest and starts the machine' -ForEach @(
        @{ Kind = 'restore' }, @{ Kind = 'rollback' }) {
        $script:rp = SwLeftRun -Kind $Kind
        # LUN 1 is kept as it is by design. The swap record says so; the
        # rollback's or the restore's own record is not written.
        SwEdit $script:rp {
            param($d)
            $d.swapPending.swaps = @($d.swapPending.swaps | Where-Object { [int]$_.lun -ne 1 })
            $d.swapPending | Add-Member -NotePropertyName kept -NotePropertyValue @([pscustomobject]@{ lun = 1; name = 'vm1-data1'; why = 'It is a shared disk (maxShares 2), and other machines can use it.' }) -Force
            foreach ($f in 'restore', 'rollback') { if ($d.PSObject.Properties[$f]) { $d.PSObject.Properties.Remove($f) } }
        }
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:2')
        $global:sw.calls[-1] | Should -Be 'start'
        $global:sw.luns[1] | Should -Be "$($script:sub)/disks/vm1-data1"
        (SwDoc $script:rp).PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
    }
    It 'FINISH-KEPT-DISKS-1: a kept list on the record of the waiting swap accounts only for the LUNs it names - another LUN in no list is still refused' {
        $script:rp = SwLeftRun -Kind 'restore'
        SwEdit $script:rp {
            param($d)
            $d.swapPending.swaps = @($d.swapPending.swaps | Where-Object { [int]$_.lun -ne 1 })
            $d.swapPending | Add-Member -NotePropertyName kept -NotePropertyValue @([pscustomobject]@{ lun = 7; name = 'vm1-data7'; why = 'No copy of it is on record.' }) -Force
        }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage "*LUN 1 'vm1-data1'*"
        $global:sw.calls | Should -Not -Contain 'start'
    }
    It 'a rollback whose own stop is not recorded yet is still its wave worker''s: refused, and nothing is touched' {
        $script:rp = SwLeftRun
        SwEdit $script:rp { param($d) $d.swapPending.PSObject.Properties.Remove('stop') }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*has not recorded its stop yet*'
        $global:sw.calls.Count | Should -Be 0
    }

    It 'RESTORE-EMPTY-LUN-1, <Kind>: a LUN with no disk that the record names - Finish attaches the disk that waits, with the caching the record holds, on the stopped machine, then starts it' -ForEach @(
        @{ Kind = 'rollback' }, @{ Kind = 'restore' }) {
        $script:rp = SwLeftRun -Kind $Kind
        SwEdit $script:rp { param($d) ($d.captured.vmConfig.dataDisks | Where-Object lun -EQ 1).caching = 'ReadWrite' }
        $global:sw.luns.Remove(1)
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $calls = @($global:sw.calls)
        $calls | Should -Contain 'attach:1:vm1-data1-d1-asitwas-x/ReadWrite'
        [array]::IndexOf($calls, 'stop') | Should -BeLessThan ([array]::IndexOf($calls, 'attach:1:vm1-data1-d1-asitwas-x/ReadWrite'))
        @($calls | Where-Object { $_ -like 'data:*' }) | Should -Be @('data:2')
        $calls[-1] | Should -Be 'start'
        $global:sw.luns[1] | Should -Be "$($script:sub)/disks/vm1-data1-d1-asitwas-x"
        $doc = SwDoc $script:rp
        $doc.PSObject.Properties['swapPending'] | Should -BeNullOrEmpty
        @($doc.$Kind.dataDisks | ForEach-Object { [int]$_.lun }) | Should -Contain 1 -Because 'the disk is on the record the moment Azure took it'
    }
    It 'RESTORE-EMPTY-LUN-1: only a LUN with no disk is left - Finish still stops the machine before it attaches the disk' {
        $script:rp = SwLeftRun -Kind 'restore'
        SwEdit $script:rp { param($d) $d.swapPending.swaps = @($d.swapPending.swaps | Where-Object { [int]$_.lun -eq 1 }) }
        $global:sw.luns.Remove(1)
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $calls = @($global:sw.calls)
        $calls | Should -Contain 'stop'
        [array]::IndexOf($calls, 'stop') | Should -BeLessThan ([array]::IndexOf($calls, 'attach:1:vm1-data1-d1-asitwas-x/None'))
        $calls[-1] | Should -Be 'start'
    }
    It 'RESTORE-EMPTY-LUN-1: Azure refuses the disk that waits on the empty LUN - the disk the LUN had goes back, the machine stays stopped, and the next Finish swaps it' {
        $script:rp = SwLeftRun -Kind 'restore'
        $global:sw.luns.Remove(1)
        $global:sw.refuseAttach = 3
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*LUN 1*stays stopped*Finish the restore*'
        $global:sw.calls | Should -Not -Contain 'start'
        $global:sw.luns[1] | Should -Be "$($script:sub)/disks/vm1-data1" -Because 'the disk the LUN had is back on it'
        @((SwDoc $script:rp).swapPending.swaps | ForEach-Object lun) | Should -Contain 1
        # FINISH-EMPTY-LUN-WORDS-1: the record says LUN 1 has its disk again.
        ((SwDoc $script:rp).swapPending.swaps | Where-Object lun -EQ 1).lunHolds | Should -Be 'had'
        $global:sw.calls.Clear()
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'data:*' }) | Should -Contain 'data:1'
        $global:sw.calls[-1] | Should -Be 'start'
    }
    It 'FINISH-EMPTY-LUN-WORDS-1: Azure refuses the disk that waits on the empty LUN AND the disk it had - the LUN still has no disk, and the record says so' {
        $script:rp = SwLeftRun -Kind 'restore'
        $global:sw.luns.Remove(1)
        $global:sw.refuseAttach = 6
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*LUN 1 has no disk*stays stopped*'
        $global:sw.luns.ContainsKey(1) | Should -BeFalse
        ((SwDoc $script:rp).swapPending.swaps | Where-Object lun -EQ 1).lunHolds | Should -Be 'none'
    }
    It 'FINISH-TEMP-DISK-LEFT-1: keeping the names, LUN 1 runs on its temporary disk and waits for the disk under its old name - Finish puts it on, names the temporary disk that is free, and the daily cleanup may delete it' {
        $script:rp = SwLeftRun -Kind 'restore'
        $tmpId = "$($script:sub)/disks/vm1-data1-d1-rtmp-x"
        SwEdit $script:rp {
            param($d)
            $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
            $d.restore.diskNaming = 'preserve'
            $d.swapPending.swaps = @([pscustomobject]@{ lun = 1; name = 'vm1-data1-d1-rtmp-x'; oldDiskId = "$sub/disks/vm1-data1-d1-rtmp-x"; diskId = "$sub/disks/vm1-data1"; diskName = 'vm1-data1'
                    caching = $null; instantAccess = $false; temporary = $false; oldTemporary = $true; lunHolds = 'notRead'; why = 'the swap did not finish' })
            $d.swapPending.swapped = @(@($d.swapPending.swapped) + @([pscustomobject]@{ lun = 2; diskId = "$sub/disks/vm1-data2"; diskName = 'vm1-data2' }))
            # The restore made the temporary disk, and recorded it the moment Azure made it.
            $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @([pscustomobject]@{ diskId = "$sub/disks/vm1-data1-d1-rtmp-x"; diskName = 'vm1-data1-d1-rtmp-x'; lun = 1; madeUtc = '2026-10-23T09:00:00Z' }) -Force
        }
        $global:sw.luns[1] = $tmpId
        $global:sw.luns[2] = "$($script:sub)/disks/vm1-data2"
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        $global:sw.luns[1] | Should -Be "$($script:sub)/disks/vm1-data1"
        $global:sw.calls[-1] | Should -Be 'start'
        $doc = SwDoc $script:rp
        $row = $doc.restore.dataDisks | Where-Object lun -EQ 1
        $row.previousDiskId | Should -Be "$($script:sub)/disks/vm1-data1" -Because 'keeping the names, the disk LUN 1 had before the restore has the same name and id, as step 6 records it'
        $row.newDiskId | Should -Be "$($script:sub)/disks/vm1-data1"
        $due = @(InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDeletableMadeDisks -StateDoc $d })
        @($due | ForEach-Object { [string]$_.diskId }) | Should -Contain $tmpId -Because 'nothing on the record uses the temporary disk now, so the daily cleanup deletes it once the move has ended'
        $done = (@(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'ok' }))[-1].detail
        $done | Should -Match "The temporary disk 'vm1-data1-d1-rtmp-x' that LUN 1 ran on is not attached\. It costs money until it is deleted\. The daily cleanup deletes it when the move of this machine has ended\."
    }
    It 'RESTORE-EMPTY-LUN-1: the disk that waits for the empty LUN is attached to another machine - refused before anything changes' {
        $script:rp = SwLeftRun -Kind 'restore'
        $global:sw.luns.Remove(1)
        $global:sw.elsewhere = @("$($script:sub)/disks/vm1-data1-d1-asitwas-x")
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage "*LUN 1 has no disk*vm1-data1-d1-asitwas-x*other-vm*"
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' -or $_ -like 'data:*' -or $_ -eq 'stop' -or $_ -eq 'start' }) | Should -BeNullOrEmpty
    }

    # FINISH-EMPTY-LUN-PROOF-1: Finish gives a disk that waits for an empty LUN
    # the proof the restore's resume gives it - it exists, no machine holds it,
    # and Azure says it was made from the copy the record names (vm-state v28,
    # swapPending.swaps[].snapshotId).
    It 'FINISH-EMPTY-LUN-PROOF-1, <Kind>: the disk that waits for an empty LUN was made from another copy - refused before anything changes, and the machine stays stopped' -ForEach @(
        @{ Kind = 'rollback'; State = 'FAILED_NEEDS_ATTENTION' }, @{ Kind = 'restore'; State = 'MIGRATED' }) {
        $script:rp = SwLeftRun -Kind $Kind
        SwEdit $script:rp { param($d) ($d.swapPending.swaps | Where-Object lun -EQ 1) | Add-Member -NotePropertyName snapshotId -NotePropertyValue '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine-d1' -Force }
        $global:sw.luns.Remove(1)
        $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/another-copy"
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage "*LUN 1 has no disk*vm1-data1-d1-asitwas-x*another-copy*vm1-pristine-d1*The machine is as it was before*"
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' -or $_ -like 'data:*' -or $_ -eq 'stop' -or $_ -eq 'start' }) | Should -BeNullOrEmpty
        $global:sw.luns.ContainsKey(1) | Should -BeFalse -Because 'nothing is attached to the empty LUN'
        $doc = SwDoc $script:rp
        $doc.state | Should -Be $State
        $row = @($doc.swapPending.swaps | Where-Object { [int]$_.lun -eq 1 })
        $row.Count | Should -Be 1 -Because 'the LUN stays on record'
        $row[0].diskId | Should -Be "$($script:sub)/disks/vm1-data1-d1-asitwas-x"
    }
    It 'FINISH-EMPTY-LUN-PROOF-1, <Kind>: the disk that waits was made from the copy the record names - Finish attaches it, then starts the machine' -ForEach @(
        @{ Kind = 'rollback' }, @{ Kind = 'restore' }) {
        $script:rp = SwLeftRun -Kind $Kind
        SwEdit $script:rp { param($d) ($d.swapPending.swaps | Where-Object lun -EQ 1) | Add-Member -NotePropertyName snapshotId -NotePropertyValue '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine-d1' -Force }
        $global:sw.luns.Remove(1)
        $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/VM1-PRISTINE-D1"
        Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false | Out-Null
        @($global:sw.calls | Where-Object { $_ -like 'attach:1:vm1-data1-d1-asitwas-x/*' }).Count | Should -Be 1
        $global:sw.calls[-1] | Should -Be 'start'
        SwLog $script:rp | Should -Not -Match 'does not name the copy' -Because 'a record that names the copy needs no note'
    }
    It 'FINISH-EMPTY-LUN-PROOF-1: the disk changes after the check and before the attach - the attach asks again, attaches nothing, and the machine stays stopped' {
        $script:rp = SwLeftRun -Kind 'restore'
        SwEdit $script:rp { param($d) ($d.swapPending.swaps | Where-Object lun -EQ 1) | Add-Member -NotePropertyName snapshotId -NotePropertyValue '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine-d1' -Force }
        $global:sw.luns.Remove(1)
        $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/vm1-pristine-d1"
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            $global:sw.calls.Add('stop')
            $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/another-copy"
        }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*LUN 1*another-copy*stays stopped*'
        # FINISH-EMPTY-LUN-WORDS-1: Azure was not asked for LUN 1, so the error
        # never says Azure did not swap it, nor that it was tried 3 times.
        $err = (@(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'fail' }))[-1].detail
        $err | Should -Match "LUN 1 has no disk\. The disk 'vm1-data1-d1-asitwas-x' was made from"
        $err | Should -Not -Match 'Azure did not swap'
        $err | Should -Not -Match 'after 3 tries'
        $err | Should -Match 'The machine stays stopped'
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' }) | Should -BeNullOrEmpty
        ((SwDoc $script:rp).swapPending.swaps | Where-Object lun -EQ 1).lunHolds | Should -Be 'none'
        $global:sw.calls | Should -Not -Contain 'start'
        @((SwDoc $script:rp).swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Contain 1
    }
    # FINISH-ATTACH-UNKNOWN-WORDS-1: the attach to an empty LUN stops with an
    # error that is not a refusal (here, the machine could not be read). Azure
    # did not refuse the disk, and it was not asked 3 times, so the error never
    # says so. Where the LUN stands is not known: the row says notRead, never
    # "no disk", and the next Finish reads the LUN before it changes anything.
    It 'FINISH-ATTACH-UNKNOWN-WORDS-1, <Kind>: the attach to an empty LUN stops with an error that is not a refusal - the error says it in its own words, never "after 3 tries", and the machine stays stopped' -ForEach @(
        @{ Kind = 'rollback'; State = 'FAILED_NEEDS_ATTENTION' }, @{ Kind = 'restore'; State = 'MIGRATED' }) {
        $script:rp = SwLeftRun -Kind $Kind
        SwEdit $script:rp { param($d) ($d.swapPending.swaps | Where-Object lun -EQ 1) | Add-Member -NotePropertyName snapshotId -NotePropertyValue '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine-d1' -Force }
        $global:sw.luns.Remove(1)
        $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/vm1-pristine-d1"
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun {
            $global:sw.calls.Add("attach:${Lun}:$(($DiskId -split '/')[-1])")
            throw 'Machine vm1 could not be read'
        }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*stays stopped*'
        $err = (@(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'fail' }))[-1].detail
        $err | Should -Match "The attach of the disk 'vm1-data1-d1-asitwas-x' made from its copy to LUN 1 stopped with an error that is not a refusal from Azure: Machine vm1 could not be read\."
        $err | Should -Match 'The product does not know which disk is on LUN 1 now\.'
        $err | Should -Match "So it did not attach the disk 'vm1-data1' that LUN 1 had\."
        $err | Should -Not -Match 'after 3 tries'
        $err | Should -Not -Match 'Azure did not swap'
        $err | Should -Not -Match 'LUN 1 has no disk' -Because 'where the LUN stands is not known'
        $err | Should -Match 'The machine stays stopped'
        $err | Should -Match "two moments\. Use Finish the $Kind again\. It reads each LUN before it changes the machine\.$"
        $err | Should -Not -Match 'when Azure accepts the swap' -Because 'Azure refused nothing'
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' }) | Should -Be @('attach:1:vm1-data1-d1-asitwas-x') -Because 'asked once, and the disk the LUN had is not attached'
        $global:sw.calls | Should -Not -Contain 'start'
        $doc = SwDoc $script:rp
        $doc.state | Should -Be $State
        $row = @($doc.swapPending.swaps | Where-Object { [int]$_.lun -eq 1 })
        $row.Count | Should -Be 1 -Because 'the LUN stays on record'
        $row[0].lunHolds | Should -Be 'notRead' -Because 'the product does not know which disk is on the LUN'
        $row[0].why | Should -Not -Match 'after 3 tries'
    }
    It 'FINISH-ATTACH-UNKNOWN-WORDS-1: one LUN''s attach stops with no refusal and another LUN''s swap is refused - only the refused LUN is said "after 3 tries"' {
        $script:rp = SwLeftRun -Kind 'restore'
        SwEdit $script:rp { param($d) ($d.swapPending.swaps | Where-Object lun -EQ 1) | Add-Member -NotePropertyName snapshotId -NotePropertyValue '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine-d1' -Force }
        $global:sw.luns.Remove(1)
        $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/vm1-pristine-d1"
        $global:sw.refuse = @(2)
        Mock -ModuleName VmMigrationFactory Add-VmfVmDataDiskOnEmptyLun { throw 'Machine vm1 could not be read' }
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } | Should -Throw
        $err = (@(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'finish' -and $_.outcome -eq 'fail' }))[-1].detail
        $err | Should -Match "after 3 tries: LUN 2 keeps 'vm1-data2', not the disk 'vm1-data2-d2-asitwas-x' made from its copy\. Azure said: OperationNotAllowed"
        $err | Should -Not -Match 'after 3 tries: [^.]*LUN 1'
        $err | Should -Match 'stopped with an error that is not a refusal from Azure: Machine vm1 could not be read\.'
        $err | Should -Match 'Use Finish the restore again when Azure accepts the swap\. It reads each LUN before it changes the machine\.'
        $doc = SwDoc $script:rp
        ($doc.swapPending.swaps | Where-Object lun -EQ 1).lunHolds | Should -Be 'notRead'
        ($doc.swapPending.swaps | Where-Object lun -EQ 2).lunHolds | Should -Be 'had'
    }
    It 'OLD-STATE-READERS-FINISH-1: a row that names no copy proves nothing - Finish stops before any change, and never attaches on a weaker proof' {
        $script:rp = SwLeftRun -Kind 'restore'
        $global:sw.luns.Remove(1)
        SwEdit $script:rp { param($d) foreach ($s in @($d.swapPending.swaps)) { $s.PSObject.Properties.Remove('snapshotId') } }
        $global:sw.sources["$($script:sub)/disks/vm1-data1-d1-asitwas-x"] = "$($script:sub)/snapshots/another-copy"
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw "*names no copy that the disk 'vm1-data1-d1-asitwas-x' was made from*"
        @($global:sw.calls | Where-Object { $_ -like 'attach:*' -or $_ -like 'data:*' -or $_ -eq 'start' -or $_ -eq 'stop' }).Count | Should -Be 0
        SwLog $script:rp | Should -Not -Match 'checked only that the disk exists'
    }

    It 'nothing left to finish: refused, and nothing is touched' {
        $script:rp = SwNewRun
        { Complete-VmfDataDiskSwap -RunPath $script:rp -VmId $script:vmId -FinishedBy 'operator@example.com' -Note 'n' -Confirm:$false } |
            Should -Throw -ExpectedMessage '*no data disk swap*'
        $global:sw.calls.Count | Should -Be 0
    }
}

Describe 'SWAP-REFUSED-AFTER-STOP-1: nothing else acts on a machine with a swap left' {
    It 'Test-VmfRetryHeld: a swap left holds the retry, even after a restore record' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ state = 'FAILED_ROLLED_BACK'; restore = [pscustomobject]@{ restoredUtc = '2026-10-23T11:00:00Z' }
                swapPending = [pscustomobject]@{ kind = 'restore'; swaps = @([pscustomobject]@{ lun = 1 }) }
                history = @([pscustomobject]@{ tsUtc = '2026-10-23T10:00:00Z'; state = 'FAILED_ROLLED_BACK'; machineState = 'restored' }) }
            Test-VmfRetryHeld -Doc $doc | Should -BeTrue
            $doc.PSObject.Properties.Remove('swapPending')
            Test-VmfRetryHeld -Doc $doc | Should -BeFalse
        }
    }

    It 'Resolve-VmfDecision refuses a retry, a validation again and a decision, naming the finish' {
        $rp = SwNewRun
        try {
            SwEdit $rp {
                param($d)
                $d.state = 'FAILED_ROLLED_BACK'
                $d.history = @($d.history) + @([pscustomobject]@{ tsUtc = '2026-10-23T10:00:00Z'; state = 'FAILED_ROLLED_BACK'; outcome = 'fail'; reasonCode = 'rolledBack'; machineState = 'restored' })
                $d | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = '2026-10-23T11:00:00Z' }) -Force
                $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kind = 'restore'; swaps = @([pscustomobject]@{ lun = 1 }) }) -Force
            }
            foreach ($to in 'PRECHECK', 'VALIDATING') {
                { Resolve-VmfDecision -RunPath $rp -VmId $script:vmId -PlanPath (Join-Path $rp 'plan.json') -ResolvedBy 'operator@example.com' -Note 'n' -ReturnTo $to } |
                    Should -Throw -ExpectedMessage '400: *Use Finish the restore on this machine first*'
            }
        }
        finally { Remove-Item $rp -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It 'retention never deletes a rollback disk that a swap left waits for' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ vmId = '/vm/1'; state = 'MIGRATED'
                safety = [pscustomobject]@{ rollbackDisksBeforeMove = [pscustomobject]@{ disks = @(
                            [pscustomobject]@{ lun = 1; diskId = '/disks/left1'; diskName = 'left1' }
                            [pscustomobject]@{ lun = 2; diskId = '/disks/spare2'; diskName = 'spare2' }) } }
                swapPending = [pscustomobject]@{ kind = 'restore'; swaps = @([pscustomobject]@{ lun = 1; diskId = '/disks/left1' }) } }
            $due = @(Get-VmfDueRollbackDisksBeforeMove -StateDocs @($doc))
            @($due.Disks | ForEach-Object diskId) | Should -Be @('/disks/spare2')
        }
    }
}

Describe 'SWAP-REFUSED-AFTER-STOP-1: Finish is reachable from the app (rule 12)' {
    It 'the engine dispatches the finish operation to Complete-VmfDataDiskSwap, with the operation id and no prompt' {
        $entry = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'docker' 'entrypoint.ps1')
        $branch = [regex]::Match($entry, "(?s)'finish' \{.*?Complete-VmfDataDiskSwap @finishParams").Value
        $branch | Should -Not -BeNullOrEmpty
        $branch | Should -Match 'CorrelationId\s*=\s*\$engineRunId'
        $branch | Should -Match 'Confirm\s*=\s*\$false'
        $branch | Should -Match 'VMF_VM_ID'
    }

    It 'the service starts finish for one machine, with who asked and why' {
        [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine')
        $store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-swf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $store | Out-Null
        [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $store)
        try {
            Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
                [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                    name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
            }
            Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
            Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $global:swAsked = @($Operation); $false }
            $global:swBody = $null
            Mock -ModuleName FacadeCore Invoke-AzRestMethod { $global:swBody = $Payload; [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-1"}' } }
            $op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
            Invoke-VmfFacadeStartEngine -Principal $op -Operation 'finish' -RunId 'run-x' -Note 'the swap is accepted now' -VmId $script:vmId | Out-Null
            $envs = @(($global:swBody | ConvertFrom-Json).containers[0].env)
            ($envs | Where-Object name -EQ 'VMF_OPERATION').value | Should -Be 'finish'
            ($envs | Where-Object name -EQ 'VMF_VM_ID').value | Should -Be $script:vmId
            ($envs | Where-Object name -EQ 'VMF_NOTE').value | Should -Be 'the swap is accepted now'
            ($envs | Where-Object name -EQ 'VMF_RESTORED_BY').value | Should -Be 'operator@example.com'
            $global:swAsked | Should -Contain 'finish' -Because 'one restore, rebuild or finish of a machine at a time'
            $global:swAsked | Should -Contain 'restore'
            { Invoke-VmfFacadeStartEngine -Principal $op -Operation 'finish' -RunId 'run-x' -Note 'n' } | Should -Throw '400:*machine*'
            { Invoke-VmfFacadeStartEngine -Principal $op -Operation 'finish' -RunId 'run-x' -VmId $script:vmId } | Should -Throw '400:*note*'
            $viewer = [pscustomobject]@{ Identity = 'viewer@example.com'; Roles = @('Vmf.Viewer') }
            { Invoke-VmfFacadeStartEngine -Principal $viewer -Operation 'finish' -RunId 'run-x' -Note 'n' -VmId $script:vmId } | Should -Throw '403*'
        }
        finally {
            [Environment]::SetEnvironmentVariable('VMF_ENGINE_JOB_ID', $null)
            [Environment]::SetEnvironmentVariable('VMF_STORE_PATH', $null)
            Remove-Item $store -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Variable swBody, swAsked -Scope Global -ErrorAction SilentlyContinue
        }
    }
}

Describe 'SWAP-REFUSED-AFTER-STOP-1: the contract (rule 1)' {
    It 'vm-state v25 declares swapPending, and the sample holds one that validates' {
        $schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $schema.properties.swapPending | Should -Not -BeNullOrEmpty
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        ($sample | ConvertFrom-Json).swapPending.kind | Should -Be 'restore'
        Test-Json -Json $sample -SchemaFile (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') | Should -BeTrue
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v24 -> v25 \(2026-10-23, SWAP-REFUSED-AFTER-STOP-1\)'
    }
    It 'FINISH-EMPTY-LUN-PROOF-1: vm-state v28 declares the copy of each disk that waits, the sample holds one that validates, and a row with any other field is refused' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        @($schema.properties.swapPending.properties.swaps.items.properties.snapshotId.type) | Should -Be @('string')
        @($schema.properties.swapPending.properties.swaps.items.required) | Should -Contain 'snapshotId' -Because 'OLD-STATE-READERS-FINISH-1: every row a swap of this version leaves names its copy (v48)'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        [string](($sample | ConvertFrom-Json).swapPending.swaps[0].snapshotId) | Should -Match '/snapshots/'
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        $row = '{"lun":1,"name":"d1","diskId":"/d/x","diskName":"x","lunHolds":"had","snapshotId":'
        $base = { param($r) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"swapPending":{"kind":"restore","leftUtc":"2026-10-25T00:00:00Z","error":"e","swaps":[' + $r + '],"swapped":[],"kept":[]}}' }
        Test-Json -Json (& $base ($row + '"/s/copy-d1"}')) -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base ($row + 'null}')) -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        Test-Json -Json (& $base '{"lun":1,"name":"d1","diskId":"/d/x","diskName":"x","lunHolds":"had"}') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse -Because 'a row with no copy is refused (v48)'
        Test-Json -Json (& $base '{"lun":1,"name":"d1","diskId":"/d/x","diskName":"x","snapshotId":"/s/c"}') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse -Because 'a row that does not say what is on its LUN is refused (v48)'
        Test-Json -Json (& $base ($row + '7}')) -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v27 -> v28 \(2026-10-25, FINISH-EMPTY-LUN-PROOF-1\)'
    }
    It 'FINISH-KEPT-DISKS-1: vm-state v29 declares the data disks kept as they are on the record of the waiting swap, the sample holds one that validates, and a kept row with any other field is refused' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) | Should -Be 51
        $kept = $schema.properties.swapPending.properties.kept
        $kept.type | Should -Be 'array'
        @($kept.items.required) | Should -Be @('lun', 'name', 'why')
        @($schema.properties.swapPending.required) | Should -Contain 'kept' -Because 'OLD-STATE-READERS-FINISH-1: every swap record of this version holds it (v48)'
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        @(($sample | ConvertFrom-Json).swapPending.kept).Count | Should -BeGreaterThan 0
        Test-Json -Json $sample -SchemaFile $schemaFile | Should -BeTrue
        $base = { param($k) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"swapPending":{"kind":"restore","leftUtc":"2026-10-25T00:00:00Z","error":"e","swaps":[],"swapped":[]' + $k + '}}' }
        Test-Json -Json (& $base ',"kept":[{"lun":1,"name":"d1","why":"It is a shared disk."}]') -SchemaFile $schemaFile | Should -BeTrue
        Test-Json -Json (& $base '') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse -Because 'a swap record with no kept list is refused (v48)'
        Test-Json -Json (& $base ',"kept":[{"lun":1,"name":"d1","why":"w","shared":true}]') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        Test-Json -Json (& $base ',"kept":[{"lun":1,"name":"d1"}]') -SchemaFile $schemaFile -ErrorAction SilentlyContinue | Should -BeFalse
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v28 -> v29 \(2026-10-25, FINISH-KEPT-DISKS-1\)'
    }
    It 'FINISH-KEPT-DISKS-1: New-VmfSwapPendingRecord writes each kept disk as lun, name and why only, and an empty list when none is kept' {
        InModuleScope VmMigrationFactory {
            $rec = New-VmfSwapPendingRecord -Kind 'restore' -Swaps @() -Reason 'e' -Kept @([pscustomobject]@{ lun = 2; name = 'd2'; why = 'w2'; shared = $true; refused = $false }, [pscustomobject]@{ lun = 1; name = 'd1'; why = 'w1' })
            @($rec.kept | ForEach-Object { [int]$_.lun }) | Should -Be @(1, 2)
            @($rec.kept[1].Keys) | Should -Be @('lun', 'name', 'why')
            $rec.kept[1].lun | Should -BeOfType [int]
            $none = New-VmfSwapPendingRecord -Kind 'rollback' -Swaps @() -Reason 'e'
            $none.Contains('kept') | Should -BeTrue
            @($none.kept).Count | Should -Be 0
        }
    }
}

Describe 'FINISH-EMPTY-LUN-PROOF-1: each disk that waits names the copy it was made from' {
    It 'New-VmfSwapLeftRow keeps the copy of the swap, and -SnapshotId names it when the swap does not' {
        InModuleScope VmMigrationFactory {
            $swap = [pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x'; snapshotId = '/s/copy-d1' }
            (New-VmfSwapLeftRow -Swap $swap -OldDiskId '/d/d1').snapshotId | Should -Be '/s/copy-d1'
            $bare = [pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/x'; diskName = 'x' }
            (New-VmfSwapLeftRow -Swap $bare -SnapshotId '/s/given').snapshotId | Should -Be '/s/given'
            $row = New-VmfSwapLeftRow -Swap $bare
            $row.PSObject.Properties['snapshotId'] | Should -Not -BeNullOrEmpty
            $row.snapshotId | Should -BeNullOrEmpty -Because 'no copy is said as null, never as an empty name'
        }
    }
    It 'Invoke-VmfDataDiskRestore: each disk it swaps in names the copy it was made from' {
        $out = InModuleScope VmMigrationFactory {
            Mock Write-VmfStepLine { }
            Mock Invoke-VmfAzOperation { & $Operation }
            Mock Get-VmfDiskShareCount { 1 }
            Mock Add-VmfRollbackDiskDuringRollbackRecord { }
            Mock New-VmfDataDiskFromCopy { @{ Id = "/d/$DiskName"; Why = $null } }
            $plan = @{ Restore = @([pscustomobject]@{ lun = 0; name = 'd0'; sourceDiskId = '/d/d0'; snapshotId = '/s/copy-d0'; diskName = 'd0-new'; skuName = 'Premium_LRS' }); Kept = @() }
            Invoke-VmfDataDiskRestore -Context ([pscustomobject]@{ RunPath = $TestDrive; VmId = 'v'; Rg = 'rg' }) -RestorePlan $plan -Location 'centralus' -Step 'restore'
        }
        @($out.Swaps).Count | Should -Be 1
        $out.Swaps[0].snapshotId | Should -Be '/s/copy-d0'
    }
    It 'Get-VmfRollbackDisksBeforeMoveSet: each rollback disk names the copy it was made from' {
        $out = InModuleScope VmMigrationFactory {
            Mock Invoke-VmfAzOperation { & $Operation }
            Mock Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $true; ManagedBy = ''; SourceResourceId = '' } }
            $doc = [pscustomobject]@{ safety = [pscustomobject]@{ rollbackDisksBeforeMove = [pscustomobject]@{ pristineSnapshotId = '/s/p'; complete = $true; zone = $null; kept = @()
                        disks = @(
                            [pscustomobject]@{ lun = $null; name = 'os'; diskId = '/d/os-asitwas'; diskName = 'os-asitwas'; snapshotId = '/s/p'; skuName = 'Premium_LRS'; instantAccess = $false; usedUtc = $null; deletedUtc = $null }
                            [pscustomobject]@{ lun = 1; name = 'd1'; diskId = '/d/d1-asitwas'; diskName = 'd1-asitwas'; snapshotId = '/s/p-d1'; skuName = 'Premium_LRS'; instantAccess = $false; usedUtc = $null; deletedUtc = $null }) } } }
            Get-VmfRollbackDisksBeforeMoveSet -Context ([pscustomobject]@{ RunPath = $TestDrive; VmId = 'v' }) -Doc $doc -Shape full -FromSnapshotId '/s/p'
        }
        $out.Why | Should -BeNullOrEmpty
        @($out.Set.Data.Swaps).Count | Should -Be 1
        $out.Set.Data.Swaps[0].snapshotId | Should -Be '/s/p-d1'
    }
}
