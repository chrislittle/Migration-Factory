# RUN-LIFECYCLE-1 (raised and ruled 2026-08-28).
#
# As soon as a person sets names in the wizard, even if they never finish it,
# the wizard stores the migration: it shows up in reports and can be acted on.
#
# The wizard's first step starts a scan, which creates the run. Deferring
# that is not the fix - the scan IS the first real action, it takes minutes,
# and the wizard's own middle steps display its results. What was wrong is that
# a run which had only been SCANNED looked exactly like one being migrated
# with, could not be resumed where the person left off, and could not be thrown
# away.
#
# So a run gets a visible life instead of a delayed birth. The stage is DERIVED
# from what the store already holds rather than stored: a status field can drift
# from reality, and this one cannot.

function Get-VmfRunStage {
    <#
    .SYNOPSIS
        Where a run is in its life: setup -> planned -> running -> finished.
    .DESCRIPTION
        setup     no plan yet - a scan, and nobody has decided anything
        planned   a plan exists, but no machine has been touched
        running   at least one machine is on its way, or has finished while
                  others have not
        finished  every machine in the plan has reached a terminal state
    .PARAMETER Plan
        The plan document, or $null when there is none.
    .PARAMETER StateDocs
        The machines' state documents (may be empty).
    .OUTPUTS
        @{ Stage = <string>; Detail = <string>; Machines = <int>; Settled = <int> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Plan,
        [Parameter()][AllowNull()]$StateDocs
    )

    $engine = Get-VmfEngineStates
    $terminal = $engine.Terminal
    $entries = @(if ($Plan) { @($Plan.entries) | Where-Object { $_ -and $_.path -eq 'A' } })

    if ($entries.Count -eq 0) {
        return @{
            Stage = 'setup'; Machines = 0; Settled = 0
            Detail = 'this run has been scanned but nothing has been planned yet'
        }
    }

    $docs = @($StateDocs) | Where-Object { $_ }
    $byId = @{}
    foreach ($d in $docs) { if ($d.vmId) { $byId[[string]$d.vmId] = $d } }

    # UNWAVED-MACHINES-UNDERWAY-1: a machine in no wave that never ran is not
    # part of the migration - no wave takes it (NOT-IN-WAVE-QUEUED-1, the rule
    # the pages and the record use). It counted as not settled, so a migration
    # whose every wave had finished read as under way, and Delete this
    # migration asked for Stop this migration, which the page does not show.
    # A plan of only such machines is still planned, never setup.
    $planned = $entries.Count
    $entries = @($entries | Where-Object { -not (Test-VmfEntryOutsideRun -Entry $_ -StateDoc $byId[[string]$_.vmId]) })

    # One (state, how many machines) for each machine with a document.
    # PAGE-LOAD-1: the way from a run summary (PERF-RUNS-LIST-1) went with the
    # list of runs (GET /api/runs), which no page asks for any more.
    $tally = [System.Collections.Generic.List[object]]::new()
    foreach ($e in $entries) {
        $doc = $byId[[string]$e.vmId]
        if (-not $doc) { continue }
        $tally.Add([pscustomobject]@{ State = [string]$doc.state; Count = 1 })
    }

    $started = 0
    $settled = 0
    foreach ($t in $tally) {
        if ($t.State -in $terminal) { $settled += $t.Count; $started += $t.Count }
        # EVAL-M15: this compared against 'QUEUED', a state nothing writes. The
        # real first state is PLANNED, so every planned machine counted as
        # started and a run that had never run reported itself under way.
        elseif ($t.State -and $t.State -ne $engine.NotStarted) { $started += $t.Count }
    }

    if ($started -eq 0) {
        return @{
            Stage = 'planned'; Machines = $planned; Settled = 0
            Detail = "planned: $planned machines, none started yet"
        }
    }
    if ($settled -ge $entries.Count) {
        return @{
            Stage = 'finished'; Machines = $entries.Count; Settled = $settled
            Detail = "finished: all $($entries.Count) machines have settled"
        }
    }
    @{
        Stage = 'running'; Machines = $entries.Count; Settled = $settled
        Detail = "under way: $settled of $($entries.Count) machines settled"
    }
}

function Test-VmfRunDiscardable {
    <#
    .SYNOPSIS
        May this run be thrown away?
    .DESCRIPTION
        The first answer here was wrong: refusing to discard any run
        containing a touched machine would lock a VM into a run plan that
        might need to be redone after an error. Redoing a failed
        migration is the normal case.

        So the guard separates two things:
          IN FLIGHT is a hard refusal - deleting the record of a machine
          mid-conversion is how you lose a machine, because that record is what
          knows how to put it back.
          SETTLED may go, but the safety copies it points at must be dealt
          with, or they bill forever with nothing left that knows what they
          were for.
    .OUTPUTS
        @{ Ok = <bool>; Detail = <string>; OrphanSnapshots = @(<id>);
           RollbackDisksBeforeMove = @(VmId, diskId, diskName); MadeDisks = @(VmId, diskId, diskName, List);
           ChangedMachines = @(VmId, Name, SnapshotIds) - DELETE-CHANGED-FREED-1:
           the machines left changed, whose copies the delete keeps }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$Plan,
        [Parameter()][AllowNull()]$StateDocs
    )

    $terminal = (Get-VmfEngineStates).Terminal
    $docs = @($StateDocs) | Where-Object { $_ }

    # EVAL-M15: same wrong literal, and here it was the expensive one - a
    # PLANNED machine read as in-flight, so a run where nothing had ever
    # started refused to be discarded, saying it was "still working on" a
    # machine that had not been touched. That is the stuck run with no way out.
    $notStarted = (Get-VmfEngineStates).NotStarted
    $inFlight = @($docs | Where-Object {
        $s = [string]$_.state
        $s -and $s -ne $notStarted -and $s -notin $terminal
    })
    if ($inFlight.Count -gt 0) {
        $names = @($inFlight | ForEach-Object { ([string]$_.vmId -split '/')[-1] + " ($([string]$_.state))" }) -join ', '
        return @{
            Ok = $false; OrphanSnapshots = @()
            Detail = "This run is still working on $names. A machine part-way through a move must not have its record deleted - that record is what knows how to roll it back. Wait for it, or stop the run first."
        }
    }

    # DISCARD-PUTBACK-HOLD-1: and a machine whose restore has not
    # ended, or one the service gave up on, or a later one that carries that
    # mark - the same question the daily cleanup asks before it keeps the
    # machine's copies (Test-VmfPutBackJobHolds). Such a machine can be part
    # way, even with no definition in Azure, and its record and its copies are
    # what Rebuild this machine needs. Its state can read settled, and a job
    # the service gave up on runs no more, so nothing else here refuses it.
    # Both choices: Keep the copies deletes the record, which is the only
    # thing that knows the machine is part way.
    $held = @($docs | Where-Object { Test-VmfPutBackJobHolds -Doc $_ })
    if ($held.Count -gt 0) {
        # One sentence pair per machine: what holds it, and what to do, by
        # the kind of its job (Get-VmfPutBackHoldDeleteWords).
        $lines = @($held | ForEach-Object { ([string]$_.vmId -split '/')[-1] + ": $(Get-VmfPutBackHoldDeleteWords -Doc $_)" }) -join ' '
        return @{
            Ok = $false; OrphanSnapshots = @(); RollbackDisksBeforeMove = @(); MadeDisks = @()
            Detail = "The migration was not deleted. The product needs its record and its safety copies for each machine that follows. $lines Then delete the migration again."
        }
    }

    # DELETE-CHANGED-FREED-1 (ruling 2026-11-06): a machine whose record
    # says it is left CHANGED is not as it was, and its safety copies are the
    # only way to put it back. The delete may go on - a migration must always
    # be discardable - but it ALWAYS keeps that machine's copies, also with
    # Delete the copies as well. They are named here, never counted with the
    # copies the delete removes; the caller records them and the page says so.
    $changed = @(foreach ($d in $docs) {
            if (-not (Test-VmfMachineLeftChanged -Doc $d)) { continue }
            if ($d.PSObject.Properties['retention'] -and $d.retention -and $d.retention.deletedUtc) { $ids = @() }
            else { $ids = @(Get-VmfSafetyCopyIds -StateDoc $d | Where-Object { $_ }) }
            [pscustomobject]@{ VmId = [string]$d.vmId; Name = ([string]$d.vmId -split '/')[-1]; SnapshotIds = $ids }
        })
    $changedIds = @($changed | ForEach-Object { $_.VmId })

    $snaps = @(foreach ($d in $docs) {
        if ($d.PSObject.Properties['retention'] -and $d.retention -and $d.retention.deletedUtc) { continue }
        if ([string]$d.vmId -in $changedIds) { continue }
        # SAFETY-RETRY-1: the earlier attempts' copies too.
        Get-VmfSafetyCopyIds -StateDoc $d
    }) | Where-Object { $_ }

    # ROLLBACK-DISKS-FIRST-1: and the rollback disks that nothing
    # used. They are made from the copies and go with them; a run deleted
    # without them leaves disks that bill with nothing left to name them.
    $disks = @(foreach ($d in $docs) {
            Get-VmfRollbackDisksBeforeMoveEntries -StateDoc $d | Where-Object { -not [string]$_.usedUtc -and -not [string]$_.deletedUtc } |
                ForEach-Object { [pscustomobject]@{ VmId = [string]$d.vmId; diskId = [string]$_.diskId; diskName = [string]$_.diskName } }
        })

    # MADE-DISK-RUN-DELETE-1: and the disks a rollback or a restore
    # made from a copy that nothing uses - the same rule the daily cleanup
    # asks (Get-VmfDeletableMadeDisks), without its wait for the move to end:
    # the run's record is the only thing that names them, and it is going.
    # A machine whose restore has not ended or was given up never
    # gets here: DISCARD-PUTBACK-HOLD-1 refuses the whole delete above.
    $made = @(foreach ($d in $docs) {
            Get-VmfDeletableMadeDisks -StateDoc $d |
                ForEach-Object { [pscustomobject]@{ VmId = [string]$d.vmId; diskId = [string]$_.diskId; diskName = [string]$_.diskName; List = [string]$_.List } }
        })

    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("$($snaps.Count) safety copies")
    if ($disks.Count -gt 0) { $parts.Add("$($disks.Count) rollback disks") }
    if ($made.Count -gt 0) { $parts.Add("$($made.Count) disks that a rollback or a restore made from the copies and that no machine uses") }
    @{
        Ok = $true
        OrphanSnapshots = @($snaps)
        RollbackDisksBeforeMove = @($disks)
        MadeDisks = @($made)
        ChangedMachines = @($changed)
        Detail = if ($disks.Count -gt 0 -or $made.Count -gt 0) {
            "This run still points at $((@($parts)[0..($parts.Count - 2)] -join ', ') + ' and ' + @($parts)[-1]). Deleting the run without them leaves copies and disks that bill for ever with nothing left to say what they were for."
        } elseif ($snaps.Count -gt 0) {
            "This run still points at $($snaps.Count) safety copies. Deleting the run without them leaves copies that bill for ever with nothing left to say what they were for."
        } else { 'nothing is in flight and no safety copies are outstanding' }
    }
}


# ASSESS-LINK-1: an assessment a migration was planned from may not be deleted.
#
# The rule lived ONLY as a disabled button on the Assessments page. The call it
# guarded was a plain discard, which checked only that the run was not working
# on machines - so a direct call, or a page that had read a short listing, could
# delete the assessment and its signed review from under a migration that
# still named it as its authority. The visible end of it was this: the
# migration stayed, pointing at nothing, and the project could not be emptied.
#
# So the engine refuses, the way Remove-VmfProject refuses a project that still
# holds things. The button on the page stays, as a hint.

function Get-VmfStoreRunPaths {
    <#
    .SYNOPSIS
        Every run in the store, loose or inside a project, as Id and Path. A
        prefix holding project.json is a PROJECT and its children are the runs -
        the same rule the Projects page and Get-VmfProject use.
    .DESCRIPTION
        STORE-RUNPATHS-REFUSED-1: the projects are the folders that
        Get-VmfStoreFoldersHolding finds holding project.json - the listings
        go together, and a listing the store refuses THROWS, naming the
        folder. It asked Test-VmfStoreItem for each folder, and a refused or
        failed check read as "no project here": the project was taken for a
        loose run and skipped, so the migrations inside it were not seen and
        the delete of the assessment they were planned from went on.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorePath)

    $root = $StorePath.TrimEnd('/', '\')
    $folders = @(Get-VmfStorePrefixes -StorePath $root | Where-Object { $_ -notin @('vmf-claims', 'vmf-records') })
    $projects = @(Get-VmfStoreFoldersHolding -StorePath $root -Folder $folders -Name 'project.json')
    foreach ($prefix in $folders) {
        $path = "$root/$prefix"
        if ($prefix -cin $projects) {
            foreach ($child in @(Get-VmfStorePrefixes -StorePath $path)) {
                [pscustomobject]@{ Id = "$prefix/$child"; Path = "$path/$child" }
            }
            continue
        }
        [pscustomobject]@{ Id = $prefix; Path = $path }
    }
}

function Get-VmfMigrationsPlannedFrom {
    <#
    .SYNOPSIS
        The migrations, ANYWHERE in the store, that name this assessment as the
        one they were planned from.
    .DESCRIPTION
        `fromAssessment` holds the assessment's BARE id, which cannot say which
        project it means - and New-VmfPlan allows planning into a different
        project, with a warning. So this looks in every project rather than
        guessing one. Two assessments with the same bare id in two projects
        would make it refuse when it need not, which is the safe way to be
        wrong: a refusal names the migrations, and nothing is lost.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)]$Manifest)

    $bare = [string]$Manifest.runId
    $project = if ($Manifest.PSObject.Properties['project']) { [string]$Manifest.project } else { '' }
    # The store root: this run's own segment off the end, and its project's too.
    $root = $RunPath.TrimEnd('/', '\') -replace '[/\\][^/\\]+$', ''
    if ($project) { $root = $root -replace '[/\\][^/\\]+$', '' }
    $names = @($bare) + $(if ($project) { @("$project/$bare") } else { @() })

    foreach ($r in @(Get-VmfStoreRunPaths -StorePath $root)) {
        $m = Read-VmfStoreJson -RunPath $r.Path -RelPath 'run.json' -Depth 6
        if ($null -eq $m) { continue }
        # A manifest with no kind is not known (Get-VmfRunKind), and is read
        # as a migration here: if it names this assessment, the delete stops.
        # Only a kind that says it is not a migration is passed over.
        $kind = Get-VmfRunKind -Manifest $m
        if ($kind -and $kind -ne 'migration') { continue }
        $from = if ($m.PSObject.Properties['fromAssessment']) { [string]$m.fromAssessment } else { '' }
        if ($from -and $from -in $names) { $r.Id }
    }
}
function Assert-VmfAssessmentUnused {
    <#
    .SYNOPSIS
        Throws, naming them, when any migration was planned from this
        assessment. Nothing for a run that is not an assessment.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)]$Manifest)

    if ([string]$Manifest.kind -ne 'assessment') { return }
    # STORE-RUNPATHS-REFUSED-1: a store that refuses or fails a check while
    # the runs are found is not "no migration". The delete stops, and says so.
    $holders = try { @(Get-VmfMigrationsPlannedFrom -RunPath $RunPath -Manifest $Manifest) }
    catch {
        throw ("The product could not read every run in the store, so it cannot say whether a migration was planned from assessment '$([string]$Manifest.runId)'. " +
               "Nothing was deleted. Try again later. The store said: $($_.Exception.Message)")
    }
    if (-not $holders.Count) { return }
    $shown = ($holders | Select-Object -First 5) -join ', '
    $more = if ($holders.Count -gt 5) { " and $($holders.Count - 5) more" } else { '' }
    throw ("Assessment '$([string]$Manifest.runId)' still holds $($holders.Count) migration(s) planned from it: " +
           "$shown$more. Delete those first - each one names this assessment and its review as what it was planned from.")
}