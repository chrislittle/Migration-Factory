/* WAVE-RUNNING-PLANNED-1, found by the build of WAVES-BUTTON-RUNNING-1,
 * 2026-10-25, by reading the three running rules side by side:
 *
 *   - the engine (Get-VmfWaveRunningDetail) and the wave editor (waveMigrating)
 *     count a wave as running when a machine of it has a state document in a
 *     state that is not final - PLANNED included, because a worker writes
 *     PLANNED when it TAKES the machine (WAVE-MIX-2).
 *   - the Migrations page (wavesInFlight) left PLANNED out. So for the time
 *     between a worker taking a machine and PRECHECK, the wave card and "What
 *     happens next" said the wave was not running, and offered the next step.
 *
 * One rule now, in help.js (VmfHelp.machineAtWork), which both pages ask.
 * A machine that only waits for a slot has NO state document, and that is
 * what tells it from a taken one. RUN, not read.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');


const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const EDITOR = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
const ENGINE = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'capacity', 'CapacityClaim.ps1'), 'utf8');
const STATE_PS = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'engine', 'StateMachine.ps1'), 'utf8');

const HELP = liftAll('help.js', ['machineStarted', 'machineHold', 'machineAtWork', 'waveHold']);
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const U = globalThis.UX_ACT;
globalThis.esc = (s) => String(s ?? '');
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
const page = liftAll('migrations.html', ['settledAll', 'wavesInFlight', 'nextWaveButton', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck', 'waveStartRequested', 'nextStepSaid', 'renderNextStep', 'storedStateOf']);

// A machine's state document's state, or nothing when it has none.
const stored = (s) => (id) => s[id];
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

test('help.js: a stored PLANNED reads as at work, and no state document reads as not at work', () => {
  eq(HELP.machineAtWork('PLANNED'), true, 'taken by a worker');
  for (const s of [undefined, null, '']) { eq(HELP.machineAtWork(s), false, `no state document: ${String(s)}`); }
  for (const s of ['PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING']) {
    eq(HELP.machineAtWork(s), true, s);
  }
  for (const s of ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION']) {
    eq(HELP.machineAtWork(s), false, s);
  }
});

test('help.js keeps the engine\'s own list of final states (Get-VmfWaveRunningDetail)', () => {
  // WAVE-RUNNING-LEASE-1: Get-VmfWaveRunningDetail asks Get-VmfMachineHold,
  // which reads the engine's final states, $script:VmfTerminalStates.
  const fn = ENGINE.slice(ENGINE.indexOf('function Get-VmfWaveRunningDetail'));
  ok(/Get-VmfMachineHold -State \$state -Lease \$lease/.test(fn), 'the engine asks the one rule');
  const m = STATE_PS.match(/\$script:VmfTerminalStates = @\(([^)]*)\)/);
  ok(m, 'the engine names its final states');
  const engine = m[1].split(',').map(s => s.trim().replace(/'/g, '')).sort();
  const settled = engine.filter(s => !HELP.machineAtWork(s));
  eq(settled, engine, 'every engine final state reads as not at work');
  // And nothing else does: every other state the engine writes is at work.
  for (const s of ['PLANNED', 'PRECHECK', 'CONVERTING', 'VALIDATING']) { ok(!engine.includes(s) && HELP.machineAtWork(s), s); }
});

test('wavesInFlight: a wave whose only machine a worker took at PLANNED is running', () => {
  eq(page.wavesInFlight([twoWaves[0]], stored({ a: 'PLANNED' })), true, 'a stored PLANNED');
});

test('wavesInFlight: a wave whose machine has no state document is not running', () => {
  eq(page.wavesInFlight([twoWaves[0]], stored({})), false, 'no state document');
  eq(page.wavesInFlight([twoWaves[0]], stored({ a: 'MIGRATED' })), false, 'finished');
});

test('"What happens next" says the wave runs while its machine is taken at PLANNED', () => {
  const html = nextFor(twoWaves, { a: 'PLANNED' });
  ok(html.includes(U.nextRunning), html);
  ok(!html.includes(U.nextPlanned), 'not "approve and start the first one"');
  ok(html.includes(U.arrangeNotRunning), 'the editor button names the waves that are not running');
  ok(!html.includes(U.arrangeWaves), 'not "Arrange the waves"');
});

test('"What happens next" still says to start the first wave when no machine has a state document', () => {
  const html = nextFor(twoWaves, {});
  ok(html.includes(U.nextPlanned) && html.includes(U.arrangeWaves), html);
});

test('nextWaveButton reads stored states: a taken machine makes its wave running', () => {
  eq(page.nextWaveButton(twoWaves, stored({ a: 'PLANNED' })), U.arrangeNotRunning, 'w1 runs, w2 has not started');
  eq(page.nextWaveButton(twoWaves, stored({ a: 'PLANNED', b: 'PLANNED' })), null, 'both waves run');
  eq(page.nextWaveButton(twoWaves, stored({})), U.arrangeWaves, 'nothing taken');
});

test('the wave card asks the same rule, with the stored state and not the PLANNED stand-in', () => {
  ok(/const waveWorking = wavesInFlight\(info\.entries, storedStateOf\);/.test(PAGE), 'the wave card passes storedStateOf');
  globalThis.allVms = [{ vmId: 'a', state: 'PLANNED' }];
  eq(page.storedStateOf('a'), 'PLANNED', 'a state document');
  eq(page.storedStateOf('b'), undefined, 'no state document reads as nothing');
});

test('the wave editor asks help.js too, and keeps no list of final states of its own', () => {
  const body = EDITOR.slice(EDITOR.indexOf('function waveMigrating('), EDITOR.indexOf('function changePanel('));
  // WAVE-RUNNING-LEASE-1: through VmfHelp.waveHold, which asks machineHold - the rule machineAtWork asks.
  ok(/VmfHelp\.waveHold\(entries\.filter\(x => x\.wave === wave\), \(id\) => states\.get\(id\)/.test(body), 'waveMigrating asks help.js');
  ok(!/'MIGRATED'/.test(body), 'no list of its own');
  // Run it, on the editor's own globals.
  globalThis.entries = [{ vmId: 'a', wave: 'w1' }, { vmId: 'b', wave: 'w2' }];
  globalThis.states = new Map([['a', 'PLANNED']]);
  globalThis.leases = new Map();
  const { waveMigrating } = liftAll('waves.html', ['waveMigrating', 'waveHoldOf']);
  eq(waveMigrating('w1'), true, 'a taken machine');
  eq(waveMigrating('w2'), false, 'no state document');
});

run('wave-running-planned');
