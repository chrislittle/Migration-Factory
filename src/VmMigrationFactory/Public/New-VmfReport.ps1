function New-VmfReport {
    <#
    .SYNOPSIS
        P2-5: render a migration into a single self-contained HTML report -
        the one report of the run, written to customer-report.html, which the
        Reports page opens.
    .DESCRIPTION
        REPORT-AUTO-1 (2026-10-02): ONE report. The engine writes it by
        itself when a wave finishes and when a machine is restored
        (Save-VmfRecordAndReport); nobody produces it and nobody chooses who it
        is for. The Operator report and its engineering appendix are gone, and
        every fact only the appendix held is in the migration record (v3).
        REPORT-WORDS-1 still holds: no engineering code reaches this report.
    .OUTPUTS
        Path to the generated customer-report.html.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$OutPath,
        [Parameter()][string]$Title = 'VM Migration Factory - Run Report',
        # REPORT-AUTO-1: the migration record the five main sections render,
        # when the caller has just kept it - so those sections and the kept
        # record are one set of facts. Without it, it is built here from the
        # store.
        [Parameter()][AllowNull()]$Record
    )

    function Encode([object]$Value) { [System.Net.WebUtility]::HtmlEncode([string]$Value) }
    # REPORT-RELEASED-1: every time a person reads is written as ISO UTC
    # (ConvertTo-VmfIsoUtc); [string] of a parsed date is month-first.

    $assessment = Read-VmfStoreJson -RunPath $OutPath -RelPath 'assessment.json'
    $claims = @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $OutPath -RelPath "capacity/$_" -Depth 12 })
    # REPORT-RELEASED-1: released reservations whose records were cleared - a
    # wave changed, or its quota was checked again. They billed; the capacity
    # table keeps them. Not quota records, so that table does not list them.
    # A history record whose reservation a live claim still shows is that
    # claim - it is not shown twice.
    $liveReservations = @($claims | Where-Object { $_ -and $_.PSObject.Properties['reservation'] -and $_.reservation -and $_.reservation.reservationId } |
        ForEach-Object { [string]$_.reservation.reservationId })
    $releasedHistory = @(Get-VmfStoreNames -RunPath $OutPath -Folder 'capacity-history' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $OutPath -RelPath "capacity-history/$_" } |
        Where-Object { $_ -and $_.PSObject.Properties['claim'] -and $_.claim } | ForEach-Object { $_.claim } |
        Where-Object { -not ($_.PSObject.Properties['reservation'] -and $_.reservation -and [string]$_.reservation.reservationId -in $liveReservations) })
    $stateDocs = @(Get-VmfStoreNames -RunPath $OutPath -Folder 'state' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $OutPath -RelPath "state/$_" })

    $sb = [System.Text.StringBuilder]::new()
    # VERIFY-FP-1 part 3b: the report style chosen on 2026-09-28 (Style A).
    # One file, nothing external: it opens in a sandboxed frame and is
    # downloaded as it is.
    # REPORT-AUTO-1: stored with NO theme mark (2026-10-02: the person's
    # theme is honoured everywhere). No person wrote it, so no person's choice
    # belongs on it: opened outside the product it follows the reader's own
    # system through the stylesheet; the Reports page marks it with the
    # dashboard's theme before it shows it.
    $null = $sb.AppendLine(@"
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8">
<title>$(Encode $Title)</title>
<style>$script:VmfReportCss</style></head><body>
"@)

    $pillFor = @{
        ReadyAfterPrep = 'info'; Blocked = 'bad'; Excluded = 'warn'; NotChosen = 'warn'
        MIGRATED = 'ok'; NEEDS_DECISION = 'warn'; SKIPPED = 'warn'
        FAILED_ROLLED_BACK = 'bad'; FAILED_NEEDS_ATTENTION = 'bad'
        QUOTA_VERIFIED = 'ok'; QUOTA_REQUESTED = 'info'; RESERVED = 'ok'
        A = 'info'; B = 'info'; C = 'info'; MANUAL = 'warn'
        # 'Excluded' above also covers path 'EXCLUDED' - hashtable keys are case-insensitive
        # BLOCKED-NAME-1: and 'Blocked' above covers the quota record's own
        # BLOCKED state for the same reason. Adding it a second time is a
        # parse error, not a duplicate that quietly wins - found that way.
    }
    function Pill([string]$Value) {
        $cls = if ($pillFor.ContainsKey($Value)) { $pillFor[$Value] } else { 'info' }
        "<span class='pill $cls'>$(Encode $Value)</span>"
    }

    # The report's five main sections render the migration record, so they say
    # what the kept record says. The follow-up sections below (infrastructure
    # code, replaced identities, capacity, what the scan could not read) are
    # read from the run's own documents here, at the same moment.
    # A run with no manifest (a store written before one existed) gets the
    # cover and the sections below only.
    # An assessment has a manifest too, and is not a migration.
    $recordProblem = $null
    $manifest = if (Test-VmfStoreItem -RunPath $OutPath -RelPath 'run.json') { Read-VmfStoreJson -RunPath $OutPath -RelPath 'run.json' -Depth 8 } else { $null }
    # RETAIN-KIND-1: the one rule for what a run is.
    if (-not $Record -and (Get-VmfRunKind -Manifest $manifest) -eq 'migration') {
        # Built, not kept: the reason is the record's and is not rendered here.
        try { $Record = Get-VmfMigrationRecordFromStore -RunPath $OutPath -Reason 'downloaded' -GeneratedBy 'the engine' }
        catch {
            $recordProblem = $_.Exception.Message
            # STEP-LOG-4: a line that cannot be written never stops the report.
            Write-VmfStepLine -RunPath $OutPath -Step 'report' -Outcome warn -Detail "The product could not build the migration record for the report: $recordProblem"
        }
    }
    $givenTitle = if ($PSBoundParameters.ContainsKey('Title')) { $Title } else { $null }
    if ($Record) {
        $null = $sb.Append((ConvertTo-VmfReportHtml -Record $Record -Title $givenTitle))
    }
    else {
        $null = $sb.AppendLine("<div class=`"sheet`"><header class=`"cover`"><div class=`"brandline`">$script:VmfReportLogo Migration Factory</div><h1>$(Encode $Title)</h1></header>")
        if ($recordProblem) {
            $null = $sb.AppendLine("<p><strong>The product could not build the summary of this migration.</strong> The sections below are read from the run directly. The reason: $(Encode $recordProblem)</p>")
        }
    }

    # ---- What changed that a definition in code holds (IAC-REPORT-1) ----
    #
    # For EVERY machine the product changed (2026-09-29): whether a
    # customer defines machines in code is theirs to know. The facts are
    # Get-VmfIacStatement's, read from what the product recorded.
    $iacRows = @(Get-VmfIacChangeRows -StateDocs $stateDocs)
    if ($iacRows.Count -gt 0) {
        $null = $sb.AppendLine('<h2>Changes to match in your infrastructure code</h2>')
        $null = $sb.AppendLine('<p>If Terraform, Bicep or another tool defines these machines, change each definition to these values before its next apply. The product does not change your code.</p>')
        $null = $sb.AppendLine('<table><tr><th>Machine</th><th>Size</th><th>Disk controller</th><th>Accelerated networking</th><th>Disks</th></tr>')
        foreach ($row in $iacRows) {
            # SEC-REPORT-1: every cell through Encode, composed or not.
            $null = $sb.AppendLine("<tr><td>$(Encode $row.name)</td><td>$(Encode $row.size)</td><td>$(Encode $row.controller)</td><td>$(Encode $row.acceleratedNetworking)</td><td>$(Encode $row.disks)</td></tr>")
        }
        $null = $sb.AppendLine('</table>')
    }

    # ---- Capacity and cost ----
    $waveClaims = @($claims) + @($releasedHistory)
    if ($waveClaims.Count -gt 0) {
        # From the LIVE claims: a family a wave moved away from (a target
        # changed) is history, not where the workloads went.
        $families = @($claims | ForEach-Object { $_.vmFamily } | Where-Object { $_ } | Sort-Object -Unique)
        # TERMS-AUDIT-1: "and", not "&"; the state in words, not QUOTA_VERIFIED;
        # and no count of reserved machines beside "no reservation".
        $null = $sb.AppendLine('<h2>Capacity and cost</h2>')
        $null = $sb.AppendLine('<table><tr><th>Size / region</th><th>Reserved</th><th>In an availability set</th><th>Used</th><th>Capacity reservation window</th><th>State</th></tr>')
        $anyAvsetDemand = $false
        $ownGroupMachines = [System.Collections.Generic.List[string]]::new()
        $stateWords = @{
            FORECAST = 'Planned'; QUOTA_VERIFIED = 'Quota checked'; QUOTA_REQUESTED = 'Quota increase requested'
            RESERVING = 'Reserving'; RESERVED = 'Reserved'; CONSUMED = 'In use'; RELEASED = 'Released'; BLOCKED = 'Blocked'
        }
        foreach ($claim in $waveClaims) {
            # SEC-REPORT-1: composed, so Encode goes on the parts.
            $held = $claim.PSObject.Properties['reservation'] -and $claim.reservation -and $claim.reservation.createdUtc
            # The two ends are read before the cell, so the word check reads
            # the cell and not a property name (MANUAL-REVIEW-1).
            $window = if ($held) {
                $madeAt = ConvertTo-VmfIsoUtc $claim.reservation.createdUtc
                $releasedAt = if ($claim.reservation.releasedUtc) { ConvertTo-VmfIsoUtc $claim.reservation.releasedUtc } else { 'Not released yet, and billed until it is' }
                "$(Encode $madeAt) &rarr; $(Encode $releasedAt)"
            } else { 'No capacity reservation' }
            $consumed = if ($claim.PSObject.Properties['reservation'] -and $claim.reservation) { $claim.reservation.consumedInstances } else { '-' }
            # CAP-2: the Reserved column carries the RESERVABLE count; a machine
            # in an availability set gets its own column, so the reduced
            # guarantee is visible to stakeholders, never buried. A claim with
            # no reservation reserved nothing, so it says so.
            $total = [int]$claim.demand.instances
            # New-VmfCapacityClaim always writes the reservable count
            # (OLD-VERSION-READERS-REMOVE-8).
            $reservable = [int]$claim.demand.reservableInstances
            # CRG-MOVE-DEMAND-1: a machine that stayed in its own capacity
            # reservation group is not in an availability set; it is named below.
            $ownHere = @(Get-VmfClaimOwnGroupVmIds -Claim $claim)
            foreach ($id in $ownHere) { if ($id -notin $ownGroupMachines) { $ownGroupMachines.Add($id) } }
            $general = [math]::Max(0, $total - $reservable - $ownHere.Count)
            if ($general -gt 0) { $anyAvsetDemand = $true }
            $generalCell = if ($general -gt 0) { "$general" } else { '-' }
            $reservedCell = if ($held) { "$reservable" } else { '-' }
            $state = [string]$claim.state
            $stateCls = if ($pillFor.ContainsKey($state)) { $pillFor[$state] } else { 'info' }
            $stateSaid = if ($stateWords.ContainsKey($state)) { $stateWords[$state] } else { $state }
            $null = $sb.AppendLine("<tr><td>$(Encode "$($claim.size) @ $($claim.region)")</td><td>$(Encode $reservedCell)</td><td>$(Encode $generalCell)</td><td>$(Encode $consumed)</td><td>$window</td><td><span class='pill $stateCls'>$(Encode $stateSaid)</span></td></tr>")
        }
        $null = $sb.AppendLine('</table>')
        if ($anyAvsetDemand) {
            $null = $sb.AppendLine('<p class="muted">Azure does not allow a capacity reservation for a machine in an availability set. Those machines moved with no capacity reservation. The product still checked the quota for them.</p>')
        }
        if ($ownGroupMachines.Count -gt 0) {
            $null = $sb.AppendLine("<p class=""muted"">These machines stayed in their own capacity reservation group, so the capacity reservation of the wave held no place for them: $(Encode ((@($ownGroupMachines | ForEach-Object { ($_ -split '/')[-1] })) -join ', ')).</p>")
        }
        if ($families.Count -gt 0) {
            # A live record exists from planning on, so the line says where the
            # target sizes are, not that the machines moved there.
            $null = $sb.AppendLine("<p><strong>Costs:</strong> The target sizes are in the quota families <em>$(Encode ($families -join ', '))</em>. An Azure Reservation covers only the sizes of its own instance size flexibility group. So a reservation for the old size does not cover the new size. An Azure savings plan for compute covers the new size too.</p>")
        }
    }

    # REPORT-GAP-1: what the scan asked for and did not get.
    #
    # Without this the report simply omits the subject, and a customer
    # reads an assessment with a hole in it and no way to know the hole is
    # there. A report that does not say what it could not measure is the
    # same defect as a check that reports a result it never took.
    #
    # Guarded on the property, not the value: an assessment written before
    # this field existed has no such member, and this module runs under
    # Set-StrictMode.
    $notRead = @()
    if ($assessment -and $assessment.PSObject.Properties['notRead']) { $notRead = @($assessment.notRead) }
    # REPORT-WORDS-1: what a report could not measure is never left out.
    # SCAN-PARTIAL-SUBS-1: the words are in ConvertTo-VmfNotReadReportHtml,
    # which also says which subscription was not read, why, and how to fix it.
    $notReadHtml = ConvertTo-VmfNotReadReportHtml -NotRead $notRead
    if ($notReadHtml) { $null = $sb.Append($notReadHtml) }

    # REPORT-AUTO-1: no appendix. The engineering detail it held - the
    # assessment of each machine, the plan's alternates and notes, the quota
    # records and each machine's checkpoint - is in the migration record (v3),
    # which administrators download from the Reports page. REPORT-WORDS-1:
    # no classification code, raw state or script name reaches this report.

    # REPORT-AUTO-1: no time of writing, so two writes of an unchanged
    # migration are the same file. The time shown is the newest one the record
    # holds - how current the report is, which a reader asks.
    $version = try { [string](Get-VmfVersion).number } catch { '' }
    $lastChange = if ($Record) { Get-VmfRecordLastChange -Record $Record } else { $null }
    $asOf = if ($lastChange) { " &middot; Last change recorded: $(Encode ($lastChange.ToString('d MMM yyyy, HH:mm', [cultureinfo]::InvariantCulture))) UTC" } else { '' }
    $null = $sb.AppendLine("<div class=`"foot`"><span>Migration Factory $(Encode $version)$asOf</span><span>Every reading for every machine is also in the migration record.</span></div>")
    # DISCLAIMER-1: a report leaves the app, and is read by people who never
    # saw the app. So it carries the short line, from the one file of words.
    $null = $sb.AppendLine("<p class=`"disclaimer`">$(Encode (Get-VmfDisclaimer).shortLine)</p></div></body></html>")

    $reportName = 'customer-report.html'
    Write-VmfStoreText -RunPath $OutPath -RelPath $reportName -Content $sb.ToString()
    # Returned handle: a local file path on the file backend, the blob URI on azblob.
    $ctx = Get-VmfStoreContext -RunPath $OutPath
    $reportPath = if ($ctx.Backend -eq 'file') { Join-Path $OutPath $reportName }
                  else { Get-VmfStoreBlobUri $ctx $reportName }
    # STEP-LOG-4: written after the report is saved, so a line that cannot be
    # written is a warning, never a failed report.
    Write-VmfStepLine -RunPath $OutPath -Step 'report' -Outcome ok -Detail $reportPath
    return $reportPath
}
