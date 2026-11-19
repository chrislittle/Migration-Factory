/* AN-MANA-DRIVER-RULE-1 (2026-11-06): a target that can give MANA
 * needs a machine with a MANA driver. An Intel Linux machine whose release has
 * no MANA driver possible is not moved, and an AMD one keeps its AMD v5 size;
 * the Details of the targets step say which release to upgrade to, then to
 * assess again.
 *
 * ONE fixture, tests/fixtures/an-mana-driver-rule.json: the engine is held to
 * its "expect" (tests/unit/AnManaDriverRule.Tests.ps1), and this page, given
 * a machine with those facts, to its "words".
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

const F = liftAll('wizard.html', ['anRuleHtml', 'anKept', 'anLost', 'anReleaseText', 'anHelpText', 'manaUpgradeText', 'sizeListMixed',
  'tempLost', 'tDotWhy', 'tHelpBtn', 'tTargetRow', 'tSqlRisk', 'tSqlFound', 'tNotTakenText', 'oldShape', 'sizeOf', 'premiumOf', 'disksOf', 'diskChoicesOf', 'osDiskTypes', 'kernelOffered', 'kernelOf',
  'kernelSectionHtml', 'eusImageText', 'tCountText', 'sizeChoiceLabel', 'advGenLabel', 'advSeriesLabel', 'advPick', 'advWhy', 'advDetailRows', 'tOptionLabel', 'tRecommended', 'tMethodOf', 'tSeriesItems', 'previewOn', 'previewOf', 'subOf', 'previewSubName', 'previewOffered', 'tPreviewLineHtml', 'tPreviewCheckBtn', 'tPreviewHelpHtml', 'tUnderRowHtml']);
globalThis.kernelOffered = F.kernelOffered;
const reset = () => {
  globalThis.tDefault = 'current'; globalThis.tOverrides = new Map(); globalThis.tSizes = new Map();
  globalThis.tDiskSel = new Map(); globalThis.tOpen = new Set(); globalThis.tHelp = new Set();
  globalThis.tKernelSel = new Map(); globalThis.tKernelDef = 'stop'; globalThis.tKSeen = new Set(); globalThis.tTSeen = new Set();
  globalThis.tASeen = new Set(); globalThis.targetAdvice = { machines: [] };
};

const FIXTURE = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'an-mana-driver-rule.json'), 'utf8'));

// A target advice machine with the fixture's facts: the options the engine
// supports and refuses, and the release it read (as Get-VmfTargetAdvice
// writes them; tests/unit/AnManaDriverRule.Tests.ps1 holds the engine to them).
function machineOf(c) {
  const linux = /^linux$/i.test(c.vm.os);
  const agent = c.vm.agent[0];
  const distro = { ubuntu: 'ubuntu', redhat: 'rhel', rocky: 'rocky', debian: 'debian', sles: 'sles' }[agent] ?? null;
  const options = ['v5', 'v6', 'v7'].map(option => {
    const supported = c.expect.offered.includes(option);
    const why = c.expect.refused[option];
    return {
      option, supported, notSupported: supported ? [] : [why ?? 'not-in-region'], targetSize: supported ? `Standard_D2s_${option}` : null,
      path: supported ? 'A' : 'MANUAL', move: option === 'v5' ? 'scsi-resize' : 'nvme-conversion', rebuild: false, preview: false,
      acceleratedNetworking: { required: null, mayUseMana: null, turnsOn: null, keptOn: null, keptOnWhy: null },
      stops: [], sizeChoices: [], prep: [], identity: null, processorChange: supported ? false : null,
    };
  });
  return {
    vmId: `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${c.name.length}`,
    name: 'm', os: c.vm.os, gen: 'V2', location: 'centralus', sourceSize: c.vm.size, processor: /_D2a/.test(c.vm.size) ? 'AMD' : 'Intel',
    linuxRelease: linux ? { distroId: distro, version: c.vm.agent[1] || null, source: agent ? 'agent' : 'image', mana: c.expect.listing, manaUpgrade: c.expect.manaUpgrade } : null,
    options, decide: null, start: c.expect.start,
  };
}

for (const c of FIXTURE.cases) {
  test(`RUN: ${c.name}`, () => {
    reset();
    const m = machineOf(c);
    globalThis.targetAdvice = { machines: [m] };
    const line = F.manaUpgradeText(m);
    if (!c.words.length) { eq(line, '', 'no upgrade line'); return; }
    for (const w of c.words) ok(line.includes(w), `"${w}" in: ${line}`);
    ok(/Upgrade the operating system/.test(line) && /assess again/.test(line), line);
    // In the Details of the row, first, and the refused options say why.
    globalThis.tOpen.add(m.vmId);
    const html = F.tTargetRow(m);
    ok(html.includes(esc(line)), 'the line is in Details');
    for (const [option, why] of Object.entries(c.expect.refused)) {
      ok(html.includes(esc(fill(UX.tNotAvailable, { why: UX.whyNot[why] }))), `${option}: not available, with the reason`);
    }
    if (!c.expect.offered.length) ok(html.includes(esc(UX.tNoTarget)), 'no target');
    // The (?) beside Other options opens the rule table (rule 11: one button, two states).
    ok(html.includes('data-help="an-0"'), 'a (?) on Other options');
    ok(!html.includes(F.anRuleHtml()), 'closed at first');
    globalThis.tHelp.add('an-0');
    ok(F.tTargetRow(m).includes(F.anRuleHtml()), 'open: the rule table');
    // Never a size of another processor maker: the series list holds only the
    // supported options, and none of them changes the maker.
    const items = F.tSeriesItems(m, new Map(), 'current');
    eq(items.map(x => x.option).filter((v, i, a) => a.indexOf(v) === i).sort().join(','), [...c.expect.offered].sort().join(','));
  });
}

test('a release Microsoft lists no later release of: the line names none, and says what to do', () => {
  const m = machineOf(FIXTURE.cases.find(c => c.expect.manaUpgrade));
  m.linuxRelease.manaUpgrade = null;
  const line = F.manaUpgradeText(m);
  eq(line, fill(UX.tManaUpgradeAny, { release: F.anReleaseText(m) }));
});

test('the reason has words, the engine can send it, and the old reasons are gone', () => {
  ok(UX.whyNot['no-mana-driver'], 'no-mana-driver has words');
  eq(UX.whyNot['an-required-no-mana'], undefined);
  eq(UX.whyNot['an-intel-v5'], undefined);
  const schema = JSON.parse(fs.readFileSync(path.join(REPO, 'schemas', 'target-advice.schema.json'), 'utf8'));
  ok(schema.$defs.reason.enum.includes('no-mana-driver'), 'in the reason list');
  ok(!schema.$defs.reason.enum.includes('an-required-no-mana'), 'the old reason is gone');
  ok(WIZ.includes(`const TARGET_ADVICE_VERSION = ${schema.properties.schemaVersion.const};`), 'the page reads the version the engine writes');
});

test('the rule behind the (?): v7 and Bsv2 are Not offered for a release that is not on the MANA list; AMD v5 is On', () => {
  const html = F.anRuleHtml();
  const rows = [...html.matchAll(/<tr><td>([^<]*)<\/td><td>[^<]*<\/td><td>([^<]*)<\/td><td>([^<]*)<\/td>/g)].map(r => [r[1], r[2], r[3]]);
  const unlisted = Object.fromEntries(rows.map(r => [r[0], r[2]]));
  eq(unlisted['v6'], UX.tAnRuleNotOffered);
  eq(unlisted['v7'], UX.tAnRuleNotOffered);
  eq(unlisted['Intel v5'], UX.tAnRuleNotOffered);
  eq(unlisted['Bsv2'], UX.tAnRuleNotOffered);
  eq(unlisted['AMD v5'], UX.vOn);
  ok(!rows.some(r => r[1] === UX.vOff || r[2] === UX.vOff), 'no size keeps it off');
});

test('the processor-or-an choice is gone: a machine with no target waits for no choice', () => {
  reset();
  const m = machineOf(FIXTURE.cases.find(c => !c.expect.offered.length));
  // REBUILD-REMOVE-PLAN-1: no machine waits for a choice at all now.
  eq(F.needsChoice, undefined);
  eq(F.decideSectionHtml, undefined);
  eq(m.start.current ?? null, null, 'it has no target');
});

// AN-PROCEED-NETVSC-1 (2026-11-06: a move is not allowed if the network will
// not work with AN): no page offers Continue for the driver floor.
// WAVE-KERNEL-LINE-1 (2026-11-14): and no wave has a kernel setting at
// all - the kernel choice belongs to each machine (the targets step), so no
// page shows a wave-level row for it. tests/js/wave-kernel-line.test.js runs
// the rows the pages draw instead.
test('AN-PROCEED-NETVSC-1: no page offers Continue for a kernel with no MANA driver', () => {
  const waves = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
  ok(!waves.includes('data-driver='), 'the wave card has no driver control');
  const W = liftConst('waves.html', 'UX');
  eq(W.driverProceed, undefined, 'the wave editor declares no Continue');
  eq(W.driverStop, undefined, 'nor a Stop and ask for a wave kernel setting');
  const mig = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
  ok(!mig.includes('driverProceed'), 'the acceptance has no Continue');
  ok(!mig.includes('UX_LEVER.driverStop'), 'nor a Stop and ask row for the kernel');
  ok(!WIZ.includes('lvDriverProceed'), 'the Run it step declares no Continue');
  ok(!WIZ.includes('UX.lvDriverStop'), 'nor a Stop and ask row for the kernel');
});

run();
