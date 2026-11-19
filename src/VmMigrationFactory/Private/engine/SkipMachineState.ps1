# SKIP-PREPARED-WORDS-1: where the stop that parked a machine left it, as
# Leave this machine out says it.

function Get-VmfSkipMachineState {
    <#
    .SYNOPSIS
        SKIP-PREPARED-WORDS-1: 'untouched', 'restored', 'changed', or $null
        (no claim) - where the stop that still describes this machine left
        it. Pure.
    .DESCRIPTION
        Skip-VmfVm returned `Prepared` when the history held GUEST_PREP, and
        the run page said "Its operating system was already prepared". History
        says a step RAN, not what it left: a preparation that changed the guest
        is rolled back before the machine parks (PREP-ROLLBACK-1), so a machine
        that rolled back runs from its first safety copy (the owner, lab walk,
        2026-10-31).

        Every stop records where it left the machine (machineState, FAIL-1).
        The stop read is the one the run page reads (currentStop in
        migrations.html): the newest entry with a reason code, only while no
        later entry moved the machine on to a state that is not a stop, and
        only while no restore (restore.restoredUtc) is as new as it. A data disk swap that is left
        (swapPending) is a changed machine, whatever the stop says - the
        rule Test-VmfRetryHeld uses. Both sides are held to
        tests/fixtures/skip-machine-state.json.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowNull()]$Doc)
    if (-not $Doc) { return $null }
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    if (& $f $Doc 'swapPending') { return 'changed' }
    $stops = @('FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION')
    if ([string](& $f $Doc 'state') -notin $stops) { return $null }
    $history = @(@(& $f $Doc 'history') | Where-Object { $_ })
    $at = -1
    for ($i = $history.Count - 1; $i -ge 0; $i--) { if ([string](& $f $history[$i] 'reasonCode')) { $at = $i; break } }
    if ($at -lt 0) { return $null }
    $later = @($history | Select-Object -Skip ($at + 1))
    if (@($later | Where-Object { [string](& $f $_ 'state') -and [string](& $f $_ 'state') -notin $stops }).Count) { return $null }
    $stop = $history[$at]
    $utc = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime() } elseif ($v) {
            $out = [datetime]::MinValue
            if ([datetime]::TryParse([string]$v, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$out)) { $out } else { 'unreadable' } } else { $null } }
    $mends = @(@((& $f (& $f $Doc 'restore') 'restoredUtc')) | Where-Object { $_ })
    if ($mends.Count) {
        $stoppedAt = & $utc (& $f $stop 'tsUtc')
        if (-not ($stoppedAt -is [datetime])) { return $null }
        foreach ($m in $mends) {
            $t = & $utc $m
            if (-not ($t -is [datetime]) -or $t -ge $stoppedAt) { return $null }
        }
    }
    $recorded = [string](& $f $stop 'machineState')
    # POWER-ONLY-CHANGED-1: a stop changed only in its power state, whose
    # power state the product returned since (a line that says untouched -
    # Get-VmfPowerOwed has nothing owed): the machine is as it was.
    if ($recorded -eq 'changed' -and [string](& $f $stop 'powerNotPutBack') -in @('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running') -and -not (Get-VmfPowerOwed -Doc $Doc)) { return 'untouched' }
    if ($recorded) { return $recorded }
    $null
}

function Test-VmfMachineLeftChanged {
    <#
    .SYNOPSIS
        SKIP-CHANGED-FREED-1: does the record say this machine is left
        CHANGED, with nothing that mended it since? Pure.
    .DESCRIPTION
        The claim is the only thing another migration asks before it takes a
        machine (Get-VmfOtherRunClaimRefusal), and its PRECHECK and first
        safety copy take the machine as it is. So a machine left changed keeps
        its claim in the migration that changed it - Leave this machine out,
        Stop this migration and the settled-claim release all ask this - until
        a restore mends it, as a retry waits (Test-VmfRetryHeld).

        A machine that is not left out: Get-VmfSkipMachineState says
        'changed'. A machine left out (SKIPPED): the same question, asked of
        the record as the machine stood when it was left out - the history
        before its SKIPPED lines, and the state it had then - with every
        restore and data disk swap that is left on the record now.
        Unknown (no stop on record) is not a claim of changed: it is what
        Leave this machine out says nothing about, and it released before.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowNull()]$Doc)
    if (-not $Doc) { return $false }
    if ([string](Get-VmfRecordField -Object $Doc -Name 'state') -ne 'SKIPPED') {
        return ((Get-VmfSkipMachineState -Doc $Doc) -eq 'changed')
    }
    $history = @(@(Get-VmfRecordField -Object $Doc -Name 'history') | Where-Object { $_ })
    $end = $history.Count
    while ($end -gt 0 -and [string](Get-VmfRecordField -Object $history[$end - 1] -Name 'state') -eq 'SKIPPED') { $end-- }
    $before = @(if ($end -gt 0) { $history[0..($end - 1)] })
    $then = if ($before.Count) { [string](Get-VmfRecordField -Object $before[-1] -Name 'state') } else { 'PLANNED' }
    # STOP-MIDMOVE-FREED-1: Stop this migration records on its SKIPPED line
    # where it left a machine part way through its move. That line is then
    # the stop that describes the machine, read with the same mends.
    $said = @($history | Select-Object -Skip $end | Where-Object { [string](Get-VmfRecordField -Object $_ -Name 'machineState') }) | Select-Object -Last 1
    if ($said) {
        $before = @($before) + @([pscustomobject]@{
                tsUtc = Get-VmfRecordField -Object $said -Name 'tsUtc'; state = 'FAILED_NEEDS_ATTENTION'
                reasonCode = 'runStopped'; machineState = [string](Get-VmfRecordField -Object $said -Name 'machineState') })
        $then = 'FAILED_NEEDS_ATTENTION'
    }
    # A copy: the caller's record is never changed.
    $asLeft = [pscustomobject]@{}
    $fields = if ($Doc -is [System.Collections.IDictionary]) { @($Doc.Keys | ForEach-Object { @{ Name = [string]$_; Value = $Doc[$_] } }) }
              else { @($Doc.PSObject.Properties | ForEach-Object { @{ Name = $_.Name; Value = $_.Value } }) }
    foreach ($field in $fields) {
        if ($field.Name -in @('state', 'history')) { continue }
        $asLeft | Add-Member -NotePropertyName $field.Name -NotePropertyValue $field.Value
    }
    $asLeft | Add-Member -NotePropertyName state -NotePropertyValue $then
    $asLeft | Add-Member -NotePropertyName history -NotePropertyValue $before
    (Get-VmfSkipMachineState -Doc $asLeft) -eq 'changed'
}
