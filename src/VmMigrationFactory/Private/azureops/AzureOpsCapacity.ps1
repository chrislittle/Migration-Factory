# azureops: On-Demand Capacity Reservation lifecycle (architecture section 10).
# ODCRs bill at VM rate from creation - create late, release promptly.

function Get-VmfAzContextForSubscription {
    <#
    .SYNOPSIS
        An Azure context pinned to one subscription, for -DefaultProfile.
    .DESCRIPTION
        ODCR-SUB-1. Capacity is per-subscription: quota is a subscription
        limit, and a capacity reservation group can only be used by VMs in its
        own subscription. Every capacity call was made against the AMBIENT
        context - whichever subscription the operator was signed in to - so a
        wave spanning subscriptions verified the wrong quota and reserved in
        the wrong place.

        Uses -DefaultProfile rather than Set-AzContext deliberately: the engine
        runs one worker per machine and mutating a global context from several
        of them at once is a race that would be almost impossible to diagnose.
        Contexts are cached per session because building one is a round trip.
    .OUTPUTS
        An Azure context, or throws if the signed-in identity cannot see that
        subscription - which is an answer, not something to work around.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    if (-not $script:VmfSubContextCache) { $script:VmfSubContextCache = @{} }
    if ($script:VmfSubContextCache.ContainsKey($SubscriptionId)) {
        return $script:VmfSubContextCache[$SubscriptionId]
    }
    $ctx = Get-AzContext -ErrorAction Stop
    if (-not $ctx) { throw 'No Azure context - Connect-AzAccount first.' }
    if ([string]$ctx.Subscription.Id -eq $SubscriptionId) {
        $script:VmfSubContextCache[$SubscriptionId] = $ctx
        return $ctx
    }
    $scoped = Set-AzContext -Subscription $SubscriptionId -Scope Process -ErrorAction Stop
    if (-not $scoped) { throw "Could not get an Azure context for subscription '$SubscriptionId'." }
    # Put the caller's context back: this function hands out a profile, it does
    # not change where anyone else is pointing.
    Set-AzContext -Context $ctx -Scope Process -ErrorAction SilentlyContinue | Out-Null
    $script:VmfSubContextCache[$SubscriptionId] = $scoped
    $scoped
}

function Use-VmfSubscriptionContext {
    <#
    .SYNOPSIS
        ENGINE-SUB-1: point THIS PROCESS at one subscription, and hand back what
        it was pointing at so the caller can put it back.
    .DESCRIPTION
        The engine addresses machines by resource group and name, which are
        unique only inside a subscription. Rather than thread a -SubscriptionId
        through every azureops function that touches a VM - about thirty of
        them, each an opportunity to miss one - the process is pointed at the
        machine's own subscription for the duration of that machine.

        THAT IS ONLY SAFE BECAUSE OF HOW WORKERS RUN, and it is worth writing
        down: Start-VmfWave spawns one worker PROCESS per concurrent machine
        (Start-Process), and each worker leases and drives ONE machine at a time
        in a sequential while loop. So there is never more than one machine in
        flight per process, and a process-scoped context cannot be changed under
        another machine's feet. If workers ever become threads or a process ever
        drives two machines at once, this becomes a race and the parameter has
        to be threaded after all. `EngineSubscription.Tests.ps1` asserts the
        one-machine-per-process property so that change cannot pass unnoticed.

        Capacity is different and deliberately still uses -DefaultProfile: it
        runs at PLAN time, in one process, across several subscriptions at once.
    .OUTPUTS
        The context that was in effect, to pass back to Restore-VmfSubscriptionContext.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $previous = Get-AzContext -ErrorAction SilentlyContinue
    if ($previous -and [string]$previous.Subscription.Id -eq $SubscriptionId) { return $previous }
    # -Scope Process so this cannot leak into the operator's own session or
    # into another worker's, and so it dies with the process if we crash.
    $null = Set-AzContext -Subscription $SubscriptionId -Scope Process -ErrorAction Stop
    $previous
}

function Restore-VmfSubscriptionContext {
    <#
    .SYNOPSIS
        Put back whatever Use-VmfSubscriptionContext replaced. Never throws -
        a failure to restore must not mask the outcome of the machine.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Context)
    if (-not $Context) { return }
    try { $null = Set-AzContext -Context $Context -Scope Process -ErrorAction Stop }
    catch { Write-Verbose "could not restore the previous Azure context: $($_.Exception.Message)" }
}

function Get-VmfVmUsage {
    <#
    .SYNOPSIS
        Compute usage (quota limit and current value) for ONE subscription.
    .DESCRIPTION
        ODCR-SUB-1: replaces a bare Get-AzVMUsage, which read whichever
        subscription the caller happened to be signed in to.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location
    )
    $ctx = Get-VmfAzContextForSubscription -SubscriptionId $SubscriptionId
    @(Get-AzVMUsage -Location $Location -DefaultProfile $ctx)
}

function Get-VmfCurrentSubscriptionId {
    <#
    .SYNOPSIS
        The subscription the session is pointed at.
    .DESCRIPTION
        QUOTA-BOUNDARY-1. Reading the ambient context is not an ARM call, but
        it IS the thing that decides which subscription an operation lands in -
        so it belongs beside the operations, where a test can replace it.

        A caller that needs a SPECIFIC subscription should carry its id rather
        than call this. This is only for the commands a person runs against
        whatever they are signed in to.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    [string](Get-AzContext).Subscription.Id
}

function Request-VmfQuotaIncrease {
    <#
    .SYNOPSIS
        Ask Azure to raise the vCPU limit for one family in one region.
    .DESCRIPTION
        REGIONAL-QUOTA-REQUEST-1: -Family is the Microsoft.Quota resource
        name, so the same request raises the Total Regional vCPUs quota with
        'cores' (probed 2026-11-02: the name the quota API returns for it).

        QUOTA-BOUNDARY-1: this PUT used to sit in Request-VmfQuota, outside the
        azureops boundary, which hard rule 3 calls a review-blocking defect.

        The cost was NOT that the cmdlet could not be tested - it was, by
        mocking Invoke-AzRestMethod inside the module, which Pester will do
        wherever the call lives. The cost is that those tests replace an AZURE
        cmdlet rather than one of ours: they break when the SDK changes under
        them, and they cannot say which of our operations was meant. A named
        seam is a contract; a mocked vendor cmdlet is a guess about one.

        Returns the raw response. The caller reads the status code, because 200
        and 202 mean different things here: 200 is an auto-approval that has
        already happened, and 202 is a request that continues without us.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Family,
        [Parameter(Mandatory)][int]$NewLimit
    )
    # The path names the subscription, so this cannot land somewhere else
    # whatever the session is pointed at - the rule from SEC-1 F10.
    # QUOTA-REQUEST-URL-1: ${Family} in braces. PowerShell 7 allows '?' in a
    # variable name, so an unbraced one before '?api' read as one empty
    # variable and Azure refused the path (MissingApiVersionParameter).
    $path = "/subscriptions/$SubscriptionId/providers/Microsoft.Compute/locations/$Location" +
            "/providers/Microsoft.Quota/quotas/${Family}?api-version=2023-02-01"
    $payload = @{
        properties = @{
            name  = @{ value = $Family }
            limit = @{ limitObjectType = 'LimitValue'; value = $NewLimit }
        }
    } | ConvertTo-Json -Depth 6
    Invoke-AzRestMethod -Method PUT -Path $path -Payload $payload
}

function Get-VmfQuotaRequestState {
    <#
    .SYNOPSIS
        QUOTA-REQUEST-POLL-1: read one quota increase request - Microsoft's
        Quota Request Status GET.
    .DESCRIPTION
        A request Azure takes with HTTP 202 continues without us, and nothing
        read it again: the page said "Pending" for ever. MEASURED 2026-11-16
        (final lab): this GET answered provisioningState InProgress, then
        Failed with error.code QuotaNotAvailableForResource about 80 seconds
        after the request was filed.

        GET /subscriptions/{sub}/providers/Microsoft.Compute/locations/{region}
            /providers/Microsoft.Quota/quotaRequests/{id}?api-version=2023-02-01
        (learn.microsoft.com/rest/api/quota/quota-request-status/get). Azure
        checks Microsoft.Quota/quotaRequests/read ("Get any service limit
        request for the specified resource", Microsoft's Azure permissions
        page, General: Microsoft.Quota).

        -RequestId is the ID the request gave: the full resource ID, or the
        GUID alone. Only the GUID goes into the path, and the subscription and
        region must have the form Azure gives them, so no other text reaches
        the URL. Each variable in the path is written with braces: PowerShell
        reads "?" as part of a variable name (QUOTA-REQUEST-URL-1).

        Returns the raw response; ConvertFrom-VmfQuotaRequestAnswer reads it.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$RequestId
    )
    $guid = [guid]::Empty
    $last = @($RequestId.Split('/') | Where-Object { $_ })
    $name = if ($last.Count) { $last[-1] } else { '' }
    if (-not [guid]::TryParseExact($name, 'D', [ref]$guid)) { throw "The quota request ID '$RequestId' does not end with a GUID." }
    $sub = [guid]::Empty
    if (-not [guid]::TryParseExact($SubscriptionId, 'D', [ref]$sub)) { throw "The subscription ID '$SubscriptionId' is not a GUID." }
    if ($Location -notmatch '^[A-Za-z0-9]+$') { throw "The region '$Location' is not an Azure region name." }
    $path = "/subscriptions/${SubscriptionId}/providers/Microsoft.Compute/locations/${Location}" +
            "/providers/Microsoft.Quota/quotaRequests/${name}?api-version=2023-02-01"
    Invoke-AzRestMethod -Method GET -Path $path
}

function Get-VmfRetailPrice {
    <#
    .SYNOPSIS
        ODCR-UX-1: what one instance of a size costs per hour, from Azure's
        published retail price list.
    .DESCRIPTION
        The reservation dialog was not how an ODCR is done. It warned that
        reserving costs money and asked for
        a note, and showed none of what was being decided - which sizes, how
        many, or what it would come to. "It costs money" is a warning, not
        information, and an operator was being asked to approve a spend they
        could not see the size of.

        This is the public price list rather than ARM - no authentication, no
        permission, nothing about the customer's account. It lives behind the
        azureops boundary anyway so it can be mocked: a test that reaches the
        real internet is a test that fails when somebody else's service is down.

        UNKNOWN RETURNS NULL, and callers must show it as unknown. Zero would
        read as free, which is the one wrong answer that looks like an answer.
    .OUTPUTS
        [double] price per hour in the list's currency, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][string]$Region,
        [Parameter()][string]$OsType
    )
    if (-not $Size -or -not $Region) { return $null }
    try {
        $filter = "armRegionName eq '$Region' and armSkuName eq '$Size' and priceType eq 'Consumption'"
        $uri = 'https://prices.azure.com/api/retail/prices?$filter=' + [uri]::EscapeDataString($filter)
        $items = @((Invoke-RestMethod -Uri $uri -TimeoutSec 20).Items) |
            Where-Object { $_.meterName -notmatch 'Spot|Low Priority' -and $_.productName -notmatch 'Managed Instance' }
        if (-not $items) { return $null }
        # Windows meters carry the licence surcharge and sit in a Windows
        # product, so the two are not interchangeable.
        $wanted = if ($OsType -eq 'Windows') { $items | Where-Object productName -match 'Windows' }
                  else { $items | Where-Object productName -notmatch 'Windows' }
        $pick = @(if ($wanted) { $wanted } else { $items }) | Sort-Object retailPrice | Select-Object -First 1
        [double]$pick.retailPrice
    }
    catch { $null }
}

function New-VmfCapacityReservation {
    <#
    .SYNOPSIS
        Ensure a Capacity Reservation Group + one reservation for a size exist
        (idempotent by name), and CONFIRMED as provisioned.

        ODCR-VERIFY-1: creation returning is NOT the capacity guarantee - that
        was the assumption this function shipped with. An ARM create returns on
        acceptance; provisioningState says whether Azure allocated anything.
    .OUTPUTS
        @{ GroupId = <id>; ReservationId = <id> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][int]$Quantity,
        [Parameter()][string]$Zone,
        # ODCR-SUB-1: the subscription this reservation must live in - the one
        # its machines are in. A reservation group in any other subscription is
        # unusable by them, so this is not optional and is never the ambient
        # context.
        [Parameter(Mandatory)][string]$SubscriptionId,
        # UNINSTALL-RESERVE-1: tags that find it after the product is gone
        # (Get-VmfReservationTags). Put on the group and the reservation when
        # they are created.
        [Parameter()][hashtable]$Tags
    )

    $ctx = Get-VmfAzContextForSubscription -SubscriptionId $SubscriptionId
    # MISSING-READ-2: only a NotFound is "no group yet", and the same for the
    # reservation below. A read Azure does not answer throws, and the claim
    # says the reservation failed - never a second create sent on a guess.
    $group = $null
    try {
        $group = Get-AzCapacityReservationGroup -ResourceGroupName $ResourceGroupName -Name $GroupName `
            -DefaultProfile $ctx -ErrorAction Stop
    }
    catch {
        if (-not (Test-VmfAzNotFound -ErrorRecord $_)) { throw }
    }
    if (-not $group) {
        $groupParams = @{ ResourceGroupName = $ResourceGroupName; Name = $GroupName; Location = $Location; DefaultProfile = $ctx }
        if ($Zone) { $groupParams.Zone = @($Zone) }
        # A TAG MUST NEVER COST A RESERVATION - the rule the safety copies
        # follow (New-VmfSnapshot). A customer policy that denies a tag name
        # would otherwise block the claim, and ODCR-FAIL-1 then releases the
        # whole wave's reservations over a label. A refusal costs the label;
        # the group keeps its vmf- name, which the removal also searches. A
        # failure that is not about the tags fails again below and throws.
        if ($Tags) {
            try { $group = New-AzCapacityReservationGroup @groupParams -Tag $Tags }
            catch {
                Write-Warning ("The capacity reservation group '$GroupName' was refused with its tags, so it is made without them. " +
                               "Its name still starts with vmf-. Azure said: $($_.Exception.Message)")
            }
        }
        if (-not $group) { $group = New-AzCapacityReservationGroup @groupParams }
        elseif ($Tags) {
            # POLICY-REVERT-1: a modify policy strips tags and reports success.
            # This is the response Azure returned, and it costs no extra call.
            $landed = ConvertTo-VmfTagTable -Tags $group.Tags
            if (-not $landed.ContainsKey('vmfCapacityReservation')) {
                Write-Warning ("The capacity reservation group '$GroupName' was made, but Azure did not keep its tags. " +
                               "A policy in this subscription removes them. Its name still starts with vmf-.")
            }
        }
    }

    $resName = ($Size -replace '^Standard_', '').ToLowerInvariant()
    $reservation = $null
    try {
        $reservation = Get-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
            -ReservationGroupName $GroupName -Name $resName -DefaultProfile $ctx -ErrorAction Stop
    }
    catch {
        if (-not (Test-VmfAzNotFound -ErrorRecord $_)) { throw }
    }
    if (-not $reservation) {
        $resParams = @{
            ResourceGroupName = $ResourceGroupName; ReservationGroupName = $GroupName
            Name = $resName; Location = $Location; Sku = $Size; CapacityToReserve = $Quantity
            DefaultProfile = $ctx
        }
        if ($Zone) { $resParams.Zone = $Zone }
        # The same rule: the removal finds the reservation by its group.
        if ($Tags) {
            try { $reservation = New-AzCapacityReservation @resParams -Tag $Tags }
            catch {
                Write-Warning ("The capacity reservation '$resName' was refused with its tags, so it is made without them. " +
                               "Azure said: $($_.Exception.Message)")
            }
        }
        if (-not $reservation) { $reservation = New-AzCapacityReservation @resParams }
    }

    # ODCR-VERIFY-1. An ODCR can complete or fail depending on Azure, so a
    # quick "done" looked like an assumption that it worked.
    #
    # It was an assumption. The assumption turned out to be
    # CORRECT, which the drill established and this comment used to deny.
    #
    # MEASURED against Azure 2026-09-02 (tests/lab/Invoke-OdcrDrill.ps1,
    # docs/evidence/odcr-verify-drill.json): New-AzCapacityReservation returns
    # 'Succeeded' after ~34s. The cmdlet BLOCKS until provisioningState is
    # terminal - the ARM API underneath is asynchronous, the wrapper waits.
    #
    # So this wait is INSURANCE, NOT A FIX. It is kept because it makes the
    # guarantee explicit and costs one API call, and because an Az version, a
    # size or a region that returns early would otherwise write RESERVED for
    # nothing. It is NOT kept on the story that the old code was broken: on
    # this path it was not.
    $reservation = Wait-VmfReservationProvisioned -ResourceGroupName $ResourceGroupName `
        -ReservationGroupName $GroupName -Name $resName -Context $ctx

    @{ GroupId = [string]$group.Id; ReservationId = [string]$reservation.Id }
}

function Wait-VmfReservationProvisioned {
    <#
    .SYNOPSIS
        Wait for a capacity reservation to reach a TERMINAL provisioning state,
        and throw unless it succeeded.
    .DESCRIPTION
        ODCR-VERIFY-1. Azure reports provisioningState on the reservation:
        Creating / Updating while it is being allocated, then Succeeded or
        Failed. Only Succeeded means the capacity is held.

        Throwing is the point. New-VmfWaveReservation catches it: Failed or
        Canceled moves the claim to BLOCKED with reservation-failed, because
        nothing is held. A wait that runs out is NOT that answer - Azure may
        still make it - so the claim stays RESERVING and is marked not
        confirmed, which bills in the product's rule until it is released
        (RESERVING-STUCK-1).
    .OUTPUTS
        The reservation object, in a Succeeded state.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$ReservationGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()]$Context,
        # Generous, because the failure mode of being too impatient is worse
        # than waiting: we would release capacity that was about to exist and
        # the operator would be billed for the attempt either way.
        [Parameter()][int]$TimeoutSeconds = 600,
        [Parameter()][int]$PollSeconds = 10
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $last = $null
    while ($true) {
        $r = Get-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
            -ReservationGroupName $ReservationGroupName -Name $Name `
            -DefaultProfile $Context -ErrorAction Stop
        $last = [string]$r.ProvisioningState

        if ($last -eq 'Succeeded') { return $r }
        if ($last -in @('Failed', 'Canceled')) {
            throw "Azure did not provision the capacity reservation '$Name' in '$ReservationGroupName': provisioningState is $last. The capacity was not held."
        }
        if ((Get-Date) -ge $deadline) {
            # RESERVING-STUCK-1: silence is not a no. Azure can still finish
            # this one, and then it bills - so the caller keeps it as a claim
            # that bills, by these words ($script:VmfReservationUnconfirmedWords).
            throw ("The capacity reservation '$Name' in '$ReservationGroupName' was still '$last' after $TimeoutSeconds seconds, " +
                   "$($script:VmfReservationUnconfirmedWords). Azure can still make it, and then it bills until it is released.")
        }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Set-VmfCapacityReservationQuantity {
    <#
    .SYNOPSIS
        Update a reservation's reserved quantity. Setting 0 is the documented
        safe path to disassociate RUNNING VMs (no deallocation, no restart risk):
        capacity-reservation-remove-vm, option 2.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$ReservationName,
        # ODCR-SUB-1: reservations live in the subscription their machines are
        # in; acting on the ambient context could touch the wrong one.
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][int]$Quantity
    )
    $ctx = Get-VmfAzContextForSubscription -SubscriptionId $SubscriptionId
    Update-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
        -ReservationGroupName $GroupName -Name $ReservationName -CapacityToReserve $Quantity `
        -DefaultProfile $ctx | Out-Null
}

function Test-VmfCapacityReservationPresent {
    <#
    .SYNOPSIS
        RESERVING-STUCK-1: does Azure show this reservation? $true or $false,
        and a THROW when Azure could not be read.
    .DESCRIPTION
        Remove-VmfCapacityReservation used to read with SilentlyContinue, so a
        throttled or refused read looked like "nothing there" and the delete
        was skipped (MISSING-READ-2 made it throw). A claim whose reservation
        Azure never confirmed is written RELEASED only after this says $false, and
        only a not-found answer says it: a reservation or its group that Azure
        does not have. Anything else is not an answer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$ReservationName,
        [Parameter(Mandatory)][string]$SubscriptionId
    )
    $ctx = Get-VmfAzContextForSubscription -SubscriptionId $SubscriptionId
    try {
        $r = Get-AzCapacityReservation -ResourceGroupName $ResourceGroupName -ReservationGroupName $GroupName `
            -Name $ReservationName -DefaultProfile $ctx -ErrorAction Stop
    }
    catch {
        $err = Resolve-VmfOperationError -ErrorRecord $_
        if ($err.StatusCode -eq 404 -or $err.ClassifyText -match 'ResourceNotFound|ParentResourceNotFound|ResourceGroupNotFound') { return $false }
        throw
    }
    [bool]$r
}

function Get-VmfCapacityReservationByArm {
    <#
    .SYNOPSIS
        ODCR-STATUS-1: what Azure holds for one capacity reservation, read by
        its resource ID - for the five-minute pass of the web service, which
        loads no Az module and so has no Get-AzCapacityReservation
        (FACADE-SIGNIN-COLD-1, FacadeAzModules.Tests.ps1).
    .DESCRIPTION
        GET {reservation id}?api-version=2024-07-01, the action
        Microsoft.Compute/capacityReservationGroups/capacityReservations/read,
        which the VMF Assessment role already holds (Get-AzCapacityReservation
        in data/rbac-actions.json), so no role changes.
        Found is $false only when Azure says not found - the reservation, its
        group or its resource group (the codes Test-VmfCapacityReservationPresent
        reads as gone). Any other answer throws: a read Azure refused or did
        not give is never "nothing bills".
    .OUTPUTS
        Found, ProvisioningState (Azure's own word: Creating, Updating,
        Succeeded, Failed, Canceled), TimeCreated (a string, or $null).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ReservationId)
    $null = Assert-VmfResourceId -ResourceId $ReservationId -Kind 'capacity reservation'
    if ($ReservationId -notmatch '(?i)^/subscriptions/[^/?#]+/resourceGroups/[^/?#]+/providers/Microsoft\.Compute/capacityReservationGroups/[^/?#]+/capacityReservations/[^/?#]+$') {
        throw "Not a full capacity reservation resource ID: '$ReservationId'."
    }
    $r = Invoke-VmfArmRequest -Method GET -Path "$($ReservationId)?api-version=2024-07-01"
    $code = if ($r) { [int]$r.StatusCode } else { 0 }
    $content = if ($r) { [string]$r.Content } else { '' }
    if ($code -eq 404) {
        $errorCode = ''
        try { $errorCode = [string](($content | ConvertFrom-Json -Depth 10).error.code) } catch { $errorCode = '' }
        if ($errorCode -in @('ResourceNotFound', 'ParentResourceNotFound', 'ResourceGroupNotFound')) {
            return [pscustomobject]@{ Found = $false; ProvisioningState = $null; TimeCreated = $null }
        }
    }
    if ($code -ne 200 -or -not $content) {
        throw "The read of the capacity reservation '$ReservationId' failed with HTTP $($code): $content"
    }
    $props = ($content | ConvertFrom-Json -Depth 20 -DateKind String).properties
    [pscustomobject]@{
        Found             = $true
        ProvisioningState = $(if ($props -and $props.provisioningState) { [string]$props.provisioningState } else { $null })
        TimeCreated       = $(if ($props -and $props.timeCreated) { [string]$props.timeCreated } else { $null })
    }
}

function Get-VmfCapacityReservationSizes {
    <#
    .SYNOPSIS
        CRG-MOVE-1: the size each capacity reservation in a group reserves,
        read by the group's resource id. Throws when Azure cannot be read.
        CRG-MOVE-ZONE-1: and the availability zones of each one.
    .DESCRIPTION
        Microsoft's "Modify a capacity reservation" page, section "Resize VMs
        associated to a capacity reservation group": before a machine in a
        group is resized, read the group's capacity reservations and the size
        each one reserves. Only the sizes and zones come back - never the
        reserved quantity, which is not a limit (Azure allows overallocation).

        A capacity reservation in a zonal group is for one zone, so each entry
        is { size; zones }: zones empty for a regional reservation (since
        2026-11-02 the zone is compared too). One entry for each size and zones.
        A reservation Azure gives with no zones field throws: it is never read
        as regional.

        The group can be in another resource group than the machine, so it is
        addressed by its id: its own subscription (ODCR-SUB-1's pinned
        profile, never the ambient one), resource group and name. A refused or
        failed read throws - it is never an empty group.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param([Parameter(Mandatory)][string]$GroupId)

    $sub = Assert-VmfResourceId -ResourceId $GroupId -Kind 'capacity reservation group'
    $m = [regex]::Match($GroupId, '(?i)^/subscriptions/[^/]+/resourceGroups/(?<rg>[^/]+)/providers/Microsoft\.Compute/capacityReservationGroups/(?<name>[^/]+)$')
    if (-not $m.Success) {
        throw "Not a capacity reservation group resource id: '$GroupId'. The product reads the capacity reservations of a group only by the id of the group."
    }
    $ctx = Get-VmfAzContextForSubscription -SubscriptionId $sub
    $list = @(Get-AzCapacityReservation -ResourceGroupName $m.Groups['rg'].Value `
        -ReservationGroupName $m.Groups['name'].Value -DefaultProfile $ctx -ErrorAction Stop)
    $seen = @{}
    foreach ($r in @($list | Where-Object { $_ -and $_.Sku -and [string]$_.Sku.Name })) {
        if (-not $r.PSObject.Properties['Zones']) {
            throw "Azure did not give the zones of the capacity reservation '$([string]$r.Name)'."
        }
        $zones = @(@($r.Zones) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Sort-Object -Unique)
        $key = '{0}|{1}' -f ([string]$r.Sku.Name).ToLowerInvariant(), ($zones -join ',')
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        [pscustomobject]@{ size = [string]$r.Sku.Name; zones = $zones }
    }
}

function Remove-VmfCapacityReservation {
    <#
    .SYNOPSIS
        Delete one reservation and, when empty, its group. Idempotent.
        Caller must have disassociated all VMs first.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$GroupName,
        [Parameter(Mandatory)][string]$ReservationName,
        # ODCR-SUB-1: reservations live in the subscription their machines are
        # in; acting on the ambient context could touch the wrong one.
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter()][int]$UnreferencedTimeoutSeconds = 120,
        [Parameter()][int]$PollSeconds = 5
    )

    $ctx = Get-VmfAzContextForSubscription -SubscriptionId $SubscriptionId
    # MISSING-READ-2: only a NotFound is "already deleted". A read Azure does
    # not answer throws, and the claim is not written RELEASED - never a
    # delete skipped on a guess while the reservation may still bill.
    $reservation = $null
    try {
        $reservation = Get-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
            -ReservationGroupName $GroupName -Name $ReservationName -DefaultProfile $ctx -ErrorAction Stop
    }
    catch {
        if (-not (Test-VmfAzNotFound -ErrorRecord $_)) { throw }
    }
    if ($reservation) {
        # Disassociation (the VM PATCH clearing capacityReservationGroup) is
        # EVENTUALLY CONSISTENT: the reservation can keep reporting VM
        # references after the PATCHes return, and deleting then 409s
        # "still referenced by VM" (found by REH-1). Wait until unreferenced.
        # Count REAL references. @($null).Count is 1 in PowerShell, so if this
        # property is ever absent rather than an empty list, the naive count
        # reads as "one VM still on it" - and this loop would then wait out the
        # whole timeout and refuse to delete EVERY reservation, leaving reserved
        # capacity billing forever. Az returns an empty list today (measured);
        # this does not depend on it.
        $refCount = { @($reservation.VirtualMachinesAssociated | Where-Object { $_ }).Count }
        $deadline = [datetime]::UtcNow.AddSeconds($UnreferencedTimeoutSeconds)
        while ((& $refCount) -gt 0) {
            if ([datetime]::UtcNow -ge $deadline) {
                throw "Capacity reservation '$ReservationName' still referenced by $(& $refCount) VM(s) after ${UnreferencedTimeoutSeconds}s - disassociate before deleting."
            }
            Start-Sleep -Seconds $PollSeconds
            try {
                $reservation = Get-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
                    -ReservationGroupName $GroupName -Name $ReservationName -DefaultProfile $ctx -ErrorAction Stop
            }
            catch {
                if (Test-VmfAzNotFound -ErrorRecord $_) { return }   # deleted out-of-band
                throw
            }
            if (-not $reservation) { return }   # deleted out-of-band
        }
        # Remove-AzCapacityReservation has no -Force (found by REH-1 on the real
        # module; azureops mocks hid it) - -Confirm:$false suppresses the prompt.
        Remove-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
            -ReservationGroupName $GroupName -Name $ReservationName -DefaultProfile $ctx -Confirm:$false | Out-Null
    }
    # MISSING-READ-2: a list Azure did not give is not "the group is empty".
    # A NotFound is a group already gone. Any other failure keeps the group:
    # it costs nothing, and the reservation above is deleted already.
    try {
        $remaining = @(Get-AzCapacityReservation -ResourceGroupName $ResourceGroupName `
            -ReservationGroupName $GroupName -DefaultProfile $ctx -ErrorAction Stop)
    }
    catch {
        if (Test-VmfAzNotFound -ErrorRecord $_) { return }
        Write-Warning ("Azure did not list the capacity reservations in the capacity reservation group '$GroupName', so the product keeps the group. " +
                       "The group costs nothing. Delete it when it is empty. Azure said: $($_.Exception.Message)")
        return
    }
    if ($remaining.Count -eq 0) {
        # The group itself costs nothing once it is empty, so a failure here is
        # not a money leak - but SilentlyContinue meant nobody ever found out,
        # and an orphaned group is one more thing an operator has to explain.
        try {
            Remove-AzCapacityReservationGroup -ResourceGroupName $ResourceGroupName -Name $GroupName `
                -DefaultProfile $ctx -Confirm:$false -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning ("The capacity reservation group '$GroupName' is empty, but Azure did not delete it. " +
                           "The group costs nothing, and you can delete it. Azure said: $($_.Exception.Message)")
        }
    }
}

function Set-VmfVmCapacityReservationGroup {
    <#
    .SYNOPSIS
        Associate (or with $null, disassociate) a VM with a Capacity Reservation
        Group. The VM must be deallocated to associate; disassociation works on
        a running VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][AllowNull()][string]$GroupId
    )

    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    $current = if ($vm.CapacityReservation -and $vm.CapacityReservation.CapacityReservationGroup) {
        [string]$vm.CapacityReservation.CapacityReservationGroup.Id
    } else { $null }
    if ($current -eq $GroupId) { return }   # idempotent

    if ($GroupId) {
        # Associate: Update-AzVM's dedicated parameter serializes a real id
        # correctly. (Hand-building CapacityReservationProfile on the VM model
        # is silently DROPPED by the ARM serializer - REH-1.)
        $vm = Clear-VmfDiskPerfProperties -Vm $vm
        $result = Update-AzVM -ResourceGroupName $ResourceGroupName -VM $vm -CapacityReservationGroupId $GroupId
        if ($result.StatusCode -ne 'OK') {
            throw "Capacity reservation association update for '$Name' returned '$($result.StatusCode)'."
        }
    }
    else {
        # Disassociate: Az PowerShell cannot express this at all ([string]
        # coerces $null to '' -> 400 LinkedInvalidPropertyId; a null profile on
        # the VM model is dropped -> silent no-op; and CRP IGNORES
        # "capacityReservationGroup": null). The shape CRP honors - verified
        # empirically in REH-1, matching az CLI's --capacity-reservation-group
        # None - is an explicit null ID INSIDE the group object.
        $payload = '{"properties":{"capacityReservation":{"capacityReservationGroup":{"id":null}}}}'
        $resp = Invoke-AzRestMethod -Method PATCH -Path "$($vm.Id)?api-version=2024-07-01" -Payload $payload
        if ($resp.StatusCode -notin @(200, 202)) {
            throw "Capacity reservation disassociation PATCH for '$Name' returned $($resp.StatusCode): $($resp.Content)"
        }
    }
    # Trust nothing the serializer touched: verify the VM's association state.
    $after = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    $now = if ($after.CapacityReservation -and $after.CapacityReservation.CapacityReservationGroup) {
        [string]$after.CapacityReservation.CapacityReservationGroup.Id
    } else { $null }
    if ([string]$now -ne [string]$GroupId) {
        throw "Capacity reservation association for '$Name' did not take effect (still '$now', wanted '$GroupId')."
    }
}

function Get-VmfVmCapacityReservationGroupId {
    <#
    .SYNOPSIS
        The Capacity Reservation Group a VM is currently associated with, or
        $null. Its own op so the restore path can ask without reaching for Az.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$Name
    )
    $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $Name
    if ($vm.CapacityReservation -and $vm.CapacityReservation.CapacityReservationGroup) {
        return [string]$vm.CapacityReservation.CapacityReservationGroup.Id
    }
    return $null
}

