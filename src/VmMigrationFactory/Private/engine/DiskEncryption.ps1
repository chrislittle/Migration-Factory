# SAFETY-CMK-1: a disk made from a safety copy keeps the key of the disk it
# replaces.
#
# Rule since 2026-10-10: a machine must always go fully back to its safety copy.
# Until this item no disk the product made from a copy - a rollback, a restore,
# a rebuild - named a disk encryption set or an encryption type, for any disk
# type. A customer who chose their own key for a disk could get one back that
# a platform key protects, or a refusal inside the stopped window, and what
# Azure does is not documented: Microsoft's sample says only that a disk made
# from a snapshot with no set "creates a managed disk with platform-managed
# keys", and gives a second script, with the set named, for customer-managed
# keys. So the product never leaves it to Azure:
#   - PRECHECK reads each disk by its id and records encryption.type and
#     encryption.diskEncryptionSetId on the capture (vm-state v21). A disk
#     Azure did not answer for, or answered for in a way the product does not
#     know, is refused untouched: unknown is never "platform key";
#   - PRECHECK asks for the permission Azure checks on each set (the linked
#     scope, as NIC-JOIN-1 does for a subnet);
#   - every safety copy asks for its disk's own set - Microsoft: "A disk and
#     all of its associated incremental snapshots must have the same disk
#     encryption set" - and is compared with it;
#   - every disk made from a copy names the recorded type and set, is read back
#     by its id and compared, and one that differs never goes on the machine.
# Double encryption (EncryptionAtRestWithPlatformAndCustomerKeys) goes the same
# way: its set is a set of that type, and both are named.

# Each encryption type Azure documents for a managed disk, and whether it
# takes a disk encryption set - the three values of Azure's EncryptionType. A
# value Azure adds later is one the product does not know, and is refused.
# A confidential machine's disk encryption is not one of these: it is in the
# disk's securityProfile (secureVMDiskEncryptionSetId), and the scan refuses
# confidential machines before PRECHECK (confidential-vm-requires-manual).
$script:VmfDiskEncryptionTypes = [ordered]@{
    EncryptionAtRestWithPlatformKey             = $false
    EncryptionAtRestWithCustomerKey             = $true
    EncryptionAtRestWithPlatformAndCustomerKeys = $true
}

function Format-VmfDiskEncryption {
    # One encryption, as a person reads it in a stop or the log.
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Type, [Parameter()][AllowNull()][AllowEmptyString()][string]$SetId)
    if (-not $Type) { return 'no encryption type' }
    if ($SetId) { "$Type with the disk encryption set '$SetId'" } else { "$Type with no disk encryption set" }
}

function Get-VmfEncryptionDifference {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: how the encryption Azure returned for a disk or a copy
        differs from the one on record - or $null when it is the same. Pure.
    .DESCRIPTION
        The type is compared as text; the set as a resource id, which Azure
        compares without regard to case. A type Azure did not return is a
        difference: never taken as "platform key".
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string]$WantType,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$WantSetId,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$GotType,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$GotSetId
    )
    $sameType = [string]$GotType -and [string]::Equals([string]$GotType, $WantType, [System.StringComparison]::OrdinalIgnoreCase)
    $sameSet = [string]::Equals([string]$GotSetId, [string]$WantSetId, [System.StringComparison]::OrdinalIgnoreCase)
    if ($sameType -and $sameSet) { return $null }
    "its encryption is $(Format-VmfDiskEncryption -Type $GotType -SetId $GotSetId), not $(Format-VmfDiskEncryption -Type $WantType -SetId $WantSetId)"
}

function Get-VmfDiskEncryptionProblem {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: why a reading of a disk's encryption cannot be given back
        exactly - or $null when it can. Pure. Each why follows the disk's name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Type,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SetId
    )
    if (-not $Type) { return 'Azure returned no encryption type for it' }
    if (-not $script:VmfDiskEncryptionTypes.Contains($Type)) { return "its encryption type is $Type, which the product does not know" }
    $takesSet = [bool]$script:VmfDiskEncryptionTypes[$Type]
    if ($takesSet -and -not $SetId) { return "its encryption type is $Type, and Azure returned no disk encryption set for it" }
    if (-not $takesSet -and $SetId) { return "its encryption type is $Type, and Azure also returned the disk encryption set '$SetId'" }
    $null
}

function Get-VmfDiskEncryptionRecord {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: the encryption PRECHECK recorded on one disk of a
        capture, or $null when none is on record. Pure.
    .DESCRIPTION
        PRECHECK records it on every disk of the capture, or stops the machine
        untouched (Add-VmfDiskEncryptionFacts), so every capture of this
        version holds it. $null is never "as before": a disk with no record is
        not made from a copy (Get-VmfEncryptionNotOnRecordWords).
    .OUTPUTS
        @{ type; diskEncryptionSetId (or $null) }, or $null.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()]$Disk)
    $type = [string](Get-VmfRecordField -Object $Disk -Name 'encryptionType')
    if (-not $type) { return $null }
    $set = [string](Get-VmfRecordField -Object $Disk -Name 'diskEncryptionSetId')
    [pscustomobject]@{ type = $type; diskEncryptionSetId = $(if ($set) { $set } else { $null }) }
}

function Get-VmfEncryptionArgs {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: the encryption parameters to splat into a copy or a disk
        made for this capture entry. Empty when none is on record. Pure.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Disk)
    $enc = Get-VmfDiskEncryptionRecord -Disk $Disk
    if (-not $enc) { return @{} }
    @{ EncryptionType = [string]$enc.type; DiskEncryptionSetId = [string]$enc.diskEncryptionSetId }
}

function Get-VmfEncryptionNotOnRecordWords {
    <#
    .SYNOPSIS
        OLD-VERSION-READERS-REMOVE-4: why a disk is not made from its copy
        when the encryption of the disk the copy was taken of is not on
        record. Pure.
    .DESCRIPTION
        Every capture of this version records each disk's encryption, so this
        is a record this version does not write. The product never makes such
        a disk with Azure's default key: it would differ from the disk it
        replaces, and nothing would say so.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)][string]$DiskName)
    "The encryption of the disk that the copy '$SnapshotId' was taken of is not on record, so the product did not make the disk '$DiskName'."
}

function Add-VmfDiskEncryptionFacts {
    <#
    .SYNOPSIS
        SAFETY-CMK-1, at PRECHECK: read every disk of the machine by its id,
        and record its encryption type and disk encryption set on its capture
        entry - the OS disk and each data disk. Changes -Capture in place.
    .DESCRIPTION
        Every disk the product makes from a copy is made with what is recorded
        here. A disk that cannot be given back exactly is refused untouched,
        with each disk and why (diskEncryptionNotKnown):
          - it has no managed disk id;
          - Azure did not answer the read;
          - Azure returned no type, a type the product does not know, a type
            that takes a set with no set, or a platform key with a set.
        ADE-DETECT-ANY-NAME-1: with -AdeStops (a move to NVMe, or the in-place
        upgrade (Preview)), the same read also answers Azure Disk Encryption
        on each disk (adeEnabled). A disk with it stops the machine
        (diskEncryptionPresent), before any other answer of this read: it is
        a definite yes. A disk whose setting has no value is unknown
        (diskEncryptionUnknown), never yes or no.
    .OUTPUTS
        $null, or the NEEDS_DECISION result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Capture, [switch]$AdeStops)
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $disks = [System.Collections.Generic.List[object]]::new()
    $adeFound = $false
    $adeUnknownSay = $null
    $os = & $f $Capture 'osDisk'
    if ($os) { $disks.Add([pscustomobject]@{ Entry = $os; Say = "the OS disk '$([string](& $f $os 'name'))'"; IsOs = $true }) }
    foreach ($dd in @(& $f $Capture 'dataDisks')) {
        if ($dd) { $disks.Add([pscustomobject]@{ Entry = $dd; Say = "the data disk '$([string](& $f $dd 'name'))' on LUN $(& $f $dd 'lun')" }) }
    }
    $problems = [System.Collections.Generic.List[string]]::new()
    $osPlanSay = $null
    foreach ($d in $disks) {
        $diskId = [string](& $f $d.Entry 'managedDiskId')
        if (-not $diskId) { $problems.Add("$($d.Say): it has no managed disk id"); continue }
        try {
            $facts = Invoke-VmfAzOperation -Name 'readDiskEncryption' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfManagedDiskFacts -DiskId $diskId
            }
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $problems.Add("$($d.Say): Azure did not answer the read ($($_.Exception.Message))")
            continue
        }
        # ADE-DETECT-ANY-NAME-1: Get-VmfManagedDiskFacts always returns
        # adeEnabled; $null in it is a setting with no value (unknown).
        if ($facts.PSObject.Properties['adeEnabled']) {
            if ($facts.adeEnabled -eq $true) { $adeFound = $true }
            elseif ($null -eq $facts.adeEnabled -and -not $adeUnknownSay) { $adeUnknownSay = $d.Say }
        }
        $type = [string]$facts.encryptionType
        $set = [string]$facts.diskEncryptionSetId
        $why = Get-VmfDiskEncryptionProblem -Type $type -SetId $set
        if ($why) { $problems.Add("$($d.Say): $why"); continue }
        $values = @{ encryptionType = $type; diskEncryptionSetId = $(if ($set) { $set } else { $null }) }
        # NO-PLAN-SCOPE-1: and, from the same read, the OS disk's Marketplace
        # purchase plan. A machine with one is outside the scope of this tool.
        # A read that fails refuses the machine above, so a plan is never
        # unknown past here.
        if ($d.PSObject.Properties['IsOs'] -and $d.IsOs) {
            $osPlan = Get-VmfPurchasePlanEvidence -Plan $(if ($facts.PSObject.Properties['purchasePlan']) { $facts.purchasePlan } else { $null })
            if ($osPlan) { $osPlanSay = "$($d.Say.Substring(0, 1).ToUpperInvariant())$($d.Say.Substring(1)) of this machine has a Marketplace purchase plan: $($osPlan.Words)." }
        }
        foreach ($k in $values.Keys) {
            if ($d.Entry -is [System.Collections.IDictionary]) { $d.Entry[$k] = $values[$k] }
            else { $d.Entry | Add-Member -NotePropertyName $k -NotePropertyValue $values[$k] -Force }
        }
    }
    if ($AdeStops -and $adeFound) { return Get-VmfAdeStop -Found $true }
    if ($AdeStops -and $adeUnknownSay) { return Get-VmfAdeStop -Found $null -UnknownSay $adeUnknownSay }
    if (-not $problems.Count) {
        if (-not $osPlanSay) { return $null }
        return @{ Next = 'NEEDS_DECISION'; Reason = 'purchasePlan'; MachineState = 'untouched'
                  Detail = "$osPlanSay A machine with a purchase plan is outside the scope of this tool. Nothing on the machine changed." }
    }
    @{ Next = 'NEEDS_DECISION'; Reason = 'diskEncryptionNotKnown'; MachineState = 'untouched'
       Detail = "The product could not read the encryption of each disk exactly, so it cannot make a disk from a safety copy with the same key: $($problems -join '; '). The product does not start a move it cannot roll back fully. Nothing on the machine changed." }
}

function Test-VmfDiskEncryptionSetPermissions {
    <#
    .SYNOPSIS
        SAFETY-CMK-1, at PRECHECK: can this identity use each disk encryption
        set the machine's disks have? Asked of the SET, which can be in
        another resource group - the NIC-JOIN-1 way (Get-VmfEffectivePermissions
        at the linked scope, Get-VmfMissingActions).
    .OUTPUTS
        $null when it can, or a machine with no set; otherwise the
        NEEDS_DECISION result naming each set and the action.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Capture,
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks - the
        # same check, with the words of the restore.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    $f = { param($o, $n) Get-VmfRecordField -Object $o -Name $n }
    $sets = [ordered]@{}
    foreach ($d in @(@(& $f $Capture 'osDisk') + @(& $f $Capture 'dataDisks'))) {
        $enc = Get-VmfDiskEncryptionRecord -Disk $d
        if ($enc -and $enc.diskEncryptionSetId -and -not $sets.Contains(([string]$enc.diskEncryptionSetId).ToLowerInvariant())) {
            $sets[([string]$enc.diskEncryptionSetId).ToLowerInvariant()] = [string]$enc.diskEncryptionSetId
        }
    }
    if (-not $sets.Count) { return $null }
    $missing = @(foreach ($setId in @($sets.Values)) {
            $perms = Invoke-VmfAzOperation -Name 'diskEncryptionSetPermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfEffectivePermissions -Scope $setId
            }
            foreach ($a in @(Get-VmfMissingActions -RequiredActions @($script:VmfDiskEncryptionSetAction) -Permissions $perms)) {
                [pscustomobject]@{ Scope = $setId; Action = $a }
            }
        })
    if (-not $missing.Count) { return $null }
    @{ Next = 'NEEDS_DECISION'; Reason = 'permissionMissingDiskEncryptionSet'; Detail = (Format-VmfDiskEncryptionSetMissingMessage -Missing $missing -For $For) }
}

function Confirm-VmfMadeDiskEncryption {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: read a disk the product made from a copy back by its id,
        and compare its encryption with the record.
    .DESCRIPTION
        Never the exit code as proof (CLAUDE.md: a policy with the modify
        effect reports success and puts its own setting back). A read that
        fails is a difference: the disk goes on the machine only when its key
        is known to match.
        With no encryption on record there is nothing to compare with, so the
        disk is refused (OLD-VERSION-READERS-REMOVE-4). Every maker refuses
        before it makes the disk; this is the last check.
    .OUTPUTS
        $null, or why the disk must not go on the machine (whole sentences,
        naming the disk).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$OpName,
        [Parameter(Mandatory)][string]$DiskId,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter()][AllowNull()]$Want
    )
    if (-not $Want) {
        return "The encryption of the disk that '$DiskName' replaces is not on record, so the product does not use '$DiskName'."
    }
    try {
        $got = Invoke-VmfAzOperation -Name "$($OpName):readBack" -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfManagedDiskFacts -DiskId $DiskId
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return "Azure made the disk '$DiskName', and the product could not read it back to compare its encryption with the record: $($_.Exception.Message)."
    }
    $diff = Get-VmfEncryptionDifference -WantType ([string]$Want.type) -WantSetId ([string]$Want.diskEncryptionSetId) `
        -GotType $(if ($got) { [string]$got.encryptionType } else { '' }) -GotSetId $(if ($got) { [string]$got.diskEncryptionSetId } else { '' })
    if ($diff) { return "Azure made the disk '$DiskName', but $diff." }
    $null
}

function New-VmfOsDiskFromCopy {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: make an OS disk from its safety copy for a rollback, a
        restore or a rebuild - with the encryption on record - then read it
        back and compare. Every OS disk the product makes from a copy comes
        through here.
    .DESCRIPTION
        -OnMade runs with the new disk's id the moment Azure made it, before
        the read-back, so a caller that keeps a record of the disks it made
        records this one too - a disk that differs bills like any other.
        Throws when the new disk differs from the record, or cannot be read
        back: it is never put on the machine, and the message names it.
    .OUTPUTS
        The new disk's id.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$OpName,
        [Parameter(Mandatory)][string]$ResourceGroupName,
        [Parameter(Mandatory)][string]$DiskName,
        [Parameter(Mandatory)][string]$SnapshotId,
        [Parameter(Mandatory)][string]$Location,
        # As the caller has it; New-VmfDiskFromSnapshot takes it as before.
        [Parameter()][AllowNull()][AllowEmptyString()][string]$SkuName,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$Zone,
        # The capture entry of the disk the copy was taken of.
        [Parameter()][AllowNull()]$Disk,
        [Parameter()][scriptblock]$OnMade
    )
    # OLD-VERSION-READERS-REMOVE-4: no disk without its key on record.
    if (-not (Get-VmfDiskEncryptionRecord -Disk $Disk)) { throw (Get-VmfEncryptionNotOnRecordWords -SnapshotId $SnapshotId -DiskName $DiskName) }
    $encArgs = Get-VmfEncryptionArgs -Disk $Disk
    $madeId = Invoke-VmfAzOperation -Name $OpName -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
        New-VmfDiskFromSnapshot -ResourceGroupName $ResourceGroupName -DiskName $DiskName -SnapshotId $SnapshotId `
            -Location $Location -SkuName $SkuName -Zone $Zone @encArgs
    }
    if ($OnMade) { & $OnMade ([string]$madeId) }
    # MADE-DISK-RECORD-1: every disk Restore this machine makes is on its
    # record the moment Azure made it - its Azure calls are named 'restore:'.
    if ($OpName -like 'restore:*') { Add-VmfRestoreDiskRecord -Context $Context -DiskId ([string]$madeId) -DiskName $DiskName -Lun $null }
    $why = Confirm-VmfMadeDiskEncryption -Context $Context -OpName $OpName -DiskId ([string]$madeId) -DiskName $DiskName `
        -Want (Get-VmfDiskEncryptionRecord -Disk $Disk)
    if ($why) { throw "$why The product did not put it on the machine, and the new disk is kept." }
    [string]$madeId
}

function Add-VmfDiskEncryptionRowFacts {
    # SAFETY-CMK-1: the encryption a data disk made from a copy is made with,
    # and compared against - from the capture entry of the disk the copy was
    # taken of. $null: not on record.
    param([Parameter(Mandatory)]$Row, [Parameter()][AllowNull()]$Facts)
    $Row | Add-Member -NotePropertyName encryption -NotePropertyValue (Get-VmfDiskEncryptionRecord -Disk $Facts) -Force
}

function Get-VmfAdeStop {
    <#
    .SYNOPSIS
        ADE-DETECT-ANY-NAME-1: the stop for Azure Disk Encryption at Checking,
        from the extension or a disk. -Found $true is diskEncryptionPresent;
        $null is diskEncryptionUnknown, naming the disk whose setting had no
        value. Pure. The machine is untouched: Checking changes nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter()][AllowNull()]$Found, [Parameter()][string]$UnknownSay)
    if ($Found -eq $true) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'diskEncryptionPresent'; MachineState = 'untouched'; Detail = 'Azure Disk Encryption is enabled on this machine.' }
    }
    @{ Next = 'NEEDS_DECISION'; Reason = 'diskEncryptionUnknown'; MachineState = 'untouched'
       Detail = "The Azure Disk Encryption setting of $UnknownSay has no value. Azure Disk Encryption is not available on a v6 or v7 size, and the product does not move an encrypted machine by the in-place upgrade (Preview). Rather than assume it is not encrypted, this machine is waiting for a person to check." }
}