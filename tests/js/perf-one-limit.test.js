/* PERF-ONE-LIMIT-1: ONE limit of reads in flight for a whole page, not one
 * per walk.
 *
 * STORE-READ-2 put 8 reads in flight at most (STORE_READ_LIMIT). The Overview
 * and Projects pages walk the projects with mapLimited and, inside each
 * project, walk its runs with mapLimited again - each walk with its own 8, so
 * up to 8 x 8 = 64 reads were in flight, more with the two reads a run asks
 * for together. MEASURED (PERF-ANALYSIS-1, sections 3 and 4): 275 of 320 cold
 * starts in 7 days began less than 5 s after another call - the service adding
 * instances DURING a page load - and a load with a cold start took 38.0 s
 * (p50) against 4.8 s warm.
 *
 * THE RULE: every read a page sends to the service goes through ONE limiter
 * (VmfHelp.readLimiter), made once for the page. A slot is held for ONE read
 * and never across a wait for another read, so an outer walk can never hold
 * the slots its inner walks need. That is why it cannot deadlock, and the
 * tests below prove it with walks nested the way the pages nest them.
 *
 * These tests RUN the pages' own blobList, blobJson, load (and, on the
 * Overview, readRun, startedRuns and the safety-copies panel) against a fake
 * service whose every answer waits, and count what is in flight at once.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, extract, test, eq, ok, run } = require('./_harness');
const { scriptsOf, Unit } = require('./_html-sinks');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const LIMIT_MATCH = HELP.match(/const STORE_READ_LIMIT = (\d+);/);
if (!LIMIT_MATCH) { throw new Error('STORE_READ_LIMIT is not declared in help.js'); }
/* Read the REAL value: a literal 8 here would keep passing after the limit
 * changed. */
const LIMIT = Number(LIMIT_MATCH[1]);
globalThis.STORE_READ_LIMIT = LIMIT;

let readLimiter = null;
try { readLimiter = lift('help.js', 'readLimiter'); } catch { readLimiter = null; }
const { mapLimited, runFolderIsRun, runKind, storeHolds } = liftAll('help.js', ['mapLimited', 'runFolderIsRun', 'runKind', 'storeHolds']);

/* The page's own limiter, as the page declares it. If the page has none, the
 * reads pass straight through - so the counts below still MEASURE the page,
 * and say how far over the limit it goes. */
function pageLimiter(file) {
  const src = pageSource(path.join(DASH, file));
  const m = src.match(/\nconst storeRead = (VmfHelp\.readLimiter\(\s*\));/);
  // eslint-disable-next-line no-eval
  return m ? eval(m[1]) : ((fn) => fn());
}

/* The code of a page, comments and strings taken out by the reader every
 * dashboard test uses, so a comment that names a call is not taken for one. */
function codeOf(file) {
  return scriptsOf(file).map(sc => new Unit(file, sc.text, sc.line).code).join('\n');
}

const within = (promise, ms, what) => Promise.race([
  promise,
  new Promise((_, no) => setTimeout(() => no(new Error(`${what} did not finish in ${ms} ms - a deadlock`)), ms)),
]);

/* ---------------- the limiter itself ---------------- */

function counter() {
  const s = { live: 0, peak: 0, done: 0 };
  s.read = async (ms = 2) => {
    s.live++; s.peak = Math.max(s.peak, s.live);
    try { await new Promise(r => setTimeout(r, ms)); } finally { s.live--; }
    s.done++;
    return s.done;
  };
  return s;
}

test('help.js has the one limiter', () => {
  ok(typeof readLimiter === 'function', 'VmfHelp.readLimiter is not in help.js');
  ok(/readLimiter[,\s]/.test(HELP.slice(HELP.lastIndexOf('window.VmfHelp'))), 'readLimiter is not handed to the pages on VmfHelp');
});

test('the limiter never lets more than the limit through, and uses all of it', async () => {
  const s = counter();
  const gate = readLimiter();
  await Promise.all(Array.from({ length: 50 }, () => gate(() => s.read())));
  eq(s.peak, LIMIT, 'reads in flight at the peak');
  eq(s.done, 50, 'every read was made');
});

test('the limiter gives back what each read returns, and its error', async () => {
  const gate = readLimiter(2);
  eq(await gate(async () => 'doc'), 'doc', 'the answer');
  let threw = null;
  try { await gate(async () => { throw new Error('404'); }); } catch (e) { threw = e.message; }
  eq(threw, '404', 'the error reaches the caller');
});

test('a read that fails gives its slot back', async () => {
  // A slot kept by a failed read is a page that reads one slower each time,
  // and stops when it has lost them all.
  // Inside `within`: a read that waits for a slot nobody gives back is a
  // promise that never settles, and node would leave with nothing said.
  const gate = readLimiter(2);
  await within((async () => {
    for (let i = 0; i < 5; i++) { await gate(async () => { throw new Error('x'); }).catch(() => null); }
  })(), 2000, 'reads after a failed read');
  const s = counter();
  await within(Promise.all(Array.from({ length: 6 }, () => gate(() => s.read()))), 2000, 'reads after failures');
  eq(s.peak, 2, 'both slots are still there');
});

test('NESTED WALKS DO NOT DEADLOCK: outer walks waiting on inner walks hold no slot', async () => {
  // The shape of both pages: 8 projects at once, each reading its own
  // document, then walking its runs, 8 at once, each a read. A limiter that
  // let an outer walk keep a slot while its inner walk waited would stop
  // here with every slot held by a project and every run waiting.
  const s = counter();
  const gate = readLimiter();
  const projects = Array.from({ length: LIMIT * 2 }, (_, i) => i);
  await within(mapLimited(projects, async () => {
    await gate(() => s.read());
    await mapLimited(Array.from({ length: LIMIT * 2 }, (_, i) => i), () => gate(() => s.read()));
  }), 5000, 'the nested walk');
  eq(s.done, LIMIT * 2 + LIMIT * 2 * LIMIT * 2, 'every read was made');
  ok(s.peak <= LIMIT, `peak ${s.peak} reads in flight, limit ${LIMIT}`);
});

test('reads wait their turn in the order they were asked', async () => {
  // The project documents are asked for first; a run's reads must not pass
  // them and leave a project row waiting behind every run in the store.
  const gate = readLimiter(1);
  const started = [];
  await Promise.all([1, 2, 3, 4, 5].map(n => gate(async () => { started.push(n); await new Promise(r => setTimeout(r, 1)); })));
  eq(started, [1, 2, 3, 4, 5], 'the order the reads started in');
});

test('two limiters do not share slots - each page load makes its own', async () => {
  const a = readLimiter(1), b = readLimiter(1);
  const s = counter();
  await Promise.all([a(() => s.read(5)), b(() => s.read(5))]);
  eq(s.peak, 2, 'one in each');
});

/* ---------------- a fake service whose every answer waits ---------------- */

/* Four projects of six runs (assessments and migrations), three runs from
 * before projects, and ten machine documents in each migration. */
function fakeService() {
  const s = counter();
  const docs = {};
  const top = [];
  const kids = {};
  for (let p = 1; p <= 4; p++) {
    const pid = `proj${p}`;
    top.push(pid);
    docs[`${pid}/project.json`] = { projectId: pid, name: `Project ${p}`, createdUtc: '2026-11-01T00:00:00Z' };
    kids[pid] = [];
    for (let r = 1; r <= 6; r++) {
      const id = `${pid}/run${r}`;
      kids[pid].push(id);
      const kind = r % 2 ? 'assessment' : 'migration';
      docs[`${id}/run.json`] = { runId: `run${p}${r}`, kind };
      if (kind === 'assessment') { docs[`${id}/assessment.json`] = { vms: [1] }; }
      else { docs[`${id}/run-status.json`] = { schemaVersion: 4, runId: `run${p}${r}`, updatedUtc: '2026-11-01T00:00:00Z', stateCounts: {}, running: [] };
             docs[`${id}/plan.json`] = { entries: [] };
             for (let m = 1; m <= 10; m++) { docs[`${id}/state/vm${m}.json`] = { vmId: `vm${m}` }; } }
    }
  }
  for (let l = 1; l <= 3; l++) { top.push(`old${l}`); docs[`old${l}/run.json`] = { runId: `old${l}`, kind: 'migration' }; }
  s.lists = 0;
  s.storeList = async (getToken, apiUrl, prefix, delimiter) => {
    await s.read(); s.lists++;
    if (prefix === '') { return { prefixes: top.slice(), names: [] }; }
    const folder = prefix.replace(/\/$/, '');
    if (kids[folder] && delimiter === '/') { return { prefixes: kids[folder].slice(), names: [`${folder}/project.json`] }; }
    if (/\/state\/$/.test(prefix)) { return { prefixes: [], names: Object.keys(docs).filter(k => k.startsWith(prefix)) }; }
    // PERF-PROBES-1: a run's own folder names the files at its level, as the
    // service's listing does; the pages read only what a listing names.
    if (delimiter === '/') { return { prefixes: [], names: Object.keys(docs).filter(k => k.startsWith(prefix) && !k.slice(prefix.length).includes('/')) }; }
    return { prefixes: [], names: [] };
  };
  s.storeBlob = async (getToken, apiUrl, p) => {
    await s.read();
    if (!(p in docs)) { throw new Error('404'); }
    return docs[p];
  };
  // The list of runs and their stages, which the Overview asks the service
  // for beside the store.
  s.fetch = async () => {
    await s.read(10);
    return { ok: true, json: async () => [] };
  };
  return s;
}

/* ---------------- the Overview ---------------- */

const overview = liftAll('index.html',
  ['readHeld', 'blobList', 'blobJson', 'load', 'readRun', 'migrationFacts']);

function overviewPage(s) {
  globalThis.cfg = { apiUrl: 'https://service.example.com/api', apiAppId: 'x' };
  globalThis.getToken = async () => 'token';
  globalThis.fetch = s.fetch;
  globalThis.DEMO_MODE = false;
  globalThis.state = { projects: [], loose: [], runs: [] };
  globalThis.render = () => {};
  globalThis.esc = (v) => String(v ?? '');
  globalThis.ago = () => '';
  globalThis.runLink = (id) => `#${id}`;
  globalThis.UX = new Proxy({}, { get: () => '' });
  const card = { innerHTML: '' };
  globalThis.document = { createElement: () => card };
  globalThis.$ = () => ({ appendChild: () => {} });
  globalThis.VmfHelp = {
    mapLimited, runFolderIsRun, runKind, storeHolds,
    storeList: s.storeList, storeBlob: s.storeBlob,
    runSummaryOf: () => null, runWaitingCount: () => 0, runGateTag: () => '', runGroup: () => 'Running',
    retentionPassFacts: () => ({ ran: false, unfinished: false, failures: [], nextUtc: null }),
    safetyCopyLedger: (docsIn) => docsIn,
    safetyCopySummary: (rows) => ({ copies: rows.length, machines: rows.length, due: 0, unlocked: 0, earliestDueUtc: null }),
    readLimiter,
    // PAGE-LOAD-1: the one call fails, so the page makes the per-file reads
    // these tests measure (page-load.test.js measures the one call).
    storeDocs: async () => { throw new Error('per-file reads measured here'); }, heldList: () => undefined, heldJson: () => undefined, heldHas: () => undefined,
  };
  globalThis.held = null;
  globalThis.PANEL_READS = [];
  // Made AFTER VmfHelp, the way the page makes it after help.js loads.
  globalThis.storeRead = pageLimiter('index.html');
  return card;
}

test('THE DEFECT, Overview: reading the projects and their runs never has more than the limit in flight', async () => {
  const s = fakeService();
  overviewPage(s);
  await within(overview.load(), 10000, 'the Overview load');
  ok(s.peak <= LIMIT, `peak ${s.peak} reads in flight, limit ${LIMIT}`);
  eq(s.peak, LIMIT, 'and the limit is used, not one at a time');
  eq(globalThis.state.runs.length, 4 * 6 + 3, 'every run is read - nothing is dropped');
  eq(globalThis.state.projects.length, 4, 'every project');
});

/* PAGE-SCALE-REPORTS-1: the Safety copies card moved to the Reports page. Its
 * walk - every migration, then every machine record of each - is still the
 * widest, and when the page's one call failed it reads file by file. ONE
 * limit holds the whole walk there too. */
const reportsCopies = liftAll('reports.html', ['blobFetch', 'blobList', 'copiesRunIds', 'copiesFacts']);

test('Reports: the Safety copies card, the widest walk, stays under the same limit', async () => {
  const s = fakeService();
  overviewPage(s);
  const card = { innerHTML: '', className: '' };
  globalThis.document = { getElementById: (id) => (id === 'copies-card' ? card : null) };
  globalThis.blobFetch = reportsCopies.blobFetch;
  globalThis.blobList = reportsCopies.blobList;
  globalThis.VmfHelp.VmfRun = { link: (page, id) => `${page}#${id}` };
  globalThis.rows = [];
  for (let p = 1; p <= 4; p++) { for (const r of [2, 4, 6]) { globalThis.rows.push({ r: `proj${p}/run${r}` }); } }
  globalThis.storeRuns = globalThis.rows.map(x => x.r);
  globalThis.assessmentIds = new Set();
  globalThis.copiesRunIds = reportsCopies.copiesRunIds;
  try {
    const facts = await within(reportsCopies.copiesFacts(), 10000, 'the Safety copies card');
    ok(s.peak <= LIMIT, `peak ${s.peak} reads in flight, limit ${LIMIT}`);
    eq(s.peak, LIMIT, 'and the limit is used, not one at a time');
    ok(facts.per.some(p => p.id === 'proj1/run2' && p.summary.copies > 0), 'a migration that keeps copies is counted');
  } finally { delete globalThis.document; }
});

/* PAGE-LOAD-1, rewritten on purpose: the list of runs is no longer asked for.
 * The call that takes its place - the documents the page draws, in one call -
 * takes a slot like the reads. */
test('Overview: the one call for the documents counts against the same limit', async () => {
  const s = fakeService();
  overviewPage(s);
  const seen = [];
  globalThis.VmfHelp.storeDocs = async () => { seen.push(s.live); await s.read(); return null; };
  // Fill every slot first, then ask: it must wait for one.
  const hold = Array.from({ length: LIMIT }, () => globalThis.storeRead(() => s.read(20)));
  const asked = overview.readHeld(3, ['run.json']);
  await within(Promise.all([...hold, asked]), 5000, 'the reads and the one call');
  ok(seen.length === 1 && seen[0] < LIMIT, `the one call was sent with ${seen[0]} reads already in flight`);
});

/* ---------------- Projects ---------------- */

// CLICKS-LOST-1: load keeps a project made on the page (withMade), and only its newest walk sets the list.
// PAGE-SCALE-PROJECTS-1: and reads each migration's status for the count that waits for a person.
const projectsPage = liftAll('projects.html', ['blobList', 'blobJson', 'load', 'withMade', 'latestTime', 'migrationWaiting']);
const runCounts = liftAll('help.js', ['runSummaryOf', 'runWaitingCount']);
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'), 'utf8').match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);

test('THE DEFECT, Projects: reading the projects and their runs never has more than the limit in flight', async () => {
  const s = fakeService();
  globalThis.cfg = { apiUrl: 'https://service.example.com/api', apiAppId: 'x' };
  globalThis.getToken = async () => 'token';
  globalThis.DEMO_MODE = false;
  globalThis.render = () => {};
  globalThis.byName = (a, b) => String(a.name).localeCompare(String(b.name));
  globalThis.projects = [];
  globalThis.loose = [];
  Object.assign(globalThis, { withMade: projectsPage.withMade, latestTime: projectsPage.latestTime, migrationWaiting: projectsPage.migrationWaiting,
                              madeHere: new Map(), loadTurn: 0, drawListWhenFree: () => {} });
  globalThis.VmfHelp = { mapLimited, runFolderIsRun, runKind, storeHolds, storeList: s.storeList, storeBlob: s.storeBlob, readLimiter, ...runCounts,
    // PAGE-LOAD-1: the one call fails, so the page makes the per-file reads
    // these tests measure (page-load.test.js measures the one call).
    storeDocs: async () => { throw new Error('per-file reads measured here'); }, heldList: () => undefined, heldJson: () => undefined, heldHas: () => undefined, };
  globalThis.held = null;
  globalThis.LIST_READS = [];
  globalThis.storeRead = pageLimiter('projects.html');
  await within(projectsPage.load(), 10000, 'the Projects load');
  ok(s.peak <= LIMIT, `peak ${s.peak} reads in flight, limit ${LIMIT}`);
  eq(s.peak, LIMIT, 'and the limit is used, not one at a time');
  eq(globalThis.projects.length, 4, 'every project');
  eq(globalThis.projects.map(p => p.assessments + p.migrations), [6, 6, 6, 6], 'every run counted');
  eq(globalThis.loose.length, 3, 'every run from before projects');
});

/* ---------------- no read goes round the limiter ---------------- */

for (const file of ['index.html', 'projects.html']) {
  test(`${file}: the page makes ONE limiter, and every read to the store goes through it`, () => {
    const code = codeOf(file);
    eq((code.match(/\bconst storeRead = VmfHelp\.readLimiter\(\s*\);/g) || []).length, 1, 'one limiter, at the default limit');
    eq((code.match(/\bVmfHelp\.readLimiter\(/g) || []).length, 1, 'and no second one');
    // Only blobList and blobJson call the store, and each through the limiter.
    const list = extract(file, 'blobList'), blob = extract(file, 'blobJson');
    ok(/storeRead\(\s*\(\)\s*=>\s*VmfHelp\.storeList\(/.test(list), 'blobList goes through the limiter');
    ok(/storeRead\(\s*\(\)\s*=>\s*VmfHelp\.storeBlob\(/.test(blob), 'blobJson goes through the limiter');
    eq((code.match(/\bVmfHelp\.store(List|Blob)\(/g) || []).length, 2, 'no other call to the store on the page');
  });
}

test('index.html: every call to the service that reads goes through the limiter', () => {
  // The calls left outside are the page's own config file and the writes; a
  // new read added with fetch must take a slot like the rest.
  const code = codeOf('index.html');
  const fetches = code.match(/\bfetch\(/g) || [];
  // PAGE-LOAD-1: the list of runs is gone; the one call goes through the limiter.
  eq(fetches.length, 1, 'fetch calls on the page (the config file)');
  ok(/storeRead\(\s*\(\)\s*=>\s*VmfHelp\.storeDocs\(/.test(extract('index.html', 'readHeld')), 'the one call takes a slot');
});

/* A read that waits for a slot nobody gives back is a promise that never
 * settles. The harness fails a file whose test never finished, and names the
 * test (TEST-JS-HANG-1). */
run('perf-one-limit');
