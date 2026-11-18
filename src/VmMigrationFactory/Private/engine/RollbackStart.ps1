# ROLLBACK-CAPACITY-1 (2026-11-14): the start at the end of a rollback,
# tried again while Azure has no capacity for the original size.
#
# A rollback returns a machine to its original size, and Microsoft restricts
# capacity growth for older series (target-families.json
# lifecycle.capacityRestrictions, from the pinned page
# retirements-and-capacity-restrictions). The product cannot guarantee
# capacity: an on-demand capacity reservation for an old size often cannot be
# had either. So the start tries an allocation failure again, a few times over
# some minutes, and then stops and says so - with every disk back and the
# machine stopped on its original size.
#
# The codes are Microsoft's, from "Troubleshooting Azure VM allocation
# failures" (https://learn.microsoft.com/troubleshoot/azure/virtual-machines/windows/allocation-failure,
# read 2026-11-14): AllocationFailed and ZonalAllocationFailed when a start of
# a stopped (deallocated) VM finds no capacity, OverconstrainedAllocationRequest
# and OverconstrainedZonalAllocationRequest when the constraints of the
# request cannot be met. For each the page says to retry the allocation later.
# SkuNotAvailable, a quota and NotAvailableForSubscription are not on it: more
# minutes do not mend them, so they are not tried again here.
#
# Invoke-VmfAzOperation does not try these again on its own (Azure answers 409,
# not a temporary status, and capacity comes back in minutes or hours, not in
# seconds of backoff - Get-VmfErrorStopReason). The tries are here, around it,
# so each try is still one narrated operation with the wrapper's own tries for
# a temporary error.
#
# Kill-resume (hard rule 4): the waits are inside the rollback, whose
# checkpoint (rollbackPending) is written before its first change. A worker
# that stops between two tries leaves it, and the next worker runs the
# rollback again (Complete-VmfRollback -Resumed) - the same disks, the same
# swaps, and the start with its tries from the first.

$script:VmfAllocationFailureCodes = @('AllocationFailed', 'ZonalAllocationFailed', 'OverconstrainedAllocationRequest', 'OverconstrainedZonalAllocationRequest')
# 4 tries, 2 minutes apart: about 6 minutes of waits. Each wait is far below the
# lease's 15 minutes, and the lease is renewed before and after each.
$script:VmfRollbackStartTries = 4
$script:VmfRollbackStartWaitSeconds = 120

function Get-VmfAllocationFailureCode {
    <#
    .SYNOPSIS
        ROLLBACK-CAPACITY-1: the allocation failure code an error names, or
        $null. PURE.
    .DESCRIPTION
        A code counts only as a whole word: a name such as 'vm-AllocationFailedTest'
        is a name. "ProvisioningState/failed/AllocationFailed", the code
        Start-VmfVm reads from the instance view, counts.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Message)
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    # Every quoted name taken out first, as Get-VmfTransientVerdict does.
    $plain = $Message -replace "'[^'\s]*'", ' '
    foreach ($code in $script:VmfAllocationFailureCodes) {
        if ($plain -cmatch "(?<![A-Za-z0-9_-])$code(?![A-Za-z0-9_-])") { return $code }
    }
    $null
}

function Get-VmfSizeRefusalCode {
    <#
    .SYNOPSIS
        ROLLBACK-CAPACITY-1 review: the code with which Azure refused a size,
        or $null. PURE.
    .DESCRIPTION
        Only Azure's refusal of the size itself makes the rollback stop with
        rollbackSizeRefused. The codes are Microsoft's:
        - SkuNotAvailable, and the restriction NotAvailableForSubscription
          ("Resolve errors for SKU not available",
          https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-sku-not-available);
        - OperationNotAllowed when it names a quota ("Resolve errors for
          resource quotas",
          https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-resource-quota)
          or the size itself. OperationNotAllowed is also Azure's answer for
          other operations, so it alone is not a refusal of the size;
        - RequestDisallowedByPolicy, an Azure Policy deny ("Resolve errors for
          request disallowed by policy",
          https://learn.microsoft.com/azure/azure-resource-manager/troubleshooting/error-policy-requestdisallowedbypolicy).
          ROLLBACK-POLICY-DENY-1 (2026-11-16): the caller asks only
          about the rollback's size-and-controller update, which changes
          nothing else, and the same machine took the move's update to the
          new size - so the policy refused the size. A policy refusal of any
          other step is a failed rollback.
        A code counts only as a whole word, outside a quoted name. A throttle
        out of tries, a timeout or a failed update status is no refusal: the
        rollback failed, and says so (rollbackFailed).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Message,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Size
    )
    if ([string]::IsNullOrWhiteSpace($Message)) { return $null }
    $plain = $Message -replace "'[^'\s]*'", ' '
    foreach ($code in 'NotAvailableForSubscription', 'SkuNotAvailable') {
        if ($plain -cmatch "(?<![A-Za-z0-9_-])$code(?![A-Za-z0-9_-])") { return $code }
    }
    if ($plain -cmatch '(?<![A-Za-z0-9_-])OperationNotAllowed(?![A-Za-z0-9_-])') {
        if ($plain -match '\bquota\b') { return 'OperationNotAllowed' }
        if ($Size -and $Message.IndexOf($Size, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return 'OperationNotAllowed' }
    }
    if (Get-VmfPolicyDenial -Message $Message) { return 'RequestDisallowedByPolicy' }
    $null
}

function Get-VmfRollbackNoCapacityWords {
    <#
    .SYNOPSIS
        ROLLBACK-CAPACITY-1: what the stop says when Azure has no capacity for
        the original size after every try. The words wait for approval.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Size)
    "Every disk is back from the first safety copy. The machine is stopped on $Size. " +
        "When Azure has capacity for $Size again, start the machine. " +
        "Or select Change to v5. " +
        "A move to v5 changes the size first, and then starts the machine. " +
        "If a Windows machine needs a change inside it before the move, it must run on $Size first."
}

function Get-VmfRollbackSizeRefusedWords {
    <#
    .SYNOPSIS
        ROLLBACK-CAPACITY-1, case B: what the stop says when Azure refused the
        original size, before any disk swap. The words wait for approval.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$StepWord,
        [Parameter(Mandatory)][string]$Size,
        [Parameter()][AllowEmptyString()][string]$NewSize,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Why,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Fail,
        [Parameter()][AllowEmptyString()][string]$MadeNote,
        # ROLLBACK-CAPACITY-1 review: what the rollback put back before the
        # size, one sentence each (Invoke-VmfRollback).
        [Parameter()][AllowNull()][string[]]$PutBack,
        # ROLLBACK-POLICY-DENY-1: Azure Policy's refusal (Get-VmfPolicyDenial).
        # The stop names the assignment and says what to do, and never shows
        # Azure's policy JSON.
        [Parameter()][AllowNull()]$PolicyDenial
    )
    $on = if ($NewSize) { "stopped on $NewSize" } else { 'stopped on its new size' }
    $back = @($PutBack | Where-Object { $_ })
    $backWords = if ($back.Count) { ' ' + ($back -join ' ') } else { ' This rollback found no other setting to restore before the size change.' }
    if ($PolicyDenial) {
        $who = if ([string]$PolicyDenial.Assignment) { "The Azure Policy assignment '$([string]$PolicyDenial.Assignment)'" } else { 'An Azure Policy assignment' }
        return "The $StepWord step failed. The rollback stopped because Azure refused the original size $Size (RequestDisallowedByPolicy). " +
            "$who does not allow this size. The machine is $on. The rollback did not swap a disk.$backWords$MadeNote " +
            "To restore the machine to $Size, change the policy assignment, or add a policy exemption for this machine. Original error: $Why"
    }
    "The $StepWord step failed. The rollback stopped because Azure refused the original size $Size ($Fail). " +
        "The machine is $on. The rollback did not swap a disk.$backWords$MadeNote Original error: $Why"
}

function Start-VmfRollbackVm {
    <#
    .SYNOPSIS
        ROLLBACK-CAPACITY-1: start the machine at the end of a rollback, and try
        an allocation failure again, $script:VmfRollbackStartTries times,
        $script:VmfRollbackStartWaitSeconds seconds apart.
    .DESCRIPTION
        Any other failure goes up at once, as it was: a lost lease ('abandon
        this VM') untouched, everything else for the caller to mark as a
        start that failed with every disk back. Still no capacity after the
        last try: throws an error that names the size and the code, with
        Data['vmfRollbackNoCapacity'] = the size.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Size
    )
    $tries = [math]::Max(1, [int]$script:VmfRollbackStartTries)
    for ($try = 1; $try -le $tries; $try++) {
        try {
            Invoke-VmfAzOperation -Name 'rollback:start' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
            } | Out-Null
            return
        }
        catch {
            # A lost lease ('abandon this VM') names no allocation code, so it
            # goes up below, untouched, as every other failure does.
            $said = (Resolve-VmfOperationError -ErrorRecord $_).Message
            $code = Get-VmfAllocationFailureCode -Message $said
            if (-not $code) { throw }
            $minutes = [math]::Round(($tries - 1) * $script:VmfRollbackStartWaitSeconds / 60)
            if ($try -ge $tries) {
                $words = "Azure has no capacity for $Size now ($code). The product tried to start the machine $tries times in about $minutes minutes."
                $noCapacity = [System.InvalidOperationException]::new($words, $_.Exception)
                $noCapacity.Data['vmfRollbackNoCapacity'] = $Size
                throw $noCapacity
            }
            $wait = [int]$script:VmfRollbackStartWaitSeconds
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'rollback' -Outcome retry -VmId $Context.VmId `
                -Detail "Azure has no capacity for $Size now ($code). Start $try of $tries failed. The product will try to start the machine again in $([math]::Round($wait / 60)) minutes."
        }
        # Outside the catch: a lost lease from the heartbeat goes up as it is.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $wait
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
    }
}
