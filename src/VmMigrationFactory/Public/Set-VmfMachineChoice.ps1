function Set-VmfMachineChoice {
    <#
    .SYNOPSIS
        MACHINE-PICK-1: save which machines a migration moves -
        machine-choices.json, beside the reviewed assessment.
    .DESCRIPTION
        A scan of a resource group, a subscription or a management group finds
        every machine there, and many of them are not meant to move. Before
        this, every machine that could move went into the migration, and the
        only way to leave one out was to take it out of a wave.

        The list is the first step of the migrate flow, before the targets.
        Only a chosen machine may have a target (Set-VmfTargetChoice), and only
        chosen machines are planned (New-VmfPlan). The machines left out stay
        in the assessment and its report.

        A machine can be chosen only when the target options give it a
        supported series - the same facts the targets step shows, so the
        screen and this cannot disagree. Nothing is saved when any machine is
        refused.

        Two guards against saving over something unseen (PLANVER-2), as
        Set-VmfTargetChoice has them: the caller quotes back the versions the
        service issued with what it read - the target options, and the list
        already saved - and a version that no longer matches is refused with
        409. And the check and the write are one step
        (Write-VmfTextDocumentIfVersion, PLAN-WRITE-RACE-1), so a save that
        lands between them is refused, never overwritten.

        Store-only: it reads and writes the run store and calls no Azure API,
        so the service can run it.
    .PARAMETER Machines
        The vmId of each chosen machine, as the target options spell it.
    .PARAMETER ExpectedAdviceVersion
        The document version of target-advice.json the list was drawn from.
    .PARAMETER ExpectedChoiceVersion
        The document version of the machine-choices.json the page read, or
        empty when there was none.
    .PARAMETER OnBehalfOf
        @{ Identity; TenantId } of the signed-in user. The service passes it;
        a command-line caller omits it and gets their Azure sign-in.
    .EXAMPLE
        Set-VmfMachineChoice -RunPath ./runs/scan-1 -ExpectedAdviceVersion $v -Machines @($id1, $id2)
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Machines,
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedAdviceVersion,
        [Parameter()][AllowEmptyString()][string]$ExpectedChoiceVersion = '',
        [Parameter()][hashtable]$OnBehalfOf
    )

    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 6
    if ($manifest -and [string]$manifest.kind -eq 'migration') {
        throw "400: '$($manifest.runId)' is a migration, not an assessment. The machines are chosen on the assessment."
    }
    # Asked before it is read: Read-VmfTextDocument throws on a missing file.
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'target-advice.json')) {
        throw '400: The target options for this assessment are not written yet. They are made when the review is approved; start them again if they did not appear.'
    }
    $adviceText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'target-advice.json')
    if ((Get-VmfDocumentVersion -Text $adviceText) -ne $ExpectedAdviceVersion) {
        throw '409: The target options changed since this page read them. Load the page again, then choose the machines again.'
    }
    $advice = $adviceText | ConvertFrom-Json -Depth 30
    if ([int]$advice.schemaVersion -ne (Get-VmfTargetAdviceSchemaVersion)) {
        throw '409: These target options were made by an older version. Make the target options again, then choose the machines.'
    }

    $existingVersion = ''
    $existingBy = 'somebody'
    $handle = Get-VmfStoreItemHandle -RunPath $RunPath -RelPath 'machine-choices.json'
    if (Test-VmfStoreItem -RunPath $RunPath -RelPath 'machine-choices.json') {
        $existingText = Read-VmfTextDocument -Path $handle
        $existingVersion = Get-VmfDocumentVersion -Text $existingText
        $existingBy = [string](($existingText | ConvertFrom-Json -Depth 10).savedBy.identity)
    }
    if ($existingVersion -ne $ExpectedChoiceVersion) {
        throw "409: $existingBy saved the machines after this page read them. Load the page again to see them."
    }

    if (-not @($Machines).Count) {
        throw '400: Choose at least one machine for this migration.'
    }
    # Machine ids keep the letter case of the assessment (VMID-CASE-1); a
    # hashtable here, as in Set-VmfTargetChoice, so a case difference cannot
    # make one machine two.
    $byId = @{}
    foreach ($m in @($advice.machines)) { $byId[[string]$m.vmId] = $m }
    $seen = @{}
    $chosen = foreach ($id in @($Machines)) {
        $machine = $byId[[string]$id]
        if (-not $machine) { throw "400: The machine '$id' is not in this assessment." }
        if ($seen.ContainsKey([string]$id)) { throw "400: The machine '$($machine.name)' is named more than once." }
        $seen[[string]$id] = $true
        # ALREADY-CURRENT-1 (2026-11-06): a machine whose size Microsoft
        # puts in the Current lifecycle stage is not selectable to migrate. The
        # stage is the options' own (sourceStage, Get-VmfAdviceStage); the page
        # ticks by the same rule (canChoose in wizard.js).
        if ($machine.PSObject.Properties['sourceStage'] -and $machine.sourceStage -and [string]$machine.sourceStage.stage -eq 'Current') {
            throw "400: The machine '$($machine.name)' cannot be chosen. $($machine.sourceSize) is in the Current lifecycle stage."
        }
        # The rule the page ticks by: a supported series.
        $canMove = @(@($machine.options) | Where-Object { $_.supported }).Count -gt 0
        if (-not $canMove) {
            throw "400: The machine '$($machine.name)' cannot move on any size series, so it cannot be chosen. Its reasons are on the review."
        }
        # The id as the options spell it, not as the request did.
        [string]$machine.vmId
    }

    $who = if ($OnBehalfOf) { $OnBehalfOf } else { Get-VmfSignedInIdentity }
    $doc = [ordered]@{
        schemaVersion = 1
        assessmentId = [string]$advice.assessmentId
        assessmentHash = $advice.assessmentHash
        adviceVersion = $ExpectedAdviceVersion
        savedBy = [ordered]@{ identity = [string]$who.Identity; tenantId = $(if ($who.TenantId) { [string]$who.TenantId } else { $null }) }
        savedUtc = (Get-Date).ToUniversalTime().ToString('o')
        machines = @($chosen)
    }
    $raced = "409: Somebody saved the machines at the same time, so this list was not saved. Load the page again, then choose the machines again."
    if (-not $existingVersion) {
        # The first save: created only if nobody created it first.
        # STORE-CREATE-LOST-ANSWER-1: savedBy and savedUtc make the text this save's own.
        if (-not (Write-VmfStoreJsonExclusive -RunPath $RunPath -RelPath 'machine-choices.json' -Document $doc -UniqueText)) { throw $raced }
    }
    else {
        try {
            Write-VmfTextDocumentIfVersion -Path $handle -Content ($doc | ConvertTo-Json -Depth 10) -ExpectedVersion $existingVersion
        }
        catch {
            # The store's own 409 names the plan; this is the list of machines.
            if ("$_" -match '^409') { throw $raced }
            throw
        }
    }

    $total = @($advice.machines).Count
    # STEP-LOG-4: written after the list of machines is saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $RunPath -Step 'machines' -Outcome ok `
        -Detail ("{0} chose {1} of the {2} machine(s) in the assessment for this migration." -f $who.Identity, @($chosen).Count, $total)

    [pscustomobject]@{
        Chosen  = @($chosen).Count
        LeftOut = $total - @($chosen).Count
    }
}
