function Test-VmfQuota {
    <#
    .SYNOPSIS
        Quota and reservations (architecture section 10): build the demand matrix
        from a plan, scan SKU restrictions, verify quota headroom, and persist
        one capacity-claim document per (wave x region x zone x size).
    .DESCRIPTION
        Claim states produced here: QUOTA_VERIFIED or BLOCKED.
        ODCR creation (RESERVED) is Phase 3. The quota family is taken from the
        SKU catalog's Family property and cross-checked against the usage
        listing - NEVER derived from the size name (a confirmed platform
        quirk: s-suffix v6 sizes can bill under the general d_v6 family, and
        the listing itself has a known bug). A family missing from the usage
        listing is recorded verbatim with a warning, not guessed at.
        REGIONAL-VCPU-QUOTA-1: the subscription's Total Regional vCPUs quota
        ('cores' in the same usage listing) is judged too, against the vCPUs
        the machines ADD - each one's new size less its old size, never below
        0. A record whose machines add vCPUs the region does not have is
        BLOCKED with 'regional-quota-shortfall'.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$OutPath,
        # QUOTA-BUTTON-1: check ONE wave's records, for the wave editor's button.
        # The family totals are still worked out over the whole plan, so a wave
        # checked alone gets exactly the answer a whole-plan check gives it.
        [Parameter()][string]$Wave,
        # QUOTA-STARTED-TWICE-1: Start-VmfWave asks this. A machine that will
        # continue the move it started (Get-VmfContinuingMoves) gets no record
        # and is never judged - it finishes its move, or fails at its resize
        # and rolls back. Once Azure changed its size (Test-VmfMoveResized), the
        # usage figure counts it, so it is not counted again. Before that, its
        # need is added to its family's total FIRST, so the machines not
        # started are judged against what is left. Reserve does not ask this,
        # so a reservation still holds a slot for such a machine.
        [Parameter()][switch]$LeaveOutStarted
    )

    $plan = Read-VmfPlanFile -Path $PlanPath

    Initialize-VmfStore -RunPath $OutPath

    # A machine that has MIGRATED already runs on its target and is in the
    # usage figure, and a SKIPPED one will not move. Counting either again
    # asks for capacity twice - a false shortfall, or a reservation that bills
    # for machines that will never use it. Found by RETRY-SERIES-1's review: a
    # wave checked again after one machine's target changed counted its
    # migrated machines. Only the state documents that exist are read.
    # RESERVE-COVER-1: the same list the Reserved gate leaves out, from one
    # function, so the gate never asks for a record this check did not write.
    $done = @{}
    # GPU-SCOPE-1: nor a machine outside the scope of this tool whose move has
    # not started - PRECHECK stops it untouched (Get-VmfLeftOutVmIds).
    foreach ($id in @(Get-VmfLeftOutVmIds -RunPath $OutPath -Entries @($plan.entries))) { $done[$id] = $true }
    # QUOTA-STARTED-TWICE-1: the machines that continue a move are left out of
    # the cells; the ones not yet on their target size still count in their
    # family's total, from the size their move started with.
    $continuingNeed = [System.Collections.Generic.List[object]]::new()
    if ($LeaveOutStarted) {
        $planById = @{}
        foreach ($e in @($plan.entries)) { $planById[[string]$e.vmId] = $e }
        foreach ($move in @(Get-VmfContinuingMoves -RunPath $OutPath)) {
            $done[$move.VmId] = $true
            $e = $planById[$move.VmId]
            if ($move.Resized -or -not $e) { continue }
            $continuingNeed.Add([pscustomobject]@{
                VmId         = $move.VmId
                Subscription = (Get-VmfSubscriptionId -ResourceId $move.VmId)
                Region       = [string]$e.assessment.location
                Size         = $(if ($move.Size) { $move.Size } else { [string]$e.target.size })
            })
        }
    }
    $executable = @($plan.entries | Where-Object { $_.path -eq 'A' -and $_.target.size -and -not $done.ContainsKey([string]$_.vmId) })
    # CRG-MOVE-DEMAND-1: the groups this migration made. A machine the
    # assessment found in any OTHER group stays in it through the move
    # (CRG-MOVE-1), so the wave reserves no place for it - by the one rule,
    # Test-VmfEntryReservable, which CONVERTING asks too.
    $productGroupIds = @(Get-VmfProductReservationGroupIds -RunPath $OutPath)

    # Demand matrix: wave x SUBSCRIPTION x region x zone x size.
    #
    # ODCR-SUB-1: subscription used to be absent from this key, so machines in
    # different subscriptions were summed into one cell and one reservation was
    # created for all of them - in whichever subscription held the capacity
    # resource group. A capacity reservation group is subscription-scoped, so
    # every machine outside that subscription silently fell back to unreserved
    # general capacity while the customer paid for slots nothing could consume.
    # Quota is per-subscription too, so a merged cell could not be verified
    # against anything real either.
    $cells = @($executable | Group-Object {
        '{0}|{1}|{2}|{3}|{4}' -f $_.wave, (Get-VmfSubscriptionId -ResourceId $_.vmId),
                                 $_.assessment.location, $_.target.zone, $_.target.size })

    # ODCR-FAMILY-1: QUOTA IS PER FAMILY, AND A PLAN CAN HOLD SEVERAL SIZES
    # THAT BILL TO ONE.
    #
    # Noted 2026-09-17: a wave can hold several VM families, and each needs
    # its own check. The cells above already split a wave by
    # subscription, region, zone and SIZE, so several machine types do get
    # several checks - and every one of them was then compared, on its own,
    # against the SAME live headroom. Two cells that each fit could both answer
    # QUOTA_VERIFIED while their sum did not fit, and the wave met
    # QuotaExceeded partway through with machines already stopped.
    #
    # CLAUDE.md makes it likelier than it looks: 's'-suffix v6 sizes bill under
    # the general d_v6 family, so two sizes that look unrelated share a pool.
    # The family is read from the SKU CATALOG and never from the name, which is
    # what makes this answerable at all.
    #
    # SO THE DEMAND IS TOTALLED PER FAMILY FIRST, in a pass of its own, and
    # every cell is then judged against its family's WHOLE ask. Totalling first
    # rather than accumulating cell by cell is deliberate: a running total
    # blames whichever cell happens to come last, and the answer would depend
    # on the order the groups came out. A family either fits or it does not,
    # and every cell in it deserves the same answer.
    # ZONES-1: per subscription - restrictions and zone numbers belong to
    # one, and a plan can hold machines of several.
    $catalogCache = @{}
    function Get-CachedCatalog {
        param([string]$Region, [string]$Subscription)
        $cacheKey = "$Subscription|$Region"
        if (-not $catalogCache.ContainsKey($cacheKey)) {
            $catalogCache[$cacheKey] = Invoke-VmfAzOperation -Name "skuCatalog:$Subscription/$Region" -RunPath $OutPath -Operation {
                $listed = @(Get-VmfSkuCatalog -Location $Region -SubscriptionId $Subscription)
                # RESERVE-RECHECK-1 review: an EMPTY size list is Azure not
                # answering, never "Azure does not offer the size". Read as
                # the second, it wrote BLOCKED (size-missing) over a good
                # record. It stops the check before any record is written.
                if ($listed.Count -eq 0) {
                    throw "Azure returned no virtual machine sizes for region '$Region' in subscription '$Subscription'. The quota cannot be checked, and no quota record was written."
                }
                $listed
            }
        }
        $catalogCache[$cacheKey]
    }

    # 'subscription|region|family' -> @{ Vcpus = n; Sizes = @(...) }
    $familyAsk = @{}
    # QUOTA-STARTED-TWICE-1: a machine that continues its move and is not on
    # its target size yet asks for its size's vCPUs here, one instance each.
    $askItems = @(foreach ($cell in $cells) {
            $parts = $cell.Name -split '\|'
            [pscustomobject]@{ Sub = $parts[1]; Region = $parts[2]; Size = $parts[4]; Count = $cell.Count; VmId = $null }
        }
        foreach ($need in $continuingNeed) {
            [pscustomobject]@{ Sub = $need.Subscription; Region = $need.Region; Size = $need.Size; Count = 1; VmId = $need.VmId }
        })
    foreach ($item in $askItems) {
        $cellSub = $item.Sub; $cellRegion = $item.Region; $cellSize = $item.Size
        if (-not $cellSub -or -not $cellSize) { continue }
        $entry = @(Get-CachedCatalog -Region $cellRegion -Subscription $cellSub) | Where-Object { $_.Name -eq $cellSize } | Select-Object -First 1
        $family = if ($entry) { [string]$entry.Family } else { '' }
        if (-not $family) {
            # RESERVE-RECHECK-1 second review: a machine that continues its
            # move cannot refuse the start, so a size the list does not show
            # is said, never counted as zero without a word.
            if ($item.VmId) {
                Write-VmfStepLine -RunPath $OutPath -Step 'capacity' -Outcome warn -VmId $item.VmId `
                    -Detail "machine '$(($item.VmId -split '/')[-1])' continues its move on $cellSize, which the size list of region '$cellRegion' does not show with a quota family - its quota was not counted"
            }
            continue
        }
        $perVm = @($entry.Capabilities) | Where-Object { $_.Name -eq 'vCPUs' } | Select-Object -First 1
        $key = '{0}|{1}|{2}' -f $cellSub, $cellRegion, $family
        if (-not $familyAsk.ContainsKey($key)) {
            $familyAsk[$key] = [pscustomobject]@{ Vcpus = 0; Sizes = [System.Collections.Generic.List[string]]::new() }
        }
        $familyAsk[$key].Vcpus += ($item.Count * [int]$(if ($perVm) { $perVm.Value } else { 0 }))
        if (-not $familyAsk[$key].Sizes.Contains($cellSize)) { $familyAsk[$key].Sizes.Add($cellSize) }
    }

    # REGIONAL-VCPU-QUOTA-1: AZURE HOLDS A SECOND vCPU QUOTA, FOR ALL SIZES.
    #
    # Beside each family's quota, a subscription has one for every vCPU in the
    # region: "Total Regional vCPUs", 'cores' in the same usage list. Nothing
    # read it, so a plan whose families each fitted could ask for more vCPUs
    # in all than the region allows - and Azure refused the resize or the
    # rebuild with the machine stopped, which rolled it back inside its change
    # window.
    #
    # WHAT A MACHINE ASKS OF IT IS WHAT IT ADDS. Azure counts a machine's old
    # size, deallocated or not, until the move gives it back: a resize changes
    # the size in place, and a rebuild deletes the old definition before it
    # makes the new one. So a machine asks for its new size's vCPUs less its
    # old size's. A family total needs no such step, because the old size
    # bills to another family.
    #
    # ONE MACHINE'S SMALLER SIZE IS NEVER LENT TO ANOTHER. Each machine's ask
    # is never below 0. A wave runs machines in an order nobody knows, so a
    # machine that grows can run before the one that shrinks, and set against
    # each other they would promise vCPUs the region does not have yet.
    #
    # An old size the size list does not show gives back nothing: that asks
    # for more, which is the safe side for the machine, and the record says so.
    #
    # A WAVE THAT RESERVES ASKS FOR THE WHOLE NEW SIZE. Microsoft: a capacity
    # reservation needs quota as a VM create does, and it is made before the
    # wave, while every old machine still counts. So a machine a reservation
    # holds (Test-VmfEntryReservable) in a Reserved wave gives nothing back at
    # that time. A machine in an availability set moves on general capacity,
    # and asks for what it adds.
    function Get-CachedSizeVcpus {
        param([string]$Region, [string]$Subscription, [string]$SizeName)
        if (-not $SizeName) { return $null }
        $sku = @(Get-CachedCatalog -Region $Region -Subscription $Subscription) | Where-Object { $_.Name -eq $SizeName } | Select-Object -First 1
        if (-not $sku) { return $null }
        $cap = @($sku.Capabilities) | Where-Object { $_.Name -eq 'vCPUs' } | Select-Object -First 1
        if ($cap) { [int]$cap.Value } else { 0 }
    }
    # 'subscription|region' -> the vCPUs the whole plan adds there.
    $regionAsk = @{}
    # cell name -> what that cell's machines add, and the old sizes not shown.
    $cellRegionAsk = @{}
    $cellUnknownSource = @{}
    foreach ($cell in $cells) {
        $parts = $cell.Name -split '\|'
        $askSub = $parts[1]; $askRegion = $parts[2]; $askSize = $parts[4]
        if (-not $askSub -or -not $askSize) { continue }
        # A size the region does not offer is BLOCKED on its own, and is not
        # counted - as the family total does not count it.
        $newVcpus = Get-CachedSizeVcpus -Region $askRegion -Subscription $askSub -SizeName $askSize
        if ($null -eq $newVcpus) { continue }
        $adds = 0
        $unknown = [System.Collections.Generic.List[string]]::new()
        foreach ($member in @($cell.Group)) {
            $reserves = ((Get-VmfCapacityGate -PlanEntry $member) -eq 'Reserved') -and (Test-VmfEntryReservable -Entry $member -ProductGroupIds $productGroupIds)
            if ($reserves) { $adds += $newVcpus; continue }
            $oldSize = [string]$member.assessment.sourceSize
            $oldVcpus = Get-CachedSizeVcpus -Region $askRegion -Subscription $askSub -SizeName $oldSize
            if ($null -eq $oldVcpus) {
                $oldVcpus = 0
                $shown = if ($oldSize) { $oldSize } else { '(none recorded)' }
                if (-not $unknown.Contains($shown)) { $unknown.Add($shown) }
            }
            $adds += [math]::Max(0, $newVcpus - $oldVcpus)
        }
        $cellRegionAsk[$cell.Name] = $adds
        $cellUnknownSource[$cell.Name] = $unknown
        $regionKey = "$askSub|$askRegion"
        $regionAsk[$regionKey] = [int]$regionAsk[$regionKey] + $adds
    }
    # QUOTA-STARTED-TWICE-1's machines: one not on its new size yet may be in
    # the middle of a rebuild, with its old definition gone and its old vCPUs
    # no longer counted. So nothing is given back for it - its whole new size
    # is counted first, and the machines not started are judged against what
    # is left.
    foreach ($need in $continuingNeed) {
        if (-not $need.Subscription -or -not $need.Size) { continue }
        $newVcpus = Get-CachedSizeVcpus -Region $need.Region -Subscription $need.Subscription -SizeName $need.Size
        if ($null -eq $newVcpus) { continue }
        $regionKey = "$($need.Subscription)|$($need.Region)"
        $regionAsk[$regionKey] = [int]$regionAsk[$regionKey] + $newVcpus
    }

    # One lookup per distinct size+region+os, not per claim.
    $priceCache = @{}
    # Captured under its own name: the loop below assigns $wave, and PowerShell
    # variable names ignore case, so that line would overwrite this parameter.
    $onlyWave = $Wave
    # RESERVE-RECHECK-1 second review: every usage list this check needs is
    # read BEFORE any record is written. Read cell by cell, a second region
    # that gave nothing stopped the check after the first region's records
    # were already written over.
    $usageCache = @{}
    # QUOTA-ROW-TWICE-1: ONE CHECK IS ONE READING, SO ONE TIME. Every usage
    # list is read here, before any record is built, and every record of this
    # call carries this one checkedUtc. Taken per record, the times differed
    # by milliseconds, and the Migrations page - which shows the reading of
    # the newest check of a family (newestCheckOf) - could not tell the
    # records of one check from several checks.
    $checkedUtc = (Get-Date).ToUniversalTime().ToString('o')
    foreach ($cell in $cells) {
        $parts = $cell.Name -split '\|'
        if ($onlyWave -and $parts[0] -ne $onlyWave) { continue }
        $usageSub = $parts[1]; $usageRegion = $parts[2]
        if (-not $usageSub) { continue }
        $usageKey = "$usageSub|$usageRegion"
        if ($usageCache.ContainsKey($usageKey)) { continue }
        $usageCache[$usageKey] = Invoke-VmfAzOperation -Name "vmUsage:$usageSub/$usageRegion" -RunPath $OutPath -Operation {
            $read = @(Get-VmfVmUsage -SubscriptionId $usageSub -Location $usageRegion)
            # RESERVE-RECHECK-1 review: an EMPTY usage list is Azure not
            # answering. Read as "family not listed", it wrote QUOTA_VERIFIED
            # from no data at all.
            if ($read.Count -eq 0) {
                throw "Azure returned no quota usage for region '$usageRegion' in subscription '$usageSub'. The quota cannot be checked, and no quota record was written."
            }
            $read
        }
    }
    # QUOTA-PREVIEW-1: KNOW THE ACCESS AT PLAN TIME. Request an increase was
    # the first place a missing grant showed, which is too late for a request
    # Azure can take days to answer. A quota belongs to a subscription, and a role on a
    # resource group never reaches it (Azure RBAC scope inheritance is downward
    # only), so a quota too low asks Azure, once per subscription, what THIS
    # identity may do there - the effective-permissions read the pre-move check
    # makes - against the quota actions of data/rbac-actions.json. A read that
    # fails is 'unknown', never a yes or a no.
    $accessCache = @{}
    function Get-CachedQuotaAccess {
        param([string]$Subscription)
        if (-not $accessCache.ContainsKey($Subscription)) {
            $answer = try {
                $perms = Invoke-VmfAzOperation -Name "quotaAccess:$Subscription" -RunPath $OutPath -Operation {
                    Get-VmfEffectivePermissions -Scope "/subscriptions/$Subscription"
                }
                Get-VmfQuotaRequestAccess -Permissions @($perms)
            }
            catch { 'unknown' }
            $accessCache[$Subscription] = $answer
        }
        $accessCache[$Subscription]
    }
    $claims = foreach ($cell in $cells) {
        $parts = $cell.Name -split '\|'
        $wave = $parts[0]; $subscriptionId = $parts[1]; $region = $parts[2]
        if ($onlyWave -and $wave -ne $onlyWave) { continue }
        $zone = if ($parts[3]) { $parts[3] } else { $null }
        $size = $parts[4]
        if (-not $subscriptionId) {
            # A machine whose id carries no subscription cannot be reserved for
            # and cannot have its quota checked. Refusing beats guessing at the
            # signed-in one, which is the defect this key change fixes.
            throw "Cannot build a quota record for wave '$wave': a machine in it has a resource id with no subscription ($(@($cell.Group)[0].vmId)). Re-run the assessment - a plan entry without a full resource id cannot be migrated."
        }
        # CAPRG-1: where a reservation for this cell goes - the resource group
        # its own machines are already in. Derived here, from the same plan
        # entries the subscription comes from, so nobody has to nominate one.
        $cellResourceGroup = Select-VmfCellResourceGroup -VmIds @($cell.Group | ForEach-Object { $_.vmId })
        if (-not $cellResourceGroup) {
            throw "Cannot build a quota record for wave '$wave': a machine in it has a resource id with no resource group ($(@($cell.Group)[0].vmId)). Re-run the assessment - a plan entry without a full resource id cannot be migrated."
        }
        $instances = $cell.Count
        # CAP-2: Azure cannot associate AvSet members to capacity reservations.
        # They still draw (general) quota - instances keeps driving the quota
        # check - but reserving their slots would double-count the family
        # (unusable reserved cores + their general cores; REH-1 jammed a
        # 10-core family exactly this way). Only non-AvSet demand is reservable.
        $avsetMembers = @($cell.Group | Where-Object {
            $_.assessment.PSObject.Properties['availabilitySetId'] -and [string]$_.assessment.availabilitySetId
        }).Count
        # CRG-MOVE-DEMAND-1: and a machine that stays in its own capacity
        # reservation group. A place for it would bill at the size's rate, and
        # take quota, until the wave releases it - and the machine never uses
        # it. The reserved count is the machines the one rule counts, so it is
        # exactly the machines CONVERTING lets join the wave's group.
        $reservableMembers = @($cell.Group | Where-Object { Test-VmfEntryReservable -Entry $_ -ProductGroupIds $productGroupIds })
        $reservable = $reservableMembers.Count
        $ownGroupVmIds = @($cell.Group | Where-Object {
                -not ($_.assessment.PSObject.Properties['availabilitySetId'] -and [string]$_.assessment.availabilitySetId) -and
                -not (Test-VmfEntryReservable -Entry $_ -ProductGroupIds $productGroupIds) } | ForEach-Object { [string]$_.vmId })

        $skuEntry = @(Get-CachedCatalog -Region $region -Subscription $subscriptionId) | Where-Object { $_.Name -eq $size } | Select-Object -First 1

        $state = 'FORECAST'; $notes = [System.Collections.Generic.List[string]]::new()
        $vmFamily = $null; $vcpusPer = 0; $quotaLimit = $null; $quotaUsed = $null
        $quotaName = $null; $requestAccess = $null
        $familyVcpus = $null
        $blockReason = $null
        # REGIONAL-VCPU-QUOTA-1: the region's figures, read from the same usage
        # list, for every record of the region.
        $regionNeeded = [int]$regionAsk["$subscriptionId|$region"]
        $regionalUsage = @($usageCache["$subscriptionId|$region"]) | Where-Object { $_ -and [string]$_.Name.Value -eq $script:VmfRegionalQuotaResourceName } | Select-Object -First 1
        $regionalLimit = $null; $regionalUsed = $null
        # REGIONAL-QUOTA-WAVES-1: what THIS record's machines add to the region,
        # beside the whole plan's total - the confirmation's line for each wave.
        $regionalAdds = if ($cellRegionAsk.ContainsKey($cell.Name)) { [int]$cellRegionAsk[$cell.Name] } else { $null }
        # REGIONAL-QUOTA-BOTH-1: whether the region is short for THIS record,
        # whatever its blockReason. Null until it is judged.
        $regionalShort = $null
        if ($regionalUsage) { $regionalLimit = [int]$regionalUsage.Limit; $regionalUsed = [int]$regionalUsage.CurrentValue }

        if (-not $skuEntry) {
            $state = 'BLOCKED'; $blockReason = 'size-missing'
            $notes.Add("size '$size' not present in region '$region'")
        }
        else {
            $vmFamily = [string]$skuEntry.Family
            $vcpuCap = @($skuEntry.Capabilities) | Where-Object { $_.Name -eq 'vCPUs' } | Select-Object -First 1
            if ($vcpuCap) { $vcpusPer = [int]$vcpuCap.Value }
            # QUOTA-FAMILY-1: the family total travels WITH the record, so the
            # dashboard shows the number this check judged rather than adding up
            # the records it can see - a finished wave's records are never
            # rewritten, and a page sum counted its moved machines for ever.
            $familyTotal = $familyAsk['{0}|{1}|{2}' -f $subscriptionId, $region, $vmFamily]
            if ($vmFamily -and $familyTotal) { $familyVcpus = [int]$familyTotal.Vcpus }

            # Restriction scan (subscription/zone restrictions from the catalog)
            $restrictions = @($skuEntry.Restrictions)
            $regionBlocked = $restrictions | Where-Object { $_.Type -eq 'Location' } | Select-Object -First 1
            if ($regionBlocked) {
                $state = 'BLOCKED'; $blockReason = 'sku-restricted'
                $notes.Add("SKU restricted in region: $($regionBlocked.ReasonCode)")
            }
            # ZONES-1: the same rule PRECHECK asks - a restriction on the zone, or
            # a size the region offers only in its other zones.
            elseif ($zone -and (Test-VmfSizeInZone -SkuEntry $skuEntry -Zone $zone -Location $region) -eq $false) {
                $state = 'BLOCKED'; $blockReason = 'sku-restricted'
                $zoneCode = Get-VmfZoneRestrictionCode -SkuEntry $skuEntry -Zone $zone
                $notes.Add($(if ($zoneCode) { "SKU restricted in zone ${zone}: $zoneCode" } else { "size not offered in zone $zone of region '$region'" }))
            }
            else {
                # Quota verification against usage, matched by catalog-provided family
                # ODCR-SUB-1: read usage in the CELL'S subscription. This was
                # Get-AzVMUsage against the ambient context, so quota for a
                # machine in subscription B was verified against whichever
                # subscription the operator happened to be signed in to.
                $usage = $usageCache["$subscriptionId|$region"]

                $familyUsage = @($usage) | Where-Object { $_.Name.Value -eq $vmFamily } | Select-Object -First 1
                # ODCR-FAMILY-1: what THIS cell asks for, and what the whole
                # FAMILY asks for across the plan. The pool is the family's, so
                # the second number is the one that decides.
                $needed = $instances * $vcpusPer
                $askKey = '{0}|{1}|{2}' -f $subscriptionId, $region, $vmFamily
                $ask = $familyAsk[$askKey]
                $familyNeeded = if ($ask) { [int]$ask.Vcpus } else { $needed }
                $sharers = @(if ($ask) { $ask.Sizes | Where-Object { $_ -ne $size } })
                if ($familyUsage) {
                    $quotaLimit = [int]$familyUsage.Limit
                    $quotaUsed = [int]$familyUsage.CurrentValue
                    # QUOTA-PREVIEW-1: Azure's own name for the quota - the Quota column.
                    if ($familyUsage.Name -and $familyUsage.Name.PSObject.Properties['LocalizedValue'] -and [string]$familyUsage.Name.LocalizedValue) {
                        $quotaName = [string]$familyUsage.Name.LocalizedValue
                    }
                    $headroom = $quotaLimit - $quotaUsed
                    if ($headroom -ge $familyNeeded) { $state = 'QUOTA_VERIFIED' }
                    else {
                        $state = 'BLOCKED'; $blockReason = 'quota-shortfall'
                        # NAME THE SIBLINGS. A cell blocked by a size it does
                        # not mention is a cell nobody can act on: the operator
                        # reads 4 vCPUs of demand against headroom of 8 and has
                        # no way to know what took the rest.
                        $withOthers = if ($sharers.Count) {
                            " - this plan asks for $needed here and $familyNeeded in total for the family, shared with $($sharers -join ', ')"
                        }
                        else { '' }
                        $notes.Add("quota shortfall: family $vmFamily needs $familyNeeded vCPUs, headroom $headroom$withOthers")
                        $requestAccess = Get-CachedQuotaAccess -Subscription $subscriptionId
                        if ($requestAccess -eq 'unknown') {
                            $notes.Add("The product could not read its access on subscription $subscriptionId. The request can fail if the product does not have this access.")
                        }
                    }
                }
                else {
                    # Known listing bug (s-suffix v6): family absent from usage output.
                    $state = 'QUOTA_VERIFIED'
                    $notes.Add("family '$vmFamily' not in usage listing (known platform bug) - verified empirically on first deployment; watch for QuotaExceeded naming the real family")
                }

                # REGIONAL-VCPU-QUOTA-1: then the Total Regional vCPUs. Only a
                # cell whose machines ADD vCPUs can be refused by it - a move
                # that adds none passes whatever the others ask. A family that
                # is short keeps its own reason, because Request an increase
                # acts on that one; the regional shortfall is named beside it
                # and recorded in regionalShort, and Request an increase asks
                # for both in the same press (REGIONAL-QUOTA-BOTH-1).
                $cellAdds = [int]$cellRegionAsk[$cell.Name]
                if ($regionalUsage) {
                    $regionalHeadroom = $regionalLimit - $regionalUsed
                    # REGIONAL-QUOTA-BOTH-1: the answer is recorded on its own,
                    # so a record that keeps the family reason still says the
                    # region is short - and Request an increase asks for both
                    # quotas in one press, not one after the other.
                    $regionalShort = ($regionalHeadroom -lt $regionNeeded -and $cellAdds -gt 0)
                    if ($regionalShort) {
                        if ($state -eq 'QUOTA_VERIFIED') {
                            $state = 'BLOCKED'; $blockReason = 'regional-quota-shortfall'
                            # REGIONAL-QUOTA-REQUEST-1: Request an increase asks
                            # for this quota too, so its access is read as a
                            # family's is - at the subscription the quota belongs to.
                            $requestAccess = Get-CachedQuotaAccess -Subscription $subscriptionId
                            if ($requestAccess -eq 'unknown') {
                                $notes.Add("The product could not read its access on subscription $subscriptionId. The request can fail if the product does not have this access.")
                            }
                        }
                        $notes.Add("quota shortfall: Total Regional vCPUs in region $region needs $regionNeeded vCPUs, headroom $regionalHeadroom - the machines of this record add $cellAdds")
                    }
                    elseif ($regionalHeadroom -lt $regionNeeded) {
                        $notes.Add("Total Regional vCPUs in region $region is short for this plan (needs $regionNeeded vCPUs, headroom $regionalHeadroom), but the machines of this record add no vCPUs, so it does not stop them")
                    }
                    $unknownOld = @($cellUnknownSource[$cell.Name])
                    if ($unknownOld.Count) {
                        $notes.Add("the size list of region $region does not show $($unknownOld -join ', '), so the vCPUs those machines give back are not counted against Total Regional vCPUs")
                    }
                }
                else {
                    $notes.Add("Total Regional vCPUs ('cores') is not in the usage listing of region $region - the regional quota was not checked")
                }
            }
        }

        # MANUAL-REVIEW-1: the approved words, with the singular forms for one.
        $ofAll = "of $instances $(if ($instances -eq 1) { 'machine' } else { 'machines' })"
        if ($avsetMembers -eq 1) {
            $notes.Add("1 $ofAll is in an availability set. Azure does not allow an on-demand capacity reservation for it, so it moves without one.")
        }
        elseif ($avsetMembers -gt 1) {
            $notes.Add("$avsetMembers $ofAll are in an availability set. Azure does not allow an on-demand capacity reservation for them, so they move without one.")
        }
        $ownNames = (@($ownGroupVmIds | ForEach-Object { ($_ -split '/')[-1] })) -join ', '
        if ($ownGroupVmIds.Count -eq 1) {
            $notes.Add("1 $ofAll stays in its own capacity reservation group ($ownNames). The move keeps it in its group. The on-demand capacity reservation of the wave holds no place for it.")
        }
        elseif ($ownGroupVmIds.Count -gt 1) {
            $notes.Add("$($ownGroupVmIds.Count) $ofAll stay in their own capacity reservation group ($ownNames). The move keeps each one in its group. The on-demand capacity reservation of the wave holds no place for them.")
        }
        # EVAL-M8: built by New-VmfCapacityClaim, which is pure and therefore
        # testable against the schema without Azure. Assembling the document
        # inline here is how it came to violate its own contract in three ways
        # while a hand-written sample kept the contract test green.
        # ODCR-UX-1: the price, cached per (size, region, os) - the same cell
        # repeats across waves and the list does not change between them.
        $osType = [string](@($cell.Group)[0].assessment.os)
        $priceKey = "$($size)|$($region)|$($osType)"
        if (-not $priceCache.ContainsKey($priceKey)) {
            $priceCache[$priceKey] = Invoke-VmfAzOperation -Name "retailPrice:$size@$region" -RunPath $OutPath -Operation {
                Get-VmfRetailPrice -Size $size -Region $region -OsType $osType
            }
        }
        $hourly = $priceCache[$priceKey]

        $claim = New-VmfCapacityClaim -RunId ([string]$plan.assessmentRunId) -Wave $wave `
            -HourlyPerInstance $hourly -Currency $(if ($null -ne $hourly) { 'USD' } else { $null }) `
            -SubscriptionId $subscriptionId -ResourceGroup $cellResourceGroup `
            -Region $region -Zone $zone -Size $size -VmFamily $vmFamily `
            -State $state -BlockReason $blockReason `
            -Instances $instances -ReservableInstances $reservable -OwnGroupVmIds $ownGroupVmIds `
            -Vcpus ([int]($instances * $vcpusPer)) -FamilyVcpus $familyVcpus `
            -QuotaLimit $quotaLimit -QuotaUsed $quotaUsed -CheckedUtc $checkedUtc -QuotaName $quotaName -RequestAccess $requestAccess `
            -RegionalVcpus $regionNeeded -RegionalLimit $regionalLimit -RegionalUsed $regionalUsed `
            -RegionalAdds $regionalAdds -RegionalShort $regionalShort -Notes @($notes)
        # The file name carries the subscription too: without it, two cells that
        # differ only by subscription wrote to the SAME path and the second
        # silently overwrote the first - losing a whole subscription's demand.
        # CLAIM-NAME-1: and a code, so wave_1 and wave-1 never share a file
        # either. A record written under the old name is still this cell's
        # when it says so (Resolve-VmfClaimFile), and is written in place.
        $resolved = Resolve-VmfClaimFile -RunPath $OutPath -Wave $wave -SubscriptionId $subscriptionId `
            -Region $region -Zone $zone -Size $size
        $claimFile = $resolved.Name
        # QUOTA-BUTTON-1 found this: a record that stands for something that
        # EXISTS IN AZURE - a reservation being made, held, in use, or released
        # and kept as history - is never overwritten by a quota check. Writing a
        # fresh QUOTA_VERIFIED over a RESERVED record erases the only thing that
        # says a reservation exists, and it goes on billing with nothing in the
        # product pointing at it. Start-VmfWave re-ran this whole check when
        # ONE wave had no records, so every other wave's reservation was exposed.
        # (RESERVE-COVER-2: every start now checks only its own wave; the
        # hosted plan operation still checks them all.)
        #
        # WAVE-EDIT-RESERVE-1: except a RELEASED record, when somebody checks
        # the quota of THAT wave. It bills nothing, and kept it stops the wave
        # starting and stops it being reserved again (the start check reads it
        # as not ready; a reserve takes only quota checks) - so after a Release
        # on the wave card, Check the quota is the rollback. The activity log
        # keeps what it recorded. A check of every wave (the hosted plan
        # operation's) still keeps every other wave's released record as
        # history. RESERVE-COVER-1: a Reserved wave's start, and Reserve, run a
        # check of THAT wave when a machine has no record, so they too replace
        # its released records - kept under capacity-history, never lost.
        # RESERVE-COVER-2: so does a BestEffort wave's start, which checked
        # every wave of the plan before.
        # RESERVE-COVER-1 review: read WITH its version, and write over it only
        # if nobody changed it since. The start and Reserve now run this check
        # whenever a machine has no record, so it meets a Reserve in flight more
        # often - and an ordinary write here put QUOTA_VERIFIED over a record
        # that Reserve had just made RESERVING, which then lost its own save.
        $existingRead = $resolved.Read
        $existing = if ($existingRead) { $existingRead.Claim } else { $null }
        if ($existing -and [string]$existing.state -eq 'RELEASED' -and $onlyWave) {
            Write-VmfReleasedClaimNote -RunPath $OutPath -Claim $existing -Because checked
        }
        elseif ($existing -and [string]$existing.state -in $script:VmfClaimStatesHeldInAzure) {
            Write-VmfStepLine -RunPath $OutPath -Step 'capacity' -Outcome info `
                -Detail "kept the $([string]$existing.state) record for $size in $region ($wave) - it describes an on-demand capacity reservation in Azure, and a quota check does not replace that"
            [pscustomobject]$existing
            continue
        }
        if ($existingRead) {
            try { Write-VmfClaimIfVersion -Handle $existingRead.Handle -Claim ([pscustomobject]$claim) -ExpectedVersion $existingRead.Version | Out-Null }
            catch {
                if ([string]$_.Exception.Message -notlike '409*') { throw }
                # Somebody wrote it in between. A record of a reservation stays;
                # anything else was another quota check, whose answer is this one.
                $now = Read-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$claimFile" -Depth 12
                if ($now -and [string]$now.state -in $script:VmfClaimStatesHeldInAzure) {
                    Write-VmfStepLine -RunPath $OutPath -Step 'capacity' -Outcome info `
                        -Detail "kept the $([string]$now.state) record for $size in $region ($wave) - it became an on-demand capacity reservation while the quota was checked, and a quota check does not replace that"
                    [pscustomobject]$now
                    continue
                }
                Write-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$claimFile" -Document $claim -Depth 12
            }
        }
        else { Write-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$claimFile" -Document $claim -Depth 12 }
        [pscustomobject]$claim
    }

    $blocked = @($claims | Where-Object { Test-VmfClaimBlocked -Claim $_ })
    # QUOTA-TRUTH-1: a one-wave check NAMES its wave, and says what the SAVED
    # plan holds in it. The first Azure test answered "claims=0" for a wave
    # that later migrated two machines, and nothing said why: the line did not
    # say which wave it was for, so two checks started together read each
    # other's answer, and a zero could not be told from a check that saw an
    # unsaved layout. Wave names hold no spaces, so the words stay parseable.
    $detail = "claims=$(@($claims).Count) blocked=$($blocked.Count)"
    if ($onlyWave) {
        $inWave = @($plan.entries | Where-Object { [string]$_.wave -eq $onlyWave })
        $moving = @($executable | Where-Object { [string]$_.wave -eq $onlyWave })
        $detail += " wave=$onlyWave machines=$($inWave.Count) moving=$($moving.Count)"
    }
    Write-VmfStepLine -RunPath $OutPath -Step 'capacity' -Outcome $(if ($blocked.Count -gt 0) { 'warn' } else { 'ok' }) `
        -Detail $detail

    [pscustomobject]@{
        Claims  = @($claims)
        Blocked = $blocked
    }
}
