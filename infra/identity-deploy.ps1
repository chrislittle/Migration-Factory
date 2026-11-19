<#
.SYNOPSIS
    Deploy the Entra registrations (infra/identity.bicep) for a platform.
.DESCRIPTION
    INSTALL-0. This script used to carry our lab as literals: its resource
    group, the dashboard's address with our suffix in it, and the API
    registration's own id. All three are now a parameter or read from where
    they live. The suffix follows the same rule as infra/deploy.ps1
    (Resolve-VmfSuffix): an existing deployment's wins, a fresh group derives.

    GATE-1 DRIFT. The template declares appRoleAssignmentRequired, and it once
    declared the LITERAL false while the live tenant was true - closed
    deliberately by Grant-VmfAccess.ps1 -CloseTheGate long after this was
    written. Bicep is declarative, so a redeploy would have asserted false and
    SILENTLY RE-OPENED sign-in to anybody in the tenant. So the live posture is
    read and handed back: a redeploy preserves a closed gate, and closing one
    stays a deliberate act of Grant-VmfAccess.ps1.

    ONE PASS. Tokens for the API are issued for api://<its own app id>, and
    that id does not exist until the registration does. The template sets it
    itself, with a second declaration of the registration (INSTALL-0 piece
    3), so this script passes nothing for it and there is no second run.

    WHAT IT RETURNS. The template's own outputs: ApiAppId, DashboardAppId and
    ApiServicePrincipalId. The caller uses ApiAppId directly. It used to look
    the registration up again by display name afterwards and take the first
    answer, and a display name is not unique in Entra - so a registration
    somebody else in the tenant made with the same name could become the
    application the facade validates every token against.
.PARAMETER ResourceGroup
    The resource group the platform lives in, or will.
.PARAMETER BaseSuffix
    Only to adopt a deployment whose suffix was chosen by hand.
.PARAMETER ApiDisplayName
    Display name of the API registration. The template creates it under this
    name. The name is used to read the LIVE sign-in gate before the deployment
    asserts it, matched exactly; two registrations with this name is a refusal,
    not a guess.
.PARAMETER DashboardDisplayName
    Display name of the dashboard registration. INSTALL-1: an azd install
    names both registrations after its environment, because a registration's
    unique name is TENANT-wide - two installs in one tenant with the default
    names would overwrite each other's redirect addresses.
.PARAMETER WhatIf
    Show what would change, and stop.
.EXAMPLE
    ./infra/identity-deploy.ps1 -ResourceGroup <resource-group>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter()][string]$BaseSuffix,
    [Parameter()][string]$ApiDisplayName = 'vmf-api',
    [Parameter()][string]$DashboardDisplayName = 'vmf-dashboard',
    # Empty means uniqueName equals displayName, which is how every install made
    # before 2026-09-09 is left alone. See identity.bicep's registrationKey.
    [Parameter()][string]$RegistrationKey = '',
    [Parameter()][switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Resolve-VmfSuffix.ps1')
. (Join-Path $PSScriptRoot 'Resolve-VmfRegistration.ps1')

$suffix = Resolve-VmfSuffix -ResourceGroup $ResourceGroup -BaseSuffix $BaseSuffix

# The live posture is read from the registration THIS deployment updates,
# found by its exact name and then by its application id - never by the first
# answer to a name lookup. A FAILED directory call throws inside the helper
# rather than reading as "no registration", because "no registration" is what
# this script turns into "the gate is open" two lines down.
$apiApp = Get-VmfEntraApplication -DisplayName $ApiDisplayName
$apiSp = if ($apiApp) { Get-VmfEntraServicePrincipal -AppId ([string]$apiApp.appId) } else { $null }
if ($apiApp -and -not $apiSp) {
    Write-Warning ("The '$ApiDisplayName' registration exists, but this account can read no service principal " +
                   'for it. Either the service principal is not created yet, or the account may not read ' +
                   'service principals. This deployment sets the sign-in gate OPEN, which is the value a first ' +
                   'deployment uses. Stop now if the gate was closed, and run this as an account that may read ' +
                   'service principals.')
}
# A REMOVED INSTALL LEAVES ITS NAMES BEHIND FOR 30 DAYS, and that is what makes
# `azd down` followed by `azd up` fail. MEASURED 2026-09-09.
#
# azd down deletes both registrations. Entra SOFT-deletes an application and
# holds its displayName for thirty days, and the Graph extension upserts by
# uniqueName - so the next install collides with the tombstone and the
# deployment fails with:
#
#   InvalidDeployment ... The language expression property 'appId' doesn't exist
#
# which names appId, never the deleted object. Nobody would work that out.
# PROVEN both ways: the same deployment, the same names, tombstones present
# fails and tombstones purged succeeds.
#
# So the tombstones are cleared here, and ONLY ones that carry the exact names
# this install is about to create. Those names are env-suffixed and belong to
# this product, so a collision with anything else is not credible - but the
# match is exact rather than a prefix, because permanently deleting the wrong
# directory object is not recoverable.
#
# A FAILURE TO PURGE STOPS THE INSTALL rather than letting it reach the
# confusing error. Purging needs directory rights the installer may not hold,
# and a person who cannot purge needs the command, not a mystery.
foreach ($wanted in @($ApiDisplayName, $DashboardDisplayName)) {
    $deleted = az rest --method GET --url "https://graph.microsoft.com/v1.0/directory/deletedItems/microsoft.graph.application?`$select=id,displayName" -o json 2>$null |
        ConvertFrom-Json
    $global:LASTEXITCODE = 0
    $tombstones = @($deleted.value | Where-Object { $_.displayName -eq $wanted })
    foreach ($t in $tombstones) {
        Write-Host "   removing a deleted registration still holding the name '$wanted'"
        az rest --method DELETE --url "https://graph.microsoft.com/v1.0/directory/deletedItems/$($t.id)" --output none 2>$null
        if ($LASTEXITCODE -ne 0) {
            $global:LASTEXITCODE = 0
            throw @"
A removed install left the name '$wanted' on a deleted registration, and this
account may not remove it permanently. Entra holds the name for 30 days, and
the install cannot create the registration until it is gone.

Ask a directory administrator to run:

  az rest --method DELETE --url https://graph.microsoft.com/v1.0/directory/deletedItems/$($t.id)

Or install with a different environment name, which gives every registration a
different name.
"@
        }
    }
}

$gateIsClosed = if ($apiSp) { [bool]$apiSp.appRoleAssignmentRequired } else { $false }
Write-Host "   sign-in gate currently: $(if ($gateIsClosed) { 'CLOSED - preserving it' } else { 'open' })"

# IDENTITY-4, 2026-09-11: the opt-in sign-in read (AuditLog.Read.All) was
# read and preserved here, the way the gate is. It went with the control that
# used it, so there is nothing to preserve - and one switch fewer to explain.
#
# A registration deployed BEFORE this still carries the scope. Redeploying
# takes it off, because the template no longer asks for it and the deployment
# is the whole set. That is the right direction: it is a permission nothing
# uses.

$params = @(
    "apiDisplayName=$ApiDisplayName"
    "dashboardDisplayName=$DashboardDisplayName"
    "registrationKey=$RegistrationKey"
    "requireAssignedRole=$($gateIsClosed.ToString().ToLower())"
)
if ($suffix) { $params += "baseSuffix=$suffix" }
$deployArgs = @('-g', $ResourceGroup, '--template-file', (Join-Path $PSScriptRoot 'identity.bicep'), '--parameters') + $params

Write-Host "identity -> '$ResourceGroup' (suffix: $(if ($suffix) { $suffix } else { 'derived by the template' }))"
if ($WhatIf) {
    $json = az deployment group what-if @deployArgs --no-pretty-print
    $changes = ($json | ConvertFrom-Json).changes
    $changes | Group-Object changeType | ForEach-Object { "$($_.Name): $($_.Count)" }
    $changes | ForEach-Object { "  [$($_.changeType)] $($_.resourceId)" }
}
else {
    # The deployment's OWN outputs, handed back to the caller. The API
    # registration's id used to be re-discovered afterwards by display name,
    # which is how an application somebody else owns could become the one the
    # facade trusts. identity.bicep already reports it: this is the source.
    $outputJson = az deployment group create @deployArgs --query properties.outputs -o json
    if ($LASTEXITCODE -ne 0) { throw 'identity deployment failed' }
    $outputs = if ($outputJson) { ([string]($outputJson | Out-String)).Trim() | ConvertFrom-Json } else { $null }
    $read = {
        param($Name)
        if ($outputs -and ($outputs.PSObject.Properties.Name -contains $Name)) { [string]$outputs.$Name.value } else { '' }
    }
    $apiAppId = & $read 'apiAppId'
    if (-not $apiAppId) {
        throw ("The identity deployment did not report apiAppId, the application id the service checks every " +
               'sign-in against. Deploy infra/identity.bicep again and read its apiAppId output.')
    }
    Write-Host 'identity deployed'
    [pscustomobject]@{
        ApiAppId              = $apiAppId
        DashboardAppId        = (& $read 'dashboardAppId')
        ApiServicePrincipalId = (& $read 'apiServicePrincipalId')
    }
}
