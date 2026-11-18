/* DISK-DELETE-CLICK-1, measured on the lab install 2026-11-09, on the
 * Migrations page, in the panel of a machine that rolled back: a press on
 * "Delete these disks" closed the WHOLE panel. No slide-out came, and the
 * console showed no error.
 *
 * The cause, traced with a hook on closeDrill: the button's own listener runs
 * first (toggleDiskDelete -> refreshDrill -> openDrill writes #drill-body
 * again), so when the click reaches the document listener its target is a
 * node that has LEFT the page. target.closest('#drill') of a detached node is
 * null, so the click read as a click outside the panel, and closeDrill threw
 * the open slide-out away (diskDelete = null).
 *
 * RUN, not read: the page's own dismissOnOutsideClick, closeDrill,
 * toggleDiskDelete, closeDiskDelete, confirmDiskDelete and toggleMadeHelp,
 * against a small DOM of our own whose refreshDrill draws the panel body
 * again, exactly as the page does, BEFORE the document listener runs. The
 * event's path is taken at dispatch, as a browser does.
 */
'use strict';
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
const { pageSource } = require('./_page-source');

/* ---- a small DOM --------------------------------------------------------- */

function node(tag, opts = {}) {
  const n = {
    tagName: tag.toUpperCase(), id: opts.id || '', cls: new Set(opts.cls || []), parentElement: null, children: [],
    attrs: {},
    classList: null,
    setAttribute(k, v) { this.attrs[k] = String(v); },
    append(c) { c.parentElement = this; this.children.push(c); return c; },
    clear() { for (const c of this.children) { c.parentElement = null; } this.children = []; },
    matches(sel) {
      if (sel.startsWith('#')) { return this.id === sel.slice(1); }
      const [t, c] = sel.split('.');
      return this.tagName === t.toUpperCase() && this.cls.has(c);
    },
    closest(sel) { for (let x = this; x; x = x.parentElement) { if (x.matches(sel)) { return x; } } return null; },
    contains(x) { for (let y = x; y; y = y.parentElement) { if (y === this) { return true; } } return false; },
  };
  n.classList = {
    contains: (c) => n.cls.has(c), add: (c) => n.cls.add(c), remove: (c) => n.cls.delete(c),
    toggle: (c) => { if (n.cls.has(c)) { n.cls.delete(c); return false; } n.cls.add(c); return true; },
  };
  return n;
}

let page;   // the page's root
let byId;   // every node by id, as $ reads it - only nodes still on the page
function connected(n) { for (let x = n; x; x = x.parentElement) { if (x === page) { return true; } } return false; }
function find(id) {
  const walk = (n) => { if (n.id === id) { return n; } for (const c of n.children) { const r = walk(c); if (r) { return r; } } return null; };
  return walk(page);
}

/* The panel body as openDrill draws it: the delete links, the open
 * slide-out's Cancel and Delete, and the (?). Each draw makes NEW nodes. */
function drawDrillBody() {
  const body = find('drill-body');
  body.clear();
  for (const kind of ['earlier', 'made', 'original']) {
    const box = body.append(node('div', { cls: ['diskdel'] }));
    box.append(node('button', { id: `${kind}delete-btn` }));
    if (globalThis.diskDelete && globalThis.diskDelete.kind === kind) {
      const slide = box.append(node('div', { cls: ['diskdel-slide'] }));
      slide.append(node('button', { id: `${kind}delete-go` }));
      slide.append(node('button', { id: `${kind}delete-cancel` }));
    }
  }
  body.append(node('button', { id: 'madehelp-btn' }));
}
function drawWaveTable() {
  const tb = find('waves');
  tb.clear();
  const row = tb.append(node('tr', { cls: ['vm-row'] }));
  row.append(node('td', { id: 'row-cell' }));
  tb.append(node('button', { id: 'wavetoggle' }));
}
function drawRunPanel() {
  const rp = find('run-panel');
  rp.clear();
  rp.append(node('button', { id: 'run-more' }));
}

function setup() {
  page = node('html');
  const body = page.append(node('body'));
  body.append(node('div', { id: 'run-current' }));
  body.append(node('div', { id: 'run-panel', cls: ['run-panel'] }));
  body.append(node('button', { id: 'act-menu-btn' }));
  body.append(node('div', { id: 'act-panel', cls: ['run-panel'] }));
  body.append(node('table', { id: 'waves' }));
  const modal = body.append(node('div', { id: 'modal-back' }));
  modal.append(node('button', { id: 'm-ok' }));
  const drill = body.append(node('aside', { id: 'drill', cls: ['open'] }));
  drill.append(node('button', { id: 'drill-close' }));
  drill.append(node('div', { id: 'drill-body' }));
  body.append(node('p', { id: 'elsewhere' }));
  globalThis.diskDelete = null;
  globalThis.madeHelpOpen.clear();
  drawDrillBody();
  drawWaveTable();
  drawRunPanel();
}

/* A click as a browser dispatches it: the path is fixed BEFORE any listener
 * runs, then the control's own listener, then the document's. */
function click(id, ownListener) {
  const target = find(id);
  if (!target) { throw new Error(`no #${id} on the page`); }
  const at = [];
  for (let x = target; x; x = x.parentElement) { at.push(x); }
  at.push({ nodeName: '#document' }); // the document and the window have no matches()
  at.push({ nodeName: 'window' });
  const e = { target, composedPath: () => at.slice(), stopPropagation() {} };
  if (ownListener) { ownListener(e); }
  P.dismissOnOutsideClick(e);
  return e;
}

/* ---- the page's own functions -------------------------------------------- */

let sent = 0;
Object.assign(globalThis, {
  $: (sel) => { const n = find(sel.replace(/^#/, '')); return n; },
  madeHelpOpen: new Set(),
  diskDelete: null,
  drillVmId: 'vm-1',
  refreshDrill: () => { if (!find('drill').classList.contains('open')) { return false; } drawDrillBody(); return true; },
  apiFetch: () => { sent++; return new Promise(() => {}); },
  runSeg: () => 'run-1',
  followThrough: () => {},
  VmfHelp: { explainAction: (e) => String(e && e.message) },
  UX_ACT: liftConst('migrations.html', 'UX_ACT'),
});
globalThis.DISK_DELETE = liftConst('migrations.html', 'DISK_DELETE');
const P = liftAll('migrations.html', ['dismissOnOutsideClick', 'closeDrill', 'toggleDiskDelete', 'closeDiskDelete',
  'confirmDiskDelete', 'toggleMadeHelp']);
const open = () => find('drill').classList.contains('open');

/* ---- the measured press, for each delete on the panel ------------------- */

for (const kind of ['earlier', 'made', 'original']) {
  test(`${kind}: "Delete these disks" opens its slide-out, and the panel stays open`, () => {
    setup();
    const e = click(`${kind}delete-btn`, () => P.toggleDiskDelete('vm-1', kind));
    ok(!connected(e.target), 'the measured order: the press drew the panel body again, so its target left the page');
    ok(open(), 'the machine panel is still open');
    eq(globalThis.diskDelete && globalThis.diskDelete.kind, kind, 'the slide-out is open');
    ok(find(`${kind}delete-go`), 'its Delete button is on the panel');
  });

  test(`${kind}: the slide-out's Cancel closes only the slide-out`, () => {
    setup();
    click(`${kind}delete-btn`, () => P.toggleDiskDelete('vm-1', kind));
    click(`${kind}delete-cancel`, () => P.closeDiskDelete());
    ok(open(), 'the machine panel is still open');
    eq(globalThis.diskDelete, null, 'the slide-out is closed');
  });
}

for (const kind of ['earlier', 'made']) {
  test(`${kind}: the red Delete sends once, and the panel stays open with the slide-out sending`, () => {
    setup();
    sent = 0;
    click(`${kind}delete-btn`, () => P.toggleDiskDelete('vm-1', kind));
    click(`${kind}delete-go`, () => { P.confirmDiskDelete('vm-1', kind); });
    ok(open(), 'the machine panel is still open');
    eq(sent, 1, 'the engine operation was sent once');
    eq(globalThis.diskDelete && globalThis.diskDelete.sending, true, 'the slide-out says it is sending');
  });
}

test('the (?) of the made disks opens its help, and the panel stays open', () => {
  setup();
  click('madehelp-btn', () => P.toggleMadeHelp('vm-1'));
  ok(open(), 'the machine panel is still open');
  ok(globalThis.madeHelpOpen.has('vm-1'), 'the help is open');
});

/* ---- what the rule must still do ----------------------------------------- */

test('a click outside the panel still closes it, and forgets its slide-out', () => {
  setup();
  click('earlierdelete-btn', () => P.toggleDiskDelete('vm-1', 'earlier'));
  click('elsewhere');
  ok(!open(), 'the panel closed');
  eq(globalThis.diskDelete, null, 'the slide-out is forgotten');
});

test('a click outside whose own listener draws its part again still closes the panel', () => {
  // A wave toggle draws the wave table again: its target leaves the page too.
  // That click WAS outside the panel, so the panel closes - a rule that let
  // every detached target through would keep it open.
  setup();
  click('wavetoggle', () => drawWaveTable());
  ok(!open(), 'the panel closed');
});

test('a click on a machine row, in the open dialog, or on the panel itself keeps the panel open', () => {
  setup();
  click('row-cell');
  ok(open(), 'a machine row');
  click('m-ok');
  ok(open(), 'the dialog');
  click('drill-body');
  ok(open(), 'the panel body');
});

test('the menus: a click inside that draws the menu again keeps it open; a click outside closes it', () => {
  setup();
  find('run-panel').classList.add('open');
  find('act-panel').classList.add('open');
  click('run-more', () => drawRunPanel());
  ok(find('run-panel').classList.contains('open'), 'the run list stays open after its own redraw');
  ok(!find('act-panel').classList.contains('open'), 'the other menu closed');
  click('elsewhere');
  ok(!find('run-panel').classList.contains('open'), 'a click outside closes the run list');
  eq(find('run-current').attrs['aria-expanded'], 'false', 'and says so');
});

test('the menu of actions: a click inside that draws it again keeps it open', () => {
  setup();
  find('act-panel').classList.add('open');
  const draw = () => { const ap = find('act-panel'); ap.clear(); ap.append(node('button', { id: 'act-item' })); };
  draw();
  click('act-item', draw);
  ok(find('act-panel').classList.contains('open'), 'the menu of actions stays open after its own redraw');
  click('elsewhere');
  ok(!find('act-panel').classList.contains('open'), 'a click outside closes it');
  eq(find('act-menu-btn').attrs['aria-expanded'], 'false', 'and says so');
});

test('the page wires the rule as its one document click listener', () => {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
  ok(/document\.addEventListener\('click', dismissOnOutsideClick\)/.test(src), 'document click listener');
});

run('disk-delete-click');
