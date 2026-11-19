function New-VmfTargetAdvice {
    <#
    .SYNOPSIS
        ADVISOR-1: write the target options for every machine in a reviewed
        assessment - target-advice.json, beside it.
    .DESCRIPTION
        Microsoft's order is assess, then choose each machine's target, then
        group the machines into waves. This writes what the choice is made
        from: for each machine, each size series with its facts, whether this
        product supports it, and the option the machine starts on under each
        of the migration's two defaults.

        It runs in the ENGINE, because only the engine can read Azure's size
        catalog; the service loads no Az module. The service starts it when
        an assessment is approved, so the options are there when a person
        opens the next step.

        A region whose sizes cannot be read is recorded as not read, and its
        machines get no supported option. The document is still written, so
        the screen can say which region to read again.

        Safe to re-run: it replaces the document.
    .PARAMETER AssessmentPath
        The assessment.json of an approved assessment.
    .EXAMPLE
        New-VmfTargetAdvice -AssessmentPath ./runs/scan-1/assessment.json
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$AssessmentPath
    )

    $assessmentDir = Split-VmfStorePath -Path $AssessmentPath
    $manifest = Read-VmfStoreJson -RunPath $assessmentDir -RelPath 'run.json' -Depth 6
    if ($manifest -and [string]$manifest.kind -eq 'migration') {
        throw "'$($manifest.runId)' is a migration, not an assessment. The target options are made from an assessment."
    }
    # Asked before it is read: Read-VmfTextDocument throws on a missing local
    # file and returns nothing on the blob store (Approve-VmfAssessment).
    if (-not (Test-VmfStoreItem -RunPath $assessmentDir -RelPath 'assessment.json')) {
        throw "'$(Split-Path $assessmentDir -Leaf)' has not finished scanning yet - there are no machines to give target options."
    }
    $assessmentText = Read-VmfTextDocument -Path $AssessmentPath
    $assessment = $assessmentText | ConvertFrom-Json -Depth 24
    Assert-VmfSupportedAssessment -Assessment $assessment -Source $AssessmentPath

    # The same gate, and the same sentence, as planning: the options are the
    # first step of planning, and they are made from what somebody reviewed.
    $approval = Read-VmfStoreJson -RunPath $assessmentDir -RelPath 'approval.json' -Depth 6
    if (-not $approval) {
        throw ("Assessment '$([string]$assessment.runId)' has not been reviewed. Somebody has to read what it " +
               'found and approve it before a migration can be planned from it - open it on the Assessments page.')
    }

    # ID-ADDRESS-1 part 3: one catalog read per subscription and region, and
    # each machine's options made from its own subscription's sizes.
    $vms = @($assessment.vms | Where-Object { $_ })
    $keysNotRead = [System.Collections.Generic.List[string]]::new()
    $readErrors = @{}
    $catalogs = Read-VmfMachineCatalogs -Machines $vms -IdProperty 'vmId' -RunPath $assessmentDir -NotRead $keysNotRead -NotReadReason $readErrors
    foreach ($key in $keysNotRead) {
        $sub, $loc = $key -split '\|', 2
        Write-Warning ("The sizes Azure offers in $loc could not be read" +
            $(if ($sub) { " for subscription $sub" } else { '' }) + ': ' + [string]$readErrors[$key])
    }
    $notRead = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $keysNotRead) {
        $loc = ($key -split '\|', 2)[1]
        if (-not $notRead.Contains($loc)) { $notRead.Add($loc) }
    }

    # Get-VmfTargetAdvice takes one catalog per region, so it is asked once for
    # each subscription's machines, and the answers are put back together in
    # the order of the scan.
    $groups = [ordered]@{}
    foreach ($vm in $vms) {
        $sub = [string](Get-VmfSubscriptionId -ResourceId ([string]$vm.vmId))
        $sub = $sub.ToLowerInvariant()
        if (-not $groups.Contains($sub)) { $groups[$sub] = [System.Collections.Generic.List[object]]::new() }
        $groups[$sub].Add($vm)
    }
    $parts = foreach ($sub in @($groups.Keys)) {
        $part = [pscustomobject]@{}
        foreach ($pr in $assessment.PSObject.Properties) { $part | Add-Member -NotePropertyName $pr.Name -NotePropertyValue $pr.Value }
        $part.vms = @($groups[$sub])
        $byLocation = @{}
        $partNotRead = @()
        foreach ($loc in @($groups[$sub] | ForEach-Object { [string]$_.location } | Sort-Object -Unique)) {
            $key = Get-VmfCatalogKey -VmId ([string]$groups[$sub][0].vmId) -Location $loc
            if ($catalogs.ContainsKey($key)) { $byLocation[$loc] = $catalogs[$key] } else { $partNotRead += $loc }
        }
        Get-VmfTargetAdvice -Assessment $part -CatalogByLocation $byLocation -RegionsNotRead $partNotRead
    }
    $parts = @($parts)
    $advice = if (-not $parts.Count) { Get-VmfTargetAdvice -Assessment $assessment }
    elseif ($parts.Count -eq 1) { $parts[0] }
    else {
        $byVm = @{}
        foreach ($p in $parts) { foreach ($m in @($p.machines)) { $byVm[[string]$m.vmId] = $m } }
        # A region is read only when every subscription with machines there read it.
        $regionRead = [ordered]@{}
        foreach ($p in $parts) {
            foreach ($r in @($p.regions)) {
                $loc = [string]$r.location
                $regionRead[$loc] = [bool]$r.read -and $(if ($regionRead.Contains($loc)) { $regionRead[$loc] } else { $true })
            }
        }
        $merged = $parts[0]
        $merged.regions = @(foreach ($loc in @($vms | ForEach-Object { [string]$_.location } | Sort-Object -Unique)) {
                [ordered]@{ location = $loc; read = [bool]$regionRead[$loc] } })
        $merged.machines = @(foreach ($vm in $vms) { $byVm[[string]$vm.vmId] })
        $merged
    }

    # Bound to the text that was reviewed, as the approval is. A screen that
    # finds a different hash knows the options were made from another scan.
    # PLANVER-2: one implementation of the hash.
    $advice.assessmentHash = Get-VmfDocumentVersion -Text $assessmentText

    Write-VmfStoreJson -RunPath $assessmentDir -RelPath 'target-advice.json' -Document $advice -Depth 12

    $machines = @($advice.machines)
    # REBUILD-REMOVE-PLAN-1: no machine waits for a choice (decide) any more,
    # so a machine with a supported target has a start.
    $withTarget = @($machines | Where-Object { $_.start.current -or $_.start.extended }).Count
    # STEP-LOG-4: written after the target options are saved, so a line that cannot be
    # written is a warning, never a failed command.
    Write-VmfStepLine -RunPath $assessmentDir -Step 'advice' -Outcome ok `
        -Detail ("Wrote the target options for {0} machine(s). {1} have a supported target.{2}" -f $machines.Count, $withTarget,
                 $(if ($notRead.Count) { " The sizes in $($notRead -join ', ') could not be read." } else { '' }))

    [pscustomobject]@{
        AdvicePath     = (Get-VmfStoreItemHandle -RunPath $assessmentDir -RelPath 'target-advice.json')
        Machines       = $machines.Count
        WithTarget     = $withTarget
        RegionsNotRead = @($notRead)
    }
}
