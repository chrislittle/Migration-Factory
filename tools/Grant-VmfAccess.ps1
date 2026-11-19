<#
.SYNOPSIS
    ONBOARD-1 (and GATE-1): give the service the access it needs, give the
    first person an admin role, and optionally close the door behind them.
.DESCRIPTION
    This is the step between "the platform is deployed" and "someone can
    actually use it". It grants the PERM-1 custom roles - never Contributor -
    at scopes the OPERATOR chooses, because where a tool may LOOK and where it
    may CHANGE things are two different questions:

      -AssessScope    where it may scan. Read-only, so this can be broad: a
                      subscription, or a management group for a whole estate.
      -MigrateScope   where it may stop and resize machines. Grant
                      this as narrowly as the estate allows.

    THE MIGRATION ROLE ALREADY CONTAINS THE ASSESSMENT ROLE (infra/roles.bicep
    unions the two action lists - a migration reads before it writes). The two
    parameters exist to set DIFFERENT scopes, not to be passed together at the
    same one: -MigrateScope alone on a scope grants everything there, and an
    -AssessScope beside it adds nothing.

    It also assigns the first admin, because a tool nobody can sign in to is
    not installed, it is just deployed.

    GATE-1 is deliberately a separate switch. -CloseTheGate makes an app role
    a requirement for signing in at all, rather than letting anyone in the
    tenant sign in to an empty tool. It REFUSES to run when nobody holds an
    admin role, because that combination locks everyone out of the tool and
    the tool cannot let them back in - that takes a directory admin and the
    portal.

    Nothing here stores a secret. Every grant is a role assignment against an
    identity that already exists.
.EXAMPLE
    # scan the whole subscription, but only ever change machines in one group
    ./tools/Grant-VmfAccess.ps1 -ResourceGroup <resource-group> `
        -AssessScope /subscriptions/<sub> `
        -MigrateScope /subscriptions/<sub>/resourceGroups/<resource-group> `
        -FirstAdmin someone@contoso.com
.EXAMPLE
    # once an admin exists, require a role to sign in
    ./tools/Grant-VmfAccess.ps1 -ResourceGroup <resource-group> -CloseTheGate
.EXAMPLE
    # the product is in another subscription than the Azure CLI uses now
    ./tools/Grant-VmfAccess.ps1 -ResourceGroup <resource-group> -SubscriptionId <sub> `
        -MigrateScope /subscriptions/<sub>/resourceGroups/<resource-group>
.PARAMETER SubscriptionId
    The subscription the product is in. Empty means the Azure CLI's current one.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    # ID-ADDRESS-1: the subscription the install is in. A resource group's name
    # is unique only inside one subscription. Empty means the Azure CLI's
    # current one, and the script says which it used.
    [string]$SubscriptionId,
    [string]$AssessScope,
    [string]$MigrateScope,
    [string]$FirstAdmin,
    # GRANT-NAME-1: empty means FIND it. A default of 'vmf-api' named a
    # registration no install has created since they gained the environment.
    [string]$ApiDisplayName = '',
    # ID-ADDRESS-1: the EXACT names of the engine's managed identity and the
    # facade. The install passes both. Empty means find each by its name
    # prefix, and refuse when two match.
    [string]$EngineIdentityName = '',
    [string]$FacadeName = '',
    [switch]$CloseTheGate
)

$ErrorActionPreference = 'Stop'
$VmfAdminRoleId = '6f1c3a10-0004-4b6e-9e6a-100000000004'
# The one way this product finds its own registrations: an exact name, and a
# refusal when two carry it.
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfRegistration.ps1')
. (Join-Path $PSScriptRoot '..' 'infra' 'New-VmfRunTag.ps1')
# INSTALL-THROTTLE-RETRY-2: every az call here tries a throttled answer again
# and keeps its own failure words.
. (Join-Path $PSScriptRoot '..' 'infra' 'Invoke-VmfAzStep.ps1')

function Write-Step([string]$Text) { Write-Host "" ; Write-Host $Text -ForegroundColor Cyan }

# --- who the service is -------------------------------------------------
# GRANT-FIX-1: filtered in PowerShell, never with `--query "[?...]"`. cmd eats
# the bracket, so the filter never reaches Azure and an error string comes back
# looking like an answer (CLAUDE.md, measured 2026-08-30).
#
# ID-ADDRESS-1: in the install's own subscription, named on every call, and ONE
# identity of each kind. A prefix that matches two - two installs in one
# resource group, or somebody else's resource named alike - is refused, never
# answered with the first one listed: the grant would go to whichever that was.
if (-not $SubscriptionId) {
    $SubscriptionId = az account show --query id -o tsv
    if (-not $SubscriptionId) { throw 'No subscription is selected. Give -SubscriptionId, or select one with az account set.' }
    Write-Host "   subscription: $SubscriptionId (the Azure CLI's current one; give -SubscriptionId to name another)"
}
if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
    throw "'$SubscriptionId' is not a subscription ID."
}
# The identities are read only when this run needs them. -CloseTheGate alone
# changes the directory, not Azure, so a directory administrator with no role
# on the resource group can still run it.
$engineMi = $null
$facadeMi = $null
if (-not $CloseTheGate -or $AssessScope -or $MigrateScope) {
    # A listing that FAILED is not an empty resource group: it used to read as
    # "Found no VMF identities", which sends a person to deploy what is there.
    $idRead = Invoke-VmfAzCall -Step 'list the managed identities' -Command { az identity list -g $ResourceGroup --subscription $SubscriptionId -o json }
    if ($idRead.ExitCode -ne 0) { throw ("Could not list the managed identities in '$ResourceGroup' in subscription $SubscriptionId." + (Get-VmfAzThrottleNote -Result $idRead)) }
    $identities = $idRead.Output
    $appRead = Invoke-VmfAzCall -Step 'list the function apps' -Command { az functionapp list -g $ResourceGroup --subscription $SubscriptionId -o json }
    if ($appRead.ExitCode -ne 0) { throw ("Could not list the function apps in '$ResourceGroup' in subscription $SubscriptionId." + (Get-VmfAzThrottleNote -Result $appRead)) }
    $functionApps = $appRead.Output
    # Select-VmfOneByName (infra/Resolve-VmfRegistration.ps1): the rule every tool uses.
    $engineMi = (Select-VmfOneByName -Items @($identities | ConvertFrom-Json) -Exact $EngineIdentityName -Prefix 'vmf-engine-mi' `
            -What 'managed identities' -NameParameter 'EngineIdentityName' -ResourceGroup $ResourceGroup -Use 'grant').principalId
    $facadeMi = (Select-VmfOneByName -Items @($functionApps | ConvertFrom-Json) -Exact $FacadeName -Prefix 'vmf-facade' `
            -What 'function apps' -NameParameter 'FacadeName' -ResourceGroup $ResourceGroup -Use 'grant').identity.principalId
    if (-not $engineMi -and -not $facadeMi) {
        throw "Found no VMF identities in '$ResourceGroup'. Deploy infra/platform.bicep first."
    }
}

# --- 0. every directory object this run needs, BEFORE it changes anything --
# The registration used to be read half way down, after the custom roles had
# been created. A refusal there left the run part done: with -CloseTheGate the
# roles existed and the gate was never closed. Resolve first, act second.
#
# And by an EXACT name. `az ad app list --display-name X --query '[0].appId'`
# took whichever registration the directory listed first, and Entra does not
# make a display name unique - so the administrator role could have been
# granted on an application any member of the tenant had registered under the
# same name, and the gate closed on it.
# GRANT-NAME-1: the default used to be the bare 'vmf-api', which no install has
# created since the names gained the environment ('vmf-api-<env>'). The script
# is not run by azd, so it cannot read the environment - it FINDS the
# registration instead, and refuses rather than guessing when the answer is not
# one.
if (-not $ApiDisplayName) {
    # Through the one place that owns directory name lookups, never a bare
    # `az ad app list` here - that is the defect RegistrationLookup guards.
    $candidates = @(Find-VmfEntraApplications -NameStartsWith 'vmf-api')
    if ($candidates.Count -eq 1) {
        $ApiDisplayName = [string]$candidates[0].displayName
        Write-Host "   found the registration: $ApiDisplayName"
    }
    elseif ($candidates.Count -gt 1) {
        throw ("This directory holds $($candidates.Count) registrations whose name starts 'vmf-api': " +
               (($candidates | ForEach-Object { $_.displayName }) -join ', ') +
               ". Name the one for this install with -ApiDisplayName.")
    }
    else {
        throw ('No registration whose name starts "vmf-api" exists, or this account may not read it. ' +
               'Install the product first, or name it with -ApiDisplayName.')
    }
}
$apiApp = Get-VmfEntraApplication -DisplayName $ApiDisplayName
if (-not $apiApp) {
    throw ("The '$ApiDisplayName' registration does not exist, or this account may not read it. " +
           'Deploy infra/identity.bicep first.')
}
$apiSp = Get-VmfEntraServicePrincipal -AppId ([string]$apiApp.appId)
if (-not $apiSp) {
    throw ("No service principal for the '$ApiDisplayName' registration can be read. Either it was removed, " +
           'or this account may not read service principals. Deploy infra/identity.bicep first.')
}
$apiSpId = [string]$apiSp.id
$userId = ''
if ($FirstAdmin) {
    $userId = Invoke-VmfAzStep -Step "find $FirstAdmin in the directory" -AllowFailure -Command { az ad user show --id $FirstAdmin --query id -o tsv }
    if (-not $userId) { throw "Could not find '$FirstAdmin' in the directory." }
}

# --- 1. the roles themselves -------------------------------------------
# ROLES-1. A role definition can be granted at or BELOW anything in its
# assignableScopes - and that list is NOT fixed at creation. This file used to
# say it was, and used to create a SECOND pair of definitions at a management
# group because of it, leaving the first pair's grants pointing at roles
# nothing used any more.
#
# MEASURED 2026-09-07, with a throwaway role: adding a management group to
# assignableScopes was accepted, the role kept its id, the grant it had already
# made was still there, and it could then be granted at that group.
#
# So there is ONE pair for a subscription, and onboarding WIDENS it. The union
# and Azure's own limit of a single management group live in
# infra/Resolve-VmfRoleScopes.ps1, so the install hook and this script cannot
# disagree about them.
. (Join-Path $PSScriptRoot '..' 'infra' 'Resolve-VmfRoleScopes.ps1')

if ($AssessScope -or $MigrateScope) {
    Write-Step 'Making sure the two custom roles reach the scopes being granted...'
    $scopes = @($AssessScope, $MigrateScope) | Where-Object { $_ }
    # INSTALL-0: the deployment record needs a region; it used to be OUR lab's
    # region as a literal. The platform's own resource group says which.
    $location = Invoke-VmfAzStep -Step "read the region of '$ResourceGroup'" -AllowFailure -Command {
        az group show -n $ResourceGroup --subscription $SubscriptionId --query location -o tsv
    }
    if (-not $location) { throw "Resource group '$ResourceGroup' was not found in subscription $SubscriptionId, so its region cannot be read." }
    $installSub = $SubscriptionId

    $reach = Set-VmfRoleScopes -SubscriptionId $installSub -Location $location -AddScopes $scopes
    Write-Host '   VMF Assessment (read only) and VMF Migration (read + the writes a migration needs)'
    Write-Host "   they may be granted at: $($reach -join ', ')"
}

# Custom role NAMES must be unique per tenant, so roles.bicep appends a short
# hash of the scope - the real name is "VMF Assessment (abc123)". Assigning by
# the bare name therefore fails, silently as far as az is concerned. Resolve
# the definition id once and assign by id, which is unambiguous.
function Resolve-RoleId {
    param([string]$NamePrefix)
    # ROLES-1: match the name AND the fact that the definition lives in this
    # subscription. A bare name match also finds roles inherited from a
    # management group above and roles another install made, with no defined
    # order to choose from - which is how the wrong definition gets granted and
    # nothing says so.
    $installSub = $SubscriptionId
    $found = Get-VmfSubscriptionRoles -SubscriptionId $installSub
    $role = if ($NamePrefix -like 'VMF Assessment*') { $found.Assess } else { $found.Execute }
    if (-not $role) {
        throw ("Could not find the custom role '$NamePrefix' defined in subscription $installSub. " +
               'Run the install, or deploy infra/roles.bicep, first.')
    }
    ($role.id -split '/')[-1]
}

# Role assignment is not idempotent: a second run reports the assignment
# already exists, which is success as far as this script is concerned.
function Grant-Role {
    param([string]$PrincipalId, [string]$RoleName, [string]$Scope, [string]$What)
    if (-not $PrincipalId) { Write-Warning "no identity found for $What - skipping"; return }
    if (-not $Scope) { return }
    $roleId = Resolve-RoleId -NamePrefix $RoleName
    # GRANT-FIX-1: same reason. This one returned an error string that [int]
    # read as 0, so an existing grant looked absent and was made again.
    $existing = @(Invoke-VmfAzStep -Step "read the role assignments of $What" -AllowFailure -Command {
            az role assignment list --assignee $PrincipalId --scope $Scope -o json
        } | ConvertFrom-Json | Where-Object { $_.roleDefinitionId -and $_.roleDefinitionId -match [regex]::Escape($roleId) })
    if ($existing.Count -gt 0) {
        Write-Host "   already granted: $What -> $RoleName"
        return
    }
    $granted = Invoke-VmfAzCall -Step "grant $RoleName to $What" -Command {
        az role assignment create --assignee-object-id $PrincipalId --assignee-principal-type ServicePrincipal `
            --role $roleId --scope $Scope --output none
    }
    if ($granted.ExitCode -eq 0) { Write-Host "   granted: $What -> $RoleName on $(($Scope -split '/')[-1])" }
    else { throw ("Could not grant $RoleName to $What at $Scope - the install is not complete." + (Get-VmfAzThrottleNote -Result $granted)) }
}

if ($AssessScope) {
    Write-Step "Letting the service SEE machines in $AssessScope"
    Write-Host '   This role is read-only - it cannot change anything.'
    Grant-Role -PrincipalId $engineMi -RoleName 'VMF Assessment' -Scope $AssessScope -What 'the migration engine'
    Grant-Role -PrincipalId $facadeMi -RoleName 'VMF Assessment' -Scope $AssessScope -What 'the web service'
}

if ($MigrateScope) {
    Write-Step "Letting the service CHANGE machines in $MigrateScope"
    Write-Host '   Only the engine may change a machine. The web service reads here and writes nothing.'
    Grant-Role -PrincipalId $engineMi -RoleName 'VMF Migration' -Scope $MigrateScope -What 'the migration engine'
    # THE WEB SERVICE READS AZURE WITH ITS OWN IDENTITY, and it was left out
    # here. MEASURED on an install, 2026-09-15: the engine held a role
    # on the subscription, the service held nothing outside the product's own
    # resource group, and the wizard's resource group list came back empty with
    # "the service needs read access before it can list them". Subscriptions
    # still listed, because the BROWSER reads those with the person's own
    # token - so the page offered a subscription and then showed nothing in it.
    #
    # The migration role contains the assessment role, which is true of the
    # ACTIONS and says nothing about WHO holds them. Both identities need
    # reach; only the engine needs to write.
    Grant-Role -PrincipalId $facadeMi -RoleName 'VMF Assessment' -Scope $MigrateScope -What 'the web service'
}

# --- 2. the first person ------------------------------------------------
# Both the registration and the person were resolved in step 0, before
# anything was created or granted.
if ($FirstAdmin) {
    Write-Step "Making $FirstAdmin an administrator of this tool"
    $assignFile = Join-Path ([System.IO.Path]::GetTempPath()) "vmf-admin-$(New-VmfRunTag).json"
    @{ principalId = $userId; resourceId = $apiSpId; appRoleId = $VmfAdminRoleId } |
        ConvertTo-Json | Set-Content $assignFile -Encoding utf8NoBOM
    try {
        Invoke-VmfAzStep -Step 'ask the directory for Vmf.Admin' -AllowFailure -Command {
            az rest --method POST --url "https://graph.microsoft.com/v1.0/users/$userId/appRoleAssignments" `
                --headers 'Content-Type=application/json' --body "@$assignFile" --output none
        } | Out-Null
    }
    finally { Remove-Item $assignFile -Force -ErrorAction SilentlyContinue }
    # READ IT BACK. This used to print "granted" whatever happened: the exit
    # code was discarded, because an already-assigned role answers with an
    # error and that is success here. So the one line a person reads was true
    # for a refusal as well - and FIRSTRUN-1 now has the install repeat it.
    # The assignment itself is the only answer worth printing.
    $held = @(Invoke-VmfAzStep -Step 'read back the Vmf.Admin role' -AllowFailure -Command {
            az rest --method GET --url "https://graph.microsoft.com/v1.0/users/$userId/appRoleAssignments" -o json
        } | ConvertFrom-Json | Select-Object -ExpandProperty value -ErrorAction SilentlyContinue |
        Where-Object { $_.resourceId -eq $apiSpId -and $_.appRoleId -eq $VmfAdminRoleId })
    if ($held.Count) { Write-Host '   granted: Vmf.Admin' }
    else {
        throw ("The Vmf.Admin role was not given to $FirstAdmin, and the directory did not say why. " +
               'Assigning a role in an application needs a directory administrator, or ownership of ' +
               "the '$ApiDisplayName' registration. Ask an administrator, or assign it in the portal.")
    }
}

# --- 3. GATE-1: only now, and only if somebody can get in ---------------
if ($CloseTheGate) {
    Write-Step 'Requiring an assigned role to sign in'
    # GRANT-QUERY-SHIM-1: read the json and count in PowerShell. A
    # `--query "value[?appRoleId=='...'] | length(@)"` went through az.cmd,
    # which eats the [? filter and drops the double quotes (CLAUDE.md), so the
    # answer was no count, [int] read it as 0, and this said nobody held the
    # role when somebody did. The read goes through the product's one directory
    # reader, which keeps az's error text: a FAILED read is said as a failed
    # read, never as "no one". What is counted is ASSIGNMENTS of the role - a
    # user, a group or a service principal each holds one.
    # Only "at least one" matters, so the reading stops at the first page that
    # holds one. Until then it follows Graph's next page, at most $maxPages, and
    # only to an address on https://graph.microsoft.com/ that holds no '&'
    # (az.cmd reads '&' as a command separator, CLAUDE.md). Each refusal leaves
    # the gate open.
    $graphRoot = 'https://graph.microsoft.com/'
    $admins = 0
    $maxPages = 50
    $pagesRead = 0
    $url = "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId/appRoleAssignedTo"
    while ($url -and $admins -lt 1) {
        if ($pagesRead -ge $maxPages) {
            throw ("Refusing to close the gate: the assignments of '$ApiDisplayName' fill more than $maxPages pages, " +
                   'and none of them is an assignment of the Vmf.Admin role. The gate stays open.')
        }
        if (-not $url.StartsWith($graphRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw ("Refusing to close the gate: the next page of assignments has an address that does not start " +
                   "with $graphRoot, so this tool does not read it. The gate stays open.")
        }
        if ($url.Contains('&')) {
            throw ("Refusing to close the gate: the next page of assignments has an address that holds '&', " +
                   'which the Azure CLI on Windows cannot pass. The gate stays open.')
        }
        try {
            $answer = Get-VmfDirectoryList -Arguments @('rest', '--method', 'GET', '--url', $url) `
                -What "the assignments of the Vmf.Admin role on '$ApiDisplayName'"
        }
        catch { throw "Refusing to close the gate: $($_.Exception.Message) The gate stays open." }
        $page = @($answer) | Select-Object -First 1
        if ($null -eq $page -or $page.PSObject.Properties.Name -notcontains 'value') {
            throw ("Refusing to close the gate: Could not read the assignments of the Vmf.Admin role on " +
                   "'$ApiDisplayName' from the directory (the answer holds no list of assignments). The gate stays open.")
        }
        $admins += @($page.value | Where-Object { $null -ne $_ -and [string]$_.appRoleId -eq $VmfAdminRoleId }).Count
        $pagesRead++
        $url = if ($page.PSObject.Properties.Name -contains '@odata.nextLink') { [string]$page.'@odata.nextLink' } else { '' }
    }
    if ($admins -lt 1) {
        throw @"
Refusing to close the gate: no one holds the administrator role.

Requiring a role to sign in while nobody has one would lock everybody out of
this tool, and the tool could not let them back in - that would take a
directory administrator and the Azure portal.

Grant an administrator first:
  ./tools/Grant-VmfAccess.ps1 -ResourceGroup $ResourceGroup -FirstAdmin <someone@example.com>
"@
    }
    $gateSet = Invoke-VmfAzCall -Step 'require a role for sign-in' -Command {
        az rest --method PATCH --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId" `
            --headers 'Content-Type=application/json' --body '{"appRoleAssignmentRequired": true}' --output none
    }
    if ($gateSet.ExitCode -ne 0) { throw ('Could not require role assignment for sign-in.' + (Get-VmfAzThrottleNote -Result $gateSet)) }
    Write-Host "   done - the Vmf.Admin role has at least $admins assignment(s). A user with no assigned role cannot sign in now."
}

Write-Step 'Where this leaves things'
$gate = Invoke-VmfAzStep -Step 'read the sign-in rule' -AllowFailure -Command {
    az rest --method GET --url "https://graph.microsoft.com/v1.0/servicePrincipals/$apiSpId" --query 'appRoleAssignmentRequired' -o tsv
}
Write-Host "   sign-in requires an assigned role : $gate"
# GRANT-NAME-1: this reported the PARAMETERS, not what the product can reach.
# Granting migrate alone printed "the service can SEE: (unchanged)", which
# reads as "still blind" - and it is not, because the migration role contains
# the assessment role.
$canSee = if ($AssessScope -and $MigrateScope) { "$AssessScope, and $MigrateScope" }
          elseif ($AssessScope) { $AssessScope }
          elseif ($MigrateScope) { "$MigrateScope (the migration role includes assessment)" }
          else { '(unchanged)' }
Write-Host "   the service can SEE               : $canSee"
Write-Host "   the service can CHANGE            : $(if ($MigrateScope) { $MigrateScope } else { '(unchanged)' })"
Write-Host ''
Write-Host 'Anything granted here can be reviewed with: az role assignment list --assignee <principal> --all' -ForegroundColor DarkGray
