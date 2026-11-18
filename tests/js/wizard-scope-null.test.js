/* WIZARD-SCOPE-NULL-1: an older scan said "It looked in:  inside subscription X".
 *
 * A scan saved before SCAN-SCOPE-NULL-1 with no resource group filter holds
 * `"resourceGroups": [null]`. When such a scan found no machine, the wizard's
 * "What we found" step (scopeSummary) read `resourceGroups.length` - 1 for
 * `[null]` - joined the list into an empty text, and named a blank resource
 * group inside the subscription. The scan really looked in the whole
 * subscription. The Assessments page already takes the nulls out
 * (`(scope.resourceGroups || []).filter(Boolean)`); the wizard did that for
 * the subscriptions only.
 *
 * RUN, not read: the wizard's own scopeSummary, with the page state it reads.
 * Stored scans are not changed: the page reads both shapes.
 */
'use strict';
const { lift, liftConst, test, ok, run } = require('./_harness');

globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.esc = (s) => String(s ?? '');
globalThis.scopes = { subscriptions: [{ id: 'sub-1', name: 'Contoso lab' }] };
globalThis.assessment = null;
const scopeSummary = lift('wizard.html', 'scopeSummary');

const said = (scope) => { globalThis.assessment = { scope }; return scopeSummary(); };

test('THE DEFECT: an older scan with resourceGroups [null] says the whole subscription', () => {
  const out = said({ subscriptions: ['sub-1'], resourceGroups: [null], managementGroup: null });
  ok(/whole subscription/i.test(out), `it must say the whole subscription: ${out}`);
  ok(out.includes('Contoso lab'), `it must name the subscription: ${out}`);
  ok(!/inside subscription/i.test(out), `a blank resource group must not sit inside it: ${out}`);
});

test('the older scan reads the same as a new scan with an empty list', () => {
  const old = said({ subscriptions: ['sub-1'], resourceGroups: [null], managementGroup: null });
  const now = said({ subscriptions: ['sub-1'], resourceGroups: [], managementGroup: null });
  ok(old === now, `the two shapes must give one sentence: "${old}" and "${now}"`);
});

test('a scan of one real resource group still names it inside the subscription', () => {
  const out = said({ subscriptions: ['sub-1'], resourceGroups: ['rg-app'], managementGroup: null });
  ok(out.includes('rg-app'), `it must name the group: ${out}`);
  ok(/inside subscription/i.test(out), `the subscription is where the group sits: ${out}`);
  ok(!/whole subscription/i.test(out), `one group is not the whole subscription: ${out}`);
});

test('a null next to a real group is left out, so no empty name joins the list', () => {
  const out = said({ subscriptions: ['sub-1'], resourceGroups: [null, 'rg-app'], managementGroup: null });
  ok(out.includes('rg-app'), `it must name the group: ${out}`);
  ok(!/:\s*,|,\s*,|,\s*inside/i.test(out), `no blank entry in the list: ${out}`);
});

test('an older management group scan with resourceGroups [null] says the whole management group', () => {
  const out = said({ subscriptions: [], resourceGroups: [null], managementGroup: 'mg-contoso' });
  ok(out.includes(UX.s2NoneWholeGroup.trim()), `it must say the whole management group: ${out}`);
  ok(out.includes('mg-contoso'), `it must name the management group: ${out}`);
});

run('WIZARD-SCOPE-NULL-1: an older scan says where it looked');
