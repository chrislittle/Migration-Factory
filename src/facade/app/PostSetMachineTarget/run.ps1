# POST /api/runs/{runId}/plan/target - WAVE-MIX-2: change one machine's size
# series after planning. Thin wrapper: the recompute and every refusal live in
# the engine. The body carries the machine, the series and the plan version the
# page read (PLANVER-2); `preview` returns each series without writing.
# RETRY-SERIES-1: `afterRollback` changes a rolled-back machine's target.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    # PROJECT-1: a run inside a project is `project/run`, and a slash does not
    # survive this route. The project travels in the body.
    $project = [string]$body.project
    if ($project -and $project -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') {
        throw '400: that is not a project id - lower-case letters, numbers and hyphens'
    }
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $result = Invoke-VmfFacadeSetMachineTarget -Principal $principal -StorePath $store -VmId ([string]$body.vmId) `
        -Option ([string]$body.option) -PlanVersion ([string]$body.planVersion) -Preview:([bool]$body.preview) `
        -AfterRollback:([bool]$body.afterRollback)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    # A plan that moved is a CONFLICT, so the page can say so rather than
    # "something went wrong"; a series the machine cannot take is a 400.
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
