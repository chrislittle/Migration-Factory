# STORE-CALL-SLOW-1: a timer pass's store calls over TLS, in a process of its
# own, while other calls take thread-pool threads all the time. Run by
# StoreCallStarved.Tests.ps1 in a child process with DOTNET_PROCESSOR_COUNT=1
# (one processor, as a small Functions instance has), because the pool's
# minimum and the shared client's certificate check are set once a process.
# Writes ONE JSON line: the time of each store call, in ms.
#
# Not named *.Tests.ps1 on purpose: Pester discovers only test files.
param([Parameter(Mandatory)][string]$ModulePath, [int]$Calls = 40)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_ThreadPoolStarved.ps1')
# A stand-in for the token, found before any Az module (a function wins).
function Global:Get-AzAccessToken { param($ResourceUrl) [pscustomobject]@{ Token = 'tls-token' } }
Import-Module $ModulePath -Force
$server = [VmfTlsServer]::new()
try {
    # The certificate check is set before the client sends anything: after
    # that the handler refuses a change.
    & (Get-Module VmMigrationFactory) {
        (Get-VmfStorageHttpHandler).SslOptions.RemoteCertificateValidationCallback = [System.Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], [VmfTlsAccept].GetMethod('Any'))
    }
    $send = { param([string]$Method, [string]$name, $Body)
        $call = @{ Method = $Method; Uri = "$($server.BaseUri)cont/$name"; Headers = @{ 'x-ms-blob-type' = 'BlockBlob' } }
        if ($null -ne $Body) { $call.Body = $Body }
        & (Get-Module VmMigrationFactory) { param($a) Invoke-VmfStorageRequest @a } $call
    }
    $null = & $send GET 'warm.json'
    [VmfPoolStarver]::Churn(100, 1500)
    [System.Threading.Thread]::Sleep(3000)
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
    [VmfPoolStarver]::StopChurn()
    [pscustomobject]@{ ms = @($ms); connections = $server.Connections } | ConvertTo-Json -Compress
}
finally { [VmfPoolStarver]::StopChurn(); $server.Dispose() }
