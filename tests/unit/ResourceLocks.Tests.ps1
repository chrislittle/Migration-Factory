#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# LOCK-1: a resource lock has to be found before the machine is touched, and
# judged against what the move does.
#
# The defect this closes was found by reading the code while building RETRY-1,
# not by a failure: nothing anywhere looked for locks. A CanNotDelete lock let a
# Windows machine run all the way to the point where the rebuild (Path B, removed
# 2026-11-07) deleted its shell and fail THERE - inside the deallocated window,
# past the point of no return.
#
# The tempting fix is "stop on any lock", and it would be wrong. A delete lock
# does not refuse a resize or a disk swap, and refusing a resize because
# someone locked the resource group is a refusal with no cause behind it. So
# the verdict is pure logic with the whole matrix asserted.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    # CLUSTER-DETECT-1: the cluster check at Checking is not under test here;
    # ClusterDetect.Tests.ps1 and StateMachine.Tests.ps1 test it.
    Mock -ModuleName VmMigrationFactory Get-VmfWorkloadCheckStop { $null }

    function Script:Lock($name, $level, $scope = 'the resource group') {
        [pscustomobject]@{ name = $name; level = $level; scope = $scope }
    }
    function Script:Verdict($locks) {
        InModuleScope VmMigrationFactory -Parameters @{ l = $locks } {
            Get-VmfLockVerdict -Locks $l
        }
    }
}

Describe 'LOCK-1: the verdict weighs lock TYPE against what the move does' {
    # REBUILD-REMOVE-LEFTOVERS-1: the verdict took the path, because a
    # CanNotDelete lock stopped the removed rebuild. Every move is in place now,
    # so it takes none.
    It 'no locks is clear' {
        (Script:Verdict @()).Blocked | Should -BeFalse
        (Script:Verdict $null).Blocked | Should -BeFalse
    }

    It 'ReadOnly blocks the move - nothing this tool does is a read' {
        $v = Script:Verdict @(Script:Lock 'prod-guard' 'ReadOnly')
        $v.Blocked | Should -BeTrue -Because 'a ReadOnly lock blocks deallocate, resize and disk changes'
        $v.Detail | Should -Match 'prod-guard'
    }

    It 'CanNotDelete does NOT stop the move - a resize and a disk swap are not deletes' {
        # The whole reason this is a verdict and not a presence check. A move
        # resizes in place, and its rollback swaps on disks made from the
        # copies. (Its cleanup of unused disks is refused under the lock:
        # CANNOTDELETE-RESTORE-1.)
        $v = Script:Verdict @(Script:Lock 'no-delete' 'CanNotDelete')
        $v.Blocked | Should -BeFalse
        $v.Detail | Should -Match 'no-delete' -Because 'an operator should still be told the lock is there'
        $v.Detail | Should -Match 'do not stop the move'
    }

    # CANNOTDELETE-RESTORE-1: the lock does not stop the move, but it refuses
    # the cleanup of the rollback disks - and those bill.
    It 'CANNOTDELETE-RESTORE-1: a CanNotDelete lock on the resource group says that the rollback disks are not deleted after the move' {
        $v = Script:Verdict @(Script:Lock 'no-delete' 'CanNotDelete')
        $v.Blocked | Should -BeFalse
        $v.Detail | Should -BeLike '*A CanNotDelete lock on the resource group prevents the delete of the rollback disks after the move. Each one costs money until it is deleted.'
    }

    It 'CANNOTDELETE-RESTORE-1: a CanNotDelete lock on this machine only does not say so - it covers no disk' {
        $v = Script:Verdict @(Script:Lock 'vm-keep' 'CanNotDelete' 'this machine')
        $v.Blocked | Should -BeFalse
        $v.Detail | Should -Match 'vm-keep'
        $v.Detail | Should -Not -Match 'way back'
    }

    It 'a blocking lock among harmless ones still blocks' {
        $v = Script:Verdict @(
            (Script:Lock 'no-delete' 'CanNotDelete'),
            (Script:Lock 'prod-guard' 'ReadOnly'))
        $v.Blocked | Should -BeTrue
        $v.Detail | Should -Match 'prod-guard'
        $v.Detail | Should -Not -Match 'no-delete' -Because 'naming a lock that is not the problem sends someone to remove the wrong one'
    }

    It 'the message names the lock and where it sits' {
        $v = Script:Verdict @(Script:Lock 'vm-hold' 'ReadOnly' 'this machine')
        $v.Detail | Should -Match 'vm-hold'
        $v.Detail | Should -Match 'this machine'
    }
}
Describe 'LOCK-1: which locks are read as covering the machine' {
    # These used to assert the FUNCTION'S SOURCE TEXT - that it contained the
    # word "inherit", a variable named onAnotherResource, and a level list. All
    # three passed while the filter silently dropped every resource-group lock,
    # which is the placement the gate exists for (EVAL-C2). The behaviour is now
    # covered properly in LockScope.Tests.ps1, against real lock ids; what is
    # left here is the one structural fact worth pinning: the fetch reads at the
    # GROUP, because a lock on the group covers the machine.
    BeforeAll {
        $script:azops = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'azureops' 'AzureOpsVm.ps1') -Raw
    }

    It 'reads at the RESOURCE GROUP, because locks inherit downward' {
        $fn = [regex]::Match($script:azops, '(?s)function Get-VmfVmResourceLocks.*?
\}').Value
        $fn | Should -Match 'Get-AzResourceLock -ResourceGroupName'
        $fn | Should -Match 'inherit'
    }

    It 'the fetch decides nothing - the decision is a pure function that is tested with real lock ids' {
        $fn = [regex]::Match($script:azops, '(?s)function Get-VmfVmResourceLocks.*?
\}').Value
        $fn | Should -Match 'Select-VmfCoveringLocks'
        $fn | Should -Not -Match 'onAnotherResource' -Because 'that predicate was the defect; it must not come back here'
    }
}

Describe 'LOCK-1: the engine stops before anything is touched' {
    BeforeAll {
        $script:sm = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1') -Raw
        $script:precheck = [regex]::Match($script:sm, '(?s)function Invoke-VmfStepPrecheck.*?\n\}').Value
    }

    It 'the check lives in PRECHECK, where a refusal is free' {
        $script:precheck | Should -Match 'Get-VmfVmResourceLocks'
        $script:precheck | Should -Match 'Get-VmfLockVerdict'
    }

    It 'and stops with the reason code that already has guidance' {
        $script:precheck | Should -Match ([regex]::Escape("Reason = [string]`$lockVerdict.Reason"))
        $table = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
        $r = @($table.reasons | Where-Object code -eq 'resourceLocked')[0]
        $r | Should -Not -BeNullOrEmpty
        $r.machine | Should -Be 'untouched' -Because 'the whole point is catching it before anything moves'
        $r.retry | Should -Be 'afterFix'
    }

    It 'runs BEFORE the machine is stopped, not after' {
        # A lock check that runs after the deallocation would find the problem
        # in exactly the place this exists to avoid.
        $idxLock = $script:precheck.IndexOf('Get-VmfLockVerdict')
        $idxLock | Should -BeGreaterThan 0
        $script:sm.IndexOf('Invoke-VmfStepStopped') | Should -BeGreaterThan `
            ($script:sm.IndexOf('Get-VmfLockVerdict')) -Because 'precheck precedes every mutating step'
    }

    It 'a lock that does not block is reported, not silently swallowed' {
        $script:precheck | Should -Match 'if \(\$lockVerdict\.Detail\)'
        $script:precheck | Should -Match "Outcome info"
    }
}
