#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
STORE-REQUEST-TIMEOUT-1: a run store request that gets no answer ends, with
all its attempts and their back-off, well inside the five-minute time limit of
the service (Consumption; host.json sets no functionTimeout).

Before: each attempt waited HttpClient's default, 100 s, and a request made up
to 5 attempts - about 8 minutes. On the lab install a schedule pass ended with
FunctionTimeoutException at 300 s after one store request waited about 3.5
minutes (FACADE-QUEUE-1, 2026-11-07).

The numbers, from what was measured (the item file has the sources):
  - the slowest store answer the lab install measured since every request
    shares one pooled client is 2.7 s (PAGE-LOAD-FREEZE-1, 4,889 calls), and
    a pass's slowest 1,020 ms (STORE-CALL-SLOW-1, 469 calls);
  - in the service, one attempt waits at most 20 s for the store's headers,
    and the whole request (every wait for headers and the back-off) at most
    40 s; once the headers came, the body has 100 s, as before (decided
    2026-11-09: a store that has started to answer finishes a large body);
  - the schedule and retention passes stop starting runs at 210 s, so 90 s
    are left for the last run and the pass record: two requests with no
    answer take 80 s.
  - the engine has no five-minute limit, and keeps its attempts as they were.

Tests against a real HTTP service on this computer (_FakeBlobService.ps1),
which waits LatencyMs before each answer: a mock that throws at once cannot
show a request that waits.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    . (Join-Path $PSScriptRoot '_CodeOnly.ps1')
    Import-Module (Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1') -Force
    . (Join-Path $PSScriptRoot '_FakeBlobService.ps1')
    # A body stream whose read waits until the stream is disposed, then gives
    # a clean end (0 bytes) - what a chunked answer with no Content-Length can
    # do when its limit disposes it.
    if (-not ('VmfHoldStream' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Threading;
public class VmfHoldStream : Stream
{
    readonly ManualResetEventSlim gate = new ManualResetEventSlim(false);
    public override bool CanRead { get { return true; } }
    public override bool CanSeek { get { return false; } }
    public override bool CanWrite { get { return false; } }
    public override long Length { get { throw new NotSupportedException(); } }
    public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) { gate.Wait(); return 0; }
    public override long Seek(long offset, SeekOrigin origin) { throw new NotSupportedException(); }
    public override void SetLength(long value) { throw new NotSupportedException(); }
    public override void Write(byte[] buffer, int offset, int count) { throw new NotSupportedException(); }
    protected override void Dispose(bool disposing) { gate.Set(); base.Dispose(disposing); }
}
"@
    }
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in to mock, defined BEFORE the guard.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:dir = Join-Path (New-VmfTestTemp -Prefix 'storetimeout') 'c'
    New-Item -ItemType Directory -Path $script:dir | Out-Null
    foreach ($i in 1..3) { Set-Content (Join-Path $script:dir "doc$i.json") -Value "{`"n`":$i}" -NoNewline -Encoding utf8NoBOM }
    $script:svc = [VmfFakeBlobService]::new($script:dir, 0)
    $script:svc.RequireToken = 'Bearer timeout-token'
    $script:Uri = { param($name) "$($script:svc.BaseUri)cont/$name" }
    # The values the module loads with, before any test changes them.
    $script:atLoad = InModuleScope VmMigrationFactory {
        @{
            ServiceAttemptMs = $script:VmfStoreServiceAttemptMs
            ServiceRequestMs = $script:VmfStoreServiceRequestMs
            EngineAttemptMs  = $script:VmfStoreEngineAttemptMs
            FloorMs          = $script:VmfStoreAttemptFloorMs
            BodyMs           = $script:VmfStoreBodyMs
        }
    }
    $script:envAtLoad = $env:FUNCTIONS_WORKER_RUNTIME
    function Global:Restore-StoreTimeoutLimits {
        param($Values)
        InModuleScope VmMigrationFactory -Parameters @{ v = $Values } {
            $script:VmfStoreServiceAttemptMs = $v.ServiceAttemptMs
            $script:VmfStoreServiceRequestMs = $v.ServiceRequestMs
            $script:VmfStoreEngineAttemptMs = $v.EngineAttemptMs
            $script:VmfStoreAttemptFloorMs = $v.FloorMs
            $script:VmfStoreBodyMs = $v.BodyMs
        }
    }
    # The default of a pass's budget, read from the function itself.
    function Global:Get-PassBudgetDefault {
        param([string]$Name)
        $ast = (InModuleScope VmMigrationFactory -Parameters @{ n = $Name } { Get-Command $n }).ScriptBlock.Ast
        $param = $ast.FindAll({ param($x) $x -is [System.Management.Automation.Language.ParameterAst] -and $x.Name.VariablePath.UserPath -eq 'BudgetSeconds' }, $true) | Select-Object -First 1
        [int]$param.DefaultValue.Value
    }
}
AfterAll {
    $script:svc.Dispose()
    Remove-VmfTestTemp
    $env:FUNCTIONS_WORKER_RUNTIME = $script:envAtLoad
    Remove-Item 'function:\Get-AzAccessToken', 'function:\Restore-StoreTimeoutLimits', 'function:\Get-PassBudgetDefault' -ErrorAction SilentlyContinue
}

Describe 'STORE-REQUEST-TIMEOUT-1: the limits' {
    It 'in the service, one attempt waits at most 20 seconds and the whole request at most 40 seconds' {
        $limit = InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit -HostTimeLimited $true }
        $limit.AttemptMs | Should -Be 20000
        $limit.BudgetMs | Should -Be 40000
        $limit.BodyMs | Should -Be 100000 -Because 'a store that has started to answer finishes its body under the limit the service had before'
        $script:atLoad.ServiceAttemptMs | Should -Be 20000
        $script:atLoad.ServiceRequestMs | Should -Be 40000
    }

    It 'two requests with no answer end inside the 90 seconds a pass keeps after its budget' {
        $limit = InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit -HostTimeLimited $true }
        foreach ($name in 'Test-VmfPassTimeLeft', 'Test-VmfRetentionTimeLeft') {
            $budget = Get-PassBudgetDefault -Name $name
            $budget | Should -Be 210 -Because "$name stops starting runs at 210 s"
            ($budget * 1000 + 2 * $limit.BudgetMs) | Should -BeLessThan 300000 -Because 'the last run the pass started and the pass record must both end inside the five-minute limit'
        }
    }

    It 'a request in the service gets at least two attempts, and an attempt waits far longer than the slowest answer measured' {
        $limit = InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit -HostTimeLimited $true }
        $limit.BudgetMs | Should -BeGreaterOrEqual (2 * $limit.AttemptMs)
        # 2.7 s: the slowest store answer measured on the lab install since one pooled client.
        $limit.AttemptMs | Should -BeGreaterOrEqual (5 * 2700)
    }

    It 'outside the service (the engine, a script) each attempt waits 100 seconds as before, with no limit on the whole request' {
        $limit = InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit -HostTimeLimited $false }
        $limit.AttemptMs | Should -Be 100000
        $limit.BudgetMs | Should -Be 0
        $limit.BodyMs | Should -Be 100000
    }

    It 'the service is known by the setting Azure Functions gives every function app, and the install sets it' {
        try {
            $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
            InModuleScope VmMigrationFactory { Test-VmfStoreHostTimeLimited } | Should -BeTrue
            (InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit }).BudgetMs | Should -Be 40000
            $env:FUNCTIONS_WORKER_RUNTIME = $null
            InModuleScope VmMigrationFactory { Test-VmfStoreHostTimeLimited } | Should -BeFalse
            (InModuleScope VmMigrationFactory { Get-VmfStoreRequestLimit }).BudgetMs | Should -Be 0
        }
        finally { $env:FUNCTIONS_WORKER_RUNTIME = $script:envAtLoad }
        Get-VmfCodeOnly -Path (Join-Path $script:repo 'infra' 'platform.bicep') -Language CStyle | Should -Match "FUNCTIONS_WORKER_RUNTIME:\s*'powershell'"
    }

    It 'the next attempt waits what is left of the request, and starts only with a second or more left' -ForEach @(
        @{ Elapsed = 0; Attempt = 20000; Budget = 40000; Want = 20000 }
        @{ Elapsed = 25000; Attempt = 20000; Budget = 40000; Want = 15000 }
        @{ Elapsed = 38999; Attempt = 20000; Budget = 40000; Want = 1001 }
        @{ Elapsed = 39001; Attempt = 20000; Budget = 40000; Want = 0 }
        @{ Elapsed = 45000; Attempt = 20000; Budget = 40000; Want = 0 }
        @{ Elapsed = 900000; Attempt = 100000; Budget = 0; Want = 100000 }
    ) {
        InModuleScope VmMigrationFactory -Parameters $_ {
            Get-VmfStoreAttemptTimeoutMs -ElapsedMs $Elapsed -AttemptMs $Attempt -BudgetMs $Budget | Should -Be $Want
        }
    }
}

Describe 'STORE-REQUEST-TIMEOUT-1: a request over HTTP' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'timeout-token' } }
        $script:svc.ResetCounts()
        $script:svc.LatencyMs = 0
        $script:svc.TrickleMs = 0
    }
    AfterEach {
        $env:FUNCTIONS_WORKER_RUNTIME = $script:envAtLoad
        $script:svc.LatencyMs = 0
        $script:svc.TrickleMs = 0
        Restore-StoreTimeoutLimits -Values $script:atLoad
    }

    It 'in the service, a store that never answers ends the request at its limit, after two attempts' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 600; $script:VmfStoreServiceRequestMs = 1500; $script:VmfStoreAttemptFloorMs = 200 }
        $script:svc.LatencyMs = 20000
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc1.json') } {
            try { $null = Invoke-VmfStorageRequest -Method GET -Uri $u; $null } catch { $_ }
        }
        $clock.Stop()
        $err | Should -Not -BeNullOrEmpty -Because 'a request with no answer must end with an error, not wait'
        $err.Exception.Message | Should -Match 'no answer'
        $err.Exception.Message | Should -Match '2 attempts'
        $clock.ElapsedMilliseconds | Should -BeLessThan 4000 -Because 'the whole request has a limit of 1.5 s here'
        $clock.ElapsedMilliseconds | Should -BeGreaterOrEqual 900
        $script:svc.Requests | Should -Be 2
    }

    It 'the last attempt waits only what is left of the whole request' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 3000; $script:VmfStoreAttemptFloorMs = 300 }
        $script:svc.LatencyMs = 20000
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc1.json') } {
            try { $null = Invoke-VmfStorageRequest -Method GET -Uri $u; $null } catch { $_ }
        }
        $clock.Stop()
        $err | Should -Not -BeNullOrEmpty
        $script:svc.Requests | Should -Be 2
        $clock.ElapsedMilliseconds | Should -BeLessThan 3700 -Because 'the second attempt has about 1 s left, not a whole 2 s attempt'
    }

    It 'in the service, a store that sends its headers at once finishes a slow body past the attempt and request limits' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        # STORE-TIMEOUT-TEST-MARGIN-1: the headers get 1.5 s, not 0.3 s - on a
        # busy CI runner the local server once took longer than 0.3 s to answer.
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 1500; $script:VmfStoreServiceRequestMs = 3000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 15000 }
        # Seven bytes, one each 600 ms after the first: 3.6 s of body, past both limits.
        $script:svc.TrickleMs = 600
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc2.json') } { Invoke-VmfStorageRequest -Method GET -Uri $u }
        $clock.Stop()
        $r.StatusCode | Should -Be 200
        ($r.Content | ConvertFrom-Json).n | Should -Be 2
        $script:svc.Requests | Should -Be 1 -Because 'the limit of 1.5 s covers only the wait for the headers, never the body'
        $clock.ElapsedMilliseconds | Should -BeGreaterOrEqual 3500
    }

    It 'a body that stops coming ends at the body limit, and the request is sent again as before' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 10000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 400 }
        $script:svc.TrickleMs = 300
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc3.json') } {
            try { $null = Invoke-VmfStorageRequest -Method GET -Uri $u; $null } catch { $_ }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'stopped sending'
        $clock.ElapsedMilliseconds | Should -BeLessThan 4500 -Because 'each body read ends at its 0.4 s limit, not after the handler drains the rest for 2 s'
        $script:svc.Requests | Should -Be 5 -Because 'the time a body takes is not counted against the limit on the whole request: the five attempts are as before'
    }

    It 'the time bodies take is not counted against the limit on the whole request' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 5000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 1500 }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        # Each body takes its whole 1.5 s limit: five attempts would count 7.5 s.
        $script:svc.TrickleMs = 400
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc3.json') } {
            try { $null = Invoke-VmfStorageRequest -Method GET -Uri $u; $null } catch { $_ }
        }
        $err.Exception.Message | Should -Match 'stopped sending'
        $script:svc.Requests | Should -Be 5 -Because 'only the waits for headers (none here) and the back-off count against the 5 s'
    }
    It 'reads sent together finish a slow body past the attempt limit' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 1500; $script:VmfStoreServiceRequestMs = 3000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 15000 }
        $script:svc.TrickleMs = 600
        $out = InModuleScope VmMigrationFactory -Parameters @{ u = @(1..3 | ForEach-Object { & $script:Uri "doc$_.json" }) } { Invoke-VmfStorageGetMany -Uri $u }
        @($out | ForEach-Object { ($_.Content | ConvertFrom-Json).n }) | Should -Be @(1, 2, 3)
        $script:svc.Requests | Should -Be 3
    }

    It 'a read sent together whose body stops coming is sent again, and the time of its body is not counted' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 10000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 400 }
        $script:svc.TrickleMs = 300
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = @(& $script:Uri 'doc1.json') } {
            try { $null = Invoke-VmfStorageGetMany -Uri $u; $null } catch { $_ }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'stopped sending'
        # One read together, then the request sent again with its five attempts, as before.
        $script:svc.Requests | Should -Be 6
        $clock.ElapsedMilliseconds | Should -BeLessThan 3300 -Because 'the read together ends at its 0.4 s body limit too, not when the 1.8 s body is all there'
    }

    It 'a read sent together whose body its limit ends with a clean end is not taken as the document' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 10000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 300 }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        Mock -ModuleName VmMigrationFactory Get-VmfStorageBodyStream { [VmfHoldStream]::new() }
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = @(& $script:Uri 'doc1.json') } {
            try { $o = Invoke-VmfStorageGetMany -Uri $u; "returned: $($o[0].Content)" } catch { $_ }
        }
        $err | Should -Not -BeOfType ([string]) -Because "a cut body must never come back as the document ($err)"
        $err.Exception.Message | Should -Match 'stopped sending'
    }
    It 'a read sent together carries only its wait for headers, not its body, to the request sent again' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 5000; $script:VmfStoreAttemptFloorMs = 100; $script:VmfStoreBodyMs = 1500 }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        $script:svc.TrickleMs = 400
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = @(& $script:Uri 'doc1.json') } {
            try { $null = Invoke-VmfStorageGetMany -Uri $u; $null } catch { $_ }
        }
        $err.Exception.Message | Should -Match 'stopped sending'
        $script:svc.Requests | Should -Be 6 -Because 'the 1.5 s body of the read together is not spent time: the request sent again still has its five attempts'
    }
    It 'a slow answer that comes inside the attempt limit is given back as it was' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 3000; $script:VmfStoreServiceRequestMs = 6000 }
        $script:svc.LatencyMs = 400
        $r = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc2.json') } { Invoke-VmfStorageRequest -Method GET -Uri $u }
        $r.StatusCode | Should -Be 200
        ($r.Content | ConvertFrom-Json).n | Should -Be 2
        $script:svc.Requests | Should -Be 1
    }

    It 'outside the service, a store that never answers gets the five attempts, each ended at the attempt limit' {
        $env:FUNCTIONS_WORKER_RUNTIME = $null
        InModuleScope VmMigrationFactory { $script:VmfStoreEngineAttemptMs = 250 }
        $script:svc.LatencyMs = 20000
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = (& $script:Uri 'doc1.json') } {
            try { $null = Invoke-VmfStorageRequest -Method GET -Uri $u; $null } catch { $_ }
        }
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'no answer'
        $script:svc.Requests | Should -Be 5
    }

    It 'reads sent together end at the attempt limit, and a read sent again keeps what the batch already spent' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 1000; $script:VmfStoreServiceRequestMs = 2500; $script:VmfStoreAttemptFloorMs = 700 }
        $script:svc.LatencyMs = 20000
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $err = InModuleScope VmMigrationFactory -Parameters @{ u = @(1..3 | ForEach-Object { & $script:Uri "doc$_.json" }) } {
            try { $null = Invoke-VmfStorageGetMany -Uri $u; $null } catch { $_ }
        }
        $clock.Stop()
        $err | Should -Not -BeNullOrEmpty
        $err.Exception.Message | Should -Match 'no answer'
        $clock.ElapsedMilliseconds | Should -BeLessThan 5000
        # 3 reads together (1 s each, at once), then the first read sent again
        # with about 1.5 s left: one attempt. The error ends the batch there.
        $script:svc.Requests | Should -Be 4 -Because 'a read sent again starts with the time its first attempt took'
    }

    It 'reads sent together that are answered in time are given back as before' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 3000; $script:VmfStoreServiceRequestMs = 6000 }
        $script:svc.LatencyMs = 300
        $out = InModuleScope VmMigrationFactory -Parameters @{ u = @(1..3 | ForEach-Object { & $script:Uri "doc$_.json" }) } { Invoke-VmfStorageGetMany -Uri $u }
        @($out | ForEach-Object { ($_.Content | ConvertFrom-Json).n }) | Should -Be @(1, 2, 3)
        $script:svc.Requests | Should -Be 3
    }
}

Describe 'STORE-REQUEST-TIMEOUT-1: a body that is not whole' {
    It 'a body shorter than the length the store gave is named; a whole body and a HEAD answer are not' {
        InModuleScope VmMigrationFactory {
            $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
            $resp.RequestMessage = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'http://localhost/c/x.json')
            $resp.Content = [System.Net.Http.ByteArrayContent]::new([byte[]]::new(10))
            Get-VmfStorageBodyShortText -Response $resp -Length 10 | Should -BeNullOrEmpty
            Get-VmfStorageBodyShortText -Response $resp -Length 5 | Should -Be 'The run store answer ended after 5 of 10 bytes.'
            $resp.RequestMessage = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Head, 'http://localhost/c/x.json')
            Get-VmfStorageBodyShortText -Response $resp -Length 0 | Should -BeNullOrEmpty
            $resp.Dispose()
        }
    }

    It 'a body read shorter than its length is an error, not the document' {
        InModuleScope VmMigrationFactory {
            $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
            $resp.RequestMessage = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'http://localhost/c/x.json')
            $resp.Content = [System.Net.Http.ByteArrayContent]::new([byte[]]::new(5))
            $resp.Content.Headers.ContentLength = 10
            { Read-VmfStorageHttpBytes -Response $resp -TimeoutMs 5000 } | Should -Throw '*ended after 5 of 10 bytes*'
            $resp.Dispose()
        }
    }
    It 'a body read that its limit ends with a clean end is the body limit error, not a short body' {
        InModuleScope VmMigrationFactory {
            Mock Get-VmfStorageBodyStream { [VmfHoldStream]::new() }
            $resp = [System.Net.Http.HttpResponseMessage]::new([System.Net.HttpStatusCode]::OK)
            $resp.RequestMessage = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, 'http://localhost/c/x.json')
            $resp.Content = [System.Net.Http.StreamContent]::new([VmfHoldStream]::new())
            $resp.Content.Headers.ContentLength | Should -BeNullOrEmpty -Because 'no length, as a chunked answer has none'
            { Read-VmfStorageHttpBytes -Response $resp -TimeoutMs 300 } | Should -Throw '*stopped sending*'
            $resp.Dispose()
        }
    }
    It 'the store client drains nothing, so a body read ends at its limit' {
        $handler = InModuleScope VmMigrationFactory { Get-VmfStorageHttpHandler }
        $handler.MaxResponseDrainSize | Should -Be 0
        $handler.ResponseDrainTimeout | Should -Be ([timespan]::Zero)
    }
}

Describe 'STORE-REQUEST-TIMEOUT-1: the wait between attempts' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'timeout-token' } }
        Mock -ModuleName VmMigrationFactory Start-Sleep { }
        # An attempt that waits its whole limit and gets no answer.
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            [System.Threading.Thread]::Sleep($TimeoutMs)
            throw [System.TimeoutException]::new('No answer from the run store in 0.5 seconds: the request timed out.')
        }
    }
    AfterEach {
        $env:FUNCTIONS_WORKER_RUNTIME = $script:envAtLoad
        Restore-StoreTimeoutLimits -Values $script:atLoad
    }

    It 'no wait and no attempt when the limit on the whole request leaves no time for another attempt' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 500; $script:VmfStoreServiceRequestMs = 1100; $script:VmfStoreAttemptFloorMs = 400 }
        { InModuleScope VmMigrationFactory { $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } } |
            Should -Throw '*no answer in 1.1 seconds, after 1 attempt.*'
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -Times 1 -Exactly
        Should -Invoke -ModuleName VmMigrationFactory Start-Sleep -Times 0 -Exactly -Because 'the wait (250 to 500 ms) would leave less than the 400 ms an attempt needs'
    }

    It 'a request whose earlier attempt spent the whole limit sends nothing and says it got no answer' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 500; $script:VmfStoreServiceRequestMs = 1000; $script:VmfStoreAttemptFloorMs = 200 }
        { InModuleScope VmMigrationFactory { $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' -SpentMs 950 } } |
            Should -Throw '*no answer in 1 seconds, after 0 attempts*'
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -Times 0 -Exactly -Scope It
    }

    It 'the first attempt of a request sent again waits only what its earlier attempt left' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 2000; $script:VmfStoreServiceRequestMs = 3000; $script:VmfStoreAttemptFloorMs = 200 }
        { InModuleScope VmMigrationFactory { $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' -SpentMs 2600 } } | Should -Throw '*no answer*'
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -Times 1 -Exactly -Scope It
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -ParameterFilter { $TimeoutMs -le 400 } -Times 1 -Exactly -Scope It
    }

    It 'the waits between attempts count against the limit on the whole request' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 300; $script:VmfStoreServiceRequestMs = 1500; $script:VmfStoreAttemptFloorMs = 100 }
        Mock -ModuleName VmMigrationFactory Get-Random { 0 }
        $global:SrtTimeouts = [System.Collections.Generic.List[int]]::new()
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $global:SrtTimeouts.Add($TimeoutMs)
            [System.Threading.Thread]::Sleep($TimeoutMs)
            throw [System.TimeoutException]::new('No answer from the run store: the request timed out.')
        }
        try {
            { InModuleScope VmMigrationFactory { $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } } | Should -Throw '*no answer*'
            # 0.3 s, 0.25 s wait, 0.3 s, 0.5 s wait: about 0.15 s is left for the third.
            $global:SrtTimeouts.Count | Should -Be 3
            $global:SrtTimeouts[2] | Should -BeLessThan 250 -Because 'the waits of 0.25 s and 0.5 s are part of the 1.5 s'
        }
        finally { Remove-Variable -Name SrtTimeouts -Scope Global -ErrorAction SilentlyContinue }
    }
    It 'each attempt is sent with the time it may wait' {
        $env:FUNCTIONS_WORKER_RUNTIME = 'powershell'
        InModuleScope VmMigrationFactory { $script:VmfStoreServiceAttemptMs = 300; $script:VmfStoreServiceRequestMs = 900; $script:VmfStoreAttemptFloorMs = 100 }
        { InModuleScope VmMigrationFactory { $null = Invoke-VmfStorageRequest -Method GET -Uri 'https://acct.blob.core.windows.net/c/x.json' } } | Should -Throw '*no answer*'
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -ParameterFilter { $TimeoutMs -eq 300 } -Times 1 -Scope It
        Should -Invoke -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest -ParameterFilter { $TimeoutMs -le 0 -or $TimeoutMs -gt 300 } -Times 0 -Exactly -Scope It
    }
}

Describe 'STORE-REQUEST-TIMEOUT-1: a write whose answer was lost' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'timeout-token' } }
        $global:LostStored = '{"a":1}'
        $global:LostTag = '"0x1"'
        $global:LostPuts = 0
        # The store as Azure keeps it: the first PUT is written, and its answer
        # never reaches the service (a timeout on the client).
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            $h = @{}; foreach ($k in $Headers.Keys) { $h[$k] = $Headers[$k] }
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = [System.Text.Encoding]::UTF8.GetBytes($global:LostStored); Headers = @{ ETag = @($global:LostTag) } }
            }
            $global:LostPuts++
            if ($h['If-Match'] -and $h['If-Match'] -ne $global:LostTag) { return [pscustomobject]@{ StatusCode = 412; Content = [byte[]]@(); Headers = @{} } }
            $global:LostStored = [System.Text.Encoding]::UTF8.GetString($Body)
            $global:LostTag = '"0x2"'
            if ($global:LostPuts -eq 1) { throw [System.TimeoutException]::new('No answer from the run store in 20 seconds: the request timed out.') }
            [pscustomobject]@{ StatusCode = 201; Content = [byte[]]@(); Headers = @{} }
        }
    }
    AfterEach { Remove-Variable -Name LostStored, LostTag, LostPuts -Scope Global -ErrorAction SilentlyContinue }

    It 'a version-checked write that landed, sent again after its timeout, is a success - not somebody else''s change' {
        $v1 = InModuleScope VmMigrationFactory { Get-VmfDocumentVersion -Text '{"a":1}' }
        { InModuleScope VmMigrationFactory -Parameters @{ v = $v1 } {
                Write-VmfTextDocumentIfVersion -Path 'azblob://acct/cont/run-1/plan.json' -Content '{"a":2}' -ExpectedVersion $v
            } } | Should -Not -Throw
        $global:LostPuts | Should -Be 2 -Because 'the first PUT timed out on the client and was sent again, and the store answered 412'
        $global:LostStored | Should -Be '{"a":2}'
    }

    It 'a version-checked write that meets another text after its timeout is still a 409' {
        $v1 = InModuleScope VmMigrationFactory { Get-VmfDocumentVersion -Text '{"a":1}' }
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest {
            if ($Method -eq 'GET') {
                return [pscustomobject]@{ StatusCode = 200; Content = [System.Text.Encoding]::UTF8.GetBytes($global:LostStored); Headers = @{ ETag = @($global:LostTag) } }
            }
            $global:LostPuts++
            if ($global:LostPuts -eq 1) {
                # Somebody else wrote while this PUT waited, and this PUT was refused.
                $global:LostStored = '{"a":9}'; $global:LostTag = '"0x9"'
                throw [System.TimeoutException]::new('No answer from the run store in 20 seconds: the request timed out.')
            }
            [pscustomobject]@{ StatusCode = 412; Content = [byte[]]@(); Headers = @{} }
        }
        { InModuleScope VmMigrationFactory -Parameters @{ v = $v1 } {
                Write-VmfTextDocumentIfVersion -Path 'azblob://acct/cont/run-1/plan.json' -Content '{"a":2}' -ExpectedVersion $v
            } } | Should -Throw '409: Somebody changed the plan*'
        $global:LostStored | Should -Be '{"a":9}'
    }
}
