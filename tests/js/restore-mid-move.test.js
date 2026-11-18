/* RESTORE-MID-MOVE-1: Restore this machine is offered only after the move of
 * the machine ended. Decided 2026-10-19: the wave's own resume and
 * rollback own a machine the wave started - also when its worker died - and
 * Stop this migration is the way to get it back now.
 *
 * Before, restoreOffered asked only whether a safety copy existed, so a
 * machine at STOPPED or CONVERTING whose worker stopped offered a restore the
 * engine now refuses. The panel says why the button is not there, on the
 * screen, and names Stop this migration.
 *
 * RUN, not read: the page's own restoreCopiesThere, restoreOffered,
 * restoreWaitsForMove and putBackControls, with help.js's machineAtWork -
 * the rule tests/js/wave-running-planned.test.js holds to the engine's list
 * of final states.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const SM = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'engine', 'StateMachine.ps1'), 'utf8');
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const HELP_SRC = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const HELP = liftAll('help.js', ['machineHold', 'machineAtWork']);
// eslint-disable-next-line no-eval
const idKey = eval('(' + HELP_SRC.match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { machineAtWork: HELP.machineAtWork, idKey });
globalThis.stepText = (e) => `text:${e.step}`;
// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
// eslint-disable-next-line no-eval
globalThis.PUTBACK_HOLD_MS = eval(PAGE.match(/const PUTBACK_HOLD_MS = (\d+);/)[1]);
globalThis.restoresInFlight = new Map();

const page = liftAll('migrations.html', ['restoreIndex', 'restoreRecordEnds', 'restoreInFlight',
  'restoreCopiesThere', 'restoreOffered', 'restoreWaitsForMove', 'finishOffered', 'putBackControls']);
globalThis.restoresInFlight = page.restoreIndex([]);

// The engine's own lists - read from the state machine, never typed here.
const list = (name) => {
  const m = SM.match(new RegExp(`\\$script:${name} = @\\(([^)]*)\\)`));
  if (!m) { throw new Error(`StateMachine.ps1 has no ${name}`); }
  return m[1].split(',').map(s => s.trim().replace(/'/g, '')).filter(Boolean);
};
const WORKING = list('VmfWorkingStates');
const TERMINAL = list('VmfTerminalStates');

const VM = '/subscriptions/11111111-2222-3333-4444-555555555555/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/app01';
const docAt = (state) => ({ vmId: VM, state, safety: { snapshotId: 'snap-1' }, history: [] });

test('the engine lists are read (a sanity check on this test itself)', () => {
  ok(WORKING.includes('CONVERTING') && WORKING.includes('PLANNED'), `working: ${WORKING.join(',')}`);
  ok(TERMINAL.includes('MIGRATED') && TERMINAL.includes('FAILED_ROLLED_BACK'), `terminal: ${TERMINAL.join(',')}`);
});

test('a machine at each working state is not offered Restore this machine, and the panel says why', () => {
  for (const s of WORKING) {
    eq(page.restoreOffered(docAt(s), true), false, `${s}: no restore`);
    eq(page.restoreWaitsForMove(docAt(s), true), true, `${s}: the line says why`);
    eq(page.putBackControls(docAt(s), VM, true).restore, false, `${s}: not through putBackControls either`);
  }
});

test('after the move ended, Restore this machine is offered, and no line says it waits', () => {
  for (const s of TERMINAL) {
    eq(page.restoreOffered(docAt(s), true), true, `${s}: restore offered`);
    eq(page.restoreWaitsForMove(docAt(s), true), false, `${s}: no line`);
  }
});

test('the line is only for an operator, and only where copies exist to restore from', () => {
  eq(page.restoreWaitsForMove(docAt('CONVERTING'), false), false, 'not for somebody who cannot operate');
  eq(page.restoreWaitsForMove({ ...docAt('CONVERTING'), safety: {} }, true), false, 'not with no copy');
  eq(page.restoreWaitsForMove({ ...docAt('CONVERTING'), retention: { deletedUtc: '2026-10-01T00:00:00Z' } }, true), false, 'not from copies that are gone');
});

test('the line names Stop this migration, the button the page shows for it', () => {
  ok(UX_ACT.restoreMidMove.includes(UX_ACT.stopRun), UX_ACT.restoreMidMove);
  ok(UX_ACT.restoreMidMove.includes(UX_ACT.restore), 'it names Restore this machine');
});

test('the panel draws the line from restoreWaitsForMove', () => {
  ok(/const midMoveLine = \(restoreWaitsForMove\(doc, canOperate\(\)\)/.test(PAGE), 'the panel asks the rule');
  ok(/\$\{putBackBusyLine\}\s*\$\{midMoveLine\}/.test(PAGE), 'and shows the line beside the busy line');
});

run('restore-mid-move');
