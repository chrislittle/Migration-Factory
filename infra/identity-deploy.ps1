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
    # Empty means "decide it here" (Resolve-VmfRegistrationKey): a new random
    # key, or a stop when a registration with either name exists. The template
    # never receives an empty key from this script.
    [Parameter()][string]$RegistrationKey = '',
    # INSTALL-PURGE-DELETED-1: the key was made in this run (preprovision's
    # Source 'new'), so no deleted registration can hold its unique names and
    # the deleted items are not read.
    [Parameter()][switch]$RegistrationKeyIsNew,
    # The application IDs recorded by the last install of this environment.
    # A live registration with its recorded ID means nothing to purge.
    [Parameter()][string]$RecordedApiAppId = '',
    [Parameter()][string]$RecordedDashboardAppId = '',
    [Parameter()][switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Resolve-VmfSuffix.ps1')
. (Join-Path $PSScriptRoot 'Resolve-VmfRegistration.ps1')

$suffix = Resolve-VmfSuffix -ResourceGroup $ResourceGroup -BaseSuffix $BaseSuffix

# INSTALL-ADOPT-OWNER-1: an EMPTY key made the uniqueName equal to the display
# name, which any member of the tenant can make first - and the template
# upserts by uniqueName, so it wrote this product's roles into their
# registration. A run with no key now takes the rule the azd install takes:
# a new random key when no registration has either name, else a stop before
# any change.
if (-not $RegistrationKey) {
    $registration = Resolve-VmfRegistrationKey -RecordedKey $RegistrationKey `
        -ApiDisplayName $ApiDisplayName -DashboardDisplayName $DashboardDisplayName
    $RegistrationKey = $registration.Key
    $RegistrationKeyIsNew = ($registration.Source -eq 'new')
    Write-Host "   registration key $RegistrationKey ($($registration.Source)). Give -RegistrationKey $RegistrationKey to every later run of this script."
}

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
# A REMOVED INSTALL LEAVES ITS UNIQUE NAMES BEHIND FOR 30 DAYS. MEASURED
# 2026-09-09: Entra SOFT-deletes an application and keeps its uniqueName for
# thirty days, and the Graph extension upserts by uniqueName - so a deployment
# that creates a uniqueName a deleted registration holds fails with:
#
#   InvalidDeployment ... The language expression property 'appId' doesn't exist
#
# which names appId, never the deleted object. The same measurement proved the
# display name is free: only the uniqueName collides.
#
# INSTALL-PURGE-DELETED-1: so the purge takes ONLY a deleted registration whose
# uniqueName is exactly the one this run creates ('<display name>-<key>'), never
# one matched by display name - that permanently deleted a deleted registration
# somebody else made. A new key cannot be held by any deleted registration, so
# nothing is read for it. A recorded key is read (a registration deleted by hand
# while the key stayed recorded). A failed read or purge STOPS the install with
# the command for a directory administrator (Clear-VmfDeletedRegistration).
# A what-if run removes nothing: a permanent delete is not a preview.
if ($WhatIf) {
    Write-Host '   what-if: no deleted registration is removed'
}
else {
    Clear-VmfDeletedRegistration -ApiDisplayName $ApiDisplayName -DashboardDisplayName $DashboardDisplayName -RegistrationKey $RegistrationKey -NewKey:$RegistrationKeyIsNew `
        -RecordedApiAppId $RecordedApiAppId -RecordedDashboardAppId $RecordedDashboardAppId
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
