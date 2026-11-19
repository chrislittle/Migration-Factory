# GET /api/runs/{runId}/summary (Vmf.Viewer). Thin wrapper: logic in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    Assert-VmfFacadeRole -Principal $principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')
    $store = Get-VmfFacadeRunStorePath -Request $Request
    # CLAIM-AT-PLAN-1: held=1 adds the machines another migration holds -
    # Choose the machines asks; the Reports page does not pay for it.
    $includeHeld = [string]$Request.Query.held -eq '1'
    $body = Get-VmfFacadeRunSummary -StorePath $store -IncludeHeld:$includeHeld | ConvertTo-Json -Depth 10
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $body; ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
