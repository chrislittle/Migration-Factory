# WORKLOAD-1: a firewall or NVA must never be migrated in place.
#
# The doc's execution pattern for them is "deploy parallel appliance capacity,
# then shift traffic" - and their support model is the vendor's, not ours. But
# an NVA is a standalone IaaS VM: no vmssId, no platform tag, an ordinary
# resource group. To Resource Graph it looks like any other machine, so before
# this rule the product would assess a firewall Ready and plan an in-place
# conversion of it.
#
# Detection is by IMAGE, never by tag (a rule). The formal source is
# Microsoft's own built-in policy "Configure Marketplace
# Network Virtual Appliances (NVAs) to add a MANA support tag"
# (e87a87f5-e6dd-4919-be21-abb0a4ea4630), whose whole purpose is naming the
# marketplace offers affected by MANA - exactly the transition the product
# performs. data/nva-offers.json is GENERATED from the fetched definition, not
# transcribed, and records the policy version so a re-fetch can detect drift.
#
# The match is publisher AND offer together, exactly as the policy's allOf
# applies them. The offer patterns alone are meaningless - they include vm*,
# linux* and win* - and only gain their meaning behind the 44-publisher gate.

function Get-VmfNvaCatalog {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)

    if (-not $script:VmfNvaCatalog -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'nva-offers.json' }
        $script:VmfNvaCatalog = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfNvaCatalog
}

function Test-VmfNvaImage {
    <#
    .SYNOPSIS
        Is this machine a known network virtual appliance, by its Marketplace
        image or its Marketplace purchase plan? PURE.
    .OUTPUTS
        @{ IsNva = bool; Detail = string; Sign = 'image'|'plan'|$null;
           Evidence = @( @{ field; value } ... ) }
        Evidence names the Azure fields and the values that decided it.
    .NOTES
        NVA-PLAN-1: Microsoft's Compute REST API and ARM template reference
        for Microsoft.Compute/virtualMachines says of plan.product: "This is
        the same value as Offer under the imageReference element." So the
        plan goes through the same two gates as the image. A machine made from
        a gallery copy of an appliance image has no publisher or offer on
        imageReference, but Azure keeps the plan - the same read
        DETECT-PATTERNS-1 makes for a storage appliance. The image is judged
        first.

        An EMPTY pair (custom or gallery image with no plan) is not judged at
        all: there is no marketplace record to match, and inventing a verdict
        from nothing is the DRIVER-1 mistake. The custom-image flow already
        routes those to an explicit human acceptance.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Publisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Offer,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$PlanPublisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$PlanProduct
    )

    $catalog = Get-VmfNvaCatalog
    # The two gates, for one publisher and offer (or plan product).
    # Returns @{ Hit; Detail }; Hit is $null when there is nothing to judge.
    $judge = {
        param([string]$Pub, [string]$Off, [string]$OfferWord)
        if ([string]::IsNullOrWhiteSpace($Pub) -or [string]::IsNullOrWhiteSpace($Off)) { return $null }
        $Pub = $Pub.Trim(); $Off = $Off.Trim()
        # -like per entry: entries without a * are exact matches under -like, and
        # the list carries wildcarded publishers (a10networks*, zscaler*) as well.
        $pubHit = @($catalog.publishers) | Where-Object { $Pub -like $_ } | Select-Object -First 1
        if (-not $pubHit) { return @{ Hit = $false; Detail = "publisher '$Pub' is not a known appliance vendor" } }
        $offerHit = @($catalog.offerPatterns) | Where-Object { $Off -like $_ } | Select-Object -First 1
        if (-not $offerHit) {
            return @{ Hit = $false; Detail = "publisher '$Pub' is a known appliance vendor but $OfferWord '$Off' matches no appliance offer pattern" }
        }
        @{ Hit = $true; Detail = "publisher '$Pub' (matched '$pubHit'), $OfferWord '$Off' (matched '$offerHit') - per Microsoft's MANA NVA policy v$($catalog.source.version)" }
    }

    $image = & $judge $Publisher $Offer 'offer'
    if ($image -and $image.Hit) {
        return @{ IsNva = $true; Sign = 'image'
                  Detail = "marketplace appliance image: $($image.Detail)"
                  Evidence = @(@{ field = 'imageReference.publisher'; value = $Publisher },
                               @{ field = 'imageReference.offer'; value = $Offer }) }
    }
    $plan = & $judge $PlanPublisher $PlanProduct 'product'
    if ($plan -and $plan.Hit) {
        return @{ IsNva = $true; Sign = 'plan'
                  Detail = "marketplace appliance purchase plan: $($plan.Detail)"
                  Evidence = @(@{ field = 'plan.publisher'; value = $PlanPublisher },
                               @{ field = 'plan.product'; value = $PlanProduct }) }
    }

    $detail = if ($image) { $image.Detail } elseif ($plan) { $plan.Detail } else { 'no marketplace image record to judge' }
    @{ IsNva = $false; Sign = $null; Detail = $detail; Evidence = @() }
}
