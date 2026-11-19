/* REPORT-RELEASED-1: the Reports page counts the machines that used a
 * released reservation whose record was cleared, and never counts one
 * wave's machines twice.
 *
 * RUN, not read: the page's own reservedInstances.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const page = liftAll('reports.html', ['reservedInstances', 'num']);
globalThis.num = page.num;
const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'reports.html'));

const claim = (wave, state, reservable, extra) => Object.assign({
  wave, subscriptionId: 's1', region: 'centralus', size: 'Standard_D4ds_v6', zone: null, state,
  demand: { reservableInstances: reservable },
  reservation: { reservationId: `/r/${wave}`, createdUtc: '2026-11-01T14:00:00Z', consumedInstances: reservable },
}, extra || {});
const hist = (c) => ({ schemaVersion: 1, because: 'changed', claim: c });

test('a released reservation kept as history counts the machines that used it', () => {
  eq(page.reservedInstances([], [hist(claim('w1', 'RELEASED', 2))]), 2);
});

test('one released before its wave ran served nobody, and counts nothing', () => {
  const c = claim('w1', 'RELEASED', 3);
  c.reservation.consumedInstances = 0;
  eq(page.reservedInstances([claim('w1', 'QUOTA_VERIFIED', 3, { reservation: null })], [hist(c)]), 0);
});

test('a wave reserved again is not counted twice', () => {
  const again = claim('w1', 'RESERVED', 2, { reservation: { reservationId: '/r/second', consumedInstances: 0 } });
  eq(page.reservedInstances([again], [hist(claim('w1', 'RELEASED', 2)), hist(claim('w1', 'RELEASED', 2))]), 2);
});

test('two history records of one cell with no live claim count once', () => {
  eq(page.reservedInstances([], [hist(claim('w1', 'RELEASED', 2)), hist(claim('w1', 'RELEASED', 2, { reservation: { reservationId: '/r/other', createdUtc: '2026-11-01T14:00:00Z', consumedInstances: 2 } }))]), 2);
});

test('the same reservation live and in history counts once', () => {
  eq(page.reservedInstances([claim('w1', 'RELEASED', 2)], [hist(claim('w1', 'RELEASED', 2))]), 2);
});

test('other waves, regions and zones are counted on their own', () => {
  eq(page.reservedInstances([claim('w1', 'RESERVED', 2)], [hist(claim('w2', 'RELEASED', 3))]), 5);
  eq(page.reservedInstances([claim('w1', 'RESERVED', 2)], [hist(claim('w1', 'RELEASED', 3, { region: 'eastus2', reservation: { reservationId: '/r/e', createdUtc: '2026-11-01T14:00:00Z', consumedInstances: 3 } }))]), 5);
  eq(page.reservedInstances([claim('w1', 'RESERVED', 2)], [hist(claim('w1', 'RELEASED', 1, { zone: '2', reservation: { reservationId: '/r/z', createdUtc: '2026-11-01T14:00:00Z', consumedInstances: 1 } }))]), 3);
});

test('a quota check with no reservation is not reserved capacity, live or kept', () => {
  eq(page.reservedInstances([claim('w1', 'QUOTA_VERIFIED', 2, { reservation: null })], [{ claim: claim('w2', 'QUOTA_VERIFIED', 2, { reservation: null }) }, null]), 0);
});

test('the page reads the history folder', () => {
  ok(PAGE.includes("source.listFolder(run, 'capacity-history')"));
});

test('RESERVING-STUCK-1: a reservation released before Azure confirmed it held nobody, live or kept', () => {
  const never = (w) => claim(w, 'RELEASED', 2, { reservation: { reservationId: `/r/${w}`, createdUtc: null, releasedUtc: '2026-11-01T15:00:00Z', consumedInstances: 0 } });
  eq(page.reservedInstances([never('w1')], [hist(never('w2'))]), 0);
});

run('report-released');
