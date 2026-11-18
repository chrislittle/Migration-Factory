/* LAB-UX-1: a machine a person restored from a safety copy still said
 * Migrated beside Restored in its row, with "Last saved
 * progress point: Updating the disks" from the move in its panel.
 *
 * PUTBACK-COUNT-1 already counts such a machine as restored, not migrated.
 * The row and the panel now say the same: no Migrated pill, and no progress
 * point from the move.
 *
 * RUN, not read: the page's own shownState and checkpointLine, with help.js's
 * own machineOutcome behind isPutBack.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

globalThis.WORKING_STATES = ['PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'SAFETY_COPY', 'STOPPED', 'CONVERTING', 'STARTING', 'VALIDATING'];
const machineOutcome = lift('help.js', 'machineOutcome');
globalThis.isPutBack = (doc) => machineOutcome(doc) === 'putBack';
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.CHECKPOINT_TEXT = liftConst('migrations.html', 'CHECKPOINT_TEXT');
globalThis.esc = (s) => String(s ?? '');
const page = liftAll('migrations.html', ['shownState', 'checkpointLine']);

const cpKey = Object.keys(globalThis.CHECKPOINT_TEXT)[0];
const migrated = { vmId: 'a', state: 'MIGRATED', pathCheckpoint: cpKey };
const restored = { vmId: 'b', state: 'MIGRATED', pathCheckpoint: cpKey,
  restore: { restoredUtc: '2026-09-30T12:00:00Z', fromCopy: 'pristine', sizeAfter: 'Standard_D2s_v4' } };

test('a migrated machine shows its state and its progress point', () => {
  eq(page.shownState(migrated), true, 'state shown');
  ok(page.checkpointLine(migrated).includes(globalThis.CHECKPOINT_TEXT[cpKey]), 'progress point shown');
});

test('a restored machine shows no Migrated state and no progress point from the move', () => {
  eq(page.shownState(restored), false, 'no Migrated pill');
  eq(page.checkpointLine(restored), '', 'no progress point');
});

test('a machine that is moving keeps its progress point', () => {
  const moving = { vmId: 'c', state: 'CONVERTING', pathCheckpoint: cpKey };
  eq(page.shownState(moving), true, 'state shown');
  ok(page.checkpointLine(moving).length > 0, 'progress point shown');
});

/* machinePill picks the one status pill for a machine, in the row and in the
 * panel. RUN with a stand-in statePill, so the choice is what is measured. */
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.ago = (iso) => String(iso);
globalThis.statePill = (state) => `<state:${state}>`;
// STATUS-WORDS-1: the pill is the status's, from help.js's rule.
const status = require('./_status').statusRule();
const pills = liftAll('migrations.html', ['restoredPill', 'statusWord', 'statusPill', 'machinePill']);
const pill = (doc) => pills.machinePill(doc, status(doc, {}));

test('RUN: a restored machine gets the Restored pill, never its state', () => {
  const p = pill(restored);
  ok(p.includes(`>${globalThis.UX_ACT.wasRestored}</span>`), p);
  ok(!p.includes('<state:'), `no Migrated pill: ${p}`);
});

test('RUN: any other machine gets its state pill', () => {
  eq(pill(migrated), '<state:MIGRATED>', 'migrated');
  eq(pill(null), '<state:PLANNED>', 'no record');
  eq(pill({ state: 'FAILED_NEEDS_ATTENTION', restore: { restoredUtc: 'x' } }),
    '<state:FAILED_NEEDS_ATTENTION>', 'a restore of no readable time ends no stop: its state still matters');
  // STATUS-WORDS-1 (lab finding 69): a restore that worked, after the stop, ends it.
  ok(pill({ state: 'FAILED_NEEDS_ATTENTION', history: [{ tsUtc: '2026-11-04T17:00:00Z', state: 'FAILED_NEEDS_ATTENTION' }],
    restore: { restoredUtc: '2026-11-04T18:00:00Z' } }).includes(`>${globalThis.UX_ACT.wasRestored}</span>`), 'restored after the stop');
});

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
test('the row and the panel both use machinePill, and the panel uses checkpointLine', () => {
  ok(/notMovedPill\(notMoved\) : machinePill\(doc, st, \{/.test(PAGE), 'the row');
  ok(/<p>\$\{machinePill\(doc, machineStatusOf\(vmId, doc\), \{ awaits: awaitsServiceCheck\(doc, latestEvents\), hold: retryHoldOf\(doc, entry\?\.wave, latestEvents\), braked: latestHalted \}\)\} /.test(PAGE), 'the panel');
  ok(!/restoredTag/.test(PAGE), 'the row adds no second Restored pill: the one status says it');
  ok(/const cp = checkpointLine\(doc\);/.test(PAGE), 'the progress point');
});

run('restored-status');
