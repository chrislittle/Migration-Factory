#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-ORDER-1: the plan keeps the order of its waves, and that is the order
# they run in.
#
# Found by the first end-to-end run of ADVISOR-1. The wave editor showed
# gen2-wave first; the owner signed off expecting it to run first; gen1-wave
# ran first. The engine ran waves in the order each FIRST APPEARED among the
# plan's machines - which are alphabetical, and vmf-e2e-g1 sorts before
# vmf-e2e-lin. The run page sorted waves by NAME. The wizard and the editor used
# first appearance. Four orders, and no place where a person's order was kept.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'wo'

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    # The end-to-end run's shape: machines alphabetical, waves the other way round.
    function Script:Plan([object[]]$Order) {
        $p = [ordered]@{ schemaVersion = 5; assessmentRunId = 'wo'
            entries = @(
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)vmf-e2e-g1"; wave = 'gen1-wave'; path = 'A'; policy = [ordered]@{ requireApproval = $true } }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)vmf-e2e-lin"; wave = 'gen2-wave'; path = 'A'; policy = [ordered]@{ requireApproval = $true } }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$($script:sub)vmf-e2e-win"; wave = 'gen2-wave'; path = 'A'; policy = [ordered]@{ requireApproval = $true } }) }
        if ($null -ne $Order) { $p.waveOrder = @($Order) }
        [pscustomobject]($p | ConvertTo-Json -Depth 10 | ConvertFrom-Json)
    }
    function Script:Order($plan) { InModuleScope VmMigrationFactory -Parameters @{ p = $plan } { @(Get-VmfPlanWaveOrder -Plan $p) } }
}

AfterAll { Remove-VmfTestTemp }

Describe 'WAVE-ORDER-1: the engine runs the plan''s order' {

    It 'THE DEFECT: gen2-wave first when the plan says so, although its machines sort later' {
        Script:Order (Script:Plan @('gen2-wave', 'gen1-wave')) | Should -Be @('gen2-wave', 'gen1-wave')
    }

    It 'and the wave after gen2-wave is gen1-wave' {
        $plan = Script:Plan @('gen2-wave', 'gen1-wave')
        $states = @{ "$($script:sub)vmf-e2e-lin" = 'MIGRATED'; "$($script:sub)vmf-e2e-win" = 'MIGRATED' }
        $next = InModuleScope VmMigrationFactory -Parameters @{ p = $plan; s = $states } {
            Get-VmfNextPlanWave -Plan $p -States $s -SignedOff $true -Halted $false
        }
        $next.Wave | Should -Be 'gen1-wave'
        $next.After | Should -Be 'gen2-wave'
    }

    It 'a plan without an order keeps the old rule - the order waves first appear' {
        Script:Order (Script:Plan $null) | Should -Be @('gen1-wave', 'gen2-wave')
    }

    It 'a named wave that no longer exists is ignored, and a wave the order misses comes after' {
        Script:Order (Script:Plan @('gone-wave', 'gen2-wave')) | Should -Be @('gen2-wave', 'gen1-wave')
    }

    It 'the sign-off records the order that runs' {
        $rp = Join-Path $script:temp "wo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'wo' | Out-Null }
        $pp = Join-Path $rp 'plan.json'
        Script:Plan @('gen2-wave', 'gen1-wave') | ConvertTo-Json -Depth 10 | Set-Content $pp -Encoding utf8NoBOM
        $doc = Approve-VmfPlan -RunPath $rp -PlanPath $pp -Note 'approved' -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' }
        @($doc.waves) | Should -Be @('gen2-wave', 'gen1-wave')
    }
}

Describe 'WAVE-ORDER-1: the plan keeps the order a person arranged' {

    It 'the wave editor''s save keeps the order it was sent' {
        $rp = Join-Path $script:temp "wo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'wo' | Out-Null }
        $pp = Join-Path $rp 'plan.json'
        Script:Plan $null | ConvertTo-Json -Depth 10 | Set-Content $pp -Encoding utf8NoBOM
        $waves = @(@{ name = 'gen2-wave'; vmIds = @("$($script:sub)vmf-e2e-lin", "$($script:sub)vmf-e2e-win") },
                   @{ name = 'gen1-wave'; vmIds = @("$($script:sub)vmf-e2e-g1") })
        Set-VmfWavePlan -RunPath $rp -PlanPath $pp -Layout @{ waves = $waves } -Confirm:$false | Out-Null
        $saved = Get-Content $pp -Raw | ConvertFrom-Json -Depth 20
        @($saved.waveOrder) | Should -Be @('gen2-wave', 'gen1-wave')
        Script:Order $saved | Should -Be @('gen2-wave', 'gen1-wave')
    }

    It 'a new plan records the order its waves were made in' {
        Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'New-VmfPlan.ps1') |
            Should -Match 'waveOrder\s+='
    }

    It 'the migration note is written' {
        Get-Content (Join-Path $script:repoRoot 'docs' 'schema-migrations.md') -Raw | Should -Match 'WAVE-ORDER-1'
    }
}
