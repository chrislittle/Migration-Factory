/* DRIFT-11-OTHER-OPTIONS-1: the targets step offered v6 to a machine that
 * cannot use accelerated networking there.
 *
 * Lab install, 2026-11-05, an Ubuntu 18.04 machine: Other options said
 * "v6 Available: D2s_v6. Accelerated networking is off on this size", and the
 * series list offered "v6: In-place upgrade". Every v6 size requires
 * accelerated networking (DRIFT-11) and gives the MANA adapter only, and that
 * release has no MANA driver. The engine now does not offer such a size (the
 * reason an-required-no-mana, Test-VmfAnRequiredWithoutMana). The page reads
 * the engine's facts: the series list shows only supported options, and Other
 * options says why v6 is not available. The rule behind the (?) says v6 is
 * Not offered for a release that is not on the MANA list.
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
globalThis.kernelOffered = F.kernelOffered;
const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set();
  globalThis.tASeen = new Set(); globalThis.targetAdvice = { machines: [] };
};

// The targets sample, which the engine made: the manual's pictures are taken from it.
const DEMO = (() => {
  const start = WIZ.indexOf('const DEMO = {');
  const end = WIZ.indexOf('// MANUAL-SHOTS-1: a planned migration of two waves');
  ok(start > 0 && end > start, 'the sample block');
  // eslint-disable-next-line no-eval
  return eval(`(() => { ${WIZ.slice(start, end)}; return DEMO; })()`);
})();
const sample = DEMO['demo-chosen/target-advice.json'];
const byName = (n) => sample.machines.find(m => m.name === n);

// AN-MANA-DRIVER-RULE-1 (2026-11-06): every test below is rewritten to
// the rule that replaced this item's. The reason an-required-no-mana asked only
// of a size that REQUIRES accelerated networking (every v6 size, Intel v5), and
// left v7 offered with it off. Now no size that can give MANA - v7 and Bsv2
// too - is offered to such a machine (no-mana-driver), so the Intel lab machine
// has no target, and the AMD one has AMD v5 only.
test('the reason has words, and the engine can send it', () => {
  ok(UX.whyNot['no-mana-driver'], 'no-mana-driver has words');
  eq(UX.whyNot['an-required-no-mana'], undefined, 'the old reason is gone');
  const schema = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'target-advice.schema.json'), 'utf8'));
  ok(schema.$defs.reason.enum.includes('no-mana-driver'), 'in the reason list');
  eq(schema.properties.schemaVersion.const, 33);
  eq(sample.schemaVersion, 33, 'the sample is the version the page reads');
});

test('RUN: the lab machine - no target, and Other options says why for v6 and v7', () => {
  reset();
  const m = byName('api-03');
  ok(m && m.linuxRelease.source === 'agent' && m.linuxRelease.mana === 'unlisted', 'Ubuntu 18.04, as the VM agent reports it');
  globalThis.targetAdvice = { machines: [m] };
  eq(F.tSeriesItems(m, new Map(), 'current').length, 0, 'nothing in the series list');
  globalThis.tOpen.add(m.vmId);
  const html = F.tTargetRow(m);
  ok(!html.includes(esc(fill(UX.tAvailableAnOff, { size: 'D2s_v7' }))), 'never "v7 Available ... off on this size"');
  ok(html.includes(esc(UX.tNoTarget)), 'no target');
  eq(html.split(esc(fill(UX.tNotAvailable, { why: UX.whyNot['no-mana-driver'] }))).length - 1, 3, 'v5, v6 and v7: not available, with the reason');
  ok(html.includes(esc(F.manaUpgradeText(m))) && /Ubuntu 22\.04/.test(F.manaUpgradeText(m)), 'and the release to upgrade to');
});

test('RUN: the AMD sample machine - AMD v5 only; v6 and v7 not available', () => {
  reset();
  const m = byName('api-a04');
  globalThis.targetAdvice = { machines: [m] };
  eq(F.tSeriesItems(m, new Map(), 'current').map(x => x.option), ['v5']);
  globalThis.tOpen.add(m.vmId);
  eq(F.tTargetRow(m).split(esc(fill(UX.tNotAvailable, { why: UX.whyNot['no-mana-driver'] }))).length - 1, 2, 'v6 and v7 say why');
});

test('the sample agrees with the rule: no option offered to such a machine can give MANA', () => {
  for (const key of ['demo-scan/target-advice.json', 'demo-chosen/target-advice.json']) {
    for (const m of DEMO[key].machines.filter(x => x.linuxRelease?.source === 'agent' && x.linuxRelease?.mana === 'unlisted')) {
      for (const o of m.options.filter(x => x.supported)) {
        for (const f of [o, ...(o.sizeChoices ?? [])]) {
          eq(f.acceleratedNetworking?.mayUseMana, false, `${key} ${m.name} ${o.option} ${f.size ?? f.targetSize}`);
        }
        ok(o.processorChange !== true, `${key} ${m.name} ${o.option}: never another processor maker`);
      }
      eq(m.decide ?? null, null, `${m.name}: no choice to make`);
    }
  }
});

test('RUN: the rule behind every accelerated networking (?) - no size that can give MANA is offered to a release that is not on the list', () => {
  const html = F.anRuleHtml();
  const rows = [...html.matchAll(/<tr><td>([\s\S]*?)<\/tr>/g)].map(r => [...r[0].matchAll(/<td>([^<]*)<\/td>/g)].map(x => x[1]));
  eq(rows, [
    [UX.tAnRuleSize.v6, UX.tAnRuleAdapter.v6, UX.vOn, UX.tAnRuleNotOffered, UX.vOn],
    [UX.tAnRuleSize.v7, UX.tAnRuleAdapter.v7, UX.vOn, UX.tAnRuleNotOffered, UX.vOn],
    [UX.tAnRuleSize.amd, UX.tAnRuleAdapter.amd, UX.vOn, UX.vOn, UX.vOn],
    [UX.tAnRuleSize.intel, esc(UX.tAnRuleAdapter.intel), UX.vOn, UX.tAnRuleNotOffered, UX.vOn],
    [UX.tAnRuleSize.bsv2, esc(UX.tAnRuleAdapter.bsv2), UX.vOn, UX.tAnRuleNotOffered, UX.vOn]]);
  eq([UX.tAnRuleSize.v6, UX.tAnRuleSize.v7, UX.tAnRuleAdapter.v6, UX.tAnRuleAdapter.v7], ['v6', 'v7', 'MANA', 'MANA']);
  ok(!('nvme' in UX.tAnRuleSize) && !('nvme' in UX.tAnRuleAdapter), 'no row that says v6 and v7 together');
});run('drift11-other-options');
