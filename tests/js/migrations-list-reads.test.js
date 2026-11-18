/* MIGRATIONS-LIST-READS-1, 2026-11-08: the Migrations page's refresh reads
 * only what can change, and a slow refresh no longer piles up.
 *
 * MEASURED on the lab install, 2026-11-08 (the service's call-timing lines):
 * the list's one call (store/docs, depth 3) read 188 to 192 documents and took
 * 1.5 to 14.2 s, every 15 seconds while a person had the page open. It named
 * run.json on every tick, although the page keeps what each manifest says
 * (runKinds, PERF-MIGRATIONS-TICK-1) and a run's kind never changes. And
 * nothing stopped a tick while the one before it was still being read, so with
 * a slow list the calls piled up; the Refresh button, wired before the first
 * load (MIGRATIONS-LOAD-1), started a second load beside the first.
 *
 * THE RULES HELD HERE, each by counting what a fake service is asked:
 *   - the first load's list names run.json, as before;
 *   - a later tick's list names run.json only while a run the last list held
 *     has no known kind (unknown means ask); run-status.json every tick;
 *   - the rows say what they said;
 *   - a new run still appears on the next tick, and its kind is learned;
 *   - a tick never starts while a load is still running (it is skipped, not
 *     queued), and the next tick after it ends reads again;
 *   - a load that has run longer than LOAD_HOLDS_MS no longer holds a tick
 *     back, so a call that never answers cannot stop the page refreshing;
 *   - a Refresh press while a load runs joins it; with none running it reads;
 *   - a refresh a person starts (another run chosen, an action's follow-up)
 *     is never skipped.
 */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const PAGE = pageSource(path.join(DASH, 'migrations.html'));
const constOf = (src, name) => Number((src.match(new RegExp(`const ${name} = (\\d+);`)) || [])[1]);
globalThis.DEMO_MODE = false;
globalThis.STORE_READ_LIMIT = constOf(HELP, 'STORE_READ_LIMIT');
globalThis.STORE_DOCS_PAGES_MAX = constOf(HELP, 'STORE_DOCS_PAGES_MAX');
globalThis.LOG_PARTS_MAX = constOf(HELP, 'LOG_PARTS_MAX');
globalThis.EVENT_CAP = constOf(HELP, 'EVENT_CAP');
const LOAD_HOLDS_MS = constOf(PAGE, 'LOAD_HOLDS_MS');

const H = liftAll('help.js', ['storeUrl', 'storeError', 'storeHolds', 'storeDocs', 'heldDepth', 'heldList', 'heldText',
  'heldJson', 'heldHas', 'mapLimited', 'readLimiter', 'runFolderIsRun', 'runKind', 'listRunsAcrossProjects',
  'leasesByMachine', 'idKey', 'nextLogPart', 'readLogParts', 'readLogEvents']);
globalThis.idKey = H.idKey;

/* The page's own functions, in one scope so they call each other. A page
 * without this item's functions is still run, in its old shape, so each rule
 * fails on its own count rather than on a missing name. */
const BASE = ['blobFetch', 'blobList', 'runListed', 'tickReads', 'loadRuns', 'refresh', 'refreshRun',
  'linkedRunId', 'namedRun', 'drawNamedRun', 'firstLoad', 'tickLoop'];
const NEW = ['listReads', 'refreshOnce', 'asOneLoad', 'loadsHolding', 'tickRefresh', 'refreshPressed'];
let M;
try { M = liftAll('migrations.html', BASE.concat(NEW)); }
catch (e) {
  M = liftAll('migrations.html', BASE);
  M.missing = e.message;
  M.refreshPressed = () => M.refresh();
}
const arr = (name) => {
  const m = PAGE.match(new RegExp(`\\nconst ${name} = (\\[[^\\]\\n]*\\]);`));
  return eval(m[1]); // eslint-disable-line no-eval
};
const LIST_READS = arr('LIST_READS');
const RUN_READS = arr('RUN_READS');
const liftSource = () => {
  const m = PAGE.match(/\nconst source = (DEMO_MODE \? \{[\s\S]*?\n\});/);
  return eval(`(${m[1]})`); // eslint-disable-line no-eval
};

/* ---- a store of the lab's shape: 4 projects, 96 runs ---- */
const ord = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const textOf = (v) => (typeof v === 'string' ? v : JSON.stringify(v));
const at = (min) => new Date(Date.UTC(2026, 10, 8, 12, min)).toISOString();
function addMigration(f, id, min, vms) {
  f[`${id}/run.json`] = { runId: id.split('/').pop(), kind: 'migration' };
  f[`${id}/run-status.json`] = { schemaVersion: 4, updatedUtc: at(min), stateCounts: { PLANNED: vms },
    summary: { writtenUtc: at(min), reason: 'planSaved', halted: false, machines: vms, stateCounts: { PLANNED: vms }, waves: [], next: { wave: 'w1', waitsFor: 'approval' } } };
  f[`${id}/plan.json`] = { entries: Array.from({ length: vms }, (_, i) => ({ vmId: `/subscriptions/x/${id}-vm${i}`, wave: 'w1', path: 'A' })) };
  for (let i = 0; i < vms; i++) { f[`${id}/state/vm${i}.json`] = { vmId: `/subscriptions/x/${id}-vm${i}`, state: 'PLANNED' }; }
  f[`${id}/assessment.json`] = { vms: [] };
}
function addAssessment(f, id) {
  f[`${id}/run.json`] = { runId: id.split('/').pop(), kind: 'assessment' };
  f[`${id}/assessment.json`] = { vms: [] };
}
function store() {
  const f = { 'retention-status.json': { lastPassUtc: at(0) } };
  for (let p = 1; p <= 4; p++) {
    f[`p${p}/project.json`] = { projectId: `p${p}` };
    for (let i = 1; i <= 12; i++) {
      addMigration(f, `p${p}/mig-${i}`, p * 12 + i, 2);
      addAssessment(f, `p${p}/assess-${i}`);
    }
  }
  return f;
}
const NEWEST = 'p4/mig-12';

/* A service that answers store/docs and store/blob from the store, records
 * every call, what each store/docs call named and how many documents it read,
 * and holds back the answer to a call `hold` names until the test releases it. */
function service(files, opts) {
  const o = opts || {};
  const s = { calls: [], docCalls: [], hold: new Set(o.hold || []), gates: [], refuse: o.refuse || (() => false) };
  const gate = (key) => (s.hold.has(key) ? new Promise(res => { s.gates.push({ key, res }); }) : Promise.resolve());
  s.release = (key) => {
    const g = s.gates.filter(x => x.key === key);
    ok(g.length, `${key} was held`);
    s.gates = s.gates.filter(x => x.key !== key);
    g.forEach(x => x.res());
  };
  const serve = (q) => {
    const prefix = q.prefix || '', depth = Number(q.depth);
    const pats = String(q.read).split(',').filter(Boolean).map(p => p.split('/'));
    const glob = (p, t) => new RegExp('^' + p.split('*').map(x => x.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(t);
    const names = [], folders = new Set(), docs = [];
    for (const n of Object.keys(files).sort(ord)) {
      if (!n.startsWith(prefix)) { continue; }
      const parts = n.slice(prefix.length).split('/');
      for (let i = 1; i < parts.length && i <= depth; i++) { folders.add(prefix + parts.slice(0, i).join('/')); }
      if (parts.length > depth) { continue; }
      names.push(n);
      if (pats.some(sg => sg.length <= parts.length && glob(sg.join('/'), parts.slice(parts.length - sg.length).join('/')))) {
        docs.push(s.refuse(n) ? { path: n, error: 'refused' } : { path: n, text: textOf(files[n]) });
      }
    }
    return { names, folders: [...folders].sort(ord), truncated: false, docs, next: '' };
  };
  s.fetch = async (url) => {
    const q = Object.fromEntries(new URL(url).searchParams.entries());
    const key = q.prefix ? `run:${q.prefix}` : 'list';
    s.calls.push(key);
    await gate(key);
    const body = serve(q);
    s.docCalls.push({ key, read: String(q.read).split(',').filter(Boolean), docs: body.docs.length });
    return { ok: true, status: 200, json: async () => body };
  };
  s.storeBlob = async (getToken, apiUrl, p, ro) => {
    const key = `blob:${p}`;
    s.calls.push(key);
    await gate(key);
    if (!(p in files)) { return null; }
    if (s.refuse(p)) { throw new Error('refused'); }
    if (ro && ro.asVersioned) { return { text: textOf(files[p]), version: `v-${p}` }; }
    if (ro && ro.asText) { return textOf(files[p]); }
    return JSON.parse(textOf(files[p]));
  };
  s.storeList = async () => { throw new Error('every listing comes from the one call here'); };
  return s;
}

/* The page, with every draw recorded and a 1-second clock for the tick loop. */
function page(s, opts) {
  const o = opts || {};
  const draws = [];
  const els = { '#run-panel': { classList: { contains: () => false } }, '#err': { textContent: '', style: { display: 'none' } },
    '#live-ind': { className: '', title: '' }, '#tick': { textContent: '' } };
  for (const k of Object.keys(M)) { if (typeof M[k] === 'function') { globalThis[k] = M[k]; } }
  const intervals = [];
  Object.assign(globalThis, {
    cfg: { apiUrl: 'https://service.example.com/api', apiAppId: 'x', refreshSeconds: 1 }, getToken: async () => 'token',
    fetch: s.fetch, DEMO_MODE: false, window: globalThis, VmfListRuns: H.listRunsAcrossProjects, LIST_READS, RUN_READS,
    LOAD_HOLDS_MS, storeRead: H.readLimiter(), location: { search: '' },
    localStorage: { getItem: () => null, setItem() { } },
    source: liftSource(), pendingRuns: new Set(), runKinds: new Map(), history: { replaceState() { } },
    listedRuns: null, loadsRunning: new Set(), nextRefresh: 0,
    runRows: [], currentRun: null, lastListError: null, showingRun: null, reading: true,
    renderRunPanel() { }, showReadingRun() { }, clearReadingRun() { }, async renderFirstRun() { draws.push({ firstRun: true }); },
    nameMachines() { }, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis() { }, renderNextStep() { }, renderFound() { },
    renderWaves() { draws.push({ run: globalThis.currentRun, vms: globalThis.allVms.map(v => v.vmId) }); },
    refreshDrill() { }, renderCapacity() { }, renderSafetyCopies() { }, renderEvents() { }, ago: () => 'a while ago',
    planDoc: null, runAck: null, runStop: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null,
    lastAssessment: null, schedules: new Map(), acceptances: new Map(), approvals: new Map(),
    allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false, discardInFlight: new Map(), latestEvents: [],
    restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    $: (sel) => els[sel] ?? null, runRegions: () => [],
    setInterval: (fn) => { intervals.push(fn); return intervals.length; },
  });
  globalThis.VmfHelp = {
    mapLimited: H.mapLimited, runFolderIsRun: H.runFolderIsRun, runKind: H.runKind, readLimiter: H.readLimiter,
    storeList: s.storeList, storeBlob: s.storeBlob, storeUrl: H.storeUrl, storeDocs: H.storeDocs,
    heldList: H.heldList, heldJson: H.heldJson, heldHas: H.heldHas, heldText: H.heldText, storeHolds: H.storeHolds,
    readLogEvents: H.readLogEvents, leasesByMachine: H.leasesByMachine,
    runSummaryOf: (st) => (st && st.summary) || null, runGroup: () => 'Waiting for approval',
    drawWhenFree: (regions, draw) => { draw(); return true; },
    VmfRun: { fromQuery: () => null, withProject: (b) => b },
    explain: (e) => String(e && e.message ? e.message : e),
  };
  /* One second of the page's clock: what the tick loop's timer does. */
  const second = () => { ok(intervals.length === 1, 'the tick loop set one timer'); intervals[0](); };
  return { draws, els, second };
}

const settle = async (n) => { for (let i = 0; i < (n || 40); i++) { await new Promise(r => setImmediate(r)); } };

/* The page opened: the first load, done. */
async function opened(opts) {
  const o = opts || {};
  const files = o.files || store();
  const s = service(files, o);
  const p = page(s, o);
  await M.firstLoad(M.tickReads());
  return { s, files, ...p, first: s.calls.length, firstDocs: s.docCalls.length };
}
const listCalls = (s, from) => s.docCalls.slice(from || 0).filter(c => c.key === 'list');
const rows = () => globalThis.runRows.map(x => ({ r: x.r, group: x.group, setupOnly: x.setupOnly, t: x.t }));

/* ---- THE DEFECT: what a tick reads ---- */

test('THE DEFECT: the first load\'s list names run.json; a later tick\'s list does not, when every kind is known', async () => {
  const o = await opened();
  const first = listCalls(o.s);
  eq(first.length, 1, 'the list, once on the first load');
  ok(first[0].read.includes('run.json') && first[0].read.includes('run-status.json'), 'the first load names both');
  await M.refresh();
  const tick = listCalls(o.s, o.firstDocs);
  eq(tick.length, 1, 'the list, once a tick');
  eq(tick[0].read, ['run-status.json'], `a tick names only run-status.json (${M.missing || 'lifted'})`);
});

test('documents the service reads for the list: 144 on the first load, 48 a tick after it (96 runs, 48 migrations)', async () => {
  const o = await opened();
  eq(listCalls(o.s)[0].docs, 96 + 48, 'first load: every run.json and every run-status.json');
  await M.refresh();
  eq(listCalls(o.s, o.firstDocs)[0].docs, 48, 'a tick: only the run-status.json of each migration');
});

test('calls a tick are as many as before, and no run.json is read one by one', async () => {
  const o = await opened();
  await M.refresh();
  const tick = o.s.calls.slice(o.first);
  eq(tick.slice().sort(), ['blob:p4/mig-12/plan.json', 'blob:retention-status.json', 'list', 'run:p4/mig-12/'].sort(),
    'the list, the open run, its plan (with its version), the cleanup record');
  ok(!tick.some(c => /run\.json$/.test(c)), 'no manifest read alone');
});

test('the rows say what they said, tick after tick', async () => {
  const o = await opened();
  const before = rows();
  eq(before.length, 48, 'every migration and no assessment');
  await M.refresh();
  eq(rows(), before, 'after one tick');
  await M.refresh();
  eq(rows(), before, 'after two');
  eq(globalThis.currentRun, NEWEST, 'the newest run is still open');
  ok(o.draws.filter(d => d.run === NEWEST).length >= 3, 'and drawn on each tick');
});

test('a run\'s status still updates on each tick', async () => {
  const o = await opened();
  o.files['p1/mig-1/run-status.json'] = { ...o.files['p1/mig-1/run-status.json'], updatedUtc: at(200) };
  await M.refresh();
  eq(globalThis.runRows[0].r, 'p1/mig-1', 'the run with the newest activity is first');
});

/* ---- a new run, and unknown means ask ---- */

test('a new migration appears on the next tick, and its kind is learned once', async () => {
  const o = await opened();
  addMigration(o.files, 'p2/mig-new', 300, 3);
  addAssessment(o.files, 'p2/assess-new');
  await M.refresh();
  ok(globalThis.runRows.some(x => x.r === 'p2/mig-new'), 'the new migration is in the list');
  ok(!globalThis.runRows.some(x => x.r === 'p2/assess-new'), 'the new assessment is not');
  eq(globalThis.runKinds.get('p2/mig-new'), 'migration', 'its kind is kept');
  eq(globalThis.runKinds.get('p2/assess-new'), 'assessment');
  const mark = o.s.docCalls.length, calls = o.s.calls.length;
  await M.refresh();
  eq(listCalls(o.s, mark)[0].read, ['run-status.json'], 'the next tick names run.json no more');
  eq(o.s.calls.slice(calls).filter(c => /run\.json$/.test(c)).length, 0, 'and reads no manifest alone');
});

test('unknown means ask: a manifest the store refused is asked for again, by the next list', async () => {
  let refused = true;
  const o = await opened({ refuse: (n) => refused && n === 'p3/mig-5/run.json' });
  ok(!globalThis.runKinds.has('p3/mig-5'), 'its kind is not known');
  await M.refresh();
  ok(listCalls(o.s, o.firstDocs)[0].read.includes('run.json'), 'the next tick names run.json');
  refused = false;
  const mark = o.s.docCalls.length;
  await M.refresh();
  eq(globalThis.runKinds.get('p3/mig-5'), 'migration', 'learned once the store answers');
  ok(globalThis.runRows.some(x => x.r === 'p3/mig-5'), 'and it is in the list');
  await M.refresh();
  eq(listCalls(o.s, mark + 2)[0].read, ['run-status.json'], 'then run.json is not named again');
});

test('before any list was read, the list names run.json', () => {
  ok(!M.missing, M.missing);
  globalThis.listedRuns = null;
  globalThis.runKinds = new Map();
  eq(M.listReads(), LIST_READS, 'the whole LIST_READS');
  ok(LIST_READS.includes('run.json'), 'which names run.json');
});

/* ---- no overlap: a tick is skipped while a load runs ---- */

test('THE DEFECT: a tick while the list is still being read starts no second load', async () => {
  const o = await opened();
  M.tickLoop();
  o.s.hold.add('list');
  o.second();                       // the tick: a load starts, its list held
  await settle();
  eq(o.s.calls.slice(o.first).filter(c => c === 'list').length, 1, 'the first tick asked for the list');
  o.second(); o.second(); o.second();   // three more ticks while it is still read
  await settle();
  eq(o.s.calls.slice(o.first).filter(c => c === 'list').length, 1, `no second list call (${M.missing || 'lifted'})`);
  eq(o.s.calls.slice(o.first).filter(c => c.startsWith('run:')).length, 1, 'no second run call');
  o.s.hold.delete('list');
  o.s.release('list');
  await settle();
  const mark = o.s.calls.length;
  o.second();                       // the next tick after it ended reads again
  await settle();
  eq(o.s.calls.slice(mark).filter(c => c === 'list').length, 1, 'the next tick reads the store again');
  ok(/next in \d+s/.test(o.els['#tick'].textContent), 'the countdown still says when');
});

test('a load that has run longer than LOAD_HOLDS_MS no longer holds a tick back', async () => {
  ok(!M.missing, M.missing);
  ok(LOAD_HOLDS_MS >= 60000, `a slow list (14 s measured) is not cut short: ${LOAD_HOLDS_MS} ms`);
  const o = await opened();
  M.tickLoop();
  o.s.hold.add('list');
  const realNow = Date.now;
  let now = realNow();
  Date.now = () => now;
  try {
    o.second();
    await settle();
    now += LOAD_HOLDS_MS - 1000;
    o.second();
    await settle();
    eq(o.s.calls.slice(o.first).filter(c => c === 'list').length, 1, 'still held back just before the limit');
    now += 2000;
    o.second();
    await settle();
    eq(o.s.calls.slice(o.first).filter(c => c === 'list').length, 2, 'a load past the limit holds no tick back');
    o.second();
    await settle();
    eq(o.s.calls.slice(o.first).filter(c => c === 'list').length, 2, 'and the new load holds the next tick back');
  } finally {
    Date.now = realNow;
    o.s.hold.delete('list');
    o.s.release('list');
    await settle();
  }
});

/* ---- the Refresh button joins a running load ---- */

test('THE DEFECT: Refresh pressed during the first load joins it, and starts no second load', async () => {
  const files = store();
  const s = service(files, { hold: ['list'] });
  page(s, {});
  const loading = M.asOneLoad ? M.asOneLoad(() => M.firstLoad(M.tickReads())) : M.firstLoad(M.tickReads());
  await settle();
  const before = s.calls.length;
  let joinedEnded = false;
  const pressed = M.refreshPressed().then(() => { joinedEnded = true; });
  await settle();
  eq(s.calls.slice(before), [], `no call is sent for the press (${M.missing || 'lifted'})`);
  ok(!joinedEnded, 'the press waits for the load it joined');
  s.release('list');
  await loading;
  await pressed;
  ok(joinedEnded, 'and ends with it');
  eq(s.calls.filter(c => c === 'list').length, 1, 'one list call in all');
  eq(globalThis.currentRun, NEWEST, 'the load drew its run');
});

test('Refresh pressed with no load running reads the store, and sets the countdown back', async () => {
  const o = await opened();
  globalThis.nextRefresh = 3;
  await M.refreshPressed();
  eq(listCalls(o.s, o.firstDocs).length, 1, 'the list is read');
  ok(o.s.calls.slice(o.first).some(c => c.startsWith('run:')), 'and the open run');
  eq(globalThis.nextRefresh, 1, 'the countdown starts again from the refresh period');
});

test('a refresh a person starts is never skipped: another run chosen during a slow tick is read at once', async () => {
  const o = await opened();
  M.tickLoop();
  o.s.hold.add('list');
  o.second();
  await settle();
  globalThis.currentRun = 'p1/mig-3';           // selectRun, then refresh(), as the picker does
  const switched = M.refresh();
  await settle();
  ok(o.s.calls.includes('run:p1/mig-3/'), 'the chosen run is read while the slow list is still out');
  ok(o.draws.some(d => d.run === 'p1/mig-3'), 'and drawn');
  o.s.hold.delete('list');
  o.s.release('list');
  await switched;
  await settle();
});

/* ---- the code ---- */

test('the tick loop asks tickRefresh, and the Refresh button asks refreshPressed', () => {
  ok(!M.missing, M.missing);
  const loop = PAGE.slice(PAGE.indexOf('function tickLoop()'), PAGE.indexOf('function tickLoop()') + 1500);
  ok(/tickRefresh\(\)/.test(loop), 'the tick is skipped while a load runs');
  ok(!/\brefresh\(\)/.test(loop.replace(/\/\/.*$/gm, '')), 'the tick never calls refresh() itself');
  const body = PAGE.slice(PAGE.indexOf('async function start()'), PAGE.indexOf('async function boot()'));
  ok(/'#refresh-btn'\)\.addEventListener\('click', \(\) => \{ refreshPressed\(\); \}\)/.test(body), 'the button joins a running load');
  ok(/asOneLoad\(\(\) => firstLoad\(tickReads\(\)\)\)/.test(body), 'the first load is a load a press can join');
});

run('migrations-list-reads');
