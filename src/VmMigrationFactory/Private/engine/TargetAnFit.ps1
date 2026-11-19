# AN-ONE-NIC-1: a move to a 2-vCPU size stops at PRECHECK when more than one
# network interface has accelerated networking after it.
#
# NIC-1 measured that Azure allows accelerated networking on ONE network
# interface of a 2-vCPU size. The move's default policy is ensureOn: the
# PRIMARY interface carries it (Get-VmfNicAnPlan), and every other interface
# keeps what it has - the engine never turns one off, and VALIDATING fails a
# machine whose interface lost it. So a machine with it off on the primary and
# on for a second interface ends the move with two. Measured 2026-10-10 on
# D2s_v4: the interface update while deallocated is accepted, and every VM
# update after it (a resize, a tag) is refused with
# VmSizeRestrictedToSingleNicWithAcceleratedNetworkingEnable. That is after
# the stop and the safety copies, on every attempt.
#
# Chosen 2026-10-10 (option 1): refuse at PRECHECK, where the machine
# is untouched, and say it on the targets step (Get-VmfTargetSize). Unknown is
# never a fit - the ROLLBACK-RETRY-CAPTURE-2 rule: no vCPU count, a size
# constrained to 2 active vCPUs, or an interface Azure could not read.

function Get-VmfAcceleratedNicsAfter {
    <#
    .SYNOPSIS
        How many network interfaces have accelerated networking after the
        move, from this attempt's capture. Pure.
    .DESCRIPTION
        The primary interface as the move decides (-PrimaryOnAfter,
        Resolve-VmfAcceleratedNetworkingForMove's OnAfter); every other
        interface as it is now, because ensureOn and preserve change no other
        interface on the way to the target. An interface Azure could not read
        is counted as Unknown, never as off: ensureOn turns the primary on
        whatever it reads, but preserve changes nothing, so an unread one
        stays unknown.
    .OUTPUTS
        @{ On = <interfaces with it on>; Unknown = <interfaces not read> }
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter()][AllowNull()]$CapturedNics,
        [Parameter()][AllowNull()]$PrimaryOnAfter
    )
    $nics = @(@($CapturedNics) | Where-Object { $_ })
    $primary = Get-VmfPrimaryNic -Nics $nics
    $primaryId = if ($primary) { [string]$primary.id } else { '' }
    $on = 0; $unknown = 0
    foreach ($nic in $nics) {
        $value = $nic.acceleratedNetworking
        if ([string]$nic.id -eq $primaryId -and $null -ne $PrimaryOnAfter) {
            # Off after the move is a change only to an interface read as on.
            if ([bool]$PrimaryOnAfter -or $null -ne $value) { $value = [bool]$PrimaryOnAfter }
        }
        if ($value -eq $true) { $on++ } elseif ($null -eq $value) { $unknown++ }
    }
    @{ On = $on; Unknown = $unknown }
}

function Get-VmfTargetAnFitRefusal {
    <#
    .SYNOPSIS
        The PRECHECK stop for a target size that cannot allow accelerated
        networking on the interfaces that have it after the move, or $null.
        Pure.
    .DESCRIPTION
        targetOneAcceleratedNic when the size has 2 vCPUs and more than one
        interface has it after the move. targetAcceleratedNicsUnknown when it
        cannot be confirmed: the catalog gives no vCPU count (or does not list
        the size), the size is constrained to 2 active vCPUs, or the interfaces
        Azure could not read make more than one possible.
    .PARAMETER After
        Get-VmfAcceleratedNicsAfter's answer.
    .PARAMETER SkuEntry
        The size catalog's row for the target size, or $null.
    .PARAMETER FoundInGuestPrep
        STOP-TEXT-SPECIFIC-1: GUEST_PREP asks (Test-VmfGuestPrepAcceleratedNicsFit).
        The detail then says why the move turns accelerated networking on
        after Checking passed - the reason text no longer says it for every
        stop.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable]$After,
        [Parameter()][AllowNull()]$SkuEntry,
        [Parameter(Mandatory)][string]$TargetSize,
        [Parameter()][switch]$FoundInGuestPrep
    )
    $maybe = [int]$After.On + [int]$After.Unknown
    if ($maybe -le 1) { return $null }
    $size = Test-VmfSizeAllowsAcceleratedNics -SkuEntry $SkuEntry -Count $maybe
    if ($size.Verdict -eq 'fits') { return $null }
    $unchanged = 'Nothing on the machine changed.'
    if ($FoundInGuestPrep) {
        $unchanged = 'The Azure Linux Agent reported a release that Microsoft does not list for MANA, but the guest has the MANA driver. ' +
                     "So the move turns on accelerated networking for the primary network interface. $unchanged"
    }
    if ($size.Verdict -eq 'tooSmall' -and $After.On -gt 1) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'targetOneAcceleratedNic'
                  Detail = ("The target size $TargetSize has $($size.Vcpus) vCPUs, so Azure allows accelerated networking on one network interface only. " +
                            "After the move, $($After.On) network interfaces of this machine have it, and Azure refuses the move after the machine stops. $unchanged") }
    }
    $what = if ($size.Verdict -eq 'tooSmall') {
                "whether accelerated networking is on for each network interface, because Azure could not read $($After.Unknown) of them, and $TargetSize has $($size.Vcpus) vCPUs"
            }
            elseif ($null -eq $size.Vcpus) { "how many vCPUs $TargetSize has, which decides on how many network interfaces Azure allows accelerated networking" }
            else { "whether Azure allows accelerated networking on more than one network interface of $TargetSize, which has $($size.Active) active vCPUs" }
    @{ Next = 'NEEDS_DECISION'; Reason = 'targetAcceleratedNicsUnknown'
       Detail = ("After the move, more than one network interface of this machine can have accelerated networking. " +
                 "The product cannot confirm $what. $unchanged") }
}

function Get-VmfCheckingManaDriver {
    <#
    .SYNOPSIS
        AN-ONE-NIC-2: the MANA driver reading Checking (PRECHECK) can use,
        before the guest is read: 'unlisted', or '' for unknown. Pure.
    .DESCRIPTION
        'unlisted' only when the VM agent reported a Linux release that
        Microsoft does not list for MANA (Test-VmfReleaseKnownUnlisted, on the
        plan entry's copy of the assessment) - the reading the target advice
        treats as definite, and the one GUEST_PREP gives for that release
        (Get-VmfManaDriverPresence). Anything else - a listed release, a
        release read from the image only, no reading, Windows - is '', which
        Resolve-VmfAcceleratedNetworkingForMove reads as a driver: today's
        answer. Never a guess. GUEST_PREP reads the real driver and asks again
        (Test-VmfGuestPrepAcceleratedNicsFit).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$PlanEntry)
    if (Test-VmfReleaseKnownUnlisted -Vm $PlanEntry.assessment) { return 'unlisted' }
    ''
}

function Test-VmfTargetAcceleratedNicsFit {
    <#
    .SYNOPSIS
        PRECHECK: the stop for a target size that cannot allow accelerated
        networking on the interfaces that have it after the move, or $null.
        Reads the size catalog only when more than one interface can have it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        # This attempt's capture of the machine (Get-VmfVmCapture).
        [Parameter(Mandatory)]$Capture,
        # AN-ONE-NIC-2: the MANA driver reading. Absent: what Checking can know
        # before the guest is read (Get-VmfCheckingManaDriver).
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ManaDriver,
        # STOP-TEXT-SPECIFIC-1: asked from GUEST_PREP; the stop says why.
        [Parameter()][switch]$FoundInGuestPrep
    )
    $plan = $Context.Plan
    $targetSize = [string]$plan.target.size
    if (-not $targetSize) { return $null }
    if (-not $PSBoundParameters.ContainsKey('ManaDriver')) { $ManaDriver = Get-VmfCheckingManaDriver -PlanEntry $plan }
    # The move's own setting on the primary interface, as CONVERTING applies it.
    $move = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $Capture.nics -ManaDriver $ManaDriver
    $after = Get-VmfAcceleratedNicsAfter -CapturedNics $Capture.nics -PrimaryOnAfter $move.OnAfter
    if (([int]$after.On + [int]$after.Unknown) -le 1) { return $null }
    $region = if ([string]$Capture.location) { [string]$Capture.location } else { [string]$plan.assessment.location }
    # ZONES-1: as the machine's own subscription, as the target is read above.
    $vmSub = Get-VmfSubscriptionId -ResourceId $Context.VmId
    $sku = Invoke-VmfAzOperation -Name 'skuCatalog' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        @(Get-VmfSkuCatalog -Location $region -SubscriptionId $vmSub) | Where-Object { $_.Name -eq $targetSize } | Select-Object -First 1
    }
    Get-VmfTargetAnFitRefusal -After $after -SkuEntry $sku -TargetSize $targetSize -FoundInGuestPrep:$FoundInGuestPrep
}

function Test-VmfGuestPrepAcceleratedNicsFit {
    <#
    .SYNOPSIS
        AN-ONE-NIC-2, GUEST_PREP: the stop for a move whose primary interface
        gets accelerated networking after all, or $null.
    .DESCRIPTION
        Checking judged the end state with the driver reading it could have
        before the guest was read (Get-VmfCheckingManaDriver). GUEST_PREP reads
        the real driver. Where Checking kept the primary off and the move now
        turns it on - the release was upgraded since the scan, or the kernel is
        6.14 or later - the count is asked again, here, before any script
        changes the guest. Any other machine: Checking's answer stands, and the
        size catalog is not read.
        AN-MANA-DRIVER-RULE-1: no driver reading keeps the primary off any more
        (only a plan's preserve does, on AMD v5), so Checking and
        GUEST_PREP give the same answer and this asks nothing. It stays as the
        guard that holds the two readings together.
    .PARAMETER Move
        Resolve-VmfAcceleratedNetworkingForMove's answer with the real driver.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][AllowNull()]$CapturedNics,
        [Parameter(Mandatory)]$Move,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$ManaDriver,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Location
    )
    if ($Move.Stop -or $Move.OnAfter -ne $true) { return $null }
    $plan = $Context.Plan
    $checked = Resolve-VmfAcceleratedNetworkingForMove -PlanEntry $plan -CapturedNics $CapturedNics -ManaDriver (Get-VmfCheckingManaDriver -PlanEntry $plan)
    if ($checked.OnAfter -ne $false) { return $null }
    $capture = [pscustomobject]@{ nics = @($CapturedNics); location = $Location }
    Test-VmfTargetAcceleratedNicsFit -Context $Context -Capture $capture -ManaDriver $ManaDriver -FoundInGuestPrep
}