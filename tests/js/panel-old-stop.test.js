/* PANEL-OLD-STOP-1, from the BGINFO-PERM-1 lab drill, 2026-10-24, on the
 * Migrations page of the installed app:
 *
 *   - a machine stopped at PRECHECK (permissionsMissing), was tried again
 *     after the fix, and reached MIGRATED. Its side panel still showed the
 *     stop box: "This account cannot finish the migration ... Nothing on this
 *     machine was changed". whyStoppedCard drew the NEWEST history entry with
 *     a reason code, and a retry writes entries with none.
 *   - while the retried wave ran, "What happens next" said "The plan is
 *     ready. Review the waves below, then approve and start the first one."
 *
 * RUN, not read: the page's own currentStop, whyStoppedCard, wavesInFlight
 * and renderNextStep.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const table = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/const PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const U = globalThis.UX_ACT;
globalThis.esc = (s) => String(s ?? '');
globalThis.canApprove = () => true;
globalThis.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
globalThis.retryLines = table.retryLines;
// STOP-HEADLINE-CHECK-1: whyStoppedCard reads the check of a stop with stopCheckSentence.
globalThis.STOP_CHECK = liftConst('migrations.html', 'STOP_CHECK');
const card = liftAll('migrations.html', ['attemptStop', 'currentStop', 'stopCheckSentence', 'whyStoppedCard']);
const permTitle = stopReasons.get('permissionsMissing').title;

// The first attempt, as the engine writes it: PRECHECK, then the park.
const firstAttempt = [
  { tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-24T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'permissionsMissing',
    machineState: 'untouched', detail: 'The identity has no Microsoft.Compute/virtualMachines/write.' },
];
// Try this machine again: the decision re-arms it at PRECHECK, and the new
// attempt runs to the end. None of these entries has a reason code.
const retried = [
  { tsUtc: '2026-10-24T11:00:00Z', state: 'PRECHECK', outcome: 'ok', detail: 'Decision resolved by operator@example.com: fixed. Re-armed at PRECHECK for the next wave run.' },
  { tsUtc: '2026-10-24T11:02:00Z', state: 'SAFETY_PRISTINE', outcome: 'ok' },
  { tsUtc: '2026-10-24T11:20:00Z', state: 'CONVERTING', outcome: 'ok' },
];

test('a MIGRATED machine whose history holds an older permissionsMissing stop shows no stop box', () => {
  const doc = { state: 'MIGRATED', history: [...firstAttempt, ...retried,
    { tsUtc: '2026-10-24T11:40:00Z', state: 'MIGRATED', outcome: 'ok' }] };
  eq(card.currentStop(doc), null, 'no current stop');
  eq(card.whyStoppedCard(doc), '', 'no box');
});

test('the state decides on its own: a machine not in a stopped state shows no box, even when its last entry is a stop', () => {
  for (const state of ['MIGRATED', 'SKIPPED', 'PRECHECK', 'PLANNED', undefined]) {
    const doc = { state, history: [...firstAttempt] };
    eq(card.currentStop(doc), null, `state ${state}`);
  }
});

test('a machine the newest attempt is still moving shows no box from the earlier attempt', () => {
  const doc = { state: 'CONVERTING', history: [...firstAttempt, ...retried] };
  eq(card.whyStoppedCard(doc), '', 'no box while it moves');
});

test('a machine parked by its newest attempt still shows that stop', () => {
  const doc = { state: 'NEEDS_DECISION', history: [...firstAttempt] };
  eq(card.currentStop(doc), firstAttempt[1], 'the park is the current stop');
  const html = card.whyStoppedCard(doc);
  ok(html.includes(permTitle), html);
  ok(html.includes(U.whyUntouched), 'and where it left the machine');
});

test('a retry that stopped again shows the NEW stop, not the old one', () => {
  const again = { tsUtc: '2026-10-24T11:30:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail',
    reasonCode: 'validationFailedAfterConversion', machineState: 'restored' };
  const doc = { state: 'FAILED_ROLLED_BACK', history: [...firstAttempt, ...retried, again] };
  eq(card.currentStop(doc), again, 'the newest stop');
  ok(!card.whyStoppedCard(doc).includes(permTitle), 'not the first attempt');
});

test('a retry that stopped again with no reason code does not show the earlier attempt\'s reason', () => {
  const doc = { state: 'FAILED_NEEDS_ATTENTION', history: [...firstAttempt, ...retried,
    { tsUtc: '2026-10-24T11:30:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail' }] };
  eq(card.currentStop(doc), null, 'the earlier stop belongs to the earlier attempt');
  eq(card.whyStoppedCard(doc), '', 'no box');
});

test('a later note in the stopped state does not hide the stop', () => {
  const doc = { state: 'NEEDS_DECISION', history: [...firstAttempt,
    { tsUtc: '2026-10-24T10:05:00Z', state: 'NEEDS_DECISION', outcome: 'ok', detail: 'a note' }] };
  eq(card.currentStop(doc), firstAttempt[1], 'still the stop');
});

test('a machine left out of the migration after its stop shows no stop box', () => {
  const doc = { state: 'SKIPPED', history: [...firstAttempt,
    { tsUtc: '2026-10-24T10:30:00Z', state: 'SKIPPED', outcome: 'skip' }] };
  eq(card.whyStoppedCard(doc), '', 'no box');
});

test('a restore after the stop ends it; one from before does not', () => {
  const stop = { tsUtc: '2026-10-01T10:00:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail',
    reasonCode: 'rollbackFailed', machineState: 'changed' };
  eq(card.currentStop({ state: 'FAILED_NEEDS_ATTENTION', restore: { restoredUtc: '2026-10-01T11:00:00Z' }, history: [stop] }), null, 'restored after');
  eq(card.currentStop({ state: 'FAILED_NEEDS_ATTENTION', restore: { restoredUtc: '2026-10-01T09:00:00Z' }, history: [stop] }), stop, 'restored before');
});

test('the side panel draws the box from whyStoppedCard, and the timeline keeps the old stop', () => {
  // RESTORE-PANEL-TIMELINE-1: not while a restore runs, and a restore that did not finish takes its place.
  ok(PAGE.includes(": restoreEnd ? restoreEndCard(restoreEnd) : whyStoppedCard(doc);") && PAGE.includes('${stopBox}'), 'the panel draws the box');
  ok(/function whyStoppedCard\(doc\) \{\s*const stop = currentStop\(doc\);/.test(PAGE), 'the box asks currentStop');
});

/* ---- PANEL-OLD-STOP-2: the stop the panel's buttons take their rules from --
 *
 * openDrill took the NEWEST history entry with a reason code. A retried
 * machine that stops again with a codeless entry then kept the reason of the
 * earlier attempt, and an old notSupported, outOfScope or decision reason hid
 * Try this machine again. The rule now: the newest stop with a reason code in
 * the CURRENT attempt. A retry starts an attempt (a later entry in a step of
 * the move, as currentStop reads it); a restore does not, so an
 * old notSupported stop still governs after one.
 */
const ctl = liftAll('migrations.html', ['attemptStop', 'stopControls', 'decisionWaiting']);
const offerFor = (doc, canOp = true, canAp = true) => {
  const stop = ctl.attemptStop(doc);
  return { stop, offer: ctl.stopControls(doc.state, stopReasons.get(stop?.reasonCode), canOp, canAp) };
};
const stopOf = (code, state, ts, extra = {}) => ({ tsUtc: ts, state, outcome: 'fail', reasonCode: code, ...extra });
const codeless = (state, ts) => ({ tsUtc: ts, state, outcome: 'fail' });

test('a retried machine that stops again with no reason code offers Try this machine again', () => {
  for (const [code, parked] of [['policyNotKnown', 'NEEDS_DECISION'], ['sizeOutOfScope', 'FAILED_NEEDS_ATTENTION'],
                                ['systemIdentityCannotSurvive', 'NEEDS_DECISION']]) {
    for (const again of ['FAILED_NEEDS_ATTENTION', 'FAILED_ROLLED_BACK', 'NEEDS_DECISION']) {
      const doc = { state: again, history: [
        { tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
        stopOf(code, parked, '2026-10-24T10:01:00Z'),
        ...retried, codeless(again, '2026-10-24T11:30:00Z')] };
      const { stop, offer } = offerFor(doc);
      eq(stop, null, `${code} then ${again}: the earlier attempt's stop does not govern`);
      eq(offer.retry, true, `${code} then ${again}: retry offered`);
      eq(offer.decide, false, `${code} then ${again}: no choice from the earlier park`);
    }
  }
});

test('a codeless stop in the current attempt gives the default controls of a stopped machine', () => {
  const doc = { state: 'FAILED_NEEDS_ATTENTION', history: [...retried, codeless('FAILED_NEEDS_ATTENTION', '2026-10-24T11:30:00Z')] };
  eq(offerFor(doc).offer, { decide: false, retry: true }, 'default');
  eq(offerFor(doc, false, true).offer.retry, false, 'still needs the operator role');
});

test('a notSupported or outOfScope stop followed by a restore still hides the retry', () => {
  for (const code of ['policyNotKnown', 'sizeRetired', 'tooManyDataDisks']) {
    const stop = stopOf(code, 'FAILED_NEEDS_ATTENTION', '2026-10-01T10:00:00Z', { machineState: 'changed' });
    const restored = { state: 'FAILED_NEEDS_ATTENTION', restore: { restoredUtc: '2026-10-01T11:00:00Z' }, history: [stop] };
    const r1 = offerFor(restored);
    eq(r1.stop, stop, `${code}: a restore starts no attempt`);
    eq(r1.offer.retry, false, `${code}: no retry after a restore`);
  }
});

test('an ordinary current stop with a reason code gives its own controls, as before', () => {
  const perm = { state: 'NEEDS_DECISION', history: [...firstAttempt] };
  eq(offerFor(perm).stop, firstAttempt[1], 'the stop');
  eq(offerFor(perm).offer, { decide: false, retry: true }, 'permissionsMissing: retry, no choice');
  const scope = { state: 'FAILED_NEEDS_ATTENTION', history: [stopOf('sizeOutOfScope', 'FAILED_NEEDS_ATTENTION', '2026-10-24T10:01:00Z')] };
  eq(offerFor(scope).offer.retry, false, 'outOfScope: no retry');
  const never = { state: 'FAILED_ROLLED_BACK', history: [stopOf('policyNotKnown', 'FAILED_ROLLED_BACK', '2026-10-24T10:01:00Z')] };
  eq(offerFor(never).offer.retry, false, 'notSupported: no retry');
  // A note in a stopped state is not a new attempt.
  const noted = { state: 'FAILED_NEEDS_ATTENTION', history: [...scope.history,
    { tsUtc: '2026-10-24T10:05:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'ok', detail: 'a note' }] };
  eq(offerFor(noted).offer.retry, false, 'a note keeps the stop');
});

test('a retry that stops again WITH a reason code takes the new reason', () => {
  const doc = { state: 'FAILED_ROLLED_BACK', history: [
    stopOf('systemIdentityCannotSurvive', 'NEEDS_DECISION', '2026-10-24T10:01:00Z'), ...retried,
    stopOf('validationFailedAfterConversion', 'FAILED_ROLLED_BACK', '2026-10-24T11:30:00Z', { machineState: 'restored' })] };
  eq(offerFor(doc).stop.reasonCode, 'validationFailedAfterConversion', 'the new stop');
  eq(offerFor(doc).offer.retry, true, 'retry offered');
  const out = { state: 'FAILED_NEEDS_ATTENTION', history: [...firstAttempt, ...retried,
    stopOf('sizeRetired', 'FAILED_NEEDS_ATTENTION', '2026-10-24T11:30:00Z')] };
  eq(offerFor(out).offer.retry, false, 'a new outOfScope stop hides the retry');
});

test('the decision button still asks decisionWaiting(doc) === the panel\'s stop', () => {
  const park = stopOf('dataOnTempDrive', 'NEEDS_DECISION', '2026-10-24T10:01:00Z');
  const parked = { state: 'NEEDS_DECISION', history: [{ tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' }, park] };
  eq(offerFor(parked).offer.decide, true, 'the choice is offered');
  eq(ctl.decisionWaiting(parked), offerFor(parked).stop, 'the same entry, so the button shows');
  const restored = { ...parked, restore: { restoredUtc: '2026-10-24T10:30:00Z' } };
  eq(ctl.decisionWaiting(restored), null, 'a restore ends the park');
  ok(ctl.decisionWaiting(restored) !== offerFor(restored).stop, 'so no button after a restore');
  // Retried, then parked again at the same gate: the new park is both.
  const again = stopOf('dataOnTempDrive', 'NEEDS_DECISION', '2026-10-24T11:30:00Z');
  const reparked = { state: 'NEEDS_DECISION', history: [...parked.history, ...retried, again] };
  eq(offerFor(reparked).stop, again, 'the new park');
  eq(ctl.decisionWaiting(reparked), again, 'the button shows for it');
  // Retried, then stopped with no code at NEEDS_DECISION: no choice from the old park.
  const plain = { state: 'NEEDS_DECISION', history: [...parked.history, ...retried, codeless('NEEDS_DECISION', '2026-10-24T11:30:00Z')] };
  eq(offerFor(plain).offer.decide, false, 'no choice');
});

test('openDrill takes the buttons\' stop from attemptStop', () => {
  ok(/const lastStop = attemptStop\(doc\);/.test(PAGE), 'openDrill asks attemptStop');
  ok(/decisionWaiting\(doc\) === lastStop/.test(PAGE), 'the decision button compares with it');
});

/* ---- What happens next ------------------------------------------------ */

globalThis.VmfHelp = { VmfRun: { link: (p) => p }, ...liftAll('help.js', ['machineStarted', 'machineHold', 'machineAtWork', 'waveHold', 'idKey']) };
// WAVE-RUNNING-LEASE-1: no machine of these runs has a lease.
globalThis.leaseOf = () => undefined;
globalThis.latestEvents = [];
// BRAKE-WAIT-WORDS-1: the wave safety brake, as the refresh keeps it.
globalThis.latestHalted = false;
globalThis.currentRun = 'run-1';
globalThis.canOperate = () => true;
globalThis.lastEngineFailure = () => null;
const nextEl = { innerHTML: '' };
globalThis.$ = (sel) => (sel === '#nextstep' ? nextEl : null);
// MIGRATIONS-WORDS-LAB-1: renderNextStep asks scheduledFirstWave about a
// signed-off first wave with a start time; no wave here has a schedule.
globalThis.scheduledFirstWave = () => null;
// STOP-STATE-SHOWN-1: renderNextStep reads the record of a stop; none here.
globalThis.runStop = null;
globalThis.schedules = new Map(); globalThis.approvals = new Map(); globalThis.acceptances = new Map();
globalThis.planSignoff = null; globalThis.planSignoffCurrent = false; globalThis.runAcknowledged = () => true;
const banner = liftAll('migrations.html', ['settledAll', 'wavesInFlight', 'nextWaveButton', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck', 'waveStartRequested', 'nextStepSaid', 'renderNextStep']);
const entries = [
  { vmId: 'a', wave: 'w1', path: 'A' },
  { vmId: 'b', wave: 'w2', path: 'A' },
  { vmId: 'm', wave: 'unscheduled', path: 'MANUAL' },
];
const nextFor = (s) => {
  globalThis.planDoc = { entries };
  globalThis.allVms = Object.entries(s).map(([vmId, state]) => ({ vmId, state }));
  banner.renderNextStep([]);
  return nextEl.innerHTML;
};

test('a wave that runs now gives the running text, not "approve and start the first one"', () => {
  for (const state of ['PRECHECK', 'SAFETY_PRISTINE', 'CONVERTING', 'VALIDATING']) {
    const html = nextFor({ a: state });
    ok(html.includes(U.nextRunning), `${state}: ${html}`);
    ok(!html.includes(U.nextPlanned), `${state}: not the start line`);
  }
});

test('the retried wave of the drill: one machine moving again after a stop', () => {
  const html = nextFor({ a: 'PRECHECK', b: 'MIGRATED' });
  ok(html.includes(U.nextRunning), html);
});

test('a plan where no wave has started still says to approve and start the first one', () => {
  const html = nextFor({});
  ok(html.includes(U.nextPlanned) && html.includes(U.arrangeWaves), html);
  // WAVE-RUNNING-PLANNED-1: a state document at PLANNED is a machine a worker
  // TOOK (WAVE-MIX-2), so its wave runs - the engine's rule. Only a machine
  // with no state document waits.
  ok(nextFor({ a: 'PLANNED', b: 'PLANNED' }).includes(U.nextRunning), 'state documents at PLANNED: taken by a worker');
});

test('between waves, it says to start the next one, not the first one', () => {
  const html = nextFor({ a: 'MIGRATED' });
  ok(html.includes(U.nextBetween), html);
  ok(!html.includes(U.nextPlanned), 'not the start line');
  ok(html.includes(U.arrangeWaves), 'the waves can still be arranged');
  ok(nextFor({ a: 'NEEDS_DECISION' }).includes(U.nextBetween), 'a stopped machine is not a running wave');
});

test('when every wave has run, it still says so', () => {
  ok(nextFor({ a: 'MIGRATED', b: 'FAILED_ROLLED_BACK' }).includes(U.nextAllRan), 'all ran');
});

test('the wave card and the banner ask one rule for a running wave', () => {
  ok(/const waveWorking = wavesInFlight\(info\.entries, storedStateOf\);/.test(PAGE), 'the wave card asks wavesInFlight');
  eq(banner.wavesInFlight(entries, (id) => ({ a: 'STOPPED' })[id]), true, 'a machine at work');
  eq(banner.wavesInFlight(entries, (id) => ({ a: 'MIGRATED', b: 'NEEDS_DECISION' })[id]), false, 'settled machines');
  eq(banner.wavesInFlight(entries, () => undefined), false, 'no state documents');
});

run('panel-old-stop');
