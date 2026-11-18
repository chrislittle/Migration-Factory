/* RUN-SUMMARY-SWAP-1, 2026-11-07. The overview and the migrations list count
 * a machine that Restore this machine left stopped, waiting for Finish the
 * restore.
 *
 * WHAT WAS WRONG. FINISH-COUNT-1 made the one definition (machineOutcome)
 * count such a machine as waiting for a person: its record holds swapPending.
 * But the overview (migrationFacts) and the migrations list (runGroup) count
 * run-status.json's summary, and that counted machines by STATE. A restored
 * machine keeps the state MIGRATED, so the overview said no machine needs
 * attention and the migration was not under Needs attention, while a machine
 * was stopped.
 *
 * THE RULE. run-status v6 carries summary.waitsOnPerson, the machines whose
 * outcome waits for a person (outcomeWaitsOnPerson, twinned with the engine's
 * Test-VmfOutcomeWaitsOnPerson and held to tests/fixtures/machine-outcomes.json).
 * The pages read it, and nothing in its place (OLD-VERSION-READERS-REMOVE-6:
 * the engine writes it in every summary, so a summary without it is not read).
 *
 * RUN, not read: help.js's own runWaitingCount, runGroup and
 * outcomeWaitsOnPerson, the Overview's own migrationFacts, and the
 * Migrations page's own waitsOnPerson.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const HELP = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const SCHEMA = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'run-status.schema.json'), 'utf8'));
const FIXTURE = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'machine-outcomes.json'), 'utf8'));

const ws = HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/);
if (!ws) { throw new Error('WORKING_STATES is not declared in help.js'); }
// eslint-disable-next-line no-eval
globalThis.WORKING_STATES = eval(ws[1]);

const shared = liftAll('help.js', ['runSummaryOf', 'runWaitingCount', 'runGateTag', 'runGroup',
                                   'machineOutcome', 'outcomeWaitsOnPerson']);
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval((HELP.match(/const PROBLEM_STATES = (\[[^\]]*\]);/) || [])[1]);
globalThis.RUN_ACTIVE_MS = Number((HELP.match(/const RUN_ACTIVE_MS = (\d+);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_WAITS = eval((HELP.match(/const RUN_GATE_WAITS = (\[[^\]]*\]);/) || [])[1]);
// eslint-disable-next-line no-eval
globalThis.RUN_GATE_TAG = eval(`(${(HELP.match(/const RUN_GATE_TAG = (\{[^}]*\});/) || [])[1]})`);
globalThis.VmfHelp = shared;

const LONG_AGO = Date.parse('2026-11-01T00:00:00Z');
const NOW = Date.parse('2026-11-07T00:00:00Z');

// The summary the engine writes after a restore left a swap on one machine
// of wave-1: every state is MIGRATED. wave-2 is next, or every wave ran.
function summary(waitsFor, waitsOnPerson, version = SCHEMA.properties.schemaVersion.const) {
  const s = {
    writtenUtc: '2026-11-07T10:00:00.0000000Z', reason: 'putBack', halted: false, machines: 4,
    stateCounts: waitsFor === 'none' ? { MIGRATED: 4 } : { MIGRATED: 2, PLANNED: 2 }, restoredStops: 0,
    waves: [{ wave: 'wave-1', machines: 2, stateCounts: { MIGRATED: 2 }, restoredStops: 0 },
            { wave: 'wave-2', machines: 2, stateCounts: waitsFor === 'none' ? { MIGRATED: 2 } : { PLANNED: 2 }, restoredStops: 0 }],
    next: { wave: waitsFor === 'none' ? null : 'wave-2', waitsFor },
  };
  if (waitsOnPerson !== undefined) {
    s.waitsOnPerson = waitsOnPerson; s.waves[0].waitsOnPerson = waitsOnPerson; s.waves[1].waitsOnPerson = 0;
  }
  return { schemaVersion: version, runId: 'contoso-move', summary: s };
}
const group = (status) => shared.runGroup(false, null, LONG_AGO, NOW, { summary: shared.runSummaryOf(status) });

test('the schema is v8 and requires the count in the summary and in each wave', () => {
  eq(SCHEMA.properties.schemaVersion.const, 8);
  eq(SCHEMA.properties.summary.properties.waitsOnPerson.type, 'integer');
  eq(SCHEMA.properties.summary.properties.waves.items.properties.waitsOnPerson.type, 'integer');
  ok(SCHEMA.properties.summary.required.includes('waitsOnPerson'), 'required: every summary this version writes holds it (RUN-STATUS-OLD-SUMMARY-1)');
  ok(SCHEMA.properties.summary.properties.waves.items.required.includes('waitsOnPerson'), 'required in each wave too');
});

test('RUN: outcomeWaitsOnPerson gives every outcome what the fixture says, and the engine is held to the same', () => {
  const map = FIXTURE.waitsOnPerson;
  ok(map && typeof map === 'object', 'the fixture holds the rule');
  eq(Object.keys(map).sort().join(','), 'attention,leftOut,migrated,notStarted,putBack,rolledBack,unknown,working');
  for (const [o, want] of Object.entries(map)) { eq(shared.outcomeWaitsOnPerson(o), want, o); }
  eq(shared.outcomeWaitsOnPerson('somethingNew'), false, 'unknown is not a yes');
  for (const c of FIXTURE.cases) {
    eq(shared.outcomeWaitsOnPerson(shared.machineOutcome(c.doc)), map[c.outcome], `${JSON.stringify(c.doc)} - ${c.why}`);
  }
});

test('RUN: the Migrations page asks the same rule', () => {
  globalThis.VmfHelp = shared;
  const waitsOnPerson = lift('migrations.html', 'waitsOnPerson');
  for (const c of FIXTURE.cases) {
    eq(waitsOnPerson(c.doc), FIXTURE.waitsOnPerson[c.outcome], `${JSON.stringify(c.doc)} - ${c.why}`);
  }
  const calls = [];
  globalThis.VmfHelp = Object.assign({}, shared, { outcomeWaitsOnPerson: (o) => { calls.push(o); return 'asked'; } });
  eq(waitsOnPerson({ state: 'MIGRATED' }), 'asked', 'the page asks help.js, not a copy of the rule');
  eq(calls.join(','), 'migrated');
  globalThis.VmfHelp = shared;
});

test('RUN: runWaitingCount reads the count, and never the stop states in its place', () => {
  eq(shared.runWaitingCount(shared.runSummaryOf(summary('start', 1))), 1, 'the count');
  eq(shared.runWaitingCount(shared.runSummaryOf(summary('start', 0))), 0);
  const none = summary('start', undefined).summary;
  none.stateCounts = { MIGRATED: 1, FAILED_NEEDS_ATTENTION: 2 }; none.restoredStops = 1;
  eq(shared.runWaitingCount(none), null, 'no count: cannot tell, not the stop states less the restored stops');
  for (const bad of [-1, 1.5, '2', null, NaN]) {
    const s = summary('start', 0).summary;
    s.waitsOnPerson = bad; s.stateCounts = { FAILED_NEEDS_ATTENTION: 1 };
    eq(shared.runWaitingCount(s), null, `a count that is not a whole number (${bad}) is not read`);
  }
  eq(shared.runWaitingCount(null), null, 'no summary is still cannot tell');
});

test('RUN: the list - a migration with a machine a restore left stopped needs attention', () => {
  eq(group(summary('none', 1)), 'Needs attention', 'every wave ran, every state is MIGRATED');
  eq(group(summary('none', 0)), 'Completed', 'the swap is finished');
  eq(group(summary('start', 1)), 'Needs attention', 'the next wave is ready');
  eq(group(summary('start', 0)), 'Planned');
  eq(group(summary('approval', 1)), 'Needs attention', 'a stopped machine comes before an approval');
  eq(group(summary('approval', 0)), 'Waiting for approval');
});

test('RUN: the list - a summary with no count is not read, so the list cannot tell', () => {
  eq(group(summary('none', undefined)), 'Planned', 'no summary it can read, and no live counts');
  const stop = summary('none', undefined);
  stop.summary.stateCounts = { MIGRATED: 3, FAILED_NEEDS_ATTENTION: 1 };
  eq(group(stop), 'Planned', 'its stop states are not counted');
});

test('RUN: the Overview - the card counts the machine a restore left stopped', () => {
  const migrationFacts = lift('index.html', 'migrationFacts');
  eq(migrationFacts(summary('start', 1), 'running').attention, 1, 'the swap left');
  eq(migrationFacts(summary('start', 0), 'running').attention, 0, 'finished');
  eq(migrationFacts(summary('start', undefined), 'running').attention, null, 'a summary with no count: not known');
});

run('run-summary-swap');
