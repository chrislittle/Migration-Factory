# CLUSTER-DETECT-1, 2026-10-31: the workload checks at Checking (PRECHECK).
#
# The scan finds a cluster node only when Azure has a record of it: a shared
# disk (maxShares above 1) or a SQL virtual machine group. A Windows Server
# failover cluster with no shared disk, an availability group built by hand,
# SQL Server installed from media and a Pacemaker cluster have no record, so
# the machine looked like a machine that is alone. The product then stopped it,
# and a stop of the primary replica causes a failover or an outage that
# nobody agreed to.
#
# The rule (2026-10-26, made wider 2026-10-27): ANY cluster node is blocked,
# not only a SQL Server node - a plain Windows failover cluster that is not
# SQL Server, such as a file server cluster, is blocked too. No elevated or
# risky access is asked for: the check is a read-only guest script, run with
# the Run Command right the product already holds, before any safety copy and
# before any stop. Guests report facts; this file judges them.
#
# PRECHECK-WORKLOAD-1 adds a check here at Checking too (a shared disk made
# after the scan, an older assessment). Both are one mechanism: this function.

# What `systemctl is-active` says of a unit that runs now, or is starting,
# reloading or stopping. Each of those is a unit on a live cluster node.
$script:VmfActiveUnitStates = @('active', 'activating', 'reloading', 'deactivating')

function Get-VmfClusterNodeVerdict {
    <#
    .SYNOPSIS
        Is this machine a cluster node, from the facts its guest reported?
        PURE.
    .DESCRIPTION
        Windows: a node of a Windows Server failover cluster when the ClusSvc
        service is running, or the key HKLM\Cluster is present - whatever runs
        on it: a file server cluster, Storage Spaces Direct, SQL Server.
        Linux: a node of a Pacemaker cluster when the pacemaker or corosync
        service is active.
        The SQL reads (HADR_Enabled, hadr.hadrenabled) never decide. They only
        add the kind of cluster to the words.
        A fact that is missing, or a value this build does not know, is
        UNKNOWN - never "not a node".
    .OUTPUTS
        @{ Verdict = 'node' | 'not-a-node' | 'unknown'; Detail = string }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowEmptyString()][string]$Os,
        [Parameter()][AllowNull()]$GuestOutput
    )
    $unknown = { param($why) @{ Verdict = 'unknown'; Detail = "The product could not check whether this machine is a cluster node: $why" } }
    if (-not $GuestOutput) { return (& $unknown 'the check inside the machine gave no answer.') }
    if ([string]$GuestOutput.result -ne 'READY') {
        $err = if ($GuestOutput.PSObject.Properties['error'] -and $GuestOutput.error) { ": $($GuestOutput.error)" } else { '' }
        return (& $unknown "the check inside the machine answered $($GuestOutput.result)$err.")
    }
    $facts = ConvertTo-VmfGuestFacts -GuestOutput $GuestOutput
    $fact = { param($name) if ($facts.PSObject.Properties[$name]) { [string]$facts.$name } else { '' } }
    $sql = & $fact 'sqlHadr'

    switch ($Os.ToLowerInvariant()) {
        'windows' {
            $svc = & $fact 'clusterService'
            $key = & $fact 'clusterKey'
            if ($svc -notin @('running', 'installed', 'absent') -or $key -notin @('yes', 'no')) {
                return (& $unknown "the check did not report the ClusSvc service and the key HKLM\Cluster (ClusSvc '$svc', HKLM\Cluster '$key').")
            }
            if ($svc -eq 'running' -or $key -eq 'yes') {
                $why = @()
                if ($svc -eq 'running') { $why += 'the ClusSvc service is running' }
                if ($key -eq 'yes') { $why += 'the key HKLM\Cluster is present' }
                $text = "This machine is a node of a Windows Server failover cluster: $($why -join ', and ')."
                if ($sql -eq 'yes') { $text += ' A SQL Server instance on it has HADR_Enabled set, so it can be a replica of an Always On availability group.' }
                return @{ Verdict = 'node'; Detail = $text }
            }
            return @{ Verdict = 'not-a-node'; Detail = "This machine is not a cluster node: the ClusSvc service is $svc, and the key HKLM\Cluster is not present." }
        }
        'linux' {
            $pm = & $fact 'pacemaker'
            $cs = & $fact 'corosync'
            if (-not $pm -or -not $cs) {
                return (& $unknown "the check did not report the pacemaker and corosync services (pacemaker '$pm', corosync '$cs').")
            }
            $pmOn = $pm -in $script:VmfActiveUnitStates
            $csOn = $cs -in $script:VmfActiveUnitStates
            if ($pmOn -or $csOn) {
                $text = "This machine is a node of a Pacemaker cluster: the pacemaker service is $pm, and the corosync service is $cs."
                if ($sql -eq 'yes') { $text += ' SQL Server on it has hadr.hadrenabled set in /var/opt/mssql/mssql.conf, so it can be a replica of an Always On availability group.' }
                return @{ Verdict = 'node'; Detail = $text }
            }
            return @{ Verdict = 'not-a-node'; Detail = "This machine is not a cluster node: the pacemaker service is $pm, and the corosync service is $cs." }
        }
        default { return (& $unknown "the operating system '$Os' has no cluster check.") }
    }
}

# CLUSTER-NOT-RUNNING-1 (2026-10-31: start it, check, put it back). A
# machine that is not running cannot run the check, and before the check the
# engine started such a machine itself in Preparing. So Checking starts it,
# runs the check, and puts back the power state it found when the machine
# must not move. The power state found is written down BEFORE the start
# (captured.clusterCheckPower), so a worker killed after the start, or after
# the check, still knows what to put back: a resume runs the check again,
# which only reads, and puts the machine back.
#   status 'started'  - the start is on record; the check or the put-back is owed
#   status 'goingOn'  - not a cluster node; the move goes on, running
#   status 'putBack'  - the machine went back to the recorded power state
# A person's retry from the first step drops the record (Clear-VmfRetryState).

function Get-VmfClusterCheckPowerRecord {
    <#
    .SYNOPSIS
        CLUSTER-NOT-RUNNING-1: the power state Checking found before it started
        the machine for the cluster check, while that start is still in force
        - or $null.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    if (-not $Doc -or -not $Doc.PSObject.Properties['captured'] -or -not $Doc.captured) { return $null }
    if (-not $Doc.captured.PSObject.Properties['clusterCheckPower']) { return $null }
    $r = $Doc.captured.clusterCheckPower
    if (-not $r -or [string]$r.status -notin @('started', 'goingOn')) { return $null }
    $r
}

# POWER-ONLY-CHANGED-1, 2026-11-06. A put-back that Azure refused was said
# once, and the machine was recorded changed, with its retry held until a
# restore - and a stop at Checking has no safety copy to restore. The machine
# MUST go back to its power state: if it was off, the power-off is tried
# again until it is. So every put-back of a power state is sent through
# the product's Azure retry (Invoke-VmfAzOperation), whatever Azure answers,
# as a refused data disk swap is (SWAP-REFUSED-AFTER-STOP-1): the error is
# marked vmfPowerRefused, and Invoke-VmfAzOperation tries it again. The
# machine has not changed in any other way, so a minute of waiting costs
# nothing. A lost lease is never marked: another worker holds the machine.
# Still refused, the stop names the power state found (powerNotPutBack), and
# a person's retry puts it back first (Invoke-VmfStepPrecheck).
$script:VmfPowerPutBackTries = 3
$script:VmfPowerPutBackDelayMs = 15000

# Azure's power state names as the portal shows them (POWER-ONLY-CHANGED-1).
function Get-VmfPowerStateName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Power)
    switch ($Power) {
        'PowerState/deallocated' { 'Stopped (deallocated)' }
        'PowerState/stopped' { 'Stopped' }
        'PowerState/running' { 'Running' }
        # MANUAL-REVIEW-1: every power state by the name the portal shows.
        'PowerState/starting' { 'Starting' }
        'PowerState/stopping' { 'Stopping' }
        'PowerState/deallocating' { 'Deallocating' }
        default { $Power -replace '^PowerState/', '' }
    }
}

function Invoke-VmfPowerPutBack {
    <#
    .SYNOPSIS
        POWER-ONLY-CHANGED-1: put a machine back to a power state it was
        found in - deallocated, stopped or running - tried again while Azure
        refuses.
    .DESCRIPTION
        Deallocated: Stop-VmfVmDeallocated, which returns at once for a
        machine that is deallocated now. Stopped: Stop-VmfVmPoweredOff - and a
        machine that is deallocated now is started first, because only a
        machine that runs can go to the power state stopped. Running
        (2026-11-06, the other direction): Start-VmfVm, which
        returns at once for a machine that runs now. Each try reads the
        machine again, so a try after a partial one is safe.
        Throws the last refusal; the caller says it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running')][string]$Power,
        [Parameter(Mandatory)][string]$Name
    )
    Invoke-VmfAzOperation -Name $Name -RunPath $Context.RunPath -VmId $Context.VmId `
        -MaxAttempts $script:VmfPowerPutBackTries -BaseDelayMs $script:VmfPowerPutBackDelayMs -Operation {
        try {
            if ($Power -eq 'PowerState/deallocated') {
                Stop-VmfVmDeallocated -ResourceGroupName $Context.Rg -Name $Context.VmName
            }
            elseif ($Power -eq 'PowerState/running') {
                Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
            }
            else {
                if ([string](Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName) -eq 'PowerState/deallocated') {
                    Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
                }
                Stop-VmfVmPoweredOff -ResourceGroupName $Context.Rg -Name $Context.VmName
            }
        }
        catch {
            if ($_.Exception.Message -notmatch 'abandon this VM' -and $null -ne $_.Exception.Data) {
                $_.Exception.Data['vmfPowerRefused'] = $true
            }
            throw
        }
    } | Out-Null
}

function Restore-VmfClusterCheckPower {
    <#
    .SYNOPSIS
        CLUSTER-NOT-RUNNING-1: put a machine that Checking started back to the
        power state it had - deallocated or stopped. Never silent.
    .DESCRIPTION
        POWER-ONLY-CHANGED-1: tried again while Azure refuses
        (Invoke-VmfPowerPutBack). Still refused, PowerNotPutBack names the
        power state found, and the caller records it with the stop.
        VOLUMES-RETRY-CHECK-OFF-1: the check of the volumes before a retry,
        and Check the volumes, start a machine that is turned off the same way,
        with their own record (captured.volumesCheckPower) and step.
    .OUTPUTS
        @{ Ok = bool; Words = string; PowerNotPutBack = string or $null } -
        the words go into the stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context, [Parameter(Mandatory)][string]$Power,
        [Parameter()][ValidateSet('clusterCheckPower', 'volumesCheckPower')][string]$RecordName = 'clusterCheckPower',
        [Parameter()][string]$Step = 'PRECHECK',
        # What a person does when Azure refused the return at every try;
        # {power} is the power state by the name the portal shows.
        [Parameter()][string]$NextStep = 'Try this machine again to return the machine to the power state {power} first.'
    )
    $deallocate = $Power -eq 'PowerState/deallocated'
    $powerOff = $Power -eq 'PowerState/stopped'
    # Get-VmfWorkloadCheckStop starts only these two, so there is always a word.
    if (-not ($deallocate -or $powerOff)) { throw "Restore-VmfClusterCheckPower cannot return the machine to the power state '$Power'." }
    $word = if ($deallocate) { 'deallocated' } else { 'stopped' }
    try {
        Invoke-VmfPowerPutBack -Context $Context -Power $Power -Name $(if ($RecordName -eq 'clusterCheckPower') { 'clusterCheckPutBack' } else { 'volumesCheckPutBack' })
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $words = "The product started the machine to run the check, and could not make it $word again ($($_.Exception.Message)), after $script:VmfPowerPutBackTries tries. The machine is running now. $($NextStep.Replace('{power}', (Get-VmfPowerStateName -Power $Power)))"
        Write-VmfStepLine -RunPath $Context.RunPath -Step $Step -Outcome warn -VmId $Context.VmId -Detail $words
        return @{ Ok = $false; Words = $words; PowerNotPutBack = $Power }
    }
    Save-VmfCapturedFacts -Context $Context -Facts @{ $RecordName = [ordered]@{ power = $Power; status = 'putBack'; tsUtc = (Get-Date).ToUniversalTime().ToString('o') } }
    $words = "The product started the machine to run the check, then made it $word again."
    @{ Ok = $true; Words = $words }
}

# STOP-POWER-AS-FOUND-1, 2026-11-05 (lab, the DISK-TYPE-DEALLOCATED-1 run): a
# machine deallocated when its move started ran, billed, after a stop that
# changed nothing - every such stop STARTED the machine, whatever power state
# the record held. One rule now, for every stop after Checking started the
# machine and before the first change: put back the power state the record
# holds, the way Restore-VmfClusterCheckPower does. Running, or no record:
# the caller starts the machine, as before. The record is not changed here:
# it stays until a person's retry drops it, so a worker killed after the
# put-back, or before the stop is on record, puts the machine back again on
# the resume (rule 4). The end of a move and of a rollback: POWER-AFTER-MOVE-1, below.
# Every caller:
#   New-VmfRollbackDisksBeforeMove            rollbackDisksBeforeMoveNotMade
#   Wait-VmfInstantAccessCopies    safetyCopyNotReady
#   Test-VmfCopyWindowBeforeConversion, nothing changed: safetyCopyWindowShort
#   Resolve-VmfStoppedMachineState -AsFound: a step that failed at every
#                                  attempt with the machine stopped, and the
#                                  step limit
#   Invoke-VmfStateMachine         a stop of a step that leaves the power as it
#                                  is (Checking, Preparing), a step that failed
#                                  at every attempt with nothing changed, and a
#                                  deallocation that failed (deallocationFailed)

function Get-VmfPowerAsFound {
    <#
    .SYNOPSIS
        STOP-POWER-AS-FOUND-1: the power state to put back after a stop that
        changed nothing - 'PowerState/deallocated', 'PowerState/stopped', or
        $null (running, or no record: start the machine). PURE.
    .DESCRIPTION
        Reads the record of the cluster check (Get-VmfClusterCheckPowerRecord):
        a start for the check still in force. A record the cluster check put
        back itself (status putBack) gives $null - the machine has that power
        state now.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $record = Get-VmfClusterCheckPowerRecord -Doc $Doc
    if (-not $record) {
        # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: an attempt that starts the
        # machine on the new size has no start for the cluster check. Its
        # record says the power state to return to (Get-VmfStartOnTargetPower).
        $onTarget = Get-VmfStartOnTargetPower -Doc $Doc
        if ($onTarget -in @('PowerState/deallocated', 'PowerState/stopped')) { return $onTarget }
        return $null
    }
    $found = [string]$record.power
    if ($found -in @('PowerState/deallocated', 'PowerState/stopped')) { return $found }
    $null
}

function Restore-VmfPowerAsFound {
    <#
    .SYNOPSIS
        STOP-POWER-AS-FOUND-1: put a machine that a stop leaves untouched back
        to the power state Checking found - or $null when there is nothing to
        put back (running, or no record). Never silent.
    .DESCRIPTION
        Deallocated: Stop-VmfVmDeallocated, which returns at once for a
        machine that is deallocated now. Stopped: Stop-VmfVmPoweredOff - and a
        machine that the move deallocated is started first, because only a
        machine that runs can go to the power state stopped
        (Invoke-VmfPowerPutBack, which tries again while Azure refuses -
        POWER-ONLY-CHANGED-1).
        A put-back still refused is said, and the caller records the machine
        changed with PowerNotPutBack, the power state found. A lost lease is
        another worker's machine now: it goes up.
    .OUTPUTS
        $null, or @{ Ok = bool; Words = <a sentence>; Detail = <the same
        sentence, as a part of a longer one>; PowerNotPutBack = <the power
        state found, when Ok is false> }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        # POWER-ONLY-CHANGED-1: the power state to put back, when it is not
        # the record of the cluster check - a person's retry of a machine
        # whose stop did not put it back (Get-VmfPowerOwed).
        # POWER-ONLY-CHANGED-1 (2026-11-06): or running, for a machine
        # the move stopped that Azure did not start again.
        [Parameter()][ValidateSet('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running')][string]$Power,
        # The name of the Azure call in the run's log; the page has words for
        # some (putBack:ensureRunning).
        [Parameter()][string]$OpName = 'powerAsFound',
        # POWER-AFTER-MOVE-1: what the power state was found before - the
        # move, or a job a person started (the restore).
        [Parameter()][string]$Before = 'the move'
    )
    $found = if ($Power) { $Power } else { Get-VmfPowerAsFound -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId) }
    # ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: a machine that owed the power state
    # running when a start on the new size began is started again too. Its
    # stop before the start must not say untouched while the machine is off.
    if (-not $found -and -not $Power -and (Get-VmfStartOnTargetPower -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)) -eq 'PowerState/running') { $found = 'PowerState/running' }
    if (-not $found) { return $null }
    $word = switch ($found) { 'PowerState/deallocated' { 'deallocated' } 'PowerState/stopped' { 'stopped' } default { 'running' } }
    $verb = switch ($found) { 'PowerState/deallocated' { 'deallocate' } 'PowerState/stopped' { 'stop' } default { 'start' } }
    $done = switch ($found) { 'PowerState/deallocated' { 'deallocated' } 'PowerState/stopped' { 'stopped' } default { 'started' } }
    $sentence = { param([string]$Part) "$($Part.Substring(0, 1).ToUpperInvariant())$($Part.Substring(1))." }
    try {
        Invoke-VmfPowerPutBack -Context $Context -Power $found -Name $OpName
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        $detail = "the machine was $word before $Before, and the product could not $verb it again ($($_.Exception.Message)), after $script:VmfPowerPutBackTries tries. Try this machine again to return the machine to the power state $(Get-VmfPowerStateName -Power $found) first"
        $state = [string](Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId).state
        Write-VmfStepLine -RunPath $Context.RunPath -Step $state -Outcome warn -VmId $Context.VmId -Detail (& $sentence $detail)
        return @{ Ok = $false; Detail = $detail; Words = (& $sentence $detail); PowerNotPutBack = $found }
    }
    $detail = "the product $done the machine again, as it was before $Before"
    @{ Ok = $true; Detail = $detail; Words = (& $sentence $detail) }
}

function Get-VmfPowerOwed {
    <#
    .SYNOPSIS
        POWER-ONLY-CHANGED-1: the power state a stop could not put back, while
        nothing has put it back since - 'PowerState/deallocated',
        'PowerState/stopped', or $null. PURE.
    .DESCRIPTION
        The last history entry that says where it left the machine
        (machineState) decides: changed, with powerNotPutBack. The line of a
        put-back that worked says untouched, and so ends it. A value this
        build does not know is not a power state to put back.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $last = @(@(& $f $Doc 'history') | Where-Object { $_ -and [string](& $f $_ 'machineState') }) | Select-Object -Last 1
    if (-not $last -or [string](& $f $last 'machineState') -ne 'changed') { return $null }
    $power = [string](& $f $last 'powerNotPutBack')
    if ($power -in @('PowerState/deallocated', 'PowerState/stopped', 'PowerState/running')) { return $power }
    $null
}

# POWER-AFTER-MOVE-1, 2026-11-06. The machine MUST go back to its power
# state: whether it was on or off, that state is kept when the work is done -
# also at the END of a job, not only at a stop before any change. Each job
# that starts the machine returns it, after the last check that needs it
# running, with the tries of Invoke-VmfPowerPutBack (Restore-VmfPowerAsFound).
# Still refused, the power state is owed (history[].powerNotPutBack), and
# Return to the power state on the machine panel returns it. Which power state:
#   - the move, its automatic rollback and Finish the rollback (which ends
#     that rollback): the power state Checking found (Get-VmfPowerAsFound);
#   - Restore this machine, and Finish the restore that ends it: the power
#     state Azure gave when the restore started (approved 2026-11-06, on
#     POWER-FOUND-AGE-1), read once
#     and kept in the job's checkpoint (putBackJob.powerAtStart) and in the
#     record of a swap it leaves (swapPending.powerAtStart);
#   REBUILD-REMOVE-RECOVER-1: Rebuild this machine, which kept the newest
#   power state on record, is gone.
# A machine found running stays running.
function Get-VmfPowerBackMachineState {
    <#
    .SYNOPSIS
        POWER-AFTER-MOVE-1: the machine state a line of a power return that
        worked records, so it ends what is owed and says no more than is true.
        PURE.
    .DESCRIPTION
        Get-VmfPowerOwed reads the last entry that says where it left the
        machine, so the line of the return must say it again:
          - MIGRATED: changed - the move put it on its new size;
          - rolled back in this attempt, or put back by Restore this machine:
            restored. A rollback can
            end in FAILED_ROLLED_BACK, NEEDS_DECISION (a park on a second visit
            to Preparing) or FAILED_NEEDS_ATTENTION (the step limit), so the
            state alone does not say it: the rollback's record does
            (rollback.rolledBackUtc, after the latest Checking), or a line
            that says restored since that Checking;
          - any other (a stop before any change, a machine left out before
            any change): untouched, as POWER-ONLY-CHANGED-1 wrote it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $state = [string](& $f $Doc 'state')
    if ($state -eq 'MIGRATED') { return 'changed' }
    if ($state -eq 'FAILED_ROLLED_BACK') { return 'restored' }
    # This attempt: the entries after the latest Checking. A retry clears
    # none of the records of a rollback or a restore, so each
    # counts only when it is at or after that Checking.
    $utc = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime() } elseif ($v) { [datetime]::Parse([string]$v, $null, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') } else { $null } }
    $history = @(@(& $f $Doc 'history') | Where-Object { $_ })
    $checks = @($history | Where-Object { [string](& $f $_ 'state') -eq 'PRECHECK' })
    $since = if ($checks.Count) { & $utc (& $f $checks[-1] 'tsUtc') } else { $null }
    foreach ($at in @((& $f (& $f $Doc 'rollback') 'rolledBackUtc'), (& $f (& $f $Doc 'restore') 'restoredUtc'))) {
        $when = & $utc $at
        if ($when -and (-not $since -or $when -ge $since)) { return 'restored' }
    }
    $after = @($history | Where-Object { -not $since -or (& $utc (& $f $_ 'tsUtc')) -ge $since })
    if (@($after | Where-Object { [string](& $f $_ 'machineState') -eq 'restored' }).Count) { return 'restored' }
    'untouched'
}

function Get-VmfJobStartPower {
    <#
    .SYNOPSIS
        POWER-AFTER-MOVE-1: the power state of the machine when a job a
        person started begins, read from Azure before the job changes
        anything - 'PowerState/running', 'PowerState/deallocated',
        'PowerState/stopped', or $null.
    .DESCRIPTION
        $null for any other power state (starting, stopping) and for a read
        Azure does not answer: the job then ends with the machine running, as
        before, and the line says why. A lost lease goes up. Read once: the
        caller keeps the answer in its checkpoint, so a resume never reads a
        machine the job has started.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Step,
        [Parameter(Mandatory)][string]$JobWords
    )
    $rg = ($VmId -split '/')[4]
    # RESTORE-POWER-READ-1: not $name. Inside the -Operation block, $name is
    # Invoke-VmfAzOperation's own -Name, so the read asked Azure for a machine
    # named "restore:powerAtStart" and the job left the machine running.
    $vmName = ($VmId -split '/')[-1]
    try {
        $power = [string](Invoke-VmfAzOperation -Name "${Step}:powerAtStart" -RunPath $RunPath -VmId $VmId -Operation {
                Get-VmfPowerState -ResourceGroupName $rg -Name $vmName
            })
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        # An info line: a warn or fail line of the job's step ends the job on
        # the page (the restore has one end line).
        Write-VmfStepLine -RunPath $RunPath -Step $Step -Outcome info -VmId $VmId `
            -Detail "The product could not read the power state of the machine before $JobWords ($($_.Exception.Message)). The machine runs at the end of $JobWords."
        return $null
    }
    if ($power -in @('PowerState/running', 'PowerState/deallocated', 'PowerState/stopped')) { return $power }
    Write-VmfStepLine -RunPath $RunPath -Step $Step -Outcome info -VmId $VmId `
        -Detail "The machine was in the power state $(Get-VmfPowerStateName -Power $power) before $JobWords. The machine runs at the end of $JobWords."
    $null
}

function Invoke-VmfJobPowerReturn {
    <#
    .SYNOPSIS
        POWER-AFTER-MOVE-1: at the end of Restore this machine or Finish,
        return the machine to the power state it keeps. A refusal is written
        as owed. Never throws, apart from a lost lease.
    .DESCRIPTION
        -Power: the power state the job read when it started (the restore,
        Finish the restore). -AtMove: the power state Checking found (Finish
        the rollback, which ends the automatic rollback). Running, or nothing
        to return: $null.
        The caller says the words of the answer in the line that ends its job.
        With -RecordRefusal, a return Azure refused at every try writes a line
        in the state the machine has (changed, with powerNotPutBack -
        Get-VmfPowerOwed), so the machine panel offers Return to the power
        state; without it, the caller writes that line after its own record.
        Safe to run again: a return to the power state the machine has does
        nothing.
    .OUTPUTS
        $null, or the answer of Restore-VmfPowerAsFound.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Step,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Power = '',
        [Parameter()][switch]$AtMove,
        [Parameter()][string]$Before = 'the move',
        [Parameter()][switch]$RecordRefusal
    )
    $context = [pscustomobject]@{ RunPath = $RunPath; VmId = $VmId; Rg = ($VmId -split '/')[4]; VmName = ($VmId -split '/')[-1] }
    $back = if ($AtMove) { Restore-VmfPowerAsFound -Context $context -OpName "${Step}:powerAsFound" }
            elseif ($Power -in @('PowerState/deallocated', 'PowerState/stopped')) { Restore-VmfPowerAsFound -Context $context -Power $Power -OpName "${Step}:powerAsFound" -Before $Before }
            else { $null }
    if (-not $back) { return $null }
    if (-not $back.Ok -and $RecordRefusal) {
        $state = [string](Read-VmfStateDoc -RunPath $RunPath -VmId $VmId).state
        Add-VmfStateTransition -RunPath $RunPath -VmId $VmId -NewState $state -Outcome fail -MachineState 'changed' `
            -PowerNotPutBack $back.PowerNotPutBack -Detail $back.Words | Out-Null
    }
    $back
}
function Get-VmfPowerOnlyLeft {
    <#
    .SYNOPSIS
        POWER-ONLY-CHANGED-1: for Stop this migration, the power state found
        when the only change a close at this step can leave is the power
        state - or $null. PURE, apart from the audit trail it is given.
    .DESCRIPTION
        A machine closed out part way through its move, before any change but
        its power state, is returned to the power state found (2026-11-06: a
        machine turned on at any phase and then left out or stopped must be
        turned off again). Before the first change:
          - Checking and a preparation that changed nothing
            (Test-VmfGuestChangedThisAttempt) start only a machine Checking
            found deallocated or stopped (Get-VmfPowerAsFound); a machine
            found running was left running, so nothing is owed;
          - the first safety copy, Shutting down and the second safety copy
            stop the machine: the power state found, or running when Checking
            found it running (no record).
        From Moving on the move changes the machine, so it keeps the full
        hold, and so does a machine whose guest the preparation changed.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$State, [Parameter()][AllowNull()]$Doc)
    if ($State -notin @('PRECHECK', 'GUEST_PREP', 'SAFETY_PRISTINE', 'STOPPED', 'SAFETY_COPY')) { return $null }
    if (Test-VmfGuestChangedThisAttempt -Doc $Doc) { return $null }
    $found = Get-VmfPowerAsFound -Doc $Doc
    if ($found) { return $found }
    if ($State -in @('SAFETY_PRISTINE', 'STOPPED', 'SAFETY_COPY')) { return 'PowerState/running' }
    $null
}

# PRECHECK-WORKLOAD-1, 2026-11-01: DETECT-PATTERNS-1 refuses a storage or
# backup appliance and a machine with a shared disk at the scan (assessment
# version 4). A plan made from an older assessment has neither blocker, and a
# disk can become shared after the scan. So Checking asks Azure again, with
# the scan's own appliance rule and the engine's own shared disk read, as
# soon as it has read the machine - beside the other out-of-scope stops
# (size, family, 32 data disks), before any stop a person can accept, any
# guest script and the start for the cluster check (review, 2026-11-01).

function Get-VmfLiveApplianceVerdict {
    <#
    .SYNOPSIS
        PRECHECK-WORKLOAD-1: is this machine, as Azure has it now, a storage
        or backup appliance? PURE.
    .DESCRIPTION
        The scan's own rule (Test-VmfStorageAppliance), given the image, the
        Marketplace plan and the gallery image of the machine Get-VmfVmConfig
        read - with the same gallery order as the scan: a community gallery
        image, then a shared gallery image, then the image id.
    .OUTPUTS
        The Test-VmfStorageAppliance result.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    $field = { param($o, $n) [string](Get-VmfRecordField -Object $o -Name $n) }
    $image = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Vm -Name 'StorageProfile') -Name 'ImageReference'
    $plan = Get-VmfRecordField -Object $Vm -Name 'Plan'
    $galleryField = 'imageReference.communityGalleryImageId'
    $galleryId = & $field $image 'CommunityGalleryImageId'
    if (-not $galleryId) {
        $galleryField = 'imageReference.sharedGalleryImageId'
        $galleryId = & $field $image 'SharedGalleryImageId'
    }
    if (-not $galleryId) {
        $galleryField = 'imageReference.id'
        $galleryId = & $field $image 'Id'
    }
    Test-VmfStorageAppliance -ImagePublisher (& $field $image 'Publisher') -ImageOffer (& $field $image 'Offer') `
        -PlanPublisher (& $field $plan 'Publisher') -PlanProduct (& $field $plan 'Product') `
        -GalleryImageId $galleryId -GalleryField $galleryField
}

# NVA-PRECHECK-1, 2026-11-02: the scan refuses a network virtual appliance
# (WORKLOAD-1), and since NVA-PLAN-1 it finds one by its Marketplace purchase
# plan too - an appliance made from a gallery copy of its Marketplace image. A
# plan made from an assessment before NVA-PLAN-1 has no blocker on such a
# machine, so Checking asks again here, with the scan's own rule.

function Get-VmfLiveNvaVerdict {
    <#
    .SYNOPSIS
        NVA-PRECHECK-1: is this machine, as Azure has it now, a network
        virtual appliance? PURE.
    .DESCRIPTION
        The scan's own rule (Test-VmfNvaImage), given the image reference and
        the Marketplace purchase plan of the machine Get-VmfVmConfig read: the
        image is judged first, then the plan.
    .OUTPUTS
        The Test-VmfNvaImage result.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    $field = { param($o, $n) [string](Get-VmfRecordField -Object $o -Name $n) }
    $image = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Vm -Name 'StorageProfile') -Name 'ImageReference'
    $plan = Get-VmfRecordField -Object $Vm -Name 'Plan'
    Test-VmfNvaImage -Publisher (& $field $image 'Publisher') -Offer (& $field $image 'Offer') `
        -PlanPublisher (& $field $plan 'Publisher') -PlanProduct (& $field $plan 'Product')
}

# NO-PLAN-SCOPE-1, 2026-11-03: the scan puts a machine with a Marketplace
# purchase plan outside the scope of this tool. A plan made from an assessment
# before that has no blocker on such a machine, so Checking asks again here,
# with the scan's own rule.

function Get-VmfLivePurchasePlanVerdict {
    <#
    .SYNOPSIS
        NO-PLAN-SCOPE-1: the Marketplace purchase plan of this machine as Azure
        has it now, as evidence - or $null for none. PURE.
    .OUTPUTS
        The Get-VmfPurchasePlanEvidence result, or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Vm)
    Get-VmfPurchasePlanEvidence -Plan (Get-VmfRecordField -Object $Vm -Name 'Plan')
}

function Get-VmfSharedDiskStop {
    <#
    .SYNOPSIS
        PRECHECK-WORKLOAD-1: the stop for a machine with a shared data disk,
        or $null.
    .DESCRIPTION
        Reads maxShares of each managed data disk by its id, with the engine's
        own shared disk read (Get-VmfDiskShareCount - the read the put-back
        uses). Above 1, other machines use the same disk: the machine is a
        cluster node on a shared disk, and it stops untouched, outside the
        scope of this tool.
        Only a managed disk can be a shared disk, so a data disk with no
        managed disk id is not read.
        A read that fails is never a pass: the error goes up to the step,
        which is tried again, then the machine stops untouched
        (FAILED_NEEDS_ATTENTION) - the product's rule for a read at Checking.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Vm)
    $shared = [System.Collections.Generic.List[string]]::new()
    $disks = @(Get-VmfRecordField -Object (Get-VmfRecordField -Object $Vm -Name 'StorageProfile') -Name 'DataDisks')
    foreach ($d in $disks) {
        if (-not $d) { continue }
        $diskId = [string](Get-VmfRecordField -Object (Get-VmfRecordField -Object $d -Name 'ManagedDisk') -Name 'Id')
        if (-not $diskId) { continue }
        $shares = Invoke-VmfAzOperation -Name 'readDataDiskShares' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfDiskShareCount -DiskId $diskId
        }
        if ([int]$shares -gt 1) {
            $name = [string](Get-VmfRecordField -Object $d -Name 'Name')
            if (-not $name) { $name = ($diskId -split '/')[-1] }
            $shared.Add("'$name' on LUN $(Get-VmfRecordField -Object $d -Name 'Lun') has maxShares $([int]$shares)")
        }
    }
    if (-not $shared.Count) { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'sharedDisk'; MachineState = 'untouched'
       Detail = "This machine has a shared disk: $($shared -join '; '). Other machines use the same disk, so this machine is a cluster node. A migration stops it as if it were alone. The product does not move a cluster node. Nothing on the machine changed." }
}

function Get-VmfWorkloadScopeStop {
    <#
    .SYNOPSIS
        PRECHECK-WORKLOAD-1: the stop for a network virtual appliance, a
        storage or backup appliance or a machine with a shared disk, or $null.
        Reads Azure only.
    .DESCRIPTION
        The machine as Azure has it now (-Vm, from Get-VmfVmConfig) is judged
        with the scan's network virtual appliance rule
        (networkVirtualAppliance, NVA-PRECHECK-1), then with its storage
        appliance rule (storageAppliance), then its Marketplace purchase plan
        (purchasePlan, NO-PLAN-SCOPE-1), then each data disk's maxShares is
        read (sharedDisk). Each stops untouched, outside the scope of this
        tool, whatever assessment the plan came from. A machine on both
        appliance lists stops once, with the network virtual appliance reason,
        as at the scan.
        It writes nothing, so a worker killed in it leaves no record, and the
        next worker reads Azure again and stops the same way (rule 4).
        PRECHECK calls it right after the machine is read, with the other
        out-of-scope stops: no RunCommand runs in the machine first, and no
        stop that a person can accept comes first.
    .OUTPUTS
        A handler stop (@{ Next; Reason; Detail; MachineState }), or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Vm)
    $nva = Get-VmfLiveNvaVerdict -Vm $Vm
    if ($nva.IsNva) {
        $evidence = @(@($nva.Evidence) | ForEach-Object { "$($_.field) '$($_.value)'" }) -join ', '
        return @{ Next = 'NEEDS_DECISION'; Reason = 'networkVirtualAppliance'; MachineState = 'untouched'
                  Detail = "This machine is a network virtual appliance, found by $evidence. Network traffic goes through it. A migration stops the machine, and the traffic stops with it. The product does not move a network virtual appliance. Nothing on the machine changed." }
    }
    $appliance = Get-VmfLiveApplianceVerdict -Vm $Vm
    if ($appliance.IsAppliance) {
        $evidence = @(@($appliance.Evidence) | ForEach-Object { "$($_.field) '$($_.value)'" }) -join ', '
        return @{ Next = 'NEEDS_DECISION'; Reason = 'storageAppliance'; MachineState = 'untouched'
                  Detail = "This machine is a storage or backup appliance from $($appliance.Vendor), found by $evidence. The vendor certifies the sizes that the appliance supports. The product does not move an appliance. Nothing on the machine changed." }
    }
    $plan = Get-VmfLivePurchasePlanVerdict -Vm $Vm
    if ($plan) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'purchasePlan'; MachineState = 'untouched'
                  Detail = "This machine has a Marketplace purchase plan: $($plan.Words). A machine with a purchase plan is outside the scope of this tool. Nothing on the machine changed." }
    }
    Get-VmfSharedDiskStop -Context $Context -Vm $Vm
}

function Get-VmfClusterCheckWaitWords {
    <#
    .SYNOPSIS
        POWER-WAIT-WORDS-1: the stop words for a machine whose power state the
        cluster check will not start it from - what to wait for, in the
        portal's status words, then what to select.
    .DESCRIPTION
        On 2026-11-08 the stop words for a machine in the power state
        'PowerState/deallocating' told the user to "make it running", which
        made no sense. A
        machine Azure is still turning off is waited for, never started, and a
        person never reads a raw 'PowerState/...' code.
        Deallocating has the approved sentence, word for word. Stopping,
        starting and any other answer follow its shape (proposed, not yet
        approved - see the item file). A stop that powers a machine off ends at
        Stopped, and the product does not know which operation Azure runs, so
        stopping names both end states.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$Power)
    $tail = 'then select Try this machine again. Nothing on the machine changed.'
    switch ($Power) {
        'PowerState/deallocating' { "The machine was being deallocated when the check started, so the product did not start it. Wait until Azure shows the machine as Stopped (deallocated), $tail" }
        'PowerState/stopping' { "The machine was being stopped when the check started, so the product did not start it. Wait until Azure shows the machine as Stopped or Stopped (deallocated), $tail" }
        'PowerState/starting' { "Azure was starting the machine when the check started, so the product did not run the check. Wait until Azure shows the machine as Running, $tail" }
        default { "Azure did not show the machine as Running, Stopped or Stopped (deallocated) when the check started, so the product did not start it. Wait until Azure shows one of these states, $tail" }
    }
}

function Get-VmfWorkloadCheckStop {
    <#
    .SYNOPSIS
        CLUSTER-DETECT-1: the stop for a cluster node at Checking, or $null.
    .DESCRIPTION
        Runs the read-only cluster check inside the machine and judges what it
        reports (Get-VmfClusterNodeVerdict). Nothing in the guest changes, and
        each stop says so.

        A machine that is not running is started for the check
        (CLUSTER-NOT-RUNNING-1), and put back to the power state it had when
        it must not move: a cluster node, or an unknown answer. Not a cluster
        node: the move goes on, and Preparing finds it running.

        Unknown is never "not a cluster node":
          - a check that answers BLOCKED, or leaves out a fact, stops it;
          - on a machine that was running, a Run Command that fails throws,
            which is the product's existing rule for a guest script that fails
            at Checking: the step is tried again, then the machine stops
            untouched (FAILED_NEEDS_ATTENTION);
          - on a machine this check started, a start or a Run Command that
            fails puts the machine back first, then stops it.
        Every clusterNodeNotChecked and clusterNode stop parks the machine the
        same way (NEEDS_DECISION).
    .OUTPUTS
        A handler stop (@{ Next; Reason; Detail; MachineState }), or $null.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Power,
        # VF-UNMANAGED-CONFIG-1: also read, on the same start and put-back,
        # whether the network settings set the SR-IOV interface as unmanaged.
        # PRECHECK sets it for a Linux move with accelerated networking on
        # after it.
        [Parameter()][switch]$SriovCheck
    )
    $os = [string]$Context.Plan.assessment.os
    if ($os -notin @('Windows', 'Linux')) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'clusterNodeNotChecked'; MachineState = 'untouched'
                  Detail = "The plan does not say if this machine runs Windows or Linux ('$os'), so the product cannot check if it is a cluster node. Nothing on the machine changed." }
    }

    # CLUSTER-NOT-RUNNING-1: the power state to put back. A start of this
    # attempt still in force wins over what Azure says now - after a kill the
    # machine reads running because this check started it.
    $record = Get-VmfClusterCheckPowerRecord -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
    $original = if ($record) { [string]$record.power } else { [string]$Power }
    # Only a power state the product can put back is started: deallocated or
    # stopped. Any other (starting, stopping, unknown) stops untouched, so a
    # machine is never started that the product could not return as it was.
    if ($original -notin @('PowerState/running', 'PowerState/deallocated', 'PowerState/stopped')) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'clusterNodeNotChecked'; MachineState = 'untouched'
                  Detail = (Get-VmfClusterCheckWaitWords -Power $original) }
    }
    $startedByCheck = $original -ne 'PowerState/running'

    $stopWith = {
        param([hashtable]$Why)
        $putBack = if ($startedByCheck) { Restore-VmfClusterCheckPower -Context $Context -Power $original } else { @{ Ok = $true; Words = '' } }
        $tail = if ($putBack.Ok) { 'Nothing in the machine changed.' } else { 'Nothing in the machine changed, but its power state did.' }
        # POWER-ONLY-CHANGED-1: a refused put-back names the power state found.
        @{ Next = 'NEEDS_DECISION'; Reason = $Why.Reason
           MachineState = $(if ($putBack.Ok) { 'untouched' } else { 'changed' })
           PowerNotPutBack = $(if ($putBack.Ok) { $null } else { $putBack.PowerNotPutBack })
           Detail = (@($Why.Text, $putBack.Words, $tail) | Where-Object { $_ }) -join ' ' }
    }

    try {
        if ($startedByCheck) {
            # Written BEFORE the start, so a kill after it knows what to put back.
            if (-not $record) {
                Save-VmfCapturedFacts -Context $Context -Facts @{ clusterCheckPower = [ordered]@{ power = $original; status = 'started'; tsUtc = (Get-Date).ToUniversalTime().ToString('o') } }
            }
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId `
                -Detail "Azure shows the machine as $(Get-VmfPowerStateName -Power $original). The product starts it to run the check that finds a cluster node, and stops it again if the machine must not move."
            Invoke-VmfAzOperation -Name 'clusterCheckStart' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Start-VmfVm -ResourceGroupName $Context.Rg -Name $Context.VmName
            } | Out-Null
            Invoke-VmfAzOperation -Name 'clusterCheckAgent' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Wait-VmfVmAgentReady -ResourceGroupName $Context.Rg -Name $Context.VmName
            } | Out-Null
        }
        # Each script by its name, as at every other guest call: RUNCMD-REPLAY-1
        # finds each followed script's call by it.
        $out = if ($os -eq 'Windows') {
            Invoke-VmfGuestScriptOnVm -ScriptName 'Test-ClusterNode.ps1' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        }
        else {
            Invoke-VmfGuestScriptOnVm -ScriptName 'cluster-node-check.sh' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        }
    }
    catch {
        # A lost lease is another worker's machine now: touch nothing.
        if (-not $startedByCheck -or $_.Exception.Message -match 'abandon this VM') { throw }
        return (& $stopWith @{ Reason = 'clusterNodeNotChecked'; Text = "The product could not check whether this machine is a cluster node: $($_.Exception.Message)" })
    }

    # VOLUMES-ONLINE-1: the same script reports whether LVM uses a devices
    # file. Recorded as a fact, whatever the cluster answer: the devices file
    # names each disk by its device ID, which changes on NVMe and on every
    # disk made from a safety copy. It decides nothing here.
    if ($os -eq 'Linux') {
        $lvmFact = Get-VmfLvmDevicesFileFact -GuestOutput $out
        # A fact that cannot be written never stops the move; a lost lease does.
        try { Save-VmfCapturedFacts -Context $Context -Facts @{ lvmDevicesFile = [ordered]@{ state = $lvmFact.State; detail = $lvmFact.Detail } } }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            Write-Warning "The LVM devices file fact of '$($Context.VmName)' was not written: $($_.Exception.Message)"
        }
        if ($lvmFact.State -eq 'inUse') {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId `
                -Detail "LVM on this machine uses the devices file $($lvmFact.Path), which names each disk by its device ID."
        }
    }

    $verdict = Get-VmfClusterNodeVerdict -Os $os -GuestOutput $out
    switch ($verdict.Verdict) {
        'node' {
            return (& $stopWith @{ Reason = 'clusterNode'; Text = "$($verdict.Detail) The product does not move a cluster node." })
        }
        'not-a-node' {
            # VF-UNMANAGED-CONFIG-1: the SR-IOV read runs here, after the
            # cluster check and before the record says the move goes on, so a
            # machine this check started is put back the same way when it
            # must wait for a decision.
            if ($SriovCheck -and $os -eq 'Linux') {
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId -Detail $verdict.Detail
                if (Get-VmfSriovUnmanagedAccepted -PlanEntry $Context.Plan) {
                    Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId `
                        -Detail 'An approver accepted the move of this machine without the unmanaged setting. The product did not check the setting again.'
                }
                else {
                    try {
                        $sriovOut = Invoke-VmfGuestScriptOnVm -ScriptName 'sriov-unmanaged-check.sh' -ResourceGroupName $Context.Rg `
                            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
                    }
                    catch {
                        # The product's rule for a guest script that fails at
                        # Checking on a running machine: the error goes up to
                        # the step. A machine this check started is put back
                        # first. A lost lease touches nothing more.
                        if (-not $startedByCheck -or $_.Exception.Message -match 'abandon this VM') { throw }
                        return (& $stopWith @{ Reason = 'sriovUnmanagedNotChecked'; Text = "The product could not read the unmanaged setting for the drivers of accelerated networking. The check in the machine failed: $($_.Exception.Message)" })
                    }
                    $sriov = Get-VmfSriovUnmanagedVerdict -GuestOutput $sriovOut
                    switch ($sriov.Verdict) {
                        'notSet' { return (& $stopWith @{ Reason = 'sriovNotUnmanaged'; Text = "$($sriov.Detail) If NetworkManager or systemd-networkd configures the virtual function, the network of the machine can stop after the move." }) }
                        'unknown' { return (& $stopWith @{ Reason = 'sriovUnmanagedNotChecked'; Text = $sriov.Detail }) }
                        default { Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId -Detail $sriov.Detail }
                    }
                }
                if ($startedByCheck) {
                    Save-VmfCapturedFacts -Context $Context -Facts @{ clusterCheckPower = [ordered]@{ power = $original; status = 'goingOn'; tsUtc = (Get-Date).ToUniversalTime().ToString('o') } }
                }
                return $null
            }
            if ($startedByCheck) {
                Save-VmfCapturedFacts -Context $Context -Facts @{ clusterCheckPower = [ordered]@{ power = $original; status = 'goingOn'; tsUtc = (Get-Date).ToUniversalTime().ToString('o') } }
            }
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'PRECHECK' -Outcome info -VmId $Context.VmId -Detail $verdict.Detail
            return $null
        }
        default {
            return (& $stopWith @{ Reason = 'clusterNodeNotChecked'; Text = $verdict.Detail })
        }
    }
}

# ROLLBACK-NO-CAPACITY-OTHER-SERIES-1 (2026-11-14): the checks
# that read the guest, for an attempt that starts the machine on the new size
# (StartOnTarget.ps1). They run in Starting, after the start and the wait for
# the agent, and before Verifying. Why this is still safe:
#   - the disks are the original disks: the rollback put back the disks of the
#     first safety copy, and this attempt took new safety copies of them
#     before it changed the size, so a check that stops puts them back again;
#   - each check here ran before the earlier move, on the disks that copy
#     holds, and passed - else that move did not start;
#   - the machine was already stopped, so the start on the new size is the
#     first start since the rollback.
# A check that stops returns RollBack, and the state machine rolls the machine
# back to its original size with its new safety copies (FAIL-1).
function Get-VmfChecksAfterStartStop {
    <#
    .SYNOPSIS
        The stop that sends a machine started on the new size back, or $null.
    .DESCRIPTION
        In order, each as before the move:
          1. Linux: the LVM devices file (lvm-devices-refresh.sh, as after a
             put-back - the rollback made the disks from a copy, and their
             device IDs changed). Said when it changes or fails.
          2. The cluster check (CLUSTER-DETECT-1). A cluster node, or an
             answer that is not known, stops it (NEEDS_DECISION after the
             rollback).
          3. Linux, when the move turns accelerated networking on: the check of
             the network settings for accelerated networking
             (VF-UNMANAGED-CONFIG-1). Not set, or no answer, stops it, unless an
             approver accepted it.
          4. The driver check (DRIVER-1), judged against the target size. FAIL
             stops it. The reading is saved as Preparing saves it.
        A lost lease goes up: another worker holds the machine.
    .OUTPUTS
        $null, or @{ Next; RollBack = $true; Reason; StopState; Detail }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)]$Context, [Parameter()][AllowNull()]$Record)
    $os = [string]$Context.Plan.assessment.os
    $size = [string]$Context.Plan.target.size
    $back = { param([string]$Reason, [string]$Text)
        @{ Next = 'FAILED_ROLLED_BACK'; RollBack = $true; Reason = $Reason; StopState = 'NEEDS_DECISION'
           Detail = "$Text The check ran after the start on $size, so the product rolls the machine back." } }
    if ($os -notin @('Windows', 'Linux')) {
        return (& $back 'clusterNodeNotChecked' "The plan does not say if this machine runs Windows or Linux ('$os'), so the product cannot check if it is a cluster node.")
    }

    if ($os -eq 'Linux') {
        $refresh = Invoke-VmfGuestScriptOnVm -ScriptName 'lvm-devices-refresh.sh' -ResourceGroupName $Context.Rg `
            -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        $said = @(@($refresh.checks) | Where-Object { $_ -and [string]$_.status -in @('FIXED', 'FAIL') } | ForEach-Object { "$($_.name): $($_.detail)" })
        if ($said.Count) {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'STARTING' -Outcome info -VmId $Context.VmId `
                -Detail "The product checked the LVM devices file inside the machine. $($said -join '; ')."
        }
    }

    try {
        $out = if ($os -eq 'Windows') {
            Invoke-VmfGuestScriptOnVm -ScriptName 'Test-ClusterNode.ps1' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        }
        else {
            Invoke-VmfGuestScriptOnVm -ScriptName 'cluster-node-check.sh' -ResourceGroupName $Context.Rg `
                -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return (& $back 'clusterNodeNotChecked' "The product could not check whether this machine is a cluster node: $($_.Exception.Message)")
    }
    $verdict = Get-VmfClusterNodeVerdict -Os $os -GuestOutput $out
    switch ($verdict.Verdict) {
        'node' { return (& $back 'clusterNode' "$($verdict.Detail) The product does not move a cluster node.") }
        'not-a-node' { Write-VmfStepLine -RunPath $Context.RunPath -Step 'STARTING' -Outcome info -VmId $Context.VmId -Detail $verdict.Detail }
        default { return (& $back 'clusterNodeNotChecked' $verdict.Detail) }
    }

    # VF-UNMANAGED-CONFIG-1 with ROLLBACK-NO-CAPACITY-OTHER-SERIES-1: on a
    # Linux move that turns accelerated networking on, the check of the network
    # settings for accelerated networking runs here too, as at Checking: an
    # attempt that starts on the new size skips the read at Checking. The
    # decision is the one Preparing saved for this attempt. Not set, or no
    # answer, rolls the machine back like every check after the start.
    if ($os -eq 'Linux') {
        $anSaved = Get-VmfAcceleratedNetworkingDecision -Doc (Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId)
        if ($anSaved.ExpectFabric) {
            if (Get-VmfSriovUnmanagedAccepted -PlanEntry $Context.Plan) {
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'STARTING' -Outcome info -VmId $Context.VmId `
                    -Detail 'An approver accepted the move of this machine without the unmanaged setting. The product did not check the setting again.'
            }
            else {
                try {
                    $sriovOut = Invoke-VmfGuestScriptOnVm -ScriptName 'sriov-unmanaged-check.sh' -ResourceGroupName $Context.Rg `
                        -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
                }
                catch {
                    if ($_.Exception.Message -match 'abandon this VM') { throw }
                    return (& $back 'sriovUnmanagedNotChecked' "The product could not read the unmanaged setting for the drivers of accelerated networking. The check in the machine failed: $($_.Exception.Message)")
                }
                $sriov = Get-VmfSriovUnmanagedVerdict -GuestOutput $sriovOut
                switch ($sriov.Verdict) {
                    'notSet' { return (& $back 'sriovNotUnmanaged' "$($sriov.Detail) If NetworkManager or systemd-networkd configures the virtual function, the network of the machine can stop after the move.") }
                    'unknown' { return (& $back 'sriovUnmanagedNotChecked' ([string]$sriov.Detail)) }
                    default { Write-VmfStepLine -RunPath $Context.RunPath -Step 'STARTING' -Outcome info -VmId $Context.VmId -Detail $sriov.Detail }
                }
            }
        }
    }

    $driverScript = if ($os -eq 'Windows') { 'Test-ManaReady.ps1' } else { 'mana-check.sh' }
    $driverOut = Invoke-VmfGuestScriptOnVm -ScriptName $driverScript -ResourceGroupName $Context.Rg `
        -VmName $Context.VmName -VmId $Context.VmId -RunPath $Context.RunPath
    $driverFacts = ConvertTo-VmfGuestFacts -GuestOutput $driverOut
    if (-not $driverFacts.PSObject.Properties['os']) { $driverFacts | Add-Member -NotePropertyName os -NotePropertyValue $os -Force }
    $driverVerdict = Get-VmfDriverJudgement -Facts $driverFacts -TargetIsBoost ((Test-VmfTargetMayUseMana -SizeName $size) -ne $false)
    Write-VmfStepLine -RunPath $Context.RunPath -Step 'driverCheck' -Outcome info -VmId $Context.VmId `
        -Detail (Get-VmfDriverCheckLine -Verdict $driverVerdict -UpdateKernel $false -Os $os -Facts $driverFacts)
    Save-VmfCapturedFacts -Context $Context -Facts @{ driver = @{ status = $driverVerdict.Status; detail = $driverVerdict.Detail; facts = $driverFacts } }
    if ($driverVerdict.Status -eq 'FAIL') { return (& $back 'driverBelowFloor' ([string]$driverVerdict.Detail)) }
    $null
}
