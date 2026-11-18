/* DECIDE-APPROVAL-STALE-1: a decision says which wave approvals it removed.
 *
 * A decision writes the plan, and a wave approval signs the whole plan, so the
 * service removes every approval the write made out of date and returns those
 * waves (ApprovalsCleared, tests/unit/DecideApprovalStale.Tests.ps1). The page
 * says so where the decision's result is shown: the line after Accept and
 * continue.
 *
 * RUN, not read: the page's own askDecide, openModal and decideDoneText.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

function fakeDom() {
  const els = new Map();
  const el = () => ({
    textContent: '', innerHTML: '', value: '', disabled: false, style: {}, onclick: null,
    classList: { set: new Set(), add(c) { this.set.add(c); }, remove(c) { this.set.delete(c); } },
    querySelectorAll: () => [], querySelector: () => null, addEventListener() {}, focus() {},
  });
  return (sel) => { if (!els.has(sel)) { els.set(sel, el()); } return els.get(sel); };
}

globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.document = { querySelector: () => null, querySelectorAll: () => [] };
globalThis.followThrough = () => {};
globalThis.runSeg = () => 'run-1';
globalThis.noteField = () => ({ id: 'note', type: 'textarea', required: true });
globalThis.setTimeout = () => 0;
// DIALOG-STALE-1: the page's own `let`, which openModal and closeModal clear.
globalThis.modalMachine = null;
const modal = liftAll('migrations.html', ['closeModal', 'openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText']);
globalThis.openModal = modal.openModal;
globalThis.decideDoneText = lift('migrations.html', 'decideDoneText');
const askDecide = lift('migrations.html', 'askDecide');

const GUIDE = { whatToDo: 'Move the files.', decide: { lever: 'onDDataFound', accept: 'proceed' } };
const gone = (w) => UX_ACT.decideApprovalGone.replace('{wave}', w);
const covered = (w) => UX_ACT.decideApprovalCovered.replace('{wave}', w);

async function decide(answer) {
  const $ = fakeDom(); globalThis.$ = $;
  globalThis.VmfHelp = { explainAction: (e) => String(e.message) };
  const calls = [];
  globalThis.apiFetch = async (p, body) => { calls.push({ p, body }); return answer; };
  askDecide('vm1', GUIDE);
  eq($('#m-title').textContent, UX_ACT.decideTitle, 'the decision dialog');
  $('#mf-note').value = 'files are disposable';
  await $('#m-confirm').onclick();
  eq(calls.length, 1, 'the service was asked');
  eq(calls[0].p, 'runs/run-1/vms/resolve');
  eq(JSON.stringify(calls[0].body.policyOverride), JSON.stringify({ onDDataFound: 'proceed' }));
  eq($('#ok').style.display, 'block', 'the result is shown');
  return $('#ok').textContent;
}

test('the string says what the wave save and the target change say', () => {
  eq(gone('w2'), 'The approval of wave w2 signed the plan before this change. Approve the wave again.');
});

test('a decision that removed two approvals names both waves, and says which one to approve again', async () => {
  const said = await decide({ NewState: 'PRECHECK', ApprovalsCleared: ['w1', 'w2'], ApprovalsToRenew: ['w2'] });
  eq(said, `${UX_ACT.done} ${covered('w1')} ${gone('w2')}`);
});

test('with the plan sign-off held, no wave is sent to an Approve the page does not show', async () => {
  const said = await decide({ NewState: 'PRECHECK', ApprovalsCleared: ['w1', 'w2'], ApprovalsToRenew: [] });
  eq(said, `${UX_ACT.done} ${covered('w1')} ${covered('w2')}`);
  ok(!said.includes('Approve the wave again'));
});

test('one wave, as the service may send a single name', async () => {
  const said = await decide({ NewState: 'PRECHECK', ApprovalsCleared: 'w2', ApprovalsToRenew: 'w2' });
  eq(said, `${UX_ACT.done} ${gone('w2')}`);
});

test('a decision that removed none says the usual line, and no approval', async () => {
  eq(await decide({ NewState: 'PRECHECK', ApprovalsCleared: [] }), UX_ACT.done);
  eq(await decide({ NewState: 'PRECHECK' }), UX_ACT.done, 'an older service that does not send the field');
  ok(!(await decide({ NewState: 'PRECHECK', ApprovalsCleared: [] })).includes('approval'));
});

/* The activity shows the line on the screen. Under the label "An operator made
 * the pending decision" the sentence was only in the hover. */
const { stepText } = liftAll('migrations.html', ['stepText']);
global.STEP_MAP = [[/^decision$/, 'decisionMade']];
global.UX_STEP = { decisionMade: 'An operator made the pending decision' };
global.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');

test('the activity shows a decision that removed approvals in its own words', () => {
  const detail = `Decision resolved by operator@example.com: fixed. ${gone('w2')}`;
  eq(stepText({ step: 'decision', outcome: 'ok', detail, approvalsCleared: ['w2'] }), detail);
  eq(stepText({ step: 'decision', outcome: 'ok', detail, approvalsCleared: 'w2' }), detail, 'one wave, as a single name');
});

test('a decision that removed none keeps its label', () => {
  eq(stepText({ step: 'decision', outcome: 'ok', detail: 'resolved by operator@example.com: fixed', approvalsCleared: [] }), UX_STEP.decisionMade);
  eq(stepText({ step: 'decision', outcome: 'ok', detail: 'resolved by operator@example.com: fixed' }), UX_STEP.decisionMade);
  eq(stepText({ step: 'decision', outcome: 'info', detail: 'carried', approvalsCleared: ['w2'] }), UX_STEP.decisionMade, 'only the line that re-arms the machine');
});

run('decide-approval-stale');
