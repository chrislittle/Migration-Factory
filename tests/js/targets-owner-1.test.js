/* ADVISE-AN-1, the targets step approved on 2026-10-12, after
 * several mock-ups:
 *   1. the lifecycle stages keep Microsoft's names, with a hint under each
 *      (TARGETS-HINTS-1 replaced "v6 or v7 where the machine supports it" and
 *      "v5" with the order of each default, and Bsv2 for a B v1 machine);
 *   2. the summary keeps its counts and gains a (?) that says, for each group
 *      not on the default, why - from the advice, never invented;
 *   3. a change of the default moves only the machines a person did not change;
 *   4. no tick boxes, Select all, Clear selection or Change the selected
 *      machines to - the defaults and each machine's own list replace them;
 *   5. the two targets of a machine to choose use the before -> after arrows;
 *   6. a size list names the processor maker only when it mixes makers;
 *   7. the first area is "Same size, newer version", and the (?) of the second
 *      says exactly who is there - the families oldShape reads.
 *
 * RUN, not read: the page's own functions, lifted out of wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { seriesLabel: lift('help.js', 'seriesLabel') });

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const hasLine = (code) => WIZ.split(/\r?\n/).some(l => l.trimStart().startsWith(code));
const UX = globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
globalThis.reasonText = (code) => String(code);

const F = liftAll('wizard.html', ['advGroups', 'tDefSeries', 'advSummary', 'advSummaryHelpHtml', 'advPick', 'advSeriesLabel', 'advWhy', 'sizeOf',
  'sizeChoiceLabel', 'sizeListMixed', 'tHelpBtn', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'tAreasHtml', 'oldShape', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes',
  'kernelOffered', 'kernelOf', 'kernelSectionHtml', 'eusImageText', 'tCountText', 'advGenLabel', 'advDetailRows', 'tempLost', 'tDotWhy',
  'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);

const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set();
  globalThis.tASeen = new Set(); globalThis.targetAdvice = { machines: [] };
};
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/';
const an = (keptOn, keptOnWhy) => ({ required: false, mayUseMana: true, turnsOn: false, keptOn, keptOnWhy });
const opt = (option, targetSize, extra) => Object.assign({ option, supported: true, notSupported: [], targetSize, move: option === 'v5' ? 'scsi-resize' : 'nvme-conversion',
  path: 'A', rebuild: false, tempDisksFrom: 0, tempDisksTo: 0, acceleratedNetworking: an(null, null), stops: [], sizeChoices: [], premiumDisks: true,
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up' }, extra || {});
const no = (option, codes) => opt(option, null, { supported: false, notSupported: codes });
const mk = (name, os, sourceSize, options, start, extra) => Object.assign({ vmId: SUB + name, name, os, gen: 'V2', location: 'centralus', sourceSize,
  diskController: 'SCSI', acceleratedNicCount: 1, linuxRelease: null, sourceStage: { stage: 'Extended', basis: 'stated' }, options,
  start: start || { current: 'v6', extended: 'v5' }, decide: null }, extra || {});

const v6a = mk('a-01', 'Linux', 'Standard_D2s_v4', [opt('v5', 'Standard_D2s_v5'), opt('v6', 'Standard_D2s_v6')]);
const v6b = mk('a-02', 'Linux', 'Standard_D2s_v4', [opt('v5', 'Standard_D2s_v5'), opt('v6', 'Standard_D2s_v6')]);
const gen1 = mk('g1-01', 'Linux', 'Standard_D2s_v4', [opt('v5', 'Standard_D2s_v5'), no('v6', ['gen1-requires-redeploy']), no('v7', ['gen1-requires-redeploy'])],
  { current: 'v5', extended: 'v5' }, { gen: 'V1' });
const bsv2 = mk('b-01', 'Linux', 'Standard_B2s', [opt('v5', 'Standard_B2s_v2', { burstableTarget: 'offered', sizeChoices: [
  { size: 'Standard_B2s_v2', family: 'Bsv2', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 4, best: true, processor: 'Intel' }] }), opt('v6', 'Standard_D2ls_v6')],
  { current: 'v5', extended: 'v5' });
const amdKeep = mk('k-01', 'Linux', 'Standard_D2as_v4', [opt('v5', 'Standard_D2as_v5', { acceleratedNetworking: an(true, null) }),
  opt('v6', 'Standard_D2as_v6', { acceleratedNetworking: an(false, 'unlisted') })], { current: 'v5', extended: 'v5' });
const choose = mk('c-01', 'Linux', 'Standard_D2s_v4', [
  opt('v5', 'Standard_D2s_v5', { acceleratedNetworking: an(null, 'host'), sizeChoices: [
    { size: 'Standard_D2s_v5', family: 'D', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 8, best: true, processor: 'Intel', acceleratedNetworking: an(null, 'host') },
    { size: 'Standard_D2as_v5', family: 'D', variant: 'default', vcpus: 2, activeVcpus: 2, memoryGB: 8, best: false, processor: 'AMD', processorChange: true, acceleratedNetworking: an(true, null) }] }),
  opt('v6', 'Standard_D2s_v6', { acceleratedNetworking: an(false, 'unlisted') })], { current: null, extended: null },
  { decide: { reason: 'processor-or-an', keepsProcessor: { current: 'v6', extended: 'v5', processor: 'Intel' }, keepsAn: { option: 'v5', size: 'Standard_D2as_v5', processor: 'AMD' } } });

test('1: the lifecycle stages keep Microsoft names, and the hints say what each holds', () => {
  eq(UX.tCurrent, 'Current');
  eq(UX.tExtended, 'Extended');
  // TARGETS-HINTS-1: the hints say the order each default starts a machine
  // on, and Bsv2 for a B v1 machine (tests/js/targets-hints.test.js).
  ok(UX.tStartOrder.includes('{a}, {b} and {c}'), UX.tStartOrder);
  // STAGE-HINT-WORDS-1: Current has its own sentence, which names v5's stage.
  ok(UX.tStartCurrent.includes('{a}, or on {b} when {a} does not fit'), UX.tStartCurrent);
  ok(UX.tStartBsv2.includes('Bsv2'), UX.tStartBsv2);
});

test('2: the summary keeps its counts, biggest first, and the (?) says why each group is not on the default - from the advice', () => {
  reset();
  const all = [v6a, v6b, gen1, bsv2, choose];
  const text = F.advSummary(all, 'current', new Map());
  eq(text, fill(UX.tSummary, { n: 5, parts: [fill(UX.tOn, { n: 2, series: 'v6' }), fill(UX.tOn, { n: 1, series: 'Bsv2' }), fill(UX.tOn, { n: 1, series: 'v5' }), fill(UX.tNoneCount, { n: 1 })].join(' · ') }));
  const help = F.advSummaryHelpHtml(all, 'current', new Map());
  ok(help.includes(esc(fill(UX.tGroupLine, { part: fill(UX.tOn, { n: 1, series: 'v5' }), why: UX.tWhyGen1 }))), help);
  ok(help.includes(esc(fill(UX.tGroupLine, { part: fill(UX.tOn, { n: 1, series: 'Bsv2' }), why: UX.tWhyBsv2 }))), 'Bsv2');
  // REBUILD-REMOVE-PLAN-1: no machine waits for a choice; one with no start has no target.
  ok(help.includes(esc(fill(UX.tGroupLine, { part: fill(UX.tNoneCount, { n: 1 }), why: UX.tWhyNone }))), 'no target');
  ok(!help.includes(fill(UX.tOn, { n: 2, series: 'v6' })), 'the machines on the default need no reason');
  const amdHelp = F.advSummaryHelpHtml([amdKeep], 'current', new Map());
  ok(amdHelp.includes(esc(fill(UX.tWhyAn, { series: 'v6' }))), 'kept accelerated networking: ' + amdHelp);
  const moved = F.advSummaryHelpHtml([v6a], 'current', new Map([[v6a.vmId, 'v5']]));
  ok(moved.includes(esc(UX.tWhyPerson)), 'a person changed it');
  const region = mk('r-01', 'Linux', 'Standard_D2s_v4', [opt('v5', 'Standard_D2s_v5'), no('v6', ['not-in-region'])], { current: 'v5', extended: 'v5' });
  ok(F.advSummaryHelpHtml([region], 'current', new Map()).includes(esc(fill(UX.tWhyNot, { series: 'v6', why: UX.whyNot['not-in-region'] }))), 'the reason of the option itself');
  eq(F.advSummaryHelpHtml([v6a, v6b], 'current', new Map()), '', 'everything on the default: no (?)');
  ok(hasLine('<p class="muted" id="t-sum">${esc(advSummary(machines, tDefault, tOverrides, tSizes))}${sumHelp ? \' \' + tHelpBtn(\'sum\', UX.tSumAbout) : \'\'}</p>'), 'the (?) is on the summary line');
});

test('3: a change of the default keeps what a person changed', () => {
  ok(!/tDefault = e\.target\.value;[^\n]*tOverrides = new Map\(\)/.test(WIZ), 'the default no longer clears the changes');
  ok(hasLine('tDefault = e.target.value; render();'), 'it only sets the default');
  reset();
  const overrides = new Map([[v6a.vmId, 'v5']]);
  eq(F.advPick(v6a, 'extended', overrides), 'v5'); eq(F.advPick(v6a, 'current', overrides), 'v5', 'the change stays');
  eq(F.advPick(v6b, 'extended', overrides), 'v5'); eq(F.advPick(v6b, 'current', overrides), 'v6', 'an unchanged machine follows the default');
});

test('4: no tick boxes, Select all, Clear selection or Change the selected machines to', () => {
  for (const k of ['tSelectAll', 'tClearSel', 'tChangeTo', 'tApply', 'tApplied', 'tSkipped']) ok(!(k in UX), `${k} is gone`);
  for (const s of ['t-pick', 'id="t-all"', 'id="t-none"', 't-apply', 't-bulk', 'tSelected', 'tNote']) ok(!WIZ.includes(s), `${s} is gone`);
  reset(); globalThis.targetAdvice = { machines: [v6a] };
  ok(!F.tTargetRow(v6a).includes('type="checkbox"'), 'no box on a row');
  ok(WIZ.includes('data-kall'), 'the kernel All buttons stay');
});

// AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. The two targets of
// ADVISE-AN-1's processor-or-an choice are gone (an Intel machine is never
// offered an AMD size). The arrow stays for the processor row of a size.
test('5: the processor-or-an cards are gone; the processor row keeps the before and after arrow', () => {
  reset(); globalThis.targetAdvice = { machines: [choose] };
  eq(F.decideSectionHtml, undefined, 'no cards at all (REBUILD-REMOVE-PLAN-1)');
  eq(UX.tDecideAn, undefined);
  eq(UX.tDecideProc, undefined, 'no processor tag: the Details row keeps the arrow');
});

test('6: a size list names the maker only when it mixes makers', () => {
  reset(); globalThis.targetAdvice = { machines: [choose, bsv2] };
  globalThis.tOverrides = new Map([[choose.vmId, 'v5']]);
  const html = F.tTargetRow(choose);
  ok(html.includes(`>${esc(fill(UX.tSizeMaker, { size: 'D2as_v5', maker: 'AMD' }))}</option>`) && html.includes(`>${esc(fill(UX.tSizeMaker, { size: 'D2s_v5', maker: 'Intel' }))}</option>`), html);
  eq(F.sizeListMixed(choose.options[0].sizeChoices), true);
  eq(F.sizeListMixed(bsv2.options[0].sizeChoices), false);
  ok(!F.tTargetRow(bsv2).includes('(Intel)'), 'one maker: no brackets');
});

test('7: the first area is Same size, newer version, and the (?) of the second says exactly who is there', () => {
  eq(UX.tAreaSame, 'Same size, newer version');
  eq(UX.tAreaShapeHelp, 'Generation 1 machines, and sizes in the B v1, A v1, Av2, Amv2, D and DS v1 and v2, F, Fs and Fsv2 families.');
  // Every family the help names, oldShape puts in the area - and nothing else.
  const inArea = ['Standard_B2s', 'Standard_B1ls', 'Standard_B2ms', 'Standard_A2', 'Standard_A2_v2', 'Standard_A2m_v2', 'Standard_D2', 'Standard_DS2',
    'Standard_D2_v2', 'Standard_DS2_v2', 'Standard_DS13-4_v2', 'Standard_F2', 'Standard_F2s', 'Standard_F2s_v2'];
  for (const s of inArea) ok(F.oldShape({ gen: 'V2', sourceSize: s }), `${s} is in the area`);
  for (const s of ['Standard_D2s_v3', 'Standard_D2as_v4', 'Standard_E4s_v4', 'Standard_B2s_v2', 'Standard_D2s_v5']) ok(!F.oldShape({ gen: 'V2', sourceSize: s }), `${s} is not`);
  ok(F.oldShape({ gen: 'V1', sourceSize: 'Standard_D2s_v4' }), 'a Generation 1 machine is');
});

run('targets-owner-1');
