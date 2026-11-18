/* PAGE-SCALE-PROJECTS-1, 2026-11-07. The Projects page: three count tiles and
 * one list with a sort, a search and pages of 10, in place of one table with
 * a row for every project.
 *
 * WHAT WAS WRONG. The page drew every project in one table with no search and
 * no pages, so with many projects a person scrolled to find one estate. The
 * Overview was one long scroll with volume too, and the same shape was
 * approved for Projects on 2026-11-07.
 *
 * WHAT IS TESTED. The page's own functions, run: which projects each tile
 * holds, what each column says (the count that waits for a person comes from
 * the migration's summary, by the one rule help.js has), the sorts the page
 * gives, the row actions (Delete keeps its reason on the row), that the page
 * mounts the shared list ONCE and gives it the rows on every draw, and that
 * the counts come from the one call the page already makes. The shared piece
 * itself is page-scale-list.test.js.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const PROJECTS = pageSource(path.join(DASH, 'projects.html'));

// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]); // eslint-disable-line no-eval
globalThis.LIST_PAGE_SIZE = Number((HELP.match(/const LIST_PAGE_SIZE = (\d+);/) || [])[1]);
globalThis.LIST_TONES = eval((HELP.match(/const LIST_TONES = (\[[^\]]*\]);/) || [])[1]); // eslint-disable-line no-eval
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runParse', 'runStorePath', 'runLink',
  'listHref', 'listMatches', 'listView', 'listSort', 'listSortValue', 'listDefaultTile', 'listRangeText', 'listTone', 'listTag',
  'listCell', 'listOpenAttrs', 'listCellClass', 'listAction', 'listNotePart', 'listTilesHtml', 'listTableHtml', 'listPagerHtml', 'listControlsHtml',
  'listMount', 'agoText', 'mapLimited', 'runFolderIsRun', 'runKind', 'storeHolds']);
globalThis.VmfHelp = Object.assign({}, shared);

globalThis.UX = liftConst('projects.html', 'UX');
const QUIET_DAYS = Number((PROJECTS.match(/\nconst QUIET_DAYS = (\d+);/) || [])[1]);
globalThis.QUIET_DAYS = QUIET_DAYS;
globalThis.reading = false;
globalThis.STORE_READ_LIMIT = 8;
const page = liftAll('projects.html', ['migrationWaiting', 'latestTime', 'projectRow', 'projectTiles', 'projectColumns',
  'projectSorts', 'holdsParts', 'holdsNote', 'holdsHtml', 'deleteAction', 'waitingTag']);
Object.assign(globalThis, page);

const NOW = Date.parse('2026-11-07T12:00:00Z');
const daysAgo = (d) => new Date(NOW - d * 86400000).toISOString();
const proj = (id, extra) => Object.assign({ id, name: id.toUpperCase(), created: daysAgo(100), note: null,
  assessments: 0, migrations: 0, waiting: 0, waitingUnknown: false, changed: daysAgo(1) }, extra || {});
const tileOf = (tiles, key) => tiles.find(t => t.key === key);

/* ---- the approved design ---------------------------------------------- */

test('three tiles, in the approved words, each holding its projects; All projects is the default', () => {
  const list = [proj('a'), proj('b', { waiting: 2, migrations: 1 }), proj('c', { changed: daysAgo(45) })];
  const tiles = page.projectTiles(list, NOW);
  eq(tiles.map(t => t.key), ['all', 'waiting', 'quiet']);
  eq(tiles.map(t => t.label), ['All projects', 'With a machine waiting for a person', 'No change in 30 days']);
  eq(tiles.map(t => t.title), ['All projects', 'Projects with a machine waiting for a person', 'Projects with no change in 30 days']);
  eq(tileOf(tiles, 'all').rows.map(r => r.id), ['a', 'b', 'c'], 'every project');
  eq(tileOf(tiles, 'waiting').rows.map(r => r.id), ['b'], 'the one with a machine waiting');
  eq(tileOf(tiles, 'quiet').rows.map(r => r.id), ['c'], 'the one with no change in 30 days');
  ok(tiles.every(t => t.empty), 'each tile says something when it holds no project');
  ok(/preferred: 'all'/.test(PROJECTS), 'the list opens on All projects: nothing is hidden by default');
});

test('a project whose count is NOT KNOWN is in the waiting tile, and says Not known', () => {
  const tiles = page.projectTiles([proj('a', { waitingUnknown: true, migrations: 1 })], NOW);
  eq(tileOf(tiles, 'waiting').rows.map(r => r.id), ['a'], 'unknown is not a no');
  eq(tileOf(tiles, 'waiting').rows[0].waiting, { text: UX.waitUnknown, tone: 'muted' });
});

test('No change in 30 days: 30 days and an hour is in, an hour less is not, and a project with no date is not', () => {
  const list = [proj('old', { changed: daysAgo(31) }), proj('new', { changed: daysAgo(29) }),
                proj('none', { changed: null, created: null }),
                proj('just-over', { changed: daysAgo(30 + 1 / 24) }), proj('just-under', { changed: daysAgo(30 - 1 / 24) })];
  eq(tileOf(page.projectTiles(list, NOW), 'quiet').rows.map(r => r.id), ['old', 'just-over'], '30 days to the hour');
  eq(QUIET_DAYS, 30);
});

test('the columns, in the approved order and words', () => {
  const cols = page.projectColumns();
  eq(cols.map(c => c.head), ['Project', 'Assessments', 'Migrations', 'Waiting for a person', 'Last change', 'Action']);
  eq(cols.map(c => c.kind), ['name', 'count', 'count', 'tag', 'ago', 'actions']);
});

test('the sorts, in the approved words: Last change (the default, newest first), Name, Waiting for a person', () => {
  const s = page.projectSorts();
  eq(s.map(x => x.label), ['Last change', 'Name', 'Waiting for a person']);
  eq(s.map(x => [x.field, x.type, x.order]), [['changed', 'time', 'desc'], ['name', 'text', 'asc'], ['waitingRank', 'number', 'desc']]);
  eq(UX.searchHint, 'Project name');
});

test('a row: the name links to the project\'s assessments, the counts link to their lists', () => {
  const r = page.projectRow(proj('pay', { name: 'Payments', note: 'Leaving the DC', assessments: 2, migrations: 0 }));
  eq([r.id, r.name, r.note], ['pay', 'Payments', 'Leaving the DC']);
  eq(VmfHelp.listHref(r.dest), 'assessments.html?project=pay');
  eq(VmfHelp.listHref(r.assessments.dest), 'assessments.html?project=pay');
  eq(r.assessments.n, 2);
  eq(VmfHelp.listHref(r.migrations.dest), 'migrations.html?project=pay');
  eq(r.migrations.n, 0);
  eq(r.actions[0].text, 'New assessment');
  eq(VmfHelp.listHref(r.actions[0].dest), 'wizard.html?project=pay', 'New assessment starts the wizard in the project');
});

test('Waiting for a person: a red count of machines, or None', () => {
  eq(page.projectRow(proj('a', { waiting: 2 })).waiting, { text: '2 machines', tone: 'bad' });
  eq(page.projectRow(proj('a', { waiting: 1 })).waiting, { text: '1 machine', tone: 'bad' });
  eq(page.projectRow(proj('a', { waiting: 0 })).waiting, { text: 'None', tone: 'muted' });
});

test('the waiting sort puts the most first, and a project NOT KNOWN above one with none', () => {
  const rows = [proj('none'), proj('two', { waiting: 2 }), proj('unknown', { waitingUnknown: true }), proj('one', { waiting: 1 })]
    .map(page.projectRow);
  const spec = page.projectSorts().find(s => s.key === 'waiting');
  eq(VmfHelp.listSort(rows, spec).map(r => r.id), ['two', 'one', 'unknown', 'none']);
});

test('Last change is the latest of the project and its runs; a project made here has its creation', () => {
  eq(page.projectRow(proj('a', { changed: daysAgo(3) })).changed, daysAgo(3));
  eq(page.projectRow(proj('a', { changed: null, created: daysAgo(9) })).changed, daysAgo(9), 'no run: when it was made');
  eq(page.latestTime(daysAgo(5), daysAgo(2)), daysAgo(2));
  eq(page.latestTime(null, daysAgo(2)), daysAgo(2));
  eq(page.latestTime(daysAgo(2), 'not a date'), daysAgo(2));
  eq(page.latestTime(null, undefined), null);
});

/* ---- the count that waits for a person: the summary's, by the one rule ---- */

const v6 = (n, extra) => Object.assign({ schemaVersion: 7, updatedUtc: daysAgo(1), stateCounts: {},
  summary: { machines: 4, waitsOnPerson: n, stateCounts: { MIGRATED: 4 }, next: { wave: null, waitsFor: 'none' } } }, extra || {});

test('a migration\'s machines that wait for a person come from summary.waitsOnPerson (VmfHelp.runWaitingCount)', () => {
  eq(page.migrationWaiting(v6(3)), 3);
  eq(page.migrationWaiting(v6(0)), 0);
  ok(/VmfHelp\.runWaitingCount\(/.test(page.migrationWaiting.toString()), 'the shared rule, not a copy');
});

test('a migration at setup has no status, and no machine waits', () => {
  eq(page.migrationWaiting(null), 0);
});

test('a status with no summary it can read is NOT KNOWN, whatever its stop states say (the Overview\'s rule)', () => {
  // OLD-VERSION-READERS-REMOVE-6: the engine writes the summary in every
  // status document, so the live counts of one wave are never read for it.
  eq(page.migrationWaiting({ schemaVersion: 7, stateCounts: { MIGRATED: 3 } }), null, 'no stop is not a 0');
  eq(page.migrationWaiting({ schemaVersion: 7, stateCounts: { NEEDS_DECISION: 1 } }), null, 'a stop in one wave is not the migration\'s count');
  ok(!/runProblemCount|stateCounts/.test(page.migrationWaiting.toString()), 'the live counts are not read');
});

/* ---- the rows come from the reads the page already makes ---------------- */

test('the one call already reads every run-status.json the counts need: no read for each row', () => {
  const reads = (PROJECTS.match(/\nconst LIST_READS = (\[[^\]]*\]);/) || [])[1];
  ok(reads, 'LIST_READS is found');
  // eslint-disable-next-line no-eval
  const list = eval(reads);
  ok(list.includes('run-status.json') && list.includes('run.json') && list.includes('project.json'), String(list));
});

function fakeStore(docs) {
  const names = Object.keys(docs);
  const folders = (prefix) => [...new Set(names.filter(n => n.startsWith(prefix)).map(n => n.slice(prefix.length))
    .filter(n => n.includes('/')).map(n => prefix + n.split('/')[0]))];
  return {
    reads: [],
    list: async (prefix) => ({ names: names.filter(n => n.startsWith(prefix) && !n.slice(prefix.length).includes('/')), prefixes: folders(prefix) }),
    json: async function (p) { this.reads.push(p); return p in docs ? JSON.parse(JSON.stringify(docs[p])) : null; },
  };
}

test('load: each project carries its counts, its machines that wait, and its last change', async () => {
  const s = fakeStore({
    'pay/project.json': { projectId: 'pay', name: 'Payments', createdUtc: daysAgo(90), note: 'n' },
    'pay/a1/run.json': { kind: 'assessment', createdUtc: daysAgo(80) },
    'pay/m1/run.json': { kind: 'migration', createdUtc: daysAgo(70) },
    'pay/m1/run-status.json': v6(2, { updatedUtc: daysAgo(4) }),
    'pay/m2/run.json': { kind: 'migration', createdUtc: daysAgo(60) },
    'pay/m2/run-status.json': v6(1, { updatedUtc: daysAgo(6) }),
    'pay/m3/run.json': { kind: 'migration', createdUtc: daysAgo(50) },
    'web/project.json': { projectId: 'web', name: 'Web', createdUtc: daysAgo(40) },
    'web/m9/run.json': { kind: 'migration', createdUtc: daysAgo(39) },
    'web/m9/run-status.json': { schemaVersion: 7, updatedUtc: daysAgo(38), stateCounts: { FAILED_ROLLED_BACK: 1 } },
    'old1/run.json': { kind: 'migration' },
  });
  const { load, withMade } = liftAll('projects.html', ['load', 'withMade']);
  Object.assign(globalThis, {
    DEMO_MODE: false, held: null, LIST_READS: [], storeRead: (fn) => fn(), cfg: { apiUrl: 'x' }, getToken: async () => 't',
    blobList: (p) => s.list(p), blobJson: (p) => s.json(p), withMade, madeHere: new Map(), loadTurn: 0,
    drawListWhenFree: () => {}, byName: (a, b) => String(a.name).localeCompare(String(b.name)), projects: [], loose: [],
  });
  globalThis.VmfHelp = Object.assign({}, shared, { storeDocs: async () => { throw new Error('per-file reads here'); } });
  await load();
  const pay = globalThis.projects.find(p => p.id === 'pay');
  eq([pay.assessments, pay.migrations, pay.waiting, pay.waitingUnknown], [1, 3, 3, false], 'two summaries add up; the migration at setup adds 0');
  eq(pay.changed, daysAgo(4), 'the newest status');
  const web = globalThis.projects.find(p => p.id === 'web');
  eq([web.waiting, web.waitingUnknown], [0, true], 'a status with no summary: not known');
  eq(web.changed, daysAgo(38));
  eq(globalThis.loose, ['old1']);
  eq(s.reads.filter(r => r.endsWith('/run-status.json')).sort(), ['pay/m1/run-status.json', 'pay/m2/run-status.json', 'pay/m3/run-status.json', 'web/m9/run-status.json'],
    'the status of a migration only - an assessment is not asked for one');
});

/* ---- Delete keeps its reason on the row (PROJ-EMPTY-1) ------------------- */

test('an empty project offers Delete; one that holds work shows Delete disabled, with the reason under it', () => {
  eq(page.deleteAction(proj('e')), { text: UX.del, action: 'delete', value: 'e' });
  const held = page.deleteAction(proj('h', { assessments: 2, migrations: 1 }));
  eq([held.text, held.action, held.value, held.disabled], [UX.del, 'delete', 'h', true]);
  const words = held.note.map(p => p.text).join('');
  eq(words, 'Delete 2 assessments and 1 migration first.', 'one line: what is inside, and what to do');
  eq(held.note.filter(p => p.dest).map(p => VmfHelp.listHref(p.dest)), ['assessments.html?project=h', 'migrations.html?project=h'],
    'each part links to the work it names');
  eq(page.deleteAction(proj('one', { migrations: 1 })).note.map(p => p.text).join(''),
    'Delete 1 migration first.', 'one piece of work: the same sentence, in the singular');
});

test('the refusal of the service says the same words as the row, with the same links, escaped', () => {
  globalThis.projects = [proj('h<x>', { name: 'H', assessments: 1, migrations: 2 })];
  const html = page.holdsHtml('h<x>');
  eq(html, 'Delete <a href="assessments.html?project=h%3Cx%3E">1 assessment</a> and ' +
    '<a href="migrations.html?project=h%3Cx%3E">2 migrations</a> first.');
  globalThis.projects = [proj('e')];
  eq(page.holdsHtml('e'), null, 'the page counts nothing inside: it says what the service said');
});

test('a click on an enabled Delete asks; a disabled one does nothing', () => {
  const { onListClick } = liftAll('projects.html', ['onListClick']);
  const asked = [];
  globalThis.deleteProject = (id, btn) => asked.push([id, btn.tag]);
  const target = (btn) => ({ closest: (sel) => (sel === 'button[data-action="delete"]' ? btn : null) });
  onListClick({ target: target({ tag: 'b1', disabled: false, dataset: { value: 'pay' } }) });
  onListClick({ target: target({ tag: 'b2', disabled: true, dataset: { value: 'web' } }) });
  onListClick({ target: target(null) });
  eq(asked, [['pay', 'b1']]);
});

/* ---- the page draws through the shared list ----------------------------- */

function renderPage() {
  const nodes = {};
  const node = (id) => (nodes[id] = nodes[id] || { id, textContent: '', innerHTML: '', style: {}, listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); } });
  const mounts = [];
  const { render } = liftAll('projects.html', ['render']);
  Object.assign(globalThis, { $: node, loose: [], reading: true, projectsList: null, onListClick: () => {} });
  globalThis.VmfHelp = Object.assign({}, shared, {
    listMount: (host, cfg) => { const m = { host, cfg, updates: [] }; mounts.push(m); return { update: (d) => m.updates.push(d) }; },
  });
  return { render, node, mounts };
}

test('render mounts the shared list ONCE, with the sorts, no project choice and All projects first, and gives it the rows on every draw', () => {
  const { render, node, mounts } = renderPage();
  globalThis.projects = [proj('a'), proj('b', { waiting: 1 })];
  render();
  render();
  eq(mounts.length, 1, 'mounted once');
  eq(mounts[0].host.id, '#projects-list');
  eq([mounts[0].cfg.preferred, mounts[0].cfg.projectFilter, mounts[0].cfg.searchHint], ['all', false, 'Project name']);
  eq(mounts[0].cfg.sorts.map(s => s.key), ['changed', 'name', 'waiting']);
  eq(mounts[0].updates.length, 2, 'every draw');
  eq(tileOf(mounts[0].updates[1].tiles, 'all').rows.length, 2);
  eq(node('#list-title').textContent, 'Projects');
  eq(node('#new-btn').textContent, 'New project');
  eq(node('#lede').textContent, UX.lede);
  eq((node('#projects-list').listeners.click || []).length, 1, 'one click listener for the row buttons');
});

test('WAIT-1, LOADING-LINE-1: the list is given the Reading sentence and told while the page reads; after, it says there is no project', () => {
  // The shared list shows the sentence on every tile while it reads
  // (loading-line.test.js); the page gives it the sentence and the state.
  const { render, mounts } = renderPage();
  globalThis.projects = [];
  globalThis.reading = true;
  render();
  eq(mounts[0].cfg.waiting, UX.waiting, 'the sentence');
  eq(mounts[0].updates[0].reading, true, 'reading');
  globalThis.reading = false;
  render();
  eq(mounts[0].updates[1].reading, false, 'the read ended');
  eq(tileOf(mounts[0].updates[1].tiles, 'all').empty, UX.empty);
});

test('the runs outside a project are shown under the list, escaped, and nothing when there are none', () => {
  const { render, node } = renderPage();
  globalThis.projects = [];
  globalThis.loose = ['old-<1>', 'old2'];
  render();
  ok(node('#loose').innerHTML.includes(esc(UX.loose)) && node('#loose').innerHTML.includes('old-&lt;1&gt;'), node('#loose').innerHTML);
  eq(node('#loose').style.display, 'block');
  globalThis.loose = [];
  render();
  eq([node('#loose').innerHTML, node('#loose').style.display], ['', 'none']);
});

test('the page: a heading with its sentence and New project at the top right, then the tiles and the list', () => {
  ok(/<div class="pagehead">[\s\S]*<h1 id="list-title"><\/h1>[\s\S]*<p class="lede" id="lede"><\/p>[\s\S]*<button id="new-btn"/.test(PROJECTS), 'the head');
  ok(/<div id="projects-list"><\/div>/.test(PROJECTS), 'the list host');
  ok(!/id="projects-table"/.test(PROJECTS), 'the one long table is gone');
  ok(PROJECTS.indexOf('id="new-form"') < PROJECTS.indexOf('id="projects-list"'), 'the form opens above the list');
});

test('rule 11: the new project form closes on Escape as on Cancel', () => {
  const { wireForm } = liftAll('projects.html', ['wireForm']);
  const nodes = {};
  const node = (id) => (nodes[id] = nodes[id] || { id, value: '', textContent: '', style: { display: 'none' }, listeners: {},
    focus() { this.focused = true; }, addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); } });
  Object.assign(globalThis, { $: node, createProject: () => {}, slug: (x) => x });
  wireForm();
  node('#new-btn').listeners.click[0]();
  eq(node('#new-form').style.display, 'block', 'open');
  (node('#new-form').listeners.keydown || []).forEach(fn => fn({ key: 'Enter' }));
  eq(node('#new-form').style.display, 'block', 'another key does nothing');
  (node('#new-form').listeners.keydown || []).forEach(fn => fn({ key: 'Escape' }));
  eq(node('#new-form').style.display, 'none', 'Escape closes it');
  ok(node('#new-btn').focused, 'and the focus goes back to New project');
});

run('page-scale-projects');
