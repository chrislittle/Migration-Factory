/* TARGETS-ALIGN-1: the table "Same size, newer version" on the step Choose
 * each target lines up, and the preview feature shows once per subscription.
 *
 * Found 2026-11-08 on the step: the rows, the Details (?) helper and Check
 * again were all out of line. A revised mock-up was approved.
 *
 * Before: under each row on the in-place upgrade (Preview) a second table row
 * started under the series column and ran past the Details column, with the
 * pill, "Same machine. Needs the preview feature VMTempDiskResizePreview on
 * subscription {sub}.", a (?) and Check again - the same subscription fact on
 * every row. Details, (?) and Check again sat at three left edges, and the
 * count line could say "0 machines take an in-place upgrade."
 *
 * RUN: the page's own functions, with machines shaped like target-advice.json.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
globalThis.VmfHelp = require('./_identity').help(Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['seriesLabel', 'machineStarted'])));

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const CSS = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'app.css'), 'utf8');
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
const constArrow = (name) => {
  const m = WIZ.match(new RegExp(`const ${name} = ([^;]+);`));
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
globalThis.shortSize = constArrow('shortSize');
globalThis.fill = constArrow('fill');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.reasonText = (c) => String(c);
const fns = liftAll('wizard.html', ['tHelpBtn', 'anKept', 'anLost', 'anReleaseText', 'anHelpText',
  'sizeListMixed', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText',
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tempLost', 'tDotWhy', 'tCountText', 'tAreasHtml',
  'anRuleHtml', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tPreviewV5Way', 'tPreviewMoreHtml',
  'tPreviewNoticeHtml', 'tRecommended', 'tOptionLabel', 'tUnderRowHtml', 'tMethodCountsHtml', 'tMethodHelpHtml']);
const SUB_APPS = '00000000-0000-0000-0000-000000000000';
const SUB_WEB = '11111111-2222-3333-4444-555555555555';
globalThis.assessment = { vms: [] };
const resetT = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set(); globalThis.tASeen = new Set();
  globalThis.tPreview = new Map();
};
const registered = (sub, on = true, read = true) => tPreview.set(sub, { read, registered: on, state: on ? 'Registered' : read ? 'NotRegistered' : null, name: sub === SUB_APPS ? 'Applications' : 'Web' });

const opt = (option, preview, extra) => Object.assign({
  option, supported: true, notSupported: [], targetSize: `Standard_D2ds_${option}`,
  move: option === 'v5' ? 'scsi-resize' : 'nvme-conversion', preview, path: 'A',
  tempDisksFrom: 1, tempDisksTo: 1,
  targetStage: { stage: option === 'v5' ? 'Extended' : 'Current', basis: 'stated' }, stageChange: option === 'v5' ? 'same' : 'up',
  acceleratedNetworking: { required: false, mayUseMana: true, turnsOn: false }, stops: [] }, extra || {});
// A Windows D2ds_v4 that starts on v6, the Preview, under Current.
const winOn = (name, sub) => ({ vmId: `/subscriptions/${sub}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${name}`, name, os: 'Windows',
  sourceSize: 'Standard_D2ds_v4', diskController: 'SCSI', acceleratedNicCount: 0, gen: 'V2', location: 'centralus',
  sourceStage: { stage: 'Extended', basis: 'stated' }, identityType: 'None',
  options: [opt('v5', false), opt('v6', true), opt('v7', true)], start: { current: 'v6', extended: 'v5' } });
const web1 = winOn('web-01', SUB_APPS);
const web2 = winOn('web-02', SUB_APPS);
const web3 = winOn('web-03', SUB_WEB);
// A Linux machine never takes the Preview.
const lin = { vmId: `/subscriptions/${SUB_APPS}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-01`, name: 'app-01', os: 'Linux',
  sourceSize: 'Standard_D2ds_v4', diskController: 'SCSI', acceleratedNicCount: 0, gen: 'V2', location: 'centralus',
  sourceStage: { stage: 'Extended', basis: 'stated' }, identityType: 'None',
  options: [opt('v5', false), opt('v6', false), opt('v7', false)], start: { current: 'v6', extended: 'v5' } };
// The cells of the first <tr> of a row's markup, as text between the tags.
const cells = (html) => {
  const tr = html.slice(0, html.indexOf('</tr>'));
  return tr.split(/<td\b/).slice(1).map(c => '<td' + c);
};
const boxes = (html) => html.match(/<div class="t-psub[^"]*"/g) ?? [];

test('THE WORDS: the in-cell fact is "Same machine.", the registered sentence is the mock-up\'s, and the old row sentence is gone', () => {
  eq(UX.tPreviewFact, 'Same machine.');
  eq(UX.tPreviewOn.one, '1 machine takes the in-place upgrade (Preview). It needs the preview feature VMTempDiskResizePreview on subscription {sub}. The feature is registered.');
  eq(UX.tPreviewOn.many, '{n} machines take the in-place upgrade (Preview). It needs the preview feature VMTempDiskResizePreview on subscription {sub}. The feature is registered.');
  eq(UX.tPreviewSame, undefined, 'the per-row subscription sentence is gone');
});

test('A PREVIEW ROW IS ONE TABLE ROW: seven cells, the short fact inside the series cell, nothing under it and nothing past the last column', () => {
  resetT(); registered(SUB_APPS);
  const html = fns.tTargetRow(web1);
  ok(!html.includes('t-under'), 'no second table row under it');
  ok(!/colspan/.test(html), 'no cell spans columns');
  const c = cells(html);
  eq(c.length, 7, 'seven cells, one for each heading');
  ok(c[4].includes('<select class="t-series"') && c[4].includes(`<div class="t-pfact">${esc(UX.tPreviewFact)}</div>`), c[4]);
  ok(c[4].indexOf('t-series') < c[4].indexOf('t-pfact'), 'the fact is under the series list');
  ok(!html.includes('Applications') && !html.includes('VMTempDiskResizePreview'), 'no subscription fact in the row');
  ok(!/t-pcheck|data-help="preview-/.test(html), 'no Check again and no (?) of the feature in the row');
});

test('DETAILS sits in its own last column, at the right edge, on every row', () => {
  resetT(); registered(SUB_APPS);
  for (const m of [web1, lin]) {
    const c = cells(fns.tTargetRow(m));
    ok(/^<td class="t-detcell">/.test(c[6]) && c[6].includes('t-det'), c[6]);
  }
  const areas = fns.tAreasHtml([web1, lin]);
  ok(areas.includes('<th class="t-detcell"></th></tr></thead>'), 'the heading of the last column is the same cell kind');
  ok(/\.p-wizard \.t-detcell \{[^}]*text-align:right/.test(CSS), 'one right edge');
});

test('EVERY CELL OF A ROW STARTS ON THE SAME TOP LINE', () => {
  ok(/\.p-wizard \.t-area tbody tr\.t-row > td \{[^}]*vertical-align:top/.test(CSS), 'the cells of a row are aligned to the top');
});

test('AN IN-PLACE ROW has no fact under its series list', () => {
  resetT(); registered(SUB_APPS);
  ok(!fns.tTargetRow(lin).includes('t-pfact'));
  tOverrides.set(web1.vmId, 'v5');
  ok(!fns.tTargetRow(web1).includes('t-pfact'));
});

test('REGISTERED: one box above the table for the subscription, with the pill, the sentence, then the (?) and Check again at the right', () => {
  resetT(); registered(SUB_APPS);
  const html = fns.tPreviewNoticeHtml([web1, web2, lin]);
  eq(boxes(html).length, 1, 'one box for two machines in one subscription');
  ok(html.includes(esc(fill(UX.tPreviewOn.many, { n: 2, sub: 'Applications' }))), html);
  const pill = html.indexOf(`<span class="pill">${esc(UX.tPillPreview)}</span>`);
  const text = html.indexOf('<span class="t-ptxt">');
  const act = html.indexOf('<span class="t-pact">');
  ok(pill > 0 && text > pill && act > text, 'pill, then the sentence, then the actions');
  const actions = html.slice(act);
  ok(actions.indexOf('data-help="preview-sub-0"') < actions.indexOf('t-pcheck'), 'the (?) then Check again');
  ok(html.includes(`data-psub="${SUB_APPS}"`), 'Check again reads this subscription');
  ok(!html.includes('t-pwarn'), 'a registered feature is not a warning');
  ok(/\.p-wizard \.t-pact \{[^}]*margin-left:auto/.test(CSS), 'the actions go to the right edge');
});

test('ONE BOX FOR EACH SUBSCRIPTION: a second subscription gets a second box, with its own (?) id', () => {
  resetT(); registered(SUB_APPS); registered(SUB_WEB);
  const html = fns.tPreviewNoticeHtml([web1, web3]);
  eq(boxes(html).length, 2);
  ok(html.includes(esc(fill(UX.tPreviewOn.one, { n: 1, sub: 'Applications' }))) && html.includes(esc(fill(UX.tPreviewOn.one, { n: 1, sub: 'Web' }))), html);
  ok(html.includes('data-help="preview-sub-0"') && html.includes('data-help="preview-sub-1"'));
});

test('NOT REGISTERED, NOT READ, AND READING use the step\'s strings, in the same box shape, amber', () => {
  resetT(); registered(SUB_APPS, false);
  let html = fns.tPreviewNoticeHtml([web1, web2]);
  ok(html.includes(esc(fill(UX.tPvOff.many, { n: 2, sub: 'Applications' }))) && html.includes('<div class="t-pmore">'), html);
  ok(/<div class="t-psub t-pwarn"/.test(html) && html.includes('<span class="t-pact">'), html);
  resetT(); registered(SUB_APPS, false, false);
  html = fns.tPreviewNoticeHtml([web1]);
  ok(html.includes(esc(fill(UX.tPvNotRead.one, { n: 1, sub: 'Applications' }))), html);
  resetT();
  html = fns.tPreviewNoticeHtml([web1]);
  ok(html.includes(esc(fill(UX.tPreviewReading, { sub: SUB_APPS }))) && !html.includes('t-pmore'), html);
  ok(/disabled>/.test(html) || html.includes('t-pcheck'), 'Check again is there');
  ok(/\.p-wizard \.t-psub\.t-pwarn \{[^}]*background:var\(--warn-soft\)/.test(CSS), 'amber in both themes, from the tokens');
});

test('THE HELP of the feature opens inside its box, from the (?) of the box', () => {
  resetT(); registered(SUB_APPS);
  tHelp.add('preview-sub-0');
  const html = fns.tPreviewNoticeHtml([web1]);
  ok(html.includes(esc(UX.tPreviewWhat)) && html.includes('id="t-help-preview-sub-0"'), html);
  ok(/^<div class="t-psub"[\s\S]*<div class="muted t-help-text t-phelp"[\s\S]*<\/p><\/div><\/div>$/.test(html), 'inside the box, after the actions');
});

test('NO PREVIEW, NO BOX', () => {
  resetT(); registered(SUB_APPS);
  eq(fns.tPreviewNoticeHtml([lin]), '');
  tOverrides.set(web1.vmId, 'v5');
  eq(fns.tPreviewNoticeHtml([web1, lin]), '');
});

test('THE COUNT LINE leaves out a kind of change no machine takes', () => {
  resetT(); registered(SUB_APPS);
  let html = fns.tMethodCountsHtml([web1, web2]);
  ok(html.includes(esc(fill(UX.tCountsPreview.many, { n: 2 }))), html);
  ok(!/\b0 machines/.test(html) && !html.includes('take an in-place upgrade.'), html);
  html = fns.tMethodCountsHtml([lin]);
  ok(html.includes(esc(UX.tCountsInPlace.one)) && !/Preview\)\./.test(html), html);
  eq(fns.tMethodCountsHtml([]), '', 'no machine takes any: no line');
});

test('Check again re-reads one subscription, as before', () => {
  ok(WIZ.includes("document.querySelectorAll('.t-pcheck').forEach(b => b.addEventListener('click', () => { tPreviewLoad(machines, b.dataset.psub); }));"));
});

run('targets-align');
