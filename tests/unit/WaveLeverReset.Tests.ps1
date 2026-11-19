#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-LEVER-RESET-1: a machine with its own value for a setting gets the value
# of its wave back from the wave editor.
#
# WAVE-LEVER-OVERRIDE-1 made a decision for one machine stand against every
# later save of its wave, and a value set by hand stay when the card changes.
# Nothing gave such a machine the value of its wave again: the only way was to
# plan it again. The wave editor now sends, for each wave, the machines the
# person reset for a setting (`reset`: setting -> machines). The engine writes
# the card's value on each of them and removes the decision record for that
# setting - through the same save, so every rule of a save holds: the version
# the page read (PLANVER-2, PLAN-WRITE-RACE-1), the refusal for a running wave
# (WAVE-EDIT-RUNNING-1), the role checks on what is written (DECIDE-2), and a
# changed wave loses its acceptance, quota check and approval.
#
# The payloads below are what src/dashboard/waves.html sends (writeLayout);
# tests/js/wave-lever-reset.test.js proves the page builds them.
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_WaveGate.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'wlr'

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

    # alpha: a1 a2 a3, beta: b1 b2. a1 stopped for files on its temporary disk
    # and an approver chose Continue for it alone; then it finished. Every wave
    # is then accepted, approved and its quota checked.
    function Script:NewRun([hashtable]$Policy = @{}, [scriptblock]$Before) {
        $rp = Join-Path $script:temp "wlr-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $plan = [ordered]@{ schemaVersion = 5; runId = 'wlr'; assessmentRunId = 'wlr-scan'; waveOrder = @('alpha', 'beta'); entries = @(
                foreach ($m in @(@('a1', 'alpha'), @('a2', 'alpha'), @('a3', 'alpha'), @('b1', 'beta'), @('b2', 'beta'))) {
                    $pol = [ordered]@{ safetyCopy = 'pristine' }
                    foreach ($k in $script:defaults.Keys) { $pol[$k] = $script:defaults[$k] }
                    if ($Policy.ContainsKey($m[0])) { foreach ($k in $Policy[$m[0]].Keys) { $pol[$k] = $Policy[$m[0]][$k] } }
                    [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = (Script:Id $m[0]); wave = $m[1]; path = 'A'
                        assessment = [ordered]@{ location = 'centralus' }; target = [ordered]@{ size = 'Standard_D2ds_v6' }; policy = $pol }
                }) }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; d = $plan } {
            Initialize-VmfRun -RunPath $rp -RunId 'wlr' | Out-Null
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
    function Script:Decide($fx, [string]$Name, [hashtable]$Override) {
        $id = Script:Id $Name
        InModuleScope VmMigrationFactory -Parameters @{ rp = $fx.Run; id = $id } {
            if (-not (Read-VmfStateDoc -RunPath $rp -VmId $id -ErrorAction SilentlyContinue)) { New-VmfStateDoc -RunPath $rp -RunId 'wlr' -VmId $id -Wave 'alpha' | Out-Null }
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
    function Script:Settings($e) { @(if ($e.PSObject.Properties['decisions']) { @($e.decisions) | ForEach-Object { [string]$_.setting } }) }
    function Script:Version($fx) { InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content $fx.Plan -Raw) } { Get-VmfDocumentVersion -Text $t } }
    # One wave as the page sends it: what its card shows, its machines, the
    # settings the person changed, and the machines reset to the wave's value.
    function Script:Wave([string]$Name, [string[]]$Machines, [hashtable]$Card = @{}, [hashtable]$Reset = $null) {
        $w = [ordered]@{ name = $Name }
        # WAVE-KERNEL-LINE-1: the kernel choice is a machine's, never a wave's.
        foreach ($k in @($script:defaults.Keys | Where-Object { $_ -ne 'onDriverBelowFloor' })) { $w[$k] = if ($Card.ContainsKey($k)) { $Card[$k] } else { $script:defaults[$k] } }
        $w.vmIds = @($Machines | ForEach-Object { Script:Id $_ })
        $w.changed = @{}
        if ($null -ne $Reset) {
            $r = [ordered]@{}
            foreach ($k in $Reset.Keys) { $r[$k] = @($Reset[$k] | ForEach-Object { Script:Id $_ }) }
            $w.reset = $r
        }
        $w
    }
    function Script:Save($fx, $Waves, [string[]]$Roles = @('Vmf.Operator', 'Vmf.Approver')) {
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

Describe 'WAVE-LEVER-RESET-1: a reset gives a machine the value of its wave' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'a1 gets Stop and ask, its decision record goes, and alpha loses its acceptance, quota check and approval' {
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('a1') }), (Script:Wave 'beta' 'b1', 'b2'))
        $a1 = Script:Entry $script:fx 'a1'
        $a1.policy.onDDataFound | Should -Be 'stop'
        Script:Settings $a1 | Should -Not -Contain 'onDDataFound'
        $r.Unchanged | Should -BeFalse
        @($r.KeptOwnSettings) | Should -BeNullOrEmpty -Because 'the machine reset is not a machine that kept its own value'
        @($r.ResetToWave | ForEach-Object { "$($_.Machine):$($_.Setting):$($_.Value)" }) | Should -Be @('a1:onDDataFound:stop')
        @($r.AcceptancesCleared) | Should -Be @('alpha')
        @($r.CapacityChecksCleared) | Should -Be @('alpha')
        @($r.ApprovalsInvalidated) | Should -Contain 'alpha'
        Script:Accepted $script:fx 'alpha' | Should -BeFalse
        Script:Approved $script:fx 'alpha' | Should -BeFalse
        # beta did not change, so it keeps everything.
        Script:Accepted $script:fx 'beta' | Should -BeTrue
        Script:Approved $script:fx 'beta' | Should -BeTrue
        Script:QuotaKept $script:fx 'beta' | Should -BeTrue
        foreach ($n in 'a2', 'a3') { (Script:Entry $script:fx $n).policy.onDDataFound | Should -Be 'stop' }
        Script:LastPlanEvent $script:fx | Should -Match ([regex]::Escape(
            "In wave alpha, machine a1 now uses the setting of its wave for 'If files are found on the temporary disk': Stop and ask. A decision for that machine had set Continue."))
    }

    It 'a decision with the same value as the wave: the record goes, the value stays, and the wave changed' {
        $fx = Script:NewRun -Before {
            param($f)
            # WAVE-APPROVE-1: another setting is not the decision the machine
            # waits for, so it is saved and the wave asks again for approval
            # (NewRun approves each wave again after this block).
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'NEEDS_DECISION' -Outcome ok -Detail 'again' | Out-Null
            }
            { Resolve-VmfDecision -RunPath $f.Run -PlanPath $f.Plan -VmId (Script:Id 'a1') -PolicyOverride @{ keepSnapshotDays = 7 } `
                -Note 'keep a week' -ResolvedBy 'approver@example.com' } | Should -Throw '400:*wave alpha cannot start now*'
            InModuleScope VmMigrationFactory -Parameters @{ rp = $f.Run; id = (Script:Id 'a1') } {
                Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
        }
        @(Script:Settings (Script:Entry $fx 'a1') | Sort-Object) | Should -Be @('keepSnapshotDays', 'onDDataFound')
        $r = Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ keepSnapshotDays = @('a1') }), (Script:Wave 'beta' 'b1', 'b2'))
        $a1 = Script:Entry $fx 'a1'
        $a1.policy.keepSnapshotDays | Should -Be 7
        @(Script:Settings $a1) | Should -Be @('onDDataFound') -Because 'only the record of the setting reset goes'
        $a1.policy.onDDataFound | Should -Be 'proceed' -Because 'another setting keeps its own value'
        $r.Unchanged | Should -BeFalse
        @($r.AcceptancesCleared) | Should -Be @('alpha')
        Script:Approved $fx 'alpha' | Should -BeFalse
        Script:LastPlanEvent $fx | Should -Match ([regex]::Escape(
            "In wave alpha, machine a1 now uses the setting of its wave for 'How long the snapshot is kept': 7 days. A decision for that machine had set 7 days."))
        # And now a change on the card reaches a1 for that setting.
        Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ keepSnapshotDays = 30 }) | ForEach-Object { $_.changed = @{ keepSnapshotDays = 7 }; $_ }) | Out-Null
        (Script:Entry $fx 'a1').policy.keepSnapshotDays | Should -Be 30
    }

    It 'the last record goes: an entry with no decision left has no decisions field' {
        Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('a1') })) | Out-Null
        (Script:Entry $script:fx 'a1').PSObject.Properties['decisions'] | Should -BeNullOrEmpty
    }

    It 'a value set by hand: the machine gets the value the card shows' {
        $fx = Script:NewRun -Policy @{ a3 = @{ keepSnapshotDays = 14 } }
        $order = @((Script:Entry $fx 'a3').policy.PSObject.Properties.Name)
        $order[-1] | Should -Not -Be 'keepSnapshotDays' -Because 'the order is asked of a value that is not last'
        $r = Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ keepSnapshotDays = @('a3') }), (Script:Wave 'beta' 'b1', 'b2'))
        (Script:Entry $fx 'a3').policy.keepSnapshotDays | Should -Be 7
        # Written in its place: Add-Member -Force moves a value to the end of
        # the policy, and the text changed by order alone (WAVE-LEVER-OVERRIDE-1).
        @((Script:Entry $fx 'a3').policy.PSObject.Properties.Name) | Should -Be $order
        Script:LastPlanEvent $fx | Should -Match ([regex]::Escape(
            "In wave alpha, machine a3 now uses the setting of its wave for 'How long the snapshot is kept': 7 days. It had 14 days."))
        @($r.ResetToWave | ForEach-Object { $_.Machine }) | Should -Be @('a3')
    }

    It 'a reset and a change on the same card: the machine gets the new value of the card' {
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ keepSnapshotDays = 30 } -Reset @{ keepSnapshotDays = @('a1') }) |
                ForEach-Object { $_.changed = @{ keepSnapshotDays = 7 }; $_ })
        foreach ($n in 'a1', 'a2', 'a3') { (Script:Entry $script:fx $n).policy.keepSnapshotDays | Should -Be 30 }
        @($r.ResetToWave | ForEach-Object { $_.Machine }) | Should -Be @('a1')
    }

    It 'a reset of a machine that already has the value of the wave, and no decision, writes nothing' {
        $before = Get-Content $script:fx.Plan -Raw
        $r = Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ keepSnapshotDays = @('a2') }), (Script:Wave 'beta' 'b1', 'b2'))
        $r.Unchanged | Should -BeTrue
        Get-Content $script:fx.Plan -Raw | Should -BeExactly $before
        Script:Accepted $script:fx 'alpha' | Should -BeTrue
        Script:Approved $script:fx 'alpha' | Should -BeTrue
    }

    It 'Set-VmfWavePlan takes a reset from the command line too' {
        $layout = @{ waves = @(@{ name = 'alpha'; vmIds = @('a1', 'a2', 'a3' | ForEach-Object { Script:Id $_ }); onDDataFound = 'stop'; reset = @{ onDDataFound = @(Script:Id 'a1') } }) }
        Set-VmfWavePlan -RunPath $script:fx.Run -PlanPath $script:fx.Plan -Layout $layout -ChangedBy 'lead@example.com' -Confirm:$false | Out-Null
        $a1 = Script:Entry $script:fx 'a1'
        $a1.policy.onDDataFound | Should -Be 'stop'
        Script:Settings $a1 | Should -Not -Contain 'onDDataFound'
    }
}

Describe 'WAVE-LEVER-RESET-1: the rules of a save hold for a reset' {
    BeforeEach { $script:fx = Script:NewRun }

    It 'a running wave is refused, and nothing is written (WAVE-EDIT-RUNNING-1)' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:fx.Run; id = (Script:Id 'a2') } {
            New-VmfStateDoc -RunPath $rp -RunId 'wlr' -VmId $id -Wave 'alpha' | Out-Null
            Add-VmfStateTransition -RunPath $rp -VmId $id -NewState 'PRECHECK' -Outcome ok | Out-Null
        }
        $before = Get-Content $script:fx.Plan -Raw
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('a1') }), (Script:Wave 'beta' 'b1', 'b2')) } |
            Should -Throw '400: Wave alpha is running*'
        Get-Content $script:fx.Plan -Raw | Should -BeExactly $before
    }

    It 'a page that read another plan is refused (409), and nothing is written (PLANVER-2)' {
        $before = Get-Content $script:fx.Plan -Raw
        $body = @{ waves = @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('a1') })) } | ConvertTo-Json -Depth 8 | ConvertFrom-Json -AsHashtable
        { Invoke-VmfFacadeSetWaves -Principal (Script:Principal 'Vmf.Operator', 'Vmf.Approver') -StorePath $script:fx.Run -Waves $body.waves -PlanVersion 'not-the-plan' } | Should -Throw '409*'
        Get-Content $script:fx.Plan -Raw | Should -BeExactly $before
    }

    It 'a reset to Continue accepts a loss: an operator is refused, an approver is not (DECIDE-2)' {
        # a2 holds Continue and a3 Stop and ask, by hand. The card shows the
        # first of the machines with no decision: Continue. a3 keeps its own.
        $fx = Script:NewRun -Policy @{ a2 = @{ onDDataFound = 'proceed' } }
        $waves = @((Script:Wave 'alpha' 'a1', 'a2', 'a3' @{ onDDataFound = 'proceed' } -Reset @{ onDDataFound = @('a3') }), (Script:Wave 'beta' 'b1', 'b2'))
        { Script:Save $fx $waves -Roles 'Vmf.Operator' } | Should -Throw '403*'
        (Script:Entry $fx 'a3').policy.onDDataFound | Should -Be 'stop'
        Script:Save $fx $waves | Out-Null
        (Script:Entry $fx 'a3').policy.onDDataFound | Should -Be 'proceed'
    }

    It 'a reset to Stop and ask takes nothing away: an operator may do it' {
        Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('a1') })) -Roles 'Vmf.Operator' | Out-Null
        (Script:Entry $script:fx 'a1').policy.onDDataFound | Should -Be 'stop'
    }
}

Describe 'WAVE-LEVER-RESET-1: a reset the engine cannot act on is refused by name, before anything is written' {
    BeforeEach { $script:fx = Script:NewRun; $script:before = Get-Content $script:fx.Plan -Raw }
    AfterEach { Get-Content $script:fx.Plan -Raw | Should -BeExactly $script:before }

    It 'a setting of the whole wave' {
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ throttle = @('a1') })) } |
            Should -Throw "*'How many machines at once' is one setting for the whole wave, so every machine of wave 'alpha' uses the setting of its wave.*"
    }
    It 'a setting a wave does not have' {
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ targetSize = @('a1') })) } |
            Should -Throw "*'targetSize' is not a setting of a wave, so no machine of wave 'alpha' can use the setting of its wave for it. The settings are:*"
    }
    It 'a machine that is not in the wave' {
        { Script:Save $script:fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('b1') }), (Script:Wave 'beta' 'b1', 'b2')) } |
            Should -Throw "*Machine b1 is not in wave alpha, so it cannot use the setting of that wave for 'onDDataFound'.*"
    }
    It 'a wave that does not say its value for the setting' {
        $w = Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDDataFound = @('a1') }
        $w.Remove('onDDataFound')
        { Script:Save $script:fx @($w) } | Should -Throw "*Wave alpha does not send its value for 'onDDataFound', so no machine can use the setting of its wave. Send the value of the wave with the change.*"
    }
    It 'a machine that updates its kernel: no wave has a kernel setting to give it (WAVE-KERNEL-LINE-1)' {
        $fx = Script:NewRun -Policy @{ a3 = @{ onDriverBelowFloor = 'updateKernel' } }
        $script:fx = $fx; $script:before = Get-Content $fx.Plan -Raw
        { Script:Save $fx @((Script:Wave 'alpha' 'a1', 'a2', 'a3' -Reset @{ onDriverBelowFloor = @('a3') })) } |
            Should -Throw "*'onDriverBelowFloor' is not a setting of a wave*"
    }
}

# WAVE-OWN-ACTIVITY-WORDS-1: the activity and the refusals of a wave save use
# the words of the wave editor: a machine does not follow a setting, or uses
# the setting of its wave. Read without comments, so a comment that names the
# old words does not count.
Describe 'WAVE-OWN-ACTIVITY-WORDS-1: the service says what the wave editor says' {
    It 'no line the service writes for a wave save uses the old words' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        foreach ($rel in @(@('Public', 'Set-VmfWavePlan.ps1'), @('Private', 'plan', 'WaveSettings.ps1'))) {
            $file = Join-Path $script:repoRoot 'src' 'VmMigrationFactory' @rel
            $code = Get-VmfCodeOnly -Path $file
            $code | Should -Not -Match 'own value' -Because "$($rel[-1]) says 'does not follow the setting'"
            $code | Should -Not -Match 'has the value of (its|that|the) wave' -Because "$($rel[-1]) says 'uses the setting of its wave'"
            $code | Should -Not -Match 'cannot get the value|cannot reset a machine' -Because "$($rel[-1]) says 'use the setting of its wave'"
        }
    }
}