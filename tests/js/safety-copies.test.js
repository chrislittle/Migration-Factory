/* RETAIN-UX-1: what the daily cleanup will do, computed on the page from the
 * engine's own record. These cases hold the page's arithmetic to the engine's
 * rule in Get-VmfExpiredSafetyCopies: due once MIGRATED for keepSnapshotDays
 * (absent = 7); not migrated = in use; unreadable = kept and said; deleted =
 * recorded by retention.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const ledger = lift('help.js', 'safetyCopyLedger');
const summary = lift('help.js', 'safetyCopySummary');
const nextPass = lift('help.js', 'nextRetentionPassUtc');
// The helper reads a constant from its enclosing scope; the harness lifts the
// function alone, so the constant is supplied here at the value the page uses.
global.RETENTION_DEFAULT_DAYS = 7;

const VM = (n) => `/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${n}`;
const doc = (n, state, migratedUtc, safety, extra) => Object.assign({
  vmId: VM(n), wave: 'w1', state,
  history: migratedUtc ? [{ state: 'PLANNED', tsUtc: '2026-09-01T00:00:00Z' }, { state: 'MIGRATED', tsUtc: migratedUtc }] : [{ state: 'PLANNED', tsUtc: '2026-09-01T00:00:00Z' }],
  safety: Object.assign({ pristineSnapshotId: `/snap/${n}-pristine`, snapshotId: `/snap/${n}`, pristineSnapshotLocked: true, snapshotLocked: true }, safety || {}),
}, extra || {});
const entry = (n, keepDays, wave = 'w1') => ({ vmId: VM(n), wave, policy: keepDays === undefined ? {} : { keepSnapshotDays: keepDays } });
const NOW = '2026-09-10T12:00:00Z';

test('RESTORE-END-JOB-1: a restore that runs or starts again keeps the copies, as the engine does', () => {
  const job = { kind: 'restore', operationId: 'op-1', phase: 'stopped' };
  const rows = ledger([doc('a', 'MIGRATED', '2026-08-01T10:00:00Z', null, { putBackJob: job })], [entry('a', 7)], NOW);
  eq(rows[0].status, 'restoreRuns', 'past its retention, and still kept');
  eq(rows[0].dueUtc, null, 'no due date');
});

test('FINISH-END-JOB-1: a finish that runs or starts again keeps the copies, and the card says it is a finish', () => {
  const job = { kind: 'finish', operationId: 'op-1', phase: 'dataSwapped', options: { finishes: 'rollback' } };
  const rows = ledger([doc('a', 'MIGRATED', '2026-08-01T10:00:00Z', null, { putBackJob: job })], [entry('a', 7)], NOW);
  eq(rows[0].status, 'finishRuns', 'past its retention, and still kept');
  eq(rows[0].dueUtc, null, 'no due date');
  const { liftConst } = require('./_harness');
  globalThis.UX_COPIES = liftConst('migrations.html', 'UX_COPIES');
  const cell = lift('migrations.html', 'copiesStatusCell');
  eq(cell({ status: 'finishRuns' }), globalThis.UX_COPIES.statusFinishRuns, 'its own words');
  ok(/^Kept\. Finish the rollback or Finish the restore/.test(globalThis.UX_COPIES.statusFinishRuns), 'it names the finish');
});

test('RESUME-GIVEUP-KEEP-1: a restore the service stopped trying keeps the copies until a person restores or rebuilds the machine', () => {
  const gaveUp = { kind: 'restore', operationId: 'op-1', phase: 'shellDeleted', ended: { outcome: 'fail', reason: 'gaveUp' } };
  eq(ledger([doc('a', 'MIGRATED', '2026-08-01T10:00:00Z', null, { putBackJob: gaveUp })], [entry('a', 7)], NOW)[0].status, 'restoreStopped', 'gave up');
  const held = { kind: 'restore', operationId: 'op-2', phase: 'made', ended: { outcome: 'fail' }, held: { operationId: 'op-1' } };
  eq(ledger([doc('a', 'MIGRATED', '2026-08-01T10:00:00Z', null, { putBackJob: held })], [entry('a', 7)], NOW)[0].status, 'restoreStopped', 'a later restore that failed keeps the hold');
  const ended = { kind: 'restore', operationId: 'op-1', phase: 'made', ended: { outcome: 'fail' } };
  eq(ledger([doc('a', 'MIGRATED', '2026-08-01T10:00:00Z', null, { putBackJob: ended })], [entry('a', 7)], NOW)[0].status, 'due', 'an ended restore holds nothing');
});
test('RESUME-GIVEUP-KEEP-1: the Safety copies card says why the copies are kept, in its own words', () => {
  const { liftConst } = require('./_harness');
  globalThis.UX_COPIES = liftConst('migrations.html', 'UX_COPIES');
  const cell = lift('migrations.html', 'copiesStatusCell');
  eq(cell({ status: 'restoreRuns' }), globalThis.UX_COPIES.statusRestoreRuns, 'a restore that runs or starts again');
  eq(cell({ status: 'restoreStopped' }), globalThis.UX_COPIES.statusRestoreStopped, 'a restore that needs a person');
  ok(/needs a person/.test(globalThis.UX_COPIES.statusRestoreStopped), 'it says the machine needs a person');
});
test('a migrated machine inside its retention is WAITING, with the due date the engine would use', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-08T10:00:00Z')], [entry('a', 7)], NOW);
  eq(rows.length, 1, 'one row');
  eq(rows[0].status, 'waiting', 'status');
  eq(rows[0].dueUtc, '2026-09-15T10:00:00.000Z', 'migrated + 7 days');
  eq(rows[0].copies, 2, 'two copies');
  eq(rows[0].locked, 2, 'both locked');
  eq(rows[0].keepDays, 7, 'keep');
});

test('SAFETY-RETRY-1: the copies of an earlier attempt are counted - retention deletes them with the current ones', () => {
  const d = doc('a', 'MIGRATED', '2026-09-08T10:00:00Z', {
    earlierCopies: [{ pristineSnapshotId: '/snap/a-pristine', snapshotId: '/snap/a', pristineSnapshotLocked: true, snapshotLocked: false }],
    pristineSnapshotId: '/snap/a-pristine-a2', snapshotId: '/snap/a-a2' });
  const rows = ledger([d], [entry('a', 7)], NOW);
  eq(rows[0].copies, 4, 'two of this attempt, two kept from the earlier one');
  eq(rows[0].locked, 3, 'the earlier prepared copy was not locked');
});
test('SAFETY-ALL-1: every data disk\'s copies count, on this attempt and an earlier one, with their locks', () => {
  const rec = (lun, id, locked) => ({ lun, diskId: `/disk/${lun}`, snapshotId: id, locked });
  const d = doc('a', 'MIGRATED', '2026-09-08T10:00:00Z', {
    pristineDataCopies: [rec(0, '/snap/a-pristine-d0', true), rec(1, '/snap/a-pristine-d1', null)],
    dataCopies: [rec(0, '/snap/a-d0', true), rec(1, null, null)],
    earlierCopies: [{ pristineSnapshotId: '/snap/a-old', pristineSnapshotLocked: true,
                      pristineDataCopies: [rec(0, '/snap/a-old-d0', true)], dataCopies: [] }] });
  const rows = ledger([d], [entry('a', 7)], NOW);
  eq(rows[0].copies, 7, 'two OS copies, three data copies (one not taken yet), and two from the earlier attempt');
  eq(rows[0].locked, 6, 'the pristine copy of LUN 1 is not locked');
  eq(summary(rows).unlocked, 1, 'so the card warns about one copy');
});

test('past its retention it is DUE for the next pass', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-01T10:00:00Z')], [entry('a', 7)], NOW);
  eq(rows[0].status, 'due', 'status');
});

test('an absent retention is the default of 7, exactly as the engine reads it', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-08T10:00:00Z')], [entry('a')], NOW);
  eq(rows[0].keepDays, 7, 'default');
  eq(rows[0].dueUtc, '2026-09-15T10:00:00.000Z', 'due');
});

test('zero days is due the moment the machine is migrated - by the next pass, not "as soon as"', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-10T11:59:00Z')], [entry('a', 0)], NOW);
  eq(rows[0].status, 'due', 'due at once');
});

test('a machine that is not migrated keeps its copies: they are the way back', () => {
  const rows = ledger([doc('b', 'CONVERTING', null)], [entry('b', 0)], NOW);
  eq(rows[0].status, 'inUse', 'in use');
  eq(rows[0].dueUtc, null, 'no due date');
});

test('an unreadable retention keeps the copies and says so, never "delete"', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-01T10:00:00Z')], [entry('a', 'soon')], NOW);
  eq(rows[0].status, 'unreadable', 'unreadable');
  const neg = ledger([doc('a', 'MIGRATED', '2026-09-01T10:00:00Z')], [entry('a', -1)], NOW);
  eq(neg[0].status, 'unreadable', 'negative is unreadable too');
});

test('copies retention already deleted are reported as deleted, not counted as kept', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-01T10:00:00Z', {}, { retention: { deletedUtc: '2026-09-09T03:03:00Z', deletedBy: 'retention (scheduled)' } })], [entry('a', 7)], NOW);
  eq(rows[0].status, 'deleted', 'deleted');
  eq(rows[0].deletedUtc, '2026-09-09T03:03:00Z', 'when');
});

test('a copy taken before SAFETY-3, or by an identity that could not lock, counts as unlocked', () => {
  const rows = ledger([doc('a', 'MIGRATED', '2026-09-08T10:00:00Z', { pristineSnapshotLocked: null, snapshotLocked: false })], [entry('a', 7)], NOW);
  eq(rows[0].locked, 0, 'none locked');
  const one = ledger([doc('a', 'MIGRATED', '2026-09-08T10:00:00Z', { pristineSnapshotId: null, pristineSnapshotLocked: null })], [entry('a', 7)], NOW);
  eq(one[0].copies, 1, 'one copy'); eq(one[0].locked, 1, 'and it is locked');
});

test('machines with no copies at all are simply absent', () => {
  eq(ledger([doc('a', 'MIGRATED', '2026-09-08T10:00:00Z', { pristineSnapshotId: null, snapshotId: null })], [entry('a', 7)], NOW).length, 0, 'absent');
  eq(ledger([{ vmId: VM('x'), state: 'PLANNED', history: [] }], [], NOW).length, 0, 'no safety block');
});

test('the summary counts copies, not machines, and finds the earliest due date', () => {
  const rows = ledger([
    doc('a', 'MIGRATED', '2026-09-08T10:00:00Z'),                                  // waiting, due 15th
    doc('b', 'MIGRATED', '2026-09-01T10:00:00Z'),                                  // due
    doc('c', 'CONVERTING', null, { pristineSnapshotLocked: false }),               // in use, one unlocked
    doc('d', 'MIGRATED', '2026-09-01T10:00:00Z', {}, { retention: { deletedUtc: '2026-09-09T03:03:00Z' } }),
  ], [entry('a', 7), entry('b', 7), entry('c', 7), entry('d', 7)], NOW);
  const s = summary(rows);
  eq(s.machines, 3, 'kept machines');
  eq(s.copies, 6, 'kept copies');
  eq(s.waiting, 2, 'waiting'); eq(s.due, 2, 'due'); eq(s.inUse, 2, 'in use');
  eq(s.unlocked, 1, 'one unlocked copy');
  eq(s.deleted, 2, 'deleted copies');
  eq(s.earliestDueUtc, '2026-09-08T10:00:00.000Z', 'b is due already, so its date is the earliest');
});

test('the next pass is 03:30 UTC (the timer schedule), today if still ahead, else tomorrow', () => {
  eq(nextPass('2026-09-10T01:00:00Z'), '2026-09-10T03:30:00.000Z', 'today');
  eq(nextPass('2026-09-10T03:30:00Z'), '2026-09-11T03:30:00.000Z', 'exactly at the pass counts as done');
  eq(nextPass('2026-09-10T12:00:00Z'), '2026-09-11T03:30:00.000Z', 'tomorrow');
});

/* RETENTION-CARD-CYCLE-1: the daily cleanup is a cycle of hourly passes
 * (PERF-RETENTION-TIMEOUT-1). The record says where the cycle is:
 * resumeAtRunId is the migration the next pass starts at, null when the cycle
 * has examined every migration; nextPassUtc is the next pass with work. The
 * card read only the schema 1 fields, so an unfinished cycle read as a day
 * that was done, with its next pass at 03:30 tomorrow. */
const { liftAll } = require('./_harness');
const passHelp = liftAll('help.js', ['nextRetentionPassUtc', 'retentionPassFacts']);
const facts = passHelp.retentionPassFacts;
const cycle = (extra) => Object.assign({
  schemaVersion: 2, cycleStartedUtc: '2026-11-02T03:30:01Z', lastPassUtc: '2026-11-02T09:30:02Z', finishedUtc: '2026-11-02T09:34:40Z',
  passesInCycle: 7, runsInStore: 40, runsExamined: 23, runsWithCopiesDue: 2, machinesDue: 3,
  executionsStarted: [{ runId: 'p1/mig-a', machines: 3, execution: 'vmf-engine-x' }], failures: [],
  resumeAtRunId: 'p1/mig-q', resumeStops: 0, nextPassUtc: '2026-11-02T10:30:00Z',
}, extra || {});

test('RETENTION-CARD-CYCLE-1: an unfinished cycle says so, counts the migrations examined of those in the store, and names the next hourly pass', () => {
  const f = facts(cycle(), '2026-11-02T09:50:00Z');
  eq(f.ran, true, 'the cleanup ran');
  eq(f.unfinished, true, 'resumeAtRunId set: the cycle is not complete');
  eq(f.examined, 23, 'examined so far');
  eq(f.inStore, 40, 'of the migrations in the store');
  eq(f.due, 3, 'machines due');
  eq(f.started, 1, 'engine jobs started');
  eq(f.startedUtc, '2026-11-02T03:30:01Z', 'the cycle started at its first pass, not at the last one');
  eq(f.nextUtc, '2026-11-02T10:30:00.000Z', 'the next pass from the record, not 03:30 tomorrow');
});

test('RETENTION-CARD-CYCLE-1: a complete cycle reads as it did, with the next pass from the record', () => {
  const f = facts(cycle({ resumeAtRunId: null, runsExamined: 40, nextPassUtc: '2026-11-03T03:30:00Z' }), '2026-11-02T09:50:00Z');
  eq(f.unfinished, false, 'null resumeAtRunId: every migration examined');
  eq(f.nextUtc, '2026-11-03T03:30:00.000Z', 'the next cycle');
  eq(facts(cycle({ resumeAtRunId: '' }), '2026-11-02T09:50:00Z').unfinished, false, 'an empty run id is no run to start at');
});

test('RETENTION-CARD-CYCLE-1: a schema 1 record, or no record, names the next 03:30 UTC as before', () => {
  const old = { schemaVersion: 1, lastPassUtc: '2026-11-02T03:30:02Z', runsExamined: 3, machinesDue: 1, executionsStarted: [], failures: [],
                resumeAtRunId: 'ignored', nextPassUtc: '2026-11-02T10:30:00Z' };
  const f = facts(old, '2026-11-02T09:50:00Z');
  eq(f.ran, true, 'it ran');
  eq(f.unfinished, false, 'schema 1 has no cycle: read as a finished day');
  eq(f.nextUtc, '2026-11-03T03:30:00.000Z', 'schema 1: nextRetentionPassUtc');
  eq(f.startedUtc, '2026-11-02T03:30:02Z', 'schema 1: the pass start');
  const none = facts(null, '2026-11-02T09:50:00Z');
  eq(none.ran, false, 'no record');
  eq(none.nextUtc, '2026-11-03T03:30:00.000Z', 'no record: the next 03:30 UTC');
  eq(facts({ schemaVersion: 2 }, '2026-11-02T09:50:00Z').ran, false, 'a record with no pass start is not a pass');
});

test('RETENTION-CARD-CYCLE-1: a next pass the record names in the past is not shown; the timer rule names the next one', () => {
  // The host stopped a pass, or the page was open a long time: the record's
  // time has gone by. The timer fires at half past every hour
  // (Get-VmfRetentionNextPassUtc), and a complete cycle waits for 03:30 UTC.
  eq(facts(cycle({ nextPassUtc: '2026-11-02T08:30:00Z' }), '2026-11-02T09:50:00Z').nextUtc, '2026-11-02T10:30:00.000Z', 'unfinished: the next half past');
  eq(facts(cycle({ nextPassUtc: '2026-11-02T08:30:00Z' }), '2026-11-02T09:10:00Z').nextUtc, '2026-11-02T09:30:00.000Z', 'unfinished: this hour, still ahead');
  eq(facts(cycle({ nextPassUtc: '2026-11-02T09:30:00Z' }), '2026-11-02T09:30:00Z').nextUtc, '2026-11-02T10:30:00.000Z', 'exactly at the pass counts as gone by');
  eq(facts(cycle({ nextPassUtc: null }), '2026-11-02T09:50:00Z').nextUtc, '2026-11-02T10:30:00.000Z', 'unfinished, no time: the next half past');
  eq(facts(cycle({ nextPassUtc: 'soon' }), '2026-11-02T09:50:00Z').nextUtc, '2026-11-02T10:30:00.000Z', 'an unreadable time is no time');
  eq(facts(cycle({ resumeAtRunId: null, nextPassUtc: '2026-11-02T03:30:00Z' }), '2026-11-02T09:50:00Z').nextUtc, '2026-11-03T03:30:00.000Z', 'complete: the next 03:30');
});

test('RETENTION-CARD-CYCLE-1: the failures of the cycle are kept for the card', () => {
  const f = facts(cycle({ failures: [{ runId: 'p1/mig-c', reason: 'stopped twice' }, { runId: '', reason: 'no list' }] }), '2026-11-02T09:50:00Z');
  eq(f.failures, ['stopped twice', 'no list'], 'every reason, in order');
  eq(facts(cycle({ failures: undefined }), '2026-11-02T09:50:00Z').failures, [], 'none');
});

run('safety-copies');
