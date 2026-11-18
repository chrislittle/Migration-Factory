/* SIZE-FALLTHROUGH-NOTE-1: the Choose each target step says why the size with
 * a temporary disk is not the target.
 *
 * The default transform tries the d size first for a machine with a temporary
 * disk, then the size without one. When the d size fails a gate, the step
 * showed the size without one and the No temporary disk tag, and nothing said
 * why. Now the engine sends each size it did not take with the gate as a code
 * (sizesNotTaken, target-advice v29), and the step puts it in words behind a
 * (?) on the Temporary disk row in Details - the screen shows the options, the
 * why is behind a helper. A Windows machine whose move becomes the in-place
 * upgrade (Preview) because of it is told so in the same text.
 *
 * RUN, not read: the page's own functions, lifted out of wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, lift, test, eq, ok, run } = require('./_harness');
// SQL-TEMPDB-SIGNOFF-1: tTargetRow asks tSqlFound, which reads the page's
// assessment. None was read here, so no machine has the SQL Server finding.
globalThis.assessment = null;
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });
globalThis.tLinksOf = () => ({ extensions: [], sqlVirtualMachine: false, dataCollectionRuleAssociations: [] });

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const UX = globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
globalThis.reasonText = (code) => String(code);

const F = liftAll('wizard.html', ['tNotTakenText', 'tempLost', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'sizeListMixed', 'tDotWhy', 'tHelpBtn', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'manaUpgradeText',
  'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText', 'tCountText',
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);

const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tSelected = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set(); globalThis.tASeen = new Set();
  globalThis.targetAdvice = { machines: [] };
};

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/';
const an = { required: false, mayUseMana: true, turnsOn: false };
const choice = (size, best, temp) => ({ size, family: 'D', variant: 'default', vcpus: 4, activeVcpus: 4, memoryGB: 16, best,
  path: 'A', tempDisksTo: temp, sizeUnverified: false, acceleratedNetworking: an, stops: [], premiumDisks: true, preview: false,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up' });
const option = (opt, targetSize, to, extra) => Object.assign({ option: opt, supported: true, notSupported: [], targetSize,
  move: opt === 'v5' ? 'scsi-resize' : 'nvme-conversion', path: 'A', preview: false, tempDisksFrom: 1, tempDisksTo: to,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up', acceleratedNetworking: an, stops: [], premiumDisks: true,
  sizeChoices: [], sizesNotTaken: [] }, extra || {});
const machine = (name, os, sourceSize, options, start) => ({ vmId: SUB + name, name, os, gen: 'V2', location: 'centralus', sourceSize,
  diskController: 'SCSI', acceleratedNicCount: 0, sourceStage: { stage: 'Extended', basis: 'stated' }, options,
  start: start || { current: 'v6', extended: 'v5' } });

// Linux on D4s_v3 with 6 data disks: D4ds_v6 holds 4, so v6 fell through to D4s_v6.
const fell = machine('db-01', 'Linux', 'Standard_D4s_v3', [
  option('v6', 'Standard_D4s_v6', 0, { sizesNotTaken: [{ size: 'Standard_D4ds_v6', why: 'too-few-data-disks' }] })]);
// Windows on D4s_v3, v5: D4ds_v5 not in the region, so D4s_v5 - the in-place upgrade (Preview).
const win = machine('web-01', 'Windows', 'Standard_D4s_v3', [
  option('v5', 'Standard_D4s_v5', 0, { preview: true, sizesNotTaken: [{ size: 'Standard_D4ds_v5', why: 'not-in-region' }] })], { current: 'v5', extended: 'v5' });
// The control: got its first size.
const first = machine('app-01', 'Linux', 'Standard_D4s_v3', [option('v6', 'Standard_D4ds_v6', 1)]);
// A v28 option: no sizesNotTaken at all.
const old = machine('old-01', 'Linux', 'Standard_D4s_v3', [option('v6', 'Standard_D4s_v6', 0)]);
delete old.options[0].sizesNotTaken;

test('every code the engine can send has its own words on the page, and no others', () => {
  const schema = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'target-advice.schema.json'), 'utf8'));
  const codes = schema.$defs.option.properties.sizesNotTaken.items.properties.why.enum;
  eq(Object.keys(UX.tNotTaken).sort(), [...codes].sort(), 'the page and the schema hold the same codes');
  eq(new Set(Object.values(UX.tNotTaken)).size, codes.length, 'each code has words of its own');
  for (const c of codes) ok(UX.tNotTaken[c].includes('{size}'), `${c} names the size`);
});

test('the words name the size not taken, the gate and the target', () => {
  reset();
  eq(F.tNotTakenText(fell, 'v6', new Map()),
    'The product did not use D4ds_v6, because it holds fewer data disks than this machine has. The target is D4s_v6.');
});

test('each code gives its own sentence', () => {
  reset();
  const seen = new Set();
  for (const why of Object.keys(UX.tNotTaken)) {
    const m = machine('x-01', 'Linux', 'Standard_D4s_v3', [option('v6', 'Standard_D4s_v6', 0, { sizesNotTaken: [{ size: 'Standard_D4ds_v6', why }] })]);
    const text = F.tNotTakenText(m, 'v6', new Map());
    ok(text.startsWith(fill(UX.tNotTaken[why], { size: 'D4ds_v6' })), `${why}: ${text}`);
    ok(!seen.has(text), `${why} is not the words of another code`);
    seen.add(text);
  }
});

test('a move that becomes the in-place upgrade (Preview) says so', () => {
  reset();
  const text = F.tNotTakenText(win, 'v5', new Map());
  ok(text.includes(fill(UX.tNotTaken['not-in-region'], { size: 'D4ds_v5' })), text);
  ok(text.endsWith(UX.tNotTakenPreview), text);
  ok(!F.tNotTakenText(fell, 'v6', new Map()).includes(UX.tNotTakenPreview), 'and a move that is not the Preview does not');
});

test('nothing to say: the first size, an empty list, a v28 option with no list, no option', () => {
  reset();
  eq(F.tNotTakenText(first, 'v6', new Map()), '');
  eq(F.tNotTakenText(old, 'v6', new Map()), '', 'an older target advice has no field, and that is no note - never an error');
  eq(F.tNotTakenText(fell, 'v7', new Map()), '', 'an option the machine does not have');
  eq(F.tNotTakenText(fell, '', new Map()), '');
});

test('a code the page does not know still names the size, with no gate', () => {
  reset();
  const m = machine('x-02', 'Linux', 'Standard_D4s_v3', [option('v6', 'Standard_D4s_v6', 0, { sizesNotTaken: [{ size: 'Standard_D4ds_v6', why: 'later-code' }] })]);
  eq(F.tNotTakenText(m, 'v6', new Map()), 'The product did not use D4ds_v6. The target is D4s_v6.');
});

test('a size chosen from the size choices was not a fall-through: nothing to say', () => {
  reset();
  const m = machine('x-03', 'Linux', 'Standard_D4s_v3', [option('v6', 'Standard_D4s_v6', 0, {
    sizeChoices: [choice('Standard_D4s_v6', true, 0), choice('Standard_D8s_v6', false, 0)],
    sizesNotTaken: [{ size: 'Standard_D4ds_v6', why: 'too-few-data-disks' }] })]);
  ok(F.tNotTakenText(m, 'v6', new Map()) !== '', 'on the target size: the note');
  eq(F.tNotTakenText(m, 'v6', new Map([[m.vmId, 'Standard_D8s_v6']])), '', 'on a chosen size: none');
});

test('RUN: Details show a (?) on the Temporary disk row; it opens the words and closes', () => {
  reset(); globalThis.targetAdvice = { machines: [fell, first] };
  ok(!F.tTargetRow(fell).includes('data-help="nt-'), 'Details closed: no (?)');
  globalThis.tOpen.add(fell.vmId);
  let html = F.tTargetRow(fell);
  const row = html.match(/<tr[^>]*><td>(?:<span class="t-kdotx" aria-hidden="true"><\/span>)?([^<]*) <button[^>]*data-help="(nt-\d+)"[^>]*>/);
  ok(row, html);
  eq(row[1], UX.dTemp, 'on the Temporary disk row');
  eq(row[2], 'nt-0', 'the id is the place of the machine');
  ok(html.includes(`title="${esc(UX.tNotTakenAbout)}"`), 'the (?) says what it is about');
  ok(!html.includes('id="t-help-nt-0"'), 'the words stay closed until asked');
  globalThis.tHelp.add('nt-0');
  html = F.tTargetRow(fell);
  ok(html.includes(`id="t-help-nt-0">${esc(F.tNotTakenText(fell, 'v6', new Map()))}</p>`), html);
  ok(html.includes(`aria-label="${esc(UX.tClose)}"`), 'and its button says Close (rule 11)');
});

test('RUN: a machine that got its first size, and a v28 option, have no (?) there', () => {
  reset(); globalThis.targetAdvice = { machines: [first, old] };
  globalThis.tOpen.add(first.vmId); globalThis.tOpen.add(old.vmId);
  ok(!F.tTargetRow(first).includes('data-help="nt-'), 'the first size');
  ok(!F.tTargetRow(old).includes('data-help="nt-'), 'an option with no field');
});

test('new options close an open (?) of this kind, as they close the others', () => {
  const code = WIZ.split(/\r?\n/).find(l => l.includes('for (const id of [...tHelp])'));
  ok(code && code.includes("id.startsWith('nt-')"), code);
});

run('size-fallthrough-note');
