# POST /api/runs/{runId}/vms/resolve - thin wrapper: role checks + logic in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.note) { throw '400: a note explaining the action is required' }
    $resolveArgs = @{
        Principal = $principal; StorePath = $store; VmId = $body.vmId; Note = $body.note
        PolicyOverride = (ConvertTo-VmfHashtable $body.policyOverride)
    }
    # RETRY-1: absent means "engine decides". Only forward a caller's choice.
    if ($body.returnTo) { $resolveArgs.ReturnTo = [string]$body.returnTo }
    $result = Invoke-VmfFacadeResolve @resolveArgs
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
