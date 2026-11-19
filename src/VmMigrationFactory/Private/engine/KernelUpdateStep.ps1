# MANA-LINUX-KERNEL-1: the kernel update inside GUEST_PREP, and its record.
#
# Order, and why: SAFETY_PRISTINE has taken the copy of every disk before
# GUEST_PREP starts, so the update is made on a machine that has a rollback.
# The update script runs, the machine is stopped and started so it boots the
# new kernel, the guest agent is waited for, and mana-check.sh reads the
# machine again. Only then does the normal preparation run - on the kernel the
# machine will move with, so nvme-fix.sh builds the initramfs of THAT kernel.
#
# One change window (2026-09-28): a failure after the update script has
# run puts the machine back from the pristine copy at once - the engine loop
# does it with the rollback every stop before the move uses (PREP-ROLLBACK-1:
# the disks only, with its checkpoint). The record says so before the put-back
# starts, so a worker that dies in the middle of it leaves a machine the next
# worker puts back, not updates again - and the checkpoint makes the next
# worker FINISH that put-back rather than run it again from the start.

function Get-VmfKernelUpdateRecord {
    <#
    .SYNOPSIS
        The captured.kernelUpdate record of this machine, or $null.
    #>
    [CmdletBinding()]
    [OutputType([object])]
    param([Parameter()][AllowNull()]$Doc)
    if ($Doc -and $Doc.PSObject.Properties['captured'] -and $Doc.captured -and
        $Doc.captured.PSObject.Properties['kernelUpdate'] -and $Doc.captured.kernelUpdate) {
        return $Doc.captured.kernelUpdate
    }
    $null
}

function Test-VmfKernelPutBackPending {
    <#
    .SYNOPSIS
        Did this attempt's kernel update fail, with the machine not yet put
        back? Pure. A resume must then put it back, and never update again.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    $record = Get-VmfKernelUpdateRecord -Doc $Doc
    [bool]($record -and [string]$record.result -eq 'failed' -and -not [string]$record.putBackUtc)
}

function ConvertTo-VmfUtcText {
    <#
    .SYNOPSIS
        A time read back from a stored document, as the ISO text it was
        written as. ConvertFrom-Json gives a date; [string] on it uses the
        local culture. Text stays text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
    if ($Value -is [System.DateTimeOffset]) { return $Value.UtcDateTime.ToString('o') }
    [string]$Value
}

function Save-VmfKernelUpdateRecord {
    <#
    .SYNOPSIS
        Write captured.kernelUpdate, in the field order of the contract.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)][System.Collections.IDictionary]$Record)
    $ordered = [ordered]@{}
    foreach ($k in 'result', 'kernelBefore', 'kernelInstalled', 'kernelAfter', 'package', 'packageManager',
        'scriptResult', 'error', 'startedUtc', 'finishedUtc', 'putBackUtc') {
        $ordered[$k] = if ($Record.Contains($k)) { $Record[$k] } else { $null }
        if ($k -like '*Utc') { $ordered[$k] = ConvertTo-VmfUtcText -Value $ordered[$k] }
    }
    Save-VmfCapturedFacts -Context $Context -Facts @{ kernelUpdate = $ordered }
}

function Complete-VmfKernelUpdatePutBack {
    <#
    .SYNOPSIS
        The put-back after a failed kernel update finished: say when, so a
        later visit to GUEST_PREP does not put the machine back again.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunPath, [Parameter(Mandatory)][string]$VmId)
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $record = Get-VmfKernelUpdateRecord -Doc $doc
    if (-not $record) { return }
    $copy = [ordered]@{}
    foreach ($p in $record.PSObject.Properties) { $copy[$p.Name] = $p.Value }
    $copy.putBackUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmfKernelUpdateRecord -Context @{ RunPath = $RunPath; VmId = $VmId } -Record $copy
}

function Complete-VmfKernelUpdateResume {
    <#
    .SYNOPSIS
        A kernel update of this attempt is still 'running' on record, and the
        machine now reads as having the MANA driver: the worker stopped after
        the restart. Finish the record with what the machine reports.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter()][AllowNull()]$Facts)
    $record = Get-VmfKernelUpdateRecord -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
    if (-not $record -or [string]$record.result -ne 'running') { return }
    $copy = [ordered]@{}
    foreach ($p in $record.PSObject.Properties) { $copy[$p.Name] = $p.Value }
    $copy.result = 'updated'
    $copy.kernelAfter = $(if ($Facts -and [string]$Facts.kernelVersion) { [string]$Facts.kernelVersion } else { $null })
    $copy.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmfKernelUpdateRecord -Context $Context -Record $copy
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome ok -VmId $Context.VmId `
        -Detail "The kernel was updated from $($copy.kernelBefore) to $($copy.kernelAfter), and it has a MANA driver."
}

function Invoke-VmfKernelUpdateStep {
    <#
    .SYNOPSIS
        MANA-LINUX-KERNEL-1: update the kernel, restart the machine, read it
        again.
    .DESCRIPTION
        Called by GUEST_PREP only when the driver is missing, the plan says
        updateKernel, and Resolve-VmfKernelUpdate says an update can help.
        Safe to run again: the update script asks the package manager for a
        kernel the machine may already have, and answers FIXED while a newer
        kernel than the running one is installed; a machine that already
        restarted onto it reads present and is never sent here.
    .OUTPUTS
        @{ Result = <a step result to return> } when the move stops, or
        @{ GuestOutput; Facts; Verdict; Presence } - the reading of the machine
        on its new kernel - when the update worked.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        # What mana-check.sh reported before the update.
        [Parameter(Mandatory)]$Facts,
        # Can the target give MANA - the same answer the first reading used.
        [Parameter()][bool]$TargetMayMana = $true
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId

    # The rollback must exist BEFORE anything changes. SAFETY_PRISTINE runs
    # before GUEST_PREP, so this holds; it is checked, not assumed, because an
    # update without a copy could not be put back.
    if (-not ($doc.safety -and [string]$doc.safety.pristineSnapshotId) -or -not (Test-VmfDataCopiesComplete -Doc $doc -Kind 'pristine')) {
        return @{ Result = @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'guestPrepBlocked'; MachineState = 'untouched'
                Detail = 'The kernel was not updated, because this machine has no first safety copy on record. Nothing was changed.' } }
    }

    # A resume keeps the kernel the machine ran before this attempt's update.
    # The start time is carried as the reader gave it: ConvertFrom-Json reads
    # it as a date, and [string] on a date writes it in the local culture's
    # words, which is not the text that was stored (PLANVER-2).
    $earlier = Get-VmfKernelUpdateRecord -Doc $doc
    $resumed = [bool]($earlier -and [string]$earlier.result -eq 'running' -and [string]$earlier.kernelBefore)
    $record = [ordered]@{
        result       = 'running'
        kernelBefore = $(if ($resumed) { [string]$earlier.kernelBefore } else { [string]$Facts.kernelVersion })
        startedUtc   = $(if ($resumed -and $earlier.startedUtc) { ConvertTo-VmfUtcText -Value $earlier.startedUtc } else { (Get-Date).ToUniversalTime().ToString('o') })
    }
    Save-VmfKernelUpdateRecord -Context $Context -Record $record
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome start -VmId $Context.VmId `
        -Detail "The kernel $($record.kernelBefore) has no MANA driver, or is below the minimum version that Microsoft lists. The product updates the kernel with the package manager of the distribution, as chosen for this machine."

    $fail = { param([string]$Why) Set-VmfKernelUpdateFailed -Context $Context -Record $record -Why $Why }

    try {
        $out = Invoke-VmfGuestScriptOnVm -ScriptName 'kernel-update.sh' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        $outcome = Get-VmfKernelUpdateOutcome -GuestOutput $out
        $record.package = $outcome.Package
        $record.packageManager = $outcome.PackageManager
        $record.scriptResult = $outcome.ScriptResult
        $record.kernelInstalled = $outcome.KernelInstalled
        Save-VmfKernelUpdateRecord -Context $Context -Record $record
        if (-not $outcome.Restart -and -not $outcome.Changed) {
            # Review finding 3: nothing on the machine changed - no newer
            # kernel, or the package manager never ran. A put-back would throw
            # away the writes since the first copy for nothing, so the move
            # stops for a person, untouched, as it does without the choice.
            $record.result = 'stopped'
            $record.error = $outcome.Detail
            $record.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
            Save-VmfKernelUpdateRecord -Context $Context -Record $record
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome warn -VmId $Context.VmId `
                -Detail "$($outcome.Detail) Nothing on the machine was changed."
            # RHEL-PINNED-KERNEL-ADVICE-1: no newer kernel in the repositories
            # has its own reason. The advice of driverBelowFloor says to choose
            # Update the kernel, which is the choice that just found nothing
            # (lab 2026-11-08: Red Hat 9.4 on the EUS repositories, held to 9.4).
            if ($outcome.ScriptResult -eq 'NO_CHANGE') {
                return @{ Result = @{ Next = 'NEEDS_DECISION'; Reason = 'kernelNotInRepositories'; MachineState = 'untouched'
                        Detail = "$($outcome.Detail) Nothing on the machine was changed." } }
            }
            # KERNEL-CHOICE-STOP-ADVICE-1: the package manager never ran - no
            # rule for the kernel flavour (Ubuntu -azure-fips, -generic), or no
            # package manager. Its own reason too, for the same cause: the
            # advice of driverBelowFloor offers the choice that was made.
            return @{ Result = @{ Next = 'NEEDS_DECISION'; Reason = 'kernelUpdateNoRule'; MachineState = 'untouched'
                    Detail = "$($outcome.Detail) Nothing on the machine was changed." } }
        }
        if (-not $outcome.Restart) { return (& $fail $outcome.Detail) }
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome info -VmId $Context.VmId `
            -Detail "$($outcome.Detail) The product stops and starts the machine so that it starts on the new kernel."

        # Stopped and started with the calls this move already makes - the
        # same stop and start as the pristine copy - so the update needs no
        # new Azure permission. The machine starts on its own size. The events
        # go under driverCheck, which the run page shows as their own sentence.
        Invoke-VmfAzOperation -Name 'deallocateForKernel' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Stop-VmfVmDeallocated -ResourceGroupName $Context.Rg -Name $Context.VmName
        } | Out-Null
        Invoke-VmfAzOperation -Name 'startAfterKernel' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
        } | Out-Null
        Wait-VmfVmAgentReady -ResourceGroupName $Context.Rg -Name $Context.VmName

        # Read again, with the readers GUEST_PREP used before the update.
        $again = Invoke-VmfGuestScriptOnVm -ScriptName 'mana-check.sh' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        $facts = ConvertTo-VmfGuestFacts -GuestOutput $again
        if (-not $facts.PSObject.Properties['os']) { $facts | Add-Member -NotePropertyName os -NotePropertyValue 'Linux' -Force }
        $verdict = Get-VmfDriverJudgement -Facts $facts -TargetIsBoost $TargetMayMana
        $presence = Get-VmfManaDriverPresence -GuestOutput $again -Os 'Linux' -Facts $facts
        $record.kernelAfter = $(if ([string]$facts.kernelVersion) { [string]$facts.kernelVersion } else { $null })
        $check = Get-VmfKernelUpdateRecheck -Presence $presence -Verdict $verdict -KernelBefore $record.kernelBefore `
            -KernelInstalled ([string]$record.kernelInstalled) -KernelAfter ([string]$record.kernelAfter) `
            -KernelDefault ([string]$outcome.KernelDefault)
        if (-not $check.Ok) { return (& $fail $check.Detail) }
    }
    catch {
        # Lease fencing is not a failure of the update: another worker owns
        # the machine now, and it reads the record and carries on.
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return (& $fail "The kernel update did not finish: $($_.Exception.Message)")
    }

    $record.result = 'updated'
    $record.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmfKernelUpdateRecord -Context $Context -Record $record
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome ok -VmId $Context.VmId -Detail $check.Detail
    @{ GuestOutput = $again; Facts = $facts; Verdict = $verdict; Presence = $presence }
}

function Set-VmfKernelUpdateFailed {
    <#
    .SYNOPSIS
        Record that this attempt's kernel update failed, and ask the engine to
        put the machine back from the pristine copy (one change window).
    .OUTPUTS
        @{ Result = <the PutBack step result> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Record,
        [Parameter(Mandatory)][string]$Why
    )
    $Record.result = 'failed'
    $Record.error = $Why
    $Record.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    Save-VmfKernelUpdateRecord -Context $Context -Record $Record
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome fail -VmId $Context.VmId `
        -Detail "$Why The product rolls the machine back from the first safety copy."
    @{ Result = @{ Next = 'FAILED_ROLLED_BACK'; PutBack = $true; Reason = 'kernelUpdateFailed'; Detail = $Why } }
}

function Resume-VmfKernelUpdateReading {
    <#
    .SYNOPSIS
        Review finding 2: GUEST_PREP's first readings, for a machine whose
        kernel update of this attempt is still 'running' on record.
    .DESCRIPTION
        The worker stopped somewhere after the update script: the machine may
        be stopped, starting, or on a new kernel that does not start. So the
        start, the guest agent and the driver reading are guarded here: any of
        them that fails puts the machine back, as a failure inside the update
        does. Never left on a kernel that does not start.
    .OUTPUTS
        @{ GuestOutput } on success, @{ Result } when the machine goes back.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Record)
    try {
        Invoke-VmfAzOperation -Name 'startAfterKernel' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
        } | Out-Null
        Wait-VmfVmAgentReady -ResourceGroupName $Context.Rg -Name $Context.VmName
        $out = Invoke-VmfGuestScriptOnVm -ScriptName 'mana-check.sh' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        return @{ GuestOutput = $out }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $copy = [ordered]@{}
        foreach ($p in $Record.PSObject.Properties) { $copy[$p.Name] = $p.Value }
        return (Set-VmfKernelUpdateFailed -Context $Context -Record $copy -Why "The machine did not answer after the kernel update: $($_.Exception.Message)")
    }
}
