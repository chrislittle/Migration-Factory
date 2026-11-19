// OLD-SKU-1B: on the Choose each target page, a Generation 1 machine or one on
// an old size chooses its v5 FAMILY (D or E) and SIZE (the default, or a
// constrained size with fewer active vCPUs).
//
// Since 2026-09-29, a customer with a Generation 1 machine on an old Dv2 size
// picks the family, and a constrained vCPU, customized or default size.
// Customized cores is OLD-SKU-1D.
//
// RUN: the page's own functions, lifted out of wizard.html.
'use strict';
const { pageSource } = require('./_page-source');
const { lift, test, eq, ok, run } = require('./_harness');
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });
Object.assign(global, require('./_harness').liftAll('wizard.html', ['advSeriesLabel']));
// REBUILD-PICKER-1: the method rule the details and the save read.
Object.assign(global, require('./_harness').liftAll('wizard.html', ['tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tRecommended']));
global.sizeOf = lift('wizard.html', 'sizeOf');

const sizeOf = lift('wizard.html', 'sizeOf');
const setSize = lift('wizard.html', 'setSize');
const savedSizes = lift('wizard.html', 'savedSizes');
global.sizeOf = sizeOf;
global.savedSizes = savedSizes;
global.savedDisks = lift('wizard.html', 'savedDisks');
const premiumOf = lift('wizard.html', 'premiumOf');
const disksOf = lift('wizard.html', 'disksOf');
global.premiumOf = premiumOf;
global.disksOf = disksOf;
global.diskChoicesOf = lift('wizard.html', 'diskChoicesOf');
global.osDiskTypes = lift('wizard.html', 'osDiskTypes');
// MANA-LINUX-KERNEL-1: the save body asks each machine for its kernel choice too.
global.kernelOffered = lift('wizard.html', 'kernelOffered');
global.kernelOf = lift('wizard.html', 'kernelOf');
global.csvCell = lift('wizard.html', 'csvCell');
global.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
global.fill = (t, v) => String(t).replace(/\{(\w+)\}/g, (_, k) => String(v[k]));
global.UX = { vBsv2Why: {}, tConstrained: '{size}, {n} active vCPUs', vDisks3: { keep: 'No change', os: 'OS disk to Premium SSD', all: 'Every disk to Premium SSD' } };
const pricingCsv = lift('wizard.html', 'pricingCsv');
const exportState = lift('wizard.html', 'exportState');
const sizeChoiceLabel = lift('wizard.html', 'sizeChoiceLabel');
const advDetailRows = lift('wizard.html', 'advDetailRows');
global.advPick = lift('wizard.html', 'advPick');
const targetChoicesBody = lift('wizard.html', 'targetChoicesBody');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/';
// Each choice carries the facts of its own size. The facts here are made
// up so the two choices disagree: the page only paints what it is given.
// (Since DRIFT-5, Microsoft requires accelerated networking on E8ds_v5 too.)
const facts = (required) => ({ path: 'A', rebuild: false, tempDisksTo: 1, sizeUnverified: false,
  acceleratedNetworking: { required, mayUseMana: true, turnsOn: required }, stops: required ? ['acceleratedNetworkingRequired'] : [] });
const CHOICES = [
  { size: 'Standard_D8ds_v5', family: 'D', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 32, best: true, ...facts(true) },
  { size: 'Standard_E8ds_v5', family: 'E', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 64, best: false, ...facts(false) },
  { size: 'Standard_E8-4ds_v5', family: 'E', variant: 'constrained', vcpus: 8, activeVcpus: 4, memoryGB: 64, best: false, ...facts(false) },
];
const old = (name) => ({
  vmId: `${SUB}rg-app/providers/Microsoft.Compute/virtualMachines/${name}`, name, gen: 'V1', os: 'Windows',
  location: 'centralus', sourceSize: 'Standard_D4_v2',
  acceleratedNicCount: 0,
  options: [{ option: 'v5', supported: true, targetSize: 'Standard_D8ds_v5', sizeChoices: CHOICES, move: 'scsi-resize', tempDisksFrom: 1, ...facts(true) },
            { option: 'v6', supported: false, targetSize: null, sizeChoices: [] }],
  start: { current: 'v5', extended: 'v5' },
});

test('the size is the chosen one when it is a choice, and the option\'s own size otherwise', () => {
  const m = old('old-01');
  eq(sizeOf(m, 'v5', new Map()), 'Standard_D8ds_v5', 'nothing chosen: the best choice the options already name');
  eq(sizeOf(m, 'v5', new Map([[m.vmId, 'Standard_E8-4ds_v5']])), 'Standard_E8-4ds_v5');
  eq(sizeOf(m, 'v5', new Map([[m.vmId, 'Standard_E16ds_v5']])), 'Standard_D8ds_v5', 'a size that is not a choice is never shown or sent');
  eq(sizeOf(m, 'v6', new Map([[m.vmId, 'Standard_E8ds_v5']])), '', 'no target on v6, whatever was chosen for v5');
  eq(sizeOf(m, '', new Map()), '');
});

test('choosing the option\'s own size is the same as choosing none, as the engine keeps it', () => {
  const m = old('old-01');
  const sizes = new Map();
  setSize(sizes, m, 'v5', 'Standard_E8ds_v5');
  eq(sizes.get(m.vmId), 'Standard_E8ds_v5');
  setSize(sizes, m, 'v5', 'Standard_D8ds_v5');
  ok(!sizes.has(m.vmId), 'back to the best choice: nothing kept');
});

test('a constrained size says how many vCPUs are active', () => {
  eq(sizeChoiceLabel(CHOICES[2]), 'E8-4ds_v5, 4 active vCPUs');
  eq(sizeChoiceLabel(CHOICES[1]), 'E8ds_v5');
});

test('the details show the chosen size, its vCPUs and its memory', () => {
  global.UX = Object.assign(global.UX, { dSize: 'Size', dCores: 'vCPUs and memory', vCores: '{n} vCPUs, {gb} GiB',
    vCoresActive: '{n} vCPUs ({active} active), {gb} GiB', dKind: 'k', dController: 'c', dTemp: 't', dAn: 'a', dLife: 'l',
    dRollback: 'r', vYes: 'Yes', vScsi: 'SCSI', vNvme: 'NVMe', vUnknown: '?', vNone: 'None', vOneDisk: '1', vDisks: '{n}',
    vOn: 'On', vOff: 'Off', vOnRequired: 'On!', vNotListed: '-', vNoChange: '', kNvme: 'n', kResize: 'z', kRebuild: 'B' });
  const m = old('old-01');
  const rows = new Map(advDetailRows(m, 'v5', 'Standard_E8-4ds_v5'));
  ok(String(rows.get('Size')).endsWith('E8-4ds_v5'), rows.get('Size'));
  eq(rows.get('vCPUs and memory'), '8 vCPUs (4 active), 64 GiB');
  eq(new Map(advDetailRows(m, 'v5')).get('vCPUs and memory'), '8 vCPUs, 32 GiB', 'no size given: the option\'s own');
});

test('THE REVIEW CASE: accelerated networking and the approval follow the chosen size', () => {
  global.UX = Object.assign(global.UX, { dApproval: 'Approval', vApprovalStop: 'Turned on when you accept the wave settings' });
  const m = old('old-01');
  const onD = new Map(advDetailRows(m, 'v5', 'Standard_D8ds_v5'));
  eq(onD.get('Accelerated networking') ?? onD.get('a'), 'Off  →  On!', 'D8ds_v5 requires it');
  ok(onD.has('Approval'), 'and stops for approval');
  const onE = new Map(advDetailRows(m, 'v5', 'Standard_E8ds_v5'));
  eq(onE.get('a'), 'Off  →  Off', 'the second choice, given facts that do not require it, does not');
  ok(!onE.has('Approval'), 'and no approval stop');
});

test('the pricing file counts and lists the SAVED size', () => {
  const m = old('old-01');
  const csv = pricingCsv([m], new Map([[m.vmId, 'v5']]), new Map([[m.vmId, 'Standard_E8-4ds_v5']])).split('\r\n');
  ok(csv.includes('centralus,Windows,E8-4ds_v5,1'), csv.join(' | '));
  ok(csv.includes('old-01,rg-app,centralus,Windows,D4_v2,v5,E8-4ds_v5,No change,?,?'), csv.join(' | '));
  ok(pricingCsv([m], new Map([[m.vmId, 'v5']])).includes('D8ds_v5'), 'no sizes: the option\'s own size');
});

// PRICE-EXPORT-1 (issue 423): this held the export BACK. The export now saves
// first, so the same cases say whether a press must save before it downloads.
test('a size changed on the screen and not saved is saved before the export', () => {
  const m = old('old-01');
  const picks = new Map([[m.vmId, 'v5']]);
  const saved = { adviceVersion: 'v1', choices: [{ vmId: m.vmId, option: 'v5', size: 'Standard_E8ds_v5' }] };
  eq(exportState([m], picks, saved, 'v1', new Map([[m.vmId, 'Standard_E8ds_v5']])).saved, true, 'saved as shown');
  eq(exportState([m], picks, saved, 'v1', new Map([[m.vmId, 'Standard_E8-4ds_v5']])).saved, false, 'another size on screen');
  eq(exportState([m], picks, saved, 'v1', new Map()).saved, false, 'back to the best on screen, E8ds_v5 saved');
  const plain = { adviceVersion: 'v1', choices: [{ vmId: m.vmId, option: 'v5', size: null }] };
  eq(exportState([m], picks, plain, 'v1', new Map()).saved, true, 'none saved and none chosen');
});

test('the save sends the size only when it is not the option\'s own', () => {
  const a = old('old-01'), b = old('old-02'), c = old('old-03');
  const sizes = new Map([[a.vmId, 'Standard_E8-4ds_v5'], [c.vmId, 'Standard_E16ds_v5']]);
  const body = targetChoicesBody([a, b, c], 'current', new Map(), sizes);
  eq(JSON.stringify(body[0]), JSON.stringify({ vmId: a.vmId, option: 'v5', size: 'Standard_E8-4ds_v5', method: 'in-place' }));
  eq(JSON.stringify(body[1]), JSON.stringify({ vmId: b.vmId, option: 'v5', method: 'in-place' }), 'none chosen: no size');
  eq(JSON.stringify(body[2]), JSON.stringify({ vmId: c.vmId, option: 'v5', method: 'in-place' }), 'a size that is not a choice is never sent');
  const src = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  // MACHINE-PICK-1: the chosen machines only (tMachines), not every machine the options cover.
  // MANA-LINUX-KERNEL-1: with the kernel choices and their default.
  // TEMP-DISK-PREVIEW-1: and the kind of change each row is on.
  ok(src.includes('const choices = targetChoicesBody(tMachines(), tDefault, tOverrides, tSizes, tDiskSel, tKernelSel, tKernelDef);'), 'saveTargets sends it');
  ok(src.includes('if (c.size) tSizes.set(c.vmId, c.size);'), 'and a saved size is loaded back');
});

run('size-choices');
