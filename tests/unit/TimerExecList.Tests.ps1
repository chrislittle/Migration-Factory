#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
TIMER-EXEC-LIST-1: the service's five-minute pass lists the engine job's
executions from ARM ONCE, and answers every "does a run of the engine go on?"
question of the pass from that one list.

Before it, Invoke-VmfFacadeResumeStalledPutBacks asked
Test-VmfFacadeEngineRunning once for each machine with an open restore or
finish, and each question read every page of the executions from ARM again.
The stalled-wave pass, the hold pass and the next-wave decision asked again.

What the list may never do:
  - answer a question after anything started an execution: a start inside
    the pass makes the next question read Azure again, or a wave or a restore
    could start twice (ENGINE-START-PART-1, RESTORE-ONE-AT-A-TIME-1);
  - answer the start's own guard: Invoke-VmfFacadeStartEngine reads Azure
    itself, every time;
  - turn a listing that failed into "not running": a failed read throws, as
    it did, and is never kept;
  - live longer than 30 seconds, or outside a pass: a request reads Azure.
#>
BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:schedule = Join-Path $script:repoRoot 'src' 'facade' 'app' 'ScheduleRunner' 'run.ps1'
    $script:jobId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.App/jobs/engine'

    # One engine execution as ARM lists it (JSON, as Get-VmfArmList gives it).
    function Global:TelExec {
        param([string]$Status = 'Running', [string]$Op = 'restore', [string]$Run = 'r1', [string]$Vm, [string]$Wave)
        $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
        if ($Vm) { $envs += @{ name = 'VMF_VM_ID'; value = $Vm } }
        if ($Wave) { $envs += @{ name = 'VMF_WAVE'; value = $Wave } }
        @{ name = "exec-$Op"; properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } } |
            ConvertTo-Json -Depth 10 | ConvertFrom-Json
    }

    # The executions listing, counted. $global:TelPages is a list of answers,
    # one per call; the last answer repeats. An answer of 'fail' is a listing
    # Azure refused.
    function Script:Mock-TelListing {
        param([object[]]$Pages)
        $global:TelCalls = 0
        $global:TelPages = $Pages
        Mock -ModuleName VmMigrationFactory Get-VmfArmList -ParameterFilter { $Path -like '*/executions?*' } {
            $global:TelCalls++
            $i = [math]::Min($global:TelCalls, @($global:TelPages).Count) - 1
            $page = @($global:TelPages)[$i]
            if ($page -is [string] -and $page -eq 'fail') { return @{ Ok = $false; Items = @(); StatusCode = 500; Content = 'boom' } }
            @{ Ok = $true; Items = @($page | Where-Object { $_ }); StatusCode = 200; Content = $null }
        }
    }

    # A machine record with an open restore (not ended), as the pass reads it.
    function Global:TelDoc {
        param([string]$Vm, [string]$OpId)
        [pscustomobject]@{ vmId = $Vm; state = 'MIGRATED'; putBackJob = [pscustomobject][ordered]@{
            kind = 'restore'; operationId = $OpId; startedBy = 'operator@example.com'; phase = 'osSwapped'
            resumes = 0; options = [pscustomobject]@{ from = 'pristine' } } }
    }
}

AfterAll {
    InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
    Remove-Item 'function:\TelExec', 'function:\TelDoc' -ErrorAction SilentlyContinue
    Remove-Variable TelCalls, TelPages, TelResumes, TelPassSeen -Scope Global -ErrorAction SilentlyContinue
}

Describe 'TIMER-EXEC-LIST-1: one listing answers the questions of a pass' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = $script:jobId
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
    }

    It 'outside a pass, every question reads Azure (a request never gets a kept list)' {
        Script:Mock-TelListing -Pages @(, @())
        InModuleScope FacadeCore {
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Should -BeFalse
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Should -BeFalse
        }
        $global:TelCalls | Should -Be 2
    }

    It 'inside a pass, different questions are each answered right, from one listing' {
        Script:Mock-TelListing -Pages @(, @(
            (TelExec -Op 'wave' -Wave 'w1'),
            (TelExec -Op 'restore' -Vm '/s/rg/vm/a'),
            (TelExec -Status 'Succeeded' -Op 'discard')))
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' | Should -BeTrue
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w2' | Should -BeFalse
            Test-VmfFacadeEngineRunning -Operation @('restore', 'finish') -RunId 'r1' -VmId '/S/RG/VM/A' | Should -BeTrue
            Test-VmfFacadeEngineRunning -Operation @('restore', 'finish') -RunId 'r1' -VmId '/s/rg/vm/b' | Should -BeFalse
            Test-VmfFacadeEngineRunning -Operation 'discard' -RunId 'r1' | Should -BeFalse
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r2' | Should -BeFalse
        }
        $global:TelCalls | Should -Be 1
    }

    It 'a kept list older than 30 seconds is read again; a younger one is not' {
        Script:Mock-TelListing -Pages @(, @())
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null
            $script:VmfEngineListPass.ReadUtc = [datetime]::UtcNow.AddSeconds(-29)
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null
        }
        $global:TelCalls | Should -Be 1
        InModuleScope FacadeCore {
            $script:VmfEngineListPass.ReadUtc = [datetime]::UtcNow.AddSeconds(-31)
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null
        }
        $global:TelCalls | Should -Be 2
    }

    It '-Fresh reads Azure even with a kept list, and does not change the kept list' {
        Script:Mock-TelListing -Pages @(@(), @((TelExec -Op 'wave' -Wave 'w1')))
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' | Should -BeFalse
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' -Fresh | Should -BeTrue
            # The kept list is still the pass's own read.
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' | Should -BeFalse
        }
        $global:TelCalls | Should -Be 2
    }

    It 'Stop ends the pass: the next question reads Azure' {
        Script:Mock-TelListing -Pages @(, @())
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null
            Stop-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null
        }
        $global:TelCalls | Should -Be 2
    }
}

Describe 'TIMER-EXEC-LIST-1: a listing that failed is never "not running"' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = $script:jobId
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
    }

    It 'throws, and the next question reads Azure again (a failure is not kept)' {
        Script:Mock-TelListing -Pages @('fail')
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' } | Should -Throw 'Could not list engine executions: HTTP 500'
            { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' } | Should -Throw 'Could not list engine executions: HTTP 500'
        }
        $global:TelCalls | Should -Be 2
    }

    It 'a read again that fails throws - it never falls back to the old list' {
        Script:Mock-TelListing -Pages @(@((TelExec -Op 'wave' -Wave 'w1')), 'fail')
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' | Should -BeTrue
            $script:VmfEngineListPass.ReadUtc = [datetime]::UtcNow.AddSeconds(-31)
            { Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' } | Should -Throw 'Could not list engine executions: HTTP 500'
            $script:VmfEngineListPass.Items | Should -BeNullOrEmpty
        }
    }

    It 'the put-back pass starts nothing when the listing fails' {
        Script:Mock-TelListing -Pages @('fail')
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $false }
        Mock -ModuleName VmMigrationFactory Update-VmfPutBackJobRecord { $true }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'started' }
        $docs = @((TelDoc -Vm '/s/rg/vm/a' -OpId 'op-a'))
        InModuleScope FacadeCore { Start-VmfFacadeEngineListPass }
        { Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $TestDrive 'r1') -RunId 'r1' -StateDocs $docs } |
            Should -Throw 'Could not list engine executions: HTTP 500'
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Update-VmfPutBackJobRecord -Times 0 -Exactly
    }
}

Describe 'TIMER-EXEC-LIST-1: the put-back pass' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = $script:jobId
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tel-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:store 'r1') -Force | Out-Null
        $env:VMF_STORE_PATH = $script:store
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Mock -ModuleName VmMigrationFactory Test-VmfMachineHeldNow { $false }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        $global:TelResumes = @()
        Mock -ModuleName VmMigrationFactory Update-VmfPutBackJobRecord { $global:TelResumes += "$Action $OperationId"; $true }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force }
    }

    It 'one listing for three open restores that Azure lists as running' {
        Script:Mock-TelListing -Pages @(, @(
            (TelExec -Vm '/s/rg/vm/a'), (TelExec -Vm '/s/rg/vm/b'), (TelExec -Status 'Processing' -Op 'finish' -Vm '/s/rg/vm/c')))
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'started' }
        $docs = @((TelDoc -Vm '/s/rg/vm/a' -OpId 'op-a'), (TelDoc -Vm '/s/rg/vm/b' -OpId 'op-b'), (TelDoc -Vm '/s/rg/vm/c' -OpId 'op-c'))
        InModuleScope FacadeCore { Start-VmfFacadeEngineListPass }
        $out = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:store 'r1') -RunId 'r1' -StateDocs $docs)
        $out.Count | Should -Be 0
        $global:TelCalls | Should -Be 1
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
    }

    It 'a start inside the pass makes the next question read Azure again' {
        # Azure lists nothing for the first two reads (the pass, then the
        # start's own guard); after the start of 'a', it lists a restore of
        # 'b' - which the pass must see, and so not start 'b'.
        Script:Mock-TelListing -Pages @(@(), @(), @((TelExec -Vm '/s/rg/vm/b')))
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Send-VmfFacadeArmRequest { [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-new"}' } }
        $docs = @((TelDoc -Vm '/s/rg/vm/a' -OpId 'op-a'), (TelDoc -Vm '/s/rg/vm/b' -OpId 'op-b'))
        InModuleScope FacadeCore { Start-VmfFacadeEngineListPass }
        $out = @(Invoke-VmfFacadeResumeStalledPutBacks -StorePath (Join-Path $script:store 'r1') -RunId 'r1' -StateDocs $docs)
        @($out | Where-Object { $_.Action -eq 'resumed' } | ForEach-Object { $_.VmId }) | Should -Be @('/s/rg/vm/a')
        $global:TelResumes | Should -Be @('resume op-a') -Because 'b runs now, so it is not counted or started'
        $global:TelCalls | Should -Be 3
        Should -Invoke -ModuleName FacadeCore Send-VmfFacadeArmRequest -Times 1 -Exactly
    }
}

Describe 'TIMER-EXEC-LIST-1: the start reads Azure itself, and empties the kept list' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = $script:jobId
        $script:store = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tel-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:store 'r1') -Force | Out-Null
        $env:VMF_STORE_PATH = $script:store
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Mock -ModuleName FacadeCore Get-VmfFacadeEngineJob {
            [pscustomobject]@{ properties = [pscustomobject]@{ template = [pscustomobject]@{ containers = @([pscustomobject]@{
                name = 'engine'; image = 'acr/vmf-engine:dev'; resources = [pscustomobject]@{ cpu = 1; memory = '2Gi' }; env = @() }) } } }
        }
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveThrottle { 2 }
        Mock -ModuleName FacadeCore Get-VmfFacadeWaveContainers { $null }
        Mock -ModuleName VmMigrationFactory Write-VmfStepLine { }
        $script:op = [pscustomobject]@{ Identity = 'operator@example.com'; Roles = @('Vmf.Operator') }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:store) { Remove-Item $script:store -Recurse -Force }
    }

    It 'a wave start is refused when Azure lists its wave, whatever the kept list says' {
        Script:Mock-TelListing -Pages @(@(), @((TelExec -Op 'wave' -Wave 'w1')))
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Send-VmfFacadeArmRequest { throw 'reached the engine start' }
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' -Wave 'w1' | Should -BeFalse
        }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'r1' -Wave 'w1' -Note 'n' } |
            Should -Throw '400: Wave w1 runs now*'
    }

    It 'a restore start is refused when Azure lists a restore of the machine, whatever the kept list says' {
        Script:Mock-TelListing -Pages @(@(), @((TelExec -Vm '/s/rg/vm/a')))
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Send-VmfFacadeArmRequest { throw 'reached the engine start' }
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation @('restore', 'finish') -RunId 'r1' -VmId '/s/rg/vm/a' | Should -BeFalse
        }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'restore' -RunId 'r1' -VmId '/s/rg/vm/a' -Note 'n' } |
            Should -Throw '400: The engine works on this machine now*'
    }

    It 'the delete check of the start reads Azure itself' {
        # A delete is open in the log; the kept list has no discard, Azure does.
        Script:Mock-TelListing -Pages @(@(), @((TelExec -Op 'discard')))
        Set-Content -Path (Join-Path $script:store 'r1' 'run.json') -Value (@{ schemaVersion = 1; runId = 'r1'; kind = 'migration' } | ConvertTo-Json)
        Mock -ModuleName FacadeCore Get-VmfFacadeOpenDiscard { [pscustomobject]@{ step = 'discard'; outcome = 'start' } }
        Mock -ModuleName FacadeCore Send-VmfFacadeArmRequest { throw 'reached the engine start' }
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'discard' -RunId 'r1' | Should -BeFalse
        }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'r1' -Wave 'w1' -Note 'n' } |
            Should -Throw '400: This migration is being deleted*'
    }

    It 'a start that Azure accepts empties the kept list' {
        Script:Mock-TelListing -Pages @(, @())
        Mock -ModuleName FacadeCore Assert-VmfFacadeNotBeingDeleted { }
        Mock -ModuleName FacadeCore Send-VmfFacadeArmRequest { [pscustomobject]@{ StatusCode = 202; Content = '{"name":"exec-new"}' } }
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Out-Null
        }
        $global:TelCalls | Should -Be 1
        $r = Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'r1' -Wave 'w1' -Note 'n'
        $r.execution | Should -Be 'exec-new'
        InModuleScope FacadeCore { $null -eq $script:VmfEngineListPass.Items | Should -BeTrue }
    }

    It 'a start that throws empties the kept list too (Azure may have made it)' {
        Script:Mock-TelListing -Pages @(, @())
        Set-Content -Path (Join-Path $script:store 'r1' 'run.json') -Value (@{ schemaVersion = 1; runId = 'r1'; kind = 'migration' } | ConvertTo-Json)
        # The real delete check runs, and reads the list through the pass.
        Mock -ModuleName FacadeCore Get-VmfFacadeOpenDiscard { [pscustomobject]@{ step = 'discard'; outcome = 'start' } }
        Mock -ModuleName FacadeCore Send-VmfFacadeArmRequest { throw 'the answer was lost' }
        InModuleScope FacadeCore { Start-VmfFacadeEngineListPass }
        { Invoke-VmfFacadeStartEngine -Principal $script:op -Operation 'wave' -RunId 'r1' -Wave 'w1' -Note 'n' } | Should -Throw '*the answer was lost*'
        InModuleScope FacadeCore { $null -eq $script:VmfEngineListPass.Items | Should -BeTrue }
    }
}

Describe 'TIMER-EXEC-LIST-1: the next-wave decision' {
    BeforeEach {
        $env:VMF_ENGINE_JOB_ID = $script:jobId
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Mock -ModuleName VmMigrationFactory Set-VmfPlanRunStatus { }
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'started' }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_ENGINE_JOB_ID -ErrorAction SilentlyContinue
    }

    It 'before it starts a wave, it reads Azure itself: any wave of the run that runs holds the start' {
        # The start's own guard asks about the wave it starts only, so this
        # question - any wave of the run - is asked of Azure, not the kept list.
        Script:Mock-TelListing -Pages @(@(), @((TelExec -Op 'wave' -Wave 'w3')))
        Mock -ModuleName VmMigrationFactory Get-VmfPlanRunDecision {
            [pscustomobject]@{ Wave = 'w2'; Reason = 'start'; Detail = 'wave w1 finished'; WaveVersion = 'v'; After = 'w1' }
        }
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Should -BeFalse
        }
        Invoke-VmfFacadeContinuePlan -StorePath (Join-Path $TestDrive 'r1') -RunId 'r1' | Should -BeNullOrEmpty
        Should -Invoke -ModuleName FacadeCore Invoke-VmfFacadeStartEngine -Times 0 -Exactly
    }

    It 'a plan that has not begun asks the kept list (no start follows that answer)' {
        Script:Mock-TelListing -Pages @(, @((TelExec -Op 'wave' -Wave 'w1')))
        Mock -ModuleName VmMigrationFactory Get-VmfPlanRunDecision { [pscustomobject]@{ Wave = $null; Reason = 'notStarted'; Detail = 'x' } }
        InModuleScope FacadeCore {
            Start-VmfFacadeEngineListPass
            Test-VmfFacadeEngineRunning -Operation 'wave' -RunId 'r1' | Should -BeTrue
        }
        Invoke-VmfFacadeContinuePlan -StorePath (Join-Path $TestDrive 'r1') -RunId 'r1' | Out-Null
        $global:TelCalls | Should -Be 1
        Should -Invoke -ModuleName VmMigrationFactory Set-VmfPlanRunStatus -Times 0 -Exactly
    }
}

Describe 'TIMER-EXEC-LIST-1: the five-minute pass holds one list, and lets it go' {
    BeforeEach {
        $script:storeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-tel-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path (Join-Path $script:storeRoot 'r1') -Force | Out-Null
        Set-Content -Path (Join-Path $script:storeRoot 'r1' 'run.json') -Value (@{ schemaVersion = 1; runId = 'r1'; kind = 'migration' } | ConvertTo-Json)
        $env:VMF_STORE_PATH = $script:storeRoot
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        $global:TelPassSeen = @()
        $seen = { $global:TelPassSeen += [bool](& (Get-Module FacadeCore) { $null -ne $script:VmfEngineListPass }); @() }
        Mock Invoke-VmfFacadeReleaseDueSchedules $seen
        Mock Invoke-VmfFacadeResumeStalledWaves $seen
        Mock Invoke-VmfFacadeRemoveEndedWaveHolds $seen
        Mock Invoke-VmfFacadeResumeStalledPutBacks $seen
        Mock Invoke-VmfFacadeEndSilentScan { $global:TelPassSeen += [bool](& (Get-Module FacadeCore) { $null -ne $script:VmfEngineListPass }); $null }
        Mock Invoke-VmfFacadeContinuePlan { $global:TelPassSeen += [bool](& (Get-Module FacadeCore) { $null -ne $script:VmfEngineListPass }); $null }
    }
    AfterEach {
        InModuleScope FacadeCore { Stop-VmfFacadeEngineListPass }
        Remove-Item Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
        if (Test-Path $script:storeRoot) { Remove-Item $script:storeRoot -Recurse -Force }
    }

    It 'every check of the pass runs inside one list pass, and the pass ends with it' {
        & $script:schedule -Timer $null 3>$null
        $global:TelPassSeen.Count | Should -Be 6 -Because 'SCAN-FAIL-SHOWN-1 added the scan end check'
        $global:TelPassSeen | Should -Not -Contain $false
        InModuleScope FacadeCore { $null -eq $script:VmfEngineListPass | Should -BeTrue }
    }

    It 'a pass that fails before it reads the runs still lets the list go' {
        Mock Get-VmfFacadeRunIds { throw 'store down' }
        & $script:schedule -Timer $null 3>$null
        InModuleScope FacadeCore { $null -eq $script:VmfEngineListPass | Should -BeTrue }
        Should -Invoke Get-VmfFacadeRunIds -Times 1 -Exactly
    }
}
