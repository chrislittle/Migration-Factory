# DECIDE-KEEP-1: a decision keeps the wave's acceptance and the plan sign-off.
#
# A decision with a setting change writes that setting into ONE machine's plan
# entry. The wave-options acceptance is bound to a hash of the wave's entries,
# and the plan sign-off to the plan's document version, so the write used to
# void both: the engine refused the wave, the sign-off stopped counting, and
# the page - which trusts an acceptance file that exists - offered no way to
# accept again. Found by the first end-to-end run of ADVISOR-1.
#
# A decision is itself a named, audited approval of exactly one change. So a
# record that was CURRENT just before the decision is moved to the plan as it
# is after it, with the decision written on the record. A record that was
# already out of date stays out of date: a decision never covers an edit
# nobody accepted.
#
# WAVE-APPROVE-1: the wave's own approval is carried too, for an approver's
# acceptance of the one decision the machine waits for and nothing else - and a
# v3 plan sign-off moves only with it (see below).
#
# DECIDE-CARRY-RACE-1: each record is written back only over the text the
# carry read (Write-VmfStoreTextIfVersion, PLANVER-2 versions: If-Match on blob
# storage, the lock file on the file backend). The write used to be an
# ordinary one, so an approval, an acceptance or a sign-off given between the
# read and the write was replaced by the older record. A record that changed is
# left as it is and named (Left, and a warn line in the run history).

function Invoke-VmfDecisionCarryForward {
    <#
    .SYNOPSIS
        Move the wave's acceptance and the plan sign-off past one decision,
        if each was current immediately before it.
    .PARAMETER Before
        What Get-VmfDecisionSnapshot returned BEFORE the plan was written.
    .PARAMETER AfterText
        PLAN-WRITE-RACE-1: the text the decision WROTE. Reading the plan again
        instead could read another writer's plan, and move the sign-off onto a
        change nobody approved.
    .OUTPUTS
        @{ Acceptance = $true|$false; SignOff = $true|$false; Approval = $true|$false; Left = @(acceptance|approval|signOff) }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Change,
        [Parameter(Mandatory)][string]$ResolvedBy,
        [Parameter()][string]$AfterText,
        # WAVE-APPROVE-1: an approver accepted the one decision the machine
        # waits for (Resolve-VmfDecision decides it). Only then is the wave's
        # approval carried; any other change asks for it again.
        [Parameter()][switch]$CarryWaveApproval,
        # DECIDE-CARRY-KILL-1: the time of the decision, when a later call
        # finishes a carry that stopped. The amendment then names when the
        # decision was made, not when the carry was finished.
        [Parameter()][string]$DecidedUtc
    )
    $after = if ($AfterText) { Get-VmfDecisionSnapshot -Text $AfterText -Wave $Before.Wave }
             else { Get-VmfDecisionSnapshot -PlanPath $PlanPath -Wave $Before.Wave }
    $amendment = [ordered]@{
        by     = $ResolvedBy
        utc    = $(if ($DecidedUtc) { $DecidedUtc } else { (Get-Date).ToUniversalTime().ToString('o') })
        vmId   = $VmId
        change = $Change
        reason = 'decision'
    }
    $result = @{ Acceptance = $false; SignOff = $false; Approval = $false; Left = @() }

    # DECIDE-CARRY-RACE-1: the records the carry found changed when it wrote,
    # and so left as they are.
    $left = [System.Collections.Generic.List[string]]::new()

    # ACCEPT-NAME-1: the file the wave's acceptance is in, never a file of
    # another wave whose name cleans to the same text.
    $accRel = Resolve-VmfWaveOptionsAcceptancePath -Wave $Before.Wave
    $accRead = Read-VmfCarryRecord -RunPath $RunPath -RelPath $accRel -Depth 24
    $acc = $accRead.Document
    if ($acc -and [string]$acc.optionsHash -eq $Before.OptionsHash -and $Before.OptionsHash -ne $after.OptionsHash) {
        Add-VmfAmendment -Document $acc -Amendment $amendment -Version (Get-VmfWaveOptionsAcceptanceSchemaVersion)
        $acc.optionsHash = $after.OptionsHash
        if (Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath $accRel -Content ($acc | ConvertTo-Json -Depth 24) -ExpectedVersion $accRead.Version) {
            $result.Acceptance = $true
        }
        else { $left.Add('acceptance') }
    }

    # WAVE-APPROVE-1: and the wave's own approval - but only for an APPROVER's
    # acceptance of the one decision the machine waits for (-CarryWaveApproval,
    # DECIDE-ROLE-1's single decision). That is itself a named, audited
    # approval of exactly this change. Any other decision - an operator's, or
    # another setting - changes the wave with no approver looking, so the wave
    # asks again for its approval, as every other change to a wave does. A
    # wave approval signs its wave, so every other wave's still matches.
    $apRel = "approvals/$($Before.Wave).json"
    $apRead = $null
    if ($CarryWaveApproval) { $apRead = Read-VmfCarryRecord -RunPath $RunPath -RelPath $apRel -Depth 8 }
    $ap = if ($apRead) { $apRead.Document } else { $null }
    if ($ap -and (Test-VmfWaveApprovalCurrent -Approval $ap -Wave $Before.Wave -WaveVersion $Before.WaveVersion) -and
        -not [string]::Equals($Before.WaveVersion, $after.WaveVersion, [System.StringComparison]::Ordinal)) {
        Add-VmfAmendment -Document $ap -Amendment $amendment -Version (Get-VmfWaveApprovalSchemaVersion)
        $ap | Add-Member -NotePropertyName waveVersion -NotePropertyValue $after.WaveVersion -Force
        # DECIDE-CARRY-RACE-1: an approval given since the read stays as its
        # approver wrote it. Safe to leave: the engine judges the stored
        # approval against the stored plan (Remove-VmfStaleWaveApprovals, then
        # the start gate), so one that does not sign the wave with this
        # decision in it is removed, and the wave cannot start on it.
        if (Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath $apRel -Content ($ap | ConvertTo-Json -Depth 8) -ExpectedVersion $apRead.Version) {
            $result.Approval = $true
        }
        else { $left.Add('approval') }
    }

    $paRead = Read-VmfCarryRecord -RunPath $RunPath -RelPath 'plan-approval.json' -Depth 8
    $pa = $paRead.Document
    # WAVE-APPROVE-1 (second review, the rule of 2026-10-10): a sign-off
    # of THIS plan passes every wave at the approval gate (Test-VmfWaveApproval).
    # Moved past an operator's decision, a v3 sign-off passed the decided wave
    # with its approval removed, and the timer started it with no approver
    # looking. So a v3 sign-off moves only together with the wave's approval -
    # an approver's decision. Any other decision asks again for the wave's
    # approval; the v3 sign-off stays the consent to run on without being moved
    # (Test-VmfPlanRunConsent). A call with no roles (PowerShell) never carries.
    # MIGRATIONS-PAGE-OLD-READERS-1, SQL-TEMPDB-SIGNOFF-1: Approve-VmfPlan writes
    # only v4 (Get-VmfPlanApprovalSchemaVersion), which keeps the v3 rule of one
    # approval per wave, so every sign-off is one.
    $carrySignOff = [bool]$CarryWaveApproval
    if ($pa -and $carrySignOff -and [string]$pa.planHash -eq $Before.PlanVersion -and $Before.PlanVersion -ne $after.PlanVersion) {
        Add-VmfAmendment -Document $pa -Amendment $amendment -Version (Get-VmfPlanApprovalSchemaVersion)
        $pa.planHash = $after.PlanVersion
        if (Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath 'plan-approval.json' -Content ($pa | ConvertTo-Json -Depth 8) -ExpectedVersion $paRead.Version) {
            $result.SignOff = $true
        }
        else { $left.Add('signOff') }
    }

    if ($result.Acceptance -or $result.SignOff -or $result.Approval) {
        $kept = @($(if ($result.Acceptance) { "the accepted options of wave $($Before.Wave)" }),
            $(if ($result.Approval) { "the approval of wave $($Before.Wave)" }), $(if ($result.SignOff) { 'the plan sign-off' }) |
            Where-Object { $_ }) -join ' and '
        # STEP-LOG-2: the plan, the acceptance and the sign-off are written. A
        # line that cannot be written must not stop the decision part way.
        Write-VmfStepLine -RunPath $RunPath -Step 'decision' -Outcome info -VmId $VmId `
            -Detail "$ResolvedBy changed $Change for this machine. That decision is recorded on $kept, which still stand."
    }
    # DECIDE-CARRY-RACE-1: a record left as it is is said, one line each. The
    # decision itself is saved; the start gate judges the record as stored.
    foreach ($code in $left) {
        $what = switch ($code) {
            'acceptance' { "The accepted settings of wave $($Before.Wave)" }
            'approval' { "The approval of wave $($Before.Wave)" }
            default { 'The plan sign-off' }
        }
        Write-VmfStepLine -RunPath $RunPath -Step 'decision' -Outcome warn -VmId $VmId `
            -Detail "$what changed while the product saved this decision. The product kept it as it is and did not record the decision on it."
    }
    $result.Left = @($left)
    $result
}

function Read-VmfCarryRecord {
    <#
    .SYNOPSIS
        DECIDE-CARRY-RACE-1: one record the carry may move, with the version
        (PLANVER-2) of the stored text it was read from, so the write back is
        refused if anybody wrote the record in between. A record that cannot
        be read is not carried, as before.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$RelPath, [Parameter()][int]$Depth = 8)
    $text = $null
    try { $text = Read-VmfStoreText -RunPath $RunPath -RelPath $RelPath } catch { }
    $doc = $null
    if ($text) { try { $doc = $text | ConvertFrom-Json -Depth $Depth } catch { } }
    [pscustomobject]@{ Document = $doc; Version = $(if ($null -ne $text) { Get-VmfDocumentVersion -Text ([string]$text) } else { '' }) }
}

function Get-VmfDecisionSnapshot {
    <#
    .SYNOPSIS
        The two versions a decision can move: the wave's options hash and the
        plan's document version, read from the STORED plan text (PLANVER-2).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter()][string]$PlanPath, [Parameter(Mandatory)][string]$Wave, [Parameter()][string]$Text)
    # -Text: the exact text a caller read or wrote (PLAN-WRITE-RACE-1).
    $text = if ($Text) { $Text } else { Read-VmfTextDocument -Path $PlanPath }
    $plan = $text | ConvertFrom-Json -Depth 24
    [pscustomobject]@{
        Wave        = $Wave
        # ACCEPT-SET-1: the same entries every other caller hashes.
        OptionsHash = (Get-VmfWaveOptionsHash -Entries @(Get-VmfWaveOptionsEntries -Plan $plan -Wave $Wave))
        PlanVersion = (Get-VmfDocumentVersion -Text $text)
        # WAVE-APPROVE-1: what the wave's approval signs.
        WaveVersion = (Get-VmfWaveVersion -PlanText $text -Wave $Wave)
    }
}

function Add-VmfAmendment {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document, [Parameter(Mandatory)]$Amendment, [Parameter(Mandatory)][int]$Version)
    $list = @(if ($Document.PSObject.Properties['amendments']) { @($Document.amendments) }) + @([pscustomobject]$Amendment)
    $Document | Add-Member -NotePropertyName amendments -NotePropertyValue $list -Force
    $Document.schemaVersion = $Version
}

# DECIDE-CARRY-KILL-1: a stop between a decision's plan write and its carry.
#
# The plan write and the carry are separate writes. A process that stopped
# between them left the plan with the decision and the records signing the plan
# from before it: the wave could not start (safe), but the decision made again
# was refused by that gate, and the person had to accept the wave's settings
# and approve the wave again - the approver's record of exactly this change was
# lost.
#
# So the decision writes a note of the carry it is about to do BEFORE the plan
# write (decision-carry/<machine key>.json, schemas/decision-carry.schema.json)
# and removes it after the carry. The next decision call for the machine
# finishes the carry the note names, but only while the stored plan is still
# the exact text the stopped decision wrote (PLANVER-2: the note holds that
# text's version). The carry itself asks every record what it asks at any
# decision: it moves only a record that still signs the plan from before. A
# plan anybody wrote since is never signed by the note, and the note goes.

function Get-VmfDecisionCarryNotePath {
    <# .SYNOPSIS DECIDE-CARRY-KILL-1: where the note of one machine's carry is kept. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$VmId)
    "decision-carry/$(Get-VmfVmKey -VmId $VmId).json"
}

function New-VmfDecisionCarryNoteText {
    <#
    .SYNOPSIS
        DECIDE-CARRY-KILL-1: the note of the carry a decision is about to do,
        as the text written to the store (decision-carry schema v1).
    .PARAMETER Before
        What Get-VmfDecisionSnapshot returned for the text the decision read.
    .PARAMETER AfterText
        The plan text the decision is about to write.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)][string]$AfterText,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Change,
        [Parameter(Mandatory)][string]$ResolvedBy,
        [Parameter(Mandatory)][string]$DecidedUtc,
        [Parameter()][switch]$CarryWaveApproval
    )
    [ordered]@{
        schemaVersion     = 1
        vmId              = $VmId
        wave              = [string]$Before.Wave
        decidedBy         = $ResolvedBy
        decidedUtc        = $DecidedUtc
        change            = $Change
        carryWaveApproval = [bool]$CarryWaveApproval
        before            = [ordered]@{
            optionsHash = [string]$Before.OptionsHash
            planVersion = [string]$Before.PlanVersion
            waveVersion = [string]$Before.WaveVersion
        }
        afterPlanVersion  = (Get-VmfDocumentVersion -Text $AfterText)
    } | ConvertTo-Json -Depth 4
}

function Complete-VmfPendingDecisionCarry {
    <#
    .SYNOPSIS
        DECIDE-CARRY-KILL-1: finish the carry of a decision whose process
        stopped after its plan write, and remove the note.
    .DESCRIPTION
        Carries only while the stored plan is the exact text the stopped
        decision wrote. Any other plan - the write never landed, or somebody
        wrote the plan since - is not signed by the note, which is removed.
        Safe to call again: a carry already done finds every record signing
        the plan after the decision and moves nothing.
    .OUTPUTS
        The carry's result (see Invoke-VmfDecisionCarryForward) with DecidedBy
        and Change of the decision, or $null when there was no carry to finish.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$PlanPath,
        [Parameter(Mandatory)][string]$VmId
    )
    $rel = Get-VmfDecisionCarryNotePath -VmId $VmId
    $text = $null
    try { $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel } catch { }
    if (-not $text) { return $null }
    $note = $null
    try { $note = $text | ConvertFrom-Json -Depth 6 -DateKind String } catch { }
    $result = $null
    $planText = Read-VmfTextDocument -Path $PlanPath
    # A note of another version is never read: it is removed, not carried.
    if ($note -and [string]$note.schemaVersion -eq '1' -and $planText -and $note.before -and
        [string]::Equals((Get-VmfDocumentVersion -Text $planText), [string]$note.afterPlanVersion, [System.StringComparison]::Ordinal)) {
        $before = [pscustomobject]@{
            Wave        = [string]$note.wave
            OptionsHash = [string]$note.before.optionsHash
            PlanVersion = [string]$note.before.planVersion
            WaveVersion = [string]$note.before.waveVersion
        }
        $result = Invoke-VmfDecisionCarryForward -RunPath $RunPath -PlanPath $PlanPath -Before $before -AfterText $planText -VmId $VmId `
            -Change ([string]$note.change) -ResolvedBy ([string]$note.decidedBy) -CarryWaveApproval:([bool]$note.carryWaveApproval) `
            -DecidedUtc ([string]$note.decidedUtc)
        # For the machine's history, which the machine panel shows in full.
        $result.DecidedBy = [string]$note.decidedBy
        $result.Change = [string]$note.change
        Write-VmfStepLine -RunPath $RunPath -Step 'decision' -Outcome info -VmId $VmId `
            -Detail "The product stopped before it completed the save of the decision by $([string]$note.decidedBy) ($([string]$note.change)). The product completed that save now."
    }
    # Only the note this call read: a note another decision wrote since stays.
    [void](Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text ([string]$text)))
    $result
}