/* COUNT-TRUTH-1: one definition of what happened to a machine.
 *
 * After a six-machine run with one machine put back, the Reports page showed
 * three figures and all three were wrong, each for a different reason:
 *
 *   - "Migrated 4": the run row read run-status.json's stateCounts, which is
 *     the engine's feed for ONE WAVE, not the run (REPORT-STALE-1)
 *   - the wave table said 6: a put-back keeps MIGRATED (PUTBACK-COUNT-1)
 *   - "Restored 0": only the engine's own rollback was counted, never a
 *     put-back a person chose (REPORT-RESTORED-1)
 *
 * and a machine LEFT OUT (SKIPPED) was counted as migrated too.
 *
 * RUN, not read: help.js's own function is driven through the shared cases,
 * and the Reports page's own summary builder is driven with real-shaped docs.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const REPORTS = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'reports.html'));
const MIGRATIONS = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

// The lifted function closes over WORKING_STATES. Take it from the source, not
// from a copy here that would keep passing after help.js changed.
const ws = HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/);
if (!ws) { throw new Error('WORKING_STATES is not declared in help.js'); }
// eslint-disable-next-line no-eval
global.WORKING_STATES = eval(ws[1]);
const machineOutcome = lift('help.js', 'machineOutcome');
global.machineOutcome = machineOutcome;
const outcomeCounts = lift('help.js', 'outcomeCounts');
// NOT-IN-WAVE-QUEUED-1: summaryFromDocs asks help.js's outsideRun too.
global.VmfHelp = { machineOutcome, outcomeCounts, outsideRun: lift('help.js', 'outsideRun') };

const CASES = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'machine-outcomes.json'), 'utf8')).cases;

test('RUN: every shared case gives the outcome the service gives', () => {
  ok(CASES.length >= 15, 'the fixture loaded');
  for (const c of CASES) {
    eq(machineOutcome(c.doc), c.outcome, `${JSON.stringify(c.doc)} - ${c.why}`);
  }
});

test('RUN: every state the schema knows has a case', () => {
  /* A state added to the schema and not here falls to "unknown" and is never
   * counted as migrated. That is safe, but it is also silent - so the list of
   * cases must cover the schema, and this says when it stops doing so. */
  const schema = JSON.parse(fs.readFileSync(
    path.join(__dirname, '..', '..', 'schemas', 'vm-state.schema.json'), 'utf8'));
  const covered = new Set(CASES.filter(c => c.doc).map(c => c.doc.state));
  for (const s of schema.properties.state.enum) { ok(covered.has(s), `a case for ${s}`); }
});

test('RUN: the counts have every outcome, at zero when nothing has it', () => {
  const c = outcomeCounts([]);
  eq(Object.keys(c).sort().join(','),
     'attention,leftOut,migrated,notStarted,putBack,rolledBack,unknown,working', 'the keys');
  ok(Object.values(c).every(v => v === 0), 'all zero');
});

// ---------- the Reports page ----------

// summaryFromDocs is a declared function in the page; lift it and run it.
const summaryFromDocs = lift('reports.html', 'summaryFromDocs');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/';
// LAB-UX-1: a plan entry carries its path, and only a machine the plan moves
// (A or B) has an outcome to count - see the MANUAL case below.
const entry = (n, wave, p = 'A') => ({ vmId: SUB + n, wave, path: p });
const doc = (n, state, extra) => ({ vmId: SUB + n, state, ...(extra || {}) });

test('RUN: the owner\'s run - six machines in three waves, one put back - reads 5 and 1', () => {
  const entries = [entry('a', 'w1'), entry('b', 'w1'), entry('c', 'w2'), entry('d', 'w2'), entry('e', 'w3'), entry('f', 'w3')];
  const docs = [doc('a', 'MIGRATED'), doc('b', 'MIGRATED'), doc('c', 'MIGRATED'),
                doc('d', 'MIGRATED', { restore: { restoredUtc: '2026-09-23T22:00:00Z' } }),
                doc('e', 'MIGRATED'), doc('f', 'MIGRATED')];
  const s = summaryFromDocs(entries, docs);
  eq(s.total, 6, 'six machines');
  eq(s.outcomes.migrated, 5, 'five migrated - not 6, and not the last wave\'s 2');
  eq(s.outcomes.putBack, 1, 'one put back');
  eq(s.outcomes.rolledBack, 0, 'and the engine rolled nothing back');
  eq(s.waves.length, 3, 'three waves');
  eq(s.waves[1].outcomes.putBack, 1, 'the put-back is in its own wave');
});

test('RUN: a machine left out is not migrated, and one with no record has not started', () => {
  const s = summaryFromDocs([entry('a', 'w'), entry('b', 'w'), entry('c', 'w')],
    [doc('a', 'SKIPPED'), doc('b', 'MIGRATED')]);
  eq(s.outcomes.migrated, 1, 'only the one that moved');
  eq(s.outcomes.leftOut, 1, 'the skipped one is left out');
  eq(s.outcomes.notStarted, 1, 'the one with no state document');
});

test('RUN: LAB-UX-1 - a machine the plan does not move is not "not started"', () => {
  // A migration of one machine read "In progress: 1 rolled back, 3 not
  // started". The three were given no target: MANUAL in the plan, no state.
  const s = summaryFromDocs([entry('a', 'w1'), entry('m1', 'unscheduled', 'MANUAL'),
    entry('m2', 'unscheduled', 'MANUAL'), entry('m3', 'unscheduled', 'MANUAL')],
    [doc('a', 'FAILED_ROLLED_BACK')]);
  eq(s.outcomes.rolledBack, 1, 'the one that moved rolled back');
  eq(s.outcomes.notStarted, 0, 'the three it does not move are not waiting to start');
  eq(s.total, 4, 'the plan still holds four');
});

test('the run row no longer counts from the wave feed', () => {
  /* The comment explaining why it stopped names stateCounts, and it sits
   * ABOVE summaryFromDocs, outside this slice - so the slice is code. */
  const load = REPORTS.slice(REPORTS.indexOf('async function loadSummaries'), REPORTS.indexOf('function outcomeState'));
  ok(load.length > 100, 'found loadSummaries');
  ok(!/stateCounts/.test(load), 'no stateCounts in the summary');
  ok(/source\.summary\(r\)/.test(load), 'it asks the source for the run summary');
  ok(/migrated: num\(o\.migrated\)/.test(load), 'migrated is the outcome');
  ok(/putBack: num\(o\.putBack\)/.test(load), 'put back is counted');
  ok(/restored: num\(o\.rolledBack\)/.test(load), 'restored is the engine rollback, named as such');
});

test('the live summary is the service\'s, with the project beside the run', () => {
  const code = REPORTS;
  ok(/summary: liveSummary/.test(code), 'the live source uses the service');
  ok(/runs\/\$\{VmfHelp\.VmfRun\.routeSegment\(run\)\}\/summary/.test(code), 'the bare run in the route');
  ok(/VmfHelp\.VmfRun\.withProject\(\{\}, run\)\)/.test(code), 'and the project in the query, by the shared rule');
});

test('the wave table uses the same definition, and shows put-backs', () => {
  const code = REPORTS;
  ok(/const mig = info\.vms\.filter\(e => outcomeOf\(e\.vmId\) === 'migrated'\)/.test(code), 'migrated by outcome');
  ok(/const back = info\.vms\.filter\(e => outcomeOf\(e\.vmId\) === 'putBack'\)/.test(code), 'put back by outcome');
  ok(/\$\{back \? `<span class="pill warn">\$\{back\}/.test(code), 'and the column draws it');
  ok(!/\['MIGRATED', 'SKIPPED'\]\.includes/.test(code), 'SKIPPED is no longer migrated');
});

/* PAGE-SCALE-REPORTS-1: the tiles that counted machines across every run are
 * gone (the tiles count migrations now). Each row's outcome names a put-back
 * and a rollback apart, after its tag. */
test('the outcome of a row names a put-back and a rollback apart', () => {
  ok(/add\(x\.putBack, UX\.oPutBack\)/.test(REPORTS), 'restored by a person');
  ok(/add\(x\.restored, UX\.oRestored\)/.test(REPORTS), 'and rolled back after a failure');
});

test('a put-back is listed with the machines that needed people', () => {
  const code = REPORTS;
  ok(/docs\.filter\(x => VmfHelp\.machineOutcome\(x\) === 'putBack'\)/.test(code), 'put-backs are found');
  ok(/state: 'PUT_BACK'/.test(code), 'and listed as their own kind');
});

test('RUN: FINISH-COUNT-1 - a machine a restore left stopped is an open problem, not a put-back', async () => {
  /* machineOutcome now says attention for it, so the put-back loop no longer
   * finds it - and its state MIGRATED is no problem state either. Without its
   * own line it would leave the list altogether. */
  const buildDetail = lift('reports.html', 'buildDetail');
  const swap = { kind: 'restore', error: 'Azure refused the swap', swaps: [{ lun: 1 }], swapped: [] };
  const docs = [
    doc('left', 'MIGRATED', { restore: { restoredUtc: '2026-10-23T11:00:00Z', restoredBy: 'operator@example.com' }, swapPending: swap, history: [] }),
    doc('back', 'MIGRATED', { restore: { restoredUtc: '2026-10-23T11:00:00Z', restoredBy: 'operator@example.com' }, history: [] }),
    doc('rb', 'FAILED_ROLLED_BACK', { restore: { restoredUtc: '2026-10-23T11:00:00Z' }, swapPending: swap,
        history: [{ state: 'FAILED_ROLLED_BACK', detail: 'x' }] }),
  ];
  const files = { 'plan.json': { entries: docs.map(d => ({ vmId: d.vmId, wave: 'w1', path: 'A' })) } };
  docs.forEach((d, i) => { files[`state/${i}.json`] = d; });
  globalThis.detailCache = new Map();
  globalThis.source = {
    readJson: async (r, n) => files[n] ?? null,
    listFolder: async (r, folder) => (folder === 'state' ? Object.keys(files).filter(k => k.startsWith('state/')) : []),
  };
  global.VmfHelp = { machineOutcome, outcomeCounts, outsideRun: global.VmfHelp.outsideRun, machineName: (id) => String(id).split('/').pop(),
                     mapLimited: async (items, fn) => Promise.all(items.map(fn)) };
  globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
  globalThis.reservedInstances = () => 0;
  const d = await buildDetail('run-1');
  const of = (n) => d.issues.filter(i => i.name === n);
  eq(of('left').length, 1, 'the stopped machine has one line');
  eq(of('left')[0].state, 'SWAP_LEFT', 'and it says the restore is not finished');
  eq(of('left')[0].open, true, 'it is open: a person must act');
  eq(of('left')[0].detail, 'Azure refused the swap', 'with Azure\'s words');
  eq(of('back').map(i => i.state), ['PUT_BACK'], 'a finished restore is still a put-back');
  eq(of('rb').map(i => i.state), ['FAILED_ROLLED_BACK'], 'a machine in a problem state keeps its one open line');
  eq(of('rb')[0].open, true, 'open');
  ok(typeof REPORTS.match(/SWAP_LEFT:\s+'[^']+'/)?.[0] === 'string', 'the page has words for it');
});

// ---------- the Migrations page ----------

test('RUN: STATUS-WORDS-1 - a stop that a restore ended is not open; its restore is listed', async () => {
  /* Lab, finding 69: after a restore that worked, the machine still showed
   * the stop as an open, red line. The stop stays in the record, closed, and
   * the restore has its own line. */
  const buildDetail = lift('reports.html', 'buildDetail');
  const stop = { tsUtc: '2026-11-04T17:00:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', detail: 'x' };
  const docs = [
    doc('mended', 'FAILED_NEEDS_ATTENTION', { restore: { restoredUtc: '2026-11-04T18:00:00Z', restoredBy: 'operator@example.com' }, history: [stop] }),
    doc('open', 'FAILED_NEEDS_ATTENTION', { restore: { restoredUtc: '2026-11-04T16:00:00Z' }, history: [stop] }),
  ];
  const files = { 'plan.json': { entries: docs.map(d => ({ vmId: d.vmId, wave: 'w1', path: 'A' })) } };
  docs.forEach((d, i) => { files[`state/${i}.json`] = d; });
  globalThis.detailCache = new Map();
  globalThis.source = {
    readJson: async (r, n) => files[n] ?? null,
    listFolder: async (r, folder) => (folder === 'state' ? Object.keys(files).filter(k => k.startsWith('state/')) : []),
  };
  global.VmfHelp = { machineOutcome, outcomeCounts, outsideRun: global.VmfHelp.outsideRun, machineName: (id) => String(id).split('/').pop(),
                     mapLimited: async (items, fn) => Promise.all(items.map(fn)) };
  globalThis.PROBLEM_STATES = ['FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
  globalThis.reservedInstances = () => 0;
  const d = await buildDetail('run-1');
  const of = (n) => d.issues.filter(i => i.name === n);
  eq(of('mended').map(i => `${i.state}:${i.open}`).sort(), ['FAILED_NEEDS_ATTENTION:false', 'PUT_BACK:false'], 'the stop closed, and the restore listed');
  eq(of('open').map(i => `${i.state}:${i.open}`), ['FAILED_NEEDS_ATTENTION:true'], 'a stop newer than the restore is open');
});

test('the Migrations page asks the same definition', () => {
  const code = MIGRATIONS;
  // STATUS-WORDS-1: the counts read the status, whose end results are this
  // definition (help.js's machineStatus calls machineOutcome).
  ok(/function machineStatusOf\(vmId, doc\)[\s\S]*?VmfHelp\.machineStatus\(/.test(code), 'the status');
  ok(/const outcome = machineOutcome\(doc\);/.test(HELP), 'the status asks the definition');
  ok(/const isPutBack = \(doc\) => VmfHelp\.machineOutcome\(doc\) === 'putBack';/.test(code), 'put back');
});

run('machine-outcome');
