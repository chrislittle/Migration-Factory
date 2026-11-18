# RESTORE-PERM-CHECK-1: before Restore this machine makes a disk or stops the
# machine, it asks for every permission Azure checks on a resource its writes
# link to - with the SAME checks a move asks at Checking.
#
# Azure checks a write on every resource it links to (CLAUDE.md, NIC-JOIN-1 and
# ROLE-SNAP-1): LinkedAuthorizationFailed. Each update of the machine in a
# restore (the disk swap, and from the first copy the size and the reservation
# group) sends its network interfaces, its user-assigned identities and its
# capacity reservation group; each disk made from a copy links to the copy and
# to the disk encryption set on record; and the first copy sets accelerated
# networking back on an interface, which links to its subnet and the rest.
# MEASURED 2026-11-01 for the identity: refused at the first write, after the
# stop. A move asks all of it at Checking. A restore asked none, so a grant
# removed after the move, or an identity added to the machine since, refused
# the restore with the machine stopped.
#
# What is asked, and on what:
#   - first, the machine itself (RESTORE-PERM-MACHINE-1): the actions the map
#     marks restore, the PERM-3 way;
#   - each network interface (NIC-JOIN-SCOPE-1) and each user-assigned identity
#     (UAMI-ASSIGN-1) of the machine as it is NOW - what each update sends;
#   - the capacity reservation groups Checking asks (ROLLBACK-CRG-1);
#   - each disk encryption set (SAFETY-CMK-1) and each safety copy (ROLE-SNAP-1)
#     of a disk the restore makes from a copy - none when it makes no disk;
#   - from the first copy, the links of each interface whose accelerated
#     networking it sets back (NIC-JOIN-1).
# A permission that cannot be read stops the restore too: unknown is never
# allowed. A resume does not ask again (the retirement and the preview checks
# of the restore are the same): it finishes the restore it started.

function Get-VmfRestoreNicWrites {
    <#
    .SYNOPSIS
        RESTORE-PERM-CHECK-1: the network interfaces a restore from the first
        copy writes. Pure.
    .DESCRIPTION
        Restore-VmfCapturedAcceleratedNetworking sets accelerated networking
        back on each interface the put-back capture records a value for, and
        Set-VmfNicAcceleratedNetworking writes only an interface whose setting
        differs. So: each recorded interface whose setting now differs, is not
        known, or is not on the machine now - unknown is not "as recorded".
    .OUTPUTS
        The resource ids, one per interface.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][AllowNull()]$PutBackNics, [Parameter()][AllowNull()]$LiveNics)
    $now = @{}
    foreach ($n in @($LiveNics | Where-Object { $null -ne $_ })) {
        $id = [string](Get-VmfRecordField -Object $n -Name 'id')
        if ($id) { $now[$id.ToLowerInvariant()] = $n }
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    @(foreach ($n in @($PutBackNics | Where-Object { $null -ne $_ })) {
            $id = [string](Get-VmfRecordField -Object $n -Name 'id')
            $want = Get-VmfRecordField -Object $n -Name 'acceleratedNetworking'
            if (-not $id -or $null -eq $want -or -not $seen.Add($id)) { continue }
            $live = $now[$id.ToLowerInvariant()]
            $has = if ($live) { Get-VmfRecordField -Object $live -Name 'acceleratedNetworking' } else { $null }
            if ($null -eq $has -or [bool]$has -ne [bool]$want) { $id }
        })
}

function Get-VmfRestorePermissionStop {
    <#
    .SYNOPSIS
        RESTORE-PERM-CHECK-1: may the product's managed identity do every
        write of this restore, on every resource the writes link to? Asked
        before the restore makes a disk or stops the machine.
    .PARAMETER Context
        RunPath, VmId, Rg and VmName of the machine.
    .PARAMETER From
        The copy the restore goes back to. Only the first copy sets
        accelerated networking back.
    .PARAMETER PutBackCapture
        Get-VmfPutBackCapture: what the first copy puts back.
    .PARAMETER CopyIds
        Each safety copy the restore makes a disk from. Empty when it makes
        none (it uses the disks made before the move).
    .PARAMETER CopyDisks
        The capture entry of each disk it makes from a copy: the encryption
        on record, which names any disk encryption set.
    .OUTPUTS
        $null when every permission is held; otherwise the words of the stop:
        the resource, the action, and what to grant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][ValidateSet('pristine', 'prepared')][string]$From,
        [Parameter()][AllowNull()]$PutBackCapture,
        [Parameter()][AllowEmptyCollection()][string[]]$CopyIds = @(),
        [Parameter()][AllowEmptyCollection()][object[]]$CopyDisks = @()
    )
    $stopWords = Get-VmfPermissionStopWords -For 'restore'
    $said = { param($e) ([string]$e.Exception.Message).Trim().TrimEnd('.') }
    # RESTORE-PERM-MACHINE-1: first the machine itself, as Checking asks PERM-3
    # first - Get-VmfEffectivePermissions at the machine's own scope, which
    # folds in every grant inherited from above it. Only the actions the map
    # marks restore: a restore is never refused for an action only a move
    # needs, such as the read of the preview feature.
    try {
        $perms = Invoke-VmfAzOperation -Name 'restore:machinePermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfEffectivePermissions -Scope $Context.VmId
        }
        $missingHere = @(Get-VmfMissingActions -RequiredActions (Get-VmfRequiredActions -Restore) -Permissions $perms)
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return "The product could not read the permissions of its managed identity: $(& $said $_). $stopWords"
    }
    if ($missingHere.Count) { return (Format-VmfMissingActionsMessage -Missing $missingHere -Scope $Context.VmId -For 'restore') }
    try {
        $live = Invoke-VmfAzOperation -Name 'restore:readMachine' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
            Get-VmfVmCapture -Vm (Get-VmfVmConfig -ResourceGroupName $Context.Rg -Name $Context.VmName)
        }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return "The product could not read the machine: $(& $said $_). The product cannot check the permissions that the restore needs. $stopWords"
    }
    try {
        # In the order Checking asks them; the first stop is said.
        $stop = Test-VmfNicJoinPermissions -Context $Context -CapturedNics (Get-VmfRecordField -Object $live -Name 'nics') -For 'restore'
        if ($stop) { return [string]$stop.Detail }
        if ($From -eq 'pristine' -and [string](Get-VmfRecordField -Object $PutBackCapture -Name 'size')) {
            $writes = @(Get-VmfRestoreNicWrites -PutBackNics (Get-VmfRecordField -Object $PutBackCapture -Name 'nics') -LiveNics (Get-VmfRecordField -Object $live -Name 'nics'))
            $stop = Test-VmfNicLinkedPermissions -Context $Context -WriteNicIds $writes
            if ($stop) { return [string]$stop.Detail }
        }
        if (@($CopyDisks | Where-Object { $null -ne $_ }).Count) {
            $stop = Test-VmfDiskEncryptionSetPermissions -Context $Context -Capture ([pscustomobject]@{ osDisk = $null; dataDisks = @($CopyDisks | Where-Object { $null -ne $_ }) }) -For 'restore'
            if ($stop) { return [string]$stop.Detail }
        }
        $stop = Test-VmfReservationJoinPermissions -Context $Context -For 'restore'
        if ($stop) { return [string]$stop.Detail }
        $stop = Test-VmfIdentityAssignPermissions -Context $Context -Capture $live -For 'restore'
        if ($stop) { return [string]$stop.Detail }
        # ROLE-SNAP-1: each copy a disk is made from, asked at the copy - the
        # NIC-JOIN-1 way (Get-VmfEffectivePermissions at the linked scope).
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $missing = @(foreach ($copyId in @($CopyIds | Where-Object { $_ })) {
                if (-not $seen.Add([string]$copyId)) { continue }
                $perms = Invoke-VmfAzOperation -Name 'restore:copyPermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                    Get-VmfEffectivePermissions -Scope $copyId
                }
                foreach ($a in @(Get-VmfMissingActions -RequiredActions @($script:VmfSnapshotReadAction) -Permissions $perms)) {
                    [pscustomobject]@{ Scope = [string]$copyId; Action = $a }
                }
            })
        if ($missing.Count) { return (Format-VmfSnapshotReadMissingMessage -Missing $missing) }
    }
    catch {
        if ($_.Exception.Message -match 'abandon this VM') { throw }
        return "The product could not read the permissions of its managed identity: $(& $said $_). $stopWords"
    }
    $null
}
