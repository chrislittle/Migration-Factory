/* TABLE-SCALE-1: two tables on the run page that do not survive a real estate.
 *
 * Seen on a 31-machine migration that was not yet half done: on a big wave,
 * the Safety copies table was already huge on the page, and both areas grow
 * out of control on big waves. They needed a more compact form.
 *
 * Both are one row per machine, or per wave-and-size, and both repeat the
 * same sentence down the page.
 *
 * THE RULE IS ALREADY WRITTEN IN THIS CODEBASE, in the assessment report:
 * "Grouped by REASON, not per machine: twelve machines blocked for one reason
 * is one piece of work, and reading it as twelve rows hides that." These two
 * tables break it.
 *
 * AND THE QUOTA TABLE IS NOT ONLY LONG - IT IS MISLEADING. A quota is per
 * size family per region. It is NOT per wave. Eight rows each reading `0/100`
 * for the same size read as eight separate allowances when there is one,
 * shared between them.
 *
 * What must NOT happen: a group that invents agreement. Two claims for one
 * size are read at different times and can genuinely differ. Collapsing them
 * into one line that picks a winner would be the page reporting something it
 * never measured - which is the defect family this whole install has been
 * finding all day.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run, lift, liftConst, liftAll } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_COPIES = liftConst('migrations.html', 'UX_COPIES');

/* THE RENDERERS, RUN.
 *
 * Every check below used to read the source for a name. Mutation walked past
 * four of them at once: a group that picks one facet and hides the rest, a
 * row that drops the waves column, a wave that claims "all locked" without
 * looking, and a control that opens and never closes - all left the names in
 * place. Name-matching is not behaviour, and this is the fourth work item in
 * one day to prove it.
 *
 * So the page's own functions are lifted and driven, and the markup they
 * produce is what is measured.
 */
const page = liftAll('migrations.html', [
  'capacityRowProblem', 'quotaBlockedHere', 'quotaListFacet', 'reservationFact', 'reservationProblem', 'reservationBills', 'claimUsesReservation', 'capacityFamilyRows', 'capacityGateOf', 'renderCapacity', 'regionalFacet', 'capacityRegionalRows',
  'copiesWaveRows', 'renderSafetyCopies',
  'copiesLockedCell', 'copiesStatusCell', 'copiesPassSentence', 'copiesMachineRow',
  'mergeFacets', 'copiesWaveStatus', 'quotaFacetsOf', 'claimSizeBlocked', 'newestCheckOf',
]);
globalThis.mergeFacets = page.mergeFacets;
// The page's own helper, put where the lifted renderer can reach it - the
// lifted functions resolve their free names at call time, on the global.
// RES-LIST-1: the page no longer has facetsOf; the rule it held is mergeFacets over a list.
const facetsOf = (claims, facet) => page.mergeFacets(claims.map(facet));
// The page's own keep-text helper, likewise - a const arrow, so it is read
// out of the page rather than reimplemented here. A copy would test the copy.
globalThis.copyKeepText = (() => {
  const m = PAGE.match(/const copyKeepText = ([^;]+);/);
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
})();

globalThis.UX_COPIES = UX_COPIES;
// QUOTA-FAMILY-1: the card's own headings, and the two record questions the
// row grouping asks, from help.js as the page has them.
globalThis.UX_CAP = liftConst('migrations.html', 'UX_CAP');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
globalThis.VmfHelp = { claimBlocked: lift('help.js', 'claimBlocked'), claimReservingStuck: lift('help.js', 'claimReservingStuck'), countWords: lift('help.js', 'countWords'),
  // MIGRATIONS-PAGE-OLD-READERS-1: every record draws its Total Regional vCPUs row.
  claimRegionalShort: lift('help.js', 'claimRegionalShort'), claimRegionalRequested: lift('help.js', 'claimRegionalRequested') };
globalThis.esc = (v) => String(v == null ? '' : v);
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.waveLabel = (w) => w || 'Not in a wave yet';
globalThis.quotaFacet = (c) => `q:${c.quota.used}/${c.quota.limit}`;
globalThis.reservationFacet = (c) => `r:${c.state}`;
globalThis.copiesOpen = new Set();
globalThis.whenLocal = (iso) => (iso ? new Date(iso).toLocaleString() : '');

function cell(html) {
  const tds = [];
  const re = /<td[^>]*>([\s\S]*?)<\/td>/g;
  let m; while ((m = re.exec(html))) { tds.push(m[1]); }
  return tds;
}
// QUOTA-FAMILY-1: the headings are built at render time and the reservation
// columns come and go, so a cell is found by its heading, not by a number.
function column(store, heading) {
  const heads = (store['#cap-head'] ?? '').match(/<th[^>]*>[\s\S]*?<\/th>/g) || [];
  const i = heads.findIndex(h => h.replace(/<[^>]+>/g, '') === heading);
  if (i < 0) { throw new Error(`no heading ${heading} in: ${store['#cap-head']}`); }
  return i;
}
function fakeTable() {
  const store = {};
  const el = (id) => ({
    set innerHTML(v) { store[id] = v; },
    get innerHTML() { return store[id] ?? ''; },
    set textContent(v) { store[id] = v; },
    get textContent() { return store[id] ?? ''; },
    insertAdjacentHTML(_, v) { store[id] = (store[id] ?? '') + v; },
    style: {},
    querySelectorAll: () => [],
  });
  globalThis.$ = (sel) => el(sel);
  return store;
}

/* QUOTA-FAMILY-1: every record carries the family Test-VmfQuota read from the
 * SKU catalog. Without one, each record is its own row by design, so a test of
 * how records fold together must give them one. */
const claim = (wave, size, used, limit, state) => ({
  wave, size, region: 'centralus', state: state ?? 'PLANNED',
  vmFamily: 'standardDSv6Family', subscriptionId: '00000000-0000-0000-0000-000000000000',
  quota: { used, limit, regionalLimit: 1000, regionalUsed: 0 }, demand: { instances: 1, regionalVcpus: 0 }, reservation: { consumedInstances: 1 },
});

/* ---- quota and capacity ------------------------------------------------ */
// The family rows of the Quota table: every record also draws its Total Regional vCPUs row.
const familyRowCount = (html) => (String(html ?? '').match(/<tr>[\s\S]*?<\/tr>/g) || []).filter(r => !r.includes('Total Regional vCPUs @')).length;

test('RUN: one reading taken twice shows ONCE, with the newest time (QUOTA-ONCE-1)', () => {
  /* Two waves of one size carry the same quota reading, a second apart. The
   * row printed both. Only the time may differ for them to fold together. */
  const timed = (wave, used, limit, at) => ({ ...claim(wave, 'D2s_v6', used, limit), quota: { used, limit, checkedUtc: at } });
  const saved = globalThis.quotaFacet;
  globalThis.quotaFacet = (c) => `<span class="pill good">ok</span> ${c.quota.used}/${c.quota.limit}` +
    (c.quota.checkedUtc ? ` at ${c.quota.checkedUtc}` : '');
  try {
    const same = page.quotaFacetsOf([timed('a', 4, 100, '2026-09-25T10:00:00Z'), timed('b', 4, 100, '2026-09-25T10:00:01Z')]);
    ok(same.length === 1, `the same figures must show once, got: ${same.join(' | ')}`);
    ok(/10:00:01/.test(same[0]), `and with the NEWEST time, got: ${same[0]}`);
    const differ = page.quotaFacetsOf([timed('a', 0, 100, '2026-09-25T10:00:00Z'), timed('b', 4, 100, '2026-09-25T10:00:01Z')]);
    ok(differ.length === 2, `different figures under one pill must both stay, got: ${differ.join(' | ')}`);
  } finally {
    globalThis.quotaFacet = saved;
  }
});

test('capacity is grouped by what a quota actually IS', () => {
  // Per size family per region - not per wave.
  const fn = PAGE.slice(PAGE.indexOf('function renderCapacity'), PAGE.indexOf('// PLANTIME-1'));
  // QUOTA-FAMILY-1: by quota FAMILY and region now. The rows are counted by
  // running the page in quota-family.test.js; this only keeps the old shape out.
  ok(/capacityFamilyRows/.test(fn), 'the rows must be grouped');
  ok(/\bregion\b/.test(fn), 'by region as well as family, because a quota is regional');
  ok(!/sorted\.length \? '' :[\s\S]{0,200}for \(const c of sorted\)/.test(fn),
    'it can no longer draw one row per claim');
});

test('RUN: several waves of one size make ONE quota row; the reservations list has rows only for the waves that use one', () => {
  const store = fakeTable();
  page.renderCapacity([claim('wave-2', 'D2ds_v6', 0, 100), claim('wave-3', 'D2ds_v6', 0, 100),
                       claim('wave-4', 'D2ds_v6', 0, 100)], { entries: [{ wave: 'wave-2', policy: { capacityGate: 'Reserved' } }] });
  const html = store['#cap-table tbody'];
  ok(familyRowCount(html) === 1, 'three waves of one size are one quota row');
  const res = store['#res-table tbody'] ?? '';
  ok((res.match(/<tr>/g) || []).length === 1 && /wave-2/.test(res) && !/wave-3|wave-4/.test(res),
    `and the On-demand capacity reservations list has a row only for the wave that uses one, got: ${res}`);
});

/* QUOTA-FAMILY-1 REWROTE THIS. It said "two sizes stay two rows, because a
 * quota is per size" - and a quota is not per size. It is per FAMILY, per
 * region, per subscription, and every size in the family draws on it. The
 * choice is one row per family (issue 425). Two FAMILIES stay two rows. */
test('RUN: two sizes of one family are one row, and two families stay two rows', () => {
  const store = fakeTable();
  page.renderCapacity([claim('wave-2', 'D2ds_v6', 0, 100), claim('wave-2', 'D2s_v6', 0, 100)]);
  ok(familyRowCount(store['#cap-table tbody']) === 1,
    'one family is one allowance, so one row');
  const two = fakeTable();
  page.renderCapacity([claim('wave-2', 'D2ds_v6', 0, 100), { ...claim('wave-2', 'E2s_v6', 0, 100), vmFamily: 'standardESv6Family' }]);
  ok(familyRowCount(two['#cap-table tbody']) === 2,
    'two families are two allowances');
});

test('RUN: a group whose claims DISAGREE shows both, rather than picking one', () => {
  /* Two claims for one size are read at different times and can genuinely
   * differ. Showing one line that silently chose a winner would be the page
   * reporting a result it never measured.
   * QUOTA-ROW-TWICE-1 narrowed this: when the times say which reading is
   * newer, the row shows the newest only (quota-row-twice.test.js). These
   * records carry no time, so nothing says which is newer, and both stay. */
  ok(facetsOf([claim('a', 'x', 0, 100), claim('b', 'x', 4, 100)], quotaFacet).length === 2,
    'two different readings must both survive');
  ok(facetsOf([claim('a', 'x', 0, 100), claim('b', 'x', 0, 100)], quotaFacet).length === 1,
    'and two identical ones collapse to one');
  const store = fakeTable();
  page.renderCapacity([claim('wave-2', 'D2s_v6', 0, 100), claim('wave-3', 'D2s_v6', 4, 100)]);
  const tds = cell(store['#cap-table tbody']);
  const q = column(store, UX_CAP.colQuota);
  ok(/0\/100/.test(tds[q]) && /4\/100/.test(tds[q]),
    `both readings must reach the row, got: ${tds[q]}`);
});

test('RUN: QUOTA-FACET-1 - same pill, different note, is ONE pill', () => {
  /* This looked wrong on the page. Two claims both "None",
   * only one with machines in an availability set, drew two identical pills
   * with one note between them. De-duplicating the whole string compared the
   * note as if it were the state. */
  const none = '<span class="pill quiet">None</span>';
  const merged = page.mergeFacets([none, none + ' <span class="muted">2 machines in an availability set</span>']);
  ok(merged.length === 1, `one state is one pill, got ${merged.length}`);
  ok(merged[0].includes('availability set'), 'and the note is kept beside it');
  ok((merged[0].match(/None/g) || []).length === 1, 'drawn once');
});

test('RUN: RES-LIST-1 - the quota cell of a family row is merged by pill, and a reservation is never merged into it', () => {
  const store = fakeTable();
  page.renderCapacity([claim('wave-2', 'D2s_v6', 0, 100), claim('wave-3', 'D2s_v6', 0, 100)],
    { entries: [{ wave: 'wave-2', policy: { capacityGate: 'Reserved' } }] });
  const family = (store['#cap-table tbody'].match(/<tr>[\s\S]*?<\/tr>/g) || []).filter(r => !r.includes('Total Regional vCPUs @'));
  const tds = cell(family.join(''));
  ok(family.length === 1 && tds.length === 5, 'the quota row has the five quota columns only');
  ok(!/None|Not reserved/.test(store['#cap-table tbody']), 'no reservation state in it');
});
test('RUN: and DIFFERENT pills are still both shown', () => {
  // The reason for showing every reading must survive this change.
  const merged = page.mergeFacets([
    '<span class="pill quiet">None</span>',
    '<span class="pill good">Reserved</span>',
  ]);
  ok(merged.length === 2, 'a real disagreement between states stays visible');
});

/* ---- safety copies ----------------------------------------------------- */

/* From the grouping helper, not from the renderer - the helper sits above it,
 * and a slice that started at the renderer missed the very thing it asks
 * about. Third time today that a slice began after its subject. */
const COPIES = PAGE.slice(PAGE.indexOf('function copiesWaveRows'), PAGE.indexOf('function renderCapacity'));

test('safety copies are one row per WAVE, not per machine', () => {
  const fn = COPIES;
  ok(/byWave|copiesGroups/.test(fn), 'the rows must be grouped by wave');
  ok(/UX_COPIES\.colMachines|colMachines/.test(fn),
    'and count the machines rather than listing them');
});

/* The copies ledger comes from VmfHelp, so the renderer is driven with a
 * stubbed one - what is under test is how the WAVE ROW summarises it. */
function runCopies(rows, open) {
  const store = fakeTable();
  globalThis.copiesOpen = new Set(open ?? []);
  globalThis.VmfHelp = {
    ...globalThis.VmfHelp,
    safetyCopyLedger: () => rows,
    retentionPassFacts: () => ({ ran: false, unfinished: false, failures: [], nextUtc: '2026-09-24T03:30:00Z' }),
    safetyCopySummary: () => ({ machines: rows.filter(r => r.status !== 'deleted').length,
      copies: rows.filter(r => r.status !== 'deleted').reduce((n, r) => n + r.copies, 0),
      unlocked: rows.filter(r => r.status !== 'deleted').reduce((n, r) => n + (r.copies - r.locked), 0) }),
  };
  page.renderSafetyCopies([], { entries: [] }, null);
  return store;
}
const copy = (wave, vm, copies, locked, status) => ({
  wave, vmId: '/x/' + vm, copies, locked, keepDays: 7, status: status ?? 'waiting',
  dueUtc: '2026-09-30T00:00:00Z',
});

test('RUN: the machines are reachable, behind something that CLOSES', () => {
  // Rule 11: a thing that opens offers a way back.
  const shut = runCopies([copy('wave-2', 'a', 2, 2), copy('wave-2', 'b', 2, 2)]);
  const shutHtml = shut['#copies-table tbody'];
  ok((shutHtml.match(/<tr/g) || []).length === 1, 'closed, a wave is one row');
  ok(shutHtml.includes(UX_COPIES.showMachines), 'with a control to open it');

  const open = runCopies([copy('wave-2', 'a', 2, 2), copy('wave-2', 'b', 2, 2)], ['wave-2']);
  const openHtml = open['#copies-table tbody'];
  ok((openHtml.match(/<tr/g) || []).length === 3, 'open, the machines are there too');
  ok(openHtml.includes(UX_COPIES.hideMachines), 'and the control closes it again');
});

test('RUN: a wave only claims "all locked" when every copy IS', () => {
  const all = runCopies([copy('wave-2', 'a', 2, 2), copy('wave-2', 'b', 1, 1)]);
  ok(all['#copies-table tbody'].includes(UX_COPIES.lockedAll), 'all locked, so it says so');

  const some = runCopies([copy('wave-2', 'a', 2, 2), copy('wave-2', 'b', 1, 0)]);
  const html = some['#copies-table tbody'];
  ok(!html.includes('>' + UX_COPIES.lockedAll + '<'),
    'one unlocked copy means the wave is not all locked');
  ok(html.includes(UX_COPIES.lockedPart.replace('{n}', '2').replace('{m}', '3')),
    'it falls back to the count');
});

test('RUN: the summary is drawn, and counts what the rows count', () => {
  /* FOUND BY READING THE PAGE, not the code: the summary said "5 copies for
   * 3 machines" while the rows totalled 7 and 4. `safetyCopySummary` drops
   * DELETED copies; the wave rows were counting them. Two places counting
   * the same thing is how they come to disagree. */
  const store = runCopies([copy('wave-2', 'a', 2, 2), copy('wave-2', 'b', 2, 2, 'deleted')]);
  // PAGE-SCALE-REPORTS-1 fix round: a count of 1 is in the singular.
  ok(store['#copies-pass'].includes('2 copies for 1 machine.'),
    `the summary must be shown, got: ${store['#copies-pass']}`);
  const tds = cell(store['#copies-table tbody']);
  ok(tds[1].trim() === '1' && tds[2].trim() === '2',
    `the row must count on the same basis, got machines=${tds[1]} copies=${tds[2]}`);
});

/* PAGE-SCALE-REPORTS-1 fix round: a count of 1 is in the singular in
 * the Safety copies words ("1 migration", "1 machine due"). The migration
 * page's summary had the same fault: "1 copies for 1 machines", "1 are not
 * protected". */
test('RUN: the summary says 1 in the singular: 1 copy, 1 machine, 1 is not protected', () => {
  const one = runCopies([copy('wave-2', 'a', 1, 0)]);
  ok(one['#copies-pass'].startsWith('1 copy for 1 machine. 1 is not protected.'), one['#copies-pass']);
  const many = runCopies([copy('wave-2', 'a', 2, 0), copy('wave-2', 'b', 1, 1)]);
  ok(many['#copies-pass'].startsWith('3 copies for 2 machines. 2 are not protected.'), many['#copies-pass']);
});
/* ---- COPIES-ROW-1 ------------------------------------------------------ */

test('RUN: one outcome is one outcome, even seven seconds apart', () => {
  /* The case seen in the lab, with the REAL spread of times two machines get. The
   * old fixtures gave every machine the same dueUtc, so the sentences could
   * not disagree - and test data that cannot disagree cannot prove the page
   * handles disagreement. */
  const a = { ...copy('wave-2', 'a', 1, 1), dueUtc: '2026-09-30T20:06:23Z' };
  const b = { ...copy('wave-2', 'b', 1, 1), dueUtc: '2026-09-30T20:06:16Z' };
  const html = runCopies([a, b])['#copies-table tbody'];
  const tds = cell(html);
  ok(!/different outcomes/.test(tds[5]), `two machines waiting are one outcome, got: ${tds[5]}`);
  ok(tds[5] === page.copiesStatusCell(b), 'said once, with the EARLIEST date - the first copy the cleanup takes');
});

test('RUN: and two real outcomes are still two', () => {
  const html = runCopies([copy('wave-2', 'a', 1, 1, 'waiting'), copy('wave-2', 'b', 1, 1, 'inUse')])['#copies-table tbody'];
  ok(cell(html)[5] === UX_COPIES.statusVaries.replace('{n}', '2'), 'a real disagreement is not merged away');
});

test('RUN: a machine row is the shape of the table', () => {
  /* It had five cells under a six-column heading, so every column below an
   * opened wave sat one to the left of its heading. */
  const store = runCopies([copy('wave-2', 'a', 2, 2), copy('wave-2', 'b', 2, 2)], ['wave-2']);
  const headings = (store['#copies-head'].match(/<th/g) || []).length;
  const rows = store['#copies-table tbody'].split('<tr').slice(1);
  ok(headings === 6, `the heading has six columns, got ${headings}`);
  for (const r of rows) {
    const n = (r.match(/<td/g) || []).length;
    ok(n === headings, `every row has ${headings} cells, got ${n}`);
  }
  ok(/^\s*2\s*$/.test(cell(rows[1])[2]), 'and the copy count sits under Copies');
});
run('table-scale');
