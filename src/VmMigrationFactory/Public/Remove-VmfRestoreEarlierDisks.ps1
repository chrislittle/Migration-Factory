function Remove-VmfRestoreEarlierDisks {
    <#
    .SYNOPSIS
        RESTORE-EARLIER-DELETE-1: delete the earlier managed disks that a
        restore kept - the engine operation 'deleteearlier', which Delete these
        disks on the machine's panel starts. ROLLBACK-ORIGINALS-LEFT-1: with
        -Set rollback, the original disks a rollback swapped off instead.
    .DESCRIPTION
        The approved design (2026-10-25). A restore with new names keeps
        each managed disk the machine had, detached, in Azure, and each costs
        money until somebody deletes it. The panel lists them from the
        restore's own record; this deletes them, for an operator, from the app
        (hard rule 12).

        ROLLBACK-ORIGINALS-LEFT-1 (2026-11-08): a rollback leaves the
        same kind of disk - the disks the machine had before the migration,
        swapped off for disks made from the first safety copy. The panel lists
        them under Original disks, not in use, and its Delete these disks is
        this operation with -Set rollback. One delete for both: the same read
        of each disk, the same refusals of a restore, the same record of each
        deleted disk the moment it is deleted.

          - Only the disks the record names: -Set restore,
            Get-VmfRestoreEarlierDisks (retainedDiskId and each
            dataDisks[].previousDiskId of a restore with diskIdChanged);
            -Set rollback, Get-VmfRollbackOriginalDisks (rollbackOriginals). By resource id
            (Remove-VmfManagedDiskById), in the resource groups the product
            makes disks in for this machine (Get-VmfMadeDiskResourceGroups).
          - Each disk is read first (Get-VmfManagedDiskAttachment). A disk
            attached to any machine at that moment is skipped, and so is a
            disk the read does not answer for; the line says which and why.
          - A disk that is already gone counts as deleted (rule 4).
          - Each disk is recorded the moment it is deleted
            (Add-VmfRestoreEarlierDeleted, Add-VmfRollbackOriginalDeleted), so
            the panel's list empties, and a job that stops part way deletes
            only what is left when it is started again.
          - Refused, before Azure is asked, where a restore of the machine is
            refused (Get-VmfRestoreEarlierRefusal), and while another job
            holds the machine. It takes the machine's hold as a restore does
            (Enter-VmfMachineLease), so a restore, a finish or a wave cannot
            start on the machine while it runs.
          - -Set rollback also: refused while the move of the machine has not
            ended (Get-VmfMadeDiskDeleteRefusal, which asks the refusals of a
            restore too), and nothing is deleted of a machine Azure does not
            show, or that the read does not answer for
            (Get-VmfMachineAbsentReason): the original disks can be what
            rebuilds it.
        Nothing is deleted on its own: only a person's Delete these disks
        starts this.
    .PARAMETER Set
        restore (the default): the earlier disks of the last restore.
        rollback: the original disks rollbacks swapped off.
    .PARAMETER By
        Who asked for it, on the record of each disk and on the line.
    .PARAMETER CorrelationId
        The engine operation's id: the name the job holds the machine under.
    .EXAMPLE
        Remove-VmfRestoreEarlierDisks -RunPath .\run1 -VmId $vmId -By 'operator@contoso.com'
    .EXAMPLE
        Remove-VmfRestoreEarlierDisks -RunPath .\run1 -VmId $vmId -Set rollback -By 'operator@contoso.com'
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][ValidateSet('restore', 'rollback')][string]$Set = 'restore',
        [Parameter()][string]$By = 'unknown',
        [Parameter()][string]$CorrelationId
    )

    # VMID-CASE-1: the record and the hold are named from the id as the record spells it.
    $recorded = Resolve-VmfRecordedVmId -RunPath $RunPath -VmId $VmId
    $vmName = ($recorded -split '/')[-1]
    $rollback = $Set -eq 'rollback'
    # Which disks, and why not, for each set.
    $listOf = if ($rollback) { { param($d) @(Get-VmfRollbackOriginalDisks -Doc $d) } }
              else { { param($d) @(Get-VmfRestoreEarlierDisks -Restore (Get-VmfRecordField -Object $d -Name 'restore')) } }
    $refusalOf = if ($rollback) { { param($d) Get-VmfMadeDiskDeleteRefusal -Doc $d -VmName $vmName } }
                 else { { param($d) Get-VmfRestoreEarlierRefusal -Doc $d -VmName $vmName } }
    $noun = if ($rollback) { 'original disk' } else { 'earlier managed disk' }
    # The Activity line has its own step for each set, so its heading says which.
    $step = if ($rollback) { 'originalDelete' } else { 'earlierDelete' }
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $recorded
    if ($rollback) {
        if (-not $doc) { throw "This migration has no record of '$vmName', so it has no original disks to delete." }
    }
    elseif (-not (Get-VmfRecordField -Object $doc -Name 'restore')) { throw "'$vmName' has no restore, so it has no earlier managed disks to delete." }
    $refusal = & $refusalOf $doc
    if ($refusal) { throw $refusal }

    $result = { param($deleted, $skipped, $detail)
        [pscustomobject]@{ VmId = $recorded; Deleted = @($deleted); Skipped = @($skipped); Detail = $detail } }
    if (-not @(& $listOf $doc).Count) {
        $none = if ($rollback) { "'$vmName' has no original disks left to delete." } else { "The restore of '$vmName' has no earlier managed disks left to delete." }
        Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome ok -VmId $recorded -Detail $none
        return (& $result @() @() $none)
    }
    if (-not $PSCmdlet.ShouldProcess($vmName, $(if ($rollback) { 'delete the original disks that a rollback swapped off' } else { 'delete the earlier managed disks of its restore' }))) { return }

    $subscriptionId = Assert-VmfResourceId -ResourceId $recorded -Kind 'virtual machine'
    $previousAzContext = Use-VmfSubscriptionContext -SubscriptionId $subscriptionId
    $lease = $null
    try {
        $lease = Enter-VmfMachineLease -RunPath $RunPath -VmId $recorded -Holder (Get-VmfMachineLeaseHolder -Kind 'restore' -CorrelationId $CorrelationId)
        # Read again under the hold: the record the disks come from is the one
        # no other job can change now.
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $recorded
        $refusal = & $refusalOf $doc
        if ($refusal) { throw $refusal }
        $disks = @(& $listOf $doc)
        if ($rollback) {
            # The cleanup's rule (MADE-DISK-RECORD-1 review): a disk of a machine
            # Azure does not show can be what rebuilds it, and unknown never deletes.
            $absent = Get-VmfMachineAbsentReason -RunPath $RunPath -VmId $recorded
            if ($absent) {
                $kept = "The product did not delete the original disks of '$vmName': $(@($disks | ForEach-Object { [string]$_.name }) -join ', '). $absent The product does not delete a disk of a machine that Azure does not show. $By asked for it."
                Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome warn -VmId $recorded -Detail $kept -CorrelationId $CorrelationId
                return (& $result @() @($disks | ForEach-Object { [pscustomobject]@{ diskId = [string]$_.diskId; name = [string]$_.name; why = $absent } }) $kept)
            }
        }
        $restoreOp = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $doc -Name 'restore') -Name 'operationId')
        $groups = @(Get-VmfMadeDiskResourceGroups -StateDoc $doc -VmId $recorded)
        $deleted = [System.Collections.Generic.List[string]]::new()
        $gone = [System.Collections.Generic.List[string]]::new()
        $skipped = [System.Collections.Generic.List[object]]::new()
        foreach ($disk in $disks) {
            try { $read = Get-VmfManagedDiskAttachment -DiskId $disk.diskId }
            catch {
                $skipped.Add([pscustomobject]@{ diskId = $disk.diskId; name = $disk.name; why = "the product could not read it ($($_.Exception.Message))" })
                continue
            }
            if ($read.Exists -and [string]$read.ManagedBy) {
                $skipped.Add([pscustomobject]@{ diskId = $disk.diskId; name = $disk.name; why = "it is attached to the machine '$(([string]$read.ManagedBy -split '/')[-1])'" })
                continue
            }
            if ($read.Exists) {
                try { Remove-VmfManagedDiskById -DiskId $disk.diskId -MachineId $recorded -ResourceGroupNames $groups }
                catch {
                    $skipped.Add([pscustomobject]@{ diskId = $disk.diskId; name = $disk.name; why = "Azure did not delete it ($($_.Exception.Message))" })
                    continue
                }
            }
            else { $gone.Add($disk.name) }
            # The checkpoint of this disk (rule 4). A write that fails stops
            # the job; the next one reads the disk again, and gone counts.
            $entry = [pscustomobject]@{ diskId = $disk.diskId; deletedUtc = (Get-Date).ToUniversalTime().ToString('o'); deletedBy = $By; gone = (-not $read.Exists) }
            if ($rollback) { $null = Add-VmfRollbackOriginalDeleted -RunPath $RunPath -VmId $recorded -Entry $entry }
            else { $null = Add-VmfRestoreEarlierDeleted -RunPath $RunPath -VmId $recorded -RestoreOperationId $restoreOp -Entry $entry }
            $deleted.Add($disk.name)
        }

        $count = if ($deleted.Count -eq 1) { "1 $noun" } else { "$($deleted.Count) $($noun)s" }
        $words = [System.Collections.Generic.List[string]]::new()
        if ($deleted.Count) { $words.Add("The product deleted $count of '$vmName': $($deleted -join ', ').") }
        foreach ($name in $gone) { $words.Add("The product did not find $name in Azure, so it counts as deleted.") }
        foreach ($s in $skipped) { $words.Add("The product did not delete $($s.name): $($s.why).") }
        $words.Add("$By asked for it.")
        $detail = $words -join ' '
        Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome $(if ($skipped.Count) { 'warn' } else { 'ok' }) -VmId $recorded -Detail $detail -CorrelationId $CorrelationId
        & $result $deleted $skipped $detail
    }
    finally {
        Exit-VmfMachineLease -Token $lease
        Restore-VmfSubscriptionContext -Context $previousAzContext
    }
}
