#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# RESTORE-ALL-1: Restore this machine puts back every disk.
#
# SAFETY-ALL-1 copied every disk and made the automatic put-back restore them
# all. The operator's restore replaced the OS disk only, so a restored machine
# ran on an OS disk of one moment and data disks of another. Now every data
# disk comes back from the copy the person chose, with the put-back's rules,
# in the machine's zone, under ONE naming choice for all disks - and a restore
# that keeps the names deletes each disk it replaces, named one by one.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:dataSub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-data/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"

    # A zonal machine with two data disks, both copied twice. An earlier
    # rollback gave LUN 1 a new disk, so the disk there NOW is not the one the
    # capture names.
    function Global:RaDoc {
        param([string]$Lun1Sku = 'Standard_LRS')
        Complete-VmfTestCapture ([pscustomobject]@{
            schemaVersion = (Get-VmfTestStateVersion); vmId = $script:vmId; state = 'MIGRATED'; history = @()
            captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{
                    name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @('2')
                    osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; deleteOption = 'Delete' }
                    dataDisks = @(
                        [pscustomobject]@{ lun = 0; name = 'vm1-d0'; skuName = 'StandardSSD_LRS'; managedDiskId = "$($script:dataSub)/Microsoft.Compute/disks/vm1-d0" },
                        [pscustomobject]@{ lun = 1; name = 'vm1-d1'; skuName = $Lun1Sku; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1" })
                    tags = @{}; nics = @() } }
            # The rollback that made the disk on LUN 1: the record knows it.
            rollback = [pscustomobject]@{ rolledBackUtc = '2026-09-29T18:30:00Z'; path = 'A'; osDisk = $null
                dataDisks = @([pscustomobject]@{ lun = 1; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1-d1-asitwas-202609291830"; diskName = 'vm1-d1-d1-asitwas-202609291830' }) }
            safety = [pscustomobject]@{
                snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-prepared"
                pristineSnapshotId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-pristine"
                cloneVmId = $null; locksAllowed = $true; pristineSnapshotLocked = $true
                pristineDataCopies = @(
                    [pscustomobject]@{ lun = 0; diskId = "$($script:dataSub)/Microsoft.Compute/disks/vm1-d0"; snapshotId = '/snap/pristine-d0'; locked = $true },
                    [pscustomobject]@{ lun = 1; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; snapshotId = '/snap/pristine-d1'; locked = $true })
                dataCopies = @(
                    [pscustomobject]@{ lun = 0; diskId = "$($script:dataSub)/Microsoft.Compute/disks/vm1-d0"; snapshotId = '/snap/prepared-d0'; locked = $true },
                    [pscustomobject]@{ lun = 1; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; snapshotId = '/snap/prepared-d1'; locked = $true })
            }
        })
    }
    # The disks on the machine now: LUN 0 in another resource group, LUN 1
    # made by the earlier rollback, and moved to Premium SSD by the move.
    function Global:RaLive {
        @([pscustomobject]@{ lun = 0; id = "$($script:dataSub)/Microsoft.Compute/disks/vm1-d0"; name = 'vm1-d0'; resourceGroup = 'rg-data'; skuName = 'Premium_LRS' },
          [pscustomobject]@{ lun = 1; id = "$($script:sub)/Microsoft.Compute/disks/vm1-d1-d1-asitwas-202609291830"; name = 'vm1-d1-d1-asitwas-202609291830'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' })
    }

    function Global:RaRun {
        param($Doc = (RaDoc))
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ra-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; d = $Doc } {
            param($rp, $id, $d)
            Initialize-VmfRun -RunPath $rp -RunId 'ra' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'ra' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            foreach ($f in 'captured', 'safety', 'rollback') { $doc | Add-Member -NotePropertyName $f -NotePropertyValue $d.$f -Force }
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                        assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe'; zone = '2' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }

    function Global:RaMocks {
        $global:ra = @{ made = [System.Collections.Generic.List[object]]::new(); deleted = [System.Collections.Generic.List[string]]::new()
            swaps = [System.Collections.Generic.List[object]]::new(); calls = [System.Collections.Generic.List[string]]::new(); applied = $true; locked = '' }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            $global:ra.made.Add([pscustomobject]@{ rg = $ResourceGroupName; name = $DiskName; snap = $SnapshotId; sku = $SkuName; zone = $Zone })
            $global:ra.calls.Add("make:$DiskName"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = '/d/vm1-os'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { Global:RaLive }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:ra.swaps.Add(@($Swaps)); $global:ra.calls.Add("swapData:$(@($Swaps | ForEach-Object { $_.diskName }) -join ',')")
            if ($global:ra.applied) { @{ Applied = $true } } else { @{ Applied = $false; Reason = 'refused' } } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:ra.deleted.Add("$ResourceGroupName/$DiskName"); $global:ra.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { if ($DiskName -eq $global:ra.locked) { , @('keep-me') } else { , @() } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:ra.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:ra.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:ra.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:ra.calls.Add("swapOs:$DiskName") }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { $global:ra.calls.Add("type:$(($DiskId -split '/')[-1])=$SkuName") }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v4' }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
    }
    function Global:RaRecord($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) (Read-VmfStateDoc -RunPath $rp -VmId $id) }
    }
}
AfterAll { Remove-Item function:RaDoc, function:RaLive, function:RaRun, function:RaMocks, function:RaRecord -ErrorAction SilentlyContinue }

Describe 'RESTORE-ALL-1: which data disks a restore replaces' {
    It 'every disk with a copy, from the kind the person chose, replacing the disk that is on each LUN NOW' {
        InModuleScope VmMigrationFactory {
            $p = Get-VmfOperatorDataRestorePlan -Doc (RaDoc) -Kind 'pristine' -Live (RaLive) -Stamp 's' -Naming 'new'
            @($p.Restore).Count | Should -Be 2
            @($p.Kept).Count | Should -Be 0
            $d1 = @($p.Restore) | Where-Object lun -eq 1
            $d1.snapshotId | Should -Be '/snap/pristine-d1'
            $d1.currentName | Should -Be 'vm1-d1-d1-asitwas-202609291830'
            $d1.sourceDiskId | Should -Match 'asitwas'
            $d1.diskName | Should -Match '-d1-restored-s$'
            # The first copy goes back on the type the capture recorded.
            (@($p.Restore) | Where-Object lun -eq 0).skuName | Should -Be 'StandardSSD_LRS'
        }
    }

    It 'the second copy uses the second copies, and keeps the type each disk has now' {
        InModuleScope VmMigrationFactory {
            $p = Get-VmfOperatorDataRestorePlan -Doc (RaDoc) -Kind 'prepared' -Live (RaLive) -Stamp 's' -Naming 'new'
            @($p.Restore | ForEach-Object snapshotId) | Should -Be @('/snap/prepared-d0', '/snap/prepared-d1')
            @($p.Restore | ForEach-Object skuName) | Should -Be @('Premium_LRS', 'Premium_LRS')
        }
    }

    It 'keeping the names: each disk takes the current name, where the current disk is' {
        InModuleScope VmMigrationFactory {
            $p = Get-VmfOperatorDataRestorePlan -Doc (RaDoc) -Kind 'pristine' -Live (RaLive) -Stamp 's' -Naming 'preserve'
            $d0 = @($p.Restore) | Where-Object lun -eq 0
            $d0.diskName | Should -Be 'vm1-d0'
            $d0.currentResourceGroup | Should -Be 'rg-data'
            $d0.tempName | Should -Match '-d0-rtmp-s$'
        }
    }

    It 'leaves, and says why: an empty LUN, a disk on Ultra Disk now, and a disk the capture never saw' {
        InModuleScope VmMigrationFactory {
            $live = @(
                [pscustomobject]@{ lun = 1; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-d1-d1-asitwas-202609291830'; name = 'vm1-u1'; resourceGroup = 'rg-app'; skuName = 'UltraSSD_LRS' },
                [pscustomobject]@{ lun = 5; id = '/d/n'; name = 'vm1-new5'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' })
            $p = Get-VmfOperatorDataRestorePlan -Doc (RaDoc) -Kind 'pristine' -Live $live -Stamp 's' -Naming 'new'
            @($p.Restore).Count | Should -Be 0
            @($p.Kept | ForEach-Object lun) | Should -Be @(0, 1, 5)
            (@($p.Kept) | Where-Object lun -eq 0).why | Should -Match 'No data disk is on LUN 0'
            (@($p.Kept) | Where-Object lun -eq 1).why | Should -Match 'Ultra Disk'
            (@($p.Kept) | Where-Object lun -eq 5).why | Should -Match 'No copy'
        }
    }

    It 'the put-back''s own rules still apply: a disk captured on Premium SSD v2 is left' {
        InModuleScope VmMigrationFactory {
            $p = Get-VmfOperatorDataRestorePlan -Doc (RaDoc -Lun1Sku 'PremiumV2_LRS') -Kind 'pristine' -Live (RaLive) -Stamp 's' -Naming 'new'
            @($p.Restore | ForEach-Object lun) | Should -Be @(0)
            (@($p.Kept) | Where-Object lun -eq 1).why | Should -Match 'Premium SSD v2'
        }
    }
}

Describe 'RESTORE-ALL-1: Restore this machine puts back every disk' {
    BeforeEach { RaMocks; $script:rp = RaRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable ra -Scope Global -ErrorAction SilentlyContinue }

    It 'THE CASE, new names: the OS disk and both data disks from the first copies, in zone 2, and nothing deleted' {
        $out = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false
        @($global:ra.made | ForEach-Object snap) | Should -Be @("$($script:sub)/Microsoft.Compute/snapshots/vm1-pristine", '/snap/pristine-d0', '/snap/pristine-d1')
        @($global:ra.made | Where-Object { $_.zone -ne '2' }) | Should -BeNullOrEmpty
        @($global:ra.deleted) | Should -BeNullOrEmpty
        # New names go beside the machine, whichever resource group the current disk is in.
        @($global:ra.made | Where-Object { $_.rg -ne 'rg-app' }) | Should -BeNullOrEmpty
        @($global:ra.swaps).Count | Should -Be 1 -Because 'one swap call covers every data disk; it detaches and attaches them together (SWAP-2UPD-1)'
        @($global:ra.swaps[0]).Count | Should -Be 2
        # Stopped the whole time: every swap is between the stop and the start.
        $calls = @($global:ra.calls)
        [array]::IndexOf($calls, 'stop') | Should -BeLessThan ([array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'swapData:*' })))
        [array]::IndexOf($calls, 'start') | Should -Be ($calls.Count - 1)
        $rec = (RaRecord $script:rp).restore
        @($rec.dataDisks).Count | Should -Be 2
        (@($rec.dataDisks) | Where-Object lun -eq 1).previousDiskName | Should -Be 'vm1-d1-d1-asitwas-202609291830'
        @($out.DataDisks).Count | Should -Be 2
        (RaRecord $script:rp).schemaVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion }) -Because 'the record is written at the version the store writes (v17 since V3-RETIRE-1)'
    }

    It 'THE REVIEW CASE: a disk the rollback made, on Premium SSD, gets its captured type back BEFORE the original size' {
        # No move record names it - the move changed the CAPTURED disk - so
        # only the record of what the product made can say where it belongs.
        # Without this, Azure refuses a size that takes no Premium SSD.
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:ra.calls)
        $calls | Should -Contain 'type:vm1-d1-d1-asitwas-202609291830=Standard_LRS'
        [array]::IndexOf($calls, 'type:vm1-d1-d1-asitwas-202609291830=Standard_LRS') | Should -BeLessThan ([array]::IndexOf($calls, 'size:Standard_D2s_v4'))
    }

    It 'a disk on a LUN that the record does not know is never replaced, and never deleted' {
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/someone-elses'; name = 'someone-elses'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' })
        }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null | Out-Null
        @($global:ra.deleted | Where-Object { $_ -match 'someone-elses' }) | Should -BeNullOrEmpty
        $rec = (RaRecord $script:rp).restore
        (@($rec.dataDisksKept) | Where-Object lun -eq 0).why | Should -Match 'not a disk that the record of this machine names'
    }

    It 'a shared disk is found before the stop: not locked-checked, not named for deletion, left' {
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ($DiskId -match 'vm1-d0$') { 2 } else { 1 } }
        $global:ra.locked = 'vm1-d0'
        $warn = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        "$warn" | Should -Not -Match 'vm1-d0'
        @($global:ra.deleted | Where-Object { $_ -match 'vm1-d0' }) | Should -BeNullOrEmpty
        (@((RaRecord $script:rp).restore.dataDisksKept) | Where-Object lun -eq 0).why | Should -Match 'shared disk'
    }

    It 'SAFETY-ULTRA-1: Restore this machine reads each Premium SSD v2 copy before the stop, and keeping the names never deletes a disk such a copy still depends on' {
        Remove-Item $script:rp -Recurse -Force
        $d = RaDoc -Lun1Sku 'PremiumV2_LRS'
        $d1 = @($d.captured.vmConfig.dataDisks)[1]
        foreach ($kv in @{ diskIOPSReadWrite = 5000; diskMBpsReadWrite = 200; logicalSectorSize = 512; diskZones = @('2') }.GetEnumerator()) { $d1 | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force }
        $script:rp = RaRun -Doc $d
        # The disk on LUN 1 now is the disk the copy was taken from.
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = "$($script:dataSub)/Microsoft.Compute/disks/vm1-d0"; name = 'vm1-d0'; resourceGroup = 'rg-data'; skuName = 'Premium_LRS' },
              [pscustomobject]@{ lun = 1; id = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; name = 'vm1-d1'; resourceGroup = 'rg-app'; skuName = 'PremiumV2_LRS' })
        }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess {
            $global:ra.calls.Add("readCopy:$(($SnapshotId -split '/')[-1])")
            [pscustomobject]@{ snapshotAccessState = 'InstantAccess'; completionPercent = 30; instantAccessDurationMinutes = 300; timeCreated = (Get-Date).ToUniversalTime().ToString('o') }
        }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null | Out-Null
        $calls = @($global:ra.calls)
        $calls | Should -Contain 'readCopy:pristine-d1'
        $calls | Should -Contain 'readCopy:prepared-d1' -Because 'every copy on record that could depend on the disk is read'
        [array]::IndexOf($calls, 'readCopy:pristine-d1') | Should -BeLessThan ([array]::IndexOf($calls, 'stop'))
        @($global:ra.deleted | Where-Object { $_ -match '/vm1-d1$' }) | Should -BeNullOrEmpty
        (@((RaRecord $script:rp).restore.dataDisksKept) | Where-Object lun -eq 1).why | Should -Match 'a copy of it depends on it until Azure finishes copying it'
        @($global:ra.deleted | Where-Object { $_ -match '/vm1-d0$' }) | Should -Not -BeNullOrEmpty -Because 'the other disks are restored as before'
    }

    It 'from the second copy: the second copies' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        @($global:ra.made | ForEach-Object snap) | Should -Be @("$($script:sub)/Microsoft.Compute/snapshots/vm1-prepared", '/snap/prepared-d0', '/snap/prepared-d1')
    }

    It 'keeping the names: each current disk is deleted, the new one takes its name where it was, and the temporary disks go' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null | Out-Null
        $deleted = @($global:ra.deleted)
        $deleted | Should -Contain 'rg-app/vm1-os'
        $deleted | Should -Contain 'rg-data/vm1-d0'
        $deleted | Should -Contain 'rg-app/vm1-d1-d1-asitwas-202609291830'
        @($deleted | Where-Object { $_ -match '-d\d-rtmp-' }).Count | Should -Be 2
        $finals = @($global:ra.made | Where-Object { $_.name -in @('vm1-d0', 'vm1-d1-d1-asitwas-202609291830') })
        $finals.Count | Should -Be 2
        ($finals | Where-Object name -eq 'vm1-d0').rg | Should -Be 'rg-data'
        # A current disk is deleted only once the temporary disk is on its LUN.
        $calls = @($global:ra.calls)
        $tempOn = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'swapData:vm1-d0-d0-rtmp*' } | Select-Object -First 1))
        $tempOn | Should -BeGreaterOrEqual 0
        [array]::IndexOf($calls, 'delete:vm1-d0') | Should -BeGreaterThan $tempOn
        $rec = (RaRecord $script:rp).restore
        @($rec.dataDisks | ForEach-Object newDiskName) | Should -Be @('vm1-d0', 'vm1-d1-d1-asitwas-202609291830')
    }

    It 'keeping the names: the warning names EVERY disk it deletes' {
        $warn = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>&1 |
            Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
        "$warn" | Should -Match 'vm1-os'
        "$warn" | Should -Match 'vm1-d0'
        "$warn" | Should -Match 'vm1-d1-d1-asitwas'
    }

    It 'keeping the names: a lock on ONE data disk refuses before the machine stops' {
        $global:ra.locked = 'vm1-d0'
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*vm1-d0*'
        @($global:ra.calls) | Should -Not -Contain 'stop'
    }

    It 'CANNOTDELETE-RESTORE-1, keeping the names: a lock that refuses the delete of a temporary data disk refuses before the machine stops' {
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { if ($DiskName -like 'vm1-d0-d0-rtmp-*') { , @('keep-me (CanNotDelete)') } else { , @() } }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage "Restore cannot keep the original disk names. A resource lock (keep-me (CanNotDelete)) on the resource group 'rg-app' prevents the delete of the temporary disk 'vm1-d0-d0-rtmp-*'. Remove the lock, or restore again and select Yes for Keep its current managed disks."
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks -ParameterFilter { $ResourceGroupName -eq 'rg-app' -and $DiskName -like 'vm1-d0-d0-rtmp-*' }
        @($global:ra.calls) | Should -Not -Contain 'stop'
        @($global:ra.made) | Should -HaveCount 0
        @($global:ra.deleted) | Should -HaveCount 0
    }

    # SWAP-REFUSED-AFTER-STOP-1 rewrote this and the new-names case below on
    # purpose: the machine STARTED with its OS disk from the copy and these
    # data disks as they were. Now it stays stopped, and the record names both
    # for Finish the restore.
    It 'keeping the names: a swap Azure refuses on every try deletes nothing of the data disks, leaves the machine stopped, and the record names both' {
        $global:ra.applied = $false
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*left STOPPED*Finish the restore*'
        @($global:ra.deleted | Where-Object { $_ -match 'vm1-d' }) | Should -BeNullOrEmpty
        @($global:ra.calls) | Should -Not -Contain 'start'
        $doc = RaRecord $script:rp
        @($doc.restore.dataDisks).Count | Should -Be 0
        @($doc.restore.dataDisksKept).Count | Should -Be 0
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        @($doc.swapPending.swaps | Where-Object { -not $_.temporary }) | Should -BeNullOrEmpty
    }

    It 'POWER-AFTER-MOVE-1: a swap Azure refuses keeps, on the record of the swap, the power state the restore found when it started' {
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        $global:ra.applied = $false
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } | Should -Throw
        (RaRecord $script:rp).swapPending.powerAtStart | Should -Be 'PowerState/deallocated'
    }

    It 'keeping the names, a delete that fails on the SECOND disk: the record says where each disk stands, the machine runs, and the restore says it did not finish' {
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk {
            if ($DiskName -eq 'vm1-d1-d1-asitwas-202609291830') { throw 'ScopeLocked' }
            $global:ra.deleted.Add("$ResourceGroupName/$DiskName"); $global:ra.calls.Add("delete:$DiskName") }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*restored and running*LUN 1*temporary disk*ScopeLocked*'
        $rec = (RaRecord $script:rp).restore
        @($rec.dataDisks | ForEach-Object lun) | Should -Be @(0)
        # RESTORE-NAME-STACK-1: the temporary name replaces the rollback's
        # suffix, it no longer stacks on it ('vm1-d1-d1-asitwas-...-d1-rtmp-').
        (@($rec.dataDisksKept) | Where-Object lun -eq 1).why | Should -Match "runs on the temporary disk 'vm1-d1-d1-rtmp-"
        @($global:ra.calls)[-1] | Should -Be 'start'
        # The page ends its "putting back" on the first warn or fail of the
        # restore step: only the last event may carry one.
        $ends = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } |
            Where-Object { $_.step -eq 'restore' -and $_.outcome -in @('warn', 'fail', 'ok') })
        $ends.Count | Should -Be 1
    }

    It 'POWER-AFTER-MOVE-1: the same, on a machine that was Stopped (deallocated) when the restore started: returned to it, and the error does not say running' {
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk {
            if ($DiskName -eq 'vm1-d1-d1-asitwas-202609291830') { throw 'ScopeLocked' }
            $global:ra.deleted.Add("$ResourceGroupName/$DiskName"); $global:ra.calls.Add("delete:$DiskName") }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*restored and in the power state it was found in*LUN 1*'
        @($global:ra.calls)[-2..-1] | Should -Be @('start', 'stop')
    }

    It 'keeping the names, the new disk under the old name fails on the FIRST disk: the second is not touched' {
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            if ($DiskName -eq 'vm1-d0') { throw 'QuotaExceeded' }
            $global:ra.made.Add([pscustomobject]@{ rg = $ResourceGroupName; name = $DiskName; snap = $SnapshotId; sku = $SkuName; zone = $Zone }); "/disks/$DiskName" }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage '*LUN 0*is deleted*QuotaExceeded*'
        @($global:ra.deleted | Where-Object { $_ -match 'asitwas' }) | Should -BeNullOrEmpty
        # ROLLBACK-DISKS-FIRST-1 (rewritten on purpose): the temporary disk of
        # LUN 1 is made before the stop now, so "not touched" is about the
        # machine - it never goes on LUN 1, and the record names it.
        @($global:ra.swaps | ForEach-Object { $_ } | Where-Object { $_.diskName -match 'd1-rtmp' }) | Should -BeNullOrEmpty
        # SWAP-REFUSED-AFTER-STOP-1 re-review (rewritten on purpose): LUN 1 was
        # not touched, so it holds the disk it had while LUN 0 runs on the copy.
        # It is left on record for Finish the restore, and the machine stays
        # stopped - it used to be kept, and the machine started.
        $doc = RaRecord $script:rp
        @($global:ra.calls) | Should -Not -Contain 'start'
        $lun1 = @($doc.swapPending.swaps) | Where-Object lun -eq 1
        $lun1.why | Should -Match 'stopped at an earlier data disk'
        $lun1.diskName | Should -Match '^vm1-d1-d1-rtmp-'
        $lun1.temporary | Should -BeTrue
        @($doc.restore.dataDisksKept | Where-Object lun -eq 1) | Should -BeNullOrEmpty
    }

    It 'keeping the names, a temporary disk Azure does not delete: the restore is still done, and says so' {
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk {
            if ($DiskName -match '-d\d-rtmp-') { throw 'busy' }
            $global:ra.deleted.Add("$ResourceGroupName/$DiskName") }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null | Out-Null
        @((RaRecord $script:rp).restore.dataDisks).Count | Should -Be 2
        $events = Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') -Raw
        $events | Should -Match 'is not attached and was not deleted'
    }

    It 'new names, a swap Azure refuses on every try: the data disks are as they were, the machine stays stopped, and the record names both disks left and the disks made' {
        $global:ra.applied = $false
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw -ExpectedMessage '*left STOPPED*'
        @($global:ra.calls) | Should -Not -Contain 'start'
        $doc = RaRecord $script:rp
        @($doc.restore.dataDisks).Count | Should -Be 0
        @($doc.swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
        @($doc.swapPending.swaps)[0].why | Should -Be 'refused'
        @($doc.swapPending.swaps)[0].diskName | Should -Match '-d0-restored-'
    }
    # SWAP-PARTIAL-START-1 rewrote this on purpose: each LUN still on the disk
    # it had was recorded as kept and the machine STARTED. Now each is left on
    # record, the machine stays stopped, and Finish the restore swaps them.
    It 'new names, a swap that did not finish: each LUN on its own disk is left on record, and the machine stays stopped' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { throw 'Data disk swap did not take effect on every LUN' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw -ExpectedMessage '*did not finish*left STOPPED*'
        @($global:ra.calls) | Should -Not -Contain 'start'
        @((RaRecord $script:rp).swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
    }

    # RESTORE-EMPTY-LUN-1 rewrote this on purpose: the error told a person to
    # attach each disk in Azure. Now the restore attaches the disk the record
    # proves belongs there; one it cannot prove stays on record for Finish the
    # restore, and the words name the LUN and both disks - never a step in Azure.
    It 'SWAP-2UPD-1: a swap that leaves a LUN with NO disk, and the disk made from its copy is gone: the machine is left STOPPED, the LUN is on record, and the error names the LUN and both disks' {
        $global:ra.reads = 0
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            $global:ra.reads++
            if ($global:ra.reads -eq 1) { Global:RaLive } else { @((Global:RaLive)[1]) }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment { [pscustomobject]@{ Exists = $false; ManagedBy = ''; SourceResourceId = '' } }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { throw 'The data disks are neither swapped nor as they were. ARM reports LUN 0: NO DISK, LUN 1: ...' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_.Exception.Message }
        $err | Should -BeLike "*left STOPPED*LUN 0 has no disk*-d0-restored-*'vm1-d0'*Finish the restore*"
        $err | Should -Not -Match 'Attach each disk to its LUN' -Because 'the way forward is in the app, never in Azure'
        @($global:ra.calls) | Should -Not -Contain 'start'
        $rec = RaRecord $script:rp
        $rec.restore | Should -Not -BeNullOrEmpty -Because 'the record says where each disk stands'
        @($rec.swapPending.swaps | ForEach-Object { [int]$_.lun }) | Should -Contain 0
    }
    It 'a copy named by its ID restores the OS disk only, and says so for each data disk' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -SnapshotId '/snap/someone-else' -Confirm:$false | Out-Null
        @($global:ra.made).Count | Should -Be 1
        $rec = (RaRecord $script:rp).restore
        @($rec.dataDisksKept).Count | Should -Be 2
        @($rec.dataDisksKept)[0].why | Should -Match 'named by its ID'
    }
}

Describe 'RESTORE-ALL-1: the record and the report' {
    It 'the IaC report lists every data disk a restore made' {
        $doc = [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r'; vmId = '/s/rg/vm/api'; state = 'MIGRATED'; history = @()
            captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2s_v4'; controller = 'SCSI'
                    osDisk = [pscustomobject]@{ name = 'api-os'; managedDiskId = '/s/rg/disks/api-os'; skuName = 'Premium_LRS' }
                    dataDisks = @([pscustomobject]@{ lun = 0; name = 'api-d0'; managedDiskId = '/s/rg/disks/api-d0'; skuName = 'Premium_LRS' }); nics = @() } }
            restore = [pscustomobject]@{ fromCopy = 'prepared'; sizeAfter = 'Standard_D2s_v6'; diskNaming = 'new'; newDiskName = 'api-os-restored'; diskIdChanged = $true
                dataDisks = @([pscustomobject]@{ lun = 0; previousDiskId = '/s/rg/disks/api-d0'; previousDiskName = 'api-d0'; newDiskId = '/s/rg/disks/api-d0-r'; newDiskName = 'api-d0-r' }) } }
        $null = Complete-VmfTestCapture $doc
        $row = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) @(Get-VmfIacChangeRows -StateDocs @($d))[0] }
        $row.disks | Should -Match 'New OS disk: api-os-restored'
        $row.disks | Should -Match 'New data disk on LUN 0: api-d0-r'
    }

    It 'a restore from the SECOND copy keeps the move''s type change in the report; the first copy puts it back' {
        $mk = {
            param($copy)
            [pscustomobject]@{ schemaVersion = (Get-VmfTestStateVersion); runId = 'r'; vmId = '/s/rg/vm/api'; state = 'MIGRATED'; history = @()
                captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2s_v4'; controller = 'SCSI'
                        osDisk = [pscustomobject]@{ name = 'api-os'; managedDiskId = '/s/rg/disks/api-os'; skuName = 'Premium_LRS' }
                        dataDisks = @([pscustomobject]@{ lun = 0; name = 'api-d0'; managedDiskId = '/s/rg/disks/api-d0'; skuName = 'StandardSSD_LRS' }); nics = @() } }
                diskTypeChanges = @([pscustomobject]@{ diskId = '/s/rg/disks/api-d0'; from = 'StandardSSD_LRS'; to = 'Premium_LRS'; by = 'move'; utc = '2026-09-29T10:00:00Z' })
                restore = [pscustomobject]@{ fromCopy = $copy; sizeAfter = 'Standard_D2s_v6'; diskNaming = 'new'; newDiskName = 'api-os-r'; diskIdChanged = $true
                    dataDisks = @([pscustomobject]@{ lun = 0; previousDiskId = '/s/rg/disks/api-d0'; previousDiskName = 'api-d0'; newDiskId = '/s/rg/disks/api-d0-r'; newDiskName = 'api-d0-r' }) } }
        }
        $rows = InModuleScope VmMigrationFactory -Parameters @{ a = (Complete-VmfTestCapture (& $mk 'prepared')); b = (Complete-VmfTestCapture (& $mk 'pristine')) } { param($a, $b) @(Get-VmfIacChangeRows -StateDocs @($a, $b)) }
        $rows[0].disks | Should -Match 'api-d0: .* to Premium SSD'
        $rows[1].disks | Should -Not -Match 'api-d0: '
    }
    It 'the state sample holds a restore with data disks, at the version the store writes' {
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
        $sample.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion })
        @($sample.restore.dataDisks).Count | Should -BeGreaterThan 0
        @($sample.restore.dataDisksKept).Count | Should -BeGreaterThan 0
    }
}

# RESTORE-THROW-STARTS-1: a data disk swap that threw put the LUNs it could not
# prove on the kept list, with a failure. The restore then saw no disk left to
# swap and STARTED the machine: its OS disk from the copy, a data disk that
# nobody read. Every LUN the restore cannot prove is back now goes on the list
# of disks left, so the machine stays stopped and Finish the restore reads
# Azure for it. Only a disk kept by design stays on the kept list.
Describe 'RESTORE-THROW-STARTS-1: a data disk the restore cannot prove is back is left, never kept' {
    BeforeAll {
        $script:rtsRg = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
        function Global:RtsRow([int]$Lun, [switch]$Preserve) {
            $r = [pscustomobject]@{ lun = $Lun; name = "vm1-d$Lun"; sourceDiskId = "$($script:rtsRg)/disks/vm1-d$Lun"; snapshotId = "$($script:rtsRg)/snapshots/pristine-d$Lun"
                skuName = 'Premium_LRS'; diskName = "vm1-d$Lun-d$Lun-restored-s"; currentId = "$($script:rtsRg)/disks/vm1-d$Lun"; currentName = "vm1-d$Lun"
                currentResourceGroup = 'rg-app'; tempName = $(if ($Preserve) { "vm1-d$Lun-d$Lun-rtmp-s" } else { $null }); encryption = [pscustomobject]@{ type = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
            $r
        }
        function Global:RtsSwap([int]$Lun, [switch]$InstantAccess) {
            [pscustomobject]@{ lun = $Lun; diskId = "$($script:rtsRg)/disks/vm1-d$Lun-d$Lun-restored-s"; diskName = "vm1-d$Lun-d$Lun-restored-s"; name = "vm1-d$Lun"
                instantAccess = [bool]$InstantAccess; caching = $(if ($InstantAccess) { 'None' } else { $null }); snapshotId = "$($script:rtsRg)/snapshots/pristine-d$Lun" }
        }
        function Global:RtsRestore {
            param([string]$Naming, $Plan, $Made, [hashtable]$TempMade = @{}, [hashtable]$AlreadyOnTemp = @{})
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rtsRp; id = "$($script:rtsRg)/virtualMachines/vm1"; n = $Naming; pl = $Plan; m = $Made; t = $TempMade; o = $AlreadyOnTemp } {
                param($rp, $id, $n, $pl, $m, $t, $o)
                $c = [pscustomobject]@{ RunPath = $rp; VmId = $id; Rg = 'rg-app' }
                $progress = @{}
                $res = Invoke-VmfOperatorDataRestore -Context $c -VmName 'vm1' -Plan $pl -Naming $n -Location 'centralus' -Made $m -TempMade $t -AlreadyOnTemp $o -Progress $progress
                $res
            }
        }
    }
    AfterAll { Remove-Item function:RtsRow, function:RtsSwap, function:RtsRestore -ErrorAction SilentlyContinue }
    BeforeEach {
        $script:rtsRp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rts-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rtsRp; id = "$($script:rtsRg)/virtualMachines/vm1" } {
            param($rp, $id)
            Initialize-VmfRun -RunPath $rp -RunId 'rts' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rts' -VmId $id -Wave 'w1' | Out-Null
        }
        $global:rts = @{ swaps = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "$($script:rtsRg)/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
    }
    AfterEach {
        if ($script:rtsRp -and (Test-Path $script:rtsRp)) { Remove-Item $script:rtsRp -Recurse -Force }
        Remove-Variable rts -Scope Global -ErrorAction SilentlyContinue
    }

    It 'new names, and Azure cannot be read after the swap threw: each LUN of the batch AND of the later batch is left with the disk that waits, and none is kept' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { foreach ($s in $Swaps) { $global:rts.swaps.Add([string]$s.diskName) }; throw 'The data disks are neither swapped nor as they were.' }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { throw 'Azure did not answer the read.' }
        # LUN 1 is a Premium SSD v2 disk, so it is in the second batch (SAFETY-ULTRA-1).
        $byDesign = [pscustomobject]@{ lun = 5; name = 'added-later'; why = 'No copy of it is on record.' }
        $res = RtsRestore -Naming 'new' -Plan @{ Restore = @((RtsRow 0), (RtsRow 1)); Kept = @($byDesign) } -Made @{ Swaps = @((RtsSwap 0), (RtsSwap 1 -InstantAccess)); Kept = @($byDesign) }
        @($global:rts.swaps) | Should -Not -Contain 'vm1-d1-d1-restored-s' -Because 'the restore stops at the swap that threw'
        @($res.Kept | ForEach-Object { [int]$_.lun }) | Should -Be @(5) -Because 'only a disk kept by design is on the kept list'
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0, 1)
        $l0 = @($res.Left) | Where-Object lun -EQ 0
        $l0.diskName | Should -Be 'vm1-d0-d0-restored-s'
        ($l0.oldDiskId -split '/')[-1] | Should -Be 'vm1-d0'
        $l0.snapshotId | Should -BeLike '*/snapshots/pristine-d0' -Because 'Finish the restore proves a disk for an empty LUN by its copy'
        $l0.why | Should -Match 'could not read'
        $l1 = @($res.Left) | Where-Object lun -EQ 1
        $l1.diskName | Should -Be 'vm1-d1-d1-restored-s'
        $l1.instantAccess | Should -BeTrue
        $l1.why | Should -Match 'stopped at an earlier data disk swap'
        @($res.Unread) | Should -Be @(0) -Because 'LUN 0 is the LUN nobody read; LUN 1 was not touched'
        # FINISH-EMPTY-LUN-WORDS-1: the record says what is on each LUN.
        $l0.lunHolds | Should -Be 'notRead'
        $l1.lunHolds | Should -Be 'had' -Because 'the restore did not touch LUN 1'
        @($res.Refused) | Should -BeNullOrEmpty -Because 'Azure refused no swap: one threw, and the later one was not sent'
    }

    It 'new names, and a LUN holds a disk that is neither the one it had nor the one made from its copy: that LUN is left too, and the other LUN goes on as a swap that took' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { throw 'The data disks are neither swapped nor as they were.' }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            @([pscustomobject]@{ lun = 0; id = "$($script:rtsRg)/disks/someone-elses"; name = 'someone-elses' },
              [pscustomobject]@{ lun = 1; id = "$($script:rtsRg)/disks/vm1-d1-d1-restored-s"; name = 'vm1-d1-d1-restored-s' })
        }
        $res = RtsRestore -Naming 'new' -Plan @{ Restore = @((RtsRow 0), (RtsRow 1)); Kept = @() } -Made @{ Swaps = @((RtsSwap 0), (RtsSwap 1)); Kept = @() }
        @($res.Kept) | Should -BeNullOrEmpty
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        (@($res.Left) | Where-Object lun -EQ 0).why | Should -Match "someone-elses"
        @($res.Replaced | ForEach-Object { [int]$_.lun }) | Should -Be @(1)
        @($res.Unread) | Should -BeNullOrEmpty -Because 'the product read both LUNs'
        @($res.Other) | Should -Be @(0)
        (@($res.Left) | Where-Object lun -EQ 0).name | Should -Be 'vm1-d0' -Because 'name stays the disk the LUN had'
        (@($res.Left) | Where-Object lun -EQ 0).lunHolds | Should -Be 'other'
    }

    It 'keeping the names, the swap onto the disk under the old name throws and Azure cannot be read: the LUN is left with that disk and the temporary disk, and never kept' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            foreach ($s in $Swaps) { $global:rts.swaps.Add([string]$s.diskName) }
            if (@($Swaps | Where-Object { $_.diskName -eq 'vm1-d0' }).Count) { $global:rts.readFail = $true; throw 'The data disks are neither swapped nor as they were.' }
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { if ($global:rts.readFail) { throw 'Azure did not answer the read.' }; @() }
        $temp0 = "$($script:rtsRg)/disks/vm1-d0-d0-rtmp-s"
        $res = RtsRestore -Naming 'preserve' -Plan @{ Restore = @((RtsRow 0 -Preserve)); Kept = @() } -Made $null -TempMade @{ 0 = $temp0 }
        @($global:rts.swaps) | Should -Be @('vm1-d0-d0-rtmp-s', 'vm1-d0')
        @($res.Kept) | Should -BeNullOrEmpty -Because 'a LUN nobody read is not a disk kept by design'
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        $l0 = @($res.Left)[0]
        $l0.diskName | Should -Be 'vm1-d0'
        ($l0.diskId -split '/')[-1] | Should -Be 'vm1-d0'
        $l0.oldDiskId | Should -Be $temp0 -Because 'the LUN ran on its temporary disk before this swap'
        # FINISH-EMPTY-LUN-WORDS-1 and FINISH-TEMP-DISK-LEFT-1: the disk the LUN
        # had is the temporary disk, named so, and the LUN was not read.
        $l0.name | Should -Be 'vm1-d0-d0-rtmp-s'
        $l0.oldTemporary | Should -BeTrue
        $l0.temporary | Should -BeFalse
        $l0.lunHolds | Should -Be 'notRead'
        $l0.snapshotId | Should -BeLike '*/snapshots/pristine-d0'
        $res.Failure | Should -Match 'LUN 0'
        @($res.Unread) | Should -Be @(0)
    }

    It 'the words for a LUN nobody read say so, never that the LUN keeps its disk; a LUN found empty since is said as empty' {
        $rows = @(
            [pscustomobject]@{ lun = 0; name = 'vm1-d0'; diskName = 'vm1-d0-new'; why = 'x' },
            [pscustomobject]@{ lun = 1; name = 'vm1-d1'; diskName = 'vm1-d1-new'; why = 'refused' },
            [pscustomobject]@{ lun = 2; name = 'vm1-d2'; diskName = 'vm1-d2-new'; why = 'LUN 2 has no disk.' })
        $w = InModuleScope VmMigrationFactory -Parameters @{ r = $rows } { param($r) Format-VmfRestoreSwapLeftWords -Swaps $r -EmptyLuns @(2) -Unread @(0, 2) }
        $w | Should -Match "did not read which disk is on these LUNs after it: LUN 0, where the disk 'vm1-d0-new' made from its copy waits to go on\."
        $w | Should -Not -Match "LUN 0 keeps"
        $w | Should -Match "LUN 1 keeps 'vm1-d1', not the disk 'vm1-d1-new'"
        $w | Should -Match "LUN 2 has no disk, and the disk 'vm1-d2-new' made from its copy waits to go on it\." -Because 'a LUN found empty is said as empty, not with the why of the read'
        $w | Should -Not -Match 'LUN 2, where'
    }

    It 'keeping the names, a swap throws and Azure answers the read: <Case>' -ForEach @(
        @{ Case = 'the swap onto the disk under the old name, and the LUN holds its temporary disk - left, said as that disk, not as unread'; Throw = 'vm1-d0'; Holds = 'vm1-d0-d0-rtmp-s'; Outcome = 'left'; Name = 'vm1-d0-d0-rtmp-s'; Third = $false }
        @{ Case = 'the swap onto the temporary disk, and the LUN holds the disk it had - left, said as that disk, not as unread'; Throw = 'vm1-d0-d0-rtmp-s'; Holds = 'vm1-d0'; Outcome = 'left'; Name = 'vm1-d0'; Third = $false }
        @{ Case = 'the swap onto the temporary disk, and the LUN holds a disk nobody named - left with the name of the disk it had, and the why names the other disk'; Throw = 'vm1-d0-d0-rtmp-s'; Holds = 'someone-elses'; Outcome = 'left'; Name = 'vm1-d0'; Third = $true }
        @{ Case = 'the swap onto the disk under the old name, and the LUN holds a disk nobody named - left with the name of the temporary disk it had (FINISH-TEMP-DISK-LEFT-1), and the why names the other disk'; Throw = 'vm1-d0'; Holds = 'someone-elses'; Outcome = 'left'; Name = 'vm1-d0-d0-rtmp-s'; Third = $true }
        @{ Case = 'the swap onto the disk under the old name, and the LUN holds that disk - the swap took'; Throw = 'vm1-d0'; Holds = 'vm1-d0'; Outcome = 'took' }) {
        $global:rts.throw = $Throw
        $global:rts.holds = $Holds
        $global:rts.thrown = $false
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            if (-not $global:rts.thrown -and @($Swaps | Where-Object { $_.diskName -eq $global:rts.throw }).Count) { $global:rts.thrown = $true; throw 'The data disks are neither swapped nor as they were.' }
            @{ Applied = $true }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            if (-not $global:rts.thrown) { return @() }
            @([pscustomobject]@{ lun = 0; id = "$($script:rtsRg)/disks/$($global:rts.holds)"; name = $global:rts.holds })
        }
        $res = RtsRestore -Naming 'preserve' -Plan @{ Restore = @((RtsRow 0 -Preserve)); Kept = @() } -Made $null -TempMade @{ 0 = "$($script:rtsRg)/disks/vm1-d0-d0-rtmp-s" }
        @($res.Kept) | Should -BeNullOrEmpty
        @($res.Unread) | Should -BeNullOrEmpty -Because 'Azure answered the read'
        if ($Outcome -eq 'took') {
            @($res.Left) | Should -BeNullOrEmpty
            @($res.Replaced | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
            return
        }
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        $l0 = @($res.Left)[0]
        $l0.name | Should -Be $Name -Because 'name is the disk the LUN had, which Finish names when it refuses another disk'
        $l0.why | Should -Match "LUN 0 holds the disk '$Holds' now"
        @($res.Other) | Should -Be $(if ($Third) { @(0) } else { @() })
        $l0.lunHolds | Should -Be $(if ($Third) { 'other' } else { 'had' })
        [bool]$l0.oldTemporary | Should -Be ($Throw -eq 'vm1-d0') -Because 'only step 6 leaves a LUN that ran on its temporary disk'
        $w = InModuleScope VmMigrationFactory -Parameters @{ r = @($res.Left); u = @($res.Unread); o = @($res.Other) } { param($r, $u, $o) Format-VmfRestoreSwapLeftWords -Swaps $r -Unread $u -Other $o }
        if ($Third) {
            $w | Should -Match "LUN 0 holds the disk '$Holds' now"
            $w | Should -Not -Match 'LUN 0 keeps'
        }
        else { $w | Should -Match "LUN 0 keeps '$Holds'" }
        $w | Should -Not -Match 'did not read'
    }

    It 'keeping the names, the swap onto the temporary disk throws and Azure cannot be read: the LUN is left with its temporary disk, and said as not read' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:rts.readFail = $true; throw 'The data disks are neither swapped nor as they were.' }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { if ($global:rts.readFail) { throw 'Azure did not answer the read.' }; @() }
        $res = RtsRestore -Naming 'preserve' -Plan @{ Restore = @((RtsRow 0 -Preserve)); Kept = @() } -Made $null -TempMade @{ 0 = "$($script:rtsRg)/disks/vm1-d0-d0-rtmp-s" }
        @($res.Kept) | Should -BeNullOrEmpty
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        @($res.Left)[0].temporary | Should -BeTrue
        @($res.Unread) | Should -Be @(0)
        @($res.Left)[0].lunHolds | Should -Be 'notRead'
        [bool]@($res.Left)[0].oldTemporary | Should -BeFalse
    }

    It 'FINISH-EMPTY-LUN-WORDS-1, <Naming>: a swap Azure refuses on every try - each LUN keeps the disk it had, said so, and the result names it as refused' -ForEach @(
        @{ Naming = 'new' }, @{ Naming = 'preserve' }) {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $false; Reason = 'OperationNotAllowed: the disk is in use' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        $res = if ($Naming -eq 'new') { RtsRestore -Naming 'new' -Plan @{ Restore = @((RtsRow 0)); Kept = @() } -Made @{ Swaps = @((RtsSwap 0)); Kept = @() } }
               else { RtsRestore -Naming 'preserve' -Plan @{ Restore = @((RtsRow 0 -Preserve)); Kept = @() } -Made $null -TempMade @{ 0 = "$($script:rtsRg)/disks/vm1-d0-d0-rtmp-s" } }
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        @($res.Left)[0].lunHolds | Should -Be 'had'
        @($res.Left)[0].name | Should -Be 'vm1-d0'
        @($res.Refused) | Should -Be @(0)
    }

    It 'FINISH-EMPTY-LUN-WORDS-1, a resume: a LUN that holds a disk nobody named is left, said as another disk' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = "$($script:rtsRg)/disks/someone-elses"; name = 'someone-elses' }) }
        $res = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rtsRp; id = "$($script:rtsRg)/virtualMachines/vm1"; pl = @{ Restore = @((RtsRow 0)); Kept = @() }; m = @{ Swaps = @((RtsSwap 0)); Kept = @() } } {
            param($rp, $id, $pl, $m)
            Invoke-VmfResumableDataRestore -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id; Rg = 'rg-app' }) -VmName 'vm1' -Plan $pl -Naming 'new' -Location 'centralus' -Made $m -Progress @{} -Resuming
        }
        @($res.Left | ForEach-Object { [int]$_.lun }) | Should -Be @(0)
        @($res.Left)[0].lunHolds | Should -Be 'other'
    }

    It 'FINISH-EMPTY-LUN-WORDS-1, keeping the names: the restore stops at one LUN, and a later LUN it did not touch is left on its own disk, said so' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { if ($DiskName -eq 'vm1-d0') { throw 'ScopeLocked' } }
        $res = RtsRestore -Naming 'preserve' -Plan @{ Restore = @((RtsRow 0 -Preserve), (RtsRow 1 -Preserve)); Kept = @() } -Made $null `
            -TempMade @{ 0 = "$($script:rtsRg)/disks/vm1-d0-d0-rtmp-s"; 1 = "$($script:rtsRg)/disks/vm1-d1-d1-rtmp-s" }
        $l1 = @($res.Left) | Where-Object lun -EQ 1
        $l1.lunHolds | Should -Be 'had'
        $l1.name | Should -Be 'vm1-d1'
        $l1.temporary | Should -BeTrue
        @($res.Refused) | Should -BeNullOrEmpty
    }
    It 'keeping the names, the restore stops at one LUN: a later LUN already on its temporary disk is kept, and its reason says it runs on that disk, made from the copy' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { if ($DiskName -eq 'vm1-d0') { throw 'ScopeLocked' } }
        $res = RtsRestore -Naming 'preserve' -Plan @{ Restore = @((RtsRow 0 -Preserve), (RtsRow 1 -Preserve)); Kept = @() } -Made $null `
            -AlreadyOnTemp @{ 0 = "$($script:rtsRg)/disks/vm1-d0-d0-rtmp-s"; 1 = "$($script:rtsRg)/disks/vm1-d1-d1-rtmp-s" }
        @($res.Left) | Should -BeNullOrEmpty
        $k1 = @($res.Kept) | Where-Object lun -EQ 1
        $k1.why | Should -Match "runs on the temporary disk 'vm1-d1-d1-rtmp-s', made from the copy"
    }
}

Describe 'RESTORE-THROW-STARTS-1: the restore''s words for a LUN that holds a third disk' {
    BeforeEach { RaMocks; $script:rp = RaRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable ra -Scope Global -ErrorAction SilentlyContinue }

    It 'new names, a swap throws and LUN 0 holds a disk nobody named; then <Then>: the machine stays stopped, and the words name that disk, never a disk LUN 0 keeps' -ForEach @(
        @{ Then = 'Azure answers the read before the start'; FailLater = $false }
        @{ Then = 'no later read answers'; FailLater = $true }) {
        $global:ra.reads = 0
        $global:ra.failLater = $FailLater
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { throw 'The data disks are neither swapped nor as they were.' }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo {
            $global:ra.reads++
            if ($global:ra.reads -eq 1) { return (Global:RaLive) }
            if ($global:ra.reads -gt 2 -and $global:ra.failLater) { throw 'Azure did not answer the read.' }
            @([pscustomobject]@{ lun = 0; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/someone-elses'; name = 'someone-elses'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' },
              @(Global:RaLive)[1])
        }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_.Exception.Message }
        @($global:ra.calls) | Should -Not -Contain 'start'
        $err | Should -Match 'left STOPPED'
        $err | Should -Match "LUN 0 holds the disk 'someone-elses' now"
        $err | Should -Not -Match 'LUN 0 keeps'
        $row0 = @((RaRecord $script:rp).swapPending.swaps) | Where-Object lun -EQ 0
        $row0.name | Should -Be 'vm1-d0' -Because 'the record names the disk the LUN had'
    }
}
# RESTORE-INLOOP-TEMP-1: keeping the names, the stopped window made the
# temporary disk of a LUN that had none. When the product could not read
# whether the disk is shared, or Azure did not make the temporary disk, the
# LUN went on the kept list - and a kept LUN lets the machine start: its OS
# disk from the copy, that data disk as it is now. Every temporary disk is
# made before the stop now, and a LUN without one is refused before any
# change: before the stop, or, if the stopped window is ever given one, there
# before any data disk changes, and the machine stays stopped.
Describe 'RESTORE-INLOOP-TEMP-1: keeping the names, every temporary disk exists before the machine stops' {
    BeforeEach { RaMocks; $script:rp = RaRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable ra -Scope Global -ErrorAction SilentlyContinue }

    It 'Restore this machine, and <Case>: the restore stops before it stops the machine, and no data disk is swapped' -ForEach @(
        @{ Case = 'the product cannot read whether the disk on LUN 1 is shared'; Fail = 'share'; Expect = "The restore stopped before it changed the machine: the product could not read whether the data disk 'vm1-d1-d1-asitwas-202609291830' on LUN 1 is shared: AuthorizationFailed The machine is as it was before the restore." }
        @{ Case = 'Azure does not make the temporary disk of LUN 1'; Fail = 'make'; Expect = '*stopped before it changed the machine*LUN 1*' }) {
        $global:ra.fail = $Fail
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ($global:ra.fail -eq 'share' -and $DiskId -match 'vm1-d1') { throw 'AuthorizationFailed' }; 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            if ($global:ra.fail -eq 'make' -and $DiskName -match '^vm1-d1-d1-rtmp-') { throw 'Azure did not make the disk.' }
            $global:ra.made.Add([pscustomobject]@{ rg = $ResourceGroupName; name = $DiskName; snap = $SnapshotId; sku = $SkuName; zone = $Zone })
            $global:ra.calls.Add("make:$DiskName"); "/disks/$DiskName" }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage $Expect
        @($global:ra.calls) | Should -Not -Contain 'stop'
        @($global:ra.calls) | Should -Not -Contain 'start'
        @($global:ra.calls | Where-Object { $_ -like 'swapData:*' -or $_ -like 'swapOs:*' -or $_ -like 'delete:*' }) | Should -BeNullOrEmpty
    }

    # RESTORE-SHARE-READ-WORDS-1: the sharing read comes before any disk is
    # made, so a refused read leaves the machine as it was - and the words say
    # so, and name the disk and its LUN.
    It 'Restore this machine, and the sharing read of LUN 1 is refused: no disk is made, the machine is not stopped, and the words name the disk and the LUN' -ForEach @(
        @{ Naming = 'preserve' }
        @{ Naming = 'new' }) {
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { if ($DiskId -match 'vm1-d1') { throw 'AuthorizationFailed: the client has no read access to the disk.' }; 1 }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming $Naming -AcceptPreserveRisk -Confirm:$false 3>$null } catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $msg = $err.Exception.Message
        $msg | Should -BeLike 'The restore stopped before it changed the machine: *'
        $msg | Should -BeLike "*could not read whether the data disk 'vm1-d1-d1-asitwas-202609291830' on LUN 1 is shared: AuthorizationFailed: the client has no read access to the disk.*"
        $msg | Should -BeLike '* The machine is as it was before the restore.'
        $msg | Should -Not -BeLike '*LUN 0*' -Because 'the read of LUN 0 passed'
        @($global:ra.made) | Should -BeNullOrEmpty -Because 'the read comes before any disk is made'
        @($global:ra.calls) | Should -Not -Contain 'stop'
        @($global:ra.calls | Where-Object { $_ -like 'size:*' -or $_ -like 'swap*' -or $_ -like 'delete:*' -or $_ -like 'type:*' }) | Should -BeNullOrEmpty
    }
    It 'Restore this machine: a data disk that New-VmfOperatorTempDataDisks neither made nor kept stops the restore before the stop - it never vanishes from the restore' {
        Mock -ModuleName VmMigrationFactory New-VmfOperatorTempDataDisks {
            $r0 = @($Plan.Restore) | Where-Object { [int]$_.lun -eq 0 } | Select-Object -First 1
            @{ Temp = @{ 0 = "/disks/$($r0.tempName)" }; Kept = @() }
        }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw -ExpectedMessage "*stopped before it changed the machine*'vm1-d1-d1-asitwas-202609291830' on LUN 1*"
        @($global:ra.calls) | Should -Not -Contain 'stop'
        @($global:ra.calls) | Should -Not -Contain 'start'
    }

    It 'Restore this machine: a disk New-VmfOperatorTempDataDisks finds shared is left by design, and the others are restored' {
        Mock -ModuleName VmMigrationFactory New-VmfOperatorTempDataDisks {
            $r0 = @($Plan.Restore) | Where-Object { [int]$_.lun -eq 0 } | Select-Object -First 1
            $r1 = @($Plan.Restore) | Where-Object { [int]$_.lun -eq 1 } | Select-Object -First 1
            @{ Temp = @{ 0 = "/disks/$($r0.tempName)" }
               Kept = @([pscustomobject]@{ lun = 1; name = [string]$r1.currentName; shared = $true; refused = $false; why = 'It is a shared disk (maxShares 2), and other machines can use it.' }) }
        }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null | Out-Null
        @($global:ra.calls)[-1] | Should -Be 'start'
        @($global:ra.deleted | Where-Object { $_ -match 'asitwas' }) | Should -BeNullOrEmpty -Because 'the shared disk is left as it is'
        (@((RaRecord $script:rp).restore.dataDisksKept) | Where-Object lun -eq 1).why | Should -Match 'shared disk'
    }
    It 'the stopped window given a LUN with no temporary disk (<Case>): it makes no disk, reads nothing, changes no data disk, and the machine is not started' -ForEach @(
        @{ Case = 'the sharing read fails'; Fail = 'share' }
        @{ Case = 'Azure does not make the disk'; Fail = 'make' }
        @{ Case = 'Azure would make the disk'; Fail = '' }) {
        $global:ra.fail = $Fail
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { $global:ra.calls.Add('readShares'); if ($global:ra.fail -eq 'share') { throw 'AuthorizationFailed' }; 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:ra.calls.Add("make:$DiskName"); if ($global:ra.fail -eq 'make') { throw 'Azure did not make the disk.' }; "/disks/$DiskName" }
        $out = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $plan = Get-VmfOperatorDataRestorePlan -Doc (RaDoc) -Kind 'pristine' -Live (RaLive) -Stamp 's' -Naming 'preserve'
            $r0 = @($plan.Restore) | Where-Object { [int]$_.lun -eq 0 }
            $progress = @{}
            $err = $null
            try {
                $null = Invoke-VmfOperatorDataRestore -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id; Rg = 'rg-app' }) -VmName 'vm1' -Plan $plan -Naming 'preserve' `
                    -Location 'centralus' -Zone '2' -TempMade @{ 0 = "/disks/$($r0.tempName)" } -Progress $progress
            }
            catch { $err = $_ }
            @{ Err = $err; Progress = $progress }
        }
        $out.Err | Should -Not -BeNullOrEmpty -Because 'a LUN with no temporary disk is refused, never kept'
        $out.Err.Exception.Message | Should -Match "LUN 1"
        $out.Err.Exception.Message | Should -Match 'STOPPED'
        $out.Err.Exception.Data['vmfRestoreStranded'] | Should -BeTrue -Because 'the caller must not start the machine'
        @($global:ra.calls | Where-Object { $_ -like 'make:*' -or $_ -eq 'readShares' -or $_ -like 'swapData:*' -or $_ -like 'delete:*' }) | Should -BeNullOrEmpty
        @($global:ra.calls) | Should -Not -Contain 'start'
        $ev = @(Get-Content (Join-Path $script:rp 'logs' 'events.jsonl') | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'fail' })
        $ev.Count | Should -Be 1 -Because 'the refusal is said once, as the end of the restore'
        $ev[0].detail | Should -Match "'/disks/vm1-d0-d0-rtmp-s'|vm1-d0-d0-rtmp-s" -Because 'the temporary disk made before the stop bills, so it is named'
    }
}
