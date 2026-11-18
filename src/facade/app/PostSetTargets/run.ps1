# POST /api/assessments/{runId}/targets - ADVISOR-1: save the target chosen for
# each machine. Thin wrapper: role check and rules live in FacadeCore and the
# engine. The signed-in identity saves; the body carries the choices and the
# document versions the page read (PLANVER-2).
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.adviceVersion) { throw '400: the version of the target options being chosen from is required' }
    if ([string]$body.default -notin @('current', 'extended')) { throw '400: the default must be current or extended' }
    $result = Invoke-VmfFacadeSetTargets -Principal $principal -StorePath $store -Default ([string]$body.default) `
        -Choices @($body.choices) -AdviceVersion ([string]$body.adviceVersion) -ChoicesVersion ([string]$body.choicesVersion) `
        -MachinesVersion ([string]$body.machinesVersion) -KernelDefault ([string]$body.kernelDefault)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 6); ContentType = 'application/json' })
}
catch {
    # A version that moved is a CONFLICT, so the page can say the options or the
    # saved targets changed rather than "something went wrong".
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
