function Test-VmfQuotaAndReservation {
    <#
    .SYNOPSIS
        The wave capacity gate: every claim for the wave must be QUOTA_VERIFIED,
        and a wave set to Reserved needs RESERVED (or CONSUMED) on every claim
        that has a machine a reservation can hold. A claim of only
        availability-set machines is judged as BestEffort judges it, and those
        machines move on general capacity (AVSET-RESERVE-1). Every machine the
        wave moves must also have a record of its own cell - under Reserved
        (RESERVE-COVER-1) and under BestEffort (RESERVE-COVER-2): a partial set
        of records is not a pass.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter()][ValidateSet('BestEffort', 'Reserved')][string]$Gate = 'BestEffort',
        # AVSET-RESERVE-1: the wave's plan entries, when the caller holds them
        # (Start-VmfWave does). Read from the run's plan otherwise, and only
        # when the answer depends on them.
        [Parameter()][AllowNull()][object[]]$Entries
    )

    $claims = @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$_" -Depth 12 } |
        Where-Object { $_.wave -eq $Wave })

    # The wave's machines, read once, when the answer depends on them.
    $waveEntries = $null
    # Asked here: inside the block, PSBoundParameters is the block's own.
    $entriesGiven = $PSBoundParameters.ContainsKey('Entries')
    $readEntries = {
        if ($entriesGiven) { return , @($Entries) }
        try {
            $plan = Read-VmfPlanDocument -RunPath $OutPath
            if ($plan) { return , @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $Wave) }
        }
        catch { }
        $null
    }

    if ($claims.Count -eq 0) {
        # GPU-SCOPE-1 review: a wave whose every machine still to run is
        # outside the scope of this tool has no records, by design - nothing
        # will use capacity. It passes, and PRECHECK stops each machine with
        # its own reason. Refusing it said "no quota records yet" for ever.
        $waveEntries = & $readEntries
        if ($null -ne $waveEntries -and (Resolve-VmfWaveNeedsNoCapacity -RunPath $OutPath -Entries $waveEntries)) {
            return [pscustomobject]@{ Pass = $true; Wave = $Wave
                Detail = ("every machine of wave '$Wave' that is still to run is outside the scope of this tool, so nothing uses capacity. " +
                          'Each machine stops at Checking with its reason') }
        }
        # GATE-SAYS-1, MEASURED on a live run 2026-09-21. This named a command
        # and the dashboard cannot run one - hard rule 12, in the operator's
        # face, on the main path. Its twin in New-VmfWaveReservation was fixed
        # by RESERVE-QUOTA-1 the day before; this one was FOUND at the same
        # time, written down, and walked past. The rule was fixed where it was
        # found and nowhere else, which is this repository's defect of the
        # week.
        #
        # It does NOT derive the records here. This is a read: the page calls
        # it to show a status, and a status read must not go and do minutes of
        # Azure work. Start-VmfWave derives them when a wave actually starts,
        # and New-VmfWaveReservation derives them when somebody reserves. So
        # this says what is true and what happens next, and names no command.
        return [pscustomobject]@{ Pass = $false; Wave = $Wave
            Detail = ("no quota records for wave '$Wave' yet - they are written when the wave is planned, " +
                      'and checked again when it starts or when you reserve capacity') }
    }

    # RESERVE-COVER-1: under Reserved, judge the MACHINES the wave moves, not
    # only the records that exist. A quota check that stopped half way, or one
    # another container is still writing, leaves a partial set - and every
    # record of a partial set can be RESERVED, so the gate passed and the
    # machines of the missing cell moved on general capacity. Each machine
    # that moves and is not done (MIGRATED or SKIPPED, which the quota check
    # leaves out on purpose) needs a record of its own cell; the states of the
    # records are judged below. This took over AVSET-RESERVE-1's plan check,
    # which asked the same of a wave whose records were all availability-set
    # cells. Unknown is not a pass: a plan that cannot be read fails the gate.
    # RESERVE-COVER-2: and under BestEffort, the same rule on the quota rung.
    # The start ran the quota check only when the wave had NO records, so the
    # machines of a missing cell moved with their quota never checked, and a
    # shortfall met them inside the stopped window. Every machine that moves
    # needs a record of its own cell at QUOTA_VERIFIED or above, and a gate
    # with no plan to read is not a pass here either.
    $planGap = ''
    $uncovered = @()
    $judged = $claims
    if ($null -eq $waveEntries) { $waveEntries = & $readEntries }
    if ($null -eq $waveEntries) {
        $planGap = 'the plan could not be read to confirm that every machine of the wave has a quota record'
    }
    else {
        $finished = @(Get-VmfLeftOutVmIds -RunPath $OutPath -Entries $waveEntries)
        $uncovered = @(Get-VmfReservedCoverageGaps -Gate $Gate -Claims $claims -Entries $waveEntries -FinishedVmIds $finished -ProductGroupIds @(Get-VmfProductReservationGroupIds -RunPath $OutPath) |
            Where-Object Kind -eq 'noRecord')
        # Review finding 1: a record whose cell holds no machine that will
        # move is not judged - the quota check never replaces it, so a
        # RELEASED one left after a rollback refused the restart for ever
        # while the reservation for the rest of the wave billed. The same is
        # true on the BestEffort rung: such a record says nothing about this
        # start (RESERVE-COVER-2).
        $judged = @(Select-VmfClaimsOfOpenMachines -Claims $claims -Entries $waveEntries -FinishedVmIds $finished)
        if ($uncovered.Count -gt 0) {
            $planGap = "$($uncovered.Count) machine(s) of the wave have no quota record: " +
                (@($uncovered | ForEach-Object { "$($_.Name) ($($_.Size))" }) -join ', ') + ' - check the quota again'
        }
    }

    # Claim-state ladder: QUOTA_VERIFIED < RESERVED < CONSUMED. A gate passes
    # at-or-above its rung - RESERVED claims must never fail a BestEffort gate
    # (found by REH-1: runway before Start-VmfWave broke the pre-flight).
    $bestEffort = @('QUOTA_VERIFIED', 'RESERVED', 'CONSUMED')
    $satisfying = if ($Gate -eq 'Reserved') { @('RESERVED', 'CONSUMED') } else { $bestEffort }
    # AVSET-RESERVE-1: a claim with nothing reservable - only availability-set
    # machines, which Azure never puts on a reservation - can never reach
    # RESERVED. Holding it to that rung made a mixed Reserved wave unstartable
    # while its other cell's reservation billed. It is judged on the BestEffort
    # rung instead: its quota check stays, and its machines move on general
    # capacity.
    $general = @(if ($Gate -eq 'Reserved') { $judged | Where-Object { -not (Test-VmfClaimReservable -Claim $_) } })
    $notReady = @($judged | Where-Object {
        $rung = if ($Gate -eq 'Reserved' -and -not (Test-VmfClaimReservable -Claim $_)) { $bestEffort } else { $satisfying }
        $_.state -notin $rung })
    $generalSaid = if ($general.Count -gt 0) {
        $(if (@($general | Where-Object { @(Get-VmfClaimOwnGroupVmIds -Claim $_).Count }).Count -eq 0) {
            "; $($general.Count) claim(s) hold only machines in an availability set, judged on the quota check alone (they move with no capacity reservation)"
        } else {
            # CRG-MOVE-DEMAND-1: or machines that stay in their own group.
            "; $($general.Count) claim(s) hold only machines in an availability set or in their own capacity reservation group, judged on the quota check alone"
        })
    } else { '' }

    [pscustomobject]@{
        Pass   = ($notReady.Count -eq 0 -and -not $planGap)
        Wave   = $Wave
        Gate   = $Gate
        Claims = $claims.Count
        GeneralCapacityClaims = $general.Count
        # RESERVE-COVER-1: the machines with no quota record, each with its
        # name and size, so the wave editor can name them.
        Uncovered = @($uncovered | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Size = $_.Size; Region = $_.Region } })
        Detail = if ($planGap) { "the $Gate gate is not met: $planGap" }
                 elseif ($notReady.Count -eq 0) { "all $($judged.Count) claims satisfy $Gate ($($satisfying -join '/'))$generalSaid" }
                 else { "$($notReady.Count) claim(s) below the $Gate gate: " + (@($notReady | ForEach-Object { "$($_.size)@$($_.region) [$($_.state)]" }) -join ', ') + $generalSaid }
    }
}
