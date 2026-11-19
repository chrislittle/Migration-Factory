# POST /api/runs/{runId}/record - ATTEST-1: build the migration's full record,
# keep it for another 90 days, and return it (Vmf.Admin). Thin wrapper.
# RECORD-DELETE-1: a download refused during a delete is a 409, a conflict.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $store = Get-VmfFacadeRunStorePath -Request $Request
    $body = Invoke-VmfFacadeExportMigrationRecord -Principal $principal -StorePath $store | ConvertTo-Json -Depth 24
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $body; ContentType = 'application/json' })
}catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^404') { [HttpStatusCode]::NotFound } elseif ($_ -match '^409') { [HttpStatusCode]::Conflict } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}