/* TERMS-AUDIT-1, from lab Session A, 2026-11-04 and 2026-11-05.
 *
 * Two things the wording gate cannot see, because each is a choice the page
 * makes at run time, not a string it declares:
 *
 *   - THE WRONG LABEL ON A DELETE (a false statement). The step map tests
 *     /lockSnapshot/ first, and that also matches "unlockSnapshot". So every
 *     unlock - in the delete of a migration and in retention - read "Locked
 *     the safety copy so nobody can delete it before its retention ends", and
 *     the read before it ("readSnapshot") fell to /snapshot/i, "Taking a
 *     safety copy of every disk, now the machine is stopped".
 *   - AN ENGINE CODE AS A LINE. The stop panel showed the reason code
 *     (rebuildNotAccepted, dataDiskSwapRefused) in code font under the
 *     reason. The code stays in the technical record, as a tooltip.
 *
 * RUN, not read: the page's own stepText and whyStoppedCard.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const table = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));

global.STEP_MAP      = liftConst('migrations.html', 'STEP_MAP');
global.UX_STEP       = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE      = liftConst('migrations.html', 'UX_STATE');
global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
global.SAYS_ITSELF   = liftConst('migrations.html', 'SAYS_ITSELF');
const { stepText } = liftAll('migrations.html', ['stepText']);

test('the tables really were lifted, so this cannot pass by reading nothing', () => {
  ok(Array.isArray(global.STEP_MAP) && global.STEP_MAP.length > 40, 'STEP_MAP');
  ok(typeof stepText === 'function', 'stepText');
});

test('each line of a safety copy delete gets its own label, in the order the engine writes them', () => {
  // Remove-VmfRunSafetyCopies and Remove-VmfExpiredSafetyCopies, through Invoke-VmfAzOperation.
  const said = (name) => stepText({ step: `azureops:${name}`, outcome: 'ok' });
  eq(said('readSnapshot'), UX_STEP.readCopy, 'the read before the unlock is a read, not a new copy');
  eq(said('unlockSnapshot'), UX_STEP.unlockCopy, 'an unlock is an unlock');
  eq(said('removeSnapshot'), UX_STEP.deleteCopy, 'a delete is a delete');
  eq(said('lockSnapshot'), UX_STEP.lockCopy, 'a lock put back is a lock');
  ok(said('unlockSnapshot') !== UX_STEP.lockCopy, 'an unlock never says Locked');
  ok(said('readSnapshot') !== UX_STEP.snapshotDisk, 'a read never says a copy is being taken');
});

test('a warning on an unlock is not "The safety copy was not locked" (the same match, in the warn rule)', () => {
  const unlockWarn = stepText({ step: 'azureops:unlockSnapshot', outcome: 'warn', detail: 'The lock was already gone.' });
  ok(unlockWarn !== UX_STEP.lockCopySkipped, unlockWarn);
  ok(unlockWarn !== UX_STEP.lockCopy, unlockWarn);
  eq(stepText({ step: 'azureops:lockSnapshot', outcome: 'warn' }), UX_STEP.lockCopySkipped, 'a lock that could not be placed still says so');
  eq(stepText({ step: 'lockSnapshot', outcome: 'warn' }), UX_STEP.lockCopySkipped, 'with or without the azureops prefix');
});

test('the copies the move takes keep their labels', () => {
  eq(stepText({ step: 'azureops:pristineSnapshot', outcome: 'ok' }), UX_STEP.snapshotPristine, 'the first copy');
  eq(stepText({ step: 'azureops:snapshot', outcome: 'ok' }), UX_STEP.snapshotDisk, 'the second copy');
});

test('the unlock label is true in a delete as well as in retention: it does not say the retention ended', () => {
  ok(!/retention/i.test(UX_STEP.unlockCopy), UX_STEP.unlockCopy);
  ok(/lock/i.test(UX_STEP.unlockCopy) && /delete/i.test(UX_STEP.unlockCopy), UX_STEP.unlockCopy);
});

/* ---- the stop panel ----------------------------------------------------- */
global.UX_ACT = liftConst('migrations.html', 'UX_ACT');
global.esc = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
global.canApprove = () => true;
global.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
global.retryLines = table.retryLines;
// eslint-disable-next-line no-eval
global.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
// STOP-HEADLINE-CHECK-1: whyStoppedCard reads the check of a stop with stopCheckSentence.
globalThis.STOP_CHECK = liftConst('migrations.html', 'STOP_CHECK');
const card = liftAll('migrations.html', ['attemptStop', 'currentStop', 'stopCheckSentence', 'whyStoppedCard']);
const visible = (html) => html.replace(/<[^>]*>/g, ' ');

for (const code of ['rebuildNotAccepted', 'systemIdentityCannotSurvive', 'dataDiskSwapRefused', 'validationFailedAfterConversion', 'aCodeNoTableHas']) {
  test(`the stop panel does not show the code ${code} as a line, and keeps it as a tooltip`, () => {
    const doc = { state: 'NEEDS_DECISION', history: [
      { tsUtc: '2026-11-05T10:00:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: code, machineState: 'untouched', detail: 'Azure said no.' }] };
    const html = card.whyStoppedCard(doc);
    ok(html.length > 0, 'a panel is drawn');
    ok(!visible(html).includes(code), `the code is not in the text a person reads: ${visible(html)}`);
    ok(html.includes(`title="${code}"`), 'the code is in the tooltip, for the technical record');
  });
}

run();
