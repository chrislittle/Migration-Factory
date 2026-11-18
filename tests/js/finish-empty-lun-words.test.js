/* FINISH-EMPTY-LUN-WORDS-1: the Finish dialog says what is on each LUN.
 *
 * It said for every row of the swap record "On LUN n, the disk X is still
 * attached". For a LUN with no disk, a LUN the product did not read and a LUN
 * that holds a third disk that is false. The record now says which one it is
 * (swapPending.swaps[].lunHolds, vm-state v38), and the dialog says it.
 *
 * FINISH-TEMP-DISK-LEFT-1 (folded in): a row whose LUN runs on the temporary
 * disk made from the copy (oldTemporary) says that disk is not attached after
 * Finish, and that the daily cleanup deletes it.
 *
 * RUN, not read: the page's own finishDiskLine and askFinish.
 */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_ACT = UX_ACT;
const { finishDiskLine, askFinish } = liftAll('migrations.html', ['finishDiskLine', 'askFinish']);

const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app01';
const row = (extra) => ({ lun: 1, name: 'app01-data1', oldDiskId: '/d/app01-data1', diskId: '/d/app01-data1-restored', diskName: 'app01-data1-restored', snapshotId: '/s/copy-d1', ...extra });

test('had: the disk the LUN had is still attached, and the disk made from its copy waits', () => {
  const w = finishDiskLine(row({ lunHolds: 'had' }));
  eq(w, 'On LUN 1, the disk app01-data1 is still attached, and the disk app01-data1-restored made from its copy waits.', w);
});

test('none: the LUN has no disk - never "still attached"', () => {
  const w = finishDiskLine(row({ lunHolds: 'none' }));
  ok(w.startsWith('LUN 1 has no disk. The disk app01-data1-restored made from its copy waits to go on it.'), w);
  ok(!/still attached/.test(w), w);
  ok(!/app01-data1 /.test(w.replace('app01-data1-restored', '')), `it does not name the disk the LUN had as on it: ${w}`);
});

test('none, and the row names no copy: the record proves nothing, and the dialog says this stops (OLD-STATE-READERS-FINISH-1)', () => {
  const w = finishDiskLine(row({ lunHolds: 'none', snapshotId: null }));
  ok(w.includes('LUN 1 has no disk, and the record does not prove which disk goes on it.'), w);
  ok(!/checks only that the disk exists/.test(w), w);
  ok(finishDiskLine(row({ lunHolds: 'none' })).includes('waits to go on it'), 'a row with its copy says the disk waits');
});

test('none, and the record names no disk it can prove (a disk made from another copy): the dialog says this stops', () => {
  const w = finishDiskLine(row({ lunHolds: 'none', diskId: '' }));
  ok(w.includes('LUN 1 has no disk, and the record does not prove which disk goes on it.'), w);
  ok(!/waits to go on it/.test(w), w);
});

test('notRead: the product did not read the LUN, and Finish reads it first', () => {
  const w = finishDiskLine(row({ lunHolds: 'notRead' }));
  ok(w.includes('The product did not read which disk is on LUN 1 after the swap stopped.'), w);
  ok(w.includes('This reads the LUN first.'), w);
  ok(w.includes('only when the LUN has the disk app01-data1 or no disk'), w);
  ok(!/still attached/.test(w), w);
});

test('other: a third disk is on the LUN', () => {
  const w = finishDiskLine(row({ lunHolds: 'other' }));
  ok(w.includes('LUN 1 has a disk that is not app01-data1 and not app01-data1-restored.'), w);
  ok(!/still attached/.test(w), w);
});

test('MIGRATIONS-PAGE-OLD-READERS-1: every writer of this version records lunHolds, so the words for a record without it are gone', () => {
  // Every row of a swap that is left is written by New-VmfSwapLeftRow with
  // -Holds, or set by Set-VmfEmptyLunRow (OldRecordSweepPages.Tests.ps1).
  eq(UX_ACT.finishDiskNoRecord, undefined, 'the string is gone');
  ok(!PAGE.includes('finishDiskNoRecord'), 'and the page names it nowhere');
  // A damaged row is said as not read - the engine reads every LUN before it changes one.
  const w = finishDiskLine(row({}));
  eq(w, finishDiskLine(row({ lunHolds: 'notRead' })), w);
  ok(!/still attached/.test(w), w);
});

test('FINISH-TEMP-DISK-LEFT-1: a LUN that runs on its temporary disk says that disk is not attached after this, and the daily cleanup deletes it', () => {
  const w = finishDiskLine(row({ lunHolds: 'had', name: 'app01-data1-rtmp', diskName: 'app01-data1', oldTemporary: true }));
  ok(w.startsWith('On LUN 1, the disk app01-data1-rtmp is still attached, and the disk app01-data1 made from its copy waits.'), w);
  ok(w.includes('The disk app01-data1-rtmp is the temporary disk made from the copy.'), w);
  ok(w.includes('the daily cleanup deletes it when the move of this machine ends'), w);
  ok(!finishDiskLine(row({ lunHolds: 'had' })).includes('temporary disk'), 'only that row');
});

test('RUN askFinish: one line per row, and "attaches" when a LUN has no disk', () => {
  let modal = null;
  globalThis.openModal = (m) => { modal = m; };
  globalThis.noteField = () => ({ id: 'note', type: 'text' });
  globalThis.runSeg = () => 'run-x';
  globalThis.apiFetch = async () => ({});
  askFinish(VM, { swapPending: { kind: 'restore', swaps: [row({ lunHolds: 'had', lun: 0, name: 'd0', diskName: 'd0-r' }), row({ lunHolds: 'none' })] } });
  ok(modal.desc.startsWith(UX_ACT.finishDesc), modal.desc);
  ok(modal.desc.includes('On LUN 0, the disk d0 is still attached'), modal.desc);
  ok(modal.desc.includes('LUN 1 has no disk.'), modal.desc);
  ok(modal.desc.endsWith(UX_ACT.finishWhatAttach), modal.desc);
  ok(/attaches/.test(UX_ACT.finishWhatAttach), UX_ACT.finishWhatAttach);
  askFinish(VM, { swapPending: { kind: 'rollback', swaps: [row({ lunHolds: 'had' })] } });
  ok(modal.desc.endsWith(UX_ACT.finishWhat), 'with no empty LUN, the words say swaps');
});

test('the page uses each new string, and the dialog goes through finishDiskLine only', () => {
  for (const k of ['finishDiskEmpty', 'finishDiskEmptyUnproven', 'finishDiskOther', 'finishDiskNotRead',
    'finishDiskReadFirst', 'finishDiskTemp', 'finishWhatAttach']) {
    ok(typeof UX_ACT[k] === 'string' && UX_ACT[k].length, k);
    ok(PAGE.includes(`UX_ACT.${k}`), `${k} is used`);
  }
  ok(PAGE.includes('(sp.swaps ?? []).map(finishDiskLine)'), 'askFinish builds each line with finishDiskLine');
});

run('finish-empty-lun-words');
