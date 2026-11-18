/* SIGNOFF-NULL-1: a plan that says nothing about approval is read ONE way.
 *
 * The engine's gate reads an entry that says nothing about the sign-off as
 * requiring it. The Migrations page read only `requireApproval: true`, so for
 * such an entry the gate's refusal named Approve and the page showed no
 * Approve button. A stored null or 0 was read two ways as well.
 *
 * Now one rule, fail-safe - only a stored boolean false turns the sign-off
 * off - in help.js (VmfHelp.approvalRequired), and the engine's copy
 * (Test-VmfApprovalRequired) is held to the SAME cases:
 * tests/fixtures/approval-required.json, run by tests/unit/SignoffNull.Tests.ps1.
 *
 * RUN, not read: the rule, and every page reader that uses it.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// ACCEPT-FIRST-MACHINE-1: the settings of a wave are read by the rule in
// help.js; waves.js names its parts (leverValue, keepsOwn, waveCard) as
// aliases of VmfHelp, so the page functions find them on the global object.
function waveRuleGlobal() { const r = require('./_at-once').waveRule; Object.assign(globalThis, { leverValue: r.leverValue, ownDecision: r.ownDecision, keepsOwn: r.keepsOwn, waveCard: r.waveCard }); return r; }
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'approval-required.json'), 'utf8'));
const approvalRequired = lift('help.js', 'approvalRequired');
const entryOf = (c, vmId = '/s/rg/vm/a', wave = 'w1') => Object.assign(JSON.parse(JSON.stringify(c.entry)), { vmId, wave, path: 'A' });

globalThis.VmfHelp = { approvalRequired, waveOrder: lift('help.js', 'waveOrder'), seriesLabel: lift('help.js', 'seriesLabel'),
  keepDaysText: lift('help.js', 'keepDaysText'),
  VmfRun: { link: (page) => page } };
// IDENTITY-LOSS-1: the real identity rule and the page helpers it draws with.
require('./_identity').help(globalThis.VmfHelp);
require('./_identity').pageGlobals();
globalThis.esc = (s) => String(s ?? '');

test('the fixture has the cases that were read two ways, and exactly one is off', () => {
  const names = FIXTURE.cases.map(c => c.name);
  for (const n of ['a stored null', 'a stored 0', 'a policy with no such key', 'an entry with no policy', 'an explicit false']) {
    ok(names.includes(n), n);
  }
  eq(FIXTURE.cases.filter(c => !c.required).length, 1);
});

for (const c of FIXTURE.cases) {
  test(`the rule (help.js): ${c.name} -> ${c.required}`, () => {
    eq(approvalRequired(entryOf(c)), c.required);
  });
}

test('the rule: no entry at all is required', () => {
  eq(approvalRequired(undefined), true);
  eq(approvalRequired(null), true);
});

// ---- the Reports page: who signed a wave off ------------------------------
{
  const UX = liftConst('reports.html', 'UX');
  globalThis.UX = UX;
  const page = liftAll('reports.html', ['signoffCell']);
  for (const c of FIXTURE.cases) {
    test(`Reports, sign-off column: ${c.name} -> asks for a sign-off = ${c.required}`, () => {
      globalThis.UX = UX;
      const said = page.signoffCell({ approvals: new Map(), planApproval: null }, 'w1', { vms: [entryOf(c)] });
      eq(said.includes(UX.noSignoffFound), c.required, said);
    });
  }
}

// ---- the wizard: the waves and their lever rows ---------------------------
{
  const UX = liftConst('wizard.html', 'UX');
  const planWaves = liftConst('wizard.html', 'planWaves');
  const leverRowsFor = lift('wizard.html', 'leverRowsFor');
// REBUILD-PICKER-1: the rebuild row it draws.
// TEMP-DISK-PREVIEW-1: the row of the machines that need the preview feature.
global.previewText = lift('wizard.html', 'previewText');
if (typeof global.vmName !== 'function') { global.vmName = (id) => String(id).split('/').pop(); }
  for (const c of FIXTURE.cases) {
    test(`wizard, the list of waves: ${c.name} -> approval = ${c.required}`, () => {
      globalThis.plan = { entries: [entryOf(c)] };
      const waves = planWaves();
      eq(waves.length, 1);
      eq(waves[0][1].approval, c.required);
    });
    test(`wizard, a wave's settings: ${c.name} -> the approval row says ${c.required ? 'yes' : 'no'}`, () => {
      globalThis.UX = UX;
      globalThis.plan = { entries: [entryOf(c)] };
      globalThis.anTurnsOnNames = () => []; globalThis.anDecidedNames = () => []; globalThis.newIdentityNames = () => [];
      globalThis.kernelUpdateNames = () => []; globalThis.diskChangeTexts = () => [];
      const rows = leverRowsFor('w1');
      const row = rows.split('</tr>').find(r => r.includes(`>${UX.lvApproval}<`));
      ok(row, 'the approval row is drawn');
      ok(row.includes(`<td>${c.required ? UX.lvYes : UX.lvNo}</td>`), row);
    });
  }
  test('wizard: a wave is read from EVERY machine, as the engine reads it - not from the first', () => {
    globalThis.UX = UX;
    const off = FIXTURE.cases.find(c => !c.required);
    const on = FIXTURE.cases.find(c => c.name === 'a stored null');
    globalThis.plan = { entries: [entryOf(off, '/s/rg/vm/a'), entryOf(on, '/s/rg/vm/b')] };
    eq(planWaves()[0][1].approval, true);
    ok(leverRowsFor('w1').includes(`<td>${UX.lvYes}</td>`));
  });
}

// ---- the wave editor: the card's tick -------------------------------------
{
  globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
  const card = ({ ...waveRuleGlobal(), ...liftAll('waves.html', []) });
  for (const c of FIXTURE.cases) {
    test(`wave editor, the sign-off tick: ${c.name} -> ${c.required}`, () => {
      eq(card.leverValue(entryOf(c), 'requireApproval'), c.required);
      eq(card.waveWideValue([entryOf(c)], 'requireApproval'), c.required);
    });
  }
}

// ---- the Migrations page: the accept dialog's settings --------------------
{
  const askAcceptOptions = lift('migrations.html', 'askAcceptOptions');
  for (const c of FIXTURE.cases) {
    test(`Migrations, accept dialog: ${c.name} -> the approval row says ${c.required ? 'yes' : 'no'}`, async () => {
      let opened = null;
      Object.assign(globalThis, {
        DEMO_MODE: true, currentRun: 'run-1', planDoc: { entries: [entryOf(c), entryOf(FIXTURE.cases.find(x => !x.required), '/s/rg/vm/b')] },
        vmName: (id) => String(id).split('/').pop(), newIdentityNames: () => [], anTurnsOnNames: () => [], anDecidedNames: () => [], kernelUpdateNames: () => [], diskChangeTexts: () => [],
        driverLeverOf: (es) => ((es ?? [])[0])?.policy ?? {}, leverKeepDays: (n) => `${Number(n ?? 7)} days`,
        openModal: (o) => { opened = o; }, apiFetch: async () => ({}),
        UX_LEVER: new Proxy({ requireApproval: 'APPROVAL-ROW', yes: 'SIGN-YES', no: 'SIGN-NO' }, { get: (t, k) => (k in t ? t[k] : String(k)) }),
        UX_ACT: new Proxy({}, { get: (t, k) => String(k) }),
      });
      await askAcceptOptions('w1');
      ok(opened, 'the dialog opened');
      // The first machine says what the case says; the second turned the
      // sign-off off. The wave needs one when ANY machine does, as the gate reads it.
      ok(opened.desc.includes(c.required ? 'SIGN-YES' : 'SIGN-NO'), opened.desc);
      ok(!opened.desc.includes(c.required ? 'SIGN-NO' : 'SIGN-YES'), 'and not the other answer');
    });
  }
}

// ---- review point 3: the gate reads EVERY machine of the wave ---------------
// Test-VmfWaveApproval reads every entry of the wave, a machine the plan does
// not move (path MANUAL) included - the wave editor's command form accepts any
// machine of the plan into a wave. The pages read the same set.
{
  const off = FIXTURE.cases.find(c => !c.required);
  const silent = FIXTURE.cases.find(c => c.name === 'an entry with no policy');
  const mixed = () => [entryOf(off, '/s/rg/vm/a'), Object.assign(entryOf(silent, '/s/rg/vm/m'), { path: 'MANUAL' })];
  test('wizard: a machine the plan does not move still makes its wave need a sign-off, as the gate reads it', () => {
    const UX = liftConst('wizard.html', 'UX');
    globalThis.UX = UX;
    globalThis.plan = { entries: mixed() };
    const waves = liftConst('wizard.html', 'planWaves')();
    eq(waves[0][1].n, 1, 'the count is still the machines that move');
    eq(waves[0][1].approval, true);
    globalThis.anTurnsOnNames = () => []; globalThis.anDecidedNames = () => []; globalThis.newIdentityNames = () => []; globalThis.kernelUpdateNames = () => []; globalThis.diskChangeTexts = () => [];
    ok(lift('wizard.html', 'leverRowsFor')('w1').includes(`<td>${UX.lvYes}</td>`));
  });
  test('Migrations accept dialog: the same', async () => {
    let opened = null;
    Object.assign(globalThis, { DEMO_MODE: true, planDoc: { entries: mixed() }, openModal: (o) => { opened = o; } });
    await lift('migrations.html', 'askAcceptOptions')('w1');
    ok(opened.desc.includes('SIGN-YES'), opened.desc);
  });
}

run('signoff-null');
