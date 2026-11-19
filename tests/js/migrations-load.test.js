/* MIGRATIONS-LOAD-1, 2026-11-08: the open migration is drawn without waiting
 * for the list of every migration in the store.
 *
 * MEASURED on the lab install, 2026-11-08 (Application Insights, the
 * service's call-timing lines, 11:28 to 12:12 UTC). The Migrations page sends
 * two store/docs calls when it opens:
 *   - the LIST: the whole store listed, and run.json and run-status.json of
 *     every run - 188 to 192 documents read, 1.5 to 14.2 s;
 *   - the RUN: the open run's folder - 4 documents for the drill migration,
 *     40 ms to 3.0 s, median 0.4 s.
 * start() waited for the list before it sent the run's call, so the first
 * draw waited for both, one after the other: the browser saw "one store/docs
 * call, 9.7 s" (the list), and the run was still being read after 10 s.
 *
 * THE RULE HELD HERE. When the page already knows which run it opens - a
 * ?run= link, else the run looked at last - it reads that run beside the list
 * and draws it as soon as its own documents are in, once its manifest says it
 * is a migration. Everything else is as before:
 *   - the list still arrives, and fills the picker;
 *   - a run named but not a migration (an assessment, a run that is gone, a
 *     run outside ?project=) is not drawn early; the list chooses, as before;
 *   - a run the list does not hold leaves nothing behind: the list's choice
 *     is drawn, from its own documents;
 *   - what is drawn is what the old order drew, and the run's documents are
 *     read once.
 */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const constOf = (src, name) => Number((src.match(new RegExp(`const ${name} = (\\d+);`)) || [])[1]);
globalThis.DEMO_MODE = false;
globalThis.STORE_READ_LIMIT = constOf(HELP, 'STORE_READ_LIMIT');
globalThis.STORE_DOCS_PAGES_MAX = constOf(HELP, 'STORE_DOCS_PAGES_MAX');
globalThis.LOG_PARTS_MAX = constOf(HELP, 'LOG_PARTS_MAX');
globalThis.EVENT_CAP = constOf(HELP, 'EVENT_CAP');

const H = liftAll('help.js', ['storeUrl', 'storeError', 'storeHolds', 'storeDocs', 'heldDepth', 'heldList', 'heldText',
  'heldJson', 'heldHas', 'mapLimited', 'readLimiter', 'runFolderIsRun', 'runKind', 'listRunsAcrossProjects',
  'leasesByMachine', 'idKey', 'nextLogPart', 'readLogParts', 'readLogEvents']);
globalThis.idKey = H.idKey;

/* The page's own functions, in one scope so they call each other. */
// MIGRATIONS-LIST-READS-1: refresh counts each load (asOneLoad), and the list names its reads (listReads).
const BASE = ['blobFetch', 'blobList', 'runListed', 'tickReads', 'listReads', 'loadRuns', 'refresh', 'refreshOnce', 'asOneLoad',
  'refreshRun', 'linkedRunId'];
let M;
try { M = liftAll('migrations.html', BASE.concat(['namedRun', 'drawNamedRun', 'firstLoad'])); }
catch (e) { M = liftAll('migrations.html', BASE); M.missing = e.message; }
/* A page without firstLoad is run in start()'s old order, so each rule
 * fails on its own count rather than on a missing name. */
const firstLoad = M.firstLoad || (async (reads) => {
  try { await M.loadRuns(reads); } finally { globalThis.reading = false; globalThis.renderRunPanel(); }
  await M.refresh({ runsFresh: true, reads });
});
const RUN_READS = (() => {
  const m = pageSource(path.join(DASH, 'migrations.html')).match(/\nconst RUN_READS = (\[[^\]\n]*\]);/);
  return eval(m[1]); // eslint-disable-line no-eval
})();
const LIST_READS = (() => {
  const m = pageSource(path.join(DASH, 'migrations.html')).match(/\nconst LIST_READS = (\[[^\]\n]*\]);/);
  return eval(m[1]); // eslint-disable-line no-eval
})();
const liftSource = () => {
  const m = pageSource(path.join(DASH, 'migrations.html')).match(/\nconst source = (DEMO_MODE \? \{[\s\S]*?\n\});/);
  return eval(`(${m[1]})`); // eslint-disable-line no-eval
};

/* ---- a store like the lab's: a project of migrations and an assessment ---- */
const ord = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const textOf = (v) => (typeof v === 'string' ? v : JSON.stringify(v));
const at = (min) => new Date(Date.UTC(2026, 10, 8, 12, min)).toISOString();
function store() {
  const f = { 'retention-status.json': { lastPassUtc: at(0) }, 'p/project.json': { projectId: 'p' } };
  const mig = (id, min, vms) => {
    f[`${id}/run.json`] = { runId: id.split('/').pop(), kind: 'migration' };
    f[`${id}/run-status.json`] = { schemaVersion: 4, updatedUtc: at(min), stateCounts: { PLANNED: vms },
      summary: { writtenUtc: at(min), reason: 'planSaved', halted: false, machines: vms, stateCounts: { PLANNED: vms }, waves: [], next: { wave: 'w1', waitsFor: 'approval' } } };
    f[`${id}/plan.json`] = { entries: Array.from({ length: vms }, (_, i) => ({ vmId: `/subscriptions/x/${id}-vm${i}`, wave: 'w1', path: 'A' })) };
    for (let i = 0; i < vms; i++) { f[`${id}/state/vm${i}.json`] = { vmId: `/subscriptions/x/${id}-vm${i}`, state: 'PLANNED' }; }
    f[`${id}/capacity/c1.json`] = { cell: `${id}-c1` };
    f[`${id}/assessment.json`] = { vms: [] };
    f[`${id}/logs/events.jsonl`] = `{"tsUtc":"${at(min)}","step":"wave","outcome":"info","detail":"${id}"}`;
    f[`${id}/catalog/eastus.json`] = { skus: ['a document no page draws'] };
  };
  mig('p/mig-a', 10, 3);   // the run looked at last, older
  mig('p/mig-b', 20, 2);   // the newest
  f['p/assess-1/run.json'] = { runId: 'assess-1', kind: 'assessment' };
  f['p/assess-1/assessment.json'] = { vms: [] };
  return f;
}

/* A service that answers store/docs and store/blob from the store, counts
 * every call, and holds back the answer to a call `hold` names until the
 * test releases it. */
function service(files, opts) {
  const o = opts || {};
  const s = { calls: [], answered: [], gates: {} };
  const gate = (key) => (o.hold && o.hold.includes(key)
    ? new Promise(res => { s.gates[key] = res; }) : Promise.resolve());
  s.release = (key) => { const r = s.gates[key]; ok(r, `${key} was held`); r(); };
  const serve = (q) => {
    const from = q.prefix ? files : (o.listFiles || files);
    const prefix = q.prefix || '', depth = Number(q.depth);
    const pats = String(q.read).split(',').map(p => p.split('/'));
    const glob = (p, t) => new RegExp('^' + p.split('*').map(x => x.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(t);
    const names = [], folders = new Set(), docs = [];
    for (const n of Object.keys(from).sort(ord)) {
      if (!n.startsWith(prefix)) { continue; }
      const parts = n.slice(prefix.length).split('/');
      for (let i = 1; i < parts.length && i <= depth; i++) { folders.add(prefix + parts.slice(0, i).join('/')); }
      if (parts.length > depth) { continue; }
      names.push(n);
      if (pats.some(sg => sg.length <= parts.length && glob(sg.join('/'), parts.slice(parts.length - sg.length).join('/')))) {
        docs.push({ path: n, text: textOf(from[n]) });
      }
    }
    return { names, folders: [...folders].sort(ord), truncated: false, docs, next: '' };
  };
  s.fetch = async (url) => {
    const u = new URL(url);
    const q = Object.fromEntries(u.searchParams.entries());
    const key = q.prefix ? `run:${q.prefix}` : 'list';
    s.calls.push(key);
    s.bytes = (s.bytes || 0);
    await gate(key);
    if (o.docsFail && o.docsFail(key)) { s.answered.push(key); return { ok: false, status: 500, json: async () => ({ error: 'refused' }) }; }
    const body = serve(q);
    s.bytes += JSON.stringify(body).length;
    s.answered.push(key);
    return { ok: true, status: 200, json: async () => body };
  };
  s.storeBlob = async (getToken, apiUrl, p, ro) => {
    const key = `blob:${p}`;
    s.calls.push(key);
    await gate(key);
    s.answered.push(key);
    if (!(p in files)) { return null; }
    if (ro && ro.asVersioned) { return { text: textOf(files[p]), version: `v-${p}` }; }
    if (ro && ro.asText) { return textOf(files[p]); }
    return JSON.parse(textOf(files[p]));
  };
  s.storeList = async (getToken, apiUrl, prefix, delimiter) => {
    s.calls.push(`ls:${prefix}`);
    const names = [], prefixes = new Set();
    for (const n of Object.keys(files).sort(ord)) {
      if (!n.startsWith(prefix || '')) { continue; }
      const rest = n.slice((prefix || '').length);
      const cut = delimiter === '/' ? rest.indexOf('/') : -1;
      if (cut >= 0) { prefixes.add((prefix || '') + rest.slice(0, cut)); } else { names.push(n); }
    }
    return { names, prefixes: [...prefixes].sort(ord), truncated: false };
  };
  return s;
}

/* The page around its first load, with every draw recorded. */
function page(s, opts) {
  const o = opts || {};
  const draws = [];
  const els = { '#run-panel': { classList: { contains: () => false } }, '#err': { textContent: '', style: { display: 'none' } },
    '#live-ind': { className: '', title: '' } };
  for (const k of BASE.concat(['namedRun', 'drawNamedRun'])) { if (M[k]) { globalThis[k] = M[k]; } }
  const remembered = o.remembered || null;
  Object.assign(globalThis, {
    cfg: { apiUrl: 'https://service.example.com/api', apiAppId: 'x' }, getToken: async () => 'token', fetch: s.fetch,
    DEMO_MODE: false, window: globalThis, VmfListRuns: H.listRunsAcrossProjects, LIST_READS, RUN_READS,
    storeRead: H.readLimiter(),
    location: { search: o.search || '' },
    localStorage: { getItem: (k) => (k === 'vmf-last-run' ? remembered : null), setItem() { } },
    source: liftSource(), pendingRuns: new Set(), runKinds: new Map(), listedRuns: null, loadsRunning: new Set(), history: { replaceState() { } },
    runRows: [], currentRun: null, lastListError: null, showingRun: null, reading: true, panelDraws: [],
    renderRunPanel() { globalThis.panelDraws.push({ rows: globalThis.runRows.length, reading: globalThis.reading }); },
    showReadingRun() { }, clearReadingRun() { }, async renderFirstRun() { draws.push({ firstRun: true }); },
    nameMachines() { }, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis() { }, renderNextStep() { }, renderFound() { },
    renderWaves() {
      draws.push({ run: globalThis.currentRun, showing: globalThis.showingRun, listAnswered: s.answered.includes('list'),
        answered: s.answered.slice(), vms: globalThis.allVms.map(v => v.vmId), plan: globalThis.planDoc });
    },
    refreshDrill() { }, renderCapacity() { }, renderSafetyCopies() { }, renderEvents() { }, ago: () => 'a while ago',
    planDoc: null, runAck: null, runStop: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null,
    lastAssessment: null, schedules: new Map(), acceptances: new Map(), approvals: new Map(),
    allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false, discardInFlight: new Map(), latestEvents: [],
    restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    $: (sel) => els[sel] ?? null, runRegions: () => [],
  });
  const linked = o.linked || null;
  globalThis.VmfHelp = {
    mapLimited: H.mapLimited, runFolderIsRun: H.runFolderIsRun, runKind: H.runKind, readLimiter: H.readLimiter,
    storeList: s.storeList, storeBlob: s.storeBlob, storeUrl: H.storeUrl, storeDocs: H.storeDocs,
    heldList: H.heldList, heldJson: H.heldJson, heldHas: H.heldHas, heldText: H.heldText, storeHolds: H.storeHolds,
    readLogEvents: H.readLogEvents, leasesByMachine: H.leasesByMachine,
    runSummaryOf: (st) => (st && st.summary) || null, runGroup: () => 'Waiting for approval',
    drawWhenFree: (regions, draw) => { draw(); return true; },
    VmfRun: { fromQuery: () => linked, withProject: (b) => b },
    explain: (e) => String(e && e.message ? e.message : e),
  };
  return { draws, els };
}

const tickOver = async (n) => { for (let i = 0; i < (n || 30); i++) { await new Promise(r => setImmediate(r)); } };

/* The first load, with the list held back until the run is drawn (or not). */
async function load(opts) {
  const o = opts || {};
  const s = service(o.files || store(), { hold: ['list'].concat(o.hold || []), listFiles: o.listFiles, docsFail: o.docsFail });
  const p = page(s, o);
  const loading = firstLoad(M.tickReads());
  await tickOver();
  const beforeList = p.draws.slice();
  const callsBeforeList = s.calls.slice();
  if (o.beforeRelease) { await o.beforeRelease(s); }
  s.release('list');
  await tickOver();
  if (o.afterRelease) { await o.afterRelease(s); }
  await loading;
  return { s, ...p, beforeList, callsBeforeList };
}

const snapshot = () => ({
  current: globalThis.currentRun, showing: globalThis.showingRun, planDoc: globalThis.planDoc,
  vms: globalThis.allVms.map(v => v.vmId).sort(), claims: globalThis.latestClaims,
  events: globalThis.latestEvents, assessment: globalThis.lastAssessment, halted: globalThis.latestHalted,
});

/* ---- THE DEFECT ---- */

test('THE DEFECT: a run named by a link is drawn before the list of runs answers', async () => {
  const r = await load({ linked: 'p/mig-a' });
  eq(r.beforeList.length, 1, `drawn once while the list was still being read (${M.missing || 'firstLoad lifted'})`);
  eq(r.beforeList[0].run, 'p/mig-a', 'the run the link names');
  eq(r.beforeList[0].showing, 'p/mig-a', 'and the page says it shows it');
  eq(r.beforeList[0].vms.length, 3, 'its machines are drawn');
  ok(!r.beforeList[0].listAnswered, 'the list had not answered');
});

test('THE DEFECT: the run looked at last is drawn before the list of runs answers', async () => {
  const r = await load({ remembered: 'p/mig-a' });
  eq(r.beforeList.map(d => d.run), ['p/mig-a'], 'drawn while the list was being read');
});

test('the first draw waits for 4 calls, none of them the list', async () => {
  const r = await load({ linked: 'p/mig-a' });
  const before = r.beforeList[0].answered.slice().sort();
  eq(before, ['blob:p/mig-a/plan.json', 'blob:p/mig-a/run.json', 'blob:retention-status.json', 'run:p/mig-a/'].sort(),
    'the run\'s one call, its manifest, its plan (with its version) and the cleanup record');
  ok(r.callsBeforeList.includes('list'), 'the list was asked for at the same time, not after');
});

test('the run is drawn once and its documents are read once, with the list after it', async () => {
  const r = await load({ linked: 'p/mig-a' });
  eq(r.draws.filter(d => d.run).length, 1, 'one draw on the first load');
  eq(r.s.calls.filter(c => c === 'run:p/mig-a/').length, 1, 'the run\'s one call, once');
  eq(r.s.calls.filter(c => c === 'blob:p/mig-a/plan.json').length, 1, 'its plan, once');
  eq(r.s.calls.filter(c => c === 'blob:retention-status.json').length, 1, 'the cleanup record, once');
  eq(r.s.calls.filter(c => c === 'list').length, 1, 'the list, once');
  eq(r.s.calls.length, 5, 'five calls in all: the list, the run, its manifest, its plan, the cleanup record');
});

/* ---- the part read later still arrives ---- */

test('the list still arrives and fills the picker, after the run is drawn', async () => {
  const r = await load({ linked: 'p/mig-a' });
  eq(globalThis.runRows.map(x => x.r).sort(), ['p/mig-a', 'p/mig-b'], 'every migration, no assessment');
  const last = globalThis.panelDraws[globalThis.panelDraws.length - 1];
  eq(last, { rows: 2, reading: false }, 'the picker is drawn with the list, and no longer says it is reading');
  eq(globalThis.currentRun, 'p/mig-a', 'the named run stays open');
  eq(globalThis.showingRun, 'p/mig-a');
  ok(r.draws.length >= 1, 'drawn');
});

/* ---- the same drawing ---- */

test('what is drawn is what the old order drew for the same run', async () => {
  await load({ linked: 'p/mig-b' });
  const early = snapshot();
  // Nothing named: the list chooses the newest, p/mig-b, and it is drawn after the list.
  const r = await load({});
  eq(r.beforeList, [], 'nothing named: nothing is drawn before the list');
  eq(snapshot(), early, 'the same run, the same documents');
  eq(early.vms.length, 2, 'p/mig-b has two machines');
  eq(early.events.length, 1, 'its log');
});

test('nothing named: the newest migration is drawn after the list, as before', async () => {
  const r = await load({});
  eq(r.draws.map(d => d.run), ['p/mig-b'], 'the newest');
  ok(r.draws[0].listAnswered, 'after the list');
  eq(r.s.calls.filter(c => c.startsWith('run:')).length, 1, 'one run call');
});

/* ---- a run named but not drawn early ---- */

test('a link to an assessment is not drawn; the list chooses, as before', async () => {
  const r = await load({ linked: 'p/assess-1' });
  eq(r.beforeList, [], 'not drawn early');
  eq(r.draws.map(d => d.run), ['p/mig-b'], 'the list\'s choice is drawn');
  eq(globalThis.showingRun, 'p/mig-b');
});

test('a link to a run that is gone is not drawn; the list chooses, as before', async () => {
  const r = await load({ linked: 'p/mig-gone' });
  eq(r.beforeList, [], 'not drawn early');
  eq(r.draws.map(d => d.run), ['p/mig-b']);
});

test('a run outside ?project= is not drawn early', async () => {
  const files = store();
  files['q/project.json'] = { projectId: 'q' };
  files['q/mig-q/run.json'] = { runId: 'mig-q', kind: 'migration' };
  const r = await load({ files, remembered: 'p/mig-a', search: '?project=q' });
  eq(r.beforeList, [], 'the run looked at last is in another project');
  eq(r.s.calls.filter(c => c === 'run:p/mig-a/' || c === 'blob:p/mig-a/run.json').length, 0, 'and it is not read');
});

/* ---- a run the list does not hold leaves nothing behind ---- */

function withoutA(files) {
  const f = {};
  for (const k of Object.keys(files)) { if (!k.startsWith('p/mig-a/')) { f[k] = files[k]; } }
  return f;
}

test('a named run the list does not hold: the list\'s choice is drawn from its own documents (run call answers late)', async () => {
  const files = store();
  const r = await load({ files, listFiles: withoutA(files), linked: 'p/mig-a', hold: ['run:p/mig-a/'],
    afterRelease: async (s) => { s.release('run:p/mig-a/'); await tickOver(); } });
  eq(globalThis.currentRun, 'p/mig-b', 'the list chose another run');
  eq(globalThis.showingRun, 'p/mig-b', 'and the page shows it');
  eq(globalThis.allVms.map(v => v.vmId).sort(), ['/subscriptions/x/p/mig-b-vm0', '/subscriptions/x/p/mig-b-vm1'], 'with its own machines');
  eq(globalThis.planDoc.entries.length, 2, 'and its own plan');
  ok(r.draws.some(d => d.run === 'p/mig-b'), 'drawn');
});

test('a named run the list does not hold: the list\'s choice is drawn (a machine record answers late)', async () => {
  const files = store();
  const r = await load({ files, listFiles: withoutA(files), linked: 'p/mig-a', hold: ['blob:p/mig-a/state/vm0.json'],
    docsFail: (key) => key === 'run:p/mig-a/',
    afterRelease: async (s) => { s.release('blob:p/mig-a/state/vm0.json'); await tickOver(); } });
  eq(globalThis.currentRun, 'p/mig-b');
  eq(globalThis.showingRun, 'p/mig-b', 'and the page shows it');
  eq(globalThis.allVms.length, 2, 'with its own machines');
  eq(globalThis.planDoc.entries.length, 2, 'and its own plan');
  ok(r.draws.some(d => d.run === 'p/mig-b'), 'drawn');
});

test('a named run the list does not hold, whose manifest answers after the list: the list\'s choice stays', async () => {
  const files = store();
  const r = await load({ files, listFiles: withoutA(files), linked: 'p/mig-a', hold: ['blob:p/mig-a/run.json'],
    afterRelease: async (s) => { s.release('blob:p/mig-a/run.json'); await tickOver(); } });
  eq(globalThis.currentRun, 'p/mig-b', 'the list chose first, and its choice is not taken back');
  eq(globalThis.showingRun, 'p/mig-b');
  eq(r.draws.filter(d => d.run).map(d => d.run), ['p/mig-b'], 'only the list\'s choice is drawn');
});

test('a run read late, after a person switched to another run, leaves none of its documents behind', async () => {
  const s = service(store(), { hold: ['run:p/mig-a/'] });
  page(s, {});
  globalThis.currentRun = 'p/mig-a';
  const late = M.refreshRun(M.tickReads());
  await tickOver();
  globalThis.currentRun = 'p/mig-b';
  await M.refreshRun(M.tickReads());
  eq(globalThis.showingRun, 'p/mig-b');
  s.release('run:p/mig-a/');
  await late;
  eq(globalThis.planDoc.entries.length, 2, 'the plan is still the plan of the run on screen');
  eq(globalThis.allVms.length, 2, 'and so are the machines');
  eq(globalThis.lastAssessment, { vms: [] }, 'and the assessment');
});

/* ---- the code ---- */

test('start() runs the first load through firstLoad, after the controls are wired', () => {
  const src = pageSource(path.join(DASH, 'migrations.html'));
  const body = src.slice(src.indexOf('async function start()'), src.indexOf('async function boot()'));
  ok(/await asOneLoad\(\(\) => firstLoad\(tickReads\(\)\)\)/.test(body), 'start() awaits firstLoad');
  ok(!/await loadRuns\(/.test(body), 'start() no longer waits for the list itself');
  const keydown = body.indexOf("addEventListener('keydown'");
  ok(keydown > 0 && keydown < body.indexOf('firstLoad(tickReads())'), 'the Escape handler is wired before the first read');
});

run('migrations-load');
