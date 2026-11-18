/* WIZARD-OPTIONS-DISKS-1: the wizard's Run it step names each machine whose
 * move changes the type of its disks, with the same words and by the same
 * rule as the dialog Review & accept options on the migration's page
 * (WAVE-OPTIONS-DISKS-1).
 *
 * Both places accept the same settings, and the acceptance is recorded with
 * the person's name. Before this, Accept these settings at Run it accepted a
 * wave without saying that a move changes an OS disk to Standard SSD.
 *
 * RUN, not read: the wizard's own leverRowsFor, with the page's own words
 * (liftConst) and the real rule in help.js (diskUpgradeOf).
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const WIZ = liftConst('wizard.html', 'UX');
const DIALOG = liftConst('migrations.html', 'UX_LEVER');

globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.VmfHelp = {
  ...liftAll('help.js', ['anOutcomeRow', 'anOutcomeNames', 'previewNames']),
  approvalRequired: lift('help.js', 'approvalRequired'),
  keepDaysText: lift('help.js', 'keepDaysText'),
  diskUpgradeOf: lift('help.js', 'diskUpgradeOf'),
};

const W = liftAll('wizard.html', ['leverRowsFor', 'anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames', 'diskChangeTexts', 'previewText']);

/** label -> value, for the rows of one wave at Run it. */
function runItRows(entries, wave = 'w1') {
  globalThis.UX = WIZ;
  globalThis.plan = { entries };
  const rows = {};
  for (const r of W.leverRowsFor(wave).matchAll(/<tr><td class="muted">([^<]*)<\/td><td>([^<]*)<\/td><\/tr>/g)) { rows[r[1]] = r[2]; }
  return rows;
}
const mk = (id, diskUpgrade, extra = {}) => Object.assign({ vmId: `/s/rg/vm/${id}`, wave: 'w1', path: 'A', assessment: {},
  policy: Object.assign({ capacityGate: 'BestEffort', keepSnapshotDays: 7, requireApproval: false, targetGeneration: 'v6', throttle: 3 },
    diskUpgrade === undefined ? {} : { diskUpgrade }) }, extra);

test('the row and its values have the words of Review & accept options', () => {
  eq(WIZ.lvDisks, DIALOG.diskMachines, 'the row');
  eq(WIZ.lvDiskMachine, DIALOG.diskMachine, 'a name with its change');
  eq(WIZ.tDiskChoice['os-standard-ssd'], DIALOG.diskStandardSsdOs, 'Standard SSD: OS disk');
  eq(WIZ.tDiskChoice.os, DIALOG.diskPremiumOs, 'Premium SSD: OS disk');
  eq(WIZ.tDiskChoice.all, DIALOG.diskPremiumAll, 'Premium SSD: every disk');
  eq(WIZ.lvNone, DIALOG.identityNone, 'None in this wave');
  eq(WIZ.lvDisks, 'Machines whose disks change to Standard SSD or Premium SSD', 'in the names Azure uses');
});

test('THE DEFECT: each machine whose disk type changes is named with its new type; the others are not', () => {
  const rows = runItRows([
    mk('hdd', 'os-standard-ssd'), mk('prem', 'os'), mk('every', 'all'),
    // PowerShell's -in ignores case, so the engine changes the disks of this one.
    mk('upper', 'ALL'),
    mk('kept'), mk('keep', 'keep'), mk('unknown', 'something-else'),
    // A machine that does not move changes nothing, whatever its entry says.
    mk('manual', 'all', { path: 'MANUAL' }), mk('excluded', 'os', { path: 'EXCLUDED' }),
    // A machine of another wave is named on that wave.
    mk('other', 'os', { wave: 'w2' }),
  ]);
  eq(rows[WIZ.lvDisks], 'hdd (Standard SSD: OS disk), prem (Premium SSD: OS disk), every (Premium SSD: every disk), upper (Premium SSD: every disk)');
  eq(runItRows([mk('other', 'os', { wave: 'w2' })], 'w2')[WIZ.lvDisks], 'other (Premium SSD: OS disk)', 'the other wave names its own');
});

test('a wave that changes no disk type says None in this wave', () => {
  const rows = runItRows([mk('kept'), mk('keep', 'keep'), mk('manual', 'all', { path: 'MANUAL' }), mk('other', 'os', { wave: 'w2' })]);
  ok(WIZ.lvDisks in rows, 'the row is there when nothing changes, so its absence is never read as none');
  eq(rows[WIZ.lvDisks], WIZ.lvNone);
});

test('Run it shows the same names as Review & accept options for the same wave', () => {
  // The dialog's own function, run on the machines of the wave that move -
  // the set askAcceptOptions gives it.
  globalThis.UX_LEVER = DIALOG;
  const dialogTexts = lift('migrations.html', 'diskChangeTexts');
  const entries = [mk('hdd', 'os-standard-ssd'), mk('prem', 'OS'), mk('every', 'all'), mk('kept'), mk('odd', 'x')];
  eq(runItRows(entries)[WIZ.lvDisks], dialogTexts(entries).join(', '));
});

run('run-it-disks');
