#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# WAVE-ORDER-START-1: what the service says around the start of a wave.
#
# Lab Session A, 2026-11-04 (finding 11): right after a person selected Start
# the plan, the activity said "the first wave starts when somebody starts it,
# or at its start time". The timer had passed while the engine container
# started and before it took a machine, so the store alone said that nothing
# had begun - and the timer wrote that line about a wave that was starting.
#
# Two changes, both tested here:
#   - the timer writes no "first wave waits for a person" line while an engine
#     run of a wave of this migration is on its way (Azure's list of
#     executions, the question the timer already asks before it starts one);
#   - the service's start line names the operation and the wave, so the
#     Migrations page can say that the wave starts instead of offering Start a
#     second time (tests/js/wave-order-start.test.js runs the page's half).

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
    $script:temp = New-VmfTestTemp -Prefix 'waveorderstart'
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    $script:Events = { param($rp) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
    # Azure's list of the engine job's executions, read through the module's
    # ARM list (Test-VmfFacadeEngineRunning).
    $script:Executions = @()
    function Global:WosExec([string]$Status, [string]$Op, [string]$Run, [string]$Wave) {
        $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
        if ($Wave) { $envs += @{ name = 'VMF_WAVE'; value = $Wave } }
        @{ name = "exec-$Status-$Wave"; properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } }
    }
    $script:plan = [pscustomobject]@{ assessmentRunId = 'r1'; waveOrder = @('new-wave', 'new-wave-2'); entries = @(
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/l26-a1'; wave = 'new-wave-2'; path = 'A'; policy = [pscustomobject]@{ throttle = 2 } },
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/l26-w3'; wave = 'new-wave'; path = 'A'; policy = [pscustomobject]@{ throttle = 2 } },
        [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = '/s/rg/vm/l26-w4'; wave = 'new-wave'; path = 'A'; policy = [pscustomobject]@{ throttle = 2 } }) }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\WosExec' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'WAVE-ORDER-START-1: the timer says nothing false about a first wave that is starting' {
    BeforeEach {
        $script:runPath = Join-Path $script:temp "t-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:runPath -Force | Out-Null
        $script:planPath = Join-Path $script:runPath 'plan.json'
        $script:plan | ConvertTo-Json -Depth 8 | Set-Content $script:planPath
        Approve-VmfPlan -RunPath $script:runPath -PlanPath $script:planPath -Note 'reviewed' `
            -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        Mock -ModuleName FacadeCore Get-VmfFacadePlanPath { param($StorePath) Join-Path $StorePath 'plan.json' }
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.App/jobs/engine'
        $script:Executions = @()
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:Executions) } | ConvertTo-Json -Depth 12) }
        }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = 'exec-1' } }
        $script:status = Join-Path $script:runPath 'plan-run.json'
        $script:PlanRunLines = { @(& $script:Events $script:runPath | Where-Object { $_.step -eq 'planrun' }) }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue }

    It 'signed off and not started by anybody: the first wave waits for a person, as before' {
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
        (Get-Content $script:status -Raw | ConvertFrom-Json).reason | Should -Be 'notStarted'
        @(& $script:PlanRunLines).Count | Should -Be 1
    }

    It 'a person started the first wave, and the engine has not taken a machine yet: no line says it waits for a person' {
        foreach ($status in 'Processing', 'Running') {
            $script:Executions = @(WosExec $status 'wave' 'r1' 'new-wave')
            Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
            Test-Path $script:status | Should -BeFalse -Because "an engine run of the wave is $status"
            @(& $script:PlanRunLines).Count | Should -Be 0 -Because 'the activity says nothing that the start makes false'
        }
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
    }

    It 'an engine run of another migration, another operation, or one that ended does not count' {
        foreach ($other in @((WosExec 'Running' 'wave' 'r2' 'new-wave'), (WosExec 'Running' 'restore' 'r1' ''), (WosExec 'Succeeded' 'wave' 'r1' 'new-wave'))) {
            Remove-Item $script:status -ErrorAction SilentlyContinue
            $script:Executions = @($other)
            Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null
            (Get-Content $script:status -Raw | ConvertFrom-Json).reason | Should -Be 'notStarted'
        }
    }

    It 'Azure is asked only when the plan waits for its first wave - not on every pass of every migration' {
        Remove-Item (Join-Path $script:runPath 'plan-approval.json')
        Invoke-VmfFacadeContinuePlan -StorePath $script:runPath -RunId 'r1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 0 -Exactly -Because 'a plan nobody signed off needs no listing'
    }
}

Describe 'WAVE-ORDER-START-1: the start line names the operation and the wave' {
    BeforeEach {
        $script:root = Join-Path $script:temp "s-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'wos'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'wos' | Out-Null }
        $script:Executions = @()
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @($script:Executions) } | ConvertTo-Json -Depth 12) }
        }
        $script:n = 0
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $script:n++
                return [pscustomobject]@{ StatusCode = 202; Content = (@{ name = "exec-$($script:n)"; id = 'x' } | ConvertTo-Json) }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'a wave start says which wave, so the page can say the wave starts' {
        # MACHINES-AT-ONCE-RANGE-1: the start reads the wave's own number.
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 2 }
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'wos' -Wave 'new-wave' -Note 'tonight' | Out-Null
        $line = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine' })
        $line.Count | Should -Be 1
        $line[0].outcome | Should -Be 'start'
        $line[0].operation | Should -Be 'wave'
        $line[0].wave | Should -Be 'new-wave'
        $line[0].detail | Should -Be 'hosted wave started by operator@example.com: tonight (execution exec-1)' -Because 'the words stay as they were'
    }

    It 'another operation names itself and no wave' {
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'wos' | Out-Null
        $line = @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine' })
        $line[0].operation | Should -Be 'assess'
        $line[0].PSObject.Properties['wave'] | Should -BeNullOrEmpty
    }
}
