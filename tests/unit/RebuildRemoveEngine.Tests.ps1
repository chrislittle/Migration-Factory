#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# REBUILD-REMOVE-ENGINE-1: the state machine has no rebuild around the same
# disks (Path B) any more - not in the move, not in the rollback.
#
# OLD-VERSION-READERS-REMOVE-1 (2026-11-11: no install runs an earlier
# version): the stop of a machine an earlier version started to rebuild
# (oldRebuildNotResumed, Get-VmfOldRebuildResume) and the refusals of a path
# other than A in CONVERTING and the rollback are gone too. Nothing is public
# before 1.0, so no store holds such a machine, and a wave runs only path A.
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:smPath = Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'Private' 'engine' 'StateMachine.ps1'
}

Describe 'REBUILD-REMOVE-ENGINE-1: no rebuild in the move or the rollback' {
    Context 'The Path B steps are gone from the move and the rollback' {
        It 'no stop and no refusal is left for a machine an earlier version started to rebuild' {
            InModuleScope VmMigrationFactory { Get-Command Get-VmfOldRebuildResume -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
            $code = Get-VmfCodeOnly -Path $script:smPath
            $code | Should -Not -Match 'oldRebuildNotResumed'
            $code | Should -Not -Match 'does not rebuild a machine' -Because 'CONVERTING and the rollback no longer refuse a path other than A'
        }
        It 'the state machine calls none of the rebuild operations and writes no Path B checkpoint' {
            $code = Get-VmfCodeOnly -Path $script:smPath
            foreach ($gone in 'Remove-VmfVmShell', 'New-VmfVmFromCapture', 'Set-VmfDeleteOptionsDetach', 'Invoke-VmfRebuildPatchSettings',
                'Invoke-VmfRebuildInReservationGroup', 'Write-VmfIdentityDeletedLine', 'Write-VmfRebuildFollowUpLine',
                'Get-VmfAcceptedIdentityLoss', 'Get-VmfStartedPath', 'Remove-VmfClaimAssociation') {
                $code | Should -Not -Match ([regex]::Escape($gone)) -Because "$gone was a Path B step"
            }
            $code | Should -Not -Match "-Checkpoint 'B:" -Because 'no Path B checkpoint is written'
            $code | Should -Not -Match "requiredFor \+= 'rebuild'"
            $code | Should -Not -Match 'expected on Path B'
        }

        It 'the helpers only the Path B steps used are gone' {
            foreach ($gone in 'Get-VmfAcceptedIdentityLoss', 'Write-VmfRebuildFollowUpLine', 'Get-VmfStartedPath',
                'Test-VmfCaptureReproducible', 'Test-VmfIdentityReproducible', 'Get-VmfCaptureFieldPolicy', 'Get-VmfMoveRefusedSettings',
                # Their last other callers went with REBUILD-REMOVE-RECOVER-1.
                'Invoke-VmfRebuildInReservationGroup', 'Remove-VmfFailedDefinition') {
                InModuleScope VmMigrationFactory -Parameters @{ n = $gone } { Get-Command $n -ErrorAction SilentlyContinue } |
                    Should -BeNullOrEmpty -Because "$gone served only the rebuild"
            }
        }

        It 'Verifying holds every machine to the identity it had: a new object ID fails, and no acceptance excuses it' {
            InModuleScope VmMigrationFactory {
                (Get-Command Test-VmfRebuildFidelity).Parameters.ContainsKey('AcceptedLossPrincipalId') | Should -BeFalse
                $cap = [pscustomobject]@{ identity = [pscustomobject]@{ type = 'SystemAssigned'; principalId = '11111111-1111-1111-1111-111111111111' }; identityType = 'SystemAssigned' }
                $live = [pscustomobject]@{ identityType = 'SystemAssigned'; identityPrincipalId = '22222222-2222-2222-2222-222222222222' }
                $r = Test-VmfRebuildFidelity -Captured $cap -Live $live
                $r.Ok | Should -BeFalse
                $r.Verdict | Should -Be 'MISMATCH'
            }
        }

        It 'Verifying compares the patch settings as they were on every move: no rebuilt variant' {
            InModuleScope VmMigrationFactory {
                (Get-Command Test-VmfRebuildSettingsFidelity).Parameters.ContainsKey('Rebuilt') | Should -BeFalse
            }
        }

        It 'the put-back fit question has no Path B variant' {
            InModuleScope VmMigrationFactory {
                (Get-Command Get-VmfPutBackFitQuestion).Parameters.ContainsKey('Path') | Should -BeFalse
            }
        }
    }
}
