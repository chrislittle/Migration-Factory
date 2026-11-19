# IAC-REPORT-1: what changed on each machine that a definition in code holds.
#
# The customer's report had a "Terraform reconciliation" section for machines
# marked iacManaged. Nothing has written that mark since IAC-2 replaced the
# tag guess with an acknowledgement, so the section never showed. The owner
# chose a table for EVERY machine the product changed (2026-09-29): whether a
# customer defines machines in code is theirs to know, and the facts are the
# same either way.
#
# The facts are the ones Get-VmfIacStatement names - size, disk controller,
# accelerated networking, new disks, disk types - read from what the product
# RECORDED: the capture, the target the machine started on, the accelerated
# networking decision it saved, the disk type changes, and the rollback and
# restore records. A fact it did not record says so. OLD-REBUILD-RESTORE-READERS-1:
# no move deletes the machine resource, so the table has no column for it.
#
# PURE: reads the state documents and plan entries it is given.

$script:VmfDiskTypeWords = @{
    Standard_LRS = 'Standard HDD'; StandardSSD_LRS = 'Standard SSD'; StandardSSD_ZRS = 'Standard SSD (zone-redundant)'
    Premium_LRS = 'Premium SSD'; Premium_ZRS = 'Premium SSD (zone-redundant)'
}

function Test-VmfIacHas {
    # A property that is there and not null. A function, not a script block:
    # `& $block $a 'x' -and ...` passes -and to the block as an argument.
    param($Object, [string]$Name)
    [bool]($Object -and $Object.PSObject.Properties[$Name] -and $null -ne $Object.$Name)
}

function Get-VmfIacChangeRows {
    <#
    .SYNOPSIS
        One row for each machine the product changed: migrated, restored or
        rolled back.
    .OUTPUTS
        @{ name; size; controller; acceleratedNetworking; disks } -
        each a phrase for a report cell.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter()][object[]]$StateDocs = @()
    )
    $noChange = 'No change'
    $notRecorded = 'Not recorded'
    foreach ($doc in @($StateDocs | Where-Object { $_ })) {
        # FINISH-COUNT-1: where the move and a restore left the machine. A
        # data disk swap a restore left (swapPending) keeps the size and the
        # controller the restore gave it, so this asks the state alone.
        $outcome = Get-VmfMachineMoveOutcome -StateDoc $doc
        $restore = if (Test-VmfIacHas $doc 'restore') { $doc.restore } else { $null }
        $rollback = if (Test-VmfIacHas $doc 'rollback') { $doc.rollback } else { $null }
        # Changed by the product: moved, put back, or a record says a disk was
        # made again - whatever state it waits in now.
        if ($outcome -notin @('migrated', 'putBack', 'rolledBack') -and -not ($restore -or $rollback)) { continue }

        $captured = if (Test-VmfIacHas $doc 'captured') { $doc.captured } else { $null }
        # ROLLBACK-RETRY-CAPTURE-1: what a definition in code holds is the machine
        # as the FIRST capture found it; a retry may have captured it changed.
        # OLD-VERSION-READERS-REMOVE-4 review: a record this version cannot read
        # (Get-VmfPutBackCapture throws) shows only that machine as not
        # recorded - it never stops the report for every machine.
        $config = $null
        if (Test-VmfIacHas $captured 'vmConfig') {
            try { $config = Get-VmfPutBackCapture -Doc $doc }
            catch {
                [pscustomobject]@{ name = ([string]$doc.vmId -split '/')[-1]; size = $notRecorded; controller = $notRecorded
                    acceleratedNetworking = $notRecorded; disks = $notRecorded }
                continue
            }
        }
        $started = if (Test-VmfIacHas $captured 'startedTarget') { $captured.startedTarget } else { $null }
        $moved = $outcome -in @('migrated', 'putBack')

        # ---- size and controller: what it was, and what it is now ----
        # OLD-STATE-READERS-FINISH-1: from the record alone. PRECHECK writes
        # the capture and the move it started (captured.startedTarget) on
        # every machine it passes; the plan entry is never read in their place.
        $fromSize = if (Test-VmfIacHas $config 'size') { [string]$config.size } else { '' }
        $toSize = if (Test-VmfIacHas $started 'size') { [string]$started.size } else { '' }
        $fromController = if ((Test-VmfIacHas $config 'controller') -and [string]$config.controller) { [string]$config.controller } else { 'SCSI' }
        $toController = if ((Test-VmfIacHas $started 'controller') -and [string]$started.controller) { [string]$started.controller } else { $fromController }
        # ROLLBACK-SIZE-REFUSED-SERIES-1: a restore onto the target size of the
        # plan made that size the first capture's, so a rollback returns there.
        # What the definition held is the size kept beside it.
        $replacedSize = Get-VmfSizeReplaced -Doc $doc
        $backSize = $fromSize
        if ($replacedSize) { $fromSize = [string]$replacedSize.Original }
        # A rollback goes back to the size of the first capture (RETIRE-SCOPE-1)
        # - the restore's size, after a restore onto the target size.
        $endSize = if ($restore -and [string]$restore.sizeAfter) { [string]$restore.sizeAfter }
                   elseif ($moved -and -not ($restore -and [string]$restore.fromCopy -eq 'pristine')) { $toSize } else { $backSize }
        $endController = if ($moved -and -not ($restore -and [string]$restore.fromCopy -eq 'pristine')) { $toController } else { $fromController }
        $size = if (-not $fromSize -or -not $endSize) { $notRecorded } elseif ($endSize -eq $fromSize) { $noChange } else { "$fromSize to $endSize" }
        if ($replacedSize -and $size -ne $notRecorded) { $size = "$size. $(Get-VmfSizeReplacedWords -Replaced $replacedSize)" }
        $controller = if ($endController -eq $fromController) { $noChange } else { "$fromController to $endController" }

        # ---- accelerated networking: the changes the move made, by the
        # decision it saved (AN-KEEP-1) and the rule that made them (NIC-1).
        # A put-back sets them back (ROLLBACK-AN-1).
        $an = $noChange
        if ($moved -and -not ($restore -and [string]$restore.fromCopy -eq 'pristine')) {
            $nics = if (Test-VmfIacHas $config 'nics') { @($config.nics) } else { @() }
            $decided = (Test-VmfIacHas $captured 'acceleratedNetworking') -and [string]$captured.acceleratedNetworking.policy
            # OLD-STATE-READERS-FINISH-1: only the decision the move saved
            # (GUEST_PREP saves it on every move). A record with none is not
            # recorded, and the plan entry is never read in its place.
            if (-not $nics.Count -or -not $decided) { $an = $notRecorded }
            else {
                $policy = [string]$captured.acceleratedNetworking.policy
                $primary = Get-VmfPrimaryNic -Nics $nics
                if ($policy -eq 'ensureOn' -and $null -eq $primary.acceleratedNetworking) { $an = $notRecorded }
                else {
                    $changes = @(Get-VmfNicAnPlan -CapturedNics $nics -Policy $policy)
                    if ($changes.Count -eq 1 -and $changes[0].enabled) { $an = 'On for the primary network interface' }
                }
            }
        }

        # ---- disks: new ones by name, and type changes still in place
        $disks = [System.Collections.Generic.List[string]]::new()
        if ($restore -and [string]$restore.newDiskName) {
            $disks.Add($(if ($restore.diskIdChanged) { "New OS disk: $([string]$restore.newDiskName)" } else { "New OS disk, with the same name: $([string]$restore.newDiskName)" }))
            # RESTORE-ALL-1 (v14): the data disks it replaced.
            if (Test-VmfIacHas $restore 'dataDisks') {
                foreach ($d in @($restore.dataDisks | Where-Object { $_ })) {
                    $disks.Add($(if ([string]$restore.diskNaming -eq 'preserve') { "New data disk on LUN $($d.lun), with the same name: $([string]$d.newDiskName)" } else { "New data disk on LUN $($d.lun): $([string]$d.newDiskName)" }))
                }
            }
        }
        elseif ($rollback) {
            if (Test-VmfIacHas $rollback 'osDisk') { $disks.Add("New OS disk: $([string]$rollback.osDisk.name)") }
            foreach ($d in @($rollback.dataDisks | Where-Object { $_ })) { $disks.Add("New data disk on LUN $($d.lun): $([string]$d.diskName)") }
        }
        if (Test-VmfIacHas $doc 'diskTypeChanges') {
            # Only a disk the machine still uses: one made again from a copy
            # replaced it, on the type the capture recorded.
            $replaced = @()
            if ($config) {
                $osId = if (Test-VmfIacHas $config.osDisk 'managedDiskId') { [string]$config.osDisk.managedDiskId } else { '' }
                # A restore from the SECOND copy makes its disks on the type
                # the move gave them, so that change is still what the
                # definition must hold; only the first copy puts the old type back.
                $firstCopy = $restore -and [string]$restore.fromCopy -eq 'pristine'
                if (($rollback -and (Test-VmfIacHas $rollback 'osDisk')) -or ($firstCopy -and [string]$restore.newDiskName)) { $replaced += $osId }
                $restoreLuns = if ($firstCopy -and (Test-VmfIacHas $restore 'dataDisks')) { @($restore.dataDisks | Where-Object { $_ } | ForEach-Object { [int]$_.lun }) } else { @() }
                if ($restoreLuns.Count) {
                    $replaced += @(@($config.dataDisks) | Where-Object { $_ -and [int]$_.lun -in $restoreLuns } | ForEach-Object { [string]$_.managedDiskId })
                }
                if ($rollback) {
                    $luns = @($rollback.dataDisks | Where-Object { $_ } | ForEach-Object { [int]$_.lun })
                    $replaced += @(@($config.dataDisks) | Where-Object { $_ -and [int]$_.lun -in $luns } | ForEach-Object { [string]$_.managedDiskId })
                }
            }
            foreach ($group in @($doc.diskTypeChanges | Where-Object { $_ } | Group-Object { [string]$_.diskId })) {
                $last = @($group.Group)[-1]
                if ([string]$last.by -ne 'move' -or $group.Name -in $replaced) { continue }
                $word = { param($s) if ($script:VmfDiskTypeWords.ContainsKey([string]$s)) { $script:VmfDiskTypeWords[[string]$s] } else { [string]$s } }
                $disks.Add("$(($group.Name -split '/')[-1]): $(& $word $last.from) to $(& $word $last.to)")
            }
        }

        [pscustomobject]@{
            name = ([string]$doc.vmId -split '/')[-1]; size = $size; controller = $controller
            acceleratedNetworking = $an
            disks = $(if ($disks.Count) { $disks -join '; ' } else { $noChange })
        }
    }
}
