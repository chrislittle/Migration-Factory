. (Join-Path $PSScriptRoot 'New-VmfRunTag.ps1')
<#
    ROLES-1: the one place that knows where the custom roles may be granted.

    There is ONE pair of definitions for a subscription, and the list of scopes
    they may be granted at GROWS. Nothing here creates a second pair, because
    the belief that made the old code do that was wrong: a role created in a
    subscription CAN be granted at a management group, once that group is in
    its assignableScopes. Measured 2026-09-07 - the update is accepted, the
    role keeps its id, and the grants it already made keep working.

    Dot-source this. Both the install hook and tools/Grant-VmfAccess.ps1 use it,
    so the rule lives once.
#>
# INSTALL-THROTTLE-RETRY-2: every az call here tries a throttled answer again.
. (Join-Path $PSScriptRoot 'Invoke-VmfAzStep.ps1')

function Get-VmfSubscriptionRoles {
    <#
    .SYNOPSIS
        The pair of custom roles DEFINED IN this subscription, if they exist.
    .DESCRIPTION
        Matched on two things together: the name the template gives them, and
        the fact that the definition lives in THIS subscription.

        Both halves matter. A plain name match finds roles inherited from a
        management group above, and roles another install made elsewhere, and
        there is no defined order to pick from - which is exactly how the
        dashboard could grant a role nobody meant.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SubscriptionId)

    $definedHere = "/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/roleDefinitions/"
    # INSTALL-THROTTLE-RETRY-2: a throttled read is tried again; any other
    # failure reads as no roles, as before.
    $all = Invoke-VmfAzStep -Step 'read the custom roles' -AllowFailure -Command {
        az role definition list --custom-role-only true --subscription $SubscriptionId --output json
    } | ConvertFrom-Json

    $ours = @($all | Where-Object { $_.id -like "$definedHere*" })
    # `Select-Object -First 1`, NEVER `[0]`. The install hook dot-sources
    # AzdHooks.ps1, which sets `Set-StrictMode -Version Latest`, and strict mode
    # is INHERITED BY CHILD SCOPES - so it is live in here. Under it, indexing an
    # EMPTY array throws "Index was outside the bounds of the array".
    #
    # An empty array is exactly what a FIRST install produces: a subscription
    # that does not have the pair yet. MEASURED 2026-09-10, the owner installing
    # into another environment - preprovision died on this line and `azd up`
    # never reached a resource. It never fired here because this subscription
    # has had the roles since ROLES-1.
    $assess = @($ours | Where-Object { $_.roleName -like 'VMF Assessment*' }) | Select-Object -First 1
    $execute = @($ours | Where-Object { $_.roleName -like 'VMF Migration*' }) | Select-Object -First 1
    [pscustomobject]@{
        Assess  = $assess
        Execute = $execute
    }
}

function Get-VmfScopeUnion {
    <#
    .SYNOPSIS
        The scope list these roles should carry, after adding some scopes.
    .DESCRIPTION
        Returns the union, and REFUSES the one thing Azure will not do: a
        second management group. A custom role may name only one. Refusing here
        with the two real options is worth more than an ARM error that names a
        limit and not a way forward.
    #>
    [CmdletBinding()]
    param(
        [string[]]$Existing = @(),
        [string[]]$Add = @()
    )

    $union = [System.Collections.Generic.List[string]]::new()
    foreach ($scope in (@($Existing) + @($Add))) {
        if ([string]::IsNullOrWhiteSpace($scope)) { continue }
        $trimmed = $scope.TrimEnd('/')
        if (-not ($union | Where-Object { $_ -eq $trimmed })) { $union.Add($trimmed) }
    }

    $groups = @($union | Where-Object { $_ -like '/providers/Microsoft.Management/managementGroups/*' })
    if ($groups.Count -gt 1) {
        throw ("A custom role may name only ONE management group, and this would name $($groups.Count): " +
               "$($groups -join ', '). Two ways forward: name a management group that contains both, " +
               'and grant there instead; or make a second installation for the other group.')
    }
    # Azure refuses these outright, and the error it gives does not say why.
    foreach ($scope in $union) {
        if ($scope -eq '' -or $scope -eq '/') { throw 'The root scope cannot be used for a custom role.' }
        if ($scope -like '*``**' -or $scope.Contains('*')) { throw "A scope cannot contain a wildcard: '$scope'." }
    }
    if ($union.Count -gt 2000) { throw "A custom role may name at most 2,000 scopes; this would name $($union.Count)." }

    , @($union)
}

function Get-VmfExpectedRoleActions {
    <#
    .SYNOPSIS
        ROLE-DEPLOY-1: what a role SHOULD permit, from the same map the template
        builds it from.
    .DESCRIPTION
        roles.bicep derives the actions with `loadJsonContent` over
        src/VmMigrationFactory/data/rbac-actions.json, so that file is the one
        source. This reads it the same way, because comparing against anything
        else would be a second list to keep in step - the defect the map exists
        to prevent.

        The execute role CONTAINS the assess role: a migration reads before it
        writes, and roles.bicep unions them for the same reason.
    .PARAMETER Role
        'assess' or 'execute'.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][ValidateSet('assess', 'execute')][string]$Role)

    $mapPath = Join-Path $PSScriptRoot '..' 'src' 'VmMigrationFactory' 'data' 'rbac-actions.json'
    $map = Get-Content -LiteralPath $mapPath -Raw | ConvertFrom-Json
    $actionsFor = {
        param($which)
        @($map.operations | Where-Object { $_.role -eq $which } | ForEach-Object { $_.actions })
    }
    $actions = @(& $actionsFor 'assess')
    if ($Role -eq 'execute') { $actions += @(& $actionsFor 'execute') }
    , @($actions | Where-Object { $_ } | Sort-Object -Unique)
}

function Test-VmfRoleActionsCurrent {
    <#
    .SYNOPSIS
        ROLE-DEPLOY-1: does a deployed role permit exactly what it should?
    .DESCRIPTION
        BOTH directions matter. A role missing an action cannot do its job -
        that is ROLE-SNAP-1, where a restore failed because the role could not
        read the snapshot it was building a disk from. A role carrying an action
        the map no longer lists is a privilege nobody can account for, and
        IDENTITY-4 removed two of exactly those. Either way the definition has
        drifted from the code and must be deployed again.
    .PARAMETER Role
        The deployed role, as `az role definition list` returns it.
    .PARAMETER Expected
        What the map says it should permit.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowNull()]$Role,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Expected
    )

    if (-not $Role) { return $false }
    # A role with no permissions block at all has drifted as far as it can.
    $held = @()
    if ($Role.PSObject.Properties['permissions'] -and @($Role.permissions).Count -gt 0) {
        $held = @($Role.permissions[0].actions)
    }
    $held = @($held | Where-Object { $_ } | Sort-Object -Unique)
    @(Compare-Object -ReferenceObject @($Expected) -DifferenceObject $held).Count -eq 0
}

function Set-VmfRoleScopes {
    <#
    .SYNOPSIS
        Create the pair, or widen where they may be granted. Never duplicates.
    .DESCRIPTION
        Reads what the roles already carry, unions the new scopes in, and
        deploys the whole list. The WHOLE list, because a deployment states a
        property rather than adding to one - passing only the new scope would
        drop the others and break every grant made through them.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$Location,
        [string[]]$AddScopes = @(),
        [string]$DeploymentName
    )

    $subScope = "/subscriptions/$SubscriptionId"
    $current = Get-VmfSubscriptionRoles -SubscriptionId $SubscriptionId
    $existing = @()
    if ($current.Assess) { $existing += @($current.Assess.assignableScopes) }
    if ($current.Execute) { $existing += @($current.Execute.assignableScopes) }

    # The subscription the roles live in is always in the list. Without it the
    # install's own resource groups could not be granted.
    $wanted = Get-VmfScopeUnion -Existing $existing -Add (@($subScope) + @($AddScopes))

    $scopesMatch = $current.Assess -and $current.Execute -and
        (@(Compare-Object -ReferenceObject @($current.Assess.assignableScopes | Sort-Object) `
                          -DifferenceObject @($wanted | Sort-Object)).Count -eq 0)

    # ROLE-DEPLOY-1: AND THE PERMISSIONS, WHICH THIS NEVER LOOKED AT.
    #
    # This decided whether to deploy by comparing the assignable scopes alone.
    # So when a role's ACTIONS changed and its scopes did not - which is what
    # every permission fix looks like - it reported success and deployed
    # NOTHING. The role in Azure stayed as it was, for ever.
    #
    # MEASURED 2026-09-18. ROLE-SNAP-1 added an action the restore path needs.
    # The owner merged it and ran `azd up`. The install printed
    #
    #    the list of places these roles may be given out is already correct
    #
    # which was TRUE, and had nothing to do with what had changed. The role
    # never gained the action, the restore went on failing, and there was no
    # other way to apply it: the dashboard has no re-apply, and a grant made by
    # hand cannot add a permission the DEFINITION does not carry.
    #
    # The whole point of deriving the role from the map is that the role cannot
    # fall behind the code. A deploy that skips on a stale comparison is exactly
    # that failure, wearing a reassuring message - the same shape as every other
    # check that reports a result it never measured.
    $permissionsMatch = $current.Assess -and $current.Execute -and
        (Test-VmfRoleActionsCurrent -Role $current.Assess -Expected (Get-VmfExpectedRoleActions -Role 'assess')) -and
        (Test-VmfRoleActionsCurrent -Role $current.Execute -Expected (Get-VmfExpectedRoleActions -Role 'execute'))

    if ($scopesMatch -and $permissionsMatch) {
        # ROLES-UX-2: this said "the roles already reach every scope asked for".
        # "Reach" reads as "the product can already reach those machines". It
        # cannot: this compares the list of places the roles MAY be given out,
        # and changes nothing about who holds one.
        $places = if ($wanted.Count -eq 1) { '1 place' } else { "$($wanted.Count) places" }
        Write-Host "   these roles already permit what the product does, and may be given out in the right $places"
        return $wanted
    }
    if ($scopesMatch) {
        # Say WHICH of the two brought the deployment about, so an operator can
        # tell a widening from a permission change in the install's output.
        Write-Host '   these roles no longer permit everything the product does - updating them'
    }

    $paramFile = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-roles-$(New-VmfRunTag).json"
    @{
        '$schema'      = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters     = @{ assignableScopes = @{ value = @($wanted) } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $paramFile -Encoding utf8NoBOM

    if (-not $DeploymentName) { $DeploymentName = "vmf-roles-$(Get-Date -Format yyyyMMddHHmmss)" }
    try {
        if ($PSCmdlet.ShouldProcess("subscription $SubscriptionId", "set the role scopes to $($wanted -join ', ')")) {
            # INSTALL-THROTTLE-RETRY-2: a throttled deployment request is tried
            # again; a refusal keeps its own words, and says a throttle.
            $deployed = Invoke-VmfAzCall -Step 'set where the custom roles may be granted' -Command {
                az deployment sub create --name $DeploymentName --location $Location --subscription $SubscriptionId `
                    --template-file (Join-Path $PSScriptRoot 'roles.bicep') --parameters "@$paramFile" --output none
            }
            if ($deployed.ExitCode -ne 0) {
                throw ("Could not set where the custom roles may be granted. The account doing this needs " +
                       "Microsoft.Authorization/roleDefinitions/write on EVERY scope in the list, not only the new one: " +
                       ($wanted -join ', ') + '.' + (Get-VmfAzThrottleNote -Result $deployed))
            }
        }
    }
    finally { Remove-Item $paramFile -Force -ErrorAction SilentlyContinue }
    , @($wanted)
}
