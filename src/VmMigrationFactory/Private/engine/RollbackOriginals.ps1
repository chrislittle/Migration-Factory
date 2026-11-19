# ROLLBACK-ORIGINALS-LEFT-1 (in 1.0 since 2026-11-08): the disks a
# rollback swapped off the machine - the disks it had before the migration.
#
# A rollback does not put them back: it puts the machine on new disks made from
# the first safety copy (the rollback disks, or disks it makes
# then), so these stay in Azure, detached, and each costs money. They are the
# customer's disks: nothing deletes them on its own (the daily cleanup counts
# them as disks of the machine, Get-VmfRecordedMachineDiskIds), and a person
# deletes them with Delete these disks on the machine's panel - the engine
# operation that deletes the earlier disks of a restore
# (Remove-VmfRestoreEarlierDisks -Set rollback).
#
# The record is rollbackOriginals (vm-state v41): diskId, diskName, lun (null
# for the operating system disk), detachedUtc, and once deleted deletedUtc,
# deletedBy and gone. It is not part of an attempt: Try this machine again
# keeps it, and a later rollback adds to it.

function Get-VmfRollbackCapturedDisk {
    <#
    .SYNOPSIS
        The disk a capture names at one place - the OS disk ($null LUN) or a
        data disk LUN - as @{ diskId; diskName }, or $null. Pure.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Capture,
        [Parameter()][AllowNull()]$Lun
    )
    if (-not $Capture) { return $null }
    $d = if ($null -eq $Lun) { Get-VmfRecordField -Object $Capture -Name 'osDisk' }
         else { @(@(Get-VmfRecordField -Object $Capture -Name 'dataDisks') | Where-Object { $_ -and [int](Get-VmfRecordField -Object $_ -Name 'lun') -eq [int]$Lun }) | Select-Object -First 1 }
    $id = [string](Get-VmfRecordField -Object $d -Name 'managedDiskId')
    if (-not $id) { return $null }
    $name = [string](Get-VmfRecordField -Object $d -Name 'name')
    @{ diskId = $id; diskName = $(if ($name) { $name } else { ($id -split '/')[-1] }) }
}

function Get-VmfRollbackOriginalEntries {
    <#
    .SYNOPSIS
        Every entry of the record of the disks rollbacks swapped off, deleted
        ones too. Pure.
    .DESCRIPTION
        The record is rollbackOriginals. OLD-STATE-READERS-PAGE-1: every
        writer of the rollback record (Set-VmfRollbackRecord,
        Add-VmfSwapFinished) writes it in the same write, through
        Add-VmfRollbackOriginalsOnDoc, so a document with no such field has
        no entry - nothing comes from the captures.
    .OUTPUTS
        [pscustomobject] entries with diskId, diskName, lun, detachedUtc, and
        deletedUtc, deletedBy and gone when the record has them.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$Doc)
    if (-not $Doc -or -not $Doc.PSObject.Properties['rollbackOriginals']) { return @() }
    @(@($Doc.rollbackOriginals) | Where-Object { $_ -and [string](Get-VmfRecordField -Object $_ -Name 'diskId') })
}

function Get-VmfRollbackOriginalDisks {
    <#
    .SYNOPSIS
        The original disks a rollback left that are not deleted: the list on
        the machine's panel, and what Delete these disks deletes. Pure.
    .DESCRIPTION
        ONE rule, twinned in the run page (rollbackOriginalDisks,
        migrations.js); both are held to tests/fixtures/rollback-originals.json.
        From Get-VmfRollbackOriginalEntries, in the order of the record. Never:
          - a disk marked deleted;
          - a disk the record says the machine uses now
            (Get-VmfDisksInUseByRecord);
          - an earlier disk of a restore (retainedDiskId, a
            dataDisks[].previousDiskId): the restore's part lists it, and its
            own delete deletes it;
          - one disk twice.
        Resource ids compare in any letter case (VMID-CASE-1).
    .OUTPUTS
        @{ diskId; name; lun; detachedUtc }.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$Doc)
    $entries = @(Get-VmfRollbackOriginalEntries -Doc $Doc)
    if (-not $entries.Count) { return @() }
    $skip = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $inUse = Get-VmfDisksInUseByRecord -Doc $Doc
    foreach ($id in @(@([string]$inUse.Os.id) + @(@($inUse.Data) | ForEach-Object { [string]$_.id }))) { if ($id) { [void]$skip.Add($id) } }
    $rs = Get-VmfRecordField -Object $Doc -Name 'restore'
    if ($rs) {
        foreach ($id in @(@([string](Get-VmfRecordField -Object $rs -Name 'retainedDiskId')) + @(@(Get-VmfRecordField -Object $rs -Name 'dataDisks') | Where-Object { $_ } | ForEach-Object { [string](Get-VmfRecordField -Object $_ -Name 'previousDiskId') }))) {
            if ($id) { [void]$skip.Add($id) }
        }
    }
    @(foreach ($e in $entries) {
            if ([string](Get-VmfRecordField -Object $e -Name 'deletedUtc')) { continue }
            $id = [string]$e.diskId
            if (-not $skip.Add($id)) { continue }
            $name = [string](Get-VmfRecordField -Object $e -Name 'diskName')
            $lun = Get-VmfRecordField -Object $e -Name 'lun'
            [pscustomobject][ordered]@{ diskId = $id; name = $(if ($name) { $name } else { ($id -split '/')[-1] })
                lun = $(if ($null -ne $lun) { [int]$lun } else { $null }); detachedUtc = (Get-VmfRecordField -Object $e -Name 'detachedUtc') }
        })
}

function Add-VmfRollbackOriginalsOnDoc {
    <#
    .SYNOPSIS
        On a document in memory, before the rollback's record of the disks it
        put on is written: record each disk those swaps took off the machine.
    .DESCRIPTION
        The disk swapped off at a place is the one this attempt's capture
        (captured.vmConfig) names there - the disk the machine had when the
        move started; a rollback never changes the capture, so a resume finds
        the same one. A place whose disk is the new one (no swap) adds
        nothing. A disk already on the record keeps its entry and its time
        (rule 4: a rollback run again records nothing twice). The caller
        writes the document, in the same write as the disks put on - after
        each swap (Set-VmfRollbackRecord, Add-VmfSwapFinished).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter()][AllowNull()]$OsDisk,
        [Parameter()][AllowEmptyCollection()][object[]]$DataDisks = @()
    )
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @(Get-VmfRollbackOriginalEntries -Doc $Doc)) { $entries.Add($e) }
    $have = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $entries) { [void]$have.Add([string]$e.diskId) }
    $capture = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'vmConfig'
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $swaps = [System.Collections.Generic.List[object]]::new()
    if ($OsDisk -and [string](Get-VmfRecordField -Object $OsDisk -Name 'id')) { $swaps.Add(@{ lun = $null; newId = [string](Get-VmfRecordField -Object $OsDisk -Name 'id') }) }
    foreach ($d in @($DataDisks | Where-Object { $_ })) {
        $newId = [string](Get-VmfRecordField -Object $d -Name 'diskId')
        if ($newId) { $swaps.Add(@{ lun = [int](Get-VmfRecordField -Object $d -Name 'lun'); newId = $newId }) }
    }
    foreach ($s in $swaps) {
        $was = Get-VmfRollbackCapturedDisk -Capture $capture -Lun $s.lun
        if (-not $was -or [string]::Equals($was.diskId, $s.newId, [System.StringComparison]::OrdinalIgnoreCase) -or -not $have.Add($was.diskId)) { continue }
        $entries.Add([pscustomobject][ordered]@{ diskId = $was.diskId; diskName = $was.diskName; lun = $s.lun; detachedUtc = $now })
    }
    $Doc | Add-Member -NotePropertyName rollbackOriginals -NotePropertyValue @($entries) -Force
}

function Add-VmfRollbackOriginalDeleted {
    <#
    .SYNOPSIS
        Record one original disk the product deleted, on its entry of
        rollbackOriginals (vm-state v41), the moment it is deleted (rule 4).
    .DESCRIPTION
        Only for a disk the record names (Get-VmfRollbackOriginalEntries). A
        disk already marked keeps its mark. A disk a put-back made is
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
        [Parameter(Mandatory)]$Entry
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { return $false }
    $diskId = [string](Get-VmfRecordField -Object $Entry -Name 'diskId')
    $entries = @(Get-VmfRollbackOriginalEntries -Doc $doc)
    $row = @($entries | Where-Object { [string]$_.diskId -ieq $diskId }) | Select-Object -First 1
    if (-not $row) { return $false }
    if ([string](Get-VmfRecordField -Object $row -Name 'deletedUtc')) { return $true }
    $row | Add-Member -NotePropertyName deletedUtc -NotePropertyValue (Get-VmfRecordField -Object $Entry -Name 'deletedUtc') -Force
    $row | Add-Member -NotePropertyName deletedBy -NotePropertyValue ([string](Get-VmfRecordField -Object $Entry -Name 'deletedBy')) -Force
    $row | Add-Member -NotePropertyName gone -NotePropertyValue ([bool](Get-VmfRecordField -Object $Entry -Name 'gone')) -Force
    $doc | Add-Member -NotePropertyName rollbackOriginals -NotePropertyValue @($entries) -Force
    $null = Set-VmfMadeDiskMarkOnDoc -Doc $doc -DiskIds @([string]$row.diskId) -Field 'deletedUtc'
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    $true
}
