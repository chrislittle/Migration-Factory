#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RESTORE-DIALOG-WORDS-1, 2026-10-25: the audit of every restore and rollback
# word, the engine side. A read of the code found sentences that were false
# against what the engine does:
#   - "so the restore itself can be undone": the product has no action that
#     puts the earlier disks back, and from the first copy putting them back
#     would change the size and the disk controller again - a second migration.
#   - "the copies become the only versions left" / "the snapshot remains the
#     only copy": the safety copies are then the only copies, and the daily
#     cleanup deletes them when the retention of the wave ends.
#   - "downstream references are unaffected": the new disk has the name and
#     resource id of the earlier disk; its tags, role assignments and backup
#     are not copied.
#   - "The disk it had stays on the machine, and the new disk is kept": the
#     caller says what happens to each disk (a put-back stops before it changes
#     the machine and names each disk it made), so the fixed sentence goes.
#   - "come back from the first safety copy": both copies call that check.
#   - "room for two": an invented word (QUOTA-NOT-CAPACITY-1).
#   - "the tool locks every copy when it takes it": only when its identity has
#     the right to place locks.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:engine = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:restoreCode = Get-VmfCodeOnly -Path (Join-Path $script:engine 'Public' 'Restore-VmfVm.ps1')
    $script:safetyCode = Get-VmfCodeOnly -Path (Join-Path $script:engine 'Private' 'engine' 'SafetyAllDisks.ps1')
    $script:stops = Get-Content (Join-Path $script:engine 'data' 'stop-reasons.json') -Raw | ConvertFrom-Json
}

Describe 'RESTORE-DIALOG-WORDS-1: the help of Restore-VmfVm says what a restore does' {
    BeforeAll {
        $script:help = (Get-Help Restore-VmfVm -Full | Out-String) -replace '\s+', ' '
    }
    It 'reads the help it checks' {
        $script:help | Should -Match 'THE DISK IDENTITY PROBLEM' -Because 'the help was read'
    }
    It 'promises no undo, and says the current disk is kept, detached' {
        $script:help | Should -Not -Match 'can be undone'
        $script:help | Should -Match 'KEPT, detached'
    }
    It 'says what happens to the safety copies when the names are kept' {
        $script:help | Should -Not -Match 'the snapshot remains the only copy'
        $script:help | Should -Match 'daily cleanup deletes them when the retention of the wave ends'
    }
    It 'says what does not come back with the name' {
        $script:help | Should -Not -Match 'downstream references keep working'
        $script:help | Should -Match 'tags, role assignments and backup'
    }
}

Describe 'RESTORE-DIALOG-WORDS-1: the words of the engine' {
    It 'the restore that keeps the names says the safety copies are the only copies until the cleanup' {
        $script:restoreCode | Should -Not -Match 'only versions'
        $script:restoreCode | Should -Not -Match 'only remaining copies'
        # MANUAL-REVIEW-1: the refusal is a guard the page never reaches (it sends the
        # acceptance), so only the warning says it now.
        @([regex]::Matches($script:restoreCode, 'daily cleanup deletes them when the retention of the wave ends')).Count | Should -Be 1 -Because 'the warning says it'
    }
    It 'the end of a restore that kept the names says what was not copied' {
        $script:restoreCode | Should -Not -Match 'downstream references are unaffected'
        $script:restoreCode | Should -Match 'has the name and resource ID of the earlier disk'
        $script:restoreCode | Should -Match 'The restore did not copy its tags, role assignments or backup'
    }
    It 'a disk made from a copy that is not used says only why - the caller says what happens to each disk' {
        $script:safetyCode | Should -Not -Match 'The disk it had stays on the machine, and the new disk is kept'
    }
    It 'the check that every data disk comes back names the safety copy, not the first one - both copies call it' {
        $err = InModuleScope VmMigrationFactory {
            try { Assert-VmfDataDisksAllBack -Kept @([pscustomobject]@{ lun = 2; name = 'vm1-d2'; refused = $true; why = 'Azure did not make it.' }); '' }
            catch { $_.Exception.Message }
        }
        $err | Should -Be "A data disk cannot be made from the safety copy: 'vm1-d2' on LUN 2 (Azure did not make it). Every disk is restored from its copy, or the product changes nothing."
    }
}

Describe 'RESTORE-DIALOG-WORDS-1: the stop reasons' {
    It 'a failed rollback names the disks it detached and the safety copies taken before the product changed the machine' {
        $r = @($script:stops.reasons | Where-Object code -eq 'rollbackFailed')[0]
        $r.meaning | Should -Not -Match 'replaced'
        $r.meaning | Should -Not -Match 'copies taken before the run'
        # The approved meaning, 2026-11-13 (MANUAL-REVIEW-1).
        $r.meaning | Should -Match 'Its safety copies and its old disks still exist\.'
        $r.whatToDo | Should -Match 'Before the migration' -Because 'the dialog names that copy so'
    }
    It 'a missing safety copy does not say every copy is locked' {
        $r = @($script:stops.reasons | Where-Object code -eq 'safetyCopyMissing')[0]
        $r.meaning | Should -Not -Match 'locks every copy'
        $r.meaning | Should -Match 'if its identity has the right to place locks'
    }
    It 'the disk type change limit says a move needs both changes, in the words of the Safety copies page' {
        $r = @($script:stops.reasons | Where-Object code -eq 'diskTypeChangeLimit')[0]
        $r.meaning | Should -Not -Match '(?i)\broom\b'
        $r.meaning | Should -Match ([regex]::Escape('A move needs both of them: its own change, and the change back if the move fails.'))
    }
    It 'the encryption reason does not say the rollback replaces a disk' {
        @($script:stops.reasons | Where-Object code -eq 'diskEncryptionNotKnown')[0].meaning | Should -Not -Match 'replace'
    }
}
