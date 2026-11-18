/* DETECT-PATTERNS-1: the workload type of each machine, with a filter, and
 * the Azure facts that decided it; and what to check before the move.
 *
 * The owner: the workload type is a column in the assessment with a filter,
 * and it shows the evidence (the field and the value) that decided it. A
 * single SQL Server machine is a warning, and the machine may still move.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { liftAll, liftConst, test, ok, eq, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const ASSESS = pageSource(path.join(REPO, 'src', 'dashboard', 'assessments.html'));
const reasons = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'assessment-reasons.json'), 'utf8'));
const listeners = {};
const ctx = { window: {}, document: { createElement: () => ({}), head: { appendChild() {} }, getElementById: () => null,
  addEventListener(kind, fn) { listeners[kind] = fn; } }, console };
vm.createContext(ctx);
vm.runInContext(pageSource(path.join(REPO, 'src', 'dashboard', 'assessment-report.js')), ctx);
const R = ctx.window.VmfReport;
Object.assign(R.REASONS.blockers, reasons.blockers);
Object.assign(R.REASONS.prep, reasons.prep);
Object.assign(R.REASONS.warnings, reasons.warnings);
Object.assign(R.REASONS.workloadTypes, reasons.workloadTypes);

const sub = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers';
const node = { vmId: `${sub}/Microsoft.Compute/virtualMachines/node1`, name: 'node1', classification: 'Blocked', blockers: ['shared-disk-cluster-node'], prepNeeded: [], warnings: [],
  workload: { type: 'cluster-or-database', evidence: [{ field: 'disk.maxShares', value: `2 (${sub}/Microsoft.Compute/disks/quorum)` }] } };
const sql = { vmId: `${sub}/Microsoft.Compute/virtualMachines/sql1`, name: 'sql1', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [], warnings: ['sql-server-agree-downtime'],
  workload: { type: 'cluster-or-database', evidence: [{ field: 'Microsoft.SqlVirtualMachine/sqlVirtualMachines', value: `${sub}/Microsoft.SqlVirtualMachine/sqlVirtualMachines/sql1` }] } };
const plain = { vmId: `${sub}/Microsoft.Compute/virtualMachines/web1`, name: 'web1', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [], warnings: [],
  workload: { type: 'standalone-vm', evidence: [] } };
const unread = { vmId: `${sub}/Microsoft.Compute/virtualMachines/app9`, name: 'app9', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [], warnings: ['workload-type-not-checked'],
  workload: { type: 'not-checked', evidence: [{ field: 'resourceGroup.managedBy', value: null }] } };
const old = { vmId: `${sub}/Microsoft.Compute/virtualMachines/old1`, name: 'old1', classification: 'ReadyAfterPrep', blockers: [], prepNeeded: [] };

test('each machine shows its workload type by name, and the Azure fact that decided it', () => {
  const html = R.workloadTableHtml([node, sql, plain]);
  ok(html.includes('node1') && html.includes(reasons.workloadTypes['cluster-or-database'].title), 'the type name');
  ok(html.includes('disk.maxShares: 2 ('), 'the field and the value');
  ok(html.includes('Microsoft.SqlVirtualMachine/sqlVirtualMachines: '), 'the SQL record');
  ok(html.includes(reasons.workloadTypes['standalone-vm'].title) && html.includes(R.TEXT.noFacts), 'a standalone machine says no fact shows another type');
});

test('a fact the scan could not read says so, and the type is not checked', () => {
  const html = R.workloadTableHtml([unread]);
  ok(html.includes('resourceGroup.managedBy: not read'), html);
  ok(html.includes(reasons.workloadTypes['not-checked'].title), 'Type not checked');
});

test('an assessment made before the type existed is not checked, never a standalone machine', () => {
  eq(R.workloadType(old), 'not-checked');
  const html = R.workloadTableHtml([old]);
  ok(!html.includes(reasons.workloadTypes['standalone-vm'].title), 'never Standalone machine');
});

test('the filter offers each type the machines have, with its count, and All first', () => {
  const html = R.workloadFilterHtml([node, sql, plain], '', 'f');
  ok(html.indexOf(R.TEXT.workloadAll + ' (3)') > -1, 'All with the total');
  ok(html.includes(`${reasons.workloadTypes['cluster-or-database'].title} (2)`), 'two of one type');
  ok(html.includes(`${reasons.workloadTypes['standalone-vm'].title} (1)`), 'one of another');
  ok(!html.includes(reasons.workloadTypes['vendor-appliance'].title), 'no option for a type nobody has');
  ok(R.workloadFilterHtml([node], 'cluster-or-database', 'f').includes('value="cluster-or-database" selected'), 'the choice is kept');
});

test('choosing a type hides the rows of every other type, and All shows them again', () => {
  const rows = ['cluster-or-database', 'standalone-vm'].map(t => ({ hidden: false, getAttribute: () => t }));
  const table = { hasAttribute: (a) => a === 'data-workload-table', querySelectorAll: () => rows };
  const select = { value: 'standalone-vm', closest: () => ({ nextElementSibling: table }) };
  R.filterWorkloadRows(select);
  eq(rows.map(r => r.hidden).join(','), 'true,false');
  select.value = '';
  R.filterWorkloadRows(select);
  eq(rows.map(r => r.hidden).join(','), 'false,false');
});

test('what to check before the move: the SQL Server warning, with its words, and nothing when no machine has one', () => {
  const html = R.warningsHtml([sql, plain]);
  ok(html.includes(R.TEXT.checkFirst) && html.includes(reasons.warnings['sql-server-agree-downtime'].title), 'the heading and the title');
  ok(html.includes('database owner'), 'the words say who agrees the downtime');
  eq(R.warningsHtml([plain]), '');
});

test('the Assessments page draws both, and the wizard review has the column, the filter and the facts', () => {
  ok(ASSESS.includes('html += window.VmfReport.warningsHtml(vms);'), 'warnings on the Assessments page');
  ok(ASSESS.includes('html += window.VmfReport.workloadTableHtml(vms);'), 'workload types on the Assessments page');
  global.window = ctx.window;
  global.UX = liftConst('wizard.html', 'UX');
  global.esc = (s) => String(s ?? '');
  global.vmName = (id) => String(id).split('/').pop();
  const f = liftAll('wizard.html', ['advGenLabel', 'reviewDetail', 'reviewTable']);
  global.advGenLabel = f.advGenLabel; global.reviewDetail = f.reviewDetail;
  global.rOpen = new Set(); global.rWorkload = '';
  let html = f.reviewTable([node, sql, plain]);
  ok(html.includes(UX.rColWorkload) && html.includes('id="r-workload"'), 'the column and the filter');
  ok(html.includes('sql1') && html.includes('web1'), 'every machine when All');
  global.rWorkload = 'standalone-vm';
  html = f.reviewTable([node, sql, plain]);
  ok(!html.includes('>sql1<') && html.includes('>web1<'), 'only the chosen type');
  global.rWorkload = '';
  global.rOpen = new Set([sql.vmId]);
  html = f.reviewTable([sql]);
  ok(html.includes(UX.rCheck) && html.includes(reasons.warnings['sql-server-agree-downtime'].title), 'Details: what to check');
  ok(html.includes(UX.rFacts) && html.includes('Microsoft.SqlVirtualMachine/sqlVirtualMachines: '), 'Details: the facts');
  global.rOpen = new Set();
  ok(WIZ.includes("$('#r-workload')?.addEventListener('change', (e) => { rWorkload = e.target.value; render(); });"), 'a change draws the step again');
});

run('workload-type');
