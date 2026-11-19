# WAVEGEN-HOSTED-1: the size catalog a plan was built with, saved beside it.
#
# Only the engine can read Azure's size catalog: it runs with Az.Compute and an
# identity that holds Microsoft.Compute/skus/read. The service loads no Az
# module, and its identity holds no such read. So anything the service runs that
# needs target sizes - changing one machine's size series (WAVE-MIX-2) - reads THIS copy, which
# the engine saved when it built the plan.
#
# Only the sizes a target can come from are kept: D, E and F, at v5, v6 and v7.
# A region's full catalog is over a thousand sizes and the planner never picks
# the rest. WAVE-MIX-2: plus the sizes the plan's machines are ON. Whether a
# source has a temporary disk decides a v5 'd' size, and a v2 or v3 size says
# so only in the catalog - without it, a machine's target changed after
# planning could differ from the one the targets step gave it.

function Get-VmfTargetCatalogSubset {
    <#
    .SYNOPSIS
        The part of a size catalog a target can come from, as plain data.
    .PARAMETER AlsoKeep
        Size names kept whatever their series - the sources.
    .OUTPUTS
        One ordered hashtable per size: name, family, capabilities (name, value).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Skus,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$AlsoKeep = @()
    )

    foreach ($sku in @($Skus)) {
        if (-not $sku) { continue }
        $name = [string]$sku.Name
        # -cnotmatch: case matters. A plain -notmatch let Standard_DC2as_v5 through,
        # because [a-z] then matched the C of a confidential family.
        if ($name -cnotmatch '^Standard_[DEF][a-z]*\d+(?:-\d+)?[a-z]*_v[5-7]$' -and $name -notin @($AlsoKeep)) { continue }
        [ordered]@{
            name         = $name
            family       = [string]$sku.Family
            capabilities = @(@($sku.Capabilities) | Where-Object { $_ } | ForEach-Object {
                    [ordered]@{ name = [string]$_.Name; value = [string]$_.Value } })
        }
    }
}

function Save-VmfCatalogSnapshot {
    <#
    .SYNOPSIS
        Save the target part of a region's size catalog beside the plan.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Skus,
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$AlsoKeep = @()
    )

    $doc = [ordered]@{
        # v2 (WAVE-MIX-2): the source sizes too. See the schema's migration note.
        schemaVersion = 2
        location      = $Location.ToLowerInvariant()
        readUtc       = (Get-Date).ToUniversalTime().ToString('o')
        sizes         = @(Get-VmfTargetCatalogSubset -Skus $Skus -AlsoKeep $AlsoKeep)
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath "catalog/$($doc.location).json" -Document $doc -Depth 8
}

function Read-VmfCatalogSnapshot {
    <#
    .SYNOPSIS
        The saved catalog for one region, as size -> entry, or $null when the
        plan has none (it was built before WAVEGEN-HOSTED-1).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Location
    )

    $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "catalog/$($Location.ToLowerInvariant()).json" -Depth 8
    if (-not $doc) { return $null }
    $bySize = @{}
    foreach ($s in @($doc.sizes)) { if ($s -and $s.name) { $bySize[[string]$s.name] = $s } }
    $bySize
}