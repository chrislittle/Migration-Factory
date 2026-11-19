/* WIZARD-POLL-STOP-1: the wizard's poll stops once the scan or the plan lands.
 *
 * The poll moves the page first (pollStep): a landed scan moves the findings
 * step to the review, a landed plan moves "How to group them" to the waves. The
 * two stop lines below that asked for the step the page WAITED on - findings,
 * and grouping - so after the move neither saw its step, and the interval went
 * on reading every document of the run every 6 seconds until the tab closed.
 * A left-running poll is what made Back jump forward on the lab walk.
 *
 * RUN, not read: the wizard's own startPolling, pollStep, deriveStep, waitOn
 * and buildWaves are driven together, as the page runs them. The 6-second
 * interval is captured and its tick called by the test.
 *
 * Nothing that comes after these steps waits on this poll: "Run it" watches
 * its start with watchForRefusal and goes to the run page, and the waves step
 * starts no poll. A page loaded on a run that is under way derives that step
 * in start(), with no poll.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const constArrow = (src, name) => {
  const m = src.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};

globalThis.STEP = liftConst('wizard.html', 'STEP');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { machineStarted: lift('help.js', 'machineStarted') });
const startPolling = lift('wizard.html', 'startPolling');
const buildWaves = lift('wizard.html', 'buildWaves');
globalThis.pollStep = lift('wizard.html', 'pollStep');
globalThis.goStep = lift('wizard.html', 'goStep');
globalThis.waitOn = lift('wizard.html', 'waitOn');
globalThis.startPolling = startPolling;
const deriveStep = lift('wizard.html', 'deriveStep');
// Counted, so a tick that throws (the poll swallows it) cannot pass a test.
let derives = 0;
globalThis.deriveStep = () => { derives++; return deriveStep(); };
globalThis.deriveAssessStep = lift('wizard.html', 'deriveAssessStep');

const INTERVAL = 41;

/* The page, with the poll captured: `poll.tick` is the interval's callback,
 * `poll.cleared` the ids handed to clearInterval. */
function page(query) {
  globalThis.location = { search: query, href: 'http://x/wizard.html' + query };
  for (const n of ['wantsRunStep', 'wantsGroupStep', 'wantsTargetsStep', 'wantsChooseStep', 'planningFrom', 'isMigration']) {
    globalThis[n] = constArrow(WIZ, n);
  }
  globalThis.targetsFitMachines = lift('wizard.html', 'targetsFitMachines');
  globalThis.readFailed = false;
  globalThis.step = 1;
  globalThis.stepChosen = false;
  globalThis.journey = 'migrate';
  globalThis.manifest = { kind: 'assessment' };
  globalThis.plan = null;
  globalThis.planRefused = null;
  globalThis.states = new Map();
  globalThis.projectId = 'p'; globalThis.runId = 'r'; globalThis.runExists = true;
  globalThis.assessment = { vms: [{ id: '/x/a', tags: {} }] };
  globalThis.targetAdvice = { machines: [{ vmId: '/x/a' }] };
  globalThis.machineChoices = { machines: ['/x/a'] };
  globalThis.machinesVersion = 'mv1';
  globalThis.targetChoices = { default: 'v6', choices: [], machinesVersion: 'mv1' };
  globalThis.failAction = (e) => { throw e; };
  globalThis.form = { strategy: 'singleWave' };
  const els = {};
  globalThis.$ = (sel) => (els[sel] ??= {
    innerHTML: '', value: '', disabled: false, style: {}, listeners: {},
    addEventListener(e, f) { this.listeners[e] = f; },
  });
  // What the page draws, in order: the step each draw shows.
  const drawn = [];
  globalThis.render = () => { drawn.push(globalThis.step); };
  const poll = { tick: null, cleared: [], started: 0 };
  globalThis.poll = null;
  globalThis.pollBusy = false;
  globalThis.setInterval = (fn) => { poll.tick = fn; poll.started++; return INTERVAL; };
  globalThis.clearInterval = (id) => { poll.cleared.push(id); };
  globalThis.readRun = async () => {};
  globalThis.paintScanProgress = async () => {};
  globalThis.paintAdviceProgress = async () => {};
  globalThis.watchPlanRefusal = () => {};
  return { els, drawn, poll };
}

/* The poll is stopped: the interval it started was cleared and nothing holds it. */
function stopped(pg, what) {
  ok(pg.poll.cleared.includes(INTERVAL), `${what}: the interval is cleared`);
  eq(globalThis.poll, null, `${what}: no poll is left`);
}
function running(pg, what) {
  eq(pg.poll.cleared.includes(INTERVAL), false, `${what}: the interval is not cleared`);
  eq(globalThis.poll, INTERVAL, `${what}: the poll still runs`);
}

/* An assessment the findings step waits for, as Assess leaves it. */
function waitingForScan() {
  const pg = page('?run=r');
  globalThis.journey = 'assess';
  globalThis.assessment = null;
  waitOn(STEP.assess.findings);
  startPolling();
  return pg;
}

/* A migration "How to group them" waits for, as Build the waves leaves it. */
async function waitingForPlan(query) {
  const pg = page(query ?? '?run=r&plan=1');
  globalThis.step = STEP.migrate.group;
  globalThis.stepChosen = true;       // reached by Save the targets
  globalThis.plannedFrom = null;
  globalThis.runSeg = () => 'r';
  globalThis.runBody = (b) => b;
  globalThis.URL = class { constructor(h) { this.searchParams = new Map(); this.href = h; } };
  globalThis.history = { replaceState() {} };
  globalThis.renderPlanWait = () => {};
  globalThis.api = async () => ({ migrationId: 'm1' });
  await buildWaves();
  eq(pg.poll.started, 1, 'Build the waves starts the poll');
  // The engine writes the migration's run.json; its plan comes after.
  globalThis.manifest = { kind: 'migration' };
  // The page's address now names the migration, as buildWaves puts it there.
  globalThis.location = { search: (query ?? '?run=r&plan=1').replace('run=r', 'run=m1') + '&from=r', href: 'http://x/wizard.html' };
  return pg;
}
const PLAN = { entries: [{ vmId: '/x/a', wave: 'w1', path: 'A' }] };

test('the scan lands with machines: the page moves to the review and the poll stops', async () => {
  const pg = waitingForScan();
  const before = derives;
  await pg.poll.tick();
  eq(derives - before, 1, 'the first tick worked out the step');
  running(pg, 'no assessment yet');
  globalThis.assessment = { vms: [{ id: '/x/a' }] };
  await pg.poll.tick();
  eq(globalThis.step, STEP.assess.review, 'the landed scan opens its review');
  stopped(pg, 'after the review opens');
  eq(pg.drawn.filter(s => s === STEP.assess.review).length, 1, 'the review is drawn once');
});

test('the scan lands with no machines: the findings step stays, drawn, and the poll stops', async () => {
  const pg = waitingForScan();
  globalThis.assessment = { vms: [] };
  await pg.poll.tick();
  eq(globalThis.step, STEP.assess.findings, 'an empty scan stays on the findings');
  eq(pg.drawn[pg.drawn.length - 1], STEP.assess.findings, 'the findings are drawn with the answer');
  stopped(pg, 'after an empty scan');
});

test('Back to the scope while the scan runs: the scan lands, the scope stays, and the poll stops', async () => {
  const pg = waitingForScan();
  goStep(STEP.assess.scope);
  const drawnBefore = pg.drawn.length;
  globalThis.assessment = { vms: [{ id: '/x/a' }] };
  await pg.poll.tick();
  eq(globalThis.step, STEP.assess.scope, 'the person stays on the step they chose');
  eq(pg.drawn.length, drawnBefore, 'and the scope is not drawn again over what they type');
  stopped(pg, 'after the scan lands behind the scope');
});

test('the plan lands: the page moves to the waves and the poll stops', async () => {
  const pg = await waitingForPlan();
  await pg.poll.tick();
  eq(globalThis.step, STEP.migrate.group, 'with no plan the page waits on grouping');
  running(pg, 'no plan yet');
  globalThis.plan = PLAN;
  await pg.poll.tick();
  eq(globalThis.step, STEP.migrate.waves, 'the landed plan opens the waves');
  stopped(pg, 'after the waves open');
  eq(pg.drawn.filter(s => s === STEP.migrate.waves).length, 1, 'the waves are drawn once');
});

test('the plan lands on an address that asks for Run it: the page moves there and the poll stops', async () => {
  const pg = await waitingForPlan('?run=r&plan=1&step=run');
  globalThis.plan = PLAN;
  await pg.poll.tick();
  eq(globalThis.step, STEP.migrate.run, 'the address asks for Run it');
  stopped(pg, 'after Run it opens');
});

test('the plan lands with a machine already started: the page says so and the poll stops', async () => {
  const pg = await waitingForPlan();
  globalThis.plan = PLAN;
  globalThis.states = new Map([['/x/a', 'PRECHECK']]);
  await pg.poll.tick();
  eq(globalThis.step, STEP.running, 'a started machine opens "already under way"');
  stopped(pg, 'after "already under way" opens');
});

test('a plan with no machines is not the answer: the poll goes on', async () => {
  const pg = await waitingForPlan();
  globalThis.plan = { entries: [] };
  await pg.poll.tick();
  eq(globalThis.step, STEP.migrate.group, 'the page still waits on grouping');
  running(pg, 'an empty plan');
});

test('the target options still being made: the poll goes on', async () => {
  const pg = page('?run=r&plan=1');
  globalThis.targetAdvice = null;
  globalThis.targetChoices = null;
  globalThis.step = STEP.migrate.targets;
  globalThis.stepChosen = false;
  startPolling();
  await pg.poll.tick();
  eq(globalThis.step, STEP.migrate.targets, 'the targets step waits');
  running(pg, 'no target options yet');
});

run('wizard-poll-stop');
