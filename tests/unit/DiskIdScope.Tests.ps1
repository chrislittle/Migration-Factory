#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DISK-ID-SCOPE-1: a delete by disk id checks more than the form of the id.
#
# Remove-VmfManagedDiskById and Get-VmfManagedDiskAttachment asked only
# Assert-VmfResourceId, which checks the FORM of a resource id. So a disk id on
# a machine's record that named a snapshot, or a disk in another subscription
# or another resource group, would be read and deleted as if it were a disk the
# product made for that machine. Hardening: the engine writes those ids from
# Azure's own answers, and no known input path changes them.
#
# The rules held here:
#   - both functions take a resource of the type Microsoft.Compute/disks only;
#   - a delete names the machine, and refuses a disk outside the machine's
#     subscription, or outside the resource groups the product makes disks in:
#     the machine's own, and the resource group of a disk the machine's record
#     names (a restore that keeps the names makes its disk where the original
#     disk is);
#   - the cleanup refuses such a disk BEFORE any Azure call - not even the read;
#   - every place the product makes a disk still has that disk deleted.
#
# Where the product makes a disk, and in which resource group (2026-10-31):
#   - the rollback disks (SAFETY_PRISTINE, New-VmfRollbackDisksBeforeMove):
#     the machine's ($Context.Rg);
#   - a rollback (rollbackDisksDuringRollback, Path A and Path B): the machine's;
#   - Rebuild this machine (recoveryDisks): the machine's;
#   - Restore this machine with new names, and its temporary disks when it
#     keeps the names (restoreDisks): the machine's;
#   - Restore this machine keeping the names (restoreDisks): the resource group
#     of the disk it replaces ($current.resourceGroup, currentResourceGroup);
#   - Premium SSD during the move (OLD-SKU-1C) changes the type of the disk in
#     place and makes no disk. A safety copy is a snapshot, deleted by its own
#     function.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-in above.
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:subId = '00000000-0000-0000-0000-000000000000'
    $script:otherSubId = '11111111-2222-3333-4444-555555555555'
    $script:vmId = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1"
    function Global:DisDisk([string]$Rg, [string]$Name, [string]$Sub = $script:subId) {
        "/subscriptions/$Sub/resourceGroups/$Rg/providers/Microsoft.Compute/disks/$Name"
    }
    $script:snapshotId = "/subscriptions/$($script:subId)/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine"

    # Azure, by resource id: every request is kept, a GET finds an unattached
    # disk, a DELETE is accepted.
    function Global:DisMockAzure {
        $global:dis = @{ calls = [System.Collections.Generic.List[string]]::new(); attached = @{} }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $global:dis.calls.Add("$Method $(($Path -split '[?]')[0])")
            if ($Method -eq 'GET') {
                $id = ($Path -split '[?]')[0]
                $body = @{ id = $id; properties = @{ creationData = @{ sourceResourceId = '' } } }
                if ($global:dis.attached.ContainsKey($id)) { $body.managedBy = $global:dis.attached[$id] }
                return [pscustomobject]@{ StatusCode = 200; Content = ($body | ConvertTo-Json -Depth 5) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = '' }
        }
    }

    # A machine in rg-app whose OS disk is in rg-os and whose data disk is in
    # rg-data: Azure lets a machine use a disk in another resource group of
    # its subscription. The machine's move has ended.
    function Global:DisRun {
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-dis-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; os = (DisDisk 'rg-os' 'vm1-os'); d0 = (DisDisk 'rg-data' 'vm1-d0')
            nic = "/subscriptions/$($script:subId)/resourceGroups/rg-net/providers/Microsoft.Network/networkInterfaces/vm1-nic"
            snap = "/subscriptions/$($script:subId)/resourceGroups/rg-copies/providers/Microsoft.Compute/snapshots/vm1-pristine"
            far = (DisDisk 'rg-far' 'vm1-far' $script:otherSubId) } {
            param($rp, $id, $os, $d0, $nic, $snap, $far)
            Initialize-VmfRun -RunPath $rp -RunId 'dis' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'dis' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{
                        name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @()
                        osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = $os }
                        dataDisks = @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; skuName = 'Premium_LRS'; managedDiskId = $d0 })
                        # Ids of other types, and a disk in another
                        # subscription, on the same record: none of them is a
                        # resource group the product makes a disk in.
                        nics = @([pscustomobject]@{ id = $nic }); copyId = $snap; strayDiskId = $far } }) -Force
            $doc.state = 'MIGRATED'
            $doc.history = @([pscustomobject]@{ state = 'MIGRATED'; tsUtc = '2026-10-20T08:00:00Z'; outcome = 'ok' })
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                        assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                        target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; path = 'A'; policy = [ordered]@{ keepSnapshotDays = 30 } }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }
    function Global:DisEdit($rp, [scriptblock]$Change) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; ch = $Change } {
            param($rp, $id, $ch)
            $d = Read-VmfStateDoc -RunPath $rp -VmId $id
            & $ch $d
            Write-VmfStateDoc -RunPath $rp -Document $d
        }
    }
    function Global:DisDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:DisEntry([string]$DiskId, $Lun = $null) {
        [pscustomobject]@{ diskId = $DiskId; diskName = ($DiskId -split '/')[-1]; lun = $Lun; madeUtc = '2026-10-20T07:00:00Z' }
    }
    function Global:DisClean($rp, [object[]]$Disks) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; disks = $Disks } {
            param($rp, $id, $disks)
            Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $rp -VmId $id -Disks $disks -Step 'retention'
        }
    }
    function Global:DisCallsFor([string]$DiskId) { @($global:dis.calls | Where-Object { $_ -like "* $DiskId" }) }
}
AfterAll {
    Remove-Item function:DisDisk, function:DisMockAzure, function:DisRun, function:DisEdit, function:DisDoc, function:DisEntry, function:DisClean, function:DisCallsFor -ErrorAction SilentlyContinue
    Remove-Item function:Invoke-AzRestMethod -ErrorAction SilentlyContinue
    Remove-Variable dis -Scope Global -ErrorAction SilentlyContinue
}

Describe 'DISK-ID-SCOPE-1: the read and the delete by disk id take a managed disk only' {
    BeforeEach { Global:DisMockAzure }

    It 'the read refuses <what>, and Azure is not asked' -ForEach @(
        @{ what = 'a snapshot id'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine' }
        @{ what = 'a machine id'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1' }
        @{ what = 'a resource under a disk'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os/providers/Microsoft.Authorization/locks/vmf' }
        @{ what = 'a disk of another provider'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Contoso.Compute/disks/vm1-os' }
        @{ what = 'a disk name with a query'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os?x=1' }
        @{ what = 'a disk name with a fragment'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os#f' }
        @{ what = 'a disk name with an encoded slash'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1%2F..' }
        @{ what = 'a disk id that ends in a line feed'; id = ('/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os' + [char]10) }    ) {
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id } { param($id) Get-VmfManagedDiskAttachment -DiskId $id } } |
            Should -Throw '*Microsoft.Compute/disks*'
        $global:dis.calls | Should -HaveCount 0
    }

    It 'the delete refuses <what>, and Azure is not asked' -ForEach @(
        @{ what = 'a snapshot id'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine' }
        @{ what = 'a resource under a disk'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os/providers/Microsoft.Authorization/locks/vmf' }
    ) {
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $script:vmId } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm } } |
            Should -Throw '*Microsoft.Compute/disks*'
        $global:dis.calls | Should -HaveCount 0
    }

    It 'the read takes a managed disk id, whatever the case of its type' {
        $id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/microsoft.compute/Disks/vm1-os'
        $r = InModuleScope VmMigrationFactory -Parameters @{ id = $id } { param($id) Get-VmfManagedDiskAttachment -DiskId $id }
        $r.Exists | Should -BeTrue
        $global:dis.calls | Should -Be @("GET $id")
    }

    It 'the delete refuses a disk in another subscription than the machine, and Azure is not asked' {
        $id = Global:DisDisk 'rg-app' 'vm1-os' $script:otherSubId
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $script:vmId } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm } } |
            Should -Throw '*not in the subscription of the machine*'
        $global:dis.calls | Should -HaveCount 0
    }

    It 'the delete refuses a disk in another resource group, and Azure is not asked' {
        $id = Global:DisDisk 'rg-other' 'vm1-os'
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $script:vmId } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm -ResourceGroupNames @('rg-os') } } |
            Should -Throw '*not in a resource group*'
        $global:dis.calls | Should -HaveCount 0
    }

    It 'the delete refuses a machine id with a query, and Azure is not asked' {
        $vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1?x=1'
        $id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os'
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $vm } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm } } |
            Should -Throw '*Microsoft.Compute/virtualMachines*'
        $global:dis.calls | Should -HaveCount 0
    }
    It 'the delete refuses a machine id that is not a virtual machine, and Azure is not asked' {
        $id = Global:DisDisk 'rg-app' 'vm1-os'
        { InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $script:snapshotId } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm } } |
            Should -Throw '*Microsoft.Compute/virtualMachines*'
        $global:dis.calls | Should -HaveCount 0
    }

    It 'the delete takes a disk in the resource group of the machine' {
        $id = Global:DisDisk 'rg-app' 'vm1-os-asitwas-202610200700'
        InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $script:vmId } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm }
        $global:dis.calls | Should -Be @("DELETE $id")
    }

    It 'the delete takes a disk in a resource group the caller names, whatever its case' {
        $id = Global:DisDisk 'RG-OS' 'vm1-os'
        InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $script:vmId } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm -ResourceGroupNames @('rg-data', 'rg-os') }
        $global:dis.calls | Should -Be @("DELETE $id")
    }

    It 'the delete takes the machine id with its subscription in another case' {
        $id = Global:DisDisk 'rg-app' 'vm1-os'
        $vm = $script:vmId -replace '/resourceGroups/rg-app/', '/resourceGroups/RG-APP/'
        InModuleScope VmMigrationFactory -Parameters @{ id = $id; vm = $vm } { param($id, $vm) Remove-VmfManagedDiskById -DiskId $id -MachineId $vm }
        $global:dis.calls | Should -Be @("DELETE $id")
    }
}

Describe 'DISK-ID-SCOPE-1: the resource groups the product makes disks in for one machine' {
    It 'the resource groups of the disks the record names, in the subscription of the machine - never the resource group of another type' {
        $doc = [pscustomobject]@{ vmId = $script:vmId
            captured = [pscustomobject]@{ vmConfig = [pscustomobject]@{
                    osDisk = [pscustomobject]@{ managedDiskId = (Global:DisDisk 'rg-os' 'vm1-os') }
                    dataDisks = @([pscustomobject]@{ lun = 0; managedDiskId = (Global:DisDisk 'rg-data' 'vm1-d0') })
                    nics = @([pscustomobject]@{ id = "/subscriptions/$($script:subId)/resourceGroups/rg-net/providers/Microsoft.Network/networkInterfaces/vm1-nic" })
                    copyId = "/subscriptions/$($script:subId)/resourceGroups/rg-copies/providers/Microsoft.Compute/snapshots/vm1-pristine"
                    strayDiskId = (Global:DisDisk 'rg-far' 'vm1-far' $script:otherSubId) } }
            # A restore that kept the names records the disk it replaced.
            restore = [pscustomobject]@{ previousDiskId = (Global:DisDisk 'rg-restored' 'vm1-os') } }
        $rgs = InModuleScope VmMigrationFactory -Parameters @{ d = $doc; vm = $script:vmId } { param($d, $vm) @(Get-VmfMadeDiskResourceGroups -StateDoc $d -VmId $vm) }
        @($rgs | Sort-Object) | Should -Be @('rg-app', 'rg-data', 'rg-os', 'rg-restored')
    }

    It 'with no record, the resource group of the machine only' {
        $rgs = InModuleScope VmMigrationFactory -Parameters @{ vm = $script:vmId } { param($vm) @(Get-VmfMadeDiskResourceGroups -StateDoc $null -VmId $vm) }
        $rgs | Should -Be @('rg-app')
    }
}

Describe 'DISK-ID-SCOPE-1: the cleanup refuses a disk outside the machine before any Azure call' {
    BeforeEach { Global:DisMockAzure; $script:rp = Global:DisRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'refuses <what>: no read, no delete, the disk is named as not deleted, and the record keeps it' -ForEach @(
        @{ what = 'a snapshot id'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/snapshots/vm1-pristine'; why = '*Microsoft.Compute/disks*' }
        @{ what = 'a disk in another subscription'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-os-restored-202610200700'; why = '*not in the subscription of the machine*' }
        @{ what = 'a disk in another resource group'; id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-other/providers/Microsoft.Compute/disks/vm1-os-restored-202610200700'; why = '*not in a resource group*' }
    ) {
        $entry = Global:DisEntry $id
        Global:DisEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @($entry) -Force }.GetNewClosure()
        $row = Global:DisEntry $id; $row | Add-Member -NotePropertyName List -NotePropertyValue 'restoreDisks'
        $result = Global:DisClean $script:rp @($row)
        $global:dis.calls | Should -HaveCount 0 -Because 'the disk is refused before the read'
        @($result.Deleted) | Should -HaveCount 0
        @($result.Failed) | Should -HaveCount 1
        $result.Failed[0].why | Should -BeLike $why
        $kept = @((Global:DisDoc $script:rp).restoreDisks)[0]
        $kept.PSObject.Properties['deletedUtc'] | Should -BeNullOrEmpty
        $kept.PSObject.Properties['usedUtc'] | Should -BeNullOrEmpty
    }

    It 'refuses one disk and still deletes the others' {
        $bad = Global:DisDisk 'rg-other' 'vm1-x'
        $good = Global:DisDisk 'rg-app' 'vm1-os-restored-202610200700'
        Global:DisEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @((Global:DisEntry $bad), (Global:DisEntry $good)) -Force }.GetNewClosure()
        $rows = @((Global:DisEntry $bad), (Global:DisEntry $good)) | ForEach-Object { $_ | Add-Member -NotePropertyName List -NotePropertyValue 'restoreDisks' -PassThru }
        $result = Global:DisClean $script:rp $rows
        @(Global:DisCallsFor $bad) | Should -HaveCount 0
        @(Global:DisCallsFor $good) | Should -Be @("GET $good", "DELETE $good")
        @($result.Deleted) | Should -Be @('vm1-os-restored-202610200700')
    }
}

Describe 'DISK-ID-SCOPE-1: every disk the product makes is still deleted' {
    BeforeEach { Global:DisMockAzure; $script:rp = Global:DisRun }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It '<what> (<list>, in <rg>) is read and deleted' -ForEach @(
        @{ what = 'a rollback disk'; list = 'rollbackDisksDuringRollback'; rg = 'rg-app'; name = 'vm1-os-asitwas-202610200700' }
        @{ what = 'a Restore this machine disk with a new name'; list = 'restoreDisks'; rg = 'rg-app'; name = 'vm1-d0-d0-restored-202610200700' }
        @{ what = 'a temporary disk of a restore that keeps the names'; list = 'restoreDisks'; rg = 'rg-app'; name = 'vm1-os-rtmp-202610200700' }
        @{ what = 'an OS disk a restore that keeps the names made where the OS disk is'; list = 'restoreDisks'; rg = 'rg-os'; name = 'vm1-os-unused' }
        @{ what = 'a data disk a restore that keeps the names made where the data disk is'; list = 'restoreDisks'; rg = 'rg-data'; name = 'vm1-d0-unused' }
    ) {
        $id = Global:DisDisk $rg $name
        $listName = $list
        Global:DisEdit $script:rp { param($d) $d | Add-Member -NotePropertyName $listName -NotePropertyValue @(Global:DisEntry $id) -Force }.GetNewClosure()
        $row = Global:DisEntry $id; $row | Add-Member -NotePropertyName List -NotePropertyValue $list
        $result = Global:DisClean $script:rp @($row)
        $global:dis.calls | Should -Be @("GET $id", "DELETE $id")
        @($result.Deleted) | Should -Be @($name)
        @((Global:DisDoc $script:rp).$list)[0].deletedUtc | Should -Not -BeNullOrEmpty
    }

    It 'a rollback disk (safety.rollbackDisksBeforeMove, in the resource group of the machine) is deleted when the move is complete' {
        $id = Global:DisDisk 'rg-app' 'vm1-os-wayback-202610200700'
        $snap = $script:snapshotId
        Global:DisEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null
                    rollbackDisksBeforeMove = [pscustomobject]@{ pristineSnapshotId = $snap; complete = $true; zone = $null
                        disks = @([pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = $id; diskName = 'vm1-os-wayback-202610200700'; snapshotId = $snap; skuName = 'Premium_LRS' }) } }) -Force
        }.GetNewClosure()
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } { param($rp, $vm)
            Remove-VmfUnusedRollbackDisksBeforeMove -Context ([pscustomobject]@{ RunPath = $rp; VmId = $vm; Rg = 'rg-app' }) }
        $global:dis.calls | Should -Be @("GET $id", "DELETE $id")
        (Global:DisDoc $script:rp).safety.rollbackDisksBeforeMove.disks[0].deletedUtc | Should -Not -BeNullOrEmpty
    }

    It 'the cleanup after a move refuses a rollback disk in another resource group, and says so' {
        $id = Global:DisDisk 'rg-other' 'vm1-os-wayback-202610200700'
        $snap = $script:snapshotId
        Global:DisEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null
                    rollbackDisksBeforeMove = [pscustomobject]@{ pristineSnapshotId = $snap; complete = $true; zone = $null
                        disks = @([pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = $id; diskName = 'vm1-os-wayback-202610200700'; snapshotId = $snap; skuName = 'Premium_LRS' }) } }) -Force
        }.GetNewClosure()
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } { param($rp, $vm)
            Remove-VmfUnusedRollbackDisksBeforeMove -Context ([pscustomobject]@{ RunPath = $rp; VmId = $vm; Rg = 'rg-app' }) }
        $global:dis.calls | Should -HaveCount 0
        $said = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } |
            Where-Object { [string]$_.detail -like '*were not deleted*' })
        $said | Should -HaveCount 1
        $said[0].detail | Should -BeLike '*vm1-os-wayback-202610200700*not in a resource group*'
    }

    # CANNOTDELETE-RESTORE-1: a CanNotDelete lock on the resource group refuses
    # the delete. The record named the disk with the words of Azure only, and
    # said the daily cleanup tries again - which the lock refuses every day.
    It 'CANNOTDELETE-RESTORE-1: the cleanup after a move names the lock that refuses the delete, and says the daily cleanup cannot delete the disk while it is on' {
        $id = Global:DisDisk 'rg-app' 'vm1-os-wayback-202610200700'
        $snap = $script:snapshotId
        Global:DisEdit $script:rp { param($d)
            $d | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $null; cloneVmId = $null
                    rollbackDisksBeforeMove = [pscustomobject]@{ pristineSnapshotId = $snap; complete = $true; zone = $null
                        disks = @([pscustomobject]@{ lun = $null; name = 'vm1-os'; diskId = $id; diskName = 'vm1-os-wayback-202610200700'; snapshotId = $snap; skuName = 'Premium_LRS' }) } }) -Force
        }.GetNewClosure()
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { throw 'ScopeLocked: the scope is locked.' }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @('keep-prod (CanNotDelete)') }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmId } { param($rp, $vm)
            Remove-VmfUnusedRollbackDisksBeforeMove -Context ([pscustomobject]@{ RunPath = $rp; VmId = $vm; Rg = 'rg-app' }) }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-app' -and $DiskName -eq 'vm1-os-wayback-202610200700' }
        $said = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } |
            Where-Object { [string]$_.detail -like '*were not deleted*' })
        $said | Should -HaveCount 1
        $said[0].outcome | Should -Be 'warn'
        $said[0].detail | Should -BeLike "*'vm1-os-wayback-202610200700' (a resource lock prevents the delete: keep-prod (CanNotDelete))*"
        $said[0].detail | Should -BeLike '*The daily cleanup cannot delete a disk while a resource lock prevents the delete.'
        (Global:DisDoc $script:rp).safety.rollbackDisksBeforeMove.disks[0].PSObject.Properties['deletedUtc'] | Should -BeNullOrEmpty -Because 'the record keeps the disk'
    }

    It 'CANNOTDELETE-RESTORE-1: a refused delete with no lock found, or a lock read that fails, keeps the words of Azure' -ForEach @(
        @{ case = 'no lock'; fails = $false }
        @{ case = 'the read fails'; fails = $true }
    ) {
        $id = Global:DisDisk 'rg-app' 'vm1-os-restored-202610200700'
        Global:DisEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @(Global:DisEntry $id) -Force }.GetNewClosure()
        $row = Global:DisEntry $id; $row | Add-Member -NotePropertyName List -NotePropertyValue 'restoreDisks'
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDiskById { throw 'Conflict: the disk is busy.' }
        $readFails = $fails
        if ($readFails) { Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { throw 'AuthorizationFailed' } }
        else { Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() } }
        $result = Global:DisClean $script:rp @($row)
        @($result.Failed) | Should -HaveCount 1
        $result.Failed[0].why | Should -BeLike '*Conflict: the disk is busy.*'
        $result.Failed[0].why | Should -Not -BeLike '*resource lock*'
        [bool]$result.Failed[0].locked | Should -BeFalse
    }

    It 'the daily cleanup deletes a restore disk in the resource group of the data disk, and refuses one in another resource group' {
        $good = Global:DisDisk 'rg-data' 'vm1-d0-unused'
        $bad = Global:DisDisk 'rg-other' 'vm1-d0-stray'
        Global:DisEdit $script:rp { param($d) $d | Add-Member -NotePropertyName restoreDisks -NotePropertyValue @((Global:DisEntry $good 0), (Global:DisEntry $bad 0)) -Force }.GetNewClosure()
        Mock -ModuleName VmMigrationFactory Test-VmfVmExists { $true }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Remove-VmfExpiredSafetyCopies -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -DeletedBy 'retention (scheduled)' `
            -AsOfUtc ([datetime]'2026-10-21T08:00:00Z') -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        @(Global:DisCallsFor $good) | Should -Be @("GET $good", "DELETE $good")
        @(Global:DisCallsFor $bad) | Should -HaveCount 0
        $made = @((Global:DisDoc $script:rp).restoreDisks)
        ($made | Where-Object { $_.diskId -eq $good }).deletedUtc | Should -Not -BeNullOrEmpty
        ($made | Where-Object { $_.diskId -eq $bad }).PSObject.Properties['deletedUtc'] | Should -BeNullOrEmpty
        $said = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } |
            Where-Object { [string]$_.detail -like '*did not delete these disks*' })
        $said | Should -HaveCount 1
        $said[0].detail | Should -BeLike "*'vm1-d0-stray'*not in a resource group*"
    }
}
