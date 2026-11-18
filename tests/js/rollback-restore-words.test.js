/* REVIEW-1: the two words say who did it.
 *
 * TERM-ROLLBACK-1 split the old "put back" into two things the product does:
 *   - a ROLLBACK is the engine's own return to the source size and controller
 *     after a failure (FAILED_ROLLED_BACK, machineState 'restored');
 *   - a RESTORE is a person replacing the disk from a safety copy.
 * Its review found the stop card telling an operator "A person restored this
 * machine" after every AUTOMATIC rollback, and the recovery step inside a
 * person's restore calling itself a rollback. These pin both the right way
 * round.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftConst, test, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const UX_STEP = liftConst('migrations.html', 'UX_STEP');
const src = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));

test('the stop card after an automatic rollback says the product rolled it back', () => {
  ok(/restored:\s*UX_ACT\.whyPutBack/.test(src), "machineState 'restored' is shown with whyPutBack");
  ok(/rolled/i.test(UX_ACT.whyPutBack), UX_ACT.whyPutBack);
  ok(!/person/i.test(UX_ACT.whyPutBack), 'no person did it: ' + UX_ACT.whyPutBack);
});

test('the recovery step inside a person\'s restore says restore, not rollback', () => {
  ok(/restore/i.test(UX_STEP.recoverStart), UX_STEP.recoverStart);
  ok(!/roll/i.test(UX_STEP.recoverStart), UX_STEP.recoverStart);
});

test('the person\'s control and its results say restore', () => {
  for (const k of ['restore', 'restoreTitle', 'wasRestored', 'wasRestoredTip', 'restoredFrom']) {
    ok(/restor/i.test(UX_ACT[k]) && !/roll/i.test(UX_ACT[k]), `${k}: ${UX_ACT[k]}`);
  }
});

run('rollback-restore-words');
