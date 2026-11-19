#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# RETRY-GATE-1: a retry is refused while the machine's wave cannot start.
#
# Try this machine again (Resolve-VmfDecision) put a machine back at PRECHECK
# without asking whether its wave could start. In a wave whose settings were
# not accepted, or that had no sign-off - after a wave edit, or a target change
# - the restart timer would not start it, and the machine waited at PRECHECK:
# read as running, refused by Skip and by a second retry, holding the wave
# editor and the release of a reservation, with nothing on the screen saying
# what it waited for.
#
# The decision (2026-10-03): the engine refuses the retry, names the
# missing step in the start gate's own words, and re-arms nothing. The page
# shows that message where the person pressed Try again (tests/js/retry-gate.test.js).
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'rgate'
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')

    $script:vm = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1'
    $script:who = @{ Identity = 'approver@example.com'; TenantId = 't' }

    # A machine that rolled back, with the copies its first attempt took - so
    # a refusal that moved them (a new attempt) would show.
    function Script:NewRun([bool]$RequireApproval = $true) {
        $rp = Join-Path $script:temp "rg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; vm = $script:vm } {
            Initialize-VmfRun -RunPath $rp -RunId 'rg-test' | Out-Null
            $doc = New-VmfStateDoc -RunPath $rp -RunId 'rg-test' -VmId $vm -Wave 'w1'
            $doc | Add-Member -NotePropertyName safety -Force -NotePropertyValue ([pscustomobject]@{
                    snapshotId = '/subscriptions/s/snapshots/vm1-vmf-rg-test'; snapshotLocked = $true
                    pristineSnapshotId = '/subscriptions/s/snapshots/vm1-vmf-rg-test-pristine'; pristineSnapshotLocked = $true
                    cloneVmId = $null; locksAllowed = $true })
            Write-VmfStateDoc -RunPath $rp -Document $doc
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' `
                -MachineState 'restored' -Detail 'STARTING failed; the machine was rolled back to how it was.' | Out-Null
        }
        $pp = Join-Path $rp 'plan.json'
        [ordered]@{ schemaVersion = 15; assessmentRunId = 'rg-test'; entries = @(
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm; wave = 'w1'; path = 'A'
                        policy = [ordered]@{ requireApproval = $RequireApproval; onDDataFound = 'stop' } }
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm2'; wave = 'w1'; path = 'A'
                        policy = [ordered]@{ requireApproval = $RequireApproval; onDDataFound = 'stop' } }
        ) } | ConvertTo-Json -Depth 10 | Set-Content $pp -Encoding utf8NoBOM
        @{ Run = $rp; Plan = $pp }
    }
    function Script:Doc($fx) { InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; vm = $script:vm } { Read-VmfStateDoc -RunPath $rp -VmId $vm } }
    function Script:Gate($fx) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; pp = $fx.Plan } {
            Get-VmfWaveStartGate -RunPath $rp -PlanPath $pp -Plan (Get-Content $pp -Raw | ConvertFrom-Json -Depth 24) -Wave 'w1'
        }
    }
    function Script:Retry($fx, [hashtable]$Override) {
        $a = @{ RunPath = $fx.Run; PlanPath = $fx.Plan; VmId = $script:vm; Note = 'fixed the boot setting'; ResolvedBy = 'operator@example.com' }
        if ($Override) { $a.PolicyOverride = $Override }
        Resolve-VmfDecision @a
    }
    function Script:Ack($fx) { Confirm-VmfRunAcknowledgement -RunPath $fx.Run -AcknowledgedBy 'operator@example.com' | Out-Null }
    function Script:Accept($fx) { Confirm-VmfWaveOptions -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -AcceptedBy 'operator@example.com' -Note 'reviewed' -Confirm:$false | Out-Null }
    function Script:SignOff($fx) { Approve-VmfPlan -RunPath $fx.Run -PlanPath $fx.Plan -Note 'approved' -OnBehalfOf $script:who | Out-Null }

    # Everything a refused retry must leave exactly as it was.
    function Script:Snapshot($fx) {
        $doc = Script:Doc $fx
        [pscustomobject]@{
            State    = [string]$doc.state
            History  = @($doc.history).Count
            Pristine = [string]$doc.safety.pristineSnapshotId
            Earlier  = [bool]$doc.safety.PSObject.Properties['earlierCopies']
            Plan     = (Get-Content $fx.Plan -Raw)
            Decided  = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } { Read-VmfEvents -RunPath $rp -Step 'decision' }).Count
        }
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'RETRY-GATE-1: a retry in a wave that cannot start is refused, and names the step' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'THE DEFECT: settings not accepted - refused in the gate''s own words, and nothing is re-armed' {
        Script:Ack $script:fx; Script:SignOff $script:fx
        $gate = Script:Gate $script:fx
        $gate.Code | Should -Be 'notAccepted' -Because 'the fixture is a wave whose settings nobody accepted'
        $before = Script:Snapshot $script:fx
        $err = $null
        try { Script:Retry $script:fx | Out-Null } catch { $err = "$_" }
        $err | Should -BeLike '400: Nothing changed for vm1, because wave w1 cannot start. *'
        $err | Should -BeLike "*$([WildcardPattern]::Escape(([string]$gate.Detail).Trim()))*" -Because 'the start gate''s own reason, the list the restart timer asks'
        $err | Should -BeLike '* Then try this machine again.'
        $after = Script:Snapshot $script:fx
        $after.State | Should -Be 'FAILED_ROLLED_BACK' -Because 'a refused retry leaves the machine where it was'
        $after.History | Should -Be $before.History
        $after.Pristine | Should -Be $before.Pristine -Because 'a refused retry takes no new attempt, so the copies stay'
        $after.Earlier | Should -BeFalse
        $after.Plan | Should -Be $before.Plan
        $after.Decided | Should -Be $before.Decided -Because 'nothing is recorded as resolved'
    }

    It 'settings changed after they were accepted - refused, naming the acceptance' {
        Script:Ack $script:fx; Script:Accept $script:fx; Script:SignOff $script:fx
        $plan = Get-Content $script:fx.Plan -Raw | ConvertFrom-Json -Depth 12
        @($plan.entries)[1].policy.onDDataFound = 'proceed'
        $plan | ConvertTo-Json -Depth 12 | Set-Content $script:fx.Plan -Encoding utf8NoBOM
        Script:SignOff $script:fx
        { Script:Retry $script:fx } | Should -Throw '400: Nothing changed for vm1*settings of wave w1 changed after*select Review & accept options again. Then try this machine again.'
        (Script:Doc $script:fx).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'no sign-off and no wave approval - refused, naming Approve' {
        Script:Ack $script:fx; Script:Accept $script:fx
        { Script:Retry $script:fx } | Should -Throw "400: Nothing changed for vm1*Nobody approved wave w1. An approver must select Approve on wave w1. Then try this machine again."
        (Script:Doc $script:fx).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'no acknowledgement - refused, naming the acknowledgement' {
        Script:Accept $script:fx; Script:SignOff $script:fx
        { Script:Retry $script:fx } | Should -Throw '400: Nothing changed for vm1*Nobody accepted the note about machines defined in code*select Accept and let this run start*'
        (Script:Doc $script:fx).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'a retry that only validates again is held to the same gates' {
        Script:Ack $script:fx; Script:SignOff $script:fx
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; vm = $script:vm } {
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_NEEDS_ATTENTION' -Outcome fail `
                -ReasonCode 'validationFailedAfterConversion' -MachineState 'changed' -Detail 'VALIDATING failed' | Out-Null
        }
        { Script:Retry $script:fx } | Should -Throw '400: Nothing changed for vm1, because wave w1 cannot start.*'
        (Script:Doc $script:fx).state | Should -Be 'FAILED_NEEDS_ATTENTION'
    }

    It 'once every gate passes, the same retry re-arms the machine' {
        Script:Ack $script:fx; Script:Accept $script:fx; Script:SignOff $script:fx
        Script:Gate $script:fx | Should -BeNullOrEmpty
        (Script:Retry $script:fx).NewState | Should -Be 'PRECHECK'
    }
}

Describe 'RETRY-GATE-1: the gate is the engine''s, not a narrower copy' {

    It 'a plan entry with no wave is refused in words, not with an error the page cannot read' {
        $fx = Script:NewRun
        $plan = Get-Content $fx.Plan -Raw | ConvertFrom-Json -Depth 12
        @($plan.entries)[0].wave = ''
        $plan | ConvertTo-Json -Depth 12 | Set-Content $fx.Plan -Encoding utf8NoBOM
        { Script:Retry $fx } | Should -Throw '400: Nothing changed for vm1, because its plan entry names no wave*'
        (Script:Doc $fx).state | Should -Be 'FAILED_ROLLED_BACK'
    }

    It 'a wave set not to need approval is retried without a sign-off - the engine would start it' {
        $fx = Script:NewRun -RequireApproval $false
        Script:Ack $fx; Script:Accept $fx
        Script:Gate $fx | Should -BeNullOrEmpty
        (Script:Retry $fx).NewState | Should -Be 'PRECHECK'
    }

    It 'a decision that leaves its wave unable to start is not re-armed: the change is saved and said' {
        # A decision carries the acceptance and the plan sign-off past its
        # write. WAVE-APPROVE-1: a wave approval signs its wave, and a decision
        # carries it only when an approver accepts the one decision the machine
        # waits for. This is an operator's change to another setting, so the
        # wave asks again for its approval, and cannot start after the write.
        $fx = Script:NewRun
        Script:Ack $fx; Script:Accept $fx
        Approve-VmfWave -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -Note 'approved' -OnBehalfOf $script:who | Out-Null
        Script:Gate $fx | Should -BeNullOrEmpty -Because 'the wave can start before the decision'
        { Script:Retry $fx -Override @{ keepSnapshotDays = 14 } } |
            Should -Throw "400: The change (keepSnapshotDays=14) is saved, but wave w1 cannot start now, so vm1 was not tried again. The approval of wave w1 no longer matched the plan and was removed. Nobody approved wave w1.*select Approve*"
        (Script:Doc $fx).state | Should -Be 'FAILED_ROLLED_BACK' -Because 'it waits for nothing nobody can see'
        # The review of RETRY-GATE-1: the stale approval file is removed, as
        # every other plan writer removes it, so the run page offers Approve
        # this wave again instead of a green "Approved by" over a wave the
        # engine refuses.
        Test-Path (Join-Path $fx.Run 'approvals' 'w1.json') | Should -BeFalse
        # And the approver's note is on the record, though nothing was re-armed.
        $refused = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } { Read-VmfEvents -RunPath $rp -Step 'decision' }) |
            Where-Object { $_.outcome -eq 'refused' }
        @($refused).Count | Should -Be 1
        $refused[0].detail | Should -BeLike '*operator@example.com changed keepSnapshotDays=14 for this machine: fixed the boot setting.*'
        $plan = Get-Content $fx.Plan -Raw | ConvertFrom-Json -Depth 12
        ($plan.entries | Where-Object vmId -eq $script:vm).policy.keepSnapshotDays | Should -Be 14 -Because 'the decision itself stands, and the message says so'
        # Approve the wave again, and the same decision goes through.
        Approve-VmfWave -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -Note 'approved again' -OnBehalfOf $script:who | Out-Null
        (Script:Retry $fx -Override @{ keepSnapshotDays = 14 }).NewState | Should -Be 'PRECHECK'
    }
}

Describe 'STEP-LOG-4: a decision line that cannot be written never decides what the decision did' {

    It 'the refused line after the change is saved: the refusal says the change is saved, not the store''s error' {
        $fx = Script:NewRun
        Script:Ack $fx; Script:Accept $fx
        Approve-VmfWave -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -Note 'approved' -OnBehalfOf $script:who | Out-Null
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'decision' -and $Outcome -eq 'refused' } { throw 'The store did not answer.' }
        { Resolve-VmfDecision -RunPath $fx.Run -PlanPath $fx.Plan -VmId $script:vm -Note 'fixed the boot setting' -ResolvedBy 'operator@example.com' -PolicyOverride @{ keepSnapshotDays = 14 } -WarningAction SilentlyContinue } |
            Should -Throw "400: The change (keepSnapshotDays=14) is saved, but wave w1 cannot start now, so vm1 was not tried again.*"
        ((Get-Content $fx.Plan -Raw | ConvertFrom-Json -Depth 12).entries | Where-Object vmId -eq $script:vm).policy.keepSnapshotDays | Should -Be 14
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'decision' -and $Outcome -eq 'refused' } -Times 1 -Exactly
    }

    It 'the ok line after the machine is re-armed: the decision is returned, and the list is told' {
        $fx = Script:NewRun
        Script:Ack $fx; Script:Accept $fx; Script:SignOff $fx
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { $true }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'decision' -and $Outcome -eq 'ok' } { throw 'The store did not answer.' }
        $r = Resolve-VmfDecision -RunPath $fx.Run -PlanPath $fx.Plan -VmId $script:vm -Note 'fixed the boot setting' -ResolvedBy 'operator@example.com' -WarningVariable w -WarningAction SilentlyContinue
        $r.NewState | Should -Be 'PRECHECK'
        (Script:Doc $fx).state | Should -Be 'PRECHECK'
        (@($w | ForEach-Object { [string]$_ }) -join ' ') | Should -BeLike "*'decision ok' for $script:vm could not be written*"
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfRunSummary -ParameterFilter { $Reason -eq 'decision' } -Times 1 -Exactly
    }
}
