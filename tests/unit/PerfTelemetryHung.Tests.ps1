#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
# PERF-TELEMETRY-HUNG-1: a call of the service that gets no answer still ends
# inside the Functions time limit (five minutes on Consumption; host.json sets
# no functionTimeout), or is named in a line before that limit. A call the
# host stops at the limit never reaches its finally, so it writes no
# VMF-CALLS line at all.
#
# MEASURED 2026-11-08, Az.Accounts 5.5.2 (the install pins 5.5.4), against a
# local stand-in for ARM and the managed identity endpoint that accepts a
# request and never answers:
#   - Invoke-AzRestMethod: one request, no retry, no end after 10 minutes. So
#     an ARM request of the service had NO limit.
#   - Invoke-AzRestMethod -AsJob, then Stop-Job after 10 s: the job stopped at
#     once. A good request costs the same as a direct call (10 to 20 ms), and
#     a request that throws gives the job the same exception and message.
#   - Get-AzAccessToken for the store: 100 s for each try, then again
#     (TOKEN-REQUEST-HUNG-1).
#   - A store request: HttpClient's 100 s for each attempt and 5 attempts
#     (STORE-REQUEST-TIMEOUT-1), so up to about 8 minutes.
BeforeAll {
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    $script:repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    Import-Module (Join-Path $script:repoRoot 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    Import-Module (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psd1') -Force
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: stand-ins to mock, defined BEFORE the guard.
    # This one can run as a job, as the real cmdlet can.
    function Global:Invoke-AzRestMethod { param($Method, $Path, $Payload, $Uri, [switch]$AsJob) throw 'stub' }
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    function Global:Reset-HungSink {
        $global:VmfHungLines = [System.Collections.Generic.List[string]]::new()
    }
    function Global:Get-HungRecord {
        @($global:VmfHungLines) | ForEach-Object {
            $_ | Should -Match '^VMF-CALLS \{'
            $_.Substring('VMF-CALLS '.Length) | ConvertFrom-Json -Depth 10
        }
    }
    function Global:New-HungViewer {
        $doc = @{ auth_typ = 'aad'; claims = @(@{ typ = 'preferred_username'; val = 'viewer@example.com' }, @{ typ = 'roles'; val = 'Vmf.Viewer' }) } | ConvertTo-Json -Depth 5
        ConvertFrom-VmfClientPrincipal -Header ([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($doc)))
    }
    # A job that never ends, as a request that gets no answer. Thread.Sleep in
    # short steps, so a stop ends it between two of them.
    function Global:New-HungJob { Start-ThreadJob -ScriptBlock { while ($true) { [System.Threading.Thread]::Sleep(20) } } }
    $script:sub = 'aaaa0a0a-bb1b-cc2c-dd3d-eeeeee4e4e4e'
    # The values the module loads with, before any test changes them.
    $script:armLimitAtLoad = InModuleScope VmMigrationFactory { $script:VmfArmAnswerLimitMs }
    $script:heldMsAtLoad = InModuleScope VmMigrationFactory { $script:VmfCallTimingHeldMs }
}
AfterAll {
    Remove-Item 'function:\Invoke-AzRestMethod', 'function:\Get-AzAccessToken', 'function:\Reset-HungSink',
        'function:\Get-HungRecord', 'function:\New-HungViewer', 'function:\New-HungJob' -ErrorAction SilentlyContinue
}

Describe 'PERF-TELEMETRY-HUNG-1: an ARM request has a time limit' {
    BeforeEach {
        Reset-HungSink
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfHungLines.Add($Message) }
        InModuleScope VmMigrationFactory { $script:VmfCallTimingSlowMs = 0; $script:VmfArmAnswerLimitMs = 300 }
        $global:VmfHungJobs = [System.Collections.Generic.List[object]]::new()
    }
    AfterEach {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingSlowMs = 1000; $script:VmfArmAnswerLimitMs = 100000
            $script:VmfCallTimings = $null; $script:VmfCallTimingArmDepth = 0
        }
        foreach ($j in $global:VmfHungJobs) { Remove-Job -Job $j -Force -ErrorAction SilentlyContinue }
    }

    It 'the limit is 100 seconds, well inside the five-minute limit of the service' {
        $limitMs = $script:armLimitAtLoad
        $limitMs | Should -Be 100000
        $hostJson = Get-Content (Join-Path $script:repoRoot 'src' 'facade' 'app' 'host.json') -Raw | ConvertFrom-Json
        # No functionTimeout: the Consumption default, five minutes, applies.
        $hostJson.PSObject.Properties.Name | Should -Not -Contain 'functionTimeout'
        $limitMs | Should -BeLessThan 300000
    }

    It 'a request that gets no answer ends at the limit, is a failed call with no status, and the job is stopped and removed' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { $j = New-HungJob; $global:VmfHungJobs.Add($j); $j }
        # Stop-Job is what was measured to end Az's job at once; Remove-Job
        # -Force alone would also stop a thread job, so the stop is asked for.
        Mock -ModuleName VmMigrationFactory Stop-Job { Microsoft.PowerShell.Core\Stop-Job -Job $Job }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } {
            Start-VmfCallTimings
            { Invoke-VmfArmRequest -Method GET -Path "/subscriptions/$s/resourceGroups/rg-a/providers/Microsoft.Compute/snapshots/snap-a?api-version=1" } |
                Should -Throw '*did not answer*timed out*'
            Complete-VmfCallTimings
        }
        $clock.ElapsedMilliseconds | Should -BeLessThan 10000
        Should -Invoke -ModuleName VmMigrationFactory Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $AsJob }
        Should -Invoke -ModuleName VmMigrationFactory Stop-Job -Times 1 -Exactly
        $rec = Get-HungRecord
        $rec.arm.n | Should -Be 1
        $rec.arm.fail | Should -Be 1
        $rec.arm.max | Should -BeGreaterOrEqual 300
        $slow = @($rec.slow)[0]
        $slow.k | Should -Be 'arm'
        $slow.op | Should -Be 'GET'
        $slow.target | Should -Be 'subscriptions/{}/resourceGroups/{}/providers/Microsoft.Compute/snapshots/{}'
        $slow.status | Should -Be 0
        $slow.ok | Should -BeFalse
        $global:VmfHungLines[0] | Should -Not -Match 'aaaa0a0a'
        $global:VmfHungJobs[0].State | Should -Be 'Stopped'
        @(Get-Job -Id $global:VmfHungJobs[0].Id -ErrorAction SilentlyContinue).Count | Should -Be 0 -Because 'the stopped job is removed'
    }

    It 'the error is a timeout to the retry rule, and names no subscription or resource' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { $j = New-HungJob; $global:VmfHungJobs.Add($j); $j }
        $err = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } {
            try { $null = Invoke-VmfArmRequest -Method GET -Path "/subscriptions/$s/resourceGroups/rg-a?api-version=1"; $null }
            catch { $_ }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Not -Match 'aaaa0a0a'
        $err.Exception.Message | Should -Not -Match 'rg-a'
        $verdict = InModuleScope VmMigrationFactory -Parameters @{ e = $err } { Get-VmfTransientVerdict -ErrorInfo (Resolve-VmfOperationError -ErrorRecord $e) }
        $verdict.Transient | Should -BeTrue
        $verdict.Throttle | Should -BeFalse
    }

    It 'an answer that comes in time is given back as it was, a 404 is still an answer, and the job is removed' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $j = Start-ThreadJob -ScriptBlock { [pscustomobject]@{ StatusCode = 404; Content = '{"error":{"code":"NotFound"}}' } }
            $global:VmfHungJobs.Add($j); $j
        }
        InModuleScope VmMigrationFactory {
            $script:VmfArmAnswerLimitMs = 30000
            Start-VmfCallTimings
            $r = Invoke-VmfArmRequest -Method GET -Path '/subscriptions/x/resourceGroups/y?api-version=1'
            $r.StatusCode | Should -Be 404
            $r.Content | Should -Be '{"error":{"code":"NotFound"}}'
            Complete-VmfCallTimings
        }
        $rec = Get-HungRecord
        $rec.arm.n | Should -Be 1
        $rec.arm.fail | Should -Be 0
        @($rec.slow)[0].status | Should -Be 404
        @(Get-Job -Id $global:VmfHungJobs[0].Id -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'a request that throws in the job throws the same error to the caller, and is a failed call' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod {
            $j = Start-ThreadJob -ScriptBlock { throw 'AuthorizationFailed: the client may not read this' }
            $global:VmfHungJobs.Add($j); $j
        }
        InModuleScope VmMigrationFactory {
            $script:VmfArmAnswerLimitMs = 30000
            Start-VmfCallTimings
            { Invoke-VmfArmRequest -Method GET -Path '/subscriptions/x?api-version=1' } | Should -Throw '*AuthorizationFailed*'
            Complete-VmfCallTimings
        }
        (Get-HungRecord).arm.fail | Should -Be 1
        @(Get-Job -Id $global:VmfHungJobs[0].Id -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'the preview feature read that gets no answer says it was not read, never registered or not' {
        Mock -ModuleName VmMigrationFactory Invoke-AzRestMethod { $j = New-HungJob; $global:VmfHungJobs.Add($j); $j }
        $state = InModuleScope VmMigrationFactory -Parameters @{ s = $script:sub } {
            Start-VmfCallTimings
            Get-VmfPreviewFeatureState -SubscriptionId $s
            Complete-VmfCallTimings
        }
        $state.Read | Should -BeFalse
        $state.Registered | Should -BeFalse
        (Get-HungRecord).arm.fail | Should -Be 2
    }

    It 'the facade''s own ARM request has the same limit, and the line names it' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod { $j = New-HungJob; $global:VmfHungJobs.Add($j); $j }
        Start-VmfFacadeCallTimings
        $principal = New-HungViewer
        { Get-VmfFacadeResourceGroupList -Principal $principal -SubscriptionId $script:sub } | Should -Throw '*did not answer*timed out*'
        Complete-VmfFacadeCallTimings
        Should -Invoke -ModuleName FacadeCore Invoke-AzRestMethod -Times 1 -Exactly -ParameterFilter { $AsJob }
        $rec = Get-HungRecord
        $rec.partial | Should -BeFalse
        $rec.arm.fail | Should -Be 1
        @($rec.slow)[0].target | Should -Be 'subscriptions/{}/resourcegroups'
        @($rec.slow)[0].status | Should -Be 0
        $global:VmfHungJobs[0].State | Should -Be 'Stopped'
    }

    It 'the facade''s ARM answer that comes in time is used as before' {
        Mock -ModuleName FacadeCore Invoke-AzRestMethod {
            $j = Start-ThreadJob -ScriptBlock { [pscustomobject]@{ StatusCode = 200; Content = '{"value":[{"name":"rg-a","location":"centralus"}]}' } }
            $global:VmfHungJobs.Add($j); $j
        }
        InModuleScope VmMigrationFactory { $script:VmfArmAnswerLimitMs = 30000 }
        Start-VmfFacadeCallTimings
        $groups = @(Get-VmfFacadeResourceGroupList -Principal (New-HungViewer) -SubscriptionId $script:sub)
        Complete-VmfFacadeCallTimings
        $groups.Count | Should -Be 1
        (Get-HungRecord).arm.fail | Should -Be 0
    }

    It 'a stand-in that cannot run as a job is called with no -AsJob, and what it gives back is the answer' {
        # The other test files' stand-ins take no -AsJob; each of their ARM
        # tests passes only because this is so.
        InModuleScope VmMigrationFactory {
            Test-VmfCommandCanRunAsJob -ParameterName @('Method', 'Path', 'Payload', 'Uri') | Should -BeFalse
            Test-VmfCommandCanRunAsJob -ParameterName @() | Should -BeFalse
            Test-VmfCommandCanRunAsJob -ParameterName $null | Should -BeFalse
            Test-VmfCommandCanRunAsJob -ParameterName @('Method', 'Path', 'AsJob') | Should -BeTrue
            $plain = [pscustomobject]@{ StatusCode = 200; Content = '{}' }
            (Receive-VmfArmAnswer -Answer $plain -Method GET -Target '/subscriptions/x').StatusCode | Should -Be 200
        }
    }
}

Describe 'PERF-TELEMETRY-HUNG-1: every ARM request of the service passes the limit' {
    It 'the facade calls Invoke-AzRestMethod in one place, its timed request' {
        $code = Get-VmfCodeOnly -Path (Join-Path $script:repoRoot 'src' 'facade' 'FacadeCore' 'FacadeCore.psm1')
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($code, [ref]$null, [ref]$null)
        $calls = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-AzRestMethod' }, $true))
        $calls.Count | Should -BeGreaterThan 0
        foreach ($c in $calls) {
            $fn = $c.Parent
            while ($fn -and $fn -isnot [System.Management.Automation.Language.FunctionDefinitionAst]) { $fn = $fn.Parent }
            $fn.Name | Should -Be 'Send-VmfFacadeArmRequest'
        }
    }
}

Describe 'PERF-TELEMETRY-HUNG-1: a store request that waits names itself before its next attempt' {
    BeforeEach {
        Reset-HungSink
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { $global:VmfHungLines.Add($Message) }
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'hung-token' } }
        $global:VmfHungLinesAtSend = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $global:VmfHungLinesAtSend.Add($global:VmfHungLines.Count)
            throw 'The request was canceled due to the configured HttpClient.Timeout of 100 seconds elapsing.'
        }
    }
    AfterEach {
        InModuleScope VmMigrationFactory { $script:VmfCallTimingHeldMs = 15000; $script:VmfCallTimings = $null }
    }

    It 'the wait that names a call is 15 seconds: less than a store attempt waits in the service, far more than a refused connection' {
        # STORE-REQUEST-TIMEOUT-1: a store attempt in the service ends at 20 s,
        # so a wait of 30 s would never name one.
        $script:heldMsAtLoad | Should -Be 15000
        $service = InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit -HostTimeLimited $true }
        $script:heldMsAtLoad | Should -BeLessThan $service.AttemptMs
        $script:heldMsAtLoad | Should -BeGreaterOrEqual 5000
    }

    It 'an attempt with no answer writes a part line that names the call, once, and the attempts go on as before' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingHeldMs = 0
            Start-VmfCallTimings
            { Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/runs/r1/plan.json?sv=1&sig=secret' } | Should -Throw '*Timeout*'
            Complete-VmfCallTimings
        }
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -Times 5 -Exactly
        @($global:VmfHungLinesAtSend) | Should -Be @(0, 1, 1, 1, 1) -Because 'the line is written after the first attempt, before the second, and only once'
        $recs = @(Get-HungRecord)
        $recs.Count | Should -Be 2
        $recs[0].partial | Should -BeTrue
        $recs[0].held.k | Should -Be 'store'
        $recs[0].held.op | Should -Be 'read'
        $recs[0].held.target | Should -Be 'runs/r1/plan.json'
        $recs[0].held.attempt | Should -Be 1
        $recs[0].held.ms | Should -BeGreaterOrEqual 0
        $recs[1].partial | Should -BeFalse
        $recs[1].store.fail | Should -Be 1
        $global:VmfHungLines[0] | Should -Not -Match 'secret|sig=|acct'
    }

    It 'an attempt that fails fast writes no part line' {
        InModuleScope VmMigrationFactory {
            Start-VmfCallTimings
            { Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } | Should -Throw
            Complete-VmfCallTimings
        }
        $global:VmfHungLines.Count | Should -Be 1
        (Get-HungRecord).partial | Should -BeFalse
    }

    It 'no line at all when no record was started (the engine outside a step, a script)' {
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingHeldMs = 0
            $script:VmfCallTimings = $null
            { Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } | Should -Throw
        }
        $global:VmfHungLines.Count | Should -Be 0
    }

    It 'a sink that throws does not change the store request' {
        Mock -ModuleName VmMigrationFactory Write-VmfCallTimingLine { throw 'sink down' }
        InModuleScope VmMigrationFactory {
            $script:VmfCallTimingHeldMs = 0
            Start-VmfCallTimings
            { Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } | Should -Throw '*Timeout*'
        }
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -Times 5 -Exactly
    }
}
