function New-VmfWaveReservation {
    <#
    .SYNOPSIS
        Architecture section 10, RESERVED stage: create ODCRs for every
        QUOTA_VERIFIED claim of a wave. Run this T-48..24h before the wave
        window - ODCRs bill at the VM rate from creation, used or not.
    .DESCRIPTION
        One Capacity Reservation Group per (wave x region x zone), one
        reservation per size at the claim's instance quantity. Creation
        succeeding IS the SLA-backed capacity guarantee; a failed creation
        moves the claim to BLOCKED (blockReason reservation-failed)
        for the fallback ladder.

        CAPRG-1: a reservation is created in the resource group its own
        machines are already in, recorded on the claim at forecast time. A VM
        attaches to a reservation by its full resource id, so the reservation
        only has to share the machines' subscription and region - which
        resource group holds it changes nothing. So there is nothing to
        configure and nothing to pre-create.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Wave
    )

    # RESERVE-QUOTA-1, MEASURED 2026-09-21: this used to throw here, and that
    # made the Reserve capacity control IMPOSSIBLE TO USE.
    #
    # The records this needs are written when a wave is planned. But CHANGING A
    # WAVE CLEARS THEM - correctly, because they describe the wave as it was:
    #
    #   "wave layout changed ... quota check cleared for wave-1"
    #   "quota checks cleared - they described the waves as they were, and
    #    capacity is checked again before a wave starts"
    #
    # And choosing "reserved capacity" IS a change to the wave. So selecting the
    # setting was itself the act that destroyed the records reserving needs, and
    # the promised re-check happens before a wave STARTS - which is after
    # reserving, never before it. The control could not work on any install, in
    # any order.
    #
    # Deriving them here is free and safe: it reads the plan, reads the SKU
    # catalog and reads quota usage. It RESERVES NOTHING and SPENDS NOTHING -
    # the spending starts below, where it is meant to. Refusing to do a
    # read-only step and naming a command the dashboard cannot run is the
    # "workflow gap rather than a safety gate" this engine already names
    # elsewhere.
    #
    # AVSET-RESERVE-1: per WAVE, not per run. Choosing Reserved clears only
    # this wave's records, so on a run where any other wave still had records
    # this derived nothing, reserved nothing and said nothing - and the page
    # waited five minutes and said "still running".
    $readWaveClaims = {
        @(foreach ($n in @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json')) {
            $c = Read-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$n" -Depth 12
            if ($c -and $c.wave -eq $Wave) { $c }
        })
    }
    $waveClaimsNow = @(& $readWaveClaims)
    # RESERVE-COVER-1: and when SOME machines of the wave have no record. A
    # quota check that stopped half way leaves a partial set; reserving it
    # bills for the cells that exist while the wave cannot start (the start
    # refuses a machine with no record). So the missing cells are checked
    # first, and a machine still without one stops the reservation below.
    # The plan is what says which machines the wave moves. A run without a
    # readable plan is judged on its records, as before - the start's gate,
    # which refuses an unread plan, is the one that decides.
    $planEntries = $null
    try {
        $plan = Read-VmfPlanDocument -RunPath $OutPath
        if ($plan) { $planEntries = @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $Wave) }
    }
    catch { $planEntries = $null }
    $finished = if ($null -ne $planEntries) { @(Get-VmfLeftOutVmIds -RunPath $OutPath -Entries $planEntries) } else { @() }
    $findNoRecord = {
        if ($null -eq $planEntries) { return @() }
        # CRG-MOVE-DEMAND-1: read when asked - the check below can run in between.
        @(Get-VmfReservedCoverageGaps -Claims $waveClaimsNow -Entries $planEntries -FinishedVmIds $finished -ProductGroupIds @(Get-VmfProductReservationGroupIds -RunPath $OutPath) |
            Where-Object Kind -eq 'noRecord')
    }
    $noRecord = @(& $findNoRecord)
    if ($waveClaimsNow.Count -eq 0 -or $noRecord.Count -gt 0) {
        $planPath = "$OutPath/plan.json"
        Write-VmfStepLine -RunPath $OutPath -Step 'capacity' -Outcome info `
            -Detail $(if ($waveClaimsNow.Count -eq 0) { "Wave '$Wave' has no quota records. The product checks the quota now. This check reserves nothing and costs nothing." }
                      else { "$($noRecord.Count) $(if ($noRecord.Count -eq 1) { 'machine' } else { 'machines' }) of wave '$Wave' $(if ($noRecord.Count -eq 1) { 'has' } else { 'have' }) no quota record. The product checks the quota now. This check reserves nothing and costs nothing." })
        Test-VmfQuota -PlanPath $planPath -OutPath $OutPath -Wave $Wave | Out-Null
        $waveClaimsNow = @(& $readWaveClaims)
        $noRecord = @(& $findNoRecord)
    }
    if ($waveClaimsNow.Count -eq 0 -and $null -ne $planEntries -and (Resolve-VmfWaveNeedsNoCapacity -RunPath $OutPath -Entries $planEntries)) {
        # GPU-SCOPE-1 review: the quota check writes no record for these
        # machines, by design. Say that, not that Azure could not be read.
        throw ("Every machine of wave '$Wave' that is still to run is outside the scope of this tool. " +
               'So the wave needs no on-demand capacity reservation, and it starts without one.')
    }
    if ($waveClaimsNow.Count -eq 0) {
        throw ("No quota records could be derived for wave '$Wave' from $OutPath/plan.json, so there is nothing " +
               'to reserve. The wave has no machine with a target size, or Azure could not be read.')
    }
    $claimNames = @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json')

    # AVSET-RESERVE-1 review: a wave with a cell whose QUOTA check is blocked
    # cannot start, so a reservation for its other cells bills for nothing.
    # The skipped cell never reached the all-or-nothing count below, and with
    # availability-set cells judged on their quota alone this became the
    # likelier case. A cell blocked by a reservation that failed is the
    # all-or-nothing rule's, and is left to it.
    $quotaBlocked = @($waveClaimsNow | Where-Object {
        (Test-VmfClaimBlocked -Claim $_) -and [string]$_.blockReason -ne 'reservation-failed' })
    # And a record that should be reserved but does not say for how many
    # machines. Refused HERE, before anything is spent: stopping half way
    # through the loop below would skip the all-or-nothing release.
    $uncounted = @($waveClaimsNow | Where-Object {
        $_.state -eq 'QUOTA_VERIFIED' -and (Test-VmfClaimReservable -Claim $_) -and $(
            $q = (Get-VmfClaimDemandCounts -Claim $_).Reservable
            $null -eq $q -or $q -lt 1) })
    if ($quotaBlocked.Count -gt 0 -or $uncounted.Count -gt 0 -or $noRecord.Count -gt 0) {
        $cells = (@($quotaBlocked | ForEach-Object {
            "$($_.size) in $($_.region)" + $(if ($_.blockReason) { " ($($_.blockReason))" } else { '' }) }) -join ', ')
        $said = if ($noRecord.Count -gt 0) {
            # RESERVE-COVER-1: the check above ran and still wrote no record
            # for these machines - Azure could not be read for their cell.
            ("Wave '$Wave' was not reserved, because " + (Get-VmfCoverMachineList -Gaps $noRecord) +
             $(if ($noRecord.Count -eq 1) { ' has' } else { ' have' }) + ' no quota record. ' +
             'The wave cannot start without one, so an on-demand capacity reservation would bill for nothing. Check the quota again, then reserve.')
        } elseif ($quotaBlocked.Count -gt 0) {
            ("Wave '$Wave' was not reserved, because the quota check is blocked for $cells. " +
             'The wave cannot start until that is corrected, so an on-demand capacity reservation would bill for nothing. ' +
             'Correct it, check the quota again, then reserve.')
        } else {
            ("Wave '$Wave' was not reserved, because a quota record does not say how many machines it holds (" +
             (@($uncounted | ForEach-Object { "$($_.size) in $($_.region)" }) -join ', ') + '). Check the quota again, then reserve.')
        }
        Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome refused -Detail $said -Data @{ wave = $Wave }
        return [pscustomobject]@{
            Reserved = @(); Blocked = @(); Unconfirmed = @(); Released = @()
            AllOrNothing = $false; NothingReservable = $false; Refused = $said
        }
    }

    # AVSET-RESERVE-1: does this wave have ANY claim a reservation can hold -
    # whatever its state, so a second press after a cell is already RESERVED
    # is not read as "nothing to reserve"?
    # STEP-LOG-5: every line from here on goes through Write-VmfStepLine. A
    # line that cannot be written must never stop this loop: a cell left
    # RESERVING, a reservation Azure made recorded as BLOCKED, or the all or
    # nothing release below skipped, each leaves capacity that bills.
    $waveCells = 0
    $waveReservable = 0
    # CRG-MOVE-DEMAND-1: machines of the wave in their own capacity reservation group.
    $waveOwn = 0
    $markedForPass = $false
    $results = foreach ($name in $claimNames) {
        $claimRel = "capacity/$name"
        # RESERVING-STUCK-1: read with its version, so every save below is
        # refused if anybody wrote the claim in between.
        $read = Read-VmfClaimVersioned -RunPath $OutPath -Name $name
        $claim = if ($read) { $read.Claim } else { $null }
        if ($claim -and $claim.wave -eq $Wave) {
            $waveCells++
            if (Test-VmfClaimReservable -Claim $claim) { $waveReservable++ }
            $waveOwn += @(Get-VmfClaimOwnGroupVmIds -Claim $claim).Count
        }
        if (-not $claim -or $claim.wave -ne $Wave -or $claim.state -ne 'QUOTA_VERIFIED') { continue }

        # CAP-2: reserve only non-AvSet demand - the reservable count, which
        # every record holds (a record with none was refused above). A cell that is all
        # AvSet members gets NO reservation and stays QUOTA_VERIFIED. Its
        # machines move on general capacity, and the Reserved gate judges it
        # on its quota check alone (AVSET-RESERVE-1).
        # AVSET-RESERVE-1: the counts are read by the one rule the gate and
        # the page use, so a value that is not a whole number cannot mean
        # "nothing to reserve" here and "reservable" there.
        $counts = Get-VmfClaimDemandCounts -Claim $claim
        $quantity = $counts.Reservable
        # A reservable record with no count was refused above, before anything
        # was spent; this only keeps a surprise from reaching Azure.
        if ((Test-VmfClaimReservable -Claim $claim) -and ($null -eq $quantity -or $quantity -lt 1)) { continue }
        if (-not (Test-VmfClaimReservable -Claim $claim)) {
            # AVSET-RESERVE-1: said ONCE. Every press of Reserve appended it
            # again, so a claim gathered the same note over and over. Saved
            # with the version it was read at, like every other write here.
            # CRG-MOVE-DEMAND-1: or machines that stay in their own capacity
            # reservation group, which the record names.
            $ownHere = @(Get-VmfClaimOwnGroupVmIds -Claim $claim)
            $avsetNote = if ($ownHere.Count -eq 0) { 'Each machine of this size is in an availability set, so the product made no on-demand capacity reservation for it.' }
                         else { 'Each machine of this size is in an availability set or stays in its own capacity reservation group, so the product made no on-demand capacity reservation for it.' }
            if (@($claim.notes) -notcontains $avsetNote) {
                $claim.notes = @(@($claim.notes) | Where-Object { $_ }) + @($avsetNote)
                try { Write-VmfClaimIfVersion -Handle $read.Handle -Claim $claim -ExpectedVersion $read.Version | Out-Null }
                catch { if ([string]$_.Exception.Message -notlike '409*') { throw } }
            }
            Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome warn -Data @{ wave = $Wave } `
                -Detail $(if ($ownHere.Count -eq 0) {
                        "Every machine of size $($claim.size) in $($claim.region) in wave '$Wave' is in an availability set, " +
                        'so it has no on-demand capacity reservation. These machines move with no on-demand capacity reservation.'
                    } else {
                        "No machine of size $($claim.size) in $($claim.region) in wave '$Wave' uses the on-demand capacity reservation of the wave, so none is made for this size. " +
                        "$((@($ownHere | ForEach-Object { ($_ -split '/')[-1] })) -join ', ') stay in their own capacity reservation group, and the move keeps them there." +
                        $(if (@($ownHere).Count -lt [int](Get-VmfClaimDemandCounts -Claim $claim).Instances) { ' The other machines are in an availability set, and move with no on-demand capacity reservation.' } else { '' })
                    })
            continue
        }

        # ODCR-SUB-1: a reservation group is subscription-scoped, so it must be
        # created in the subscription its machines are in - and its NAME must
        # differ per subscription, or two cells of one wave would collide on a
        # name and the second would silently reuse the first's group.
        $claimSub = [string]$claim.subscriptionId
        if (-not $claimSub) {
            throw "Quota record '$name' does not say which subscription it applies to, so no on-demand capacity reservation was asked for. Check the quota of the wave again, then reserve."
        }
        # CAPRG-1: the resource group the claim's own machines are in.
        $claimRg = [string]$claim.resourceGroup
        if (-not $claimRg) {
            throw "Quota record '$name' does not say which resource group its on-demand capacity reservation goes in, so none was asked for. Check the quota of the wave again, then reserve."
        }
        $zonePart = if ($claim.zone) { "-az$($claim.zone)" } else { '' }
        # CLAIM-NAME-1: a new ask, so the names that keep two waves apart. They
        # are recorded below, before Azure is asked, and every later step reads
        # what was recorded.
        $names = Get-VmfReservationNames -Claim $claim -ForNewAsk
        $groupName = $names.GroupName

        # ODCR-VERIFY-1: say we are TRYING, before we try, and persist it.
        #
        # Creating a reservation takes minutes and can be waited on for ten, so
        # for that whole window the claim used to sit at its previous state and
        # nothing anywhere said a job was running. A person who reloaded the
        # page saw the Reserve button again and could fire a second one - which
        # on this path means paying twice for the same guarantee.
        #
        # Written to the store, not held in memory, because the thing that has
        # to survive is a page reload in somebody else's browser.
        #
        # RESERVING-STUCK-1: and WHAT we are asking for. The names used to be
        # learned only from Azure's answer, so an engine that stopped before it
        # left a claim nobody could look up or release.
        $claim.state = 'RESERVING'
        $askedUtc = (Get-Date).ToUniversalTime().ToString('o')
        $claim | Add-Member -NotePropertyName reservingSinceUtc -NotePropertyValue $askedUtc -Force
        $claim | Add-Member -NotePropertyName reservationAsked -NotePropertyValue ([ordered]@{
            groupId = $names.GroupId; reservationId = $names.ReservationId; askedUtc = $askedUtc }) -Force
        if ($claim.PSObject.Properties['reservationUnconfirmedUtc']) { $claim.PSObject.Properties.Remove('reservationUnconfirmedUtc') }
        $claim.schemaVersion = $script:VmfCapacityClaimSchemaVersion
        # A second reserve run - a second press, or a retried job - read the
        # same QUOTA_VERIFIED claim. Only one of them may write RESERVING; the
        # other would pay twice for one guarantee.
        try { $version = Write-VmfClaimIfVersion -Handle $read.Handle -Claim $claim -ExpectedVersion $read.Version }
        catch {
            if ([string]$_.Exception.Message -notlike '409*') { throw }
            Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome warn `
                -Detail "Another reserve operation changed the quota record of $($claim.size) in $($claim.region) first, so the product does not reserve it again."
            continue
        }
        # ODCR-STATUS-1: the five-minute pass reads a RESERVING claim from
        # Azure once no reserve job runs, so this run goes into the record of
        # the runs it checks - after the write it is for, before Azure is
        # asked: an engine that stops while Azure makes the reservation leaves
        # the run marked. Once per reserve. A mark that cannot be written is a
        # warning, and the hourly check of every run finds the claim.
        if (-not $markedForPass) {
            Add-VmfRunScheduleDue -RunPath $OutPath -Reason 'engine' | Out-Null
            $markedForPass = $true
        }
        Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome start `
            -Detail "reserving ${quantity}x $($claim.size) in $($claim.region)$zonePart"

        try {
            $ids = Invoke-VmfAzOperation -Name "odcr:$claimSub/$($claim.size)" -RunPath $OutPath -Operation {
                New-VmfCapacityReservation -ResourceGroupName $names.ResourceGroup -GroupName $groupName `
                    -Location $claim.region -Size $claim.size -Quantity $quantity -Zone $claim.zone `
                    -SubscriptionId $names.SubscriptionId -Tags (Get-VmfReservationTags -RunId $claim.runId -Wave $claim.wave -RunPath $OutPath)
            }
            $claim.state = 'RESERVED'
            $claim | Add-Member -NotePropertyName reservation -NotePropertyValue ([ordered]@{
                groupId = $ids.GroupId; reservationId = $ids.ReservationId
                createdUtc = (Get-Date).ToUniversalTime().ToString('o')
                releasedUtc = $null; consumedInstances = 0
            }) -Force
            # MANUAL-REVIEW-1: the hover text of the activity row, in the
            # approved words. The page reads no word of it: an odcr line with no
            # machine that does not say RELEASED shows the reserve label.
            $forWhat = "$quantity $(if ($quantity -eq 1) { 'machine' } else { 'machines' })"
            $inZone = if ($claim.zone) { ", in availability zone $($claim.zone)" } else { '' }
            Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome ok `
                -Detail "Azure holds an on-demand capacity reservation for $forWhat of $($claim.size) in $($claim.region)$inZone."
            $status = 'RESERVED'
        }
        catch {
            $said = $_.Exception.Message
            if ($said -match [regex]::Escape($script:VmfReservationUnconfirmedWords)) {
                # RESERVING-STUCK-1: Azure did not answer in time. That is not
                # a no - it can still make the reservation, and then it bills.
                # So the claim stays one that bills, marked not confirmed, and
                # is released by its names.
                $claim | Add-Member -NotePropertyName reservationUnconfirmedUtc `
                    -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
                $claim | Add-Member -NotePropertyName notes -NotePropertyValue (
                    @($claim.notes) + @("Azure did not confirm the on-demand capacity reservation: $said")) -Force
                Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome warn `
                    -Detail "Azure did not confirm the on-demand capacity reservation of $($claim.size) in $($claim.region): $said Select Release on the wave."
                $status = 'UNCONFIRMED'
            }
            else {
                $claim.state = 'BLOCKED'
                $claim | Add-Member -NotePropertyName blockReason -NotePropertyValue 'reservation-failed' -Force
                $claim | Add-Member -NotePropertyName notes -NotePropertyValue (
                    @($claim.notes) + @("Azure did not make the on-demand capacity reservation: $said")) -Force
                Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome fail `
                    -Detail "Azure did not make the on-demand capacity reservation of $($claim.size) in $($claim.region): $said"
                $status = 'BLOCKED'
            }
        }

        # RESERVING-STUCK-1: a person may have released this claim while Azure
        # was still making it. Writing our answer over RELEASED would bring back
        # a record of capacity that is gone - or, if Azure finished after the
        # release, leave a reservation that bills with no record. So the answer
        # is saved only if the claim is as we left it; if not, it is left as it
        # is, and what Azure made is released too.
        $savedOver = $false
        try { Write-VmfClaimIfVersion -Handle $read.Handle -Claim $claim -ExpectedVersion $version | Out-Null }
        catch {
            if ([string]$_.Exception.Message -notlike '409*') { throw }
            $savedOver = $true
        }
        if ($savedOver) {
            $stored = Read-VmfStoreJson -RunPath $OutPath -RelPath $claimRel -Depth 12
            $nowState = if ($stored) { [string]$stored.state } else { 'gone' }
            Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome warn `
                -Detail "Another operation changed the quota record of $($claim.size) in $($claim.region) while Azure made the on-demand capacity reservation, so the product leaves the record as it is."
            if ($status -ne 'BLOCKED') {
                try {
                    Invoke-VmfAzOperation -Name 'odcrRelease' -RunPath $OutPath -Operation {
                        Remove-VmfCapacityReservation -ResourceGroupName $names.ResourceGroup `
                            -GroupName $groupName -ReservationName $names.ReservationName -SubscriptionId $names.SubscriptionId
                    } | Out-Null
                }
                catch {
                    # MANUAL-REVIEW-1 review: the quota record changed (RELEASED
                    # or gone), so Release on the wave does not find this one.
                    Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome fail `
                        -Detail ("Azure did not release the on-demand capacity reservation $($names.ReservationId), and it can still bill: $($_.Exception.Message). " +
                                 'The product has no record of it, so Release on the wave does not find it. ' +
                                 'Delete it in Azure. It is in the resource group of its machines, with the tag vmfCapacityReservation=true.')
                }
            }
            # RESERVE-COVER-1 review: this cell is not held, so it counts for
            # all or nothing. Left out, the other cells stayed RESERVED and
            # billed for a wave that could not start.
            [pscustomobject]@{ Size = $claim.size; Region = $claim.region; Zone = $claim.zone; Status = 'LOST' }
            continue
        }
        [pscustomobject]@{ Size = $claim.size; Region = $claim.region; Zone = $claim.zone; Status = $status }
    }

    # AVSET-RESERVE-1: the ONE answer to "was there anything to reserve?" when
    # there was not - every claim of the wave is availability-set machines
    # only. Written once per run, after every cell, with the wave and a code
    # (the same shape as DECIDE-KEEP-1's optionsChanged): the wave editor
    # waited for words that only the claim note carried, and said "still
    # running" about an answer that had already come. A per-cell warning cannot
    # say this - a mixed wave has one too, and its other cell is reserving.
    $nothingReservable = ($waveCells -gt 0 -and $waveReservable -eq 0)
    if ($nothingReservable) {
        Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome info -Data @{ wave = $Wave; code = 'nothingReservable' } `
            -Detail $(if ($waveOwn -eq 0) {
                    "Wave '$Wave' has nothing to reserve. Every machine in it is in an availability set, and Azure cannot " +
                    'put these machines on an on-demand capacity reservation. They move with no on-demand capacity reservation.'
                } else {
                    "Wave '$Wave' has nothing to reserve. Each machine in it is in an availability set, or stays in its own capacity reservation group. " +
                    'The move keeps a machine in its own capacity reservation group, and a machine in an availability set moves with no on-demand capacity reservation.'
                })
    }

    $out = @($results)
    $blocked = @($out | Where-Object Status -eq 'BLOCKED')
    $unconfirmed = @($out | Where-Object Status -eq 'UNCONFIRMED')
    $reserved = @($out | Where-Object Status -eq 'RESERVED')
    $lost = @($out | Where-Object Status -eq 'LOST')
    $notHeld = $blocked.Count + $unconfirmed.Count + $lost.Count

    # ODCR-FAIL-1, ruled 2026-08-29: ALL OR NOTHING. A wave that could
    # only partly reserve cannot run as planned, and leaving the successful
    # reservations in place means a customer paying for capacity nothing will
    # use - for as long as it takes somebody to notice, which for a wave that
    # never starts may be never. So give it all back and park.
    #
    # The trade is accepted explicitly: scarce capacity genuinely
    # obtained is released rather than held.
    #
    # RESERVING-STUCK-1: a cell Azure did not confirm is not held either, and
    # it may still bill, so it is released too - by its names. A release Azure
    # refuses for it now leaves it on the wave, marked not confirmed.
    if ($notHeld -gt 0 -and ($reserved.Count + $unconfirmed.Count) -gt 0) {
        Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome warn `
            -Detail ("$notHeld of $($out.Count) cells could not be reserved, so the $($reserved.Count) " +
                     'that succeeded are being released - a partly reserved wave cannot run as planned, and holding them would bill for capacity nothing can use.')
        try {
            Remove-VmfCapacityReservations -OutPath $OutPath -Wave $Wave | Out-Null
        }
        catch {
            # The one case that silently bills. Say so as loudly as possible.
            Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome fail `
                -Detail ("The on-demand capacity reservations were not released, and Azure bills them: $($_.Exception.Message). " +
                         'Select Release on the Quota and on-demand capacity reservations card of the Migrations page.')
            throw "Wave '$Wave' was not fully reserved, and the on-demand capacity reservations already made were not released. Azure bills them. $($_.Exception.Message)"
        }
    }

    [pscustomobject]@{
        Reserved = @(if ($notHeld -gt 0) { @() } else { $reserved })
        Blocked  = $blocked
        Unconfirmed = $unconfirmed
        Released = @(if ($notHeld -gt 0) { $reserved } else { @() })
        AllOrNothing = ($notHeld -gt 0)
        NothingReservable = $nothingReservable
        Refused = $null
    }
}