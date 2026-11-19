/* PLANRUN-1 on the Migrations page: a wave of a signed-off plan that will start
 * ON ITS OWN says so - "Starts when wave-1 finishes" - instead of offering a
 * Start button that would race the plan's timer.
 *
 * The trap this guards: the page SORTS waves by name for display, and the
 * engine runs them in PLAN order. Read off the sort, "starts when X finishes"
 * would name the wrong wave.
 *
 * RUN, not read: the page's own planRunOrder and planFollowText.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
// WAVE-ORDER-START-1: planRunOrder is VmfHelp.waveOrder over the moved machines.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { waveOrder: lift('help.js', 'waveOrder') });
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
const planRunOrder = lift('migrations.html', 'planRunOrder');
globalThis.planRunOrder = planRunOrder;
const planFollowText = lift('migrations.html', 'planFollowText');
const U = globalThis.UX_MISC;

// Plan order zulu -> alpha -> mike: NOT the alphabetical order the page shows.
const plan = { entries: [
  { vmId: 'z1', wave: 'zulu', path: 'A' }, { vmId: 'a1', wave: 'alpha', path: 'A' },
  { vmId: 'm1', wave: 'mike', path: 'A' }, { vmId: 'x1', wave: 'unscheduled', path: 'A' },
  { vmId: 'q1', wave: 'manual', path: 'MANUAL' }] };
const states = (s) => (id) => s[id] ?? 'PLANNED';

test('RUN: the order is the plan\'s, which is the engine\'s', () => {
  eq(planRunOrder(plan).join(','), 'zulu,alpha,mike');
});

test('RUN: before anything begins, the first wave is started by a person', () => {
  eq(planFollowText('zulu', plan, states({}), null), null, 'a Start button, not a promise');
  eq(planFollowText('alpha', plan, states({}), null), U.startsAfter.replace('{wave}', 'zulu'),
    'the second follows the first - by PLAN order, not by name');
});

test('RUN: while the first runs, the next waits for it, and the one after waits for the next', () => {
  const s = states({ z1: 'CONVERTING' });
  eq(planFollowText('alpha', plan, s, null), U.startsAfter.replace('{wave}', 'zulu'));
  eq(planFollowText('mike', plan, s, null), U.startsAfter.replace('{wave}', 'alpha'));
});

test('RUN: once the one before has finished, it starts on the next pass', () => {
  eq(planFollowText('alpha', plan, states({ z1: 'MIGRATED' }), null), U.startsSoon);
});

test('RUN: a machine waiting for a person holds the plan, whatever the timer last said', () => {
  eq(planFollowText('alpha', plan, states({ z1: 'NEEDS_DECISION' }), { reason: 'start', detail: 'old' }), U.planHeld);
});

// RESTORED-HOLD-1: a restore as new as the stop ends the stop - help.js's own
// machineOutcome says putBack - so the machine no longer holds the plan. The
// engine's timer asks the same rule (Get-VmfNextPlanWave -Settled).
test('RUN: a machine whose stop a restore ended does not hold the plan', () => {
  if (!globalThis.WORKING_STATES) {
    const help = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
    // eslint-disable-next-line no-eval
    globalThis.WORKING_STATES = eval(help.match(/const WORKING_STATES = (\[[^\]]+\]);/)[1]);
  }
  globalThis.VmfHelp.machineOutcome = lift('help.js', 'machineOutcome');
  const stoppedAt = '2026-11-06T10:00:00Z';
  const stopped = (state) => ({ vmId: 'z1', state, history: [{ tsUtc: stoppedAt, state, reasonCode: 'guestCheckFailed' }] });
  for (const state of ['NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION']) {
    const s = states({ z1: state });
    const restored = { ...stopped(state), restore: { restoredUtc: '2026-11-06T10:30:00Z' } };
    eq(planFollowText('alpha', plan, s, null, () => stopped(state)), U.planHeld, `${state}, no restore: held`);
    eq(planFollowText('alpha', plan, s, null, () => restored), U.startsSoon, `${state}, restored: it starts`);
    const older = { ...stopped(state), restore: { restoredUtc: '2026-11-06T09:00:00Z' } };
    eq(planFollowText('alpha', plan, s, null, () => older), U.planHeld, `${state}, a restore older than the stop: held`);
    const swapLeft = { ...restored, swapPending: { kind: 'restore', swaps: [{ lun: 0 }] } };
    eq(planFollowText('alpha', plan, s, null, () => swapLeft), U.planHeld, `${state}, a data disk swap left: held`);
  }
});

test('the wave header gives it each machine\'s record', () => {
  ok(/planFollowText\(wave, planDoc, vmStateOf, planRunStatus, \(id\) => allVms\.find\(v => v\.vmId === id\)\)/.test(PAGE), 'the records this page read');
});

test('RUN: the timer\'s own reason is shown when it is why the wave waits', () => {
  const status = { reason: 'gate', detail: 'Wave alpha is next, and it cannot start yet. Nobody accepted the settings of wave alpha. On wave alpha, select Review & accept options.' };
  eq(planFollowText('alpha', plan, states({ z1: 'MIGRATED' }), status), status.detail);
});

test('RUN: a wave that is not in the order says nothing', () => {
  eq(planFollowText('manual', plan, states({}), null), null);
  eq(planFollowText('unscheduled', plan, states({}), null), null);
});

test('the wave header uses it instead of Start, only for a signed-off plan it covers', () => {
  ok(/const planCovers = Boolean\(planSignoff && planSignoffCurrent\) && !isUnplannedWave\(wave\);/.test(PAGE), 'covered only by a CURRENT sign-off');
  // LAB-UX-1: and not for a wave whose every machine has run - one with a
  // machine rolled back said "Starts within five minutes" after it finished.
  // LAB-UX-1: the decision moved into waveStartHtml, which finished-plan-words.test.js RUNS.
  ok(/const follows = \(o\.planCovers && !o\.waveWorking && !o\.waveDone && !waveRan && !o\.sched\)/.test(PAGE), 'and only for a wave that has not begun');
  // STARTS-SOON-WORDS-1: the line "Starts at the next check of the service" has its (?).
  ok(/if \(follows\) \{ return follows === UX_MISC\.startsSoon \? startsSoonHtml\(wave\) : `<span class="muted">\$\{esc\(follows\)\}<\/span>`; \}/.test(PAGE), 'the line replaces Start');
  ok(/approveBtn = \(needsApproval && !appr && !planCovers && canApprove\(\)/.test(PAGE), 'and a signed plan asks for no per-wave Approve');
});

// WAVE-APPROVE-1: the plan starts a wave on its own only with the consent of a
// sign-off AND the wave's own approval. A change to one wave after the sign-off
// asks again for that wave only, and its header shows Approve, not "Starts when".
const planStartsWave = lift('migrations.html', 'planStartsWave');

test('WAVE-APPROVE-1: RUN: a sign-off of version 3 consents after a change; the wave still needs its own approval', () => {
  const v3 = { schemaVersion: 3 };
  eq(planStartsWave(v3, false, { wave: 'w2' }), true, 'approved on its own: it follows');
  eq(planStartsWave(v3, false, null), false, 'changed after the sign-off: it waits');
  eq(planStartsWave(v3, true, null), true, 'the sign-off of this very plan covers it');
});

test('WAVE-APPROVE-1: RUN: a wave set to need no approval does not start by itself after it changed', () => {
  // The review: a start nobody presses must rest on something an approver
  // signed. Its own approval (written by Sign off all) went with the change;
  // a person can still press Start.
  eq(planStartsWave({ schemaVersion: 3 }, false, null), false);
});

test('MIGRATIONS-PAGE-OLD-READERS-1: the sign-off is read with no version - Approve-VmfPlan writes only v4', () => {
  ok(!/schemaVersion/.test(planStartsWave.toString()), 'planStartsWave reads no schemaVersion');
  eq(planStartsWave({}, false, { wave: 'w2' }), true, 'a sign-off of an earlier plan version, with the wave approved');
  eq(planStartsWave(null, true, { wave: 'w2' }), false, 'no sign-off: started by a person');
});

test('WAVE-APPROVE-1: the wave header asks it, and the gate line follows the same answer', () => {
  ok(/const planStarts = planStartsWave\(planSignoff, planSignoffCurrent, appr\) && !isUnplannedWave\(wave\);/.test(PAGE), 'asked with the wave and its approval');
  ok(/waveStartHtml\(wave, info\.entries, \{ planCovers: planStarts,/.test(PAGE), 'the start control uses it');
  ok(/esc\(planStarts \? UX_MISC\.gateTextPlan : UX_MISC\.gateText\)/.test(PAGE), 'and the line between waves');
});

run('plan-follow');
