# POST /api/assessments/{runId}/machines - MACHINE-PICK-1: save the machines
# chosen for the migration, the first step of the migrate flow. Thin wrapper:
# role check and rules live in FacadeCore and the engine. The signed-in
# identity saves; the body carries the machines and the document versions the
# page read (PLANVER-2).
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.adviceVersion) { throw '400: the version of the target options the machines were chosen from is required' }
    $result = Invoke-VmfFacadeSetMachines -Principal $principal -StorePath $store -Machines @($body.machines | Where-Object { $_ }) `
        -AdviceVersion ([string]$body.adviceVersion) -ChoiceVersion ([string]$body.machinesVersion)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 6); ContentType = 'application/json' })
}
catch {
    # A version that moved is a CONFLICT, so the page can say the options or the
    # saved machines changed rather than "something went wrong".
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
