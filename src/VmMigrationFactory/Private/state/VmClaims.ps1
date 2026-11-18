# RUN-CLAIM-1. The question: does anything stop a machine being in two
# runs at once? Nothing did - and the hole was deeper than a missing warning.
#
# Leases are written UNDER the run path (`leases/<vmkey>.lease`), so
# exclusive-create fences workers WITHIN one run and not at all between runs.
# Two runs over the same resource group could lease, deallocate and convert the
# same machine simultaneously, each believing it held it exclusively, inside
# the deallocated window where the disks are detached. The route there is
# ordinary: scan a resource group, abandon the run after a bad attempt, scan it
# again.
#
# A claim therefore has to live BESIDE the runs rather than inside one. Runs
# are prefixes in a single container, so the claim namespace is a sibling
# prefix - reachable with the very same exclusive-create primitive, no new
# storage concept, and correct for the local backend too.
#
# The lease-time check is the gate. The plan-time check exists only so that
# somebody finds out before a wave starts rather than during one.

function Get-VmfClaimScopePath {
    <#
    .SYNOPSIS
        The store-wide scope that holds machine claims - a sibling of the runs.
    .DESCRIPTION
        azblob://acct/container/<runId>  ->  azblob://acct/container/vmf-claims
        <root>/<runId>                  ->  <root>/vmf-claims
        Two runs in the same store MUST resolve to the same scope, or the claim
        fences nothing.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RunPath)

    if ($RunPath -match '^azblob://([^/]+)/([^/]+)/(.+?)/*$') {
        return "azblob://$($Matches[1])/$($Matches[2])/vmf-claims"
    }
    $parent = Split-Path -Path ($RunPath.TrimEnd('\', '/')) -Parent
    if (-not $parent) { $parent = $RunPath }
    Join-Path $parent 'vmf-claims'
}

function Get-VmfClaimRelPath {
    <#
    .SYNOPSIS
        The name of a machine's claim - one name for one machine, whatever the
        letter case of its ID.
    .DESCRIPTION
        VMID-CASE-1. Azure gives some resource IDs with the resource group or
        the machine name in upper case, and each run keeps the ID as ITS
        assessment read it. The claim was named from that ID, and blob storage
        names are case sensitive - so two runs that read one machine in two
        letter cases held two claims, and both were granted. The name is now
        in lower case. A granted claim is written under BOTH names, so a run
        still on the old code, which knows only the old name, finds the machine
        held. A claim made before this change is read under its old name
        (Get-VmfClaimLegacyRelPath) - but only the old name made from THIS
        run's spelling of the ID. A claim an older run made from the ID in
        another letter case is not found: a known limit, for runs that hold
        machines while an installation is updated (VMID-CASE-1).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmId)
    # The resource group is found by the word before it, which is itself read
    # as written - so that word is put in one spelling first.
    (Get-VmfVmKey -VmId ($VmId -replace '(?i)/resourceGroups/', '/resourceGroups/')).ToLowerInvariant() + '.claim'
}

function Get-VmfClaimLegacyRelPath {
    <#
    .SYNOPSIS
        VMID-CASE-1: the name a claim had before it was put in lower case - the
        ID's key in the letter case the run read. $null when it is the same name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmId)
    $old = (Get-VmfVmKey -VmId $VmId) + '.claim'
    if ($old -ceq (Get-VmfClaimRelPath -VmId $VmId)) { return $null }
    $old
}

function Test-VmfClaimHolderAlive {
    <#
    .SYNOPSIS
        Is the run that holds this claim still there? A claim held by a run
        that no longer exists is not a claim - nothing can be migrating with it.
    .DESCRIPTION
        Answered from the claim's OWN recorded runPath, never inferred from a
        naming convention: guessing wrong here would either strand a machine or,
        far worse, hand a live run's machine to a second one.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Claim)

    if (-not $Claim) { return $false }
    if (-not $Claim.PSObject.Properties['runPath'] -or -not [string]$Claim.runPath) {
        # An older claim with no path recorded: assume the holder is alive.
        # Unknown must never resolve in the direction that lets two runs touch
        # one machine.
        return $true
    }
    $null -ne (Read-VmfStoreJson -RunPath ([string]$Claim.runPath) -RelPath 'run.json' -Depth 6)
}

function Get-VmfVmClaim {
    <#
    .SYNOPSIS
        Who holds this machine, if anyone. $null when it is free.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $scope = Get-VmfClaimScopePath -RunPath $RunPath
    $claim = Read-VmfStoreJson -RunPath $scope -RelPath (Get-VmfClaimRelPath -VmId $VmId) -Depth 6
    # VMID-CASE-1: a claim made before its name was put in lower case.
    $legacy = Get-VmfClaimLegacyRelPath -VmId $VmId
    if (-not $claim -and $legacy) { $claim = Read-VmfStoreJson -RunPath $scope -RelPath $legacy -Depth 6 }
    $claim
}

function New-VmfVmClaim {
    <#
    .SYNOPSIS
        Claim a machine for a run, store-wide. Idempotent for the holder.
    .PARAMETER Force
        Take a claim another run holds. An abandoned run must never hold
        machines hostage - but taking one is a deliberate act by a person, and
        it is recorded on the claim.
    .OUTPUTS
        @{ Granted = <bool>; HeldBy = <runId|null>; Detail = <string>;
           Taken = <bool> } - DELETE-UNSTARTED-WAVE-1: on a grant, Taken says
           this call took the claim; false when the run held it already.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter()][switch]$Force,
        [Parameter()][string]$TakenBy
    )

    $scope = Get-VmfClaimScopePath -RunPath $RunPath
    $rel = Get-VmfClaimRelPath -VmId $VmId
    $doc = [ordered]@{
        schemaVersion = 1
        vmId          = $VmId
        runId         = $RunId
        # The holder's own path, so "is that run still there?" is a question we
        # can ANSWER rather than infer from a naming convention. Without it a
        # claim outlives the run that made it and holds the machine forever -
        # which is the hostage problem this whole item exists to avoid.
        runPath       = $RunPath
        claimedUtc    = (Get-Date).ToUniversalTime().ToString('o')
        takenFrom     = $null
        takenBy       = $null
    }

    $name = ($VmId -split '/')[-1]
    $heldBy = { param($holder) "'$name' is already part of the run '$holder', which is still using it. A machine can only be in one migration at a time." }

    # VMID-CASE-1: a claim made before its name was put in lower case still
    # holds the machine. One that another run still holds is read as the
    # claim, so the rules below refuse it (or record it taken, with -Force);
    # one this run holds, or one whose run is gone, holds nothing against it.
    $legacyRel = Get-VmfClaimLegacyRelPath -VmId $VmId
    $older = if ($legacyRel) { Read-VmfStoreJson -RunPath $scope -RelPath $legacyRel -Depth 6 } else { $null }
    $olderOther = $older -and [string]$older.runId -ne $RunId
    $olderHolds = $olderOther -and (Test-VmfClaimHolderAlive -Claim $older)
    # Reviews of VMID-CASE-1: once this run is granted the new name, it takes
    # the OLDER name too, before the grant is reported. A run still on the old
    # code knows only that name, and on blob storage the two are two names:
    # holding only the new one let the old code create the older one and move
    # the same machine. So: the older name is created for this run; a claim
    # there that names this run is kept (on a file store that ignores case it
    # IS the claim just written); a dead run's claim, or any claim with -Force,
    # is overwritten with this run's. A LIVE other run's claim there means that
    # run took the machine first: the new name is given back and this run is
    # refused - never both runs at once. This run's release removes both.
    # Returns the refusal when another run won, or nothing. (Not compared by
    # claimedUtc: ConvertFrom-Json turns it into a date.)
    # CLAIM-TAKEOVER-RACE-1: the overwrite is written only if the older name
    # still holds the text judged; another run's write in between is judged
    # again, and a name that changes at every try is a refusal.
    $takeOlder = {
        if (-not $legacyRel) { return }
        foreach ($try in 1..3) {
            if (Write-VmfStoreJsonExclusive -RunPath $scope -RelPath $legacyRel -Document $doc) { return }
            $nowText = Read-VmfStoreText -RunPath $scope -RelPath $legacyRel
            if ($null -eq $nowText) { continue }   # removed between the two calls: try again
            $now = $nowText | ConvertFrom-Json -Depth 6
            if ([string]$now.runId -eq $RunId) { return }
            if (-not $Force -and (Test-VmfClaimHolderAlive -Claim $now)) {
                return @{ HeldBy = [string]$now.runId; Detail = (& $heldBy ([string]$now.runId)) }
            }
            if (Write-VmfStoreTextIfVersion -RunPath $scope -RelPath $legacyRel -Content ($doc | ConvertTo-Json -Depth 6) `
                    -ExpectedVersion (Get-VmfDocumentVersion -Text $nowText)) { return }
        }
        @{ HeldBy = $null; Detail = "The older claim of '$name' changed each time this migration tried to take it, so this migration did not take the machine." }
    }
    $grant = {
        param($Detail, [bool]$Taken)
        $lost = & $takeOlder
        if ($lost) {
            # The new name is given back only while it holds this run's claim:
            # a claim another run took there in between stays.
            $mineText = Read-VmfStoreText -RunPath $scope -RelPath $rel
            if ($null -ne $mineText -and [string]($mineText | ConvertFrom-Json -Depth 6).runId -eq $RunId) {
                $null = Remove-VmfStoreItemIfVersion -RunPath $scope -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $mineText)
            }
            return @{ Granted = $false; HeldBy = $lost.HeldBy; Detail = $lost.Detail }
        }
        @{ Granted = $true; HeldBy = $RunId; Detail = $Detail; Taken = $Taken }
    }
    if ($olderOther -and -not $olderHolds) { $doc.takenFrom = [string]$older.runId; $doc.takenBy = 'automatic' }

    # CLAIM-TAKEOVER-RACE-1: a first claim is a create-only write, so only one
    # creator wins. A claim that is there is read as TEXT, judged, and taken
    # only if it still holds that text (Write-VmfStoreTextIfVersion: If-Match
    # on blob storage, the lock file on the file backend). A refused write
    # means another run changed the claim in between - two runs that took a
    # dead run's claim with ordinary writes were both told "claimed", and both
    # moved the machine. The claim is then read and judged again, so the run
    # that lost is refused with the name of the run that won.
    foreach ($try in 1..3) {
        # STORE-CREATE-LOST-ANSWER-1: the run id, its path and the time make the
        # text this call's own.
        if (-not $olderHolds -and (Write-VmfStoreJsonExclusive -RunPath $scope -RelPath $rel -Document $doc -UniqueText)) {
            return (& $grant 'claimed' $true)
        }
        $text = Read-VmfStoreText -RunPath $scope -RelPath $rel
        # A live older claim of another run is the holder, whatever the new
        # name says: a run on the old code knows only that name.
        if ($olderHolds) { $existing = $older }
        elseif ($null -eq $text) { continue }   # removed after the create: create again
        else { $existing = $text | ConvertFrom-Json -Depth 6 }
        $holder = [string]$existing.runId

        if ($holder -eq $RunId) {
            return (& $grant 'already held by this run' $false)
        }

        # A claim held by a run that no longer exists is not a claim. Deleting
        # a run must not strand its machines - and the record says who it was
        # taken from, so this is never silent.
        if (-not (Test-VmfClaimHolderAlive -Claim $existing)) {
            $doc.takenFrom = $holder
            $doc.takenBy = 'automatic'
            $why = "the run '$holder' that held this machine no longer exists, so the machine was free"
        }
        elseif (-not $Force) {
            return @{ Granted = $false; HeldBy = $holder; Detail = (& $heldBy $holder) }
        }
        else {
            $doc.takenFrom = $holder
            $doc.takenBy = if ($TakenBy) { $TakenBy } else { 'unknown' }
            $why = "taken from '$holder' by $($doc.takenBy)"
        }
        $content = $doc | ConvertTo-Json -Depth 6
        $written = if ($null -eq $text) {
            Write-VmfStoreTextExclusive -RunPath $scope -RelPath $rel -Content $content
        }
        else {
            Write-VmfStoreTextIfVersion -RunPath $scope -RelPath $rel -Content $content -ExpectedVersion (Get-VmfDocumentVersion -Text $text)
        }
        if ($written) { return (& $grant $why $true) }
    }

    # The claim changed at every try. A live run that holds it now is named;
    # otherwise the refusal says what happened. Never a grant: unknown never
    # lets two runs change one machine.
    $now = Read-VmfStoreJson -RunPath $scope -RelPath $rel -Depth 6
    if ($now -and [string]$now.runId -ne $RunId -and (Test-VmfClaimHolderAlive -Claim $now)) {
        return @{ Granted = $false; HeldBy = [string]$now.runId; Detail = (& $heldBy ([string]$now.runId)) }
    }
    @{
        Granted = $false; HeldBy = $(if ($now) { [string]$now.runId } else { $null })
        Detail  = "The claim of '$name' changed each time this migration tried to take it, so this migration did not take the machine."
    }
}

function Remove-VmfVmClaim {
    <#
    .SYNOPSIS
        Release a machine, but ONLY if this run holds it - otherwise a tidy-up
        in one run silently unfences another.
    .DESCRIPTION
        CLAIM-TAKEOVER-RACE-1: a claim is removed only as it was read
        (Remove-VmfStoreItemIfVersion). A release that read this run's claim
        and then removed whatever was there removed the claim another run had
        just taken with -Force, and a third run could then take the machine.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$RunId
    )
    $scope = Get-VmfClaimScopePath -RunPath $RunPath
    $rel = Get-VmfClaimRelPath -VmId $VmId
    $legacyRel = Get-VmfClaimLegacyRelPath -VmId $VmId
    # VMID-CASE-1: the name a claim had before it was put in lower case. This
    # run releases it when it is this run's; removes it when its run is gone
    # (the same rule the gates use); and leaves another live run's alone. It is
    # never this run's claim, so it never makes this release fail - the review
    # found Stop-VmfRun, Remove-VmfRun and Skip-VmfVm counting a failure.
    if ($legacyRel) {
        foreach ($try in 1..3) {
            $olderText = Read-VmfStoreText -RunPath $scope -RelPath $legacyRel
            if ($null -eq $olderText) { break }
            $older = $olderText | ConvertFrom-Json -Depth 6
            if (-not ([string]$older.runId -eq $RunId -or -not (Test-VmfClaimHolderAlive -Claim $older))) { break }
            if (Remove-VmfStoreItemIfVersion -RunPath $scope -RelPath $legacyRel -ExpectedVersion (Get-VmfDocumentVersion -Text $olderText)) { break }
        }
    }
    # Read AFTER that: on a file store that ignores case the two names are one
    # file, and a dead claim just removed is not a claim held by another run.
    foreach ($try in 1..3) {
        $text = Read-VmfStoreText -RunPath $scope -RelPath $rel
        if ($null -eq $text) { return @{ Released = $true; Detail = 'no claim to release' } }
        $existing = $text | ConvertFrom-Json -Depth 6
        if ([string]$existing.runId -ne $RunId) {
            return @{ Released = $false; Detail = "held by '$($existing.runId)', not this run" }
        }
        if (Remove-VmfStoreItemIfVersion -RunPath $scope -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $text)) {
            return @{ Released = $true; Detail = 'released' }
        }
    }
    @{ Released = $false; Detail = "The claim of '$(($VmId -split '/')[-1])' changed each time this migration tried to release it, so the claim stays." }
}

function Remove-VmfSettledVmClaim {
    <#
    .SYNOPSIS
        CLAIM-KEPT-AFTER-WAVE-1: give back the claim of a machine this run is
        finished with - MIGRATED or SKIPPED - and of no other.
    .DESCRIPTION
        The worker calls this where the machine settles, after the state
        machine checkpointed the final state; Start-VmfWave calls it again at
        the end of the wave, as a second pass. The release used to be only at
        the end of the wave, so an execution that stopped after the last
        machine settled left every machine of the wave claimed, and the
        service never starts a wave whose machines are all settled.

        The state is read from the store, never taken from the caller: a
        machine in any other state keeps its claim - a live worker's machine
        mid-move, and a FAILED or parked machine this run still recovers
        (Skip this machine and Stop the run release those). The claim was
        taken under run.json's id (Get-VmfNextWaveVm), so it is released under
        it, by Remove-VmfVmClaim: only this run's claim, only as it was read.
        Safe to run again.

        SKIP-CHANGED-FREED-1: a SKIPPED machine whose record says it is left
        CHANGED (Test-VmfMachineLeftChanged) keeps its claim too, whoever
        calls this - the worker, the end of the wave, a restore, Finish the
        restore, or a timer of the service. Another migration would take its
        first safety copy of the changed machine. Restore this machine and
        Finish the restore call this once their record is written, so the
        claim goes when the record says the machine is mended.
    .OUTPUTS
        Remove-VmfVmClaim's answer, $null when the machine is not settled, or
        Released = $false when it is left changed.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc -or [string]$doc.state -notin $script:VmfSettledStates) { return $null }
    if (Test-VmfMachineLeftChanged -Doc $doc) {
        return @{ Released = $false; Detail = 'the machine was left out while it is changed, so this run keeps it until a restore' }
    }
    $run = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    $runId = if ($run) { [string]$run.runId } else { '' }
    # A run whose own id cannot be read is not the holder: release nothing.
    if (-not $runId) { return @{ Released = $false; Detail = 'the id of this run could not be read, so the claim stays' } }
    Remove-VmfVmClaim -RunPath $RunPath -VmId $VmId -RunId $runId
}

function Get-VmfOtherRunClaimRefusal {
    <#
    .SYNOPSIS
        RESTORE-CROSS-RUN-1: does ANOTHER live migration hold this machine's
        claim? The refusal sentence, which names that migration, or $null.
    .DESCRIPTION
        A restore, a rebuild and a finish take the machine's lease, and a lease
        fences the jobs of ONE migration. A machine migrated here is released when
        it settles (CLAIM-KEPT-AFTER-WAVE-1), so a newer migration can claim it and move it -
        and this migration's panel still offers to put it back. The claim is
        the fence between migrations, so these jobs ask it too: while another
        migration holds the machine, they are refused before anything changes.
        Decided 2026-10-23: a safety block for a case nobody has seen,
        with no hand-off of the claim.

        This migration's own claim is no refusal, and neither is a claim whose
        migration is gone (Test-VmfClaimHolderAlive - the rule every claim gate
        uses). A claim with no migration path recorded is read as alive, and
        a run whose own id cannot be read is not the holder: unknown never lets
        two migrations change one machine.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $claim = Get-VmfVmClaim -RunPath $RunPath -VmId $VmId
    if (-not $claim) { return $null }
    $run = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    $runId = if ($run) { [string]$run.runId } else { '' }
    if ($runId -and [string]$claim.runId -eq $runId) { return $null }
    if (-not (Test-VmfClaimHolderAlive -Claim $claim)) { return $null }
    "The migration '$([string]$claim.runId)' holds '$(($VmId -split '/')[-1])' now, and a machine can be in one migration at a time. Try again after that migration migrates it, or skips or stops it with no change on it, or after you delete that migration."
}

function Test-VmfVmClaims {
    <#
    .SYNOPSIS
        Plan-time: which machines does another run already hold? Informative -
        the gate that actually protects a machine is at lease time.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()]$Entries,
        [Parameter(Mandatory)][string]$RunId
    )
    $conflicts = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) {
        if (-not $e -or -not $e.vmId) { continue }
        $claim = Get-VmfVmClaim -RunPath $RunPath -VmId ([string]$e.vmId)
        # Same rule as the lease gate: a claim whose run is gone is not a
        # conflict. Two checks that disagree would send an operator hunting for
        # a run that does not exist.
        if ($claim -and [string]$claim.runId -ne $RunId -and (Test-VmfClaimHolderAlive -Claim $claim)) {
            $conflicts.Add([pscustomobject]@{
                VmId = [string]$e.vmId
                Name = ([string]$e.vmId -split '/')[-1]
                HeldBy = [string]$claim.runId
            })
        }
    }
    if ($conflicts.Count -eq 0) {
        return @{ Pass = $true; Conflicts = @(); Detail = 'no machine here belongs to another migration' }
    }
    $named = @($conflicts | ForEach-Object { "$($_.Name) (in '$($_.HeldBy)')" }) -join ', '
    @{
        Pass = $false; Conflicts = @($conflicts)
        Detail = "These machines are already part of another migration and cannot be in two at once: $named. Finish or discard that one, or take them over deliberately."
    }
}

function Get-VmfHeldMachines {
    <#
    .SYNOPSIS
        CLAIM-AT-PLAN-1: which of these machines another live migration holds -
        for Choose the machines, before a person plans a machine the start
        check would refuse.
    .DESCRIPTION
        The answer is Test-VmfVmClaims, the start check's own rule (a claim of
        another run whose run is still there), so the page and the start never
        disagree. The claims are listed first, and only a machine whose claim
        name (or older name, VMID-CASE-1) is in the listing is read: a page of
        a thousand machines costs one listing, not a thousand reads. Names are
        compared without letter case, which can only add a read, never lose a
        claim. Blob storage lists 5,000 names a page and the store helper reads
        one page, so a full page is not proof a machine is free: then every
        machine is read. The page is counted by EVERY name in it - the claim
        folder also holds deletions.jsonl, so a full page can name 4,999 claims.
    .OUTPUTS
        One object per held machine: vmId (as the caller gave it), name, heldBy.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$VmIds,
        [Parameter(Mandatory)][AllowEmptyString()][string]$RunId
    )
    $ids = @($VmIds | Where-Object { $_ })
    if ($ids.Count -eq 0) { return }
    $scope = Get-VmfClaimScopePath -RunPath $RunPath
    $listing = @(Get-VmfStoreNames -RunPath $scope -Folder '')
    $names = @($listing | Where-Object { [string]$_ -like '*.claim' })
    $read = $ids
    if ($listing.Count -lt 5000) {
        $listed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($n in $names) { $null = $listed.Add([string]$n) }
        $read = @($ids | Where-Object {
                $listed.Contains((Get-VmfClaimRelPath -VmId $_)) -or
                (($legacy = Get-VmfClaimLegacyRelPath -VmId $_) -and $listed.Contains($legacy)) })
    }
    if ($read.Count -eq 0) { return }
    $gate = Test-VmfVmClaims -RunPath $RunPath -Entries @($read | ForEach-Object { [pscustomobject]@{ vmId = $_ } }) -RunId $RunId
    foreach ($c in @($gate.Conflicts)) {
        [pscustomobject]@{ vmId = [string]$c.VmId; name = [string]$c.Name; heldBy = [string]$c.HeldBy }
    }
}
