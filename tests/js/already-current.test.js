/* ALREADY-CURRENT-1: a machine on a Current size is in the group Current.
 *
 * Lab finding 81 (2026-11-05): Choose the machines and the assessment gave a
 * red "Cannot yet" to machines already on D2ds_v6, and the count line added
 * them in. The cause: a machine the product rebuilt has no image record in
 * Azure, so the scan reads a custom image and blocks it on every series.
 * The rule since 2026-11-06: a machine whose current size Microsoft puts in the
 * Current lifecycle stage is in the group Current, its line is
 * "<size> is in the Current lifecycle stage.", it is not red, it is not in the
 * Cannot yet count, and it cannot be selected. Every other machine that reads
 * Cannot yet shows its real reason on its row.
 *
 * RUN, not read: the shared report, the Assessments page, the wizard and the
 * run page, each with the cases of tests/fixtures/already-current.json - the
 * cases the engine test (tests/unit/AlreadyCurrent.Tests.ps1) holds the scan
 * to. The stage is the scan's (sourceLifecycle); no page reads it from a name.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const FIX = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'already-current.json'), 'utf8'));
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} }, fetch: async () => ({ ok: true, json: async () => reasons }), console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js')), ctx);
const R = ctx.window.VmfReport;
Object.assign(R.REASONS.blockers, reasons.blockers);
Object.assign(R.REASONS.prep, reasons.prep);
Object.assign(R.REASONS.warnings, reasons.warnings);

const SUB = '00000000-0000-0000-0000-000000000000';
// One assessment record for each case, in the shape the scan writes it.
const recordOf = (c, i) => {
  const name = 'm' + i;
  const r = { vmId: `/subscriptions/${SUB}/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/${name}`, name,
    resourceGroup: 'rg', location: 'centralus', sourceSize: c.sourceSize, classification: c.classification,
    blockers: c.blockers, prepNeeded: ['stornvme'], warnings: ['mana-driver-download'], tags: {} };
  if (c.platformManaged) r.platformManaged = true;
  if (!c.engineless) r.sourceLifecycle = c.engine ? { stage: c.engine, basis: 'stated' } : null;
  return r;
};
const CASES = FIX.cases.map((c, i) => ({ c, v: recordOf(c, i) }));
const VMS = CASES.map(x => x.v);
const named = (g) => CASES.filter(x => x.c.group === g).map(x => x.v.name);

test('the fixture holds every group, and the lab machines', () => {
  for (const g of ['current', 'can', 'some', 'cannot', 'excluded']) ok(named(g).length > 0, g);
  ok(FIX.cases.some(c => c.sourceSize === 'Standard_D2ds_v5' && c.group === 'cannot'), 'the v5 machine the lab read as Cannot yet');
  ok(FIX.cases.some(c => c.sourceSize === 'Standard_D2ds_v4' && /Site Recovery/.test(c.name)), 'the v4 machine with Site Recovery');
});

for (const { c, v } of CASES) {
  test(`the shared report: ${c.name}`, () => {
    eq(R.machineGroup(v), c.group, 'group');
    eq(R.machineWhy(v), c.why, 'the line on its row');
    eq(R.isCurrent(v), c.group === 'current', 'isCurrent');
    eq(R.canMigrate(v), ['can', 'some'].includes(c.group), 'canMigrate');
  });
}

test('the counts: a Current machine is counted once, as Current - never as Cannot yet, never as Can migrate', () => {
  const n = R.migrateCounts(VMS);
  eq(n.current, named('current').length, 'current');
  eq(n.cannotYet, named('cannot').length, 'cannot yet');
  eq(n.ready, named('can').length + named('some').length, 'can migrate');
  eq(n.someTargets, named('some').length, 'some targets');
  eq(n.excluded, named('excluded').length, 'excluded');
  eq(n.ready + n.cannotYet + n.excluded + n.current, VMS.length, 'every machine once');
  eq(R.migrateCounts([]).current, 0);
});

test('a Current machine is in no finding: not held back, not limited, nothing to prepare, nothing to check', () => {
  const current = new Set(named('current'));
  const { stops, limits } = R.splitBlockers(VMS);
  for (const [, names] of [...stops, ...limits, ...R.groupByCode(VMS, 'prepNeeded'), ...R.groupByCode(VMS, 'warnings')]) {
    ok(!names.some(nm => current.has(nm)), names.join(','));
  }
  // The machines that cannot move keep their finding.
  const image = stops.find(([code]) => code === 'image-not-supported');
  ok(image, 'the image finding is still there');
  eq(image[1].sort(), CASES.filter(x => x.c.group === 'cannot' && x.v.blockers.includes('image-not-supported')).map(x => x.v.name).sort());
});

test('the findings show a Current group: one line for each machine, in the approved words, not red', () => {
  const html = R.findingsHtml(VMS, { showPrep: true });
  const block = R.currentHtml(VMS);
  ok(html.includes(block), 'findingsHtml draws the Current group');
  ok(block.includes('>Current<'), 'the heading is Current');
  for (const { c, v } of CASES.filter(x => x.c.group === 'current')) {
    ok(block.includes(`<b>${v.name}</b> - ${c.why}`), `${v.name}: ${block}`);
  }
  ok(!/pill bad|"bad"/.test(block), 'not red');
  eq(R.currentHtml(VMS.filter(v => !R.isCurrent(v))), '', 'no group when no machine is Current');
  eq(R.TEXT.grpCurrent, 'Current');
  eq(R.TEXT.currentLine, '{size} is in the Current lifecycle stage.');
});

test('the stage is the scan\'s: a record with no stage is never Current, whatever its size name', () => {
  const v6 = { name: 'old', sourceSize: 'Standard_D2ds_v6', classification: 'ReadyAfterPrep', blockers: [] };
  eq(R.isCurrent(v6), false);
  eq(R.isCurrent({ ...v6, sourceLifecycle: null }), false);
  eq(R.isCurrent({ ...v6, sourceLifecycle: { stage: 'Extended', basis: 'stated' } }), false);
  eq(R.isCurrent({ ...v6, sourceSize: 'Standard_D2ds_v4', sourceLifecycle: { stage: 'Current', basis: 'stated' } }), true, 'the stage decides, not the name');
  const src = pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js'));
  const body = src.slice(src.indexOf('function isCurrent('), src.indexOf('function isCurrent(') + 400);
  ok(!/_v6|_v7|v\[67\]/.test(body), 'no size name in the rule');
});

// ---------- the Assessments page ----------
const reportHtml = lift('assessments.html', 'reportHtml');
const AUX = liftConst('assessments.html', 'UX');
// PAGE-SCALE-ASSESSMENTS-1: the list has two counts now, Machines found and
// Can migrate (the approved design); the Current machines are
// counted in the report beside it. So the rule held here is that the list
// never counts a Current machine as one that can migrate or cannot.
test('the Assessments list: Can migrate holds no Current machine, and the report beside it counts them', () => {
  const row = liftAll('assessments.html', ['assessmentRow', 'assessmentStatus', 'lastChange', 'deleteAction', 'nextAction']);
  global.esc = (s) => String(s);
  global.migrateCounts = R.migrateCounts;
  global.UX = AUX;
  global.STATUS_TAGS = { review: () => ({}), accepted: () => ({}), planned: () => ({}) };
  const had = global.VmfHelp;
  global.VmfHelp = { runTitle: () => 'name', VmfRun: { parse: () => ({}) } };
  Object.assign(global, row);
  const r = row.assessmentRow({ id: 'a1', projectId: null, when: null, machines: VMS.length, planned: [], approval: null, vms: VMS }, new Map());
  global.VmfHelp = had;
  eq(r.can, named('can').length + named('some').length, 'can migrate: the machines that can move, no Current one');
  eq(r.found, VMS.length, 'machines found: every machine');
  eq(AUX.colCurrent, 'Current');
});
test('the assessment report: a Current count that is not red, and the Current group', () => {
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
  ok(html.includes(`<span class="pill quiet">Current: ${named('current').length}</span>`), html.slice(0, 600));
  ok(html.includes(`<span class="pill bad">Cannot yet: ${named('cannot').length}</span>`), 'cannot yet counts only those');
  // A Current machine is not counted under Can migrate.
  ok(html.includes(`<span class="pill good">${AUX.clsReadyAfterPrep}: ${named('can').length}</span>`), 'a Current machine is not counted as Can migrate too');
  ok(html.includes(R.currentHtml(VMS)), 'the Current group is in the report');
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
// The target options for each machine: every series supported, so only the
// Current rule can stop one being ticked. sourceStage is what the target
// advice writes (Get-VmfAdviceStage, the function the scan uses).
const ADV = CASES.map(({ c, v }) => ({ vmId: v.vmId, name: v.name, sourceStage: c.engine ? { stage: c.engine, basis: 'stated' } : null,
  options: [{ option: 'v6', supported: true }] }));
const NONE = { sub: '', rg: '', tag: '', name: '' };

test('Choose the machines: each machine in its group; a Current machine is grey, says its line, and cannot be ticked', () => {
  globalThis.UX = WUX;
  const rows = W.chooseRows(VMS, ADV, (x) => x, R.canMigrate, undefined, R);
  for (const { c, v } of CASES) {
    const r = rows.find(x => x.name === v.name);
    if (c.group === 'excluded') { ok(!r, 'not listed'); continue; }
    eq(r.group, c.group, c.name);
    eq(r.why, c.why, c.name);
    eq(r.tickable, c.group !== 'current', `${c.name}: tickable`);
  }
  const html = W.chooseListHtml(rows, new Set(), NONE, 50, (s) => s);
  const drawn = html.split('<tr>').slice(2);
  for (const { c, v } of CASES.filter(x => x.c.group === 'current' || x.c.group === 'cannot')) {
    const tr = drawn.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes(`<div class="muted m-why">${esc(c.why)}</div>`), `${c.name}: ${tr}`);
    ok(c.group !== 'current' || tr.includes(`<span class="pill quiet">${WUX.grpCurrent}</span>`), `${c.name}: grey Current`);
    ok(c.group !== 'current' || !tr.includes('pill bad'), 'not red');
  }
  eq(WUX.grpCurrent, 'Current');
});

test('the target options decide too: a machine whose size the options call Current cannot be chosen', () => {
  eq(W.canChoose({ sourceStage: { stage: 'Current', basis: 'stated' }, options: [{ option: 'v7', supported: true }] }), false);
  eq(W.canChoose({ sourceStage: { stage: 'Extended', basis: 'stated' }, options: [{ option: 'v6', supported: true }] }), true);
  eq(W.canChoose({ sourceStage: null, options: [{ option: 'v6', supported: true }] }), true);
});

test('a machine the scan puts in Current cannot be ticked even when its target options carry no stage', () => {
  globalThis.UX = WUX;
  const noStage = ADV.map(a => ({ ...a, sourceStage: null }));
  const rows = W.chooseRows(VMS, noStage, (x) => x, R.canMigrate, undefined, R);
  for (const { v } of CASES.filter(x => x.c.group === 'current')) eq(rows.find(r => r.name === v.name).tickable, false, v.name);
});

// Review round 1: Review it said "None" for a Cannot yet machine, with its
// reason only behind Details; and the Details of a Current machine still
// listed its findings. RUN: the page's own functions.
const RV = liftAll('wizard.html', ['reviewDetail', 'reviewTable']);
function reviewGlobals(open) {
  globalThis.UX = WUX;
  global.window = { VmfReport: R };
  global.rWorkload = '';
  global.rOpen = new Set(open || []);
  global.advGenLabel = (g) => String(g ?? '');
  global.vmName = (id) => String(id).split('/').pop();
}
test('Review it: a Current row and a Cannot yet row each show their line where the open size series go', () => {
  reviewGlobals();
  const rows = RV.reviewTable(VMS).split('</tr>');
  for (const { c, v } of CASES.filter(x => x.c.group === 'current' || x.c.group === 'cannot')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes(`<span class="muted">${esc(c.why)}</span>`), `${c.name}: ${tr}`);
    ok(!tr.includes(`>${WUX.rNoTarget}<`), `${c.name}: not None`);
  }
});
test('Review it Details: a Current machine shows its line and no finding; a Cannot yet machine keeps its findings', () => {
  const cur = CASES.find(x => x.c.group === 'current' && x.v.blockers.includes('image-not-supported'));
  reviewGlobals([cur.v.vmId]);
  const det = RV.reviewDetail(cur.v);
  ok(det.includes(esc(cur.c.why)), det);
  for (const code of ['image-not-supported', 'stornvme', 'mana-driver-download']) {
    ok(!det.includes(esc((R.reasonOf(code) || {}).title)), `${code} is not listed: ${det}`);
  }
  const cannot = CASES.find(x => x.c.group === 'cannot').v;
  ok(RV.reviewDetail(cannot).includes(esc((R.reasonOf(cannot.blockers[0]) || {}).title)));
  ok(RV.reviewTable(VMS).includes(`<td colspan="6">${det}</td>`), 'the Details row draws it');
});

test('the page passes the shared report to the list', () => {
  ok(/chooseRows\(assessment\?\.vms, targetAdvice\.machines, vmName, window\.VmfReport\.canMigrate, mHeld, window\.VmfReport\)/.test(WIZ), 'chooseRowsNow');
});

test('the wizard review: the count line has Current, and Cannot yet without them', () => {
  ok(WIZ.includes('const { ready, cannotYet: blocked, current } = window.VmfReport.migrateCounts(vms);'), 'the counts');
  ok(WIZ.includes('${current ? ` &middot; <b>${current}</b> ${esc(UX.s2Current)}` : \'\'}'), 'the line');
  eq(WUX.s2Current, 'Current');
});

const foundRows = lift('wizard.html', 'foundRows');
test('the wizard\'s found list: Current, grey, with its line; Cannot yet with its reason', () => {
  global.window = { VmfReport: R };
  globalThis.UX = WUX;
  global.reasonText = (code) => (R.reasonOf(code) || {}).title || code;
  global.assessment = { vms: VMS };
  const html = foundRows();
  const rows = html.split('</tr>');
  for (const { c, v } of CASES.filter(x => x.c.group === 'current')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes('<span class="pill quiet">Current</span>') && tr.includes(c.why), tr);
  }
  for (const { c, v } of CASES.filter(x => x.c.group === 'cannot')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes('pill bad') && tr.includes(c.why), tr);
  }
});

// ---------- the run page ----------
const M = liftAll('migrations.html', ['foundCurrent', 'judgeForSeries', 'judgeUnplanned']);
const renderFound = lift('migrations.html', 'renderFound');
const MUX = liftConst('migrations.html', 'UX_FOUND');
const MUXT = liftConst('migrations.html', 'UX_FOUND_T');
test('the run page holds the same rule as the shared report, for every case', () => {
  for (const { c, v } of CASES) eq(M.foundCurrent(v), R.isCurrent(v), c.name);
  eq(MUXT.currentLine, R.TEXT.currentLine, 'the same words');
  eq(MUX.Current[0], 'Current');
});

function drawFound(plan) {
  let html = '';
  global.$ = (sel) => sel === '#found' ? { set innerHTML(x) { html = x; } } : null;
  global.esc = (s) => String(s);
  global.REASONS = { blockers: reasons.blockers, prep: reasons.prep };
  global.reasonText = (code) => (reasons.blockers[code] || reasons.prep[code] || {}).title || String(code);
  Object.assign(global, M);
  global.foundOpen = true;
  global.UX_FOUND = MUX;
  global.UX_FOUND_T = MUXT;
  renderFound({ vms: VMS }, Boolean(plan), plan);
  return html;
}
test('Machines we found: Current machines are grey, say their line, and are not counted as cannot migrate yet', () => {
  const html = drawFound(null);
  ok(html.includes(`<span class="pill quiet" title="">${named('current').length} ${MUX.Current[2]}</span>`), html.slice(0, 700));
  ok(html.includes(`<span class="pill bad" title="${MUX.Blocked[1]}">${named('cannot').length} ${MUX.Blocked[2]}</span>`), 'cannot yet counts the others only');
  const rows = html.split('<tr>');
  for (const { c, v } of CASES.filter(x => x.c.group === 'current')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes(`<span class="pill quiet" title="">Current</span>`) && tr.includes(`<td class="muted">${c.why}</td>`), tr);
  }
  for (const { c, v } of CASES.filter(x => x.c.group === 'cannot')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes('pill bad') && tr.includes(c.why), `${c.name}: ${tr}`);
  }
});

test('Machines we found, with a plan: a Current machine is Current, not "Not in this migration"', () => {
  const planned = CASES.find(x => x.c.group === 'can').v;
  const html = drawFound({ entries: [{ vmId: planned.vmId, policy: { targetGeneration: 'v6' }, path: 'B' }] });
  const rows = html.split('<tr>');
  for (const { v } of CASES.filter(x => x.c.group === 'current')) {
    const tr = rows.find(t => t.includes(`>${v.name}<`));
    ok(tr.includes('>Current</span>'), tr);
  }
});

run('already-current');
