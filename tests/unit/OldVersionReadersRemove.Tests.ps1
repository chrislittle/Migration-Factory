#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-VERSION-READERS-REMOVE-1: no code, stop reason, contract field or report
# section for a record of a rebuild that an earlier version wrote.
#
# The rebuild around the same disks (Path B) was removed on 2026-11-07.
# The removal kept readers for what an earlier version wrote: a plan entry
# with path B, a machine an earlier version started to rebuild, the acceptance
# of a rebuild, the identity a rebuild deleted and the follow-ups after it.
#
# Since 2026-11-11: no install runs an earlier version - nothing is public before 1.0,
# so no store holds such a record. Each reader went with proof that no flow
# of this version writes what it read. The contracts drop the fields with a
# version bump and a migration note, and no code reads the old shape
# (plan-entry v31, wave options acceptance v9, wave approval v5, vm-state v42).
# The assessment reader takes the current version only.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:schemas = Join-Path $script:repoRoot 'schemas'
    function Global:OvrSchema([string]$Name) {
        [System.IO.File]::ReadAllText((Join-Path $script:schemas $Name)) | ConvertFrom-Json -AsHashtable -Depth 40
    }
    # The code of every engine, service and page file, comments taken out.
    $script:codeFiles = @(
        @(Get-ChildItem -Path $script:moduleRoot -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'facade') -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.js')
    )
    function Global:OvrCodeMatching([string]$Pattern) {
        foreach ($f in $script:codeFiles) {
            $code = Get-VmfCodeOnly -Path $f.FullName
            if ($code -cmatch $Pattern) { $f.FullName.Substring($script:repoRoot.Length + 1) }
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-1: no reader for a rebuild an earlier version planned or started' {
    It 'has no function that refuses or reports such a record' {
        foreach ($name in @('Get-VmfRebuildRefusal', 'Assert-VmfNoRebuildPlanned', 'Get-VmfOldRebuildResume',
                            'Get-VmfRebuildFollowUpText', 'Get-VmfRebuildFollowUpReportHtml')) {
            InModuleScope VmMigrationFactory -Parameters @{ name = $name } { param($name) Get-Command $name -ErrorAction SilentlyContinue } |
                Should -BeNullOrEmpty -Because "$name read a record that no flow of this version writes"
        }
        foreach ($rel in @('Private/plan/RebuildRefusal.ps1', 'Private/engine/OldRebuildResume.ps1',
                           'Private/plan/RebuildFollowUps.ps1', 'Private/report/RebuildFollowUpReport.ps1')) {
            Test-Path (Join-Path $script:moduleRoot $rel) | Should -BeFalse -Because "$rel is gone"
        }
    }

    It 'has no stop reason that only such a record reaches, and no code that writes one' {
        $reasons = ([System.IO.File]::ReadAllText((Join-Path $script:moduleRoot 'data' 'stop-reasons.json')) | ConvertFrom-Json).reasons
        foreach ($code in @('pathNotExecutable', 'rebuildNotSupported', 'oldRebuildNotResumed')) {
            @($reasons | Where-Object { $_.code -eq $code }) | Should -HaveCount 0 -Because "$code is gone from the stop reasons"
            @(OvrCodeMatching "\b$code\b") | Should -BeNullOrEmpty -Because "no code writes or reads $code"
        }
    }

    It 'runs only path A, the in-place upgrade' {
        @(OvrCodeMatching "'A',\s*'B'") | Should -BeNullOrEmpty -Because 'no plan entry of this version has path B'
        $plan = [pscustomobject]@{ entries = @(
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'a'; wave = 'w1'; path = 'A' }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'b'; wave = 'w1'; path = 'B' }
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'm'; wave = 'w1'; path = 'MANUAL' }) }
        $moving = InModuleScope VmMigrationFactory -Parameters @{ plan = $plan } { param($plan) Get-VmfWaveOptionsEntries -Plan $plan -Wave 'w1' }
        @($moving | ForEach-Object vmId) | Should -Be @('a')
    }

    It 'reads no identity a rebuild deleted and no follow-up after a rebuild, in the report or on the page' {
        @(OvrCodeMatching '\bidentityDeleted\b|\boldPrincipalId\b|identityPrincipalAfter|identityPrincipalBefore|rebuildFollowUps') |
            Should -BeNullOrEmpty -Because 'no step of this version writes these lines'
        $report = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Public' 'New-VmfReport.ps1')
        $report | Should -Not -Match 'identities that a rebuild deleted'
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.js')
        $page | Should -Not -Match 'idReplaced|identityDeletedStep'
    }

    It 'refuses no field a page of an earlier version sent with a rebuild, because no such page exists' {
        @(OvrCodeMatching 'identityLossPrincipalId|rebuildExtensions|identityLossNamed|rebuildNamed|onSystemAssignedIdentity') |
            Should -BeNullOrEmpty -Because 'the service names no field that only an earlier page sent'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-1: the contracts hold no shape of an earlier record' {
    It 'accepts only the current assessment version' {
        $current = InModuleScope VmMigrationFactory { Get-VmfAssessmentSchemaVersion }
        { InModuleScope VmMigrationFactory -Parameters @{ v = $current } { param($v) Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = $v }) } } |
            Should -Not -Throw
        foreach ($v in @(1, ($current - 1), ($current + 1))) {
            { InModuleScope VmMigrationFactory -Parameters @{ v = $v } { param($v) Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = $v }) } } |
                Should -Throw -Because "version $v is not the version this build writes"
        }
        { InModuleScope VmMigrationFactory -Parameters @{ v = ($current - 1) } { param($v) Assert-VmfSupportedAssessment -Assessment ([pscustomobject]@{ schemaVersion = $v }) } } |
            Should -Throw '*Scan again*'
        (OvrSchema 'assessment.schema.json').properties.schemaVersion.const | Should -Be $current
    }

    It 'gives a plan entry path A, MANUAL or EXCLUDED, and no field of a rebuild (plan-entry v31)' {
        $s = OvrSchema 'plan-entry.schema.json'
        $s.properties.schemaVersion.const | Should -Be 37
        (InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion }) | Should -Be 37
        @($s.properties.path.enum) | Should -Be @('A', 'MANUAL', 'EXCLUDED')
        $s.properties.assessment.properties.Keys | Should -Not -Contain 'rebuildLinks'
        @($s.properties.target.properties.choice.properties.method.enum) | Should -Not -Contain 'rebuild'
        @($s.properties.decisions.items.properties.Keys | Sort-Object) | Should -Be @('by', 'setting', 'utc')
    }

    It 'holds no list of a rebuild or an identity loss in an acceptance (v9) or a wave approval (v5)' {
        $acc = OvrSchema 'wave-options-acceptance.schema.json'
        $acc.properties.schemaVersion.const | Should -Be 9
        $acc.properties.Keys | Should -Not -Contain 'rebuild'
        $acc.properties.Keys | Should -Not -Contain 'identityLoss'
        (InModuleScope VmMigrationFactory { Get-VmfWaveOptionsAcceptanceSchemaVersion }) | Should -Be 9
        $ap = OvrSchema 'wave-approval.schema.json'
        $ap.properties.schemaVersion.const | Should -Be 5
        $ap.properties.Keys | Should -Not -Contain 'identityLoss'
        (InModuleScope VmMigrationFactory { Get-VmfWaveApprovalSchemaVersion }) | Should -Be 5
    }

    It 'captures no SQL virtual machine resource or data collection rule association for a rebuild (vm-state v42)' {
        $s = OvrSchema 'vm-state.schema.json'
        $s.properties.schemaVersion.const | Should -Be 51
        $s.properties.captured.properties.Keys | Should -Not -Contain 'sqlVirtualMachine'
        $s.properties.captured.properties.Keys | Should -Not -Contain 'dataCollectionRuleAssociations'
        (Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'engine' 'StateMachine.ps1')) |
            Should -Not -Match "'sqlVirtualMachine'|'dataCollectionRuleAssociations'"
    }

    It 'writes a migration note for each version it bumps' {
        $notes = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'schema-migrations.md'))
        foreach ($n in @('plan-entry v30 -> v31', 'wave-options-acceptance v8 -> v9', 'wave-approval v4 -> v5', 'vm-state v41 -> v42')) {
            $notes | Should -Match ([regex]::Escape($n))
        }
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-1: the manual check covers the stop reasons page' {
    It 'reads reference/stop-reasons.md with every other page' {
        $code = Get-VmfCodeOnly -Path (Join-Path $PSScriptRoot 'RebuildRemoveDocs.Tests.ps1')
        $code | Should -Not -Match 'stop-reasons\.md'
    }
}
