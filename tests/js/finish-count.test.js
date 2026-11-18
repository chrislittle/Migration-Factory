/* FINISH-COUNT-1 (Migrations page half): a machine that Restore this machine
 * left stopped, waiting for Finish the restore, waits for a person.
 *
 * When Azure refuses a data disk swap during a restore, the machine stays
 * stopped and its record holds swapPending (SWAP-REFUSED-AFTER-STOP-1). Its
 * state stays MIGRATED and it has a restore record, so the page counted it as
 * Put back - and the Waiting on people card, the wave's status, the wave's
 * order and the row's "See what to do" all asked the state alone, which is not
 * a problem state. help.js's one definition (machineOutcome) now says
 * attention for it; the page asks that definition too.
 *
 * RUN, not read: the page's own helpers, with help.js's real machineOutcome.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
// eslint-disable-next-line no-eval
globalThis.WORKING_STATES = eval(HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/)[1]);
globalThis.VmfHelp = { machineOutcome: lift('help.js', 'machineOutcome'), outcomeWaitsOnPerson: lift('help.js', 'outcomeWaitsOnPerson') };
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/\nconst PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...globalThis.PROBLEM_STATES];
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.notMovedReasons = () => null;
globalThis.esc = (s) => String(s ?? '');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.CHECKPOINT_TEXT = liftConst('migrations.html', 'CHECKPOINT_TEXT');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.statePill = (state) => `<state:${state}>`;
const liftArrow = (name) => {
  const m = PAGE.match(new RegExp(`\\nconst ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not lift ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
globalThis.isPutBack = liftArrow('isPutBack');
// STATUS-WORDS-1: the wave, the pill and the tiles read help.js's status rule.
const machineStatus = require('./_status').statusRule();
globalThis.VmfHelp.machineStatus = machineStatus;
globalThis.RUNNING_STATUS = liftConst('migrations.html', 'RUNNING_STATUS');
globalThis.WAITING_STATUS = liftConst('migrations.html', 'WAITING_STATUS');
globalThis.ENDED_STATUS = liftConst('migrations.html', 'ENDED_STATUS');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.ago = (iso) => String(iso);
const st = (doc) => machineStatus(doc, {});

const page = liftAll('migrations.html', ['waitsOnPerson', 'vmCategory', 'waveStatus', 'statusCounts', 'shownState',
  'restoredPill', 'statusWord', 'statusPill', 'machinePill', 'checkpointLine']);

const cpKey = Object.keys(globalThis.CHECKPOINT_TEXT)[0];
const swap = (kind) => ({ kind, leftUtc: '2026-10-23T11:00:00Z', error: 'refused', swaps: [{ lun: 1 }], swapped: [] });
const leftByRestore = { vmId: 'a', state: 'MIGRATED', pathCheckpoint: cpKey,
  restore: { restoredUtc: '2026-10-23T11:00:00Z' }, swapPending: swap('restore') };
const restored = { vmId: 'b', state: 'MIGRATED', restore: { restoredUtc: '2026-10-23T11:00:00Z' } };
const migrated = { vmId: 'c', state: 'MIGRATED', pathCheckpoint: cpKey };
const decision = { vmId: 'd', state: 'NEEDS_DECISION' };
const rolledBack = { vmId: 'e', state: 'FAILED_ROLLED_BACK' };
const leftByRollback = { vmId: 'f', state: 'FAILED_NEEDS_ATTENTION', swapPending: swap('rollback') };

test('RUN: the one rule - a machine a restore left stopped waits for a person', () => {
  eq(page.waitsOnPerson(leftByRestore), true, 'the swap left');
  eq(page.waitsOnPerson(decision), true, 'a decision');
  eq(page.waitsOnPerson(rolledBack), true, 'a rollback, which the card always counted');
  eq(page.waitsOnPerson(leftByRollback), true, 'a rollback that left a swap');
  eq(page.waitsOnPerson(restored), false, 'a finished restore');
  eq(page.waitsOnPerson(migrated), false, 'a migrated machine');
  eq(page.waitsOnPerson(null), false, 'no record');
  eq(page.waitsOnPerson({ state: 'PLANNED' }), false, 'a machine that has not started');
});

test('RUN: the status filter puts it under attention', () => {
  eq(page.vmCategory('MIGRATED', {}, leftByRestore), 'attention', 'the swap left');
  eq(page.vmCategory('MIGRATED', {}, restored), 'done', 'a finished restore');
  eq(page.vmCategory('NEEDS_DECISION', {}), 'attention', 'a decision, with no record passed');
  ok(PAGE.includes('vmCategory(v.state, v.entry, v.doc, v.st) === statusFilter'), 'the filter passes the record and its status');
});

test('RUN: a wave with it waits on people, and is not Complete', () => {
  // STATUS-WORDS-1: the wave reads the status of each machine (machineStatus),
  // whose end results are help.js's one definition.
  eq(page.waveStatus([st(migrated), st(leftByRestore)], false)[0], 'Waiting on people', 'the swap left');
  eq(page.waveStatus([st(migrated), st(restored)], false)[0], 'Complete', 'a finished restore');
  eq(page.waveStatus([st(decision)], false)[0], 'Waiting on people', 'a decision');
  ok(/machineStatusOf\(e\.vmId, allVms\.find\(v => v\.vmId === e\.vmId\)\)/.test(PAGE), 'the wave passes each record');
});

test('RUN: its row shows no Restored pill and no progress point from the move', () => {
  eq(page.shownState(leftByRestore), false, 'the state pill gives way');
  eq(page.checkpointLine(leftByRestore), '', 'no progress point');
  ok(page.machinePill(leftByRestore, st(leftByRestore)).includes(globalThis.UX_ACT.finishPill), 'the pill says Stopped: finish the restore');
  eq(page.shownState(leftByRollback), true, 'a rollback that left a swap keeps its progress point');
  // STATUS-WORDS-1: it said Needs attention; it says what a person does.
  ok(page.machinePill(leftByRollback, st(leftByRollback)).includes(globalThis.UX_MISC.statusFinishRollback), 'Stopped: finish the rollback');
  eq(page.shownState(migrated), true, 'a migrated machine keeps its state');
  ok(!/restoredTag/.test(PAGE), 'no second Restored pill in the row: the one status pill says it');
});

test('RUN: the Waiting on people card counts it', () => {
  const renderKpis = lift('migrations.html', 'renderKpis');
  const box = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#kpis' ? box : null);
  globalThis.machinesInRun = (vms) => vms.length;
  globalThis.planDoc = null;
  globalThis.canOperate = () => false;
  globalThis.renderRunActions = () => {};
  globalThis.waitsOnPerson = page.waitsOnPerson;
  globalThis.statusCounts = page.statusCounts;
  globalThis.machineStatusOf = (id, doc) => st(doc);
  renderKpis([migrated, restored, leftByRestore, decision], false);
  const tile = (label) => {
    const m = box.innerHTML.match(new RegExp(`<div class="label">${label}</div><div class="val">(\\d+)</div>`));
    return m ? Number(m[1]) : null;
  };
  eq(tile('Waiting on people'), 2, 'the decision and the swap left');
  eq(tile(globalThis.UX_MISC.putBackTile), 1, 'only the finished restore is put back');
  eq(tile('Migrated'), 1, 'one migrated');
});

test('the wave orders it first, counts it, and offers "See what to do" on its row', () => {
  // STATUS-WORDS-1: by the status, whose waiting group holds the swap left.
  ok(/const rank = \(v\) => \(WAITING_STATUS\.includes\(v\.st\.key\) \|\| v\.st\.key === 'rolledBack'\) \? 0/.test(PAGE), 'the order asks the one rule');
  ok(WAITING_STATUS.includes(st(leftByRestore).key), 'the swap left is in the waiting group');
  ok(/vms = \[\.\.\.vms\]\.sort\(\(a, b\) => rank\(a\) - rank\(b\)/.test(PAGE), 'and sorts by it');
  ok(/const needsSomeone = vms\.filter\(v => rank\(v\) === 0\)\.length;/.test(PAGE), 'needs someone');
  ok(/const inFlight = vms\.filter\(v => rank\(v\) === 1\)\.length;/.test(PAGE), 'in flight');
  ok(/const needsPerson = rank\(v\) === 0;/.test(PAGE), 'the row');
  ok(!/rank\(\w+\.state\)/.test(PAGE), 'nothing ranks by the state alone');
});

run('finish-count');
