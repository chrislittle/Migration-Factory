#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-REBUILD-RESTORE-READERS-1: no restore, job, lease, record, report, page
# or contract reads a rebuild that an earlier version made.
#
# The rebuild around the same disks is removed, and no flow of this version
# writes its records: no putBackJob of kind rebuild (New-VmfPutBackJob is
# called with restore and finish only), no lease holder rebuild:, no recovery
# or recoveryDisks, no restore.rebuilt that can be true, no step recovery, no
# path B. Nothing is public before 1.0, so no store holds one. The readers,
# their words and their contract fields go: vm-state v45, migration-record and
# run-status drop the reason rebuilt.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    function Global:OrrSchema([string]$Name) {
        [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' $Name)) | ConvertFrom-Json -AsHashtable -Depth 40
    }
    $script:codeFiles = @(
        @(Get-ChildItem -Path $script:moduleRoot -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'facade') -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.js' | Where-Object { $_.Name -notlike '*.min.js' })
    )
    function Global:OrrCodeMatching([string]$Pattern) {
        foreach ($f in $script:codeFiles) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -cmatch $Pattern) { $f.FullName.Substring($script:repoRoot.Length + 1) }
        }
    }
}
AfterAll { Remove-Item function:OrrSchema, function:OrrCodeMatching -ErrorAction SilentlyContinue }

Describe 'OLD-REBUILD-RESTORE-READERS-1: the engine reads no record of a rebuild' {
    It 'no code reads recovery, recoveredUtc or recoveryDisks' {
        @(OrrCodeMatching "recoveredUtc|recoveryDisks|'recovery'|\.recovery\b") | Should -BeNullOrEmpty
    }

    It 'no code names a job, a lease or a step of a rebuild' {
        @(OrrCodeMatching "'rebuild'|'rebuild:|rebuild:\*|'recover'|'rebuilt'|Rebuild this machine|rebuildRead|shellDeleted|renameStopped") | Should -BeNullOrEmpty
    }

    It 'the restore asks no refusal of a rebuild, and reads no plan path for one' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfRestoreOldRebuildRefusal -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
        $code = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Public' 'Restore-VmfVm.ps1')
        $code | Should -Not -Match 'oldRebuild|planPath'
    }

    It 'a restore job resumes from the steps of a restore only' {
        $phases = InModuleScope VmMigrationFactory { $script:VmfPutBackJobPhases }
        foreach ($p in 'rebuildRead', 'shellDeleted', 'rebuilt', 'renameStopped') { $phases | Should -Not -Contain $p }
        $phases | Should -Contain 'osOnTemp'
        { InModuleScope VmMigrationFactory { Test-VmfPutBackJobPast -Job ([pscustomobject]@{ kind = 'restore'; phase = 'shellDeleted' }) -Phase 'made' } } |
            Should -Throw '*does not know*'
    }

    It 'a job record is said as Restore this machine or a finish, never as a rebuild' {
        InModuleScope VmMigrationFactory {
            Get-VmfPutBackJobWords -Job ([pscustomobject]@{ kind = 'restore' }) | Should -Be 'Restore this machine'
            Get-VmfLeaseHolderWords -Lease ([pscustomobject]@{ workerId = 'rebuild:op-1' }) | Should -Be 'held by a worker'
            Test-VmfPutBackLeaseHolder -WorkerId 'rebuild:op-1' | Should -BeFalse
            Test-VmfPutBackLeaseHolder -WorkerId 'restore:op-1' | Should -BeTrue
        }
    }

    It 'the made-disk lists are the rollback''s and the restore''s' {
        InModuleScope VmMigrationFactory { $script:VmfMadeDiskLists } | Should -Be @('rollbackDisksDuringRollback', 'restoreDisks')
    }

    It 'the customer report and the move name have no method B' {
        InModuleScope VmMigrationFactory { $script:VmfReportMethod.ContainsKey('B') } | Should -BeFalse
        $iac = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'report' 'IacChanges.ps1')
        $iac | Should -Not -Match "Deleted and created again|-eq 'B'"
    }

    It 'the service refuses no removed engine input by name, and ends no rebuild job' {
        $facade = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $facade | Should -Not -Match 'Assert-VmfFacadeNoRemovedEngineInput|oldRebuild'
        $start = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'app' 'PostStartEngine' 'run.ps1')
        $start | Should -Not -Match 'acceptIdentityLoss|NoRemovedEngineInput'
    }
}

Describe 'OLD-REBUILD-RESTORE-READERS-1: the contracts' {
    It 'vm-state v45 has no recovery, recoveryDisks, restore.rebuilt or putBackJob.rebuild, and a job is a restore or a finish' {
        $s = OrrSchema 'vm-state.schema.json'
        $s.properties.schemaVersion.const | Should -Be 51
        InModuleScope VmMigrationFactory { $script:VmfStateDocSchemaVersion } | Should -Be 51
        $s.properties.Keys | Should -Not -Contain 'recovery'
        $s.properties.Keys | Should -Not -Contain 'recoveryDisks'
        $s.properties.restore.properties.Keys | Should -Not -Contain 'rebuilt'
        $s.properties.putBackJob.properties.Keys | Should -Not -Contain 'rebuild'
        $s.properties.putBackJob.properties.kind.enum | Should -Be @('restore', 'finish')
        foreach ($p in 'rebuildRead', 'shellDeleted', 'rebuilt', 'renameStopped') { $s.properties.putBackJob.properties.phase.enum | Should -Not -Contain $p }
        $sample = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'samples' 'vm-state.sample.json')) | ConvertFrom-Json -AsHashtable -Depth 40
        $sample.schemaVersion | Should -Be 51
        $sample.Keys | Should -Not -Contain 'recovery'
        $sample.Keys | Should -Not -Contain 'recoveryDisks'
        [string]$sample.pathCheckpoint | Should -Not -Match '^B:'
    }

    It 'the migration record and the run summary have no reason rebuilt' {
        $m = OrrSchema 'migration-record.schema.json'
        $m.properties.reason.enum | Should -Not -Contain 'rebuilt'
        ($m | ConvertTo-Json -Depth 40) | Should -Not -Match '"rebuilt"'
        $r = OrrSchema 'run-status.schema.json'
        ($r | ConvertTo-Json -Depth 40) | Should -Not -Match '"rebuilt"'
    }
}
