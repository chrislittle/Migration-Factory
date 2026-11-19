#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-PERM-CHECK-1: Restore this machine asks for every permission Azure
# checks on a resource the machine uses, BEFORE it stops or changes anything.
#
# A move asks at Checking (NIC-JOIN-SCOPE-1, NIC-JOIN-1, SAFETY-CMK-1,
# ROLLBACK-CRG-1, UAMI-ASSIGN-1). The restore asked none of them: it made the
# disks, stopped the machine and updated it - and Azure checks each update on
# the network interfaces, the user-assigned identity and the capacity
# reservation group it links to (LinkedAuthorizationFailed, measured for the
# identity 2026-11-01), and each disk made from a copy on the copy (ROLE-SNAP-1)
# and on its disk encryption set. A grant removed after the move, or an
# identity added to the machine since, refused the restore after the stop.
#
# The restore uses the SAME checks as Checking (the Test-Vmf*Permissions
# functions, with -For restore for the words), on the machine as it is NOW for
# what each update sends, and on the copies the restore makes its disks from.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    . (Join-Path $PSScriptRoot '_RecordShape.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'rpc'
    # Every disk made from a copy is read back and its key compared.
    Mock -ModuleName VmMigrationFactory Get-VmfManagedDiskFacts { [pscustomobject]@{ id = $DiskId; encryptionType = 'EncryptionAtRestWithPlatformKey'; diskEncryptionSetId = $null } }

    $script:zero = '00000000-0000-0000-0000-000000000000'
    $script:rgId = "/subscriptions/$script:zero/resourceGroups/rg-app"
    $script:vmId = "$script:rgId/providers/Microsoft.Compute/virtualMachines/vm1"
    $script:disks = "$script:rgId/providers/Microsoft.Compute/disks"
    $script:nic1 = "/subscriptions/$script:zero/resourceGroups/rg-net/providers/Microsoft.Network/networkInterfaces/vm1-nic"
    $script:nic2 = "/subscriptions/$script:zero/resourceGroups/rg-net/providers/Microsoft.Network/networkInterfaces/vm1-nic2"
    $script:subnet = "/subscriptions/$script:zero/resourceGroups/rg-net/providers/Microsoft.Network/virtualNetworks/vnet-app/subnets/snet-app"
    $script:mi = "/subscriptions/$script:zero/resourceGroups/rg-ids/providers/Microsoft.ManagedIdentity/userAssignedIdentities/mi-app"
    $script:des = "/subscriptions/$script:zero/resourceGroups/rg-keys/providers/Microsoft.Compute/diskEncryptionSets/des-app"
    $script:crg = "/subscriptions/$script:zero/resourceGroups/rg-cap/providers/Microsoft.Compute/capacityReservationGroups/crg-app"
    $script:copyOs = "$script:rgId/providers/Microsoft.Compute/snapshots/vm1-osdisk-snap"
    $script:copyData = "$script:rgId/providers/Microsoft.Compute/snapshots/vm1-d0-snap"
    $global:RpcVmId = $script:vmId

    # The fake Azure answer for effective permissions: everything, except at a
    # scope the test names in $global:RpcNone (nothing granted), and a read that
    # fails at $global:RpcThrow. Every scope asked is kept in order.
    Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
        $global:RpcAsked.Add([string]$Scope)
        if ($global:RpcThrow -and [string]$Scope -eq $global:RpcThrow) { throw "Could not read effective permissions at '$Scope' (HTTP 403): refused" }
        if (@($global:RpcNone) -contains [string]$Scope) { return @() }
        # RESTORE-PERM-MACHINE-1: a scope the test gives its own entry.
        if ($global:RpcEntry -and $global:RpcEntry.ContainsKey([string]$Scope)) { return @($global:RpcEntry[[string]$Scope]) }
        @([pscustomobject]@{ actions = @('*'); notActions = @(); dataActions = @(); notDataActions = @() })
    }
    # The machine as it is now, read through the boundary.
    Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { if ($global:RpcLiveThrow) { throw 'The machine was not found (HTTP 404).' }; [pscustomobject]@{ Id = $global:RpcVmId } }
    Mock -ModuleName VmMigrationFactory Get-VmfVmCapture { $global:RpcLive }
    Mock -ModuleName VmMigrationFactory Get-VmfNetworkInterfaceById {
        [pscustomobject]@{ id = $NicId; properties = [pscustomobject]@{ ipConfigurations = @([pscustomobject]@{ properties = [pscustomobject]@{ subnet = [pscustomobject]@{ id = $global:RpcSubnet } } }) } }
    }

    function Script:Reset {
        $global:RpcAsked = [System.Collections.Generic.List[string]]::new()
        $global:RpcNone = @()
        $global:RpcThrow = $null
        $global:RpcLiveThrow = $false
        $global:RpcEntry = @{}
        $global:RpcSubnet = $script:subnet
        # The machine now: one interface with accelerated networking on (the
        # move turned it on), and a user-assigned identity.
        $global:RpcLive = [pscustomobject]@{
            name = 'vm1'; size = 'Standard_D2s_v6'
            nics = @([pscustomobject]@{ id = $script:nic1; primary = $true; acceleratedNetworking = $true })
            identity = [pscustomobject]@{ type = 'UserAssigned'; userAssignedIds = @($script:mi) }
        }
    }

    # A run with one machine that moved, its capture in a capacity reservation
    # group of its own, and accelerated networking off before the move.
    function Script:NewRun([string]$Group = $null) {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vmId = $script:vmId; disks = $script:disks; nic = $script:nic1; group = $Group; copy = $script:copyOs } {
            Initialize-VmfRun -RunPath $rp -RunId 'rpc' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'rpc' -VmId $vmId -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{ snapshotId = $copy; pristineSnapshotId = $copy; cloneVmId = $null }) -Force
            $doc.state = 'MIGRATED'
            $null = Add-VmfTestMachineCapture $doc 'vm1' "$disks/vm1-osdisk" 'Standard_D2s_v4'
            $doc.captured.vmConfig.nics = @([pscustomobject]@{ id = $nic; primary = $true; acceleratedNetworking = $false })
            $doc.captured.vmConfig | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $(if ($group) { $group } else { $null }) -Force
            $null = Complete-VmfTestCapture $doc
            Write-VmfStateDoc -RunPath $rp -Document $doc
            $plan = [ordered]@{ schemaVersion = 1; entries = @([ordered]@{
                schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $vmId; wave = 'w1'; ring = 'lab'
                assessment = [ordered]@{ location = 'centralus' }
                target = [ordered]@{ size = 'Standard_D2s_v6' }; path = 'A'; policy = [ordered]@{} }) }
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Document $plan -Depth 24
        }
        $script:rp = $rp
        $rp
    }

    # The gate alone, as Restore-VmfVm asks it.
    function Script:Gate {
        param([string]$From = 'prepared', [string[]]$CopyIds = @(), [object[]]$CopyDisks = @())
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vmId = $script:vmId; from = $From; ids = $CopyIds; cd = $CopyDisks } {
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $vmId
            Get-VmfRestorePermissionStop -Context ([pscustomobject]@{ RunPath = $rp; VmId = $vmId; Rg = 'rg-app'; VmName = 'vm1' }) `
                -From $from -PutBackCapture (Get-VmfPutBackCapture -Doc $doc) -CopyIds @($ids) -CopyDisks @($cd)
        }
    }

    function Script:MockRestoreOps {
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = 'vm1-osdisk'; id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/vm1-osdisk"
                resourceGroup = 'rg-app'; location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 128 }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { 'previous-context' }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        Mock -ModuleName VmMigrationFactory Start-VmfVm { }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { 'Standard_D2s_v6' }
        Mock -ModuleName VmMigrationFactory Get-VmfJobStartPower { 'PowerState/running' }
        Mock -ModuleName VmMigrationFactory Invoke-VmfJobPowerReturn { $null }
        Mock -ModuleName VmMigrationFactory Invoke-VmfVolumesCheckAfterPutBack { @{ verdict = 'OK'; words = '' } }
    }

    function Script:Restore {
        param([string]$From = 'prepared', [switch]$Resume, [string]$Op = 'op-1')
        Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From $From -RestoredBy 'lead@example.com' -CorrelationId $Op -Resume:$Resume -Confirm:$false
    }
    function Script:Doc { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vmId = $script:vmId } { Read-VmfStateDoc -RunPath $rp -VmId $vmId } }
    function Script:Events { InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { @(Read-VmfEvents -RunPath $rp) } }
}

AfterAll {
    Remove-VmfTestTemp
    Remove-Variable RpcAsked, RpcNone, RpcThrow, RpcLive, RpcLiveThrow, RpcSubnet, RpcVmId, RpcEntry -Scope Global -ErrorAction SilentlyContinue
}

Describe 'RESTORE-PERM-CHECK-1: the checks of Checking, asked for a restore' {
    BeforeEach { Script:Reset; Script:NewRun | Out-Null }

    It 'nothing missing: no stop, and every resource the restore links to is asked' {
        Script:Gate -From 'pristine' -CopyIds @($script:copyOs) -CopyDisks @([pscustomobject]@{ encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $script:des }) | Should -BeNullOrEmpty
        foreach ($scope in $script:nic1, $script:subnet, $script:des, $script:mi, $script:copyOs) {
            $global:RpcAsked | Should -Contain $scope
        }
    }

    It 'NIC-JOIN-SCOPE-1: an interface the restore update sends and may not join stops it, named, with the action' {
        $global:RpcNone = @($script:nic1)
        $stop = Script:Gate
        $stop | Should -Match "cannot join the network interface 'vm1-nic' in the resource group 'rg-net'"
        $stop | Should -Match ([regex]::Escape("Microsoft.Network/networkInterfaces/join/action on $script:nic1"))
        $stop | Should -Match 'The restore updates the machine\. Each update includes all network interfaces of the machine\. Azure can check this permission on each network interface: '
        $stop | Should -Match 'The restore stopped before it changed the machine\.'
        $stop | Should -Match 'Grant the VMF Migration role on a scope that covers each network interface'
        $stop | Should -Not -Match 'resize|The run stopped' -Because 'a restore from the second copy does not resize, and it is not a run'
    }

    It 'the interfaces asked are the machine as it is NOW: one added since the move is asked too' {
        $global:RpcLive.nics = @($global:RpcLive.nics) + @([pscustomobject]@{ id = $script:nic2; primary = $false; acceleratedNetworking = $false })
        $global:RpcNone = @($script:nic2)
        Script:Gate | Should -Match "cannot join the network interface 'vm1-nic2'"
    }

    It 'UAMI-ASSIGN-1: an identity added to the machine since the move, which the product may not assign, stops it' {
        # The capture holds no identity; the machine has one now.
        $global:RpcNone = @($script:mi)
        $stop = Script:Gate
        $stop | Should -Match "cannot assign the user-assigned managed identity 'mi-app'"
        $stop | Should -Match ([regex]::Escape("Microsoft.ManagedIdentity/userAssignedIdentities/assign/action on $script:mi"))
        $stop | Should -Match 'The restore updates the machine\. Each update assigns each user-assigned managed identity again\. Azure checks this permission on each user-assigned managed identity: '
        $stop | Should -Match 'The restore stopped before it changed the machine\. Grant the VMF Migration role where the managed identity is'
        $stop | Should -Not -Match 'The run stopped|its rollback'
    }

    It 'UAMI-ASSIGN-1: an identity Azure reports with no id stops it as not known' {
        $global:RpcLive.identity = [pscustomobject]@{ type = 'UserAssigned'; userAssignedIds = @() }
        $stop = Script:Gate
        $stop | Should -Match 'returned no identity id'
        $stop | Should -Match 'The restore updates the machine\. Each update assigns each user-assigned managed identity again\. Nothing'
        $stop | Should -Match 'Nothing on the machine changed\.'
    }

    It 'SAFETY-CMK-1: a disk encryption set of a disk the restore makes, which the product cannot read, stops it' {
        $global:RpcNone = @($script:des)
        $stop = Script:Gate -CopyIds @($script:copyOs) -CopyDisks @([pscustomobject]@{ encryptionType = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $script:des })
        $stop | Should -Match "cannot read the disk encryption set 'des-app'"
        $stop | Should -Match ([regex]::Escape("Microsoft.Compute/diskEncryptionSets/read on $script:des"))
        $stop | Should -Match 'The restore stopped before it changed the machine\. Grant the VMF Migration role where the disk encryption set is'
    }

    It 'ROLE-SNAP-1: a safety copy the restore makes a disk from, which the product cannot read, stops it' {
        $global:RpcNone = @($script:copyData)
        $stop = Script:Gate -CopyIds @($script:copyOs, $script:copyData)
        $stop | Should -Match "cannot read the safety copy 'vm1-d0-snap'\. The restore makes a disk from this safety copy\."
        $stop | Should -Match 'When Azure makes a disk from a safety copy, Azure checks this permission on the safety copy: '
        $stop | Should -Match ([regex]::Escape("Microsoft.Compute/disks/beginGetAccess/action on $script:copyData"))
        $stop | Should -Match 'The restore stopped before it changed the machine\. Grant the VMF Migration role on a scope that includes the safety copy\. Then try again\.'
        $stop | Should -Not -Match 'vm1-osdisk-snap' -Because 'only the copy with the missing permission is named'
    }

    It 'no copy is asked when the restore makes no disk from one' {
        Script:Gate | Should -BeNullOrEmpty
        $global:RpcAsked | Should -Not -Contain $script:copyOs
    }

    It 'ROLLBACK-CRG-1: the capacity reservation group of the machine, where the product may not join, stops it' {
        Script:NewRun -Group $script:crg | Out-Null
        $global:RpcNone = @($script:crg)
        $stop = Script:Gate
        $stop | Should -Match "on the capacity reservation group 'crg-app'"
        $stop | Should -Match 'The restore keeps this machine in the capacity reservation group, or returns it to the group\. Azure checks this permission on the group: '
        $stop | Should -Match 'The restore stopped before it changed the machine\. Grant the VMF Migration role on the capacity reservation group, then try again\.'
        $stop | Should -Not -Match 'The run stopped|The move keeps'
    }

    It 'NIC-JOIN-1: the first copy sets accelerated networking back, so the subnet of that interface is asked, and a missing join stops it' {
        $global:RpcNone = @($script:subnet)
        $stop = Script:Gate -From 'pristine'
        $stop | Should -Match "cannot join the subnet 'snet-app'"
        $stop | Should -Match 'The restore sets accelerated networking on the network interface to its value before the move\. Azure checks this permission on each resource that the network interface links to: '
        $stop | Should -Match 'The restore stopped before it changed the machine\. Grant the VMF Migration role where these resources are'
        $stop | Should -Not -Match 'The move changes'
    }

    It 'NIC-JOIN-1: the second copy does not change an interface, so its subnet is not asked' {
        $global:RpcNone = @($script:subnet)
        Script:Gate -From 'prepared' | Should -BeNullOrEmpty
        $global:RpcAsked | Should -Not -Contain $script:subnet
    }

    It 'NIC-JOIN-1: an interface whose setting is already as recorded is not changed, so its subnet is not asked' {
        $global:RpcLive.nics[0].acceleratedNetworking = $false
        $global:RpcNone = @($script:subnet)
        Script:Gate -From 'pristine' | Should -BeNullOrEmpty
    }

    It 'NIC-JOIN-1: an interface whose setting now is not known is asked: unknown is not as recorded' {
        $global:RpcLive.nics[0].acceleratedNetworking = $null
        $global:RpcNone = @($script:subnet)
        Script:Gate -From 'pristine' | Should -Match "cannot join the subnet 'snet-app'"
    }

    It 'a permission that cannot be read stops it, says so, and names what Azure said: unknown is never allowed' {
        $global:RpcThrow = $script:copyOs
        $stop = Script:Gate -CopyIds @($script:copyOs)
        $stop | Should -Match 'The product could not read the permissions of its managed identity: .*HTTP 403'
        $stop | Should -Match 'The restore stopped before it changed the machine\.'
    }

    It 'an interface join that cannot be read stops it, in the words of the restore' {
        $global:RpcThrow = $script:nic1
        $stop = Script:Gate
        $stop | Should -Match ([regex]::Escape('The restore updates the machine. Each update includes all network interfaces of the machine. Azure can check Microsoft.Network/networkInterfaces/join/action on each network interface. The product could not read whether its managed identity has it: '))
        $stop | Should -Match 'Nothing on the machine changed\.'
    }

    It 'the machine that cannot be read stops it too' {
        $global:RpcLiveThrow = $true
        $stop = Script:Gate
        $stop | Should -Match 'The product could not read the machine: .*HTTP 404.*\. The product cannot check the permissions that the restore needs\.'
        $stop | Should -Match 'HTTP 404'
        $stop | Should -Match 'The restore stopped before it changed the machine\.'
    }

    It 'the move keeps its own words: Checking is unchanged' {
        $global:RpcNone = @($script:nic1)
        $move = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vmId = $script:vmId; nic = $script:nic1 } {
            (Test-VmfNicJoinPermissions -Context @{ RunPath = $rp; VmId = $vmId } -CapturedNics @([pscustomobject]@{ id = $nic })).Detail
        }
        $move | Should -Match 'The resize of the machine, and its rollback, include each network interface'
        $move | Should -Match 'The run stopped before touching the machine\.'
    }
}

Describe 'RESTORE-PERM-CHECK-1: Restore this machine stops untouched on a missing permission' {
    BeforeEach { Script:Reset; Script:NewRun | Out-Null; Script:MockRestoreOps }

    It 'a missing permission refuses the restore before any disk is made, the stop or any update - and says why' {
        $global:RpcNone = @($script:mi)
        { Script:Restore } | Should -Throw "*cannot assign the user-assigned managed identity 'mi-app'*The restore stopped before it changed the machine*"
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Start-VmfVm -Times 0 -Exactly
        $fail = @(Script:Events | Where-Object { $_.outcome -eq 'fail' })
        $fail.Count | Should -Be 1
        $fail[0].detail | Should -Match "mi-app"
        @(Script:Events | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'start' }).Count | Should -Be 0 -Because 'a restore that did not start opens no restore on the page'
    }

    It 'kill-resume: a refused restore writes no checkpoint, so nothing resumes it' {
        $global:RpcNone = @($script:nic1)
        { Script:Restore } | Should -Throw '*cannot join the network interface*'
        $doc = Script:Doc
        $doc.PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
    }

    It 'the restore asks for the copy it makes the OS disk from, and nothing missing lets it run to the end' {
        $r = Script:Restore
        $r.RestoredFromSnapshotId | Should -Be $script:copyOs
        $global:RpcAsked | Should -Contain $script:copyOs
        $global:RpcAsked | Should -Contain $script:nic1
        $global:RpcAsked | Should -Contain $script:mi
        Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 1 -Exactly
    }

    It 'kill-resume: a resume of the restore does not ask again - it finishes what it started' {
        # The first job passed the check, made its disks, and died at the stop.
        # A real kill runs no finally, so the job is not marked ended.
        Mock -ModuleName VmMigrationFactory Close-VmfPutBackJob { }
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { throw 'VMF-TEST-KILLED: the process is gone' }
        { Script:Restore } | Should -Throw '*VMF-TEST-KILLED*'
        $askedFirst = $global:RpcAsked.Count
        $askedFirst | Should -BeGreaterThan 0 -Because 'the first job asked'
        $job = (Script:Doc).putBackJob
        $job | Should -Not -BeNullOrEmpty
        [string]$job.phase | Should -Be 'made'
        # The new container. A grant removed meanwhile is not asked about:
        # the machine is part way, and the resume finishes it.
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { }
        $global:RpcNone = @($script:mi, $script:nic1, $script:copyOs)
        $r = Script:Restore -Resume
        $r.RestoredFromSnapshotId | Should -Be $script:copyOs
        $global:RpcAsked.Count | Should -Be $askedFirst -Because 'the resume asks no permission again'
        Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 1 -Exactly -Because 'the resume makes no second disk'
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 1 -Exactly
        (Script:Doc).restore | Should -Not -BeNullOrEmpty
    }

    Context 'what the restore asks about: the copies and the keys of the disks it makes' {
        BeforeEach {
            $global:RpcGate = $null
            Mock -ModuleName VmMigrationFactory Get-VmfRestorePermissionStop {
                $global:RpcGate = @{ From = $From; Ids = @($CopyIds); Disks = @($CopyDisks); Size = [string]$PutBackCapture.size }
                'STOP-FOR-TEST'
            }
            Mock -ModuleName VmMigrationFactory Get-VmfPutBackRetirementCheck { $null }
            Mock -ModuleName VmMigrationFactory Get-VmfPreviewPutBackCheck { $null }
            Mock -ModuleName VmMigrationFactory Get-VmfDiskShareCount { 1 }
            # One data disk the restore puts back, from its own copy, on a
            # customer-managed key.
            Mock -ModuleName VmMigrationFactory Get-VmfOperatorDataRestorePlan {
                @{ Restore = @([pscustomobject]@{ lun = 0; name = 'vm1-d0'; snapshotId = $global:RpcCopyData; currentId = 'd0-id'; currentName = 'vm1-d0'; currentResourceGroup = 'rg-app'
                            diskName = 'vm1-d0-restored'; tempName = 'vm1-d0-rtmp'; encryption = [pscustomobject]@{ type = 'EncryptionAtRestWithCustomerKey'; diskEncryptionSetId = $global:RpcDes } })
                   Kept = @() }
            }
            $global:RpcCopyData = $script:copyData
            $global:RpcDes = $script:des
        }
        AfterEach { Remove-Variable RpcGate, RpcCopyData, RpcDes -Scope Global -ErrorAction SilentlyContinue }

        It 'new disks from the copies: each copy and the key of each disk, OS disk and data disk' {
            { Script:Restore } | Should -Throw '*STOP-FOR-TEST*'
            $global:RpcGate.From | Should -Be 'prepared'
            $global:RpcGate.Ids | Should -Be @($script:copyOs, $script:copyData)
            @($global:RpcGate.Disks | ForEach-Object { [string]$_.diskEncryptionSetId }) | Should -Contain $script:des
            @($global:RpcGate.Disks).Count | Should -Be 2 -Because 'the OS disk entry of the capture, and the data disk'
            Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
        }

        It 'the first copy with the disks made before the move, new names: no disk is made from a copy, so no copy is asked' {
            Mock -ModuleName VmMigrationFactory Get-VmfRollbackDisksBeforeMoveSet {
                @{ Set = @{ OsName = 'vm1-os-asitwas'; OsId = "$($global:RpcVmId)-os-asitwas"; Ids = @(); Data = @{ Swaps = @(); Kept = @() } }; Why = '' }
            }
            { Script:Restore -From 'pristine' } | Should -Throw '*STOP-FOR-TEST*'
            $global:RpcGate.From | Should -Be 'pristine'
            $global:RpcGate.Size | Should -Be 'Standard_D2s_v4' -Because 'the put-back capture is what the first copy puts back'
            @($global:RpcGate.Ids).Count | Should -Be 0
            @($global:RpcGate.Disks).Count | Should -Be 0
        }

        It 'the first copy with the disks made before the move, keeping the names: the disks under the old names are made from the copies, so they are asked' {
            Mock -ModuleName VmMigrationFactory Get-VmfRollbackDisksBeforeMoveSet {
                @{ Set = @{ OsName = 'vm1-os-asitwas'; OsId = "$($global:RpcVmId)-os-asitwas"; Ids = @(); Data = @{ Swaps = @([pscustomobject]@{ lun = 0; diskName = 'vm1-d0-asitwas'; diskId = 'd0-asitwas' }); Kept = @() } }; Why = '' }
            }
            { Restore-VmfVm -RunPath $script:rp -VmId $script:vmId -From 'pristine' -DiskNaming 'preserve' -AcceptPreserveRisk -RestoredBy 'lead@example.com' -CorrelationId 'op-1' -Confirm:$false 3>$null } | Should -Throw '*STOP-FOR-TEST*'
            $global:RpcGate.Ids | Should -Be @($script:copyOs, $script:copyData)
        }
    }

    It 'the gate is asked after the machine lease and before the checkpoint, in the code' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Restore-VmfVm.ps1')
        $gate = $code.IndexOf('Get-VmfRestorePermissionStop')
        $gate | Should -BeGreaterThan $code.IndexOf('Enter-VmfMachineLease')
        $gate | Should -BeLessThan $code.IndexOf('New-VmfPutBackJob')
        $gate | Should -BeLessThan $code.IndexOf("'restore:stop'")
        $gate | Should -BeLessThan $code.IndexOf("'restore:createDisk'")
    }
}

Describe 'RESTORE-PERM-MACHINE-1: the restore asks for its own actions at the machine, the PERM-3 way' {
    BeforeEach { Script:Reset; Script:NewRun | Out-Null }

    It 'the actions of a restore come from the map, and hold none that only a move or a scan needs' {
        $restore = @(InModuleScope VmMigrationFactory { Get-VmfRequiredActions -Restore })
        foreach ($a in 'Microsoft.Compute/virtualMachines/read', 'Microsoft.Compute/virtualMachines/write',
            'Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/virtualMachines/start/action',
            'Microsoft.Compute/disks/read', 'Microsoft.Compute/disks/write', 'Microsoft.Compute/disks/delete',
            'Microsoft.Network/networkInterfaces/read', 'Microsoft.Network/networkInterfaces/write') {
            $restore | Should -Contain $a
        }
        foreach ($a in 'Microsoft.Features/providers/features/read', 'Microsoft.Compute/snapshots/write',
            'Microsoft.Quota/quotas/write', 'Microsoft.Authorization/locks/write', 'Microsoft.Compute/skus/read',
            'Microsoft.Compute/capacityReservationGroups/write', 'Microsoft.Compute/virtualMachines/runCommand/action') {
            $restore | Should -Not -Contain $a -Because "only a move or a scan uses $a"
        }
        # Each one is an action of the execute or assess role in the map.
        $all = @(InModuleScope VmMigrationFactory { Get-VmfRequiredActions })
        foreach ($a in $restore) { $all | Should -Contain $a }
    }

    It 'the machine itself is asked, and first - as Checking asks PERM-3 first' {
        Script:Gate | Should -BeNullOrEmpty
        $global:RpcAsked[0] | Should -Be $script:vmId
    }

    It 'virtualMachines/write removed at the machine stops the restore, named, with the words of PERM-3 for a restore' {
        $global:RpcEntry = @{ $script:vmId = [pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Compute/virtualMachines/write'); dataActions = @(); notDataActions = @() } }
        $stop = Script:Gate
        $stop | Should -Be ("The product's managed identity does not have 1 permission on the machine 'vm1' ($($script:vmId)): Microsoft.Compute/virtualMachines/write. " +
            'The restore needs this permission. The restore stopped before it changed the machine. ' +
            'Grant the VMF Migration role on this machine, its resource group or its subscription. Then try again.')
        $global:RpcAsked | Should -Not -Contain $script:nic1 -Because 'the first stop is said, as at Checking'
    }

    It 'two actions missing: each is named, in the plural' {
        $global:RpcEntry = @{ $script:vmId = [pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Compute/virtualMachines/deallocate/action', 'Microsoft.Compute/disks/write'); dataActions = @(); notDataActions = @() } }
        $stop = Script:Gate
        $stop | Should -Match ([regex]::Escape('does not have 2 permissions on the machine'))
        $stop | Should -Match ([regex]::Escape('Microsoft.Compute/disks/write, Microsoft.Compute/virtualMachines/deallocate/action. The restore needs these permissions.'))
    }

    It 'an action only a move needs is not asked of a restore: the preview feature read, the safety copy write, the quota' {
        $global:RpcEntry = @{ $script:vmId = [pscustomobject]@{ actions = @('*')
                notActions = @('Microsoft.Features/providers/features/read', 'Microsoft.Compute/snapshots/write', 'Microsoft.Quota/*', 'Microsoft.Authorization/locks/*', 'Microsoft.Compute/virtualMachines/runCommand/action')
                dataActions = @(); notDataActions = @() } }
        Script:Gate | Should -BeNullOrEmpty
    }

    It 'a machine permission that cannot be read stops the restore: unknown is never allowed' {
        $global:RpcThrow = $script:vmId
        $stop = Script:Gate
        $stop | Should -Match 'The product could not read the permissions of its managed identity: .*HTTP 403'
        $stop | Should -Match 'The restore stopped before it changed the machine\.'
    }

    It 'Checking keeps its own words' {
        $move = InModuleScope VmMigrationFactory -Parameters @{ vmId = $script:vmId } { Format-VmfMissingActionsMessage -Missing @('Microsoft.Compute/virtualMachines/write') -Scope $vmId }
        $move | Should -Match 'The move and its rollback need them\.'
        $move | Should -Match 'So the run stopped before it changed the machine\.'
    }

    Context 'Restore this machine' {
        BeforeEach { Script:MockRestoreOps }

        It 'a missing machine action refuses the restore before any disk is made or the stop' {
            $global:RpcEntry = @{ $script:vmId = [pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Compute/virtualMachines/write'); dataActions = @(); notDataActions = @() } }
            { Script:Restore } | Should -Throw "*does not have 1 permission on the machine 'vm1'*The restore stopped before it changed the machine*"
            Should -Invoke -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Stop-VmfVmDeallocated -Times 0 -Exactly
            Should -Invoke -ModuleName VmMigrationFactory Set-VmfVmOsDisk -Times 0 -Exactly
            (Script:Doc).PSObject.Properties['putBackJob'] | Should -BeNullOrEmpty
            @(Script:Events | Where-Object { $_.outcome -eq 'fail' -and $_.detail -match 'virtualMachines/write' }).Count | Should -Be 1
        }
    }
}
