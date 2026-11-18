/* DECIDE-1: the stop that is a CHOICE, decided for one machine.
 *
 * A machine parks because a rebuild will destroy its system-assigned
 * identity. The only control the page offered was "Try this machine again".
 * Pressing it re-ran PRECHECK, which read the same plan lever, which still
 * said stop - so the machine parked again, with the same reason, for ever.
 * There was nothing to correct between the two attempts, because a rebuild
 * always destroys that identity. The one way through from the app was to
 * change the setting for the WHOLE WAVE, which also cleared that wave's
 * approval and dropped the same protection from every other machine in it.
 *
 * The engine could always do this one machine at a time. The page never sent
 * it. These tests run the page's own function.
 *
 * REBUILD-REMOVE-ACCEPT-1: the identity stop is gone with the rebuild, so the
 * example here is the other decision, accelerated networking that a target
 * requires. The page follows the reason's data either way.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const askDecide = lift('migrations.html', 'askDecide');
// DECIDE-APPROVAL-STALE-1: askDecide says its result through the page's own
// decideDoneText, so it is lifted beside it.
global.decideDoneText = lift('migrations.html', 'decideDoneText');

let modal = null, sent = null;
global.openModal = (o) => { modal = o; };
global.apiFetch = (url, body) => { sent = { url, body }; return Promise.resolve({}); };
global.runSeg = () => 'run-7';
global.noteField = () => ({ id: 'note', required: true });
global.UX_ACT = {
  decideTitle: 'Accept this for one machine',
  decideDesc: 'You accept this for this machine only.',
  decideConfirm: 'Accept and continue',
};

const IDENTITY = {
  code: 'acceleratedNetworkingRequired',
  whatToDo: 'The target size requires accelerated networking.',
  retry: 'decision',
  decide: { lever: 'acceleratedNetworking', accept: 'ensureOn', approver: true },
};

const reset = () => { modal = null; sent = null; };

test('it decides ONE machine, by writing the lever the reason names', async () => {
  reset();
  askDecide('/s/rg/vm/app01', IDENTITY);
  ok(modal, 'a modal opens');
  await modal.onConfirm({ note: 'the report team signed this off' });
  eq(sent.url, 'runs/run-7/vms/resolve', 'endpoint');
  eq(sent.body.vmId, '/s/rg/vm/app01', 'one machine, named');
  eq(sent.body.policyOverride, { acceleratedNetworking: 'ensureOn' },
     'THE WHOLE POINT: the page sends a policy override, which it never did');
  eq(sent.body.note, 'the report team signed this off', 'the note is recorded');
});

test('the lever comes from the DATA, not from a name written into this page', async () => {
  // If the page hard-coded acceleratedNetworking, this passes anyway and
  // proves nothing - so decide with a reason that names a different lever and
  // check the page followed it. A second decision added to stop-reasons.json
  // must get a working control with no change here.
  reset();
  askDecide('/s/rg/vm/app01', {
    code: 'somethingElse', whatToDo: 'x', retry: 'decision',
    decide: { lever: 'onDDataFound', accept: 'proceed', approver: true },
  });
  await modal.onConfirm({ note: 'n' });
  eq(sent.body.policyOverride, { onDDataFound: 'proceed' }, 'the lever the reason named');
});

test('a reason with no decide block sends nothing at all', async () => {
  // Rather than posting a resolve with an empty override, which would re-arm
  // the machine and park it again - the exact loop this replaces.
  reset();
  askDecide('/s/rg/vm/app01', { code: 'permissionsMissing', retry: 'afterFix', whatToDo: 'x' });
  eq(modal, null, 'no modal');
  eq(sent, null, 'nothing sent');
});

test('and neither does a missing accept value', async () => {
  reset();
  askDecide('/s/rg/vm/app01', { retry: 'decision', decide: { lever: 'onDDataFound' } });
  eq(modal, null, 'no modal');
});

test('the button says what it does, and the reason says what is accepted', () => {
  reset();
  askDecide('/s/rg/vm/app01', IDENTITY);
  eq(modal.confirmLabel, 'Accept and continue',
     'not "Confirm" - the word carries the consequence');
  ok(modal.desc.includes(IDENTITY.whatToDo),
     "the reason's own guidance, so the page cannot say something different from the manual");
  ok(modal.desc.includes('this machine only'), 'and that it is one machine, not the wave');
  ok(modal.fields.some(f => f.id === 'note'), 'a note is required');
});

run();
