/* WIZARD-PROJECTS-ERROR-1: the first step of Assess and migrate said there
 * were no projects when the service could not read the list.
 *
 * renderProjectPick caught a failed GET api/projects and used an empty list,
 * so the step said "You have no projects yet" and offered the create form -
 * a false statement - and dropped the sentence the service wrote about why.
 * PERF-PROJECTS-LIST-1 made a refused store listing fail the call, so this can
 * happen more often.
 *
 * Now a failed read shows the service's sentence through the page's own
 * failed-read display (failRead, READ-1) and a Try again button in the step,
 * and nothing that says the list is empty.
 *
 * RUN, not read: the page's own renderProjectPick, with its own UX table.
 */
'use strict';
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('wizard.html', 'UX');
globalThis.UX = UX;
globalThis.esc = (v) => String(v ?? '');
globalThis.card = (title, body, inner) => `<h2>${title}</h2><p>${body}</p><div class="cb">${inner}</div>`;
globalThis.roleAction = (id, label) => `<button id="${id}">${label}</button>`;
globalThis.canOperate = true;
globalThis.STEP = { assess: { scope: 1 } };
globalThis.history = { replaceState() {} };
globalThis.goStep = () => {};

// Elements made on first use, keyed by selector; listeners kept so a test can
// press a button the step drew.
function fakeDom() {
  const els = new Map();
  const make = () => {
    const el = { textContent: '', innerHTML: '', value: '', disabled: false, style: {}, listeners: {} };
    el.addEventListener = (type, fn) => { el.listeners[type] = fn; };
    return el;
  };
  const $ = (sel) => { if (!els.has(sel)) { els.set(sel, make()); } return els.get(sel); };
  $.has = (sel) => els.has(sel);
  return $;
}

function setup(answers) {
  const $ = fakeDom();
  globalThis.$ = $;
  const calls = [];
  globalThis.api = async (method, path) => {
    calls.push(`${method} ${path}`);
    const a = answers.shift();
    if (a instanceof Error) { throw a; }
    return a;
  };
  const shown = [];
  globalThis.VmfHelp = { explain: (e) => `explained: ${e.message}` };
  globalThis.failRead = (e) => { shown.push(e); $('#err').textContent = globalThis.VmfHelp.explain(e); $('#err').style.display = 'block'; };
  globalThis.fail = (e) => { throw e; };
  globalThis.clearErr = () => { $('#err').style.display = 'none'; };
  globalThis.projects = [];
  globalThis.projectsReadError = null;
  return { $, calls, shown };
}

const renderProjectPick = lift('wizard.html', 'renderProjectPick');
// Try again calls the step again by name, as the page's own scope would.
globalThis.renderProjectPick = renderProjectPick;
const REFUSED = 'The run store refused to list the projects folder.';

test('a failed project list shows the service sentence through failRead', async () => {
  const { $, shown } = setup([new Error(REFUSED)]);
  const el = $('#step');
  await renderProjectPick(el);
  eq(shown.length, 1, 'failRead is called once');
  eq(shown[0].message, REFUSED, 'with the error the service gave');
  eq($('#err').style.display, 'block', 'the page error is shown');
  ok($('#err').textContent.includes(REFUSED), 'and it holds the service sentence');
});

test('a failed project list does not say there are no projects, and has no create form', async () => {
  const { $ } = setup([new Error(REFUSED)]);
  const el = $('#step');
  await renderProjectPick(el);
  ok(!el.innerHTML.includes(UX.s0None), 'no "You have no projects yet"');
  ok(!el.innerHTML.includes('f-pname'), 'no project name box');
  ok(!el.innerHTML.includes(UX.s0Create), 'no Create and continue');
  ok(!el.innerHTML.includes(UX.s0OrNew), 'no "Or create a new project"');
  ok(el.innerHTML.includes(UX.s0ReadFailed), 'says the list could not be read');
  ok(el.innerHTML.includes(`id="p-retry"`) && el.innerHTML.includes(UX.s0Retry), 'offers Try again');
});

test('Try again clears the error and reads the list again', async () => {
  const { $, calls } = setup([new Error(REFUSED), { projects: [{ projectId: 'contoso-exit', name: 'Contoso exit' }] }]);
  const el = $('#step');
  await renderProjectPick(el);
  const press = $('#p-retry').listeners.click;
  ok(typeof press === 'function', 'the Try again button is wired');
  await press();
  eq(calls.length, 2, 'the list is asked for again');
  eq(calls[1], 'GET projects', 'from the same endpoint');
  eq($('#err').style.display, 'none', 'the old error goes');
  ok(el.innerHTML.includes('contoso-exit'), 'the step shows the projects it read');
  ok(!el.innerHTML.includes(UX.s0ReadFailed), 'and no longer says the read failed');
});

test('Try again that fails again says so again', async () => {
  const { $, shown } = setup([new Error(REFUSED), new Error('HTTP 503')]);
  const el = $('#step');
  await renderProjectPick(el);
  await $('#p-retry').listeners.click();
  eq(shown.length, 2, 'failRead is called for the second failure');
  eq(shown[1].message, 'HTTP 503', 'with the second error');
  ok(el.innerHTML.includes(UX.s0ReadFailed) && !el.innerHTML.includes(UX.s0None), 'still not an empty list');
});

test('a list the service read as empty still says there are no projects', async () => {
  const { $, shown } = setup([{ projects: [] }]);
  const el = $('#step');
  await renderProjectPick(el);
  eq(shown.length, 0, 'no error');
  ok(el.innerHTML.includes(UX.s0None), 'You have no projects yet');
  ok(el.innerHTML.includes('f-pname'), 'with the create form');
  ok(!el.innerHTML.includes(UX.s0ReadFailed), 'and no read failure');
});

test('the words are declared in the page', () => {
  ok(typeof UX.s0ReadFailed === 'string' && UX.s0ReadFailed.length > 0, 's0ReadFailed');
  ok(typeof UX.s0Retry === 'string' && UX.s0Retry.length > 0, 's0Retry');
});

run('wizard-projects-error');
