# OLD-SKU-1C: upgrade a machine's disks to Premium SSD during the move.
# HDD-OS-1: and change a Standard HDD OS disk to Standard SSD (os-standard-ssd).
#
# A person picks it per machine on the targets step: keep the disk types, the
# OS disk only, or every disk (plan-entry policy.diskUpgrade: os | all). The
# change is made while the machine is stopped, after the safety copies and
# after the machine is on its new size - a Premium SSD disk needs a size that
# takes one, and an old size such as D4_v2 does not.
#
# ONE CHANGE WINDOW, and the rollback is the copies. A rollback makes a NEW
# disk from each copy on the type the capture recorded, so it puts the old
# type back without changing the upgraded disk a second time. A disk a
# put-back keeps (no copy on record) has its type set back instead.
#
# AZURE ALLOWS TWO DISK TYPE CHANGES PER DISK A DAY. Every change this product
# makes is recorded on the machine's state document (diskTypeChanges), kept
# across attempts, and a move that would make a third change inside 24 hours
# stops before the machine is touched, with the time it can run.
# Microsoft, under Restrictions: "You can only change disk type twice per day."
# https://learn.microsoft.com/en-us/azure/virtual-machines/disks-convert-types
# The page does not say whether a day is 24 hours or a calendar day, or count
# by direction. A third change inside one UTC day WAS accepted once
# (TYPECHANGE-CHECK-1, 2026-09-30); one acceptance does not make a published
# limit safe to pass, so the rule stays on the safe side: 24 hours.

# The type a disk becomes. Redundancy is kept: a zone-redundant disk stays
# zone-redundant. Premium SSD is already there; Premium SSD v2 and Ultra Disk
# are faster types that are never changed; anything else is not known.
$script:VmfPremiumDiskSkuFor = @{
    'Standard_LRS'    = 'Premium_LRS'
    'StandardSSD_LRS' = 'Premium_LRS'
    'StandardSSD_ZRS' = 'Premium_ZRS'
}

# HDD-OS-1: the type a Standard HDD OS disk becomes. Microsoft retires Standard
# HDD as the type of an OS disk on 8 September 2028 (disks-hdd-os-retirement)
# and names Standard SSD as the closest in price and performance. Standard HDD
# has only the locally redundant type - Microsoft's own list of these disks
# filters on "Standard HDD LRS" - so there is no zone-redundant case. Any other
# type is not changed: it is not retired.
# MEASURED 2026-10-25 (one machine, westus3): Azure refuses the change while the
# machine runs ("Cannot change account type ... while it is attached to running
# VM"); on the deallocated machine Standard HDD to Standard SSD and back, six
# changes in a few minutes, were all accepted and read back, and the machine
# started on Standard SSD. The 24-hour rule above stays: Microsoft's page still
# says twice a day.
$script:VmfStandardSsdDiskSkuFor = @{
    'Standard_LRS' = 'StandardSSD_LRS'
}

function Get-VmfPremiumDiskSku {
    <#
    .SYNOPSIS
        OLD-SKU-1C: the Premium SSD type for a disk type, or $null when the
        disk is not changed (already Premium SSD, a faster type, or unknown).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$SkuName)
    if ($SkuName -and $script:VmfPremiumDiskSkuFor.ContainsKey($SkuName)) { return $script:VmfPremiumDiskSkuFor[$SkuName] }
    $null
}

function Get-VmfDiskUpgradeValue {
    # The plan entry's choice: 'os', 'all', 'os-standard-ssd' (HDD-OS-1),
    # or '' for keep.
    param([Parameter(Mandatory)]$PlanEntry)
    # Member access, not PSObject.Properties: an entry can be an object or a
    # hashtable (TYPECHANGE-CHECK-1).
    if ($PlanEntry.policy) {
        $v = [string]$PlanEntry.policy.diskUpgrade
        if ($v -in @('os', 'all', 'os-standard-ssd')) { return $v }
    }
    ''
}

function Get-VmfDiskTypeUpgradePlan {
    <#
    .SYNOPSIS
        OLD-SKU-1C: which of the captured disks change type, from what to what.
        Pure: no Azure.
    .OUTPUTS
        @{ diskId; name; role = 'os' | 'data'; lun; from; to } for each disk
        that changes. A disk that is already Premium SSD, or on a type this
        product never changes, is not in the list.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param(
        [Parameter(Mandatory)]$Capture,
        [Parameter()][AllowEmptyString()][ValidateSet('', 'os', 'all', 'os-standard-ssd')][string]$Upgrade
    )
    if (-not $Upgrade) { return @() }
    # HDD-OS-1: Standard SSD is for the OS disk only, and only from Standard
    # HDD; os and all go to Premium SSD.
    $standardSsd = $Upgrade -eq 'os-standard-ssd'
    $out = [System.Collections.Generic.List[object]]::new()
    $one = { param($disk, $role)
        # TYPECHANGE-CHECK-1: PRECHECK passes the capture as Get-VmfVmCapture
        # makes it - ordered hashtables - and CONVERTING passes it as read back
        # from the state document - objects. PSObject.Properties sees no key of
        # a hashtable, so this plan was EMPTY at PRECHECK and both of its checks
        # were skipped on every real move; a retry then changed a data disk a
        # third time in a day. Member access reads both shapes.
        $from = [string]$disk.skuName
        $to = if ($standardSsd) { if ($script:VmfStandardSsdDiskSkuFor.ContainsKey($from)) { $script:VmfStandardSsdDiskSkuFor[$from] } else { $null } }
              else { Get-VmfPremiumDiskSku -SkuName $from }
        if ($to -and [string]$disk.managedDiskId) {
            $out.Add([pscustomobject]@{ diskId = [string]$disk.managedDiskId; name = [string]$disk.name; role = $role
                    lun = $(if ($role -eq 'data') { [int]$disk.lun } else { $null }); from = $from; to = $to })
        }
    }
    if ($Capture.osDisk) { & $one $Capture.osDisk 'os' }
    if ($Upgrade -eq 'all') { foreach ($dd in @($Capture.dataDisks | Where-Object { $_ })) { & $one $dd 'data' } }
    @($out)
}

function Get-VmfDiskTypeChangeRefusal {
    <#
    .SYNOPSIS
        OLD-SKU-1C: is there room inside Azure's limit - two type changes per
        disk in 24 hours - for the changes a move may make? Pure: reads the
        record on the state document.
    .DESCRIPTION
        A move needs room for TWO: its own change, and the rollback's change
        back. Without the second, a failed move could not set the type back,
        and a size that takes no Premium SSD would then refuse the machine.
        So one recorded change in the last 24 hours is already too many.
        The record holds only the changes this product made for this machine
        in this migration; a change made by hand is not in it.
    .OUTPUTS
        $null, or @{ disk; retryAfterUtc } for the disk that must wait longest.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][AllowNull()]$Doc,
        [Parameter()][string[]]$DiskIds = @(),
        [Parameter()][datetime]$NowUtc = (Get-Date).ToUniversalTime(),
        [Parameter()][ValidateRange(1, 2)][int]$Room = 2
    )
    if (-not $Doc -or -not $Doc.PSObject.Properties['diskTypeChanges']) { return $null }
    # TYPECHANGE-CHECK-1: ConvertFrom-Json gives a date value, not the text.
    # [string] of a date value drops its zone, so a local one read as UTC moved
    # by the offset. A date value is turned to UTC as it is; only text is parsed.
    $asUtc = { param($v)
        if ($v -is [datetime]) {
            # A date with no zone (Kind Unspecified) is the store's UTC, as the
            # text branch below assumes - never local time.
            if ($v.Kind -eq [System.DateTimeKind]::Unspecified) { return [datetime]::SpecifyKind($v, [System.DateTimeKind]::Utc) }
            return $v.ToUniversalTime()
        }
        if ($v -is [datetimeoffset]) { return $v.UtcDateTime }
        [datetime]::Parse([string]$v, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal)
    }
    $worst = $null
    foreach ($id in $DiskIds) {
        # -eq on text ignores letter case: Azure returns a resource group name
        # in either case, and the record and a new capture may differ.
        $recent = @(@($Doc.diskTypeChanges) | Where-Object { [string]$_.diskId -eq $id } | ForEach-Object { & $asUtc $_.utc } |
                Where-Object { $_ -gt $NowUtc.AddHours(-24) } | Sort-Object)
        # Changes that must drop out of the 24 hours first, oldest first.
        $over = $recent.Count - (2 - $Room)
        if ($over -gt 0) {
            $after = $recent[$over - 1].AddHours(24)
            if (-not $worst -or $after -gt $worst.retryAfterUtc) { $worst = [pscustomobject]@{ disk = $id; retryAfterUtc = $after } }
        }
    }
    $worst
}

function Add-VmfDiskTypeChangeRecord {
    <#
    .SYNOPSIS
        OLD-SKU-1C: record one disk type change on the state document, BEFORE
        it is made - a change Azure made but the product never recorded would
        let a third change through. Kept across attempts: it is about Azure's
        count, not about this attempt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][ValidateSet('move', 'rollback', 'restore')][string]$By
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    $list = [System.Collections.Generic.List[object]]::new()
    if ($doc.PSObject.Properties['diskTypeChanges']) { foreach ($c in @($doc.diskTypeChanges)) { if ($c) { $list.Add($c) } } }
    $list.Add([pscustomobject]@{ diskId = $DiskId; from = $From; to = $To; by = $By; utc = (Get-Date).ToUniversalTime().ToString('o') })
    $doc | Add-Member -NotePropertyName diskTypeChanges -NotePropertyValue @($list) -Force
    Write-VmfStateDoc -RunPath $RunPath -Document $doc
}

function Get-VmfDiskTypeWord {
    <#
    .SYNOPSIS
        DISK-TYPE-WORDS-1: Azure's name for a disk type (Standard_LRS is
        Standard HDD), for the lines the run page shows. A type with no name
        here stays as Azure wrote it.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowEmptyString()][AllowNull()][string]$SkuName)
    if ($SkuName -and $script:VmfDiskTypeWords.ContainsKey($SkuName)) { return $script:VmfDiskTypeWords[$SkuName] }
    [string]$SkuName
}

function Invoke-VmfDiskTypeUpgrade {
    <#
    .SYNOPSIS
        OLD-SKU-1C: change the planned disks to Premium SSD. The machine is
        stopped and already on its target size. Safe to run again: a disk that
        already has its new type is left, and not recorded twice.
    .DESCRIPTION
        A shared disk (maxShares above 1) is left as it is and said: other
        machines use it too, and its type is theirs as much as this one's.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Capture,
        [Parameter(Mandatory)]$PlanEntry
    )
    $changes = @(Get-VmfDiskTypeUpgradePlan -Capture $Capture -Upgrade (Get-VmfDiskUpgradeValue -PlanEntry $PlanEntry))
    $done = [System.Collections.Generic.List[string]]::new()
    foreach ($c in $changes) {
        $live = Invoke-VmfAzOperation -Name 'diskTypeRead' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfManagedDiskSku -DiskId $c.diskId
        }
        if ([int]$live.MaxShares -gt 1) {
            Write-VmfStepLine -RunPath $Context.RunPath -Step 'diskType' -Outcome warn -VmId $Context.VmId `
                -Detail "The disk '$($c.name)' keeps the type $(Get-VmfDiskTypeWord $live.SkuName). It is a shared disk (maxShares $($live.MaxShares)), and other machines use it."
            continue
        }
        if ([string]$live.SkuName -eq $c.to) { continue }
        $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
        $last = if ($doc.PSObject.Properties['diskTypeChanges']) { @(@($doc.diskTypeChanges) | Where-Object { [string]$_.diskId -eq $c.diskId }) | Select-Object -Last 1 } else { $null }
        if (-not ($last -and [string]$last.by -eq 'move' -and [string]$last.to -eq $c.to)) {
            Add-VmfDiskTypeChangeRecord -RunPath $Context.RunPath -VmId $Context.VmId -DiskId $c.diskId -From ([string]$live.SkuName) -To $c.to -By 'move'
        }
        # DISK-TYPE-WORDS-1: the line names the type it sets - the run page
        # said "Premium SSD" for every change, also one to Standard SSD.
        Invoke-VmfAzOperation -Name 'diskType' -RunPath $Context.RunPath -VmId $Context.VmId -EventData @{ skuName = $c.to } -Operation {
            Set-VmfManagedDiskSku -DiskId $c.diskId -SkuName $c.to
        } | Out-Null
        $done.Add("'$($c.name)' $(Get-VmfDiskTypeWord $live.SkuName) to $(Get-VmfDiskTypeWord $c.to)")
    }
    if ($done.Count) {
        Write-VmfStepLine -RunPath $Context.RunPath -Step 'diskType' -Outcome ok -VmId $Context.VmId `
            -Detail "The disk types are changed: $($done -join ', ')."
    }
}

function Restore-VmfCapturedDiskTypes {
    <#
    .SYNOPSIS
        OLD-SKU-1C: put the recorded disk type back on disks a put-back keeps
        in use - the disks it did not make again from a copy. Only a disk this
        move changed is touched, and only when it does not already have its
        type back. Throws only when the lease is lost; a type Azure will not
        set back is said and counted, and the caller decides what that means
        (Assert-VmfSizeTakesKeptDisks).
    .OUTPUTS
        The number of disks whose type did not go back - every type, so the
        put-back can say each one. KeptTypes says which type each one kept.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter()][string[]]$DiskIds = @(),
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        # RESTORE-ALL-1: disk ID -> the type it goes back to when no move
        # record names the disk (a disk a rollback or a restore made).
        [Parameter()][hashtable]$TypeBack = @{},
        # HDD-OS-1: filled with the type each disk KEPT when it did not go
        # back ('' when not known), for Assert-VmfSizeTakesKeptDisks - a size
        # refuses a Premium SSD disk, never a Standard SSD one.
        [Parameter()][AllowNull()][System.Collections.Generic.List[string]]$KeptTypes,
        # ROLLBACK-CAPACITY-1 review: filled with the name of each disk whose
        # type this call set back, for the stop that lists what went back.
        [Parameter()][AllowNull()][System.Collections.Generic.List[string]]$SetBack
    )
    $doc = Read-VmfStateDoc -RunPath $RunPath -VmId $VmId
    if (-not $doc) { return 0 }
    $records = if ($doc.PSObject.Properties['diskTypeChanges']) { @($doc.diskTypeChanges) } else { @() }
    if (-not $records.Count -and -not $TypeBack.Count) { return 0 }
    $notBack = 0
    foreach ($id in @($DiskIds | Where-Object { $_ } | Select-Object -Unique)) {
        # The type before the move is the latest MOVE record's from. The last
        # record of any kind is not enough: a set-back that failed is recorded
        # before it is tried, and must be tried again by the next put-back.
        $last = @($records | Where-Object { [string]$_.diskId -eq $id -and [string]$_.by -eq 'move' }) | Select-Object -Last 1
        if (-not $last -and $TypeBack.ContainsKey($id)) { $last = [pscustomobject]@{ from = [string]$TypeBack[$id]; to = '' } }
        if (-not $last) { continue }
        $name = ($id -split '/')[-1]
        try {
            $live = Invoke-VmfAzOperation -Name "$($Kind):diskTypeRead" -RunPath $RunPath -VmId $VmId -Operation { Get-VmfManagedDiskSku -DiskId $id }
            if ([string]$live.SkuName -eq [string]$last.from) { continue }
            if (-not [string]$last.to) { $last.to = [string]$live.SkuName }
            Add-VmfDiskTypeChangeRecord -RunPath $RunPath -VmId $VmId -DiskId $id -From ([string]$live.SkuName) -To ([string]$last.from) -By $Kind
            Invoke-VmfAzOperation -Name "$($Kind):diskType" -RunPath $RunPath -VmId $VmId -EventData @{ skuName = [string]$last.from } -Operation {
                Set-VmfManagedDiskSku -DiskId $id -SkuName ([string]$last.from)
            } | Out-Null
            Write-VmfStepLine -RunPath $RunPath -Step $Kind -Outcome info -VmId $VmId -Detail "The disk '$name' has its type $(Get-VmfDiskTypeWord $last.from) again."
            if ($null -ne $SetBack) { $SetBack.Add($name) }
        }
        catch {
            # Lease fencing: another worker owns the machine now.
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $notBack++
            if ($null -ne $KeptTypes) { $KeptTypes.Add([string]$last.to) }
            # RESTORE-WARN-ENDS-1: info in a person's restore, where the run
            # page reads a 'restore' warn as the end of it.
            Write-VmfStepLine -RunPath $RunPath -Step $Kind -Outcome $(if ($Kind -eq 'restore') { 'info' } else { 'warn' }) -VmId $VmId `
                -Detail "The disk '$name' keeps the type $(Get-VmfDiskTypeWord $last.to). Azure did not set $(Get-VmfDiskTypeWord $last.from) back: $($_.Exception.Message)"
        }
    }
    $notBack
}

function Test-VmfDiskPremiumCapable {
    <#
    .SYNOPSIS
        OLD-SKU-1C: does this size take Premium SSD disks? $true, $false, or
        $null when the catalog does not say - which is never read as a yes.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$SkuEntry)
    if (-not $SkuEntry) { return $null }
    $cap = @($SkuEntry.Capabilities) | Where-Object { $_.Name -eq 'PremiumIO' } | Select-Object -First 1
    if (-not $cap) { return $null }
    [string]$cap.Value -eq 'True'
}

function Test-VmfDiskUpgradeReady {
    <#
    .SYNOPSIS
        OLD-SKU-1C, at PRECHECK: stop before the machine is touched when the
        target size does not take Premium SSD, or when a disk had two type
        changes in the last 24 hours (Azure's limit). HDD-OS-1: a change to
        Standard SSD asks only the second: every size takes Standard SSD.
    .OUTPUTS
        $null to go on, or the NEEDS_DECISION result.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$PlanEntry,
        [Parameter(Mandatory)]$Capture
    )
    $upgrade = Get-VmfDiskUpgradeValue -PlanEntry $PlanEntry
    $changes = @(Get-VmfDiskTypeUpgradePlan -Capture $Capture -Upgrade $upgrade)
    if (-not $changes.Count) { return $null }
    # HDD-OS-1: Standard SSD needs no Premium SSD size - every size takes it -
    # so only a move to Premium SSD asks the size.
    if ($upgrade -in @('os', 'all')) {
        $size = [string]$PlanEntry.target.size
        $region = if ([string]$Capture.location) { [string]$Capture.location } else { [string]$PlanEntry.assessment.location }
        # ID-ADDRESS-1 part 3: read as the machine's own subscription.
        $vmSub = Get-VmfSubscriptionId -ResourceId $Context.VmId
        $skuEntry = Invoke-VmfAzOperation -Name 'skuCatalog' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            @(Get-VmfSkuCatalog -Location $region -SubscriptionId $vmSub) | Where-Object { $_.Name -eq $size } | Select-Object -First 1
        }
        $premium = Test-VmfDiskPremiumCapable -SkuEntry $skuEntry
        if ($premium -ne $true) {
            return @{
                Next = 'NEEDS_DECISION'; Reason = 'premiumDisksNotSupported'
                Detail = $(if ($null -eq $premium) { "Azure does not say whether the size $size takes Premium SSD disks." }
                           else { "The size $size does not take Premium SSD disks." })
            }
        }
    }
    $doc = Read-VmfStateDoc -RunPath $Context.RunPath -VmId $Context.VmId
    $wait = Get-VmfDiskTypeChangeRefusal -Doc $doc -DiskIds @($changes | ForEach-Object { $_.diskId })
    if ($wait) {
        $name = (@($changes | Where-Object { $_.diskId -eq $wait.disk }) | Select-Object -First 1).name
        return @{
            Next = 'NEEDS_DECISION'; Reason = 'diskTypeChangeLimit'
            Detail = "Azure allows two type changes for each disk in 24 hours. A move needs both of them: its own change, and the change back if the move fails. The disk '$name' had a type change in the last 24 hours. Select Try this machine again after $($wait.retryAfterUtc.ToString('yyyy-MM-dd HH:mm')) UTC."
        }
    }
    $null
}

function Get-VmfDisksKeptInUse {
    <#
    .SYNOPSIS
        OLD-SKU-1C: the captured disks a put-back leaves on the machine - not
        made again from a copy. Pure. With no pristine copy nothing is made
        again; otherwise the data disks on the LUNs it kept.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)]$Capture,
        [Parameter(Mandatory)][bool]$Restored,
        [Parameter()][int[]]$KeptLuns = @()
    )
    $data = @($Capture.dataDisks | Where-Object { $_ })
    $ids = if (-not $Restored) {
        @([string]$Capture.osDisk.managedDiskId) + @($data | ForEach-Object { [string]$_.managedDiskId })
    }
    else {
        @($data | Where-Object { [int]$_.lun -in $KeptLuns } | ForEach-Object { [string]$_.managedDiskId })
    }
    @($ids | Where-Object { $_ })
}

function Assert-VmfSizeTakesKeptDisks {
    <#
    .SYNOPSIS
        OLD-SKU-1C: a put-back that could not set a disk's type back may not
        go on to a size that takes no Premium SSD - Azure refuses the machine
        on it. Say so by name, with what to do, before the step Azure would
        refuse. A size that takes Premium SSD (or no disk left on it) passes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][int]$NotBack,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter(Mandatory)][string]$Then,
        # HDD-OS-1: the type each disk kept (Restore-VmfCapturedDiskTypes).
        # When every one is known and none is Premium SSD - a Standard SSD OS
        # disk - every size takes them, and the size is not asked. Not given,
        # or a type not known: the size is asked, as before.
        [Parameter()][AllowNull()][System.Collections.Generic.List[string]]$KeptTypes
    )
    if ($NotBack -le 0) { return }
    if ($null -ne $KeptTypes -and $KeptTypes.Count -ge $NotBack -and
        -not @($KeptTypes | Where-Object { -not $_ -or $_ -in @($script:VmfPremiumDiskSkuFor.Values) }).Count) { return }
    $vmSub = Get-VmfSubscriptionId -ResourceId $VmId
    $entry = Invoke-VmfAzOperation -Name "$($Kind):skuCatalog" -RunPath $RunPath -VmId $VmId -Operation {
        @(Get-VmfSkuCatalog -Location $Location -SubscriptionId $vmSub) | Where-Object { $_.Name -eq $Size } | Select-Object -First 1
    }
    if ((Test-VmfDiskPremiumCapable -SkuEntry $entry) -eq $true) { return }
    throw "$NotBack $(if ($NotBack -eq 1) { 'disk of this machine keeps' } else { 'disks of this machine keep' }) Premium SSD, named above, and the size $Size takes no Premium SSD, so Azure refuses the machine on it. $Then"
}

function Restore-VmfDiskTypesForSize {
    <#
    .SYNOPSIS
        OLD-SKU-1C: set the disk types back, then stop by name if a disk that
        kept Premium SSD would block the size the machine goes back to. One
        call for each put-back, before its size step.
    .OUTPUTS
        The number of disks whose type did not go back.
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)][ValidateSet('rollback', 'restore')][string]$Kind,
        [Parameter()][string[]]$DiskIds = @(),
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][string]$Location,
        [Parameter()][string]$Then,
        [Parameter()][hashtable]$TypeBack = @{}
    )
    if (-not $Then) {
        $Then = @{ restore = 'Set each disk back to its type, then restore the machine again.'
            rollback = 'Set each disk back to its type, then use Restore this machine.' }[$Kind]
    }
    $kept = [System.Collections.Generic.List[string]]::new()
    $notBack = Restore-VmfCapturedDiskTypes -RunPath $RunPath -VmId $VmId -DiskIds $DiskIds -Kind $Kind -TypeBack $TypeBack -KeptTypes $kept
    Assert-VmfSizeTakesKeptDisks -RunPath $RunPath -VmId $VmId -Size $Size -Location $Location -NotBack $notBack -Kind $Kind -Then $Then -KeptTypes $kept
    $notBack
}

function Restore-VmfForOriginalSize {
    <#
    .SYNOPSIS
        Put back, BEFORE the original size, what that size refuses: disk types
        it cannot take (OLD-SKU-1C) and accelerated networking when it cannot
        carry it (OLD-FAM-1: B1s to B8ms, F1). One call for an operator's
        restore from the first copy.
    .OUTPUTS
        @{ TypesNotBack; AnDone } - AnDone says accelerated networking was
        already put back here, so the caller does not do it again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunPath,
        [Parameter(Mandatory)][string]$VmId,
        [Parameter(Mandatory)]$Doc,
        [Parameter(Mandatory)][string]$Size,
        [Parameter(Mandatory)][string]$Location,
        # RESTORE-ALL-1: the disks in use NOW, and each one's captured type for
        # a disk no move record names (a rollback or a restore made it).
        # Without them: the captured disks, as before.
        [Parameter()][string[]]$DiskIds,
        [Parameter()][hashtable]$TypeBack = @{}
    )
    if (-not $PSBoundParameters.ContainsKey('DiskIds')) { $DiskIds = Get-VmfDisksKeptInUse -Capture $Doc.captured.vmConfig -Restored $false }
    $types = Restore-VmfDiskTypesForSize -RunPath $RunPath -VmId $VmId -Kind 'restore' -Size $Size -Location $Location `
        -DiskIds $DiskIds -TypeBack $TypeBack
    # ROLLBACK-RETRY-CAPTURE-1: the size and the interfaces as the FIRST
    # capture found them - the size this restore returns the machine to.
    $anDone = (Get-VmfSourceAcceleratedNetworking -Doc $Doc -PutBack) -eq $false
    if ($anDone) { $null = Restore-VmfCapturedAcceleratedNetworking -RunPath $RunPath -VmId $VmId -Nics (Get-VmfPutBackCapture -Doc $Doc).nics -Kind 'restore' }
    @{ TypesNotBack = $types; AnDone = $anDone }
}
