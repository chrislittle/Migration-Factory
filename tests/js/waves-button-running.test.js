/* WAVES-BUTTON-RUNNING-1, from the review of PANEL-OLD-STOP-1, 2026-10-24:
 * while a wave ran, "What happens next" on the Migrations page said "A wave
 * is running now" and offered "Arrange the waves" - which opens an editor
 * that refuses any change to the running wave (WAVE-EDIT-RUNNING-1).
 *
 * The engine refuses a change only to a RUNNING wave: it asks
 * Get-VmfWaveRunningDetail of each wave a save touches. The editor draws a
 * running wave with no controls, AND locks every machine in a started state -
 * settled ones too, MIGRATED, rolled back or parked (help.js machineStarted,
 * the editor's started()). What a person can still change while a wave runs:
 * a machine with no wave, or a machine that has not started in a wave that is
 * not running. When one exists, the button stays and says so; when none
 * exists, the editor can change nothing, and the button goes.
 *
 * RUN, not read: the page's own nextWaveButton and renderNextStep.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const U = globalThis.UX_ACT;
globalThis.esc = (s) => String(s ?? '');
const HELP = liftAll('help.js', ['machineStarted', 'machineHold', 'machineAtWork', 'waveHold']);
globalThis.VmfHelp = { VmfRun: { link: (p) => `${p}?run=run-1` }, machineStarted: HELP.machineStarted, machineAtWork: HELP.machineAtWork, waveHold: HELP.waveHold, idKey: (id) => String(id == null ? '' : id).toLowerCase() };
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
const page = liftAll('migrations.html', ['settledAll', 'wavesInFlight', 'nextWaveButton', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck', 'waveStartRequested', 'nextStepSaid', 'renderNextStep']);

// WAVE-RUNNING-PLANNED-1: nextWaveButton reads STORED states - a machine with
// no state document gives nothing, never a PLANNED stand-in.
const states = (s) => (id) => s[id];
const twoWaves = [
  { vmId: 'a', wave: 'w1', path: 'B' },
  { vmId: 'b', wave: 'w2', path: 'A' },
];
const nextFor = (entries, s) => {
  globalThis.planDoc = { entries };
  globalThis.allVms = Object.entries(s).map(([vmId, state]) => ({ vmId, state }));
  page.renderNextStep([]);
  return nextEl.innerHTML;
};

test('the label names the waves the editor can still change, and is not the planning label', () => {
  ok(typeof U.arrangeNotRunning === 'string' && U.arrangeNotRunning.length > 0, 'a declared string');
  ok(U.arrangeNotRunning !== U.arrangeWaves, 'another label from the planned case');
  ok(/not running/i.test(U.arrangeNotRunning), U.arrangeNotRunning);
});

test('a wave runs and another has not started: the button says it changes the waves that are not running', () => {
  for (const state of ['PRECHECK', 'SAFETY_PRISTINE', 'CONVERTING', 'VALIDATING']) {
    const html = nextFor(twoWaves, { a: state });
    ok(html.includes(U.nextRunning), `${state}: the running text`);
    ok(html.includes(U.arrangeNotRunning), `${state}: the running label: ${html}`);
    ok(!html.includes(U.arrangeWaves), `${state}: not "Arrange the waves"`);
    ok(html.includes('href="waves.html?run=run-1"'), `${state}: it still opens the wave editor`);
  }
});

test('a wave runs and the only other wave has finished: the editor locks its settled machines, so no button', () => {
  for (const settled of ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION']) {
    eq(page.nextWaveButton(twoWaves, states({ a: 'CONVERTING', b: settled })), null, settled);
  }
});

test('a wave runs and another wave holds a machine that has not started: the button shows', () => {
  const three = [...twoWaves, { vmId: 'c', wave: 'w2', path: 'A' }];
  eq(page.nextWaveButton(three, states({ a: 'CONVERTING', b: 'MIGRATED' })), U.arrangeNotRunning, 'c has not started');
  // WAVE-RUNNING-PLANNED-1: a state document at PLANNED is a machine a worker
  // took, so its wave runs, and every machine is in a running wave.
  eq(page.nextWaveButton(three, states({ a: 'CONVERTING', b: 'MIGRATED', c: 'PLANNED' })), null, 'c taken at PLANNED');
});

test('the started states are the editor\'s own: one rule in help.js, which the editor reads', () => {
  const editor = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
  ok(/const started = \(vmId\) => VmfHelp\.machineStarted\(states\.get\(vmId\)\);/.test(editor), 'the editor asks help.js');
  ok(!/STARTED_STATES/.test(editor), 'and keeps no list of its own');
  ok(/VmfHelp\.machineStarted\(storedStateOf\(e\.vmId\)\)/.test(PAGE), 'the Migrations page asks the same rule');
  for (const s of ['PRECHECK', 'CONVERTING', 'VALIDATING', 'MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION']) {
    eq(HELP.machineStarted(s), true, s);
  }
  for (const s of ['PLANNED', undefined, null, '']) { eq(HELP.machineStarted(s), false, String(s)); }
});

test('a wave runs and the plan holds unscheduled machines: they can go into a new wave, so the button shows', () => {
  const entries = [{ vmId: 'a', wave: 'w1', path: 'B' }, { vmId: 'm', wave: 'unscheduled', path: 'MANUAL' }];
  eq(page.nextWaveButton(entries, states({ a: 'CONVERTING' })), U.arrangeNotRunning, 'unscheduled');
  ok(nextFor(entries, { a: 'CONVERTING' }).includes(U.arrangeNotRunning), 'rendered');
});

test('every machine of the plan is in a running wave: the editor can change nothing, so no button', () => {
  // (a machine that has started anywhere is locked too - see above)
  const one = [{ vmId: 'a', wave: 'w1', path: 'B' }, { vmId: 'c', wave: 'w1', path: 'A' }];
  eq(page.nextWaveButton(one, states({ a: 'CONVERTING' })), null, 'one running wave');
  const html = nextFor(one, { a: 'CONVERTING' });
  ok(html.includes(U.nextRunning), 'the running text stays');
  ok(!html.includes(U.arrangeNotRunning) && !html.includes(U.arrangeWaves) && !html.includes('waves.html'), html);
  // Two waves, both running.
  eq(page.nextWaveButton(twoWaves, states({ a: 'CONVERTING', b: 'PRECHECK' })), null, 'two running waves');
});

test('a machine waiting for a slot in the running wave does not make that wave changeable', () => {
  const one = [{ vmId: 'a', wave: 'w1', path: 'B' }, { vmId: 'c', wave: 'w1', path: 'A' }];
  eq(page.nextWaveButton(one, states({ a: 'CONVERTING' })), null, 'c has no state document');
});

test('no wave runs: the planning label, as before', () => {
  eq(page.nextWaveButton(twoWaves, states({})), U.arrangeWaves, 'nothing started');
  eq(page.nextWaveButton(twoWaves, states({ a: 'MIGRATED' })), U.arrangeWaves, 'between waves');
  eq(page.nextWaveButton(twoWaves, states({ a: 'NEEDS_DECISION' })), U.arrangeWaves, 'a parked machine is not a running wave');
  ok(nextFor(twoWaves, {}).includes(U.arrangeWaves), 'rendered');
});

test('every wave has run: no button', () => {
  eq(page.nextWaveButton(twoWaves, states({ a: 'MIGRATED', b: 'FAILED_ROLLED_BACK' })), null, 'all ran');
  ok(!nextFor(twoWaves, { a: 'MIGRATED', b: 'SKIPPED' }).includes('waves.html'), 'rendered');
});

test('a person who cannot operate sees no button in any case', () => {
  globalThis.canOperate = () => false;
  try { eq(nextFor(twoWaves, { a: 'CONVERTING' }), '', 'no card'); }
  finally { globalThis.canOperate = () => true; }
});

test('the label is true of the editor: it closes a running wave and started machines, and the engine refuses only a running wave', () => {
  const editor = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
  ok(/const running = waveMigrating\(name\);\s*const editable = canEdit && !running;/.test(editor), 'the editor closes a wave by its own running test');
  ok(/\(canEdit && !isStarted && !waveMigrating\(e\.wave\)\) \? 'draggable="true"'/.test(editor), 'a machine moves only when it has not started and its wave does not run');
  const save = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Public', 'Set-VmfWavePlan.ps1'), 'utf8');
  ok(/foreach \(\$touched in @\(\$touchedWaves\)\)[\s\S]{0,200}Get-VmfWaveRunningDetail -RunPath \$RunPath -Wave \$touched/.test(save),
    'the save asks each wave it touches, not the whole plan');
});

run('waves-button-running');
