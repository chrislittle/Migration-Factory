/* QUOTA-FAMILY-1 (issue 425): the quota card is one row per QUOTA FAMILY and
 * region, not one per size.
 *
 * A wave that mixed many sizes drew one row for each, and a quota is not per
 * size: Azure gives ONE allowance per family per region per subscription, and
 * every size in the family draws on it. Rows per size hid the sum - two rows
 * that each fit could share one allowance that did not.
 *
 * The family comes from the record (`vmFamily`, which Test-VmfQuota reads from
 * the SKU catalog), NEVER from the size name: s-suffix v6 sizes bill under the
 * general d_v6 family, so a name says nothing reliable. A record with no
 * family is its own row and says so. Merging it by size name would be the page
 * guessing a family.
 *
 * Every check below RUNS the page's own functions with the page's own pills
 * (quotaFacet, reservationFacet) and measures the markup they draw.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, eq, run, lift, liftAll, liftConst } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_CAP = liftConst('migrations.html', 'UX_CAP');
globalThis.UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
globalThis.BLOCK_TEXT = liftConst('migrations.html', 'BLOCK_TEXT');
globalThis.RESERVING_STUCK_MINUTES = 60;
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
globalThis.VmfHelp = {
  claimBlocked: lift('help.js', 'claimBlocked'),
  claimReservingStuck: lift('help.js', 'claimReservingStuck'),
  // MIGRATIONS-PAGE-OLD-READERS-1: every record draws its Total Regional vCPUs row.
  claimRegionalShort: lift('help.js', 'claimRegionalShort'),
  claimRegionalRequested: lift('help.js', 'claimRegionalRequested'),
};
globalThis.esc = (v) => String(v == null ? '' : v)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.ago = () => 'a moment ago';
globalThis.waveLabel = (w) => w || 'Not moved';

const page = liftAll('migrations.html', [
  'quotaFacet', 'reservationFacet', 'mergeFacets', 'quotaFacetsOf', 'regionalFacet', 'capacityRegionalRows',
  'capacityRowProblem', 'quotaBlockedHere', 'quotaListFacet', 'reservationFact', 'reservationProblem', 'reservationBills', 'claimUsesReservation', 'capacityFamilyRows', 'capacityGateOf', 'renderCapacity',
  'claimSizeBlocked', 'newestCheckOf',
]);
globalThis.mergeFacets = page.mergeFacets;

function fakeTable() {
  const store = {};
  const styles = {};
  Object.defineProperty(store, '__styles', { value: styles, enumerable: false });
  const els = {};
  Object.defineProperty(store, '__els', { value: els, enumerable: false });
  const el = (id) => (els[id] ??= {
    set innerHTML(v) { store[id] = v; },
    get innerHTML() { return store[id] ?? ''; },
    insertAdjacentHTML(_, v) { store[id] = (store[id] ?? '') + v; },
    get style() { return (styles[id] ??= {}); },
    querySelectorAll: () => [],
    get children() { return { length: ((store[id] ?? '').match(/<th/g) || []).length }; },
  });
  globalThis.$ = (sel) => el(sel);
  return store;
}
const rowsOf = (html) => html.split('<tr').slice(1);
function cells(rowHtml) {
  const tds = [];
  const re = /<td[^>]*>([\s\S]*?)<\/td>/g;
  let m; while ((m = re.exec(rowHtml))) { tds.push(m[1]); }
  return tds;
}
const headingsOf = (html) => (html.match(/<th[^>]*>([\s\S]*?)<\/th>/g) || []).map(h => h.replace(/<[^>]+>/g, ''));

const SUB_A = '00000000-0000-0000-0000-000000000000';
const SUB_B = '11111111-1111-1111-1111-111111111111';
/* Records shaped as Test-VmfQuota writes them (schemas/capacity-claim). */
const rec = (o) => ({
  schemaVersion: 9, runId: 'r1', wave: o.wave ?? 'wave-1', subscriptionId: o.sub ?? SUB_A,
  resourceGroup: 'rg-app', region: o.region ?? 'centralus', zone: o.zone ?? null,
  size: o.size, vmFamily: o.family === undefined ? 'standardDSv6Family' : o.family,
  state: o.state ?? 'QUOTA_VERIFIED', blockReason: o.blockReason ?? null,
  demand: { instances: o.n ?? 1, reservableInstances: o.n ?? 1, vcpus: o.vcpus ?? 2, regionalVcpus: 0,
    ...(o.total === undefined ? {} : { familyVcpus: o.total }) },
  quota: o.quota === null ? undefined : { limit: o.limit === undefined ? 100 : o.limit, used: o.used ?? 10, checkedUtc: o.at ?? null, regionalLimit: 1000, regionalUsed: 0 },
  ...(o.reservation ? { reservation: o.reservation } : {}),
});

/* ---- grouping ---------------------------------------------------------- */

test('two sizes in one family make ONE row, and the row lists both sizes', () => {
  const rows = page.capacityFamilyRows([
    rec({ size: 'Standard_D2s_v6', vcpus: 2 }),
    rec({ size: 'Standard_D4s_v6', vcpus: 4 }),
  ]);
  eq(rows.length, 1, 'one family in one region is one row');
  eq(rows[0].sizes.map(s => s.size).sort(), ['Standard_D2s_v6', 'Standard_D4s_v6'], 'both sizes are in the row');

  const store = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6' }), rec({ size: 'Standard_D4s_v6' })], null);
  const drawn = rowsOf(store['#cap-table tbody']);
  eq(drawn.filter(r => !r.includes('Total Regional vCPUs @')).length, 1, 'and the card draws one family row');
  ok(/Standard_D2s_v6/.test(drawn[0]) && /Standard_D4s_v6/.test(drawn[0]), 'which names both sizes');
  ok(/standardDSv6Family/.test(cells(drawn[0])[0]), 'and the family from the record');
});

test('the family is the RECORD\'s, never the size name\'s', () => {
  /* Two names that look like two families, recorded as one, are one row. Two
   * names that look like one family, recorded as two, are two rows. Either
   * case reading the name instead of the record gets it wrong. */
  const oneFamily = page.capacityFamilyRows([
    rec({ size: 'Standard_D2s_v6', family: 'standardDDSv6Family' }),
    rec({ size: 'Standard_D2ds_v6', family: 'standardDDSv6Family' }),
  ]);
  eq(oneFamily.length, 1, 'sizes the records put in one family share a row');
  const twoFamilies = page.capacityFamilyRows([
    rec({ size: 'Standard_D2s_v6', family: 'familyOne' }),
    rec({ size: 'Standard_D4s_v6', family: 'familyTwo' }),
  ]);
  eq(twoFamilies.length, 2, 'sizes the records put in two families stay apart');
});

/* vCPUs needed is the ENGINE'S family total (demand.familyVcpus, capacity-claim
 * v10) - the number Test-VmfQuota judged the headroom against, over every size,
 * wave and zone of the family in the region. The first version of this card
 * summed the records itself, and the review found it counted a finished
 * wave's machines for ever: those records are never rewritten. */
test('vCPUs needed is the family total the check recorded, per family AND region', () => {
  const rows = page.capacityFamilyRows([
    rec({ wave: 'wave-1', size: 'Standard_D2s_v6', vcpus: 4, total: 18 }),
    rec({ wave: 'wave-2', size: 'Standard_D4s_v6', vcpus: 8, total: 18 }),
    rec({ wave: 'wave-2', size: 'Standard_D2s_v6', vcpus: 6, zone: '2', total: 18 }),
    rec({ wave: 'wave-1', size: 'Standard_D2s_v6', vcpus: 2, region: 'eastus2', total: 2 }),
  ]);
  eq(rows.length, 2, 'two regions are two rows');
  eq(rows.find(r => r.region === 'centralus').neededVcpus, 18, 'the family total in one region');
  eq(rows.find(r => r.region === 'eastus2').neededVcpus, 2, 'and another region keeps its own');

  const store = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6', vcpus: 4, used: 10, limit: 100, total: 12 }),
                       rec({ size: 'Standard_D4s_v6', vcpus: 8, used: 10, limit: 100, total: 12 })], null);
  const tds = cells(rowsOf(store['#cap-table tbody'])[0]);
  const heads = headingsOf(store['#cap-head']);
  eq(tds[heads.indexOf(UX_CAP.colNeeded)].trim(), '12', 'the row shows the family total');
  eq(tds[heads.indexOf(UX_CAP.colFree)].trim(), '90', 'against the free vCPUs: limit minus used');
});

test('the page never makes a sum of its own', () => {
  /* A finished wave's record from an earlier check sits beside the newest
   * check. The newest total is the answer; adding the two would count the
   * finished wave's machines again. */
  const rows = page.capacityFamilyRows([
    rec({ wave: 'wave-0', size: 'Standard_D2s_v6', vcpus: 10, total: 18, at: '2026-09-25T10:00:00Z' }),
    rec({ wave: 'wave-1', size: 'Standard_D2s_v6', vcpus: 8, total: 8, at: '2026-09-25T11:00:00Z' }),
  ]);
  eq(rows[0].neededVcpus, 8, 'the newest check, not 18 and not 26');
  const old = page.capacityFamilyRows([rec({ size: 'Standard_D2s_v6', vcpus: 4 }), rec({ size: 'Standard_D4s_v6', vcpus: 8 })]);
  eq(old[0].neededVcpus, null, 'records with no total (written before v10) give no number, never a sum');
  const store = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6', vcpus: 4 })], null);
  const heads = headingsOf(store['#cap-head']);
  eq(cells(rowsOf(store['#cap-table tbody'])[0])[heads.indexOf(UX_CAP.colNeeded)].trim(), '-', 'and the card says not known');
  const noFamily = page.capacityFamilyRows([rec({ size: 'Standard_D2s_v6', family: null, state: 'BLOCKED', blockReason: 'size-missing', limit: null, total: 1 })]);
  eq(noFamily[0].neededVcpus, null, 'a record with no family has no family total, whatever it carries');
});

test('a subscription is its own allowance, so two subscriptions are two rows', () => {
  const rows = page.capacityFamilyRows([
    rec({ size: 'Standard_D2s_v6', sub: SUB_A }),
    rec({ size: 'Standard_D2s_v6', sub: SUB_B }),
  ]);
  eq(rows.length, 2, 'quota is per subscription');
});

test('a record without a family is never merged by size name', () => {
  const rows = page.capacityFamilyRows([
    rec({ size: 'Standard_D2s_v6', family: null, state: 'BLOCKED', blockReason: 'size-missing', limit: null }),
    rec({ wave: 'wave-2', size: 'Standard_D2s_v6', family: null, state: 'BLOCKED', blockReason: 'size-missing', limit: null }),
    rec({ size: 'Standard_D2s_v6' }),
  ]);
  eq(rows.length, 3, 'two records with no family and one with a family are three rows');
  eq(rows.filter(r => r.family === null).length, 2, 'each record with no family has its own row');
  const withFamily = rows.find(r => r.family);
  eq(withFamily.claims.length, 1, 'and the family row did not take them in because of the size name');

  const store = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6', family: '', limit: null })], null);
  ok(store['#cap-table tbody'].includes(esc(UX_CAP.familyUnknown)),
    'a record with an empty family says the family is not known');
});

/* ---- order ------------------------------------------------------------- */

test('a row with a problem sorts first', () => {
  const fine = rec({ size: 'Standard_A2_v6', family: 'aaaFamily' });
  const short = rec({ size: 'Standard_Z2_v6', family: 'zzzFamily', state: 'BLOCKED', blockReason: 'quota-shortfall' });
  eq(page.capacityFamilyRows([fine, short]).map(r => r.family), ['zzzFamily', 'aaaFamily'],
    'not enough quota comes before a row that is fine, whatever the names');

  const refused = rec({ size: 'Standard_Z2_v6', family: 'zzzFamily', state: 'BLOCKED', blockReason: 'reservation-failed' });
  // RES-LIST-1: a refused reservation is a fact of the Capacity reservations list.
  eq(page.capacityFamilyRows([fine, refused])[0].family, 'aaaFamily', 'capacity refused is not a quota problem');

  const unknown = rec({ size: 'Standard_Z2_v6', family: 'zzzFamily', limit: null });
  eq(page.capacityFamilyRows([fine, unknown])[0].family, 'zzzFamily', 'a quota that cannot be verified comes first');

  const noFamily = rec({ size: 'Standard_Z2_v6', family: null, state: 'BLOCKED', blockReason: 'size-missing', limit: null });
  eq(page.capacityFamilyRows([fine, noFamily])[0].family, null, 'a family that cannot be verified comes first');

  /* Found by mutation: every record above with no family was ALSO blocked or
   * unread, so a rule that forgot the family alone survived. A record whose
   * quota was read but whose family is empty still cannot say which
   * allowance it draws on. */
  ok(page.capacityFamilyRows([rec({ size: 'Standard_Z2_v6', state: 'QUOTA_REQUESTED' })])[0].problem,
    'an increase that Azure has not granted yet is still not enough quota');
  const asking = { ...rec({ size: 'Standard_Z2_v6', state: 'RESERVING' }), reservingSinceUtc: new Date().toISOString() };
  ok(!page.capacityFamilyRows([asking])[0].problem, 'a reservation Azure is still making is not a problem yet');
  ok(!page.capacityFamilyRows([{ ...asking, reservationUnconfirmedUtc: '2026-09-25T10:00:00Z' }])[0].problem,
    'a reservation Azure did not confirm is a problem of the Capacity reservations list, not of the quota');
  ok(!page.capacityFamilyRows([rec({ size: 'Standard_Z2_v6', state: 'RELEASED', limit: null })])[0].problem,
    'a released record is history, not a problem');

  // The flag itself: a row with no family sorts before every name anyway, so
  // the order alone cannot show it.
  const readButNoFamily = rec({ size: 'Standard_Z2_v6', family: '' });
  ok(page.capacityFamilyRows([readButNoFamily])[0].problem,
    'a missing family alone is a problem, whatever else the record says');

  eq(page.capacityFamilyRows([fine, rec({ size: 'Standard_Z2_v6', family: 'zzzFamily' })]).map(r => r.family),
    ['aaaFamily', 'zzzFamily'], 'with no problem, rows are in name order');

  const store = fakeTable();
  page.renderCapacity([fine, short], null);
  ok(/zzzFamily/.test(cells(rowsOf(store['#cap-table tbody'])[0])[0]), 'and the card draws it first');
});

test('one problem size makes the whole family row a problem', () => {
  const rows = page.capacityFamilyRows([
    rec({ size: 'Standard_D2s_v6' }),
    rec({ size: 'Standard_D4s_v6', state: 'BLOCKED', blockReason: 'sku-restricted' }),
  ]);
  ok(rows[0].problem, 'the row is a problem');
});

/* ---- RES-LIST-1: two lists ------------------------------------------------ */

/* Found 2026-11-11: the card held the quota, every reservation of the row
 * and the In use count in one table, pushed together and hard to read.
 * The card is two lists: Quota (one row for each quota family and
 * region) and Capacity reservations (one row for each wave and size). */
function resList(claims, plan) {
  const store = fakeTable();
  page.renderCapacity(claims, plan);
  const heads = headingsOf(store['#res-head'] ?? '');
  const rows = rowsOf(store['#res-table tbody'] ?? '').map(r => {
    const tds = cells(r);
    return { wave: tds[0], size: tds[1], state: tds[2], fact: tds[3], release: tds[4], all: r };
  });
  return { store, heads, rows };
}
const pillsIn = (td) => [...td.matchAll(/<span class="([^"]*)"[^>]*>([^<]*)<\/span>/g)].map(m => [m[1], m[2]]);
const plainOf = (html) => html.replace(/<[^>]+>/g, ' ').replace(/\s+/g, ' ').trim();

test('the Quota list holds no reservation data, whatever the waves hold', () => {
  const store = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6', state: 'RESERVED', reservation: { consumedInstances: 1 } }),
    rec({ size: 'Standard_D4s_v6', wave: 'wave-2' })], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'Reserved' } }] });
  eq(headingsOf(store['#cap-head']), [UX_CAP.colFamily, UX_CAP.colSizes, UX_CAP.colNeeded, UX_CAP.colFree, UX_CAP.colQuota]);
  const quota = store['#cap-table tbody'];
  ok(!quota.includes(`>${UX_MISC.reserved}`) && !quota.includes(UX_LEVER.capOnDemand) && !quota.includes(UX_MISC.notReserved), quota);
  ok(!/wave-1|wave-2/.test(quota), 'and names no wave: ' + quota);
  for (const r of rowsOf(quota)) { eq(cells(r).length, 5, 'every row is the shape of the heading'); }
});

test('the Capacity reservations list is hidden when no wave in view reserves', () => {
  const { store, rows } = resList([rec({ size: 'Standard_D2s_v6' })], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'BestEffort' } }] });
  eq(store.__styles['#res-section'].display, 'none', 'the section is hidden');
  eq(rows.length, 0, 'no rows');
});

test('it shows when a wave in view reserves: one row for each wave and size, in that order of columns', () => {
  const { heads, rows } = resList([
    rec({ wave: 'wave-2', size: 'Standard_D4s_v6', state: 'RESERVED', n: 2, reservation: { consumedInstances: 1 } }),
    rec({ wave: 'wave-1', size: 'Standard_D2s_v6' }),
    rec({ wave: 'wave-2', size: 'Standard_D2s_v6' }),
  ], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'BestEffort' } }, { wave: 'wave-2', policy: { capacityGate: 'Reserved' } }] });
  eq(heads, [UX_CAP.colWave, UX_CAP.colSize, UX_CAP.colState, UX_CAP.colFact, '']);
  eq(rows.map(r => `${plainOf(r.wave)}|${plainOf(r.size)}`), ['wave-2|Standard_D2s_v6', 'wave-2|Standard_D4s_v6'],
    'only the waves that use an on-demand capacity reservation - wave-1 is set to None and has no row');
  eq(pillsIn(rows[0].state).map(p => p[1]), [UX_MISC.notReserved], 'a wave set to reserve with nothing held says Not reserved');
  eq(pillsIn(rows[1].state).map(p => p[1]), [`${UX_MISC.reserved} 2`]);
  eq(plainOf(rows[1].fact), UX_MISC.reservedCounts.replace('{used}', '1').replace('{idle}', '1'), 'one in use, one idle, in the shortest form');
});

test('the size names its zone, and its region when the card holds more than one region', () => {
  const { rows } = resList([rec({ size: 'Standard_D2s_v6', zone: '2', state: 'RESERVED', reservation: { consumedInstances: 0 } }),
    rec({ size: 'Standard_D2s_v6', region: 'eastus2', state: 'RESERVED', reservation: { consumedInstances: 0 } })], null);
  const sizes = rows.map(r => plainOf(r.size)).sort();
  eq(sizes, [UX_CAP.sizeInRegion.replace('{size}', UX_CAP.sizeInZone.replace('{size}', 'Standard_D2s_v6').replace('{zone}', '2')).replace('{region}', 'centralus'),
    UX_CAP.sizeInRegion.replace('{size}', 'Standard_D2s_v6').replace('{region}', 'eastus2')].sort());
});

test('a reservation Azure refused is said in the Capacity reservations list, and the Quota list keeps the quota reading', () => {
  const refused = rec({ size: 'Standard_D2s_v6', state: 'BLOCKED', blockReason: 'reservation-failed', used: 10, limit: 100 });
  const { store, rows } = resList([refused], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'Reserved' } }] });
  eq(pillsIn(rows[0].state).map(p => p[1]), [UX_MISC.quotaReservationFailed]);
  ok(!store['#cap-table tbody'].includes(UX_MISC.quotaReservationFailed), 'not in the Quota list');
  ok(store['#cap-table tbody'].includes(UX_MISC.quotaOk) && store['#cap-table tbody'].includes('10/100'), 'which says the quota reading');
  ok(!page.capacityFamilyRows([refused])[0].problem, 'and the quota row is not a problem for it');
});

test('a reservation row with a problem sorts first: one nobody confirmed, or one Azure refused', () => {
  const stuck = { ...rec({ wave: 'wave-9', size: 'Standard_D2s_v6', state: 'RESERVING' }), reservingSinceUtc: new Date().toISOString(), reservationUnconfirmedUtc: new Date().toISOString() };
  const making = { ...rec({ wave: 'wave-0', size: 'Standard_D2s_v6', state: 'RESERVING' }), reservingSinceUtc: new Date().toISOString() };
  const refused = rec({ wave: 'wave-8', size: 'Standard_D2s_v6', state: 'BLOCKED', blockReason: 'reservation-failed' });
  const held = rec({ wave: 'wave-1', size: 'Standard_D2s_v6', state: 'RESERVED', reservation: { consumedInstances: 0 } });
  const { rows } = resList([held, making, refused, stuck], null);
  eq(rows.map(r => plainOf(r.wave)), ['wave-8', 'wave-9', 'wave-0', 'wave-1']);
  ok(!page.capacityFamilyRows([stuck])[0].problem, 'and neither makes the quota row a problem');
});

test('a wave the plan does not show, and a wave set to None, have no row', () => {
  const { rows } = resList([rec({ wave: 'wave-9', size: 'Standard_D2s_v6' }), rec({ wave: 'wave-1', size: 'Standard_D2s_v6' }),
    rec({ wave: 'wave-2', size: 'Standard_D2s_v6', state: 'RESERVED', reservation: { consumedInstances: 0 } })],
  { entries: [{ wave: 'wave-2', policy: { capacityGate: 'Reserved' } }, { wave: 'wave-1', policy: { capacityGate: 'BestEffort' } }] });
  eq(rows.map(r => plainOf(r.wave)), ['wave-2']);
  ok(!rows.some(r => r.state.includes(`>${UX_LEVER.capOnDemand}<`)), 'no None row');
});

test('a reservation that bills is never hidden, also in a wave the plan sets to None', () => {
  const { rows } = resList([rec({ wave: 'wave-1', size: 'Standard_D2s_v6', state: 'RESERVED', reservation: { consumedInstances: 0 } })],
    { entries: [{ wave: 'wave-1', policy: { capacityGate: 'BestEffort' } }] });
  eq(rows.length, 1);
});

test('the card is called Quota with no on-demand capacity reservation in view, and names both with one', () => {
  const plain = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6' })], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'BestEffort' } }] });
  const t = (store, id) => store.__els[id] ?? {};
  eq(t(plain, '#cap-title').textContent, 'Quota');
  eq(t(plain, '#cap-hint').textContent, UX_CAP.hintQuota);
  eq(plain.__styles['#cap-quota-sub'].display, 'none', 'no Quota sub-heading under a card called Quota');
  ok(!/on-demand capacity reservation/i.test(UX_CAP.hintQuota), 'and its sentence does not name one');
  const both = fakeTable();
  page.renderCapacity([rec({ size: 'Standard_D2s_v6' })], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'Reserved' } }] });
  eq(t(both, '#cap-title').textContent, 'Quota and on-demand capacity reservations');
  ok(t(both, '#cap-hint').textContent.includes('An on-demand capacity reservation holds hardware for you.'), t(both, '#cap-hint').textContent);
  eq(t(both, '#res-title').textContent, 'On-demand capacity reservations');
  eq(both.__styles['#cap-quota-sub'].display, '');
  ok(!Object.values(UX_CAP).concat(Object.values(UX_MISC)).some(v => /\bODCR\b/.test(String(v))), 'never ODCR on screen');
});
test('the card never says availability set, in any row or hover', () => {
  const r = rec({ size: 'Standard_D2s_v6', n: 3, state: 'RESERVED', reservation: { consumedInstances: 0 } });
  r.demand.reservableInstances = 1;
  const none = rec({ wave: 'wave-2', size: 'Standard_D4s_v6', n: 2 });
  none.demand.reservableInstances = 0;
  const { store } = resList([r, none], { entries: [{ wave: 'wave-1', policy: { capacityGate: 'Reserved' } }, { wave: 'wave-2', policy: { capacityGate: 'Reserved' } }] });
  const all = Object.values(store).join(' ');
  ok(!/availability set/i.test(all), all);
});

test('each fact is one short sentence or nothing', () => {
  const facts = [
    page.reservationFact(rec({ size: 'Standard_D2s_v6', state: 'RELEASED', reservation: { consumedInstances: 2 } })),
    page.reservationFact({ ...rec({ size: 'Standard_D2s_v6', state: 'RESERVING' }), reservationUnconfirmedUtc: new Date().toISOString() }),
  ];
  eq(facts[0], UX_MISC.servedNote.replace('{n}', '2'));
  eq(facts[1], 'Azure did not confirm it. It can still bill.', 'the exact approved words');
  for (const f of facts) { ok(/^[A-Z0-9]/.test(f) && /\.$/.test(f), f); }
  eq(page.reservationFact(rec({ size: 'Standard_D2s_v6', state: 'RELEASED' })), '', 'a release nothing used says nothing');
});
/* ---- what a row says --------------------------------------------------- */

test('a size-level block sits beside its SIZE, not on the family quota', () => {
  /* "This size is restricted here" in a row of three sizes names no size. */
  const store = fakeTable();
  page.renderCapacity([
    rec({ size: 'Standard_D2s_v6' }),
    rec({ size: 'Standard_D4s_v6', state: 'BLOCKED', blockReason: 'sku-restricted' }),
  ], null);
  const heads = headingsOf(store['#cap-head']);
  const tds = cells(rowsOf(store['#cap-table tbody'])[0]);
  const sizes = tds[heads.indexOf(UX_CAP.colSizes)];
  ok(/Standard_D4s_v6[^,]*restricted/.test(sizes), `the restricted size carries the pill, got: ${sizes}`);
  ok(!/restricted/.test(tds[heads.indexOf(UX_CAP.colQuota)]), 'and the family quota does not');
});

test('needed, free and the Quota cell are ONE check side by side', () => {
  /* The review: two free figures and two needed figures with no time on
   * either could not be paired. Both come from the newest check now.
   * QUOTA-ROW-TWICE-1: and so does the Quota cell. The older reading stayed
   * in it with its own time, and "2/20" beside "0/20" for one family read
   * as the same quota shown twice. */
  const older = rec({ wave: 'wave-1', size: 'Standard_D2s_v6', used: 0, limit: 10, total: 10, at: '2026-09-25T10:00:00Z' });
  const newer = rec({ wave: 'wave-2', size: 'Standard_D2s_v6', used: 4, limit: 10, total: 6, at: '2026-09-25T11:00:00Z' });
  const rows = page.capacityFamilyRows([older, newer]);
  eq([rows[0].neededVcpus, rows[0].freeVcpus], [6, 6], 'the newest check: 6 needed, 10 - 4 free');
  const store = fakeTable();
  globalThis.ago = (iso) => `at ${iso}`;
  try {
    page.renderCapacity([older, newer], null);
  } finally { globalThis.ago = () => 'a moment ago'; }
  const heads = headingsOf(store['#cap-head']);
  const quota = cells(rowsOf(store['#cap-table tbody'])[0])[heads.indexOf(UX_CAP.colQuota)];
  ok(/4\/10[\s\S]*11:00/.test(quota), `the newest reading, with its time, got: ${quota}`);
  ok(!/0\/10/.test(quota) && !/10:00/.test(quota), `and not the older one, got: ${quota}`);
  const none = page.capacityFamilyRows([rec({ size: 'Standard_D2s_v6', limit: null })]);
  eq(none[0].freeVcpus, null, 'a reading that was not taken gives no number, never zero');
});

test('the reading-a-run row spans the heading the page built', () => {
  const body = liftAll('migrations.html', ['readingRegions']);
  fakeTable();
  globalThis.$ = (sel) => (sel === '#cap-head' ? { children: { length: 8 } } : null);
  eq(body.readingRegions().find(r => r.sel === '#cap-table tbody').cols, 8, 'read from the header');
});

run('quota family');
