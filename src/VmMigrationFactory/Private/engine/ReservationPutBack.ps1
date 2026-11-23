# ROLLBACK-CRG-1: a put-back puts the machine back in the capacity reservation
# group it was in before the move.
#
# Every put-back - the automatic rollback, Restore this machine from the first
# copy - used to leave WHATEVER group the
# machine was in. That is right for the product's own group: it holds only the
# target size, and Azure refuses to start a machine whose size has no
# reservation in its group (found by the SAFETY-2 drill). But the capture never
# recorded the group the machine had before the move, so a machine its owner
# had put in its OWN group came back without it, and nothing said so. Its later
# starts had no capacity guarantee.
#
# So PRECHECK records the group (captured.vmConfig.capacityReservationGroupId,
# vm-state v24; $null is "in no group"). The put-back takes the group of THIS
# attempt's capture when this migration did not make it - a retry is a
# complete new run (SAFETY-RETRY-1), and a group chosen between two attempts is
# not a change of the product. Else the group an earlier rollback could not
# put the machine back in, else the FIRST capture's group
# (Get-VmfPutBackReservationGroup, CRG-ROLLBACK-ATTEMPT-GROUP-1).
#   - A group the machine was not in before the move is left, BEFORE the size
#     changes - the product's group, or one somebody joined during the move.
#   - The group it was in is put back AFTER the size is back: Azure checks the
#     machine's current size against the group (REH-1), and a regional machine
#     joins a group only while it is deallocated (Microsoft's
#     capacity-reservation-associate-vm page).
#   - Azure can refuse that - the group holds no reservation for the size.
#     The put-back says so in its own words and goes on. A put-back that has
#     already changed the machine must never fail for a group.
#   - Every capture says its group, $null for none (Get-VmfVmCapture). A
#     record that does not say is not one this version writes: the put-back
#     stops before anything changes (Get-VmfPutBackRecordGap,
#     OLD-VERSION-READERS-REMOVE-4), and never reads it as "in no group".

# ROLLBACK-CRG-1: what Azure checks on the group when a machine joins it -
# the action Microsoft's capacity-reservation-group-share page names for a
# machine owner who deploys into a group. Asked of the group itself at
# PRECHECK (NIC-JOIN-1, ROLE-SNAP-1: a write is checked on what it links to).
$script:VmfReservationJoinActions = @('Microsoft.Compute/capacityReservationGroups/deploy/action')

function Get-VmfCapturedReservationGroup {
    <#
    .SYNOPSIS
        The capacity reservation group a capture recorded. Pure.
    .OUTPUTS
        @{ Known; GroupId }. Known is $false for a record with no field - a
        plan entry whose assessment did not say (Add-VmfPlanReservationGroup):
        unknown, never "in no group". Every capture of the machine says
        (Get-VmfVmCapture). GroupId is $null for a machine in no group.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Capture)
    if ($null -eq $Capture) { return @{ Known = $false; GroupId = $null } }
    if (-not (Test-VmfRecordHasField -Object $Capture -Name 'capacityReservationGroupId')) { return @{ Known = $false; GroupId = $null } }
    $id = [string](Get-VmfRecordField -Object $Capture -Name 'capacityReservationGroupId')
    @{ Known = $true; GroupId = $(if ($id) { $id } else { $null }) }
}

function Get-VmfOwedReservationGroup {
    <#
    .SYNOPSIS
        CRG-ROLLBACK-ATTEMPT-GROUP-1 review: the capacity reservation group an
        earlier rollback did not return the machine to, and that no put-back
        has tried since. Pure.
    .DESCRIPTION
        rollback.reservationGroupNotBack: Azure refused the join, the rollback
        said so and finished, and the machine runs in no group. The record
        stays across attempts (the rollback record is kept until the next
        rollback writes it), and every write of the record that does not try
        the group carries it on (Set-VmfRollbackRecord), so a later attempt
        still owes the group. A restore after that rollback
        (restore.restoredUtc later than rollback.rolledBackUtc) made its own
        decision about the group, so the record no longer stands. A group of
        this migration is never owed.
    .OUTPUTS
        @{ groupId; why }, or $null.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $rb = & $f $Doc 'rollback'
    $miss = & $f $rb 'reservationGroupNotBack'
    $groupId = [string](& $f $miss 'groupId')
    if (-not $groupId) { return $null }
    $utc = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime() } elseif ($v) { [datetime]::Parse([string]$v, $null, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') } else { $null } }
    $restoredAt = & $utc (& $f (& $f $Doc 'restore') 'restoredUtc')
    $rolledBackAt = & $utc (& $f $rb 'rolledBackUtc')
    if ($restoredAt -and (-not $rolledBackAt -or $restoredAt -gt $rolledBackAt)) { return $null }
    if (@(@($ProductGroupIds) | Where-Object { $_ -and [string]::Equals([string]$_, $groupId, [System.StringComparison]::OrdinalIgnoreCase) }).Count) { return $null }
    [ordered]@{ groupId = $groupId; why = [string](& $f $miss 'why') }
}

function Get-VmfPutBackReservationGroup {
    <#
    .SYNOPSIS
        CRG-ROLLBACK-ATTEMPT-GROUP-1: the capacity reservation group a
        rollback or a restore of this attempt returns the machine to. Pure.
    .DESCRIPTION
        In this order:
          1. The group of THIS attempt's capture (captured.vmConfig), when it
             is a group this migration did not make. A retry from the first
             step is a complete new run (SAFETY-RETRY-1), so a put-back of
             attempt N returns the machine to the group it was in at the start
             of attempt N - a group the machine joined between two attempts
             included.
          2. Else the group an earlier rollback did not return the machine to
             (Get-VmfOwedReservationGroup): Azure refused that join, so the
             attempt started in no group, and the put-back tries the group
             again.
          3. Else the first capture's group, "in no group" included - as
             before this rule, so a machine is never worse off: a machine in
             no group at this attempt, or in a group of this migration, goes
             back to the group it was in before the first change.
        The size, the controller and the disk types still come from the first
        capture (ROLLBACK-RETRY-CAPTURE-1): the product changed those, and a
        group chosen between attempts is not a change of the product.
    .PARAMETER ProductGroupIds
        Get-VmfProductReservationGroupIds of the run.
    .OUTPUTS
        @{ Known; GroupId }, as Get-VmfCapturedReservationGroup gives it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )
    $attempt = Get-VmfCapturedReservationGroup -Capture (Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'vmConfig')
    if ($attempt.Known -and $attempt.GroupId) {
        $ours = @(@($ProductGroupIds) | Where-Object { $_ -and [string]::Equals([string]$_, [string]$attempt.GroupId, [System.StringComparison]::OrdinalIgnoreCase) })
        if (-not $ours.Count) { return $attempt }
    }
    $owed = Get-VmfOwedReservationGroup -Doc $Doc -ProductGroupIds $ProductGroupIds
    if ($owed) { return @{ Known = $true; GroupId = [string]$owed.groupId } }
    Get-VmfCapturedReservationGroup -Capture (Get-VmfOriginalCapture -Doc $Doc)
}

function Get-VmfProductReservationGroupIds {
    <#
    .SYNOPSIS
        Every capacity reservation group a quota record of this migration
        names - the groups the product made and joins. A store read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RunPath)
    $ids = foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json')) {
        $claim = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$name" -Depth 12
        foreach ($field in 'reservation', 'reservationAsked') {
            $g = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $claim -Name $field) -Name 'groupId')
            if ($g) { $g }
        }
    }
    @($ids | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-VmfReservationGroupName {
    # The last part of a group's resource id, which Azure shows as its name.
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$GroupId)
    if ($GroupId) { ($GroupId -split '/')[-1] } else { '' }
}

function Get-VmfReservationPutBackPlan {
    <#
    .SYNOPSIS
        What a put-back does with the machine's capacity reservation group.
        Pure.
    .PARAMETER CurrentGroupId
        The group the machine is in now, as Azure reads it; empty for none.
    .PARAMETER Captured
        Get-VmfCapturedReservationGroup of the put-back capture. It is always
        known (Get-VmfPutBackRecordGap); one that is not throws, before any
        decision.
    .PARAMETER ProductGroupIds
        Get-VmfProductReservationGroupIds of the run.
    .OUTPUTS
        @{ Leave; LeaveGroupId; LeaveIsOurs; JoinGroupId; Words }. Leave
        before the size changes, join after it. LeaveIsOurs: the group left is
        one a quota record of this migration names. Words are information
        lines to write before the leave.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CurrentGroupId,
        [Parameter(Mandatory)][hashtable]$Captured,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )
    $same = { param($a, $b) [bool]$a -and [bool]$b -and [string]::Equals([string]$a, [string]$b, [System.StringComparison]::OrdinalIgnoreCase) }
    $current = if ($CurrentGroupId) { $CurrentGroupId } else { $null }
    $words = [System.Collections.Generic.List[string]]::new()
    $leave = $false
    $join = $null
    if (-not $Captured.Known) { throw 'The record of this machine does not say its capacity reservation group, so the product does not change the machine.' }
    $was = $Captured.GroupId
    if ($current -and -not (& $same $current $was)) { $leave = $true }
    if ($was -and -not (& $same $current $was)) { $join = $was }
    # ROLLBACK-CRG-1 review: a group the machine leaves that this migration did
    # not make - somebody joined the machine to it during the move. Leaving it
    # is "as it was", and the put-back says so loudly, never only in passing.
    $leaveOurs = $leave -and @(@($ProductGroupIds) | Where-Object { & $same $_ $current }).Count -gt 0
    @{ Leave = $leave; LeaveGroupId = $(if ($leave) { $current } else { $null }); LeaveIsOurs = [bool]$leaveOurs; JoinGroupId = $join; Words = @($words) }
}

function Get-VmfReservationReadWords {
    <#
    .SYNOPSIS
        RESERVATION-RESULT-WORDS-1: what the put-back's read of the group
        found, in the approved words. Pure.
    .DESCRIPTION
        The activity showed only "Checking which capacity reservation group
        this machine is in", and never the result. A sentence comes only where
        it is true: the machine is in the group it was in before the move, or
        in no group as before. Where the two differ, the put-back leaves or
        joins a group, and those lines say it - so this gives $null.
        The rollback pair was approved on 2026-11-14; the restore pair is
        the same with "the restore".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CurrentGroupId,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$CapturedGroupId
    )
    if (-not $CurrentGroupId -and -not $CapturedGroupId) {
        return "The machine is in no capacity reservation group, so the $Kind has no group to put it back in."
    }
    if ($CurrentGroupId -and $CapturedGroupId -and [string]::Equals($CurrentGroupId, $CapturedGroupId, [System.StringComparison]::OrdinalIgnoreCase)) {
        return "The machine is in the capacity reservation group $(Get-VmfReservationGroupName $CurrentGroupId). The $Kind puts it back in that group."
    }
    $null
}

function Get-VmfReservationStep {
    # The step name of a put-back's lines, from the kind of its operations.
    param([Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind)
    $Kind
}

function Get-VmfReservationPutBack {
    <#
    .SYNOPSIS
        Read the group the machine is in now and decide the put-back
        (Get-VmfReservationPutBackPlan). The decision carries CurrentGroupId.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Rg,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter()][AllowNull()]$Capture
    )
    $current = Invoke-VmfAzOperation -Name "$($Kind):readReservation" -RunPath $RunPath -VmId $VmId -Operation {
        Get-VmfVmCapacityReservationGroupId -ResourceGroupName $Rg -Name $VmName
    }
    $captured = Get-VmfCapturedReservationGroup -Capture $Capture
    $decision = Get-VmfReservationPutBackPlan -CurrentGroupId ([string]$current) -Captured $captured `
        -ProductGroupIds @(Get-VmfProductReservationGroupIds -RunPath $RunPath)
    $decision.CurrentGroupId = [string]$current
    # RESERVATION-RESULT-WORDS-1: the result of the read, as the first of the
    # lines Invoke-VmfReservationLeave writes - right after the read's line.
    $found = Get-VmfReservationReadWords -Kind $Kind -CurrentGroupId ([string]$current) -CapturedGroupId ([string]$captured.GroupId)
    if ($found) { $decision.Words = @(@($found) + @($decision.Words)) }
    $decision
}

function Invoke-VmfReservationLeave {
    <#
    .SYNOPSIS
        Before the size changes: say the decision's words, and leave a group
        the machine was not in before the move.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Rg,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Decision,
        [Parameter()][string]$Size,
        # The Path B rollback: deleting the definition takes the machine out of
        # its group, so nothing is asked of Azure - only said and recorded.
        [Parameter()][switch]$DefinitionGoes
    )
    $step = Get-VmfReservationStep -Kind $Kind
    foreach ($w in @($Decision.Words)) { Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId -Detail $w }
    if (-not $Decision.Leave) { return $null }
    if (-not $DefinitionGoes) {
        Invoke-VmfAzOperation -Name "$($Kind):leaveReservation" -RunPath $RunPath -VmId $VmId -Operation {
            Set-VmfVmCapacityReservationGroup -ResourceGroupName $Rg -Name $VmName -GroupId $null
        } | Out-Null
    }
    $name = Get-VmfReservationGroupName $Decision.LeaveGroupId
    # The "in use" count is the product's own record, not a live reading, so a
    # machine that leaves a reservation must say so there.
    Remove-VmfClaimAssociation -RunPath $RunPath -VmId $VmId
    if ($Decision.LeaveIsOurs) {
        Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId `
            -Detail "The machine left the capacity reservation group '$name'. The machine was not in it before the move$(if ($Size) { ", and the machine returns to $Size" })."
        return $null
    }
    # ROLLBACK-CRG-1 review: a group this migration did not make.
    Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome warn -VmId $VmId -Detail (Get-VmfReservationLeftWords -GroupId ([string]$Decision.LeaveGroupId))
    [ordered]@{ groupId = [string]$Decision.LeaveGroupId }
}

function Get-VmfReservationLeftWords {
    # The words for a group the machine left that this migration did not make.
    param([Parameter(Mandatory)][string]$GroupId)
    "The machine left the capacity reservation group '$(Get-VmfReservationGroupName $GroupId)'. The machine was not in it before the move, and this migration did not make it. " +
    'Add the machine to the group again if it must stay in it.'
}

function Get-VmfReservationNotBackWords {
    # The words for a group Azure did not put the machine back in.
    param([Parameter(Mandatory)][string]$GroupId, [Parameter(Mandatory)][string]$Why, [Parameter()][string]$Size)
    "Azure did not return the machine to its capacity reservation group '$(Get-VmfReservationGroupName $GroupId)': $($Why.TrimEnd('.')). " +
    "The machine runs in no capacity reservation group, so Azure does not guarantee capacity when it starts. " +
    "Add the machine to the group again when the group has an on-demand capacity reservation$(if ($Size) { " for $Size" })."
}

function Invoke-VmfReservationRejoin {
    <#
    .SYNOPSIS
        After the size is back, while the machine is stopped: put it back in
        the group it was in before the move.
    .OUTPUTS
        $null when there was nothing to do or Azure did it; otherwise
        @{ groupId; why } - Azure refused, and the put-back goes on.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Rg,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter(Mandatory)][hashtable]$Decision,
        [Parameter()][string]$Size
    )
    $groupId = [string]$Decision.JoinGroupId
    if (-not $groupId) { return $null }
    $step = Get-VmfReservationStep -Kind $Kind
    try {
        Invoke-VmfAzOperation -Name "$($Kind):joinReservation" -RunPath $RunPath -VmId $VmId -Operation {
            Set-VmfVmCapacityReservationGroup -ResourceGroupName $Rg -Name $VmName -GroupId $groupId
        } | Out-Null
    }
    catch {
        # A lost lease stops the worker as everywhere else; another one
        # finishes the put-back and asks again.
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $why = [string]$_.Exception.Message
        Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome warn -VmId $VmId -Detail (Get-VmfReservationNotBackWords -GroupId $groupId -Why $why -Size $Size)
        return [ordered]@{ groupId = $groupId; why = $why }
    }
    Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId `
        -Detail "The machine is back in its capacity reservation group '$(Get-VmfReservationGroupName $groupId)', as before the move."
    $null
}

# REBUILD-REMOVE-ENGINE-1: Invoke-VmfRebuildInReservationGroup, the rebuild in
# the group the machine was in, is gone with the last rebuild: the Path B
# rollback (REBUILD-REMOVE-ENGINE-1) and the restore that rebuilt and Rebuild
# this machine (REBUILD-REMOVE-RECOVER-1).

function Test-VmfReservationJoinPermissions {
    <#
    .SYNOPSIS
        PRECHECK: can this identity keep the machine in, or put it back in, a
        capacity reservation group this migration did not make? $null when it
        can, or there is no such group; otherwise the NEEDS_DECISION result.
    .DESCRIPTION
        NIC-JOIN-1 and ROLE-SNAP-1: Azure checks a write on every resource it
        links to (LinkedAuthorizationFailed), and the machine-scope check does
        not see a group in another resource group. A group of this migration is
        not asked about: the product never puts a machine back in it.

        One group is asked about: the group a put-back returns the machine to
        (Get-VmfPutBackCapture with the groups of this migration). Since
        CRG-ROLLBACK-ATTEMPT-GROUP-1 (2026-11-21) that is the group of THIS
        attempt's capture whenever this migration did not make it - the group
        the move acts in too (CRG-MOVE-1). So CRG-JOIN-ATTEMPT-1's second
        group - this attempt's, when it differed from the first capture's - is
        the same group, and it is asked about once. With no such group, it is
        the group an earlier rollback still owes, or the first capture's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks - the
        # same group, with the words of the restore.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $productGroupIds = @(Get-VmfProductReservationGroupIds -RunPath $Context.RunPath)
    $groupId = Get-VmfOwnReservationGroup -Capture (Get-VmfPutBackCapture -Doc $doc -ProductGroupIds $productGroupIds) -ProductGroupIds $productGroupIds
    if (-not $groupId) { return $null }

    $perms = Invoke-VmfAzOperation -Name 'reservationPermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfEffectivePermissions -Scope $groupId
    }
    $missing = @(Get-VmfMissingActions -RequiredActions @($script:VmfReservationJoinActions) -Permissions $perms)
    if (-not $missing.Count) { return $null }

    $count = $missing.Count
    $on = @($missing | ForEach-Object { "$_ on $groupId" }) -join '; '
    $why = if ($For -eq 'restore') {
        # A restore updates the machine in the group it is in, and the first
        # copy returns it to the group it was in before the move.
        "The restore keeps this machine in the capacity reservation group, or returns it to the group. Azure checks this permission on the group: $on."
    }
    else {
        "A rollback or a restore returns this machine to the group, and Azure checks this permission on the group: $on."
    }
    $where = 'on the capacity reservation group'
    $names = "the capacity reservation group '$(Get-VmfResourceNameFromId $groupId)'"
    @{
        Next   = 'NEEDS_DECISION'
        # STOP-TEXT-SPECIFIC-1: its own reason, and the words lead with the group.
        Reason = 'permissionMissingReservationGroup'
        Detail = "The product's managed identity is missing $count $(if ($count -eq 1) { 'permission' } else { 'permissions' }) on $names. " +
                 "$why " +
                 "$(if ($For -eq 'restore') { Get-VmfPermissionStopWords -For 'restore' } else { 'The run stopped before it changed the machine.' }) Grant the VMF Migration role $where, then try again."
    }
}
