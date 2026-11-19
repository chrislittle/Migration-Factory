/* COPY-DELETE-LOCK-RACE-1: the Activity list of the Migrations page, after a
 * safety copy delete that Azure refused.
 *
 * MEASURED on the lab install, 2026-11-14 (Delete this migration, with Delete
 * the copies as well): the delete of one copy failed with HTTP 409
 * ScopeLocked, and the list marked that line "failed once, then succeeded on
 * retry". No call was tried again. A failed line is marked recovered when a
 * later ok line has the same step and machine - and a copy line has no
 * machine, so the deletes of the OTHER copies, which worked, made the failed
 * one read as recovered.
 *
 * Now: a line is recovered only by a later ok line about the same copy
 * (snapshotId), and an Azure call line that the product tries again shows its
 * cause, never the words of a success ("Deleted the safety copy.").
 *
 * RUN, not read: the page's own renderEvents and stepText.
 */
'use strict';
const { extract, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_RAN = liftConst('migrations.html', 'UX_RAN');
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.ago = () => '5 minutes ago';
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: (id) => String(id == null ? '' : id).toLowerCase() });
const helpers = ['foldedCallLines', 'retriedText', 'stepRetried', 'rollbackFollows', 'activityLines'].filter(n => { try { extract('migrations.html', n); return true; } catch { return false; } });
const page = liftAll('migrations.html', ['stepText', 'renderEvents', 'feedFailNote', ...helpers]);

function rows(events, whole) {
  const drawn = [];
  const tbody = { set innerHTML(v) { drawn.length = 0; if (v) { drawn.push(v); } }, get innerHTML() { return drawn.join(''); },
    insertAdjacentHTML(_where, html) { drawn.push(html); } };
  const el = () => ({ classList: { toggle() { } }, hidden: false, textContent: '' });
  const parts = { '#event-table tbody': tbody, '#event-scroll': el(), '#ev-toggle': el(), '#ev-count': el() };
  globalThis.$ = (sel) => parts[sel];
  globalThis.FEED_RECENT = 30;
  globalThis.showWholeLog = Boolean(whole);
  globalThis.toggleWholeLog = () => { };
  page.renderEvents(events);
  return drawn.filter(r => r.startsWith('<tr'));
}
const at = (min, sec) => `2026-11-14T22:${String(min).padStart(2, '0')}:${String(sec ?? 0).padStart(2, '0')}Z`;
const SNAP = (n) => `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/snapshots/${n}`;
const LOCKED = (n) => `HTTP 409 ScopeLocked - Deleting snapshot '${SNAP(n)}' failed with 409: the scope is locked.`;

/* The lab's delete, as the engine writes it: copy d0 refused, the other copies deleted. */
const lab = [
  { tsUtc: at(10, 0), step: 'discardCopy', outcome: 'info', detail: 'The product removes the lock from the safety copy vm-pristine-d0. Then it deletes the copy.', snapshotId: SNAP('vm-pristine-d0') },
  { tsUtc: at(10, 1), step: 'azureops:unlockSnapshot', outcome: 'ok', snapshotId: SNAP('vm-pristine-d0') },
  { tsUtc: at(10, 2), step: 'azureops:removeSnapshot', outcome: 'fail', detail: LOCKED('vm-pristine-d0'), snapshotId: SNAP('vm-pristine-d0') },
  { tsUtc: at(10, 3), step: 'azureops:lockSnapshot', outcome: 'ok', snapshotId: SNAP('vm-pristine-d0') },
  { tsUtc: at(10, 4), step: 'discardCopy', outcome: 'fail', detail: `The product did not delete the safety copy vm-pristine-d0: ${LOCKED('vm-pristine-d0')} The product put the lock back on the copy.`, snapshotId: SNAP('vm-pristine-d0') },
  { tsUtc: at(10, 5), step: 'azureops:unlockSnapshot', outcome: 'ok', snapshotId: SNAP('vm-pristine-d1') },
  { tsUtc: at(10, 6), step: 'azureops:removeSnapshot', outcome: 'ok', snapshotId: SNAP('vm-pristine-d1') },
];

test('THE LAB DEFECT: a refused delete of one copy is not marked recovered by the delete of another copy', () => {
  for (const whole of [false, true]) {
    const r = rows(lab, whole);
    eq(r.filter(x => x.includes(UX_STEP.recoveredNote)).length, 0, `lines that say "${UX_STEP.recoveredNote}" (whole log: ${whole})`);
    ok(r.some(x => x.includes('pill bad') && x.includes('vm-pristine-d0')), 'the refused delete stays red');
  }
});

test('a refused delete of a copy that a later delete of the SAME copy finished is still marked recovered', () => {
  const same = [
    { tsUtc: at(20, 0), step: 'azureops:removeSnapshot', outcome: 'fail', detail: LOCKED('c1'), snapshotId: SNAP('c1') },
    { tsUtc: at(20, 30), step: 'azureops:removeSnapshot', outcome: 'ok', snapshotId: SNAP('c1') },
  ];
  eq(rows(same, true).filter(x => x.includes(UX_STEP.recoveredNote)).length, 1, 'the same copy');
});

test('an Azure call line that the product tries again shows its cause, never the words of a success', () => {
  const retry = [{ tsUtc: at(30), step: 'azureops:removeSnapshot', outcome: 'retry', detail: LOCKED('c2'), snapshotId: SNAP('c2'), attempt: 1 }];
  for (const whole of [false, true]) {
    const r = rows(retry, whole);
    eq(r.length, 1, 'one line');
    ok(!r[0].includes(UX_STEP.deleteCopy), `never "${UX_STEP.deleteCopy}"`);
    ok(r[0].includes('ScopeLocked'), 'the cause');
    ok(!r[0].includes('pill bad'), 'not red: the product tries again');
  }
  eq(page.stepText({ step: 'azureops:removeSnapshot', outcome: 'ok', snapshotId: SNAP('c2') }), UX_STEP.deleteCopy, 'the ok line keeps its words');
});

run('copy-delete-lock-race');
