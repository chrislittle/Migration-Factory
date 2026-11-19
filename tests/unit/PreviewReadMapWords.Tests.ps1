#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PREVIEW-READ-MAP-WORDS-1: what the permission map says about the read of
# the preview feature VMTempDiskResizePreview.
#
# THE DEFECT. The why of Microsoft.Features/providers/features/read in
# src/VmMigrationFactory/data/rbac-actions.json said two things that stopped
# being true:
#   - that the read was "Not yet measured on the role alone" - the lab of
#     2026-11-08 measured it through the installed app with the VMF roles
#     alone, granted at the subscription (TEMP-DISK-PREVIEW-ROLE-1, passed);
#   - that without the feature the move is one "which otherwise only a
#     rebuild reaches" - the rebuild was removed on 2026-11-07
#     (REBUILD-REMOVE-1). Without the feature Azure refuses the resize, and
#     the targets step does not let a person choose the in-place upgrade
#     (Preview) for the machine.
#
# The map is the file the permissions page of the manual is built from, and
# the record of why each action is in the roles; a why that is not true is a
# false statement about the product's access.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $map = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json') -Raw | ConvertFrom-Json -Depth 20
    $script:ops = @($map.operations | Where-Object { @($_.actions) -contains 'Microsoft.Features/providers/features/read' })
    $script:why = @($script:ops | ForEach-Object { [string]$_.why }) -join ' '
}

Describe 'PREVIEW-READ-MAP-WORDS-1: the map states the measured read and no rebuild' {
    It 'one operation holds the read, and it has a why' {
        $script:ops.Count | Should -Be 1
        $script:why | Should -Not -BeNullOrEmpty
    }
    It 'the why no longer says the read is not measured on the role alone' {
        $script:why | Should -Not -Match '(?i)not yet measured'
    }
    It 'the why says the 2026-11-08 lab measured the read on the VMF roles alone, at the subscription' {
        $script:why | Should -Match 'TEMP-DISK-PREVIEW-ROLE-1, MEASURED 2026-11-08'
        $script:why | Should -Match 'with the VMF roles alone, granted at the subscription'
        $script:why | Should -Match 'read VMTempDiskResizePreview as Registered'
    }
    It 'the why names no rebuild: the rebuild is removed, so no move reaches the target that way' {
        $script:why | Should -Not -Match '(?i)rebuild'
        $script:why | Should -Not -Match '(?i)path b'
    }
    It 'the why says what happens without the feature: Azure refuses the resize, and the Preview cannot be chosen' {
        $script:why | Should -Match 'Without the feature, Azure refuses that resize'
        $script:why | Should -Match 'the targets step does not let a person choose the in-place upgrade \(Preview\) for the machine'
    }
}
