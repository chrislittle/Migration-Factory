/* MIGRATIONS-DECISION-WORDS-1: the decision line of the Activity list names
 * the button the operator selected.
 *
 * In the final lab (2026-11-13) an operator selected Try this machine again,
 * and the Activity list said only "An operator made the pending decision".
 * Resolve-VmfDecision now writes the choice on its ok line (choice = retry
 * with no setting change, accept with one; DecideApprovalStale.Tests.ps1), and
 * the page names the button. The words were approved on 2026-11-14.
 *
 * RUN, not read: the page's own stepText, words and step map.
 */
'use strict';
const { liftAll, liftConst, test, eq, run } = require('./_harness');

globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
const { stepText } = liftAll('migrations.html', ['stepText']);

const DETAIL = 'resolved by operator@example.com: fixed the boot setting';

test('the approved words, exactly', () => {
  eq(UX_STEP.decisionRetry, 'An operator selected Try this machine again.');
  eq(UX_STEP.decisionAccept, 'An operator selected Accept this and continue.');
  eq(UX_STEP.decisionMade, 'An operator made the pending decision', 'the fallback stays');
});

test('Try this machine again names its button', () => {
  eq(stepText({ step: 'decision', outcome: 'ok', detail: DETAIL, choice: 'retry', approvalsCleared: [] }), UX_STEP.decisionRetry);
});

test('Accept this and continue names its button', () => {
  eq(stepText({ step: 'decision', outcome: 'ok', detail: DETAIL, choice: 'accept', approvalsCleared: [] }), UX_STEP.decisionAccept);
});

test('a decision line with no choice keeps the fallback', () => {
  eq(stepText({ step: 'decision', outcome: 'ok', detail: DETAIL }), UX_STEP.decisionMade);
  eq(stepText({ step: 'decision', outcome: 'ok', detail: DETAIL, choice: 'something else' }), UX_STEP.decisionMade, 'an unknown choice');
});

test('a carry line of the decision keeps the fallback', () => {
  eq(stepText({ step: 'decision', outcome: 'info', detail: 'carried', choice: 'accept' }), UX_STEP.decisionMade, 'only the ok line names a button');
});

test('DECIDE-APPROVAL-STALE-1 still wins: a decision that removed approvals shows its own sentence', () => {
  const detail = 'Decision resolved by operator@example.com: fixed. The approval of wave w2 signed the plan before this change. Approve the wave again.';
  eq(stepText({ step: 'decision', outcome: 'ok', detail, choice: 'accept', approvalsCleared: ['w2'] }), detail);
});

test('a refused decision still shows its refusal', () => {
  eq(stepText({ step: 'decision', outcome: 'refused', detail: 'Wave w1 cannot start now.', choice: 'accept' }), 'Wave w1 cannot start now.');
});

run('migrations-decision-words');
