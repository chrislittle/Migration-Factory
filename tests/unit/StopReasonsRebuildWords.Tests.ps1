#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STOP-REASONS-REBUILD-WORDS-1 - two stop reasons a machine of this version can
# reach still said the product rebuilds a machine. No move rebuilds a machine
# since REBUILD-REMOVE-1 (2026-11-07). Decided 2026-11-11: change only those two
# (resourceLocked, diskTypeNotKnown); the reasons that only an older version's
# plan reaches go with the old-version readers (OLD-VERSION-READERS-REMOVE-1).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:reasons = (Get-Content -Raw -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'stop-reasons.json') | ConvertFrom-Json).reasons
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:diskTypeCode = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'DiskTypeKnown.ps1')
}

Describe 'STOP-REASONS-REBUILD-WORDS-1: reachable stop reasons do not say rebuild' {
    It 'the reason <_> has no rebuild in its words' -ForEach @('resourceLocked', 'diskTypeNotKnown') {
        $r = @($script:reasons | Where-Object code -eq $_)
        $r.Count | Should -Be 1
        ($r[0].title, $r[0].meaning, $r[0].whatToDo) -join ' ' | Should -Not -Match '(?i)rebuil'
    }
    It 'the ReadOnly lock reason says the product cannot stop or resize the machine' {
        ($script:reasons | Where-Object code -eq 'resourceLocked').meaning | Should -Match 'cannot stop or resize the machine\.'
    }
    It 'the disk type stop Detail written by the engine has no rebuild' {
        $script:diskTypeCode | Should -Match 'diskTypeNotKnown'
        $script:diskTypeCode | Should -Not -Match '(?i)rebuil'
    }
}
