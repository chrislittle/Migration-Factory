#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MADE-DISK-RECORD-1: every disk a put-back makes from a copy is on record the
# moment Azure makes it, and retention deletes the ones nothing uses.
#
# Restore this machine named the disks it made only from a list in memory, so a
# restore that died after it made them left them on no record. And no cleanup
# knew a disk that a rollback or a restore made and did not use
# (rollbackDisksDuringRollback): each billed until a person deleted it.
#
# The decision of 2026-10-23: retention DELETES an unused disk that a
# put-back made from a copy once the machine's move has ended - reading each
# disk first, and NEVER deleting one that is attached, nor one that a refused
# swap still waits to put on the machine (swapPending). The same schedule as
# the safety copies. Most tests below are about what it must NOT delete.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json'

    # A machine after a move, on the target size, with one data disk.
    function Global:MdrRun {
        param([string]$State = 'MIGRATED')
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-mdr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; st = $State } {
            param($rp, $id, $sub, $st)
            Initialize-VmfRun -RunPath $rp -RunId 'mdr' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'mdr' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{
                        name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @(); capacityReservationGroupId = $null
                        osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-os" }
                        dataDisks = @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-d0" })
                        tags = @{}; nics = @() } }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = "$sub/snapshots/vm1-prepared"; pristineSnapshotId = "$sub/snapshots/vm1-pristine"
                    cloneVmId = $null; locksAllowed = $true; pristineSnapshotLocked = $true
                    pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-d0"; snapshotId = "$sub/snapshots/vm1-pristine-d0"; locked = $true })
                    dataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-d0"; snapshotId = "$sub/snapshots/vm1-prepared-d0"; locked = $true }) }) -Force
            $doc.state = $st
            $doc.history = @([pscustomobject]@{ state = $st; tsUtc = '2026-10-20T08:00:00Z'; outcome = 'ok' })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                        assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; path = 'A'; policy = [ordered]@{ keepSnapshotDays = 30 } }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }
    function Global:MdrDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:MdrEdit($rp, [scriptblock]$Change) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; ch = $Change } {
            param($rp, $id, $ch)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            & $ch $d
            $null = Complete-VmfTestCapture $d
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
    }
    function Global:MdrLog($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    function Global:MdrEntry([string]$Name, $Lun = $null, [switch]$Used, [switch]$Gone) {
        $e = [pscustomobject]@{ diskId = "$($script:sub)/disks/$Name"; diskName = $Name; lun = $Lun; madeUtc = '2026-10-20T07:00:00Z' }
        if ($Used) { $e | Add-Member -NotePropertyName usedUtc -NotePropertyValue '2026-10-20T07:30:00Z' }
        if ($Gone) { $e | Add-Member -NotePropertyName deletedUtc -NotePropertyValue '2026-10-20T07:30:00Z' }
        $e
    }

    # Azure, for a restore. Every disk a test makes is kept by name.
    function Global:MdrMockAzure {
        $global:mdr = @{ calls = [System.Collections.Generic.List[string]]::new(); disks = @{}; attached = @{}; gone = @{}; vmExists = $true; vmReadFails = $false }
        # Review: the cleanup asks whether the machine exists before it deletes
        # a disk made for it, under the machine's own subscription.
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists {
            $global:mdr.calls.Add("vmExists:$Name")
            if ($global:mdr.vmReadFails) { throw 'The read was refused.' }
            $global:mdr.vmExists }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:mdr.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:mdr.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $null }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:mdr.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = "$($script:sub)/disks/vm1-os"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = "$($script:sub)/disks/vm1-d0"; name = 'vm1-d0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            $global:mdr.calls.Add("create:$DiskName")
            $global:mdr.disks[$DiskName] = "$($script:sub)/disks/$DiskName"
            $global:mdr.disks[$DiskName]
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:mdr.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:mdr.calls.Add('data'); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:mdr.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        # Retention: each disk read by its resource id, and deleted by it.
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskAttachment {
            $global:mdr.calls.Add("read:$(($DiskId -split '/')[-1])")
            if ($global:mdr.gone.ContainsKey($DiskId)) { return [pscustomobject]@{ Exists = $false; ManagedBy = '' } }
            [pscustomobject]@{ Exists = $true; ManagedBy = $(if ($global:mdr.attached.ContainsKey($DiskId)) { $global:mdr.attached[$DiskId] } else { '' }) }
        }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { $global:mdr.calls.Add("deleteById:$DiskId") }
        Mock -ModuleName VmMigrationFactory Unlock-VmfSnapshot { }
        Mock -ModuleName VmMigrationFactory Remove-VmfSnapshot { }
    }
    function Global:MdrRestore($rp, [string]$Naming = 'new') {
        Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -DiskNaming $Naming -AcceptPreserveRisk:($Naming -eq 'preserve') -Confirm:$false -WarningAction SilentlyContinue
    }
    function Global:MdrRetention($rp, [switch]$Preview) {
        Remove-VmfExpiredSafetyCopies -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -DeletedBy 'retention (scheduled)' -AsOfUtc ([datetime]'2026-10-21T08:00:00Z') `
            -Confirm:$false -WhatIf:$Preview -WarningAction SilentlyContinue
    }
}
AfterAll {
    Remove-Item function:MdrRun, function:MdrDoc, function:MdrEdit, function:MdrLog, function:MdrEntry, function:MdrMockAzure, function:MdrRestore, function:MdrRetention -ErrorAction SilentlyContinue
    Remove-Variable mdr -Scope Global -ErrorAction SilentlyContinue
}

Describe 'MADE-DISK-RECORD-1: Restore this machine records each disk the moment Azure makes it' {
    BeforeEach { Global:MdrMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'new names: the OS disk and the data disk are on restoreDisks before the stop, so a restore that dies there leaves them on record' {
        $script:rp = Global:MdrRun
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'The engine lost its hold: abandon this VM' }
        { Global:MdrRestore $script:rp } | Should -Throw '*abandon this VM*'
        $doc = Global:MdrDoc $script:rp
        $made = @($doc.restoreDisks)
        $made | Should -HaveCount 2
        $os = $made | Where-Object { $null -eq $_.lun }
        $os.diskName | Should -BeLike 'vm1-os-restored-*'
        $os.diskId | Should -Be "$($script:sub)/disks/$($os.diskName)" -Because 'every disk is addressed by its resource id'
        ($made | Where-Object { $_.lun -eq 0 }).diskName | Should -BeLike 'vm1-d0-d0-restored-*'
        @($made | Where-Object { $_.madeUtc }) | Should -HaveCount 2
        Test-Json -Json ($doc | ConvertTo-Json -Depth 40) -SchemaFile $script:schemaFile | Should -BeTrue
        $doc.schemaVersion | Should -Be 51
    }

    It 'a restore Azure refused part way names the disks it made, and they stay on record unused' {
        $script:rp = Global:MdrRun
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            if ($DiskName -like 'vm1-d0-*') { throw 'QuotaExceeded' }
            "$($script:sub)/disks/$DiskName"
        }
        { Global:MdrRestore $script:rp } | Should -Throw '*vm1-os-restored-*'
        $made = @((Global:MdrDoc $script:rp).restoreDisks)
        $made | Should -HaveCount 1
        $made[0].PSObject.Properties['usedUtc'] | Should -BeNullOrEmpty
    }

    It 'a restore that completes marks each disk it put on the machine as used, so retention never lists them' {
        $script:rp = Global:MdrRun
        Global:MdrRestore $script:rp | Out-Null
        $made = @((Global:MdrDoc $script:rp).restoreDisks)
        $made | Should -HaveCount 2
        @($made | Where-Object { $_.usedUtc }) | Should -HaveCount 2 -Because 'both disks are on the machine'
        $due = InModuleScope VmMigrationFactory -Parameters @{ d = (Global:MdrDoc $script:rp) } { param($d) @(Get-VmfDueMadeDisks -StateDocs @($d)) }
        @($due) | Should -HaveCount 0
    }

    It 'keeping the names: the temporary disks are on record and marked deleted when the restore deletes them; the disks under the old names are used' {
        $script:rp = Global:MdrRun
        Global:MdrRestore $script:rp 'preserve' | Out-Null
        $made = @((Global:MdrDoc $script:rp).restoreDisks)
        $temps = @($made | Where-Object { $_.diskName -like '*-rtmp-*' })
        $temps | Should -HaveCount 2 -Because "the OS and the data disk each had a temporary disk; on record: $(@($made | ForEach-Object diskName) -join ', ')"
        @($temps | Where-Object { $_.deletedUtc }) | Should -HaveCount 2 -Because 'the restore deleted both, so none is named again'
        $finals = @($made | Where-Object { $_.diskName -in @('vm1-os', 'vm1-d0') })
        $finals | Should -HaveCount 2
        @($finals | Where-Object { $_.usedUtc }) | Should -HaveCount 2
    }

    It 'the next restore names the disks an earlier restore made that the machine does not run on (kill and resume)' {
        $script:rp = Global:MdrRun
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'The engine lost its hold: abandon this VM' }
        { Global:MdrRestore $script:rp } | Should -Throw
        # The next restore, a minute or more later: other names.
        Global:MdrEdit $script:rp { param($d) foreach ($e in @($d.restoreDisks)) { $e.diskName = $e.diskName -replace '\d{12}$', '202610200700'; $e.diskId = $e.diskId -replace '\d{12}$', '202610200700' } }
        $earlier = @((Global:MdrDoc $script:rp).restoreDisks | ForEach-Object diskName)
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:mdr.calls.Add('stop') }
        Global:MdrRestore $script:rp | Out-Null
        $said = @(Global:MdrLog $script:rp | Where-Object { [string]$_.detail -like 'An earlier restore made these disks*' })
        $said | Should -HaveCount 1
        foreach ($n in $earlier) { $said[0].detail | Should -BeLike "*'$n'*" }
        # The earlier ones are still unused; the new ones are on the machine.
        $doc = Global:MdrDoc $script:rp
        @(InModuleScope VmMigrationFactory -Parameters @{ d = $doc } { param($d) Get-VmfUnusedMadeDisks -Doc $d -List 'restoreDisks' } | ForEach-Object diskName) | Sort-Object |
            Should -Be @($earlier | Sort-Object)
        # And the daily cleanup deletes them: the machine's move has ended.
        $r = Global:MdrRetention $script:rp
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' } | ForEach-Object { ($_ -split '/')[-1] }) | Sort-Object | Should -Be @($earlier | Sort-Object)
        @($r.MadeDisksDeleted) | Should -HaveCount 1
    }

    It 'a record that cannot be written does not stop the restore, and a line names the disk' {
        $script:rp = Global:MdrRun
        Mock -ModuleName VmMigrationFactory Add-VmfMadeDiskRecord { throw 'The store did not answer.' }
        { Global:MdrRestore $script:rp } | Should -Not -Throw
        $said = @(Global:MdrLog $script:rp | Where-Object { [string]$_.detail -like '*is not on the record of this machine*' })
        @($said | Where-Object { $_.detail -like "*'vm1-os-restored-*" }) | Should -HaveCount 1
    }
}

Describe 'MADE-DISK-RECORD-1: which disks a put-back made are due (Get-VmfDueMadeDisks, pure)' {
    BeforeAll {
        function Global:MdrPureDoc([string]$State, [object[]]$Rollback = @(), [object[]]$Restore = @()) {
            [pscustomobject]@{ vmId = "vm-$State"; state = $State; rollbackDisksDuringRollback = @($Rollback); restoreDisks = @($Restore) }
        }
        function Global:MdrDue([object[]]$Docs) {
            InModuleScope VmMigrationFactory -Parameters @{ d = $Docs } { param($d) @(Get-VmfDueMadeDisks -StateDocs $d) }
        }
    }
    AfterAll { Remove-Item function:MdrPureDoc, function:MdrDue -ErrorAction SilentlyContinue }

    It 'every list, once the move has ended (MIGRATED, FAILED_ROLLED_BACK, SKIPPED); each row says its list' {
        foreach ($st in 'MIGRATED', 'FAILED_ROLLED_BACK', 'SKIPPED') {
            $due = Global:MdrDue @(Global:MdrPureDoc $st -Rollback @(Global:MdrEntry 'rb1') -Restore @(Global:MdrEntry 'rs1' 0))
            @($due) | Should -HaveCount 1
            @($due[0].Disks | ForEach-Object diskName | Sort-Object) | Should -Be @('rb1', 'rs1') -Because $st
            ($due[0].Disks | Where-Object diskName -eq 'rs1').List | Should -Be 'restoreDisks'
        }
    }

    It 'never while the move has not ended - a person may still put the machine back' {
        foreach ($st in 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION', 'CONVERTING', 'PLANNED', 'VALIDATING') {
            @(Global:MdrDue @(Global:MdrPureDoc $st -Restore @(Global:MdrEntry 'rs1'))) | Should -HaveCount 0 -Because $st
        }
    }

    It 'never a disk marked used or deleted' {
        $due = Global:MdrDue @(Global:MdrPureDoc 'MIGRATED' -Restore @((Global:MdrEntry 'used' -Used), (Global:MdrEntry 'gone' -Gone), (Global:MdrEntry 'free')))
        @($due[0].Disks | ForEach-Object diskName) | Should -Be @('free')
    }

    It 'never a disk that swapPending still names - a disk Finish puts on the machine, or one it already swapped' {
        $doc = Global:MdrPureDoc 'MIGRATED' -Restore @((Global:MdrEntry 'waits' 0), (Global:MdrEntry 'free'))
        $doc | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'restore'
                swaps = @([pscustomobject]@{ lun = 0; diskId = "$($script:sub)/disks/waits"; diskName = 'waits' }); swapped = @() })
        @((Global:MdrDue @($doc))[0].Disks | ForEach-Object diskName) | Should -Be @('free')
    }

    It 'never a disk the record says the machine runs on, or ran on: a restore, a rollback, the capture' {
        $doc = Global:MdrPureDoc 'MIGRATED' -Rollback @((Global:MdrEntry 'rb-os'), (Global:MdrEntry 'rb-d0' 0)) -Restore @((Global:MdrEntry 'rs-os'), (Global:MdrEntry 'rs-old'), (Global:MdrEntry 'cap-os'), (Global:MdrEntry 'free'))
        # A retry captured the machine running on a disk a restore made.
        $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{ osDisk = [pscustomobject]@{ name = 'cap-os'; managedDiskId = "$($script:sub)/disks/cap-os" }; dataDisks = @() } })
        $doc | Add-Member -NotePropertyName rollback -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-10-20T08:00:00Z'; path = 'A'
                osDisk = [pscustomobject]@{ id = "$($script:sub)/disks/rb-os"; name = 'rb-os' }; dataDisks = @([pscustomobject]@{ lun = 0; diskId = "$($script:sub)/disks/rb-d0"; diskName = 'rb-d0' }) })
        $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = '2026-10-20T10:00:00Z'; newDiskId = "$($script:sub)/disks/rs-os"; newDiskName = 'rs-os'
                previousDiskId = "$($script:sub)/disks/rs-old"; dataDisks = @() })
        @((Global:MdrDue @($doc))[0].Disks | ForEach-Object diskName) | Should -Be @('free')
    }

    It 'a document from before v26 with no lists, or with nothing due, gives nothing' {
        @(Global:MdrDue @([pscustomobject]@{ vmId = 'v'; state = 'MIGRATED' })) | Should -HaveCount 0
        @(Global:MdrDue @(Global:MdrPureDoc 'MIGRATED' -Restore @(Global:MdrEntry 'x' -Used))) | Should -HaveCount 0
    }
}

Describe 'MADE-DISK-RECORD-1: retention deletes them by resource id, reading each first' {
    BeforeEach { Global:MdrMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'deletes an unused disk that is attached to nothing, marks it deleted, and says so; a preview deletes nothing' {
        $script:rp = Global:MdrRun -State 'FAILED_ROLLED_BACK'
        Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName rollbackDisksDuringRollback -NotePropertyValue @(Global:MdrEntry 'vm1-os-asitwas-202610200700') -Force }
        $preview = Global:MdrRetention $script:rp -Preview
        @($preview.MadeDisks) | Should -HaveCount 1
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -HaveCount 0
        $r = Global:MdrRetention $script:rp
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -Be @("deleteById:$($script:sub)/disks/vm1-os-asitwas-202610200700")
        @($r.MadeDisksDeleted[0].Disks) | Should -Be @('vm1-os-asitwas-202610200700')
        @((Global:MdrDoc $script:rp).rollbackDisksDuringRollback)[0].deletedUtc | Should -Not -BeNullOrEmpty
        @(Global:MdrLog $script:rp | Where-Object { [string]$_.detail -like "The daily cleanup deleted these disks, which a rollback or a restore made from the safety copies of this machine and nothing used:*'vm1-os-asitwas-202610200700'*" }) | Should -HaveCount 1
        # Run again: nothing is due.
        @((Global:MdrRetention $script:rp -Preview).MadeDisks) | Should -HaveCount 0
    }

    It 'review: keeps every disk made for a machine that Azure says is gone - unknown never deletes a disk - and says why' {
        $script:rp = Global:MdrRun
        $global:mdr.vmExists = $false
        Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @((Global:MdrEntry 'vm1-os-rec-202610200700'), (Global:MdrEntry 'vm1-d0-d0-rec-202610200700' 0)) -Force }
        $r = Global:MdrRetention $script:rp
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' -or $_ -like 'read:*' }) | Should -HaveCount 0
        @($global:mdr.calls | Where-Object { $_ -eq 'vmExists:vm1' }) | Should -HaveCount 1
        @($r.MadeDisksDeleted) | Should -HaveCount 0
        @((Global:MdrDoc $script:rp).restoreDisks | Where-Object { $_.PSObject.Properties['deletedUtc'] -or $_.PSObject.Properties['usedUtc'] }) | Should -HaveCount 0
        $said = @(Global:MdrLog $script:rp | Where-Object { [string]$_.detail -like "The daily cleanup kept these disks*'vm1-os-rec-202610200700'*" })
        $said | Should -HaveCount 1
        $said[0].detail | Should -BeLike '*Azure does not have the machine*'
        $said[0].outcome | Should -Be 'warn'
    }

    It 'review: a read of the machine that fails keeps the disks too - unknown never deletes a disk' {
        $script:rp = Global:MdrRun
        $global:mdr.vmReadFails = $true
        Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(Global:MdrEntry 'vm1-os-restored-202610200700') -Force }
        Global:MdrRetention $script:rp | Out-Null
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -HaveCount 0
        $said = @(Global:MdrLog $script:rp | Where-Object { [string]$_.detail -like 'The daily cleanup kept these disks*' })
        $said | Should -HaveCount 1
        $said[0].detail | Should -BeLike '*could not read the machine*The read was refused*'
    }

    It 'NEVER deletes a disk that is attached to a machine: it is kept and marked used' {
        $script:rp = Global:MdrRun
        $id = "$($script:sub)/disks/vm1-os-rec-202610200700"
        $global:mdr.attached[$id] = "$($script:sub)/virtualMachines/other"
        Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(Global:MdrEntry 'vm1-os-rec-202610200700') -Force }
        Global:MdrRetention $script:rp | Out-Null
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -HaveCount 0
        @((Global:MdrDoc $script:rp).restoreDisks)[0].usedUtc | Should -Not -BeNullOrEmpty
        @((Global:MdrRetention $script:rp -Preview).MadeDisks) | Should -HaveCount 0 -Because 'a disk in use is the machine''s own from then on'
    }

    It 'NEVER deletes a disk that swapPending names, end to end' {
        $script:rp = Global:MdrRun
        Global:MdrEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @((Global:MdrEntry 'vm1-d0-d0-restored-202610200700' 0), (Global:MdrEntry 'vm1-os-restored-202610200700')) -Force
            $d | Add-Member -NotePropertyName swapPending -NotePropertyValue ([pscustomobject]@{ kept = @(); kind = 'restore'; leftUtc = '2026-10-20T08:00:00Z'; error = 'x'; usedBy = $null
                    swaps = @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; oldDiskId = "$($script:sub)/disks/vm1-d0"; diskId = "$($script:sub)/disks/vm1-d0-d0-restored-202610200700"; diskName = 'vm1-d0-d0-restored-202610200700'; why = 'x' })
                    swapped = @() }) -Force }
        Global:MdrRetention $script:rp | Out-Null
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -Be @("deleteById:$($script:sub)/disks/vm1-os-restored-202610200700")
    }

    It 'a disk Azure no longer has is marked deleted, and is not asked for again' {
        $script:rp = Global:MdrRun
        $id = "$($script:sub)/disks/vm1-os-restored-202610200700"
        $global:mdr.gone[$id] = $true
        Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(Global:MdrEntry 'vm1-os-restored-202610200700') -Force }
        Global:MdrRetention $script:rp | Out-Null
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -HaveCount 0
        @((Global:MdrDoc $script:rp).restoreDisks)[0].deletedUtc | Should -Not -BeNullOrEmpty
    }

    It 'leaves every disk of a machine that a restore, a rebuild or a wave holds now - and takes them once that hold has expired' {
        $script:rp = Global:MdrRun
        Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(Global:MdrEntry 'vm1-os-restored-202610200700') -Force }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) New-VmfLease -RunPath $rp -VmId $id -WorkerId 'restore:op-1' | Out-Null }
        $r = Global:MdrRetention $script:rp
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' -or $_ -like 'read:*' }) | Should -HaveCount 0 -Because 'a restore that holds the machine may be about to put that disk on it'
        @($r.MadeDisks) | Should -HaveCount 0
        # The hold of a job that died expires.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id)
            $lease = Get-VmfLeaseInfo -RunPath $rp -VmId $id
            $lease.heartbeatUtc = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o')
            Write-VmfStoreJson -RunPath $rp -RelPath (Get-VmfLeaseRelPath -VmId $id) -Document $lease -Depth 6 }
        Global:MdrRetention $script:rp | Out-Null
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -HaveCount 1
    }

    It 'asks for the hold again just before it deletes: a job that took the machine after the first look keeps every disk' {
        $script:rp = Global:MdrRun -State 'FAILED_ROLLED_BACK'
        Global:MdrEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(Global:MdrEntry 'vm1-os-restored-202610200700') -Force
            $d.safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue ([pscustomobject]@{ stamp = '202610200600'; pristineSnapshotId = "$($script:sub)/snapshots/vm1-pristine"; complete = $true
                    disks = @([pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = "$($script:sub)/disks/vm1-os-asitwas-202610200600"; diskName = 'vm1-os-asitwas-202610200600'; madeUtc = '2026-10-20T06:00:00Z' }) }) -Force }
        # Free when the cleanup reads the machines; held from then on.
        $global:mdr.holdAsks = 0
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $global:mdr.holdAsks++; $global:mdr.holdAsks -gt 1 }
        $r = Global:MdrRetention $script:rp
        @($r.MadeDisks) | Should -HaveCount 1 -Because 'the first look found the machine free'
        @($r.RollbackDisksBeforeMove) | Should -HaveCount 1
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' -or $_ -like 'read:*' }) | Should -HaveCount 0
    }

    It 'a hold that cannot be read counts as held: unknown never frees a disk for a delete' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfLeaseInfo { throw 'The store did not answer.' }
            Test-VmfMachineHeldNow -RunPath 'C:\nowhere' -VmId 'vm' | Should -BeTrue
            Mock Get-VmfLeaseInfo { $null }
            Test-VmfMachineHeldNow -RunPath 'C:\nowhere' -VmId 'vm' | Should -BeFalse
        }
    }

    It 'the hold keeps the rollback disks before the move too' {
        $script:rp = Global:MdrRun -State 'FAILED_ROLLED_BACK'
        Global:MdrEdit $script:rp { param($d)
            $d.safety | Add-Member -NotePropertyName rollbackDisksBeforeMove -NotePropertyValue ([pscustomobject]@{ stamp = '202610200600'; pristineSnapshotId = "$($script:sub)/snapshots/vm1-pristine"; complete = $true
                    disks = @([pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = "$($script:sub)/disks/vm1-os-asitwas-202610200600"; diskName = 'vm1-os-asitwas-202610200600'; madeUtc = '2026-10-20T06:00:00Z' }) }) -Force }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId } { param($rp, $id) New-VmfLease -RunPath $rp -VmId $id -WorkerId 'restore:op-1' | Out-Null }
        Global:MdrRetention $script:rp | Out-Null
        @($global:mdr.calls | Where-Object { $_ -like 'deleteById:*' }) | Should -HaveCount 0
    }
}

Describe 'MADE-DISK-RECORD-1: a disk comes off the list once it is in use' {
    It 'a rollback marks the disk it made as used when the machine runs on it (Set-VmfRollbackRecord)' {
        $script:rp = Global:MdrRun -State 'VALIDATING'
        try {
            Global:MdrEdit $script:rp { param($d) $d | Add-Member -NotePropertyName rollbackDisksDuringRollback -NotePropertyValue @((Global:MdrEntry 'os-asitwas'), (Global:MdrEntry 'd0-asitwas' 0), (Global:MdrEntry 'spare' 0)) -Force }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; id = $script:vmId; sub = $script:sub } { param($rp, $id, $sub)
                $ctx = [pscustomobject]@{ RunPath = $rp; VmId = $id }
                Set-VmfRollbackRecord -Context $ctx -Path 'A' -OsDisk ([ordered]@{ id = "$sub/disks/os-asitwas"; name = 'os-asitwas' }) -DataDisks @([ordered]@{ lun = 0; diskId = "$sub/disks/d0-asitwas"; diskName = 'd0-asitwas' }) }
            $rb = @((Global:MdrDoc $script:rp).rollbackDisksDuringRollback)
            ($rb | Where-Object diskName -eq 'os-asitwas').usedUtc | Should -Not -BeNullOrEmpty
            ($rb | Where-Object diskName -eq 'd0-asitwas').usedUtc | Should -Not -BeNullOrEmpty
            ($rb | Where-Object diskName -eq 'spare').PSObject.Properties['usedUtc'] | Should -BeNullOrEmpty
        }
        finally { Remove-Item $script:rp -Recurse -Force }
    }
}

Describe 'MADE-DISK-RECORD-1: the contract, vm-state v26' {
    It 'the store, the schema and the sample say 26, and the sample holds restoreDisks' {
        $schema = Get-Content $script:schemaFile -Raw | ConvertFrom-Json
        $schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
        $sampleText = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw
        Test-Json -Json $sampleText -SchemaFile $script:schemaFile -ErrorAction Stop | Should -BeTrue
        $sample = $sampleText | ConvertFrom-Json
        $sample.schemaVersion | Should -Be 51
        $sample.restoreDisks | Should -Not -BeNullOrEmpty
        @($sample.restoreDisks | Where-Object { $_.usedUtc }) | Should -Not -BeNullOrEmpty
    }

    It 'each list takes usedUtc and deletedUtc, and stays closed' {
        foreach ($list in 'rollbackDisksDuringRollback', 'restoreDisks') {
            $base = { param($e) '{"schemaVersion":51,"runId":"r","vmId":"v","state":"MIGRATED","history":[],"' + $list + '":[' + $e + ']}' }
            Test-Json -Json (& $base '{"diskId":"/d/1","diskName":"d1","lun":null,"madeUtc":"2026-10-20T07:00:00Z","usedUtc":"2026-10-20T07:30:00Z","deletedUtc":"2026-10-21T07:00:00Z"}') -SchemaFile $script:schemaFile -ErrorAction Stop | Should -BeTrue -Because $list
            { if (-not (Test-Json -Json (& $base '{"diskId":"/d/1","diskName":"d1","madeUtc":"2026-10-20T07:00:00Z","madeUp":1}') -SchemaFile $script:schemaFile -ErrorAction Stop)) { throw 'not valid' } } | Should -Throw -Because $list
            { if (-not (Test-Json -Json (& $base '{"diskName":"d1","madeUtc":"2026-10-20T07:00:00Z"}') -SchemaFile $script:schemaFile -ErrorAction Stop)) { throw 'not valid' } } | Should -Throw -Because $list
        }
    }

    It 'the migration note says what changed' {
        (Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw) | Should -Match '## vm-state v25 -> v26 \(2026-10-23, MADE-DISK-RECORD-1\)'
    }
}

Describe 'MADE-DISK-RECORD-1: the daily cleanup starts for these disks too' {
    It 'the scheduler counts the disks a put-back made, as it counts the rollback disks' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1')
        $code | Should -Match '\$madeDue = @\(\$preview\.MadeDisks\)\.Count'
        $code | Should -Match '\$eligible -eq 0 -and \$disksDue -eq 0 -and \$madeDue -eq 0'
    }
}
