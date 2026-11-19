# CRG-MOVE-1: a move keeps a machine in its own capacity reservation group.
#
# ROLLBACK-CRG-1 records the group at PRECHECK and returns the machine to it on
# every put-back. The move itself did not ask about it:
#   - with a wave reservation, CONVERTING put the machine in the wave's group,
#     and the release at the end of the wave took it out of that group - into
#     none;
#   - without one, a Path B rebuild built the machine in no group;
#   - without one, a Path A resize kept the machine in a group that holds no
#     reservation for the new size, and Azure refused the start (SAFETY-2: a
#     machine starts only when its group has a reservation for its size). The
#     machine was rolled back, and the change window was spent.
#
# Since 2026-10-19: check exactly what Microsoft's "Modify a capacity
# reservation" page tells a person to check, in "Resize VMs associated to a
# capacity reservation group": the group must have a capacity reservation for
# the target size, or the person creates one or removes the machine from the
# group. Build only that, and nothing that manages the customer's reservations.
# Never read the reserved quantity: Azure allows a group to hold more machines
# than it reserves (overallocation), so a quantity is not a limit.
#
# So, at PRECHECK, before any change: a machine in a group this migration did
# not make has the group's capacity reservations read. No reservation for the
# target size stops it untouched, naming Microsoft's two options. One for it:
# CONVERTING keeps the machine in that group on both paths - the Path A resize
# leaves it there, the Path B rebuild names it - and a wave reservation does
# not replace it. A put-back then finds the machine in the group it recorded,
# and leaves it there (Get-VmfReservationPutBackPlan).

function Get-VmfOwnReservationGroup {
    <#
    .SYNOPSIS
        The capacity reservation group a capture recorded, when this migration
        did not make it. Pure.
    .OUTPUTS
        The group id, or $null: no group, a record that does not say (a plan
        entry whose assessment did not say - unknown, and not asked about), or
        a group a quota record of this migration names
        (Get-VmfProductReservationGroupIds). Every capture says.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Capture,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )
    $captured = Get-VmfCapturedReservationGroup -Capture $Capture
    if (-not ($captured.Known -and $captured.GroupId)) { return $null }
    $groupId = [string]$captured.GroupId
    $ours = @(@($ProductGroupIds) | Where-Object { [string]::Equals([string]$_, $groupId, [System.StringComparison]::OrdinalIgnoreCase) })
    if ($ours.Count) { return $null }
    $groupId
}

function Add-VmfPlanReservationGroup {
    <#
    .SYNOPSIS
        CRG-MOVE-DEMAND-1: carry the assessment record's capacity reservation
        group into a plan entry's assessment (plan-entry v30).
    .DESCRIPTION
        Only when the record says (assessment v13): a record without the field
        leaves the entry without it, which Get-VmfCapturedReservationGroup
        reads as unknown - and unknown is counted for a reservation, never left
        out. $null (in no group) is carried as $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary]$Assessment,
        [Parameter()][AllowNull()]$Record
    )
    if ($null -eq $Record -or -not $Record.PSObject.Properties['capacityReservationGroupId']) { return }
    $id = [string]$Record.capacityReservationGroupId
    $Assessment['capacityReservationGroupId'] = $(if ($id) { $id } else { $null })
}

function Get-VmfReservationZoneFit {
    <#
    .SYNOPSIS
        Does a group have a capacity reservation for this size, in the zone of
        the machine? Pure. CRG-MOVE-1 and CRG-MOVE-ZONE-1.
    .DESCRIPTION
        Since 2026-11-02 the zone is compared too: a capacity reservation in a
        zonal group is for one availability zone, so the size and the zone
        must be on the SAME reservation. A regional reservation (zones empty)
        fits any machine in the region. A machine with no zone fits any
        reservation of the size, as CRG-MOVE-1 did. A zone that is not known -
        the machine's, or a reservation's - is never a fit.
        Sizes are compared without letter case, as Azure gives them both ways;
        zones as text.
    .PARAMETER Reservations
        The read (Get-VmfCapacityReservationSizes): { size; zones } each.
    .PARAMETER Zone
        The machine's zone (Get-VmfMachineZone), empty for none.
    .PARAMETER ZoneKnown
        $false when the capture does not say the machine's zones.
    .OUTPUTS
        { Fits; Why = fits | noSize | otherZone | zoneUnknown; Zones } - Zones
        are the zones the size is reserved in, for the stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][AllowNull()][object[]]$Reservations = @(),
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        [Parameter(Mandatory)][bool]$ZoneKnown
    )
    $result = { param($fits, $why, $zones) [pscustomobject]@{ Fits = $fits; Why = $why; Zones = @($zones) } }
    if (-not $Size) { return (& $result $false 'noSize' @()) }
    $ofSize = @(@($Reservations) | Where-Object { $_ -and [string]::Equals([string](Get-VmfRecordField -Object $_ -Name 'size'), $Size, [System.StringComparison]::OrdinalIgnoreCase) })
    if (-not $ofSize.Count) { return (& $result $false 'noSize' @()) }
    # Only a reservation whose zones were read can be regional or zonal.
    $read = @($ofSize | Where-Object { Test-VmfRecordHasField -Object $_ -Name 'zones' })
    $zonesOf = { param($r) @(@(Get-VmfRecordField -Object $r -Name 'zones') | Where-Object { $null -ne $_ -and [string]$_ } | ForEach-Object { [string]$_ }) }
    $reserved = @($read | ForEach-Object { & $zonesOf $_ } | Sort-Object -Unique)
    if (@($read | Where-Object { -not (& $zonesOf $_).Count }).Count) { return (& $result $true 'fits' $reserved) }
    if ($ZoneKnown -and $Zone -and ($reserved -contains [string]$Zone)) { return (& $result $true 'fits' $reserved) }
    if ($read.Count -lt $ofSize.Count) { return (& $result $false 'zoneUnknown' $reserved) }
    if (-not $ZoneKnown) { return (& $result $false 'zoneUnknown' $reserved) }
    if (-not $Zone) { return (& $result $true 'fits' $reserved) }
    & $result $false 'otherZone' $reserved
}

function Get-VmfReservationGroupHold {
    <#
    .SYNOPSIS
        Can this group hold the machine on this size? One read of the group's
        capacity reservations, and the zone rule. CRG-MOVE-1, CRG-MOVE-ZONE-1.
    .DESCRIPTION
        The check PRECHECK makes before a move (Test-VmfMoveReservationGroup).
        REBUILD-REMOVE-RECOVER-1: Rebuild this machine as the target asked it
        too, and is gone. The zone of the machine comes from the
        capture, never another read; a capture with no zones field does not
        say. A lost lease throws, as everywhere else.
    .OUTPUTS
        @{ ReadError; Zone; Fit } - ReadError is Azure's words when the read
        failed (Fit is then $null); Fit is Get-VmfReservationZoneFit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$GroupId,
        [Parameter()][AllowNull()]$Capture,
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][string]$OperationName
    )
    $reservations = $null
    try {
        $reservations = @(Invoke-VmfAzOperation -Name $OperationName -RunPath $RunPath -VmId $VmId -Operation {
                @(Get-VmfCapacityReservationSizes -GroupId $GroupId)
            })
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return @{ ReadError = [string]$_.Exception.Message; Zone = ''; Fit = $null }
    }
    $zone = Get-VmfMachineZone -Machine $Capture
    $zoneKnown = Test-VmfRecordHasField -Object $Capture -Name 'zones'
    @{ ReadError = $null; Zone = $zone; Fit = (Get-VmfReservationZoneFit -Reservations $reservations -Size $Size -Zone $zone -ZoneKnown $zoneKnown) }
}

function Test-VmfMoveReservationGroup {
    <#
    .SYNOPSIS
        PRECHECK: can the move keep this machine in its own capacity
        reservation group? $null when it can, or there is no such group;
        otherwise the NEEDS_DECISION result, with the machine untouched.
    .PARAMETER Capture
        This attempt's capture (captured.vmConfig): the group the machine is
        in now, which the resize or the rebuild acts in.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][AllowNull()]$Capture,
        [Parameter(Mandatory)][string]$TargetSize
    )
    $productGroupIds = @(Get-VmfProductReservationGroupIds -RunPath $Context.RunPath)
    $groupId = Get-VmfOwnReservationGroup -Capture $Capture -ProductGroupIds $productGroupIds
    if (-not $groupId) {
        # CRG-MOVE-DEMAND-1 review: the assessment found the machine in its own
        # group, so Check the quota reserved no place for it in the wave's
        # group (Test-VmfEntryReservable), and CONVERTING will not join it.
        # It is not in that group now. On a wave set to Reserved it would
        # then start with no capacity reservation inside the stopped window,
        # which its wave's setting promises it never does - so it stops here,
        # untouched. A wave not set to Reserved promises no reservation, and
        # the machine moves with the warning line CONVERTING writes.
        $plan = $Context.Plan
        $reserved = $plan -and (Get-VmfCapacityGate -PlanEntry $plan) -eq 'Reserved'
        $inAvset = $plan -and $plan.assessment -and $plan.assessment.PSObject.Properties['availabilitySetId'] -and [string]$plan.assessment.availabilitySetId
        $plannedOwn = if ($plan -and -not $inAvset) { Get-VmfOwnReservationGroup -Capture $plan.assessment -ProductGroupIds $productGroupIds } else { $null }
        if ($reserved -and $plannedOwn) {
            $machine = ([string]$Context.VmId -split '/')[-1]
            $plannedName = Get-VmfReservationGroupName $plannedOwn
            return @{
                Next         = 'NEEDS_DECISION'
                Reason       = 'reservationGroupLeftAfterScan'
                MachineState = 'untouched'
                Detail       = "The assessment found the machine '$machine' in the capacity reservation group '$plannedName', and it left that group after the assessment. " +
                               'So the capacity reservation of its wave holds no place for it, and the wave is set to On-demand capacity reservation. The run stopped before it changed the machine. ' +
                               "Add the machine to the group '$plannedName' again, then try the machine again. " +
                               'Or run a new assessment and plan again, then select Check the quota and Reserve capacity for the wave.'
            }
        }
        return $null
    }
    $name = Get-VmfReservationGroupName $groupId
    $hold = Get-VmfReservationGroupHold -RunPath $Context.RunPath -VmId $Context.VmId -GroupId $groupId -Capture $Capture -Size $TargetSize -OperationName 'reservationSizes'
    $why = $hold.ReadError
    if ($null -ne $why) {
        return @{
            Next         = 'NEEDS_DECISION'
            # STOP-TEXT-SPECIFIC-1: a group it could not read is not a group
            # with no capacity reservation - its own reason.
            Reason       = 'reservationGroupNotRead'
            MachineState = 'untouched'
            Detail       = "This machine is in the capacity reservation group '$name'. Azure did not give the capacity reservations of the group: $($why.TrimEnd('.')). " +
                           "So the product cannot confirm that the group has a capacity reservation for $TargetSize. The run stopped before it changed the machine. " +
                           'If Azure refused the read, grant the VMF Assessment role on the group. Then try the machine again.'
        }
    }
    $zone = $hold.Zone
    $fit = $hold.Fit
    if ($fit.Fits) {
        $where = if ($zone) { " in availability zone $zone" } else { '' }
        Write-VmfEvent -RunPath $Context.RunPath -Step 'precheck' -Outcome info -VmId $Context.VmId `
            -Detail "The machine is in the capacity reservation group '$name', which has a capacity reservation for $TargetSize$where. The move keeps the machine in this group."
        return $null
    }
    $zoneWords = { param($zones) $z = @($zones); if ($z.Count -gt 1) { "availability zones $(($z[0..($z.Count - 2)]) -join ', ') and $($z[-1])" } else { "availability zone $($z[0])" } }
    if ($fit.Why -eq 'otherZone') {
        return @{
            Next         = 'NEEDS_DECISION'
            Reason       = 'reservationGroupNoTargetSize'
            MachineState = 'untouched'
            Detail       = "This machine is in the capacity reservation group '$name', in availability zone $zone. The group has a capacity reservation for $TargetSize only in $(& $zoneWords $fit.Zones). " +
                           'A capacity reservation in a zonal group is for one availability zone. The run stopped before it changed the machine. ' +
                           "Create a capacity reservation for $TargetSize in availability zone $zone in the group. A reserved quantity of 0 needs no more quota. " +
                           'Or remove the machine from the group. Then try the machine again.'
        }
    }
    if ($fit.Why -eq 'zoneUnknown') {
        return @{
            Next         = 'NEEDS_DECISION'
            Reason       = 'reservationGroupNoTargetSize'
            MachineState = 'untouched'
            Detail       = "This machine is in the capacity reservation group '$name'. The group has a capacity reservation for $TargetSize. The product cannot read the availability zone of the machine or of that capacity reservation. " +
                           'So the product cannot confirm that the capacity reservation is in the availability zone of the machine. The run stopped before it changed the machine. ' +
                           "Make sure that the group has a capacity reservation for $TargetSize in the availability zone of the machine. Or remove the machine from the group. Then try the machine again."
        }
    }
    @{
        Next         = 'NEEDS_DECISION'
        Reason       = 'reservationGroupNoTargetSize'
        MachineState = 'untouched'
        Detail       = "This machine is in the capacity reservation group '$name'. The group has no capacity reservation for the target size $TargetSize. " +
                       'Azure resizes a machine in a group only to a size that has a capacity reservation in the group. The run stopped before it changed the machine. ' +
                       "Create a capacity reservation for $TargetSize in the group. A reserved quantity of 0 needs no more quota. " +
                       'Or remove the machine from the group. Then try the machine again.'
    }
}
