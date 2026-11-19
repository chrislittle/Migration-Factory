/* SAVE-STUCK-1: step 2 of 3 cannot be completed on a plan you agree with.
 *
 * Seen on a plan the product had just grouped by resource group, the default:
 * Save could not be clicked to continue. A person had to edit the plan, then
 * save it, to move past the step.
 *
 * Inside the flow, saving IS continuing - WAVE-FLOW-1 made this page step 2,
 * and Save is the only way to step 3. But the button was disabled whenever
 * nothing had changed. So a person who reads the default grouping and agrees
 * with it is stuck: the way forward is to change something they did not want
 * to change.
 *
 * MEASURED in the page: `saveDisabled: true, title: "", dirty: false,
 * inFlow: true`. And no title at all, so nothing said why - the same dead end
 * as PROJ-EMPTY-1's tooltip, one page along.
 *
 * "Nothing has changed" stops being a reason to disable anything. It is a
 * reason not to WRITE. Re-saving an identical plan is not harmless: it bumps
 * the plan version, and an acceptance is bound to the version it was shown.
 *
 * The page already had this exact shape one button away - Reset is always
 * enabled and says "Nothing to undo - this already matches the saved plan."
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run, lift, liftConst, liftAll } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
const UX = liftConst('waves.html', 'UX');

/* THE PAGE'S OWN save(), RUN.
 *
 * The first shape of the two checks below read the source and compared the
 * POSITION of `dirty()` against the position of the write. Both survived
 * mutation - text order is not behaviour, and a guard that can never be true
 * still reads as being in the right place. So the function is executed with
 * the write stubbed, and what it did is what is measured. */
// QUOTA-TRUTH-1: the write itself moved into writeLayout(), which the quota
// check shares. Lifted together, so save() runs the real one.
const page = liftAll('waves.html', ['writeLayout', 'save']);
globalThis.UX = UX;

function runSave({ dirty, inFlow }) {
  const seen = { wrote: null, went: null, ok: '', saveDisabled: null, continueShown: false };
  const box = (id) => ({
    style: { display: '' },
    set textContent(v) { if (id === '#ok') { seen.ok = v; } },
    get textContent() { return ''; },
    set disabled(v) { if (id === '#save') { seen.saveDisabled = v; } },
    get disabled() { return false; },
    set href(v) { seen.continueShown = true; },
  });
  globalThis.$ = (id) => box(id);
  globalThis.dirty = () => dirty;
  globalThis.inFlow = () => inFlow;
  globalThis.runHref = (p, q) => { seen.went = `${p} ${JSON.stringify(q ?? null)}`; return 'about:blank'; };
  globalThis.runSeg = () => 'run-1';
  globalThis.runBody = (b) => b;
  globalThis.snapshot = () => 'after';
  globalThis.layout = new Map([['wave-1', { vmIds: [], requireApproval: true }]]);
// PLAN-WRITE-RACE-1: the save quotes the plan version the page read.
globalThis.planVersion = 'ver-1';
// The real page, not the sample: writeLayout asks DEMO_MODE before it sends.
globalThis.DEMO_MODE = false;
// WAVE-EDIT-RUNNING-1: writeLayout asks whether a wave is running.
globalThis.waveMigrating = () => false;
  globalThis.apiPost = async (p, b) => { seen.wrote = { p, waves: b.waves.length }; return {}; };
  // CLICKS-LOST-1: save marks its button busy through help.js.
  globalThis.VmfHelp = { explainAction: (e) => String(e && e.message ? e.message : e), markBusy: lift('help.js', 'markBusy') };
  globalThis.original = 'before';
  globalThis.buildLayoutFromPlan = () => {};
  globalThis.render = () => {};
  globalThis.location = { set href(v) { seen.went = seen.went ?? v; } };
  return page.save().then(() => seen);
}

// WAVE-LEVER-OVERRIDE-1: writeLayout lists the settings changed on each card
// (changedOf) and draws each card again after a save (WAVE_DEFAULTS).
globalThis.changedOf = () => ({});
// WAVE-LEVER-RESET-1: and the machines reset to the value of the wave (resetOf).
globalThis.resetOf = () => ({});
globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
test('Save is never disabled just because nothing has changed', () => {
  // THE DEFECT. Inside the flow this button is the only way onward.
  ok(!/\$\('#save'\)\.disabled = !canEdit \|\| !dirty\(\)/.test(PAGE),
    'a plan somebody agrees with must not be a plan they cannot leave');
  ok(/\$\('#save'\)\.disabled = !canEdit/.test(PAGE),
    'it is still withheld from somebody who may not edit');
});

test('RUN: an unchanged plan is not written again', async () => {
  /* Re-saving an identical plan bumps the plan version, and an acceptance is
   * bound to the version it was shown. So the button continues without
   * writing rather than writing something that changes nothing. */
  const seen = await runSave({ dirty: false, inFlow: true });
  ok(seen.wrote === null, 'nothing may be written when nothing changed');
});

test('RUN: inside the flow it continues, because saving IS continuing here', async () => {
  const seen = await runSave({ dirty: false, inFlow: true });
  ok(/wizard\.html/.test(seen.went ?? ''), 'it goes on to the next step');
  ok(/"step":"run"/.test(seen.went ?? ''), 'which is the step that runs it');
});

test('RUN: outside the flow it says so, rather than doing nothing', async () => {
  // Silence is indistinguishable from a broken button - the page's own words,
  // written for Reset one button along.
  const seen = await runSave({ dirty: false, inFlow: false });
  ok(seen.wrote === null, 'still nothing written');
  ok(seen.ok === UX.saveNothing, 'and it says the plan was already saved');
  ok(seen.saveDisabled === false, 'the button is usable again afterwards');
});

test('RUN: a plan that DID change is still written', async () => {
  // The half that must not regress.
  const seen = await runSave({ dirty: true, inFlow: false });
  ok(seen.wrote !== null, 'a real change must still reach the service');
  ok(/plan\/waves$/.test(seen.wrote.p), 'on the route that saves the waves');
});

test('the words say the plan is already saved, not that something failed', () => {
  ok(/Nothing to save/i.test(UX.saveNothing),
    'a failure message here would send somebody looking for a fault');
});

run('save-stuck');
