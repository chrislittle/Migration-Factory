#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DCR-READ-1: the data collection rule associations of a machine were READ,
# never guessed from the Azure Monitor Agent extension.
#
# A rebuild (Path B) deleted the machine's definition, and Azure deleted its
# data collection rule associations with it (measured 2026-11-01,
# docs/research/rebuild-impact-2026-11-01.md). DCR-READ-1 listed them at the
# scan and at Checking, so the acceptance of a rebuild named each one.
#
# REBUILD-REMOVE-ACCEPT-1 removed the acceptance and the read at Checking, and
# REBUILD-REMOVE-ENGINE-1 the line after the delete. REBUILD-REMOVE-ROLE-1
# removed the rest: the scan's read, the rule of the follow-ups, and
# Microsoft.Insights/dataCollectionRuleAssociations/read from both roles
# (RebuildRemoveRole.Tests.ps1 holds that). OLD-VERSION-READERS-REMOVE-1 removed
# the words of a follow-up an earlier version recorded, and the contract fields
# that held one (2026-11-11: nobody holds such a record).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    $script:temp = New-VmfTestTemp -Prefix 'dcr'
    $script:vmId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm1'
    function Global:DcRun {
        $rp = Join-Path $script:temp "r-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'dcr' | Out-Null }
        $rp
    }
}

AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\DcRun' -ErrorAction SilentlyContinue
}

Describe 'DCR-READ-1: no contract holds the associations a rebuild deleted (OLD-VERSION-READERS-REMOVE-1)' {
    It 'REBUILD-REMOVE-ACCEPT-1: the stop for a read that failed is gone with the read' {
        InModuleScope VmMigrationFactory { Get-VmfStopGuidance -Code 'dataCollectionRuleAssociationsNotRead' | Should -BeNullOrEmpty }
    }

    It 'the words of a follow-up are gone' {
        InModuleScope VmMigrationFactory { Get-Command Get-VmfRebuildFollowUpText -ErrorAction SilentlyContinue } | Should -BeNullOrEmpty
    }

    It 'the machine state, the plan entry and the acceptance hold no association list' {
        $vs = Get-Content (Join-Path $script:repoRoot 'schemas' 'vm-state.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $vs.properties.captured.properties.PSObject.Properties.Name | Should -Not -Contain 'dataCollectionRuleAssociations'
        $pe = Get-Content (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $pe.properties.decisions.items.properties.PSObject.Properties.Name | Should -Not -Contain 'dataCollectionRuleAssociations'
        $acc = Get-Content (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json') -Raw | ConvertFrom-Json -Depth 40
        $acc.properties.PSObject.Properties.Name | Should -Not -Contain 'rebuild'
    }

    It 'the migration note names every version' {
        $notes = Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw
        $notes | Should -Match 'assessment v8 -> v9'
        $notes | Should -Match 'vm-state v35 -> v36'
        $notes | Should -Match 'plan-entry v25 -> v26'
        $notes | Should -Match 'wave-options-acceptance v6 -> v7'
        $notes | Should -Match 'vm-state v41 -> v42'
    }
}