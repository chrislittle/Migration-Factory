#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
FACADE-TIMER-QUEUE-1: the service's five-minute schedule timer took 60 to 133
seconds a pass on the lab installation, grew with the store, and reached the
5-minute function limit (PERF-ANALYSIS-1 measured it over 7 days).

The pass read every machine record of every run THREE times (the stalled-wave
pass, the put-back pass, the next-wave decision), and for a restore the
service gave up on it read the hold, listed the engine's executions from ARM
and read the whole run log, every pass, to do nothing with the answer.
These tests hold the pass to one read of each machine record for those two
passes, no record read by the decision when the plan is not signed off or the
run is paused, and no work for a record it will skip.

Dashboard calls do NOT wait behind the timer (PERF-ANALYSIS-1), so this item
sets no concurrency setting.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    . (Join-Path $PSScriptRoot '_RecordVersion.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'

    # A plan of two waves of two machines, as PlanRun.Tests.ps1 builds it.
    $script:plan = [pscustomobject]@{ assessmentRunId = 'r1'; entries = @(
        foreach ($w in 'w1', 'w2') { foreach ($n in 'a', 'b') {
            [pscustomobject]@{ schemaVersion = (Get-VmfTestPlanEntryVersion); vmId = "/s/rg/vm/$w$n"; wave = $w; path = 'A'; policy = [pscustomobject]@{ throttle = 2 } } } }) }

    function Script:New-FtqRun {
        param([string]$Root, [string]$RunId = 'r1', [switch]$SignOff, [string]$State = 'MIGRATED')
        $rp = Join-Path $Root $RunId
        New-Item -ItemType Directory -Path $rp -Force | Out-Null
        $script:plan | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $rp 'plan.json')
        Set-Content -Path (Join-Path $rp 'run.json') -Value (@{ schemaVersion = 1; runId = $RunId; kind = 'migration' } | ConvertTo-Json)
        if ($SignOff) {
            Approve-VmfPlan -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') -Note 'reviewed' `
                -OnBehalfOf @{ Identity = 'approver@example.com'; TenantId = $null } | Out-Null
        }
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp; st = $State } {
            foreach ($n in 'a', 'b') {
                New-VmfStateDoc -RunPath $rp -RunId 'r1' -VmId "/s/rg/vm/w1$n" -Wave 'w1' | Out-Null
                Add-VmfStateTransition -RunPath $rp -VmId "/s/rg/vm/w1$n" -NewState $st -Outcome ok | Out-Null
            }
        }
        $rp
    }

    # A machine record that carries a restore the service gave up on
    # (RESUME-GIVEUP-KEEP-1): ended, reason gaveUp.
    function Script:Add-FtqGaveUpRestore {
        param([string]$RunPath, [string]$VmName = 'w1a')
        $file = Get-ChildItem (Join-Path $RunPath 'state') -Filter '*.json' |
            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).vmId -like "*/$VmName" } | Select-Object -First 1
        $doc = Get-Content $file.FullName -Raw | ConvertFrom-Json -Depth 30
        $doc | Add-Member -NotePropertyName putBackJob -Force -NotePropertyValue ([pscustomobject][ordered]@{
            kind = 'restore'; operationId = 'op-gaveup-1'; startedBy = 'operator@example.com'; phase = 'osSwapped'
            resumes = 3; options = [pscustomobject]@{ from = 'pristine' }
            ended = [pscustomobject]@{ reason = 'gaveUp'; why = 'it did not finish' } })
        $doc | ConvertTo-Json -Depth 30 | Set-Content $file.FullName
    }

    # How many times a machine record was read, counted in the module's own
    # store call. The real one runs, by name: a mock's $PSBoundParameters is
    # empty.
    function Script:Mock-FtqCountStateReads {
        $global:FtqStateReads = 0
        Mock -ModuleName VmMigrationFactory Read-VmfStoreJson {
            if ([string]$RelPath -like 'state/*') { $global:FtqStateReads++ }
            & (Get-Module VmMigrationFactory) { param($a, $b, $c)
                & (Get-Command Read-VmfStoreJson -CommandType Function) -RunPath $a -RelPath $b -Depth $c
            } $RunPath $RelPath $(if ($Depth) { $Depth } else { 24 })
        }
    }
}

Describe 'FACADE-TIMER-QUEUE-1: the next-wave decision reads machine records only when it can use them' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ftq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Mock -ModuleName VmMigrationFactory Test-VmfRunAcknowledged { @{ Pass = $true; Detail = 'acknowledged' } }
        Mock -ModuleName VmMigrationFactory Test-VmfWaveOptionsAccepted { @{ Pass = $true; Detail = 'accepted' } }
    }
    AfterEach { if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force } }

    It 'a plan nobody signed off: the same answer, and no machine record is listed or read' {
        $rp = Script:New-FtqRun -Root $script:root
        Script:Mock-FtqCountStateReads
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames { @() } -ParameterFilter { $Folder -eq 'state' }
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Get-VmfPlanRunDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') }
        $d.Reason | Should -Be 'notSigned'
        $d.Detail | Should -Be 'the plan has not been signed off, so no wave starts on its own'
        $d.Wave | Should -BeNullOrEmpty
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfStoreNames -Times 0 -Exactly -ParameterFilter { $Folder -eq 'state' }
        $global:FtqStateReads | Should -Be 0
    }

    It 'a paused run: the same answer, and no machine record is listed or read' {
        $rp = Script:New-FtqRun -Root $script:root -SignOff
        InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Set-VmfWaveHalt -RunPath $rp -Reason 'paused for the test' | Out-Null }
        Script:Mock-FtqCountStateReads
        Mock -ModuleName VmMigrationFactory Get-VmfStoreNames { @() } -ParameterFilter { $Folder -eq 'state' }
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Get-VmfPlanRunDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') }
        $d.Reason | Should -Be 'halted'
        $d.Detail | Should -Be 'the run is paused, so no wave starts on its own until somebody resumes it'
        Should -Invoke -ModuleName VmMigrationFactory Get-VmfStoreNames -Times 0 -Exactly -ParameterFilter { $Folder -eq 'state' }
        $global:FtqStateReads | Should -Be 0
    }

    It 'a signed-off plan still reads the records: wave 1 at work holds wave 2' {
        $rp = Script:New-FtqRun -Root $script:root -SignOff -State 'CONVERTING'
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Get-VmfPlanRunDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') }
        $d.Reason | Should -Be 'running'
    }

    It 'and when wave 1 has finished, names wave 2' {
        $rp = Script:New-FtqRun -Root $script:root -SignOff
        $d = InModuleScope VmMigrationFactory -Parameters @{ rp = $rp } { Get-VmfPlanRunDecision -RunPath $rp -PlanPath (Join-Path $rp 'plan.json') }
        $d.Reason | Should -Be 'start'
        $d.Wave | Should -Be 'w2'
    }
}

Describe 'FACADE-TIMER-QUEUE-1: a restore the service gave up on costs the pass nothing' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ftq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:rp = Script:New-FtqRun -Root $script:root
        Script:Add-FtqGaveUpRestore -RunPath $script:rp
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.App/jobs/engine'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = 'exec-1' } }
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $false }
        Mock -ModuleName VmMigrationFactory Read-VmfEvents { @() }
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
    }

    It 'asks Azure nothing, reads no hold and no run log, and acts on nothing' {
        $out = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath $script:rp -RunId 'r1')
        $out.Count | Should -Be 0
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfMachineHeldNow -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Read-VmfEvents -Times 0 -Exactly
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
    }

    It 'and the record stays, so it still keeps the safety copies' {
        Invoke-VmfFacadeResumeStalledPutBacks -StorePath $script:rp -RunId 'r1' | Out-Null
        $kept = Get-ChildItem (Join-Path $script:rp 'state') -Filter '*.json' |
            ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json } | Where-Object { $_.putBackJob }
        @($kept).Count | Should -Be 1
        $kept.putBackJob.ended.reason | Should -Be 'gaveUp'
    }

    It 'a restore that stopped part way is still asked about, as before' {
        $file = Get-ChildItem (Join-Path $script:rp 'state') -Filter '*.json' |
            Where-Object { (Get-Content $_.FullName -Raw | ConvertFrom-Json).putBackJob } | Select-Object -First 1
        $doc = Get-Content $file.FullName -Raw | ConvertFrom-Json -Depth 30
        $doc.putBackJob.ended = $null
        $doc | ConvertTo-Json -Depth 30 | Set-Content $file.FullName
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        Invoke-VmfFacadeResumeStalledPutBacks -StorePath $script:rp -RunId 'r1' | Out-Null
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfMachineHeldNow -Times 1 -Exactly
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 1 -Exactly
    }
}

Describe 'FACADE-TIMER-QUEUE-1: the stalled-wave and put-back passes take the records they are given' {
    BeforeEach {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ftq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $script:rp = Script:New-FtqRun -Root $script:root -State 'CONVERTING'
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.App/jobs/engine'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = 'exec-1' } }
    }
    AfterEach {
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
    }

    It 'reads the records of a run once, with nothing left out' {
        $docs = @(Get-VmfFacadeRunStateDocs -StorePath $script:rp)
        $docs.Count | Should -Be 2
        @($docs | ForEach-Object { [string]$_.state }) | Should -Be @('CONVERTING', 'CONVERTING')
    }

    It 'the stalled-wave pass judges from the records it is given, and reads none' {
        $given = @(Get-VmfFacadeRunStateDocs -StorePath $script:rp)
        Script:Mock-FtqCountStateReads
        Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rp -RunId 'r1' -StateDocs $given | Out-Null
        $global:FtqStateReads | Should -Be 0
        # Machines at work, no live hold: it went on to ask Azure about wave w1.
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 1 -Exactly -ParameterFilter { $Wave -eq 'w1' }
    }

    It 'and given no machine at work, it asks Azure nothing' {
        $given = @(Get-VmfFacadeRunStateDocs -StorePath $script:rp | ForEach-Object { $_.state = 'MIGRATED'; $_ })
        Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rp -RunId 'r1' -StateDocs $given | Out-Null
        Should -Invoke -ModuleName FacadeCore Test-VmfFacadeEngineRunning -Times 0 -Exactly
    }

    It 'with no records given, it reads them itself, as before' {
        Script:Mock-FtqCountStateReads
        Invoke-VmfFacadeResumeStalledWaves -StorePath $script:rp -RunId 'r1' | Out-Null
        $global:FtqStateReads | Should -Be 2
    }

    It 'the put-back pass judges from the records it is given, and reads none' {
        Script:Add-FtqGaveUpRestore -RunPath $script:rp
        $given = @(Get-VmfFacadeRunStateDocs -StorePath $script:rp)
        ($given | ForEach-Object { $_.putBackJob.ended }) | Where-Object { $_ } | ForEach-Object { $_.reason = $null }
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $true }
        Script:Mock-FtqCountStateReads
        Invoke-VmfFacadeResumeStalledPutBacks -StorePath $script:rp -RunId 'r1' -StateDocs $given | Out-Null
        $global:FtqStateReads | Should -Be 0
        # The record given (open, not given up) was judged: its hold was asked.
        Should -Invoke -ModuleName VmMigrationFactory Test-VmfMachineHeldNow -Times 1 -Exactly
    }
}

Describe 'FACADE-TIMER-QUEUE-1: one pass reads each machine record once' {
    BeforeAll {
        $script:root = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-ftq-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        Script:New-FtqRun -Root $script:root -RunId 'r1' | Out-Null
        Script:New-FtqRun -Root $script:root -RunId 'r2' | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/0/resourceGroups/rg/providers/Microsoft.App/jobs/engine'
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { [pscustomobject]@{ execution = 'exec-1' } }
    }
    AfterAll {
        Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
        if (Test-Path $script:root) { Remove-Item $script:root -Recurse -Force }
    }

    It 'two runs of two machines, nobody signed off: four records, four reads' {
        # Before: 12 - the stalled-wave pass, the put-back pass and the
        # next-wave decision each read every record of every run.
        Script:Mock-FtqCountStateReads
        & $script:schedule -Timer $null 3>$null
        $global:FtqStateReads | Should -Be 4
    }

    It 'gives the same records to the stalled-wave pass and the put-back pass' {
        $code = Get-VmfCodeOnly -Path $script:schedule
        $code | Should -Match 'Get-VmfFacadeRunStateDocs -StorePath \$store'
        $code | Should -Match 'Invoke-VmfFacadeResumeStalledWaves -StorePath \$store -RunId \$runId -StateDocs \$stateDocs'
        # TIMER-PASS-LIMIT-1: through Select-VmfScheduleStateDocs, which gives
        # them while they are fresh (SchedulePass.Tests.ps1).
        $code | Should -Match '\$putBackDocs = & \(Get-Module VmMigrationFactory\) \{ param\(\$d, \$t\) Select-VmfScheduleStateDocs -StateDocs \$d -ReadUtc \$t \} \$stateDocs \$stateDocsReadUtc'
        $code | Should -Match 'Invoke-VmfFacadeResumeStalledPutBacks -StorePath \$store -RunId \$runId -StateDocs \$putBackDocs'
    }

    It 'a read that fails gives the passes nothing, so each reads for itself and says its own failure' {
        $code = Get-VmfCodeOnly -Path $script:schedule
        $code | Should -Match '(?s)try \{ \$stateDocs = @\(Get-VmfFacadeRunStateDocs -StorePath \$store\) \}\s*catch \{ \$stateDocs = \$null \}'
    }
}
