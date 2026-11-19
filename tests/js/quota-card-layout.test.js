/* QUOTA-CARD-LAYOUT-1: the Quota card reads as an even table with 2 rows or
 * 30, and with 1 size or 15 sizes in a row.
 *
 * What a person saw, on a real migration with six rows: the Sizes column took
 * most of the width, the Quota column was squeezed, "0/100 checked 3m ago"
 * wrapped and left "ago" alone under the Headroom verified pill on every row,
 * and "vCPUs needed" and "vCPUs free" broke onto two lines. At phone width the
 * card cut the table off: the card hides what runs past it, so the Quota
 * column could not be seen at all.
 *
 * The rules this pins, each one the layout depends on:
 *   - the two tables of the card sit in the product's own wide-table box
 *     (.vmf-scroll, as VmfHelp.listMount and the Reports page use), so a
 *     table wider than a phone scrolls inside its box, and the page does not;
 *   - the Quota cell (pill and "n/limit checked Xm ago") never wraps;
 *   - a heading never wraps, so every row lines up under one-line headings;
 *   - the numbers are right-aligned, with tabular figures, and never wrap;
 *   - a long Sizes list wraps between names inside its own column, which has
 *     a floor so it is not crushed to one name per line;
 *   - in the On-demand capacity reservations list, a size (with its zone) is
 *     one thing and does not break, Details has a floor (at phone width it
 *     was squeezed to one word on a line), and Release stays on one line.
 *
 * RUN, not read, for the markup: the page's own renderCapacity draws the card
 * from tests/fixtures/quota-card-many-sizes.json. The rules that only a
 * browser applies are read from app.css and the page markup.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { test, ok, eq, run, lift, liftAll, liftConst } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const DASH = path.join(REPO, 'src', 'dashboard');
const FIX = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'quota-card-many-sizes.json'), 'utf8'));

globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_CAP = liftConst('migrations.html', 'UX_CAP');
globalThis.BLOCK_TEXT = liftConst('migrations.html', 'BLOCK_TEXT');
globalThis.RESERVING_STUCK_MINUTES = 60;
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
globalThis.VmfHelp = {
  claimBlocked: globalThis.claimBlocked,
  claimReservingStuck: lift('help.js', 'claimReservingStuck'),
  claimRegionalShort: lift('help.js', 'claimRegionalShort'),
  claimRegionalRequested: lift('help.js', 'claimRegionalRequested'),
};
globalThis.esc = (v) => String(v == null ? '' : v)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.ago = () => '3m ago';
globalThis.waveLabel = (w) => w || 'Not moved';
globalThis.askReleaseReservation = () => {};

const page = liftAll('migrations.html', [
  'quotaFacet', 'reservationFacet', 'mergeFacets', 'quotaFacetsOf', 'regionalFacet', 'capacityRegionalRows',
  'capacityRowProblem', 'quotaBlockedHere', 'quotaListFacet', 'reservationFact', 'reservationProblem', 'reservationBills',
  'claimUsesReservation', 'capacityFamilyRows', 'capacityGateOf', 'renderCapacity', 'claimSizeBlocked', 'newestCheckOf',
]);
globalThis.mergeFacets = page.mergeFacets;

function fakeDom() {
  const store = {};
  globalThis.$ = (id) => ({
    set innerHTML(v) { store[id] = v; },
    get innerHTML() { return store[id] ?? ''; },
    insertAdjacentHTML(_, v) { store[id] = (store[id] ?? '') + v; },
    style: {},
    querySelectorAll: () => [],
  });
  return store;
}
const rowsOf = (html) => (html ?? '').split('<tr').slice(1);
/** Each cell of a row: its class list and its inner markup. */
function cells(rowHtml) {
  const out = [];
  const re = /<td([^>]*)>([\s\S]*?)<\/td>/g;
  let m;
  while ((m = re.exec(rowHtml))) {
    const cls = (m[1].match(/class="([^"]*)"/) || [])[1] || '';
    out.push({ cls: cls.split(/\s+/).filter(Boolean), html: m[2] });
  }
  return out;
}
function heads(html) {
  return (html.match(/<th[^>]*>[\s\S]*?<\/th>/g) || []).map(h => ({
    cls: ((h.match(/class="([^"]*)"/) || [])[1] || '').split(/\s+/).filter(Boolean),
    text: h.replace(/<[^>]+>/g, ''),
  }));
}
const withTime = (claims) => claims.map(c => ({ schemaVersion: 2, ...c, quota: { ...c.quota, checkedUtc: FIX.checkedUtc } }));

/* 30 family rows, one of them with 15 sizes: the size of estate the card must
 * still read as a table at. */
function bigEstate() {
  const claims = [];
  for (let i = 0; i < 30; i++) {
    const n = i === 0 ? 15 : 1;
    for (let s = 0; s < n; s++) {
      claims.push({ wave: 'wave-1', region: 'centralus', zone: null, size: `Standard_D${2 + s}s_v${i}`, vmFamily: `family${String(i).padStart(2, '0')}`,
        state: 'QUOTA_VERIFIED', blockReason: null,
        demand: { instances: 1, reservableInstances: 1, vcpus: 2, familyVcpus: 2 * n, regionalVcpus: 0 },
        quota: { limit: 100, used: i, regionalLimit: 350, regionalUsed: 24 } });
    }
  }
  return claims;
}

function checkQuotaTable(store, sizesInRegional) {
  const hs = heads(store['#cap-head']);
  eq(hs.length, 5, 'the Quota list has its five columns');
  const at = (text) => hs.findIndex(h => h.text === text);
  const sizesAt = at(UX_CAP.colSizes), quotaAt = at(UX_CAP.colQuota);
  const needAt = at(UX_CAP.colNeeded), freeAt = at(UX_CAP.colFree);
  ok(hs[needAt].cls.includes('num') && hs[freeAt].cls.includes('num'), 'the two vCPU headings are number headings');
  ok(hs[sizesAt].cls.includes('cap-sizes'), 'the Sizes heading carries the Sizes column class');
  ok(hs[quotaAt].cls.includes('cap-quota'), 'the Quota heading carries the Quota column class');
  const rows = rowsOf(store['#cap-table tbody']);
  ok(rows.length > 1, 'rows were drawn');
  for (const r of rows) {
    const tds = cells(r);
    eq(tds.length, 5, 'every row has five cells');
    ok(tds[sizesAt].cls.includes('cap-sizes'), 'the sizes cell is in the Sizes column');
    ok(tds[quotaAt].cls.includes('cap-quota'), 'the quota cell is in the Quota column, which never wraps');
    ok(tds[needAt].cls.includes('num') && tds[freeAt].cls.includes('num'), 'the vCPU figures are number cells');
    // A size is one thing: the list breaks between names, never inside one.
    const names = tds[sizesAt].html.match(/<span class="nowrap[^"]*"/g) || [];
    ok(names.length >= 1, 'each size is held together');
  }
  const regional = rows.find(r => r.includes(esc(UX_CAP.regionalName)));
  ok(regional, 'the Total Regional vCPUs row is drawn');
  const names = (cells(regional)[sizesAt].html.match(/<span class="nowrap[^"]*"/g) || []).length;
  eq(names, sizesInRegional, 'the Total Regional vCPUs row lists every size, each held together');
}

test('the Quota list, from a migration of many sizes: column classes on every heading and cell', () => {
  const store = fakeDom();
  page.renderCapacity(withTime(FIX.claims), FIX.plan, () => true);
  checkQuotaTable(store, new Set(FIX.claims.map(c => c.size)).size);
});

test('the same rules hold for 30 rows, and a row of 15 sizes', () => {
  const store = fakeDom();
  page.renderCapacity(withTime(bigEstate()), { entries: [{ wave: 'wave-1', policy: { capacityGate: 'BestEffort' } }] }, () => false);
  checkQuotaTable(store, 15 + 29);
  const wide = rowsOf(store['#cap-table tbody']).find(r => r.includes('family00'));
  const sizesCell = cells(wide).find(td => td.cls.includes('cap-sizes'));
  eq((sizesCell.html.match(/<span class="nowrap/g) || []).length, 15, 'the row of 15 sizes lists all 15 in its own column');
});

test('the On-demand capacity reservations list: a size does not break, and Details has a floor, and Release stays on one line', () => {
  const store = fakeDom();
  page.renderCapacity(withTime(FIX.claims), FIX.plan, () => true);
  const rows = rowsOf(store['#res-table tbody']);
  eq(rows.length, 3, 'one row for each wave and size that reserves');
  const hs = heads(store['#res-head']);
  const sizeAt = hs.findIndex(h => h.text === UX_CAP.colSize);
  ok(sizeAt >= 0, 'the list has its Size column');
  ok(hs[hs.length - 1].cls.includes('cap-act'), 'the last heading is the Release column');
  const factAt = hs.findIndex(h => h.text === UX_CAP.colFact);
  ok(factAt >= 0 && hs[factAt].cls.includes('cap-fact'), 'the Details heading carries the Details column class');
  for (const r of rows) {
    const tds = cells(r);
    ok(/^<span class="[^"]*\bnowrap\b[^"]*\bmono\b|^<span class="[^"]*\bmono\b[^"]*\bnowrap\b/.test(tds[sizeAt].html),
      'the size, with its zone, is held together');
    ok(tds[tds.length - 1].cls.includes('cap-act'), 'the Release cell is in the Release column');
    ok(tds[factAt].cls.includes('cap-fact'), 'the fact is in the Details column, which has a floor');
  }
  ok(rows.some(r => r.includes('data-releasewave')), 'Release is drawn');
});

const CSS = pageSource(path.join(DASH, 'app.css'));
const ruleFor = (selectorRe) => {
  const m = CSS.match(new RegExp(selectorRe.source + String.raw`\s*\{([^}]*)\}`));
  return m ? m[1] : '';
};

test('the browser rules: no heading wraps, the Quota cell does not wrap, the numbers align (app.css)', () => {
  ok(/white-space:\s*nowrap/.test(ruleFor(/#capacity-card th/)), 'no heading of the card wraps');
  ok(/white-space:\s*nowrap/.test(ruleFor(/#capacity-card td\.cap-quota/)), 'the pill and its reading stay on one line');
  const num = ruleFor(/#capacity-card td\.num/);
  ok(/white-space:\s*nowrap/.test(num), 'a figure never wraps');
  ok(/width:\s*1%/.test(num), 'a figure column is as narrow as its heading');
  ok(/display:\s*block/.test(ruleFor(/#capacity-card td\.cap-sizes::before/)) && /width:\s*\d+ch/.test(ruleFor(/#capacity-card td\.cap-sizes::before/)), 'the Sizes column has a floor, and wraps above it');
  ok(/white-space:\s*nowrap/.test(ruleFor(/#capacity-card td\.cap-act/)), 'Release stays on one line');
  ok(/display:\s*block/.test(ruleFor(/#capacity-card td\.cap-fact::before/)) && /width:\s*\d+ch/.test(ruleFor(/#capacity-card td\.cap-fact::before/)), 'Details has a floor, so a short fact is not one word on a line');
  const any = ruleFor(/td\.num,th\.num/);
  ok(/text-align:\s*right/.test(any) && /tabular-nums/.test(any), 'figures are right-aligned with tabular figures');
  ok(/white-space:\s*nowrap/.test(ruleFor(/\.pill/)), 'a pill never wraps');
  ok(/overflow-x:\s*auto/.test(ruleFor(/\.vmf-scroll/)), 'the wide-table box scrolls sideways');
});

test('both tables of the card sit in the wide-table box, so a phone scrolls the table and not the page', () => {
  const html = fs.readFileSync(path.join(DASH, 'migrations.html'), 'utf8');
  ok(/<div class="vmf-scroll">\s*<table id="cap-table">/.test(html), 'the Quota list is in its own box');
  ok(/<div class="vmf-scroll">\s*<table id="res-table">/.test(html), 'the On-demand capacity reservations list is in its own box');
});

run('quota card layout');
