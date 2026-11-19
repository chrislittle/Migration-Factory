#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-LEVER-OVERRIDE-1: a wave save undid a machine's own answer.
#
# A decision's answer is written to ONE machine (Resolve-VmfDecision: for
# example onDDataFound = proceed on that plan entry). The wave editor drew a
# wave's card from its FIRST machine and sent all seven settings for every wave
# on every save, and Set-VmfWavePlan wrote each one wherever it differed. So
# after the wave finished, any save of any wave wrote the card's value over the
# machine's answer - or, when the decided machine was first, spread its answer
# to the whole wave - and the write cleared the wave's acceptance and quota
# check, and every approval (WAVE-SAVE-FALSE-1).
#
# Nothing recorded that a value came from a decision, so plan-entry v17 does
# (`decisions`). The page sends what each card shows and which settings the
# person changed on it (`changed`, with the value the card showed); the engine
# writes a setting on a machine that stays only when the person changed it and
# the machine held the value the card showed, a machine joining a wave takes
# its card, and nothing is ever written over a decision. Every machine that
# keeps its own value is named.
#
# The payloads below are what src/dashboard/waves.html sends (writeLayout);
# tests/js/wave-lever-override.test.js proves the page builds them. Both sides
# are held to tests/fixtures/wave-own-settings.json.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    # RETRY-GATE-1: a decision is refused while its wave cannot start, so the
    # gates are opened first, the way a person does.
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'wlo'

    $script:sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines'
    function Script:Id([string]$Name) { "$script:sub/$Name" }
    $script:who = @{ Identity = 'approver@example.com'; TenantId = '00000000-0000-0000-0000-000000000000' }
    $script:defaults = [ordered]@{ capacityGate = 'BestEffort'; requireApproval = $true; onDDataFound = 'stop'
        onDriverBelowFloor = 'stop'; keepSnapshotDays = 7; throttle = 15 }

    function Script:Principal([string[]]$Roles) {
        $claims = @(@{ typ = 'preferred_username'; val = 'lead@example.com' }) + @($Roles | ForEach-Object { @{ typ = 'roles'; val = $_ } })
        $doc = @{ auth_typ = 'aad'; claims = $claims } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }

    # alpha: a1 a2 a3, beta: b1 b2, and x not in a wave. a1 stopped for files
    # on its temporary disk and an approver chose Continue for it alone; then
    # the wave finished. Then every wave was accepted, approved and its quota
    # checked - so a save that voids any of them can be seen.
    function Script:NewRun([hashtable]$Policy = @{}, [scriptblock]$Before) {
        $rp = Join-Path $script:temp "wlo-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $plan = [ordered]@{ schemaVersion = 5; runId = 'wlo'; assessmentRunId = 'wlo-scan'; waveOrder = @('alpha', 'beta'); entries = @(
                foreach ($m in @(@('a1', 'alpha'), @('a2', 'alpha'), @('a3', 'alpha'), @('b1', 'beta'), @('b2', 'beta'), @('x', 'unscheduled'))) {
                    $pol = [ordered]@{ safetyCopy = 'pristine' }
                    foreach ($k in $script:defaults.Keys) { $pol[$k] = $script:defaults[$k] }
                    if ($Policy.ContainsKey($m[0])) { foreach ($k in $Policy[$m[0]].Keys) { $pol[$k] = $Policy[$m[0]][$k] } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (Script:Id $m[0]); wave = $m[1]; path = 'A'
                        assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D2ds_v6' }; policy = $pol }
                }) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; d = $plan } {
            Initialize-VmfRun -RunPath $rp -RunId 'wlo' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $d
        }
        $pp = Join-Path $rp 'plan.json'
        $fx = @{ Run = $rp; Plan = $pp }
        Open-VmfTestWaveGate -RunPath $rp -PlanPath $pp
        Script:Decide $fx 'a1' @{ onDDataFound = 'proceed' }
        if ($Before) { & $Before $fx }
        foreach ($w in 'alpha', 'beta') {
            Confirm-VmfWaveOptions -RunPath $rp -PlanPath $pp -Wave $w -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
            Approve-VmfWave -RunPath $rp -PlanPath $pp -Wave $w -Note 'read and approved' -OnBehalfOf $script:who | Out-Null
            InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; w = $w } {
                Write-VmfStoreJson -RunPath $rp -RelPath "capacity/$w-centralus-d2ds.json" -Depth 12 -Document ([ordered]@{
                    schemaVersion = 8; wave = $w; region = 'centralus'; size = 'Standard_D2ds_v6'; count = 2; state = 'QUOTA_VERIFIED' })
            }
        }
        $fx
    }
    # A real decision, through Resolve-VmfDecision; then the machine finishes.
    # WAVE-APPROVE-1 (the rule, 2026-10-10): an approver accepting the
    # decision the machine waits for - parked for files on the temporary disk,
    # with the approver's role - so the wave approval and the plan sign-off
    # move past it. Any other decision asks again for the wave's approval.
    function Script:Decide($fx, [string]$Name, [hashtable]$Override) {
        $id = Script:Id $Name
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; id = $id } {
            New-VmfStateDoc -RunPath $rp -RunId 'wlo' -VmId $id -Wave 'alpha' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files on the temporary disk' | Out-Null
        }
        Resolve-VmfDecision -RunPath $fx.Run -PlanPath $fx.Plan -VmId $id -PolicyOverride $Override -Note 'the files are not needed' `
            -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; id = $id } {
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
        }
    }
    function Script:Plan($fx) { Get-Content $fx.Plan -Raw | ConvertFrom-Json -Depth 30 }
    function Script:Entry($fx, [string]$Name) { @((Script:Plan $fx).entries | Where-Object { $_.vmId -eq (Script:Id $Name) })[0] }
    function Script:Version($fx) { InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content $fx.Plan -Raw) } { Get-VmfDocumentVersion -Text $t } }
    # One wave as the page sends it: what its card shows, its machines, and the
    # settings the person changed (each with the value the card showed). $null
    # for Changed is a page from before this change, which sends no list.
    function Script:Wave([string]$Name, [string[]]$Machines, [hashtable]$Card = @{}, $Changed = @{}) {
        $w = [ordered]@{ name = $Name }
        # WAVE-KERNEL-LINE-1: the kernel choice is a machine's, never a wave's.
        foreach ($k in @($script:defaults.Keys | Where-Object { $_ -ne 'onDriverBelowFloor' })) { $w[$k] = if ($Card.ContainsKey($k)) { $Card[$k] } else { $script:defaults[$k] } }
        $w.vmIds = @($Machines | ForEach-Object { Script:Id $_ })
        if ($null -ne $Changed) { $w.changed = $Changed }
        $w
    }
    function Script:Save($fx, $Waves, [string[]]$Roles = @('Vmf.Operator', 'Vmf.Approver')) {
        # Through JSON, as a request body arrives.
        $body = @{ waves = @($Waves); planVersion = (Script:Version $fx) } | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        Invoke-VmfFacadeSetWaves -Principal (Script:Principal $Roles) -StorePath $fx.Run -Waves $body.waves -PlanVersion $body.planVersion
    }
    function Script:Approved($fx, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; pp = $fx.Plan; w = $Wave } { (Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave $w).Pass }
    }
    function Script:Accepted($fx, [string]$Wave) {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; w = $Wave } {
            $plan = Read-VmfPlanDocument -RunPath $rp
            (Test-VmfWaveOptionsAccepted -RunPath $rp -Wave $w -Entries @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $w)).Pass
        }
    }
    function Script:QuotaKept($fx, [string]$Wave) { Test-Path (Join-Path $fx.Run 'capacity' "$Wave-centralus-d2ds.json") }
    function Script:LastPlanEvent($fx) {
        $events = InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run } {
            @(Read-VmfStoreLines -RunPath $rp -RelPath 'logs/events.jsonl' | ForEach-Object { $_ | ConvertFrom-Json })
        }
        [string](@($events | Where-Object { $_.step -eq 'plan' })[-1].detail)
    }
}
AfterAll { Remove-VmfTestTemp }

Describe 'WAVE-LEVER-OVERRIDE-1: a decision is recorded on that machine alone' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'records the setting, who decided and when, on that entry only, and raises the entry to the current contract' {
        $a1 = Script:Entry $script:fx 'a1'
        $a1.policy.onDDataFound | Should -Be 'proceed'
        @($a1.decisions).Count | Should -Be 1
        $a1.decisions[0].setting | Should -Be 'onDDataFound'
        $a1.decisions[0].by | Should -Be 'approver@example.com'
        $a1.decisions[0].utc | Should -Not -BeNullOrEmpty
        # It reads back and writes out as the same text, so a later write of
        # the plan does not change it (a fraction with a trailing zero did not).
        $raw = [regex]::Match((Get-Content $script:fx.Plan -Raw), '"utc":\s*"([^"]+)"').Groups[1].Value
        $raw | Should -Match '^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$'
        (@{ utc = $raw } | ConvertTo-Json | ConvertFrom-Json | ConvertTo-Json -Compress) | Should -Be "{`"utc`":`"$raw`"}"
        $a1.schemaVersion | Should -Be (InModuleScope VmMigrationFactory { Get-VmfPlanSchemaVersion })
        foreach ($n in 'a2', 'a3', 'b1') { (Script:Entry $script:fx $n).PSObject.Properties['decisions'] | Should -BeNullOrEmpty }
        # The record is valid against the contract the entry now says it is:
        # the sample entry, carrying a1's record.
        $sample = Get-Content (Join-Path $script:repoRoot 'schemas' 'samples' 'plan-entry.sample.json') -Raw | ConvertFrom-Json -Depth 30
        $sample.decisions = $a1.decisions
        ($sample | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $script:repoRoot 'schemas' 'plan-entry.schema.json') | Should -BeTrue
    }

    It 'the same decision again keeps its record; another setting adds one; another value replaces it' {
        # WAVE-APPROVE-1 (the rule, 2026-10-10): a decision that changes
        # the plan and is not an approver's acceptance saves the change and asks
        # again for the wave's approval (-Refused). An approver then approves the
        # wave again, as a person does. Before, every one of these went through.
        $again = {
            param([hashtable]$Override, [string]$By, [switch]$Refused)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'again' | Out-Null
            }
            $call = { Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath $script:fx.Plan -VmId (Script:Id 'a1') `
                -PolicyOverride $Override -Note 'again' -ResolvedBy $By | Out-Null }
            if ($Refused) {
                $call | Should -Throw '400:*wave alpha cannot start now*Nobody approved wave alpha*'
                Approve-VmfWave -RunPath $script:fx.Run -PlanPath $script:fx.Plan -Wave 'alpha' -Note 'approved again' -OnBehalfOf $script:who | Out-Null
            }
            else { & $call }
        }
        # The same answer again: the record stays as it was, so the plan text
        # does not change for it (an approval signs that text - RETRY-GATE-1).
        # AN-PROCEED-NETVSC-1: the driver floor's only value is stop now.
        & $again @{ onDDataFound = 'proceed'; onDriverBelowFloor = 'stop' } 'second@example.com' -Refused
        $a1 = Script:Entry $script:fx 'a1'
        @($a1.decisions | ForEach-Object { $_.setting } | Sort-Object) | Should -Be @('onDDataFound', 'onDriverBelowFloor')
        @($a1.decisions | Where-Object { $_.setting -eq 'onDDataFound' }).by | Should -Be 'approver@example.com'
        @($a1.decisions | Where-Object { $_.setting -eq 'onDriverBelowFloor' }).by | Should -Be 'second@example.com'
        # Each setting alone, so whichever is not last in the policy is asked
        # too: writing the same answer used to move it to the end.
        foreach ($s in @(@{ onDDataFound = 'proceed' }, @{ onDriverBelowFloor = 'stop' })) {
            $text = Get-Content $script:fx.Plan -Raw
            & $again $s 'third@example.com'
            Get-Content $script:fx.Plan -Raw | Should -BeExactly $text -Because "the same decision again for $s writes nothing new"
        }
        # Another value: a new decision, so a new record.
        & $again @{ onDDataFound = 'stop' } 'fourth@example.com' -Refused
        @((Script:Entry $script:fx 'a1').decisions | Where-Object { $_.setting -eq 'onDDataFound' }).by | Should -Be 'fourth@example.com'
        @((Script:Entry $script:fx 'a1').decisions).Count | Should -Be 2
    }

    It 'a retry with no setting change records nothing' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; id = (Script:Id 'a2') } {
            New-VmfStateDoc -RunPath $rp -RunId 'wlo' -VmId $id -Wave 'alpha' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'x' | Out-Null
        }
        Resolve-VmfDecision -RunPath $script:fx.Run -PlanPath $script:fx.Plan -VmId (Script:Id 'a2') -Note 'fixed' -ResolvedBy 'approver@example.com' | Out-Null
        (Script:Entry $script:fx 'a2').PSObject.Properties['decisions'] | Should -BeNullOrEmpty
    }

    It 'the record is not part of what a wave acceptance is bound to - the value is' {
        InModuleScope VmMigrationFactory {
            $e = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'v'; policy = [pscustomobject]@{ onDDataFound = 'proceed' } }
            $d = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = 'v'; policy = [pscustomobject]@{ onDDataFound = 'proceed' }; decisions = @([pscustomobject]@{ setting = 'onDDataFound'; by = 'x'; utc = 'y' }) }
            Get-VmfWaveOptionsHash -Entries @($d) | Should -Be (Get-VmfWaveOptionsHash -Entries @($e))
        }
    }
}

Describe 'WAVE-LEVER-OVERRIDE-1: a wave save never writes over a machine''s own answer' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'the page''s save with nothing changed writes nothing: a1 keeps Continue and every check stays' {
        $before = Get-Content $script:fx.Plan -Raw
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2'))
        $r.Unchanged | Should -BeTrue
        @($r.KeptOwnSettings) | Should -BeNullOrEmpty -Because 'nothing was changed, so nothing was kept from a change'
        Get-Content $script:fx.Plan -Raw | Should -BeExactly $before
        (Script:Entry $script:fx 'a1').policy.onDDataFound | Should -Be 'proceed'
        foreach ($w in 'alpha', 'beta') {
            Script:Approved $script:fx $w | Should -BeTrue
            Script:Accepted $script:fx $w | Should -BeTrue
            Script:QuotaKept $script:fx $w | Should -BeTrue
        }
    }

    It 'the page''s save with another wave changed: a1 keeps its answer, and alpha keeps its acceptance and quota check' {
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2' @{ throttle = 5 } @{ throttle = 15 }))
        (Script:Entry $script:fx 'a1').policy.onDDataFound | Should -Be 'proceed'
        foreach ($n in 'b1', 'b2') { (Script:Entry $script:fx $n).policy.throttle | Should -Be 5 }
        @($r.AcceptancesCleared) | Should -Be @('beta')
        @($r.CapacityChecksCleared) | Should -Be @('beta')
        Script:Accepted $script:fx 'alpha' | Should -BeTrue -Because 'no setting of alpha was written'
        Script:QuotaKept $script:fx 'alpha' | Should -BeTrue
        # WAVE-APPROVE-1: rewritten. An approval signed the WHOLE plan text, so
        # this pinned alpha's approval asked for again. An approval now signs
        # its own wave, so a change to beta keeps alpha's, and says nothing.
        Script:Approved $script:fx 'alpha' | Should -BeTrue
        Script:LastPlanEvent $script:fx | Should -Not -Match ([regex]::Escape('The approval of wave alpha'))
        Script:LastPlanEvent $script:fx | Should -Not -Match 'In wave alpha, the setting'
    }

    It 'a page from before this change - every setting, no list of changes - still keeps a1''s answer, and names it' {
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Changed $null), (Script:Wave 'beta' 'b1', 'b2' -Changed $null))
        (Script:Entry $script:fx 'a1').policy.onDDataFound | Should -Be 'proceed'
        $r.Unchanged | Should -BeTrue
        @($r.KeptOwnSettings).Count | Should -Be 1
        $r.KeptOwnSettings[0].Machine | Should -Be 'a1'
        $r.KeptOwnSettings[0].Setting | Should -Be 'onDDataFound'
        $r.KeptOwnSettings[0].Reason | Should -Be 'decision'
        Script:Approved $script:fx 'alpha' | Should -BeTrue
        Script:LastPlanEvent $script:fx | Should -Match ([regex]::Escape("In wave alpha, machine a1 does not follow the setting 'If files are found on the temporary disk'. A decision for that machine set its value."))
    }

    It 'STEP-LOG-4: a save that changes nothing stays a throwing write - its line is all it writes, so a lost line is an error, and nothing changes' {
        $before = Get-Content $script:fx.Plan -Raw
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'plan' } { throw 'The store did not answer.' }
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Changed $null), (Script:Wave 'beta' 'b1', 'b2' -Changed $null)) } |
            Should -Throw '*The store did not answer.*'
        Get-Content $script:fx.Plan -Raw | Should -BeExactly $before
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'plan' } -Times 1 -Exactly
    }

    It 'a change on the card writes every machine without its own value, and names the ones that keep theirs' {
        # a1 decided the snapshot days too (the same 7 the wave has); a3 holds
        # 14, set by hand. The card shows 7, from a2.
        $fx = Script:NewRun -Policy @{ a3 = @{ keepSnapshotDays = 14 } } -Before {
            param($f)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'again' | Out-Null
            }
            # WAVE-APPROVE-1: another setting is not the decision the machine
            # waits for, so it is saved and the wave asks again for its
            # approval (NewRun approves each wave again after this block).
            { Resolve-VmfDecision -RunPath $f.Run -PlanPath $f.Plan -VmId (Script:Id 'a1') -PolicyOverride @{ keepSnapshotDays = 7 } `
                -Note 'keep a week' -ResolvedBy 'approver@example.com' } | Should -Throw '400:*wave alpha cannot start now*'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
        }
        $r = Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ keepSnapshotDays = 30 } @{ keepSnapshotDays = 7 }), (Script:Wave 'beta' 'b1', 'b2'))
        (Script:Entry $fx 'a2').policy.keepSnapshotDays | Should -Be 30
        (Script:Entry $fx 'a1').policy.keepSnapshotDays | Should -Be 7 -Because 'a decision set it, even to the value the wave had'
        (Script:Entry $fx 'a3').policy.keepSnapshotDays | Should -Be 14 -Because 'it held another value than the card showed'
        @($r.KeptOwnSettings | ForEach-Object { "$($_.Machine):$($_.Reason)" } | Sort-Object) | Should -Be @('a1:decision', 'a3:own')
        $said = Script:LastPlanEvent $fx
        $said | Should -Match ([regex]::Escape("In wave alpha, the setting 'How long the snapshot is kept' changed from 7 days to 30 days."))
        $said | Should -Match ([regex]::Escape("In wave alpha, machine a1 does not follow the setting 'How long the snapshot is kept'. A decision for that machine set its value."))
        $said | Should -Match ([regex]::Escape("In wave alpha, machine a3 does not follow the setting 'How long the snapshot is kept'. Its value was different from the value of the wave."))
        @($r.AcceptancesCleared) | Should -Be @('alpha')
    }

    It 'when every machine named keeps its own value, nothing is written, every check stays, and the activity says so' {
        # A wave whose every machine decided Continue for itself. The card shows
        # Continue; the person changes it to Stop and ask.
        $fx2 = Script:NewRun -Policy @{ a2 = @{ onDDataFound = 'proceed' }; a3 = @{ onDDataFound = 'proceed' } } -Before {
            param($f)
            foreach ($n in 'a2', 'a3') {
                InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id $n) } {
                    New-VmfStateDoc -RunPath $rp -RunId 'wlo' -VmId $id -Wave 'alpha' | Out-Null
                    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -ReasonCode 'dataOnTempDrive' -Detail 'files' | Out-Null
                }
                Resolve-VmfDecision -RunPath $f.Run -PlanPath $f.Plan -VmId (Script:Id $n) -PolicyOverride @{ onDDataFound = 'proceed' } `
                    -Note 'not needed' -ResolvedBy 'approver@example.com' -ResolvedRoles @('Vmf.Approver') | Out-Null
                InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id $n) } {
                    Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
                }
            }
        }
        $before = Get-Content $fx2.Plan -Raw
        $r = Script:Save $fx2 @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ onDDataFound = 'stop' } @{ onDDataFound = 'proceed' }), (Script:Wave 'beta' 'b1', 'b2'))
        $r.Unchanged | Should -BeTrue
        Get-Content $fx2.Plan -Raw | Should -BeExactly $before
        @($r.KeptOwnSettings | ForEach-Object { $_.Machine } | Sort-Object) | Should -Be @('a1', 'a2', 'a3')
        Script:Approved $fx2 'alpha' | Should -BeTrue
        Script:Accepted $fx2 'alpha' | Should -BeTrue
        Script:QuotaKept $fx2 'alpha' | Should -BeTrue
        Script:LastPlanEvent $fx2 | Should -Match ([regex]::Escape("no setting changed. In wave alpha, machines a1, a2, a3 do not follow the setting 'If files are found on the temporary disk'. A decision for each machine set its value."))
    }

    It 'a machine joining a wave takes its card, but not over its own answer' {
        $fx = Script:NewRun -Policy @{ b1 = @{ throttle = 5 }; b2 = @{ throttle = 5 }; x = @{ onDDataFound = 'proceed' } } -Before {
            param($f)
            # x has not started, and a decision for it is on record - written
            # into the plan the way Resolve-VmfDecision writes it.
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'x') } {
                $plan = Read-VmfPlanDocument -RunPath $rp
                $e = @($plan.entries | Where-Object { $_.vmId -eq $id })[0]
                Set-VmfOwnDecision -PlanEntry $e -Setting 'onDDataFound' -By 'approver@example.com' -Confirm:$false
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document $plan
            }
        }
        $r = Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2', 'x' @{ throttle = 5 }))
        $x = Script:Entry $fx 'x'
        $x.wave | Should -Be 'beta'
        $x.policy.throttle | Should -Be 5 -Because 'a machine joining a wave takes its card'
        $x.policy.onDDataFound | Should -Be 'proceed' -Because 'a decision for the machine travels with it'
        @($r.KeptOwnSettings | ForEach-Object { "$($_.Machine):$($_.Setting)" }) | Should -Be @('x:onDDataFound')
    }
}

Describe 'WAVE-LEVER-OVERRIDE-1: the service judges what will be written' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'an operator saves another wave while a1 holds a decided Continue: not refused, and nothing in alpha changes' {
        # The old page drew alpha from a1 (Continue) and sent Continue for the
        # whole wave, so a2 and a3 were "decided" - and an operator renaming
        # beta was refused as if accepting a loss for them.
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2' @{ throttle = 30 } @{ throttle = 15 })) -Roles 'Vmf.Operator'
        $r.Unchanged | Should -BeFalse
        foreach ($n in 'a2', 'a3') { (Script:Entry $script:fx $n).policy.onDDataFound | Should -Be 'stop' }
    }

    It 'an operator who changes a gate to Continue on a card is still refused' {
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ onDDataFound = 'proceed' } @{ onDDataFound = 'stop' }), (Script:Wave 'beta' 'b1', 'b2')) -Roles 'Vmf.Operator' } |
            Should -Throw '403*'
    }

    It 'an operator who moves a machine into a wave whose card has no sign-off is still refused' {
        $fx = Script:NewRun -Policy @{ b1 = @{ requireApproval = $false }; b2 = @{ requireApproval = $false } }
        { Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2'), (Script:Wave 'beta' 'b1', 'b2', 'a3' @{ requireApproval = $false })) -Roles 'Vmf.Operator' } |
            Should -Throw '403*'
    }

    It 'a list of changes that names a value the machines do not hold writes nothing, and asks no approver' {
        # beta holds Stop and ask. A request that says its card showed Continue
        # and asks for Continue writes nothing - the safe direction.
        $before = Get-Content $script:fx.Plan -Raw
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2' @{ onDDataFound = 'proceed' } @{ onDDataFound = 'proceed' })) -Roles 'Vmf.Operator'
        $r.Unchanged | Should -BeTrue
        Get-Content $script:fx.Plan -Raw | Should -BeExactly $before
        @($r.KeptOwnSettings | ForEach-Object { "$($_.Machine):$($_.Reason)" } | Sort-Object) | Should -Be @('b1:own', 'b2:own')
    }

    It 'a list of changes naming a setting a wave does not have is refused by name' {
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Changed @{ targetSize = 'x' })) } | Should -Throw "*'targetSize' is not a setting of a wave*"
    }
}

Describe 'WAVE-LEVER-OVERRIDE-1 review: a setting of the wave is one value for the wave' {
    # Review finding 1. The engine reads ONE value for the wave - the capacity
    # gate from its first machine, how many at once from the first machine with
    # one, the sign-off from any machine - so a machine "keeping its own" value
    # of one of these left the card saying 10 at once while the wave ran 3.
    It 'a change of how many at once writes every machine, even one that held another value' {
        $fx = Script:NewRun -Policy @{ a1 = @{ throttle = 5 } }
        $r = Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ throttle = 30 } @{ throttle = 15 }), (Script:Wave 'beta' 'b1', 'b2'))
        foreach ($n in 'a1', 'a2', 'a3') { (Script:Entry $fx $n).policy.throttle | Should -Be 30 }
        @($r.KeptOwnSettings) | Should -BeNullOrEmpty
    }

    It 'a decision for a setting of the wave is not recorded, so the wave can change it' {
        $fx = Script:NewRun -Before {
            param($f)
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'again' | Out-Null
            }
            # WAVE-APPROVE-1: saved, and the wave asks again for its approval.
            { Resolve-VmfDecision -RunPath $f.Run -PlanPath $f.Plan -VmId (Script:Id 'a1') -PolicyOverride @{ throttle = 5 } `
                -Note 'slower' -ResolvedBy 'approver@example.com' } | Should -Throw '400:*wave alpha cannot start now*'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
        }
        @((Script:Entry $fx 'a1').decisions | ForEach-Object { $_.setting }) | Should -Be @('onDDataFound')
        Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ throttle = 60 } @{ throttle = 15 }), (Script:Wave 'beta' 'b1', 'b2')) | Out-Null
        (Script:Entry $fx 'a1').policy.throttle | Should -Be 60
        (Script:Entry $fx 'a1').policy.onDDataFound | Should -Be 'proceed' -Because 'its own answer for the temporary disk still stands'
    }
}

Describe 'WAVE-LEVER-OVERRIDE-1 review: the service judges the plan it saves' {
    # Review finding 2. With no plan version from the page, the service judged
    # the role checks on one read and the writer read again - a plan written in
    # between gave a write nobody judged. Now the judged version goes to the
    # writer, and a page that read another plan gets 409, not a 403 about a
    # plan it never saw.
    It 'a page that read another plan is told the plan changed (409)' {
        $fx = Script:NewRun
        # A change the CURRENT plan would refuse an operator (Continue on a
        # gate): the answer must be the 409, before any role check is made on
        # a plan this page never read.
        $body = @{ waves = @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2' @{ onDDataFound = 'proceed' } @{ onDDataFound = 'stop' })) } | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        { Invoke-VmfFacadeSetWaves -Principal (Script:Principal 'Vmf.Operator') -StorePath $fx.Run -Waves $body.waves -PlanVersion 'not-the-plan' } | Should -Throw '409*'
    }

    It 'with no version from the page, the writer is held to the plan the service judged' {
        $fx = Script:NewRun
        Mock -ModuleName FacadeCore Set-VmfWavePlan { $script:expected = $ExpectedPlanVersion; [pscustomobject]@{ Unchanged = $true } }
        $body = @{ waves = @((Script:Wave 'alpha' 'a1', 'a2', 'a3'), (Script:Wave 'beta' 'b1', 'b2')) } | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        Invoke-VmfFacadeSetWaves -Principal (Script:Principal 'Vmf.Operator') -StorePath $fx.Run -Waves $body.waves -PlanVersion '' | Out-Null
        $script:expected | Should -Be (Script:Version $fx)
    }
}
Describe 'WAVE-LEVER-OVERRIDE-1: the engine keeps the machines the card names (one fixture for both sides)' {
    BeforeDiscovery {
        $fixture = Get-Content (Join-Path $PSScriptRoot '..' 'fixtures' 'wave-own-settings.json') -Raw | ConvertFrom-Json -Depth 20
        $script:cases = @($fixture.cases | ForEach-Object { @{ Case = $_; Wave = $fixture.wave } })
    }

    It '<Case.name>' -ForEach $script:cases {
        $entries = @($Case.entries | ForEach-Object {
                $e = [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$($_.name)"; wave = $Wave; policy = $_.policy }
                if ($_.PSObject.Properties['decisions']) { $e | Add-Member -NotePropertyName decisions -NotePropertyValue $_.decisions }
                $e
            })
        $field = $Case.change.field
        $layout = @{ waves = @(@{ name = $Wave; vmIds = @($entries.vmId); $field = $Case.change.to; changed = @{ $field = $Case.card.$field } }) }
        $judged = InModuleScope VmMigrationFactory -Parameters @{ e = $entries; l = $layout } {
            Get-VmfWaveSettingWrites -Entries $e -Waves @(ConvertTo-VmfWaveLayout -Layout $l)
        }
        $written = @($judged.Writes | ForEach-Object { $_.Machine } | Sort-Object)
        $written | Should -Be @($Case.writes | Sort-Object)
        @($judged.Kept | ForEach-Object { $_.Machine } | Sort-Object) | Should -Be @($Case.kept | Sort-Object)
        # The card's promise: no machine it names as holding its own value is written.
        foreach ($m in @($Case.own.$field)) { $written | Should -Not -Contain $m }
    }
}
