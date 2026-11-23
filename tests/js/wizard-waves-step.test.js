/* WIZARD-WAVES-STEP-1: "Build the waves" showed the grouping step again.
 *
 * Seen twice in the lab on 2026-10-26: the wizard said "Working out the waves",
 * the address changed to the new migration (?run=<migration>&project=..&plan=1),
 * and the page then showed "How should they be grouped into waves?" again -
 * radio options and a Build the waves button - although the plan was made.
 *
 * THE CAUSE. A step is a number, and the two journeys share them: "what we
 * found" on the assess journey is 3, and so is "how to group them" when
 * migrating. The watch had a rule "the scan has landed while the findings step
 * waits: draw it and stop watching" that did not ask which journey it was on.
 * New-VmfPlan copies assessment.json into the new migration BEFORE it writes
 * plan.json, so a tick between the two drew the grouping form again and
 * stopped the watch - and the page stayed on that form after the plan was made.
 * The same rule redrew the form under a person who had just chosen a grouping,
 * when a watch from the targets step was still running: the lost first click.
 *
 * AND A SECOND WAY IN. A load of the migration's address while the engine
 * plans (a sign-in redirect, a tab the browser discarded, a reload) drew the
 * grouping FORM with nothing watching for the plan - and Build the waves on a
 * migration would be refused, because a migration has no approval.
 *
 * RUN, not read: the page's own readRun, deriveJourney, deriveStep, render,
 * renderStep3, buildWaves and startPolling, in one scope, over a fake store
 * that answers the way the service does (null for a document not there), with
 * tokens from the shared MSAL stand-in.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run, msalStandIn } = require('./_harness');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const constOf = (name) => {
  // To the semicolon that ends a line (a comment may follow it): esc carries
  // ';' inside its strings.
  const m = WIZ.match(new RegExp(`\\nconst ${name} = ([\\s\\S]+?);[ \\t]*(?://[^\\n]*)?\\r?\\n`));
  if (!m) { throw new Error('could not read ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};

const help = liftAll('help.js', ['runParse', 'runStorePath', 'runRouteSegment', 'runWithProject', 'runLink',
  'mapLimited', 'tokenOrRedirect', 'machineStarted', 'idKey']);

const PAGE_FNS = ['readRun', 'ackGiven', 'readDoc', 'readNames', 'readVersionedDoc', 'reviewedScan', 'blobJson', 'blobVersioned', 'blobList', 'getToken',
  'deriveJourney', 'deriveStep', 'targetsFitMachines', 'render', 'renderStep3', 'buildWaves', 'startPolling',
  'backToAssessment', 'runFullId', 'runPrefix', 'runSeg', 'runBody', 'runHref', 'onlyChosen', 'roleAction'];
PAGE_FNS.push('renderPlanWait', 'deriveAssessStep');
// WIZARD-BACK-TARGETS-1: the step a person chose, and the poll's rule about it.
PAGE_FNS.push('goStep', 'waitOn', 'pollStep');
// WIZARD-PLAN-FAIL-1: the watch on the assessment's log, and what it draws.
PAGE_FNS.push('blobText', 'planRefusal', 'planStillWaiting', 'watchPlanRefusal', 'renderPlanRefused');
// help.js's own loop and log reader. The loop is the real one; only its
// interval and its deadline are made short, so a test does not wait minutes.
const helpLog = liftAll('help.js', ['nextLogPart', 'readLogParts', 'readLogEvents', 'watchRun']);

const PROJECT = 'proj1';
const ASSESS = 'assess-1';
const MIGRATION = 'assess-1-migration-20261026-101500';
const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-01';

/** A fresh page: globals as the page declares them, a fake store, the stand-in. */
function freshPage(query) {
  const store = new Map();
  const g = globalThis;
  g.UX = liftConst('wizard.html', 'UX');
  g.STEP = liftConst('wizard.html', 'STEP');
  g.TARGET_ADVICE_VERSION = constOf('TARGET_ADVICE_VERSION');
  g.esc = constOf('esc');
  g.card = constOf('card');
  g.opt = constOf('opt');
  for (const n of ['wantsPlan', 'wantsRunStep', 'wantsGroupStep', 'wantsTargetsStep', 'wantsChooseStep', 'planningFrom', 'isMigration']) { g[n] = constOf(n); }

  // The page's own state, as its top-level `let`s start.
  Object.assign(g, {
    DEMO_MODE: false, cfg: { apiAppId: 'app-id', apiUrl: 'https://api.example.com' },
    step: 1, poll: null, pollBusy: false, assessment: null, plan: null, states: new Map(), approvals: new Map(),
    runExists: false, manifest: null, approval: null, journey: 'assess', readFailed: null, acceptances: new Map(),
    planSignoff: null, planSignoffCurrent: false, acknowledged: false, targetAdvice: null, adviceVersion: '', adviceOld: false, targetChoices: null,
    choicesVersion: '', machineChoices: null, machinesVersion: '', assessmentVersion: '', runKinds: new Map(),
    form: { scopeType: 'rg', sub: '', rgs: [], subs: [], mg: '', strategy: 'singleWave', appTag: '' },
    canOperate: true, projectId: PROJECT, runId: null, plannedFrom: null,
    planWatch: null, planRefused: null,
  });
  g.LOG_PARTS_MAX = 200;
  g.PLAN_QUIET_MIN = constOf('PLAN_QUIET_MIN');
  const params = new URLSearchParams(query);
  g.runId = params.get('run');

  // Sign-in: the shared stand-in, through help.js's own token call.
  const msal = msalStandIn();
  g.msalApp = msal.ready({});
  g.account = g.msalApp.getAllAccounts()[0];
  const session = new Map();
  g.sessionStorage = { getItem: (k) => session.get(k) ?? null, setItem: (k, v) => session.set(k, String(v)), removeItem: (k) => session.delete(k) };
  g.INTERACTIVE_TRIED = 'vmfInteractiveTried';
  g.STORE_READ_LIMIT = 8;

  // The store, as the service answers: a document not there is null.
  const reads = [];
  const watches = [];
  const failing = new Set();   // paths whose read throws, as a store fault does
  const watchTimeout = { ms: 400 };
  // PAGE-LOAD-3: readRun asks the one call first; here it fails, so each document is read.
  g.RUN_READS = [];
  g.VmfHelp = { ...require('./_held').perFileHelp(),
    VmfRun: { parse: help.runParse, storePath: help.runStorePath, routeSegment: help.runRouteSegment,
              withProject: help.runWithProject, link: help.runLink },
    mapLimited: help.mapLimited, tokenOrRedirect: help.tokenOrRedirect, machineStarted: help.machineStarted, idKey: help.idKey,
    readLogEvents: helpLog.readLogEvents,
    watchRun: (o) => { watches.push(o); return helpLog.watchRun(Object.assign({}, o, { pollMs: 1, timeoutMs: watchTimeout.ms })); },
    async storeBlob(getTok, apiUrl, p, opts) {
      await getTok();
      reads.push(p);
      if (failing.has(p)) { throw new Error(`502 from the store for ${p}`); }
      if (!store.has(p)) { return null; }
      // A log is text, as the store holds it; every other document is JSON.
      const held = store.get(p);
      const text = typeof held === 'string' ? held : JSON.stringify(held);
      if (opts && opts.asVersioned) { return { text, version: `ver-${text.length}` }; }
      if (opts && opts.asText) { return text; }
      return JSON.parse(text);
    },
    async storeList(getTok, apiUrl, prefix) {
      await getTok();
      return { names: [...store.keys()].filter(k => k.startsWith(prefix)) };
    },
  };
  g.nameMachines = () => {};
  g.failRead = () => {};
  g.fail = (e) => { throw e; };
  g.failAction = (e) => { g.actionError = e; };
  g.actionError = null;

  // The screen. renderStep4 leaves for the wave editor, so it records that.
  const els = new Map();
  const el = (sel) => {
    if (!els.has(sel)) {
      els.set(sel, { innerHTML: '', value: '', disabled: false, style: {}, listeners: {},
        addEventListener(e, f) { this.listeners[e] = f; } });
    }
    return els.get(sel);
  };
  g.$ = (sel) => el(sel);
  g.document = { querySelectorAll: () => [] };
  const shown = [];
  g.renderRail = () => {};
  g.renderChoose = () => shown.push('choose');
  g.renderTargets = () => shown.push('targets');
  g.renderStep4 = () => shown.push('arrange the waves');
  g.renderStep5 = () => shown.push('run it');
  g.renderStep2 = () => shown.push('findings');
  g.renderStep1 = () => shown.push('scope');
  g.renderReview = async () => { shown.push('review'); };

  // The address, and the interval the watch sets.
  g.location = { search: query, href: `https://app.example.com/wizard.html${query}` };
  g.history = { replaceState: (_s, _t, url) => { const u = new URL(String(url)); g.location.search = u.search; g.location.href = u.href; } };
  const timer = { tick: null, started: 0, cleared: 0 };
  g.setInterval = (fn) => { timer.tick = fn; timer.started++; return 7; };
  g.clearInterval = () => { timer.cleared++; };

  g.api = async () => { throw new Error('no service in this test'); };

  const fns = liftAll('wizard.html', PAGE_FNS);
  // Functions the page calls by name resolve on the global scope.
  for (const n of PAGE_FNS) { if (!['render'].includes(n)) { g[n] = fns[n]; } }
  g.render = fns.render;
  g.paintScanProgress = async () => {};
  g.paintAdviceProgress = async () => {};
  g.stepChosen = false;   // as the page starts

  /** What start() does once it has a token: read, derive, draw. */
  async function load() {
    await fns.readRun();
    g.journey = fns.deriveJourney();
    g.step = fns.deriveStep();
    fns.render();
  }
  /** One tick of the watch, run to its end. */
  async function tick() {
    ok(timer.tick, 'the watch is running');
    await timer.tick();
  }
  return { store, failing, fns, els, shown, timer, reads, watches, watchTimeout, load, tick, step: () => g.step, html: () => el('#step').innerHTML };
}

/** An assessment, approved, with machines chosen and targets saved for them. */
function seedAssessment(store) {
  const pre = `${PROJECT}/${ASSESS}`;
  store.set(`${pre}/run.json`, { runId: ASSESS, kind: 'assessment' });
  store.set(`${pre}/approval.json`, { approvedBy: 'operator@example.com' });
  store.set(`${pre}/assessment.json`, { runId: ASSESS, vms: [{ vmId: VM, name: 'app-01', tags: {} }] });
  store.set(`${pre}/target-advice.json`, { schemaVersion: constOf('TARGET_ADVICE_VERSION'), machines: [{ vmId: VM, options: [] }] });
  store.set(`${pre}/machine-choices.json`, { machines: [VM] });
}
// The targets are saved against the version the service issued for the list.
function saveTargets(page) {
  const pre = `${PROJECT}/${ASSESS}`;
  const list = JSON.stringify(page.store.get(`${pre}/machine-choices.json`));
  page.store.set(`${pre}/target-choices.json`, { machinesVersion: `ver-${list.length}`, choices: [] });
}
/** What New-VmfPlan writes into the migration, in its order, before the plan. */
function seedMigrationStart(store) {
  const pre = `${PROJECT}/${MIGRATION}`;
  store.set(`${pre}/run.json`, { runId: MIGRATION, kind: 'migration', fromAssessment: ASSESS, project: PROJECT });
  store.set(`${pre}/assessment.json`, { runId: ASSESS, vms: [{ vmId: VM, name: 'app-01', tags: {} }] });
  store.set(`${pre}/target-choices.json`, { choices: [] });
  store.set(`${pre}/machine-choices.json`, { machines: [VM] });
}
function writePlan(store) {
  store.set(`${PROJECT}/${MIGRATION}/plan.json`, { entries: [{ vmId: VM, wave: 'wave-1', path: 'A' }] });
}
const MIGRATION_URL = `?run=${MIGRATION}&project=${PROJECT}&plan=1`;

test('the assessment with saved targets opens on the grouping form (the set-up is real)', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  eq(page.step(), STEP.migrate.group, 'step');
  ok(page.html().includes('id="go3"'), 'Build the waves is offered on the assessment');
});

test('THE DEFECT: a reload while the engine plans does not draw the grouping form again', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  await page.load();
  eq(page.step(), STEP.migrate.group, 'the step is still "how to group them"');
  ok(!page.html().includes('id="go3"'), 'no Build the waves: on a migration it would plan from the migration, and be refused');
  ok(!page.html().includes('type="radio"'), 'no grouping choices: the grouping is chosen already');
  ok(page.html().includes(UX.s3Working), 'it says the waves are being worked out');
});

test('a reload while the engine plans starts the watch', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  await page.load();
  eq(page.timer.started, 1, 'one watch is started on that load');
});

// LAB 2026-10-26, on the install: the engine's container took well over 30
// seconds to start, and the migration has no run.json until it does. A reload
// in that window showed the ASSESS journey at "Where should we look?", and
// nothing watched. Build the waves puts the assessment in the address.
const EARLY_URL = `?run=${MIGRATION}&project=${PROJECT}&plan=1&from=${ASSESS}`;

test('Build the waves puts the assessment it plans from in the address', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  globalThis.api = async () => ({ migrationId: MIGRATION });
  await page.fns.buildWaves();
  const q = new URLSearchParams(globalThis.location.search);
  eq([q.get('run'), q.get('project'), q.get('from')], [MIGRATION, PROJECT, ASSESS], 'the address');
});

test('THE LAB DEFECT: a reload before the migration has a run.json waits for the plan', async () => {
  const page = freshPage(EARLY_URL);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  eq([globalThis.journey, page.step()], ['migrate', STEP.migrate.group], 'journey and step');
  ok(page.html().includes(UX.s3Working), 'the waiting view');
  ok(!page.html().includes('id="go3"'), 'no grouping form');
  eq(page.shown, [], 'not the scope step');
  eq(page.timer.started, 1, 'a watch');
  await page.tick();
  eq(page.shown, [], 'still waiting');
  seedMigrationStart(page.store);
  await page.tick();
  eq(page.shown, [], 'still waiting once the migration exists');
  ok(page.html().includes(UX.s3Working), 'the waiting view stays');
  writePlan(page.store);
  await page.tick();
  eq(page.shown, ['arrange the waves'], 'the wave editor opens when the plan lands');
});

test('Back from that early waiting view goes to the assessment', async () => {
  const page = freshPage(EARLY_URL);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  page.els.get('#b').listeners.click();
  ok(globalThis.location.href.startsWith(`wizard.html?run=${ASSESS}&project=${PROJECT}`),
    `Back goes to the assessment: ${globalThis.location.href}`);
});

test('a run address with no record and no assessment named still starts at the scope step', async () => {
  const page = freshPage(`?run=new-run&project=${PROJECT}`);
  await page.load();
  eq([globalThis.journey, page.step()], ['assess', STEP.assess.scope], 'journey and step');
  eq(page.shown, ['scope'], 'the scope step');
});

test('run.json wins over a from= in the address: an assessment stays an assessment', async () => {
  // A stray from= (an edited or pasted address) must not turn an assessment
  // into a migration being planned. Its run.json says what it is.
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&from=other-assessment`);
  page.store.set(`${PROJECT}/${ASSESS}/run.json`, { runId: ASSESS, kind: 'assessment' });
  await page.load();
  eq([globalThis.journey, page.step()], ['assess', STEP.assess.findings], 'journey and step: the scan it waits for');
  eq(page.shown, ['findings'], 'the findings step');
  ok(!page.html().includes(UX.s3Working), 'no waiting view for a plan');
  eq(page.timer.started, 0, 'no migration watch');
});

test('drawing the waiting view again while the watch runs starts no second watch', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  await page.load();
  page.fns.render();
  eq(page.timer.started, 1, 'still one watch');
});

test('THE DEFECT: after that reload, the plan lands and a LATE tick goes to Arrange the waves', async () => {
  // A tab in a window behind others gets one timer a minute, so the plan is
  // long written by the time the next tick runs. One tick is enough.
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  await page.load();
  await page.tick();
  eq(page.shown, [], 'still waiting while there is no plan');
  writePlan(page.store);
  await page.tick();
  eq(page.step(), STEP.migrate.waves, 'step after the plan landed');
  eq(page.shown, ['arrange the waves'], 'the wave editor is opened');
});

test('the waiting view after a reload offers Back to the assessment (rule 11)', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  await page.load();
  const back = page.els.get('#b');
  ok(back && typeof back.listeners.click === 'function', 'a Back button with a handler');
  ok(page.html().includes('id="b"'), 'drawn on the waiting view');
  back.listeners.click();
  ok(globalThis.location.href.startsWith(`wizard.html?run=${ASSESS}&project=${PROJECT}`),
    `Back goes to the assessment: ${globalThis.location.href}`);
});

test('a reload of the migration with its plan built opens Arrange the waves', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store); writePlan(page.store);
  await page.load();
  eq(page.step(), STEP.migrate.waves, 'step');
  eq(page.shown, ['arrange the waves'], 'the wave editor is opened');
});

test('Build the waves: the watch follows the new migration to Arrange the waves', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  const posts = [];
  globalThis.api = async (method, route, body) => { posts.push({ method, route, body }); return { migrationId: MIGRATION }; };
  await page.fns.buildWaves();
  eq(globalThis.actionError, null, 'no error');
  eq(posts.length, 1, 'one plan request');
  ok(posts[0].route === `runs/${ASSESS}/engine/plan` && posts[0].body.waveStrategy === 'singleWave', `the request: ${JSON.stringify(posts[0])}`);
  ok(globalThis.location.search.includes(`run=${MIGRATION}`), 'the address names the migration');
  ok(page.html().includes(UX.s3Working), 'it says the waves are being worked out');
  // The job starts: nothing is written yet, then the migration, then the plan.
  await page.tick();
  eq(page.shown, [], 'nothing moves before the migration exists');
  ok(!page.html().includes('id="go3"'), 'and the grouping form is not drawn again');
  seedMigrationStart(page.store);
  await page.tick();
  eq(page.shown, [], 'nothing moves before the plan exists');
  ok(!page.html().includes('id="go3"'), 'still not the grouping form');
  ok(globalThis.poll !== null && page.timer.cleared === 0, 'and the watch goes on watching');
  writePlan(page.store);
  await page.tick();
  eq(page.step(), STEP.migrate.waves, 'step after the plan landed');
  eq(page.shown, ['arrange the waves'], 'the wave editor is opened');
});

test('the waiting view after Build the waves offers Back to the assessment it planned from', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  globalThis.api = async () => ({ migrationId: MIGRATION });
  await page.fns.buildWaves();
  ok(page.html().includes('id="b"'), 'a Back button on the waiting view');
  // Before the engine writes the migration, nothing read names the assessment.
  await page.tick();
  page.els.get('#b').listeners.click();
  ok(globalThis.location.href.startsWith(`wizard.html?run=${ASSESS}&project=${PROJECT}`),
    `Back goes to the assessment: ${globalThis.location.href}`);
});

test('THE LOST CLICK: a watch still running on the grouping form does not draw it again', async () => {
  // A watch the targets step started goes on when that step moves to the
  // grouping step. Its tick must leave the form - and the choice made on it - alone.
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  page.fns.startPolling();
  const drawn = page.els.get('#step');
  drawn.innerHTML += '<!-- drawn once -->';
  await page.tick();
  ok(drawn.innerHTML.endsWith('<!-- drawn once -->'), 'the form was not drawn again under the person');
});

test('the assess journey still draws the findings when the scan lands, and stops watching', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}`);
  page.store.set(`${PROJECT}/${ASSESS}/run.json`, { runId: ASSESS, kind: 'assessment' });
  await page.load();
  eq([globalThis.journey, page.step()], ['assess', STEP.assess.findings], 'waiting on the findings step');
  page.fns.startPolling();
  page.store.set(`${PROJECT}/${ASSESS}/assessment.json`, { runId: ASSESS, vms: [] });
  await page.tick();
  eq(page.shown, ['findings', 'findings'], 'the findings are drawn when the scan lands');
  eq(globalThis.poll, null, 'and the watch stops');
});

test('a plan that has started a machine opens the run, not the editor', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store); writePlan(page.store);
  page.store.set(`${PROJECT}/${MIGRATION}/state/app-01.json`, { vmId: VM, state: 'PRECHECK' });
  await page.load();
  eq(page.step(), STEP.running, 'step');
});

/* WIZARD-PLAN-FAIL-1: a refused plan waited for ever.
 *
 * When the engine refuses to plan, docker/entrypoint.ps1 writes the reason as
 * an engine:plan fail line in the ASSESSMENT's log - VMF_RUN_ID is the
 * assessment - and the migration may never get a run.json at all. The wizard
 * watched only the migration, so "Working out the waves" stayed for ever.
 * The fail line names the migration it was planning (migrationId), so a line
 * from an earlier plan of the same assessment is not this one's answer - on a
 * reload too, where the page has no time of its own to measure from.
 */
const LOG = `${PROJECT}/${ASSESS}/logs/events.jsonl`;
const REASON = 'No target was chosen for these machines yet. Choose the target for each machine, then plan.';
function logLines(store, events) {
  const old = store.get(LOG) || '';
  store.set(LOG, old + events.map(e => JSON.stringify(Object.assign({ tsUtc: new Date().toISOString() }, e))).join('\n') + '\n');
}
const refusal = (migrationId, detail) => ({ step: 'engine:plan', outcome: 'fail', detail: detail || REASON, migrationId });
// The watch ends with an answer, or goes on while the page waits: either way
// many of its 1 ms ticks have run by the time this returns.
const settle = () => Promise.race([(globalThis.planWatch && globalThis.planWatch.done) || Promise.resolve(),
  new Promise(r => setTimeout(r, 150))]);

async function pressBuild(page) {
  seedAssessment(page.store); saveTargets(page);
  await page.load();
  globalThis.api = async () => ({ migrationId: MIGRATION });
  await page.fns.buildWaves();
}

test('PLAN-FAIL: after Build the waves, a refusal in the assessment log stops the wait and says why', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  ok(page.html().includes(UX.s3Working), 'the waiting view first');
  logLines(page.store, [{ step: 'engine:plan', outcome: 'info', detail: 'Engine version 1.0 started the plan operation.' }, refusal(MIGRATION)]);
  await settle();
  ok(!page.html().includes(UX.s3Working), 'the spinner is gone');
  ok(page.html().includes(REASON), `the engine's reason is shown: ${page.html()}`);
  ok(page.html().includes(UX.s3Refused.split('{reason}')[0].trim()), 'with the words that say no plan was made');
  ok(page.html().includes(UX.s3RefusedNext), 'and what to do');
  eq(globalThis.poll, null, 'the watch for the plan stops: nothing more is coming');
  ok(page.timer.cleared > 0, 'its interval is cleared');
});

test('PLAN-FAIL: the refusal is read from the ASSESSMENT log, not the migration', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  logLines(page.store, [refusal(MIGRATION)]);
  await settle();
  ok(page.reads.includes(LOG), `the assessment log was read: ${page.reads.filter(r => r.includes('logs')).join(', ')}`);
  ok(!page.reads.some(r => r.startsWith(`${PROJECT}/${MIGRATION}/logs/`)), 'not a log under the migration');
});

test('PLAN-FAIL: the refused view offers Back to the assessment (rule 11)', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  logLines(page.store, [refusal(MIGRATION)]);
  await settle();
  ok(page.html().includes('id="b"'), 'a Back button on the refused view');
  page.els.get('#b').listeners.click();
  ok(globalThis.location.href.startsWith(`wizard.html?run=${ASSESS}&project=${PROJECT}`),
    `Back goes to the assessment: ${globalThis.location.href}`);
});

test('PLAN-FAIL: THE LAB CASE - a reload before the migration has a run.json shows the refusal', async () => {
  // The refusal came before New-VmfPlan wrote run.json: the migration never
  // exists. The address names the assessment, so the watch still knows where to read.
  const page = freshPage(EARLY_URL);
  seedAssessment(page.store); saveTargets(page);
  logLines(page.store, [refusal(MIGRATION)]);
  await page.load();
  await settle();
  ok(page.html().includes(REASON), `the reason is shown: ${page.html()}`);
  eq(globalThis.poll, null, 'and the watch for the plan stops');
});

test('PLAN-FAIL: a reload of a migration whose run.json exists reads its fromAssessment', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  logLines(page.store, [refusal(MIGRATION)]);
  await page.load();
  await settle();
  ok(page.html().includes(REASON), 'the reason is shown');
});

test('PLAN-FAIL: a refusal of an EARLIER plan of the same assessment does not stop the wait', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  page.store.set(LOG, '');
  logLines(page.store, [refusal('assess-1-migration-20261025-090000', 'yesterday: the targets were chosen on a different scan')]);
  await pressBuild(page);
  await settle();
  ok(!page.html().includes('yesterday'), 'the old reason is not shown');
  ok(page.html().includes(UX.s3Working), 'still the waiting view');
  ok(globalThis.poll !== null, 'still watching for the plan');
  // And the plan still lands.
  seedMigrationStart(page.store); writePlan(page.store);
  await page.tick();
  eq(page.shown, ['arrange the waves'], 'the wave editor opens when the plan lands');
});

test('PLAN-FAIL: a fail line of another operation, or with no migration named, is not this answer', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  page.watchTimeout.ms = 40;
  await pressBuild(page);
  logLines(page.store, [
    { step: 'engine:advise', outcome: 'fail', detail: 'advice failed', migrationId: MIGRATION },
    { step: 'engine:plan', outcome: 'fail', detail: 'a plan of some other migration' },
    { step: 'engine:plan', outcome: 'info', detail: 'not a fail line', migrationId: MIGRATION },
  ]);
  await settle();
  ok(page.html().includes(UX.s3Working), `still the waiting view: ${page.html()}`);
  ok(!/advice failed|some other migration|not a fail line/.test(page.html()), 'none of them is shown');
});

test('PLAN-FAIL: a refused line (LOG-SAYS-WHY-1) for this migration is an answer too', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  logLines(page.store, [{ step: 'engine:plan', outcome: 'refused', detail: REASON, migrationId: MIGRATION }]);
  await settle();
  ok(page.html().includes(REASON), `the reason is shown: ${page.html()}`);
});

test('PLAN-FAIL: the plan wins - a plan that lands is not called refused', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  seedMigrationStart(page.store); writePlan(page.store);
  await page.tick();
  eq(page.shown, ['arrange the waves'], 'the wave editor opens');
  logLines(page.store, [refusal(MIGRATION, 'capacity: the quota check failed')]);
  await settle();
  ok(!page.html().includes('quota check failed'), 'no refusal drawn over a plan that exists');
  eq(globalThis.planRefused, null, 'and none recorded');
});

test('PLAN-FAIL: the plan wins - a fail line after plan.json was written is not "no plan"', async () => {
  // The capacity check runs after New-VmfPlan writes plan.json; its failure is
  // an engine:plan fail line for this migration. The watch for the plan has
  // not read it yet.
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  seedMigrationStart(page.store); writePlan(page.store);
  logLines(page.store, [refusal(MIGRATION, 'capacity: the quota check failed')]);
  await settle();
  ok(!page.html().includes('quota check failed'), `no refusal drawn: ${page.html()}`);
  eq(globalThis.planRefused, null, 'and none recorded');
  ok(globalThis.poll !== null, 'the watch for the plan goes on');
  await page.tick();
  eq(page.shown, ['arrange the waves'], 'and it opens the plan');
});

test('PLAN-FAIL: the plan wins - a plan the page holds already is not called refused', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  page.watchTimeout.ms = 40;
  await pressBuild(page);
  // Held by the page (a read), and the step not moved on yet.
  globalThis.plan = { entries: [{ vmId: VM, wave: 'wave-1', path: 'A' }] };
  logLines(page.store, [refusal(MIGRATION, 'capacity: the quota check failed')]);
  await settle();
  eq(globalThis.planRefused, null, 'no refusal recorded');
  ok(!page.html().includes('quota check failed'), 'none drawn');
});

test('PLAN-FAIL: a plan that cannot be read is not "no plan": the refusal waits for a read', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  page.failing.add(`${PROJECT}/${MIGRATION}/plan.json`);
  logLines(page.store, [refusal(MIGRATION)]);
  await settle();
  eq(globalThis.planRefused, null, 'no refusal while the plan cannot be read');
  ok(page.html().includes(UX.s3Working), 'still the waiting view');
  page.failing.clear();
  await settle();
  ok(page.html().includes(REASON), 'shown once the read answers that there is no plan');
});

test('PLAN-FAIL: drawn again, the refused view stays, and no watch starts again', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  await pressBuild(page);
  logLines(page.store, [refusal(MIGRATION)]);
  await settle();
  const started = page.timer.started, watched = page.watches.length;
  page.fns.render();
  ok(page.html().includes(REASON), 'the reason is still shown');
  ok(!page.html().includes(UX.s3Working), 'not the spinner again');
  eq([page.timer.started, page.watches.length], [started, watched], 'no second watch');
});

test('PLAN-FAIL: one watch of the log, however often the waiting view is drawn', async () => {
  const page = freshPage(MIGRATION_URL);
  seedAssessment(page.store); saveTargets(page); seedMigrationStart(page.store);
  page.watchTimeout.ms = 30;
  await page.load();
  page.fns.render(); page.fns.render();
  eq(page.watches.length, 1, 'one watch');
});

test('PLAN-FAIL: NO ANSWER - after the quiet time it says nothing arrived, and keeps waiting', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  page.watchTimeout.ms = 30;
  await pressBuild(page);
  // Two rounds of the loop: the first ends with no answer.
  await new Promise(r => setTimeout(r, 80));
  const wait = page.els.get('#plan-wait');
  ok(wait && String(wait.textContent || wait.innerHTML).includes(UX.s3Quiet.replace('{n}', '10')),
    `it says nothing arrived: ${wait && (wait.textContent || wait.innerHTML)}`);
  ok(!page.html().includes(UX.s3Refused.split('{reason}')[0].trim()), 'it does not say the plan was refused');
  ok(globalThis.poll !== null, 'it still watches for the plan');
  eq(globalThis.planRefused, null, 'no refusal is recorded');
  // A refusal that comes late is still shown.
  page.watchTimeout.ms = 400;
  logLines(page.store, [refusal(MIGRATION)]);
  await settle();
  ok(page.html().includes(REASON), `a late refusal is shown: ${page.html()}`);
});

test('PLAN-FAIL: the watch of a page that has gone ends', async () => {
  const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
  page.watchTimeout.ms = 5000;
  await pressBuild(page);
  const mine = globalThis.planWatch;
  // The person goes Back: the page is a different page now.
  globalThis.planWatch = null;
  const t0 = Date.now();
  await mine.done;
  ok(Date.now() - t0 < 2000, `the watch ended at its next tick, not at its deadline: ${Date.now() - t0} ms`);
});

// WAVE-SIZE-REMOVE-1 (2026-11-08): no "Most machines in one wave". A
// grouping by tag or resource group is one wave per group, of any size; how
// many machines move at once is the wave's own setting.
for (const strategy of ['tags', 'resourceGroup']) {
  test(`WAVE-SIZE-REMOVE-1: grouping by ${strategy} asks for no wave size`, async () => {
    const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
    seedAssessment(page.store); saveTargets(page);
    globalThis.form.strategy = strategy;
    await page.load();
    ok(page.html().includes('id="go3"'), 'the grouping form is drawn (the set-up is real)');
    ok(!page.html().includes('f-size') && !page.html().includes('g-size'), 'no wave size field');
    ok(!('waveSize' in globalThis.UX), 'no wave size words');
  });

  test(`WAVE-SIZE-REMOVE-1: Build the waves by ${strategy} sends no wave size`, async () => {
    const page = freshPage(`?run=${ASSESS}&project=${PROJECT}&plan=1`);
    seedAssessment(page.store); saveTargets(page);
    globalThis.form.strategy = strategy;
    await page.load();
    const posts = [];
    globalThis.api = async (method, route, body) => { posts.push({ method, route, body }); return { migrationId: MIGRATION }; };
    await page.fns.buildWaves();
    eq(posts.length, 1, 'one plan request');
    eq(posts[0].body.waveStrategy, strategy, 'the grouping is sent');
    ok(!('waveSize' in posts[0].body), `no wave size in the request: ${JSON.stringify(posts[0].body)}`);
  });
}

test('PLAN-FAIL: the demo reads no log', async () => {
  // The early address: everything else a watch needs is there.
  const page = freshPage(EARLY_URL);
  seedAssessment(page.store); saveTargets(page);
  globalThis.DEMO_MODE = true;
  try {
    await page.fns.watchPlanRefusal();
    eq(page.watches.length, 0, 'no watch in the demo');
  } finally { globalThis.DEMO_MODE = false; }
});

test('PLAN-FAIL: planRefusal takes the fail line for THIS migration only', () => {
  // The last test: a watch left by an earlier test ends here, as it ends when
  // a page moves on, so the run can finish.
  globalThis.planWatch = null;
  const fns = liftAll('wizard.html', ['planRefusal']);
  eq(fns.planRefusal([], 'm1'), null, 'no lines');
  eq(fns.planRefusal(null, 'm1'), null, 'no log');
  eq(fns.planRefusal([refusal('m0')], 'm1'), null, 'another migration');
  eq(fns.planRefusal([refusal('m1', 'why')], 'm1'), { failure: refusal('m1', 'why') }, 'this migration');
  eq(fns.planRefusal([refusal('m1', 'first'), refusal('m1', 'last')], 'm1').failure.detail, 'last', 'the newest wins');
  eq(fns.planRefusal([{ step: 'engine:plan', outcome: 'fail', detail: 'x', migrationId: '' }], ''), null, 'no migration named on either side');
});
run('wizard-waves-step');
