# SAP-1, 2026-09-19. The two SAP signals that need no Azure call, read from
# the inventory row the scan already has.
#
# The other two - Azure's SAP provider naming the machine, and the Azure VM
# extension for SAP solutions - are lookups and live in
# Private/azureops/AzureOpsSap.ps1. All four say the same kind of thing: SAP is
# here. None of them is a statement about an operating system.
#
# WHY THE PRODUCT BLOCKS. Microsoft's migration guide, rewritten 24 July 2026,
# puts a gate above the readiness checklist: "Only sizes on the SAP-certified
# list are supported, regardless of platform readiness. Treat certification as
# a gate that comes before all other planning, not as a validation item."
# That list is SAP Note 1928533, behind an SAP Service Marketplace login. This
# product cannot read it, so it can never say whether a target size is
# certified - which is why an SAP machine is not the product's to move.

# The Azure licence types that put a machine on SAP repositories. Microsoft
# documents each one as installing "RHEL for SAP Business Apps", "RHEL for SAP
# with HA", or "SLES SAP" repositories. A machine carrying one of these is
# paying for SAP content.
# Source: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/azure-hybrid-benefit-linux
$script:VmfSapLicenseTypes = @(
    'RHEL_SAPAPPS',
    'RHEL_SAPHA',
    'RHEL_BASESAPAPPS',
    'RHEL_BASESAPHA',
    'SLES_SAP'
)

# The marketplace offers that are SAP products, by publisher and offer. These
# are not a general operating system with an SAP label: RHEL for SAP Apps
# carries the SAP-certified kernel, the SAP-tuned performance profiles and the
# SAP HA resource agents.
#
# Matched on the OFFER, gated by the PUBLISHER, exactly like the network
# virtual appliance list - an offer name alone is not evidence.
# Source: the same Microsoft page, which lists every eligible offer.
$script:VmfSapImages = @{
    'redhat' = @('rhel-sap-apps', 'rhel-sap-ha')
    # Every SUSE SAP offer is `sles-sap` followed by the version, with an
    # optional `-hardened`: sles-sap-16-0-x86-64, sles-sap-15-sp7,
    # sles-sap-15-sp7-hardened, ... sles-sap-12-sp5. The prefix is the
    # product name, so it is matched as a prefix rather than copied as ten
    # strings that go stale on the next service pack.
    'suse'   = @('sles-sap*')
}

function Test-VmfSapLicense {
    <#
      .SYNOPSIS
      SAP-1: does this machine's Azure licence type put it on SAP repositories?
      .OUTPUTS
      @{ IsSap = bool; Detail = string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$LicenseType)

    if ([string]::IsNullOrWhiteSpace($LicenseType)) {
        return @{ IsSap = $false; Detail = 'no licence type recorded' }
    }
    foreach ($known in $script:VmfSapLicenseTypes) {
        if ($LicenseType -eq $known) {
            return @{ IsSap = $true
                      Detail = "the machine carries the Azure licence type $known, which puts it on SAP repositories" }
        }
    }
    @{ IsSap = $false; Detail = "licence type $LicenseType is not an SAP one" }
}

function Test-VmfSapImage {
    <#
      .SYNOPSIS
      SAP-1: was this machine built from an SAP marketplace image?
      .OUTPUTS
      @{ IsSap = bool; Detail = string }
      .NOTES
      An EMPTY publisher (a custom or gallery image) is not judged here. There
      is no marketplace record to match, and inventing a verdict from nothing
      is the DRIVER-1 mistake - the same rule the appliance check follows.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Publisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Offer
    )

    if ([string]::IsNullOrWhiteSpace($Publisher) -or [string]::IsNullOrWhiteSpace($Offer)) {
        return @{ IsSap = $false; Detail = 'no marketplace image record to judge' }
    }
    $pub = $Publisher.Trim().ToLowerInvariant()
    if (-not $script:VmfSapImages.ContainsKey($pub)) {
        return @{ IsSap = $false; Detail = "publisher $Publisher has no SAP offers on this list" }
    }
    $off = $Offer.Trim().ToLowerInvariant()
    foreach ($pattern in $script:VmfSapImages[$pub]) {
        if ($off -like $pattern) {
            return @{ IsSap = $true
                      Detail = "the machine was built from the SAP image $Publisher/$Offer" }
        }
    }
    @{ IsSap = $false; Detail = "$Publisher/$Offer is not an SAP offer" }
}
