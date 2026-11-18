/* ASSESS-COUNT-1: the Assessments list counts the way the report beside it does.
 *
 * SERIES-COUNT-1 taught the report and the wizard that a machine with a size
 * series still open to it can migrate. The list's "Cannot yet" column and its
 * tiles still counted every machine the scan called Blocked - and Excluded
 * ones too - so the list said 3 cannot yet where its own report said 0.
 *
 * One rule, in the shared report (migrateCounts), and every count on both
 * pages uses it. RUN: the shared report's own functions, with the engine's
 * reasons file, and the page's own drawing functions lifted out of it.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} }, fetch: async () => ({ ok: true, json: async () => reasons }), console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js')), ctx);
const R = ctx.window.VmfReport;
Object.assign(R.REASONS.blockers, reasons.blockers);

const m = (name, classification, blockers, extra) => Object.assign({ name, vmId: '/vm/' + name, classification, blockers }, extra || {});
// The example shape: a Generation 1 machine the scan calls Blocked,
// open to v5; one blocked everywhere; one excluded; two ready.
const vms = [
  m('g1', 'Blocked', ['gen1-requires-redeploy', 'image-cannot-boot-nvme']),
  m('conf', 'Blocked', ['confidential-vm-requires-manual']),
  m('aks', 'Excluded', []),
  m('pm', 'Blocked', [], { platformManaged: true }),
  m('r1', 'ReadyAfterPrep', []),
  m('r2', 'ReadyAfterPrep', []),
];

test('the shared rule: open to a series = can migrate; excluded and platform-managed are neither', () => {
  const c = R.migrateCounts(vms);
  eq(c.ready, 3, 'g1 (v5), r1, r2');
  eq(c.cannotYet, 1, 'only conf is closed on every series');
  eq(c.someTargets, 1, 'g1 is open to some series only');
  eq(c.excluded, 2, 'aks and the platform-managed machine');
  eq(c.ready + c.cannotYet + c.excluded, vms.length, 'every machine counted once');
});

test('no machines: all zero, never NaN', () => {
  const c = R.migrateCounts([]);
  eq(`${c.ready}/${c.cannotYet}/${c.someTargets}/${c.excluded}`, '0/0/0/0');
  eq(R.migrateCounts(undefined).ready, 0);
});

// PAGE-SCALE-ASSESSMENTS-1: the list's tiles count assessments now (To
// review, Accepted, Planned, All), and each row has one machine count that
// can move - Can migrate - beside Machines found. The row is RUN here.
const rowFns = liftAll('assessments.html', ['assessmentRow', 'assessmentStatus', 'lastChange', 'deleteAction', 'nextAction']);
test("THE DEFECT: a row's Can migrate counts by the shared rule", () => {
  const had = global.VmfHelp;
  global.esc = (s) => String(s);
  global.migrateCounts = R.migrateCounts;
  global.UX = new Proxy({}, { get: (_, k) => String(k) });
  global.STATUS_TAGS = { review: () => ({}), accepted: () => ({}), planned: () => ({}) };
  global.VmfHelp = { runTitle: () => 'name', VmfRun: { parse: () => ({}) } };
  Object.assign(global, rowFns);
  const row = (list) => rowFns.assessmentRow({ id: 'a', projectId: null, when: null, machines: list.length, planned: [], approval: null, vms: list }, new Map());
  eq([row(vms).can, row(vms).found], [3, 6], 'was 2 ready: g1 is open to v5');
  eq(row([m('g', 'Blocked', ['gen1-requires-redeploy'])]).can, 1, 'a Generation 1 machine open to v5');
  eq(row([m('c', 'Blocked', ['confidential-vm-requires-manual'])]).can, 0, 'closed on every series');
  global.VmfHelp = had;
});
// The report beside the list, run: its pills must be the same numbers.
const reportHtml = lift('assessments.html', 'reportHtml');
test('the report counts the same machines the same way', () => {
  global.UX = new Proxy({}, { get: (_, k) => String(k) });
  global.esc = (s) => String(s);
  global.ago = () => '';
  global.vmName = (id) => id;
  global.scopeText = () => ({ what: '', where: '' });
  // PAGE-SCALE-ASSESSMENTS-1: the report's head and its planned migrations; not what this test reads.
  global.scopeLineHtml = () => ''; global.reportTitle = (r) => r.id; global.plannedHtml = () => '';
  global.window = { VmfReport: R };
  Object.assign(global, { migrateCounts: R.migrateCounts, groupByCode: R.groupByCode, splitBlockers: R.splitBlockers,
    reasonCard: R.reasonCard, chipList: R.chipList });
  const html = reportHtml({ id: 'a1', vms, approval: null });
  for (const want of ['clsReadyAfterPrep: 2', 'clsSomeTargets: 1', 'clsBlocked: 1', 'clsExcluded: 2']) {
    ok(html.includes(want), `${want} in ${html.slice(0, 400)}`);
  }
});

// The migrations page, before a plan: its list of found machines.
const judgeForSeries = lift('migrations.html', 'judgeForSeries');
const judgeUnplanned = lift('migrations.html', 'judgeUnplanned');
test('the migrations page calls a Generation 1 machine with no series yet "some targets only"', () => {
  global.judgeForSeries = judgeForSeries;
  global.REASONS = { blockers: reasons.blockers, prep: reasons.prep ?? {} };
  eq(judgeUnplanned(vms[0]).classification, 'SomeTargets', 'g1 is open to v5');
  eq(judgeUnplanned(vms[1]).classification, 'Blocked', 'conf is closed everywhere');
  eq(judgeUnplanned(vms[4]).classification, 'ReadyAfterPrep', 'r1 can migrate');
  eq(judgeUnplanned(vms[2]).classification, 'Excluded');
});

const renderFound = lift('migrations.html', 'renderFound');
// ALREADY-CURRENT-1: renderFound asks the page's Current rule first.
global.foundCurrent = lift('migrations.html', 'foundCurrent');
test('the migrations page draws it: an amber "some targets only" pill, before any plan', () => {
  let html = '';
  global.$ = (sel) => sel === '#found' ? { set innerHTML(v) { html = v; } } : null;
  global.esc = (s) => String(s);
  global.reasonText = (c) => c;
  global.judgeUnplanned = judgeUnplanned;
  global.foundOpen = false;
  global.UX_FOUND = { ReadyAfterPrep: ['Yes', '', 'can migrate'], Blocked: ['Not yet', '', 'cannot migrate yet'],
    SomeTargets: ['Some targets only', '', 'some targets only'] };
  global.UX_FOUND_T = new Proxy({}, { get: (_, k) => String(k) });
  renderFound({ vms: [vms[0], vms[1], vms[4]] }, null, null);
  ok(html.includes('<span class="pill warn" title="">1 some targets only</span>'), 'summary: ' + html.slice(0, 500));
  ok(html.includes('<span class="pill bad" title="">1 cannot migrate yet</span>'), 'summary counts conf only');
});

// The wizard's "What we found" step.
const foundRows = lift('wizard.html', 'foundRows');
test('the wizard\'s found list says "Some targets only", not "Not yet", for a machine open to v5', () => {
  global.window = { VmfReport: R };
  global.esc = (s) => String(s);
  global.reasonText = (c) => c;
  global.assessment = { vms: [vms[0], vms[1]] };
  const html = foundRows();
  const [g1Row, confRow] = html.split('</tr>');
  ok(g1Row.includes('Some targets only') && g1Row.includes('pill warn'), g1Row);
  ok(confRow.includes('Not yet') && confRow.includes('pill bad'), confRow);
});

test('the list, its report and the wizard all count through the shared rule', () => {
  const page = pageSource(path.join(REPO, 'src', 'dashboard', 'assessments.html'));
  const wizard = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
  ok(!/startsWith\('Ready'\)/.test(page), 'the list no longer counts "Ready*" by name');
  ok(!/vms\.length - ready/.test(page), 'nor "everything else is blocked"');
  ok((page.match(/migrateCounts\(/g) || []).length >= 2, 'the list and the report use it');
  ok(/migrateCounts\(/.test(wizard), 'the wizard uses it');
});

run('assess-count');
