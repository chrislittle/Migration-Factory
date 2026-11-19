# SCHEDULE-PASS-DUE-1: the five-minute schedule pass reads only the runs that
# have something due.
#
# MEASURED (2026-11-10): the pass read every run in the store - about
# 530 store calls and its whole 210-second budget, every pass - though almost
# no run had anything due. It ran in the web service beside the dashboard's
# calls. The ruling: keep the pass in the same service (no new function
# app and no new job), and make it read only what is due.
#
# THE DUE RECORD. One document at the top of the store, schedule-due.json
# (schemas/schedule-due.schema.json), lists the runs the pass checks. Each
# entry has a mark id that changes at every mark. Every path that makes a run
# due marks it through ONE function, Add-VmfRunScheduleDue, AFTER it wrote the
# fact - the cmdlets themselves, so a person at a console marks the run as the
# service does, and the service's engine start:
#   - a start of a wave, a restore or a finish (the service's engine start,
#     Start-VmfWave, New-VmfPutBackJob) - the run can stop part way, and then
#     a wave or a restore must start again, a hold must go, and the next wave
#     of a signed-off plan must start. The mark holds the run in the record
#     for 15 minutes: Azure can list a new execution late, and the engine
#     writes its first hold only when its container runs;
#   - a schedule saved (Set-VmfWaveSchedule) - its wave starts at its time;
#   - a plan sign-off (Approve-VmfPlan) - the next wave starts
#     when one finishes;
#   - a decision or a retry of a machine (Resolve-VmfDecision) - the
#     machine goes back to a working state, and the pass starts its wave again
#     when no part of it runs;
#   - Resume (Clear-VmfWaveHalt) - the pass starts again what the
#     brake held.
# The pass keeps a run in the record while Get-VmfRunScheduleNeed finds a
# fact that one of its checks acts on, and removes it when it finds none.
#
# THE RACE. A removal is version-checked (Write-VmfStoreRootTextIfVersion, the
# If-Match every version-checked write uses), and it removes an entry only
# while the entry holds the mark id the pass read at its start. A path that
# marks a run while the pass checks it writes a new mark id, so the pass does
# not remove it. A mark is written after the fact it is for, so a pass that
# read the run before the fact also read the record before the mark.
#
# THE SAFETY NET. Once an hour the pass also checks every run in the store, as
# every pass did before (the sweep), and adds any run it finds a fact for. So a
# run that is due and is not in the record - a mark that could not be written,
# or a record that could not be read - is found
# within the hour. A record that is not there, or cannot be used, starts a
# sweep at once.

# The name of the record at the store root.
$script:VmfScheduleDueName = 'schedule-due.json'
# How often the pass checks every run (the sweep).
$script:VmfScheduleSweepMinutes = 60
# How long an engine start keeps its run in the record, whatever the pass finds.
$script:VmfScheduleDueHoldMinutes = 15
# How many times a write of the record is tried when another writer changed it.
$script:VmfScheduleDueWriteTries = 5
# Why a run is in the record.
$script:VmfScheduleDueReasons = @('engine', 'schedule', 'planSignOff', 'decision', 'resume', 'sweep')

function Test-VmfScheduleDueRunId {
    <#
    .SYNOPSIS
        Is this a run id the due record may hold: 'run' or 'project/run'? Pure.
    .DESCRIPTION
        The record is data from the store, so its run ids are checked before
        the pass names a folder from one: text, 1 to 512 characters, one or two
        segments, no backslash, no control character, and no segment that is
        '.' or '..'.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$RunId)
    if ($RunId -isnot [string]) { return $false }
    if ($RunId.Length -lt 1 -or $RunId.Length -gt 512) { return $false }
    if ($RunId.Contains([char]0x5C)) { return $false }
    foreach ($ch in $RunId.ToCharArray()) { if ([int]$ch -lt 32 -or [int]$ch -eq 127) { return $false } }
    $segments = $RunId -split '/'
    if ($segments.Count -gt 2) { return $false }
    foreach ($s in $segments) { if ([string]::IsNullOrEmpty($s) -or $s -eq '.' -or $s -eq '..') { return $false } }
    $true
}

function ConvertFrom-VmfScheduleDueTime {
    <#
    .SYNOPSIS
        A time of the due record (text, 'o', UTC) as a UTC date, or $null when
        it is empty or cannot be read. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { return $null }
    $at = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    if (-not [datetime]::TryParse($Value, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$at)) { return $null }
    $at
}

function ConvertFrom-VmfScheduleDueText {
    <#
    .SYNOPSIS
        The entries of the due record, read from its text. Pure.
    .DESCRIPTION
        THE RECORD IS DATA FROM THE STORE (the TIMER-PASS-LIMIT-1 security
        review): every field is type-checked, and nothing here throws. A text
        that is not the record, or of another schema, gives no entries. An
        entry that does not fit is left out. Valid is $false in both cases, so
        the pass starts a sweep: a run the record lost is found by the sweep.
    .OUTPUTS
        @{ Valid; Entries } - each entry an ordered hashtable with runId,
        markId, reason, markedUtc, holdUntilUtc and nextUtc.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text)
    $none = [pscustomobject]@{ Valid = $false; Entries = @() }
    if ([string]::IsNullOrWhiteSpace($Text)) { return $none }
    $doc = $null
    try { $doc = $Text | ConvertFrom-Json -Depth 8 -DateKind String -AsHashtable } catch { return $none }
    if ($doc -isnot [System.Collections.IDictionary]) { return $none }
    $version = $doc['schemaVersion']
    if (-not ($version -is [int] -or $version -is [long]) -or $version -ne 1) { return $none }
    $runs = $doc['runs']
    if ($null -eq $runs -or $runs -is [string] -or $runs -isnot [System.Collections.IEnumerable] -or $runs -is [System.Collections.IDictionary]) { return $none }
    $valid = $true
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $entries = [System.Collections.Generic.List[object]]::new()
    foreach ($r in @($runs)) {
        $ok = $r -is [System.Collections.IDictionary]
        if ($ok) {
            $ok = (Test-VmfScheduleDueRunId -RunId $r['runId']) -and
                ($r['markId'] -is [string]) -and -not [string]::IsNullOrEmpty($r['markId']) -and
                ($r['reason'] -is [string]) -and ($r['reason'] -in $script:VmfScheduleDueReasons) -and
                ($null -ne (ConvertFrom-VmfScheduleDueTime -Value $r['markedUtc'])) -and
                ($null -eq $r['holdUntilUtc'] -or $null -ne (ConvertFrom-VmfScheduleDueTime -Value $r['holdUntilUtc'])) -and
                ($null -eq $r['nextUtc'] -or $null -ne (ConvertFrom-VmfScheduleDueTime -Value $r['nextUtc']))
        }
        if (-not $ok -or -not $seen.Add([string]$r['runId'])) { $valid = $false; continue }
        $entries.Add([ordered]@{
            runId = [string]$r['runId']; markId = [string]$r['markId']; reason = [string]$r['reason']
            markedUtc = [string]$r['markedUtc']
            holdUntilUtc = $(if ($null -eq $r['holdUntilUtc']) { $null } else { [string]$r['holdUntilUtc'] })
            nextUtc = $(if ($null -eq $r['nextUtc']) { $null } else { [string]$r['nextUtc'] })
        })
    }
    [pscustomobject]@{ Valid = $valid; Entries = @($entries) }
}

function ConvertTo-VmfScheduleDueText {
    <# .SYNOPSIS The text of the due record, entries in ordinal order of run id. Pure. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyCollection()][object[]]$Entries = @())
    $ordered = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) { if ($e) { $ordered.Add($e) } }
    # Ordinal, not the culture's order: the same text on every worker, so a
    # record nothing changed is never written again.
    $ordered.Sort([System.Comparison[object]] { param($a, $b) [string]::CompareOrdinal([string]$a['runId'], [string]$b['runId']) })
    ([ordered]@{ schemaVersion = 1; runs = @($ordered) }) | ConvertTo-Json -Depth 6
}

function Read-VmfScheduleDue {
    <#
    .SYNOPSIS
        The due record as the store holds it: Exists, Valid, Entries and the
        Version of its text (PLANVER-2). A store that refuses the read throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StorePath)
    $text = Read-VmfStoreRootText -StorePath $StorePath -Name $script:VmfScheduleDueName
    $parsed = ConvertFrom-VmfScheduleDueText -Text $text
    [pscustomobject]@{
        Exists  = $null -ne $text
        Valid   = $parsed.Valid
        Entries = @($parsed.Entries)
        Version = $(if ($null -ne $text) { Get-VmfDocumentVersion -Text $text } else { $null })
    }
}

function Select-VmfScheduleDueRuns {
    <#
    .SYNOPSIS
        The runs of the due record a pass checks now: each entry with no next
        time, or a next time that has come. In ordinal order of run id. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Entries = @(),
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $now = $NowUtc.ToUniversalTime()
    $out = [System.Collections.Generic.List[string]]::new()
    foreach ($e in @($Entries)) {
        if (-not $e -or -not (Test-VmfScheduleDueRunId -RunId $e['runId'])) { continue }
        $next = ConvertFrom-VmfScheduleDueTime -Value $e['nextUtc']
        if ($null -ne $next -and $next -gt $now) { continue }
        if (-not $out.Contains([string]$e['runId'])) { $out.Add([string]$e['runId']) }
    }
    $out.Sort([System.StringComparer]::Ordinal)
    @($out)
}

function Merge-VmfScheduleDueMark {
    <#
    .SYNOPSIS
        The entries with this run marked: a new mark id, no next time (the
        next pass checks it), and the hold of an engine start. Pure.
    .DESCRIPTION
        A hold never gets shorter: a mark with a shorter hold, or none, keeps
        the hold the entry has.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Entries = @(),
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][int]$HoldMinutes = 0,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $now = $NowUtc.ToUniversalTime()
    $out = [System.Collections.Generic.List[object]]::new()
    $hold = $null
    foreach ($e in @($Entries)) {
        if (-not $e) { continue }
        if ([string]::Equals([string]$e['runId'], $RunId, [System.StringComparison]::Ordinal)) { $hold = ConvertFrom-VmfScheduleDueTime -Value $e['holdUntilUtc']; continue }
        $out.Add($e)
    }
    if ($HoldMinutes -gt 0) {
        $mine = $now.AddMinutes($HoldMinutes)
        if ($null -eq $hold -or $mine -gt $hold) { $hold = $mine }
    }
    $out.Add([ordered]@{
        runId = $RunId; markId = [System.Guid]::NewGuid().ToString('N'); reason = $Reason
        markedUtc = $now.ToString('o')
        holdUntilUtc = $(if ($null -ne $hold) { $hold.ToString('o') } else { $null })
        nextUtc = $null
    })
    @($out)
}

function Merge-VmfScheduleDueChanges {
    <#
    .SYNOPSIS
        The entries after a pass: each run it checked kept, given its next
        time, added, or removed. Pure.
    .DESCRIPTION
        One change for each run the pass checked: RunId; SeenMarkId, the mark
        id the entry had when the pass read the record ($null: the run was not
        in it); Needed, whether Get-VmfRunScheduleNeed found a fact; NextUtc,
        the time it found ('o' text, or $null for now).
          - Not needed: the entry is removed only while it holds SeenMarkId
            and its hold has ended. A path that marked the run since wrote
            another mark id, and its entry stays.
          - Needed, in the record with SeenMarkId: it gets NextUtc.
          - Needed, in the record with another mark id: left as the mark wrote
            it - the next pass checks it.
          - Needed, not in the record: added (reason sweep, a new mark id).
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Entries = @(),
        [Parameter()][AllowEmptyCollection()][object[]]$Changes = @(),
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $now = $NowUtc.ToUniversalTime()
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($e in @($Entries)) { if ($e) { $out.Add($e) } }
    foreach ($c in @($Changes)) {
        if (-not $c -or -not (Test-VmfScheduleDueRunId -RunId ([string]$c.RunId))) { continue }
        $id = [string]$c.RunId
        $at = -1
        for ($i = 0; $i -lt $out.Count; $i++) {
            if ([string]::Equals([string]$out[$i]['runId'], $id, [System.StringComparison]::Ordinal)) { $at = $i; break }
        }
        $seen = if ($c.SeenMarkId) { [string]$c.SeenMarkId } else { $null }
        $same = $at -ge 0 -and $seen -and [string]::Equals([string]$out[$at]['markId'], $seen, [System.StringComparison]::Ordinal)
        if (-not $c.Needed) {
            if (-not $same) { continue }
            $hold = ConvertFrom-VmfScheduleDueTime -Value $out[$at]['holdUntilUtc']
            if ($null -ne $hold -and $hold -gt $now) { continue }
            $out.RemoveAt($at)
            continue
        }
        $next = if ($c.NextUtc) { ConvertFrom-VmfScheduleDueTime -Value $c.NextUtc } else { $null }
        $nextText = if ($null -ne $next -and $next -gt $now) { $next.ToString('o') } else { $null }
        if ($same) { $out[$at]['nextUtc'] = $nextText; continue }
        if ($at -ge 0) { continue }
        $out.Add([ordered]@{
            runId = $id; markId = [System.Guid]::NewGuid().ToString('N'); reason = 'sweep'
            markedUtc = $now.ToString('o'); holdUntilUtc = $null; nextUtc = $nextText
        })
    }
    @($out)
}

function Write-VmfScheduleDueRecord {
    <#
    .SYNOPSIS
        Change the due record in one version-checked write: read it, give its
        entries to -Change, write what comes back only if nobody wrote the
        record in between - else read it again and try again. $true when the
        record holds the change.
    .DESCRIPTION
        A record that is not there is created with a write that fails if it
        exists. A record whose text does not change is not written. A record
        that cannot be used is written over: -Change gets the entries that
        could be read. Throws when the store does not answer.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][scriptblock]$Change,
        # What -Change needs besides the entries: given to it as its second argument.
        [Parameter()][hashtable]$Argument = @{}
    )
    for ($try = 0; $try -lt $script:VmfScheduleDueWriteTries; $try++) {
        $now = Read-VmfScheduleDue -StorePath $StorePath
        $entries = @(& $Change @($now.Entries) $Argument)
        $text = ConvertTo-VmfScheduleDueText -Entries $entries
        if (-not $now.Exists) {
            if (Write-VmfStoreRootTextExclusive -StorePath $StorePath -Name $script:VmfScheduleDueName -Content $text) { return $true }
            continue
        }
        if ($now.Valid -and [string]::Equals((Get-VmfDocumentVersion -Text $text), $now.Version, [System.StringComparison]::Ordinal)) { return $true }
        if (Write-VmfStoreRootTextIfVersion -StorePath $StorePath -Name $script:VmfScheduleDueName -Content $text -ExpectedVersion $now.Version) { return $true }
    }
    $false
}

function Add-VmfScheduleDueRun {
    <#
    .SYNOPSIS
        Mark a run due: the next schedule pass checks it. $true when the
        record holds the mark.
    .DESCRIPTION
        Called AFTER the write that makes the run due (an engine start, a
        schedule saved, a plan sign-off), so a pass that read the run before
        that write also read the record before this mark, and keeps it.
        -HoldMinutes keeps the run in the record that long whatever the pass
        finds: an engine start, whose execution Azure can list late.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][ValidateRange(0, 1440)][int]$HoldMinutes = 0,
        [Parameter()][datetime]$NowUtc = [datetime]::UtcNow
    )
    if (-not (Test-VmfScheduleDueRunId -RunId $RunId)) { throw "'$RunId' is not a run id the schedule pass can check." }
    if ($Reason -notin $script:VmfScheduleDueReasons) { throw "'$Reason' is not a reason the due record knows." }
    $mark = { param($entries, $a) Merge-VmfScheduleDueMark -Entries $entries -RunId $a.RunId -Reason $a.Reason -HoldMinutes $a.HoldMinutes -NowUtc $a.NowUtc }
    Write-VmfScheduleDueRecord -StorePath $StorePath -Change $mark -Argument @{ RunId = $RunId; Reason = $Reason; HoldMinutes = $HoldMinutes; NowUtc = $NowUtc }
}

function Get-VmfStoreRunPlace {
    <#
    .SYNOPSIS
        The store a run path is in, and the run id the schedule pass names it
        by: @{ StorePath; RunId } - or $null when the path names no run of a
        store.
    .DESCRIPTION
        On blob storage a run path is azblob://<account>/<container>/<run id>
        (Get-VmfStoreContext): the store is the container, and the run id is
        'run' or 'project/run'. On the file backend a run is a folder of the
        store, or of a project folder in it, and a project folder holds
        project.json - the rule Get-VmfFacadeRunIds lists the runs by.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath)
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'azblob') {
        $id = ([string]$ctx.Prefix).Trim('/')
        if (-not (Test-VmfScheduleDueRunId -RunId $id)) { return $null }
        return [pscustomobject]@{ StorePath = "azblob://$($ctx.Account)/$($ctx.Container)"; RunId = $id }
    }
    $full = [System.IO.Path]::GetFullPath($RunPath).TrimEnd([char]0x5C, [char]0x2F)
    $leaf = [System.IO.Path]::GetFileName($full)
    $parent = [System.IO.Path]::GetDirectoryName($full)
    if (-not $leaf -or -not $parent) { return $null }
    if ([System.IO.File]::Exists([System.IO.Path]::Combine($parent, 'project.json'))) {
        $top = [System.IO.Path]::GetDirectoryName($parent)
        if (-not $top) { return $null }
        $id = "$([System.IO.Path]::GetFileName($parent))/$leaf"
        if (-not (Test-VmfScheduleDueRunId -RunId $id)) { return $null }
        return [pscustomobject]@{ StorePath = $top; RunId = $id }
    }
    if (-not (Test-VmfScheduleDueRunId -RunId $leaf)) { return $null }
    [pscustomobject]@{ StorePath = $parent; RunId = $leaf }
}

function Add-VmfRunScheduleDue {
    <#
    .SYNOPSIS
        THE ONE MARK: put a run into the record of the runs the five-minute
        schedule pass checks, after the write that made it due. Every path
        that makes a run due calls it - the cmdlets (Set-VmfWaveSchedule,
        Approve-VmfPlan, Resolve-VmfDecision, Clear-VmfWaveHalt,
        Start-VmfWave, and the start of a restore or a finish,
        New-VmfPutBackJob) and the service's engine start. $true when the
        record holds the mark.
    .DESCRIPTION
        The write it follows is already made, so a mark that cannot be
        written never fails it: it is a warning, and the hourly check of
        every run (the sweep) finds the run. -RunPath names the run; the
        service, which knows its store and the run id, gives them as
        -StorePath and -RunId.
    #>
    [CmdletBinding(DefaultParameterSetName = 'path')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'path')][string]$RunPath,
        [Parameter(Mandatory, ParameterSetName = 'id')][string]$StorePath,
        [Parameter(Mandatory, ParameterSetName = 'id')][string]$RunId,
        [Parameter(Mandatory)][string]$Reason,
        [Parameter()][switch]$EngineStart
    )
    try {
        $place = if ($PSCmdlet.ParameterSetName -eq 'id') { [pscustomobject]@{ StorePath = $StorePath; RunId = $RunId } } else { Get-VmfStoreRunPlace -RunPath $RunPath }
        if (-not $place) { throw 'the run path names no run of a store' }
        $hold = if ($EngineStart) { $script:VmfScheduleDueHoldMinutes } else { 0 }
        $ok = Add-VmfScheduleDueRun -StorePath $place.StorePath -RunId $place.RunId -Reason $Reason -HoldMinutes $hold
        if (-not $ok) { throw 'the record changed at the same time five times' }
        $true
    }
    catch {
        Write-Warning "schedule: could not add the run to the record of the runs to check ($Reason): $($_.Exception.Message). The hourly check of every run finds it."
        $false
    }
}

function Test-VmfStoreRunPresent {
    <#
    .SYNOPSIS
        Is there anything of this run in the store? The schedule pass asks it
        of a run of the due record before it checks it, by the rule the sweep
        lists runs by: a folder with anything in it is a run.
    .DESCRIPTION
        run.json is asked first (one small read); without it the run is
        listed. A store that does not answer throws: unknown is not "gone".
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][string]$RunPath)
    if (Test-VmfStoreItem -RunPath $RunPath -RelPath 'run.json') { return $true }
    $ctx = Get-VmfStoreContext -RunPath $RunPath
    if ($ctx.Backend -eq 'file') { return [System.IO.Directory]::Exists($RunPath) }
    @(Get-VmfStoreNames -RunPath $RunPath -Folder '').Count -gt 0
}

function Update-VmfScheduleDue {
    <#
    .SYNOPSIS
        Write what a schedule pass found (Merge-VmfScheduleDueChanges) into
        the due record. $true when the record holds it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter()][AllowEmptyCollection()][object[]]$Changes = @(),
        [Parameter()][datetime]$NowUtc = [datetime]::UtcNow
    )
    $apply = { param($entries, $a) Merge-VmfScheduleDueChanges -Entries $entries -Changes $a.Changes -NowUtc $a.NowUtc }
    Write-VmfScheduleDueRecord -StorePath $StorePath -Change $apply -Argument @{ Changes = @($Changes); NowUtc = $NowUtc }
}

function Get-VmfRunScheduleNeed {
    <#
    .SYNOPSIS
        Does one of the schedule pass's checks act on this run, now or later?
        NextUtc: now (a check acts now), a later time (only a scheduled wave
        whose time has not come), or $null (no check acts on it). Reason: the
        first fact found.
    .DESCRIPTION
        The facts are the questions the checks ask first, so a run with none
        of them is a run every check leaves alone:
          machineWorking  a machine record at a working state (PLANNED to
                          VALIDATING): its wave can have stopped part way
                          (Invoke-VmfFacadeResumeStalledWaves);
          putBackJob      a restore, a rebuild or a finish on a machine record
                          that the service did not give up on
                          (Invoke-VmfFacadeResumeStalledPutBacks);
          volumesCheckStarted a start for the check of the volumes that the
                          return did not end (captured.volumesCheckPower,
                          Invoke-VmfFacadeResumeStalledVolumeChecks);
          holdLive        a hold of a wave worker with a heartbeat that is not
                          old: a worker runs, and can stop;
          holdEnded       an old hold of a wave worker on a machine at a final
                          state (Invoke-VmfFacadeRemoveEndedWaveHolds);
          holdTaken       an old hold of a wave worker on a machine with no
                          record: taken before its check (WAVE-RESUME-PLANNED-1);
          reservingClaim  a quota record at RESERVING: the pass reads its
                          capacity reservation from Azure when no reserve or
                          release job of the run runs
                          (Invoke-VmfFacadeReadReservingClaims, ODCR-STATUS-1);
          planSignedOff  a plan sign-off, and the plan has not run every wave
                          (Invoke-VmfFacadeContinuePlan, plan-run.json);
          scheduleStarted a schedule with a start on record;
          scheduleDue     a pending schedule whose time has come, or whose
                          time cannot be read;
          schedulePending a pending schedule whose time has not come: NextUtc
                          is the earliest such time.
        A hold of a restore is that job's (putBackJob). An old hold on a group
        of machines (an availability set) has no record and does nothing the
        pass acts on. Read in that order, and the first fact for now ends the
        read.
    .PARAMETER StateDocs
        The run's machine records, read once by the pass. None given: read here.
    .PARAMETER ReservingClaims
        ODCR-STATUS-1: the quota records still at RESERVING after the pass read
        them from Azure. None given: read here (Get-VmfReservingClaims).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$StateDocs,
        [Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$ReservingClaims,
        [Parameter()][datetime]$NowUtc = [datetime]::UtcNow
    )
    $now = $NowUtc.ToUniversalTime()
    $at = { param($why) [pscustomobject]@{ NextUtc = $now; Reason = $why } }
    if ($null -eq $StateDocs) {
        $StateDocs = @(foreach ($name in Get-VmfStoreNames -RunPath $RunPath -Folder 'state' -Extension '.json') {
                $doc = Read-VmfStoreJson -RunPath $RunPath -RelPath "state/$name" -Depth 24
                if ($doc) { $doc }
            })
    }
    # VMID-CASE-1: Azure gives one ID in more than one letter case.
    $stateOf = [System.Collections.Generic.Dictionary[string, string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($doc in @($StateDocs)) {
        if (-not $doc) { continue }
        $state = [string]$doc.state
        if ([string]$doc.vmId) { $stateOf[[string]$doc.vmId] = $state }
        if ($state -in $script:VmfWorkingStates) { return (& $at 'machineWorking') }
        $job = Get-VmfPutBackJob -Doc $doc
        if ($job -and [string]$job.operationId -and [string]$job.kind -in @('restore', 'finish')) {
            $ended = Get-VmfRecordField -Object $job -Name 'ended'
            $gaveUp = $ended -and [string](Get-VmfRecordField -Object $ended -Name 'reason') -eq 'gaveUp'
            if (-not $gaveUp) { return (& $at 'putBackJob') }
        }
        # VOLUMES-CHECK-JOB-STOP-1: a start for the check of the volumes that
        # the return did not end (Invoke-VmfFacadeResumeStalledVolumeChecks).
        $volumesStart = Get-VmfVolumesCheckStarted -Doc $doc
        if ($volumesStart -and -not (Get-VmfRecordField -Object $volumesStart -Name 'gaveUp')) { return (& $at 'volumesCheckStarted') }
    }
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'leases' -Extension '.lease')) {
        $lease = Read-VmfStoreJson -RunPath $RunPath -RelPath "leases/$name" -Depth 6
        if (-not $lease) { continue }
        if (Test-VmfPutBackLeaseHolder -WorkerId ([string]$lease.workerId)) { continue }
        if (-not (Test-VmfMachineLeaseExpired -Lease $lease)) { return (& $at 'holdLive') }
        $vmId = [string]$lease.vmId
        if (-not $vmId -or $vmId.StartsWith('group-', [System.StringComparison]::Ordinal)) { continue }
        if (-not $stateOf.ContainsKey($vmId)) { return (& $at 'holdTaken') }
        if ($stateOf[$vmId] -in $script:VmfTerminalStates) { return (& $at 'holdEnded') }
    }
    # ODCR-STATUS-1: a capacity reservation nobody confirmed can bill, and the
    # pass reads it from Azure until it has an answer.
    if ($null -eq $ReservingClaims) { $ReservingClaims = @(Get-VmfReservingClaims -RunPath $RunPath) }
    if (@($ReservingClaims | Where-Object { $_ }).Count -gt 0) { return (& $at 'reservingClaim') }
    if (Test-VmfStoreItem -RunPath $RunPath -RelPath 'plan-approval.json') {
        $planRun = Read-VmfStoreJson -RunPath $RunPath -RelPath 'plan-run.json' -Depth 4
        if (-not $planRun -or [string]$planRun.reason -ne 'done') { return (& $at 'planSignedOff') }
    }
    $earliest = $null
    foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'schedules' -Extension '.json')) {
        $text = Read-VmfStoreText -RunPath $RunPath -RelPath "schedules/$name"
        if ($null -eq $text) { continue }
        $doc = $null
        try { $doc = $text | ConvertFrom-Json -Depth 8 -DateKind String } catch { return (& $at 'scheduleDue') }
        if (-not $doc) { continue }
        if ([string]$doc.state -in @('starting', 'started')) { return (& $at 'scheduleStarted') }
        $runAt = ConvertFrom-VmfScheduleDueTime -Value $doc.runAtUtc
        if ($null -eq $runAt -or $runAt -le $now) { return (& $at 'scheduleDue') }
        if ($null -eq $earliest -or $runAt -lt $earliest) { $earliest = $runAt }
    }
    if ($null -ne $earliest) { return [pscustomobject]@{ NextUtc = $earliest; Reason = 'schedulePending' } }
    [pscustomobject]@{ NextUtc = $null; Reason = $null }
}

function Test-VmfScheduleSweepOpen {
    <#
    .SYNOPSIS
        Does this pass check every run in the store (the sweep)? Pure.
    .DESCRIPTION
        Yes when the due record is not there or cannot be used, when the pass
        record cannot be used, when a sweep is open (sweepStartedUtc), and
        when the last sweep ended an hour ago or more - or at a time that is
        not read, or more than 5 minutes ahead of this clock: a clock that
        went back must not stop the sweep for ever.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Previous,
        [Parameter(Mandatory)][bool]$DueUsable,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    if (-not $DueUsable) { return $true }
    $read = Get-VmfSchedulePassCursor -Previous $Previous
    if (-not $read.Valid) { return $true }
    if ($read.SweepStartedUtc) { return $true }
    $last = ConvertFrom-VmfScheduleDueTime -Value $read.LastSweepUtc
    if ($null -eq $last) { return $true }
    $now = $NowUtc.ToUniversalTime()
    if ($last -gt $now.AddMinutes(5)) { return $true }
    ($now - $last).TotalMinutes -ge $script:VmfScheduleSweepMinutes
}
