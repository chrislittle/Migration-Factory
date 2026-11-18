#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# SAFETY-ALL-1: a safety copy of every disk, and a put-back of every disk.
#
# Every screen said "Snapshot of every disk before anything is changed"; the
# engine copied the OS disk only. A put-back returned the OS disk to its copy
# while the data disks kept what was written after it, and nothing could bring
# back a data disk the move damaged. Since 2026-09-29: copy every disk, put
# every disk back.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"

    # A run with one machine: OS disk and two data disks (Premium SSD, and one
    # Premium SSD v2), in zone 2.
    # -Data1Premium (SAFETY-ULTRA-MARGIN-1): the second data disk is Premium SSD,
    # so a put-back test is not stopped by the old record's Premium SSD v2 disk,
    # whose values are not on record - that case refuses the put-back now.
    function Global:SadNewRun([string]$Path = 'A', [switch]$WithCopies, [switch]$NoData, [switch]$Data1Premium) {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sad-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; with = [bool]$WithCopies; noData = [bool]$NoData; d1p = [bool]$Data1Premium } {
            param($rp, $id, $sub, $with, $noData, $d1p)
            Initialize-VmfRun -RunPath $rp -RunId 'sad' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'sad' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $data = if ($noData) { @() } else { @(
                [pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS' }
                [pscustomobject]@{ name = 'vm1-data1'; lun = 1; managedDiskId = "$sub/disks/vm1-data1"; caching = 'None'; sizeGB = 256; skuName = $(if ($d1p) { 'Premium_LRS' } else { 'PremiumV2_LRS' }) }) }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'
                        zones = @('2')
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk" }
                        dataDisks = $data; nics = @(); tags = @{} } }) -Force
            $safety = [pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true }
            if ($with) {
                $safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue "$sub/snapshots/vm1-pristine" -Force
                $safety | Add-Member -NotePropertyName pristineSnapshotLocked -NotePropertyValue $true -Force
                $safety | Add-Member -NotePropertyName pristineDataCopies -NotePropertyValue @(
                    [pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0"; snapshotId = "$sub/snapshots/vm1-pristine-d0"; locked = $true }
                    [pscustomobject]@{ lun = 1; diskId = "$sub/disks/vm1-data1"; snapshotId = "$sub/snapshots/vm1-pristine-d1"; locked = $true }) -Force
            }
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        $rp
    }
    function Global:SadCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            $plan = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'
                target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{ safetyCopy = 'pristine' } }
            New-VmfContext -PlanEntry $plan -RunPath $rp -RunId 'sad'
        }
    }
    function Global:SadDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:SadLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
}
AfterAll { Remove-Item function:SadNewRun, function:SadCtx, function:SadDoc, function:SadLog -ErrorAction SilentlyContinue }

Describe 'SAFETY-ALL-1: every data disk is copied, at the same stopped moment' {
    BeforeEach {
        # ROLLBACK-DISKS-FIRST-1: the rollback disks, made at the end of
        # SAFETY_PRISTINE, are the subject of RollbackDisksBeforeMove.Tests.ps1; here the copies are.
        Mock -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove { $null }
        $global:sad = @{ calls = [System.Collections.Generic.List[string]]::new() }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:sad.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:sad.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfSafetyCopyTags { @{ vmfSafetyCopy = 'true' } }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:sad.calls.Add("snap:$SnapshotName<-$(($OsDiskId -split '/')[-1])"); "/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { $global:sad.calls.Add("lock:$(($SnapshotId -split '/')[-1])") }
        # SAFETY-ULTRA-1: the first copy of the Premium SSD v2 disk is an
        # instant access copy, and Azure says it is usable at once (measured).
        Mock -ModuleName VmMigrationFactory New-VmfInstantAccessSnapshot { $global:sad.calls.Add("snap:$SnapshotName<-$(($DiskId -split '/')[-1])"); "/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { [pscustomobject]@{ snapshotAccessState = 'InstantAccess'; completionPercent = 10; instantAccessDurationMinutes = 300; timeCreated = (Get-Date).ToUniversalTime().ToString('o') } }
        Mock -ModuleName VmMigrationFactory Get-VmfPowerState { 'PowerState/deallocated' }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sad -Scope Global -ErrorAction SilentlyContinue }

    It 'the pristine step copies the OS disk and both data disks while the machine is stopped, and locks each' {
        $script:rp = SadNewRun
        $ctx = SadCtx $script:rp
        InModuleScope VmMigrationFactory -Parameters @{ c = $ctx } { param($c) Invoke-VmfStepSafetyPristine -Context $c } | Out-Null
        $calls = @($global:sad.calls)
        $calls | Should -Contain 'snap:vm1-vmf-sad-pristine<-vm1-osdisk'
        $calls | Should -Contain 'snap:vm1-vmf-sad-pristine-d0<-vm1-data0'
        $calls | Should -Contain 'snap:vm1-vmf-sad-pristine-d1<-vm1-data1'
        @($calls | Where-Object { $_ -like 'lock:*' }).Count | Should -Be 3
        [array]::IndexOf($calls, 'stop') | Should -Be 0
        $calls[-1] | Should -Be 'start' -Because 'the machine starts only after every copy is taken'
        $doc = SadDoc $script:rp
        @($doc.safety.pristineDataCopies).Count | Should -Be 2
        @($doc.safety.pristineDataCopies | Where-Object { $_.locked -eq $true }).Count | Should -Be 2
        $doc.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion })
    }

    It 'a resume after the OS copy takes only what is missing - stopped first, and the OS disk not copied twice' {
        $script:rp = SadNewRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue '/snapshots/os' -Force
            $doc.safety | Add-Member -NotePropertyName pristineSnapshotLocked -NotePropertyValue $true -Force
            $doc.safety | Add-Member -NotePropertyName pristineDataCopies -NotePropertyValue @([pscustomobject]@{ lun = 1; diskId = 'd1'; snapshotId = '/snapshots/d1'; locked = $true }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } | Out-Null
        $calls = @($global:sad.calls)
        $calls[0] | Should -Be 'stop'
        @($calls | Where-Object { $_ -like 'snap:*' }) | Should -Be @('snap:vm1-vmf-sad-pristine-d0<-vm1-data0')
        $calls[-1] | Should -Be 'start'
    }

    It 'a copy on record but not yet locked is asked for again by its name, and locked' {
        $script:rp = SadNewRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue '/snapshots/os' -Force
            $doc.safety | Add-Member -NotePropertyName pristineDataCopies -NotePropertyValue @(
                [pscustomobject]@{ lun = 0; diskId = 'd0'; snapshotId = '/snapshots/vm1-vmf-sad-pristine-d0'; locked = $null }
                [pscustomobject]@{ lun = 1; diskId = 'd1'; snapshotId = '/snapshots/d1'; locked = $true }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } | Out-Null
        $global:sad.calls | Should -Contain 'lock:vm1-vmf-sad-pristine-d0'
        (SadDoc $script:rp).safety.pristineDataCopies | Where-Object lun -EQ 0 | ForEach-Object { $_.locked | Should -BeTrue }
    }

    It 'every copy on record: the step takes no copy and stops nothing - it only makes sure the way back is made' {
        # ROLLBACK-DISKS-FIRST-1 changed this on purpose: a resume with every
        # copy on record goes on to make the rollback disks (a
        # complete record makes no call), so the step is no longer a no-op.
        $script:rp = SadNewRun -WithCopies
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c }
        $r.Next | Should -Be 'GUEST_PREP'
        @($global:sad.calls).Count | Should -Be 0 -Because 'no stop, no copy, no lock, no start'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfRollbackDisksBeforeMove -Times 1 -Exactly
    }

    It 'the prepared copy takes every data disk too, recorded apart from the pristine ones' {
        $script:rp = SadNewRun -WithCopies
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyCopy -Context $c } | Out-Null
        $global:sad.calls | Should -Contain 'snap:vm1-vmf-sad-d0<-vm1-data0'
        $global:sad.calls | Should -Contain 'snap:vm1-vmf-sad-d1<-vm1-data1'
        $doc = SadDoc $script:rp
        @($doc.safety.dataCopies).Count | Should -Be 2
        @($doc.safety.pristineDataCopies).Count | Should -Be 2 -Because 'the pristine records are merged, never replaced'
    }

    It 'a machine with no data disks takes its OS copy only, and is complete' {
        $script:rp = SadNewRun -NoData
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } | Out-Null
        @($global:sad.calls | Where-Object { $_ -like 'snap:*' }).Count | Should -Be 1
        InModuleScope VmMigrationFactory -Parameters @{ d = (SadDoc $script:rp) } { param($d) Test-VmfDataCopiesComplete -Doc $d -Kind 'pristine' } | Should -BeTrue
    }

    It 'a data disk''s copy name carries its LUN, before the attempt; the OS copy keeps its name' {
        InModuleScope VmMigrationFactory {
            Get-VmfSafetyCopyName -VmName 'vm1' -RunId 'r' -Kind 'pristine' | Should -Be 'vm1-vmf-r-pristine'
            Get-VmfSafetyCopyName -VmName 'vm1' -RunId 'r' -Kind 'pristine' -Lun 3 | Should -Be 'vm1-vmf-r-pristine-d3'
            Get-VmfSafetyCopyName -VmName 'vm1' -RunId 'r' -Kind 'prepared' -Lun 0 -Attempt 2 | Should -Be 'vm1-vmf-r-d0-a2'
            (Get-VmfSafetyCopyName -VmName ('x' * 90) -RunId 'r' -Kind 'pristine' -Lun 12 -Attempt 3) | Should -Match '-pristine-d12-a3$'
        }
    }

    It 'a resumed prepared copy takes only the data disk that has none' {
        $script:rp = SadNewRun -WithCopies
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety | Add-Member -NotePropertyName dataCopies -NotePropertyValue @([pscustomobject]@{ lun = 1; diskId = 'd1'; snapshotId = '/snapshots/d1'; locked = $true }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyCopy -Context $c } | Out-Null
        @($global:sad.calls | Where-Object { $_ -like 'snap:*-d*' }) | Should -Be @('snap:vm1-vmf-sad-d0<-vm1-data0')
    }

    # SAFETY-ULTRA-1 rewrote this rule on purpose. SAFETY-ALL-1 let the move go
    # on without the copy of a Premium SSD v2 or Ultra Disk, because a put-back
    # left those disks. The put-back now makes them again from that copy, so
    # the FIRST copy is the way back like any other: a refusal stops the move.
    # Only the SECOND copy of these types stays a warning.
    It 'a Premium SSD v2 first copy Azure refuses stops the step: it is the way back now' {
        $script:rp = SadNewRun
        Mock -ModuleName VmMigrationFactory New-VmfInstantAccessSnapshot { throw 'OperationNotAllowed: too many snapshots in progress' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } } | Should -Throw '*too many snapshots*'
        $global:sad.calls | Should -Not -Contain 'start' -Because 'the step stopped; the state machine starts the machine again and says it is untouched'
        InModuleScope VmMigrationFactory -Parameters @{ d = (SadDoc $script:rp) } { param($d) Test-VmfDataCopiesComplete -Doc $d -Kind 'pristine' } | Should -BeFalse
    }

    It 'a Premium SSD v2 SECOND copy Azure refuses is a warning; the step goes on' {
        $script:rp = SadNewRun -WithCopies
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot {
            if ($OsDiskId -like '*vm1-data1') { throw 'OperationNotAllowed: too many snapshots in progress' }
            $global:sad.calls.Add("snap:$SnapshotName"); "/snapshots/$SnapshotName" }
        $r = InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyCopy -Context $c }
        $r.Next | Should -Be 'CONVERTING'
        @((SadDoc $script:rp).safety.dataCopies | ForEach-Object lun) | Should -Be @(0)
        SadLog $script:rp | Should -Match "No second copy of the data disk 'vm1-data1' on LUN 1\. Its disk type is Premium SSD v2"
        InModuleScope VmMigrationFactory -Parameters @{ d = (SadDoc $script:rp) } { param($d) Test-VmfDataCopiesComplete -Doc $d -Kind 'prepared' } | Should -BeTrue
    }

    It 'any other data disk''s copy Azure refuses stops the step: it is the way back' {
        $script:rp = SadNewRun
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot {
            if ($OsDiskId -like '*vm1-data0') { throw 'OperationNotAllowed: refused' }
            "/snapshots/$SnapshotName" }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } } | Should -Throw '*refused*'
    }

}

Describe 'SAFETY-ALL-1: what a put-back restores' {
    It 'every data disk with a copy and a known type; Ultra, Premium SSD v2, no copy and no type are left, each with the reason' {
        $doc = [pscustomobject]@{
            captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ dataDisks = @(
                [pscustomobject]@{ name = 'd0'; lun = 0; skuName = 'Premium_LRS'; managedDiskId = '/disks/d0' }
                [pscustomobject]@{ name = 'd1'; lun = 1; skuName = 'PremiumV2_LRS' }
                [pscustomobject]@{ name = 'd2'; lun = 2; skuName = 'UltraSSD_LRS' }
                [pscustomobject]@{ name = 'd3'; lun = 3; skuName = 'StandardSSD_LRS' }
                [pscustomobject]@{ name = 'd4'; lun = 4 }
                [pscustomobject]@{ name = 'd5'; lun = 5; skuName = 'Premium_LRS'; managedDiskId = '/disks/d5' }) } }
            safety = [pscustomobject]@{ pristineDataCopies = @(
                [pscustomobject]@{ lun = 0; snapshotId = '/s/0'; diskId = '/disks/d0' }, [pscustomobject]@{ lun = 1; snapshotId = '/s/1' },
                [pscustomobject]@{ lun = 2; snapshotId = '/s/2' }, [pscustomobject]@{ lun = 4; snapshotId = '/s/4' },
                [pscustomobject]@{ lun = 5; snapshotId = '/s/5'; diskId = '/disks/other' }) } }
        $null = Complete-VmfTestCapture $doc
        $plan = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDataRestorePlan -Doc $d -Stamp '202609291200' }
        @($plan.Restore | ForEach-Object lun) | Should -Be @(0)
        $plan.Restore[0].diskName | Should -Be 'd0-d0-asitwas-202609291200' -Because 'the LUN keeps two long names apart'
        $plan.Restore[0].skuName | Should -Be 'Premium_LRS'
        $plan.Restore[0].sourceDiskId | Should -Be '/disks/d0'
        # SAFETY-ULTRA-1: a capture with no IOPS, throughput and sector size (a
        # move started before they were recorded) still leaves these disks -
        # now with that reason (SafetyUltra.Tests.ps1 has the disks that go back).
        ($plan.Kept | Where-Object lun -EQ 1).why | Should -Match '^Its disk type is Premium SSD v2, and its IOPS, throughput, sector size are not on record\. '
        ($plan.Kept | Where-Object lun -EQ 1).name | Should -Be 'd1'
        ($plan.Kept | Where-Object lun -EQ 2).why | Should -Match '^Its disk type is Ultra Disk, and its IOPS, throughput, sector size are not on record\. '
        ($plan.Kept | Where-Object lun -EQ 3).why | Should -Match '^No copy'
        ($plan.Kept | Where-Object lun -EQ 4).why | Should -Match 'type is not on record'
        ($plan.Kept | Where-Object lun -EQ 5).why | Should -Match 'of another disk'
    }

    It 'two data disks whose names differ only past the length Azure allows get two names' {
        $long = 'x' * 70
        $doc = [pscustomobject]@{
            captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{ dataDisks = @(
                [pscustomobject]@{ name = "$long-a"; lun = 0; skuName = 'Premium_LRS' }
                [pscustomobject]@{ name = "$long-b"; lun = 1; skuName = 'Premium_LRS' }) } }
            safety = [pscustomobject]@{ pristineDataCopies = @([pscustomobject]@{ lun = 0; snapshotId = '/s/0' }, [pscustomobject]@{ lun = 1; snapshotId = '/s/1' }) } }
        $null = Complete-VmfTestCapture $doc
        $plan = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDataRestorePlan -Doc $d -Stamp '202609291200' }
        $names = @($plan.Restore | ForEach-Object diskName)
        @($names | Select-Object -Unique).Count | Should -Be 2
        $names | ForEach-Object { $_.Length | Should -BeLessOrEqual 80 }
    }
}

Describe 'SAFETY-ALL-1: the put-back puts every disk back, in the machine''s zone' {
    BeforeEach {
        $global:sad = @{ calls = [System.Collections.Generic.List[string]]::new(); created = @{}; swaps = $null; rebuild = $null }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:sad.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:sad.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:sad.calls.Add('size') }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:sad.calls.Add("create:$DiskName"); $global:sad.created[$DiskName] = @{ zone = $Zone; sku = $SkuName; from = $SnapshotId }; "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:sad.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:sad.calls.Add('data'); $global:sad.swaps = @($Swaps); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        # SAFETY-ULTRA-1: the put-back reads each Premium SSD v2 copy first.
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { [pscustomobject]@{ snapshotAccessState = 'InstantAccess'; instantAccessDurationMinutes = 300; timeCreated = (Get-Date).ToUniversalTime().ToString('o') } }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force }; Remove-Variable sad -Scope Global -ErrorAction SilentlyContinue }

    It 'Path A: the OS disk and each data disk are made again in zone 2 from the first copies and swapped in' {
        $script:rp = SadNewRun -WithCopies -Data1Premium
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $os = $global:sad.created.Keys | Where-Object { $_ -like 'vm1-osdisk-asitwas-*' }
        $global:sad.created[$os].zone | Should -Be '2'
        foreach ($l in 0, 1) {
            $d = $global:sad.created.Keys | Where-Object { $_ -like "vm1-data$l-d$l-asitwas-*" }
            $d | Should -Not -BeNullOrEmpty
            $global:sad.created[$d].zone | Should -Be '2'
            $global:sad.created[$d].sku | Should -Be 'Premium_LRS'
            $global:sad.created[$d].from | Should -Match "vm1-pristine-d$l`$"
        }
        @($global:sad.swaps | ForEach-Object lun | Sort-Object) | Should -Be @(0, 1)
        SadLog $script:rp | Should -Match "LUN 0 now uses 'vm1-data0-d0-asitwas-"
    }

    It 'SAFETY-ULTRA-MARGIN-1: an old record whose Premium SSD v2 disk has no values on record stops the rollback before the stop' {
        # Was: that disk was left as it is and the rollback went on, so the
        # machine came back with disks from two moments.
        $script:rp = SadNewRun -WithCopies
        { InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "*'vm1-data1' on LUN 1 (Its disk type is Premium SSD v2, and its IOPS, throughput, sector size are not on record*"
        $global:sad.calls | Should -Not -Contain 'stop'
    }

    It 'Path A: every new disk exists before any disk is swapped, and the machine starts last' {
        $script:rp = SadNewRun -WithCopies -Data1Premium
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:sad.calls)
        $firstSwap = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'os:*' } | Select-Object -First 1))
        $lastCreate = [array]::LastIndexOf($calls, ($calls | Where-Object { $_ -like 'create:*' } | Select-Object -Last 1))
        # ROLLBACK-DISKS-FIRST-1 (rewritten on purpose): every disk is made
        # BEFORE the stop, so the stop follows the last disk made.
        $calls[0] | Should -BeLike 'create:*'
        [array]::IndexOf($calls, 'stop') | Should -Be ($lastCreate + 1) -Because "the calls were: $($calls -join ', ')"
        [array]::IndexOf($calls, 'size') | Should -BeLessThan $firstSwap -Because 'ROLLBACK-ORDER-1: the hardware goes back before the disk'
        $lastCreate | Should -BeLessThan $firstSwap
        [array]::IndexOf($calls, 'data') | Should -BeGreaterThan $firstSwap
        $calls[-1] | Should -Be 'start'
    }

    It 'SAFETY-ULTRA-MARGIN-1, Path A: a data disk Azure will not make stops the rollback before the stop, naming it and Azure''s words' {
        $script:rp = SadNewRun -WithCopies
        Mock -ModuleName VmMigrationFactory Invoke-VmfAzOperation -ParameterFilter { $Name -eq 'rollback:createDataDisk' } { throw 'SnapshotNotFound: the copy is gone' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "*'vm1-data0' on LUN 0*SnapshotNotFound*Every disk is restored from its copy, or the product changes nothing.*"
        $global:sad.calls | Should -Not -Contain 'stop'
        $global:sad.calls | Should -Not -Contain 'data'
        $global:sad.calls | Where-Object { $_ -like 'os:*' } | Should -BeNullOrEmpty -Because 'no disk is swapped'
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    # SWAP-REFUSED-AFTER-STOP-1 rewrote this rule on purpose. A swap Azure
    # refused left the data disks as they were and STARTED the machine - its OS
    # disk from the copy, its data disks not: two moments. The rule since
    # 2026-10-23: every disk goes back. The swap is tried again; still refused,
    # the machine stays stopped and its record names each disk.
    It 'Path A: a data-disk swap Azure refuses on every try leaves the machine stopped, says so, and names each disk' {
        $script:rp = SadNewRun -WithCopies -Data1Premium
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { @{ Applied = $false; Reason = 'OperationNotAllowed' } }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:sad.calls | Should -Not -Contain 'start'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmDataDisks -Times 3 -Exactly -Scope It -Because 'tried three times'
        $log = SadLog $script:rp
        $log | Should -Match "Azure did not swap these data disks back after 3 tries: LUN 0 keeps 'vm1-data0'"
        $log | Should -Match 'The machine is stopped\.'
        @((SadDoc $script:rp).swapPending.swaps | ForEach-Object lun) | Should -Be @(0, 1)
    }

    It 'a shared disk is never swapped for a copy; a disk whose sharing cannot be read stops the rollback (SAFETY-ULTRA-MARGIN-1)' {
        $script:rp = SadNewRun -WithCopies -Data1Premium
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 2 }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:sad.created.Keys | Where-Object { $_ -like 'vm1-data0*' } | Should -BeNullOrEmpty
        SadLog $script:rp | Should -Match "'vm1-data0' on LUN 0 is left as it is\. It is a shared disk \(maxShares 2\)"
        $global:sad.calls | Should -Contain 'start' -Because 'a shared disk is left by design, and the rollback goes on'

        Remove-Item $script:rp -Recurse -Force
        $script:rp = SadNewRun -WithCopies -Data1Premium
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { throw 'AuthorizationFailed' }
        $global:sad.calls.Clear()
        { InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw '*could not read whether other machines share it: AuthorizationFailed*'
        $global:sad.created.Keys | Where-Object { $_ -like 'vm1-data0*' } | Should -BeNullOrEmpty
        $global:sad.calls | Should -Not -Contain 'stop' -Because 'unknown is not "shared"'
    }

    It 'a machine with no data-disk copies on record (taken before this change) puts back the OS disk and says so for each data disk' {
        $script:rp = SadNewRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc.safety | Add-Member -NotePropertyName pristineSnapshotId -NotePropertyValue '/snapshots/os' -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp 'A') } { param($c) Invoke-VmfRollback -Context $c }
        $global:sad.swaps | Should -BeNullOrEmpty
        @($global:sad.created.Keys | Where-Object { $_ -like 'vm1-osdisk-asitwas-*' }).Count | Should -Be 1
    }
}

Describe 'SAFETY-ALL-1: retries and retention find the data-disk copies' {
    It 'retention lists every copy - this attempt''s records and an earlier attempt''s IDs' {
        $doc = [pscustomobject]@{ safety = [pscustomobject]@{
            pristineSnapshotId = '/s/os-p'; snapshotId = '/s/os'
            pristineDataCopies = @([pscustomobject]@{ lun = 0; snapshotId = '/s/d0-p' })
            dataCopies = @([pscustomobject]@{ lun = 0; snapshotId = '/s/d0' })
            earlierCopies = @([pscustomobject]@{ pristineSnapshotId = '/s/old-os-p'; pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = '/d/0'; snapshotId = '/s/old-d0-p'; locked = $true }); dataCopies = @([pscustomobject]@{ lun = 0; diskId = '/d/0'; snapshotId = '/s/old-d0'; locked = $true }) }) } }
        $ids = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfSafetyCopyIds -StateDoc $d }
        foreach ($id in '/s/os-p', '/s/os', '/s/d0-p', '/s/d0', '/s/old-os-p', '/s/old-d0-p', '/s/old-d0') { $ids | Should -Contain $id }
    }

    It 'a person''s retry moves the data-disk copies to the earlier attempt, and the new attempt takes its own' {
        $script:rp = SadNewRun -WithCopies
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt }
        $doc = SadDoc $script:rp
        $doc.safety.PSObject.Properties['pristineDataCopies'] | Should -BeNullOrEmpty
        $earlier = @($doc.safety.earlierCopies)[-1]
        @($earlier.pristineDataCopies).Count | Should -Be 2
        # The same records, so the dashboard still counts them as locked.
        @($earlier.pristineDataCopies | Where-Object { $_.locked -eq $true }).Count | Should -Be 2
        @($earlier.pristineDataCopies.snapshotId) | Should -Contain "$($script:sub)/snapshots/vm1-pristine-d1"
        InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfSafetyAttempt -Doc $d } | Should -Be 2
        Remove-Item $script:rp -Recurse -Force
    }

    It 'the automatic put-back keeps them - it is the way back' {
        $script:rp = SadNewRun -WithCopies
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' }
        @((SadDoc $script:rp).safety.pristineDataCopies).Count | Should -Be 2
        Remove-Item $script:rp -Recurse -Force
    }

}

Describe 'SAFETY-ALL-1 / SWAP-2UPD-1: swapping data disks on a stopped machine' {
    # MEASURED 2026-09-30 on a lab machine: Azure identifies a data disk by its
    # LUN, so ONE update cannot swap one - changing the LUN's disk, or removing
    # it and adding another on the same LUN, is refused as a property change.
    # Detach in one update, attach in a second, works. The mocks below act like
    # Azure: the machine is one object, and an update that changes a LUN's
    # disk or its createOption in place is refused.
    BeforeEach {
        $global:sadVm = [pscustomobject]@{ StorageProfile = [pscustomobject]@{ DataDisks = @(
            [pscustomobject]@{ Lun = 0; Name = 'd0'; CreateOption = 'Empty'; Caching = 'ReadOnly'; DeleteOption = 'Delete'; ManagedDisk = [pscustomobject]@{ Id = '/disks/d0' } }
            [pscustomobject]@{ Lun = 1; Name = 'd1'; CreateOption = 'Attach'; Caching = 'None'; DeleteOption = 'Detach'; ManagedDisk = [pscustomobject]@{ Id = '/disks/d1' } }) } }
        $global:sadLive = @($global:sadVm.StorageProfile.DataDisks | ForEach-Object { "$($_.Lun)=$($_.ManagedDisk.Id)" })
        $global:sadSent = [System.Collections.Generic.List[object]]::new()
        $global:sadRefuseAttach = 0
        Mock -ModuleName VmMigrationFactory Get-AzVM {
            # A fresh copy of what Azure holds, as Get-AzVM returns.
            [pscustomobject]@{ StorageProfile = [pscustomobject]@{ DataDisks = [System.Collections.Generic.List[object]]@($global:sadLive | ForEach-Object {
                $lun, $id = $_ -split '=', 2
                $was = @($global:sadVm.StorageProfile.DataDisks) | Where-Object Lun -EQ ([int]$lun) | Select-Object -First 1
                [pscustomobject]@{ Lun = [int]$lun; Name = ($id -split '/')[-1]; CreateOption = 'Attach'; Caching = $was.Caching; DeleteOption = $was.DeleteOption; WriteAcceleratorEnabled = [bool]$was.WriteAcceleratorEnabled; ManagedDisk = [pscustomobject]@{ Id = $id } } }) } }
        }
        Mock -ModuleName VmMigrationFactory Remove-AzVMDataDisk -RemoveParameterType 'VM' {
            $VM.StorageProfile.DataDisks = @($VM.StorageProfile.DataDisks | Where-Object { $_.Name -notin $DataDiskNames }); $VM }
        Mock -ModuleName VmMigrationFactory Add-AzVMDataDisk -RemoveParameterType 'VM' {
            $VM.StorageProfile.DataDisks = @($VM.StorageProfile.DataDisks) + [pscustomobject]@{ Lun = $Lun; Name = $Name; CreateOption = $CreateOption
                Caching = $Caching; DeleteOption = $DeleteOption; WriteAccelerator = [bool]$WriteAccelerator; ManagedDisk = [pscustomobject]@{ Id = $ManagedDiskId } }
            $VM }
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' {
            $want = @($VM.StorageProfile.DataDisks | ForEach-Object { "$($_.Lun)=$($_.ManagedDisk.Id)" })
            if ($global:sadBusy -gt 0) { $global:sadBusy--; throw 'TooManyRequests: 429, try again later' }
            $global:sadSent.Add(@($VM.StorageProfile.DataDisks | ForEach-Object { [pscustomobject]@{ Lun = $_.Lun; Id = $_.ManagedDisk.Id; Caching = $_.Caching; DeleteOption = $_.DeleteOption; CreateOption = $_.CreateOption; WriteAccelerator = $_.WriteAccelerator } }))
            # Azure: a LUN that stays must keep its disk.
            foreach ($w in $want) { $lun = ($w -split '=')[0]; $had = $global:sadLive | Where-Object { ($_ -split '=')[0] -eq $lun }
                if ($had -and $had -ne $w) { throw "Changing property 'dataDisk.managedDisk.id' is not allowed." } }
            $adding = @($want | Where-Object { $_ -notin $global:sadLive })
            if ($adding.Count -and $global:sadIgnoreAttach -gt 0) { $global:sadIgnoreAttach--; return }
            if ($adding.Count -and $global:sadRefuseAttach -gt 0) { $global:sadRefuseAttach--; throw 'OperationNotAllowed: the disk cannot be attached' }
            if ($adding.Count -gt 1 -and $global:sadPartial) { $global:sadLive = @($global:sadLive) + $adding[0]; throw 'Conflict: part of the update failed' }
            $global:sadLive = $want
            if (-not $adding.Count -and $global:sadDetachThrows) { $global:sadDetachThrows = $false; throw 'Conflict: the operation was cancelled by the client' }
        }
    }
    AfterEach { Remove-Variable sadVm, sadSent, sadLive, sadRefuseAttach, sadPartial, sadBusy, sadIgnoreAttach, sadDetachThrows -Scope Global -ErrorAction SilentlyContinue }

    It 'THE LAB CASE: detach in one update, attach in a second, on the same LUN with the same caching' {
        $r = InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/d0-asitwas'; diskName = 'd0-asitwas' }) }
        $r.Applied | Should -BeTrue
        $global:sadSent.Count | Should -Be 2
        @($global:sadSent[0] | ForEach-Object Lun) | Should -Be @(1) -Because 'the first update detaches LUN 0 and leaves LUN 1'
        $slot = $global:sadSent[1] | Where-Object Lun -EQ 0
        $slot.Id | Should -Be '/disks/d0-asitwas'
        $slot.CreateOption | Should -Be 'Attach'
        $slot.Caching | Should -Be 'ReadOnly'
        $slot.DeleteOption | Should -Be 'Delete'
        ($global:sadSent[1] | Where-Object Lun -EQ 1).Id | Should -Be '/disks/d1'
    }

    It 'several disks: still two updates, not two per disk' {
        $r = InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @(
            [pscustomobject]@{ lun = 0; diskId = '/disks/n0'; diskName = 'n0' }, [pscustomobject]@{ lun = 1; diskId = '/disks/n1'; diskName = 'n1' }) }
        $r.Applied | Should -BeTrue
        $global:sadSent.Count | Should -Be 2
        @($global:sadSent[0]).Count | Should -Be 0
    }

    It 'the attach refused: the old disks go back on their LUNs, and it says so - never a machine with no disk' {
        $global:sadRefuseAttach = 1
        $r = InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) }
        $r.Applied | Should -BeFalse
        $r.Reason | Should -Match 'OperationNotAllowed'
        $global:sadLive | Should -Contain '0=/disks/d0'
        ($global:sadSent[-1] | Where-Object Lun -EQ 0).Caching | Should -Be 'ReadOnly'
    }

    It 'the attach refused and the old disks refused too: an error that says the machine has no disk there' {
        $global:sadRefuseAttach = 2
        { InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) } } |
            Should -Throw '*neither swapped nor as they were*not every old disk is attached again*LUN 0: NO DISK*/disks/d0*Attach each old disk to its LUN*'
    }

    It 'the attach took on one LUN and not the other: an error naming each LUN - that machine is neither' {
        $global:sadPartial = $true
        { InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @(
            [pscustomobject]@{ lun = 0; diskId = '/disks/n0'; diskName = 'n0' }, [pscustomobject]@{ lun = 1; diskId = '/disks/n1'; diskName = 'n1' }) } } |
            Should -Throw '*took on some LUNs and not others*LUN 1: NO DISK*'
    }
    It 'a detach Azure reported as failed but APPLIED is carried on to the attach, not stopped' {
        $global:sadDetachThrows = $true
        $r = InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) }
        $r.Applied | Should -BeTrue
        $global:sadLive | Should -Contain '0=/disks/new'
    }

    It 'an attach Azure accepted and did not act on: the old disks go back, not applied' {
        $global:sadIgnoreAttach = 1
        $r = InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) }
        $r.Applied | Should -BeFalse
        $r.Reason | Should -Match 'did not attach'
        $global:sadLive | Should -Contain '0=/disks/d0'
    }

    It 'a put-back Azure accepted and did not act on: an error naming the empty LUN and its old disk' {
        $global:sadIgnoreAttach = 2
        { InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) } } |
            Should -Throw '*neither swapped nor as they were*LUN 0: NO DISK*/disks/d0*'
    }

    It 'Azure only busy: the update is tried again, and the swap goes through' {
        $global:sadBusy = 2
        $r = InModuleScope VmMigrationFactory {
            Mock Start-Sleep { }
            Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) }
        $r.Applied | Should -BeTrue
    }

    It 'the write accelerator comes back with the disk' {
        $global:sadVm.StorageProfile.DataDisks[0] | Add-Member -NotePropertyName WriteAcceleratorEnabled -NotePropertyValue $true -Force
        InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) } | Out-Null
        ($global:sadSent[-1] | Where-Object Lun -EQ 0).WriteAccelerator | Should -BeTrue
    }

    It 'a swap left neither way is never retried by the operation wrapper' {
        $global:sadCalls = 0
        { InModuleScope VmMigrationFactory {
            Invoke-VmfAzOperation -Name 'rollback:swapDataDisks' -BaseDelayMs 1 -Operation { $global:sadCalls++; throw "$script:VmfSwapNeitherWords ARM reports LUN 0: NO DISK. 503 InternalServerError" } } } |
            Should -Throw '*neither swapped*'
        $global:sadCalls | Should -Be 1
        Remove-Variable sadCalls -Scope Global -ErrorAction SilentlyContinue
    }
    It 'the detach refused: nothing changed, not applied, with Azure''s words' {
        Mock -ModuleName VmMigrationFactory Update-AzVM -RemoveParameterType 'VM' { throw 'Conflict: the machine is busy' }
        $r = InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 0; diskId = '/disks/new'; diskName = 'new' }) }
        $r.Applied | Should -BeFalse
        $r.Reason | Should -Match 'busy'
    }

    It 'a LUN the machine does not have is refused before anything is sent' {
        { InModuleScope VmMigrationFactory { Set-VmfVmDataDisks -ResourceGroupName 'rg' -Name 'vm1' -Swaps @([pscustomobject]@{ lun = 7; diskId = '/disks/x'; diskName = 'x' }) } } |
            Should -Throw '*no data disk on LUN 7*'
        $global:sadSent.Count | Should -Be 0
    }

    It 'never changes a LUN''s disk or createOption in place - the update Azure refuses' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        $fn = [regex]::Match($code, '(?s)function Set-VmfVmDataDisks.*?\n\}').Value
        $fn | Should -Not -Match '\.ManagedDisk\.Id\s*='
        $fn | Should -Not -Match '\.CreateOption\s*='
    }
}
Describe 'SAFETY-ALL-1: a disk made from a copy lands in the zone asked for' {
    It 'passes the zone to the disk, and none when there is none' {
        $global:sadArgs = @()
        Mock -ModuleName VmMigrationFactory Get-AzDisk { $null }
        Mock -ModuleName VmMigrationFactory New-AzDiskConfig { $global:sadArgs += , $PesterBoundParameters; [pscustomobject]@{} }
        Mock -ModuleName VmMigrationFactory New-AzDisk { [pscustomobject]@{ Id = "/disks/$DiskName" } }
        InModuleScope VmMigrationFactory { New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s' -Location 'centralus' -Zone '3' } | Out-Null
        InModuleScope VmMigrationFactory { New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'b' -SnapshotId '/s' -Location 'centralus' } | Out-Null
        @($global:sadArgs[0]['Zone']) | Should -Be @('3')
        $global:sadArgs[1].ContainsKey('Zone') | Should -BeFalse
        Remove-Variable sadArgs -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a zone-redundant disk gets no zone: Azure refuses one on it' {
        $global:sadArgs = @()
        Mock -ModuleName VmMigrationFactory Get-AzDisk { $null }
        Mock -ModuleName VmMigrationFactory New-AzDiskConfig { $global:sadArgs += , $PesterBoundParameters; [pscustomobject]@{} }
        Mock -ModuleName VmMigrationFactory New-AzDisk { [pscustomobject]@{ Id = "/disks/$DiskName" } }
        InModuleScope VmMigrationFactory { New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'z' -SnapshotId '/s' -Location 'centralus' -SkuName 'Premium_ZRS' -Zone '3' } | Out-Null
        $global:sadArgs[0].ContainsKey('Zone') | Should -BeFalse
        Remove-Variable sadArgs -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a disk of that name made from another copy is refused, never used' {
        Mock -ModuleName VmMigrationFactory Get-AzDisk { [pscustomobject]@{ Id = '/disks/a'; CreationData = [pscustomobject]@{ SourceResourceId = '/s/other' } } }
        { InModuleScope VmMigrationFactory { New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s/mine' -Location 'centralus' } } | Should -Throw "*made from '/s/other'*"
        Mock -ModuleName VmMigrationFactory Get-AzDisk { [pscustomobject]@{ Id = '/disks/a'; CreationData = [pscustomobject]@{ SourceResourceId = '/s/mine' } } }
        InModuleScope VmMigrationFactory { New-VmfDiskFromSnapshot -ResourceGroupName 'rg' -DiskName 'a' -SnapshotId '/s/mine' -Location 'centralus' } | Should -Be '/disks/a'
    }
}

Describe 'SAFETY-ALL-1: reading whether a disk is shared' {
    It 'reads maxShares by the disk''s ID; absent means one machine' {
        $id = "$($script:sub)/disks/d0"
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{"maxShares":3}}' } }
        InModuleScope VmMigrationFactory -Parameters @{ id = $id } { param($id) Get-VmfDiskShareCount -DiskId $id } | Should -Be 3
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { $Path -like "$id`?api-version=*" -and $Method -eq 'GET' }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"properties":{}}' } }
        InModuleScope VmMigrationFactory -Parameters @{ id = $id } { param($id) Get-VmfDiskShareCount -DiskId $id } | Should -Be 1
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 403; Content = 'AuthorizationFailed' } }
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id } { param($id) Get-VmfDiskShareCount -DiskId $id } } | Should -Throw '*403*'
        { InModuleScope VmMigrationFactory { Get-VmfDiskShareCount -DiskId 'd0' } } | Should -Throw '*Not a full disk resource id*'
    }
}

Describe 'SAFETY-ALL-1: a data-disk copy gone before the move stops it there' {
    It 'CONVERTING refuses before any change when a data disk''s copy no longer exists' {
        $script:rp = SadNewRun -WithCopies
        Mock -ModuleName VmMigrationFactory Test-VmfSnapshotExists { $SnapshotId -notlike '*vm1-pristine-d0' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { throw 'must not be reached' }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { throw 'must not be reached' }
        { InModuleScope VmMigrationFactory -Parameters @{ c = (SadCtx $script:rp) } { param($c) Invoke-VmfStepConverting -Context $c } } |
            Should -Throw '*Safety copy missing*vm1-pristine-d0*'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0 -Exactly
        Remove-Item $script:rp -Recurse -Force
    }
}
