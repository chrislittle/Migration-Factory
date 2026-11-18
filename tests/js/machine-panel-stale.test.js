/* MACHINE-PANEL-STALE-1, from the BGINFO-PERM-1 lab drill, 2026-10-24, on the
 * Migrations page of the installed app: a machine stopped at PRECHECK
 * (permissionsMissing). Its side panel was open when Try this machine again
 * moved it through Path B to MIGRATED. The row changed to Migrated on the
 * fifteen-second refresh. The panel kept "Needs a decision", the stop box and
 * the old buttons until it was closed and opened again: openDrill drew it ONE
 * time, and the refresh never drew it again.
 *
 * RUN, not read: the page's own openDrill, drawDrill, refreshDrill and
 * closeDrill, with the real pill, stop box, controls and timeline, against a
 * small DOM of our own (the _harness rule: the function is real, the DOM is
 * yours).
 */
'use strict';
// MADE-DISK-SHOWN-1: the machines whose (?) of the made disks is open.
globalThis.madeHelpOpen = new Set();
// MADE-DISK-DELETE-1: the open slide-out delete of disks, which a new open and closeDrill forget.
globalThis.diskDelete = null;
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { extract, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const table = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));

/* ---- the page's own tables ---------------------------------------------- */
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/const PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...globalThis.PROBLEM_STATES];
// eslint-disable-next-line no-eval
globalThis.UX_PATH = eval(`(${PAGE.match(/const UX_PATH = (\{[^}]+\});/)[1]})`);
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.CHECKPOINT_TEXT = liftConst('migrations.html', 'CHECKPOINT_TEXT');
globalThis.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
globalThis.retryLines = table.retryLines;
const permTitle = stopReasons.get('permissionsMissing').title;

/* ---- what the panel reads that is not under test ------------------------ */
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => id;
globalThis.techText = (s) => s;
globalThis.stepText = (e) => e.step;
globalThis.guestRunPill = () => '';
// The panel's "... ago" text. A test changes it to stand for time passing.
let agoText = 'a moment ago';
globalThis.ago = () => agoText;
globalThis.notMovedReasons = () => null;
globalThis.notMovedHtml = () => '';
globalThis.latestClaims = [];
globalThis.canOperate = () => true;
globalThis.canApprove = () => true;
globalThis.restoreInFlight = () => null;
globalThis.rebuildInFlight = () => null;
globalThis.restoreOffered = () => false;
globalThis.restoreWaitsForMove = () => false;
globalThis.VmfHelp = { machineOutcome: (d) => (d?.restore ? 'putBack' : d?.state === 'MIGRATED' ? 'migrated' : 'other'), idKey: (id) => String(id == null ? '' : id).toLowerCase() };
// IDENTITY-LOSS-1: the panel reads the run log for an identity a rebuild deleted.
globalThis.latestEvents = [];
// BRAKE-WAIT-WORDS-1: the wave safety brake, as the refresh keeps it.
globalThis.latestHalted = false;
globalThis.isPutBack = (d) => VmfHelp.machineOutcome(d) === 'putBack';
// STATUS-WORDS-1: the pill of the panel asks help.js's status rule.
globalThis.VmfHelp.machineStatus = require('./_status').statusRule();
// NOT-IN-WAVE-QUEUED-1: refreshDrill closes the panel of a machine that left the run.
globalThis.VmfHelp.outsideRun = require('./_harness').lift('help.js', 'outsideRun');
globalThis.UX_RAN = liftConst('migrations.html', 'UX_RAN');
// RETRY-SERIES-1: the page's own fillRetrySeries, against a counted service.
let fills = 0;
const SERIES = { PlanVersion: 'ver-1', Current: 'v6', Options: [
  { option: 'v6', current: true, supported: true, targetSize: 'Standard_D2ds_v6' },
  { option: 'v5', current: false, supported: true, targetSize: 'Standard_D2ds_v5' }] };
globalThis.apiFetch = async () => { fills++; return SERIES; };
globalThis.runSeg = () => 'run-1';
globalThis.retrySeriesCache = null;
globalThis.drillFocusId = null;
for (const n of ['askResolve', 'askDecide', 'askRestore', 'askRebuild', 'askFinish', 'askSkipVm']) {
  globalThis[n] = () => { };
}
// DIALOG-STALE-1: the dialog side is tests/js/dialog-stale.test.js.
globalThis.panelDialog = (id, open) => open();
globalThis.markDialogStale = () => false;
// The page's own `let`s, which openDrill and refreshDrill keep.
globalThis.drillVmId = null;
globalThis.drillRun = null;
globalThis.drillDrawn = null;

/* ---- a small DOM ---------------------------------------------------------
 * Static elements are real objects. An element the panel's markup names by
 * id is made on first lookup, ONCE per draw, so a lookup after a redraw is a
 * new element - as in a browser, where innerHTML replaces the nodes. */
function classes() {
  const s = new Set();
  return { add: (c) => s.add(c), remove: (c) => s.delete(c), contains: (c) => s.has(c) };
}
let children = new Map();
function element(id) {
  return {
    id, _html: '', value: '', textContent: '', dataset: {}, handlers: {}, classList: classes(), buttons: [],
    get innerHTML() { return this._html; },
    // The series slot: its buttons become elements, found by their id.
    set innerHTML(v) {
      this._html = String(v);
      if (this.id !== 'retryseries-slot') { return; }
      this.buttons = [...this._html.matchAll(/id="([^"]+)" data-retryseries="([^"]+)"/g)].map(m => {
        const b = element(m[1]); b.dataset.retryseries = m[2]; children.set(m[1], b); return b;
      });
    },
    querySelectorAll(sel) { return sel === '[data-retryseries]' ? this.buttons : []; },
    addEventListener(kind, fn) { this.handlers[kind] = fn; this.wired = (this.wired ?? 0) + 1; },
    focus() { globalThis.document.activeElement = this; },
    scrollIntoView() { },
  };
}
let agoSpans = [];
let evlinks = [];
let draws = 0;
const closeBtn = element('');
const drill = element('drill');
drill.scrollTop = 0;
drill.querySelector = (sel) => (sel === '.close' ? closeBtn : null);
const body = {
  _html: '',
  get innerHTML() { return this._html; },
  set innerHTML(v) {
    this._html = String(v);
    draws++;
    children = new Map();
    // A browser clamps the scroll position when the content is replaced.
    drill.scrollTop = 0;
    evlinks = [...this._html.matchAll(/class="evlink" data-ev="([^"]*)"/g)].map(m => {
      const a = element(''); a.dataset.ev = m[1]; return a;
    });
    agoSpans = [...this._html.matchAll(/<span data-ago="([^"]*)">([^<]*)<\/span>/g)].map(m => {
      const s = element(''); s.dataset.ago = m[1]; s.textContent = m[2]; return s;
    });
  },
  contains(el) { return [...children.values()].includes(el) || evlinks.includes(el) || agoSpans.includes(el); },
  querySelectorAll(sel) { return sel === '.evlink' ? evlinks : sel === '[data-ago]' ? agoSpans : []; },
};
drill.contains = (el) => el === closeBtn || body.contains(el);
const modalBack = element('modal-back');
const noteBox = element('mf-note');
const statics = { '#drill': drill, '#drill-body': body, '#modal-back': modalBack, '#mf-note': noteBox };
globalThis.$ = (sel) => {
  if (statics[sel]) { return statics[sel]; }
  const m = /^#([\w-]+)$/.exec(sel);
  if (m && children.has(m[1])) { return children.get(m[1]); }
  if (!m || !body._html.includes(`id="${m[1]}"`)) { return null; }
  if (!children.has(m[1])) { children.set(m[1], element(m[1])); }
  return children.get(m[1]);
};
globalThis.document = { activeElement: null, getElementById: (id) => globalThis.$('#' + id) };

const panel = liftAll('migrations.html', ['openDrill', 'capacityLine', 'drawDrill', 'refreshDrill', 'closeDrill', 'refocusDrill', 'revealDiskDelete', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords',
  'agoSpan', 'drillKey', 'fillRetrySeries', 'retrySeriesOptions', 'lastStopEntry', 'sizeRefusedStop', 'restoreOntoTarget',
  'machineTimeline', 'attemptStop', 'currentStop', 'whyStoppedCard', 'stopControls', 'powerOwed', 'volumesCheckOffer', 'volumesCheckStarted', 'volumesStartedLine', 'powerName', 'retryHeld', 'decisionWaiting',
  'putBackControls', 'finishOffered', 'machinePill', 'shownState', 'restoredPill', 'statePill', 'checkpointLine',
  'restoredNoteHtml', 'restoreEarlierDisks', 'recordedMachineDiskIds', 'madeDiskRows', 'madeDisksHtml', 'recordDiskIdsInUse', 'rollbackOriginalDisks', 'rollbackOriginalsHtml', 'machineStatusOf', 'statusWord', 'statusPill', 'timelineDuration', 'activityLines', 'timelineLine', 'restoreEndAfter', 'restoreEndCard', 'foldedCallLines', 'rollbackFollows', 'stepRetried', 'retriedText']);

/* ---- the drill's machine, before and after the retry -------------------- */
const VM = 'vm-app-01';
const entry = { vmId: VM, wave: 'w1', path: 'B' };
const parked = [
  { tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-24T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'permissionsMissing',
    machineState: 'untouched', detail: 'The identity has no Microsoft.Compute/virtualMachines/write.' },
];
const stoppedDoc = () => ({ vmId: VM, state: 'NEEDS_DECISION', history: parked.map(h => ({ ...h })) });
const migratedDoc = () => ({ vmId: VM, state: 'MIGRATED', history: [...parked.map(h => ({ ...h })),
  { tsUtc: '2026-10-24T11:00:00Z', state: 'PRECHECK', outcome: 'ok', detail: 'Re-armed at PRECHECK.' },
  { tsUtc: '2026-10-24T11:20:00Z', state: 'CONVERTING', outcome: 'ok' },
  { tsUtc: '2026-10-24T11:40:00Z', state: 'MIGRATED', outcome: 'ok' }] });

function reset() {
  globalThis.currentRun = 'run-1';
  globalThis.planDoc = { entries: [entry] };
  globalThis.allVms = [];
  globalThis.drillVmId = null; globalThis.drillRun = null; globalThis.drillDrawn = null;
  globalThis.drillFocusId = null; globalThis.retrySeriesCache = null;
  globalThis.latestEvents = [];
  agoText = 'a moment ago';
  fills = 0;
  globalThis.document.activeElement = null;
  modalBack.classList.remove('open');
  noteBox.value = '';
  drill.classList.remove('open');
  body.innerHTML = '';
  draws = 0;
}
/** Select the machine's row, as renderWaves does. */
function openFor(doc) {
  globalThis.allVms = [doc];
  panel.openDrill(doc, entry, VM);
}
/** The page's refresh: fresh state documents, then the panel. */
function refreshWith(doc) {
  globalThis.allVms = doc ? [doc] : [];
  return panel.refreshDrill();
}
/** The words of the panel's status pill: the first pill it draws. */
const pillOf = (html) => (/<span class="pill[^"]*"[^>]*>(?:<[^>]*>)*([^<]*)<\/span>/.exec(html) || [])[1];
/** The SAME element: eq compares JSON, and two of these fakes print alike. */
const same = (got, want, what) => ok(got === want, what);
const migratedLabel = UX_STATE.MIGRATED[0];
const decisionLabel = UX_STATE.NEEDS_DECISION[0];

test('the drill: a panel open at Needs a decision shows Migrated and no stop after the refresh', () => {
  reset();
  openFor(stoppedDoc());
  eq(pillOf(body.innerHTML), decisionLabel, 'before: the decision pill');
  ok(body.innerHTML.includes(permTitle), 'before: the stop box');
  ok(body.innerHTML.includes('id="resolve-btn"'), 'before: Try this machine again');
  ok(body.innerHTML.includes('id="skip-btn"'), 'before: Leave this machine out');

  // RESTORE-PANEL-TIMELINE-1: the list is the machine's lines of the run history.
  globalThis.latestEvents = [{ tsUtc: '2026-10-24T11:20:00Z', step: 'CONVERTING', outcome: 'ok', vmId: VM }];
  eq(refreshWith(migratedDoc()), true, 'the refresh drew the panel');
  const html = body.innerHTML;
  ok(html.includes(migratedLabel), `after: the Migrated pill: ${html.slice(0, 300)}`);
  eq(pillOf(html), migratedLabel, 'after: the status pill says Migrated');
  ok(!html.includes(permTitle), 'after: no stop box');
  for (const id of ['resolve-btn', 'decide-btn', 'skip-btn']) { ok(!html.includes(`id="${id}"`), `after: no ${id}`); }
  ok(html.includes(UX_STATE.CONVERTING[0]), 'after: the timeline has the new attempt');
  ok(drill.classList.contains('open'), 'the panel stays open');
});

test('a refresh that brings nothing new does not draw the panel again', () => {
  reset();
  openFor(stoppedDoc());
  const before = draws, filled = fills;
  eq(refreshWith(stoppedDoc()), true, 'the refresh asked');
  eq(draws, before, 'the same document, a new object: no new draw');
  eq(fills, filled, 'and no new call to the service');
  eq($('#resolve-btn').wired, 1, 'Try this machine again is wired once, not again');
  refreshWith(migratedDoc());
  eq(draws, before + 1, 'a changed document: one draw');
  refreshWith(migratedDoc());
  eq(draws, before + 1, 'and none after it');
});

test('a dialog open from the panel survives the refresh, with its typed note and its focus', () => {
  reset();
  openFor(stoppedDoc());
  // Try this machine again: the dialog is #modal-back, outside the panel.
  modalBack.classList.add('open');
  noteBox.value = 'Granted the role on the subnet.';
  noteBox.focus();
  refreshWith(migratedDoc());
  ok(body.innerHTML.includes(migratedLabel), 'the panel behind it is current');
  ok(modalBack.classList.contains('open'), 'the dialog is still open');
  eq(noteBox.value, 'Granted the role on the subnet.', 'the typed note');
  same(document.activeElement, noteBox, 'the focus stays in the dialog');
});

test('the focused button keeps the focus when it is still there; when it is gone, the panel keeps it', () => {
  reset();
  openFor(stoppedDoc());
  $('#skip-btn').focus();
  const again = stoppedDoc();
  again.history.push({ tsUtc: '2026-10-24T10:05:00Z', state: 'NEEDS_DECISION', outcome: 'ok', detail: 'a note' });
  refreshWith(again);
  same(document.activeElement, $('#skip-btn'), 'the new Leave this machine out button');
  refreshWith(migratedDoc());
  same(document.activeElement, closeBtn, 'the panel close button, not the page');
});

test('a focus outside the panel is not moved', () => {
  reset();
  openFor(stoppedDoc());
  const search = element('vm-search');
  search.focus();
  refreshWith(migratedDoc());
  same(document.activeElement, search, 'the search box keeps it');
});

test('the scroll position and the evidence the person opened stay', () => {
  reset();
  openFor(stoppedDoc());
  $('#ev-holder').innerHTML = '<pre class="evidence">captured</pre>';
  drill.scrollTop = 340;
  refreshWith(migratedDoc());
  eq($('#ev-holder').innerHTML, '<pre class="evidence">captured</pre>', 'the evidence');
  eq(drill.scrollTop, 340, 'the scroll position');
});

test('evidence that loads after a redraw goes into the panel on the screen', async () => {
  reset();
  const withEvidence = stoppedDoc();
  withEvidence.history[1].evidenceRef = 'evidence/precheck.json';
  let answer;
  globalThis.source = { readText: () => new Promise((resolve) => { answer = resolve; }) };
  openFor(withEvidence);
  ok(evlinks.length > 0, 'the timeline has an evidence link');
  const loading = evlinks[0].handlers.click();
  const moved = JSON.parse(JSON.stringify(withEvidence));
  moved.history.push({ tsUtc: '2026-10-24T10:05:00Z', state: 'NEEDS_DECISION', outcome: 'ok', detail: 'a note' });
  refreshWith(moved);
  answer('{"ok":true}');
  await loading;
  ok($('#ev-holder').innerHTML.includes('{"ok":true}'), `the evidence: ${$('#ev-holder').innerHTML}`);
});

test('evidence that loads after the panel changed to another machine is not shown there', async () => {
  reset();
  const withEvidence = stoppedDoc();
  withEvidence.history[1].evidenceRef = 'evidence/precheck.json';
  let answer;
  globalThis.source = { readText: () => new Promise((resolve) => { answer = resolve; }) };
  openFor(withEvidence);
  const loading = evlinks[0].handlers.click();
  const other = { vmId: 'vm-other', state: 'MIGRATED', history: [] };
  panel.openDrill(other, { vmId: 'vm-other', wave: 'w1', path: 'A' }, 'vm-other');
  answer('{"ok":true}');
  await loading;
  ok(!$('#ev-holder').innerHTML.includes('{"ok":true}'), 'not on the other machine');
});

test('a closed panel is not drawn and not opened by the refresh', () => {
  reset();
  openFor(stoppedDoc());
  panel.closeDrill();
  const before = draws;
  eq(refreshWith(migratedDoc()), false, 'nothing to draw');
  eq(draws, before, 'no draw');
  ok(!drill.classList.contains('open'), 'still closed');
});

test('a panel of another run closes when the page shows a new run', () => {
  reset();
  openFor(stoppedDoc());
  globalThis.currentRun = 'run-2';
  eq(refreshWith(null), false, 'nothing drawn');
  ok(!drill.classList.contains('open'), 'the panel of run-1 is closed');
});

test('a queued machine that the wave starts shows its state on the refresh', () => {
  reset();
  panel.openDrill(undefined, entry, VM);
  ok(body.innerHTML.includes('Queued'), 'before: queued');
  const before = draws;
  refreshWith(null);
  eq(draws, before, 'still queued: no new draw');
  refreshWith({ vmId: VM, state: 'PRECHECK', history: [{ tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' }] });
  ok(body.innerHTML.includes(UX_STATE.PRECHECK[0]), 'after: the step it is on');
});

test('selecting a row draws the panel even when nothing changed', () => {
  reset();
  openFor(stoppedDoc());
  const before = draws;
  panel.openDrill(stoppedDoc(), entry, VM);
  eq(draws, before + 1, 'a selection is a new draw');
});

/* ---- review: time passing alone is not a change ------------------------ */
const tick = () => new Promise((resolve) => setImmediate(resolve));
const rolledBack = () => ({ vmId: VM, state: 'FAILED_ROLLED_BACK',
  guestExecutions: [{ script: 'prep', version: '1', result: 'OK', tsUtc: '2026-10-24T10:02:00Z' }],
  history: [
    { tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
    { tsUtc: '2026-10-24T10:20:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'permissionsMissing', machineState: 'restored' }] });

test('time passing alone does not draw the panel again: it only writes the times again', () => {
  reset();
  openFor(rolledBack());
  ok(agoSpans.length > 0, 'the panel says a time as "... ago"');
  const before = draws;
  agoText = '5 minutes ago';
  refreshWith(rolledBack());
  eq(draws, before, 'no new draw');
  ok(agoSpans.every(s => s.textContent === '5 minutes ago'), 'the times are current');
});

test('a rolled-back machine: time passing asks the service nothing and keeps the series buttons', async () => {
  reset();
  openFor(rolledBack());
  await tick();
  eq(fills, 1, 'the selection asked the service once');
  const button = $('#retryseries-v5');
  ok(button, 'the Change to v5 button has a stable id');
  agoText = '2 minutes ago';
  refreshWith(rolledBack());
  await tick();
  eq(fills, 1, 'no new call');
  same($('#retryseries-v5'), button, 'the same button, not emptied and filled again');
});

test('a real redraw of a rolled-back machine reuses the series answer and keeps the focus on its button', async () => {
  reset();
  openFor(rolledBack());
  await tick();
  const button = $('#retryseries-v5');
  button.focus();
  const noted = rolledBack();
  noted.history.push({ tsUtc: '2026-10-24T10:30:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'ok', detail: 'a note' });
  const before = draws;
  refreshWith(noted);
  eq(draws, before + 1, 'drawn again');
  eq(fills, 1, 'the same plan entry and state: no new call');
  ok($('#retryseries-v5') && $('#retryseries-v5') !== button, 'a new button after the draw');
  same(document.activeElement, $('#retryseries-v5'), 'the focus is on it');
});

test('a new plan entry, or a selected row, asks the service again', async () => {
  reset();
  openFor(rolledBack());
  await tick();
  panel.openDrill(rolledBack(), entry, VM);
  await tick();
  eq(fills, 2, 'a selection asks again');
  const noted = rolledBack();
  noted.history.push({ tsUtc: '2026-10-24T10:30:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'ok', detail: 'a note' });
  globalThis.planDoc = { entries: [{ ...entry, target: { choice: 'v5' } }] };
  refreshWith(noted);
  await tick();
  eq(fills, 3, 'another plan entry asks again');
});

/* ---- review: a run that is gone takes its panel with it ---------------- */
test('a run deleted while its panel is open closes the panel', () => {
  reset();
  openFor(stoppedDoc());
  statics['#kpis'] = element('kpis');
  globalThis.readingRegions = () => [];
  globalThis.showingRun = 'run-1';
  const { clearReadingRun } = liftAll('migrations.html', ['clearReadingRun', 'closeDrill']);
  clearReadingRun();
  ok(!drill.classList.contains('open'), 'the panel is closed');
});
test('the page refresh draws the open panel, after the waves', () => {
  const body = extract('migrations.html', 'refreshRun');
  ok(/renderWaves\(halted\);\s*refreshDrill\(\);/.test(body), 'refreshRun calls refreshDrill after renderWaves');
});

test('rule 11: Escape and the close button still close the panel', () => {
  ok(/if \(\$\('#drill'\)\.classList\.contains\('open'\)\) \{ closeDrill\(\); return; \}/.test(PAGE), 'Escape');
  // CSP-INLINE-1: a listener, because the policy refuses an onclick= attribute.
  // MANUAL-REVIEW-1: the button has a name a screen reader says.
  ok(PAGE.includes('<button type="button" class="close" id="drill-close" aria-label="Close" title="Close">'), 'the close button');
  ok(PAGE.includes("$('#drill-close').addEventListener('click', closeDrill);"), 'the close button closes the panel');
});

run('machine-panel-stale');
