#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }

# STEP-LOG-2 for Restore this machine, in place: a line that cannot be written
# never decides how the restore ends.
#
# REBUILD-REMOVE-RECOVER-1: these tests were in RestoreRebuild.Tests.ps1, with
# the tests of the restore that rebuilt a machine (RESTORE-PB-1). That restore
# is gone with the rebuild around the same disks; the tests of the restore in
# place stay here, on the same machine record. A machine an earlier version
# rebuilt (path B) still restores in place from the second copy.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:nicId = "$($script:sub)/Microsoft.Network/networkInterfaces/vm1-nic"
    $script:crg = "$($script:sub)/Microsoft.Compute/capacityReservationGroups/crg-v6"

    # A Windows machine the move rebuilt, in zone 2, with two data disks. The
    # move put every disk on Premium SSD; the capture recorded Standard HDD.
    function Global:RbDoc {
        param([string]$Path = 'B')
        [pscustomobject]@{
            captured = [pscustomobject]@{
                startedTarget = [pscustomobject]@{ path = $Path; size = 'Standard_D2ds_v6'; controller = 'NVMe' }
                vmConfig = [pscustomobject]@{
                    vmId = $script:vmId; name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Windows'; zones = @('2')
                    osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Standard_LRS'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; deleteOption = 'Detach' }
                    dataDisks = @(
                        [pscustomobject]@{ lun = 0; name = 'vm1-d0'; skuName = 'Standard_LRS'; caching = 'ReadOnly'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"; deleteOption = 'Detach' },
                        [pscustomobject]@{ lun = 1; name = 'vm1-d1'; skuName = 'Standard_LRS'; caching = 'None'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; deleteOption = 'Detach' })
                    nics = @([pscustomobject]@{ id = $script:nicId; primary = $true; acceleratedNetworking = $false })
                    tags = @{} } }
            safety = [pscustomobject]@{
                snapshotId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-prepared"
                pristineSnapshotId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-pristine"
                cloneVmId = $null; locksAllowed = $true; pristineSnapshotLocked = $true
                pristineDataCopies = @(
                    [pscustomobject]@{ lun = 0; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"; snapshotId = '/snap/pristine-d0'; locked = $true },
                    [pscustomobject]@{ lun = 1; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; snapshotId = '/snap/pristine-d1'; locked = $true })
                dataCopies = @(
                    [pscustomobject]@{ lun = 0; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"; snapshotId = '/snap/prepared-d0'; locked = $true },
                    [pscustomobject]@{ lun = 1; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; snapshotId = '/snap/prepared-d1'; locked = $true })
            }
            diskTypeChanges = @(
                [pscustomobject]@{ utc = '2026-09-30T15:00:00Z'; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move' },
                [pscustomobject]@{ utc = '2026-09-30T15:00:05Z'; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move' },
                [pscustomobject]@{ utc = '2026-09-30T15:00:09Z'; diskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; from = 'Standard_LRS'; to = 'Premium_LRS'; by = 'move' })
        }
    }
    # The data disks on the machine now: the captured two, and a third that
    # somebody attached after the move, which the record does not know.
    function Global:RbLive {
        @([pscustomobject]@{ lun = 0; id = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"; name = 'vm1-d0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' },
          [pscustomobject]@{ lun = 1; id = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; name = 'vm1-d1'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' },
          [pscustomobject]@{ lun = 5; id = "$($script:sub)/Microsoft.Compute/disks/added-later"; name = 'added-later'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' })
    }
    # The machine as Azure has it now, as the capture function reads it.
    function Global:RbNow {
        [ordered]@{
            vmId = $script:vmId; name = 'vm1'; size = 'Standard_D2ds_v6'; controller = 'NVMe'; location = 'centralus'; osType = 'Windows'; zones = @('2')
            osDisk = [ordered]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; deleteOption = 'Detach' }
            dataDisks = @(
                [ordered]@{ lun = 0; name = 'vm1-d0'; skuName = 'Premium_LRS'; caching = 'ReadOnly'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d0"; deleteOption = 'Detach' },
                [ordered]@{ lun = 1; name = 'vm1-d1'; skuName = 'Premium_LRS'; caching = 'None'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/vm1-d1"; deleteOption = 'Detach' },
                [ordered]@{ lun = 5; name = 'added-later'; skuName = 'Premium_LRS'; caching = 'ReadWrite'; managedDiskId = "$($script:sub)/Microsoft.Compute/disks/added-later"; deleteOption = 'Detach' })
            nics = @([ordered]@{ id = $script:nicId; primary = $true; acceleratedNetworking = $true })
            tags = @{ owner = 'app-team' }
        }
    }

    function Global:RbRun {
        param($Doc = (RbDoc), [switch]$Claim)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rb-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; d = $Doc } {
            param($rp, $id, $d)
            Initialize-VmfRun -RunPath $rp -RunId 'rb' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rb' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            foreach ($f in 'captured', 'safety', 'diskTypeChanges') { $doc | Add-Member -NotePropertyName $f -NotePropertyValue $d.$f -Force }
            $doc.state = 'MIGRATED'
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        if ($Claim) {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; repo = $script:repoRoot } {
                param($rp, $id, $repo)
                $claim = Get-Content (Join-Path $repo 'schemas' 'samples' 'capacity-claim.sample.json') -Raw | ConvertFrom-Json
                $claim | Add-Member -NotePropertyName associatedVmIds -NotePropertyValue @($id) -Force
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/claim-v6.json' -Document $claim
            }
        }
        $rp
    }
    function Global:RbClaimed($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id) $id -in @((Read-VmfStoreJson -RunPath $rp -RelPath 'capacity/claim-v6.json').associatedVmIds) }
    }

    function Global:RbMocks {
        $global:rb = @{ made = [System.Collections.Generic.List[object]]::new(); deleted = [System.Collections.Generic.List[string]]::new()
            calls = [System.Collections.Generic.List[string]]::new(); builds = [System.Collections.Generic.List[object]]::new()
            size = 'Standard_D2ds_v6'; failBuild = 0; failMake = ''; crg = $null; leftAfterFail = $false; leftDeletes = $false; failType = '' }
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $global:rb.calls.Add('exists?'); [bool]$global:rb.leftAfterFail }
        Mock -ModuleName VmMigrationFactory Get-VmfEngineSubscriptionId { '00000000-0000-0000-0000-000000000000' }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            if ($global:rb.failMake -and $DiskName -like $global:rb.failMake) { throw 'Azure did not make it' }
            $global:rb.made.Add([pscustomobject]@{ rg = $ResourceGroupName; name = $DiskName; snap = $SnapshotId; sku = $SkuName; zone = $Zone })
            $global:rb.calls.Add("make:$DiskName"); "$($script:sub)/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'vm1-os'; id = "$($script:sub)/Microsoft.Compute/disks/vm1-os"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { Global:RbLive }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:rb.calls.Add("swapData:$(@($Swaps | ForEach-Object { $_.diskName }) -join ',')"); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:rb.deleted.Add($DiskName); $global:rb.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $global:rb.crg }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { $global:rb.calls.Add('leaveReservation') }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rb.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rb.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:rb.calls.Add("size:$Size"); throw "HTTP 409 - Unable to resize the VM 'vm1' since changing from resource disk to non-resource disk VM size and vice-versa is not allowed." }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rb.calls.Add("swapOs:$DiskName") }
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:rb.calls.Add("an:$Enabled"); $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku {
            $global:rb.calls.Add("type:$(($DiskId -split '/')[-1])=$SkuName")
            if ($global:rb.failType -and $SkuName -eq $global:rb.failType) { throw 'Azure refused the type change' } }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:rb.size }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapture { Global:RbNow }
        # REBUILD-PROPS-1: the restore reads the purchase plan of each OS disk it rebuilds around.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ purchasePlan = $null; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    }
    function Global:RbRecord($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) (Read-VmfStateDoc -RunPath $rp -VmId $id) }
    }
    function Global:RbEvents($rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }
}
AfterAll { Remove-Item function:RbDoc, function:RbLive, function:RbNow, function:RbRun, function:RbClaimed, function:RbMocks, function:RbRecord, function:RbEvents -ErrorAction SilentlyContinue }

Describe 'REBUILD-REMOVE-RECOVER-1: the second copy of a machine an earlier version rebuilt' {
    BeforeEach { RbMocks; $script:rp = RbRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable rb -Scope Global -ErrorAction SilentlyContinue }

    It 'restores in place, as before: no definition is deleted or made' {
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        $global:rb.calls | Should -Not -Contain 'deleteShell'
        @($global:rb.builds).Count | Should -Be 0
        $global:rb.calls | Should -Contain 'start'
    }
}

Describe 'STEP-LOG-2: a restore line that cannot be written never decides how the restore ends' {
    # Each line below is written after the restore made a disk, stopped the
    # machine or deleted its definition. A line that could not be written went
    # to the restore's own catch: it started the machine part way through, or
    # rebuilt it as it was, and reported a restore that worked as failed.
    BeforeEach { RbMocks; $script:rp = RbRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable rb -Scope Global -ErrorAction SilentlyContinue }

    It 'in place: the lines after the reservation is left and the size is back fail, and the machine starts once, restored' {
        # ROLLBACK-CRG-1: the capture says the machine was in no group, so
        # the group it is in now is left.
        $inPlace = RbDoc -Path 'A'
        $inPlace.captured.vmConfig | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $null -Force
        $script:rp = RbRun -Doc $inPlace
        $global:rb.crg = $script:crg
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:rb.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Detail -like 'The machine left the capacity reservation group*' -or $Detail -like 'The machine is back on*' } { throw 'The store did not answer.' }
        $r = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false -WarningAction SilentlyContinue
        $r.NewDiskName | Should -Match '^vm1-os-restored-\d{12}$'
        @($global:rb.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        $global:rb.calls | Should -Contain "swapOs:$($r.NewDiskName)"
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Detail -like 'The machine left the capacity reservation group*' -or $Detail -like 'The machine is back on*' } -Times 2 -Exactly
    }

    It 'the data disks: the line after they are swapped fails, and the restore ends restored, not started part way' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Detail -like 'The data disks were restored*' } { throw 'The store did not answer.' }
        $r = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue
        @($r.DataDisks).Count | Should -Be 2
        @($global:rb.calls | Where-Object { $_ -eq 'start' }).Count | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Detail -like 'The data disks were restored*' } -Times 1 -Exactly
    }

    It 'the line that names the disks made before the stop fails, and the restore goes on' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Detail -like 'The restore made the disks*' } { throw 'The store did not answer.' }
        $r = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue
        $r.NewDiskName | Should -Match '^vm1-os-restored-\d{12}$'
        $global:rb.calls | Should -Contain 'stop'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Detail -like 'The restore made the disks*' } -Times 1 -Exactly
    }

    It 'the last line fails: a restore that worked is not reported as failed' {
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue
        $r.NewDiskName | Should -Match '^vm1-os-restored-\d{12}$'
        (RbRecord $script:rp).restore | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'ok' } -Times 1 -Exactly
    }

    It 'a restore that failed and started the machine again says it runs, not that it is DOWN, when its line fails' {
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { throw 'The agent did not answer.' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'warn' } { throw 'The store did not answer.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*The machine has been restarted*'
        $err | Should -Not -BeLike '*DOWN*'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'warn' } -Times 1 -Exactly
    }

    # MANUAL-REVIEW-1: the words say the machine is stopped, in a sentence, not DOWN in capitals.
    It 'a machine that could not be started again: the error says it is stopped, not that the store did not answer' {
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rb.calls.Add('start'); throw 'Azure refused the start' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*Azure did not start the machine. The machine is stopped.*'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }

    It 'a disk Azure will not make: the error names the disk kept, not the store' {
        $global:rb.failMake = 'vm1-d1-*'
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*The restore stopped before it changed the machine*'
        $global:rb.calls | Should -Not -Contain 'stop'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }

    It 'a stop Azure refuses after the disks are made: the error names the disks, not the store' {
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rb.calls.Add('stop'); throw 'Azure refused the stop' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*could not stop the machine*'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }

    It 'a restore that stopped with a LUN empty says so, not that the store did not answer, when its fail line cannot be written' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rb.calls.Add("swapOs:$DiskName"); throw 'Azure refused the swap' }
        Mock -ModuleName VmMigrationFactory Get-VmfEmptyDataLuns { @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; id = "$($script:sub)/Microsoft.Compute/disks/vm1-d0" }) }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } { throw 'The store did not answer.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false -WarningAction SilentlyContinue } catch { $err = $_.Exception.Message }
        $err | Should -BeLike '*the machine is left STOPPED: LUN 0 has no disk*'
        $global:rb.calls | Should -Not -Contain 'start'
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'restore' -and $Outcome -eq 'fail' } -Times 1 -Exactly
    }
}
