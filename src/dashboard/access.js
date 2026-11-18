'use strict';
const $ = (s) => document.querySelector(s);
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));

/* ============================ UX-STRINGS-BEGIN ============================
   Same bar as the dashboard: plain words only. The reader manages access;
   they know what a person, a group and a role are - nothing else. */
const UX = {
  notAdmin:    'You do not have access management rights',
  notAdminCopy:'Your account can use the dashboard, but only administrators can change who has access. Ask an existing administrator to add you.',
  whoTitle:    'Who has access',
  whoHint:     'Roles come from your directory. A member of a group inherits the role you give that group.',
  colWho:      'User or group',
  colType:     'Type',
  colRoles:    'Roles',
  typeUser:    'user',
  typeGroup:   'group',
  addTitle:    'Give someone access',
  addHint:     'Find a user or a group in your directory, then choose the roles they hold.',
  searchHint:  'Type a name to search for a user or a group...',
  addBtn:      'Give access',
  removeTip:   'Remove this role',
  addRole:     'Add a role',
  addRoleTip:  'Give this user or group another role',
  addRoleCancel: 'Cancel',
  roleAdded:   'Role added.',
  removeAsk:   'Remove the {role} role from {who}?',
  removeAskDesc: 'The change takes effect the next time they sign in.',
  added:       'Access given. It takes effect the next time they sign in.',
  removed:     'Role removed. It takes effect the next time they sign in.',
  nobody:      'Nobody has been given access yet.',
  // LOADING-LINE-1: the table's one row while the directory is read.
  whoReading:  'Reading the users and groups that have a role in this product.',
  noMatch:     'No user or group matches.',
  scopeTitle:  'Where the product may work',
  scopeHint:   'The places the product may assess, and the places it may migrate.',
  scopeNone:   'The product has not been given access to anything yet, so it has nothing to scan.',
  scopeLook:   'Assess',
  scopeChange: 'Assess and migrate',
  scopePickLabel: 'Subscription',
  scopeLevelLabel:'What does the product need access to?',
  scopeLevelMg:   'A management group. This covers every subscription under it, including subscriptions added later.',
  scopeLevelSub:  'One subscription. This covers every resource group in that subscription.',
  scopeLevelRg:   'One resource group. This is the smallest choice, and the one to prefer.',
  scopeRgLabel:   'Resource group',
  scopeMgLabel:   'Management group',
  scopeRgLoading: 'Reading the resource groups...',
  scopeRgNone:    'This subscription has no resource groups you can read.',
  scopeMgNone:    'No management group found',
  scopeMgNoneWhy: 'This directory has no management groups, so choose a subscription or a resource group instead.',
  scopeMgDenied:  'You cannot read management groups',
  scopeMgDeniedWhy: 'Granting at a management group needs rights above a subscription. Ask your directory administrator to grant there, or choose a subscription or a resource group.',
  scopeColWhere:  'Where',
  scopeRemove:    'Remove',
  scopeRemoveConfirm: 'Remove this access?',
  scopeRemoveYes: 'Yes, remove access',
  roleTidyYes: 'Yes, remove them',
  removeYes: 'Yes, remove',
  cancel: 'Cancel',
  scopeRemoveDesc:'The product can no longer assess or migrate anything here. Nothing is deleted and no machine is touched.',
  scopeRemoved:   'Access removed.',
  // ACCESS-REMOVE-SHARED-1: two engine grants on one place share the one web
  // service assignment there, so removing one of them keeps it.
  scopeRemoveDescShared: 'This removes the engine grant only. Another grant on this place uses the web service read access, so that access stays.',
  scopeRemovedShared: 'Access removed. The web service read access stays, because another grant on this place uses it.',
  scopeRemovedServiceUnread: 'The engine grant is removed. This page could not read the other grants on this place, so it did not remove the web service read access.',
  // ACCESS-SERVICE-ORPHAN-1: a web service assignment with no engine grant at
  // its place gets its own row, and its own Remove.
  scopeServiceOnlyNote: 'The web service only. The engine has no grant on this place.',
  // Said with its condition: a wider engine grant can still cover the place.
  scopeServiceOnlyWhy: 'The web service can read the machines here, but the engine has no grant on this place. If no wider grant covers it, the product cannot scan or migrate them. Remove this access, or give the product access to the place again.',
  scopeServiceRemoveDesc: 'The web service can no longer read the machines here. Nothing is deleted and no machine is touched.',
  scopeServiceRemoved: 'The web service read access is removed.',
  scopeServiceKeptEngine: 'The web service read access stays, because an engine grant on this place now uses it.',
  scopeServiceKeptUnread: 'This page could not read the engine grants on this place, so it did not remove the web service read access.',
  scopeRemoving:  'Removing...',
  scopeGone:      'no longer exists',
  scopeGoneWhy:   'The product still holds access to a place that has been deleted. The access does nothing, and you can remove it here.',
  scopeJustAdded: 'just added',
  scopeLagWhy:    'Azure can take some time to list a change to access. This page shows your change at once, so a row can show here before Azure lists it.',
  scopeCoveredBy: 'Already covered by the grant on {place}',
  scopeCoveredWhy:'A grant on a subscription also applies to every resource group in it. A grant on a management group also applies to every subscription in it.',
  scopeColLevel:  'Level',
  scopeLevelNameMg:  'management group',
  scopeLevelNameSub: 'subscription',
  scopeLevelNameRg:  'resource group',
  scopeModeLabel: 'What may it do there?',
  scopeAssess: 'Assess only. The product reads the machines here and reports what it could migrate. It changes nothing.',
  scopeMigrate:'Assess and migrate. The product can also stop, resize and start machines, change their network interfaces, and run its scripts in them. It can make and delete snapshots, disks and resource locks, make on-demand capacity reservations, and request quota increases.',
  scopeBtn:    'Give the product access here',
  scopeAdded:  'Access given. A scan can now include this place.',
  // ACCESS-HALF-1: the product needs two identities and only one was given
  // access. Said out loud, because the symptom is silent - every list in the
  // product stays empty and this page used to report the place as covered.
  scopeHalfGranted: 'The engine has access to this place. The web service does not, so lists of machines here stay empty. Install the product again to give it access.',
  scopeHalfNote: 'The engine only. The web service cannot read this place, so lists of machines here stay empty.',
  scopeHalfFix: 'Give the web service access',
  scopeHalfFixing: 'Giving access...',
  scopeHalfFixed: 'The web service can now read this place, and the lists show its machines.',
  scopeHalfUnknown: 'This page could not read what the web service can reach, so it cannot say whether these places are fully covered.',
  // ACCESS-PAIR-COVER-1: Azure role assignments are inherited, so the web
  // service reads a place through a grant on a place that contains it.
  scopeServiceVia: 'The web service reads this place through the grant on {place}.',
  scopeServiceBlind: 'Cannot tell. This page could not read the subscriptions in the management group {place}, so it cannot say whether the web service reads this place.',
  scopeRemoveLosesRead: 'The web service reads these places only through this grant. After the removal, it cannot read them, and their lists of machines stay empty:',
  scopeLosesMaybe: '{place}. A management group that this page cannot read can still give the web service access.',
  // A guard: the caller always gives a place. An empty place is refused.
  scopeNoRole: 'Choose a place first.',
  /* ROLES-1 WORDING, rewritten. The message was very confusing.
   *
   * It opened with a raw resource id ninety characters long, said "add
   * that place to the two roles" without naming them, and ended with two more
   * raw ids under no heading - so a reader could not tell whether the list was
   * what they had, what they would get, or what they had to go and do. Every
   * fact in it was true and none of it could be acted on. */
  scopeWidenAsk: 'Add {where} to the two roles the product uses, then give the product access there?',
  scopeWidenBtn: 'Add the place and grant',
  scopeWidened: 'The roles now reach that place, and access is granted.',
  scopeWidenDenied: 'Your account may not change the two roles. Azure needs Microsoft.Authorization/roleDefinitions/write on every place the roles already reach, not only the new one: {scopes}',
  scopeSecondGroup: 'The roles already reach the management group {have}. Azure permits one management group for each role, so {want} cannot be added. Grant at a management group that holds both, or install the product again for the other group.',
  // A guard: an install writes the ids of the roles it made.
  scopeRoleMissing: 'The dashboard configuration does not name the two roles. Install the product again.',
  scopeWidenPipeline: 'The two roles are VMF Assessment and VMF Migration. Adding a place only lets them be used there. Nobody gets access until you give it.',
  scopeWidenScopeList: 'The two roles would then cover these places:',
  scopeNoPerm: 'Your account cannot grant access in that subscription. Granting access needs Owner or User Access Administrator there.',
  scopeBusy:   'Working...',
  scopeReading:'Reading what the product can reach...',
  scopeConnect: 'This page needs your permission for Azure before it can show or change where the product may work. That permission is separate from the directory permission the card above asks for.',
  scopeConnectBtn: 'Connect to Azure',
  // CONSENT-STUCK-1: some directories let only an administrator approve a new
  // application. Then this button cannot work, whatever rights you hold.
  scopeConnectRefused: 'If Microsoft Entra ID answers Need admin approval, ask a directory administrator to approve the product once.',
  // CONSENT-SPLIT-1: shown when the directory refuses. The third sentence is
  // the one that matters - it tells a person the product is not shut.
  dirBlocked:    'This part of the page needs approval from a directory administrator.',
  dirBlockedWhy: 'It reads your directory to show who can sign in, and to give and remove roles. Microsoft Entra ID lets only a directory administrator approve those permissions. No user can approve them, and owning the subscription does not give them. The card below still works, with your rights on the subscription.',
  dirConnectBtn: 'Connect to the directory',
  /* ROLE-2: "administrator: everything above, plus managing who has access"
   * had no "above" to reference. Each role must state exactly what it is.
   *
   * Right on both counts. "Everything above" described a LIST ORDER, and these
   * are pills on a row with no order at all. And the wording hid the shape of
   * the model, which is not the ladder it reads as:
   *
   *   Administrator  every gate in the facade, plus this page
   *   Operator       read + start, pause, resume, fix.  CANNOT sign off a wave
   *   Approver       read + sign off a wave.            CANNOT run anything
   *   Viewer         read
   *
   * OPERATOR AND APPROVER ARE SIBLINGS, NOT STEPS. Invoke-VmfFacadeApprove
   * takes Approver or Administrator and refuses an Operator, deliberately:
   * whoever runs a wave should not also be the one who signs it off. That is
   * the single most important thing about these roles and the old wording did
   * not mention it. */
  roleWords: {
    'Vmf.Viewer':   ['Viewer',       'Can see runs, waves, machines and reports. Changes nothing.'],
    'Vmf.Approver': ['Approver',     'Can see everything. Can accept an assessment, sign off a plan or a wave, and accept a decision for a stopped machine. Cannot start, pause or stop anything.'],
    'Vmf.Operator': ['Operator',     'Can see everything. Can assess, plan and arrange waves, start, pause and resume migrations, and retry or restore machines. Cannot sign off or accept a decision.'],
    'Vmf.Admin':    ['Administrator','Can do everything an Operator and an Approver can do, and can give and remove access on this page.'],
  },
  /* What each role ALREADY INCLUDES, so the page never offers a role that
   * would add nothing. Picking administrator must not leave somebody
   * thinking they also need every other role to get everything.
   *
   * Read from the facade's own gates, not invented: Vmf.Admin appears in every
   * Assert-VmfFacadeRole call, and Vmf.Viewer's reads are granted to all four
   * roles. */
  roleCovers: {
    'Vmf.Admin':    ['Vmf.Viewer', 'Vmf.Approver', 'Vmf.Operator'],
    'Vmf.Operator': ['Vmf.Viewer'],
    'Vmf.Approver': ['Vmf.Viewer'],
    'Vmf.Viewer':   [],
  },
  roleAllCovered: 'Administrator covers everything. Every other role is already covered.',
  roleCoveredBy:  'Already covered by the {role} role',
  /* ROLE-3: an administrator's row still listed every other role, which is
   * redundant once administrator covers them.
   *
   * Yes. The page had started SAYING the other roles add nothing while still
   * drawing four pills that all look equally load-bearing. The assignments are
   * real - he genuinely holds four - so hiding them would be a lie; the fix is
   * to show which ones are doing work.
   *
   * And then to offer to clean them up, because a permission that does nothing
   * is still a permission somebody has to reason about at review time. */
  roleTidy:       'Remove {n} already covered',
  roleTidyAsk:    'Remove these roles from {who}?\n\n{list}\n\nEach is already covered by the {by} role, so nothing they can do changes.',
  roleTidyDone:   'Removed the roles that added nothing.',
  // DEPLOY-MSG-RULE12-1: it said to run Deploy-VmfFacade.ps1 (hard rule 12).
  noApi:          'The dashboard configuration does not name the web service. Install the product again to write it, then reload this page.',
};
/* ============================= UX-STRINGS-END ============================= */

let cfg = null, msalApp = null, account = null, spId = null, appRoles = [], picked = null;

// ROLE-GATE-1 REGRESSION (ADMIN-1). This page had no demo mode and never
// declared DEMO_MODE, so the role gate's first line was a ReferenceError and
// the Admin page was dead from 788eff0 until someone opened it. Declared on
// this page exactly as on the other seven, so the gate line stays identical.
const DEMO_MODE = new URLSearchParams(location.search).has('demo');

/* DOC-4: sample data for the manual's picture of this page, which needs a
 * visual and had none.
 *
 * With ?demo, graph() and arm() answer from this table and never reach the
 * directory or Azure; a write is accepted into the table and forgotten on
 * reload. The people are the Contoso example the manual follows. Sam holds
 * Viewer beside Operator so the picture shows a covered role; the group holds
 * a role but cannot read the records yet, so it shows the read-access offer;
 * one grant points at a resource group that no longer exists. */
const DEMO = {
  signedInAs: 'dana.ruiz@contoso.com',
  cfg: {
    apiAppId: 'sample', clientId: 'sample', tenantId: 'sample',
    enginePrincipalId: 'sample-engine',
  },
  spId: 'sp-sample',
  roles: [
    { id: 'r-viewer', value: 'Vmf.Viewer', isEnabled: true },
    { id: 'r-approver', value: 'Vmf.Approver', isEnabled: true },
    { id: 'r-operator', value: 'Vmf.Operator', isEnabled: true },
    { id: 'r-admin', value: 'Vmf.Admin', isEnabled: true },
  ],
  people: [
    { id: 'u-dana', displayName: 'Dana Ruiz', userPrincipalName: 'dana.ruiz@contoso.com', type: 'User' },
    { id: 'u-sam', displayName: 'Sam Okafor', userPrincipalName: 'sam.okafor@contoso.com', type: 'User' },
    { id: 'u-pat', displayName: 'Pat Lindqvist', userPrincipalName: 'pat.lindqvist@contoso.com', type: 'User' },
    { id: 'u-lee', displayName: 'Lee Tanaka', userPrincipalName: 'lee.tanaka@contoso.com', type: 'User' },
    { id: 'g-billing', displayName: 'Billing platform team', type: 'Group' },
    { id: 'g-web', displayName: 'Web operations', type: 'Group' },
  ],
  assignments: [
    { id: 'a1', principalId: 'u-dana', appRoleId: 'r-admin' },
    { id: 'a2', principalId: 'u-sam', appRoleId: 'r-operator' },
    { id: 'a3', principalId: 'u-sam', appRoleId: 'r-viewer' },
    { id: 'a4', principalId: 'u-pat', appRoleId: 'r-approver' },
    { id: 'a5', principalId: 'g-billing', appRoleId: 'r-viewer' },
  ],
  subscriptions: [
    { subscriptionId: '1111', displayName: 'Production', state: 'Enabled' },
    { subscriptionId: '2222', displayName: 'Development', state: 'Enabled' },
  ],
  groups: { '1111': ['rg-billing', 'rg-shared', 'rg-vmf', 'rg-web'], '2222': ['rg-sandbox'] },
  grants: [
    { id: '/subscriptions/1111/providers/Microsoft.Authorization/roleAssignments/g1', scope: '/subscriptions/1111', role: 'assess' },
    { id: '/subscriptions/1111/resourceGroups/rg-billing/providers/Microsoft.Authorization/roleAssignments/g2', scope: '/subscriptions/1111/resourceGroups/rg-billing', role: 'migrate' },
    { id: '/subscriptions/1111/resourceGroups/rg-uxtest/providers/Microsoft.Authorization/roleAssignments/g3', scope: '/subscriptions/1111/resourceGroups/rg-uxtest', role: 'assess' },
  ],
  managementGroups: [{ name: 'contoso-root', properties: { displayName: 'Contoso' } }],
};

function demoAnswer(kind, method, path, body) {
  const person = (id) => DEMO.people.find(x => x.id === id) || {};
  const nameIn = (filter) => decodeURIComponent((String(path).match(/startswith\(displayName,'([^']*)'\)/) || [])[1] || '').toLowerCase();
  if (kind === 'graph') {
    if (path.startsWith('servicePrincipals(appId=')) return { id: DEMO.spId, appRoles: DEMO.roles };
    if (method === 'GET' && path.includes('/appRoleAssignedTo')) {
      return { value: DEMO.assignments.map(a => ({ ...a, principalDisplayName: person(a.principalId).displayName, principalType: person(a.principalId).type })) };
    }
    if (method === 'POST' && path.includes('/appRoleAssignedTo')) {
      const a = { id: `a${Date.now()}`, principalId: body.principalId, appRoleId: body.appRoleId };
      DEMO.assignments.push(a);
      return a;
    }
    if (method === 'DELETE' && path.includes('/appRoleAssignedTo/')) {
      const id = path.split('/').pop();
      DEMO.assignments = DEMO.assignments.filter(a => a.id !== id);
      return null;
    }
    if (path.startsWith('directoryObjects/getByIds')) {
      return { value: (body.ids || []).map(id => person(id)).filter(x => x.id).map(x => ({ id: x.id, userPrincipalName: x.userPrincipalName || '' })) };
    }
    if (path.startsWith('users?')) {
      const q = nameIn(path);
      return { value: DEMO.people.filter(x => x.type === 'User' && x.displayName.toLowerCase().startsWith(q)) };
    }
    if (path.startsWith('groups?')) {
      const q = nameIn(path);
      return { value: DEMO.people.filter(x => x.type === 'Group' && x.displayName.toLowerCase().startsWith(q)) };
    }
    throw new Error(`No sample answer for ${method} ${path}`);
  }
  // arm
  if (method === 'PUT') {
    return null;
  }
  if (method === 'DELETE') {
    const id = path.split('?')[0];
    DEMO.grants = DEMO.grants.filter(g => g.id !== id);
    return null;
  }
  if (path.startsWith('/subscriptions?')) return { value: DEMO.subscriptions };
  if (path.startsWith('/providers/Microsoft.Management/managementGroups')) return { value: DEMO.managementGroups };
  if (path.includes('/roleAssignments')) {
    const sub = (path.match(/^\/subscriptions\/([^/]+)/) || [])[1];
    return { value: DEMO.grants.filter(g => g.scope.startsWith(`/subscriptions/${sub}`)).map(g => ({ id: g.id,
      properties: { scope: g.scope, principalId: DEMO.cfg.enginePrincipalId, roleDefinitionId: `/subscriptions/${sub}/providers/Microsoft.Authorization/roleDefinitions/def-${g.role}` } })) };
  }
  if (path.includes('/roleDefinitions')) {
    return { value: [
      { name: 'def-assess', properties: { roleName: 'VMF Assessment (sample)' } },
      { name: 'def-migrate', properties: { roleName: 'VMF Migration (sample)' } },
    ] };
  }
  if (path.includes('/resourcegroups')) {
    const sub = (path.match(/^\/subscriptions\/([^/]+)/) || [])[1];
    return { value: (DEMO.groups[sub] || []).map(name => ({ name })) };
  }
  throw new Error(`No sample answer for ${method} ${path}`);
}

async function getToken(scopes, interactive) {
  const req = { scopes, account };
  try { return (await msalApp.acquireTokenSilent(req)).accessToken; }
  catch (e) { if (!interactive) throw e; return VmfHelp.tokenOrRedirect(msalApp, req); }
}
const GRAPH_SCOPES = ['AppRoleAssignment.ReadWrite.All', 'Application.Read.All',
  'User.ReadBasic.All', 'Group.Read.All'].map(s => `https://graph.microsoft.com/${s}`);

/* CONSENT-SPLIT-1: SILENT BY DEFAULT, for the reason `arm` below already
   carries. POPUP-2 found that an interactive default puts the bug back: a call
   that forgets the argument asks the directory while the page is still
   loading, which nobody clicked for. Since POPUP-3 that is worse than a
   blocked popup - it navigates the page away.
   So reading is silent, and the four calls that CHANGE something say `true`,
   because each of them follows a click. A call that forgets now fails safe:
   it throws, and a card offers a button. */
async function graph(method, path, body, interactive = false) {
  if (DEMO_MODE) return demoAnswer('graph', method, path, body);
  const token = await getToken(GRAPH_SCOPES, interactive);
  const r = await fetch(`https://graph.microsoft.com/v1.0/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, ...(body ? { 'Content-Type': 'application/json' } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (r.status === 204) return null;
  const data = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(data?.error?.message ?? `HTTP ${r.status}`);
  return data;
}
function flash(el, msg) { $(el).textContent = msg; $(el).style.display = 'block'; setTimeout(() => { $(el).style.display = 'none'; }, 8000); }
function fail(e) { $('#err').textContent = VmfHelp.explain(e); $('#err').style.display = 'block'; }
// Something the PERSON did. Never blames Azure RBAC - the facade refuses
// an action on APP ROLE, and its storage permission is not involved.
function failAction(e) { $('#err').textContent = VmfHelp.explainAction(e); $('#err').style.display = 'block'; }

// SCOPE-ADD-1: an admin function, run as the signed-in user, onboards more
// scopes from the portal and other tooling.
//
// AS THE SIGNED-IN USER, exactly as the role assignment above already works.
// The earlier plan was to hand back an az command, and it was refused: a user
// must not be sent to separate PowerShell commands outside the app (hard
// rule 12).
//
// The security argument for the handoff was that an app able to widen its own
// scope cannot be bounded. That argument is real, and it is fully satisfied by
// doing it this way instead - the app never holds the right to grant roles,
// the PERSON does, with their own token. An administrator who lacks it gets
// their own 403, which is the correct and auditable answer, and the tenant's
// log carries their name rather than the service's.
const ARM = 'https://management.azure.com';
const ARM_SCOPES = ['https://management.azure.com/user_impersonation'];
let subs = [];

// Azure is a SECOND consent, separate from the directory one this page already
// has. Asking for it while the page loads makes the browser block the popup -
// which is what shipped, and the card rendered "Failed to fetch" with no way
// forward. A popup has to follow a click, so reading is silent-only and the
// card asks for the one gesture it needs.
//
// POPUP-2: THE DEFAULT WAS `true`, AND THAT PUT THE BUG BACK. POPUP-1 guarded
// the FIRST call in loadScopes and passed `interactive` to it. The two reads
// INSIDE its loop took no fourth argument at all, so they defaulted to
// interactive and asked for a popup while the page was still loading, which
// the browser blocked - a popup that should never have been asked for.
//
// The default is SILENT now, so a call that forgets the argument fails safe -
// it throws, and a card offers a button - instead of asking the browser for a
// popup nobody clicked for. Every call that KNOWS a gesture is behind it says
// so, and they are all mutations: the two grants, the widen, and the two
// removals.
async function arm(method, path, body, interactive = false) {
  if (DEMO_MODE) return demoAnswer('arm', method, path, body);
  const token = await getToken(ARM_SCOPES, interactive);
  const r = await fetch(`${ARM}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) {
    const text = await r.text();
    const err = new Error(text || `${r.status}`);
    err.status = r.status;
    throw err;
  }
  return r.status === 204 ? null : r.json();
}

/* ROLES-1 part 2: the two custom roles, BY ID.
 *
 * This used to list custom roles at the scope being granted and take the first
 * whose name began 'VMF Assessment'. That also finds roles inherited from a
 * management group above, and roles another install of the product made, and
 * there is no defined order to choose between them - so it could grant the
 * WRONG definition, with different permissions, and say nothing at all.
 *
 * The ids come from dashboard.config.json, written by the publish from the
 * subscription the roles are defined in. Microsoft's own advice is to use the
 * id: a role can be renamed and its id does not move.
 */
function vmfRoleId(mode) {
  return mode === 'migrate' ? (cfg.migrateRoleId || '') : (cfg.assessRoleId || '');
}

async function vmfRoleDefinition(mode) {
  const id = vmfRoleId(mode);
  if (!id) { return null; }
  // The definition is fetched every time rather than cached: its list of
  // places changes, and a stale copy would either widen something already
  // wide or skip a widening that was needed.
  return arm('GET', `${id}?api-version=2022-04-01`);
}

function isManagementGroupScope(scope) {
  return String(scope || '').toLowerCase().startsWith('/providers/microsoft.management/managementgroups/');
}

function subscriptionIdOf(scope) {
  const m = /^\/subscriptions\/([^/]+)/i.exec(String(scope || ''));
  return m ? m[1] : '';
}

/* Is this scope already reachable, judging by the strings alone?
 *
 * A role may be granted AT anything in its list, or anywhere BENEATH it. For
 * subscriptions and resource groups that is a path, so a prefix answers it.
 * IT DOES NOT ANSWER IT FOR A MANAGEMENT GROUP: a subscription beneath the
 * group '/providers/.../managementGroups/x' has a path of '/subscriptions/...'
 * and shares no prefix with it at all. scopeIsCovered asks Azure for that case.
 */
function scopeCoveredBy(scope, assignableScopes) {
  const target = String(scope || '').toLowerCase().replace(/\/+$/, '');
  if (!target) { return false; }
  return (assignableScopes || []).some((entry) => {
    const at = String(entry || '').toLowerCase().replace(/\/+$/, '');
    return at !== '' && (target === at || target.startsWith(at + '/'));
  });
}

/* SCOPE-COVER-1: a grant inside a wider grant adds nothing, and the card said
 * nothing about it.
 *
 * Role assignments do not narrow one another. A grant at a subscription
 * reaches every resource group in it, so a second grant on one of those
 * resource groups changes nothing - and REMOVING the smaller one changes
 * nothing either. The card listed both as separate rows, which reads as two
 * different permissions and makes removing the smaller one look like a way to
 * scope the product down. It is not.
 *
 * The roles card on this same page already marks a directory role that another
 * role includes. This is that same fact about the other half of the page.
 *
 * Only what the ids PROVE is marked. A subscription under a management group
 * is covered in Azure, but the ids do not say so - the caller reads the
 * descendants and passes them, and a call that failed passes nothing, so
 * nothing is marked. Unknown is not a yes.
 */
// A row's MODE, not the words it shows. Ranking permission by comparing a
// display string would break silently the day somebody rewords the column.
function scopeReach(mode) { return mode === 'migrate' ? 2 : 1; }

function scopeNormalize(scope) {
  return String(scope || '').toLowerCase().replace(/\/+$/, '');
}

function scopeIsUnder(inner, outer, descendants) {
  const a = scopeNormalize(inner);
  const b = scopeNormalize(outer);
  if (!a || !b) { return false; }
  // No `a === b` guard: two equal ids fail the separator test below, and a
  // management group is never its own descendant. Mutation showed a guard
  // there changed nothing, and a branch nothing can reach is a lie about what
  // the code does.
  if (a.startsWith(b + '/')) { return true; }
  // A management group's children are a fact only Azure holds.
  const under = (descendants && descendants.get) ? descendants.get(b) : null;
  if (!under) { return false; }
  // ACCESS-PAIR-COVER-1: a management group under another one. Azure lists
  // the child groups among the descendants, by their full id.
  if (under.has(a)) { return true; }
  const subId = subscriptionIdOf(a);
  return !!(subId && under.has(`/subscriptions/${subId}`.toLowerCase()));
}

function scopeCovers(outer, inner, descendants) {
  if (!outer || !inner || !outer.scope || !inner.scope) { return false; }
  // ACCESS-SERVICE-ORPHAN-1: a web service only row gives the engine nothing,
  // and an engine grant does not hold the web service read it shows.
  if (outer.reach === 'service-only' || inner.reach === 'service-only') { return false; }
  // Assess and migrate includes assess. A WIDER place with a NARROWER
  // permission still adds something, so it covers nothing.
  const spare = scopeReach(outer.mode) - scopeReach(inner.mode);
  if (spare < 0) { return false; }
  if (scopeIsUnder(inner.scope, outer.scope, descendants)) { return true; }
  return spare > 0 && scopeNormalize(inner.scope) === scopeNormalize(outer.scope);
}

function scopeRowsWithCoverage(rows, descendants) {
  const all = rows || [];
  return all.map(r => {
    // A place that no longer exists is already explained by its own mark.
    if (r.stale) { return r; }
    const covering = all.filter(o => o !== r && scopeCovers(o, r, descendants));
    if (!covering.length) { return r; }
    // The OUTERMOST one, so a resource group under a subscription under a
    // management group names the management group rather than whichever row
    // Azure happened to list first.
    const top = covering.find(c => !covering.some(o => o !== c && scopeCovers(o, c, descendants)));
    return { ...r, coveredBy: (top || covering[0]).name };
  });
}

/* ACCESS-PAIR-COVER-1: the web service read access an engine grant gets from
 * a WIDER place.
 *
 * loadScopes pairs an engine grant with the web service assignment AT ITS
 * PLACE. But Azure role assignments are inherited: a web service assignment
 * at a subscription reads every resource group in it, and one at a
 * management group reads every subscription under it. So a row with no pair
 * at its place, inside a place the web service holds, is not "The engine
 * only" - its lists of machines work.
 *
 * Only what is PROVEN covers, by scopeIsUnder: the ids for a resource group
 * in a subscription, and Azure's own list of descendants for a management
 * group. A management group whose list could not be read is CANNOT TELL
 * ('unknown'), never covered and never "The engine only".
 *
 * The web service assignments are the ones the rows show, so a removal this
 * tab made (SCOPE-LAG-1) covers nothing while Azure still lists it. The pair a
 * Remove deletes does not change: `serviceId` stays the one at the row's own
 * place, so removing a covered grant never takes the wider read access. */
function scopeServiceHeld(rows) {
  const held = new Map();
  for (const r of rows || []) {
    const id = r.reach === 'service-only' ? r.id : r.serviceId;
    if (id && r.scope && !held.has(id)) { held.set(id, { id, scope: r.scope, name: r.name }); }
  }
  return [...held.values()];
}

function scopeRowsWithServiceCover(rows, descendants) {
  const held = scopeServiceHeld(rows);
  return (rows || []).map(r => {
    if (r.reach !== 'engine-only') { return r; }
    const via = held.filter(h => scopeIsUnder(r.scope, h.scope, descendants));
    // A management group this page could not read may hold this place.
    const blind = held.filter(h => isManagementGroupScope(h.scope) && !via.includes(h) &&
      !(descendants && descendants.has && descendants.has(scopeNormalize(h.scope))));
    if (via.length) {
      // The OUTERMOST, as SCOPE-COVER-1 names it.
      const top = via.find(c => !via.some(o => o !== c && scopeIsUnder(c.scope, o.scope, descendants))) || via[0];
      return { ...r, reach: 'full', serviceVia: via.map(h => h.id), serviceViaName: top.name,
               serviceBlind: blind.map(h => h.name) };
    }
    if (blind.length) { return { ...r, reach: 'unknown', serviceBlind: blind.map(h => h.name) }; }
    return r;
  });
}

/* ACCESS-PAIR-COVER-1: the places whose web service read access goes with
 * this removal. `shared` is scopeServiceInUse for the row: a web service
 * assignment another grant on the place uses is kept, so nothing goes.
 * A place that a management group this page cannot read may still cover is
 * named, with that doubt said. Returns the lines for the question. */
function scopeReadLosses(removing, rows, shared) {
  const takes = removing.reach === 'service-only' ? removing.id : (shared ? null : removing.serviceId);
  if (!takes) { return []; }
  const lines = [];
  for (const o of rows || []) {
    if (o === removing || o.stale || !Array.isArray(o.serviceVia) || !o.serviceVia.includes(takes)) { continue; }
    if (o.serviceVia.some(id => id !== takes)) { continue; }    // another wider grant still gives it
    const line = (o.serviceBlind || []).length ? UX.scopeLosesMaybe.replace('{place}', o.name) : o.name;
    if (!lines.includes(line)) { lines.push(line); }
  }
  return lines;
}

/* The list these roles should carry once this scope is added, or the reason
 * they cannot. Azure permits only ONE management group in a role.
 */
function widenScopes(existing, scope) {
  const have = (existing || []).map(x => String(x || '').replace(/\/+$/, '')).filter(Boolean);
  const want = String(scope || '').replace(/\/+$/, '');
  if (!want) { return { error: UX.scopeNoRole }; }
  if (have.some(x => x.toLowerCase() === want.toLowerCase())) { return { scopes: have }; }
  if (isManagementGroupScope(want)) {
    const already = have.find(isManagementGroupScope);
    if (already) {
      return { error: UX.scopeSecondGroup.replace('{have}', already).replace('{want}', want) };
    }
  }
  return { scopes: have.concat([want]) };
}

/* Does this role already reach the scope? The string test first, because it
 * costs nothing, then the one question strings cannot answer.
 */
async function scopeIsCovered(scope, def) {
  const reach = def?.properties?.assignableScopes || [];
  if (scopeCoveredBy(scope, reach)) { return true; }
  const group = reach.find(isManagementGroupScope);
  const subId = subscriptionIdOf(scope);
  if (!group || !subId) { return false; }
  // A subscription beneath the group is covered, and only Azure knows the
  // shape of the tree.
  try {
    const kids = await arm('GET', `${group}/descendants?api-version=2021-04-01`);
    return (kids.value || []).some(d => String(d.id || '').toLowerCase() === `/subscriptions/${subId}`.toLowerCase());
  }
  catch { return false; }
}

// The scope as the person picked it: a resource group by its name, a
// subscription by the name Azure shows, a management group by its name. The
// full id is what Azure needs and what nobody can read.
function placeName(scope) {
  const rg = String(scope).match(/\/resourceGroups\/([^/]+)/i);
  if (rg) { return rg[1]; }
  if (isManagementGroupScope(scope)) { return String(scope).split('/').pop(); }
  const sub = subscriptionIdOf(scope);
  const known = (subs || []).find(x => x.subscriptionId === sub);
  return known ? known.displayName : scope;
}

/* SCOPE-LAG-1. A scope added on this page took a minute or two of refreshing
 * before it appeared.
 *
 * The cause is not this page being slow. Azure's roleAssignments LIST is
 * eventually consistent - a grant made seconds ago is not in it for a minute
 * or two. The page was asking that list and throwing away the only
 * authoritative answer it had: the PUT that created the assignment returns 201
 * WITH THE CREATED OBJECT, which is Azure confirming the grant exists.
 *
 * So the page remembers what it just did and merges it, until Azure's list
 * agrees. This is not optimism - both records come from a call Azure answered.
 * The same lag hides a REMOVAL, which is worse: the standing ruling in this
 * product is that a removal must remove, and a row that lingers for two
 * minutes reads as one that did not.
 *
 * Reconciled on every load: an added id is forgotten once the list carries it,
 * a removed id once the list drops it. A ten minute cap means a pathological
 * case ends with Azure believed, never with this page insisting forever.
 *
 * sessionStorage, so a reload does not make the row vanish again - which would
 * be more confusing than never showing it. Every access is wrapped: a private
 * window that refuses storage simply gets the old behaviour.
 */
const SCOPE_LAG_KEY = 'vmf-scope-lag';
const SCOPE_LAG_MS = 600000;

/* ACCESS-LAG-WORDS-1: the assignments a record names.
 *
 * A grant is TWO role assignments - the engine's and the web service's
 * (ACCESS-HALF-1) - and so is a removal. The page kept only the engine's, so
 * while Azure listed one of the two the row was drawn from part of the grant.
 * A record now names every assignment, the engine's first, because the
 * engine's is the one that draws the row. A record an older page left names
 * one, in `id`, and still reads. */
function scopeLagIds(r) {
  const list = Array.isArray(r?.ids) ? r.ids : [r?.id];
  return list.filter(x => typeof x === 'string' && x);
}

function scopeLagRead() {
  try {
    const raw = sessionStorage.getItem(SCOPE_LAG_KEY);
    const all = raw ? JSON.parse(raw) : [];
    const known = (Array.isArray(all) ? all : []).filter(r => r && typeof r === 'object' &&
      (r.action === 'added' || r.action === 'removed') && scopeLagIds(r).length);
    return known.filter(r => (Date.now() - (r.atMs || 0)) < SCOPE_LAG_MS);
  } catch { return []; }
}

function scopeLagWrite(records) {
  try { sessionStorage.setItem(SCOPE_LAG_KEY, JSON.stringify(records)); } catch { /* nothing to do */ }
}

function scopeLagNote(action, ids, row) {
  const list = [].concat(ids || []).filter(x => typeof x === 'string' && x);
  if (!list.length) return;
  // The later word about an assignment replaces the earlier one.
  const kept = scopeLagRead().filter(r => !scopeLagIds(r).some(x => list.includes(x)));
  kept.push({ action, id: list[0], ids: list, atMs: Date.now(), row: row || null });
  scopeLagWrite(kept);
}

/* What the page should show, given what Azure listed and what we just did.
 * Pure, so a test can drive every combination without a browser or a token. */
/* LAG-FLAP-1: a record lives until it EXPIRES, never until the list first
 * agrees with it.
 *
 * The first version forgot a record the moment Azure's list stopped carrying
 * the row - "Azure caught up, we are done". THAT IS NOT WHAT EVENTUAL
 * CONSISTENCY MEANS. It is not monotonic: a later read can reach an older
 * replica and hand back the row again, and by then the record that would have
 * hidden it had been thrown away.
 *
 * MEASURED IN THE PRODUCT, 2026-09-20. Two scopes removed; both deletes
 * succeeded in Azure. One row went, came BACK on a later refresh, and went
 * again for good a minute later. The assumption held for one of them and not
 * the other, which is what an assumption about replicas looks like.
 *
 * Keeping a record to its ten minute cap is safe in both directions:
 *   - a removal record hides a row only while Azure still lists it. Once Azure
 *     really has dropped it, the record hides nothing.
 *   - it cannot hide a RE-GRANT of the same place, because every grant is a
 *     PUT to a fresh crypto.randomUUID() and so carries a different id.
 *   - an add record shows a row only while Azure has not listed it yet.
 *
 * `acting` is the third thing this returns: the records that changed what is
 * on screen THIS load. The explanation belongs to those, not to every record
 * still being remembered - or it sits under a settled table for ten minutes
 * explaining a lag that is over.
 */
/* ACCESS-LAG-WORDS-1: a record draws its row until Azure lists EVERY
 * assignment in it, never from the part Azure has listed so far.
 *
 * `otherListed` is the web service's assignments Azure listed, or null when
 * that list could not be read. Cannot tell is never yes and never no, so then
 * a record is judged on the engine's assignment alone - the row Azure drew. */
function scopeRowsWithLag(listed, pending, otherListed) {
  const records = (pending || [])
    .filter(p => p && (p.action === 'added' || p.action === 'removed'))
    .map(p => ({ p, ids: scopeLagIds(p) }))
    .filter(x => x.ids.length);
  const seen = new Set();
  for (const r of listed || []) {
    if (r.id) { seen.add(r.id); }
    if (r.serviceId) { seen.add(r.serviceId); }
  }
  for (const id of otherListed || []) { seen.add(id); }
  const removed = new Set();
  for (const x of records) { if (x.p.action === 'removed') { x.ids.forEach(id => removed.add(id)); } }
  const keep = [];
  const rows = [];
  const acting = [];

  // The adds Azure has not listed whole. Each one draws its row from the
  // record, and the part Azure has listed draws nothing.
  const ahead = [];
  for (const x of records) {
    if (x.p.action === 'removed') { keep.push(x.p); continue; }
    // Added, then removed again, both inside the window. The removal is the
    // later word, so the row must not come back - and the removal record alone
    // says everything the pair said.
    if (x.ids.some(id => removed.has(id))) { continue; }
    keep.push(x.p);
    const judged = otherListed === null ? x.ids.slice(0, 1) : x.ids;
    if (x.p.row && !judged.every(id => seen.has(id))) { ahead.push(x); }
  }
  const fromRecord = new Set(ahead.map(x => x.ids[0]));
  // ACCESS-SERVICE-ORPHAN-1: a web service only row is part of a grant the
  // record draws when the record sits at its place - the same pairing
  // loadScopes uses. Every record's row carries its scope (grantScopeNow).
  const partOfAhead = (r) => r.reach === 'service-only' &&
    ahead.some(x => scopeNormalize(x.p.row.scope) === scopeNormalize(r.scope));

  for (const r of listed || []) {
    if (removed.has(r.id)) { acting.push(r.id); continue; }   // we deleted it; Azure still lists it
    if (fromRecord.has(r.id)) { continue; }                   // the record draws this grant whole
    if (partOfAhead(r)) { continue; }
    rows.push(r);
  }
  // Only ahead of Azure while Azure has not listed all of it. Once it has, the
  // row is Azure's and carries no mark.
  for (const x of ahead) {
    rows.push({ ...x.p.row, id: x.ids[0], serviceId: x.ids[1] || null, justAdded: true });
    acting.push(x.ids[0]);
  }
  return { rows, keep, acting };
}

/* ACCESS-MG-ROW-TWICE-1: one row for each role assignment.
 *
 * loadScopes lists each identity's assignments once for each subscription,
 * with `$filter=principalId eq`. Microsoft's "Role Assignments - List For
 * Scope" page (api-version 2022-04-01) says that filter returns the
 * assignments "at, above or below the scope". So an assignment at a
 * management group comes back in every subscription under it, and the page
 * drew a row each time: one grant shown as several.
 *
 * Rows are kept by the assignment's id, in any case. Of the copies, the one
 * that read its web service pair wins, then one whose read was not "cannot
 * tell": a subscription whose web service list failed must not make the
 * grant look unread when another subscription read it. And a web service
 * assignment an engine row is paired with in one subscription is not a web
 * service only row because another subscription's engine list did not carry
 * the grant yet (SCOPE-LAG-1). */
function scopeRowsOnce(rows) {
  const key = (id) => String(id || '').toLowerCase();
  const rank = (r) => (r.serviceId ? 2 : r.reach !== 'unknown' ? 1 : 0);
  const kept = new Map();
  for (const r of rows || []) {
    const k = key(r.id);
    const had = kept.get(k);
    if (!had || rank(r) > rank(had)) { kept.set(k, r); }
  }
  const paired = new Set();
  for (const r of kept.values()) {
    if (r.serviceId) { paired.add(key(r.serviceId)); }
  }
  // An assignment another row already shows as its pair draws no row itself.
  return [...kept.values()].filter(r => !paired.has(key(r.id)));
}

async function loadScopes(interactive = false) {
  const host = $('#scope-list');
  host.textContent = UX.scopeReading;
  const pid = cfg.enginePrincipalId;
  if (!pid) { host.textContent = UX.scopeNone; return; }

  let list;
  try { list = await arm('GET', '/subscriptions?api-version=2022-12-01', null, interactive); }
  catch (e) {
    // No Azure consent yet. That is not an error to display - it is a button.
    //
    // CONSENT-STUCK-1: the FORM goes too. Without Azure there are no
    // subscriptions to list, so it rendered an empty picker that looked broken
    // and a grant button that could not work.
    $('#scope-add').style.display = 'none';
    host.innerHTML = `<p class="muted">${esc(UX.scopeConnect)}</p>` +
      `<p class="muted" style="max-width:60ch">${esc(UX.scopeConnectRefused)}</p>` +
      `<button type="button" class="btn" id="scope-connect">${esc(UX.scopeConnectBtn)}</button>`;
    $('#scope-connect').addEventListener('click', () => {
      const btn = $('#scope-connect');
      btn.disabled = true;
      // VmfHelp.explain, not the raw message: a refusal reads as a sentence.
      loadScopes(true)
        .catch(err => { host.textContent = VmfHelp.explain(err); })
        .finally(() => { const b = $('#scope-connect'); if (b) { b.disabled = false; } });
    });
    return;
  }
  $('#scope-add').style.display = '';
  subs = (list.value || []).filter(x => x.state === 'Enabled');
  // PAGE-WAIT-1: the add-a-place picker needs only the subscriptions, so it
  // is filled now and its resource groups read BESIDE the grants below. It
  // waited for every subscription's grants to be read first.
  $('#scope-pick').innerHTML = subs.map(sb =>
    `<option value="${esc(sb.subscriptionId)}">${esc(sb.displayName)}</option>`).join('');
  const groupsLoad = loadResourceGroups();
  groupsLoad.catch(() => { });   // awaited at the end, where its failure still surfaces

  // A role assignment lives at a scope, and listing at the subscription returns
  // the ones BELOW it too - so a grant on a single resource group appears here
  // rather than staying invisible until somebody wonders why the product can see
  // machines nobody remembers granting.
  const rows = [];
  // ACCESS-HALF-1: set when the web service half could not be read anywhere,
  // so the page can say "cannot tell" once rather than guess per row.
  let serviceUnreadable = false;
  const ourRoleGuids = {
    assess: vmfRoleId('assess').split('/').pop(),
    migrate: vmfRoleId('migrate').split('/').pop(),
  };
  /* PAGE-WAIT-1: each subscription was read in turn, and inside each the web
   * service's grants waited for the engine's. Nothing crosses subscriptions,
   * so they are read together - paced, and kept in subscription order. */
  const perSub = await VmfHelp.mapLimited(subs, async (sub) => {
    const subRows = [];
    const serviceIds = [];
    let subUnreadable = false;
    try {
      const serviceRead = cfg.webServicePrincipalId
        ? arm('GET', `/subscriptions/${sub.subscriptionId}` +
            `/providers/Microsoft.Authorization/roleAssignments` +
            `?api-version=2022-04-01&$filter=principalId+eq+'${cfg.webServicePrincipalId}'`, null, interactive)
        : null;
      serviceRead?.catch(() => { });   // read below; a failure there means "cannot tell"
      const ra = await arm('GET', `/subscriptions/${sub.subscriptionId}` +
        `/providers/Microsoft.Authorization/roleAssignments` +
        `?api-version=2022-04-01&$filter=principalId+eq+'${pid}'`, null, interactive);
      const assignments = ra.value || [];

      // ACCESS-HALF-1: what the WEB SERVICE holds in this subscription.
      // Every list the product shows comes from it, so a scope the engine
      // holds alone is not the product reaching that scope. `null` stays
      // "cannot tell" and is never drawn as covered.
      // ACCESS-SERVICE-ORPHAN-1: read before the engine list can end this
      // subscription, because a web service assignment with no engine grant
      // is a row too.
      let serviceScopes = null;
      const serviceOurs = [];
      if (serviceRead) {
        try {
          const sa = await serviceRead;
          serviceScopes = new Map();
          for (const a of (sa.value || [])) {
            const d = a.properties.roleDefinitionId || '';
            const ours = (ourRoleGuids.assess && d.endsWith(ourRoleGuids.assess)) ||
                         (ourRoleGuids.migrate && d.endsWith(ourRoleGuids.migrate));
            if (ours) { serviceScopes.set(scopeNormalize(a.properties.scope), a.id); serviceIds.push(a.id); serviceOurs.push(a); }
          }
        } catch (e) { serviceScopes = null; }
      }
      if (serviceScopes === null) { subUnreadable = true; }
      if (!assignments.length && !serviceOurs.length) return { subRows, serviceIds, subUnreadable };

      // The resource groups that exist RIGHT NOW, read once per subscription
      // and only when a grant actually points at one.
      let liveGroups = null;
      const needsGroups = assignments.concat(serviceOurs).some(a => /\/resourceGroups\//i.test(a.properties.scope || ''));
      if (needsGroups) {
        try {
          const g = await arm('GET', `/subscriptions/${sub.subscriptionId}/resourcegroups?api-version=2021-04-01`, null, interactive);
          liveGroups = new Set((g.value || []).map(x => x.name.toLowerCase()));
        } catch (e) { liveGroups = null; }         // cannot tell is not the same as gone
      }

      const engineKeys = new Set();
      for (const a of assignments) {
        const defId = a.properties.roleDefinitionId || '';
        // ROLES-1: compared against the ids this install was published with,
        // rather than against whatever a per-subscription name lookup returned.
        // One pair of roles serves every scope now, so there is nothing to look
        // up per subscription - and the old lookup could match another
        // install's role and label its grant as ours.
        const mode = (ourRoleGuids.migrate && defId.endsWith(ourRoleGuids.migrate)) ? 'migrate'
          : (ourRoleGuids.assess && defId.endsWith(ourRoleGuids.assess)) ? 'assess'
          : null;
        if (!mode) continue;                       // some other role, not ours
        const what = mode === 'migrate' ? UX.scopeChange : UX.scopeLook;
        const where = describeScope(a.properties.scope, sub);
        // A deleted resource group kept its row here.
        // A grant on a resource group that has been deleted
        // does nothing, and it reads as access the product still has. Only ever
        // marked when the groups were READ successfully - a listing that failed
        // means "cannot tell", which must never be shown as "gone".
        const rgName = (a.properties.scope || '').match(/\/resourceGroups\/([^/]+)/i);
        const stale = !!(rgName && liveGroups && !liveGroups.has(rgName[1].toLowerCase()));
        // ACCESS-HALF-1: does the PRODUCT reach this, or only the engine?
        const key = scopeNormalize(a.properties.scope);
        engineKeys.add(key);
        const serviceHas = serviceScopes === null ? null : serviceScopes.has(key);
        const reach = productReach(true, serviceHas);
        subRows.push({ ...where, what, mode, stale, id: a.id, scope: a.properties.scope,
                       reach, serviceId: serviceScopes ? (serviceScopes.get(key) || null) : null });
      }
      // ACCESS-SERVICE-ORPHAN-1: a web service assignment with no engine
      // grant AT ITS PLACE - the same pairing as above - is access nobody
      // could see or remove. It draws its own row, and its id is the row's.
      for (const a of serviceOurs) {
        const key = scopeNormalize(a.properties.scope);
        if (engineKeys.has(key)) { continue; }
        const rgName = (a.properties.scope || '').match(/\/resourceGroups\/([^/]+)/i);
        subRows.push({ ...describeScope(a.properties.scope, sub), what: UX.scopeLook, mode: 'assess',
                       stale: !!(rgName && liveGroups && !liveGroups.has(rgName[1].toLowerCase())),
                       id: a.id, scope: a.properties.scope, reach: productReach(false, true), serviceId: null });
      }
    } catch (e) { /* a subscription the reader cannot see is not an error here */ }
    return { subRows, serviceIds, subUnreadable };
  });
  // ACCESS-LAG-WORDS-1: the web service's assignments Azure listed, so a
  // grant the page made is shown whole until Azure lists both halves of it.
  const listedServiceIds = [];
  for (const s of perSub) {
    rows.push(...s.subRows);
    listedServiceIds.push(...(s.serviceIds || []));
    if (s.subUnreadable) { serviceUnreadable = true; }
  }

  // SCOPE-LAG-1: what Azure listed, plus what this page did that Azure has not
  // caught up with yet, minus what it removed and Azure still lists.
  // ACCESS-MG-ROW-TWICE-1: first, one row for each assignment.
  const merged = scopeRowsWithLag(scopeRowsOnce(rows), scopeLagRead(), serviceUnreadable ? null : listedServiceIds);
  scopeLagWrite(merged.keep);
  // SCOPE-COVER-1: and then say which of those rows is already covered.
  // ACCESS-PAIR-COVER-1: after the web service read access each row gets
  // from a wider place. The descendants are read for every management group
  // in the rows, the web service only rows included.
  const descendants = await scopeDescendants(merged.rows, interactive);
  const shown = scopeRowsWithCoverage(scopeRowsWithServiceCover(merged.rows, descendants), descendants);
  // ACCESS-PAIR-COVER-1: what each Remove takes from the places below it.
  const losses = new Map();

  host.innerHTML = shown.length
    ? `<table><thead><tr><th>${esc(UX.scopeColWhere)}</th><th>${esc(UX.scopeColLevel)}</th>` +
      `<th>${esc(UX.scopeModeLabel)}</th><th></th></tr></thead><tbody>` +
      shown.map(r => {
        const shared = r.reach !== 'service-only' && scopeServiceInUse(r, merged.rows, []);
        losses.set(r.id, scopeReadLosses(r, shown, shared));
        return `<tr><td>${esc(r.name)}${
          r.stale ? ` <span class="pill quiet">${esc(UX.scopeGone)}</span>` : ''
        }${
          r.justAdded ? ` <span class="pill quiet">${esc(UX.scopeJustAdded)}</span>` : ''
        }${
          r.coveredBy ? ` <span class="pill quiet">${esc(UX.scopeCoveredBy.replace('{place}', r.coveredBy))}</span>` : ''
        }${
          // ACCESS-HALF-1: the engine reaches it and the web service does not,
          // so every list of machines here comes back empty.
          r.reach === 'engine-only' ? ` <span class="pill warn">${esc(UX.scopeHalfNote)}</span>` : ''
        }${
          r.reach === 'service-only' ? ` <span class="pill warn">${esc(UX.scopeServiceOnlyNote)}</span>` : ''
        }${
          r.serviceViaName ? ` <span class="pill quiet">${esc(UX.scopeServiceVia.replace('{place}', r.serviceViaName))}</span>` : ''
        }${
          r.reach === 'unknown' && (r.serviceBlind || []).length
            ? ` <span class="pill warn">${esc(UX.scopeServiceBlind.replace('{place}', r.serviceBlind[0]))}</span>` : ''
        }</td><td class="muted">${esc(r.level)}</td>` +
        `<td>${esc(r.what)}</td>` +
        `<td style="text-align:right"><button type="button" class="btn ghost" style="padding:4px 12px;font-size:12px"` +
        ` data-revoke="${esc(r.id)}"${r.serviceId ? ` data-revoke2="${esc(r.serviceId)}"` : ''}${
          // ACCESS-REMOVE-SHARED-1: another row uses this row's web service
          // assignment, so the question says Remove keeps it. The removal
          // asks Azure again before it deletes anything.
          // ACCESS-SERVICE-ORPHAN-1: a web service only row IS the web
          // service assignment, so its Remove deletes that one and no other.
          r.reach === 'service-only' ? ' data-serviceonly="1"'
            : shared ? ' data-shared="1"' : ''
        }>${esc(UX.scopeRemove)}</button>${
          // ACCESS-HALF-1: a half-granted place needs a way FORWARD, not only
          // a way to destroy the half that works.
          r.reach === 'engine-only' && cfg.webServicePrincipalId
            ? ` <button type="button" class="btn" style="padding:4px 12px;font-size:12px" data-fixhalf="${esc(r.scope)}">${esc(UX.scopeHalfFix)}</button>`
            : ''
        }</td></tr>`;
      }).join('') +
      '</tbody></table>' +
      (shown.some(r => r.stale) ? `<p class="muted" style="margin-top:10px">${esc(UX.scopeGoneWhy)}</p>` : '') +
      (shown.some(r => r.coveredBy) ? `<p class="muted" style="margin-top:10px">${esc(UX.scopeCoveredWhy)}</p>` : '') +
      (shown.some(r => r.reach === 'service-only') ? `<p class="muted" style="margin-top:10px">${esc(UX.scopeServiceOnlyWhy)}</p>` : '') +
      (serviceUnreadable ? `<p class="muted" style="margin-top:10px">${esc(UX.scopeHalfUnknown)}</p>` : '') +
      (merged.acting.length ? `<p class="muted" style="margin-top:10px">${esc(UX.scopeLagWhy)}</p>` : '')
    : `<p class="muted">${esc(UX.scopeNone)}</p>`;

  host.querySelectorAll('button[data-revoke]').forEach(b =>
    b.addEventListener('click', () => revokeScope(b.dataset.revoke, b, b.dataset.revoke2 || null, b.dataset.shared === '1',
      b.dataset.serviceonly === '1', losses.get(b.dataset.revoke) || [])));

  host.querySelectorAll('button[data-fixhalf]').forEach(b =>
    b.addEventListener('click', () => repairHalfScope(b.dataset.fixhalf, b)));

  await groupsLoad;
}

/* Which subscriptions sit under each management group in these rows.
 *
 * SCOPE-COVER-1 can prove a resource group is inside a subscription from the
 * ids alone. A management group is the one case it cannot, so it is asked -
 * and only when a row is actually at that level, which most estates never are.
 *
 * A call that fails leaves the group out of the map, so its children are not
 * marked. "Cannot tell" must never be shown as "already covered".
 */
async function scopeDescendants(rows, interactive) {
  const groups = [...new Set((rows || []).map(r => r.scope).filter(s => isManagementGroupScope(s)))];
  const map = new Map();
  // PAGE-WAIT-1: the groups are independent, so they are asked together.
  await Promise.all(groups.map(async (g) => {
    try {
      const kids = await arm('GET', `${g}/descendants?api-version=2021-04-01`, null, interactive);
      map.set(scopeNormalize(g),
        new Set((kids.value || []).map(d => String(d.id || '').toLowerCase())));
    } catch (e) { /* cannot tell is not covered */ }
  }));
  return map;
}

// What a scope id IS, in words. `/subscriptions/x/resourceGroups/y` is a
// resource group; the same string without that tail is the subscription; and a
// management group is a different shape entirely.
function describeScope(scope, sub) {
  const s = String(scope || '');
  const rg = s.match(/\/resourceGroups\/([^/]+)/i);
  if (rg) return { name: `${rg[1]} (${sub.displayName})`, level: UX.scopeLevelNameRg };
  const mg = s.match(/\/managementGroups\/([^/]+)/i);
  if (mg) return { name: mg[1], level: UX.scopeLevelNameMg };
  return { name: sub.displayName, level: UX.scopeLevelNameSub };
}

// The resource groups of whichever subscription is picked. Read on demand: a
// call per subscription up front pays for a list most people never open.
async function loadResourceGroups() {
  const sel = $('#scope-rg');
  const subId = $('#scope-pick')?.value;
  if (!sel || !subId) return;
  sel.innerHTML = `<option value="">${esc(UX.scopeRgLoading)}</option>`;
  try {
    const r = await arm('GET', `/subscriptions/${subId}/resourcegroups?api-version=2021-04-01`);
    const groups = (r.value || []).sort((a, b) => a.name.localeCompare(b.name));
    sel.innerHTML = groups.length
      ? groups.map(g => `<option value="${esc(g.name)}">${esc(g.name)}</option>`).join('')
      : `<option value="">${esc(UX.scopeRgNone)}</option>`;
  } catch (e) {
    sel.innerHTML = `<option value="">${esc(UX.scopeRgNone)}</option>`;
  }
}

/* Management groups the signed-in person can read.
 *
 * Management group scope needs a plain message when somebody does not hold
 * rights at that level, which is usually higher than their own.
 *
 * There are three separate ordinary answers here, none of them an
 * error: the directory has no management groups, the account cannot read them,
 * or it can read them and still cannot grant at that level. The first two are
 * answered here; the third is answered by the 403 on the grant itself. Each
 * one says what to do instead, because "look and change at a subscription" is
 * a real alternative that most people can actually use.
 */
async function loadManagementGroups() {
  const sel = $('#scope-mg');
  const note = $('#scope-mg-note');
  if (!sel) return;
  sel.innerHTML = `<option value="">${esc(UX.scopeReading)}</option>`;
  if (note) note.textContent = '';
  try {
    const r = await arm('GET', '/providers/Microsoft.Management/managementGroups?api-version=2020-05-01');
    const mgs = r.value || [];
    if (!mgs.length) {
      sel.innerHTML = `<option value="">${esc(UX.scopeMgNone)}</option>`;
      if (note) note.textContent = UX.scopeMgNoneWhy;
      return;
    }
    sel.innerHTML = mgs.map(m =>
      `<option value="${esc(m.name)}">${esc(m.properties?.displayName || m.name)}</option>`).join('');
  } catch (e) {
    sel.innerHTML = `<option value="">${esc(UX.scopeMgDenied)}</option>`;
    if (note) note.textContent = UX.scopeMgDeniedWhy;
  }
}

// Which of the three pickers the chosen level needs.
function scopeLevel() {
  return document.querySelector('input[name="scope-level"]:checked')?.value ?? 'rg';
}
function renderScopeLevel() {
  const level = scopeLevel();
  $('#scope-sub-row').style.display = (level === 'mg') ? 'none' : '';
  $('#scope-rg-row').style.display  = (level === 'rg') ? '' : 'none';
  $('#scope-mg-row').style.display  = (level === 'mg') ? '' : 'none';
  if (level === 'mg') loadManagementGroups();
  if (level === 'rg') loadResourceGroups();
}

/* Taking access away.
 *
 * This page could only ever GIVE access, which made it half a control: the way
 * to remove it was the Azure portal, and a page that can only add is a page
 * whose picture of "where the product may work" drifts from the truth.
 *
 * Done AS THE SIGNED-IN PERSON, with their own token, exactly like the grant -
 * the app deliberately holds no rights to change access.
 */
function revokeScope(assignmentId, btn, serviceAssignmentId, shared, serviceOnly, losing) {
  if (!assignmentId) return;
  // POPUP-1: asked in the row, not in a browser box.
  // ACCESS-REMOVE-SHARED-1: the question says what the removal will keep.
  const desc = serviceOnly ? UX.scopeServiceRemoveDesc : shared ? UX.scopeRemoveDescShared : UX.scopeRemoveDesc;
  // ACCESS-PAIR-COVER-1: and every place below it that loses the web service
  // read access with it, by name.
  const lost = (losing || []).filter(Boolean);
  VmfHelp.confirmInPlace(btn, { ask: UX.scopeRemoveConfirm,
    desc: lost.length ? `${desc}\n\n${UX.scopeRemoveLosesRead}` : desc,
    ...(lost.length ? { lines: lost } : {}),
    yes: UX.scopeRemoveYes, cancel: UX.cancel, under: 'tr' },
    () => revokeScopeNow(assignmentId, btn, serviceAssignmentId, serviceOnly));
}

/* ACCESS-REMOVE-SHARED-1: the place a role assignment is at, from its id.
 * Azure writes an assignment's id as its scope followed by this provider. */
function scopeOfAssignment(assignmentId) {
  return String(assignmentId || '').split(/\/providers\/Microsoft\.Authorization\/roleAssignments\//i)[0];
}

/* ACCESS-REMOVE-SHARED-1: does another engine grant still use the web
 * service assignment that `removing` is paired with?
 *
 * The web service holds ONE assignment for each place (ACCESS-HALF-1), and
 * the page pairs an engine row with the one AT ITS OWN SCOPE (loadScopes, by
 * scopeNormalize). Azure refuses a second identical assignment, so a second
 * engine grant on the same place - Assess, then Assess and migrate - shares
 * the first one's. Removing it with either grant took it from the other.
 *
 * `engineRows` is every engine grant ({ id, scope, serviceId }) Azure listed,
 * or null when that list could not be read: cannot tell, never yes or no.
 * `pending` is this page's own records (SCOPE-LAG-1): a grant Azure does not
 * list yet still counts, and one this page removed does not, even while
 * Azure still lists it. */
function scopeServiceInUse(removing, engineRows, pending) {
  if (!Array.isArray(engineRows)) { return null; }
  const place = scopeNormalize(removing.scope);
  const records = (pending || []).filter(p => p && (p.action === 'added' || p.action === 'removed'));
  const removed = new Set();
  for (const p of records) { if (p.action === 'removed') { scopeLagIds(p).forEach(x => removed.add(x)); } }
  const relies = (x) => !!x && !!x.id && x.id !== removing.id && !removed.has(x.id) &&
    ((!!removing.serviceId && x.serviceId === removing.serviceId) || scopeNormalize(x.scope) === place);
  if (engineRows.some(relies)) { return true; }
  return records.some(p => {
    if (p.action !== 'added') { return false; }
    // An add removed again names its engine assignment in the removal, so
    // `relies` already leaves it out.
    const ids = scopeLagIds(p);
    return relies({ id: ids[0], scope: p.row?.scope, serviceId: ids[1] || null });
  });
}

/* ACCESS-REMOVE-SHARED-1: which web service assignment this removal may take
 * away, asked of Azure AT THE MOMENT OF THE REMOVAL rather than read off a
 * table that may be minutes old.
 *
 * Returns { remove } with the id to delete (or null when there is none), or
 * { kept: 'shared' } when another grant uses it, or { kept: 'unread' } when a
 * list could not be read. The ruling stands both ways: a removal
 * removes what belongs only to that grant, and never what another grant
 * still uses. As the signed-in user, like every call on this page. */
async function scopeServiceStep(assignmentId, serviceAssignmentId) {
  if (!serviceAssignmentId && !cfg.webServicePrincipalId) { return { remove: null }; }
  const scope = scopeOfAssignment(assignmentId);
  const place = scopeNormalize(scope);
  const guids = [vmfRoleId('assess'), vmfRoleId('migrate')].map(x => x.split('/').pop()).filter(Boolean);
  const ours = (a) => guids.some(g => (a?.properties?.roleDefinitionId || '').endsWith(g));
  const listAt = async (principalId) => {
    const r = await arm('GET', `${scope}/providers/Microsoft.Authorization/roleAssignments` +
      `?api-version=2022-04-01&$filter=principalId+eq+'${principalId}'`, null, true);
    return (r.value || []).filter(ours);
  };
  let serviceId = serviceAssignmentId || null;
  if (!serviceId) {
    // A row drawn from a record whose web service PUT got 409 carries no id,
    // and the assignment it relies on is the one at this place.
    try {
      const found = (await listAt(cfg.webServicePrincipalId)).find(a => scopeNormalize(a.properties.scope) === place);
      if (!found) { return { remove: null }; }
      serviceId = found.id;
    } catch (e) { return { kept: 'unread' }; }
  }
  let engineRows = null;
  try {
    if (cfg.enginePrincipalId) {
      engineRows = (await listAt(cfg.enginePrincipalId)).map(a => ({ id: a.id, scope: a.properties.scope, serviceId: null }));
    }
  } catch (e) { engineRows = null; }
  const inUse = scopeServiceInUse({ id: assignmentId, scope, serviceId }, engineRows, scopeLagRead());
  if (inUse === null) { return { kept: 'unread' }; }
  if (inUse) { return { kept: 'shared' }; }
  return { remove: serviceId };
}

/* ACCESS-SERVICE-ORPHAN-1: `serviceOnly` - the row IS a web service
 * assignment with no engine grant at its place. There is no engine half to
 * delete, and the same question decides the web service half: Azure is asked
 * at the moment of the removal whether an engine grant on the place now uses
 * it, and cannot tell keeps it. */
async function revokeScopeNow(assignmentId, btn, serviceAssignmentId, serviceOnly) {
  btn.disabled = true;
  btn.textContent = UX.scopeRemoving;
  try {
    // Already gone is the outcome the person asked for - and the web service
    // half is still decided below, so an engine assignment removed somewhere
    // else does not leave the other half behind.
    if (!serviceOnly) {
      try { await arm('DELETE', `${assignmentId}?api-version=2022-04-01`, null, true); }
      catch (e) { if (e.status !== 404 && e.status !== 204) { throw e; } }
    }
    // ACCESS-HALF-1: A REMOVAL MUST REMOVE. The product reaches a place
    // through two identities, so taking one away and leaving the other is
    // access nobody can see on the page that is meant to show it.
    // ACCESS-REMOVE-SHARED-1: but only what belongs to THIS grant. The web
    // service assignment goes only when no other grant uses it.
    const step = await scopeServiceStep(assignmentId, serviceOnly ? assignmentId : serviceAssignmentId);
    if (step.remove) {
      try { await arm('DELETE', `${step.remove}?api-version=2022-04-01`, null, true); }
      catch (e) { if (e.status !== 404 && e.status !== 204) { throw e; } }
    }
    // SCOPE-LAG-1: Azure lists a deleted assignment for a minute or two after
    // it is gone. The record names only what went: a kept web service
    // assignment named here would hide the grant that still uses it.
    scopeLagNote('removed', serviceOnly ? [step.remove] : [assignmentId, step.remove]);
    if (serviceOnly) {
      if (step.kept === 'shared') { flash('#ok', UX.scopeServiceKeptEngine); }
      else if (step.kept === 'unread') { flash('#err', UX.scopeServiceKeptUnread); }
      else { flash('#ok', UX.scopeServiceRemoved); }
    }
    else if (step.kept === 'shared') { flash('#ok', UX.scopeRemovedShared); }
    else if (step.kept === 'unread') { flash('#err', UX.scopeRemovedServiceUnread); }
    else { flash('#ok', UX.scopeRemoved); }
    await loadScopes(true);
  }
  catch (e) {
    if (e.status === 403) { flash('#ok', UX.scopeNoPerm); }
    else { fail(e); }
    btn.disabled = false;
    btn.textContent = UX.scopeRemove;
  }
}

/* STORE-READ-1 removed the whole of STORE-ACCESS-1 from this page.
 *
 * What was here: a grant of the built-in Storage Blob Data Reader role on the
 * run store's storage account, made as the signed-in administrator alongside
 * the app role, a matching removal, a listing to fill a "Can read the records"
 * column, and a repair button for people granted before it existed.
 *
 * It was correct and it is gone, because the second permission it managed is
 * gone. The dashboard no longer reads blob storage - the service reads, with
 * its own identity - so a role in the product is the whole of what a person
 * needs, and this page grants all of it again.
 *
 * The engine's SCOPE grants below are a different thing and stay: those are
 * what let the engine act on somebody's machines, and Azure is still the only
 * place that can say yes to them.
 */
async function grantScope() {
  const btn = $('#scope-btn');
  const mode = document.querySelector('input[name="scope-mode"]:checked')?.value ?? 'assess';
  const level = scopeLevel();
  const subId = $('#scope-pick').value;
  // PERM-2: the scope is as small as the person chose. A resource group is the
  // least privilege that can still do the work, so it is the default here.
  const scope = level === 'mg'
      ? ($('#scope-mg').value ? `/providers/Microsoft.Management/managementGroups/${$('#scope-mg').value}` : '')
    : level === 'rg'
      ? ((subId && $('#scope-rg').value) ? `/subscriptions/${subId}/resourceGroups/${$('#scope-rg').value}` : '')
      : (subId ? `/subscriptions/${subId}` : '');
  if (!scope) return;
  btn.disabled = true; btn.textContent = UX.scopeBusy;
  let def = null;
  let widen = null;
  try {
    // Migration includes assessment by design, so one assignment covers both.
    def = await vmfRoleDefinition(mode);
    if (!def) { flash('#err', UX.scopeRoleMissing); return; }

    /* ROLES-1: cover, then assign.
     *
     * A role can only be granted where its own list reaches. When it already
     * does - the ordinary case, and always the case for an install anchored at
     * a management group - nothing about the role changes and this stays the
     * single action it has always been.
     */
    if (!(await scopeIsCovered(scope, def))) {
      const widened = widenScopes(def.properties?.assignableScopes, scope);
      if (widened.error) { flash('#err', widened.error); return; }
      widen = widened.scopes;
    }
  }
  catch (e) { fail(e); return; }
  finally { btn.disabled = false; btn.textContent = UX.scopeBtn; }

  if (!widen) { await grantScopeNow(scope, def, null, btn, level, mode); return; }

  /* The role itself is about to change, so say so first.
   *
   * POPUP-1: asked on the button, not in a browser box. Two reasons this is
   * worth asking rather than doing: widening changes where these roles may be
   * used everywhere, not only here; and a customer whose pipeline owns the
   * definitions must put it THERE instead, or the next run of that pipeline
   * removes it and the grant stops working with nothing naming the cause.
   */
  // A NAME A PERSON RECOGNISES, not the resource id. The id runs to ninety
  // characters, and the reader chose this place from two dropdowns a moment
  // ago - they know it as "rg-vmf-ci", so that is what the question calls it.
  const where = placeName(scope);
  VmfHelp.confirmInPlace(btn, {
    ask: UX.scopeWidenAsk.replace('{where}', where),
    // In the order a reader needs it: what the roles ARE, what adding a place
    // does and does not do, the one thing that can undo it, and only then the
    // list - under a heading that says what the list IS. It used to be two
    // raw ids with no heading at all.
    desc: [
      UX.scopeWidenPipeline,
      UX.scopeWidenScopeList,
      widen.map(placeName).join(', '),
    ].join('\n'),
    yes: UX.scopeWidenBtn,
    cancel: UX.cancel,
    // ROLE-REMOVE-CONFIRM-1: after the button's own line, in the card, not over it.
    under: 'div',
  }, () => grantScopeNow(scope, def, widen, btn, level, mode));
}

/* ACCESS-HALF-1: who a grant is actually for.
 *
 * THE PRODUCT HAS TWO IDENTITIES THAT NEED REACH OVER A CUSTOMER'S MACHINES.
 * The engine stops and resizes them. The web service READS them -
 * and every list in this product, including the ones on this page, comes from
 * the web service. This page granted the engine and nothing else, so a scope
 * added here left every list blank and the page said the product could reach
 * the subscription.
 *
 * `tools/Grant-VmfAccess.ps1` has always granted both. This is the app doing
 * what the installer does, which is what hard rule 12 asks of it.
 *
 * THE WEB SERVICE NEVER TAKES A MIGRATION ROLE. It reads; it does not change a
 * machine. The installer draws that line and so does this.
 *
 * A config deployed before this change does not name the web service. The plan
 * then carries ONE assignment and says `incomplete`, because granting half in
 * silence is the defect itself. */
function grantPlan(level, ids) {
  const plan = [{
    who: 'engine',
    principalId: ids.enginePrincipalId,
    roleDefinitionId: level === 'migrate' ? ids.migrateRoleId : ids.assessRoleId,
  }];
  if (ids.webServicePrincipalId) {
    plan.push({
      who: 'service',
      principalId: ids.webServicePrincipalId,
      roleDefinitionId: ids.assessRoleId,
    });
  } else {
    plan.incomplete = true;
  }
  return plan;
}

/* ACCESS-HALF-1: what it takes to REPAIR a half-granted place.
 *
 * Found by using the page this item had just fixed. It correctly
 * said "the engine only - the web service cannot read this place" and offered
 * one button: Remove. So the only way out of a half grant was to destroy the
 * half that works and add it again, or to leave the app.
 *
 * CLAUDE.md rule 11 - a control that can only be committed to is a trap - and
 * rule 12, every operator action is reachable from the app. Diagnosing
 * something the page will not let you act on is neither.
 *
 * Only the MISSING half, and never the engine, which already holds what it
 * needs. An empty plan means there is nothing this page can offer: without the
 * web service's identity in the config there is no repair to make, and a
 * button that cannot work is worse than no button. */
function repairPlan(scope, ids) {
  if (!ids.webServicePrincipalId) { return []; }
  return [{
    who: 'service',
    principalId: ids.webServicePrincipalId,
    roleDefinitionId: ids.assessRoleId,
    scope,
  }];
}

/* ACCESS-HALF-1: does the PRODUCT reach this scope?
 *
 * Not "does the engine". A scope the engine holds and the web service does not
 * is a scope where migrations would run and nobody could see a machine to
 * start one on.
 *
 * `null` means a listing could not be read for that half. That is CANNOT TELL
 * and never "covered" - the IMAGE-1 rule, which this repository has now had to
 * write down in four places. */
function productReach(engineHas, serviceHas) {
  if (engineHas === null || serviceHas === null) { return 'unknown'; }
  if (engineHas && serviceHas) { return 'full'; }
  if (engineHas) { return 'engine-only'; }
  if (serviceHas) { return 'service-only'; }
  return 'none';
}

/* ACCESS-HALF-1: give the web service the half it is missing, here.
 *
 * No confirmation: this ADDS read access to a place the product already works
 * in, which is the thing the person is being told is missing. The question in
 * front of Remove is there because Remove destroys something.
 *
 * As the signed-in person, with their own token, like every other change on
 * this page - the app holds no rights to change access at all. */
async function repairHalfScope(scope, btn) {
  const was = btn.textContent;
  btn.disabled = true;
  btn.textContent = UX.scopeHalfFixing;
  try {
    const plan = repairPlan(scope, {
      webServicePrincipalId: cfg.webServicePrincipalId,
      assessRoleId: vmfRoleId('assess'),
    });
    for (const part of plan) {
      try {
        await arm('PUT', `${part.scope}/providers/Microsoft.Authorization/roleAssignments/${crypto.randomUUID()}` +
          '?api-version=2022-04-01', {
            properties: {
              roleDefinitionId: part.roleDefinitionId,
              principalId: part.principalId,
              principalType: 'ServicePrincipal',
            },
          }, true);
      }
      catch (e) { if (e.status !== 409) { throw e; } }   // already there is the outcome asked for
    }
    flash('#ok', UX.scopeHalfFixed);
    await loadScopes(true);
  }
  catch (e) {
    if (e.status === 403) { flash('#ok', UX.scopeNoPerm); }
    else { fail(e); }
    btn.disabled = false;
    btn.textContent = was;
  }
}

/* ACCESS-LAG-WORDS-1: `level` is where (a resource group, a subscription or
 * a management group); `mode` is what (Assess, or Assess and migrate). The
 * pending row was built from `level`, so it said "Assess" for every grant. */
async function grantScopeNow(scope, def, widen, btn, level, mode) {
  btn.disabled = true; btn.textContent = UX.scopeBusy;
  try {
    if (widen) {
      try {
        await arm('PUT', `${def.id}?api-version=2022-04-01`, {
          properties: {
            roleName: def.properties.roleName,
            description: def.properties.description,
            type: 'CustomRole',
            assignableScopes: widen,
            permissions: def.properties.permissions,
          },
        });
      }
      catch (e) {
        // Azure needs roleDefinitions/write on EVERY place the roles already
        // reach, not only the new one. Reported as a failed grant - which is
        // what happened before - that is impossible to act on.
        if (e.status === 403) { flash('#err', UX.scopeWidenDenied.replace('{scopes}', widen.join(', '))); return; }
        throw e;
      }
    }

    // ACCESS-HALF-1: BOTH halves of the product, the way the installer does
    // it. The engine takes the level asked for; the web service takes reading
    // either way, because it reads and never changes a machine.
    //
    // The engine goes FIRST and its result is the one reported, so this reads
    // the same as it always did when both succeed. A web service grant that
    // fails is said out loud rather than swallowed: half a grant is the defect
    // this whole item is.
    const plan = grantPlan(mode, {
      enginePrincipalId: cfg.enginePrincipalId,
      webServicePrincipalId: cfg.webServicePrincipalId,
      assessRoleId: vmfRoleId('assess'),
      migrateRoleId: vmfRoleId('migrate'),
    });
    // SCOPE-LAG-1: the 201 carries the assignment Azure just created. That is
    // the authoritative answer, and it used to be thrown away in favour of a
    // list that would not mention the grant for another minute or two.
    let created = null;
    let serviceMade = null;
    let halfOnly = plan.incomplete === true;
    for (const part of plan) {
      const roleId = part.who === 'engine' ? def.id : part.roleDefinitionId;
      try {
        const madeOne = await arm('PUT',
          `${scope}/providers/Microsoft.Authorization/roleAssignments/${crypto.randomUUID()}` +
          '?api-version=2022-04-01', {
            properties: {
              roleDefinitionId: roleId,
              principalId: part.principalId,
              principalType: 'ServicePrincipal',
            },
          }, true);
        if (part.who === 'engine') { created = madeOne; } else { serviceMade = madeOne; }
      }
      catch (e) {
        // Already there is the outcome asked for; anything else on the engine
        // is the grant failing and must throw. On the web service it is half
        // a grant, which the page has to say rather than draw as covered.
        if (e.status === 409) { continue; }
        if (part.who === 'engine') { throw e; }
        halfOnly = true;
      }
    }
    if (halfOnly) { flash('#err', UX.scopeHalfGranted); }
    const madeSub = subs.find(s => s.subscriptionId === $('#scope-pick').value);
    if (created && created.id && madeSub) {
      // ACCESS-LAG-WORDS-1: ONE record for the grant, naming every assignment
      // it made, so the row shows all of it until Azure lists all of it.
      scopeLagNote('added', [created.id, serviceMade?.id], {
        ...describeScope(created.properties?.scope || scope, madeSub),
        what: mode === 'migrate' ? UX.scopeChange : UX.scopeLook,
        stale: false,
        // SCOPE-COVER-1 reads these two, so a grant already covered says so
        // on the same load that shows it, rather than two minutes later.
        mode: mode === 'migrate' ? 'migrate' : 'assess',
        scope: created.properties?.scope || scope,
        // ACCESS-HALF-1: what the page knows of the web service half.
        reach: !cfg.webServicePrincipalId ? 'unknown' : (halfOnly ? 'engine-only' : 'full'),
      });
    }
    flash('#ok', widen ? UX.scopeWidened : UX.scopeAdded);
    await loadScopes(true);
  }
  catch (e) {
    // 403 is the RIGHT answer for an administrator who cannot grant here, and
    // it must read as an answer rather than a crash.
    if (e.status === 403) { flash('#ok', level === 'mg' ? UX.scopeMgDeniedWhy : UX.scopeNoPerm); }
    else if (e.status === 409) { flash('#ok', UX.scopeAdded); await loadScopes(true); }
    else { fail(e); }
  }
  finally { btn.disabled = false; btn.textContent = UX.scopeBtn; }
}

// LEAK-2: module scope, because the Escape handler that calls it is wired once
// for the page while the table it acts on is rebuilt by every loadAssignments.
// The tbody NODE survives those rebuilds - only its contents are replaced - but
// this queries it each time rather than closing over one render's copy.
function closeRoleMenus() {
  const tb = $('#who-table tbody');
  if (!tb) { return; }
  tb.querySelectorAll('.rolemenu').forEach(m => { m.hidden = true; });
  tb.querySelectorAll('[data-addfor]').forEach(t => { t.textContent = '+ ' + t.dataset.open; });
}

async function loadAssignments() {
  const rows = [];
  let page = await graph('GET', `servicePrincipals/${spId}/appRoleAssignedTo?$top=999`);
  while (page) {
    rows.push(...page.value);
    page = page['@odata.nextLink'] ? await graph('GET', page['@odata.nextLink'].split('/v1.0/')[1]) : null;
  }
  const byPrincipal = new Map();
  for (const a of rows) {
    if (!byPrincipal.has(a.principalId)) byPrincipal.set(a.principalId, { id: a.principalId, name: a.principalDisplayName, type: a.principalType, roles: [] });
    byPrincipal.get(a.principalId).roles.push(a);
  }

  // WHICH one? A directory can hold two accounts with the same display name -
  // a person and a second identity kept to test the role gate is the usual
  // pair - and the table showed both with no way to tell them apart. A row you
  // cannot identify is a row you cannot safely change.
  //
  // appRoleAssignedTo does not carry the sign-in name, so it is read here in
  // ONE call rather than one per row. A failure costs the sign-in names, not
  // the page.
  try {
    const ids = [...byPrincipal.keys()];
    if (ids.length) {
      const looked = await graph('POST', 'directoryObjects/getByIds',
        { ids, types: ['user', 'group'] });
      for (const o of (looked?.value ?? [])) {
        const p = byPrincipal.get(o.id);
        if (p) p.signIn = o.userPrincipalName || o.mail || '';
      }
    }
  } catch (e) { /* names still render */ }
  const tb = $('#who-table tbody');
  tb.innerHTML = byPrincipal.size ? '' : `<tr><td colspan="3" class="muted">${esc(UX.nobody)}</td></tr>`;
  for (const [, p] of [...byPrincipal.entries()].sort((a, b) => String(a[1].name).localeCompare(String(b[1].name)))) {
    // ROLE-3: which of the roles this person holds are covered by ANOTHER
    // role they hold. Those are real assignments that grant nothing extra.
    const heldVals = p.roles.map(a => (appRoles.find(r => r.id === a.appRoleId) || {}).value).filter(Boolean);
    const coveredBy = {};
    for (const v of heldVals) {
      for (const c of (UX.roleCovers[v] || [])) {
        if (heldVals.includes(c)) { coveredBy[c] = (UX.roleWords[v] ?? [v])[0]; }
      }
    }
    // ROLE-REMOVE-CONFIRM-1: a question names the user as the row does - the
    // display name, and the sign-in name kept apart from it, never run together.
    const who = p.signIn ? `${p.name} (${p.signIn})` : p.name;
    const rolePills = p.roles.map(a => {
      const roleName = appRoles.find(r => r.id === a.appRoleId)?.value ?? a.appRoleId;
      const [word] = UX.roleWords[roleName] ?? [roleName];
      const covered = coveredBy[roleName];
      // A covered role is drawn quiet and says what covers it. Still removable,
      // still real - just visibly not the thing doing the work.
      const cls = covered ? 'pill quiet' : 'pill';
      const tip = covered ? UX.roleCoveredBy.replace('{role}', covered)
                          : (UX.roleWords[roleName]?.[1] ?? '');
      return `<span class="${cls}" title="${esc(tip)}">${esc(word)}<button type="button" data-del="${esc(a.id)}" data-role="${esc(word)}" data-who="${esc(who)}" title="${esc(UX.removeTip)}">&times;</button></span>`;
    }).join(' ');
    // ADDING a role to somebody already here. There was no way to edit the
    // roles somebody holds. You could take one away - each pill
    // has its own remove - but the only way to add was to search the directory
    // for a person who is already on the screen.
    const held = new Set(p.roles.map(a => a.appRoleId));
    // ROLE-2: a role that adds NOTHING is not offered. Somebody holding
    // Administrator is offered no roles at all, and somebody holding Operator
    // is not offered Viewer - it is already inside what they have.
    const idOf = (v) => (appRoles.find(r => r.value === v) || {}).id;
    const coveredIds = new Set();
    for (const a of p.roles) {
      const heldVal = (appRoles.find(r => r.id === a.appRoleId) || {}).value;
      for (const c of (UX.roleCovers[heldVal] || [])) { const i = idOf(c); if (i) { coveredIds.add(i); } }
    }
    const missing = appRoles.filter(r => !held.has(r.id) && !coveredIds.has(r.id));
    // Adding a role had no way to cancel. An action must always offer a way
    // to abandon it - that is ordinary navigation (rule 11).
    //
    // Right, and it is a pattern rather than one control: opening something
    // that offers no way back is a trap wherever it appears. So the trigger is
    // ONE button with two states - it says "+ Add a role", and while the
    // choices are showing it says "Cancel". Escape closes it too, because that
    // is what a person tries first.
    const addControl = missing.length
      // ROLE-2: the cancel button looked like one of the role options.
      // The trigger flips to "Cancel" and sits in a row of
      // identical ghost buttons that ARE roles, so the one control that is not
      // a choice looked like the first choice. It keeps its own class now and
      // the roles are the only things that look like roles.
      ? `<span class="addrole"><button type="button" class="btn ghost addcancel" data-addfor="${esc(p.id)}"
           data-open="${esc(UX.addRole)}" data-close="${esc(UX.addRoleCancel)}"
           title="${esc(UX.addRoleTip)}">+ ${esc(UX.addRole)}</button>
           <span class="rolemenu" hidden>${missing.map(r => {
             const [word, why] = UX.roleWords[r.value] ?? [r.value, ''];
             return `<button type="button" class="btn ghost" data-grant="${esc(r.id)}"
                       data-to="${esc(p.id)}"
                       title="${esc(why)}">${esc(word)}</button>`;
           }).join(' ')}</span></span>`
      // "They already hold every role" is a wasted statement when
      // administrator alone does everything: it stated a fact about the LIST
      // rather than
      // about the person. Now it says the useful thing, and only when there
      // is a useful thing to say.
      : (held.has(idOf('Vmf.Admin'))
          ? `<div class="muted" style="margin-top:6px">${esc(UX.roleAllCovered)}</div>`
          : '');

    // The tidy. Offered only when there IS something to tidy, and it names
    // what it will remove before doing it - three permission removals in one
    // press is not something to do on a shrug.
    const deadRoles = p.roles.filter(a => coveredBy[(appRoles.find(r => r.id === a.appRoleId) || {}).value]);
    const tidyControl = deadRoles.length
      ? `<button type="button" class="btn ghost lever-act" data-tidy="${esc(p.id)}"
           data-ids="${esc(deadRoles.map(a => a.id).join(','))}" data-who="${esc(who)}"
           >${esc(UX.roleTidy.replace('{n}', String(deadRoles.length)))}</button>`
      : '';

    tb.insertAdjacentHTML('beforeend', `<tr>
      <td>${esc(p.name)}${p.signIn ? `<div class="muted mono">${esc(p.signIn)}</div>` : ''}</td>
      <td><span class="pill quiet">${esc(p.type === 'Group' ? UX.typeGroup : UX.typeUser)}</span></td>
      <td>${rolePills} ${addControl} ${tidyControl}</td></tr>`);
  }

  tb.querySelectorAll('[data-addfor]').forEach(b => b.addEventListener('click', () => {
    const menu = b.parentElement.querySelector('.rolemenu');
    const wasHidden = menu.hidden;
    closeRoleMenus();                       // one open at a time
    if (wasHidden) { menu.hidden = false; b.textContent = b.dataset.close; }
  }));
  // LEAK-2: the Escape key is wired ONCE, in start(). It used to be wired
  // here, and loadAssignments runs again after every grant, tidy, removal and
  // search - so the handler count on `document` grew for the life of the tab,
  // and each accumulated copy swept the whole table on every keypress.
  tb.querySelectorAll('[data-grant]').forEach(b => b.addEventListener('click', async () => {
    b.disabled = true;
    try {
      await graph('POST', `servicePrincipals/${spId}/appRoleAssignedTo`,
        { principalId: b.dataset.to, resourceId: spId, appRoleId: b.dataset.grant }, true);
      flash('#ok', UX.roleAdded);
      loadAssignments();
    } catch (e) { failAction(e); b.disabled = false; }
  }));
  tb.querySelectorAll('[data-tidy]').forEach(b => b.addEventListener('click', () => askTidyRoles(b)));
  tb.querySelectorAll('[data-del]').forEach(b => b.addEventListener('click', () => askRemoveRole(b)));
}

/* ROLE-REMOVE-CONFIRM-1: "Remove n already covered" asks on a line of its own
 * under the user's row, like the x on a chip. It named the user from the
 * cell's text, which runs the display name and the sign-in name together; it
 * reads who from the button now. The removals are the ones it always made. */
function askTidyRoles(b) {
  const row = b.closest('tr');
  const who = b.dataset.who || '';
  const dead = b.dataset.ids.split(',').filter(Boolean);
  const names = [...row.querySelectorAll('.pill.quiet')].map(x => x.textContent.replace(/\u00d7|\u2715|x$/, '').trim());
  const by = row.querySelector('.pill:not(.quiet)')?.textContent.replace(/\u00d7|\u2715|x$/, '').trim() ?? '';
  // POPUP-1: asked in the row, not in a browser box.
  VmfHelp.confirmInPlace(b, { ask: UX.roleTidyAsk.replace('{who}', () => who).replace('{list}', () => names.join(', ')).replace('{by}', () => by),
                              yes: UX.roleTidyYes, cancel: UX.cancel, under: 'tr' }, async () => {
    b.disabled = true;
    try {
      for (const id of dead) { await graph('DELETE', `servicePrincipals/${spId}/appRoleAssignedTo/${id}`, null, true); }
      flash('#ok', UX.roleTidyDone);
      loadAssignments();
    } catch (e) { failAction(e); b.disabled = false; }
  });
}

/* ROLE-REMOVE-CONFIRM-1: the x on a role chip asks in a row of its own, under
 * the user's row, across the whole table - never inside the chip, which is one
 * word wide, and never over the next user's row. The question names the role
 * and the user by the words the row already shows. The removal itself is the
 * one the page always made (POPUP-1: asked in the page, not in a browser box). */
function askRemoveRole(b) {
  const ask = UX.removeAsk.replace('{role}', () => b.dataset.role || '')
                          .replace('{who}', () => b.dataset.who || '');
  VmfHelp.confirmInPlace(b, { ask, desc: UX.removeAskDesc, yes: UX.removeYes, cancel: UX.cancel,
                              under: 'tr' }, async () => {
    b.disabled = true;
    try {
      await graph('DELETE', `servicePrincipals/${spId}/appRoleAssignedTo/${b.dataset.del}`, null, true);
      flash('#ok', UX.removed);
      loadAssignments();
    } catch (e) { failAction(e); b.disabled = false; }
  });
}

let searchTimer = null;
async function runSearch(q) {
  const box = $('#results');
  if (q.length < 2) { box.innerHTML = ''; return; }
  const f = q.replace(/'/g, "''");
  try {
    const [users, groups] = await Promise.all([
      graph('GET', `users?$filter=startswith(displayName,'${encodeURIComponent(f)}') or startswith(userPrincipalName,'${encodeURIComponent(f)}')&$select=id,displayName,userPrincipalName&$top=6`),
      graph('GET', `groups?$filter=startswith(displayName,'${encodeURIComponent(f)}')&$select=id,displayName&$top=6`),
    ]);
    const opts = [
      ...users.value.map(u => ({ id: u.id, name: u.displayName, sub: u.userPrincipalName, type: 'User' })),
      ...groups.value.map(g => ({ id: g.id, name: g.displayName, sub: UX.typeGroup, type: 'Group' })),
    ];
    box.innerHTML = opts.length ? opts.map((o, i) =>
      `<button type="button" class="result" data-i="${i}"><span class="pill quiet">${esc(o.type === 'Group' ? UX.typeGroup : UX.typeUser)}</span> <b>${esc(o.name)}</b> <span class="muted">${esc(o.sub)}</span></button>`).join('')
      : `<p class="muted">${esc(UX.noMatch)}</p>`;
    box.querySelectorAll('.result').forEach(b => b.addEventListener('click', () => {
      picked = opts[Number(b.dataset.i)];
      box.querySelectorAll('.result').forEach(x => x.classList.remove('sel'));
      b.classList.add('sel');
      $('#rolepick').style.display = 'flex';
      $('#add-actions').style.display = 'block';
    }));
  } catch (e) { fail(e); }
}

function renderRolePick() {
  $('#rolepick').innerHTML = appRoles
    .filter(r => r.isEnabled)
    .sort((a, b) => Object.keys(UX.roleWords).indexOf(a.value) - Object.keys(UX.roleWords).indexOf(b.value))
    .map((r, i) => {
      const [word, why] = UX.roleWords[r.value] ?? [r.value, ''];
      return `<label><input type="radio" name="role" value="${esc(r.id)}"${i === 0 ? ' checked' : ''}><span><b>${esc(word)}</b><span class="muted">${esc(why)}</span></span></label>`;
    }).join('');
}

async function start() {
  // ROLE-GATE-1: nobody without a role in this app goes any further.
  // Somebody with NO role could sign in and see things.
  // Signing in needs no role, and this page never asked - so
  // what somebody saw depended only on Azure RBAC, a different system.
  if (!DEMO_MODE && !(await VmfHelp.gateOnRole(cfg, getToken, msalApp))) { return; }
  VmfHelp.identity(account, DEMO_MODE ? DEMO.signedInAs : null);
  // The page is only useful to administrators; the directory is the real gate.
  let roles = [];
  if (DEMO_MODE) { roles = ['Vmf.Admin']; }
  else {
    const apiTok = await getToken([`api://${cfg.apiAppId}/access_as_user`], true);
    try { roles = JSON.parse(atob(apiTok.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))).roles ?? []; } catch { }
  }
  if (!roles.includes('Vmf.Admin')) {
    $('#gate-title').textContent = UX.notAdmin;
    $('#gate-copy').textContent = UX.notAdminCopy;
    $('#gate-view').style.display = 'block';
    return;
  }
  $('#who-title').textContent = UX.whoTitle; $('#who-hint').innerHTML = UX.whoHint;
  $('#th-who').textContent = UX.colWho; $('#th-type').textContent = UX.colType; $('#th-roles').textContent = UX.colRoles;
  $('#add-title').textContent = UX.addTitle; $('#add-hint').textContent = UX.addHint;
  $('#search').placeholder = $('#search').placeholder || '';
  $('#search').setAttribute('placeholder', UX.searchHint);
  $('#add-btn').textContent = UX.addBtn;
  // SCOPE-ADD-1
  $('#scope-title').textContent = UX.scopeTitle;
  $('#scope-hint').textContent = UX.scopeHint;
  $('#scope-btn').textContent = UX.scopeBtn;
  $('#scope-mode').innerHTML =
    `<label style="display:block;font-size:13px;margin-bottom:6px">${esc(UX.scopeModeLabel)}</label>` +
    [['assess', UX.scopeAssess], ['migrate', UX.scopeMigrate]].map(([v, t], i) =>
      `<label style="display:block;margin:4px 0"><input type="radio" name="scope-mode" value="${v}"${i === 0 ? ' checked' : ''}> ${esc(t)}</label>`).join('');
  // PERM-2: resource group FIRST and selected, because the smallest scope that
  // does the job is the one to reach for. A subscription used to be the only
  // choice, so wanting the product in one resource group meant granting it the
  // whole subscription.
  $('#scope-level').innerHTML =
    `<label style="display:block;font-size:13px;margin-bottom:6px">${esc(UX.scopeLevelLabel)}</label>` +
    [['rg', UX.scopeLevelRg], ['sub', UX.scopeLevelSub], ['mg', UX.scopeLevelMg]].map(([v, t], i) =>
      `<label style="display:block;margin:4px 0"><input type="radio" name="scope-level" value="${v}"${i === 0 ? ' checked' : ''}> ${esc(t)}</label>`).join('');
  // PREVIEW-ACCESS-WORDS-1: no line under the resource group choice says the
  // in-place upgrade (Preview) needs the subscription. Measured 2026-11-13: with
  // the roles on one resource group only, the web service and the engine read
  // the preview feature, and a Preview move completed.
  $('#scope-picklabel').textContent = UX.scopePickLabel;
  $('#scope-rglabel').textContent = UX.scopeRgLabel;
  $('#scope-mglabel').textContent = UX.scopeMgLabel;
  document.querySelectorAll('input[name="scope-level"]').forEach(el =>
    el.addEventListener('change', renderScopeLevel));
  // Changing the subscription changes which resource groups exist.
  $('#scope-pick').addEventListener('change', loadResourceGroups);
  renderScopeLevel();
  $('#scope-btn').addEventListener('click', grantScope);
  // Reading scopes needs a second token (Azure, not the directory), so a
  // failure here must not take the rest of the page down with it.
  loadScopes().catch(e => { $('#scope-list').textContent = e.message; });
  $('#search').addEventListener('input', (e) => {
    clearTimeout(searchTimer);
    searchTimer = setTimeout(() => runSearch(e.target.value.trim()), 350);
  });
  $('#add-btn').addEventListener('click', async () => {
    const roleId = document.querySelector('input[name="role"]:checked')?.value;
    if (!picked || !roleId) return;
    $('#add-btn').disabled = true;
    try {
      await graph('POST', `servicePrincipals/${spId}/appRoleAssignedTo`,
        { principalId: picked.id, resourceId: spId, appRoleId: roleId }, true);
      flash('#ok', UX.added);
      $('#search').value = ''; $('#results').innerHTML = '';
      $('#rolepick').style.display = 'none'; $('#add-actions').style.display = 'none';
      picked = null;
      loadAssignments();
    } catch (e) { failAction(e); }
    $('#add-btn').disabled = false;
  });
  // LEAK-2, and CLAUDE.md rule 11: the key a person tries first when something
  // opens and they change their mind. Wired ONCE here, with the page's other
  // permanent listeners - not inside loadAssignments, which runs again after
  // every grant, tidy, removal and search.
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { closeRoleMenus(); } });
  $('#app').style.display = 'block';
  // CONSENT-SPLIT-1: LAST, and allowed to fail. The Azure half above is already
  // on the screen by this point, so a directory the person may not read costs
  // them these two cards and nothing else.
  await loadDirectory();
}

/* CONSENT-SPLIT-1: the DIRECTORY half of this page - who can sign in, and what
 * role they hold. It reads and writes Microsoft Entra, and Entra keeps that for
 * a directory administrator. No user can approve it for themselves.
 *
 * IT USED TO BE THE FIRST THING THE PAGE DID, and it threw. So a person whose
 * directory refused got one word in a red bar and an empty page - including the
 * card below, which grants the product access to a SUBSCRIPTION and needs
 * nothing from the directory at all. Owning the subscription is enough for
 * that, and the half he was entitled to use was locked behind the half he was
 * not.
 *
 * The shape is the one `loadScopes` already uses for the Azure consent: a
 * refusal is not an error to display, it is a sentence and a button. */
async function loadDirectory(interactive = false) {
  const blocked = $('#dir-blocked');
  // LOADING-LINE-1: the table says what it reads, not nothing, until the
  // directory answers. loadAssignments writes the rows over it.
  $('#who-table tbody').innerHTML = VmfHelp.waitingRow(UX.whoReading, 3);
  try {
    const sp = await graph('GET', `servicePrincipals(appId='${cfg.apiAppId}')?$select=id,appRoles`, null, interactive);
    spId = sp.id; appRoles = sp.appRoles;
    blocked.style.display = 'none';
    $('#who-table').style.display = '';
    $('#add-card').style.display = '';
    renderRolePick();
    await loadAssignments();
    return true;
  }
  catch (e) {
    // The two cards that cannot work are taken off the screen rather than left
    // looking broken, and the sentence says the part that matters: the card
    // below still works.
    $('#who-table').style.display = 'none';
    $('#add-card').style.display = 'none';
    blocked.innerHTML = `<p style="margin:0 0 10px">${esc(UX.dirBlocked)}</p>` +
      `<p class="muted" style="margin:0 0 12px;max-width:60ch">${esc(UX.dirBlockedWhy)}</p>` +
      `<button type="button" class="btn" id="dir-connect">${esc(UX.dirConnectBtn)}</button>`;
    blocked.style.display = 'block';
    // The button is for an administrator who simply has not approved it yet.
    // It asks ONCE - VmfHelp's guard refuses a second attempt in a session, so
    // a directory that says no cannot bounce this page in a loop.
    // The button comes BACK on failure. Disabling it and leaving it disabled
    // made a control that dies silently - rule 11's trap.
    $('#dir-connect').addEventListener('click', () => {
      $('#dir-connect').disabled = true;
      loadDirectory(true)
        .catch(err => failAction(err))
        .finally(() => { const b = $('#dir-connect'); if (b) { b.disabled = false; } });
    });
    return false;
  }
}

async function boot() {
  // Guarded: a missing shared file must cost the help option, not the page.
  if (window.VmfHelp) VmfHelp.install({ getMsal: () => msalApp, getRunId: () => null });
  if (DEMO_MODE) { cfg = DEMO.cfg; $('#demo-tag').style.display = 'inline-block'; await start(); return; }
  if (typeof msal === 'undefined') throw new Error('msal-browser.min.js failed to load - redeploy the dashboard.');
  cfg = VmfHelp.checkedConfig(await (await fetch('dashboard.config.json')).json());
  if (!cfg.apiAppId) throw new Error(UX.noApi);
  msalApp = new msal.PublicClientApplication({
    auth: { clientId: cfg.clientId, authority: `https://login.microsoftonline.com/${cfg.tenantId}`,
            redirectUri: location.origin + location.pathname },
    cache: { cacheLocation: 'sessionStorage' },
  });
  await msalApp.initialize();
  /* POPUP-3: takes the account a sign-in redirect brought back, when this load
     IS the return from one. Throws if the directory refused, and remembers the
     attempt, so the page cannot ask again and loop. */
  const accounts = await VmfHelp.accountsAfterReturn(msalApp);
  if (accounts.length) { account = accounts[0]; await start(); }
  else {
    VmfHelp.showSignIn();
    $('#login-btn').addEventListener('click', async () => {
      try {
        /* POPUP-3: leaves for the directory. Nothing follows - the browser navigates away here.
           CONSENT-SPLIT-1: SIGNING IN ASKS FOR THIS PRODUCT'S OWN PERMISSION,
           not the directory's. It used to ask for the directory permissions
           here, so a person whose directory refuses them could not reach the
           page AT ALL - including the card that grants access in Azure, which
           needs none of them. The directory is asked for separately, by the
           part of the page that needs it. */
        await VmfHelp.signInRedirect(msalApp, [`api://${cfg.apiAppId}/access_as_user`]);

      } catch (e) { fail(e); }
    });
  }
}

boot().catch(fail);
