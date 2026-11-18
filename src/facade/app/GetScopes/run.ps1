# GET /api/scopes - the places the service can scan (subscriptions +
# management groups), and with ?subscriptionId= the resource groups in one
# subscription. Feeds the scan dialog's pickers (SCOPE-1). Thin wrapper.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    $subId = $Request.Query.subscriptionId
    $result = if ($subId) {
        [pscustomobject]@{ resourceGroups = @(Get-VmfFacadeResourceGroupList -Principal $principal -SubscriptionId $subId) }
    }
    else { Get-VmfFacadeScopeList -Principal $principal }
    $body = $result | ConvertTo-Json -Depth 5
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $body; ContentType = 'application/json' })
}
catch {
    $code = if ($_ -match '^401') { [HttpStatusCode]::Unauthorized } elseif ($_ -match '^403') { [HttpStatusCode]::Forbidden } elseif ($_ -match '^400') { [HttpStatusCode]::BadRequest } else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
