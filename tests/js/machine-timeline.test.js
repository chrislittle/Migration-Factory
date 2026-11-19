/* TRAIL-1, 2026-09-18. Everything that happened to a machine, in one list.
 *
 * THE DEFECT, on a live install. After a successful put-back, the list headed
 * "What happened, newest first" ended at **Migrated** - while the put-back sat
 * in its own box a few lines above it, and the row in the table said "Put
 * back".
 *
 * The trail was built from the machine's MIGRATION HISTORY, and a put-back is
 * not a migration state. So the record of what happened to a machine was
 * missing the most recent thing that happened to it.
 *
 * The owner: the trail "doesn't cover the put back though. it should."
 *
 * RESTORE-PANEL-TIMELINE-1, 2026-11-17: TRAIL-1 added the restore RECORD, which
 * says only that a restore ended - none of its steps, and nothing of a restore
 * that failed. The trail is now the machine's lines of the run history, by the
 * rule the Activity table uses, with the ends of the history (a stop, Stop this
 * migration, Migrated). tests/js/restore-panel-timeline.test.js draws the
 * panel. These hold the ordering: by TIME, so a put-back lands where it
 * happened.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
for (const n of ['UX_ACT', 'UX_STATE', 'UX_STATE_DONE', 'UX_STEP', 'SAYS_ITSELF', 'STEP_MAP']) {
  globalThis[n] = liftConst('migrations.html', n);
}
// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/const PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...globalThis.PROBLEM_STATES];
globalThis.VmfHelp = { idKey: (id) => String(id == null ? '' : id).toLowerCase() };

const { machineTimeline } = liftAll('migrations.html', ['machineTimeline', 'activityLines', 'timelineLine', 'stepText',
  'foldedCallLines', 'rollbackFollows', 'stepRetried', 'retriedText']);

const T = (mins) => new Date(Date.parse('2026-09-18T20:00:00Z') - mins * 60000).toISOString();
const VM = 'vm-1';
const L = (mins, step, outcome, extra) => Object.assign({ tsUtc: T(mins), step, outcome, vmId: VM }, extra);

const MIGRATED = {
  vmId: VM, state: 'MIGRATED',
  history: [
    { state: 'MIGRATING', tsUtc: T(200), outcome: 'ok', durationSec: 5 },
    { state: 'MIGRATED', tsUtc: T(180), outcome: 'ok', durationSec: 72 },
  ],
};
const MOVE = [L(200, 'CONVERTING', 'start'), L(195, 'CONVERTING', 'ok', { durationSec: 300 }),
  L(190, 'VALIDATING', 'start'), L(181, 'VALIDATING', 'ok', { durationSec: 540 })];
const DONE = 'operator@example.com restored the machine from a safety copy. Note: testing the way back';
const putBack = (mins) => [L(mins + 4, 'restore', 'start'), L(mins + 2, 'azureops:restore:createDisk', 'ok'), L(mins, 'restore', 'ok', { detail: DONE })];

test('without a put-back the trail is the move and its end, newest first', () => {
  const t = machineTimeline(MIGRATED, MOVE);
  eq(t[0].label, UX_STATE.MIGRATED[0], 'the end of the move is newest');
  eq(t[t.length - 1].label, UX_STATE.CONVERTING[0], 'the first step is oldest');
  eq(t.length, 3, 'the end, and the two closing lines: a start line is not news');
});

test('THE REGRESSION: a put-back appears in the trail, with its steps', () => {
  const t = machineTimeline(MIGRATED, [...MOVE, ...putBack(5)]);
  eq(t[0].label, UX_ACT.restoredStep, 'and it is the newest thing that happened');
  eq(t[1].label, UX_STEP.makeDiskFromCopy, 'and the step of the restore under it');
});

test('and who did it, and the note somebody typed, because it is the record of what happened', () => {
  const entry = machineTimeline(MIGRATED, [...MOVE, ...putBack(5)])[0];
  // The engine's end line says it; the panel draws it under the sentence (detail).
  ok(entry.detail.includes('operator@example.com'), entry.detail);
  ok(entry.detail.includes('testing the way back'), entry.detail);
});

test('it lands where it HAPPENED, not simply on top', () => {
  /* A machine migrated again after a put-back. Appending would put the
   * put-back above a migration that came later - a record in the wrong order
   * is worse than one with a gap, because it reads as true. */
  const t = machineTimeline({ ...MIGRATED, history: [...MIGRATED.history, { state: 'MIGRATED', tsUtc: T(1), outcome: 'ok' }] },
    [...MOVE, ...putBack(60), L(2, 'VALIDATING', 'ok')]);
  eq(t[0].tsUtc, T(1), 'the later migration is newest');
  ok(t.findIndex(h => h.label === UX_ACT.restoredStep) > 1, 'and the put-back sits under it');
});

test('a machine with no history and no lines has an empty trail', () => {
  eq(machineTimeline({ vmId: VM, history: [] }, []).length, 0);
  eq(machineTimeline({}, MOVE).length, 0, 'a document with no machine takes no line');
  eq(machineTimeline(null, MOVE).length, 0);
});

test('a line or an entry with no time is not placed at a time it never had', () => {
  /* Sorting on a missing date puts an entry somewhere arbitrary, and the trail
   * is a record - an entry in the wrong place is a false statement. */
  const t = machineTimeline({ ...MIGRATED, history: [...MIGRATED.history, { state: 'SKIPPED', outcome: 'skip' }] },
    [...MOVE, { step: 'restore', outcome: 'ok', vmId: VM, detail: DONE }]);
  eq(t.length, 3, 'they are left out rather than guessed at');
});

run('machine timeline');
