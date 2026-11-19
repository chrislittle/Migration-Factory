/* CLOSE-NOT-CANCEL-1, lab Session A, 2026-11-04: a toggle that only shows
 * information said "Cancel" when it was open.
 *
 * Rule 11 is built as one button with two states, and the second state was
 * always Cancel. On the Migrations page that read "Starts within about 5
 * minutes [Cancel]" - as if the button cancels the start of the wave, which it
 * does not do. The owner: on a toggle that only shows information, the word is
 * Close.
 *
 * The rule (CLAUDE.md hard rule 11): Close when the open part only shows
 * information; Cancel when it holds a choice that is not saved and closing
 * throws it away. Escape does the same as the button.
 *
 * RUN, not read: each toggle's own function, with its page's own words.
 * The Details of the review and targets steps are run in review-page.test.js
 * and rebuild-picker.test.js.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// ACCEPT-FIRST-MACHINE-1: the settings of a wave are read by the rule in
// help.js; waves.js names its parts (leverValue, keepsOwn, waveCard) as
// aliases of VmfHelp, so the page functions find them on the global object.
function waveRuleGlobal() { const r = require('./_at-once').waveRule; Object.assign(globalThis, { leverValue: r.leverValue, ownDecision: r.ownDecision, keepsOwn: r.keepsOwn, waveCard: r.waveCard }); return r; }

const REPO = path.join(__dirname, '..', '..');
const esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.esc = esc;
globalThis.vmName = (id) => String(id).split('/').pop();

/** The word on an open toggle: the text of the button whose data attribute is `attr`. */
function wordOn(html, attr) {
  const m = html.match(new RegExp(`<button[^>]*${attr}[^>]*>([^<]*)</button>`));
  if (!m) { throw new Error(`no button with ${attr} in: ${html}`); }
  return m[1];
}
function labelOn(html, attr) {
  const m = html.match(new RegExp(`<button[^>]*${attr}[^>]*aria-label="([^"]*)"`));
  if (!m) { throw new Error(`no aria-label on the button with ${attr} in: ${html}`); }
  return m[1];
}

// ---- The wizard: every (?) of the targets and Run it steps --------------------
const WUX = liftConst('wizard.html', 'UX');

test('the wizard has a Close word for its toggles, and no Cancel word left for them', () => {
  eq(WUX.tClose, 'Close');
  eq(Object.prototype.hasOwnProperty.call(WUX, 'tCancel'), false, 'tCancel is gone');
});

test('RUN: an open (?) of the wizard says Close; closed, it says ?', () => {
  globalThis.UX = WUX;
  const tHelpBtn = liftAll('wizard.html', ['tHelpBtn']).tHelpBtn;
  globalThis.tHelp = new Set();
  const shut = tHelpBtn('sum', WUX.tSumAbout);
  eq(wordOn(shut, 'data-help="sum"'), '?');
  globalThis.tHelp = new Set(['sum']);
  const open = tHelpBtn('sum', WUX.tSumAbout);
  eq(wordOn(open, 'data-help="sum"'), 'Close', 'the open (?) says Close');
  eq(labelOn(open, 'data-help="sum"'), 'Close', 'and a screen reader hears Close');
  ok(!open.includes('Cancel'), open);
  globalThis.tHelp = new Set();
});

// ---- The Migrations page: Starts within about 5 minutes, and the dialog's (?) ----
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const UX_MISC = liftConst('migrations.html', 'UX_MISC');

test('the Migrations page has a Close word, and keeps Cancel for its dialog', () => {
  eq(UX_ACT.close, 'Close');
  eq(UX_ACT.cancel, 'Cancel', 'the dialog still has Cancel: it holds a note and choices not sent');
  const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
  ok(PAGE.includes("$('#m-cancel').textContent = UX_ACT.cancel;"), 'the dialog button says Cancel');
});

test('RUN: the (?) beside "Starts within about 5 minutes" says Close when open, never Cancel', () => {
  globalThis.UX_MISC = UX_MISC; globalThis.UX_ACT = UX_ACT;
  const { startsSoonHtml } = liftAll('migrations.html', ['startsSoonHtml']);
  globalThis.soonHelpOpen = new Set(['w2']);
  const open = startsSoonHtml('w2');
  ok(open.includes(esc(UX_MISC.startsSoon)) && open.includes(esc(UX_MISC.startsSoonHelp)), open);
  eq(wordOn(open, 'data-soonhelp="w2"'), 'Close', 'Close: the button does not cancel the start');
  eq(labelOn(open, 'data-soonhelp="w2"'), 'Close');
  ok(!open.includes('Cancel'), open);
  globalThis.soonHelpOpen = new Set();
  eq(wordOn(startsSoonHtml('w2'), 'data-soonhelp="w2"'), '?');
});

test('RUN: the (?) of an option in a dialog says Close when open, and ? again when closed', () => {
  globalThis.UX_ACT = UX_ACT;
  const page = liftAll('migrations.html', ['toggleModalHelp', 'closeModalHelp']);
  const text = { hidden: true };
  const btn = { dataset: { mhelp: 'h0' }, textContent: '?', attrs: { 'aria-expanded': 'false' },
    setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k]; } };
  globalThis.document = { getElementById: (id) => (id === 'h0' ? text : null), querySelectorAll: () => [btn] };
  page.toggleModalHelp(btn);
  eq(btn.textContent, 'Close'); eq(btn.attrs['aria-label'], 'Close');
  eq(page.closeModalHelp(), true, 'Escape closes it, as the button does');
  eq(btn.textContent, '?'); eq(text.hidden, true);
});

// ---- The wave editor: the (?) of "keep their own value" --
const VUX = liftConst('waves.html', 'UX');

test('the wave editor has a Close word, and keeps Cancel for Reset and Change target', () => {
  eq(VUX.close, 'Close');
  eq(VUX.cancel, 'Cancel');
});

// REBUILD-REMOVE-ACCEPT-1: the identity pill and its (?) are gone with the rebuild.

/* The (?) of "N machines keep their own value" lists the machines. Where the
 * person can change the wave, each has a Reset, and closing the helper cancels
 * the resets not saved. So: Close while it holds no reset, Cancel once it
 * holds one - the word says what the button does. */
function ownSetUp({ edit = true } = {}) {
  globalThis.UX = VUX;
  // WAVE_DEFAULTS reads VmfHelp.WAVE_DEFAULT_WORKERS, so VmfHelp comes first.
  // ACCEPT-FIRST-MACHINE-1: and the rule and words of help.js (ownRowText).
  globalThis.VmfHelp = require('./_at-once').atOnce({ approvalRequired: lift('help.js', 'approvalRequired'), WAVE_DEFAULT_WORKERS: 15 });
  globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
  globalThis.WAVE_WIDE = ['capacityGate', 'requireApproval', 'throttle'];
  const page = ({ ...waveRuleGlobal(), ...liftAll('waves.html', ['ownOf', 'ownHint', 'ownRow', 'resetPending', 'toggleReset', 'clearResets', 'resetLocked', 'toggleOwnHelp']) });
  Object.assign(globalThis, page);
  globalThis.entries = [
    { vmId: '/s/a', wave: 'w', policy: { keepSnapshotDays: 14 } },
    { vmId: '/s/c', wave: 'w', policy: {} },
  ];
  globalThis.membersOf = (name) => entries.filter(e => layout.get(name).vmIds.includes(e.vmId));
  const w = { ...WAVE_DEFAULTS, vmIds: entries.map(e => e.vmId), drawn: { ...WAVE_DEFAULTS } };
  globalThis.layout = new Map([['w', w]]);
  globalThis.ownHelp = new Set(['w|keepSnapshotDays']);
  globalThis.canEdit = edit;
  globalThis.canSignOff = true;
  globalThis.waveMigrating = () => false;
  globalThis.render = () => {};
  return { w, page };
}

test('RUN: the (?) of "keep their own value" says Close while it holds no reset', () => {
  const { w, page } = ownSetUp();
  const open = page.ownHint('w', w, 'keepSnapshotDays');
  ok(open.includes('data-ownreset'), 'it offers a Reset');
  eq(wordOn(open, 'data-ownhelp="w\\|keepSnapshotDays"'), 'Close', 'nothing to throw away: Close');
  eq(labelOn(open, 'data-ownhelp="w\\|keepSnapshotDays"'), 'Close');
});

test('RUN: with a reset not saved, the same (?) says Cancel - closing it cancels the reset', () => {
  const { w, page } = ownSetUp();
  page.toggleReset('w', 'keepSnapshotDays', '/s/a');
  const pending = page.ownHint('w', w, 'keepSnapshotDays');
  eq(wordOn(pending, 'data-ownhelp="w\\|keepSnapshotDays"'), 'Cancel', 'a choice not saved: Cancel');
  eq(labelOn(pending, 'data-ownhelp="w\\|keepSnapshotDays"'), 'Cancel');
  eq(wordOn(pending, 'data-ownreset="w\\|keepSnapshotDays"'), 'Cancel', 'the Reset is Cancel too');
  page.toggleOwnHelp('w|keepSnapshotDays');
  eq(page.resetPending(w, 'keepSnapshotDays', '/s/a'), false, 'the button did what it said');
  page.toggleOwnHelp('w|keepSnapshotDays');
  eq(wordOn(page.ownHint('w', w, 'keepSnapshotDays'), 'data-ownhelp="w\\|keepSnapshotDays"'), 'Close', 'and Close again');
});

test('RUN: for a person who cannot change the wave, the list only shows information: Close', () => {
  const { w, page } = ownSetUp({ edit: false });
  const open = page.ownHint('w', w, 'keepSnapshotDays');
  ok(!open.includes('data-ownreset'), 'no Reset');
  eq(wordOn(open, 'data-ownhelp="w\\|keepSnapshotDays"'), 'Close');
});

// ---- Get help: the guide of the screen only shows information -------------------
const HELP = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
// eslint-disable-next-line no-eval
const TEXT = eval('(' + HELP.match(/\n {2}const TEXT = (\{[\s\S]*?\n {2}\});/)[1] + ')');

function helpDialogs() {
  const shown = [];
  globalThis.TEXT = TEXT;
  globalThis.dialog = (body, buttons, title) => { shown.push({ body, buttons, title }); return { querySelectorAll: () => [] }; };
  globalThis.openManual = () => {};
  globalThis.currentPage = () => 'waves.html';
  return shown;
}

test('RUN: the guide of the screen closes with Close, and so does its notice when it cannot load', async () => {
  const guideDialog = lift('help.js', 'guideDialog');
  let shown = helpDialogs();
  globalThis.fetch = async () => ({ ok: true, json: async () => ({ screens: { 'waves.html': { title: 'Waves', what: 'x', howToRead: [], nextStep: 'y' } } }) });
  await guideDialog();
  eq(shown[0].buttons.map(b => b.label), [TEXT.guideGeneral, 'Close'], 'the guide: Read the manual, Close');
  shown = helpDialogs();
  globalThis.fetch = async () => ({ ok: false });
  await guideDialog();
  eq(shown[0].buttons.map(b => b.label), [TEXT.openGithub, 'Close'], 'the notice: Read the manual, Close');
});

test('RUN: "Pick a migration first" only shows information: Close; the file dialog keeps Cancel', () => {
  const bundleDialog = lift('help.js', 'bundleDialog');
  let shown = helpDialogs();
  globalThis.adapter = { getRunId: () => null };
  bundleDialog();
  eq(shown[0].buttons.map(b => b.label), ['Close'], 'nothing to choose: Close');
  shown = helpDialogs();
  globalThis.adapter = { getRunId: () => 'run-1' };
  bundleDialog();
  eq(shown[0].buttons[0].label, 'Cancel', 'Download the file is not done yet: Cancel');
});

run('close-not-cancel');
