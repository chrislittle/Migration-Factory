# DISCARD-ENGINE-1 (GitHub issue 427): delete the safety copies of a migration
# that is being deleted, and say exactly which ones could not be.
#
# This runs in the ENGINE. The service loads no Az module (FACADE-SIGNIN-COLD-1)
# and holds no right to delete anything in a customer's subscription; when it called this
# path in process, the first lock removal failed with "Remove-AzResourceLock is
# not recognized". tests/unit/FacadeAzModules.Tests.ps1 now fails if the
# service can reach it again.

function Invoke-VmfSafetyCopyDelete {
    <#
    .SYNOPSIS
        COPY-DELETE-LOCK-RACE-1: delete one safety copy whose lock the product
        has just removed, and take Azure's ScopeLocked answer as temporary for
        a fixed number of tries.
    .DESCRIPTION
        THE ONE PLACE a copy is deleted after its unlock - Delete the copies as
        well (Remove-VmfRunSafetyCopies) and the daily retention cleanup
        (Remove-VmfExpiredSafetyCopies) both call it.

        MEASURED on the lab install, 2026-11-14: Azure can still apply a lock
        for a moment after it stops listing it, and answers the delete with HTTP
        409 ScopeLocked. Invoke-VmfAzOperation does not try a 409 again, so the
        answer is marked (vmfLockLag) and tried again with its backoff. A lock
        that stays - a lock on the resource group, say - still ends the delete
        after -MaxAttempts tries, with Azure's words. Any other answer is not
        marked, so a refused permission is not tried again.

        Each Azure call line carries the copy's id (snapshotId), so the
        Activity list never takes one copy's line for another's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter()][string]$RunPath,
        [Parameter()][string]$VmId,
        [Parameter()][ValidateRange(1, 20)][int]$MaxAttempts = 6,
        [Parameter()][ValidateRange(0, 60000)][int]$BaseDelayMs = 2000
    )
    Invoke-VmfAzOperation -Name 'removeSnapshot' -RunPath $RunPath -VmId $VmId -MaxAttempts $MaxAttempts -BaseDelayMs $BaseDelayMs `
        -EventData @{ snapshotId = $SnapshotId } -Operation {
        try { Remove-VmfSnapshot -SnapshotId $SnapshotId }
        catch {
            if ("$_" -match '\bScopeLocked\b' -and $_.Exception.Data) { $_.Exception.Data['vmfLockLag'] = $true }
            throw
        }
    } | Out-Null
}

function Invoke-VmfSafetyCopyUnlock {
    <#
    .SYNOPSIS
        COPY-DELETE-LOCK-RACE-1: remove the product's lock from one safety copy
        and return only when Azure no longer lists it (Unlock-VmfSnapshot reads
        it back -ConfirmReads times, -ConfirmDelaySec apart).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter()][string]$RunPath,
        [Parameter()][string]$VmId,
        [Parameter()][int]$ConfirmReads = 6,
        [Parameter()][int]$ConfirmDelaySec = 10
    )
    Invoke-VmfAzOperation -Name 'unlockSnapshot' -RunPath $RunPath -VmId $VmId -EventData @{ snapshotId = $SnapshotId } -Operation {
        Unlock-VmfSnapshot -SnapshotId $SnapshotId -ConfirmReads ([math]::Max(1, $ConfirmReads)) -ConfirmDelaySec ([math]::Max(0, $ConfirmDelaySec))
    } | Out-Null
}

function Remove-VmfRunSafetyCopies {
    <#
    .SYNOPSIS
        Delete each safety copy: unlock it, delete it, and confirm Azure no
        longer has it. Returns what was deleted, what was already gone and
        what failed, with Azure's reason.
    .DESCRIPTION
        Every copy is tried, even after one fails - a person deciding what to
        do next needs the whole list, not the first refusal.

        Safe to run again. A copy Azure no longer has is counted as already
        gone and not touched, because a second try after a part-failed delete
        is the normal way to arrive here.

        A delete Azure accepts is NOT proof the copy is gone: the snapshot
        delete is asynchronous (202), and a copy that is still there after the
        delete would be a copy nothing in the product knows about once the run
        is removed. So each one is read again until it is gone, or counted as
        failed.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$SnapshotIds,
        # How often, and how far apart, a deleted copy is read again. Six
        # reads ten seconds apart covers the snapshot deletes measured so far.
        [Parameter()][int]$ConfirmReads = 6,
        [Parameter()][int]$ConfirmDelaySec = 10,
        # S5: whose copy each one is (snapshot id -> machine name) and the run,
        # for the note on a lock that goes back.
        [Parameter()][hashtable]$Owners = @{},
        [Parameter()][string]$RunId,
        # RETENTION-LOCK-PUTBACK-1: the daily retention cleanup deletes its
        # copies through this same code, so a refused delete gets its lock back
        # there too. It writes its lines under its own step and machine.
        [Parameter()][ValidateSet('discardCopy', 'retention')][string]$Step = 'discardCopy',
        [Parameter()][string]$VmId
    )

    $deleted = [System.Collections.Generic.List[string]]::new()
    $alreadyGone = [System.Collections.Generic.List[string]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()

    foreach ($snapId in @($SnapshotIds | Where-Object { $_ } | Select-Object -Unique)) {
        $name = ([string]$snapId -split '/')[-1]
        $unlocked = $false
        $deleteAccepted = $false
        try {
            $there = Invoke-VmfAzOperation -Name 'readSnapshot' -RunPath $RunPath -VmId $VmId -EventData @{ snapshotId = $snapId } -Operation {
                Test-VmfSnapshotExists -SnapshotId $snapId
            }
            if (-not $there) { $alreadyGone.Add($snapId); continue }

            # Review 2 note c: said BEFORE the lock comes off. A container
            # stopped between the unlock and the delete leaves the copy
            # unlocked, and this line is then the only thing that says so.
            # STEP-LOG-2: so it stays a throwing write. A line that cannot be
            # written goes to the catch below, and the copy keeps its lock.
            Write-VmfEvent -RunPath $RunPath -Step $Step -VmId $VmId -Outcome info `
                -Detail "The product removes the lock from the safety copy $name. Then it deletes the copy. If no later line names this copy, the copy can be in Azure with no lock." -Data @{ snapshotId = $snapId }
            # SAFETY-3's lock comes off first, as retention does it: a locked
            # copy, the default, refuses the delete.
            # COPY-DELETE-LOCK-RACE-1: marked before the call. An unlock that
            # Azure accepted but still lists ends here with a throw, and the
            # catch puts the lock back (Lock-VmfSnapshot keeps one lock).
            $unlocked = $true
            Invoke-VmfSafetyCopyUnlock -SnapshotId $snapId -RunPath $RunPath -VmId $VmId -ConfirmReads $ConfirmReads -ConfirmDelaySec $ConfirmDelaySec
            Invoke-VmfSafetyCopyDelete -SnapshotId $snapId -RunPath $RunPath -VmId $VmId
            $deleteAccepted = $true

            $gone = $false
            for ($i = 1; $i -le $ConfirmReads; $i++) {
                $still = Invoke-VmfAzOperation -Name 'readSnapshot' -RunPath $RunPath -VmId $VmId -EventData @{ snapshotId = $snapId } -Operation {
                    Test-VmfSnapshotExists -SnapshotId $snapId
                }
                if (-not $still) { $gone = $true; break }
                if ($i -lt $ConfirmReads) { Start-Sleep -Seconds $ConfirmDelaySec }
            }
            if (-not $gone) {
                throw "Azure accepted the delete, but the copy is still there after $($ConfirmReads * $ConfirmDelaySec) seconds."
            }
            $deleted.Add($snapId)
        }
        catch {
            $why = $_.Exception.Message
            # S5: the product's own lock came off for a delete that did not
            # happen. Put it back, with the same note the copy got when it was
            # taken, and say whether it is back: an unlocked copy is one any
            # Contributor or script can delete.
            $lockSaid = ''
            if ($unlocked -and -not $deleteAccepted) {
                try {
                    $owner = if ($Owners.ContainsKey($snapId)) { [string]$Owners[$snapId] } else { 'a machine of this migration' }
                    $notes = Get-VmfSafetyCopyLockNotes -VmName $owner -RunId $(if ($RunId) { $RunId } else { 'unknown' })
                    Invoke-VmfAzOperation -Name 'lockSnapshot' -RunPath $RunPath -VmId $VmId -EventData @{ snapshotId = $snapId } -Operation {
                        Lock-VmfSnapshot -SnapshotId $snapId -Notes $notes
                    } | Out-Null
                    $lockSaid = ' The product put the lock back on the copy.'
                }
                catch { $lockSaid = " The copy has no lock. The product could not put the lock back: $($_.Exception.Message)" }
            }
            elseif ($unlocked) { $lockSaid = ' Azure accepted the delete. The product did not put the lock back.' }
            # STEP-LOG-2 review: and whether its lock is back, which must survive a
            # lost line - an unlocked copy is one anybody can delete.
            $failed.Add([pscustomobject]@{ SnapshotId = $snapId; Name = $name; Reason = "$why$lockSaid" })
            # Review 2 item 1: its own step. A 'discard' failure ENDS the delete
            # on the page and in the service, and the engine goes on with the
            # other copies after this - so a restore allowed now could read a
            # copy the engine then deletes.
            # STEP-LOG-2: copies before this one may be deleted. A line that
            # could not be written left this function, so the other copies
            # were never tried and the delete lost its list of what it did.
            Write-VmfStepLine -RunPath $RunPath -Step $Step -VmId $VmId -Outcome fail `
                -Detail "The product did not delete the safety copy ${name}: $why$lockSaid" -Data @{ snapshotId = $snapId }
        }
    }

    [pscustomobject]@{
        Deleted     = @($deleted)
        AlreadyGone = @($alreadyGone)
        Failed      = @($failed)
    }
}

function Get-VmfOpenDiscard {
    <#
    .SYNOPSIS
        DISCARD-ENGINE-1 S2: the 'discard' start line that nothing has ended
        yet, or nothing. A start is ended by a 'discard' or 'engine:discard'
        failure or refusal - the same rule as the page's discardIndex.
    .DESCRIPTION
        THE ONE COPY OF THIS RULE IN POWERSHELL. The service asked it as
        Get-VmfFacadeOpenDiscard; RECORD-DELETE-1 needs it in the engine too
        (a delete that stopped after it kept its record must not refuse every
        download for ever), so it moved here and the service asks it here.
        Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Events)
    $open = $null
    foreach ($e in @($Events)) {
        if (-not $e) { continue }
        if ($e.step -eq 'discard' -and $e.outcome -eq 'start') { $open = $e; continue }
        if ($e.step -in @('discard', 'engine:discard') -and $e.outcome -in @('fail', 'refused')) { $open = $null }
    }
    $open
}