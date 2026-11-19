# GET /api/store/docs?depth=&read=&prefix=&after= - the store listed once, with
# the documents a page draws, in ONE call (Vmf.Viewer).
#
# PAGE-LOAD-1. MEASURED on the lab install, 2026-11-06: one load of the
# Overview or the Assessments page sent about 200 calls to the service, one for
# each store document, and the page waited for all of them. A page now asks
# here once for what it draws (Get-VmfFacadeStoreDocs says what comes back),
# and reads through store/blob only what this did not give it.
#
# The same roles as store/blob and store/list, checked by
# Get-VmfFacadeStoreDocs: nothing comes back that those could not read.
# No document version: a page that saves a document reads it through
# store/blob, which issues the version (PLANVER-2).
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']

    $depthText = [string]$Request.Query.depth
    $depth = 3
    if ($depthText -and -not [int]::TryParse($depthText, [ref]$depth)) { throw '400 the depth is a number' }
    $read = @(([string]$Request.Query.read) -split ',' | Where-Object { $_ -ne '' })

    $answer = Get-VmfFacadeStoreDocs -Principal $principal -Prefix ([string]$Request.Query.prefix) -Depth $depth `
        -Read $read -After ([string]$Request.Query.after)
    $body = $answer | ConvertTo-Json -Depth 6 -Compress
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::OK; Body = $body; ContentType = 'application/json' })
}
catch {
    $code = if ("$_" -match '^400') { [HttpStatusCode]::BadRequest }
            elseif ("$_" -match '^401') { [HttpStatusCode]::Unauthorized }
            elseif ("$_" -match '^403') { [HttpStatusCode]::Forbidden }
            else { [HttpStatusCode]::InternalServerError }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = $code; Body = (@{ error = "$_" } | ConvertTo-Json); ContentType = 'application/json' })
}
finally {
    Complete-VmfFacadeCallTimings
}
