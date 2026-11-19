function Get-VmfDiskTypeUnknownStop {
    <#
    .SYNOPSIS
        DISK-TYPE-DEALLOCATED-1, at PRECHECK: stop the move, untouched, when
        the capture holds no disk type for a disk, or no size for a data disk.
        Pure: reads the capture and the read errors.
    .DESCRIPTION
        every rollback and restore makes each disk again from its safety copy, on the type
        the capture recorded, and Azure refuses a disk with no type ("Required
        property 'name' not found in 'sku'"). Every rebuild - Path B, its
        rollback, Restore this machine and Rebuild this machine - attaches each
        data disk with the size the capture recorded (the rebuild an earlier version made; REBUILD-REMOVE-ROLE-1 removed its create).
        MEASURED 2026-11-05: the model of a deallocated machine gives neither,
        so the capture reads them from the disk itself (Get-VmfVmCapture). A
        value that is still empty - a read Azure refused, or a disk that
        returned none - is asked about HERE, before the first safety copy
        stops the machine. Found in the lab, it stopped the move at the first
        rollback disk, after the machine had been started for
        its copies.
        -ReadErrors (review): what Azure said for each disk read that failed,
        by disk id, so the stop names the cause - a missing permission is not
        a missing value.
    .OUTPUTS
        $null, or the NEEDS_DECISION result (diskTypeNotKnown, untouched)
        naming each disk, what is missing, and what Azure said.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Capture, [Parameter()][AllowNull()][hashtable]$ReadErrors)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $why = {
        param($disk)
        $id = [string](& $f $disk 'managedDiskId')
        if ($ReadErrors -and $id -and $ReadErrors.ContainsKey($id)) { "Azure did not answer the read: $($ReadErrors[$id])" }
        else { 'Azure returned no value' }
    }
    $unknown = [System.Collections.Generic.List[string]]::new()
    $os = & $f $Capture 'osDisk'
    if ($os -and -not [string](& $f $os 'skuName')) { $unknown.Add("the OS disk '$([string](& $f $os 'name'))' has no disk type ($(& $why $os))") }
    foreach ($dd in @(& $f $Capture 'dataDisks')) {
        if (-not $dd) { continue }
        $missing = @()
        if (-not [string](& $f $dd 'skuName')) { $missing += 'no disk type' }
        if ([string](& $f $dd 'sizeGB') -eq '') { $missing += 'no size' }
        if ($missing.Count) { $unknown.Add("the data disk '$([string](& $f $dd 'name'))' on LUN $(& $f $dd 'lun') has $($missing -join ' and ') ($(& $why $dd))") }
    }
    if (-not $unknown.Count) { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'diskTypeNotKnown'; MachineState = 'untouched'
       Detail = "The product could not read a value that a rollback needs: $($unknown -join '; '). A rollback makes each disk again from its safety copy with its disk type. The product does not start a move that it cannot roll back fully. Nothing on the machine changed." }
}
