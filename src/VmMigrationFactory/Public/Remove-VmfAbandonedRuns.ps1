function Remove-VmfAbandonedRuns {
    <#
    .SYNOPSIS
        RUN-LIFECYCLE-1: remove runs that were only scanned and then left.
    .DESCRIPTION
        As soon as a person sets names in the wizard, even if they never
        finish it, the wizard stores the migration, and it shows up in reports
        with actions available on it.

        The wizard has to create the run at step one, because the scan is the
        first real action and it takes minutes - there is nothing to show
        otherwise. So abandoning the wizard leaves a run that exists for ever.
        The run page already labels it "Still being prepared", and it can be
        deleted by hand, but nothing clears them up.

        THREE RULES, and each one is a refusal to be clever:

        1. SETUP STAGE ONLY. A run with a plan is a decision somebody made, and
           removing it is a question about safety copies. This only removes
           runs with no plan at all - a scan, which costs minutes to redo.
        2. NEVER AUTOMATIC. Nothing calls this on a timer. A person runs it, or
           schedules it themselves, having read what it would take.
        3. -WhatIf FIRST, always worth it. The default is to report; you must
           pass -Confirm:$false or answer the prompt to delete anything.

        A run whose age cannot be read is KEPT. Unknown is not old.
    .PARAMETER StorePath
        The container root - `azblob://<account>/<container>` or a local folder.
    .PARAMETER Project
        Only look inside this project. Omit to look at the top level and inside
        every project.
    .PARAMETER OlderThanDays
        How old a scan must be before it counts as abandoned. Default 30.
    .PARAMETER Reason
        Recorded with each removal.
    .PARAMETER RemovedBy
        Who asked, when the caller acts for somebody (the facade does).
    .EXAMPLE
        Remove-VmfAbandonedRuns -StorePath azblob://vmfstate/vmf-runs -WhatIf
    .EXAMPLE
        Remove-VmfAbandonedRuns -StorePath $store -OlderThanDays 60 -Reason 'quarterly tidy' -Confirm:$false
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][string]$Project,
        [Parameter()][ValidateRange(1, 3650)][int]$OlderThanDays = 30,
        [Parameter()][string]$Reason = 'abandoned setup, removed by tidy-up',
        [Parameter()][string]$RemovedBy
    )

    $root = $StorePath.TrimEnd('/', '\')
    if ($Project) { $root = "$root/$Project" }

    # Every candidate run path, with the project it sits in. A prefix holding a
    # project.json is a PROJECT, and its children are the runs - which is the
    # same rule the Projects page and Get-VmfProject use.
    # STORE-RUNPATHS-REFUSED-1: the projects come from Get-VmfStoreFoldersHolding,
    # which throws on a listing the store refuses - read as "no project here",
    # a refusal took a project for a run.
    $candidates = [System.Collections.Generic.List[object]]::new()
    $folders = @(Get-VmfStorePrefixes -StorePath $root | Where-Object { $_ -notin @(Get-VmfNotARunFolders) })
    $projects = @(Get-VmfStoreFoldersHolding -StorePath $root -Folder $folders -Name 'project.json')
    foreach ($prefix in $folders) {
        $path = "$root/$prefix"
        if ($prefix -cin $projects) {
            if ($Project) { continue }   # already inside one; do not recurse twice
            # PROJECT-LOGS-DELETE-1: and beside a project's runs too - a project's own
            # logs is its event log, never a run.
            foreach ($child in @(Get-VmfStorePrefixes -StorePath $path | Where-Object { $_ -notin @(Get-VmfNotARunFolders) })) {
                $candidates.Add([pscustomobject]@{ Id = "$prefix/$child"; Path = "$path/$child" })
            }
            continue
        }
        $candidates.Add([pscustomobject]@{ Id = $prefix; Path = $path })
    }

    $cutoff = (Get-Date).ToUniversalTime().AddDays(-$OlderThanDays)
    $removable = [System.Collections.Generic.List[object]]::new()
    $kept = [System.Collections.Generic.List[object]]::new()

    foreach ($c in $candidates) {
        $manifest = Read-VmfStoreJson -RunPath $c.Path -RelPath 'run.json' -Depth 8
        if (-not $manifest) { continue }   # not a run at all

        # EVAL-H11: plan.json has ONE reader, and it is gated. This does not
        # need to read the plan - only to know whether one exists, which is
        # what makes a run a decision rather than a scan.
        if (Test-VmfStoreItem -RunPath $c.Path -RelPath 'plan.json') {
            $kept.Add([pscustomobject]@{ Id = $c.Id; Why = 'it has a plan' })
            continue
        }

        # ASSESS-LINK-1: an ASSESSMENT never has a plan of its own - the plan
        # lives in the migration made from it - so the test above called every
        # assessment older than the cutoff abandoned, including one a live
        # migration names as what it was planned from. Remove-VmfRun now refuses
        # that, and a refusal in the loop below would stop the whole tidy-up
        # part way; so it is kept here, with the reason.
        if ((Get-VmfRunKind -Manifest $manifest) -eq 'assessment' -and
            @(Get-VmfMigrationsPlannedFrom -RunPath $c.Path -Manifest $manifest).Count) {
            $kept.Add([pscustomobject]@{ Id = $c.Id; Why = 'a migration was planned from it' })
            continue
        }

        # RUN-DELETE-RESERVE-1: Remove-VmfRun refuses a run holding a
        # reservation that bills, and a refusal in the loop below would stop the
        # tidy-up part way - so it is kept here, with the reason, as above.
        if (Get-VmfRunBillingRefusal -RunPath $c.Path -Action 'delete the migration') {
            $kept.Add([pscustomobject]@{ Id = $c.Id; Why = 'it holds a capacity reservation that bills' })
            continue
        }

        # Unknown is not old. A run whose date cannot be read is left alone,
        # the same rule the engine follows for an unknown generation.
        $createdRaw = [string]$manifest.createdUtc
        $created = [datetime]::MinValue
        if (-not $createdRaw -or -not [datetime]::TryParse($createdRaw, [ref]$created)) {
            $kept.Add([pscustomobject]@{ Id = $c.Id; Why = 'its age cannot be read' })
            continue
        }
        $created = $created.ToUniversalTime()
        if ($created -gt $cutoff) {
            $kept.Add([pscustomobject]@{ Id = $c.Id; Why = "it is newer than $OlderThanDays days" })
            continue
        }

        $removable.Add([pscustomobject]@{
            Id = $c.Id; Path = $c.Path; CreatedUtc = $created.ToString('o')
            Kind = Get-VmfRunKind -Manifest $manifest   # RETAIN-KIND-1: the one rule
            AgeDays = [int][math]::Floor(((Get-Date).ToUniversalTime() - $created).TotalDays)
        })
    }

    $who = if ($RemovedBy) { $RemovedBy } else { $null }
    $removed = [System.Collections.Generic.List[object]]::new()

    foreach ($r in $removable) {
        if (-not $PSCmdlet.ShouldProcess($r.Path, "remove an abandoned scan from $($r.CreatedUtc)")) { continue }
        if (-not $who) { $who = (Get-VmfSignedInIdentity).Identity }
        # THROUGH Remove-VmfRun, which re-checks the stage itself. This cmdlet
        # decides WHICH runs; that one decides whether a run may go, and it is
        # the only caller of the bulk delete.
        Remove-VmfRun -RunPath $r.Path -Reason $Reason -RemovedBy $who -KeepSafetyCopies -Confirm:$false | Out-Null
        $removed.Add($r)
    }

    [pscustomobject]@{
        StorePath   = $StorePath
        OlderThanDays = $OlderThanDays
        Candidates  = @($removable)
        Removed     = @($removed)
        Kept        = @($kept)
        RemovedBy   = $who
    }
}
