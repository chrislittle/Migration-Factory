# PERM-3: can this identity actually do the job, BEFORE anything is touched.
#
# The PERM-1 drill found a missing permission part-way through a Path B rebuild.
# By then the machine's shell had been deleted - and because the rebuild and the
# roll-back need the SAME rights, the gap that broke the migration also broke the
# recovery meant to cover it. The disks survived, unattached, and the engine had
# no way to put the machine back.
#
# The fix is cheap: ask Azure which actions this identity holds at the machine's
# scope, compare against data/rbac-actions.json, and park before the first
# mutation. It turns the worst failure mode in the product into a refusal that costs
# nothing.
#
# Everything here is pure so it is testable without Azure (hard rule 5). The one
# ARM call lives in azureops.

function Get-VmfRequiredActions {
    <#
    .SYNOPSIS
        The distinct ARM actions a given role needs, from data/rbac-actions.json.
    .PARAMETER Role
        'assess' for a read-only scan; @('assess','execute') to migrate - an
        execution needs the read actions too.
    #>
    [CmdletBinding()]
    param(
        [Parameter()][string[]]$Role = @('assess', 'execute'),
        [Parameter()][string]$Path,
        # SAFETY-3: an operation marked "optional" in the map is one the product
        # can do without - the lock on a safety copy - and Contributor lacks
        # it. It is NOT required, so a migration is never refused for it; it
        # is listed with -Optional, so PRECHECK can say plainly what will not
        # happen. The custom execute role carries it either way.
        [Parameter()][switch]$Optional,
        # TEMP-DISK-PREVIEW-1: an operation the map marks requiredFor a kind of
        # move (preview) is required only when the move is of that kind. Without
        # -For it is left out, so an installation whose role predates it still
        # moves every other machine.
        [Parameter()][AllowEmptyCollection()][string[]]$For = @(),
        # RESTORE-PERM-MACHINE-1: only the operations the map marks restore -
        # what Restore this machine can call once it made a disk or stopped
        # the machine. Never an action that only a move or a scan needs.
        [Parameter()][switch]$Restore
    )
    $file = if ($Path) { $Path } else { Join-Path $script:VmfModuleRoot 'data' 'rbac-actions.json' }
    if (-not (Test-Path $file)) { throw "RBAC action map not found at '$file'." }
    $map = Get-Content $file -Raw | ConvertFrom-Json
    $wantOptional = [bool]$Optional
    $actions = foreach ($op in $map.operations) {
        $isOptional = [bool]($op.PSObject.Properties['optional'] -and $op.optional)
        $forKind = if ($op.PSObject.Properties['requiredFor']) { [string]$op.requiredFor } else { '' }
        if ($forKind -and $forKind -notin $For) { continue }
        if ($Restore -and -not ($op.PSObject.Properties['restore'] -and $op.restore -eq $true)) { continue }
        if ($op.role -in $Role -and $isOptional -eq $wantOptional) { $op.actions }
    }
    @($actions | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-VmfQuotaRequestActions {
    <#
    .SYNOPSIS
        QUOTA-PREVIEW-1: the actions Request an increase needs - the
        Microsoft.Quota actions data/rbac-actions.json gives the execute role.
    .DESCRIPTION
        Read from the map, never written here, so the check at plan time asks
        about exactly what the map says the request needs.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter()][string]$Path)
    $splat = @{ Role = @('execute') }
    if ($Path) { $splat.Path = $Path }
    @(Get-VmfRequiredActions @splat | Where-Object { $_ -like 'Microsoft.Quota/*' })
}

function Get-VmfQuotaRequestAccess {
    <#
    .SYNOPSIS
        QUOTA-PREVIEW-1: may this identity request a quota, from its effective
        permissions on the subscription? 'granted' or 'missing'.
    .DESCRIPTION
        Pure. The caller asks Azure (Get-VmfEffectivePermissions at the
        subscription) and records 'unknown' itself when that read fails - an
        empty answer is Azure saying "nothing here", which is missing.
        A role given on a resource group is not in the subscription's list:
        Azure RBAC scope inheritance is downward only.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()]$Permissions)
    $missing = @(Get-VmfMissingActions -RequiredActions @(Get-VmfQuotaRequestActions) -Permissions $Permissions)
    if ($missing.Count) { 'missing' } else { 'granted' }
}
function ConvertTo-VmfActionRegex {
    <#
    .SYNOPSIS
        An RBAC action pattern as a regex. '*' matches any run of characters,
        INCLUDING '/' - "Microsoft.Compute/*" really does cover
        "Microsoft.Compute/virtualMachines/write".
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Pattern)
    # A LITERAL string replace, not -replace. The escaped pattern is full of
    # backslashes, and a REGEX replacement of the escaped star is one dropped
    # backslash away from '\*' - 'zero or more backslashes' - which matches at
    # every position and turns every pattern into match-anything. That is
    # exactly what happened here, and it would have passed every action.
    # UAMI-ASSIGN-1 (review): a star between two slashes is NOT read as "no
    # segment" here. That made virtualMachines/*/write grant
    # virtualMachines/write - a false pass into the stopped window. The one
    # documented case where it must (Managed Identity Operator's
    # userAssignedIdentities/*/assign/action) is accepted for that one action
    # only, in Test-VmfIdentityAssignHeld.
    $escaped = [regex]::Escape($Pattern)
    '^' + $escaped.Replace('\*', '.*') + '$'
}

function Test-VmfActionGranted {
    <#
    .SYNOPSIS
        Is one action permitted by one permission entry?

        RBAC evaluates a permission as a whole: the action has to match one of
        its Actions AND must not match any of its NotActions. NotActions from a
        DIFFERENT role assignment do not subtract from this one, which is why
        this takes a single entry rather than two flat lists.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter()][string[]]$Actions = @(),
        [Parameter()][string[]]$NotActions = @()
    )
    $allowed = $false
    foreach ($p in @($Actions | Where-Object { $_ })) {
        if ($Action -match (ConvertTo-VmfActionRegex -Pattern $p)) { $allowed = $true; break }
    }
    if (-not $allowed) { return $false }
    foreach ($p in @($NotActions | Where-Object { $_ })) {
        if ($Action -match (ConvertTo-VmfActionRegex -Pattern $p)) { return $false }
    }
    $true
}

function Get-VmfMissingActions {
    <#
    .SYNOPSIS
        Which required actions this identity does NOT hold.
    .PARAMETER Permissions
        What Azure returned for the scope: objects with .actions / .notActions.
        An action is held if ANY ONE of them grants it.
    .OUTPUTS
        The missing actions, sorted. Empty means the identity can do the job.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RequiredActions,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()]$Permissions
    )
    $entries = @($Permissions | Where-Object { $_ })
    $missing = foreach ($required in @($RequiredActions | Where-Object { $_ })) {
        $held = $false
        foreach ($entry in $entries) {
            $acts = @(if ($entry.PSObject.Properties['actions']) { $entry.actions })
            $nots = @(if ($entry.PSObject.Properties['notActions']) { $entry.notActions })
            if (Test-VmfActionGranted -Action $required -Actions $acts -NotActions $nots) { $held = $true; break }
        }
        if (-not $held) { $required }
    }
    @($missing | Sort-Object -Unique)
}

function Format-VmfMissingActionsMessage {
    <#
    .SYNOPSIS
        The parking message. Names what is missing and what to do about it -
        an operator reading "insufficient permissions" cannot act on it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Missing,
        [Parameter()][string]$Scope,
        # RESTORE-PERM-MACHINE-1: 'restore' when Restore this machine asks.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    # STOP-TEXT-SPECIFIC-1: leads with what is missing, on which resource.
    $n = @($Missing).Count
    $what = if ($n -eq 1) { 'permission' } else { 'permissions' }
    $on = if ($Scope) { " on the machine '$(Get-VmfResourceNameFromId $Scope)' ($Scope)" } else { ' on this machine' }
    $lead = "The product's managed identity does not have $n $what$($on): $(@($Missing) -join ', '). "
    if ($For -eq 'restore') {
        $needs = if ($n -eq 1) { 'The restore needs this permission.' } else { 'The restore needs these permissions.' }
        return $lead + "$needs $(Get-VmfPermissionStopWords -For 'restore') " +
            'Grant the VMF Migration role on this machine, its resource group or its subscription. Then try again.'
    }
    $lead +
    # REBUILD-REMOVE-ROLE-1: no move deletes a machine now. A permission that
    # Azure refuses while the machine is stopped can also refuse its rollback,
    # which leaves it stopped (UAMI-ASSIGN-1, measured).
    'The move and its rollback need them. If Azure refuses one while the machine is stopped, the machine can stay stopped. ' +
    'So the run stopped before it changed the machine. Grant the VMF Migration role on this machine, its resource group or its subscription, then try again.'
}

function Get-VmfResourceNameFromId {
    <#
    .SYNOPSIS
        STOP-TEXT-SPECIFIC-1: the name of a resource, the last segment of its
        id, for the words of a stop. Pure. The id itself stays in the stop.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Id)
    $parts = @(([string]$Id).TrimEnd('/') -split '/' | Where-Object { $_ })
    if ($parts.Count) { [string]$parts[-1] } else { [string]$Id }
}

function Format-VmfNameList {
    <#
    .SYNOPSIS
        STOP-TEXT-SPECIFIC-1: 'a', 'a' and 'b', or 'a', 'b' and 'c'. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names)
    $q = @($Names | Where-Object { $_ } | ForEach-Object { "'$_'" })
    if ($q.Count -le 1) { return ($q -join '') }
    "$(($q[0..($q.Count - 2)]) -join ', ') and $($q[-1])"
}

# NIC-JOIN-1: a network interface write is also a JOIN of everything the
# interface links to.
#
# MEASURED 2026-09-27, the first end-to-end run of ADVISOR-1: turning
# accelerated networking on for a Generation 1 machine going to v5 was refused
# INSIDE the stopped window, and the machine was rolled back:
#
#   has permission to perform action 'Microsoft.Network/networkInterfaces/write'
#   on scope '.../networkInterfaces/<nic>'; however, it does not have permission
#   to perform action(s) 'Microsoft.Network/virtualNetworks/subnets/join/action'
#   on the linked scope(s) '.../virtualNetworks/<vnet>/subnets/<subnet>'
#   (LinkedAuthorizationFailed)
#
# Azure re-evaluates every resource the interface references on any write, even
# one that changes only accelerated networking. The PERM-3 check asked only at
# the machine's own scope, so it passed - and a customer's network usually lives
# in another resource group, where a narrow grant would not reach anyway. Same
# class as ROLE-SNAP-1: a permission on a resource the code never names.
#
# The set is Microsoft's own: the built-in Virtual Machine Contributor role
# carries a join action for each of these, read from Azure on 2026-09-27.
$script:VmfNicLinkJoins = [ordered]@{
    subnet                  = 'Microsoft.Network/virtualNetworks/subnets/join/action'
    networkSecurityGroup    = 'Microsoft.Network/networkSecurityGroups/join/action'
    publicIPAddress         = 'Microsoft.Network/publicIPAddresses/join/action'
    lbBackendAddressPool    = 'Microsoft.Network/loadBalancers/backendAddressPools/join/action'
    lbInboundNatRule        = 'Microsoft.Network/loadBalancers/inboundNatRules/join/action'
    appGwBackendAddressPool = 'Microsoft.Network/applicationGateways/backendAddressPools/join/action'
    applicationSecurityGroup = 'Microsoft.Network/applicationSecurityGroups/joinIpConfiguration/action'
}

# STOP-TEXT-SPECIFIC-1: each kind of linked resource in Azure's own words,
# for the stop that names it.
$script:VmfNicLinkWords = @{
    subnet                   = 'subnet'
    networkSecurityGroup     = 'network security group'
    publicIPAddress          = 'public IP address'
    lbBackendAddressPool     = 'load balancer backend pool'
    lbInboundNatRule         = 'load balancer inbound NAT rule'
    appGwBackendAddressPool  = 'application gateway backend pool'
    applicationSecurityGroup = 'application security group'
}

function Get-VmfNicLinkedActions {
    <#
    .SYNOPSIS
        Every (scope, action) pair Azure checks when this interface is written.
    .PARAMETER Nic
        The interface as Azure returns it - the Az object or the ARM JSON.
        Property names are matched without regard to case, so both work.
    .OUTPUTS
        @{ Scope; Action; Kind } per distinct pair.
    #>
    [CmdletBinding()]
    [OutputType([object[]])]
    param([Parameter(Mandatory)][AllowNull()]$Nic)
    if (-not $Nic) { return @() }
    $get = { param($o, $name) if ($o -and $o.PSObject.Properties[$name]) { $o.$name } else { $null } }
    $root = if (& $get $Nic 'properties') { $Nic.properties } else { $Nic }
    $pairs = [System.Collections.Generic.List[object]]::new()
    $add = { param($id, $kind) if ($id) { $pairs.Add([pscustomobject]@{ Scope = [string]$id; Action = $script:VmfNicLinkJoins[$kind]; Kind = $kind }) } }

    & $add (& $get (& $get $root 'networkSecurityGroup') 'id') 'networkSecurityGroup'
    foreach ($ipc in @(& $get $root 'ipConfigurations')) {
        if (-not $ipc) { continue }
        $c = if (& $get $ipc 'properties') { $ipc.properties } else { $ipc }
        & $add (& $get (& $get $c 'subnet') 'id') 'subnet'
        & $add (& $get (& $get $c 'publicIPAddress') 'id') 'publicIPAddress'
        foreach ($x in @(& $get $c 'loadBalancerBackendAddressPools')) { & $add (& $get $x 'id') 'lbBackendAddressPool' }
        foreach ($x in @(& $get $c 'loadBalancerInboundNatRules')) { & $add (& $get $x 'id') 'lbInboundNatRule' }
        foreach ($x in @(& $get $c 'applicationGatewayBackendAddressPools')) { & $add (& $get $x 'id') 'appGwBackendAddressPool' }
        foreach ($x in @(& $get $c 'applicationSecurityGroups')) { & $add (& $get $x 'id') 'applicationSecurityGroup' }
    }
    @($pairs | Sort-Object Scope, Action -Unique)
}

# SAFETY-CMK-1: a disk or a copy made with a disk encryption set makes the set
# a LINKED scope, the class ROLE-SNAP-1 (the snapshot) and NIC-JOIN-1 (the
# subnet) found by measurement. The action is Microsoft's: the built-in roles
# that make disks with a customer's key - Azure Migrate Execute Expert and
# Azure Red Hat OpenShift Disk Storage Operator - both carry it, and Virtual
# Machine Contributor, which carries no disk encryption set action, does not.
# NOT MEASURED in this product yet: the SAFETY-CMK-1 lab test removes it and
# records Azure's own LinkedAuthorizationFailed words.
$script:VmfDiskEncryptionSetAction = 'Microsoft.Compute/diskEncryptionSets/read'

function Format-VmfDiskEncryptionSetMissingMessage {
    <#
    .SYNOPSIS
        SAFETY-CMK-1: the parking message for a disk encryption set this
        identity cannot read, naming the set and the action.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$Missing,
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    # STOP-TEXT-SPECIFIC-1: leads with the sets by name; the action on each
    # scope follows, as Azure names them.
    $lines = @($Missing | ForEach-Object { "$($_.Action) on $($_.Scope)" })
    $sets = @($Missing | ForEach-Object { Get-VmfResourceNameFromId ([string]$_.Scope) } | Select-Object -Unique)
    $kind = if ($sets.Count -eq 1) { 'disk encryption set' } else { 'disk encryption sets' }
    "The product's managed identity cannot read the $kind $(Format-VmfNameList -Names $sets). " +
    'A disk made from a safety copy must have the disk encryption set of the disk it replaces, and Azure checks this permission on the set: ' +
    ($lines -join '; ') + ". $(Get-VmfPermissionStopWords -For $For) Grant the VMF Migration role where the disk encryption set is, then try again."
}

# UAMI-ASSIGN-1: a machine with a USER-ASSIGNED managed identity makes the
# identity a linked scope of EVERY write of the machine - a resize, a disk
# swap, a rebuild, and the rollback of each. MEASURED 2026-11-01 in the lab,
# with the VMF Migration role alone (redacted):
#
#   has permission to perform action 'Microsoft.Compute/virtualMachines/write'
#   ... however, it does not have permission to perform action(s)
#   'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action' on the
#   linked scope(s) '<the identity>' (LinkedAuthorizationFailed)
#
# on Path A and on Path B, and the rollback was refused the same way, so the
# machine was left stopped. The action is the one Azure named; Microsoft's FAQ
# gives it as userAssignedIdentities/*/assign/action, in the built-in Managed
# Identity Operator role. That form is accepted for this ONE action
# (Test-VmfIdentityAssignHeld), never by the shared matcher.
$script:VmfIdentityAssignAction = 'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action'
$script:VmfIdentityAssignDocumentedAction = 'Microsoft.ManagedIdentity/userAssignedIdentities/*/assign/action'

function Test-VmfIdentityAssignHeld {
    <#
    .SYNOPSIS
        UAMI-ASSIGN-1: may this account assign a user-assigned identity, from
        its effective permissions at the identity? Pure.
    .DESCRIPTION
        Held when one permission entry grants the action Azure names
        (userAssignedIdentities/assign/action) - or grants the form
        Microsoft's FAQ and the built-in Managed Identity Operator role use
        (userAssignedIdentities/*/assign/action), read as the same right -
        and that entry's notActions exclude neither form. Only for this
        action: the shared matcher never reads "/*/" as no segment.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowNull()]$Permissions)
    foreach ($entry in @($Permissions | Where-Object { $_ })) {
        $acts = @(if ($entry.PSObject.Properties['actions']) { $entry.actions })
        $nots = @(if ($entry.PSObject.Properties['notActions']) { $entry.notActions })
        # A notAction of this entry in EITHER spelling takes the right away.
        $excluded = @($nots | Where-Object { $_ } | Where-Object {
                $rx = ConvertTo-VmfActionRegex -Pattern $_
                ($script:VmfIdentityAssignAction -match $rx) -or ($script:VmfIdentityAssignDocumentedAction -match $rx)
            }).Count
        if ($excluded) { continue }
        # Granted in either spelling: the action Azure names, or the
        # documented form matched literally (itself, or a wider wildcard).
        $granted = @($acts | Where-Object { $_ } | Where-Object {
                $rx = ConvertTo-VmfActionRegex -Pattern $_
                ($script:VmfIdentityAssignAction -match $rx) -or ($script:VmfIdentityAssignDocumentedAction -match $rx)
            }).Count
        if ($granted) { return $true }
    }
    $false
}

function Format-VmfIdentityAssignMissingMessage {
    <#
    .SYNOPSIS
        UAMI-ASSIGN-1: the parking message for a user-assigned identity this
        account may not assign, naming the identity and the action, and the role to grant there - as the network and disk encryption set stops do.
    .PARAMETER Unread
        Identities whose permissions could not be read, each with Azure's
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
    # STOP-TEXT-SPECIFIC-1: leads with the identities by name.
    $lines = @($Missing | ForEach-Object { "$($_.Action) on $($_.Scope)" })
    $names = @($Missing | ForEach-Object { Get-VmfResourceNameFromId ([string]$_.Scope) } | Select-Object -Unique)
    $kind = if ($names.Count -eq 1) { 'user-assigned managed identity' } else { 'user-assigned managed identities' }
    $also = if (@($Unread).Count) { " The product also could not read this permission on: $(@($Unread) -join '; ')." } else { '' }
    "The product's managed identity cannot assign the $kind $(Format-VmfNameList -Names $names). " +
    $(if ($For -eq 'restore') { 'The restore updates the machine. Each update assigns each user-assigned managed identity again. Azure checks this permission on each user-assigned managed identity: ' }
      else { 'Every change to the machine, and its rollback, assigns the identity again, and Azure checks this permission on the identity: ' }) +
    ($lines -join '; ') + ".$also $(Get-VmfPermissionStopWords -For $For) Grant the VMF Migration role where the managed identity is, then try again."
}

function Format-VmfLinkedMissingMessage {
    <#
    .SYNOPSIS
        The parking message for a join this identity does not hold, naming the
        resource and the action, and what to grant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][object[]]$Missing,
        # RESTORE-PERM-CHECK-1: 'restore' when Restore this machine asks.
        [Parameter()][ValidateSet('move', 'restore')][string]$For = 'move'
    )
    # STOP-TEXT-SPECIFIC-1: leads with each resource by its Azure kind and
    # name (the Kind of Get-VmfNicLinkedActions), so the stop names only the
    # resources it is about.
    $lines = @($Missing | ForEach-Object { "$($_.Action) on $($_.Scope)" })
    # In the order the check found them, one entry for each resource.
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $named = @(foreach ($m in @($Missing)) {
            if (-not $seen.Add([string]$m.Scope)) { continue }
            $kindProp = $m.PSObject.Properties['Kind']
            $kind = if ($kindProp -and $script:VmfNicLinkWords.Contains([string]$kindProp.Value)) { $script:VmfNicLinkWords[[string]$kindProp.Value] } else { 'resource' }
            "the $kind '$(Get-VmfResourceNameFromId ([string]$m.Scope))'"
        })
    $list = if ($named.Count -le 1) { $named -join '' } else { "$(($named[0..($named.Count - 2)]) -join ', ') and $($named[-1])" }
    "The product's managed identity cannot join $list, which a network interface of this machine links to. " +
    $(if ($For -eq 'restore') { 'The restore sets accelerated networking on the network interface to its value before the move. Azure checks this permission on each resource that the network interface links to: ' }
      else { 'The move changes the network interface, and Azure checks this permission on each resource that it links to: ' }) +
    ($lines -join '; ') + ". $(Get-VmfPermissionStopWords -For $For) Grant the VMF Migration role where these resources are, then try again."
}

function Get-VmfPermissionStopWords {
    <#
    .SYNOPSIS
        RESTORE-PERM-CHECK-1: the sentence a permission stop says about the
        machine. A move stops at Checking; Restore this machine stops before
        it makes a disk or stops the machine. Pure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter()][ValidateSet('move', 'restore')][string]$For = 'move')
    if ($For -eq 'restore') { return 'The restore stopped before it changed the machine.' }
    'The run stopped before touching the machine.'
}

# RESTORE-PERM-CHECK-1, the class of ROLE-SNAP-1 (MEASURED on a live install
# 2026-09-18): a disk made FROM a snapshot makes the snapshot a linked scope,
# and Azure checks this action on it. The restore asks it on each safety copy
# it makes a disk from, before it makes one or stops the machine. The action is
# the one Azure named, and the one rbac-actions.json holds for New-AzDisk.
$script:VmfSnapshotReadAction = 'Microsoft.Compute/disks/beginGetAccess/action'

function Format-VmfSnapshotReadMissingMessage {
    <#
    .SYNOPSIS
        RESTORE-PERM-CHECK-1: the stop for a safety copy this identity cannot
        read to make a disk from, naming the copy and the action - as the disk
        encryption set stop does.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][object[]]$Missing)
    $lines = @($Missing | ForEach-Object { "$($_.Action) on $($_.Scope)" })
    $copies = @($Missing | ForEach-Object { Get-VmfResourceNameFromId ([string]$_.Scope) } | Select-Object -Unique)
    $kind = if ($copies.Count -eq 1) { 'safety copy' } else { 'safety copies' }
    # STE100 rewrite 2026-11-15: one fact per sentence, condition first.
    $what = if ($copies.Count -eq 1) { 'The restore makes a disk from this safety copy.' } else { 'The restore makes a disk from each of these safety copies.' }
    $scope = if ($copies.Count -eq 1) { 'the safety copy' } else { 'each safety copy' }
    "The product's managed identity cannot read the $kind $(Format-VmfNameList -Names $copies). $what " +
    'When Azure makes a disk from a safety copy, Azure checks this permission on the safety copy: ' +
    ($lines -join '; ') + ". $(Get-VmfPermissionStopWords -For 'restore') Grant the VMF Migration role on a scope that includes $scope. Then try again."
}
