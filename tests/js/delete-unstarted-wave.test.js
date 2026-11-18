/* DELETE-UNSTARTED-WAVE-1 (lab install, 2026-11-16; option (a) chosen).
 *
 * Wave s1 finished and wave s2 had not started: its machine was Queued, with
 * no state document. The Migrations page showed no Stop this migration - only
 * Pause new work and Delete this migration - and the service refused Delete:
 * "This migration works on machines now: under way: 1 of 2 machines settled.
 * Select Stop this migration first." A dead end.
 *
 * The page asked its own question (a machine with a state that is not PLANNED
 * and not settled), and the service asked Get-VmfRunStage. Now the page asks
 * the service's question too: VmfHelp.runStage, held with Get-VmfRunStage to
 * tests/fixtures/run-stage.json. Between waves both say running, so the page
 * shows Stop this migration, which leaves out the machines of the waves that
 * did not start. Then Delete works.
 *
 * RUN, not read: help.js's runStage and the page's own runIsWorking.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'run-stage.json'), 'utf8')).cases;

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const outsideRun = lift('help.js', 'outsideRun');
// idKey is one line, which lift cannot take: read as help.js writes it.
// eslint-disable-next-line no-eval
const idKey = eval(`(${HELP.match(/function idKey\(id\) \{[^\n]*\}/)[0]})`);
// runStage asks outsideRun and idKey by name, as help.js holds them.
globalThis.outsideRun = outsideRun;
globalThis.idKey = idKey;
const runStage = lift('help.js', 'runStage');
globalThis.VmfHelp = { outsideRun, idKey, runStage };

// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = PAGE.match(/const NOT_STARTED_STATE = '([A-Z_]+)';/)[1];
const runIsWorking = lift('migrations.html', 'runIsWorking');

const entry = (n, wave, p = 'A') => ({ vmId: n, wave, path: p });
const doc = (n, state) => ({ vmId: n, state });
function working(plan, docs) {
  globalThis.planDoc = plan;
  globalThis.allVms = docs;
  return runIsWorking();
}

// ---------- the one rule ----------

test('RUN: every shared case gives the answer the engine gives', () => {
  ok(CASES.length >= 14, 'the fixture loaded');
  for (const c of CASES) {
    const plan = c.entries === null ? null : { entries: c.entries };
    const r = runStage(plan, c.docs);
    eq(r.stage, c.stage, `${c.name}: stage`);
    eq(r.machines, c.machines, `${c.name}: machines`);
    eq(r.settled, c.settled, `${c.name}: settled`);
  }
});

test('RUN: the settled states are the page\'s own list', () => {
  /* runStage and the page's SETTLED_STATES must name the same states, or the
   * page and the engine part again on the next state somebody adds. */
  for (const s of globalThis.SETTLED_STATES) {
    eq(runStage({ entries: [entry('vm1', 'w1')] }, [doc('vm1', s)]).stage, 'finished', s);
  }
});

// ---------- the page offers Stop this migration where Delete is refused ----------

test('RUN: between waves the page shows Stop this migration (the lab case)', () => {
  eq(working({ entries: [entry('vm1', 's1'), entry('vm2', 's2')] }, [doc('vm1', 'MIGRATED')]), true,
    'wave s1 finished and wave s2 did not start: the service refuses Delete, so the page offers Stop');
});

test('RUN: a machine part-way through its move still shows Stop this migration', () => {
  eq(working({ entries: [entry('vm1', 's1'), entry('vm2', 's2')] }, [doc('vm1', 'CONVERTING')]), true);
});

test('RUN: a machine at work that the plan does not name still shows Stop this migration', () => {
  /* The rule the page had keeps its place: a state document the plan does not
   * name is not in the stage, and a machine at work must never offer Delete. */
  eq(working({ entries: [entry('vm1', 's1')] }, [doc('vm1', 'MIGRATED'), doc('vm9', 'STOPPED')]), true);
});

test('RUN: a migration that finished, or never started, shows Delete this migration', () => {
  eq(working({ entries: [entry('vm1', 's1'), entry('vm2', 's2')] }, [doc('vm1', 'MIGRATED'), doc('vm2', 'SKIPPED')]), false, 'finished');
  eq(working({ entries: [entry('vm1', 's1'), entry('vm2', 's2')] }, []), false, 'planned, nothing started');
  eq(working({ entries: [entry('vm1', 's1'), entry('vm2', 's2')] }, [doc('vm1', 'PLANNED')]), false, 'planned, a document at PLANNED');
  eq(working({ entries: [entry('vm1', 's1'), entry('vm2', 'unscheduled')] }, [doc('vm1', 'MIGRATED')]), false,
    'every wave finished, a machine in no wave never ran (UNWAVED-MACHINES-UNDERWAY-1)');
});

test('RUN: before the plan is read, the page asks the state documents alone', () => {
  eq(working(null, [doc('vm1', 'CONVERTING')]), true);
  eq(working(null, [doc('vm1', 'MIGRATED')]), false);
});

// ---------- the dialog says what Stop does to a wave that did not start ----------

test('the Stop this migration dialog says a wave that did not start does not start, and its machines do not change', () => {
  const UX_ACT = liftConst('migrations.html', 'UX_ACT');
  ok(UX_ACT.stopRunDesc.includes('A wave that did not start does not start after this. Its machines are left out, and the product does not change them.'),
    UX_ACT.stopRunDesc);
});

run('delete-unstarted-wave');
