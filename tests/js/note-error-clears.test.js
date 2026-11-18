/* LAB-UX-1: "Please add a short note" stayed on screen after the action it
 * was about had gone through. Two places:
 *
 *   - the Migrations page dialog: the error stayed while the confirmed action
 *     ran, and closing the dialog did not remove it;
 *   - the wizard's Run it step: the page error stayed after the plan was
 *     signed off, and started, with a note.
 *
 * And Start the plan went grey with no words while the service started the
 * engine, so the plan looked as if it had not started.
 *
 * RUN, not read: the pages' own openModal, closeModal, clearErr and markBusy.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// A few elements, made on first use, keyed by selector.
function fakeDom() {
  const els = new Map();
  const el = () => ({
    textContent: '', innerHTML: '', value: '', disabled: false, style: {}, onclick: null,
    classList: { set: new Set(), add(c) { this.set.add(c); }, remove(c) { this.set.delete(c); } },
    querySelectorAll: () => [], querySelector: () => null, addEventListener() {}, focus() {},
  });
  return (sel) => { if (!els.has(sel)) { els.set(sel, el()); } return els.get(sel); };
}

globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.document = { querySelector: () => null, querySelectorAll: () => [] };
// CLICKS-LOST-1: the wizard's markBusy is help.js's, shared by every page.
globalThis.VmfHelp = { explainAction: (e) => String(e && e.message), markBusy: lift('help.js', 'markBusy') };
globalThis.followThrough = () => {};
// DIALOG-STALE-1: the page's own `let`, which openModal and closeModal clear.
globalThis.modalMachine = null;
const modal = liftAll('migrations.html', ['closeModal', 'openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText']);

test('the dialog: the note error goes as soon as the note is there, while the action runs', async () => {
  const $ = fakeDom(); globalThis.$ = $;
  let release;
  const pending = new Promise(r => { release = r; });
  modal.openModal({ title: 't', desc: 'd', fields: [{ id: 'note', type: 'textarea', required: true }],
    onConfirm: () => pending });
  $('#mf-note').value = '';
  await $('#m-confirm').onclick();
  eq($('#m-err').style.display, 'block', 'no note: the error is shown');
  eq($('#m-err').textContent, globalThis.UX_ACT.noteMissing, 'and it asks for the note');
  $('#mf-note').value = 'change window 12';
  const done = $('#m-confirm').onclick();
  eq($('#m-err').style.display, 'none', 'with a note, the error goes before the action returns');
  release('ok');
  await done;
  eq($('#m-err').style.display, 'none', 'and stays gone after it');
});

test('the dialog: closing it removes its error', () => {
  const $ = fakeDom(); globalThis.$ = $;
  $('#m-err').style.display = 'block';
  modal.closeModal();
  eq($('#m-err').style.display, 'none', 'closed with it');
});

test('the wizard: clearErr hides the page error', () => {
  const $ = fakeDom(); globalThis.$ = $;
  const clearErr = lift('wizard.html', 'clearErr');
  // WIZARD-START-ERROR-OUT-OF-VIEW-1: and every field error of the Run it step
  // (run-step-field-error.test.js runs the field errors themselves).
  let fieldsCleared = 0;
  globalThis.clearFieldErr = () => { fieldsCleared++; };
  $('#err').style.display = 'block';
  clearErr();
  eq($('#err').style.display, 'none', 'hidden');
  eq(fieldsCleared, 1, 'the field errors go with it');
});

test('the wizard: a busy button says what it is doing, and the way back restores it', () => {
  const markBusy = lift('wizard.html', 'markBusy');
  const btn = { textContent: 'Start the plan', disabled: false };
  const undo = markBusy(btn, 'Starting the plan...');
  eq([btn.disabled, btn.textContent], [true, 'Starting the plan...'], 'busy');
  undo();
  eq([btn.disabled, btn.textContent], [false, 'Start the plan'], 'restored after a failure');
});

// Wiring: the handlers call them BEFORE the first request, which is where the
// wait is. Read from the handler bodies only.
const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const handler = (id) => {
  const at = WIZ.indexOf(`$('#${id}')?.addEventListener('click'`);
  ok(at > 0, `${id} handler found`);
  return WIZ.slice(at, WIZ.indexOf('\n  });', at));
};
test('the wizard: Start the plan marks itself busy and clears the error before it calls the service', () => {
  const h = handler('go5');
  const busy = h.indexOf('markBusy($(\'#go5\'), UX.startPlanBusy)');
  const clear = h.indexOf('clearErr()');
  const first = h.indexOf('await api(');
  ok(busy > 0 && clear > 0 && first > 0, 'all three are in the handler');
  ok(clear < first && busy < first, 'both come before the first request');
  ok(/catch \(e\) \{ failAction\(e\); undoBusy\(\); \}/.test(h), 'a failed start gives the button back');
});
test('the wizard: Sign off clears the error before it calls the service', () => {
  const h = handler('signoff');
  ok(h.indexOf('clearErr()') > 0 && h.indexOf('clearErr()') < h.indexOf('await '), 'cleared first');
});

run('note-error-clears');
