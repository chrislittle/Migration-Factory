# ODCR-STATE-1, 2026-09-19. What a wave set to a capacity reservation is told when
# its capacity is not held yet.
#
# The old refusal made no sense while the ODCR was still being deployed in
# Azure: it described the options, not what the person did.
#
# A claim sits at RESERVING for the WHOLE time Azure is building the
# reservation - minutes - and lands on BLOCKED when Azure refuses.
# The gate accepted only RESERVED or CONSUMED, so every one of those produced
# "no capacity has been reserved for it ... use Reserve capacity", which tells
# somebody to do what they just did and hides an outright failure behind an
# instruction.
#
# PURE ON PURPOSE (hard rule 5): the gate that calls this reads the store and
# throws. This decides only WHICH SENTENCE is true of a set of claims, so a
# test can drive every state instead of reading the source for a phrase.

function Get-VmfReservedCapacityRefusal {
    <#
    .SYNOPSIS
        ODCR-STATE-1: why a Reserved wave cannot start, in the words that fit.
    .OUTPUTS
        $null when capacity IS held and the wave may start, otherwise the
        sentence to show and record.
    .PARAMETER Claims
        This wave's quota records. An empty set means nobody ever asked.
    .PARAMETER Wave
        The wave's name, for the message.
    .PARAMETER NowUtc
        Injected so the "started N minutes ago" line is testable.
    .PARAMETER ReservableMachines
        AVSET-RESERVE-1: how many machines of the wave, in the PLAN, are outside
        an availability set. -1 (the default) is unknown. Only 0 lets a wave
        whose claims have nothing reservable start without a reservation: the
        claims that exist can be a partial set (a quota check that stopped half
        way, or another container still writing them), and judging from them
        alone would start ordinary machines unreserved.
    .PARAMETER Entries
        RESERVE-COVER-1: the machines of the wave that move
        (Get-VmfWaveOptionsEntries). Given, the refusal judges the MACHINES:
        each needs a record of its own cell (Get-VmfReservedCoverageGaps), and
        a machine with none is named, with its size. ReservableMachines is then
        counted from these, leaving out the finished ones. Not given, it judges
        the records alone, as before.
    .PARAMETER FinishedVmIds
        Get-VmfFinishedVmIds: machines that are MIGRATED or SKIPPED, which need
        no record.
    .PARAMETER AsRecord
        GATE-WORDS-1: return the refusal for machines with no record, or with
        none reserved beside one that is, as its record (@{ Code; Detail ... }),
        so the caller can log the code. Every other refusal is still a sentence.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()][object[]]$Claims,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][datetime]$NowUtc = (Get-Date).ToUniversalTime(),
        [Parameter()][int]$ReservableMachines = -1,
        [Parameter()][AllowNull()][object[]]$Entries,
        [Parameter()][AllowNull()][string[]]$FinishedVmIds,
        [Parameter()][switch]$AsRecord,
        # CRG-MOVE-DEMAND-1: the run's groups (Get-VmfProductReservationGroupIds),
        # for the one rule of which machine a reservation holds.
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )

    $all = @($Claims | Where-Object { $_ })
    $say = { param($Record) if (-not $Record) { $null } elseif ($AsRecord) { $Record } else { [string]$Record.Detail } }

    # RESERVING-STUCK-1: "wait" is only true while somebody is making it. Asked
    # before the held check: a wave with a held cell and one Azure never
    # confirmed is not reserved as planned. Release is the way out - a wave
    # whose claim bills cannot be saved to another setting.
    $stuck = @($all | Where-Object { Test-VmfClaimReservingStuck -Claim $_ -NowUtc $NowUtc })
    if ($stuck.Count -gt 0) {
        return ("Azure has not confirmed the on-demand capacity reservation for wave '$Wave', and it may be billing. " +
                'Select Release on the wave, then reserve again.')
    }

    # AVSET-RESERVE-1: only a claim with something to reserve can be waiting
    # for a reservation. A claim of only availability-set machines never gets
    # one - Azure does not allow it - so judging it here made a mixed wave
    # unstartable and an all-availability-set wave a dead end that said
    # "reserve capacity" to a control that reserves nothing. Those machines
    # move on general capacity; their quota is the capacity gate's question.
    # No claims at all is still "nobody asked" below: unknown is not general.
    # And the PLAN must agree that every machine is in an availability set -
    # see ReservableMachines. Otherwise this falls through to "nobody asked".
    # RESERVE-COVER-1: judge the MACHINES. A quota check that stopped half way,
    # or a second container reading while the first still writes, leaves a
    # partial set, and every record of a partial set can be RESERVED. A machine
    # with no record of its cell is named, with its size, before anything else
    # is said - checking the quota again is what writes it. Machines that are
    # done are left out, as the quota check leaves them out of the demand.
    $gaps = @()
    $byMachine = $PSBoundParameters.ContainsKey('Entries')
    if ($byMachine) {
        $open = @($Entries | Where-Object { $_ -and [string]$_.vmId -notin @($FinishedVmIds) })
        $gaps = @(Get-VmfReservedCoverageGaps -Claims $all -Entries $open -ProductGroupIds @($ProductGroupIds))
        $missing = Get-VmfReservedCoverRefusal -Wave $Wave -Gaps @($gaps | Where-Object Kind -eq 'noRecord')
        if ($missing) { return (& $say $missing) }
        $ReservableMachines = Get-VmfReservableEntryCount -Entries $open -ProductGroupIds @($ProductGroupIds)
        # Review finding 1: a record whose cell holds no machine that will move
        # says nothing about this start. The quota check never replaces it, so
        # a RELEASED one left after a rollback refused a restart for ever.
        $all = @(Select-VmfClaimsOfOpenMachines -Claims $all -Entries $open)
    }

    $needs = @($all | Where-Object { Test-VmfClaimReservable -Claim $_ })
    if ($all.Count -gt 0 -and $needs.Count -eq 0 -and $ReservableMachines -eq 0) { return $null }
    $all = $needs

    # A held record used to end the refusal here, so a cell nobody reserved
    # beside one that is held reached only the gate's raw detail. With the
    # machines known, that cell's machines are named - unless Azure is
    # reserving it now, which is "wait" below (reserving again pays twice).
    $reserving = @($all | Where-Object { $_.state -eq 'RESERVING' })
    if (@($all | Where-Object { $_.state -in @('RESERVED', 'CONSUMED') }).Count -gt 0) {
        if (-not $byMachine) { return $null }
        if (@($gaps | Where-Object Kind -eq 'reserving').Count -eq 0) {
            return (& $say (Get-VmfReservedCoverRefusal -Wave $Wave -Gaps @($gaps | Where-Object Kind -eq 'notReserved')))
        }
    }

    if ($reserving.Count -gt 0) {
        # How long it has been going is the difference between "wait" and
        # "something is stuck". A claim with no timestamp says neither.
        $since = @($reserving | ForEach-Object { [string]$_.reservingSinceUtc } |
                   Where-Object { $_ } | Sort-Object | Select-Object -First 1)
        $age = ''
        if ($since) {
            $started = [datetime]::Parse($since, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
            $mins = [math]::Max(0, [math]::Round(($NowUtc - $started).TotalMinutes))
            $age = " It started $mins minute(s) ago."
        }
        return ("Wave '$Wave' is having its capacity reserved now.$age " +
                'Azure can take some minutes to make an on-demand capacity reservation. Wait for the wave to say Reserved, then start it. ' +
                'Do not reserve again, because a second on-demand capacity reservation also bills.')
    }

    $blocked = @($all | Where-Object { Test-VmfClaimBlocked -Claim $_ })
    if ($blocked.Count -gt 0) {
        $why = (@($blocked | ForEach-Object { [string]$_.blockReason } |
                 Where-Object { $_ } | Sort-Object -Unique) -join ', ')
        $said = @($blocked | ForEach-Object { @($_.notes) } | Where-Object { $_ } | Select-Object -Last 1)
        return ("Reserving capacity for wave '$Wave' did not work" +
                $(if ($why) { " ($why)" } else { '' }) + '. ' +
                $(if ($said) { "Azure said: $said " } else { '' }) +
                'Nothing is held and nothing is billing. Correct the cause and reserve again, or set On-demand capacity reservation for this wave to No.')
    }

    if (@($all | Where-Object { $_.state -eq 'RELEASED' }).Count -gt 0) {
        return ("The capacity reserved for wave '$Wave' was released, so nothing is held for it now. " +
                'Reserve it again, or set On-demand capacity reservation for this wave to No.')
    }

    # FORECAST, QUOTA_VERIFIED, QUOTA_REQUESTED and no claim at all are the
    # same thing to a person: nobody has asked for a reservation yet. This is
    # the ONE case the original sentence was right for.
    ("Wave '$Wave' is set to On-demand capacity reservation, and no capacity has been reserved for it. " +
     'Reserving is a separate action that spends money - ' +
     'use Reserve capacity on the wave in the wave editor, or set the wave to no ' +
     'on-demand capacity reservation if a guarantee is not required.')
}

function Get-VmfReservedGeneralNote {
    <#
    .SYNOPSIS
        AVSET-RESERVE-1: the line a Reserved wave's start writes when some or
        all of its machines move on general capacity.
    .DESCRIPTION
        A machine in an availability set cannot use a capacity reservation, so a
        wave set to Reserved starts with those machines on general capacity -
        the same thing the report says of each of them afterwards. Said once, at
        the start, so nobody reads a Reserved wave as fully reserved.
        Pure: which sentence is true of these claims.
    .OUTPUTS
        The sentence, or $null when every machine is reservable.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][object[]]$Claims,
        [Parameter(Mandatory)][string]$Wave,
        # As for Get-VmfReservedCapacityRefusal: machines of the wave in the
        # plan outside an availability set, -1 unknown. "Every machine" is said
        # only when the plan says 0.
        [Parameter()][int]$ReservableMachines = -1
    )

    $all = @($Claims | Where-Object { $_ })
    $general = 0
    foreach ($c in $all) { $general += Get-VmfClaimGeneralInstances -Claim $c }
    # CRG-MOVE-DEMAND-1: the machines that stay in their own capacity
    # reservation group, by name (demand.ownGroupVmIds, capacity-claim v15).
    # They are not in an availability set, and they do move on a capacity
    # reservation - their own.
    $own = @($all | ForEach-Object { Get-VmfClaimOwnGroupVmIds -Claim $_ } | Where-Object { $_ } | Sort-Object -Unique)
    if ($general -eq 0 -and $own.Count -eq 0) { return $null }
    $ownNames = (@($own | ForEach-Object { ([string]$_ -split '/')[-1] }) -join ', ')
    $allGeneral = ($ReservableMachines -eq 0 -and @($all | Where-Object { Test-VmfClaimReservable -Claim $_ }).Count -eq 0)

    if ($own.Count -eq 0) {
        if ($allGeneral) {
            return ("Wave '$Wave' is set to On-demand capacity reservation, but every machine in it is in an availability set. " +
                    'Azure does not allow an on-demand capacity reservation for these machines, so the wave starts with no on-demand capacity reservation.')
        }
        return ("Wave '$Wave' starts on its on-demand capacity reservation, except $general machine(s) in an availability set. " +
                'Azure does not allow an on-demand capacity reservation for those machines, so they move with no on-demand capacity reservation.')
    }
    $ownWords = "$ownNames, which stay in their own capacity reservation group"
    $why = $(if ($general -gt 0) { 'Azure does not allow an on-demand capacity reservation for a machine in an availability set, so it moves with no on-demand capacity reservation. ' } else { '' }) +
           'The move keeps a machine in its own capacity reservation group.'
    $except = $(if ($general -gt 0) { "$general machine(s) in an availability set, and $ownWords" } else { $ownWords })
    if ($allGeneral) {
        return ("Wave '$Wave' is set to On-demand capacity reservation, but no machine in it uses the on-demand capacity reservation of the wave: $except. " +
                $why + ' So the wave reserves no capacity.')
    }
    "Wave '$Wave' starts on its on-demand capacity reservation, except $except. $why"
}

function Get-VmfReservableEntryCount {
    <#
    .SYNOPSIS
        AVSET-RESERVE-1: how many of these plan entries a capacity reservation
        can hold - every one that is not in an availability set, and
        (CRG-MOVE-DEMAND-1) not in a capacity reservation group of its own.
    .DESCRIPTION
        The PLAN's answer, not the quota records'. The records can be a partial
        set while a quota check is written cell by cell, and a wave is judged
        "all general capacity" only when the plan agrees. The same test the
        quota check (Test-VmfQuota, CAP-2) and the state machine use for an
        availability-set member.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter()][AllowNull()][object[]]$Entries,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )

    @($Entries | Where-Object { Test-VmfEntryReservable -Entry $_ -ProductGroupIds @($ProductGroupIds) }).Count
}