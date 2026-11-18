function Restore-VmfMachinePower {
    <#
    .SYNOPSIS
        POWER-ONLY-CHANGED-1: return each machine whose power state the
        product changed, and has not returned, to the power state it was found
        in - the engine operation 'powerback'.
    .DESCRIPTION
        Since 2026-11-06: a machine the product turned on at any phase, and
        that is then left out or stopped, must be turned off again if it was
        off at the start. Leave this machine out and Stop this migration run in the web
        service, which has no right to change a machine. So they record the
        power state that is owed (history[].powerNotPutBack, Get-VmfPowerOwed)
        and the service starts this operation; the machine panel offers it
        again (Return to the power state) while the power state is owed.

        For each machine (one, or every machine of the run with -VmId left
        out) whose record says a power state is owed and that no wave, restore
        or rebuild works on now:
          - it takes the machine, as a restore does (Enter-VmfMachineLease);
          - it returns the machine to that power state with the product's
            tries (Restore-VmfPowerAsFound -Power, Invoke-VmfPowerPutBack);
          - it writes a line in the state the machine has: untouched when the
            power state is back, which ends what is owed; else changed, with
            the power state still owed and Azure's words;
          - with the power state back, a machine that is left out gives back
            its claim (Remove-VmfSettledVmClaim).
        Safe to run again (rule 4): a machine with nothing owed is only asked
        for its claim, and a job stopped after the return and before its line
        returns the machine again - a return to a power state the machine has
        does nothing. A lease lost on one machine is said for it, and the
        other machines go on.
    .PARAMETER By
        Who asked for it, on each line.
    .PARAMETER CorrelationId
        The engine operation's id: the name the job holds each machine under.
    .EXAMPLE
        Restore-VmfMachinePower -RunPath .\run1 -VmId $vmId -By 'lead@contoso.com' -Note 'left out'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][string]$VmId,
        [Parameter()][string]$By = 'unknown',
        [Parameter()][AllowEmptyString()][string]$Note = '',
        [Parameter()][string]$CorrelationId
    )

    # The machines this run holds, as its plan spells them.
    $plan = Read-VmfPlanDocument -RunPath $RunPath -Depth 24
    $ids = @(@($plan.entries) | Where-Object { $_ -and $_.vmId } | ForEach-Object { [string]$_.vmId })
    if ($VmId) {
        $one = @($ids | Where-Object { $_ -ieq $VmId })
        if (-not $one.Count) { throw "'$VmId' is not in this migration's plan." }
        $ids = @($one[0])
    }
    $settled = @('SKIPPED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'MIGRATED')
    $noteSaid = if ($Note) { " ($Note)" } else { '' }

    foreach ($id in $ids) {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $id
        if (-not $doc) { continue }
        $owed = Get-VmfPowerOwed -Doc $doc
        $vmName = ($id -split '/')[-1]
        if (-not $owed) {
            # Nothing owed: a machine left out whose power state is back gives
            # back its claim (a job stopped after its line, before this).
            if ([string]$doc.state -eq 'SKIPPED') { try { Remove-VmfSettledVmClaim -RunPath $RunPath -VmId $id | Out-Null } catch { Write-Warning "The claim of '$vmName' was not released: $($_.Exception.Message)" } }
            continue
        }
        # A machine a worker moves now is the worker's: its own stops return
        # the power state.
        if ([string]$doc.state -notin $settled) {
            [pscustomobject]@{ VmId = $id; Power = $owed; Returned = $false; Detail = "The product did not return $vmName to its power state, because it is at the step $($doc.state)." }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($vmName, "return to the power state $(Get-VmfPowerStateName -Power $owed)")) { continue }

        $subscriptionId = Assert-VmfResourceId -ResourceId $id -Kind 'virtual machine'
        $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $subscriptionId
        $lease = $null
        try {
            try { $lease = Enter-VmfMachineLease -RunPath $RunPath -VmId $id -Holder (Get-VmfMachineLeaseHolder -Kind 'restore' -CorrelationId $CorrelationId) }
            catch {
                [pscustomobject]@{ VmId = $id; Power = $owed; Returned = $false; Detail = "The product did not return $vmName to its power state now: $($_.Exception.Message)" }
                continue
            }
            $context = [pscustomobject]@{ RunPath = $RunPath; VmId = $id; Rg = ($id -split '/')[4]; VmName = $vmName }
            # A lost lease is another job's machine now: nothing is written for
            # it, the power state stays owed, and the other machines go on.
            try { $back = Restore-VmfPowerAsFound -Context $context -Power $owed -OpName 'powerBack' }
            catch {
                if ($_.Exception.Message -notmatch 'abandon this VM') { throw }
                [pscustomobject]@{ VmId = $id; Power = $owed; Returned = $false; Detail = "The product did not return $vmName to its power state: $($_.Exception.Message)" }
                continue
            }
            $docNow = Read-VmfStateDoc -RunPath $RunPath -VmId $id
            $state = [string]$docNow.state
            if ($back.Ok) {
                # POWER-AFTER-MOVE-1: the line says where the machine is, with
                # its power state back - changed after a move, restored after a
                # rollback, a restore, untouched before any change.
                Add-VmfStateTransition -RunPath $RunPath -VmId $id -NewState $state -Outcome ok -MachineState (Get-VmfPowerBackMachineState -Doc $docNow) -PowerPutBack `
                    -Detail "$($back.Words) $By asked for it$noteSaid." | Out-Null
                if ($state -eq 'SKIPPED') {
                    try { Remove-VmfSettledVmClaim -RunPath $RunPath -VmId $id | Out-Null }
                    catch { Write-Warning "The claim of '$vmName' was not released: $($_.Exception.Message)" }
                }
            }
            else {
                Add-VmfStateTransition -RunPath $RunPath -VmId $id -NewState $state -Outcome fail -MachineState 'changed' -PowerNotPutBack $owed `
                    -Detail "$($back.Words) $By asked for it$noteSaid." | Out-Null
            }
            Write-VmfStepLine -RunPath $RunPath -Step 'powerBack' -Outcome $(if ($back.Ok) { 'ok' } else { 'warn' }) -VmId $id -Detail $back.Words
            [pscustomobject]@{ VmId = $id; Power = $owed; Returned = [bool]$back.Ok; Detail = $back.Words }
        }
        finally {
            Exit-VmfMachineLease -Token $lease
            Restore-VmfSubscriptionContext -Context $previousAzContext
        }
    }
}
