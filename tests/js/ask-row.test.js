/* ASKROW-1: the confirmation must not push its own Cancel off the page.
 *
 * MEASURED 2026-09-15 on the Projects page at 1400px, in a browser, with the
 * real page: the confirmation ran 101px past the card, and
 * `.card { overflow:hidden }` cut it. "Yes, delete" stayed on screen and
 * CANCEL DID NOT - the destructive answer offered, the way out hidden, which
 * is hard rule 11 exactly backwards.
 *
 * It grew rightwards because it REPLACED the button, wherever the button
 * happened to sit - and on a table it sits in the last cell, against the edge.
 * It is anchored to the button's own container now, and the button stays in
 * place, hidden, so the cell keeps its width and nothing jumps.
 *
 * These test the part a stylesheet cannot: that the button is kept as a
 * spacer rather than removed, that the container is made a positioning
 * context, and that BOTH are given back on every way out.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const confirmInPlace = lift('help.js', 'confirmInPlace');

function fakeDom() {
  const docHandlers = {};
  const make = (tag) => ({
    tag, children: [], className: '', type: '', textContent: '',
    /* A real CSSStyleDeclaration answers '' for a property nobody set, and
     * `undefined` here would have made these tests pass on a restore that
     * wrote the wrong thing back. */
    style: new Proxy({}, { get: (t, k) => (k in t ? t[k] : ''), set: (t, k, v) => { t[k] = v; return true; } }),
    hidden: false, handlers: {},
    setAttribute() {}, focus() { fake.activeElement = this; },
    appendChild(c) { this.children.push(c); c.parentNode = this; return c; },
    insertBefore(c) { this.children.push(c); c.parentNode = this; return c; },
    removeChild(c) { this.children = this.children.filter(x => x !== c); c.parentNode = null; },
    replaceChild(a, b) { this.children = this.children.map(x => (x === b ? a : x)); a.parentNode = this; b.parentNode = null; },
    addEventListener(t, fn) { (this.handlers[t] ||= []).push(fn); },
    querySelectorAll() { return []; },
  });
  const fake = {
    activeElement: null,
    createElement: make,
    addEventListener(t, fn) { (docHandlers[t] ||= []).push(fn); },
    removeEventListener(t, fn) { docHandlers[t] = (docHandlers[t] || []).filter(x => x !== fn); },
    press(key) { for (const fn of docHandlers[key === 'Escape' ? 'keydown' : 'keydown'] || []) { fn({ key, preventDefault() {} }); } },
    listenerCount() { return (docHandlers.keydown || []).length; },
  };
  return fake;
}

function openOne() {
  global.document = fakeDom();
  const host = global.document.createElement('td');
  const btn = global.document.createElement('button');
  host.appendChild(btn);
  let said = null;
  confirmInPlace(btn, { ask: 'Delete this project?', yes: 'Yes, delete', cancel: 'Cancel' }, (v) => { said = v; });
  const row = host.children.find(c => c.className === 'askrow');
  const buttons = row.children.filter(c => c.tag === 'button');
  return { host, btn, row, yes: buttons[0], no: buttons[1], said: () => said };
}

test('the button is kept as a spacer, not removed', () => {
  // Removing it collapsed the cell, so the table jumped while the question
  // was on screen.
  const { host, btn } = openOne();
  ok(host.children.includes(btn), 'the button must stay in the cell');
  eq(btn.style.visibility, 'hidden');
});

test('and its container becomes the thing the row is anchored to', () => {
  const { host } = openOne();
  eq(host.style.position, 'relative');
});

test('Cancel gives back the button and the container', () => {
  const { host, btn, no } = openOne();
  no.handlers.click[0]();
  eq(btn.style.visibility, '');
  eq(host.style.position, '');
  eq(host.children.filter(c => c.className === 'askrow').length, 0);
});

test('and so does Escape', () => {
  const { host, btn } = openOne();
  global.document.press('Escape');
  eq(btn.style.visibility, '');
  eq(host.style.position, '');
});

test('and so does answering yes', () => {
  const { host, btn, yes, said } = openOne();
  yes.handlers.click[0]();
  eq(btn.style.visibility, '');
  eq(host.style.position, '');
  eq(said(), null, 'no field, so no value');
});

test('the Escape listener retires with the row', () => {
  // LEAK-2 again: one listener per open, and none left afterwards.
  const { no } = openOne();
  eq(global.document.listenerCount(), 1);
  no.handlers.click[0]();
  eq(global.document.listenerCount(), 0);
});

run('ASKROW-1: the confirmation stays inside its card');