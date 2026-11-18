#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0' }
<#
PAGE-LOAD-FREEZE-1: every store request of the service goes over a pooled
connection, not a new TCP connection for each request.

MEASURED on the lab install (Application Insights, VMF-CALLS lines, 2026-11-06
and 2026-11-07): the schedule timer made about 700 store calls a pass, every
five minutes, and every one of them opened a new TCP connection to the same
storage address and port - Invoke-WebRequest makes a new HttpClient for each
call when no -WebSession is given (MEASURED on this computer, PowerShell
7.6.9: 20 calls, 20 connections; a shared HttpClient, 1). Store calls on one
instance then stalled for 65 s or about 110 s and ended together - during a
page load (15:17-15:19 on 2026-11-06, six reads at once) and with no page
open at all (03:34 on 2026-11-07, the schedule and cleanup timers at once).

Microsoft, "Troubleshoot intermittent outbound connection errors in Azure App
Service" (Cause): each instance is given 128 SNAT ports for one address and
port, the load balancer takes a closed connection's port back only after four
minutes, and a function that opens new connections fast is "blocked until a
new SNAT port becomes available". "Manage connections in Azure Functions":
"Don't create a new client with every function invocation."

So these tests count TCP connections at a real HTTP service on this computer
(_FakeBlobService.ps1), the way the store is reached: a mock answers without a
socket and cannot show a connection.
#>
BeforeAll {
    $script:repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..' '..'))
    $script:modulePath = Join-Path $script:repo 'src' 'VmMigrationFactory' 'VmMigrationFactory.psd1'
    Import-Module $script:modulePath -Force
    . (Join-Path $PSScriptRoot '_FakeBlobService.ps1')
    . (Join-Path $PSScriptRoot '_TempWork.ps1')
    . (Join-Path $PSScriptRoot '_AzureGuard.ps1')
    # Az is not installed in CI: a stand-in to mock, defined BEFORE the guard.
    function Global:Get-AzAccessToken { param($ResourceUrl) throw 'stub' }
    Block-VmfAzureCalls -TestFile $PSCommandPath

    $script:dir = Join-Path (New-VmfTestTemp -Prefix 'storeconn') 'c'
    New-Item -ItemType Directory -Path $script:dir | Out-Null
    foreach ($i in 1..12) { Set-Content (Join-Path $script:dir "doc$i.json") -Value "{`"n`":$i}" -NoNewline -Encoding utf8NoBOM }
    $script:svc = [VmfFakeBlobService]::new($script:dir, 0)
    $script:svc.RequireToken = 'Bearer conn-token'
    $script:Uri = { param($name) "$($script:svc.BaseUri)cont/$name" }
    # One store request, as every caller in the module sends it.
    $script:Send = { param([string]$Method, [string]$u, [hashtable]$Headers = @{}, $Body)
        $call = @{ Method = $Method; Uri = $u; Headers = $Headers }
        if ($PSBoundParameters.ContainsKey('Body')) { $call.Body = $Body }
        InModuleScope VmMigrationFactory -Parameters @{ a = $call } { Invoke-VmfStorageRequest @a }
    }
}
AfterAll {
    $script:svc.Dispose()
    Remove-VmfTestTemp
    Remove-Item 'function:\Get-AzAccessToken' -ErrorAction SilentlyContinue
}

Describe 'PAGE-LOAD-FREEZE-1: the store is reached over pooled connections' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'conn-token' } }
        $script:svc.ResetCounts()
    }

    It 'sends twelve store requests one after another over ONE connection' {
        foreach ($i in 1..12) {
            $r = & $script:Send GET (& $script:Uri "doc$i.json")
            $r.StatusCode | Should -Be 200
            ($r.Content | ConvertFrom-Json).n | Should -Be $i
        }
        $script:svc.Requests | Should -Be 12
        $script:svc.Connections.Count | Should -Be 1 -Because 'a new connection for each store request is what used up the instance''s outbound ports on the lab install'
    }

    It 'sends a read, a write, a check and a delete over the same connection' {
        $null = & $script:Send GET (& $script:Uri 'doc1.json')
        $null = & $script:Send PUT (& $script:Uri 'new.json') @{ 'x-ms-blob-type' = 'BlockBlob' } '{"a":1}'
        $null = & $script:Send HEAD (& $script:Uri 'doc2.json')
        $null = & $script:Send DELETE (& $script:Uri 'gone.json')
        $null = & $script:Send GET "$($script:svc.BaseUri)cont?restype=container&comp=list&prefix="
        $script:svc.Requests | Should -Be 5
        $script:svc.Connections.Count | Should -Be 1
    }

    It 'shares the connections of the reads sent together (Invoke-VmfStorageGetMany)' {
        InModuleScope VmMigrationFactory -Parameters @{ u = @(1..6 | ForEach-Object { & $script:Uri "doc$_.json" }) } {
            $null = Invoke-VmfStorageGetMany -Uri $u -Limit 1
        }
        foreach ($i in 7..12) { $null = & $script:Send GET (& $script:Uri "doc$i.json") }
        $script:svc.Requests | Should -Be 12
        $script:svc.Connections.Count | Should -Be 1 -Because 'the single requests and the batch reads use one connection pool'
    }

    It 'is one client for the whole process: a second runspace gets the same one' {
        $here = InModuleScope VmMigrationFactory { Get-VmfStorageHttpClient }
        $ps = [powershell]::Create()
        try {
            $null = $ps.AddScript({
                    param($modulePath)
                    Import-Module $modulePath -Force
                    & (Get-Module VmMigrationFactory) { Get-VmfStorageHttpClient }
                }).AddArgument($script:modulePath)
            $there = @($ps.Invoke())
            $ps.Streams.Error.Count | Should -Be 0 -Because "$($ps.Streams.Error | Select-Object -First 1)"
        }
        finally { $ps.Dispose() }
        $there.Count | Should -Be 1
        [object]::ReferenceEquals($here, $there[0].psobject.BaseObject) | Should -BeTrue -Because 'the Functions worker runs calls in many runspaces of one process, and each runspace imports the module again'
        $here | Should -BeOfType ([System.Net.Http.HttpClient])
    }

    It 'replaces a connection after a few minutes, so a change of the storage address is seen' {
        $handler = InModuleScope VmMigrationFactory { Get-VmfStorageHttpHandler }
        $handler | Should -BeOfType ([System.Net.Http.SocketsHttpHandler])
        $handler.PooledConnectionLifetime | Should -BeGreaterThan ([timespan]::FromMinutes(1))
        $handler.PooledConnectionLifetime | Should -BeLessOrEqual ([timespan]::FromMinutes(15))
    }
}

Describe 'PAGE-LOAD-FREEZE-1: a store request sends and gives back what it did before' {
    BeforeEach {
        Mock -ModuleName VmMigrationFactory Get-AzAccessToken { [pscustomobject]@{ Token = 'conn-token' } }
        $script:svc.ResetCounts()
        $script:last = { $all = @($script:svc.Captured.ToArray()); $all[$all.Count - 1] }
    }

    It 'sends the token, the storage version and the caller''s headers' {
        $null = & $script:Send PUT (& $script:Uri 'w.json') @{ 'x-ms-blob-type' = 'BlockBlob'; 'If-Match' = '"0x1"' } '{}'
        $req = & $script:last
        $req.Method | Should -Be 'PUT'
        $req.Headers['Authorization'] | Should -Be 'Bearer conn-token'
        $req.Headers['x-ms-version'] | Should -Be '2023-11-03'
        $req.Headers['x-ms-blob-type'] | Should -Be 'BlockBlob'
        $req.Headers['If-Match'] | Should -Be '"0x1"'
    }

    It 'asks for a compressed answer, as Invoke-WebRequest did' {
        $null = & $script:Send GET (& $script:Uri 'doc1.json')
        (& $script:last).Headers['Accept-Encoding'] | Should -Match 'gzip'
    }

    It 'sends the body as UTF-8 with no byte-order mark, and no content type' {
        $text = '{"name":"caf' + [char]0x00E9 + '"}'
        $null = & $script:Send PUT (& $script:Uri 'u.json') @{ 'x-ms-blob-type' = 'BlockBlob' } $text
        $req = & $script:last
        [System.Text.Encoding]::UTF8.GetString($req.Body) | Should -BeExactly $text
        $req.Body[0] | Should -Not -Be 0xEF
        $req.Headers['Content-Length'] | Should -Be ([string]$req.Body.Length)
        $req.Headers.ContainsKey('Content-Type') | Should -BeFalse -Because 'Invoke-WebRequest sent none, so the store keeps serving what it served'
    }

    It 'sends an empty body as length 0, and a PUT with no body as length 0 too' {
        $null = & $script:Send PUT (& $script:Uri 'a.log') @{ 'x-ms-blob-type' = 'AppendBlob'; 'If-None-Match' = '*' } ''
        (& $script:last).Headers['Content-Length'] | Should -Be '0'
        $null = & $script:Send PUT "$($script:svc.BaseUri)cont?restype=container"
        (& $script:last).Headers['Content-Length'] | Should -Be '0' -Because 'Azure Storage refuses a PUT with no length'
    }

    It 'does not carry one request''s headers into the next' {
        $null = & $script:Send PUT (& $script:Uri 'x.json') @{ 'x-ms-blob-type' = 'BlockBlob'; 'If-None-Match' = '*' } '{}'
        $null = & $script:Send GET (& $script:Uri 'doc1.json')
        $req = & $script:last
        $req.Headers.ContainsKey('If-None-Match') | Should -BeFalse -Because 'an Invoke-WebRequest session keeps every header it was given (measured), which would make the next write fail'
        $req.Headers.ContainsKey('x-ms-blob-type') | Should -BeFalse
    }

    It 'gives back the status, the text and the headers, with ETag and Content-Type found in any letter case' {
        $r = & $script:Send GET (& $script:Uri 'doc5.json')
        $r.StatusCode | Should -Be 200
        $r.Content | Should -BeOfType ([string])
        $r.Content | Should -BeExactly '{"n":5}'
        $r.Headers['etag'] | Should -Be '"0x7"'
        [string]($r.Headers['content-type'] | Select-Object -First 1) | Should -Be 'application/octet-stream'
    }

    It 'reads the ETag the way the store code reads it' {
        $r = & $script:Send GET (& $script:Uri 'doc5.json')
        InModuleScope VmMigrationFactory -Parameters @{ r = $r } {
            $etag = $null
            foreach ($k in @($r.Headers.Keys)) { if ([string]$k -ieq 'ETag') { $etag = [string](@($r.Headers[$k])[0]) } }
            $etag | Should -Be '"0x7"'
        }
    }

    It 'gives back an answer that is not success as a status, without an error' {
        $r = & $script:Send GET (& $script:Uri 'nothing.json')
        $r.StatusCode | Should -Be 404
        $r.Content | Should -Match 'BlobNotFound'
    }

    It 'tries a "try later" answer again, with the same back-off' {
        $script:svc.FailFirst['doc9.json'] = 2
        $r = & $script:Send GET (& $script:Uri 'doc9.json')
        $r.StatusCode | Should -Be 200
        $script:svc.Requests | Should -Be 3
    }

    It 'tries a request that gets no answer again, then says it did not succeed' {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = ([System.Net.IPEndPoint]$probe.LocalEndpoint).Port; $probe.Stop()
        $script:tries = 0
        Mock -ModuleName VmMigrationFactory Send-VmfStorageHttpRequest { $script:tries++; throw 'connection refused' }
        { & $script:Send GET "http://127.0.0.1:$port/cont/doc1.json" } | Should -Throw '*connection refused*'
        $script:tries | Should -Be 5
    }
}
