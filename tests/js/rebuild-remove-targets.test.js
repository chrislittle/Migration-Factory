/* REBUILD-REMOVE-PLAN-1: the targets step offers no rebuild. Every target is
 * the in-place upgrade, or the in-place upgrade (Preview) - Path A for a
 * Windows machine whose move changes the kind of temporary disk, which Azure
 * allows only with the preview feature VMTempDiskResizePreview on the
 * subscription (TEMP-DISK-PREVIEW-1, which this file replaces).
 *
 * Decided 2026-11-07: remove the rebuild around the same disks. For the preview
 * feature, the page guides the customer, for each subscription, how to register it.
 * The page never registers it. For each subscription where a machine's target
 * needs it and it is not registered, the step says so, how to register it in
 * the Azure portal, and offers Check again.
 *
 * RUN: the page's own functions, with machines shaped like target-advice.json
 * v28 (no rebuild, no identity, no decide).
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');
globalThis.VmfHelp = require('./_identity').help(Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['seriesLabel', 'machineStarted'])));

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const WAVES = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
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
  'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tempLost', 'tDotWhy', 'advSummary', 'advSummaryHelpHtml', 'advGroups', 'tDefSeries',
  'anRuleHtml', 'targetChoicesBody', 'exportState', 'savedSizes', 'savedDisks',
  'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tPreviewV5Way', 'tPreviewMoreHtml',
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

// An option as target-advice v28 writes it: no rebuild, no identity.
const opt = (option, preview, extra) => Object.assign({
  option, supported: true, notSupported: [], targetSize: `Standard_D2ds_${option}`,
  move: option === 'v5' ? 'scsi-resize' : 'nvme-conversion', preview, path: 'A',
  tempDisksFrom: 1, tempDisksTo: 1,
  targetStage: { stage: option === 'v5' ? 'Extended' : 'Current', basis: 'stated' }, stageChange: option === 'v5' ? 'same' : 'up',
  acceleratedNetworking: { required: false, mayUseMana: true, turnsOn: false }, stops: [] }, extra || {});
// A Windows D2ds_v4: v5 keeps the SCSI temporary disk; v6 and v7 are the Preview.
// It starts on v6 under Current: the first supported option of the order.
const win = { vmId: `/subscriptions/${SUB_APPS}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/win-01`, name: 'win-01', os: 'Windows',
  sourceSize: 'Standard_D2ds_v4', diskController: 'SCSI', acceleratedNicCount: 0, gen: 'V2',
  sourceStage: { stage: 'Extended', basis: 'stated' }, identityType: 'SystemAssigned',
  options: [opt('v5', false), opt('v6', true), opt('v7', true)], start: { current: 'v6', extended: 'v5' } };
// A Windows Generation 1 B2s: its v5 option goes to the Bsv2 size by the Preview.
const bv1 = { vmId: `/subscriptions/${SUB_WEB}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/web-b01`, name: 'web-b01', os: 'Windows',
  sourceSize: 'Standard_B2s', diskController: null, acceleratedNicCount: 0, gen: 'V1',
  sourceStage: { stage: 'End of Life', basis: 'stated' }, identityType: 'None',
  options: [opt('v5', true, { targetSize: 'Standard_B2ls_v2', move: 'scsi-resize', tempDisksTo: 0, burstableKept: true, sizeChoices: [
    { size: 'Standard_B2ls_v2', family: 'Bsv2', preview: true, path: 'A', tempDisksTo: 0 },
    { size: 'Standard_D2lds_v5', family: 'Dl', preview: false, path: 'A', tempDisksTo: 1 }] }),
    opt('v6', false, { supported: false, notSupported: ['gen1-requires-redeploy'], targetSize: null, path: 'MANUAL' }),
    opt('v7', false, { supported: false, notSupported: ['gen1-requires-redeploy'], targetSize: null, path: 'MANUAL' })],
  start: { current: 'v5', extended: 'v5' } };
// A Linux machine never takes the Preview.
const lin = { vmId: `/subscriptions/${SUB_APPS}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/app-01`, name: 'app-01', os: 'Linux',
  sourceSize: 'Standard_D2ds_v4', diskController: 'SCSI', acceleratedNicCount: 0, gen: 'V2', sourceStage: { stage: 'Extended', basis: 'stated' }, identityType: 'None',
  options: [opt('v5', false), opt('v6', false), opt('v7', false)], start: { current: 'v6', extended: 'v5' } };
const items = (html) => [...html.matchAll(/<option value="([^"]+)"([^>]*)>([^<]*)<\/option>/g)].map(x => [x[1], x[3], /disabled/.test(x[2]), /selected/.test(x[2])]);

test('THE DEFECT GONE: no item of the series list is a rebuild, and each option is one item', () => {
  resetT(); registered(SUB_APPS);
  eq(JSON.stringify(items(fns.tTargetRow(win))), JSON.stringify([
    ['v5', 'v5: In-place upgrade', false, false],
    ['v6', 'v6: In-place upgrade (Preview)', false, true],
    ['v7', 'v7: In-place upgrade (Preview)', false, false]]));
  ok(!/Rebuild|Not recommended/.test(fns.tTargetRow(win)), 'no rebuild anywhere in the row');
});

test('the start is the first supported option of the order: a Preview start, and (Recommended) only on an in-place start', () => {
  resetT(); registered(SUB_APPS);
  eq(fns.tMethodOf(win, 'v6', tSizes), 'preview');
  eq(fns.tMethodOf(win, 'v5', tSizes), 'in-place');
  ok(!fns.tRecommended(win, 'v6', tSizes, 'current'), 'a Preview says Preview, not Recommended');
  tDefault = 'extended';
  eq(items(fns.tTargetRow(win)).find(x => x[3])[1], 'v5: In-place upgrade (Recommended)');
  resetT(); registered(SUB_APPS);
  eq(items(fns.tTargetRow(lin)).find(x => x[3])[1], 'v6: In-place upgrade (Recommended)');
});

test('the method is a fact of the size, never a choice: the save sends preview for a Preview size and in-place for the rest', () => {
  resetT(); registered(SUB_APPS);
  const body = fns.targetChoicesBody([win, lin], 'current', tOverrides, tSizes, new Map(), new Map(), 'stop');
  eq(JSON.stringify(body.map(b => [b.option, b.method])), JSON.stringify([['v6', 'preview'], ['v6', 'in-place']]));
  tOverrides.set(win.vmId, 'v5');
  eq(fns.targetChoicesBody([win], 'current', tOverrides, tSizes, new Map(), new Map(), 'stop')[0].method, 'in-place');
  ok(!/'rebuild'/.test(WIZ.slice(WIZ.indexOf('function tMethodOf'), WIZ.indexOf('// TEMP-DISK-PREVIEW-1: the subscription of a machine'))), 'tMethodOf has no rebuild');
  ok(!/tMethodSel/.test(WIZ), 'no saved method choice is kept');
});

test('not registered: a Preview the machine is not on cannot be chosen, and the one it is on stays, marked as needing the feature', () => {
  resetT(); registered(SUB_APPS, false);
  eq(JSON.stringify(items(fns.tTargetRow(win))), JSON.stringify([
    ['v5', 'v5: In-place upgrade', false, false],
    ['v6', 'v6: In-place upgrade (Preview, feature needed)', false, true],
    ['v7', 'v7: In-place upgrade (Preview, feature needed)', true, false]]));
  resetT(); registered(SUB_APPS, false, false);
  ok(items(fns.tTargetRow(win)).find(x => x[0] === 'v7')[2], 'not read is not a yes');
  resetT();
  ok(items(fns.tTargetRow(win)).find(x => x[0] === 'v7')[2], 'not read yet is not a yes');
});

test('a Generation 1 B v1 machine takes its Bsv2 size by the Preview, and its Dl size in place', () => {
  resetT(); registered(SUB_WEB);
  eq(fns.tMethodOf(bv1, 'v5', tSizes), 'preview');
  eq(items(fns.tTargetRow(bv1)).find(x => x[3])[1], 'Bsv2: In-place upgrade (Preview)');
  tSizes.set(bv1.vmId, 'Standard_D2lds_v5');
  eq(fns.tMethodOf(bv1, 'v5', tSizes), 'in-place', 'another size of the option is in place, with no feature');
});

test('THE NOTICE: one line for each subscription where a machine takes the Preview and the feature is not registered, with what to do', () => {
  resetT(); registered(SUB_APPS, false);
  const second = Object.assign({}, win, { vmId: win.vmId.replace('win-01', 'win-02'), name: 'win-02' });
  const html = fns.tPreviewNoticeHtml([win, second, lin]);
  ok(html.includes(esc(fill(UX.tPvOff.many, { n: 2, sub: 'Applications' }))), html);
  eq(UX.tPvOff.many, '{n} machines in subscription {sub} move by the in-place upgrade (Preview). The preview feature VMTempDiskResizePreview is not registered in this subscription.');
  ok(html.includes(esc(UX.tPvWho)) && html.includes(esc(UX.tPvReg2)), 'it says what to do (PREVIEW-RG-SCOPE-1)');
  ok(html.includes('data-help="preview-sub-0"') && html.includes('t-pcheck'), 'the (?) and Check again');
  eq((html.match(/t-pwarn/g) ?? []).length, 1, 'one line for the subscription');
  registered(SUB_APPS, false, false);
  ok(fns.tPreviewNoticeHtml([win]).includes(esc(fill(UX.tPvNotRead.one, { n: 1, sub: 'Applications' }))), 'not read says so');
  // TARGETS-ALIGN-1: registered, the box stays and says so, with no warning.
  registered(SUB_APPS);
  const on = fns.tPreviewNoticeHtml([win, second]);
  ok(on.includes(esc(fill(UX.tPreviewOn.many, { n: 2, sub: 'Applications' }))) && !on.includes('t-pwarn') && !on.includes('t-pmore'), on);
  ok(WIZ.includes('${tPreviewNoticeHtml(machines)}'), 'the step draws it');
});

test('THE NOTICE counts only the machines whose target is the Preview, not every machine that has a Preview somewhere', () => {
  resetT(); registered(SUB_APPS, false);
  tOverrides.set(win.vmId, 'v5');
  eq(fns.tPreviewNoticeHtml([win, lin]), '', 'win-01 is on v5, in place: nothing needs the feature');
  tOverrides.set(win.vmId, 'v7');
  ok(fns.tPreviewNoticeHtml([win]).includes(esc(fill(UX.tPvOff.one, { n: 1, sub: 'Applications' }))));
});

test('THE STEPS in the Azure portal (Subscriptions, Preview features, Register, the wait) are in the box; the help holds the feature - and no command to copy (rule 12)', () => {
  resetT(); registered(SUB_APPS, false);
  tHelp.add('preview-sub-0');
  const html = fns.tPreviewNoticeHtml([win]);
  eq(UX.tPvReg2, 'Select Preview features. Find VMTempDiskResizePreview and select Register.');
  for (const k of ['tPvReg2', 'tPvReg3', 'tPreviewWhat', 'tPreviewNotTool', 'tPreviewKeep']) ok(html.includes(esc(UX[k])), k);
  ok(!/az feature|az provider|Register-Az|Set-AzContext|t-copy|<pre/.test(html), 'no command to run elsewhere');
  ok(!/PREVIEW_COMMANDS|navigator\.clipboard/.test(WIZ), 'the page holds no command and copies nothing');
  resetT(); registered(SUB_APPS, false);
  ok(!fns.tPreviewNoticeHtml([win]).includes('t-phelp'), 'nothing opens on its own');
});
// TARGETS-ALIGN-1: the subscription, its (?) and Check again moved to the box
// above the table (tests/js/targets-align.test.js); the row keeps its own fact.
test('a Preview row says Same machine under its series list; an in-place row says nothing there', () => {
  resetT(); registered(SUB_APPS);
  ok(fns.tTargetRow(win).includes(`<div class="t-pfact">${esc(UX.tPreviewFact)}</div>`));
  tOverrides.set(win.vmId, 'v5');
  ok(!fns.tTargetRow(win).includes('t-pfact'), 'nothing under an in-place series list');
});

test('Details: the kind of change says In-place upgrade, with Preview where it is one; no identity row and no removed row', () => {
  resetT(); registered(SUB_APPS);
  const rows = new Map(fns.advDetailRows(win, 'v6', '', undefined, 'current'));
  eq(rows.get(UX.dKind), 'In-place upgrade (Preview)');
  eq(rows.get(UX.dRollback), UX.vRollbackPreview);
  const v5 = new Map(fns.advDetailRows(win, 'v5', '', undefined, 'extended'));
  eq(v5.get(UX.dKind), 'In-place upgrade (Recommended)');
  eq(v5.get(UX.dRollback), UX.vRollbackInPlace);
  for (const k of ['dIdentity', 'dRemoved', 'vIdLost', 'vRollbackRebuild', 'kPathB', 'tPillNot', 'tRebuildUse', 'tIdAlert', 'tDecideIdAlert', 'tCountsRebuild', 'tWhyInPlace']) {
    eq(UX[k], undefined, `${k} is gone`);
  }
});

test('the counts name the in-place upgrade and the Preview, and never a rebuild; the facts table has two columns', () => {
  resetT(); registered(SUB_APPS);
  const html = fns.tMethodCountsHtml([win, lin]);
  ok(html.includes('1 machine takes an in-place upgrade. 1 machine takes an in-place upgrade (Preview).'), html);
  ok(!/rebuild/i.test(html));
  tHelp.add('method');
  const help = fns.tMethodHelpHtml();
  eq((help.match(/<th>/g) ?? []).length, 3, 'a heading column and two kinds of change');
  ok(help.includes(esc(UX.tMethodFacts.preview.when)) && !/rebuild/i.test(help), help);
});

test('the summary has no identity count and no machine to choose; its (?) has no in-place reason', () => {
  resetT(); registered(SUB_APPS);
  const text = fns.advSummary([win, lin, bv1], 'current', new Map(), new Map());
  ok(!/identity|to choose/.test(text), text);
  const groups = fns.advGroups([win, lin, bv1], 'current', new Map(), new Map());
  ok(groups.every(g => g.why !== 'inplace' && g.why !== 'choose-id' && g.kind !== 'choose'), JSON.stringify(groups));
});

test('every reason a move across the kinds of temporary disk can carry has words on this page', () => {
  for (const c of ['disk-encryption-preview', 'generation-unknown', 'temp-disk-change-not-measured']) ok(typeof UX.whyNot[c] === 'string' && UX.whyNot[c].length > 20, c);
  ok(/Azure Disk Encryption/.test(UX.whyNot['disk-encryption-preview']) && /Scan the machine again/.test(UX.whyNot['generation-unknown']));
  ok(/Azure Disk Encryption/.test(UX.vBsv2Why['disk-encryption-preview']));
  eq(UX.whyNot['disk-encryption-rebuild'], undefined);
});

test('the page has no identity notice, no choice cards and no decide save check', () => {
  for (const name of ['identityOf', 'identityKeeper', 'identityToCheck', 'identityNoticeHtml', 'decideNoticeHtml', 'identityDecideHtml', 'needsChoice',
    'decideMissing', 'decideSectionHtml', 'syncDecideMissing', 'tRemovals', 'tLinksOf', 'tRemovalWords']) {
    ok(!new RegExp(`function ${name}\\(`).test(WIZ), name);
  }
  ok(!/\.t-idkeep|input\.t-decide/.test(WIZ));
});

test('Check again reads the feature with no reload, and the page never registers it (rule 12 exception)', () => {
  ok(WIZ.includes("api('GET', `preview-feature?subscriptionId=${encodeURIComponent(s)}`)"), 'a GET of the service');
  ok(WIZ.includes("document.querySelectorAll('.t-pcheck').forEach(b => b.addEventListener('click', () => { tPreviewLoad(machines, b.dataset.psub); }));"), 'Check again reads again');
  ok(!/api\(\s*'(POST|PUT)'[^)]*(feature|register)/i.test(WIZ), 'no call registers anything');
  ok(WIZ.includes("tOverrides.set(e.target.dataset.vm, String(e.target.value));"), 'an item is its option');
});

test('RUN: tPreviewLoad reads each subscription that has a Preview once, and again for one on Check again', async () => {
  resetT();
  const calls = [];
  globalThis.api = async (method, where) => { calls.push(`${method} ${where}`); return { read: true, registered: where.includes(SUB_APPS), state: 'Registered', subscriptionName: 'Applications' }; };
  globalThis.render = () => {}; globalThis.STEP = { migrate: { targets: 't' } }; globalThis.step = 't';
  const { tPreviewLoad } = liftAll('wizard.html', ['tPreviewLoad', 'previewOffered', 'subOf']);
  await tPreviewLoad([win, lin, bv1]);
  eq(calls, [`GET preview-feature?subscriptionId=${SUB_APPS}`, `GET preview-feature?subscriptionId=${SUB_WEB}`]);
  await tPreviewLoad([win, lin, bv1]);
  eq(calls.length, 2, 'once');
  await tPreviewLoad([win, lin, bv1], SUB_WEB);
  eq(calls.length, 3, 'only the subscription asked for');
  globalThis.api = async () => { throw new Error('500'); };
  await tPreviewLoad([win], SUB_APPS);
  eq(tPreview.get(SUB_APPS).read, false, 'a failed read is not checked');
});

test('the wave editor and the sign-off still name the Preview machines, by one rule', () => {
  const help = liftAll('help.js', ['previewNames']);
  const entries = [{ vmId: '/x/a', path: 'A', target: { choice: { method: 'preview' } } }, { vmId: '/x/b', path: 'A', target: { choice: { method: 'in-place' } } }];
  eq(help.previewNames(entries, (id) => id.split('/').pop()), ['a']);
  ok(WIZ.includes('[UX.lvPreview, previewText(wave)],'), 'the sign-off has the row');
  ok(WAVES.includes('${previewLine(members, name)}'), 'the wave editor names them (WAVE-NOTE-LAYOUT-1: with its wave, for the note box)');
});

test('the colour is never the only cue, and the words are the product nouns', () => {
  resetT(); registered(SUB_APPS);
  const bare = fns.tTargetRow(win).replace(/class="[^"]*"/g, '');
  ok(bare.includes('(Preview)'), 'the row says Preview in the words of its option');
  // TARGETS-ALIGN-1: the pill is in the box of the subscription, above the table.
  ok(fns.tPreviewNoticeHtml([win]).replace(/class="[^"]*"/g, '').includes('>Preview<'));
  const ours = Object.entries(UX).filter(([k]) => /^tPreview|^tPv|^tPill|^tCountsPreview|^vRollbackPreview|^tMethod/.test(k)).map(([, v]) => JSON.stringify(v)).join(' ');
  ok(!/\bVMs?\b/.test(ours), ours);
  ok(!/rebuil|redeploy from image/i.test(ours), ours);
});

run('rebuild-remove-targets');
