/* PERF-PROBES-1, 2026-11-03. The pages stop reading store files that a
 * listing they hold already shows are not there.
 *
 * WHAT WAS MEASURED (PERF-ANALYSIS-1, "Measured", sections 1 and 5): 9,949 of
 * 37,813 store reads in 7 days answered 404 (26%). Each is a call to the
 * service, and on a cold instance it costs as much as a real read. From the
 * code, the reads that a page could know were not there:
 *
 *   Overview   project.json AND run.json for every top-level folder - one of
 *              the two is always missing;
 *   Projects   project.json for each run outside a project, while the listing
 *              read beside it already showed the file was absent;
 *   Migrations halt.flag, the acknowledgement, plan-approval.json and
 *              plan-run.json of the open run before they exist, and one log
 *              part past the last, every 15 seconds;
 *   Reports    plan.json, in the Safety copies card, for a run that has no
 *              machine document (a run at setup has no plan at all). The card
 *              was on the Overview until PAGE-SCALE-REPORTS-1 moved it.
 *
 * THE RULES HELD HERE, each by counting the reads a fake store answers:
 *   - a file that a listing the page holds does not name is not read;
 *   - a listing the page could not read, or one the service cut short, is not
 *     proof that a file is absent: the page asks, as before (unknown means ask);
 *   - nothing the page shows changes;
 *   - the Overview and Projects send a project's document and its runs'
 *     manifests together, after the one listing (the shape with the shorter
 *     wall time - see the item);
 *   - the open run on Migrations is listed ONCE a tick, and every file and
 *     folder it reads comes from that listing.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// PAGE-LOAD-2: the Migrations page's one calls fail here, so its reads go to the fake store.
const { perFileHelp, perFileGlobals } = require('./_held');
// STORE-HOLDS-ONE-1: the census of storeHolds reads code only, with the scanner Get-VmfCodeOnly is held to.
const { scan, scriptsOf, FILES: SINK_FILES } = require('./_html-sinks');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
globalThis.STORE_READ_LIMIT = Number((HELP.match(/const STORE_READ_LIMIT = (\d+);/) || [])[1]);
globalThis.LOG_PARTS_MAX = Number((HELP.match(/const LOG_PARTS_MAX = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);

const help = liftAll('help.js', ['mapLimited', 'runFolderIsRun', 'runKind', 'runSummaryOf', 'runWaitingCount',
  'runGateTag', 'runGroup', 'readLimiter']);
const logs = liftAll('help.js', ['nextLogPart', 'readLogParts', 'readLogEvents']);

const ticks = async (n) => { for (let i = 0; i < n; i++) { await new Promise(r => setTimeout(r, 0)); } };

/* ---- a store that answers like the service ---------------------------
 *
 * A listing with the delimiter names the files at that level and the folders
 * under it (the folder names without the slash, as the service gives them);
 * without it, every file under the prefix. A read of a file that is not there
 * answers null, as VmfHelp.storeBlob does for a 404, and is counted as one. */
function fakeStore(docs, opts) {
  const o = opts || {};
  const s = { reads: [], lists: [], missing: [], held: [] };
  s.storeList = async (getToken, apiUrl, prefix, delimiter) => {
    s.lists.push(`${prefix}|${delimiter || ''}`);
    if (o.listFails && o.listFails(prefix)) { throw new Error(`list ${prefix}: HTTP 500`); }
    const under = Object.keys(docs).filter(k => k.startsWith(prefix));
    const truncated = !!(o.truncated && o.truncated(prefix));
    if (delimiter !== '/') { return { names: under, prefixes: [], truncated }; }
    const names = [], prefixes = new Set();
    for (const k of under) {
      const rest = k.slice(prefix.length);
      const cut = rest.indexOf('/');
      if (cut < 0) { names.push(k); } else { prefixes.add(prefix + rest.slice(0, cut)); }
    }
    return { names, prefixes: [...prefixes], truncated };
  };
  s.storeBlob = async (getToken, apiUrl, p) => {
    s.reads.push(p);
    if (o.hold && o.hold(p)) { await new Promise(go => s.held.push(go)); }
    if (!(p in docs)) { s.missing.push(p); return null; }
    return JSON.parse(JSON.stringify(docs[p]));
  };
  s.readsOf = (p) => s.reads.filter(x => x === p).length;
  return s;
}

/* Two projects, two runs from before projects, and a folder that holds
 * neither document. Every migration has its status, so no read of the list
 * below can answer 404 except where a row of the item says the page cannot
 * know first (approval.json of an assessment nobody approved). */
function estate() {
  const now = new Date().toISOString();
  const status = (id) => ({ schemaVersion: 4, runId: id, updatedUtc: now, stateCounts: {}, running: [] });
  return {
    'proj1/project.json': { projectId: 'proj1', name: 'One', createdUtc: now },
    'proj1/a1/run.json': { runId: 'a1', kind: 'assessment' },
    'proj1/a1/assessment.json': { vms: [1, 2] },
    'proj1/a1/approval.json': { approvedBy: 'someone@example.com' },
    'proj1/m1/run.json': { runId: 'm1', kind: 'migration' },
    'proj1/m1/run-status.json': status('m1'),
    'proj2/project.json': { projectId: 'proj2', name: 'Two', createdUtc: now },
    'proj2/a2/run.json': { runId: 'a2', kind: 'assessment' },
    'proj2/a2/assessment.json': { vms: [1] },
    'proj2/m2/run.json': { runId: 'm2', kind: 'migration' },
    'proj2/m2/run-status.json': status('m2'),
    'old1/run.json': { runId: 'old1', kind: 'migration' },
    'old1/run-status.json': status('old1'),
    'old1/state/vm1.json': { vmId: 'vm1' },
    'old2/run.json': { runId: 'old2', kind: 'assessment' },
    'old2/assessment.json': { vms: [] },
    'old2/approval.json': { approvedBy: 'someone@example.com' },
    'stray/notes/readme.json': { note: 'not a run and not a project' },
  };
}

/* ---------------------------------------------------------------------- */
/* ---- the one rule, on all three pages ---------------------------------- */
/* ---------------------------------------------------------------------- */

/* STORE-HOLDS-ONE-1: the rule is written ONCE, in help.js (VmfHelp.storeHolds),
 * and the Overview, Projects and Migrations call it. PERF-PROBES-1 first put a
 * copy on each page, held to one list of cases; three copies were still three
 * places to change. The cases below hold the one copy, and the census after
 * them holds the pages to it. */
const HOLDS_CASES = [
  { what: 'no listing: not known, so ask', listing: null, path: 'r/halt.flag', want: true },
  { what: 'a listing the service cut short cannot say no', listing: { names: [], prefixes: [], truncated: true }, path: 'r/halt.flag', want: true },
  { what: 'a file the listing names', listing: { names: ['r/halt.flag'], prefixes: [] }, path: 'r/halt.flag', want: true },
  { what: 'a file the listing does not name', listing: { names: ['r/run.json'], prefixes: [] }, path: 'r/halt.flag', want: false },
  { what: 'a name is the whole path, not a part of one', listing: { names: ['r/halt.flag.old'], prefixes: [] }, path: 'r/halt.flag', want: false },
  { what: 'a folder is not a file', listing: { names: [], prefixes: ['r/plan.json'] }, path: 'r/plan.json', want: false },
  { what: 'a listing with no names list names nothing', listing: { prefixes: [] }, path: 'r/halt.flag', want: false },
];
let helpHolds = null;
try { helpHolds = lift('help.js', 'storeHolds'); } catch { helpHolds = null; }
test('help.js: storeHolds says yes only where the listing names the file, or cannot say', () => {
  ok(helpHolds, 'help.js has storeHolds');
  for (const c of HOLDS_CASES) { eq(helpHolds(c.listing, c.path), c.want, c.what); }
});

test('help.js gives the pages storeHolds (VmfHelp.storeHolds)', () => {
  const code = scan(HELP).code;
  const at = code.indexOf('window.VmfHelp = {');
  ok(at >= 0, 'help.js sets window.VmfHelp');
  const exported = code.slice(at, code.indexOf('};', at));
  ok(/[{,\s]storeHolds\s*[,}]/.test(exported), 'VmfHelp names storeHolds');
});

/* Code only (scan, the same scanner as Get-VmfCodeOnly): a comment that says
 * why a page no longer has its own copy is not a copy. */
const HOLDS_PAGES = ['index.html', 'projects.html', 'migrations.html'];
const ALL_PAGES = SINK_FILES.filter(f => f !== 'help.js');
function holdsUses(file) {
  const code = scriptsOf(file).map(sc => scan(sc.text).code).join('\n');
  return {
    defines: /\bfunction\s+storeHolds\b|\b(?:const|let|var)\s+storeHolds\b|\bstoreHolds\s*[:=](?!=)/.test(code),
    bare: (code.match(/(?<![\w$.])storeHolds\s*\(/g) || []).length,
    shared: (code.match(/\bVmfHelp\.storeHolds\s*\(/g) || []).length,
  };
}

test('the census reads code, not comments, and finds a copy where one is', () => {
  const comment = scan('/* function storeHolds(listing, path) { } */\n// storeHolds(l, p)\nconst x = 1;').code;
  ok(!/storeHolds/.test(comment), 'a comment is not code');
  const copy = scan('function storeHolds(listing, path) { return true; }\nstoreHolds(l, p);').code;
  ok(/\bfunction\s+storeHolds\b/.test(copy) && /(?<![\w$.])storeHolds\s*\(/.test(copy), 'a copy and a bare call are found');
  ok(ALL_PAGES.length > 5 && ALL_PAGES.includes('index.html'), `the census reads the pages (${ALL_PAGES.length})`);
});

test('no dashboard page has its own storeHolds, and every call is to the one in help.js', () => {
  const offenders = [];
  for (const file of ALL_PAGES) {
    const u = holdsUses(file);
    if (u.defines) { offenders.push(`${file} defines its own storeHolds`); }
    if (u.bare) { offenders.push(`${file} calls storeHolds ${u.bare} time(s) without VmfHelp`); }
  }
  ok(offenders.length === 0, offenders.join('; '));
});

test('the Overview, Projects and Migrations still ask the rule before they read', () => {
  for (const file of HOLDS_PAGES) { ok(holdsUses(file).shared > 0, `${file} calls VmfHelp.storeHolds`); }
});

/* ---------------------------------------------------------------------- */
/* ---- the Overview ------------------------------------------------------ */
/* ---------------------------------------------------------------------- */

function overviewNames() {
  // PAGE-LOAD-1: the list of runs (startedRuns) is gone, and the page reads
  // what it draws in one call (readHeld). These tests measure the per-file
  // reads, which the page still makes when that call fails - so it fails here.
  const base = ['readHeld', 'blobList', 'blobJson', 'load', 'readRun', 'migrationFacts'];
  return base;
}
const overview = liftAll('index.html', overviewNames());

function overviewPage(s) {
  globalThis.cfg = { apiUrl: 'https://service.example.com/api', apiAppId: 'x' };
  globalThis.getToken = async () => 'token';
  globalThis.fetch = async () => ({ ok: true, json: async () => [] });
  globalThis.DEMO_MODE = false;
  globalThis.state = { projects: [], loose: [], runs: [] };
  globalThis.held = null;
  globalThis.PANEL_READS = [];
  globalThis.render = () => {};
  globalThis.esc = (v) => String(v ?? '');
  globalThis.ago = () => '';
  globalThis.runLink = (id) => `#${id}`;
  globalThis.UX = new Proxy({}, { get: () => '' });
  const card = { innerHTML: '' };
  globalThis.document = { createElement: () => card };
  globalThis.$ = () => ({ appendChild: () => {} });
  s.ledgers = [];
  globalThis.VmfHelp = {
    mapLimited: help.mapLimited, runFolderIsRun: help.runFolderIsRun, runKind: help.runKind,
    storeList: s.storeList, storeBlob: s.storeBlob, storeHolds: helpHolds,
    runSummaryOf: help.runSummaryOf, runWaitingCount: help.runWaitingCount, runGateTag: help.runGateTag,
    runGroup: help.runGroup,
    retentionPassFacts: () => ({ ran: false, unfinished: false, failures: [], nextUtc: null }),
    safetyCopyLedger: (docsIn, entries) => { s.ledgers.push({ docs: docsIn.length, entries: (entries || []).length }); return docsIn; },
    safetyCopySummary: (rows) => ({ copies: rows.length, machines: rows.length, due: 0, unlocked: 0, earliestDueUtc: null }),
    // PAGE-LOAD-1: the one call fails, so every read below is a per-file read.
    storeDocs: async () => { throw new Error('the per-file reads are what these tests measure'); },
    heldList: () => undefined, heldJson: () => undefined,
  };
  globalThis.storeRead = help.readLimiter();
  return card;
}
const overviewShows = () => ({
  projects: globalThis.state.projects.map(p => `${p.id}:${p.assessments}/${p.migrations}`),
  loose: globalThis.state.loose,
  runs: globalThis.state.runs.map(r => `${r.id}:${r.kind}:${r.projectId}`).sort(),
});
const OVERVIEW_SHOWS = {
  projects: ['proj1:1/1', 'proj2:1/1'],
  loose: ['old1', 'old2'],
  runs: ['old1:migration:null', 'old2:assessment:null', 'proj1/a1:assessment:proj1', 'proj1/m1:migration:proj1',
    'proj2/a2:assessment:proj2', 'proj2/m2:migration:proj2'],
};

test('THE DEFECT, Overview: a top-level folder is asked only for the document its listing names', async () => {
  const s = fakeStore(estate());
  overviewPage(s);
  await overview.load();
  eq(s.readsOf('old1/project.json'), 0, 'a run outside a project is not asked for a project document');
  eq(s.readsOf('old2/project.json'), 0, 'nor is an assessment outside a project');
  eq(s.readsOf('proj1/run.json'), 0, 'a project is not asked for a run manifest of its own');
  eq(s.readsOf('proj2/run.json'), 0, 'nor is the second project');
  eq(s.readsOf('stray/project.json') + s.readsOf('stray/run.json'), 0, 'a folder with neither is asked for nothing');
  eq(s.readsOf('proj1/project.json'), 1, 'a project document, once');
  eq(s.readsOf('old1/run.json'), 1, 'a run outside a project, its manifest once');
});

test('Overview: a load reads nothing that is not there, except an approval nobody gave', async () => {
  // approval.json is the item's one "No" row: what the page reads cannot say
  // whether an assessment was approved, so proj2/a2's unapproved one is still
  // asked for. Every other read of a load must find its file.
  const s = fakeStore(estate());
  overviewPage(s);
  await overview.load();
  eq(s.missing.filter(p => !p.endsWith('/approval.json')), [], 'reads that found nothing');
  eq(s.missing, ['proj2/a2/approval.json'], 'the one read the page cannot know first');
});

test('Overview: the page shows the same projects, runs and counts', async () => {
  const s = fakeStore(estate());
  overviewPage(s);
  await overview.load();
  eq(overviewShows(), OVERVIEW_SHOWS);
});

test('Overview, UNKNOWN MEANS ASK: a folder whose listing fails is asked both questions, as before', async () => {
  const s = fakeStore(estate(), { listFails: (prefix) => prefix === 'old1/' || prefix === 'proj1/' });
  overviewPage(s);
  let threw = null;
  try { await overview.load(); } catch (e) { threw = e.message; }
  eq(s.readsOf('old1/project.json'), 1, 'the project document is asked for');
  eq(s.readsOf('old1/run.json'), 1, 'and the run manifest');
  eq(s.readsOf('proj1/project.json'), 1, 'a project whose listing fails is still read');
  ok(globalThis.state.loose.includes('old1') || threw, 'the run is still found');
});

test('Overview: a listing the service cut short is not proof that a file is absent', async () => {
  const s = fakeStore(estate(), { truncated: (prefix) => prefix === 'old1/' });
  overviewPage(s);
  await overview.load();
  eq(s.readsOf('old1/project.json'), 1, 'asked, because the listing could not say');
  eq(overviewShows(), OVERVIEW_SHOWS, 'and the page shows the same');
});

test('Overview, THE SHAPE: a project document and its runs\' manifests are asked together, after one listing', async () => {
  // Before: two reads together (one always 404), then the listing, then the
  // runs - three round trips for a project. After: the listing, then the
  // document beside the runs - two.
  const s = fakeStore(estate(), { hold: (p) => p === 'proj1/project.json' });
  overviewPage(s);
  const loading = overview.load();
  await ticks(30);
  ok(s.held.length >= 1, 'the project document was asked for');
  ok(s.reads.includes('proj1/a1/run.json') && s.reads.includes('proj1/m1/run.json'),
    'the runs of the project are asked for before its document answers');
  eq(s.lists.filter(l => l === 'proj1/|/').length, 1, 'one listing of the project folder');
  for (const go of s.held.splice(0)) { go(); }
  await loading;
  eq(overviewShows(), OVERVIEW_SHOWS, 'and every run is in the right project');
});

test('Overview: a folder that names a project document it cannot read is read as before', async () => {
  // The listing names project.json but the read fails: the page then asks for
  // a run manifest, as it did when both were asked at once.
  const docs = estate();
  docs['old1/project.json'] = { projectId: 'old1', name: 'Broken' };
  const s = fakeStore(docs);
  const blob = s.storeBlob;
  s.storeBlob = async (t, a, p) => (p === 'old1/project.json' ? (s.reads.push(p), null) : blob(t, a, p));
  overviewPage(s);
  await overview.load();
  eq(s.readsOf('old1/run.json'), 1, 'the manifest is asked for');
  ok(globalThis.state.loose.includes('old1'), 'and the run is listed outside a project, as before');
});

/* ---------------------------------------------------------------------- */
/* ---- the Safety copies card (on the Reports page since PAGE-SCALE-REPORTS-1) */
/* ---------------------------------------------------------------------- */

const reportsCopies = liftAll('reports.html', ['blobFetch', 'blobList', 'copiesRunIds', 'copiesFacts']);

function copiesPage(s) {
  globalThis.cfg = { apiUrl: 'https://service.example.com/api', apiAppId: 'x' };
  globalThis.getToken = async () => 'token';
  globalThis.DEMO_MODE = false;
  globalThis.held = null;
  globalThis.esc = (v) => String(v ?? '');
  globalThis.UX = new Proxy({}, { get: () => '' });
  globalThis.blobFetch = reportsCopies.blobFetch;
  globalThis.blobList = reportsCopies.blobList;
  const card = { innerHTML: '', className: '' };
  globalThis.document = { getElementById: (id) => (id === 'copies-card' ? card : null) };
  // The migrations the page listed: every run that is not an assessment.
  globalThis.rows = [{ r: 'proj1/m1' }, { r: 'proj2/m2' }, { r: 'old1' }];
  globalThis.storeRuns = globalThis.rows.map(x => x.r);
  globalThis.assessmentIds = new Set();
  globalThis.copiesRunIds = reportsCopies.copiesRunIds;
  s.ledgers = [];
  globalThis.VmfHelp = {
    mapLimited: help.mapLimited, readLimiter: help.readLimiter,
    storeList: s.storeList, storeBlob: s.storeBlob,
    retentionPassFacts: () => ({ ran: false, unfinished: false, failures: [], nextUtc: null }),
    safetyCopyLedger: (docsIn, entries) => { s.ledgers.push({ docs: docsIn.length, entries: (entries || []).length }); return docsIn; },
    safetyCopySummary: (rows) => ({ copies: rows.length, machines: rows.length, due: 0, unlocked: 0, earliestDueUtc: null }),
    // PAGE-LOAD-1: the one call failed, so every read below is a per-file read.
    heldList: () => undefined, heldJson: () => undefined,
    VmfRun: { link: (page, id) => `${page}#${id}` },
  };
  return card;
}

test('THE DEFECT, Safety copies card: a migration with no machine document is not asked for its plan', async () => {
  const docs = estate();
  docs['old1/plan.json'] = { entries: [{ vmId: 'vm1', path: 'A', wave: 'w1' }] };
  const s = fakeStore(docs);
  copiesPage(s);
  try {
    await reportsCopies.copiesFacts();
    eq(s.readsOf('proj1/m1/plan.json'), 0, 'a run with no machine document (it never ran, or it is at setup)');
    eq(s.readsOf('proj2/m2/plan.json'), 0, 'the second one');
    eq(s.readsOf('old1/plan.json'), 1, 'a run with machine documents is asked for its plan, once');
    eq(s.missing.filter(p => p !== 'retention-status.json'), [], 'no read that found nothing');
    const withDocs = s.ledgers.find(l => l.docs > 0);
    ok(withDocs && withDocs.entries === 1, 'the plan entries reach the ledger beside the documents');
  } finally { delete globalThis.document; }
});

test('Safety copies card: the plan is asked beside the machine documents, not after them', async () => {
  const docs = estate();
  docs['old1/plan.json'] = { entries: [] };
  const s = fakeStore(docs, { hold: (p) => p === 'old1/state/vm1.json' });
  copiesPage(s);
  try {
    const drawing = reportsCopies.copiesFacts();
    await ticks(30);
    ok(s.held.length >= 1, 'the machine document was asked for');
    ok(s.reads.includes('old1/plan.json'), 'the plan was asked before the machine document answered');
    for (const go of s.held.splice(0)) { go(); }
    await drawing;
  } finally { delete globalThis.document; }
});
/* ---------------------------------------------------------------------- */
/* ---- Projects ---------------------------------------------------------- */
/* ---------------------------------------------------------------------- */

function projectsNames() {
  // CLICKS-LOST-1: load keeps a project made on the page (withMade).
  // PAGE-SCALE-PROJECTS-1: and reads each migration's status for the count that waits for a person.
  const base = ['blobList', 'blobJson', 'load', 'withMade', 'latestTime', 'migrationWaiting'];
  return base;
}
const projectsPage = liftAll('projects.html', projectsNames());

function projectsSetup(s) {
  globalThis.cfg = { apiUrl: 'https://service.example.com/api', apiAppId: 'x' };
  globalThis.getToken = async () => 'token';
  globalThis.DEMO_MODE = false;
  globalThis.render = () => {};
  globalThis.byName = (a, b) => String(a.name).localeCompare(String(b.name));
  globalThis.projects = [];
  globalThis.loose = [];
  Object.assign(globalThis, { withMade: projectsPage.withMade, latestTime: projectsPage.latestTime, migrationWaiting: projectsPage.migrationWaiting,
                              madeHere: new Map(), loadTurn: 0, drawListWhenFree: () => {} });
  globalThis.VmfHelp = { mapLimited: help.mapLimited, runFolderIsRun: help.runFolderIsRun, runKind: help.runKind,
    runSummaryOf: help.runSummaryOf, runWaitingCount: help.runWaitingCount,
    storeList: s.storeList, storeBlob: s.storeBlob, storeHolds: helpHolds,
    // PAGE-LOAD-1: the one call fails, so the page makes the per-file reads
    // these tests measure (page-load.test.js measures the one call).
    storeDocs: async () => { throw new Error('per-file reads measured here'); }, heldList: () => undefined, heldJson: () => undefined, heldHas: () => undefined, };
  globalThis.held = null;
  globalThis.LIST_READS = [];
  globalThis.storeRead = help.readLimiter();
}
const projectsShow = () => ({
  projects: globalThis.projects.map(p => `${p.id}:${p.assessments}/${p.migrations}`),
  loose: globalThis.loose,
});
const PROJECTS_SHOW = { projects: ['proj1:1/1', 'proj2:1/1'], loose: ['old1', 'old2', 'stray'] };

test('THE DEFECT, Projects: a folder whose listing names no project document is not asked for one', async () => {
  const s = fakeStore(estate());
  projectsSetup(s);
  await projectsPage.load();
  for (const f of ['old1', 'old2', 'stray']) { eq(s.readsOf(`${f}/project.json`), 0, `${f}/project.json`); }
  eq(s.readsOf('proj1/project.json'), 1, 'a project, once');
  eq(s.missing, [], 'reads that found nothing');
  eq(s.lists.filter(l => l === 'proj1/|/').length, 1, 'one listing of a project folder, not two');
});

test('Projects: the page shows the same projects, counts and runs outside a project', async () => {
  const s = fakeStore(estate());
  projectsSetup(s);
  await projectsPage.load();
  eq(projectsShow(), PROJECTS_SHOW);
});

test('Projects, THE SHAPE: a project document and its runs\' manifests are asked together, after one listing', async () => {
  const s = fakeStore(estate(), { hold: (p) => p === 'proj2/project.json' });
  projectsSetup(s);
  const loading = projectsPage.load();
  await ticks(30);
  ok(s.held.length >= 1, 'the project document was asked for');
  ok(s.reads.includes('proj2/a2/run.json') && s.reads.includes('proj2/m2/run.json'),
    'the runs are asked for before the project document answers');
  for (const go of s.held.splice(0)) { go(); }
  await loading;
  eq(projectsShow(), PROJECTS_SHOW);
});

test('Projects, UNKNOWN MEANS ASK: a folder whose listing fails or is cut short is asked for its document', async () => {
  let failing = true;
  const s = fakeStore(estate(), {
    listFails: (prefix) => failing && prefix === 'proj1/',
    truncated: (prefix) => prefix === 'old1/',
  });
  projectsSetup(s);
  // The second listing of proj1 (for its runs) answers.
  const list = s.storeList;
  s.storeList = async (...a) => { const r = list(...a); if (a[2] === 'proj1/') { failing = false; } return r; };
  globalThis.VmfHelp.storeList = s.storeList;
  await projectsPage.load();
  eq(s.readsOf('proj1/project.json'), 1, 'the project whose listing failed');
  eq(s.readsOf('old1/project.json'), 1, 'the folder whose listing was cut short');
  eq(projectsShow(), PROJECTS_SHOW, 'and the page shows the same');
});

/* ---------------------------------------------------------------------- */
/* ---- Migrations: the open run, every tick ------------------------------- */
/* ---------------------------------------------------------------------- */

const refreshRun = lift('migrations.html', 'refreshRun');
let tickReads = null;
try { tickReads = lift('migrations.html', 'tickReads'); } catch { tickReads = null; }
let runListed = null;
try { runListed = lift('migrations.html', 'runListed'); } catch { runListed = null; }

/* The page's LIVE source, as it is written, over a fake blobFetch and
 * blobList - so the log parts are read by the page's own reader and help.js's
 * own walk, not by a stand-in that could agree with whatever the test wants. */
globalThis.DEMO_MODE = false;
const liveSource = liftConst('migrations.html', 'source');

const RUN = 'p/mig';
function runStore(extra) {
  const lines = (n, at) => Array.from({ length: n }, (_, i) => JSON.stringify({ tsUtc: '2026-11-03T10:00:00Z', step: 'X', n: at + i })).join('\n');
  const docs = {
    [`${RUN}/run.json`]: { runId: 'mig', kind: 'migration' },
    [`${RUN}/run-status.json`]: { schemaVersion: 4, runId: 'mig', updatedUtc: '2026-11-03T10:00:00Z', stateCounts: {}, running: [] },
    [`${RUN}/plan.json`]: { entries: [{ vmId: 'vm1', path: 'A', wave: 'w1' }] },
    [`${RUN}/state/vm1.json`]: { vmId: 'vm1', state: 'PLANNED' },
    [`${RUN}/capacity/cell1.json`]: { cell: 'c1' },
    [`${RUN}/schedules/w1.json`]: { wave: 'w1' },
    [`${RUN}/approvals/w1.json`]: { wave: 'w1', approvedBy: 'someone@example.com' },
    [`${RUN}/acceptances/wave-options-w1.json`]: { wave: 'w1' },
    [`${RUN}/logs/events.jsonl`]: lines(3, 1),
    [`${RUN}/evidence/vm1-prep.json`]: { ok: true },
  };
  return Object.assign(docs, extra || {});
}

function migrationsPage(docs, opts) {
  const o = opts || {};
  const s = { reads: [], lists: [], missing: [] };
  globalThis.blobFetch = async (p, how) => {
    s.reads.push(p);
    if (o.readFails && o.readFails(p)) { throw new Error(`read ${p}: HTTP 500`); }
    if (!(p in docs)) { s.missing.push(p); return null; }
    const d = docs[p];
    if (how && how.asVersioned) { return { text: JSON.stringify(d), version: 'v1' }; }
    if (how && how.asText) { return typeof d === 'string' ? d : JSON.stringify(d); }
    return typeof d === 'string' ? d : JSON.parse(JSON.stringify(d));
  };
  const store = fakeStore(docs, { listFails: o.listFails, truncated: o.truncated });
  globalThis.blobList = async (prefix, delimiter) => { s.lists.push(prefix); return store.storeList(null, null, prefix, delimiter); };
  const err = { textContent: '', style: { display: 'none' } };
  const els = { '#err': err, '#live-ind': { className: '', title: '' } };
  Object.assign(globalThis, {
    source: liveSource, currentRun: RUN, showingRun: RUN,
    showReadingRun() { }, clearReadingRun() { }, async renderFirstRun() { },
    nameMachines() { }, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis() { }, renderNextStep() { }, renderFound() { }, renderWaves() { }, refreshDrill() { },
    renderCapacity() { }, renderSafetyCopies() { }, renderEvents() { }, ago: () => 'a while ago',
    planDoc: null, runAck: null, runStop: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null,
    lastAssessment: null, schedules: new Map(), acceptances: new Map(), approvals: new Map(),
    allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false, discardInFlight: new Map(), latestEvents: [],
    restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    $: (sel) => els[sel] ?? null,
    tickReads, runListed, ...perFileGlobals(),
    // CLICKS-LOST-1: no control is held here, so the drawing runs at once.
    runRegions: () => [],
    VmfHelp: {
      ...perFileHelp(),
      mapLimited: help.mapLimited, readLogEvents: logs.readLogEvents,
      explain: (e) => String(e && e.message ? e.message : e),
      drawWhenFree: (regions, draw) => { draw(); return true; },
    },
  });
  // help.js's log walk calls these by name.
  globalThis.nextLogPart = logs.nextLogPart;
  globalThis.readLogParts = logs.readLogParts;
  s.readsOf = (rel) => s.reads.filter(x => x === `${RUN}/${rel}`).length;
  s.listsOf = (rel) => s.lists.filter(x => x === `${RUN}/${rel}`).length;
  return { s, err };
}
const tick = () => refreshRun(tickReads ? tickReads() : undefined);
const NOT_YET = ['halt.flag', 'acknowledgements/infrastructure-as-code.json', 'plan-approval.json', 'plan-run.json',
  'assessment.json'];

test('THE DEFECT, Migrations: the open run reads no file that its listing does not name', async () => {
  const { s, err } = migrationsPage(runStore());
  await tick();
  eq(err.textContent, '', 'the run was drawn');
  for (const rel of NOT_YET) { eq(s.readsOf(rel), 0, rel); }
  // The daily cleanup's record is at the store root, outside the run, and is
  // there after its first pass; this fake store has had none.
  eq(s.missing, ['retention-status.json'], 'reads that found nothing');
});

test('Migrations: no log part is read past the last one the listing names', async () => {
  const { s } = migrationsPage(runStore({ [`${RUN}/logs/events-2.jsonl`]: JSON.stringify({ tsUtc: '2026-11-03T11:00:00Z', step: 'Y' }) }));
  await tick();
  eq(s.readsOf('logs/events.jsonl'), 1, 'part 1');
  eq(s.readsOf('logs/events-2.jsonl'), 1, 'part 2');
  eq(s.readsOf('logs/events-3.jsonl'), 0, 'no part 3, which the listing does not name');
  eq(globalThis.latestEvents.length, 4, 'every line of both parts reached the page');
});

test('Migrations: a run with no log yet is not asked for one', async () => {
  const docs = runStore();
  delete docs[`${RUN}/logs/events.jsonl`];
  const { s, err } = migrationsPage(docs);
  await tick();
  eq(s.readsOf('logs/events.jsonl'), 0, 'the first part');
  eq(globalThis.latestEvents, [], 'no events');
  eq(err.textContent, '');
});

test('Migrations: ONE listing of the run a tick, and the five folders come from it', async () => {
  const { s } = migrationsPage(runStore());
  await tick();
  eq(s.lists, [`${RUN}/`], 'the listings this tick sent');
  eq(globalThis.allVms.map(v => v.vmId), ['vm1'], 'the machine documents');
  eq(globalThis.latestClaims.length, 1, 'the capacity documents');
  eq([...globalThis.schedules.keys()], ['w1'], 'the schedules');
  eq([...globalThis.approvals.keys()], ['w1'], 'the approvals');
  eq([...globalThis.acceptances.keys()], ['w1'], 'the acceptances');
  eq(s.readsOf('evidence/vm1-prep.json'), 0, 'a file the page does not show is not read');
  await tick();
  eq(s.lists, [`${RUN}/`, `${RUN}/`], 'the next tick lists the run again: a listing is never kept');
});

test('Migrations: every file the listing names is read, and drawn', async () => {
  const { s } = migrationsPage(runStore({
    [`${RUN}/halt.flag`]: { by: 'someone@example.com' },
    [`${RUN}/acknowledgements/infrastructure-as-code.json`]: { acknowledgedBy: 'someone@example.com' },
    [`${RUN}/plan-approval.json`]: { planHash: 'v1' },
    [`${RUN}/plan-run.json`]: { next: 'w1' },
    [`${RUN}/assessment.json`]: { vms: [1] },
  }));
  await tick();
  for (const rel of NOT_YET) { eq(s.readsOf(rel), 1, rel); }
  eq(globalThis.latestHalted, true, 'the pause is shown');
  ok(globalThis.runAck && globalThis.runAck.acknowledgedBy, 'the acknowledgement');
  eq(globalThis.planSignoffCurrent, true, 'the sign-off, for the plan as it stands');
  ok(globalThis.planRunStatus && globalThis.planRunStatus.next === 'w1', 'what the plan does next');
  ok(globalThis.lastAssessment, 'the assessment');
});

test('Migrations, UNKNOWN MEANS ASK: when the listing fails, every read is made as before', async () => {
  const { s, err } = migrationsPage(runStore(), { listFails: (prefix) => prefix === `${RUN}/` });
  await tick();
  eq(err.textContent, '', 'the run was still drawn');
  for (const rel of NOT_YET) { eq(s.readsOf(rel), 1, rel); }
  eq(s.readsOf('logs/events-2.jsonl'), 1, 'the log is walked to the first part that is not there');
  for (const f of ['state', 'capacity', 'schedules', 'approvals', 'acceptances']) {
    eq(s.listsOf(`${f}/`), 1, `the ${f} folder is listed`);
  }
  eq(globalThis.allVms.map(v => v.vmId), ['vm1'], 'the machine documents');
});

test('Migrations: a listing the service cut short is read as no listing', async () => {
  const { s } = migrationsPage(runStore(), { truncated: (prefix) => prefix === `${RUN}/` });
  await tick();
  for (const rel of NOT_YET) { eq(s.readsOf(rel), 1, rel); }
  eq(s.listsOf('state/'), 1, 'the state folder is listed');
  eq(s.readsOf('logs/events-2.jsonl'), 1, 'the log is walked as before');
});

test('Migrations: a pause flag that cannot be read still stops the refresh, as before', async () => {
  // The flag is the one read here with no catch: a run that may be paused must
  // not be drawn as running. Listed and unreadable keeps that.
  const { err } = migrationsPage(runStore({ [`${RUN}/halt.flag`]: { by: 'x' } }), { readFails: (p) => p === `${RUN}/halt.flag` });
  await tick();
  ok(/halt\.flag/.test(err.textContent), `the refresh says it could not read the flag: ${err.textContent}`);
});

test('Migrations: the demo keeps every read, because it has no listing', () => {
  const src = pageSource(path.join(DASH, 'migrations.html'));
  const demo = src.slice(src.indexOf('const source = DEMO_MODE ? {'), src.indexOf('} : {', src.indexOf('const source = DEMO_MODE ? {')));
  ok(/async listRun\(\) \{ return null; \}/.test(demo), 'the demo source answers "not known" for the listing');
});

run('perf-probes');
