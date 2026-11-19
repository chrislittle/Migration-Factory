# EVAL-M8/M9: the quota record, built in one place and testable without Azure.
#
# Every claim the product has ever written was invalid against its own schema,
# in three ways at once, and nothing noticed because the only document ever
# validated against `capacity-claim.schema.json` was a hand-written sample in
# `schemas/samples/`. The sample conformed. The code emitted something else.
#
#   1. `quota.checkedUtc` was added so the dashboard could stop implying the
#      reading was live. `quota` is a closed object and the field was never
#      declared, so EVERY claim failed - unconditionally, from the moment that
#      improvement shipped.
#   2. `quota.limit` and `quota.used` are typed integer, and are written as
#      null on the path CLAUDE.md documents as a known Azure bug: the s-suffix
#      v6 families that do not appear in the usage listing. That is the primary
#      fleet shape.
#   3. `vmFamily` is typed string and is written as null whenever the size is
#      not offered in the region - which is exactly when a claim is blocked and
#      most worth reading.
#
# The lesson is the one the self-evaluation drew twice elsewhere: a contract
# tested against a fixture is not tested. So the claim is constructed here, as
# a pure function with no Azure in it, and the tests validate WHAT THIS EMITS
# against the schema rather than validating a sample nobody's code produces.

# CRG-MOVE-DEMAND-1 (v15): demand.ownGroupVmIds - the machines of the record
# that stay in their own capacity reservation group, left out of
# reservableInstances as an availability set member is.
$script:VmfCapacityClaimSchemaVersion = 15

# REGIONAL-QUOTA-REQUEST-1: the subscription's Total Regional vCPUs quota of
# Microsoft.Compute. The usage list names it 'cores', and so does the
# Microsoft.Quota API: PROBED 2026-11-02 (read only, centralus), GET
# .../locations/<region>/providers/Microsoft.Quota/quotas/cores returned name
# 'cores', localizedValue 'Total Regional vCPUs', isQuotaApplicable true. The
# Quota API's own page says to use the name it returns when requesting quota.
$script:VmfRegionalQuotaResourceName = 'cores'
$script:VmfRegionalQuotaDisplayName = 'Total Regional vCPUs'

function Get-VmfQuotaRequestLimit {
    <#
    .SYNOPSIS
        REGIONAL-QUOTA-REQUEST-1: the limit a quota increase request asks for.
        Pure.
    .DESCRIPTION
        The usage, plus the vCPUs the plan needs of the quota, plus the
        headroom asked for - and NEVER below the present limit. A reading
        taken earlier can put the usage and the need below a limit already
        raised, and a request for less would lower the quota. An unknown
        present limit is not a floor.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][int]$Used,
        [Parameter(Mandatory)][int]$Need,
        [Parameter()][int]$Headroom = 0,
        [Parameter()][AllowNull()][object]$CurrentLimit
    )
    $asked = $Used + $Need + $Headroom
    if ($null -ne $CurrentLimit -and [int]$CurrentLimit -gt $asked) { return [int]$CurrentLimit }
    $asked
}

function Get-VmfQuotaRefusalText {
    <#
    .SYNOPSIS
        QUOTA-FILED-WORDS-1: the reason a quota increase request was not
        filed, from Azure's answer. Pure.
    .DESCRIPTION
        The wave editor shows this sentence for the quota after Request. An
        ARM error body is JSON with error.code and error.message, and those
        are what a person reads; any other body is shown as it came, so
        nothing Azure said is lost. Never throws: it runs on the path that
        reports a failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object]$StatusCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Content
    )
    $head = "Azure answered HTTP $StatusCode"
    $code = $null; $message = $null
    try {
        $j = $Content | ConvertFrom-Json -ErrorAction Stop
        if ($j -and $j.PSObject.Properties['error'] -and $j.error) {
            $code = [string]$j.error.code
            $message = [string]$j.error.message
        }
    }
    catch { }   # not JSON: the body as it came
    if ($message) {
        if ($code) { return "$head ${code}: $message" }
        return "${head}: $message"
    }
    if ($Content) { return "${head}: $Content" }
    "$head."
}

# RESERVING-STUCK-1: how long a claim may sit at RESERVING before the page
# offers Release. A create returns in about 34 seconds (ODCR-VERIFY-1) and its
# wait gives up at 600. This is NOT proof the engine has stopped - the create
# call itself can block longer, and the engine job may live a day. What makes
# an overlap safe is that both writers save the claim only if it is unchanged
# since they read it (Write-VmfClaimIfVersion), and the engine releases what it
# made if the claim was released meanwhile. The dashboard holds the same number
# (help.js, RESERVING_STUCK_MINUTES).
$script:VmfReservingStuckMinutes = 60

# The words Wait-VmfReservationProvisioned uses when Azure has not answered in
# time. New-VmfWaveReservation reads them to tell "not confirmed" from "Azure
# said no", and Invoke-VmfAzOperation never retries an error that holds them.
$script:VmfReservationUnconfirmedWords = 'so it was not confirmed as held'

function Read-VmfClaimVersioned {
    <#
    .SYNOPSIS
        RESERVING-STUCK-1: a claim with its PLANVER-2 version, so a later save
        can refuse if anybody wrote it in between. $null when it is not there.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Name
    )
    $handle = "$RunPath/capacity/$Name"
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath "capacity/$Name"
    if ($null -eq $text) { return $null }
    [pscustomobject]@{ Handle = $handle; Version = (Get-VmfDocumentVersion -Text $text); Claim = ($text | ConvertFrom-Json -Depth 12) }
}

function Write-VmfClaimIfVersion {
    <#
    .SYNOPSIS
        Save a claim only if it still holds the version the caller read
        (Write-VmfTextDocumentIfVersion, PLAN-WRITE-RACE-1). Throws 409
        otherwise. Returns the version it wrote, for the next save.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Handle,
        [Parameter(Mandatory)]$Claim,
        [Parameter(Mandatory)][string]$ExpectedVersion
    )
    $text = $Claim | ConvertTo-Json -Depth 12
    Write-VmfTextDocumentIfVersion -Path $Handle -Content $text -ExpectedVersion $ExpectedVersion
    Get-VmfDocumentVersion -Text $text
}

function Get-VmfNameCode {
    <#
    .SYNOPSIS
        CLAIM-NAME-1: a short code that tells apart names a cleaning rule
        would make the same. Pure. A quota record's file and reservation
        group names use it, and so does a wave's acceptance file
        (ACCEPT-NAME-1, Get-VmfWaveOptionsAcceptancePath).
    .DESCRIPTION
        The first characters of the SHA-256 of the parts, joined by the
        unit separator character (code 31), which no wave, subscription,
        region, zone or size holds - a part that did would be refused, so no
        part can run into the next. Letter case is ignored, because the engine
        ignores it when it groups a plan into cells (Group-Object, -eq) and
        Azure ignores it in a resource name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][AllowEmptyCollection()][string[]]$Part,
        [Parameter()][ValidateRange(6, 64)][int]$Length = 12
    )
    $separator = [string][char]31
    $parts = @($Part | ForEach-Object { ([string]$_).ToLowerInvariant() })
    if (@($parts | Where-Object { $_.Contains($separator) }).Count) { throw 'A part of a name holds the unit separator character, so it cannot be told apart from two parts.' }
    $text = $parts -join $separator
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $hash.Substring(0, $Length)
}

function Get-VmfClaimFileName {
    <#
    .SYNOPSIS
        CLAIM-NAME-1: the file name of a quota record - one cell of a wave,
        subscription, region, zone and size. Pure.
    .DESCRIPTION
        The readable part is the rule the product always used: the five parts
        with every character but a letter, a number or a dash made a dash. A
        wave name may hold dots and underscores too (Set-VmfWavePlan), so
        wave_1, wave.1 and wave-1 got ONE file, and each check of one wave
        replaced the other wave's record. The code after it is made from the
        parts as they are, so two cells never share a file.
        Lower case, because the engine reads Wave_1 and wave_1 as one wave:
        it names the cell after whichever machine came first, and on blob
        storage a name in a different case is a different file.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter(Mandatory)][string]$Size
    )
    $readable = ('{0}-{1}-{2}-{3}-{4}' -f $Wave, $SubscriptionId.Substring(0, [math]::Min(8, $SubscriptionId.Length)), $Region,
                 $(if ($Zone) { $Zone } else { 'regional' }), $Size) -replace '[^A-Za-z0-9\-]', '-'
    $code = Get-VmfNameCode -Part @($Wave, $SubscriptionId, $Region, [string]$Zone, $Size)
    "$($readable.ToLowerInvariant())-$code.json"
}

function Test-VmfClaimOfCell {
    <#
    .SYNOPSIS
        CLAIM-NAME-1: is this quota record the record of this cell? Pure.
        Compared the way the quota check groups a plan: letter case ignored,
        no zone the same as an empty one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Claim,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Wave,
        [Parameter(Mandatory)][AllowEmptyString()][string]$SubscriptionId,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Region,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Size
    )
    # The ONE cell comparer: Test-VmfClaimCellMatchesEntry (RESERVE-COVER-1)
    # asks this with a plan entry's cell.
    if ($null -eq $Claim) { return $false }
    $field = { param($n) if ($Claim -is [System.Collections.IDictionary]) { [string]$Claim[$n] } elseif ($Claim.PSObject.Properties[$n]) { [string]$Claim.$n } else { '' } }
    ((& $field 'wave') -eq $Wave) -and ((& $field 'subscriptionId') -eq $SubscriptionId) -and
        ((& $field 'region') -eq $Region) -and ((& $field 'zone') -eq [string]$Zone) -and ((& $field 'size') -eq $Size)
}

function Resolve-VmfClaimFile {
    <#
    .SYNOPSIS
        CLAIM-NAME-1: which file holds a cell's quota record, read with its
        version (Read-VmfClaimVersioned). Returns Name and Read; Read is
        $null when the cell has no record yet.
    .DESCRIPTION
        The name from Get-VmfClaimFileName. OLD-VERSION-READERS-REMOVE-2: the
        name from before CLAIM-NAME-1 is not read - only an earlier version
        wrote it, and nothing is public before 1.0.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Region,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter(Mandatory)][string]$Size
    )
    $cell = @{ Wave = $Wave; SubscriptionId = $SubscriptionId; Region = $Region; Zone = $Zone; Size = $Size }
    $name = Get-VmfClaimFileName @cell
    $read = Read-VmfClaimVersioned -RunPath $RunPath -Name $name
    [pscustomobject]@{ Name = $name; Read = $read }
}

function Get-VmfReservationNames {
    <#
    .SYNOPSIS
        RESERVING-STUCK-1: the group and reservation a claim's on-demand
        capacity reservation has, or would have. Pure.
    .DESCRIPTION
        Without -ForNewAsk: the names the claim RECORDED before Azure was
        asked (reservationAsked), read from its resource IDs. A claim that
        recorded none is refused - OLD-VERSION-READERS-REMOVE-5: the rule from
        before CLAIM-NAME-1 gave it a name, and a release by a guessed name can
        delete a reservation of another wave. Only New-VmfWaveReservation
        writes RESERVING, and it records the ask in the same save, so no
        record of this version is refused (OldVersionReadersRemove5.Tests.ps1).
        With -ForNewAsk: the names for a new ask.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Claim,
        # CLAIM-NAME-1: the names for a reservation about to be ASKED for. The
        # old rule turned every character but a letter, a number or a dash
        # into a dash, so waves wave_1 and wave-1 got one group - and since the
        # create reuses a reservation by name, the second wave's Reserve took
        # the first wave's reservation, and a release of either deleted it. A
        # new ask adds a code from the run, the wave, the subscription, the
        # region and the zone - a group holds one region, so two regions of one
        # wave in one resource group need two. A claim that already recorded an
        # ask is REFUSED: only a QUOTA_VERIFIED claim is asked for, and the
        # product never writes one that holds an ask (a quota check writes a
        # fresh record), so such a claim was changed by hand or by a defect -
        # and its recorded reservation may still exist.
        [Parameter()][switch]$ForNewAsk
    )

    # A name is unique only inside one resource group of one subscription, so
    # what identifies the reservation is its RESOURCE ID (the standing rule:
    # address resources by id). Subscription, resource group and names
    # are all read from the one recorded id, never assembled from elsewhere.
    $asked = if ($Claim.PSObject.Properties['reservationAsked']) { $Claim.reservationAsked } else { $null }
    if ($ForNewAsk -and $asked -and ($asked.groupId -or $asked.reservationId)) {
        throw ("The quota record for $([string]$Claim.size) in $([string]$Claim.region) already names an on-demand capacity reservation ($([string]$asked.reservationId)), so a new one was not asked for. " +
               'Check the quota of the wave again, then reserve.')
    }
    if (-not $ForNewAsk) {
        if (-not ($asked -and [string]$asked.groupId -and [string]$asked.reservationId)) {
            throw "The quota record for $([string]$Claim.size) in $([string]$Claim.region) holds no resource ID for an on-demand capacity reservation."
        }
        $groupId = [string]$asked.groupId
        $reservationId = [string]$asked.reservationId
        if (-not $reservationId.StartsWith("$groupId/capacityReservations/", [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "The recorded on-demand capacity reservation $reservationId is not in the recorded capacity reservation group $groupId."
        }
        return @{
            GroupId = $groupId; ReservationId = $reservationId
            SubscriptionId = Get-VmfSubscriptionId -ResourceId $groupId
            ResourceGroup = Get-VmfResourceGroupName -ResourceId $groupId
            GroupName = ($groupId -split '/')[-1]
            ReservationName = ($reservationId -split '/')[-1]
        }
    }
    # ODCR-SUB-1: the subscription is in the name, or two cells of one wave in
    # two subscriptions would share a group name.
    $sub = [string]$Claim.subscriptionId
    $zonePart = if ($Claim.zone) { "-az$($Claim.zone)" } else { '' }
    $groupName = ('vmf-{0}-{1}-{2}{3}' -f $Claim.runId, $Claim.wave, $sub.Substring(0, [math]::Min(8, $sub.Length)), $zonePart) -replace '[^A-Za-z0-9\-]', '-'
    # The code goes on AFTER the cut, so a long run and wave name can never
    # cut off what tells two groups apart (the zone, the subscription).
    $code = Get-VmfNameCode -Length 8 -Part @([string]$Claim.runId, [string]$Claim.wave, $sub, [string]$Claim.region, [string]$Claim.zone)
    # SNAPSHOT-NAME-END-1: the shared rule makes the cut (67 + the code = 76).
    $groupName = ConvertTo-VmfAzureName -Name $groupName -Suffix "-$code" -MaxLength 76 -Rule 'capacityReservationGroup'
    $resName = ([string]$Claim.size -replace '^Standard_', '').ToLowerInvariant()
    $groupId = "/subscriptions/$sub/resourceGroups/$([string]$Claim.resourceGroup)/providers/Microsoft.Compute/capacityReservationGroups/$groupName"
    @{
        GroupId = $groupId; ReservationId = "$groupId/capacityReservations/$resName"
        SubscriptionId = $sub; ResourceGroup = [string]$Claim.resourceGroup
        GroupName = $groupName; ReservationName = $resName
    }
}

function Test-VmfClaimReservingStuck {
    <#
    .SYNOPSIS
        RESERVING-STUCK-1: is this a RESERVING claim nobody is making any more?
        Pure. True when Azure did not confirm it in time, or when it has been
        RESERVING longer than any create takes, or cannot say since when.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Claim,
        [Parameter()][datetime]$NowUtc = (Get-Date).ToUniversalTime()
    )
    if ([string]$Claim.state -ne 'RESERVING') { return $false }
    if ($Claim.PSObject.Properties['reservationUnconfirmedUtc'] -and $Claim.reservationUnconfirmedUtc) { return $true }
    $since = if ($Claim.PSObject.Properties['reservingSinceUtc']) { $Claim.reservingSinceUtc } else { $null }
    if (-not $since) { return $true }
    # ConvertFrom-Json may already have turned it into a date value.
    $started = if ($since -is [datetime]) { $since.ToUniversalTime() }
               else { [datetime]::Parse([string]$since, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime() }
    ($NowUtc - $started).TotalMinutes -ge $script:VmfReservingStuckMinutes
}

# QUOTA-BUTTON-1: the states in which a claim stands for something that exists
# (or existed) in AZURE - a capacity reservation being made, held, in use, or
# released and kept as the record that one was held. A quota check never
# replaces these: it would erase the only record of a reservation that bills.
$script:VmfClaimStatesHeldInAzure = @('RESERVING', 'RESERVED', 'CONSUMED', 'RELEASED')

# WAVE-EDIT-RESERVE-1: the states in which a reservation BILLS - being made,
# held, or in use. No writer may remove such a claim: it is the only record
# pointing at something Azure charges for. A RELEASED claim bills nothing, and
# kept it stops the wave starting again (the start check reads it as not
# ready), so a writer may clear it - after saying in the activity log what it
# was (Write-VmfReleasedClaimNote).
$script:VmfClaimStatesBilling = @('RESERVING', 'RESERVED', 'CONSUMED')

function Get-VmfReservationTags {
    <#
    .SYNOPSIS
        UNINSTALL-RESERVE-1: the tags on every capacity reservation group and
        reservation the product creates, so they can be found after the
        product - and every record of them - is gone.
    .DESCRIPTION
        'true', not the install's name, so ONE literal command finds every
        reservation this product ever made in a subscription - the same shape
        as the safety copies' vmfSafetyCopy tag (FIND-COPY-1). The run and the
        wave say what it was for; the store says which install, when the run is
        on blob storage. An absent tag is better than a made-up one.
    .OUTPUTS
        [hashtable] of tag name to value.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$RunPath
    )
    $tags = @{ vmfCapacityReservation = 'true'; vmfRun = $RunId; vmfWave = $Wave }
    if ($RunPath -and $RunPath -match '^azblob://([^/]+)/') { $tags['vmfStore'] = $Matches[1] }
    $tags
}

function Get-VmfBillingClaimRefusal {
    <#
    .SYNOPSIS
        The refusal, or $null: ONE rule for every writer that would remove a
        wave's claims (Set-VmfWavePlan, Set-VmfMachineTarget). Pure.
    .PARAMETER Action
        What the person was doing, finishing the sentence "Release it on the
        wave, then ...".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][AllowEmptyCollection()][string[]]$States = @(),
        [Parameter(Mandatory)][string]$Action
    )
    $billing = @($States | Where-Object { $_ -in $script:VmfClaimStatesBilling } | Sort-Object -Unique)
    if (-not $billing.Count) { return $null }
    # RUN-DELETE-RESERVE-1 review: a claim still RESERVING has no Release while
    # a create runs, so the answer is to wait. RESERVING-STUCK-1: one nobody is
    # making any more shows Not confirmed, with Release beside it.
    if (-not @($billing | Where-Object { $_ -ne 'RESERVING' }).Count) {
        return ("400: Wave $Wave has an on-demand capacity reservation that Azure is still making (RESERVING). Wait until the wave shows Reserved, then release it on the wave, then $Action. " +
                "If the wave shows Not confirmed, select Release beside it, then $Action.")
    }
    "400: Wave $Wave has an on-demand capacity reservation in Azure ($($billing -join ', ')). Release it on the wave, then $Action."
}

function Get-VmfRunBillingRefusal {
    <#
    .SYNOPSIS
        RUN-DELETE-RESERVE-1: the refusal for an action that would remove a
        whole run's claims - deleting the run - or $null. Reads the run's
        claims and asks the one rule, wave by wave.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Action
    )
    $claims = @(foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json')) {
            $c = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$name" -Depth 12
            if ($c) { [pscustomobject]@{ Wave = [string]$c.wave; State = [string]$c.state } }
        })
    foreach ($group in @($claims | Group-Object Wave)) {
        $refusal = Get-VmfBillingClaimRefusal -Wave $group.Name -States @($group.Group.State) -Action $Action
        if ($refusal) { return $refusal }
    }
    $null
}

function Assert-VmfNoBillingReservation {
    <#
    .SYNOPSIS
        Throws the refusal, if any. Asked by Remove-VmfRun, and by the service
        BEFORE it logs "discarded by" - a refused deletion must leave no line
        saying it happened (the ASSESS-LINK-1 shape).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    $refusal = Get-VmfRunBillingRefusal -RunPath $RunPath -Action 'delete the migration'
    if ($refusal) { throw $refusal }
}

function Get-VmfWaveReleaseRefusal {
    <#
    .SYNOPSIS
        WAVE-EDIT-RESERVE-1: why the operator's release of a wave's reservation
        must not run now, or $null. Asked by the engine's `release` operation,
        so the page is never the only guard.
    .DESCRIPTION
        A machine between being taken and a final state may be using the
        reservation - CONVERTING associates it with the reservation - so
        releasing under it fails an Azure call inside the stopped window. A
        state of PLANNED counts: the engine writes it when a worker TAKES the
        machine (WAVE-MIX-2), and a lease counts for the same reason. A machine
        parked on a decision or rolled back is the operator's call to leave
        without the guarantee, so it does not stop a release.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave
    )
    Get-VmfWaveRunningDetail -RunPath $RunPath -Wave $Wave
}

function Get-VmfWaveRunningDetail {
    <#
    .SYNOPSIS
        Is a wave RUNNING - which machine says so - or $null. One rule for
        every caller: the release of its reservation (WAVE-EDIT-RESERVE-1) and
        an edit of the wave (WAVE-EDIT-RUNNING-1).
    .DESCRIPTION
        Running: a machine of the wave has a lease, or a state that is not
        final - Get-VmfMachineHold, the rule the pages share (VmfHelp.machineHold,
        WAVE-RUNNING-LEASE-1). PLANNED counts - the engine writes it when a
        worker TAKES the machine (WAVE-MIX-2). A machine parked on a decision,
        rolled back, or finished is settled. Read from the STORED plan, so an
        unsaved edit does not change the answer.
        A machine at work is named first. A hold a stopped worker left on a
        finished machine (endedHold) is named only when nothing else holds the
        wave, and says that the service removes it: then the wave stops
        running.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave
    )
    $plan = Read-VmfPlanDocument -RunPath $RunPath
    $ended = $null
    foreach ($e in @($plan.entries | Where-Object { [string]$_.wave -eq $Wave })) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId ([string]$e.vmId) -ErrorAction SilentlyContinue
        $lease = Get-VmfLeaseInfo -RunPath $RunPath -VmId ([string]$e.vmId)
        $name = ([string]$e.vmId -split '/')[-1]
        $state = if ($doc -and $doc.state) { [string]$doc.state } else { '' }
        switch (Get-VmfMachineHold -State $state -Lease $lease) {
            'working' {
                if ($lease) { return "$name is $(Get-VmfLeaseHolderWords -Lease $lease)" }
                return "$name is $state"
            }
            'endedHold' {
                if (-not $ended) { $ended = "$name is held by a worker that stopped, and the service removes that hold at its next check" }
            }
        }
    }
    $ended
}

function Save-VmfReleasedClaimHistory {
    <#
    .SYNOPSIS
        REPORT-RELEASED-1: keep a RELEASED claim under capacity-history/, which
        the customer report and the Reports page read beside the live claims.
    .DESCRIPTION
        The activity log alone lost the billed reservation time from both
        reports. Nothing that judges a wave reads this folder: the start gate
        and the wave editor read capacity/ only.

        ONE FILE PER RESERVATION: the name comes from the reservation (its id
        and when it was made), so a second write - a retried save, or a writer
        that saves it before it takes the claim - replaces the first. A claim
        with no reservation record gets a name of its own each time.
        Contract: schemas/capacity-history.schema.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Claim,
        [Parameter()][ValidateSet('changed', 'checked')][string]$Because = 'changed'
    )
    $cell = ("{0}-{1}-{2}-{3}" -f [string]$Claim.wave, [string]$Claim.region, [string]$Claim.size,
        $(if ($Claim.zone) { [string]$Claim.zone } else { 'regional' })) -replace '[^A-Za-z0-9\-_.]', '-'
    $res = if ($Claim.PSObject.Properties['reservation']) { $Claim.reservation } else { $null }
    # RESERVING-STUCK-1: a reservation Azure never confirmed has no creation
    # time, so two releases of one cell would share a name; its release time
    # tells them apart.
    $when = if ($res -and $res.createdUtc) { ConvertTo-VmfIsoUtc $res.createdUtc } elseif ($res) { "released $(ConvertTo-VmfIsoUtc $res.releasedUtc)" } else { '' }
    $identity = if ($res -and [string]$res.reservationId) { "$([string]$res.reservationId)|$when" } else { [guid]::NewGuid().ToString('N') }
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = -join ($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($identity)) | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    $record = [ordered]@{
        schemaVersion = 1
        clearedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        because       = $Because
        claim         = ($Claim | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12)
    }
    # WRITE-DEPTH-OPEN-1: 24, because the schema's claim is open.
    Write-VmfStoreJson -RunPath $RunPath -RelPath "capacity-history/$cell-$($hash.Substring(0, 12)).json" -Document $record -Depth 24
}

function Write-VmfReleasedClaimNote {
    <#
    .SYNOPSIS
        Before a RELEASED claim is cleared, the activity log keeps what it
        recorded, and the claim is kept as history (Save-VmfReleasedClaimHistory).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Claim,
        # Why it goes: the wave changed, or its quota was checked again.
        [Parameter()][ValidateSet('changed', 'checked')][string]$Because = 'changed'
    )
    Save-VmfReleasedClaimHistory -RunPath $RunPath -Claim $Claim -Because $Because
    $when = if ($Claim.PSObject.Properties['reservation'] -and $Claim.reservation) {
        # RESERVING-STUCK-1: a reservation released by name was never seen made.
        # The dates are read before the sentence, so the word check reads the
        # sentence and not a property name (MANUAL-REVIEW-1).
        $madeAt = ConvertTo-VmfIsoUtc $Claim.reservation.createdUtc
        $releasedAt = ConvertTo-VmfIsoUtc $Claim.reservation.releasedUtc
        if ($Claim.reservation.createdUtc) {
            " It was reserved $madeAt and released $releasedAt."
        } else { " Azure had not confirmed it, and it was released $releasedAt." }
    } else { '' }
    $why, $verb = if ($Because -eq 'checked') { "The quota of wave $([string]$Claim.wave) was checked again", 'replaced' }
                  else { "Wave $([string]$Claim.wave) changed", 'removed' }
    # STEP-LOG-2: written after the history is kept and the plan saved; the
    # caller clears the claim next. A line that cannot be written stops neither.
    Write-VmfStepLine -RunPath $RunPath -Step 'capacity' -Outcome info `
        -Detail ("$why, so the record of its released on-demand capacity reservation " +
                 "($([string]$Claim.size) in $([string]$Claim.region)) was $verb.$when")
}

function Get-VmfSubscriptionId {
    <#
    .SYNOPSIS
        The subscription id out of an ARM resource id. Pure.
    .DESCRIPTION
        ODCR-SUB-1. A capacity reservation group is SUBSCRIPTION-SCOPED: a VM
        can only associate with one in its own subscription, region and zone.
        The capacity model had no idea subscriptions existed - the demand matrix
        keyed on wave|region|zone|size, so machines from different subscriptions
        were summed into one cell and one reservation was created for all of
        them, in whichever subscription happened to hold the capacity resource
        group. The machines in every other subscription could never use it: they
        fell back to unreserved general capacity, which is the exact failure the
        Reserved gate exists to prevent, while the customer paid for slots
        nothing could consume.
    .OUTPUTS
        The subscription id, or $null when the id does not carry one - which
        must never be silently treated as "the current one".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][string]$ResourceId)
    if ($ResourceId -match '(?i)/subscriptions/([0-9a-f-]{36})(/|$)') { return $Matches[1] }
    $null
}

function Get-VmfResourceGroupName {
    <#
    .SYNOPSIS
        The resource group out of an ARM resource id. Pure.
    .DESCRIPTION
        CAPRG-1. A reservation has to be created in SOME resource group, and
        the first version of this asked an operator to nominate one - a single
        name that had to exist in every subscription being migrated, which no
        real estate can promise and which nothing in the app helped anybody
        set up.

        It was a question that did not need asking. A VM attaches to a
        reservation by the reservation group's full resource id, so the
        reservation only has to share the machines' subscription and region;
        which resource group holds it changes nothing about whether they can
        use it. The machines are already in a resource group - one that exists,
        that the operator can see, and that they already have rights to. Use
        that one.
    .OUTPUTS
        The resource group name, or $null when the id does not carry one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][string]$ResourceId)
    if ($ResourceId -match '(?i)/resourceGroups/([^/]+)(/|$)') { return $Matches[1] }
    $null
}

function Select-VmfCellResourceGroup {
    <#
    .SYNOPSIS
        Which resource group a cell's reservation goes in. Pure.
    .DESCRIPTION
        Normally every machine in a cell is in one resource group and there is
        nothing to decide. When they span several, the one holding the MOST of
        them wins, and an exact tie is broken by name so two runs over the same
        plan always choose the same group. Any of them would work - this is
        about being predictable, not about being right.
    .OUTPUTS
        The resource group name, or $null when no machine id carries one.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][string[]]$VmIds)
    $groups = @($VmIds | ForEach-Object { Get-VmfResourceGroupName -ResourceId $_ } | Where-Object { $_ })
    if ($groups.Count -eq 0) { return $null }
    @($groups | Group-Object | Sort-Object -Property @{ Expression = 'Count'; Descending = $true },
                                                     @{ Expression = 'Name'; Descending = $false })[0].Name
}

function Test-VmfClaimBlocked {
    <#
    .SYNOPSIS
        Is this quota record blocked? The ONE function every reader asks.
    .DESCRIPTION
        BLOCKED-NAME-1. The state is BLOCKED, and `blockReason` says why: of
        the reasons, only `reservation-failed` is about capacity. A quota
        shortfall is a LIMIT, a restricted size is a policy, and a missing
        size is not offered there at all.

        One function rather than a comparison copied to each call site:
        `BlockedState.Tests.ps1` holds every reader to it. Every writer of
        this version gives BLOCKED (OLD-VERSION-READERS-REMOVE-8), so no
        other name is read.

        Anything with no readable state is NOT blocked. An unreadable claim is
        an unreadable claim; calling it blocked would assert a cause again.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Claim)

    if ($null -eq $Claim) { return $false }
    $state = if ($Claim -is [string]) { $Claim }
             elseif ($Claim.PSObject.Properties['state']) { [string]$Claim.state }
             else { '' }
    $state.Trim().ToUpperInvariant() -eq 'BLOCKED'
}
function Test-VmfClaimRegionalShort {
    <#
    .SYNOPSIS
        Is this quota record short of the Total Regional vCPUs quota?
    .DESCRIPTION
        REGIONAL-QUOTA-BOTH-PAGE-1. True when the record is blocked on the
        regional quota ('regional-quota-shortfall'), or blocked on its family
        ('quota-shortfall') with the quota check's answer beside it that the
        region is short for the same machines (regionalShort, capacity-claim
        v14). Only the boolean the schema gives counts: the quota check writes
        null when it did not judge the region (no regional reading, or a record
        blocked before it), and unknown is not short. Nothing here judges the
        figures - the quota check did.

        Request-VmfQuota asks this to put a record in its region's quota
        increase request. The dashboard's twin is VmfHelp.claimRegionalShort,
        which the migration page's capacity card and the wave editor read, and
        both are held to tests/fixtures/regional-short.json - so the card says
        the region is short exactly when Request an increase asks for it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Claim)

    if ($null -eq $Claim -or $Claim -is [string]) { return $false }
    # The facade gets hashtables (BODY-HASH-1); one shape for the reads below.
    if ($Claim -is [System.Collections.IDictionary]) { $Claim = [pscustomobject]$Claim }
    if (-not (Test-VmfClaimBlocked -Claim $Claim)) { return $false }
    $read = { param($name) if ($Claim.PSObject.Properties[$name]) { $Claim.$name } else { $null } }
    $reason = & $read 'blockReason'
    if ($reason -is [string] -and $reason -ceq 'regional-quota-shortfall') { return $true }
    $answer = & $read 'regionalShort'
    return ($reason -is [string] -and $reason -ceq 'quota-shortfall' -and $answer -is [bool] -and $answer)
}

function Test-VmfClaimReservable {
    <#
    .SYNOPSIS
        AVSET-RESERVE-1: does this quota record have any machine a capacity
        reservation can hold?
    .DESCRIPTION
        Azure cannot put a machine in an availability set on a capacity
        reservation, so CAP-2 records `demand.reservableInstances` beside the
        total. A record that SAYS zero has nothing to reserve: its machines move
        on general capacity, and a wave set to Reserved must not wait for a
        reservation that can never exist - that is the defect this answers,
        twice over (a mixed wave that could never start while its other cell
        billed, and an all-availability-set wave told to reserve).

        A record that does not say - no count, or a count that is not a whole
        number - IS reservable. New-VmfCapacityClaim always writes the count,
        so this is the safe side of a record nothing of this version writes:
        unknown is not a no, and reading it as one would let a Reserved wave
        start with no on-demand capacity reservation. New-VmfWaveReservation
        refuses to reserve for such a record, because it cannot say how many
        machines to reserve for (OLD-VERSION-READERS-REMOVE-8).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Claim)

    $reservable = (Get-VmfClaimDemandCounts -Claim $Claim).Reservable
    ($null -eq $reservable) -or ($reservable -gt 0)
}

function Get-VmfClaimDemandCounts {
    <#
    .SYNOPSIS
        AVSET-RESERVE-1: a quota record's instances and reservable instances,
        each an integer or $null when the record does not say.
    .DESCRIPTION
        Strict on purpose: only a whole number counts as saying. A value that
        is not one - text that is not a number, a fraction, true or false - is
        not an answer, so the record reads as reservable. The wave editor reads
        the same way (waves.html, claimCount), and both are held to the rule
        cases in tests/fixtures/reserve-nothing-events.json.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Claim)

    $pick = {
        param($Holder, [string]$Key)
        if ($null -eq $Holder) { return $null }
        if ($Holder -is [System.Collections.IDictionary]) { if ($Holder.Contains($Key)) { return , $Holder[$Key] } else { return $null } }
        if ($Holder.PSObject.Properties[$Key]) { return , $Holder.$Key }
        $null
    }
    $count = {
        param($Value)
        # true and false are neither type below, so they read as no count.
        if ($null -eq $Value) { return $null }
        if ($Value -is [int] -or $Value -is [long] -or $Value -is [short] -or $Value -is [byte]) { return [long]$Value }
        if ($Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
            if ([math]::Floor([double]$Value) -eq [double]$Value) { return [long]$Value } else { return $null }
        }
        if ($Value -is [string] -and $Value -match '^\s*[+-]?\d+\s*$') { return [long]$Value.Trim() }
        $null
    }
    $demand = & $pick $Claim 'demand'
    [pscustomobject]@{
        Instances  = & $count (& $pick $demand 'instances')
        Reservable = & $count (& $pick $demand 'reservableInstances')
    }
}

function Get-VmfClaimOwnGroupVmIds {
    <#
    .SYNOPSIS
        CRG-MOVE-DEMAND-1: the machines of this record that stay in their own
        capacity reservation group (demand.ownGroupVmIds, v15). Empty when
        the record names none, or holds no demand.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()]$Claim)

    if ($null -eq $Claim) { return @() }
    $demand = if ($Claim -is [System.Collections.IDictionary]) { $Claim['demand'] } elseif ($Claim.PSObject.Properties['demand']) { $Claim.demand } else { $null }
    if ($null -eq $demand) { return @() }
    $ids = if ($demand -is [System.Collections.IDictionary]) { $demand['ownGroupVmIds'] } elseif ($demand.PSObject.Properties['ownGroupVmIds']) { $demand.ownGroupVmIds } else { $null }
    @(@($ids) | Where-Object { $_ -is [string] -and $_ })
}

function Get-VmfClaimGeneralInstances {
    <#
    .SYNOPSIS
        AVSET-RESERVE-1: how many of this record's machines move on general
        capacity because they are in an availability set. 0 when it does not say.
    .DESCRIPTION
        CRG-MOVE-DEMAND-1: the machines that stay in their own capacity
        reservation group are left out too (Get-VmfClaimOwnGroupVmIds). They
        are not reserved by the wave either, but they are not in an
        availability set, and they move on their own group.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param([Parameter()][AllowNull()]$Claim)

    $c = Get-VmfClaimDemandCounts -Claim $Claim
    if ($null -eq $c.Instances -or $null -eq $c.Reservable) { return 0 }
    $own = @(Get-VmfClaimOwnGroupVmIds -Claim $Claim).Count
    [int][math]::Max(0, $c.Instances - [math]::Max(0, $c.Reservable) - $own)
}
function Get-VmfCapacityClaimSchemaVersion {
    <#
    .SYNOPSIS
        The version this build writes. One declaration, so the writer, the
        schema's const and the migration note cannot disagree.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    $script:VmfCapacityClaimSchemaVersion
}

function New-VmfCapacityClaim {
    <#
    .SYNOPSIS
        Build one quota record document. Pure - no Azure, no store.
    .DESCRIPTION
        Takes facts already gathered (the SKU catalog entry's family, the usage
        reading, the demand counts) and returns the document exactly as it is
        written to `capacity/<cell>.json`.

        Nulls are deliberate and are declared nullable in the schema. A null
        vmFamily means the size is not offered in that region, so there is no
        family; a null quota limit/used means the family did not appear in the
        usage listing and the reading could not be taken. CLAUDE.md's rule
        applies to both: unknown must never be read as either a yes or a no,
        so the claim says null rather than 0 - which would read as "no quota
        used" and is the more dangerous lie.
    .OUTPUTS
        [ordered] claim document.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Wave,
        # ODCR-SUB-1: which subscription this cell's machines live in, and
        # therefore the only subscription a reservation for them can be created
        # in. Required - a claim that cannot say where it applies cannot be
        # acted on, and defaulting it to the signed-in context is precisely the
        # bug being fixed.
        [Parameter(Mandatory)][string]$SubscriptionId,
        # CAPRG-1: the resource group its machines are already in - see
        # Get-VmfResourceGroupName for why this is not a setting.
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$Region,
        [Parameter()][AllowNull()][string]$Zone,
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][AllowNull()][string]$VmFamily,
        [Parameter(Mandatory)][string]$State,
        [Parameter()][AllowNull()][string]$BlockReason,
        [Parameter(Mandatory)][int]$Instances,
        [Parameter(Mandatory)][int]$ReservableInstances,
        # CRG-MOVE-DEMAND-1 (v15): the machines of the cell that stay in their
        # own capacity reservation group, which ReservableInstances leaves out.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$OwnGroupVmIds = @(),
        [Parameter(Mandatory)][int]$Vcpus,
        # QUOTA-FAMILY-1: the vCPUs the whole plan asks of this record's quota
        # family, in its subscription and region - the number the check judged
        # (ODCR-FAMILY-1). Null when there is no family to total.
        [Parameter()][AllowNull()][object]$FamilyVcpus,
        # REGIONAL-VCPU-QUOTA-1 (v11): the vCPUs the whole plan ADDS to the
        # subscription's Total Regional vCPUs in this region - each machine's
        # new size less its old one, never below 0 - and the reading of that
        # quota ('cores' in the usage list). Null when it was not read.
        [Parameter()][AllowNull()][object]$RegionalVcpus,
        [Parameter()][AllowNull()][object]$RegionalLimit,
        [Parameter()][AllowNull()][object]$RegionalUsed,
        # REGIONAL-QUOTA-WAVES-1 (v14): the vCPUs THIS record's machines add to
        # the Total Regional vCPUs - its part of RegionalVcpus. Null when not
        # worked out (a size the region does not offer).
        [Parameter()][AllowNull()][object]$RegionalAdds,
        # REGIONAL-QUOTA-BOTH-1 (v14): the quota check's answer to "are the
        # machines of this record short of the Total Regional vCPUs?", whatever
        # blockReason says. True or false when judged; null when it was not
        # (no regional reading, or the record was blocked before it).
        [Parameter()][AllowNull()][object]$RegionalShort,
        # ODCR-UX-1: what reserving this cell would cost per hour, at RETAIL
        # list price. Null when it could not be read - the claim says unknown
        # rather than zero, because zero reads as free.
        [Parameter()][AllowNull()][object]$HourlyPerInstance,
        [Parameter()][AllowNull()][string]$Currency,
        [Parameter()][AllowNull()][object]$QuotaLimit,
        [Parameter()][AllowNull()][object]$QuotaUsed,
        [Parameter()][AllowNull()][string]$CheckedUtc,
        # QUOTA-PREVIEW-1 (v12): Azure's own name for the quota, from the usage
        # list (LocalizedValue, for example "Standard DDSv6 Family vCPUs"), and
        # whether this identity may request it: granted, missing, or unknown when
        # the read of its permissions failed. Null when not asked.
        [Parameter()][AllowNull()][string]$QuotaName,
        [Parameter()][AllowNull()][AllowEmptyString()][ValidateSet('granted', 'missing', 'unknown', '')][string]$RequestAccess,
        [Parameter()][string[]]$Notes = @()
    )

    [ordered]@{
        schemaVersion = $script:VmfCapacityClaimSchemaVersion
        runId  = $RunId
        wave   = $Wave
        subscriptionId = $SubscriptionId
        resourceGroup = $ResourceGroup
        region = $Region
        zone   = if ($Zone) { $Zone } else { $null }
        size   = $Size
        vmFamily = if ($VmFamily) { $VmFamily } else { $null }
        state  = $State
        blockReason = if ($BlockReason) { $BlockReason } else { $null }
        regionalShort = if ($null -ne $RegionalShort) { [bool]$RegionalShort } else { $null }
        demand = [ordered]@{
            instances           = $Instances
            reservableInstances = $ReservableInstances
            ownGroupVmIds       = @(@($OwnGroupVmIds) | Where-Object { $_ })
            vcpus               = [math]::Max(1, $Vcpus)
            familyVcpus         = if ($null -ne $FamilyVcpus) { [int]$FamilyVcpus } else { $null }
            regionalVcpus       = if ($null -ne $RegionalVcpus) { [int]$RegionalVcpus } else { $null }
            regionalAdds        = if ($null -ne $RegionalAdds) { [int]$RegionalAdds } else { $null }
        }
        # ODCR-UX-1: what reserving this cell would cost per hour, so the
        # operator can see the SIZE of the spend before approving it. Null when
        # the price could not be read - shown as unknown, never as zero.
        estimatedHourly = $(if ($null -ne $HourlyPerInstance) {
            [ordered]@{
                perInstance = [double]$HourlyPerInstance
                total       = [double]$HourlyPerInstance * $ReservableInstances
                currency    = $(if ($Currency) { $Currency } else { $null })
                # Public price details are fine to use, noted as retail: they
                # do not reflect a customer's MACC discount. The
                # basis travels WITH the number rather than being remembered by
                # each caller - a price with no basis is one somebody quotes at
                # a customer.
                basis       = 'retail-list-price'
            }
        } else { $null })
        # checkedUtc, because used/limit is a reading taken AT PLAN TIME and
        # never refreshed. The dashboard was showing it as though it were live,
        # so it appeared frozen while a wave consumed cores.
        quota  = [ordered]@{
            limit        = if ($null -ne $QuotaLimit) { [int]$QuotaLimit } else { $null }
            used         = if ($null -ne $QuotaUsed) { [int]$QuotaUsed } else { $null }
            regionalLimit = if ($null -ne $RegionalLimit) { [int]$RegionalLimit } else { $null }
            regionalUsed  = if ($null -ne $RegionalUsed) { [int]$RegionalUsed } else { $null }
            name          = if ($QuotaName) { $QuotaName } else { $null }
            requestAccess = if ($RequestAccess) { $RequestAccess } else { $null }
            checkedUtc   = if ($CheckedUtc) { $CheckedUtc } else { (Get-Date).ToUniversalTime().ToString('o') }
            requestId    = $null
            requestedUtc = $null
            regionalRequestId    = $null
            regionalRequestedUtc = $null
        }
        notes  = @($Notes)
    }
}

function Get-VmfCapacityBlockReasons {
    <#
    .SYNOPSIS
        Every value `blockReason` may take, declared once.
    .DESCRIPTION
        EVAL-M9: `New-VmfWaveReservation` writes 'reservation-failed' when an
        on-demand capacity reservation cannot be created. That value was never
        in the schema enum, so the claim it wrote was invalid - and the
        dashboard, which tested for the single string 'quota-shortfall' to
        decide whether to show a warning, rendered a BLOCKED claim with a green
        "quota ok" pill. A wave whose reservation had failed looked ready.
        REGIONAL-VCPU-QUOTA-1 added 'regional-quota-shortfall': the family
        fits, and the subscription's Total Regional vCPUs quota does not. It is
        a reason of its own because Request an increase raises a FAMILY limit,
        and a family request sized from such a record could ask for less than
        the family has.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param()
    , @('quota-shortfall', 'regional-quota-shortfall', 'sku-restricted', 'size-missing', 'reservation-failed')
}
