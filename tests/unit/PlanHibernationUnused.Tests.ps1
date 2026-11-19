#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PLAN-HIBERNATION-UNUSED-1: the plan entry no longer carries the scan's
# hibernation fact (plan-entry v32).
#
# A machine with hibernation enabled is outside the scope of this tool. The
# scan excludes it (Rules.ps1 reads the assessment's own hibernationEnabled),
# so no plan entry could hold true, and Checking reads the machine again
# (Get-VmfHostHibernationStop) before any change. Nothing read the plan
# entry's copy, so it left the planner and the contract. The scan's reading
# and the Checking stop stay.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:moduleRoot = Join-Path $script:repoRoot 'src' 'VmMigrationFactory'
    $script:schemaFile = Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json'
}

Describe 'PLAN-HIBERNATION-UNUSED-1: no hibernation fact on a plan entry' {
    It 'the planner writes no hibernationEnabled' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Public' 'New-VmfPlan.ps1')
        $code | Should -Not -Match 'hibernationEnabled' -Because 'nothing reads the plan entry''s copy of the scan''s hibernation fact'
    }

    It 'the contract is version 35 (32 removed it), has no hibernationEnabled, and the sample passes it' {
        $s = [System.IO.File]::ReadAllText($script:schemaFile) | ConvertFrom-Json -AsHashtable -Depth 40
        $s.properties.schemaVersion.const | Should -Be 37
        InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion } | Should -Be 37
        $s.properties.assessment.properties.Keys | Should -Not -Contain 'hibernationEnabled'
        $sampleText = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json'))
        $sample = $sampleText | ConvertFrom-Json -Depth 40
        $sample.schemaVersion | Should -Be 37
        $sample.assessment.PSObject.Properties.Name | Should -Not -Contain 'hibernationEnabled'
        $sampleText | Test-Json -SchemaFile $script:schemaFile | Should -BeTrue
    }

    It 'the migration note names the change' {
        $notes = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'schema-migrations.md'))
        $notes | Should -Match ([regex]::Escape('## plan-entry v31 -> v32 (2026-11-12, PLAN-HIBERNATION-UNUSED-1)'))
    }

    It 'the sample run for the manual writes the current plan version' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'tools' 'New-VmfManualSampleRun.ps1')
        $code | Should -Match 'schemaVersion = 37;'
    }

    It 'the architecture document does not list it among the plan entry''s assessment facts' {
        $arch = [System.IO.File]::ReadAllText((Join-Path $script:repoRoot 'docs' 'architecture' 'architecture.html'))
        $arch | Should -Not -Match '"hibernationEnabled":'
    }

    It 'the scan still reads hibernation and Checking still stops it' {
        (Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'assess' 'Discovery.ps1')) | Should -Match 'hibernationEnabled'
        (Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'assess' 'Rules.ps1')) | Should -Match 'hibernationEnabled'
        (Get-VmfCodeOnly -Path (Join-Path $script:moduleRoot 'Private' 'engine' 'HostHibernationCheck.ps1')) | Should -Match "Reason = 'hibernationEnabled'"
    }
}
