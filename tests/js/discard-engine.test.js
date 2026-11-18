/* DISCARD-ENGINE-1 (GitHub issue 427): deleting a migration with its safety
 * copies runs in the engine, so the page has to show a delete that is still
 * happening, and one that did not work.
 *
 * Before, the service tried to delete the copies itself and failed with
 * "Remove-AzResourceLock is not recognized". Now the service starts the
 * engine and answers at once with `queued`. The migration stays until the
 * engine has deleted every copy; a copy it cannot delete keeps the migration,
 * and the page says why.
 *
 * RUN, not read: the page's own discardRun, discardIndex, renderRunActions and
 * engineOperationName.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_ACT = UX_ACT;
globalThis.DISCARD_IDLE_MS = Number(PAGE.match(/const DISCARD_IDLE_MS = (\d+);/)[1]);
globalThis.DISCARD_TIMEOUT_MS = Number(PAGE.match(/const DISCARD_TIMEOUT_MS = (\d+);/)[1]);
const { discardIndex } = liftAll('migrations.html', ['discardIndex']);
const discardRun = lift('migrations.html', 'discardRun');
const renderRunActions = lift('migrations.html', 'renderRunActions');
const engineOperationName = lift('migrations.html', 'engineOperationName');
const lastEngineFailure = lift('migrations.html', 'lastEngineFailure');
// RESTORE-MID-MOVE-1: restoreOffered asks restoreCopiesThere and help.js's
// machineAtWork; these docs have no state, so no move is at work.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['machineHold', 'machineAtWork']));
const { restoreOffered } = liftAll('migrations.html', ['restoreCopiesThere', 'restoreOffered']);

const NOW = Date.parse('2026-10-02T12:00:00Z');
const at = (min) => new Date(NOW - min * 60000).toISOString();

/* ---- what the service answers ------------------------------------------ */

function world(answer) {
  const forgotten = [];
  globalThis.forgetRun = (id) => forgotten.push(id);
  globalThis.runSeg = () => 'migration-1';
  globalThis.source = { listRuns: async () => ['proj/migration-1'] };
  globalThis.apiFetch = async () => answer;
  return { forgotten };
}

test('RUN: the engine was started - the page says so, and keeps the migration', async () => {
  const w = world({ queued: true, operation: 'discard', execution: 'vmf-engine-1', safetyCopies: 3 });
  const said = await discardRun('proj/migration-1', { note: 'n', copies: 'delete' });
  eq(said, UX_ACT.discardQueued, 'it says the engine is deleting the copies');
  eq(w.forgotten.length, 0, 'the migration is still there until every copy is gone');
});

test('RUN: a delete done at once is still forgotten at once', async () => {
  const w = world({ Removed: true });
  const said = await discardRun('proj/migration-1', { note: 'n', copies: 'keep' });
  eq(said, UX_ACT.discardDone);
  eq(w.forgotten.length, 1);
});

/* ---- the delete the engine is doing now -------------------------------- */

test('RUN: a delete the service started is in progress', () => {
  const r = discardIndex([{ step: 'engine', outcome: 'start', tsUtc: at(3) },
                          { step: 'discard', outcome: 'start', tsUtc: at(2) },
                          { step: 'azureops:removeSnapshot', outcome: 'ok', tsUtc: at(1) }], NOW);
  ok(r, 'it is in progress');
  eq(r.since, at(2), 'since the service started it');
});

test('RUN: a copy that was not deleted ends it, and so does the engine failure', () => {
  eq(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(5) },
                   { step: 'discard', outcome: 'fail', tsUtc: at(4), detail: 'The safety copy s1 was not deleted.' }], NOW), null);
  eq(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(5) },
                   { step: 'engine:discard', outcome: 'fail', tsUtc: at(4), detail: '1 of 3 safety copies were not deleted' }], NOW), null);
});

test('RUN: a second try after a failure is in progress again', () => {
  const r = discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(30) },
                          { step: 'engine:discard', outcome: 'fail', tsUtc: at(29) },
                          { step: 'discard', outcome: 'start', tsUtc: at(1) }], NOW);
  ok(r && r.since === at(1), 'the newest start counts');
});

test('RUN: a delete is shown while its job is working, however long it takes', () => {
  // Review 2 note a: a fixed hour was shorter than a big delete. The engine
  // writes a line for every Azure call it makes, so a delete three hours in
  // with a line a minute ago is still running.
  ok(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(180) },
                   { step: 'azureops:removeSnapshot', outcome: 'ok', tsUtc: at(1) }], NOW), 'still working');
});

test('RUN: a job that stopped with no word does not hold the page for ever', () => {
  // No line from the job for longer than any step takes: the job is gone.
  // The service still refuses a second delete while Azure lists one.
  const idle = DISCARD_IDLE_MS / 60000;
  eq(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(idle + 1) }], NOW), null);
  eq(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(180) },
                   { step: 'azureops:removeSnapshot', outcome: 'ok', tsUtc: at(idle + 1) }], NOW), null);
  ok(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(idle - 1) }], NOW), 'a job still starting');
});

test('RUN: review 2 item 1 - a copy that was not deleted does not end the delete', () => {
  ok(discardIndex([{ step: 'discard', outcome: 'start', tsUtc: at(5) },
                   { step: 'discardCopy', outcome: 'fail', tsUtc: at(4), detail: 'The safety copy s1 was not deleted.' }], NOW),
     'the engine goes on with the other copies');
});

test('RUN: nothing started means nothing in progress', () => {
  eq(discardIndex([], NOW), null);
  eq(discardIndex(null, NOW), null);
  eq(discardIndex([{ step: 'run', outcome: 'ok', tsUtc: at(1) }], NOW), null);
});

/* ---- the run row -------------------------------------------------------- */

function draw(inFlight, working = false) {
  const host = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#run-actions' ? host : { addEventListener: () => {} });
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.ago = () => '2 minutes ago';
  globalThis.currentRun = 'proj/migration-1';
  globalThis.canOperate = () => true;
  globalThis.canApprove = () => false;
  globalThis.runAcknowledged = () => true;
  globalThis.runIsWorking = () => working;
  globalThis.discardInFlight = inFlight;
  for (const f of ['askReport', 'askAcknowledge', 'askStopRun', 'askDiscardRun']) { globalThis[f] = () => {}; }
  renderRunActions();
  return host.innerHTML;
}

test('DRAWN: while the engine deletes it, the row says so in place of the delete', () => {
  const html = draw({ since: at(2) });
  ok(!html.includes(UX_ACT.discardRun), 'no second delete to press');
  ok(html.includes(UX_ACT.discardWorking.replace('{ago}', '2 minutes ago')), 'it says the engine is deleting it');
});

test('DRAWN: after a failure the delete is offered again', () => {
  const html = draw(null);
  ok(html.includes(UX_ACT.discardRun), 'the person can try again');
});

test('N6: the words while it runs are whole sentences', () => {
  const said = UX_ACT.discardWorking.replace('{ago}', '2 minutes ago');
  ok(/\.\s+The delete started 2 minutes ago\.$/.test(said), said);
});

test('DRAWN: a run still working keeps its Stop beside the delete in progress', () => {
  const html = draw({ since: at(2) }, true);
  ok(html.includes(UX_ACT.stopRun), 'Stop is still there');
  ok(!html.includes(UX_ACT.discardRun), 'and still no second delete');
});

test('N6: a new delete clears the banner of the delete that failed before it', () => {
  const failed = { step: 'engine:discard', outcome: 'fail', tsUtc: at(30), detail: '1 of 3 safety copies were not deleted: s1.' };
  ok(lastEngineFailure([failed]), 'the failure shows');
  eq(lastEngineFailure([failed, { step: 'discard', outcome: 'start', tsUtc: at(1) }]), null, 'the new delete clears it');
  const again = { step: 'engine:discard', outcome: 'fail', tsUtc: at(0), detail: 'again' };
  eq(lastEngineFailure([failed, { step: 'discard', outcome: 'start', tsUtc: at(1) }, again]).detail, 'again', 'and a new failure shows');
});

test('review 2 item 4: Restore is not offered from copies that were deleted', () => {
  const safety = { pristineSnapshotId: '/snap/p', snapshotId: '/snap/q' };
  ok(restoreOffered({ safety }, true), 'copies there, operator');
  ok(!restoreOffered({ safety }, false), 'not for somebody who cannot operate');
  ok(!restoreOffered({ safety, retention: { deletedUtc: at(1) } }, true), 'not from copies that are gone');
  ok(!restoreOffered({ safety: { pristineSnapshotId: '/snap/p', snapshotId: null } }, true), 'not before the copy step, when nothing changed the machine');
  // PREP-ROLLBACK-1: a stop before the second copy that left the machine
  // changed - its rollback could not finish - is restored from the first copy.
  const changed = { safety: { pristineSnapshotId: '/snap/p', snapshotId: null }, history: [{ state: 'FAILED_NEEDS_ATTENTION', machineState: 'changed' }] };
  ok(restoreOffered(changed, true), 'the first copy, when the last stop left the machine changed');
  ok(!restoreOffered({ ...changed, history: [{ machineState: 'changed' }, { machineState: 'restored' }] }, true), 'not when a later stop put it back');
  ok(!restoreOffered({ ...changed, retention: { deletedUtc: at(1) } }, true), 'not from a first copy that is gone');
  ok(!restoreOffered({ safety: { snapshotId: null }, history: changed.history }, true), 'not with no copy at all');
});

test('the failure banner names the delete, not "the last action"', () => {
  eq(engineOperationName('engine:discard'), UX_ACT.nextFailedDiscard);
});

run('discard-engine');
