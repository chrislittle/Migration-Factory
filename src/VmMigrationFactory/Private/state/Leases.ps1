# Lease manager: exclusive-create lease documents under <store>/leases/.
# The atomic primitive is the store's exclusive create (FileMode.CreateNew on
# the file backend, blob PUT If-None-Match:* on azblob) - exactly one creator
# wins, which is what stops two workers (or two operators) from ever touching
# the same VM. Heartbeats are rewrites; expiry = stale heartbeat.
#
# LEASE-HEARTBEAT-RACE-1: after the create, every change to a lease is ONE STEP
# WITH ITS CHECK - the product's own mechanism for "nobody changed this since I
# read it" (PLANVER-2 versions, PLAN-WRITE-RACE-1):
#   a renewal  writes only if the lease is still the text it read
#              (Write-VmfStoreTextIfVersion: If-Match on blob storage, the lock
#              file on the file backend). It used to read, check the holder and
#              write with an ordinary write, so a takeover in between (the
#              watchdog removes the lease and another worker creates it, or a
#              restore takes it over) was written over, and two jobs both
#              believed they held the machine. A refused write is a LOST lease,
#              thrown with 'abandon this VM' - the words the state machine
#              treats as fencing, never as a step failure.
#   a removal  removes only the text it read (Remove-VmfStoreItemIfVersion),
#              which on the file backend waits for the lock a renewal holds.
#   the watchdog removes a lease only as it judged it expired
#              (Remove-VmfExpiredLease).

function Get-VmfLeaseRelPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmId)
    'leases/' + (Get-VmfVmKey -VmId $VmId) + '.lease'
}

function Get-VmfLeasePath {
    <#
    .SYNOPSIS
        FILE-BACKEND ONLY absolute path of a lease (legacy callers/tests).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    Join-Path $RunPath 'leases' ((Get-VmfVmKey -VmId $VmId) + '.lease')
}

function Get-VmfLeaseInfo {
    <#
    .SYNOPSIS
        Read a lease document (any backend). $null when not held.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    Read-VmfStoreJson -RunPath $RunPath -RelPath (Get-VmfLeaseRelPath -VmId $VmId) -Depth 6
}

function New-VmfLease {
    <#
    .SYNOPSIS
        Atomically claim a VM for a worker. Returns the lease object, or $null
        if another worker already holds it.
    .DESCRIPTION
        WAVE-RUNNING-LEASE-1: a lease is a contract, schemas/lease.schema.json,
        because the Migrations page and the wave editor read it. A renewal
        rewrites the lease it read, so it keeps the version.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$WorkerId
    )

    $now = (Get-Date).ToUniversalTime().ToString('o')
    $lease = [ordered]@{
        schemaVersion = 1
        vmId         = $VmId
        workerId     = $WorkerId
        acquiredUtc  = $now
        heartbeatUtc = $now
    }
    # STORE-CREATE-LOST-ANSWER-1: the worker id and the time make the text
    # this worker's own, so a create whose answer was lost is still its lease.
    if (Write-VmfStoreJsonExclusive -RunPath $RunPath -RelPath (Get-VmfLeaseRelPath -VmId $VmId) -Document $lease -UniqueText) {
        return [pscustomobject]$lease
    }
    return $null   # someone else holds the lease
}

function Update-VmfLeaseHeartbeat {
    <#
    .SYNOPSIS
        Renew a held lease. Throws if the caller no longer owns it (lease was
        reaped and possibly re-issued) - the worker must abandon the VM.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$WorkerId
    )

    $rel = Get-VmfLeaseRelPath -VmId $VmId
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
    if ($null -eq $text) { throw "Lease for '$VmId' no longer exists - abandon this VM." }
    $lease = $text | ConvertFrom-Json -Depth 6
    if ($lease.workerId -ne $WorkerId) {
        throw "Lease for '$VmId' is held by '$($lease.workerId)', not '$WorkerId' - abandon this VM."
    }
    $lease.heartbeatUtc = (Get-Date).ToUniversalTime().ToString('o')
    $content = $lease | ConvertTo-Json -Depth 24
    # LEASE-HEARTBEAT-RACE-1: written only if the lease is still the text read.
    try {
        $written = Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath $rel -Content $content -ExpectedVersion (Get-VmfDocumentVersion -Text $text)
    }
    catch {
        # The store did not answer as it should. The lease as stored says what
        # happened: this renewal (its answer was lost), another job (lost), or
        # nothing - a store error, which the step that called this fails on
        # and tries again, as before.
        $failure = $_
        $now = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
        if ($null -ne $now -and [string]::Equals($now, $content, [System.StringComparison]::Ordinal)) { return }
        if ($null -ne $now -and [string]::Equals($now, $text, [System.StringComparison]::Ordinal)) { throw $failure }
        $who = if ($null -eq $now) { 'nobody' } else { [string]($now | ConvertFrom-Json -Depth 6).workerId }
        throw "Lease for '$VmId' changed while '$WorkerId' renewed it, and is now held by '$who' - abandon this VM."
    }
    if (-not $written) {
        $now = Get-VmfLeaseInfo -RunPath $RunPath -VmId $VmId
        $who = if ($now) { [string]$now.workerId } else { 'nobody' }
        throw "Lease for '$VmId' changed while '$WorkerId' renewed it, and is now held by '$who' - abandon this VM."
    }
}

function Remove-VmfLease {
    <#
    .SYNOPSIS
        Release a lease. Only the owning worker (or -Force, for the watchdog)
        may remove it. Idempotent when already gone.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string]$WorkerId,
        [Parameter()][switch]$Force
    )

    $rel = Get-VmfLeaseRelPath -VmId $VmId
    # LEASE-HEARTBEAT-RACE-1: removed only as read. A lease taken over between
    # the check and the removal belongs to its new holder and stays; -Force
    # reads it again and removes what is there now.
    foreach ($try in 1..3) {
        $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
        if ($null -eq $text) { return }
        if (-not $Force) {
            $lease = $text | ConvertFrom-Json -Depth 6
            if ($lease.workerId -ne $WorkerId) {
                throw "Refusing to remove lease for '$VmId' held by '$($lease.workerId)' (caller: '$WorkerId'). Use -Force only from the watchdog."
            }
        }
        if (Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $text)) { return }
    }
    Write-Warning "The lease for '$VmId' changed each time it was removed, so it stays. It ends by itself when its heartbeat stops."
}

function Remove-VmfExpiredLease {
    <#
    .SYNOPSIS
        Watchdog: remove one lease only as it was judged expired. $true when
        this call removed it.
    .DESCRIPTION
        LEASE-HEARTBEAT-RACE-1. The watchdog listed the expired leases and then
        removed each one with -Force, whatever it held by then. A holder that
        renewed in between lost a live lease, and a new worker could take the
        machine while the old one still worked on it. Now the lease is read,
        judged, and removed only if it still holds the text judged.
    .PARAMETER WaveWorkerOnly
        STALE-WAVE-HOLD-1: remove it only when a wave worker holds it, judged
        in the same read as its age. The hold of a restore is the
        business of that job's restart (RESTORE-END-JOB-1).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][int]$TimeoutSeconds = 120,
        [Parameter()][switch]$WaveWorkerOnly
    )
    $rel = Get-VmfLeaseRelPath -VmId $VmId
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
    if ($null -eq $text) { return $false }
    $lease = $text | ConvertFrom-Json -Depth 6
    if ($WaveWorkerOnly -and (Test-VmfPutBackLeaseHolder -WorkerId ([string]$lease.workerId))) { return $false }
    if (-not (Test-VmfMachineLeaseExpired -Lease $lease -TimeoutSeconds $TimeoutSeconds)) { return $false }
    Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $text)
}

function Get-VmfExpiredLeases {
    <#
    .SYNOPSIS
        Watchdog: list leases whose heartbeat is older than the timeout.
        The orchestrator removes them (-Force) and marks the VM resume-needed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][int]$TimeoutSeconds = 120
    )

    $cutoff = (Get-Date).ToUniversalTime().AddSeconds(-$TimeoutSeconds)
    $expired = foreach ($name in Get-VmfStoreNames -RunPath $RunPath -Folder 'leases' -Extension '.lease') {
        $lease = Read-VmfStoreJson -RunPath $RunPath -RelPath "leases/$name" -Depth 6
        if (-not $lease) { continue }   # released between list and read
        $hb = [datetime]::Parse($lease.heartbeatUtc, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
        if ($hb -lt $cutoff) { $lease }
    }
    @($expired)
}
