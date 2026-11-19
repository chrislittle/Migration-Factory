# SCHEDULE-START-ONCE-1: a scheduled wave starts once.
#
# The schedule pass started the engine for a due wave and then removed the
# wave's schedule. A service stopped between the two, or a removal that threw,
# left the schedule due: the next passes left it alone while the first run went
# on (Test-VmfFacadeEngineRunning), and the pass after that run ended started
# the wave a second time.
#
# So the start goes on record in the schedule document itself, BEFORE the
# start: state 'starting' with a new start id, which the engine start carries
# to Azure (VMF_SCHEDULE_START). After the start the record names the
# executions (state 'started'). Each write and the removal are version-checked
# (PLANVER-2), so a schedule a person changed or cancelled in between is never
# written over or removed.
# SCHEDULE-WAVE-VERSION-1: the start also carries the version of the wave the
# pass judged (VMF_WAVE_VERSION), and the ENGINE removes the schedule once its
# own read of the wave is that version (Remove-VmfScheduleOfStart). When it is
# not, the engine does not start the wave and puts the schedule back to
# 'pending' (Reset-VmfScheduleStartRecord -StartId) - so the wave stays
# scheduled, as the engine's words say. Only the engine run of THIS start
# (its start id) does either. The service never removes or puts back a
# schedule while an engine run of its start goes on.
# A pass that finds a start on record never starts it as a new one:
#   - 'started': the engine was started. While a run of this start goes on,
#     the schedule is left to the engine; after it, the service removes it.
#   - 'starting': Azure is asked for an execution with the start id. One there
#     means the wave started; none means the start was not made, and the wave
#     goes through the gates again as a due wave, with a new start id. A gate
#     that stops it puts the schedule back to 'pending'
#     (Reset-VmfScheduleStartRecord, SCHEDULE-STARTING-STUCK-1), as a due
#     wave's first try leaves it.
# Remove-then-start would lose a start when the pass stops between the two;
# this order loses nothing and starts nothing twice.

function Get-VmfWaveScheduleSchemaVersion {
    <#
    .SYNOPSIS
        SCHEDULE-SCHEMA-1: the version of schedules/<wave>.json that the
        service writes (schemas/wave-schedule.schema.json).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param()
    1
}

function Test-VmfScheduleDue {
    <#
    .SYNOPSIS
        Is this pending schedule's start time at or before AsOf? The one rule,
        for the schedule pass (Get-VmfScheduleStep) and its tests.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][datetime]$AsOf
    )
    if ([string]$Schedule.state -ne 'pending') { return $false }
    # A document read with ConvertFrom-Json holds a date value; one read with
    # -DateKind String holds the text that was written ('o', UTC).
    $value = $Schedule.runAtUtc
    $runAt = if ($value -is [datetime]) { $value.ToUniversalTime() }
             else { [datetime]::Parse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal) }
    $runAt -le $AsOf.ToUniversalTime()
}

# SCHEDULE-START-ONCE-1 review: how long a start record with no execution in
# Azure is left alone. Two passes can overlap - nothing published proves that
# the timer runs on one instance (TIMER-SINGLETON-LAB-1 is open) - and a pass
# that reads a record another pass wrote a moment ago, before that pass started
# the engine or before Azure lists the start, must not start the wave too. A
# pass stops starting runs at 210 seconds (TIMER-PASS-LIMIT-1), the host stops
# a call at 5 minutes, and the timer fires every 5 minutes: a pass that wrote a
# record is over well inside 10 minutes. So a record younger than that waits,
# and a start Azure refused is made again on the first pass after it.
$script:VmfScheduleStartGraceSeconds = 600

function Test-VmfScheduleStartFresh {
    <#
    .SYNOPSIS
        Is this start record younger than the grace period - so it may belong
        to a pass that still starts the engine? Read from the record's own
        startingUtc, as the service wrote it.
    .DESCRIPTION
        startingUtc is written as 'o', UTC. Read with -DateKind String it is
        that text; read by ConvertFrom-Json without it, a date value - both
        are taken. A record with no time, or one that cannot be read, is not
        fresh: the wave is never held for ever.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]$Schedule,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $value = if ($Schedule.PSObject.Properties['startingUtc']) { $Schedule.startingUtc } else { $null }
    if ($null -eq $value -or "$value" -eq '') { return $false }
    $at = [datetime]::MinValue
    if ($value -is [datetime]) { $at = $value.ToUniversalTime() }
    elseif (-not [datetime]::TryParse([string]$value, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal, [ref]$at)) { return $false }
    ($NowUtc.ToUniversalTime() - $at).TotalSeconds -lt $script:VmfScheduleStartGraceSeconds
}

function Get-VmfScheduleStep {
    <#
    .SYNOPSIS
        What the schedule pass does with each schedule of a run, from ONE
        listing: 'due', 'starting' or 'started'. A pending schedule whose time
        has not come is not returned.
    .DESCRIPTION
        Each document is read as text, so the version the pass judges goes
        with it (Get-VmfDocumentVersion), and dates stay text.
    .OUTPUTS
        @{ Wave; Step; Schedule; Version } for each.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter()][datetime]$AsOf = (Get-Date).ToUniversalTime()
    )
    $out = foreach ($name in @(Get-VmfStoreNames -RunPath $RunPath -Folder 'schedules' -Extension '.json')) {
        $text = Read-VmfStoreText -RunPath $RunPath -RelPath "schedules/$name"
        if ($null -eq $text) { continue }
        $doc = $text | ConvertFrom-Json -Depth 8 -DateKind String
        $step = switch ([string]$doc.state) {
            'started' { 'started' }
            'starting' { 'starting' }
            default { if (Test-VmfScheduleDue -Schedule $doc -AsOf $AsOf) { 'due' } else { $null } }
        }
        if (-not $step) { continue }
        [pscustomobject]@{ Wave = [string]$doc.wave; Step = $step; Schedule = $doc; Version = (Get-VmfDocumentVersion -Text $text) }
    }
    @($out)
}

function Set-VmfScheduleStartRecord {
    <#
    .SYNOPSIS
        Write the start record into a wave's schedule, only if the schedule
        still holds the version the pass judged.
    .DESCRIPTION
        -Starting: state 'starting' with a new start id - written BEFORE the
        start. With -Executions: state 'started' and the executions - written
        after it. Dates stay text: the document is read with -DateKind String.
    .OUTPUTS
        @{ StartId; Version } - the version of the text written - or $null
        when the schedule changed or is gone. A store that does not answer
        throws.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$Version,
        [Parameter(Mandatory, ParameterSetName = 'starting')][switch]$Starting,
        # SCHEDULE-SCHEMA-1: a start whose answer named no execution is still
        # written as started, with an empty list (schemas/wave-schedule).
        [Parameter(Mandatory, ParameterSetName = 'started')][AllowEmptyCollection()][string[]]$Executions
    )
    $rel = "schedules/$Wave.json"
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
    if ($null -eq $text -or (Get-VmfDocumentVersion -Text $text) -ne $Version) { return $null }
    $doc = $text | ConvertFrom-Json -Depth 8 -DateKind String -AsHashtable
    $now = (Get-Date).ToUniversalTime().ToString('o')
    if ($Starting) {
        $doc['state'] = 'starting'
        $doc['startId'] = [System.Guid]::NewGuid().ToString('N')
        $doc['startingUtc'] = $now
        $doc['executions'] = @()
        $doc['startedUtc'] = $null
    }
    else {
        $doc['state'] = 'started'
        $doc['executions'] = @($Executions)
        $doc['startedUtc'] = $now
    }
    $content = $doc | ConvertTo-Json -Depth 8
    if (-not (Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath $rel -Content $content -ExpectedVersion $Version)) { return $null }
    [pscustomobject]@{ StartId = [string]$doc['startId']; Version = (Get-VmfDocumentVersion -Text $content) }
}

function Reset-VmfScheduleStartRecord {
    <#
    .SYNOPSIS
        SCHEDULE-STARTING-STUCK-1: put a 'starting' schedule back to
        'pending', only if it still holds the version the pass judged.
    .DESCRIPTION
        A start record older than the grace period, with no execution in
        Azure, goes through the start checks again. When a check stops it,
        the schedule must be what a due schedule whose check fails on its
        first try is: pending, with the start time, the window and the note as
        they were written, and no start on record. So the page offers the
        cancel, the service accepts it, and the activity line that names it is
        true. Before, the record stayed 'starting': the page said the wave was
        starting, and the service refused the cancel.
        Dates stay text: the document is read with -DateKind String.
    .OUTPUTS
        $true when this call wrote it; $false when the schedule changed, is
        gone or holds no start record. A store that does not answer throws.
    #>
    [CmdletBinding(DefaultParameterSetName = 'version')]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        # The service's schedule pass: the version it judged. Only a
        # 'starting' record - a start the pass found was not made.
        [Parameter(Mandatory, ParameterSetName = 'version')][string]$Version,
        # SCHEDULE-WAVE-VERSION-1: the engine run of a scheduled start whose
        # own read of the wave differs from the version the pass judged. Only
        # the record of THIS start ('starting' or 'started' with this start
        # id): the wave did not start, so the schedule must stay. The version
        # is the one this call reads, checked by the write.
        [Parameter(Mandatory, ParameterSetName = 'start')][string]$StartId
    )
    $rel = "schedules/$Wave.json"
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
    if ($null -eq $text) { return $false }
    $doc = $text | ConvertFrom-Json -Depth 8 -DateKind String -AsHashtable
    if ($PSCmdlet.ParameterSetName -eq 'start') {
        if (-not (Test-VmfScheduleOfStart -Schedule $doc -StartId $StartId)) { return $false }
        $Version = Get-VmfDocumentVersion -Text $text
    }
    elseif ([string]$doc['state'] -ne 'starting') { return $false }
    # The version is checked by the write itself, in one step with it
    # (PLAN-WRITE-RACE-1): another version is never written over.
    # schemas/wave-schedule: a pending schedule has no start on record. Every
    # other field keeps the value that was written (dates stay text).
    $kept = $text | ConvertFrom-Json -Depth 8 -DateKind String -AsHashtable
    foreach ($name in 'startId', 'startingUtc', 'executions', 'startedUtc') { [void]$kept.Remove($name) }
    $kept['state'] = 'pending'
    $content = $kept | ConvertTo-Json -Depth 8
    [bool](Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath $rel -Content $content -ExpectedVersion $Version)
}

function Remove-VmfStartedSchedule {
    <#
    .SYNOPSIS
        Remove a wave's schedule whose start is made, only if it still holds
        the version the pass wrote or judged. $true when this call removed it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$Version
    )
    Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath "schedules/$Wave.json" -ExpectedVersion $Version
}

function Test-VmfScheduleOfStart {
    <#
    .SYNOPSIS
        SCHEDULE-WAVE-VERSION-1: does this schedule hold the record of the
        start with this start id ('starting' or 'started')? The one rule for
        what the engine run of a scheduled start may remove or put back.
        Ordinal: a start id is lower-case hex.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Schedule, [Parameter(Mandatory)][string]$StartId)
    if (-not $Schedule) { return $false }
    $state = if ($Schedule -is [System.Collections.IDictionary]) { [string]$Schedule['state'] } else { [string]$Schedule.state }
    $id = if ($Schedule -is [System.Collections.IDictionary]) { [string]$Schedule['startId'] } else { [string]$Schedule.startId }
    ($state -in @('starting', 'started')) -and [string]::Equals($id, $StartId, [System.StringComparison]::Ordinal)
}

function Remove-VmfScheduleOfStart {
    <#
    .SYNOPSIS
        SCHEDULE-WAVE-VERSION-1: the engine run of a scheduled start removes
        the wave's schedule once its own read of the wave is the version the
        pass judged - only if the schedule still holds the record of THIS
        start, and only the version this call read.
    .OUTPUTS
        $true when this call removed it; $false when the schedule is gone,
        changed, or holds another start. A store that does not answer throws.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$Wave,
        [Parameter(Mandatory)][string]$StartId
    )
    $rel = "schedules/$Wave.json"
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
    if ($null -eq $text) { return $false }
    $doc = $text | ConvertFrom-Json -Depth 8 -DateKind String -AsHashtable
    if (-not (Test-VmfScheduleOfStart -Schedule $doc -StartId $StartId)) { return $false }
    [bool](Remove-VmfStoreItemIfVersion -RunPath $RunPath -RelPath $rel -ExpectedVersion (Get-VmfDocumentVersion -Text $text))
}

function Get-VmfScheduleStartRefusal {
    <#
    .SYNOPSIS
        The refusal for a person who cancels, or sets again, a schedule whose
        start is on record - or $null. Its start was made or is being made,
        and a cancel or a new time then would say what did not happen.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Schedule, [Parameter(Mandatory)][string]$Wave)
    if (-not $Schedule -or [string]$Schedule.state -notin @('starting', 'started')) { return $null }
    "409: The service started wave $Wave at its scheduled time, or is starting it now, so you cannot change its scheduled start. The engine removes the start time when it starts the wave. If the wave changed, the wave stays scheduled."
}
