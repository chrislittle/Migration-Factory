#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# OLD-VERSION-READERS-REMOVE-3: the plan-entry contract holds no value or field that no writer gives
# (plan-entry v33), and the engine reads none of them.
#
# Since 2026-11-11: no installation runs an earlier version - nothing is public before 1.0,
# so no store holds a plan an earlier version wrote. Each reader went with
# proof that no writer of this version gives what it read:
#   - ReadyNow: the scan stopped writing it at assessment v11 (Rules.ps1).
#   - onDriverBelowFloor proceed: no lever allows it (Get-VmfPolicyLevers), and
#     New-VmfPlan writes stop or updateKernel only.
#   - acceleratedNetworking ensureOff: no lever allows it, and no plan writer
#     names it (AnManaDriverRule.Tests.ps1 'no plan writer writes ensureOff').
#   - target.rollbackSize: New-VmfPlan stopped writing it at RETIRE-SCOPE-1.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:schema = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json')) | ConvertFrom-Json -AsHashtable -Depth 40
    $script:codeFiles = @(
        @(Get-ChildItem -Path $script:moduleRoot -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'facade') -Recurse -Include '*.ps1', '*.psm1') +
        @(Get-ChildItem -Path (Join-Path $script:repoRoot 'src' 'dashboard') -Filter '*.js')
    )
    function Global:Ovr3CodeMatching([string]$Pattern) {
        foreach ($f in $script:codeFiles) {
            if ((Get-VmfCodeOnly -Path $f.FullName) -cmatch $Pattern) { $f.FullName.Substring($script:repoRoot.Length + 1) }
        }
    }
    function Global:Ovr3Read($Plan) {
        InModuleScope VmMigrationFactory -Parameters @{ p = $Plan } { param($p) ConvertTo-VmfSupportedPlan -Plan $p -Source 'plan.json' }
    }
}
AfterAll { Remove-Item 'function:\Ovr3CodeMatching', 'function:\Ovr3Read' -ErrorAction SilentlyContinue }

Describe 'OLD-VERSION-READERS-REMOVE-3: the plan reader still refuses a newer plan, and PRECHECK an older value' {
    It 'the current version is 33, and a current plan reads' {
        $v = InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion }
        $v | Should -Be 37
        @((Ovr3Read ([pscustomobject]@{ entries = @([pscustomobject]@{ vmId = 'a'; schemaVersion = $v }) })).entries).Count | Should -Be 1
    }

    It 'a newer entry is refused as written by a newer version' {
        { Ovr3Read ([pscustomobject]@{ entries = @([pscustomobject]@{ vmId = 'a'; schemaVersion = 38 }) }) } | Should -Throw '*newer version of the product*'
    }

    It 'an older entry that holds a removed policy value is refused before any change (policyNotKnown)' {
        InModuleScope VmMigrationFactory {
            foreach ($p in @(@{ onDriverBelowFloor = 'proceed' }, @{ acceleratedNetworking = 'ensureOff' })) {
                Get-VmfPlanPolicyRefusal -PlanEntry ([pscustomobject]@{ schemaVersion = 31; policy = [pscustomobject]$p }) | Should -Not -BeNullOrEmpty
            }
        }
    }
}
Describe 'OLD-VERSION-READERS-REMOVE-3: plan-entry v33 holds no value or field that no writer gives' {
    It 'the contract is version 37, and the sample passes it' {
        $script:schema.properties.schemaVersion.const | Should -Be 37
        $sample = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json'))
        ($sample | ConvertFrom-Json).schemaVersion | Should -Be 37
        $sample | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }

    It 'has no ReadyNow, no proceed for the kernel floor, no ensureOff, no rollbackSize and no rule for ensureOff' {
        @($script:schema.properties.assessment.properties.classification.enum) | Should -Not -Contain 'ReadyNow'
        @($script:schema.properties.policy.properties.onDriverBelowFloor.enum) | Should -Be @('stop', 'updateKernel')
        @($script:schema.properties.policy.properties.acceleratedNetworking.enum) | Should -Be @('ensureOn', 'preserve')
        $script:schema.properties.target.properties.Keys | Should -Not -Contain 'rollbackSize'
        $script:schema.Contains('allOf') | Should -BeFalse
    }

    It 'the contract refuses an entry that holds any of them' {
        $text = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json'))
        $file = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
        $e = $text | ConvertFrom-Json; $e.assessment.classification = 'ReadyNow'
        ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $file -ErrorAction SilentlyContinue | Should -BeFalse
        $e = $text | ConvertFrom-Json; $e.policy | Add-Member -NotePropertyName onDriverBelowFloor -NotePropertyValue 'proceed' -Force
        ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $file -ErrorAction SilentlyContinue | Should -BeFalse
        $e = $text | ConvertFrom-Json; $e.target | Add-Member -NotePropertyName rollbackSize -NotePropertyValue 'Standard_D2s_v5' -Force
        ($e | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile $file -ErrorAction SilentlyContinue | Should -BeFalse
    }

    It 'the migration note names the change' {
        $notes = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'schema-migrations.md'))
        $notes | Should -Match ([regex]::Escape('## plan-entry v32 -> v33 (2026-11-12, OLD-VERSION-READERS-REMOVE-3)'))
    }

    It 'the sample run for the manual writes version 37' {
        (Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1')) | Should -Match 'schemaVersion = 37;'
    }
}

Describe 'OLD-VERSION-READERS-REMOVE-3: no code reads what no writer gives' {
    It 'no engine, service or page code names ensureOff' {
        @(Ovr3CodeMatching 'ensureOff') | Should -BeNullOrEmpty
    }

    It 'the count of interfaces after the move has no switch for ensureOff' {
        InModuleScope VmMigrationFactory { (Get-Command Get-VmfAcceleratedNicsAfter).Parameters.Keys } | Should -Not -Contain 'OthersOff'
    }

    It 'the wave approval check and the acceptance file take no parameter they do not use' {
        InModuleScope VmMigrationFactory { (Get-Command Test-VmfWaveApprovalCurrent).Parameters.Keys } | Should -Not -Contain 'PlanVersion'
        InModuleScope VmMigrationFactory { (Get-Command Resolve-VmfWaveOptionsAcceptancePath).Parameters.Keys } | Should -Not -Contain 'RunPath'
        @(Ovr3CodeMatching 'Test-VmfWaveApprovalCurrent[^\r\n]*-PlanVersion') | Should -BeNullOrEmpty
        @(Ovr3CodeMatching 'Resolve-VmfWaveOptionsAcceptancePath -RunPath') | Should -BeNullOrEmpty
    }

    It 'no comment says the service loads Az.Accounts, or speaks of an approval from before' {
        foreach ($rel in 'Private/azureops/AzureOpsVm.ps1', 'Private/azureops/AzureOpsCapacity.ps1', 'Private/engine/RunSafetyCopies.ps1',
                         'Private/plan/CatalogSnapshot.ps1', 'Public/New-VmfTargetAdvice.ps1') {
            [System.IO.File]::ReadAllText((Join-Path $script:moduleRoot $rel)) | Should -Not -Match 'Az\.Accounts' -Because $rel
        }
        foreach ($rel in 'Private/engine/Orchestrator.ps1', 'Private/engine/DecisionCarry.ps1') {
            [System.IO.File]::ReadAllText((Join-Path $script:moduleRoot $rel)) | Should -Not -Match 'approval from before' -Because $rel
        }
    }
}
