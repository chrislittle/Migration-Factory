/* DELETE-STALE-1 and SLOW-DELETE-1: deleting a migration, as the owner met it.
 *
 * DELETE-STALE-1 - "delete a migration gets stuck in a refresh loop & messes
 * up." The run stayed selected in the page's memory, in the address and in
 * the remembered last run, so every refresh asked for it again; and the
 * "nothing to show" card was drawn BESIDE the deleted run's own buttons,
 * still offering to delete it.
 *
 * SLOW-DELETE-1 - "delete a migration took too long. threw this ... it did
 * delete though." The page stopped waiting at 45 seconds and said "Try again
 * in a moment" - advice to press a destructive action a second time, about a
 * delete that had worked.
 *
 * RUN, not read: the page's own discardRun, forgetRun and clearReadingRun.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
// MACHINE-PANEL-STALE-1: clearReadingRun closes the machine panel; machine-panel-stale.test.js runs that.
globalThis.closeDrill = () => { };
const page = liftAll('migrations.html', ['discardRun', 'forgetRun', 'clearReadingRun', 'readingRegions', 'linkedRunId']);
const help = liftAll('help.js', ['runParse', 'runStorePath', 'runFromQuery']);

function world({ listed, apiFails } = {}) {
  const els = {};
  globalThis.$ = (sel) => (els[sel] ??= { innerHTML: `<b>old ${sel}</b>`, children: [] });
  globalThis.UX_ACT = UX_ACT;
  globalThis.UX_MISC = {};
  globalThis.DISCARD_TIMEOUT_MS = Number(PAGE.match(/const DISCARD_TIMEOUT_MS = (\d+);/)[1]);
  globalThis.readingRegions = page.readingRegions;
  globalThis.clearReadingRun = page.clearReadingRun;
  globalThis.forgetRun = page.forgetRun;
  globalThis.currentRun = 'proj/migration-1';
  globalThis.showingRun = 'proj/migration-1';
  globalThis.pendingRuns = new Set(['proj/migration-1']);
  const store = { 'vmf-last-run': 'proj/migration-1' };
  globalThis.localStorage = { getItem: k => store[k] ?? null, removeItem: k => { delete store[k]; } };
  globalThis.location = { href: 'http://x/migrations.html?run=migration-1&project=proj' };
  let replaced = null;
  globalThis.history = { replaceState: (_, __, u) => { replaced = String(u); } };
  globalThis.VmfHelp = { VmfRun: { parse: help.runParse, storePath: help.runStorePath, fromQuery: help.runFromQuery } };
  globalThis.linkedRunId = page.linkedRunId;
  globalThis.runSeg = () => 'migration-1';
  const calls = [];
  globalThis.apiFetch = async (p, body, opts) => {
    calls.push({ p, body, opts });
    if (apiFails === 'timeout') { const e = new Error(UX_ACT.slowService); e.timedOut = true; throw e; }
    if (apiFails === 'refused') { throw new Error('403: not allowed'); }
    return {};
  };
  globalThis.source = { listRuns: async () => listed ?? [] };
  return { els, store, calls, replaced: () => replaced };
}

test('RUN: a delete that works leaves the page with no trace of the run', async () => {
  const w = world();
  const said = await page.discardRun('proj/migration-1', { note: 'n', copies: 'keep' });
  eq(said, UX_ACT.discardDone, 'it says it is deleted');
  eq(globalThis.currentRun, null, 'the run is no longer selected');
  ok(!globalThis.pendingRuns.has('proj/migration-1'), 'nor kept visible as pending');
  eq(w.store['vmf-last-run'], undefined, 'nor remembered as the last run');
  ok(!/run=/.test(w.replaced()), 'nor in the address, which the next load would reselect');
  for (const sel of ['#run-actions', '#nextstep', '#found', '#kpis']) {
    eq(w.els[sel].innerHTML, '', `${sel} is cleared, not left beside the empty card`);
  }
  eq(globalThis.showingRun, null, 'and the page no longer claims to show it');
});

test('RUN: a delete gets longer than an ordinary action', async () => {
  const w = world();
  await page.discardRun('proj/migration-1', { note: 'n', copies: 'delete' });
  ok(w.calls[0].opts && w.calls[0].opts.timeoutMs >= 120000, `a delete may take minutes, got ${w.calls[0].opts && w.calls[0].opts.timeoutMs}`);
  eq(w.calls[0].body.deleteSafetyCopies, true, 'and the copies choice still travels');
});

test('RUN: a delete that timed out but WORKED says it is deleted - it does not say try again', async () => {
  world({ apiFails: 'timeout', listed: ['proj/migration-2'] });
  const said = await page.discardRun('proj/migration-1', { note: 'n', copies: 'keep' });
  eq(said, UX_ACT.discardDone, 'the list proves it is gone');
  eq(globalThis.currentRun, null);
});

test('RUN: a delete that timed out and is still listed says so, and does not claim either outcome', async () => {
  world({ apiFails: 'timeout', listed: ['proj/migration-1'] });
  let thrown = null;
  try { await page.discardRun('proj/migration-1', { note: 'n', copies: 'keep' }); } catch (e) { thrown = e; }
  ok(thrown && thrown.message === UX_ACT.discardUnknown, 'it says the delete can still be in progress');
  eq(globalThis.currentRun, 'proj/migration-1', 'and does not forget a run that may still be there');
});

test('RUN: a refusal is a refusal, and nothing is forgotten', async () => {
  world({ apiFails: 'refused' });
  let thrown = null;
  try { await page.discardRun('proj/migration-1', { note: 'n', copies: 'keep' }); } catch (e) { thrown = e; }
  ok(thrown && /403/.test(thrown.message), 'the service answer is passed on');
  eq(globalThis.currentRun, 'proj/migration-1', 'the run is still selected');
});

test('no message on this page tells a person to "try again" after a timeout', () => {
  ok(!/Try again in a moment/.test(UX_ACT.slowService), 'the page does not know the action failed');
  const fetchFn = PAGE.slice(PAGE.indexOf('async function apiFetch('), PAGE.indexOf('// The scopes list is stable'));
  ok(fetchFn.length > 200, 'found apiFetch');
  ok(/err\.timedOut = e\.name === 'AbortError';/.test(fetchFn), 'a timeout is marked as one');
});

run('delete-stale');
