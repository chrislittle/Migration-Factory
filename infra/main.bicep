// INSTALL-1: the template `azd up` deploys, as an ORDINARY DEPLOYMENT at
// subscription scope. One resource group holds the platform, nothing wraps it,
// and nothing is protected from deletion - NO-STACKS-1, 2026-09-11, after
// three teardown failures in two days. A deployment stack held it from
// 2026-09-05 until then; see the note at the top of azure.yaml.
//
// Three things this template does NOT deploy, and why:
//   - the Entra registrations (infra/identity.bicep): an Entra object cannot
//     be deployed from here at all; the preprovision hook deploys them first
//     and passes the API id in;
//   - the engine image: built in the customer's registry by the
//     postprovision hook and pinned to the job by digest, adopted here on a
//     re-run (INSTALL-0 piece 4).
//   - the two custom roles (infra/roles.bicep): they live at the
//     SUBSCRIPTION and every install in it shares them (same ids, same
//     names), so a removal must never take them - another install still
//     needs them. The preprovision hook deploys them separately.
// Everything in this file is composition. The resource is platform.bicep,
// unchanged, so a hand deploy of it still matches.
targetScope = 'subscription'

@minLength(1)
@maxLength(40)
@description('Name of the azd environment. The resource group is named from it unless resourceGroupName says otherwise.')
param environmentName string

@minLength(1)
@description('Region for every resource. Must offer Container Apps with workload profiles - the readiness check says so before anything is created.')
param location string

@description('The resource group the platform lives in. One install per group. Empty names it after the environment.')
param resourceGroupName string = ''

// An explicit empty value (main.parameters.json passes the environment's
// AZURE_RESOURCE_GROUP, which the preprovision hook sets) must mean the
// default, not a resource group with no name.
var rgName = empty(resourceGroupName) ? 'rg-${environmentName}' : resourceGroupName

@description('''Application (client) id of the API registration the identity template created.
The preprovision hook deploys that registration and records this value.

IT HAS A DEFAULT, AND THE DEFAULT IS EMPTY ON PURPOSE. azd validates a
template's required parameters BEFORE it runs the preprovision hook, so a
parameter with no default made `azd up` fail in about twenty seconds - on a
value only that hook can produce. Measured 2026-09-08, with and without
--no-prompt, and it is why the one-command install had never worked.

Empty is never DEPLOYED: the hook sets it, and platform.bicep refuses an empty
value (EVAL-H13) rather than publishing a service with no sign-in.''')
param apiAppId string = ''

@description('''EASYAUTH-403-1: application (client) id of the vmf-dashboard registration, named in
the facade's authorization policy. EMPTY ON PURPOSE for the same reason apiAppId is - azd validates
this template's parameters BEFORE running the hook that produces the value. Empty is never deployed:
platform.bicep requires 36 characters and refuses it.''')
param dashboardAppId string = ''

@allowed([ 'Free', 'Basic' ])
@description('''WARM-1: ONE hosting choice, covering the dashboard AND the facade.

Free: App Service Free (F1) for the dashboard, Azure Functions Consumption (Y1) for the service.
Basic: one App Service Basic (B1) plan for both, with Always On.

(INSTALL-PLAN-WORDS-1: the same two sentences as the install question, and nothing more.)

Changing it later REPLACES the facade site: Azure does not move a function app between plan kinds,
so the site is created again under the new plan and its code published again by the hook. The facade
holds no state - every run lives in the store - so nothing is lost. The dashboard site moves plans
without being replaced.''')
param hostingPlan string = 'Free'

@description('The engine image the job runs. Empty on a fresh install (the platform template uses its placeholder); the postprovision hook records the built image so a re-run adopts it.')
param engineImage string = ''

@description('PUBLISH-IN-1 - the image the publish job runs. Empty means the placeholder, exactly like engineImage above.')
param publishImage string = ''

@description('Only to adopt a deployment whose suffix was chosen by hand. Empty derives it from the resource group.')
param baseSuffix string = ''

var tags = { 'azd-env-name': environmentName, project: 'vm-migration-factory' }

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: rgName
  location: location
  tags: tags
}

module platform 'platform.bicep' = {
  name: 'vmf-platform'
  scope: rg
  params: {
    apiAppId: apiAppId
    dashboardAppId: dashboardAppId
    hostingPlan: hostingPlan
    location: location
    // The platform's own defaults, restated here because a module parameter
    // cannot be left out conditionally: the placeholder image (INSTALL-0
    // piece 4) and the derived suffix (INSTALL-0 piece 1).
    engineImage: empty(engineImage) ? 'mcr.microsoft.com/k8se/quickstart-jobs:latest' : engineImage
    publishImage: empty(publishImage) ? 'mcr.microsoft.com/k8se/quickstart-jobs:latest' : publishImage
    baseSuffix: empty(baseSuffix) ? uniqueString(rg.id) : baseSuffix
  }
}

// Outputs land in the azd environment (.azure/<env>/.env) for the hooks.
output AZURE_RESOURCE_GROUP string = rg.name
output VMF_BASE_SUFFIX string = platform.outputs.baseSuffix
output VMF_STORE_ACCOUNT string = platform.outputs.storeName
output VMF_ACR_NAME string = platform.outputs.acrName
output VMF_ACR_LOGIN_SERVER string = platform.outputs.acrLoginServer
output VMF_FACADE_NAME string = platform.outputs.facadeName
output VMF_FACADE_URL string = platform.outputs.facadeUrl
output VMF_FACADE_ID string = platform.outputs.facadeResourceId
output VMF_DASHBOARD_NAME string = platform.outputs.dashboardSiteName
output VMF_DASHBOARD_URL string = platform.outputs.dashboardUrl
output VMF_ENGINE_JOB_NAME string = platform.outputs.engineJobName
output VMF_ENGINE_PRINCIPAL_ID string = platform.outputs.engineIdentityPrincipalId
output VMF_HOSTING_PLAN string = hostingPlan
