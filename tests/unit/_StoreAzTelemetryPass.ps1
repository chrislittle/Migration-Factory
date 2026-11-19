# FACADE-PASS-SHARE-1: a timer pass's store calls through the REAL Az.Accounts
# module, in a process of its own, while every request to a host outside this
# computer hangs. Run by StoreAzTelemetry.Tests.ps1 with HTTPS_PROXY and
# HTTP_PROXY set to a VmfBlackHole of the test process (_AzStandIns.ps1) and
# NO_PROXY=localhost,127.0.0.1, so nothing leaves this computer: the managed
# identity, ARM and the store are local stand-ins.
#
# Each store call asks Az.Accounts for its token (Get-AzAccessToken), as the
# service does. Writes ONE JSON line: the time of each store call in ms, the
# most thread-pool threads that ran work at once and the most threads, the
# token requests the identity stand-in had, and Azure PowerShell's
# EnableDataCollection setting at the end.
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.
param(
    [Parameter(Mandatory)][string]$ModulePath,
    [Parameter(Mandatory)][string]$AzVersion,
    [int]$Calls = 200
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_ThreadPoolStarved.ps1')
. (Join-Path $PSScriptRoot '_AzStandIns.ps1')
$sub = '00000000-0000-0000-0000-000000000000'
$tenant = '00000000-0000-0000-0000-0000000000aa'
$identity = [VmfFakeIdentity]::new($sub, $tenant)
$store = [VmfTlsServer]::new()
$failed = $false
try {
    $env:IDENTITY_ENDPOINT = "$($identity.BaseUri)msi/token"
    $env:IDENTITY_HEADER = 'stand-in'
    Import-Module Az.Accounts -RequiredVersion $AzVersion
    Disable-AzContextAutosave -Scope Process | Out-Null
    $null = Add-AzEnvironment -Name VmfStandIn -ResourceManagerEndpoint $identity.BaseUri -ActiveDirectoryEndpoint "$($identity.BaseUri)aad/" -ActiveDirectoryServiceEndpointResourceId 'https://management.core.windows.net/' -Scope Process
    $null = Connect-AzAccount -Identity -SkipContextPopulation -Environment VmfStandIn -Subscription $sub -Tenant $tenant -WarningAction SilentlyContinue
    Import-Module $ModulePath -Force
    # The certificate check is set before the client sends anything; this
    # makes the store client, as the first store call of a process does.
    & (Get-Module VmMigrationFactory) {
        (Get-VmfStorageHttpHandler).SslOptions.RemoteCertificateValidationCallback = [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], [VmfTlsAccept].GetMethod('Any'))
    } 6>$null
    $send = { param([string]$Method, [string]$name, $Body)
        $call = @{ Method = $Method; Uri = "$($store.BaseUri)cont/$name"; Headers = @{ 'x-ms-blob-type' = 'BlockBlob' } }
        if ($null -ne $Body) { $call.Body = $Body }
        & (Get-Module VmMigrationFactory) { param($a) Invoke-VmfStorageRequest @a } $call
    }
    $null = & $send GET 'warm.json'
    [VmfPoolSampler]::Start()
    $ms = foreach ($i in 1..$Calls) {
        $clock = [System.Diagnostics.Stopwatch]::StartNew()
        $r = switch ($i % 4) {
            0 { & $send HEAD "doc$i.json" }
            1 { & $send GET "cont?restype=container&comp=list&i=$i" }
            2 { & $send GET "doc$i.json" }
            3 { & $send PUT "doc$i.json" '{"a":1}' }
        }
        if ($r.StatusCode -ne 200) { throw "status $($r.StatusCode)" }
        [Math]::Round($clock.Elapsed.TotalMilliseconds, 1)
    }
    [VmfPoolSampler]::Stop()
    [pscustomobject]@{
        ms             = @($ms)
        maxBusy        = [VmfPoolSampler]::MaxBusy
        maxThreads     = [VmfPoolSampler]::MaxThreads
        tokenRequests  = $identity.TokenRequests
        dataCollection = [bool](Get-AzConfig -EnableDataCollection).Value
    } | ConvertTo-Json -Compress
}
catch {
    [Console]::Out.WriteLine('HARNESS-ERROR ' + $_.Exception.Message)
    $failed = $true
}
finally { [VmfPoolSampler]::Stop(); $store.Dispose(); $identity.Dispose() }
# A request that hangs is not waited for at exit (Azure PowerShell sends what
# it holds when the process ends), on every path.
[Console]::Out.Flush()
[System.Environment]::Exit($(if ($failed) { 1 } else { 0 }))
