function Request-VmfQuota {
    <#
    .SYNOPSIS
        P2-6: submit quota increase requests for every claim blocked by a quota
        shortfall (architecture section 10, QUOTA_REQUESTED state).
    .DESCRIPTION
        Scans the run's quota records for state BLOCKED with
        blockReason 'quota-shortfall' and PUTs ONE Microsoft.Quota increase per
        quota - subscription, region and family (catalog-provided, never
        name-derived) - to used + the vCPUs the whole plan needs of the family
        (demand.familyVcpus; plus -HeadroomVcpus). REGIONAL-QUOTA-REQUEST-1:
        a record blocked with 'regional-quota-shortfall' gets ONE request per
        subscription and region for the Total Regional vCPUs quota ('cores'),
        to regionalUsed + demand.regionalVcpus (plus -HeadroomVcpus). No
        request of either kind asks for less than the present limit.
        REGIONAL-QUOTA-BOTH-1: a record blocked with 'quota-shortfall' that
        the quota check found short of the region too (regionalShort) is in
        both requests, filed in the same press.
        QUOTA-PREVIEW-1: a quota the
        quota check found no access to request (quota.requestAccess 'missing')
        is not asked for. Restriction-blocked and size-missing claims are NOT
        quota problems and are left untouched.

        Many compute requests auto-approve in minutes (HTTP 200 = done); larger
        ones return 202 and continue as a support-routed request - which is
        exactly why the runway starts weeks ahead of the wave. Claims move to
        QUOTA_REQUESTED with the request id recorded; re-run
        Test-VmfQuota later to re-verify headroom.
    .PARAMETER WhatIfOnly
        Compute and report what would be requested without submitting. The
        rows go to the activity log as one quotaPreview line, which the wave
        editor's request confirmation shows.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter()][int]$HeadroomVcpus = 0,
        [Parameter()][switch]$WhatIfOnly
    )

    $claimNames = @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json')
    if ($claimNames.Count -eq 0) {
        # A guard: the page offers Request an increase only from the records of a check.
        throw 'No quota is checked for this migration. Select Check the quota on the wave first.'
    }

    # ID-ADDRESS-1: each request goes to the subscription its claim records -
    # the one its machines are in (ODCR-SUB-1). It used to go to whatever
    # subscription the session was in; from the engine, signed in with its
    # identity, that is the identity's home subscription for every claim.

    # QUOTA-PREVIEW-1: ONE REQUEST PER QUOTA. A quota is a subscription, a
    # region and a family, and a plan can hold several records of one: two
    # waves, or two sizes that bill to one family. One request per record
    # asked each time for the usage plus THAT record's vCPUs - each less than
    # the plan needs, the second written over the first. The quota check
    # judged the family's WHOLE ask (demand.familyVcpus, ODCR-FAMILY-1), so
    # that is what is asked for, once, and the preview shows exactly these rows.
    #
    # REGIONAL-QUOTA-REQUEST-1: and ONE REQUEST PER REGIONAL QUOTA. A record
    # blocked with 'regional-quota-shortfall' has a family that fits; what is
    # short is the subscription's Total Regional vCPUs in the region. Its quota
    # is a subscription and a region, and Microsoft.Quota names it 'cores'
    # (probed 2026-11-02, the name the usage list gives it too). It is asked
    # for through the SAME request as a family, sized from the regional
    # figures the check judged: the regional usage plus the vCPUs the whole
    # plan adds in the region (demand.regionalVcpus). A family request is
    # never sized from such a record - it could ask for less than the family has.
    #
    # REGIONAL-QUOTA-BOTH-1: A RECORD CAN BE IN BOTH. A family that is short
    # keeps 'quota-shortfall', and the quota check records beside it whether
    # the region is short for the same machines (regionalShort, capacity-claim
    # v14). Such a record is in its family's request AND its region's, so one
    # press asks for both. Before, the region was asked for only after Azure
    # granted the family and a second check blocked the record on it - two
    # requests one after the other, each of which can take days. A record
    # whose check did not judge the region (regionalShort null) is not put in
    # a regional request.
    # The request of the record's own reason moves it to QUOTA_REQUESTED; the
    # regional request beside it is recorded in regionalRequestId.
    $regionalName = $script:VmfRegionalQuotaResourceName
    $groups = [ordered]@{}
    foreach ($name in $claimNames) {
        $claimRel = "capacity/$name"
        $claim = Read-VmfStoreJson -RunPath $OutPath -RelPath $claimRel -Depth 12
        if (-not (Test-VmfClaimBlocked -Claim $claim) -or -not $claim.PSObject.Properties['blockReason']) { continue }
        $own = switch ([string]$claim.blockReason) {
            'quota-shortfall' { 'family' }
            'regional-quota-shortfall' { 'regional' }
            default { $null }
        }
        if (-not $own) { continue }
        $kinds = @($own)
        # REGIONAL-QUOTA-BOTH-PAGE-1: the one rule, which the capacity card's twin reads too.
        if ($own -eq 'family' -and (Test-VmfClaimRegionalShort -Claim $claim)) { $kinds += 'regional' }
        foreach ($kind in $kinds) {
            $quotaKey = if ($kind -eq 'regional') { $regionalName } else { ([string]$claim.vmFamily).ToLowerInvariant() }
            $key = '{0}|{1}|{2}|{3}' -f $kind, ([string]$claim.subscriptionId).ToLowerInvariant(), ([string]$claim.region).ToLowerInvariant(), $quotaKey
            if (-not $groups.Contains($key)) { $groups[$key] = [pscustomobject]@{ Kind = $kind; Members = [System.Collections.Generic.List[object]]::new() } }
            $groups[$key].Members.Add([pscustomobject]@{ Rel = $claimRel; Claim = $claim; Own = ($kind -eq $own) })
        }
    }

    $results = foreach ($key in $groups.Keys) {
        $kind = $groups[$key].Kind
        $members = @($groups[$key].Members)
        # The reading of the newest check speaks for the quota.
        $ref = @($members | Sort-Object { [string]$_.Claim.quota.checkedUtc } -Descending)[0].Claim
        $field = { param($obj, $n) if ($obj -and $obj.PSObject.Properties[$n]) { $obj.$n } else { $null } }
        if ($kind -eq 'regional') {
            # The quota's name in the request, and Azure's own name for it.
            $quotaResource = $regionalName
            $quotaName = $script:VmfRegionalQuotaDisplayName
            $limit = & $field $ref.quota 'regionalLimit'
            $usedRead = & $field $ref.quota 'regionalUsed'
            $needRead = & $field $ref.demand 'regionalVcpus'
            # The regional ask is the whole plan's, the same on every record of
            # the reading, so the newest record gives it with its usage.
            $sized = ($null -ne $usedRead) -and ($null -ne $needRead)
            $used = if ($null -ne $usedRead) { [int]$usedRead } else { $null }
            $need = if ($null -ne $needRead) { [int]$needRead } else { $null }
            # REGIONAL-QUOTA-WAVES-1: what each wave adds to the region, from
            # what each record's machines add (demand.regionalAdds, v14) - never
            # demand.vcpus, the whole new size. A record whose check did not work
            # it out (null) gives the row no lines rather than a wrong one.
            $adds = @($members | ForEach-Object { & $field $_.Claim.demand 'regionalAdds' })
            $waves = if (@($adds | Where-Object { $null -eq $_ }).Count) { @() } else {
                @($members | Group-Object { [string]$_.Claim.wave } | Sort-Object Name | ForEach-Object {
                    [pscustomobject]@{ Wave = $_.Name; Vcpus = [int](($_.Group | ForEach-Object { [int]$_.Claim.demand.regionalAdds } | Measure-Object -Sum).Sum) }
                })
            }
        }
        else {
            $quotaResource = [string]$ref.vmFamily
            $limit = & $field $ref.quota 'limit'
            $used = [int](& $field $ref.quota 'used')
            $sized = $true
            $totals = @($members | ForEach-Object { & $field $_.Claim.demand 'familyVcpus' } | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
            $need = if ($totals.Count) { ($totals | Measure-Object -Maximum).Maximum }
                    else { [int](($members | ForEach-Object { [int]$_.Claim.demand.vcpus } | Measure-Object -Sum).Sum) }
            $waves = @($members | Group-Object { [string]$_.Claim.wave } | Sort-Object Name | ForEach-Object {
                [pscustomobject]@{ Wave = $_.Name; Vcpus = [int](($_.Group | ForEach-Object { [int]$_.Claim.demand.vcpus } | Measure-Object -Sum).Sum) }
            })
            $quotaName = [string](& $field $ref.quota 'name')
            if (-not $quotaName) { $quotaName = [string]$ref.vmFamily }
        }
        # REGIONAL-QUOTA-REQUEST-1: a request never asks for a limit below the
        # present one, of either kind. A reading taken earlier can put the
        # usage and the ask below a limit already raised, and a request for
        # less would LOWER the quota.
        $newLimit = if ($sized) { Get-VmfQuotaRequestLimit -Used $used -Need $need -Headroom $HeadroomVcpus -CurrentLimit $limit } else { $null }
        # What the current limit leaves - never below 0, when usage is above it.
        $free = if ($null -ne $limit -and $null -ne $used) { [math]::Max(0, [int]$limit - $used) } else { $null }
        $accessSaid = @($members | ForEach-Object { [string](& $field $_.Claim.quota 'requestAccess') })
        $access = if ($accessSaid -contains 'missing') { 'missing' } elseif ($accessSaid -contains 'unknown') { 'unknown' }
                  elseif ($accessSaid -contains 'granted') { 'granted' } else { $null }
        # The step lines name the quota as the request does.
        $said = if ($kind -eq 'regional') { "quota=$quotaResource region=$($ref.region)" } else { "family=$($ref.vmFamily)" }
        # MANUAL-REVIEW-1: a fail line is shown word for word in the activity
        # list, so it names the quota by its Azure name and its region, never
        # as key=value.
        $named = "$quotaName in $($ref.region)"
        # QUOTA-FILED-WORDS-1: a quota not filed carries the reason, the
        # sentence the page shows for it after Request.
        $row = {
            param($status, $requestId, $reason = $null)
            [pscustomobject]@{
                Kind = $kind; Family = $quotaResource; QuotaName = $quotaName; SubscriptionId = [string]$ref.subscriptionId
                Region = $ref.region; Wave = (@($members | ForEach-Object { [string]$_.Claim.wave } | Sort-Object -Unique) -join ', '); Waves = $waves
                Usage = $used; CurrentLimit = $limit; RequestedLimit = $newLimit; Free = $free; Access = $access
                Status = $status; RequestId = $requestId; Reason = $reason
            }
        }

        # Only an ID's own shape passes (Get-VmfSubscriptionId), so no other text
        # reaches the request's URL.
        $subscriptionId = Get-VmfSubscriptionId -ResourceId "/subscriptions/$([string]$ref.subscriptionId)"
        if (-not $subscriptionId) {
            $reason = 'The quota record does not name a subscription, so no increase was requested. Check the quota again: the check writes the subscription.'
            Write-VmfStepLine -RunPath $OutPath -Step 'quotaRequest' -Outcome fail -Detail "${named}: $reason"
            & $row 'FAILED' $null $reason
            continue
        }
        # A record written with no regional reading cannot size the request.
        if (-not $sized) {
            $reason = 'The quota record does not give the usage of the Total Regional vCPUs quota, so no increase was requested. Select Check the quota on the wave again.'
            Write-VmfStepLine -RunPath $OutPath -Step 'quotaRequest' -Outcome fail -Detail "${named}: $reason"
            & $row 'FAILED' $null $reason
            continue
        }
        # The quota check asked Azure, and this identity may not request quota
        # on the subscription. Asking would only be refused.
        if ($access -eq 'missing') {
            $reason = "The product cannot request a quota increase on subscription $subscriptionId, so no increase was requested. That needs the Assess and migrate role on the subscription. Give the role on the Admin page, or request a quota increase on the Quotas page of the Azure portal."
            if (-not $WhatIfOnly) {
                Write-VmfStepLine -RunPath $OutPath -Step 'quotaRequest' -Outcome fail -Detail "${named}: $reason"
            }
            & $row 'NOACCESS' $null $reason
            continue
        }

        if ($WhatIfOnly) {
            & $row 'WHATIF' $null
            continue
        }

        # QUOTA-FILED-WORDS-1: a request that throws (its retries spent, or an
        # error that is not temporary) is one quota not filed. It used to end
        # the whole operation, so the quotas after it were never requested and
        # no result line said which ones were.
        try {
            $response = Invoke-VmfAzOperation -Name "quotaRequest:$quotaResource" -RunPath $OutPath -Operation {
                Request-VmfQuotaIncrease -SubscriptionId $subscriptionId -Location $ref.region `
                    -Family $quotaResource -NewLimit $newLimit
            }
        }
        catch {
            $reason = "The request to Azure failed: $($_.Exception.Message)"
            Write-VmfStepLine -RunPath $OutPath -Step 'quotaRequest' -Outcome fail -Detail "${named}: $reason"
            & $row 'FAILED' $null $reason
            continue
        }

        $status = $null; $requestId = $null; $reason = $null
        switch ([int]$response.StatusCode) {
            200 { $status = 'APPROVED' }        # completed synchronously (auto-approve)
            202 {
                $status = 'PENDING'             # request continues asynchronously
                try {
                    $content = $response.Content | ConvertFrom-Json -Depth 12
                    $requestId = [string]$content.id
                }
                catch { $requestId = $null }
                # QUOTA-REQUEST-POLL-1: Microsoft's Quota - Create Or Update
                # page shows a 202 with no body and a location header that
                # ends with the request's GUID. The engine reads the request
                # by that GUID (Get-VmfQuotaRequestState).
                if (-not $requestId) { $requestId = Get-VmfQuotaRequestIdFromHeader -Response $response }
            }
            default {
                $status = 'FAILED'
                $reason = Get-VmfQuotaRefusalText -StatusCode $response.StatusCode -Content ([string]$response.Content)
                Write-VmfStepLine -RunPath $OutPath -Step 'quotaRequest' -Outcome fail -Detail "${named}: $reason"
            }
        }

        if ($status -in @('APPROVED', 'PENDING')) {
            foreach ($m in $members) {
                $claim = $m.Claim
                $at = (Get-Date).ToUniversalTime().ToString('o')
                if ($m.Own) {
                    $claim.state = 'QUOTA_REQUESTED'
                    $claim.quota | Add-Member -NotePropertyName requestId -NotePropertyValue $requestId -Force
                    $claim.quota | Add-Member -NotePropertyName requestedUtc -NotePropertyValue $at -Force
                }
                else {
                    # REGIONAL-QUOTA-BOTH-1: the regional request beside the
                    # family's. The record stays as its family request leaves it.
                    $claim.quota | Add-Member -NotePropertyName regionalRequestId -NotePropertyValue $requestId -Force
                    $claim.quota | Add-Member -NotePropertyName regionalRequestedUtc -NotePropertyValue $at -Force
                }
                $claim | Add-Member -NotePropertyName notes -NotePropertyValue (
                    @($claim.notes) + @("quota request $status for $(if ($kind -eq 'regional') { $quotaName } else { $quotaResource }) limit=$newLimit")) -Force
                Write-VmfStoreJson -RunPath $OutPath -RelPath $m.Rel -Document $claim -Depth 12
            }
            Write-VmfStepLine -RunPath $OutPath -Step 'quotaRequest' -Outcome ok `
                -Detail "$(if ($kind -eq 'regional') { $said } else { "$said region=$($ref.region)" }) newLimit=$newLimit status=$status"
        }

        & $row $status $requestId $reason
    }
    $out = @($results)
    if ($WhatIfOnly) {
        # QUOTA-PREVIEW-1: the preview went only to the container log, which no
        # page can read, and the wave editor printed "filed" for it. The run's
        # activity log is how an engine answer reaches a page (the quota
        # check's summary line), so the preview is ONE line there, written even
        # when nothing is short - an empty list is an answer, no line is not.
        # One row per quota, with Azure's columns (Quota, Region, Usage, Current
        # limit, New limit), each wave's need, and what the current limit leaves.
        $requests = @($out | ForEach-Object {
            [ordered]@{
                kind = [string]$_.Kind
                family = [string]$_.Family; quotaName = [string]$_.QuotaName; subscriptionId = [string]$_.SubscriptionId
                region = [string]$_.Region; usage = $_.Usage; currentLimit = $_.CurrentLimit
                requestedLimit = $_.RequestedLimit; free = $_.Free; access = $_.Access; status = [string]$_.Status
                waves = @($_.Waves | ForEach-Object { [ordered]@{ wave = [string]$_.Wave; vcpus = [int]$_.Vcpus } })
            }
        })
        # Its own step, not quotaRequest: the activity log names every
        # quotaRequest line "A quota increase was requested", and this one
        # requested nothing. The detail is the sentence the log shows.
        $said = if ($requests.Count -eq 1) { '1 quota increase request' } else { "$($requests.Count) quota increase requests" }
        # STEP-LOG-5: a throwing write on purpose. A preview changes nothing,
        # and this line is its only answer - the page waits for it. A line
        # that cannot be written fails the preview, with nothing filed, so the
        # page says the preview did not work rather than waiting for ever.
        Write-VmfEvent -RunPath $OutPath -Step 'quotaPreview' -Outcome info `
            -Detail "The preview shows $said. No request was filed." `
            -Data @{ requests = $requests }
    }
    else {
        # QUOTA-FILED-WORDS-1: the wave editor said "filed" when the engine
        # job STARTED, before Azure was asked, and a request Azure refused was
        # said only in the activity log. Like the preview, the real request
        # now ends with ONE line the page waits for: each quota, its status
        # (APPROVED and PENDING are filed; FAILED and NOACCESS are not) and
        # the reason for each quota not filed. Written even when nothing was
        # requested - an empty list is an answer, no line is not.
        $rows = @($out | ForEach-Object {
            [ordered]@{
                kind = [string]$_.Kind
                family = [string]$_.Family; quotaName = [string]$_.QuotaName; subscriptionId = [string]$_.SubscriptionId
                region = [string]$_.Region; requestedLimit = $_.RequestedLimit; status = [string]$_.Status
                reason = $(if ($_.Reason) { [string]$_.Reason } else { $null })
                # QUOTA-CHECK-SPINNER-1: the ID Azure gave a filed request, so the
                # confirmation names it. Empty when Azure gave none (an approval at once).
                requestId = $(if ($_.RequestId) { [string]$_.RequestId } else { $null })
            }
        })
        $filed = @($out | Where-Object Status -in @('APPROVED', 'PENDING')).Count
        # STEP-LOG-5: NOT a throwing write, unlike the preview's. This line
        # comes AFTER Azure was asked, so a line that cannot be written must
        # not turn requests Azure took into a failed operation. The page then
        # waits out its window and says the activity log shows each request.
        Write-VmfStepLine -RunPath $OutPath -Step 'quotaResult' -Outcome $(if ($filed -eq $out.Count) { 'ok' } else { 'warn' }) `
            -Detail "The engine filed $filed of $($out.Count) quota increase requests." `
            -Data @{ requests = $rows }
        # QUOTA-REQUEST-POLL-1: then the answer of Azure to each filed request.
        # A 202 continues without us, and nothing read it again, so the page
        # said "Pending" for ever. The engine reads each request filed in the
        # last 2 minutes - from the stored records, so a re-run goes on where
        # one stopped - and writes one quotaAnswer line for each. After the
        # result line, so the page says "filed" first.
        try { $null = Wait-VmfQuotaRequestAnswer -OutPath $OutPath }
        catch { Write-Warning "The product could not read the answers of Azure to the quota increase requests: $($_.Exception.Message)" }
    }
    [pscustomobject]@{
        Submitted = @($out | Where-Object Status -in @('APPROVED', 'PENDING'))
        # NOACCESS is a request the product did not make: it is not filed, so it counts as failed.
        Failed    = @($out | Where-Object Status -in @('FAILED', 'NOACCESS'))
        All       = $out
    }
}
