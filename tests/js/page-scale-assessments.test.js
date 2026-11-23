/* PAGE-SCALE-ASSESSMENTS-1, 2026-11-07. The Assessments page: four count
 * tiles and one list with a project choice, a search and pages of 10, in
 * place of one table with a row for every assessment.
 *
 * WHAT WAS WRONG. The page drew every assessment in one table, by its raw run
 * id, with no search and no pages, so with many assessments the one that
 * waits for a review was hard to find. The shape was approved on
 * 2026-11-07 (the Overview and Projects have it already).
 *
 * WHAT IS TESTED. The page's own functions, run: which assessments each tile
 * holds, what each column says, the action each row offers (the product's
 * own: Review and Plan a migration open the wizard, Open the newest
 * migration), Delete with its reason on the row, the report that the name
 * opens beside the list (Close, Escape, and the keyboard back on the name),
 * the project filter from ?project=, and that the projects come from the one
 * call the page already makes. The shared piece itself is
 * page-scale-list.test.js.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));
const PAGE = pageSource(path.join(DASH, 'assessments.html'));

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
  'listMount', 'agoText', 'runTitle', 'mapLimited', 'runFolderIsRun', 'runKind']);
const VmfRun = { parse: shared.runParse, storePath: shared.runStorePath, link: shared.runLink, fromQuery: shared.runFromQuery };
globalThis.VmfHelp = Object.assign({}, shared, { VmfRun, LIST_LOOSE: globalThis.LIST_LOOSE });

// The shared report's own count rule, with the engine's reasons file.
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} },
  fetch: async () => ({ ok: true, json: async () => reasons }), console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(DASH, 'assessment-report.js')), ctx);
Object.assign(ctx.window.VmfReport.REASONS.blockers, reasons.blockers);
globalThis.migrateCounts = ctx.window.VmfReport.migrateCounts;

globalThis.UX = liftConst('assessments.html', 'UX');
globalThis.reading = false;
globalThis.DEMO_MODE = false;
globalThis.STORE_READ_LIMIT = 8;
globalThis.projects = [];
const page = liftAll('assessments.html', ['assessmentStatus', 'lastChange', 'deleteAction', 'nextAction', 'assessmentRow',
  'assessmentTiles', 'assessmentColumns', 'projectChoices', 'reportTitle', 'plannedHtml']);
Object.assign(globalThis, page);
// eslint-disable-next-line no-eval
globalThis.STATUS_TAGS = eval('(' + (PAGE.match(/\nconst STATUS_TAGS = (\{[\s\S]*?\n\});/) || [])[1] + ')');

const NOW = Date.parse('2026-11-07T12:00:00Z');
const daysAgo = (d) => new Date(NOW - d * 86400000).toISOString();
const ready = (n) => Array.from({ length: n }, (_, i) => ({ name: 'r' + i, vmId: '/vm/r' + i, classification: 'ReadyAfterPrep', blockers: [] }));
const blocked = (n) => Array.from({ length: n }, (_, i) => ({ name: 'b' + i, vmId: '/vm/b' + i, classification: 'Blocked', blockers: ['confidential-vm-requires-manual'] }));
// A row as loadAssessments makes it.
const a = (id, extra) => Object.assign({ id, projectId: VmfRun.parse(id).project || null, when: daysAgo(10), scope: null,
  machines: 0, planned: [], plannedUtc: null, approval: null, vms: [], notRead: [] }, extra || {});
const accepted = (d) => ({ approvedBy: { identity: 'sam@contoso.com' }, approvedUtc: daysAgo(d), note: null });
const tileOf = (tiles, key) => tiles.find(t => t.key === key);

/* ---- the approved design ---------------------------------------------- */

test('four tiles, in the approved words, each holding its assessments; To review is the default', () => {
  const list = [a('p/new'), a('p/ok', { approval: accepted(5) }),
                a('p/done', { approval: accepted(8), planned: ['p/done-m'], plannedUtc: daysAgo(7) })];
  const tiles = page.assessmentTiles(list);
  eq(tiles.map(t => t.key), ['review', 'accepted', 'planned', 'all']);
  eq(tiles.map(t => t.label), ['To review', 'Accepted, no migration yet', 'Planned', 'All assessments']);
  eq(tiles.map(t => t.title), ['Assessments to review', 'Accepted assessments with no migration', 'Assessments with a migration', 'All assessments']);
  eq(tileOf(tiles, 'review').rows.map(r => r.id), ['p/new']);
  eq(tileOf(tiles, 'accepted').rows.map(r => r.id), ['p/ok']);
  eq(tileOf(tiles, 'planned').rows.map(r => r.id), ['p/done']);
  eq(tileOf(tiles, 'all').rows.map(r => r.id), ['p/new', 'p/ok', 'p/done'], 'every assessment, nothing hidden');
  ok(tiles.every(t => t.empty), 'each tile says something when it holds no assessment');
});

test('a planned assessment is counted once, as Planned, even with no acceptance on record', () => {
  const t = page.assessmentTiles([a('p/x', { planned: ['p/m'] })]);
  eq([tileOf(t, 'review').rows.length, tileOf(t, 'accepted').rows.length, tileOf(t, 'planned').rows.length], [0, 0, 1]);
});

test('the columns, in the approved order and words', () => {
  const cols = page.assessmentColumns();
  eq(cols.map(c => c.head), ['Assessment', 'Project', 'Machines found', 'Can migrate', 'Status', 'Last change', 'Action']);
  eq(cols.map(c => c.kind), ['name', 'text', 'num', 'num', 'tag', 'ago', 'actions']);
  eq(UX.searchHint, 'Assessment or project');
  eq(UX.lede, 'A migration is planned from an accepted assessment.');
});

test('a row: the readable name, the project by name, the counts, and the run id kept for the search', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  const names = new Map([['pay', 'Payments']]);
  const r = page.assessmentRow(a('pay/assessment-1', { when: '2026-10-03T10:00:00Z', machines: 5, vms: ready(3).concat(blocked(2)) }), names);
  eq([r.id, r.projectId, r.project], ['pay/assessment-1', 'pay', 'Payments']);
  ok(/^Payments · assessment of /.test(r.name), r.name);
  eq([r.found, r.can], [5, 3], 'Can migrate is the shared rule\'s count (ASSESS-COUNT-1)');
  eq(VmfHelp.listHref(r.dest), 'assessments.html?run=assessment-1&project=pay', 'the name has an address of its own');
  eq(r.open, { action: 'report', value: 'pay/assessment-1' }, 'and opens the report on this page');
  const loose = page.assessmentRow(a('old-scan'), names);
  eq([loose.projectId, loose.project], [null, 'Outside a project'], 'the Overview\'s words for a run from before projects');
  const unnamed = page.assessmentRow(a('gone/x'), names);
  eq(unnamed.project, 'gone', 'a project with no name read is named by its id');
});

test('Status: To review (amber), Accepted, Planned (green)', () => {
  const names = new Map();
  eq(page.assessmentRow(a('p/1'), names).status, { text: 'To review', tone: 'warn' });
  eq(page.assessmentRow(a('p/2', { approval: accepted(1) }), names).status, { text: 'Accepted', tone: '' });
  eq(page.assessmentRow(a('p/3', { approval: accepted(1), planned: ['p/m'] }), names).status, { text: 'Planned', tone: 'good' });
});

test('the action of each status is the product\'s own: Review and Plan a migration open the wizard, Open the newest migration', () => {
  const names = new Map();
  const act = (row) => page.assessmentRow(row, names).actions[0];
  const review = act(a('p/1'));
  eq([review.text, VmfHelp.listHref(review.dest)], ['Review', 'wizard.html?run=1&project=p']);
  const plan = act(a('p/2', { approval: accepted(1) }));
  eq([plan.text, VmfHelp.listHref(plan.dest)], ['Plan a migration', 'wizard.html?run=2&project=p']);
  const open = act(a('p/3', { approval: accepted(1), planned: ['p/m-new', 'p/m-old'] }));
  eq([open.text, VmfHelp.listHref(open.dest)], ['Open', 'migrations.html?run=m-new&project=p'], 'the first planned is the newest');
});

test('Last change is the latest of the scan, the acceptance and the newest migration', () => {
  eq(page.lastChange(a('p/1', { when: daysAgo(9) })), daysAgo(9));
  eq(page.lastChange(a('p/1', { when: daysAgo(9), approval: accepted(4) })), daysAgo(4));
  eq(page.lastChange(a('p/1', { when: daysAgo(9), approval: accepted(4), plannedUtc: daysAgo(2) })), daysAgo(2));
  eq(page.lastChange(a('p/1', { when: daysAgo(3), approval: accepted(4), plannedUtc: 'not a time' })), daysAgo(3));
  eq(page.lastChange(a('p/1', { when: null })), null);
});

/* ---- Delete keeps its reason on the row (PROJ-EMPTY-1) ------------------- */

test('an assessment nothing was planned from offers Delete; a planned one shows it disabled, the reason under it', () => {
  eq(page.deleteAction(a('p/1')), { text: 'Delete', action: 'delete', value: 'p/1' });
  const one = page.deleteAction(a('p/2', { planned: ['p/m1'] }));
  eq([one.disabled, one.action, one.value], [true, 'delete', 'p/2']);
  eq(one.note.map(x => x.text).join(''), 'Delete the migration first.');
  eq(one.note.filter(x => x.dest).map(x => VmfHelp.listHref(x.dest)), ['migrations.html?run=m1&project=p'], 'a link to it');
  const two = page.deleteAction(a('p/3', { planned: ['p/m1', 'p/m2'] }));
  eq(two.note.map(x => x.text).join(''), 'Delete the 2 migrations first.');
  eq(two.note.filter(x => x.dest).map(x => VmfHelp.listHref(x.dest)), ['migrations.html?project=p'], 'the project\'s migrations');
  const looseTwo = page.deleteAction(a('old', { planned: ['m1', 'm2'] }));
  eq(looseTwo.note.filter(x => x.dest).map(x => VmfHelp.listHref(x.dest)), ['migrations.html']);
  const html = VmfHelp.listAction(one);
  ok(/disabled/.test(html) && html.includes('class="muted vmf-note"') && !/title="/.test(html), 'drawn under the button, not in a hover: ' + html);
});

test('the row keeps both actions: the next step and Delete', () => {
  eq(page.assessmentRow(a('p/1'), new Map()).actions.map(x => x.text), ['Review', 'Delete']);
});

/* ---- the project choice and the filter from the Projects page ----------- */

test('the project choice: every project by name, then Outside a project when an assessment has none', () => {
  globalThis.projects = [{ id: 'a', name: 'Alpha' }, { id: 'e', name: 'Empty' }];
  eq(page.projectChoices([a('a/1')]), [{ id: 'a', name: 'Alpha' }, { id: 'e', name: 'Empty' }], 'a project with no assessment is a choice too');
  eq(page.projectChoices([a('a/1'), a('old')]).pop(), { id: LIST_LOOSE, name: 'Outside a project' });
});

/* ---- the page draws through the shared list ----------------------------- */

function renderPage(search) {
  const nodes = {};
  const node = (id) => (nodes[id] = nodes[id] || { id, textContent: '', innerHTML: '', style: {}, listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); } });
  const mounts = [];
  const { renderTable, openAskedReport } = liftAll('assessments.html', ['renderTable', 'openAskedReport']);
  const opened = [];
  Object.assign(globalThis, { $: node, assessList: null, reportAsked: false, location: { search: search || '' },
    onListClick: () => {}, openReport: (id) => { opened.push(id); return true; }, openAskedReport });
  globalThis.VmfHelp = Object.assign({}, shared, { VmfRun, LIST_LOOSE: globalThis.LIST_LOOSE,
    listMount: (host, cfg) => { const m = { host, cfg, updates: [] }; mounts.push(m); return { update: (d) => m.updates.push(d) }; },
  });
  return { renderTable, node, mounts, opened };
}

test('render mounts the shared list ONCE, opening on To review, and gives it the rows and projects on every draw', () => {
  const { renderTable, node, mounts } = renderPage('');
  globalThis.projects = [{ id: 'p', name: 'P' }];
  globalThis.rows = [a('p/1'), a('p/2', { approval: accepted(1) })];
  renderTable();
  renderTable();
  eq(mounts.length, 1, 'mounted once');
  eq(mounts[0].host.id, '#assessments-list');
  eq([mounts[0].cfg.preferred, mounts[0].cfg.searchHint, mounts[0].cfg.project], ['review', 'Assessment or project', '']);
  ok(!mounts[0].cfg.sorts && mounts[0].cfg.projectFilter !== false, 'a project choice and no Sort, as the design shows');
  eq(mounts[0].updates.length, 2, 'every draw');
  eq(tileOf(mounts[0].updates[1].tiles, 'all').rows.length, 2);
  eq(mounts[0].updates[1].projects, [{ id: 'p', name: 'P' }]);
  eq((node('#assessments-list').listeners.click || []).length, 1, 'one click listener for the row controls');
});

test('?project= from the Projects page is the project filter the list starts with, on All assessments', () => {
  const { renderTable, mounts } = renderPage('?project=pay');
  globalThis.rows = [];
  renderTable();
  eq([mounts[0].cfg.project, mounts[0].cfg.preferred], ['pay', 'all'], 'that project\'s assessments, not a tile it may have no row in');
});

test('WAIT-1, LOADING-LINE-1: the list is given the Reading sentence and told while the page reads; after, All assessments says there is none', () => {
  // The shared list shows the sentence on every tile while it reads - To
  // review too, which the page opens on (loading-line.test.js).
  const { renderTable, mounts } = renderPage('');
  globalThis.rows = [];
  globalThis.reading = true;
  renderTable();
  eq(mounts[0].cfg.waiting, UX.waiting, 'the sentence');
  eq(mounts[0].updates[0].reading, true, 'reading');
  globalThis.reading = false;
globalThis.DEMO_MODE = false;
  renderTable();
  eq(mounts[0].updates[1].reading, false, 'the read ended');
  eq(tileOf(mounts[0].updates[1].tiles, 'all').empty, UX.none);
});

test('?run= opens that report once, after the store is read', () => {
  const { renderTable, opened } = renderPage('?run=a1&project=pay');
  globalThis.rows = [a('pay/a1')];
  globalThis.reading = true;
  renderTable();
  eq(opened, [], 'not while the store is read');
  globalThis.reading = false;
globalThis.DEMO_MODE = false;
  renderTable();
  renderTable();
  eq(opened, ['pay/a1'], 'once');
  const none = renderPage('');
  globalThis.reading = false;
globalThis.DEMO_MODE = false;
  none.renderTable();
  eq(none.opened, [], 'no ?run=, no report');
});

/* ---- the controls of a row ---------------------------------------------- */

function clickTarget(map) {
  return { closest: (sel) => map[sel] || null };
}
test('a click on an enabled Delete asks; a disabled one does nothing', () => {
  const { onListClick } = liftAll('assessments.html', ['onListClick']);
  const asked = [];
  globalThis.discardAssessment = (id, btn) => asked.push([id, btn.tag]);
  onListClick({ target: clickTarget({ 'button[data-action="delete"]': { tag: 'b1', disabled: false, dataset: { value: 'p/1' } } }) });
  onListClick({ target: clickTarget({ 'button[data-action="delete"]': { tag: 'b2', disabled: true, dataset: { value: 'p/2' } } }) });
  eq(asked, [['p/1', 'b1']]);
});

test('a click on a name opens its report in place; a click for a new tab or window keeps the address', () => {
  const { onListClick } = liftAll('assessments.html', ['onListClick']);
  const opened = [];
  globalThis.openReport = (id) => { opened.push(id); return true; };
  const link = { dataset: { value: 'p/1' } };
  let prevented = 0;
  const ev = (extra) => Object.assign({ target: clickTarget({ 'a[data-action="report"]': link }), button: 0, preventDefault() { prevented++; } }, extra || {});
  onListClick(ev());
  eq([opened, prevented], [['p/1'], 1], 'opened, and the page did not go to the address');
  for (const extra of [{ ctrlKey: true }, { metaKey: true }, { shiftKey: true }, { altKey: true }, { button: 1 }]) {
    onListClick(ev(extra));
  }
  eq([opened.length, prevented], [1, 1], 'a new tab or window: the address opens the report there');
  globalThis.openReport = () => false;
  onListClick(ev());
  eq(prevented, 1, 'an assessment the page does not hold: the address does the work');
});

/* ---- the report beside the list: rule 11 ------------------------------- */

function panelWorld() {
  const focused = [];
  const close = { dataset: {}, listeners: {}, addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); },
    focus() { focused.push('close'); } };
  const panel = { querySelector: (sel) => (sel === '.close' ? close : null) };
  const calls = [];
  const names = [{ dataset: { value: 'p/1' }, focus() { focused.push('name p/1'); } }, { dataset: { value: 'p/2' }, focus() { focused.push('name p/2'); } }];
  const host = { querySelectorAll: (sel) => (sel === 'a[data-action="report"]' ? names : []) };
  globalThis.window = { VmfReport: { openPanel: (html) => { calls.push('open'); return panel; }, closePanel: () => calls.push('close') } };
  globalThis.$ = (sel) => (sel === '#assessments-list' ? host : null);
  globalThis.reportHtml = (row) => 'report of ' + row.id;
  globalThis.rows = [a('p/1'), a('p/2')];
  // ASSESS-APPROVAL-HASH-1: the report of an assessment nobody approved reads
  // its version (assess-approval-hash.test.js runs that read).
  globalThis.loadReportVersion = (id) => calls.push('version ' + id);
  globalThis.openReportId = null;
  globalThis.openReportVersion = '';
  return { focused, close, calls };
}

test('rule 11: the report opens with the keyboard on Close; Close and Escape close it and the keyboard goes back to the name', () => {
  const fns = liftAll('assessments.html', ['openReport', 'reportClosed', 'onReportKey']);
  Object.assign(globalThis, fns);
  const w = panelWorld();
  eq(fns.openReport('p/9'), false, 'an assessment the page does not hold');
  ok(fns.openReport('p/2'));
  eq(globalThis.openReportId, 'p/2');
  eq(w.focused, ['close'], 'the keyboard is on Close');
  eq((w.close.listeners.click || []).length, 1);
  fns.openReport('p/1');
  eq((w.close.listeners.click || []).length, 1, 'one listener, however often it opens');
  w.close.listeners.click[0]();
  eq(w.focused.slice(-1), ['name p/1'], 'Close: back on the name');
  eq(globalThis.openReportId, null);
  fns.openReport('p/2');
  fns.onReportKey({ key: 'Enter' });
  eq(globalThis.openReportId, 'p/2', 'another key does nothing');
  fns.onReportKey({ key: 'Escape' });
  eq([globalThis.openReportId, w.focused.slice(-1)[0], w.calls.slice(-1)[0]], [null, 'name p/2', 'close'], 'Escape: closed, back on the name');
});

test('an acceptance made in the open report draws the report again, so it shows Reviewed, not the button', async () => {
  const { approve } = liftAll('assessments.html', ['approve']);
  const calls = [];
  Object.assign(globalThis, {
    document: { getElementById: () => ({ value: ' note ' }) },
    api: async (method, route, body) => { calls.push(['api', route, body.note, body.assessmentHash]); return {}; },
    loadAssessments: async () => calls.push(['load']), renderTable: () => calls.push(['draw']),
    openReport: (id) => { calls.push(['open', id]); return true; },
  });
  globalThis.VmfHelp = Object.assign({}, shared, { VmfRun: Object.assign({}, VmfRun,
    { routeSegment: (id) => VmfRun.parse(id).run, withProject: (b, id) => Object.assign(b, { project: VmfRun.parse(id).project }) }) });
  globalThis.openReportId = 'p/a1';
  // ASSESS-APPROVAL-HASH-1: the version of the scan the report showed goes with it.
  globalThis.openReportVersion = 'v-scan';
  await approve('p/a1', { textContent: 'I have reviewed this', disabled: false });
  eq(calls, [['api', 'assessments/a1/approve', 'note', 'v-scan'], ['load'], ['draw'], ['open', 'p/a1']]);
  calls.length = 0;
  globalThis.openReportId = null;
  await approve('p/a1', { textContent: 'x', disabled: false });
  eq(calls.map(c => c[0]), ['api', 'load', 'draw'], 'the report was closed meanwhile: it stays closed');
});

test('the report is headed by the row\'s name, says where the scan looked with the ids on hover, and lists its migrations', () => {
  const { reportHtml, scopeLineHtml, scopeText, approveWhy } = liftAll('assessments.html', ['reportHtml', 'scopeLineHtml', 'scopeText', 'approveWhy']);
  globalThis.approveWhy = approveWhy;
  const R = ctx.window.VmfReport;
  Object.assign(globalThis, { scopeLineHtml, scopeText, scopes: null, subName: (id) => 'Prod', mgName: (id) => id,
    ago: () => '', vmName: (id) => id, groupByCode: R.groupByCode, splitBlockers: R.splitBlockers,
    reasonCard: R.reasonCard, chipList: R.chipList, window: { VmfReport: R } });
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  globalThis.VmfHelp = Object.assign({}, shared, { VmfRun, LIST_LOOSE: globalThis.LIST_LOOSE });
  const html = reportHtml(a('pay/a1', { when: '2026-10-03T10:00:00Z', vms: ready(1), planned: ['pay/m1'],
    scope: { subscriptions: ['sub-1'], resourceGroups: [], managementGroup: null } }));
  ok(/^<h3>Payments · assessment of [^<]+<\/h3><div class="mono muted vmf-sub">pay\/a1<\/div>/.test(html), html.slice(0, 200));
  ok(html.includes('id="report-scope"') && html.includes('title="Prod (sub-1)"'), 'the ids on hover: ' + html.slice(0, 400));
  ok(html.includes(esc(UX.plannedFrom)) && html.includes('>Plan another</a>'), 'the migrations planned from it');
});

/* ---- the report keeps what the old row showed ---------------------------- */

test('the report lists the migrations planned from it, each a link, and Plan another opens the wizard', () => {
  globalThis.VmfHelp = Object.assign({}, shared, { VmfRun, LIST_LOOSE: globalThis.LIST_LOOSE });
  const html = page.plannedHtml(a('p/a1', { planned: ['p/m<2>', 'p/m1'] }));
  ok(html.includes(esc(UX.plannedFrom)), html);
  ok(html.includes('href="migrations.html?run=m%3C2%3E&amp;project=p">p/m&lt;2&gt;</a>'), 'linked, escaped: ' + html);
  ok(html.includes('href="wizard.html?run=a1&amp;project=p">Plan another</a>'), html);
  eq(page.plannedHtml(a('p/a2')), '', 'nothing planned: the row\'s own action plans the first');
});

test('the report is headed by the row\'s own name', () => {
  globalThis.projects = [{ id: 'pay', name: 'Payments' }];
  ok(/^Payments · assessment of /.test(page.reportTitle(a('pay/x', { when: '2026-10-03T10:00:00Z' }))));
  ok(/^Outside a project · assessment/.test(page.reportTitle(a('old'))));
});

/* ---- the rows come from the reads the page already makes ---------------- */

test('the one call already reads every project.json the names need: no read for each row', () => {
  // eslint-disable-next-line no-eval
  const list = eval((PAGE.match(/\nconst LIST_READS = (\[[^\]]*\]);/) || [])[1]);
  eq(list.slice().sort(), ['approval.json', 'assessment.json', 'project.json', 'run.json']);
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

test('load: the projects by name - one with no assessment too - and each row with its migrations newest first', async () => {
  const s = fakeStore({
    'pay/project.json': { projectId: 'pay', name: 'Payments' },
    'pay/a1/run.json': { kind: 'assessment', createdUtc: daysAgo(20) },
    'pay/a1/assessment.json': { vms: ready(2) },
    'pay/a1/approval.json': accepted(18),
    'pay/m1/run.json': { kind: 'migration', project: 'pay', createdUtc: daysAgo(15), fromAssessment: 'a1' },
    'pay/m2/run.json': { kind: 'migration', project: 'pay', createdUtc: daysAgo(5), fromAssessment: 'a1' },
    'empty/project.json': { projectId: 'empty', name: 'Empty one' },
    'nameless/project.json': {},
    'nameless/a9/run.json': { kind: 'assessment', createdUtc: daysAgo(2) },
    'old/run.json': { kind: 'assessment', createdUtc: daysAgo(40) },
    'vmf-claims/x.json': {},
  });
  const fns = liftAll('assessments.html', ['loadAssessments', 'listProjects', 'lastChange']);
  Object.assign(globalThis, {
    DEMO_MODE: false, held: null, LIST_READS: [], cfg: { apiUrl: 'x' }, getToken: async () => 't', rows: [], projects: [],
    blobList: (p) => s.list(p), blobFetch: (p) => s.json(p), renderTable: () => {}, lastChange: fns.lastChange,
    listProjects: fns.listProjects,
  });
  globalThis.window = { VmfListRuns: async (list) => {
    const top = (await list('', '/')).prefixes;
    const out = [];
    for (const p of top) {
      if (!shared.runFolderIsRun(p)) { continue; }
      const inside = await list(`${p}/`, '/');
      if (!inside.names.includes(`${p}/project.json`)) { out.push(p); continue; }
      out.push(...inside.prefixes);
    }
    return out.sort();
  } };
  globalThis.source = {
    listRuns: () => window.VmfListRuns(blobList), listProjects: () => fns.listProjects(),
    readJson: (r, rel) => s.json(`${r}/${rel}`),
  };
  globalThis.VmfHelp = Object.assign({}, shared, { VmfRun, storeDocs: async () => { throw new Error('per-file reads here'); } });
  await fns.loadAssessments();
  eq(globalThis.projects, [{ id: 'empty', name: 'Empty one' }, { id: 'nameless', name: 'nameless' }, { id: 'pay', name: 'Payments' }]);
  eq(globalThis.rows.map(r => r.id), ['nameless/a9', 'pay/a1', 'old'], 'the latest change first');
  const a1 = globalThis.rows.find(r => r.id === 'pay/a1');
  eq([a1.projectId, a1.planned, a1.plannedUtc], ['pay', ['pay/m2', 'pay/m1'], daysAgo(5)]);
  eq(globalThis.rows.find(r => r.id === 'old').projectId, null);
  eq(s.reads.filter(r => r.endsWith('project.json')).sort(), ['empty/project.json', 'nameless/project.json', 'pay/project.json'],
    'one read for each project, never one for each row');
});

/* ---- the page itself ---------------------------------------------------- */

test('the page: a heading with its sentence, Clear up old scans and Assess an estate at the top right, then the list', () => {
  const html = fs.readFileSync(path.join(DASH, 'assessments.html'), 'utf8');
  ok(/<div class="pagehead">[\s\S]*<h1 id="list-title"><\/h1>[\s\S]*<p class="lede" id="lede"><\/p>[\s\S]*id="tidy-btn"[\s\S]*id="assess-btn" href="wizard.html"/.test(html), 'the head');
  ok(/<div id="assessments-list"><\/div>/.test(html), 'the list host');
  ok(!/id="runs-table"/.test(html) && !/id="kpis"/.test(html), 'the one long table and its separate counts are gone');
});

test('the old chevron is gone: the name is the one way to the report', () => {
  ok(!/button\.chev|class="chev"/.test(PAGE), 'no chevron');
  ok(/open: \{ action: 'report', value: r\.id \}/.test(PAGE));
});

run('page-scale-assessments');
