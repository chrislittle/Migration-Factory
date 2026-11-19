# WAVE-2 lever 7 (ruled 2026-08-28): the default is 7 days, and it is enforced.
#
# keepSnapshotDays existed in the contract for weeks and nothing read it. A
# setting nothing enforces is worse than no setting: the acceptance screen
# tells a customer their safety copies are kept 7 days, and the truth was
# "forever, until someone notices the storage bill". This file is the pure
# half of making it true - which machines are eligible, and why - so the
# decision is unit-testable with no Azure anywhere near it.
#
# The direction of caution here is the opposite of most of the product: this
# code DELETES the last copy of a machine as it was before migration. So the
# rules are narrow on purpose:
#
#   * only a machine that reached MIGRATED. Anything parked, failed, or still
#     in flight keeps its copies no matter how old - those are exactly the
#     machines someone may still need to put back.
#   * the clock starts when the machine reached MIGRATED, not when the run
#     started and not when the snapshot was taken.
#   * the retention comes from that machine's OWN plan entry, because two
#     waves in one run may have accepted different answers.
#   * a machine whose copies were already deleted is never revisited.

function Get-VmfRetentionDays {
    <#
    .SYNOPSIS
        The keepSnapshotDays this machine's wave accepted, or the default.
    .OUTPUTS
        [int] days, or $null when the entry says something unusable - unknown
        must never read as "delete it".
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$PlanEntry)

    if ($PlanEntry -and $PlanEntry.policy -and $PlanEntry.policy.PSObject.Properties['keepSnapshotDays']) {
        $raw = $PlanEntry.policy.keepSnapshotDays
        $days = 0
        if ([int]::TryParse([string]$raw, [ref]$days) -and $days -ge 0) { return $days }
        return $null
    }
    [int](Get-VmfDefaultWavePolicy).keepSnapshotDays
}

function Get-VmfMigratedUtc {
    <#
    .SYNOPSIS
        When this machine reached MIGRATED, from its own history. $null if it
        never did.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter(Mandatory)]$StateDoc)

    if ([string]$StateDoc.state -ne 'MIGRATED') { return $null }
    $hit = @($StateDoc.history) | Where-Object { [string]$_.state -eq 'MIGRATED' } | Select-Object -Last 1
    if (-not $hit) { return $null }
    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string]$hit.tsUtc, [ref]$parsed)) { return $parsed.ToUniversalTime() }
    $null
}

function Get-VmfExpiredSafetyCopies {
    <#
    .SYNOPSIS
        Which machines' safety copies are past the retention their wave
        accepted. Pure: state documents and plan entries in, decisions out.
    .PARAMETER NowUtc
        Passed in rather than read, so the rule is testable at any age.
    .OUTPUTS
        One object per ELIGIBLE machine: VmId, SnapshotIds, MigratedUtc,
        AgeDays, KeepDays. Machines that are not eligible are simply absent -
        with one exception: KeepDays $null (an unreadable retention) is
        reported as a skip, because silently keeping is right but silently
        never telling anyone is how a setting rots again.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$StateDocs,
        [Parameter()][AllowNull()]$PlanEntries,
        [Parameter(Mandatory)][datetime]$NowUtc
    )

    $byId = @{}
    foreach ($e in @($PlanEntries)) { if ($e -and $e.vmId) { $byId[[string]$e.vmId] = $e } }

    $eligible = [System.Collections.Generic.List[object]]::new()
    $skipped  = [System.Collections.Generic.List[object]]::new()

    foreach ($doc in @($StateDocs)) {
        if (-not $doc) { continue }
        $vmId = [string]$doc.vmId

        # Already cleaned up - not an error, just nothing left to do.
        if ($doc.PSObject.Properties['retention'] -and $doc.retention -and $doc.retention.deletedUtc) { continue }

        # RESTORE-END-JOB-1: a restore that has not ended needs
        # the copies - its job resumes from them, and a machine whose
        # definition a rebuild deleted is rebuilt from them. Said, never
        # silent, like the unreadable setting below.
        # RESUME-GIVEUP-KEEP-1: and while the service gave up on one, until a
        # restore or a rebuild of the machine finishes.
        if (Test-VmfPutBackJobHolds -Doc $doc) {
            if (@(Get-VmfSafetyCopyIds -StateDoc $doc).Count) {
                $skipped.Add([pscustomobject]@{
                    VmId = $vmId
                    Reason = (Get-VmfPutBackHoldWhy -Doc $doc)
                })
            }
            continue
        }

        $ids = @(Get-VmfSafetyCopyIds -StateDoc $doc)
        if (-not $ids) { continue }

        $migrated = Get-VmfMigratedUtc -StateDoc $doc
        if (-not $migrated) { continue }   # not migrated: its copies are the point

        $keep = Get-VmfRetentionDays -PlanEntry $byId[$vmId]
        if ($null -eq $keep) {
            $skipped.Add([pscustomobject]@{
                VmId = $vmId
                Reason = 'this machine''s wave has an unreadable retention setting, so its safety copies were left alone'
            })
            continue
        }

        $age = ($NowUtc - $migrated).TotalDays
        if ($age -lt $keep) { continue }

        $eligible.Add([pscustomobject]@{
            VmId        = $vmId
            SnapshotIds = @($ids)
            MigratedUtc = $migrated.ToString('o')
            AgeDays     = [math]::Round($age, 1)
            KeepDays    = $keep
        })
    }

    @{ Eligible = @($eligible); Skipped = @($skipped) }
}

function Get-VmfSafetyCopyIds {
    <#
    .SYNOPSIS
        SAFETY-RETRY-1: every safety copy a machine's record points at - this
        attempt's, then the earlier attempts' (safety.earlierCopies). One rule
        for everything that finds them: retention, run deletion. SAFETY-ALL-1:
        the data disks' copies too.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()]$StateDoc)
    if (-not $StateDoc -or -not $StateDoc.PSObject.Properties['safety'] -or -not $StateDoc.safety) { return @() }
    $s = $StateDoc.safety
    $earlier = @(if ($s.PSObject.Properties['earlierCopies']) { @($s.earlierCopies) })
    @(foreach ($c in @($s) + $earlier) {
            foreach ($name in 'pristineSnapshotId', 'snapshotId') {
                if ($c -and $c.PSObject.Properties[$name] -and [string]$c.$name) { [string]$c.$name }
            }
            # SAFETY-ALL-1: every data disk's copy, this attempt's and an
            # earlier one's - both hold the same records.
            foreach ($name in 'pristineDataCopies', 'dataCopies') {
                if ($c -and $c.PSObject.Properties[$name]) { foreach ($d in @($c.$name)) { if ($d -and [string]$d.snapshotId) { [string]$d.snapshotId } } }
            }
        })
}

function Get-VmfRollbackDisksBeforeMoveEntries {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: every rollback disk that a
        machine's record names - this attempt's (safety.rollbackDisksBeforeMove), then
        the earlier attempts' (safety.earlierCopies[].rollbackDisksBeforeMove). The
        sibling of Get-VmfSafetyCopyIds, and the one reader for everything
        that finds these disks: the cleanup after a move, retention, run
        deletion. Pure.
    .OUTPUTS
        One object per disk: the recorded entry (lun, name, diskId, diskName,
        snapshotId, skuName, instantAccess, madeUtc, usedUtc, deletedUtc) with
        Attempt = 'current' or 'earlier'.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$StateDoc)
    if (-not $StateDoc -or -not $StateDoc.PSObject.Properties['safety'] -or -not $StateDoc.safety) { return @() }
    $s = $StateDoc.safety
    $holders = @(@([pscustomobject]@{ Attempt = 'current'; Holder = $s }) +
        @(@(if ($s.PSObject.Properties['earlierCopies']) { @($s.earlierCopies) }) | Where-Object { $_ } | ForEach-Object { [pscustomobject]@{ Attempt = 'earlier'; Holder = $_ } }))
    @(foreach ($h in $holders) {
            $rec = if ($h.Holder.PSObject.Properties['rollbackDisksBeforeMove']) { $h.Holder.rollbackDisksBeforeMove } else { $null }
            if (-not $rec -or -not $rec.PSObject.Properties['disks']) { continue }
            foreach ($d in @($rec.disks)) {
                if (-not $d -or -not [string]$d.diskId) { continue }
                $row = $d | Select-Object *
                $row | Add-Member -NotePropertyName Attempt -NotePropertyValue $h.Attempt -Force
                $row
            }
        })
}

# The states in which a machine's move has ENDED and its rollback is no longer
# the engine's: moved, put back, or never started. A machine that waits for a
# decision or needs attention keeps its rollback disks - a person
# may still put it back, and Restore this machine uses them.
$script:VmfRollbackDisksBeforeMoveDueStates = @('MIGRATED', 'FAILED_ROLLED_BACK', 'SKIPPED')

function Get-VmfDueRollbackDisksBeforeMove {
    <#
    .SYNOPSIS
        ROLLBACK-DISKS-FIRST-1: which rollback disks retention
        deletes now. Pure: state documents in, decisions out.
    .DESCRIPTION
        A disk a put-back used is the machine's own disk and is never listed;
        a disk already deleted is not listed again. Of the rest:
          - an earlier attempt's, always - a person's retry made new ones for
            the new copies (SAFETY-RETRY-1);
          - this attempt's, once the machine's move has ended (MIGRATED,
            FAILED_ROLLED_BACK, SKIPPED). A move that completes deletes them
            itself; this finds any that delete did not reach.
        No waiting days: these disks are not the safety copies. The copies
        keep the retention their wave accepted.
    .OUTPUTS
        One object per machine with something due: VmId, Disks.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$StateDocs)
    @(foreach ($doc in @($StateDocs | Where-Object { $_ })) {
            # RESTORE-END-JOB-1: a restore that has not ended may
            # use these disks when it resumes.
            if (Test-VmfPutBackJobHolds -Doc $doc) { continue }
            $ended = [string]$doc.state -in $script:VmfRollbackDisksBeforeMoveDueStates
            # SWAP-REFUSED-AFTER-STOP-1: a disk a refused swap left is the disk
            # Finish the rollback or Finish the restore puts on the machine.
            $waits = @(@(Get-VmfRecordField -Object (Get-VmfRecordField -Object $doc -Name 'swapPending') -Name 'swaps') |
                Where-Object { $_ } | ForEach-Object { [string]$_.diskId })
            $due = @(Get-VmfRollbackDisksBeforeMoveEntries -StateDoc $doc | Where-Object {
                    -not [string]$_.usedUtc -and -not [string]$_.deletedUtc -and ($_.Attempt -eq 'earlier' -or $ended) -and [string]$_.diskId -notin $waits })
            if ($due.Count) { [pscustomobject]@{ VmId = [string]$doc.vmId; Disks = $due } }
        })
}

function Get-VmfDueMadeDisks {
    <#
    .SYNOPSIS
        MADE-DISK-RECORD-1: which disks a put-back made from a copy (a
        rollback, Restore this machine, Rebuild this machine) retention
        deletes now. Pure: state documents in, decisions out.
    .DESCRIPTION
        The decision of 2026-10-23: an unused disk that a put-back made
        is deleted once the machine's move has ended (MIGRATED,
        FAILED_ROLLED_BACK, SKIPPED), on the schedule of the safety copies. A
        machine that waits for a decision or needs attention keeps them: a
        person may still put it back. Never listed:
          - a disk marked used or deleted;
          - a disk a refused swap still waits to put on the machine, or one it
            swapped (swapPending, SWAP-REFUSED-AFTER-STOP-1) - Finish uses it;
          - a disk the record says the machine runs on or ran on
            (Get-VmfRecordedMachineDiskIds).
        The caller reads each disk before it deletes it, and never deletes one
        attached to anything.
    .OUTPUTS
        One object per machine with something due: VmId, Disks (each with
        List, the list it is on).
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$StateDocs)
    @(foreach ($doc in @($StateDocs | Where-Object { $_ })) {
            if ([string]$doc.state -notin $script:VmfRollbackDisksBeforeMoveDueStates) { continue }
            # RESTORE-END-JOB-1: the disks a restore made before its
            # job stopped are the disks its resume uses.
            if (Test-VmfPutBackJobHolds -Doc $doc) { continue }
            $due = @(Get-VmfDeletableMadeDisks -StateDoc $doc)
            if ($due.Count) { [pscustomobject]@{ VmId = [string]$doc.vmId; Disks = $due } }
        })
}

function Get-VmfDeletableMadeDisks {
    <#
    .SYNOPSIS
        MADE-DISK-RUN-DELETE-1: the disks a put-back made from a copy that one
        machine's record says nothing uses - the one rule the daily cleanup
        (Get-VmfDueMadeDisks) and the delete of a migration
        (Test-VmfRunDiscardable) both ask. Pure.
    .DESCRIPTION
        Never listed:
          - a disk marked used or deleted;
          - a disk a refused swap still waits to put on the machine, or one it
            swapped (swapPending, SWAP-REFUSED-AFTER-STOP-1) - Finish uses it;
          - a disk the record says the machine runs on or ran on
            (Get-VmfRecordedMachineDiskIds).
        WHEN a listed disk may go is the caller's: the cleanup waits for the
        move to end, and a delete of the migration is the person's choice.
        Each caller reads every disk before it deletes it, and never deletes
        one attached to anything (Remove-VmfRollbackDisksBeforeMoveEntries).
    .OUTPUTS
        The entries (Get-VmfMadeDiskEntries), each with List.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter()][AllowNull()]$StateDoc)
    if (-not $StateDoc) { return @() }
    $pending = Get-VmfRecordField -Object $StateDoc -Name 'swapPending'
    $waits = @(@(@(Get-VmfRecordField -Object $pending -Name 'swaps') + @(Get-VmfRecordField -Object $pending -Name 'swapped')) |
        Where-Object { $_ } | ForEach-Object { [string](Get-VmfRecordField -Object $_ -Name 'diskId') } | Where-Object { $_ })
    $onRecord = @(Get-VmfRecordedMachineDiskIds -StateDoc $StateDoc)
    @(Get-VmfMadeDiskEntries -StateDoc $StateDoc | Where-Object {
            -not (Test-VmfMadeDiskMarked -Entry $_) -and [string]$_.diskId -notin $waits -and [string]$_.diskId -notin $onRecord })
}

function Get-VmfSafetyCopyTags {
    <#
    .SYNOPSIS
        FIND-COPY-1: the tags a safety copy carries, so it can be found after
        this product is gone.
    .DESCRIPTION
        A safety copy is a snapshot in the resource group of the machine it
        came from - never in this product's. Removing the product leaves every
        copy where it is, and takes away the two things that knew about them:
        the run store, which holds each machine's retention, and the daily pass
        that acts on it.

        What marked a copy before this was the LOCK's name, which disappears
        the moment somebody removes the lock, and the run id inside the
        resource name, which a machine name over 75 characters pushes off the
        end. Tags sit on the resource, survive both, and are what
        `az resource list --tag` searches.

        THERE IS NO EXPIRY DATE HERE, and that is not an omission. The clock
        starts when the machine reaches MIGRATED - see the top of this file -
        and the copy is taken BEFORE that. A date computed at this moment would
        be wrong by however long the migration takes, and a wrong date on a
        restore point is worse than none. The accepted number of days is a fact
        now, so that is what goes on.
    .OUTPUTS
        [hashtable] of tag name to value. Never $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$RunPath,
        [Parameter()][AllowNull()]$KeepDays,
        [Parameter()][AllowNull()]$TakenUtc
    )

    # 'true', not the install's name, so ONE literal command finds every copy
    # this product has ever taken in a subscription. The manual can print that
    # command with nothing to substitute, and it stays right for somebody who
    # installed twice.
    $tags = @{
        vmfSafetyCopy = 'true'
        vmfMachine    = $VmName
        vmfRun        = $RunId
    }

    # Which install took it, for a subscription that holds more than one.
    # azblob://<account>/<container>/<runId> - a local run path has no account,
    # and an absent tag is better than a made-up one.
    if ($RunPath -and $RunPath -match '^azblob://([^/]+)/') { $tags['vmfStore'] = $Matches[1] }

    # UNKNOWN IS NOT A NUMBER. Get-VmfRetentionDays returns $null when a wave's
    # setting is unusable, and the retention pass treats that as "leave it
    # alone". A tag saying 7 would contradict the code that decides.
    if ($null -ne $KeepDays) { $tags['vmfKeepDays'] = [string][int]$KeepDays }

    $when = if ($TakenUtc) { [datetime]$TakenUtc } else { (Get-Date).ToUniversalTime() }
    $tags['vmfTakenUtc'] = $when.ToUniversalTime().ToString('o')

    return $tags
}

function Set-VmfSafetyCopiesDeleted {
    <#
    .SYNOPSIS
        Record on a machine's state document that its safety copies are gone
        on purpose: when, which, by whom, and the retention days that
        deleted them ($null when no retention did - DISCARD-ENGINE-1, a
        migration deleted with its copies).
    .DESCRIPTION
        One write for both writers - the daily cleanup and the delete of a
        migration - so the page's copies card, a restore and the next delete
        read the same record. Present means EVERY copy of the machine is gone:
        Test-VmfRunDiscardable then counts none of them, so a caller must not
        write it while any copy of the machine may still exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SnapshotIds,
        [Parameter()][AllowNull()]$KeepDays,
        [Parameter(Mandatory)][string]$DeletedBy,
        [Parameter()][datetime]$AsOfUtc = [datetime]::UtcNow
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $doc | Add-Member -NotePropertyName retention -NotePropertyValue ([pscustomobject]@{
        deletedUtc         = $AsOfUtc.ToUniversalTime().ToString('o')
        keepDays           = $KeepDays
        deletedSnapshotIds = @($SnapshotIds)
        deletedBy          = $DeletedBy
    }) -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}