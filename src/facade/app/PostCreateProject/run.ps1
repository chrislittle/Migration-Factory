# POST /api/projects - PROJECT-1. Create a project.
#
# Hard rule 10: naming a piece of work is the FIRST thing an operator does, so
# sending them to PowerShell for it would be the worst possible place to break
# the rule that every operator action is reachable from the app.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    # Null-safe, like PostApproveAssessment: a request with no body at all
    # should reach the validation below and be told what is missing, not
    # fail on a property of $null.
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    $result = Invoke-VmfFacadeCreateProject -Principal $principal `
        -ProjectId ([string]$body.projectId) -Name ([string]$body.name) -Scope $body.scope -Note ([string]$body.note)
    $json = $result | ConvertTo-Json -Depth 6
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $json; ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
