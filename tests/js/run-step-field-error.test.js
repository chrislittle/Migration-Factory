/* WIZARD-START-ERROR-OUT-OF-VIEW-1 and SIGNOFF-NOTE-ERROR-1: on the wizard's
 * Run it step, a button that refuses for a missing field said why at the TOP
 * of the page, out of view.
 *
 * Seen on the lab install, 2026-11-14: after a reload of the Run it step the
 * note box was empty, and a click on Start the plan seemed to do nothing. The
 * page had written "Please add a short note" into its error line at the top
 * of the page. Sign off the plan did the same (filed 2026-11-01).
 *
 * The rule now: the error shows beside the field it is about (the note box,
 * or the tick about machines defined in code), the field is marked invalid,
 * and the focus goes to the field, so the error is where the person looks.
 * The Migrations page dialog already showed its note error beside the note
 * (#m-err, LAB-UX-1); this is the same look on the wizard.
 *
 * RUN, not read: the wizard's own renderStep5 is drawn, and the click
 * handlers it wires are called. The page error (`fail`) is a spy, so a
 * handler that still sends the error to the top of the page fails here.
 */
'use strict';
const { test, ok, eq, run, liftConst, lift } = require('./_harness');

const UX = liftConst('wizard.html', 'UX');
const renderStep5 = lift('wizard.html', 'renderStep5');

/* A small DOM: one node per selector, kept, so the test reads the node the
 * handler wrote to. getElementById and querySelector share the same nodes. */
function fakeDom() {
  const nodes = new Map();
  const make = (sel) => {
    const n = {
      sel, id: sel.startsWith('#') ? sel.slice(1) : '', value: '', checked: false, textContent: '', innerHTML: '',
      hidden: true, disabled: false, style: {}, attrs: {}, listeners: {}, focused: 0, scrolled: [],
      addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); },
      setAttribute(k, v) { this.attrs[k] = String(v); },
      removeAttribute(k) { delete this.attrs[k]; },
      getAttribute(k) { return k in this.attrs ? this.attrs[k] : null; },
      focus() { this.focused++; },
      scrollIntoView(opts) { this.scrolled.push(opts); },
      querySelectorAll: () => [], querySelector: () => null,
    };
    return n;
  };
  const get = (sel) => { if (!nodes.has(sel)) { nodes.set(sel, make(sel)); } return nodes.get(sel); };
  return { get, nodes };
}

function setUp({ signoff = null, acked = true, operator = true, approver = true, realAction = false, how = 'all', times = {} } = {}) {
  const dom = fakeDom();
  const calls = { fail: [], api: [] };
  const waves = [['w1', { n: 2 }]];
  globalThis.UX = UX;
  globalThis.planWaves = () => waves;
  globalThis.plan = { entries: [{ wave: 'w1', policy: { throttle: 5 } }] };
  globalThis.runForm = { note: '', ack: false, how, times };
  globalThis.acceptances = new Map([['w1', { acceptedBy: 'operator@example.com' }]]);
  globalThis.planSignoff = signoff;
  globalThis.planSignoffCurrent = true;
  globalThis.approvals = new Map();
  globalThis.waveSignState = lift('wizard.html', 'waveSignState');
  globalThis.canApprove = approver;
  globalThis.canOperate = operator;
  globalThis.acceptControl = lift('wizard.html', 'acceptControl');
  globalThis.acceptAllControl = lift('wizard.html', 'acceptAllControl');
  globalThis.startControl = lift('wizard.html', 'startControl');
  globalThis.acknowledged = acked;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.card = (t, b, inner) => `<h2>${t}</h2><p>${b}</p>${inner}`;
  globalThis.leverRowsFor = () => '';
  globalThis.tempSections = () => '';
  globalThis.sizeRowsFor = () => '';
  globalThis.runHref = (p) => p;
  globalThis.VmfHelp = require('./_identity').help({ WAVE_MAX_WORKERS: 60, waveEstimate: () => '' });
  // Its own tests cover what it says; here only where it is said.
  globalThis.VmfHelp.explainAction = (e) => String(e && e.message);
  globalThis.$ = (sel) => dom.get(sel);
  globalThis.document = {
    getElementById: (id) => dom.get(`#${id}`),
    querySelector: (sel) => dom.get(sel),
    // The field error boxes the page drew: each node whose id ends in -err.
    querySelectorAll: (sel) => (sel === '.f-err' ? [...dom.nodes.values()].filter(n => /-err$/.test(n.id)) : []),
  };
  globalThis.tHelpBtn = lift('wizard.html', 'tHelpBtn');
  globalThis.tHelp = new Set();
  globalThis.helpWire = () => {};
  globalThis.exportPlan = () => {};
  globalThis.paintStartFailure = () => {};
  globalThis.fail = (e) => { calls.fail.push(e && e.message); };
  // realAction: the page's own failAction, which writes the error line at the
  // top of the page (#err) - the refusals of the service go there.
  globalThis.failAction = realAction ? lift('wizard.html', 'failAction') : (e) => { calls.fail.push(e && e.message); };
  globalThis.clearErr = lift('wizard.html', 'clearErr');
  globalThis.failField = lift('wizard.html', 'failField');
  globalThis.clearFieldErr = lift('wizard.html', 'clearFieldErr');
  globalThis.markBusy = () => () => {};
  globalThis.saveIacAck = async () => false;
  globalThis.readRun = async () => {};
  globalThis.render = () => {};
  globalThis.blobVersioned = async () => ({ version: 'v1' });
  globalThis.DEMO_MODE = false;
  globalThis.runPrefix = () => 'runs/r1';
  globalThis.runSeg = () => 'r1';
  globalThis.runBody = (b) => b;
  globalThis.api = async (m, u, b) => { calls.api.push([m, u, b]); return {}; };
  globalThis.watchForRefusal = () => {};
  // The Accept button of the wave, and Accept all: the handlers the step wires.
  const acceptBtn = dom.get('[data-accept]');
  acceptBtn.dataset = { accept: 'w1' };
  const el = {
    innerHTML: '',
    querySelectorAll: (sel) => (sel === '[data-accept]' ? [acceptBtn] : []),
    querySelector: (sel) => (sel === '[data-accept-all]' ? dom.get('[data-accept-all]') : null),
  };
  renderStep5(el);
  const click = (id) => {
    const sel = id.startsWith('[') ? id : `#${id}`;
    const node = dom.get(sel);
    const fns = node.listeners.click || [];
    ok(fns.length === 1, `one click handler on ${sel}`);
    return fns[0]({ currentTarget: node });
  };
  return { dom, calls, html: el.innerHTML, click };
}

test('the markup: an error box sits right under the note box, and one right under the tick', () => {
  const { html } = setUp({ acked: false });
  ok(/<textarea id="f-note"[^>]*><\/textarea>\s*<p class="f-err" id="f-note-err" role="alert" hidden><\/p>/.test(html),
    'the note error box follows the note box, hidden, read out when it shows');
  ok(/<textarea id="f-note"[^>]*aria-describedby="f-note-err"/.test(html), 'the note box names its error box');
  ok(/<label class="ackrow">[\s\S]*?<\/label>\s*<p class="f-err" id="f-ack-err" role="alert" hidden><\/p>/.test(html),
    'the tick error box follows the tick');
  ok(/<input type="checkbox" id="f-ack"[^>]*aria-describedby="f-ack-err"/.test(html), 'the tick names its error box');
});

test('Sign off the plan with no note: the error shows beside the note box, and the focus goes there', async () => {
  const { dom, calls, click } = setUp();
  dom.get('#f-note').value = '   ';
  await click('signoff');
  const box = dom.get('#f-note-err');
  eq(box.hidden, false, 'the error box beside the note shows');
  eq(box.textContent, UX.noteMissing, 'and asks for the note');
  eq(dom.get('#f-note').focused, 1, 'the focus goes to the note box');
  eq(dom.get('#f-note').getAttribute('aria-invalid'), 'true', 'the note box is marked invalid');
  eq(box.scrolled, [{ block: 'nearest' }], 'the error is brought into view the nearest way');
  eq(calls.fail, [], 'nothing goes to the error line at the top of the page');
  eq(calls.api, [], 'and nothing is sent');
});

test('Start the plan with no note (the box is empty after a reload): the error shows beside the note box', async () => {
  const { dom, calls, click } = setUp({ signoff: { approvedBy: { identity: 'approver@example.com' } } });
  dom.get('#f-note').value = '';
  await click('go5');
  eq(dom.get('#f-note-err').hidden, false, 'the error box beside the note shows');
  eq(dom.get('#f-note-err').textContent, UX.noteMissing, 'and asks for the note');
  eq(dom.get('#f-note').focused, 1, 'the focus goes to the note box');
  eq(calls.fail, [], 'nothing goes to the error line at the top of the page');
  eq(calls.api, [], 'and the plan does not start');
});

test('Start the plan with a note but no tick: the error shows beside the tick, the note error goes', async () => {
  const { dom, calls, click } = setUp({ signoff: { approvedBy: { identity: 'approver@example.com' } }, acked: false });
  dom.get('#f-note').value = '';
  await click('go5');
  eq(dom.get('#f-note-err').hidden, false, 'first the note error');
  dom.get('#f-note').value = 'change window 12';
  dom.get('#f-ack').checked = false;
  await click('go5');
  eq(dom.get('#f-note-err').hidden, true, 'the note error goes once the note is there');
  eq(dom.get('#f-note').getAttribute('aria-invalid'), null, 'and the note box is valid again');
  eq(dom.get('#f-ack-err').hidden, false, 'the error box beside the tick shows');
  eq(dom.get('#f-ack-err').textContent, UX.iacMissing, 'and asks for the tick');
  eq(dom.get('#f-ack').focused, 1, 'the focus goes to the tick');
  eq(calls.fail, [], 'nothing goes to the error line at the top of the page');
  eq(calls.api, [], 'and the plan does not start');
});

test('with the note and the tick, Start clears every field error and starts', async () => {
  const { dom, calls, click } = setUp({ signoff: { approvedBy: { identity: 'approver@example.com' } }, acked: false });
  dom.get('#f-note').value = 'change window 12';
  await click('go5');
  eq(dom.get('#f-ack-err').hidden, false, 'no tick: the tick error shows');
  dom.get('#f-ack').checked = true;
  await click('go5');
  eq(dom.get('#f-ack-err').hidden, true, 'the tick error goes');
  eq(dom.get('#f-ack').getAttribute('aria-invalid'), null, 'and the tick is valid again');
  ok(calls.api.some(([, u]) => /engine\/wave$/.test(u)), 'and the first wave starts');
});

test('typing a note removes its error at once', async () => {
  const { dom, click } = setUp();
  dom.get('#f-note').value = '';
  await click('signoff');
  eq(dom.get('#f-note-err').hidden, false, 'shown');
  const onInput = (dom.get('#f-note').listeners.input || [])[0];
  ok(onInput, 'the note box has an input handler');
  onInput({ target: { value: 'c' } });
  eq(dom.get('#f-note-err').hidden, true, 'gone while the person types');
  eq(dom.get('#f-note').getAttribute('aria-invalid'), null, 'and the box is valid again');
});

test('ticking the box removes its error at once', async () => {
  const { dom, click } = setUp({ signoff: { approvedBy: { identity: 'approver@example.com' } }, acked: false });
  dom.get('#f-note').value = 'x';
  await click('go5');
  eq(dom.get('#f-ack-err').hidden, false, 'shown');
  const onChange = (dom.get('#f-ack').listeners.change || [])[0];
  onChange({ target: { checked: true } });
  eq(dom.get('#f-ack-err').hidden, true, 'gone once ticked');
});

test('a field with no error box on the page falls back to the page error, so the reason is never lost', () => {
  setUp();
  const said = [];
  globalThis.fail = (e) => { said.push(e.message); };
  globalThis.document.getElementById = () => null;
  globalThis.failField({ id: 'f-none', focus() {}, setAttribute() {} }, 'why');
  eq(said, ['why'], 'the page error says it');
});

/* The review (2026-11-14): a refusal of the SERVICE - a 409 because the plan
 * changed, a 403, a network failure - went to the error line at the top of the
 * page with no scroll and no focus: the same "the button does nothing". */
const signed = { approvedBy: { identity: 'approver@example.com' } };
const refuse = () => { globalThis.api = async () => { throw new Error('409: the plan changed since this page read it'); }; };
function saidInView(dom, what) {
  const err = dom.get('#err');
  eq(err.style.display, 'block', `${what}: the error line shows`);
  ok(/409/.test(err.textContent), `${what}: it says the refusal`);
  eq(err.focused, 1, `${what}: it takes the focus`);
  eq(err.scrolled, [{ block: 'nearest' }], `${what}: it comes into view the nearest way`);
}

test('a refused Start the plan: the error comes into view and takes the focus', async () => {
  const { dom, click } = setUp({ signoff: signed, realAction: true });
  dom.get('#f-note').value = 'change window 12';
  refuse();
  await click('go5');
  saidInView(dom, 'Start');
});

test('a refused Sign off the plan: the error comes into view and takes the focus', async () => {
  const { dom, click } = setUp({ realAction: true });
  dom.get('#f-note').value = 'change window 12';
  refuse();
  await click('signoff');
  saidInView(dom, 'Sign off');
});

test('a refused Accept: the error comes into view and takes the focus', async () => {
  const { dom, click } = setUp({ realAction: true });
  refuse();
  await click('[data-accept]');
  saidInView(dom, 'Accept');
});

test('a refused Accept all: the error comes into view and takes the focus', async () => {
  const { dom, click } = setUp({ realAction: true });
  refuse();
  await click('[data-accept-all]');
  saidInView(dom, 'Accept all');
});

test('a start time in the past: the error comes into view and takes the focus', async () => {
  const { dom, click } = setUp({ signoff: signed, realAction: true, how: 'times', times: { w1: '2000-01-01T00:00' } });
  dom.get('#f-note').value = 'change window 12';
  await click('go5');
  const err = dom.get('#err');
  eq(err.textContent, UX.whenPast, 'it says the time is past');
  eq([err.focused, err.scrolled.length], [1, 1], 'in view, with the focus');
});

test('Accept and Accept all clear an old error before they try again', async () => {
  for (const sel of ['[data-accept]', '[data-accept-all]']) {
    const { dom, click } = setUp({ realAction: true });
    dom.get('#err').style.display = 'block';
    await click(sel);
    eq(dom.get('#err').style.display, 'none', `${sel}: the old error goes`);
  }
});

test('the error line can take the focus, and a screen reader says it', () => {
  const html = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'), 'utf8');
  ok(/<div id="err" role="alert" tabindex="-1"><\/div>/.test(html), 'role="alert" and tabindex="-1" on #err');
});

run('run-step-field-error');
