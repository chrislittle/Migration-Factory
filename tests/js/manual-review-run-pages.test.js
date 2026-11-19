/* MANUAL-REVIEW-1, area C: the words of the Migrations page, the wave editor
 * and the wizard (2026-11-12). Each line is true, reachable on a 1.0
 * install, helps the person act, and uses the product's own nouns and Azure's
 * own names. RUN, not read: the tables are lifted from the pages, and the
 * feed's own stepText draws the lines.
 *
 * tests/unit/ManualReviewRunLines.Tests.ps1 holds the engine side.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftConst, liftAll, test, eq, ok, run } = require('./_harness');
const { pageSource } = require('./_page-source');

const REPO = path.join(__dirname, '..', '..');
const MIG = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const UX_STATE = liftConst('migrations.html', 'UX_STATE');
const UX_STEP = liftConst('migrations.html', 'UX_STEP');
const UX_MISC = liftConst('migrations.html', 'UX_MISC');
const UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const UX_FOUND_T = liftConst('migrations.html', 'UX_FOUND_T');
const UX_FOUND = liftConst('migrations.html', 'UX_FOUND');
const UX_FIRST = liftConst('migrations.html', 'UX_FIRST');
const STOP_CHECK = liftConst('migrations.html', 'STOP_CHECK');
const WAVES = liftConst('waves.html', 'UX');
const WUX = liftConst('wizard.html', 'UX');
const SM = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'engine', 'StateMachine.ps1'), 'utf8');

// Every string value of a table, nested or not.
function strings(o) {
  if (typeof o === 'string') return [o];
  if (Array.isArray(o)) return o.flatMap(strings);
  if (o && typeof o === 'object') return Object.values(o).flatMap(strings);
  return [];
}
const ALL = [UX_STATE, UX_STEP, UX_MISC, UX_LEVER, UX_ACT, UX_FOUND_T, UX_FOUND, UX_FIRST, WAVES, WUX].flatMap(strings);

test('Rolled back says the power state, never that the machine runs', () => {
  // POWER-AFTER-MOVE-1: a rollback returns the machine to the power state Checking found.
  eq(UX_STATE.FAILED_ROLLED_BACK[1], 'A step failed, and the product rolled the machine back to its original size and power state.');
  ok(!/It is running/.test(UX_STATE.FAILED_ROLLED_BACK[1]));
  ok(!/engineer/.test(UX_STATE.FAILED_NEEDS_ATTENTION[1]), 'no invented role');
  eq(UX_STATE.FAILED_NEEDS_ATTENTION[1], 'The machine stopped. Open the machine to see why and what to do.');
  eq(UX_FOUND.Blocked[1], 'A finding stops this machine. The row says which.');
});

test('no feed line for a first copy that a plan did not ask for', () => {
  ok(!('pristineNotRequested' in UX_STEP), 'the string is gone');
  ok(!/not requested/.test(MIG), 'and its branch');
  globalThis.UX_STEP = UX_STEP;
});

test('no "reservation" alone and no "capacity reservation" without on-demand', () => {
  // Since 2026-11-13: the setting is "On-demand capacity reservation for this wave".
  const bad = ALL.filter(s => /\s/.test(s)).filter(s => {
    const t = s.replace(/on-demand capacity reservations?/gi, '').replace(/capacity reservation groups?/gi, '')
      .replace(/its capacity reservation setting/g, '');
    return /\breservations?\b/i.test(t);
  });
  eq(bad, [], 'every reservation is named by its Azure name');
  eq(UX_MISC.quotaReservationFailed, 'On-demand capacity reservation failed');
  // Review batch 10: a wave that reserves nothing shows Not reserved, from its own string.
  eq(UX_MISC.bestEffortPill, 'Not reserved');
  ok(MIG.includes('${esc(UX_MISC.bestEffortHint)}">${esc(UX_MISC.bestEffortPill)}</span>'), 'the pill uses its own string');
  for (const label of [UX_LEVER.capacityGate, WAVES.capLabel, WUX.lvCapacity]) eq(label, 'On-demand capacity reservation for this wave');
});

test('no "(s)" plural, and the counts say one or many', () => {
  eq(ALL.filter(s => /\w\(s\)/.test(s)), []);
  ok(/\{n\} engine container,/.test(WAVES.capFitsOne) && /\{n\} engine containers,/.test(WAVES.capFits));
  ok(/^\{n\} machine cannot/.test(WUX.aBlockedNoteOne) && /^\{n\} machines cannot/.test(WUX.aBlockedNote));
});

test('no lab run, and no claim that the product has not measured something', () => {
  eq(ALL.filter(s => /\blab\b/i.test(s)), []);
  eq(ALL.filter(s => /not measured|has not measured/i.test(s)), []);
  ok(!/dLabRun|vNvmeUnmeasured/.test(WIZ), 'the Details row is gone');
});

test('no opinion words: safely, usual, really, least change, old kernel, older than', () => {
  eq(ALL.filter(s => /\bsafely\b|than usual|\breally\b|least change|\bold kernel\b|older than the MANA|looks too long|just larger/i.test(s)), []);
  // WAVE-KERNEL-LINE-1: the wave kernel setting is gone; its one row on the
  // three pages names the machines, in one sentence.
  const row = 'Machines whose kernel the product updates if it has no MANA driver';
  eq(UX_LEVER.kernelMachines, row);
  eq(WAVES.kernelLabel, row);
  eq(WUX.lvKernel, row);
});

test('no duration nobody measured, and no minutes for each machine', () => {
  eq(ALL.filter(s => /a few minutes|a minute or two|about a minute/i.test(s)), []);
  // Since 2026-11-13: no wave-time figure in words; the engine's estimate stays where the page shows its number.
  eq(ALL.filter(s => /each machine takes|minutes (for each|per) machine/i.test(s)), []);
});

test('the wizard names the real controls and pages', () => {
  ok(WUX.s5Done.includes(`Select ${WUX.openRun}`), 'Open the run');
  ok(!/runs page/.test(WUX.s5Done));
  ok(WUX.s3Planned.includes(`select ${UX_ACT.discardRun} on the Migrations page`), 'Delete this migration');
  ok(!/discard this migration/.test(WUX.s3Planned));
});

test('the kernel help never tells a person to leave EUS', () => {
  ok(!/Switch such a machine to the non-EUS repositories/.test(WUX.tKernelHelp));
  ok(/on EUS or non-EUS repositories\.$/.test(WUX.tKernelHelp));
});

test('when an on-demand capacity reservation bills, in the approved words', () => {
  // Approved 2026-11-13.
  const until = 'until every machine of the wave has ended and the product releases it, or until you select Release';
  for (const s of [UX_LEVER.capReservedHint, WAVES.capTip, WAVES.reserveDone, WAVES.reserveAsk]) ok(s.includes(until), s);
  eq(ALL.filter(s => /until the wave is closed|while it is held/i.test(s)), []);
});

test('no "we" narrator in the found-machines table', () => {
  eq(UX_FOUND_T.title, 'Machines that the scan found');
  eq(UX_FOUND_T.colWhere, 'Resource group and region');
  eq(WUX.colWhere, 'Resource group and region');
  eq(strings(UX_FOUND).filter(s => /\bwe\b/i.test(s)), []);
  eq([WUX.s1Title, WUX.s1Body, WUX.s2Title, ...WUX.stepsAssess].filter(s => /\bwe\b/i.test(s)), [], 'the steps name the scan');
  eq(WUX.s2Title, 'What the scan found');
});

test('the stop box reads the check out of the rollback words the engine writes', () => {
  // STOP-HEADLINE-CHECK-1: the page and the engine hold one sentence.
  ok(SM.includes('"The $stepWord step failed, and the product rolled the machine back to how it was: $why$powerNote$keptNote"'));
  eq(STOP_CHECK.prefix, 'The Verifying step failed, and the product rolled the machine back to how it was: ');
  ok(/VALIDATING = 'Verifying'/.test(SM), 'Verifying is the step word of VALIDATING');
});

test('the sample data names no lab resource group and no lab region', () => {
  // Catch list item 2: no lab names or regions in what ships. The
  // sample machines are on screens the manual shows.
  for (const f of ['migrations.js', 'waves.js', 'wizard.js', 'help.js']) {
    const lines = fs.readFileSync(path.join(REPO, 'src', 'dashboard', f), 'utf8').split('\n')
      .filter(l => !/^\s*(\/\/|\*|\/\*)/.test(l));
    eq(lines.filter(l => /rg-vmf-lab|centralus/.test(l)).map(l => l.trim().slice(0, 80)), [], f);
  }
  const shots = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
  ok(!/rg-vmf-lab|centralus/.test(shots), 'the screenshot tool asks for the same sample names');
});

run('manual-review-run-pages');
