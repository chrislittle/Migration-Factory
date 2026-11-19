/* RETRY-GATE-1: Try this machine again, in a wave that cannot start.
 *
 * The engine refuses the retry and names the missing step in the start gate's
 * own words (tests/unit/RetryGate.Tests.ps1). The page shows that sentence
 * where the person pressed Try again: in the same dialog, which stays open,
 * without the status code in front of it.
 *
 * RUN, not read: the page's own askResolve, openModal and closeModal, and
 * help.js's rules evaluated from the file itself (as plan-write-race.test.js
 * takes them).
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const START = 'const ROLE_WORDS';
const END = 'function explainAction(err) { return explainWith(err, true); }';
const from = HELP.indexOf(START);
const to = HELP.indexOf(END);
const slice = (from >= 0 && to > from) ? HELP.slice(from, to + END.length) : '';
// eslint-disable-next-line no-eval
const rules = slice ? eval(`(function () { ${slice}; return { explain, explainAction }; })()`) : null;

// What the engine says for a wave whose settings nobody accepted.
// GATE-WORDS-1: the gate's words, from src/VmMigrationFactory/data/start-gates.json.
const REFUSAL = '400: Nothing changed for vm1, because wave w1 cannot start. Nobody accepted the settings of wave w1. ' +
  'On wave w1, select Review & accept options. Then try this machine again.';
const SENTENCE = REFUSAL.replace(/^400: /, '');

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
globalThis.retryFacts = () => null;
globalThis.ago = () => '';
globalThis.runSeg = () => 'run-1';
globalThis.noteField = () => ({ id: 'note', type: 'textarea', required: true });
// DIALOG-STALE-1: the page's own `let`, which openModal and closeModal clear.
globalThis.modalMachine = null;
const modal = liftAll('migrations.html', ['closeModal', 'openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText']);
globalThis.openModal = modal.openModal;
const askResolve = lift('migrations.html', 'askResolve');

test('help.js: an action the engine refused shows its sentence, without the code', () => {
  ok(rules, 'the rules were not found in help.js');
  eq(rules.explainAction(new Error(REFUSAL)), SENTENCE);
});

test('help.js: a 400 that names a missing thing keeps its words, not the 404 answer', () => {
  const said = rules.explainAction(new Error('400: Nothing changed for vm1. The plan entry was NotFound in wave w1.'));
  eq(said, 'Nothing changed for vm1. The plan entry was NotFound in wave w1.');
});

test('help.js: a refusal that names a machine called web401 is not read as a sign-in failure', () => {
  const said = rules.explainAction(new Error('400: Nothing changed for web401, because wave w1 cannot start. Then try this machine again.'));
  eq(said, 'Nothing changed for web401, because wave w1 cannot start. Then try this machine again.');
  const conflict = rules.explainAction(new Error('409: Somebody changed the plan at 10:40:14.4013, so web401 was not saved.'));
  eq(conflict, 'Somebody changed the plan at 10:40:14.4013, so web401 was not saved.');
});

test('help.js: a READ that failed with 400 is not rewritten - the rule is for actions', () => {
  eq(rules.explain(new Error(REFUSAL)), REFUSAL);
});

test('Try this machine again: the refusal is said in the dialog the person pressed, which stays open', async () => {
  const $ = fakeDom(); globalThis.$ = $;
  globalThis.VmfHelp = { explainAction: rules.explainAction };
  const calls = [];
  globalThis.apiFetch = async (p, body) => { calls.push({ p, body }); throw new Error(REFUSAL); };
  askResolve('vm1', { state: 'FAILED_ROLLED_BACK', history: [] });
  eq($('#m-title').textContent, UX_ACT.resolve, 'the Try again dialog');
  $('#mf-note').value = 'fixed the boot setting';
  await $('#m-confirm').onclick();
  eq(calls.length, 1, 'the service was asked');
  eq(calls[0].p, 'runs/run-1/vms/resolve');
  eq($('#m-err').style.display, 'block', 'the refusal is shown');
  eq($('#m-err').textContent, SENTENCE, 'in the engine words, naming the missing step');
  ok($('#modal-back').classList.set.has('open'), 'the dialog stays open, with its Cancel');
  eq($('#m-confirm').disabled, false, 'and Confirm can be pressed again once the step is done');
  ok($('#ok').style.display !== 'block', 'no success message');
});

run('retry-gate');
