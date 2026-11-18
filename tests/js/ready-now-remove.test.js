/* READY-NOW-REMOVE-1: no page says Already on a target size, or Already migrated.
 *
 * The scan gave the result ReadyNow to any machine on NVMe, and the pages
 * called it "Already on a target size" (the Assessments page) and "Already
 * migrated" (the wizard, the run page). After ALREADY-CURRENT-1 the only
 * machines left with it were the v5 sizes with NVMe, Ebsv5 and Ebdsv5, which
 * are in the Extended stage and have Ebsv6 as their successor. Owner,
 * 2026-11-06: such a machine is assessed like any other machine - Can migrate
 * when a target exists, else Cannot yet with its reason. The scan of
 * assessment v11 writes no ReadyNow; an older assessment that holds it reads
 * as ReadyAfterPrep (Can migrate) on every page, the engine's rule
 * (ConvertTo-VmfOwnClassification).
 *
 * RUN, not read: the shared report, the Assessments page, the wizard and the
 * run page, each with the cases of tests/fixtures/ready-now-remove.json - the
 * cases tests/unit/ReadyNowRemove.Tests.ps1 holds the engine to.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const FIX = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'ready-now-remove.json'), 'utf8'));
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} }, fetch: async () => ({ ok: true, json: async () => reasons }), console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js')), ctx);
const R = ctx.window.VmfReport;
Object.assign(R.REASONS.blockers, reasons.blockers);
Object.assign(R.REASONS.prep, reasons.prep);
Object.assign(R.REASONS.warnings, reasons.warnings);

const SUB = '00000000-0000-0000-0000-000000000000';
// One assessment record for each case: the classification the scan of this
// build writes, or the one an older assessment holds.
const recordOf = (c, i) => {
  const name = 'rn' + i;
  const r = { vmId: `/subscriptions/${SUB}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${name}`, name,
    resourceGroup: 'rg', location: 'centralus', sourceSize: c.sourceSize, diskController: c.diskController, os: c.os,
    classification: c.stored || c.scan, blockers: [], prepNeeded: c.nvmePrep || [], warnings: [], tags: {} };
  if (!c.engineless) r.sourceLifecycle = c.stage ? { stage: c.stage, basis: 'stated' } : null;
  return r;
};
const CASES = FIX.cases.map((c, i) => ({ c, v: recordOf(c, i) }));
const VMS = CASES.map(x => x.v);
const named = (g) => CASES.filter(x => x.c.group === g).map(x => x.v.name);
const GONE = ['Already migrated', 'Already on a target size', 'already migrated', 'already runs on a target size'];
const PAGES = ['assessments.js', 'assessment-report.js', 'wizard.js', 'migrations.js'];

test('the fixture holds the Ebsv5 and Ebdsv5 shapes, and no ReadyNow (OLD-VERSION-READERS-REMOVE-2)', () => {
  ok(FIX.cases.some(c => /_E\d+bs_v5$/.test(c.sourceSize) && c.diskController === 'NVMe' && c.group === 'can'), 'Ebsv5');
  ok(FIX.cases.some(c => /_E\d+bds_v5$/.test(c.sourceSize) && c.diskController === 'NVMe' && c.group === 'can'), 'Ebdsv5');
  ok(!FIX.cases.some(c => c.stored === 'ReadyNow'), 'no assessment holds ReadyNow');
  ok(!FIX.cases.some(c => c.scan === 'ReadyNow'), 'the scan of this build writes no ReadyNow');
});

test('no page holds the words, or a group for the result', () => {
  for (const file of PAGES) {
    const src = pageSource(path.join(REPO, 'src', 'dashboard', file));
    for (const w of GONE) ok(!src.includes(w), `${file} still says "${w}"`);
  }
  const WUX = liftConst('wizard.html', 'UX');
  ok(!('grpDone' in WUX), 'the wizard has no Already migrated group');
  ok(!('clsReadyNow' in liftConst('assessments.html', 'UX')), 'the Assessments page has no count for it');
  ok(!('ReadyNow' in liftConst('migrations.html', 'UX_FOUND')), 'the run page has no word for it');
});

for (const { c, v } of CASES) {
  test(`the shared report: ${c.name}`, () => {
    eq(R.machineGroup(v), c.group, 'group');
    eq(R.canMigrate(v), c.group === 'can', 'canMigrate');
  });
}

// ---------- the Assessments page ----------
const reportHtml = lift('assessments.html', 'reportHtml');
const AUX = liftConst('assessments.html', 'UX');
test('the assessment report: the machines that can migrate have one count', () => {
  global.UX = AUX;
  global.esc = (s) => String(s);
  global.ago = () => '';
  global.vmName = (id) => id;
  global.scopeText = () => ({ what: '', where: '' });
  // PAGE-SCALE-ASSESSMENTS-1: the report's head and its planned migrations; not what this test reads.
  global.scopeLineHtml = () => ''; global.reportTitle = (r) => r.id; global.plannedHtml = () => '';
  global.window = { VmfReport: R };
  Object.assign(global, { migrateCounts: R.migrateCounts, groupByCode: R.groupByCode, splitBlockers: R.splitBlockers,
    reasonCard: R.reasonCard, chipList: R.chipList });
  const html = reportHtml({ id: 'a1', vms: VMS, approval: null });
  ok(html.includes(`<span class="pill good">${AUX.clsReadyAfterPrep}: ${named('can').length}</span>`), html.slice(0, 600));
  ok(html.includes(`<span class="pill quiet">${AUX.colCurrent}: ${named('current').length}</span>`), 'Current');
  eq((html.match(/<span class="pill good">/g) || []).length, 1, 'one green count');
});

// ---------- the wizard ----------
globalThis.UX = liftConst('wizard.html', 'UX');
const WUX = globalThis.UX;
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');   // eslint-disable-line no-eval
globalThis.fill = eval('(' + WIZ.match(/const fill = ([^;]+);/)[1] + ')');   // eslint-disable-line no-eval
globalThis.M_PAGE = 50;
globalThis.subOfId = (id) => (String(id ?? '').match(/\/subscriptions\/([^/]+)/i) ?? [])[1] ?? '';
globalThis.VmfHelp = { idKey: (id) => String(id == null ? '' : id).toLowerCase() };
const W = liftAll('wizard.html', ['canChoose', 'chooseGroup', 'tagPairs', 'chooseRows', 'manaUpgradeText', 'anReleaseText', 'chooseMatches', 'chooseListHtml']);
// The target options as the engine writes them for each case: a supported v6
// where the plan finds a path, none where it does not.
const ADV = CASES.map(({ c, v }) => ({ vmId: v.vmId, name: v.name, sourceStage: c.engineless ? null : (c.stage ? { stage: c.stage, basis: 'stated' } : null),
  options: [{ option: 'v6', supported: Boolean(c.openV6) }] }));
const NONE = { sub: '', rg: '', tag: '', name: '' };

test('Choose the machines: each machine in the group the fixture says, and a machine on Ebsv5 or Ebdsv5 can be ticked', () => {
  globalThis.UX = WUX;
  const rows = W.chooseRows(VMS, ADV, (x) => x, R.canMigrate, undefined, R);
  for (const { c, v } of CASES) {
    const r = rows.find(x => x.name === v.name);
    eq(r.group, c.group, c.name);
    eq(r.tickable, c.group === 'can' && Boolean(c.openV6), `${c.name}: tickable`);
  }
  const html = W.chooseListHtml(rows, new Set(), NONE, 50, (s) => s);
  for (const { v } of CASES.filter(x => x.c.group === 'can')) {
    const tr = html.split('<tr>').find(t => t.includes(`>${v.name}<`));
    ok(tr.includes(`>${WUX.grpCan}<`), `${v.name}: ${tr}`);
  }
});

test('chooseGroup gives no group but excluded, current, can, some and cannot', () => {
  for (const { v } of CASES) ok(['current', 'can', 'some', 'cannot'].includes(W.chooseGroup(v, R.canMigrate, R)), v.name);
});

const foundRows = lift('wizard.html', 'foundRows');
test('the wizard\'s found list: a machine on Ebsv5 says Yes', () => {
  global.window = { VmfReport: R };
  globalThis.UX = WUX;
  global.reasonText = (code) => (R.reasonOf(code) || {}).title || code;
  global.assessment = { vms: VMS };
  const rows = foundRows().split('</tr>');
  for (const { c, v } of CASES.filter(x => x.c.group === 'can')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes('<span class="pill ">Yes</span>'), `${c.name}: ${tr}`);
  }
});

// ---------- the run page ----------
const M = liftAll('migrations.html', ['foundCurrent', 'judgeForSeries', 'judgeUnplanned']);
const renderFound = lift('migrations.html', 'renderFound');
const MUX = liftConst('migrations.html', 'UX_FOUND');
const MUXT = liftConst('migrations.html', 'UX_FOUND_T');
test('the run page judges by the engine rule, with and without a series', () => {
  global.REASONS = { blockers: reasons.blockers, prep: reasons.prep };
  for (const { c, v } of CASES.filter(x => x.c.stored === 'ReadyAfterPrep')) {
    eq(M.judgeForSeries(v, undefined).classification, c.readAs, c.name);
  }
  // Blocked by the scan for a reason that does not apply to v5, on NVMe.
  eq(M.judgeForSeries({ classification: 'Blocked', diskController: 'NVMe', blockers: ['gen1-requires-redeploy'], prepNeeded: [] }, 'v5').classification, 'ReadyAfterPrep');
});

test('Machines we found: the machines on Ebsv5 and Ebdsv5 are counted as can migrate', () => {
  let html = '';
  global.$ = (sel) => sel === '#found' ? { set innerHTML(x) { html = x; } } : null;
  global.esc = (s) => String(s);
  global.reasonText = (code) => (reasons.blockers[code] || reasons.prep[code] || {}).title || String(code);
  Object.assign(global, M);
  global.foundOpen = true;
  global.UX_FOUND = MUX;
  global.UX_FOUND_T = MUXT;
  renderFound({ vms: VMS }, false, null);
  ok(html.includes(`<span class="pill " title="${MUX.ReadyAfterPrep[1]}">${named('can').length} ${MUX.ReadyAfterPrep[2]}</span>`), html.slice(0, 700));
  for (const w of GONE) ok(!html.includes(w), w);
});

const notMovedReasons = lift('migrations.html', 'notMovedReasons');
test('a planned machine the plan does not move, on NVMe and a Current size, says it is on the size series of its target', () => {
  global.UX_MISC = liftConst('migrations.html', 'UX_MISC');
  global.UX_FOUND = MUX;
  global.judgeForSeries = M.judgeForSeries;
  const e = { vmId: 'vm', path: 'EXCLUDED', planNotes: [], policy: { targetGeneration: 'v6' },
    assessment: { classification: 'ReadyAfterPrep', diskController: 'NVMe', blockers: [], prepNeeded: [] } };
  eq(notMovedReasons(e)[0], global.UX_MISC.notMovedAlready);
});

// MANUAL-REVIEW-1 (2026-11-12: no lab facts in shipped words): the
// Lab run row and its plan note are gone. A move from NVMe to NVMe is allowed
// and says nothing about a lab.
test('the targets step: no Lab run row, and no plan note about a lab run', () => {
  const ps = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'plan', 'EntryClassification.ps1'), 'utf8');
  ok(!/No lab run has moved/.test(ps), 'no plan note');
  ok(!('vNvmeUnmeasured' in WUX) && !('dLabRun' in WUX), 'no strings');
  ok(!/dLabRun|vNvmeUnmeasured/.test(WIZ), 'no row in the Details of an option');
});

run('ready-now-remove');
