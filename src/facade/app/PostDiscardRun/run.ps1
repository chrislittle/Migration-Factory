# POST /api/runs/{runId}/discard - RUN-LIFECYCLE-1. Thin wrapper: role checks
# and the setup-stage restriction live in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    # PROJECT-1: a run inside a project is `project/run`, and a SLASH does not
    # survive this route - IIS rejects an encoded one and the caller gets a
    # bare 404. So the project travels in the body, exactly as it does for
    # approve and for the engine dispatch.
    $project = [string]$body.project
    if ($project -and $project -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') {
        throw '400: that is not a project id - lower-case letters, numbers and hyphens'
    }
    $runId = [string]$Request.Params.runId
    $store = Get-VmfFacadeRunStorePath -Request $Request
    # DISCARD-ENGINE-1: the run and the project travel on, because deleting
    # the safety copies starts the engine, which builds its own store path.
    $result = Invoke-VmfFacadeDiscardRun -Principal $principal -StorePath $store -Note ([string]$body.note) `
        -DeleteSafetyCopies:([bool]$body.deleteSafetyCopies) -RunId $runId -Project $project
    # 202 when the engine was started and the delete is still to happen.
    $status = if ($result.PSObject.Properties['queued'] -and $result.queued) { [HttpStatusCode]::Accepted } else { [HttpStatusCode]::OK }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $status; Body = ($result | ConvertTo-Json -Depth 10); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
