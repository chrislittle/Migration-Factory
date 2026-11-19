#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-1: claiming the safety copy. Until now the snapshot taken at
# SAFETY_COPY was insurance nobody could claim - its id was recorded and no
# code ever read it. These tests pin the restore's behaviour, and above all
# the DISK IDENTITY question: a disk built from a snapshot is a NEW disk,
# which is drift in customer Terraform state and breaks anything bound to the
# old id (backup instances, locks, disk-scoped roles).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # RESTORE-PERM-CHECK-1: the permission check of Restore this machine is not under test here (RestorePermCheck.Tests.ps1).
    Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop { $null }
    # OLD-VERSION-READERS-REMOVE-4: every disk made from a copy is read back and its key compared, so the fake Azure answers the read.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:SUB = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines'
    $script:DISKS = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks'

    function Script:NewRestoreRun {
        param([switch]$NoSnapshot, [switch]$IacManaged)
        $rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-rst-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $vmId = "$script:SUB/app01"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $vmId; noSnap = [bool]$NoSnapshot; iac = [bool]$IacManaged } {
            Initialize-VmfRun -RunPath $rp -RunId 'rst-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rst-test' -VmId $vmId -Wave 'lab-1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
            $snapId = if ($noSnap) { $null } else { '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/snapshots/app01-snap' }
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $snapId; cloneVmId = $null }) -Force
            # RESTORE-MID-MOVE-1: a restore is offered only after the move ended.
            $doc.state = 'MIGRATED'
            # OLD-VERSION-READERS-REMOVE-4: a machine with a safety copy passed
            # PRECHECK, which captured it.
            $doc | Add-Member -NotePropertyName captured -Force -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]@{
                vmId = $vmId; name = 'app01'; location = 'centralus'; size = 'Standard_D2s_v6'; controller = 'SCSI'
                osDisk = [pscustomobject]@{ name = 'app01-osdisk'; managedDiskId = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'; skuName = 'Premium_LRS' }
                dataDisks = @(); nics = @() } })
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'lab-1'; ring = 'lab'
                assessment = [ordered]@{ iacManaged = $iac; location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $rp
    }

    function Script:MockAzureOps {
        # The disk world, as ARM would answer it.
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-lab'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot {
            "/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/disks/$DiskName"
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        # SEC-1 / F10: pinning the machine's own subscription is an Azure
        # call like any other, and no test may reach Azure.
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        # TEST-1 caught these tests calling REAL Azure for the size the machine
        # landed on - and passing anyway, which is the whole reason the guard
        # exists. The test says what the answer is.
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
    }
}

Describe 'Restore-VmfVm - the safety copy, finally claimable' {
    AfterEach { if ($script:run -and (Test-Path $script:run)) { Remove-Item $script:run -Recurse -Force } }

    It 'refuses plainly when no safety copy was ever taken' {
        $script:run = Script:NewRestoreRun -NoSnapshot
        Script:MockAzureOps
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false } |
            Should -Throw '*no safety copy*'
    }

    It 'builds a disk from the snapshot, swaps it in, and brings the machine back up' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        $r = Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false
        $r.RestoredFromSnapshotId | Should -Match 'app01-snap'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 1
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 1
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1
        Should -Invoke -ModuleName VmMigrationFactory Wait-VmfVmAgentReady -Times 1
    }

    It 'default naming keeps the ORIGINAL disk and reports that the id changed' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        $r = Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false
        $r.DiskNaming | Should -Be 'new'
        $r.NewDiskName | Should -Not -Be 'app01-osdisk'
        $r.DiskIdChanged | Should -BeTrue
        $r.RetainedDiskId | Should -Match 'app01-osdisk' -Because 'the pre-restore disk is kept, so the restore itself is reversible'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDisk -Times 0 -Because 'nothing is deleted under the default policy'
    }

    It 'preserve naming ends on the ORIGINAL disk name, deleting the old disk to free it' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        $r = Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false
        $r.NewDiskName | Should -Be 'app01-osdisk'
        $r.DiskIdChanged | Should -BeFalse -Because 'same name and same resource id means no Terraform drift'
        # a managed disk cannot be renamed, so the name is freed via a temporary disk
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 2
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDisk -Times 2
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 2
    }

    It 'ID-ADDRESS-1: a disk in another resource group is checked, deleted and made again THERE, and nothing of that name beside the machine is touched' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }   # RESTORE-ALL-1: no data disks unless a test says so
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-disks/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-disks'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128; controller = 'NVMe' }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-disks' -and $DiskName -eq 'app01-osdisk' }
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDisk -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-disks' -and $DiskName -eq 'app01-osdisk' }
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-disks' -and $DiskName -eq 'app01-osdisk' }
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes -Times 1 -Exactly -ParameterFilter { $DiskResourceGroup -eq 'rg-disks' -and $DiskName -eq 'app01-osdisk' }
        # The temporary disk sits beside the machine, and only it goes there.
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 1 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-lab' -and $DiskName -like 'app01-osdisk-rtmp-*' }
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDisk -Times 0 -Exactly -ParameterFilter { $ResourceGroupName -eq 'rg-lab' -and $DiskName -eq 'app01-osdisk' }
    }

    It 'NEVER infers the destructive option - even a machine tagged as IaC-managed defaults to new' {
        # The IaC fact is a tag heuristic the tool never asks anyone to
        # confirm; far too weak a signal to pick a destructive path on
        # someone's behalf (owner-corrected).
        $script:run = Script:NewRestoreRun -IacManaged
        Script:MockAzureOps
        $r = Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false
        $r.DiskNaming | Should -Be 'new'
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDisk -Times 0
    }

    It 'refuses the destructive option unless the caller says so out loud' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -Confirm:$false } |
            Should -Throw '*The delete was not accepted, so the restore did not start.*'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Because 'it refuses before touching the machine'
    }

    It 'catches a delete-blocking lock BEFORE the machine is moved anywhere' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @('keep-prod (CanNotDelete)') }
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false } |
            Should -Throw '*lock*'
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 `
            -Because 'discovering the lock mid-restore would strand the machine on a temporary disk'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0
    }

    # CANNOTDELETE-RESTORE-1: keeping the names, the restore also deletes its
    # temporary disk, beside the machine. A lock on the resource group of the
    # machine refused that delete with the machine stopped, when the OS disk is
    # in another resource group and its own lock check found nothing.
    It 'CANNOTDELETE-RESTORE-1: keeping the names, a lock that refuses the delete of the temporary disk refuses before anything changes' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'app01-osdisk'; id = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-disks/providers/Microsoft.Compute/disks/app01-osdisk'
                               resourceGroup = 'rg-disks'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { if ($ResourceGroupName -eq 'rg-lab') { , @('keep-prod (CanNotDelete)') } else { , @() } }
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false } |
            Should -Throw "Restore cannot keep the original disk names. A resource lock (keep-prod (CanNotDelete)) on the resource group 'rg-lab' prevents the delete of the temporary disk 'app01-osdisk-rtmp-*'. Remove the lock, or restore again and select Yes for Keep its current managed disks."
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks -ParameterFilter { $ResourceGroupName -eq 'rg-lab' -and $DiskName -like 'app01-osdisk-rtmp-*' }
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfManagedDisk -Times 0
        $events = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp })
        @($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'start' }) | Should -HaveCount 0 -Because 'no restore starts on the page'
    }

    It 'CANNOTDELETE-RESTORE-1: the default naming deletes no disk, so a lock does not stop it and no lock is read' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @('keep-prod (CanNotDelete)') }
        Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks -Times 0
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1
    }

    It 'CANNOTDELETE-RESTORE-1: keeping the names, Azure refuses the delete of the temporary disk after the swap - the restore goes on and the run history names the disk' {
        # The OS disk is on the machine under its own name by then. A stop
        # here restarted the machine on the restored OS disk with the data
        # disks of another moment, and said the restore did not complete.
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { if ($DiskName -like '*-rtmp-*') { throw 'ScopeLocked: the scope is locked.' } }
        $r = Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null
        $r.NewDiskName | Should -Be 'app01-osdisk'
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1 -Exactly
        $events = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp })
        $warn = @($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'warn' -and [string]$_.detail -like "*The temporary disk 'app01-osdisk-rtmp-*' is not attached and was not deleted: ScopeLocked*" })
        $warn | Should -HaveCount 1
        @($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'ok' }) | Should -HaveCount 1
    }

    It 'CANNOTDELETE-RESTORE-1: a lost hold of the machine while the temporary disk is deleted still stops the restore' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { if ($DiskName -like '*-rtmp-*') { throw 'Lease lost: abandon this VM.' } }
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -DiskNaming preserve -AcceptPreserveRisk -Confirm:$false 3>$null } |
            Should -Throw '*abandon this VM*'
    }

    It 'records the whole restore in the machine record and the run history' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -RestoredBy 'lead@example.com' -Note 'boot failure' -Confirm:$false | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run; id = "$script:SUB/app01" } {
            Read-VmfStateDoc -RunPath $rp -VmId $id
        }
        $doc.restore.restoredBy | Should -Be 'lead@example.com'
        $doc.restore.previousDiskId | Should -Match 'app01-osdisk'
        $doc.restore.newDiskId | Should -Not -BeNullOrEmpty
        $doc.restore.diskIdChanged | Should -BeTrue
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        ($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'ok' }) | Should -Not -BeNullOrEmpty
        ($events | Where-Object { $_.detail -match 'boot failure' }) | Should -Not -BeNullOrEmpty
    }

    It 'restores DISK CONTENT only - it never silently changes the machine size' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController { }
        Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmSizeAndController -Times 0 `
            -Because 'reverting the size is the rollback path, and conflating the two would surprise an operator'
    }

    It 'keeps generated disk names inside the limit Azure actually enforces (drill finding)' {
        # Found live: restoring an already-restored disk stacked suffixes past
        # 80 characters and Azure rejected the request with a bare
        # "disk.name is invalid".
        InModuleScope VmMigrationFactory {
            $long = 'vmf-rst-lin_disk1_0d8de30da0ba4e8c9034b82a83dbed2f-restored-202608261235'
            $name = Get-VmfBoundedDiskName -BaseName $long -Suffix '-rtmp-202608261236'
            $name.Length | Should -BeLessOrEqual 80
            $name | Should -BeLike '*-rtmp-202608261236' -Because 'the suffix survives; the base is what gets trimmed'
            $name | Should -Not -BeLike '*--*' -Because 'a trimmed base must not leave a doubled separator'
            # short names are left alone
            Get-VmfBoundedDiskName -BaseName 'app01-osdisk' -Suffix '-restored-1' | Should -Be 'app01-osdisk-restored-1'
        }
    }

    It 'a failed restore NEVER leaves the machine powered off (drill finding)' {
        # Found live: a restore that failed after the stop left the machine
        # deallocated. A disaster-recovery tool that abandons a machine down
        # has made the outage worse.
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        # ROLLBACK-DISKS-FIRST-1 (rewritten on purpose): a disk Azure will not
        # make now stops the restore BEFORE the stop (RollbackDisksFirst.Tests),
        # so the failure after the stop is the swap.
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'OperationNotAllowed: the swap was refused' }
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false } |
            Should -Throw '*has been restarted*'
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 1 `
            -Because 'the machine must come back up even when the restore fails'
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        ($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'warn' }) | Should -Not -BeNullOrEmpty
    }

    It 'says the machine is stopped when Azure does not start it again' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        # ROLLBACK-DISKS-FIRST-1: the swap, as above - a failure after the stop.
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { throw 'OperationNotAllowed: the swap was refused' }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { throw 'allocation failed' }
        { Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false } |
            Should -Throw '*Azure did not start the machine. The machine is stopped.*'
    }

    It 'RESTORE-END-LOST-1: the start line carries the engine operation''s id, so the engine''s fail line ends THIS restore and no other' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -CorrelationId 'op-7' -Confirm:$false | Out-Null
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        $start = @($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'start' })
        $start.Count | Should -Be 1
        $start[0].correlationId | Should -Be 'op-7'
    }

    It 'RESTORE-END-LOST-1: and a restore run outside the engine writes none' {
        $script:run = Script:NewRestoreRun
        Script:MockAzureOps
        Restore-VmfVm -RunPath $script:run -VmId "$script:SUB/app01" -Confirm:$false | Out-Null
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:run } { Read-VmfEvents -RunPath $rp }
        $start = @($events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'start' })
        $start[0].PSObject.Properties['correlationId'] | Should -BeNullOrEmpty
    }
    It 'is destructive enough to require confirmation' {
        $cmd = Get-Command Restore-VmfVm
        $cmd.Parameters.ContainsKey('WhatIf') | Should -BeTrue
        $meta = [System.Management.Automation.CommandMetadata]::new($cmd)
        $meta.SupportsShouldProcess | Should -BeTrue
        $meta.ConfirmImpact | Should -Be 'High'
    }
}
