/* LEAK-2: a dialog's Escape listener must retire with the dialog.
 *
 * The listener lives on `document`, so it outlives the dialog node unless
 * something takes it off. It used to be removed on exactly ONE path - inside
 * the Escape branch itself. Every other way a dialog closes (the backdrop
 * click, and every button whose onClick does d.remove()) detached the node and
 * left the listener installed, holding a closure over the whole detached
 * dialog.
 *
 * One more per help menu, guide, About or bundle dialog opened and closed, on
 * a page the product expects somebody to leave open all day. Each accumulated
 * copy then runs on every keypress.
 *
 * The fix has three exits, because a caller's own onClick is not ours to
 * change, so these tests drive all three.
 */
'use strict';
const { lift, test, eq, run } = require('./_harness');

const dialog = lift('help.js', 'dialog');

/** The smallest DOM that `dialog` actually touches. */
function fakeDom() {
  const listeners = [];          // what is currently on `document`
  const make = (tag) => {
    const el = {
      tag, children: [], isConnected: false, handlers: {},
      style: {}, className: '', type: '', textContent: '', _html: '',
      set innerHTML(v) { this._html = v; },
      get innerHTML() { return this._html; },
      setAttribute() {},
      appendChild(child) { this.children.push(child); return child; },
      // Memoised, so the actions row the buttons are appended to is the same
      // node the test can reach afterwards.
      querySelector(sel) {
        this._q = this._q || {};
        if (!this._q[sel]) { this._q[sel] = make('div'); }
        return this._q[sel];
      },
      addEventListener(type, fn) { (this.handlers[type] ||= []).push(fn); },
      remove() { this.isConnected = false; },
    };
    return el;
  };
  global.document = {
    createElement: make,
    body: { appendChild(el) { el.isConnected = true; return el; } },
    addEventListener(type, fn) { listeners.push({ type, fn }); },
    removeEventListener(type, fn) {
      const i = listeners.findIndex(l => l.type === type && l.fn === fn);
      if (i >= 0) { listeners.splice(i, 1); }
    },
  };
  global.esc = (s) => String(s ?? '');
  global.TEXT = { title: 'Help' };
  return {
    listeners,
    press(key) { for (const l of [...listeners]) { l.fn({ key }); } },
  };
}

test('opening a dialog installs exactly one keydown listener', () => {
  const dom = fakeDom();
  dialog('<p>body</p>', [], 'Title');
  eq(dom.listeners.length, 1, 'listeners on document');
});

test('Escape closes it AND takes the listener away', () => {
  const dom = fakeDom();
  const back = dialog('<p>body</p>', [], 'Title');
  dom.press('Escape');
  eq(back.isConnected, false, 'dialog removed');
  eq(dom.listeners.length, 0, 'listeners left behind');
});

test('THE DEFECT: a button that removes the node leaves nothing behind', () => {
  /* This is how nearly every dialog in the product is closed - the caller's
   * onClick calls d.remove() and never passes through close(). Before the fix
   * the listener stayed for the life of the page. */
  const dom = fakeDom();
  const back = dialog('<p>body</p>', [{ label: 'Close', onClick: (d) => d.remove() }], 'Title');
  const btn = back.querySelector('#vmf-help-actions').children[0];
  for (const fn of (btn.handlers.click || [])) { fn(); }
  eq(back.isConnected, false, 'dialog removed by the button');
  eq(dom.listeners.length, 0, 'listeners left behind');
});

test('a backdrop click takes the listener away too', () => {
  const dom = fakeDom();
  const back = dialog('<p>body</p>', [], 'Title');
  for (const fn of (back.handlers.click || [])) { fn({ target: back }); }
  eq(back.isConnected, false, 'dialog removed by the backdrop');
  eq(dom.listeners.length, 0, 'listeners left behind');
});

test('a key pressed after the dialog is gone retires the listener', () => {
  /* The last line of defence: if a caller removes the node in some way we did
   * not anticipate, the next keypress notices and cleans up rather than
   * sweeping a detached dialog forever. */
  const dom = fakeDom();
  const back = dialog('<p>body</p>', [], 'Title');
  back.remove();                     // closed behind our back
  dom.press('a');                    // not Escape
  eq(dom.listeners.length, 0, 'listeners left behind');
});

test('twenty dialogs opened and closed by button leave nothing on document', () => {
  const dom = fakeDom();
  for (let i = 0; i < 20; i++) {
    const back = dialog('<p>body</p>', [{ label: 'Close', onClick: (d) => d.remove() }], 'Title');
    const btn = back.querySelector('#vmf-help-actions').children[0];
    for (const fn of (btn.handlers.click || [])) { fn(); }
  }
  eq(dom.listeners.length, 0, 'listeners after 20 open/close cycles');
});

run('dialog-listener');
