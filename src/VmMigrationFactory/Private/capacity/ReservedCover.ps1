# RESERVE-COVER-1, 2026-10-04. A wave set to Reserved is judged by the
# MACHINES it moves, not by the quota records that happen to exist.
#
# The gate and the refusal used to ask "is every record of the wave RESERVED?".
# Test-VmfQuota writes one record per cell, cell by cell, reading Azure inside
# the loop - so a check that stopped half way, or a second container reading
# while the first still wrote, left a PARTIAL set. Reserve reserved the cells
# it had, the start passed, and the machines of the missing cell moved on
# general capacity with no word. AVSET-RESERVE-1 closed the one case it
# introduced (a wave whose records were all availability-set cells); this is
# the general rule it pointed at.
#
# RESERVE-COVER-2, 2026-10-09: the same rule for a wave with no capacity
# reservation (BestEffort). Its start checked the quota only when the wave had
# no records at all, so a partial set passed the same way. Every machine that
# moves needs a record of its own cell at QUOTA_VERIFIED or above.
#
# PURE, apart from the store reads of the state documents (Get-VmfFinishedVmIds,
# Get-VmfStartedVmIds, and Get-VmfLeftOutVmIds and
# Resolve-VmfWaveNeedsNoCapacity, which use them): which machines a set of
# records covers is logic a test can drive with every kind of machine.

function Test-VmfEntryReservable {
    <#
    .SYNOPSIS
        Does the wave's capacity reservation hold a place for this plan entry?
        The ONE rule Test-VmfQuota, the Reserved gate, the start's line and
        CONVERTING use.
    .DESCRIPTION
        Every machine, except:
        - a machine in an availability set (CAP-2: Azure cannot put one on a
          reservation);
        - CRG-MOVE-DEMAND-1: a machine the assessment found in a capacity
          reservation group this migration did not make. CRG-MOVE-1 keeps it
          in that group through the move, so a place for it in the wave's
          group would bill for nothing. "Its own group" is CRG-MOVE-1's rule,
          Get-VmfOwnReservationGroup, asked of the plan entry's assessment
          (plan-entry v30, capacityReservationGroupId). An entry with no such
          field does not say, and is reservable: unknown is never a no.
    .PARAMETER ProductGroupIds
        Get-VmfProductReservationGroupIds of the run: a group of this migration
        is never the machine's own. Required, so no caller can forget it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Entry,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds
    )

    if (-not $Entry) { return $false }
    if ($Entry.assessment -and $Entry.assessment.PSObject.Properties['availabilitySetId'] -and
        [string]$Entry.assessment.availabilitySetId) { return $false }
    -not (Get-VmfOwnReservationGroup -Capture $Entry.assessment -ProductGroupIds @($ProductGroupIds))
}

function Get-VmfFinishedVmIds {
    <#
    .SYNOPSIS
        The machines of a run that are MIGRATED or SKIPPED - done, so the quota
        check leaves them out of the demand on purpose (RETRY-SERIES-1).
    .DESCRIPTION
        ONE answer for the quota check and the capacity gate. A gate that asked
        for a record for a machine the check had left out would refuse every
        restart of a part-finished wave. Only the state documents that exist
        are read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RunPath)

    @(foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json')) {
        $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$name"
        if ($doc -and [string]$doc.state -in @('MIGRATED', 'SKIPPED')) { [string]$doc.vmId }
    })
}

function Test-VmfMoveStarted {
    <#
    .SYNOPSIS
        STATE-TARGET-1: has this machine's move started? Past PRECHECK, with
        the target it started recorded. Such a machine finishes the move it
        started, whatever its plan entry says now - so nothing may leave it
        out of the capacity it will use. One rule, read by the state machine
        and by the capacity checks.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    [bool]($Doc -and [string]$Doc.state -notin @('PLANNED', 'PRECHECK') -and $Doc.captured -and
        $Doc.captured.PSObject.Properties['startedTarget'])
}

function Get-VmfStartedVmIds {
    <#
    .SYNOPSIS
        GPU-SCOPE-1 review: the machines of a run whose move has started
        (Test-VmfMoveStarted). Only the state documents that exist are read.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][string]$RunPath)

    @(foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json')) {
        $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$name"
        if (Test-VmfMoveStarted -Doc $doc) { [string]$doc.vmId }
    })
}

function Test-VmfMoveResized {
    <#
    .SYNOPSIS
        QUOTA-STARTED-TWICE-1: does the state document SAY the machine is on
        its target size already, so Azure's usage figure counts it? VALIDATING
        comes after the first start on it. Anything else - the resize writes
        no checkpoint of its own - is not known, and reads as not resized: its
        need is counted, which is the safe side for the machine.
        REBUILD-REMOVE-ENGINE-1: Path B's B:recreated no longer counts - no
        move rebuilds a machine.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    if (-not $Doc) { return $false }
    $state = [string]$Doc.state
    # Not STARTING: the machine may not be allocated on its new size yet.
    $state -eq 'VALIDATING'
}

function Get-VmfContinuingMoves {
    <#
    .SYNOPSIS
        QUOTA-STARTED-TWICE-1: the machines of a run that will CONTINUE the
        move they started - past PRECHECK with the target recorded
        (Test-VmfMoveStarted), and in a working state. A machine in a terminal
        state (FAILED_ROLLED_BACK, NEEDS_DECISION, FAILED_NEEDS_ATTENTION) is
        not taken by a worker; its next run is a retry or a decision, which
        starts again from PRECHECK or re-arms a working state then. So it is
        counted like a machine that has not started.
    .OUTPUTS
        One object per machine: VmId, State, Resized (Test-VmfMoveResized) and
        Size (the size its move started with, STATE-TARGET-1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)

    $terminal = @((Get-VmfEngineStates).Terminal)
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json')) {
        $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$name"
        if (-not (Test-VmfMoveStarted -Doc $doc) -or [string]$doc.state -in $terminal) { continue }
        $started = $doc.captured.startedTarget
        $size = if ($started -and $started.PSObject.Properties['target'] -and $started.target) { [string]$started.target.size } else { '' }
        [pscustomobject]@{ VmId = [string]$doc.vmId; State = [string]$doc.state; Resized = (Test-VmfMoveResized -Doc $doc); Size = $size }
    }
}

function Get-VmfLeftOutVmIds {
    <#
    .SYNOPSIS
        The machines the quota check leaves out of the demand, and so the
        capacity gate asks no record for: MIGRATED or SKIPPED
        (Get-VmfFinishedVmIds), and - GPU-SCOPE-1 - a machine outside the scope
        of the product (Test-VmfEntryOutOfScope) whose move has NOT started.
    .DESCRIPTION
        ONE answer for the quota check, the capacity gate, the Reserved gate
        and a reservation. PRECHECK stops an out-of-scope machine untouched,
        so it uses no capacity. A machine whose move started finishes it
        (STATE-TARGET-1) - with no later scope check - so it is never left out:
        leaving it out would count too little quota, or give its reservation
        slot to another machine.
    .PARAMETER Entries
        The plan entries to judge for scope. Finished machines are left out
        whatever is passed.
    .PARAMETER FinishedVmIds
        Get-VmfFinishedVmIds, when the caller has read it already - so the
        state documents are not read twice.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][AllowNull()][object[]]$Entries,
        [Parameter()][AllowNull()][string[]]$FinishedVmIds
    )

    $ids = [System.Collections.Generic.List[string]]::new()
    $done = if ($PSBoundParameters.ContainsKey('FinishedVmIds')) { @($FinishedVmIds) } else { @(Get-VmfFinishedVmIds -RunPath $RunPath) }
    foreach ($id in @($done | Where-Object { $_ })) { $ids.Add([string]$id) }
    $scoped = @($Entries | Where-Object { $_ -and (Test-VmfEntryOutOfScope -Entry $_) })
    if ($scoped.Count) {
        $started = @(Get-VmfStartedVmIds -RunPath $RunPath)
        foreach ($e in $scoped) {
            $id = [string]$e.vmId
            if ($id -notin $started -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    @($ids)
}

function Test-VmfWaveNeedsNoCapacity {
    <#
    .SYNOPSIS
        GPU-SCOPE-1 review: is every machine of the wave still to run outside
        the scope of this tool? Then nothing will use capacity: the quota check
        writes no record, and the gate must not wait for one. PRECHECK gives
        each machine its own stop, with its reason.
    .PARAMETER FinishedVmIds
        Get-VmfFinishedVmIds.
    .PARAMETER LeftOutVmIds
        Get-VmfLeftOutVmIds for the same entries.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()][object[]]$Entries,
        [Parameter()][AllowNull()][string[]]$FinishedVmIds,
        [Parameter()][AllowNull()][string[]]$LeftOutVmIds
    )
    $open = @($Entries | Where-Object { $_ -and [string]$_.vmId -notin @($FinishedVmIds) })
    $open.Count -gt 0 -and @($open | Where-Object { [string]$_.vmId -notin @($LeftOutVmIds) }).Count -eq 0
}

function Resolve-VmfWaveNeedsNoCapacity {
    <#
    .SYNOPSIS
        Test-VmfWaveNeedsNoCapacity for a wave in a run. A wave with no machine
        outside the scope of this tool reads nothing more than before: the
        state documents are read only when one machine is out of scope.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][AllowNull()][object[]]$Entries
    )
    if (-not @($Entries | Where-Object { $_ -and (Test-VmfEntryOutOfScope -Entry $_) }).Count) { return $false }
    $finished = @(Get-VmfFinishedVmIds -RunPath $RunPath)
    Test-VmfWaveNeedsNoCapacity -Entries $Entries -FinishedVmIds $finished `
        -LeftOutVmIds @(Get-VmfLeftOutVmIds -RunPath $RunPath -Entries $Entries -FinishedVmIds $finished)
}

function Get-VmfReservedCoverageGaps {
    <#
    .SYNOPSIS
        RESERVE-COVER-1: the machines of a wave that no quota record covers as
        they need. RESERVE-COVER-2: for a wave with no capacity reservation
        (BestEffort) as well as a Reserved one.
    .DESCRIPTION
        A record covers a machine when it is for the machine's wave,
        subscription (from its resource id), region, zone and target size - the
        cell Test-VmfQuota groups by, and Get-VmfClaimForEntry matches on.
        - A machine a reservation can hold, in a Reserved wave, needs a record
          that counts it (reservable demand) at RESERVED or CONSUMED.
        - A machine in an availability set needs a record at QUOTA_VERIFIED or
          above (AVSET-RESERVE-1: judged on its quota check alone).
        - In a BestEffort wave, EVERY machine is judged that way: nothing is
          reserved, so its quota check is the whole question (RESERVE-COVER-2).
        Each gap has a Kind:
          noRecord    - no record of the cell, or none that counts this machine
                        as reservable. Checking the quota again writes it.
          notReserved - a reservable record of the cell that is not held.
          reserving   - its record is being reserved now.
          quota       - a machine judged on the quota rung (in an availability
                        set, or any machine under BestEffort) whose record is
                        below it (blocked); the capacity gate's to judge.
    .PARAMETER Entries
        The machines of the wave that move: Get-VmfWaveOptionsEntries.
    .PARAMETER FinishedVmIds
        Get-VmfLeftOutVmIds (Get-VmfFinishedVmIds, and GPU-SCOPE-1's machines
        outside the scope of this tool). Those machines are left out.
    .PARAMETER Gate
        The wave's capacity gate. Reserved (the default) holds a machine a
        reservation can hold to a reservation; BestEffort holds every machine
        to its quota check.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object[]]$Claims,
        [Parameter()][AllowNull()][object[]]$Entries,
        [Parameter()][AllowNull()][string[]]$FinishedVmIds,
        [Parameter()][ValidateSet('BestEffort', 'Reserved')][string]$Gate = 'Reserved',
        # CRG-MOVE-DEMAND-1: the run's groups (Get-VmfProductReservationGroupIds),
        # for Test-VmfEntryReservable. A machine in its own group is judged
        # on its quota check, as an availability set member is.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )

    $finished = @{}
    foreach ($id in @($FinishedVmIds | Where-Object { $_ })) { $finished[$id] = $true }
    $all = @($Claims | Where-Object { $_ })

    foreach ($entry in @($Entries | Where-Object { $_ })) {
        $vmId = [string]$entry.vmId
        if ($finished.ContainsKey($vmId)) { continue }
        $zone = if ($entry.target -and $entry.target.PSObject.Properties['zone']) { [string]$entry.target.zone } else { '' }
        $size = if ($entry.target) { [string]$entry.target.size } else { '' }
        $region = if ($entry.assessment) { [string]$entry.assessment.location } else { '' }
        $cell = @($all | Where-Object { Test-VmfClaimCellMatchesEntry -Claim $_ -Entry $entry })
        $reservable = Test-VmfEntryReservable -Entry $entry -ProductGroupIds @($ProductGroupIds)

        $kind = $null
        $blockReason = $null
        # RESERVE-COVER-2: a BestEffort wave reserves nothing, so a machine a
        # reservation could hold is judged as an availability-set one is.
        if ($reservable -and $Gate -eq 'Reserved') {
            $counting = @($cell | Where-Object { Test-VmfClaimReservable -Claim $_ })
            if ($counting.Count -eq 0) { $kind = 'noRecord' }
            elseif (@($counting | Where-Object { $_.state -in @('RESERVED', 'CONSUMED') }).Count -gt 0) { $kind = $null }
            elseif (@($counting | Where-Object { $_.state -eq 'RESERVING' }).Count -gt 0) { $kind = 'reserving' }
            else {
                $kind = 'notReserved'
                # Review finding 6: a record blocked on its quota is named as
                # blocked - checking again changes nothing until it is corrected.
                $why = @($counting | Where-Object { Test-VmfClaimBlocked -Claim $_ } |
                         ForEach-Object { [string]$_.blockReason } | Where-Object { $_ } | Sort-Object -Unique)
                if (@($counting | Where-Object { Test-VmfClaimBlocked -Claim $_ }).Count -gt 0) {
                    $blockReason = if ($why.Count) { $why -join ', ' } else { 'blocked' }
                }
            }
        }
        else {
            if ($cell.Count -eq 0) { $kind = 'noRecord' }
            elseif (@($cell | Where-Object { $_.state -in @('QUOTA_VERIFIED', 'RESERVED', 'CONSUMED') }).Count -eq 0) {
                $kind = 'quota'
                # RESERVE-RECHECK-1: why, so the start's refusal names the
                # action for the cause, as notReserved does above.
                $blockedHere = @($cell | Where-Object { Test-VmfClaimBlocked -Claim $_ })
                if ($blockedHere.Count -gt 0) {
                    $why = @($blockedHere | ForEach-Object { [string]$_.blockReason } | Where-Object { $_ } | Sort-Object -Unique)
                    $blockReason = if ($why.Count) { $why -join ', ' } else { 'blocked' }
                }
            }
        }
        if (-not $kind) { continue }
        [pscustomobject]@{
            VmId       = $vmId
            Name       = ($vmId -split '/')[-1]
            Size       = $size
            Region     = $region
            Zone       = $zone
            Reservable = $reservable
            Kind       = $kind
            BlockReason = $blockReason
        }
    }
}

function Get-VmfReservedCoverRefusal {
    <#
    .SYNOPSIS
        RESERVE-COVER-1: the refusal for machines a wave cannot start without -
        a code, and two sentences that name each machine with its size and say
        what to do. A Reserved wave, and since RESERVE-COVER-2 a BestEffort one.
    .DESCRIPTION
        GATE-WORDS-1's pattern: the words live in data/start-gates.json (gate
        capacity), where tools/Test-SimplifiedEnglish.ps1 checks them, and a
        caller asks the code, never the words. The migration's page shows the
        first sentence of a refused start, so that sentence names the machines.
    .OUTPUTS
        @{ Pass = $false; Gate; Code; Detail }, or $null when no gap is of a
        kind it speaks for (noRecord, notReserved, or - RESERVE-RECHECK-1 -
        quota with a blocked record).
    .PARAMETER Gate
        RESERVE-COVER-2: the wave's capacity gate. A BestEffort wave reserves
        nothing, so its instruction is to check the quota and start - never to
        reserve.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][object[]]$Gaps,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][ValidateSet('BestEffort', 'Reserved')][string]$Gate = 'Reserved'
    )

    $none = @($Gaps | Where-Object { $_ -and $_.Kind -eq 'noRecord' })
    if ($none.Count -gt 0) {
        # A machine in an availability set needs only the check. Any machine a
        # reservation can hold needs the reservation after it - in a Reserved
        # wave. A BestEffort wave needs only the check (RESERVE-COVER-2).
        $code = if ($Gate -eq 'Reserved' -and @($none | Where-Object Reservable).Count -gt 0) { 'noQuotaRecord' } else { 'noQuotaRecordGeneral' }
        return (New-VmfStartGateRefusal -Code $code -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $none))
    }
    # RESERVE-RECHECK-1: a machine judged on its quota check alone (any
    # machine of a BestEffort wave, or one in an availability set) whose
    # record is blocked. Every start checks the quota again, so this is what a
    # start says when quota was taken after the last check. These machines move
    # on general capacity, so the words say quota and never ask to reserve.
    $quotaBlocked = @($Gaps | Where-Object { $_ -and $_.Kind -eq 'quota' -and $_.BlockReason })
    foreach ($cause in @(
            @{ Code = 'quotaShortGeneral';  Reasons = @('quota-shortfall') }
            # REGIONAL-VCPU-QUOTA-1: its own words, because Request an increase
            # raises a family limit and never the Total Regional vCPUs.
            @{ Code = 'regionalQuotaShortGeneral'; Reasons = @('regional-quota-shortfall') }
            @{ Code = 'sizeBlockedGeneral'; Reasons = @('sku-restricted', 'size-missing') })) {
        $these = @($quotaBlocked | Where-Object { @($_.BlockReason -split ',\s*' | Where-Object { $_ -in $cause.Reasons }).Count -gt 0 })
        if ($these.Count -gt 0) {
            return (New-VmfStartGateRefusal -Code $cause.Code -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $these))
        }
    }
    if ($quotaBlocked.Count -gt 0) {
        return (New-VmfStartGateRefusal -Code 'quotaBlockedGeneral' -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $quotaBlocked))
    }
    # Review finding 6: a blocked record is named as blocked - checking again
    # changes nothing until the cause is corrected. One code per cause, so the
    # instruction names the action for it (the second review): a quota
    # increase, another target size, or a reservation Azure refused. A cause
    # this build does not know is said as blocked with no reason recorded.
    $blocked = @($Gaps | Where-Object { $_ -and $_.Kind -eq 'notReserved' -and $_.BlockReason })
    foreach ($cause in @(
            @{ Code = 'quotaShortBesideHeld';        Reasons = @('quota-shortfall') }
            @{ Code = 'regionalQuotaShortBesideHeld'; Reasons = @('regional-quota-shortfall') }
            @{ Code = 'sizeBlockedBesideHeld';       Reasons = @('sku-restricted', 'size-missing') }
            @{ Code = 'reservationFailedBesideHeld'; Reasons = @('reservation-failed') })) {
        $these = @($blocked | Where-Object { @($_.BlockReason -split ',\s*' | Where-Object { $_ -in $cause.Reasons }).Count -gt 0 })
        if ($these.Count -gt 0) {
            return (New-VmfStartGateRefusal -Code $cause.Code -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $these))
        }
    }
    if ($blocked.Count -gt 0) {
        return (New-VmfStartGateRefusal -Code 'quotaBlockedBesideHeld' -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $blocked))
    }
    # Checking again turns a released record back into a quota check, and
    # Reserve reserves only those - so this instruction is right for every
    # state but RESERVING, which the caller says first.
    $open = @($Gaps | Where-Object { $_ -and $_.Kind -eq 'notReserved' })
    if ($open.Count -gt 0) {
        return (New-VmfStartGateRefusal -Code 'notReservedBesideHeld' -Wave $Wave -Machines (Get-VmfCoverMachineList -Gaps $open))
    }
    $null
}
function Get-VmfCoverMachineList {
    <#
    .SYNOPSIS
        RESERVE-COVER-1: "machine 'app-2' (Standard_E2s_v6)", or up to three
        named and the rest counted - for the start's refusal and Reserve's. A block reason is said by the code chosen, never as its raw name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][object[]]$Gaps)

    $list = @($Gaps | Where-Object { $_ })
    $shown = @($list | Select-Object -First 3 | ForEach-Object { "'$($_.Name)' ($($_.Size))" })
    $more = $list.Count - $shown.Count
    $text = if ($shown.Count -le 1) { $shown -join '' }
            else { ($shown[0..($shown.Count - 2)] -join ', ') + ' and ' + $shown[-1] }
    if ($more -gt 0) { $text += " and $more more" }
    $(if ($list.Count -eq 1) { 'machine ' } else { 'machines ' }) + $text
}

function Test-VmfClaimCellMatchesEntry {
    <#
    .SYNOPSIS
        RESERVE-COVER-1: is this quota record for this plan entry's cell - its
        wave, subscription (from its resource id), region, zone and target
        size? The cell Test-VmfQuota groups by. ONE predicate for the coverage
        rule and Get-VmfClaimForEntry, which adds the state and the group.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Claim, [Parameter()][AllowNull()]$Entry)

    if (-not $Claim -or -not $Entry) { return $false }
    $sub = Get-VmfSubscriptionId -ResourceId ([string]$Entry.vmId)
    if (-not $sub) { return $false }
    $zone = if ($Entry.target -and $Entry.target.PSObject.Properties['zone']) { [string]$Entry.target.zone } else { '' }
    $size = if ($Entry.target) { [string]$Entry.target.size } else { '' }
    $region = if ($Entry.assessment) { [string]$Entry.assessment.location } else { '' }
    # CLAIM-NAME-1 review: one comparer for a record and a cell.
    Test-VmfClaimOfCell -Claim $Claim -Wave ([string]$Entry.wave) -SubscriptionId $sub -Region $region -Zone $zone -Size $size
}

function Select-VmfClaimsOfOpenMachines {
    <#
    .SYNOPSIS
        RESERVE-COVER-1 review: the records of a wave whose cell still holds a
        machine that will move. A record of a cell whose machines are all done
        is not the gate's business any more.
    .DESCRIPTION
        The quota check writes nothing for a cell with no open machine, so it
        never replaces such a record. Judged by the gate, a RELEASED one - left
        by a Release after a rollback - refused the restart of a part-finished
        wave for ever, while the reservation made for the rest of the wave
        billed. Found by the independent review of this change.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object[]]$Claims,
        [Parameter()][AllowNull()][object[]]$Entries,
        [Parameter()][AllowNull()][string[]]$FinishedVmIds
    )
    $open = @($Entries | Where-Object { $_ -and [string]$_.vmId -notin @($FinishedVmIds) })
    @($Claims | Where-Object {
        $c = $_
        $c -and @($open | Where-Object { Test-VmfClaimCellMatchesEntry -Claim $c -Entry $_ }).Count -gt 0
    })
}