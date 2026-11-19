#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
PLANRUN-1: sign off the plan, and let it run.

The engine ran ONE wave and exited, and nothing ever started the next - three
approved waves once sat idle because nothing was coming for them. And the last
step approved only the FIRST wave while the person believed they had signed off
the plan.

The rule, agreed with the owner: when a wave finishes, the next one starts -
unless it has a start time (then it waits for it), or a machine is parked for a
decision (then the run holds). The first wave is started by a person.
#>
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $PSScriptRoot '..' '..' 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    # Three waves of two, in plan order w1, w2, w3.
    $script:plan = [pscustomobject]@{ assessmentRunId = 'r1'; entries = @(
        foreach ($w in 'w1', 'w2', 'w3') { foreach ($n in 'a', 'b') {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$w$n"; wave = $w; path = 'A'; policy = [pscustomobject]@{ throttle = 4 } } } }) }
    $script:Next = { param([hashtable]$States, [bool]$Signed = $true, [bool]$Halted = $false, [string[]]$Scheduled = @())
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:plan; s = $States; g = $Signed; h = $Halted; sc = $Scheduled } {
            Get-VmfNextPlanWave -Plan $p -States $s -SignedOff $g -Halted $h -ScheduledWaves $sc
        }
    }
    $script:done = { param([string[]]$Waves) $h = @{}; foreach ($w in $Waves) { foreach ($n in 'a', 'b') { $h["/s/rg/vm/$w$n"] = 'MIGRATED' } }; $h }
}

Describe 'PLANRUN-1: what a signed-off plan does next' {
    It 'nothing starts on its own for a plan nobody signed off' {
        (& $script:Next @{} -Signed $false).Reason | Should -Be 'notSigned'
    }

    It 'the FIRST wave waits for a person - signing is not starting' {
        $d = & $script:Next @{}
        $d.Wave | Should -BeNullOrEmpty
        $d.Reason | Should -Be 'notStarted'
    }

    It 'when wave 1 finishes, wave 2 starts, with its own "how many at once"' {
        $d = & $script:Next (& $script:done 'w1')
        $d.Wave | Should -Be 'w2'
        $d.After | Should -Be 'w1'
        $d.Throttle | Should -Be 4
        $d.Detail | Should -Match 'wave w1 finished, so wave w2 starts'
    }

    It 'and not while a wave is still running' {
        $s = & $script:done 'w1'; $s['/s/rg/vm/w2a'] = 'CONVERTING'
        (& $script:Next $s).Reason | Should -Be 'running'
    }

    It 'the run HOLDS on a machine waiting for a person - the owner''s call' {
        foreach ($parked in 'NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION') {
            $s = & $script:done 'w1'; $s['/s/rg/vm/w1b'] = $parked
            $d = & $script:Next $s
            $d.Wave | Should -BeNullOrEmpty
            $d.Reason | Should -Be 'held'
            $d.Detail | Should -Match 'w1b'
        }
    }

    It 'a machine put back or left out does not hold the run' {
        $s = & $script:done 'w1'; $s['/s/rg/vm/w1a'] = 'FAILED_ROLLED_BACK'; $s['/s/rg/vm/w1b'] = 'SKIPPED'
        (& $script:Next $s).Wave | Should -Be 'w2'
    }

    It 'a paused run starts nothing' {
        (& $script:Next (& $script:done 'w1') -Halted $true).Reason | Should -Be 'halted'
    }

    It 'a wave with a start time waits for it - the schedule starts it, not this' {
        $d = & $script:Next (& $script:done 'w1') -Scheduled @('w2')
        $d.Wave | Should -BeNullOrEmpty
        $d.Reason | Should -Be 'scheduled'
    }

    It 'and when every wave has run, it is done' {
        (& $script:Next (& $script:done 'w1', 'w2', 'w3')).Reason | Should -Be 'done'
    }

    It 'the order is the plan''s, not the alphabet''s' {
        $p = [pscustomobject]@{ entries = @(
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/x/1'; wave = 'zulu'; path = 'A' },
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/x/2'; wave = 'alpha'; path = 'A' },
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/x/3'; wave = 'unscheduled'; path = 'A' },
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/x/4'; wave = 'manual'; path = 'MANUAL' }) }
        $order = InModuleScope VmMigrationFactory -Parameters @{ p = $p } { Get-VmfPlanWaveOrder -Plan $p }
        @($order) -join ',' | Should -Be 'zulu,alpha' -Because 'unscheduled and MANUAL machines never run'
    }
}

Describe 'PLANRUN-1: one signature for the whole plan' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-planrun-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        $script:plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
        $script:planPath = Join-Path $script:runPath 'plan.json'
    }
    AfterEach { if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force } }

    It 'writes a record the contract accepts, naming every wave in order' {
        $r = Approve-VmfPlan -RunPath $script:runPath -PlanPath $script:planPath -Note 'reviewed' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null }
        @($r.Waves) -join ',' | Should -Be 'w1,w2,w3'
        $doc = Join-Path $script:runPath 'plan-approval.json'
        Get-Content $doc -Raw | Test-Json -SchemaFile (Join-Path $script:repo 'schemas' 'plan-approval.schema.json') | Should -BeTrue
    }

    It 'refuses a plan that changed under the approver, and signs nothing' {
        { Approve-VmfPlan -RunPath $script:runPath -PlanPath $script:planPath -Note 'n' -ExpectedPlanHash ('0' * 64) `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } } | Should -Throw '409:*'
        Test-Path (Join-Path $script:runPath 'plan-approval.json') | Should -BeFalse
    }

    It 'every wave of the plan passes the engine''s approval gate - and a later edit drops it for the waves it changed' {
        # WAVE-APPROVE-1: rewritten. The sign-off is now one approval per wave,
        # each signing its own wave, so an edit drops the signature of the waves
        # it changed and keeps the others' (2026-10-05). This pinned
        # that moving a w3 machine to w1 dropped w2's signature too.
        Approve-VmfPlan -RunPath $script:runPath -PlanPath $script:planPath -Note 'reviewed' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        foreach ($w in 'w1', 'w2', 'w3') {
            $g = InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath; w = $w } {
                Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave $w }
            $g.Pass | Should -BeTrue -Because "the plan sign-off covers $w"
            $g.Detail | Should -Match 'approved by approver@example.com'
        }
        # A later edit to the plan - one machine moved from w3 to w1.
        $edited = Get-Content $script:planPath -Raw | ConvertFrom-Json
        $edited.entries[5].wave = 'w1'
        $edited | ConvertTo-Json -Depth 8 | Set-Content $script:planPath
        $pass = @{}
        foreach ($w in 'w1', 'w2', 'w3') {
            $pass[$w] = (InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath; pp = $script:planPath; w = $w } {
                Test-VmfWaveApproval -RunPath $rp -PlanPath $pp -Wave $w }).Pass
        }
        $pass.w1 | Should -BeFalse -Because 'a machine joined w1 after it was signed'
        $pass.w3 | Should -BeFalse -Because 'a machine left w3 after it was signed'
        $pass.w2 | Should -BeTrue -Because 'nothing in w2 changed, so its signature still stands'
    }
}

Describe 'PLANRUN-1: the timer' {
    BeforeEach {
        $script:runPath = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-planrun-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        $script:plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $script:runPath 'plan.json')
        $script:planPath = Join-Path $script:runPath 'plan.json'
        Approve-VmfPlan -RunPath $script:runPath -PlanPath $script:planPath -Note 'reviewed' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } {
            foreach ($n in 'a', 'b') {
                New-VmfStateDoc -RunPath $rp -RunId 'r1' -VmId "/s/rg/vm/w1$n" -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId "/s/rg/vm/w1$n" -NewState 'MIGRATED' -Outcome ok | Out-Null
            }
        }
        # The two gates that need documents this test is not about.
        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { @{ Pass = $true; Detail = 'acknowledged' } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { @{ Pass = $true; Detail = 'accepted' } }
        Mock -ModuleName FacadeCore Get-VmfFacadePlanPath { param($StorePath) Join-Path $StorePath 'plan.json' }
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.App/jobs/engine'
        $script:running = @()
        # ENGINE-START-PART-1 review: the pass asks Test-VmfFacadeEngineRunning,
        # which lists the executions through the module's ARM list.
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:running) } | ConvertTo-Json -Depth 12) }
        }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = 'exec-1' } }
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
        if (Test-Path $script:runPath) { Remove-Item $script:runPath -Recurse -Force }
    }

    # MACHINES-AT-ONCE-RANGE-1: the start reads the wave's own number itself (Get-VmfFacadeWaveThrottle); the timer names none.
    It 'starts the next wave, as the signed-off plan, and names no number of its own' {
        $r = Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1'
        $r.Wave | Should -Be 'w2'
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 1 -Exactly -ParameterFilter {
            $Operation -eq 'wave' -and $Wave -eq 'w2' -and $null -eq $Throttle -and $Principal.Identity -match 'approver@example.com'
        }
        (Get-Content (Join-Path $script:runPath 'plan-run.json') -Raw | ConvertFrom-Json).reason | Should -Be 'start'
        Get-Content (Join-Path $script:runPath 'plan-run.json') -Raw |
            Test-Json -SchemaFile (Join-Path $script:repo 'schemas' 'plan-run.schema.json') | Should -BeTrue
    }

    It 'WAVE-APPROVE-1 (review 4): the start carries the version of the wave the timer judged, so the engine can refuse another' {
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null
        $judged = InModuleScope VmMigrationFactory -Parameters @{ t = (Get-Content $script:planPath -Raw) } { Get-VmfWaveVersion -PlanText $t -Wave 'w2' }
        $judged | Should -Not -BeNullOrEmpty
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 1 -Exactly -ParameterFilter {
            $Wave -eq 'w2' -and $WaveVersion -ceq $judged
        }
    }

    It 'WAVE-APPROVE-1: the start names the wave''s own approver, who may not be the one who signed the plan off' {
        Approve-VmfWave -RunPath $script:runPath -PlanPath $script:planPath -Wave 'w2' -Note 'read again' `
            -OnBehalfOf @{ Identity = 'second-approver@example.com'; TenantId = $null } | Out-Null
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 1 -Exactly -ParameterFilter {
            $Wave -eq 'w2' -and $Principal.Identity -match 'second-approver@example\.com'
        }
    }

    It 'KILL-RESUME: a second pass while that execution runs starts nothing' {
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null
        # The engine has not touched a machine yet - it is pulling its image -
        # so the store alone still says "wave 2 has not started".
        $script:running = @(@{ properties = @{ status = 'Running'; template = @{ containers = @(@{ env = @(
            @{ name = 'VMF_OPERATION'; value = 'wave' }, @{ name = 'VMF_RUN_ID'; value = 'r1' }, @{ name = 'VMF_WAVE'; value = 'w2' }) }) } } })
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 1 -Exactly
    }

    It 'a wave the engine would refuse is reported, not started - and logged once, not every pass' {
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { @{ Pass = $false; Detail = 'nobody accepted this wave''s settings' } }
        1..3 | ForEach-Object { Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null }
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
        $status = Get-Content (Join-Path $script:runPath 'plan-run.json') -Raw | ConvertFrom-Json
        $status.reason | Should -Be 'gate'
        $status.detail | Should -Match 'Wave w2 is next, and it cannot start yet\. nobody accepted'
        $lines = @(Get-Content (Join-Path $script:runPath 'logs' 'events.jsonl') | Where-Object { $_ -match '"step":"planrun"' })
        $lines.Count | Should -Be 1 -Because 'three passes with the same answer are one line'
    }

    It 'GATE-WORDS-1: a next wave whose settings changed after they were accepted logs the refusal once, so the page offers the acceptance again' {
        # The status line says to select Review & accept options again. The
        # page offers that button only after an optionsChanged refusal is
        # logged for the wave (acceptanceRefused). Nothing logged it here.
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted {
            @{ Pass = $false; Gate = 'acceptance'; Code = 'changed'; Detail = 'The settings of wave w2 changed after operator accepted them.' } }
        1..3 | ForEach-Object { Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null }
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
        $refused = @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp -Step 'acceptance' } |
            Where-Object { $_.outcome -eq 'refused' -and $_.code -eq 'optionsChanged' -and $_.wave -eq 'w2' })
        $refused.Count | Should -Be 1 -Because 'said once, not every five minutes'
    }

    It 'GATE-WORDS-1: a next wave nobody accepted logs no refusal - the page already offers Review & accept options' {
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted {
            @{ Pass = $false; Gate = 'acceptance'; Code = 'notAccepted'; Detail = 'Nobody accepted the settings of wave w2.' } }
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null
        @(InModuleScope VmMigrationFactory -Parameters @{ rp = $script:runPath } { Read-VmfEvents -RunPath $rp -Step 'acceptance' } |
            Where-Object { $_.outcome -eq 'refused' }).Count | Should -Be 0
    }

    It 'a plan nobody signed off records nothing at all' {
        Remove-Item (Join-Path $script:runPath 'plan-approval.json')
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:runPath 'plan-run.json') | Should -BeFalse
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
    }

    It 'the timer runs it every pass, in its own error handling' {
        $timer = Get-Content (Join-Path $script:repo 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1') -Raw
        $timer | Should -Match 'Invoke-VmfFacadeContinuePlan -StorePath \$store -RunId \$runId'
        # STEP-LOG-6: through Write-VmfStepLine, so a lost line never stops the pass.
        $timer | Should -Match "Write-VmfStepLine -RunPath \`$sp -Step 'planrun' -Outcome fail"
    }
}
