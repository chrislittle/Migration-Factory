# GET /api/engine/capacity?atOnce=N - will this many machines at once fit the
# engine's own environment (SCALE-2, any signed-in role). Read-only: the
# containers the number needs, their cores, and the environment's free
# Consumption cores, read live. The wave editor shows the answer beside the
# estimate; the start and the schedule refuse when it does not fit.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    Assert-VmfFacadeRole -Principal $principal -AnyOf @('Vmf.Viewer', 'Vmf.Operator', 'Vmf.Approver', 'Vmf.Admin')
    $n = 0
    if (-not [int]::TryParse([string]$Request.Query.atOnce, [ref]$n) -or $n -lt 1) { throw '400: atOnce must be a whole number of machines, at least 1' }
    $result = Get-VmfFacadeEngineCapacity -Workers $n -Job (Get-VmfFacadeEngineJob)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 4); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
