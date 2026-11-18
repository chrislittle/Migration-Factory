function Remove-VmfMadeDisks {
    <#
    .SYNOPSIS
        MADE-DISK-DELETE-1: delete the managed disks a put-back made from the
        safety copies that the record says nothing uses - the engine operation
        'deletemade', which Delete these disks now on the machine's panel
        starts.
    .DESCRIPTION
        Decided 2026-11-08: a person may delete these disks
        from the app (hard rule 12). A rollback and Restore this machine (and
        Rebuild this machine, in an earlier version) record each disk they
        make (rollbackDisksDuringRollback, restoreDisks). The daily cleanup
        deletes one nothing uses only once the move of the machine has ended,
        so a machine that waits for a person kept it with no end.

          - Only the disks the one rule lists (Get-VmfDeletableMadeDisks: the
            rule of the daily cleanup, the delete of a migration and the
            panel), by resource id, through the cleanup's own delete
            (Remove-VmfRollbackDisksBeforeMoveEntries): each disk is read first; one
            attached to any machine is kept and marked used; one already gone
            counts as deleted; each deleted one is marked deletedUtc on its
            list at once (rule 4), so the panel's list empties and a job that
            stops part way deletes only what is left when it runs again. A
            disk it cannot read, or that Azure does not delete, is kept and
            named.
          - Refused, before Azure is asked, by Get-VmfMadeDiskDeleteRefusal
            (a move that has not ended, the refusals of a restore, a refused
            swap), and while another job holds the machine. It takes the
            machine's hold as a restore does (Enter-VmfMachineLease), and
            reads the record again under it.
          - Nothing is deleted of a machine Azure does not show, or that the
            read does not answer for (Get-VmfMachineAbsentReason, the
            cleanup's rule): those disks can be what rebuilds the machine.
        Nothing is deleted on its own: only a person's Delete these disks now
        starts this. The Activity line (step madeDelete) names each disk, each
        disk kept and why, and who asked.
    .PARAMETER By
        Who asked for it, on the Activity line.
    .PARAMETER CorrelationId
        The engine operation's id: the name the job holds the machine under.
    .EXAMPLE
        Remove-VmfMadeDisks -RunPath .\run1 -VmId $vmId -By 'operator@contoso.com'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string]$By = 'unknown',
        [Parameter()][string]$CorrelationId
    )

    # VMID-CASE-1: the record and the hold are named from the id as the record spells it.
    $recorded = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $vmName = ($recorded -split '/')[-1]
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $recorded
    if (-not $doc) { throw "This migration has no record of '$vmName', so it has no disks made from the safety copies to delete." }
    $refusal = Get-VmfMadeDiskDeleteRefusal -Doc $doc -VmName $vmName
    if ($refusal) { throw $refusal }

    $result = { param($deleted, $skipped, $detail)
        [pscustomobject]@{ VmId = $recorded; Deleted = @($deleted); Skipped = @($skipped); Detail = $detail } }
    if (-not @(Get-VmfDeletableMadeDisks -StateDoc $doc).Count) {
        $none = "'$vmName' has no managed disks made from the safety copies left to delete."
        Write-VmfStepLine -RunPath $RunPath -Step 'madeDelete' -Outcome ok -VmId $recorded -Detail $none -CorrelationId $CorrelationId
        return (& $result @() @() $none)
    }
    if (-not $PSCmdlet.ShouldProcess($vmName, 'delete the managed disks made from its safety copies that nothing uses')) { return }

    $subscriptionId = Assert-VmfResourceId -ResourceId $recorded -Kind 'virtual machine'
    $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $subscriptionId
    $lease = $null
    try {
        $lease = Enter-VmfMachineLease -RunPath $RunPath -VmId $recorded -Holder (Get-VmfMachineLeaseHolder -Kind 'restore' -CorrelationId $CorrelationId)
        # Read again under the hold: the record the disks come from is the one
        # no other job can change now.
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $recorded
        $refusal = Get-VmfMadeDiskDeleteRefusal -Doc $doc -VmName $vmName
        if ($refusal) { throw $refusal }
        $disks = @(Get-VmfDeletableMadeDisks -StateDoc $doc)
        # The cleanup's rule (MADE-DISK-RECORD-1 review): a disk of a machine
        # Azure does not show can be what rebuilds it, and unknown never deletes.
        $absent = Get-VmfMachineAbsentReason -RunPath $RunPath -VmId $recorded
        if ($absent) {
            $kept = "The product did not delete the managed disks made from the safety copies of '$vmName': $(@($disks | ForEach-Object { [string]$_.diskName }) -join ', '). $absent The product does not delete a disk of a machine that Azure does not show. $By asked for it."
            Write-VmfStepLine -RunPath $RunPath -Step 'madeDelete' -Outcome warn -VmId $recorded -Detail $kept -CorrelationId $CorrelationId
            return (& $result @() @($disks | ForEach-Object { [pscustomobject]@{ diskId = [string]$_.diskId; name = [string]$_.diskName; why = $absent } }) $kept)
        }
        $done = Remove-VmfRollbackDisksBeforeMoveEntries -RunPath $RunPath -VmId $recorded -Disks $disks -Step 'madeDelete'

        $skipped = [System.Collections.Generic.List[object]]::new()
        foreach ($u in @($done.InUse)) { $skipped.Add([pscustomobject]@{ name = [string]$u.name; why = "it is attached to the machine '$(([string]$u.managedBy -split '/')[-1])'" }) }
        foreach ($f in @($done.Failed)) { $skipped.Add([pscustomobject]@{ name = [string]$f.name; why = ([string]$f.why).TrimEnd('.') }) }
        $deleted = @($done.Deleted)
        $count = if ($deleted.Count -eq 1) { '1 managed disk' } else { "$($deleted.Count) managed disks" }
        $words = [System.Collections.Generic.List[string]]::new()
        if ($deleted.Count) { $words.Add("The product deleted $count made from the safety copies of '$vmName': $($deleted -join ', ').") }
        foreach ($s in $skipped) { $words.Add("The product did not delete $($s.name): $($s.why).") }
        $words.Add("$By asked for it.")
        $detail = $words -join ' '
        Write-VmfStepLine -RunPath $RunPath -Step 'madeDelete' -Outcome $(if ($skipped.Count) { 'warn' } else { 'ok' }) -VmId $recorded -Detail $detail -CorrelationId $CorrelationId
        & $result $deleted $skipped $detail
    }
    finally {
        Exit-VmfMachineLease -Token $lease
        Restore-VmfSubscriptionContext -Context $previousAzContext
    }
}
