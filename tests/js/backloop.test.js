/* BACKLOOP-1: Back on the wave editor returned to the wave editor.
 *
 * A click on Back opened the same page again.
 *
 * waves.html sent Back to wizard.html with NO step. With a plan in place the
 * wizard derives step 2, which is the editor, so it redirected straight back.
 * Step 1 was unreachable once a plan existed, because nothing could ask for it.
 *
 * And step 1 on a planned migration must not plan again: the engine's plan
 * action always makes a NEW migration from the assessment, so pressing "Build
 * the waves" there would have made a second migration, not re-grouped this one.
 *
 * RUN, not read: the wizard's own deriveStep and renderStep3 are driven.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const WAVES = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
const constArrow = (src, name) => {
  const m = src.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};

const UX = liftConst('wizard.html', 'UX');
const fns = liftAll('wizard.html', ['deriveStep', 'renderStep3', 'backToAssessment']);

function at(query) {
  globalThis.location = { search: query, href: 'http://x/wizard.html' + query };
  globalThis.wantsRunStep = constArrow(WIZ, 'wantsRunStep');
  globalThis.wantsGroupStep = constArrow(WIZ, 'wantsGroupStep');
}
// The wizard's own step numbers, not a copy.
globalThis.STEP = liftConst('wizard.html', 'STEP');
// WAVES-BUTTON-RUNNING-1: the started states are help.js's, which every page asks.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['machineStarted']));

function migrationWithPlan() {
  globalThis.readFailed = false;
  globalThis.journey = 'migrate';
  globalThis.plan = { entries: [{ vmId: '/x/a', wave: 'w1', path: 'A' }] };
  globalThis.states = new Map();
  globalThis.step = STEP.migrate.waves;
}

test('RUN: with no step named, a planned migration derives the editor - the loop', () => {
  migrationWithPlan(); at('?run=r');
  eq(fns.deriveStep(), STEP.migrate.waves, 'which is why Back had to NAME a step');
});

test('RUN: step=group reaches step 1 of a planned migration', () => {
  migrationWithPlan(); at('?run=r&step=group');
  eq(fns.deriveStep(), STEP.migrate.group);
});

test('RUN: but never steps back over a running migration', () => {
  migrationWithPlan(); at('?run=r&step=group');
  globalThis.states = new Map([['/x/a', 'PRECHECK']]);
  eq(fns.deriveStep(), STEP.running, 'a run that has started shows its progress');
});

test('RUN: the Back button on the editor names the step', () => {
  ok(/backBtn\.addEventListener\('click', \(\) => \{ location\.href = runHref\('wizard\.html', \{ step: 'group' \}\); \}\);/.test(WAVES),
    'waves.html Back asks for step=group');
});

test('RUN: the poll does not move a person on from the step they asked for', () => {
  ok(/step === STEP\.migrate\.group && !wantsGroupStep\(\) && !stepChosen\) \{/.test(WIZ),
    'the plan-landed jump is skipped when step=group was asked for');
});

function paint() {
  const els = {};
  const el = (id) => (els[id] ??= { innerHTML: '', listeners: {}, addEventListener(e, f) { this.listeners[e] = f; }, style: {} });
  globalThis.$ = (sel) => el(sel);
  globalThis.document = { querySelectorAll: () => [] };
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.card = (title, body, inner) => `<h2>${title}</h2><p>${body}</p>${inner}`;
  globalThis.runHref = (page, extra) => page + '?run=r' + (extra && extra.flow ? '&flow=1' : '');
  globalThis.backToAssessment = fns.backToAssessment;
  globalThis.UX = UX;
  // WIZARD-WAVES-STEP-1: the grouping form is the ASSESSMENT's step; a
  // migration with no plan waits for it (wizard-waves-step.test.js).
  globalThis.manifest = { kind: 'assessment' };
  globalThis.planRefused = null;   // WIZARD-PLAN-FAIL-1: the page's own state, as it starts
  globalThis.isMigration = constArrow(WIZ, 'isMigration');
  globalThis.opt = constArrow(WIZ, 'opt');
  globalThis.buildWaves = () => {};
  globalThis.form = { strategy: 'tags', targetGeneration: 'v6' };
  globalThis.assessment = { vms: [] };
  // MACHINE-PICK-1: the tag list comes from the machines in this migration.
  globalThis.onlyChosen = lift('wizard.html', 'onlyChosen'); globalThis.machineChoices = null; globalThis.targetChoices = null;
  // WIZARD-ROLES-2: the step's action is drawn on the role; an operator here.
  globalThis.roleAction = lift('wizard.html', 'roleAction'); globalThis.canOperate = true;
  const target = { innerHTML: '' };
  fns.renderStep3(target);
  return { html: target.innerHTML, els };
}

test('RUN: step 1 of a planned migration says what is true and cannot plan again', () => {
  migrationWithPlan();
  const { html, els } = paint();
  ok(html.includes(UX.s3Planned), 'it says the machines are already in waves');
  ok(!html.includes('id="go3"'), 'there is no "Build the waves" - that would make a second migration');
  ok(/id="to-waves" href="waves\.html\?run=r&flow=1"/.test(html), 'forward to the waves');
  ok(typeof els['#b'].listeners.click === 'function', 'and a Back that works (rule 11)');
});

test('RUN: step 1 with NO plan still offers the grouping', () => {
  migrationWithPlan(); globalThis.plan = null;
  const { html } = paint();
  ok(html.includes('id="go3"'), 'the ordinary first step is unchanged');
  ok(!html.includes(UX.s3Planned), 'and does not claim a plan');
});

run('backloop');
