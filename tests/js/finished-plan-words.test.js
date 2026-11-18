/* LAB-UX-1, from the 2026-09-30 lab session, on the Migrations page:
 *
 *   - "What happens next: The plan is ready ... approve and start the first
 *     one" was shown after every wave had run;
 *   - a wave card said "Starts within five minutes" on a wave that had
 *     finished - its one machine had rolled back, and the page counted a
 *     wave finished only when every machine was migrated or left out.
 *
 * RUN, not read: the page's own settledAll and renderNextStep.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.VmfHelp = { VmfRun: { link: (p) => p }, ...liftAll('help.js', ['machineStarted', 'machineHold', 'machineAtWork', 'waveHold', 'waveOrder', 'idKey']) };
// WAVE-RUNNING-LEASE-1: no machine of these runs has a lease.
globalThis.leaseOf = () => undefined;
globalThis.currentRun = 'run-1';
globalThis.latestEvents = [];
// BRAKE-WAIT-WORDS-1: the wave safety brake, as the refresh keeps it.
globalThis.latestHalted = false;
globalThis.canOperate = () => true;
globalThis.lastEngineFailure = () => null;
const nextEl = { innerHTML: '' };
globalThis.$ = (sel) => (sel === '#nextstep' ? nextEl : null);
// PANEL-OLD-STOP-1: and asks wavesInFlight whether a wave runs now.
// WAVE-ORDER-START-1: and says it in words through nextStepSaid, with the start
// and the wait read from the events.
// MIGRATIONS-WORDS-LAB-1: renderNextStep asks scheduledFirstWave about a
// signed-off first wave with a start time; no wave here has a schedule.
globalThis.scheduledFirstWave = () => null;
// STOP-STATE-SHOWN-1: renderNextStep reads the record of a stop; none here.
globalThis.runStop = null;
globalThis.schedules = new Map(); globalThis.approvals = new Map(); globalThis.acceptances = new Map();
globalThis.planSignoff = null; globalThis.planSignoffCurrent = false; globalThis.runAcknowledged = () => true;
const page = liftAll('migrations.html', ['settledAll', 'wavesInFlight', 'nextWaveButton', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords',
  'waitingOnlyForCheck', 'waveStartRequested', 'nextStepSaid', 'renderNextStep']);
const U = globalThis.UX_ACT;

const states = (s) => (id) => s[id] ?? 'PLANNED';
const entries = [
  { vmId: 'a', wave: 'w1', path: 'A' },
  { vmId: 'b', wave: 'w2', path: 'A' },
  // Given no target: the plan does not move it, and it never gets a state.
  { vmId: 'm', wave: 'unscheduled', path: 'MANUAL' },
];

test('a wave whose machine rolled back has run', () => {
  eq(page.settledAll([entries[0]], states({ a: 'FAILED_ROLLED_BACK' })), true, 'rolled back is settled');
  eq(page.settledAll([entries[0]], states({ a: 'MIGRATED' })), true, 'migrated');
  eq(page.settledAll([entries[0]], states({ a: 'CONVERTING' })), false, 'still working');
  eq(page.settledAll([entries[0]], states({})), false, 'not started');
});

test('a machine the plan does not move does not hold a wave open, and an empty list has not run', () => {
  eq(page.settledAll([entries[0], entries[2]], states({ a: 'MIGRATED' })), true, 'the MANUAL machine is not counted');
  eq(page.settledAll([entries[2]], states({})), false, 'nothing that moves: not run');
  eq(page.settledAll([], states({})), false, 'nothing at all');
});

const nextFor = (s) => {
  globalThis.planDoc = { entries };
  globalThis.allVms = Object.entries(s).map(([vmId, state]) => ({ vmId, state }));
  page.renderNextStep([]);
  return nextEl.innerHTML;
};

test('after every wave has run, the next step does not say to start the first one', () => {
  const html = nextFor({ a: 'MIGRATED', b: 'FAILED_ROLLED_BACK' });
  ok(html.includes(U.nextAllRan), html);
  ok(!html.includes(U.nextPlanned), 'not the start line');
  ok(!html.includes(U.arrangeWaves), 'and no button to arrange waves that have all run');
});

test('before that, it still does - for a plan where no wave has started', () => {
  const html = nextFor({});
  ok(html.includes(U.nextPlanned) && html.includes(U.arrangeWaves), html);
});

test('PANEL-OLD-STOP-1: between waves, it says to start the next wave, not the first one', () => {
  const html = nextFor({ a: 'MIGRATED' });
  ok(html.includes(U.nextBetween) && html.includes(U.arrangeWaves), html);
});

/* The wave card's start control, RUN: waveStartHtml decides between a start
 * time, a Start button, the reason it cannot start, and nothing - and reads
 * each machine's state through vmStateOf, the same lookup the card uses. The
 * review found the inline version could lose the state lookup unnoticed. */
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.planRunOrder = require('./_harness').lift('migrations.html', 'planRunOrder');
globalThis.planFollowText = require('./_harness').lift('migrations.html', 'planFollowText');
globalThis.isUnplannedWave = (w) => w === 'unplanned';
globalThis.planRunStatus = null;
// STARTS-SOON-WORDS-1: the line of a wave the service starts has its (?).
globalThis.soonHelpOpen = new Set();
const card = liftAll('migrations.html', ['settledAll', 'vmStateOf', 'startsSoonHtml', 'waveStartHtml']);
const W = [{ vmId: 'a', wave: 'w1', path: 'A' }];
const W2 = [{ vmId: 'b', wave: 'w2', path: 'A' }];
const ctx = (o) => Object.assign({ planCovers: true, waveWorking: false, waveDone: false,
  halted: false, sched: null, startBlockedBy: null }, o);
const at = (s) => { globalThis.allVms = Object.entries(s).map(([vmId, state]) => ({ vmId, state })); };

test('RUN: a signed-off wave whose machine rolled back offers no start time and no Start', () => {
  globalThis.planDoc = { entries: [...W, ...W2] };
  at({ a: 'FAILED_ROLLED_BACK' });
  eq(card.waveStartHtml('w1', W, ctx({})), '', 'the finished wave');
  ok(!card.waveStartHtml('w1', W, ctx({})).includes(globalThis.UX_MISC.startsSoon), 'never "Starts within five minutes"');
  eq(card.waveStartHtml('w1', W, ctx({ planCovers: false })), '', 'and no Start button on an unsigned plan');
  ok(card.waveStartHtml('w2', W2, ctx({})).includes(globalThis.UX_MISC.startsSoon), 'the NEXT wave still starts on its own');
});

test('RUN: a wave nobody has started still offers its Start, or its reason', () => {
  globalThis.planDoc = { entries: [...W, ...W2] };
  at({});
  ok(card.waveStartHtml('w1', W, ctx({ planCovers: false })).includes('data-start="w1"'), 'a Start button');
  ok(card.waveStartHtml('w1', W, ctx({ planCovers: false, startBlockedBy: 'needs a sign-off' })).includes('needs a sign-off'), 'or why not');
  ok(card.waveStartHtml('w1', W, ctx({})).includes('data-start="w1"'), 'the first wave of a signed plan: a person starts it');
});

test('RUN: a scheduled wave offers no Start and no start time - its schedule says when', () => {
  globalThis.planDoc = { entries: [...W, ...W2] };
  at({ a: 'MIGRATED' });
  eq(card.waveStartHtml('w2', W2, ctx({ sched: { runAtUtc: '2026-10-01T02:00:00Z' } })), '', 'signed plan');
  eq(card.waveStartHtml('w2', W2, ctx({ planCovers: false, sched: { runAtUtc: '2026-10-01T02:00:00Z' } })), '', 'unsigned plan');
});

test('the wave card uses waveStartHtml', () => {
  ok(/const startBtn = waveStartHtml\(wave, info\.entries, \{/.test(PAGE), 'the card asks the function');
});

run('finished-plan-words');
