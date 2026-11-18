/* OLD-REBUILD-RESTORE-READERS-1: the run page, the migration page, the
 * assessments page and the reports page read no rebuild that an earlier
 * version made.
 *
 * No flow of this version writes a recovery record, a disk list
 * recoveryDisks, a job of kind rebuild or a path B, and nothing is public
 * before 1.0. So the page has no status Rebuilding or Rebuilt, no restore
 * refusal for a machine an earlier version rebuilt, no method label for path
 * B, and no list of disks Rebuild this machine made.
 *
 * RUN, not read: the pages' own tables and functions.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const ws = HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/);
// eslint-disable-next-line no-eval
globalThis.WORKING_STATES = eval(ws[1]);
const help = liftAll('help.js', ['machineOutcome', 'machineStatus']);

const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const UX_MISC = liftConst('migrations.html', 'UX_MISC');
const UX_COPIES = liftConst('migrations.html', 'UX_COPIES');
Object.assign(globalThis, { UX_ACT, UX_COPIES, esc: (s) => String(s ?? ''), agoSpan: (s) => String(s) });
const page = liftAll('migrations.html', ['recordedMachineDiskIds', 'madeDiskRows', 'powerOwed', 'retryHeld']);

const MIG = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

/* A one-line table, read as the page declares it. */
function oneLineConst(file, name) {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', file));
  const m = src.match(new RegExp(`\\nconst ${name} = (\\{[^\\n]*\\});`));
  if (!m) { throw new Error(`could not read const ${name} from ${file}`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[1]})`);
}

test('the method labels name the in-place upgrade only, on every page', () => {
  eq(JSON.stringify(oneLineConst('migrations.html', 'UX_PATH')), JSON.stringify({ A: 'In-place upgrade' }), 'migrations');
  eq(JSON.stringify(oneLineConst('assessments.html', 'PATH_WORDS')), JSON.stringify({ A: 'In-place upgrade' }), 'assessments');
  eq(JSON.stringify(oneLineConst('reports.html', 'PATH_WORDS')), JSON.stringify({ A: 'In-place upgrade' }), 'reports');
});

test('no status, restore words or disk list of a rebuild on the migration page', () => {
  for (const key of ['statusRebuilding', 'statusRebuildingTip']) { ok(!(key in UX_MISC), `${key} is gone`); }
  for (const key of ['restoreOldRebuild', 'madeByRebuild', 'wasRebuilt', 'wasRebuiltTip', 'rowCheckRebuilt']) { ok(!(key in UX_ACT), `${key} is gone`); }
  for (const fn of ['restoreOldRebuild', 'restoreOldRebuildWords', 'rebuildIndex', 'rebuildInFlight']) {
    ok(!new RegExp(`function ${fn}\\s*\\(`).test(MIG), `${fn} is gone`);
  }
});

test('RUN: a machine that stopped is a decision, whatever an old recovery or job record says', () => {
  const stopped = {
    state: 'NEEDS_DECISION',
    history: [{ tsUtc: '2026-11-04T17:00:00Z', state: 'NEEDS_DECISION', reasonCode: 'x' }],
    recovery: { recoveredUtc: '2026-11-04T18:00:00Z' },
  };
  eq(help.machineStatus(stopped, {}).key, 'decision', 'a recovery record is not read');
  eq(help.machineStatus(stopped, { rebuilding: { since: '2026-11-04T17:30:00Z' } }).key, 'decision', 'live.rebuilding is not read');
});

test('RUN: the disks made from the copies are the rollback\'s and the restore\'s', () => {
  const id = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/app-01-os-rec';
  const rows = page.madeDiskRows({ state: 'MIGRATED', recoveryDisks: [{ diskId: id, diskName: 'app-01-os-rec', lun: null }] });
  eq(rows.length, 0, 'recoveryDisks is not read');
});

test('RUN: a recovery record mends no machine a stop left changed', () => {
  const doc = { state: 'NEEDS_DECISION', recovery: { recoveredUtc: '2026-10-01T11:00:00Z' }, history: [
    { tsUtc: '2026-10-01T10:00:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'x', machineState: 'changed' }] };
  eq(page.retryHeld(doc), true, 'still held');
});

run();
