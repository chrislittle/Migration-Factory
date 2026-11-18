/* ADVISE-AN-1, 2026-10-12: the screen shows nothing as unknown.
 *   - Intel v5 is not offered to a machine whose running Linux release has no
 *     MANA driver. AN-MANA-DRIVER-RULE-1: nor is any size that can give MANA,
 *     and an Intel machine is never offered the AMD size (no-mana-driver).
 *   - Where the release could not be read while the machine ran, the screen
 *     says what to do - "Start the machine, then assess again." - never
 *     Unknown, and no option is marked On or Off on a guess.
 *   - Every accelerated networking (?) shows the one rule as a table: it
 *     depends only on the Linux release and the adapter of the size.
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
const UX = globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');
globalThis.shortSize = (s) => String(s ?? '').replace(/^Standard_/, '');
globalThis.reasonText = (code) => String(code);

const F = liftAll('wizard.html', ['anRuleHtml', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'sizeListMixed',
  'tempLost', 'tDotWhy', 'tHelpBtn', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'manaUpgradeText', 'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf',
  'kernelSectionHtml', 'eusImageText', 'tCountText', 'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);
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
  targetStage: { stage: 'Current', basis: 'stated' }, stageChange: 'up', processorChange: false, processor: 'Intel' }, extra || {});
const mk = (name, options, start, extra) => Object.assign({ vmId: SUB + name, name, os: 'Linux', gen: 'V2', location: 'centralus', sourceSize: 'Standard_D2s_v4',
  processor: 'Intel', diskController: 'SCSI', acceleratedNicCount: 1, linuxRelease: null, sourceStage: { stage: 'Extended', basis: 'stated' }, options,
  start: start || { current: 'v6', extended: 'v5' }, decide: null }, extra || {});

// AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. Intel v5 is still not
// offered to such a machine, but neither is any size that can give MANA, and
// never the AMD size of an Intel machine - so an-intel-v5 (no AMD size in the
// region) cannot arise. Its reason is no-mana-driver now.
test('Intel v5 not offered: the reason is no-mana-driver now, and an-intel-v5 is gone', () => {
  eq(UX.whyNot['an-intel-v5'], undefined);
  ok(UX.whyNot['no-mana-driver'], 'the reason has words');
  const schema = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'target-advice.schema.json'), 'utf8'));
  ok(!schema.$defs.reason.enum.includes('an-intel-v5'), 'the engine cannot send the old reason');
  ok(schema.$defs.reason.enum.includes('no-mana-driver'), 'the engine can send it');
});

test('RUN: a Generation 1 machine whose only target is the AMD size starts on it; Details show the change of processor, and the row has no processor tag', () => {
  reset();
  const g1 = mk('g1-amd', [opt('v5', 'Standard_D2as_v5', { processorChange: true, processor: 'AMD', acceleratedNetworking: an(true, null) })],
    { current: 'v5', extended: 'v5' }, { gen: 'V1', sourceSize: 'Standard_DS2_v2' });
  globalThis.targetAdvice = { machines: [g1] };
  const html = F.tTargetRow(g1);
  ok(!html.includes('pill warn'), html);
  eq(UX.tDecideProc, undefined, 'the processor tag is gone: a machine keeps its processor maker');
  const row = F.advDetailRows(g1, 'v5', undefined).find(r => r[0] === UX.dProc);
  eq(row && row[1], 'Intel  →  AMD', 'Details: the processor, before and after');
  const same = mk('same', [opt('v6', 'Standard_D2s_v6')]);
  ok(!F.advDetailRows(same, 'v6', undefined).some(r => r[0] === UX.dProc), 'no row where the maker stays');
});

test('RUN: a release that could not be read says what to do - never Unknown, never On or Off', () => {
  reset();
  for (const why of ['release-unknown', 'image-unlisted']) {
    const m = mk(`r-${why}`, [opt('v6', 'Standard_D2s_v6', { acceleratedNetworking: an(null, why) })]);
    globalThis.targetAdvice = { machines: [m] };
    eq(F.advDetailRows(m, 'v6', undefined).find(r => r[0] === UX.dAn)[1], `${UX.vOn}  →  ${UX.vStartAssess}`, why);
    const html = F.tTargetRow(m);
    ok(html.includes(`<span class="pill warn">${esc(UX.vStartAssess)}</span>`), `${why}: the tag says what to do`);
    ok(!html.includes(`>${esc(UX.vUnknown)}<`) && !html.includes(esc(UX.tAnTag)), `${why}: nothing unknown, nothing off`);
    ok(UX.tAnKeepHelp[why].endsWith(UX.vStartAssess), `${why}: the (?) ends with the same action`);
  }
  eq(UX.vStartAssess, 'Start the machine, then assess again.');
});

test('RUN: the rule, as a table, behind every accelerated networking (?)', () => {
  const html = F.anRuleHtml();
  const rows = [...html.matchAll(/<tr><td>([\s\S]*?)<\/tr>/g)].map(r => [...r[0].matchAll(/<td>([^<]*)<\/td>/g)].map(x => x[1]));
  eq(rows, [
    // DRIFT-11-OTHER-OPTIONS-1: every v6 size requires it, so v6 is not offered for a release off the list.
    // AN-MANA-DRIVER-RULE-1: and no size that can give MANA is - v7 and Bsv2 too. No size keeps it off.
    [UX.tAnRuleSize.v6, UX.tAnRuleAdapter.v6, UX.vOn, UX.tAnRuleNotOffered, UX.vOn],
    [UX.tAnRuleSize.v7, UX.tAnRuleAdapter.v7, UX.vOn, UX.tAnRuleNotOffered, UX.vOn],
    [UX.tAnRuleSize.amd, UX.tAnRuleAdapter.amd, UX.vOn, UX.vOn, UX.vOn],
    [UX.tAnRuleSize.intel, esc(UX.tAnRuleAdapter.intel), UX.vOn, UX.tAnRuleNotOffered, UX.vOn],
    [UX.tAnRuleSize.bsv2, esc(UX.tAnRuleAdapter.bsv2), UX.vOn, UX.tAnRuleNotOffered, UX.vOn]]);
  ok(html.includes(esc(UX.tAnRule)) && html.includes(esc(UX.tAnRuleNic)), 'the rule and the different rule of 2 vCPUs');
  ok(/network interfaces does not change it/.test(UX.tAnRule), 'the number of interfaces does not matter');
  // AN-MANA-DRIVER-RULE-1: the processor-or-an choice that showed this table is
  // gone; REBUILD-REMOVE-PLAN-1 removed the identity choice too.
  eq(F.decideNoticeHtml, undefined, 'no choice notice is left');
});

// Decided 2026-10-12 (option B): the processor maker never changes without
// the person choosing it. A Generation 1 Intel machine whose only target is
// the AMD size is not started on it: one card, and one line on how to keep
// the Intel processor.
// AN-MANA-DRIVER-RULE-1 (2026-11-06): rewritten. An Intel machine whose
// only target was the AMD size waited for a choice of one card. An Intel
// machine is never offered an AMD size now, so the engine sends no such
// machine; a processor-or-an record, should one arrive, draws nothing.
test('RUN: the processor-or-an choice is gone - its cards are never drawn', () => {
  reset();
  const g1 = mk('g1-only', [opt('v5', 'Standard_D2as_v5', { processorChange: true, processor: 'AMD', acceleratedNetworking: an(true, null) })],
    { current: null, extended: null }, { gen: 'V1', sourceSize: 'Standard_DS2_v2',
      decide: { reason: 'processor-or-an', keepsProcessor: { current: null, extended: null, processor: 'Intel' }, keepsAn: { option: 'v5', size: 'Standard_D2as_v5', processor: 'AMD' } } });
  globalThis.targetAdvice = { machines: [g1] };
  eq(F.decideSectionHtml, undefined, 'no cards: REBUILD-REMOVE-PLAN-1 removed the choice cards');
  eq(UX.tDecideOnly, undefined, 'and no words for one card');
});run('an-certain');
