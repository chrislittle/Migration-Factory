/* SERIES-COUNT-1: a machine with a size series still open to it can migrate.
 *
 * Found in the ADVISOR-1 end-to-end run. The review said "2 can migrate, 1
 * cannot yet" and drew a Generation 1 machine in red - although it was ready
 * for v5, and moved there. Both of its blockers name v6 and v7 only.
 * RUN: the shared report's own functions, with the engine's reasons file.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null, addEventListener() {} }, fetch: async () => ({ ok: true, json: async () => reasons }), console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js')), ctx);
const R = ctx.window.VmfReport;
Object.assign(R.REASONS.blockers, reasons.blockers);

const m = (name, classification, blockers) => ({ name, vmId: '/vm/' + name, classification, blockers });
const gen1 = m('g1', 'Blocked', ['gen1-requires-redeploy', 'image-cannot-boot-nvme']);

test('THE DEFECT: a Generation 1 machine ready for v5 can migrate', () => {
  eq(R.openSeries(gen1).join(','), 'v5');
  eq(R.canMigrate(gen1), true);
});

test('a machine blocked on every series cannot', () => {
  eq(R.canMigrate(m('conf', 'Blocked', ['confidential-vm-requires-manual'])), false);
});

test('a code this page does not know closes every series - never a pass', () => {
  eq(R.canMigrate(m('new', 'Blocked', ['a-code-from-a-newer-scan'])), false);
});

test('excluded stays out; a ready machine can', () => {
  eq(R.canMigrate(m('x', 'Excluded', [])), false);
  eq(R.canMigrate(m('r', 'ReadyAfterPrep', [])), true);
});

test('the cards split: what stops a machine everywhere is red, what closes some targets is not', () => {
  const html = R.findingsHtml([gen1, m('conf', 'Blocked', ['confidential-vm-requires-manual'])], {});
  const stopsAt = html.indexOf('What is holding machines back'), limitsAt = html.indexOf('What limits the target');
  ok(stopsAt >= 0 && limitsAt > stopsAt, 'two sections');
  const gen1Card = html.slice(limitsAt);
  ok(gen1Card.includes(reasons.blockers['gen1-requires-redeploy'].title), 'the Generation 1 reason is under the limits');
  ok(!html.slice(stopsAt, limitsAt).includes(reasons.blockers['gen1-requires-redeploy'].title), 'and not in red');
});

test('the wizard and the assessments page count with it', () => {
  const wiz = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
  const ass = pageSource(path.join(REPO, 'src', 'dashboard', 'assessments.html'));
  // ASSESS-COUNT-1: both now count through migrateCounts, which is built on
  // canMigrate (tests/js/assess-count.test.js runs it).
  ok(wiz.includes('window.VmfReport.migrateCounts(vms)'), 'wizard');
  ok(ass.includes('const counts = migrateCounts(vms);'), 'assessments');
});

run('series-count');
