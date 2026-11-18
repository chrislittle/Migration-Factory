/* WIZARD-BACK-TARGETS-1: Back from "How to group them" jumped forward again.
 *
 * Seen on the lab installation, 2026-11-02: Back on "How to group them" drew
 * "Choose each target", and about 7 seconds later the wizard's poll worked out
 * the step from the run - "How to group them", because the targets were saved -
 * and moved the person forward again, because that step was later than the one
 * shown. So a saved target could not be changed from the wizard.
 *
 * The rule now: a step a person chose with a button is never moved by the
 * poll. The poll still moves a person on from a step that WAITS for the engine
 * (the scan, the plan), because that is what the person waits for.
 *
 * RUN, not read: the wizard's own Back handler, its own poll tick and its own
 * deriveStep are driven together, as the page runs them.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');
const { scriptsOf, scan } = require('./_html-sinks');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const constArrow = (src, name) => {
  const m = src.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};

const UX = liftConst('wizard.html', 'UX');
globalThis.STEP = liftConst('wizard.html', 'STEP');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { machineStarted: lift('help.js', 'machineStarted'), idKey: eval('(' + pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js')).match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')') });
const deriveStep = lift('wizard.html', 'deriveStep');
const renderStep3 = lift('wizard.html', 'renderStep3');
const startPolling = lift('wizard.html', 'startPolling');
const startScan = lift('wizard.html', 'startScan');
const buildWaves = lift('wizard.html', 'buildWaves');
globalThis.goStep = lift('wizard.html', 'goStep');
globalThis.waitOn = lift('wizard.html', 'waitOn');
const pollStep = lift('wizard.html', 'pollStep');
globalThis.pollStep = pollStep;
globalThis.buildWaves = buildWaves;
// Counted, so a tick that throws (the poll swallows it) cannot pass a test.
let derives = 0;
globalThis.deriveStep = () => { derives++; return deriveStep(); };
globalThis.deriveAssessStep = lift('wizard.html', 'deriveAssessStep');
globalThis.startPolling = startPolling;

/* The page as it is on an approved assessment whose targets are saved and
 * which has no plan: the case from the lab walk. */
function page(query) {
  globalThis.location = { search: query, href: 'http://x/wizard.html' + query };
  for (const n of ['wantsRunStep', 'wantsGroupStep', 'wantsTargetsStep', 'wantsChooseStep', 'planningFrom', 'isMigration', 'opt']) {
    globalThis[n] = constArrow(WIZ, n);
  }
  globalThis.targetsFitMachines = lift('wizard.html', 'targetsFitMachines');
  globalThis.onlyChosen = lift('wizard.html', 'onlyChosen');
  globalThis.roleAction = lift('wizard.html', 'roleAction');
  globalThis.readFailed = false;
  // SCAN-FAIL-SHOWN-1 review: the page's stopped-scan state, which startScan clears.
  globalThis.scanStopped = null;
  globalThis.journey = 'migrate';
  globalThis.manifest = { kind: 'assessment' };
  globalThis.plan = null;
  globalThis.planRefused = null;
  globalThis.states = new Map();
  globalThis.assessment = { vms: [{ id: '/x/a', tags: {} }] };
  globalThis.targetAdvice = { machines: [{ vmId: '/x/a' }] };
  globalThis.machineChoices = { machines: ['/x/a'] };
  globalThis.machinesVersion = 'mv1';
  globalThis.targetChoices = { default: 'v6', choices: [], machinesVersion: 'mv1' };
  globalThis.failAction = (e) => { throw e; };
  globalThis.form = { strategy: 'singleWave' };
  globalThis.canOperate = true;
  globalThis.UX = UX;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.card = (title, body, inner) => `<h2>${title}</h2><p>${body}</p>${inner}`;
  globalThis.runHref = (p) => p + '?run=r';
  globalThis.backToAssessment = () => { throw new Error('Back here stays inside the wizard'); };
  // Every element the page asks for exists; the clicks are captured.
  const els = {};
  globalThis.$ = (sel) => (els[sel] ??= {
    innerHTML: '', value: '', disabled: false, style: {}, listeners: {},
    addEventListener(e, f) { this.listeners[e] = f; },
  });
  globalThis.document = { querySelectorAll: () => [] };
  // What the page draws, in order: the step each draw shows.
  const drawn = [];
  globalThis.render = () => { drawn.push(globalThis.step); if (globalThis.journey === 'migrate' && globalThis.step === STEP.migrate.group) renderStep3($('#step')); };
  // The poll: captured, then called by the test - the interval is 6 seconds.
  const poll = { tick: null, cleared: 0 };
  globalThis.poll = null;
  globalThis.pollBusy = false;
  globalThis.setInterval = (fn) => { poll.tick = fn; return 7; };
  globalThis.clearInterval = () => { poll.cleared++; };
  globalThis.readRun = async () => {};
  globalThis.paintScanProgress = async () => {};
  globalThis.paintAdviceProgress = async () => {};
  globalThis.watchPlanRefusal = () => {};
  return { els, drawn, poll };
}

test('RUN: Back from "How to group them" stays on "Choose each target" across poll ticks', async () => {
  const pg = page('?run=r&plan=1');
  // The page loads on grouping (targets saved), as start() derives it.
  globalThis.step = deriveStep();
  globalThis.stepChosen = false;
  eq(globalThis.step, STEP.migrate.group, 'saved targets derive "How to group them"');
  globalThis.render();
  startPolling();               // a poll left running, as on the lab walk
  pg.els['#b'].listeners.click();
  eq(globalThis.step, STEP.migrate.targets, 'Back shows "Choose each target"');
  const before = derives;
  await pg.poll.tick();
  await pg.poll.tick();
  eq(derives - before, 2, 'both ticks worked out the step');
  eq(globalThis.step, STEP.migrate.targets, 'two poll ticks later the person is still on the step they chose');
  eq(pg.drawn[pg.drawn.length - 1], STEP.migrate.targets, 'and the last thing drawn is that step');
  // And the tick ran past the step rule: with no options it asks for their progress.
  let asked = 0; globalThis.paintAdviceProgress = async () => { asked++; };
  globalThis.targetAdvice = null;
  await pg.poll.tick();
  eq(asked, 1, 'the tick reached the line after the step rule');
  eq(globalThis.step, STEP.migrate.targets, 'and still left the person where they chose');
});

test('RUN: the plan landing still moves a waiting "How to group them" on to the waves', async () => {
  const pg = page('?run=r&plan=1');
  globalThis.step = STEP.migrate.group;
  globalThis.stepChosen = true;       // reached by Save the targets
  globalThis.runId = 'r'; globalThis.plannedFrom = null;
  globalThis.runSeg = () => 'r';
  globalThis.runBody = (b) => b;
  globalThis.URL = class { constructor(h) { this.searchParams = new Map(); this.href = h; } };
  globalThis.history = { replaceState() {} };
  globalThis.renderPlanWait = () => {};
  globalThis.api = async () => ({ migrationId: 'm1' });
  await buildWaves();
  // The engine writes the migration's plan; the next tick reads it.
  globalThis.manifest = { kind: 'migration' };
  globalThis.plan = { entries: [{ vmId: '/x/a', wave: 'w1', path: 'A' }] };
  await pg.poll.tick();
  eq(globalThis.step, STEP.migrate.waves, 'the plan the person waits for moves them to the waves');
});

test('RUN: Back from the findings to the scope stays there while the scan runs', async () => {
  const pg = page('?run=r');
  globalThis.journey = 'assess';
  globalThis.manifest = { kind: 'assessment' };
  globalThis.projectId = 'p'; globalThis.runId = 'r'; globalThis.runExists = true;
  globalThis.assessment = null;
  globalThis.step = STEP.assess.findings;
  globalThis.stepChosen = false;
  startPolling();
  goStep(STEP.assess.scope);          // the findings step's Back
  const before = derives;
  await pg.poll.tick();
  eq(derives - before, 1, 'the tick worked out the step');
  eq(globalThis.step, STEP.assess.scope, 'the scan still running does not take the person away from the scope');
});

test('RUN: the scan landing still moves a waiting findings step on, after Assess', async () => {
  const pg = page('?run=r');
  globalThis.journey = 'assess';
  globalThis.projectId = 'p'; globalThis.runId = null; globalThis.runExists = false;
  globalThis.assessment = null;
  globalThis.step = STEP.assess.scope;
  globalThis.stepChosen = true;       // the person came back to the scope
  globalThis.form = { scopeType: 'mg' };
  globalThis.blobJson = async () => null;
  globalThis.api = async () => ({});
  globalThis.VmfHelp.VmfRun = { storePath: (p, n) => `${p}/${n}`, routeSegment: (x) => x, withProject: (b) => b };
  globalThis.history = { replaceState() {} };
  pg.els['#f-name'] = Object.assign($('#x'), { value: 'run-1' });
  pg.els['#f-mg'] = Object.assign($('#y'), { value: 'mg-1' });
  await startScan();                  // Assess: the scan starts, the findings step waits for it
  eq(globalThis.step, STEP.assess.findings, 'Assess shows the findings step');
  globalThis.runId = 'r'; globalThis.runExists = true;
  globalThis.assessment = { vms: [{ id: '/x/a' }] };
  await pg.poll.tick();
  eq(globalThis.step, STEP.assess.review, 'the assessment the person waits for opens its review');
});

test('pollStep: a chosen step stays; a waiting step moves on, never back', () => {
  eq(pollStep(STEP.migrate.targets, STEP.migrate.group, true), STEP.migrate.targets, 'chosen, later derived');
  eq(pollStep(STEP.assess.review, STEP.assess.findings, true), STEP.assess.review, 'chosen, earlier derived');
  eq(pollStep(STEP.migrate.group, STEP.migrate.waves, false), STEP.migrate.waves, 'waiting, later derived');
  eq(pollStep(STEP.migrate.waves, STEP.migrate.group, false), STEP.migrate.waves, 'waiting, earlier derived: never back');
  eq(pollStep(STEP.migrate.group, STEP.migrate.group, false), STEP.migrate.group, 'same');
});

/* Every button that changes the step goes through goStep, so none of them can
 * be moved by the poll. Census of the code (comments and strings masked): a
 * plain `step = ` appears only in the functions that own the rule. */
test('every step change outside the poll goes through goStep or waitOn', () => {
  const allowed = new Set(['goStep', 'waitOn', 'start', 'startPolling']);
  const found = [];
  for (const sc of scriptsOf('wizard.html')) {
    const code = scan(sc.text).mask;
    const re = /(^|[^.\w])step\s*=(?!=)/g;
    let m;
    while ((m = re.exec(code))) {
      // `const step =` and `let step =` are other variables or the declaration.
      const before = code.slice(Math.max(0, m.index - 8), m.index + m[1].length);
      if (/(const|let|var)\s*$/.test(before)) continue;
      const fns = [...code.slice(0, m.index).matchAll(/function\s+(\w+)\s*\(/g)];
      const owner = fns.length ? fns[fns.length - 1][1] : '(top level)';
      if (!allowed.has(owner)) found.push(owner);
    }
  }
  eq(found.join(', '), '', 'functions that set the step directly');
  ok(/function goStep\(n\) \{\s*step = n; stepChosen = true; render\(\);\s*\}/.test(WIZ), 'goStep marks the step as chosen');
});

run('wizard-back-targets');
