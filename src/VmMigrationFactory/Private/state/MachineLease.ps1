# RESTORE-ONE-AT-A-TIME-1: one restore of a machine at a time.
#
# A second click, or two people, started two engine jobs for one machine. Each
# stopped it, made disks from the copy and swapped them in, and one could start
# the machine while the other swapped its disks. The service now refuses the
# second start (Invoke-VmfFacadeStartEngine), but two starts can pass it
# together - so the engine holds the machine itself, with the lease a wave
# worker takes (Leases.ps1): the same file, under the run, created by the
# store's exclusive create. One holder wins; a wave worker and a restore fence
# each other through it too.
#
# The holder is 'restore:<operation id>' - the id the engine puts on
# the start line and on its own fail line (RESTORE-END-LOST-1).
#
#   Every exit releases it (Exit-VmfMachineLease, in the caller's finally).
#   A restore that dies stops its heartbeat, and its hold ends by
#     itself after $script:VmfMachineLeaseTimeoutSeconds - the limit the wave
#     watchdog uses, so the two never disagree about who is alive. The next
#     restore takes it over in one step: only the text it judged
#     expired is removed.
#   A WAVE WORKER'S hold is never taken over, expired or not (RESTORE-MID-MOVE-1,
#     decision of 2026-10-19: a retry must work, and nothing may assume that
#     a worker died). The wave's own resume and rollback own a machine it started; the
#     wave watchdog removes a dead worker's hold and resumes the machine, and
#     Stop this migration removes it and closes the machine out.
#   A RESUME of the same restore names the same operation id, and takes its own
#     hold over at once: a stopped restore that is started again is not locked
#     out by the hold it left. RESTORE-END-JOB-1: the service's timer resumes
#     a restore whose job stopped (its checkpoint, putBackJob, is
#     on the machine's record), and passes its operation id.
#
# The heartbeat is the hook every Azure call already renews a wave worker's
# lease through ($script:VmfOpHeartbeat, in Invoke-VmfAzOperation). Unlike a
# worker's, it NEVER throws: once the machine is stopped, the restore finishes
# its change window - a lost hold must never leave a machine stopped (a wave
# worker can stop mid-state because the next holder resumes it; a restore is
# resumed only when its job has stopped, RESTORE-END-JOB-1). The fence is
# asked instead, by name, at the last point where nothing has changed
# (Assert-VmfMachineLeaseHeld).

# The wave watchdog's limit: Start-VmfWave and Stop-VmfRun -LeaseTimeoutSeconds.
$script:VmfMachineLeaseTimeoutSeconds = 900
# As the wave worker's heartbeat (Invoke-VmfStateMachine): small calls in a row
# do not each write the store.
$script:VmfMachineLeaseRenewSeconds = 25
# The hold this process has now. The engine runs ONE operation per container,
# so one is enough - the same reason Use-VmfSubscriptionContext may be
# process-wide.
$script:VmfMachineLeaseToken = $null

function Get-VmfMachineLeaseHolder {
    <#
    .SYNOPSIS
        The holder name a restore takes a machine under:
        '<kind>:<operation id>', or a new id when the caller has none.
        OLD-REBUILD-RESTORE-READERS-1: the only kind is restore.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('restore')][string]$Kind,
        [Parameter()][AllowEmptyString()][string]$CorrelationId
    )
    $id = if ($CorrelationId) { $CorrelationId } else { [guid]::NewGuid().ToString() }
    "${Kind}:$id"
}

function Test-VmfPutBackLeaseHolder {
    <#
    .SYNOPSIS
        Is this lease held by a restore, not by a wave worker?
        Every reader of leases/ that means "a wave is working" asks this.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$WorkerId)
    [bool]($WorkerId -match '^restore:')
}

function Get-VmfLeaseHolderWords {
    <#
    .SYNOPSIS
        "held by a worker" or "held by a restore" - for a
        refusal that names what holds a machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Lease)
    $holder = if ($Lease) { [string]$Lease.workerId } else { '' }
    if ($holder -like 'restore:*') { 'held by a restore' }
    else { 'held by a worker' }
}

function Get-VmfReapedLeaseWords {
    <#
    .SYNOPSIS
        What the wave watchdog says when it removes an expired lease. A wave
        worker's machine is resumed by the wave; a restore is
        resumed by the service's timer (RESTORE-END-JOB-1), never by the wave.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Lease)
    $holder = [string]$Lease.workerId
    if (Test-VmfPutBackLeaseHolder -WorkerId $holder) {
        $kind = ($holder -split ':')[0]
        return "Removed the expired hold of the $kind '$holder'. That job stopped, and the wave does not resume it. The service starts the $kind again by itself, from the last step it saved."
    }
    "reaped expired lease of $holder - VM will be resumed"
}

function Test-VmfMachineLeaseExpired {
    <#
    .SYNOPSIS
        Is this lease's heartbeat older than the limit? A heartbeat that cannot
        be read is NOT expired: unknown never frees a machine for a second job.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Lease,
        [Parameter()][int]$TimeoutSeconds = $script:VmfMachineLeaseTimeoutSeconds
    )
    $hb = $Lease.heartbeatUtc
    # ConvertFrom-Json turns the time into a date value; a store read may not.
    $when = if ($hb -is [datetime]) { $hb.ToUniversalTime() }
            else {
                $parsed = [datetime]::MinValue
                $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
                if (-not [datetime]::TryParse([string]$hb, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) { return $false }
                $parsed
            }
    $when -lt (Get-Date).ToUniversalTime().AddSeconds(-$TimeoutSeconds)
}

function Get-VmfMachineHold {
    <#
    .SYNOPSIS
        WAVE-RUNNING-LEASE-1: does this machine keep its wave running, and
        why? 'none', 'working' or 'endedHold'. Pure.
    .DESCRIPTION
        ONE rule, twinned in the pages (VmfHelp.machineHold, help.js) and held
        to tests/fixtures/machine-hold.json in both languages:
          working    a lease is held - a wave worker, a restore -
                     or the stored state is not final. PLANNED counts: a
                     worker writes it when it TAKES the machine (WAVE-MIX-2).
          endedHold  a WAVE WORKER's lease older than the limit, on a machine
                     whose stored state is final: the worker stopped after the
                     move ended. The service's timer removes that hold at its
                     next check (STALE-WAVE-HOLD-1, Get-VmfEndedWaveHolds asks
                     this rule), or the wave's watchdog if the wave runs.
          none       no lease, and no state document or a final one.
        Both 'working' and 'endedHold' keep the wave running: the engine
        refuses an edit and a release of it (Get-VmfWaveRunningDetail). A
        heartbeat that cannot be read is not old (Test-VmfMachineLeaseExpired),
        and the hold of a restore is that job's own, whatever its
        age (RESTORE-END-JOB-1 starts it again).
    .PARAMETER State
        The state DOCUMENT's state, or '' when the machine has none.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$State,
        [Parameter()][AllowNull()]$Lease,
        [Parameter()][int]$TimeoutSeconds = $script:VmfMachineLeaseTimeoutSeconds
    )
    $final = [bool]$State -and $State -in $script:VmfTerminalStates
    if ($Lease) {
        if ($final -and -not (Test-VmfPutBackLeaseHolder -WorkerId ([string]$Lease.workerId)) -and
            (Test-VmfMachineLeaseExpired -Lease $Lease -TimeoutSeconds $TimeoutSeconds)) { return 'endedHold' }
        return 'working'
    }
    if ($State -and -not $final) { return 'working' }
    'none'
}

function Test-VmfMachineHeldNow {
    <#
    .SYNOPSIS
        MADE-DISK-RECORD-1: does a live hold stand on this machine now - a
        restore or a wave worker? A hold older than the limit is a
        job that died, and is not. A hold that cannot be read counts as held:
        unknown never frees a machine's disks for a delete.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    try { $lease = Get-VmfLeaseInfo -RunPath $RunPath -VmId $VmId }
    catch { return $true }
    [bool]($lease -and -not (Test-VmfMachineLeaseExpired -Lease $lease))
}

function Format-VmfMachineLeaseRefusal {
    <#
    .SYNOPSIS
        The sentence that says who holds the machine. One copy: the engine
        refuses with it, and the service refuses with it before a job starts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Lease,
        [Parameter(Mandatory)][string]$VmName
    )
    $holder = [string]$Lease.workerId
    if (-not (Test-VmfPutBackLeaseHolder -WorkerId $holder)) {
        # RESTORE-MID-MOVE-1: a wave worker's hold does not end by itself for
        # a restore - the wave resumes the machine, or Stop this migration
        # removes the hold.
        return "A wave migrates '$VmName' now. Wait until the wave ends, then try again. To get the machine back now, use Stop this migration, then restore the machine."
    }
    "A restore of '$VmName' runs now. Wait until it ends, then try again. If that job stopped, try again after $([int]($script:VmfMachineLeaseTimeoutSeconds / 60)) minutes."
}

function Get-VmfMachineLeaseRefusal {
    <#
    .SYNOPSIS
        The service's question before it starts a restore: does a
        live hold stand on this machine? The refusal sentence, or $null.
    .DESCRIPTION
        A restore's hold older than the limit is a job that
        died, and is not a refusal - the engine takes it over. A wave worker's
        hold is a refusal, expired or not (RESTORE-MID-MOVE-1). The engine
        asks again in any case.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    # VMID-CASE-1: the lease is named from the ID as the record spells it.
    $recorded = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    # RESTORE-CROSS-RUN-1: another live migration that holds the machine's
    # claim refuses it too - a lease fences only the jobs of this migration.
    $claimRefusal = Get-VmfOtherRunClaimRefusal -RunPath $RunPath -VmId $recorded
    if ($claimRefusal) { return $claimRefusal }
    $lease = Get-VmfLeaseInfo -RunPath $RunPath -VmId $recorded
    if (-not $lease) { return $null }
    if ((Test-VmfPutBackLeaseHolder -WorkerId ([string]$lease.workerId)) -and (Test-VmfMachineLeaseExpired -Lease $lease)) { return $null }
    Format-VmfMachineLeaseRefusal -Lease $lease -VmName ($recorded -split '/')[-1]
}

function Enter-VmfMachineLease {
    <#
    .SYNOPSIS
        Take the machine for a restore, or throw the sentence that
        says who has it. Sets the heartbeat every Azure call renews it through.
    .OUTPUTS
        The token Exit-VmfMachineLease takes: RunPath, VmId, Holder,
        PreviousHook, Last, Warned.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Holder,
        [Parameter()][int]$TimeoutSeconds = $script:VmfMachineLeaseTimeoutSeconds
    )
    # RESTORE-CROSS-RUN-1: a lease fences the jobs of ONE migration; the claim
    # fences migrations. While another live migration holds the machine, this
    # job is refused before it takes the lease, so nothing is left to release.
    $claimRefusal = Get-VmfOtherRunClaimRefusal -RunPath $RunPath -VmId $VmId
    if ($claimRefusal) { throw $claimRefusal }
    $rel = Get-VmfLeaseRelPath -VmId $VmId
    $vmName = ($VmId -split '/')[-1]
    $taken = $false
    $held = $null
    # Three tries: a hold released, or an expired one removed, between the
    # create and the read is tried again; nothing else loops.
    foreach ($try in 1..3) {
        if (New-VmfLease -RunPath $RunPath -VmId $VmId -WorkerId $Holder) { $taken = $true; break }
        $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
        if ($null -eq $text) { continue }
        $held = $text | ConvertFrom-Json -Depth 6
        # Ordinal: the operation id is the engine's own, and a looser match
        # could only let a second job in.
        if ([string]::Equals([string]$held.workerId, $Holder, [System.StringComparison]::Ordinal)) {
            # The SAME restore, started again: its own hold, renewed.
            # LEASE-HEARTBEAT-RACE-1: a renewal that loses to a takeover in
            # between is tried again, so the refusal names the new holder.
            try { Update-VmfLeaseHeartbeat -RunPath $RunPath -VmId $VmId -WorkerId $Holder }
            catch {
                if ([string]$_.Exception.Message -match 'abandon this VM') { $held = $null; continue }
                throw
            }
            $taken = $true
            break
        }
        # RESTORE-MID-MOVE-1: only the hold of a restore is taken
        # over. A wave worker's is refused below, expired or not.
        if ((Test-VmfPutBackLeaseHolder -WorkerId ([string]$held.workerId)) -and (Test-VmfMachineLeaseExpired -Lease $held -TimeoutSeconds $TimeoutSeconds)) {
            # A job that died. Removed only as it was judged: a heartbeat that
            # lands between the read and the removal keeps it, and two jobs
            # that both judged it expired cannot both remove a fresh hold.
            Write-Warning "The hold of '$($held.workerId)' on '$vmName' is older than $TimeoutSeconds seconds, so its job stopped. This job takes the machine."
            $null = Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $text)
            continue
        }
        throw (Format-VmfMachineLeaseRefusal -Lease $held -VmName $vmName)
    }
    if (-not $taken) {
        if ($held) { throw (Format-VmfMachineLeaseRefusal -Lease $held -VmName $vmName) }
        throw "Another job takes '$vmName' now. Wait until it ends, then try again."
    }
    $token = [pscustomobject]@{
        RunPath      = $RunPath
        VmId         = $VmId
        Holder       = $Holder
        PreviousHook = $script:VmfOpHeartbeat
        Last         = Get-Date
        Warned       = $false
    }
    $script:VmfMachineLeaseToken = $token
    # A scriptblock written here runs in this module, so the hook can call
    # the private function below from Invoke-VmfAzOperation.
    $script:VmfOpHeartbeat = { Invoke-VmfMachineLeaseHeartbeat }
    $token
}

function Invoke-VmfMachineLeaseHeartbeat {
    <#
    .SYNOPSIS
        Renew this process's hold. Never throws (see the head of this file):
        a hold another job has is left alone and said once as a warning; a
        hold somebody removed is taken back.
    #>
    [CmdletBinding()]
    param()
    $t = $script:VmfMachineLeaseToken
    if (-not $t) { return }
    if (((Get-Date) - $t.Last).TotalSeconds -lt $script:VmfMachineLeaseRenewSeconds) { return }
    $t.Last = Get-Date
    try {
        $held = Get-VmfLeaseInfo -RunPath $t.RunPath -VmId $t.VmId
        if ($held -and [string]::Equals([string]$held.workerId, $t.Holder, [System.StringComparison]::Ordinal)) {
            Update-VmfLeaseHeartbeat -RunPath $t.RunPath -VmId $t.VmId -WorkerId $t.Holder
            return
        }
        if (-not $held -and (New-VmfLease -RunPath $t.RunPath -VmId $t.VmId -WorkerId $t.Holder)) { return }
        $who = if ($held) { [string]$held.workerId } else { 'another job' }
        if (-not $t.Warned) {
            $t.Warned = $true
            Write-Warning "The hold on '$(($t.VmId -split '/')[-1])' is now '$who', not '$($t.Holder)'. This job finishes what it started, so the machine is not left part done."
        }
    }
    catch {
        if (-not $t.Warned) {
            $t.Warned = $true
            Write-Warning "The hold on '$(($t.VmId -split '/')[-1])' could not be renewed: $($_.Exception.Message)"
        }
    }
}

function Assert-VmfMachineLeaseHeld {
    <#
    .SYNOPSIS
        The fence, at the last point where nothing has changed: this job still
        holds the machine, or it throws the sentence that says who does.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Token)
    if (-not $Token) { return }
    $vmName = ($Token.VmId -split '/')[-1]
    # RESTORE-CROSS-RUN-1: asked again here, as the lease is - a newer
    # migration may have claimed the machine since the job started.
    $claimRefusal = Get-VmfOtherRunClaimRefusal -RunPath $Token.RunPath -VmId $Token.VmId
    if ($claimRefusal) { throw $claimRefusal }
    $held = Get-VmfLeaseInfo -RunPath $Token.RunPath -VmId $Token.VmId
    if ($held -and [string]::Equals([string]$held.workerId, $Token.Holder, [System.StringComparison]::Ordinal)) { return }
    if (-not $held -and (New-VmfLease -RunPath $Token.RunPath -VmId $Token.VmId -WorkerId $Token.Holder)) { return }
    if (-not $held) { $held = Get-VmfLeaseInfo -RunPath $Token.RunPath -VmId $Token.VmId }
    if ($held) { throw (Format-VmfMachineLeaseRefusal -Lease $held -VmName $vmName) }
    throw "Another job takes '$vmName' now. Wait until it ends, then try again."
}

function Exit-VmfMachineLease {
    <#
    .SYNOPSIS
        Release this job's hold and put the earlier heartbeat hook back. Only
        its own hold is removed; a release never throws, because it runs in a
        finally and must not replace the reason the job ended.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Token)
    if (-not $Token) { return }
    try {
        $held = Get-VmfLeaseInfo -RunPath $Token.RunPath -VmId $Token.VmId
        if ($held -and [string]::Equals([string]$held.workerId, $Token.Holder, [System.StringComparison]::Ordinal)) {
            Remove-VmfLease -RunPath $Token.RunPath -VmId $Token.VmId -WorkerId $Token.Holder
        }
        elseif ($held) {
            Write-Warning "The hold on '$(($Token.VmId -split '/')[-1])' is '$($held.workerId)' now, so this job left it in place."
        }
    }
    catch {
        Write-Warning "The hold on '$(($Token.VmId -split '/')[-1])' could not be released: $($_.Exception.Message). It ends by itself after $($script:VmfMachineLeaseTimeoutSeconds) seconds."
    }
    finally {
        if ($script:VmfMachineLeaseToken -eq $Token) { $script:VmfMachineLeaseToken = $null }
        $script:VmfOpHeartbeat = $Token.PreviousHook
    }
}
