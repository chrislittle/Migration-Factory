/* ROLLBACK-CAPACITY-1 and FILTER-DRIVER-READ-1 (2026-11-14): the
 * sign-off of a wave - the wizard's Run it and Review & accept options on the
 * migration's page - shows, each only for a wave it is true of:
 *   - one line that the product gives no guarantee of capacity, for a wave
 *     that holds a machine whose original size is in a series with restricted
 *     capacity (assessment.sourceCapacityRestricted, plan-entry v35, written
 *     by the engine from data);
 *   - Microsoft's sentence about third-party software that changes boot,
 *     storage drivers, filter drivers or disk enumeration, and what it means,
 *     for a wave that moves a machine to NVMe (v6 or v7). A wave of only v5
 *     or Bsv2 moves stays on SCSI and shows nothing.
 *
 * ONE RULE (help.js signOffRiskLines), two pages: each page gives its own
 * words, as keepDaysText does. The pages' own drawing is RUN in run-step
 * (renderStep5) and wave-words (askAcceptOptions); here the rule itself, with
 * each page's real words.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const WIZ = liftConst('wizard.html', 'UX');
const DIALOG = liftConst('migrations.html', 'UX_LEVER');
// SQL-TEMPDB-SIGNOFF-1: with the SQL Server rule it asks when a page gives its words.
const signOffRiskLines = liftAll('help.js', ['signOffRiskLines', 'sqlTempdbEntries', 'sqlTempdbRisk']).signOffRiskLines;

const mk = (id, extra = {}) => Object.assign({ vmId: `/s/rg/vm/${id}`, wave: 'w1', path: 'A',
  assessment: { sourceSize: 'Standard_D2s_v4', sourceCapacityRestricted: false },
  target: { size: 'Standard_D2s_v5', controller: 'SCSI' } }, extra);
const v3 = (id, extra = {}) => mk(id, Object.assign({ assessment: { sourceSize: 'Standard_D2s_v3', sourceCapacityRestricted: true } }, extra));
const nvme = (id, extra = {}) => mk(id, Object.assign({ target: { size: 'Standard_D2ds_v6', controller: 'NVMe' } }, extra));

// The words each page passes - read from the page source, so a page that
// passed other words fails 'each page asks the one rule with its own words'.
const WIZ_WORDS = { capacity: WIZ.lvCapacityNoGuarantee, nvme: [WIZ.lvNvmeThirdParty, WIZ.lvNvmeThirdPartyWhat, WIZ.lvNvmeDiskPaths] };
const DIALOG_WORDS = { capacity: DIALOG.capacityNoGuarantee, nvme: [DIALOG.nvmeThirdParty, DIALOG.nvmeThirdPartyWhat, DIALOG.nvmeDiskPaths] };
const runIt = (entries, wave = 'w1') => signOffRiskLines(entries.filter(e => e.wave === wave), WIZ_WORDS);
const dialog = (entries) => signOffRiskLines(entries, DIALOG_WORDS);
test('the words are the same on both pages', () => {
  eq(WIZ.lvCapacityNoGuarantee, DIALOG.capacityNoGuarantee, 'the capacity line');
  eq(WIZ.lvNvmeThirdParty, DIALOG.nvmeThirdParty, 'Microsoft\'s sentence');
  eq(WIZ.lvNvmeThirdPartyWhat, DIALOG.nvmeThirdPartyWhat, 'what it means');
  eq(WIZ.lvNvmeDiskPaths, DIALOG.nvmeDiskPaths, 'the disk paths');
});

test('Microsoft\'s sentence is word for word the pinned NVMe page for Linux', () => {
  const page = fs.readFileSync(path.join(__dirname, '..', '..', 'docs', 'upstream-docs', 'azure', 'virtual-machines', 'nvme-linux.md'), 'utf8');
  const quoted = /"([^"]+)"/.exec(WIZ.lvNvmeThirdParty)[1];
  ok(page.includes(quoted), `the page holds: ${quoted}`);
  ok(/v5/.test(WIZ.lvNvmeThirdPartyWhat) && /SCSI/.test(WIZ.lvNvmeThirdPartyWhat), 'it names v5 and SCSI');
});

test('THE CASE: a wave with a machine on a restricted series shows the capacity line once', () => {
  eq(runIt([v3('a'), v3('b'), mk('c')]), [WIZ.lvCapacityNoGuarantee]);
  eq(dialog([v3('a'), v3('b'), mk('c')]), [DIALOG.capacityNoGuarantee]);
});

test('no capacity line for a wave with none, with only a value not known, or only on a machine that does not move', () => {
  eq(runIt([mk('a'), mk('b')]), []);
  eq(runIt([mk('a', { assessment: { sourceSize: 'x', sourceCapacityRestricted: null } })]), [], 'null is not a yes');
  eq(runIt([mk('a', { assessment: { sourceSize: 'x' } })]), [], 'absent is not a yes');
  eq(runIt([mk('a', { assessment: { sourceSize: 'x', sourceCapacityRestricted: 'true' } })]), [], 'only a stored true');
  eq(runIt([v3('m', { path: 'MANUAL' }), mk('a')]), [], 'a machine that does not move');
  eq(runIt([v3('o', { wave: 'w2' }), mk('a')]), [], 'a machine of another wave');
  eq(runIt([v3('o', { wave: 'w2' })], 'w2'), [WIZ.lvCapacityNoGuarantee], 'its own wave shows it');
});

test('THE CASE: a wave that moves a machine to NVMe shows Microsoft\'s sentence and what it means', () => {
  eq(runIt([nvme('a'), mk('b')]), [WIZ.lvNvmeThirdParty, WIZ.lvNvmeThirdPartyWhat, WIZ.lvNvmeDiskPaths]);
  eq(dialog([nvme('a')]), [DIALOG.nvmeThirdParty, DIALOG.nvmeThirdPartyWhat, DIALOG.nvmeDiskPaths]);
});

test('a wave of only v5 or Bsv2 moves stays on SCSI and shows no NVMe line', () => {
  const bsv2 = mk('b', { target: { size: 'Standard_B2s_v2', controller: 'SCSI' } });
  eq(runIt([mk('a'), bsv2]), []);
  eq(dialog([mk('a'), bsv2]), []);
  eq(runIt([nvme('m', { path: 'MANUAL' }), mk('a')]), [], 'a machine that does not move');
});

test('both lines together, capacity first', () => {
  eq(runIt([v3('a'), nvme('b')]), [WIZ.lvCapacityNoGuarantee, WIZ.lvNvmeThirdParty, WIZ.lvNvmeThirdPartyWhat, WIZ.lvNvmeDiskPaths]);
  eq(dialog([nvme('b', { assessment: { sourceSize: 'Standard_D2s_v3', sourceCapacityRestricted: true } })]),
    [DIALOG.capacityNoGuarantee, DIALOG.nvmeThirdParty, DIALOG.nvmeThirdPartyWhat, DIALOG.nvmeDiskPaths]);
});

test('DISK-PATH-READ-1: the disk path line says what the product checks and what it does not', () => {
  ok(/mounted volumes and the fstab file/.test(WIZ.lvNvmeDiskPaths), 'what it checks');
  ok(/\/dev\/sdc/.test(WIZ.lvNvmeDiskPaths) && /\/dev\/disk\/azure\/scsi1/.test(WIZ.lvNvmeDiskPaths), 'the device paths');
  ok(/UUID/.test(WIZ.lvNvmeDiskPaths), 'the stable identifier Microsoft names');
});

test('the rule itself: only a machine that moves counts, and only a stored true', () => {
  const W = { capacity: 'C', nvme: ['N1', 'N2'] };
  eq(signOffRiskLines([nvme('m', { path: 'MANUAL' })], W), [], 'NVMe, not moving');
  eq(signOffRiskLines([nvme('a')], W), ['N1', 'N2']);
  eq(signOffRiskLines([mk('a')], W), [], 'SCSI');
  eq(signOffRiskLines([v3('m', { path: 'EXCLUDED' })], W), [], 'restricted, not moving');
  eq(signOffRiskLines([v3('a')], W), ['C']);
  eq(signOffRiskLines([v3('a'), nvme('b')], W), ['C', 'N1', 'N2'], 'capacity first');
  eq(signOffRiskLines([], W), []);
  eq(signOffRiskLines(undefined, W), []);
  eq(signOffRiskLines([null, v3('a')], W), ['C'], 'a hole in the list');
});

test('each page asks the one rule with its own words, and draws each line under the settings', () => {
  const wiz = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.js'), 'utf8');
  // SQL-TEMPDB-SIGNOFF-1: and the SQL Server line, with its machine names (sql-tempdb-signoff).
  ok(/VmfHelp\.signOffRiskLines\(\(plan\?\.entries \?\? \[\]\)\.filter\(e => e\.wave === w\),\s*\{ capacity: UX\.lvCapacityNoGuarantee, nvme: \[UX\.lvNvmeThirdParty, UX\.lvNvmeThirdPartyWhat, UX\.lvNvmeDiskPaths\], sql: UX\.lvSqlTempdb \}, \(id\) => machineNameOf\(id\)\)/.test(wiz), 'Run it');
  ok(/<table class="facts">\$\{leverRowsFor\(w\)\}<\/table>\s*\$\{riskLines\(w\)\}/.test(wiz), 'Run it draws them under the table');
  const mig = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.js'), 'utf8');
  ok(/VmfHelp\.signOffRiskLines\(entries, \{ capacity: UX_LEVER\.capacityNoGuarantee,\s*nvme: \[UX_LEVER\.nvmeThirdParty, UX_LEVER\.nvmeThirdPartyWhat, UX_LEVER\.nvmeDiskPaths\], sql: UX_LEVER\.sqlTempdb \}, vmName\)/.test(mig), 'the acceptance');
  ok(/<\/table><\/div>\$\{riskLines\}/.test(mig), 'the acceptance draws them under the table');
  for (const [name, src] of [['wizard.js', wiz], ['migrations.js', mig]]) {
    ok(!/function (waveRiskLines|acceptRiskLines)\b/.test(src), `${name} builds no lines of its own`);
  }
});
run('rollback-capacity');
