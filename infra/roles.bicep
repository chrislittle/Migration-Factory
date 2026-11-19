// PERM-1: the two custom roles this tool runs as, BUILT FROM THE CODE.
//
// The actions are not written here. They are loaded from
// src/VmMigrationFactory/data/rbac-actions.json, which maps every Azure
// operation the module can perform to the permission it needs - and a unit
// test fails the build when the module gains a call the map has never heard
// of. Two lists that must agree is one list too many, and a role that drifts
// behind the code is how "least privilege" quietly becomes Contributor again.
//
// Why two roles rather than one: they want opposite scopes. Assessment is
// read-only, so it is safe to grant broadly - that is what makes "scan my
// whole management group" harmless. Migration writes: it stops machines,
// swaps their disks and deletes disks and snapshots, so it should be granted as
// narrowly as the estate allows.
//
// Replaces what the lab accumulated: Contributor on a resource group, and
// Reader at the TENANT ROOT management group. The latter existed only so
// management-group scanning could be tested and was never a product
// requirement.

targetScope = 'subscription'

@description('''Everywhere these roles may be assigned. ROLES-1: an ARRAY, and it GROWS.

Onboarding grants at a level the user chooses - a resource group, a subscription, or a
management group for fleet-wide scanning. When a scope arrives that this list does not
already cover, the list gains it and the definitions keep their ids, so every grant that
already exists keeps working.

THE CALLER MUST PASS THE WHOLE LIST, including what is already there. A deployment states
a property; it cannot add to one. Passing only the new scope would silently drop the
others and break their assignments, so tools/Grant-VmfAccess.ps1 and the install hook both
read the current list and pass the union.

Azure's limits, which shape this: up to 2,000 entries, but only ONE management group; no
root scope and no wildcards.''')
param assignableScopes array = [ subscription().id ]

var rbac = loadJsonContent('../src/VmMigrationFactory/data/rbac-actions.json')

// Derived, in this one place, from the map.
var assessActions = union(
  flatten(map(filter(rbac.operations, op => op.role == 'assess'), op => op.actions)),
  []
)
var executeOnlyActions = union(
  flatten(map(filter(rbac.operations, op => op.role == 'execute'), op => op.actions)),
  []
)
// A migration reads before it writes, so the execute role contains the assess
// role. Granting them separately would just be another thing to forget.
var executeActions = union(assessActions, executeOnlyActions)

// ROLES-1: the identity of these roles comes from the SUBSCRIPTION they are
// created in, never from the scopes they may be assigned at.
//
// That distinction is the whole fix. Keyed to the scope list, adding a
// management group produced a SECOND pair of definitions with a second name,
// and the first pair's assignments pointed at a role nothing used any more.
// Keyed to the subscription, the list can grow all it likes and the ids do not
// move.
//
// The value is unchanged for every install that exists: the hook passed
// `assignableScope=/subscriptions/<id>`, which is what subscription().id
// returns, so these guids and names are byte for byte what they were.
var roleKey = subscription().id

resource assessRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  // A deterministic id means redeploying updates the role rather than
  // creating a second one, and existing assignments keep working.
  name: guid(roleKey, 'vmf-assess-role')
  properties: {
    roleName: '${rbac.roles.assess.roleName} (${uniqueString(roleKey)})'
    description: rbac.roles.assess.description
    type: 'CustomRole'
    assignableScopes: assignableScopes
    permissions: [
      {
        actions: assessActions
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

resource executeRole 'Microsoft.Authorization/roleDefinitions@2022-04-01' = {
  name: guid(roleKey, 'vmf-execute-role')
  properties: {
    roleName: '${rbac.roles.execute.roleName} (${uniqueString(roleKey)})'
    description: rbac.roles.execute.description
    type: 'CustomRole'
    assignableScopes: assignableScopes
    permissions: [
      {
        actions: executeActions
        notActions: []
        dataActions: []
        notDataActions: []
      }
    ]
  }
}

@description('Assign this to anything that only needs to SEE machines - safe to grant broadly.')
output assessRoleId string = assessRole.id
@description('Assign this only where machines are actually being migrated.')
output executeRoleId string = executeRole.id
output assessActionCount int = length(assessActions)
output executeActionCount int = length(executeActions)
@description('Everywhere these roles can now be granted, so a caller can report it.')
output assignableScopes array = assignableScopes
