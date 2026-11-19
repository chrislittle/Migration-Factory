/* AVSET-RESERVE-1: the wave editor hears "nothing to reserve" when the engine
 * says it, and says where those machines go.
 *
 * The page looked for the words "no reservable demand" in the log. Those words
 * were only ever in the CLAIM note; the event said "all-AvSet cell, no
 * reservation possible". So a wave of availability-set machines waited out the
 * whole watch and was told "still running" about an answer that had come. Its
 * test passed, because it fed the page an event the engine never wrote.
 *
 * Now the engine writes a code and the wave in the event, and both halves are
 * held to tests/fixtures/reserve-nothing-events.json: the PowerShell test runs
 * the engine on each case and compares the events; this one gives the page the
 * same events.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
// QUOTA-CHECK-SPINNER-1: loadClaims counts its reads, so only the newest fills the page.
globalThis.claimsTurn = 0;
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// REGIONAL-QUOTA-BOTH-PAGE-1: the page asks help.js whether a record is short of the region.
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
const claimRegionalShort = lift('help.js', 'claimRegionalShort');

const FIX = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'reserve-nothing-events.json'), 'utf8'));
const UX = liftConst('waves.html', 'UX');
const reserveScan = lift('waves.html', 'reserveScan');
const { loadClaims } = liftAll('waves.html', ['loadClaims', 'heldOrFetch']);
const reserveControl = lift('waves.html', 'reserveControl');
const reserveDoneText = lift('waves.html', 'reserveDoneText');
// Lifted alone and set as globals, because loadClaims calls them by name.
const claimCount = lift('waves.html', 'claimCount');
const waveNoneReservable = lift('waves.html', 'waveNoneReservable');
const quotaAccessFrom = lift('waves.html', 'quotaAccessFrom');

const at = new Date().toISOString();
const asLogged = (events) => events.map(e => {
  const o = { tsUtc: at, step: e.step, outcome: e.outcome, detail: 'as the engine words it' };
  if (e.code) { o.code = e.code; }
  if (e.wave) { o.wave = e.wave; }
  return o;
});

test('the fixture was read and has cases, so nothing below passes on an empty list', () => {
  ok(FIX.cases.length > 3, `${FIX.cases.length} cases`);
});

for (const c of FIX.cases) {
  test(`the log: ${c.why}`, () => {
    const verdict = reserveScan(asLogged(c.events), FIX.wave);
    if (c.page === 'nothing') { ok(verdict && verdict.nothing, JSON.stringify(verdict)); }
    else { eq(verdict, null, 'the claim decides this one, not the log'); }
  });
}

test('another wave\'s "nothing to reserve" is not this wave\'s answer', () => {
  const theirs = FIX.cases.find(c => c.page === 'nothing').events.map(e => Object.assign({}, e, { wave: 'wave-2' }));
  eq(reserveScan(asLogged(theirs), FIX.wave), null);
});

test('a failure still wins over "nothing to reserve" - it is the news a person must see', () => {
  const nothing = FIX.cases.find(c => c.page === 'nothing').events;
  const events = asLogged(nothing.concat([{ step: 'engine', outcome: 'fail' }]));
  const verdict = reserveScan(events, FIX.wave);
  ok(verdict && verdict.failure && !verdict.nothing, JSON.stringify(verdict));
});

test('the old phrase in a detail is no answer at all', () => {
  // The made-up event the old test used. Nothing the engine writes looks like
  // it, and the page must not start depending on words again.
  const made = [{ tsUtc: at, step: 'odcr', outcome: 'warn', detail: 'no reservable demand' }];
  eq(reserveScan(made, FIX.wave), null);
});

// The claims as the store holds them, read by the page's own loadClaims.
function world(cells, wave, plan = { inAvset: 1, outside: 0 }) {
  const docs = cells.map(c => ({
    wave, size: c.name, state: c.state ?? 'QUOTA_VERIFIED',
    demand: { instances: c.instances, reservableInstances: c.reservable },
    quota: { limit: 100, used: 0 },
  }));
  Object.assign(globalThis, {
    UX, DEMO_MODE: false, canEdit: true, demoState: new Map(),
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(),
    quotaChecked: false, quotaShort: false, unlistedWaves: new Set(), lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map(),
    runPrefix: () => 'p/r',
    blobList: async () => docs.map((d, i) => `p/r/capacity/${i}.json`),
    blobFetch: async (n) => docs[Number(n.match(/(\d+)\.json$/)[1])],
    // PAGE-LOAD-3: loadClaims asks the one call first; here it fails, so each record is read.
    VmfHelp: { ...require('./_held').perFileHelp(),
      mapLimited: async (xs, f) => Promise.all(xs.map(f)),
      claimReservingStuck: () => false,
      claimBlocked: (s) => s === 'BLOCKED',
      claimRegionalShort,
    },
    esc: (s) => String(s ?? ''), dirty: () => false, waveMigrating: () => false,
    claimCount, waveNoneReservable, quotaAccessFrom,
    // The saved plan's machines of the wave: in an availability set, or not.
    entries: [
      ...Array.from({ length: plan.inAvset }, (_, i) => ({ vmId: 'av' + i, wave, path: 'A', assessment: { availabilitySetId: '/avsets/pair' } })),
      ...Array.from({ length: plan.outside }, (_, i) => ({ vmId: 'vm' + i, wave, path: 'A', assessment: { availabilitySetId: '' } })),
    ],
  });
}

for (const c of FIX.cases) {
  test(`the pill: ${c.why}`, async () => {
    world(c.cells, FIX.wave, c.plan);
    ok(await loadClaims(), 'the read worked');
    eq(globalThis.claims.get(FIX.wave) ?? null, c.pill);
    const html = reserveControl(FIX.wave);
    if (c.pill === 'general') {
      ok(html.includes(UX.reserveGeneral) && !html.includes('data-reserve='),
        'nothing to reserve, so no Reserve button: ' + html);
    }
    if (c.pill === null) { ok(html.includes('data-reserve='), 'a wave with reservable machines offers Reserve'); }
  });
}

test('a claim that does not say how many machines are reservable is reservable - unknown is not a no', async () => {
  world([{ name: 'old', instances: 2, reservable: undefined }], 'w');
  await loadClaims();
  ok(!globalThis.claims.has('w'), 'no general pill on a claim that does not say');
});

test('a mixed wave, once reserved, says how many machines move on general capacity', async () => {
  world([{ name: 'a', instances: 2, reservable: 0 }, { name: 'b', instances: 3, reservable: 1, state: 'RESERVED' }], 'w');
  await loadClaims();
  const said = reserveDoneText('w');
  ok(said.startsWith(UX.reserveDone.replace('{wave}', 'w')), said);
  ok(said.includes(UX.reserveDoneGeneral.replace('{n}', '4')), said);
});

test('and a wave with no availability-set machine says only that it is reserved', async () => {
  world([{ name: 'b', instances: 3, reservable: 3, state: 'RESERVED' }], 'w');
  await loadClaims();
  eq(reserveDoneText('w'), UX.reserveDone.replace('{wave}', 'w'));
});

// TERMS-AUDIT-1: Azure's own term. There is no such thing as general capacity (owner).
test('the words say what Azure allows, in Azure\'s own term', () => {
  ok(/Azure does not allow an on-demand capacity reservation/.test(UX.reserveNothing), UX.reserveNothing);
  ok(/Azure does not allow an on-demand capacity reservation/.test(UX.reserveGeneralTip), UX.reserveGeneralTip);
  ok(/no on-demand capacity reservation/.test(UX.reserveDoneGeneral), UX.reserveDoneGeneral);
  for (const s of [UX.reserveNothing, UX.reserveGeneralTip, UX.reserveDoneGeneral, UX.reserveDoneGeneralOne, UX.reserveGeneral]) { ok(!/general capacity/i.test(s), s); }
});

test('rule cases: what makes a quota record reservable, the same cases the engine is held to', () => {
  ok(FIX.rules.length > 10, 'the cases were read');
  for (const r of FIX.rules) {
    const v = r.reservableInstances === 'missing' ? undefined : r.reservableInstances;
    const n = claimCount(v);
    eq(n === null || n > 0, r.reservable, `reservableInstances ${JSON.stringify(r.reservableInstances)}`);
  }
});

test('only the availability-set records exist yet, but the plan has an ordinary machine: Reserve stays (review finding 1)', async () => {
  // A quota check writes records one by one. Hiding Reserve on a partial set
  // would hide the only way to reserve the ordinary machines.
  world([{ name: 'a', instances: 1, reservable: 0 }], 'w', { inAvset: 1, outside: 1 });
  await loadClaims();
  ok(!globalThis.claims.has('w'), 'no General capacity pill');
  ok(reserveControl('w').includes('data-reserve='), 'Reserve is offered');
});

test('a wave with no moving machine in the plan is not "all in an availability set" - unknown is not yes', async () => {
  world([{ name: 'a', instances: 1, reservable: 0 }], 'w', { inAvset: 0, outside: 0 });
  await loadClaims();
  ok(!globalThis.claims.has('w'));
});

test('a quota-blocked claim with nothing reservable is not "Azure did not provision this reservation" (review finding 5)', async () => {
  world([{ name: 'a', instances: 2, reservable: 0, state: 'BLOCKED' }, { name: 'b', instances: 1, reservable: 1 }], 'w', { inAvset: 2, outside: 1 });
  await loadClaims();
  ok(globalThis.claims.get('w') !== 'blocked', String(globalThis.claims.get('w')));
});

test('...but a reservable claim that is blocked still reads as not reserved', async () => {
  world([{ name: 'b', instances: 1, reservable: 1, state: 'BLOCKED' }], 'w', { inAvset: 0, outside: 1 });
  await loadClaims();
  eq(globalThis.claims.get('w'), 'blocked');
});

test('a count the page cannot read is no count: never "NaN machines"', async () => {
  world([{ name: 'a', instances: 'many', reservable: 0 }, { name: 'b', instances: 2, reservable: 1, state: 'RESERVED' }], 'w', { inAvset: 1, outside: 1 });
  await loadClaims();
  const said = reserveDoneText('w');
  ok(!/NaN/.test(said), said);
});

test('the run page says the sentence of the new events, not "Creating the reservation" (review finding 3)', () => {
  const { stepText } = require('./_harness').liftAll('migrations.html', ['stepText']);
  globalThis.UX_STEP = new Proxy({}, { get: (_, k) => `[label ${String(k)}]` });
  globalThis.UX_STATE = {};
  const nothing = { step: 'odcr', outcome: 'info', code: 'nothingReservable', wave: 'w', detail: 'Wave w has nothing to reserve.' };
  eq(stepText(nothing), nothing.detail);
  const cell = { step: 'odcr', outcome: 'warn', wave: 'w', detail: 'Every machine of size X is in an availability set.' };
  eq(stepText(cell), cell.detail);
  const note = { step: 'capacity', outcome: 'info', wave: 'w', detail: 'Wave w starts on general capacity.' };
  eq(stepText(note), note.detail);
  // An ordinary reservation line keeps its label.
  ok(/label reserveCap/.test(stepText({ step: 'odcr', outcome: 'start', detail: 'reserving 1x D2' })));
});
run('reserve-nothing');
