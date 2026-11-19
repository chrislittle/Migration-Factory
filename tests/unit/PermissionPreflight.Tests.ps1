#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERM-3: ask whether the identity CAN do the job BEFORE touching the machine.
#
# The PERM-1 drill hit a missing permission part-way through a Path B rebuild,
# after the shell had been deleted. The rebuild and the roll-back need the same
# rights, so the gap that broke the migration also broke the recovery meant to
# cover it - the disks survived, unattached, and nothing could put the machine
# back.
#
# PERM-1 proved the ROLE is complete. This file covers the other half: that the
# engine correctly reads what an identity actually holds. RBAC's wildcard and
# notActions semantics are exactly the kind of thing that looks right and
# quietly grants - or denies - the wrong thing, and either mistake is expensive:
# denying parks runs that would have worked, granting lets a machine be deleted
# by an identity that cannot rebuild it.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    # TEST-1: anything this file forgets to mock must fail as a TEST error,
    # not quietly reach real Azure. Placed before the file's own mocks so
    # those still win where they exist.
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }
}

Describe 'PERM-3: matching one action against one permission' {
    It 'matches an exact action' {
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/write' `
                -Actions @('Microsoft.Compute/virtualMachines/write') | Should -BeTrue
        }
    }

    It 'a wildcard crosses slashes - Microsoft.Compute/* covers everything beneath it' {
        # Treating * as "one segment" would report a fully privileged identity
        # as missing almost everything, and park every run in the fleet.
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/write' `
                -Actions @('Microsoft.Compute/*') | Should -BeTrue
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/extensions/write' `
                -Actions @('Microsoft.Compute/*') | Should -BeTrue
        }
    }

    It 'Owner - a bare * - grants everything' {
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/delete' -Actions @('*') | Should -BeTrue
        }
    }

    It 'a dot is a literal dot, not any character' {
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'MicrosoftXCompute/virtualMachines/write' `
                -Actions @('Microsoft.Compute/virtualMachines/write') | Should -BeFalse
        }
    }

    It 'a mid-pattern wildcard works' {
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/read' -Actions @('*/read') | Should -BeTrue
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/write' -Actions @('*/read') | Should -BeFalse
        }
    }

    It 'notActions subtract from what the same permission granted' {
        # This is how Contributor is built: * minus the authorization writes.
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Authorization/roleAssignments/write' `
                -Actions @('*') -NotActions @('Microsoft.Authorization/roleAssignments/write') | Should -BeFalse
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/write' `
                -Actions @('*') -NotActions @('Microsoft.Authorization/*') | Should -BeTrue
        }
    }

    It 'no actions grants nothing' {
        InModuleScope VmMigrationFactory {
            Test-VmfActionGranted -Action 'Microsoft.Compute/virtualMachines/read' -Actions @() | Should -BeFalse
        }
    }
}

Describe 'PERM-3: what is missing, across several role assignments' {
    It 'an action granted by ANY assignment is held' {
        InModuleScope VmMigrationFactory {
            $perms = @(
                [pscustomobject]@{ actions = @('Microsoft.Compute/virtualMachines/read'); notActions = @() },
                [pscustomobject]@{ actions = @('Microsoft.Compute/virtualMachines/write'); notActions = @() }
            )
            Get-VmfMissingActions -RequiredActions @(
                'Microsoft.Compute/virtualMachines/read',
                'Microsoft.Compute/virtualMachines/write') -Permissions $perms | Should -BeNullOrEmpty
        }
    }

    It 'notActions on one assignment do NOT subtract from another assignment' {
        # RBAC evaluates each assignment as a whole. Flattening every actions
        # and notActions list into two flat lists would deny an action a second,
        # narrower role legitimately grants - parking a run that would work.
        InModuleScope VmMigrationFactory {
            $perms = @(
                [pscustomobject]@{ actions = @('*'); notActions = @('Microsoft.Compute/virtualMachines/delete') },
                [pscustomobject]@{ actions = @('Microsoft.Compute/virtualMachines/delete'); notActions = @() }
            )
            Get-VmfMissingActions -RequiredActions @('Microsoft.Compute/virtualMachines/delete') `
                -Permissions $perms | Should -BeNullOrEmpty
        }
    }

    It 'reports exactly what is absent, so an operator can grant precisely that' {
        InModuleScope VmMigrationFactory {
            $perms = @([pscustomobject]@{ actions = @('Microsoft.Compute/virtualMachines/read'); notActions = @() })
            $missing = Get-VmfMissingActions -RequiredActions @(
                'Microsoft.Compute/virtualMachines/read',
                'Microsoft.Compute/virtualMachines/write',
                'Microsoft.Compute/virtualMachines/delete') -Permissions $perms
            @($missing) | Should -Be @('Microsoft.Compute/virtualMachines/delete', 'Microsoft.Compute/virtualMachines/write')
        }
    }

    It 'an identity holding NOTHING is missing everything, not silently fine' {
        InModuleScope VmMigrationFactory {
            @(Get-VmfMissingActions -RequiredActions @('Microsoft.Compute/virtualMachines/write') -Permissions @()).Count |
                Should -Be 1
            @(Get-VmfMissingActions -RequiredActions @('Microsoft.Compute/virtualMachines/write') -Permissions $null).Count |
                Should -Be 1
        }
    }
}

Describe 'PERM-3: the required set comes from the shipped role map' {
    It 'reads the real actions out of data/rbac-actions.json' {
        InModuleScope VmMigrationFactory {
            $required = Get-VmfRequiredActions
            @($required).Count | Should -BeGreaterThan 20
            $required | Should -Contain 'Microsoft.Compute/virtualMachines/write'
            # REBUILD-REMOVE-ROLE-1: no move deletes a machine, so the check no
            # longer asks for the delete; the join on the interfaces stays.
            $required | Should -Not -Contain 'Microsoft.Compute/virtualMachines/delete'
            $required | Should -Contain 'Microsoft.Network/networkInterfaces/join/action'
        }
    }

    It 'BGINFO-PERM-1: the map no longer requires extensions/write, for any role' {
        # PERM-1 (2026-08-26) saw New-AzVM demand extensions/write on a Windows
        # rebuild of a machine with BGInfo: New-AzVM installs BGInfo itself
        # unless the call says -DisableBginfoExtension. BGINFO-ADD-1 gives the
        # switch. BGINFO-PERM-1 MEASURED it on 2026-10-24, through the install,
        # with the role and the map both without the action: a Windows Path B
        # rebuild and a restore rebuild worked, and Azure refused nothing. A
        # permission the product does not need is one a security team refuses.
        InModuleScope VmMigrationFactory {
            Get-VmfRequiredActions | Should -Not -Contain 'Microsoft.Compute/virtualMachines/extensions/write'
            Get-VmfRequiredActions -Role @('migrate') | Should -Not -Contain 'Microsoft.Compute/virtualMachines/extensions/write'
        }
        $map = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        foreach ($op in @($map.operations)) {
            @($op.actions) | Should -Not -Contain 'Microsoft.Compute/virtualMachines/extensions/write' -Because "$($op.cmdlet) must not ask for it"
        }
    }

    It 'BGINFO-PERM-1: the lesson keeps the measurement; New-AzVM left the map with the rebuild' {
        # The lesson must give the measured result, not the reading that kept
        # the action ("most likely", "stays in the role"). The general lesson
        # stays: a call can demand permissions on resources the caller never
        # names, so an addition is a hypothesis until a drill.
        # REBUILD-REMOVE-ROLE-1: the New-AzVM entry, whose why held the
        # measurement, is gone - no remaining path creates a machine.
        $map = Get-Content (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json
        @($map.operations | Where-Object { $_.cmdlet -eq 'New-AzVM' }) | Should -BeNullOrEmpty
        $map.verificationLesson | Should -Match 'BGINFO-PERM-1'
        $map.verificationLesson | Should -Match '(?i)never mentions'
        $map.verificationLesson | Should -Not -Match '(?i)most likely'
        $map.verificationLesson | Should -Not -Match 'replays a captured config'
    }
    It 'assess alone is read-only - it cannot delete a machine' {
        InModuleScope VmMigrationFactory {
            Get-VmfRequiredActions -Role @('assess') | Should -Not -Contain 'Microsoft.Compute/virtualMachines/delete'
        }
    }

    It 'the VMF Migration role we ship satisfies its own check' {
        # If our own role does not pass, every customer following the docs parks
        # on their first machine.
        $dataFile = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json'
        InModuleScope VmMigrationFactory -Parameters @{ dataFile = $dataFile } {
            $map = Get-Content $dataFile -Raw | ConvertFrom-Json
            $granted = @(foreach ($op in $map.operations) { if ($op.role -in @('assess', 'execute')) { $op.actions } })
            $perms = @([pscustomobject]@{ actions = @($granted | Where-Object { $_ } | Sort-Object -Unique); notActions = @() })
            Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions) -Permissions $perms | Should -BeNullOrEmpty
        }
    }

    It 'so do Owner and Contributor, which is what most people will actually have' {
        InModuleScope VmMigrationFactory {
            $owner = @([pscustomobject]@{ actions = @('*'); notActions = @() })
            Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions) -Permissions $owner | Should -BeNullOrEmpty

            $contributor = @([pscustomobject]@{ actions = @('*'); notActions = @(
                'Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write',
                'Microsoft.Authorization/elevateAccess/Action') })
            Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions) -Permissions $contributor | Should -BeNullOrEmpty
        }
    }

    It 'SAFETY-3: the lock actions are optional - Contributor still passes, and -Optional names what it cannot do' {
        InModuleScope VmMigrationFactory {
            $required = Get-VmfRequiredActions
            $required | Should -Not -Contain 'Microsoft.Authorization/locks/write'
            $optional = Get-VmfRequiredActions -Optional
            $optional | Should -Contain 'Microsoft.Authorization/locks/write'
            $optional | Should -Contain 'Microsoft.Authorization/locks/delete'
            $contributor = @([pscustomobject]@{ actions = @('*'); notActions = @(
                'Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write',
                'Microsoft.Authorization/elevateAccess/Action') })
            @(Get-VmfMissingActions -RequiredActions $optional -Permissions $contributor).Count | Should -Be 2
            $owner = @([pscustomobject]@{ actions = @('*'); notActions = @() })
            Get-VmfMissingActions -RequiredActions $optional -Permissions $owner | Should -BeNullOrEmpty
        }
    }

    It 'Reader does NOT - it can plan, and must not be allowed to start' {
        InModuleScope VmMigrationFactory {
            $reader = @([pscustomobject]@{ actions = @('*/read'); notActions = @() })
            $missing = Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions) -Permissions $reader
            @($missing).Count | Should -BeGreaterThan 0
            $missing | Should -Contain 'Microsoft.Compute/virtualMachines/write'
        }
    }
}

Describe 'PERM-3: the message an operator has to act on' {
    It 'names the missing actions rather than saying "insufficient permissions"' {
        InModuleScope VmMigrationFactory {
            $m = Format-VmfMissingActionsMessage -Missing @('Microsoft.Compute/virtualMachines/delete') `
                -Scope '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app01'
            $m | Should -Match 'Microsoft.Compute/virtualMachines/delete'
            $m | Should -Match 'app01'
            $m | Should -Match '(?i)VMF Migration role'
        }
    }

    It 'says why the check exists, because the failure it prevents is not obvious' {
        InModuleScope VmMigrationFactory {
            $m = Format-VmfMissingActionsMessage -Missing @('a', 'b')
            $m | Should -Match '(?i)rollback'
            $m | Should -Match '(?i)stopped before it changed the machine'
        }
    }
}

Describe 'PERM-3: PRECHECK refuses before it touches anything' {
    BeforeAll {
        $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
    }

    It 'the check is in PRECHECK' {
        $script:sm | Should -Match 'permissionsCheck'
        $script:sm | Should -Match 'Get-VmfMissingActions'
    }

    It 'parks rather than failing, so the machine is recoverable by an operator' {
        $script:sm | Should -Match "(?s)Get-VmfMissingActions.{0,400}Next = 'NEEDS_DECISION'"
    }

    It 'and asks BEFORE the first thing that changes the machine' {
        # The whole value is the ordering: after the shell is deleted, knowing
        # the identity cannot rebuild it is worthless.
        $precheckStart = $script:sm.IndexOf('function Invoke-VmfStepPrecheck')
        $permCheck = $script:sm.IndexOf('permissionsCheck', $precheckStart)
        $capture = $script:sm.IndexOf("Invoke-VmfAzOperation -Name 'getVm'", $precheckStart)
        $permCheck | Should -BeGreaterThan 0
        $permCheck | Should -BeLessThan $capture -Because 'the answer is only free while nothing has been touched'
    }

    It 'asks at the machine own scope, so inherited grants count' {
        # A role assigned at the subscription or management group applies to the
        # VM. Asking at the subscription instead would miss grants made directly
        # on the resource group, and vice versa.
        $script:sm | Should -Match 'Get-VmfEffectivePermissions -Scope \$Context\.VmId'
    }
}

Describe 'PERM-3: reading effective permissions stays behind the azureops boundary' {
    It 'the ARM call lives in azureops, not in the engine' {
        $ops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsRbac.ps1') -Raw
        $ops | Should -Match 'Invoke-AzRestMethod'
        $ops | Should -Match 'Microsoft.Authorization/permissions'
    }

    It 'and it refuses to guess when Azure will not answer' {
        # Treating an unreadable answer as "no permissions" would park the whole
        # fleet on a transient error; treating it as "fine" would defeat the
        # check entirely. It throws, and the step retries.
        $ops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsRbac.ps1') -Raw
        $ops | Should -Match 'throw "Could not read effective permissions'
    }
}
