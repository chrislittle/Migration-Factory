/* RESTORE-ONE-AT-A-TIME-1: the machine panel does not offer Restore this
 * machine while a restore of the machine runs, and says why on the screen.
 * REBUILD-REMOVE-RECOVER-1: Rebuild this machine is gone.
 *
 * Before, Restore this machine was offered from restoreOffered alone, which
 * never asked whether a restore was running - so a second click started a
 * second engine job on the same machine. The service and the engine refuse
 * that now; the page stops offering it.
 *
 * RUN, not read: the page's own putBackControls, restoreOffered,
 * restoreIndex and restoreInFlight, driven with events shaped as the engine writes them.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.stepText = (e) => `text:${e.step}`;
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: eval('(' + pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js')).match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')') });
// RESTORE-MID-MOVE-1: restoreOffered asks whether the move of the machine ended.
globalThis.VmfHelp.machineAtWork = liftAll('help.js', ['machineHold', 'machineAtWork']).machineAtWork;
// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);

const page = liftAll('migrations.html', ['restoreIndex', 'restoreRecordEnds', 'restoreInFlight',
  'restoreCopiesThere', 'restoreOffered', 'finishOffered', 'putBackControls']);

const VM = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/app01';
const at = (n) => new Date(Date.UTC(2026, 9, 19, 12, n, 0)).toISOString();
const ev = (step, outcome, minute, extra = {}) => ({ vmId: VM, step, outcome, tsUtc: at(minute), ...extra });

// A machine both buttons would be offered on: a safety copy, and a shell the
// migration changed and could not put back.
const doc = () => ({
  vmId: VM, state: 'FAILED_NEEDS_ATTENTION', safety: { snapshotId: 'snap-1' },
  captured: { vmConfig: { size: 'Standard_D2ds_v4' } },
  history: [{ tsUtc: at(0), machineState: 'changed', reasonCode: 'rollbackFailed' }],
});

// The clock the page asks: ten minutes after minute 0 of the sample lines.
const NOW = Date.parse(at(10));
const ctl = (d, operate = true, nowMs = NOW) => page.putBackControls(d, VM, operate, nowMs);
// eslint-disable-next-line no-eval
const HOLD_MS = eval(PAGE.match(/const PUTBACK_HOLD_MS = (\d+);/)[1]);
globalThis.PUTBACK_HOLD_MS = HOLD_MS;

function seen(events) {
  globalThis.restoresInFlight = page.restoreIndex(events);
}

test('nothing running: Restore is offered, and nothing says busy', () => {
  seen([]);
  const c = ctl(doc());
  eq(c, { busy: false, restore: true, finish: null }, 'offered');
});

test('a restore running: it is not offered, and busy says why', () => {
  seen([ev('restore', 'start', 1, { correlationId: 'op-1' })]);
  eq(ctl(doc()), { busy: true, restore: false, finish: null }, 'hidden');
});

test('the machine is matched without letter case, as the restore index does', () => {
  seen([{ ...ev('restore', 'start', 1), vmId: VM.toUpperCase() }]);
  eq(ctl(doc()).busy, true, 'the same machine');
});

test('a restore of ANOTHER machine leaves Restore on this one', () => {
  seen([{ ...ev('restore', 'start', 1), vmId: VM.replace('app01', 'app02') }]);
  eq(ctl(doc()), { busy: false, restore: true, finish: null }, 'offered');
});

test('a viewer with no operator role is not offered it, running or not', () => {
  seen([]);
  const c = ctl(doc(), false);
  eq(c.restore, false, 'nothing to press');
});

test('REBUILD-REMOVE-RECOVER-1: no machine is offered Rebuild this machine', () => {
  seen([]);
  ok(!('rebuild' in ctl(doc())), JSON.stringify(ctl(doc())));
});

test('the panel shows the busy line, and builds the restore button from putBackControls', () => {
  const drill = PAGE.slice(PAGE.indexOf('async function openDrill('));
  ok(/const putBack = putBackControls\(doc, vmId, canOperate\(\)\);/.test(drill), 'the panel asks the rule');
  ok(/const restoreBtn = putBack\.restore\b/.test(drill), 'restore from the rule');
  ok(!/rebuildBtn|rebuild-btn|askRebuild/.test(drill), 'no rebuild button');
  ok(/\$\{putBackBusyLine\}/.test(drill), 'the reason is on the screen');
  ok(UX_ACT.putBackBusy && UX_ACT.putBackBusy.includes('Restore this machine'), 'the words name the button');
  ok(!UX_ACT.putBackBusy.includes('Rebuild this machine'), 'and no button that is gone');
  ok(/restoresInFlight = restoreIndex\(events\);/.test(PAGE), 'the index is built with the events');
  ok(!/rebuildIndex|rebuildInFlight/.test(PAGE), 'OLD-REBUILD-RESTORE-READERS-1: no index of a rebuild');
});

test('review: a job killed hard writes no end line - the buttons come back once its newest line is older than the hold', () => {
  for (const [start, step] of [['restore', 'azureops:restore:stop']]) {
    seen([ev(start, 'start', 0, { correlationId: 'op-1' }), ev(step, 'ok', 2)]);
    const lastMs = Date.parse(at(2));
    eq(ctl(doc(), true, lastMs + HOLD_MS).busy, true, `${start}: still running at the limit`);
    eq(ctl(doc(), true, lastMs + HOLD_MS + 1000), { busy: false, restore: true, finish: null }, `${start}: back after it`);
  }
});

test('review: a line of the job resets the clock, so a working job keeps the buttons hidden', () => {
  seen([ev('restore', 'start', 0), ev('azureops:restore:stop', 'ok', 14), ev('restore', 'info', 20)]);
  eq(ctl(doc(), true, Date.parse(at(20)) + HOLD_MS - 1000).busy, true, 'twenty minutes in, its last line is recent');
});

test('the hold the page waits is the one the manual says: 15 minutes', () => {
  eq(HOLD_MS, 15 * 60 * 1000, 'fifteen minutes');
  const manual = fs.readFileSync(path.join(__dirname, '..', '..', 'docs', 'manual', 'use', 'put-back.md'), 'utf8');
  ok(/15 minutes/.test(manual), 'the manual says 15 minutes');
});

test('review: a start line whose time cannot be read does not hide the buttons for ever', () => {
  seen([{ vmId: VM, step: 'restore', outcome: 'start', tsUtc: 'not a time' }]);
  eq(ctl(doc()), { busy: false, restore: true, finish: null }, 'restore: offered');
  seen([{ vmId: VM, step: 'restore', outcome: 'start' }]);
  eq(ctl(doc()), { busy: false, restore: true, finish: null }, 'a restore with no time: offered');
});

run('restore-one-at-a-time');
