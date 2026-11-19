#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ACCEPT-SET-1: one answer to which machines a wave's accepted settings cover.
#
# Found by reading, in the independent review of WAVE-MIX-2: the acceptance is
# a hash over the wave's entries (Get-VmfWaveOptionsHash), and its callers
# disagreed about WHICH entries. Start-VmfWave hashed the wave's path A and B
# entries; Confirm-VmfWaveOptions, the start gate (Get-VmfWaveStartGate) and a
# decision's carry-forward hashed every entry in the wave. A wave holding a
# machine that does not move (MANUAL, EXCLUDED - the API can put one in a wave)
# was accepted over one set and started against the other, and refused as
# "changed" for ever. The PLANVER-2 lesson again: three copies of a rule are
# three answers.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
}

Describe 'ACCEPT-SET-1: a wave holding a machine that does not move' {
    BeforeEach {
        $script:rp = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-as-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; sub = $sub } {
            Initialize-VmfRun -RunPath $rp -RunId 'as-run' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 8; assessmentRunId = 'as-run'
                entries = @(
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/moves"; wave = 'w1'; path = 'A'
                        policy = [ordered]@{ requireApproval = $false; throttle = 15 } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/stays"; wave = 'w1'; path = 'MANUAL'
                        policy = [ordered]@{ requireApproval = $false; throttle = 15 } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$sub/alone"; wave = 'w2'; path = 'MANUAL'
                        policy = [ordered]@{ requireApproval = $false; throttle = 15 } }) })
        }
        # Every OTHER start gate passes, so the one under test is the one that answers.
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' | Out-Null
        Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Wave 'w1' -AcceptedBy 'operator@example.com' | Out-Null
    }
    AfterEach { if (Test-Path $script:rp) { Remove-Item $script:rp -Recurse -Force } }

    It 'what was accepted is what the wave start checks - not refused as changed' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $plan = Read-VmfPlanDocument -RunPath $rp
            (Test-VmfWaveOptionsAccepted -RunPath $rp -Entries (Get-VmfWaveOptionsEntries -Plan $plan -Wave 'w1') -Wave 'w1').Code | Should -Be 'current'
        }
    }

    It 'the set is the machines that move: a change to one that does not move is not a change to the wave' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $plan = Read-VmfPlanDocument -RunPath $rp
            @(Get-VmfWaveOptionsEntries -Plan $plan -Wave 'w1').vmId | Should -Match '/moves$'
            ($plan.entries | Where-Object { $_.vmId -like '*/stays' }).policy.throttle = 30
            (Test-VmfWaveOptionsAccepted -RunPath $rp -Entries (Get-VmfWaveOptionsEntries -Plan $plan -Wave 'w1') -Wave 'w1').Code | Should -Be 'current'
            ($plan.entries | Where-Object { $_.vmId -like '*/moves' }).policy.throttle = 30
            (Test-VmfWaveOptionsAccepted -RunPath $rp -Entries (Get-VmfWaveOptionsEntries -Plan $plan -Wave 'w1') -Wave 'w1').Code | Should -Be 'changed'
        }
    }

    It 'the start gate agrees: acknowledged, accepted and no sign-off needed, so it passes' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $plan = Read-VmfPlanDocument -RunPath $rp
            Get-VmfWaveStartGate -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Plan $plan -Wave 'w1' | Should -BeNullOrEmpty
        }
    }

    It 'a decision''s carry-forward reads the same set as the acceptance' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } {
            $acc = Read-VmfStoreJson -RunPath $rp -RelPath (Get-VmfWaveOptionsAcceptancePath -Wave 'w1') -Depth 8
            (Get-VmfDecisionSnapshot -PlanPath (Join-Path $rp 'plan.json') -Wave 'w1').OptionsHash | Should -Be ([string]$acc.optionsHash)
        }
    }

    It 'a wave with no machine that moves has nothing to accept, and says so as a 400' {
        { Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath (Join-Path $script:rp 'plan.json') -Wave 'w2' -AcceptedBy 'operator@example.com' } |
            Should -Throw "400: No machine that moves is in wave 'w2'*"
    }
}

Describe 'ACCEPT-SET-1: one rule, every caller' {
    It '<File> takes the wave''s entries from Get-VmfWaveOptionsEntries' -ForEach @(
        @{ File = 'Public/Start-VmfWave.ps1' }, @{ File = 'Public/Confirm-VmfWaveOptions.ps1' },
        @{ File = 'Private/engine/PlanRun.ps1' }, @{ File = 'Private/engine/DecisionCarry.ps1' }) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $File)
        $code | Should -Match 'Get-VmfWaveOptionsEntries'
    }
}
