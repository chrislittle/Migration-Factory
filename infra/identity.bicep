// PKG-1: the Entra objects. The Graph extension is GA (1.0.0) since
// 2026-09-08; this relied on 0.2.0-preview until then, approved as a known
// risk. The preview still worked, but a preview is not kept once the GA
// release exists.
//
// MOVING TO GA IS A bicepconfig.json CHANGE AND NOTHING ELSE, but it took a
// measurement to know that. The install failed all day with
//   InvalidDeployment ... property 'appId' doesn't exist
// and the obvious suspect was this file's apiAppIdentifier - a second
// application resource sharing apiApp's uniqueName. Removing it did fix the
// preview. It was not the cause. One variable at a time, same template, same
// resource group:
//
//   0.2.0-preview + experimental + duplicate ..... Failed
//   1.0.0         + experimental + duplicate ..... Failed
//   1.0.0         + experimental - duplicate ..... Failed
//   0.2.0-preview + experimental - duplicate ..... Succeeded
//   1.0.0         NO experimental - duplicate .... Succeeded
//   1.0.0         NO experimental + duplicate .... SUCCEEDED
//
// experimentalFeaturesEnabled.extensibility was the breakage: with a GA
// extension, extensibility is no longer experimental, and leaving the flag on
// breaks the appId read. The last line is why this file is UNCHANGED - the
// duplicate declaration works on GA, and redesigning around it would have been
// a fix for a defect that does not exist.
// the platform needs, declared rather than scripted. These are Microsoft
// Graph objects, not ARM resources, so they need the Graph Bicep extension -
// currently preview, which was accepted deliberately.
//
// Deployed separately from platform.bicep because Graph objects are TENANT
// scoped while the platform is resource-group scoped, and because the api
// app id this produces is an input to the platform's sign-in enforcement.
extension microsoftGraphV1

targetScope = 'resourceGroup'

@description('Display name of the API registration that guards the facade')
param apiDisplayName string = 'vmf-api'

@description('Display name of the dashboard sign-in registration')
param dashboardDisplayName string = 'vmf-dashboard'

@description('''Suffix of the platform this identity belongs to. Derived from the resource group
exactly as platform.bicep derives it, so the two templates agree on the dashboard's address without
either being told. Pass it only to adopt a deployment whose suffix was chosen by hand.''')
param baseSuffix string = uniqueString(resourceGroup().id)

@description('Origin the dashboard is served from (its redirect URI). Defaults to the App Service platform.bicep creates for it.')
param dashboardOrigin string = 'https://vmf-dash-${baseSuffix}.azurewebsites.net'

@description('''A key that makes each install's registrations distinct in Entra, and NOTHING ELSE.

WHY IT EXISTS. Entra keeps a deleted application for 30 days and keeps its
uniqueName with it, and the Graph extension upserts by uniqueName - so
reinstalling an environment of the same name collided with the tombstone and
failed on a message about appId. MEASURED 2026-09-09, one property at a time:

  same uniqueName, same displayName ... Failed
  NEW uniqueName,  same displayName ... Succeeded
  same uniqueName, NEW displayName .... Failed

So uniqueName is what collides and displayName is free. The name a person sees
in the portal is unchanged; only the key moves.

NEVER EMPTY FROM AN INSTALL (INSTALL-ADOPT-OWNER-1). An empty key makes the
uniqueName equal to the display name, which any member of the tenant can make
first, and this template upserts into whatever holds that uniqueName.
preprovision and identity-deploy.ps1 pass the recorded key, or a new random key
when no registration has either name; else they stop before this runs.''')
param registrationKey string = ''

// displayName is what a person reads; uniqueName is what Entra reserves.
var apiUniqueName = empty(registrationKey) ? apiDisplayName : '${apiDisplayName}-${registrationKey}'
var dashboardUniqueName = empty(registrationKey) ? dashboardDisplayName : '${dashboardDisplayName}-${registrationKey}'

// INSTALL-0 piece 3: there is no apiIdentifierUri parameter any more. The
// identifier is set INSIDE this deployment - see apiAppIdentifier below.

// Fixed ids keep re-runs idempotent: Graph treats a changed role id as a new
// role, which would orphan every existing assignment.
var roles = [
  { id: '6f1c3a10-0001-4b6e-9e6a-100000000001', value: 'Vmf.Viewer' }
  { id: '6f1c3a10-0002-4b6e-9e6a-100000000002', value: 'Vmf.Approver' }
  { id: '6f1c3a10-0003-4b6e-9e6a-100000000003', value: 'Vmf.Operator' }
  { id: '6f1c3a10-0004-4b6e-9e6a-100000000004', value: 'Vmf.Admin' }
]
var scopeId = '6f1c3a10-00aa-4b6e-9e6a-1000000000aa'
var azCliClientId = '04b07795-8ddb-461a-bbee-02f9e1bf7b46'
var graphAppId = '00000003-0000-0000-c000-000000000000'
// Azure Resource Manager ("Windows Azure Service Management API"), for the
// reads the dashboard makes AS THE SIGNED-IN PERSON: the access console's
// scope list. IDENTITY-3's "Where is it used?" read Resource Graph with it
// too, until IDENTITY-4 removed that panel.
var armAppId = '797f4846-ba00-4fd7-ba43-dac1f8f63013'

// The dashboard: a browser app that signs a person in. It holds no secret -
// it asks for tokens on the signed-in user's behalf and nothing more.
resource dashboardApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: dashboardUniqueName
  displayName: dashboardDisplayName
  signInAudience: 'AzureADMyOrg'
  // POPUP-3: EVERY PAGE, because every page signs a person in and each one
  // returns to ITSELF. Three were missing - assessments, migrations and
  // projects - so a person who opened one of those without a session already
  // in the browser met a redirect-URI mismatch from Entra and could not sign
  // in at all. That was true under the popup flow too; the popup just made it
  // rarer, because people arrive at the front page first.
  //
  // `tests/unit/PopupFree.Tests.ps1` reads this list against the pages on disk
  // and fails if a new page is added without one.
  spa: {
    redirectUris: [
      dashboardOrigin
      '${dashboardOrigin}/index.html'
      '${dashboardOrigin}/access.html'
      '${dashboardOrigin}/assessments.html'
      '${dashboardOrigin}/migrations.html'
      '${dashboardOrigin}/projects.html'
      '${dashboardOrigin}/reports.html'
      '${dashboardOrigin}/waves.html'
      '${dashboardOrigin}/wizard.html'
    ]
  }
  requiredResourceAccess: [
    // STORE-READ-1: the Azure Storage user_impersonation permission was here
    // and is gone. The browser asked for a storage token to read the run store
    // directly; it asks for this app's own access_as_user now, and the service
    // reads with its managed identity. One less permission to consent to.
    {
      // the access console manages roles AS THE SIGNED-IN ADMIN; the
      // directory still decides whether they may
      resourceAppId: graphAppId
      // IDENTITY-4, 2026-09-11: the OPT-IN sign-in read (AuditLog.Read.All)
      // was here, behind a signInActivity parameter. It went with the control
      // that used it. Its consent was WIDER than its read - it permits every
      // sign-in in the tenant, in a reader's session - and it is the kind of
      // permission a customer's security team is right to refuse. The product
      // no longer researches what a machine's identity reaches, so it no
      // longer needs it, and the install has one switch fewer.
      //
      // These four remain, and none of them is for that: the access console
      // assigns app roles AS THE SIGNED-IN ADMIN and reads users and groups to
      // do it. Application.Read.All is least privileged per the Graph docs.
      resourceAccess: [
        { id: '84bccea3-f856-4a8a-967b-dbe0a3d53a64', type: 'Scope' }  // AppRoleAssignment.ReadWrite.All
        { id: 'c79f8feb-a9db-4090-85f9-90d820caa0eb', type: 'Scope' }  // Application.Read.All
        { id: 'b340eb25-3456-403f-be2f-af7a0d370277', type: 'Scope' }  // User.ReadBasic.All
        { id: '5f8c59db-677d-491f-a6b8-5f174b11ec1d', type: 'Scope' }  // Group.Read.All
      ]
    }
    {
      // Azure, as the person: the access console's scope reads and role grants, with THEIR rights
      resourceAppId: armAppId
      resourceAccess: [ { id: '41094075-9dad-400e-a0bd-54e686782033', type: 'Scope' } ]  // user_impersonation
    }
  ]
}

resource dashboardSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: dashboardApp.appId
}

// The API: what the facade validates tokens against, and where the four roles
// live. Assignable to users AND groups, so access can be managed by group.
var apiAppRoles = [for r in roles: {
  id: r.id
  value: r.value
  displayName: r.value
  description: '${r.value} role for the VMF migration service'
  allowedMemberTypes: [ 'User' ]
  isEnabled: true
}]
var apiApi = {
  requestedAccessTokenVersion: 2
  oauth2PermissionScopes: [
    {
      id: scopeId
      value: 'access_as_user'
      type: 'User'
      adminConsentDisplayName: 'Access the VMF migration service'
      adminConsentDescription: 'Call the VMF migration service as the signed-in user'
      userConsentDisplayName: 'Access the VMF migration service'
      userConsentDescription: 'Call the VMF migration service on your behalf'
      isEnabled: true
    }
  ]
  // The dashboard and the CLI may ask for this scope without a separate
  // consent prompt. Nothing else may.
  preAuthorizedApplications: [
    { appId: dashboardApp.appId, delegatedPermissionIds: [ scopeId ] }
    { appId: azCliClientId, delegatedPermissionIds: [ scopeId ] }
  ]
}

resource apiApp 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: apiUniqueName
  displayName: apiDisplayName
  signInAudience: 'AzureADMyOrg'
  appRoles: apiAppRoles
  api: apiApi
}

// INSTALL-0 piece 3: ONE PASS. Tokens are issued for api://<the registration's
// own application id>, and that id does not exist until the registration does.
// This used to be a second run of the deploy script with the id pasted in -
// and our script carried OUR id as a literal. The Graph extension upserts by
// uniqueName, so a SECOND declaration of the same registration, referencing
// the first's id, sets the identifier inside one deployment. It carries the
// full definition - roles and API - so that whichever way the upsert applies,
// nothing the first declaration set is lost.
resource apiAppIdentifier 'Microsoft.Graph/applications@v1.0' = {
  uniqueName: apiApp.uniqueName
  displayName: apiDisplayName
  signInAudience: 'AzureADMyOrg'
  identifierUris: [ 'api://${apiApp.appId}' ]
  appRoles: apiAppRoles
  api: apiApi
}

@description('''Require an assigned app role to sign in at all (GATE-1).

FALSE on a first deployment and never set true here by hand: closing the gate
before anybody holds the administrator role locks everyone out of the tool they
just installed, and the tool cannot let them back in - that takes a directory
administrator and the portal. Grant-VmfAccess.ps1 -CloseTheGate is the only
thing that should close it, and it refuses unless an administrator exists.

WHY THIS IS A PARAMETER. It was the literal `false`, and the live tenant was
`true` - closed deliberately, months later. Bicep is declarative, so the next
redeploy of this template would have asserted `false` and SILENTLY RE-OPENED
the gate, with no error and nothing in the output naming it. infra/identity-
deploy.ps1 now reads the live value and passes it back, so a redeploy can
preserve the posture but never quietly downgrade it.

Since 2026-09-02 this setting of the app registration is in the template, because the
deployment made the registration, and a setting kept only in the portal can drift.''')
param requireAssignedRole bool = false

resource apiSp 'Microsoft.Graph/servicePrincipals@v1.0' = {
  appId: apiApp.appId
  appRoleAssignmentRequired: requireAssignedRole
}

@description('Feed this to platform.bicep as apiAppId so the facade enforces sign-in')
output apiAppId string = apiApp.appId
output dashboardAppId string = dashboardApp.appId
output apiServicePrincipalId string = apiSp.id
