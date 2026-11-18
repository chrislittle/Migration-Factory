/* WAVE-KERNEL-LINE-1 (2026-11-14, found on the lab): the wave allowed no
 * kernel choice but Stop and ask for the MANA kernel, so every machine that
 * chose Update the kernel showed as not following the wave.
 *
 * KERNEL-UX-1 put the kernel choice on EACH MACHINE (the Choose each target
 * step) and rejected a wave-level setting. The wave settings still showed a
 * row "If the kernel is below the minimum version that Microsoft lists for
 * MANA: Stop and ask" that could never be anything else, and under it every
 * machine that chose Update the kernel as a machine that "does not follow this
 * setting". Now no wave has a kernel setting: the wave editor, Run it and the
 * acceptance of the Migrations page show ONE row, the machines whose kernel
 * the product updates, with "None in this wave" when none.
 *
 * RUN, not read, where a page function draws it; the words are pinned as
 * literals, so a change of the string table cannot pass by changing both sides.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');
require('./_at-once').install();
const rule = require('./_at-once').waveRule;
// Run it draws the other rows with these (as kernel-choice.test.js gives them).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { approvalRequired: lift('help.js', 'approvalRequired'),
  keepDaysText: lift('help.js', 'keepDaysText') });

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/';
const ROW = 'Machines whose kernel the product updates if it has no MANA driver';
const NONE = 'None in this wave';
const OLD = 'If the kernel is below the minimum version that Microsoft lists for MANA';
const src = (f) => pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', f));
/* A line of code, not a comment: some line BEGINS with this code once its
 * indent is gone, so a commented-out line does not count. */
const hasLine = (text, code) => text.split(/\r?\n/).some(l => l.trimStart().startsWith(code));
/* The lines of code only: a line that starts as a comment is dropped, and a
 * comment after code is cut (no URL in these lines holds //). */
const codeLines = (text) => text.split(/\r?\n/).map(l => l.trim())
  .filter(l => l && !l.startsWith('//') && !l.startsWith('*') && !l.startsWith('/*'))
  .map(l => l.replace(/\s\/\/\s.*$/, ''));

const upd = (n, wave = 'w') => ({ vmId: SUB + n, wave, path: 'A', policy: { onDriverBelowFloor: 'updateKernel' },
  decisions: [{ setting: 'onDriverBelowFloor', by: 'operator@example.com', utc: '2026-11-14T09:00:00Z' }] });
const plain = (n, wave = 'w') => ({ vmId: SUB + n, wave, path: 'A', policy: { onDriverBelowFloor: 'stop' } });

test('no wave has a kernel setting: the rule of help.js reads none, and no machine "does not follow" one', () => {
  ok(!('onDriverBelowFloor' in rule.waveSettingDefaults()), 'the settings of a wave hold no kernel setting');
  const card = rule.waveCard([upd('a'), plain('b')]);
  ok(!('onDriverBelowFloor' in card.values), 'the card has no kernel value');
  ok(!('onDriverBelowFloor' in card.own), 'and names no machine that does not follow it');
});

test('help.js has no words for a wave kernel setting any more', () => {
  const help = src('help.js');
  for (const key of ['ownRowKernel', 'ownDriverStop', 'ownKernel']) {
    ok(!new RegExp(`\\n\\s+${key}:`).test(help), `help.js TEXT has no ${key}`);
  }
});

test('the wave editor: one row names the machines that update their kernel, and None in this wave when none', () => {
  const UX = liftConst('waves.html', 'UX');
  eq(UX.kernelLabel, ROW, 'the label of the row');
  eq(UX.kernelNone, NONE, 'and the word for none');
  for (const key of ['driverLabel', 'driverStop', 'driverOnly', 'kernelNames']) eq(UX[key], undefined, `no ${key}`);
  globalThis.UX = UX;
  globalThis.esc = (v) => String(v ?? '');
  globalThis.vmName = (id) => String(id).split('/').pop();
  const kernelRow = lift('waves.html', 'kernelRow');
  globalThis.membersOf = () => [upd('lin-01'), plain('win-01'), upd('lin-02')];
  const two = kernelRow('w');
  ok(two.includes(`<span class="lv">${ROW}</span>`), two);
  ok(two.includes('lin-01, lin-02'), 'both machines, by name, in plan order');
  ok(!two.includes('win-01'), 'not a machine that does not update its kernel');
  ok(!/<select|<input|data-ownhelp|data-ownreset/.test(two), 'nothing to change on the wave: the choice belongs to each machine');
  ok(!two.includes(OLD) && !two.includes('Stop and ask'), 'no wave setting is shown');
  globalThis.membersOf = () => [plain('win-01')];
  ok(kernelRow('w').includes(NONE), 'None in this wave when no machine chose it');
  globalThis.membersOf = () => [];
  ok(kernelRow('w').includes(NONE), 'and for an empty wave');
});

test('the wave editor draws the row, and no wave setting for the kernel, in code', () => {
  const lines = codeLines(src('waves.html'));
  ok(lines.some(l => l.includes('${kernelRow(name)}')), 'the card draws the row');
  // The one line that names it reads a machine's own choice (kernelRow).
  const named = lines.filter(l => l.includes('onDriverBelowFloor'));
  eq(named, ["const names = membersOf(name).filter(e => e?.policy?.onDriverBelowFloor === 'updateKernel').map(e => vmName(e.vmId));"],
    'no save, no snapshot, no new wave and no reset carries a kernel setting of a wave');
});

test('Run it: the kernel row stays, and the wave setting row is gone', () => {
  const UX = liftConst('wizard.html', 'UX');
  eq(UX.lvKernel, ROW);
  eq(UX.lvDriver, undefined, 'no label for a wave kernel setting');
  eq(UX.lvDriverStop, undefined, 'and no value for it');
  globalThis.UX = UX;
  globalThis.esc = (v) => String(v ?? '');
  globalThis.vmName = (id) => String(id).split('/').pop();
  globalThis.anTurnsOnNames = () => [];
  globalThis.anDecidedNames = () => [];
  globalThis.diskChangeTexts = () => [];
  globalThis.previewText = () => UX.lvNone;
  globalThis.plan = { entries: [upd('lin-01', 'w1'), plain('lin-02', 'w1'), plain('win-01', 'w2')] };
  globalThis.kernelUpdateNames = lift('wizard.html', 'kernelUpdateNames');
  const rows = lift('wizard.html', 'leverRowsFor')('w1');
  ok(rows.includes(`<td class="muted">${ROW}</td><td>lin-01</td>`), rows);
  ok(!rows.includes(OLD), 'no wave kernel setting');
  ok(!rows.includes('does not follow this setting') && !rows.includes('do not follow this setting'), 'no machine is said not to follow its wave for its own kernel choice');
  ok(lift('wizard.html', 'leverRowsFor')('w2').includes(`<td class="muted">${ROW}</td><td>${NONE}</td>`), 'None in this wave');
});

test('the acceptance of the Migrations page: the kernel row stays, and the wave setting row is gone', () => {
  const UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
  eq(UX_LEVER.kernelMachines, ROW);
  eq(UX_LEVER.identityNone, NONE);
  for (const key of ['onDriverBelowFloor', 'driverStop', 'driverStopHint']) eq(UX_LEVER[key], undefined, `no ${key}`);
  const mig = src('migrations.html');
  ok(hasLine(mig, "[UX_LEVER.kernelMachines, kernelUpdateNames(entries).join(', ') || UX_LEVER.identityNone],"), 'the kernel row of the acceptance');
  ok(!codeLines(mig).some(l => l.includes("'onDriverBelowFloor']")), 'no row reads a wave kernel setting');
});

run('wave-kernel-line');
