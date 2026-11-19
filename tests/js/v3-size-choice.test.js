/* V3-TEMPDISK-1: on the Choose each target step, a v3 machine starts on the
 * d size Microsoft names for it (D4s_v3 to D4ds_v6) and may choose the size
 * without a temporary disk instead (D4s_v6). Both arrive as the option's size
 * choices, the same shape a machine chosen by shape has.
 *
 * RUN: the page's own row functions, lifted out of wizard.html, with a machine
 * shaped like the engine's target-advice.json.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// SQL-TEMPDB-SIGNOFF-1: tTargetRow asks tSqlFound, which reads the page's
// assessment. None was read here, so no machine has the SQL Server finding.
globalThis.assessment = null;
// BSV2-TARGET-1: the pages name a Bsv2 size by its series (VmfHelp.seriesLabel).
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: liftAll('help.js', ['seriesLabel']).seriesLabel });
globalThis.tLinksOf = () => ({ extensions: [], sqlVirtualMachine: false, dataCollectionRuleAssociations: [] });

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.reasonText = (code) => String(code);
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not read ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
globalThis.shortSize = constArrow('shortSize');
globalThis.fill = constArrow('fill');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
// MANA-LINUX-KERNEL-1: a row draws the kernel choice too (kernelOffered, kernelOf).
// KERNEL-UX-1: in its Details (kernelSectionHtml), and an area counts its machines (tCountText).
const f = liftAll('wizard.html', ['tHelpBtn', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'sizeListMixed', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'tAreasHtml', 'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText', 'tCountText',
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tempLost', 'tDotWhy', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);

const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tSelected = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set(); globalThis.tASeen = new Set();
};
const an = { required: false, mayUseMana: true, turnsOn: false };
// The two choices disagree on the temporary disk, as Azure's sizes do.
const choice = (size, best, temp) => ({ size, family: 'D', variant: 'default', vcpus: 4, activeVcpus: 4, memoryGB: 16, best,
  path: 'B', rebuild: true, tempDisksTo: temp, sizeUnverified: false, acceleratedNetworking: an, stops: [], premiumDisks: true });
const v6 = { option: 'v6', supported: true, notSupported: [], targetSize: 'Standard_D4ds_v6', move: 'nvme-conversion', rebuild: true,
  tempDisksFrom: 1, tempDisksTo: 1, targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up', acceleratedNetworking: an,
  stops: [], premiumDisks: true, sizeChoices: [choice('Standard_D4ds_v6', true, 1), choice('Standard_D4s_v6', false, 0)] };
const web = { vmId: '/vm/web-07', name: 'web-07', gen: 'V2', location: 'centralus', sourceSize: 'Standard_D4s_v3', diskController: 'SCSI',
  acceleratedNicCount: 1, sourceStage: { stage: 'End of Life', basis: 'stated' }, options: [v6], start: { current: 'v6', extended: 'v6' } };

test('RUN: a v3 machine is in the area for a newer version of its size, on the d size, with a size list and no family list', () => {
  reset();
  ok(!f.oldShape(web), 'a Generation 2 v3 machine is not chosen by shape');
  const html = f.tAreasHtml([web]);
  ok(html.includes('id="t-area-same"') && !html.includes('id="t-area-shape"'), 'the first area only');
  const size = html.match(/<select class="t-size"[^>]*>([\s\S]*?)<\/select>/);
  ok(size, 'a size list is drawn');
  const opts = [...size[1].matchAll(/<option value="([^"]+)"( selected)?>/g)].map(x => [x[1], Boolean(x[2])]);
  eq(JSON.stringify(opts), JSON.stringify([['Standard_D4ds_v6', true], ['Standard_D4s_v6', false]]), 'both sizes, the d size first and selected');
  ok(!html.includes('class="t-fam"'), 'one family is no choice: no family list');
});

test('RUN: choosing the size without a temporary disk shows it, and the details say the temporary disk goes', () => {
  reset();
  globalThis.tSizes.set(web.vmId, 'Standard_D4s_v6');
  eq(f.sizeOf(web, 'v6', globalThis.tSizes), 'Standard_D4s_v6');
  const html = f.tAreasHtml([web]);
  ok(/<option value="Standard_D4s_v6" selected>/.test(html), 'the chosen size is selected');
  const temp = new Map(f.advDetailRows(web, 'v6', 'Standard_D4s_v6')).get(UX.dTemp);
  eq(temp, `${UX.vOneDisk}  →  ${UX.vNone}`, 'one temporary disk, then none');
  const kept = new Map(f.advDetailRows(web, 'v6', 'Standard_D4ds_v6')).get(UX.dTemp);
  eq(kept, `${UX.vOneDisk}  →  ${UX.vOneDisk}`, 'the d size keeps it');
});

test('RUN: a machine whose choices span two families still has the family list', () => {
  reset();
  const two = JSON.parse(JSON.stringify(web));
  two.vmId = '/vm/ds2-01'; two.name = 'ds2-01'; two.sourceSize = 'Standard_DS2_v2';
  two.options[0].sizeChoices[1] = Object.assign(choice('Standard_E2ds_v6', false, 1), { family: 'E' });
  ok(f.tAreasHtml([two]).includes('class="t-fam"'));
});

test('the demo options give the v3 machine the d size and both choices', () => {
  const demo = JSON.parse(WIZ.match(/'demo-scan\/target-advice\.json': (\{.*\}),\n/)[1]);
  // GPU-SCOPE-1 review: the demo document is held to the page's own version,
  // not to a number. The v13 bump first left the demo on 12, and the page
  // reads any other version as no options made - so every demo run showed the
  // targets step as not started.
  const pageVersion = Number(WIZ.match(/const TARGET_ADVICE_VERSION = (\d+);/)[1]);
  eq(demo.schemaVersion, pageVersion, 'the demo options are the version the page reads');
  const m = demo.machines.find(x => x.name === 'web-07');
  const o = m.options.find(x => x.option === 'v6');
  eq(o.targetSize, 'Standard_D2ds_v6');
  eq(JSON.stringify(o.sizeChoices.map(c => [c.size, c.best, c.tempDisksTo])),
    JSON.stringify([['Standard_D2ds_v6', true, 1], ['Standard_D2s_v6', false, 0]]));
  // targets-step.test.js holds the page's version to the engine's.
});

run('v3-size-choice');
