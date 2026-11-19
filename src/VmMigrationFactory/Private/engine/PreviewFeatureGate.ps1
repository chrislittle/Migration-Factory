# TEMP-DISK-PREVIEW-1: Checking reads the preview feature again, before any
# change, for a machine whose move is the in-place upgrade with the preview
# feature VMTempDiskResizePreview (plan entry target.choice.method preview).
#
# MEASURED 2026-11-01: with the feature not registered, Azure refuses the
# resize across the temporary disk kinds (OperationNotAllowed). That refusal
# comes while the machine is stopped, after the first safety copy. So the
# subscription is asked here, where a stop costs nothing: a subscription that
# unregistered the feature after the plan was made stops the machine
# untouched. A read that fails is not a yes either.

function Get-VmfPreviewFeatureGate {
    <#
    .SYNOPSIS
        TEMP-DISK-PREVIEW-1: $null when the move may go on, or the stop.
    .DESCRIPTION
        Only for an entry whose method is preview; any other move reads
        nothing. The gate keeps no answer: every run of Checking asks Azure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$PlanEntry
    )
    if ((Get-VmfEntryMethod -Entry $PlanEntry) -ne 'preview') { return $null }
    $feature = Get-VmfPreviewFeatureName
    $subId = [string]$Context.SubscriptionId
    $read = Invoke-VmfAzOperation -Name 'previewFeature' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfPreviewFeatureState -SubscriptionId $subId
    }
    $sub = if ($read -and [string]$read.SubscriptionName -and [string]$read.SubscriptionName -ne $subId) { "$($read.SubscriptionName) ($subId)" } else { $subId }
    if ($read -and $read.Read -and $read.Registered) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'precheck' -Outcome info -VmId $Context.VmId `
            -Detail "The preview feature $($feature.Name) is registered on subscription $sub. This machine takes the in-place upgrade (Preview)."
        return $null
    }
    $lead = "This machine takes the in-place upgrade (Preview), which needs the preview feature $($feature.Name) on subscription $sub."
    if ($read -and $read.Read) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'previewFeatureNotRegistered'; MachineState = 'untouched'
                  Detail = "$lead Azure gives its state as $($read.State), and it is not registered. Nothing on the machine changed." }
    }
    # STOP-TEXT-SPECIFIC-1: a feature it could not read is its own reason -
    # the fix is the read, not a registration.
    @{ Next = 'NEEDS_DECISION'; Reason = 'previewFeatureNotRead'; MachineState = 'untouched'
       Detail = ("$lead The product could not read its state ($(if ($read) { $read.Detail } else { 'no answer' })). " +
                 'Nothing on the machine changed.') }
}

# PREVIEW-PUTBACK-1: the rollback of a Preview move needs the feature too.
#
# A Preview move is Path A, so its rollback and Restore this machine from the
# first copy resize the machine back across the same kinds of temporary disk
# (Set-VmfVmSizeAndController). Azure allows that only with the feature
# registered (MEASURED 2026-11-01: refused without it). Checking read it before
# the move; a subscription that unregistered it afterwards got the refusal
# while the machine was stopped, and the machine was left stopped.
#
# Owner rules (one change window; every disk back, or refuse before any
# change): both ways back ask here, BEFORE they make a disk or stop the
# machine, and refuse there. A rebuild of the rollback is not used instead:
# it deletes the system-assigned identity and the extensions the Preview kept,
# which needs a named acceptance (IDENTITY-LOSS-1, REBUILD-ACCEPT-1).

# The stop reason of a rollback refused here (data/stop-reasons.json).
$script:VmfPreviewRollbackReason = 'previewRollbackNotRegistered'

function Get-VmfStartedMoveMethod {
    <#
    .SYNOPSIS
        PREVIEW-PUTBACK-1: the method of the move a machine STARTED - the
        record PRECHECK wrote (captured.startedTarget, STATE-TARGET-1) - else
        the plan entry's. '' for none. Pure.
    .DESCRIPTION
        The record wins: it says what Azure did to the machine, and the plan
        entry can change after the move started. A record from before the
        method was saved has no method, and is not filled in from the entry.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][AllowNull()]$PlanEntry
    )
    $captured = if ($Doc -and $Doc.PSObject.Properties['captured']) { $Doc.captured } else { $null }
    $started = if ($captured -and $captured.PSObject.Properties['startedTarget']) { $captured.startedTarget } else { $null }
    if ($started) {
        $target = if ($started.PSObject.Properties['target']) { $started.target } else { $null }
        return (Get-VmfEntryMethod -Entry ([pscustomobject]@{ target = $target }))
    }
    Get-VmfEntryMethod -Entry $PlanEntry
}

function Get-VmfPreviewRollbackPowerWords {
    <#
    .SYNOPSIS
        Review of PREVIEW-PUTBACK-1: for a resumed rollback that the check
        refused, one sentence that says whether the machine runs or is
        stopped, from the power state Azure reports now.
    .DESCRIPTION
        An earlier worker of the same rollback can have stopped the machine
        before it was lost, and the state document does not record that stop
        (rollbackPending has no such field). So the words never say "as the
        failed step left it" here: they say what Azure reports, or that the
        product could not read it. A lost lease is passed up.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Context)
    try {
        $power = [string](Invoke-VmfAzOperation -Name 'rollback:previewPower' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName
        })
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return "An earlier try of this rollback can have stopped the machine, and the product could not read its power state ($($_.Exception.Message))."
    }
    if ($power -eq 'PowerState/running') { return "Azure reports the machine as Running, on its new size." }
    "Azure reports the machine as $(Get-VmfPowerStateName -Power $power), not Running. An earlier try of this rollback or the failed step stopped it, and it stays stopped on its new size until the feature is registered and the machine is restored."
}

function Get-VmfPreviewPutBackCheck {
    <#
    .SYNOPSIS
        PREVIEW-PUTBACK-1: may the rollback of this move resize the machine
        in place? $null when the move is not a Preview; otherwise
        @{ Refuse = bool; Detail = string }.
    .DESCRIPTION
        Asked before the rollback makes a disk or stops the machine. Reads the
        feature (the read the move's Checking made); registered goes on. Not
        registered, or not read: the machine's size now is read (or -SizeNow,
        when the caller read it). On its original size already - Azure refused
        the forward resize - the rollback changes no temporary disk and goes
        on; a refusal then would leave a stopped machine that can be put
        back. Any other size, or a size that cannot be read: refused. The check
        keeps no answer, and it never registers the feature.
        PREVIEW-RESTORE-UPFRONT-1: the decision and its words are
        Get-VmfPreviewPutBackVerdict, which the web service asks too.
    .PARAMETER Kind
        rollback (the automatic rollback) or restore (Restore this machine from
        the first copy): only the words of what to do next differ.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter()][AllowEmptyString()][string]$Method,
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][AllowEmptyString()][string]$SizeNow = ''
    )
    if ($Method -ne 'preview') { return $null }
    $subId = [string]$Context.SubscriptionId
    $read = Invoke-VmfAzOperation -Name "$($Kind):previewFeature" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        Get-VmfPreviewFeatureState -SubscriptionId $subId
    }
    $now = $SizeNow
    if (-not ($read -and $read.Read -and $read.Registered) -and -not $now) {
        try {
            $now = [string](Invoke-VmfAzOperation -Name "$($Kind):previewSizeNow" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfVmSize -ResourceGroupName $Context.Rg -Name $Context.VmName
            })
        }
        catch {
            # A lost lease is not "no answer": another worker holds the machine.
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $now = ''
        }
    }
    Get-VmfPreviewPutBackVerdict -Kind $Kind -Size $Size -SizeNow $now -SubscriptionId $subId -FeatureRead $read
}

function Get-VmfPreviewPutBackVerdict {
    <#
    .SYNOPSIS
        PREVIEW-RESTORE-UPFRONT-1: the one decision, and its words, for the
        rollback of a Preview move, from what was read. Pure: no Azure call.
        @{ Refuse = bool; Detail = string }.
    .DESCRIPTION
        The engine (Get-VmfPreviewPutBackCheck) and the web service
        (Get-VmfPreviewPutBackRefusal) read with their own commands and ask
        this, so the dialog says what the engine writes. Registered goes on.
        Else the machine on its original size goes on (its rollback changes no
        temporary disk). Else, a size that is not known included: refused.
    .PARAMETER SizeNow
        The machine's size now; '' when it was not read.
    .PARAMETER FeatureRead
        What Get-VmfPreviewFeatureState gave; $null for no answer.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][AllowEmptyString()][string]$SizeNow = '',
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter()][AllowNull()]$FeatureRead
    )
    $feature = Get-VmfPreviewFeatureName
    $read = $FeatureRead
    $subId = $SubscriptionId
    $sub = if ($read -and [string]$read.SubscriptionName -and [string]$read.SubscriptionName -ne $subId) { "$($read.SubscriptionName) ($subId)" } else { $subId }
    $way = if ($Kind -eq 'rollback') { 'the rollback' } else { 'the restore' }
    if ($read -and $read.Read -and $read.Registered) {
        return @{ Refuse = $false
            Detail = "The preview feature $($feature.Name) is registered on subscription $sub, so $way can return the machine to $Size in place." }
    }
    $now = $SizeNow
    if ($now -and $now -ieq $Size) {
        return @{ Refuse = $false
            Detail = "The machine is on $Size already, so a rollback or a restore does not change the temporary disk and does not need the preview feature $($feature.Name)." }
    }
    $why = if ($read -and $read.Read) { "Azure gives its state as $($read.State), and it is not registered." }
           else { "The product could not read its state ($(if ($read) { $read.Detail } else { 'no answer' }))." }
    $next = if ($Kind -eq 'rollback') {
        "Register the preview feature $($feature.Name) on subscription $sub again. In the Azure portal, open the subscription, then Settings, then Preview features. " +
        'Then use Restore this machine and choose the safety copy Before the migration. The product does not rebuild the machine or start it on its new size.'
    } else {
        "Nothing on the machine changed. Register the preview feature $($feature.Name) on subscription $sub again. In the Azure portal, open the subscription, then Settings, then Preview features. " +
        'Then use Restore this machine again.'
    }
    @{ Refuse = $true
       Detail = ("This machine took the in-place upgrade (Preview). A rollback or a restore to $Size changes the temporary disk again. " +
                 "Azure allows that only when the preview feature $($feature.Name) is registered on subscription $sub. $why $next") }
}

function Get-VmfPreviewPutBackRefusal {
    <#
    .SYNOPSIS
        PREVIEW-RESTORE-UPFRONT-1: for the web service, before it starts
        Restore this machine from the first copy: the refusal of a Preview
        move's rollback, in the engine's words. $null when it may start.
    .DESCRIPTION
        The method is the record's (captured.startedTarget), as the engine
        asks it (Get-VmfStartedMoveMethod -Doc). It reads with Az.Accounts
        only, as the web service's own identity (VMF Assessment role): the
        feature (Get-VmfPreviewFeatureState) and, when that is not
        registered, the machine's size (Get-VmfVmSizeByArm).
        It refuses ONLY on a definite answer: the feature read says not
        registered, and the machine is on a size that is not its original
        size. A record it cannot read, a feature read that fails, or a size it
        cannot read gives $null: the engine asks again with its own identity
        before it makes a disk or stops the machine, and that is the guarantee.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId)
    $recorded = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $recorded
    if (-not $doc -or -not $doc.captured -or -not $doc.captured.vmConfig) { return $null }
    if ((Get-VmfStartedMoveMethod -Doc $doc) -ne 'preview') { return $null }
    # ROLLBACK-SIZE-REFUSED-SERIES-1: a restore onto the target size of the
    # plan refuses a Preview move by its own rule (Get-VmfRestoreOntoTarget).
    $onto = Get-VmfRestoreOntoTargetForRun -RunPath $RunPath -VmId $recorded -Doc $doc
    if ($onto) { return $(if ($onto.Refusal) { [string]$onto.Refusal } else { $null }) }
    $subId = Assert-VmfResourceId -ResourceId $recorded -Kind 'virtual machine'
    $read = Get-VmfPreviewFeatureState -SubscriptionId $subId
    if (-not ($read -and $read.Read) -or $read.Registered) { return $null }
    $now = try { [string](Get-VmfVmSizeByArm -VmId $recorded) } catch { '' }
    if (-not $now) { return $null }
    # ROLLBACK-RETRY-CAPTURE-1: the size it goes back to is the FIRST capture's.
    $capture = Get-VmfPutBackCapture -Doc $doc
    $verdict = Get-VmfPreviewPutBackVerdict -Kind 'restore' -Size ([string]$capture.size) -SizeNow $now -SubscriptionId $subId -FeatureRead $read
    if ($verdict.Refuse) { return $verdict.Detail }
    $null
}
