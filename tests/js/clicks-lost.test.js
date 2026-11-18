/* CLICKS-LOST-1: a click gets no sign that it worked, the page moves under
 * the pointer, and old messages stay.
 *
 * Lab install, 2026-11-04 and 2026-11-05. Each instance the item lists, RUN
 * through the page's own function:
 *
 *   - Save the plan took about a minute with only its own text changed, and
 *     was pressed twice. Save the targets gave no sign at all.
 *   - A page that drew again on its timer replaced the button under the
 *     pointer (the wave editor, the Migrations page - Show what the scan found
 *     did nothing while the page loaded).
 *   - Projects said "Project created", and the project was not in the list
 *     until a reload; the list drew in pieces under the person.
 *   - "Choose a target for these machines first" stayed after the machine was
 *     chosen; "No quota has been checked" stayed after the check said the
 *     quota is enough; the old error stayed above "The wave is starting".
 *
 * And the two shared rules the pages use: help.js markBusy (a sign at once)
 * and drawWhenFree (a redraw waits while the person holds a control in it).
 */
'use strict';
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// PAGE-LOAD-2: the Migrations page's one calls fail here, so its reads go to the fakes.
const { perFileHelp } = require('./_held');
const { pageSource } = require('./_page-source');

/* Lifted once. A file without them still runs, so each rule fails on its own
 * test rather than the whole file failing at the first line. */
const missing = (name) => () => { throw new Error(`help.js has no ${name}`); };
let help;
try { help = liftAll('help.js', ['markBusy', 'drawWhenFree', 'controlHeld', 'isTypingControl', 'isPointerControl', 'recentlyActive']); }
catch { help = { markBusy: missing('markBusy'), drawWhenFree: missing('drawWhenFree') }; }
// help.js keeps the draws that wait in one map beside the rule, which a lift leaves out.
globalThis.heldDraws = new WeakMap();
/* And the bound of a hold: the person counts as holding a control only while
 * active (the pointer moved or pressed, or a key went into a field) in the
 * last HOLD_MS. A lift leaves the page's listeners out, so a test says when
 * the person was active. The page's own value is held below. */
globalThis.HOLD_MS = 5000;
globalThis.lastSeen = { pointer: 0, typing: 0 };
const active = () => { globalThis.lastSeen.pointer = Date.now(); globalThis.lastSeen.typing = Date.now(); };

/* ---- a small DOM, enough for these rules ------------------------------- */

/** An element. `tag` and `type` are what the rules read; parent links walk up. */
function el(tag, opts = {}) {
  const e = {
    tagName: String(tag).toUpperCase(), type: opts.type ?? '', parentElement: opts.parent ?? null,
    textContent: opts.text ?? '', innerHTML: '', disabled: false, style: { display: opts.display ?? '' },
    attrs: {}, listeners: {}, hovered: [], ownerDocument: null, role: opts.role ?? null,
    setAttribute(k, v) { this.attrs[k] = String(v); },
    removeAttribute(k) { delete this.attrs[k]; },
    getAttribute(k) { return k === 'role' ? this.role : (k in this.attrs ? this.attrs[k] : null); },
    hasAttribute(k) { return k === 'href' ? Boolean(opts.href) : k in this.attrs; },
    addEventListener(t, f) { (this.listeners[t] = this.listeners[t] || []).push(f); },
    removeEventListener(t, f) { this.listeners[t] = (this.listeners[t] || []).filter(x => x !== f); },
    fire(t) { for (const f of [...(this.listeners[t] || [])]) { f({ type: t }); } },
    contains(x) { for (let n = x; n; n = n.parentElement) { if (n === this) { return true; } } return false; },
    querySelectorAll(sel) { return sel === ':hover' ? this.hovered : []; },
  };
  return e;
}
/** A document whose focus a test sets. */
function doc() { return { activeElement: null, body: el('body') }; }
function region(d) { const r = el('div'); r.ownerDocument = d; active(); return r; }
const tick = () => new Promise(r => setTimeout(r, 5));

/* ---- help.js: markBusy -------------------------------------------------- */

test('markBusy: the button is disabled, says what it does and is marked busy at once; the way back restores it', () => {
  const b = el('button', { text: 'Save the plan' });
  const undo = help.markBusy(b, 'Saving the plan...');
  eq([b.disabled, b.textContent, b.attrs['aria-busy']], [true, 'Saving the plan...', 'true'], 'busy');
  undo();
  eq([b.disabled, b.textContent, b.attrs['aria-busy']], [false, 'Save the plan', undefined], 'restored');
});

test('markBusy: app.css draws a busy button with a turning circle', () => {
  const css = require('fs').readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'), 'utf8');
  ok(/\.btn\[aria-busy="true"\]::before\s*\{[^}]*content:[^}]*animation:\s*vmf-busy\b/.test(css), 'a busy button has a circle that turns');
  ok(/@keyframes vmf-busy\s*\{\s*to\s*\{\s*transform:\s*rotate\(360deg\)/.test(css), 'and the turn is defined');
  ok(/prefers-reduced-motion:\s*reduce\)\s*\{[^}]*\.btn\[aria-busy="true"\]::before\s*\{\s*animation:\s*none/.test(css), 'and it stops for a person who asks for less motion');
});

/* ---- help.js: drawWhenFree ---------------------------------------------- */

test('drawWhenFree: nothing held - it draws at once', () => {
  const d = doc(); const r = region(d); let n = 0;
  eq(help.drawWhenFree([r], () => { n++; }), true, 'drawn');
  eq(n, 1);
});

test('drawWhenFree: the pointer on a button in the region - it waits, and draws the latest once the pointer goes', async () => {
  const d = doc(); const r = region(d);
  const btn = el('button', { parent: r }); const label = el('span', { parent: btn });
  r.hovered = [btn, label];
  const drawn = [];
  eq(help.drawWhenFree([r], () => drawn.push('first')), false, 'held');
  help.drawWhenFree([r], () => drawn.push('second'));
  eq(drawn, [], 'nothing replaced under the pointer');
  r.fire('pointerout'); await tick();
  eq(drawn, [], 'the pointer is still on it: still waits');
  r.hovered = [];
  r.fire('pointerout'); await tick();
  eq(drawn, ['second'], 'the latest draw, once');
  r.fire('pointerout'); await tick();
  eq(drawn, ['second'], 'and never again');
  // Held again later: it waits again, and draws again once the pointer goes.
  r.hovered = [btn];
  help.drawWhenFree([r], () => drawn.push('third'));
  eq(drawn, ['second'], 'held a second time');
  r.hovered = []; r.fire('pointerout'); await tick();
  eq(drawn, ['second', 'third'], 'and drawn a second time');
});

test('drawWhenFree: the pointer on text in the region, not a control - it draws at once', () => {
  const d = doc(); const r = region(d); r.hovered = [el('p', { parent: r })];
  let n = 0; help.drawWhenFree([r], () => { n++; });
  eq(n, 1);
});

test('drawWhenFree: a link, a select, a label and a role="button" each hold it', () => {
  for (const [tag, opts] of [['a', { href: 'x' }], ['select', {}], ['label', {}], ['div', { role: 'button' }], ['summary', {}]]) {
    // The browser lists every element under the pointer, outermost first.
    const d = doc(); const r = region(d); const card = el('div', { parent: r });
    r.hovered = [card, el(tag, { ...opts, parent: card })];
    let n = 0; help.drawWhenFree([r], () => { n++; });
    eq(n, 0, `${tag} holds it`);
  }
});

test('drawWhenFree: focus in a text field in the region - it waits until focus goes', async () => {
  const d = doc(); const r = region(d);
  const field = el('input', { type: 'text', parent: r }); d.activeElement = field;
  let n = 0; help.drawWhenFree([r], () => { n++; });
  eq(n, 0, 'held while the person types');
  d.activeElement = d.body; r.fire('focusout'); await tick();
  eq(n, 1, 'drawn once focus went');
});

test('drawWhenFree: focus on a check box or a button does not hold it (only typing does)', () => {
  for (const f of [el('input', { type: 'checkbox' }), el('input', { type: 'radio' }), el('button')]) {
    const d = doc(); const r = region(d); f.parentElement = r; d.activeElement = f;
    let n = 0; help.drawWhenFree([r], () => { n++; });
    eq(n, 1, `${f.tagName} ${f.type}`);
  }
  const d = doc(); const r = region(d); const t = el('textarea', { parent: r }); d.activeElement = t;
  let n = 0; help.drawWhenFree([r], () => { n++; });
  eq(n, 0, 'a text area holds it');
});

test('drawWhenFree: focus outside the regions does not hold it; any one region held holds it', () => {
  const d = doc(); const a = region(d); const b = region(d);
  d.activeElement = el('input', { type: 'search' });
  let n = 0; help.drawWhenFree([a, b], () => { n++; });
  eq(n, 1, 'a field elsewhere on the page');
  b.hovered = [el('button', { parent: b })];
  help.drawWhenFree([a, b], () => { n++; });
  eq(n, 1, 'the second region holds it');
});

test('drawWhenFree: a still pointer holds only for the bound - then the waiting draw runs with no movement at all', async () => {
  const was = globalThis.HOLD_MS; globalThis.HOLD_MS = 120;
  try {
    const d = doc(); const r = region(d);
    r.hovered = [el('button', { parent: r })];     // :hover stays, as on a touch screen
    let n = 0;
    eq(help.drawWhenFree([r], () => { n++; }), false, 'held while the person is active');
    await new Promise(res => setTimeout(res, 40));
    eq(n, 0, 'still held inside the bound');
    await new Promise(res => setTimeout(res, 260));
    eq(n, 1, 'drawn after the bound, with no pointer event and the pointer still on the button');
  } finally { globalThis.HOLD_MS = was; }
});

test('drawWhenFree: a person who keeps typing keeps the hold past the bound', async () => {
  const was = globalThis.HOLD_MS; globalThis.HOLD_MS = 120;
  try {
    const d = doc(); const r = region(d);
    d.activeElement = el('input', { type: 'text', parent: r });
    let n = 0; help.drawWhenFree([r], () => { n++; });
    for (let i = 0; i < 6; i++) { await new Promise(res => setTimeout(res, 50)); globalThis.lastSeen.typing = Date.now(); }
    eq(n, 0, 'held for 300 ms of typing, more than twice the bound');
    await new Promise(res => setTimeout(res, 300));
    eq(n, 1, 'drawn once the typing stopped for the bound');
  } finally { globalThis.HOLD_MS = was; }
});

test('drawWhenFree: a person not active at all holds nothing, even with the pointer resting on a button', () => {
  const d = doc(); const r = region(d);
  globalThis.lastSeen = { pointer: Date.now() - 60000, typing: Date.now() - 60000 };
  r.hovered = [el('button', { parent: r })];
  d.activeElement = el('textarea', { parent: r });
  let n = 0; help.drawWhenFree([r], () => { n++; });
  eq(n, 1, 'drawn at once');
});

test('drawWhenFree: the page holds for 10 seconds, and counts the pointer, a press, a key and a change as activity', () => {
  const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
  ok(/\n\s*const HOLD_MS = 10000;/.test(HELP), 'the bound is 10 seconds');
  for (const [ev, kind] of [['pointermove', 'pointer'], ['pointerdown', 'pointer'], ['keydown', 'typing'], ['input', 'typing']]) {
    ok(new RegExp(`'${ev}'[^\\n]*seen\\('${kind}'\\)`).test(HELP), `${ev} counts as ${kind}`);
  }
});

test('drawWhenFree: no region to look at - it draws', () => {
  let n = 0; help.drawWhenFree([], () => { n++; }); help.drawWhenFree([null], () => { n++; });
  eq(n, 2);
});

/* ---- Save the plan (wave editor) ---------------------------------------- */

const WUX = liftConst('waves.html', 'UX');

function wavesDom() {
  const els = new Map();
  return (sel) => {
    if (!els.has(sel)) { const e = el(sel === '#save' ? 'button' : 'div'); els.set(sel, e); }
    return els.get(sel);
  };
}

test('Save the plan: at once - disabled, busy, its words - and the line says what it waits for; all goes after', async () => {
  const save = liftAll('waves.html', ['save'])['save'];
  const $ = wavesDom(); globalThis.$ = $;
  globalThis.UX = WUX;
  globalThis.dirty = () => true; globalThis.inFlow = () => false;
  globalThis.runHref = () => 'about:blank';
  globalThis.render = () => {};
  globalThis.VmfHelp = { markBusy: help.markBusy, explainAction: (e) => String(e.message) };
  let release;
  globalThis.writeLayout = () => new Promise(r => { release = () => r({}); });
  $('#save').textContent = WUX.save;
  const done = save();
  eq([$('#save').disabled, $('#save').attrs['aria-busy'], $('#save').textContent], [true, 'true', WUX.saving], 'a sign before the service answers');
  eq([$('#save-wait').style.display, $('#save-wait').textContent], ['', WUX.savingWait], 'it says what it waits for');
  ok(/minute/.test(WUX.savingWait), 'and how long that can be');
  release(); await done;
  eq([$('#save').attrs['aria-busy'], $('#save').textContent], [undefined, WUX.save], 'the button is back');
  eq($('#save-wait').style.display, 'none', 'and the line goes');
});

test('Save the plan: a refused save also takes the busy state and the line away', async () => {
  const save = liftAll('waves.html', ['save'])['save'];
  const $ = wavesDom(); globalThis.$ = $;
  globalThis.writeLayout = async () => { throw new Error('409: the plan changed'); };
  await save();
  eq([$('#save').attrs['aria-busy'], $('#save-wait').style.display], [undefined, 'none']);
  eq($('#err').textContent, '409: the plan changed', 'the refusal is said');
});

/* ---- Check the quota (wave editor): the top panel follows the check ---- */

test('Check the quota: once the quota is enough, the top panel no longer says no quota has been checked', async () => {
  // QUOTA-CHECK-SPINNER-1: the card shows the plan-wide table from the records.
  const page = liftAll('waves.html', ['checkCapacity', 'drawQuotaCard', 'quotaCardHtml', 'quotaShortFamily', 'quotaShortRegion', 'quotaGroups', 'planQuotaRows', 'agoHtml', 'quotaPlanState']);
  const $ = wavesDom(); globalThis.$ = $;
  const answer = el('span');
  Object.assign(globalThis, {
    UX: WUX, esc: (s) => String(s ?? ''), cssEscape: (s) => s,
    // QUOTA-CHECK-SPINNER-1: the answer is kept per wave and the row drawn from it.
    document: { querySelector: () => null }, checkingWaves: new Set(), capAnswers: new Map(), drawQuotaRow: () => {},
    layout: new Map([['wave-1', { capacityGate: 'BestEffort' }]]),
    canEdit: false, DEMO_MODE: false, runSeg: () => 'run-1', runQuery: () => '',
    quotaShort: false, quotaChecked: false, unlistedWaves: new Set(), regionalShortRegions: new Set(),
    regionalShortWaves: new Set(), quotaAccess: new Map(), lastChecked: new Map(),
    uncoveredText: () => '', ago: () => 'now', dirty: () => false, waveDocs: new Map(), checkPlan: () => {}, waveNames: () => ['wave-1'], membersOf: () => [{}],
    VmfHelp: { claimBlocked: (s) => s === 'BLOCKED', claimRegionalShort: () => false, claimRegionalRequested: () => false, explain: (e) => e.message, explainAction: (e) => e.message },
    openQuotaConfirm: () => {},
    apiGet: async () => ({ Pass: true, Detail: 'all claims pass' }),
    loadClaims: async () => { globalThis.quotaChecked = true; globalThis.lastChecked = new Map([['wave-1', '2026-11-16T10:00:00Z']]);
      globalThis.waveDocs = new Map([['wave-1', [{ wave: 'wave-1', subscriptionId: 's', region: 'centralus', vmFamily: 'f', state: 'QUOTA_VERIFIED',
        demand: { vcpus: 2, familyVcpus: 2, regionalVcpus: 2, regionalAdds: 2 }, quota: { limit: 10, used: 0, regionalLimit: 10, regionalUsed: 0, name: 'F vCPUs', checkedUtc: '2026-11-16T10:00:00Z' } }]]]); return true; },
  });
  page.drawQuotaCard();
  ok($('#quota').innerHTML.includes(WUX.quotaNotChecked), 'before: nothing checked');
  const btn = el('button', { text: WUX.capCheck });
  await page.checkCapacity('wave-1', btn);
  ok(!$('#quota').innerHTML.includes(WUX.quotaNotChecked), 'the top panel no longer says nothing was checked');
  ok($('#quota').innerHTML.includes(WUX.capPlanEnough), 'it says what the check found');
});

/* ---- the wave editor's reservation watch waits for the pointer ---------- */

test('the wave editor: a reservation tick does not draw the editor while the pointer is on a control in it', async () => {
  const watchReservation = lift('waves.html', 'watchReservation');
  const page = liftAll('waves.html', ['editorRegions', 'drawEditorWhenFree']);
  const d = doc();
  const regions = { '#pool': region(d), '#waves': region(d), '#quota': region(d) };
  regions['#waves'].hovered = [el('button', { parent: regions['#waves'] })];
  let draws = 0;
  Object.assign(globalThis, page, {
    $: (s) => regions[s] ?? el('div'), render: () => { draws++; }, DEMO_MODE: false,
    runPrefix: () => 'run-1', blobLines: async () => [], reserveScan: () => null,
    loadClaims: async () => true, claims: new Map([['wave-1', 'working']]),
    reserveDoneText: () => '', UX: WUX,
    VmfHelp: { drawWhenFree: help.drawWhenFree, watchRun: async (o) => { await o.onTick(); return { claim: 'held' }; } },
  });
  await watchReservation('wave-1');
  eq(draws, 0, 'nothing replaced under the pointer');
  regions['#waves'].hovered = [];
  regions['#waves'].fire('pointerout'); await tick();
  eq(draws, 1, 'drawn once the pointer left');
});

/* ---- Save the targets, and "Choose a target ... first" (wizard) --------- */

const ZUX = liftConst('wizard.html', 'UX');

function wizardPage({ missing }) {
  const $ = wavesDom();
  const state = { missing };
  Object.assign(globalThis, {
    $, UX: ZUX, VmfHelp: { markBusy: help.markBusy, explainAction: (e) => String(e.message) },
    fill: (s, o) => String(s).replace(/\{(\w+)\}/g, (_, k) => o[k]),
    decideMissing: () => state.missing, tMachines: () => [], tDefault: 'v6', tOverrides: new Map(),
    failAction: (e) => { $('#err').textContent = String(e.message); $('#err').style.display = 'block'; },
    clearErr: () => { $('#err').style.display = 'none'; },
    tMissingText: '',
  });
  $('#t-save').textContent = ZUX.tSave;
  $('#err').style.display = 'none';
  return { $, state };
}

test('Save the targets: at once - disabled, busy and its words - before the service is asked', async () => {
  const page = liftAll('wizard.html', ['saveTargets', 'markBusy']);
  const { $ } = wizardPage({ missing: null });
  let release;
  Object.assign(globalThis, {
    markBusy: page.markBusy,
    targetChoicesBody: () => [], api: () => new Promise(r => { release = r; }), runBody: (b) => b, runSeg: () => 'a-1',
    said: () => {}, location: { href: 'https://example.com/wizard.html' }, history: { replaceState() {} },
    readRun: async () => {}, goStep: () => {}, STEP: { migrate: { group: 'group' } }, tOpen: new Set(),
    tKernelDef: 'stop', tSizes: new Map(), tDiskSel: new Map(), tKernelSel: new Map(), tMethodSel: new Map(),
    adviceVersion: 'a', choicesVersion: 'c', machinesVersion: 'm',
  });
  const done = page.saveTargets();
  eq([$('#t-save').disabled, $('#t-save').attrs['aria-busy'], $('#t-save').textContent], [true, 'true', ZUX.tSaving], 'a sign at once');
  ok($('#t-export').disabled, 'Export waits for the same save');
  release({}); await done;
});

// REBUILD-REMOVE-PLAN-1: "Choose a target for these machines first" is gone with the
// machines that waited for a choice (the engine's decide), and its three tests with it.

/* ---- a new start clears the old error (Migrations page, wizard) --------- */

const lastEngineFailure = lift('migrations.html', 'lastEngineFailure');
const waveStartFailure = lift('wizard.html', 'waveStartFailure');
const at = (s) => `2026-11-05T10:00:${String(s).padStart(2, '0')}Z`;
const REFUSED = [
  { tsUtc: at(1), step: 'engine', outcome: 'start', operation: 'wave', wave: 'wave-1', detail: 'hosted wave started' },
  { tsUtc: at(2), step: 'engine:wave', outcome: 'fail', detail: 'This run has not been acknowledged.' },
];

test('a new start: the service start line after a refused start clears the refusal, on both pages', () => {
  ok(lastEngineFailure(REFUSED), 'refused: the Migrations page says it');
  ok(waveStartFailure(REFUSED), 'and the wizard');
  const again = [...REFUSED, { tsUtc: at(30), step: 'engine', outcome: 'start', operation: 'wave', wave: 'wave-1', detail: 'hosted wave started' }];
  eq(lastEngineFailure(again), null, 'the start that follows clears it on the Migrations page');
  eq(waveStartFailure(again), null, 'and on the wizard');
  const part = [...REFUSED, { tsUtc: at(30), step: 'engine', outcome: 'warn', operation: 'wave', wave: 'wave-1', detail: 'part start' }];
  eq(lastEngineFailure(part), null, 'a part start is a start');
});

test('a new start: only a start of THAT operation, and a refusal after the new start is still said', () => {
  const other = [...REFUSED, { tsUtc: at(30), step: 'engine', outcome: 'start', operation: 'restore', detail: 'hosted restore started' }];
  ok(lastEngineFailure(other), 'a restore start does not clear a wave refusal');
  ok(waveStartFailure(other), 'nor on the wizard');
  const failedStart = [...REFUSED, { tsUtc: at(30), step: 'engine', outcome: 'fail', operation: 'wave', detail: 'Azure refused' }];
  ok(lastEngineFailure(failedStart), 'a start line that failed is not a start');
  const twice = [...REFUSED,
    { tsUtc: at(30), step: 'engine', outcome: 'start', operation: 'wave', wave: 'wave-1', detail: 'hosted wave started' },
    { tsUtc: at(50), step: 'engine:wave', outcome: 'refused', detail: 'No capacity.' }];
  eq(lastEngineFailure(twice).detail, 'No capacity.', 'the new refusal is said');
  eq(waveStartFailure(twice).detail, 'No capacity.', 'on both pages');
});

test('a new start: a confirmed action on the Migrations page takes the old page error away', async () => {
  const els = new Map();
  const $ = (sel) => { if (!els.has(sel)) { els.set(sel, Object.assign(el('div'), { value: '', classList: { add() {}, remove() {} }, querySelectorAll: () => [], querySelector: () => null, focus() {} })); } return els.get(sel); };
  Object.assign(globalThis, {
    $, UX_ACT: liftConst('migrations.html', 'UX_ACT'), esc: (s) => String(s ?? ''),
    document: { querySelector: () => null, querySelectorAll: () => [] },
    VmfHelp: { explainAction: (e) => String(e && e.message) }, followThrough: () => {}, modalMachine: null,
  });
  const modal = liftAll('migrations.html', ['closeModal', 'openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText']);
  $('#err').textContent = 'The wave did not start: This run has not been acknowledged.';
  $('#err').style.display = 'block';
  modal.openModal({ title: 'Start wave', desc: 'd', fields: [], doneMessage: 'The wave is starting.', onConfirm: async () => undefined });
  await $('#m-confirm').onclick();
  eq($('#ok').textContent, 'The wave is starting.', 'the new start is said');
  eq($('#err').style.display, 'none', 'and the old error above it is gone');
});

test('a new start: a refused confirm leaves the page error alone (the dialog says the refusal)', async () => {
  const $ = globalThis.$;
  const modal = liftAll('migrations.html', ['closeModal', 'openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText']);
  $('#err').style.display = 'block';
  modal.openModal({ title: 't', desc: 'd', fields: [], onConfirm: async () => { throw new Error('refused'); } });
  await $('#m-confirm').onclick();
  eq($('#err').style.display, 'block');
  eq($('#m-err').textContent, 'refused');
});

/* ---- the Migrations page: a refresh waits for the pointer --------------- */

test('the Migrations page: a refresh does not draw the run while the pointer is on a control in it', async () => {
  const refreshRun = lift('migrations.html', 'refreshRun');
  const runRegions = lift('migrations.html', 'runRegions');
  const d = doc();
  const regionSels = ['#kpis', '#run-actions', '#nextstep', '#found', '#waves', '#cap-table tbody', '#copies-table tbody', '#event-table tbody', '#drill-body'];
  const regions = Object.fromEntries(regionSels.map(s => [s, region(d)]));
  const toggle = el('button', { parent: regions['#found'] });
  regions['#found'].hovered = [toggle];
  const drawn = [];
  const fakeSrc = {
    listRun: async () => null, readLines: async () => [], listFolder: async () => [],
    readJson: async () => null, readRoot: async () => null,
  };
  const els = { ...regions, '#err': el('div'), '#live-ind': el('span') };
  Object.assign(globalThis, {
    $: (s) => els[s] ?? null, runRegions, currentRun: 'p/mig-1', showingRun: 'p/mig-1', source: fakeSrc, DEMO_MODE: false,
    planDoc: null, runAck: null, runStop: null, planSignoff: null, planSignoffCurrent: false, planRunStatus: null, lastAssessment: null,
    schedules: new Map(), acceptances: new Map(), approvals: new Map(), allVms: [], latestClaims: [], latestLeases: new Map(), latestHalted: false,
    discardInFlight: new Map(), latestEvents: [], restoresInFlight: new Map(), rebuildsInFlight: new Map(), lastUpdated: 0,
    runListed: () => null, showReadingRun() {}, clearReadingRun() {},
    nameMachines() {}, discardIndex: () => new Map(), restoreIndex: () => new Map(), rebuildIndex: () => new Map(),
    renderKpis: () => drawn.push('kpis'), renderNextStep: () => drawn.push('next'), renderFound: () => drawn.push('found'),
    renderWaves: () => drawn.push('waves'), refreshDrill: () => drawn.push('drill'), renderCapacity: () => drawn.push('cap'),
    renderSafetyCopies: () => drawn.push('copies'), renderEvents: () => drawn.push('events'), ago: () => 'now',
    VmfHelp: { ...perFileHelp(), storeHolds: () => true, drawWhenFree: help.drawWhenFree, mapLimited: async (xs, f) => Promise.all(xs.map(f)), explain: (e) => String(e.message) },
  });
  await refreshRun({ status: async () => null, plan: async () => ({ pv: null, doc: null }), run: async () => null });
  eq(drawn, [], 'nothing drawn while the pointer is on Show what the scan found');
  eq(els['#err'].style.display, 'none', `and that is not an error: ${els['#err'].textContent}`);
  eq(globalThis.showingRun, 'p/mig-1', 'the run is the one on screen');
  eq(globalThis.lastUpdated, 0, '"Updated ... ago" does not claim a drawing that has not happened');
  regions['#found'].hovered = [];
  regions['#found'].fire('pointerout'); await tick();
  ok(drawn.includes('found') && drawn.includes('waves') && drawn.includes('events'), `drawn once the pointer left: ${drawn}`);
  eq(drawn.filter(x => x === 'found').length, 1, 'once');
});

test('the Migrations page: a drawing that waited is dropped when another run is chosen meanwhile', async () => {
  const refreshRun = lift('migrations.html', 'refreshRun');
  const found = globalThis.$('#found');
  found.hovered = [el('button', { parent: found })];
  const drawn = [];
  globalThis.renderFound = () => drawn.push('found');
  globalThis.renderKpis = () => drawn.push('kpis');
  globalThis.currentRun = 'p/mig-1';
  await refreshRun({ status: async () => null, plan: async () => ({ pv: null, doc: null }), run: async () => null });
  eq(drawn, [], 'held');
  globalThis.currentRun = 'p/mig-2';
  found.hovered = []; found.fire('pointerout'); await tick();
  eq(drawn, [], 'the first run is not drawn over the run now chosen');
});

test('the Migrations page: the regions a refresh draws are every region it replaces', () => {
  const runRegions = lift('migrations.html', 'runRegions');
  const seen = [];
  globalThis.$ = (s) => { seen.push(s); return { s }; };
  const got = runRegions().map(x => x.s);
  for (const s of ['#kpis', '#run-actions', '#nextstep', '#found', '#waves', '#cap-table tbody', '#copies-table tbody', '#event-table tbody', '#drill-body']) {
    ok(got.includes(s), `${s} is held`);
  }
});

/* ---- Projects: what was just made is in the list at once ---------------- */

// The page's own slug rule, read from its one line.
function projectSlug() {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'projects.html'));
  const m = src.match(/\nconst slug = (\(s\) => [^\n]*);\n/);
  ok(m, 'the slug rule is found');
  // eslint-disable-next-line no-eval
  return eval(m[1]);
}
/* PAGE-SCALE-PROJECTS-1: the page draws through the shared list
 * (VmfHelp.listMount); here a list that writes the names of the All projects
 * tile into its host, which is what these tests read. load reads each
 * migration's status (migrationWaiting) and the last change (latestTime). */
const PROJ_DRAW = ['latestTime', 'migrationWaiting', 'projectTiles', 'projectRow', 'projectColumns', 'projectSorts', 'waitingTag',
  'deleteAction', 'holdsParts', 'holdsNote'];
const listByName = (host) => ({ update: (d) => { host.innerHTML = d.tiles[0].rows.map(r => r.name).join('|'); } });
function projectsPage() {
  const nodes = {};
  const node = (id) => (nodes[id] = nodes[id] || Object.assign(el(id === '#create-btn' ? 'button' : 'div'), { value: '', focus() {} }));
  const PUX = liftConst('projects.html', 'UX');
  Object.assign(globalThis, {
    $: node, esc: (s) => String(s ?? ''), ago: () => '', byName: (a, b) => String(a.name).localeCompare(String(b.name)),
    DEMO_MODE: false, UX: PUX, projects: [], loose: [], reading: true, madeHere: new Map(), loadTurn: 0,
    deleteProject: () => {}, projectsList: null, onListClick: () => {}, QUIET_DAYS: 30,
  });
  return { node, PUX };
}

test('Projects: a project just created is in the list at once, and a walk that started before it does not take it away', async () => {
  const page = liftAll('projects.html', ['render', 'load', 'createProject', 'withMade', 'drawListWhenFree', 'listRegions', ...PROJ_DRAW]);
  const hp = liftAll('help.js', ['waitingRow', 'mapLimited', 'runFolderIsRun', 'runKind', 'storeHolds']);
  const { node, PUX } = projectsPage();
  // A store whose first listing is held back until the test lets it go.
  let releaseFirst; const firstHeld = new Promise(r => { releaseFirst = r; });
  let listings = 0;
  Object.assign(globalThis, page, {
    slug: projectSlug(), STORE_READ_LIMIT: 8,
    VmfHelp: { ...hp, drawWhenFree: help.drawWhenFree, listMount: listByName, markBusy: help.markBusy, explainAction: (e) => String(e.message),
      // PAGE-LOAD-1: the one call fails, so the page reads through the blobList below.
      storeDocs: async () => { throw new Error('per-file reads measured here'); } },
    held: null, LIST_READS: [], storeRead: (fn) => fn(), cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token',
    blobList: async (prefix) => {
      if (prefix === '') { listings++; if (listings === 1) { await firstHeld; return { prefixes: ['old-one/'] }; } return { prefixes: ['old-one/', 'new-one/'] }; }
      return { prefixes: [], names: [`${prefix}project.json`] };
    },
    blobJson: async (p) => ({ projectId: p.split('/')[0], name: p.split('/')[0] === 'new-one' ? 'New one' : 'Old one', createdUtc: '2026-11-05T10:00:00Z' }),
    api: async () => ({}),
    failAction: (e) => { node('#err').textContent = e.message; },
    fail: (e) => { node('#err').textContent = e.message; },
  });
  const first = page.load();                 // the page's first walk, still reading
  node('#f-name').value = 'New one';
  await page.createProject();
  ok(node('#projects-list').innerHTML.includes('New one'), 'in the list at once');
  eq(node('#ok').textContent, PUX.created);
  releaseFirst(); await first; page.render();
  ok(node('#projects-list').innerHTML.includes('New one'), 'the older walk did not take it away');
  ok(globalThis.projects.some(p => p.id === 'new-one'), 'it is in the list the page holds');
  eq(globalThis.projects.filter(p => p.id === 'new-one').length, 1, 'once, when the store names it too');
});

test('Projects: a walk whose store listing does not name the new project yet keeps it in the list', async () => {
  const page = liftAll('projects.html', ['render', 'load', 'withMade', 'drawListWhenFree', 'listRegions', ...PROJ_DRAW]);
  const hp = liftAll('help.js', ['waitingRow', 'mapLimited', 'runFolderIsRun', 'runKind', 'storeHolds']);
  const { node } = projectsPage();
  Object.assign(globalThis, page, {
    STORE_READ_LIMIT: 8, VmfHelp: { ...hp, drawWhenFree: help.drawWhenFree, listMount: listByName,
      // PAGE-LOAD-1: the one call fails, so the page reads through the blobList below.
      storeDocs: async () => { throw new Error('per-file reads measured here'); } },
    held: null, LIST_READS: [], storeRead: (fn) => fn(), cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token',
    blobList: async (prefix) => (prefix === '' ? { prefixes: ['old-one/'] } : { prefixes: [], names: [`${prefix}project.json`] }),
    blobJson: async () => ({ projectId: 'old-one', name: 'Old one' }),
  });
  globalThis.madeHere.set('new-one', { id: 'new-one', name: 'New one', assessments: 0, migrations: 0 });
  await page.load();
  eq(globalThis.projects.map(p => p.id), ['new-one', 'old-one'], 'kept, in its place by name');
  ok(node('#projects-list').innerHTML.includes('New one'), 'and drawn');
});

test('Projects: the create button says it works at once, and a refused create gives it back', async () => {
  const page = liftAll('projects.html', ['createProject', 'withMade']);
  const { node, PUX } = projectsPage();
  let release;
  Object.assign(globalThis, {
    slug: projectSlug(), load: async () => {}, VmfHelp: { markBusy: help.markBusy, explainAction: (e) => String(e.message) },
    api: () => new Promise((res, rej) => { release = rej; }),
    failAction: (e) => { node('#err').textContent = e.message; node('#err').style.display = 'block'; },
    fail: (e) => { node('#err').textContent = e.message; },
  });
  node('#create-btn').textContent = PUX.createBtn;
  node('#f-name').value = 'Another';
  const done = page.createProject();
  eq([node('#create-btn').disabled, node('#create-btn').attrs['aria-busy'], node('#create-btn').textContent], [true, 'true', PUX.creating], 'a sign at once');
  release(new Error('That name is taken.')); await done;
  eq([node('#create-btn').disabled, node('#create-btn').textContent], [false, PUX.createBtn], 'given back');
  eq(node('#err').textContent, 'That name is taken.');
});

test('Projects: a walk that finishes after a newer one does not replace the newer list', async () => {
  const page = liftAll('projects.html', ['render', 'load', 'withMade', 'drawListWhenFree', 'listRegions', ...PROJ_DRAW]);
  const hp = liftAll('help.js', ['waitingRow', 'mapLimited', 'runFolderIsRun', 'runKind', 'storeHolds']);
  projectsPage();
  let releaseOld; const oldHeld = new Promise(r => { releaseOld = r; });
  let n = 0;
  Object.assign(globalThis, page, {
    STORE_READ_LIMIT: 8, VmfHelp: { ...hp, drawWhenFree: help.drawWhenFree, listMount: listByName,
      // PAGE-LOAD-1: the one call fails, so the page reads through the blobList below.
      storeDocs: async () => { throw new Error('per-file reads measured here'); } },
    held: null, LIST_READS: [], storeRead: (fn) => fn(), cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token',
    blobList: async (prefix) => {
      if (prefix === '') { n++; if (n === 1) { await oldHeld; return { prefixes: ['gone/', 'kept/'] }; } return { prefixes: ['kept/'] }; }
      return { prefixes: [], names: [`${prefix}project.json`] };
    },
    blobJson: async (p) => ({ projectId: p.split('/')[0], name: p.split('/')[0] }),
  });
  const older = page.load();
  await page.load();                        // newer: the project "gone" was deleted
  releaseOld(); await older;
  eq(globalThis.projects.map(p => p.id), ['kept'], 'the deleted project does not come back');
});

test('Projects: the list does not draw while the person types a new project, and draws when they stop', async () => {
  const page = liftAll('projects.html', ['render', 'drawListWhenFree', 'listRegions', ...PROJ_DRAW]);
  const { node } = projectsPage();
  const d = doc();
  const form = node('#new-form'); form.ownerDocument = d;
  node('#projects-list').ownerDocument = d;
  const field = el('input', { type: 'text', parent: form }); d.activeElement = field;
  Object.assign(globalThis, page, { VmfHelp: { drawWhenFree: help.drawWhenFree, waitingRow: () => 'reading', listMount: listByName } });
  globalThis.projects = [{ id: 'a', name: 'A', assessments: 0, migrations: 0 }];
  page.drawListWhenFree();
  eq(node('#projects-list').innerHTML, '', 'not drawn while typing');
  d.activeElement = d.body; form.fire('focusout'); await tick();
  ok(node('#projects-list').innerHTML.includes('A'), 'drawn once the person stopped');
});

test('Projects: the walk of the store does not draw the list while the person types a new project', async () => {
  const page = liftAll('projects.html', ['render', 'load', 'withMade', 'drawListWhenFree', 'listRegions', ...PROJ_DRAW]);
  const hp = liftAll('help.js', ['waitingRow', 'mapLimited', 'runFolderIsRun', 'runKind', 'storeHolds']);
  const { node } = projectsPage();
  const d = doc();
  const form = node('#new-form'); form.ownerDocument = d;
  d.activeElement = el('input', { type: 'text', parent: form });
  Object.assign(globalThis, page, {
    STORE_READ_LIMIT: 8, VmfHelp: { ...hp, drawWhenFree: help.drawWhenFree, listMount: listByName,
      // PAGE-LOAD-1: the one call fails, so the page reads through the blobList below.
      storeDocs: async () => { throw new Error('per-file reads measured here'); } },
    held: null, LIST_READS: [], storeRead: (fn) => fn(), cfg: { apiUrl: 'https://service.example.com/api' }, getToken: async () => 'token',
    blobList: async (prefix) => (prefix === '' ? { prefixes: ['alpha/'] } : { prefixes: [], names: [`${prefix}project.json`] }),
    blobJson: async (p) => ({ projectId: 'alpha', name: 'Alpha' }),
  });
  await page.load();
  eq(node('#projects-list').innerHTML, '', 'nothing drawn under the person typing');
  ok(globalThis.projects.some(p => p.id === 'alpha'), 'but the page holds the project');
  d.activeElement = d.body; form.fire('focusout'); await tick();
  ok(node('#projects-list').innerHTML.includes('Alpha'), 'drawn once they stopped');
});

test('Projects: a project deleted on the page is no longer kept as made here', () => {
  const PROJ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'projects.html'));
  const at = PROJ.indexOf('async function deleteProjectNow(');
  const body = PROJ.slice(at, PROJ.indexOf('\n  }\n', at));
  ok(/\n\s+madeHere\.delete\(id\);/.test(body), 'deleteProjectNow forgets it, so the next walk does not put it back');
  ok(body.indexOf('madeHere.delete(id)') < body.indexOf('await load()'), 'before the walk');
});

run('clicks-lost');
