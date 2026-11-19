#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# TARGET-OPTIONS-WAIT-1: one advise operation of an assessment at a time.
#
# Seen in the final lab (2026-11-17): the wizard's Choose the machines step
# offered Make the target options while the engine's advise operation, started
# by the approval (ADVISOR-1), still ran. The page is fixed in
# tests/js/target-options-wait.test.js. Here: the service refuses a second
# advise of the same assessment while Azure lists one, the way it refuses a
# second start of a wave (ENGINE-START-PART-1, Test-VmfFacadeEngineRunning).
# And an approval recorded while one runs does not write a failed start into
# the run's activity: the page would show "could not be made" over options
# that are being made.

BeforeAll {
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI, so the service tests mock a stand-in, defined
    # BEFORE the guard (TEST-AZURE-GUARD-1).
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    $script:temp = New-VmfTestTemp -Prefix 'targetoptionswait'
    $script:approver = [pscustomobject]@{ Identity = 'approver@example.com'; TenantId = 't'; Roles = @('Vmf.Approver') }
    # The engine job as Azure gives it, and every start Azure is asked for.
    $script:MockArm = {
        $script:starts = [System.Collections.Generic.List[string]]::new()
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
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
    # Azure's list of the engine job's executions (Test-VmfFacadeEngineRunning).
    $script:Executions = @()
    function Global:TowExec([string]$Status, [string]$Op, [string]$Run, [string]$Project) {
        $envs = @(@{ name = 'VMF_OPERATION'; value = $Op }, @{ name = 'VMF_RUN_ID'; value = $Run })
        if ($Project) { $envs += @{ name = 'VMF_PROJECT'; value = $Project } }
        @{ name = "exec-$Status-$Op"; properties = @{ status = $Status; template = @{ containers = @(@{ env = $envs }) } } }
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
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\TowExec' -ErrorAction SilentlyContinue
    Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue
}

Describe 'TARGET-OPTIONS-WAIT-1: a second advise of an assessment whose advise runs is refused' {
    BeforeEach {
        $script:root = Join-Path $script:temp "tow-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        New-Item -ItemType Directory -Path $script:root -Force | Out-Null
        $env:VMF_STORE_PATH = $script:root
        $env:VMF_ENGINE_JOB_ID = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.App/jobs/vmf-engine'
        $script:rp = Join-Path $script:root 'alpha' 'scan-1'
        InModuleScope VmMigrationFactory -Parameters @{ rp = $script:rp } { param($rp) Initialize-VmfRun -RunPath $rp -RunId 'scan-1' -Kind 'assessment' | Out-Null }
        $script:Executions = @()
        & $script:MockExecutions
        & $script:MockArm
    }
    AfterEach { Remove-Item Env:\VMF_ENGINE_JOB_ID, Env:\VMF_STORE_PATH -ErrorAction SilentlyContinue }

    It 'refuses while Azure lists an advise of the same assessment as <Status>, before any start' -ForEach @(
        @{ Status = 'Running' }, @{ Status = 'Processing' }) {
        $script:Executions = @((TowExec $Status 'advise' 'scan-1' 'alpha'))
        { Invoke-VmfFacadeStartEngine -Principal $script:approver -Operation 'advise' -RunId 'scan-1' -Project 'alpha' } |
            Should -Throw '400: The product makes the target options for this assessment now. Wait until the list of machines shows.'
        $script:starts.Count | Should -Be 0 -Because 'the refusal comes before any start'
    }

    It 'starts while only another assessment, a finished advise or another operation is listed' {
        $script:Executions = @((TowExec 'Running' 'advise' 'scan-2' 'alpha'), (TowExec 'Running' 'advise' 'scan-1' 'beta'),
            (TowExec 'Succeeded' 'advise' 'scan-1' 'alpha'), (TowExec 'Failed' 'advise' 'scan-1' 'alpha'),
            (TowExec 'Running' 'assess' 'scan-1' 'alpha'))
        $r = Invoke-VmfFacadeStartEngine -Principal $script:approver -Operation 'advise' -RunId 'scan-1' -Project 'alpha'
        $r.execution | Should -Be 'exec-1'
        $script:starts.Count | Should -Be 1
    }

    It 'an advise start that cannot list the executions does not start' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { [pscustomobject]@{ StatusCode = 503; Content = 'busy' } }
        { Invoke-VmfFacadeStartEngine -Principal $script:approver -Operation 'advise' -RunId 'scan-1' -Project 'alpha' } |
            Should -Throw 'Could not list engine executions: HTTP 503*'
        $script:starts.Count | Should -Be 0
    }
}

Describe 'TARGET-OPTIONS-WAIT-1: an approval recorded while the options are made' {
    BeforeEach {
        $script:rp = Join-Path $script:temp "towa-$([guid]::NewGuid().ToString('N').Substring(0,8))"
        $doc = [ordered]@{ schemaVersion = 17; runId = 'scan-1'; vms = @() }
        InModuleScope VmMigrationFactory -Parameters @{ p = $script:rp; d = $doc } {
            Initialize-VmfRun -RunPath $p -RunId 'scan-1' -Kind 'assessment' | Out-Null
            Write-VmfStoreJson -RunPath $p -RelPath 'assessment.json' -Document $d -Depth 24
        }
    }

    It 'says the options are being made, and writes no failed start, when the start is refused because one runs' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw '400: The product makes the target options for this assessment now. Wait until the list of machines shows.' }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $true }
        $r = Invoke-VmfFacadeApproveAssessment -Principal $script:approver -StorePath $script:rp -RunId 'scan-1' -Project 'alpha'
        Test-Path (Join-Path $script:rp 'approval.json') | Should -BeTrue
        $r.TargetOptions.started | Should -BeTrue -Because 'an advise of this assessment runs, and its options come'
        $r.TargetOptions.error | Should -BeNullOrEmpty
        @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine:advise' -and $_.outcome -eq 'fail' }).Count |
            Should -Be 0 -Because 'a failed line makes the page say the options could not be made'
        Should -Invoke Test-VmfFacadeEngineRunning -ModuleName FacadeCore -Times 1 -ParameterFilter {
            ($Operation -contains 'advise') -and $RunId -eq 'scan-1' -and $Project -eq 'alpha'
        }
    }

    It 'still writes the failed start when no advise runs' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'the engine job could not be read' }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { $false }
        $r = Invoke-VmfFacadeApproveAssessment -Principal $script:approver -StorePath $script:rp -RunId 'scan-1'
        $r.TargetOptions.started | Should -BeFalse
        $r.TargetOptions.error | Should -Match 'did not start'
        @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine:advise' -and $_.outcome -eq 'fail' }).Count | Should -Be 1
    }

    It 'still writes the failed start when the list of executions cannot be read either' {
        Mock -ModuleName FacadeCore Invoke-VmfFacadeStartEngine { throw 'Could not list engine executions: HTTP 503 busy' }
        Mock -ModuleName FacadeCore Test-VmfFacadeEngineRunning { throw 'Could not list engine executions: HTTP 503 busy' }
        $r = Invoke-VmfFacadeApproveAssessment -Principal $script:approver -StorePath $script:rp -RunId 'scan-1'
        $r.TargetOptions.started | Should -BeFalse
        @(& $script:Events $script:rp | Where-Object { $_.step -eq 'engine:advise' -and $_.outcome -eq 'fail' }).Count | Should -Be 1
    }
}
