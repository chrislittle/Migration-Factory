function Invoke-VmfAssessment {
    <#
    .SYNOPSIS
        Phase 1 of the factory: discover the fleet via Azure Resource Graph and
        assess every VM against the readiness rules. Read-only; mutates nothing.
    .PARAMETER Scope
        @{ Subscriptions = @('...'); ManagementGroup = 'mg-name';
           TagFilter = @{ key='migrate'; value='2026' };
           ResourceGroups = @('rg1') } - Subscriptions and/or ManagementGroup
        required (SCOPE-1: a management group expands to every readable
        subscription beneath it), rest optional.
    .PARAMETER OutPath
        Run directory; assessment.json is written to it.
    .EXAMPLE
        Invoke-VmfAssessment -Scope @{ Subscriptions = @($subId) } -OutPath .\run1
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][hashtable]$Scope,
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter()][string]$RunId = ("assess-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss')),
        [Parameter()][string]$AppGroupTag = 'app'
    )

    if ((-not $Scope.Subscriptions -or @($Scope.Subscriptions).Count -eq 0) -and -not $Scope.ManagementGroup) {
        throw 'Scope.Subscriptions and/or Scope.ManagementGroup is required - assessment never queries beyond declared scope.'
    }

    # ASSESS-PAGE-1: a name already carrying a finished scan is REFUSED.
    #
    # Nothing used to stop this. Initialize-VmfRun reuses an object whose
    # manifest exists, and the write below replaces assessment.json - so
    # scanning again under the same name silently threw away the earlier scan.
    # That is bad on its own, and it also breaks the provenance the split
    # exists for: a migration records the assessment it was planned from, and
    # overwriting that assessment leaves the migration pointing at data it was
    # never planned from.
    #
    # The test is a FINISHED scan, not merely a manifest, so a scan that failed
    # part way can still be retried under its own name. Assessments are meant to
    # be re-run and compared - as a NEW one, which is the point.
    if (Test-VmfStoreItem -RunPath $OutPath -RelPath 'assessment.json') {
        throw ("'$RunId' has already been assessed. Assessments are kept so they can be compared, " +
               'so this one is not replaced - scan again under a different name.')
    }
    $existingKind = [string](Read-VmfStoreJson -RunPath $OutPath -RelPath 'run.json' -Depth 4).kind
    if ($existingKind -and $existingKind -ne 'assessment') {
        throw "'$RunId' is a $existingKind, not an assessment. Choose a different name."
    }

    # This object is an ASSESSMENT, not a run that never started. The scope goes
    # in the manifest too, so the Assessments page can say what was scanned
    # without opening the assessment itself.
    # PROJECT-1: derived from where it is being created, never passed twice.
    Initialize-VmfRun -RunPath $OutPath -RunId $RunId -Kind 'assessment' -Scope $Scope `
        -Project (Resolve-VmfRunProject -RunPath $OutPath) | Out-Null
    $scopeDetail = @()
    if ($Scope.ManagementGroup) { $scopeDetail += "managementGroup=$($Scope.ManagementGroup)" }
    if ($Scope.Subscriptions) { $scopeDetail += "subscriptions=" + (@($Scope.Subscriptions) -join ',') }
    # STEP-LOG-4: kept a throwing write on purpose. The scan has read nothing
    # yet and saved no assessment, so a line that cannot be written stops it
    # here, and the scan can run again under its own name. Every line after
    # this one goes through Write-VmfStepLine: a lost line never stops a scan
    # part way, and never replaces a refusal's own words.
    Write-VmfEvent -RunPath $OutPath -Step 'assessment' -Outcome start -Detail ($scopeDetail -join ' ')

    $inventoryParams = @{}
    if ($Scope.Subscriptions) { $inventoryParams.Subscriptions = @($Scope.Subscriptions) }
    if ($Scope.ManagementGroup) { $inventoryParams.ManagementGroup = [string]$Scope.ManagementGroup }
    if ($Scope.TagFilter) { $inventoryParams.TagFilter = $Scope.TagFilter }
    if ($Scope.ResourceGroups) { $inventoryParams.ResourceGroups = @($Scope.ResourceGroups) }
    $inventory = Invoke-VmfAzOperation -Name 'argInventory' -RunPath $OutPath -Operation {
        Get-VmfFleetInventory @inventoryParams
    }
    # PROGRESS-1: the count goes in a FIELD as well as the sentence. The wizard
    # shows it while the scan runs, and a page that had to read the number back
    # out of "discovered 312 VMs" would break the moment somebody improved the
    # wording - a sentence is for a person, a field is for a program.
    $discovered = @($inventory).Count
    Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome info `
        -Detail "discovered $discovered VMs" -Data @{ discovered = $discovered }

    # One SKU catalog read per subscription and region (ID-ADDRESS-1 part 3),
    # indexed by size name. Azure answers the list as a subscription.
    #
    # SCAN-PARTIAL-SUBS-1: a read that fails no longer stops the scan of every
    # other subscription. Invoke-VmfAzOperation (inside the read) tries a
    # temporary failure again first; a failure that remains is collected here,
    # recorded in notRead with Azure's reason and the role the permission map
    # names, and the machines of that subscription and region are held
    # (sizes-not-read) - in the assessment, never shown as able to move.
    $catalogKeysNotRead = [System.Collections.Generic.List[string]]::new()
    $catalogErrors = @{}
    $catalogs = Read-VmfMachineCatalogs -Machines @($inventory) -IdProperty 'id' -RunPath $OutPath `
        -NotRead $catalogKeysNotRead -NotReadError $catalogErrors
    $sizesNotRead = @(Get-VmfSizesNotRead -Keys @($catalogKeysNotRead) -Errors $catalogErrors -Machines @($inventory) -IdProperty 'id')

    # AN-1: one extra Resource Graph query for the WHOLE estate, so the
    # assessment can say which interfaces carry accelerated networking. A
    # failure here leaves the map $null, which reads as "not looked up" rather
    # than "none are on" - the assessment then says nothing about AN instead of
    # saying something false.
    # REPORT-GAP-1: what this scan asked for and did not get.
    #
    # A scan that carries on with less than it wanted is the right behaviour -
    # it must not guess, and it must not turn a machine away over something it
    # could not read. What was wrong is that it then said NOTHING: the value
    # was dropped, a line went into the run log, and the report simply omitted
    # the subject. A customer read an assessment with a hole in it and no way
    # to know the hole was there.
    #
    # This is the same defect the drift checker had - a result presented
    # without saying what it could not measure.
    $notRead = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in $sizesNotRead) {
        $notRead.Add($entry)
        Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome warn `
            -Detail ("could not read the sizes Azure offers in $($entry.location) for subscription $($entry.subscriptionId) ($($entry.detail)) - " +
                     "its $($entry.machineCount) machine(s) are held until a new assessment reads them") `
            -Data @{ subscriptionId = $entry.subscriptionId; location = $entry.location; reason = $entry.reason; errorCode = $entry.errorCode }
    }

    $nicAccelerated = $null
    # CLUSTER-DETECT-1: the cluster hints come from the same read. $null =
    # not read, which no machine reads as "no hint".
    $nicClusterHints = $null
    try {
        $nicFacts = Invoke-VmfAzOperation -Name 'nicFacts' -RunPath $OutPath -Operation {
            # Same scope as the inventory, never wider: a scan must not read
            # beyond what it was asked to look at (SCOPE-1).
            $nicParams = @{}
            if ($inventoryParams.Subscriptions) { $nicParams.Subscriptions = $inventoryParams.Subscriptions }
            if ($inventoryParams.ManagementGroup) { $nicParams.ManagementGroup = $inventoryParams.ManagementGroup }
            Get-VmfNicFacts @nicParams
        }
        $nicAccelerated = $nicFacts.Accelerated
        $nicClusterHints = $nicFacts.ClusterHints
    }
    catch {
        # The subject is a KEY, not a sentence: the pages turn it into their own
        # words, and a report that had to match on English would break the
        # moment somebody improved this line.
        $notRead.Add([ordered]@{
                subject = 'acceleratedNetworking'
                detail  = [string]$_.Exception.Message
            })
        $notRead.Add([ordered]@{
                subject = 'clusterHints'
                detail  = [string]$_.Exception.Message
            })
        Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome warn `
            -Detail "could not read the network interfaces ($($_.Exception.Message)) - the report does not say if accelerated networking is on, and no machine is called standalone"
    }

    # WORKLOAD-1 (AVD): ask the DesktopVirtualization provider which machines
    # are session hosts. This is the ONLY AVD signal - no tag decides anything -
    # so a scan that cannot run it must STOP, not proceed with less: an
    # assessment produced without this check could classify a session host
    # Ready, and everything downstream trusts the assessment. The scan is
    # read-only and free, so refusing costs a role grant and a re-run - the
    # PERM-3 shape: ask at the moment the answer is cheap. (Provider not
    # registered is NOT a refusal: it is a verified "no AVD here".)
    # SCAN-SCOPE-READS-1: host pools are listed in every subscription of the
    # scope - the chosen subscriptions, every subscription under a chosen
    # management group, and the machines' own - and in NO other. A host pool
    # can sit in another subscription than its session hosts, so the scan
    # dialog tells the person to put that subscription in the scope.
    $avdSessionHosts = @{}
    $avdPoolTypes = @{}
    $avdSubs = @($inventory | ForEach-Object { ([string]$_.id -split '/')[2] } | Where-Object { $_ } | Sort-Object -Unique)
    if ($avdSubs.Count -gt 0) {
        $avdScopeSubs = @(@($Scope.Subscriptions) + $avdSubs | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $avdArgs = @{ Subscriptions = $avdScopeSubs }
        if ($Scope.ManagementGroup) { $avdArgs.ManagementGroup = [string]$Scope.ManagementGroup }
        $avdResult = Invoke-VmfAzOperation -Name 'avdSessionHosts' -RunPath $OutPath -Operation {
            Get-VmfAvdSessionHostIds @avdArgs
        }
        if (-not $avdResult.Verified) {
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome fail `
                -Detail "AVD session-host membership could not be verified: $($avdResult.Detail)"
            # SCOPE-SUBS-GUID-1: a scope value that is not a subscription ID is
            # not a missing role, so the message names the value and no role.
            if ($avdResult.ContainsKey('NotSubscriptionId') -and $avdResult.NotSubscriptionId) {
                throw "The scan cannot verify which machines are AVD session hosts. The scan scope has the value '$($avdResult.NotSubscriptionId)', which is not a subscription ID. The scan assessed no machine."
            }
            throw "Cannot verify which machines are AVD session hosts ($($avdResult.Detail)). The VMF Assessment role holds this read. On the Admin page, give the product Assess access to this place, then start the scan again. Nothing has been assessed."
        }
        $avdSessionHosts = $avdResult.Ids
        # DETECT-PATTERNS-1: each host's pool type, for the workload type.
        if ($avdResult.ContainsKey('PoolTypes') -and $avdResult.PoolTypes) { $avdPoolTypes = $avdResult.PoolTypes }
    }

    # SAP-1: which machines carry the Azure VM extension for SAP solutions?
    # Same contract as the AVD check and for the same reason: a scan that
    # cannot run it REFUSES rather than producing an assessment that could call
    # an SAP machine Ready.
    #
    # SAP-2: this needs no permission the scan does not already hold - it reads
    # virtual machine extensions through Resource Graph. So a failure here is
    # Resource Graph itself being unreachable, not a missing grant.
    $sapSystemVms = @{}
    if ($avdSubs.Count -gt 0) {
        $sapResult = Invoke-VmfAzOperation -Name 'sapSystemVms' -RunPath $OutPath -Operation {
            Get-VmfSapSystemVmIds -Subscriptions $avdSubs
        }
        if (-not $sapResult.Verified) {
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome fail `
                -Detail "SAP membership could not be verified: $($sapResult.Detail)"
            throw "Cannot verify which machines belong to SAP systems ($($sapResult.Detail)). This reads virtual machine extensions through Resource Graph with the access the scan already has, so try the scan again. Nothing has been assessed."
        }
        $sapSystemVms = $sapResult.Ids
    }

    # WORKLOAD-1 (AKS + Databricks): which resource groups do the platforms
    # themselves say they manage? Same contract as the AVD check: this is the
    # only signal (no names, no tags), so if it cannot be read the scan
    # REFUSES rather than producing an assessment that could call a cluster
    # node Ready.
    # SCAN-SCOPE-READS-1: only in the machines' own subscriptions, like the SAP
    # check (SCOPE-1). It used to read every subscription the identity could
    # see. No machine found, nothing to protect, nothing read.
    $managedPlatformGroups = @{}
    if ($avdSubs.Count -gt 0) {
        $managedGroupsResult = Invoke-VmfAzOperation -Name 'managedPlatformGroups' -RunPath $OutPath -Operation {
            Get-VmfManagedPlatformGroups -Subscriptions $avdSubs
        }
        if (-not $managedGroupsResult.Verified) {
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome fail `
                -Detail "platform-managed groups could not be verified: $($managedGroupsResult.Detail)"
            throw "Cannot verify which resource groups belong to AKS clusters or Databricks workspaces ($($managedGroupsResult.Detail)). The VMF Assessment role holds this read. On the Admin page, give the product Assess access to this place, then start the scan again. Nothing has been assessed."
        }
        $managedPlatformGroups = $managedGroupsResult.Groups
    }

    # DETECT-PATTERNS-1: three reads that find workloads which must not move
    # like an ordinary machine - SQL Server and its availability groups, the
    # shared disks of a failover cluster, and the resource groups a service or
    # a managed application owns. Same contract as the AVD, SAP and platform
    # checks: each one answers or says it could not, and a scan that cannot
    # answer one REFUSES, because an assessment that could call an
    # availability group member or a cluster node Ready is worse than none.
    # The subscriptions are the machines' own (SCOPE-1): each record lives
    # beside its machine.
    # HDD-OS-1: $null until the disk read answers - not looked up is not "none".
    $sqlVms = @{}; $diskShares = @{}; $diskTypes = $null; $groupOwners = @{}
    # HDD-OS-ASR-PROBE-1: the disks Azure Site Recovery made, from the same
    # read. $null until it answers: no disk is then taken as made by it.
    $siteRecoveryDisks = $null
    if ($avdSubs.Count -gt 0) {
        $sqlResult = Invoke-VmfAzOperation -Name 'sqlVirtualMachines' -RunPath $OutPath -Operation {
            Get-VmfSqlVirtualMachines -Subscriptions $avdSubs
        }
        if (-not $sqlResult.Verified) {
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome fail `
                -Detail "SQL Server machines could not be verified: $($sqlResult.Detail)"
            throw "Cannot verify which machines run SQL Server ($($sqlResult.Detail)). The VMF Assessment role holds Microsoft.SqlVirtualMachine/sqlVirtualMachines/read. On the Admin page, give the product Assess access to this place, then start the scan again. Nothing has been assessed."
        }
        $sqlVms = $sqlResult.Ids

        $diskResult = Invoke-VmfAzOperation -Name 'diskShares' -RunPath $OutPath -Operation {
            Get-VmfDiskShareMap -Subscriptions $avdSubs
        }
        if (-not $diskResult.Verified) {
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome fail `
                -Detail "shared disks could not be verified: $($diskResult.Detail)"
            throw "Cannot verify which machines use shared disks ($($diskResult.Detail)). This reads managed disks through Resource Graph with the access the scan already has, so try the scan again. Nothing has been assessed."
        }
        $diskShares = $diskResult.Disks
        # HDD-OS-1: the type of each disk, from the same read.
        $diskTypes = if ($diskResult.ContainsKey('Types') -and $null -ne $diskResult.Types) { $diskResult.Types } else { $null }
        $siteRecoveryDisks = if ($diskResult.ContainsKey('SiteRecovery') -and $null -ne $diskResult.SiteRecovery) { $diskResult.SiteRecovery } else { $null }

        $groupResult = Invoke-VmfAzOperation -Name 'resourceGroupOwners' -RunPath $OutPath -Operation {
            Get-VmfResourceGroupOwners -Subscriptions $avdSubs
        }
        if (-not $groupResult.Verified) {
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome fail `
                -Detail "resource group owners could not be verified: $($groupResult.Detail)"
            throw "Cannot verify which resource groups a service or a managed application owns ($($groupResult.Detail)). This reads resource groups through Resource Graph with the access the scan already has, so try the scan again. Nothing has been assessed."
        }
        $groupOwners = $groupResult.Groups
    }

    # CLUSTER-DETECT-1: the SQL IaaS Agent extension, a hint that a machine may
    # be a cluster node. A hint never blocks, so a read that fails does not
    # stop the scan: it is said in notRead, and the machines read as not
    # checked - never standalone.
    $sqlAgentVms = $null
    if ($avdSubs.Count -gt 0) {
        $agentResult = Invoke-VmfAzOperation -Name 'sqlIaaSAgentExtensions' -RunPath $OutPath -Operation {
            Get-VmfSqlIaaSAgentVmIds -Subscriptions $avdSubs
        }
        if ($agentResult.Verified) { $sqlAgentVms = $agentResult.Ids }
        else {
            if (-not @($notRead | Where-Object { $_.subject -eq 'clusterHints' }).Count) {
                $notRead.Add([ordered]@{ subject = 'clusterHints'; detail = [string]$agentResult.Detail })
            }
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome warn `
                -Detail "could not read the SQL IaaS Agent extensions ($($agentResult.Detail)) - no machine is called standalone"
        }
    }
    else { $sqlAgentVms = @{} }

    # REBUILD-REMOVE-SCAN-EXT-1 (assessment v15): the scan reads no list of
    # every extension of every machine, and no data collection rule
    # association (REBUILD-REMOVE-ROLE-1, v12). Both were read only for the
    # acceptance of a rebuild, which is gone with the rebuild.

    # LINUX-VERSION-OVERFLOW-1: one machine whose record cannot be made does
    # not stop the scan of the others. A Linux release with too many digits,
    # which root inside one machine controls, ended the scan here and saved no
    # assessment. The machine is held (machine-not-read) with what the product
    # said, the run log says which machine, and the others are judged.
    $records = foreach ($vm in @($inventory)) {
        try {
            $skuEntry = $null
            $machineCatalog = Get-VmfMachineCatalog -Catalogs $catalogs -VmId ([string]$vm.id) -Location ([string]$vm.location)
            if ($machineCatalog) { $skuEntry = $machineCatalog[[string]$vm.sku] }
            # SCAN-PARTIAL-SUBS-1: its subscription and region were not read.
            $vmSizesNotRead = [bool]([string]$vm.location -and
                $catalogKeysNotRead.Contains((Get-VmfCatalogKey -VmId ([string]$vm.id) -Location ([string]$vm.location))))
            # IMAGE-1: ask Azure whether the image supports NVMe. GEN1-IMAGE-1:
            # judged against the machine as it is now, so a machine upgraded from
            # Gen1 to Gen2 is not refused for the Gen1 image it was built from.
            $imageNvme = Get-VmfMachineImageNvme -Vm $vm -RunPath $OutPath
            Get-VmfAssessmentRecord -Vm $vm -SkuEntry $skuEntry `
                -AppGroupTag $AppGroupTag -SapSystemVms $sapSystemVms `
                -ImageNvmeSupported $imageNvme.Nvme -ImageNvmeNote $imageNvme.Note -NicAcceleratedMap $nicAccelerated `
                -AvdSessionHosts $avdSessionHosts -ManagedPlatformGroups $managedPlatformGroups `
                -AvdPoolTypes $avdPoolTypes -SqlVms $sqlVms -DiskShares $diskShares -DiskTypes $diskTypes -SiteRecoveryDisks $siteRecoveryDisks -ResourceGroupOwners $groupOwners `
                -NicClusterHints $nicClusterHints -SqlAgentVms $sqlAgentVms `
                -SizesNotRead:$vmSizesNotRead
        }
        catch {
            $why = [string]$_.Exception.Message
            # The not-read shape the scan already has: the machine is named in
            # notRead with what the product said (the report and the page show
            # it under What this scan could not read), and its record holds it.
            $notRead.Add([ordered]@{ subject = 'machine'; detail = $why; scope = [string]$vm.id; machineCount = 1 })
            Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome warn `
                -Detail "could not read the facts of machine $([string]$vm.name) ($why) - it is held until a new assessment reads it" `
                -Data @{ vmId = [string]$vm.id }
            Get-VmfMachineNotReadRecord -Vm $vm -Detail $why
        }
    }

    # IDENTITY-4: the fleet-wide read of what each system-assigned identity
    # could reach WAS HERE, with its coverage record. See the note in
    # Private/assess/Discovery.ps1 for why it is gone. The DETECTION survives -
    # identityType and identityPrincipalId come off the VM object and cost
    # nothing - and that is what the finding, the wave gate and the PRECHECK
    # record are all built on.

    $summary = @{}
    foreach ($r in @($records)) {
        $summary[$r.classification] = 1 + $(if ($summary.ContainsKey($r.classification)) { $summary[$r.classification] } else { 0 })
    }

    $doc = [ordered]@{
        # AN-PRIMARY-1: one place holds the version (AssessmentContract.ps1).
        schemaVersion = Get-VmfAssessmentSchemaVersion
        runId         = $RunId
        generatedUtc  = (Get-Date).ToUniversalTime().ToString('o')
        scope         = [ordered]@{
            # SCAN-SCOPE-NULL-1: @($x) of a value that is not there is a list
            # with one null in it, which the schema refuses. A scan of a
            # management group has no subscription list, and most scans have
            # no resource group filter.
            subscriptions   = @(@($Scope.Subscriptions) | Where-Object { $_ })
            managementGroup = $(if ($Scope.ManagementGroup) { [string]$Scope.ManagementGroup } else { $null })
            tagFilter       = $Scope.TagFilter
            resourceGroups  = @(@($Scope.ResourceGroups) | Where-Object { $_ })
            # DRIFT-12 (assessment v16): no acceptedImages. The image override
            # it recorded is removed - no page or service call could pass it.
        }
        summary       = $summary
        # REPORT-GAP-1: subjects this scan could not read, so the report can
        # say the estate was assessed WITHOUT them rather than quietly leaving
        # them out.
        notRead       = @($notRead)
        # IDENTITY-3: how far the identity check reached, for the page to say.
        vms           = @($records)
    }
    # ASSESS-APPROVAL-HASH-1: create-only. The check at the start of the scan
    # is not enough: two scans started on one run both pass it, and the one
    # that finished last replaced the other - also after somebody approved it,
    # so a migration could be planned from a scan nobody read (Claude
    # Security scan, F13). The store lets exactly one creator win
    # (If-None-Match: * on blob storage, CreateNew on the file backend); the
    # scan saved first stays as it was. -UniqueText: the text holds this
    # scan's time, so a create whose answer was lost is still known as ours.
    if (-not (Write-VmfStoreJsonExclusive -RunPath $OutPath -RelPath 'assessment.json' -Document $doc -UniqueText)) {
        throw ("'$RunId' has another scan, saved while this scan ran. The product keeps that scan and does not save this one. " +
               'Scan again under a different name to get a new scan.')
    }
    $assessmentPath = Get-VmfStoreItemHandle -RunPath $OutPath -RelPath 'assessment.json'

    Write-VmfStepLine -RunPath $OutPath -Step 'assessment' -Outcome ok `
        -Detail (($summary.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')

    [pscustomobject]@{
        RunId          = $RunId
        AssessmentPath = $assessmentPath
        Total          = @($records).Count
        Summary        = [pscustomobject]$summary
    }
}
