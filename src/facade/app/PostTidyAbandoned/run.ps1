# POST /api/maintenance/abandoned - REAPER-1. Thin wrapper: which runs qualify
# is the engine's decision, and it is not restated here.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $body = if ($Request.Body) { $Request.Body } else { @{} }
    # The store ROOT: this looks across every project, not inside one run.
    $store = Get-VmfFacadeStorePath
    $days = if ($body.olderThanDays) { [int]$body.olderThanDays } else { 30 }
    $result = Invoke-VmfFacadeTidyAbandonedRuns -Principal $principal -StorePath $store `
        -OlderThanDays $days -Apply:([bool]$body.apply)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 8); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
