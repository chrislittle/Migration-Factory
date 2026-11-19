# SCALE-1, the half that was still open.
#
# At scale, the engine needs tooling to handle throttling when quota or
# capacity is not available, so that a run does not fail for it.
#
# Per-call retry already handles an individual 429, and capacity back-pressure
# already halts a wave whose cells are exhausted. What neither does is SPREAD
# LOAD: N workers call ARM concurrently with no coordination, so a wave large
# enough to throttle throttles all at once and every worker burns its retry
# budget in parallel on the same overloaded endpoint.
#
# The fix is not a distributed token bucket. Workers are separate processes with
# only the run store between them, and a per-call coordination round trip would
# cost more than it saves. What actually helps is cheaper: WHEN ONE WORKER IS
# THROTTLED, TELL THE OTHERS. One worker discovering a 429 is evidence about the
# subscription, not about that worker, and the others are about to find out the
# same way.
#
# So: a throttled worker publishes a short cool-off, every worker reads it
# (cached, so this is not a store round trip per ARM call), and each waits a
# JITTERED slice of it. The jitter is the point - workers that all resume at the
# same instant have simply moved the stampede, which is the failure this is
# meant to remove rather than reschedule.

# Per-process cache. A store read per ARM call would be its own load problem.
$script:VmfPacingCache = @{}

function Write-VmfThrottleSignal {
    <#
    .SYNOPSIS
        SCALE-1: tell every other worker on this run that ARM is throttling.
    .DESCRIPTION
        Called when a request comes back throttled. Records a cool-off that
        expires on its own - there is no "all clear" message, because a worker
        that died holding one would silence the whole run.
    .PARAMETER Seconds
        How long to ask other workers to ease off. Deliberately SHORT: this
        spreads a burst, it does not pause a migration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][int]$Seconds = 10
    )

    try {
        $until = (Get-Date).ToUniversalTime().AddSeconds($Seconds)
        Write-VmfStoreJson -RunPath $RunPath -RelPath 'pacing.json' -Depth 4 -Document ([ordered]@{
            schemaVersion    = 1
            throttledUntilUtc = $until.ToString('o')
            observedUtc      = (Get-Date).ToUniversalTime().ToString('o')
        })
        # The publishing worker trusts what it just wrote rather than reading it
        # back, so its own next call is paced too.
        $script:VmfPacingCache[$RunPath] = @{ Until = $until; ReadAt = (Get-Date).ToUniversalTime() }
    }
    catch {
        # Pacing is an OPTIMISATION. Failing to publish the hint must never fail
        # the operation that was about to succeed.
        Write-Verbose "could not publish a throttle signal: $($_.Exception.Message)"
    }
}

function Get-VmfPacingWaitMs {
    <#
    .SYNOPSIS
        SCALE-1: how long this worker should wait before its next ARM call.
    .DESCRIPTION
        Pure enough to test: it reads the signal (cached) and returns a
        millisecond delay. It does not sleep - the caller does, so a test can
        assert the decision without waiting for it.

        Returns 0 when there is no signal, when it has expired, or when anything
        at all goes wrong. Pacing must never be the reason a migration stalls.
    .PARAMETER CacheTtlSeconds
        How stale a cached read may be. The signal is short-lived, so a few
        seconds of staleness costs little and saves a store read per ARM call.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][int]$CacheTtlSeconds = 5
    )

    try {
        $now = (Get-Date).ToUniversalTime()
        $entry = $script:VmfPacingCache[$RunPath]
        if (-not $entry -or ($now - $entry.ReadAt).TotalSeconds -ge $CacheTtlSeconds) {
            $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath 'pacing.json' -Depth 4
            $until = $null
            if ($doc -and $doc.throttledUntilUtc) {
                $raw = $doc.throttledUntilUtc
                if ($raw -is [datetime]) {
                    # ConvertFrom-Json ALREADY converted it. Round-tripping it
                    # through [string] formats it in the current culture, which
                    # drops the Z - and parsing that back as local time then
                    # converting to UTC pushes an EXPIRED signal into the future.
                    # Caught by the expiry test, which is the one case where
                    # being wrong means a run that paces itself for ever.
                    $until = $raw.ToUniversalTime()
                }
                else {
                    $parsed = [datetime]::MinValue
                    # RoundtripKind so a trailing Z parses as UTC rather than as
                    # local time that then gets shifted again.
                    if ([datetime]::TryParse([string]$raw, [cultureinfo]::InvariantCulture,
                            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) {
                        $until = $parsed.ToUniversalTime()
                    }
                }
            }
            $entry = @{ Until = $until; ReadAt = $now }
            $script:VmfPacingCache[$RunPath] = $entry
        }

        if (-not $entry.Until) { return 0 }
        $remainingMs = ($entry.Until - $now).TotalMilliseconds
        if ($remainingMs -le 0) { return 0 }

        # A JITTERED SLICE, not the whole cool-off. Every worker waiting the
        # full period and resuming together just moves the stampede; waiting a
        # random part of it is what actually spreads them out.
        [int](Get-Random -Minimum 0 -Maximum ([int][math]::Max(1, $remainingMs)))
    }
    catch {
        Write-Verbose "could not read the pacing signal: $($_.Exception.Message)"
        0
    }
}

function Clear-VmfPacingCache {
    <#
    .SYNOPSIS
        Drop the per-process pacing cache. For tests, and for a worker that has
        moved to a different run.
    #>
    [CmdletBinding()]
    param([Parameter()][string]$RunPath)
    if ($RunPath) { $script:VmfPacingCache.Remove($RunPath) | Out-Null }
    else { $script:VmfPacingCache = @{} }
}
