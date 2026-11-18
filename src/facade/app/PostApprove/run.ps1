# POST /api/runs/{runId}/waves/{wave}/approve - thin wrapper: role checks + logic in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.note) { throw '400: a note explaining the action is required' }
    # APPR-2: the browser must say which plan it had on screen. No hash means
    # the caller cannot tell us what it signed, and an approval that is not
    # bound to a plan version is the defect this gate exists to close.
    if (-not $body.planHash) { throw '400: the plan version being approved is required' }
    $result = Invoke-VmfFacadeApprove -Principal $principal -StorePath $store -Wave $Request.Params.wave `
        -Note $body.note -PlanHash $body.planHash
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    # APPR-2: a stale plan is a CONFLICT, not a server fault. 409 is what tells
    # the page to say "the plan changed" rather than "something went wrong".
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
