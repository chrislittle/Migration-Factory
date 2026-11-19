/* LAB-UX-1: a stopped machine's panel said "Correct that cause, then run this
 * machine again. Once that is done, try it again." - the same instruction
 * twice. The first half was the reason's whatToDo in stop-reasons.json; the
 * second is the page's own line for the reason's retry kind. The page adds
 * the retry, so the reason must not say it too.
 *
 * RUN, not read: the page's own whyStoppedCard, over EVERY reason in the
 * engine's own table - so a reason added later is held to it as well.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const table = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.canApprove = () => true;
globalThis.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
globalThis.retryLines = table.retryLines;
// PANEL-OLD-STOP-1: the box draws only the stop that still describes the
// machine (currentStop), so each case is a machine stopped by it now.
globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
// STOP-HEADLINE-CHECK-1: whyStoppedCard reads the check of a stop with stopCheckSentence.
globalThis.STOP_CHECK = liftConst('migrations.html', 'STOP_CHECK');
const { whyStoppedCard } = liftAll('migrations.html', ['attemptStop', 'currentStop', 'stopCheckSentence', 'whyStoppedCard']);

// An instruction to go again: "try it again", "run this machine again",
// "start this machine again", "try again later".
const RETRY = /\b(try|run|start)\b(?: (?:it|this machine|the machine))? again\b/gi;
const whatToDoLine = (html) => {
  const m = html.match(/<b>[^<]*:<\/b> ([^<]*)<\/p>/);
  return m ? m[1] : '';
};

test('every reason tells a person to go again once at most', () => {
  ok(table.reasons.length > 10, 'the table was read');
  const twice = [];
  for (const r of table.reasons) {
    const doc = { state: 'FAILED_ROLLED_BACK', history: [{ reasonCode: r.code, tsUtc: '2026-09-30T10:00:00Z' }] };
    const line = whatToDoLine(whyStoppedCard(doc));
    ok(line.length > 0, `${r.code}: the what-to-do line was found`);
    const n = (line.match(RETRY) || []).length;
    if (n > 1) { twice.push(`${r.code}: ${line}`); }
  }
  eq(twice, [], 'said twice');
});

test('the reason the lab session saw now reads once', () => {
  const doc = { state: 'FAILED_ROLLED_BACK', history: [{ reasonCode: 'validationFailedAfterConversion', tsUtc: '2026-09-30T10:00:00Z' }] };
  const line = whatToDoLine(whyStoppedCard(doc));
  eq((line.match(RETRY) || []).length, 1, line);
  ok(line.endsWith(table.retryLines.afterFix), `the page supplies the retry: ${line}`);
});

run('stop-card-once');
