/* KPI-COUNT-1, 2026-09-18. How many machines a run covers.
 *
 * THE DEFECT, seen on a real install: the tile read
 *
 *     VIRTUAL MACHINES   0
 *     in this run
 *
 * while the table directly underneath listed one machine, waiting for approval.
 *
 * Neither number was wrong; they answered different questions. The wave table
 * is built from the PLAN, and a machine with no state document renders as
 * PLANNED. The tile counted STATE DOCUMENTS, and the engine writes one only
 * when it first touches a machine - so a run that has not started has none.
 *
 * A run covers what its plan covers. These pin that, including the case the
 * page already handles one row lower: a state document with no plan entry is
 * still a machine in the run, which is why this is a union and not a swap of
 * one source for the other.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const machinesInRun = lift('migrations.html', 'machinesInRun');

/* THE TILE ITSELF, not only the function behind it.
 *
 * The first version of this file tested machinesInRun alone. Reverting the
 * tile to the broken expression left all seven passing - the function was
 * right and nothing read it. That is the same shape as the defect that broke
 * Approve the same day: a correct callee, and a caller that does not use it.
 *
 * So renderKpis is lifted too, with just enough around it to paint. The DOM
 * harness keeps painted markup as TEXT, which is all this needs.
 */
const kpis = liftAll('migrations.html', ['machinesInRun', 'renderKpis']);

/* PUTBACK-COUNT-1 gave renderKpis two helpers that decide what counts as
 * migrated. They are read out of the page rather than written again here - a
 * copy in the test would test the copy. */
const PAGE_SRC = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
/* COUNT-TRUTH-1: and those helpers now ask help.js's one definition, which is
 * lifted from help.js for the same reason. */
{
  const HELP = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
  // eslint-disable-next-line no-eval
  globalThis.WORKING_STATES = eval(HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/)[1]);
  // NOT-IN-WAVE-QUEUED-1: machinesInRun asks help.js's outsideRun.
  globalThis.VmfHelp = { machineOutcome: lift('help.js', 'machineOutcome'), outcomeWaitsOnPerson: lift('help.js', 'outcomeWaitsOnPerson'), outsideRun: lift('help.js', 'outsideRun') };
}
/* STATUS-WORDS-1: the tiles count each machine by its status - help.js's rule,
 * and the page's own statusCounts. */
{
  const machineStatus = require('./_status').statusRule();
  const { liftConst } = require('./_harness');
  globalThis.RUNNING_STATUS = liftConst('migrations.html', 'RUNNING_STATUS');
  globalThis.WAITING_STATUS = liftConst('migrations.html', 'WAITING_STATUS');
  globalThis.statusCounts = lift('migrations.html', 'statusCounts');
  globalThis.machineStatusOf = (id, doc) => machineStatus(doc, {});
}
for (const name of ['isPutBack']) {
  const m = PAGE_SRC.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name + ' from the page'); }
  // eslint-disable-next-line no-eval
  globalThis[name] = eval('(' + m[1] + ')');
}

// FINISH-COUNT-1: the Waiting on people card asks the page's one rule.
globalThis.waitsOnPerson = lift('migrations.html', 'waitsOnPerson');

function paint(vms, plan) {
  const el = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#kpis' ? el : null);
  globalThis.PROBLEM_STATES = ['NEEDS_DECISION', 'FAILED_NEEDS_ATTENTION'];
  globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK'];
  globalThis.canOperate = () => false;
  globalThis.runIsWorking = () => false;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.UX_ACT = {};
  globalThis.renderRunActions = () => {};
  /* The page reads the plan from the value the refresh has just set, not from
   * an argument - see the comment on renderKpis for why. So the test sets it
   * the same way the page does. */
  globalThis.planDoc = plan;
  kpis.renderKpis(vms, false);
  return el.innerHTML;
}

/** The number the operator actually reads under "Virtual machines". */
function shownCount(vms, plan) {
  const html = paint(vms, plan);
  const m = html.match(/Virtual machines<\/div><div class="val">([^<]*)</);
  // A miss means the tile's markup moved. Fail loudly rather than read nothing.
  ok(m, 'the Virtual machines tile was painted and could be read');
  return m[1];
}

const plan = (...ids) => ({ entries: ids.map(id => ({ vmId: id, wave: 'wave-1' })) });
const states = (...ids) => ids.map(id => ({ vmId: id, state: 'MIGRATING' }));

test('a planned run that has not started counts its plan, not its state docs', () => {
  /* THE REGRESSION. Before the fix this was 0, under a table showing one. */
  eq(machinesInRun([], plan('/subscriptions/s/rg/a/vm1')), 1);
});

test('a machine is counted once, whether or not it has started', () => {
  const id = '/subscriptions/s/rg/a/vm1';
  eq(machinesInRun(states(id), plan(id)), 1, 'the plan entry and its state doc are one machine');
});

test('a part-started run counts every machine, started or not', () => {
  const ids = ['/s/vm1', '/s/vm2', '/s/vm3'];
  eq(machinesInRun(states(ids[0]), plan(...ids)), 3);
});

test('a state doc with no plan entry still counts, the way the table shows it', () => {
  /* renderWaves puts these under 'unplanned'. A tile that ignored them would
   * report fewer machines than the rows below it - the same disagreement,
   * pointing the other way. */
  eq(machinesInRun(states('/s/seeded'), plan('/s/vm1')), 2);
});

test('an empty run is empty, and says so', () => {
  eq(machinesInRun([], plan()), 0);
  eq(machinesInRun([], null), 0);
});

test('no plan yet is not a crash - a run is opened before it is planned', () => {
  eq(machinesInRun(states('/s/vm1'), null), 1);
  eq(machinesInRun(states('/s/vm1'), undefined), 1);
  eq(machinesInRun(states('/s/vm1'), {}), 1);
});

test('a document with no machine id is not counted as a machine', () => {
  /* A half-written entry must not inflate the count. It cannot be told apart
   * from any other, so it is not a machine as far as this is concerned. */
  eq(machinesInRun([{ state: 'MIGRATING' }, null], { entries: [{ wave: 'wave-1' }, null] }), 0);
});

test('the TILE shows the run count - the page reads the function', () => {
  /* THE WIRING. Reverting the tile to the state-document count leaves every
   * test above passing and fails this one. */
  eq(shownCount([], plan('/subscriptions/s/rg/a/vm1')), '1',
     'one planned machine, none started');
});

test('the tile agrees with the table on a part-started run', () => {
  const ids = ['/s/vm1', '/s/vm2', '/s/vm3'];
  eq(shownCount(states(ids[0]), plan(...ids)), '3');
});

test('the tile reads 0 only when the run really covers nothing', () => {
  eq(shownCount([], plan()), '0');
});

run('machines in run');
