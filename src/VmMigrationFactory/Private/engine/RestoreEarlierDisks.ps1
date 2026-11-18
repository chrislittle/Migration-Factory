# RESTORE-EARLIER-DELETE-1 (approved design, 2026-10-25): the earlier
# managed disks of a restore that kept them, and the record of each one that
# Delete these disks deleted.
#
# A restore with new names (diskNaming new) makes a new managed disk from each
# snapshot and swaps it onto the machine; the disk the machine had stays in
# Azure, detached, and costs money. The restore's own record names each one:
# retainedDiskId for the operating system disk, and dataDisks[].previousDiskId
# for each data disk (RESTORE-ALL-1). Nothing else is ever deleted here.

function Get-VmfRestoreEarlierDisks {
    <#
    .SYNOPSIS
        The earlier managed disks of a restore that are not deleted yet. Pure.
    .DESCRIPTION
        ONE rule, twinned in the run page (restoreEarlierDisks, migrations.js),
        which lists them and counts them in the confirmation; both are held to
        tests/fixtures/restore-earlier-disks.json.
          - Only a restore with diskIdChanged: a restore that kept the names
            deleted the earlier disks itself.
          - The operating system disk: retainedDiskId. Each data disk:
            previousDiskId, when it is not the disk on that LUN now.
          - Never a disk the record says the machine runs on now (newDiskId
            of the restore or of any of its data disks), and never a disk on
            earlierDisksDeleted. Resource ids compare in any letter case
            (VMID-CASE-1: Azure gives one id in more than one case).
          - One disk named twice is listed once.
    .OUTPUTS
        @{ diskId; name; lun } in the order of the record - the operating
        system disk first (lun $null), then each data disk.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$Restore)
    if (-not $Restore -or -not [bool](Get-VmfRecordField -Object $Restore -Name 'diskIdChanged')) { return @() }
    $leaf = { param($id) ([string]$id -split '/')[-1] }
    $data = @(@(Get-VmfRecordField -Object $Restore -Name 'dataDisks') | Where-Object { $_ })
    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($id in @([string](Get-VmfRecordField -Object $Restore -Name 'newDiskId')) + @($data | ForEach-Object { [string](Get-VmfRecordField -Object $_ -Name 'newDiskId') })) {
        if ($id) { [void]$skip.Add($id) }
    }
    foreach ($row in @(@(Get-VmfRecordField -Object $Restore -Name 'earlierDisksDeleted') | Where-Object { $_ })) {
        $id = [string](Get-VmfRecordField -Object $row -Name 'diskId')
        if ($id) { [void]$skip.Add($id) }
    }
    $found = [System.Collections.Generic.List[object]]::new()
    $os = [string](Get-VmfRecordField -Object $Restore -Name 'retainedDiskId')
    if ($os -and $skip.Add($os)) {
        $name = [string](Get-VmfRecordField -Object $Restore -Name 'previousDiskName')
        $found.Add([pscustomobject][ordered]@{ diskId = $os; name = $(if ($name) { $name } else { & $leaf $os }); lun = $null })
    }
    foreach ($d in $data) {
        $id = [string](Get-VmfRecordField -Object $d -Name 'previousDiskId')
        if (-not $id -or -not $skip.Add($id)) { continue }
        $name = [string](Get-VmfRecordField -Object $d -Name 'previousDiskName')
        $found.Add([pscustomobject][ordered]@{ diskId = $id; name = $(if ($name) { $name } else { & $leaf $id }); lun = [int](Get-VmfRecordField -Object $d -Name 'lun') })
    }
    @($found)
}

function Get-VmfRestoreEarlierRefusal {
    <#
    .SYNOPSIS
        Why Delete these disks may not run on this machine now, or $null. Pure.
    .DESCRIPTION
        The refusals of a restore, in their own words: a restore or a finish
        that has not ended, or that stopped and needs a person
        (Get-VmfPutBackJobRefusal, Get-VmfPutBackHoldDeleteWords), and a
        refused swap that left the machine stopped (Get-VmfSwapPendingRefusal)
        - in each, the restore has not ended, so its record is not the last
        word on which disk the machine has. The machine's hold is asked by
        the caller (Enter-VmfMachineLease).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][string]$VmName
    )
    $job = Get-VmfPutBackJobRefusal -Doc $Doc -VmName $VmName
    if ($job) { return $job }
    $held = Get-VmfPutBackHoldDeleteWords -Doc $Doc
    if ($held) { return $held }
    Get-VmfSwapPendingRefusal -Doc $Doc -VmName $VmName
}

function Add-VmfRestoreEarlierDeleted {
    <#
    .SYNOPSIS
        Record one earlier disk the product deleted, on the restore that names
        it (restore.earlierDisksDeleted, vm-state v40), the moment it is
        deleted (rule 4).
    .DESCRIPTION
        Written only when the machine's record still holds the restore the
        job read (restore.operationId, -RestoreOperationId), and that restore
        names the disk as an earlier disk (Get-VmfRestoreEarlierDisks) - a
        later restore has its own earlier disks, and nothing is recorded on
        it. A disk already on the list adds nothing. A disk a put-back made is
        marked deleted on its own list in the same write
        (Set-VmfMadeDiskMarkOnDoc). A write that fails throws: the job stops,
        and the next one reads the disk again - gone counts as deleted.
    .OUTPUTS
        [bool] whether the record names the disk as deleted now.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowEmptyString()][string]$RestoreOperationId,
        [Parameter(Mandatory)]$Entry
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $restore = Get-VmfRecordField -Object $doc -Name 'restore'
    if (-not $restore) { return $false }
    if (-not [string]::Equals([string](Get-VmfRecordField -Object $restore -Name 'operationId'), $RestoreOperationId, [System.StringComparison]::Ordinal)) { return $false }
    $diskId = [string](Get-VmfRecordField -Object $Entry -Name 'diskId')
    $already = @(@(Get-VmfRecordField -Object $restore -Name 'earlierDisksDeleted') | Where-Object { $_ -and [string]$_.diskId -ieq $diskId })
    if ($already.Count) { return $true }
    if (-not @(Get-VmfRestoreEarlierDisks -Restore $restore | Where-Object { $_.diskId -ieq $diskId }).Count) { return $false }
    $row = [pscustomobject][ordered]@{
        diskId     = $diskId
        deletedUtc = [string](Get-VmfRecordField -Object $Entry -Name 'deletedUtc')
        deletedBy  = [string](Get-VmfRecordField -Object $Entry -Name 'deletedBy')
        gone       = [bool](Get-VmfRecordField -Object $Entry -Name 'gone')
    }
    $rows = @(@(Get-VmfRecordField -Object $restore -Name 'earlierDisksDeleted') | Where-Object { $_ }) + @($row)
    $restore | Add-Member -NotePropertyName earlierDisksDeleted -NotePropertyValue $rows -Force
    $null = Set-VmfMadeDiskMarkOnDoc -Doc $doc -DiskIds @($diskId) -Field 'deletedUtc'
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    $true
}
