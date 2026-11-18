/* RUN-404-1, 2026-09-21. Found in a network log: many 404 answers, still, on
 * many pages.
 *
 * 145 of 1856 requests came back 404, and every one was the same endpoint.
 * About a hundred were this page asking for run-status.json for runs that had
 * been PLANNED AND NEVER STARTED - fourteen to twenty-one times each.
 *
 * A 404 is the correct answer to "is this here yet". THE DEFECT IS THAT THE
 * PRODUCT CANNOT TELL A NORMAL ABSENCE FROM A REAL ONE, and neither can a
 * person reading the log - which is exactly how this was found. Cutting the
 * routine ones is what makes a real one mean something.
 *
 * PAGE-LOAD-1, rewritten on purpose. The Overview used to ask the service
 * which runs had started (GET /runs) and skipped the status of a run at
 * setup. That call is gone: the listing that comes with the page's one call
 * (VmfHelp.storeDocs) already says whether run-status.json is there. The rule
 * is the same - a run with no status document is not asked for one - and it
 * now holds for every run with no status, at setup or not.
 *
 * UNKNOWN MEANS ASK. When the page holds no listing that can say, it asks, so
 * it can never show less because a call failed.
 */
'use strict';
const { liftAll, test, eq, run } = require('./_harness');

const H = liftAll('help.js', ['heldDepth', 'heldList', 'heldText', 'heldJson', 'heldHas', 'runKind']);
const page = liftAll('index.html', ['blobJson', 'readRun', 'migrationFacts']);

const status = { schemaVersion: 4, runId: 'live', updatedUtc: '2026-11-06T00:00:00Z', stateCounts: { CONVERTING: 1 }, running: ['vm1'] };
/* What the page holds after its one call: a run at setup (no status) and a
 * running one, inside a project. */
const heldStore = (opts) => ({
  prefix: '', depth: 3, truncated: !!(opts && opts.truncated), complete: true,
  names: new Set(['proj/scan-only/run.json', 'proj/live/run.json', 'proj/live/run-status.json']),
  folders: ['proj', 'proj/live', 'proj/scan-only'],
  docs: new Map([
    ['proj/scan-only/run.json', { path: 'proj/scan-only/run.json', text: '{"kind":"migration"}' }],
    ['proj/live/run.json', { path: 'proj/live/run.json', text: '{"kind":"migration"}' }],
    ['proj/live/run-status.json', { path: 'proj/live/run-status.json', text: JSON.stringify(status) }],
  ]),
});

function pageWith(held) {
  const asked = [];
  globalThis.held = held;
  globalThis.cfg = { apiUrl: 'https://service.example.com/api' };
  globalThis.getToken = async () => 'token';
  globalThis.storeRead = (fn) => fn();
  globalThis.VmfHelp = {
    ...H,
    storeBlob: async (t, u, p) => { asked.push(p); return p.endsWith('run-status.json') ? status : null; },
    runSummaryOf: () => null, runWaitingCount: () => 0, runGateTag: () => '', runGroup: () => 'In progress',
  };
  return asked;
}

test('a run with no status document is not asked for one - the listing says it is not there', async () => {
  const asked = pageWith(heldStore());
  const row = await page.readRun('proj/scan-only', { kind: 'migration' }, 'proj');
  eq(asked, [], 'calls to the service');
  eq(row.status, null, 'no status');
});

test('a running one is read, from what the page holds, with no call', async () => {
  const asked = pageWith(heldStore());
  const row = await page.readRun('proj/live', { kind: 'migration' }, 'proj');
  eq(asked, [], 'calls to the service');
  eq(row.status.runId, 'live', 'its status is on its row');
  eq(row.running, 1, 'the machines it is moving');
});

test('UNKNOWN MEANS ASK: the one call failed, so every migration is asked, as before', async () => {
  const asked = pageWith(null);
  await page.readRun('proj/scan-only', { kind: 'migration' }, 'proj');
  eq(asked, ['proj/scan-only/run-status.json'], 'asked');
});

test('UNKNOWN MEANS ASK: a listing the service cut short cannot say a document is not there', async () => {
  const asked = pageWith(heldStore({ truncated: true }));
  await page.readRun('proj/scan-only', { kind: 'migration' }, 'proj');
  eq(asked, ['proj/scan-only/run-status.json'], 'asked');
});

run('run-404');
