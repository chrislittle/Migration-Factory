/* PAGE-SCALE-OVERVIEW-1, 2026-11-07. The count tiles and the one list, said
 * ONCE in help.js.
 *
 * WHAT WAS WRONG. With a large estate the Overview page was one giant
 * scroll. The Overview drew five tables one after the
 * other, each with a row for every item, no page and no search. Projects,
 * Assessments and Reports have the same shape (PAGE-SCALE-PROJECTS-1,
 * -ASSESSMENTS-1, -REPORTS-1), so the piece that replaces it is shared.
 *
 * WHAT IS TESTED. The shared functions as help.js has them, lifted and run:
 * the filter, the pages of 10, the default tile, the markup of the tiles, the
 * table and the pager (real buttons, labels, escaping), the links, and the
 * mounted list driven by its events on a small DOM that this file owns.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));

// The shared words, as help.js declares them.
// eslint-disable-next-line no-eval
globalThis.TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g,
  c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.LIST_PAGE_SIZE = Number((HELP.match(/const LIST_PAGE_SIZE = (\d+);/) || [])[1]);
globalThis.LIST_LOOSE = (HELP.match(/const LIST_LOOSE = '([^']*)';/) || [])[1];
// eslint-disable-next-line no-eval
globalThis.LIST_TONES = eval((HELP.match(/const LIST_TONES = (\[[^\]]*\]);/) || [])[1]);

const H = liftAll('help.js', ['runParse', 'runStorePath', 'runLink', 'listMatches', 'listView', 'listDefaultTile',
  'listRangeText', 'listHref', 'listTone', 'listTag', 'listCell', 'listOpenAttrs', 'listTilesHtml', 'listTableHtml', 'listPagerHtml',
  'listControlsHtml', 'listTabsHtml', 'listMount', 'agoText', 'runTitle', 'listSortValue', 'listSort', 'listAction', 'listNotePart', 'listCellClass', 'countWords']);

const rows = (n, extra) => Array.from({ length: n }, (_, i) => Object.assign({
  id: `p${i % 3}/migration-${i}`, projectId: `p${i % 3}`, project: `Project ${i % 3}`, name: `Project ${i % 3} · migration ${i}`,
}, extra ? extra(i) : {}));

/* ---- the constants ----------------------------------------------------- */

test('pages of 10, and a project value that no project id can be', () => {
  eq(LIST_PAGE_SIZE, 10);
  ok(LIST_LOOSE && !/^[a-z0-9-]+$/.test(LIST_LOOSE), `${LIST_LOOSE} is not a project id shape`);
});

/* ---- the filter and the pages ------------------------------------------ */

test('pages of 10: "1 to 10 of 23", then 11 to 20, then 21 to 23', () => {
  const all = rows(23);
  const p0 = H.listView(all, { page: 0 });
  eq([p0.from, p0.to, p0.total, p0.pages, p0.rows.length], [1, 10, 23, 3, 10]);
  eq(H.listRangeText(p0), '1 to 10 of 23');
  const p2 = H.listView(all, { page: 2 });
  eq([p2.from, p2.to, p2.rows.length], [21, 23, 3]);
  eq(p2.rows[0].id, all[20].id, 'the 21st row');
});

test('a page past the end is the last page, and before the start is the first', () => {
  const all = rows(12);
  eq(H.listView(all, { page: 9 }).page, 1);
  eq(H.listView(all, { page: -3 }).page, 0);
  eq(H.listView(all, { page: 'x' }).page, 0);
});

test('nothing to show is "0 to 0 of 0", on one page', () => {
  const v = H.listView([], { page: 4 });
  eq([v.from, v.to, v.total, v.pages, v.page], [0, 0, 0, 1, 0]);
  eq(H.listRangeText(v), '0 to 0 of 0');
});

test('the project filter keeps the rows of that project, and "outside a project" keeps those with none', () => {
  const all = rows(9).concat([{ id: 'old-run', projectId: null, project: 'Outside a project', name: 'old' }]);
  eq(H.listView(all, { project: 'p1' }).total, 3);
  ok(H.listView(all, { project: 'p1' }).rows.every(r => r.projectId === 'p1'));
  eq(H.listView(all, { project: LIST_LOOSE }).rows.map(r => r.id), ['old-run']);
  eq(H.listView(all, { project: '' }).total, 10, 'all projects');
});

test('the search matches the name, the run id and the project, in any case', () => {
  const all = rows(9);
  eq(H.listView(all, { query: 'MIGRATION-4' }).rows.map(r => r.id), ['p1/migration-4'], 'the run id');
  eq(H.listView(all, { query: 'project 2' }).total, 3, 'the project');
  eq(H.listView(all, { query: '· migration 7' }).total, 1, 'the name');
  eq(H.listView(all, { query: '   ' }).total, 9, 'spaces are no search');
  eq(H.listView(all, { query: 'p1', project: 'p2' }).total, 0, 'both apply');
});

/* ---- the default tile -------------------------------------------------- */

test('the default tile is the one asked for when it has rows, else the first with rows', () => {
  const t = (key, n) => ({ key, rows: rows(n) });
  eq(H.listDefaultTile([t('a', 0), t('b', 2), t('c', 1)], 'c'), 'c');
  eq(H.listDefaultTile([t('a', 0), t('b', 2), t('c', 1)], 'a'), 'b', 'the asked one is empty');
  eq(H.listDefaultTile([t('a', 0), t('b', 0)], 'b'), 'b', 'nothing has rows: the asked one');
  eq(H.listDefaultTile([t('a', 0), t('b', 0)], 'zz'), 'a', 'and an unknown one: the first');
  eq(H.listDefaultTile([], 'a'), null);
});

/* ---- the markup -------------------------------------------------------- */

test('each tile is a real button that says whether it is selected, with its count, name and hint', () => {
  const html = H.listTilesHtml([{ key: 'a', label: 'Waiting <now>', hint: 'Stopped.', tone: 'bad', rows: rows(3) },
                                { key: 'b', label: 'Running', rows: [] }], 'a');
  eq((html.match(/<button type="button"/g) || []).length, 2, 'two buttons');
  ok(/data-tile="a" aria-pressed="true"/.test(html), 'a is pressed');
  ok(/data-tile="b" aria-pressed="false"/.test(html), 'b is not');
  ok(html.includes('>3</span>') && html.includes('>0</span>'), 'the counts');
  ok(html.includes('Waiting &lt;now&gt;'), 'the name, escaped');
  ok(html.includes('Stopped.'), 'the hint');
  ok(html.includes('t-bad'), 'the tone');
});

test('a tile tone is one of the known tones, else none', () => {
  ok(!H.listTilesHtml([{ key: 'a', label: 'A', tone: '" onclick="x', rows: [] }], 'a').includes('onclick'), 'not written');
  eq(H.listTone('warn'), 'warn');
  eq(H.listTone('nope'), '');
});

test('a link goes only to a page of this app, with the run in its query', () => {
  eq(H.listHref({ page: 'migrations', run: 'proj/mig-1' }), 'migrations.html?run=mig-1&project=proj');
  eq(H.listHref({ page: 'wizard', run: 'a1' }), 'wizard.html?run=a1');
  eq(H.listHref({ page: 'projects' }), 'projects.html');
  eq(H.listHref({ page: 'javascript:alert(1)//', run: 'x' }), '#', 'an unknown page');
  eq(H.listHref(null), '#');
  ok(H.listHref({ page: 'migrations', run: 'p/a"b<c' }).includes('a%22b%3Cc'), 'the run is encoded');
});

test('the table: column heads, numbers on the right, the name with the run id under it', () => {
  const cols = [{ head: 'Migration', kind: 'name' }, { head: 'Project', kind: 'text', key: 'project' },
                { head: 'Stopped at', kind: 'tag', key: 'stopped' }, { head: 'Machines', kind: 'num', key: 'machines' },
                { head: 'Last change', kind: 'ago', key: 'when' }, { head: 'Action', kind: 'link', key: 'action' }];
  const r = { id: 'p/<m>', name: 'P · migration of <today>', project: 'P&Q', dest: { page: 'migrations', run: 'p/m' },
              stopped: { text: 'wave-<1>', tone: 'bad' }, machines: 2, when: null,
              action: { text: 'Review', page: 'wizard', run: 'p/a' } };
  const html = H.listTableHtml(cols, { rows: [r] }, 'none');
  eq((html.match(/<th scope="col"/g) || []).length, 6, 'six heads');
  ok(/<th scope="col" class="num">Machines<\/th>/.test(html), 'the number column is right-aligned');
  ok(html.includes('href="migrations.html?run=m&amp;project=p"'), 'the name links to the migration');
  ok(html.includes('P · migration of &lt;today&gt;'), 'the readable name, escaped');
  ok(/class="mono muted vmf-sub">p\/&lt;m&gt;</.test(html), 'the run id, small and muted, escaped');
  ok(html.includes('P&amp;Q'), 'the project, escaped');
  ok(html.includes('<span class="pill bad">wave-&lt;1&gt;</span>'), 'the tag');
  ok(html.includes('<td class="num">2</td>'), 'the number');
  ok(html.includes('href="wizard.html?run=a&amp;project=p"') && html.includes('>Review</a>'), 'the action');
  ok(!/<(?!\/?(table|thead|tbody|tr|th|td|a|div|span)\b)[a-z]/i.test(html), 'no markup from a value');
});

test('a tag that says "not known" is muted text, not a coloured tag', () => {
  eq(H.listTag({ text: 'Not known', tone: 'muted' }), '<span class="muted">Not known</span>');
  eq(H.listTag({ text: 'x', tone: 'nope' }), '<span class="pill">x</span>', 'an unknown tone is the plain tag');
  eq(H.listCell({ kind: 'num', key: 'm' }, { m: { text: 'Not known', tone: 'muted' } }), '<span class="muted">Not known</span>');
  eq(H.listCell({ kind: 'num', key: 'm' }, { m: null }), '');
});

test('an empty list says so, across every column', () => {
  const html = H.listTableHtml([{ head: 'A', kind: 'text', key: 'a' }, { head: 'B', kind: 'text', key: 'b' }], { rows: [] }, 'No <row>.');
  ok(html.includes('<td colspan="2" class="muted vmf-waiting">No &lt;row&gt;.</td>'), html);
});

test('the pager: the range, and Previous and Next as buttons that cannot go past the ends', () => {
  const first = H.listPagerHtml(H.listView(rows(23), { page: 0 }));
  ok(first.includes('1 to 10 of 23'), 'the range');
  ok(/data-page="prev" disabled/.test(first), 'Previous is off on the first page');
  ok(!/data-page="next" disabled/.test(first), 'Next is on');
  const last = H.listPagerHtml(H.listView(rows(23), { page: 2 }));
  ok(!/data-page="prev" disabled/.test(last) && /data-page="next" disabled/.test(last), 'the last page');
  eq((first.match(/<button type="button"/g) || []).length, 2);
  ok(first.includes(`>${TEXT.listPrevious}<`) && first.includes(`>${TEXT.listNext}<`), 'the words');
  ok(first.includes('aria-live="polite"'), 'a screen reader hears the new range');
});

test('the controls: a labelled project choice and a labelled search box, the choice kept', () => {
  const html = H.listControlsHtml({ id: 'ov', searchHint: 'Migration or project' },
    [{ id: 'p1', name: 'Payments <refresh>' }, { id: 'p2', name: 'Web' }], { project: 'p2', query: 'a"b' });
  ok(/<label[^>]*>Project <select id="ov-project" data-list="project">/.test(html), 'the label holds the choice');
  ok(/<label[^>]*>Search <input type="search" id="ov-search" data-list="search"/.test(html), 'and the search box');
  ok(html.includes(`<option value="">${TEXT.listAllProjects}</option>`), 'All projects first');
  ok(html.includes('<option value="p2" selected>Web</option>'), 'the choice kept');
  ok(html.includes('Payments &lt;refresh&gt;'), 'a name, escaped');
  ok(html.includes('value="a&quot;b"') && html.includes('placeholder="Migration or project"'), 'the search, escaped');
});

/* ---- the readable name and the age ------------------------------------- */

test('a run is named by its project and the day it was made', () => {
  const day = new Date('2026-09-01T10:00:00Z').toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
  eq(H.runTitle('Payments', 'migration', '2026-09-01T10:00:00Z'), `Payments · migration of ${day}`);
  eq(H.runTitle('Payments', 'assessment', '2026-09-01T10:00:00Z'), `Payments · assessment of ${day}`);
  eq(H.runTitle('Payments', 'migration', null), 'Payments · migration', 'no date');
  eq(H.runTitle('Payments', 'assessment', 'not a date'), 'Payments · assessment', 'a date that does not read');
});

// MANUAL-REVIEW-1: in words, not "5m ago" - an abbreviation is not ASD-STE100.
test('the age of a change, in words', () => {
  const now = Date.parse('2026-11-07T12:00:00Z');
  const at = (min) => new Date(now - min * 60000).toISOString();
  eq(H.agoText(null, now), '');
  eq(H.agoText('x', now), '');
  eq(H.agoText(at(0), now), 'just now');
  eq(H.agoText(at(5), now), '5 minutes ago');
  eq(H.agoText(at(150), now), '2 hours ago');
  eq(H.agoText(at(3 * 1440 + 5), now), '3 days ago');
});

/* ---- the mounted list, driven by its events ---------------------------- */

/* A host element enough for listMount: it keeps what is written to each part,
 * gives back an element for a selector, and lets a test fire an event. */
function fakeHost() {
  const parts = {}, handlers = {}, focused = [];
  const el = (sel) => ({ sel, focus() { focused.push(sel); } });
  const host = {
    set innerHTML(v) { this._html = v; for (const k of Object.keys(parts)) delete parts[k]; },
    get innerHTML() { return this._html; },
    querySelector(sel) {
      const m = sel.match(/^\[data-part="(\w+)"\]$/);
      if (m) { return (parts[m[1]] = parts[m[1]] || { innerHTML: '', textContent: '', querySelector: (s) => el(s) }); }
      return el(sel);
    },
    addEventListener(type, fn) { (handlers[type] = handlers[type] || []).push(fn); },
    contains(node) { return !!(node && node.inside); },
  };
  const fire = (type, target) => (handlers[type] || []).forEach(fn => fn({ target }));
  return { host, parts, focused, fire };
}
const clickOn = (attr, value, disabled) => ({
  closest: (sel) => (sel === `[${attr}]` ? { dataset: { [attr === 'data-tile' ? 'tile' : 'page']: value }, disabled: !!disabled } : null),
  matches: () => false,
});
const typeIn = (kind, value) => ({ closest: () => null, matches: (sel) => sel === `[data-list="${kind}"]`, value });

function config() {
  const columns = [{ head: 'Migration', kind: 'name' }, { head: 'Project', kind: 'text', key: 'project' }];
  return { id: 'ov', preferred: 'person', searchHint: 'Migration or project', columns, tilesLabel: 'x' };
}
function data(personRows, runningRows) {
  return {
    tiles: [{ key: 'person', label: 'Waiting for a person', title: 'Waiting for a person', empty: 'No one.', rows: personRows },
            { key: 'running', label: 'Running now', empty: 'Nothing runs.', rows: runningRows,
              columns: [{ head: 'Migration', kind: 'name' }, { head: 'Wave', kind: 'text', key: 'wave' }] }],
    projects: [{ id: 'p0', name: 'Project 0' }, { id: 'p1', name: 'Project 1' }, { id: 'p2', name: 'Project 2' }],
  };
}

test('mounted: the skeleton once, then the default tile, its title, its rows and its pager', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  ok(/data-part="tiles"/.test(f.host.innerHTML) && /role="group"/.test(f.host.innerHTML), 'a labelled group of tiles');
  ok(/aria-labelledby="ov-title"/.test(f.host.innerHTML), 'the list is named by its title');
  list.update(data(rows(12), rows(2)));
  eq(list.state().tile, 'person');
  eq(f.parts.title.textContent, 'Waiting for a person');
  ok(f.parts.tiles.innerHTML.includes('data-tile="person" aria-pressed="true"'));
  ok(f.parts.pager.innerHTML.includes('1 to 10 of 12'));
  ok(f.parts.controls.innerHTML.includes('id="ov-search"'), 'the controls');
});

test('mounted: an empty default tile gives way to the first with rows, until a person picks', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data([], rows(2)));
  eq(list.state().tile, 'running', 'the first with rows');
  list.update(data(rows(1), rows(2)));
  eq(list.state().tile, 'person', 'rows arrived while the page read: the default again');
  f.fire('click', clickOn('data-tile', 'running'));
  list.update(data(rows(3), rows(2)));
  eq(list.state().tile, 'running', 'a tile the person picked stays picked');
});

test('mounted: a tile click shows its rows, its own columns and its empty sentence, from page 1, and keeps focus', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(25), []));
  f.fire('click', clickOn('data-page', 'next'));
  eq(list.state().page, 1);
  f.fire('click', clickOn('data-tile', 'running'));
  eq(list.state().page, 0, 'back to page 1');
  ok(f.parts.table.innerHTML.includes('>Wave</th>'), 'the tile\'s own columns');
  ok(f.parts.table.innerHTML.includes('Nothing runs.'), 'its empty sentence');
  eq(f.parts.title.textContent, 'Running now', 'the label when there is no title');
  eq(f.focused.pop(), '[data-tile="running"]', 'focus stays on the tile');
});

test('mounted: Next and Previous move one page, a disabled one does nothing, and focus stays on the pager', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(25), []));
  f.fire('click', clickOn('data-page', 'prev', true));
  eq(list.state().page, 0, 'disabled');
  f.fire('click', clickOn('data-page', 'next'));
  f.fire('click', clickOn('data-page', 'next'));
  eq(list.state().page, 2);
  ok(f.parts.pager.innerHTML.includes('21 to 25 of 25'));
  eq(f.focused.pop(), '[data-page="prev"]', 'Next is off on the last page, so Previous takes the focus');
  f.fire('click', clickOn('data-page', 'prev'));
  eq(list.state().page, 1);
  eq(f.focused.pop(), '[data-page="prev"]');
});

test('mounted: a search or a project that still fills pages starts again at page 1', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(40), []));
  f.fire('click', clickOn('data-page', 'next'));
  f.fire('input', typeIn('search', 'migration'));
  eq(list.state().page, 0, 'the search: 40 rows still match');
  f.fire('click', clickOn('data-page', 'next'));
  f.fire('change', typeIn('project', 'p0'));
  eq(list.state().page, 0, 'the project: 14 rows still match');
});

test('mounted: the search and the project filter show only what matches, from page 1', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(25), []));
  f.fire('click', clickOn('data-page', 'next'));
  f.fire('input', typeIn('search', 'migration-2'));
  eq(list.state().page, 0);
  ok(f.parts.pager.innerHTML.includes('1 to 6 of 6'), f.parts.pager.innerHTML);
  f.fire('input', typeIn('search', ''));
  f.fire('change', typeIn('project', 'p1'));
  ok(f.parts.pager.innerHTML.includes('1 to 8 of 8'), f.parts.pager.innerHTML);
  f.fire('change', typeIn('project', 'p1'));
  f.fire('input', typeIn('search', 'zzz'));
  ok(f.parts.table.innerHTML.includes(TEXT.listNoMatch), 'a filter that matches nothing says so');
});

test('mounted: an update keeps the controls a person is typing in, unless the projects changed', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(5), []));
  f.parts.controls.innerHTML = 'TYPING';
  list.update(data(rows(6), []));
  eq(f.parts.controls.innerHTML, 'TYPING', 'not drawn again');
  f.fire('change', typeIn('project', 'p2'));
  const more = data(rows(6), []);
  more.projects = [{ id: 'p0', name: 'Project 0' }];
  list.update(more);
  ok(f.parts.controls.innerHTML.includes('Project 0'), 'drawn again for a new set of projects');
  eq(list.state().project, '', 'a project that is gone is no longer the filter');
});

/* ---- the export list --------------------------------------------------- */

/* Review finding 3: a tile counts all its rows, so with a filter set the list
 * can show fewer. The range says that it is filtered, so 12 on the tile and
 * "1 to 3 of 3" never read as a contradiction. */
test('the range says when the project or the search filters the list', () => {
  const v = H.listView(rows(3), {});
  eq(H.listRangeText(v, false), '1 to 3 of 3');
  eq(H.listRangeText(v, true), TEXT.listRangeFiltered.replace('{from}', 1).replace('{to}', 3).replace('{total}', 3));
  ok(/that match the filter$/.test(H.listRangeText(v, true)), H.listRangeText(v, true));
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(25), []));
  ok(f.parts.pager.innerHTML.includes('>1 to 10 of 25<'), 'no filter: the plain range');
  f.fire('input', typeIn('search', 'migration-2'));
  ok(f.parts.pager.innerHTML.includes('1 to 6 of 6 that match the filter'), f.parts.pager.innerHTML);
  f.fire('input', typeIn('search', ''));
  f.fire('change', typeIn('project', 'p1'));
  ok(f.parts.pager.innerHTML.includes('1 to 8 of 8 that match the filter'), 'the project filter too');
  f.fire('change', typeIn('project', ''));
  ok(f.parts.pager.innerHTML.includes('>1 to 10 of 25<'), 'filter cleared: the plain range again');
});

/* Review finding 4: the page draws again as it reads. A tile or pager button
 * with the keyboard focus gets it back after each draw. */
test('mounted: the focus stays on a tile or a pager button while the page draws again', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  try {
    list.update(data(rows(25), rows(2)));
    globalThis.document = { activeElement: { inside: true, dataset: { tile: 'running' } } };
    list.update(data(rows(26), rows(2)));
    eq(f.focused.pop(), '[data-tile="running"]', 'the tile');
    globalThis.document = { activeElement: { inside: true, dataset: { page: 'next' } } };
    list.update(data(rows(27), rows(2)));
    eq(f.focused.pop(), '[data-page="next"]', 'the pager button');
    globalThis.document = { activeElement: { inside: false, dataset: { tile: 'running' } } };
    list.update(data(rows(28), rows(2)));
    eq(f.focused.length, 0, 'focus outside the list is left alone');
    globalThis.document = { activeElement: { inside: true, dataset: {} } };
    list.update(data(rows(29), rows(2)));
    eq(f.focused.length, 0, 'the search box is not drawn again, so it keeps its own focus');
  } finally { delete globalThis.document; }
});

/* ---- PAGE-SCALE-PROJECTS-1: what the Projects page added to the shared piece ----
 *
 * The Projects page needs a sort choice, no project filter (each row IS a
 * project), a count that links to its list, and a row action that can be a
 * button with a reason under it. They are added here, not on that page, so
 * the other pages can use them; the Overview gives none of them and draws as
 * it did (the tests above, unchanged). */

const SORTS = [
  { key: 'changed', label: 'Last change', field: 'changed', type: 'time', order: 'desc' },
  { key: 'name', label: 'Name', field: 'name', type: 'text', order: 'asc' },
  { key: 'waiting', label: 'Waiting for a person', field: 'rank', type: 'number', order: 'desc' },
];
const prow = (name, changed, rank) => ({ id: name.toLowerCase(), name, changed, rank });

test('sort by a time, newest first; a row with no time goes last; a tie goes by name', () => {
  const all = [prow('B', '2026-11-01T00:00:00Z', 0), prow('A', '2026-11-05T00:00:00Z', 0), prow('C', null, 0),
               prow('D', '2026-11-01T00:00:00Z', 0), prow('E', 'not a date', 0)];
  eq(H.listSort(all, SORTS[0]).map(r => r.name), ['A', 'B', 'D', 'C', 'E']);
  eq(all.map(r => r.name), ['B', 'A', 'C', 'D', 'E'], 'the rows given are not reordered');
});

test('sort by a name, A to Z, in any letter case', () => {
  const all = [prow('beta', null, 0), prow('Alpha', null, 0), prow('gamma', null, 0)];
  eq(H.listSort(all, SORTS[1]).map(r => r.name), ['Alpha', 'beta', 'gamma']);
});

test('sort by a number, most first; a tie goes by name; a value that is not a number goes last', () => {
  const all = [prow('C', null, 1), prow('A', null, 3), prow('B', null, 1), prow('Z', null, 0), prow('Y', null, 'x'), prow('X', null, 0.5)];
  eq(H.listSort(all, SORTS[2]).map(r => r.name), ['A', 'B', 'C', 'X', 'Z', 'Y']);
});

test('no sort keeps the order the page gave, which is what the Overview does', () => {
  const all = [prow('B', null, 0), prow('A', null, 0)];
  eq(H.listSort(all, null).map(r => r.name), ['B', 'A']);
  eq(H.listSort(all, {}).map(r => r.name), ['B', 'A'], 'a sort with no field');
  eq(H.listView(all, {}).rows.map(r => r.name), ['B', 'A'], 'the view');
});

test('the view sorts BEFORE it makes the pages, so page 2 holds the 11th row of the sorted list', () => {
  const all = Array.from({ length: 12 }, (_, i) => prow(`N${String(i).padStart(2, '0')}`, null, i));
  const p1 = H.listView(all, { sort: SORTS[2], page: 1 });
  eq(p1.rows.map(r => r.rank), [1, 0], 'the two with the fewest');
  eq(H.listView(all, { sort: SORTS[2], page: 0 }).rows[0].rank, 11, 'the most first');
});

test('the controls: a labelled Sort choice first, the choice kept, and no project choice when the page says so', () => {
  const html = H.listControlsHtml({ id: 'pj', searchHint: 'Project name', sorts: SORTS, projectFilter: false }, [], { sort: 'name', query: '' });
  ok(new RegExp(`<label[^>]*>${TEXT.listSort} <select id="pj-sort" data-list="sort">`).test(html), 'the label holds the choice');
  ok(html.includes('<option value="changed">Last change</option>'), 'Last change');
  ok(html.includes('<option value="name" selected>Name</option>'), 'the choice kept');
  ok(html.includes('<option value="waiting">Waiting for a person</option>'), 'Waiting for a person');
  ok(!html.includes('data-list="project"'), 'no project choice');
  ok(html.includes('placeholder="Project name"'), 'the search box');
  ok(html.indexOf('data-list="sort"') < html.indexOf('data-list="search"'), 'Sort, then Search');
});

test('the controls with no sorts are the Overview\'s: the project choice and the search, and no Sort', () => {
  const html = H.listControlsHtml({ id: 'ov', searchHint: 'x' }, [{ id: 'p', name: 'P' }], { project: '', query: '' });
  ok(!html.includes('data-list="sort"'), 'no Sort');
  ok(html.includes('data-list="project"') && html.includes('data-list="search"'), 'as before');
});

test('a sort label is escaped', () => {
  const html = H.listControlsHtml({ id: 'x', sorts: [{ key: 'a"b', label: '<b>', field: 'name' }], projectFilter: false }, [], { sort: '', query: '' });
  ok(html.includes('value="a&quot;b"') && html.includes('&lt;b&gt;') && !html.includes('<b>'), html);
});

test('a count links to its list when it is more than 0, and 0 is muted text', () => {
  const col = { kind: 'count', key: 'n' };
  eq(H.listCell(col, { n: { n: 3, dest: { page: 'assessments', project: 'pay' } } }), '<a href="assessments.html?project=pay">3</a>');
  eq(H.listCell(col, { n: { n: 0, dest: { page: 'assessments', project: 'pay' } } }), '<span class="muted">0</span>');
  eq(H.listCell(col, { n: null }), '<span class="muted">0</span>');
  eq(H.listCellClass(col), ' class="num"', 'a count is on the right');
});

test('a link with a project carries it in the query, encoded; a run still wins', () => {
  eq(H.listHref({ page: 'wizard', project: 'pay' }), 'wizard.html?project=pay');
  eq(H.listHref({ page: 'migrations', project: 'a&b' }), 'migrations.html?project=a%26b');
  eq(H.listHref({ page: 'assessments', project: 'p' }), 'assessments.html?project=p');
  eq(H.listHref({ page: 'migrations', run: 'proj/m', project: 'other' }), 'migrations.html?run=m&project=proj');
  eq(H.listHref({ page: 'nope', project: 'p' }), '#');
});

test('the actions of a row: a link, a button with its value, a disabled one with its reason under it', () => {
  const col = { kind: 'actions', key: 'act' };
  const html = H.listCell(col, { act: [
    { text: 'New assessment', dest: { page: 'wizard', project: 'pay' } },
    { text: 'Delete', action: 'delete', value: 'p"ay', disabled: true,
      note: [{ text: 'Holds ' }, { text: '1 <migration>', dest: { page: 'migrations', project: 'pay' } }, { text: '.' }] },
  ] });
  ok(html.includes('<a class="btn ghost small" href="wizard.html?project=pay">New assessment</a>'), 'the link');
  ok(html.includes('<button type="button" class="btn ghost small" data-action="delete" data-value="p&quot;ay" disabled>Delete</button>'), 'the button, its value escaped');
  ok(html.includes('<div class="muted vmf-note">Holds <a href="migrations.html?project=pay">1 &lt;migration&gt;</a>.</div>'), 'the reason, visible, with its link');
  ok(!/title=/.test(html), 'the reason is not a hover');
  const on = H.listAction({ text: 'Delete', action: 'delete', value: 'x' });
  ok(!/disabled/.test(on) && !/vmf-note/.test(on), 'an enabled button has no reason');
  eq(H.listCell(col, { act: null }), '', 'no actions');
  eq(H.listCellClass(col), ' class="vmf-actions"');
  eq(H.listCellClass({ kind: 'text' }), '');
});

test('the name can carry the description of the row under its id', () => {
  const html = H.listCell({ kind: 'name' }, { id: 'pay', name: 'Payments', note: 'Leaving <DC>', dest: { page: 'assessments', project: 'pay' } });
  ok(html.includes('href="assessments.html?project=pay"'), 'linked');
  ok(html.includes('<div class="muted vmf-desc">Leaving &lt;DC&gt;</div>'), html);
  ok(!H.listCell({ kind: 'name' }, { id: 'r', name: 'R', dest: {} }).includes('vmf-desc'), 'none when there is none');
});

test('the reason under a disabled button can wrap and is held to a width (app.css)', () => {
  const css = pageSource(path.join(DASH, 'app.css'));
  const rule = (css.match(/\.vmf-note\s*\{([^}]*)\}/) || [])[1] || '';
  ok(/white-space:\s*normal/.test(rule), 'it wraps, though the action cell does not');
  ok(/max-width/.test(rule), 'and is held to the width of the cell');
  ok(/\.vmf-actions\s*\{[^}]*white-space:\s*nowrap/.test(css), 'the buttons stay on one line');
});

function sortConfig() {
  return { id: 'pj', preferred: 'all', searchHint: 'Project name', projectFilter: false, sorts: SORTS,
           columns: [{ head: 'Project', kind: 'name' }] };
}
function sortData(n) {
  const all = Array.from({ length: n }, (_, i) => prow(`P${String(i).padStart(2, '0')}`, new Date(Date.UTC(2026, 10, 1 + (i % 7))).toISOString(), i % 4));
  return { tiles: [{ key: 'all', label: 'All projects', empty: 'None.', rows: all }], projects: [] };
}

test('mounted: the first sort is the default, a new sort starts again at page 1, and state says it', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, sortConfig());
  list.update(sortData(25));
  eq(list.state().sort, 'changed', 'the first sort');
  ok(f.parts.controls.innerHTML.includes('id="pj-sort"'), 'drawn');
  ok(!f.parts.controls.innerHTML.includes('data-list="project"'), 'no project choice');
  f.fire('click', clickOn('data-page', 'next'));
  eq(list.state().page, 1);
  f.fire('change', typeIn('sort', 'name'));
  eq([list.state().sort, list.state().page], ['name', 0], 'Name, page 1');
  ok(f.parts.table.innerHTML.indexOf('>P00<') < f.parts.table.innerHTML.indexOf('>P01<'), 'A to Z');
  f.fire('change', typeIn('sort', 'waiting'));
  ok(/>P03</.test(f.parts.table.innerHTML) && !/>P00</.test(f.parts.table.innerHTML), 'the most first: rank 3 rows on page 1, rank 0 rows not');
  f.fire('change', typeIn('sort', 'nonsense'));
  eq(list.state().sort, 'changed', 'a sort the page did not give is the first one');
});

test('mounted: the sort stays while the page reads more rows', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, sortConfig());
  list.update(sortData(5));
  f.fire('change', typeIn('sort', 'name'));
  list.update(sortData(6));
  eq(list.state().sort, 'name');
});

test('mounted: the Overview\'s list has no sort and keeps its rows in the order given', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(3), []));
  eq(list.state().sort, '', 'no sort');
  ok(!f.parts.controls.innerHTML.includes('data-list="sort"'), 'no Sort control');
  const t = f.parts.table.innerHTML;
  ok(t.indexOf('migration-0') < t.indexOf('migration-1') && t.indexOf('migration-1') < t.indexOf('migration-2'), 'the order given');
});
/* ---- PAGE-SCALE-ASSESSMENTS-1: what the Assessments page adds ---------- */

test('a name can also open something on the page: its link carries data-action and data-value, escaped', () => {
  const html = H.listCell({ kind: 'name' }, { id: 'p/a"1', name: 'P', dest: { page: 'assessments', run: 'p/a"1' },
                                             open: { action: 'report', value: 'p/a"1' } });
  ok(html.startsWith('<a class="vmf-name" href="assessments.html?run=a%221&amp;project=p" data-action="report" data-value="p/a&quot;1">P</a>'), html);
  const plain = H.listCell({ kind: 'name' }, { id: 'r', name: 'R', dest: { page: 'migrations', run: 'r' } });
  ok(plain.startsWith('<a class="vmf-name" href="migrations.html?run=r">R</a>'), 'no open: the link the Overview and Projects draw: ' + plain);
});

test('mounted: a project the page asks for is the filter once the projects hold it, and the choice shows it', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, Object.assign(config(), { project: 'p1' }));
  const none = data(rows(9), []);
  none.projects = [];
  list.update(none);
  eq(list.state().project, '', 'not yet: the projects are still being read');
  list.update(data(rows(9), []));
  eq(list.state().project, 'p1', 'the projects hold it now');
  ok(/<option value="p1" selected>/.test(f.parts.controls.innerHTML), 'the choice shows it: ' + f.parts.controls.innerHTML);
  ok(f.parts.pager.innerHTML.includes('1 to 3 of 3 that match the filter'), f.parts.pager.innerHTML);
  f.fire('change', typeIn('project', ''));
  list.update(data(rows(9), []));
  eq(list.state().project, '', 'a person who chose All projects keeps it while the page reads');
});

test('mounted: a person who chooses a project before the projects arrive keeps that choice', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, Object.assign(config(), { project: 'p1' }));
  const few = data(rows(9), []);
  few.projects = [{ id: 'p2', name: 'Project 2' }];
  list.update(few);
  f.fire('change', typeIn('project', 'p2'));
  list.update(data(rows(9), []));
  eq(list.state().project, 'p2');
});

test('mounted: no project asked for is All projects, as on the Overview', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(9), []));
  eq(list.state().project, '');
});

/* ---- PAGE-SCALE-REPORTS-1: what the Reports page adds --------------------
 *
 * The Reports page shows two lists in one card, chosen by two tabs: the
 * migration runs (the tiles' rows) and the records to download. The tabs are
 * added HERE, not on that page alone, with role="tab" and arrow keys. A page
 * that gives no tabs draws as it did (every test above, unchanged). */

/* A host for the tabs: the parts keep their attributes, and a test can fire a
 * key on a tab. */
function tabHost() {
  const f = fakeHost();
  const keyHandlers = [];
  const add = f.host.addEventListener.bind(f.host);
  f.host.addEventListener = (type, fn) => { if (type === 'keydown') { keyHandlers.push(fn); } else { add(type, fn); } };
  const query = f.host.querySelector.bind(f.host);
  f.host.querySelector = (sel) => {
    const el = query(sel);
    if (!el.attrs) { el.attrs = {}; el.setAttribute = (k, v) => { el.attrs[k] = String(v); }; el.removeAttribute = (k) => { delete el.attrs[k]; }; }
    return el;
  };
  f.key = (tab, key) => {
    let stopped = false;
    keyHandlers.forEach(fn => fn({ key, target: { closest: (s) => (s === '[data-tab]' ? { dataset: { tab } } : null) }, preventDefault() { stopped = true; } }));
    return stopped;
  };
  return f;
}
const clickTab = (tab) => ({ closest: (sel) => (sel === '[data-tab]' ? { dataset: { tab } } : null), matches: () => false });
function tabData(runRows, recordRows, extra) {
  const d = data(runRows, []);
  d.tabs = [{ key: 'runs', label: 'Migration runs', intro: 'Newest <first>.' },
            { key: 'records', label: 'Records <to> download',
              list: { title: 'Records of each migration', empty: 'No record.', intro: 'Kept 90 days.', rows: recordRows,
                      columns: [{ head: 'Migration', kind: 'name' }, { head: 'Why', kind: 'text', key: 'why' }] } }];
  return Object.assign(d, extra || {});
}

test('tabs: a labelled tablist of real tabs, the selected one in the keyboard order, each naming the panel', () => {
  const f = tabHost();
  const list = H.listMount(f.host, Object.assign(config(), { tabsLabel: 'Report <lists>' }));
  ok(/role="tablist" aria-label="Report &lt;lists&gt;"/.test(f.host.innerHTML), 'the tablist is labelled: ' + f.host.innerHTML);
  ok(/id="ov-panel"/.test(f.host.innerHTML), 'the panel has an id the tabs can name');
  list.update(tabData(rows(3), rows(2)));
  const t = f.parts.tabs.innerHTML;
  eq((t.match(/<button type="button" role="tab"/g) || []).length, 2, 'two tabs, each a button');
  ok(/id="ov-tab-runs" data-tab="runs" aria-selected="true" aria-controls="ov-panel" tabindex="0"/.test(t), t);
  ok(/id="ov-tab-records" data-tab="records" aria-selected="false" aria-controls="ov-panel" tabindex="-1"/.test(t), t);
  ok(t.includes('Records &lt;to&gt; download'), 'the label, escaped');
  eq(f.parts.tabs.hidden, false, 'shown');
  eq(f.parts.panel.attrs.role, 'tabpanel', 'the panel is a tab panel');
  eq(f.parts.panel.attrs['aria-labelledby'], 'ov-tab-runs', 'named by the selected tab');
  eq(list.state().tab, 'runs', 'the tiles\' tab first');
});

test('tabs: the tiles\' tab shows the selected tile\'s rows; the other tab shows its own list, title, columns and intro', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  list.update(tabData(rows(12), rows(3, i => ({ why: 'reason ' + i }))));
  ok(f.parts.pager.innerHTML.includes('1 to 10 of 12'), 'the tile\'s rows');
  ok(f.parts.intro.innerHTML.includes('Newest &lt;first&gt;.'), 'the tab\'s intro, escaped');
  f.fire('click', clickTab('records'));
  eq(list.state().tab, 'records');
  ok(f.parts.pager.innerHTML.includes('1 to 3 of 3'), 'the records');
  ok(f.parts.table.innerHTML.includes('>Why</th>') && f.parts.table.innerHTML.includes('reason 2'), 'its own columns');
  eq(f.parts.title.textContent, 'Records of each migration', 'its title names the list');
  ok(f.parts.intro.innerHTML.includes('Kept 90 days.'), 'its intro');
  ok(!f.parts.tiles.innerHTML.includes('aria-pressed="true"'), 'no tile is pressed while another list shows');
  eq(f.parts.panel.attrs['aria-labelledby'], 'ov-tab-records');
  ok(f.parts.tabs.innerHTML.includes('data-tab="records" aria-selected="true"'), 'the tab says it is selected');
  eq(f.focused.pop(), '[data-tab="records"]', 'the keyboard stays on the tab');
});

test('tabs: an empty list says its own sentence, and the project and the search filter it too', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  list.update(tabData(rows(3), []));
  f.fire('click', clickTab('records'));
  ok(f.parts.table.innerHTML.includes('No record.'), 'its empty sentence');
  list.update(tabData(rows(3), rows(9)));
  f.fire('change', typeIn('project', 'p1'));
  ok(f.parts.pager.innerHTML.includes('1 to 3 of 3 that match the filter'), f.parts.pager.innerHTML);
  f.fire('input', typeIn('search', 'nothing-like-this'));
  ok(f.parts.table.innerHTML.includes(TEXT.listNoMatch), 'no row matches');
});

test('tabs: a new tab starts again at page 1', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  list.update(tabData(rows(25), rows(25)));
  f.fire('click', clickOn('data-page', 'next'));
  eq(list.state().page, 1);
  f.fire('click', clickTab('records'));
  eq(list.state().page, 0);
});

test('tabs: pressing a tile goes back to the tiles\' tab and shows that tile', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  list.update(tabData(rows(3), rows(2)));
  f.fire('click', clickTab('records'));
  f.fire('click', clickOn('data-tile', 'running'));
  eq([list.state().tab, list.state().tile], ['runs', 'running']);
  ok(f.parts.tiles.innerHTML.includes('data-tile="running" aria-pressed="true"'));
});

test('tabs: Right and Left move between the tabs and round the ends, Home and End go to the first and last', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  list.update(tabData(rows(3), rows(2)));
  ok(f.key('runs', 'ArrowRight'), 'the key is taken');
  eq(list.state().tab, 'records');
  eq(f.focused.pop(), '[data-tab="records"]', 'the focus goes with it');
  f.key('records', 'ArrowRight');
  eq(list.state().tab, 'runs', 'round the end');
  f.key('runs', 'ArrowLeft');
  eq(list.state().tab, 'records', 'and back round the start');
  f.key('records', 'Home');
  eq(list.state().tab, 'runs');
  f.key('runs', 'End');
  eq(list.state().tab, 'records');
  ok(!f.key('records', 'a'), 'another key is not taken');
  eq(list.state().tab, 'records');
});

test('tabs: one tab, or none, draws no tablist and the list is the tiles\' list, as before', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  const one = data(rows(3), []);
  one.tabs = [{ key: 'runs', label: 'Migration runs' }];
  list.update(one);
  eq(f.parts.tabs.hidden, true, 'no tablist');
  eq(f.parts.tabs.innerHTML, '');
  eq(list.state().tab, null);
  eq(f.parts.title.hidden, false, 'the title heads the list');
  eq(f.parts.intro.hidden, true, 'no intro');
  ok(f.parts.tiles.innerHTML.includes('data-tile="person" aria-pressed="true"'));
});

test('tabs: they can arrive later (a role read after the rows), and go again', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  list.update(data(rows(3), []));
  ok(!f.parts.panel, 'no tabs: the panel is not touched, as on every page before');
  list.update(tabData(rows(3), rows(1)));
  eq(f.parts.tabs.hidden, false);
  eq(f.parts.title.hidden, true, 'the tabs name the lists, so the title is not shown twice');
  eq(f.parts.panel.attrs.role, 'tabpanel');
  f.fire('click', clickTab('records'));
  list.update(data(rows(3), []));
  eq(list.state().tab, null, 'the tab is gone');
  eq(f.parts.panel.attrs.role, undefined, 'and the panel is not a tab panel');
  ok(f.parts.tiles.innerHTML.includes('aria-pressed="true"'), 'a tile is pressed again');
});

test('tabs: the focus stays on a tab while the page draws again', () => {
  const f = tabHost();
  const list = H.listMount(f.host, config());
  try {
    list.update(tabData(rows(3), rows(2)));
    globalThis.document = { activeElement: { inside: true, dataset: { tab: 'records' } } };
    list.update(tabData(rows(4), rows(2)));
    eq(f.focused.pop(), '[data-tab="records"]');
  } finally { delete globalThis.document; }
});

test('a name with no address is text, not a link; a tag can carry a note after it', () => {
  const html = H.listCell({ kind: 'name' }, { id: 'p/<r>', name: 'P <x>' });
  ok(html.startsWith('<span class="vmf-name">P &lt;x&gt;</span><div class="mono muted vmf-sub">p/&lt;r&gt;</div>'), html);
  ok(!html.includes('href'), 'no link');
  eq(H.listCell({ kind: 'tag', key: 'o' }, { o: { text: 'Finished', tone: 'good', note: '2 migrated, <1> restored' } }),
    '<span class="pill good">Finished</span> <span class="outcome-note">2 migrated, &lt;1&gt; restored</span>');
  eq(H.listCell({ kind: 'tag', key: 'o' }, { o: { text: 'Finished', tone: 'good' } }), '<span class="pill good">Finished</span>', 'no note: the tag alone');
});

/* PAGE-SCALE-REPORTS-1 fix round: the Safety copies box is a list with no
 * tiles, and the page writes its own lines above the table. */
test('a list with no tiles: the tile group is hidden, and the list is the one tile\'s rows', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, Object.assign(config(), { tiles: false }));
  ok(/data-part="tiles" role="group" aria-label="[^"]*" hidden>/.test(f.host.innerHTML), 'the tile group is hidden: ' + f.host.innerHTML.slice(0, 200));
  list.update({ tiles: [{ key: 'copies', label: 'Safety copies', empty: 'None.', rows: rows(12) }], projects: [] });
  eq(f.parts.title.textContent, 'Safety copies');
  ok(f.parts.pager.innerHTML.includes('1 to 10 of 12'), 'pages of 10');
  const plain = fakeHost();
  H.listMount(plain.host, config());
  ok(!/data-part="tiles"[^>]*hidden/.test(plain.host.innerHTML), 'a page that gives tiles shows them, as before');
});

test('the page writes its own lines above the table, in the lead part the list gives back', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, config());
  ok(/data-part="lead"/.test(f.host.innerHTML), 'a lead part in the card');
  ok(f.host.innerHTML.indexOf('data-part="lead"') < f.host.innerHTML.indexOf('data-part="table"'), 'above the table');
  ok(list.lead() === f.parts.lead, 'the list gives it back');
});

test('a count says one thing for 1 and another for every other number', () => {
  const pair = ['{n} machine due', '{n} machines due'];
  eq(H.countWords(1, pair), '1 machine due');
  eq(H.countWords(0, pair), '0 machines due');
  eq(H.countWords(2, pair), '2 machines due');
  eq(H.countWords('1', pair), '1 machine due', 'a count read from a record as text');
  eq(H.countWords(3, ['{n} of {total} migration checked', '{n} of {total} migrations checked'], { total: 1, by: 1 }), '3 of 1 migration checked', 'by another number');
});

test('help.js exports the shared piece and its words', () => {
  const block = (HELP.match(/window\.VmfHelp = \{([\s\S]*?)\};/) || [])[1] || '';
  const names = block.split(/[,\n]/).map(s => s.replace(/\/\/.*$/, '').trim()).filter(Boolean);
  for (const want of ['listMount', 'listView', 'listDefaultTile', 'listHref', 'listSort', 'runTitle', 'agoText', 'LIST_LOOSE', 'LIST_PAGE_SIZE', 'countWords']) {
    ok(names.includes(want), `VmfHelp.${want} is exported`);
  }
  for (const k of ['listTiles', 'listProject', 'listAllProjects', 'listSearch', 'listRange', 'listPrevious', 'listNext', 'listNoMatch', 'listSort']) {
    ok(typeof TEXT[k] === 'string' && TEXT[k], `TEXT.${k}`);
  }
});

run('page-scale-list');
