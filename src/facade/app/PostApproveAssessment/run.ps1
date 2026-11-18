# POST /api/assessments/{runId}/approve - record that an assessment has been
# reviewed, so a migration may be planned from it (ASSESS-PAGE-1, Vmf.Approver).
# Thin wrapper: logic in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    # PROJECT-1: an assessment inside a project needs project/run, and a SLASH
    # does not survive this route - IIS rejects an encoded one and the caller
    # gets a bare 404. So the project travels in the body, exactly as it does
    # for the engine dispatch. Measured against the live facade.
    $project = [string]$body.project
    if ($project -and $project -cnotmatch '^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$') {
        throw '400: that is not a project id - lower-case letters, numbers and hyphens'
    }
    $runId = [string]$Request.Params.runId
    $store = Get-VmfFacadeRunStorePath -Request $Request
    # ADVISOR-1: with the run id and project, the target options start as soon
    # as the review is recorded.
    $approveParams = @{ Principal = $principal; StorePath = $store; Note = ([string]$body.note); RunId = $runId }
    if ($project) { $approveParams.Project = $project }
    $result = Invoke-VmfFacadeApproveAssessment @approveParams
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 6); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
