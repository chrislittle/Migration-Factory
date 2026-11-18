/* RESTORED-HOLD-1 (folded in RESTORED-LIST-1), 2026-11-06. A machine whose
 * stop a restore ended does not wait for a person on the Migrations list or
 * on the Overview.
 *
 * WHAT WAS WRONG. A restore does not change the state: the machine stays
 * FAILED_NEEDS_ATTENTION, NEEDS_DECISION or FAILED_ROLLED_BACK, and the
 * summary's stateCounts keep it there. The list (runGroup) and the Overview's
 * card (migrationFacts) counted every machine in such a state as waiting for a
 * person, so a migration whose only stopped machine was restored stayed under
 * Needs attention, and the card counted it.
 *
 * THE RULE. run-status v5 counts those machines in summary.restoredStops
 * (Get-VmfMachineOutcome says putBack), beside stateCounts, which keep each
 * machine under its own state. The pages take that count off the machines in
 * a stop state. RUN-SUMMARY-SWAP-1 (v6) then made the engine count the
 * machines that wait for a person (waitsOnPerson), which leaves such a
 * machine out; the pages read that count (OLD-VERSION-READERS-REMOVE-6: never
 * the stop states in its place). restoredStops still says that a stop has
 * ended, so a migration whose waves all ran is Completed.
 *
 * RUN, not read: help.js's own runGroup and runWaitingCount, and the
 * Overview's own migrationFacts.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const HELP = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const SCHEMA = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'run-status.schema.json'), 'utf8'));

const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup']);
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.VmfHelp = shared;

const LONG_AGO = Date.parse('2026-11-01T00:00:00Z');
const NOW = Date.parse('2026-11-06T00:00:00Z');

// A summary in the shape the engine writes: wave-1 ran with one machine
// stopped in `state`; wave-2 is next and waits for `waitsFor`.
// The engine's count of the machines that wait for a person leaves out the
// restored one.
function summary(state, waitsFor, restoredStops, version = SCHEMA.properties.schemaVersion.const) {
  const s = {
    writtenUtc: '2026-11-05T10:00:00.0000000Z', reason: 'putBack', halted: false, machines: 4,
    stateCounts: { MIGRATED: 1, [state]: 1, PLANNED: 2 },
    waves: [{ wave: 'wave-1', machines: 2, stateCounts: { MIGRATED: 1, [state]: 1 } },
            { wave: 'wave-2', machines: 2, stateCounts: { PLANNED: 2 } }],
    next: { wave: 'wave-2', waitsFor },
    waitsOnPerson: restoredStops ? 0 : 1,
  };
  s.waves[0].waitsOnPerson = s.waitsOnPerson; s.waves[1].waitsOnPerson = 0;
  if (restoredStops !== undefined) { s.restoredStops = restoredStops; s.waves[0].restoredStops = restoredStops; s.waves[1].restoredStops = 0; }
  return { schemaVersion: version, runId: 'contoso-move', summary: s };
}
const group = (status) => shared.runGroup(false, null, LONG_AGO, NOW, { summary: shared.runSummaryOf(status) });

test('the schema is v5 or later and carries the count in the summary and in each wave', () => {
  ok(SCHEMA.properties.schemaVersion.const >= 5, 'v5 added restoredStops; RUN-SUMMARY-SWAP-1 made it v6');
  ok(SCHEMA.properties.summary.properties.restoredStops, 'summary.restoredStops');
  ok(SCHEMA.properties.summary.properties.waves.items.properties.restoredStops, 'waves[].restoredStops');
  ok(SCHEMA.properties.summary.properties.reason.enum.includes('putBack'), 'the reason for a machine put back');
});

test('RUN: the list - a migration whose only stopped machine was restored does not need attention', () => {
  for (const state of ['FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK']) {
    eq(group(summary(state, 'start', 0)), 'Needs attention', `${state}, not restored`);
    eq(group(summary(state, 'start', 1)), 'Planned', `${state}, restored: the next wave is ready`);
    eq(group(summary(state, 'approval', 1)), 'Waiting for approval', `${state}, restored: the next wave waits for its approval`);
  }
});

test('RUN: the list - every wave ran and the only stop was restored: Completed, as a migrated machine put back is', () => {
  const done = summary('FAILED_NEEDS_ATTENTION', 'none', 1);
  done.summary.stateCounts = { MIGRATED: 3, FAILED_NEEDS_ATTENTION: 1 };
  eq(group(done), 'Completed');
  const notRestored = summary('FAILED_NEEDS_ATTENTION', 'none', 0);
  notRestored.summary.stateCounts = { MIGRATED: 3, FAILED_NEEDS_ATTENTION: 1 };
  eq(group(notRestored), 'Needs attention');
});

test('RUN: the Overview - the card does not count a restored machine', () => {
  const migrationFacts = lift('index.html', 'migrationFacts');
  eq(migrationFacts(summary('FAILED_NEEDS_ATTENTION', 'start', 0), 'running').attention, 1, 'not restored');
  eq(migrationFacts(summary('FAILED_NEEDS_ATTENTION', 'start', 1), 'running').attention, 0, 'restored');
});

run('restored-list');
