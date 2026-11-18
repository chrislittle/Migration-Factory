# POST /api/runs/{runId}/vms/skip - SKIP-ONE-1. Thin wrapper: the role check
# and every refusal live in FacadeCore and the engine.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.note) { throw '400: a note explaining the action is required' }
    if (-not $body.vmId) { throw '400: the machine to leave out is required' }
    # POWER-ONLY-CHANGED-1: the run and the project, so the service can start
    # the return of the machine to its power state.
    $skip = @{ Principal = $principal; StorePath = $store; VmId = [string]$body.vmId; Note = [string]$body.note; RunId = [string]$Request.Params.runId }
    if ($body.project) { $skip.Project = [string]$body.project }
    $result = Invoke-VmfFacadeSkipVm @skip
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
