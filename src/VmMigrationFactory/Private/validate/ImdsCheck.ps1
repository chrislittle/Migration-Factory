# VERIFY-FP-1: a platform check the move cannot fake - the Instance Metadata
# Service, asked from inside the guest before and after the move.
#
# Microsoft (instance-metadata-service): requests "must be sent using the VM's
# primary NIC and primary IP, and DHCP must be enabled". One answer therefore
# proves the part of the network a move rebuilds, and it says which size the
# machine is on. It does NOT prove the path across the virtual network: the
# request "never leaves the host". The accelerated networking check stays.
#
# Every validation failure rolls the machine back (FAIL-1), so this must not
# be flaky: the guest script retries, a script that could not run is
# 'unknown' and never fails a move, and a machine that never reached IMDS
# before the move (a static address inside the guest) is never failed for not
# reaching it after.

function Get-VmfImdsReading {
    <#
    .SYNOPSIS
        Run the IMDS guest script and return what it read: Reached is 'yes',
        'no' or 'unknown' (the script could not run or said nothing).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)]$Context)
    $script = if ($Context.Plan.assessment.os -eq 'Windows') { 'Test-Imds.ps1' } else { 'imds-check.sh' }
    $reading = [ordered]@{ reached = 'unknown'; vmSize = ''; securityType = ''; secureBoot = ''; vtpm = ''; readUtc = (Get-Date).ToUniversalTime().ToString('o') }
    try {
        $out = Invoke-VmfGuestScriptOnVm -ScriptName $script -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        if ($out -and [string]$out.result -ne 'BLOCKED') {
            $f = ConvertTo-VmfGuestFacts -GuestOutput $out
            if ($f.PSObject.Properties['imdsReached'] -and [string]$f.imdsReached -in @('yes', 'no')) { $reading.reached = [string]$f.imdsReached }
            foreach ($pair in @(@('vmSize', 'imdsVmSize'), @('securityType', 'imdsSecurityType'), @('secureBoot', 'imdsSecureBoot'), @('vtpm', 'imdsVtpm'))) {
                if ($f.PSObject.Properties[$pair[1]]) { $reading[$pair[0]] = [string]$f.($pair[1]) }
            }
        }
    }
    catch {
        # A lost lease is the fence that stops a reaped worker: it must reach
        # the state machine, never be read as "IMDS unknown".
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $reading.reached = 'unknown'
    }
    [pscustomobject]$reading
}

function Select-VmfImdsBefore {
    <#
    .SYNOPSIS
        IMDS-KEEP-2: which reading before the move GUEST_PREP keeps when it
        asks again - a retry of the step, a resume after a worker stopped, or
        a re-prepare sent back from STOPPED. Pure. Returns
        @{ Reading; KeptEarlier; Why }.
    .DESCRIPTION
        The baseline VALIDATING compares against is the FIRST reading of the
        attempt, taken on the untouched machine - read once, like guestBefore.
        The case (2026-10-09): the network works before the move, the preparation
        breaks it, the retried step reads "no"; when that "no" replaced the
        "yes" (IMDS-KEEP-1's rule), the check after the move compared "no"
        with "no" and passed a machine the product broke.

        "Untouched" is the audit trail's answer, never a new marker:
        GuestChanged is Test-VmfGuestChangedThisAttempt, true when a script
        that changes the guest ran in this attempt - FIXED, or STARTED and
        never answered (it may have changed it).

        Why:
          first            no reading on record, the guest untouched: this one.
          kept             a known reading ('yes' or 'no') on record: it stays,
                           whatever this one says and whatever changed since.
          replacedUnknown  an unknown on record and the guest still untouched:
                           this one, which is still a reading of the machine
                           as it was.
          changed          no known reading on record and the guest changed:
                           this one cannot show the machine as it was, so the
                           baseline stays unknown - the earlier unknown, or a
                           new unknown reading when none is on record.
        The caller keeps this inside one attempt: a person's retry from the
        first step drops the reading (Clear-VmfRetryState), as it does the
        guest reading beside it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Earlier,
        [Parameter()][AllowNull()]$Latest,
        [Parameter(Mandatory)][bool]$GuestChanged
    )
    $known = { param($r) $r -and $r.PSObject.Properties['reached'] -and [string]$r.reached -in @('yes', 'no') }
    if (& $known $Earlier) { return @{ Reading = $Earlier; KeptEarlier = $true; Why = 'kept' } }
    if ($GuestChanged) {
        if ($Earlier) { return @{ Reading = $Earlier; KeptEarlier = $true; Why = 'changed' } }
        # A new object, never the new reading relabelled: its size and
        # security facts are from after the change too.
        $readUtc = if ($Latest -and $Latest.PSObject.Properties['readUtc']) { [string]$Latest.readUtc } else { (Get-Date).ToUniversalTime().ToString('o') }
        return @{ Reading = [pscustomobject]@{ reached = 'unknown'; vmSize = ''; securityType = ''; secureBoot = ''; vtpm = ''; readUtc = $readUtc }
            KeptEarlier = $false; Why = 'changed' }
    }
    @{ Reading = $Latest; KeptEarlier = $false; Why = $(if ($Earlier) { 'replacedUnknown' } else { 'first' }) }
}
function Test-VmfImdsOutcome {
    <#
    .SYNOPSIS
        Judge the reading after the move against the one before it and the
        plan's target size. Pure. Returns @{ Ok; Detail }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After,
        [Parameter()][string]$TargetSize
    )
    $b = if ($Before -and $Before.PSObject.Properties['reached']) { [string]$Before.reached } else { 'unknown' }
    $a = if ($After -and $After.PSObject.Properties['reached']) { [string]$After.reached } else { 'unknown' }

    if ($b -eq 'yes' -and $a -eq 'no') {
        return @{ Ok = $false; Detail = 'The Instance Metadata Service answered before the move and does not answer now. It answers only on the primary network interface, so that interface does not work as it did before the move.' }
    }
    if ($a -eq 'yes' -and $TargetSize -and $After.vmSize -and [string]$After.vmSize -ne $TargetSize) {
        return @{ Ok = $false; Detail = "The machine reports the size $($After.vmSize), and the plan's target is $TargetSize." }
    }
    $detail = switch ($a) {
        'yes' { "The Instance Metadata Service answered on the primary network interface: size $($After.vmSize)." }
        'no' { 'The Instance Metadata Service does not answer. Nothing shows that it answered before the move, so this does not stop the move.' }
        default { 'The product could not ask the Instance Metadata Service, so this check has no answer.' }
    }
    @{ Ok = $true; Detail = $detail }
}
