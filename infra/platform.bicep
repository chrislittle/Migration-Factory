// PKG-1 / S3-3: the VMF standing platform as Bicep composed from Azure
// Verified Modules. One deployment = the whole platform a
// customer subscription needs, minus two deliberately script-managed pieces:
//   - the facade Function App (live Easy Auth config predates this template;
//     folding it in is the PKG-1 completion step - see Deploy-VmfFacade.ps1)
//   - storage static website + Entra app registrations (data-plane / Graph;
//     Deploy-VmfCockpit.ps1 and Deploy-VmfFacade.ps1 own them; Graph Bicep
//     extension adoption tracked in PKG-1)
// Deploy with what-if first: this template ADOPTS the existing store,
// workspace and App Insights by name.

@description('''Suffix shared by every platform resource name. DERIVED from the resource group by
default (INSTALL-0, 2026-09-04): a customer types nothing, the storage account and registry
names come out globally unique, and the same resource group always yields the same suffix - so
identity.bicep, deployed into the same group, agrees on the dashboard's address without being told.
Pass it only to adopt an existing deployment whose suffix was chosen by hand (infra/deploy.ps1
reads that from the store already in the group and refuses a mismatch).''')
param baseSuffix string = uniqueString(resourceGroup().id)

@description('''INSTALL-0 piece 4 - the image the engine job runs. The default is a PLACEHOLDER,
Microsoft's public sample job image, so the job can be created in the same pass as the registry that
will hold the real engine image: a job cannot exist without naming an image that exists. A job never
runs by itself - only the facade starts one, on an operator's request - so the placeholder never
executes. The first code publish replaces it with the engine image built in this registry, pinned by
digest, and every later publish does the same. A hand redeploy must NOT put the placeholder back:
infra/deploy.ps1 reads the job's current image and passes it here (Resolve-VmfEngineImage).''')
param engineImage string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'

@description('''PUBLISH-IN-1 - the image the publish job runs. A PLACEHOLDER by default, for the same
reason the engine's is: a job cannot be created naming an image that does not exist yet, and the
registry that will hold the real one is created in this same pass. The placeholder never executes -
this job runs only when a publish starts it. Every code publish builds the real image and points the
job at it by digest, and infra/deploy.ps1 reads the job's current image back so a hand redeploy does
not put the placeholder back.''')
param publishImage string = 'mcr.microsoft.com/k8se/quickstart-jobs:latest'

@allowed([ 'Free', 'Basic' ])
@description('''WARM-1: ONE choice covers the dashboard AND the facade, because there was never a
second answer worth giving.

Free: App Service Free (F1) for the dashboard, Azure Functions Consumption (Y1) for the service.
Basic: one App Service Basic (B1) plan for both, with Always On.

(INSTALL-PLAN-WORDS-1: the same two sentences as the install question.)

Why one plan holds both. Microsoft: "One or more function apps can be
configured to run on the same computing resources (App Service plan) as other App Service apps, such
as web apps", and "You're billed only for the plan, regardless of how many function apps or web apps
run in the plan" (azure-functions/dedicated-plan, read 2026-09-19). So one plan holds both, and Azure
bills it once - TWO plans would buy nothing extra.

Sharing is only possible at Basic. The same page: "Azure Functions doesn't support Free and Shared
tier App Service plans", so the dashboard's F1 plan could never have held the facade.

Azure does not move a function app between plan kinds, so the FACADE SITE carries the kind in its
name when Basic is chosen: changing the choice later builds a new site and the hook publishes the
code to it. The facade holds no state - every run lives in the store - so nothing is lost. The
DASHBOARD site does move, because both its plans are ordinary Windows plans.

NO-STACKS-2: there is no deployment stack, and nothing deletes what the old choice left behind - THE
OLD SITE AND PLAN STAY, and a Basic plan left behind keeps billing. Delete them by hand after the
change.''')
param hostingPlan string = 'Free'

// Built-in role ids, by id rather than by name so the grant is exactly what it says.
// EASYAUTH-403-1: the Azure CLI's own application id, first-party and the same
// in every tenant. identity.bicep pre-authorises it on the API scope, and the
// facade's authorization policy names it, so tools/Test-VmfHealth.ps1 can ask
// the service a question AS THE OPERATOR. The two files must agree.
var azCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
var roleReader = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
// PIPELINE-LATER-1 (2026-11-02): a person runs every update, so no
// role here goes to a pipeline identity. The roles a pipeline held - push and
// build on the registry, jobs contributor, website contributor, reader, and
// the constrained right to grant roles (CD-2 stage A) - are gone with the
// deployPrincipalId parameter. DIST-2 and CD-2 stage B bring them back after
// 1.0, and docs/later/pipeline keeps the page that set one up.
var roleBlobContributor = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'
var roleBlobOwner = 'b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
// CODE-CONTAINER-WRITE-1: the service reads its own program code and may not
// write it.
var roleBlobReader = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var roleQueueContributor = '974c5e8b-45b9-4653-ba55-5f855dd0fb88'
var roleTableContributor = '0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
var roleAcrPull = '7f951dda-4ed3-4680-a7ca-43fe172d538d'
var roleContributor = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
// STORE-LOGS-TELEMETRY-1: Monitoring Metrics Publisher, for the facade on its
// own Application Insights component only.
var roleMetricsPublisher = '3913510d-42f4-4e42-8a64-420c390055eb'

@description('''EVAL-H13: application (client) id of the vmf-api Entra registration that guards
the facade. REQUIRED - it used to default to empty, which made the entire Easy Auth block
conditional and produced an internet-reachable migration control plane with no authentication
at all: every function is authLevel anonymous, and the only identity check in code decodes the
x-ms-client-principal header without verifying who sent it. Anyone could have forged it and
approved a wave, started it against production machines, or discarded a run with its safety
copies. The "first pass with no registration yet" this default existed for is not real:
identity.bicep needs only the dashboard origin, which is computable from baseSuffix, so it can
and must be deployed first.''')
@minLength(36)
param apiAppId string

@description('''EASYAUTH-403-1: application (client) id of the vmf-dashboard registration. It is
named in the facade's authorization policy, so only the dashboard and the Azure CLI may call the
service. REQUIRED, and for the same reason apiAppId is: an empty value would produce
allowedApplications: [''], which is a NON-EMPTY list matching nothing - every caller refused, which
is the defect this parameter exists to fix. main.bicep carries the empty default that azd needs
before its hooks run; this template refuses it.''')
@minLength(36)
param dashboardAppId string

@description('Tenant id issuing tokens for the facade (defaults to this subscription tenant)')
param tenantId string = subscription().tenantId

@description('''HOST-1: origin the dashboard is served from, used for blob and facade CORS.
Defaults to the App Service this template now creates for it. Override only to serve the
dashboard from somewhere else - the default is the supported path.''')
param dashboardOrigin string = 'https://vmf-dash-${baseSuffix}.azurewebsites.net'

param location string = resourceGroup().location

var tags = { 'vmf-persistent': 'true', project: 'vm-migration-factory' }
var storeName = 'vmfstate${baseSuffix}'
var facadeName = 'vmf-facade-${baseSuffix}'
var facadePlanName = 'vmf-facade-plan-${baseSuffix}'
var warm = hostingPlan == 'Basic'
// WARM-1: one plan holds both apps when the answer is Basic, so the name says
// what it is rather than which app asked for it.
//
// Empty on a Free install, which builds no shared plan.
var sharedPlanName = warm ? 'vmf-plan-b1-${baseSuffix}' : ''
// INSTALL-1 decision 3: a Basic facade is a different SITE, named for the
// kind, so the choice can change without an impossible move (Azure does not
// move a function app between plan kinds). The literals above stay the Free
// names.
var facadeSiteName = warm ? 'vmf-facade-b1-${baseSuffix}' : facadeName
var facadeHostingPlanName = warm ? sharedPlanName : facadePlanName
var acrName = 'vmfacr${baseSuffix}'
var dashboardName = 'vmf-dash-${baseSuffix}'
// NAME-3: these four carried no baseSuffix while every other
// resource did. Harmless across separate resource groups, but two installs in
// ONE group would collide - and dev/test/prod sharing a group is a normal
// customer shape. Fixed here so NEW installs are correct.
// MIGRATING AN EXISTING DEPLOYMENT IS NOT A RENAME: a renamed managed
// identity is a NEW principal, so every role assignment it holds must be
// re-granted, and a renamed workspace abandons its telemetry history. See
// NAME-3 in the backlog for the one-way migration.
var logsName = 'vmf-logs-${baseSuffix}'
var engineIdentityName = 'vmf-engine-mi-${baseSuffix}'
var acaEnvName = 'vmf-aca-env-${baseSuffix}'
var engineJobName = 'vmf-engine-${baseSuffix}'
// PUBLISH-IN-1: the job that puts the service's code in the store, and the
// identity it runs as. Separate from the engine's on purpose - the engine
// reads and writes every migration record, and this holds one data role on one
// container.
var publishJobName = 'vmf-publish-${baseSuffix}'
// NSP-3: the perimeter around the run store, and the profile inside it that
// carries the one rule. Since 2026-09-10 the NSP is part of the stack: this is
// one solution, removed when the migration is done, so the perimeter is
// created, associated and removed with everything else rather than left to a
// platform team.
var nspName = 'vmf-nsp-${baseSuffix}'
var nspProfileName = 'run-store'
var publishIdentityName = 'vmf-publish-mi-${baseSuffix}'
// Computed rather than referenced: the facade needs the job's id for its
// settings, and the job needs the facade's identity for its role assignment.
// Referencing both ways is a cycle; the name is fixed, so the id is knowable.
var engineJobResourceId = resourceId('Microsoft.App/jobs', engineJobName)
// PREVIEW-1: what-if SKIPS a nested deployment whose parameters carry an
// unresolved reference(), and `module.outputs.x` compiles to exactly that. So
// every module here that took an id from another module was invisible to a
// preview - seven of them, including the store and the facade, which is to say
// the parts of a deploy most worth seeing before it runs.
//
// The ids below are computed from names this template already owns, which
// resolve at what-if time, and the ordering that the output reference used to
// imply is kept with an explicit dependsOn. That is not a new trick here: the
// job's id above, and the store's, were already computed this way to break
// cycles. A principal id cannot be computed - it exists only once Azure has
// created the identity - so the modules whose parameters carry one still skip,
// and those are named in PREVIEW-1 in the backlog.
var logsResourceId = resourceId('Microsoft.OperationalInsights/workspaces', logsName)
var facadeResourceId = resourceId('Microsoft.Web/sites', facadeSiteName)
// WARM-1: the same plan as the facade when the answer is Basic. The dashboard
// SITE keeps its name either way - both plans are ordinary Windows plans, and
// Azure moves a web app between them.
var dashboardFreePlanName = 'vmf-dash-plan-${baseSuffix}'
var dashboardPlanName = warm ? sharedPlanName : dashboardFreePlanName
var dashboardPlanResourceId = resourceId('Microsoft.Web/serverfarms', dashboardPlanName)
var facadeHostingPlanResourceId = resourceId('Microsoft.Web/serverfarms', facadeHostingPlanName)
var acaEnvResourceId = resourceId('Microsoft.App/managedEnvironments', acaEnvName)
var engineIdentityResourceId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', engineIdentityName)
// Computed from the name, like the ids above and for the same reason: an
// output reference here would make the perimeter invisible to what-if
// (PREVIEW-1), and the perimeter is the single most useful thing to see in a
// preview - it decides what can reach the store.
var storeResourceId = resourceId('Microsoft.Storage/storageAccounts', storeName)
var publishIdentityResourceId = resourceId('Microsoft.ManagedIdentity/userAssignedIdentities', publishIdentityName)
var acrLoginServer = '${acrName}${environment().suffixes.acrLoginServer}'
// Same reason: the store grants the facade's identity access, so the facade
// cannot also reference the store module without forming a cycle.

module logs 'br/public:avm/res/operational-insights/workspace:0.16.1' = {
  name: 'vmf-logs-deploy'
  params: {
    name: logsName
    location: location
    tags: tags
    dataRetention: 30
    dailyQuotaGb: '0.2'   // hard ingestion cap - bounded telemetry cost (AVM types this as string)
    // ADOPTION PIN (what-if caught this): the AVM default disables key-based
    // ingestion, and the Container Apps environment ships its console logs
    // using exactly that shared key. Taking the default would silently kill
    // engine logging - the same failure the S3-7 drill already hit once.
    features: {
      disableLocalAuth: false
    }
  }
}

module appInsights 'br/public:avm/res/insights/component:0.8.0' = {
  name: 'vmf-ai-deploy'
  params: {
    name: facadeName
    location: location
    tags: tags
    workspaceResourceId: logsResourceId
    retentionInDays: 90
    // STORE-LOGS-TELEMETRY-1: Entra sign-in only. MEASURED on the lab install,
    // 2026-11-06, in the perimeter's access log: the perimeter refused
    // telemetry/write from the facade, sent with the connection string's
    // instrumentation key and no identity, while every store call of the same
    // facade, signed with its managed identity, was admitted. The facade signs
    // its telemetry now (APPLICATIONINSIGHTS_AUTHENTICATION_STRING in
    // facade-appsettings.bicep, and facadeTelemetryPublisher below), as
    // infra/ci-schedule/ci-starter.bicep already does. The WORKSPACE keeps its
    // key: see the pin on module logs.
    //
    // Signing was not enough while the workspace was in the perimeter: after
    // azd up of this change (lab, 2026-11-06) the perimeter still refused the
    // facade's telemetry/write with an EMPTY SourceAppId. It arrived only once
    // the workspace left the perimeter (STORE-LOGS-WORKSPACE-PERIMETER-1).
    // Kept: the component takes no key, and the data that arrived came signed.
    disableLocalAuth: true
  }
  // PREVIEW-1: the id above is computed, so the ordering the output reference
  // used to imply is stated here instead.
  dependsOn: [ logs ]
}

// STORE-LOGS-TELEMETRY-1: the facade's system-assigned identity may send
// telemetry to its own component - Monitoring Metrics Publisher, scoped to that
// one component, as ci-starter.bicep grants it. A resource here rather than an
// entry in the component module's roleAssignments: the facade already depends
// on the component, so the component cannot name the facade's identity
// without a cycle.
//
// The name holds the site's id: a change of hosting plan (WARM-1) makes a new
// site with a new identity, and so a new assignment rather than a refused
// update of the old one.
//
// KNOWN LIMIT, the same as ci-starter.bicep: the name holds no principal id,
// because bicep needs the name when the deployment starts and the identity
// exists only after the site does. So if the facade site is deleted and made
// again under the same name, its new identity gets
// RoleAssignmentUpdateNotPermitted on this assignment. Remove the old
// assignment first, then deploy again.
resource facadeTelemetryComponent 'Microsoft.Insights/components@2020-02-02' existing = {
  name: facadeName
}

resource facadeTelemetryPublisher 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(facadeTelemetryComponent.id, facadeResourceId, roleMetricsPublisher)
  scope: facadeTelemetryComponent
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleMetricsPublisher)
    principalId: facade.outputs.systemAssignedMIPrincipalId!
    principalType: 'ServicePrincipal'
  }
  dependsOn: [ appInsights ]
}

module engineIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'vmf-engine-mi-deploy'
  params: {
    name: engineIdentityName
    location: location
    tags: tags
  }
}

// PUBLISH-IN-1: who the publish job is. It exists to hold ONE data role on ONE
// container, so it is its own principal rather than a second hat on the
// engine's - an identity that can both publish code and read every migration
// record is a bigger thing than either job needs.
module publishIdentity 'br/public:avm/res/managed-identity/user-assigned-identity:0.6.0' = {
  name: 'vmf-publish-mi-deploy'
  params: {
    name: publishIdentityName
    location: location
    tags: tags
  }
}

module store 'br/public:avm/res/storage/storage-account:0.33.1' = {
  name: 'vmf-store-deploy'
  params: {
    name: storeName
    location: location
    tags: tags
    skuName: 'Standard_LRS'
    kind: 'StorageV2'
    // NSP-5: the perimeter reports MissingIdentityConfiguration against the
    // store without this. Microsoft's rule, in their own words: "Managed
    // identity needs to be assigned on resources for perimeter access" -
    // perimeter access being traffic between two resources INSIDE the same
    // perimeter.
    //
    // This perimeter holds one resource, and nothing this product runs on can
    // be a member of it (the note above the perimeter module says why), so
    // there is no such traffic today and nothing is blocked. The identity is
    // here because an unresolved issue on an ENFORCED perimeter is noise that
    // hides the next one, and because a customer may put more in the
    // perimeter than we do.
    //
    // It grants nothing. An identity with no role assignment can reach no
    // resource, and none is given to it anywhere in this template.
    managedIdentities: {
      systemAssigned: true
    }
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    // SEC-1: nothing uses a shared key against the run store - the engine and
    // the service sign in with their managed identities, the dashboard with
    // the viewer's own token, the uninstall with --auth-mode login, and the
    // publish uploads the code package with --auth-mode login too. Refusing
    // keys outright means there is no key for a leaked app setting or
    // deployment record to carry.
    //
    // This holds only because the facade has no Azure Files content share:
    // that share cannot be reached by identity, and it is the one thing that
    // forced a key onto this account. NOFILES-1, beside
    // WEBSITE_RUN_FROM_PACKAGE below, records how that was removed and what
    // it costs. Do not reintroduce a content share here without reading it.
    allowSharedKeyAccess: false
    // Adoption-safe pins (what-if caught all three): AVM defaults would flip
    // the ACL to Deny (breaking every consumer), and infrastructure
    // encryption is immutable after creation.
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
    requireInfrastructureEncryption: false
    // CODE-CONTAINER-WRITE-1: EVERY BLOB DATA ROLE IS GRANTED ON A CONTAINER,
    // NEVER ON THIS ACCOUNT. The account holds the service's program code
    // (vmf-deploy/facade.zip, fetched by the Functions host on every start).
    // The engine held Storage Blob Data Contributor and the service Storage
    // Blob Data Owner on the whole account, so either could overwrite the code
    // the service runs - the engine runs every migration and holds the
    // migration role over customer machines. A write it made to facade.zip
    // would run as the service at its next start. Now only the publish job
    // can write vmf-deploy, the service can only read it, and the engine
    // cannot reach it. tests/unit/CodeContainerWrite.Tests.ps1 reads the
    // compiled template and fails on a blob role granted on the account.
    blobServices: {
      containers: [
        {
          // The records. The engine and the service read and write them;
          // both use only this container (VMF_STORE_CONTAINER below).
          // Contributor is the whole of what the store code needs: the engine
          // has done all of it with Contributor since the first install.
          name: 'vmf-runs'
          roleAssignments: [
            {
              principalId: engineIdentity.outputs.principalId
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: roleBlobContributor
            }
            {
              principalId: facade.outputs.systemAssignedMIPrincipalId!
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: roleBlobContributor
            }
          ]
        }
        {
          // The Functions host's own data: locks, timer status and the host
          // id here, its keys in azure-webjobs-secrets. Microsoft gives
          // Storage Blob Data Owner for an identity-based AzureWebJobsStorage
          // (Configure connections to remote services in Azure Functions,
          // Host required). The template makes both containers, so the host
          // never has to create one, and the role stops at each container.
          name: 'azure-webjobs-hosts'
          roleAssignments: [
            {
              principalId: facade.outputs.systemAssignedMIPrincipalId!
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: roleBlobOwner
            }
          ]
        }
        {
          name: 'azure-webjobs-secrets'
          roleAssignments: [
            {
              principalId: facade.outputs.systemAssignedMIPrincipalId!
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: roleBlobOwner
            }
          ]
        }
        {
          // NOFILES-1: the facade's code, as a zip the Functions host fetches
          // with its own identity. See WEBSITE_RUN_FROM_PACKAGE below.
          name: 'vmf-deploy'
          // The publish job writes the code package HERE and nowhere else,
          // and it is the ONLY thing that does (PUBLISH-IN-1). The grant is
          // scoped to this container rather than the account for the reason
          // the store's own role list gives: an account-wide data role would
          // let the thing that publishes code read every plan, approval,
          // machine state and safety copy record in vmf-runs. The person
          // installing holds no data role on this account, which is what
          // lets the install work against a store that admits nothing from
          // outside the subscription.
          roleAssignments: [
            {
              principalId: publishIdentity.outputs.principalId
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: roleBlobContributor
            }
            {
              // CODE-CONTAINER-WRITE-1: the host fetches facade.zip with the
              // service's identity (WEBSITE_RUN_FROM_PACKAGE). Read, never
              // write: the service may not change the code it runs.
              principalId: facade.outputs.systemAssignedMIPrincipalId!
              principalType: 'ServicePrincipal'
              roleDefinitionIdOrName: roleBlobReader
            }
          ]
        }
      ]
      // STORE-READ-1: the blob CORS rules were here and are gone. They
      // existed so a BROWSER could read this account; nothing in a browser
      // reaches it now. The facade reads it from inside Azure, which is not a
      // cross-origin request and was never covered by these rules. The
      // dashboard's own CORS, on the facade below, is a different setting and
      // stays.
      //
      // STORE-LOGS-REQUEST-LOG-2: NO request log in 1.0 (2026-11-06: the run
      // store request log is dropped for 1.0). STORE-LOGS-1 sent
      // writes and deletes to the workspace, and measured that a setting to a
      // workspace outside the store's perimeter sends nothing (no row in 21
      // hours, 2026-11-03). The workspace left the perimeter
      // (STORE-LOGS-WORKSPACE-PERIMETER-1), so no setting is made. After 1.0
      // the log goes to a small log storage account inside the perimeter; a
      // storage account's logs cannot go to the same account.
    }
    // The account-wide roles are the queue and table roles of an identity-based
    // AzureWebJobsStorage (SEC-1), for the service's own identity. Neither
    // reaches a blob. The blob roles are on the containers above
    // (CODE-CONTAINER-WRITE-1): never add one here.
    roleAssignments: [
      {
        principalId: facade.outputs.systemAssignedMIPrincipalId!
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleQueueContributor
      }
      {
        principalId: facade.outputs.systemAssignedMIPrincipalId!
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleTableContributor
      }
    ]
  }
}

/* NSP-3: THE PERIMETER. What makes this product work against a store nothing
 * outside Azure may reach.
 *
 * THE PROBLEM IT SOLVES. A corporate policy with the modify effect forces
 * `publicNetworkAccess: Disabled` on every storage account as it is created,
 * and clears `bypass` to `None` with it. The template asks for neither; the
 * policy wins, silently, on every deployment (POLICY-REVERT-1). With the store
 * closed, nothing on the public path reaches it - not the install, not the
 * service, not the engine.
 *
 * WHAT WAS MEASURED (NSP-1, and independently in a second, corporate
 * subscription). A subscription-based INBOUND rule admits all three services
 * this product runs on - the Container Apps job, the Function App and the Web
 * App - even though none of them can be a perimeter MEMBER. The negative
 * control is what makes it proof: removing the rule blocked every one of them
 * again.
 *
 * WHY IT COULD NOT LAND UNTIL NOW. A subscription rule admits things IN the
 * subscription. It can never admit a laptop or a browser, so every part of
 * this product that touched the store from outside Azure had to go first:
 * the dashboard's blob reads (STORE-READ-1), the person's and the pipeline's
 * data roles (STORE-READ-1 part 2), the code upload (PUBLISH-IN-1) and the
 * teardown hook's status read (FIND-COPY-1). There are none left.
 *
 * ENFORCED, not Audit. Audit reports what would be blocked and blocks nothing,
 * which is a setting that looks like protection and is not. The rule was
 * measured working before this shipped.
 *
 * ONE PERIMETER PER RESOURCE. Azure associates a resource with one perimeter
 * profile at a time, so this takes the store. A customer whose platform team
 * wants the store inside THEIR perimeter has to remove this association first -
 * said in the manual, because the error if they do not is about the
 * association and names nothing of ours.
 */
module perimeter 'br/public:avm/res/network/network-security-perimeter:0.1.4' = {
  name: 'vmf-nsp-deploy'
  params: {
    name: nspName
    location: location
    tags: tags
    profiles: [
      {
        name: nspProfileName
        accessRules: [
          {
            // THE ONE RULE. Everything this product runs on is in this
            // subscription, and nothing else needs in.
            //
            // Read from the deployment, never a parameter: a perimeter that
            // admits a subscription somebody typed is a perimeter that admits
            // the wrong one the first time somebody copies a parameter file.
            //
            // `subscription().id` - THE FULL RESOURCE ID - and not
            // `.subscriptionId`, which is the bare GUID. NSP-3 shipped the
            // bare one and every install failed:
            //
            //   LinkedInvalidPropertyId: Property id 'cccc0c0c-...' at path
            //   'properties.subscriptions[0].id' is invalid. Expect fully
            //   qualified resource Id that start with '/subscriptions/...'
            //
            // MEASURED on the first lab azd up after NSP-3, 2026-09-11.
            // The unit test could not catch it: it asserted the expression the
            // template contained, which was the wrong expression. Only ARM
            // knows this shape, so the test now asserts the shape ARM wants.
            name: 'allow-this-subscription'
            direction: 'Inbound'
            subscriptions: [
              { id: subscription().id }
            ]
          }
        ]
      }
    ]
    resourceAssociations: [
      {
        name: 'run-store'
        privateLinkResource: storeResourceId
        profile: nspProfileName
        accessMode: 'Enforced'
      }
    ]
    // STORE-LOGS-WORKSPACE-PERIMETER-1: the Log Analytics workspace is NOT
    // associated. STORE-LOGS-NSP-1 put it here, Enforced, so the store's
    // request log would reach it. MEASURED on the lab install, 2026-11-06:
    // with it here, the perimeter refused the facade's telemetry/write on the
    // workspace (NspPublicInboundPerimeterRulesDenied, an EMPTY SourceAppId)
    // even after the facade signed its telemetry with its managed identity, and
    // AppRequests stayed empty; a person's log query was refused too. With the
    // association deleted, AppRequests and AppTraces arrived within a minute.
    // Since 2026-11-06 the workspace stays outside the perimeter.
  }
  // The association names the store, so it has to exist. The id above is
  // computed rather than referenced, so that ordering is stated here.
  dependsOn: [ store ]
}

module acr 'br/public:avm/res/container-registry/registry:0.13.1' = {
  name: 'vmf-acr-deploy'
  params: {
    name: acrName
    location: location
    tags: tags
    acrSku: 'Basic'
    acrAdminUserEnabled: false   // zero-secrets: OIDC pushes, MI pulls
    roleAssignments: [
      {
        principalId: engineIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleAcrPull
      }
      {
        // PUBLISH-IN-1: the publish job pulls the image that carries the
        // package it uploads
        principalId: publishIdentity.outputs.principalId
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleAcrPull
      }
    ]
  }
}

module acaEnv 'br/public:avm/res/app/managed-environment:0.16.0' = {
  name: 'vmf-aca-env-deploy'
  params: {
    name: acaEnvName
    location: location
    tags: tags
    zoneRedundant: false
    // SCALE-UX-1 ceiling, measured 2026-09-04: with NO workload profiles this
    // is a "Consumption only" environment - the kind Microsoft's own page
    // now calls legacy - and one container there gets at most 2 CPU and
    // 4 GiB, so at most 10 machines at once. The Consumption workload
    // profile (the default kind) allows 4 CPU and 8 GiB a replica, costs
    // nothing extra, and lets a wave run 20 at once. The Container Apps docs
    // say workload profiles allow more than 2 CPU and 4 GiB (2026-09-04).
    // An existing Consumption-only environment cannot be changed into this
    // kind: it is deleted and made again (the job with it).
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
    // Console-log ingestion needs the workspace SHARED KEY, which ARM GET
    // never returns; the AVM module resolves it from this resource id at
    // deploy time. If ContainerAppConsoleLogs is ever empty (found by the
    // S3-7 smoke), re-wire the key: PATCH the environment's
    // appLogsConfiguration.logAnalyticsConfiguration {customerId, sharedKey}
    // via ARM, or simply redeploy this template.
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsWorkspaceResourceId: logsResourceId
    }
    // SCALE-2: the facade reads the environment's Consumption cores in use
    // and their limit (its /usages), so the wave editor can say whether a
    // wave's containers fit before anyone starts it. A read, nothing more.
    roleAssignments: [
      {
        principalId: facade.outputs.systemAssignedMIPrincipalId!
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleReader
      }
    ]
  }
  // PREVIEW-1: the ids this module needs are computed from names now, so the
  // ordering the output references used to imply is stated here instead.
  dependsOn: [ logs ]
}

// The facade: the small REST surface the dashboard calls. Consumption plan,
// so it costs nothing while idle. Its Easy Auth is configured here rather
// than by a script - an unauthenticated request must be refused by the
// platform, never by application code.
// HOST-1: the dashboard is a real web host, not a storage account pretending
// to be one. Storage static websites CANNOT serve response headers at all -
// no Content-Security-Policy, no HSTS - and the dashboard holds an access
// token in browser memory, so that mattered. App Service also keeps the whole
// thing templatable: the site and its config deploy from here, and the content
// ships with the same zip mechanism the facade already uses. F1 is free; the
// limits (no custom-domain SSL, no SLA, 60 CPU-minutes a day) are ample for
// serving five static pages to an operations team, and B1 is the upgrade path
// if a custom domain is ever wanted.
//
// WARM-1: this is the SHARED plan when the answer is Basic. The dashboard site
// and the facade site both sit on it, and Azure bills the plan once.
module dashboardPlan 'br/public:avm/res/web/serverfarm:0.7.0' = {
  name: 'vmf-dash-plan-deploy'
  params: {
    name: dashboardPlanName
    location: location
    tags: tags
    // WARM-1: F1 cannot be made warm and cannot hold a function app at all, so
    // Basic is where one plan starts to serve both. B1 is the FIRST tier that
    // offers Always On - Premium v3/v4 adds scale-out, VNet integration and
    // zone redundancy, none of which this product uses, for two to four times
    // the price of the same warm app.
    skuName: warm ? 'B1' : 'F1'
    // Stays 'windows' when it holds the facade too. A plan's kind is what the
    // portal groups by; what Azure enforces for a function app is the SKU, and
    // Free and Shared are the two it refuses.
    kind: 'windows'
    // ADOPTION TRAP, caught by what-if against the live lab 2026-09-07: the
    // module's own default is 3, "to leverage availability zones" - an
    // assumption for a production dedicated plan. A Free plan runs one
    // instance and cannot scale out, and Azure reports its capacity as 0, so
    // leaving the default asserted 0 => 3 on every deploy of a plan that
    // cannot honour it. Stated here so the template says what the plan is.
    // B1 runs real workers, and one is what these two apps need.
    skuCapacity: warm ? 1 : 0
  }
}

module dashboard 'br/public:avm/res/web/site:0.24.0' = {
  name: 'vmf-dash-deploy'
  params: {
    name: dashboardName
    location: location
    tags: tags
    kind: 'app'
    serverFarmResourceId: dashboardPlanResourceId
    // DRIFT-3: the same setting, stated for the same reason. This host serves
    // static files and the browser carries the person's own token, so there is
    // no session to be sticky to - the affinity cookie is cost with no use.
    // This one is a real change: the deployed site has it on.
    clientAffinityEnabled: false
    httpsOnly: true
    siteConfig: {
      // WARM-1: F1 does not support alwaysOn and setting it true FAILS THE
      // DEPLOYMENT, so this follows the plan rather than being hard false.
      // On B1 it is what stops the dashboard unloading after a quiet period.
      alwaysOn: warm
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      defaultDocuments: [ 'index.html' ]
      // The dashboard host had NO telemetry when it was first
      // created. For a site of static files the useful signal is the web
      // server's own logs, not code instrumentation - when this host returned
      // HTTP 500 on every request after its first deployment, there was
      // nothing to look at and the cause had to be found by bisection.
      detailedErrorLoggingEnabled: true
      httpLoggingEnabled: true
      requestTracingEnabled: true
    }
    // DIAG-1 ASKED FOR DIAGNOSTIC SETTINGS HERE AND THEY CANNOT EXIST.
    //
    // This plan is F1 - free - always, and a free App Service supports NO
    // diagnostic categories at all. Azure refuses the whole stack:
    //   BadRequest: Category 'AppServiceHTTPLogs' is not supported.
    //
    // It never showed until 2026-09-08 because the lab's platform is
    // hand-deployed and nobody re-ran it after DIAG-1 added this. MEASURED on
    // the live sites: `az monitor diagnostic-settings categories list` returns
    // an EMPTY list for both the F1 dashboard and the Y1 facade, and neither
    // site carries a single diagnostic setting. The block has never deployed.
    //
    // The dashboard is five static pages. It has NO Easy Auth of its own -
    // measured 2026-09-09: platform.enabled is false and globalValidation is
    // null on the deployed site, and this template configures authsettingsV2
    // for the facade only. An earlier version of this comment said "behind
    // Easy Auth", which was wrong: the PAGES are public, and every byte of
    // DATA is behind the facade, which does enforce it (EVAL-H13 below).
    //
    // That is the ordinary shape for a single-page app, and it is why the
    // record DIAG-1 wanted - that somebody reached the front door - is the
    // FACADE'S AppServiceAuthenticationLogs, where sign-in is actually
    // enforced, kept below on the plan that supports it.
  }
  // PREVIEW-1: the ids this module needs are computed from names now, so the
  // ordering the output references used to imply is stated here instead.
  dependsOn: [ dashboardPlan, logs ]
}

/* WARM-1: the facade has a plan of its OWN only when the answer is Free.
 *
 * Basic puts it on the dashboard's plan, which is the whole saving: two Basic
 * plans would cost about $110 a month to deliver exactly what one delivers for
 * $55. Deploying this module as well would build a second plan nothing sits
 * on, and bill for it.
 *
 * facadeHostingPlanResourceId is computed from the NAME, so the facade site
 * below needs no change - the name already points at the shared plan when the
 * answer is Basic.
 */
module facadeHostingPlan 'br/public:avm/res/web/serverfarm:0.7.0' = if (!warm) {
  name: 'vmf-facade-plan-deploy'
  params: {
    name: facadeHostingPlanName
    location: location
    tags: tags
    skuName: 'Y1'                                 // Y1 = consumption
    // The live plan is 'functionapp', which is what a plan hosting a function
    // app is; 'windows' was asserting a change to a running plan for nothing.
    /* DRIFT-3, SETTLED BY DEPS-CURRENT-1 part 4. Azure stores the plan's kind
     * lower case ('functionapp'). Up to serverfarm 0.4.1 the module's kind
     * parameter admitted only 'functionApp', so every drift preview reported
     * `kind: functionapp -> functionApp` and no deploy settled it. From 0.7.0
     * the parameter takes the kind Azure takes, so the template now states it
     * as Azure stores it. Azure treats kind case-insensitively, so the plan
     * does not change.
     */
    kind: 'functionapp'
    // The same adoption trap as the dashboard's plan. Consumption capacity is
    // the platform's to decide and reads as 0.
    skuCapacity: 0
  }
}

module facade 'br/public:avm/res/web/site:0.24.0' = {
  name: 'vmf-facade-deploy'
  params: {
    name: facadeSiteName
    location: location
    tags: tags
    kind: 'functionapp'
    serverFarmResourceId: facadeHostingPlanResourceId
    /* DRIFT-3: ARR affinity OFF, stated rather than inherited.
     *
     * This template did not state it, so the module's own default - true -
     * applied. The running facade has it FALSE, which is correct, so nothing
     * had gone wrong yet; the next deploy of this template would have turned
     * sticky-session cookies ON for the migration control plane, pinned every
     * caller to one instance and worked against scale-out on Consumption.
     *
     * Found by the first honest drift preview, which is the entire argument
     * for DRIFT-2: the job could not report truthfully before, so this sat
     * here unseen.
     */
    clientAffinityEnabled: false
    managedIdentities: {
      systemAssigned: true
    }
    siteConfig: union(
      {
        powerShellVersion: '7.6'        // enforced every deploy: an EOL runtime
        minTlsVersion: '1.2'            // is a finding, not a footnote
        ftpsState: 'Disabled'
        // Always On is what makes Basic "always warm"; Consumption refuses it.
        alwaysOn: warm
        cors: {
          allowedOrigins: [ dashboardOrigin ]
          supportCredentials: false
        }
      },
      /* FACADE-QUEUE-1: on Consumption, ONE instance - the warm one.
       *
       * MEASURED 2026-11-08 on the lab install (Application Insights, 7 days):
       * 164 facade instances started, and 131 of them started within a minute
       * of a request another instance served - Consumption scaled OUT during an
       * operator's session. Each new process loads the modules (2-4 s) and signs
       * in as the managed identity (5-8 s) before the first function body runs,
       * so the requests around a new instance took p50 7.6 s and p90 25 s. That
       * is most of why the Migrations page was slow to load.
       *
       * The schedule timer runs every 5 minutes, so the one instance stays
       * started; a page request goes to a process that is already loaded.
       *
       * Microsoft, "Event-driven scaling in Azure Functions", Limit scale-out
       * (ms.date 2026-08-03, read 2026-11-08): "In a Consumption or Elastic
       * Premium plan, you can specify a lower maximum limit for your app by
       * modifying the value of the functionAppScaleLimit site configuration
       * setting." The ARM reference for Microsoft.Web/sites: "This setting only
       * applies to the Consumption and Elastic Premium Plans" - so Basic (B1),
       * a Dedicated plan of one worker with Always On, does not carry it.
       *
       * One instance is enough for an operations team: the busiest lab instance
       * served 524 requests in 30 minutes with 13 runspaces and 504 MB private
       * bytes; a Consumption instance has 1.5 GB ("Azure Functions Scale and
       * Hosting", Service limits). The worker's in-process concurrency is NOT
       * set: Microsoft's PowerShell reference (Concurrency, ms.date 2026-05-20)
       * says the default is 1,000 runspaces on Functions 4.x, and the lab
       * logged no queued request. tests/unit/FacadeQueue.Tests.ps1 holds both.
       */
      warm ? {} : { functionAppScaleLimit: 1 }
    )
    /* DIAG-1: the control plane had NO platform logging.
     *
     * On 2026-09-07 the DRIFT-3 classification called dropped logging
     * harmless, and logging is important. Following that
     * turned up something worse than the entry being discussed: the dashboard
     * - a host for static files - was wired to Log Analytics, and THIS app,
     * which approves waves, starts migrations and halts runs, was not.
     *
     * Application Insights carried the application's own telemetry, so the
     * gap was invisible from inside the app. What was missing is the platform
     * view: who reached the front door, what the host did, and what Azure
     * changed underneath it.
     *
     * WHAT IS DELIBERATELY NOT HERE. AppServiceConsoleLogs and
     * AppServiceAppLogs are the high-volume pair, and Application Insights
     * already carries application telemetry - collecting both twice would put
     * ingestion on a customer's bill for nothing. AppServiceIPSecAuditLogs
     * records IP restriction decisions, and there are no IP restrictions to
     * decide. Add either when there is a reason, not in case.
     */
    // DIAG-1, AND ONLY ON A PLAN THAT CAN CARRY IT.
    //
    // Consumption is Y1, and a Y1 site supports NO diagnostic categories -
    // measured on the live facade, where the categories list comes back empty
    // and no setting exists. Asking for them refuses the whole stack:
    //   BadRequest: Category 'AppServiceHTTPLogs' is not supported.
    //
    // Basic is B1, an ordinary App Service plan, and carries them. So the
    // setting follows the plan rather than being asserted regardless.
    //
    // ON CONSUMPTION THE FACADE IS NOT UNOBSERVED: Application Insights is
    // wired either way, and it is what the support bundle and the version
    // endpoint already read. What is lost on Y1 is the PLATFORM's own view -
    // AppServiceAuthenticationLogs above all, the record that somebody reached
    // the front door. That is a real difference between the two plans and the
    // hosting-plan page should say so.
    diagnosticSettings: warm ? [
      {
        name: 'vmf-facade-to-logs'
        workspaceResourceId: logsResourceId
        // DIAG-3, MEASURED 2026-09-09 on a live B1 function app, because the
        // first list was assumed and the assumption cost the whole install:
        //   BadRequest: Category 'AppServiceHTTPLogs' is not supported.
        //
        // AppServiceHTTPLogs and AppServicePlatformLogs are WEB APP categories.
        // The facade is a FUNCTION app, and B1 or not, it does not have them.
        // `az monitor diagnostic-settings categories list` on the site returns
        // exactly five: FunctionAppLogs, AppServiceAuditLogs,
        // AppServiceIPSecAuditLogs, AppServiceAuthenticationLogs, AllMetrics.
        //
        // This path is gated on the Basic plan and had never run: the
        // lab and the proof environment are both Consumption. Choosing the
        // other hosting plan - one of the three questions the install asks -
        // failed the deployment outright.
        logCategoriesAndGroups: [
          { category: 'FunctionAppLogs' }
          { category: 'AppServiceAuditLogs' }
          { category: 'AppServiceIPSecAuditLogs' }
          { category: 'AppServiceAuthenticationLogs' }
        ]
        metricCategories: [ { category: 'AllMetrics' } ]
      }
    ] : []
    // DEPS-CURRENT-1 part 4: the app settings are NOT here any more. From
    // 0.20.0 this module writes ApplicationInsightsAgent_EXTENSION_VERSION
    // beside them whenever they name the Application Insights component, and
    // the facade never had that setting. They are written by
    // facade-appsettings.bicep below, exactly as this module wrote them at
    // 0.19.0.
    configs: [
      // Unauthenticated callers get 401 from the platform itself, never from
      // application code. NOT conditional: a control plane that can be
      // deployed without this is a control plane that will be (EVAL-H13).
      {
        name: 'authsettingsV2'
        properties: {
          globalValidation: {
            requireAuthentication: true
            unauthenticatedClientAction: 'Return401'
          }
          identityProviders: {
            azureActiveDirectory: {
              enabled: true
              registration: {
                clientId: apiAppId
                openIdIssuer: '${environment().authentication.loginEndpoint}${tenantId}/v2.0'
              }
              validation: {
                allowedAudiences: [ 'api://${apiAppId}', apiAppId ]
                // EASYAUTH-403-1: STATE THIS. NEVER LET AZURE INVENT IT.
                //
                // Omitting it does not mean "no policy". Azure materialises
                // one, and on this install it materialised
                // `allowedApplications: []` - an EMPTY ARRAY, which refuses
                // EVERY caller with HTTP 403 whatever token they hold.
                //
                // MEASURED on the affected install, one property at a time,
                // with the same two calls after each change:
                //   []                       -> 401 no token, 403 with one
                //   absent                   -> 401 no token, 200 with one
                //   [] put back              -> 403 again   (isolates it)
                //   [dashboard, az cli]      -> 401 no token, 200 with one
                //
                // Microsoft documents the opposite - that it restricts only
                // when non-empty. The measurement is what shipped here.
                //
                // THE TWO IDS ARE THE TWO identity.bicep PRE-AUTHORISES: the
                // dashboard a person signs in to, and the Azure CLI that
                // tools/Test-VmfHealth.ps1 asks the service through. Naming
                // only the dashboard shuts out the product's own diagnostic.
                defaultAuthorizationPolicy: {
                  allowedApplications: [ dashboardAppId, azCliClientId ]
                }
              }
            }
          }
          login: {
            tokenStore: {
              enabled: true
            }
          }
          platform: {
            enabled: true
          }
        }
      }
    ]
  }
  // PREVIEW-1: the ids this module needs are computed from names now, so the
  // ordering the output references used to imply is stated here instead.
  // WARM-1: BOTH plans are named. Only one of them is deployed on any run -
  // the facade's own plan when the answer is Free, the shared one when it is
  // Basic - and ARM drops the edge for the one that was skipped.
  dependsOn: [ facadeHostingPlan, dashboardPlan, appInsights ]
}

// DEPS-CURRENT-1 part 4: the facade's app settings, written as avm/res/web/site
// wrote them at 0.19.0 - the settings the site has now, then these, then the
// component's connection string. facade-appsettings.bicep says why they left
// the site module.
//
// PREVIEW-1: every parameter here is computed from names and resolves at
// preview time. The current settings were read here, in the parent, and passed
// in; INSTALL-FIRST-RUN-SETTINGS-1 moved that read into the module. The site
// is made by the facade module, not declared by this template, and ARM read
// a list() on its resourceId() before the site existed, in spite of the
// dependsOn: a first install stopped with ResourceNotFound. In the
// module the read runs only after the site module, as dependsOn says. So a
// preview of a FIRST install cannot read the settings of a site that does not
// exist yet, and shows this deployment as it can; a preview of an install that
// has the site reads them as before.
module facadeAppSettings 'facade-appsettings.bicep' = {
  name: 'vmf-facade-appsettings-deploy'
  params: {
    siteName: facadeSiteName
    appInsightsName: facadeName
    settings: {
      FUNCTIONS_EXTENSION_VERSION: '~4'
      FUNCTIONS_WORKER_RUNTIME: 'powershell'
      /* MISE-1: the sign-in layer validates tokens with MISE, and says so.
       *
       * WHY THIS SETTING EXISTS. The API registration this site validates
       * for was flagged by Microsoft's S360 MISE compliance measure, whose
       * notice says a registration that is not remediated is SCHEDULED FOR
       * DELETION. The measure reads authentication telemetry and asks
       * whether the component validating the token is a current MISE
       * client. Nothing in this product validates a token - App Service
       * Authentication does, in front of the site, and the application
       * only reads the identity header it produces. So the remediation is
       * not code: it is asking the platform's own validator to use MISE.
       *
       * App Service Authentication ships MISE and uses it ONLY when this
       * setting is true (from version 1.10.3 onward; before that it also
       * required a first-party subscription). Confirm the running version
       * at the site's /.auth/version endpoint - a new version is not
       * picked up until the site restarts.
       *
       * TWO THINGS MAKE THIS SAFE HERE, and both would stop being true
       * quietly if somebody changed them:
       *
       *   1. MISE CANNOT BE ENABLED ON A LINUX CONSUMPTION OR FLEX
       *      CONSUMPTION FUNCTION APP. This site is a WINDOWS function app
       *      on Y1, or B1 when the hosting plan is Basic. Neither is
       *      excluded.
       *      Moving it to Linux Consumption would take this setting away
       *      with no error.
       *   2. ENABLING MISE WITHOUT AN ISSUER URL RETURNS 401 for every
       *      caller. This template already sets openIdIssuer explicitly
       *      in the facade's authsettingsV2 above, which is the condition
       *      the guidance names.
       *
       * The reports have a three-day sampling window and take three to
       * five days to turn green, so a red measure the morning after a
       * deploy means nothing yet.
       */
      WEBSITE_AAD_ENABLE_MISE: 'true'
      /* The Functions runtime's own storage connection, WITHOUT a key.
       *
       * SEC-1 / F4 and F7. This used to call listKeys() on the run store -
       * the account holding every plan, approval, machine state and safety
       * copy record - and write the shared key into a plaintext app
       * setting AND into this module's recorded parameters. Anyone who
       * could read the site's configuration or the deployment history got
       * an unscoped, non-expiring credential for all migration state:
       * enough to read every customer's estate, or to forge an
       * approvals/<wave>.json and let a wave run unapproved. That reaches
       * anyone holding Website Contributor here, which was meant to carry no
       * data role on the store.
       *
       * The rule since 2026-09-06: NO storage access key is used anywhere
       * in this solution. Where one is present it is wrong, and access
       * must be identity based.
       *
       * The service URIs are spelled out rather than taken from the AVM
       * module's storageAccountResourceId parameter, which derives them
       * with reference() - a runtime dependency on the store, which the
       * store cannot have because ITS role assignments already depend on
       * this app's identity. environment() has no such dependency and
       * keeps this correct in every cloud.
       */
      AzureWebJobsStorage__accountName: storeName
      AzureWebJobsStorage__blobServiceUri: 'https://${storeName}.blob.${environment().suffixes.storage}'
      AzureWebJobsStorage__queueServiceUri: 'https://${storeName}.queue.${environment().suffixes.storage}'
      AzureWebJobsStorage__tableServiceUri: 'https://${storeName}.table.${environment().suffixes.storage}'
      AzureWebJobsStorage__credential: 'managedidentity'
      /* NOFILES-1: the facade runs FROM A PACKAGE IN BLOB STORAGE, so it
       * has no Azure Files content share and therefore no shared key.
       *
       * This is the second half of the no-key rule, and it took a wrong
       * turn first. A Windows Consumption function app normally keeps its
       * own code on an Azure Files share named by
       * WEBSITE_CONTENTAZUREFILECONNECTIONSTRING - a setting this template
       * never wrote, which `az functionapp create` added back when the
       * publish script still created the app, and which survived every
       * deploy since because the site module MERGES app settings. It
       * carries an account key.
       *
       * MEASURED in the lab, 2026-09-07, with keys refused on the store:
       * the host stayed up on an already mounted share and read its
       * secrets by identity, but every zip deploy died inside Kudu with
       * "Access to the path 'C:\home\LogFiles\kudu\deployment' is
       * denied" - which is CD's publish step.
       *
       * Azure Files DOES support managed identity, over SMB OAuth, for a
       * client you control: you install AzFilesSmbMIClient, it puts an
       * IMDS token in the Kerberos cache, and you mount with sec=krb5. The
       * App Service worker is not that client. PROVEN: with
       * isSmbOAuthEnabled true on the account and keys still refused, the
       * zip deploy failed identically. The platform never takes the OAuth
       * path.
       *
       * Blob storage does support identity, so the answer is to have no
       * file share at all. The host fetches this package with the app's
       * system-assigned identity, which holds Storage Blob Data Reader on
       * vmf-deploy and nothing that can write it (CODE-CONTAINER-WRITE-1).
       * No SAS, no key.
       *
       * The costs, which are real and are written down rather than
       * discovered later: dynamic scale-out is backed by Azure Files, so
       * scaling can be limited - acceptable for a control plane serving a
       * handful of operator requests, and not acceptable if this app ever
       * grows a high-fanout trigger. Cold start is slightly slower.
       * wwwroot is read-only, which the facade does not write to. And a
       * publish must SYNC TRIGGERS afterwards, which the publish script
       * does.
       *
       * A fresh install has no package until the first publish, so the app
       * does not start until tools/Deploy-VmfFacade.ps1 has run once. That
       * is the same order the install guide already gives.
       */
      WEBSITE_RUN_FROM_PACKAGE: 'https://${storeName}.blob.${environment().suffixes.storage}/vmf-deploy/facade.zip'
      VMF_STORE_ACCOUNT: storeName
      VMF_STORE_CONTAINER: 'vmf-runs'
      // INSTALL-0 piece 4: the job always exists, so this is never conditional.
      VMF_ENGINE_JOB_ID: engineJobResourceId
      // FACADE-SIGNIN-COLD-1: no VMF_TENANT_ID any more. The service does not
      // sign in: its tokens come from the managed identity endpoint, which
      // the platform gives it as IDENTITY_ENDPOINT and IDENTITY_HEADER.
    }
  }
  dependsOn: [ facade, appInsights ]
}

// The engine: one job execution = one factory operation (assess | plan |
// wave). The wave orchestrator's worker processes run INSIDE this container.
// Approval + capacity gates are enforced by the engine itself - hosting
// changes nothing about governance.
module engineJob 'br/public:avm/res/app/job:0.7.2' = {
  name: 'vmf-engine-job-deploy'
  params: {
    name: engineJobName
    location: location
    tags: tags
    environmentResourceId: acaEnvResourceId
    // The Consumption profile declared on the environment above; a job that
    // names none lands on the legacy 2 CPU / 4 GiB ceiling.
    workloadProfileName: 'Consumption'
    managedIdentities: {
      userAssignedResourceIds: [ engineIdentityResourceId ]
    }
    registries: [
      {
        server: acrLoginServer
        identity: engineIdentityResourceId
      }
    ]
    triggerType: 'Manual'
    manualTriggerConfig: {
      parallelism: 1
      replicaCompletionCount: 1
    }
    roleAssignments: [
      {
        // S3-4: the facade reads the job definition and starts executions
        principalId: facade.outputs.systemAssignedMIPrincipalId!
        principalType: 'ServicePrincipal'
        roleDefinitionIdOrName: roleContributor
      }
    ]
    // RESUME-1. This was 7200 - two hours - and it was OURS, not Azure's: the
    // service states no maximum, and validate-only probes on this exact job
    // accepted 24 hours, 7 days and 30 days. At ~20 minutes a machine, two
    // hours meant a wave of more than ~18 was killed mid-flight, and nothing
    // started it again. That was too fragile.
    //
    // 24 hours, deliberately, rather than 30 days: the engine checkpoints, so a
    // replica that hangs is worth killing, and a day bounds what a hung one can
    // bill. The safety net is not this number - it is the timer that resumes a
    // stalled wave (Invoke-VmfFacadeResumeStalledWaves); this just stops the
    // common case from needing it.
    replicaTimeout: 86400
    replicaRetryLimit: 0          // resume is an operator action, never a blind retry
    containers: [
      {
        name: 'engine'
        image: engineImage
        resources: {
          cpu: '1'
          memory: '2Gi'
        }
        env: [
          { name: 'VMF_STORE_ACCOUNT', value: storeName }
          { name: 'VMF_STORE_CONTAINER', value: 'vmf-runs' }
          { name: 'AZURE_CLIENT_ID', value: engineIdentity.outputs.clientId }
        ]
      }
    ]
  }
  // PREVIEW-1: the ids this module needs are computed from names now, so the
  // ordering the output references used to imply is stated here instead.
  dependsOn: [ acaEnv, acr ]
}

// PUBLISH-IN-1: the job that publishes the service's code.
//
// It runs for about fifteen seconds, once, per publish. It exists because the
// step it replaces - a laptop uploading a zip to blob storage - is the one part
// of an install that a locked-down store refuses outright, and no perimeter
// rule can ever admit a laptop. This runs INSIDE the subscription, where the
// rule does admit it.
//
// Everything about it is deliberately smaller than the engine's job beside it:
// one container, the smallest resources Container Apps accepts, no retries, and
// a timeout in minutes rather than a day.
module publishJob 'br/public:avm/res/app/job:0.7.2' = {
  name: 'vmf-publish-job-deploy'
  params: {
    name: publishJobName
    location: location
    tags: tags
    environmentResourceId: acaEnvResourceId
    workloadProfileName: 'Consumption'
    managedIdentities: {
      userAssignedResourceIds: [ publishIdentityResourceId ]
    }
    registries: [
      {
        server: acrLoginServer
        identity: publishIdentityResourceId
      }
    ]
    triggerType: 'Manual'
    manualTriggerConfig: {
      parallelism: 1
      replicaCompletionCount: 1
    }
    // Fifteen minutes. The upload takes seconds; the rest of this is the wait
    // for a seconds-old role assignment to reach the data plane, which
    // Microsoft documents as up to ten minutes. A publish that is still trying
    // after fifteen has a cause a longer wait will not fix.
    replicaTimeout: 900
    // NO RETRY. A failed publish must be read, not repeated: the two causes are
    // a permission that has not landed yet, which the job waits for itself, and
    // a network rule, which a second execution meets in exactly the same way.
    replicaRetryLimit: 0
    containers: [
      {
        name: 'publish'
        image: publishImage
        resources: {
          cpu: '0.25'
          memory: '0.5Gi'
        }
        env: [
          { name: 'VMF_STORE_ACCOUNT', value: storeName }
          { name: 'VMF_DEPLOY_CONTAINER', value: 'vmf-deploy' }
          { name: 'AZURE_CLIENT_ID', value: publishIdentity.outputs.clientId }
        ]
      }
    ]
  }
  dependsOn: [ acaEnv, acr ]
}

// PERM-2, 2026-08-31: the Contributor gap must be closed. The role should not
// be there.
//
// This template used to grant the engine identity CONTRIBUTOR on this resource
// group. That predates PERM-1, whose entire purpose - stated in the header of
// infra/roles.bicep - is "Replaces what the lab accumulated: Contributor on a
// resource group, and Reader at the TENANT ROOT management group." It was
// replaced everywhere except in the template that actually deploys, and nobody
// noticed because the running identity had been created before that line
// existed: the grant lived only on paper until the CD-1 reconciliation deploy
// made it real.
//
// The engine's access now comes from ONE place: the two custom roles in
// infra/roles.bicep, granted at scopes an operator chooses - broadly for
// assessment, which reads, and as narrowly as the estate allows for migration,
// which stops and resizes machines. Nothing here grants the engine anything
// over customer machines, which is the property that makes the blast radius
// answerable.
//
// Do not add a role assignment here to fix a permission failure. The action
// belongs in src/VmMigrationFactory/data/rbac-actions.json, where the role is
// derived from and a test checks the module against it.

// INSTALL-1: the names, for the hooks that publish code after the stack.
output baseSuffix string = baseSuffix
output storeName string = storeName
output acrName string = acrName
output facadeName string = facadeSiteName
// FUNCTIONS-ADMIN-ISOLATION-1: the install closes the /admin paths of the
// service by this ID after every deployment (infra/Set-VmfFacadeAdminIsolation.ps1).
output facadeResourceId string = facade.outputs.resourceId
output engineJobName string = engineJobName
output acrLoginServer string = acr.outputs.loginServer
output engineIdentityClientId string = engineIdentity.outputs.clientId
output engineIdentityPrincipalId string = engineIdentity.outputs.principalId
output engineJobResourceId string = engineJob.outputs.resourceId
output engineImage string = engineImage
output publishJobName string = publishJobName
output publishImage string = publishImage
output perimeterName string = nspName
@description('HOST-1: where the dashboard is served from - feed this to identity.bicep as dashboardOrigin, and to the dashboard deploy script.')
output dashboardUrl string = 'https://${dashboardName}.azurewebsites.net'
output dashboardSiteName string = dashboardName
output facadeUrl string = 'https://${facadeSiteName}.azurewebsites.net/api'
