/* PERF-MIGRATIONS-TICK-1, 2026-11-02. The Migrations list and the Reports
 * page stop reading documents they do not need.
 *
 * WHAT WAS MEASURED (PERF-ANALYSIS-1, "Measured", section 5). The Migrations
 * page read run.json, run-status.json and plan.json of EVERY run on load and
 * again on every refresh (15 s): 1 + P + 3R calls a tick. An assessment never
 * has run-status.json or plan.json, so 2A of those reads answered 404 on every
 * tick - and run.json, read beside them, said the run was an assessment. The
 * whole plan of every migration was read to count its machines, which the
 * summary in run-status.json already holds. The open run's status and plan
 * were read twice a tick, once by the list and once by the run. Reports read
 * the same three documents per run with no kind check, and showed each
 * assessment as a migration that never got past setup.
 *
 * THE RULES HELD HERE, each by counting the reads a fake store answers:
 *   - a run's kind is kept for the life of the page: run.json is read once,
 *     and an assessment gets no read of run-status.json or plan.json once
 *     the page knows its kind;
 *   - a manifest the page could not read is asked for again (unknown means ask);
 *   - plan.json is read for a migration only when its status has no summary
 *     that counts a machine;
 *   - the open run's status and plan are read once a tick;
 *   - the first load keeps its three reads per run together (PAGE-WAIT-1);
 *   - every row says what it said before;
 *   - Reports leaves an assessment out before it reads its status.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftAll, extract, test, eq, ok, run } = require('./_harness');
// PAGE-LOAD-2: the page's one calls fail here, so its reads go to the fake below.
const { perFileHelp, perFileGlobals } = require('./_held');

const fs = require('fs');
const path = require('path');
const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

/* ---- help.js, the page's shared rules, as they are ---------------------- */
const help = liftAll('help.js', ['runKind', 'runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup', 'mapLimited']);
const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.STORE_READ_LIMIT = 8;

/* ---- the page's own functions ------------------------------------------ */
const loadRuns = lift('migrations.html', 'loadRuns');
// MIGRATIONS-LIST-READS-1: refresh counts each load (asOneLoad) and runs refreshOnce.
const { refresh, refreshOnce, asOneLoad } = liftAll('migrations.html', ['refresh', 'refreshOnce', 'asOneLoad']);
Object.assign(globalThis, { refreshOnce, asOneLoad, loadsRunning: new Set(), listedRuns: null });
const refreshRun = lift('migrations.html', 'refreshRun');
// PERF-PROBES-1: refreshRun reads the files a listing of the run names
// (VmfHelp.storeHolds, from _held.js). The fake
// source here has no listing, which the page reads as not known, so every read
// is made as before - the counts below are about the status and the plan.
globalThis.runListed = lift('migrations.html', 'runListed');
globalThis.linkedRunId = lift('migrations.html', 'linkedRunId');
/* The reader that shares one tick's reads. Lifted on its own, so a page
 * without it fails the tests that need it rather than every test. */
let tickReads = null;
try { tickReads = lift('migrations.html', 'tickReads'); } catch { tickReads = null; }
// MIGRATIONS-LIST-READS-1: the list names its reads through listReads.
globalThis.listReads = lift('migrations.html', 'listReads');
/* A page without one is still run, so each rule fails on its own count. */
const reader = () => (tickReads ? tickReads() : undefined);

/* ---- a store, and a fake that counts every read ------------------------ */
const T = (min) => new Date(Date.parse('2026-11-02T12:00:00Z') - min * 60000).toISOString();
const summary = (machines, waitsFor, counts) => ({
  writtenUtc: T(30), reason: 'planSaved', halted: false, machines, stateCounts: counts, waitsOnPerson: 0,
  waves: [], next: { wave: machines ? 'w1' : null, waitsFor },
});
const entry = (id, p, wave) => ({ vmId: id, path: p, wave });

function store() {
  return {
    'p/assess-1': { 'run.json': { runId: 'assess-1', kind: 'assessment' } },
    'p/assess-2': { 'run.json': { runId: 'assess-2', kind: 'assessment' } },
    // A status whose summary counts the machines: the plan is not needed.
    'p/mig-sum': {
      'run.json': { runId: 'mig-sum', kind: 'migration' },
      'run-status.json': { schemaVersion: 7, runId: 'mig-sum', summary: summary(2, 'approval', { PLANNED: 2 }) },
      'plan.json': { entries: [entry('a', 'A', 'w1'), entry('b', 'B', 'w1')] },
    },
    // A status with no summary this page can read: the plan is read, and the
    // list cannot tell more (OLD-VERSION-READERS-REMOVE-6).
    'p/mig-old': {
      'run.json': { runId: 'mig-old', kind: 'migration' },
      'run-status.json': { schemaVersion: 7, runId: 'mig-old', updatedUtc: T(600), stateCounts: { MIGRATED: 2 } },
      'plan.json': { entries: [entry('c', 'A', 'w1'), entry('d', 'A', 'w1')] },
    },
    // A plan that moves no machine in a wave: the summary counts none, so it
    // cannot say whether the plan has entries. Planned, not set up.
    'p/mig-zero': {
      'run.json': { runId: 'mig-zero', kind: 'migration' },
      'run-status.json': { schemaVersion: 7, runId: 'mig-zero', summary: summary(0, 'none', {}) },
      'plan.json': { entries: [entry('e', 'MANUAL', 'unscheduled')] },
    },
    // Scanned, never planned.
    'p/setup': { 'run.json': { runId: 'setup', kind: 'migration' } },
  };
}

function fakeSource(docs, opts) {
  const o = opts || {};
  const log = [];
  const answer = (r, rel) => {
    if (o.fails && o.fails(r, rel)) { return Promise.reject(new Error(`read ${r}/${rel}: HTTP 500`)); }
    const d = docs[r] && docs[r][rel];
    return Promise.resolve(d === undefined ? null : JSON.parse(JSON.stringify(d)));
  };
  const gate = (r, rel, value) => (o.held ? new Promise(res => o.held.push(() => res(value))) : value);
  const src = {
    log,
    async listRuns() { log.push('list'); return Object.keys(docs); },
    readJson(r, rel) { log.push(`${r}|${rel}`); return gate(r, rel, answer(r, rel)); },
    readVersioned(r, rel) {
      log.push(`${r}|${rel}`);
      return gate(r, rel, answer(r, rel).then(d => (d === null ? null : { text: JSON.stringify(d), version: `v-${r}` })));
    },
    async readLines(r, rel) { log.push(`${r}|${rel}`); return []; },
    async listFolder(r, folder) { log.push(`${r}|${folder}/`); return []; },
    async readRoot(rel) { log.push(`|${rel}`); return null; },
  };
  return src;
}
const reads = (src, r, rel) => src.log.filter(x => x === `${r}|${rel}`).length;
const readsOf = (src, r) => src.log.filter(x => x.startsWith(`${r}|`));

/* The page around the two functions: what they read and write. */
function page(docs, opts) {
  const src = fakeSource(docs, opts);
  const err = { textContent: '', style: { display: 'none' } };
  const els = {
    '#run-panel': { classList: { contains: () => false } },
    '#err': err,
    '#live-ind': { className: '', title: '' },
  };
  Object.assign(globalThis, {
    source: src, DEMO_MODE: false, pendingRuns: new Set(), runKinds: new Map(), listedRuns: null,
    location: { search: '' }, localStorage: { getItem: () => null, setItem() { } },
    history: { replaceState() { } },
    runRows: [], currentRun: (opts && opts.current) || null, lastListError: null, showingRun: null,
    renderRunPanel() { }, showReadingRun() { }, clearReadingRun() { }, async renderFirstRun() { },
    nameMachines() { }, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis() { }, renderNextStep() { }, renderFound() { }, renderWaves() { }, refreshDrill() { },
    renderCapacity() { }, renderSafetyCopies() { }, renderEvents() { }, ago: () => 'a while ago',
    planDoc: null, runAck: null, runStop: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null,
    lastAssessment: null, schedules: new Map(), acceptances: new Map(), approvals: new Map(),
    allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false, discardInFlight: new Map(), latestEvents: [],
    restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    $: (sel) => els[sel] ?? null,
    loadRuns, refreshRun, tickReads, ...perFileGlobals(),
    // CLICKS-LOST-1: no control is held here, so the drawing runs at once.
    runRegions: () => [],
    VmfHelp: {
      ...perFileHelp(),
      drawWhenFree: (regions, draw) => { draw(); return true; },
      runKind: help.runKind, runSummaryOf: help.runSummaryOf, runGroup: help.runGroup,
      runGateTag: help.runGateTag, mapLimited: help.mapLimited,
      VmfRun: { fromQuery: () => null },
      explain: (e) => String(e && e.message ? e.message : e),
    },
  });
  return { src, err };
}
const rowsNow = () => globalThis.runRows.map(x => ({ r: x.r, group: x.group, setupOnly: x.setupOnly, waitsFor: x.waitsFor }))
  .sort((a, b) => (a.r < b.r ? -1 : 1));

/* ---- the list --------------------------------------------------------- */

test('the first load reads each run\'s three documents, and lists only the migrations', async () => {
  const { src } = page(store());
  await loadRuns(reader());
  for (const r of Object.keys(store())) { eq(reads(src, r, 'run.json'), 1, `${r} run.json`); }
  eq(rowsNow().map(x => x.r), ['p/mig-old', 'p/mig-sum', 'p/mig-zero', 'p/setup'], 'no assessment in the list');
});

test('PAGE-WAIT-1: on the first load a run\'s three reads are sent together', async () => {
  const held = [];
  const { src } = page({ 'p/mig-sum': store()['p/mig-sum'] }, { held });
  const loading = loadRuns(reader());
  for (let i = 0; i < 5; i++) { await new Promise(r => setImmediate(r)); }
  const sent = readsOf(src, 'p/mig-sum').map(x => x.split('|')[1]).sort();
  eq(sent, ['plan.json', 'run-status.json', 'run.json'], 'all three asked for before any answer came back');
  for (const release of held.splice(0)) { release(); }
  await loading;
});

test('THE REGRESSION: an assessment gets no status or plan read once its kind is known', async () => {
  const { src } = page(store());
  await loadRuns(reader());
  const before = src.log.length;
  await loadRuns(reader());
  await loadRuns(reader());
  const later = src.log.slice(before);
  for (const r of ['p/assess-1', 'p/assess-2']) {
    eq(later.filter(x => x.startsWith(`${r}|`)), [], `${r}: nothing at all on a later tick`);
  }
});

test('run.json is read once per run for the life of the page, not on every tick', async () => {
  const { src } = page(store());
  for (let tick = 0; tick < 4; tick++) { await loadRuns(reader()); }
  for (const r of Object.keys(store())) { eq(reads(src, r, 'run.json'), 1, `${r} run.json`); }
});

test('UNKNOWN MEANS ASK: a manifest the page could not read is asked for again', async () => {
  const docs = store();
  let failing = true;
  const { src } = page(docs, { fails: (r, rel) => failing && r === 'p/assess-1' && rel === 'run.json' });
  await loadRuns(reader());
  ok(globalThis.runRows.some(x => x.r === 'p/assess-1'), 'with no manifest it is listed, as before');
  failing = false;
  await loadRuns(reader());
  eq(reads(src, 'p/assess-1', 'run.json'), 2, 'asked again');
  ok(!globalThis.runRows.some(x => x.r === 'p/assess-1'), 'and left out once it says it is an assessment');
  await loadRuns(reader());
  eq(reads(src, 'p/assess-1', 'run.json'), 2, 'and then never again');
});

test('a run with no manifest at all keeps being asked, and stays a migration', async () => {
  const docs = store();
  delete docs['p/setup']['run.json'];
  const { src } = page(docs);
  await loadRuns(reader());
  await loadRuns(reader());
  eq(reads(src, 'p/setup', 'run.json'), 2, 'nothing was learned, so nothing is kept');
  ok(globalThis.runRows.some(x => x.r === 'p/setup'), 'still listed');
});

test('plan.json is read on a later tick only where the summary cannot count the machines', async () => {
  const { src } = page(store());
  await loadRuns(reader());
  const before = src.log.length;
  await loadRuns(reader());
  const later = src.log.slice(before);
  const planReads = (r) => later.filter(x => x === `${r}|plan.json`).length;
  eq(planReads('p/mig-sum'), 0, 'a v4 summary counts its machines');
  eq(planReads('p/mig-old'), 1, 'a status with no summary');
  eq(planReads('p/mig-zero'), 1, 'a summary that counts no machine');
  eq(planReads('p/setup'), 1, 'no status at all');
  for (const r of ['p/mig-sum', 'p/mig-old', 'p/mig-zero', 'p/setup']) {
    eq(later.filter(x => x === `${r}|run-status.json`).length, 1, `${r}: its status, once`);
  }
});

test('every row says on a later tick what it said on the first', async () => {
  page(store());
  await loadRuns(reader());
  const first = rowsNow();
  await loadRuns(reader());
  eq(rowsNow(), first);
  const of = (r) => first.find(x => x.r === r);
  eq(of('p/mig-sum').group, 'Waiting for approval');
  eq(of('p/mig-zero').group, 'Planned', 'a plan with entries, none moved');
  eq(of('p/mig-zero').setupOnly, false);
  eq(of('p/setup').setupOnly, true);
  eq(of('p/mig-old').group, 'Other', 'no summary it can read: the plan count does not stand for one');
});

test('a summary is never read as the machine count when the plan was read too', async () => {
  // On the first tick the plan is in hand: a plan with no entries is set up
  // only, whatever an old summary says.
  const docs = store();
  docs['p/mig-zero']['plan.json'] = { entries: [] };
  page(docs);
  await loadRuns(reader());
  eq(rowsNow().find(x => x.r === 'p/mig-zero').setupOnly, true);
});

/* ---- the open run ----------------------------------------------------- */

test('THE REGRESSION: the open run\'s status and plan are read once a tick', async () => {
  const { src, err } = page(store(), { current: 'p/mig-sum' });
  await loadRuns(reader());
  const before = src.log.length;
  await refresh();
  const tick = src.log.slice(before);
  eq(tick.filter(x => x === 'p/mig-sum|run-status.json').length, 1, 'run-status.json');
  eq(tick.filter(x => x === 'p/mig-sum|plan.json').length, 1, 'plan.json');
  eq(err.textContent, '', 'the run was drawn');
  eq((globalThis.planDoc.entries || []).length, 2, 'from the plan that was read');
});

test('the open run is read once on the first tick too, before its kind is known', async () => {
  const { src } = page(store(), { current: 'p/mig-old' });
  await refresh();
  eq(reads(src, 'p/mig-old', 'run-status.json'), 1);
  eq(reads(src, 'p/mig-old', 'plan.json'), 1);
});

test('the page\'s first load reads the open run once: the walk and the run share one reader', async () => {
  /* start() walks the store, chooses the run, then draws it. Both halves are
   * the same load. */
  const { src, err } = page(store());
  ok(tickReads, 'the page has a reader that one tick shares');
  const shared = reader();
  await loadRuns(shared);
  ok(globalThis.currentRun, 'a run was chosen');
  await refresh({ runsFresh: true, reads: shared });
  eq(reads(src, globalThis.currentRun, 'run-status.json'), 1);
  eq(reads(src, globalThis.currentRun, 'plan.json'), 1);
  eq(err.textContent, '');
  // MIGRATIONS-LOAD-1: start() hands its one reader to firstLoad, which hands
  // it to the walk, to the named run read beside it, and to the first draw.
  const start = extract('migrations.html', 'start');
  ok(/await asOneLoad\(\(\) => firstLoad\(tickReads\(\)\)\)/.test(start), 'start() makes one reader');
  const first = extract('migrations.html', 'firstLoad');
  ok(/drawNamedRun\(reads\)/.test(first), 'the named run uses it');
  ok(/await loadRuns\(reads\)/.test(first), 'the walk uses it');
  ok(/await refresh\(\{ runsFresh: true, reads \}\)/.test(first), 'and so does the first draw');
});

test('each tick reads again: a reader is never kept from one tick to the next', async () => {
  const { src } = page(store(), { current: 'p/mig-sum' });
  await refresh();
  await refresh();
  await refresh();
  eq(reads(src, 'p/mig-sum', 'run-status.json'), 3, 'the status, once a tick');
  eq(reads(src, 'p/mig-sum', 'plan.json'), 3, 'the plan, once a tick, for the run on screen');
});

test('a failed status read still says so on the run, and the list still draws', async () => {
  const { err } = page(store(), { current: 'p/mig-sum', fails: (r, rel) => r === 'p/mig-sum' && rel === 'run-status.json' });
  await refresh();
  ok(err.textContent.includes('HTTP 500'), 'the run says it could not refresh');
  ok(globalThis.runRows.some(x => x.r === 'p/mig-sum'), 'the list kept the run');
});

/* STOP-STATE-SHOWN-1 (review): the record of a stop is read like halt.flag
 * beside it - a stop that is there is kept for the cards, one that is not is
 * no stop, and a read that fails says so on the run. It must never read as
 * "not stopped", which drew the lab state again: both waves Complete, a red
 * brake card, and Resume. */
const STOPPED = { schemaVersion: 1, runId: 'mig-sum', stoppedUtc: '2026-11-17T01:12:40Z', stoppedBy: 'operator@example.com',
  note: 'n', wavesNotStarted: ['w2'], machines: [], schedulesRemoved: [] };
test('STOP-STATE-SHOWN-1: a stop on record is kept for the cards', async () => {
  const docs = store();
  docs['p/mig-sum']['stopped.json'] = STOPPED;
  const { src, err } = page(docs, { current: 'p/mig-sum' });
  await refresh();
  eq(reads(src, 'p/mig-sum', 'stopped.json'), 1, 'read once a tick');
  eq(err.textContent, '');
  eq(globalThis.runStop && globalThis.runStop.stoppedBy, 'operator@example.com');
});

test('STOP-STATE-SHOWN-1: no stop on record is no stop', async () => {
  const { err } = page(store(), { current: 'p/mig-sum' });
  globalThis.runStop = STOPPED;
  await refresh();
  eq(err.textContent, '');
  eq(globalThis.runStop, null);
});

test('STOP-STATE-SHOWN-1: a stop that cannot be read is not drawn as "not stopped"', async () => {
  const docs = store();
  docs['p/mig-sum']['stopped.json'] = STOPPED;
  const { err } = page(docs, { current: 'p/mig-sum', fails: (r, rel) => r === 'p/mig-sum' && rel === 'stopped.json' });
  let drawn = 0;
  globalThis.renderKpis = () => { drawn++; };
  globalThis.runStop = null;
  await refresh();
  ok(err.textContent.includes('HTTP 500'), 'the run says it could not refresh');
  eq(drawn, 0, 'the cards were not drawn from a read that failed');
  eq(globalThis.runStop, null, 'nothing was kept from it');
});
test('the saving, on a store of 19 assessments and 20 migrations', async () => {
  const docs = {};
  for (let i = 0; i < 19; i++) { docs[`p/a-${i}`] = { 'run.json': { kind: 'assessment' } }; }
  for (let i = 0; i < 20; i++) { docs[`p/m-${i}`] = store()['p/mig-sum']; }
  const { src } = page(docs, { current: 'p/m-0' });
  await refresh();
  const before = src.log.length;
  await refresh();
  const tick = src.log.slice(before).filter(x => !x.startsWith('p/m-0|') && !x.startsWith('|'));
  // One listing and one status per migration; nothing for an assessment.
  eq(tick.length, 1 + 19, 'the list, and the other migrations\' status');
});

/* ---- Reports ----------------------------------------------------------- */

const loadSummaries = lift('reports.html', 'loadSummaries');
globalThis.num = lift('reports.html', 'num');

function reportsPage(docs) {
  const src = fakeSource(docs);
  src.summary = async (r) => { src.log.push(`${r}|summary`); return { outcomes: { migrated: 1 } }; };
  src.exists = async (r, rel) => { src.log.push(`${r}|exists ${rel}`); return false; };
  // PAGE-SCALE-REPORTS-1: the projects come from the same one call; none here.
  src.listProjects = async () => [];
  Object.assign(globalThis, {
    source: src, rows: [], projects: [], storeRuns: [], assessmentIds: new Set(), byNewest: () => 0, renderTable() { },
    VmfHelp: { mapLimited: help.mapLimited, runKind: help.runKind,
      // PAGE-LOAD-1: the one call fails, so the page reads through `source`,
      // which these tests count (page-load.test.js measures the one call).
      storeDocs: async () => { throw new Error('per-file reads measured here'); } },
    DEMO_MODE: false, held: null, LIST_READS: [], cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token',
    heldSummary: () => undefined,
  });
  return src;
}

test('Reports: an assessment is left out before its status or plan is read', async () => {
  const src = reportsPage(store());
  await loadSummaries();
  for (const r of ['p/assess-1', 'p/assess-2']) {
    eq(readsOf(src, r), [`${r}|run.json`], `${r}: its manifest only`);
    ok(!globalThis.rows.some(x => x.r === r), `${r} is not a row`);
  }
});

test('Reports: THE REGRESSION - an assessment is not a migration that never got past setup', async () => {
  reportsPage(store());
  await loadSummaries();
  const setup = globalThis.rows.filter(x => x.setupOnly).map(x => x.r);
  eq(setup, ['p/setup'], 'only the run that was scanned and never planned');
});

test('Reports: every migration still gets its rows, its counts and its report check', async () => {
  const src = reportsPage(store());
  await loadSummaries();
  eq(globalThis.rows.map(x => x.r).sort(), ['p/mig-old', 'p/mig-sum', 'p/mig-zero', 'p/setup']);
  for (const r of ['p/mig-old', 'p/mig-sum', 'p/mig-zero']) {
    eq(reads(src, r, 'run-status.json'), 1, `${r} status`);
    eq(reads(src, r, 'plan.json'), 1, `${r} plan`);
    eq(reads(src, r, 'summary'), 1, `${r} summary`);
  }
  eq(globalThis.rows.find(x => x.r === 'p/mig-sum').total, 2);
  eq(reads(src, 'p/setup', 'summary'), 0, 'a run never planned is not asked for a summary');
});

test('Reports: a run with no manifest is listed as a migration', async () => {
  const docs = store();
  delete docs['p/setup']['run.json'];
  reportsPage(docs);
  await loadSummaries();
  ok(globalThis.rows.some(x => x.r === 'p/setup'), 'no manifest: listed, as before');
});

/* The page states the rule where a reader of the code looks for it. */
test('the kind of a run is kept in one place on the Migrations page', () => {
  ok(/\nconst runKinds = new Map\(\);/.test(PAGE), 'one map for the life of the page');
});

run('migrations-tick');
