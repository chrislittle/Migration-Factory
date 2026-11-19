# ODCR-STATUS-1: a quota record stuck at RESERVING is read from Azure by the
# resource ID the engine recorded before it asked.
#
# MEASURED on the lab install, 2026-11-09: the reservation drill stopped the
# engine 4 seconds after it asked Azure for a capacity reservation, and Azure
# made it anyway - Succeeded, real, and billing. The page knew only the clock:
# "Reserving..." for 60 minutes, then "Not confirmed". Nothing asked Azure,
# though the claim held the reservation's resource ID (reservationAsked).
#
# The five-minute pass of the web service now asks, when no reserve or release
# job of the run runs (Invoke-VmfFacadeReadReservingClaims), and records what
# the engine would have recorded had it lived:
#   Succeeded            RESERVED, by the recorded IDs - Azure holds it, it
#                        bills, and the wave can use it;
#   Failed or Canceled   BLOCKED, reservation-failed - the engine's own rule
#                        for that answer (Wait-VmfReservationProvisioned);
#   not found            RELEASED - nothing bills - once the ask is older than
#                        $script:VmfReservingGoneMarginMinutes; before that,
#                        nothing is written;
#   still being made     not confirmed (reservationUnconfirmedUtc), which the
#                        page offers Release for, written ONCE; the next pass
#                        reads it again.
# Every write quotes the version the pass read (Write-VmfClaimIfVersion), so a
# Release saved in between is never written over. The 60-minute clock stays
# only for a claim the service cannot read from Azure (a role that does not
# reach its resource group): unknown is never "nothing bills".

# How long after the ask a "not found" answer is read as gone. A CHOSEN
# margin, not a measured Azure limit: no Microsoft page states how late an
# accepted create can appear. It is the engine's own wait for a create
# (Wait-VmfReservationProvisioned, 600 seconds), against a create measured at
# about 34 seconds (ODCR-VERIFY-1). Before it, a not-found record is left as
# it is: the page offers Release after 60 minutes in any case.
$script:VmfReservingGoneMarginMinutes = 10

function Get-VmfReservingReadOutcome {
    <#
    .SYNOPSIS
        ODCR-STATUS-1: what Azure's answer for a RESERVING claim means. Pure.
        'held', 'failed', 'gone' or 'making'.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][bool]$Found,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ProvisioningState
    )
    if (-not $Found) { return 'gone' }
    if ($ProvisioningState -eq 'Succeeded') { return 'held' }
    if ($ProvisioningState -in @('Failed', 'Canceled')) { return 'failed' }
    'making'
}

function Get-VmfReservingClaims {
    <#
    .SYNOPSIS
        ODCR-STATUS-1: the quota records of a run at RESERVING, each with the
        version it was read at (PLANVER-2), for a later version-checked save.
    .DESCRIPTION
        One list of the capacity folder and the records read together
        (Read-VmfStoreTextMany), because the five-minute pass asks it of every
        run it checks. A store that does not answer throws.
    .OUTPUTS
        Name, Handle, Version, Claim - the shape of Read-VmfClaimVersioned.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    $names = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json')
    if (-not $names.Count) { return }
    $texts = Read-VmfStoreTextMany -Items @($names | ForEach-Object { [pscustomobject]@{ RunPath = $RunPath; RelPath = "capacity/$_" } })
    for ($i = 0; $i -lt $names.Count; $i++) {
        $text = $texts[$i]
        if ($null -eq $text) { continue }
        $claim = $null
        try { $claim = $text | ConvertFrom-Json -Depth 12 } catch { continue }
        if (-not $claim -or [string]$claim.state -ne 'RESERVING') { continue }
        [pscustomobject]@{
            Name = $names[$i]; Handle = "$RunPath/capacity/$($names[$i])"
            Version = (Get-VmfDocumentVersion -Text $text); Claim = $claim
        }
    }
}

function Update-VmfReservingClaimFromAzure {
    <#
    .SYNOPSIS
        ODCR-STATUS-1: read one RESERVING claim's capacity reservation from
        Azure by its recorded resource ID, and record the answer.
    .DESCRIPTION
        The caller makes sure no reserve or release job of the run runs: the
        engine that asked is the only other writer of a RESERVING claim, and it
        would release what Azure made if this wrote first.
        The save quotes the version in -Read. A claim changed since then is
        left as it is ('changed'). A read Azure does not give throws and
        changes nothing. A recorded ID in another subscription than the claim
        is refused, as Remove-VmfCapacityReservations refuses it, and so is a
        claim that recorded no ID (OLD-VERSION-READERS-REMOVE-5): it throws,
        and nothing is read or written.
    .PARAMETER Read
        One item of Get-VmfReservingClaims.
    .OUTPUTS
        Name, Outcome ('held', 'failed', 'gone', 'making', 'unchanged',
        'changed'), Size, Region, ProvisioningState.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Read,
        [Parameter()][datetime]$NowUtc = [datetime]::UtcNow
    )
    $claim = $Read.Claim
    $said = { param([string]$o, $s) [pscustomobject]@{ Name = [string]$Read.Name; Outcome = $o; Size = [string]$claim.size; Region = [string]$claim.region; ProvisioningState = $s } }
    if ([string]$claim.state -ne 'RESERVING') { return (& $said 'unchanged' $null) }

    $names = Get-VmfReservationNames -Claim $claim
    if ($claim.subscriptionId -and $names.SubscriptionId -ne [string]$claim.subscriptionId) {
        throw ("The on-demand capacity reservation $($names.ReservationId) is not in the subscription of its claim ($($claim.subscriptionId)), " +
               'so it was not read.')
    }
    $answer = Get-VmfCapacityReservationByArm -ReservationId $names.ReservationId
    $state = if ($answer.ProvisioningState) { [string]$answer.ProvisioningState } else { $null }
    $outcome = Get-VmfReservingReadOutcome -Found ([bool]$answer.Found) -ProvisioningState $state
    # Review: an engine stopped while its create was on the way to Azure can
    # leave a PUT that lands after this read (the lab drill: Azure made one 4
    # seconds after the engine stopped). So not found means gone only once the
    # ask is older than the margin; before that, or with no time recorded,
    # nothing is written and the next pass reads it again.
    if ($outcome -eq 'gone') {
        $askedAt = $null
        $asked = if ($claim.PSObject.Properties['reservationAsked']) { $claim.reservationAsked } else { $null }
        $raw = if ($asked -and $asked.PSObject.Properties['askedUtc'] -and $asked.askedUtc) { $asked.askedUtc }
               elseif ($claim.PSObject.Properties['reservingSinceUtc'] -and $claim.reservingSinceUtc) { $claim.reservingSinceUtc } else { $null }
        if ($raw -is [datetime]) { $askedAt = $raw.ToUniversalTime() }
        elseif ($raw) {
            $parsed = [datetime]::MinValue
            if ([datetime]::TryParse([string]$raw, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { $askedAt = $parsed.ToUniversalTime() }
        }
        if ($null -eq $askedAt -or ($NowUtc.ToUniversalTime() - $askedAt).TotalMinutes -lt $script:VmfReservingGoneMarginMinutes) {
            return (& $said 'unchanged' $state)
        }
    }
    $now = $NowUtc.ToUniversalTime().ToString('o')
    $size = [string]$claim.size
    $region = [string]$claim.region
    $stateWord = if ($state) { $state } else { 'not given' }
    $dropUnconfirmed = { if ($claim.PSObject.Properties['reservationUnconfirmedUtc']) { $claim.PSObject.Properties.Remove('reservationUnconfirmedUtc') } }

    switch ($outcome) {
        'making' {
            # Written once: a write each pass would refuse a Release that read
            # the claim before it.
            if ($claim.PSObject.Properties['reservationUnconfirmedUtc'] -and $claim.reservationUnconfirmedUtc) { return (& $said 'unchanged' $state) }
            $claim | Add-Member -NotePropertyName reservationUnconfirmedUtc -NotePropertyValue $now -Force
            $claim | Add-Member -NotePropertyName notes -NotePropertyValue (
                @(@($claim.notes) | Where-Object { $_ }) + @("Azure did not confirm the on-demand capacity reservation. Azure reported provisioningState $stateWord after the engine stopped.")) -Force
            $line = @{ Outcome = 'warn'
                Detail = ("Azure is still making the on-demand capacity reservation for $size in $region`: provisioningState is $stateWord. " +
                          'The engine stopped, so the on-demand capacity reservation is not confirmed, and it can bill. ' +
                          'Select Release beside it, or wait. The service reads it again in 5 minutes.') }
        }
        'held' {
            $claim.state = 'RESERVED'
            $claim | Add-Member -NotePropertyName reservation -NotePropertyValue ([ordered]@{
                groupId = $names.GroupId; reservationId = $names.ReservationId
                createdUtc = $(if ($answer.TimeCreated) { [string]$answer.TimeCreated } else { $null })
                releasedUtc = $null; consumedInstances = 0
            }) -Force
            & $dropUnconfirmed
            $line = @{ Outcome = 'ok'
                Detail = ("Azure holds the on-demand capacity reservation for $size in $region, and it bills. " +
                          'The engine stopped before it recorded this, so the service recorded it. ' +
                          'The wave can use it. Select Release on the wave if the wave does not need it.') }
        }
        'failed' {
            $claim.state = 'BLOCKED'
            $claim | Add-Member -NotePropertyName blockReason -NotePropertyValue 'reservation-failed' -Force
            $claim | Add-Member -NotePropertyName notes -NotePropertyValue (
                @(@($claim.notes) | Where-Object { $_ }) + @("Azure did not make the on-demand capacity reservation. Its provisioningState is $stateWord, and Azure holds no capacity.")) -Force
            & $dropUnconfirmed
            $line = @{ Outcome = 'fail'
                Detail = ("Azure did not make the on-demand capacity reservation for $size in $region`: provisioningState is $stateWord. " +
                          'The engine stopped before it recorded this, so the service recorded it. Nothing is held.') }
        }
        'gone' {
            $claim.state = 'RELEASED'
            $claim | Add-Member -NotePropertyName reservation -NotePropertyValue ([ordered]@{
                groupId = $names.GroupId; reservationId = $names.ReservationId
                createdUtc = $null; releasedUtc = $now; consumedInstances = 0
            }) -Force
            & $dropUnconfirmed
            $line = @{ Outcome = 'info'
                Detail = ("Azure has no on-demand capacity reservation for $size in $region, so nothing bills for it. " +
                          'The engine stopped before it recorded an answer. To reserve again, check the quota on the wave, then reserve.') }
        }
    }
    $claim.schemaVersion = $script:VmfCapacityClaimSchemaVersion
    try { Write-VmfClaimIfVersion -Handle $Read.Handle -Claim $claim -ExpectedVersion $Read.Version | Out-Null }
    catch {
        if ([string]$_.Exception.Message -notlike '409*') { throw }
        return (& $said 'changed' $state)
    }
    Write-VmfStepLine -RunPath $RunPath -Step 'odcr' -Outcome $line.Outcome -Detail $line.Detail -Data @{ wave = [string]$claim.wave }
    & $said $outcome $state
}
