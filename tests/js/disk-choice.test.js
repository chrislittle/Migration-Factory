// OLD-SKU-1C: on the Choose each target page, a machine in the second area
// (Generation 1, or an old size) may have its disks changed to Premium SSD
// during the move - the OS disk only, or every disk - on a size that takes it.
//
// Since 2026-09-29: the customer picks it per machine.
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
global.savedSizes = lift('wizard.html', 'savedSizes');
global.savedDisks = lift('wizard.html', 'savedDisks');
const premiumOf = lift('wizard.html', 'premiumOf');
const disksOf = lift('wizard.html', 'disksOf');
global.premiumOf = premiumOf;
global.disksOf = disksOf;
// HDD-OS-1: the list of choices, and the OS disk type now and after.
global.oldShape = lift('wizard.html', 'oldShape');
const diskChoicesOf = lift('wizard.html', 'diskChoicesOf');
global.osDiskTypes = lift('wizard.html', 'osDiskTypes');
global.advPick = lift('wizard.html', 'advPick');
// MANA-LINUX-KERNEL-1: the save body asks each machine for its kernel choice too.
global.kernelOffered = lift('wizard.html', 'kernelOffered');
global.kernelOf = lift('wizard.html', 'kernelOf');
global.csvCell = lift('wizard.html', 'csvCell');
global.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
global.fill = (t, v) => String(t).replace(/\{(\w+)\}/g, (_, k) => String(v[k]));
global.UX = {
  vBsv2Why: {},
  vDisks3: { keep: 'No change', 'os-standard-ssd': 'OS disk to Standard SSD', os: 'OS disk to Premium SSD', all: 'Every disk to Premium SSD' },
  vDiskTypes: { Standard_LRS: 'Standard HDD', StandardSSD_LRS: 'Standard SSD', StandardSSD_ZRS: 'Standard SSD (zone-redundant)',
    Premium_LRS: 'Premium SSD', Premium_ZRS: 'Premium SSD (zone-redundant)', PremiumV2_LRS: 'Premium SSD v2', UltraSSD_LRS: 'Ultra Disk' },
  dDisks: 'Disks', dSize: 'Size', dCores: 'c', vCores: '{n}', vCoresActive: '{n}', dKind: 'k', dController: 'ct', dTemp: 't', dAn: 'a',
  dLife: 'l', dRollback: 'r', vYes: 'Yes', vScsi: 'SCSI', vNvme: 'NVMe', vUnknown: '?', vNone: 'None', vOneDisk: '1', vDisks: '{n}',
  vOn: 'On', vOff: 'Off', vOnRequired: 'On!', vNotListed: '-', vNoChange: '', kNvme: 'n', kResize: 'z', kRebuild: 'B',
};
const targetChoicesBody = lift('wizard.html', 'targetChoicesBody');
const pricingCsv = lift('wizard.html', 'pricingCsv');
const exportState = lift('wizard.html', 'exportState');
const advDetailRows = lift('wizard.html', 'advDetailRows');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/';
// D8ds_v5 takes Premium SSD; a D8d_v5 choice (no s) does not.
const CHOICES = [
  { size: 'Standard_D8ds_v5', family: 'D', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 32, best: true, premiumDisks: true },
  { size: 'Standard_D8d_v5', family: 'D', variant: 'default', vcpus: 8, activeVcpus: 8, memoryGB: 32, best: false, premiumDisks: false },
];
const old = (name, over) => Object.assign({
  vmId: `${SUB}rg-app/providers/Microsoft.Compute/virtualMachines/${name}`, name, gen: 'V1', os: 'Linux', location: 'centralus',
  sourceSize: 'Standard_D4_v2',
  options: [{ option: 'v5', supported: true, targetSize: 'Standard_D8ds_v5', sizeChoices: CHOICES, premiumDisks: true, move: 'scsi-resize' }],
  start: { current: 'v5', extended: 'v5' },
}, over || {});

test('the disk choice counts only on a size that takes Premium SSD', () => {
  const m = old('old-01');
  const disks = new Map([[m.vmId, 'all']]);
  ok(premiumOf(m, 'v5', new Map()), 'the option\'s own size takes it');
  eq(disksOf(m, 'v5', new Map(), disks), 'all');
  const onD8d = new Map([[m.vmId, 'Standard_D8d_v5']]);
  ok(!premiumOf(m, 'v5', onD8d), 'the chosen size does not');
  eq(disksOf(m, 'v5', onD8d, disks), '', 'so the choice is not kept');
  const unknown = old('old-02', { options: [{ option: 'v5', supported: true, targetSize: 'Standard_D8ds_v5', sizeChoices: [], premiumDisks: null }] });
  eq(disksOf(unknown, 'v5', new Map(), new Map([[unknown.vmId, 'os']])), '', 'unknown is not a yes');
  eq(disksOf(m, 'v5', new Map(), new Map([[m.vmId, 'keep']])), '', 'keep is no choice');
});

test('the save sends the disk choice only where it counts', () => {
  const a = old('old-01'), b = old('old-02'), c = old('old-03');
  const body = targetChoicesBody([a, b, c], 'current', new Map(),
    new Map([[c.vmId, 'Standard_D8d_v5']]), new Map([[a.vmId, 'os'], [c.vmId, 'all']]));
  eq(JSON.stringify(body[0]), JSON.stringify({ vmId: a.vmId, option: 'v5', method: 'in-place', disks: 'os' }));
  eq(JSON.stringify(body[1]), JSON.stringify({ vmId: b.vmId, option: 'v5', method: 'in-place' }), 'none chosen');
  eq(JSON.stringify(body[2]), JSON.stringify({ vmId: c.vmId, option: 'v5', size: 'Standard_D8d_v5', method: 'in-place' }), 'a size that takes no Premium SSD sends none');
});

test('the pricing file says the SAVED disk choice for each machine', () => {
  const a = old('old-01'), b = old('old-02');
  const csv = pricingCsv([a, b], new Map([[a.vmId, 'v5'], [b.vmId, 'v5']]), new Map(), new Map([[a.vmId, 'all']])).split('\r\n');
  ok(csv.includes('old-01,rg-app,centralus,Linux,D4_v2,v5,D8ds_v5,Every disk to Premium SSD,?,?'), csv.join(' | '));
  ok(csv.includes('old-02,rg-app,centralus,Linux,D4_v2,v5,D8ds_v5,No change,?,?'), csv.join(' | '));
});

// PRICE-EXPORT-1 (issue 423): this held the export BACK. The export now saves
// first, so the same cases say whether a press must save before it downloads.
test('a disk choice changed on the screen and not saved is saved before the export', () => {
  const m = old('old-01');
  const picks = new Map([[m.vmId, 'v5']]);
  const saved = { adviceVersion: 'v1', choices: [{ vmId: m.vmId, option: 'v5', size: null, disks: 'os' }] };
  eq(exportState([m], picks, saved, 'v1', new Map(), new Map([[m.vmId, 'os']])).saved, true, 'saved as shown');
  eq(exportState([m], picks, saved, 'v1', new Map(), new Map([[m.vmId, 'all']])).saved, false, 'another choice on screen');
  eq(exportState([m], picks, saved, 'v1', new Map(), new Map()).saved, false, 'keep on screen, os saved');
});

test('the details say what happens to the disks, where a choice can be made', () => {
  const m = old('old-01');
  eq(new Map(advDetailRows(m, 'v5', 'Standard_D8ds_v5', 'all')).get('Disks'), 'Every disk to Premium SSD');
  eq(new Map(advDetailRows(m, 'v5', 'Standard_D8ds_v5', '')).get('Disks'), 'No change');
  ok(!new Map(advDetailRows(m, 'v5', 'Standard_D8ds_v5')).has('Disks'), 'the first area has no disk choice, and no row');
});

test('the list is in the second area only, and every state has words', () => {
  const src = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  ok(src.includes('const diskKeys = diskChoicesOf(m, pick, tSizes);') && src.includes('if (diskKeys.length > 1) {'), 'the list is drawn where it offers more than keep');
  ok(src.includes("tDiskChoice: { keep: 'Keep the disk types', 'os-standard-ssd': 'Standard SSD: OS disk', os: 'Premium SSD: OS disk', all: 'Premium SSD: every disk' },"));
  ok(src.includes('if (c.disks) tDiskSel.set(c.vmId, c.disks);'), 'a saved choice is loaded back');
});

// HDD-OS-1: Microsoft retires Standard HDD as an OS disk type on 8 September
// 2028. A machine whose OS disk is Standard HDD is offered Standard SSD for it,
// in BOTH areas and on any size: every size takes Standard SSD.
const hdd = (name, over) => old(name, Object.assign({ osDiskType: 'Standard_LRS' }, over || {}));
const first = (name, over) => hdd(name, Object.assign({ gen: 'V2', sourceSize: 'Standard_D2s_v4',
  options: [{ option: 'v5', supported: true, targetSize: 'Standard_D2s_v5', sizeChoices: [], premiumDisks: true, move: 'scsi-resize' }] }, over || {}));

test('HDD-OS-1: Standard SSD is offered for a Standard HDD OS disk, in both areas, on any size', () => {
  eq(diskChoicesOf(first('new-01'), 'v5', new Map()).join(','), 'keep,os-standard-ssd', 'the first area: Standard SSD only');
  eq(diskChoicesOf(hdd('old-01'), 'v5', new Map()).join(','), 'keep,os-standard-ssd,os,all', 'the second area: next to the Premium SSD choices');
  const m = hdd('old-02');
  const onD8d = new Map([[m.vmId, 'Standard_D8d_v5']]);
  eq(diskChoicesOf(m, 'v5', onD8d).join(','), 'keep,os-standard-ssd', 'a size that takes no Premium SSD still takes Standard SSD');
  eq(disksOf(m, 'v5', onD8d, new Map([[m.vmId, 'os-standard-ssd']])), 'os-standard-ssd');
});

test('HDD-OS-1: not offered where the OS disk is not Standard HDD, or its type is not known', () => {
  for (const t of ['StandardSSD_LRS', 'Premium_LRS', null, undefined]) {
    const m = first('new-02', { osDiskType: t });
    eq(diskChoicesOf(m, 'v5', new Map()).join(','), 'keep', `an OS disk on ${t}: no list`);
    eq(disksOf(m, 'v5', new Map(), new Map([[m.vmId, 'os-standard-ssd']])), '', `an OS disk on ${t}: a saved choice does not count`);
  }
  eq(diskChoicesOf(first('new-03'), '', new Map()).join(','), 'keep', 'no target: nothing to choose');
});

test('HDD-OS-1: the save sends Standard SSD, and the details say it', () => {
  const m = first('new-01');
  const body = targetChoicesBody([m], 'current', new Map(), new Map(), new Map([[m.vmId, 'os-standard-ssd']]));
  eq(JSON.stringify(body[0]), JSON.stringify({ vmId: m.vmId, option: 'v5', method: 'in-place', disks: 'os-standard-ssd' }));
  const d8d = hdd('old-04');
  eq(new Map(advDetailRows(d8d, 'v5', 'Standard_D8d_v5', 'os-standard-ssd')).get('Disks'), 'OS disk to Standard SSD', 'on a size that takes no Premium SSD too');
});

test('HDD-OS-1: the pricing file says the OS disk type now and after, in Azure\'s names', () => {
  const a = first('new-01'), b = hdd('old-01'), c = first('new-02', { osDiskType: 'StandardSSD_ZRS' }), d = first('new-03', { osDiskType: null });
  const picks = new Map([[a.vmId, 'v5'], [b.vmId, 'v5'], [c.vmId, 'v5'], [d.vmId, 'v5']]);
  const disks = new Map([[a.vmId, 'os-standard-ssd'], [b.vmId, 'os'], [c.vmId, 'os-standard-ssd'], [d.vmId, 'os-standard-ssd']]);
  const csv = pricingCsv([a, b, c, d], picks, new Map(), disks).split('\r\n');
  ok(csv.includes('Machine,Resource group,Region,Operating system,Size now,Size series,Target size,Disks,OS disk type now,OS disk type after'), csv.join(' | '));
  ok(csv.includes('new-01,rg-app,centralus,Linux,D2s_v4,v5,D2s_v5,OS disk to Standard SSD,Standard HDD,Standard SSD'), csv.join(' | '));
  ok(csv.includes('old-01,rg-app,centralus,Linux,D4_v2,v5,D8ds_v5,OS disk to Premium SSD,Standard HDD,Premium SSD'), csv.join(' | '));
  ok(csv.includes('new-02,rg-app,centralus,Linux,D2s_v4,v5,D2s_v5,No change,Standard SSD (zone-redundant),Standard SSD (zone-redundant)'), csv.join(' | '));
  ok(csv.includes('new-03,rg-app,centralus,Linux,D2s_v4,v5,D2s_v5,No change,?,?'), 'unknown is said, never a type: ' + csv.join(' | '));
});

test('HDD-OS-1: the list keeps a Standard SSD choice, and the plan export reads it', () => {
  const src = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
  ok(src.includes("if (['os', 'all', 'os-standard-ssd'].includes(e.target.value)) tDiskSel.set(id, e.target.value); else tDiskSel.delete(id);"), 'a change keeps the choice');
  ok(src.includes('osDiskType: e.assessment?.osDiskType ?? null,'), 'the plan export carries the type');
});
run('disk-choice');
