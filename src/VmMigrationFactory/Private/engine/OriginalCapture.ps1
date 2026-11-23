# ROLLBACK-RETRY-CAPTURE-1: the first capture of a machine is kept for the
# put-back.
#
# PRECHECK captures the machine at the start of every attempt
# (captured.vmConfig), and the attempt's own steps use that capture: its safety
# copies are of the disks it names, and a Path B move rebuilds around them. But
# every put-back read the same field as "how the machine was". A retry after a
# restore or a rebuild therefore captured a machine the product had already
# changed - rebuilt on its TARGET size, without its extensions - and from then
# on a rollback or a restore put the machine back to THAT.
#
# So the first capture of the machine in this run is kept whole, once, in
# captured.original (vm-state v16), and nothing writes it again. A put-back
# takes the machine's shape from it - size, disk controller, accelerated
# networking on each interface, each disk's type - and the disks from the
# attempt's own capture: SAFETY-RETRY-1 gives each attempt its own copies, of
# the disks that attempt found, and those are the only disks the copies match.
#
# Every read goes through Get-VmfRecordField: a document is a JSON object when
# read from the store and a hashtable while PRECHECK builds it
# (TYPECHANGE-CHECK-1: PSObject.Properties misses hashtable keys).

function Get-VmfOriginalCapture {
    <#
    .SYNOPSIS
        The first capture of this machine in this run. Pure.
    .DESCRIPTION
        captured.original.vmConfig, written once by the first PRECHECK in the
        same write as the capture (OLD-VERSION-READERS-REMOVE-4: a record of
        this version always holds it). $null when the record holds none -
        never this attempt's capture in its place.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Doc)
    $captured = Get-VmfRecordField -Object $Doc -Name 'captured'
    Get-VmfRecordField -Object (Get-VmfRecordField -Object $captured -Name 'original') -Name 'vmConfig'
}

function Get-VmfPutBackRecordGap {
    <#
    .SYNOPSIS
        Why the record of this machine cannot give a put-back its shape, or
        $null when it can. Pure.
    .DESCRIPTION
        OLD-VERSION-READERS-REMOVE-4: PRECHECK writes the first capture
        (captured.original) with this attempt's capture, and every capture
        says its capacity reservation group, $null for none
        (Get-VmfVmCapture). A record that lacks either is not a record this
        version writes, so a put-back stops - it never takes this attempt's
        capture, which can be of a machine the product already changed, and
        never reads a group it does not know as "in no group".
        A record with no capture of this attempt has nothing to put back to
        and gives $null (Get-VmfPutBackCapture gives $null too).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()]$Doc)
    $captured = Get-VmfRecordField -Object $Doc -Name 'captured'
    if (-not (Get-VmfRecordField -Object $captured -Name 'vmConfig')) { return $null }
    $first = Get-VmfOriginalCapture -Doc $Doc
    if (-not $first) { return 'The record of this machine holds no first capture, so the product does not change the machine.' }
    if (-not (Get-VmfCapturedReservationGroup -Capture $first).Known) {
        return 'The first capture of this machine does not say its capacity reservation group, so the product does not change the machine.'
    }
    $null
}

function Test-VmfMachineTouched {
    <#
    .SYNOPSIS
        Has the product touched this machine in this run - stopped it for a
        copy, prepared its guest, changed it or put it back? Pure.
    .DESCRIPTION
        A machine that only ever reached PRECHECK, and parked there, is as its
        owner keeps it: the product's guidance at such a stop is often to
        change it (remove an interface, turn accelerated networking on), so
        its first capture is refreshed until the product first touches it.
        After that the capture is "how it was", and nothing replaces it.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter()][AllowNull()]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    if ((& $f $Doc 'restore') -or (& $f $Doc 'rollback')) { return $true }
    $past = @('SAFETY_PRISTINE', 'GUEST_PREP', 'STOPPED', 'SAFETY_COPY', 'CONVERTING', 'STARTING', 'VALIDATING', 'MIGRATED', 'FAILED_ROLLED_BACK')
    foreach ($h in @(& $f $Doc 'history')) {
        if (-not $h) { continue }
        if ([string](& $f $h 'state') -in $past) { return $true }
        if ([string](& $f $h 'machineState') -in @('changed', 'restored')) { return $true }
    }
    $false
}

function New-VmfOriginalCaptureRecord {
    <#
    .SYNOPSIS
        What PRECHECK keeps as the first capture, or $null when the one kept
        stands. Pure.
    .DESCRIPTION
        Written at the first PRECHECK, and refreshed by a later one only while
        the product has never touched the machine (Test-VmfMachineTouched) -
        then it is still the machine as its owner keeps it. Once touched, a
        retry, a resume and a second PRECHECK all find it there and leave it.
        OLD-VERSION-READERS-REMOVE-4: a touched machine whose record holds no
        first capture is not a record this version writes. The capture this
        PRECHECK takes can be of a machine the product already changed, so it
        is never taken as the first: this throws, and the attempt does not
        start.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter(Mandatory)]$Capture,
        [Parameter()][AllowNull()][object[]]$Extensions = @(),
        [Parameter()][AllowNull()]$SourceAcceleratedNetworking
    )
    # ConvertFrom-Json turns an ISO date into a date value, so a capture read
    # back from the store holds one; written as text in one form, UTC.
    $iso = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime().ToString('o') } elseif ($v) { [string]$v } else { $null } }
    $captured = Get-VmfRecordField -Object $Doc -Name 'captured'
    $touched = Test-VmfMachineTouched -Doc $Doc
    if ((Get-VmfRecordField -Object $captured -Name 'original') -and $touched) { return $null }
    if ($touched) {
        throw 'The record of this machine holds no first capture, so the product does not start this attempt.'
    }
    $at = & $iso (Get-VmfRecordField -Object $Capture -Name 'capturedUtc')
    [ordered]@{
        vmConfig                    = $Capture
        extensions                  = @($Extensions)
        sourceAcceleratedNetworking = $SourceAcceleratedNetworking
        capturedUtc                 = $(if ($at) { $at } else { (Get-Date).ToUniversalTime().ToString('o') })
    }
}

function Get-VmfPutBackCapture {
    <#
    .SYNOPSIS
        The capture a rollback or a restore puts the machine back to. Pure.
    .DESCRIPTION
        A copy of this attempt's capture - its disks, interfaces, location and
        zone - with the machine's shape from the FIRST capture: the size, the
        disk controller, accelerated networking on each interface it still
        has, and the type of the OS disk and of each data disk by its LUN. The
        capacity reservation group comes from Get-VmfPutBackReservationGroup
        (CRG-ROLLBACK-ATTEMPT-GROUP-1): this attempt's own group, else a group
        an earlier rollback still owes, else the first capture's. The stored
        captures are evidence and are never changed.

        On the first attempt the two captures are the same. A record with no
        first capture, or a first capture that does not say its capacity
        reservation group, throws (Get-VmfPutBackRecordGap): this version
        always writes both, and a put-back never guesses the shape.
    .PARAMETER ProductGroupIds
        Get-VmfProductReservationGroupIds of the run. A caller that acts on the
        capacity reservation group passes it; without it, a group of this
        migration in this attempt's capture is read as the machine's own.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][AllowEmptyCollection()][AllowNull()][string[]]$ProductGroupIds = @()
    )
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $captured = & $f $Doc 'captured'
    $attempt = & $f $captured 'vmConfig'
    if (-not $attempt) { return $null }
    $gap = Get-VmfPutBackRecordGap -Doc $Doc
    if ($gap) { throw $gap }
    $now = $attempt | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $first = & $f (& $f $captured 'original') 'vmConfig'

    $set = { param($o, $name, $value) $o | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    if ([string](& $f $first 'size')) { & $set $now 'size' ([string](& $f $first 'size')) }
    # A Generation 1 machine has no controller on record (ROLLBACK-NULL-1), and
    # its put-back must not name one, so an empty value is copied too.
    & $set $now 'controller' (& $f $first 'controller')
    # ROLLBACK-CRG-1 with CRG-ROLLBACK-ATTEMPT-GROUP-1: the capacity
    # reservation group the machine was in at the start of this attempt, else
    # the group an earlier rollback still owes, else the first capture's (it
    # always says, Get-VmfPutBackRecordGap).
    & $set $now 'capacityReservationGroupId' (Get-VmfPutBackReservationGroup -Doc $Doc -ProductGroupIds $ProductGroupIds).GroupId

    # Accelerated networking, by interface. An interface the first capture
    # never saw keeps what this attempt found; one it could not read stays as
    # this attempt found it - unknown is not a value (ROLLBACK-AN-1).
    $anThen = @{}
    foreach ($nic in @(& $f $first 'nics')) {
        $id = [string](& $f $nic 'id')
        $an = & $f $nic 'acceleratedNetworking'
        if ($id -and $null -ne $an) { $anThen[$id.ToLowerInvariant()] = [bool]$an }
    }
    foreach ($nic in @($now.nics | Where-Object { $_ -and [string]$_.id })) {
        $key = ([string]$nic.id).ToLowerInvariant()
        if ($anThen.ContainsKey($key)) { & $set $nic 'acceleratedNetworking' $anThen[$key] }
    }

    # Each disk's type, by its place: the OS disk, and each data disk by LUN.
    $osThen = [string](& $f (& $f $first 'osDisk') 'skuName')
    if ($osThen -and $now.osDisk) { & $set $now.osDisk 'skuName' $osThen }
    $typeThen = @{}
    foreach ($d in @(& $f $first 'dataDisks')) {
        $sku = [string](& $f $d 'skuName')
        if ($sku -and $null -ne (& $f $d 'lun')) { $typeThen[[int](& $f $d 'lun')] = $sku }
    }
    foreach ($d in @($now.dataDisks | Where-Object { $_ })) {
        if ($typeThen.ContainsKey([int]$d.lun)) { & $set $d 'skuName' $typeThen[[int]$d.lun] }
    }
    $now
}

function Test-VmfRetryHeld {
    <#
    .SYNOPSIS
        SAFETY-RETRY-1: is a retry from the first step refused, because the
        last stop left the machine CHANGED and nothing has mended it since?
        Pure.
    .DESCRIPTION
        A retry from the first step is a complete new run with new safety
        copies, and a new "as it was" copy of a changed machine would be
        wrong. A restore (restore.restoredUtc) later than that stop mends it. A stop that left
        only the power state changed holds nothing (POWER-ONLY-CHANGED-1,
        Get-VmfPowerOwed): the retry puts it back first. The run page
        decides the same way (retryHeld in migrations.html); both are held to
        tests/fixtures/retry-held.json.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)]$Doc)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    # SWAP-REFUSED-AFTER-STOP-1: a put-back a refused data-disk swap left. The
    # machine is stopped with disks from two moments, whatever the last stop
    # says and whatever restore record it has - a restore that left a swap
    # writes one. Finish the rollback or Finish the restore comes first.
    if (& $f $Doc 'swapPending') { return $true }
    $utc = { param($v) if ($v -is [datetime]) { $v.ToUniversalTime() } elseif ($v) { [datetime]::Parse([string]$v, $null, [System.Globalization.DateTimeStyles]'AdjustToUniversal, AssumeUniversal') } else { $null } }
    $lastChange = @(& $f $Doc 'history') | Where-Object { $_ -and (& $f $_ 'machineState') } | Select-Object -Last 1
    if (-not $lastChange -or [string](& $f $lastChange 'machineState') -ne 'changed') { return $false }
    # POWER-ONLY-CHANGED-1: changed ONLY in its power state - Azure refused to
    # put back the power state Checking found. Its disks, size, controller and
    # network are as they were, so a new "as it was" copy is right, and there
    # may be no copy to restore. The retry puts the power state back first.
    if (Get-VmfPowerOwed -Doc $Doc) { return $false }
    # VOLUMES-RETRY-CHECK-1 (2026-11-14): a volume not mounted after a
    # rollback or a restore. The person mounts it inside the machine, and the
    # retry FIRST checks that every volume mounted before the move is mounted
    # again (Invoke-VmfVolumesCheckBeforeRetry) - so it is not held, but only
    # while the record that owes that check is there: without it a retry
    # would skip the check.
    # VOLUMES-NOT-CHECKED-WORDS-1: and a stop of that check that could not run
    # (volumesNotChecked), by the same rule.
    if ([string](& $f $lastChange 'reasonCode') -in @('volumesNotBack', 'volumesNotChecked') -and (Get-VmfVolumesCheckOwed -Doc $Doc)) { return $false }
    $changedAt = & $utc (& $f $lastChange 'tsUtc')
    $mended = @(
        (& $utc (& $f (& $f $Doc 'restore') 'restoredUtc'))
    ) | Where-Object { $_ -and (-not $changedAt -or $_ -gt $changedAt) }
    -not $mended
}

# ROLLBACK-RETRY-CAPTURE-2: a retry is refused when the first size can no
# longer hold the machine.
#
# Every put-back returns the machine to its FIRST capture's size, with the
# network interfaces and data disks it has NOW (Get-VmfPutBackCapture). Between
# two attempts somebody can add an interface or a disk - a retry after Restore
# this machine, or after Rebuild this machine as the target. If the first size
# cannot hold them, Azure refuses the put-back, and it does so inside the
# stopped window. So PRECHECK asks before anything changes (OWNER-QUESTIONS-1
# row 8, decided 2026-10-05).
#
# What the machine has proven is not asked again: the first capture ran on that
# size with its interfaces and disks, and a machine on that size now holds what
# it has. Only a count above both is asked of the size catalog, and a limit the
# catalog does not give is "cannot verify" - never "fits" (NIC-1).

function Get-VmfPutBackFitQuestion {
    <#
    .SYNOPSIS
        What a put-back to the first size needs that the machine has not
        already proven that size holds. Pure.
    .DESCRIPTION
        $null when there is nothing to ask: the product never touched the
        machine (its first capture is refreshed to the machine as it is), the
        document keeps no capture, or every count is one the machine already
        held on that size. A touched machine always has a first capture
        (New-VmfOriginalCaptureRecord refuses one that does not).

        Accelerated networking (NIC-1): a 2-vCPU size permits it on one network
        interface only, and a size that takes none permits it on none. After a
        put-back, an interface has the setting of the first capture, else the
        setting this attempt reads, else what the move left
        (Get-VmfPutBackCapture). What the move leaves: the primary interface as
        the move decides (-PrimaryOnAfter), every other one as it is now. The
        rollback changes the size BEFORE it sets each interface back, so an
        interface counts when it has the setting then OR after
        (REBUILD-REMOVE-ENGINE-1: there is no rollback by rebuild, which set
        each interface back before it). Since
        ROLLBACK-RETRY-CAPTURE-3 the rollback first turns OFF each interface
        recorded off (when another is recorded on and the size has 2 vCPUs),
        before any machine update, so this count is one too high in
        that shape. Kept:
        a refusal here is before anything changes, and it says what to remove.

        On the first size now, the machine proves what it has: an interface
        Azure could not read is not asked about, and the move's own setting on
        the primary interface is the same question a first attempt has, which
        is not asked: the rollback turns it off before any machine update
        (ROLLBACK-RETRY-CAPTURE-3).
    .PARAMETER Capture
        This attempt's capture of the machine (Get-VmfVmCapture).
    .PARAMETER PrimaryOnAfter
        Is accelerated networking on for the primary interface after the move
        (Resolve-VmfAcceleratedNetworkingForMove's OnAfter). $null: as it is now.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][AllowNull()]$Capture,
        [Parameter()][AllowNull()]$PrimaryOnAfter
    )
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    if (-not $Capture -or -not (Test-VmfMachineTouched -Doc $Doc)) { return $null }
    $first = Get-VmfOriginalCapture -Doc $Doc
    $size = [string](& $f $first 'size')
    if (-not $size) { return $null }
    $sameSize = $size -eq [string](& $f $Capture 'size')

    $nicsThen = @(& $f $first 'nics' | Where-Object { $_ })
    $nicsNow = @(& $f $Capture 'nics' | Where-Object { $_ })
    $disksThen = @(& $f $first 'dataDisks' | Where-Object { $_ }).Count
    $disksNow = @(& $f $Capture 'dataDisks' | Where-Object { $_ }).Count

    $anThen = @{}
    foreach ($nic in $nicsThen) {
        $id = [string](& $f $nic 'id')
        $an = & $f $nic 'acceleratedNetworking'
        if ($id -and $null -ne $an) { $anThen[$id.ToLowerInvariant()] = [bool]$an }
    }
    $primary = Get-VmfPrimaryNic -Nics $nicsNow
    $primaryId = if ($primary) { ([string](& $f $primary 'id')).ToLowerInvariant() } else { '' }
    $anOn = 0; $anPutBack = 0; $anUnknown = 0; $liveOn = 0; $liveUnread = 0
    foreach ($nic in $nicsNow) {
        $id = ([string](& $f $nic 'id')).ToLowerInvariant()
        $live = & $f $nic 'acceleratedNetworking'
        if ($live -eq $true) { $liveOn++ } elseif ($null -eq $live) { $liveUnread++ }
        $moved = if ($id -eq $primaryId -and -not $sameSize -and $null -ne $PrimaryOnAfter) { [bool]$PrimaryOnAfter } else { $live }
        $back = if ($anThen.ContainsKey($id)) { $anThen[$id] } elseif ($null -ne $live) { [bool]$live } else { $moved }
        if ($back -eq $true) { $anPutBack++ }
        if ($back -eq $true -or $moved -eq $true) { $anOn++ }
        elseif ($null -eq $back -or $null -eq $moved) { $anUnknown++ }
    }
    $anProven = @($nicsThen | Where-Object { (& $f $_ 'acceleratedNetworking') -eq $true }).Count
    if ($sameSize) {
        # Azure holds this machine on this size now, as it is - an interface
        # it could not read included.
        $anProven = [Math]::Max($anProven, $liveOn + $liveUnread)
    }

    $nicsAsk = -not $sameSize -and $nicsNow.Count -gt $nicsThen.Count
    $disksAsk = -not $sameSize -and $disksNow -gt $disksThen
    $anAsk = ($anOn + $anUnknown) -gt $anProven
    if (-not ($nicsAsk -or $disksAsk -or $anAsk)) { return $null }
    [pscustomobject]@{
        Size      = $size
        NicsAsk   = $nicsAsk
        NicsNow   = $nicsNow.Count
        DisksAsk  = $disksAsk
        DisksNow  = $disksNow
        AnAsk     = $anAsk
        AnOn      = $anOn
        AnPutBack = $anPutBack
        AnUnknown = $anUnknown
    }
}

function Get-VmfPutBackFitRefusal {
    <#
    .SYNOPSIS
        The PRECHECK stop for a first size that cannot hold the machine, or
        $null when it holds it. Pure.
    .DESCRIPTION
        putBackSizeTooSmall when the size catalog gives a limit below what the
        machine has; putBackSizeUnknown when it gives none (or does not list
        the size) - unknown is never a fit. A limit known to be too small is
        said first.
    .PARAMETER SkuEntry
        The size catalog's row for the first size, or $null when the catalog
        does not list it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Question,
        [Parameter()][AllowNull()]$SkuEntry
    )
    $size = [string]$Question.Size
    $tooSmall = [System.Collections.Generic.List[string]]::new()
    $unknown = [System.Collections.Generic.List[string]]::new()

    if ($Question.NicsAsk) {
        $max = Get-VmfSkuMaxNics -SkuEntry $SkuEntry
        if ($null -eq $max) { $unknown.Add("how many network interfaces $size holds (the machine has $($Question.NicsNow))") }
        elseif ($max -lt $Question.NicsNow) { $tooSmall.Add("$size holds $max network interfaces, and the machine has $($Question.NicsNow) now.") }
    }
    if ($Question.DisksAsk) {
        $max = Get-VmfSkuMaxDataDisks -SkuEntry $SkuEntry
        if ($null -eq $max) { $unknown.Add("how many data disks $size holds (the machine has $($Question.DisksNow))") }
        elseif ($max -lt $Question.DisksNow) { $tooSmall.Add("$size holds $max data disks, and the machine has $($Question.DisksNow) now.") }
    }
    if ($Question.AnAsk) {
        $takes = Test-VmfSizeTakesAcceleratedNetworking -SkuEntry $SkuEntry
        $maybe = $Question.AnOn + $Question.AnUnknown
        if ($takes -eq $false) {
            # OLD-FAM-1: every rollback and restore turns it off first on the interfaces
            # the first capture knew, so only the put-back's own setting counts.
            if ($Question.AnPutBack -gt 0) { $tooSmall.Add("$size does not take accelerated networking, and $($Question.AnPutBack) network interfaces keep it after a rollback.") }
        }
        elseif ($null -eq $takes -and $Question.AnPutBack -gt 0) { $unknown.Add("whether $size takes accelerated networking") }
        elseif ($maybe -gt 1) {
            # AN-ONE-NIC-2: the 2-vCPU rule (NIC-1) in one place, the one the
            # target size is held to (Test-VmfSizeAllowsAcceleratedNics).
            $fit = Test-VmfSizeAllowsAcceleratedNics -SkuEntry $SkuEntry -Count $maybe
            if ($fit.Verdict -eq 'tooSmall') {
                if ($Question.AnOn -gt 1) { $tooSmall.Add("$size has $($fit.Vcpus) vCPUs, so Azure allows accelerated networking on one network interface only, and $($Question.AnOn) interfaces have it.") }
                else { $unknown.Add("whether accelerated networking is on for each network interface, because Azure could not read every one") }
            }
            elseif ($fit.Verdict -eq 'unknown') {
                if ($null -eq $fit.Vcpus) { $unknown.Add("how many vCPUs $size has, which decides on how many network interfaces Azure allows accelerated networking") }
                else { $unknown.Add("whether Azure allows accelerated networking on more than one network interface of $size, which has $($fit.Active) active vCPUs") }
            }
        }
    }

    $lead = "A rollback or a restore returns this machine to its original size, $size."
    if ($tooSmall.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'putBackSizeTooSmall'
                  Detail = "$lead $($tooSmall -join ' ') Azure refuses that rollback while the machine is stopped. Nothing on the machine changed." }
    }
    if ($unknown.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'putBackSizeUnknown'
                  Detail = "$lead The Azure size catalog does not say $($unknown -join ', or '). So the product cannot confirm that a rollback works. Nothing on the machine changed." }
    }
    $null
}

function Test-VmfPutBackSizeFits {
    <#
    .SYNOPSIS
        PRECHECK: the stop for a retry whose first size cannot hold the
        machine, or $null. Reads the size catalog only when there is something
        the machine has not proven.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Capture,
        # The state document PRECHECK read before this attempt's capture.
        [Parameter()][AllowNull()]$Doc
    )
    if (-not $Doc) { $Doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId }
    # The move's own setting on the primary interface, as CONVERTING applies
    # it before a Path A rollback changes the size back.
    $onAfter = (Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $Context.Plan -CapturedNics $Capture.nics).OnAfter
    $question = Get-VmfPutBackFitQuestion -Doc $Doc -Capture $Capture -PrimaryOnAfter $onAfter
    if (-not $question) { return $null }
    $region = if ([string]$Capture.location) { [string]$Capture.location } else { [string]$Context.Plan.assessment.location }
    $size = [string]$question.Size
    # ZONES-1: as the machine's own subscription, as the target is read.
    $vmSub = Get-VmfSubscriptionId -ResourceId $Context.VmId
    $sku = Invoke-VmfAzOperation -Name 'skuCatalog' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        @(Get-VmfSkuCatalog -Location $region -SubscriptionId $vmSub) | Where-Object { $_.Name -eq $size } | Select-Object -First 1
    }
    Get-VmfPutBackFitRefusal -Question $question -SkuEntry $sku
}
