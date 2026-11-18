function Approve-VmfWave {
    <#
    .SYNOPSIS
        APPR-1: record an ENFORCED authorization for one wave to execute.
        The approval carries the approver's signed-in Entra identity (from
        their Azure login - never typed), the plan version the approver was
        shown, and the version of THIS WAVE (WAVE-APPROVE-1: its machines and
        settings, Get-VmfWaveVersion). Start-VmfWave refuses a requireApproval
        wave without a current approval; a change to this wave invalidates it,
        and a change to another wave does not.
    .DESCRIPTION
        Who may approve = who can WRITE to the run store (Storage Blob Data
        Contributor on the azblob backend). Viewers with Reader access
        physically cannot produce this document. This artifact is the Stage 3
        approval API resource - the future SPA approve action writes the same
        document through the facade.
    .EXAMPLE
        Approve-VmfWave -RunPath $run -PlanPath $planPath -Wave 'prod-1' `
            -Note 'canary-1 wave report reviewed with app owners; approved to proceed'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$Note,
        # S3-2: the facade approves ON BEHALF OF the validated browser user
        # (its own identity is a managed identity - stamping that would be a
        # lie). CLI callers omit this and get their signed-in Azure identity.
        [Parameter()][hashtable]$OnBehalfOf,
        # APPR-2: the hash of the plan the approver was SHOWN. The approval is
        # only worth something if it signs the plan on the approver's screen,
        # and this function reads plan.json when the call ARRIVES - up to a
        # refresh tick plus however long they spent typing later. In that gap a
        # Vmf.Operator may rewrite the wave with no approver involved, and the
        # signature would land on machines the approver never saw.
        # Optional on purpose: a person at a terminal approving from a plan
        # file they just read is not in this race. The facade REQUIRES it,
        # because the browser is where the race lives.
        [Parameter()][string]$ExpectedPlanHash
        # REBUILD-REMOVE-ACCEPT-1: -IdentityLossNamed is gone. No plan of this
        # version rebuilds a machine.
    )

    $planText = Read-VmfTextDocument -Path $PlanPath
    if (-not $planText) { throw "No plan found at '$PlanPath'." }
    $plan = $planText | ConvertFrom-Json -Depth 24
    if (-not (@($plan.entries) | Where-Object { $_.wave -eq $Wave })) {
        throw "Wave '$Wave' is not in the plan at '$PlanPath' - nothing to approve."
    }

    # PLANVER-2: one implementation, in Get-VmfDocumentVersion - see the note
    # on the sibling gate in Confirm-VmfWaveOptions.
    $planHash = Get-VmfDocumentVersion -Text $planText
    # WAVE-APPROVE-1: what the approval SIGNS is this wave alone - its machines
    # and its settings (Get-VmfWaveVersion) - from the same text whose plan
    # version is checked below. The check stays on the whole plan: the page
    # quotes the plan version it was shown (PLANVER-2), and an equal plan
    # version is an equal wave, so it can only refuse more.
    $waveVersion = Get-VmfWaveVersion -PlanText $planText -Wave $Wave

    # APPR-2: refuse BEFORE anything is written or logged. A mismatch is not an
    # error to recover from - it means the plan moved under the approver, so
    # the only safe answer is to sign nothing and say why.
    if ($ExpectedPlanHash -and $ExpectedPlanHash -ne $planHash) {
        # ACCEPT-EVIDENCE-1, the same on the sibling gate: a refusal that names
        # no evidence cannot be acted on.
        throw ("409: the plan changed after it was shown for approval, so nothing was approved. " +
            "The plan at '$PlanPath' now reads $(Get-VmfShortHash $planHash) and the caller sent $(Get-VmfShortHash $ExpectedPlanHash). " +
            "Look at wave '$Wave' again and approve it once you are content with it.")
    }


    # SQL-TEMPDB-SIGNOFF-1: the box for SQL Server and the temporary disk is on
    # the plan sign-off only. A wave approved on its own - after a change to the
    # wave, or a new target for a machine - is refused while it holds a machine
    # at risk that the plan sign-off does not name, so the change cannot pass
    # the box. Only a machine where the scan found SQL Server can be at risk.
    $sqlAtRisk = @(Get-VmfSqlTempdbRiskEntries -Entries @($plan.entries) -Wave $Wave)
    if ($sqlAtRisk.Count) {
        $signed = Read-VmfStoreJson -RunPath $RunPath -RelPath 'plan-approval.json' -Depth 6
        $named = if ($signed -and $signed.PSObject.Properties['sqlTempdbChecked']) { @($signed.sqlTempdbChecked) } else { @() }
        $sqlMissing = @(Get-VmfSqlTempdbMissing -AtRisk $sqlAtRisk -Checked $named)
        if ($sqlMissing.Count) {
            throw ("400: SQL Server runs on $(Get-VmfSqlTempdbNames -Entries $sqlMissing) in wave $Wave. " +
                'The target size of each has an NVMe temporary disk or no temporary disk. ' +
                'On the Run it step, tick "I checked where tempdb is on each of these machines." Then sign off the plan again.')
        }
    }

    $who = if ($OnBehalfOf) { $OnBehalfOf } else { Get-VmfSignedInIdentity }
    $doc = [ordered]@{
        schemaVersion = (Get-VmfWaveApprovalSchemaVersion)
        runId       = [string]$plan.assessmentRunId
        wave        = $Wave
        approvedBy  = [ordered]@{ identity = $who.Identity; tenantId = $who.TenantId }
        approvedUtc = (Get-Date).ToUniversalTime().ToString('o')
        planHash    = $planHash
        waveVersion = $waveVersion
        note        = $Note
        # OLD-VERSION-READERS-REMOVE-1 (v5): no identityLoss, in the contract either.
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath "approvals/$Wave.json" -Document $doc -Depth 6
    # STEP-LOG-4: written after the approval is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'approval' -Outcome ok `
        -Detail "wave $Wave approved by $($who.Identity): $Note"
    # APPROVE-GROUP-1: the list on the Migrations page says what the next wave
    # waits for. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -PlanPath $PlanPath -Reason 'waveApproved' | Out-Null

    [pscustomobject]@{
        Wave        = $Wave
        ApprovedBy  = $who.Identity
        PlanHash    = $planHash
        WaveVersion = $waveVersion
        Note        = $Note
    }
}
