#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
SCAN-FAIL-SHOWN-1: a scan whose engine job fails must end the wizard's wait,
and say why.

Measured on the lab installation, 2026-11-09: the engine job execution of a
scan ended with the status Failed about 3 minutes after the start, wrote no
console line and no line in the run's activity, and the wizard said "Looking
for machines" for more than 11 minutes, with no end.

Three parts, each tested here:
  - the service's five-minute pass reads the engine job's executions it
    already lists (TIMER-EXEC-LIST-1), and for an assess execution of the run
    that ended Failed or Stopped with no answer after its start
    line, writes the engine:assess fail line the wizard reads
    (Invoke-VmfFacadeEndSilentScan; the rule is Get-VmfScanSilentEnd);
  - the start of a scan puts its run in the record of the runs the pass
    checks, and the pass keeps a run whose scan runs;
  - the engine entrypoint writes a console line before anything that can
    fail, and names the start step that failed.
The wizard's half is tests/js/scan-progress.test.js.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:jobId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine'
    $script:schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'

    # One engine execution as ARM lists it.
    function Global:SfsExec {
        param([string]$Name = 'exec-1', [string]$Status = 'Failed', [string]$Op = 'assess', [string]$Run = 'r1', [string]$Project)
        $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
        if ($Project) { $envs += @{ name = 'VMF_PROJECT'; value = $Project } }
        @{ name = $Name; properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } } |
            ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }
    # The service's start line of a scan, as Invoke-VmfFacadeStartEngine writes it.
    function Global:SfsStart {
        param([string[]]$Executions = @('exec-1'), [string]$Op = 'assess')
        [pscustomobject]@{ step = 'engine'; outcome = 'start'; operation = $Op; executions = $Executions
            detail = "hosted $Op started by operator@example.com (execution $($Executions[0]))" }
    }
    function Global:SfsLine { param([string]$Step, [string]$Outcome) [pscustomobject]@{ step = $Step; outcome = $Outcome; detail = 'x' } }

    $script:Rule = { param($events, $execs)
        & (Get-Module VmMigrationFactory) { param($e, $x) Get-VmfScanSilentEnd -Events $e -Executions $x } $events $execs }
    $script:Ended = { param([string]$name = 'exec-1', [string]$status = 'Failed') [pscustomobject]@{ Name = $name; Status = $status } }
}

AfterAll {
    InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
    Remove-Item 'function:\SfsExec', 'function:\SfsStart', 'function:\SfsLine' -ErrorAction SilentlyContinue
}

Describe 'SCAN-FAIL-SHOWN-1: the rule - which ended scan gets a fail line (Get-VmfScanSilentEnd)' {
    It 'an execution named on the newest scan start, ended <Status>, with no answer after the start: a line that names it and its status' -ForEach @(
        @{ Status = 'Failed' }, @{ Status = 'Stopped' }
    ) {
        $r = & $script:Rule @((SfsStart), (SfsLine 'engine:assess' 'info'), (SfsLine 'assessment' 'start'), (SfsLine 'assessment' 'info')) @(& $script:Ended 'exec-1' $Status)
        $r.Execution | Should -Be 'exec-1'
        $r.Status | Should -Be $Status
        $r.Detail | Should -Be "The engine job execution exec-1 has the status $Status in Azure, and the scan recorded no result and no reason."
    }

    It 'a scan that answered after its start gets no line: <Step> <Outcome>' -ForEach @(
        @{ Step = 'assessment'; Outcome = 'ok' }, @{ Step = 'assessment'; Outcome = 'fail' }, @{ Step = 'assessment'; Outcome = 'refused' }
        @{ Step = 'engine:assess'; Outcome = 'fail' }, @{ Step = 'engine:assess'; Outcome = 'refused' }
    ) {
        & $script:Rule @((SfsStart), (SfsLine $Step $Outcome)) @(& $script:Ended) | Should -BeNullOrEmpty
    }

    It 'an execution that runs, or that succeeded, or whose status Azure gives as <Status>, gets no line' -ForEach @(
        @{ Status = 'Running' }, @{ Status = 'Processing' }, @{ Status = 'Succeeded' }, @{ Status = 'Unknown' }, @{ Status = 'Degraded' }, @{ Status = 'failed' }, @{ Status = '' }
    ) {
        & $script:Rule @((SfsStart)) @(& $script:Ended 'exec-1' $Status) | Should -BeNullOrEmpty
    }

    It 'an execution the newest start does not name gets no line (an earlier scan of the same run)' {
        & $script:Rule @((SfsStart -Executions 'exec-old'), (SfsLine 'engine:assess' 'fail'), (SfsStart -Executions 'exec-new')) @(& $script:Ended 'exec-old') |
            Should -BeNullOrEmpty
    }

    It 'an answer BEFORE the newest start is the earlier scan''s, and does not end this one' {
        $r = & $script:Rule @((SfsStart -Executions 'exec-old'), (SfsLine 'engine:assess' 'fail'), (SfsStart -Executions 'exec-new')) @(& $script:Ended 'exec-new')
        $r.Execution | Should -Be 'exec-new'
    }

    It 'the start line of another operation is not a scan start' {
        & $script:Rule @((SfsStart -Op 'plan')) @(& $script:Ended) | Should -BeNullOrEmpty
        $r = & $script:Rule @((SfsStart -Executions 'exec-1'), (SfsStart -Op 'advise' -Executions 'exec-9')) @(& $script:Ended 'exec-1')
        $r.Execution | Should -Be 'exec-1' -Because 'a later advise start does not hide the scan start before it'
    }

    It 'a log with no scan start line gets no line: nothing ties the execution to the run' {
        & $script:Rule @((SfsLine 'assessment' 'start')) @(& $script:Ended) | Should -BeNullOrEmpty
        & $script:Rule @() @(& $script:Ended) | Should -BeNullOrEmpty
    }

    It 'a start line with no executions names none' {
        $s = SfsStart; $s.PSObject.Properties.Remove('executions')
        & $script:Rule @($s) @(& $script:Ended) | Should -BeNullOrEmpty
    }

    It 'rubbish in the log does not throw' {
        { & $script:Rule @($null, [pscustomobject]@{}, (SfsStart)) @(& $script:Ended) } | Should -Not -Throw
    }
}

Describe 'SCAN-FAIL-SHOWN-1: the service writes the line (Invoke-VmfFacadeEndSilentScan)' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = $script:jobId
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sfs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:runPath = Join-Path $script:store 'r1'
        New-Item -ItemType Directory -Path (Join-Path $script:runPath 'logs') -Force | Out-Null
        $env:VMF_STORE_PATH = $script:store
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        $script:WriteLog = { param([object[]]$lines)
            $text = (@($lines) | ForEach-Object { $_ | ConvertTo-Json -Compress -Depth 5 }) -join "`n"
            [System.IO.File]::WriteAllText((Join-Path $script:runPath 'logs' 'events.jsonl'), $text + "`n")
        }
        $script:Listing = { param([object[]]$items)
            $global:SfsItems = @($items)
            Mock -ModuleName VmMigrationFactory Get-VmfArmList -ParameterFilter { $Path -like '*/executions?*' } {
                @{ Ok = $true; Items = @($global:SfsItems | Where-Object { $_ }); StatusCode = 200; Content = $null } }
        }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        Remove-Variable SfsItems -Scope Global -ErrorAction SilentlyContinue
        if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force }
    }

    It 'a scan whose execution Failed with no line: the engine:assess fail line goes into the run''s activity, once' {
        & $script:WriteLog @((SfsStart), (SfsLine 'engine:assess' 'info'))
        & $script:Listing @((SfsExec -Status 'Failed'))
        $r = Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'r1'
        $r.Execution | Should -Be 'exec-1'
        $events = @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp } $script:runPath)
        $line = @($events | Where-Object { $_.step -eq 'engine:assess' -and $_.outcome -eq 'fail' })
        $line.Count | Should -Be 1
        $line[0].detail | Should -Be 'The engine job execution exec-1 has the status Failed in Azure, and the scan recorded no result and no reason.'
        $line[0].execution | Should -Be 'exec-1'
        $line[0].executionStatus | Should -Be 'Failed'
        # The next pass finds the line, and writes no second one.
        Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
        @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp -Step 'engine:assess' } $script:runPath |
            Where-Object { $_.outcome -eq 'fail' }).Count | Should -Be 1
    }

    It 'a scan inside a project: the page names the run and the project apart, the pass names its place' {
        & $script:WriteLog @((SfsStart))
        & $script:Listing @((SfsExec -Status 'Failed' -Run 'r1' -Project 'p1'))
        (Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'p1/r1').Execution | Should -Be 'exec-1'
    }

    It 'no assess execution of THIS run that ended unanswered: the run log is not read (a pass reads nothing it does not need)' {
        & $script:WriteLog @((SfsStart))
        & $script:Listing @(
            (SfsExec -Status 'Failed' -Run 'r2'), (SfsExec -Status 'Failed' -Op 'wave'), (SfsExec -Status 'Running'),
            (SfsExec -Status 'Succeeded'), (SfsExec -Status 'Failed' -Run 'r1' -Project 'p1'))
        Mock -ModuleName VmMigrationFactory Read-VmfEvents { @() }
        Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Read-VmfEvents -Times 0 -Exactly
    }

    It 'a failed execution of <What> writes no line in this run' -ForEach @(
        @{ What = 'another run'; Exec = @{ Run = 'r2' } }
        @{ What = 'another operation'; Exec = @{ Op = 'wave' } }
        @{ What = 'the same run name in a project'; Exec = @{ Project = 'p1' } }
    ) {
        & $script:WriteLog @((SfsStart))
        $x = $Exec.Clone()
        & $script:Listing @((SfsExec -Status 'Failed' @x))
        Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'r1' | Should -BeNullOrEmpty
        @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp -Step 'engine:assess' } $script:runPath).Count | Should -Be 0
    }

    It 'a listing Azure does not give throws, and writes nothing (unknown is never an answer)' {
        & $script:WriteLog @((SfsStart))
        Mock -ModuleName VmMigrationFactory Get-VmfArmList -ParameterFilter { $Path -like '*/executions?*' } { @{ Ok = $false; Items = @(); StatusCode = 500; Content = 'boom' } }
        { Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'r1' } | Should -Throw '*Could not list engine executions*'
        @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp -Step 'engine:assess' } $script:runPath).Count | Should -Be 0
    }

    It 'inside the five-minute pass it reads the list the pass keeps (no new Azure call)' {
        & $script:WriteLog @((SfsStart))
        $global:SfsCalls = 0
        $global:SfsItems = @((SfsExec -Status 'Running'))
        Mock -ModuleName VmMigrationFactory Get-VmfArmList -ParameterFilter { $Path -like '*/executions?*' } {
            $global:SfsCalls++; @{ Ok = $true; Items = @($global:SfsItems); StatusCode = 200; Content = $null } }
        InModuleScope FacadeCore { Start-VmfFacadeEngineListPass; Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null }
        Invoke-VmfFacadeEndSilentScan -StorePath $script:runPath -RunId 'r1' | Out-Null
        $global:SfsCalls | Should -Be 1
        Remove-Variable SfsCalls -Scope Global -ErrorAction SilentlyContinue
    }
}

Describe 'SCAN-FAIL-SHOWN-1: the five-minute pass asks it for every run it checks' {
    BeforeEach {
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sfs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:storeRoot 'r1') -Force | Out-Null
        Set-Content -Path (Join-Path $script:storeRoot 'r1' 'run.json') -Value (@{ schemaVersion = 1; runId = 'r1'; kind = 'assessment' } | ConvertTo-Json)
        $env:VMF_STORE_PATH = $script:storeRoot
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Mock Invoke-VmfFacadeReleaseDueSchedules { @() }
        Mock Invoke-VmfFacadeResumeStalledWaves { @() }
        Mock Invoke-VmfFacadeRemoveEndedWaveHolds { @() }
        Mock Invoke-VmfFacadeResumeStalledPutBacks { @() }
        Mock Invoke-VmfFacadeContinuePlan { $null }
        Mock Test-VmfFacadeRunJobRunning { $false }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force }
    }

    It 'the pass asks for the run, inside the list pass, and says what it wrote in the service log' {
        $global:SfsInPass = $null
        Mock Invoke-VmfFacadeEndSilentScan {
            $global:SfsInPass = [bool](& (Get-Module FacadeCore) { $null -ne $script:VmfEngineListPass })
            [pscustomobject]@{ Execution = 'exec-1'; Status = 'Failed'; Detail = 'd' }
        }
        $out = & $script:schedule -Timer $null 3>$null 6>&1
        Should -Invoke Invoke-VmfFacadeEndSilentScan -Times 1 -Exactly -ParameterFilter { $RunId -eq 'r1' }
        $global:SfsInPass | Should -BeTrue
        (@($out | ForEach-Object { [string]$_ }) -join "`n") | Should -Match "ended the scan of run 'r1': the engine job execution exec-1 has the status Failed"
        Remove-Variable SfsInPass -Scope Global -ErrorAction SilentlyContinue
    }

    It 'a check that throws is a warning in the service log, and the pass goes on to its other checks' {
        Mock Invoke-VmfFacadeEndSilentScan { throw 'HTTP 500' }
        $all = @(& $script:schedule -Timer $null 3>&1)
        $w = @($all | Where-Object { $_ -is [System.Management.Automation.WarningRecord] } | ForEach-Object { [string]$_ })
        ($w -join "`n") | Should -Match "scan end check failed for run 'r1': HTTP 500"
        Should -Invoke Invoke-VmfFacadeContinuePlan -Times 1 -Exactly
        # No red line in the run for a check of the service: the next pass asks again.
        Test-Path (Join-Path $script:storeRoot 'r1' 'logs' 'events.jsonl') | Should -BeFalse
    }
}

Describe 'SCAN-FAIL-SHOWN-1: a scan start puts its run in the record the pass checks' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-sfs-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:operator = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = (@{ properties = @{ template = @{ containers = @(@{
                    name = 'engine'; image = 'i'; resources = @{ cpu = 1; memory = '2Gi' }; env = @() }) } } } | ConvertTo-Json -Depth 10) }
            }
            [pscustomobject]@{ StatusCode = 202; Content = (@{ name = 'exec-7'; id = 'x' } | ConvertTo-Json) }
        }
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[]}' } }
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
    }

    It 'a scan start marks its run and holds it 15 minutes, and its start line names the execution' {
        Invoke-VmfFacadeStartEngine -Principal $script:operator -Operation 'assess' -RunId 'r1' -Project 'proj-1' -ScopeRg 'rg-a' | Out-Null
        $due = Get-Content (Join-Path $script:root 'schedule-due.json') -Raw | ConvertFrom-Json
        $due.runs[0].runId | Should -Be 'proj-1/r1'
        $due.runs[0].reason | Should -Be 'engine'
        ([datetime]::Parse($due.runs[0].holdUntilUtc).ToUniversalTime() - [datetime]::UtcNow).TotalMinutes | Should -BeGreaterThan 14
        $start = @(& (Get-Module VmMigrationFactory) { param($rp) Read-VmfEvents -RunPath $rp -Step 'engine' } (Join-Path $script:root 'proj-1' 'r1'))
        $start[-1].operation | Should -Be 'assess'
        @($start[-1].executions) | Should -Be @('exec-7')
    }

    It 'the pass keeps a run while a scan of it runs: it asks Azure about assess too' {
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        Test-VmfFacadeRunJobRunning -RunId 'p1/r1' | Should -BeTrue
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 1 -Exactly -ParameterFilter { 'assess' -in $Operation }
    }
}

Describe 'SCAN-FAIL-SHOWN-1: the engine entrypoint says where its start failed' {
    BeforeAll {
        $script:entryPath = Join-Path $script:repoRoot 'docker' 'entrypoint.ps1'
        # Runs the entrypoint in its own process with the settings given. On
        # this computer /app does not exist, so with every setting it stops at
        # the module load - before any Azure call.
        $script:RunEntry = { param([hashtable]$settings)
            $names = 'VMF_OPERATION', 'VMF_RUN_ID', 'VMF_STORE_ACCOUNT', 'VMF_STORE_CONTAINER'
            $saved = @{}
            foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n); [Environment]::SetEnvironmentVariable($n, $null) }
            try {
                foreach ($k in $settings.Keys) { [Environment]::SetEnvironmentVariable($k, $settings[$k]) }
                $text = & pwsh -NoProfile -NonInteractive -File $script:entryPath 2>&1 | ForEach-Object { [string]$_ }
                [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($text -join "`n") }
            }
            finally { foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) } }
        }
    }

    It 'a missing setting: the console names the step and the setting, and the job fails' {
        $r = & $script:RunEntry @{ VMF_OPERATION = 'assess' }
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match 'engine: starting operation=assess'
        $r.Text | Should -Match "engine: operation=assess FAILED before it started, at the step 'read the required settings': Engine misconfigured: VMF_RUN_ID is not set\."
    }

    It 'a module that does not load: the console names that step' {
        $r = & $script:RunEntry @{ VMF_OPERATION = 'assess'; VMF_RUN_ID = 'r1'; VMF_STORE_ACCOUNT = 'acct'; VMF_STORE_CONTAINER = 'c' }
        $r.Code | Should -Not -Be 0
        $r.Text | Should -Match "engine: operation=assess FAILED before it started, at the step 'load the module'"
    }

    It 'the first console line comes before anything that can fail, and every start step is inside the handler' {
        $code = Get-VmfCodeOnly -Path $script:entryPath
        $first = $code.IndexOf('engine: starting operation=')
        $first | Should -BeGreaterThan -1
        foreach ($call in 'foreach ($required in', 'Import-Module /app/src/VmMigrationFactory', 'Import-Module Az.Accounts', 'Connect-AzAccount -Identity') {
            $at = $code.IndexOf($call)
            $at | Should -BeGreaterThan $first -Because "$call comes after the first line"
        }
        $code | Should -Match "(?s)\`$startStep = 'sign in with the managed identity'\s*Connect-AzAccount -Identity.*?catch \{[^}]*FAILED before it started, at the step '\`$startStep'"
    }
}
