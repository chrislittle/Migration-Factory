# RESTORE-END-JOB-1: a restore whose job stops resumes from its
# last checkpoint, the way a wave does.
#
# A wave's machine has its steps on its state document (state, pathCheckpoint),
# so the service's timer finds a wave that stopped mid-flight and starts it
# again (Invoke-VmfFacadeResumeStalledWaves). Restore this machine had nothing
# like it: its job runs once (replicaRetryLimit 0),
# and a job the platform stopped - out of memory, the time limit, a restart -
# left the machine part way, possibly stopped, possibly with no definition in
# Azure, and the Migrations page said "Restoring" for ever. Decided 2026-10-19
# and again 2026-10-24: a restore resumes, as a wave does.
#
# So each restore keeps its own checkpoint on the machine's record,
# putBackJob (vm-state v27):
#
#   kind, operationId   restore, and the engine operation's id - the
#                       id on its start line and in its lease holder
#                       (RESTORE-ONE-AT-A-TIME-1), so a resume takes over the
#                       lease of the SAME restore and the page ends the SAME
#                       restore on the engine's own fail line.
#   options, startedBy, note, stamp
#                       what the person asked for, and the time in every disk
#                       name. A resume uses these, never the request that
#                       started it again, so every disk it asks for has the name
#                       the first job gave it - and New-VmfDiskFromSnapshot
#                       returns the disk of that name: never a second set.
#   before              what the machine was before the job changed it (its OS
#                       disk, its data disks, its size). After the swap the
#                       machine's OS disk IS the restored one, so a resume that
#                       read it again would restore the restored disk.
#   phase               the last step that ended. Each step saves it when it
#                       ends (rule 4); a resume does every step after it, and
#                       asks Azure where it must (a step killed half way).
#   made, os, dataLuns, result
#                       what the steps found or made that later steps need.
#   resumes             how many times the service started it again. At
#                       $script:VmfPutBackResumeLimit the service stops trying,
#                       ends the row with the engine's fail line, and removes
#                       the record, so a person can start a new one.
#   ended               a job that ended with an answer (a failure the restore
#                       said). Not resumed: the service only makes sure the row
#                       ends, then removes the record.
#
# FINISH-END-JOB-1 (vm-state v33): Finish the rollback and Finish the restore
# (Complete-VmfDataDiskSwap) keep the same checkpoint, kind finish, with the
# finish they do in options.finishes. A finish makes no disk, so it needs only
# three steps: begun, dataSwapped and started. Each swap Azure takes is on the
# swap record the moment it took (swapPending), so a resume reads each LUN and
# swaps only the disks that are left.
#
# The record is removed in the same write as the restore's own
# record. While it stands - and is not ended - a new restore or finish
# of the machine is refused (Get-VmfPutBackJobRefusal), and retention keeps the
# machine's safety copies and every disk made for it (Retention.ps1): the resume
# needs them, and so does a machine left part way, which is restored from
# them.

# The steps, in the order they end. Each path uses some of them, always in this
# order: in place (stopped, hardware, osOnTemp ...). OLD-REBUILD-RESTORE-READERS-1:
# the steps of a rebuild (rebuildRead, shellDeleted, rebuilt, renameStopped)
# are gone, and a record that names one is not resumed (a step this version
# does not know).
# RESTORE-ORIGINAL-DELETE-RESTART-1 (vm-state v43): keeping the names, a
# delete of the original OS disk that Azure refuses goes back instead
# (osOnTemp, originalKept, originalBack, originalStarted - then the job ends).
# Those steps come before originalRemoved, so a resume from one of them never
# goes on to make the disk under the name.
$script:VmfPutBackJobPhases = @(
    'begun', 'made', 'stopped', 'hardware',
    'osOnTemp', 'originalKept', 'originalBack', 'originalStarted', 'originalRemoved', 'osSwapped', 'tempRemoved',
    'dataSwapped', 'started'
)
# How many times the service starts a stopped restore again. A job
# that dies the same way each time (out of memory on the same step) would
# otherwise start every five minutes for ever.
$script:VmfPutBackResumeLimit = 3

function Get-VmfPutBackJob {
    <# .SYNOPSIS The putBackJob record of a machine, or $null. Pure. #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    Get-VmfRecordField -Object $Doc -Name 'putBackJob'
}

function Test-VmfPutBackJobOpen {
    <#
    .SYNOPSIS
        Does this machine's record hold a restore that has not
        ended - one whose job stopped, or one that runs now? Pure.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    $job = Get-VmfPutBackJob -Doc $Doc
    [bool]($job -and -not (Get-VmfRecordField -Object $job -Name 'ended'))
}

function Test-VmfPutBackJobHolds {
    <#
    .SYNOPSIS
        RESUME-GIVEUP-KEEP-1: does this machine's record keep its safety copies
        and every disk made for it from the daily cleanup? Pure.
    .DESCRIPTION
        Yes while a restore has not ended (its resume needs them),
        while the record says the service gave up on one (ended, reason
        gaveUp: the machine can be part way), and while a later restore
        carries that mark (held) and has not finished. Only the write
        that records a restore that finished removes the record,
        and with it the hold. The rule: a machine can always get back.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    $job = Get-VmfPutBackJob -Doc $Doc
    if (-not $job) { return $false }
    $ended = Get-VmfRecordField -Object $job -Name 'ended'
    [bool](-not $ended -or [string](Get-VmfRecordField -Object $ended -Name 'reason') -eq 'gaveUp' -or (Get-VmfRecordField -Object $job -Name 'held'))
}

function Get-VmfPutBackHoldDeleteWords {
    <#
    .SYNOPSIS
        DISCARD-PUTBACK-HOLD-1: what holds this machine and what the person
        does about it, for the refusal of Delete this migration - or $null when
        the record holds nothing. Pure.
    .DESCRIPTION
        The same two cases as Get-VmfPutBackHoldWhy (Test-VmfPutBackJobOpen,
        else a job that stopped and did not finish), said as the product's
        action (Get-VmfPutBackJobWords), and what to do: wait for a job that
        has not ended; else the same action again.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    if (-not (Test-VmfPutBackJobHolds -Doc $Doc)) { return $null }
    $job = Get-VmfPutBackJob -Doc $Doc
    $action = Get-VmfPutBackJobWords -Job $job
    if (Test-VmfPutBackJobOpen -Doc $Doc) { return "$action has not ended. Wait until it ends." }
    "$action stopped and did not finish. Use $action again."
}

function Get-VmfPutBackHoldWhy {
    <#
    .SYNOPSIS
        Why the cleanup keeps this machine's copies, in words - or $null when
        the record holds nothing. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    if (-not (Test-VmfPutBackJobHolds -Doc $Doc)) { return $null }
    $job = Get-VmfPutBackJob -Doc $Doc
    $kind = [string]$job.kind
    if (Test-VmfPutBackJobOpen -Doc $Doc) {
        $what = if ($kind -eq 'finish') { "$(Get-VmfPutBackJobWords -Job $job) of this machine" } else { "a $kind of this machine" }
        return "$what has not ended, so its safety copies were left alone"
    }
    "a restore of this machine stopped and did not finish, and the machine needs a person, so its safety copies were left alone until a restore of it finishes"
}

function Test-VmfPutBackJobPast {
    <#
    .SYNOPSIS
        Has this job ended the step -Phase (or a later one)? Pure. No job means
        no step has ended. A phase this version does not know throws: a resume
        never guesses where a machine stands.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowNull()]$Job,
        [Parameter(Mandatory)][string]$Phase
    )
    $want = [array]::IndexOf($script:VmfPutBackJobPhases, $Phase)
    if ($want -lt 0) { throw "'$Phase' is not a step of a restore." }
    if (-not $Job) { return $false }
    $now = [string](Get-VmfRecordField -Object $Job -Name 'phase')
    $at = [array]::IndexOf($script:VmfPutBackJobPhases, $now)
    if ($at -lt 0) { throw "The record of this $([string](Get-VmfRecordField -Object $Job -Name 'kind')) names the step '$now', which this version of the product does not know. It does not resume it." }
    $at -ge $want
}

function Get-VmfPutBackJobWords {
    <#
    .SYNOPSIS
        FINISH-END-JOB-1: the product's action a job record names - Restore
        this machine, Finish the rollback or Finish the restore. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Job)
    if ([string](Get-VmfRecordField -Object $Job -Name 'kind') -eq 'finish') {
        $of = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $Job -Name 'options') -Name 'finishes')
        return (Get-VmfFinishActionName -Kind $(if ($of -eq 'restore') { 'restore' } else { 'rollback' }))
    }
    Get-VmfPutBackKindWords -Kind ([string](Get-VmfRecordField -Object $Job -Name 'kind'))
}

function Get-VmfPutBackKindWords {
    <# .SYNOPSIS 'restore', said as the product's action. Pure. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Kind)
    'Restore this machine'
}

function Get-VmfPutBackJobRefusal {
    <#
    .SYNOPSIS
        The refusal of a new restore or finish while an earlier one of
        this machine has not ended - or $null. Pure.
    .DESCRIPTION
        A job that stopped part way resumes by itself (the service's timer).
        A second job over it would start from a machine that is part way: it
        would read the restored disk as the machine's own, make a second set
        of disks. -OperationId
        is the job's own resume, which is never refused here.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter()][AllowEmptyString()][string]$OperationId
    )
    if (-not (Test-VmfPutBackJobOpen -Doc $Doc)) { return $null }
    $job = Get-VmfPutBackJob -Doc $Doc
    if ($OperationId -and [string]::Equals([string]$job.operationId, $OperationId, [System.StringComparison]::Ordinal)) { return $null }
    $action = Get-VmfPutBackJobWords -Job $job
    # FINISH-END-JOB-1: a finish runs now, or its job stopped and the service
    # starts it again.
    if ([string]$job.kind -eq 'finish') {
        return "$action of '$VmName' has not ended. If its job stopped, the service starts it again by itself. Wait until it ends, then try again."
    }
    "$action of '$VmName' did not finish: its job stopped part way. The service starts it again by itself from its last step. Wait until it ends, then try again."
}

function Get-VmfPutBackMidMoveRefusal {
    <#
    .SYNOPSIS
        RESTORE-MID-MOVE-1: the refusal of a NEW restore of a
        machine whose move has not ended - or $null. Pure.
    .DESCRIPTION
        Decided 2026-10-19: the wave's own resume and rollback own a
        machine the wave started. A restore of a machine mid-move is refused,
        also when its wave worker died; Stop this migration is the way to get
        it back now (it closes the machine out, and Restore this machine is
        offered then). Before, a restore took the dead worker's hold, put the
        disks back, and the restarted wave went on with the move on them.
        "Not ended" is the engine's own list of working states, never a list
        of its own here. A resume of a restore (-Resume) is never
        asked: it finishes what it started.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][ValidateSet('restore')][string]$Kind
    )
    if (-not $Doc) { return $null }
    $state = [string](Get-VmfRecordField -Object $Doc -Name 'state')
    if ($state -notin @((Get-VmfEngineStates).Working)) { return $null }
    $action = Get-VmfPutBackKindWords -Kind $Kind
    "The move of '$VmName' has not ended: it is at the step $state. $action is refused until the move ends, also if the wave stopped. The wave owns the machine, and rolls it back if the move fails. To get the machine back now, use Stop this migration, then restore the machine."
}

function New-VmfPutBackJob {
    <#
    .SYNOPSIS
        Write the checkpoint a restore starts with (phase begun),
        before it changes anything. Throws when it cannot be written: nothing
        has changed, and a job with no checkpoint cannot be resumed.
    .OUTPUTS
        The token the other functions here take: RunPath, VmId, Job (the
        record as written, kept in memory).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][ValidateSet('restore', 'finish')][string]$Kind,
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter()][AllowEmptyString()][string]$StartedBy = '',
        [Parameter()][AllowEmptyString()][string]$Note = '',
        [Parameter(Mandatory)][hashtable]$Options,
        [Parameter(Mandatory)][string]$Stamp,
        [Parameter()][AllowNull()]$Before,
        # POWER-AFTER-MOVE-1 (vm-state v39): the power state the job read
        # before it changed anything (Get-VmfJobStartPower), kept so a resume
        # returns the machine to it.
        [Parameter()][AllowEmptyString()][AllowNull()][string]$PowerAtStart = ''
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { throw "No record of '$VmId' in this run." }
    $now = (Get-Date).ToUniversalTime().ToString('o')
    # RESUME-GIVEUP-KEEP-1: a restore the service gave up on, or one that
    # carried that mark, holds the copies until a restore
    # finishes. This job carries the mark on; its own finished record ends it.
    $earlier = Get-VmfPutBackJob -Doc $doc
    $held = $null
    # FINISH-END-JOB-1: a finish keeps the earlier record whole (prior) and
    # puts it back when it ends, so it carries no mark of its own.
    $prior = $null
    if ($Kind -eq 'finish' -and $earlier) {
        # A record that has not ended is never kept as prior: its job runs, or
        # the service starts it again. Asked here, in the write itself - the
        # finish asked before it took the hold, and a restore can start in
        # between. Refused before anything changes.
        $open = Get-VmfPutBackJobRefusal -Doc $doc -VmName (($VmId -split '/')[-1]) -OperationId $OperationId
        if ($open) { throw $open }
        $prior = if ([string]$earlier.kind -eq 'finish') { Get-VmfRecordField -Object $earlier -Name 'prior' } else { $earlier }
    }
    elseif ($earlier -and (Test-VmfPutBackJobHolds -Doc $doc)) {
        $held = Get-VmfRecordField -Object $earlier -Name 'held'
        if (-not $held) {
            $endedWhy = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $earlier -Name 'ended') -Name 'why')
            $held = [pscustomobject][ordered]@{ operationId = [string]$earlier.operationId; sinceUtc = $now; why = $(if ($endedWhy) { $endedWhy } else { $null }) }
        }
    }
    $job = [pscustomobject][ordered]@{
        kind        = $Kind
        operationId = $OperationId
        startedUtc  = $now
        startedBy   = $StartedBy
        note        = $Note
        options     = [pscustomobject]$Options
        stamp       = $Stamp
        phase       = 'begun'
        phaseUtc    = $now
        resumes     = 0
        before      = $Before
    }
    if ($held) { $job | Add-Member -NotePropertyName held -NotePropertyValue $held -Force }
    if ($prior) { $job | Add-Member -NotePropertyName prior -NotePropertyValue $prior -Force }
    if ($PowerAtStart) { $job | Add-Member -NotePropertyName powerAtStart -NotePropertyValue $PowerAtStart -Force }
    $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue $job -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    # SCHEDULE-PASS-DUE-1: the restore or the finish has its checkpoint, and
    # can stop part way, so the five-minute pass checks this run. Never throws.
    Add-VmfRunScheduleDue -RunPath $RunPath -Reason 'engine' -EngineStart | Out-Null
    [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Job = $job }
}

function Get-VmfPutBackJobToken {
    <#
    .SYNOPSIS
        A resume's token: the job on the machine's record, if it is the job
        with this operation id and kind and it has not ended. Throws otherwise -
        a resume never takes another job's record.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][ValidateSet('restore', 'finish')][string]$Kind,
        [Parameter()][AllowEmptyString()][string]$OperationId
    )
    $vmName = ($VmId -split '/')[-1]
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $job = Get-VmfPutBackJob -Doc $doc
    # FINISH-END-JOB-1: a finish is named by the finish its record says.
    $action = if ($Kind -ne 'finish') { Get-VmfPutBackKindWords -Kind $Kind }
              elseif ($job -and [string]$job.kind -eq 'finish') { Get-VmfPutBackJobWords -Job $job }
              else { 'finish' }
    if (-not $job -or -not $OperationId -or [string]$job.kind -ne $Kind -or
        -not [string]::Equals([string]$job.operationId, $OperationId, [System.StringComparison]::Ordinal)) {
        throw "There is no $action of '$vmName' with the id '$OperationId' to start again. Nothing was changed."
    }
    if (Get-VmfRecordField -Object $job -Name 'ended') {
        throw "$action of '$vmName' ended already, so it is not started again. Nothing was changed."
    }
    # A phase this version does not know is refused before anything changes.
    $null = Test-VmfPutBackJobPast -Job $job -Phase 'begun'
    [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Job = $job }
}

function Save-VmfPutBackJobStep {
    <#
    .SYNOPSIS
        Save that a step ended, with what later steps need from it (-Data:
        fields of the record, written in the same write). The record on the
        machine is replaced by the token's copy, which this job owns.
    .DESCRIPTION
        -MustWrite throws when it cannot be written - for the steps before the
        machine changes. Without it this never throws: inside the stopped
        window a checkpoint that cannot be written must never leave a machine
        stopped. A resume then starts at the step before, and every step is
        safe to do again.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Token,
        [Parameter(Mandatory)][string]$Phase,
        [Parameter()][hashtable]$Data = @{},
        [Parameter()][switch]$MustWrite
    )
    if (-not $Token) { return }
    if ([array]::IndexOf($script:VmfPutBackJobPhases, $Phase) -lt 0) { throw "'$Phase' is not a step of a restore." }
    $job = $Token.Job
    foreach ($k in $Data.Keys) { $job | Add-Member -NotePropertyName $k -NotePropertyValue $Data[$k] -Force }
    # A step that ended stays ended: the phase only moves forward.
    if (-not (Test-VmfPutBackJobPast -Job $job -Phase $Phase) -or [string]$job.phase -eq $Phase) {
        $job | Add-Member -NotePropertyName phase -NotePropertyValue $Phase -Force
        $job | Add-Member -NotePropertyName phaseUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    try {
        $doc = Read-VmfStateDoc -RunPath $Token.RunPath -VmId $Token.VmId
        if (-not $doc) { throw "No record of '$($Token.VmId)' in this run." }
        $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue $job -Force
        Write-VmfStateDoc -RunPath $Token.RunPath -Document $doc
    }
    catch {
        if ($MustWrite) { throw }
        Write-Warning "The step '$Phase' of $(Get-VmfPutBackJobWords -Job $job) on '$(($Token.VmId -split '/')[-1])' is done, and its checkpoint was not written: $($_.Exception.Message). If the job stops now, the step is done again."
    }
}

function Save-VmfPutBackJobData {
    <#
    .SYNOPSIS
        Save fields of the record without a new step (for example each data
        disk's step while the data disks are swapped). Never throws.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Token, [Parameter(Mandatory)][hashtable]$Data)
    if (-not $Token) { return }
    Save-VmfPutBackJobStep -Token $Token -Phase ([string]$Token.Job.phase) -Data $Data
}

function Remove-VmfPutBackJobOnDoc {
    <#
    .SYNOPSIS
        Remove this job's record from a document in memory, for the write that
        records how the restore ended. Only this job's own
        record is removed. Pure.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Doc, [Parameter()][AllowNull()]$Token)
    if (-not $Token) { return }
    $job = Get-VmfPutBackJob -Doc $Doc
    if ($job -and [string]::Equals([string]$job.operationId, [string]$Token.Job.operationId, [System.StringComparison]::Ordinal)) {
        $Doc.PSObject.Properties.Remove('putBackJob')
    }
}

function Get-VmfPutBackJobBehind {
    <#
    .SYNOPSIS
        FINISH-END-JOB-1: the record of a restore on the machine,
        also while a finish stands over it - the finish keeps it whole as
        prior. Pure. The readers of a restore's own record (its settings, its
        operation, what Finish the restore writes from) ask this.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $job = Get-VmfPutBackJob -Doc $Doc
    if ($job -and [string]$job.kind -eq 'finish') { return (Get-VmfRecordField -Object $job -Name 'prior') }
    $job
}

function Remove-VmfFinishJobOnDoc {
    <#
    .SYNOPSIS
        FINISH-END-JOB-1: end a finish's own record on a document in memory,
        for the write that records how the finish ended. Pure.
    .DESCRIPTION
        Only this job's own record is touched. The record it stood over
        (prior) goes back as it was - a restore the service gave up on keeps
        its hold (RESUME-GIVEUP-KEEP-1) and what Finish the restore writes its
        record from. A finish with none removes its record.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Doc, [Parameter()][AllowNull()]$Token)
    if (-not $Token) { return }
    $job = Get-VmfPutBackJob -Doc $Doc
    if (-not $job -or [string]$job.kind -ne 'finish' -or -not [string]::Equals([string]$job.operationId, [string]$Token.Job.operationId, [System.StringComparison]::Ordinal)) { return }
    $prior = Get-VmfRecordField -Object $job -Name 'prior'
    if ($prior) { $Doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue $prior -Force }
    else { $Doc.PSObject.Properties.Remove('putBackJob') }
}
function Close-VmfPutBackJob {
    <#
    .SYNOPSIS
        In the caller's finally: a job whose record is still on the machine did
        not write its end record, so it ended with an answer (a failure it
        said). Its record is marked ended, and it is never resumed. A job that
        wrote its end record removed its own record in that write, so nothing
        is left to mark. Never throws.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Token, [Parameter()][AllowEmptyString()][string]$Why = '')
    if (-not $Token) { return }
    try {
        $doc = Read-VmfStateDoc -RunPath $Token.RunPath -VmId $Token.VmId
        $job = Get-VmfPutBackJob -Doc $doc
        if (-not $job -or -not [string]::Equals([string]$job.operationId, [string]$Token.Job.operationId, [System.StringComparison]::Ordinal)) { return }
        # FINISH-END-JOB-1: a finish over the record of a restore
        # puts that record back - it is never resumed, and the record it stood
        # over is as it was.
        if ([string]$job.kind -eq 'finish' -and (Get-VmfRecordField -Object $job -Name 'prior')) {
            Remove-VmfFinishJobOnDoc -Doc $doc -Token $Token
            Write-VmfStateDoc -RunPath $Token.RunPath -Document $doc
            return
        }
        $job | Add-Member -NotePropertyName ended -Force -NotePropertyValue ([pscustomobject][ordered]@{
                utc = (Get-Date).ToUniversalTime().ToString('o'); outcome = 'fail'; why = $(if ($Why) { $Why } else { $null }) })
        Write-VmfStateDoc -RunPath $Token.RunPath -Document $doc
    }
    catch { Write-Warning "The record of the job on '$(($Token.VmId -split '/')[-1])' was not marked as ended: $($_.Exception.Message)" }
}

function ConvertTo-VmfJobHashtable {
    <#
    .SYNOPSIS
        A field read back from the record as the hashtable the steps take:
        @{ Swaps; Kept } and the like keep their keys; a LUN map gets integer
        keys. Pure. $null stays $null.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Value, [Parameter()][switch]$IntKeys)
    if ($null -eq $Value) { return $null }
    $out = @{}
    $props = if ($Value -is [System.Collections.IDictionary]) { @($Value.Keys | ForEach-Object { [pscustomobject]@{ Name = $_; Value = $Value[$_] } }) } else { @($Value.PSObject.Properties) }
    foreach ($p in $props) {
        $key = if ($IntKeys) { [int]$p.Name } else { [string]$p.Name }
        $out[$key] = $p.Value
    }
    $out
}

function Update-VmfPutBackJobRecord {
    <#
    .SYNOPSIS
        The service's own change to a job's record - count a start again
        (resume), or remove the record (remove) - in ONE version-checked write
        (Write-VmfStoreTextIfVersion, PLANVER-2). $true when this call wrote
        it; $false when the record is not this job's, or somebody wrote the
        document since it was read: nothing is changed then, and the next pass
        of the timer asks again.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$OperationId,
        # gaveUp (RESUME-GIVEUP-KEEP-1): keep the record, marked ended with the
        # reason gaveUp, so retention keeps the machine's copies until a
        # restore of it finishes.
        [Parameter(Mandatory)][ValidateSet('resume', 'remove', 'gaveUp')][string]$Action,
        [Parameter()][AllowEmptyString()][string]$Why = ''
    )
    $rel = 'state/' + (Get-VmfVmKey -VmId $VmId) + '.json'
    $text = Read-VmfStoreText -RunPath $RunPath -RelPath $rel
    if ($null -eq $text) { return $false }
    $doc = $text | ConvertFrom-Json -Depth 24
    $job = Get-VmfPutBackJob -Doc $doc
    if (-not $job -or -not [string]::Equals([string]$job.operationId, $OperationId, [System.StringComparison]::Ordinal)) { return $false }
    if ($Action -eq 'resume') {
        $job | Add-Member -NotePropertyName resumes -NotePropertyValue (1 + [int]$job.resumes) -Force
        $job | Add-Member -NotePropertyName resumedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    elseif ([string]$job.kind -eq 'finish' -and (Get-VmfRecordField -Object $job -Name 'prior')) {
        # FINISH-END-JOB-1: the record a finish stood over goes back as it was.
        $doc | Add-Member -NotePropertyName putBackJob -NotePropertyValue $job.prior -Force
    }
    elseif ($Action -eq 'gaveUp') {
        $job | Add-Member -NotePropertyName ended -Force -NotePropertyValue ([pscustomobject][ordered]@{
                utc = (Get-Date).ToUniversalTime().ToString('o'); outcome = 'fail'; reason = 'gaveUp'; why = $(if ($Why) { $Why } else { $null }) })
    }
    else { $doc.PSObject.Properties.Remove('putBackJob') }
    Write-VmfStoreTextIfVersion -RunPath $RunPath -RelPath $rel -Content ($doc | ConvertTo-Json -Depth 24) -ExpectedVersion (Get-VmfDocumentVersion -Text $text)
}

function Test-VmfPutBackEndWritten {
    <#
    .SYNOPSIS
        Did this restore write a line that ends it on the
        Migrations page? Pure: the run's events in, a yes or a no out.
    .DESCRIPTION
        The page's own rule (restoreIndex): after the start line
        with this operation id, a line of the machine on the step restore with
        ok, warn or fail, or the engine's own fail or
        refused line (engine:<kind>) with the same id. Read by the order of the
        log, never by a date. With no start line there is nothing on the page
        to end: $true.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Events = @(),
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][ValidateSet('restore', 'finish')][string]$Kind,
        [Parameter(Mandatory)][string]$OperationId
    )
    # FINISH-END-JOB-1: a finish has its own step, and the page ends it on ok,
    # warn or fail, as a restore (migrations.html restoreIndex).
    $step = if ($Kind -eq 'finish') { 'finish' } else { 'restore' }
    $ends = @('ok', 'warn', 'fail')
    $list = @($Events | Where-Object { $_ })
    $startAt = -1
    for ($i = 0; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        if ([string]$e.step -eq $step -and [string]$e.outcome -eq 'start' -and [string]$e.vmId -ieq $VmId -and
            [string]::Equals([string](Get-VmfRecordField -Object $e -Name 'correlationId'), $OperationId, [System.StringComparison]::Ordinal)) { $startAt = $i }
    }
    if ($startAt -lt 0) { return $true }
    for ($i = $startAt + 1; $i -lt $list.Count; $i++) {
        $e = $list[$i]
        if ([string]$e.vmId -ine $VmId) { continue }
        if ([string]$e.step -eq $step -and [string]$e.outcome -in $ends) { return $true }
        if ([string]$e.step -eq "engine:$Kind" -and [string]$e.outcome -in @('fail', 'refused') -and
            [string]::Equals([string](Get-VmfRecordField -Object $e -Name 'correlationId'), $OperationId, [System.StringComparison]::Ordinal)) { return $true }
    }
    $false
}