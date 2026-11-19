# POST /api/runs/{runId}/waves/{wave}/schedule - start a wave later, or
# cancel a scheduled start (SCHED-1). Thin wrapper: rules live below.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    $params = @{
        Principal = $principal
        StorePath = $store
        Wave      = $Request.Params.wave
        Note      = [string]$body.note
    }
    if ($body.cancel) { $params.Cancel = $true }
    if ($body.runAtUtc) { $params.RunAtUtc = [string]$body.runAtUtc }
    if ($body.windowMinutes) { $params.WindowMinutes = [int]$body.windowMinutes }
    $result = Invoke-VmfFacadeSchedule @params
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::BadRequest }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
