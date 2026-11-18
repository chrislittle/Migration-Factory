/* LOADING-LINE-1, 2026-11-08: every page shows its "Reading ..." line from the
 * moment it starts to read until its data is drawn.
 *
 * The redesigned pages, such as Assessments, showed no sign that they were
 * loading, though every page had shown a loading line before.
 *
 * WHAT WAS WRONG. Before the page redesigns each table showed the page's
 * sentence as its one row while it read and had no row (WAIT-1). The shared
 * list (VmfHelp.listMount) had no idea of reading, so each page put the
 * sentence into the empty text of ONE tile. Assessments opens on another tile
 * and said "none to review" while it read; the Overview said nothing waits
 * once its first project landed. Three pages outside the list showed nothing:
 * Access an empty table, Assess and migrate an empty page, and the wave
 * editor wrote its line into a part of the page that stayed hidden.
 *
 * WHAT IS TESTED.
 *   1. The shared list, lifted from help.js and driven on a small host: the
 *      page's sentence before the first update, on EVERY tile while it reads
 *      and has no row, and the tile's own sentence once the read ends.
 *   2. Every page, booted OUTSIDE demo mode (tests/js/_dom.js) against a
 *      stand-in service that holds every read: the sentence is on screen
 *      before the first read answers, and gone once the reads have answered.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const HELP = pageSource(path.join(DASH, 'help.js'));

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
  'listControlsHtml', 'listTabsHtml', 'listMount', 'agoText', 'runTitle', 'listSortValue', 'listSort', 'listAction', 'listNotePart',
  'listCellClass', 'countWords']);

/* ---- 1. the shared list ------------------------------------------------- */

function fakeHost() {
  const parts = {}, handlers = {};
  const host = {
    set innerHTML(v) { this._html = v; for (const k of Object.keys(parts)) delete parts[k]; },
    get innerHTML() { return this._html; },
    querySelector(sel) {
      const m = sel.match(/^\[data-part="(\w+)"\]$/);
      if (m) { return (parts[m[1]] = parts[m[1]] || { innerHTML: '', textContent: '', querySelector: () => ({ focus() {} }), setAttribute() {}, removeAttribute() {} }); }
      return { focus() {} };
    },
    addEventListener(type, fn) { (handlers[type] = handlers[type] || []).push(fn); },
    contains: () => false,
  };
  const fire = (type, target) => (handlers[type] || []).forEach(fn => fn({ target }));
  return { host, parts, fire };
}
const clickTile = (key) => ({ closest: (sel) => (sel === '[data-tile]' ? { dataset: { tile: key } } : null), matches: () => false });
const typeSearch = (value) => ({ closest: () => null, matches: (sel) => sel === '[data-list="search"]', value });

const SENTENCE = 'Reading your migrations.';
const COLUMNS = [{ head: 'Migration', kind: 'name' }];
function cfg(extra) { return Object.assign({ id: 'll', preferred: 'first', searchHint: 'x', columns: COLUMNS, waiting: SENTENCE }, extra || {}); }
function tiles(firstRows, secondRows) {
  return [{ key: 'first', label: 'First', empty: 'Nothing in the first.', rows: firstRows || [] },
          { key: 'second', label: 'Second', empty: 'Nothing in the second.', rows: secondRows || [] }];
}
const row = (n) => ({ id: `p/m-${n}`, projectId: 'p', project: 'P', name: `Migration ${n}` });

test('list: the sentence is in the table from the moment the list is mounted, before the first update', () => {
  const f = fakeHost();
  H.listMount(f.host, cfg());
  ok(f.parts.table && f.parts.table.innerHTML.includes(SENTENCE), 'no sentence before the first update: ' + (f.parts.table || {}).innerHTML);
  ok(f.parts.table.innerHTML.includes('vmf-waiting'), 'the waiting class every page uses');
});

test('list: while the page reads, EVERY tile with no row says the sentence - not "none"', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles(), projects: [], reading: true });
  ok(f.parts.table.innerHTML.includes(SENTENCE), 'the default tile: ' + f.parts.table.innerHTML);
  ok(!f.parts.table.innerHTML.includes('Nothing in the first.'), 'said "none" before it had looked');
  f.fire('click', clickTile('second'));
  ok(f.parts.table.innerHTML.includes(SENTENCE), 'a tile the person selected: ' + f.parts.table.innerHTML);
  ok(!f.parts.table.innerHTML.includes('Nothing in the second.'), 'said "none" on the selected tile before it had looked');
});

test('list: while the page reads with no row, the pager does not say "0 to 0 of 0"', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  ok(!/0 to 0 of 0/.test((f.parts.pager || {}).innerHTML || ''), 'before the first update');
  list.update({ tiles: tiles(), projects: [], reading: true });
  ok(!/0 to 0 of 0/.test(f.parts.pager.innerHTML), 'while it reads: ' + f.parts.pager.innerHTML);
});

test('list: a search with no match while the page reads says the sentence, not "no match"', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles([row(1)]), projects: [], reading: true });
  f.fire('input', typeSearch('zzz'));
  ok(f.parts.table.innerHTML.includes(SENTENCE), 'more rows can still arrive: ' + f.parts.table.innerHTML);
});

test('list: rows that have landed are shown while the page still reads', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles([row(1)]), projects: [], reading: true });
  ok(f.parts.table.innerHTML.includes('Migration 1'), 'the row');
  ok(!f.parts.table.innerHTML.includes(SENTENCE), 'the sentence beside a row');
});

test('list: once the read ends, each tile says its own sentence and the pager comes back', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles(), projects: [], reading: true });
  list.update({ tiles: tiles(), projects: [], reading: false });
  ok(f.parts.table.innerHTML.includes('Nothing in the first.'), 'the empty sentence: ' + f.parts.table.innerHTML);
  ok(!f.parts.table.innerHTML.includes(SENTENCE), 'still said it was reading');
  ok(/0 to 0 of 0/.test(f.parts.pager.innerHTML), 'the pager');
  f.fire('input', typeSearch('zzz'));
  ok(f.parts.table.innerHTML.includes('Nothing in the first.'), 'no row, no search match: still the tile\'s sentence');
});

test('list: an update that does not say it reads is a finished read', () => {
  // A page that forgets to say it reads must never leave the sentence up
  // for ever: no `reading` is a finished read.
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles(), projects: [] });
  ok(f.parts.table.innerHTML.includes('Nothing in the first.'), f.parts.table.innerHTML);
});

test('list: a failed read says the read failed on every tile with no row, and no pager', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles(), projects: [], reading: false, failed: true });
  ok(f.parts.table.innerHTML.includes(TEXT.listReadFailed), f.parts.table.innerHTML);
  ok(!f.parts.table.innerHTML.includes(SENTENCE) && !f.parts.table.innerHTML.includes('Nothing in the first.'), 'the sentence or "none" beside a failure');
  eq(f.parts.pager.innerHTML, '', 'no "0 to 0 of 0"');
  f.fire('click', clickTile('second'));
  ok(f.parts.table.innerHTML.includes(TEXT.listReadFailed), 'on a tile the person selected too');
  list.update({ tiles: tiles([], [row(1)]), projects: [], reading: false, failed: true });
  ok(f.parts.table.innerHTML.includes('Migration 1'), 'rows that were read still show');
  list.update({ tiles: tiles(), projects: [], reading: false });
  ok(f.parts.table.innerHTML.includes('Nothing in the second.'), 'a read that works again says its own sentence');
});

test('list: a list with no sentence of its own is as it was', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg({ waiting: undefined }));
  eq((f.parts.table || {}).innerHTML || '', '', 'drew a table before the first update');
  list.update({ tiles: tiles(), projects: [], reading: true });
  ok(f.parts.table.innerHTML.includes('Nothing in the first.'), f.parts.table.innerHTML);
});

test('list: a tab with a list of its own keeps its own sentence while the page reads', () => {
  // The Reports page's records tab says its own reading state.
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles(), projects: [], reading: true,
                tabs: [{ key: 'runs', label: 'Runs' }, { key: 'rec', label: 'Records', list: { title: 'Records', empty: 'Reading the records.', rows: [] } }] });
  f.fire('click', { closest: (sel) => (sel === '[data-tab]' ? { dataset: { tab: 'rec' } } : null), matches: () => false });
  ok(f.parts.table.innerHTML.includes('Reading the records.'), f.parts.table.innerHTML);
  ok(!f.parts.table.innerHTML.includes(SENTENCE), 'the tile list\'s sentence on a tab with its own');
});

/* ---- 2. every page, booted against a service that holds its reads -------- */

const { bootHeld, turns } = require('./_held-boot');

/** The element's text now: what it was last painted with, or its text. */
const shown = (el) => (el ? `${el.innerHTML || ''} ${el.textContent || ''}` : '');
/** Every element that was painted and holds `text` in its last paint. */
function holders(r, text) {
  const last = new Map();
  for (const p of r.painted) { last.set(p.id, p.html); }
  for (const [id, el] of r.byId) { if (String(el.textContent || '').includes(text)) { last.set(id, el.textContent); } }
  return [...last.entries()].filter(([, html]) => String(html).includes(text)).map(([id]) => id);
}

const PAGES = [
  { page: 'index.html', key: 'waiting' },
  { page: 'projects.html', key: 'waiting' },
  { page: 'assessments.html', key: 'waiting' },
  { page: 'reports.html', key: 'waiting' },
  { page: 'migrations.html', key: 'UX_MISC.waiting', search: '?run=p1/mig-1' },
  { page: 'access.html', key: 'whoReading' },
  { page: 'wizard.html', key: 'runReading', search: '?run=p1/mig-1' },
  { page: 'waves.html', key: 'readingPlan', search: '?run=p1/mig-1' },
];

function sentenceOf(p) {
  const [name, key] = p.key.includes('.') ? p.key.split('.') : ['UX', p.key];
  const words = liftConst(p.page, name);
  ok(words && typeof words[key] === 'string' && words[key].startsWith('Reading'), `${p.page}: ${name}.${key} is its Reading sentence`);
  return words[key];
}

/* On screen: painted into an element that is not inside the hidden page. The
 * boot DOM has no tree, so an element is inside `#app` when the page's own
 * markup puts it there - read from the page source. */
function insideApp(pageFile, id) {
  const html = pageSource(path.join(DASH, pageFile));
  const app = html.indexOf('<div id="app"');
  if (app < 0) { return false; }
  const hostId = String(id).split(' ')[0].replace(/^#/, '');
  const at = html.indexOf(`id="${hostId}"`);
  // The app's div ends at </main> on every page; nothing after </main> is in it.
  return at > app && at < html.indexOf('</main>');
}

for (const p of PAGES) {
  test(`${p.page}: before the first read answers, the page shows its Reading sentence where a person can see it`, async () => {
    const sentence = sentenceOf(p);
    const { r, svc } = await bootHeld(p);
    eq(r.errors, [], 'nothing thrown');
    ok(svc.held.length > 0, 'the page asked the service for nothing, so nothing was held');
    const where = holders(r, sentence);
    ok(where.length > 0, `${p.page} showed no "${sentence}" while its reads were held`);
    const appShown = r.byId.get('app') && r.byId.get('app').style.display === 'block';
    const visible = where.filter(id => {
      const el = r.byId.get(String(id).split(' ')[0]) || null;
      if (el && el.hidden) { return false; }
      return appShown || !insideApp(p.page, id);
    });
    ok(visible.length > 0, `${p.page}: "${sentence}" is only in ${where.join(', ')}, which a person cannot see`);
  });

  test(`${p.page}: once the reads answer, the Reading sentence is gone`, async () => {
    const sentence = sentenceOf(p);
    const { r, svc } = await bootHeld(p);
    svc.release();
    await turns(r, 15);
    eq(r.errors, [], 'nothing thrown');
    const left = holders(r, sentence).filter(id => { const el = r.byId.get(String(id).split(' ')[0]); return !(el && el.hidden); });
    eq(left, [], `${p.page} still shows "${sentence}" after every read answered`);
  });

  /* REVIEW, fix round: a read that FAILS ends the read too. Three pages left
   * the sentence drawn at mount up beside the error, because the throw
   * skipped the draw that tells the list the read ended. */
  test(`${p.page}: when the store refuses the read, the Reading sentence is gone`, async () => {
    const sentence = sentenceOf(p);
    const { r, svc } = await bootHeld(p, true);
    svc.release();
    await turns(r, 15);
    const left = holders(r, sentence).filter(id => { const el = r.byId.get(String(id).split(' ')[0]); return !(el && el.hidden); });
    eq(left, [], `${p.page} still shows "${sentence}" beside the failure`);
  });
}

/* And the list says the read failed - never the tile's "none", which would
 * be a finished sentence about a store nobody could read. */
for (const page of ['projects.html', 'assessments.html', 'reports.html']) {
  test(`${page}: when the store refuses the read, the list says the read failed, not "none"`, async () => {
    const { r, svc } = await bootHeld({ page }, true);
    svc.release();
    await turns(r, 15);
    const tables = r.painted.filter(x => / table$/.test(x.id));
    const last = tables.length ? tables[tables.length - 1].html : '';
    ok(last.includes(TEXT.listReadFailed), `${page}: the list after a refused read: ${last}`);
  });
}

/* ---- 3. the Reports page's Safety copies box ---------------------------- */

test('reports.html: the Safety copies box says it reads the copies until the list is drawn over it', async () => {
  const { safetyPanel } = liftAll('reports.html', ['safetyPanel']);
  const RUX = liftConst('reports.html', 'UX');
  ok(typeof RUX.copiesReading === 'string' && RUX.copiesReading.startsWith('Reading'), 'the Reading sentence');
  const card = { className: '', innerHTML: '' };
  let answer;
  const drawn = [];
  const saved = { document: globalThis.document, UX: globalThis.UX, VmfHelp: globalThis.VmfHelp };
  try {
    Object.assign(globalThis, {
      document: { getElementById: (id) => (id === 'copies-card' ? card : null) },
      UX: RUX,
      VmfHelp: { waitingLine: (t) => `<p class="muted vmf-waiting">${esc(t)}</p>` },
      copiesRunIds: () => ['p/mig-1'],
      copiesFacts: () => new Promise((done) => { answer = done; }),
      drawCopies: (host) => { drawn.push(true); host.innerHTML = '<div>the list</div>'; },
    });
    const going = safetyPanel();
    ok(card.innerHTML.includes(RUX.copiesReading), 'before the copies are read: ' + card.innerHTML);
    ok(card.innerHTML.includes(RUX.copiesTitle), 'the box is named while it reads');
    answer({ per: [], pass: null });
    await going;
    eq(drawn.length, 1, 'the list is drawn');
    ok(!card.innerHTML.includes(RUX.copiesReading), 'still said it read after the list was drawn');
  } finally { Object.assign(globalThis, saved); }
});

run('loading-line');
