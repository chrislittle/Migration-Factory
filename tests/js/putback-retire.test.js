/* RETIRE-SCOPE-1 (reversing part of V3-RETIRE-1): the restore dialog says
 * (REBUILD-REMOVE-RECOVER-1: Rebuild this machine is gone) when Microsoft retires the size a machine had. Within the 12
 * months before the margin they warn; from one day before the date a return to
 * that size is outside the scope of this tool, and they say the product refuses
 * it. No other size is named any more, and the wave's acceptance no longer
 * lists rollback sizes. PRECHECK records captured.putBackRetirement (size,
 * retiresUtc, warnFromUtc); a record V3-RETIRE-1 wrote may also carry
 * currentSize, which the page ignores.
 *
 * RUN: the page's own functions, lifted out of migrations.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const note = lift('migrations.html', 'putBackRetireNote');

const doc = (r) => ({ captured: { vmConfig: { size: 'Standard_D4s_v3' }, putBackRetirement: r } });
const v3 = { size: 'Standard_D4s_v3', retiresUtc: '2029-11-15', warnFromUtc: '2028-11-15' };
const say = (t) => t.replace('{size}', 'D4s_v3').replace('{date}', '2029-11-15');

test('more than 12 months before the date: nothing is said', () => {
  eq(note(doc(v3), '2026-10-03T10:00:00Z'), '');
  eq(note(doc(v3), '2028-11-14T23:59:59Z'), '');
});

test('within the 12 months: the size and the date, and that the product refuses a return from the day before', () => {
  const t = note(doc(v3), '2028-11-15T00:00:00Z');
  eq(t, say(UX_ACT.retireWarn));
  ok(t.includes('D4s_v3') && t.includes('2029-11-15') && !t.includes('Standard_'), t);
  eq(note(doc(v3), '2029-11-13T23:59:59Z'), say(UX_ACT.retireWarn), 'two days before: still a warning');
});

test('from one day before the date: outside the scope of this tool, as the engine and the service refuse it', () => {
  eq(note(doc(v3), '2029-11-14T00:00:00Z'), say(UX_ACT.retireRefused), 'the day before');
  eq(note(doc(v3), '2031-01-01'), say(UX_ACT.retireRefused));
  ok(UX_ACT.retireRefused.includes('outside the scope of this tool'), UX_ACT.retireRefused);
});

test('no size is named but the one the machine had - a record that carries a current size is ignored', () => {
  const old = Object.assign({}, v3, { currentSize: 'Standard_D4ds_v5', rollbackSize: 'Standard_D4ds_v5' });
  for (const day of ['2029-06-01', '2031-01-01']) {
    const t = note(doc(old), day);
    ok(t && !t.includes('D4ds_v5'), t);
  }
  for (const k of ['retireWarn', 'retireRefused']) { ok(!UX_ACT[k].includes('{current}'), k); }
  for (const gone of ['retireReplaced', 'retireNoCurrent', 'retireWarnNoCurrent']) { eq(UX_ACT[gone], undefined, gone); }
});

test('a machine with no record - no retirement, or started before the record existed - says nothing', () => {
  eq(note(doc(undefined), '2031-01-01'), '');
  eq(note({}, '2031-01-01'), '');
  eq(note(null, '2031-01-01'), '');
});

test('the wave acceptance no longer lists rollback sizes', () => {
  const lever = liftConst('migrations.html', 'UX_LEVER');
  eq(lever.rollbackSizeMachines, undefined);
  ok(!PAGE.includes('rollbackSizeNames'), 'the list is gone from the page');
});

test('the restore says it only where the first copy can be chosen', () => {
  const restore = PAGE.slice(PAGE.indexOf('function askRestore('), PAGE.indexOf('function askRestore(') + 2500);
  // PREP-ROLLBACK-1: also with the first copy alone, which goes back to the size it had.
  // RESTORE-DIALOG-WORDS-1: the copies are the options the dialog offers;
  // tests/js/restore-dialog-words runs the dialog with and without the first copy.
  ok(/const retire = copies\.includes\('pristine'\) \? putBackRetireNote\(doc\) : '';/.test(restore), 'the other copy keeps the size the machine has now');
  // Then the Site Recovery line (REBUILD-ACCEPT-1).
  // ROLLBACK-SIZE-REFUSED-SERIES-1: after the size the first copy goes onto.
  ok(/desc: \[UX_ACT\.restoreDesc, ontoWords, \.\.\.restoreExceptions\(doc\), retire, \.\.\.restoreSiteRecoveryWords\(doc\)\]\.filter\(Boolean\)\.join\(' '\)/.test(restore), 'and it is shown in the dialog');
  ok(!PAGE.includes('askRebuild'), 'Rebuild this machine is gone');
});

test('the engine writes these under putBack, and the feed shows its own words - never the failed restore of the restore step', () => {
  global.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
  global.UX_STEP = liftConst('migrations.html', 'UX_STEP');
  global.UX_STATE = liftConst('migrations.html', 'UX_STATE');
  global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
  global.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
  const { stepText } = liftAll('migrations.html', ['stepText']);
  const words = 'Nothing changed for vm1, because Microsoft retires Standard_D4s_v3 on 2029-11-15.';
  eq(stepText({ step: 'putBack', outcome: 'fail', detail: words }), words);
  eq(stepText({ step: 'putBack', outcome: 'warn', detail: words }), words);
  for (const f of ['Restore-VmfVm.ps1']) {
    const src = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Public', f), 'utf8');
    ok(src.includes("-Step 'putBack' -Outcome fail") && src.includes("-Step 'putBack' -Outcome warn"), `${f} writes under putBack`);
  }
  eq(UX_STEP.readCurrentSizes, undefined, 'no size catalog is read for a restore any more');
});

test('a rolled-back row shows the size the machine had - rollback.sizeAfter is gone (vm-state v47, OLD-VERSION-READERS-REMOVE-4)', () => {
  ok(!/rollback\?\.sizeAfter|rollback\.sizeAfter/.test(PAGE), 'the page reads no rollback.sizeAfter');
  ok(PAGE.includes('const liveSize = putBack || (arrived ? planTo : planFrom);'));
});

run('putback-retire');
