# RETRY-1: every stop carries a CODE, and every code carries guidance.
#
# The right question: realistically, what could a customer fix before they
# select Retry? Counted from the stop sites, the answer is that
# most stops happen BEFORE the machine is touched - missing permissions, a
# target size too small for the machine's interfaces, a kernel below the driver
# floor, data on the temporary disk, no capacity in the region. Those are
# free to retry and genuinely fixable. The frightening class - failed after
# conversion - is the SHORT list, and retrying it rarely helps.
#
# A button cannot express that difference from free text. So the state doc
# records a code, `data/stop-reasons.json` says what the code means and what
# to do about it, and StopReasons.Tests.ps1 fails the build if either side
# gains an entry the other does not have. That is the same derive-both-sides
# guard that caught the stale guest sample and the invented capture field.

function Get-VmfStopReasons {
    <#
    .SYNOPSIS
        The stop-reason table (data/stop-reasons.json), cached per session.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][string]$Path)

    if (-not $script:VmfStopReasons -or $Path) {
        $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'stop-reasons.json' }
        $script:VmfStopReasons = Get-Content $file -Raw -Encoding utf8 | ConvertFrom-Json
    }
    $script:VmfStopReasons
}

function Get-VmfStopGuidance {
    <#
    .SYNOPSIS
        Look up one stop reason. Returns $null for an unknown code.
    .DESCRIPTION
        Unknown must stay unknown (the DRIVER-1 rule): a code with no entry
        returns nothing rather than a made-up reassurance, and the caller
        shows the raw detail instead.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()][string]$Code)

    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    @((Get-VmfStopReasons).reasons) | Where-Object { $_.code -eq $Code } | Select-Object -First 1
}

function Get-VmfStopNextStep {
    <#
    .SYNOPSIS
        LAB-UX-1: what a person does next for a stop - the reason's whatToDo,
        then the line for its retry kind.
    .DESCRIPTION
        The line comes from stop-reasons.json (retryLines), the table the
        Migrations page reads too, so the page and the migration record say the
        same words. A whatToDo does not say to try again itself: the panel said
        it twice when it did. Returns $null when the reason says nothing to do.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Guidance)

    if (-not $Guidance -or -not $Guidance.PSObject.Properties['whatToDo'] -or -not [string]$Guidance.whatToDo) { return $null }
    $lines = (Get-VmfStopReasons).retryLines
    $kind = if ($Guidance.PSObject.Properties['retry']) { [string]$Guidance.retry } else { '' }
    $line = if ($kind -and $lines -and $lines.PSObject.Properties[$kind]) { [string]$lines.$kind } else { '' }
    (@([string]$Guidance.whatToDo, $line) | Where-Object { $_ }) -join ' '
}
function Get-VmfErrorStopReason {
    <#
    .SYNOPSIS
        Classify an exhausted step's error message into a stop reason code.
    .DESCRIPTION
        Only for the generic failure path, where the engine has an ARM error
        and no better information. Capacity is worth naming precisely: it is
        the single most likely reason an operator presses retry, and it is
        deliberately NOT in the transient-retry list in AzureOps (capacity
        comes back in hours, not in seconds of exponential backoff), so it
        reaches a person as a plain step failure unless classified here.

        Anything unrecognised stays `stepFailedRepeatedly` - a wrong code is
        worse than a general one, because it sends someone to fix the wrong
        thing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return 'stepFailedRepeatedly' }

    # STOP-TEXT-SPECIFIC-1: one code for each cause, so each stop says only
    # what happened. A quota is not capacity (QUOTA-NOT-CAPACITY-1), a delete
    # lock is not a ReadOnly lock, a disabled subscription is not a lock, and a
    # refusal during the move is not the permission check before it. ORDER
    # MATTERS: the first code whose pattern matches wins, so a quota message
    # that also says "allocation" is a quota.
    $patterns = [ordered]@{
        quotaExceeded        = @('QuotaExceeded', 'OperationNotAllowed.*quota', 'exceeding approved .* quota',
            'subscription .* quota')
        capacityUnavailable  = @('AllocationFailed', 'SkuNotAvailable', 'ZonalAllocationFailed',
            'OverconstrainedAllocationRequest')
        subscriptionReadOnly = @('ReadOnlyDisabledSubscription')
        # Review of STOP-TEXT-SPECIFIC-1: a ReadOnly lock refuses a delete with
        # the same ScopeLocked words as a CanNotDelete lock, so Azure's error
        # does not say the lock type. The typed stop resourceLocked comes only
        # from the lock verdict at Checking, which reads each lock's level
        # (a CanNotDelete stop was removed with the rebuild:
        # REBUILD-REMOVE-LEFTOVERS-1).
        resourceLockRefused  = @('ScopeLocked', 'CanNotDelete', 'locked resource', 'the scope .* is locked',
            'cannot perform (delete|write) operation because following scope')
        permissionRefused    = @('AuthorizationFailed', 'does not have authorization to perform action',
            'LinkedAuthorizationFailed')
        # SAFETY-3: a safety copy deleted under the product's lock is found before
        # the machine is changed; the code names it so the guidance can too.
        safetyCopyMissing   = @('Safety copy missing')
        # LVM-1 / STORAGE-SPACES-1: a machine that came back without a volume
        # group or storage pool is a specific, actionable failure, not a
        # generic "validation failed after conversion" - the operator needs to
        # know it is their DATA volume that is missing, not the boot path.
        storageVolumesLost  = @('Storage volumes are missing after the move')
    }

    # ACTIVITY-LINES-1 (review): the step loop gives Resolve-VmfOperationError's
    # text - the messages of the error chain joined by ' -> '. Each pattern is
    # asked of one message at a time, so a word of one message and a word of
    # another ("subscription" in the outer, "quota" in an inner) are never one
    # match.
    $parts = @($Message -split ' -> ' | Where-Object { $_ })
    foreach ($code in $patterns.Keys) {
        foreach ($p in $patterns[$code]) {
            foreach ($part in $parts) { if ($part -match $p) { return $code } }
        }
    }
    'stepFailedRepeatedly'
}

function Get-VmfRetryEntryState {
    <#
    .SYNOPSIS
        Where a retry of this machine should re-enter the state machine.
    .DESCRIPTION
        RETRY-1: this used to be a question put to the operator ("run the
        safety checks again" or "only repeat the final health checks"). It is
        not a judgement call - it follows from what already happened:

        - The conversion completed and only the VALIDATING pass failed, so the
          machine is already on its target hardware. Re-running the whole
          conversion would be churn. Re-validate.
        - Everything else starts at PRECHECK, which re-verifies every fact
          just-in-time before anything mutates. A parked machine was never
          verified at all; a rolled-back machine is back on its original size
          and must be re-checked from scratch.

        PRECHECK is the safe default in every ambiguous case, because it
        cannot skip a check.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object]$Document)

    if ($Document.state -ne 'FAILED_NEEDS_ATTENTION') { return 'PRECHECK' }

    $last = @($Document.history) | Where-Object { $_.outcome -eq 'fail' } | Select-Object -Last 1
    if ($last -and [string]$last.reasonCode -eq 'validationFailedAfterConversion') { return 'VALIDATING' }
    'PRECHECK'
}

function Get-VmfWaitingDecisionStop {
    <#
    .SYNOPSIS
        DECIDE-ROLE-1: the stop a machine waits at NOW, when it is a park for
        a person - or $null.
    .DESCRIPTION
        "The newest history entry with a reason code" is not always the park.
        So the park is the LAST history entry, it must be a NEEDS_DECISION
        entry with a reason code, and no restore may be as new as it or newer.
        A time that cannot be read when such a record exists is not a yes.

        The run page asks the same question (decisionWaiting in
        migrations.html); both are held to tests/fixtures/decision-waiting.json.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$Document)

    # Fields and times read as Test-VmfRetryHeld reads them (Get-VmfRecordField,
    # and a time made UTC), except that a time that cannot be read is null
    # here rather than an error: unknown is not a yes.
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $utc = {
        param($v)
        if ($v -is [datetime]) { return $v.ToUniversalTime() }
        if (-not $v) { return $null }
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$v, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$parsed)) { return $parsed }
        $null
    }
    if (-not $Document -or [string](& $f $Document 'state') -ne 'NEEDS_DECISION') { return $null }
    # The LAST entry, as Resolve-VmfDecision reads it - and a null entry is
    # no park, not an error.
    $history = @(& $f $Document 'history')
    $last = if ($history.Count) { $history[-1] } else { $null }
    if (-not $last -or [string](& $f $last 'state') -ne 'NEEDS_DECISION' -or -not [string](& $f $last 'reasonCode')) { return $null }

    $later = @(
        (& $f (& $f $Document 'restore') 'restoredUtc')
    ) | Where-Object { $null -ne $_ -and [string]$_ }
    if (@($later).Count) {
        $parkedAt = & $utc (& $f $last 'tsUtc')
        if ($null -eq $parkedAt) { return $null }
        foreach ($v in $later) {
            $at = & $utc $v
            if ($null -eq $at -or $at -ge $parkedAt) { return $null }
        }
    }
    $last
}