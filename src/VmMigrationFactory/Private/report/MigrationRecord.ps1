# ATTEST-1: a full record of a migration, to keep.
#
# Asked for by a customer at the first demo: every action, step, result, time
# and person, per machine, in a form their engineering and change-management
# teams can keep as the record of the change. Rulings, 2026-09-24:
#
#   - it is for the ADMINISTRATOR role - engineering and change management;
#   - correct data, not tamper-proofing;
#   - kept for 90 days to download, including after the migration is deleted.
#
# Nearly all of it was already in the store, in three places - each machine's
# state document, the run's activity log, and the approvals and acceptances -
# with nothing putting it together. This puts it together. It asks Azure for
# nothing, and it says where each figure came from rather than inventing one.
#
# WHERE IT IS KEPT: vmf-records/, beside the runs and outside every one of
# them, so deleting a migration cannot delete its record. A record is written
# when a wave closes out, when a machine is restored (REPORT-AUTO-1,
# with the report, by Save-VmfRecordAndReport), when an administrator downloads
# it, and just before a migration is deleted; each write keeps it for another
# 90 days.
#
# REPORT-AUTO-1 (v3): it also holds every fact the report's old engineering
# appendix held - the assessment of each machine for its series, its size
# alternates, plan notes and checkpoint, and the quota records. The appendix
# went when the report became one kind; its facts were not to go with it.


$script:VmfRecordKeepDays = 90
$script:VmfRecordFolder = 'vmf-records'

function Get-VmfStoreRootOf {
    <#
    .SYNOPSIS
        The store root a run lives under: its own segment off the end, and its
        project's too. The same answer for a run inside a project and one
        outside, locally and in Azure - so every record lands in ONE folder.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter()][AllowEmptyString()][string]$Project)
    $root = $RunPath.TrimEnd('/', '\') -replace '[/\\][^/\\]+$', ''
    if ($Project) { $root = $root -replace '[/\\][^/\\]+$', '' }
    $root
}

function Get-VmfRecordScope {
    <#
    .SYNOPSIS
        The records folder AS A STORE PATH of its own, with each record a
        document directly inside it.
    .DESCRIPTION
        FOUND ON THE FIRST AZURE INSTALL, 2026-09-24: the records were written
        as "vmf-records/<name>" relative to the store ROOT. On a local disk that
        is a folder. In Azure the root is a bare container, and the blob store
        refuses a path with no prefix under the container - on purpose, because
        a run path that named the whole container would let a run delete reach
        every run. So the record was never written after a wave, both downloads
        failed, and deleting a migration stopped, because a delete that cannot
        keep the record deletes nothing. Every test passed: they all used a
        local folder. The machine claims already had this shape (vmf-claims).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$StorePath)
    $trimmed = $StorePath.TrimEnd([char]0x2F, [char]0x5C)
    if ($trimmed -match '^azblob://') { return "$trimmed/$script:VmfRecordFolder" }
    Join-Path $trimmed $script:VmfRecordFolder
}

function Get-VmfRecordName {
    <#
    .SYNOPSIS
        The record's file name: project and run, so two runs of one name in
        two projects keep two records.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$RunId, [Parameter()][AllowEmptyString()][string]$Project)
    $raw = if ($Project) { "$Project--$RunId" } else { $RunId }
    ($raw -replace '[^A-Za-z0-9\-]', '-') + '.json'
}

function Get-VmfRecordField {
    # A property of a JSON object or a hashtable, or $null. Records are built
    # from documents read either way.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

function Test-VmfRecordHasField {
    # Does a JSON object or a hashtable carry this field at all - even with a
    # null value? A capture is a hashtable at PRECHECK (Get-VmfVmCapture) and
    # an object once read back from the state document, and the PSObject form
    # alone is always false for a hashtable key (CRG-MOVE-ZONE-1 review).
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $false }
    if ($Object -is [System.Collections.IDictionary]) { return [bool]$Object.Contains($Name) }
    $null -ne $Object.PSObject.Properties[$Name]
}

function Get-VmfAssessedCounts {
    <#
    .SYNOPSIS
        The fleet assessment's own counts, as the scan made them, by
        classification, in name order.
    .DESCRIPTION
        Pure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter()][AllowNull()]$Summary)
    $byClass = [ordered]@{}
    $names = if ($Summary -is [System.Collections.IDictionary]) { @($Summary.Keys) } elseif ($Summary) { @($Summary.PSObject.Properties.Name) } else { @() }
    $sum = @{}
    foreach ($n in $names) {
        $own = [string]$n
        $sum[$own] = [int]$sum[$own] + [int](Get-VmfRecordField -Object $Summary -Name ([string]$n))
    }
    foreach ($n in @($sum.Keys | Sort-Object)) { $byClass[[string]$n] = $sum[$n] }
    $byClass
}

function Get-VmfRecordAssessment {
    <#
    .SYNOPSIS
        One machine's assessment as the record keeps it: its classification
        for the series ITS plan entry moves to, its generation, disk
        architecture, and the blockers and preparation that apply.
    .DESCRIPTION
        The judgement the report's appendix made, moved here with its facts
        (REPORT-AUTO-1). REVIEW-1: a planned machine is judged against its
        entry's series by the engine's own rule (V5-GATE-1) - the scan decides
        for every series at once, so a Generation 1 machine in a v5 wave read
        as blocked while it migrated. V5-ADE-1: a machine the plan does not
        move, although the series alone would, is Blocked with the plan's own
        reason. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Vm, [Parameter()][AllowNull()]$Entry)
    if ($null -eq $Vm) { return $null }
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $class = [string](& $f $Vm 'classification')
    $issues = @(@(& $f $Vm 'blockers') + @(& $f $Vm 'prepNeeded'))
    $series = [string](& $f (& $f $Entry 'policy') 'targetGeneration')
    if ($series -in @('v5', 'v6', 'v7')) {
        $judged = Resolve-VmfEntryClassification -Assessment $Vm -TargetGeneration $series
        $class = $judged.Classification
        $issues = @(@($judged.Blockers) + @($judged.Prep))
    }
    if ($Entry -and [string](& $f $Entry 'path') -eq 'MANUAL' -and $class -like 'Ready*') {
        $class = 'Blocked'
        $issues = @(& $f $Entry 'planNotes')
    }
    [ordered]@{
        classification   = $class
        generation       = [string](& $f $Vm 'gen')
        diskArchitecture = [string](& $f $Vm 'sourceDiskArch')
        issues           = @($issues | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
}

function Get-VmfRecordOutcome {
    <#
    .SYNOPSIS
        What happened to one machine, as the migration record says it: the
        one definition (Get-VmfMachineOutcome), and `notMoved` for a machine
        the plan does not move.
    .DESCRIPTION
        RECORD-UNMOVED-1. The run page's rule (MANUAL-WHY-1): a machine whose
        plan entry is MANUAL or EXCLUDED, and which has not started, is "Not
        moved" - never waiting to start. The record called it notStarted, so
        a finished migration read as "Not started" for machines nothing was
        ever going to move. A machine with a state past PLANNED keeps the
        outcome its state gives, as the run page does. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$StateDoc, [Parameter()][AllowNull()]$Entry)
    $outcome = Get-VmfMachineOutcome -StateDoc $StateDoc
    if ($outcome -eq 'notStarted' -and [string](Get-VmfRecordField -Object $Entry -Name 'path') -in @('MANUAL', 'EXCLUDED')) { return 'notMoved' }
    $outcome
}

function ConvertTo-VmfQuotaRecordRow {
    <#
    .SYNOPSIS
        One quota record as the migration record keeps it: what the report's
        appendix showed for it (REPORT-AUTO-1). Pure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Claim)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $demand = & $f $Claim 'demand'
    $quota = & $f $Claim 'quota'
    $num = { param($v) if ($null -eq $v -or [string]$v -eq '') { $null } else { [int]$v } }
    [ordered]@{
        wave       = [string](& $f $Claim 'wave')
        region     = [string](& $f $Claim 'region')
        zone       = $(if (& $f $Claim 'zone') { [string](& $f $Claim 'zone') } else { $null })
        size       = [string](& $f $Claim 'size')
        family     = $(if (& $f $Claim 'vmFamily') { [string](& $f $Claim 'vmFamily') } else { $null })
        vcpus      = & $num (& $f $demand 'vcpus')
        quotaUsed  = & $num (& $f $quota 'used')
        quotaLimit = & $num (& $f $quota 'limit')
        state      = [string](& $f $Claim 'state')
        notes      = @(@(& $f $Claim 'notes') | Where-Object { $_ } | ForEach-Object { [string]$_ })
    }
}

function ConvertTo-VmfMigrationRecord {
    <#
    .SYNOPSIS
        The record of one migration, from its documents. Pure: nothing read,
        nothing written, no Azure.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter()][AllowNull()]$Plan,
        [Parameter()][AllowEmptyCollection()][object[]]$StateDocs = @(),
        [Parameter()][AllowEmptyCollection()][object[]]$Events = @(),
        [Parameter()][AllowNull()]$PlanApproval,
        [Parameter()][AllowNull()][hashtable]$WaveApprovals,
        [Parameter()][AllowEmptyCollection()][object[]]$Acceptances = @(),
        [Parameter()][AllowNull()]$Acknowledgement,
        # REPORT-AUTO-1: the run's assessment and its quota records, for the
        # facts the report's appendix used to hold.
        [Parameter()][AllowNull()]$Assessment,
        [Parameter()][AllowEmptyCollection()][object[]]$Claims = @(),
        [Parameter(Mandatory)][string]$GeneratedBy,
        [Parameter(Mandatory)][ValidateSet('waveClosed', 'putBack', 'stopped', 'dailyCheck', 'downloaded', 'deleted')][string]$Reason,
        [Parameter()][datetime]$Now = (Get-Date).ToUniversalTime()
    )
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    # POSITION IS NOT TIME: several workers append to the log at once. Every
    # timestamp is written in one ISO-8601 UTC form, so as text they sort in
    # time order.
    $byTime = @($Events | Where-Object { $_ } | Sort-Object { [string](& $f $_ 'tsUtc') })

    $docById = @{}
    foreach ($d in @($StateDocs)) { if ($d -and (& $f $d 'vmId')) { $docById[[string](& $f $d 'vmId')] = $d } }
    $entries = @(if ($Plan) { @(& $f $Plan 'entries') | Where-Object { $_ } })
    $ids = [System.Collections.Generic.List[string]]::new()
    foreach ($e in $entries) { $id = [string](& $f $e 'vmId'); if ($id -and -not $ids.Contains($id)) { $ids.Add($id) } }
    # REPORT-AUTO-1 review 6: a hashtable's keys come in hash order, which
    # changes from one process to the next - sorted, so two writes agree.
    foreach ($id in @($docById.Keys | Sort-Object)) { if (-not $ids.Contains($id)) { $ids.Add($id) } }
    # VERIFY-FP-1 part 3b review: looked up once, by machine. Each machine used
    # to scan every entry and every event - 26 seconds for 300 machines.
    $entryById = @{}
    foreach ($e in $entries) { $k = [string](& $f $e 'vmId'); if ($k -and -not $entryById.ContainsKey($k)) { $entryById[$k] = $e } }
    $eventsById = @{}
    foreach ($ev in $byTime) {
        $k = [string](& $f $ev 'vmId'); if (-not $k) { continue }
        if (-not $eventsById.ContainsKey($k)) { $eventsById[$k] = [System.Collections.Generic.List[object]]::new() }
        $eventsById[$k].Add($ev)
    }

    # Looked up by machine, as the entries are. A hashtable ignores case, and
    # VMID-CASE-1 keeps the assessment's spelling in the plan anyway.
    $vmById = @{}
    foreach ($v in @(& $f $Assessment 'vms')) { $k = [string](& $f $v 'vmId'); if ($k -and -not $vmById.ContainsKey($k)) { $vmById[$k] = $v } }

    $machines = foreach ($id in $ids) {
        $entry = $entryById[$id]
        $doc = $docById[$id]
        # NOT-IN-WAVE-QUEUED-1: a machine in no wave that never ran is not part
        # of the migration - no wave takes it - so the record does not list
        # it, the rule the pages show it by. One with a state document keeps
        # its row: its history is the record.
        if (Test-VmfEntryOutsideRun -Entry $entry -StateDoc $doc) { continue }
        $outcome = Get-VmfRecordOutcome -StateDoc $doc -Entry $entry
        $assess = & $f $entry 'assessment'
        $target = & $f $entry 'target'
        # ROLLBACK-RETRY-CAPTURE-1: "before" is the machine as the FIRST capture
        # found it - a retry after a rebuild captured it on the target size.
        # OLD-VERSION-READERS-REMOVE-4 review: a record this version cannot read
        # (Get-VmfPutBackCapture throws) leaves only this machine's "before"
        # empty - never the plan's size in its place, and never a record that
        # stops for every machine.
        $captured = $null
        $captureUnreadable = $false
        if (& $f (& $f $doc 'captured') 'vmConfig') {
            try { $captured = Get-VmfPutBackCapture -Doc $doc } catch { $captureUnreadable = $true }
        }
        $restore = & $f $doc 'restore'
        $sizeBefore = [string]$(if (& $f $captured 'size') { & $f $captured 'size' } elseif (-not $captureUnreadable) { & $f $assess 'sourceSize' })
        # ROLLBACK-SIZE-REFUSED-SERIES-1: a restore onto the target size of the
        # plan made that size the first capture's, so every put-back returns
        # there. "Before" is still the size the machine had: the size kept
        # beside it (captured.original.sizeReplaced). The machine is on the
        # restore's size now, when nothing moved it since.
        $replacedSize = Get-VmfSizeReplaced -Doc $doc
        $sizeOntoRestore = $null
        if ($replacedSize) { $sizeOntoRestore = $sizeBefore; $sizeBefore = [string]$replacedSize.Original }
        $controllerBefore = [string](& $f $captured 'controller')
        # WHERE THE "NOW" FIGURE COMES FROM, said beside it. VERIFY-FP-1 part
        # 3: a machine migrated with an evidence record is read from Azure after
        # the move; one from before the record existed falls back to the plan
        # target, which VALIDATING checked it against.
        # $sizeNow, not $now: PowerShell names ignore case, and $Now is the
        # [datetime] parameter above - assigning this to it fails.
        $evidence = & $f $doc 'evidence'
        $afterRead = & $f $evidence 'after'
        $readSize = [string](& $f $afterRead 'azure.size'); $readController = [string](& $f $afterRead 'azure.controller')
        # FINISH-COUNT-1: the size it runs on now. A data disk swap a restore
        # left counts the machine as waiting for a person, and keeps the size
        # the restore record gives.
        $sizeNow = switch (Get-VmfMachineMoveOutcome -StateDoc $doc) {
            'migrated' {
                if ($readSize) { [ordered]@{ size = $readSize; controller = $readController; basis = 'read from Azure after the move' } }
                else { [ordered]@{ size = [string](& $f $target 'size'); controller = [string](& $f $target 'controller'); basis = 'the plan target, which the machine passed validation against' } }
            }
            'putBack'  { [ordered]@{ size = [string](& $f $restore 'sizeAfter'); controller = $controllerBefore; basis = 'the restore record' } }
            default    {
                if ($replacedSize) { [ordered]@{ size = $sizeOntoRestore; controller = $controllerBefore; basis = 'the restore record' } }
                else { [ordered]@{ size = $sizeBefore; controller = $controllerBefore; basis = 'not changed by this migration' } }
            }
        }
        # Said beside the figure on every outcome: the report shows "before"
        # and "now", and only this sentence says why they differ.
        if ($replacedSize) { $sizeNow.basis = "$($sizeNow.basis). $(Get-VmfSizeReplacedWords -Replaced $replacedSize)" }
        [ordered]@{
            vmId        = $id
            # VMID-CASE-1: as Azure spells it on the machine, not in the ID.
            name        = Get-VmfMachineName -VmId $id -Names @([string](& $f $captured 'name'))
            wave        = [string](& $f $entry 'wave')
            path        = [string](& $f $entry 'path')
            state       = $(if ($doc) { [string](& $f $doc 'state') } else { 'PLANNED' })
            outcome     = $outcome
            before      = [ordered]@{ size = $sizeBefore; controller = $controllerBefore; os = [string](& $f $assess 'os'); osVersion = [string](& $f $assess 'osVersion') }
            # TEMP-DISK-PREVIEW-1: and the method the plan recorded, so the
            # report names an in-place upgrade (Preview). Additive: target is
            # open-shaped in migration-record.schema.json; null for an entry
            # older than plan-entry v23.
            target      = [ordered]@{ size = [string](& $f $target 'size'); controller = [string](& $f $target 'controller')
                              method = $(if ($recMethod = Get-VmfEntryMethod -Entry $entry) { $recMethod } else { $null }) }
            now         = $sizeNow
            steps       = @(@(& $f $doc 'history') | Where-Object { $_ } | ForEach-Object {
                # ISO UTC (ConvertTo-VmfIsoUtc): the state document is read
                # through ConvertFrom-Json, which makes a time a date value, and
                # [string] of that is month-first with no zone. evidenceRef: the
                # file the step kept, such as the boot diagnostics.
                [ordered]@{ tsUtc = ConvertTo-VmfIsoUtc (& $f $_ 'tsUtc'); state = [string](& $f $_ 'state'); outcome = [string](& $f $_ 'outcome')
                            durationSec = & $f $_ 'durationSec'; detail = [string](& $f $_ 'detail'); reasonCode = & $f $_ 'reasonCode'
                            evidenceRef = & $f $_ 'evidenceRef' } })
            guestScripts = @(@(& $f $doc 'guestExecutions') | Where-Object { $_ } | ForEach-Object {
                [ordered]@{ tsUtc = ConvertTo-VmfIsoUtc (& $f $_ 'tsUtc'); script = [string](& $f $_ 'script'); version = [string](& $f $_ 'version')
                            sha256 = [string](& $f $_ 'sha256'); result = [string](& $f $_ 'result') } })
            safetyCopies = & $f $doc 'safety'
            putBack      = $restore
            retention    = & $f $doc 'retention'
            # VERIFY-FP-1 part 3: each reading before and after the move, and
            # what it is. Never a pass or a fail.
            evidence     = $(if ($evidence -and $outcome -eq 'migrated') {
                [ordered]@{
                    takenUtc = ConvertTo-VmfIsoUtc (& $f $evidence 'takenUtc')
                    rows     = @(Compare-VmfEvidence -Before (& $f $evidence 'before') -After $afterRead -Planned @(& $f $evidence 'planned') | ForEach-Object {
                        [ordered]@{ key = $_.key; group = $_.group; label = $_.label; before = $_.before; after = $_.after; result = $_.result } })
                }
            } else { $null })
            activity     = @(if ($eventsById.ContainsKey($id)) { $eventsById[$id] })
            # REPORT-AUTO-1 (v3): what the report's appendix showed.
            assessment     = Get-VmfRecordAssessment -Vm $vmById[$id] -Entry $entry
            sizeAlternates = @(@(& $f $target 'sizeAlternates') | Where-Object { $_ } | ForEach-Object { [string]$_ })
            planNotes      = @(@(& $f $entry 'planNotes') | Where-Object { $_ } | ForEach-Object { [string]$_ })
            pathCheckpoint = $(if (& $f $doc 'pathCheckpoint') { [string](& $f $doc 'pathCheckpoint') } else { $null })
        }
    }

    # The fleet assessment's own counts, as the scan made them.
    $assessed = if ($Assessment) {
        $byClass = Get-VmfAssessedCounts -Summary (& $f $Assessment 'summary')
        # MACHINE-PICK-1: a plan holds only the machines a person chose. A
        # scanned machine it has no entry for is not in this migration - the
        # rule the report's appendix used before it moved here: only once the
        # plan holds machines, and never an Excluded or platform-managed one.
        $notIn = 0
        if ($entries.Count) {
            foreach ($v in @(& $f $Assessment 'vms')) {
                if (-not $v) { continue }
                if ($entryById.ContainsKey([string](& $f $v 'vmId'))) { continue }
                if ([string](& $f $v 'classification') -eq 'Excluded' -or (& $f $v 'platformManaged')) { continue }
                $notIn++
            }
        }
        [ordered]@{ machines = @(& $f $Assessment 'vms' | Where-Object { $_ }).Count; byClassification = $byClass; notInMigration = $notIn }
    } else { $null }

    # Every decision a named person made, in one list, oldest first. `version`
    # is what it was given for: the plan version for a sign-off, the wave's
    # version for a wave approval (WAVE-APPROVE-1; the plan version for one
    # written before), the settings version for an acceptance.
    $decisions = [System.Collections.Generic.List[object]]::new()
    $addDecision = { param($what, $wave, $by, $at, $note, $version)
        if (-not $by -and -not $at) { return }
        $decisions.Add([ordered]@{ what = $what; wave = $wave; by = [string]$by; atUtc = ConvertTo-VmfIsoUtc $at; note = [string]$note; version = $version }) }
    if ($PlanApproval) {
        & $addDecision 'signed off the plan' $null (& $f (& $f $PlanApproval 'approvedBy') 'identity') (& $f $PlanApproval 'approvedUtc') (& $f $PlanApproval 'note') (& $f $PlanApproval 'planHash')
        # SQL-TEMPDB-SIGNOFF-1 (plan-approval v4): the approver confirmed, with
        # the sign-off, that they checked where tempdb is on each SQL Server
        # machine that moves to an NVMe temporary disk or none. The note names
        # the machines. No row for a sign-off with no such machine.
        $sqlChecked = @(@(& $f $PlanApproval 'sqlTempdbChecked') | Where-Object { $_ })
        if ($sqlChecked.Count) {
            & $addDecision 'checked where tempdb is on the SQL Server machines' $null (& $f (& $f $PlanApproval 'approvedBy') 'identity') (& $f $PlanApproval 'approvedUtc') `
                (@($sqlChecked | ForEach-Object { Get-VmfMachineName -VmId ([string]$_) }) -join ', ') (& $f $PlanApproval 'planHash')
        }
    }
    # WAVE-APPROVE-1: "Sign off all" writes one approval per wave with the
    # sign-off, at the same moment, by the same person - said so, so the record
    # does not read as N separate approvals beside the sign-off.
    $signedAt = if ($PlanApproval) { ConvertTo-VmfIsoUtc (& $f $PlanApproval 'approvedUtc') } else { $null }
    $signedBy = if ($PlanApproval) { [string](& $f (& $f $PlanApproval 'approvedBy') 'identity') } else { $null }
    foreach ($w in @(if ($WaveApprovals) { $WaveApprovals.Keys })) {
        $a = $WaveApprovals[$w]
        $by = & $f (& $f $a 'approvedBy') 'identity'
        $at = & $f $a 'approvedUtc'
        $waveVersion = [string](& $f $a 'waveVersion')
        $fromSignOff = $signedAt -and [string]::Equals((ConvertTo-VmfIsoUtc $at), $signedAt, [System.StringComparison]::Ordinal) -and
            [string]::Equals([string]$by, $signedBy, [System.StringComparison]::Ordinal)
        & $addDecision $(if ($fromSignOff) { 'approved the wave by signing off the plan' } else { 'approved the wave' }) $w $by $at (& $f $a 'note') `
            $(if ($waveVersion) { $waveVersion } else { & $f $a 'planHash' })
    }
    foreach ($a in @($Acceptances | Where-Object { $_ })) {
        & $addDecision "accepted the wave's settings" (& $f $a 'wave') (& $f $a 'acceptedBy') (& $f $a 'acceptedUtc') (& $f $a 'note') (& $f $a 'optionsHash')
    }
    if ($Acknowledgement) {
        & $addDecision 'accepted the note about machines defined in code' $null (& $f $Acknowledgement 'acknowledgedBy') (& $f $Acknowledgement 'acknowledgedUtc') (& $f $Acknowledgement 'statement') $null
    }
    $ordered = @($decisions | Sort-Object { [string]$_.atUtc })

    # Every outcome Get-VmfOutcomeCounts names, at zero when nothing has it,
    # and notMoved beside notStarted (v4, RECORD-UNMOVED-1). Counted from the
    # machines above, so the summary and the machine table never disagree.
    $summary = [ordered]@{}
    foreach ($k in @((Get-VmfOutcomeCounts).PSObject.Properties.Name)) {
        $summary[$k] = 0
        if ($k -eq 'notStarted') { $summary['notMoved'] = 0 }
    }
    foreach ($m in @($machines)) { $summary[[string]$m.outcome]++ }

    [ordered]@{
        schemaVersion  = 5
        runId          = [string](& $f $Manifest 'runId')
        project        = & $f $Manifest 'project'
        fromAssessment = & $f $Manifest 'fromAssessment'
        createdUtc     = [string](& $f $Manifest 'createdUtc')
        createdBy      = & $f $Manifest 'createdBy'
        generatedUtc   = $Now.ToString('o')
        generatedBy    = $GeneratedBy
        reason         = $Reason
        keepUntilUtc   = $Now.AddDays($script:VmfRecordKeepDays).ToString('o')
        summary        = $summary
        decisions      = @($ordered)
        machines       = @($machines)
        runActivity    = @($byTime | Where-Object { -not (& $f $_ 'vmId') })
        assessment     = $assessed
        quotaRecords   = @(@($Claims | Where-Object { $_ }) | ForEach-Object { ConvertTo-VmfQuotaRecordRow -Claim $_ })
    }
}

function New-VmfMigrationRecord {
    <#
    .SYNOPSIS
        Build the record of the migration at RunPath from the store, keep it in
        vmf-records/ for another 90 days, and return it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][ValidateSet('waveClosed', 'putBack', 'stopped', 'dailyCheck', 'downloaded', 'deleted')][string]$Reason,
        [Parameter()][string]$GeneratedBy = 'the engine',
        # RECORD-DELETE-1: refuse, rather than keep, when a delete of this
        # migration has started to remove it. The download asks for this.
        [Parameter()][switch]$RefuseWhileDeleting
    )
    # RECORD-DELETE-1 review 2: the version of the kept record is read BEFORE
    # the build, so a record that a wave keeps while this one is built (from
    # newer data) is not replaced by this older one: the keep below quotes this
    # version and the store refuses it.
    $expected = ''
    if ($RefuseWhileDeleting) {
        $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 8
        if (-not $manifest) { throw "There is no migration at '$RunPath'." }
        $preName = Get-VmfRecordName -RunId ([string]$manifest.runId) -Project ([string]$manifest.project)
        $preScope = Get-VmfRecordScope -StorePath (Get-VmfStoreRootOf -RunPath $RunPath -Project ([string]$manifest.project))
        if (Test-VmfStoreItem -RunPath $preScope -RelPath $preName) {
            $expected = Get-VmfDocumentVersion -Text (Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $preScope -RelPath $preName))
        }
    }
    $record = Get-VmfMigrationRecordFromStore -RunPath $RunPath -Reason $Reason -GeneratedBy $GeneratedBy
    $name = Get-VmfRecordName -RunId ([string]$record.runId) -Project ([string]$record.project)
    $root = Get-VmfStoreRootOf -RunPath $RunPath -Project ([string]$record.project)
    $scope = Get-VmfRecordScope -StorePath $root
    if ($RefuseWhileDeleting) { Save-VmfRecordUnlessDeleting -RunPath $RunPath -Scope $scope -Name $name -Record $record -ExpectedVersion $expected }
    else { Write-VmfStoreJson -RunPath $scope -RelPath $name -Document $record -Depth 24 }
    # REPORT-RECORD-LINE-1: a line in the run history, in the shape the report
    # write leaves (New-VmfReport): the daily check compares it with the
    # newest change and the newest warning, as it does the report's. Without
    # it, a record that failed while the report after it was written looked
    # current. The record is kept by now, so a line that cannot be written is
    # not a failed record: the daily check, finding no line, writes it again.
    try {
        $ctx = Get-VmfStoreContext -RunPath $scope
        $where = if ($ctx.Backend -eq 'file') { Join-Path $scope $name } else { Get-VmfStoreBlobUri $ctx $name }
        Write-VmfStepLine -RunPath $RunPath -Step 'record' -Outcome ok -Detail $where
    }
    catch { Write-Verbose "The record was kept, and the line that says so could not be written: $($_.Exception.Message)" }
    $record
}

function Test-VmfDeleteStoppedAfterRecord {
    <#
    .SYNOPSIS
        RECORD-DELETE-1 review 1: did the delete that kept this 'deleted'
        record stop afterwards, leaving the migration in place?
    .DESCRIPTION
        A delete keeps its record before it releases the machines and removes
        the run, and any of those can stop it (a claim release the store
        refuses, a capacity reservation made in the last seconds). Then the
        migration is still there under a record that says 'deleted', and a
        download refused for that would be refused for ever. Remove-VmfRun
        writes a 'discard' failure when it stops after the keep and BEFORE it
        removes anything.

        The question is the one rule that says whether a delete is open
        (Get-VmfOpenDiscard), asked from the moment the record was made: the
        keep opens it, and a failure or a refusal after it ends it. A record
        whose time cannot be read is NOT ended - unknown is not a yes.

        Only the delete's own 'discard' lines are asked, not the engine's
        'engine:discard'. The engine writes that line for ANY failure while
        run.json is still there - a removal that stopped part way included,
        and in Azure run.json goes late in the removal. Taken as an end, it
        would let a download build a record from a half-removed run. A stop
        before the removal always has Remove-VmfRun's own line as well.

        And only a line that NAMES THIS RECORD (keptRecordUtc, its
        generatedUtc). Review 2 reproduced the hole: a first delete keeps its
        record and stops part way through the removal; a second finds no plan,
        keeps no record, stops, and its line - or any other 'discard' failure,
        a refusal before the keep or "the engine did not start" - ended the
        first delete's record, and a download replaced it with one built from
        the half-removed run. And with no plan.json the run is not whole,
        whatever a line says: a 'deleted' record is only kept with a plan.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)]$Kept
    )
    $madeAt = ConvertTo-VmfRecordUtc (Get-VmfRecordField -Object $Kept -Name 'generatedUtc')
    if (-not $madeAt) { return $false }
    if (-not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'plan.json')) { return $false }
    $after = @(Read-VmfEvents -RunPath $RunPath | Where-Object {
            $_ -and $_.step -eq 'discard' -and
            ($named = ConvertTo-VmfRecordUtc (Get-VmfRecordField -Object $_ -Name 'keptRecordUtc')) -and
            $named.Ticks -eq $madeAt.Ticks
        } | Sort-Object { (ConvertTo-VmfRecordUtc $_.tsUtc) })
    $opened = [pscustomobject]@{ step = 'discard'; outcome = 'start' }
    -not (Get-VmfOpenDiscard -Events (@($opened) + $after))
}

function Save-VmfRecordUnlessDeleting {
    <#
    .SYNOPSIS
        RECORD-DELETE-1: keep a record that was built from the store, unless a
        delete of the migration has started to remove it. Throws 409.
    .DESCRIPTION
        Found by the review of REPORT-RECORD-LINE-1: a download that raced a
        delete could keep a record built from a half-removed run over the
        record the delete kept, and write the run history back into the folder
        the delete had removed - a folder with no run.json that nothing cleans.

        Asked AFTER the record was built, so it judges what the build read. A
        delete keeps its own record ('deleted') BEFORE it removes anything
        (Remove-VmfRun), so a build that overlapped the removal finds that
        record here, or finds run.json gone. Either way nothing is kept and
        nothing is returned. A 'deleted' record whose delete then STOPPED
        (Test-VmfDeleteStoppedAfterRecord) does not refuse: the migration is
        still there, and this record replaces it.

        And the check and the keep are one step (PLAN-WRITE-RACE-1): the kept
        record is written only if it is still the version read before the
        build, or created only if there was none. A delete or a wave that
        keeps its record in between wins, and this refuses. On the file
        backend that holds against another download only; the store in Azure
        holds it against every writer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Scope,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)]$Record,
        # The version of the kept record read before the build; empty for none.
        [Parameter(Mandatory)][AllowEmptyString()][string]$ExpectedVersion
    )
    $deleting = '409: A delete of this migration started, so the product did not make a new record of it. Records of each migration shows the records that the product kept.'
    $raced = '409: The record of this migration was written again while this one was made, so this one was not kept. Try again.'

    $gone = -not (Test-VmfStoreItem -RunPath $RunPath -RelPath 'run.json')
    if (-not $gone -and (Test-VmfStoreItem -RunPath $Scope -RelPath $Name)) {
        $keptText = Read-VmfTextDocument -Path (Get-VmfStoreItemHandle -RunPath $Scope -RelPath $Name)
        $kept = $null
        try { $kept = $keptText | ConvertFrom-Json -Depth 64 } catch { $kept = $null }
        if ($kept -and ([string](Get-VmfRecordField -Object $kept -Name 'reason')) -eq 'deleted') {
            $gone = -not (Test-VmfDeleteStoppedAfterRecord -RunPath $RunPath -Kept $kept)
        }
    }
    if ($gone) { throw $deleting }

    if (-not $ExpectedVersion) {
        # STORE-CREATE-LOST-ANSWER-1: generatedUtc makes the text this build's own.
        if (-not (Write-VmfStoreJsonExclusive -RunPath $Scope -RelPath $Name -Document $Record -UniqueText)) { throw $raced }
        return
    }
    try {
        Write-VmfTextDocumentIfVersion -Path (Get-VmfStoreItemHandle -RunPath $Scope -RelPath $Name) `
            -Content ($Record | ConvertTo-Json -Depth 24) -ExpectedVersion $ExpectedVersion
    }
    catch {
        # The store's own 409 names the plan; this is the record.
        if ("$_" -match '^409') { throw $raced }
        throw
    }
}
function Get-VmfMigrationRecordFromStore {
    <#
    .SYNOPSIS
        The record of the migration at RunPath, built from the store and
        returned - NOT kept. New-VmfMigrationRecord keeps it; the report
        (VERIFY-FP-1 part 3b) renders it, so both say the same thing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][ValidateSet('waveClosed', 'putBack', 'stopped', 'dailyCheck', 'downloaded', 'deleted')][string]$Reason,
        [Parameter()][string]$GeneratedBy = 'the engine'
    )
    $manifest = Read-VmfStoreJson -RunPath $RunPath -RelPath 'run.json' -Depth 8
    if (-not $manifest) { throw "There is no migration at '$RunPath'." }
    # EVAL-H11: through the one gated reader of plan.json, like every other reader.
    $plan = Read-VmfPlanDocument -RunPath $RunPath -Depth 24
    $docs = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$_" -Depth 24 } | Where-Object { $_ })
    # WRITE-DEPTH-OPEN-1: lines are written at 24 (Write-VmfEvent); a line read
    # shallower than it was written is dropped here.
    $events = @(Read-VmfStoreLines -RunPath $RunPath -RelPath 'logs/events.jsonl' |
        ForEach-Object { try { $_ | ConvertFrom-Json -Depth 24 } catch { $null } } | Where-Object { $_ })
    $approvals = @{}
    foreach ($n in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'approvals' -Extension '.json')) {
        $a = Read-VmfStoreJson -RunPath $RunPath -RelPath "approvals/$n" -Depth 6
        if ($a) { $approvals[[string]$a.wave] = $a }
    }
    $acceptances = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'acceptances' -Extension '.json' |
        ForEach-Object { Read-VmfStoreJson -RunPath $RunPath -RelPath "acceptances/$_" } | Where-Object { $_ })
    # REPORT-AUTO-1: the assessment the migration was planned from (New-VmfPlan
    # copies it in) and the live quota records - what the appendix read.
    # Review 5: each read on its own. A malformed file reads as none, with a
    # warning - it must never block a delete (which keeps the record first) or
    # the record download.
    $warnRead = { param($what, $why)
        Write-VmfStepLine -RunPath $RunPath -Step 'record' -Outcome warn -Detail "The migration record was written without $what, because it could not be read: $why"
    }
    $assessment = $null
    try {
        if (Test-VmfStoreItem -RunPath $RunPath -RelPath 'assessment.json') { $assessment = Read-VmfStoreJson -RunPath $RunPath -RelPath 'assessment.json' -Depth 24 }
    }
    catch { & $warnRead 'the assessment' $_.Exception.Message }
    $claims = [System.Collections.Generic.List[object]]::new()
    $claimNames = @()
    try { $claimNames = @(Get-VmfStoreNames -RunPath $RunPath -Folder 'capacity' -Extension '.json') }
    catch { & $warnRead 'the quota records' $_.Exception.Message }
    foreach ($n in @($claimNames | Sort-Object)) {
        try { $c = Read-VmfStoreJson -RunPath $RunPath -RelPath "capacity/$n" -Depth 12; if ($c) { $claims.Add($c) } }
        catch { & $warnRead "the quota record $n" $_.Exception.Message }
    }
    $claims = @($claims)
    $record = ConvertTo-VmfMigrationRecord -Manifest $manifest -Plan $plan -StateDocs $docs -Events $events `
        -PlanApproval (Read-VmfStoreJson -RunPath $RunPath -RelPath 'plan-approval.json' -Depth 6) `
        -WaveApprovals $approvals -Acceptances $acceptances `
        -Acknowledgement (Read-VmfStoreJson -RunPath $RunPath -RelPath 'acknowledgements/infrastructure-as-code.json' -Depth 6) `
        -Assessment $assessment -Claims $claims `
        -GeneratedBy $GeneratedBy -Reason $Reason
    $record
}

function Get-VmfKeptMigrationRecords {
    <#
    .SYNOPSIS
        The records kept beside the runs: name, run, project, when made, why,
        and until when. Read from the records themselves.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorePath)
    $scope = Get-VmfRecordScope -StorePath $StorePath
    foreach ($n in @(Get-VmfStoreNames -RunPath $scope -Folder '' -Extension '.json')) {
        $r = Read-VmfStoreJson -RunPath $scope -RelPath $n -Depth 24
        if (-not $r) { continue }
        [pscustomobject]@{ Name = $n; RunId = [string]$r.runId; Project = $r.project; GeneratedUtc = [string]$r.generatedUtc
                           Reason = [string]$r.reason; KeepUntilUtc = [string]$r.keepUntilUtc }
    }
}

function Remove-VmfExpiredMigrationRecords {
    <#
    .SYNOPSIS
        Delete the records past their 90 days. Called by the daily cleanup.
        A record whose date cannot be read is KEPT - unknown is not old.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorePath, [Parameter()][datetime]$AsOf = (Get-Date).ToUniversalTime())
    foreach ($r in @(Get-VmfKeptMigrationRecords -StorePath $StorePath)) {
        $until = [datetime]::MinValue
        if (-not [datetime]::TryParse($r.KeepUntilUtc, $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$until)) { continue }
        if ($until -gt $AsOf) { continue }
        Remove-VmfStoreItem -RunPath (Get-VmfRecordScope -StorePath $StorePath) -RelPath $r.Name
        $r
    }
}
