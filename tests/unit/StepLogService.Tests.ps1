#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# STEP-LOG-6: a run history line that cannot be written, in the service, never
# decides what the service did.
#
# STEP-LOG-2 and STEP-LOG-4 put every line the module writes after a change
# through Write-VmfStepLine. The service (src/facade) still wrote its own lines
# with Write-VmfEvent, which throws when the store refuses the line. So a start
# of the engine that worked was reported as failed while the engine ran on the
# customer's machines, and a resume pass or a schedule pass stopped part way:
# the next stopped wave was not started again, and the pass returned no list of
# what it started. Each test below makes the one line fail and shows the start
# is made, the pass goes on, and the service log has a warning that names the
# line and holds its words.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    # Az is not installed in CI, so the service tests mock a stand-in, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'steplog6'
    $script:vm = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/'
    $script:schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'
    $script:retention = Join-Path $script:repoRoot 'src' 'facade' 'app' 'RetentionRunner' 'run.ps1'
    $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    # The warning a lost line gives, read back as one string.
    $script:Said = { param($w) (@($w | ForEach-Object { [string]$_ }) -join "`n") }
    # The engine job as Azure gives it, and a start that Azure accepts.
    $script:MockArm = {
        $script:starts = [System.Collections.Generic.List[string]]::new()
        # ENGINE-START-PART-1: a wave start asks Azure, through the module's
        # ARM list, whether an execution of its wave runs. None does.
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod -ParameterFilter { [string]$Path -match '/executions\?' } {
            [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' }
        }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET' -and $Path -match '/executions\?') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ value = @() } | ConvertTo-Json -Depth 6) }
            }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            if ($Method -eq 'POST' -and $Path -match '/start\?') {
                $script:starts.Add($Payload)
                return [pscustomobject]@{ StatusCode = 202; Content = (@{ name = "exec-$($script:starts.Count)"; id = 'x' } | ConvertTo-Json) }
            }
            [pscustomobject]@{ StatusCode = 200; Content = '{}' }
        }
    }
    $script:Events = { param($rp) InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { param($rp) @(Read-VmfEvents -RunPath $rp) } }
}
AfterAll {
    Remove-VmfTestTemp
    Remove-Item 'function:\Invoke-AzRestMethod' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'STEP-LOG-6: a line that cannot be written, after the service started the engine' {
    BeforeEach {
        $script:root = Join-Path $script:temp "sl6-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'sl6'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'sl6' | Out-Null }
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'a start of the engine that worked is returned as a start when its line cannot be written' {
        & $script:MockArm
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine' } { throw 'The store did not answer.' }
        # MACHINES-AT-ONCE-RANGE-1: the start reads the wave's own number; Pilot, one container.
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 5 }
        $r = Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'wave' -RunId 'sl6' -Wave 'w1' -Note 'tonight' `
            -WarningVariable w -WarningAction SilentlyContinue
        $r.execution | Should -Be 'exec-1' -Because 'the page is told the start it made'
        $r.startedBy | Should -Be 'operator@example.com'
        $script:starts.Count | Should -Be 1
        (& $script:Said $w) | Should -BeLike "*'engine start' could not be written*The store did not answer.*hosted wave started by operator@example.com: tonight (execution exec-1)*"
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine' } -Times 1 -Exactly
    }

    It 'the resume pass starts every stopped wave, and returns them, when a line cannot be written' {
        # Two waves, each with a machine stopped mid-move and nothing working on it.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            param($rp, $vm)
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'sl6'; assessmentRunId = 'sl6'
                entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}a"; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }, [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}b"; wave = 'w2'; path = 'A'; policy = [ordered]@{ throttle = 5 } }) })
            foreach ($pair in @(@("${vm}a", 'w1'), @("${vm}b", 'w2'))) {
                $doc = New-VmfStateDoc -RunPath $rp -RunId 'sl6' -VmId $pair[0] -Wave $pair[1]
                $doc.state = 'CONVERTING'
                Write-VmfStateDoc -RunPath $rp -Document $doc
            }
        }
        $pp = Join-Path $script:rp 'plan.json'
        Confirm-VmfRunAcknowledgement -RunPath $script:rp -AcknowledgedBy 'operator@example.com' | Out-Null
        foreach ($wave in 'w1', 'w2') {
            Approve-VmfWave -RunPath $script:rp -PlanPath $pp -Wave $wave -Note 'test' -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = 't' } | Out-Null
            Confirm-VmfWaveOptions -RunPath $script:rp -PlanPath $pp -Wave $wave -AcceptedBy 'operator@example.com' -Confirm:$false | Out-Null
        }
        & $script:MockArm
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'resume' } { throw 'The store did not answer.' }
        $r = @(Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rp -RunId 'sl6' -WarningVariable w -WarningAction SilentlyContinue)
        @($r.Wave) | Should -Be @('w1', 'w2') -Because 'a lost line for the first wave must not stop the pass before the second'
        $script:starts.Count | Should -Be 2
        @($r.Execution) | Should -Be @('exec-1', 'exec-2')
        (& $script:Said $w) | Should -BeLike "*'resume warn' could not be written*The run stopped before wave w1 finished (a at CONVERTING)*"
        (& $script:Said $w) | Should -BeLike "*'resume warn' could not be written*The run stopped before wave w2 finished (b at CONVERTING)*"
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'resume' } -Times 2 -Exactly
    }

    It 'the schedule pass goes on to the next due wave when the line for a wave it leaves cannot be written' {
        # Four waves are due: one that does not fit its window, one with no
        # approval, one that changed after the plan sign-off - each is left, with
        # a line - and one that starts.
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp; vm = $script:vm } {
            param($rp, $vm)
            Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                schemaVersion = 9; runId = 'sl6'
                entries = @(foreach ($w in 'wWindow', 'wApproval', 'wChanged', 'wOk') { [ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "$vm$w"; wave = $w; path = 'A' } }) })
        }
        # SCHEDULE-START-ONCE-1: the schedules, the start record and the
        # removal go through these three.
        Mock -ModuleName VmMigrationFactory Get-VmfScheduleStep {
            foreach ($w in 'wWindow', 'wApproval', 'wChanged', 'wOk') {
                [pscustomobject]@{ Wave = $w; Step = 'due'; Version = ('a' * 64)
                    Schedule = [pscustomobject]@{ wave = $w; windowMinutes = $(if ($w -eq 'wWindow') { 60 } else { $null }); scheduledBy = 'operator@example.com'; note = 'tonight'; state = 'pending' } }
            }
        }
        Mock -ModuleName VmMigrationFactory Set-VmfScheduleStartRecord { [pscustomobject]@{ StartId = ('c' * 32); Version = ('b' * 64) } }
        Mock -ModuleName VmMigrationFactory Remove-VmfStartedSchedule { $true }
        Mock -ModuleName FacadeCore Test-VmfWaveWindow { [pscustomobject]@{ Fits = $false; Reason = 'it needs 3 hours' } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveApproval { [pscustomobject]@{ Pass = ($Wave -ne 'wApproval') } }
        Mock -ModuleName VmMigrationFactory Get-VmfUnattendedStartRefusal { if ($Wave -eq 'wChanged') { 'changed after the sign-off' } }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = "exec-$Wave" } }
        # ENGINE-START-PART-1 review: no run of a due wave goes on.
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'schedule' } { throw 'The store did not answer.' }
        $r = @(Invoke-VmfFacadeReleaseDueSchedules -StorePath $script:rp -RunId 'sl6' -WarningVariable w -WarningAction SilentlyContinue)
        @($r.Wave) | Should -Be @('wOk')
        $r[0].Execution | Should -Be 'exec-wOk'
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 1 -Exactly
        # SCHEDULE-WAVE-VERSION-1: the engine run of the start removes the start
        # time once its read of the wave is the one judged; the pass does not.
        Should -Invoke -ModuleName VmMigrationFactory Remove-VmfStartedSchedule -Times 0 -Exactly
        $said = & $script:Said $w
        $said | Should -BeLike "*'schedule warn' could not be written*wave wWindow was due to start but will not fit its window: it needs 3 hours*"
        $said | Should -BeLike "*'schedule warn' could not be written*wave wApproval was due to start but has not been approved*"
        $said | Should -BeLike "*'schedule warn' could not be written*wave wChanged was due to start, but it changed after the plan was signed off*"
        # SCHEDULE-START-ONCE-1: and the line for the wave that started.
        $said | Should -BeLike "*'schedule info' could not be written*The service started the engine for wave wOk at its scheduled time (execution exec-wOk). The engine checks the wave again, and then removes the start time.*"
        Should -Invoke -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'schedule' } -Times 4 -Exactly
    }

    It 'an approved review is returned with its failed start of the target options when that line cannot be written' {
        $scan = Join-Path $script:root 'scan'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $scan } {
            param($rp)
            Initialize-VmfRun -RunPath $rp -RunId 'scan' -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $rp -RelPath 'assessment.json' -Depth 24 -Document ([ordered]@{ schemaVersion = 17; runId = 'scan'; vms = @() })
        }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'the engine job could not be read' }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Step -eq 'engine:advise' } { throw 'The store did not answer.' }
        $approver = [pscustomobject]@{ Identity = 'approver@example.com'; Roles = @('Vmf.Approver'); TenantId = 't' }
        $r = Invoke-VmfFacadeApproveAssessment -Principal $approver -StorePath $scan -RunId 'scan' -WarningVariable w -WarningAction SilentlyContinue
        $r.TargetOptions.started | Should -BeFalse
        $r.TargetOptions.error | Should -BeLike '*did not start*the engine job could not be read*'
        Test-Path (Join-Path $scan 'approval.json') | Should -BeTrue -Because 'the review is recorded whether or not the start works'
        (& $script:Said $w) | Should -BeLike "*'engine:advise fail' could not be written*The target options did not start*"
    }
}

Describe 'STEP-LOG-6: the two timer passes, when the line for a failed check cannot be written' {
    BeforeEach {
        $script:root = Join-Path $script:temp "sl6t-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        # Two migrations, each with a plan of one machine.
        foreach ($run in 'r1', 'r2') {
            InModuleScope VmMigrationFactory -Parameters @{ rp = (Join-Path $script:root $run); id = $run; vm = $script:vm } {
                param($rp, $id, $vm)
                Initialize-VmfRun -RunPath $rp -RunId $id | Out-Null
                Write-VmfStoreJson -RunPath $rp -RelPath 'plan.json' -Depth 24 -Document ([ordered]@{
                    schemaVersion = 9; runId = $id; entries = @([ordered]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "${vm}$id"; wave = 'w1'; path = 'A'; policy = [ordered]@{ throttle = 5 } }) })
            }
        }
        Mock -ModuleName VmMigrationFactory Write-VmfEvent -ParameterFilter { $Outcome -eq 'fail' } { throw 'The store did not answer.' }
    }
    AfterEach { Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'the schedule pass makes each of its five checks for every run' {
        Mock Invoke-VmfFacadeReleaseDueSchedules { throw 'the schedule could not be read' }
        Mock Invoke-VmfFacadeResumeStalledWaves { throw 'the engine could not be listed' }
        Mock Invoke-VmfFacadeResumeStalledPutBacks { throw 'the records could not be read' }
        Mock Invoke-VmfFacadeContinuePlan { throw 'the plan could not be read' }
        Mock Invoke-VmfFacadeRemoveEndedWaveHolds { throw 'the leases could not be listed' }
        $out = & $script:schedule -Timer $null 3>&1
        foreach ($pass in 'Invoke-VmfFacadeReleaseDueSchedules', 'Invoke-VmfFacadeResumeStalledWaves', 'Invoke-VmfFacadeResumeStalledPutBacks', 'Invoke-VmfFacadeRemoveEndedWaveHolds', 'Invoke-VmfFacadeContinuePlan') {
            Should -Invoke $pass -Times 2 -Exactly -Because "a lost line in one check must not stop $pass for the run or the next run"
        }
        $said = & $script:Said $out
        $said | Should -Not -BeLike '*before it could read the runs*'
        foreach ($line in "'schedule fail'", "'resume fail'", "'watchdog fail'", "'planrun fail'") { $said | Should -BeLike "*$line could not be written*" }
        $said | Should -BeLike '*A scheduled wave could not be released: the schedule could not be read*'
    }

    It 'the retention pass records each run it could not clean, and goes on to the next run' {
        Mock -ModuleName VmMigrationFactory Update-VmfRunSummary { throw 'the summary could not be written' }
        $out = & $script:retention -Timer $null 3>&1
        $record = Get-Content (Join-Path $script:root 'retention-status.json') -Raw | ConvertFrom-Json
        @($record.failures.runId) | Should -Be @('r1', 'r2')
        @($record.failures.reason) | Should -Not -Contain ''
        $record.runsExamined | Should -Be 2
        (& $script:Said $out) | Should -BeLike "*'retention fail' could not be written*The daily cleanup did not run*"
    }
}
