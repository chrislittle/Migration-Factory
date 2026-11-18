/* SWAP-REFUSED-AFTER-STOP-1: a machine a refused data-disk swap left stopped
 * offers Finish the rollback, or Finish the restore - and nothing that would
 * act on it another way.
 *
 * A rollback or a restore whose data-disk swap Azure refused, also when it
 * was tried again, leaves the machine stopped, and its record (swapPending)
 * names each disk that is not back. The page offers the one action that swaps
 * only those disks and starts the machine (the engine's 'finish' operation),
 * in a dialog with Cancel and Escape (hard rule 11), and withholds Restore this
 * machine, which the engine refuses then.
 *
 * RUN, not read: the page's own putBackControls, finishOffered, restoreIndex,
 * retryHeld and askFinish, driven with records shaped as the engine writes
 * them.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.stepText = (e) => `text:${e.step}`;
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: eval('(' + pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js')).match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')') });
// RESTORE-MID-MOVE-1: restoreOffered asks whether the move of the machine ended.
globalThis.VmfHelp.machineAtWork = liftAll('help.js', ['machineHold', 'machineAtWork']).machineAtWork;
// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
// eslint-disable-next-line no-eval
globalThis.PUTBACK_HOLD_MS = eval(PAGE.match(/const PUTBACK_HOLD_MS = (\d+);/)[1]);

const page = liftAll('migrations.html', ['restoreIndex', 'restoreRecordEnds', 'restoreInFlight',
  'restoreCopiesThere', 'restoreOffered', 'finishOffered', 'putBackControls']);
// POWER-ONLY-CHANGED-1: retryHeld asks powerOwed, so both are lifted together.
const { retryHeld } = liftAll('migrations.html', ['powerOwed', 'retryHeld']);

const VM = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/app01';
const at = (n) => new Date(Date.UTC(2026, 9, 23, 12, n, 0)).toISOString();
const ev = (step, outcome, minute, extra = {}) => ({ vmId: VM, step, outcome, tsUtc: at(minute), ...extra });
const NOW = Date.parse(at(10));
const ctl = (d, operate = true) => page.putBackControls(d, VM, operate, NOW);
function seen(events) {
  globalThis.restoresInFlight = page.restoreIndex(events);
}

// A rollback that Azure would not let swap LUN 1 back.
const leftByRollback = () => ({
  vmId: VM, state: 'FAILED_NEEDS_ATTENTION', safety: { snapshotId: 'snap-1', pristineSnapshotId: 'snap-0' },
  captured: { vmConfig: { size: 'Standard_D2ds_v4' } },
  history: [{ tsUtc: at(0), state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', machineState: 'changed', reasonCode: 'dataDiskSwapRefused' }],
  swapPending: { kind: 'rollback', leftUtc: at(0), error: 'OperationNotAllowed', swaps: [{ lun: 1, name: 'app01-data1', diskId: '/d/new1', diskName: 'app01-data1-d1-asitwas-x' }], swapped: [] },
});
// A restore of a migrated machine, the same.
const leftByRestore = () => ({
  vmId: VM, state: 'MIGRATED', safety: { snapshotId: 'snap-1', pristineSnapshotId: 'snap-0' },
  captured: { vmConfig: { size: 'Standard_D2ds_v4' } },
  history: [{ tsUtc: at(0), state: 'MIGRATED', outcome: 'ok' }],
  restore: { restoredUtc: at(1) },
  swapPending: { kind: 'restore', leftUtc: at(1), error: 'OperationNotAllowed', swaps: [{ lun: 1, name: 'app01-data1', diskId: '/d/new1', diskName: 'app01-data1-d1-restored-x' }], swapped: [] },
});

test('a rollback left a swap: Finish the rollback is offered, and Restore is not', () => {
  seen([]);
  eq(ctl(leftByRollback()), { busy: false, restore: false, finish: 'rollback' }, 'only the finish');
});

test('a restore left a swap: Finish the restore is offered, and Restore is not', () => {
  seen([]);
  eq(ctl(leftByRestore()), { busy: false, restore: false, finish: 'restore' }, 'only the finish');
});

test('no swap left: no finish, and Restore as before', () => {
  seen([]);
  const d = leftByRollback(); delete d.swapPending;
  d.history[0].reasonCode = 'rollbackFailed';
  eq(ctl(d), { busy: false, restore: true, finish: null }, 'as before');
});

test('only for a person who may change machines, and never while a job holds the machine', () => {
  seen([]);
  eq(ctl(leftByRollback(), false).finish, null, 'a viewer');
  seen([ev('finish', 'start', 1, { correlationId: 'op-1' })]);
  const c = ctl(leftByRollback());
  eq(c.busy, true, 'a finish runs');
  eq(c.finish, null, 'not twice');
});

test('a finish is ended by its own ok, warn or fail line, or by the engine fail line with its id', () => {
  for (const outcome of ['ok', 'warn', 'fail']) {
    seen([ev('finish', 'start', 1), ev('finish', outcome, 2)]);
    eq(ctl(leftByRollback()).busy, false, `ended by ${outcome}`);
  }
  seen([ev('finish', 'start', 1), ev('finish', 'info', 2)]);
  eq(ctl(leftByRollback()).busy, true, 'an info line leaves it running');
  seen([ev('finish', 'start', 1, { correlationId: 'op-1' }), ev('engine:finish', 'fail', 2, { correlationId: 'op-2' })]);
  eq(ctl(leftByRollback()).busy, true, 'another job\'s fail line does not end it');
  seen([ev('finish', 'start', 1, { correlationId: 'op-1' }), ev('engine:finish', 'fail', 2, { correlationId: 'op-1' })]);
  eq(ctl(leftByRollback()).busy, false, 'its own engine fail line ends it');
});

test('a swap left holds Try this machine again, and the reason names the finish', () => {
  ok(retryHeld(leftByRollback()), 'after a rollback');
  ok(retryHeld(leftByRestore()), 'after a restore, whose record is newer than any stop');
  ok(/Finish the rollback or Finish the restore/.test(UX_ACT.retryHeldSwap), UX_ACT.retryHeldSwap);
  ok(PAGE.includes('esc(doc.swapPending ? UX_ACT.retryHeldSwap : UX_ACT.retryHeld)'), 'the held line says which');
});

test('the button names the action by what left it, in the product\'s own words', () => {
  eq(UX_ACT.finishRollback, 'Finish the rollback', 'rollback');
  eq(UX_ACT.finishRestore, 'Finish the restore', 'restore');
  ok(UX_STEP.finishStart && UX_STEP.finishDone && UX_STEP.finishFailed, 'the activity says each');
});

test('RUN askFinish: a dialog with a note, which starts the engine\'s finish for this machine', async () => {
  const calls = [];
  let modal = null;
  globalThis.UX_ACT = UX_ACT;
  globalThis.openModal = (m) => { modal = m; };
  globalThis.noteField = () => ({ id: 'note', type: 'text' });
  globalThis.runSeg = () => 'run-x';
  globalThis.apiFetch = async (route, body) => { calls.push({ route, body }); return {}; };
  // FINISH-EMPTY-LUN-WORDS-1: each row's words come from finishDiskLine.
  const { askFinish } = liftAll('migrations.html', ['finishDiskLine', 'askFinish']);
  askFinish(VM, leftByRollback());
  ok(modal, 'the dialog opened');
  eq(modal.title, UX_ACT.finishRollback, 'its title is the action');
  ok(modal.desc.includes('app01-data1'), `it names the disk the LUN keeps: ${modal.desc}`);
  ok(modal.desc.includes('app01-data1-d1-asitwas-x'), 'and the disk made from its copy');
  eq(modal.fields.map(f => f.id), ['note'], 'a note, as every action that changes a machine');
  await modal.onConfirm({ note: 'Azure accepts it now' });
  eq(calls, [{ route: 'runs/run-x/engine/finish', body: { vmId: VM, note: 'Azure accepts it now' } }], 'the engine finish, for this machine');
  askFinish(VM, leftByRestore());
  eq(modal.title, UX_ACT.finishRestore, 'a restore: Finish the restore');
});

test('the panel paints the button, and wires it to the dialog', () => {
  ok(PAGE.includes('const finishBtn = putBack.finish'), 'the button comes from putBackControls');
  // DIALOG-STALE-1: through panelDialog, so the dialog keeps its machine.
  ok(PAGE.includes("$('#finish-btn')?.addEventListener('click', () => panelDialog(vmId, () => askFinish(vmId, doc)));"), 'and opens the dialog');
  ok(/\$\{finishBtn\}/.test(PAGE), 'and is painted');
});

test('RUN machinePill: the row of a machine a restore left stopped says so, not Restored', () => {
  globalThis.esc = (s) => String(s);
  globalThis.UX_ACT = UX_ACT;
  globalThis.statePill = (s) => `state:${s}`;
  globalThis.restoredPill = () => 'restored';
  // STATUS-WORDS-1: the pill is the status's, from help.js's rule.
  globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
  globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
  globalThis.ago = (iso) => String(iso);
  const status = require('./_status').statusRule();
  const pills = liftAll('migrations.html', ['statusWord', 'statusPill', 'machinePill']);
  const pill = (doc) => pills.machinePill(doc, status(doc, {}));
  ok(pill(leftByRestore()).includes(UX_ACT.finishPill), 'stopped, finish the restore');
  eq(pill({ ...leftByRestore(), swapPending: undefined }), 'restored', 'without a swap left, as before');
  // STATUS-WORDS-1: it said Needs attention; it says what a person does.
  ok(pill(leftByRollback()).includes(globalThis.UX_MISC.statusFinishRollback), 'a rollback that left a swap says Stopped: finish the rollback');
});

run('finish-swap');