# NIC-JOIN-SCOPE-1: may this identity join each network interface of the
# machine? Asked at PRECHECK, at each interface's OWN scope, before anything is
# touched - for every move, whatever happens to accelerated networking.
#
# A resize with Update-AzVM sends the whole definition of the machine, its
# network interfaces included. Microsoft names the action "Attach a network
# interface to a virtual machine" (the network interface page, Permissions),
# and an interface can be in another resource group than its machine. Microsoft
# Q&A 596739 shows a PowerShell resize refused with LinkedAuthorizationFailed
# for this action on the interface. This product MEASURED the same class for
# the user-assigned identity (UAMI-ASSIGN-1): the resize was refused while the
# machine was stopped, and so was the rollback - the same Update-AzVM call - so
# the machine stayed stopped.
#
# The machine-scope check (PERM-3) reads the role at the machine. A grant there,
# or on the machine's resource group, does not reach an interface in another
# group, and a grant on the machine resource alone does not reach even the
# interface beside it: RBAC inheritance runs down from a scope. So every
# interface is asked about at its own scope.
#
# NOT MEASURED: whether Azure checks the join on an interface whose reference
# the resize does not change. TESTMATRIX-1 lists the measurement. The owner
# made the check 1.0 on 2026-11-07 regardless.
#
# The NIC-JOIN-1 way (Test-VmfNicLinkedPermissions): Get-VmfEffectivePermissions
# at the linked scope, Get-VmfMissingActions against the action. Unknown is its
# own answer, as UAMI-ASSIGN-1 decided: a read that fails, or an interface the
# capture holds with no id, stops the machine untouched - never read as allowed.

$script:VmfNicJoinAction = 'Microsoft.Network/networkInterfaces/join/action'

function Format-VmfNicJoinMissingMessage {
    <#
    .SYNOPSIS
        NIC-JOIN-SCOPE-1: the parking message for a network interface this
        identity may not join, naming each interface and its resource group,
        the action on each scope, and what to grant: the role on a scope that covers each interface.
    .PARAMETER Unread
        Interfaces whose permissions could not be read, each with Azure's
        answer - named too, so one fix covers both.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$Missing,
        [Parameter()][string[]]$Unread = @(),
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    # STOP-TEXT-SPECIFIC-1: leads with each interface by name and group.
    $lines = @($Missing | ForEach-Object { "$($_.Action) on $($_.Scope)" })
    $named = @($Missing | ForEach-Object {
            "'$(Get-VmfResourceNameFromId ([string]$_.Scope))' in the resource group '$(Get-VmfResourceGroupName -ResourceId ([string]$_.Scope))'"
        })
    $list = if ($named.Count -le 1) { $named -join '' } else { "$(($named[0..($named.Count - 2)]) -join ', ') and $($named[-1])" }
    $kind = if ($named.Count -eq 1) { 'network interface' } else { 'network interfaces' }
    # NIC-JOIN-SCOPE-1, 2026-11-07: say WHAT is needed, not where or
    # how - "just say grant the role to a scope that covers the interface.
    # customers can decide how they want to do that". The interface and its
    # resource group stay in the stop as facts.
    $also = if (@($Unread).Count) { " The product also could not read this permission on: $(@($Unread) -join '; ')." } else { '' }
    "The product's managed identity cannot join the $kind $list. " +
    "$(Get-VmfNicJoinWhyWords -For $For): " +
    ($lines -join '; ') + ".$also $(Get-VmfPermissionStopWords -For $For) " +
    "Grant the VMF Migration role on a scope that covers each network interface that this stop names. Then try again."
}

function Get-VmfNicJoinWhyWords {
    <#
    .SYNOPSIS
        RESTORE-PERM-CHECK-1: why each network interface is asked, for a move
        or for Restore this machine, up to the list of actions (no end mark).
        Pure.
    .PARAMETER Permission
        The words for the permission: 'this permission', or the action name.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move',
        [Parameter()][string]$Permission = 'this permission'
    )
    # STE100 rewrite 2026-11-15: one fact per sentence for the restore.
    if ($For -eq 'restore') { return "The restore updates the machine. Each update includes all network interfaces of the machine. Azure can check $Permission on each network interface" }
    "The resize of the machine, and its rollback, include each network interface of the machine, and Azure can check $Permission on each one"
}

function Test-VmfNicJoinPermissions {
    <#
    .SYNOPSIS
        NIC-JOIN-SCOPE-1, at PRECHECK: can this identity join each network
        interface of the machine? Asked of the INTERFACE, at its own scope.
    .PARAMETER CapturedNics
        The interfaces of the capture (Get-VmfVmCapture: id, primary, ...).
    .OUTPUTS
        $null when it can, or the capture holds no interface; otherwise the
        NEEDS_DECISION result, machine untouched:
        permissionMissingNetworkInterface naming each interface, its resource
        group and the action, or networkInterfaceJoinNotKnown when the answer
        could not be read.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter()][AllowNull()]$CapturedNics,
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks - the
        # same check, with the words of the restore.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $ids = [System.Collections.Generic.List[string]]::new()
    $noId = 0
    foreach ($nic in @($CapturedNics | Where-Object { $null -ne $_ })) {
        $nicId = ([string](Get-VmfRecordField -Object $nic -Name 'id')).Trim()
        if (-not $nicId) { $noId++; continue }
        if ($seen.Add($nicId)) { $ids.Add($nicId) }
    }
    $missing = [System.Collections.Generic.List[object]]::new()
    $unread = [System.Collections.Generic.List[string]]::new()
    if ($noId -eq 1) { $unread.Add('a network interface for which Azure returned no id') }
    elseif ($noId) { $unread.Add("$noId network interfaces for which Azure returned no id") }
    foreach ($nicNow in $ids) {
        try {
            $perms = Invoke-VmfAzOperation -Name 'nicJoinPermissions' -RunPath $Context.RunPath -VmId $Context.VmId -Operation {
                Get-VmfEffectivePermissions -Scope $nicNow
            }
        }
        catch {
            if ($_.Exception.Message -match 'abandon this VM') { throw }
            $unread.Add("$nicNow ($($_.Exception.Message))")
            continue
        }
        foreach ($a in @(Get-VmfMissingActions -RequiredActions @($script:VmfNicJoinAction) -Permissions $perms)) {
            $missing.Add([pscustomobject]@{ Scope = $nicNow; Action = $a })
        }
    }
    if ($missing.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'permissionMissingNetworkInterface'; MachineState = 'untouched'
                  Detail = (Format-VmfNicJoinMissingMessage -Missing @($missing) -Unread @($unread) -For $For) }
    }
    if ($unread.Count) {
        return @{ Next = 'NEEDS_DECISION'; Reason = 'networkInterfaceJoinNotKnown'; MachineState = 'untouched'
                  Detail = "$(Get-VmfNicJoinWhyWords -For $For -Permission $script:VmfNicJoinAction). The product could not read whether its managed identity has it: $($unread -join '; '). Nothing on the machine changed." }
    }
    $null
}
