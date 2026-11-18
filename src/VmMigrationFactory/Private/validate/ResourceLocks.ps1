# LOCK-1: a resource lock must be found BEFORE the machine is touched.
#
# Found while building RETRY-1: nothing anywhere looked for locks. A lock that
# refuses a change of the move stops it THERE - inside the deallocated window,
# past the point of no return - when it could have been a free stop at PRECHECK
# with "remove the lock, try again".
#
# The judgement is not "any lock stops the run". Lock TYPE has to be weighed
# against what the move does, or this becomes a check that refuses machines it
# has no reason to refuse:
#
#   ReadOnly       blocks every write - deallocate, resize, disk patch, disk
#                  swap. Nothing the product does is possible. Blocks the move.
#   CanNotDelete   blocks deletes only. Every move is in place: it resizes the
#                  machine, and its rollback swaps disks made from the copies.
#                  The move does not stop for it, so it is said as an info
#                  line. It is NOT harmless everywhere: the deletes of the
#                  unused rollback disks, and of Restore this machine,
#                  are refused under it (CANNOTDELETE-RESTORE-1): the line
#                  says so for a lock on the resource group, and Restore this
#                  machine reads the locks before it changes anything.
#
# REBUILD-REMOVE-LEFTOVERS-1: a CanNotDelete lock stopped a path other than A,
# because the removed rebuild deleted the machine definition. Every move is
# Path A now, so the verdict no longer takes a path.
#
# The reading is split from the judging on purpose: the verdict is pure logic
# with no Azure in it, so every combination is unit-testable.

function Get-VmfLockVerdict {
    <#
    .SYNOPSIS
        Decide whether a set of locks blocks the move of this machine.
    .DESCRIPTION
        Pure: takes the locks already read, returns @{ Blocked; Reason; Detail }.
        A lock that does not block the move is reported as clear - stopping a
        resize because someone put a delete lock on the resource group would be
        a refusal with no cause behind it.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()][object[]]$Locks
    )

    $all = @($Locks | Where-Object { $_ })
    if ($all.Count -eq 0) { return @{ Blocked = $false; Detail = $null } }

    # Only a ReadOnly lock stops the move. A CanNotDelete lock does not refuse
    # a resize or a disk swap, so the move goes on; the line names the lock.
    $hits = @($all | Where-Object { [string]$_.level -eq 'ReadOnly' })
    if ($hits.Count -eq 0) {
        $ignored = @($all | ForEach-Object { "$($_.name) ($($_.level)) on $($_.scope)" }) -join '; '
        # CANNOTDELETE-RESTORE-1: a lock on the resource group (or above it)
        # covers the disks the product makes there, and refuses their delete
        # after the move. A lock on the machine itself covers no disk.
        $groupWide = @($all | Where-Object { [string]$_.level -eq 'CanNotDelete' -and [string]$_.scope -ne 'this machine' })
        $cleanup = if ($groupWide.Count) { ' A CanNotDelete lock on the resource group prevents the delete of the rollback disks after the move. Each one costs money until it is deleted.' } else { '' }
        return @{ Blocked = $false; Detail = "These locks do not stop the move: $ignored.$cleanup" }
    }

    # STOP-TEXT-SPECIFIC-1: the reason of the lock TYPE, so the stop says only
    # what this lock refuses.
    $named = @($hits | ForEach-Object { "$($_.name) ($($_.level)) on $($_.scope)" }) -join '; '
    @{ Blocked = $true; Reason = 'resourceLocked'
       Detail = "A ReadOnly lock refuses every change to this machine: $named." }
}