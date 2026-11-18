#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# MISSING-READ-2: more failed reads were taken as "it is not there".
#
# MISSING-READ-1 fixed five reads and made Test-VmfAzNotFound the one test of
# a NotFound. These reads still used -ErrorAction SilentlyContinue, so a
# throttle, a 5xx or a reset socket read the same as "not there":
#   - Remove-VmfVmShell: a failed read was "shell already deleted". It went
#     with the rebuild (REBUILD-REMOVE-ROLE-1 removed the function).
#   - New-VmfOsDiskSnapshot: a failed read took the safety copy again, under
#     the same name, over a copy that may be there.
#   - Lock-VmfSnapshot: a failed read asked for the lock again. That write is
#     the same lock name and is safe, so it stays the answer - said here.
#   - Get-VmfAvailabilitySetMembers: a failed read of the set was "no other
#     members", so PRECHECK gave no note at all.
#   - New-VmfCapacityReservation and Remove-VmfCapacityReservation: a failed
#     read made a group or a reservation again, or skipped the delete.
#
# The stand-ins fail the way an Az cmdlet does: a NON-terminating error
# (Write-Error), which SilentlyContinue swallows and Stop turns into a throw.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    # CI has no Az modules: stand-ins with the parameters the reads use.
    function Global:Get-AzVM { [CmdletBinding()] param($ResourceGroupName, $Name, [switch]$UserData, [switch]$Status) throw 'stub' }
    function Global:Get-AzSnapshot { [CmdletBinding()] param($ResourceGroupName, $SnapshotName) throw 'stub' }
    function Global:New-AzSnapshotConfig { [CmdletBinding()] param($SourceUri, $Location, $CreateOption, [switch]$Incremental, $EncryptionType, $DiskEncryptionSetId) throw 'stub' }
    function Global:New-AzSnapshot { [CmdletBinding()] param($ResourceGroupName, $SnapshotName, $Snapshot) throw 'stub' }
    function Global:Get-AzResourceLock { [CmdletBinding()] param($LockName, $Scope, $ResourceGroupName, $ResourceName, $ResourceType) throw 'stub' }
    function Global:New-AzResourceLock { [CmdletBinding()] param($LockLevel, $LockName, $Scope, $LockNotes, [switch]$Force) throw 'stub' }
    function Global:Get-AzAvailabilitySet { [CmdletBinding()] param($ResourceGroupName, $Name) throw 'stub' }
    function Global:Get-AzCapacityReservationGroup { [CmdletBinding()] param($ResourceGroupName, $Name, $DefaultProfile) throw 'stub' }
    function Global:New-AzCapacityReservationGroup { [CmdletBinding()] param($ResourceGroupName, $Name, $Location, $Zone, $DefaultProfile, $Tag) throw 'stub' }
    function Global:Get-AzCapacityReservation { [CmdletBinding()] param($ResourceGroupName, $ReservationGroupName, $Name, $DefaultProfile) throw 'stub' }
    function Global:New-AzCapacityReservation { [CmdletBinding()] param($ResourceGroupName, $ReservationGroupName, $Name, $Location, $Sku, $CapacityToReserve, $Zone, $DefaultProfile, $Tag) throw 'stub' }
    function Global:Remove-AzCapacityReservation { [CmdletBinding(SupportsShouldProcess)] param($ResourceGroupName, $ReservationGroupName, $Name, $DefaultProfile) throw 'stub' }
    function Global:Remove-AzCapacityReservationGroup { [CmdletBinding(SupportsShouldProcess)] param($ResourceGroupName, $Name, $DefaultProfile) throw 'stub' }
    # TEST-AZURE-GUARD-1: the guard comes AFTER the stand-ins above.
    Block-VmfAzureCalls -TestFile $PSCommandPath
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    # Azure's words for each answer. Redacted: names are placeholders.
    $script:notFoundVm = "The Resource 'Microsoft.Compute/virtualMachines/vm1' under resource group 'rg-app' was not found. ErrorCode: ResourceNotFound"
    $script:notFoundSnap = "Resource 'vm1-pristine' was not found. ErrorCode: ResourceNotFound"
    $script:notFoundSet = "The Resource 'Microsoft.Compute/availabilitySets/avs1' under resource group 'rg-app' was not found. ErrorCode: ResourceNotFound"
    $script:notFoundGroup = "The Resource 'Microsoft.Compute/capacityReservationGroups/vmf-crg' under resource group 'rg-app' was not found. ErrorCode: ResourceNotFound"
    $script:noParent = "Can not perform requested operation on nested resource. Parent resource 'vmf-crg' not found. ErrorCode: ParentResourceNotFound"
    $script:unavailable = "Operation returned an invalid status code 'ServiceUnavailable'. StatusCode: 503"

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers'
    $script:vmId = "$($script:sub)/Microsoft.Compute/virtualMachines/vm1"
    $script:osId = "$($script:sub)/Microsoft.Compute/disks/vm1-os"
    $script:snapId = "$($script:sub)/Microsoft.Compute/snapshots/vm1-pristine"
    $script:setId = "$($script:sub)/Microsoft.Compute/availabilitySets/avs1"
    $script:subId = '00000000-0000-0000-0000-000000000000'
}
AfterAll {
    Remove-Item 'function:\Get-AzVM', 'function:\Get-AzSnapshot', 'function:\New-AzSnapshotConfig', 'function:\New-AzSnapshot',
        'function:\Get-AzResourceLock', 'function:\New-AzResourceLock', 'function:\Get-AzAvailabilitySet',
        'function:\Get-AzCapacityReservationGroup', 'function:\New-AzCapacityReservationGroup', 'function:\Get-AzCapacityReservation',
        'function:\New-AzCapacityReservation', 'function:\Remove-AzCapacityReservation', 'function:\Remove-AzCapacityReservationGroup',
        'function:\Mr2Capture', 'function:\Mr2Plan', 'function:\Mr2Run', 'function:\Mr2Ctx', 'function:\Mr2Doc' -ErrorAction SilentlyContinue
}

Describe 'MISSING-READ-2: no read named in the item asks Azure with SilentlyContinue' {
    It 'each function asks Test-VmfAzNotFound, and swallows nothing' {
        $vmCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1')
        $capCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsCapacity.ps1')
        $cases = @(
            @{ Code = $vmCode; Fn = 'New-VmfOsDiskSnapshot' }
            @{ Code = $vmCode; Fn = 'Lock-VmfSnapshot' }
            @{ Code = $vmCode; Fn = 'Get-VmfAvailabilitySetMembers' }
            @{ Code = $capCode; Fn = 'New-VmfCapacityReservation' }
            @{ Code = $capCode; Fn = 'Remove-VmfCapacityReservation' }
        )
        foreach ($case in $cases) {
            $body = [regex]::Match($case.Code, "(?s)function $($case.Fn) \{.*?\n\}").Value
            $body | Should -Not -BeNullOrEmpty -Because "$($case.Fn) is in the file"
            $body | Should -Not -Match 'SilentlyContinue' -Because "$($case.Fn) must tell a NotFound from no answer"
            $body | Should -Match 'Test-VmfAzNotFound' -Because "$($case.Fn) asks the one test of a NotFound"
        }
    }
}

Describe 'MISSING-READ-2: New-VmfOsDiskSnapshot (a failed read never takes the copy again)' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory New-AzSnapshotConfig { [pscustomobject]@{ Tags = $null } }
        Mock -ModuleName VmMigrationFactory New-AzSnapshot { [pscustomobject]@{ Id = '/snapshots/new'; Tags = $null } }
    }
    It 'a NotFound takes the copy' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundSnap; os = $script:osId } {
            param($m, $os)
            Mock Get-AzSnapshot { Write-Error -Message $m }
            New-VmfOsDiskSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'vm1-pristine' -OsDiskId $os -Location 'centralus' | Should -Be '/snapshots/new'
            Should -Invoke New-AzSnapshot -Times 1 -Exactly
        }
    }
    It 'a 503 throws, and takes no copy' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; os = $script:osId } {
            param($m, $os)
            Mock Get-AzSnapshot { Write-Error -Message $m }
            { New-VmfOsDiskSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'vm1-pristine' -OsDiskId $os -Location 'centralus' } | Should -Throw '*ServiceUnavailable*'
            Should -Invoke New-AzSnapshot -Times 0 -Exactly
        }
    }
    It 'a copy that is there is used, and none is taken' {
        InModuleScope VmMigrationFactory -Parameters @{ os = $script:osId } {
            param($os)
            Mock Get-AzSnapshot { [pscustomobject]@{ Id = '/snapshots/there' } }
            New-VmfOsDiskSnapshot -ResourceGroupName 'rg-app' -SnapshotName 'vm1-pristine' -OsDiskId $os -Location 'centralus' | Should -Be '/snapshots/there'
            Should -Invoke New-AzSnapshot -Times 0 -Exactly
        }
    }
}

Describe 'MISSING-READ-2: Lock-VmfSnapshot (asking for the same lock again is the safe answer)' {
    It 'a NotFound places the lock' {
        InModuleScope VmMigrationFactory -Parameters @{ snap = $script:snapId } {
            param($snap)
            Mock Get-AzResourceLock { Write-Error -Message "The lock 'vmf-safety-copy' could not be found. ErrorCode: LockNotFound" }
            Mock New-AzResourceLock { [pscustomobject]@{ LockId = '/lock/new' } }
            Lock-VmfSnapshot -SnapshotId $snap -Notes 'n' | Should -Be '/lock/new'
            Should -Invoke New-AzResourceLock -Times 1 -Exactly
        }
    }
    It 'a 503 asks for the same lock: the write is the answer, and it throws if Azure refuses it' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; snap = $script:snapId } {
            param($m, $snap)
            Mock Get-AzResourceLock { Write-Error -Message $m }
            Mock New-AzResourceLock { [pscustomobject]@{ LockId = '/lock/new' } }
            Lock-VmfSnapshot -SnapshotId $snap -Notes 'n' | Should -Be '/lock/new'
            Should -Invoke New-AzResourceLock -Times 1 -Exactly -ParameterFilter { $LockName -eq 'vmf-safety-copy' -and $LockLevel -eq 'CanNotDelete' }
            Mock New-AzResourceLock { Write-Error -Message $m }
            { Lock-VmfSnapshot -SnapshotId $snap -Notes 'n' } | Should -Throw '*ServiceUnavailable*'
        }
    }
}

Describe 'MISSING-READ-2: Get-VmfAvailabilitySetMembers (a failed read of the set is not "no other members")' {
    It 'a NotFound is no members' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundSet; set = $script:setId } {
            param($m, $set)
            Mock Get-AzAvailabilitySet { Write-Error -Message $m }
            @(Get-VmfAvailabilitySetMembers -AvailabilitySetId $set).Count | Should -Be 0
        }
    }
    It 'a 503 throws' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; set = $script:setId } {
            param($m, $set)
            Mock Get-AzAvailabilitySet { Write-Error -Message $m }
            { Get-VmfAvailabilitySetMembers -AvailabilitySetId $set } | Should -Throw '*ServiceUnavailable*'
        }
    }
    It 'a set that is there gives its members; a power state Azure did not give stays unknown' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; set = $script:setId; sub = $script:sub } {
            param($m, $set, $sub)
            Mock Get-AzAvailabilitySet { [pscustomobject]@{ VirtualMachinesReferences = @(
                [pscustomobject]@{ Id = "$sub/Microsoft.Compute/virtualMachines/vm-a" },
                [pscustomobject]@{ Id = "$sub/Microsoft.Compute/virtualMachines/vm-b" }) } }
            Mock Get-AzVM { [pscustomobject]@{ Statuses = @([pscustomobject]@{ Code = 'PowerState/running' }) } } -ParameterFilter { $Name -eq 'vm-a' }
            Mock Get-AzVM { Write-Error -Message $m } -ParameterFilter { $Name -eq 'vm-b' }
            $r = @(Get-VmfAvailabilitySetMembers -AvailabilitySetId $set)
            $r.Count | Should -Be 2
            ($r | Where-Object Name -EQ 'vm-a').Allocated | Should -BeTrue
            ($r | Where-Object Name -EQ 'vm-b').Allocated | Should -BeNullOrEmpty -Because 'unknown is never "stopped"'
        }
    }
}

Describe 'MISSING-READ-2: PRECHECK still gives the availability set note when Azure did not give the members' {
    It 'the note says Azure did not give the other machines, and warns when the hardware is not known to offer the size' {
        $n = InModuleScope VmMigrationFactory { Get-VmfAvailabilitySetUnknownNote -TargetSize 'Standard_D2ds_v6' -OfferedSizes $null }
        $n.Outcome | Should -Be 'warn'
        $n.Detail | Should -Match 'Azure did not give the other machines in it'
        $n.Detail | Should -Match 'Standard_D2ds_v6'
        $n.Detail | Should -Match 'until every machine in the set is stopped'
        $n2 = InModuleScope VmMigrationFactory { Get-VmfAvailabilitySetUnknownNote -TargetSize 'Standard_D2ds_v6' -OfferedSizes @('Standard_D4ds_v6') }
        $n2.Outcome | Should -Be 'warn'
    }
    It 'hardware that offers the size: info, and the members are still said as unknown' {
        $n = InModuleScope VmMigrationFactory { Get-VmfAvailabilitySetUnknownNote -TargetSize 'Standard_D2ds_v6' -OfferedSizes @('standard_d2ds_v6') }
        $n.Outcome | Should -Be 'info'
        $n.Detail | Should -Match 'Azure did not give the other machines in it'
        $n.Detail | Should -Match 'offers Standard_D2ds_v6'
    }
    It 'PRECHECK catches a failed members read and gives that note, never silence' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1')
        $code | Should -Match 'catch \{ \$members = \$null \}'
        $code | Should -Match 'if \(\$null -eq \$members -or \$others\.Count -gt 0\)'
        $code | Should -Match 'avsetNote = if \(\$null -eq \$members\) \{ Get-VmfAvailabilitySetUnknownNote -TargetSize \$target -OfferedSizes \$offered \}'
    }
}

Describe 'MISSING-READ-2: New-VmfCapacityReservation (a failed read never makes a group or a reservation again)' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfAzContextForSubscription { [pscustomobject]@{ Name = 'ctx' } }
        Mock -ModuleName VmMigrationFactory Wait-VmfReservationProvisioned { [pscustomobject]@{ Id = '/g/r' } }
        Mock -ModuleName VmMigrationFactory New-AzCapacityReservationGroup { [pscustomobject]@{ Id = '/g'; Tags = $null } }
        Mock -ModuleName VmMigrationFactory New-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r' } }
    }
    It 'a NotFound makes the group and the reservation' {
        InModuleScope VmMigrationFactory -Parameters @{ g = $script:notFoundGroup; r = $script:noParent; s = $script:subId } {
            param($g, $r, $s)
            Mock Get-AzCapacityReservationGroup { Write-Error -Message $g }
            Mock Get-AzCapacityReservation { Write-Error -Message $r }
            $ids = New-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -Location 'centralus' -Size 'Standard_D2ds_v6' -Quantity 1 -SubscriptionId $s
            $ids.GroupId | Should -Be '/g'
            Should -Invoke New-AzCapacityReservationGroup -Times 1 -Exactly
            Should -Invoke New-AzCapacityReservation -Times 1 -Exactly
        }
    }
    It 'a 503 on the group read throws, and makes nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; s = $script:subId } {
            param($m, $s)
            Mock Get-AzCapacityReservationGroup { Write-Error -Message $m }
            Mock Get-AzCapacityReservation { throw 'must not be read' }
            { New-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -Location 'centralus' -Size 'Standard_D2ds_v6' -Quantity 1 -SubscriptionId $s } | Should -Throw '*ServiceUnavailable*'
            Should -Invoke New-AzCapacityReservationGroup -Times 0 -Exactly
            Should -Invoke New-AzCapacityReservation -Times 0 -Exactly
        }
    }
    It 'a 503 on the reservation read throws, and makes no reservation' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; s = $script:subId } {
            param($m, $s)
            Mock Get-AzCapacityReservationGroup { [pscustomobject]@{ Id = '/g' } }
            Mock Get-AzCapacityReservation { Write-Error -Message $m }
            { New-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -Location 'centralus' -Size 'Standard_D2ds_v6' -Quantity 1 -SubscriptionId $s } | Should -Throw '*ServiceUnavailable*'
            Should -Invoke New-AzCapacityReservation -Times 0 -Exactly
        }
    }
    It 'a group and a reservation that are there are used, and none is made' {
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:subId } {
            param($s)
            Mock Get-AzCapacityReservationGroup { [pscustomobject]@{ Id = '/g' } }
            Mock Get-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r' } }
            $ids = New-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -Location 'centralus' -Size 'Standard_D2ds_v6' -Quantity 1 -SubscriptionId $s
            $ids.ReservationId | Should -Be '/g/r'
            Should -Invoke New-AzCapacityReservationGroup -Times 0 -Exactly
            Should -Invoke New-AzCapacityReservation -Times 0 -Exactly
        }
    }
}

Describe 'MISSING-READ-2: Remove-VmfCapacityReservation (a failed read never skips the delete)' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-VmfAzContextForSubscription { [pscustomobject]@{ Name = 'ctx' } }
        Mock -ModuleName VmMigrationFactory Remove-AzCapacityReservation { }
        Mock -ModuleName VmMigrationFactory Remove-AzCapacityReservationGroup { }
    }
    It 'a 503 on the reservation read throws, and deletes nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; s = $script:subId } {
            param($m, $s)
            Mock Get-AzCapacityReservation { Write-Error -Message $m }
            { Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s } | Should -Throw '*ServiceUnavailable*'
            Should -Invoke Remove-AzCapacityReservation -Times 0 -Exactly
            Should -Invoke Remove-AzCapacityReservationGroup -Times 0 -Exactly
        }
    }
    It 'a NotFound is a reservation already gone; the empty group is deleted' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:notFoundGroup; s = $script:subId } {
            param($m, $s)
            Mock Get-AzCapacityReservation { Write-Error -Message "Resource 'd2ds_v6' was not found. ErrorCode: ResourceNotFound" } -ParameterFilter { $Name }
            Mock Get-AzCapacityReservation { @() } -ParameterFilter { -not $Name }
            Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s
            Should -Invoke Remove-AzCapacityReservation -Times 0 -Exactly
            Should -Invoke Remove-AzCapacityReservationGroup -Times 1 -Exactly
        }
    }
    It 'a reservation that is there is deleted' {
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:subId } {
            param($s)
            Mock Get-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r'; VirtualMachinesAssociated = @() } } -ParameterFilter { $Name }
            Mock Get-AzCapacityReservation { @() } -ParameterFilter { -not $Name }
            Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s
            Should -Invoke Remove-AzCapacityReservation -Times 1 -Exactly
        }
    }
    It 'a 503 while it waits for the machines to leave throws, and deletes nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; s = $script:subId } {
            param($m, $s)
            $script:mr2Reads = 0
            Mock Get-AzCapacityReservation {
                $script:mr2Reads++
                if ($script:mr2Reads -eq 1) { [pscustomobject]@{ Id = '/g/r'; VirtualMachinesAssociated = @([pscustomobject]@{ Id = '/vm/a' }) } }
                else { Write-Error -Message $m }
            } -ParameterFilter { $Name }
            { Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s -PollSeconds 0 } | Should -Throw '*ServiceUnavailable*'
            Should -Invoke Remove-AzCapacityReservation -Times 0 -Exactly
        }
    }
    It 'a NotFound while it waits is a reservation deleted by someone else' {
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:subId } {
            param($s)
            $script:mr2Reads = 0
            Mock Get-AzCapacityReservation {
                $script:mr2Reads++
                if ($script:mr2Reads -eq 1) { [pscustomobject]@{ Id = '/g/r'; VirtualMachinesAssociated = @([pscustomobject]@{ Id = '/vm/a' }) } }
                else { Write-Error -Message "Resource 'd2ds_v6' was not found. ErrorCode: ResourceNotFound" }
            } -ParameterFilter { $Name }
            { Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s -PollSeconds 0 } | Should -Not -Throw
            Should -Invoke Remove-AzCapacityReservation -Times 0 -Exactly
        }
    }
    It 'a list of the group Azure did not give keeps the group, and says so' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:unavailable; s = $script:subId } {
            param($m, $s)
            Mock Get-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r'; VirtualMachinesAssociated = @() } } -ParameterFilter { $Name }
            Mock Get-AzCapacityReservation { Write-Error -Message $m } -ParameterFilter { -not $Name }
            $w = $null
            Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s -WarningVariable w -WarningAction SilentlyContinue
            Should -Invoke Remove-AzCapacityReservation -Times 1 -Exactly
            Should -Invoke Remove-AzCapacityReservationGroup -Times 0 -Exactly -Because 'a group Azure did not list may still hold a reservation'
            "$w" | Should -Match "Azure did not list the capacity reservations in the capacity reservation group 'vmf-crg', so the product keeps the group\."
        }
    }
    # MANUAL-REVIEW-1: the warning when Azure does not delete the empty group,
    # in Azure's names.
    It 'an empty group Azure does not delete is kept, and the warning says so in Azure''s names' {
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:subId } {
            param($s)
            Mock Get-AzCapacityReservation { [pscustomobject]@{ Id = '/g/r'; VirtualMachinesAssociated = @() } } -ParameterFilter { $Name }
            Mock Get-AzCapacityReservation { @() } -ParameterFilter { -not $Name }
            Mock Remove-AzCapacityReservationGroup { throw 'Conflict. ErrorCode: OperationNotAllowed' }
            $w = $null
            Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s -WarningVariable w -WarningAction SilentlyContinue
            Should -Invoke Remove-AzCapacityReservationGroup -Times 1 -Exactly
            "$w" | Should -Be "The capacity reservation group 'vmf-crg' is empty, but Azure did not delete it. The group costs nothing, and you can delete it. Azure said: Conflict. ErrorCode: OperationNotAllowed"
        }
    }
    It 'a group that is gone is not deleted again' {
        InModuleScope VmMigrationFactory -Parameters @{ m = $script:noParent; s = $script:subId } {
            param($m, $s)
            Mock Get-AzCapacityReservation { Write-Error -Message $m }
            Remove-VmfCapacityReservation -ResourceGroupName 'rg-app' -GroupName 'vmf-crg' -ReservationName 'd2ds_v6' -SubscriptionId $s
            Should -Invoke Remove-AzCapacityReservationGroup -Times 0 -Exactly
        }
    }
}

# MISSING-READ-2: the callers of Remove-VmfVmShell are gone. REBUILD-REMOVE-ENGINE-1
# removed the Path B move, its rollback and Remove-VmfFailedDefinition;
# REBUILD-REMOVE-RECOVER-1 removed the restore that rebuilt. No step deletes a
# definition, so a read Azure does not answer cannot be taken as one deleted.
