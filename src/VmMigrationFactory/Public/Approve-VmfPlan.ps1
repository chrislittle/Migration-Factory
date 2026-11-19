function Approve-VmfPlan {
    <#
    .SYNOPSIS
        PLANRUN-1: sign off the WHOLE plan - every wave in it - once.
    .DESCRIPTION
        The last step of the wizard approved the FIRST wave only, while the
        person believed they had signed off the plan; every later wave then sat
        waiting for a signature nobody knew was missing. Authorisation happens
        once, when the plan is agreed. When each wave runs is a change window,
        not a second signature.

        WAVE-APPROVE-1: it writes ONE APPROVAL PER WAVE (approvals/<wave>.json,
        each signing its own wave, exactly as Approve-VmfWave does), so a later
        change to one wave asks again for that wave only. Then it writes
        plan-approval.json beside the plan: the approver's signed-in identity,
        the waves and the plan's version. That record is the consent for the
        run to continue on its own: when a wave finishes, the next one starts,
        unless it has a start time, a machine is waiting for a decision, or the
        next wave's own approval no longer matches it.

        It lives at the run's top level, not in approvals/, so no wave name can
        ever collide with it.
    .EXAMPLE
        Approve-VmfPlan -RunPath $run -PlanPath "$run/plan.json" -Note 'reviewed with the application owners'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Note,
        # The facade signs on behalf of the validated browser user.
        [Parameter()][hashtable]$OnBehalfOf,
        # APPR-2: the version of the plan the approver was SHOWN.
        [Parameter()][string]$ExpectedPlanHash,
        # REBUILD-REMOVE-ACCEPT-1: -IdentityLossNamed is gone. No plan of this
        # version rebuilds a machine.
        # SQL-TEMPDB-SIGNOFF-1: the machine ids the approver confirmed they
        # checked where tempdb is - each machine where the scan found SQL Server
        # and whose move takes it from a SCSI temporary disk to an NVMe
        # temporary disk or none (Test-VmfSqlTempdbRisk). The sign-off is
        # refused until every such machine of the plan is named.
        [Parameter()][AllowNull()][AllowEmptyCollection()][string[]]$SqlTempdbChecked = @()
    )

    $planText = Read-VmfTextDocument -Path $PlanPath
    if (-not $planText) { throw "No plan found at '$PlanPath'." }
    $plan = $planText | ConvertFrom-Json -Depth 24
    $waves = @(Get-VmfPlanWaveOrder -Plan $plan)
    if (-not $waves.Count) { throw "The plan at '$PlanPath' has no wave with a machine to move - nothing to sign off." }

    $planHash = Get-VmfDocumentVersion -Text $planText
    if ($ExpectedPlanHash -and $ExpectedPlanHash -ne $planHash) {
        throw ("409: the plan changed after it was shown for sign-off, so nothing was signed. " +
            "The plan at '$PlanPath' now reads $(Get-VmfShortHash $planHash) and the caller sent $(Get-VmfShortHash $ExpectedPlanHash). " +
            'Look at the plan again and sign it off once you are content with it.')
    }


    # SQL-TEMPDB-SIGNOFF-1: after the version check, so a changed plan is
    # looked at again first; before anything is written, so a refusal signs no
    # wave. Only a machine where the scan found SQL Server can be at risk.
    $sqlAtRisk = @(Get-VmfSqlTempdbRiskEntries -Entries @($plan.entries))
    $sqlMissing = @(Get-VmfSqlTempdbMissing -AtRisk $sqlAtRisk -Checked $SqlTempdbChecked)
    if ($sqlMissing.Count) {
        throw ("400: SQL Server runs on $(Get-VmfSqlTempdbNames -Entries $sqlMissing). " +
            'The target size of each has an NVMe temporary disk or no temporary disk. ' +
            'On the Run it step, tick "I checked where tempdb is on each of these machines." Then sign off the plan again.')
    }

    $who = if ($OnBehalfOf) { $OnBehalfOf } else { Get-VmfSignedInIdentity }
    $approvedUtc = (Get-Date).ToUniversalTime().ToString('o')

    # WAVE-APPROVE-1 (2026-10-05): the "Sign off all" button stays, as ONE
    # APPROVAL PER WAVE. Each wave gets its own approval, signing that wave
    # alone (Get-VmfWaveVersion) from the same text whose version was checked
    # above, so a later change to one wave asks again for that wave only.
    # Written BEFORE the sign-off record: a stop between the two leaves waves
    # approved and no consent to run on, which starts nothing by itself.
    $versions = Get-VmfWaveVersions -PlanText $planText -Wave $waves
    foreach ($w in $waves) {
        Write-VmfStoreJson -RunPath $RunPath -RelPath "approvals/$w.json" -Depth 6 -Document ([ordered]@{
            schemaVersion = (Get-VmfWaveApprovalSchemaVersion)
            runId       = [string]$plan.assessmentRunId
            wave        = $w
            approvedBy  = [ordered]@{ identity = $who.Identity; tenantId = $who.TenantId }
            approvedUtc = $approvedUtc
            planHash    = $planHash
            waveVersion = $versions[$w]
            note        = $Note
        })
    }

    # The sign-off record: who signed off which waves, and the consent for the
    # run to carry on by itself (v3). Its planHash still passes every wave
    # while the plan is the text it signed (Test-VmfPlanSignedOff), and a v3
    # record stays the consent after a change (Test-VmfPlanRunConsent) - each
    # wave's own approval is the gate.
    $doc = [ordered]@{
        schemaVersion = (Get-VmfPlanApprovalSchemaVersion)
        runId       = [string]$plan.assessmentRunId
        waves       = @($waves)
        approvedBy  = [ordered]@{ identity = $who.Identity; tenantId = $who.TenantId }
        approvedUtc = $approvedUtc
        planHash    = $planHash
        note        = $Note
    }
    # SQL-TEMPDB-SIGNOFF-1 (v4): the machines the approver confirmed, in the
    # plan's spelling. Only when there is one: a plan with no such machine
    # records nothing new.
    if ($sqlAtRisk.Count) { $doc.sqlTempdbChecked = @($sqlAtRisk | ForEach-Object { [string]$_.vmId }) }
    Write-VmfStoreJson -RunPath $RunPath -RelPath 'plan-approval.json' -Document $doc -Depth 6
    # STEP-LOG-4: written after the sign-off is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'approval' -Outcome ok `
        -Detail "the plan ($($waves.Count) wave(s)) was signed off by $($who.Identity), with one approval for each wave ($($waves -join ', ')): $Note"
    # APPROVE-GROUP-1: the list on the Migrations page says what the next wave
    # waits for. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -PlanPath $PlanPath -Reason 'planSignedOff' | Out-Null
    # SCHEDULE-PASS-DUE-1: after the sign-off is saved, the five-minute pass
    # checks this run: it starts the next wave when one finishes. Never throws.
    Add-VmfRunScheduleDue -RunPath $RunPath -Reason 'planSignOff' | Out-Null

    [pscustomobject]@{
        Waves      = @($waves)
        ApprovedBy = $who.Identity
        PlanHash   = $planHash
        Note       = $Note
    }
}
