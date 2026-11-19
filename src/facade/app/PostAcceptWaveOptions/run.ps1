# POST /api/runs/{runId}/waves/accept-options - WAVE-2. Thin wrapper: role
# checks + logic in FacadeCore. The signed-in identity accepts; the body only
# names the wave.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    if (-not $body.wave) { throw '400: a wave name is required' }
    # ACCEPT-HASH-1: the browser must say which plan it had on screen. No hash
    # means the caller cannot tell us what it agreed to, and an acceptance that
    # is not bound to a plan version proves nothing about what was chosen.
    if (-not $body.planHash) { throw '400: the plan version being accepted is required' }
    $result = Invoke-VmfFacadeAcceptWaveOptions -Principal $principal -StorePath $store `
        -Wave ([string]$body.wave) -Note ([string]$body.note) -PlanHash ([string]$body.planHash)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 10); ContentType = 'application/json' })
}
catch {
    # ACCEPT-HASH-1: a plan that moved is a CONFLICT, not a server fault. 409 is
    # what tells the page to say "the wave changed" rather than "something went
    # wrong" - the same mapping the approve endpoint carries.
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
