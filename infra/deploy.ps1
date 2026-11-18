<#
.SYNOPSIS
    Deploy the VMF platform template into a resource group.
.DESCRIPTION
    INSTALL-0. This script used to carry our lab as literals: its resource
    group, its suffix, a deploy principal's application id and the API
    registration's id. A customer running it would have deployed into our
    group with our names. Every one of those is now a parameter or is read
    from where it already lives.

    THE SUFFIX RULE (Resolve-VmfSuffix): an existing deployment's suffix wins,
    read from the vmfstate* account already in the group; a fresh group
    passes nothing and the template derives one from the resource group; a
    suffix given by hand is checked against what exists and a mismatch is a
    refusal, because deploying with a different suffix would create a second
    platform beside the first and report success.

    HOST-1: dashboardOrigin is not passed - it defaults inside the template
    to the App Service the template creates for the dashboard. Overriding it
    would point blob and facade CORS back at the storage endpoint.
.PARAMETER ResourceGroup
    The resource group to deploy into. It must exist.
.PARAMETER BaseSuffix
    Only to adopt a deployment whose suffix was chosen by hand. Leave it out
    everywhere else.
.PARAMETER ApiDisplayName
    The API registration whose id guards the facade. identity.bicep creates
    it; this script reads its id from the directory rather than carrying one.
.PARAMETER WhatIf
    Show what would change, and stop.
.EXAMPLE
    ./infra/deploy.ps1 -ResourceGroup <resource-group>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ResourceGroup,
    [Parameter()][string]$BaseSuffix,
    [Parameter()][string]$ApiDisplayName = 'vmf-api',
    [Parameter()][switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Resolve-VmfSuffix.ps1')
. (Join-Path $PSScriptRoot 'Resolve-VmfRegistration.ps1')
. (Join-Path $PSScriptRoot 'Set-VmfFacadeAdminIsolation.ps1')

$suffix = Resolve-VmfSuffix -ResourceGroup $ResourceGroup -BaseSuffix $BaseSuffix

# INSTALL-0 piece 4: one pass. The engine job is always deployed. An existing
# job keeps the image a publish pinned; a fresh install gets the placeholder
# from the template, and the first publish replaces it.
$engineImage = if ($suffix) { Resolve-VmfEngineImage -ResourceGroup $ResourceGroup -JobName "vmf-engine-$suffix" } else { '' }
$publishImage = if ($suffix) { Resolve-VmfPublishImage -ResourceGroup $ResourceGroup -JobName "vmf-publish-$suffix" } else { '' }

# The API app id comes from the directory, where identity.bicep put it -
# matched EXACTLY by name, because this id becomes clientId and
# allowedAudiences on the facade. It used to take the FIRST answer of a
# display-name lookup, and a display name is not unique in Entra: a
# registration any member of the tenant had made with the same name could
# become the application the facade validates every token against.
$apiApp = Get-VmfEntraApplication -DisplayName $ApiDisplayName
if (-not $apiApp) {
    throw ("The '$ApiDisplayName' registration does not exist, or this account may not read it. " +
           "Deploy the identity first: ./infra/identity-deploy.ps1 -ResourceGroup $ResourceGroup")
}
$apiAppId = [string]$apiApp.appId

# EASYAUTH-403-1: the facade's authorization policy names the dashboard, so
# this path needs its id too. DERIVED from the API's name rather than taken as
# another parameter: the pair is created together and named together
# ('vmf-api-<env>' / 'vmf-dashboard-<env>'), so a caller who overrides one and
# forgets the other would deploy a policy naming a registration that does not
# exist - and refuse every caller, which is the defect this fixes.
$dashboardName = $ApiDisplayName -replace '^vmf-api', 'vmf-dashboard'
$dashboardApp = Get-VmfEntraApplication -DisplayName $dashboardName
if (-not $dashboardApp) {
    throw ("The '$dashboardName' registration does not exist, or this account may not read it. " +
           "Deploy the identity first: ./infra/identity-deploy.ps1 -ResourceGroup $ResourceGroup")
}
$dashboardAppId = [string]$dashboardApp.appId

$params = @(
    "apiAppId=$apiAppId"
    "dashboardAppId=$dashboardAppId"
)
if ($suffix) { $params += "baseSuffix=$suffix" }
if ($engineImage) { $params += "engineImage=$engineImage" }
if ($publishImage) { $params += "publishImage=$publishImage" }
$deployArgs = @('-g', $ResourceGroup, '--template-file', (Join-Path $PSScriptRoot 'platform.bicep'), '--parameters') + $params

Write-Host "platform -> '$ResourceGroup' (suffix: $(if ($suffix) { $suffix } else { 'derived by the template' }))"
Write-Host "   engine image: $(if ($engineImage) { "kept as published ($engineImage)" } else { 'the placeholder, until the first publish' })"
Write-Host "   publish image: $(if ($publishImage) { "kept as published ($publishImage)" } else { 'the placeholder, until the first publish' })"
if ($WhatIf) {
    az deployment group what-if @deployArgs
    exit $LASTEXITCODE
}
$facadeId = [string](az deployment group create @deployArgs --query properties.outputs.facadeResourceId.value --output tsv)
if ($LASTEXITCODE -ne 0) { throw 'platform deployment failed' }
'platform deployed'

# FUNCTIONS-ADMIN-ISOLATION-1: the same step the azd install takes first.
# The template cannot close the /admin paths of the service; this does, and
# reads the value back (infra/Set-VmfFacadeAdminIsolation.ps1).
$facadeId = $facadeId.Trim()
if (-not $facadeId) { throw 'The deployment did not report facadeResourceId. The script cannot close the /admin paths of the service.' }
$closed = Set-VmfFacadeAdminIsolation -SiteId $facadeId
if ($closed -eq 'already') { 'The /admin paths of the service are closed. The script made no change.' } else { 'The script closed the /admin paths of the service.' }
