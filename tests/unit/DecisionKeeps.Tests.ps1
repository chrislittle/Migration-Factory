#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DECIDE-KEEP-1: recording a decision keeps the wave's acceptance and the plan
# sign-off.
#
# Found in the first end-to-end run of ADVISOR-1: a Generation 1 machine going
# to v5 stopped for accelerated networking, an approver pressed "Accept this and
# continue", and the decision wrote acceleratedNetworking=ensureOn into that
# machine's plan entry. That changed the wave-options hash AND the plan's
# document version, so the engine then refused the wave ("changed after ...
# accepted its options"), the plan sign-off stopped counting, and the page -
# which trusts an acceptance file that exists - offered no way to accept again.
# The run was stuck with no path out from the screen.
#
# A decision is itself a named, audited approval of exactly one change. So when
# the acceptance and the sign-off were CURRENT just before it, they are carried
# forward with the decision recorded on them. Anything else that changes the
# plan still needs a fresh acceptance and sign-off.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'dk'
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')

    $script:g1 = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/g1'
    $script:lin = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/lin'
    $script:win = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/win'
    $script:who = @{ Identity = 'approver@example.com'; TenantId = 't' }

    function Script:NewRun {
        $rp = Join-Path $script:temp "dk-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $script:g1 } {
            Initialize-VmfRun -RunPath $rp -RunId 'dk-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'dk-test' -VmId $vm -Wave 'gen1-wave' | Out-Null
            # WAVE-APPROVE-1: with its reason code, so an approver's decision is
            # the acceptance of the one decision the machine waits for.
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'acceleratedNetworkingRequired' `
                -Detail 'Microsoft requires accelerated networking on Standard_D2s_v5' | Out-Null
        }
        $pol = { [ordered]@{ safetyCopy = 'pristine'; capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop' } }
        $plan = [ordered]@{
            schemaVersion = 15; assessmentRunId = 'dk-test'
            entries = @(
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:g1; wave = 'gen1-wave'; path = 'A'; policy = (& $pol) }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:lin; wave = 'gen2-wave'; path = 'A'; policy = (& $pol) }
                [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:win; wave = 'gen2-wave'; path = 'A'; policy = (& $pol) }
            )
        }
        $pp = Join-Path $rp 'plan.json'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $pp -Encoding utf8NoBOM
        foreach ($w in 'gen1-wave', 'gen2-wave') {
            # REBUILD-REMOVE-ACCEPT-1: every machine moves in place, so none is named.
            Confirm-VmfWaveOptions -RunPath $rp -PlanPath $pp -Wave $w -AcceptedBy 'operator@example.com' -Note 'reviewed' -Confirm:$false | Out-Null
        }
        Approve-VmfPlan -RunPath $rp -PlanPath $pp -Note 'approved' -OnBehalfOf $script:who | Out-Null
        # RETRY-GATE-1: the last start gate - a decision is refused without it.
        Confirm-VmfRunAcknowledgement -RunPath $rp -AcknowledgedBy 'operator@example.com' | Out-Null
        @{ Run = $rp; Plan = $pp }
    }
    # ACCEPT-NAME-1: the file name has a code from the wave, so ask the module.
    function Script:AccFile($rp, $wave) {
        Join-Path $rp (InModuleScope VmMigrationFactory -Parameters @{ w = $wave } { Get-VmfWaveOptionsAcceptancePath -Wave $w })
    }
    function Script:Acceptance($rp, $wave) {
        Get-Content (Script:AccFile $rp $wave) -Raw | ConvertFrom-Json -Depth 12
    }
    function Script:Gate($rp, $pp, $wave) {
        $e = @((Get-Content $pp -Raw | ConvertFrom-Json -Depth 12).entries | Where-Object { $_.wave -eq $wave })
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; e = $e; w = $wave } {
            Test-VmfWaveOptionsAccepted -RunPath $rp -Entries $e -Wave $w
        }
    }
    function Script:SignedOff($rp, $pp) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; pp = $pp } {
            Test-VmfPlanSignedOff -RunPath $rp -PlanText (Get-Content $pp -Raw)
        }
    }
    function Script:Decide($fx) {
        Resolve-VmfDecision -RunPath $fx.Run -PlanPath $fx.Plan -VmId $script:g1 `
            -PolicyOverride @{ acceleratedNetworking = 'ensureOn' } -Note 'go' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver')
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'DECIDE-KEEP-1: a decision keeps what was current' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'THE DEFECT: the wave still passes its options gate after the decision' {
        (Script:Gate $script:fx.Run $script:fx.Plan 'gen1-wave').Pass | Should -BeTrue -Because 'the fixture starts accepted'
        Script:Decide $script:fx | Out-Null
        $gate = Script:Gate $script:fx.Run $script:fx.Plan 'gen1-wave'
        $gate.Pass | Should -BeTrue -Because $gate.Detail
    }

    It 'and the plan sign-off still counts' {
        Script:Decide $script:fx | Out-Null
        $s = Script:SignedOff $script:fx.Run $script:fx.Plan
        $s.Pass | Should -BeTrue -Because $s.Detail
    }

    It 'the decision is written on both records: who, when, which machine, what changed' {
        Script:Decide $script:fx | Out-Null
        $acc = Script:Acceptance $script:fx.Run 'gen1-wave'
        @($acc.amendments).Count | Should -Be 1
        $acc.amendments[0].by | Should -Be 'approver@example.com'
        $acc.amendments[0].vmId | Should -Be $script:g1
        $acc.amendments[0].change | Should -Match 'acceleratedNetworking=ensureOn'
        $acc.acceptedBy | Should -Be 'operator@example.com' -Because 'the original acceptance is kept, not rewritten as somebody else''s'
        $pa = Get-Content (Join-Path $script:fx.Run 'plan-approval.json') -Raw | ConvertFrom-Json -Depth 8
        @($pa.amendments).Count | Should -Be 1
        $pa.amendments[0].vmId | Should -Be $script:g1
        $pa.approvedBy.identity | Should -Be 'approver@example.com'
    }

    It 'another wave''s acceptance is not touched' {
        $before = Get-Content (Script:AccFile $script:fx.Run 'gen2-wave') -Raw
        Script:Decide $script:fx | Out-Null
        Get-Content (Script:AccFile $script:fx.Run 'gen2-wave') -Raw | Should -Be $before
        (Script:Gate $script:fx.Run $script:fx.Plan 'gen2-wave').Pass | Should -BeTrue
    }

    It 'what it writes matches the schemas' {
        Script:Decide $script:fx | Out-Null
        Get-Content (Script:AccFile $script:fx.Run 'gen1-wave') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-options-acceptance.schema.json') | Should -BeTrue
        Get-Content (Join-Path $script:fx.Run 'plan-approval.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-approval.schema.json') | Should -BeTrue
        # WAVE-APPROVE-1: and the wave approval the decision was carried on.
        Get-Content (Join-Path $script:fx.Run 'approvals' 'gen1-wave.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'wave-approval.schema.json') | Should -BeTrue
    }
}

Describe 'DECIDE-KEEP-1: it never covers a change nobody accepted' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'an acceptance already out of date before the decision stays out of date' {
        # Somebody edited the wave after it was accepted, without accepting again.
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
        ($plan.entries | Where-Object vmId -eq $script:g1).policy.onDDataFound = 'proceed'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        (Script:Gate $script:fx.Run $script:fx.Plan 'gen1-wave').Pass | Should -BeFalse
        # RETRY-GATE-1: the decision is now refused outright - the wave cannot
        # start, so nothing is written and the machine is not re-armed. What
        # this test always guarded still holds: the acceptance is not moved.
        $planBefore = Get-Content $script:fx.Plan -Raw
        { Script:Decide $script:fx } | Should -Throw '400:*accept*'
        Get-Content $script:fx.Plan -Raw | Should -Be $planBefore
        $gate = Script:Gate $script:fx.Run $script:fx.Plan 'gen1-wave'
        $gate.Pass | Should -BeFalse -Because 'a decision must not launder an edit nobody accepted'
        $gate.Code | Should -Be 'changed'
        (Script:Acceptance $script:fx.Run 'gen1-wave').PSObject.Properties['amendments'] | Should -BeNullOrEmpty
    }

    It 'a sign-off already out of date before the decision stays out of date' {
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
        ($plan.entries | Where-Object vmId -eq $script:lin).policy.capacityGate = 'Reserved'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        # RETRY-GATE-1: the wave can still start, on a wave approval of the
        # edited text - so the decision reaches its write and the carry. The
        # carry must still refuse to move a sign-off that was out of date
        # before it (the guard this test exists for).
        # WAVE-APPROVE-1: rewritten. gen1-wave's own approval was current before
        # the decision, so it is carried past it: the decision goes through and
        # the machine is re-armed. This pinned a refusal, because a wave
        # approval signed the whole plan and the decision's write voided it.
        Approve-VmfWave -RunPath $script:fx.Run -PlanPath $script:fx.Plan -Wave 'gen1-wave' -Note 'approved the edit' -OnBehalfOf $script:who | Out-Null
        { Script:Decide $script:fx } | Should -Not -Throw
        (Script:SignedOff $script:fx.Run $script:fx.Plan).Pass | Should -BeFalse -Because 'a decision must not launder an edit nobody signed off'
        (Get-Content (Join-Path $script:fx.Run 'plan-approval.json') -Raw | ConvertFrom-Json).PSObject.Properties['amendments'] | Should -BeNullOrEmpty
        $ap = Get-Content (Join-Path $script:fx.Run 'approvals' 'gen1-wave.json') -Raw | ConvertFrom-Json
        @($ap.amendments).Count | Should -Be 1 -Because 'the decision is written on the wave approval it was carried on'
    }

    It 'a decision with no setting change writes nothing to either record' {
        $acc = Get-Content (Script:AccFile $script:fx.Run 'gen1-wave') -Raw
        $pa = Get-Content (Join-Path $script:fx.Run 'plan-approval.json') -Raw
        Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath $script:fx.Plan -VmId $script:g1 -Note 'go' -ResolvedBy 'approver@example.com' | Out-Null
        Get-Content (Script:AccFile $script:fx.Run 'gen1-wave') -Raw | Should -Be $acc
        Get-Content (Join-Path $script:fx.Run 'plan-approval.json') -Raw | Should -Be $pa
    }
}

Describe 'DECIDE-KEEP-1: the gate says which kind of refusal it is' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'not accepted, changed since, and current are three codes' {
        Remove-Item (Script:AccFile $script:fx.Run 'gen1-wave')
        (Script:Gate $script:fx.Run $script:fx.Plan 'gen1-wave').Code | Should -Be 'notAccepted'
        (Script:Gate $script:fx.Run $script:fx.Plan 'gen2-wave').Code | Should -Be 'current'
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
        ($plan.entries | Where-Object vmId -eq $script:lin).policy.onDDataFound = 'proceed'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        (Script:Gate $script:fx.Run $script:fx.Plan 'gen2-wave').Code | Should -Be 'changed'
    }

    It 'a wave refused for changed settings says so in the log with the wave and the code, so the page can offer to accept again' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Public' 'Start-VmfWave.ps1')
        $code | Should -Match "if \(\`$optionsGate\.Code -eq 'changed'\)"
        # RESUME-GATE-1: written through the one function that says it once.
        $code | Should -Match 'Write-VmfOptionsChangedRefusal -RunPath \$RunPath -Wave \$Wave'
        $plan = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'Private' 'engine' 'PlanRun.ps1')
        $plan | Should -Match "-Outcome refused -Detail \`$Detail -Data @\{ wave = \`$Wave; code = 'optionsChanged' \}"
    }
}
