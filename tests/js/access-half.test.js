/* ACCESS-HALF-1, 2026-09-22. Found on a lab install when every list in the
 * app came back empty.
 *
 * THE PRODUCT HAS TWO IDENTITIES THAT NEED REACH OVER A CUSTOMER'S MACHINES.
 * The engine stops and resizes them. The web service READS them, and
 * everything the dashboard lists - subscriptions, resource groups, machines -
 * it asks the web service for.
 *
 * The Access page manages one of them:
 *
 *     const pid = cfg.enginePrincipalId;
 *
 * So a scope granted in the app gives the engine reach and the web service
 * nothing, every list in the product stays blank, and the page reports that
 * the product can reach a subscription when only half of it can.
 *
 * MEASURED: on that install the engine holds the subscription role, created
 * 19 Sept in a single act; the web service holds no VMF role at any scope; and
 * the activity log shows no role assignment changed there in fourteen days.
 * Nothing removed it - the page never granted it.
 *
 * `tools/Grant-VmfAccess.ps1` has always granted both, which is why an install
 * that answers yes to the first-scope question is fine. The install asks with
 * NO as the default.
 */
'use strict';
const { liftAll, test, eq, ok, run } = require('./_harness');

const { grantPlan, productReach, repairPlan } = liftAll('access.html', ['grantPlan', 'productReach', 'repairPlan']);

const IDS = {
  enginePrincipalId:     'engine-0000',
  webServicePrincipalId: 'service-0000',
  assessRoleId:          '/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/assess-role',
  migrateRoleId:         '/subscriptions/s/providers/Microsoft.Authorization/roleDefinitions/migrate-role',
};

test('an assess grant covers both halves of the product', () => {
  const plan = grantPlan('assess', IDS);
  eq(plan.length, 2, 'two assignments');
  eq(plan.map(p => p.principalId).sort(), ['engine-0000', 'service-0000']);
  for (const p of plan) { eq(p.roleDefinitionId, IDS.assessRoleId, p.who); }
});

test('a migrate grant gives the engine migration and the service only reading', () => {
  // The web service reads and never changes a machine. Grant-VmfAccess.ps1
  // has always drawn that line; the page has to draw the same one.
  const plan = grantPlan('migrate', IDS);
  eq(plan.length, 2, 'two assignments');
  const engine = plan.find(p => p.principalId === 'engine-0000');
  const service = plan.find(p => p.principalId === 'service-0000');
  eq(engine.roleDefinitionId, IDS.migrateRoleId, 'the engine migrates');
  eq(service.roleDefinitionId, IDS.assessRoleId, 'the service only reads');
});

test('a config that does not name the web service plans ONE and says so', () => {
  // An install deployed before this change carries no web service id. The
  // page must not grant half in silence - that is the whole defect.
  const old = { ...IDS, webServicePrincipalId: '' };
  const plan = grantPlan('migrate', old);
  eq(plan.length, 1, 'only the engine can be granted');
  eq(plan[0].principalId, 'engine-0000');
  ok(plan.incomplete === true, 'the plan must declare itself incomplete');
});

test('the product reaches a scope only when BOTH halves do', () => {
  eq(productReach(true, true), 'full');
});

test('and a scope only the engine holds is not the product reaching it', () => {
  // THE DEFECT, as a verdict. This is what the lab install looked like,
  // and the page drew it as though the product were covered.
  eq(productReach(true, false), 'engine-only');
});

test('nor is one only the web service holds', () => {
  eq(productReach(false, true), 'service-only');
});

test('neither is nothing', () => {
  eq(productReach(false, false), 'none');
});

test('and a half it could not read is CANNOT TELL, never covered', () => {
  // The IMAGE-1 rule, here: unknown must never be read as a yes. A listing
  // that failed for one identity is not evidence that identity has nothing,
  // and it is certainly not evidence the product is covered.
  eq(productReach(true, null), 'unknown');
  eq(productReach(null, true), 'unknown');
  eq(productReach(null, null), 'unknown');
});

test('a half-granted scope can be REPAIRED, not only removed', () => {
  // Found in use: the page correctly said "the engine only,
  // the web service cannot read this place" - and offered one button, Remove.
  // So the only route out of a half grant was to destroy the half that works
  // and start again, or to leave the app entirely.
  //
  // CLAUDE.md rule 11: a control that can only be committed to is a trap.
  // Rule 12: every operator action is reachable from the app.
  const plan = repairPlan('/subscriptions/s', IDS);
  eq(plan.length, 1, 'only the missing half is granted');
  eq(plan[0].principalId, 'service-0000', 'the web service');
  eq(plan[0].roleDefinitionId, IDS.assessRoleId, 'reading, never migration');
  eq(plan[0].scope, '/subscriptions/s', 'at the place that is half granted');
});

test('and the repair never touches the engine, which already has what it needs', () => {
  const plan = repairPlan('/subscriptions/s', IDS);
  ok(!plan.some(p => p.principalId === 'engine-0000'), 'the engine is left alone');
});

test('a config that cannot name the web service offers no repair it cannot make', () => {
  // Offering a button that cannot work is worse than offering none: it reports
  // an action the product does not have.
  const plan = repairPlan('/subscriptions/s', { ...IDS, webServicePrincipalId: '' });
  eq(plan.length, 0, 'nothing to offer');
});
run('access-half');
