# TARGET-CAPABILITY-PRECHECK-1, at Checking: the target advice did not offer a
# size that does not support a feature the machine uses, but the advice is
# made from the scan, and the machine or the catalog can change after it - a
# person turns on encryption at host, adds an Ultra Disk, or Azure changes a
# zone. So Checking asks again, from the machine just read and the live
# catalog, before the first safety copy stops the machine. Past here the same
# answer is Azure refusing the resize in Moving, and a rollback.

function Test-VmfTargetFeaturesReady {
    <#
    .SYNOPSIS
        Stop before the machine is touched when the planned size does not
        support encryption at host, Ultra Disk compatibility (in the machine's
        zone) or Premium Storage for a Premium SSD v2 or Ultra Disk the machine
        uses - or when the catalog does not say it does.
    .DESCRIPTION
        Read-only: it changes nothing, and a resume asks again from the top.
        The catalog is read only when the machine uses one of the features,
        as the machine's own subscription (ID-ADDRESS-1), from the cache
        Get-VmfSkuCatalog keeps - no new Azure call.
    .OUTPUTS
        $null to go on, or the NEEDS_DECISION result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter(Mandatory)]$Capture
    )
    $eah = [bool]($Capture.securityProfile -and $Capture.securityProfile.encryptionAtHost -eq $true)
    $ultra = [bool]($Capture.ultraSsdEnabled -eq $true)
    $disks = @(@($Capture.osDisk) + @($Capture.dataDisks) | Where-Object { $_ })
    $premiumDisks = @($disks | Where-Object { [string]$_.skuName -in $script:VmfPremiumStorageDiskTypes })
    if (-not $eah -and -not $ultra -and -not $premiumDisks.Count) { return $null }

    $size = [string]$PlanEntry.target.size
    $region = if ([string]$Capture.location) { [string]$Capture.location } else { [string]$PlanEntry.assessment.location }
    $zone = Get-VmfMachineZone -Machine $Capture
    $vmSub = Get-VmfSubscriptionId -ResourceId $Context.VmId
    $skuEntry = Invoke-VmfAzOperation -Name 'skuCatalog' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        @(Get-VmfSkuCatalog -Location $region -SubscriptionId $vmSub) | Where-Object { $_.Name -eq $size } | Select-Object -First 1
    }
    $gaps = @(Get-VmfTargetFeatureGaps -EncryptionAtHost $eah -UltraSsdEnabled $ultra -Disks $disks -SkuEntry $skuEntry -Zone $zone -Location $region)
    if (-not $gaps.Count) { return $null }
    @{
        Next = 'NEEDS_DECISION'; Reason = 'targetFeatureNotSupported'
        Detail = (Get-VmfTargetFeatureDetail -Gaps $gaps -Size $size -Zone $zone -Location $region)
    }
}
