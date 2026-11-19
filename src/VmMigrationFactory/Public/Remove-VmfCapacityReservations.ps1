function Remove-VmfCapacityReservations {
    <#
    .SYNOPSIS
        Wave close-out (RELEASED stage) via the DOCUMENTED SAFE SEQUENCE
        (capacity-reservation-remove-vm, option 2): set each reservation's
        quantity to ZERO first, then disassociate the RUNNING VMs, then delete.
    .DESCRIPTION
        Never uses the deallocate-to-disassociate path (option 1): powering a
        migrated VM down to free a reservation would make its restart subject
        to general capacity - the exact availability trap the reservation
        existed to prevent. Quantity-zero-first means VMs stay
        RUNNING throughout; they are already placed on their hosts and simply
        stop being "reserved". Note also: consumed reservation slots cost
        nothing extra (only the UNUSED part of a capacity reservation bills), so releasing is
        cost hygiene for unused slots, never urgent for consumed ones.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Wave
    )

    # STEP-LOG-5: every line here is written after Azure or the store
    # changed, through Write-VmfStepLine. A line that cannot be written must
    # never stop the loop: the next reservations would go on billing.
    $released = [System.Collections.Generic.List[object]]::new()
    $notReleased = [System.Collections.Generic.List[object]]::new()
    $notDone = {
        param($Claim, [string]$Why)
        Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome fail -Detail $Why
        $notReleased.Add([pscustomobject]@{ Size = $Claim.size; Region = $Claim.region })
    }
    # RESERVING-STUCK-1: the RELEASED record is saved only if the claim is as
    # this release read it (Write-VmfClaimIfVersion). The engine may still be
    # writing a claim it is reserving; neither may overwrite the other.
    $saveReleased = {
        param($Read, $Claim)
        try { Write-VmfClaimIfVersion -Handle $Read.Handle -Claim $Claim -ExpectedVersion $Read.Version | Out-Null; $true }
        catch {
            if ([string]$_.Exception.Message -notlike '409*') { throw }
            & $notDone $Claim ("The claim for $($Claim.size)@$($Claim.region) changed while it was released, so it was not recorded as released. " +
                               'Select Release again to read it again.')
            $false
        }
    }
    foreach ($name in @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json')) {
        $read = Read-VmfClaimVersioned -RunPath $OutPath -Name $name
        $claim = if ($read) { $read.Claim } else { $null }
        if (-not $claim -or $claim.wave -ne $Wave) { continue }

        # RESERVING-STUCK-1: a claim nobody is making any more - an engine
        # stopped, or Azure did not confirm it in time - is released by the
        # resource ids it recorded before Azure was asked, because Azure never
        # gave its own. No machine of the wave can use it (a wave does not start
        # on a RESERVING claim), so there is nothing to detach. It is recorded
        # RELEASED only once Azure shows it gone. One Azure refuses now is said,
        # left on the wave, and does not stop the others.
        if (Test-VmfClaimReservingStuck -Claim $claim) {
            # Subscription, resource group and names all come from the one
            # recorded id. An id in another subscription than the claim's is
            # refused, not guessed at. OLD-VERSION-READERS-REMOVE-5: and a
            # claim that recorded no id is refused - no name is made for it, so
            # nothing of another wave is deleted by a guess. Every RESERVING
            # claim this version writes holds its id (New-VmfWaveReservation).
            try { $names = Get-VmfReservationNames -Claim $claim }
            catch {
                & $notDone $claim ("The quota record for $($claim.size) in $($claim.region) holds no resource ID for an on-demand capacity reservation, so nothing was released. " +
                                   'An on-demand capacity reservation can still bill. Find it in Azure by the tag vmfCapacityReservation=true, then delete it there.')
                continue
            }
            if ($claim.subscriptionId -and $names.SubscriptionId -ne [string]$claim.subscriptionId) {
                & $notDone $claim ("The on-demand capacity reservation $($names.ReservationId) is not in the subscription of its quota record ($($claim.subscriptionId)), so it was not released. " +
                                   'It can still bill. Delete it in Azure by its resource ID.')
                continue
            }
            try {
                Invoke-VmfAzOperation -Name 'odcrRelease' -RunPath $OutPath -Operation {
                    Remove-VmfCapacityReservation -ResourceGroupName $names.ResourceGroup `
                        -GroupName $names.GroupName -ReservationName $names.ReservationName -SubscriptionId $names.SubscriptionId
                } | Out-Null
                # The delete reads quietly, so a read Azure refused looks like
                # "nothing there". Only Azure saying not found is gone.
                $still = Invoke-VmfAzOperation -Name 'odcrGone' -RunPath $OutPath -Operation {
                    Test-VmfCapacityReservationPresent -ResourceGroupName $names.ResourceGroup `
                        -GroupName $names.GroupName -ReservationName $names.ReservationName -SubscriptionId $names.SubscriptionId
                }
                if ($still) { throw 'Azure still shows the on-demand capacity reservation after the delete.' }
            }
            catch {
                & $notDone $claim ("The on-demand capacity reservation $($names.ReservationId) was not confirmed, and it was not released now. " +
                                   "It can still bill. Release it again later. Azure said: $($_.Exception.Message)")
                continue
            }
            $claim.state = 'RELEASED'
            # Nobody saw it made, so there is no start time to give.
            $claim | Add-Member -NotePropertyName reservation -NotePropertyValue ([ordered]@{
                groupId = $names.GroupId; reservationId = $names.ReservationId
                createdUtc = $null; releasedUtc = (Get-Date).ToUniversalTime().ToString('o'); consumedInstances = 0
            }) -Force
            if (-not (& $saveReleased $read $claim)) { continue }
            Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome ok `
                -Detail "RELEASED $($claim.size)@$($claim.region), which Azure had not confirmed, by its resource ID"
            $released.Add([pscustomobject]@{ Size = $claim.size; Region = $claim.region })
            continue
        }
        if ($claim.state -notin @('RESERVED', 'CONSUMED')) { continue }

        # ODCR-SUB-1 / CAPRG-1: release in the subscription and resource group
        # the reservation is IN. RESERVING-STUCK-1 review: all of them, and the
        # names, come from the reservation's own resource id - a name is unique
        # only inside one resource group of one subscription. They used to be
        # taken from the claim's fields with the id as a fallback, so the parts
        # of one address came from two records. An id in another subscription
        # than its claim is refused.
        try {
            $held = Get-VmfReservationNames -Claim ([pscustomobject]@{ reservationAsked = [pscustomobject]@{
                groupId = [string]$claim.reservation.groupId; reservationId = [string]$claim.reservation.reservationId } })
        }
        catch { $held = $null }
        if (-not $held -or -not $held.SubscriptionId -or -not $held.ResourceGroup) {
            & $notDone $claim ("The quota record for $($claim.size) in $($claim.region) holds no whole resource ID for its on-demand capacity reservation, so it was not released. " +
                               'It can still bill. Delete it in Azure.')
            continue
        }
        if ($claim.subscriptionId -and $held.SubscriptionId -ne [string]$claim.subscriptionId) {
            & $notDone $claim ("The on-demand capacity reservation $($held.ReservationId) is not in the subscription of its quota record ($($claim.subscriptionId)), so it was not released. " +
                               'It can still bill. Delete it in Azure by its resource ID.')
            continue
        }
        $claimRg = $held.ResourceGroup
        $claimSub = $held.SubscriptionId
        $groupName = $held.GroupName
        $resName = $held.ReservationName

        # Step 1 (safety-critical ORDER): quantity -> 0 BEFORE any disassociation,
        # so running VMs can be disassociated without deallocation.
        Invoke-VmfAzOperation -Name 'odcrQuantityZero' -RunPath $OutPath -Operation {
            Set-VmfCapacityReservationQuantity -ResourceGroupName $claimRg `
                -GroupName $groupName -ReservationName $resName -Quantity 0 -SubscriptionId $claimSub
        } | Out-Null

        # Step 2: disassociate the still-RUNNING VMs
        foreach ($vmId in @($claim.PSObject.Properties['associatedVmIds'] ? $claim.associatedVmIds : @())) {
            $vmName = ($vmId -split '/')[-1]
            $vmRg = ($vmId -split '/')[4]
            # SEC-1 / F10: the two calls either side of this one carry
            # -SubscriptionId, and this one addresses the MACHINE by resource
            # group and name - a pair that is unique only inside one
            # subscription. A wave can hold machines from several, so the pin
            # is per machine rather than once for the whole release, and it is
            # put back before the next one.
            $vmSubscriptionId = Assert-VmfResourceId -ResourceId $vmId -Kind 'virtual machine'
            $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $vmSubscriptionId
            try {
                Invoke-VmfAzOperation -Name 'odcrDisassociate' -RunPath $OutPath -VmId $vmId -Operation {
                    Set-VmfVmCapacityReservationGroup -ResourceGroupName $vmRg -Name $vmName -GroupId $null
                } | Out-Null
            }
            finally { Restore-VmfSubscriptionContext -Context $previousAzContext }
        }
        Invoke-VmfAzOperation -Name 'odcrRelease' -RunPath $OutPath -Operation {
            Remove-VmfCapacityReservation -ResourceGroupName $claimRg `
                -GroupName $groupName -ReservationName $resName -SubscriptionId $claimSub
        } | Out-Null

        $claim.state = 'RELEASED'
        $claim.reservation.releasedUtc = (Get-Date).ToUniversalTime().ToString('o')
        if (-not (& $saveReleased $read $claim)) { continue }
        Write-VmfStepLine -RunPath $OutPath -Step 'odcr' -Outcome ok -Detail "RELEASED $($claim.size)@$($claim.region)"
        $released.Add([pscustomobject]@{ Size = $claim.size; Region = $claim.region })
    }
    [pscustomobject]@{ Released = @($released); NotReleased = @($notReleased) }
}
