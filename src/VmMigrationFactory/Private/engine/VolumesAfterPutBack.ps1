# VOLUMES-ONLINE-1 (final lab, 2026-11-13): the check inside the machine after
# a rollback and after Restore this machine.
#
# What the lab found: after the rollback onto disks made from the safety copies,
# an Oracle Linux 9.7 machine kept /var/crash offline - LVM's devices file named
# the disks by their old device IDs - and the engine wrote "The machine is back
# as it was", having run no check inside the machine. The full-rollback rule
# (every disk back 100%, or say so) needs the guest's own word.
#
# So every put-back that makes disks from the safety copies ends with:
#   1. on Linux, lvm-devices-refresh.sh - the documented refresh of the devices
#      file (lvmdevices --update --refresh), vgchange -aay and the fstab mounts;
#      nothing where the file is not in use;
#   2. the guest validation script, as a reading;
#   3. the comparison with the reading before the move (captured.guestBefore):
#      the mounted volumes (Test-VmfVolumesBack) and the volume groups and
#      storage pools (Test-VmfStorageTopology).
# Every line it writes is info: the run page ends a rollback or a restore on
# the first warn or fail line of that step, so the stop or the restore's last
# line carries the verdict. It runs while the machine is running - before it returns to the power state
# it was found in - and its result goes on the checkpoint of the put-back
# (rollbackPending.volumes, putBackJob.volumes; vm-state v49), so a resume
# after the return uses the result and never asks a stopped machine.

function Get-VmfGuestOsFromRecord {
    <#
    .SYNOPSIS
        'Windows' or 'Linux', from the guest scripts a machine's record shows
        the product ran - or $null. Pure.
    .DESCRIPTION
        Restore this machine has no plan entry in hand. A machine with a safety
        copy passed Checking, which runs a guest script on every machine (the
        cluster check), and every guest script is named for its operating
        system: .sh on Linux, .ps1 on Windows.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $names = @(@(Get-VmfRecordField -Object $Doc -Name 'guestExecutions') | Where-Object { $_ } | ForEach-Object { [string](Get-VmfRecordField -Object $_ -Name 'script') })
    $before = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'guestBefore'
    if ($before) { $names += [string](Get-VmfRecordField -Object $before -Name 'script') }
    $linux = @($names | Where-Object { $_ -like '*.sh' }).Count
    $windows = @($names | Where-Object { $_ -like '*.ps1' }).Count
    if ($linux -and -not $windows) { return 'Linux' }
    if ($windows -and -not $linux) { return 'Windows' }
    $null
}

function Get-VmfVolumesCheckWords {
    <#
    .SYNOPSIS
        The sentence an operator reads for a volume check after a put-back.
        Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][ValidateSet('MATCH', 'MISSING', 'UNKNOWN')][string]$Verdict,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore', 'retry', 'check')][string]$Kind,
        [Parameter()][string[]]$Volumes = @(),
        [Parameter()][string]$Why
    )
    $list = if (@($Volumes).Count) { @($Volumes) -join ', ' } else { 'none' }
    switch ($Verdict) {
        'MATCH' { "Every volume that was mounted before the move is mounted again: $list." }
        'MISSING' { "These volumes were mounted before the move and are not mounted now: $list." }
        # VOLUMES-RETRY-CHECK-1: at the check before a retry, the stop's own
        # what-to-do says to mount the volume and try again.
        # VOLUMES-RESTORE-MIGRATED-1: and so does the result of Check the volumes.
        default {
            if ($Kind -in @('retry', 'check')) { "The product could not check the volumes inside the machine ($(([string]$Why).TrimEnd('.')))." }
            else { "The product could not check the volumes inside the machine after the $Kind ($(([string]$Why).TrimEnd('.'))). Make sure that every volume is mounted before you use the machine." }
        }
    }
}

function Invoke-VmfVolumesCheckAfterPutBack {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-1: refresh (Linux), read and compare the volumes of a
        machine a put-back has just started. Never throws, except for a lost
        lease.
    .OUTPUTS
        @{ verdict = 'MATCH'|'MISSING'|'UNKNOWN'; words; detail; tsUtc } - the
        shape the checkpoint keeps (vm-state v49).
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Os,
        # VOLUMES-RETRY-CHECK-1: 'retry' is the check before a person's retry,
        # at Checking - its lines go on that step.
        # VOLUMES-RESTORE-MIGRATED-1: 'check' is Check the volumes, on its own
        # step (volumesCheck).
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore', 'retry', 'check')][string]$Kind,
        # VOLUMES-ONLINE-FINISH-1: Finish the rollback and Finish the restore
        # write the lines on their own step ('finish'): the rollback or the
        # restore they finish has ended.
        [Parameter()][string]$Step,
        # VOLUMES-RETRY-CHECK-OFF-1: the check cannot run, for this reason (the
        # start for the check was refused). The result says so, with no call.
        [Parameter()][string]$NotRunWhy
    )
    $step = if ($Step) { $Step } elseif ($Kind -eq 'retry') { 'PRECHECK' } elseif ($Kind -eq 'check') { 'volumesCheck' } else { $Kind }
    $result = { param($verdict, $words, $detail) [ordered]@{ verdict = $verdict; words = $words; detail = $detail; tsUtc = (Get-Date).ToUniversalTime().ToString('o') } }
    $unknown = { param($why)
        $w = Get-VmfVolumesCheckWords -Verdict 'UNKNOWN' -Kind $Kind -Why $why
        Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId -Detail $w
        & $result 'UNKNOWN' $w ([string]$why) }

    if ($NotRunWhy) { return (& $unknown $NotRunWhy) }
    if ($Os -notin @('Windows', 'Linux')) { return (& $unknown 'the record does not say if this machine runs Windows or Linux') }
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $before = Get-VmfRecordField -Object (Get-VmfRecordField -Object $doc -Name 'captured') -Name 'guestBefore'
    try {
        $power = Invoke-VmfAzOperation -Name "$($Kind):volumesPower" -RunPath $RunPath -VmId $VmId -Operation {
            Get-VmfPowerState -ResourceGroupName $ResourceGroupName -Name $VmName
        }
        if ([string]$power -ne 'PowerState/running') {
            return (& $unknown "the machine is in the power state $(Get-VmfPowerStateName -Power ([string]$power)), not running")
        }
        Invoke-VmfAzOperation -Name "$($Kind):volumesAgent" -RunPath $RunPath -VmId $VmId -Operation {
            Wait-VmfVmAgentReady -ResourceGroupName $ResourceGroupName -Name $VmName
        } | Out-Null
        if ($Os -eq 'Linux') {
            $refresh = Invoke-VmfGuestScriptOnVm -ScriptName 'lvm-devices-refresh.sh' -ResourceGroupName $ResourceGroupName -VmName $VmName -VmId $VmId -RunPath $RunPath
            $said = @(@($refresh.checks) | Where-Object { $_ -and [string]$_.status -in @('FIXED', 'FAIL') } | ForEach-Object { "$($_.name): $($_.detail)" })
            if ($said.Count) {
                Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId `
                    -Detail "The product checked the LVM devices file inside the machine. $($said -join '; ')."
            }
        }
        $script = if ($Os -eq 'Windows') { 'Test-GuestValidation.ps1' } else { 'guest-validate.sh' }
        $after = Invoke-VmfGuestScriptOnVm -ScriptName $script -ResourceGroupName $ResourceGroupName -VmName $VmName -VmId $VmId -RunPath $RunPath -AsReading
        # VOLUMES-ONLINE-WINDOWS-1: the Windows twin of the refresh above - a
        # data disk that was online before the move and is offline now is
        # brought online, then the machine is read again.
        $online = $null
        if ($Os -eq 'Windows') {
            $online = Invoke-VmfWindowsDisksOnline -RunPath $RunPath -VmId $VmId -ResourceGroupName $ResourceGroupName -VmName $VmName -Before $before -After $after -Step $step
            if ($online.Changed) {
                $after = Invoke-VmfGuestScriptOnVm -ScriptName $script -ResourceGroupName $ResourceGroupName -VmName $VmName -VmId $VmId -RunPath $RunPath -AsReading
            }
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return (& $unknown $_.Exception.Message)
    }
    $volumes = Test-VmfVolumesBack -Before $before -After $after -CaseSensitive:($Os -eq 'Linux')
    $topology = Test-VmfStorageTopology -Before $before -After $after
    # VOLUMES-ONLINE-WINDOWS-1: each disk brought online is in the detail the
    # checkpoint keeps, as well as in the activity.
    if ($online -and [string]$online.Words) { $volumes.Detail = "$([string]$online.Words) $($volumes.Detail)" }
    if (-not $volumes.Ok -or -not $topology.Ok) {
        $lost = @($volumes.Missing)
        $words = if ($lost.Count) { Get-VmfVolumesCheckWords -Verdict 'MISSING' -Kind $Kind -Volumes $lost } else { '' }
        if (-not $topology.Ok) { $words = (@($words, "A volume group or storage pool is not as it was before the move: $($topology.Detail).") | Where-Object { $_ }) -join ' ' }
        Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId -Detail $words
        return (& $result 'MISSING' $words "$($volumes.Detail); $($topology.Detail)")
    }
    if ($volumes.Verdict -eq 'UNKNOWN') { return (& $unknown $volumes.Detail) }
    # Each volume, never the list as one text: Get-VmfMountedVolumes returns
    # its list as one item (so an empty list stays a list), and @() of it
    # gave "mounted again: / /boot /var/crash." (VOLUMES-RETRY-CHECK-1).
    $words = Get-VmfVolumesCheckWords -Verdict 'MATCH' -Kind $Kind -Volumes @(Get-VmfMountedVolumes -GuestOutput $before | ForEach-Object { $_ } | Where-Object { $_ })
    Write-VmfStepLine -RunPath $RunPath -Step $step -Outcome info -VmId $VmId -Detail $words
    & $result 'MATCH' $words "$($volumes.Detail); $($topology.Detail)"
}

function Get-VmfRollbackVolumesCheck {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-1: the volume check of this rollback - from its
        checkpoint when a worker before this one took it, else taken now and
        put on the checkpoint (rollbackPending.volumes) before anything else.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $pending = Get-VmfRecordField -Object $doc -Name 'rollbackPending'
    $kept = Get-VmfRecordField -Object $pending -Name 'volumes'
    if ($kept -and [string](Get-VmfRecordField -Object $kept -Name 'verdict')) { return $kept }
    $check = Invoke-VmfVolumesCheckAfterPutBack -RunPath $Context.RunPath -VmId $Context.VmId -ResourceGroupName $Context.Rg -VmName $Context.VmName `
        -Os ([string]$Context.Plan.assessment.os) -Kind 'rollback'
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if ($doc -and $doc.PSObject.Properties['rollbackPending'] -and $doc.rollbackPending) {
        $doc.rollbackPending | Add-Member -NotePropertyName volumes -NotePropertyValue ([pscustomobject]$check) -Force
        Write-VmfStateDoc -RunPath $Context.RunPath -Document $doc
    }
    [pscustomobject]$check
}

# VOLUMES-RETRY-CHECK-1 (2026-11-14): after a volumesNotBack stop
# the operator mounts the volume inside the machine, then selects Try this
# machine again. The retry FIRST runs the check above: every volume mounted
# before the move must be mounted again. Then it goes on as any person's retry,
# a complete new run with new safety copies (SAFETY-RETRY-1). If not, it stops
# again with volumesNotBack and changes nothing in Azure. The same first step
# for a put-back whose check could not run (UNKNOWN): the machine is restored
# and a retry is allowed, so its first step is that check.
#
# What owes the check is a record on the state document, volumesCheckOwed
# (vm-state v50), written in the same write as the stop that owes it.
# Resolve-VmfDecision (the service, which cannot run a script in a machine)
# re-arms such a machine at Checking WITHOUT the new attempt: the safety
# copies, the reading before the move (captured.guestBefore) and this record
# stay, so a check that fails leaves the machine exactly as it was - Restore
# this machine still finds its copy, and the next retry still has the reading
# to compare with. The engine takes the new attempt (Clear-VmfRetryState
# -NewAttempt, which removes the record in the same write) only after the
# check passes.

function Get-VmfVolumesCheckOwed {
    <#
    .SYNOPSIS
        VOLUMES-RETRY-CHECK-1: the record that a retry of this machine must
        check its volumes first, or $null. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $owed = Get-VmfRecordField -Object $Doc -Name 'volumesCheckOwed'
    if ($owed -and [string](Get-VmfRecordField -Object $owed -Name 'reason')) { return $owed }
    $null
}

function Set-VmfVolumesCheckOwed {
    <#
    .SYNOPSIS
        VOLUMES-RETRY-CHECK-1: write on the document what a volume check after
        a put-back owes the next retry. Changes the document only; the caller
        writes it, in the same write as the stop. Pure.
    .DESCRIPTION
        MISSING owes the check (reason volumesNotBack), UNKNOWN owes it too
        (reason notChecked) - unknown is never a pass. MATCH removes a record
        from before. No verdict (no check ran) leaves the record as it is.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Doc,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Verdict,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind
    )
    switch ($Verdict) {
        'MATCH' { if ($Doc.PSObject.Properties['volumesCheckOwed']) { $Doc.PSObject.Properties.Remove('volumesCheckOwed') } }
        { $_ -in @('MISSING', 'UNKNOWN') } {
            $reason = if ($Verdict -eq 'MISSING') { 'volumesNotBack' } else { 'notChecked' }
            $Doc | Add-Member -NotePropertyName volumesCheckOwed -Force -NotePropertyValue ([pscustomobject][ordered]@{
                    reason = $reason; kind = $Kind; tsUtc = (Get-Date).ToUniversalTime().ToString('o') })
        }
        default { }
    }
}

# VOLUMES-RETRY-CHECK-OFF-1 (2026-11-15): the check runs a script inside the
# machine, so the machine must run. A machine that is Stopped or Stopped
# (deallocated) when a person selects Try this machine again, or Check the
# volumes, is started for the check the way Checking starts one for the cluster
# check (CLUSTER-NOT-RUNNING-1), and returned to the power state it had,
# whatever the check finds:
#   1. the power state found is written down BEFORE the start
#      (captured.volumesCheckPower, status 'started');
#   2. the machine starts, and the check runs (Invoke-VmfVolumesCheckAfterPutBack);
#   3. the machine returns to that power state with the product's tries
#      (Restore-VmfClusterCheckPower -RecordName volumesCheckPower, status
#      'putBack').
# A kill after the start: the next run reads the record, does not start the
# machine again, and returns it to the power state on record - not to the
# power state Azure shows then. Any other power state (Starting, Stopping) is
# not started: the check does not run and says the power state.

function Invoke-VmfVolumesCheckStarted {
    <#
    .SYNOPSIS
        VOLUMES-RETRY-CHECK-OFF-1: the volume check of a person's retry, or of
        Check the volumes, on a machine that can be turned off. Never throws,
        except for a lost lease.
    .OUTPUTS
        @{ Check = the result of Invoke-VmfVolumesCheckAfterPutBack;
           PutBack = $null (the machine was running), or the answer of
           Restore-VmfClusterCheckPower (Ok, Words, PowerNotPutBack) }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Os,
        [Parameter(Mandatory)][ValidateSet('retry', 'check')][string]$Kind,
        [Parameter(Mandatory)][string]$Step,
        [Parameter()][string]$NextStep = 'Try this machine again to return the machine to the power state {power} first.'
    )
    $checkArgs = @{ RunPath = $Context.RunPath; VmId = $Context.VmId; ResourceGroupName = $Context.Rg; VmName = $Context.VmName; Os = $Os; Kind = $Kind; Step = $Step }
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $record = Get-VmfRecordField -Object (Get-VmfRecordField -Object $doc -Name 'captured') -Name 'volumesCheckPower'
    # A start of this check still in force wins over what Azure says now:
    # after a kill the machine runs because this check started it.
    $started = if ($record -and [string](Get-VmfRecordField -Object $record -Name 'status') -eq 'started') { [string](Get-VmfRecordField -Object $record -Name 'power') } else { '' }
    try {
        $now = [string](Invoke-VmfAzOperation -Name "$($Kind):volumesPowerFound" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName })
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return @{ Check = (Invoke-VmfVolumesCheckAfterPutBack @checkArgs -NotRunWhy $_.Exception.Message); PutBack = $null }
    }
    $original = if ($started -in @('PowerState/deallocated', 'PowerState/stopped')) { $started } else { $now }
    # Running with no start on record, or a power state the product cannot
    # return a machine to: the check as it is - it reads the power state
    # again, and says one that is not running.
    if ($original -notin @('PowerState/deallocated', 'PowerState/stopped')) {
        return @{ Check = (Invoke-VmfVolumesCheckAfterPutBack @checkArgs); PutBack = $null }
    }
    $check = $null
    # A machine that is running now runs because this check started it.
    # One that is not (a person turned it off since) is started again.
    if ($now -ne 'PowerState/running') {
        try {
            # Written BEFORE the start, so a kill after it knows what to return to.
            if (-not $started) {
                Save-VmfCapturedFacts -Context $Context -Facts @{ volumesCheckPower = [ordered]@{ power = $original; status = 'started'; tsUtc = (Get-Date).ToUniversalTime().ToString('o') } }
            }
            Write-VmfStepLine -RunPath $Context.RunPath -Step $Step -Outcome info -VmId $Context.VmId `
                -Detail "Azure shows the machine as $(Get-VmfPowerStateName -Power $now). The product starts the machine for the check of the volumes. Then it returns the machine to the power state $(Get-VmfPowerStateName -Power $original)."
            Invoke-VmfAzOperation -Name "$($Kind):volumesStart" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
            } | Out-Null
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $check = Invoke-VmfVolumesCheckAfterPutBack @checkArgs -NotRunWhy $_.Exception.Message
        }
    }
    if (-not $check) { $check = Invoke-VmfVolumesCheckAfterPutBack @checkArgs }
    # Whatever the check found: a start that failed part way can leave the
    # machine running, and the return to a power state the machine has does
    # nothing.
    $putBack = Restore-VmfClusterCheckPower -Context $Context -Power $original -RecordName 'volumesCheckPower' -Step $Step -NextStep $NextStep
    @{ Check = $check; PutBack = $putBack }
}

function Invoke-VmfVolumesCheckBeforeRetry {
    <#
    .SYNOPSIS
        VOLUMES-RETRY-CHECK-1: the first step of Checking for a machine whose
        record owes a volume check. $null: nothing owed, or every volume is
        mounted again and the new attempt is taken - Checking goes on. A
        hashtable: the stop, with no disk, size or setting changed.
    .DESCRIPTION
        A kill before the new attempt leaves the record, so the resume checks
        again (the check reads and refreshes only). A kill after it finds no
        record and goes on: Clear-VmfRetryState removes the record in the
        write that moves the copies to safety.earlierCopies, so they move once.
        VOLUMES-RETRY-CHECK-OFF-1: a machine that is turned off is started for
        the check and returned to its power state first
        (Invoke-VmfVolumesCheckStarted), so Checking finds it as it was.
        VOLUMES-NOT-CHECKED-WORDS-1: the stop is volumesNotBack only when the
        check found a volume not mounted; a check that could not run stops
        with volumesNotChecked. A check that passed on a machine Azure refused
        to return to its power state stops with powerNotPutBack, and the check
        stays owed: the next retry returns the machine first.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if (-not $Context.RunPath) { return $null }
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    if (-not (Get-VmfVolumesCheckOwed -Doc $doc)) { return $null }
    $os = [string]$Context.Plan.assessment.os
    if ($os -notin @('Windows', 'Linux')) { $os = Get-VmfGuestOsFromRecord -Doc $doc }
    $run = Invoke-VmfVolumesCheckStarted -Context $Context -Os $os -Kind 'retry' -Step 'PRECHECK'
    $check = $run.Check
    $notBack = $run.PutBack -and -not $run.PutBack.Ok
    if ([string]$check.verdict -eq 'MATCH' -and -not $notBack) {
        Clear-VmfRetryState -RunPath $Context.RunPath -VmId $Context.VmId -From 'PRECHECK' -NewAttempt
        return $null
    }
    $reason = if ([string]$check.verdict -eq 'MATCH') { 'powerNotPutBack' } elseif ([string]$check.verdict -eq 'MISSING') { 'volumesNotBack' } else { 'volumesNotChecked' }
    $powerWords = if ($run.PutBack) { " $([string]$run.PutBack.Words)" } else { '' }
    # The machine stays as the last stop recorded it: changed, and a power
    # state that stop could not put back stays owed (POWER-ONLY-CHANGED-1).
    $stop = @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = $reason; MachineState = 'changed'; PowerAsFound = $true
               Detail = "The product did not try this machine again. $([string]$check.words)$powerWords" }
    $owedPower = if ($notBack) { [string]$run.PutBack.PowerNotPutBack } else { Get-VmfPowerOwed -Doc $doc }
    if ($owedPower) { $stop.PowerNotPutBack = $owedPower }
    $stop
}

# VOLUMES-CHECK-JOB-STOP-1 (1.0, 2026-11-15): a job of Check the volumes
# (checkvolumes) that stops between the start for the check and the return
# leaves a machine that was turned off running, and billing. Nothing else
# starts that job again: a restore and a finish have their checkpoint
# (putBackJob) and the service's resume. So the five-minute pass of the
# service (Invoke-VmfFacadeResumeStalledVolumeChecks) looks for the record of
# the start (captured.volumesCheckPower, status 'started') on a machine that no
# hold and no job has: it marks the record (stoppedUtc, resumes) and starts
# checkvolumes again, which reads the record, does not start the machine
# again, checks, and returns it to the recorded power state. At the limit of
# a restore's resumes it marks the record gaveUp and starts it no more; the
# panel says the machine runs because a check did not finish.

function Get-VmfVolumesCheckStarted {
    <#
    .SYNOPSIS
        VOLUMES-CHECK-JOB-STOP-1: the record of a start for the check of the
        volumes that the return has not ended (captured.volumesCheckPower,
        status 'started'), or $null. Pure.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $record = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'volumesCheckPower'
    if ($record -and [string](Get-VmfRecordField -Object $record -Name 'status') -eq 'started') { return $record }
    $null
}

function Set-VmfVolumesCheckStopped {
    <#
    .SYNOPSIS
        VOLUMES-CHECK-JOB-STOP-1: mark the record of a start for the check
        whose job no longer runs, and count one more start of the check.
    .DESCRIPTION
        The service calls it when no hold and no job of the machine runs.
        stoppedUtc is written once (the panel reads it); resumes counts each
        start the service makes. At the limit the record is marked gaveUp and
        the service starts the check no more.
    .OUTPUTS
        'resume' (start the check again), 'gaveUp' (the limit is reached now;
        say it once), or 'none' (no record in force, or given up before).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][int]$Limit = $script:VmfPutBackResumeLimit
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $record = Get-VmfVolumesCheckStarted -Doc $doc
    if (-not $record -or (Get-VmfRecordField -Object $record -Name 'gaveUp')) { return 'none' }
    if (-not [string](Get-VmfRecordField -Object $record -Name 'stoppedUtc')) {
        $record | Add-Member -NotePropertyName stoppedUtc -NotePropertyValue ((Get-Date).ToUniversalTime().ToString('o')) -Force
    }
    $resumes = [int](Get-VmfRecordField -Object $record -Name 'resumes')
    $answer = if ($resumes -ge $Limit) { 'gaveUp' } else { 'resume' }
    if ($answer -eq 'gaveUp') { $record | Add-Member -NotePropertyName gaveUp -NotePropertyValue $true -Force }
    else { $record | Add-Member -NotePropertyName resumes -NotePropertyValue ($resumes + 1) -Force }
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
    $answer
}

function Get-VmfVolumesCheckNextStep {
    <#
    .SYNOPSIS
        VOLUMES-RESTORE-MIGRATED-1: what a person does after a volume was found
        not mounted, where Check the volumes is offered. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()
    'Mount each volume inside the machine. Then select Check the volumes.'
}

function Get-VmfVolumesCheckRefusal {
    <#
    .SYNOPSIS
        VOLUMES-RESTORE-MIGRATED-1: why Check the volumes may not run on this
        machine now, or $null. Pure.
    .DESCRIPTION
        The engine asks it before and under the machine's hold, and the
        service asks it before a job starts - one copy of the words.
          - A machine a job works on (a working state of the engine): that
            job runs its own checks.
          - A data disk swap left (swapPending): the machine is stopped with
            disks from two moments, and Finish the rollback or Finish the
            restore comes first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc, [Parameter(Mandatory)][string]$VmName)
    # No record: the engine says so (Invoke-VmfVolumesCheck).
    if (-not $Doc) { return $null }
    $state = [string](Get-VmfRecordField -Object $Doc -Name 'state')
    if ($state -notin @('MIGRATED', 'SKIPPED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION')) {
        return "The product did not check the volumes of $VmName, because the machine is at the step $state."
    }
    $swap = Get-VmfRecordField -Object $Doc -Name 'swapPending'
    if ($swap) {
        $action = Get-VmfFinishActionName -Kind $(if ([string](Get-VmfRecordField -Object $swap -Name 'kind') -eq 'restore') { 'restore' } else { 'rollback' })
        return "The product did not check the volumes of $VmName, because a data disk swap is not complete. Select $action first."
    }
    $null
}

# VOLUMES-ONLINE-WINDOWS-1: on Linux the known cause of a volume that is not
# mounted after a start on new disks is the LVM devices file, and the check
# above refreshes it first. On Windows a data disk can start offline: the SAN
# policy (Get-StorageSetting) keeps a disk Windows reads as new offline, and a
# disk can come up read-only. Not measured yet - the lab plan of VOLUMES-ONLINE-2
# reads it - so the product does only what Windows documents for it
# (Set-Disk -IsOffline $false, Set-Disk -IsReadOnly $false), and only to put a
# disk back as it was before the move: a disk the reading before the move
# (captured.guestBefore, the 'data disks' fact of Test-GuestValidation.ps1)
# shows online, and read-only off only on a disk that was writable then. A
# disk the customer kept offline or read-only stays so. A disk is known by its
# partition table's own ID (the GPT disk GUID, or the MBR signature), which a
# disk made from a snapshot keeps, and the move to NVMe does not change.

function Invoke-VmfWindowsDisksOnline {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-WINDOWS-1: bring online the data disks that were online
        before the move and are offline now (and turn off read-only where the
        move turned it on). Never throws, except for a lost lease.
    .OUTPUTS
        @{ Changed = a disk was changed, so read the machine again; Words =
        the sentences the activity says, or '' }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter()][AllowNull()]$Before,
        [Parameter()][AllowNull()]$After,
        [Parameter(Mandatory)][string]$Step
    )
    $todo = Get-VmfDisksToBringOnline -Before $Before -After $After
    if (-not @($todo.Online).Count -and -not @($todo.Writable).Count) { return @{ Changed = $false; Words = '' } }
    # Only a list that has a key is sent: how Run Command renders an empty
    # parameter is not measured, and the script takes @() for one not given.
    $runParams = @{}
    $onlineKeys = @($todo.Online | ForEach-Object { $_.Key }) -join ','
    $writableKeys = @($todo.Writable | ForEach-Object { $_.Key }) -join ','
    if ($onlineKeys) { $runParams.OnlineKeys = $onlineKeys }
    if ($writableKeys) { $runParams.WritableKeys = $writableKeys }
    try {
        $out = Invoke-VmfGuestScriptOnVm -ScriptName 'Set-DataDisksOnline.ps1' -ResourceGroupName $ResourceGroupName -VmName $VmName -VmId $VmId -RunPath $RunPath `
            -Parameters $runParams
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $w = "The product could not change the status of the data disks to Online ($(([string]$_.Exception.Message).TrimEnd('.')))."
        Write-VmfStepLine -RunPath $RunPath -Step $Step -Outcome info -VmId $VmId -Detail $w
        return @{ Changed = $false; Words = $w }
    }
    $checks = @(@($out.checks) | Where-Object { $_ })
    $on = @($checks | Where-Object { [string]$_.name -eq 'disk online' -and [string]$_.status -eq 'FIXED' } | ForEach-Object { [string]$_.detail })
    $rw = @($checks | Where-Object { [string]$_.name -eq 'disk writable' -and [string]$_.status -eq 'FIXED' } | ForEach-Object { [string]$_.detail })
    $bad = @($checks | Where-Object { [string]$_.status -eq 'FAIL' } | ForEach-Object { ([string]$_.detail).TrimEnd('.') })
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($on.Count) { $parts.Add("The product changed the status of these data disks to Online: $($on -join ', ').") }
    if ($rw.Count) { $parts.Add("The product removed the read-only attribute from these data disks: $($rw -join ', ').") }
    if ($bad.Count) { $parts.Add("Windows refused to change these data disks: $($bad -join '; ').") }
    $words = $parts -join ' '
    if ($words) { Write-VmfStepLine -RunPath $RunPath -Step $Step -Outcome info -VmId $VmId -Detail $words }
    @{ Changed = [bool]($on.Count -or $rw.Count); Words = $words }
}

function Get-VmfFinishVolumesCheck {
    <#
    .SYNOPSIS
        VOLUMES-ONLINE-FINISH-1: the volume check of Finish the rollback or
        Finish the restore - from its checkpoint (putBackJob.volumes) when a
        job before this one took it, else taken now and put on the
        checkpoint before anything else, as Restore this machine does.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$VmName,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter()][AllowNull()]$Token
    )
    $kept = if ($Token) { Get-VmfRecordField -Object $Token.Job -Name 'volumes' } else { $null }
    if ($kept -and [string](Get-VmfRecordField -Object $kept -Name 'verdict')) { return $kept }
    $check = [pscustomobject](Invoke-VmfVolumesCheckAfterPutBack -RunPath $RunPath -VmId $VmId -ResourceGroupName $ResourceGroupName -VmName $VmName `
            -Os (Get-VmfGuestOsFromRecord -Doc (Read-VmfStateDoc -RunPath $RunPath -VmId $VmId)) -Kind $Kind -Step 'finish')
    Save-VmfPutBackJobData -Token $Token -Data @{ volumes = $check }
    $check
}