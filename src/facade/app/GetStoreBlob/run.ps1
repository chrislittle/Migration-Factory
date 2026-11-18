# GET /api/store/blob?path= - one document from the run store (Vmf.Viewer).
#
# STORE-READ-1, the pair of GetStoreList. See that file for why the browser
# stopped reading blob storage for itself.
#
# A MISSING blob is 404 and not an error: the dashboard asks for documents that
# may not exist yet - an approval before anyone approved, a plan before anyone
# planned - and its helper has always read "not there" as null.
# PLANVER-2: THE SERVICE ISSUES THE DOCUMENT'S VERSION, in the same response as
# the document.
#
# A caller that needs to name the version of a plan it is agreeing to used to
# compute it from the text it received here. That requires the document to
# travel BYTE FOR BYTE through a JSON service - a requirement nobody wrote down,
# and one the platform does not honour. MEASURED 2026-09-17 against a real
# install: the same blob, at the same path, hashed to one value in the service
# and another in the caller, and no candidate reading - a byte-order mark, a
# trailing newline - closed the gap.
#
# So the version is computed HERE, over the bytes read from the store, and
# returned in a header. A caller quotes it back. Nothing downstream recomputes
# anything, so how the body travels stops mattering.
#
# IT IS ISSUED WITH THE CONTENT, NOT BY A SECOND CALL. The gate this feeds
# exists so an acceptance names the plan the person was SHOWN; a version fetched
# separately could describe a different revision than the one on screen.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    Assert-VmfFacadeRole -Principal $principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')

    # The caller names the document, so it is checked before it is used.
    $path = Resolve-VmfFacadeStoreKey -Path ([string]$Request.Query.path)

    if ($env:VMF_STORE_PATH) {
        $file = Join-Path $env:VMF_STORE_PATH ($path -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::NotFound; Body = (@{ error = 'not found' } | ConvertTo-Json); ContentType = 'application/json' })
            return
        }
        $content = Get-Content -LiteralPath $file -Raw
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::OK; Body = $content; ContentType = 'application/json'
                Headers = (Get-VmfDocumentVersionHeaders -Text $content)
            })
        return
    }

    $account = $env:VMF_STORE_ACCOUNT
    $container = $env:VMF_STORE_CONTAINER
    if (-not $account -or -not $container) { throw 'Facade misconfigured: set VMF_STORE_ACCOUNT + VMF_STORE_CONTAINER.' }
    # Each SEGMENT is escaped, never the whole key - escaping the slashes would
    # turn one document three folders down into a single oddly named blob.
    $encoded = (($path -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $response = & (Get-Module VmMigrationFactory) { param($u) Invoke-VmfStorageRequest -Method GET -Uri $u } `
        "https://$account.blob.core.windows.net/$container/$encoded"

    if ([int]$response.StatusCode -eq 404) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{ StatusCode = [HttpStatusCode]::NotFound; Body = (@{ error = 'not found' } | ConvertTo-Json); ContentType = 'application/json' })
        return
    }
    if ([int]$response.StatusCode -ge 400) { throw "the run store refused the read: HTTP $($response.StatusCode)" }

    $type = 'application/json'
    if ($response.Headers -and $response.Headers['Content-Type']) { $type = [string]($response.Headers['Content-Type'] | Select-Object -First 1) }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK; Body = $response.Content; ContentType = $type
            Headers = (Get-VmfDocumentVersionHeaders -Text ([string]$response.Content))
        })
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
