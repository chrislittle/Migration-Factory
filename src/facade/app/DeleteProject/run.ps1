# POST /api/projects/{projectId}/delete - PROJ-DEL-1. Thin wrapper: the role
# check and the "must be empty" refusal live in FacadeCore and the engine.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    $projectId = [string]$Request.Params.projectId
    if ($projectId -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') {
        throw '400: that is not a project id - lower-case letters, numbers and hyphens'
    }
    # The store ROOT, not a run inside it: a project is a prefix beneath it.
    $store = Get-VmfFacadeStorePath
    $result = Invoke-VmfFacadeDeleteProject -Principal $principal -StorePath $store -ProjectId $projectId -Note ([string]$body.note)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 6); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
