/* CRG-MOVE-DEMAND-1: a wave reserves no place for a machine that stays in its
 * own capacity reservation group, and the pages say so.
 *
 * The engine's one rule is Test-VmfEntryReservable: a machine in an
 * availability set, or one the assessment found in a capacity reservation
 * group this migration did not make, gets no place in the wave's reservation.
 * The quota record names the second kind (demand.ownGroupVmIds,
 * capacity-claim v15).
 *
 * - The wave editor offers no Reserve button for a wave whose saved plan gives
 *   no machine a place (waveNoneReservable, the page's twin of the rule), and
 *   does not count a machine in its own group as one in an availability set.
 * - The capacity card on the Migrations page names the machines in their own
 *   group, and counts only the others as in an availability set.
 *
 * RUN, not read: the pages' own functions.
 */
'use strict';
// QUOTA-CHECK-SPINNER-1: loadClaims counts its reads, so only the newest fills the page.
globalThis.claimsTurn = 0;
const { test, ok, eq, run, lift, liftAll, liftConst } = require('./_harness');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000';
const OURS = `${SUB}/resourceGroups/rg-lab/providers/Microsoft.Compute/capacityReservationGroups/vmf-crg-w1`;
const THEIRS = `${SUB}/resourceGroups/rg-capacity/providers/Microsoft.Compute/capacityReservationGroups/contoso-crg`;
const vmId = (n) => `${SUB}/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/${n}`;

/* ---- the wave editor ---------------------------------------------------- */

const UX = liftConst('waves.html', 'UX');
const waveNoneReservable = lift('waves.html', 'waveNoneReservable');
const { loadClaims } = liftAll('waves.html', ['loadClaims', 'heldOrFetch']);
const reserveControl = lift('waves.html', 'reserveControl');
const reserveDoneText = lift('waves.html', 'reserveDoneText');
const claimCount = lift('waves.html', 'claimCount');
const quotaAccessFrom = lift('waves.html', 'quotaAccessFrom');
// help.js's claimRegionalShort calls claimBlocked by name.
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
const claimRegionalShort = lift('help.js', 'claimRegionalShort');

// A plan entry: 'absent' (the scan did not say), 'none', 'own', 'ours'.
function entry(name, group, avset = false) {
  const a = { availabilitySetId: avset ? '/avsets/pair' : '' };
  if (group !== 'absent') { a.capacityReservationGroupId = { none: null, own: THEIRS, ours: OURS }[group]; }
  return { vmId: vmId(name), wave: 'w', path: 'A', assessment: a };
}

function world(docs, planEntries) {
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
    entries: planEntries,
  });
}
const claim = (o) => ({ wave: 'w', size: o.size ?? 'Standard_D2ds_v6', state: o.state ?? 'QUOTA_VERIFIED',
  demand: { instances: o.instances, reservableInstances: o.reservable, ...(o.own ? { ownGroupVmIds: o.own } : {}) },
  quota: { limit: 100, used: 0 }, ...(o.reservation ? { reservation: o.reservation } : {}) });

test('the twin: a wave whose machines are all in their own group gives none a place', () => {
  globalThis.entries = [entry('a', 'own'), entry('b', 'own')];
  eq(waveNoneReservable('w', new Set()), true);
});

test('the twin: an availability set member and a machine in its own group - still none', () => {
  globalThis.entries = [entry('a', 'none', true), entry('b', 'own')];
  eq(waveNoneReservable('w', new Set()), true);
});

test('the twin: one machine in no group gets a place', () => {
  globalThis.entries = [entry('a', 'own'), entry('b', 'none')];
  eq(waveNoneReservable('w', new Set()), false);
});

test('the twin: a plan entry that does not say is counted - unknown is never a no', () => {
  globalThis.entries = [entry('a', 'absent')];
  eq(waveNoneReservable('w', new Set()), false);
});

test('the twin: a group of this migration is not the machine\'s own, whatever the letter case', () => {
  globalThis.entries = [entry('a', 'ours')];
  eq(waveNoneReservable('w', new Set([OURS.toLowerCase()])), false);
  eq(waveNoneReservable('w', new Set()), true, 'without the list, the same group reads as its own');
});

test('the twin: a wave with no moving machine is not "none" - unknown is not yes', () => {
  globalThis.entries = [];
  eq(waveNoneReservable('w', new Set()), false);
});

test('the editor: a wave of machines in their own group offers no Reserve button', async () => {
  world([claim({ instances: 2, reservable: 0, own: [vmId('a'), vmId('b')] })], [entry('a', 'own'), entry('b', 'own')]);
  ok(await loadClaims(), 'the read worked');
  eq(globalThis.claims.get('w'), 'general');
  const html = reserveControl('w');
  ok(html.includes(UX.reserveGeneral) && !html.includes('data-reserve='), html);
});

test('the editor: a machine in a group a record of this migration names is reservable, so Reserve stays', async () => {
  const held = claim({ size: 'Standard_D4ds_v6', instances: 1, reservable: 1, state: 'RESERVED', reservation: { groupId: OURS } });
  held.wave = 'w0';
  world([claim({ instances: 1, reservable: 0, own: [vmId('a')] }), held], [entry('a', 'ours')]);
  await loadClaims();
  ok(!globalThis.claims.has('w'), String(globalThis.claims.get('w')));
});

test('the editor: once reserved, a machine in its own group is not counted as one in an availability set', async () => {
  world([claim({ instances: 4, reservable: 1, own: [vmId('a')], state: 'RESERVED', reservation: { groupId: OURS } })],
    [entry('a', 'own'), entry('b', 'none', true), entry('c', 'none', true), entry('d', 'none')]);
  await loadClaims();
  const said = reserveDoneText('w');
  ok(said.includes(UX.reserveDoneGeneral.replace('{n}', '2')), said);
});

test('the words name both causes, in Azure\'s own terms', () => {
  ok(/own capacity reservation group/.test(UX.reserveNothing), UX.reserveNothing);
  ok(/own capacity reservation group/.test(UX.reserveGeneralTip), UX.reserveGeneralTip);
  ok(/availability set/.test(UX.reserveNothing), UX.reserveNothing);
});

/* ---- the capacity card on the Migrations page --------------------------- */

const UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_MISC = UX_MISC;
globalThis.UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
const page = liftAll('migrations.html', ['reservationFacet', 'reservationFact']);

function card(o, gate = 'Reserved') {
  globalThis.VmfHelp = { claimBlocked: (s) => s === 'BLOCKED', claimReservingStuck: () => false };
  globalThis.esc = (v) => String(v == null ? '' : v).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  return { pill: page.reservationFacet(claim(o), gate), fact: page.reservationFact(claim(o)) };
}

/* RES-LIST-1 (2026-11-11): the Capacity reservations list says one
 * short fact a row, and never the machines of an availability set. */
test('a reserved row says its counts, and names no availability set', () => {
  const r = card({ instances: 4, reservable: 1, own: [vmId('app-01')], state: 'RESERVED', reservation: { consumedInstances: 1 } });
  eq(r.fact, UX_MISC.reservedCounts.replace('{used}', '1').replace('{idle}', '0'));
  ok(!/availability set/i.test(r.pill + r.fact), r.pill + r.fact);
});

test('two machines in their own group and nothing to reserve: the fact names them, the pill says why', () => {
  const r = card({ instances: 2, reservable: 0, own: [vmId('a'), vmId('b')] });
  eq(r.fact, UX_MISC.ownGroupNote.replace('{n}', '2').replace('{names}', 'a, b'));
  ok(r.pill.includes(`title="${UX_MISC.ownGroupHint}"`), 'the pill itself says why: ' + r.pill);
});

test('one machine in its own group: the singular words', () => {
  eq(card({ instances: 1, reservable: 0, own: [vmId('app-01')] }).fact, UX_MISC.ownGroupNoteOne.replace('{names}', 'app-01'));
});

test('machines in an availability set only: Not reserved, with no fact and no hover about them', () => {
  const r = card({ instances: 3, reservable: 0 });
  ok(r.pill.includes(`>${UX_MISC.notReserved}<`), r.pill);
  ok(!/title=/.test(r.pill), 'no hover: ' + r.pill);
  eq(r.fact, '');
});

test('each fact is a sentence', () => {
  for (const r of [card({ instances: 2, reservable: 0, own: [vmId('a'), vmId('b')] }), card({ instances: 1, reservable: 0, own: [vmId('a')] })]) {
    ok(/^[A-Z0-9]/.test(r.fact) && /\.$/.test(r.fact), r.fact);
  }
});
run('crg-move-demand');
