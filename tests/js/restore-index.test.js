/* RENDER-1: which machines have a put-back running, answered once.
 *
 * This used to walk the whole event log for EACH machine row, and twice for a
 * machine with a restore open. renderWaves calls it per row, and renderWaves
 * runs on every 15-second refresh, every keystroke in the search box, every
 * filter chip and every wave toggle. The cost was machines x events, and both
 * grow - the log has no cap, and every operator action appends to it.
 *
 * Replacing two scans with one index is only safe if the ANSWER is identical,
 * so these tests are about the behaviour, not the speed: a restore that is
 * still open, one that has ended, what it is doing right now, and the ordering
 * rules the two passes encoded.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, test, eq, ok, run } = require('./_harness');

const restoreIndex = lift('migrations.html', 'restoreIndex');

// The index calls stepText on the newest azureops step; the words are tested
// elsewhere, so here it just has to be identifiable.
global.stepText = (e) => `text:${e.step}`;
// RESTORE-END-LOST-1 review: the index matches a machine without case, with the help file's own idKey.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: eval('(' + pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'help.js')).match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')') });
// PUTBACK-GONE-1: the page's own list of what ends a put-back, read from it.
// eslint-disable-next-line no-eval
global.RESTORE_ENDS = eval(pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html')).match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);

const at = (n) => new Date(Date.UTC(2026, 8, 13, 12, n, 0)).toISOString();
const ev = (vmId, step, outcome, minute) => ({ vmId, step, outcome, tsUtc: at(minute) });

test('a machine with no events is not in the index', () => {
  eq(restoreIndex([]).size, 0, 'empty log');
  eq(restoreIndex([ev('vm1', 'wave', 'ok', 1)]).size, 0, 'unrelated steps');
});

test('an open restore is reported, with when it started', () => {
  const idx = restoreIndex([ev('vm1', 'restore', 'start', 1)]);
  eq(idx.size, 1, 'one machine');
  eq(idx.get('vm1').since, at(1), 'since');
  eq(idx.get('vm1').doing, null, 'nothing under it yet');
});

test('a restore that ENDED is not in flight - and a progress note does not end it', () => {
  /* The rule this used to encode was "a start opens and ANYTHING else closes"
   * - and that rule WAS the defect (PUTBACK-GONE-1). The engine writes `info`
   * progress under the same step while the machine is still down, so the first
   * note switched "Putting back" off. The engine ends a put-back with ok, warn
   * or fail, and only those close it. */
  for (const outcome of ['ok', 'fail', 'warn']) {
    const idx = restoreIndex([ev('vm1', 'restore', 'start', 1), ev('vm1', 'restore', outcome, 2)]);
    eq(idx.size, 0, `restore closed by ${outcome}`);
  }
  const noted = restoreIndex([ev('vm1', 'restore', 'start', 1), ev('vm1', 'restore', 'info', 2)]);
  eq(noted.size, 1, 'a progress note leaves it open');
});

test('a machine can start a SECOND restore after the first ended', () => {
  const idx = restoreIndex([
    ev('vm1', 'restore', 'start', 1),
    ev('vm1', 'restore', 'ok', 2),
    ev('vm1', 'restore', 'start', 5),
  ]);
  eq(idx.get('vm1').since, at(5), 'the later start is the open one');
});

test('what it is doing now is the NEWEST step under the open restore', () => {
  const idx = restoreIndex([
    ev('vm1', 'restore', 'start', 1),
    ev('vm1', 'azureops:restore:snapshot', 'ok', 2),
    ev('vm1', 'azureops:restore:disk', 'start', 3),
  ]);
  eq(idx.get('vm1').doing, 'text:azureops:restore:disk', 'the latest one');
});

test('a step from BEFORE the restore started does not count', () => {
  // The original compared timestamps for exactly this. A machine put back
  // twice would otherwise report the previous attempt's step as current.
  const idx = restoreIndex([
    ev('vm1', 'azureops:restore:disk', 'ok', 1),
    ev('vm1', 'restore', 'start', 5),
  ]);
  eq(idx.get('vm1').doing, null, 'the earlier step is not what it is doing now');
});

test('an OUT-OF-ORDER line from before the restore is still rejected', () => {
  /* FOUND BY MUTATION. The previous test puts the older step earlier in the
   * array, so position alone rejects it and the timestamp check could be
   * deleted without failing anything.
   *
   * The log is appended by the engine and read while it is being written, and
   * the product runs SEVERAL worker containers at once (SCALE-2). Position in
   * the file is not a promise about time, so the check is what actually does
   * the work - and this is the case that proves it. */
  const idx = restoreIndex([
    ev('vm1', 'restore', 'start', 5),
    ev('vm1', 'azureops:restore:disk', 'ok', 1),   // written later, happened earlier
  ]);
  eq(idx.get('vm1').doing, null, 'an earlier step is not what it is doing now');
});

test('a step at the SAME instant as the start does count', () => {
  // The original used >=, not >. Events written in the same second are
  // ordinary - the log is appended to by one engine, fast.
  const idx = restoreIndex([
    ev('vm1', 'restore', 'start', 5),
    ev('vm1', 'azureops:restore:disk', 'start', 5),
  ]);
  eq(idx.get('vm1').doing, 'text:azureops:restore:disk', 'same timestamp counts');
});

test('machines do not read each other events', () => {
  const idx = restoreIndex([
    ev('vm1', 'restore', 'start', 1),
    ev('vm2', 'azureops:restore:disk', 'start', 2),
    ev('vm2', 'restore', 'start', 3),
  ]);
  eq(idx.get('vm1').doing, null, 'vm1 did not take vm2 step');
  eq(idx.get('vm2').since, at(3), 'vm2 has its own');
});

test('when a restore ends, what it was doing goes with it', () => {
  const idx = restoreIndex([
    ev('vm1', 'restore', 'start', 1),
    ev('vm1', 'azureops:restore:disk', 'start', 2),
    ev('vm1', 'restore', 'ok', 3),
    ev('vm1', 'restore', 'start', 4),
  ]);
  eq(idx.get('vm1').since, at(4), 'the new restore');
  eq(idx.get('vm1').doing, null, 'and it is not still showing the old step');
});

test('several machines at once, which is the case that made this quadratic', () => {
  const events = [];
  for (let i = 0; i < 50; i++) {
    events.push(ev(`vm${i}`, 'restore', 'start', 1));
    events.push(ev(`vm${i}`, 'azureops:restore:disk', 'start', 2));
  }
  const idx = restoreIndex(events);
  eq(idx.size, 50, 'every machine answered in one pass');
  eq(idx.get('vm7').doing, 'text:azureops:restore:disk', 'and each one correctly');
});

test('rubbish in the log does not throw', () => {
  // The log is append-only text read while it is being written.
  eq(restoreIndex(null).size, 0, 'no list');
  eq(restoreIndex([null, undefined, {}, { step: 'restore' }]).size, 0, 'entries with no machine');
});

run('restore-index');
