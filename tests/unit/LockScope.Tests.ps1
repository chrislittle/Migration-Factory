#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# EVAL-C2 and EVAL-M7, from the 2026-08-28 self-evaluation.
#
# C2: the VM lock filter tested the lock's OWN resource id, which always ends
# /providers/Microsoft.Authorization/locks/<name> - so a RESOURCE-GROUP lock
# always satisfied "this lock is on another resource" and was dropped. That is
# the most common placement in an enterprise estate, so the LOCK-1 gate was
# inert exactly where it mattered: the machine sailed through the precheck and
# died at Remove-AzVM INSIDE the deallocated window, where the rollback fails
# the same way.
#
# M7: the sibling had the opposite error - it treated every lock with no /disks/
# segment as blocking, including locks on unrelated resources, sending an
# operator mid-incident to remove a CanNotDelete lock from somebody else's
# production asset.
#
# The old tests could not have caught either: they matched the functions' own
# source text (one asserted the word "inherit" appears). These feed real lock
# ids through the real functions.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:RG = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-apps'

    function Script:Lock([string]$name, [string]$level, [string]$onResource) {
        # A lock's own id is <scope>/providers/Microsoft.Authorization/locks/<name>,
        # where <scope> is the group or a resource inside it. This is the shape
        # the whole defect turned on.
        $scope = if ($onResource) { "$script:RG/$onResource" } else { $script:RG }
        [pscustomobject]@{
            Name       = $name
            ResourceId = "$scope/providers/Microsoft.Authorization/locks/$name"
            Properties = [pscustomobject]@{ level = $level }
        }
    }
}

Describe 'EVAL-C2: which locks cover a virtual machine' {

    It 'a RESOURCE-GROUP lock covers the machine - the case that was silently dropped' {
        $locks = @(Script:Lock 'group-guard' 'CanNotDelete' $null)
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            $found = Select-VmfCoveringLocks -Locks $locks -VmName 'vm1'
            @($found).Count | Should -Be 1 -Because 'a group lock stops the delete as surely as one on the machine'
            @($found)[0].scope | Should -Be 'the resource group'
            @($found)[0].level | Should -Be 'CanNotDelete'
        }
    }

    It 'a lock on THIS machine covers it' {
        $locks = @(Script:Lock 'vm-guard' 'CanNotDelete' 'providers/Microsoft.Compute/virtualMachines/vm1')
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            $found = Select-VmfCoveringLocks -Locks $locks -VmName 'vm1'
            @($found).Count | Should -Be 1
            @($found)[0].scope | Should -Be 'this machine'
        }
    }

    It 'a lock on ANOTHER machine does not' {
        $locks = @(Script:Lock 'other-vm' 'CanNotDelete' 'providers/Microsoft.Compute/virtualMachines/vm2')
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfCoveringLocks -Locks $locks -VmName 'vm1').Count | Should -Be 0
        }
    }

    It 'a lock on an unrelated resource in the same group does not' {
        $locks = @(Script:Lock 'sa-guard' 'CanNotDelete' 'providers/Microsoft.Storage/storageAccounts/sa1')
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfCoveringLocks -Locks $locks -VmName 'vm1').Count | Should -Be 0
        }
    }

    It 'a machine whose name is a prefix of another machine is not confused with it' {
        $locks = @(Script:Lock 'other' 'CanNotDelete' 'providers/Microsoft.Compute/virtualMachines/vm10')
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfCoveringLocks -Locks $locks -VmName 'vm1').Count | Should -Be 0
        }
    }

    It 'levels other than CanNotDelete and ReadOnly are ignored' {
        $locks = @(Script:Lock 'note' 'NotSpecified' $null)
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfCoveringLocks -Locks $locks -VmName 'vm1').Count | Should -Be 0
        }
    }

    It 'reports every covering lock when a group lock and a machine lock are both present' {
        $locks = @(
            (Script:Lock 'group-guard' 'CanNotDelete' $null),
            (Script:Lock 'vm-guard' 'ReadOnly' 'providers/Microsoft.Compute/virtualMachines/vm1'),
            (Script:Lock 'other-vm' 'CanNotDelete' 'providers/Microsoft.Compute/virtualMachines/vm2')
        )
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            $found = Select-VmfCoveringLocks -Locks $locks -VmName 'vm1'
            @($found).Count | Should -Be 2
            @($found.scope) | Should -Contain 'the resource group'
            @($found.scope) | Should -Contain 'this machine'
        }
    }
}

Describe 'EVAL-M7: which locks actually block deleting a disk' {

    It 'a group lock blocks it' {
        $locks = @(Script:Lock 'group-guard' 'CanNotDelete' $null)
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfDeleteBlockingLocks -Locks $locks -DiskName 'vm1_osdisk').Count | Should -Be 1
        }
    }

    It 'a lock on THIS disk blocks it' {
        $locks = @(Script:Lock 'disk-guard' 'CanNotDelete' 'providers/Microsoft.Compute/disks/vm1_osdisk')
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfDeleteBlockingLocks -Locks $locks -DiskName 'vm1_osdisk').Count | Should -Be 1
        }
    }

    It 'a lock on another disk does not' {
        $locks = @(Script:Lock 'other-disk' 'CanNotDelete' 'providers/Microsoft.Compute/disks/other_osdisk')
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfDeleteBlockingLocks -Locks $locks -DiskName 'vm1_osdisk').Count | Should -Be 0
        }
    }

    It 'a lock on an unrelated resource does NOT block it - the operator must not be sent to the wrong asset' {
        # This is EVAL-M7: a storage account lock has no /disks/ segment, so the
        # old test "is this not a disk lock?" called it blocking.
        $locks = @(
            (Script:Lock 'sa-guard' 'CanNotDelete' 'providers/Microsoft.Storage/storageAccounts/sa1'),
            (Script:Lock 'nic-guard' 'CanNotDelete' 'providers/Microsoft.Network/networkInterfaces/vm1-nic'),
            (Script:Lock 'other-vm' 'CanNotDelete' 'providers/Microsoft.Compute/virtualMachines/vm2')
        )
        InModuleScope VmMigrationFactory -Parameters @{ locks = $locks } {
            (Select-VmfDeleteBlockingLocks -Locks $locks -DiskName 'vm1_osdisk').Count | Should -Be 0 `
                -Because 'naming a lock that is not the problem sends someone to remove the wrong one'
        }
    }
}

Describe 'EVAL-C2/M7: both functions share one scope parser, so they cannot drift apart' {
    # The report named the best predictor of a defect in this codebase: "the
    # analogous case, one function over". These two functions had opposite bugs
    # in the same twenty lines. Now there is one answer to "what does this lock
    # cover", and both ask it.
    It 'reads the lock scope, not the lock id' {
        InModuleScope VmMigrationFactory {
            $group = Get-VmfLockScope -LockResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Authorization/locks/x'
            $group.Kind | Should -Be 'group'

            $vm = Get-VmfLockScope -LockResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1/providers/Microsoft.Authorization/locks/x'
            $vm.Kind | Should -Be 'resource'
            $vm.ResourceType | Should -Be 'virtualMachines'
            $vm.ResourceName | Should -Be 'vm1'

            $disk = Get-VmfLockScope -LockResourceId '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/d1/providers/Microsoft.Authorization/locks/x'
            $disk.ResourceType | Should -Be 'disks'
            $disk.ResourceName | Should -Be 'd1'
        }
    }

    It 'an id it cannot parse is treated as covering, never as harmless' {
        # Unknown must never resolve in the direction that lets a delete proceed
        # into the deallocated window.
        InModuleScope VmMigrationFactory {
            (Get-VmfLockScope -LockResourceId 'something-unexpected').Kind | Should -Be 'group'
        }
    }

    It 'both lock functions call it' {
        $azops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
        foreach ($fn in 'Select-VmfCoveringLocks', 'Select-VmfDeleteBlockingLocks') {
            $body = [regex]::Match($azops, "(?s)function $fn.*?\n\}").Value
            $body | Should -Match 'Get-VmfLockScope' -Because "$fn must not carry its own idea of lock scope"
        }
    }
}
