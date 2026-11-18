/* REGIONAL-VCPU-QUOTA-1: the Total Regional vCPUs quota on the pages that show
 * quota results.
 *
 * Azure holds a quota for all vCPUs of a subscription in a region, beside each
 * size family's. Test-VmfQuota now judges it, records it (capacity-claim v11:
 * demand.regionalVcpus, quota.regionalLimit and quota.regionalUsed), and blocks
 * a record with 'regional-quota-shortfall' when the machines add more vCPUs
 * than the region has free.
 *
 * The pages show what the engine decided. They never add up the records and
 * never judge the figures a second time.
 *
 * RUN, not read: the pages' own functions, with the page's own words.
 */
'use strict';
// QUOTA-CHECK-SPINNER-1: loadClaims counts its reads, so only the newest fills the page.
globalThis.claimsTurn = 0;
const { test, ok, eq, run, lift, liftAll, liftConst } = require('./_harness');

globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_CAP = liftConst('migrations.html', 'UX_CAP');
globalThis.BLOCK_TEXT = liftConst('migrations.html', 'BLOCK_TEXT');
globalThis.RESERVING_STUCK_MINUTES = 60;
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
globalThis.VmfHelp = {
  claimBlocked: globalThis.claimBlocked,
  claimReservingStuck: lift('help.js', 'claimReservingStuck'),
  claimRegionalShort: lift('help.js', 'claimRegionalShort'),
  // REGIONAL-QUOTA-REQUESTED-PAGE-1. Lifted so that its absence fails its own
  // tests, not every test of the file.
  claimRegionalRequested: (() => {
    try { return lift('help.js', 'claimRegionalRequested'); }
    catch { return () => { throw new Error('help.js has no claimRegionalRequested'); }; }
  })(),
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
globalThis.facetsOf = (claims, facet) => page.mergeFacets(claims.map(facet));

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

const SUB_A = '00000000-0000-0000-0000-000000000000';
/* A record as Test-VmfQuota writes it, v11. */
const rec = (o) => ({
  schemaVersion: 11, runId: 'r1', wave: o.wave ?? 'wave-1', subscriptionId: o.sub ?? SUB_A,
  resourceGroup: 'rg-app', region: o.region ?? 'centralus', zone: null,
  size: o.size ?? 'Standard_D4s_v6', vmFamily: o.family ?? 'standardDSv6Family',
  state: o.state ?? 'QUOTA_VERIFIED', blockReason: o.blockReason ?? null,
  demand: { instances: 1, reservableInstances: 1, vcpus: 4, familyVcpus: 4,
    ...(o.regional === undefined ? {} : { regionalVcpus: o.regional }) },
  quota: { limit: 100, used: 0, checkedUtc: o.at ?? null,
    ...(o.rLimit === undefined ? {} : { regionalLimit: o.rLimit, regionalUsed: o.rUsed ?? 0 }) },
});

test('the migration page: a record blocked on the regional quota says so, in its own words', () => {
  const pill = page.quotaFacet(rec({ state: 'BLOCKED', blockReason: 'regional-quota-shortfall' }));
  ok(pill.includes(esc(UX_MISC.quotaRegionalShort)), `got: ${pill}`);
  ok(!pill.includes(esc(UX_MISC.quotaShort) + '<'), 'not the words of a family shortfall');
  ok(/Total Regional vCPUs/.test(UX_MISC.quotaRegionalShort), 'Azure\'s own name for the quota');
  ok(!/capacity/i.test(UX_MISC.quotaRegionalShort), 'a quota, never capacity');
});

test('the migration page: one Total Regional vCPUs row for each subscription and region, with the engine\'s numbers', () => {
  const rows = page.capacityRegionalRows([
    rec({ size: 'Standard_D4s_v6', regional: 6, rLimit: 10, rUsed: 8, at: '2026-10-19T10:00:00Z' }),
    rec({ size: 'Standard_D8s_v6', family: 'standardDDSv6Family', regional: 6, rLimit: 10, rUsed: 8, at: '2026-10-19T10:00:00Z' }),
    rec({ region: 'eastus2', regional: 2, rLimit: 50, rUsed: 0 }),
  ]);
  eq(rows.length, 2, 'two families in one region are ONE regional row; another region is its own');
  const central = rows.find(r => r.region === 'centralus');
  eq(central.neededVcpus, 6, 'vCPUs needed is the number the engine judged - not 6 + 6');
  eq(central.freeVcpus, 2, 'vCPUs free is the regional limit minus the regional vCPUs in use');
  eq(central.sizes, ['Standard_D4s_v6', 'Standard_D8s_v6'], 'and the row names the sizes');
});

test('MIGRATIONS-PAGE-OLD-READERS-1: every record draws its regional row - Test-VmfQuota always writes demand.regionalVcpus', () => {
  // Not a record of this version: it still has its row, with no number guessed.
  const rows = page.capacityRegionalRows([rec({})]);
  eq(rows.length, 1, 'no record is skipped for an old shape');
  eq(rows[0].neededVcpus, null, 'and no number is made up');
});

test('the migration page: the newest check gives the number, never a sum of records', () => {
  const rows = page.capacityRegionalRows([
    rec({ wave: 'wave-0', regional: 12, rLimit: 20, rUsed: 0, at: '2026-10-19T09:00:00Z' }),
    rec({ wave: 'wave-1', regional: 4, rLimit: 20, rUsed: 8, at: '2026-10-19T10:00:00Z' }),
  ]);
  eq([rows[0].neededVcpus, rows[0].freeVcpus], [4, 12], 'the newest record: 4 needed, 20 - 8 free');
});

test('the migration page: a RELEASED record is history - a live record gives the numbers', () => {
  const rows = page.capacityRegionalRows([
    rec({ wave: 'wave-0', state: 'RELEASED', regional: 12, rLimit: 20, rUsed: 0, at: '2026-10-19T11:00:00Z' }),
    rec({ wave: 'wave-1', regional: 4, rLimit: 20, rUsed: 8, at: '2026-10-19T10:00:00Z' }),
  ]);
  eq([rows[0].neededVcpus, rows[0].freeVcpus], [4, 12], 'the live record, though the released one is newer');
  const onlyReleased = page.capacityRegionalRows([rec({ state: 'RELEASED', regional: 12, rLimit: 20, rUsed: 0 })]);
  eq([onlyReleased[0].neededVcpus, onlyReleased[0].freeVcpus], [12, 20], 'with no live record, the released one still shows');
});
test('the migration page: a regional row is a problem when the engine blocked a record on it, or Azure did not report it', () => {
  ok(page.capacityRegionalRows([rec({ regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'regional-quota-shortfall' })])[0].problem,
    'blocked on the regional quota');
  ok(!page.capacityRegionalRows([rec({ regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'quota-shortfall' })])[0].problem,
    'a FAMILY shortfall is the family row\'s problem, not this one');
  ok(page.capacityRegionalRows([rec({ regional: 6, rLimit: null })])[0].problem,
    'a regional quota Azure did not report cannot be verified');
  ok(!page.capacityRegionalRows([rec({ regional: 6, rLimit: 10, rUsed: 0 })])[0].problem, 'a regional quota that fits is fine');
  ok(!page.capacityRegionalRows([rec({ regional: 6, rLimit: null, state: 'RELEASED' })])[0].problem, 'a released record is history');
});

test('the migration page: the card draws the regional row - first when it is short, after the families when it fits', () => {
  const short = fakeTable();
  page.renderCapacity([
    rec({ family: 'aaaFamily', regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'regional-quota-shortfall' }),
  ], null);
  const heads = headingsOf(short['#cap-head']);
  const drawn = rowsOf(short['#cap-table tbody']);
  eq(drawn.length, 2, 'the family row and the regional row');
  const first = cells(drawn[0]);
  ok(first[0].includes(esc(UX_CAP.regionalName)), `the short regional row comes first, got: ${first[0]}`);
  eq(first[heads.indexOf(UX_CAP.colNeeded)].trim(), '6');
  eq(first[heads.indexOf(UX_CAP.colFree)].trim(), '2');
  ok(first[heads.indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaRegionalShort)), 'with the pill that says why');
  for (const r of drawn) { eq(cells(r).length, heads.length, 'every row is the shape of the heading'); }

  const fine = fakeTable();
  page.renderCapacity([rec({ family: 'zzzFamily', regional: 2, rLimit: 10, rUsed: 0 })], null);
  const rowsFine = rowsOf(fine['#cap-table tbody']);
  ok(cells(rowsFine[1])[0].includes(esc(UX_CAP.regionalName)), 'a regional row that fits comes after the families');
  ok(/0\/10/.test(cells(rowsFine[1])[headingsOf(fine['#cap-head']).indexOf(UX_CAP.colQuota)]), 'and shows its reading, used of limit');
});

test('the migration page: with a reservation in view, the regional row keeps the shape of the Quota heading', () => {
  const store = fakeTable();
  page.renderCapacity([rec({ regional: 2, rLimit: 10, rUsed: 0, state: 'RESERVED' })], null);
  const heads = headingsOf(store['#cap-head']);
  eq(heads.length, 5, 'RES-LIST-1: the Quota list has its five columns only');
  for (const r of rowsOf(store['#cap-table tbody'])) { eq(cells(r).length, heads.length); }
});

/* REGIONAL-QUOTA-BOTH-PAGE-1: a record blocked on its FAMILY keeps
 * 'quota-shortfall', and the quota check records beside it whether the region
 * is short for the same machines (regionalShort, capacity-claim v14). Request
 * an increase asks for both. The card showed the regional row as enough, after
 * the families, when every short record of the region was short on its family
 * too. One rule says whether a record is short of the region - help.js
 * claimRegionalShort, twin of the engine's Test-VmfClaimRegionalShort - and
 * both are held to tests/fixtures/regional-short.json. */
const fs = require('fs');
const path = require('path');
const SHORT_CASES = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'regional-short.json'), 'utf8')).cases;
const v14 = (o, regionalShort) => ({ ...rec(o), schemaVersion: 14, regionalShort,
  demand: { ...rec(o).demand, regionalAdds: rec(o).demand.regionalVcpus ?? 0 } });

test('RUN: every shared case gives the answer the engine gives', () => {
  ok(SHORT_CASES.length >= 12, 'the fixture loaded');
  for (const c of SHORT_CASES) {
    eq(VmfHelp.claimRegionalShort(c.claim), c.short, `${JSON.stringify(c.claim)} - ${c.why}`);
  }
});

test('the migration page: a record short on its family AND the region makes the regional row a problem', () => {
  const both = page.capacityRegionalRows([
    v14({ regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'quota-shortfall' }, true)]);
  ok(both[0].problem, 'the engine found the region short beside the family');
  const room = page.capacityRegionalRows([
    v14({ regional: 2, rLimit: 100, rUsed: 0, state: 'BLOCKED', blockReason: 'quota-shortfall' }, false)]);
  ok(!room[0].problem, 'the engine found room in the region: the family row has the problem, not this one');
  const released = page.capacityRegionalRows([
    v14({ regional: 6, rLimit: 10, rUsed: 8, state: 'RELEASED', blockReason: 'quota-shortfall' }, true),
    v14({ wave: 'wave-2', regional: 6, rLimit: 10, rUsed: 8 }, false)]);
  ok(!released[0].problem, 'a released record is history');
});

test('the migration page: the regional pill says the quota is not enough for such a record, and enough when the region has room', () => {
  const short = page.regionalFacet(v14({ regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'quota-shortfall' }, true));
  ok(short.includes(esc(UX_MISC.quotaRegionalShort)) && /pill bad/.test(short), `got: ${short}`);
  ok(!short.includes(esc(UX_MISC.quotaOk) + '<'), 'never the words that say it is enough');
  const room = page.regionalFacet(v14({ regional: 2, rLimit: 100, rUsed: 0, state: 'BLOCKED', blockReason: 'quota-shortfall' }, false));
  ok(room.includes(esc(UX_MISC.quotaOk)) && /pill good/.test(room), `got: ${room}`);
  const old = page.regionalFacet(rec({ regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'quota-shortfall' }));
  ok(!old.includes(esc(UX_MISC.quotaRegionalShort)), 'a record written before v14 has no answer: the page does not judge the figures');
});

test('the migration page: the card draws that regional row first, with the pill that says why', () => {
  const store = fakeTable();
  page.renderCapacity([
    v14({ family: 'aaaFamily', regional: 6, rLimit: 10, rUsed: 8, state: 'BLOCKED', blockReason: 'quota-shortfall' }, true),
  ], null);
  const heads = headingsOf(store['#cap-head']);
  const drawn = rowsOf(store['#cap-table tbody']);
  eq(drawn.length, 2, 'the family row and the regional row');
  const first = cells(drawn[0]);
  ok(first[0].includes(esc(UX_CAP.regionalName)), `the short regional row comes first, got: ${first[0]}`);
  ok(first[heads.indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaRegionalShort)), 'with the pill that says why');
  const family = cells(drawn[1]);
  ok(family[heads.indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaShort)), 'and the family row keeps its own words');

  const room = fakeTable();
  page.renderCapacity([
    v14({ family: 'aaaFamily', regional: 2, rLimit: 100, rUsed: 0, state: 'BLOCKED', blockReason: 'quota-shortfall' }, false),
  ], null);
  const rowsRoom = rowsOf(room['#cap-table tbody']);
  ok(!cells(rowsRoom[0])[0].includes(esc(UX_CAP.regionalName)), 'with room in the region, the family row comes first');
  ok(cells(rowsRoom[1])[headingsOf(room['#cap-head']).indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaOk)),
    'and the regional row says it is enough');
});

test('one rule: the card and the wave editor ask help.js, and compare no block reason of their own', () => {
  const { extract } = require('./_harness');
  for (const [file, name] of [['migrations.html', 'regionalFacet'], ['migrations.html', 'capacityRegionalRows'], ['waves.html', 'loadClaims']]) {
    const body = extract(file, name);
    ok(/VmfHelp\.claimRegionalShort\(/.test(body), `${name} in ${file} asks VmfHelp.claimRegionalShort`);
    ok(!/regionalShort\s*===/.test(body), `${name} in ${file} does not read regionalShort itself`);
  }
});

/* REGIONAL-QUOTA-REQUESTED-PAGE-1: Request an increase moves a record to
 * QUOTA_REQUESTED by the request of its own reason, and writes the regional
 * request filed beside a family request in quota.regionalRequestId and
 * quota.regionalRequestedUtc. Such a record is not blocked any more, so the
 * regional row showed Headroom verified with the old usage, after the
 * families, while the family row of the same record said Increase requested.
 * One rule says whether a regional request waits for a record - help.js
 * claimRegionalRequested - held to tests/fixtures/regional-requested.json,
 * whose engine cases RegionalQuotaRequestedPage.Tests.ps1 makes the engine
 * write. */
const REQUESTED_CASES = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'regional-requested.json'), 'utf8')).cases;
const requestedCase = (name) => REQUESTED_CASES.find(c => c.engine === name);
/* A v14 record with the request fields of one engine case of the fixture. */
const filed = (name, o = {}) => {
  const c = requestedCase(name).claim;
  const base = v14({ regional: 6, rLimit: 10, rUsed: 8, ...o, state: c.state, blockReason: c.blockReason }, c.regionalShort);
  return { ...base, quota: { ...base.quota, ...c.quota } };
};

test('RUN: every shared case of a waiting regional request gives the fixture\'s answer', () => {
  ok(REQUESTED_CASES.length >= 15, 'the fixture loaded');
  for (const c of REQUESTED_CASES) {
    eq(VmfHelp.claimRegionalRequested(c.claim), c.requested, `${JSON.stringify(c.claim)} - ${c.why}`);
  }
});

test('the migration page: THE DEFECT - a record whose regional request waits says Increase requested on the regional row', () => {
  for (const name of ['regional-own-pending', 'regional-own-approved', 'both-pending', 'both-approved', 'family-refused-region-filed']) {
    const pill = page.regionalFacet(filed(name));
    ok(pill.includes(esc(UX_MISC.quotaReq)) && /pill warn/.test(pill), `${name}: got ${pill}`);
    ok(!pill.includes(esc(UX_MISC.quotaOk)), `${name}: never the words that say the quota is enough`);
    ok(!pill.includes(esc(UX_MISC.quotaRegionalShort)), `${name}: the request is filed, so not the words that ask for one`);
    ok(!/8\/10/.test(pill), `${name}: not the old usage, which the request is to change`);
  }
});

test('the migration page: a QUOTA_REQUESTED record with no regional request keeps the regional figures', () => {
  for (const name of ['family-only', 'region-refused-family-filed']) {
    const pill = page.regionalFacet(filed(name, { rLimit: 100, rUsed: 0 }));
    ok(pill.includes(esc(UX_MISC.quotaOk)) && /0\/100/.test(pill), `${name}: got ${pill}`);
    ok(!pill.includes(esc(UX_MISC.quotaReq)), `${name}: no regional request waits`);
  }
});

test('the migration page: a regional row with a waiting request is a problem; with none it is not', () => {
  for (const name of ['regional-own-pending', 'regional-own-approved', 'both-pending', 'both-approved', 'family-refused-region-filed']) {
    ok(page.capacityRegionalRows([filed(name)])[0].problem, `${name}: the request still waits`);
  }
  ok(!page.capacityRegionalRows([filed('family-only', { rLimit: 100, rUsed: 0 })])[0].problem, 'only the family was requested');
  ok(!page.capacityRegionalRows([{ ...filed('both-pending'), state: 'RELEASED' },
    v14({ wave: 'wave-2', regional: 2, rLimit: 100, rUsed: 0 }, false)])[0].problem, 'a released record is history');
});

test('the migration page: the card draws the regional row with a waiting request first, as Increase requested', () => {
  for (const name of ['regional-own-pending', 'both-pending']) {
    const store = fakeTable();
    page.renderCapacity([filed(name, { family: 'aaaFamily' })], null);
    const heads = headingsOf(store['#cap-head']);
    const drawn = rowsOf(store['#cap-table tbody']);
    eq(drawn.length, 2, `${name}: the family row and the regional row`);
    const first = cells(drawn[0]);
    ok(first[0].includes(esc(UX_CAP.regionalName)), `${name}: the regional row comes first, got: ${first[0]}`);
    ok(first[heads.indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaReq)), `${name}: with Increase requested`);
    ok(!first[heads.indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaOk)), `${name}: and never Headroom verified`);
    ok(cells(drawn[1])[heads.indexOf(UX_CAP.colQuota)].includes(esc(UX_MISC.quotaReq)), `${name}: as the family row says`);
  }
});

test('one rule: the card asks help.js whether a regional request waits, and reads no request field itself', () => {
  const { extract } = require('./_harness');
  for (const name of ['regionalFacet', 'capacityRegionalRows']) {
    const body = extract('migrations.html', name);
    ok(/VmfHelp\.claimRegionalRequested\(/.test(body), `${name} asks VmfHelp.claimRegionalRequested`);
    ok(!/regionalRequest(Id|edUtc)/.test(body), `${name} does not read the request fields itself`);
  }
});

/* ---- the wave editor ------------------------------------------------------ */

test('the wave editor: the records say which waves and regions are short of the regional quota', async () => {
  const UX = liftConst('waves.html', 'UX');
  globalThis.UX = UX;
  const docs = [
    rec({ wave: 'wave-1', region: 'centralus', state: 'BLOCKED', blockReason: 'regional-quota-shortfall', regional: 6, rLimit: 10, rUsed: 8 }),
    rec({ wave: 'wave-2', region: 'eastus2', state: 'BLOCKED', blockReason: 'quota-shortfall', regional: 2, rLimit: 10, rUsed: 0 }),
  ];
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  globalThis.DEMO_MODE = false;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobList = async () => docs.map((_, i) => `c${i}.json`);
  globalThis.blobFetch = async (n) => docs[Number(n.slice(1, -5))];
  // PAGE-LOAD-3: loadClaims asks the one call first; here it fails, so each record is read.
  globalThis.VmfHelp = { ...globalThis.VmfHelp, ...require('./_held').perFileHelp(), mapLimited: async (list, fn) => Promise.all(list.map(fn)) };
  globalThis.waveNoneReservable = () => false;
  // The page's own state, which loadClaims sets.
  Object.assign(globalThis, { claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false,
    quotaShort: false, unlistedWaves: new Set(), lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map() });
  ok(await w.loadClaims(), 'the records are read');
  eq([...globalThis.regionalShortWaves], ['wave-1'], 'only the wave the engine blocked on the regional quota');
  eq([...globalThis.regionalShortRegions], ['centralus'], 'and its region');
  ok(/Total Regional vCPUs/.test(UX.quotaRegional) && /Request an increase/.test(UX.quotaRegional),
    'the card says Request an increase does not ask for it');
  // QUOTA-CHECK-SPINNER-1: the wave names the quota in its line, by Azure's name.
  ok(UX.capRegionalName === 'Total Regional vCPUs' && !/capacity/i.test(UX.capLineShort), 'quota, never capacity');
});

/* REGIONAL-QUOTA-BOTH-1: a record blocked on its family keeps that reason, and
 * the engine records beside it that the region is short too (regionalShort,
 * capacity-claim v14). Request an increase asks for both, so the card names
 * the region. The wave keeps the family's words: its family is short. */
test('the wave editor: a record short on its family AND the region names the region, and keeps the family words for the wave', async () => {
  const UX = liftConst('waves.html', 'UX');
  globalThis.UX = UX;
  const docs = [
    { ...rec({ wave: 'wave-2', region: 'eastus2', state: 'BLOCKED', blockReason: 'quota-shortfall', regional: 6, rLimit: 10, rUsed: 8 }), regionalShort: true },
    { ...rec({ wave: 'wave-3', region: 'westus3', state: 'BLOCKED', blockReason: 'quota-shortfall', regional: 2, rLimit: 100, rUsed: 0 }), regionalShort: false },
  ];
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  globalThis.DEMO_MODE = false;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobList = async () => docs.map((_, i) => `c${i}.json`);
  globalThis.blobFetch = async (n) => docs[Number(n.slice(1, -5))];
  // PAGE-LOAD-3: loadClaims asks the one call first; here it fails, so each record is read.
  globalThis.VmfHelp = { ...globalThis.VmfHelp, ...require('./_held').perFileHelp(), mapLimited: async (list, fn) => Promise.all(list.map(fn)) };
  globalThis.waveNoneReservable = () => false;
  Object.assign(globalThis, { claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false,
    quotaShort: false, unlistedWaves: new Set(), lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map() });
  ok(await w.loadClaims(), 'the records are read');
  eq([...globalThis.regionalShortRegions], ['eastus2'], 'the region the engine found short beside the family, and not the one with room');
  eq([...globalThis.regionalShortWaves], [], 'the wave keeps the family words: the family is short too');
});

run('regional quota');
