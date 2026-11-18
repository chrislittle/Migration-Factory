# POST /api/runs/{runId}/approve-plan - PLANRUN-1: sign off the whole plan.
# Thin wrapper: role checks + logic in FacadeCore.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.note) { throw '400: a note explaining the action is required' }
    # APPR-2: the browser must say which plan it had on screen.
    if (-not $body.planHash) { throw '400: the plan version being signed off is required' }
    # SQL-TEMPDB-SIGNOFF-1: the machine ids of the box for SQL Server and the
    # temporary disk. Text only; the sign-off judges them against the plan.
    $checked = @(@($body.sqlTempdbChecked) | Where-Object { $_ -is [string] -and $_ })
    $result = Invoke-VmfFacadeApprovePlan -Principal $principal -StorePath $store -Note $body.note -PlanHash $body.planHash -SqlTempdbChecked $checked
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    # A plan that changed under the approver is a CONFLICT, not a server fault.
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}