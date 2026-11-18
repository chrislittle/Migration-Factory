#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# ENGINE-START-PART-1: the service never reports a started engine as failed.
#
# STEP-LOG-6 fixed the run history line written after a start of the engine.
# Two other things after the start could still throw, and then the page showed
# an error for a start that worked while the engine ran on the customer's
# machines - so a person could start it again:
#
#   - the run manifest (run.json), written after Azure accepted the start;
#   - a wave in more than one container (SCALE-2), when Azure accepted the
#     first container and refused a later one.
#
# And a second start of a wave whose engine runs - also one that is only part
# started, whose machines have no state document yet - is refused by the
# service, from Azure's list of executions (Test-VmfFacadeEngineRunning, the
# question a restore already asks).

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az is not installed in CI, so the service tests mock a stand-in, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'enginestartpart'
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    $script:Said = { param($w) (@($w | ForEach-Object { [string]$_ }) -join "`n") }
    # The engine job as Azure gives it (a Consumption-only environment: at most
    # 7 workers a container, so 20 at once is three containers of 7, 7 and 6),
    # and a start Azure answers with the code the test gives for each call.
    $script:MockArm = {
        param([int[]]$Codes = @(202))
        $script:starts = [System.Collections.Generic.List[string]]::new()
        $script:codes = $Codes
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $script:starts.Add($Payload)
                $code = $script:codes[[math]::Min($script:starts.Count, $script:codes.Count) - 1]
                if ($code -in 200, 202) {
                    return [pscustomobject]@{ StatusCode = $code; Content = (@{ name = "exec-$($script:starts.Count)"; id = 'x' } | ConvertTo-Json) }
                }
                return [pscustomobject]@{ StatusCode = $code; Content = '{"error":{"code":"ContainerAppEnvironmentCoresQuotaExceeded"}}' }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    # Azure's list of the engine job's executions, read through the module's
    # ARM list (Test-VmfFacadeEngineRunning).
    $script:Executions = @()
    function Global:EspExec([string]$Status, [string]$Op, [string]$Run, [string]$Wave) {
        $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
        if ($Wave) { $envs += @{ name = 'VMF_WAVE'; value = $Wave } }
        @{ name = "exec-$Status-$Wave"; properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } }
    }
    $script:MockExecutions = {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:Executions) } | ConvertTo-Json -Depth 12) }
        }
    }
    $script:Events = { param($rp) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\EspExec' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'ENGINE-START-PART-1: a start that Azure accepted is reported as made' {
    BeforeEach {
        $script:root = Join-Path $script:temp "esp-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'esp'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'esp' | Out-Null }
        $script:Executions = @()
        & $script:MockExecutions
        # MACHINES-AT-ONCE-RANGE-1: a start takes the wave's own number from its plan.
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 20 }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'a start whose run manifest cannot be written is returned as a start, with a warning in the service log' {
        & $script:MockArm
        Mock -ModuleName VmMigrationFactory Initialize-VmfRun { throw 'The store did not answer.' }
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'esp' `
            -WarningVariable w -WarningAction SilentlyContinue
        $r.execution | Should -Be 'exec-1' -Because 'the engine runs, so the page is told the start it made'
        $said = & $script:Said $w
        $said | Should -BeLike '*run manifest*could not be written*The store did not answer.*' -Because 'the lost write is a warning that names it'
        $said | Should -BeLike '*exec-1*' -Because 'the warning names the execution that runs'
        @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine' -and $_.outcome -eq 'start' }).Count |
            Should -Be 1 -Because 'the start line is still written after a lost manifest'
    }

    It 'a start that Azure refuses writes no run manifest (no run that never ran)' {
        & $script:MockArm -Codes @(409)
        $fresh = Join-Path $script:root 'never'
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'never' } |
            Should -Throw 'Engine start failed: HTTP 409*'
        Test-Path (Join-Path $fresh 'run.json') | Should -BeFalse -Because 'the manifest is written only after Azure accepts the start'
    }

    It 'a wave whose first container Azure refuses is still a failed start, and nothing is said to run' {
        & $script:MockArm -Codes @(409)
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'tonight' } |
            Should -Throw 'Engine start failed: HTTP 409*'
        $script:starts.Count | Should -Be 1 -Because 'nothing runs, so no later container is asked for'
        @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine' }).Count | Should -Be 0
    }

    It 'a wave whose later container Azure refuses is returned as a part start that names what runs and what does not' {
        & $script:MockArm -Codes @(202, 409)
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'tonight'
        $r.execution | Should -Be 'exec-1'
        @($r.executions) | Should -Be @('exec-1') -Because 'only the containers that started are executions'
        $r.containers | Should -Be 1
        $r.partStart | Should -BeTrue
        $script:starts.Count | Should -Be 2 -Because 'after a refusal no later container is asked for'
        @($r.notStarted.container) | Should -Be @('2/3', '3/3')
        @($r.notStarted.workers) | Should -Be @(7, 6)
        $r.notStarted[0].reason | Should -BeLike '*HTTP 409*ContainerAppEnvironmentCoresQuotaExceeded*' -Because "Azure's answer is kept"
        $r.notStarted[1].reason | Should -BeLike '*refused container 2/3*'
        $r.workersStarted | Should -Be 7
        $r.message | Should -BeLike 'Wave w1 started in 1 of 3 containers, with 7 of 20 machines at once.*'
        $r.message | Should -BeLike '*Azure refused container 2/3*HTTP 409*'
        $r.message | Should -BeLike '*The containers that run do all the machines of the wave.*'
        $r.message | Should -BeLike '*The service refuses a second start of the wave while it runs.*'
    }

    It 'the run history line of a part start names each execution and each container that does not run' {
        & $script:MockArm -Codes @(202, 202, 409)
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'tonight'
        @($r.executions) | Should -Be @('exec-1', 'exec-2')
        $lines = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine' })
        $lines.Count | Should -Be 1 -Because 'one line says the whole start'
        $lines[0].outcome | Should -Be 'warn' -Because 'a part start is not a plain start'
        $lines[0].detail | Should -BeLike '*hosted wave started by operator@example.com: tonight*exec-1, exec-2*'
        $lines[0].detail | Should -BeLike '*Azure refused container 3/3*HTTP 409*'
    }

    It 'a part start whose line cannot be written is still returned as a part start' {
        & $script:MockArm -Codes @(202, 409)
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine' } { throw 'The store did not answer.' }
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'tonight' `
            -WarningVariable w -WarningAction SilentlyContinue
        $r.partStart | Should -BeTrue
        (& $script:Said $w) | Should -BeLike "*'engine warn' could not be written*Azure refused container 2/3*"
    }

    It 'a later container that Azure does not answer at all is a part start too' {
        & $script:MockArm
        $script:calls = 0
        Mock -ModuleName FacadeCore Invoke-AzRestMethod -ParameterFilter { $Method -eq 'POST' } {
            $script:calls++
            if ($script:calls -gt 1) { throw 'The connection was closed.' }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'exec-1' } | ConvertTo-Json) }
        }
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'tonight'
        $r.partStart | Should -BeTrue
        $r.notStarted[0].reason | Should -BeLike '*The connection was closed.*'
    }

    It 'a full start is not a part start and says nothing more' {
        & $script:MockArm -Codes @(202)
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'tonight'
        @($r.executions) | Should -Be @('exec-1', 'exec-2', 'exec-3')
        $r.partStart | Should -BeFalse
        @($r.notStarted).Count | Should -Be 0
        $r.message | Should -BeNullOrEmpty
        (@(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine' }))[0].outcome | Should -Be 'start'
    }
}

Describe 'ENGINE-START-PART-1: a second start of a wave whose engine runs is refused' {
    BeforeEach {
        $script:root = Join-Path $script:temp "espg-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'esp'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'esp' | Out-Null }
        & $script:MockExecutions
        & $script:MockArm
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'refuses while Azure lists an execution of the same wave as <Status>, before any start' -ForEach @(
        @{ Status = 'Running' }, @{ Status = 'Processing' }) {
        # Processing: a part-started container pulls its image, and no machine
        # of the wave has a state document yet - so the page still offers Start.
        $script:Executions = @((EspExec $Status 'wave' 'esp' 'w1'))
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'again' } |
            Should -Throw '400: Wave w1 runs now. Wait until it ends.'
        $script:starts.Count | Should -Be 0 -Because 'the refusal comes before any start'
    }

    It 'starts while only another wave, another run, a finished execution or another operation is listed' {
        $script:Executions = @((EspExec 'Running' 'wave' 'esp' 'w2'), (EspExec 'Running' 'wave' 'other' 'w1'),
            (EspExec 'Succeeded' 'wave' 'esp' 'w1'), (EspExec 'Running' 'quotacheck' 'esp' 'w1'))
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'first'
        $r.execution | Should -Be 'exec-1'
    }

    It 'a wave start that cannot list the executions does not start' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 503; Content = 'busy' } }
        { Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'esp' -Wave 'w1' -Note 'first' } |
            Should -Throw 'Could not list engine executions: HTTP 503*'
        $script:starts.Count | Should -Be 0
    }

    It 'the question with a wave named counts only executions of that wave' {
        $script:Executions = @((EspExec 'Running' 'wave' 'esp' 'w2'))
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'esp' -Wave 'w1' } | Should -BeFalse
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'esp' -Wave 'w2' } | Should -BeTrue
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'esp' } | Should -BeTrue -Because 'with no wave named it answers for the run, as before'
    }
}

Describe 'ENGINE-START-PART-1 review: the timer passes count a Processing run as a run' {
    # The service guard refuses a start while a run of the wave is Running or
    # Processing. The three timer passes asked for Running only, so a fresh
    # container that pulls its image (Processing) got a start from them, the
    # guard refused it, the pass stopped and the run history showed a false
    # 'fail' line. Each pass now asks the same question as the guard.
    BeforeEach {
        $script:root = Join-Path $script:temp "espt-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'esp'
        $script:vmBase = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmBase } {
            param($rp, $vm)
            Initialize-VmfRun -RunPath $rp -RunId 'esp' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'esp'; assessmentRunId = 'esp'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}a"; wave = 'w1'; path = 'A'; policy = [ordered]@{ requireApproval = $false; throttle = 5 } },
                            [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}b"; wave = 'w2'; path = 'A'; policy = [ordered]@{ requireApproval = $false; throttle = 5 } }) })
        }
        # A run of wave w1 that pulls its image.
        $script:Executions = @((EspExec 'Processing' 'wave' 'esp' 'w1'))
        & $script:MockExecutions
        & $script:MockArm
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'the resume pass starts no second run of a wave whose run is Processing, and goes on to the next wave' {
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vmBase } {
            param($rp, $vm)
            foreach ($pair in @(@("${vm}a", 'w1'), @("${vm}b", 'w2'))) {
                $doc = New-VmfStateDoc -RunPath $rp -RunId 'esp' -VmId $pair[0] -Wave $pair[1]
                $doc.state = 'CONVERTING'
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        $pp = Join-Path $script:rp 'plan.json'
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' | Out-Null
        foreach ($wave in 'w1', 'w2') {
            Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $pp -Wave $wave -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        }
        $r = @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rp -RunId 'esp')
        @($r.Wave) | Should -Be @('w2') -Because 'the Processing run of w1 is a run; w2 has none'
        $script:starts.Count | Should -Be 1
        @(& $script:Events $script:rp | Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 0
    }

    It 'the schedule pass leaves a wave whose run is Processing scheduled, and releases the next one' {
        foreach ($wave in 'w1', 'w2') {
            Invoke-VmfFacadeSchedule -Principal $script:operator -StorePath $script:rp -Wave $wave `
                -RunAtUtc ((Get-Date).AddMinutes(30).ToString('o')) -Note 'tonight' | Out-Null
        }
        $released = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:rp -RunId 'esp' -AsOf (Get-Date).ToUniversalTime().AddHours(1))
        @($released.Wave) | Should -Be @('w2')
        $script:starts.Count | Should -Be 1
        # SCHEDULE-WAVE-VERSION-1: w2 keeps its start on record ('started')
        # until the engine run of that start removes it.
        @(Get-VmfWaveSchedule -RunPath $script:rp | Where-Object { [string]$_.state -eq 'pending' } | ForEach-Object { $_.wave }) | Should -Be @('w1') -Because 'it is asked again on the next pass'
        @(Get-VmfWaveSchedule -RunPath $script:rp | Where-Object { [string]$_.state -eq 'started' } | ForEach-Object { $_.wave }) | Should -Be @('w2')
        @(& $script:Events $script:rp | Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 0
    }

    It 'the plan-continue pass starts no wave while a run of the migration is Processing' {
        Mock -ModuleName VmMigrationFactory Get-VmfPlanRunDecision {
            [pscustomobject]@{ Wave = 'w2'; Throttle = 3; Detail = 'w1 ended'; After = 'w1'; WaveVersion = ('a' * 64) }
        }
        $r = Invoke-VmfFacadeContinuePlan -StorePath $script:rp -RunId 'esp'
        $r | Should -BeNullOrEmpty
        $script:starts.Count | Should -Be 0 -Because 'one run of the migration is on its way'
    }

    It 'a run started for a project counts whichever way the caller names the run' {
        # The page names the run and its project apart; the timers name the
        # run by its place in the store, project/run.
        $proj = @{ name = 'p'; properties = @{ status = 'Processing'; template = @{ containers = @(@{ env = @(
            @{ name = 'VMF_OPERATION'; value = 'wave' }, @{ name = 'VMF_RUN_ID'; value = 'esp' },
            @{ name = 'VMF_PROJECT'; value = 'proj-a' }, @{ name = 'VMF_WAVE'; value = 'w1' }) }) } } }
        $script:Executions = @($proj)
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'proj-a/esp' -Wave 'w1' } | Should -BeTrue
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'esp' -Project 'proj-a' -Wave 'w1' } | Should -BeTrue
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'esp' -Wave 'w1' } | Should -BeFalse -Because 'a run outside the project is another run'
        $script:Executions = @((EspExec 'Processing' 'wave' 'proj-a/esp' 'w1'))
        InModuleScope FacadeCore { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'esp' -Project 'proj-a' -Wave 'w1' } | Should -BeTrue
    }
}
Describe 'ENGINE-START-PART-1: the run page shows the words of a part start' {
    It 'the Start this wave dialog returns the service message, so the page shows it' {
        . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
        $page = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'dashboard' 'migrations.html')
        $page | Should -Match 'const started = await apiFetch\(`runs/\$\{runSeg\(\)\}/engine/wave`'
        $page | Should -Match 'return started\?\.partStart \? started\.message : undefined;'
    }
}
