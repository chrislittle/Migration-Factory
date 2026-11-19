/* ROLLBACK-SIZE-REFUSED-SERIES-1 (decided 2026-11-14): Azure refused
 * a machine's original size during its rollback, so the machine is stopped on
 * its new size (rollbackSizeRefused). The way forward is another series, from
 * the first safety copy:
 *   1. Change to v5 is offered beside the machine (the engine takes this stop
 *      too, Set-VmfMachineTarget -AfterRollback), and its done message names
 *      the next step, the restore;
 *   2. Restore this machine from the copy Before the migration puts the
 *      machine on the v5 size of the plan - and the dialog says that size,
 *      by the rule the engine uses (restoreOntoTarget, held to
 *      tests/fixtures/restore-onto-target.json with Get-VmfRestoreOntoTarget).
 *
 * RUN, not read: the page's own restoreOntoTarget, askRestore and
 * askRetrySeries.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const rule = liftAll('migrations.html', ['lastStopEntry', 'sizeRefusedStop', 'restoreOntoTarget']);
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'restore-onto-target.json'), 'utf8')).cases;

test('the fixture loaded', () => { ok(CASES.length >= 8, `${CASES.length} cases`); });

test('RUN: every shared case gives the answer the engine gives', () => {
  for (const c of CASES) {
    const got = rule.restoreOntoTarget(c.doc, c.entry, c.from || 'pristine');
    if (c.onto === null) { eq(got, null, c.why); continue; }
    ok(got, c.why);
    eq(got.size, c.onto.size, `${c.why}: the size`);
    eq(got.option, c.onto.option, `${c.why}: the series`);
    eq(got.originalSize, c.onto.originalSize, `${c.why}: the original size`);
    eq(got.refused, !!c.onto.refused, `${c.why}: refused`);
  }
});

test('the last stop reads back past the entry of a retry', () => {
  const doc = { history: [
    { tsUtc: '2026-11-14T10:00:00Z', state: 'FAILED_NEEDS_ATTENTION', reasonCode: 'rollbackSizeRefused' },
    { tsUtc: '2026-11-14T10:05:00Z', state: 'PRECHECK', outcome: 'ok' }] };
  eq(rule.lastStopEntry(doc).reasonCode, 'rollbackSizeRefused');
  eq(rule.lastStopEntry({ history: [] }), null);
});

// The restore dialog: the page's own askRestore and the helpers it calls.
const r = liftAll('migrations.html', ['restoreCopyField', 'restoreDiskNames', 'restoreKeepInstantNote', 'putBackRetireNote', 'askRestore',
  'restoreExceptions', 'restoreShapes', 'shapeWords', 'restoreSiteRecoveryWords']);
globalThis.UX_ACT = UX_ACT;
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.noteField = () => ({ id: 'note', label: 'Why?' });
globalThis.runSeg = () => 'migration-1';
const DOC = CASES[0].doc;
const withCopies = Object.assign({}, DOC, { safety: { pristineSnapshotId: '/snapshots/p1', snapshotId: '/snapshots/s1' } });
function openRestore(doc, onto) {
  let captured = null;
  globalThis.openModal = (opts) => { captured = opts; };
  r.askRestore('/subscriptions/s/rg/a/vm1', doc, onto);
  return captured;
}

test('THE CASE: the restore dialog names the size the first copy goes onto, and that later rollbacks return there', () => {
  const onto = rule.restoreOntoTarget(DOC, CASES[0].entry);
  const opts = openRestore(withCopies, onto);
  ok(opts, 'the dialog opened');
  const words = UX_ACT.restoreOntoTarget.replace('{original}', 'D2s_v4').replace(/\{size\}/g, 'D2s_v5').replace('{series}', 'v5');
  ok(opts.desc.includes(words), `the dialog says: ${opts.desc}`);
  ok(/Every later rollback and restore returns the machine to D2s_v5\./.test(opts.desc), 'what a later rollback does');
});

test('no words for a restore that goes to the original size, or one the service refuses', () => {
  ok(!openRestore(withCopies, null).desc.includes('Azure refused the original size'), 'no onto');
  ok(!openRestore(withCopies, Object.assign(rule.restoreOntoTarget(DOC, CASES[0].entry), { refused: true })).desc.includes('Azure refused the original size'), 'refused: the service says why');
  const prepOnly = Object.assign({}, DOC, { safety: { snapshotId: '/snapshots/s1' } });
  ok(!openRestore(prepOnly, rule.restoreOntoTarget(DOC, CASES[0].entry)).desc.includes('Azure refused the original size'), 'the other copy keeps its size');
});

test('the panel asks the rule for the restore and for the next step of Change to v5', () => {
  ok(PAGE.includes("askRestore(vmId, doc, restoreOntoTarget(doc, entry))"), 'the restore button passes the size');
  ok(PAGE.includes('keep, !!sizeRefusedStop(doc));'), 'the series buttons know the restore comes next');
  ok(PAGE.includes("(doc.state === 'FAILED_NEEDS_ATTENTION' && lastStopEntry(doc)?.reasonCode === 'rollbackSizeRefused' && canOperate()))"), 'Change to v5 beside this stop');
});

test('RUN: Change to v5 after the size was refused says to restore next', () => {
  globalThis.retrySeriesCache = null;
  globalThis.modalMachine = null;
  const page = liftAll('migrations.html', ['retrySeriesOptions', 'askRetrySeries']);
  const answer = { PlanVersion: 'ver-1', Options: [{ option: 'v5', current: false, supported: true, targetSize: 'Standard_D2s_v5' }] };
  let modal = null;
  globalThis.openModal = (m) => { modal = m; };
  page.askRetrySeries('/vm1', answer, 'v5', true);
  eq(modal.doneMessage, UX_ACT.retrySeriesDoneRestore);
  ok(/Restore this machine/.test(UX_ACT.retrySeriesDoneRestore) && /Before the migration/.test(UX_ACT.retrySeriesDoneRestore), UX_ACT.retrySeriesDoneRestore);
  page.askRetrySeries('/vm1', answer, 'v5');
  eq(modal.doneMessage, UX_ACT.retrySeriesDone, 'a machine that rolled back: the retry comes next');
});

run('rollback-other-series');
