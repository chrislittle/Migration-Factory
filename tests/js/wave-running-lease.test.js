/* WAVE-RUNNING-LEASE-1, filed by the build of WAVE-RUNNING-PLANNED-1:
 *
 *   - the engine (Get-VmfWaveRunningDetail) counts a wave as running when a
 *     machine of it has a LEASE, or a state that is not final;
 *   - the pages (VmfHelp.machineAtWork) read no lease. A worker that took a
 *     lease and had not yet written PLANNED, or a lease a stopped worker left
 *     on a finished machine, made the Migrations page and the wave editor
 *     offer the wave's controls while the engine refused each edit.
 *
 * One rule now, in two languages: VmfHelp.machineHold here and
 * Get-VmfMachineHold in the engine, both held to
 * tests/fixtures/machine-hold.json (tests/unit/WaveRunningLease.Tests.ps1).
 * Its answer endedHold - a stopped worker's hold on a finished machine - is
 * the hold the service's timer removes, and the pages say so.
 * Both pages read the leases in ONE call (PAGE-LOAD-1, storeDocs). RUN, not read.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const HELP_SRC = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const LEASE_PS = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'state', 'MachineLease.ps1'), 'utf8');
const STATE_PS = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'engine', 'StateMachine.ps1'), 'utf8');
const FIXTURE = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'machine-hold.json'), 'utf8'));

globalThis.LEASE_LIMIT_SECONDS = Number((HELP_SRC.match(/const LEASE_LIMIT_SECONDS = (\d+);/) || [])[1]);
const idKey = (id) => String(id == null ? '' : id).toLowerCase();
globalThis.idKey = idKey;
const H = liftAll('help.js', ['machineHold', 'machineAtWork', 'waveHold', 'leasesByMachine']);

const NOW = Date.parse('2026-11-07T12:00:00Z');
const leaseOf = (c) => {
  if (!c.lease) { return null; }
  const l = { vmId: '/s/rg/vm/a', workerId: c.lease.workerId };
  if ('heartbeatAgeSeconds' in c.lease) { l.heartbeatUtc = new Date(NOW - c.lease.heartbeatAgeSeconds * 1000).toISOString(); }
  else if ('heartbeatUtc' in c.lease) { l.heartbeatUtc = c.lease.heartbeatUtc; }
  return l;
};

/* ---- the rule ---- */

test('the lease limit is the engine\'s ($script:VmfMachineLeaseTimeoutSeconds)', () => {
  const engine = Number((LEASE_PS.match(/\$script:VmfMachineLeaseTimeoutSeconds = (\d+)/) || [])[1]);
  ok(engine > 0, 'the engine names its limit');
  eq(globalThis.LEASE_LIMIT_SECONDS, engine, 'help.js has the same limit');
});

test('the final states are the engine\'s ($script:VmfTerminalStates)', () => {
  const m = STATE_PS.match(/\$script:VmfTerminalStates = @\(([^)]*)\)/);
  ok(m, 'the engine names its final states');
  const engine = m[1].split(',').map(s => s.trim().replace(/'/g, ''));
  for (const s of engine) { eq(H.machineHold(s, null, NOW), 'none', `${s} with no lease`); }
  for (const s of ['PLANNED', 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING']) {
    ok(!engine.includes(s), s);
    eq(H.machineHold(s, null, NOW), 'working', s);
  }
});

test('the fixture holds the cases the pages read wrongly, and every answer', () => {
  const names = FIXTURE.cases.map(c => c.name);
  ok(names.includes('no state document and a live worker lease'), 'a lease and no state document');
  ok(names.includes('MIGRATED and an old worker lease'), 'a stopped worker\'s hold');
  eq([...new Set(FIXTURE.cases.map(c => c.hold))].sort(), ['endedHold', 'none', 'working']);
});

for (const c of FIXTURE.cases) {
  test(`the rule (help.js): ${c.name} -> ${c.hold}`, () => {
    eq(H.machineHold(c.state ?? undefined, leaseOf(c), NOW), c.hold);
    eq(H.machineAtWork(c.state ?? undefined, leaseOf(c), NOW), c.hold !== 'none', 'machineAtWork');
  });
}

test('a heartbeat the engine wrote with seven figures after the second reads as a time', () => {
  const lease = { workerId: 'w1-worker-0', heartbeatUtc: '2026-11-07T11:00:00.1234567Z' };
  eq(H.machineHold('MIGRATED', lease, NOW), 'endedHold');
});

test('machineAtWork with a state only reads as before', () => {
  eq(H.machineAtWork('PLANNED'), true);
  eq(H.machineAtWork(undefined), false);
  eq(H.machineAtWork('MIGRATED'), false);
});

test('waveHold: a machine at work outranks a stopped worker\'s hold', () => {
  const entries = [{ vmId: 'a' }, { vmId: 'b' }];
  const old = { workerId: 'w1-worker-0', heartbeatUtc: new Date(NOW - 3600000).toISOString() };
  const st = (m) => (id) => m[id];
  const ls = (m) => (id) => m[id];
  eq(H.waveHold(entries, st({ a: 'MIGRATED', b: 'CONVERTING' }), ls({ a: old }), NOW), 'working');
  eq(H.waveHold(entries, st({ a: 'MIGRATED', b: 'MIGRATED' }), ls({ a: old }), NOW), 'endedHold');
  eq(H.waveHold(entries, st({ a: 'MIGRATED', b: 'MIGRATED' }), ls({}), NOW), 'none');
  eq(H.waveHold(entries, st({}), ls({ b: { workerId: 'w1-worker-0', heartbeatUtc: new Date(NOW).toISOString() } }), NOW), 'working');
});

test('leasesByMachine keys each lease by the ID inside it, in any letter case', () => {
  const m = H.leasesByMachine([{ vmId: '/S/RG/vm/A', workerId: 'x' }, null, { workerId: 'no id' }, { vmId: 'group-avset/set', workerId: 'y' }]);
  eq(m.get('/s/rg/vm/a').workerId, 'x');
  eq(m.size, 2, 'a lease with no ID is left out');
});

/* ---- the Migrations page ---- */

const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
const U = globalThis.UX_ACT, M = globalThis.UX_MISC;
globalThis.esc = (s) => String(s ?? '');
globalThis.VmfHelp = { VmfRun: { link: (p) => `${p}?run=run-1` }, machineStarted: liftAll('help.js', ['machineStarted']).machineStarted,
  machineAtWork: H.machineAtWork, machineHold: H.machineHold, waveHold: H.waveHold, leasesByMachine: H.leasesByMachine, idKey };
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
const page = liftAll('migrations.html', ['settledAll', 'wavesInFlight', 'nextWaveButton', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck',
  'waveStartRequested', 'nextStepSaid', 'renderNextStep', 'storedStateOf', 'leaseOf', 'waveRunningSaid']);

const fresh = () => ({ vmId: 'a', workerId: 'w1-worker-0', heartbeatUtc: new Date().toISOString() });
const stopped = () => ({ vmId: 'a', workerId: 'w1-worker-0', heartbeatUtc: new Date(Date.now() - 3600000).toISOString() });
const twoWaves = [{ vmId: 'a', wave: 'w1', path: 'B' }, { vmId: 'b', wave: 'w2', path: 'A' }];
const setRun = (states, leases) => {
  globalThis.allVms = Object.entries(states).map(([vmId, state]) => ({ vmId, state }));
  globalThis.latestLeases = H.leasesByMachine(leases);
};
const nextFor = (entries, states, leases) => {
  globalThis.planDoc = { entries };
  setRun(states, leases);
  page.renderNextStep([]);
  return nextEl.innerHTML;
};

test('THE DEFECT, Migrations: a wave whose only machine has a lease and no state document is running', () => {
  setRun({}, [fresh()]);
  eq(page.wavesInFlight([twoWaves[0]], page.storedStateOf), true, 'the lease counts');
  setRun({}, []);
  eq(page.wavesInFlight([twoWaves[0]], page.storedStateOf), false, 'no lease, no state document');
});

test('Migrations: leaseOf finds a lease by the machine ID in any letter case', () => {
  setRun({}, [{ vmId: '/S/RG/VM/A', workerId: 'w' }]);
  eq(page.leaseOf('/s/rg/vm/a').workerId, 'w');
  eq(page.leaseOf('/s/rg/vm/b'), undefined);
});

test('Migrations: "What happens next" says the wave runs while a worker holds its machine', () => {
  const html = nextFor(twoWaves, {}, [fresh()]);
  ok(html.includes(U.nextRunning), html);
  ok(html.includes(U.arrangeNotRunning), 'the editor button names the waves that are not running');
  ok(!html.includes(U.nextPlanned), 'not "approve and start the first one"');
});

test('Migrations: a stopped worker\'s hold on a finished machine is said as that, not as a running wave', () => {
  const html = nextFor([twoWaves[0]], { a: 'MIGRATED' }, [stopped()]);
  ok(html.includes(U.nextEndedHold), html);
  ok(!html.includes(U.nextRunning), 'not "a wave is running now"');
  ok(!html.includes(U.nextAllRan), 'not "every wave has run" while the engine still refuses an edit');
});

test('Migrations: a machine sent back to Checking that a worker holds does not only wait for the service', () => {
  const since = '2026-11-07T11:00:00Z';
  const doc = { vmId: 'a', state: 'PRECHECK', history: [{ state: 'PRECHECK', tsUtc: since }] };
  const events = [{ vmId: 'a', step: 'decision', outcome: 'ok', returnTo: 'PRECHECK', tsUtc: '2026-11-07T11:00:01Z' }];
  const docOf = () => doc;
  eq(page.waitingOnlyForCheck([twoWaves[0]], docOf, events, () => undefined), true, 'no lease: it waits for the next check');
  eq(page.waitingOnlyForCheck([twoWaves[0]], docOf, events, () => fresh()), false, 'a worker holds it: it is at work');
});

test('Migrations: the wave card says why the wave cannot start', () => {
  const docOf = (id) => globalThis.allVms.find(v => v.vmId === id);
  setRun({ a: 'MIGRATED' }, [stopped()]);
  eq(page.waveRunningSaid([twoWaves[0]], page.storedStateOf, docOf, []), M.endedHold, 'a stopped worker\'s hold');
  setRun({}, [fresh()]);
  eq(page.waveRunningSaid([twoWaves[0]], page.storedStateOf, docOf, []), U.startAlreadyRunning, 'a worker holds it');
  setRun({ a: 'CONVERTING' }, []);
  eq(page.waveRunningSaid([twoWaves[0]], page.storedStateOf, docOf, []), U.startAlreadyRunning, 'a machine at work');
  ok(/const startBlockedBy = waveWorking\s*\?\s*waveRunningSaid\(info\.entries, storedStateOf,/.test(PAGE), 'the wave card asks it');
});

test('Migrations: the open run\'s ONE call reads the leases, with at most 12 names', () => {
  const reads = eval(PAGE.match(/const RUN_READS = (\[[^\]]+\]);/)[1]); // eslint-disable-line no-eval
  ok(reads.includes('leases/*.lease'), 'the leases');
  ok(reads.length <= 12, 'the service takes at most 12 names');
  const runRead = PAGE.slice(PAGE.indexOf('async function refreshRun('));
  ok(/folder\('leases'\)/.test(runRead), 'the leases folder from the same call');
  ok(/latestLeases = VmfHelp\.leasesByMachine\(/.test(runRead), 'kept for the rules');
});

/* ---- the wave editor ---- */

/* Review of WAVE-RUNNING-LEASE-1: a leases LISTING that fails is not known,
 * never "no leases". Taken as empty, the page said a held wave was free and
 * offered its controls - the defect, in its failure mode. The refresh fails
 * and says so, and draws nothing from that read; the wave editor does the
 * same (readLeases below). */
/* Run the Migrations page's refresh against a stand-in store, and say what it
 * drew and what its error line holds. */
async function refreshWith(fakeSrc) {
  const { lift } = require('./_harness');
  const refreshRun = lift('migrations.html', 'refreshRun');
  const drawn = [];
  const el = () => ({ textContent: '', className: '', title: '', style: { display: 'none' } });
  const els = { '#err': el(), '#live-ind': el() };
  const saved = { $: globalThis.$, VmfHelp: globalThis.VmfHelp };
  Object.assign(globalThis, {
    $: (s) => els[s] ?? null, runRegions: () => [], currentRun: 'p/mig-1', showingRun: 'p/mig-1', source: fakeSrc, DEMO_MODE: false,
    planDoc: null, runAck: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null, lastAssessment: null,
    schedules: new Map(), acceptances: new Map(), approvals: new Map(), allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false,
    discardInFlight: new Map(), latestEvents: [], restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    runListed: () => null, showReadingRun() {}, clearReadingRun() {},
    nameMachines() {}, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis: () => drawn.push('kpis'), renderNextStep: () => drawn.push('next'), renderFound: () => drawn.push('found'),
    renderWaves: () => drawn.push('waves'), refreshDrill: () => drawn.push('drill'), renderCapacity: () => drawn.push('cap'),
    renderSafetyCopies: () => drawn.push('copies'), renderEvents: () => drawn.push('events'), ago: () => 'now',
    VmfHelp: { ...require('./_held').perFileHelp(), storeHolds: () => true, drawWhenFree: (r, draw) => { draw(); return true; },
      mapLimited: async (xs, f) => Promise.all(xs.map(f)), explain: (e) => String(e.message) },
  });
  try {
    await refreshRun({ status: async () => null, plan: async () => ({ pv: null, doc: null }), run: async () => null });
    return { drawn, err: els['#err'], leases: globalThis.latestLeases };
  } finally { Object.assign(globalThis, saved); }
}

test('Migrations: a leases listing that fails draws no wave as free, and the page says it could not read the holds', async () => {
  const got = await refreshWith({
    listRun: async () => null, readLines: async () => [], readJson: async () => null, readRoot: async () => null,
    listFolder: async (run, name) => { if (name === 'leases') { throw new Error('HTTP 503'); } return []; },
  });
  eq(got.drawn, [], 'no wave is drawn from a read that does not know the holds');
  eq(got.err.style.display, 'block', 'the page says it');
  ok(got.err.textContent.includes(M.leasesUnread.replace('{reason}', 'HTTP 503')), got.err.textContent);
});

/* LEASE-UNREAD-PAGE-1: a lease the listing names and the store REFUSES to
 * read (an error, not "not found") is not "no lease". The machine ID is
 * inside the lease, so the page cannot say which machine it holds: it can
 * judge no wave, and the refresh fails with the words of a failed listing. */
const leaseListed = (readLease) => ({
  listRun: async () => null, readLines: async () => [], readRoot: async () => null,
  readJson: async (run, rel) => (rel === 'leases/a.lease' ? readLease() : null),
  listFolder: async (run, name) => (name === 'leases' ? ['leases/a.lease'] : []),
});

test('THE DEFECT, Migrations: a listed lease the store refuses to read draws no wave as free', async () => {
  const got = await refreshWith(leaseListed(async () => { throw new Error('HTTP 500'); }));
  eq(got.drawn, [], 'no wave is drawn from a read that does not know the holds');
  eq(got.err.style.display, 'block', 'the page says it');
  ok(got.err.textContent.includes(M.leasesUnread.replace('{reason}', 'HTTP 500')), got.err.textContent);
});

test('Migrations: a listed lease that is not there now (its job removed it) is no lease, and the page draws', async () => {
  // VmfHelp.storeBlob reads a 404 as null: the lease is gone.
  const got = await refreshWith(leaseListed(async () => null));
  eq(got.err.style.display, 'none', got.err.textContent);
  ok(got.drawn.includes('waves'), 'the waves are drawn');
  eq(got.leases.size, 0, 'no lease');
});

test('Migrations: a listed lease that reads is kept for its machine', async () => {
  const got = await refreshWith(leaseListed(async () => fresh()));
  eq(got.err.style.display, 'none', got.err.textContent);
  eq(got.leases.get('a').workerId, 'w1-worker-0');
});

const EDITOR = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
const WUX = liftConst('waves.html', 'UX');

test('wave editor: a leases listing that fails stops the page with the same words, never "no leases"', async () => {
  const realHelp = liftAll('help.js', ['heldDepth', 'heldList', 'heldText', 'heldJson']);
  globalThis.UX = WUX;
  globalThis.runPrefix = () => 'proj/run-1';
  globalThis.cfg = { apiUrl: 'https://svc.example.com' };
  globalThis.getToken = async () => 't';
  globalThis.blobList = async () => { throw new Error('HTTP 503'); };
  globalThis.blobFetch = async () => null;
  const saved = globalThis.VmfHelp;
  globalThis.VmfHelp = Object.assign({}, saved, realHelp, {
    mapLimited: async (xs, fn) => Promise.all(xs.map(fn)), explain: (e) => String(e.message),
    storeDocs: async () => { throw new Error('down'); },
  });
  try {
    const { readLeases } = liftAll('waves.html', ['readLeases']);
    let thrown = null;
    try { await readLeases(); } catch (e) { thrown = e; }
    ok(thrown, 'the page does not go on with no leases');
    eq(thrown && thrown.message, WUX.leasesUnread.replace('{reason}', 'HTTP 503'));
    eq(WUX.leasesUnread, M.leasesUnread, 'one sentence on both pages');
  } finally { globalThis.VmfHelp = saved; }
});

test('THE DEFECT, wave editor: a lease alone makes its wave running', () => {
  globalThis.entries = [{ vmId: 'a', wave: 'w1' }, { vmId: 'b', wave: 'w2' }];
  globalThis.states = new Map();
  globalThis.leases = H.leasesByMachine([fresh()]);
  const { waveMigrating, waveHoldOf } = liftAll('waves.html', ['waveMigrating', 'waveHoldOf']);
  eq(waveMigrating('w1'), true, 'a worker holds a');
  eq(waveMigrating('w2'), false, 'nothing holds b');
  globalThis.states = new Map([['a', 'MIGRATED']]);
  globalThis.leases = H.leasesByMachine([stopped()]);
  eq(waveMigrating('w1'), true, 'a stopped worker\'s hold still locks the wave, as the engine does');
  eq(waveHoldOf('w1'), 'endedHold');
});

test('wave editor: a wave held only by a stopped worker shows Held and says the service removes the hold', () => {
  const card = EDITOR.slice(EDITOR.indexOf('function render('));
  ok(/waveHoldOf\(name\) === 'endedHold' \? UX\.endedHoldTip : UX\.runningTip/.test(card), 'the tip');
  ok(/waveHoldOf\(name\) === 'endedHold' \? UX\.endedHoldTag : UX\.runningTag/.test(card), 'the tag');
  ok(WUX.endedHoldTag && WUX.endedHoldTip && WUX.endedHoldMove, 'the words are declared');
});

test('wave editor: moving a machine into a held wave says the service removes the hold', () => {
  const bar = { textContent: '', style: { display: 'none' } };
  const moved = { textContent: '', style: { display: 'none' } };
  globalThis.UX = WUX;
  globalThis.$ = (s) => (s === '#warnbar' ? bar : s === '#moved' ? moved : null);
  globalThis.entries = [{ vmId: 'a', wave: 'w1' }, { vmId: 'c', wave: 'w2' }];
  globalThis.states = new Map([['a', 'MIGRATED']]);
  globalThis.leases = H.leasesByMachine([stopped()]);
  globalThis.layout = new Map([['w1', { vmIds: ['a'] }], ['w2', { vmIds: ['c'] }]]);
  const { moveTo } = liftAll('waves.html', ['moveTo', 'waveMigrating', 'waveHoldOf']);
  moveTo('w1', ['c']);
  eq(bar.textContent, WUX.endedHoldMove.replace('{wave}', 'w1'));
  globalThis.$ = (sel) => (sel === '#nextstep' ? nextEl : null);
});

test('wave editor: the page reads the leases with the machines, and keeps them for the rule', () => {
  // PAGE-LOAD-3: beside the machines, from the migration's one call (readMigration).
  ok(/await Promise\.all\(\[readPlan\(\), stateRead,[^\]]*runHeld\.then\(held => readLeases\(held\)\)\]\);/.test(EDITOR), 'read beside the machines');
  ok(/\(\{ plan, stateDocs, assessment, leases \} = got\);/.test(EDITOR), 'into leases');
});

test('wave editor: the leases come from ONE call, and each from that call when it holds it', async () => {
  const calls = [];
  const prefix = 'proj/run-1/leases/';
  const held = {
    prefix, depth: 1, truncated: false, complete: true, folders: [],
    names: new Set([`${prefix}a.lease`]),
    docs: new Map([[`${prefix}a.lease`, { path: `${prefix}a.lease`, text: JSON.stringify(fresh()) }]]),
  };
  const realHelp = liftAll('help.js', ['heldDepth', 'heldList', 'heldText', 'heldJson']);
  globalThis.cfg = { apiUrl: 'https://svc.example.com' };
  globalThis.runPrefix = () => 'proj/run-1';
  globalThis.getToken = async () => 't';
  globalThis.blobList = async (p) => { calls.push(['list', p]); return []; };
  globalThis.blobFetch = async (p) => { calls.push(['fetch', p]); return null; };
  globalThis.VmfHelp = Object.assign({}, globalThis.VmfHelp, realHelp, {
    mapLimited: async (xs, fn) => Promise.all(xs.map(fn)),
    storeDocs: async (gt, url, opts) => { calls.push(['docs', opts.prefix, opts.depth, opts.read]); return held; },
  });
  const { readLeases } = liftAll('waves.html', ['readLeases']);
  const got = await readLeases();
  eq(calls, [['docs', prefix, 1, ['*.lease']]], 'one call, nothing else');
  eq(got.get('a').workerId, 'w1-worker-0');
  // The call failed: the leases are read as before - a listing and each lease.
  calls.length = 0;
  globalThis.VmfHelp.storeDocs = async () => { throw new Error('down'); };
  globalThis.blobList = async (p) => { calls.push(['list', p]); return [`${prefix}a.lease`, `${prefix}notes.txt`]; };
  globalThis.blobFetch = async (p) => { calls.push(['fetch', p]); return fresh(); };
  const again = await readLeases();
  eq(calls, [['list', prefix], ['fetch', `${prefix}a.lease`]], 'the listing and the lease');
  eq(again.get('a').workerId, 'w1-worker-0');
});

/* LEASE-UNREAD-PAGE-1: the wave editor reads each listed lease itself when
 * the one call cannot say. A read the store refuses stops the page with the
 * words of a failed listing; a lease that is not there now is no lease. */
async function editorLeaseRead(fetchLease) {
  const prefix = 'proj/run-1/leases/';
  const realHelp = liftAll('help.js', ['heldDepth', 'heldList', 'heldText', 'heldJson']);
  globalThis.UX = WUX;
  globalThis.cfg = { apiUrl: 'https://svc.example.com' };
  globalThis.runPrefix = () => 'proj/run-1';
  globalThis.getToken = async () => 't';
  globalThis.blobList = async () => [`${prefix}a.lease`];
  globalThis.blobFetch = async () => fetchLease();
  const saved = globalThis.VmfHelp;
  globalThis.VmfHelp = Object.assign({}, saved, realHelp, {
    mapLimited: async (xs, fn) => Promise.all(xs.map(fn)), explain: (e) => String(e.message),
    storeDocs: async () => { throw new Error('down'); },
  });
  try {
    const { readLeases } = liftAll('waves.html', ['readLeases']);
    try { return { leases: await readLeases(), thrown: null }; } catch (e) { return { leases: null, thrown: e }; }
  } finally { globalThis.VmfHelp = saved; }
}

test('THE DEFECT, wave editor: a listed lease the store refuses to read stops the page, never "no lease"', async () => {
  const got = await editorLeaseRead(async () => { throw new Error('HTTP 403'); });
  ok(got.thrown, 'the page does not go on as if no worker held the machine');
  eq(got.thrown && got.thrown.message, WUX.leasesUnread.replace('{reason}', 'HTTP 403'));
});

test('wave editor: a listed lease that is not there now is no lease', async () => {
  const got = await editorLeaseRead(async () => null);
  eq(got.thrown, null, String(got.thrown && got.thrown.message));
  eq(got.leases.size, 0);
});

test('a lease that is not there is null, and a refused read throws (VmfHelp.storeBlob)', async () => {
  const { storeBlob } = liftAll('help.js', ['storeBlob', 'storeUrl', 'storeError']);
  const savedFetch = globalThis.fetch;
  try {
    globalThis.fetch = async () => ({ status: 404, ok: false, headers: { get: () => null }, text: async () => '', json: async () => ({}) });
    eq(await storeBlob(async () => 't', 'https://svc.example.com', 'a.lease'), null, '404 is not there');
    globalThis.fetch = async () => ({ status: 403, ok: false, headers: { get: () => null }, text: async () => '{"error":"refused"}', json: async () => ({ error: 'refused' }) });
    let thrown = null;
    try { await storeBlob(async () => 't', 'https://svc.example.com', 'a.lease'); } catch (e) { thrown = e; }
    ok(thrown, '403 throws');
  } finally { globalThis.fetch = savedFetch; }
});

run('wave-running-lease');
