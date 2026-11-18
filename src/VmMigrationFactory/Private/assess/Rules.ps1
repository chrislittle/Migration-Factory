# Assessment rule engine: turns one inventory row + SKU facts into a
# classification with explicit blockers/prep items. Every rule leaves a trace -
# nothing is silently decided (MS guide "Assess" phase, traceability matrix).

function Get-VmfWindowsServerYear {
    <#
    .SYNOPSIS
        OSVER-1: the Windows Server version a machine runs, as its year - from
        the running operating system first, the image second.
    .DESCRIPTION
        The VM agent reports the running operating system's name
        (instanceView.osName, "Windows Server 2019 Datacenter"). A machine
        upgraded in place reports its new version there; its image still
        names the old one. The name is empty when the machine is deallocated or
        has no agent, and then the image decides:
          - a Windows Server image: the FIRST four-digit number of its SKU
            (WINVER-1: "2012-R2-Datacenter" is 2012, never 20122);
          - a SQL Server image: the Windows its OFFER names ("sql2017-ws2016"),
            because its SKU names the SQL edition.
        A name that is not Windows Server, or has no year, gives none. PURE.
    .OUTPUTS
        @{ Year = <int or $null>; Source = 'running' | 'image' | $null;
           ImageYear = <int or $null>; Note = <string or $null> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$OsName,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ImagePublisher,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ImageOffer,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ImageSku
    )
    $running = if ($OsName -match '(?i)\bWindows Server (\d{4})\b') { [int]$Matches[1] } else { $null }
    $image = if ($ImagePublisher -ieq 'MicrosoftWindowsServer' -and $ImageSku -match '(\d{4})') { [int]$Matches[1] }
             elseif ($ImagePublisher -ieq 'MicrosoftSQLServer' -and $ImageOffer -match '(?i)ws(\d{4})') { [int]$Matches[1] }
             else { $null }
    if ($running) {
        $note = if ($image -and $image -ne $running) {
            "The machine runs Windows Server $running. Its image is Windows Server $image. The version it runs is the one judged."
        } else { $null }
        return @{ Year = $running; Source = 'running'; ImageYear = $image; Note = $note }
    }
    if ($image) { return @{ Year = $image; Source = 'image'; ImageYear = $image; Note = $null } }
    @{ Year = $null; Source = $null; ImageYear = $null; Note = $null }
}

function Get-VmfUnsupportedFamilyCode {
    <#
    .SYNOPSIS
        OLD-FAM-3: the families the product does not move, by name, with the
        blocker code that says why. $null for every other size.
    .DESCRIPTION
        A scope decision, 2026-09-29: HPC and FPGA are left out entirely, and
        G, Gs, Ls and Lsv2 refused with the reason. Microsoft's "Retired VM
        sizes modernization guide" (2026-09-25) sends Ls, Lsv2, G and Gs to
        the L series. HPC and FPGA series have their own retirement guides,
        which the "End of Life Azure VM size series" page links; no route is
        named here, so none is invented.
        These are a SCOPE choice, not a technical limit, and the words say so:
          - H family (H, HB, HC, HX) and NP - HPC and FPGA.
          - Ls and Lsv2 - the End of Life storage optimized series. Newer L
            sizes are not End of Life, and keep the answer they always had.
          - G, Gs - Microsoft moves them to the L series.
          - GPU-SCOPE-1 (a scope decision, 2026-10-09): the GPU families NC,
            ND, NG and NV, the confidential NCC sizes among them. NP is FPGA
            and keeps its own code above. Before this, a Generation 1 GPU
            machine was given a D or E v5 size by its vCPUs and memory - a
            size with no GPU.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SizeName)
    if ($SizeName -match '^Standard_(NP|HB|HC|HX|H)\d') { return 'hpc-or-fpga-size' }
    if ($SizeName -match '^Standard_L\d+s(_v2)?$') { return 'local-nvme-storage-size' }
    if ($SizeName -match '^Standard_GS?\d') { return 'l-series-replacement' }
    if ($SizeName -match '^Standard_N(?!P\d)[A-Z]*\d') { return 'gpu-size' }
    $null
}

function Get-VmfFamilyScopeDetail {
    <#
    .SYNOPSIS
        GPU-SCOPE-1: the words for a machine on a family the product does not
        move (Get-VmfUnsupportedFamilyCode), or $null. One sentence for the
        target rules, the wave editor and PRECHECK.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Size)
    if (-not (Get-VmfUnsupportedFamilyCode -SizeName $Size)) { return $null }
    "$Size is outside the scope of this tool, so it does not move this machine."
}

function Get-VmfMaxDataDiskCount {
    <#
    .SYNOPSIS
        DISKS-32-1: the most data disks a machine the product moves may have.
    .DESCRIPTION
        A scope decision, 2026-10-05: at most 32 data disks. A machine with
        more is outside the scope of this tool on every series - not a limit
        of Azure, which has v6 and v7 sizes that take 64, and the isolated
        E104i v5 sizes. One number, so the scan, the target rules, PRECHECK
        and the capacity checks cannot disagree on it.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    32
}

function Test-VmfTooManyDataDisks {
    <#
    .SYNOPSIS
        DISKS-32-1: does this count of data disks put a machine outside the
        scope of this tool? No count is not more: an assessment without one
        gates nothing, as before.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Count)
    if ($null -eq $Count -or [string]$Count -eq '') { return $false }
    [int]$Count -gt (Get-VmfMaxDataDiskCount)
}

function Get-VmfDataDiskScopeDetail {
    <#
    .SYNOPSIS
        DISKS-32-1: the words for a machine with more data disks than this
        tool moves, or $null. One sentence for the target rules, the wave
        editor and PRECHECK.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Count)
    if (-not (Test-VmfTooManyDataDisks -Count $Count)) { return $null }
    "This machine has $([int]$Count) data disks. A machine with more than $(Get-VmfMaxDataDiskCount) data disks is outside the scope of this tool, so it does not move this machine."
}

function Get-VmfAssessedDataDiskCount {
    <#
    .SYNOPSIS
        DISKS-32-1: the data disk count an assessment record, or the copy of
        it a plan entry carries, gives - or $null when it has none.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$Assessment)
    if (-not $Assessment -or -not $Assessment.PSObject.Properties['dataDiskCount']) { return $null }
    $Assessment.dataDiskCount
}

function Test-VmfEntryOutOfScope {
    <#
    .SYNOPSIS
        GPU-SCOPE-1: is this planned machine outside the scope of this tool -
        on a family it does not move, or on a size it no longer moves because
        Microsoft retires it (RETIRE-SCOPE-1)? DISKS-32-1: or with more data
        disks than it moves?
    .DESCRIPTION
        PRECHECK stops such a machine untouched, so it never uses quota or a
        capacity reservation. A plan made before the rule still lists it on
        path A. The capacity checks leave it out through
        Get-VmfLeftOutVmIds - only while its move has NOT started, because a
        machine past PRECHECK finishes the move it started (STATE-TARGET-1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Entry)
    if (-not $Entry -or -not $Entry.assessment) { return $false }
    $size = [string]$Entry.assessment.sourceSize
    [bool](Get-VmfUnsupportedFamilyCode -SizeName $size) -or (Test-VmfSizeRetiredForTool -Size $size) -or
        (Test-VmfTooManyDataDisks -Count (Get-VmfAssessedDataDiskCount -Assessment $Entry.assessment))
}

function Get-VmfOutOfScopeBlockerCodes {
    <#
    .SYNOPSIS
        The scan's blockers that put a machine outside the scope of this tool
        on every series: the families it does not move (OLD-FAM-3,
        GPU-SCOPE-1), a retired size (OLD-FAM-4, RETIRE-SCOPE-1) and more data
        disks than it moves (DISKS-32-1). One list, so the target options and
        the wave editor cannot disagree on it.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    # DETECT-PATTERNS-1: the four workload refusals ruled outside the
    # scope of this tool - a storage or backup appliance, a machine in a
    # managed application, a failover cluster node on a shared disk, and a SQL
    # Server availability group member.
    @('hpc-or-fpga-size', 'local-nvme-storage-size', 'l-series-replacement', 'gpu-size', 'size-retired', 'too-many-data-disks',
      'storage-appliance-needs-vendor', 'managed-application-needs-vendor', 'shared-disk-cluster-node', 'sql-availability-group-member',
      # NO-PLAN-SCOPE-1: a machine with a Marketplace purchase plan.
      'purchase-plan-out-of-scope')
}

function Get-VmfAssessmentRecord {
    <#
    .SYNOPSIS
        Assess one VM inventory row. Pure logic - all Azure facts are passed in.
    .PARAMETER Vm
        One row from Get-VmfFleetInventory.
    .PARAMETER SkuEntry
        The VM's current-size entry from Get-VmfSkuCatalog for its region ($null ok).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]$Vm,
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter()][string]$AppGroupTag = 'app',
        # IMAGE-1: what Azure says about the image itself. $true/$false/$null,
        # where $null means Azure did not answer and nothing is inferred.
        [Parameter()][AllowNull()]$ImageNvmeSupported,
        # GEN1-IMAGE-1: which image answered, when it was not the one the
        # machine was built from. Recorded on the machine, never applied silently.
        [Parameter()][AllowNull()][string]$ImageNvmeNote,
        # AN-1: nic id -> accelerated networking on/off, for the whole estate.
        # $null means it was not looked up, which is different from "none are
        # on" and must stay different.
        [Parameter()][AllowNull()][hashtable]$NicAcceleratedMap,
        # WORKLOAD-1 (AKS + Databricks): 'subId/rgName' lowercased -> owner
        # description, from the ContainerService and Databricks providers.
        # $null = not looked up; the assessment refuses to run unverified.
        [Parameter()][AllowNull()][hashtable]$ManagedPlatformGroups,
        # SAP-1: lowercased VM id -> why, from Azure's SAP provider and from
        # the Azure VM extension for SAP solutions. $null = not looked up;
        # the scan refuses to run unverified, the same contract the AVD and
        # platform-group lookups carry.
        [Parameter()][AllowNull()][hashtable]$SapSystemVms,
        # WORKLOAD-1 (AVD): lowercased VM id -> host pool name, from the
        # DesktopVirtualization provider itself. $null = not looked up (the
        # enumeration failed or was skipped), which is different from empty
        # (looked up, no AVD anywhere) - and the tag stays only as a weak
        # fallback for exactly that $null case.
        [Parameter()][AllowNull()][hashtable]$AvdSessionHosts,
        # DETECT-PATTERNS-1: lowercased VM id -> the host pool's hostPoolType.
        [Parameter()][AllowNull()][hashtable]$AvdPoolTypes,
        # DETECT-PATTERNS-1: lowercased VM id -> @{ id; groupId; offer; sku },
        # the SQL IaaS Agent's record (Get-VmfSqlVirtualMachines).
        [Parameter()][AllowNull()][hashtable]$SqlVms,
        # DETECT-PATTERNS-1: lowercased disk id -> maxShares, for every
        # attached disk read (Get-VmfDiskShareMap).
        [Parameter()][AllowNull()][hashtable]$DiskShares,
        # HDD-OS-1: lowercased disk id -> the disk's type (sku.name), from
        # the same read (Get-VmfDiskShareMap). $null = not looked up; a key
        # that is absent = not read. Neither is a type.
        [Parameter()][AllowNull()][hashtable]$DiskTypes,
        # HDD-OS-ASR-PROBE-1: lowercased disk id -> $true for each disk with a
        # tag that marks a disk Azure Site Recovery made (ASR-ReplicaDisk or
        # ASR-FODisk), from the same read. $null = not looked up: no disk is
        # then taken as made by Site Recovery.
        [Parameter()][AllowNull()][hashtable]$SiteRecoveryDisks,
        # DETECT-PATTERNS-1: 'subId/rgName' lowercased -> managedBy ('' when
        # nothing manages it), for every group read (Get-VmfResourceGroupOwners).
        # For all four: $null = not looked up, and a key that is absent = not
        # read. Neither is "none".
        [Parameter()][AllowNull()][hashtable]$ResourceGroupOwners,
        # CLUSTER-DETECT-1: lowercased nic id -> @{ ipConfigCount; pools }
        # (Get-VmfNicFacts ClusterHints), and lowercased VM id -> the SQL IaaS
        # Agent extension type (Get-VmfSqlIaaSAgentVmIds). $null = not read.
        [Parameter()][AllowNull()][hashtable]$NicClusterHints,
        [Parameter()][AllowNull()][hashtable]$SqlAgentVms,
        # SCAN-PARTIAL-SUBS-1: the size list of this machine's subscription and
        # region could not be read. The machine is held (sizes-not-read) until
        # a new scan reads it - never judged from its size name alone, and
        # never shown as able to move.
        [Parameter()][switch]$SizesNotRead,
        # OLD-FAM-4: the moment a size's retirement date is judged against.
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime()
    )

    $blockers = [System.Collections.Generic.List[string]]::new()
    $prep = [System.Collections.Generic.List[string]]::new()
    $notes = [System.Collections.Generic.List[string]]::new()
    # DETECT-PATTERNS-1: what a person must check before the move, while the
    # machine may still move. Not a blocker, and not something the product
    # prepares - so a list of its own.
    $warnings = [System.Collections.Generic.List[string]]::new()
    $vmKey = ([string]$Vm.id).ToLowerInvariant()
    $vmField = { param([string]$Name) if ($Vm.PSObject.Properties[$Name]) { [string]$Vm.$Name } else { '' } }
    # The resource group's managedBy: $null when not read.
    $groupOwner = $null
    if ($null -ne $ResourceGroupOwners -and ([string]$Vm.id -match '(?i)^/subscriptions/([^/]+)/')) {
        $groupKey = "$($Matches[1])/$($Vm.resourceGroup)".ToLowerInvariant()
        if ($ResourceGroupOwners.ContainsKey($groupKey)) { $groupOwner = [string]$ResourceGroupOwners[$groupKey] }
    }
    $groupOwnerKind = Get-VmfResourceGroupOwnerKind -ManagedBy ([string]$groupOwner)

    # --- Rule: platform-managed members are hard-excluded (scope guard) ---
    $platformManaged = $false
    if (-not [string]::IsNullOrWhiteSpace($Vm.vmssId)) {
        $platformManaged = $true; $notes.Add('member of VMSS: ' + $Vm.vmssId)
    }
    elseif ($null -ne $ManagedPlatformGroups -and ([string]$Vm.id -match '(?i)^/subscriptions/([^/]+)/') -and
            $ManagedPlatformGroups.ContainsKey("$($Matches[1])/$($Vm.resourceGroup)".ToLowerInvariant())) {
        # The AKS review replaced two weak signals with the
        # provider's own declaration. The MC_* naming convention is gone -
        # customers can rename the node RG, and an ordinary RG named MC_*
        # would have false-positived. The cluster object declares its real
        # nodeResourceGroup; the Databricks workspace declares its
        # managedResourceGroupId. Keyed by subscription AND group, so a name
        # collision across subscriptions cannot misfire.
        $platformManaged = $true
        $notes.Add("machine lives in the resource group managed by $($ManagedPlatformGroups["$($Matches[1])/$($Vm.resourceGroup)".ToLowerInvariant()]) (from the platform's own record)")
    }
    elseif ($null -ne $AvdSessionHosts -and $AvdSessionHosts.ContainsKey(([string]$Vm.id).ToLowerInvariant())) {
        # The AUTHORITATIVE signal (a tag on an AVD host is not enough to
        # protect it): the host pool itself lists this machine as a session
        # host. True for Personal and Pooled pools alike - hostPoolType changes
        # assignment semantics, never how membership is recorded.
        $platformManaged = $true
        $notes.Add("AVD session host in host pool '$($AvdSessionHosts[([string]$Vm.id).ToLowerInvariant()])' (from the DesktopVirtualization provider)")
    }
    # DETECT-PATTERNS-1: ANY service that writes its id in the resource group's
    # managedBy owns the machines in it - Azure Red Hat OpenShift as well as
    # AKS and Databricks, which the provider records above already cover. Read
    # from the TYPE in the id, never the group's name. A managed application
    # is NOT left alone silently: its vendor owns the machine, and the rule
    # below refuses it with that reason.
    if (-not $platformManaged -and $groupOwnerKind -in @('node-pool', 'service')) {
        $platformManaged = $true
        $notes.Add("machine lives in a resource group managed by $groupOwner (the resource group's managedBy)")
    }
    # BATCH-CYCLECLOUD-SIGNAL-1: a node of an Azure CycleCloud cluster. No
    # Azure record names its machines (CycleCloud is not a resource provider),
    # so the tags CycleCloud documents, in their documented format, decide
    # (CycleCloudDetection.ps1). Asked even of a scale set member, so the note
    # and the type name CycleCloud, not only the scale set.
    $cycleCloud = Test-VmfCycleCloudNode -Tags $Vm.tags
    if ($cycleCloud.IsNode) {
        $platformManaged = $true
        $notes.Add("machine is in an Azure CycleCloud cluster - $(Get-VmfCycleCloudEvidenceText -Verdict $cycleCloud) (the tags CycleCloud adds to each machine of a cluster). Change the size in the settings of the CycleCloud cluster.")
    }
    # REBUILD-MOVE-HOST-1 (2026-11-11): dedicated hosts were never tested and
    # are not part of 1.0 - a machine on an Azure Dedicated Host
    # is outside the scope of this tool. A host runs only the sizes of one size
    # series (Microsoft's Dedicated Hosts overview), so a move to another series
    # is not a resize on the same host. Either field decides: automatic
    # placement can leave the host out of the model and keep the host group.
    # Checking asks again (Get-VmfHostHibernationStop).
    $hostName = (& $vmField 'hostId') -split '/' | Select-Object -Last 1
    $hostGroupName = (& $vmField 'hostGroupId') -split '/' | Select-Object -Last 1
    if ($hostName -or $hostGroupName) {
        $platformManaged = $true
        $where = @(if ($hostName) { "on the dedicated host '$hostName'" }; if ($hostGroupName) { "in the host group '$hostGroupName'" }) -join ' '
        $notes.Add("Azure Dedicated Host - Azure places this machine $where. A machine on a dedicated host is outside the scope of this tool.")
    }
    # REBUILD-MOVE-HOST-1 (2026-11-11): the product moves no machine with
    # hibernation - a machine with hibernation enabled is outside the
    # scope of this tool. It replaces the note that Checking stops a
    # hibernated machine: Checking now stops every machine with hibernation
    # enabled (Get-VmfHostHibernationStop), and a machine can hibernate only
    # with it enabled (Microsoft's Hibernation overview, prerequisites).
    $hibernationEnabled = [bool]$Vm.hibernationEnabled
    if ($hibernationEnabled) {
        $platformManaged = $true
        $notes.Add('Hibernation - hibernation is enabled on this machine. A machine with hibernation enabled is outside the scope of this tool.')
    }
    # The AKS tag branch that stood here pending review is GONE - the review
    # happened (2026-08-28) and the provider's nodeResourceGroup
    # declaration above replaced it. No tag decides anything in this system,
    # with ONE exception where Azure has no record to read: the tags Azure
    # CycleCloud documents and writes on its own nodes, in their documented
    # format (BATCH-CYCLECLOUD-SIGNAL-1, above).
    # The shapes that appear as standalone VMs (the newer "Virtual Machines"
    # node pools, legacy availability-set pools) live in the node RG and are
    # caught there; Uniform-VMSS nodes never enter this inventory at all,
    # because Uniform instances are not Microsoft.Compute/virtualMachines
    # resources - a scope fact, not a gap.

    # --- Rule: SERVER OS ONLY (scope ruling 2026-08-28) ---
    # No Windows client OS is allowed in the product: this is a tool for
    # server OS types only. Not an AVD side-effect - a scope rule, which also
    # subsumes the earlier AVD ruling (nothing AVD is touched, in a pool or
    # not), since every AVD host runs a client OS. Two signals, neither a tag:
    #
    # 1. The IMAGE: publisher MicrosoftWindowsDesktop is the client-OS
    #    marketplace, including every AVD multi-session SKU (avd/evd - SKUs
    #    that exist only for AVD).
    # 2. The RUNNING OS, from the agent (instanceView.osName): catches a
    #    CUSTOM-image client machine no marketplace record would reveal.
    #    Empty when the machine is deallocated - that residual is blocked
    #    anyway: a custom image gets image-not-supported (IMAGE-1, DRIFT-12),
    #    except a machine already excluded as a client OS, which keeps only
    #    that reason (CLIENT-IMAGE-DATA-1) - it is excluded either way.
    $clientOsNote = $null
    if ([string]$Vm.imagePublisher -ieq 'MicrosoftWindowsDesktop') {
        $clientOsNote = if ([string]$Vm.imageSku -imatch 'avd|evd') {
            "built from an AVD multi-session image ($($Vm.imageSku)) - excluded even when not registered in a host pool"
        } else {
            "Windows client operating-system image ($($Vm.imageSku))"
        }
    }
    elseif ([string]$Vm.osName -imatch 'Windows (7|8|10|11)' -and [string]$Vm.osName -inotmatch 'Server') {
        $clientOsNote = "the machine reports it is running '$($Vm.osName)'"
    }
    if ($clientOsNote) {
        $platformManaged = $true
        $notes.Add("client operating system - $clientOsNote. The product migrates SERVER operating systems only.")
    }

    # --- Rule: network virtual appliances (WORKLOAD-1) ---
    # An NVA is a standalone VM the platform guard cannot see - no vmssId, no
    # platform relationship. The doc's pattern for them is parallel appliance
    # capacity + traffic shift, and the support model is the vendor's, so an
    # in-place conversion is never the right move. Judged from the IMAGE,
    # never a tag, against Microsoft's own MANA NVA policy list. NVA-PLAN-1:
    # the Marketplace purchase plan too, which Azure keeps on a machine made
    # from a gallery copy of the appliance image (plan.product is "the same
    # value as Offer under the imageReference element" - Microsoft's
    # Microsoft.Compute/virtualMachines reference).
    $planPublisher = & $vmField 'planPublisher'
    $planProduct = & $vmField 'planProduct'
    $nva = Test-VmfNvaImage -Publisher ([string]$Vm.imagePublisher) -Offer ([string]$Vm.imageOffer) `
        -PlanPublisher $planPublisher -PlanProduct $planProduct
    if ($nva.IsNva) {
        $blockers.Add('nva-requires-parallel-deployment')
        $notes.Add("Network virtual appliance - migrate it the vendor's way: deploy parallel appliance capacity on a supported size and shift traffic. ($($nva.Detail))")
    }

    # --- Rule: storage and backup appliances (DETECT-PATTERNS-1) ---
    # Microsoft's v6/v7 Plan page: treat machine-based storage appliances like
    # network virtual appliances. The vendor approves the size first
    # (2026-10-10), so the machine is outside the scope of this tool - WEKA
    # clients too (2026-10-20: the client depends on the network
    # adapter, which a v6 or v7 move changes). A blocker of its own, so the
    # machine is refused whatever the support list says of its image.
    # A machine on BOTH lists is refused ONCE, with the NVA reason:
    # NetApp is on Microsoft's NVA policy list as well as ours.
    $galleryField = 'imageReference.id'
    $galleryImageId = & $vmField 'communityGalleryImageId'
    if ($galleryImageId) { $galleryField = 'imageReference.communityGalleryImageId' }
    else {
        $galleryImageId = & $vmField 'sharedGalleryImageId'
        if ($galleryImageId) { $galleryField = 'imageReference.sharedGalleryImageId' }
        else { $galleryImageId = [string]$Vm.imageId }
    }
    $appliance = Test-VmfStorageAppliance -ImagePublisher ([string]$Vm.imagePublisher) -ImageOffer ([string]$Vm.imageOffer) `
        -PlanPublisher $planPublisher -PlanProduct $planProduct -GalleryImageId $galleryImageId -GalleryField $galleryField
    if (-not $nva.IsNva -and $appliance.IsAppliance) {
        $blockers.Add('storage-appliance-needs-vendor')
        $notes.Add("Storage or backup appliance - $($appliance.Vendor), found by its $($appliance.Sign)")
    }
    # The fourth way an appliance reaches Azure: an Azure managed application.
    # Its resource group is managed by a Microsoft.Solutions/applications
    # resource, and the vendor owns the machines in it. A managed application
    # gives no vendor list, so none is named; the plan, if any, is evidence.
    elseif (-not $nva.IsNva -and $groupOwnerKind -eq 'managed-application') {
        $blockers.Add('managed-application-needs-vendor')
        $notes.Add("Machine in an Azure managed application - the resource group is managed by $groupOwner")
    }
    # --- Rule: a Marketplace purchase plan (NO-PLAN-SCOPE-1) ---
    # Since 2026-11-03: any machine with a purchase plan is outside the scope
    # of the product - Ubuntu Pro, RHEL BYOS and SUSE -llc too, for 1.0, because
    # no edition with a plan was ever tested. An appliance or a machine in a
    # managed application keeps its own reason above: it says more.
    elseif (-not $nva.IsNva -and ($planEvidence = Get-VmfPurchasePlanEvidence -Plan @{ publisher = $planPublisher; product = $planProduct; name = (& $vmField 'planName') })) {
        $blockers.Add('purchase-plan-out-of-scope')
        $notes.Add("Marketplace purchase plan - $($planEvidence.Words). A machine with a purchase plan is outside the scope of this tool.")
    }

    # --- Rule: failover cluster nodes on a shared disk (DETECT-PATTERNS-1) ---
    # A data disk with maxShares above 1 is attached to more than one machine
    # at once. Stopping one node as if it were alone is not the product's move
    # (CLUSTER-MOVE-1, after 1.0). Proven on Azure: a separate lifecycle
    # planner tool's test put one disk with maxShares 2 on two machines.
    # A disk the scan could not read is UNKNOWN - never a refusal, never a pass.
    $sharedDisks = [System.Collections.Generic.List[object]]::new()
    $unreadDisks = [System.Collections.Generic.List[string]]::new()
    $dataDiskIds = @(@($(if ($Vm.PSObject.Properties['dataDisks']) { $Vm.dataDisks })) | Where-Object { $_ } | ForEach-Object {
            if ($_.PSObject.Properties['managedDisk'] -and $_.managedDisk) { [string]$_.managedDisk.id } } | Where-Object { $_ })
    foreach ($diskId in $dataDiskIds) {
        $key = $diskId.ToLowerInvariant()
        if ($null -eq $DiskShares -or -not $DiskShares.ContainsKey($key)) { $unreadDisks.Add($diskId); continue }
        if ([int]$DiskShares[$key] -gt 1) { $sharedDisks.Add(@{ id = $diskId; shares = [int]$DiskShares[$key] }) }
    }
    if ($sharedDisks.Count) {
        $blockers.Add('shared-disk-cluster-node')
        $notes.Add('Shared disk - ' + (@($sharedDisks | ForEach-Object { "$($_.id) has maxShares $($_.shares)" }) -join '; '))
    }

    # --- Rule: a Standard HDD OS disk (HDD-OS-1) ---
    # Microsoft retires Standard HDD as the type of an OS disk on 8 September
    # 2028, and then converts each one that is left to Standard SSD
    # (disks-hdd-os-retirement). The machine can still move, and the targets
    # step offers Standard SSD for the OS disk during the move - so a warning,
    # never a blocker. The type is the DISK's own, the field Microsoft's list
    # reads. A disk the scan could not read has no type: unknown is not a yes
    # and not a no, so it gives no warning and the targets step offers nothing.
    # HDD-OS-ASR-1: Microsoft keeps support for "Standard HDD OS disks created
    # by Azure Site Recovery". HDD-OS-ASR-PROBE-1 (probe, 2026-11-09): such a
    # disk carries the tag ASR-ReplicaDisk or ASR-FODisk, and nothing else
    # marks it - the disk a failover runs on has the source disk's own name.
    # The Site Recovery extension marks the machine Site Recovery REPLICATES,
    # whose OS disk the customer made and which IS retired, so it is not read.
    # A disk with the tag gets no warning; its type stays in the record, so
    # the targets step still offers Standard SSD. A tag is the customer's to
    # change, so the words of the warning keep the exception for a disk that
    # has lost it.
    $osDiskType = $null
    $osDiskId = & $vmField 'osDiskManagedId'
    if ($osDiskId -and $null -ne $DiskTypes -and $DiskTypes.ContainsKey($osDiskId.ToLowerInvariant())) {
        $osDiskType = [string]$DiskTypes[$osDiskId.ToLowerInvariant()]
    }
    $osDiskBySiteRecovery = [bool]($osDiskId -and $null -ne $SiteRecoveryDisks -and $SiteRecoveryDisks.ContainsKey($osDiskId.ToLowerInvariant()))
    if ($osDiskType -eq 'Standard_LRS' -and -not $osDiskBySiteRecovery) { $warnings.Add('os-disk-standard-hdd') }

    # --- Rule: SQL Server (DETECT-PATTERNS-1) ---
    # The SQL IaaS Agent writes a Microsoft.SqlVirtualMachine/sqlVirtualMachines
    # record that points to the machine (proven on Azure by the planner's test
    # build). With sqlVirtualMachineGroupResourceId set, the machine is in an
    # Always On availability group (from Microsoft's documentation only: the
    # test needs a domain) - refused, outside the scope of this tool. On its
    # own, a SQL Server machine may move, and the downtime is agreed with the
    # database owner - a warning. Without the agent there is no record, and
    # only a SQL Server image tells.
    $sqlRecord = $null
    if ($null -ne $SqlVms) { $sqlRecord = if ($SqlVms.ContainsKey($vmKey)) { $SqlVms[$vmKey] } else { '' } }
    $sqlImage = [string]$Vm.imagePublisher -eq 'MicrosoftSQLServer'
    if ($sqlRecord -and $sqlRecord.groupId) {
        $blockers.Add('sql-availability-group-member')
        $notes.Add("SQL Server Always On availability group member - $($sqlRecord.groupId)")
    }
    elseif ($sqlRecord -or $sqlImage) {
        $warnings.Add('sql-server-agree-downtime')
    }

    # --- Rule: a hint that the machine may be a cluster node (CLUSTER-DETECT-1) ---
    # A cluster node that Azure has no record of: a load balancer backend
    # pool, more than one IP configuration, the SQL IaaS Agent extension. A
    # WARNING that a person confirms, never a blocker (a web server behind a
    # load balancer fires one too). Checking reads inside the machine before it
    # moves and stops a cluster node there. A machine the scan already blocks
    # as a cluster node needs no hint.
    $clusterHints = Get-VmfClusterHintFacts -Vm $Vm -NicClusterHints $NicClusterHints -SqlAgentVms $SqlAgentVms
    if (@($clusterHints.Fired).Count -and -not ($blockers.Contains('shared-disk-cluster-node') -or $blockers.Contains('sql-availability-group-member'))) {
        $warnings.Add('cluster-node-confirm')
    }

    # --- Rule: Azure Disk Encryption (ADE-2) ---
    # Microsoft, 2026-07-24: Azure Disk Encryption is NOT AVAILABLE on the v6
    # or v7 series, for either operating system, and it retires on 2028-09-15.
    # Its replacement is encryption at host - which cannot be enabled on a
    # machine that HAS EVER HAD Azure Disk Encryption. That restriction
    # survives decryption, snapshots and disk copies, so "decrypt it first" is
    # not a remediation. The supported path is new disks and a new machine.
    #
    # TRUE is an answer here; FALSE IS NOT. Azure records this per disk and the
    # inventory reads the OS disk only, so a machine encrypted on its data
    # disks alone reads false. The engine's extension check before the wave is
    # what covers that, and it stays. This rule only moves the DISCOVERY of the
    # obvious case from the middle of a migration to the scan.
    if ([string]$Vm.adeOsDiskEnabled -eq 'true') {
        $blockers.Add('disk-encryption-present')
    }

    # --- Rule: SAP workloads (SAP-1) ---
    # Microsoft, 24 July 2026, ABOVE the readiness checklist: "Only sizes on
    # the SAP-certified list are supported, regardless of platform readiness.
    # Treat certification as a gate that comes before all other planning, not
    # as a validation item."
    #
    # That list is SAP Note 1928533, behind an SAP Service Marketplace login.
    # This product cannot fetch it, ship it or keep it current, so it can never
    # say whether a target size is certified. The ruling, 2026-09-19: block
    # it, the way a network virtual appliance is blocked. There is no
    # acceptance - the certification is SAP's to give, not an operator's.
    #
    # THREE SIGNALS, AND NOT ONE OF THEM CAN FIRE ON A NORMAL MACHINE. Each is
    # a positive assertion that SAP is here, never a statement about an
    # operating system:
    #   - the Azure VM extension for SAP solutions is installed on it
    #   - its Azure licence type puts it on SAP repositories
    #   - it was built from an SAP marketplace image
    #
    # A fourth - Azure's SAP provider naming the machine - was dropped by
    # SAP-2 for what it cost to ask: the parent read returns the deployment's
    # osProfile. None of these three needs any permission the scan does not
    # already hold.
    # The reason NAMES the signal that fired, so the answer is checkable.
    $sapWhy = $null
    if ($null -ne $SapSystemVms) { $sapWhy = $SapSystemVms[([string]$Vm.id).ToLowerInvariant()] }
    if (-not $sapWhy) {
        $sapLicense = Test-VmfSapLicense -LicenseType ([string]$Vm.licenseType)
        if ($sapLicense.IsSap) { $sapWhy = $sapLicense.Detail }
    }
    if (-not $sapWhy) {
        $sapImage = Test-VmfSapImage -Publisher ([string]$Vm.imagePublisher) -Offer ([string]$Vm.imageOffer)
        if ($sapImage.IsSap) { $sapWhy = $sapImage.Detail }
    }
    if ($sapWhy) {
        $blockers.Add('sap-needs-a-certified-size')
        $notes.Add("SAP workload - $sapWhy")
    }

    # --- The workload type, and its evidence (DETECT-PATTERNS-1) ---
    # Each fact is $null when it was not read, '' when it was read and absent.
    $platformFact = $null
    if ($null -ne $ManagedPlatformGroups -and ([string]$Vm.id -match '(?i)^/subscriptions/([^/]+)/')) {
        $pk = "$($Matches[1])/$($Vm.resourceGroup)".ToLowerInvariant()
        $platformFact = if ($ManagedPlatformGroups.ContainsKey($pk)) { [string]$ManagedPlatformGroups[$pk] } else { '' }
    }
    $avdFact = $null
    if ($null -ne $AvdSessionHosts) { $avdFact = if ($AvdSessionHosts.ContainsKey($vmKey)) { [string]$AvdSessionHosts[$vmKey] } else { '' } }
    $poolTypeFact = if ($null -ne $AvdPoolTypes -and $AvdPoolTypes.ContainsKey($vmKey)) { [string]$AvdPoolTypes[$vmKey] } else { '' }
    $sapFact = if ($sapWhy) { $sapWhy } elseif ($null -ne $SapSystemVms) { '' } else { $null }
    $workload = Get-VmfWorkloadType -Facts @{
        Nva = @{ IsNva = [bool]$nva.IsNva; Evidence = @($nva.Evidence) }
        Appliance = $appliance; GroupOwner = $groupOwner; Platform = $platformFact; CycleCloud = $cycleCloud
        VmssId = [string]$Vm.vmssId; AvdPool = $avdFact; AvdPoolType = $poolTypeFact
        Sql = $sqlRecord; ImagePublisher = [string]$Vm.imagePublisher
        SharedDisks = @($sharedDisks); UnreadDisks = @($unreadDisks); Sap = $sapFact
        ClusterHints = @($clusterHints.Fired); UnreadHints = @($clusterHints.Unread)
    }
    # Unknown is never a pass: the machine may move, and a person checks first.
    if ($workload.type -eq 'not-checked') { $warnings.Add('workload-type-not-checked') }

    # --- Rule: security model (TRUST-1) ---
    # Trusted Launch flows through: the capture carries it and the rebuild
    # reapplies it. Confidential VMs do not - their disks and their attestation
    # are a different machinery the product does not reproduce, and a rebuild
    # that dropped it would be a silent security downgrade. Blocked with the
    # reason named, like ADE.
    # CONF-1, answered against the guidance 2026-08-30. The block was right and
    # its stated reason was secondary. The primary reason is that there is
    # NOWHERE TO GO: the migration overview's target-families table lists only
    # Boost families (Dlsv6/Dsv6/Esv6, Dalsv6/Dasv6/Easv6, and the v7
    # equivalents), and no confidential family appears in it.
    #
    # RE-CHECKED 2026-09-01 against the confidential-computing docs, and one
    # clause of the original reasoning was OVERSTATED - corrected here rather
    # than left standing because it was true of one size and asserted of all:
    #
    #   - confidential families DO exist on v6: DCasv6/DCesv6 and DCadsv6/DCedsv6,
    #     ECasv6/ECesv6 and ECadsv6/ECedsv6. There is NO v7 confidential family.
    #   - the 'd' variants DO have local NVMe temp disks - the DCadsv6 page lists
    #     "Temporary local NVMe disks: Supported" and 75-3,600 GiB of local
    #     storage. The earlier note said confidential v6 has "no local disk and
    #     no NVMe controller"; that was true of DCasv6 (no 'd' = no local disk)
    #     and wrong as a general claim.
    #   - what the DCadsv6 page does NOT state is a DISK CONTROLLER TYPE at all.
    #     That is silence, and silence is not a "no" any more than it is a "yes"
    #     (the IMAGE-1 rule). We do not claim it cannot do NVMe; we claim it is
    #     not a target the product maps to.
    #
    # What DOES settle it, and needs none of that:
    #   - no confidential family is in the migration guidance's target table;
    #   - the scope is D and E series (2026-08-29). DC and EC are neither,
    #     so DCasv5 -> DCasv6 is a different transform, not this one;
    #   - ACCELERATED NETWORKING IS "Not Supported" on confidential VMs outright,
    #     so the AN handling this engine performs has no meaning on one;
    #   - "Confidential OS disk encryption setting can't be changed after VM
    #     deployment", and Azure Site Recovery and live migration are both
    #     unsupported - this is machinery a controller swap must not walk into.
    #
    # So the refusal stands, on stronger ground than before. A CVM's upgrade path
    # is DCasv5 -> DCasv6, which is a resize within the confidential families and
    # involves no SCSI-to-NVMe conversion the product would perform.
    # Sources: learn.microsoft.com/azure/confidential-computing/confidential-vm-overview
    #          learn.microsoft.com/azure/virtual-machines/sizes/general-purpose/dcadsv6-series
    if ([string]$Vm.securityType -eq 'ConfidentialVM') {
        $blockers.Add('confidential-vm-requires-manual')
        $notes.Add('Confidential VM - the migration guidance lists no confidential family among its v6/v7 targets, and the product covers the D and E series. Confidential machines also do not support accelerated networking at all, and their OS disk encryption cannot be changed after deployment. Its upgrade path is a resize within the confidential families (DCasv5 to DCasv6), which is a different move the product does not make')
    }

    # --- Rule: families the product does not move (OLD-FAM-3) ---
    # Each code written out, so the reasons test can see what the rules emit.
    switch (Get-VmfUnsupportedFamilyCode -SizeName ([string]$Vm.sku)) {
        'hpc-or-fpga-size' { $blockers.Add('hpc-or-fpga-size') }
        'local-nvme-storage-size' { $blockers.Add('local-nvme-storage-size') }
        'l-series-replacement' { $blockers.Add('l-series-replacement') }
        'gpu-size' { $blockers.Add('gpu-size') }
    }

    # --- Rule: more data disks than the product moves (DISKS-32-1) ---
    # A scope decision, 2026-10-05: at most 32. The count is the data disk
    # list Resource Graph gives (storageProfile.dataDisks), so the operating
    # system disk is never in it.
    if (Test-VmfTooManyDataDisks -Count $Vm.dataDiskCount) {
        $blockers.Add('too-many-data-disks')
    }

    # --- Rule: a size Microsoft has retired (OLD-FAM-4, RETIRE-SCOPE-1) ---
    # After its retirement date a size cannot run: Microsoft deallocates every
    # machine on it. A v1 (Basic and Standard A-series) retired on 2024-08-31
    # and Azure no longer lists it, so the scan called it "not in this region".
    # Read from the retirement data, so each later family gets the same answer.
    # RETIRE-SCOPE-1 (2026-10-04): from ONE DAY before the date a
    # machine on that size is outside the scope of this tool - a rollback
    # started the evening before must not reach the old size after midnight.
    # The same line the advice, the plan, PRECHECK, the restore and the rebuild
    # draw (Test-VmfSizeRetiredForTool), so the product gives one answer.
    if (Test-VmfSizeRetiredForTool -Size ([string]$Vm.sku) -Now $Now) {
        $blockers.Add('size-retired')
        $notes.Add((Get-VmfRetiresWords -Size ([string]$Vm.sku) -Now $Now))
    }

    # --- Rule: generation ---
    $gen = if ($Vm.gen -match 'V?2') { 'V2' } elseif ($Vm.gen -match 'V?1') { 'V1' } else { $null }
    if ($gen -eq 'V1') { $blockers.Add('gen1-requires-redeploy') }
    elseif ($null -eq $gen) { $prep.Add('verify-generation'); $notes.Add('generation unknown (Azure reported none)') }

    # --- Rule: Windows version floor (WS2019+) for NVMe ---
    $winVer = $null
    if ($Vm.os -eq 'Windows') {
        # OSVER-1: the RUNNING version decides - the VM agent's osName - and
        # the image only when the machine reported none (deallocated, or no
        # agent). A machine upgraded in place from 2016 stayed held back.
        $winVer = Get-VmfWindowsServerYear -OsName ([string]$Vm.osName) -ImagePublisher ([string]$Vm.imagePublisher) `
            -ImageOffer ([string]$Vm.imageOffer) -ImageSku ([string]$Vm.imageSku)
        $verDigits = $winVer.Year
        if ($winVer.Note) { $notes.Add($winVer.Note) }
        if ($verDigits -and [int]$verDigits -lt 2019) { $blockers.Add('windows-version-below-2019') }
        # GEN-V5-1, ruled 2026-09-26: below 2016 ships PowerShell 4.0
        # or older, and the guest steps have run only on 5.1. v5 has no NVMe
        # reason to refuse it, so this is the reason it is held there until
        # a lab run proves the steps. It applies to v5 only.
        if ($verDigits -and [int]$verDigits -lt 2016) { $blockers.Add('windows-version-not-proven') }
        if ([string]::IsNullOrWhiteSpace($Vm.imagePublisher)) {
            $prep.Add('verify-custom-image-nvme-ready')
        }
        $prep.Add('stornvme')
        if ($Vm.diskController -ne 'NVMe') { $notes.Add('Windows guest prep required before conversion') }
    }
    else {
        $prep.Add('linux-nvme-prep')
        # DRIVER-WARN-1: say that the kernel gets checked, before the day it
        # is. A lab run met this mid-migration - safety copy taken, guest
        # already prepared - and the assessment had said NOTHING about it.
        #
        # It cannot be DECIDED here: the kernel is read from inside the
        # machine (mana-check.sh), and the assessment reads ARM. So this
        # announces the check rather than performing it - unknown read as
        # neither a yes nor a no.
        #
        # EVERY Linux machine, matching the gate that exists.
        # Get-VmfDriverJudgement judges the MANA floor for any non-Windows
        # machine heading to an NVMe target, whatever its accelerated
        # networking state. An item scoped narrower than the gate would let
        # exactly the machine that gets parked through.
        $prep.Add('mana-kernel-floor')
    }

    # --- Rule: IMAGE-1 - only images the product can vouch for ---
    # Anything not positively recognised is BLOCKED. The product moves other
    # people's production machines; an unrecognised image is not "probably
    # fine". Nothing overrides it (DRIFT-12, 2026-11-12): the reason
    # says the fact and that the product does not move the machine.
    $imageSupport = Get-VmfImageSupport -Publisher ([string]$Vm.imagePublisher) `
        -Offer ([string]$Vm.imageOffer) -Sku ([string]$Vm.imageSku) `
        -ImageId ([string]$Vm.imageId)
    # CLIENT-IMAGE-DATA-1: a client image (MicrosoftWindowsDesktop) is on the
    # list as unsupported, so the list agrees with the client rule above. That
    # rule already excluded the machine and said why; a second reason for the
    # same fact would count it twice in the report's blocker groups.
    if (-not $imageSupport.Supported -and -not $clientOsNote) {
        $blockers.Add('image-not-supported')
        if ($imageSupport.Reason) { $notes.Add($imageSupport.Reason) }
    }

    # --- Rule: Linux release on Microsoft's NVMe list (IMAGE-SCRIPT-MATCH-1) ---
    # The Linux half of enable-nvme-interface, as windows-version-below-2019
    # is the Windows half: a release the page does not list gets no v6 or v7
    # target (appliesTo), and keeps v5. Unknown is a warning, never a pass and
    # never a fail. A machine the support list refuses moves on no series, so
    # it gets neither.
    if ([string]$Vm.os -match '^(?i)linux$' -and $imageSupport.Supported) {
        $nvmeLinux = Get-VmfLinuxNvmeJudgement -Vm $Vm
        if ($nvmeLinux.Listing -eq 'unlisted') { $blockers.Add('linux-release-not-on-nvme-list') }
        if ($nvmeLinux.Listing -eq 'unknown') { $warnings.Add('linux-release-nvme-not-read') }
        if ($nvmeLinux.Note) { $notes.Add($nvmeLinux.Note) }
        # EOL-RELEASE-AN-1: the vendor's end of standard support, as a fact.
        # Never a blocker: Checking stops the machine for an approver
        # (linuxReleaseEndOfLife), and the vendors sell extended support.
        $releaseEol = Get-VmfLinuxReleaseEol -Release $nvmeLinux.Release -Now $Now
        if ($releaseEol.Status -eq 'past') { $warnings.Add('linux-release-past-standard-support'); $notes.Add($releaseEol.Text) }
        if ($releaseEol.Status -eq 'unknown') { $warnings.Add('linux-release-end-of-support-not-known') }
    }
    # Azure's own answer about the image. Only a definite NO blocks: silence
    # is not evidence.
    if ($false -eq $ImageNvmeSupported) {
        # OSVER-1, as GEN1-IMAGE-1 does for generation: Azure's answer is
        # about the IMAGE, and its record never changes after an in-place
        # upgrade of Windows (Microsoft: the source image information
        # "remains unchanged"). A machine that RUNS Windows Server 2019 or
        # later, made from an older Windows Server image, can use NVMe; the
        # move gives its OS disk the NVMe capability, as for every machine.
        # Only that case - the version it runs 2019 or later, its image's
        # version known and older (which means the running one was read: an
        # image-only reading gives both the same year). Anything unknown
        # still blocks.
        $upgradedPastImage = $Vm.os -eq 'Windows' -and $winVer -and
            [int]$winVer.Year -ge 2019 -and $winVer.ImageYear -and [int]$winVer.ImageYear -lt 2019
        if ($upgradedPastImage) {
            $notes.Add("Azure reports that this machine's image, Windows Server $($winVer.ImageYear), cannot use NVMe disks. The machine now runs Windows Server $($winVer.Year), which can. The version it runs is the one judged.")
        }
        else {
            $blockers.Add('image-cannot-boot-nvme')
            $notes.Add('Azure reports this OS image does not support the NVMe disk type, so the machine would not start after the move.')
        }
    }    if ($ImageNvmeNote) { $notes.Add($ImageNvmeNote) }

    # --- Rule: source disk architecture (SKU API authoritative; name fallback) ---
    $maxResourceMb = $null
    if ($SkuEntry) {
        $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'MaxResourceVolumeMB' } | Select-Object -First 1
        if ($cap) { $maxResourceMb = [int64]$cap.Value }
    }
    elseif ($SizesNotRead) {
        # SCAN-PARTIAL-SUBS-1: unknown is never a yes or a no. The name rule
        # below still fills the fields, and the blocker holds the machine, so
        # no plan is made from them.
        $blockers.Add('sizes-not-read')
        $notes.Add('The scan could not read the sizes Azure offers in the subscription and region of this machine.')
    }
    else { $notes.Add('current size not in SKU catalog - name-based disk-arch detection only') }
    $sourceDiskArch = Get-VmfDiskArchitecture -SizeName $Vm.sku -MaxResourceVolumeMB $maxResourceMb
    # TEMPPOOL-1: how many temporary drives it has TODAY. The target's count is
    # a plan-time fact (the target size is chosen there), so the pair is only
    # complete once planned - but this half is a fact about the machine and
    # belongs with the other facts about it.
    $sourceTempDisks = Get-VmfTempDiskCount -SkuEntry $SkuEntry -SizeName $Vm.sku
    # DAV4-TEMPDISK-1 (independent review): a series whose replacement row
    # says every size has a temporary disk (v3, and the AMD v4 series, whose
    # names have no d) is not diskless because the catalog gave no reading.
    # The planner already chose the d size from that row; the path and the
    # engine's page file move read THIS record, so without the same fact a
    # Windows machine on the size without a temporary disk was planned in
    # place - a resize Azure refuses across disk categories, with the machine
    # stopped. A reading in the catalog always wins. V4-NAMES-1: Ddv4 and
    # Edv4 rows say the same (one temporary disk on every size); Dv4 and Ev4
    # rows say false, so the name rule stands for them. V5-NAMES-1: the
    # same for Ddv5 and Edv5 (true) and Dv5 and Ev5 (false).
    if ($null -eq $maxResourceMb) {
        $row = Get-VmfSizeReplacement -SizeName ([string]$Vm.sku)
        if ($row -and $row.everySizeHasTemporaryDisk -eq $true) {
            $sourceDiskArch = 'scsi-temp'
            $sourceTempDisks = 1
            $notes.Add('Azure did not report the temporary disk of this size. Microsoft says that every size of this series has one temporary disk, so the assessment records one.')
        }
    }
    if ($Vm.os -eq 'Windows' -and $sourceDiskArch -eq 'scsi-temp') { $prep.Add('pagefile') }
    # IDENTITY-UX-1: a Windows machine on a size with a SCSI temp disk is
    # REBUILT on every v6/v7 target (Azure refuses the resize: "resource disk
    # to non-resource disk ... not allowed"; docs/research/v6-rebuild-
    # alternatives.md), and a rebuild gives it a NEW system-assigned
    # identity. Said here, at the first screen, not at PRECHECK.
    # IDENTITY-LOSS-1: a WARNING, not preparation. The prep list says "these
    # are handled for you; nothing here needs doing first", and this is the
    # one finding a person must decide on before the wave runs.
    # REBUILD-REMOVE-PLAN-1 (2026-11-07): no move rebuilds a machine, so
    # no move deletes its system-assigned identity, and the scan no longer gives
    # system-identity-recreated (its reason is gone from assessment-reasons.json
    # too). The identity is still recorded, for the run report.
    $identityType = if ($Vm.PSObject.Properties['identityType']) { [string]$Vm.identityType } else { '' }

    # IAC-2 (directed 2026-08-27): the assessment no longer guesses whether
    # a machine is managed by infrastructure-as-code. It used to match a handful
    # of tag keys against terraform/tf/opentofu, which could not tell Terraform
    # from Bicep, Pulumi, ARM or Ansible, and read a differently-tagged Terraform
    # estate as unmanaged - then wired that guess to a lever that could stop a
    # migration. The rule: no tag dependencies in this system at all.
    #
    # The concern is unchanged and real - migrating an IaC-managed machine
    # changes properties the definitions do not know about - but it is handled
    # by TELLING the customer and having them acknowledge it once for the run,
    # not by us pretending to detect it per machine.

    # --- Rule: ASSESS-2(a) unmanaged (blob VHD) OS disk -------------------
    # The product works on MANAGED disks throughout - snapshots, capability
    # patches, the capture, the recreate. A machine still on a blob VHD cannot
    # be migrated by it at all, and today it gets as far as PRECHECK before
    # failing on a capture that assumes a managed disk. Saying so in the report
    # turns a confusing mid-run failure into a plain answer at the start.
    $hasManagedOsDisk = [bool]([string]$Vm.osDiskManagedId)
    $hasVhdUri = [bool]([string]$Vm.osDiskVhdUri)
    if ($hasVhdUri -and -not $hasManagedOsDisk) {
        $blockers.Add('unmanaged-os-disk')
        $notes.Add('OS disk is an unmanaged page blob (VHD) - convert it to a managed disk first; every step of this migration works on managed disks')
    }

    # --- Rule: ephemeral OS disk (EPHEMERAL-1) -----------------------------
    # THE OTHER MACHINE WITH NO MANAGED OS DISK. The rule above was written for
    # the blob-VHD case and its comment describes the whole class - "every step
    # of this migration works on managed disks" - but it only ever fired on a
    # VHD uri. An EPHEMERAL OS disk has neither: the disk lives on the host, so
    # there is no disk resource, no uri, and nothing to snapshot or re-attach.
    #
    # Found 2026-09-19 by comparing this query against Microsoft's published
    # one, which carries the same column. Until now such a machine was assessed
    # as migratable, entered a wave, and failed at its FIRST SAFETY COPY on a
    # null disk id - a confusing error naming nothing about ephemeral disks.
    # The machine was untouched, which is why nobody had met it yet.
    #
    # 'Local' is the only value that means ephemeral. Anything else, including
    # empty, is an ordinary OS disk - this must never fire on a normal machine.
    if ([string]$Vm.osDiskDiffOption -eq 'Local') {
        $blockers.Add('ephemeral-os-disk')
        $notes.Add('The operating system disk is ephemeral - it lives on the host and is empty again every time the machine stops')
    }

    # --- Rule: AN-1 accelerated networking, as a FACT ----------------------
    # Recorded, never judged here: whether an AN layout FITS depends on the
    # target size, which is a planning decision (NIC-1 - Azure caps AN by VM
    # size, not per NIC). The assessment's job is to say what is there, early
    # enough to matter.
    $acceleratedNicCount = $null
    # AN-PRIMARY-1: and the PRIMARY interface's setting, which is what the
    # engine judges (Get-VmfPrimaryNic: the interface Azure flags primary, else
    # the first). A count cannot say it for several interfaces with some on.
    # Not read, or the primary not readable: unknown - never off.
    $primaryNicAccelerated = $null
    if ($null -ne $NicAcceleratedMap) {
        $nicList = @($Vm.nicIds | Where-Object { $_ })
        $flagged = @($nicList | Where-Object {
                $_.PSObject.Properties['properties'] -and $_.properties -and
                $_.properties.PSObject.Properties['primary'] -and [bool]$_.properties.primary }) | Select-Object -First 1
        $primaryNic = if ($flagged) { $flagged } elseif ($nicList.Count) { $nicList[0] } else { $null }
        if ($primaryNic) {
            $primaryNicId = ([string]$primaryNic.id).ToLowerInvariant()
            if ($primaryNicId -and $NicAcceleratedMap.ContainsKey($primaryNicId)) {
                $primaryNicAccelerated = [bool]$NicAcceleratedMap[$primaryNicId]
            }
        }
    }
    if ($null -ne $NicAcceleratedMap) {
        $known = 0; $on = 0
        foreach ($nic in @($Vm.nicIds)) {
            $nid = ([string]$nic.id).ToLowerInvariant()
            if ($nid -and $NicAcceleratedMap.ContainsKey($nid)) {
                $known++
                if ($NicAcceleratedMap[$nid]) { $on++ }
            }
        }
        # Unknown stays unknown. A machine whose interfaces we could not read
        # must not be reported as having none switched on.
        if ($known -gt 0) {
            $acceleratedNicCount = $on
            if ($on -gt 0) {
                $notes.Add("accelerated networking is on $on of $known network interface(s) - a v6 target permits it on the primary interface only, and the size decides how many it allows at all")
            }
        }
    }

    # ADE is checked live at PRECHECK (extension query is per-VM); note it.
    $notes.Add('ADE checked live at PRECHECK (dual-OS)')

    # --- App-group tag (flows through to the planner) ---
    # IAC-2 follow-on: the RING tag is gone. Reading a tag to
    # GROUP machines is an option the customer picks; reading one to decide how
    # the product TREATS a machine is not, and the ring tag did the latter - it
    # selected a whole policy set, and silently ignored any value that was not
    # one of our four invented words, so a customer tagging env=production got
    # the default and was never told why. The ring now comes from the explicit
    # choice made at planning time.
    $appGroup = $null
    if ($Vm.tags) {
        $appProp = $Vm.tags.PSObject.Properties[$AppGroupTag]
        if ($appProp -and $appProp.Value) { $appGroup = [string]$appProp.Value }
    }

    # --- Classification ---
    $classification =
        if ($platformManaged) { 'Excluded' }
        elseif ($blockers.Count -gt 0) { 'Blocked' }
        else { 'ReadyAfterPrep' }
    # READY-NOW-REMOVE-1 (assessment v11, 2026-11-06): no ReadyNow. It
    # went to every machine on NVMe and read "Already migrated", so a machine
    # on Ebsv5 or Ebdsv5 (Extended; the Eb family also lists Ebsv6 and Ebdsv6,
    # which no Microsoft page calls their replacement - EB-COMMENT-1) was
    # offered no move. A
    # machine on NVMe is assessed like any other; a machine on a Current size
    # is shown as Current (sourceLifecycle), and the plan gives it no move to
    # an NVMe series (Test-VmfAlreadyOnNvmeTarget).

    # MANA-WIN-3: say before the wave that the move can download the MANA
    # driver from download.microsoft.com (MANA-WIN-1, GUEST_PREP). The scan
    # reads ARM, never the driver store, so it cannot tell which machines need
    # it - every Windows machine that can move to at least one size series is
    # told. Not an excluded machine, and not one that every series blocks:
    # neither moves, so there is nothing to check (review). The open series
    # are read by the one rule the plan and the pages use
    # (Resolve-VmfEntryClassification, appliesTo). A warning: the machine may
    # still move. The plan names the exact machines (Get-VmfManaDriverDownloadNote).
    if ($Vm.os -eq 'Windows') {
        $asScanned = [pscustomobject]@{ classification = $classification; platformManaged = $platformManaged
            diskController = [string]$Vm.diskController; blockers = @($blockers); prepNeeded = @($prep) }
        $openSeries = @('v5', 'v6', 'v7' | Where-Object {
                (Resolve-VmfEntryClassification -Assessment $asScanned -TargetGeneration $_).Classification -notin @('Blocked', 'Excluded') })
        if ($openSeries.Count) { $warnings.Add('mana-driver-download') }
    }

    $record = [pscustomobject]@{
        vmId               = $Vm.id
        name               = $Vm.name
        resourceGroup      = $Vm.resourceGroup
        location           = $Vm.location
        # A machine outside availability zones comes back from Resource Graph
        # with zones = null, and @($null) is a list holding one null - which
        # every real scan wrote as "zones": [null], against the schema.
        # Found by AN-PRIMARY-1's contract test; the engine reads both as none.
        zones              = @(@($Vm.zones) | Where-Object { $_ })
        classification     = $classification
        gen                = $gen
        os                 = [string]$Vm.os
        osVersion          = [string]$Vm.imageSku
        # ADVISE-AN-1 (assessment v3): the operating system the VM agent
        # reports as RUNNING - for Linux its distribution and release, which
        # the target advice sets against Microsoft's MANA table. Empty when the
        # machine was deallocated or has no agent; never read as a release.
        runningOsName      = $(if ($Vm.PSObject.Properties['osName']) { [string]$Vm.osName } else { '' })
        runningOsVersion   = $(if ($Vm.PSObject.Properties['osVersionRunning']) { [string]$Vm.osVersionRunning } else { '' })
        imagePublisher     = [string]$Vm.imagePublisher
        imageOffer         = [string]$Vm.imageOffer
        imageId            = [string]$Vm.imageId
        # DETECT-PATTERNS-1 (assessment v4): the Marketplace purchase plan and
        # the gallery image the machine was made from - two of the four ways a
        # vendor appliance reaches Azure. '' when Azure records none.
        planPublisher      = $planPublisher
        planProduct        = $planProduct
        galleryImageId     = $(if ($galleryField -eq 'imageReference.id') { '' } else { $galleryImageId })
        imageSupport       = [string]$imageSupport.Status
        sourceSize         = $Vm.sku
        # ALREADY-CURRENT-1 (assessment v10): Microsoft's lifecycle stage of
        # the size the machine is on NOW, from the lifecycle data
        # (Get-VmfSizeLifecycleStage, by Get-VmfAdviceStage) - never from the
        # name on a page. The pages show a machine on a Current size as
        # Current, not as a machine that cannot move. $null when the data
        # holds no stage for the size.
        sourceLifecycle    = Get-VmfAdviceStage -SizeName ([string]$Vm.sku)
        sourceDiskArch     = $sourceDiskArch
        # $null means the catalog could not say - never read it as "none".
        sourceTempDisks    = $sourceTempDisks
        diskController     = [string]$Vm.diskController
        securityType       = [string]$Vm.securityType
        dataDiskCount      = [int]$Vm.dataDiskCount
        # NIC-1: multi-NIC machines need a target size that can hold them all.
        # An assessment written before NIC-1 has no count; 1 is the safe read
        # (it gates nothing) rather than a crash.
        nicCount           = $(if ($Vm.PSObject.Properties['nicCount'] -and [int]$Vm.nicCount -gt 0) { [int]$Vm.nicCount } else { 1 })
        acceleratedNicCount = $acceleratedNicCount
        primaryNicAccelerated = $primaryNicAccelerated
        hasManagedOsDisk   = $hasManagedOsDisk
        # HDD-OS-1 (assessment v5): the OS disk's type, as Azure names it
        # (Standard_LRS is Standard HDD). Null when the scan could not read it.
        osDiskType         = $osDiskType
        availabilitySetId  = [string]$Vm.availabilitySetId
        appGroup           = $appGroup
        platformManaged    = $platformManaged
        hibernationEnabled = $hibernationEnabled
        # IDENTITY-UX-1: 'None', 'SystemAssigned', 'UserAssigned' or
        # 'SystemAssigned, UserAssigned' - Azure's own words; '' when the
        # discovery row predates this field.
        identityType       = $identityType
        identityPrincipalId = $(if ($Vm.PSObject.Properties['identityPrincipalId']) { [string]$Vm.identityPrincipalId } else { '' })
        # REBUILD-REMOVE-SCAN-EXT-1 (assessment v15): no rebuildLinks. It
        # listed what a rebuild deleted with the VM, for the acceptance of a
        # rebuild; the rebuild and its acceptance are gone.
        # WAVE-1: the machine's own tags travel with the record so a person
        # composing waves can group by ANY tag they actually use - the two
        # convention keys below are only defaults, not the whole story.
        tags               = $(if ($Vm.tags) { ConvertTo-VmfTagTable -Tags $Vm.tags } else { @{} })
        blockers           = @($blockers)
        # DETECT-PATTERNS-1 (assessment v4): the workload type and the Azure
        # fields that decided it; and what a person checks before the move.
        workload           = $workload
        warnings           = @($warnings)
        prepNeeded         = @($prep)
        notes              = @($notes)
    }
    # CRG-MOVE-DEMAND-1 (assessment v13): the capacity reservation group the
    # machine is in, Azure's resource id; $null for none. Written only when
    # the discovery row says - a row without the field is unknown, never "in
    # no group", and the plan entry then does not say either.
    if ($Vm.PSObject.Properties['capacityReservationGroupId']) {
        $groupNow = [string]$Vm.capacityReservationGroupId
        $record | Add-Member -NotePropertyName capacityReservationGroupId -NotePropertyValue $(if ($groupNow) { $groupNow } else { $null })
    }
    # TARGET-CAPABILITY-PRECHECK-1 (assessment v17): encryption at host and
    # Ultra Disk compatibility, so the target advice offers no size that does
    # not support one the machine uses. Resource Graph gives null for a
    # property Azure leaves out because it is not set, which is off. Written
    # only when the discovery row has the column - a row without it is
    # unknown, never "off".
    foreach ($feature in 'encryptionAtHost', 'ultraSsdEnabled') {
        if ($Vm.PSObject.Properties[$feature]) {
            $record | Add-Member -NotePropertyName $feature -NotePropertyValue ($Vm.$feature -eq $true)
        }
    }
    $record
}
