function Invoke-VmfVolumesCheck {
    <#
    .SYNOPSIS
        VOLUMES-RESTORE-MIGRATED-1: check the volumes of one machine whose
        record owes that check - the engine operation 'checkvolumes', which
        Check the volumes on the machine panel starts.
    .DESCRIPTION
        Restore this machine on a migrated machine can leave a volume that was
        mounted before the move not mounted (VOLUMES-ONLINE-1). The record then
        owes a check of the volumes (volumesCheckOwed) and keeps the machine
        changed. The machine stays MIGRATED, so Try this machine again, whose
        first step is that check (VOLUMES-RETRY-CHECK-1), is not offered.
        After the person mounts the volume, this runs the same check with no
        move:
          - it takes the machine, as a restore does (Enter-VmfMachineLease);
          - a machine that is turned off is started for the check and returned
            to its power state (Invoke-VmfVolumesCheckStarted,
            VOLUMES-RETRY-CHECK-OFF-1);
          - every volume mounted again (a measured MATCH): one line, in the
            state the machine has, says restored and removes the record that
            owes the check, in the same write;
          - a volume still not mounted: the stop volumesNotBack, changed, and
            the record owes the check as volumesNotBack;
          - the check could not run: the stop volumesNotChecked, changed, and
            the record stays as it was - unknown never replaces a volume found
            not mounted, and is never a pass.
        A power state Azure refused to return to is owed on the line
        (powerNotPutBack), and the panel offers Return to the power state.
        Safe to run again (rule 4): a record that owes nothing writes nothing,
        and a job stopped after the start reads the power state on record and
        returns the machine to it.
    .PARAMETER By
        Who asked for it, on the line.
    .PARAMETER CorrelationId
        The engine operation's id: the name the job holds the machine under.
    .EXAMPLE
        Invoke-VmfVolumesCheck -RunPath .\run1 -VmId $vmId -By 'lead@contoso.com'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string]$By = 'unknown',
        [Parameter()][string]$CorrelationId
    )

    $id = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $vmName = ($id -split '/')[-1]
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $id
    if (-not $doc) { throw "There is no record of $vmName in this migration." }
    # VOLUMES-CHECK-JOB-STOP-1: a start for the check that the return did not
    # end is always returned, also when nothing owes the check now.
    if (-not (Get-VmfVolumesCheckOwed -Doc $doc) -and -not (Get-VmfVolumesCheckStarted -Doc $doc)) {
        return [pscustomobject]@{ VmId = $id; Verdict = $null; Detail = "The record of $vmName owes no check of the volumes." }
    }
    $refusal = Get-VmfVolumesCheckRefusal -Doc $doc -VmName $vmName
    if ($refusal) { throw $refusal }
    if (-not $PSCmdlet.ShouldProcess($vmName, 'check the volumes inside the machine')) { return }

    $subscriptionId = Assert-VmfResourceId -ResourceId $id -Kind 'virtual machine'
    $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $subscriptionId
    $lease = $null
    try {
        $lease = Enter-VmfMachineLease -RunPath $RunPath -VmId $id -Holder (Get-VmfMachineLeaseHolder -Kind 'restore' -CorrelationId $CorrelationId)
        # Under the hold, the record again: a job that ended between the first
        # read and the hold can have changed it.
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $id
        $owed = Get-VmfVolumesCheckOwed -Doc $doc
        $startedRecord = Get-VmfVolumesCheckStarted -Doc $doc
        if (-not $owed -and -not $startedRecord) {
            return [pscustomobject]@{ VmId = $id; Verdict = $null; Detail = "The record of $vmName owes no check of the volumes." }
        }
        $refusal = Get-VmfVolumesCheckRefusal -Doc $doc -VmName $vmName
        if ($refusal) { throw $refusal }
        $context = [pscustomobject]@{ RunPath = $RunPath; VmId = $id; Rg = ($id -split '/')[4]; VmName = $vmName }
        if (-not $owed) {
            # Nothing owes the check, but an earlier job started the machine
            # for it and stopped before the return: only the return.
            $back = Restore-VmfClusterCheckPower -Context $context -Power ([string]$startedRecord.power) -RecordName 'volumesCheckPower' -Step 'volumesCheck' `
                -NextStep 'Select Return to the power state to return the machine to the power state {power}.'
            $state = [string](Read-VmfStateDoc -RunPath $RunPath -VmId $id).state
            if (-not $back.Ok) {
                Add-VmfStateTransition -RunPath $RunPath -VmId $id -NewState $state -Outcome fail -MachineState 'changed' -PowerNotPutBack $back.PowerNotPutBack `
                    -Detail "$($back.Words) $By asked for the check." | Out-Null
            }
            Write-VmfStepLine -RunPath $RunPath -Step 'volumesCheck' -Outcome $(if ($back.Ok) { 'ok' } else { 'warn' }) -VmId $id -Detail "$($back.Words) $By asked for the check."
            return [pscustomobject]@{ VmId = $id; Verdict = $null; Detail = [string]$back.Words }
        }
        $run = Invoke-VmfVolumesCheckStarted -Context $context -Os (Get-VmfGuestOsFromRecord -Doc $doc) -Kind 'check' -Step 'volumesCheck' `
            -NextStep 'Select Return to the power state to return the machine to the power state {power}.'
        $check = $run.Check
        $verdict = [string]$check.verdict
        $state = [string](Read-VmfStateDoc -RunPath $RunPath -VmId $id).state
        $asked = "$By asked for the check."
        $powerWords = if ($run.PutBack) { " $([string]$run.PutBack.Words)" } else { '' }
        $notBack = @{}
        if ($run.PutBack -and -not $run.PutBack.Ok) { $notBack.PowerNotPutBack = [string]$run.PutBack.PowerNotPutBack }
        $kind = [string](Get-VmfRecordField -Object $owed -Name 'kind')
        if ($kind -notin @('rollback', 'restore')) { $kind = 'restore' }
        switch ($verdict) {
            'MATCH' {
                # Measured: every volume is back, so the machine is restored and
                # owes no check - in one write. Only the power state can still
                # be owed.
                $machineState = if ($notBack.Count) { 'changed' } else { 'restored' }
                Add-VmfStateTransition -RunPath $RunPath -VmId $id -NewState $state -Outcome ok -MachineState $machineState @notBack `
                    -Amend { param($d) if ($d.PSObject.Properties['volumesCheckOwed']) { $d.PSObject.Properties.Remove('volumesCheckOwed') } } `
                    -Detail "$([string]$check.words) $asked$powerWords" | Out-Null
            }
            'MISSING' {
                Add-VmfStateTransition -RunPath $RunPath -VmId $id -NewState $state -Outcome fail -MachineState 'changed' -ReasonCode 'volumesNotBack' @notBack `
                    -Amend { param($d) Set-VmfVolumesCheckOwed -Doc $d -Verdict 'MISSING' -Kind $kind } `
                    -Detail "$([string]$check.words) $(Get-VmfVolumesCheckNextStep) $asked$powerWords" | Out-Null
            }
            default {
                Add-VmfStateTransition -RunPath $RunPath -VmId $id -NewState $state -Outcome fail -MachineState 'changed' -ReasonCode 'volumesNotChecked' @notBack `
                    -Detail "$([string]$check.words) $asked$powerWords" | Out-Null
            }
        }
        Write-VmfStepLine -RunPath $RunPath -Step 'volumesCheck' -Outcome $(if ($verdict -eq 'MATCH' -and -not $notBack.Count) { 'ok' } else { 'warn' }) -VmId $id `
            -Detail "$([string]$check.words) $asked$powerWords"
        [pscustomobject]@{ VmId = $id; Verdict = $verdict; Detail = [string]$check.words }
    }
    finally {
        Exit-VmfMachineLease -Token $lease
        Restore-VmfSubscriptionContext -Context $previousAzContext
    }
}
