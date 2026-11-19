function Approve-VmfAssessment {
    <#
    .SYNOPSIS
        ASSESS-PAGE-1: record that an assessment has been reviewed, so a
        migration may be planned from it.
    .DESCRIPTION
        As in Azure Migrate, an assessment (a report) is required before any
        migration. After the report is reviewed and approved, and everything
        is validated, it becomes a run.

        `New-VmfPlan` refuses an assessment that has not been approved, so this
        is the gate rather than a formality. It is deliberately the same shape
        as `Approve-VmfWave`: the identity comes from the approver's own
        sign-in and is never typed, a reason is required, and the decision is
        bound by hash to the exact document that was read.

        APPROVING AN ASSESSMENT WITH BLOCKED MACHINES IS ALLOWED, and the count
        is recorded. "Migrate the eighty that can move and deal with the twenty
        later" is the normal answer, not an error - but the record should say
        the blocked machines were known about rather than leaving somebody to
        infer it from timestamps.
    .EXAMPLE
        Approve-VmfAssessment -RunPath $assessment -Note 'reviewed with the app owners'
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        # OPTIONAL, deliberately. A required "what did you conclude" box had no
        # point - a compulsory free-text riddle between a person and
        # the next step. This gate only unlocks PLANNING; nothing is touched by
        # approving. The gate that authorises deleting and rebuilding machines
        # is the WAVE approval, and that still requires a reason.
        [Parameter()][AllowEmptyString()][string]$Note = '',
        # The facade approves ON BEHALF OF the validated browser user - its own
        # identity is a managed identity, and stamping that would be a lie.
        # Command-line callers omit this and get their signed-in Azure identity.
        [Parameter()][hashtable]$OnBehalfOf
    )

    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    if (-not $manifest) { throw "No assessment at '$RunPath'." }
    if ([string]$manifest.kind -eq 'migration') {
        throw "'$($manifest.runId)' is a migration, not an assessment. Migrations are approved per wave."
    }

    # Asked before it is read: Read-VmfTextDocument THROWS on a missing file,
    # so checking the result for emptiness never ran and the caller got "cannot
    # find path" instead of the sentence written for them.
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'assessment.json')) {
        throw "'$($manifest.runId)' has not finished scanning yet - there is nothing to review."
    }
    $assessmentText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'assessment.json')
    if (-not $assessmentText) {
        throw "'$($manifest.runId)' has not finished scanning yet - there is nothing to review."
    }
    $assessment = $assessmentText | ConvertFrom-Json -Depth 24

    # PLANVER-2: one implementation of the hash - the same bytes and algorithm
    # this used to write out here, so no approval already stored changes.
    $hash = Get-VmfDocumentVersion -Text $assessmentText

    $blocked = @($assessment.vms | Where-Object { $_.classification -eq 'Blocked' }).Count
    $who = if ($OnBehalfOf) { $OnBehalfOf } else { Get-VmfSignedInIdentity }

    $doc = [ordered]@{
        schemaVersion     = 1
        assessmentId      = [string]$manifest.runId
        approvedBy        = [ordered]@{ identity = $who.Identity; tenantId = $who.TenantId }
        approvedUtc       = (Get-Date).ToUniversalTime().ToString('o')
        assessmentHash    = $hash
        note              = $Note
        blockedAtApproval = $blocked
    }
    Write-VmfStoreJson -RunPath $RunPath -RelPath 'approval.json' -Document $doc -Depth 6
    # STEP-LOG-4: written after the approval is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'approval' -Outcome ok `
        -Detail "assessment approved by $($who.Identity): $Note$(if ($blocked) { " (the scan blocked $blocked machine(s) for at least one size series)" })"

    [pscustomobject]@{
        AssessmentId   = [string]$manifest.runId
        ApprovedBy     = $who.Identity
        AssessmentHash = $hash
        Blocked        = $blocked
        Note           = $Note
    }
}
