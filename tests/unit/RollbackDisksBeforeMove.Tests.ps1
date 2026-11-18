#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-DISKS-FIRST-1, reworked to the decision of 2026-10-11: a put-back
# must never be blocked, and must be 100% safe. So a put-back must
# never depend on Azure accepting a new disk request at put-back time.
#
# So the way back is BUILT before the move changes anything: at the end of
# SAFETY_PRISTINE, once the first copies are taken and usable, the engine
# makes a disk from each - the OS disk and every data disk a put-back
# restores - and reads each back. A disk Azure refuses, or one that differs,
# stops the move with the machine as it was, and the disks made are deleted.
# Every put-back from the first copy then only swaps these disks in. A move
# that completes deletes the ones nothing used; retention finds the rest.
#
# The fakes record every call that changes a machine, makes or deletes a
# disk, in order.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
    $script:des = "$($script:sub)/diskEncryptionSets/des-contoso"

    # One machine: an OS disk on a customer-managed key and one Premium SSD
    # data disk. -Copies: the first copies are taken and locked. -Kept: a
    # complete record of the rollback disks, as SAFETY_PRISTINE
    # leaves it.
    function Global:PbdNewRun {
        param([switch]$Copies, [switch]$Made, [string]$State = 'SAFETY_PRISTINE', [string]$DataSku = 'Premium_LRS', [switch]$NoIopsFacts)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-pbd-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; des = $script:des; copies = [bool]$Copies; made = [bool]$Made; st = $State; dsku = $DataSku; noFacts = [bool]$NoIopsFacts } {
            param($rp, $id, $sub, $des, $copies, $made, $st, $dsku, $noFacts)
            Initialize-VmfRun -RunPath $rp -RunId 'pbd' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'pbd' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $data = [pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = $dsku
                encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $des }
            if ($dsku -eq 'PremiumV2_LRS' -and -not $noFacts) {
                foreach ($kv in @(@('diskIOPSReadWrite', 5000), @('diskMBpsReadWrite', 200), @('logicalSectorSize', 512))) { $data | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] }
                $data | Add-Member -NotePropertyName diskZones -NotePropertyValue @()
                $data.caching = 'None'
            }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @(); capacityReservationGroupId = $null
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk"
                            encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $des }
                        dataDisks = @($data); nics = @(); tags = @{} } }) -Force
            $safety = [pscustomobject]@{ snapshotId = $null; cloneVmId = $null; locksAllowed = $true }
            if ($copies -or $made) {
                $safety = [pscustomobject]@{ snapshotId = "$sub/snapshots/vm1-prepared"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/vm1-pristine"; pristineSnapshotLocked = $true
                    pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0"; snapshotId = "$sub/snapshots/vm1-pristine-d0"; locked = $true }) }
            }
            if ($made) {
                $safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue ([pscustomobject]@{
                        stamp = '202610110700'; pristineSnapshotId = "$sub/snapshots/vm1-pristine"; zone = $null; complete = $true
                        disks = @(
                            [pscustomobject]@{ lun = $null; name = 'vm1-osdisk'; diskId = "$sub/disks/vm1-osdisk-asitwas-202610110700"; diskName = 'vm1-osdisk-asitwas-202610110700'
                                snapshotId = "$sub/snapshots/vm1-pristine"; skuName = 'Premium_LRS'; instantAccess = $false; madeUtc = '2026-10-11T07:00:30Z'; usedUtc = $null; deletedUtc = $null },
                            [pscustomobject]@{ lun = 0; name = 'vm1-data0'; diskId = "$sub/disks/vm1-data0-d0-asitwas-202610110700"; diskName = 'vm1-data0-d0-asitwas-202610110700'
                                snapshotId = "$sub/snapshots/vm1-pristine-d0"; skuName = $dsku; instantAccess = $false; madeUtc = '2026-10-11T07:00:40Z'; usedUtc = $null; deletedUtc = $null })
                        kept = @() })
            }
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue $safety -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            if ($st -ne 'PLANNED') { Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok | Out-Null }
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                        assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }
    function Global:PbdCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'
                    target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'pbd'
        }
    }
    function Global:PbdDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:PbdLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }
    function Global:PbdStep($rp) { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $rp) } { param($c) Invoke-VmfStepSafetyPristine -Context $c } }

    # Azure. A disk whose name matches $pbd.refuse is refused; $pbd.gotEnc is
    # the key Azure reads back; a disk asked for again by its name comes back,
    # as New-VmfDiskFromSnapshot does. $pbd.gone and $pbd.attached shape what
    # a read of a disk by its id says.
    function Global:PbdMockAzure {
        $global:pbd = @{ calls = [System.Collections.Generic.List[string]]::new(); disks = @{}; refuse = '^$'; gotEnc = 'EncryptionAtRestWithCustomerKey'
            gone = @(); attached = @{}; deleteFails = '^$'; shares = 1 }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:pbd.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:pbd.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory New-VmfOsDiskSnapshot { $global:pbd.calls.Add("snapshot:$SnapshotName"); "$($script:sub)/snapshots/$SnapshotName" }
        Mock -ModuleName VmMigrationFactory Lock-VmfSnapshot { $global:pbd.calls.Add('lock'); "$SnapshotId/providers/Microsoft.Authorization/locks/vmf-safety-copy" }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { "$($script:sub)/capacityReservationGroups/crg1" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { $global:pbd.calls.Add('leaveReservation') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:pbd.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = "$($script:sub)/disks/vm1-osdisk"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { $global:pbd.shares }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            if ($DiskName -match $global:pbd.refuse) { $global:pbd.calls.Add("refused:$DiskName"); throw "QuotaExceeded: Azure did not make the disk '$DiskName'." }
            if ($global:pbd.disks.ContainsKey($DiskName)) { $global:pbd.calls.Add("existing:$DiskName"); return $global:pbd.disks[$DiskName] }
            $global:pbd.calls.Add("create:$DiskName")
            $global:pbd.disks[$DiskName] = "$($script:sub)/disks/$DiskName"
            $global:pbd.disks[$DiskName]
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
            [pscustomobject]@{ id = $DiskId; skuName = 'PremiumV2_LRS'; diskSizeGB = 128; diskIOPSReadWrite = 5000; diskMBpsReadWrite = 200; logicalSectorSize = 512; zones = @()
                encryptionType = $global:pbd.gotEnc; diskEncryptionSetId = $(if ($global:pbd.gotEnc -eq 'EncryptionAtRestWithPlatformKey') { $null } else { $script:des }) }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $n = ($DiskId -split '/')[-1]
            $global:pbd.calls.Add("read:$n")
            if ($n -in $global:pbd.gone) { return [pscustomobject]@{ Exists = $false; ManagedBy = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = $(if ($global:pbd.attached.ContainsKey($n)) { $global:pbd.attached[$n] } else { '' }) }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById {
            $n = ($DiskId -split '/')[-1]
            if ($n -match $global:pbd.deleteFails) { $global:pbd.calls.Add("deleteRefused:$n"); throw "ScopeLocked: the disk '$n' is locked." }
            $global:pbd.calls.Add("deleteDisk:$n")
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:pbd.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:pbd.calls.Add("data:$(@($Swaps | ForEach-Object { $_.diskName }) -join ',')"); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:pbd.calls.Add('an'); $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { $global:pbd.calls.Add('type') }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfSnapshotAccess { [pscustomobject]@{ snapshotAccessState = 'InstantAccess'; completionPercent = 100; instantAccessDurationMinutes = 300; timeCreated = (Get-Date).ToUniversalTime().AddMinutes(-5).ToString('o') } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = "$($script:sub)/disks/vm1-data0"; name = 'vm1-data0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' }) }
        Mock -ModuleName VmMigrationFactory Invoke-VmfGuestScriptOnVm { $global:pbd.calls.Add("guest:$ScriptName"); throw 'no guest script runs in these tests' }
    }

    # Every call that changes the machine: not a disk made, read or deleted,
    # and not a copy.
    function Global:PbdMachineCalls { @($global:pbd.calls | Where-Object { $_ -notmatch '^(create|existing|refused|read|deleteDisk|deleteRefused|snapshot):|^lock$' }) }
}
AfterAll {
    Remove-Item function:PbdNewRun, function:PbdCtx, function:PbdDoc, function:PbdLog, function:PbdStep, function:PbdMockAzure, function:PbdMachineCalls -ErrorAction SilentlyContinue
    Remove-Variable pbd -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ROLLBACK-DISKS-FIRST-1: SAFETY_PRISTINE builds the way back before the move changes anything' {
    BeforeEach { Global:PbdMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'the order: stop, the copies, start, then a disk from each copy - and only then does the move go on' {
        $script:rp = Global:PbdNewRun
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'GUEST_PREP' -Because "the step said: $($r.Detail)"
        $calls = @($global:pbd.calls)
        $start = [array]::IndexOf($calls, 'start')
        $os = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'create:vm1-osdisk-asitwas-*' } | Select-Object -First 1))
        $data = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'create:vm1-data0-d0-asitwas-*' } | Select-Object -First 1))
        $os | Should -BeGreaterThan $start -Because "a disk from a copy needs no stopped machine (calls: $($calls -join ', '))"
        $data | Should -BeGreaterThan $os
        @($calls | Where-Object { $_ -like 'snapshot:*' }) | Should -HaveCount 2
        @(Global:PbdMachineCalls) | Should -Be @('stop', 'start') -Because 'the copies need the stop; nothing else touches the machine'
        $rec = (Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove
        $rec.complete | Should -BeTrue
        $rec.stamp | Should -Match '^\d{12}$'
        @($rec.disks | ForEach-Object diskName) | Should -Be @("vm1-osdisk-asitwas-$($rec.stamp)", "vm1-data0-d0-asitwas-$($rec.stamp)")
        @($rec.disks | Where-Object { $null -eq $_.lun }).Count | Should -Be 1
        $rec.pristineSnapshotId | Should -Be (Global:PbdDoc $script:rp).safety.pristineSnapshotId
        (Global:PbdDoc $script:rp).schemaVersion | Should -Be 51
        Global:PbdLog $script:rp | Should -Match 'made the rollback disks from the first safety copies, before it changes the machine'
    }

    It 'an OS disk on another key (SAFETY-CMK-1) stops the move untouched, and the disk made is deleted' {
        $script:rp = Global:PbdNewRun -Copies
        $global:pbd.gotEnc = 'EncryptionAtRestWithPlatformKey'
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
        $r.Reason | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match 'stopped before it changed the machine'
        $r.Detail | Should -Match 'vm1-osdisk-asitwas-\d{12}'
        $r.Detail | Should -Match "The rollback disks are deleted: 'vm1-osdisk-asitwas-\d{12}'"
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:vm1-osdisk-asitwas-*' }) | Should -HaveCount 1
        @($global:pbd.calls | Where-Object { $_ -like 'create:vm1-data0*' }) | Should -HaveCount 0 -Because 'it stops at the first disk that cannot be used'
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks | Where-Object { -not $_.deletedUtc }) | Should -HaveCount 0 -Because 'nothing bills on no record'
    }

    It 'a data disk Azure refuses stops the move untouched: the OS disk already made is deleted, and the stop names the data disk' {
        $script:rp = Global:PbdNewRun -Copies
        $global:pbd.refuse = 'data0-d0-asitwas'
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION'
        $r.Reason | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "The data disk 'vm1-data0-d0-asitwas-\d{12}' for LUN 0 was not made from its copy"
        $r.Detail | Should -Match 'QuotaExceeded'
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:vm1-osdisk-asitwas-*' }) | Should -HaveCount 1
        @(Global:PbdMachineCalls) | Should -Be @('start') -Because 'the machine is started, as it was, and nothing else touches it'
    }

    It 'a disk that cannot be deleted after a refusal is named, so nothing bills in silence' {
        $script:rp = Global:PbdNewRun -Copies
        $global:pbd.refuse = 'data0-d0-asitwas'
        $global:pbd.deleteFails = 'osdisk-asitwas'
        $r = Global:PbdStep $script:rp
        $r.Detail | Should -Match "were not deleted, and each bills until somebody deletes it: 'vm1-osdisk-asitwas-\d{12}' \(ScopeLocked"
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks | Where-Object { -not $_.deletedUtc }) | Should -HaveCount 1 -Because 'the disk stays on record for retention and run deletion'
    }

    It 'through the engine: a refused disk ends the machine FAILED_NEEDS_ATTENTION, untouched, and no guest step runs' {
        $script:rp = Global:PbdNewRun -Copies
        $global:pbd.refuse = 'osdisk-asitwas'
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        $entry = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; wave = 'w1'; ring = 'lab'; path = 'A'
            assessment = [pscustomobject]@{ os = 'Linux'; location = 'centralus' }; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }
        $final = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; e = $entry } { param($rp, $e) Invoke-VmfStateMachine -PlanEntry $e -RunPath $rp -RunId 'pbd' }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $stop.machineState | Should -Be 'untouched'
        @($global:pbd.calls | Where-Object { $_ -like 'guest:*' }) | Should -HaveCount 0
        @(Global:PbdMachineCalls) | Should -Be @('start')
    }

    It 'a shared data disk is left, as every put-back leaves it, and the record says why' {
        $script:rp = Global:PbdNewRun -Copies
        $global:pbd.shares = 2
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'GUEST_PREP'
        $rec = (Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove
        @($rec.disks) | Should -HaveCount 1
        @($rec.kept)[0].why | Should -Match 'shared disk \(maxShares 2\)'
    }

    It 'a Premium SSD v2 disk whose values are not on record cannot come back fully, so the move stops untouched' {
        $script:rp = Global:PbdNewRun -Copies -DataSku 'PremiumV2_LRS' -NoIopsFacts
        $r = Global:PbdStep $script:rp
        $r.Reason | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $r.Detail | Should -Match "The data disk 'vm1-data0' on LUN 0 cannot be made from its copy"
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:vm1-osdisk-asitwas-*' }) | Should -HaveCount 1
    }

    It 'review: a data disk Azure makes but that differs from the record stops the move untouched, and BOTH disks made are deleted' {
        # Mutation found surviving at review: "if (-not $made.Id)" alone let a
        # made-but-different disk (Id with Why) through as a way back.
        $script:rp = Global:PbdNewRun -Copies -DataSku 'PremiumV2_LRS'
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
            [pscustomobject]@{ id = $DiskId; skuName = 'PremiumV2_LRS'; diskSizeGB = 128; diskIOPSReadWrite = $(if ($DiskId -match 'data0') { 3000 } else { 5000 }); diskMBpsReadWrite = 200; logicalSectorSize = 512; zones = @()
                encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $script:des }
        }
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'FAILED_NEEDS_ATTENTION' -Because "the step said: $($r.Detail)"
        $r.Reason | Should -Be 'rollbackDisksBeforeMoveNotMade'
        $r.MachineState | Should -Be 'untouched'
        $r.Detail | Should -Match "The data disk 'vm1-data0-d0-asitwas-\d{12}' for LUN 0 was not made from its copy"
        $r.Detail | Should -Match 'differs from the record'
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:vm1-osdisk-asitwas-*' }) | Should -HaveCount 1
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:vm1-data0-d0-asitwas-*' }) | Should -HaveCount 1 -Because 'a disk that differs bills like any other'
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks | Where-Object { -not $_.deletedUtc }) | Should -HaveCount 0
        (Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.complete | Should -BeFalse
    }

    It 'kill-resume: a worker that stops between two disks - the resume asks for the same names, and each disk is made once' {
        $script:rp = Global:PbdNewRun -Copies
        $global:pbdDied = $false
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount {
            if (-not $global:pbdDied) { $global:pbdDied = $true; throw 'Lease lost - abandon this VM.' }
            1
        }
        try {
            { Global:PbdStep $script:rp } | Should -Throw '*abandon this VM*'
            $mid = Global:PbdDoc $script:rp
            $mid.state | Should -Be 'SAFETY_PRISTINE' -Because 'the step never returned, so the resume runs it again'
            $mid.safety.rollbackDisksBeforeMove.complete | Should -BeFalse
            @($mid.safety.rollbackDisksBeforeMove.disks) | Should -HaveCount 1
            $r = Global:PbdStep $script:rp
        }
        finally { Remove-Variable pbdDied -Scope Global -ErrorAction SilentlyContinue }
        $r.Next | Should -Be 'GUEST_PREP'
        $stamp = (Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.stamp
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -Be @("create:vm1-osdisk-asitwas-$stamp", "create:vm1-data0-d0-asitwas-$stamp")
        @($global:pbd.calls | Where-Object { $_ -like 'existing:*' }) | Should -Be @("existing:vm1-osdisk-asitwas-$stamp")
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:*' }) | Should -HaveCount 0 -Because 'a lost lease is not a refused disk'
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks) | Should -HaveCount 2
    }

    It 'kill-resume: the names come from the checkpoint written before the first disk, not from the time of the resume' {
        # A worker wrote the checkpoint at 07:00 and stopped before it made a
        # disk. The resume, minutes later, asks for the 07:00 names.
        $script:rp = Global:PbdNewRun -Copies
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Set-VmfRollbackDisksBeforeMoveRecord -RunPath $rp -VmId $id -Record ([pscustomobject]@{ stamp = '202610110700'; pristineSnapshotId = "$sub/snapshots/vm1-pristine"; zone = $null; complete = $false; disks = @(); kept = @() })
        }
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'GUEST_PREP'
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -Be @('create:vm1-osdisk-asitwas-202610110700', 'create:vm1-data0-d0-asitwas-202610110700')
    }
    It 'kill-resume: a worker that stops after the disks are made and before the first change - the resume makes nothing' {
        $script:rp = Global:PbdNewRun -Copies
        $null = Global:PbdStep $script:rp
        # The worker died before the transition to GUEST_PREP was written.
        $global:pbd.calls.Clear()
        $r = Global:PbdStep $script:rp
        $r.Next | Should -Be 'GUEST_PREP'
        @($global:pbd.calls | Where-Object { $_ -match '^(create|existing|deleteDisk):' }) | Should -HaveCount 0
    }
}

Describe 'ROLLBACK-DISKS-FIRST-1: every put-back from the first copy uses the disks made before the move' {
    BeforeEach { Global:PbdMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'Path A rollback: no disk is made; each is read before the stop, then swapped in after the size' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:pbd.calls)
        @($calls | Where-Object { $_ -like 'create:*' -or $_ -like 'existing:*' }) | Should -HaveCount 0 -Because 'the rollback asks Azure for no new disk'
        $calls[0] | Should -Be 'read:vm1-osdisk-asitwas-202610110700'
        $calls[1] | Should -Be 'read:vm1-data0-d0-asitwas-202610110700'
        $calls[2] | Should -Be 'stop'
        @(Global:PbdMachineCalls) | Should -Be @('stop', 'leaveReservation', 'size:Standard_D2s_v4', 'os:vm1-osdisk-asitwas-202610110700', 'data:vm1-data0-d0-asitwas-202610110700', 'start')
        $doc = Global:PbdDoc $script:rp
        $doc.rollback.osDisk.name | Should -Be 'vm1-osdisk-asitwas-202610110700'
        @($doc.safety.rollbackDisksBeforeMove.disks | Where-Object { -not $_.usedUtc }) | Should -HaveCount 0 -Because 'a disk a put-back put on the machine is never used again, nor deleted'
        @($doc.PSObject.Properties['rollbackDisksDuringRollback'] | Where-Object { $_.Value }) | Should -HaveCount 0 -Because 'the rollback made no disk'
        Global:PbdLog $script:rp | Should -Match 'uses the disks that the product made from the safety copies before the move changed the machine'
    }

    It 'the disks-only rollback before the move uses them too' {
        $script:rp = Global:PbdNewRun -Made -State 'GUEST_PREP'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -HaveCount 0
        @(Global:PbdMachineCalls) | Should -Be @('stop', 'os:vm1-osdisk-asitwas-202610110700', 'data:vm1-data0-d0-asitwas-202610110700', 'start')
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B rollback is gone with its step.
    It 'Restore this machine from the first copy, new names: no disk is made, the rollback disks go on' {
        $script:rp = Global:PbdNewRun -Made -State 'FAILED_NEEDS_ATTENTION'
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:pbd.calls.Add("allow:$DiskName") }
        $r = Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -HaveCount 0
        @(Global:PbdMachineCalls) | Should -Be @('stop', 'leaveReservation', 'size:Standard_D2s_v4', 'os:vm1-osdisk-asitwas-202610110700', 'data:vm1-data0-d0-asitwas-202610110700', 'start')
        $r.NewDiskName | Should -Be 'vm1-osdisk-asitwas-202610110700'
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks | Where-Object { -not $_.usedUtc }) | Should -HaveCount 0
    }

    It 'Restore this machine keeping the names: the rollback disks are the temporary disks' {
        $script:rp = Global:PbdNewRun -Made -State 'FAILED_NEEDS_ATTENTION'
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:pbd.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        $calls = @($global:pbd.calls)
        @($calls | Where-Object { $_ -like 'create:*' }) | Should -Be @('create:vm1-osdisk', 'create:vm1-data0') -Because 'only the disks under the old names are made, after those names are freed'
        [array]::IndexOf($calls, 'create:vm1-osdisk') | Should -BeGreaterThan ([array]::IndexOf($calls, 'delete:vm1-osdisk'))
        $calls | Should -Contain 'os:vm1-osdisk-asitwas-202610110700'
        $calls | Should -Contain 'delete:vm1-osdisk-asitwas-202610110700'
        $calls | Should -Contain 'delete:vm1-data0-d0-asitwas-202610110700'
        $calls[-1] | Should -Be 'start'
    }
}

Describe 'ROLLBACK-DISKS-FIRST-1: the fallback - a put-back that cannot use them makes its own, before the stop' {
    BeforeEach { Global:PbdMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'a document from before vm-state v22 (no rollback disks) - the rollback makes them, and says why' {
        $script:rp = Global:PbdNewRun -Copies -State 'VALIDATING'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:pbd.calls)
        $calls[0] | Should -BeLike 'create:vm1-osdisk-asitwas-*'
        [array]::IndexOf($calls, 'stop') | Should -BeGreaterThan 1
        Global:PbdLog $script:rp | Should -Match 'makes its disks from the first safety copy now, before it stops the machine. No rollback disks are on record'
    }

    It 'a rollback disk that Azure no longer has - the rollback reads it before the stop, and makes its own' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        $global:pbd.gone = @('vm1-data0-d0-asitwas-202610110700')
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:pbd.calls)
        $create = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'create:*' } | Select-Object -First 1))
        $create | Should -BeGreaterOrEqual 0
        $create | Should -BeLessThan ([array]::IndexOf($calls, 'stop'))
        $calls | Should -Not -Contain 'os:vm1-osdisk-asitwas-202610110700'
        Global:PbdLog $script:rp | Should -Match 'Azure no longer has the rollback disk'
    }

    It 'review: a fallback rollback in the minute the rollback disks were made never asks for their names' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        $st = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp); rp = $script:rp; id = $script:vmId; sub = $script:sub } {
            param($c, $rp, $id, $sub)
            Set-VmfRollbackPending -Context $c -Kind 'full' -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The health check did not answer.'
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $st = Get-VmfRollbackStamp -Doc $doc
            # Rollback disks were made in the same minute.
            $rec = $doc.safety.rollbackDisksBeforeMove
            $rec.stamp = $st
            foreach ($d in @($rec.disks)) {
                $d.diskName = $d.diskName -replace '202610110700', $st
                $d.diskId = "$sub/disks/$($d.diskName)"
            }
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $st
        }
        $global:pbd.disks["vm1-osdisk-asitwas-$st"] = "$($script:sub)/disks/vm1-osdisk-asitwas-$st"
        $global:pbd.attached = @{ "vm1-osdisk-asitwas-$st" = "$($script:sub)/virtualMachines/other" }
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $global:pbd.calls | Should -Not -Contain "existing:vm1-osdisk-asitwas-$st" -Because 'the fallback must never get the disk on another machine back by its name'
        $global:pbd.calls | Should -Not -Contain "os:vm1-osdisk-asitwas-$st"
        $global:pbd.calls | Should -Contain "create:vm1-osdisk-asitwas-$($st)r"
    }

    It 'a rollback disk attached to another machine is never swapped in' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        $global:pbd.attached = @{ 'vm1-osdisk-asitwas-202610110700' = "$($script:sub)/virtualMachines/other" }
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $global:pbd.calls | Should -Not -Contain 'os:vm1-osdisk-asitwas-202610110700'
        Global:PbdLog $script:rp | Should -Match 'is attached to'
    }

    It 'a resume after the swap finds its disk on this machine, and uses it' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        $global:pbd.attached = @{ 'vm1-osdisk-asitwas-202610110700' = $script:vmId }
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $global:pbd.calls | Should -Contain 'os:vm1-osdisk-asitwas-202610110700'
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -HaveCount 0
    }

    It 'kill-resume: a rollback that stopped after the OS swap - the next worker swaps the SAME disks, never makes others' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Set-VmfRollbackPending -Context $c -Kind 'full' -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The health check did not answer.' }
        $global:pbdDied = $false
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks {
            $global:pbd.calls.Add("data:$(@($Swaps | ForEach-Object { $_.diskName }) -join ',')")
            if (-not $global:pbdDied) { $global:pbdDied = $true; throw 'Lease lost - abandon this VM.' }
            @{ Applied = $true }
        }
        try {
            { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
            (@((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks) | Where-Object { $null -eq $_.lun }).usedBy | Should -BeLike 'rollback-*'
            # The next worker: the OS disk is on this machine now.
            $global:pbd.attached = @{ 'vm1-osdisk-asitwas-202610110700' = $script:vmId }
            $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c -Resumed }
        }
        finally { Remove-Variable pbdDied -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' -or $_ -like 'existing:*' }) | Should -HaveCount 0 -Because 'the resume asks Azure for no new disk either'
        @($global:pbd.calls | Where-Object { $_ -like 'os:*' } | Select-Object -Unique) | Should -Be @('os:vm1-osdisk-asitwas-202610110700')
        @($global:pbd.calls | Where-Object { $_ -like 'data:*' } | Select-Object -Unique) | Should -Be @('data:vm1-data0-d0-asitwas-202610110700')
    }

    It 'Restore this machine after a rollback put the machine on them makes new disks - it never swaps in the disks the machine runs on' {
        $script:rp = Global:PbdNewRun -Made -State 'FAILED_ROLLED_BACK'
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v4' }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Set-VmfRollbackDisksBeforeMoveUsed -RunPath $rp -VmId $id -DiskIds @("$sub/disks/vm1-osdisk-asitwas-202610110700", "$sub/disks/vm1-data0-d0-asitwas-202610110700") -By 'rollback-202610111200'
        }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        @($global:pbd.calls | Where-Object { $_ -like 'create:vm1-osdisk-restored-*' }) | Should -HaveCount 1
        $global:pbd.calls | Should -Not -Contain 'os:vm1-osdisk-asitwas-202610110700'
        Global:PbdLog $script:rp | Should -Match 'An earlier rollback or restore already put the rollback disks on the machine'
    }
    It 'a rollback that fails after the stop names the rollback disks that are not on the machine, which bill' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Set-VmfRollbackPending -Context $c -Kind 'full' -State 'VALIDATING' -ReasonCode 'validationFailedAfterConversion' -Detail 'The health check did not answer.' }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:pbd.calls.Add("size:$Size"); throw 'The requested VM size is not available in the current region. ErrorCode: SkuNotAvailable' }
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $stop = @($final.history)[-1]
        # ROLLBACK-CAPACITY-1: a refused size has its own reason (case B).
        $stop.reasonCode | Should -Be 'rollbackSizeRefused'
        $stop.detail | Should -Match "The rollback disks made before the move that are not on the machine are kept: 'vm1-osdisk-asitwas-202610110700', 'vm1-data0-d0-asitwas-202610110700'\."
    }
    It 'disks an earlier put-back used are not used again' {
        $script:rp = Global:PbdNewRun -Made -State 'VALIDATING'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            Set-VmfRollbackDisksBeforeMoveUsed -RunPath $rp -VmId $id -DiskIds @("$sub/disks/vm1-osdisk-asitwas-202610110700")
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -Not -BeNullOrEmpty
        Global:PbdLog $script:rp | Should -Match 'An earlier rollback or restore already put the rollback disks on the machine'
    }

    It 'the disks-only rollback on a disk type this attempt does not have makes its own' {
        $script:rp = Global:PbdNewRun -Made -State 'GUEST_PREP'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } {
            param($rp, $id)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            $d.captured.vmConfig.osDisk.skuName = 'StandardSSD_LRS'
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        @($global:pbd.calls | Where-Object { $_ -like 'create:*' }) | Should -Not -BeNullOrEmpty
        Global:PbdLog $script:rp | Should -Match 'do not match this attempt'
    }

    It 'Restore this machine from the second copy does not use them' {
        $script:rp = Global:PbdNewRun -Made -State 'FAILED_NEEDS_ATTENTION'
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub } {
            param($rp, $id, $sub)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            $d.safety | Add-Member -NotePropertyName dataCopies -NotePropertyValue @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0"; snapshotId = "$sub/snapshots/vm1-prepared-d0"; locked = $true }) -Force
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        @($global:pbd.calls | Where-Object { $_ -like 'create:vm1-osdisk-restored-*' }) | Should -HaveCount 1 -Because 'the second copy makes its own disk'
        @($global:pbd.calls | Where-Object { $_ -like 'read:*asitwas*' }) | Should -HaveCount 0
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks | Where-Object { $_.usedUtc }) | Should -HaveCount 0
    }
}

Describe 'ROLLBACK-DISKS-FIRST-1: a move that completes deletes the disks nothing used' {
    BeforeEach { Global:PbdMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'deletes each unused disk by its id, and records it' {
        $script:rp = Global:PbdNewRun -Made -State 'MIGRATED'
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Remove-VmfUnusedRollbackDisksBeforeMove -Context $c }
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:*' }) | Should -Be @('deleteDisk:vm1-osdisk-asitwas-202610110700', 'deleteDisk:vm1-data0-d0-asitwas-202610110700')
        @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks | Where-Object { -not $_.deletedUtc }) | Should -HaveCount 0
        Global:PbdLog $script:rp | Should -Match 'The move is complete, so the product deleted the rollback disks'
    }

    It 'never deletes a disk that is attached, nor one a put-back used' {
        $script:rp = Global:PbdNewRun -Made -State 'MIGRATED'
        $global:pbd.attached = @{ 'vm1-data0-d0-asitwas-202610110700' = $script:vmId }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub; c = (Global:PbdCtx $script:rp) } {
            param($rp, $id, $sub, $c)
            Set-VmfRollbackDisksBeforeMoveUsed -RunPath $rp -VmId $id -DiskIds @("$sub/disks/vm1-osdisk-asitwas-202610110700")
            Remove-VmfUnusedRollbackDisksBeforeMove -Context $c
        }
        @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:*' }) | Should -HaveCount 0
        $global:pbd.calls | Should -Not -Contain 'read:vm1-osdisk-asitwas-202610110700' -Because 'a used disk is not even a candidate'
        $d0 = @((Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove.disks) | Where-Object { $_.lun -eq 0 }
        $d0.usedUtc | Should -Not -BeNullOrEmpty -Because 'a disk found attached is in use from then on'
        $d0.deletedUtc | Should -BeNullOrEmpty
    }

    It 'a delete Azure refuses never fails the move: it is said, and retention finds the disk again' {
        $script:rp = Global:PbdNewRun -Made -State 'MIGRATED'
        $global:pbd.deleteFails = 'osdisk'
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:PbdCtx $script:rp) } { param($c) Remove-VmfUnusedRollbackDisksBeforeMove -Context $c } } | Should -Not -Throw
        Global:PbdLog $script:rp | Should -Match 'the daily cleanup tries again'
        $due = InModuleScope VmMigrationFactory -Parameters @{ d = (Global:PbdDoc $script:rp) } { param($d) Get-VmfDueRollbackDisksBeforeMove -StateDocs @($d) }
        @($due[0].Disks | ForEach-Object diskName) | Should -Be @('vm1-osdisk-asitwas-202610110700')
    }

}

Describe 'ROLLBACK-DISKS-FIRST-1: retention and run deletion find them' {
    It 'which disks are due: an earlier attempt''s always; this attempt''s once the move has ended; never a used or a deleted one' {
        InModuleScope VmMigrationFactory {
            $disk = { param($n, [switch]$Used, [switch]$Gone) [pscustomobject]@{ lun = $null; diskId = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/disks/$n"; diskName = $n
                    usedUtc = $(if ($Used) { '2026-10-11T08:00:00Z' } else { $null }); deletedUtc = $(if ($Gone) { '2026-10-11T08:00:00Z' } else { $null }) } }
            $doc = { param($state, $now, $earlier)
                [pscustomobject]@{ vmId = "vm-$state"; state = $state
                    safety = [pscustomobject]@{ rollbackDisksBeforeMove = [pscustomobject]@{ disks = @($now) }
                        earlierCopies = @([pscustomobject]@{ rollbackDisksBeforeMove = [pscustomobject]@{ disks = @($earlier) } }) } } }
            $docs = @(
                (& $doc 'MIGRATED' @((& $disk 'm-now'), (& $disk 'm-used' -Used), (& $disk 'm-gone' -Gone)) @(& $disk 'm-old')),
                (& $doc 'FAILED_ROLLED_BACK' @(& $disk 'r-now') @()),
                (& $doc 'NEEDS_DECISION' @(& $disk 'n-now') @(& $disk 'n-old')),
                (& $doc 'FAILED_NEEDS_ATTENTION' @(& $disk 'f-now') @()),
                (& $doc 'CONVERTING' @(& $disk 'c-now') @()))
            $due = @(Get-VmfDueRollbackDisksBeforeMove -StateDocs $docs)
            $byVm = @{}; foreach ($d in $due) { $byVm[$d.VmId] = @($d.Disks | ForEach-Object diskName | Sort-Object) }
            $byVm['vm-MIGRATED'] | Should -Be @('m-now', 'm-old')
            $byVm['vm-FAILED_ROLLED_BACK'] | Should -Be @('r-now')
            $byVm['vm-NEEDS_DECISION'] | Should -Be @('n-old') -Because 'a machine waiting for a person keeps its way back'
            $byVm.ContainsKey('vm-FAILED_NEEDS_ATTENTION') | Should -BeFalse
            $byVm.ContainsKey('vm-CONVERTING') | Should -BeFalse -Because 'a moving machine needs its way back most'
        }
    }

    It 'a person''s retry moves them with the old copies, and the new attempt makes its own' {
        Global:PbdMockAzure
        $script:rp = Global:PbdNewRun -Made -State 'FAILED_ROLLED_BACK'
        try {
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) Clear-VmfRetryState -RunPath $rp -VmId $id -From 'PRECHECK' -NewAttempt }
            $doc = Global:PbdDoc $script:rp
            $doc.safety.PSObject.Properties['rollbackDisksBeforeMove'] | Should -BeNullOrEmpty
            @($doc.safety.earlierCopies)[-1].rollbackDisksBeforeMove.stamp | Should -Be '202610110700'
            $due = InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfDueRollbackDisksBeforeMove -StateDocs @($d) }
            @($due[0].Disks) | Should -HaveCount 2 -Because 'an earlier attempt''s unused disks are due at once'
            $r = Global:PbdStep $script:rp
            $r.Next | Should -Be 'GUEST_PREP'
            $now = (Global:PbdDoc $script:rp).safety.rollbackDisksBeforeMove
            $now.complete | Should -BeTrue
            @($now.disks | ForEach-Object diskName) | Should -Not -Contain 'vm1-osdisk-asitwas-202610110700'
            (Global:PbdDoc $script:rp).schemaVersion | Should -Be 51
        }
        finally { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }
    }

    It 'the retention pass deletes what is due, and a preview lists it without deleting' {
        Global:PbdMockAzure
        $script:rp = Global:PbdNewRun -Made -State 'FAILED_ROLLED_BACK'
        try {
            $plan = Join-Path $script:rp 'plan.json'
            $preview = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $plan -DeletedBy 'ops@example.com' -WhatIf
            @($preview.RollbackDisksBeforeMove) | Should -HaveCount 1
            @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:*' }) | Should -HaveCount 0
            $done = Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath $plan -DeletedBy 'ops@example.com' -Confirm:$false
            @($global:pbd.calls | Where-Object { $_ -like 'deleteDisk:*' }) | Should -HaveCount 2
            @($done.RollbackDisksBeforeMoveDeleted) | Should -HaveCount 1
            Global:PbdLog $script:rp | Should -Match 'deleted the rollback disks of this machine, which nothing used'
        }
        finally { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }
    }

    It 'run deletion counts them with the copies, so a run is never deleted with disks left on no record' {
        InModuleScope VmMigrationFactory {
            $doc = [pscustomobject]@{ vmId = 'vm-a'; state = 'FAILED_NEEDS_ATTENTION'
                safety = [pscustomobject]@{ pristineSnapshotId = '/s/p'
                    rollbackDisksBeforeMove = [pscustomobject]@{ disks = @([pscustomobject]@{ lun = $null; diskId = '/d/1'; diskName = 'd1'; usedUtc = $null; deletedUtc = $null },
                                                                 [pscustomobject]@{ lun = 0; diskId = '/d/2'; diskName = 'd2'; usedUtc = '2026-10-11T08:00:00Z'; deletedUtc = $null }) } } }
            $v = Test-VmfRunDiscardable -Plan $null -StateDocs @($doc)
            $v.Ok | Should -BeTrue
            @($v.RollbackDisksBeforeMove | ForEach-Object diskName) | Should -Be @('d1')
            $v.Detail | Should -Match '1 rollback disks'
        }
    }
}

Describe 'ROLLBACK-DISKS-FIRST-1: the contract, vm-state v22' {
    It 'the store, the schema and the sample say 22, and the sample holds a record of the rollback disks' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $schema = Get-Content $schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
        $sampleText = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        Test-Json -Json $sampleText -SchemaFile $schemaFile -ErrorAction Stop | Should -BeTrue
        $sample = $sampleText | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 51
        $sample.safety.rollbackDisksBeforeMove.complete | Should -BeTrue
        @($sample.safety.rollbackDisksBeforeMove.disks).Count | Should -BeGreaterThan 1
    }

    It 'the record is closed: an unknown field, or a disk with no id, is refused' {
        $schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'
        $base = { param($disk) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"PLANNED","history":[],"safety":{"rollbackDisksBeforeMove":{"stamp":"202610110700","pristineSnapshotId":"/s/p","complete":true,"disks":[' + $disk + ']}}}' }
        Test-Json -Json (& $base '{"lun":null,"diskId":"/d/1","diskName":"d1","madeUtc":"2026-10-11T07:00:00Z"}') -SchemaFile $schemaFile -ErrorAction Stop | Should -BeTrue
        # SWAP-REFUSED-AFTER-STOP-1: Test-Json returns False, and does not throw, for a
        # fault inside a nested list (measured on PowerShell 7.6.7, 2026-10-23), so a
        # check that waits for a throw fails on a document the schema refuses. Each now
        # counts a False as a refusal too.
        { if (-not (Test-Json -Json (& $base '{"lun":null,"diskId":"/d/1","diskName":"d1","madeUtc":"2026-10-11T07:00:00Z","madeUp":1}') -SchemaFile $schemaFile -ErrorAction Stop)) { throw 'not valid with the schema' } } | Should -Throw
        { if (-not (Test-Json -Json (& $base '{"lun":null,"diskName":"d1","madeUtc":"2026-10-11T07:00:00Z"}') -SchemaFile $schemaFile -ErrorAction Stop)) { throw 'not valid with the schema' } } | Should -Throw
    }

    It 'the migration note says what changed, why, and what an older document does' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'vm-state v21 -> v22'
        $notes | Should -Match 'rollbackDisksBeforeMove'
        $notes | Should -Match 'Migrating:'
    }

    It 'the stop has guidance, and says the machine is untouched' {
        $g = InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'rollbackDisksBeforeMoveNotMade' }
        $g.machine | Should -Be 'untouched'
        $g.retry | Should -Be 'afterFix'
    }
}
