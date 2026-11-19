/* QUOTA-ROW-TWICE-1: one quota family in one region shows ONE quota reading.
 *
 * Found 2026-11-08 on the lab install, a 1.0 defect: the same size showed its
 * quota twice. A run of three waves: wave-2 and wave-3 on
 * D2ds_v5. While wave-3 ran, its row said "Headroom verified 2/20 checked 42s
 * ago" AND "Headroom verified 0/20 checked 17m ago". The plan operation
 * checked every wave; the start of wave-3 checked only wave-3 and rewrote its
 * record, so wave-2's record kept the reading from planning. Both are
 * readings of ONE quantity - the family's usage in the region - and the newer
 * one replaces the older one. The engine already reads it so:
 * Request-VmfQuota sizes a request from "the reading of the newest check".
 *
 * Every check RUNS the page's own functions with the page's own pills.
 */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { test, ok, eq, run, lift, liftAll, liftConst } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_CAP = liftConst('migrations.html', 'UX_CAP');
globalThis.UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
globalThis.BLOCK_TEXT = liftConst('migrations.html', 'BLOCK_TEXT');
globalThis.RESERVING_STUCK_MINUTES = 60;
globalThis.VmfHelp = {
  claimBlocked: lift('help.js', 'claimBlocked'),
  claimReservingStuck: lift('help.js', 'claimReservingStuck'),
  claimRegionalShort: lift('help.js', 'claimRegionalShort'),
  claimRegionalRequested: lift('help.js', 'claimRegionalRequested'),
};
// The help.js twins call claimBlocked by its bare name, as inside help.js.
globalThis.claimBlocked = VmfHelp.claimBlocked;
globalThis.esc = (v) => String(v == null ? '' : v)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
// The time each pill says, so a test can tell the two readings apart.
globalThis.ago = (iso) => `at ${iso}`;
globalThis.waveLabel = (w) => w || 'Not moved';

const page = liftAll('migrations.html', [
  'quotaFacet', 'reservationFacet', 'mergeFacets', 'quotaFacetsOf', 'regionalFacet', 'capacityRegionalRows',
  'capacityRowProblem', 'quotaBlockedHere', 'quotaListFacet', 'reservationFact', 'reservationProblem', 'reservationBills', 'claimUsesReservation', 'capacityFamilyRows', 'capacityGateOf', 'renderCapacity',
  'claimSizeBlocked', 'newestCheckOf',
]);
globalThis.mergeFacets = page.mergeFacets;

function fakeTable() {
  const store = {};
  const el = (id) => ({
    set innerHTML(v) { store[id] = v; },
    get innerHTML() { return store[id] ?? ''; },
    insertAdjacentHTML(_, v) { store[id] = (store[id] ?? '') + v; },
    style: {},
    querySelectorAll: () => [],
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
const pillsOf = (td) => [...td.matchAll(/<span class="pill [^"]*"[^>]*>([^<]*)<\/span>/g)].map(m => m[1]);

/* The table as the card draws it: one object per row, keyed by heading. */
function drawn(claims, plan = null) {
  const store = fakeTable();
  page.renderCapacity(claims, plan);
  const heads = headingsOf(store['#cap-head']);
  return rowsOf(store['#cap-table tbody']).map(r => {
    const tds = cells(r);
    return Object.fromEntries(heads.map((h, i) => [h, tds[i]]));
  });
}

const SUB = '00000000-0000-0000-0000-000000000000';
const T_PLAN = '2026-11-08T10:00:00.0000000Z';    // the plan operation's check: every wave
const T_START = '2026-11-08T10:16:18.0000000Z';   // the start of wave-3: that wave only
/* Records shaped as Test-VmfQuota writes them (schemas/capacity-claim). */
const rec = (o) => ({
  schemaVersion: 15, runId: 'r1', wave: o.wave ?? 'wave-1', subscriptionId: SUB,
  resourceGroup: 'rg-app', region: o.region ?? 'centralus', zone: o.zone ?? null,
  size: o.size ?? 'Standard_D2ds_v5', vmFamily: o.family ?? 'standardDDSv5Family',
  state: o.state ?? 'QUOTA_VERIFIED', blockReason: o.blockReason ?? null,
  regionalShort: o.regionalShort ?? null,
  demand: { instances: 1, reservableInstances: 1, vcpus: 2, familyVcpus: o.total ?? 2, regionalVcpus: o.regional ?? 0 },
  quota: { limit: o.limit === undefined ? 20 : o.limit, used: o.used ?? 0, checkedUtc: o.at ?? null,
    regionalLimit: o.rLimit === undefined ? 1000 : o.rLimit, regionalUsed: o.rUsed ?? 0 },
  ...(o.reservation ? { reservation: o.reservation } : {}),
});

/* ---- the row from the lab ------------------------------------------------ */

test('THE DEFECT: two waves of one size checked at two times show ONE reading, the newest', () => {
  const wave2 = rec({ wave: 'wave-2', used: 0, total: 4, at: T_PLAN });
  const wave3 = rec({ wave: 'wave-3', used: 2, total: 2, at: T_START });
  const rows = drawn([wave2, wave3]);
  eq(rows.length, 2, 'one family in one region is one row, and the Total Regional vCPUs row follows it');
  const row = rows[0];
  const quota = row[UX_CAP.colQuota];
  eq(pillsOf(quota), [UX_MISC.quotaOk], `ONE pill, got: ${quota}`);
  ok(quota.includes('2/20') && quota.includes(T_START), `the newest reading, with its time, got: ${quota}`);
  ok(!quota.includes('0/20') && !quota.includes(T_PLAN), `and never the older reading, got: ${quota}`);
  eq(row[UX_CAP.colNeeded].trim(), '2', 'vCPUs needed from the same check as the pill');
  eq(row[UX_CAP.colFree].trim(), '18', 'vCPUs free from the same check: 20 - 2');
  // RES-LIST-1: the Quota list names no wave; the waves are in the Capacity reservations list.
  // The order the records arrive in does not choose the reading.
  const reversed = drawn([wave3, wave2])[0][UX_CAP.colQuota];
  eq(reversed, quota, 'the same cell whichever record the store gives first');
});

/* ---- a block and a pass: the newest check wins, both ways ---------------- */

test('a newer BLOCK replaces an older pass: a stale pass never hides it', () => {
  const pass = rec({ wave: 'wave-2', used: 0, at: T_PLAN });
  const block = rec({ wave: 'wave-3', used: 19, total: 2, at: T_START, state: 'BLOCKED', blockReason: 'quota-shortfall' });
  const row = drawn([pass, block])[0];
  eq(pillsOf(row[UX_CAP.colQuota]), [UX_MISC.quotaShort], `only the block, got: ${row[UX_CAP.colQuota]}`);
  eq(row[UX_CAP.colFree].trim(), '1', 'and free is the blocking check\'s figure');
  ok(page.capacityFamilyRows([pass, block])[0].problem, 'the row is a problem');
});

test('a newer PASS replaces an older block: the newer check judged the whole family', () => {
  /* Every quota check totals the family over EVERY wave of the plan
   * (QUOTA-BUTTON-1), so the newer check already judged the older block's
   * machines - after an increase that Azure granted, for example. */
  const block = rec({ wave: 'wave-2', used: 19, total: 4, at: T_PLAN, state: 'BLOCKED', blockReason: 'quota-shortfall' });
  const pass = rec({ wave: 'wave-3', used: 0, limit: 40, total: 4, at: T_START });
  const row = drawn([block, pass])[0];
  eq(pillsOf(row[UX_CAP.colQuota]), [UX_MISC.quotaOk], `only the newer pass, got: ${row[UX_CAP.colQuota]}`);
  ok(!page.capacityFamilyRows([block, pass])[0].problem, 'and the row is not a problem any more');
  // An increase requested, then a check that found it still short.
  const asked = rec({ wave: 'wave-2', at: T_PLAN, state: 'QUOTA_REQUESTED' });
  const still = rec({ wave: 'wave-3', used: 19, at: T_START, state: 'BLOCKED', blockReason: 'quota-shortfall' });
  eq(pillsOf(drawn([asked, still])[0][UX_CAP.colQuota]), [UX_MISC.quotaShort], 'the newer check speaks');
  eq(pillsOf(drawn([still, { ...asked, quota: { ...asked.quota, checkedUtc: '2026-11-08T11:00:00Z' } }])[0][UX_CAP.colQuota]),
    [UX_MISC.quotaReq], 'and a newer request speaks over an older block');
});

test('vCPUs free says what the pill says: a newest reading that was not taken gives no number', () => {
  /* The newest check could not read the family (the s-suffix listing gap).
   * Free came from the newest record WITH figures, so it showed the old
   * figure beside a pill that says the quota is not known. */
  const read = rec({ wave: 'wave-2', used: 4, at: T_PLAN });
  const notRead = rec({ wave: 'wave-3', limit: null, at: T_START });
  const row = drawn([read, notRead])[0];
  eq(pillsOf(row[UX_CAP.colQuota]), [UX_MISC.quotaUnknown], `the newest says not known, got: ${row[UX_CAP.colQuota]}`);
  eq(row[UX_CAP.colFree].trim(), '-', 'and free is not known either, never 16 from the older check');
  ok(page.capacityFamilyRows([read, notRead])[0].problem, 'a quota that cannot be verified is a problem');
  const r = page.capacityFamilyRows([read, notRead])[0];
  eq(r.neededVcpus, 2, 'needed from the same check');
});

/* ---- one check, several records ------------------------------------------ */

test('one check of several sizes is ONE reading, and an older check of another size is not shown', () => {
  /* Test-VmfQuota stamps one checkedUtc on every record of one call, so the
   * records of the newest check are known as one. */
  const old = rec({ wave: 'wave-1', size: 'Standard_D4ds_v5', used: 0, total: 6, at: T_PLAN });
  const a = rec({ wave: 'wave-3', size: 'Standard_D2ds_v5', used: 2, total: 4, at: T_START });
  const b = rec({ wave: 'wave-3', size: 'Standard_D2ds_v5', zone: '2', used: 2, total: 4, at: T_START });
  const row = drawn([old, a, b])[0];
  eq(pillsOf(row[UX_CAP.colQuota]), [UX_MISC.quotaOk], `one pill for the one check, got: ${row[UX_CAP.colQuota]}`);
  ok(row[UX_CAP.colQuota].includes('2/20') && !row[UX_CAP.colQuota].includes('0/20'), 'the newest figures only');
  ok(/Standard_D4ds_v5/.test(row[UX_CAP.colSizes]), 'every size of the family stays in the row');
  eq(row[UX_CAP.colNeeded].trim(), '4', 'needed from the newest check');
  // The one rule, said directly.
  eq(page.newestCheckOf([old, a, b]), [a, b], 'the records of the newest check, in the order given');
  eq(page.newestCheckOf([]), [], 'no records, no check');
});

test('in one check, records that differ in what they say all stay', () => {
  /* One check can judge two records of a family differently: the one whose
   * machines add vCPUs is short of the Total Regional vCPUs, the other is not.
   * That is not two readings - both are true of the newest check. */
  const adds = rec({ wave: 'wave-3', size: 'Standard_D4ds_v5', at: T_START, state: 'BLOCKED', blockReason: 'regional-quota-shortfall' });
  const addsNone = rec({ wave: 'wave-3', size: 'Standard_D2ds_v5', at: T_START });
  const pills = pillsOf(drawn([adds, addsNone])[0][UX_CAP.colQuota]);
  ok(pills.includes(UX_MISC.quotaRegionalShort) && pills.includes(UX_MISC.quotaOk), `both, got: ${pills}`);
  ok(page.capacityFamilyRows([adds, addsNone])[0].problem, 'and the row is a problem');
});

/* ---- facts that are not a reading of the quota ---------------------------- */

test('RES-LIST-1: a capacity reservation that Azure refused is NOT in the Quota cell: the cell is the newest reading', () => {
  /* Reserve writes reservation-failed on the wave's own record. It is a fact
   * about that wave's reservation, so the Capacity reservations list says it
   * (quota-family.test.js), and the Quota list keeps the quota reading. */
  const refused = rec({ wave: 'wave-2', at: T_PLAN, state: 'BLOCKED', blockReason: 'reservation-failed' });
  const pass = rec({ wave: 'wave-3', used: 2, at: T_START });
  const row = drawn([refused, pass])[0];
  eq(pillsOf(row[UX_CAP.colQuota]), [UX_MISC.quotaOk], `only the newest reading, got: ${row[UX_CAP.colQuota]}`);
  ok(row[UX_CAP.colQuota].includes('2/20'), 'its figures');
  eq(row[UX_CAP.colFree].trim(), '18', 'free from the newest reading');
  ok(!page.capacityFamilyRows([refused, pass])[0].problem, 'and the quota row is not a problem for it');
  // A refusal on the newest record shows its quota reading.
  const newestRefused = { ...refused, quota: { ...refused.quota, checkedUtc: '2026-11-08T11:00:00Z' } };
  eq(pillsOf(drawn([newestRefused, pass])[0][UX_CAP.colQuota]), [UX_MISC.quotaOk], 'the reading of the refused record');
});
test('a size that is restricted stays beside its size, and a row of only such sizes keeps its total', () => {
  const restricted = rec({ size: 'Standard_D4ds_v5', at: T_START, state: 'BLOCKED', blockReason: 'sku-restricted', limit: null, total: 6 });
  const older = rec({ size: 'Standard_D2ds_v5', used: 2, at: T_PLAN, total: 4 });
  const row = drawn([restricted, older])[0];
  ok(/Standard_D4ds_v5[^,]*restricted/i.test(row[UX_CAP.colSizes]), `beside the size, got: ${row[UX_CAP.colSizes]}`);
  ok(row[UX_CAP.colQuota].includes('2/20'), `the quota reading is the newest record that reads the quota, got: ${row[UX_CAP.colQuota]}`);
  eq(row[UX_CAP.colNeeded].trim(), '4', 'and needed from that same record');
  ok(page.capacityFamilyRows([restricted, older])[0].problem, 'a restricted size makes the row a problem');
  const only = page.capacityFamilyRows([restricted])[0];
  eq(only.neededVcpus, 6, 'a row of only restricted sizes still shows the family total it carries');
  eq(only.freeVcpus, null, 'and no free figure, which it never read');
  eq(drawn([restricted])[0][UX_CAP.colQuota], '-', 'and its Quota cell shows no reading');
});

/* ---- the Total Regional vCPUs row ---------------------------------------- */

test('the Total Regional vCPUs row shows ONE reading too, the newest', () => {
  const plan = rec({ wave: 'wave-2', at: T_PLAN, regional: 4, rLimit: 40, rUsed: 10 });
  const start = rec({ wave: 'wave-3', at: T_START, regional: 2, rLimit: 40, rUsed: 12 });
  const rows = page.capacityRegionalRows([plan, start]);
  eq([rows[0].neededVcpus, rows[0].freeVcpus], [2, 28], 'needed and free from the newest check');
  const store = fakeTable();
  page.renderCapacity([plan, start], null);
  const regional = rowsOf(store['#cap-table tbody']).find(r => r.includes(UX_CAP.regionalName));
  const quota = cells(regional)[headingsOf(store['#cap-head']).indexOf(UX_CAP.colQuota)];
  eq(pillsOf(quota), [UX_MISC.quotaOk], `one pill, got: ${quota}`);
  ok(quota.includes('12/40') && !quota.includes('10/40'), `the newest reading only, got: ${quota}`);
});

test('on the regional row, a newer pass replaces an older shortfall, and a newer shortfall an older pass', () => {
  const short = rec({ wave: 'wave-2', at: T_PLAN, regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'regional-quota-shortfall', regionalShort: true });
  const fits = rec({ wave: 'wave-3', at: T_START, regional: 2, rLimit: 40, rUsed: 8, regionalShort: false });
  ok(!page.capacityRegionalRows([short, fits])[0].problem, 'the newer check fits: not a problem');
  const laterShort = { ...short, quota: { ...short.quota, checkedUtc: '2026-11-08T11:00:00Z' } };
  ok(page.capacityRegionalRows([laterShort, fits])[0].problem, 'the newer check is short: a problem');
  eq(page.capacityRegionalRows([laterShort, fits])[0].freeVcpus, 2, 'and free is its figure');
});

run('quota row twice');
