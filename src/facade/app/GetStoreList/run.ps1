# GET /api/store/list?prefix=&delimiter= - list the run store (Vmf.Viewer).
#
# STORE-READ-1. The dashboard used to call blob storage DIRECTLY with the
# signed-in person's own token. A browser cannot be admitted by a network
# security perimeter - it is not in a subscription, so no subscription rule can
# ever name it - and a locked-down store admits nothing else. The read moves
# here, where the facade's own identity does it from inside Azure.
#
# The response shape is the one the browser's own helper produced, so the pages
# above it did not change: names, prefixes with the trailing slash removed.
using namespace System.Net
param($Request, $TriggerMetadata)
# PERF-TELEMETRY-1: one trace line with this call's store and ARM times.
Start-VmfFacadeCallTimings
try {
    $principal = ConvertFrom-VmfClientPrincipal -Header $Request.Headers['x-ms-client-principal']
    Assert-VmfFacadeRole -Principal $principal -AnyOf @('Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator', 'Vmf.Admin')

    # The caller chooses the prefix, so it is checked before it is used. An
    # EMPTY prefix lists the top of the container, which is a real request.
    $prefix = Resolve-VmfFacadeStoreKey -Path ([string]$Request.Query.prefix) -AllowEmpty
    # RECORDS-VIEWER-READ-1: the folders the product keeps beside the runs
    # (the kept migration records, the machine claims) are the Admin's.
    Assert-VmfFacadeStoreKeyReadable -Principal $principal -Path $prefix
    $delimiter = [string]$Request.Query.delimiter
    if ($delimiter -and $delimiter -ne '/') { throw '400 the only delimiter is /' }

    # PAGE-LOAD-1: the listing is Get-VmfFacadeStoreListing, which store/docs
    # lists through too, so the two cannot list two ways. It follows the
    # pages of a listing and says when even that ran out (truncated).
    $listing = Get-VmfFacadeStoreListing -Prefix $prefix -Delimiter $delimiter
    # And nobody else is given a name or a folder under them: the top of the
    # store, and a prefix that is part of a name, list them too.
    $names = @(Select-VmfFacadeReadableStoreKeys -Principal $principal -Key @($listing.names))
    $prefixes = @(Select-VmfFacadeReadableStoreKeys -Principal $principal -Key @($listing.prefixes))
    $body = [pscustomobject]@{ names = $names; prefixes = $prefixes; truncated = [bool]$listing.truncated } | ConvertTo-Json -Depth 4
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
