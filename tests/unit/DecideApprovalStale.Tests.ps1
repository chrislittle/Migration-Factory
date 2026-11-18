#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# DECIDE-APPROVAL-STALE-1: a decision says which wave approvals it removed.
#
# A wave approval signs the whole plan text. A decision with a setting change
# (Resolve-VmfDecision -PolicyOverride) writes the plan, so every approval
# signed before it can no longer pass the gate, and RETRY-GATE-1 removes them
# (Remove-VmfStaleWaveApprovals). When the decision went through, nothing said
# so: a person who approved those waves found them unapproved, with no line in
# the activity. A wave save and a target change both say it ("The approval of
# wave X signed the plan before this change. Approve the wave again.").
#
# A decision now says it, from the same helper, and returns the waves so the
# page can say it where the decision's result is shown. One difference, found
# by the independent review: a decision carries the plan sign-off past its
# write, and a current sign-off passes every wave. A wave it covers can start
# without the removed approval, and the page offers no Approve for it - so the
# words say "can still start without it", not "Approve the wave again".
#
# WAVE-APPROVE-1: a wave approval now signs its own wave, so a decision's write
# leaves another wave's approval standing; only the decided wave's own approval
# goes (an approver accepting the one decision the machine waits for carries
# it). Every approval here is one Approve-VmfWave writes: nothing is public
# before 1.0, so no store holds one that signs the whole plan text.
#
# The rule of 2026-10-10: a decision moves a v3 sign-off only with the
# wave's approval - an approver's decision. An operator's decision under a v3
# sign-off saves the change and asks again for the wave's approval.
# MIGRATIONS-PAGE-OLD-READERS-1: Approve-VmfPlan writes only v4, so no case
# here holds a v1 or v2 sign-off.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'dastale'

    $script:vm1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/ds1'
    $script:vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/ds2'
    $script:who = @{ Identity = 'approver@example.com'; TenantId = 't' }

    # Two waves, each accepted and approved. -SignOff also signs off the plan
    # (v3, the only version Approve-VmfPlan writes).
    # -W1NeedsNoApproval sets the decided machine's wave not to need approval,
    # so the decision goes through with no sign-off. -Parked parks the machine
    # for files on the temporary disk, a decision an approver accepts.
    function Script:NewRun([switch]$SignOff, [switch]$W1NeedsNoApproval, [switch]$Parked) {
        $rp = Join-Path $script:temp "ds-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $script:vm1 } {
            Initialize-VmfRun -RunPath $rp -RunId 'ds-test' | Out-Null
            New-VmfStateDoc -RunPath $rp -RunId 'ds-test' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' `
                -MachineState 'restored' -Detail 'STARTING failed; the machine was rolled back to how it was.' | Out-Null
        }
        $pp = Join-Path $rp 'plan.json'
        [ordered]@{ schemaVersion = 15; assessmentRunId = 'ds-test'; entries = @(
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm1; wave = 'w1'; path = 'A'
                        policy = [ordered]@{ requireApproval = (-not $W1NeedsNoApproval); onDDataFound = 'stop' } }
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm2; wave = 'w2'; path = 'A'
                        policy = [ordered]@{ requireApproval = $true; onDDataFound = 'stop' } }
        ) } | ConvertTo-Json -Depth 10 | Set-Content $pp -Encoding utf8NoBOM
        Confirm-VmfRunAcknowledgement -RunPath $rp -AcknowledgedBy 'operator@example.com' | Out-Null
        foreach ($w in 'w1', 'w2') {
            Confirm-VmfWaveOptions -RunPath $rp -PlanPath $pp -Wave $w -AcceptedBy 'operator@example.com' -Note 'reviewed' -Confirm:$false | Out-Null
            Approve-VmfWave -RunPath $rp -PlanPath $pp -Wave $w -Note 'approved' -OnBehalfOf $script:who | Out-Null
        }
        if ($SignOff) { Approve-VmfPlan -RunPath $rp -PlanPath $pp -Note 'signed off' -OnBehalfOf $script:who | Out-Null }
        if ($Parked) {
            # Parked for files on the temporary disk: the one decision an
            # approver accepts is onDDataFound = proceed.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $script:vm1 } {
                Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' `
                    -MachineState 'untouched' -Detail 'files on the temporary disk' | Out-Null
            }
        }
        @{ Run = $rp; Plan = $pp }
    }
    function Script:Decide($fx, [hashtable]$Override) {
        $a = @{ RunPath = $fx.Run; PlanPath = $fx.Plan; VmId = $script:vm1; Note = 'fixed the boot setting'; ResolvedBy = 'operator@example.com' }
        if ($Override) { $a.PolicyOverride = $Override }
        Resolve-VmfDecision @a
    }
    function Script:Ok($fx) {
        @(InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } { Read-VmfEvents -RunPath $rp -Step 'decision' } | Where-Object { $_.outcome -eq 'ok' })
    }
    $script:renew = { param([string]$w) "The approval of wave $w signed the plan before this change. Approve the wave again." }
    $script:covered = { param([string]$w) "The approval of wave $w signed the plan before this change, so it was removed. The wave can still start without it." }
}

AfterAll { Remove-VmfTestTemp }

Describe 'DECIDE-APPROVAL-STALE-1: a decision that goes through says which approvals it removed' {

    It 'the machine''s history says it too, beside the decision' {
        $fx = Script:NewRun -W1NeedsNoApproval
        Script:Decide $fx @{ keepSnapshotDays = 14 } | Out-Null
        $doc = InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; vm = $script:vm1 } { Read-VmfStateDoc -RunPath $rp -VmId $vm }
        @($doc.history)[-1].detail | Should -BeLike "Decision resolved by operator@example.com: fixed the boot setting.*$(& $script:covered 'w1')*"
    }

    It 'a retry with no setting change writes no plan, removes nothing, and says nothing about approvals' {
        $fx = Script:NewRun -SignOff
        $r = Script:Decide $fx
        $r.NewState | Should -Be 'PRECHECK'
        @($r.ApprovalsCleared).Count | Should -Be 0
        Test-Path (Join-Path $fx.Run 'approvals' 'w2.json') | Should -BeTrue
        (Script:Ok $fx)[0].detail | Should -Be 'resolved by operator@example.com: fixed the boot setting' -Because 'the line is as it was'
    }

    It 'a wave with no approval file has none to lose, and is not named' {
        $fx = Script:NewRun -W1NeedsNoApproval
        Remove-Item (Join-Path $fx.Run 'approvals' 'w1.json')
        $r = Script:Decide $fx @{ keepSnapshotDays = 14 }
        @($r.ApprovalsCleared).Count | Should -Be 0
        (Script:Ok $fx)[0].detail | Should -Not -Match 'wave w1'
    }

    It 'a note that ends in a question mark is not given a full stop as well' {
        $fx = Script:NewRun -W1NeedsNoApproval
        $a = @{ RunPath = $fx.Run; PlanPath = $fx.Plan; VmId = $script:vm1; Note = 'is this the boot setting?'; ResolvedBy = 'operator@example.com'; PolicyOverride = @{ keepSnapshotDays = 14 } }
        Resolve-VmfDecision @a | Out-Null
        (Script:Ok $fx)[0].detail | Should -BeLike 'Decision resolved by operator@example.com: is this the boot setting? The approval*'
    }

    It 'WAVE-APPROVE-1: with approvals that sign their own wave, a decision removes only its own wave''s, and says so' {
        $fx = Script:NewRun -W1NeedsNoApproval
        $r = Script:Decide $fx @{ keepSnapshotDays = 14 }
        $r.NewState | Should -Be 'PRECHECK' -Because 'wave w1 needs no approval, so it can start'
        @($r.ApprovalsCleared) | Should -Be @('w1')
        Test-Path (Join-Path $fx.Run 'approvals' 'w2.json') | Should -BeTrue -Because 'the decision did not touch wave w2'
        $d = (Script:Ok $fx)[0].detail
        $d | Should -BeLike "*$(& $script:covered 'w1')*"
        $d | Should -Not -Match 'wave w2'
        InModuleScope VmMigrationFactory -Parameters @{ fx = $fx } {
            (Test-VmfWaveApproval -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w2').Pass | Should -BeTrue
        }
    }

    It 'WAVE-APPROVE-1: with the plan signed off, an operator''s decision is not covered by the sign-off - the decided wave asks again, the other keeps its approval' {
        # Rewritten for the rule of 2026-10-10. This pinned the sign-off
        # carried past an operator's decision: a v3 sign-off of the exact plan
        # then passed w1 at the approval gate with its approval removed, so the
        # timer would start a change no approver saw. Now the v3 sign-off moves
        # only with the wave's approval, and w1 asks again.
        $fx = Script:NewRun -SignOff
        $signedBefore = (Get-Content (Join-Path $fx.Run 'plan-approval.json') -Raw | ConvertFrom-Json).planHash
        { Script:Decide $fx @{ keepSnapshotDays = 14 } } | Should -Throw '400:*wave w1 cannot start now*Nobody approved wave w1*'
        (Get-Content (Join-Path $fx.Run 'plan-approval.json') -Raw | ConvertFrom-Json).planHash | Should -BeExactly $signedBefore -Because 'the sign-off is not moved'
        (Get-Content $fx.Plan -Raw | ConvertFrom-Json).entries[0].policy.keepSnapshotDays | Should -Be 14 -Because 'the change is saved'
        Test-Path (Join-Path $fx.Run 'approvals' 'w1.json') | Should -BeFalse
        Test-Path (Join-Path $fx.Run 'approvals' 'w2.json') | Should -BeTrue
        InModuleScope VmMigrationFactory -Parameters @{ fx = $fx; vm = $script:vm1 } {
            (Test-VmfWaveApproval -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1').Pass | Should -BeFalse
            (Test-VmfWaveApproval -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w2').Pass | Should -BeTrue
            (Read-VmfStateDoc -RunPath $fx.Run -VmId $vm).state | Should -Be 'FAILED_ROLLED_BACK' -Because 'the machine is not tried again'
        }
    }

    It 'WAVE-APPROVE-1: with the plan signed off, an approver''s acceptance of the decision carries the wave approval and the sign-off' {
        $fx = Script:NewRun -SignOff -Parked
        $a = @{ RunPath = $fx.Run; PlanPath = $fx.Plan; VmId = $script:vm1; Note = 'the files are not needed'; ResolvedBy = 'lead@example.com'
                PolicyOverride = @{ onDDataFound = 'proceed' }; ResolvedRoles = @('Vmf.Approver') }
        $r = Resolve-VmfDecision @a
        $r.NewState | Should -Be 'PRECHECK'
        @($r.ApprovalsCleared).Count | Should -Be 0 -Because 'the wave approval is carried, not removed'
        $now = InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content $fx.Plan -Raw) } { Get-VmfDocumentVersion -Text $t }
        $signed = Get-Content (Join-Path $fx.Run 'plan-approval.json') -Raw | ConvertFrom-Json
        $signed.planHash | Should -BeExactly $now -Because 'the sign-off moves with the wave approval'
        @($signed.amendments)[-1].by | Should -Be 'lead@example.com'
        $w1 = Get-Content (Join-Path $fx.Run 'approvals' 'w1.json') -Raw | ConvertFrom-Json
        $w1.approvedBy.identity | Should -Be 'approver@example.com' -Because 'the approval keeps the name of the approver who gave it'
        @($w1.amendments)[-1].by | Should -Be 'lead@example.com' -Because 'and gains an amendment that names the approver who decided'
        @($w1.amendments)[-1].change | Should -Be 'onDDataFound=proceed'
        InModuleScope VmMigrationFactory -Parameters @{ fx = $fx } {
            (Test-VmfWaveApproval -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1').Pass | Should -BeTrue
        }
    }

    It 'a wave save, a target change and a decision say it with one helper' {
        $s = InModuleScope VmMigrationFactory { Get-VmfStaleApprovalNote -Wave @('w1', 'w2') }
        $s | Should -BeExactly ((& $script:renew 'w1') + ' ' + (& $script:renew 'w2'))
        InModuleScope VmMigrationFactory { Get-VmfStaleApprovalNote -Wave @('w2') -StillCovered @('w1') } |
            Should -BeExactly ((& $script:renew 'w2') + ' ' + (& $script:covered 'w1'))
        InModuleScope VmMigrationFactory { Get-VmfStaleApprovalNote -Wave @() } | Should -BeExactly ''
        InModuleScope VmMigrationFactory { Get-VmfStaleApprovalNote -Wave @('unscheduled') } |
            Should -BeExactly 'The approval of the machines not in a wave signed the plan before this change. Approve the wave again.'
    }
}

# MIGRATIONS-DECISION-WORDS-1: the ok line of a decision says which button the
# operator selected, so the Migrations page can name it (2026-11-14:
# "Name both buttons"). Try this machine again sends no setting change; Accept
# this and continue sends one. The carry lines of the same step name no button.
Describe 'MIGRATIONS-DECISION-WORDS-1: the decision line says which button the operator selected' {

    It 'Try this machine again (no setting change) writes choice retry' {
        $fx = Script:NewRun -SignOff
        Script:Decide $fx | Out-Null
        $line = @(Script:Ok $fx)
        $line.Count | Should -Be 1
        $line[0].choice | Should -BeExactly 'retry'
    }

    It 'Accept this and continue (a setting change) writes choice accept' {
        $fx = Script:NewRun -W1NeedsNoApproval
        Script:Decide $fx @{ keepSnapshotDays = 14 } | Out-Null
        $line = @(Script:Ok $fx)
        $line.Count | Should -Be 1
        $line[0].choice | Should -BeExactly 'accept'
    }

    It 'an approver''s acceptance writes choice accept, and its carry lines name no button' {
        $fx = Script:NewRun -SignOff -Parked
        Resolve-VmfDecision -RunPath $fx.Run -PlanPath $fx.Plan -VmId $script:vm1 -Note 'the files are not needed' -ResolvedBy 'lead@example.com' `
            -PolicyOverride @{ onDDataFound = 'proceed' } -ResolvedRoles @('Vmf.Approver') | Out-Null
        (Script:Ok $fx)[0].choice | Should -BeExactly 'accept'
        $carry = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } { Read-VmfEvents -RunPath $rp -Step 'decision' } | Where-Object { $_.outcome -ne 'ok' })
        $carry.Count | Should -BeGreaterThan 0 -Because 'the carry wrote its lines'
        @($carry | Where-Object { $_.PSObject.Properties['choice'] }).Count | Should -Be 0
    }
}
