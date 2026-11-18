#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
ACCEPT-NAME-1, 2026-10-19. Two waves whose names differ only in punctuation
shared one settings acceptance file.

A wave name may hold letters, numbers, dashes, dots and underscores
(Set-VmfWavePlan). The acceptance file was acceptances/wave-options-<wave>.json
with every character but a letter, a number or a dash made a dash, so wave_1,
wave.1 and wave-1 wrote one file. Accepting one wave replaced the other's
acceptance, so the other was refused as changed; accepting that one again
refused the first.

The fix is the CLAIM-NAME-1 shape: the readable name in lower case plus a short
code from the wave as it is (Get-VmfNameCode), and the earlier name still read -
and written in place - when the record in it names the same wave. A decision
that carries an acceptance forward (DECIDE-KEEP-1) and a change of one
machine's target (WAVE-MIX-2) find the file the same way.

THESE TESTS RUN THE FUNCTIONS: the names, Confirm-VmfWaveOptions, the start
gate's acceptance check, a decision's carry-forward, and a record written under
the name the product used before.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'an'
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:g1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/g1'
    $script:lin = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/lin'
    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }

    # Two waves whose names the old rule made the same: g1 in wave_1 waits for
    # a decision, lin is in wave-1. Nothing is accepted yet.
    function Script:AnNewRun {
        $rp = Join-Path $script:temp "an-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $script:g1 } {
            Initialize-VmfRun -RunPath $rp -RunId 'an-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'an-test' -VmId $vm -Wave 'wave_1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'acceleratedNetworkingRequired' `
                -Detail 'Microsoft requires accelerated networking on Standard_D2s_v5' | Out-Null
        }
        $pol = { [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } }
        $plan = [ordered]@{
            schemaVersion = 15; assessmentRunId = 'an-test'
            entries = @(
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:g1; wave = 'wave_1'; path = 'A'; policy = (& $pol) }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:lin; wave = 'wave-1'; path = 'A'; policy = (& $pol) }
            )
        }
        $pp = Join-Path $rp 'plan.json'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $pp -Encoding utf8NoBOM
        @{ Run = $rp; Plan = $pp }
    }
    function Script:AnAccept($fx, [string]$Wave, [string]$Note = 'reviewed') {
        Confirm-VmfWaveOptions -RunPath $fx.Run -PlanPath $fx.Plan -Wave $Wave -AcceptedBy 'operator@example.com' -Note $Note -Confirm:$false | Out-Null
    }
    function Script:AnGate($fx, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; pp = $fx.Plan; w = $Wave } {
            $plan = Get-Content $pp -Raw | ConvertFrom-Json -Depth 12
            Test-VmfWaveOptionsAccepted -RunPath $rp -Entries @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $w) -Wave $w
        }
    }
    function Script:AnPath([string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ w = $Wave } { Get-VmfWaveOptionsAcceptancePath -Wave $w }
    }
    function Script:AnFiles($fx) {
        @(Get-ChildItem (Join-Path $fx.Run 'acceptances') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
            [pscustomobject]@{ File = $_.Name; Text = (Get-Content $_.FullName -Raw); Doc = (Get-Content $_.FullName -Raw | ConvertFrom-Json -Depth 12) } })
    }
}
AfterAll { Remove-VmfTestTemp }

Describe 'ACCEPT-NAME-1: the name of an acceptance file' {
    BeforeAll {
        # Every name in a row cleaned to the same text under the old rule.
        $script:rows = @(
            , @('wave-1', 'wave_1', 'wave.1')
            , @('wave--1', 'wave_-1', 'wave-_1', 'wave__1', 'wave..1', 'wave._1')
            , @('app-a-b', 'app_a_b', 'app.a.b', 'app-a_b', 'app_a.b'))
        $script:alike = @($script:rows | ForEach-Object { $_ })
    }

    It 'waves whose names differ only in punctuation get different files, for every pair' {
        $names = @($script:alike | ForEach-Object { Script:AnPath $_ })
        $names.Count | Should -Be $script:alike.Count
        @($names | Sort-Object -Unique).Count | Should -Be $script:alike.Count -Because ($names -join ', ')
    }

    It 'the name is the readable name in lower case and the CLAIM-NAME-1 code from the wave as it is' {
        $code = InModuleScope VmMigrationFactory { Get-VmfNameCode -Part @('Web_Pilot') }
        Script:AnPath 'Web_Pilot' | Should -BeExactly "acceptances/wave-options-web-pilot-$code.json"
        Script:AnPath 'Web_Pilot' | Should -Match '^acceptances/wave-options-web-pilot-[0-9a-f]{12}\.json$'
    }

    It 'the same wave gives the same name every time' {
        Script:AnPath 'wave.1' | Should -BeExactly (Script:AnPath 'wave.1')
    }

    It 'letter case is ignored, because the engine reads Wave_1 and wave_1 as one wave (WAVE-CASE-1)' {
        Script:AnPath 'Wave_1' | Should -BeExactly (Script:AnPath 'wave_1')
        Script:AnPath 'WAVE.1' | Should -BeExactly (Script:AnPath 'wave.1')
    }
}

Describe 'ACCEPT-NAME-1: two waves keep two acceptances' {
    BeforeEach { $script:fx = Script:AnNewRun }

    It 'THE DEFECT: accepting wave-1 leaves the acceptance of wave_1 as it was' {
        Script:AnAccept $script:fx 'wave_1'
        Script:AnAccept $script:fx 'wave-1'
        $a = Script:AnGate $script:fx 'wave_1'
        $a.Code | Should -Be 'current' -Because $a.Detail
        $b = Script:AnGate $script:fx 'wave-1'
        $b.Code | Should -Be 'current' -Because $b.Detail
        $files = Script:AnFiles $script:fx
        $files.Count | Should -Be 2
        @($files.Doc.wave) | Should -Contain 'wave_1'
        @($files.Doc.wave) | Should -Contain 'wave-1'
    }

    It 'and accepting wave_1 again leaves wave-1 accepted' {
        Script:AnAccept $script:fx 'wave_1'
        Script:AnAccept $script:fx 'wave-1'
        Script:AnAccept $script:fx 'wave_1' 'again'
        (Script:AnGate $script:fx 'wave-1').Code | Should -Be 'current'
        (Script:AnGate $script:fx 'wave_1').Code | Should -Be 'current'
    }

    It 'a wave nobody accepted is not accepted, even when a wave with a like name is' {
        Script:AnAccept $script:fx 'wave_1'
        (Script:AnGate $script:fx 'wave-1').Code | Should -Be 'notAccepted'
    }

    It 'a decision on a machine of wave_1 carries the acceptance of wave_1 and leaves wave-1''s as it is' {
        Script:AnAccept $script:fx 'wave_1'
        Script:AnAccept $script:fx 'wave-1'
        Approve-VmfPlan -RunPath $script:fx.Run -PlanPath $script:fx.Plan -Note 'approved' -OnBehalfOf $script:who | Out-Null
        Confirm-VmfRunAcknowledgement -RunPath $script:fx.Run -AcknowledgedBy 'operator@example.com' | Out-Null
        $other = Get-Content (Join-Path $script:fx.Run (Script:AnPath 'wave-1')) -Raw
        Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath $script:fx.Plan -VmId $script:g1 `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } -Note 'go' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') | Out-Null
        $mine = Get-Content (Join-Path $script:fx.Run (Script:AnPath 'wave_1')) -Raw | ConvertFrom-Json -Depth 12
        @($mine.amendments).Count | Should -Be 1
        $gate = Script:AnGate $script:fx 'wave_1'
        $gate.Code | Should -Be 'current' -Because $gate.Detail
        Get-Content (Join-Path $script:fx.Run (Script:AnPath 'wave-1')) -Raw | Should -BeExactly $other
        (Script:AnGate $script:fx 'wave-1').Code | Should -Be 'current'
    }
}

Describe 'ACCEPT-NAME-1: one rule, every caller' {
    It '<File> finds the acceptance file with Resolve-VmfWaveOptionsAcceptancePath, never by the name alone' -ForEach @(
        @{ File = 'Public/Confirm-VmfWaveOptions.ps1' }, @{ File = 'Public/Set-VmfMachineTarget.ps1' },
        @{ File = 'Private/engine/DecisionCarry.ps1' }) {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' $File)
        $code | Should -Match 'Resolve-VmfWaveOptionsAcceptancePath -Wave \$'
        $code | Should -Not -Match 'Get-VmfWaveOptionsAcceptancePath'
    }

    It 'the start gate (Test-VmfWaveOptionsAccepted) does too' {
        $body = InModuleScope VmMigrationFactory { (Get-Command Test-VmfWaveOptionsAccepted).ScriptBlock.ToString() }
        $code = Get-VmfCodeOnly -Text $body -Language PowerShell
        $code | Should -Match 'Resolve-VmfWaveOptionsAcceptancePath -Wave \$Wave'
        $code | Should -Not -Match 'Get-VmfWaveOptionsAcceptancePath'
    }

    It 'no other module file names an acceptance file' {
        $files = Get-ChildItem (Join-Path $script:repoRoot 'src' 'VmMigrationFactory') -Recurse -Filter '*.ps1'
        $hits = @($files | Where-Object { (Get-VmfCodeOnly -Path $_.FullName) -match 'wave-options-' } | ForEach-Object Name)
        $hits | Should -Be @('Orchestrator.ps1')
    }
}
