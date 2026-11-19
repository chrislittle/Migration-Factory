# MADE-DISK-RECORD-1: the disks a put-back makes from a copy - a rollback
# (rollbackDisksDuringRollback) and Restore this machine (restoreDisks) - are on the machine's record the moment Azure makes
# them, and the daily cleanup deletes the ones nothing uses.
#
# Each list keeps the same entry: diskId, diskName, lun (null for the OS disk),
# madeUtc, and, once true, usedUtc (a put-back put it on a machine: it is the
# machine's own disk from then on, and nothing deletes it) or deletedUtc (it is
# gone). A marked entry is "off the list": no stop names it, and no cleanup asks
# for it. The entries stay, so a record still says what each put-back made -
# the pattern of the rollback disks (Set-VmfRollbackDisksBeforeMoveMark).
#
# Decided 2026-10-23: retention deletes an unused disk that a
# put-back made, once the machine's move has ended (Get-VmfDueMadeDisks) -
# reading each disk first, and NEVER deleting one that is attached, nor one a
# refused swap still waits to put on the machine (swapPending).

$script:VmfMadeDiskLists = @('rollbackDisksDuringRollback', 'restoreDisks')

function Add-VmfMadeDiskRecord {
    <#
    .SYNOPSIS
        Record a disk a put-back made from a copy, the moment Azure made it,
        on one of the two lists. A disk already on the list is not added
        again. Throws when the record cannot be written; each caller decides.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('rollbackDisksDuringRollback', 'restoreDisks')][string]$List,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter()][AllowNull()]$Lun
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if (-not $doc) { return }
    $have = @(if ($doc.PSObject.Properties[$List]) { @($doc.$List) | Where-Object { $_ } })
    if (@($have | Where-Object { [string]$_.diskId -eq $DiskId }).Count) { return }
    $entry = [ordered]@{ diskId = $DiskId; diskName = $DiskName; lun = $(if ($null -ne $Lun) { [int]$Lun } else { $null }); madeUtc = (Get-Date).ToUniversalTime().ToString('o') }
    $doc | Add-Member -NotePropertyName $List -NotePropertyValue @($have + @([pscustomobject]$entry)) -Force
    Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
}

function Add-VmfRestoreDiskRecord {
    <#
    .SYNOPSIS
        A disk Restore this machine made from a copy, on restoreDisks the
        moment Azure made it. Every disk a restore makes comes through
        New-VmfOsDiskFromCopy or New-VmfDataDiskFromCopy with an Azure call
        named 'restore:...', and they call this.
    .DESCRIPTION
        Never throws: a restore may be inside its stopped window, and a record
        that cannot be written must never leave the machine stopped. The disk
        is then named in the activity log, so it is never on no record at all.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter()][AllowNull()]$Lun
    )
    try { Add-VmfMadeDiskRecord -Context $Context -List 'restoreDisks' -DiskId $DiskId -DiskName $DiskName -Lun $Lun }
    catch {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'restore' -Outcome info -VmId $Context.VmId `
            -Detail "The restore made the disk '$DiskName' ($DiskId) from the safety copy. It is not on the record of this machine: $($_.Exception.Message)"
    }
}

function Get-VmfMadeDiskEntries {
    <#
    .SYNOPSIS
        Every disk a put-back made from a copy that a machine's record names,
        from the two lists, with List set to the list it is on. Pure.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$StateDoc)
    if (-not $StateDoc) { return @() }
    @(foreach ($list in $script:VmfMadeDiskLists) {
            foreach ($d in @(Get-VmfRecordField -Object $StateDoc -Name $list)) {
                if (-not $d -or -not [string]$d.diskId) { continue }
                $row = $d | Select-Object *
                $row | Add-Member -NotePropertyName List -NotePropertyValue $list -Force
                $row
            }
        })
}

function Test-VmfMadeDiskMarked {
    <# .SYNOPSIS A made-disk entry marked used or deleted: off the list. Pure. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Entry)
    [bool]([string](Get-VmfRecordField -Object $Entry -Name 'usedUtc') -or [string](Get-VmfRecordField -Object $Entry -Name 'deletedUtc'))
}

function Set-VmfMadeDiskMarkOnDoc {
    <#
    .SYNOPSIS
        Mark each entry of the two lists whose disk id is given, on a
        document in memory - for a caller that writes the document itself in
        the same write. A mark already there is kept.
    .OUTPUTS
        [bool] whether anything changed.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter()][AllowEmptyCollection()][string[]]$DiskIds = @(),
        [Parameter(Mandatory)][ValidateSet('usedUtc', 'deletedUtc')][string]$Field
    )
    $ids = @($DiskIds | Where-Object { $_ })
    if (-not $ids.Count) { return $false }
    $changed = $false
    foreach ($list in $script:VmfMadeDiskLists) {
        foreach ($d in @(Get-VmfRecordField -Object $Doc -Name $list)) {
            if (-not $d -or [string]$d.diskId -notin $ids -or [string](Get-VmfRecordField -Object $d -Name $Field)) { continue }
            $d | Add-Member -NotePropertyName $Field -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
            $changed = $true
        }
    }
    $changed
}

function Set-VmfMadeDiskMark {
    <#
    .SYNOPSIS
        Mark disks a put-back made as used or deleted, wherever they are on
        record. Never throws: it runs inside a put-back's stopped window and in
        the cleanup, and a mark that cannot be written is said as a warning -
        the cleanup reads each disk first and never deletes an attached one.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][AllowEmptyCollection()][string[]]$DiskIds = @(),
        [Parameter(Mandatory)][ValidateSet('usedUtc', 'deletedUtc')][string]$Field
    )
    if (-not @($DiskIds | Where-Object { $_ }).Count) { return }
    try {
        $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
        if (-not $doc) { return }
        if (Set-VmfMadeDiskMarkOnDoc -Doc $doc -DiskIds $DiskIds -Field $Field) { Write-VmfStateDoc -RunPath $RunPath -Document $doc }
    }
    catch { Write-Warning "The record of the disks made from the safety copies was not updated: $($_.Exception.Message)" }
}

function Get-VmfRecordedMachineDiskIds {
    <#
    .SYNOPSIS
        Every disk id the machine's record names as a disk the machine runs
        on or ran on: the capture, and the records of the last rollback and
        restore. Pure.
    .DESCRIPTION
        A disk a put-back made and then put on the machine is the machine's
        own, even when no mark says so - a put-back that stopped between its
        swap and its mark. So the
        cleanup never deletes a disk named here. Every field whose name ends
        in "id" or "ids" counts: one more id kept is never a disk lost.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()]$StateDoc)
    if (-not $StateDoc) { return @() }
    $found = [System.Collections.Generic.List[string]]::new()
    $walk = $null
    $walk = {
        param($node, [int]$depth)
        if ($null -eq $node -or $depth -gt 12) { return }
        if ($node -is [string] -or $node -is [ValueType]) { return }
        if ($node -is [System.Collections.IEnumerable] -and $node -isnot [System.Collections.IDictionary]) { foreach ($i in $node) { & $walk $i ($depth + 1) }; return }
        $props = if ($node -is [System.Collections.IDictionary]) { @($node.Keys | ForEach-Object { [pscustomobject]@{ Name = [string]$_; Value = $node[$_] } }) } else { @($node.PSObject.Properties) }
        foreach ($p in $props) {
            if ($p.Value -is [string]) {
                if ($p.Name -match '(?i)ids?$' -and $p.Value) { $found.Add([string]$p.Value) }
                continue
            }
            if ($p.Name -match '(?i)ids$' -and $p.Value -is [System.Collections.IEnumerable]) {
                foreach ($v in $p.Value) { if ($v -is [string] -and $v) { $found.Add($v) } }
                continue
            }
            & $walk $p.Value ($depth + 1)
        }
    }
    # ROLLBACK-ORIGINALS-LEFT-1: and the original disks a rollback swapped off -
    # the customer's disks, kept until a person deletes them.
    foreach ($name in 'captured', 'rollback', 'restore', 'rollbackOriginals') {
        & $walk (Get-VmfRecordField -Object $StateDoc -Name $name) 0
    }
    @($found | Select-Object -Unique)
}

function Get-VmfMadeDiskResourceGroups {
    <#
    .SYNOPSIS
        DISK-ID-SCOPE-1: the resource groups where the product makes disks for
        this machine - the cleanup deletes a disk in no other. Pure.
    .DESCRIPTION
        Every disk the product makes for a machine is in the resource group of
        the machine (the rollback disks, a rollback, and a
        restore with new names or its temporary disks), or in the
        resource group of the disk it replaces (a restore that keeps the
        names). So: the machine's own, and the resource group of each managed
        disk the record says the machine runs on or ran on
        (Get-VmfRecordedMachineDiskIds), in the machine's subscription. An id
        of another type, or a disk in another subscription, adds nothing.
    .OUTPUTS
        Resource group names, the machine's first.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowNull()]$StateDoc,
        [Parameter(Mandatory)][string]$VmId
    )
    $machineSub = Get-VmfSubscriptionId -ResourceId $VmId
    $found = [System.Collections.Generic.List[string]]::new()
    $found.Add([string](Get-VmfResourceGroupName -ResourceId $VmId))
    foreach ($id in @(Get-VmfRecordedMachineDiskIds -StateDoc $StateDoc)) {
        try { $sub = Assert-VmfManagedDiskId -DiskId ([string]$id) } catch { continue }
        if ($sub -ne $machineSub) { continue }
        $rg = [string](Get-VmfResourceGroupName -ResourceId ([string]$id))
        if ($rg -and $rg -notin $found) { $found.Add($rg) }
    }
    @($found | Where-Object { $_ })
}
function Get-VmfUnusedMadeDisks {
    <#
    .SYNOPSIS
        The disks on one list that an earlier put-back made from a copy and the
        machine does not run on by its record, not marked used or deleted: a
        put-back that stopped, or a process that died, after it made them.
        Pure.
    .OUTPUTS
        The entries, oldest first.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][ValidateSet('rollbackDisksDuringRollback', 'restoreDisks')][string]$List
    )
    $made = @(@(Get-VmfRecordField -Object $Doc -Name $List) | Where-Object { $_ -and [string]$_.diskId -and -not (Test-VmfMadeDiskMarked -Entry $_) })
    if (-not $made.Count) { return }
    $inUse = Get-VmfDisksInUseByRecord -Doc $Doc
    $ids = @(@([string]$inUse.Os.id) + @(@($inUse.Data) | ForEach-Object { [string]$_.id }) | Where-Object { $_ })
    @($made | Where-Object { [string]$_.diskId -notin $ids })
}

function Get-VmfMachineAbsentReason {
    <#
    .SYNOPSIS
        MADE-DISK-RECORD-1 review: $null when Azure says this machine exists;
        otherwise the sentence that says why the cleanup keeps its disks.
    .DESCRIPTION
        Asked by name (Test-VmfVmExists)
        under the machine's own subscription, as Restore-VmfVm addresses it
        (SEC-1). Fails closed: a machine Azure does not have, and a read that
        fails, both return a reason - only a definite yes returns $null.
        Restore-VmfSubscriptionContext puts the earlier context back.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $here = $false
    try {
        $sub = Assert-VmfResourceId -ResourceId $VmId -Kind 'virtual machine'
        $rg = ($VmId -split '/')[4]
        $vmName = ($VmId -split '/')[-1]
        $before = Use-VmfSubscriptionContext -SubscriptionId $sub
        try {
            $here = Invoke-VmfAzOperation -Name 'retention:machineExists' -RunPath $RunPath -VmId $VmId -Operation {
                Test-VmfVmExists -ResourceGroupName $rg -Name $vmName
            }
        }
        finally { Restore-VmfSubscriptionContext -Context $before }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return "The product could not read the machine in Azure: $(([string]$_.Exception.Message).TrimEnd('.'))."
    }
    if ($here -eq $true) { return $null }
    'Azure does not have the machine now.'
}

function Get-VmfMadeDiskDeleteRefusal {
    <#
    .SYNOPSIS
        MADE-DISK-DELETE-1: why Delete these disks now may not delete the
        disks a put-back made on this machine now, or $null. Pure.
    .DESCRIPTION
        The engine asks it before and under the machine's hold, and the
        service asks it before a job starts - one copy of the words.
          - A machine whose move has not ended (a working state of the
            engine): the wave owns it, and a rollback may use these disks.
          - Every refusal of Delete these disks under Its earlier managed
            disks (Get-VmfRestoreEarlierRefusal): a restore or a finish that
            has not ended, or that stopped and holds the disks (its resume or
            the next restore uses them), and a refused swap that left the
            machine stopped.
        The machine's hold is asked by the caller (Enter-VmfMachineLease).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][string]$VmName
    )
    $state = [string](Get-VmfRecordField -Object $Doc -Name 'state')
    if ($state -in @((Get-VmfEngineStates).Working)) {
        return "The move of '$VmName' has not ended: it is at the step $state. The product does not delete these disks until the move ends. A rollback can use them."
    }
    Get-VmfRestoreEarlierRefusal -Doc $Doc -VmName $VmName
}
