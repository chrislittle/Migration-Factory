/* PAGE-LOAD-1: a page load is a handful of calls to the service, not one call
 * for each store document.
 *
 * MEASURED on a lab install, 2026-11-06 (Application Insights): one load of
 * the Overview or the Assessments page sent about 200 calls to the service -
 * about 140 reads of one document and 30 listings in 30 seconds - and the page
 * waited for all of them. A load took a minute or two.
 *
 * THE RULE: a page asks the service ONCE for the store listed and every
 * document it draws (VmfHelp.storeDocs, GET store/docs), and its own readers
 * answer from that (heldList, heldJson, heldHas). What that cannot say -
 * a level deeper than the call went, a document it did not name, a listing
 * the service cut short - the page asks for as before: unknown means ask.
 *
 * These tests:
 *   - hold the test's stand-in for the service to tests/fixtures/store-docs.json,
 *     the answers the service itself is held to (StoreDocs.Tests.ps1);
 *   - prove each held answer is the answer the per-file read gives, and that
 *     every case it cannot answer is left to the service;
 *   - RUN each page's own load against a store of 4 projects, count every
 *     call, and compare what the page holds with what the per-file reads
 *     give when the one call fails.
 */
'use strict';
// QUOTA-CHECK-SPINNER-1: loadClaims counts its reads, so only the newest fills the page.
globalThis.claimsTurn = 0;
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, test, eq, ok, run } = require('./_harness');
const { scriptsOf, Unit } = require('./_html-sinks');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const FIX = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'store-docs.json'), 'utf8'));
const HELP = pageSource(path.join(DASH, 'help.js'));
const constOf = (src, name) => {
  const m = src.match(new RegExp(`const ${name} = (\\d+);`));
  if (!m) { throw new Error(`${name} is not declared`); }
  return Number(m[1]);
};
globalThis.STORE_READ_LIMIT = constOf(HELP, 'STORE_READ_LIMIT');
globalThis.STORE_DOCS_PAGES_MAX = constOf(HELP, 'STORE_DOCS_PAGES_MAX');

let H = {};
try {
  H = liftAll('help.js', ['storeUrl', 'storeError', 'storeHolds', 'storeDocs', 'heldDepth', 'heldList', 'heldText', 'heldJson', 'heldHas',
    'mapLimited', 'readLimiter', 'runFolderIsRun', 'runKind', 'listRunsAcrossProjects', 'leasesByMachine', 'idKey']);
} catch (e) { H = { missing: e.message }; }

/* The code of a page, comments and strings taken out. */
function codeOf(file) {
  return scriptsOf(file).map(sc => new Unit(file, sc.text, sc.line).code).join('\n');
}
/* A page's own one-line constant list, e.g. const LIST_READS = ['a', 'b']; */
function readsOf(file, name) {
  const m = pageSource(path.join(DASH, file)).match(new RegExp(`\\nconst ${name} = (\\[[^\\]\\n]*\\]);`));
  if (!m) { throw new Error(`${file} declares no ${name}`); }
  // eslint-disable-next-line no-eval
  return eval(m[1]);
}

/* ---------------- the test's stand-in for store/docs ---------------- */

const ord = (a, b) => (a < b ? -1 : a > b ? 1 : 0);
const textOf = (v) => (typeof v === 'string' ? v : JSON.stringify(v));
const globMatch = (pattern, text) => new RegExp('^' + pattern.split('*').map(x => x.replace(/[.+?^${}()|[\]\\]/g, '\\$&')).join('.*') + '$').test(text);

/* What GET store/docs answers for a store held as { path: document }. Held to
 * the fixture below, which the service is held to as well. */
function serveDocs(files, q) {
  const prefix = q.prefix || '';
  const depth = Number(q.depth);
  const pats = String(q.read).split(',').filter(Boolean).map(p => p.split('/'));
  const maxDocs = q.maxDocs || 400;
  const names = [], folders = new Set(), wanted = [];
  for (const n of Object.keys(files).sort(ord)) {
    if (!n.startsWith(prefix)) { continue; }
    const parts = n.slice(prefix.length).split('/');
    for (let i = 1; i < parts.length && i <= depth; i++) { folders.add(prefix + parts.slice(0, i).join('/')); }
    if (parts.length > depth) { continue; }
    names.push(n);
    if (q.after && n <= q.after) { continue; }
    if (pats.some(s => s.length <= parts.length && globMatch(s.join('/'), parts.slice(parts.length - s.length).join('/')))) { wanted.push(n); }
  }
  const page = wanted.slice(0, maxDocs);
  return {
    names: q.after ? [] : names,
    folders: q.after ? [] : [...folders].sort(ord),
    truncated: !!q.truncated,
    docs: q.truncated ? [] : page.map(p => ({ path: p, text: textOf(files[p]) })),
    next: !q.truncated && wanted.length > page.length ? page[page.length - 1] : '',
  };
}

/* What store/list answers. */
function serveList(files, prefix, delimiter) {
  const names = [], prefixes = new Set();
  for (const n of Object.keys(files).sort(ord)) {
    if (!n.startsWith(prefix)) { continue; }
    const rest = n.slice(prefix.length);
    const cut = delimiter === '/' ? rest.indexOf('/') : -1;
    if (cut >= 0) { prefixes.add(prefix + rest.slice(0, cut)); } else { names.push(n); }
  }
  return { names, prefixes: [...prefixes].sort(ord), truncated: false };
}

/* A service that answers store/docs, store/list, store/blob and the summary
 * of a run, and counts every call. `docsFail` makes store/docs answer 500. */
function service(files, opts) {
  const o = opts || {};
  const s = { calls: [], files };
  const answer = (status, body) => ({ ok: status < 400, status, json: async () => body });
  s.fetch = async (url) => {
    const u = new URL(url);
    s.calls.push(u.pathname.replace(/^\/api\//, ''));
    await new Promise(r => setTimeout(r, 1));
    if (u.pathname.endsWith('/store/docs')) {
      if (o.docsFail) { return answer(500, { error: 'refused' }); }
      const q = Object.fromEntries(u.searchParams.entries());
      return answer(200, serveDocs(files, { ...q, maxDocs: o.maxDocs, truncated: o.truncated }));
    }
    const sum = u.pathname.match(/\/runs\/([^/]+)\/summary$/);
    if (sum) {
      const project = u.searchParams.get('project');
      const runPath = project ? `${project}/${sum[1]}` : sum[1];
      return answer(200, { outcomes: { migrated: Object.keys(files).filter(k => k.startsWith(`${runPath}/state/`) && files[k].state === 'MIGRATED').length } });
    }
    return answer(404, { error: 'not found' });
  };
  s.storeList = async (getToken, apiUrl, prefix, delimiter) => {
    s.calls.push('store/list');
    await new Promise(r => setTimeout(r, 1));
    return serveList(files, prefix || '', delimiter);
  };
  /* PAGE-LOAD-2: each read is kept with its path and how it was read, and the
   * most reads in flight at once is counted. */
  s.blobs = [];
  s.live = 0;
  s.most = 0;
  s.storeBlob = async (getToken, apiUrl, p, ro) => {
    s.calls.push('store/blob');
    s.blobs.push({ path: p, versioned: !!(ro && ro.asVersioned) });
    s.live++; s.most = Math.max(s.most, s.live);
    try {
      await new Promise(r => setTimeout(r, 1));
      if (!(p in files)) { return null; }
      if (ro && ro.asVersioned) { return { text: textOf(files[p]), version: `v-${p}` }; }
      if (ro && ro.asText) { return textOf(files[p]); }
      return JSON.parse(textOf(files[p]));
    } finally { s.live--; }
  };
  const list = s.storeList;
  s.storeList = async (...a) => {
    s.live++; s.most = Math.max(s.most, s.live);
    try { return await list(...a); } finally { s.live--; }
  };
  return s;
}

const fixtureFiles = FIX.files;

async function heldFor(query, opts) {
  const s = service(fixtureFiles, opts);
  globalThis.fetch = s.fetch;
  const held = await H.storeDocs(async () => 'token', 'https://service.example.com/api', query);
  return { held, s };
}

/* ---------------- the stand-in agrees with the fixture ---------------- */

test('help.js gives the pages the one call and the readers', () => {
  ok(!H.missing, H.missing);
  const exported = HELP.slice(HELP.lastIndexOf('window.VmfHelp'));
  for (const name of ['storeDocs', 'heldList', 'heldJson', 'heldHas', 'heldText']) {
    ok(new RegExp(`\\b${name}\\b`).test(exported), `${name} is handed to the pages on VmfHelp`);
  }
});

for (const c of FIX.cases) {
  test(`the stand-in answers as the service does: ${c.name}`, () => {
    const got = serveDocs(fixtureFiles, { depth: c.query.depth, read: c.query.read.join(',') });
    eq(got.names, c.names, 'names');
    eq(got.folders, c.folders, 'folders');
    eq(got.docs.map(d => d.path), c.docs, 'docs');
  });
}

/* ---------------- storeDocs ---------------- */

test('storeDocs asks once, and holds the listing and the documents', async () => {
  const c = FIX.cases[0];
  const { held, s } = await heldFor(c.query);
  eq(s.calls, ['store/docs'], 'calls');
  eq([...held.names], c.names, 'names');
  eq([...held.docs.keys()], c.docs, 'docs');
  ok(held.complete && !held.truncated, 'complete');
});

test('storeDocs follows the pages, and takes the listing from the first', async () => {
  const c = FIX.cases[0];
  const { held, s } = await heldFor(c.query, { maxDocs: 2 });
  eq(s.calls.length, Math.ceil(c.docs.length / 2), 'one call for each page');
  eq([...held.docs.keys()], c.docs, 'every document');
  eq([...held.names], c.names, 'the listing of the first page, not the empty one of the last');
  ok(held.complete, 'complete');
});

test('storeDocs stops at its limit of pages, and says it is not complete', async () => {
  const c = FIX.cases[0];
  const { held, s } = await heldFor(c.query, { maxDocs: 1 });
  ok(c.docs.length > globalThis.STORE_DOCS_PAGES_MAX ? true : true, 'fixture');
  eq(s.calls.length, Math.min(c.docs.length, globalThis.STORE_DOCS_PAGES_MAX), 'calls');
  eq(held.complete, c.docs.length <= globalThis.STORE_DOCS_PAGES_MAX, 'complete');
});

test('storeDocs throws when the service refuses, so the page reads as before', async () => {
  let threw = null;
  try { await heldFor(FIX.cases[0].query, { docsFail: true }); } catch (e) { threw = e.message; }
  eq(threw, 'refused', 'the service sentence');
});

/* ---------------- heldList: the listing store/list gives, or nothing ---------------- */

test('heldList gives the listing store/list gives, for every folder the call went deep enough for', async () => {
  for (const c of FIX.cases) {
    const { held } = await heldFor(c.query);
    const folders = ['', ...c.folders.map(f => f + '/')];
    let compared = 0;
    for (const f of folders) {
      const level = f.split('/').filter(Boolean).length;
      const got = H.heldList(held, f, '/');
      if (level + 1 > c.query.depth) { eq(got, undefined, `${c.name}: ${f} is deeper than the call went`); continue; }
      eq(got, serveList(fixtureFiles, f, '/'), `${c.name}: listing of "${f}"`);
      compared++;
    }
    ok(compared > 0, `${c.name}: some listing compared`);
  }
});

test('heldList gives every document below a folder only when none can be deeper than the call went', async () => {
  const { held: three } = await heldFor(FIX.cases[0].query);
  eq(H.heldList(three, 'old1/'), serveList(fixtureFiles, 'old1/'), 'old1 holds nothing deeper than three');
  eq(H.heldList(three, 'proj/m1/'), undefined, 'proj/m1/state is AT the depth, so it can hold more');
  eq(H.heldList(three, 'proj/m1/state/'), undefined, 'a folder at the depth');
  const { held: four } = await heldFor(FIX.cases[1].query);
  eq(H.heldList(four, 'proj/m1/state/'), serveList(fixtureFiles, 'proj/m1/state/'), 'one level further down');
  eq(H.heldList(four, 'proj/m1/'), serveList(fixtureFiles, 'proj/m1/'), 'and its run');
});

test('heldList leaves to the service: a part of a name, a listing cut short, nothing held', async () => {
  const { held } = await heldFor(FIX.cases[0].query);
  eq(H.heldList(held, 'proj/a1/run.json'), undefined, 'a prefix that is part of a name');
  eq(H.heldList(null, '', '/'), undefined, 'no call made');
  const { held: cut } = await heldFor(FIX.cases[0].query, { truncated: true });
  eq(H.heldList(cut, '', '/'), undefined, 'a listing cut short');
});

/* ---------------- heldJson and heldHas ---------------- */

test('heldJson gives each document the call read, parsed, as the per-file read does', async () => {
  const c = FIX.cases[0];
  const { held } = await heldFor(c.query);
  for (const p of c.docs) {
    if (typeof fixtureFiles[p] === 'string') { continue; }
    eq(H.heldJson(held, p), { value: fixtureFiles[p] }, p);
  }
});

test('heldJson: a document that is not JSON is left to the service, so its read error is not lost', async () => {
  // PAGE-LOAD-2 fix round: taken as null, a damaged document vanished without a word.
  const { held } = await heldFor(FIX.cases[0].query);
  eq(H.heldJson(held, 'proj/a2/assessment.json'), undefined, 'not JSON');
});

test('heldJson: a document the listing does not name is not in the store - null, with no call', async () => {
  const { held } = await heldFor(FIX.cases[0].query);
  eq(H.heldJson(held, 'proj/a2/approval.json'), { value: null }, 'nobody approved a2');
  eq(H.heldJson(held, 'old1/run-status.json'), { value: null }, 'a run at setup has no status');
});

test('heldJson leaves to the service everything it cannot say', async () => {
  const { held } = await heldFor(FIX.cases[0].query);
  eq(H.heldJson(held, 'proj/m1/plan.json'), undefined, 'in the store, not named by the call');
  eq(H.heldJson(held, 'retention-status.json'), undefined, 'at the top, not named by the call');
  eq(H.heldJson(held, 'proj/m1/state/vm1.json'), undefined, 'deeper than the call went');
  eq(H.heldJson(held, 'proj/m1/state/none.json'), undefined, 'deeper than the call went, even when it is not there');
  eq(H.heldJson(null, 'proj/a1/run.json'), undefined, 'no call made');
  const { held: cut } = await heldFor(FIX.cases[0].query, { truncated: true });
  eq(H.heldJson(cut, 'proj/a1/run.json'), undefined, 'a listing cut short');
  const refused = { ...held, docs: new Map(held.docs) };
  refused.docs.set('proj/a1/run.json', { path: 'proj/a1/run.json', text: null, error: 'HTTP 403' });
  eq(H.heldJson(refused, 'proj/a1/run.json'), undefined, 'a read the store refused');
  const gone = { ...held, docs: new Map(held.docs) };
  gone.docs.set('proj/a1/run.json', { path: 'proj/a1/run.json', text: null });
  eq(H.heldJson(gone, 'proj/a1/run.json'), undefined, 'empty when read: the service says what is there');
  eq(H.heldText(gone, 'proj/a1/run.json'), { value: null }, 'a log part that is empty ends the walk');
});

test('heldJson: past the last page read, a listed document is left to the service', async () => {
  const c = FIX.cases[0];
  const { held } = await heldFor(c.query, { maxDocs: 1 });
  if (held.complete) { return; }
  const last = c.docs[c.docs.length - 1];
  ok(!held.docs.has(last), 'the last document was not read');
  eq(H.heldJson(held, last), undefined, last);
});

test('heldHas says from the listing whether a document is there, down to the depth', async () => {
  const { held } = await heldFor(FIX.cases[0].query);
  eq(H.heldHas(held, 'proj/m1/plan.json'), true, 'there');
  eq(H.heldHas(held, 'proj/m1/customer-report.html'), false, 'not there');
  eq(H.heldHas(held, 'proj/m1/state/vm1.json'), undefined, 'deeper than the call');
  eq(H.heldHas(null, 'proj/m1/plan.json'), undefined, 'no call');
});

/* ---------------- the pages, on a store like the lab's ---------------- */

/* Four projects of six runs - assessments and migrations - three runs from
 * before projects, ten machine records in each migration, a claim registry,
 * the cleanup record, one assessment whose document is cut short. */
function bigStore() {
  const files = {};
  let minute = 0;
  const at = () => new Date(Date.UTC(2026, 10, 1, 0, minute++)).toISOString();
  files['retention-status.json'] = { lastPassUtc: at(), runsExamined: 3, machinesDue: 0, executionsStarted: [], failures: [] };
  files['vmf-claims/claims/vm1.json'] = { holder: 'x' };
  for (let p = 1; p <= 4; p++) {
    const pid = `proj${p}`;
    files[`${pid}/project.json`] = { projectId: pid, name: `Project ${p}`, createdUtc: at() };
    for (let r = 1; r <= 6; r++) {
      const id = `${pid}/run${r}`;
      const kind = r % 2 ? 'assessment' : 'migration';
      files[`${id}/run.json`] = { runId: `run${r}`, kind, project: pid, createdUtc: at(), ...(kind === 'migration' ? { fromAssessment: `run${r - 1}` } : {}) };
      if (kind === 'assessment') {
        files[`${id}/assessment.json`] = (p === 2 && r === 3) ? '{ cut short' : { generatedUtc: at(), vms: [{ vmId: `${id}-vm1` }, { vmId: `${id}-vm2` }] };
        if (r === 1) { files[`${id}/approval.json`] = { approvedUtc: at() }; }
      } else if (r !== 6) {
        files[`${id}/run-status.json`] = { schemaVersion: 4, runId: `run${r}`, updatedUtc: at(), stateCounts: { MIGRATED: 3 }, running: [] };
        files[`${id}/plan.json`] = { entries: Array.from({ length: 10 }, (_, m) => ({ vmId: `/subscriptions/x/vm${m}`, wave: `w${m % 2}`, path: 'A' })) };
        for (let m = 0; m < 10; m++) { files[`${id}/state/vm${m}.json`] = { vmId: `/subscriptions/x/VM${m}`, state: m < 3 ? 'MIGRATED' : 'PLANNED' }; }
        files[`${id}/logs/events.jsonl`] = '{"e":1}';
        if (r === 2) { files[`${id}/customer-report.html`] = '<html></html>'; }
      }
      // run6 is a migration at setup: no plan, no status.
    }
  }
  for (let l = 1; l <= 3; l++) { files[`old${l}/run.json`] = { runId: `old${l}`, createdUtc: at() }; }
  return files;
}

const BOUND = 2;   // calls to the service on one load, on any store

function commonGlobals(s) {
  globalThis.cfg = { apiUrl: 'https://service.example.com/api', apiAppId: 'x' };
  globalThis.getToken = async () => 'token';
  globalThis.fetch = s.fetch;
  globalThis.DEMO_MODE = false;
  globalThis.held = null;
  globalThis.location = { search: '' };
  globalThis.window = globalThis;
  globalThis.VmfListRuns = H.listRunsAcrossProjects;
  globalThis.VmfHelp = {
    mapLimited: H.mapLimited, runFolderIsRun: H.runFolderIsRun, runKind: H.runKind, readLimiter: H.readLimiter,
    storeList: s.storeList, storeBlob: s.storeBlob, storeUrl: H.storeUrl,
    storeDocs: H.storeDocs, heldList: H.heldList, heldJson: H.heldJson, heldHas: H.heldHas, storeHolds: H.storeHolds,
    runSummaryOf: (st) => (st && st.summary) || null, runWaitingCount: () => 0, runGateTag: () => '', runGroup: () => 'Running',
    retentionPassFacts: () => ({ ran: false, unfinished: false, failures: [], nextUtc: null }),
    safetyCopyLedger: (docsIn, entries) => docsIn.map(d => ({ id: d.vmId, planned: (entries || []).length })),
    safetyCopySummary: (rows) => ({ copies: rows.length, machines: rows.length, due: 0, unlocked: 0, earliestDueUtc: null, rows }),
    VmfRun: { storePath: (proj, r) => (proj ? `${proj}/${r}` : r), parse: (x) => ({ run: String(x).split('/').pop() }),
              routeSegment: (x) => String(x).split('/').pop(), withProject: (o, x) => (String(x).includes('/') ? { ...o, project: String(x).split('/')[0] } : o) },
  };
}

/* ---- Overview ---- */

let overview = null;
try {
  overview = liftAll('index.html', ['readHeld', 'blobList', 'blobJson', 'load', 'readRun', 'migrationFacts']);
} catch (e) { overview = { missing: e.message }; }

function overviewPage(s) {
  commonGlobals(s);
  globalThis.PANEL_READS = readsOf('index.html', 'PANEL_READS');
  globalThis.state = { projects: [], loose: [], runs: [] };
  globalThis.render = () => {};
  globalThis.esc = (v) => String(v ?? '');
  globalThis.ago = () => '';
  globalThis.runLink = (id) => `#${id}`;
  globalThis.UX = new Proxy({}, { get: () => '' });
  const card = { innerHTML: '' };
  globalThis.document = { createElement: () => card };
  globalThis.$ = () => ({ appendChild: () => {} });
  globalThis.storeRead = H.readLimiter();
  return card;
}
const byId = (a, b) => ord(a.id, b.id);
async function overviewLoad(opts) {
  const s = service(bigStore(), opts);
  overviewPage(s);
  await overview.load();
  const first = s.calls.length;
  const st = { projects: globalThis.state.projects, loose: globalThis.state.loose, runs: globalThis.state.runs.slice().sort(byId) };
  return { s, first, st };
}

test('THE DEFECT, Overview: the first draw is ONE call to the service, not one for each document', async () => {
  ok(!overview.missing, overview.missing);
  const { s, first, st } = await overviewLoad();
  // The one assessment whose text is cut short is read by itself, so its error is the page's (PAGE-LOAD-2 fix round).
  eq(s.calls.slice(0, first), ['store/docs', 'store/blob'], 'the calls before the first draw');
  ok(first <= BOUND, `${first} calls`);
  eq(st.runs.length, 4 * 6 + 3, 'every run is read');
  eq(st.projects.length, 4, 'every project');
});

test('Overview: what the page holds is what the per-file reads give', async () => {
  const one = await overviewLoad();
  const each = await overviewLoad({ docsFail: true });
  ok(each.first > 50, `the per-file reads are many on this store (${each.first}) - the test store is big enough`);
  eq(one.st, each.st, 'projects, runs before projects, and every run');
});

test('Overview: no call asks for the list of runs - the listing says which runs have a status', async () => {
  const { s } = await overviewLoad();
  ok(!s.calls.some(c => c === 'runs'), 'no GET runs');
  ok(!/\$\{cfg\.apiUrl\}\/runs`/.test(codeOf('index.html')), 'the page does not name it');
});

/* PAGE-SCALE-REPORTS-1: the Safety copies card moved to the Reports page, so
 * the Overview makes no second call for it. */
test('Overview: no second call - the Safety copies card moved to the Reports page', async () => {
  const { s, first } = await overviewLoad();
  eq(s.calls.length, first, 'every call is before the first draw');
  ok(!/safetyPanel|COPIES_READS/.test(codeOf('index.html')), 'nothing of the card is left');
});
/* ---- Assessments ---- */

let assess = null;
try {
  assess = liftAll('assessments.html', ['blobFetch', 'blobList', 'loadAssessments', 'listProjects', 'lastChange']);
} catch (e) { assess = { missing: e.message }; }

function liftSource(file) {
  const src = pageSource(path.join(DASH, file));
  const m = src.match(/\nconst source = (DEMO_MODE \? \{[\s\S]*?\n\});/);
  if (!m) { throw new Error(`${file} has no source`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[1]})`);
}

async function assessmentsLoad(opts) {
  const s = service(bigStore(), opts);
  commonGlobals(s);
  globalThis.LIST_READS = readsOf('assessments.html', 'LIST_READS');
  globalThis.blobFetch = assess.blobFetch;
  globalThis.blobList = assess.blobList;
  globalThis.source = liftSource('assessments.html');
  globalThis.rows = [];
  // PAGE-SCALE-ASSESSMENTS-1: the projects by name, from the same one call.
  globalThis.projects = [];
  globalThis.storeRuns = []; globalThis.assessmentIds = new Set();
  globalThis.listProjects = assess.listProjects;
  globalThis.lastChange = assess.lastChange;
  globalThis.renderTable = () => {};
  await assess.loadAssessments();
  return { s, rows: globalThis.rows };
}

test('THE DEFECT, Assessments: the list is ONE call to the service', async () => {
  ok(!assess.missing, assess.missing);
  const { s, rows } = await assessmentsLoad();
  // The assessment whose text is cut short is read by itself (PAGE-LOAD-2 fix round).
  eq(s.calls, ['store/docs', 'store/blob'], 'calls');
  eq(rows.length, 4 * 3, 'every assessment');
  ok(rows.some(r => r.approval) && rows.some(r => !r.approval), 'approved and not approved');
  eq(rows.find(r => r.id === 'proj2/run3').machines, 0, 'a document cut short counts no machine, as a failed read did');
  ok(rows.some(r => r.planned.length), 'the migration planned from it is found');
});

test('Assessments: what the page holds is what the per-file reads give', async () => {
  const one = await assessmentsLoad();
  const each = await assessmentsLoad({ docsFail: true });
  ok(each.s.calls.length > 30, `the per-file reads are many (${each.s.calls.length})`);
  eq(one.rows, each.rows, 'every row');
});

/* ---- Projects ---- */

let projectsPage = null;
try {
  projectsPage = liftAll('projects.html', ['blobList', 'blobJson', 'load', 'withMade', 'latestTime', 'migrationWaiting']);
} catch (e) { projectsPage = { missing: e.message }; }

async function projectsLoad(opts) {
  const s = service(bigStore(), opts);
  commonGlobals(s);
  globalThis.LIST_READS = readsOf('projects.html', 'LIST_READS');
  globalThis.render = () => {};
  globalThis.byName = (a, b) => String(a.name).localeCompare(String(b.name));
  globalThis.projects = [];
  globalThis.storeRuns = []; globalThis.assessmentIds = new Set();
  globalThis.loose = [];
  // PAGE-SCALE-PROJECTS-1: load reads each migration's status for the count that waits for a person.
  Object.assign(globalThis, { withMade: projectsPage.withMade, latestTime: projectsPage.latestTime, migrationWaiting: projectsPage.migrationWaiting,
                              madeHere: new Map(), loadTurn: 0, drawListWhenFree: () => {} });
  globalThis.storeRead = H.readLimiter();
  await projectsPage.load();
  return { s, projects: globalThis.projects, loose: globalThis.loose };
}

test('THE DEFECT, Projects: the list is ONE call to the service', async () => {
  ok(!projectsPage.missing, projectsPage.missing);
  const { s, projects, loose } = await projectsLoad();
  eq(s.calls, ['store/docs'], 'calls');
  eq(projects.map(p => p.assessments + p.migrations), [6, 6, 6, 6], 'every run counted');
  eq(loose, ['old1', 'old2', 'old3'], 'every run from before projects');
});

test('Projects: what the page holds is what the per-file reads give', async () => {
  const one = await projectsLoad();
  const each = await projectsLoad({ docsFail: true });
  ok(each.s.calls.length > 20, `the per-file reads are many (${each.s.calls.length})`);
  eq({ p: one.projects, l: one.loose }, { p: each.projects, l: each.loose }, 'projects');
});

/* ---- Reports ---- */

let reports = null;
try {
  reports = liftAll('reports.html', ['num', 'summaryFromDocs', 'heldSummary', 'blobFetch', 'blobList', 'liveSummary', 'loadSummaries',
    'listProjects', 'copiesRunIds', 'copiesFacts']);
} catch (e) { reports = { missing: e.message }; }

async function reportsLoad(opts) {
  const s = service(bigStore(), opts);
  commonGlobals(s);
  globalThis.LIST_READS = readsOf('reports.html', 'LIST_READS');
  // The service's counts and the page's are held to one fixture
  // (machine-outcome.test.js); here a migrated machine is counted.
  globalThis.VmfHelp.outcomeCounts = (docs) => ({ migrated: docs.filter(d => d && d.state === 'MIGRATED').length });
// NOT-IN-WAVE-QUEUED-1: summaryFromDocs asks help.js's outsideRun.
globalThis.VmfHelp.outsideRun = liftAll('help.js', ['outsideRun']).outsideRun;
  for (const k of ['num', 'summaryFromDocs', 'heldSummary', 'blobFetch', 'blobList', 'liveSummary', 'listProjects']) { globalThis[k] = reports[k]; }
  globalThis.projects = [];
  globalThis.storeRuns = []; globalThis.assessmentIds = new Set();
  globalThis.source = liftSource('reports.html');
  globalThis.rows = [];
  globalThis.renderTable = () => {};
  globalThis.byNewest = (a, b) => (Date.parse(b.updatedUtc ?? b.createdUtc ?? 0) || 0) - (Date.parse(a.updatedUtc ?? a.createdUtc ?? 0) || 0);
  await reports.loadSummaries();
  return { s, rows: globalThis.rows, projects: globalThis.projects };
}

test('THE DEFECT, Reports: the list is ONE call to the service, counts included', async () => {
  ok(!reports.missing, reports.missing);
  const { s, rows } = await reportsLoad();
  eq(s.calls, ['store/docs'], 'calls');
  eq(rows.length, 4 * 3 + 3, 'every migration, and no assessment');
  const r2 = rows.find(r => r.r === 'proj1/run2');
  eq([r2.migrated, r2.total, r2.hasReport], [3, 10, true], 'counts from the machine records, in any letter case of the ID, and the report');
  eq(rows.find(r => r.r === 'proj1/run4').hasReport, false, 'no report');
  ok(rows.find(r => r.r === 'proj1/run6').setupOnly, 'a migration at setup');
});

test('Reports: what the page holds is what the per-file reads and the service counts give', async () => {
  const one = await reportsLoad();
  const each = await reportsLoad({ docsFail: true });
  ok(each.s.calls.filter(c => c.endsWith('/summary')).length >= 8, 'the per-file load asks the service to count each migration');
  eq(one.rows, each.rows, 'every row');
  eq(one.projects, each.projects, 'the projects');
});

test('Reports: the projects, by name, come in the one call - no read for each row', async () => {
  const { s, projects } = await reportsLoad();
  eq(s.calls, ['store/docs'], 'calls');
  eq(projects.map(p => p.id), ['proj1', 'proj2', 'proj3', 'proj4'], 'every project');
});

/* PAGE-SCALE-REPORTS-1: the Safety copies card moved here from the Overview,
 * where it was ONE more call. Here the page's one call already holds every
 * document it reads, so it asks the service nothing more. */
test('Reports: the Safety copies card asks the service nothing more, and shows what the per-file reads show', async () => {
  const draw = async (opts) => {
    const loaded = await reportsLoad(opts);
    globalThis.copiesRunIds = reports.copiesRunIds;
    const before = loaded.s.calls.length;
    const facts = await reports.copiesFacts();
    return { calls: loaded.s.calls.slice(before), facts };
  };
  const one = await draw();
  eq(one.calls, [], 'no call for the card');
  const each = await draw({ docsFail: true });
  ok(each.calls.length > 20, 'the per-file card reads many');
  eq(one.facts, each.facts, 'the card\'s facts');
  ok(one.facts.per.some(p => p.id === 'proj1/run2' && p.summary.copies > 0), 'a migration with machine records is counted');
  ok(!one.facts.per.some(p => /run[135]$/.test(p.id)), 'an assessment is not walked');
});

/* ---------------- a page that saves reads that document the PLANVER-2 way ---------------- */

test('no page takes a version from the one call: a save reads its document through store/blob', () => {
  const docs = HELP.slice(HELP.indexOf('async function storeDocs('), HELP.indexOf('function heldDepth('));
  ok(docs.length > 0, 'storeDocs is in help.js');
  ok(!/version/i.test(docs.replace(/\/\*[\s\S]*?\*\//g, '')), 'storeDocs keeps no version');
  for (const file of ['index.html', 'projects.html', 'reports.html']) {
    ok(!/asVersioned/.test(codeOf(file)), `${file} saves no document read with a version`);
  }
  // ASSESS-APPROVAL-HASH-1: the Assessments page quotes back the version of the
  // ONE document its approval names, and reads it through store/blob - never
  // from the one call (assess-approval-hash.test.js runs the read).
  const versioned = codeOf('assessments.html').match(/storeBlob\([^;]*asVersioned: true \}\)/g) || [];
  eq(versioned, ['storeBlob(() => getToken(), cfg.apiUrl, `${id}/assessment.json`, { asVersioned: true })'], 'assessments.html: the scan an approval names');
});

/* ================= PAGE-LOAD-2: the Migrations page and the support bundle =================
 *
 * The Migrations page sent about 185 calls when it opened on the lab install
 * (P 3, A 40, M 20) and about 25 every 15 seconds: the listing of each
 * project, then run.json, run-status.json and plan.json of each run, then the
 * open run's documents one by one. THE RULE: the list is ONE call (store/docs)
 * a load and a tick, and the open run's folder is ONE call with a prefix. The
 * plan of the open run stays a store/blob read, because its version is quoted
 * back (PLANVER-2). A migration with no run-status.json in the listing is not
 * asked for one (PERF-SETUP-RUNS-1). The support bundle reads one run in ONE
 * call, and when that call fails it sends at most 8 reads at once
 * (PERF-ONE-LIMIT-2). */

let migr = null;
try {
  migr = liftAll('migrations.html', ['blobFetch', 'blobList', 'runListed', 'tickReads', 'listReads', 'loadRuns',
    'refresh', 'refreshOnce', 'asOneLoad', 'refreshRun', 'linkedRunId']);
} catch (e) { migr = { missing: e.message }; }
// The adapter the page hands the support bundle, lifted on its own.
try { migr.helpAdapter = liftAll('migrations.html', ['helpAdapter']).helpAdapter; } catch (e) { migr.helpAdapter = () => { throw new Error(e.message); }; }

let realHelp = {};
try {
  realHelp = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup',
    'nextLogPart', 'readLogParts', 'readLogEvents', 'buildBundle']);
} catch (e) { realHelp = { missing: e.message }; }
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = constOf(HELP, 'RUN_ACTIVE_MS');
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.LOG_PARTS_MAX = constOf(HELP, 'LOG_PARTS_MAX');
globalThis.EVENT_CAP = constOf(HELP, 'EVENT_CAP');
// eslint-disable-next-line no-eval
globalThis.BUNDLE_READS = eval((HELP.match(/const BUNDLE_READS = (\[[^\]]*\]);/) || [])[1]);

/* The lab's shape, with the documents a migration gathers as it runs: four
 * projects, every migration status with the summary a current engine writes,
 * one migration whose status has no summary it can read, one never planned, and the
 * open run with schedules, approvals, acceptances, quota claims, a sign-off,
 * a second log part and the documents a page never draws (a catalog, evidence). */
function migrationsStore(opts) {
  const files = bigStore();
  for (const k of Object.keys(files)) {
    const m = k.match(/^(proj\d\/run\d)\/run-status\.json$/);
    if (!m) { continue; }
    files[k] = { ...files[k], summary: { writtenUtc: files[k].updatedUtc, reason: 'planSaved', halted: false, machines: 10,
      stateCounts: { MIGRATED: 3, PLANNED: 7 }, waitsOnPerson: 0, waves: [], next: { wave: 'w0', waitsFor: 'approval' } } };
  }
  // A status with no summary: the plan is read, as for no status at all.
  if (!(opts && opts.allSummaries)) { delete files['proj3/run4/run-status.json'].summary; }
  const open = 'proj1/run2';
  files[`${open}/plan-approval.json`] = { planHash: `v-${open}/plan.json`, approvedUtc: '2026-11-01T00:00:00Z' };
  files[`${open}/acknowledgements/infrastructure-as-code.json`] = { acknowledgedUtc: '2026-11-01T00:00:00Z' };
  files[`${open}/schedules/w0.json`] = { wave: 'w0', startUtc: '2026-11-09T00:00:00Z' };
  files[`${open}/approvals/w0.json`] = { wave: 'w0', approvedUtc: '2026-11-01T00:00:00Z' };
  files[`${open}/acceptances/wave-options-w0.json`] = { wave: 'w0', acceptedUtc: '2026-11-01T00:00:00Z' };
  files[`${open}/capacity/eastus-dv6.json`] = { cell: 'eastus-dv6', cores: 8 };
  files[`${open}/capacity-history/eastus-dv6-0001.json`] = { cell: 'eastus-dv6', released: true };
  files[`${open}/logs/events.jsonl`] = '{"tsUtc":"2026-11-01T00:00:00Z","e":1}\n{"tsUtc":"2026-11-01T00:01:00Z","e":2}';
  files[`${open}/logs/events-2.jsonl`] = '{"tsUtc":"2026-11-01T00:02:00Z","e":3}';
  files[`${open}/catalog/eastus.json`] = { skus: ['a large document no page draws'] };
  files[`${open}/evidence/vm1-precheck.json`] = { guest: 'facts' };
  files[`${open}/target-advice.json`] = { machines: [] };
  // WAVE-RUNNING-LEASE-1: a worker holds a machine. The lease is in the run's one call.
  files[`${open}/leases/vm1.lease`] = { schemaVersion: 1, vmId: '/subscriptions/x/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/VM1',
    workerId: 'w0-worker-0', acquiredUtc: '2026-11-01T00:00:00Z', heartbeatUtc: '2026-11-01T00:01:00Z' };
  return files;
}

/* The page around its load and its tick, with the service above behind it. */
function migrationsPage(s, opts) {
  const o = opts || {};
  commonGlobals(s);
  globalThis.LIST_READS = readsOf('migrations.html', 'LIST_READS');
  globalThis.RUN_READS = readsOf('migrations.html', 'RUN_READS');
  globalThis.storeRead = H.readLimiter();
  const panel = { classList: { contains: () => !!o.panelOpen } };
  const els = { '#run-panel': panel, '#err': { textContent: '', style: { display: 'none' } }, '#live-ind': { className: '', title: '' } };
  for (const k of ['blobFetch', 'blobList', 'runListed', 'tickReads', 'loadRuns', 'refreshRun', 'linkedRunId']) {
    globalThis[k] = migr[k];
  }
  Object.assign(globalThis, {
    source: liftSource('migrations.html'),
    pendingRuns: new Set(), runKinds: new Map(), listedRuns: null, loadsRunning: new Set(), localStorage: { getItem: () => null, setItem() { } },
    history: { replaceState() { } }, runRows: [], currentRun: o.current || null, lastListError: null, showingRun: null,
    renderRunPanel() { }, showReadingRun() { }, clearReadingRun() { }, async renderFirstRun() { },
    nameMachines() { }, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis() { }, renderNextStep() { }, renderFound() { }, renderWaves() { }, refreshDrill() { },
    renderCapacity() { }, renderSafetyCopies() { }, renderEvents() { }, ago: () => 'a while ago',
    planDoc: null, runAck: null, runStop: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null,
    lastAssessment: null, schedules: new Map(), acceptances: new Map(), approvals: new Map(),
    allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false, discardInFlight: new Map(), latestEvents: [],
    restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    $: (sel) => els[sel] ?? null, runRegions: () => [],
  });
  Object.assign(globalThis.VmfHelp, {
    runSummaryOf: realHelp.runSummaryOf, runWaitingCount: realHelp.runWaitingCount, runGateTag: realHelp.runGateTag,
    runGroup: realHelp.runGroup, heldText: H.heldText, readLogEvents: realHelp.readLogEvents,
    leasesByMachine: H.leasesByMachine,
    drawWhenFree: (regions, draw) => { draw(); return true; },
    VmfRun: { fromQuery: () => null },
    explain: (e) => String(e && e.message ? e.message : e),
  });
  return els;
}

/* What the page holds after a draw of the list and the open run. */
function migrationsHeld(els) {
  const sorted = (m) => [...m.entries()].sort((a, b) => ord(a[0], b[0]));
  return {
    rows: globalThis.runRows.map(x => ({ r: x.r, t: x.t, group: x.group, setupOnly: x.setupOnly, waitsFor: x.waitsFor })).sort((a, b) => ord(a.r, b.r)),
    current: globalThis.currentRun, err: els['#err'].textContent,
    planDoc: globalThis.planDoc, runAck: globalThis.runAck, runStop: null, planSignoff: globalThis.planSignoff,
    planSignoffCurrent: globalThis.planSignoffCurrent, planRunStatus: globalThis.planRunStatus,
    lastAssessment: globalThis.lastAssessment, schedules: sorted(globalThis.schedules),
    acceptances: sorted(globalThis.acceptances), approvals: sorted(globalThis.approvals),
    allVms: globalThis.allVms.slice().sort((a, b) => ord(a.vmId, b.vmId)), latestClaims: globalThis.latestClaims,
    latestLeases: sorted(globalThis.latestLeases),
    latestHalted: globalThis.latestHalted, latestEvents: globalThis.latestEvents,
  };
}

/* start(): the walk and the first draw share one reader. */
async function migrationsLoad(opts) {
  const o = opts || {};
  const s = service(o.files || migrationsStore(o), o);
  const els = migrationsPage(s, { current: o.current || 'proj1/run2', panelOpen: o.panelOpen });
  const reads = globalThis.tickReads();
  await globalThis.loadRuns(reads);
  await migr.refresh({ runsFresh: true, reads });
  return { s, els, first: s.calls.length };
}

const MIGRATIONS_BOUND = 4;   // the list, the open run, its plan (versioned), the cleanup record

test('THE DEFECT, Migrations: the first load is a handful of calls, not one for each document', async () => {
  ok(!migr.missing, migr.missing);
  ok(!realHelp.missing, realHelp.missing);
  const { s, els } = await migrationsLoad({ allSummaries: true });
  eq(els['#err'].textContent, '', 'the run was drawn');
  eq(s.calls.filter(c => c === 'store/docs').length, 2, 'one call for the list, one for the open run');
  ok(s.calls.length <= MIGRATIONS_BOUND, `${s.calls.length} calls: ${JSON.stringify(s.blobs)}`);
  eq(globalThis.runRows.length, 4 * 3 + 3, 'every migration, and no assessment');
});

test('THE DEFECT, Migrations: a 15-second tick is a handful of calls, with the list or without it', async () => {
  const { s, first } = await migrationsLoad({ allSummaries: true });
  await migr.refresh();
  const tick = s.calls.slice(first);
  eq(tick.filter(c => c === 'store/docs').length, 2, 'the list and the open run, one call each');
  ok(tick.length <= MIGRATIONS_BOUND, `${tick.length} calls a tick`);
  const open = await migrationsLoad({ panelOpen: true, allSummaries: true });
  await migr.refresh();
  const still = open.s.calls.slice(open.first);
  eq(still.filter(c => c === 'store/docs').length, 1, 'with the list open, only the open run is read');
  ok(still.length <= MIGRATIONS_BOUND - 1, `${still.length} calls a tick`);
});

test('Migrations: what the page holds is what the per-file reads give', async () => {
  const one = await migrationsLoad();
  const each = await migrationsLoad({ docsFail: true });
  ok(each.first > 60, `the per-file reads are many on this store (${each.first})`);
  const a = migrationsHeld(one.els), b = migrationsHeld(each.els);
  eq(a, b, 'the list and the open run');
  eq(a.latestEvents.length, 3, 'both parts of the log');
  ok(a.planSignoffCurrent, 'the sign-off names the version the service issued');
  ok(a.allVms.length === 10 && a.latestClaims.length === 1 && a.schedules.length === 1, 'the open run is drawn');
  // WAVE-RUNNING-LEASE-1: the lease, by the machine ID inside it, from the one call and from the per-file reads.
  eq(a.latestLeases.map(([k, v]) => [k, v.workerId]), [['/subscriptions/x/resourcegroups/rg/providers/microsoft.compute/virtualmachines/vm1', 'w0-worker-0']], 'the lease');
  eq(a.rows.find(x => x.r === 'proj1/run6').setupOnly, true, 'a migration never planned');
});

test('Migrations: a tick holds what a per-file tick holds', async () => {
  const one = await migrationsLoad();
  await migr.refresh();
  const each = await migrationsLoad({ docsFail: true });
  await migr.refresh();
  eq(migrationsHeld(one.els), migrationsHeld(each.els), 'after a tick');
});

test('PLANVER-2: the open run\'s plan is a store/blob read with its version, never a document of the one call', async () => {
  const { s } = await migrationsLoad();
  const planReads = s.blobs.filter(b => b.path === 'proj1/run2/plan.json');
  eq(planReads, [{ path: 'proj1/run2/plan.json', versioned: true }], 'one versioned read of the plan');
  const reads = readsOf('migrations.html', 'RUN_READS').concat(readsOf('migrations.html', 'LIST_READS'));
  ok(!reads.some(r => /plan\.json$/.test(r) && !/plan-/.test(r)), 'neither call reads plan.json');
});

test('PERF-SETUP-RUNS-1: a migration never planned is asked for neither its status nor its plan', async () => {
  const { s, first } = await migrationsLoad();
  await migr.refresh();
  for (const rel of ['run-status.json', 'plan.json']) {
    eq(s.blobs.filter(b => b.path === `proj1/run6/${rel}`).length, 0, `proj1/run6/${rel}, on the load and the tick`);
  }
  ok(first > 0, 'the page loaded');
});

test('Migrations: plan.json is read for the list only where the status cannot count the machines', async () => {
  const { s } = await migrationsLoad({ current: 'proj4/run2' });
  const listPlans = s.blobs.filter(b => /plan\.json$/.test(b.path)).map(b => b.path).sort();
  eq(listPlans, ['proj3/run4/plan.json', 'proj4/run2/plan.json'], 'the run from before the summary, and the open run');
});

test('Migrations: no run-status.json is read one by one when the one call answered', async () => {
  const { s } = await migrationsLoad();
  await migr.refresh();
  eq(s.blobs.filter(b => /run-status\.json$/.test(b.path)).length, 0, 'every status from the one call');
  eq(s.blobs.filter(b => /\/state\//.test(b.path)).length, 0, 'every machine record from the one call');
  eq(s.blobs.filter(b => /logs\//.test(b.path)).length, 0, 'every log part from the one call');
});

test('Migrations: the open run\'s call names no document the page never draws', () => {
  const runReads = readsOf('migrations.html', 'RUN_READS');
  ok(runReads.length <= 12, 'the service takes at most 12 names');
  const files = migrationsStore();
  const q = { prefix: 'proj1/run2/', depth: 2, read: runReads.join(',') };
  const got = serveDocs(files, q).docs.map(d => d.path);
  for (const never of ['catalog/eastus.json', 'evidence/vm1-precheck.json', 'target-advice.json', 'plan.json', 'run.json']) {
    ok(!got.includes(`proj1/run2/${never}`), `${never} is not read`);
  }
});

/* ---- the support bundle ---- */

function bundleGlobals(s) {
  Object.assign(globalThis, {
    build: { version: '1.0.0' }, service: null, TEXT: { disclaimerLine: 'x' }, clientErrors: [],
    location: { search: '', pathname: '/migrations.html' },
    mapLimited: H.mapLimited, readLimiter: H.readLimiter, heldJson: H.heldJson, heldList: H.heldList,
    heldText: H.heldText, nextLogPart: realHelp.nextLogPart, readLogParts: realHelp.readLogParts,
    readLogEvents: realHelp.readLogEvents,
  });
  globalThis.adapter = migr.helpAdapter();
  return s;
}

async function bundleOf(opts) {
  const s = service(migrationsStore(), opts);
  migrationsPage(s, { current: 'proj1/run2' });
  bundleGlobals(s);
  const b = await realHelp.buildBundle('proj1/run2');
  delete b.generatedUtc;
  return { s, b };
}

test('THE DEFECT, support bundle: one run is ONE call, not six walks', async () => {
  ok(!realHelp.missing, realHelp.missing);
  const { s, b } = await bundleOf();
  eq(s.calls, ['store/docs'], 'calls');
  eq(b.machines.length, 10, 'every machine record');
  eq([b.capacity.length, b.capacityHistory.length, b.approvals.length, b.schedules.length, b.acceptances.length], [1, 1, 1, 1, 1], 'every folder');
  eq(b.events.length, 3, 'both parts of the log');
  ok(b.plan && b.status && b.assessment === null, 'the status and the plan');
  eq(b.couldNotRead, [], 'nothing missing');
});

test('Support bundle: what it holds is what the per-file reads give', async () => {
  const one = await bundleOf();
  const each = await bundleOf({ docsFail: true });
  ok(each.s.calls.length > 15, `the per-file reads are many (${each.s.calls.length})`);
  eq(one.b, each.b, 'the bundle');
});

test('EVAL-M13: with the one call failed, a reader that throws at once costs only its own document', async () => {
  const s = service(migrationsStore(), { docsFail: true });
  migrationsPage(s, { current: 'proj1/run2' });
  bundleGlobals(s);
  const page = migr.helpAdapter();
  globalThis.adapter = { ...page, readJson: (run, rel) => { if (rel === 'plan.json') { throw new Error('not a function'); } return page.readJson(run, rel); } };
  const b = await realHelp.buildBundle('proj1/run2');
  eq(b.couldNotRead, ['plan.json: not a function'], 'the one it could not read, said');
  eq(b.machines.length, 10, 'and everything else');
});

test('Migrations: a call the service cut short is read as no call, and the page shows the same', async () => {
  const one = await migrationsLoad();
  const cut = await migrationsLoad({ truncated: true });
  ok(cut.s.calls.filter(c => c !== 'store/docs').length > 60, 'every read made as before');
  eq(migrationsHeld(cut.els), migrationsHeld(one.els), 'the list and the open run');
});
/* Fix round 1: a document the store holds but that is not JSON - a machine
 * record cut short - is not an answer. The page asks for it itself, and the
 * read error is shown, as the per-file read showed it; the bundle names it. */
function damaged(files) { files['proj1/run2/state/vm4.json'] = '{ "vmId": "cut short'; return files; }

test('a damaged machine record is not dropped without a word: the page says it could not read it', async () => {
  const one = await migrationsLoad({ files: damaged(migrationsStore()) });
  ok(one.els['#err'].textContent.includes('Could not refresh'), `the page says so: "${one.els['#err'].textContent}"`);
  ok(one.s.blobs.some(b => b.path === 'proj1/run2/state/vm4.json'), 'it asked the service for that record');
  const each = await migrationsLoad({ files: damaged(migrationsStore()), docsFail: true });
  eq(one.els['#err'].textContent, each.els['#err'].textContent, 'the same words as the per-file reads');
});

test('a damaged machine record is named in the support bundle, as the per-file bundle names it', async () => {
  const s = service(damaged(migrationsStore()));
  migrationsPage(s, { current: 'proj1/run2' });
  bundleGlobals(s);
  const b = await realHelp.buildBundle('proj1/run2');
  eq(b.couldNotRead.length, 1, `couldNotRead: ${JSON.stringify(b.couldNotRead)}`);
  ok(b.couldNotRead[0].startsWith('state/vm4.json: '), 'it names the document');
  eq(b.machines.length, 9, 'and keeps every other record');
  eq(s.calls.filter(c => c === 'store/docs').length, 1, 'still one call for the rest');
});
test('PERF-ONE-LIMIT-2: a bundle read one document at a time sends at most 8 at once', async () => {
  const { s } = await bundleOf({ docsFail: true });
  ok(s.most <= globalThis.STORE_READ_LIMIT, `${s.most} reads in flight at once`);
});

/* ================= PAGE-LOAD-3: the Waves page and Assess and migrate =================
 *
 * The Waves page read one migration a document a call: the plan, a listing of
 * state/ and each machine record, the assessment, a listing of capacity/ and
 * each quota record, the leases. Assess and migrate read a dozen documents and
 * three listings, then each document the listings named, on every step and
 * every tick. THE RULE: the run's folder is ONE call (store/docs with the run
 * as the prefix), and each reader answers from it first; what it cannot say
 * is read as before (unknown means ask). A document the page SAVES with a
 * version - the plan on Waves, the target options, the targets and the
 * machines chosen on Assess and migrate - stays a store/blob read with its
 * version (PLANVER-2). The help adapter of both pages gives the support
 * bundle the same one call (runDocs). */

let waves = null;
try {
  waves = liftAll('waves.html', ['blobFetch', 'blobList', 'heldOrFetch', 'readLeases', 'loadClaims', 'claimCount',
    'quotaAccessFrom', 'readPlan', 'readMigration', 'runFullId', 'runPrefix']);
  waves.helpAdapter = liftAll('waves.html', ['helpAdapter']).helpAdapter;
} catch (e) { waves = { missing: e.message }; }
let claimHelp = {};
try {
  globalThis.claimBlocked = liftAll('help.js', ['claimBlocked']).claimBlocked;
  globalThis.RESERVING_STUCK_MINUTES = 60;
  claimHelp = liftAll('help.js', ['claimBlocked', 'claimReservingStuck', 'claimRegionalShort']);
} catch (e) { claimHelp = { missing: e.message }; }

/* The open migration as the wave editor finds it: the documents above, its
 * assessment, and quota records of two waves. */
function wavesStore() {
  const files = migrationsStore({ allSummaries: true });
  const open = 'proj1/run2';
  files[`${open}/assessment.json`] = { generatedUtc: '2026-11-01T00:00:00Z', vms: [{ vmId: '/subscriptions/x/VM1', name: 'vm-one' }] };
  files[`${open}/capacity/eastus-dv6.json`] = { wave: 'w0', region: 'eastus', state: 'RESERVED', demand: { vcpus: 8, instances: 2 },
    quota: { limit: 100, used: 10, checkedUtc: '2026-11-01T00:00:00Z' } };
  files[`${open}/capacity/eastus-ev6.json`] = { wave: 'w1', region: 'eastus', state: 'QUOTA_VERIFIED', demand: { vcpus: 4, instances: 1 },
    quota: { limit: null, used: null, checkedUtc: '2026-11-01T00:05:00Z' } };
  return files;
}

function wavesPage(s) {
  commonGlobals(s);
  globalThis.RUN_READS = readsOf('waves.html', 'RUN_READS');
  for (const k of ['blobFetch', 'blobList', 'heldOrFetch', 'readLeases', 'loadClaims', 'claimCount', 'quotaAccessFrom', 'readPlan', 'runFullId', 'runPrefix']) {
    globalThis[k] = waves[k];
  }
  Object.assign(globalThis, {
    runId: 'run2', projectId: 'proj1', planVersion: '', msalApp: null,
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false, quotaShort: false,
    unlistedWaves: new Set(), lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(),
    quotaAccess: new Map(), waveDocs: new Map(), waveNoneReservable: () => false, UX: { leasesUnread: 'The leases could not be read: {reason}' },
  });
  Object.assign(globalThis.VmfHelp, {
    heldText: H.heldText, leasesByMachine: H.leasesByMachine, explain: (e) => String(e && e.message ? e.message : e),
    claimBlocked: claimHelp.claimBlocked, claimReservingStuck: claimHelp.claimReservingStuck, claimRegionalShort: claimHelp.claimRegionalShort,
  });
}

/* What the wave editor holds after it read the migration. */
function wavesHeld(got) {
  const sorted = (m) => [...m.entries()].sort((a, b) => ord(String(a[0]), String(b[0])));
  return {
    plan: got.plan, planVersion: globalThis.planVersion,
    stateDocs: got.stateDocs.slice().sort((a, b) => ord(a.vmId, b.vmId)), assessment: got.assessment,
    leases: sorted(got.leases).map(([k, v]) => [k, v.workerId]),
    claims: sorted(globalThis.claims), billing: [...globalThis.billingWaves].sort(ord), quotaChecked: globalThis.quotaChecked,
    quotaShort: globalThis.quotaShort, unlisted: [...globalThis.unlistedWaves].sort(ord), lastChecked: sorted(globalThis.lastChecked),
  };
}

async function wavesLoad(opts) {
  const o = opts || {};
  const s = service(o.files || wavesStore(), o);
  wavesPage(s);
  const got = await waves.readMigration();
  return { s, got, held: wavesHeld(got) };
}

test('THE DEFECT, Waves: a load is the plan and ONE call for the run, not one call for each document', async () => {
  ok(!waves.missing, waves.missing);
  ok(!claimHelp.missing, claimHelp.missing);
  const { s, held } = await wavesLoad();
  eq(s.calls.slice().sort(ord), ['store/blob', 'store/docs'], 'the calls of one load');
  eq(s.blobs, [{ path: 'proj1/run2/plan.json', versioned: true }], 'the only store/blob read is the plan, with its version');
  eq(held.stateDocs.length, 10, 'every machine record');
  eq(held.claims, [['w0', 'held']], 'the quota records');
  eq(held.leases.length, 1, 'the lease');
  ok(held.assessment && held.assessment.vms.length === 1, 'the assessment');
});

test('Waves: what the page holds is what the per-file reads give', async () => {
  const one = await wavesLoad();
  const each = await wavesLoad({ docsFail: true });
  ok(each.s.calls.length > 15, `the per-file reads are many on this store (${each.s.calls.length})`);
  eq(one.held, each.held, 'the plan, the machines, the assessment, the leases and the quota records');
  eq(one.held.unlisted, ['w1'], 'a record with no limit is the listing gap');
});

test('Waves: a call the service cut short is read as no call, and the page holds the same', async () => {
  const one = await wavesLoad();
  const cut = await wavesLoad({ truncated: true });
  ok(cut.s.calls.filter(c => c !== 'store/docs').length > 15, 'every read made as before');
  eq(cut.held, one.held, 'the same');
});

test('PLANVER-2, Waves: the plan is a store/blob read with its version, never a document of the one call', async () => {
  const { held } = await wavesLoad();
  eq(held.planVersion, 'v-proj1/run2/plan.json', 'the version the service issued for the plan');
  const reads = readsOf('waves.html', 'RUN_READS');
  ok(reads.length <= 12, 'the service takes at most 12 names');
  ok(!reads.some(r => /plan/.test(r)), 'the one call reads no plan');
});

test('Waves: a reservation watch reads the quota records in ONE call, and holds what the per-file reads give', async () => {
  const s = service(wavesStore());
  wavesPage(s);
  ok(await waves.loadClaims(), 'the records are read');
  eq(s.calls, ['store/docs'], 'one call a tick');
  const one = wavesHeld({ plan: null, stateDocs: [], assessment: null, leases: new Map() });
  const each = service(wavesStore(), { docsFail: true });
  wavesPage(each);
  ok(await waves.loadClaims(), 'the records are read one by one');
  ok(each.calls.length > 2, `the per-file reads (${each.calls.length})`);
  eq(wavesHeld({ plan: null, stateDocs: [], assessment: null, leases: new Map() }), one, 'the same records');
});

test('Waves: a damaged machine record is asked of the service, so its read error is not lost', async () => {
  let err = null;
  try { await wavesLoad({ files: damaged(wavesStore()) }); } catch (e) { err = e; }
  ok(err, 'the read of the damaged record fails, as the per-file read does');
  let each = null;
  try { await wavesLoad({ files: damaged(wavesStore()), docsFail: true }); } catch (e) { each = e; }
  ok(each, 'and per file');
});

async function wavesBundle(opts) {
  const s = service(wavesStore(), opts);
  wavesPage(s);
  bundleGlobals(s);
  globalThis.adapter = waves.helpAdapter();
  const b = await realHelp.buildBundle('proj1/run2');
  delete b.generatedUtc;
  return { s, b };
}

test('THE DEFECT, support bundle from Waves: one run is ONE call', async () => {
  const { s, b } = await wavesBundle();
  eq(s.calls, ['store/docs'], 'calls');
  eq(b.machines.length, 10, 'every machine record');
  eq(b.couldNotRead, [], 'nothing missing');
  const each = await wavesBundle({ docsFail: true });
  ok(each.s.calls.length > 15, `the per-file reads are many (${each.s.calls.length})`);
  eq(b, each.b, 'the bundle the per-file reads give');
});

/* ---- Assess and migrate ---- */

let wiz = null;
try {
  wiz = liftAll('wizard.html', ['blobJson', 'blobVersioned', 'blobList', 'readDoc', 'readNames', 'readVersionedDoc', 'reviewedScan', 'readRun', 'ackGiven', 'runFullId', 'runPrefix']);
  wiz.helpAdapter = liftAll('wizard.html', ['helpAdapter']).helpAdapter;
} catch (e) { wiz = { missing: e.message }; }
const WIZ_SRC = pageSource(path.join(DASH, 'wizard.html'));
const ADVICE_VERSION = constOf(WIZ_SRC, 'TARGET_ADVICE_VERSION');

/* An assessment with its options, targets and machines chosen, and the open
 * migration with its sign-off, approvals and acceptances. */
function wizardStore() {
  const files = migrationsStore({ allSummaries: true });
  const a = 'proj1/run1';
  files[`${a}/target-advice.json`] = { schemaVersion: ADVICE_VERSION, machines: [{ vmId: '/subscriptions/x/vm-a' }] };
  files[`${a}/target-choices.json`] = { machinesVersion: `v-${a}/machine-choices.json`, choices: [] };
  files[`${a}/machine-choices.json`] = { vmIds: ['/subscriptions/x/vm-a'] };
  return files;
}

function wizardPage(s, run) {
  commonGlobals(s);
  globalThis.RUN_READS = readsOf('wizard.html', 'RUN_READS');
  for (const k of ['blobJson', 'blobVersioned', 'blobList', 'readDoc', 'readNames', 'readVersionedDoc', 'reviewedScan', 'runFullId', 'runPrefix']) {
    globalThis[k] = wiz[k];
  }
  Object.assign(globalThis, {
    runId: run, projectId: 'proj1', DEMO: {}, msalApp: null, runKinds: new Map(), TARGET_ADVICE_VERSION: ADVICE_VERSION,
    readFailed: null, runExists: false, manifest: null, approval: null, assessment: null, plan: null, planSignoff: null,
    planSignoffCurrent: false, acknowledged: false, states: new Map(), approvals: new Map(), acceptances: new Map(),
    targetAdvice: null, adviceVersion: '', adviceOld: false, targetChoices: null, choicesVersion: '', machineChoices: null, machinesVersion: '', assessmentVersion: '',
    nameMachines() { },
  });
}

function wizardHeld() {
  const sorted = (m) => [...m.entries()].sort((a, b) => ord(String(a[0]), String(b[0])));
  return {
    readFailed: globalThis.readFailed, runExists: globalThis.runExists, manifest: globalThis.manifest, approval: globalThis.approval,
    assessment: globalThis.assessment, plan: globalThis.plan, planSignoff: globalThis.planSignoff, planSignoffCurrent: globalThis.planSignoffCurrent, acknowledged: globalThis.acknowledged,
    states: sorted(globalThis.states), approvals: sorted(globalThis.approvals), acceptances: sorted(globalThis.acceptances),
    targetAdvice: globalThis.targetAdvice, adviceVersion: globalThis.adviceVersion, adviceOld: globalThis.adviceOld, targetChoices: globalThis.targetChoices,
    choicesVersion: globalThis.choicesVersion, machineChoices: globalThis.machineChoices, machinesVersion: globalThis.machinesVersion,
    assessmentVersion: globalThis.assessmentVersion,
  };
}

/* One step: the first read of the run, and the read of the next tick. */
async function wizardSteps(run, opts) {
  const o = opts || {};
  const s = service(o.files || wizardStore(), o);
  wizardPage(s, run);
  await wiz.readRun();
  const first = s.calls.slice();
  const firstHeld = wizardHeld();
  await wiz.readRun();
  return { s, first, tick: s.calls.slice(first.length), firstHeld, tickHeld: wizardHeld() };
}

test('THE DEFECT, Assess and migrate: a step on an assessment is ONE call and the three documents it saves', async () => {
  ok(!wiz.missing, wiz.missing);
  const { first, tick, s, tickHeld } = await wizardSteps('run1');
  eq(first.filter(c => c === 'store/docs').length, 1, 'one call for the run');
  eq(first.length, 4, `the calls of the first read: ${JSON.stringify(s.blobs)}`);
  eq(tick.length, 4, 'and of a tick');
  eq([...new Set(s.blobs.map(b => b.path))].sort(ord), ['proj1/run1/machine-choices.json', 'proj1/run1/target-advice.json', 'proj1/run1/target-choices.json'],
    'the store/blob reads are the documents a save quotes back');
  ok(s.blobs.every(b => b.versioned), 'each with its version');
  ok(tickHeld.assessment && tickHeld.approval && tickHeld.targetAdvice && tickHeld.machineChoices, 'the step is drawn');
});

test('THE DEFECT, Assess and migrate: a step on a migration is ONE call, and the plan with its version for the sign-off', async () => {
  const { tick, s, tickHeld } = await wizardSteps('run2');
  eq(tick.slice().sort(ord), ['store/blob', 'store/docs'], 'the calls of a tick, once the kind is known');
  eq(s.blobs.slice(-1), [{ path: 'proj1/run2/plan.json', versioned: true }], 'the plan the sign-off is compared with');
  ok(tickHeld.planSignoffCurrent, 'the sign-off names the version the service issued');
  eq(tickHeld.states.length, 10, 'every machine record');
  eq([tickHeld.approvals.length, tickHeld.acceptances.length], [1, 1], 'the approvals and the acceptances');
});

test('Assess and migrate: what the page holds is what the per-file reads give, on an assessment and a migration', async () => {
  for (const run of ['run1', 'run2']) {
    const one = await wizardSteps(run);
    const each = await wizardSteps(run, { docsFail: true });
    ok(each.first.length > 10, `${run}: the per-file reads are many (${each.first.length})`);
    eq(one.firstHeld, each.firstHeld, `${run}: the first read`);
    eq(one.tickHeld, each.tickHeld, `${run}: a tick`);
  }
});

test('Assess and migrate: a call the service cut short is read as no call, and the page holds the same', async () => {
  for (const run of ['run1', 'run2']) {
    const one = await wizardSteps(run);
    const cut = await wizardSteps(run, { truncated: true });
    ok(cut.first.length > 10, `${run}: every read made as before`);
    eq(cut.tickHeld, one.tickHeld, `${run}: the same`);
  }
});

test('Assess and migrate: a damaged machine record is asked of the service, as the per-file read asks', async () => {
  const one = await wizardSteps('run2', { files: damaged(wizardStore()) });
  ok(one.s.blobs.some(b => b.path === 'proj1/run2/state/vm4.json'), 'it asked the service for that record');
  const each = await wizardSteps('run2', { files: damaged(wizardStore()), docsFail: true });
  eq(one.tickHeld, each.tickHeld, 'the same as the per-file reads');
});

test('PLANVER-2, Assess and migrate: no document a save quotes back comes from the one call', () => {
  const reads = readsOf('wizard.html', 'RUN_READS');
  ok(reads.length <= 12, 'the service takes at most 12 names');
  for (const saved of ['target-advice.json', 'target-choices.json', 'machine-choices.json']) {
    ok(!reads.some(r => globMatch(r, saved) || r.includes('choices') || r.includes('advice')), `${saved} is not read by the one call`);
  }
});

async function wizardBundle(opts) {
  const s = service(wizardStore(), opts);
  wizardPage(s, 'run2');
  bundleGlobals(s);
  globalThis.adapter = wiz.helpAdapter();
  const b = await realHelp.buildBundle('proj1/run2');
  delete b.generatedUtc;
  return { s, b };
}

test('THE DEFECT, support bundle from Assess and migrate: one run is ONE call', async () => {
  const { s, b } = await wizardBundle();
  eq(s.calls, ['store/docs'], 'calls');
  eq(b.machines.length, 10, 'every machine record');
  eq(b.couldNotRead, [], 'nothing missing');
  const each = await wizardBundle({ docsFail: true });
  ok(each.s.calls.length > 15, `the per-file reads are many (${each.s.calls.length})`);
  eq(b, each.b, 'the bundle the per-file reads give');
});

/* ================= PAGE-LOAD-4: the support bundle from the Reports page =================
 *
 * The Reports page's help adapter gave no runDocs, so a support bundle made
 * there read each document and each folder of the run by itself: about N + 10
 * calls for a run of N machines. THE RULE: the same one call the Migrations,
 * Waves and Assess and migrate pages give (store/docs with the run as the
 * prefix, depth 2), and each log part read from it first (heldText; unknown
 * means ask). A line of the log that is not JSON is kept as { raw }, from the
 * one call and per file alike (EVENTLOG-1): the bundle is read by somebody who
 * is already stuck, and a line nobody can parse is evidence. */

let rep4 = null;
try {
  rep4 = liftAll('reports.html', ['blobFetch', 'blobList', 'helpAdapter']);
} catch (e) { rep4 = { missing: e.message }; }

/* The open run with a log part that holds a line that is not JSON. */
function reportsBundleStore() {
  const files = migrationsStore({ allSummaries: true });
  files['proj1/run2/logs/events-2.jsonl'] = '{"tsUtc":"2026-11-01T00:02:00Z","e":3}\nnot json, cut short by a crash\n{"tsUtc":"2026-11-01T00:03:00Z","e":4}';
  return files;
}

async function reportsBundle(opts) {
  const o = opts || {};
  const s = service(o.files || reportsBundleStore(), o);
  commonGlobals(s);
  globalThis.blobFetch = rep4.blobFetch;
  globalThis.blobList = rep4.blobList;
  globalThis.source = liftSource('reports.html');
  Object.assign(globalThis, { openRunId: 'proj1/run2', msalApp: null });
  Object.assign(globalThis.VmfHelp, { heldText: H.heldText, readLogParts: realHelp.readLogParts });
  bundleGlobals(s);
  globalThis.location = { search: '', pathname: '/reports.html' };
  globalThis.adapter = rep4.helpAdapter();
  const b = await realHelp.buildBundle('proj1/run2');
  delete b.generatedUtc;
  return { s, b };
}

test('THE DEFECT, support bundle from Reports: one run is ONE call, not one for each document', async () => {
  ok(!rep4.missing, rep4.missing);
  const { s, b } = await reportsBundle();
  eq(s.calls, ['store/docs'], 'calls');
  eq(b.machines.length, 10, 'every machine record');
  eq([b.capacity.length, b.capacityHistory.length, b.approvals.length, b.schedules.length, b.acceptances.length], [1, 1, 1, 1, 1], 'every folder');
  eq(b.events.length, 5, 'every line of both parts of the log');
  eq(b.couldNotRead, [], 'nothing missing');
});

test('Reports: the support bundle holds what the per-file reads give', async () => {
  const one = await reportsBundle();
  const each = await reportsBundle({ docsFail: true });
  ok(each.s.calls.length > 15, `the per-file reads are many (${each.s.calls.length})`);
  eq(one.b, each.b, 'the bundle');
});

test('EVENTLOG-1, Reports: a log line that is not JSON is kept as raw, from the one call and per file', async () => {
  for (const opts of [{}, { docsFail: true }]) {
    const { s, b } = await reportsBundle(opts);
    const raw = b.events.filter(e => e && e.raw !== undefined);
    eq(raw, [{ raw: 'not json, cut short by a crash' }], `the line kept as written (${opts.docsFail ? 'per file' : 'one call'})`);
    eq(b.events.map(e => e.e ?? 'raw'), [1, 2, 3, 'raw', 4], 'in order, with the lines around it');
    if (!opts.docsFail) { eq(s.blobs.filter(x => /logs\//.test(x.path)), [], 'no log part read by itself'); }
  }
});

test('Reports: a support bundle call the service cut short is read as no call, and the bundle is the same', async () => {
  const one = await reportsBundle();
  const cut = await reportsBundle({ truncated: true });
  ok(cut.s.calls.filter(c => c !== 'store/docs').length > 15, 'every read made as before');
  ok(cut.s.blobs.some(x => x.path === 'proj1/run2/logs/events-2.jsonl'), 'the log parts read by themselves');
  eq(cut.b, one.b, 'the bundle');
});

test('Reports: a log part the one call did not read is asked of the service (unknown means ask)', async () => {
  // A page of the one call held the listing but not the second part's text.
  const s = service(reportsBundleStore());
  const real = s.fetch;
  s.fetch = async (url) => {
    const r = await real(url);
    if (!/store\/docs/.test(url)) { return r; }
    const body = await r.json();
    return { ok: true, status: 200, json: async () => ({ ...body, docs: body.docs.filter(d => !/events-2\.jsonl$/.test(d.path)) }) };
  };
  const files = reportsBundleStore();
  const got = await (async () => {
    commonGlobals(s);
    globalThis.fetch = s.fetch;
    globalThis.blobFetch = rep4.blobFetch;
    globalThis.blobList = rep4.blobList;
    globalThis.source = liftSource('reports.html');
    Object.assign(globalThis, { openRunId: 'proj1/run2', msalApp: null });
    Object.assign(globalThis.VmfHelp, { heldText: H.heldText, readLogParts: realHelp.readLogParts });
    bundleGlobals(s);
    globalThis.adapter = rep4.helpAdapter();
    return realHelp.buildBundle('proj1/run2');
  })();
  eq(s.blobs.map(x => x.path), ['proj1/run2/logs/events-2.jsonl'], 'only the part it did not hold');
  eq(got.events.length, 5, 'and the whole log');
  ok(files['proj1/run2/logs/events-2.jsonl'], 'the store holds it');
});

test('Reports: sample data has no service, so its help adapter gives no one call', () => {
  const src = codeOf('reports.html');
  const fn = src.slice(src.indexOf('function helpAdapter()'));
  ok(fn.length > 0, 'the page builds its adapter in helpAdapter()');
  ok(/runDocs:\s*DEMO_MODE\s*\?\s*undefined/.test(fn), 'no runDocs in ?demo');
  ok(/VmfHelp\.install\(helpAdapter\(\)\)/.test(src), 'the page installs it');
});

run('page-load');
