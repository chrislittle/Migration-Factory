# SAFETY-ULTRA-1: the rollback for Premium SSD v2 and Ultra Disk data disks.
#
# The rule of 2026-10-10: a machine must always go back fully to its safety copies.
# A copy of these two types cannot make a disk until Azure has copied it in
# the background - unless it is an instant access copy, and then only for the
# minutes Azure gave it. So the engine asks Azure, never a stored date, at the
# three moments that decide whether the rollback exists:
#   1. PRECHECK: what a new disk needs is recorded, read from each disk by its
#      id, and a disk Azure is still filling from a copy is refused (Azure
#      gives no instant access copy of it).
#   2. After the first copies, while the machine is still stopped: every copy
#      must be usable before anything changes. A copy that is not usable yet
#      is waited for, stopped, up to 30 minutes - never while the machine runs,
#      because a rollback returns each disk to the copy moment and every write
#      during a wait would be lost.
#   3. Just before the conversion: each copy must be complete, or have at
#      least 120 minutes of instant access left. If not, the machine is put
#      back at once, never converted into a move whose rollback ends during it.
# Every reading of a copy goes through Get-VmfSnapshotAccess (azureops).

function Get-VmfCopyUsability {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: what Azure said about one copy, as the engine judges
        it. Pure.
    .DESCRIPTION
        Usable: snapshotAccessState InstantAccess, AvailableWithInstantAccess
        or Available (Microsoft, instant access snapshots). Complete: the
        background copy is finished - Available or AvailableWithInstantAccess.
        Pending, an empty state, or no reading at all is not usable: unknown
        is never a yes.
        MinutesLeft: the instant access left at -NowUtc, from Azure's own
        timeCreated and instantAccessDurationMinutes; $null when Azure gave
        either one no value.
    .OUTPUTS
        @{ State; Percent; Usable; Complete; MinutesLeft; TakenUtc }
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()][AllowNull()]$Access,
        [Parameter(Mandatory)][datetime]$NowUtc
    )
    $state = if ($Access) { [string]$Access.snapshotAccessState } else { '' }
    $complete = $state -in @('Available', 'AvailableWithInstantAccess')
    $usable = $complete -or $state -eq 'InstantAccess'
    $taken = $null
    $left = $null
    if ($Access -and [string]$Access.timeCreated) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Access.timeCreated, [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal', [ref]$parsed)) {
            $taken = $parsed
            if ($null -ne $Access.instantAccessDurationMinutes) {
                $left = [int][math]::Floor(($parsed.AddMinutes([double]$Access.instantAccessDurationMinutes) - $NowUtc.ToUniversalTime()).TotalMinutes)
            }
        }
    }
    [pscustomobject]@{
        State       = $state
        Percent     = $(if ($Access) { $Access.completionPercent } else { $null })
        Usable      = [bool]$usable
        Complete    = [bool]$complete
        MinutesLeft = $left
        TakenUtc    = $taken
    }
}

function Get-VmfInstantAccessCopyReadiness {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: read every recorded copy of a Premium SSD v2 or Ultra
        Disk data disk from Azure, and judge it (Get-VmfCopyUsability).
    .DESCRIPTION
        A copy whose read fails is in the answer, not usable, with the error:
        the caller says so rather than guessing. A machine with no such disk
        makes no Azure call.
        -Kind all also reads the copies of earlier attempts: a restore that
        keeps the names must know every copy that depends on a disk it would
        delete.
    .OUTPUTS
        A hashtable: snapshot id -> @{ snapshotId; diskId; lun; State; Percent;
        Usable; Complete; MinutesLeft; TakenUtc; Error }.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Doc,
        [Parameter()][ValidateSet('pristine', 'prepared', 'all')][string]$Kind = 'pristine'
    )
    # The LUNs of these types, in either capture.
    $luns = @{}
    $original = Get-VmfRecordField -Object (Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'original') -Name 'vmConfig'
    $attempt = Get-VmfRecordField -Object (Get-VmfRecordField -Object $Doc -Name 'captured') -Name 'vmConfig'
    foreach ($vm in @($attempt, $original)) {
        foreach ($d in @(Get-VmfRecordField -Object $vm -Name 'dataDisks')) {
            if ($d -and $script:VmfInstantAccessDiskTypes.ContainsKey([string](Get-VmfRecordField -Object $d -Name 'skuName'))) { $luns[[int](Get-VmfRecordField -Object $d -Name 'lun')] = $true }
        }
    }
    $map = @{}
    if (-not $luns.Count) { return $map }

    $records = [System.Collections.Generic.List[object]]::new()
    $kinds = if ($Kind -eq 'all') { @('pristine', 'prepared') } else { @($Kind) }
    foreach ($k in $kinds) { foreach ($c in @(Get-VmfDataCopies -Doc $Doc -Kind $k)) { $records.Add($c) } }
    if ($Kind -eq 'all') {
        $safety = Get-VmfRecordField -Object $Doc -Name 'safety'
        foreach ($earlier in @(Get-VmfRecordField -Object $safety -Name 'earlierCopies')) {
            foreach ($field in 'pristineDataCopies', 'dataCopies') {
                foreach ($c in @(Get-VmfRecordField -Object $earlier -Name $field)) { if ($c) { $records.Add($c) } }
            }
        }
    }
    foreach ($c in $records) {
        $copyId = [string]$c.snapshotId
        if (-not $copyId -or $map.ContainsKey($copyId) -or -not $luns.ContainsKey([int]$c.lun)) { continue }
        $err = $null
        $judged = $null
        try {
            $access = Invoke-VmfAzOperation -Name 'readSafetyCopy' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfSnapshotAccess -SnapshotId $copyId
            }
            $judged = Get-VmfCopyUsability -Access $access -NowUtc ((Get-Date).ToUniversalTime())
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $err = $_.Exception.Message
            $judged = Get-VmfCopyUsability -Access $null -NowUtc ((Get-Date).ToUniversalTime())
        }
        $map[$copyId] = [pscustomobject]@{
            snapshotId = $copyId; diskId = [string]$c.diskId; lun = [int]$c.lun
            State = $judged.State; Percent = $judged.Percent; Usable = $judged.Usable; Complete = $judged.Complete
            MinutesLeft = $judged.MinutesLeft; TakenUtc = $judged.TakenUtc; Error = $err
        }
    }
    $map
}

function Format-VmfCopyState {
    # One copy, as a person reads it in a stop or the log.
    param([Parameter(Mandatory)]$Ready)
    if ([string]$Ready.Error) { return "LUN $($Ready.lun): the product could not read its copy ($($Ready.Error))" }
    $state = if ($Ready.State) { $Ready.State } else { 'not given' }
    $pct = if ($null -ne $Ready.Percent) { ", $([math]::Floor([double]$Ready.Percent)) percent copied" } else { '' }
    $left = if ($null -ne $Ready.MinutesLeft -and $Ready.State -eq 'InstantAccess') { ", $([math]::Max(0, [int]$Ready.MinutesLeft)) minutes of instant access left" } else { '' }
    "LUN $($Ready.lun): access state $state$pct$left"
}

function Add-VmfInstantAccessDiskFacts {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1, at PRECHECK: read each Premium SSD v2 and Ultra Disk
        data disk by its resource id, and record on its capture entry what a
        rollback needs to make it again.
    .DESCRIPTION
        diskIOPSReadWrite, diskMBpsReadWrite and logicalSectorSize are what
        the new disk is made with and compared against; diskZones, maxShares
        and completionPercent are evidence and checks; sizeGB is the disk's
        own size. Changes -Capture in place.

        Each refusal is untouched, with words a person can act on - what
        cannot be put back fully is refused before any change:
          - a machine in an availability set with any such disk: Microsoft's
            instant access page says these disks cannot be attached across
            fault domains while they have an active instant access copy, and
            a machine in an availability set counts. A rollback would then
            fail to attach its disks, past the point of no return. Outside the
            scope of this tool (instantAccessAvailabilitySet). Asked before any
            disk is read;
          - a disk Azure returns no IOPS, throughput or sector size for: a
            rollback could not make it again (dataDiskValuesUnknown);
          - a disk still being filled from a copy (completionPercent below
            100 - a retry soon after a rollback): Azure takes no instant
            access copy of it (dataDiskFilling).
    .OUTPUTS
        $null, or the NEEDS_DECISION result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Capture)
    $special = @(@(Get-VmfRecordField -Object $Capture -Name 'dataDisks') | Where-Object {
            $_ -and $script:VmfInstantAccessDiskTypes.ContainsKey([string](Get-VmfRecordField -Object $_ -Name 'skuName')) })
    if (-not $special.Count) { return $null }
    $say = { param($d) "'$([string](Get-VmfRecordField -Object $d -Name 'name'))' on LUN $(Get-VmfRecordField -Object $d -Name 'lun') ($($script:VmfInstantAccessDiskTypes[[string](Get-VmfRecordField -Object $d -Name 'skuName')]))" }

    if ([string](Get-VmfRecordField -Object $Capture -Name 'availabilitySetId')) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'instantAccessAvailabilitySet'; MachineState = 'untouched'
            Detail = "This machine is in an availability set and has these data disks: $(@($special | ForEach-Object { & $say $_ }) -join ', '). Azure does not attach such a disk across fault domains while it has an instant access copy, so a rollback could not attach it. A machine like this is outside the scope of this tool. Nothing on the machine changed." }
    }

    $filling = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()
    foreach ($dd in $special) {
        $diskId = [string](Get-VmfRecordField -Object $dd -Name 'managedDiskId')
        $facts = Invoke-VmfAzOperation -Name 'readDataDiskFacts' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfManagedDiskFacts -DiskId $diskId
        }
        $missing = @(foreach ($pair in @(@('diskIOPSReadWrite', 'IOPS'), @('diskMBpsReadWrite', 'throughput'), @('logicalSectorSize', 'sector size'))) {
                if ($null -eq $facts.($pair[0])) { $pair[1] } })
        if ($missing.Count) { $unknown.Add("$(& $say $dd): no $($missing -join ', ')"); continue }
        $set = @{
            diskIOPSReadWrite = [long]$facts.diskIOPSReadWrite
            diskMBpsReadWrite = [long]$facts.diskMBpsReadWrite
            logicalSectorSize = [long]$facts.logicalSectorSize
            diskZones         = @(@($facts.zones) | Where-Object { $_ } | ForEach-Object { [string]$_ })
            maxShares         = $facts.maxShares
            completionPercent = $facts.completionPercent
        }
        if ($null -ne $facts.diskSizeGB) { $set.sizeGB = [long]$facts.diskSizeGB }
        foreach ($k in $set.Keys) {
            if ($dd -is [System.Collections.IDictionary]) { $dd[$k] = $set[$k] }
            else { $dd | Add-Member -NotePropertyName $k -NotePropertyValue $set[$k] -Force }
        }
        if ($null -ne $facts.completionPercent -and [double]$facts.completionPercent -lt 100) {
            $filling.Add("$(& $say $dd), $([math]::Floor([double]$facts.completionPercent)) percent")
        }
    }
    if ($unknown.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'dataDiskValuesUnknown'; MachineState = 'untouched'
            Detail = "Azure did not return a value that a rollback needs to make these data disks again: $($unknown -join '; '). The product does not start a move it cannot roll back. Nothing on the machine changed." }
    }
    if (-not $filling.Count) { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'dataDiskFilling'; MachineState = 'untouched'
       Detail = "Azure is still filling these data disks from a copy: $($filling -join '; '). Azure takes no instant access copy of a disk while it fills it, and a rollback or a restore of the disk uses that copy. Nothing on the machine changed." }
}

function Wait-VmfInstantAccessCopies {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1, at the end of SAFETY_PRISTINE: go on only when Azure
        says every first copy of a Premium SSD v2 or Ultra Disk is usable.
    .DESCRIPTION
        Called with the machine stopped, before it starts again and before
        anything changes it - on every path through the step, a resume after
        a stop during the wait included (that resume takes no new copy and
        reads Azure again).
          - Every copy usable: $null, and the step goes on.
          - A copy not usable yet, the machine stopped: read again every
            -PollSeconds, renewing the lease, until each copy is usable or
            -MaxMinutes have passed since Azure made it (its own timeCreated,
            so a resume does not start the count again).
          - The machine running (a resume after it was started): no wait.
        At the limit, or when the machine runs, the move stops with nothing
        changed, and the machine is started again - or goes back to the power
        state Checking found (STOP-POWER-AS-FOUND-1).
    .OUTPUTS
        $null, or the stop result (FAILED_NEEDS_ATTENTION, safetyCopyNotReady).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][int]$MaxMinutes = $script:VmfCopyWaitMinutes,
        [Parameter()][int]$PollSeconds = 30
    )
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $started = (Get-Date).ToUniversalTime()
    $waited = $false
    while ($true) {
        $ready = Get-VmfInstantAccessCopyReadiness -Context $Context -Doc $doc -Kind 'pristine'
        $notYet = @($ready.Values | Where-Object { -not $_.Usable } | Sort-Object lun)
        if (-not $notYet.Count) {
            if ($ready.Count) {
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'SAFETY_PRISTINE' -Outcome info -VmId $Context.VmId `
                    -Detail "Azure can make a disk from every first safety copy of a Premium SSD v2 or Ultra Disk data disk: $(@($ready.Values | Sort-Object lun | ForEach-Object { Format-VmfCopyState -Ready $_ }) -join '; ')."
            }
            return $null
        }
        $stopWords = $null
        if (-not $waited) {
            $power = Invoke-VmfAzOperation -Name 'powerForCopyWait' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfPowerState -ResourceGroupName $Context.Rg -Name $Context.VmName
            }
            if ([string]$power -notin @('PowerState/deallocated', 'PowerState/stopped')) {
                $stopWords = 'The machine runs, and the product does not wait while a machine runs: a rollback would lose every write made during the wait.'
            }
            else {
                $waited = $true
                Write-VmfStepLine -RunPath $Context.RunPath -Step 'SAFETY_PRISTINE' -Outcome info -VmId $Context.VmId `
                    -Detail "The machine stays stopped while Azure makes these first safety copies usable, for at most $MaxMinutes minutes: $(@($notYet | ForEach-Object { Format-VmfCopyState -Ready $_ }) -join '; ')."
            }
        }
        if (-not $stopWords) {
            $nowUtc = (Get-Date).ToUniversalTime()
            $late = @($notYet | Where-Object { $from = if ($_.TakenUtc) { [datetime]$_.TakenUtc } else { $started }; $nowUtc -ge $from.AddMinutes($MaxMinutes) })
            if ($late.Count) { $stopWords = "The machine stayed stopped for up to $MaxMinutes minutes after each copy was made, and Azure did not make them usable." }
        }
        if ($stopWords) {
            # STOP-POWER-AS-FOUND-1: back to the power state Checking found.
            $restore = Resolve-VmfStoppedMachineState -Context $Context -AsFound
            return @{
                Next         = 'FAILED_NEEDS_ATTENTION'
                Reason       = 'safetyCopyNotReady'
                PowerAsFound = $true
                MachineState = $(if ($restore.MachineState -eq 'restored') { 'untouched' } else { 'changed' })
                # POWER-ONLY-CHANGED-1: the power state found, when only its
                # put-back was refused.
                PowerNotPutBack = $restore.PowerNotPutBack
                Detail       = "Azure cannot make a disk yet from the first safety copy of: $(@($notYet | ForEach-Object { Format-VmfCopyState -Ready $_ }) -join '; '). The product changes a machine only when every copy can bring it back. $stopWords Nothing on the machine changed - $($restore.Detail)."
            }
        }
        # EVAL-H1: renew the lease while waiting.
        if ($script:VmfOpHeartbeat) { & $script:VmfOpHeartbeat }
        Start-Sleep -Seconds $PollSeconds
    }
}

function Get-VmfCopyWindowProblems {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1: the copies that would not last through a conversion.
        Pure.
    .DESCRIPTION
        A copy passes when it is complete, or in instant access with at least
        -MarginMinutes left. Pending, an unread copy, or instant access whose
        end Azure did not say all fail: unknown is not a yes.
    .OUTPUTS
        One sentence part per copy that fails; empty when every copy passes.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter()][AllowEmptyCollection()][object[]]$Readiness = @(),
        [Parameter(Mandatory)][int]$MarginMinutes
    )
    @(foreach ($r in @($Readiness | Where-Object { $_ } | Sort-Object lun)) {
            if ($r.Complete -and -not [string]$r.Error) { continue }
            if ($r.State -eq 'InstantAccess' -and $null -ne $r.MinutesLeft -and [int]$r.MinutesLeft -ge $MarginMinutes -and -not [string]$r.Error) { continue }
            Format-VmfCopyState -Ready $r
        })
}

function Test-VmfCopyWindowBeforeConversion {
    <#
    .SYNOPSIS
        SAFETY-ULTRA-1, at the start of CONVERTING, before any change: will
        the rollback last through the conversion?
    .DESCRIPTION
        Each first copy of a Premium SSD v2 or Ultra Disk must be complete, or
        have at least 120 minutes of instant access left. When one does not,
        the machine never converts (ONE-WINDOW-1):
          - the preparation changed the guest in this attempt: the disks go
            back from the first copy at once, while the copies are still
            usable (PutBack: the disks-only rollback);
          - nothing changed: the machine starts again, untouched - or goes
            back to the power state Checking found (STOP-POWER-AS-FOUND-1).
        Only before the conversion starts: after it, the fastest way out is to
        finish or to roll back.
    .OUTPUTS
        $null, or the step result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Doc)
    $ready = Get-VmfInstantAccessCopyReadiness -Context $Context -Doc $Doc -Kind 'pristine'
    if (-not $ready.Count) { return $null }
    $problems = @(Get-VmfCopyWindowProblems -Readiness @($ready.Values) -MarginMinutes $script:VmfCopyMarginMinutes)
    if (-not $problems.Count) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'CONVERTING' -Outcome info -VmId $Context.VmId `
            -Detail "Every first safety copy of a Premium SSD v2 or Ultra Disk data disk lasts through the move: $(@($ready.Values | Sort-Object lun | ForEach-Object { Format-VmfCopyState -Ready $_ }) -join '; ')."
        return $null
    }
    $detail = "Before the move, each first safety copy of a Premium SSD v2 or Ultra Disk data disk must be complete, or usable for at least $script:VmfCopyMarginMinutes more minutes. These are not: $($problems -join '; '). The machine did not move."
    if (Test-VmfGuestChangedThisAttempt -Doc $Doc) {
        return @{ Next = 'FAILED_ROLLED_BACK'; PutBack = $true; Reason = 'safetyCopyWindowShort'; Detail = $detail }
    }
    # STOP-POWER-AS-FOUND-1: back to the power state Checking found.
    $restore = Resolve-VmfStoppedMachineState -Context $Context -AsFound
    @{ Next = 'FAILED_NEEDS_ATTENTION'; Reason = 'safetyCopyWindowShort'; PowerAsFound = $true
       MachineState = $(if ($restore.MachineState -eq 'restored') { 'untouched' } else { 'changed' })
       PowerNotPutBack = $restore.PowerNotPutBack
       Detail = "$detail Nothing on the machine changed - $($restore.Detail)." }
}
