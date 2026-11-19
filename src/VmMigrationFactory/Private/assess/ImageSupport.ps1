# IMAGE-1: which OS images the product will migrate.
#
# The requirement splits in two, and only one half is a fact Azure will tell
# us. Measured from the image API (2024-07-01):
#
#   CAN it boot on NVMe?  Reported per image version as the DiskControllerTypes
#                         feature. Gen1 images report "SCSI"; most Gen2 images
#                         report "SCSI, NVMe" - but Windows Server 2016 Gen2
#                         reports "SCSI" (measured 2026-09-29). Read it, never
#                         infer it.
#   IS it supported?      Azure has no opinion. OpenLogic CentOS 7.9 is end of
#                         life and still advertises NVMe. So support is a
#                         curated judgement, held as versioned DATA in
#                         data/supported-images.json where it can be reviewed.

function Get-VmfImageMatrix {
    <#
    .SYNOPSIS
        Load the publisher support matrix that ships with the module.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)

    if (-not $script:VmfImageMatrix -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'supported-images.json' }
        $script:VmfImageMatrix = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfImageMatrix
}

function Get-VmfImageMatrixEntry {
    <#
    .SYNOPSIS
        DRIFT-12: the support list entry for an image's publisher and offer.
    .DESCRIPTION
        An entry with no offerPattern covers every offer of its publisher. An
        entry with one covers only the offers it matches (microsoftazurelinux:
        azurelinux-<n>), and wins over the entry with none (SUSE: openSUSE
        Leap). Case is ignored, as Azure ignores it. The one reading
        of the list: the scan's support question and the release reader
        (Get-VmfImageRelease) both ask it.
    .OUTPUTS
        @{ Entry = <entry or $null>; PublisherKnown = <bool> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Publisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Offer,
        [Parameter()][AllowNull()]$Matrix
    )
    if (-not $Publisher) { return @{ Entry = $null; PublisherKnown = $false } }
    $m = if ($Matrix) { $Matrix } else { Get-VmfImageMatrix }
    $same = @(@($m.publishers) | Where-Object { [string]$_.publisher -ieq $Publisher })
    # IMAGE-SCRIPT-MATCH-1: the entry for the offer wins over the entry for the
    # whole publisher, wherever each is in the list. SUSE is endorsed, and its
    # openSUSE Leap offers are not.
    $byOffer = @($same | Where-Object { $_.PSObject.Properties['offerPattern'] -and [string]$_.offerPattern })
    foreach ($e in $byOffer) {
        if ([string]$Offer -imatch [string]$e.offerPattern) { return @{ Entry = $e; PublisherKnown = $true } }
    }
    $wide = @($same | Where-Object { -not ($_.PSObject.Properties['offerPattern'] -and [string]$_.offerPattern) } | Select-Object -First 1)
    if ($wide.Count) { return @{ Entry = $wide[0]; PublisherKnown = $true } }
    @{ Entry = $null; PublisherKnown = ($same.Count -gt 0) }
}

function Get-VmfImageSupport {
    <#
    .SYNOPSIS
        IMAGE-1: may this machine's OS image be migrated?
    .DESCRIPTION
        Anything not positively recognised is refused. An unknown publisher is
        NOT "probably fine" - the product moves other people's production
        machines, and the cost of being wrong is a VM that does not come back.

        DRIFT-12 (2026-11-12): nothing overrides the answer. The
        operator override this had (AcceptedImages) was reachable from no page
        and no service call, so it is removed, and every reason says the fact
        and that the product does not move the machine.
    .OUTPUTS
        @{ Supported = <bool>; Status = <string>; Reason = <string> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][string]$Publisher,
        [Parameter()][AllowNull()][string]$Offer,
        [Parameter()][AllowNull()][string]$Sku,
        [Parameter()][AllowNull()][string]$ImageId,
        [Parameter()][AllowNull()]$Matrix
    )

    if (-not $Publisher) {
        return @{
            Supported = $false; Status = 'custom-image'
            Reason = 'This machine runs a custom image, so the product cannot check its support. The product does not move this machine.'
        }
    }

    $found = Get-VmfImageMatrixEntry -Publisher $Publisher -Offer $Offer -Matrix $Matrix
    $entry = $found.Entry
    if (-not $entry -and $found.PublisherKnown) {
        return @{
            Supported = $false; Status = 'unknown-offer'
            Reason = "The product does not recognize the offer '$Offer' of the publisher '$Publisher'. The product does not move this machine."
        }
    }
    if (-not $entry) {
        return @{
            Supported = $false; Status = 'unknown-publisher'
            Reason = "The product does not recognize the publisher '$Publisher'. The product does not move this machine."
        }
    }
    if ($entry.support -eq 'unsupported') {
        return @{
            Supported = $false; Status = 'unsupported'
            Reason = [string]$entry.note
        }
    }
    @{ Supported = $true; Status = [string]$entry.support; Reason = "published by $Publisher" }
}

function Test-VmfImageSupportsNvme {
    <#
    .SYNOPSIS
        IMAGE-1: does the image itself carry NVMe support, per Azure?
    .DESCRIPTION
        Reads the DiskControllerTypes feature from an image version. Returns
        $null when Azure reported nothing - unknown is not the same as no, and
        the engine must not turn silence into either answer.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$Features)

    $f = @($Features) | Where-Object { $_.name -eq 'DiskControllerTypes' } | Select-Object -First 1
    if (-not $f -or -not $f.value) { return $null }
    [bool]([string]$f.value -match '(?i)nvme')
}

# GEN1-IMAGE-1: a machine taken from Gen1 to Gen2 by Microsoft's route (MBR2GPT,
# then the Trusted Launch upgrade) still names the Gen1 image it was BUILT
# from, and a Gen1 Windows image reports SCSI only. That answer is about the
# image's generation, not the machine's, so it refused machines that can run
# on NVMe (lab drill, 2026-09-25). Azure publishes the Gen2 edition of the
# same build under a related name with the SAME version number - measured:
# 2022-datacenter and 2022-datacenter-g2 are both 20348.5622.260906 - so the
# name nominates a candidate and the version and architecture confirm it.
# The three suffixes are the ones Microsoft uses, measured from the catalogue.
$script:VmfGen2SkuSuffixes = @('-g2', '-gen2', '-gensecond')

function Get-VmfGen2ImageSkuCandidates {
    <#
    .SYNOPSIS
        GEN1-IMAGE-1: the SKUs in a listing that could be the Gen2 edition of
        a Gen1 SKU.
    .DESCRIPTION
        Case is ignored and a dot matches an underscore, because Canonical's
        18.04-LTS pairs with 18_04-lts-gen2. A candidate is only a candidate:
        Resolve-VmfImageNvmeAnswer confirms it by version and architecture.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Sku,
        [Parameter()][AllowNull()][string[]]$SkuNames
    )

    if (-not $Sku) { return @() }
    $norm = { param($name) ([string]$name).ToLowerInvariant().Replace('.', '_') }
    $wanted = @($script:VmfGen2SkuSuffixes | ForEach-Object { (& $norm $Sku) + $_ })
    @(@($SkuNames) | Where-Object { $_ -and ($wanted -contains (& $norm $_)) })
}

function Test-VmfImageNeedsGen2Edition {
    <#
    .SYNOPSIS
        GEN1-IMAGE-1: is Azure's answer for this image about a generation the
        machine no longer is?
    .DESCRIPTION
        True only for a Gen2 machine on a Gen1 image that did not say YES. A
        Gen1 image that already reports NVMe needs no second question, and a
        NO from a Gen2 image is a real NO.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$VmGeneration,
        [Parameter()][AllowNull()]$Image
    )

    [bool]($Image -and $VmGeneration -match 'V?2' -and [string]$Image.hyperVGeneration -eq 'V1' -and $true -ne $Image.nvme)
}

function Resolve-VmfImageNvmeAnswer {
    <#
    .SYNOPSIS
        GEN1-IMAGE-1: Azure's NVMe answer for the machine as it is now.
    .DESCRIPTION
        Pure. For a Gen2 machine on a Gen1 image, the answer comes from the
        Gen2 edition of the SAME build - same version number, same
        architecture, and Gen2. Without one, the answer is UNKNOWN: the Gen1
        answer does not apply, and nothing else was measured.
    .OUTPUTS
        @{ Nvme = $true/$false/$null; Note = <string or $null> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$VmGeneration,
        [Parameter()][AllowNull()]$Image,
        [Parameter()][AllowNull()][object[]]$Gen2Editions
    )

    if (-not $Image) { return @{ Nvme = $null; Note = $null } }
    if (-not (Test-VmfImageNeedsGen2Edition -VmGeneration $VmGeneration -Image $Image)) {
        return @{ Nvme = $Image.nvme; Note = $null }
    }
    $same = @(@($Gen2Editions) | Where-Object {
            $_ -and [string]$_.hyperVGeneration -eq 'V2' -and
            [string]$_.architecture -eq [string]$Image.architecture -and
            [string]$_.version -eq [string]$Image.version -and $null -ne $_.nvme })
    $answers = @($same | ForEach-Object { [bool]$_.nvme } | Sort-Object -Unique)
    $upgraded = "This machine is Generation 2, but it was built from the Generation 1 image $($Image.sku)."
    if ($answers.Count -eq 1) {
        return @{
            Nvme = $answers[0]
            Note = "$upgraded The NVMe answer comes from $($same[0].sku), the Generation 2 edition of the same build, version $($Image.version)."
        }
    }
    @{
        Nvme = $null
        Note = "$upgraded No Generation 2 edition of the same build was found, so the scan cannot tell if this machine supports NVMe."
    }
}

function Get-VmfMachineImageNvme {
    <#
    .SYNOPSIS
        IMAGE-1 and GEN1-IMAGE-1: ask Azure whether the image a machine runs
        supports NVMe, judged against the machine as it is now.
    .DESCRIPTION
        One catalogue read for the image. Two more - the offer's SKU list and
        the Gen2 edition - only for a Gen2 machine on a Gen1 image that did
        not say YES. Every read is cached, so a fleet costs a handful of calls.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter()][string]$RunPath
    )

    if (-not ($Vm.imagePublisher -and $Vm.imageOffer -and $Vm.imageSku)) { return @{ Nvme = $null; Note = $null } }
    $image = Invoke-VmfAzOperation -Name "imageFeatures:$($Vm.imagePublisher)/$($Vm.imageSku)" -RunPath $RunPath -Operation {
        Get-VmfImageVersionFacts -Location $Vm.location -Publisher $Vm.imagePublisher -Offer $Vm.imageOffer -Sku $Vm.imageSku
    }
    $editions = @()
    if (Test-VmfImageNeedsGen2Edition -VmGeneration ([string]$Vm.gen) -Image $image) {
        $names = Invoke-VmfAzOperation -Name "imageSkus:$($Vm.imagePublisher)/$($Vm.imageOffer)" -RunPath $RunPath -Operation {
            Get-VmfImageSkuNames -Location $Vm.location -Publisher $Vm.imagePublisher -Offer $Vm.imageOffer
        }
        foreach ($candidate in @(Get-VmfGen2ImageSkuCandidates -Sku ([string]$Vm.imageSku) -SkuNames $names)) {
            $editions += Invoke-VmfAzOperation -Name "imageFeatures:$($Vm.imagePublisher)/$candidate" -RunPath $RunPath -Operation {
                Get-VmfImageVersionFacts -Location $Vm.location -Publisher $Vm.imagePublisher -Offer $Vm.imageOffer -Sku $candidate
            }
        }
    }
    Resolve-VmfImageNvmeAnswer -VmGeneration ([string]$Vm.gen) -Image $image -Gen2Editions $editions
}