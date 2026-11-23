#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ROLLBACK-CRG-1: a rollback took a machine out of its own capacity reservation
# group.
#
# Found 2026-10-05 by reading the code (MANA-LINUX-KERNEL-1). The Path A
# rollback left WHATEVER group the machine was in, because the product's own
# group holds only the target size and Azure refuses to start a machine whose
# size has no reservation in its group (the SAFETY-2 drill). But nothing
# recorded the group the machine had before the move, so a machine that the
# customer had put in its OWN group came back without it, and nothing said so.
# Its later starts had no capacity guarantee. Path B rebuilt from a capture
# that had no group either.
#
# THE RULE: PRECHECK records the group (vm-state v24). Every put-back - the
# rollback, Restore this machine, Rebuild this machine - leaves a group that
# the machine was not in before the move, and puts it back in the group it
# was in, after the size is back. Azure can refuse that (the group holds no
# reservation for the size): the put-back says so in its own words and goes
# on. Every capture says its group (OLD-VERSION-READERS-REMOVE-4, vm-state
# v47): a record that does not say is not one this version writes, so the
# put-back stops before anything changes - never "in no group".
#
# The fake below holds Azure's rules as the drills measured them: a machine
# joins a group only when the group has a reservation for its size (REH-1),
# and a machine starts only when its group has a reservation for its size
# (SAFETY-2).
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
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'crg'

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000'
    $script:vmId = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/vm1"
    # The product's group, made for the wave: the target size only.
    $script:ours = "$script:sub/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/vmf-crg-w1"
    # The customer's own group: the size the machine had before the move.
    $script:theirs = "$script:sub/resourceGroups/rg-capacity/providers/Microsoft.Compute/capacityReservationGroups/contoso-crg"
    # Another group the product did not make.
    $script:other = "$script:sub/resourceGroups/rg-capacity/providers/Microsoft.Compute/capacityReservationGroups/contoso-other"

    function Global:CrgReset {
        $global:crg = @{
            size = 'Standard_D2ds_v6'; controller = 'NVMe'; group = $script:ours
            # group id -> the sizes it holds a reservation for
            holds = @{ $script:ours = @('Standard_D2ds_v6'); $script:theirs = @('Standard_D2ds_v4'); $script:other = @('Standard_D2ds_v4') }
            disks = @{ 'vm1-osdisk' = 'SCSI, NVMe' }
            attached = 'vm1-osdisk'
            exists = $true
            leftFailed = $false
            killStartOnce = $false
            calls = [System.Collections.Generic.List[string]]::new()
        }
    }
    function Global:CrgShort([string]$Id) { if ($Id) { ($Id -split '/')[-1] } else { 'none' } }

    function Global:CrgMockAzure {
        Mock -ModuleName VmMigrationFactory Stop-VmfVmDeallocated { $global:crg.calls.Add('stop') }
        Mock -ModuleName VmMigrationFactory Start-VmfVm {
            if ($global:crg.killStartOnce) { $global:crg.killStartOnce = $false; $global:crg.calls.Add('killed'); throw 'The lease was lost - abandon this VM.' }
            $g = $global:crg.group
            if ($g -and $global:crg.size -notin @($global:crg.holds[$g])) {
                throw "Capacity Reservation with VM size $($global:crg.size) does not exist in the Capacity Reservation Group '$(Global:CrgShort $g)'."
            }
            $global:crg.calls.Add('start')
        }
        Mock -ModuleName VmMigrationFactory Wait-VmfVmAgentReady { }
        Mock -ModuleName VmMigrationFactory Get-VmfVmSize { $global:crg.size }
        Mock -ModuleName VmMigrationFactory Get-VmfVmCapacityReservationGroupId { $global:crg.group }
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup {
            if ($GroupId) {
                # REH-1: Azure checks the machine's CURRENT size against the group.
                if ($global:crg.size -notin @($global:crg.holds[$GroupId])) {
                    throw "Capacity Reservation with VM size $($global:crg.size) does not exist in the Capacity Reservation Group '$(Global:CrgShort $GroupId)'."
                }
                $global:crg.group = $GroupId
                $global:crg.calls.Add("join:$(Global:CrgShort $GroupId)")
            }
            else { $global:crg.group = $null; $global:crg.calls.Add('leave') }
        }
        Mock -ModuleName VmMigrationFactory Get-VmfDeleteBlockingLocks { , @() }
        Mock -ModuleName VmMigrationFactory Remove-VmfManagedDisk { $global:crg.calls.Add("delete:$DiskName") }
        Mock -ModuleName VmMigrationFactory Use-VmfSubscriptionContext { $null }
        Mock -ModuleName VmMigrationFactory Restore-VmfSubscriptionContext { }
        Mock -ModuleName VmMigrationFactory Get-VmfDataDiskInfo { @() }
        Mock -ModuleName VmMigrationFactory Get-VmfOsDiskInfo {
            [pscustomobject]@{ name = $global:crg.attached; id = "/disks/$($global:crg.attached)"; resourceGroup = 'rg-lab'
                location = 'centralus'; skuName = 'Premium_LRS'; sizeGB = 30; controller = $global:crg.controller }
        }
        Mock -ModuleName VmMigrationFactory New-VmfDiskFromSnapshot { $global:crg.disks[$DiskName] = 'SCSI'; $global:crg.calls.Add("create:$DiskName"); "/disks/$DiskName" }
        Mock -ModuleName VmMigrationFactory Set-VmfOsDiskControllerTypes { $global:crg.disks[$DiskName] = $ControllerTypes }
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            $global:crg.size = $Size; $global:crg.controller = $Controller
            $global:crg.calls.Add("size:$Size")
        }
        Mock -ModuleName VmMigrationFactory Set-VmfVmOsDisk { $global:crg.attached = $DiskName; $global:crg.calls.Add("swap:$DiskName") }
        Mock -ModuleName VmMigrationFactory Get-VmfSkuCatalog { @() }
        # Path B
        Mock -ModuleName VmMigrationFactory Get-VmfVmConfig { if ($global:crg.exists) { [pscustomobject]@{ Name = 'vm1' } } else { $null } }
    }

    # The run: a machine moved from D2ds_v4 to D2ds_v6. -Group is what the
    # capture recorded: a group id, 'none', or 'unknown' (a record from before
    # v24, which has no field). -Claim writes this wave's quota record, whose
    # reservation is the product's group.
    function Global:CrgNewRun {
        param([string]$Group = 'none', [switch]$Claim, [string]$State = '')
        $rp = Join-Path $script:temp "run-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId; g = $Group; claim = [bool]$Claim; ours = $script:ours; st = $State } {
            param($rp, $id, $g, $claim, $ours, $st)
            Initialize-VmfRun -RunPath $rp -RunId 'crg' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'crg' -VmId $id -Wave 'w1' | Out-Null
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $vmConfig = [ordered]@{ size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; name = 'vm1'; osType = 'Linux'
                osDisk = [ordered]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = '/disks/vm1-osdisk' }; dataDisks = @(); nics = @() }
            if ($g -ne 'unknown') { $vmConfig.capacityReservationGroupId = $(if ($g -eq 'none') { $null } else { $g }) }
            $doc | Add-Member -NotePropertyName captured -NotePropertyValue ([pscustomobject]@{ vmConfig = [pscustomobject]$vmConfig }) -Force
            $doc | Add-Member -NotePropertyName safety -NotePropertyValue ([pscustomobject]@{
                    snapshotId = '/snapshots/vm1-prepared'; pristineSnapshotId = '/snapshots/vm1-pristine' }) -Force
            # RESTORE-MID-MOVE-1: a restore is offered only after the move ended.
            if ($st) { $doc.state = $st }
            $null = Complete-VmfTestCapture $doc
            # 'unknown': a record that does not say its group - not one this
            # version writes (OLD-VERSION-READERS-REMOVE-4).
            if ($g -eq 'unknown') { foreach ($c in @($doc.captured.vmConfig, $doc.captured.original.vmConfig)) { $c.PSObject.Properties.Remove('capacityReservationGroupId') } }
            Write-VmfStateDoc -RunPath $rp -Document $doc
            if ($claim) {
                Write-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2dsv6.json' -Document ([pscustomobject]@{
                        state = 'RESERVED'; size = 'Standard_D2ds_v6'; region = 'centralus'; wave = 'w1'
                        reservationAsked = [pscustomobject]@{ groupId = $ours; reservationId = "$ours/capacityReservations/d2dsv6" }
                        reservation = [pscustomobject]@{ groupId = $ours; reservationId = "$ours/capacityReservations/d2dsv6"; consumedInstances = 1 }
                        associatedVmIds = @($id) })
            }
        }
        $rp
    }
    # A retry: the first capture of the machine (captured.original.vmConfig)
    # says -First - a group id, 'none', or 'unknown' (no field) - while this
    # attempt's capture keeps what Global:CrgNewRun wrote.
    function Global:CrgSetFirst([string]$Rp, [string]$First = 'none') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId; g = $First } {
            param($rp, $id, $g)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $first = [ordered]@{ size = 'Standard_D2ds_v4'; controller = 'SCSI'; location = 'centralus'; name = 'vm1'; osType = 'Linux'
                osDisk = [ordered]@{ name = 'vm1-osdisk'; skuName = 'Premium_LRS'; managedDiskId = '/disks/vm1-osdisk' }; dataDisks = @(); nics = @() }
            if ($g -ne 'unknown') { $first.capacityReservationGroupId = $(if ($g -eq 'none') { $null } else { $g }) }
            $doc.captured | Add-Member -NotePropertyName original -NotePropertyValue ([pscustomobject]@{
                    vmConfig = [pscustomobject]$first; extensions = @(); capturedUtc = '2026-11-01T00:00:00.0000000Z' }) -Force
            $null = Complete-VmfTestCapture $doc
            # Complete-VmfTestCapture fills a missing group with none; 'unknown' has no field.
            if ($g -eq 'unknown') { $doc.captured.original.vmConfig.PSObject.Properties.Remove('capacityReservationGroupId') }
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    # An earlier rollback recorded that Azure did not put the machine back in -Group.
    function Global:CrgOwe([string]$Rp, [string]$Group) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId; g = $Group } {
            param($rp, $id, $g)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            $doc | Add-Member -NotePropertyName rollback -Force -NotePropertyValue ([pscustomobject]@{
                    rolledBackUtc = '2026-11-02T00:00:00.0000000Z'; path = 'A'; osDisk = $null; dataDisks = @(); keptDataDisks = @()
                    reservationGroupNotBack = [pscustomobject]@{ groupId = $g; why = 'Capacity Reservation with VM size Standard_D2ds_v4 does not exist.' } })
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    # A person's retry after a finished rollback: this attempt's capture says
    # -Group ('none' or an id), and the rollback checkpoint of the last one is gone.
    function Global:CrgNextAttempt([string]$Rp, [string]$Group = 'none') {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId; g = $Group } {
            param($rp, $id, $g)
            $doc = Read-VmfStateDoc -RunPath $rp -VmId $id
            if ($doc.PSObject.Properties['rollbackPending']) { $doc.PSObject.Properties.Remove('rollbackPending') }
            $doc.captured.vmConfig | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $(if ($g -eq 'none') { $null } else { $g }) -Force
            Write-VmfStateDoc -RunPath $rp -Document $doc
        }
    }
    function Global:CrgPlan([string]$Path = 'A') {
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vmId; path = $Path; wave = 'w1'
            target = [pscustomobject]@{ size = 'Standard_D2ds_v6'; controller = 'NVMe' } }
    }
    function Global:CrgRollback([string]$Rp, [string]$Path = 'A', [switch]$GuestOnly) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; p = (Global:CrgPlan $Path); g = [bool]$GuestOnly } {
            param($rp, $p, $g)
            Invoke-VmfRollback -Context (New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crg') -GuestOnly:$g
        }
    }
    function Global:CrgDoc([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId } { param($rp, $id) Read-VmfStateDoc -RunPath $rp -VmId $id }
    }
    function Global:CrgLines([string]$Rp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp } { param($rp) @(Read-VmfEvents -RunPath $rp) }
    }
    function Global:CrgAt([string]$Prefix) {
        $calls = @($global:crg.calls)
        [array]::IndexOf($calls, ($calls | Where-Object { $_ -like "$Prefix*" } | Select-Object -First 1))
    }
}
AfterAll {
    Remove-Item 'function:\CrgReset', 'function:\CrgShort', 'function:\CrgMockAzure', 'function:\CrgNewRun', 'function:\CrgSetFirst', 'function:\CrgOwe', 'function:\CrgNextAttempt', 'function:\CrgPlan',
        'function:\CrgRollback', 'function:\CrgDoc', 'function:\CrgLines', 'function:\CrgAt' -ErrorAction SilentlyContinue
    Remove-Variable crg -Scope Global -ErrorAction SilentlyContinue
    Remove-VmfTestTemp
}

Describe 'ROLLBACK-CRG-1: the capture records the group' {

    It 'Get-VmfVmCapture records the group the machine is in' {
        $vm = [pscustomobject]@{ Id = $script:vmId; Name = 'vm1'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2ds_v4' }
            StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'; OsDisk = [pscustomobject]@{ Name = 'vm1-osdisk'; OsType = 'Linux'; ManagedDisk = [pscustomobject]@{ Id = '/disks/vm1-osdisk'; StorageAccountType = 'Premium_LRS' } }; DataDisks = @() }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @() }
            CapacityReservation = [pscustomobject]@{ CapacityReservationGroup = [pscustomobject]@{ Id = $script:theirs } } }
        $cap = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) Get-VmfVmCapture -Vm $vm }
        $cap.Contains('capacityReservationGroupId') | Should -BeTrue
        $cap.capacityReservationGroupId | Should -Be $script:theirs
    }

    It 'and records none as a field that is there and empty - never as a field that is missing' {
        $vm = [pscustomobject]@{ Id = $script:vmId; Name = 'vm1'; Location = 'centralus'
            HardwareProfile = [pscustomobject]@{ VmSize = 'Standard_D2ds_v4' }
            StorageProfile = [pscustomobject]@{ DiskControllerType = 'SCSI'; OsDisk = [pscustomobject]@{ Name = 'vm1-osdisk'; OsType = 'Linux'; ManagedDisk = [pscustomobject]@{ Id = '/disks/vm1-osdisk'; StorageAccountType = 'Premium_LRS' } }; DataDisks = @() }
            NetworkProfile = [pscustomobject]@{ NetworkInterfaces = @() } }
        $cap = InModuleScope VmMigrationFactory -Parameters @{ vm = $vm } { param($vm) Get-VmfVmCapture -Vm $vm }
        $cap.Contains('capacityReservationGroupId') | Should -BeTrue
        $cap.capacityReservationGroupId | Should -BeNullOrEmpty
    }

    It 'a record without the field is unknown; with it, the group or none' {
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:theirs } {
            param($g)
            $r = Get-VmfCapturedReservationGroup -Capture ([pscustomobject]@{ size = 'x' })
            $r.Known | Should -BeFalse
            $r = Get-VmfCapturedReservationGroup -Capture ([pscustomobject]@{ capacityReservationGroupId = $null })
            $r.Known | Should -BeTrue
            $r.GroupId | Should -BeNullOrEmpty
            $r = Get-VmfCapturedReservationGroup -Capture ([ordered]@{ capacityReservationGroupId = $g })
            $r.Known | Should -BeTrue
            $r.GroupId | Should -Be $g
            (Get-VmfCapturedReservationGroup -Capture $null).Known | Should -BeFalse
        }
    }

    It 'a put-back takes the group from the FIRST capture when this attempt''s capture names a group of this migration (ROLLBACK-RETRY-CAPTURE-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ theirs = $script:theirs; ours = $script:ours } {
            param($theirs, $ours)
            $doc = [pscustomobject]@{ captured = [pscustomobject]@{
                    vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v6'; capacityReservationGroupId = $ours; nics = @(); dataDisks = @() }
                    original = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v4'; capacityReservationGroupId = $theirs } } } }
            (Get-VmfPutBackCapture -Doc $doc -ProductGroupIds @($ours)).capacityReservationGroupId | Should -Be $theirs
            $doc.captured.original.vmConfig.capacityReservationGroupId = $null
            $back = Get-VmfPutBackCapture -Doc $doc -ProductGroupIds @($ours)
            $back.PSObject.Properties['capacityReservationGroupId'] | Should -Not -BeNullOrEmpty -Because 'none is a value'
            $back.capacityReservationGroupId | Should -BeNullOrEmpty
        }
    }

    It 'OLD-VERSION-READERS-REMOVE-4: a first capture that does not say its group stops the put-back, even when this attempt read one' {
        InModuleScope VmMigrationFactory -Parameters @{ ours = $script:ours } {
            param($ours)
            $doc = [pscustomobject]@{ captured = [pscustomobject]@{
                    vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v6'; capacityReservationGroupId = $ours; nics = @(); dataDisks = @() }
                    original = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v4' } } } }
            { Get-VmfPutBackCapture -Doc $doc } | Should -Throw '*does not say its capacity reservation group*'
            $doc.captured.vmConfig.capacityReservationGroupId | Should -Be $ours -Because 'the stored capture is evidence and is not changed'
        }
    }

    It 'a group of this migration in this attempt''s capture is never the put-back group' {
        InModuleScope VmMigrationFactory -Parameters @{ ours = $script:ours } {
            param($ours)
            $doc = [pscustomobject]@{ captured = [pscustomobject]@{
                    vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v6'; capacityReservationGroupId = $ours; nics = @(); dataDisks = @() }
                    original = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v4'; capacityReservationGroupId = $null } } } }
            $back = Get-VmfPutBackCapture -Doc $doc -ProductGroupIds @($ours.ToUpperInvariant())
            (Get-VmfCapturedReservationGroup -Capture $back).Known | Should -BeTrue
            (Get-VmfCapturedReservationGroup -Capture $back).GroupId | Should -BeNullOrEmpty
        }
    }

    # REBUILD-REMOVE-ENGINE-1: the capture field list a rebuild put back is gone with the rebuild.
}

Describe 'ROLLBACK-CRG-1: what a put-back does with the group' {

    BeforeAll {
        function Script:Decide($Current, $Captured, $Ours) {
            InModuleScope VmMigrationFactory -Parameters @{ c = $Current; k = $Captured; o = @($Ours) } {
                param($c, $k, $o)
                Get-VmfReservationPutBackPlan -CurrentGroupId $c -Captured $k -ProductGroupIds @($o | Where-Object { $_ })
            }
        }
    }

    It 'THE CASE: in the product''s group, captured in its own: leave the product''s, join its own' {
        $d = Script:Decide $script:ours @{ Known = $true; GroupId = $script:theirs } @($script:ours)
        $d.Leave | Should -BeTrue
        $d.LeaveGroupId | Should -Be $script:ours
        $d.JoinGroupId | Should -Be $script:theirs
    }

    It 'the decision says whether the group left is one of this migration' {
        (Script:Decide $script:ours @{ Known = $true; GroupId = $script:theirs } @($script:ours)).LeaveIsOurs | Should -BeTrue
        (Script:Decide $script:other @{ Known = $true; GroupId = $script:theirs } @($script:ours)).LeaveIsOurs | Should -BeFalse
        (Script:Decide $script:theirs @{ Known = $true; GroupId = $script:theirs } @($script:ours)).LeaveIsOurs | Should -BeFalse
    }

    It 'in the product''s group, captured in none: leave it, join nothing' {
        $d = Script:Decide $script:ours @{ Known = $true; GroupId = $null } @($script:ours)
        $d.Leave | Should -BeTrue
        $d.JoinGroupId | Should -BeNullOrEmpty
    }

    It 'in its own group, as captured: nothing changes' {
        $d = Script:Decide $script:theirs @{ Known = $true; GroupId = $script:theirs } @($script:ours)
        $d.Leave | Should -BeFalse
        $d.JoinGroupId | Should -BeNullOrEmpty
    }

    It 'the ids are compared without letter case, as Azure gives them both ways' {
        $d = Script:Decide $script:theirs.ToUpperInvariant() @{ Known = $true; GroupId = $script:theirs } @($script:ours.ToUpperInvariant())
        $d.Leave | Should -BeFalse
        $d.JoinGroupId | Should -BeNullOrEmpty
        (Script:Decide $script:ours.ToUpperInvariant() @{ Known = $true; GroupId = $null } @($script:ours)).Leave | Should -BeTrue
    }

    It 'in no group, captured in its own (a rebuild deleted the definition): join its own' {
        $d = Script:Decide $null @{ Known = $true; GroupId = $script:theirs } @()
        $d.Leave | Should -BeFalse
        $d.JoinGroupId | Should -Be $script:theirs
    }

    It 'in a group it was not in before the move: leave it, and put back the one it was in' {
        $d = Script:Decide $script:other @{ Known = $true; GroupId = $script:theirs } @($script:ours)
        $d.Leave | Should -BeTrue
        $d.LeaveGroupId | Should -Be $script:other
        $d.JoinGroupId | Should -Be $script:theirs
    }

    It 'OLD-VERSION-READERS-REMOVE-4: a record that does not say its group decides nothing - in any group or none' {
        foreach ($now in @($script:ours, $script:other, $null)) {
            { Script:Decide $now @{ Known = $false; GroupId = $null } @($script:ours) } | Should -Throw '*does not say its capacity reservation group*'
        }
    }

    It 'the groups of this migration are read from its quota records' {
        $rp = Global:CrgNewRun -Claim
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; ours = $script:ours } {
            param($rp, $ours)
            @(Get-VmfProductReservationGroupIds -RunPath $rp) | Should -Be @($ours)
        }
        $empty = Global:CrgNewRun
        InModuleScope VmMigrationFactory -Parameters @{ rp = $empty } { param($rp) @(Get-VmfProductReservationGroupIds -RunPath $rp).Count | Should -Be 0 }
    }
}

Describe 'ROLLBACK-CRG-1: the rollback, Path A' {
    BeforeEach { Global:CrgReset; Global:CrgMockAzure }

    It 'THE DEFECT: a machine in its own group, rolled back from Starting, keeps its group' {
        # The move joined the product's group; the machine was in its own before.
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        Global:CrgRollback $rp
        $global:crg.group | Should -Be $script:theirs
        $global:crg.size | Should -Be 'Standard_D2ds_v4'
        @($global:crg.calls) | Should -Contain 'start'
        (Global:CrgAt 'leave') | Should -BeLessThan (Global:CrgAt 'size:') -Because 'the product''s group holds only the new size (SAFETY-2)'
        (Global:CrgAt 'join:') | Should -BeGreaterThan (Global:CrgAt 'size:') -Because "Azure checks the size against the group (REH-1); the calls were: $(@($global:crg.calls) -join ', ')"
        (Global:CrgAt 'join:') | Should -BeLessThan (Global:CrgAt 'start')
        $lines = @(Global:CrgLines $rp | Where-Object { $_.step -eq 'rollback' })
        @($lines | Where-Object { $_.detail -match 'back in its capacity reservation group' -and $_.detail -match 'contoso-crg' }).Count | Should -Be 1
    }

    It 'the product''s group is still left when the machine had no group, and the quota record says so' {
        $rp = Global:CrgNewRun -Group 'none' -Claim
        Global:CrgRollback $rp
        $global:crg.group | Should -BeNullOrEmpty
        @($global:crg.calls | Where-Object { $_ -like 'join:*' }).Count | Should -Be 0
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
            param($rp, $id) @((Read-VmfStoreJson -RunPath $rp -RelPath 'capacity/w1-d2dsv6.json').associatedVmIds) | Should -Not -Contain $id
        }
    }

    It 'leaving the product''s group is information, not a warning, and is not recorded as a group left' {
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        Global:CrgRollback $rp
        @(Global:CrgLines $rp | Where-Object { $_.outcome -eq 'warn' -and $_.detail -match 'vmf-crg-w1' }).Count | Should -Be 0
        (Global:CrgDoc $rp).rollback.PSObject.Properties['reservationGroupLeft'] | Should -BeNullOrEmpty
    }

    It 'REVIEW: a group somebody joined during the move is left LOUDLY - a warning, the record, the last line and the stop' {
        $global:crg.group = $script:other
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; p = (Global:CrgPlan 'A') } {
            param($rp, $p)
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crg'
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'STARTING' -ReasonCode 'bootFailedAfterConversion' -Detail 'The machine did not start.'
            $null = Complete-VmfRollback -Context $ctx
        }
        $global:crg.group | Should -Be $script:theirs
        $lines = @(Global:CrgLines $rp | Where-Object { $_.step -eq 'rollback' })
        $warn = @($lines | Where-Object { $_.outcome -eq 'warn' -and $_.detail -match 'contoso-other' })
        $warn.Count | Should -Be 1
        $warn[0].detail | Should -Match 'this migration did not make it'
        ($lines | Where-Object { $_.outcome -eq 'ok' } | Select-Object -Last 1).detail | Should -Match 'contoso-other'
        $doc = Global:CrgDoc $rp
        $doc.rollback.reservationGroupLeft.groupId | Should -Be $script:other
        @($doc.history)[-1].detail | Should -Match 'contoso-other'
    }

    It 'a machine that stayed in its own group is not taken out of it' {
        $global:crg.group = $script:theirs
        $rp = Global:CrgNewRun -Group $script:theirs
        Global:CrgRollback $rp
        @($global:crg.calls | Where-Object { $_ -eq 'leave' -or $_ -like 'join:*' }).Count | Should -Be 0
        $global:crg.group | Should -Be $script:theirs
    }

    It 'when Azure refuses the group, the rollback says so in its own words and finishes' {
        $global:crg.holds[$script:theirs] = @('Standard_E4s_v4')   # no reservation for the size it goes back to
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        { Global:CrgRollback $rp } | Should -Not -Throw
        $global:crg.group | Should -BeNullOrEmpty
        @($global:crg.calls) | Should -Contain 'start'
        $lines = @(Global:CrgLines $rp | Where-Object { $_.step -eq 'rollback' })
        $warn = @($lines | Where-Object { $_.outcome -eq 'warn' -and $_.detail -match 'contoso-crg' })
        $warn.Count | Should -Be 1
        $warn[0].detail | Should -Match 'did not return the machine to its capacity reservation group'
        $warn[0].detail | Should -Match 'does not exist in the Capacity Reservation Group' -Because 'Azure''s own words'
        ($lines | Where-Object { $_.outcome -eq 'ok' } | Select-Object -Last 1).detail | Should -Match 'except its capacity reservation group'
        $rec = (Global:CrgDoc $rp).rollback.reservationGroupNotBack
        $rec.groupId | Should -Be $script:theirs
        $rec.why | Should -Match 'does not exist'
    }

    It 'and the stop that ends the rollback says it too, never only the activity' {
        $global:crg.holds[$script:theirs] = @('Standard_E4s_v4')
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        $end = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; p = (Global:CrgPlan 'A') } {
            param($rp, $p)
            $ctx = New-VmfContext -PlanEntry $p -RunPath $rp -RunId 'crg'
            Set-VmfRollbackPending -Context $ctx -Kind full -State 'STARTING' -ReasonCode 'bootFailedAfterConversion' -Detail 'The machine did not start.'
            Complete-VmfRollback -Context $ctx
        }
        $doc = Global:CrgDoc $rp
        $doc.state | Should -Be 'FAILED_ROLLED_BACK'
        $last = @($doc.history)[-1]
        $last.detail | Should -Match 'contoso-crg'
        $last.detail | Should -Match 'capacity reservation group'
    }

    It 'a rollback that put the group back clears what an earlier rollback recorded' {
        $global:crg.holds[$script:theirs] = @('Standard_E4s_v4')
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        Global:CrgRollback $rp
        (Global:CrgDoc $rp).rollback.reservationGroupNotBack | Should -Not -BeNullOrEmpty
        Global:CrgReset; Global:CrgMockAzure
        Global:CrgRollback $rp
        (Global:CrgDoc $rp).rollback.PSObject.Properties['reservationGroupNotBack'] | Should -BeNullOrEmpty
    }

    It 'OLD-VERSION-READERS-REMOVE-4: a record that does not say its group: the rollback stops before anything changes, and says why' {
        $global:crg.group = $script:other
        $rp = Global:CrgNewRun -Group 'unknown' -Claim
        { Global:CrgRollback $rp } | Should -Throw '*does not say its capacity reservation group, so the product does not change the machine.'
        $global:crg.group | Should -Be $script:other
        @($global:crg.calls).Count | Should -Be 0 -Because 'nothing is asked of Azure'
        @(Global:CrgLines $rp | Where-Object { $_.detail -match 'does not say its capacity reservation group' }).Count | Should -Be 1
    }

    It 'KILL AND RESUME (rule 4): a worker that stops after the join, resumed, joins once and ends in its own group' {
        $global:crg.killStartOnce = $true
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        { Global:CrgRollback $rp } | Should -Throw '*abandon this VM*'
        $global:crg.group | Should -Be $script:theirs -Because 'the join happened before the worker stopped'
        Global:CrgRollback $rp
        $global:crg.group | Should -Be $script:theirs
        @($global:crg.calls | Where-Object { $_ -like 'join:*' }).Count | Should -Be 1 -Because "a resume reads the group again; the calls were: $(@($global:crg.calls) -join ', ')"
        @($global:crg.calls | Where-Object { $_ -eq 'leave' }).Count | Should -Be 1
        @($global:crg.calls) | Should -Contain 'start'
    }

    It 'a worker that loses its lease during the join stops there - a lost lease is never said as a refused group' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmCapacityReservationGroup {
            if ($GroupId) { throw 'The lease was lost - abandon this VM.' }
            $global:crg.group = $null; $global:crg.calls.Add('leave')
        }
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        { Global:CrgRollback $rp } | Should -Throw '*abandon this VM*'
        @($global:crg.calls) | Should -Not -Contain 'start'
    }

    It 'KILL AND RESUME: a worker that stops after the leave, resumed, still puts the machine in its own group' {
        Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
            if (-not $global:crg.killedOnce) { $global:crg.killedOnce = $true; throw 'The lease was lost - abandon this VM.' }
            $global:crg.size = $Size; $global:crg.calls.Add("size:$Size")
        }
        $rp = Global:CrgNewRun -Group $script:theirs -Claim
        { Global:CrgRollback $rp } | Should -Throw '*abandon this VM*'
        $global:crg.group | Should -BeNullOrEmpty
        Global:CrgRollback $rp
        $global:crg.group | Should -Be $script:theirs
        $global:crg.size | Should -Be 'Standard_D2ds_v4'
    }
}

Describe 'ROLLBACK-CRG-1: the rollback before the move (from Preparing)' {
    BeforeEach { Global:CrgReset; Global:CrgMockAzure }

    It 'a machine in its own group, rolled back from Preparing, keeps it: nothing touches the group' {
        $global:crg.group = $script:theirs; $global:crg.size = 'Standard_D2ds_v4'; $global:crg.controller = 'SCSI'
        $rp = Global:CrgNewRun -Group $script:theirs
        Global:CrgRollback $rp -GuestOnly
        $global:crg.group | Should -Be $script:theirs
        @($global:crg.calls | Where-Object { $_ -eq 'leave' -or $_ -like 'join:*' }).Count | Should -Be 0
        @($global:crg.calls) | Should -Contain 'start'
    }
}

# REBUILD-REMOVE-ENGINE-1: the Path B rollback is gone with its step. Its tests were here.

Describe 'ROLLBACK-CRG-1: Restore this machine, from the first copy, in place' {
    BeforeEach { Global:CrgReset; Global:CrgMockAzure }

    It 'leaves the product''s group and puts the machine back in its own, after the size' {
        $rp = Global:CrgNewRun -Group $script:theirs -Claim -State 'MIGRATED'
        Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $global:crg.group | Should -Be $script:theirs
        (Global:CrgAt 'leave') | Should -BeLessThan (Global:CrgAt 'size:')
        (Global:CrgAt 'join:') | Should -BeGreaterThan (Global:CrgAt 'size:')
        (Global:CrgAt 'join:') | Should -BeLessThan (Global:CrgAt 'start')
    }

    It 'when Azure refuses the group, the restore says so and finishes' {
        $global:crg.holds[$script:theirs] = @('Standard_E4s_v4')
        $rp = Global:CrgNewRun -Group $script:theirs -Claim -State 'MIGRATED'
        { Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null } | Should -Not -Throw
        @($global:crg.calls) | Should -Contain 'start'
        @(Global:CrgLines $rp | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'warn' -and $_.detail -match 'contoso-crg' }).Count | Should -Be 1
    }

    It 'REVIEW: a group somebody joined during the move is left with a warning' {
        $global:crg.group = $script:other
        $rp = Global:CrgNewRun -Group $script:theirs -Claim -State 'MIGRATED'
        Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $global:crg.group | Should -Be $script:theirs
        @(Global:CrgLines $rp | Where-Object { $_.step -eq 'restore' -and $_.outcome -eq 'warn' -and $_.detail -match 'contoso-other' }).Count | Should -Be 1
    }

    It 'a machine that stayed in its own group keeps it' {
        $global:crg.group = $script:theirs
        $rp = Global:CrgNewRun -Group $script:theirs -State 'MIGRATED'
        Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        @($global:crg.calls | Where-Object { $_ -eq 'leave' -or $_ -like 'join:*' }).Count | Should -Be 0
        $global:crg.group | Should -Be $script:theirs
    }
}

Describe 'ROLLBACK-CRG-1: the join is asked about before anything changes (NIC-JOIN-1, ROLE-SNAP-1)' {

    BeforeAll {
        function Script:Gate([string]$Group = 'none', [switch]$Claim, [string[]]$Granted = @()) {
            $rp = Global:CrgNewRun -Group $Group -Claim:$Claim
            $script:granted = $Granted
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions { @([pscustomobject]@{ actions = @($script:granted); notActions = @() }) }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; id = $script:vmId } {
                param($rp, $id) Test-VmfReservationJoinPermissions -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id })
            }
        }
    }

    It 'THE CHECK: a machine in its own group, where this identity cannot deploy to the group, stops at Checking, naming both' {
        $r = Script:Gate -Group $script:theirs -Granted @('Microsoft.Compute/capacityReservationGroups/read')
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingReservationGroup'
        $r.Detail | Should -Match ([regex]::Escape('Microsoft.Compute/capacityReservationGroups/deploy/action'))
        $r.Detail | Should -Match ([regex]::Escape($script:theirs))
        $r.Detail | Should -Match 'stopped before it changed the machine'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly -ParameterFilter { $Scope -eq $script:theirs }
    }

    It 'a grant on the group passes' {
        Script:Gate -Group $script:theirs -Granted @('Microsoft.Compute/*') | Should -BeNullOrEmpty
    }

    It 'a group of this migration is not asked about - the product never puts a machine back in it' {
        Script:Gate -Group $script:ours -Claim | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly
    }

    It 'a machine in no group is not asked about; a record that does not say stops (OLD-VERSION-READERS-REMOVE-4)' {
        Script:Gate -Group 'none' | Should -BeNullOrEmpty
        { Script:Gate -Group 'unknown' } | Should -Throw '*does not say its capacity reservation group*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly
    }

    It 'the action it asks for is one the migration role grants - the check cannot demand what the role lacks' {
        $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        $granted = @($map.operations | Where-Object role -eq 'execute' | ForEach-Object { $_.actions })
        $asked = InModuleScope VmMigrationFactory { @($script:VmfReservationJoinActions) }
        $asked.Count | Should -BeGreaterThan 0
        foreach ($a in $asked) { $granted | Should -Contain $a }
        # The machine write that joins the group lists it as a linked action.
        $update = @($map.operations | Where-Object cmdlet -eq 'Update-AzVM')[0]
        @($update.actions) | Should -Contain 'Microsoft.Compute/capacityReservationGroups/deploy/action'
    }

    It 'Checking asks it after the capture is saved and before the target is recorded' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $pre = [regex]::Match($code, '(?s)function Invoke-VmfStepPrecheck \{.*?\nfunction ').Value
        $at = $pre.IndexOf('Test-VmfReservationJoinPermissions -Context $Context')
        $at | Should -BeGreaterThan 0
        $pre.IndexOf('Save-VmfCapturedFacts -Context $Context -Facts $facts') | Should -BeLessThan $at
        $at | Should -BeLessThan $pre.IndexOf('startedTarget = (Get-VmfStartedTarget')
    }
}

Describe 'CRG-JOIN-ATTEMPT-1 with CRG-ROLLBACK-ATTEMPT-GROUP-1: Checking asks about the group this attempt returns the machine to' {
    # CRG-JOIN-ATTEMPT-1 (2026-11-07) asked about two groups on a retry: the
    # first capture's (the put-back group then) and this attempt's (the group
    # the move acts in). Since CRG-ROLLBACK-ATTEMPT-GROUP-1 (2026-11-21) a
    # put-back of an attempt returns the machine to the group of THAT
    # attempt's capture, unless it is a group of this migration - so the move
    # and the put-back act in one group, and that group is asked about once.

    BeforeAll {
        # -First is the group of the first capture, -Now the group of this
        # attempt's capture: a group id, 'none', or 'unknown' (no field).
        # -NoOriginal: a first attempt, where the two captures are the same.
        function Script:AttemptRun([string]$First = 'none', [string]$Now = 'none', [switch]$NoOriginal, [switch]$Claim) {
            $rp = Global:CrgNewRun -Group $Now -Claim:$Claim
            if (-not $NoOriginal) { Global:CrgSetFirst -Rp $rp -First $First }
            $rp
        }
        # -Granted: group id -> the actions this identity holds on it.
        function Script:AttemptGate([string]$Rp, [hashtable]$Granted = @{}) {
            $script:grantedBy = $Granted
            Mock -ModuleName VmMigrationFactory Get-VmfEffectivePermissions {
                $acts = @($script:grantedBy.Keys | Where-Object { [string]::Equals($_, $Scope, [System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $script:grantedBy[$_] })
                @([pscustomobject]@{ actions = @($acts); notActions = @() })
            }
            InModuleScope VmMigrationFactory -Parameters @{ rp = $Rp; id = $script:vmId } {
                param($rp, $id) Test-VmfReservationJoinPermissions -Context ([pscustomobject]@{ RunPath = $rp; VmId = $id })
            }
        }
        $script:deploy = 'Microsoft.Compute/capacityReservationGroups/deploy/action'
    }

    It 'THE CASE: a retried machine in no group at first, now in its own group, with no grant on it, stops at Checking naming that group' {
        $rp = Script:AttemptRun -First 'none' -Now $script:theirs
        $r = Script:AttemptGate -Rp $rp
        $r.Next | Should -Be 'NEEDS_DECISION'
        $r.Reason | Should -Be 'permissionMissingReservationGroup'
        $r.Detail | Should -Match ([regex]::Escape("$script:deploy on $script:theirs"))
        $r.Detail | Should -Match 'A rollback or a restore returns this machine to the group'
        $r.Detail | Should -Match 'missing 1 permission on'
        $r.Detail | Should -Match 'stopped before it changed the machine'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly -ParameterFilter { $Scope -eq $script:theirs }
    }

    It 'the same retry with the grant on the group passes' {
        $rp = Script:AttemptRun -First 'none' -Now $script:theirs
        Script:AttemptGate -Rp $rp -Granted @{ $script:theirs = @($script:deploy) } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly
    }

    It 'a first capture whose record does not say the group stops the check, as every put-back (OLD-VERSION-READERS-REMOVE-4)' {
        $rp = Script:AttemptRun -First 'unknown' -Now $script:theirs
        { Script:AttemptGate -Rp $rp } | Should -Throw '*does not say its capacity reservation group*'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly
    }

    It 'a retry that moved to another group asks only the group it is in now - the put-back no longer returns it to the first' {
        $rp = Script:AttemptRun -First $script:other -Now $script:theirs
        $r = Script:AttemptGate -Rp $rp
        $r.Reason | Should -Be 'permissionMissingReservationGroup'
        $r.Detail | Should -Match ([regex]::Escape("$script:deploy on $script:theirs"))
        $r.Detail | Should -Not -Match 'contoso-other'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly -ParameterFilter { $Scope -eq $script:other }
        Script:AttemptGate -Rp $rp -Granted @{ $script:theirs = @($script:deploy) } | Should -BeNullOrEmpty
    }

    It 'a first attempt is asked once' {
        $rp = Script:AttemptRun -Now $script:theirs -NoOriginal
        $r = Script:AttemptGate -Rp $rp
        $r.Reason | Should -Be 'permissionMissingReservationGroup'
        $r.Detail | Should -Match 'returns this machine to the group'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly
    }

    It 'a retry in the same group as at first is asked once, whatever the letter case' {
        $rp = Script:AttemptRun -First $script:theirs.ToUpperInvariant() -Now $script:theirs
        Script:AttemptGate -Rp $rp | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly
    }

    It 'a retry now in a group of this migration, in no group at first, is not asked about any group' {
        $rp = Script:AttemptRun -First 'none' -Now $script:ours -Claim
        Script:AttemptGate -Rp $rp | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly
    }

    It 'a retry now in a group of this migration, in its own group at first, is asked about its own group - the put-back returns it there' {
        $rp = Script:AttemptRun -First $script:theirs -Now $script:ours -Claim
        $r = Script:AttemptGate -Rp $rp
        $r.Detail | Should -Match ([regex]::Escape("$script:deploy on $script:theirs"))
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly -ParameterFilter { $Scope -eq $script:theirs }
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 0 -Exactly -ParameterFilter { $Scope -eq $script:ours }
    }

    It 'a retry now in no group is asked about the group of the first capture - the put-back returns it there' {
        $rp = Script:AttemptRun -First $script:theirs -Now 'none'
        Script:AttemptGate -Rp $rp | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly -ParameterFilter { $Scope -eq $script:theirs }
    }

    It 'REVIEW: a retry now in no group, with a group an earlier rollback still owes, is asked about the owed group' {
        $rp = Script:AttemptRun -First 'none' -Now 'none'
        Global:CrgOwe -Rp $rp -Group $script:theirs
        Script:AttemptGate -Rp $rp | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfEffectivePermissions -Times 1 -Exactly -ParameterFilter { $Scope -eq $script:theirs }
    }

    It 'a resume asks again and gives the same answer: the check reads and writes nothing (rule 4)' {
        $rp = Script:AttemptRun -First 'none' -Now $script:theirs
        $docBefore = Global:CrgDoc $rp | ConvertTo-Json -Depth 30
        $one = Script:AttemptGate -Rp $rp
        $two = Script:AttemptGate -Rp $rp
        $two.Reason | Should -Be $one.Reason
        $two.Detail | Should -Be $one.Detail
        (Global:CrgDoc $rp | ConvertTo-Json -Depth 30) | Should -Be $docBefore
    }
}

Describe 'CRG-ROLLBACK-ATTEMPT-GROUP-1: a put-back of an attempt returns the machine to the group of that attempt' {
    # Found 2026-11-07 by the review of CRG-JOIN-ATTEMPT-1, seen again
    # 2026-11-21. The put-back took the group from the FIRST capture, as it
    # takes the size (ROLLBACK-RETRY-CAPTURE-1). But the size, the controller
    # and the disk types are what the product changed; a group chosen between
    # two attempts is not. A machine in no group at first, put in a group of
    # its own and retried, was taken out of that group by the rollback of the
    # retry, and its later starts had no capacity guarantee.
    # THE RULE: a rollback or a restore of attempt N returns the machine to the
    # group of attempt N's capture (SAFETY-RETRY-1: a retry is a complete new
    # run), unless that capture does not say, or names a group of this
    # migration - then the first capture's group stands.

    Context 'the put-back capture' {
        BeforeAll {
            # -Owed: an earlier rollback recorded that Azure did not put the
            # machine back in this group (rollback.reservationGroupNotBack).
            # -RestoredAfter: a restore ran after that rollback.
            function Script:BackGroup($First, $Now, [string[]]$Ours = @(), [switch]$NowUnknown, [string]$Owed, [switch]$RestoredAfter) {
                InModuleScope VmMigrationFactory -Parameters @{ f = $First; n = $Now; o = @($Ours); u = [bool]$NowUnknown; w = $Owed; ra = [bool]$RestoredAfter } {
                    param($f, $n, $o, $u, $w, $ra)
                    $attempt = [pscustomobject]@{ size = 'Standard_D2ds_v6'; nics = @(); dataDisks = @() }
                    if (-not $u) { $attempt | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $n }
                    $doc = [pscustomobject]@{ captured = [pscustomobject]@{
                            vmConfig = $attempt
                            original = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v4'; capacityReservationGroupId = $f } } } }
                    if ($w) {
                        $doc | Add-Member -NotePropertyName rollback -NotePropertyValue ([pscustomobject]@{ rolledBackUtc = '2026-11-02T00:00:00.0000000Z'; path = 'A'; osDisk = $null; dataDisks = @()
                                reservationGroupNotBack = [pscustomobject]@{ groupId = $w; why = 'Capacity Reservation with VM size Standard_D2ds_v4 does not exist.' } })
                    }
                    if ($ra) { $doc | Add-Member -NotePropertyName restore -NotePropertyValue ([pscustomobject]@{ restoredUtc = '2026-11-03T00:00:00.0000000Z' }) }
                    $back = Get-VmfPutBackCapture -Doc $doc -ProductGroupIds @($o | Where-Object { $_ })
                    $back.PSObject.Properties['capacityReservationGroupId'] | Should -Not -BeNullOrEmpty -Because 'the put-back capture always says its group'
                    $doc.captured.vmConfig.size | Should -Be 'Standard_D2ds_v6' -Because 'the stored capture is evidence and is not changed'
                    [string]$back.capacityReservationGroupId
                }
            }
        }

        It 'THE CASE: in no group at first, in its own group at this attempt: the put-back group is its own' {
            Script:BackGroup -First $null -Now $script:theirs -Ours @($script:ours) | Should -Be $script:theirs
        }

        It 'in one group at first and another of its own at this attempt: the put-back group is the one of this attempt' {
            Script:BackGroup -First $script:other -Now $script:theirs -Ours @($script:ours) | Should -Be $script:theirs
        }

        It 'in its own group at first and in no group at this attempt: the put-back group is the first capture''s, as before this rule' {
            Script:BackGroup -First $script:theirs -Now $null | Should -Be $script:theirs
        }

        It 'REVIEW: a group an earlier rollback did not put the machine back in is the put-back group of a later attempt in no group' {
            Script:BackGroup -First $null -Now $null -Owed $script:theirs | Should -Be $script:theirs
            Script:BackGroup -First $script:other -Now $null -Owed $script:theirs | Should -Be $script:theirs -Because 'the owed group is the one the earlier attempt tried'
        }

        It 'REVIEW: the owed group stands for a later attempt in a group of this migration too' {
            Script:BackGroup -First $null -Now $script:ours -Ours @($script:ours) -Owed $script:theirs | Should -Be $script:theirs
        }

        It 'REVIEW: a group of its own at this attempt wins over the owed group - the machine was moved on purpose' {
            Script:BackGroup -First $null -Now $script:other -Ours @($script:ours) -Owed $script:theirs | Should -Be $script:other
        }

        It 'REVIEW: a restore after that rollback ends the owed group - the restore made its own decision' {
            Script:BackGroup -First $null -Now $null -Owed $script:theirs -RestoredAfter | Should -BeNullOrEmpty
        }

        It 'REVIEW: a group of this migration is never owed' {
            Script:BackGroup -First $null -Now $null -Ours @($script:ours) -Owed $script:ours | Should -BeNullOrEmpty
        }

        It 'a group of this migration in this attempt''s capture: the first capture''s group stands, whatever the letter case' {
            Script:BackGroup -First $script:theirs -Now $script:ours -Ours @($script:ours.ToUpperInvariant()) | Should -Be $script:theirs
        }

        It 'this attempt''s capture does not say its group: the first capture''s group stands' {
            Script:BackGroup -First $script:theirs -Now $null -NowUnknown | Should -Be $script:theirs
        }

        It 'the size still comes from the first capture' {
            InModuleScope VmMigrationFactory -Parameters @{ theirs = $script:theirs } {
                param($theirs)
                $doc = [pscustomobject]@{ captured = [pscustomobject]@{
                        vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v6'; capacityReservationGroupId = $theirs; nics = @(); dataDisks = @() }
                        original = [pscustomobject]@{ vmConfig = [pscustomobject]@{ size = 'Standard_D2ds_v4'; capacityReservationGroupId = $null } } } }
                (Get-VmfPutBackCapture -Doc $doc).size | Should -Be 'Standard_D2ds_v4'
            }
        }
    }

    Context 'the rollback' {
        BeforeEach { Global:CrgReset; Global:CrgMockAzure }

        It 'THE CASE: in no group at first, retried in its own group, which the move kept: the rollback keeps it there' {
            $global:crg.group = $script:theirs
            $global:crg.holds[$script:theirs] = @('Standard_D2ds_v4', 'Standard_D2ds_v6')
            $rp = Global:CrgNewRun -Group $script:theirs
            Global:CrgSetFirst -Rp $rp -First 'none'
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
            @($global:crg.calls | Where-Object { $_ -eq 'leave' -or $_ -like 'join:*' }).Count | Should -Be 0 -Because "the calls were: $(@($global:crg.calls) -join ', ')"
            @(Global:CrgLines $rp | Where-Object { $_.step -eq 'rollback' -and $_.outcome -eq 'warn' -and $_.detail -match 'contoso-crg' }).Count | Should -Be 0
            @($global:crg.calls) | Should -Contain 'start'
        }

        It 'in another group at first, retried in its own group and moved in the group of the wave: the rollback returns it to its own group, never to the first' {
            $rp = Global:CrgNewRun -Group $script:theirs -Claim
            Global:CrgSetFirst -Rp $rp -First $script:other
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
            @($global:crg.calls) | Should -Not -Contain 'join:contoso-other'
            (Global:CrgAt 'join:contoso-crg') | Should -BeGreaterThan (Global:CrgAt 'size:')
        }

        It 'in its own group at first, retried while in the group of the wave: the rollback leaves the group of the wave and returns it to its own' {
            $rp = Global:CrgNewRun -Group $script:ours -Claim
            Global:CrgSetFirst -Rp $rp -First $script:theirs
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
            (Global:CrgAt 'leave') | Should -BeLessThan (Global:CrgAt 'size:')
            (Global:CrgAt 'join:contoso-crg') | Should -BeGreaterThan (Global:CrgAt 'size:')
        }

        It 'in its own group at first, retried in no group with nothing on record: the rollback returns it to its own group, as before this rule' {
            $rp = Global:CrgNewRun -Group 'none' -Claim
            Global:CrgSetFirst -Rp $rp -First $script:theirs
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
        }

        It 'REVIEW: Azure refused the group on the first rollback; the rollback of the next attempt tries it again, and then nothing is owed' {
            # Attempt 1: in no group at first, in its own group at the attempt. The group holds no reservation for D2ds_v4.
            $global:crg.holds[$script:theirs] = @('Standard_E4s_v4')
            $rp = Global:CrgNewRun -Group $script:theirs -Claim
            Global:CrgSetFirst -Rp $rp -First 'none'
            Global:CrgRollback $rp
            $global:crg.group | Should -BeNullOrEmpty
            (Global:CrgDoc $rp).rollback.reservationGroupNotBack.groupId | Should -Be $script:theirs
            # Attempt 2 starts in no group. The customer adds the reservation; the move joins the group of the wave.
            Global:CrgNextAttempt -Rp $rp -Group 'none'
            $global:crg.holds[$script:theirs] = @('Standard_D2ds_v4')
            $global:crg.group = $script:ours; $global:crg.size = 'Standard_D2ds_v6'; $global:crg.calls.Clear()
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs -Because "the calls were: $(@($global:crg.calls) -join ', ')"
            (Global:CrgAt 'join:contoso-crg') | Should -BeGreaterThan (Global:CrgAt 'size:')
            (Global:CrgDoc $rp).rollback.PSObject.Properties['reservationGroupNotBack'] | Should -BeNullOrEmpty -Because 'the group is back, so nothing is owed'
        }

        It 'REVIEW: refused again on the next attempt, the group stays owed with the new words' {
            $global:crg.holds[$script:theirs] = @('Standard_E4s_v4')
            $rp = Global:CrgNewRun -Group $script:theirs -Claim
            Global:CrgSetFirst -Rp $rp -First 'none'
            Global:CrgRollback $rp
            Global:CrgNextAttempt -Rp $rp -Group 'none'
            $global:crg.group = $script:ours; $global:crg.size = 'Standard_D2ds_v6'; $global:crg.calls.Clear()
            Global:CrgRollback $rp
            @($global:crg.calls) | Should -Contain 'leave'
            @($global:crg.calls | Where-Object { $_ -like 'join:*' }).Count | Should -Be 0 -Because 'Azure refused the join again'
            (Global:CrgDoc $rp).rollback.reservationGroupNotBack.groupId | Should -Be $script:theirs
        }

        It 'REVIEW: a rollback before the move keeps the owed group on record - it does not try any group' {
            $rp = Global:CrgNewRun -Group 'none'
            Global:CrgSetFirst -Rp $rp -First 'none'
            Global:CrgOwe -Rp $rp -Group $script:theirs
            $global:crg.group = $null; $global:crg.size = 'Standard_D2ds_v4'; $global:crg.controller = 'SCSI'
            Global:CrgRollback $rp -GuestOnly
            @($global:crg.calls | Where-Object { $_ -eq 'leave' -or $_ -like 'join:*' }).Count | Should -Be 0
            (Global:CrgDoc $rp).rollback.reservationGroupNotBack.groupId | Should -Be $script:theirs
        }

        It 'REVIEW KILL AND RESUME (rule 4): stopped after the leave, before the try, the resume still tries the owed group' {
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
                if (-not $global:crg.killedOnce) { $global:crg.killedOnce = $true; throw 'The lease was lost - abandon this VM.' }
                $global:crg.size = $Size; $global:crg.calls.Add("size:$Size")
            }
            $rp = Global:CrgNewRun -Group 'none' -Claim
            Global:CrgSetFirst -Rp $rp -First 'none'
            Global:CrgOwe -Rp $rp -Group $script:theirs
            { Global:CrgRollback $rp } | Should -Throw '*abandon this VM*'
            (Global:CrgDoc $rp).rollback.reservationGroupNotBack.groupId | Should -Be $script:theirs -Because 'nothing has tried the group yet'
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
            (Global:CrgDoc $rp).rollback.PSObject.Properties['reservationGroupNotBack'] | Should -BeNullOrEmpty
        }

        It 'REVIEW KILL AND RESUME (rule 4): stopped after the join and the record of the disk swap, the resume joins once and then nothing is owed' {
            $global:crg.killStartOnce = $true
            $rp = Global:CrgNewRun -Group 'none' -Claim
            Global:CrgSetFirst -Rp $rp -First 'none'
            Global:CrgOwe -Rp $rp -Group $script:theirs
            { Global:CrgRollback $rp } | Should -Throw '*abandon this VM*'
            $global:crg.group | Should -Be $script:theirs
            @($global:crg.calls | Where-Object { $_ -like 'swap:*' }).Count | Should -BeGreaterThan 0 -Because 'the record is written again after the disk swap, before the start'
            (Global:CrgDoc $rp).rollback.rolledBackUtc | Should -Not -Be ([datetime]'2026-11-02T00:00:00Z').ToUniversalTime() -Because 'the record was written again by this rollback'
            (Global:CrgDoc $rp).rollback.reservationGroupNotBack.groupId | Should -Be $script:theirs -Because 'a write before the last one carries the group on'
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
            @($global:crg.calls | Where-Object { $_ -like 'join:*' }).Count | Should -Be 1
            (Global:CrgDoc $rp).rollback.PSObject.Properties['reservationGroupNotBack'] | Should -BeNullOrEmpty
        }

        It 'KILL AND RESUME (rule 4): a rollback of a retry stopped after the leave, resumed, still returns the machine to the group of this attempt' {
            Mock -ModuleName VmMigrationFactory Set-VmfVmSizeAndController {
                if (-not $global:crg.killedOnce) { $global:crg.killedOnce = $true; throw 'The lease was lost - abandon this VM.' }
                $global:crg.size = $Size; $global:crg.calls.Add("size:$Size")
            }
            $rp = Global:CrgNewRun -Group $script:theirs -Claim
            Global:CrgSetFirst -Rp $rp -First 'none'
            { Global:CrgRollback $rp } | Should -Throw '*abandon this VM*'
            $global:crg.group | Should -BeNullOrEmpty -Because 'the worker stopped after it left the group of the wave'
            Global:CrgRollback $rp
            $global:crg.group | Should -Be $script:theirs
            @($global:crg.calls | Where-Object { $_ -like 'join:*' }) | Should -Be @('join:contoso-crg')
            @($global:crg.calls) | Should -Contain 'start'
        }
    }

    Context 'Restore this machine' {
        BeforeEach { Global:CrgReset; Global:CrgMockAzure }

        It 'in no group at first, retried in its own group: the restore returns the machine to its own group' {
            $rp = Global:CrgNewRun -Group $script:theirs -Claim -State 'MIGRATED'
            Global:CrgSetFirst -Rp $rp -First 'none'
            Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
            $global:crg.group | Should -Be $script:theirs
            (Global:CrgAt 'join:contoso-crg') | Should -BeGreaterThan (Global:CrgAt 'size:')
        }

        It 'in its own group at first, retried while in the group of the wave: the restore returns it to its own group' {
            $rp = Global:CrgNewRun -Group $script:ours -Claim -State 'MIGRATED'
            Global:CrgSetFirst -Rp $rp -First $script:theirs
            Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
            $global:crg.group | Should -Be $script:theirs
        }
    }
}

Describe 'ROLLBACK-CRG-1: the contract (vm-state v24)' {
    BeforeAll {
        $script:schema = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json
        $script:sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json') -Raw | ConvertFrom-Json
    }

    It 'the schema, the store and the sample are v24' {
        $script:schema.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion | Should -Be 51 }
        $script:sample.schemaVersion | Should -Be 51
    }

    It 'the schema declares the captured group and what a rollback did not put back' {
        $vc = $script:schema.properties.captured.properties.vmConfig.properties.capacityReservationGroupId
        $vc | Should -Not -BeNullOrEmpty
        @($vc.type) | Should -Contain 'null'
        $vc.description | Should -Match 'Required \(v47\)'
        $nb = $script:schema.properties.rollback.properties.reservationGroupNotBack
        @($nb.required) | Should -Be @('groupId', 'why')
        @($script:schema.properties.rollback.properties.reservationGroupLeft.required) | Should -Be @('groupId')
    }

    It 'the sample shows both' {
        $script:sample.captured.vmConfig.PSObject.Properties['capacityReservationGroupId'] | Should -Not -BeNullOrEmpty
        $script:sample.captured.original.vmConfig.PSObject.Properties['capacityReservationGroupId'] | Should -Not -BeNullOrEmpty
        $script:sample.rollback.reservationGroupNotBack.groupId | Should -Match 'capacityReservationGroups'
    }

    It 'the migration note says what an older record means' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match '## vm-state v23 -> v24 \(\d{4}-\d{2}-\d{2}, ROLLBACK-CRG-1\)'
        $notes | Should -Match '(?s)v23 -> v24.*unknown'
    }
}

# RESERVATION-RESULT-WORDS-1 (volumes lab, 2026-11-14): the activity showed
# "Checking which capacity reservation group this machine is in" and never
# said what the read found. The rollback words are approved; the restore
# pair is the same with "the restore". A line is written only where it is
# true: a machine in the group it was in before the move (or in none, as
# before). Where the groups differ, the leave and join lines say it.
Describe 'RESERVATION-RESULT-WORDS-1: the put-back says the group it read' {
    BeforeAll {
        $script:noneRollback = 'The machine is in no capacity reservation group, so the rollback has no group to put it back in.'
        $script:inRollback = 'The machine is in the capacity reservation group contoso-crg. The rollback puts it back in that group.'
        $script:noneRestore = 'The machine is in no capacity reservation group, so the restore has no group to put it back in.'
        $script:inRestore = 'The machine is in the capacity reservation group contoso-crg. The restore puts it back in that group.'
        function Global:CrgReadWords([string]$Kind, [string]$Current, $Was) {
            InModuleScope VmMigrationFactory -Parameters @{ k = $Kind; c = $Current; w = $Was } {
                param($k, $c, $w) Get-VmfReservationReadWords -Kind $k -CurrentGroupId $c -CapturedGroupId $w
            }
        }
        # The line right after the read, or $null. -OwnStep: the first line of
        # the put-back's own step after it (an Azure call can come between).
        function Global:CrgLineAfterRead([string]$Rp, [string]$Kind, [switch]$OwnStep) {
            $all = @(Global:CrgLines $Rp)
            $at = -1
            for ($i = 0; $i -lt $all.Count; $i++) { if ($all[$i].step -eq "azureops:$($Kind):readReservation" -and $all[$i].outcome -eq 'ok') { $at = $i; break } }
            if ($at -lt 0 -or $at + 1 -ge $all.Count) { return $null }
            if ($OwnStep) { return @($all[($at + 1)..($all.Count - 1)] | Where-Object { $_.step -eq $Kind } | Select-Object -First 1) }
            $all[$at + 1]
        }
    }
    AfterAll { Remove-Item 'function:\CrgReadWords', 'function:\CrgLineAfterRead' -ErrorAction SilentlyContinue }
    BeforeEach { Global:CrgReset; Global:CrgMockAzure }

    It 'in no group, as before the move: the approved words for no group' {
        Global:CrgReadWords 'rollback' '' $null | Should -BeExactly $script:noneRollback
        Global:CrgReadWords 'restore' '' $null | Should -BeExactly $script:noneRestore
    }

    It 'in the group it was in before the move: the approved words, with the group''s name only' {
        Global:CrgReadWords 'rollback' $script:theirs $script:theirs | Should -BeExactly $script:inRollback
        Global:CrgReadWords 'restore' $script:theirs $script:theirs | Should -BeExactly $script:inRestore
        Global:CrgReadWords 'rollback' $script:theirs.ToUpperInvariant() $script:theirs | Should -Match 'group CONTOSO-CRG\. The rollback' -Because 'Azure gives an id in either letter case'
    }

    It 'groups that differ write no read line: the leave and join lines say it' {
        Global:CrgReadWords 'rollback' '' $script:theirs | Should -BeNullOrEmpty -Because 'the rollback puts it in a group, so "no group to put it back in" is false'
        Global:CrgReadWords 'rollback' $script:ours $null | Should -BeNullOrEmpty -Because 'the rollback takes it out of the group'
        Global:CrgReadWords 'rollback' $script:other $script:theirs | Should -BeNullOrEmpty
    }

    It 'THE CASE: a rollback of a machine in no group says so, on the line after the read' {
        $global:crg.group = $null
        $rp = Global:CrgNewRun -Group 'none'
        Global:CrgRollback $rp
        $line = Global:CrgLineAfterRead $rp 'rollback'
        $line.step | Should -Be 'rollback'
        $line.outcome | Should -Be 'info'
        $line.detail | Should -BeExactly $script:noneRollback
    }

    It 'a rollback of a machine that stayed in its own group names the group' {
        $global:crg.group = $script:theirs
        $rp = Global:CrgNewRun -Group $script:theirs
        Global:CrgRollback $rp
        (Global:CrgLineAfterRead $rp 'rollback').detail | Should -BeExactly $script:inRollback
        @(Global:CrgLines $rp | Where-Object { $_.detail -eq $script:inRollback }).Count | Should -Be 1
    }

    It 'a rollback that leaves the product''s group writes no read line, only the leave line' {
        $rp = Global:CrgNewRun -Group 'none' -Claim
        Global:CrgRollback $rp
        @(Global:CrgLines $rp | Where-Object { $_.detail -match '^The machine is in (no|the) capacity reservation group' }).Count | Should -Be 0
        (Global:CrgLineAfterRead $rp 'rollback' -OwnStep).detail | Should -Match "left the capacity reservation group 'vmf-crg-w1'"
    }

    It 'a restore says it in its own words' {
        $global:crg.group = $null
        $rp = Global:CrgNewRun -Group 'none' -State 'MIGRATED'
        Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        $line = Global:CrgLineAfterRead $rp 'restore'
        $line.step | Should -Be 'restore'
        $line.outcome | Should -Be 'info'
        $line.detail | Should -BeExactly $script:noneRestore

        Global:CrgReset; Global:CrgMockAzure
        $global:crg.group = $script:theirs
        $rp = Global:CrgNewRun -Group $script:theirs -State 'MIGRATED'
        Restore-VmfVm -RunPath $rp -VmId $script:vmId -From pristine -Confirm:$false | Out-Null
        (Global:CrgLineAfterRead $rp 'restore').detail | Should -BeExactly $script:inRestore
    }

    It 'the run page shows the put-back line as its words, escaped' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $js = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')
        $js | Should -Match "if \(e\.step === 'rollback' && e\.detail\) \{ return e\.detail; \}"
        $js | Should -Match "if \(e\.outcome === 'info' && e\.detail\) return e\.detail;"
        $js | Should -Match 'esc\(stepText\(e\)\)'
    }
}
