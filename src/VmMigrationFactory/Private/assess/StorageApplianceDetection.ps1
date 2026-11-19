# DETECT-PATTERNS-1: a storage or backup appliance is not the product's to move.
#
# Microsoft's v6/v7 Plan page, "Storage and backup virtual appliances": treat
# machine-based storage appliances like network virtual appliances. The vendor
# certifies the sizes, so the vendor approves the move first (owner,
# 2026-10-10, for every storage and backup appliance). The product refuses
# the machine as outside the scope of this tool, the way it refuses an NVA
# (WORKLOAD-1).
#
# Microsoft has NO list of their images. data/storage-appliances.json is our
# own, read from the Azure Marketplace catalog, with its date - not a
# Microsoft list.
#
# AN APPLIANCE REACHES AZURE FOUR WAYS, and three of them are read here (the
# fourth, a managed application, is the resource group's managedBy, which the
# rules read from Get-VmfResourceGroupOwners):
#   1. a Marketplace image: imageReference publisher AND offer;
#   2. a Marketplace purchase: the machine's plan publisher AND product. Azure
#      keeps the plan on the machine when the image came from a gallery or a
#      managed application, so this catches a vendor image with no name;
#   3. a vendor gallery: the image id (WEKA deploys from its own community
#      gallery, not the Marketplace - its storage machines AND its clients).
#
# The publisher alone is never evidence: Veeam also publishes an Office 365
# backup console, which is an ordinary machine.

function Get-VmfStorageApplianceCatalog {
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)

    if (-not $script:VmfStorageApplianceCatalog -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'storage-appliances.json' }
        $script:VmfStorageApplianceCatalog = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfStorageApplianceCatalog
}

function Test-VmfStorageAppliance {
    <#
    .SYNOPSIS
        Is this machine a storage or backup appliance, by its image, its
        purchase plan or its gallery image? PURE.
    .OUTPUTS
        @{ IsAppliance = bool; Vendor = string; Sign = 'image'|'plan'|'gallery'|$null;
           Evidence = @( @{ field; value } ... ) }
        Evidence names the Azure field and the value that decided it.
    .NOTES
        Empty values judge nothing: no record is not a statement either way.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ImagePublisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ImageOffer,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$PlanPublisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$PlanProduct,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$GalleryImageId,
        # The Azure field the gallery id came from, for the evidence.
        [Parameter()][string]$GalleryField = 'imageReference.id'
    )

    $catalog = Get-VmfStorageApplianceCatalog
    $vendorOf = {
        param([string]$Publisher, [string]$Offer)
        if ([string]::IsNullOrWhiteSpace($Publisher) -or [string]::IsNullOrWhiteSpace($Offer)) { return $null }
        foreach ($v in @($catalog.vendors)) {
            # -eq and -like ignore case in PowerShell, as Azure does.
            if ($Publisher.Trim() -ne [string]$v.publisher) { continue }
            foreach ($pattern in @($v.offers)) {
                if ($Offer.Trim() -like [string]$pattern) { return $v }
            }
        }
        $null
    }

    $v = & $vendorOf $ImagePublisher $ImageOffer
    if ($v) {
        return @{ IsAppliance = $true; Vendor = [string]$v.vendor; Sign = 'image'
                  Evidence = @(@{ field = 'imageReference.publisher'; value = $ImagePublisher },
                               @{ field = 'imageReference.offer'; value = $ImageOffer }) }
    }
    $v = & $vendorOf $PlanPublisher $PlanProduct
    if ($v) {
        return @{ IsAppliance = $true; Vendor = [string]$v.vendor; Sign = 'plan'
                  Evidence = @(@{ field = 'plan.publisher'; value = $PlanPublisher },
                               @{ field = 'plan.product'; value = $PlanProduct }) }
    }
    if (-not [string]::IsNullOrWhiteSpace($GalleryImageId)) {
        foreach ($g in @($catalog.galleries)) {
            if ($GalleryImageId.Trim() -like [string]$g.imageId) {
                return @{ IsAppliance = $true; Vendor = [string]$g.vendor; Sign = 'gallery'
                          Evidence = @(@{ field = $GalleryField; value = $GalleryImageId }) }
            }
        }
    }
    @{ IsAppliance = $false; Vendor = $null; Sign = $null; Evidence = @() }
}
