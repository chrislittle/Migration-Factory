/* DECIDE-2: which controls a stopped machine offers.
 *
 * Two separate questions, which DECIDE-1 ran together:
 *
 *   a CHOICE - a loss a person may accept for THIS machine. All three of the
 *     wave's "stop and ask" gates carry one, and all three belong to the
 *     approver.
 *   a RETRY  - running the machine again, which helps only if something can
 *     be corrected.
 *
 * The identity stop has a choice and no correction. The other two have both,
 * and for them the correction is usually the better answer - so the retry
 * must NOT be withdrawn when the choice appears beside it.
 *
 * This rule lived inline in openDrill where nothing could reach it, and its
 * tests matched the page's source. Source tells you what you meant.
 */
'use strict';
const { lift, test, eq, run } = require('./_harness');

const stopControls = lift('migrations.html', 'stopControls');

const IDENTITY = { retry: 'decision', decide: { lever: 'onSystemAssignedIdentity', accept: 'proceed' } };
const TEMPDISK = { retry: 'afterFix', decide: { lever: 'onDDataFound', accept: 'proceed' } };
const DRIVER   = { retry: 'afterFix', decide: { lever: 'onDriverBelowFloor', accept: 'proceed' } };
const LOCKED   = { retry: 'afterFix' };                 // a plain fault, no choice
const CAPACITY = { retry: 'whenAvailable' };
const NEVER    = { retry: 'notSupported' };
const SCOPE    = { retry: 'outOfScope' };   // RETIRE-SCOPE-1: a retired size

const OPER = [true, false];   // canOperate, canApprove
const APPR = [true, true];
const APPR_ONLY = [false, true];   // DECIDE-ROLE-1: the approver role alone

test('the identity stop offers the CHOICE and withholds the retry', () => {
  // The whole defect: "Try this machine again" re-ran the same check against
  // the same setting and parked the machine again, for ever.
  eq(stopControls('NEEDS_DECISION', IDENTITY, ...APPR), { decide: true, retry: false });
});

test('and offers an operator neither, because the facade would refuse them', () => {
  eq(stopControls('NEEDS_DECISION', IDENTITY, ...OPER), { decide: false, retry: false });
});

test('DECIDE-ROLE-1: the approver role ALONE is offered the choice, and not the retry', () => {
  // The service accepts the decision from the approver alone and keeps the
  // retry for the operator, so the page offers exactly that - every principal
  // above held both roles, so this case never ran.
  eq(stopControls('NEEDS_DECISION', IDENTITY, ...APPR_ONLY), { decide: true, retry: false });
  eq(stopControls('NEEDS_DECISION', TEMPDISK, ...APPR_ONLY), { decide: true, retry: false });
  eq(stopControls('NEEDS_DECISION', DRIVER, ...APPR_ONLY), { decide: true, retry: false });
  // and never on a machine that does not wait for a decision: the service
  // refuses the approver alone there.
  eq(stopControls('FAILED_ROLLED_BACK', TEMPDISK, ...APPR_ONLY), { decide: false, retry: false });
});

test('the other two gates offer BOTH to an approver', () => {
  // DECIDE-2. Treating these like the identity stop would withdraw a retry
  // that genuinely works - move the files, patch the kernel, run it again and
  // nothing is lost at all.
  eq(stopControls('NEEDS_DECISION', TEMPDISK, ...APPR), { decide: true, retry: true });
  eq(stopControls('NEEDS_DECISION', DRIVER, ...APPR), { decide: true, retry: true });
});

test('and an operator still gets the RETRY on them, which is the better answer', () => {
  eq(stopControls('NEEDS_DECISION', TEMPDISK, ...OPER), { decide: false, retry: true });
  eq(stopControls('NEEDS_DECISION', DRIVER, ...OPER), { decide: false, retry: true });
});

test('a plain fault is unchanged: retry only, for an operator', () => {
  eq(stopControls('NEEDS_DECISION', LOCKED, ...OPER), { decide: false, retry: true });
  eq(stopControls('FAILED_ROLLED_BACK', LOCKED, ...OPER), { decide: false, retry: true });
  eq(stopControls('NEEDS_DECISION', CAPACITY, ...OPER), { decide: false, retry: true });
});

test('and a machine this engine cannot migrate gets no retry, as before', () => {
  eq(stopControls('NEEDS_DECISION', NEVER, ...APPR), { decide: false, retry: false });
  // RETIRE-SCOPE-1: a machine outside the scope of this tool is not offered a retry either.
  eq(stopControls('NEEDS_DECISION', SCOPE, ...APPR), { decide: false, retry: false });
  eq(stopControls('FAILED_ROLLED_BACK', SCOPE, ...OPER), { decide: false, retry: false });
});

test('the choice is offered only where the machine is PARKED', () => {
  // A machine that failed after conversion is a different situation: it was
  // changed and put back. The choice belongs to the gate before anything was
  // touched, not to a failure afterwards.
  eq(stopControls('FAILED_ROLLED_BACK', IDENTITY, ...APPR), { decide: false, retry: false });
  eq(stopControls('MIGRATED', IDENTITY, ...APPR), { decide: false, retry: false });
});

test('an unknown reason code offers the retry and no choice', () => {
  // Unknown stays unknown - the page must not invent a decision for a code it
  // cannot resolve, and must not go silent either.
  eq(stopControls('NEEDS_DECISION', undefined, ...OPER), { decide: false, retry: true });
  eq(stopControls('NEEDS_DECISION', null, ...APPR), { decide: false, retry: true });
});

run();
