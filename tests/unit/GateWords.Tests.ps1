#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# GATE-WORDS-1: the start gate's reasons are written for the screen.
#
# RETRY-GATE-1 shows the engine's start gate reason in the Try this machine
# again dialog, and the migration's page already showed it for the next wave
# of a signed-off plan and for a refused wave start. The reasons were written
# for a person at a PowerShell prompt: they named Confirm-VmfWaveOptions and
# Confirm-VmfRunAcknowledgement, talked of the wave's "levers", started in
# lower case, and the acknowledgement reason repeated its whole ten-sentence
# statement before it said what to do.
#
# THE RULE: every reason the gate can return is one sentence that says what is
# missing and one that says what to do, with the Migrations page's own button
# names. The words live in data/start-gates.json, where
# tools/Test-SimplifiedEnglish.ps1 reads them like every other screen string,
# and each reason carries a stable code beside its sentence, so nothing has to
# read the words to know which gate failed.
#
# RUN, not read: every reason below comes out of the engine's own gate, from a
# run in the state that produces it.
BeforeAll {
    . (Join-Path $PSScriptRoot '_PageSource.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'gwords'

    $script:words = Get-Content (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'data' 'start-gates.json') -Raw | ConvertFrom-Json
    $script:statement = InModuleScope VmMigrationFactory { Get-VmfIacStatement }
    $pageText = (Get-VmfPageSource -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html'))
    $label = { param($key) $m = [regex]::Match($pageText, "(?m)^\s*$key\s*:\s*'([^']*)'"); if (-not $m.Success) { throw "no UX_ACT.$key" }; $m.Groups[1].Value }
    # The buttons the Migrations page shows for each gate.
    $script:button = @{
        acknowledgement = & $label 'ackBtn'
        acceptance      = & $label 'acceptOptions'
        approval        = & $label 'approve'
    }

    $script:vm1 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/gw1'
    $script:vm2 = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/gw2'
    $script:who = @{ Identity = 'approver@example.com'; TenantId = 't' }

    function Script:NewRun {
        $rp = Join-Path $script:temp "gw-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Initialize-VmfRun -RunPath $rp -RunId 'gw-test' | Out-Null }
        $pp = Join-Path $rp 'plan.json'
        [ordered]@{ schemaVersion = 15; assessmentRunId = 'gw-test'; entries = @(
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm1; wave = 'w1'; path = 'A'
                        policy = [ordered]@{ requireApproval = $true; onDDataFound = 'stop' } }
            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm2; wave = 'w1'; path = 'A'
                        policy = [ordered]@{ requireApproval = $true; onDDataFound = 'stop' } }
        ) } | ConvertTo-Json -Depth 10 | Set-Content $pp -Encoding utf8NoBOM
        @{ Run = $rp; Plan = $pp }
    }
    function Script:Ack($fx, [string]$By = 'operator@example.com') {
        if ($By) { Confirm-VmfRunAcknowledgement -RunPath $fx.Run -AcknowledgedBy $By | Out-Null; return }
        # A record that names nobody - written by hand, as nothing in the product writes one.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } {
            Write-VmfStoreJson -RunPath $rp -RelPath 'acknowledgements/infrastructure-as-code.json' -Document ([ordered]@{
                schemaVersion = 1; topic = 'infrastructure-as-code'; acknowledgedBy = ''; acknowledgedUtc = '2026-10-04T10:00:00Z' })
        }
    }
    function Script:Accept($fx) { Confirm-VmfWaveOptions -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -AcceptedBy 'operator@example.com' -Note 'reviewed' -Confirm:$false | Out-Null }
    function Script:Approve($fx) { Approve-VmfWave -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -Note 'approved' -OnBehalfOf $script:who | Out-Null }
    function Script:EditPlan($fx, [scriptblock]$Change) {
        $plan = Get-Content $fx.Plan -Raw | ConvertFrom-Json -Depth 12
        & $Change $plan
        $plan | ConvertTo-Json -Depth 12 | Set-Content $fx.Plan -Encoding utf8NoBOM
    }
    function Script:Gate($fx) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; pp = $fx.Plan } {
            Get-VmfWaveStartGate -RunPath $rp -PlanPath $pp -Plan (Get-Content $pp -Raw | ConvertFrom-Json -Depth 24) -Wave 'w1'
        }
    }

    # Each state that fails a gate, and the code it must give.
    $script:cases = [ordered]@{
        notAcknowledged      = { param($fx) }
        acknowledgedByNobody = { param($fx) Script:Ack $fx '' }
        notAccepted          = { param($fx) Script:Ack $fx }
        changed              = { param($fx) Script:Ack $fx; Script:Accept $fx
                                 Script:EditPlan $fx { param($plan) @($plan.entries)[1].policy.onDDataFound = 'proceed' } }
        notApproved          = { param($fx) Script:Ack $fx; Script:Accept $fx }
        approvalOutOfDate    = { param($fx) Script:Ack $fx; Script:Accept $fx; Script:Approve $fx
                                 # A change to the wave outside its settings: the acceptance
                                 # still holds, the approval does not. WAVE-APPROVE-1: in the
                                 # wave - an approval signs its own wave, so a field added at
                                 # the top of the plan, which this was, no longer voids it.
                                 Script:EditPlan $fx { param($plan) @($plan.entries)[1] | Add-Member -NotePropertyName target -NotePropertyValue ([pscustomobject]@{ size = 'Standard_D4s_v6' }) -Force } }
    }
    $script:seen = @{}
    foreach ($code in $script:cases.Keys) {
        $fx = Script:NewRun
        & $script:cases[$code] $fx
        $script:seen[$code] = Script:Gate $fx
    }
}

AfterAll { Remove-VmfTestTemp }

Describe 'GATE-WORDS-1: every reason the start gate can return' {

    It '<_>: the gate gives this code, and the gate it belongs to' -ForEach @('notAcknowledged', 'acknowledgedByNobody', 'notAccepted', 'changed', 'notApproved', 'approvalOutOfDate') {
        $g = $script:seen[$_]
        $g | Should -Not -BeNullOrEmpty -Because "the fixture for $_ fails a gate"
        $g.Pass | Should -BeFalse
        $g.Code | Should -Be $_
        $g.Gate | Should -Be ([string]$script:words.reasons.$_.gate)
    }

    It '<_>: the sentence is the file''s two sentences, filled in' -ForEach @('notAcknowledged', 'acknowledgedByNobody', 'notAccepted', 'changed', 'notApproved', 'approvalOutOfDate') {
        $r = $script:words.reasons.$_
        $want = ("$($r.missing) $($r.toDo)" -replace '\{wave\}', 'w1') -replace '\{by\}', 'operator@example.com'
        $script:seen[$_].Detail | Should -BeExactly $want
    }

    It '<_>: no command, no lever, no placeholder, a capital letter first and a full stop last' -ForEach @('notAcknowledged', 'acknowledgedByNobody', 'notAccepted', 'changed', 'notApproved', 'approvalOutOfDate') {
        $d = [string]$script:seen[$_].Detail
        $d | Should -Not -Match '\b[A-Z][a-z]+-Vmf[A-Za-z]+' -Because 'a person on the screen cannot run a command (hard rule 12)'
        $d | Should -Not -Match '(?i)\blevers?\b' -Because 'lever is the engine''s word; the screen says settings'
        $d | Should -Not -Match '[{}]'
        $d | Should -Not -Match '(?i)\bwizard\b' -Because 'the migration''s page has the button; the wizard is not where the person is'
        $d | Should -MatchExactly '^[A-Z]'
        $d | Should -Match '\.$'
    }

    It '<_>: two sentences - what is missing, then what to do - each short' -ForEach @('notAcknowledged', 'acknowledgedByNobody', 'notAccepted', 'changed', 'notApproved', 'approvalOutOfDate') {
        $sentences = @(([string]$script:seen[$_].Detail) -split '(?<=[.!?])\s+' | Where-Object { $_ })
        $sentences.Count | Should -Be 2
        @($sentences[0] -split '\s+').Count | Should -BeLessOrEqual 25 -Because 'ASD-STE100, descriptive'
        @($sentences[1] -split '\s+').Count | Should -BeLessOrEqual 20 -Because 'ASD-STE100, instruction'
    }

    It '<_>: the instruction names the button the Migrations page shows for that gate' -ForEach @('notAcknowledged', 'acknowledgedByNobody', 'notAccepted', 'changed', 'notApproved', 'approvalOutOfDate') {
        $r = $script:words.reasons.$_
        $btn = $script:button[[string]$r.gate]
        [string]$r.toDo | Should -Match ("select " + [regex]::Escape($btn) + '\b') -Because "the page's own label is '$btn'"
    }

    It 'the acknowledgement reason does not repeat the statement - the statement is in the dialog the button opens' {
        foreach ($code in 'notAcknowledged', 'acknowledgedByNobody') {
            $d = [string]$script:seen[$code].Detail
            foreach ($s in @($script:statement -split '(?<=\.)\s+' | Where-Object { $_ })) {
                $d.Contains($s) | Should -BeFalse -Because "the refusal said '$s' before it said what to do"
            }
        }
    }

    It 'the file holds exactly the codes the gate gives - none it never gives, none it gives without words' {
        # RESERVE-COVER-1 added the reasons of the capacity gate of a wave set
        # to Reserved (gate 'capacity'). Get-VmfWaveStartGate never gives them;
        # tests/unit/ReserveCover.Tests.ps1 holds the capacity gate to them the
        # same way this file holds the other three.
        # WAVE-APPROVE-1 added signOffOutOfDate: the TIMER's own reason, not
        # Get-VmfWaveStartGate's - a wave changed after the plan was signed off
        # does not start by itself (Test-VmfPlanRunWaveSigned). A person may
        # still start it, so the start gate never gives it;
        # WaveApprovePerWave.Tests.ps1 holds the timer to it.
        @($script:words.reasons.PSObject.Properties | Where-Object { [string]$_.Value.gate -ne 'capacity' -and $_.Name -ne 'signOffOutOfDate' } |
            ForEach-Object Name | Sort-Object) | Should -Be @($script:cases.Keys | Sort-Object)
        # The CODE of the function (Get-VmfCodeOnly), not its whole definition:
        # a comment that names the call cannot pass for it (COMMENT-TRAP-1).
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $signedCode = Get-VmfCodeOnly -Language PowerShell -Text (InModuleScope VmMigrationFactory { (Get-Command Test-VmfPlanRunWaveSigned).Definition })
        $signedCode | Should -Match "New-VmfStartGateRefusal -Code 'signOffOutOfDate'"
        @($script:words.reasons.PSObject.Properties | Where-Object { [string]$_.Value.gate -eq 'capacity' } |
            ForEach-Object Name | Sort-Object) |
            Should -Be @('noQuotaRecord', 'noQuotaRecordGeneral', 'notReservedBesideHeld', 'quotaBlockedBesideHeld', 'quotaShortBesideHeld', 'regionalQuotaShortBesideHeld', 'reservationFailedBesideHeld', 'sizeBlockedBesideHeld', 'quotaShortGeneral', 'regionalQuotaShortGeneral', 'sizeBlockedGeneral', 'quotaBlockedGeneral', 'quotaCheckFailed' | Sort-Object)
    }

    It 'a wave that passes every gate gives nothing' {
        $fx = Script:NewRun
        Script:Ack $fx; Script:Accept $fx; Script:Approve $fx
        Script:Gate $fx | Should -BeNullOrEmpty
    }
}

Describe 'GATE-WORDS-1: every place that shows the reason says it in the same words' {

    It 'the next wave of a signed-off plan: the line the migration''s page shows under the wave' {
        $fx = Script:NewRun
        Script:Ack $fx
        # A second wave, after w1, so w2 is next once w1 is done.
        Script:EditPlan $fx { param($plan)
            $plan.entries = @(@($plan.entries)[0], [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = $script:vm2; wave = 'w2'; path = 'A'
                policy = [pscustomobject]@{ requireApproval = $true; onDDataFound = 'stop' } }) }
        Confirm-VmfWaveOptions -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' -AcceptedBy 'operator@example.com' -Note 'r' -Confirm:$false | Out-Null
        Approve-VmfPlan -RunPath $fx.Run -PlanPath $fx.Plan -Note 'approved' -OnBehalfOf $script:who | Out-Null
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; pp = $fx.Plan; vm = $script:vm1 } {
            New-VmfStateDoc -RunPath $rp -RunId 'gw-test' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'MIGRATED' -Outcome ok | Out-Null
            Get-VmfPlanRunDecision -RunPath $rp -PlanPath $pp
        }
        $d.Reason | Should -Be 'gate'
        $d.Detail | Should -BeExactly ('Wave w2 is next, and it cannot start yet. ' +
            ("$($script:words.reasons.notAccepted.missing) $($script:words.reasons.notAccepted.toDo)" -replace '\{wave\}', 'w2'))
    }

    It 'a refused wave start says the reason first, not "options gate failed" - the page shows only the first sentence' {
        # The approval gate comes after the subscription check, which asks Azure.
        Mock -ModuleName VmMigrationFactory Test-VmfWaveSubscriptions { @{ Pass = $true; Detail = 'one subscription' } }
        foreach ($code in 'notAcknowledged', 'notAccepted', 'notApproved') {
            $fx = Script:NewRun
            & $script:cases[$code] $fx
            $err = $null
            try { Start-VmfWave -RunPath $fx.Run -PlanPath $fx.Plan -Wave 'w1' | Out-Null } catch { $err = "$_" }
            $err | Should -BeExactly ([string]$script:seen[$code].Detail) -Because $code
        }
    }

    It 'a refused retry carries the same reason, and for changed settings logs the line that makes the page offer the acceptance again' {
        $fx = Script:NewRun
        & $script:cases['changed'] $fx
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; vm = $script:vm1 } {
            New-VmfStateDoc -RunPath $rp -RunId 'gw-test' -VmId $vm -Wave 'w1' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $vm -NewState 'FAILED_ROLLED_BACK' -Outcome fail -ReasonCode 'bootFailedAfterConversion' `
                -MachineState 'restored' -Detail 'STARTING failed' | Out-Null
        }
        $err = $null
        try { Resolve-VmfDecision -RunPath $fx.Run -PlanPath $fx.Plan -VmId $script:vm1 -Note 'fixed' -ResolvedBy 'operator@example.com' | Out-Null } catch { $err = "$_" }
        $err | Should -BeExactly "400: Nothing changed for gw1, because wave w1 cannot start. $($script:seen['changed'].Detail) Then try this machine again."
        # The Migrations page offers Review & accept options again only after the
        # engine logs a refusal for changed settings (acceptanceRefused).
        $lines = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } { Read-VmfEvents -RunPath $rp -Step 'acceptance' } |
            Where-Object { $_.outcome -eq 'refused' -and $_.code -eq 'optionsChanged' -and $_.wave -eq 'w1' })
        $lines.Count | Should -Be 1 -Because 'the reason says to select Review & accept options again, so the button must be there'
    }

    It 'the run summary names the gate from the code, the same three names as before' {
        foreach ($code in 'notAcknowledged', 'notAccepted', 'notApproved') {
            $fx = Script:NewRun
            & $script:cases[$code] $fx
            $name = InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; pp = $fx.Plan } {
                Get-VmfRunSummaryGate -RunPath $rp -PlanPath $pp -Plan (Get-Content $pp -Raw | ConvertFrom-Json -Depth 24) -Wave 'w1'
            }
            $name | Should -Be ([string]$script:words.reasons.$code.gate)
        }
    }
}
