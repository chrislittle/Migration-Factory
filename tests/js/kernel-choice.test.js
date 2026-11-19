/* MANA-LINUX-KERNEL-1: "If the kernel has no MANA driver: Stop and ask /
 * Update the kernel" - a choice per machine on the Choose each target step,
 * and shown again where a wave is signed off. KERNEL-UX-1 moved the choice
 * into each machine's Details, with a dot and a notice, and took away the
 * default list and the column.
 *
 * RUN, not read: the pages' own functions, lifted out of wizard.html,
 * migrations.html and waves.html, driven with machines shaped like the target
 * advice and entries shaped like the plan.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// ACCEPT-FIRST-MACHINE-1: the settings of a wave are read by the rule in
// help.js; waves.js names its parts (leverValue, keepsOwn, waveCard) as
// aliases of VmfHelp, so the page functions find them on the global object.
function waveRuleGlobal() { const r = require('./_at-once').waveRule; Object.assign(globalThis, { leverValue: r.leverValue, ownDecision: r.ownDecision, keepsOwn: r.keepsOwn, waveCard: r.waveCard }); return r; }
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel'),
  // SIGNOFF-NULL-1: the one rule for the sign-off.
  approvalRequired: lift('help.js', 'approvalRequired'),
  // WAVE-WORDS-3: the retention words of Run it and the acceptance dialog.
  keepDaysText: lift('help.js', 'keepDaysText') });

const REPO = path.join(__dirname, '..', '..');
const read = (f) => pageSource(path.join(REPO, 'src', 'dashboard', f));
/* A line of code, not a comment: some line of the page BEGINS with this code
 * once its indent is gone, so a line turned into a comment (// ...) does not
 * count (CLAUDE.md, "a test that reads a whole file matches its own
 * comments"). A whole-file scanner is not used here: wizard.html has regular
 * expressions with quotes in them, which throw a quote-aware scanner off. */
const hasLine = (text, code) => text.split(/\r?\n/).some(l => l.trimStart().startsWith(code));global.sizeOf = lift('wizard.html', 'sizeOf');
global.savedSizes = lift('wizard.html', 'savedSizes');
// REBUILD-PICKER-1: the method rule the save reads, and the rebuild row of Run it.
Object.assign(global, require('./_harness').liftAll('wizard.html', ['tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tRecommended']));
// TEMP-DISK-PREVIEW-1: the row of the machines that need the preview feature.
global.previewText = lift('wizard.html', 'previewText');
globalThis.VmfHelp.previewNames = lift('help.js', 'previewNames');
// SIGNOFF-AN-OFF-1: and the machines whose move turns accelerated networking off.
Object.assign(globalThis.VmfHelp, liftAll('help.js', []));
global.savedDisks = lift('wizard.html', 'savedDisks');
global.premiumOf = lift('wizard.html', 'premiumOf');
global.disksOf = lift('wizard.html', 'disksOf');
global.diskChoicesOf = lift('wizard.html', 'diskChoicesOf');
global.oldShape = global.oldShape ?? lift('wizard.html', 'oldShape');
global.osDiskTypes = lift('wizard.html', 'osDiskTypes');
global.advPick = lift('wizard.html', 'advPick');
global.kernelOffered = lift('wizard.html', 'kernelOffered');
global.kernelOf = lift('wizard.html', 'kernelOf');
const targetChoicesBody = lift('wizard.html', 'targetChoicesBody');
const setKernelChoice = global.setKernelChoice = lift('wizard.html', 'setKernelChoice');
const exportState = lift('wizard.html', 'exportState');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/';
const opt = (option, move, mayUseMana, extra) => Object.assign({ option, supported: true, targetSize: `Standard_D2ds_${option}`, move,
  acceleratedNetworking: { required: false, mayUseMana, turnsOn: false }, sizeChoices: [], premiumDisks: true }, extra || {});
const machine = (name, os, options, start) => ({ vmId: SUB + name, name, os, options, start: start || { current: 'v6', extended: 'v5' } });

const lin = machine('lin-01', 'Linux', [opt('v5', 'scsi-resize', true), opt('v6', 'nvme-conversion', true)]);
const win = machine('win-01', 'Windows', [opt('v5', 'scsi-resize', true), opt('v6', 'nvme-conversion', true)]);
const amd = machine('amd-01', 'Linux', [opt('v5', 'scsi-resize', false, { targetSize: 'Standard_D2ads_v5' }), opt('v6', 'nvme-conversion', true)]);

test('offered for a Linux machine whose target can use MANA - never for Windows or AMD v5', () => {
  ok(kernelOffered(lin, 'v6', new Map()), 'Linux on v6');
  ok(kernelOffered(lin, 'v5', new Map()), 'Linux on Intel v5');
  ok(!kernelOffered(win, 'v6', new Map()), 'Windows takes its driver into the driver store');
  ok(!kernelOffered(amd, 'v5', new Map()), 'AMD v5 never gives MANA');
  ok(kernelOffered(amd, 'v6', new Map()), 'the same machine on v6 can');
  const unknown = machine('unk-01', 'Linux', [opt('v5', 'scsi-resize', null)]);
  ok(kernelOffered(unknown, 'v5', new Map()), 'a size that cannot be read is offered, as the engine judges it');
  ok(!kernelOffered(lin, null, new Map()), 'no target, no choice');
});

test('a size choice decides for itself', () => {
  const sized = machine('old-01', 'Linux', [opt('v5', 'scsi-resize', true, { targetSize: 'Standard_D2ds_v5', sizeChoices: [
    { size: 'Standard_D2ds_v5', acceleratedNetworking: { mayUseMana: true } },
    { size: 'Standard_D2ads_v5', acceleratedNetworking: { mayUseMana: false } }] })]);
  ok(kernelOffered(sized, 'v5', new Map()), 'the best size can');
  ok(!kernelOffered(sized, 'v5', new Map([[sized.vmId, 'Standard_D2ads_v5']])), 'the AMD size chosen cannot');
});

test('the choice that counts: a machine\'s own, else the default, and nothing where it is not offered', () => {
  eq(kernelOf(lin, 'v6', new Map(), new Map(), 'stop'), 'stop');
  eq(kernelOf(lin, 'v6', new Map(), new Map(), 'update'), 'update');
  eq(kernelOf(lin, 'v6', new Map(), new Map([[lin.vmId, 'stop']]), 'update'), 'stop', 'its own Stop wins');
  eq(kernelOf(win, 'v6', new Map(), new Map([[win.vmId, 'update']]), 'update'), '', 'never for Windows');
  eq(kernelOf(amd, 'v5', new Map(), new Map(), 'update'), '', 'never for AMD v5');
});

test('a machine keeps its own choice only where it differs from the default', () => {
  const k = new Map();
  setKernelChoice(k, lin.vmId, 'update', 'stop');
  eq(k.get(lin.vmId), 'update');
  setKernelChoice(k, lin.vmId, 'stop', 'stop');
  ok(!k.has(lin.vmId), 'back to the default is no choice of its own');
  setKernelChoice(k, lin.vmId, 'stop', 'update');
  eq(k.get(lin.vmId), 'stop');
});

test('Save sends a machine\'s own choice where it is offered and differs from the default', () => {
  const kernels = new Map([[lin.vmId, 'update'], [win.vmId, 'update'], [amd.vmId, 'update']]);
  const body = targetChoicesBody([lin, win, amd], 'current', new Map([[amd.vmId, 'v5']]), new Map(), new Map(), kernels, 'stop');
  eq(body.find(c => c.vmId === lin.vmId).kernel, 'update');
  eq(body.find(c => c.vmId === win.vmId).kernel, undefined, 'never for Windows');
  eq(body.find(c => c.vmId === amd.vmId).kernel, undefined, 'never for AMD v5');
  const same = targetChoicesBody([lin], 'current', new Map(), new Map(), new Map(), new Map(), 'update');
  eq(same[0].kernel, undefined, 'the default travels once, as kernelDefault');
  const before = targetChoicesBody([lin], 'current', new Map(), new Map(), new Map());
  eq(before[0].kernel, undefined, 'a caller from before this change sends none');
});

// KERNEL-UX-1: the page shows no default any more, so it always saves Stop and
// ask as the default, and each machine set to Update the kernel says so itself.
test('the save request sends Stop and ask as the default', () => {
  const src = read('wizard.html');
  ok(hasLine(src, 'default: tDefault, kernelDefault: tKernelDef, adviceVersion'), 'the body names the default');
  ok(/^const tKernelDef = 'stop';\r?$/m.test(src), 'and the default is a constant, Stop and ask');
  ok(!/tKernelDef\s*=[^=]/.test(src.replace(/^const tKernelDef = 'stop';\r?$/m, '')), 'that nothing sets again');
  ok(hasLine(src, 'tKernelSel = kernelChoicesFrom(targetChoices, targetAdvice.machines);'), 'a saved file is read by kernelChoicesFrom');
});

// KERNEL-DEFAULT-EARLIER-1: this page always saves Stop and ask as the
// default, and the service and Set-VmfTargetChoice refuse another one, so the
// page reads each machine's own choice only.
const kernelChoicesFrom = lift('wizard.html', 'kernelChoicesFrom');
const lin2 = machine('lin-02', 'Linux', [opt('v6', 'nvme-conversion', true)]);
test('RUN: KERNEL-DEFAULT-EARLIER-1: a saved default is never read into a machine', () => {
  ok(!/kernelDefault/.test(kernelChoicesFrom.toString()), 'kernelChoicesFrom reads no kernelDefault');
  const k = kernelChoicesFrom({ kernelDefault: 'update', choices: [{ vmId: lin.vmId, option: 'v6' }, { vmId: lin2.vmId, option: 'v6', kernel: 'stop' }] }, [lin, lin2]);
  eq(k.size, 0, 'only a machine set to Update the kernel has that choice');
  const now = kernelChoicesFrom({ kernelDefault: 'stop', choices: [{ vmId: lin.vmId, option: 'v6', kernel: 'update' }, { vmId: lin2.vmId, option: 'v6' }] }, [lin, lin2]);
  eq([...now], [[lin.vmId, 'update']], 'a save from now: only the machines set to Update the kernel');
  eq(kernelChoicesFrom({ choices: [{ vmId: lin.vmId, option: 'v6' }] }, [lin]).size, 0, 'a file with no default reads as Stop and ask');
  eq(kernelChoicesFrom(null, [lin]).size, 0, 'and so does no file');
});

test('a kernel choice changed on the screen and not saved is saved before the export', () => {
  const picks = new Map([[lin.vmId, 'v6']]);
  const saved = { adviceVersion: 'v1', default: 'current', kernelDefault: 'stop', choices: [{ vmId: lin.vmId, option: 'v6', kernel: 'update' }] };
  eq(exportState([lin], picks, saved, 'v1', new Map(), new Map(), 'current', new Map([[lin.vmId, 'update']]), 'stop').saved, true, 'saved as shown');
  eq(exportState([lin], picks, saved, 'v1', new Map(), new Map(), 'current', new Map(), 'stop').saved, false, 'Stop on screen, Update saved');
  const plain = { adviceVersion: 'v1', default: 'current', choices: [{ vmId: lin.vmId, option: 'v6' }] };
  eq(exportState([lin], picks, plain, 'v1', new Map(), new Map(), 'current', new Map(), 'stop').saved, true, 'a file from before this change reads as Stop');
  eq(exportState([lin], picks, plain, 'v1', new Map(), new Map(), 'current', new Map([[lin.vmId, 'update']]), 'stop').saved, false, 'Update on screen, Stop saved');
  // KERNEL-DEFAULT-EARLIER-1: the saved default is not read - each machine's
  // own choice is what was saved.
  ok(!/saved\.kernelDefault/.test(exportState.toString()), 'exportState reads no saved kernelDefault');
  const other = { adviceVersion: 'v1', default: 'current', kernelDefault: 'update', choices: [{ vmId: lin.vmId, option: 'v6' }] };
  eq(exportState([lin], picks, other, 'v1', new Map(), new Map(), 'current', new Map(), 'stop').saved, true,
    'Stop and ask on screen, and no machine choice saved: saved as shown');
});

test('the choice has words, and its help opens with a way back', () => {
  const UX = liftConst('wizard.html', 'UX');
  eq(UX.tKernelChoice.stop, 'Stop and ask');
  eq(UX.tKernelChoice.update, 'Update the kernel');
  ok(UX.tKernelHelp && UX.tKernelAbout && UX.tKernelTitle && UX.tKernelWhy && UX.tKernelHint.stop && UX.tKernelHint.update, 'the section and its help');
  ok(!('colKernel' in UX) && !('tKernelDefault' in UX), 'the column and the default list are gone (KERNEL-UX-1)');
  // RHEL-PINNED-KERNEL-ADVICE-1: the update uses only the repositories the
  // machine has, and a Red Hat image for one minor release is on EUS
  // repositories held to that release (Microsoft, Red Hat Update
  // Infrastructure). The product cannot read the repositories before the
  // move, so the help says it before the person chooses.
  ok(/repositories that the machine uses/.test(UX.tKernelHelp), 'the help says the update uses only the repositories of the machine');
  ok(/EUS repositories/.test(UX.tKernelHelp) && /non-EUS repositories/.test(UX.tKernelHelp), 'and names the EUS repositories and the way out');
});

// KERNEL-UX-1: the choice is in the Details of each Linux machine whose target
// can use MANA, an amber dot marks the Details until they are opened, and a
// notice above the tables - which names no machine - sets every machine still
// to check at once. RUN: the page's own functions.
const UXW = liftConst('wizard.html', 'UX');
const rowSet = () => {
  global.UX = UXW;
  global.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
  global.esc = (v) => String(v ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  global.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
  global.tDefault = 'current'; global.tOverrides = new Map(); global.tSizes = new Map(); global.tDiskSel = new Map();
  global.tOpen = new Set(); global.tSelected = new Set(); global.tHelp = new Set();
  global.tKernelSel = new Map(); global.tKernelDef = 'stop'; global.tKSeen = new Set(); global.tTSeen = new Set(); global.tASeen = new Set();
  global.targetAdvice = { machines: [lin, lin2, win, amd] };
};
const K = liftAll('wizard.html', ['tHelpBtn', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'sizeListMixed', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'oldShape', 'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advWhy', 'advDetailRows',
  'kernelSectionHtml', 'eusImageText', 'kernelToCheck', 'kernelNoticeHtml', 'kernelSetAll', 'tCountText', 'tempLost', 'tDotWhy', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml', 'sizeOf']);
const dotted = (html) => /class="btn small ghost t-det t-kdot"/.test(html);
const section = (html) => html.includes('class="sec t-ksec"');
const amdOnV5 = new Map([[amd.vmId, 'v5']]);

test('RUN: a Linux machine whose target can use MANA gets the section and the dot - Windows and AMD v5 never', () => {
  rowSet(); global.tOverrides = amdOnV5;
  ok(dotted(K.tTargetRow(lin)), 'Linux on v6: the dot');
  ok(!dotted(K.tTargetRow(win)), 'Windows: no dot');
  ok(!dotted(K.tTargetRow(amd)), 'AMD v5: no dot');
  for (const m of [lin, win, amd]) global.tOpen.add(m.vmId);
  const open = K.tTargetRow(lin);
  ok(section(open), 'Linux: the section is in Details');
  ok(open.indexOf('class="sec t-ksec"') < open.indexOf(UXW.tWhatChanges.split('{')[0]), 'and it comes first');
  ok(open.includes(esc(fill(UXW.tKernelTitle, { name: 'lin-01' }))), 'with the machine in its title');
  eq((open.match(/type="radio" name="t-k-[^"]+" class="t-kernel"/g) || []).length, 2, 'two radio buttons');
  ok(open.includes(`value="stop" checked`), 'Stop and ask is chosen when nothing else is');
  ok(open.includes(`role="radiogroup" aria-label="${esc(fill(UXW.tKernelTitle, { name: 'lin-01' }))}"`), 'the group has a name');
  ok(!section(K.tTargetRow(win)), 'Windows: no section');
  ok(!section(K.tTargetRow(amd)), 'AMD v5: no section');
  global.tKernelSel = new Map([[lin.vmId, 'update']]);
  ok(K.tTargetRow(lin).includes(`value="update" checked`), 'a machine set to Update the kernel shows it');
});

test('RUN: the dot goes once the Details were opened, and each section has its own help', () => {
  rowSet();
  ok(dotted(K.tTargetRow(lin)));
  ok(K.tTargetRow(lin).includes(`aria-label="${UXW.tDetails}: ${UXW.tKernelCheck}"`), 'a screen reader hears it too');
  global.tKSeen.add(lin.vmId);
  ok(!dotted(K.tTargetRow(lin)), 'seen: no dot');
  global.tOpen.add(lin.vmId); global.tOpen.add(lin2.vmId);
  const a = K.tTargetRow(lin), b = K.tTargetRow(lin2);
  ok(a.includes('data-help="kernel-0"') && b.includes('data-help="kernel-1"'), 'two open Details never share one help');
  global.tHelp.add('kernel-1');
  ok(!K.tTargetRow(lin).includes('id="t-help-kernel-'), 'the help of one machine opens alone');
  ok(K.tTargetRow(lin2).includes(`id="t-help-kernel-1">${esc(UXW.tKernelHelp)}`), 'in its own section');
});

test('RUN: the notice shows while a machine is still to check, names no machine, and goes when none is', () => {
  rowSet(); global.tOverrides = amdOnV5;
  const all = [lin, lin2, win, amd];
  const check = () => K.kernelToCheck(all, 'current', amdOnV5, new Map(), global.tKernelSel, global.tKSeen);
  eq(check().map(m => m.name), ['lin-01', 'lin-02'], 'the two Linux machines whose target can use MANA');
  const html = K.kernelNoticeHtml(check());
  ok(html.includes(esc(UXW.tKernelAlert)), 'what the dot means');
  ok(html.includes(`data-kall="stop">${esc(UXW.tKernelAll.stop)}</button>`) && html.includes(`data-kall="update">${esc(UXW.tKernelAll.update)}</button>`), 'two buttons');
  ok(!/lin-0|win-0|amd-0/.test(html), 'no machine named');
  global.tKSeen.add(lin.vmId);
  eq(check().map(m => m.name), ['lin-02'], 'one opened, one to check');
  global.tKSeen.add(lin2.vmId);
  eq(check().length, 0);
  eq(K.kernelNoticeHtml(check()), '', 'no notice when none is to check');
  eq(K.kernelNoticeHtml(K.kernelToCheck([win, amd], 'current', amdOnV5, new Map(), new Map(), new Set())), '', 'none with no such machine');
});

// KERNEL-CHOICE-WORDS-1 (approved words, 2026-11-14): the notice and the
// line of each machine say what the product does IF Checking finds the kernel
// below the minimum - never that the kernel needs an update. The old words
// read as a finding on a machine that then passed Checking.
test('KERNEL-CHOICE-WORDS-1: the words say what happens if Checking finds the kernel below the minimum', () => {
  eq(UXW.tKernelAlert, 'The product reads the kernel of each Linux machine at Checking. Choose what it does if the kernel has no MANA driver for the new size.');
  // WAVE-KERNEL-LINE-1: the line of each machine under a wave kernel setting
  // went with the setting; the row that names these machines says it as a
  // condition already (tests/js/wave-kernel-line.test.js).
  const UXV = liftConst('waves.html', 'UX');
  for (const s of [UXW.tKernelAlert, UXV.kernelLabel]) {
    ok(!/needs? (an )?update|kernel is old|has no MANA driver\./i.test(s), `no finding: ${s}`);
  }
  // The choice keeps its two places: the notice has the two All buttons.
  const html = K.kernelNoticeHtml([lin]);
  ok(html.includes('data-kall="stop"') && html.includes('data-kall="update"'), 'the two All buttons stay');
});
test('RUN: an All button sets every machine still to check, marks each one seen, and leaves the others', () => {
  rowSet();
  const kernels = new Map([[lin2.vmId, 'update']]);
  const seen = new Set([lin2.vmId]);   // opened and set to Update the kernel by hand
  const lin3 = machine('lin-03', 'Linux', [opt('v6', 'nvme-conversion', true)]);
  const toCheck = K.kernelToCheck([lin, lin2, lin3, win], 'current', new Map(), new Map(), kernels, seen);
  K.kernelSetAll(toCheck, 'update', kernels, seen);
  eq(kernels.get(lin.vmId), 'update'); eq(kernels.get(lin3.vmId), 'update');
  ok(!kernels.has(win.vmId), 'Windows is never set');
  ok(seen.has(lin.vmId) && seen.has(lin3.vmId) && !seen.has(win.vmId), 'each one set counts as seen');
  K.kernelSetAll([lin, lin3], 'stop', kernels, seen);
  ok(!kernels.has(lin.vmId) && !kernels.has(lin3.vmId), 'All: stop and ask clears them back to Stop and ask');
  eq(kernels.get(lin2.vmId), 'update', 'a machine already checked keeps its own choice');
  const src = read('wizard.html');
  ok(hasLine(src, 'kernelSetAll(kernelToCheck(machines, tDefault, tOverrides, tSizes, tKernelSel, tKSeen), b.dataset.kall, tKernelSel, tKSeen);'), 'the buttons call it');
  ok(src.includes('const machines = tMachines();\n  tMarkSeen(machines);') && hasLine(src, 'tMarkSeen(machines);'), 'each drawing of the step marks what open Details show (tMarkSeen)');
});

// Review finding 2: opening Details with no choice in them is not a check. A
// Linux machine on AMD v5 has no choice; opened, then moved to v6, it must
// still have its dot - and it counts as seen once its open Details show it.
const markSeen = liftAll('wizard.html', ['tMarkSeen', 'tempLost', 'anKept', 'anLost', 'sizeOf']).tMarkSeen;
test('RUN: open Details count as a check only when they show the choice (review finding 2)', () => {
  rowSet();
  global.tOverrides = new Map([[amd.vmId, 'v5']]);
  global.tOpen.add(amd.vmId); global.tOpen.add(win.vmId);
  markSeen([amd, win, lin]);
  ok(!global.tKSeen.has(amd.vmId), 'AMD v5 open: no choice shown, not seen');
  ok(!global.tKSeen.has(win.vmId), 'Windows open: not seen');
  ok(!global.tKSeen.has(lin.vmId), 'closed: not seen');
  global.tOverrides = new Map([[amd.vmId, 'v6']]);
  global.tOpen.delete(amd.vmId);
  ok(dotted(K.tTargetRow(amd)), 'moved to v6 with Details closed: the dot shows');
  eq(K.kernelToCheck([amd], 'current', global.tOverrides, new Map(), global.tKernelSel, global.tKSeen).length, 1, 'and the notice counts it');
  global.tOpen.add(amd.vmId);
  markSeen([amd]);
  ok(global.tKSeen.has(amd.vmId), 'opened on v6: the choice shows, so it is seen');
});

// Review finding 1: a machine's own Stop and ask writes nothing to the plan,
// so the wave setting decides. AN-PROCEED-NETVSC-1 (2026-11-06): the
// wave setting is Stop and ask only, so the hint now says the stop, and never
// offers Continue.
test('the hints say what each choice really does', () => {
  ok(/stops before anything is changed/.test(UXW.tKernelHint.stop), 'Stop and ask says the stop: ' + UXW.tKernelHint.stop);
  ok(!/Continue/.test(UXW.tKernelHint.stop), 'and offers no Continue');
  ok(!/is rolled back/.test(UXW.tKernelHint.update), 'active voice');
});

// KERNEL-HINT-UNTOUCHED-1: Update the kernel has two outcomes when it cannot
// give the driver. No newer kernel in the repositories of the machine, or no
// rule for its kernel, stops it before anything is changed
// (kernelNotInRepositories, BLOCKED: Invoke-VmfKernelUpdateStep). Only an
// update that ran and failed rolls it back. The line and the help say both,
// each in its own sentence, so neither outcome takes the words of the other.
test('Update the kernel says the stop with nothing changed and the rollback, each for its own outcome', () => {
  const sentences = (s) => s.split(/(?<=\.)\s+/);
  for (const [name, text] of [['the line', UXW.tKernelHint.update], ['the help', UXW.tKernelHelp]]) {
    const all = sentences(text);
    const none = all.filter((x) => /no update is possible/.test(x));
    const failed = all.filter((x) => /update fails/.test(x));
    eq(none.length, 1, name + ' has one sentence for no update: ' + text);
    ok(/stops before anything is changed/.test(none[0]) && !/roll/.test(none[0]), name + ': no update stops with nothing changed: ' + none[0]);
    eq(failed.length, 1, name + ' has one sentence for a failed update: ' + text);
    ok(/rolls the machine back/.test(failed[0]) && !/stops/.test(failed[0]), name + ': a failed update rolls the machine back: ' + failed[0]);
    ok(all.indexOf(none[0]) < all.indexOf(failed[0]), name + ': the stop comes before the rollback, in the order they can happen');
  }
  ok(UXW.tKernelHint.update.split(/\s+/).length <= 35, 'the line stays short: ' + UXW.tKernelHint.update);
});

test('RUN: each area heading counts its machines, one and many', () => {
  rowSet();
  eq(K.tCountText(1), '1 machine');
  eq(K.tCountText(3), '3 machines');
  eq(K.tCountText(0), '0 machines');
});

test('the Run it step names the machines that update their kernel, and shows no kernel setting of the wave', () => {
  const UX = liftConst('wizard.html', 'UX');
  global.UX = UX;
  global.esc = (v) => String(v ?? '');
  global.vmName = (id) => String(id).split('/').pop();
  global.anTurnsOnNames = () => [];
  global.anDecidedNames = () => [];
  global.newIdentityNames = () => [];
  // WIZARD-OPTIONS-DISKS-1: the disk row is not what this test reads.
  global.diskChangeTexts = () => [];
  global.kernelUpdateNames = (wave) => (global.plan.entries).filter(e => e.wave === wave && ['A', 'B'].includes(e.path) && e.policy?.onDriverBelowFloor === 'updateKernel').map(e => vmName(e.vmId));
  global.plan = { entries: [
    { vmId: SUB + 'lin-01', wave: 'w1', path: 'A', policy: { onDriverBelowFloor: 'updateKernel' }, decisions: [{ setting: 'onDriverBelowFloor', by: 'operator@example.com', utc: 'x' }] },
    { vmId: SUB + 'lin-02', wave: 'w1', path: 'A', policy: { onDriverBelowFloor: 'proceed' } },
    { vmId: SUB + 'win-01', wave: 'w2', path: 'B', policy: { onDriverBelowFloor: 'stop' } },
  ] };
  const own = lift('wizard.html', 'kernelUpdateNames');
  eq(own('w1'), ['lin-01']);
  eq(own('w2'), []);
  const rows = lift('wizard.html', 'leverRowsFor')('w1');
  ok(rows.includes(`<td class="muted">${UX.lvKernel}</td><td>lin-01</td>`), 'the machine is named');
  // WAVE-KERNEL-LINE-1: no row for a kernel setting of the wave, so no line
  // says the machine does not follow one.
  ok(!rows.includes('If the kernel is below the minimum version'), 'no wave kernel setting');
  ok(!rows.includes('does not follow this setting'), 'and the machine is not said to differ from its wave');
  eq(UX.lvDriverProceed, undefined, 'and there is no Continue to show');
  ok(lift('wizard.html', 'leverRowsFor')('w2').includes(`<td class="muted">${UX.lvKernel}</td><td>${UX.lvNone}</td>`), 'none in a wave without one');
});

test('the wave\'s acceptance names them too, and reads the wave\'s own setting', () => {
  const src = read('migrations.html');
  const constArrow = (name) => {
    const m = src.match(new RegExp(`const ${name} = ([\\s\\S]*?);\\n`));
    if (!m) throw new Error('could not read ' + name);
    // eslint-disable-next-line no-eval
    return eval('(' + m[1] + ')');
  };
  global.vmName = (id) => String(id).split('/').pop();
  const names = constArrow('kernelUpdateNames');
  const entries = [
    { vmId: SUB + 'lin-01', policy: { onDriverBelowFloor: 'updateKernel' }, decisions: [{ setting: 'onDriverBelowFloor' }] },
    { vmId: SUB + 'lin-02', policy: { onDriverBelowFloor: 'stop' } },
  ];
  eq(names(entries), ['lin-01']);
  // AN-PROCEED-NETVSC-1: the setting has one value now, so the acceptance reads no machine for it.
  ok(!src.includes('driverLeverOf'), 'no reading of the wave setting');
  ok(src.includes("[UX_LEVER.kernelMachines, kernelUpdateNames(entries).join(', ') || UX_LEVER.identityNone],"), 'a row of the acceptance table');
});

test('the wave card has no kernel setting, and names who chose Update the kernel on its own row', () => {
  const UX = liftConst('waves.html', 'UX');
  global.UX = UX;
  global.esc = (v) => String(v ?? '');
  global.vmName = (id) => String(id).split('/').pop();
  const card = waveRuleGlobal();
  const decided = (n) => ({ vmId: n, wave: 'w', policy: { onDriverBelowFloor: 'updateKernel' }, decisions: [{ setting: 'onDriverBelowFloor' }] });
  // WAVE-KERNEL-LINE-1: no wave has a kernel setting, so no machine keeps its own.
  const all = card.waveCard([decided('a'), decided('b')]);
  eq(all.values.onDriverBelowFloor, undefined, 'no kernel value on the card');
  eq(all.own.onDriverBelowFloor, undefined, 'and no machine that does not follow it');
  global.membersOf = () => [decided(SUB + 'a'), { vmId: SUB + 'c', policy: { onDriverBelowFloor: 'stop' } }];
  const row = lift('waves.html', 'kernelRow')('w');
  ok(row.includes(UX.kernelLabel) && row.includes('>a<'), row);
  global.membersOf = () => [{ vmId: SUB + 'c', policy: { onDriverBelowFloor: 'stop' } }];
  ok(lift('waves.html', 'kernelRow')('w').includes(UX.kernelNone), 'None in this wave when no machine chose it');
});

test('the run page has words for the update step', () => {
  const src = read('migrations.html');
  ok(src.includes("[/runcmd:kernel-update/,        'guestKernel'],"), 'the guest script has its own label');
  const UX_STEP = liftConst('migrations.html', 'UX_STEP');
  ok(UX_STEP.guestKernel, 'and the label exists');
});

run('kernel-choice');
