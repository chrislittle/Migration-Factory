# GET /api/preview-feature?subscriptionId= - whether the preview feature
# VMTempDiskResizePreview is registered on one subscription (TEMP-DISK-PREVIEW-1,
# any role). Read-only: the service never registers it. Feeds the targets
# step's Preview option and its Check again button. Thin wrapper.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $result = Get-VmfFacadePreviewFeature -Principal $principal -SubscriptionId ([string]$Request.Query.subscriptionId)
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = ($result | ConvertTo-Json -Depth 4); ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}