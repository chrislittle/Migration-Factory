/* DIALOG-STALE-1, filed by MACHINE-PANEL-STALE-1 (2026-10-24): the side
 * panel follows its machine on each refresh, but a dialog the panel opened
 * (Try this machine again, Restore, the decision, Leave this machine out,
 * Rebuild, Finish) was built ONE time, from the state document the panel held
 * when the button was selected. A machine that moved on while the dialog was
 * open kept its old stop in the dialog, and Confirm was refused with no word
 * that the machine changed.
 *
 * Now the refresh says so in the dialog, with the machine's new state, and
 * keeps the typed note and the dialog open. It asks the panel's own change
 * check (drawDrill and drillKey, with the "... ago" texts left out), so time
 * passing alone shows nothing.
 *
 * RUN, not read: the page's own openModal, askResolve, openDrill, drawDrill,
 * refreshDrill, panelDialog and markDialogStale, against a small DOM of our
 * own (the _harness rule: the function is real, the DOM is yours).
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

/* ---- what the panel and the dialog read that is not under test ---------- */
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => id;
globalThis.techText = (s) => s;
globalThis.stepText = (e) => e.step;
globalThis.guestRunPill = () => '';
// The "... ago" text. A test changes it to stand for time passing.
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
globalThis.apiFetch = async () => ({ Options: [] });
globalThis.runSeg = () => 'run-1';
globalThis.runBody = (b) => b;
globalThis.followThrough = () => { };
globalThis.retrySeriesCache = null;
globalThis.drillFocusId = null;
// The panel's dialogs this file does not open: each opens a plain dialog, as
// the real ones do through openModal.
for (const n of ['askDecide', 'askRestore', 'askFinish', 'askSkipVm']) {
  globalThis[n] = () => globalThis.openModal({ title: n, desc: n, fields: [globalThis.noteField()] });
}
// The page's own `let`s.
globalThis.drillVmId = null;
globalThis.drillRun = null;
globalThis.drillDrawn = null;
globalThis.modalMachine = null;

/* ---- a small DOM ---------------------------------------------------------
 * An element the panel's markup names by id is made on first lookup, ONCE
 * per draw, so a lookup after a redraw is a new element. The dialog's
 * elements are static, as in the page: no panel draw writes them. */
function classes() {
  const s = new Set();
  return { add: (c) => s.add(c), remove: (c) => s.delete(c), contains: (c) => s.has(c) };
}
let children = new Map();
function element(id) {
  return {
    id, _html: '', value: '', textContent: '', dataset: {}, handlers: {}, classList: classes(), style: {}, writes: 0,
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); this.writes++; },
    querySelectorAll() { return []; },
    querySelector() { return null; },
    addEventListener(kind, fn) { this.handlers[kind] = fn; },
    focus() { globalThis.document.activeElement = this; },
    scrollIntoView() { },
  };
}
const closeBtn = element('');
const drill = element('drill');
drill.scrollTop = 0;
drill.querySelector = (sel) => (sel === '.close' ? closeBtn : null);
const body = {
  _html: '',
  get innerHTML() { return this._html; },
  set innerHTML(v) { this._html = String(v); children = new Map(); },
  contains(el) { return [...children.values()].includes(el); },
  querySelectorAll() { return []; },
};
const modalBack = element('modal-back');
const noteBox = element('mf-note');
const fieldsBox = element('m-fields');
// The note box is the textarea openModal writes into the fields.
fieldsBox.querySelector = (sel) => (sel === 'input,textarea' && fieldsBox._html.includes('id="mf-note"') ? noteBox : null);
const stale = element('m-stale');
const statics = {
  '#drill': drill, '#drill-body': body, '#modal-back': modalBack, '#mf-note': noteBox, '#m-fields': fieldsBox,
  '#m-title': element('m-title'), '#m-desc': element('m-desc'), '#m-err': element('m-err'),
  '#m-cancel': element('m-cancel'), '#m-confirm': element('m-confirm'), '#m-stale': stale,
};
globalThis.$ = (sel) => {
  if (statics[sel]) { return statics[sel]; }
  const m = /^#([\w-]+)$/.exec(sel);
  if (!m || !body._html.includes(`id="${m[1]}"`)) { return null; }
  if (!children.has(m[1])) { children.set(m[1], element(m[1])); }
  return children.get(m[1]);
};
globalThis.document = { activeElement: null, getElementById: (id) => globalThis.$('#' + id), querySelector: () => null, querySelectorAll: () => [] };

// noteField is an arrow const in the page: lifted by its own line.
// eslint-disable-next-line no-eval
globalThis.noteField = eval(PAGE.match(/const noteField = (\(required = true\) =>\s*\(\{[^}]*\}\));/)[1]);
const page = liftAll('migrations.html', ['openModal', 'modalFieldHtml', 'modalHelpHtml', 'modalHelpText', 'closeModal', 'askResolve', 'askHalt', 'retryFacts', 'panelDialog', 'markDialogStale',
  'openDrill', 'capacityLine', 'drawDrill', 'refreshDrill', 'closeDrill', 'refocusDrill', 'revealDiskDelete', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords',
  'agoSpan', 'drillKey', 'fillRetrySeries', 'retrySeriesOptions', 'lastStopEntry', 'sizeRefusedStop', 'restoreOntoTarget',
  'machineTimeline', 'attemptStop', 'currentStop', 'whyStoppedCard', 'stopControls', 'powerOwed', 'volumesCheckOffer', 'volumesCheckStarted', 'volumesStartedLine', 'powerName', 'retryHeld', 'decisionWaiting',
  'putBackControls', 'finishOffered', 'machinePill', 'shownState', 'restoredPill', 'statePill', 'checkpointLine',
  'restoredNoteHtml', 'restoreEarlierDisks', 'recordedMachineDiskIds', 'madeDiskRows', 'madeDisksHtml', 'recordDiskIdsInUse', 'rollbackOriginalDisks', 'rollbackOriginalsHtml', 'machineStatusOf', 'statusWord', 'statusPill', 'timelineDuration', 'activityLines', 'timelineLine', 'restoreEndAfter', 'restoreEndCard', 'foldedCallLines', 'rollbackFollows', 'stepRetried', 'retriedText']);
globalThis.openModal = page.openModal;

/* ---- the machine, before and after the retry ---------------------------- */
const VM = 'vm-app-01';
const entry = { vmId: VM, wave: 'w1', path: 'B' };
const parked = [
  { tsUtc: '2026-10-24T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-24T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'permissionsMissing',
    machineState: 'untouched', detail: 'The identity has no Microsoft.Compute/virtualMachines/write.' },
];
const stoppedDoc = () => ({ vmId: VM, state: 'NEEDS_DECISION', history: parked.map(h => ({ ...h })) });
const runningDoc = () => ({ vmId: VM, state: 'CONVERTING', history: [...parked.map(h => ({ ...h })),
  { tsUtc: '2026-10-24T11:00:00Z', state: 'PRECHECK', outcome: 'ok', detail: 'Re-armed at PRECHECK.' },
  { tsUtc: '2026-10-24T11:20:00Z', state: 'CONVERTING', outcome: 'ok' }] });
const migratedDoc = () => ({ vmId: VM, state: 'MIGRATED', history: [...runningDoc().history,
  { tsUtc: '2026-10-24T11:40:00Z', state: 'MIGRATED', outcome: 'ok' }] });
const migratedLabel = UX_STATE.MIGRATED[0];
const convertingLabel = UX_STATE.CONVERTING[0];
const NOTE = 'Granted the role on the subnet.';

function reset() {
  globalThis.currentRun = 'run-1';
  globalThis.planDoc = { entries: [entry] };
  globalThis.allVms = [];
  globalThis.drillVmId = null; globalThis.drillRun = null; globalThis.drillDrawn = null;
  globalThis.drillFocusId = null; globalThis.retrySeriesCache = null; globalThis.modalMachine = null;
  agoText = 'a moment ago';
  globalThis.document.activeElement = null;
  modalBack.classList.remove('open');
  noteBox.value = '';
  stale.innerHTML = ''; stale.style.display = 'none';
  drill.classList.remove('open');
  body.innerHTML = '';
}
function openFor(doc) {
  globalThis.allVms = [doc];
  page.openDrill(doc, entry, VM);
}
function refreshWith(doc) {
  globalThis.allVms = doc ? [doc] : [];
  return page.refreshDrill();
}
/** Select Try this machine again on the panel, and type a note. */
function openRetry() {
  const btn = $('#resolve-btn');
  ok(btn && btn.handlers.click, 'the panel offers Try this machine again');
  btn.handlers.click();
  ok(modalBack.classList.contains('open'), 'the dialog is open');
  eq(statics['#m-title'].textContent, UX_ACT.resolve, 'it is Try this machine again');
  noteBox.value = NOTE;
}
const shown = () => stale.style.display !== 'none' && stale.innerHTML !== '';
/** Cancel, as the dialog's Cancel button and Escape do. */
const cancel = () => modalBack.classList.remove('open');

test('the item: Try this machine again on a NEEDS_DECISION machine says the machine is now Migrated, and keeps the note', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  ok(!shown(), 'before the refresh: no notice');
  const fieldWrites = fieldsBox.writes;
  noteBox.focus();

  refreshWith(migratedDoc());
  ok(shown(), 'the dialog says the machine changed');
  ok(stale.innerHTML.includes(UX_ACT.dialogStale), `the words: ${stale.innerHTML}`);
  ok(stale.innerHTML.includes(migratedLabel), 'and shows the new state, Migrated');
  ok(modalBack.classList.contains('open'), 'the dialog stays open');
  eq(noteBox.value, NOTE, 'the typed note is kept');
  eq(fieldsBox.writes, fieldWrites, 'the fields are not written again');
  ok(document.activeElement === noteBox, 'the focus stays in the note');
  eq(statics['#m-title'].textContent, UX_ACT.resolve, 'still the same dialog');
});

test('time passing alone does not show the notice', () => {
  reset();
  // A script ran in the machine: the panel says when as "... ago".
  const withScript = () => ({ ...stoppedDoc(),
    guestExecutions: [{ script: 'prep', version: '1', result: 'OK', tsUtc: '2026-10-24T10:00:30Z' }] });
  openFor(withScript());
  ok(body.innerHTML.includes('data-ago='), 'the panel has an "... ago" text');
  openRetry();
  agoText = '9 minutes ago';
  refreshWith(withScript());
  ok(!shown(), 'the same document, only later: no notice');
  eq(noteBox.value, NOTE, 'the note');
});

test('each change shows the newest state', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  refreshWith(runningDoc());
  ok(stale.innerHTML.includes(convertingLabel), 'first: the step it is on');
  refreshWith(migratedDoc());
  ok(stale.innerHTML.includes(migratedLabel), 'then: Migrated');
  ok(!stale.innerHTML.includes(convertingLabel), 'and not the old state');
});

test('a dialog that the panel did not open gets no notice', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  cancel();
  // Pause the run: a dialog of the run, not of this machine.
  page.askHalt();
  ok(modalBack.classList.contains('open'), 'the pause dialog is open');
  refreshWith(migratedDoc());
  ok(!shown(), 'no notice about a machine in the pause dialog');
});

test('a dialog opened again after a notice starts without it', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  refreshWith(runningDoc());
  ok(shown(), 'the first dialog says the machine changed');
  cancel();
  globalThis.allVms = [runningDoc()];
  page.openDrill(runningDoc(), entry, VM);
  page.askHalt();
  eq(stale.style.display, 'none', 'the next dialog hides the old notice');
  eq(stale.innerHTML, '', 'and empties it');
});

test('a notice names only the machine of the dialog', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  eq(page.markDialogStale('vm-other', migratedDoc()), false, 'another machine: no notice');
  ok(!shown(), 'nothing shown');
  eq(page.markDialogStale(VM, migratedDoc()), true, 'this machine: the notice');
});

test('a machine whose state record is gone: the dialog says the product has no record of it now', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  refreshWith(null);
  ok(body.innerHTML.includes('Queued'), 'the panel shows the machine with no record');
  ok(shown(), 'the dialog says the machine changed');
  ok(stale.innerHTML.includes(UX_ACT.dialogGone), `the words: ${stale.innerHTML}`);
  ok(!stale.innerHTML.includes(UX_ACT.dialogStale), 'not the words for a new state');
  ok(modalBack.classList.contains('open'), 'the dialog stays open');
  eq(noteBox.value, NOTE, 'the typed note is kept');
});

test('closing the dialog clears its machine and hides the notice', () => {
  reset();
  openFor(stoppedDoc());
  openRetry();
  refreshWith(runningDoc());
  ok(shown(), 'the notice is there');
  page.closeModal();
  ok(!modalBack.classList.contains('open'), 'closed');
  eq(globalThis.modalMachine, null, 'the dialog is of no machine now');
  eq(stale.style.display, 'none', 'the notice is hidden');
});
test('every dialog on the panel is opened through panelDialog', () => {
  for (const fn of ['openDrill', 'capacityLine', 'fillRetrySeries']) {
    const src = extract('migrations.html', fn);
    const bare = src.match(/addEventListener\('click', \(\) => ask\w+\(/g) || [];
    eq(bare, [], `${fn}: a panel button opens its dialog through panelDialog`);
  }
  const src = extract('migrations.html', 'openDrill');
  for (const n of ['askResolve', 'askDecide', 'askRestore', 'askFinish', 'askSkipVm']) {
    ok(new RegExp(`panelDialog\\(vmId, \\(\\) => ${n}\\(`).test(src), `${n} goes through panelDialog`);
  }
});

test('every panel dialog marks its machine', () => {
  reset();
  const doc = stoppedDoc();
  openFor(doc);
  for (const id of ['resolve-btn', 'skip-btn']) {
    globalThis.modalMachine = null;
    $(`#${id}`).handlers.click();
    eq(globalThis.modalMachine, VM, `${id}: the dialog is for this machine`);
    cancel();
  }
});

test('rule 11: the dialog keeps Cancel and Escape', () => {
  // RESTORE-DIALOG-WORDS-1: an open ? helper of an option closes first, and
  // the next Escape closes the dialog (tests/js/restore-dialog-words runs it).
  ok(/if \(\$\('#modal-back'\)\.classList\.contains\('open'\)\) \{ if \(closeModalHelp\(\)\) return; closeModal\(\); return; \}/.test(PAGE), 'Escape');
  ok(PAGE.includes("$('#m-cancel').addEventListener('click', closeModal);"), 'Cancel');
  ok(PAGE.includes('id="m-stale"') && PAGE.includes('id="m-cancel"'), 'the notice sits in the dialog beside Cancel');
});

run('dialog-stale');
