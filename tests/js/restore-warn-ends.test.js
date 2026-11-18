/* RESTORE-WARN-ENDS-1: a line in the middle of a restore ended "Putting back".
 *
 * During a person's restore, an interface whose accelerated networking Azure
 * would not set back, or a disk whose type it would not set back, was written
 * as a `warn` under the step `restore`. The page reads a `restore` warn as the
 * END of the restore, so "Putting back" switched off while the restore went
 * on, and the activity list said "The restore did not finish. The machine was
 * restarted and is running." The engine now writes those lines as `info`, as
 * the data disk restore already did (RESTORE-ALL-1), and the page shows an
 * `info` line's own sentence instead of the finished-restore words.
 *
 * RUN: the page's own restoreIndex and stepText, driven with what the engine
 * writes; and the two engine helpers READ FROM THEIR SOURCE, so a warn under a
 * restore cannot come back unnoticed.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const ENGINE = path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Private', 'engine');
const STATE_MACHINE = fs.readFileSync(path.join(ENGINE, 'StateMachine.ps1'), 'utf8');
const DISK_TYPE = fs.readFileSync(path.join(ENGINE, 'DiskType.ps1'), 'utf8');

// eslint-disable-next-line no-eval
global.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
global.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
global.STEP_MAP = [];
global.UX_STEP = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE = liftConst('migrations.html', 'UX_STATE');
global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
// RESTORE-END-LOST-1 review: restoreIndex matches a machine without case, with the help file's own idKey.
// eslint-disable-next-line no-eval
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey: eval('(' + pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js')).match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')') });
const { restoreIndex, stepText } = liftAll('migrations.html', ['restoreIndex', 'stepText']);

const VM = '/x/vm1';
const ev = (min, step, outcome, detail) => ({ tsUtc: new Date(Date.UTC(2026, 9, 12, 16, min)).toISOString(), vmId: VM, step, outcome, detail });
const notBack = 'Accelerated networking could not be set back on vm1-nic0: NetworkInterfaceInUse. The machine starts with it as the move left it.';

test('RUN: a line about an interface that did not go back keeps "Putting back" on', () => {
  const events = [
    ev(0, 'restore', 'start', 'restoring from safety copy'),
    ev(1, 'azureops:restore:deallocate', 'ok'),
    ev(2, 'restore', 'info', notBack),
    ev(3, 'azureops:restore:resize', 'ok'),
  ];
  const open = restoreIndex(events).get(VM);
  ok(open, 'the machine is still shown as putting back');
  ok(!restoreIndex([...events, ev(9, 'restore', 'ok', 'restored from safety copy')]).has(VM), 'and the end still ends it');
});

test('the activity list shows what an info line says, not that the restore is done', () => {
  eq(stepText(ev(2, 'restore', 'info', notBack)), notBack);
  eq(stepText(ev(9, 'restore', 'ok', 'restored from safety copy')), UX_STEP.restoreDone);
  eq(stepText(ev(9, 'restore', 'warn', 'restore failed and the machine was restarted')), UX_STEP.restoreWarn);
  eq(stepText(ev(0, 'restore', 'start', 'restoring')), UX_STEP.restoreStart);
});

test('the two engine helpers write info, not warn, under a restore', () => {
  // The interface helper chooses its outcome once, from the kind.
  ok(/\$notBackOutcome = if \(\$Kind -eq 'restore'\) \{ 'info' \} else \{ 'warn' \}/.test(STATE_MACHINE), 'the interface helper picks info for a restore');
  const anWrites = [...STATE_MACHINE.matchAll(/-Step \$eventStep -Outcome (\S+)/g)].map(m => m[1]);
  ok(anWrites.length >= 3, `found the interface helper's lines, got ${anWrites.length}`);
  ok(!anWrites.includes('warn'), 'no interface line is a plain warn');
  ok(/-Step \$Kind -Outcome \$\(if \(\$Kind -eq 'restore'\) \{ 'info' \} else \{ 'warn' \}\)/.test(DISK_TYPE), 'the disk type helper picks info for a restore');
  ok(!/-Step \$Kind -Outcome warn/.test(DISK_TYPE), 'no disk type line is a plain warn');
});

run('restore-warn-ends');
