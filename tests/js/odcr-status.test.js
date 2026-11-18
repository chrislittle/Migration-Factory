/* ODCR-STATUS-1: a capacity reservation nobody confirmed says so on the
 * migration page, with Release.
 *
 * MEASURED on the lab install, 2026-11-09: the reservation drill stopped the
 * engine 4 seconds after it asked Azure for wave-1's capacity reservation, and
 * Azure made it anyway. The migration page's capacity cell read "wave-1
 * Reserving..." and "wave-2 Not confirmed": no word that it can bill, and no
 * Release - that was only in the wave editor.
 *
 * The five-minute pass of the web service now reads such a record from Azure
 * (tests/unit/OdcrStatus.Tests.ps1). A record Azure still makes is marked not
 * confirmed (reservationUnconfirmedUtc); this page says, in the cell, that it
 * can bill, and offers Release beside it to an operator while no machine of
 * the wave is at work.
 *
 * Every check RUNS the page's own functions with the page's own words.
 */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { test, ok, eq, run, lift, liftAll, liftConst } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_CAP = liftConst('migrations.html', 'UX_CAP');
globalThis.UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.BLOCK_TEXT = liftConst('migrations.html', 'BLOCK_TEXT');
globalThis.RESERVING_STUCK_MINUTES = 60;
globalThis.VmfHelp = {
  claimBlocked: lift('help.js', 'claimBlocked'),
  claimReservingStuck: lift('help.js', 'claimReservingStuck'),
  claimRegionalShort: lift('help.js', 'claimRegionalShort'),
  claimRegionalRequested: lift('help.js', 'claimRegionalRequested'),
  machineHold: lift('help.js', 'machineHold'),
  waveHold: lift('help.js', 'waveHold'),
};
globalThis.claimBlocked = VmfHelp.claimBlocked;
globalThis.machineHold = VmfHelp.machineHold;
globalThis.LEASE_LIMIT_SECONDS = Number(pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'))
  .match(/const LEASE_LIMIT_SECONDS = (\d+);/)[1]);
globalThis.esc = (v) => String(v == null ? '' : v)
  .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.ago = (iso) => `at ${iso}`;
globalThis.waveLabel = (w) => w || 'Not moved';

const page = liftAll('migrations.html', [
  'quotaFacet', 'reservationFacet', 'mergeFacets', 'quotaFacetsOf', 'regionalFacet', 'capacityRegionalRows',
  'capacityRowProblem', 'quotaBlockedHere', 'quotaListFacet', 'reservationFact', 'reservationProblem', 'reservationBills', 'claimUsesReservation', 'capacityFamilyRows', 'capacityGateOf', 'renderCapacity',
  'claimSizeBlocked', 'newestCheckOf', 'reservationReleasable', 'askReleaseReservation',
]);
globalThis.mergeFacets = page.mergeFacets;

let clicks = [];
function fakeTable() {
  const store = {};
  const styles = {};
  Object.defineProperty(store, '__styles', { value: styles, enumerable: false });
  const el = (id) => ({
    set innerHTML(v) { store[id] = v; },
    get innerHTML() { return store[id] ?? ''; },
    insertAdjacentHTML(_, v) { store[id] = (store[id] ?? '') + v; },
    get style() { return (styles[id] ??= {}); },
    // The buttons the table holds, as the page wires them.
    querySelectorAll: (sel) => {
      if (sel !== '[data-releasewave]') { return []; }
      const html = store[id] ?? '';
      return [...html.matchAll(/data-releasewave="([^"]*)"/g)].map(m => ({
        dataset: { releasewave: m[1] },
        addEventListener: (ev, fn) => { if (ev === 'click') { clicks.push({ wave: m[1], fn }); } },
      }));
    },
  });
  globalThis.$ = (sel) => el(sel);
  return store;
}

const SUB = '00000000-0000-0000-0000-000000000000';
const NOW = Date.now();
const minsAgo = (n) => new Date(NOW - n * 60000).toISOString();
const rec = (o) => ({
  schemaVersion: 15, runId: 'r1', wave: o.wave ?? 'wave-1', subscriptionId: SUB,
  resourceGroup: 'rg-app', region: 'centralus', zone: null,
  size: 'Standard_D2ds_v5', vmFamily: 'standardDDSv5Family',
  state: o.state ?? 'RESERVING', blockReason: null,
  demand: { instances: 1, reservableInstances: 1, vcpus: 2, familyVcpus: 2 },
  quota: { limit: 20, used: 0, checkedUtc: minsAgo(30) },
  reservingSinceUtc: o.since ?? minsAgo(3),
  ...(o.unconfirmed ? { reservationUnconfirmedUtc: o.unconfirmed } : {}),
});
const reservedPlan = { entries: [{ vmId: '/subscriptions/x/vm1', wave: 'wave-1', path: 'A', policy: { capacityGate: 'Reserved' } },
                                 { vmId: '/subscriptions/x/vm2', wave: 'wave-2', path: 'A', policy: { capacityGate: 'Reserved' } }] };
/* RES-LIST-1: the Capacity reservations list as the card draws it. */
const resRows = (store) => (store['#res-table tbody'] ?? '').split('<tr').slice(1).map(r => {
  const tds = []; const re = /<td[^>]*>([\s\S]*?)<\/td>/g; let m;
  while ((m = re.exec(r))) { tds.push(m[1]); }
  return { wave: tds[0], size: tds[1], state: tds[2], fact: tds[3], release: tds[4] };
});
const drawRes = (claims, releasable = () => true) => { const store = fakeTable(); page.renderCapacity(claims, reservedPlan, releasable); return resRows(store); };
const heldRec = (wave, used = 0) => ({ ...rec({ wave, state: 'RESERVED' }), reservation: { groupId: '/g', reservationId: '/g/r', consumedInstances: used } });

/* ---- the row ------------------------------------------------------------- */

test('THE DEFECT: a reservation nobody confirmed has its own row: Not confirmed, the owner\'s fact, and Release', () => {
  const [r] = drawRes([rec({ unconfirmed: minsAgo(1) })]);
  ok(r.state.includes(`>${UX_MISC.unconfirmed}</span>`) && r.state.includes(`title="${UX_MISC.unconfirmedHint}"`), `the pill with its approved hover, got: ${r.state}`);
  eq(r.fact, `<span class="muted">Azure did not confirm it. It can still bill.</span>`, 'the fact, exactly');
  ok(r.release.includes('data-releasewave="wave-1"') && r.release.includes(`>${UX_MISC.releaseBtn}</button>`), `Release in its own column, got: ${r.release}`);
  ok(r.release.includes(`title="${UX_MISC.releaseTip}"`), 'with what it does on hover');
  ok(!r.state.includes('button') && !r.fact.includes('button'), 'and nowhere else in the row');
});

test('no Release where the page says no: the fact stays', () => {
  const [r] = drawRes([rec({ unconfirmed: minsAgo(1) })], () => false);
  eq(r.release, '', 'no Release');
  ok(r.fact.includes(UX_MISC.unconfirmedNote), 'the fact is still said');
});

test('Release only where the reservation bills: not while the engine makes it, not after it is released, not for None or Not reserved', () => {
  const making = rec({ wave: 'wave-1', since: minsAgo(2) });
  const released = { ...rec({ wave: 'wave-1', state: 'RELEASED' }), reservation: { consumedInstances: 0 } };
  const notReserved = rec({ wave: 'wave-1', state: 'QUOTA_VERIFIED' });
  for (const [c, what] of [[making, 'Reserving...'], [released, 'Released'], [notReserved, 'Not reserved']]) {
    const [r] = drawRes([c]);
    eq(r.release, '', `${what}: no Release`);
  }
  const store = fakeTable();
  page.renderCapacity([rec({ wave: 'wave-3', state: 'QUOTA_VERIFIED' }), heldRec('wave-1')],
    { entries: [...reservedPlan.entries, { vmId: '/subscriptions/x/vm3', wave: 'wave-3', path: 'A', policy: { capacityGate: 'BestEffort' } }] }, () => true);
  ok(!resRows(store).some(r => r.wave.includes('wave-3')), 'a wave set to None has no row at all');
  const [mk] = drawRes([making]);
  ok(mk.state.includes(`>${UX_MISC.reserving}</span>`), 'a reservation Azure is making says Reserving...');
});

test('a reservation Azure holds bills: Reserved n, its counts in the shortest form, and Release', () => {
  const [r] = drawRes([{ ...heldRec('wave-1', 1), demand: { instances: 2, reservableInstances: 2, vcpus: 2 } }]);
  ok(r.state.includes(`>${UX_MISC.reserved} 2</span>`), r.state);
  eq(r.fact, '<span class="muted">1 in use, 1 idle</span>');
  ok(r.release.includes('data-releasewave="wave-1"'), 'Release, for an operator while the wave is not at work');
});

test('the pass marked it not confirmed three minutes after it was asked: Release at once, not after an hour', () => {
  const c = rec({ since: minsAgo(3), unconfirmed: minsAgo(0) });
  ok(VmfHelp.claimReservingStuck(c), 'the page reads the mark the pass wrote');
  ok(drawRes([c])[0].release.includes('data-releasewave="wave-1"'), 'and offers Release');
});

test('OWNER: ONE Release for each wave, on its first row - a problem row first - whichever row bills', () => {
  const s1 = rec({ wave: 'wave-1', unconfirmed: minsAgo(1) });
  const s2 = { ...heldRec('wave-1'), size: 'Standard_D4ds_v5' };
  const s3 = { ...rec({ wave: 'wave-1', state: 'QUOTA_VERIFIED' }), size: 'Standard_A2_v2' };
  const rows = drawRes([s2, s3, s1]);
  eq(rows.length, 3);
  eq(rows.map(r => (r.release.match(/data-releasewave/g) || []).length), [1, 0, 0], 'one button, on the first row');
  ok(rows[0].state.includes(`>${UX_MISC.unconfirmed}</span>`), 'and the first row is the problem row');
  const onlyHeldLater = drawRes([s3, { ...heldRec('wave-1'), size: 'Standard_Z9' }]);
  eq(onlyHeldLater.map(r => (r.release.match(/data-releasewave/g) || []).length), [1, 0],
    'a wave with a row that bills offers Release on its first row, also when that row itself does not bill');
  const nothingBills = drawRes([s3]);
  eq(nothingBills[0].release, '', 'no row of the wave bills: no Release');
});

test('two waves: one row each, and each Release names its own wave', () => {
  const rows = drawRes([rec({ wave: 'wave-1', unconfirmed: minsAgo(1) }), heldRec('wave-2')]);
  eq(rows.length, 2);
  ok(rows[0].release.includes('data-releasewave="wave-1"') && rows[1].release.includes('data-releasewave="wave-2"'), JSON.stringify(rows.map(r => r.release)));
});
/* ---- who may release, and when ------------------------------------------- */

test('the card asks the page who may release for each wave; with no answer it offers none', () => {
  const asked = [];
  const making = rec({ wave: 'wave-3', since: minsAgo(2) });
  const rows = drawRes([rec({ unconfirmed: minsAgo(1) }), rec({ unconfirmed: minsAgo(2) }), heldRec('wave-2'), making], (w) => { asked.push(w); return false; });
  ok(!rows.some(r => /data-releasewave/.test(r.release)), 'no Release when the page says no');
  eq(asked.sort(), ['wave-1', 'wave-2'], 'asked once for each wave with a row that bills - never for a reservation the engine makes now');
  const store2 = fakeTable();
  page.renderCapacity([rec({ unconfirmed: minsAgo(1) })], reservedPlan);
  ok(!/data-releasewave/.test(store2['#res-table tbody']), 'and none when the page does not say');
});

test('Release is offered to an operator only, and only while no machine of the wave is at work (the engine refuses then)', () => {
  globalThis.allVms = [];
  globalThis.leaseOf = () => undefined;
  globalThis.canOperate = () => true;
  ok(page.reservationReleasable('wave-1', reservedPlan), 'an operator, nothing at work: offered');
  globalThis.canOperate = () => false;
  ok(!page.reservationReleasable('wave-1', reservedPlan), 'a viewer or an approver: not offered');
  globalThis.canOperate = () => true;
  globalThis.allVms = [{ vmId: '/subscriptions/x/vm1', state: 'STOPPED' }];
  ok(!page.reservationReleasable('wave-1', reservedPlan), 'a machine of the wave at a working state: not offered');
  ok(page.reservationReleasable('wave-2', reservedPlan), 'another wave is not held by it');
  globalThis.allVms = [];
  globalThis.leaseOf = (id) => (id === '/subscriptions/x/vm1'
    ? { workerId: 'w-1', heartbeatUtc: new Date().toISOString(), acquiredUtc: new Date().toISOString() } : undefined);
  ok(!page.reservationReleasable('wave-1', reservedPlan), 'a machine a worker holds now: not offered');
});

/* ---- the confirmation ---------------------------------------------------- */

test('Release opens the page\'s dialog: a note, Release, and Cancel and Escape from the dialog; it starts the engine\'s release of the wave', async () => {
  let opened = null;
  const posted = [];
  globalThis.openModal = (o) => { opened = o; };
  globalThis.noteField = () => ({ id: 'note', required: true });
  globalThis.runSeg = () => 'r1';
  globalThis.apiFetch = async (route, body) => { posted.push({ route, body }); return {}; };
  page.askReleaseReservation('wave-1');
  ok(opened, 'the dialog opens');
  eq(opened.title, UX_ACT.releaseTitle);
  eq(opened.confirmLabel, UX_MISC.releaseBtn, 'its button says what it does');
  ok(opened.desc.includes('wave-1'), `the description names the wave, got: ${opened.desc}`);
  eq(opened.fields.map(f => f.id), ['note'], 'a note is asked for: the engine refuses a release without one');
  eq(posted.length, 0, 'nothing is sent before the person confirms');
  const said = await opened.onConfirm({ note: 'not needed now' });
  eq(posted, [{ route: 'runs/r1/engine/release', body: { wave: 'wave-1', note: 'not needed now' } }]);
  eq(said, UX_ACT.releaseStarted.replace('{wave}', 'wave-1'), 'and the page says what happens next');
});

test('the card wires each Release button to the dialog for its own wave', () => {
  clicks = [];
  const store = fakeTable();
  page.renderCapacity([rec({ unconfirmed: minsAgo(1) })], reservedPlan, () => true);
  ok(store['#res-table tbody'].includes('data-releasewave'), 'the button is drawn');
  eq(clicks.map(c => c.wave), ['wave-1'], 'and wired, once');
  let opened = null;
  globalThis.openModal = (o) => { opened = o; };
  globalThis.noteField = () => ({ id: 'note', required: true });
  clicks[0].fn();
  ok(opened && opened.title === UX_ACT.releaseTitle, 'a click opens the Release dialog');
  eq(opened.desc, UX_ACT.releaseDesc.replace('{wave}', 'wave-1'), 'for that wave');
});

test('the page passes its own rule to the card, and the dialog is the one with Cancel and Escape', () => {
  ok(/renderCapacity\(latestClaims, planDoc, \(w\) => reservationReleasable\(w, planDoc\)\)/.test(PAGE), 'the refresh passes reservationReleasable');
  ok(/function openModal\(/.test(PAGE) && /\$\('#m-cancel'\)\.textContent = UX_ACT\.cancel/.test(PAGE), 'openModal draws Cancel');
});

run('odcr status');
