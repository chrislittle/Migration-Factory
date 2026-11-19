function Confirm-VmfWaveOptions {
    <#
    .SYNOPSIS
        WAVE-2: record that a named person reviewed and accepted a wave's
        policy levers. The engine refuses to start a wave without this.
    .DESCRIPTION
        The rule: for every wave created, a user must select the options.
        Defaults can be set, but they must be clicked and accepted.

        Defaults exist (one safe set, Get-VmfDefaultWavePolicy) but a default
        nobody looked at is a decision nobody made. So acceptance is a
        first-class contract artifact: who, when, and a HASH over the wave's
        membership and levers - so editing a policy or adding a machine AFTER
        acceptance invalidates it, the same way a changed plan invalidates its
        approval. Re-accept after any change; the engine says exactly that.

        Acceptance is not approval. Approval (requireApproval) is a sign-off
        lever a wave may or may not carry; acceptance is universal - every
        wave, always, because it is what makes the levers CHOSEN rather than
        inherited.
    .EXAMPLE
        Confirm-VmfWaveOptions -RunPath $run -PlanPath $plan -Wave 'first-five' -AcceptedBy 'operator@example.com'
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$AcceptedBy,
        [Parameter()][string]$Note,
        # ACCEPT-HASH-1: the hash of the plan the person was SHOWN. The same
        # gate APPR-2 put on approval, on the gate that matters more - approval
        # is a lever a wave may or may not carry, acceptance is universal.
        #
        # This function reads the plan when the call ARRIVES. The dialog that
        # lists the levers is drawn earlier, and in between a Vmf.Operator may
        # rewrite the wave. The record would then name a person as having
        # chosen settings they never saw, which is the one thing it exists to
        # prove they did.
        #
        # Optional on purpose, exactly as APPR-2 is: somebody at a terminal
        # accepting from a plan file they just read is not in this race. The
        # facade REQUIRES it, because the browser is where the race lives.
        [Parameter()][string]$ExpectedPlanHash
        # REBUILD-REMOVE-ACCEPT-1: -IdentityLossNamed and -RebuildNamed are
        # gone. No person accepts a rebuild or the loss of an identity any
        # more, and no plan of this version rebuilds a machine.
    )

    $ErrorActionPreference = 'Stop'
    # Read the bytes ONCE and hash those, then put them through the same
    # supported-plan gate Read-VmfPlanFile applies. Reading twice - once to
    # hash, once to parse - would leave a gap between the two reads, which is a
    # smaller copy of the defect being fixed.
    $planText = Read-VmfTextDocument -Path $PlanPath
    if (-not $planText) { throw "No plan found at '$PlanPath'." }
    $plan = ConvertTo-VmfSupportedPlan -Plan ($planText | ConvertFrom-Json -Depth 24) -Source $PlanPath

    # PLANVER-2: one implementation, in Get-VmfDocumentVersion. This was written
    # out here and in Approve-VmfWave, and a third copy was being asked of every
    # caller over HTTP - which is the defect that item exists for.
    $planHash = Get-VmfDocumentVersion -Text $planText

    # Refuse BEFORE anything is written or logged. A mismatch is not an error
    # to recover from - it means the plan moved under the person, so the only
    # safe answer is to record nothing and say why.
    if ($ExpectedPlanHash -and $ExpectedPlanHash -ne $planHash) {
        # ACCEPT-EVIDENCE-1: SAY WHAT WAS COMPARED. A refusal that names no
        # evidence cannot be acted on. "The plan moved under you" and "we
        # disagree about how to read the plan" produce the same sentence, and
        # only the first is solved by looking at the wave again. The flow drill
        # met this against a real install and the message could not tell them
        # apart. A plan version is not a secret - the caller computed one to
        # get here.
        throw ("409: the wave changed after its settings were shown, so nothing was accepted. " +
            "The plan at '$PlanPath' now reads $(Get-VmfShortHash $planHash) and the caller sent $(Get-VmfShortHash $ExpectedPlanHash). " +
            "Look at wave '$Wave' again and accept it once you are content with it.")
    }

    # ACCEPT-SET-1: the same entries the wave start checks - the machines that move.
    $entries = @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $Wave)
    if ($entries.Count -eq 0) { throw "400: No machine that moves is in wave '$Wave' - nothing to accept." }

    # SAFETYCOPY-CLEAN-1, MANUAL-REVIEW-1: an entry that does not ask for the
    # first safety copy holds a value the contract does not list, so the check
    # below refuses it.
    # OLD-VERSION-READERS-REMOVE-3: settings that hold a value the engine
    # does not know - PRECHECK refuses each such machine (policyNotKnown).
    $unknown = @($entries | Where-Object { Get-VmfPlanPolicyRefusal -PlanEntry $_ } |
        ForEach-Object { ([string]$_.vmId -split '/')[-1] })
    if ($unknown.Count -gt 0) {
        $named = @($unknown | Select-Object -First 10) -join ', '
        if ($unknown.Count -gt 10) { $named += " and $($unknown.Count - 10) more" }
        throw ("400: The plan for $named holds a setting value that this product does not know, so this product refuses to accept wave '$Wave'. " +
            'Plan these machines again with this product.')
    }


    $hash = Get-VmfWaveOptionsHash -Entries $entries

    # The record carries the LEVERS THEMSELVES, not just the hash: an
    # acceptance nobody can read back is a checkbox, not a decision. One
    # distinct policy set per row - most waves have exactly one.
    $leverSets = @($entries | ForEach-Object { $_.policy | ConvertTo-Json -Depth 8 -Compress } |
        Sort-Object -Unique | ForEach-Object { $_ | ConvertFrom-Json })

    if (-not $PSCmdlet.ShouldProcess($Wave, 'record the wave-options acceptance')) { return }

    # EVAL-L4: the record's whole purpose is to prove a NAMED person chose a
    # NAMED wave's settings in a NAMED run. Writing a blank identity produced
    # something that looks like that record and is not one, which is worse than
    # refusing - so refuse.
    $acceptedRunId = [string]$plan.assessmentRunId
    if ([string]::IsNullOrWhiteSpace($acceptedRunId)) {
        throw "This plan does not say which assessment run it came from (assessmentRunId is empty), so an acceptance recorded against it could not say what it belongs to. Re-plan from the assessment rather than accepting settings that cannot be traced."
    }

    $doc = [ordered]@{
        schemaVersion = (Get-VmfWaveOptionsAcceptanceSchemaVersion)
        # This read $plan.runId. A plan document has no runId - the field is
        # assessmentRunId - so every acceptance ever written recorded an empty
        # string. The sibling writer one file over (Approve-VmfWave) had it
        # right, which is why nothing looked twice.
        runId         = $acceptedRunId
        wave          = $Wave
        acceptedBy    = $AcceptedBy
        acceptedUtc   = (Get-Date).ToUniversalTime().ToString('o')
        machineCount  = $entries.Count
        optionsHash   = $hash
        levers        = $leverSets
        note          = $Note
        # OLD-VERSION-READERS-REMOVE-1 (v9): no identityLoss and no rebuild,
        # in the contract either.
    }
    # ACCEPT-NAME-1: the file this wave's acceptance is in - an earlier file
    # is written in place when it names this wave, so a wave never has two.
    # WRITE-DEPTH-OPEN-1: 24, because the schema's levers[] is open, and a
    # shallower write saves a deeper part as its type name, with only a warning.
    Write-VmfStoreJson -RunPath $RunPath -RelPath (Resolve-VmfWaveOptionsAcceptancePath -Wave $Wave) -Document $doc -Depth 24
    # STEP-LOG-4: written after the acceptance is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'acceptance' -Outcome ok `
        -Detail "wave '$Wave' options accepted by $AcceptedBy ($($entries.Count) machine(s))"
    # APPROVE-GROUP-1: the list on the Migrations page says what the next wave
    # waits for. Never throws.
    Update-VmfRunSummary -RunPath $RunPath -PlanPath $PlanPath -Reason 'optionsAccepted' | Out-Null
    [pscustomobject]$doc
}
