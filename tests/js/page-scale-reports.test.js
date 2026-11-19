/* PAGE-SCALE-REPORTS-1, 2026-11-07. The Reports page: count tiles and one
 * list in two tabs (the migration runs, and the records to download), with a
 * project choice, a search and pages of 10. And the Safety copies card, which
 * MOVED here from the Overview (ruling, 2026-11-07; it closes
 * PAGE-SCALE-COPIES-1).
 *
 * WHAT WAS WRONG. The page drew every migration in one table and every kept
 * record in a second, each by its raw run id, with no search and no pages. With
 * many migrations it was one long scroll. The shape was approved on
 * 2026-11-07, the same one the Overview, Projects and Assessments have.
 *
 * WHAT IS TESTED. The page's own functions, run: which runs each tile holds,
 * what each column says, the report button on the row, the records tab (for an
 * administrator only), the detail of a migration that its name opens on this
 * page (Close, Escape, the keyboard back on the name, and ?run=), the projects
 * from the one call the page already makes, and the Safety copies card: on
 * this page, in the words it had, and gone from the Overview. The shared piece
 * itself is page-scale-list.test.js.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, extract, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const PAGE = pageSource(path.join(DASH, 'reports.html'));
const OVERVIEW = pageSource(path.join(DASH, 'index.html'));

// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
globalThis.LIST_PAGE_SIZE = Number((HELP.match(/const LIST_PAGE_SIZE = (\d+);/) || [])[1]);
globalThis.LIST_LOOSE = (HELP.match(/const LIST_LOOSE = '([^']*)';/) || [])[1];
globalThis.LIST_TONES = eval((HELP.match(/const LIST_TONES = (\[[^\]]*\]);/) || [])[1]); // eslint-disable-line no-eval
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const shared = liftAll('help.js', ['runParse', 'runStorePath', 'runLink', 'runFromQuery', 'listHref', 'listMatches', 'listView',
  'listSort', 'listSortValue', 'listDefaultTile', 'listRangeText', 'listTone', 'listTag', 'listCell', 'listOpenAttrs',
  'listCellClass', 'listAction', 'listNotePart', 'listTilesHtml', 'listTableHtml', 'listPagerHtml', 'listControlsHtml',
  'listTabsHtml', 'listMount', 'agoText', 'runTitle', 'mapLimited', 'runFolderIsRun', 'runKind']);
const VmfRun = { parse: shared.runParse, storePath: shared.runStorePath, link: shared.runLink, fromQuery: shared.runFromQuery };
globalThis.VmfHelp = Object.assign({}, shared, { VmfRun, LIST_LOOSE: globalThis.LIST_LOOSE });

const UX = liftConst('reports.html', 'UX');
globalThis.UX = UX;
globalThis.reading = false;
globalThis.isAdmin = false;
globalThis.projects = [];
globalThis.kept = [];
globalThis.keptError = '';
globalThis.keptReading = false;
globalThis.day = (iso) => (iso ? `day(${iso})` : '');
const page = liftAll('reports.html', ['num', 'outcomeState', 'outcomeTag', 'projectName', 'runRow', 'runTiles', 'runColumns',
  'recordRow', 'recordRows', 'recordColumns', 'reportTabs', 'projectChoices']);
Object.assign(globalThis, page);

// A row as loadSummaries makes it.
const r = (id, o) => Object.assign({ r: id, createdUtc: '2026-10-03T10:00:00Z', updatedUtc: '2026-11-06T10:00:00Z',
  setupOnly: false, hasReport: false, total: 4, waves: 1, migrated: 0, putBack: 0, restored: 0, attention: 0, leftOut: 0,
  working: 0, notStarted: 0 }, o || {});
const done = (id, o) => r(id, Object.assign({ migrated: 4 }, o || {}));
const tileOf = (tiles, key) => tiles.find(t => t.key === key);

/* ---- the approved design ---------------------------------------------- */

test('the tiles, in the approved words: every real migration, Finished, In progress, Needs attention now', () => {
  const list = [done('p/a'), r('p/b', { migrated: 2, notStarted: 2 }), r('p/c', { migrated: 3, attention: 1 }),
                r('p/d', { migrated: 1, working: 1, attention: 1, notStarted: 1 }), r('p/setup', { setupOnly: true, total: 0 })];
  const tiles = page.runTiles(list);
  eq(tiles.map(t => t.key), ['all', 'done', 'going', 'attention', 'setup']);
  // MANUAL-REVIEW-1: a migration with no plan is Not planned; never got past setup was an idiom.
  eq(tiles.map(t => t.label), ['Migration runs', 'Finished', 'In progress', 'Needs attention now', 'Not planned']);
  eq(tileOf(tiles, 'all').rows.map(x => x.id), ['p/a', 'p/b', 'p/c', 'p/d'], 'every migration that was planned');
  eq(tileOf(tiles, 'done').rows.map(x => x.id), ['p/a']);
  eq(tileOf(tiles, 'going').rows.map(x => x.id), ['p/b', 'p/d']);
  eq(tileOf(tiles, 'attention').rows.map(x => x.id), ['p/c', 'p/d'], 'a machine waits for a person NOW, in a run that is still going too');
  eq(tileOf(tiles, 'attention').tone, 'bad');
  eq(tileOf(tiles, 'setup').rows.map(x => x.id), ['p/setup'], 'scanned and never planned: listed, never counted as a migration (RUN-LIFECYCLE-1)');
  ok(tileOf(tiles, 'setup').hint, 'the tile says why it is apart');
  ok(tiles.every(t => t.empty && t.title), 'each tile names its list and says something when it holds no run');
});

test('while the store is read, the list is given the Reading sentence and told so, not that there is none (WAIT-1, LOADING-LINE-1)', () => {
  // The shared list shows the sentence on every tile while it reads
  // (loading-line.test.js); the page gives it the sentence and the state.
  const { renderTable } = liftAll('reports.html', ['renderTable']);
  const mounts = [];
  const saved = { VmfHelp: globalThis.VmfHelp, $: globalThis.$, openAskedDetail: globalThis.openAskedDetail, reportTabs: globalThis.reportTabs,
                  runTiles: globalThis.runTiles, projectChoices: globalThis.projectChoices, rows: globalThis.rows };
  try {
    Object.assign(globalThis, {
      VmfHelp: Object.assign({}, globalThis.VmfHelp, { listMount: (host, cfg) => { const m = { cfg, updates: [] }; mounts.push(m); return { update: (d) => m.updates.push(d) }; } }),
      $: () => ({ addEventListener() {} }), openAskedDetail: () => {}, reportTabs: () => [], runTiles: page.runTiles,
      projectChoices: () => [], rows: [], reportList: null, onListClick: () => {},
    });
    globalThis.reading = true;
    renderTable();
    eq(mounts[0].cfg.waiting, UX.waiting, 'the sentence');
    eq(mounts[0].updates[0].reading, true, 'reading');
    globalThis.reading = false;
    renderTable();
    eq(mounts[0].updates[1].reading, false, 'the read ended');
    eq(tileOf(mounts[0].updates[1].tiles, 'all').empty, UX.noRuns);
  } finally { globalThis.reading = false; globalThis.reportList = null; Object.assign(globalThis, saved); }
});

test('the columns, in the approved order and words', () => {
  const cols = page.runColumns();
  eq(cols.map(c => c.head), ['Migration', 'Project', 'Outcome', 'Machines', 'Last change', 'Report']);
  eq(cols.map(c => c.kind), ['name', 'text', 'tag', 'num', 'ago', 'actions']);
  eq(UX.searchHint, 'Migration or project');
  eq(UX.pageTitle, 'Reports');
  eq(UX.lede, 'The result of each migration, and its full record to download.');
});

test('a row: the readable name, the project by name, the run id kept for the search, and the name opens it here', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  const x = page.runRow(done('pay/migration-1', { createdUtc: '2026-10-03T10:00:00Z' }));
  eq([x.id, x.projectId, x.project], ['pay/migration-1', 'pay', 'Payments']);
  ok(/^Payments · migration of /.test(x.name), x.name);
  eq(VmfHelp.listHref(x.dest), 'reports.html?run=migration-1&project=pay', 'the name has an address of its own');
  eq(x.open, { action: 'detail', value: 'pay/migration-1' }, 'and opens the migration on this page');
  eq(x.machines, 4);
  eq(x.changed, '2026-11-06T10:00:00Z', 'the last change');
  eq(page.runRow(r('p/x', { updatedUtc: null })).changed, '2026-10-03T10:00:00Z', 'no status yet: when it was made');
  eq(page.runRow(r('old-run')).project, 'Outside a project', 'a run from before projects');
  eq(page.runRow(r('gone/x')).project, 'gone', 'a project with no name read is named by its id');
  globalThis.projects = [];
});

test('Outcome: a tag that says how it ended, and the counts behind it after the tag (OUTCOME-WORDS-1)', () => {
  const fin = page.outcomeTag(done('p/a', { migrated: 5, putBack: 1, total: 6 }));
  eq([fin.text, fin.tone], ['Finished', 'good']);
  eq(fin.note, '5 migrated, 1 restored by a person');
  const att = page.outcomeTag(r('p/b', { migrated: 3, attention: 1 }));
  eq([att.text, att.tone], ['Needs attention', 'bad']);
  ok(att.note.includes('1 waiting for a person'), 'how many wait: ' + att.note);
  const going = page.outcomeTag(r('p/c', { migrated: 1, working: 2, notStarted: 1 }));
  eq([going.text, going.tone], ['In progress', 'quiet']);
  eq(going.note, '1 migrated, 2 moving now, 1 not started');
  eq(page.runRow(r('p/s', { setupOnly: true, total: 0 })).outcome, { text: 'Not planned', tone: 'quiet' });
});

test('Report: the button shows on the row only when the migration has a report, in the words the manual uses', () => {
  eq(page.runRow(r('p/a', { hasReport: true })).actions, [{ text: 'Open the full report', action: 'report', value: 'p/a' }]);
  eq(page.runRow(r('p/b')).actions, []);
  const setup = page.runRow(r('p/s', { setupOnly: true, total: 0 }));
  eq([setup.machines, setup.actions], ['', []], 'a run that never got past setup has no count and no report');
});

/* ---- the records, for an administrator -------------------------------- */

const rec = (o) => Object.assign({ Name: 'pay-migration-1.json', RunId: 'migration-1', Project: 'pay', Reason: 'waveClosed',
  GeneratedUtc: '2026-11-01T10:00:00Z', KeepUntilUtc: '2027-01-30T10:00:00Z' }, o || {});

test('a record: the migration by name, why it was written, when, kept until, and Download the record', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  const created = new Map([['pay/migration-1', '2026-10-03T10:00:00Z']]);
  const x = page.recordRow(rec(), created);
  eq([x.id, x.projectId, x.project], ['pay/migration-1', 'pay', 'Payments']);
  ok(/^Payments · migration of /.test(x.name), 'named by the day the migration was made: ' + x.name);
  eq(x.dest, undefined, 'no address: a deleted migration has no page');
  eq([x.why, x.written, x.kept], ['a wave finished', 'day(2026-11-01T10:00:00Z)', 'day(2027-01-30T10:00:00Z)']);
  eq(x.actions, [{ text: 'Download the record', action: 'record', value: 'pay-migration-1.json' }]);
  const gone = page.recordRow(rec({ RunId: 'migration-9', Reason: 'deleted' }), created);
  eq(gone.name, 'Payments · migration', 'a migration the page does not hold has no date to name it by');
  eq(gone.why, 'the migration was deleted');
  const loose = page.recordRow(rec({ Project: null, RunId: 'old-run', Reason: 'somethingNew' }), created);
  eq([loose.id, loose.projectId, loose.project, loose.why], ['old-run', null, 'Outside a project', 'somethingNew']);
  globalThis.projects = [];
});

test('the records are newest first', () => {
  globalThis.kept = [rec({ Name: 'a', GeneratedUtc: '2026-10-01T00:00:00Z' }), rec({ Name: 'b', GeneratedUtc: '2026-11-02T00:00:00Z' })];
  eq(page.recordRows([]).map(x => x.actions[0].value), ['b', 'a']);
  globalThis.kept = [];
});

test('the record columns, in the approved order and words', () => {
  const cols = page.recordColumns();
  eq(cols.map(c => c.head), ['Migration', 'Written because', 'Written', 'Kept until', 'Record']);
  eq(cols.map(c => c.kind), ['name', 'text', 'text', 'text', 'actions']);
});

test('the tabs: only an administrator has the records, so only an administrator has two tabs', () => {
  globalThis.isAdmin = false;
  eq(page.reportTabs([]), [], 'no tabs: the list is the runs, as the role allows');
  globalThis.isAdmin = true;
  try {
    const tabs = page.reportTabs([]);
    eq(tabs.map(t => [t.key, t.label]), [['runs', 'Migration runs'], ['records', 'Records to download']]);
    eq(tabs[0].list, undefined, 'the runs tab shows the tiles\' rows');
    eq(tabs[1].list.title, 'Records of each migration', 'the name the manual uses');
    eq(tabs[1].list.intro, UX.recordsHint, 'and what a record is, and that it is kept 90 days');
    eq(tabs[1].list.empty, UX.recordsNone);
    globalThis.keptReading = true;
    eq(page.reportTabs([]).list, undefined);
    eq(page.reportTabs([])[1].list.empty, UX.recordsWaiting, 'while it reads, it says so');
    globalThis.keptReading = false;
    globalThis.keptError = 'refused <x>';
    eq(page.reportTabs([])[1].list.empty, 'refused <x>', 'a read that failed says why (the list escapes it)');
  } finally { globalThis.isAdmin = false; globalThis.keptError = ''; globalThis.keptReading = false; }
});

test('the project choice: every project, then the runs and records from before projects', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }, { id: 'web', name: 'Web' }];
  eq(page.projectChoices([r('pay/a')], []), [{ id: 'pay', name: 'Payments' }, { id: 'web', name: 'Web' }]);
  eq(page.projectChoices([r('old')], []).pop(), { id: LIST_LOOSE, name: 'Outside a project' });
  globalThis.kept = [rec({ Project: null, RunId: 'old' })];
  eq(page.projectChoices([], []).pop(), { id: LIST_LOOSE, name: 'Outside a project' }, 'a record outside a project counts too');
  globalThis.kept = [];
  globalThis.projects = [];
});

/* ---- the list, mounted ------------------------------------------------- */

test('the list is mounted ONCE, with the approved choices, and drawn again as the page reads', () => {
  const fn = extract('reports.html', 'renderTable');
  eq((fn.match(/VmfHelp\.listMount\(/g) || []).length, 1);
  ok(/if \(!reportList\)/.test(fn), 'mounted once: a person\'s tile, search and page stay while the page reads');
  ok(/preferred: 'all'/.test(fn), 'it opens on every migration, as the design shows');
  ok(/tabsLabel: UX\.tabsLabel/.test(fn) && /searchHint: UX\.searchHint/.test(fn));
  ok(/tiles: runTiles\(rows\)/.test(fn) && /tabs: reportTabs\(rows\)/.test(fn) && /projects: projectChoices\(rows\)/.test(fn));
});

/* A click on the list, as onListClick reads it. */
function clickOn(sel, data, extra) {
  return Object.assign({ target: { closest: (s) => (s === sel ? data : null) }, button: 0, preventDefault() { this.stopped = true; } }, extra || {});
}

test('a row\'s buttons: Open the full report shows the report, Download the record saves the record', async () => {
  const { onListClick } = liftAll('reports.html', ['onListClick']);
  const asked = [];
  globalThis.openReport = async (run, btn) => { asked.push(['report', run, btn.id]); };
  globalThis.fetchKeptRecord = async (name) => ({ name });
  globalThis.downloadRecord = async (get, btn) => { asked.push(['record', (await get()).name, btn.id]); };
  globalThis.openDetail = (run) => { asked.push(['detail', run]); return true; };
  globalThis.$ = () => ({ style: {} });
  onListClick(clickOn('button[data-action="report"]', { id: 'b1', dataset: { value: 'p/a' } }));
  onListClick(clickOn('button[data-action="record"]', { id: 'b2', dataset: { value: 'p-a.json' } }));
  await new Promise(res => setTimeout(res, 0));
  eq(asked, [['report', 'p/a', 'b1'], ['record', 'p-a.json', 'b2']]);
});

test('the name opens the migration on this page; a click for a new tab keeps the address', () => {
  const { onListClick } = liftAll('reports.html', ['onListClick']);
  const opened = [];
  globalThis.openDetail = (run, opener) => { opened.push([run, opener.id]); return true; };
  const link = { id: 'n1', dataset: { value: 'p/a' } };
  const plain = clickOn('a[data-action="detail"]', link);
  onListClick(plain);
  eq(opened, [['p/a', 'n1']]);
  ok(plain.stopped, 'the page does not leave');
  const newTab = clickOn('a[data-action="detail"]', link, { ctrlKey: true });
  onListClick(newTab);
  eq(opened.length, 1, 'ctrl-click opens a new tab, at the same address');
  ok(!newTab.stopped);
});

/* ---- the detail of a migration ------------------------------------------ */

function detailDom() {
  const els = {};
  const el = (id) => (els[id] = els[id] || { id, hidden: true, textContent: '', innerHTML: '', focused: 0,
    focus() { this.focused++; }, querySelectorAll: () => [], addEventListener() {} });
  ['run-detail', 'detail-title', 'detail-run', 'detail-body', 'detail-close', 'report-view'].forEach(el);
  globalThis.document = { getElementById: (id) => els[id] || null, querySelectorAll: () => [] };
  globalThis.$ = (s) => els[s.replace(/^#/, '')] || el(s.replace(/^#/, ''));
  return els;
}

test('the name opens the migration\'s detail below the list, with Close; Close and Escape put the keyboard back on the name', async () => {
  const els = detailDom();
  els['report-view'].hidden = true;
  const fns = liftAll('reports.html', ['openDetail', 'closeDetail', 'detailKey', 'detailTitle']);
  globalThis.rows = [done('p/a')];
  globalThis.location = { search: '' };
  globalThis.openRunId = null;
  globalThis.detailOpener = null;
  globalThis.detailRun = null;
  globalThis.showDetail = async () => {};
  try {
    const name = { focus() { this.focused = true; } };
    ok(fns.openDetail('p/a', name), 'opened');
    eq(els['run-detail'].hidden, false, 'the detail shows');
    ok(/· migration of /.test(els['detail-title'].textContent), 'headed by the row\'s own name');
    eq(els['detail-run'].textContent, 'p/a', 'the run id under it');
    eq(els['detail-close'].textContent, 'Close', 'rule 11: Close, because the detail only shows information');
    eq(els['detail-close'].focused, 1, 'the keyboard goes to Close');
    eq(globalThis.openRunId, 'p/a', 'help offers this run (EVAL-M14)');
    let stopped = false;
    ok(fns.detailKey({ key: 'Escape', preventDefault() { stopped = true; } }), 'Escape is taken');
    ok(stopped);
    eq(els['run-detail'].hidden, true, 'Escape closes it');
    ok(name.focused, 'the keyboard is back on the name');
    eq(globalThis.openRunId, null, 'help is back to what the address says');
    ok(!fns.detailKey({ key: 'Escape', preventDefault() {} }), 'Escape with nothing open is not taken');
    ok(!fns.openDetail('p/nothing', name), 'a run the page does not hold opens nothing');
  } finally { delete globalThis.document; }
});

test('Escape closes the report over the page first, then the detail', () => {
  const { onKey } = liftAll('reports.html', ['onKey']);
  const said = [];
  globalThis.reportKey = () => { said.push('report'); return true; };
  globalThis.detailKey = () => { said.push('detail'); return true; };
  onKey({ key: 'Escape' });
  eq(said, ['report'], 'the report took it');
  globalThis.reportKey = () => false;
  onKey({ key: 'Escape' });
  eq(said, ['report', 'detail']);
});

test('?run= opens that migration\'s detail once, after the store is read', () => {
  const { openAskedDetail } = liftAll('reports.html', ['openAskedDetail']);
  const opened = [];
  globalThis.openDetail = (run) => { opened.push(run); return true; };
  globalThis.location = { search: '?run=migration-1&project=pay' };
  globalThis.detailAsked = false;
  globalThis.reading = true;
  openAskedDetail();
  eq(opened, [], 'not while the store is read');
  globalThis.reading = false;
  openAskedDetail();
  openAskedDetail();
  eq(opened, ['pay/migration-1'], 'once');
  globalThis.location = { search: '' };
});

test('the detail is the per-run detail the row opened before: the waves, the people, the capacity, the links', () => {
  const fn = extract('reports.html', 'showDetail');
  for (const want of ['UX.wavesHead', 'UX.issuesHead', 'UX.capacityHead', 'signoffCell(', "VmfRun.link('migrations.html', run)", "recordButton('data-record', run)"]) {
    ok(fn.includes(want), want);
  }
  ok(/isAdmin \? recordButton/.test(fn), 'Download the record for an administrator only');
});

/* ---- the page's own head, and its markup ------------------------------- */

test('the page has its heading and sentence, the list, the detail with its Close button, and the Safety copies card', () => {
  ok(/<h1 id="page-title" tabindex="-1"><\/h1>/.test(PAGE), 'a heading');
  ok(/<p class="lede" id="lede"><\/p>/.test(PAGE));
  ok(/<div id="reports-list"><\/div>/.test(PAGE), 'the list');
  ok(/<section class="card" id="run-detail" aria-labelledby="detail-title" hidden>/.test(PAGE), 'the detail, hidden until a name is selected');
  ok(/<button type="button" id="detail-close" class="btn small ghost"><\/button>/.test(PAGE), 'with a way back');
  ok(/<div id="copies-card"><\/div>/.test(PAGE), 'the Safety copies card');
  ok(!/id="runs-table"|id="records-table"|id="kpis"/.test(PAGE), 'the two long tables and the old tiles are gone');
});

test('the projects come from the one call the page already makes, and the cleanup record too', () => {
  const reads = (PAGE.match(/const LIST_READS = (\[[^\]]*\]);/) || [])[1];
  ok(reads, 'LIST_READS');
  // eslint-disable-next-line no-eval
  const list = eval(reads);
  ok(list.includes('project.json'), 'project.json, for the project names');
  ok(list.includes('retention-status.json'), 'the daily cleanup\'s record, for the Safety copies card');
  ok(list.includes('state/*.json') && list.includes('plan.json'), 'the machine records and plans the card counts');
});

/* ---- the Safety copies card moved from the Overview -------------------- */

// The words the Overview card had on 2026-11-07. The box on this page now
// gets the list's treatment too (fix round): the words that
// count (the line and the cleanup line) now say 1 in the singular, and the
// rest are kept as they were.
const COPIES_WORDS = {
  copiesTitle: 'Safety copies',
  copiesHint: 'A restore of a migrated machine uses these copies. They are kept until its retention ends.',
  copiesNone: 'No safety copies are kept right now.',
  copiesUnlocked: '{n} of them carry no lock, so anyone with Contributor rights could delete them.',
  copiesPassNone: 'The daily cleanup has not run since this installation started. It runs every day at 03:30 UTC.',
  copiesPassFail: 'The last daily cleanup reported a problem: {reason}',
  copiesNext: 'Next cleanup at {when}.',
  copiesNextOpen: 'The next hourly pass continues it at {when}.',
  copiesError: 'The safety copies could not be read: {reason}',
  copiesCol: 'Migration',
  copiesKept: 'Copies kept',
  copiesDue: 'Due next cleanup',
  copiesEarliest: 'Earliest deletion',
  copiesOpen: 'Open',
};

test('THE MOVE: the Reports page has the Safety copies card, in the words the Overview card had', () => {
  for (const [k, v] of Object.entries(COPIES_WORDS)) { eq(UX[k], v, k); }
  for (const name of ['safetyPanel', 'copiesFacts', 'drawCopies', 'copiesPassText', 'whenLocal']) { ok(extract('reports.html', name), name); }
});

test('THE MOVE: the Overview has no Safety copies card, no words for it, and no second call for it', () => {
  const words = liftConst('index.html', 'UX');
  ok(!Object.keys(words).some(k => /^copies/.test(k)), 'no copies words: ' + Object.keys(words).filter(k => /^copies/.test(k)));
  for (const name of ['safetyPanel', 'copiesPassText']) {
    let found = true;
    try { extract('index.html', name); } catch { found = false; }
    ok(!found, `${name} is gone from the Overview`);
  }
  ok(!/COPIES_READS|DEMO_COPIES|copies-card/.test(OVERVIEW), 'nothing of the card is left');
  ok(!/safetyPanel\(\)/.test(OVERVIEW), 'and nothing draws it');
});

/* ---- the Safety copies box: the list's treatment (fix round) ----------- */

globalThis.VmfHelp.countWords = lift('help.js', 'countWords');
globalThis.whenLocal = (iso) => (iso ? `AT(${iso})` : '');
const copies = liftAll('reports.html', ['copiesRow', 'copiesColumns', 'copiesLineText', 'copiesPassText', 'drawCopies']);

test('the summary line says 1 in the singular: 1 safety copy, 1 machine, 1 migration', () => {
  eq(copies.copiesLineText({ copies: 1, machines: 1, due: 1 }, 1), '1 safety copy kept for 1 machine across 1 migration. 1 due for the next cleanup.');
  eq(copies.copiesLineText({ copies: 7, machines: 4, due: 2 }, 3), '7 safety copies kept for 4 machines across 3 migrations. 2 due for the next cleanup.');
});

test('the cleanup line says 1 in the singular: 1 migration checked, 1 machine due, 1 cleanup started', () => {
  const facts = liftAll('help.js', ['retentionPassFacts', 'nextRetentionPassUtc']);
  globalThis.VmfHelp.retentionPassFacts = (p) => facts.retentionPassFacts(p, '2026-11-02T09:50:00Z');
  globalThis.VmfHelp.agoText = () => '1h ago';
  const one = { schemaVersion: 1, lastPassUtc: '2026-11-02T03:30:02Z', runsExamined: 1, machinesDue: 1,
                executionsStarted: [{ runId: 'p/m', machines: 1, execution: 'x' }], failures: [] };
  ok(copies.copiesPassText(one).startsWith('Last daily cleanup 1h ago: 1 migration checked, 1 machine due, 1 cleanup started.'), copies.copiesPassText(one));
  const many = Object.assign({}, one, { runsExamined: 3, machinesDue: 0, executionsStarted: [] });
  ok(copies.copiesPassText(many).startsWith('Last daily cleanup 1h ago: 3 migrations checked, 0 machines due, 0 cleanups started.'), copies.copiesPassText(many));
  const open = { schemaVersion: 2, cycleStartedUtc: '2026-11-02T03:30:01Z', lastPassUtc: '2026-11-02T09:30:02Z', runsInStore: 1, runsExamined: 0,
                 machinesDue: 1, executionsStarted: [], failures: [], resumeAtRunId: 'p/m', resumeStops: 0, nextPassUtc: '2026-11-02T10:30:00Z' };
  ok(copies.copiesPassText(open).includes('is not complete: 0 of 1 migration checked, 1 machine due, 0 cleanups started.'), copies.copiesPassText(open));
});

test('a row of the box: the readable name with the run id under it, the counts, the date, and Open', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  const created = new Map([['pay/migration-1', '2026-10-03T10:00:00Z']]);
  const x = copies.copiesRow({ id: 'pay/migration-1', summary: { copies: 3, due: 1, earliestDueUtc: '2026-11-09T10:00:00Z' } }, created);
  eq([x.id, x.projectId, x.project], ['pay/migration-1', 'pay', 'Payments']);
  ok(/^Payments · migration of /.test(x.name), x.name);
  eq(VmfHelp.listHref(x.dest), 'migrations.html?run=migration-1&project=pay', 'the name opens the migration\'s page, as Open does');
  eq([x.kept, x.due, x.earliest], [3, { text: '1', tone: 'warn' }, 'AT(2026-11-09T10:00:00Z)']);
  eq(x.actions, [{ text: 'Open', dest: { page: 'migrations', run: 'pay/migration-1' } }]);
  eq(copies.copiesRow({ id: 'gone-run', summary: { copies: 1, due: 0, earliestDueUtc: null } }, created).due, 0, 'nothing due is 0');
  eq(copies.copiesRow({ id: 'gone-run', summary: { copies: 1, due: 0, earliestDueUtc: null } }, created).name, 'Outside a project · migration',
    'a run the page could not read has no date to name it by');
  globalThis.projects = [];
});

test('the box\'s columns are the ones it had', () => {
  eq(copies.copiesColumns().map(c => c.head), ['Migration', 'Copies kept', 'Due next cleanup', 'Earliest deletion', '']);
  eq(copies.copiesColumns().map(c => c.kind), ['name', 'num', 'num', 'text', 'actions']);
});

/* A host for the box: enough for listMount, keeping what each part holds. */
function boxHost() {
  const parts = {};
  const el = () => ({ focus() {} });
  return {
    parts,
    set innerHTML(v) { this._html = v; },
    get innerHTML() { return this._html; },
    set className(v) { this._class = v; },
    querySelector(sel) {
      const m = sel.match(/^\[data-part="(\w+)"\]$/);
      if (m) { return (parts[m[1]] = parts[m[1]] || { innerHTML: '', textContent: '', querySelector: el }); }
      return el();
    },
    addEventListener() {},
    contains() { return false; },
  };
}
const perOf = (n) => Array.from({ length: n }, (_, i) => ({ id: `pay/migration-${i}`, summary: { machines: 1, copies: 2, due: i % 2, unlocked: 1, earliestDueUtc: null } }));

test('the box is the shared list: no tiles, pages of 10, Search, and its lines above the table', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  globalThis.rows = [];
  const host = boxHost();
  copies.drawCopies(host, perOf(12).concat([{ id: 'none', summary: { machines: 0, copies: 0, due: 0, unlocked: 0 } }]), null);
  ok(/data-part="tiles"[^>]*hidden/.test(host.innerHTML), 'no tiles');
  eq(host.parts.title.textContent, 'Safety copies', 'its heading');
  ok(host.parts.pager.innerHTML.includes('1 to 10 of 12'), 'pages of 10, a migration with no copies is no row: ' + host.parts.pager.innerHTML);
  ok(host.parts.controls.innerHTML.includes('placeholder="Migration or project"'), 'a Search');
  ok(host.parts.controls.innerHTML.includes('data-list="project"'), 'and a Project choice, for its own rows');
  const lead = host.parts.lead.innerHTML;
  ok(lead.includes(UX.copiesHint), 'the hint');
  ok(lead.includes('24 safety copies kept for 12 machines across 12 migrations.'), lead);
  ok(lead.includes('12 of them carry no lock'), 'the lock warning');
  ok(lead.includes(UX.copiesPassNone.split('.')[0]), 'the cleanup line');
  ok(host.parts.table.innerHTML.includes('Payments · migration'), 'the readable name');
  globalThis.projects = [];
});

test('no copies: the box says so once, and the list says the same as its empty sentence', () => {
  const host = boxHost();
  copies.drawCopies(host, [], null);
  ok(!host.parts.lead.innerHTML.includes(UX.copiesNone), 'the line is not said twice');
  ok(host.parts.table.innerHTML.includes(UX.copiesNone), 'the list says it');
});

test('the box reads with ONE limit, so the walk never floods the service (PERF-ONE-LIMIT-1)', () => {
  const fn = extract('reports.html', 'copiesFacts');
  ok(/VmfHelp\.readLimiter\(\)/.test(fn), 'one limiter for the card');
  ok(/limited\(\(\) => blobList\(/.test(fn) && /limited\(\(\) => blobFetch\(/.test(fn), 'every read of the card takes a slot');
});

test('a run whose manifest, status or plan could not be read still has its safety copies counted', async () => {
  const { loadSummaries, copiesRunIds } = liftAll('reports.html', ['loadSummaries', 'copiesRunIds']);
  globalThis.STORE_READ_LIMIT = 8;
  Object.assign(globalThis, { DEMO_MODE: true, rows: [], storeRuns: [], assessmentIds: new Set(), byNewest: () => 0, renderTable() {},
    heldSummary: () => undefined, projects: [] });
  globalThis.source = {
    listRuns: async () => ['p/ok', 'p/broken', 'p/assess'],
    listProjects: async () => [],
    readJson: async (r, rel) => {
      if (r === 'p/broken') { throw new Error('read refused'); }
      if (rel === 'run.json') { return { kind: r === 'p/assess' ? 'assessment' : 'migration' }; }
      return rel === 'plan.json' ? { entries: [{ vmId: 'a', wave: 'w', path: 'A' }] } : {};
    },
    summary: async () => ({ outcomes: {} }), exists: async () => false,
  };
  await loadSummaries();
  eq(globalThis.rows.map(x => x.r), ['p/ok'], 'the list shows what it could read');
  eq(copiesRunIds(), ['p/ok', 'p/broken'], 'the box walks every run that is not an assessment, as the Overview did');
});

/* ---- the detail's way back, after the list drew again (review) --------- */

test('Close puts the keyboard on the name in the list as it is NOW, after the list drew it again', () => {
  const fresh = { focused: 0, focus() { this.focused++; } };
  const card = { hidden: false };
  const els = { 'run-detail': card, 'detail-body': { innerHTML: 'x' }, 'page-title': { focused: 0, focus() { this.focused++; } } };
  globalThis.$ = (s) => els[s.replace(/^#/, '')];
  const other = { dataset: { value: 'p/b' }, focus() { throw new Error('another name'); } };
  fresh.dataset = { value: 'p/a' };
  globalThis.document = { querySelectorAll: (s) => (s === '#reports-list a[data-action="detail"]' ? [other, fresh] : []) };
  globalThis.location = { search: '' };
  const { closeDetail } = liftAll('reports.html', ['closeDetail']);
  try {
    globalThis.detailOpener = { isConnected: false, focus() { throw new Error('a link the list threw away'); } };
    globalThis.detailRun = 'p/a';
    closeDetail();
    eq(fresh.focused, 1, 'the name the list drew again');
    card.hidden = false;
    globalThis.detailOpener = null; globalThis.detailRun = 'p/elsewhere';
    closeDetail();
    eq(els['page-title'].focused, 1, 'opened by ?run= with its name on no page shown: the page heading');
  } finally { delete globalThis.document; }
});

test('the page heading can take the keyboard', () => {
  ok(/<h1 id="page-title" tabindex="-1"><\/h1>/.test(PAGE), 'tabindex -1, so focus() works and Tab does not stop on it');
});

run('page-scale-reports');
