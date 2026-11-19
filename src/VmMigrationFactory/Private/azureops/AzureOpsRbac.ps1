function Get-VmfEffectivePermissions {
    <#
    .SYNOPSIS
        What the CALLING identity is actually permitted to do at a scope.

        One call, and it answers the question no amount of reading role
        assignments does cleanly: assignments can be inherited from the
        management group, the subscription or the resource group, can come from
        several roles at once, and can subtract with notActions. This API returns
        the effective result for the caller at the scope it is asked about, so
        inherited grants are already folded in.

        Needs no special permission of its own - a principal can always ask what
        it may do.
    .OUTPUTS
        The permission entries, each with .actions / .notActions (and the data
        equivalents). Empty means this identity holds nothing here.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Scope)

    $path = "$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01"
    $resp = Invoke-AzRestMethod -Method GET -Path $path
    if ($resp.StatusCode -ne 200) {
        throw "Could not read effective permissions at '$Scope' (HTTP $($resp.StatusCode)): $($resp.Content)"
    }
    @(($resp.Content | ConvertFrom-Json).value)
}
