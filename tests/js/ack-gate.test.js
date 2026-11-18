/* ACK-GATE-1, 2026-09-18. The page gates Start on what the ENGINE gates on.
 *
 * WHAT HAPPENED. The owner pressed "Start this wave" on a run that had never
 * been acknowledged. The engine refused before it looked at the wave at all:
 *
 *   This run has not been acknowledged: Migrating a machine changes its size,
 *   its disk controller and its disk identities... Someone has to accept that
 *   before this run can start - do it in the wizard, or with
 *   Confirm-VmfRunAcknowledgement.
 *
 * The page had offered the button anyway, because it did not know the gate
 * existed. And there was no way to fix it from the app: the acceptance was
 * collected in the wizard and nowhere else, so he was handed a wizard URL built
 * by reading source - REACH-1 broken, the rule that every operator action is
 * reachable from the app.
 *
 * THE RULE WAS ALREADY WRITTEN DOWN. The comment beside this code says, of the
 * wave-options gate:
 *
 *   "An operator saw the warning and a blue Start button side by side, pressed
 *    Start, and was told the wave was starting. Nothing started... Gate on what
 *    the engine gates on, and say why the button is not there."
 *
 * It was never pointed at the run-level gate. Same defect, same page, one gate
 * along - which is the shape of every defect found on this install.
 *
 * ORDER MATTERS. Start-VmfWave checks the acknowledgement FIRST, then the wave
 * options, then the approval. A page naming a later gate sends somebody to fix
 * the wrong thing.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const str = (name) => {
  const m = PAGE.match(new RegExp(name + ": *'([^']*)'"));
  if (!m) { throw new Error('could not read UX_ACT.' + name); }
  return m[1];
};

const gate = liftAll('migrations.html', ['askAcknowledge', 'ackNoteNodes', 'renderRunActions']);

/* THE PAGE'S OWN TEST OF "is this accepted", not a copy of it.
 *
 * The first version of the last check in this file recomputed the condition
 * inline, so it measured the TEST and not the page - and mutation walked past
 * it. The harness lifts function declarations, and this is a const arrow, so it
 * is read out of the page and evaluated here. */
const ackExpr = PAGE.match(/const runAcknowledged = (\(\) => [^;]+);/);
if (!ackExpr) { throw new Error('could not read runAcknowledged from the page'); }
// eslint-disable-next-line no-eval
globalThis.runAcknowledged = eval('(' + ackExpr[1] + ')');

globalThis.UX_ACT = {
  ackTitle: str('ackTitle'),
  // IAC-NOTE-LIST-1: the note is a lead, a list and a closing line.
  ackLead: str('ackLead'), ackChanges: liftConst('migrations.html', 'UX_ACT').ackChanges, ackAfter: str('ackAfter'),
  ackAccept: str('ackAccept'), ackMissing: str('ackMissing'),
  ackBtn: str('ackBtn'), ackDone: str('ackDone'),

  // PROJ-EMPTY-1 moved stopping and deleting the run off the wave
  // safety-brake tile and onto this row, so the row needs their words too.
  stopRun: str('stopRun'), discardRun: str('discardRun'),
};
globalThis.noteField = () => ({ id: 'note', label: 'Why?' });
globalThis.runSeg = () => 'migration-1';
globalThis.esc = (v) => String(v == null ? '' : v);

function actions({ acked, operator = true, approver = false, working = true }) {
  const host = { innerHTML: '' };
  const wired = {};
  globalThis.$ = (sel) => (sel === '#run-actions' ? host
    : { addEventListener: (_, fn) => { wired[sel] = fn; } });
  globalThis.currentRun = 'proj/migration-1';
  globalThis.canOperate = () => operator;
  globalThis.canApprove = () => approver;
  globalThis.runAck = acked;

  // PROJ-EMPTY-1: the two run-lifecycle buttons live on this row now.
  globalThis.runIsWorking = () => working;
  globalThis.askStopRun = () => {};
  globalThis.askDiscardRun = () => {};
  // DISCARD-ENGINE-1: the row reads whether the engine is deleting the run.
  globalThis.discardInFlight = null;
  gate.renderRunActions();
  return { html: host.innerHTML, wired };
}

/* IAC-NOTE-LIST-1: the dialog builds the note with DOM nodes in #m-desc.
 * iac-note-list.test.js reads what it builds; these tests need only a place
 * to put it. */
function dialogDom() {
  globalThis.$ = () => ({ replaceChildren() {} });
  globalThis.document = { createElement: () => ({ appendChild() {} }) };
}

/* ---- the way to accept it, from this page ------------------------------ */

test('REACH-1: an unacknowledged run offers the acceptance here', () => {
  /* The defect was not only the button that could not work - it was that the
   * only cure lived in the wizard, and somebody had to be handed a URL. */
  const out = actions({ acked: null });
  ok(out.html.includes(UX_ACT.ackBtn), 'the page offers it');
});

test('and stops offering it once it is done', () => {
  const out = actions({ acked: { acknowledgedBy: 'operator' } });
  ok(!out.html.includes(UX_ACT.ackBtn), 'a button for something already done is noise');
  // REPORT-AUTO-1: the report button left this row; the run actions stay.
  ok(out.html.includes(UX_ACT.stopRun), 'the other actions are still there');
});

test('somebody who cannot operate is not offered it', () => {
  const out = actions({ acked: null, operator: false, approver: true });
  ok(!out.html.includes(UX_ACT.ackBtn));
});

test('the dialog asks the wizard question, word for word', () => {
  /* One question asked in two places must not become two questions.
   * IAC-NOTE-LIST-1: the note is a list now, and iac-note-list.test.js holds
   * its words on both pages; here, the checkbox is the wizard's. */
  let captured = null;
  globalThis.openModal = (o) => { captured = o; };
  dialogDom();
  gate.askAcknowledge();
  const wizard = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  const wizardAccept = wizard.match(/iacAccept: *'([^']*)'/)[1];
  eq(captured.fields[0].options[0].label, wizardAccept);
});

test('it refuses to send an acceptance nobody ticked', () => {
  let captured = null;
  globalThis.openModal = (o) => { captured = o; };
  globalThis.apiFetch = async () => { throw new Error('must not be called'); };
  dialogDom();
  gate.askAcknowledge();
  return captured.onConfirm({ accept: [], note: 'n' })
    .then(() => { throw new Error('it should have refused'); })
    .catch(e => { eq(e.message, UX_ACT.ackMissing); });
});

test('a ticked acceptance is sent for THIS run, with the topic the engine reads', async () => {
  let captured = null, sent = null;
  globalThis.openModal = (o) => { captured = o; };
  globalThis.apiFetch = async (path, body) => { sent = { path, body }; };
  dialogDom();
  gate.askAcknowledge();
  await captured.onConfirm({ accept: ['yes'], note: 'accepted' });
  eq(sent.path, 'runs/migration-1/acknowledge');
  eq(sent.body.topic, 'infrastructure-as-code',
     'the engine reads acknowledgements/infrastructure-as-code.json');
  eq(sent.body.note, 'accepted');
});

/* ---- the gate itself, read from the page ------------------------------- */

test('THE REGRESSION: Start is gated on the acknowledgement', () => {
  /* WAVE-GATE-1 put "this wave is running now" ahead of the three gates, so
   * this no longer matches the first branch by hand. What it always meant is
   * that the run-level gate is among the things asked before Start is
   * offered - and the check below still holds the ORDER of the three. */
  const expr = PAGE.match(/const startBlockedBy =[\s\S]*?;/)[0];
  ok(/runAcknowledged\(\)/.test(expr),
     'the run-level gate is tested before a wave button is offered');
});

test('and it is tested FIRST, in the order the engine checks them', () => {
  /* Start-VmfWave checks the acknowledgement, then the wave options, then the
   * approval. Naming a later gate sends somebody to fix the wrong thing. */
  const expr = PAGE.match(/const startBlockedBy =[\s\S]*?;/)[0];
  const ackAt = expr.indexOf('runAcknowledged');
  const accAt = expr.indexOf('!acc ?');
  const apprAt = expr.indexOf('needsApproval');
  ok(ackAt >= 0 && accAt > ackAt, 'the acknowledgement is named before the options');
  ok(apprAt > accAt, 'and the options before the approval');
});

test('a run whose acknowledgement names nobody does not count as accepted', () => {
  /* The engine refuses that too - "the recorded acknowledgement names nobody -
   * it has to be a person, because it is the audit trail". A page that took an
   * empty name would offer Start for a run that still cannot start. Driven
   * through the page's own check, and through what it paints. */
  const out = actions({ acked: { acknowledgedUtc: '2026-09-18T00:00:00Z' } });
  ok(out.html.includes(UX_ACT.ackBtn),
     'still offered, because a document naming nobody is not an acceptance');
});

run('acknowledgement gate');
