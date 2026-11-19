/* TILE-COUNT-READING-1, 2026-11-08: a count tile says no number while its
 * page reads.
 *
 * WHAT WAS WRONG. The count tiles of the shared list (VmfHelp.listMount) on
 * the Overview, Projects, Assessments and Reports pages showed the number of
 * rows read so far: "0 To review" for the seconds every load takes, for an
 * estate with assessments to review. LOADING-LINE-1 put the page's "Reading
 * ..." line in the table under them; the number itself still said 0. Lead
 * decision: a count tile that says 0 on every load is a false statement.
 *
 * THE RULE. While the page reads, every tile says "Reading" in place of its
 * number. When the read ends, the count. When the read fails, "Not known" -
 * the count of a store nobody could read is not known, never 0, and never the
 * part that was read before the failure.
 *
 * WHAT IS TESTED. The tiles of the shared list, lifted from help.js and
 * driven; then the Projects, Assessments and Reports pages booted outside demo
 * mode against a service that holds every read, answers it with an empty
 * store, or refuses it (tests/js/_held-boot.js).
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');
const { bootHeld, turns } = require('./_held-boot');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
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

/** The number or the words each tile shows, in order. */
const tileValues = (html) => [...String(html).matchAll(/<span class="val[^"]*">([^<]*)<\/span>/g)].map(m => m[1]);

function fakeHost() {
  const parts = {};
  const host = {
    set innerHTML(v) { this._html = v; for (const k of Object.keys(parts)) delete parts[k]; },
    get innerHTML() { return this._html; },
    querySelector(sel) {
      const m = sel.match(/^\[data-part="(\w+)"\]$/);
      if (m) { return (parts[m[1]] = parts[m[1]] || { innerHTML: '', textContent: '', querySelector: () => ({ focus() {} }), setAttribute() {}, removeAttribute() {} }); }
      return { focus() {} };
    },
    addEventListener() {}, contains: () => false,
  };
  return { host, parts };
}
const row = (n) => ({ id: `p/m-${n}`, projectId: 'p', project: 'P', name: `Migration ${n}` });
const tiles = (a, b) => [{ key: 'a', label: 'A', empty: 'None in A.', rows: a || [] },
                         { key: 'b', label: 'B', tone: 'bad', empty: 'None in B.', rows: b || [] }];
const cfg = (extra) => Object.assign({ id: 'tc', preferred: 'a', columns: [{ head: 'Name', kind: 'name' }], waiting: 'Reading your things.' }, extra || {});

test('the words exist, and are not a number', () => {
  ok(typeof TEXT.listCountReading === 'string' && TEXT.listCountReading && !/\d/.test(TEXT.listCountReading), String(TEXT.listCountReading));
  ok(typeof TEXT.listCountFailed === 'string' && TEXT.listCountFailed && !/\d/.test(TEXT.listCountFailed), String(TEXT.listCountFailed));
});

test('list: while the page reads, every tile says Reading - not 0, and not the count so far', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles([], [row(1), row(2)]), projects: [], reading: true });
  eq(tileValues(f.parts.tiles.innerHTML), [TEXT.listCountReading, TEXT.listCountReading], f.parts.tiles.innerHTML);
  ok(f.parts.tiles.innerHTML.includes('vmf-waiting'), 'the waiting style every page uses');
});

test('list: when the read ends, each tile shows its count', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles([], [row(1)]), projects: [], reading: true });
  list.update({ tiles: tiles([], [row(1), row(2)]), projects: [], reading: false });
  eq(tileValues(f.parts.tiles.innerHTML), ['0', '2']);
  ok(!f.parts.tiles.innerHTML.includes('vmf-waiting'), 'still styled as waiting');
});

test('list: when the read fails, every tile says Not known - never 0, never the part read before the failure', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: tiles([], [row(1)]), projects: [], reading: false, failed: true });
  eq(tileValues(f.parts.tiles.innerHTML), [TEXT.listCountFailed, TEXT.listCountFailed], f.parts.tiles.innerHTML);
});

test('list: a list with no Reading sentence counts as it always did', () => {
  // The Safety copies box mounts a list with no sentence and no tiles shown.
  const f = fakeHost();
  const list = H.listMount(f.host, cfg({ waiting: undefined }));
  list.update({ tiles: tiles([row(1)]), projects: [], reading: true });
  eq(tileValues(f.parts.tiles.innerHTML), ['1', '0']);
});

test('list: the tile is still a button with its label, and its words are escaped', () => {
  const f = fakeHost();
  const list = H.listMount(f.host, cfg());
  list.update({ tiles: [{ key: 'a', label: 'A <b>', empty: 'x', rows: [] }], projects: [], reading: true });
  ok(/<button type="button" class="kpi vmf-tile" data-tile="a" aria-pressed="true">/.test(f.parts.tiles.innerHTML), f.parts.tiles.innerHTML);
  ok(f.parts.tiles.innerHTML.includes('A &lt;b&gt;'), 'the label, escaped');
});

/* ---- the pages ---------------------------------------------------------- */

const lastTiles = (r) => {
  const all = r.painted.filter(x => / tiles$/.test(x.id));
  return all.length ? all[all.length - 1].html : '';
};

for (const page of ['projects.html', 'assessments.html', 'reports.html']) {
  test(`${page}: before the first read answers, no tile shows a number`, async () => {
    const { r, svc } = await bootHeld({ page });
    ok(svc.held.length > 0, 'nothing was held');
    const values = tileValues(lastTiles(r));
    ok(values.length > 0, `${page} drew no tile`);
    eq(values.filter(v => v !== TEXT.listCountReading), [], `${page} tiles while it reads`);
  });

  test(`${page}: once the reads answer, each tile shows its count`, async () => {
    const { r, svc } = await bootHeld({ page });
    svc.release();
    await turns(r, 15);
    const values = tileValues(lastTiles(r));
    ok(values.length > 0 && values.every(v => v === '0'), `${page} tiles after an empty store: ${values}`);
  });

  test(`${page}: when the store refuses the read, each tile says Not known`, async () => {
    const { r, svc } = await bootHeld({ page }, true);
    svc.release();
    await turns(r, 15);
    const values = tileValues(lastTiles(r));
    ok(values.length > 0 && values.every(v => v === TEXT.listCountFailed), `${page} tiles after a refused read: ${values}`);
  });
}

/* REVIEW (fix round): the Overview. With nothing read yet it shows its Reading
 * card, not the tiles. A failed read used to empty the page, leaving only the
 * error banner - no tile and no list - while the manual said each tile says
 * Not known. It now keeps the tiles and the list, as the other three pages. */
test('index.html: before the first read answers, it says what it reads and shows no number', async () => {
  const { r, svc } = await bootHeld({ page: 'index.html' });
  ok(svc.held.length > 0, 'nothing was held');
  eq(tileValues(lastTiles(r)).filter(v => v !== TEXT.listCountReading), [], 'a tile with a number while it reads');
  const panels = r.painted.filter(x => x.id === 'panels').map(x => x.html).pop() || '';
  ok(panels.includes('vmf-waiting'), 'the Reading card: ' + panels);
});

test('index.html: when the store refuses the read, each tile says Not known and the list says the read failed', async () => {
  const { r, svc } = await bootHeld({ page: 'index.html' }, true);
  svc.release();
  await turns(r, 15);
  const values = tileValues(lastTiles(r));
  ok(values.length > 0 && values.every(v => v === TEXT.listCountFailed), `the tiles after a refused read: ${values}`);
  const tables = r.painted.filter(x => / table$/.test(x.id));
  const last = tables.length ? tables[tables.length - 1].html : '';
  ok(last.includes(TEXT.listReadFailed), 'the list after a refused read: ' + last);
  const panels = r.painted.filter(x => x.id === 'panels').map(x => x.html).pop() || '';
  ok(panels.includes('id="ov-list"'), 'the tiles and the list are on the page: ' + panels);
  const err = r.byId.get('err');
  ok(err && err.style.display === 'block' && String(err.textContent).length > 0, 'the banner gives the reason');
});

test('index.html: an empty store still says where to start, with no tile', async () => {
  const { r, svc } = await bootHeld({ page: 'index.html' });
  svc.release();
  await turns(r, 15);
  const panels = r.painted.filter(x => x.id === 'panels').map(x => x.html).pop() || '';
  ok(panels.includes('href="projects.html"') && !panels.includes('id="ov-list"'), 'the first visit: ' + panels);
});

run('tile-count-reading');
