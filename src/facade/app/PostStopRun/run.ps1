# POST /api/runs/{runId}/stop - RUN-LIFECYCLE-1. Close out a run that cannot
# finish. Thin wrapper: the role check and the live-worker refusal are in
# FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    # POWER-ONLY-CHANGED-1: the run and the project, so the service can start
    # the return of each machine to its power state.
    $stop = @{ Principal = $principal; StorePath = $store; Note = [string]$body.note; RunId = [string]$Request.Params.runId }
    if ($body.project) { $stop.Project = [string]$body.project }
    $result = Invoke-VmfFacadeStopRun @stop
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 10); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
