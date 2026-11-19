# Discovery: fleet inventory via Azure Resource Graph. The ARM call itself is
# in azureops (Invoke-VmfResourceGraphQuery), which is what gives a throttled
# page a retry instead of failing the whole scan - BOUNDARY-1.

$script:VmfArgQuery = @'
Resources
| where type =~ 'microsoft.compute/virtualmachines'
| extend sku = tostring(properties.hardwareProfile.vmSize),
         os = tostring(properties.storageProfile.osDisk.osType),
         gen = tostring(properties.extended.instanceView.hyperVGeneration),
         // SCOPE (a scope rule): this is a SERVER OS tool. The agent reports the
         // RUNNING OS name here regardless of what image the machine was built
         // from - which is what catches a custom-image client VM that no
         // marketplace record would ever reveal. Empty when deallocated
         // (measured 2026-09-27). gen is NOT: Resource Graph reported V1 and
         // V2 for three deallocated machines that day.
         osName = tostring(properties.extended.instanceView.osName),
         // ADVISE-AN-1: and the version the agent reports beside it - for
         // Linux the release that RUNS (an in-place upgrade does not change
         // the image). Microsoft's own assessment query reads this field.
         // Empty when deallocated, as osName is.
         osVersionRunning = tostring(properties.extended.instanceView.osVersion),
         diskController = tostring(properties.storageProfile.diskControllerType),
         imagePublisher = tostring(properties.storageProfile.imageReference.publisher),
         imageOffer = tostring(properties.storageProfile.imageReference.offer),
         imageSku = tostring(properties.storageProfile.imageReference.sku),
         imageId = tostring(properties.storageProfile.imageReference.id),
         vmssId = tostring(properties.virtualMachineScaleSet.id),
         hibernationEnabled = tobool(properties.additionalCapabilities.hibernationEnabled),
         // REBUILD-MOVE-HOST-1 (2026-11-11): a machine on an Azure
         // Dedicated Host is outside the scope of this tool. The host, when
         // the machine was placed on one; the host group, when it was placed
         // in one (automatic placement can leave the host out of the model).
         hostId = tostring(properties.host.id),
         hostGroupId = tostring(properties.hostGroup.id),
         securityType = tostring(properties.securityProfile.securityType),
         // TARGET-CAPABILITY-PRECHECK-1: encryption at host and Ultra Disk
         // compatibility. A target size must support each one the machine
         // uses, or Azure refuses the resize after the stop. Azure leaves the
         // property out when it is not set, which reads null here: off.
         encryptionAtHost = tobool(properties.securityProfile.encryptionAtHost),
         ultraSsdEnabled = tobool(properties.additionalCapabilities.ultraSSDEnabled),
         dataDiskCount = array_length(properties.storageProfile.dataDisks),
         availabilitySetId = tostring(properties.availabilitySet.id),
         // CRG-MOVE-DEMAND-1: the capacity reservation group the machine is
         // in, empty for none. A machine in a group this migration did not
         // make stays in it through the move (CRG-MOVE-1), so the wave
         // reserves no place for it.
         capacityReservationGroupId = tostring(properties.capacityReservation.capacityReservationGroup.id),
         nicCount = array_length(properties.networkProfile.networkInterfaces),
         // ASSESS-2(a): an UNMANAGED (blob VHD) OS disk has no managedDisk id.
         // Those machines cannot be migrated by the product at all, and today they
         // get all the way to PRECHECK before failing messily on a capture that
         // assumes a managed disk. Knowing it here makes it a plain answer in
         // the report instead of a confusing failure later.
         osDiskManagedId = tostring(properties.storageProfile.osDisk.managedDisk.id),
         osDiskVhdUri = tostring(properties.storageProfile.osDisk.vhd.uri),
         // IDENTITY-UX-1: a rebuild (Path B) gives a machine a NEW system-
         // assigned identity - same name, different account - and every
         // grant to the old one stops working. The assessment says so at
         // the first screen, so it needs the fact here.
         identityType = tostring(identity.type),
         identityPrincipalId = tostring(identity.principalId),
         // ADE-2: Azure Disk Encryption, at SCAN time. The engine already
         // refuses an encrypted machine, but it learned this from the VM
         // extensions at the moment the wave ran - so the machine stopped
         // mid-migration, days after somebody planned around it.
         //
         // THIS IS THE OS DISK ONLY. Azure records the setting per disk, and
         // this field says nothing about the data disks. So TRUE is an answer
         // and FALSE IS NOT: the extension check at run time stays exactly
         // where it is, and this only ever moves the discovery earlier.
         adeOsDiskEnabled = tostring(properties.storageProfile.osDisk.encryptionSettings.enabled),
         // SAP-1: the Azure licence type. RHEL_SAPAPPS, RHEL_SAPHA,
         // RHEL_BASESAPAPPS, RHEL_BASESAPHA and SLES_SAP each put the machine
         // on SAP repositories, which nobody pays for by accident. Empty when
         // the licence type was never set, which is not a statement either way.
         licenseType = tostring(properties.licenseType),
         // EPHEMERAL-1: an EPHEMERAL OS disk lives on the host, not in a disk
         // resource. 'Local' is the only value that means it, and it is the
         // signal Microsoft's own published inventory query uses.
         osDiskDiffOption = tostring(properties.storageProfile.osDisk.diffDiskSettings.option),
         // DETECT-PATTERNS-1: a storage or backup appliance reaches Azure as
         // a Marketplace image (publisher and offer, above), a Marketplace
         // PURCHASE PLAN - which Azure keeps on the machine when the image
         // came from a gallery or a managed application - or a vendor's own
         // gallery image (WEKA: a community gallery). Read by a separate
         // lifecycle planner tool on test machines, 2026-10-16.
         planPublisher = tostring(plan.publisher),
         planProduct = tostring(plan.product),
         // NO-PLAN-SCOPE-1: and its name, so the scan names the whole plan of
         // a machine it puts outside the scope of this tool.
         planName = tostring(plan.name),
         communityGalleryImageId = tostring(properties.storageProfile.imageReference.communityGalleryImageId),
         sharedGalleryImageId = tostring(properties.storageProfile.imageReference.sharedGalleryImageId),
         // and each data disk, to find a shared disk (maxShares > 1) - a
         // failover cluster node. Resource Graph has no list of the machines
         // on a shared disk, so the machine's own list is where to start.
         dataDisks = properties.storageProfile.dataDisks,
         nicIds = properties.networkProfile.networkInterfaces
| project id, name, resourceGroup, location, zones, sku, os, gen, osName, osVersionRunning, diskController,
          imagePublisher, imageOffer, imageSku, imageId, vmssId, hibernationEnabled, hostId, hostGroupId, securityType, encryptionAtHost, ultraSsdEnabled,
          dataDiskCount, availabilitySetId, capacityReservationGroupId, nicCount, osDiskManagedId, osDiskVhdUri, nicIds, tags,
          identityType, identityPrincipalId, adeOsDiskEnabled, licenseType, osDiskDiffOption,
          planPublisher, planProduct, planName, communityGalleryImageId, sharedGalleryImageId, dataDisks
| order by name asc
'@

function Get-VmfFleetInventory {
    <#
    .SYNOPSIS
        Enumerate VMs in scope via Azure Resource Graph, with paging.
    .PARAMETER Subscriptions
        Subscription IDs to query. One of Subscriptions or ManagementGroup is
        required - never query beyond declared scope.
    .PARAMETER ManagementGroup
        SCOPE-1: a management group id/name; Resource Graph expands it to every
        subscription beneath that the caller can read.
    .PARAMETER TagFilter
        Optional @{ key = 'name'; value = 'x' } - only VMs carrying that tag value.
    .PARAMETER ResourceGroups
        Optional RG name allowlist (case-insensitive).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][string[]]$Subscriptions,
        [Parameter()][string]$ManagementGroup,
        [Parameter()][hashtable]$TagFilter,
        [Parameter()][string[]]$ResourceGroups
    )

    if ((-not $Subscriptions -or @($Subscriptions).Count -eq 0) -and -not $ManagementGroup) {
        throw 'Declare a scope: Subscriptions and/or ManagementGroup.'
    }

    $query = $script:VmfArgQuery
    if ($TagFilter -and $TagFilter.key) {
        # A quote or a backslash would end or escape the KQL string, so both go.
        $k = $TagFilter.key -replace "['\\]", ""
        $v = [string]$TagFilter.value -replace "['\\]", ""
        $query = $query -replace '\| order by name asc',
            "| where tostring(tags['$k']) =~ '$v'`n| order by name asc"
    }
    # SCAN-SCOPE-READS-1 review: a scan of resource groups asks Resource Graph
    # for the machines of those groups only, rather than reading every machine
    # of the subscription and dropping the rest here. A quote and a backslash
    # are removed from each name, as for the tag, so a name cannot end the list.
    $rgNames = @(@($ResourceGroups) | Where-Object { $_ } | ForEach-Object { "'" + ([string]$_ -replace "['\\]", '') + "'" })
    if ($rgNames.Count -gt 0) {
        # String.Replace, not -replace: the names are text, never a pattern.
        $query = $query.Replace('| order by name asc', "| where resourceGroup in~ ($($rgNames -join ', '))`n| order by name asc")
    }

    $all = [System.Collections.Generic.List[object]]::new()
    $skipToken = $null
    do {
        $body = @{
            query   = $query
            options = @{ '$top' = 500 }
        }
        # Resource Graph accepts either scope shape; a management group expands
        # to every readable subscription beneath it (SCOPE-1).
        if ($ManagementGroup) { $body.managementGroups = @($ManagementGroup) }
        if ($Subscriptions -and @($Subscriptions).Count -gt 0) { $body.subscriptions = @($Subscriptions) }
        if ($skipToken) { $body.options['$skipToken'] = $skipToken }

        # BOUNDARY-1: the ARM call itself lives in azureops, so a throttled
        # page is retried instead of losing the whole scan.
        $parsed = Invoke-VmfResourceGraphQuery -Body $body
        foreach ($row in @($parsed.data)) { $all.Add($row) }
        $skipToken = $parsed.'$skipToken'
    } while ($skipToken)

    $result = $all.ToArray()
    if ($ResourceGroups -and $ResourceGroups.Count -gt 0) {
        $rgSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ResourceGroups, [System.StringComparer]::OrdinalIgnoreCase)
        $result = @($result | Where-Object { $rgSet.Contains($_.resourceGroup) })
    }
    return , $result
}

$script:VmfArgNicQuery = @'
Resources
| where type =~ 'microsoft.network/networkinterfaces'
| extend accelerated = tobool(properties.enableAcceleratedNetworking),
         // CLUSTER-DETECT-1: the IP configurations, for two cluster hints - a
         // load balancer backend pool, and more than one IP configuration (an
         // availability group listener or a cluster IP address). Read from the
         // interface only: the role does not read load balancers (decided
         // 2026-10-27), so floating IP, which is on the load balancer's rule,
         // is not looked at.
         ipConfigurations = properties.ipConfigurations
| project id, accelerated, ipConfigurations
'@

# IDENTITY-4, 2026-09-11. The three Resource Graph queries that read what each
# system-assigned identity could reach, and the two functions that attached the
# answer to every record, WERE HERE. They are gone, with the whole of IDENTITY-3
# steps 1 to 3.
#
# The product could never be sure it made the right grants, which made the
# feature flawed and confusing. Finding every dependency of a system-assigned
# identity on a temporary disk move is not the product's job; its job is to
# show the risk, so the customer can assess the impact and approve.
#
# The list could never be complete. Azure RBAC and key-vault policies are what
# Resource Graph can see; group membership and app-role assignments live in
# Entra, which the ENGINE cannot read without a standing directory grant this
# product deliberately does not hold - so they were never recorded, and a
# re-grant from that list would have restored a subset while reading as the
# whole. The panel that asked the wider question said so in its own closing
# sentence: a runbook, a pipeline or a linked service holding the client id is
# invisible to every check it ran.
#
# What replaces it is the DETECTION, which is free: identityType and
# identityPrincipalId come off the VM object. The product says a rebuild
# destroys the identity, parks the machine, and an approver accepts that after
# the customer's own analysis (DECIDE-1). The old account is recorded when it
# is destroyed and shown in the report (IDENTITY-4), which is a fact about our
# own action rather than research into theirs.

function Get-VmfNicFacts {
    <#
    .SYNOPSIS
        AN-1: which network interfaces have accelerated networking switched on.
        CLUSTER-DETECT-1: and, from the same read, the two cluster hints of
        each interface.

        The assessment recorded how MANY interfaces a machine has and nothing
        about them, so the first time anyone learned an AN layout would not fit
        its target was plan time or PRECHECK - not the report they read when
        deciding. This is one extra Resource Graph query for the whole estate,
        not one call per machine.

        Accelerated networking lives on the INTERFACE, not the VM, which is why
        it needs a second query at all.
    .OUTPUTS
        @{ Accelerated = @{ nic id (lowercase) -> [bool] }
           ClusterHints = @{ nic id (lowercase) -> @{ ipConfigCount; pools = @(backend pool ids) } } }
        An interface the caller cannot see is simply absent from both, and
        absent must read as "unknown" rather than "off" or "no hint" - the
        caller decides what to do with that.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][string[]]$Subscriptions,
        [Parameter()][string]$ManagementGroup
    )

    $map = @{}
    $hints = @{}
    $skipToken = $null
    do {
        $body = @{ query = $script:VmfArgNicQuery; options = @{ '$top' = 500 } }
        if ($ManagementGroup) { $body.managementGroups = @($ManagementGroup) }
        if ($Subscriptions -and @($Subscriptions).Count -gt 0) { $body.subscriptions = @($Subscriptions) }
        if ($skipToken) { $body.options['$skipToken'] = $skipToken }
        $parsed = Invoke-VmfResourceGraphQuery -Body $body
        foreach ($row in @($parsed.data)) {
            if (-not $row.id) { continue }
            $key = ([string]$row.id).ToLowerInvariant()
            $map[$key] = [bool]$row.accelerated
            $ipcs = @(@($(if ($row.PSObject.Properties['ipConfigurations']) { $row.ipConfigurations })) | Where-Object { $_ })
            $pools = @(foreach ($ipc in $ipcs) {
                    $props = if ($ipc.PSObject.Properties['properties']) { $ipc.properties } else { $null }
                    if ($props -and $props.PSObject.Properties['loadBalancerBackendAddressPools']) {
                        foreach ($pool in @($props.loadBalancerBackendAddressPools)) { if ($pool -and $pool.id) { [string]$pool.id } }
                    }
                })
            $hints[$key] = @{ ipConfigCount = $ipcs.Count; pools = @($pools | Sort-Object -Unique) }
        }
        $skipToken = $parsed.'$skipToken'
    } while ($skipToken)
    @{ Accelerated = $map; ClusterHints = $hints }
}
