#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-DISKS-FIRST-1, found by the independent review of SAFETY-CMK-1.
#
# Since the decision of 2026-10-11 these documents are THE FALLBACK:
# they carry no record of rollback disks (a move from before
# vm-state v22), so each put-back makes its disks before the stop, as below.
# The main path - disks made at the end of SAFETY_PRISTINE and only swapped in
# - is RollbackDisksBeforeMove.Tests.ps1.
#
# The Path A rollback, the disks-only rollback and Restore this machine made
# the OS disk from its copy only AFTER they stopped the machine, turned
# accelerated networking off, left the reservation, set the disk types back
# and put the size and controller back. A disk Azure refused - or, since
# SAFETY-CMK-1 and SAFETY-ULTRA-1, one that came back on another key or with
# other values, or that could not be read back - stopped the put-back half
# done: the machine stopped, on its old size, with the converted OS disk.
# Path B already made every disk before it deleted the definition.
#
# Now every disk is made, and read back, before the put-back changes the
# machine. A disk that stops the put-back stops it with the machine as the
# failed step left it; the steps after keep their order (ROLLBACK-ORDER-1,
# ROLLBACK-RETRY-CAPTURE-3). The fakes below record every call that changes
# a machine or makes a disk, in order.
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

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
    $script:vmId = "$($script:sub)/virtualMachines/vm1"
    $script:des = "$($script:sub)/diskEncryptionSets/des-contoso"
    # The rollback checkpoint's time: the names of the disks a rollback makes
    # carry it, so a resume asks for the same names.
    $script:started = '2026-10-11T08:30:00.0000000Z'

    # One machine after a Path A move: the OS disk (customer-managed key) and
    # one Premium SSD data disk, both copied first, in a reservation.
    function Global:RdfNewRun {
        param([string]$Kind = '', [string]$State = 'VALIDATING')
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rdf-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:sub; des = $script:des; kind = $Kind; st = $State; started = $script:started } {
            param($rp, $id, $sub, $des, $kind, $st, $started)
            Initialize-VmfRun -RunPath $rp -RunId 'rdf' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rdf' -VmId $id | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]@{ name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @(); capacityReservationGroupId = $null
                        osDisk = [pscustomobject]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-osdisk"
                            encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $des }
                        dataDisks = @([pscustomobject]@{ name = 'vm1-data0'; lun = 0; managedDiskId = "$sub/disks/vm1-data0"; caching = 'ReadOnly'; sizeGB = 128; skuName = 'Premium_LRS'
                                encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $des })
                        nics = @(); tags = @{} } }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = "$sub/snapshots/vm1-prepared"; cloneVmId = $null; locksAllowed = $true
                    pristineSnapshotId = "$sub/snapshots/vm1-pristine"; pristineSnapshotLocked = $true
                    pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-data0"; snapshotId = "$sub/snapshots/vm1-pristine-d0"; locked = $true }) }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            if ($kind) {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState $st -Outcome ok | Out-Null
                $ctx = New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = 'A'; wave = 'w1'; target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'rdf'
                Set-VmfRollbackPending -Context $ctx -Kind $kind -State $st -ReasonCode 'validationFailed' -Detail 'The health check did not answer.'
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc.rollbackPending.startedUtc = $started
                $null = Complete-VmfTestCapture $doc
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        $rp
    }
    function Global:RdfCtx($rp, [string]$Path = 'A') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; path = $Path } {
            param($rp, $id, $path)
            New-VmfContext -PlanEntry ([pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; path = $path; wave = 'w1'
                    target = [pscustomobject]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; policy = [pscustomobject]@{} }) -RunPath $rp -RunId 'rdf'
        }
    }
    function Global:RdfDoc($rp) { InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id } }
    function Global:RdfLog($rp) { (Get-ChildItem $rp -Recurse -File | Where-Object Name -Match 'event' | ForEach-Object { Get-Content $_.FullName -Raw }) -join "`n" }

    # Azure, for a rollback. A disk name that matches $rdf.refuse is refused;
    # $rdf.gotEnc is the encryption Azure reads back for a disk made from a
    # copy. A disk asked for again by its name is returned, as
    # New-VmfDiskFromSnapshot does.
    function Global:RdfMockAzure {
        # MADE-DISK-NAMED-1: a disk whose name matches $rdf.badEnc is made, and
        # reads back on a platform key - Azure made it, and it must not be used.
        $global:rdf = @{ calls = [System.Collections.Generic.List[string]]::new(); disks = @{}; refuse = '^$'; gotEnc = 'EncryptionAtRestWithCustomerKey'; readBackFails = $false; badEnc = '' }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rdf.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { $global:rdf.calls.Add('start') }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { "$($script:sub)/capacityReservationGroups/crg1" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup { $global:rdf.calls.Add('leaveReservation') }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:rdf.calls.Add("size:$Size") }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-osdisk'; id = "$($script:sub)/disks/vm1-osdisk"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            if ($DiskName -match $global:rdf.refuse) { $global:rdf.calls.Add("refused:$DiskName"); throw "QuotaExceeded: Azure did not make the disk '$DiskName'." }
            if ($global:rdf.disks.ContainsKey($DiskName)) { $global:rdf.calls.Add("existing:$DiskName"); return $global:rdf.disks[$DiskName] }
            $global:rdf.calls.Add("create:$DiskName")
            $global:rdf.disks[$DiskName] = "$($script:sub)/disks/$DiskName"
            $global:rdf.disks[$DiskName]
        }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts {
            if ($global:rdf.readBackFails) { throw 'The read was refused.' }
            $enc = if ($global:rdf.badEnc -and (($DiskId -split '/')[-1]) -match $global:rdf.badEnc) { 'EncryptionAtRestWithPlatformKey' } else { $global:rdf.gotEnc }
            [pscustomobject]@{ id = $DiskId; encryptionType = $enc; diskEncryptionSetId = $(if ($enc -eq 'EncryptionAtRestWithPlatformKey') { $null } else { $script:des }) }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rdf.calls.Add("os:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfVmDataDisks { $global:rdf.calls.Add('data'); @{ Applied = $true } }
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { [pscustomobject]@{ Name = 'vm1' } }
        Mock -ModuleName VmMigrationFactory Set-VmfNicAcceleratedNetworking { $global:rdf.calls.Add('an'); $true }
        Mock -ModuleName VmMigrationFactory Set-VmfManagedDiskSku { $global:rdf.calls.Add('type') }
        Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskSku { [pscustomobject]@{ SkuName = 'Premium_LRS' } }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = 'x'; name = 'x' }) }
    }

    # Every call that changes the machine - anything but making a disk.
    function Global:RdfMachineCalls { @($global:rdf.calls | Where-Object { $_ -notmatch '^(create|existing|refused):' }) }
}
AfterAll {
    Remove-Item function:RdfNewRun, function:RdfCtx, function:RdfDoc, function:RdfLog, function:RdfMockAzure, function:RdfMachineCalls -ErrorAction SilentlyContinue
    Remove-Variable rdf -Scope Global -ErrorAction SilentlyContinue
}

Describe 'ROLLBACK-DISKS-FIRST-1: the Path A rollback makes every disk before it stops the machine' {
    BeforeEach { Global:RdfMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'the order: every disk made, stop, reservation, size, the OS swap, the data swap, start' {
        $script:rp = Global:RdfNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c }
        $calls = @($global:rdf.calls)
        $calls[0] | Should -BeLike 'create:vm1-osdisk-asitwas-*'
        $calls[1] | Should -BeLike 'create:vm1-data0-d0-asitwas-*'
        $calls[2] | Should -Be 'stop' -Because "the calls were: $($calls -join ', ')"
        @(Global:RdfMachineCalls) | Should -Be @('stop', 'leaveReservation', 'size:Standard_D2s_v4', ('os:' + ($calls[0] -replace '^create:')), 'data', 'start') -Because 'the steps after the disks keep their order (ROLLBACK-ORDER-1: the size before the swap)'
    }

    It 'an OS disk Azure refuses stops the rollback BEFORE the stop: the machine is untouched by the rollback' {
        $script:rp = Global:RdfNewRun
        $global:rdf.refuse = 'osdisk-asitwas'
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c } }
        catch { $err = $_ }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'QuotaExceeded'
        $err.Exception.Data['vmfRollbackUntouched'] | Should -BeTrue
        @(Global:RdfMachineCalls) | Should -HaveCount 0 -Because 'no stop, no accelerated networking, no reservation, no disk type, no size, no swap, no start'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup -Times 0
    }

    It 'an OS disk on another key (SAFETY-CMK-1) stops it before the stop, and the disk is on record by name' {
        $script:rp = Global:RdfNewRun
        $global:rdf.gotEnc = 'EncryptionAtRestWithPlatformKey'
        $err = $null
        try { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c } }
        catch { $err = $_ }
        $err.Exception.Message | Should -Match 'vm1-osdisk-asitwas-\d{12}'
        $err.Exception.Data['vmfRollbackUntouched'] | Should -BeTrue
        @(Global:RdfMachineCalls) | Should -HaveCount 0
        @((Global:RdfDoc $script:rp).rollbackDisksDuringRollback | Where-Object { $_.diskName -like 'vm1-osdisk-asitwas-*' }) | Should -HaveCount 1 -Because 'a disk that bills is never on no record'
    }

    It 'an OS disk that cannot be read back stops it before the stop' {
        $script:rp = Global:RdfNewRun
        $global:rdf.readBackFails = $true
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c } } | Should -Throw '*could not read it back*'
        @(Global:RdfMachineCalls) | Should -HaveCount 0
    }

    It 'SAFETY-ULTRA-MARGIN-1: a data disk Azure refuses stops the rollback before the stop, naming it - every disk goes back, or none' {
        # Was: the disk kept its old disk and the rollback went on (since
        # 2026-10-16: every disk goes back to its copy, or the put-back does
        # not start - the full rollback rule).
        $script:rp = Global:RdfNewRun
        $global:rdf.refuse = 'data0-d0-asitwas'
        { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c } } |
            Should -Throw "A data disk cannot be made from the safety copy: 'vm1-data0' on LUN 0 (Azure did not make*Every disk is restored from its copy, or the product changes nothing."
        $calls = @($global:rdf.calls)
        $calls | Should -Contain ($calls | Where-Object { $_ -like 'refused:*' } | Select-Object -First 1)
        $calls | Should -Not -Contain 'stop' -Because 'the machine is left as the failed step left it'
        $calls | Should -Not -Contain 'data'
        $calls | Should -Not -Contain 'start'
    }

    It 'through the checkpoint: a refused OS disk is a failed rollback whose words say the rollback changed nothing, and name the disk' {
        $script:rp = Global:RdfNewRun -Kind 'full'
        $global:rdf.refuse = 'osdisk-asitwas'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'rollbackFailed'
        $stop.machineState | Should -Be 'changed' -Because 'the move changed the machine'
        $stop.detail | Should -Match 'the rollback stopped before it changed the machine'
        $stop.detail | Should -Match "vm1-osdisk-asitwas-202610110830"
        $stop.detail | Should -Match 'as the failed step left it'
        $stop.detail | Should -Match 'health check did not answer' -Because 'the original cause stays on record'
        $final.PSObject.Properties['rollbackPending'] | Should -BeNullOrEmpty
    }

    It 'review: a size Azure refuses after the disks are made - the stop names every disk the rollback made, which bills' {
        $script:rp = Global:RdfNewRun -Kind 'full'
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { $global:rdf.calls.Add("size:$Size"); throw 'The requested VM size is not available in the current region. ErrorCode: SkuNotAvailable' }
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $stop = @($final.history)[-1]
        # ROLLBACK-CAPACITY-1: a refused size has its own reason (case B).
        $stop.reasonCode | Should -Be 'rollbackSizeRefused'
        $stop.detail | Should -Not -Match 'before it changed the machine' -Because 'the rollback stopped the machine'
        $stop.detail | Should -Match "each is kept: 'vm1-osdisk-asitwas-202610110830', 'vm1-data0-d0-asitwas-202610110830'\."
    }

    It 'review: a refused OS disk on the first run names no disk it did not make' {
        $script:rp = Global:RdfNewRun -Kind 'full'
        $global:rdf.refuse = 'osdisk-asitwas'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        (@($final.history)[-1]).detail | Should -Not -Match 'each is kept'
    }

    It 'a machine a failed start left stopped stays stopped: a refused disk starts nothing' {
        # STARTING failed: the machine is deallocated on the target size.
        $script:rp = Global:RdfNewRun -Kind 'full' -State 'STARTING'
        $global:rdf.refuse = 'osdisk-asitwas'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
    }

    It 'kill-resume: a worker that stops after the disks are made and before the stop - the resume uses the SAME disks, and finishes' {
        $script:rp = Global:RdfNewRun -Kind 'full'
        $global:rdfDied = $false
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            $global:rdf.calls.Add('stop')
            if (-not $global:rdfDied) { $global:rdfDied = $true; throw 'Lease lost - abandon this VM.' }
        }
        try {
            { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
            (Global:RdfDoc $script:rp).rollbackPending.kind | Should -Be 'full' -Because 'the checkpoint stays until the rollback is done'
            $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        }
        finally { Remove-Variable rdfDied -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        $calls = @($global:rdf.calls)
        @($calls | Where-Object { $_ -like 'create:*' }) | Should -Be @('create:vm1-osdisk-asitwas-202610110830', 'create:vm1-data0-d0-asitwas-202610110830') -Because 'the names come from the checkpoint, so each disk is made once'
        @($calls | Where-Object { $_ -like 'existing:*' }) | Should -HaveCount 2 -Because 'the resume asks for the same disks again'
        @((Global:RdfDoc $script:rp).rollbackDisksDuringRollback) | Should -HaveCount 2
        @($calls | Where-Object { $_ -like 'size:*' }) | Should -HaveCount 1
        @($calls | Where-Object { $_ -like 'os:*' }) | Should -Be @('os:vm1-osdisk-asitwas-202610110830')
        $calls[-1] | Should -Be 'start'
    }

    It 'kill-resume: a worker that stops after the size went back - the resume swaps the disks it made, never makes others' {
        $script:rp = Global:RdfNewRun -Kind 'full'
        $global:rdfDied = $false
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk {
            $global:rdf.calls.Add("os:$DiskName")
            if (-not $global:rdfDied) { $global:rdfDied = $true; throw 'Lease lost - abandon this VM.' }
        }
        try {
            { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
            $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        }
        finally { Remove-Variable rdfDied -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:rdf.calls | Where-Object { $_ -like 'create:*' }) | Should -HaveCount 2
        @($global:rdf.calls | Where-Object { $_ -like 'os:*' } | Select-Object -Unique) | Should -Be @('os:vm1-osdisk-asitwas-202610110830')
    }
}

Describe 'ROLLBACK-DISKS-FIRST-1: the disks-only rollback before the move' {
    BeforeEach { Global:RdfMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'the order: every disk made, stop, the OS swap, the data swap, start - no hardware step' {
        $script:rp = Global:RdfNewRun
        InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Invoke-VmfRollback -Context $c -GuestOnly }
        $calls = @($global:rdf.calls)
        $calls[0] | Should -BeLike 'create:vm1-osdisk-asitwas-*'
        $calls[1] | Should -BeLike 'create:vm1-data0-d0-asitwas-*'
        @(Global:RdfMachineCalls) | Should -Be @('stop', ('os:' + ($calls[0] -replace '^create:')), 'data', 'start')
    }

    It 'a refused OS disk stops it before the stop; the stop keeps its cause and says no disk changed' {
        $script:rp = Global:RdfNewRun -Kind 'disks' -State 'GUEST_PREP'
        $global:rdf.refuse = 'osdisk-asitwas'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $final.state | Should -Be 'FAILED_NEEDS_ATTENTION'
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'validationFailed' -Because 'no disk changed, so this is not a failed rollback (review F5)'
        $stop.detail | Should -Match 'stopped before it changed a disk'
        $stop.detail | Should -Match 'QuotaExceeded'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Because 'the rollback never stopped the machine'
        @($global:rdf.calls | Where-Object { $_ -like 'os:*' -or $_ -eq 'data' }) | Should -HaveCount 0
    }

    It 'kill-resume: a worker that stops after the disks are made - the resume uses the same disks' {
        $script:rp = Global:RdfNewRun -Kind 'disks' -State 'GUEST_PREP'
        $global:rdfDied = $false
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated {
            $global:rdf.calls.Add('stop')
            if (-not $global:rdfDied) { $global:rdfDied = $true; throw 'Lease lost - abandon this VM.' }
        }
        try {
            { InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c } } | Should -Throw '*abandon this VM*'
            $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        }
        finally { Remove-Variable rdfDied -Scope Global -ErrorAction SilentlyContinue }
        $final.state | Should -Be 'FAILED_ROLLED_BACK'
        @($global:rdf.calls | Where-Object { $_ -like 'create:*' }) | Should -HaveCount 2
        @($global:rdf.calls | Where-Object { $_ -like 'existing:*' }) | Should -HaveCount 2
        @((Global:RdfDoc $script:rp).rollbackDisksDuringRollback) | Should -HaveCount 2
    }
}

# REBUILD-REMOVE-ENGINE-1: the Path B rollback is gone with its step. Its tests were here.

Describe 'ROLLBACK-DISKS-FIRST-1: the time in the names, pure' {
    It 'comes from the checkpoint, as text or as the date value ConvertFrom-Json makes' {
        InModuleScope VmMigrationFactory {
            Get-VmfRollbackStamp -Doc ([pscustomobject]@{ rollbackPending = [pscustomobject]@{ startedUtc = '2026-10-11T08:30:59.9000000Z' } }) | Should -Be '202610110830'
            $asDate = [datetime]::SpecifyKind([datetime]'2026-10-11T08:30:00', [System.DateTimeKind]::Utc)
            Get-VmfRollbackStamp -Doc ([pscustomobject]@{ rollbackPending = [pscustomobject]@{ startedUtc = $asDate } }) | Should -Be '202610110830'
            Get-VmfRollbackStamp -Doc (('{"rollbackPending":{"startedUtc":"2026-10-11T08:30:00Z"}}') | ConvertFrom-Json) | Should -Be '202610110830'
        }
    }
    It 'is the time now with no checkpoint' {
        InModuleScope VmMigrationFactory {
            $now = (Get-Date).ToUniversalTime()
            $got = Get-VmfRollbackStamp -Doc ([pscustomobject]@{})
            $got | Should -Match '^\d{12}$'
            ([datetime]::ParseExact($got, 'yyyyMMddHHmm', $null) - $now).TotalMinutes | Should -BeLessOrEqual 1
            Get-VmfRollbackStamp -Doc $null | Should -Match '^\d{12}$'
        }
    }
}

Describe 'ROLLBACK-DISKS-FIRST-1: Restore this machine makes every disk before it stops the machine' {
    BeforeAll {
        $script:rsub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute'
        # A machine after a move, on the target size, with one data disk.
        function Global:RdfRestoreRun {
            # MADE-DISK-NAMED-1: -Encrypted records a customer-managed key on
            # each disk, so a disk made from a copy is read back and compared.
            param([switch]$Encrypted)
            $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rdfr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; sub = $script:rsub; enc = [bool]$Encrypted; des = $script:des } {
                param($rp, $id, $sub, $enc, $des)
                Initialize-VmfRun -RunPath $rp -RunId 'rdfr' | Out-Null
                New-VmfStateDoc -RunPath $rp -RunId 'rdfr' -VmId $id -Wave 'w1' | Out-Null
                $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
                $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{
                            name = 'vm1'; size = 'Standard_D2s_v4'; controller = 'SCSI'; location = 'centralus'; osType = 'Linux'; zones = @(); capacityReservationGroupId = $null
                            osDisk = [pscustomobject]@{ name = 'vm1-os'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-os" }
                            dataDisks = @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; skuName = 'Premium_LRS'; managedDiskId = "$sub/disks/vm1-d0" })
                            tags = @{}; nics = @() } }) -Force
                # OLD-VERSION-READERS-REMOVE-4: every capture records each disk's
                # key, so every restore reads its disks back - -Encrypted is
                # kept for the tests that name it.
                foreach ($d in @(@($doc.captured.vmConfig.osDisk) + @($doc.captured.vmConfig.dataDisks))) {
                    $d | Add-Member -NotePropertyName encryptionType -NotePropertyValue 'EncryptionAtRestWithCustomerKey' -Force
                    $d | Add-Member -NotePropertyName diskEncryptionSetId -NotePropertyValue $des -Force
                }
                $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                        snapshotId = "$sub/snapshots/vm1-prepared"; pristineSnapshotId = "$sub/snapshots/vm1-pristine"
                        cloneVmId = $null; locksAllowed = $true; pristineSnapshotLocked = $true
                        pristineDataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-d0"; snapshotId = '/snap/pristine-d0'; locked = $true })
                        dataCopies = @([pscustomobject]@{ lun = 0; diskId = "$sub/disks/vm1-d0"; snapshotId = '/snap/prepared-d0'; locked = $true }) }) -Force
                $doc.state = 'MIGRATED'
                $null = Complete-VmfTestCapture $doc
                Write-VmfStateDoc -RunPath $rp -Document $doc
                $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $id; wave = 'w1'; ring = 'lab'
                            assessment = [ordered]@{ location = 'centralus'; os = 'Linux' }
                            target = [ordered]@{ size = 'Standard_D2s_v6'; controller = 'NVMe' }; path = 'A'; policy = [ordered]@{} }) }
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
            }
            $rp
        }
    }
    AfterAll { Remove-Item function:RdfRestoreRun -ErrorAction SilentlyContinue }
    BeforeEach {
        Global:RdfMockAzure
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo { [pscustomobject]@{ name = 'vm1-os'; id = "$($script:rsub)/disks/vm1-os"; resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = 'NVMe' } }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @([pscustomobject]@{ lun = 0; id = "$($script:rsub)/disks/vm1-d0"; name = 'vm1-d0'; resourceGroup = 'rg-app'; skuName = 'Premium_LRS' }) }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:rdf.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:rdf.calls.Add("allow:$DiskName") }
    }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'from the first copy, new names: every disk made, then stop, reservation, size, the swaps, start' {
        $script:rp = Global:RdfRestoreRun
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $calls = @($global:rdf.calls)
        $calls[0] | Should -BeLike 'create:vm1-os-restored-*'
        $calls[1] | Should -BeLike 'create:vm1-d0-d0-restored-*'
        @(Global:RdfMachineCalls) | Should -Be @('stop', 'leaveReservation', 'size:Standard_D2s_v4', ('os:' + ($calls[0] -replace '^create:')), 'data', 'start') -Because "the calls were: $($calls -join ', ')"
        @($calls | Where-Object { $_ -like 'create:*' }) | Should -HaveCount 2 -Because 'each disk is made once'
        @($calls | Where-Object { $_ -like 'existing:*' }) | Should -HaveCount 0 -Because 'nothing asks for a disk a second time after the stop'
    }

    It 'from the prepared copy on NVMe: the new disk is given NVMe before the stop, and before its swap' {
        $script:rp = Global:RdfRestoreRun
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false | Out-Null
        $calls = @($global:rdf.calls)
        $allow = [array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'allow:vm1-os-restored-*' } | Select-Object -First 1))
        $allow | Should -BeGreaterOrEqual 0
        $allow | Should -BeLessThan ([array]::IndexOf($calls, 'stop'))
        $calls | Should -Not -Contain 'size:Standard_D2s_v4' -Because 'the prepared copy keeps the size'
    }

    It 'from the first copy: an OS disk Azure refuses stops the restore before the stop - the machine is untouched' {
        $script:rp = Global:RdfRestoreRun
        $global:rdf.refuse = 'vm1-os-restored'
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } | Should -Throw '*stopped before it changed the machine*QuotaExceeded*'
        @(Global:RdfMachineCalls) | Should -HaveCount 0 -Because 'no stop, no reservation, no size, no swap, no start'
        Global:RdfLog $script:rp | Should -Match 'The restore stopped before it changed the machine'
    }

    It 'keeping the names: the temporary disks are made before the stop; each final disk only after the disk whose name it takes is deleted' {
        $script:rp = Global:RdfRestoreRun
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        $calls = @($global:rdf.calls)
        $stop = [array]::IndexOf($calls, 'stop')
        $calls[0] | Should -BeLike 'create:vm1-os-rtmp-*'
        $calls[1] | Should -BeLike 'create:vm1-d0-d0-rtmp-*'
        $stop | Should -Be 2 -Because "the calls were: $($calls -join ', ')"
        @($calls | Where-Object { $_ -like 'create:*rtmp*' }) | Should -HaveCount 2 -Because 'each temporary disk is made once'
        @($calls | Where-Object { $_ -like 'existing:*' }) | Should -HaveCount 0 -Because 'nothing asks for a temporary disk a second time after the stop'
        [array]::IndexOf($calls, 'create:vm1-os') | Should -BeGreaterThan ([array]::IndexOf($calls, 'delete:vm1-os'))
        [array]::IndexOf($calls, 'create:vm1-d0') | Should -BeGreaterThan ([array]::IndexOf($calls, 'delete:vm1-d0'))
        [array]::IndexOf($calls, 'size:Standard_D2s_v4') | Should -BeLessThan ([array]::IndexOf($calls, ($calls | Where-Object { $_ -like 'os:*rtmp*' } | Select-Object -First 1)))
        $calls[-1] | Should -Be 'start'
    }

    It 'review: a stop Azure refuses after the disks are made - the error names every disk made, which bills' {
        $script:rp = Global:RdfRestoreRun
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:rdf.calls.Add('stop'); throw 'OperationNotAllowed: the stop was refused.' }
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_ }
        $err.Exception.Message | Should -Match 'could not stop the machine: OperationNotAllowed'
        $err.Exception.Message | Should -Match "are kept: 'vm1-os-restored-\d{12}', 'vm1-d0-d0-restored-\d{12}'\."
        @(Global:RdfMachineCalls) | Should -Be @('stop') -Because 'nothing after the refused stop'
    }

    It 'review: a swap that fails after the stop - the error names the disks made that are not on the machine' {
        $script:rp = Global:RdfRestoreRun
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:rdf.calls.Add("os:$DiskName"); throw 'OperationNotAllowed: the swap was refused.' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } |
            Should -Throw "*the swap was refused*are kept: 'vm1-os-restored-*', 'vm1-d0-d0-restored-*has been restarted*"
    }

    It 'review: the OS disk made, then its controller setting refused before the stop - the error names the disk' {
        $script:rp = Global:RdfRestoreRun
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { throw 'OperationNotAllowed: the setting was refused.' }
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From prepared -Confirm:$false } |
            Should -Throw "*stopped before it changed the machine*The disk made from the safety copy is kept: 'vm1-os-restored-*"
        @(Global:RdfMachineCalls) | Should -HaveCount 0
    }

    It 'keeping the names: a temporary OS disk Azure refuses stops it before the stop, and deletes nothing' {
        $script:rp = Global:RdfRestoreRun
        $global:rdf.refuse = 'vm1-os-rtmp'
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false } | Should -Throw '*stopped before it changed the machine*'
        @(Global:RdfMachineCalls) | Should -HaveCount 0
    }

    It 'SAFETY-ULTRA-MARGIN-1: keeping the names, a temporary data disk Azure refuses stops the restore before the stop' {
        $script:rp = Global:RdfRestoreRun
        $global:rdf.refuse = 'vm1-d0-d0-rtmp'
        { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false } |
            Should -Throw "The restore stopped before it changed the machine:*'vm1-d0' on LUN 0*"
        @($global:rdf.calls | Where-Object { $_ -like 'refused:*' }) | Should -HaveCount 1 -Because 'it is never made twice'
        $global:rdf.calls | Should -Not -Contain 'stop'
        $global:rdf.calls | Should -Not -Contain 'delete:vm1-d0'
    }

    # MADE-DISK-NAMED-1: a data disk Azure MADE, then refused on its read-back
    # (another key, SAFETY-CMK-1), bills like any other disk. The error names
    # it with the disks made, as it names the OS disk - not only inside why.
    It 'MADE-DISK-NAMED-1, new names: a data disk made on another key is named with every disk made, and never goes on the machine' {
        $script:rp = Global:RdfRestoreRun -Encrypted
        $global:rdf.badEnc = 'vm1-d0-d0-restored'
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_.Exception.Message }
        $err | Should -Match 'The restore stopped before it changed the machine'
        $err | Should -Match "The disks made from the safety copy are kept: 'vm1-os-restored-\d{12}', 'vm1-d0-d0-restored-\d{12}'\."
        @(Global:RdfMachineCalls) | Should -HaveCount 0 -Because 'no stop and no swap: the refused disk never goes on the machine'
        Global:RdfLog $script:rp | Should -Match "kept: 'vm1-os-restored-\d{12}', 'vm1-d0-d0-restored-\d{12}'" -Because 'the fail line in the activity says it too'
    }

    It 'MADE-DISK-NAMED-1, keeping the names: a temporary data disk made on another key is named with every disk made' {
        $script:rp = Global:RdfRestoreRun -Encrypted
        $global:rdf.badEnc = 'vm1-d0-d0-rtmp'
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false } catch { $err = $_.Exception.Message }
        $err | Should -Match "The disks made from the safety copy are kept: 'vm1-os-rtmp-\d{12}', 'vm1-d0-d0-rtmp-\d{12}'\."
        @(Global:RdfMachineCalls) | Should -HaveCount 0 -Because 'nothing is stopped, swapped or deleted'
    }

    It 'MADE-DISK-NAMED-1: a data disk Azure did not make is not named as made' {
        $script:rp = Global:RdfRestoreRun
        $global:rdf.refuse = 'vm1-d0-d0-restored'
        $err = $null
        try { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From pristine -Confirm:$false } catch { $err = $_.Exception.Message }
        $err | Should -Match "The disk made from the safety copy is kept: 'vm1-os-restored-\d{12}'\."
        $err | Should -Not -Match "kept: [^.]*vm1-d0-d0-restored" -Because 'Azure made no such disk, so nothing of that name bills'
    }

}

Describe 'MADE-DISK-NAMED-1: a rollback names a data disk it made and then refused' {
    BeforeEach { Global:RdfMockAzure }
    AfterEach { if ($script:rp -and (Test-Path $script:rp)) { Remove-Item $script:rp -Recurse -Force } }

    It 'Path A: the stop names the data disk made on another key with every disk made, it is on record, and it never goes on the machine' {
        $script:rp = Global:RdfNewRun -Kind 'full'
        $global:rdf.badEnc = 'data0-d0-asitwas'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        $stop = @($final.history)[-1]
        $stop.reasonCode | Should -Be 'rollbackFailed'
        $stop.detail | Should -Match 'the rollback stopped before it changed the machine'
        $stop.detail | Should -Match "each is kept: 'vm1-osdisk-asitwas-202610110830', 'vm1-data0-d0-asitwas-202610110830'\."
        $rec = @($final.rollbackDisksDuringRollback | Where-Object { $_.diskName -eq 'vm1-data0-d0-asitwas-202610110830' })
        $rec | Should -HaveCount 1 -Because 'a disk Azure made is on record the moment it exists'
        [int]$rec[0].lun | Should -Be 0
        @(Global:RdfMachineCalls) | Should -HaveCount 0 -Because 'no stop and no swap: the refused disk is never attached'
    }

    It 'where the disk is made: a disk made then refused is kept with its id and name, and is never one to swap in' {
        $script:rp = Global:RdfNewRun
        $global:rdf.badEnc = '-new$'
        $row = [pscustomobject]@{ lun = 0; name = 'vm1-data0'; currentName = 'vm1-data0'; currentId = "$($script:sub)/disks/vm1-data0"; sourceDiskId = "$($script:sub)/disks/vm1-data0"
            diskName = 'vm1-data0-new'; tempName = 'vm1-data0-new'; snapshotId = "$($script:sub)/snapshots/vm1-pristine-d0"; skuName = 'Premium_LRS'
            encryption = [pscustomobject]@{ type = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $script:des } }
        $res = InModuleScope VmMigrationFactory -Parameters @{ c = [pscustomobject]@{ RunPath = $script:rp; VmId = $script:vmId; Rg = 'rg-app' }; r = $row } {
            param($c, $r)
            @{ Data = Invoke-VmfDataDiskRestore -Context $c -RestorePlan @{ Restore = @($r); Kept = @() } -Location 'centralus' -Zone '' -Step 'restore'
               Temp = New-VmfOperatorTempDataDisks -Context $c -Plan @{ Restore = @($r); Kept = @() } -Location 'centralus' -Zone '' }
        }
        @($res.Data.Swaps) | Should -HaveCount 0 -Because 'a disk the read-back refused never goes on the machine'
        $k = @($res.Data.Kept)[0]
        $k.refused | Should -BeTrue
        $k.madeDiskName | Should -Be 'vm1-data0-new'
        $k.madeDiskId | Should -Be "$($script:sub)/disks/vm1-data0-new"
        $res.Temp.Temp.ContainsKey(0) | Should -BeFalse -Because 'a temporary disk the read-back refused never goes on the LUN'
        (@($res.Temp.Kept)[0]).madeDiskName | Should -Be 'vm1-data0-new'
        (@($res.Temp.Kept)[0]).madeDiskId | Should -Be "$($script:sub)/disks/vm1-data0-new"
        InModuleScope VmMigrationFactory -Parameters @{ k = $k } {
            param($k)
            Get-VmfMadeDataDiskNames -Made @('a', 'b') -Kept @($k, [pscustomobject]@{ lun = 1; name = 'x'; refused = $true; why = 'Azure did not make it.' }) | Should -Be @('a', 'b', 'vm1-data0-new')
        }
    }

    # REBUILD-REMOVE-ENGINE-1: the Path B case is gone with its step.
    It 'the disks-only rollback before the move: the same' {
        $script:rp = Global:RdfNewRun -Kind 'disks' -State 'GUEST_PREP'
        $global:rdf.badEnc = 'data0-d0-asitwas'
        $final = InModuleScope VmMigrationFactory -Parameters @{ c = (Global:RdfCtx $script:rp) } { param($c) Complete-VmfRollback -Context $c }
        (@($final.history)[-1]).detail | Should -Match "each is kept: 'vm1-osdisk-asitwas-202610110830', 'vm1-data0-d0-asitwas-202610110830'\."
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Because 'the rollback never stopped the machine'
        @($global:rdf.calls | Where-Object { $_ -like 'os:*' -or $_ -eq 'data' }) | Should -HaveCount 0
    }
}
