/* MANUAL-SHOTS-1: the sample answers the pages give with ?demo, so the
 * manual's pictures show the controls they are about.
 *
 * Each one stands in for an answer of the service. A stand-in in another shape
 * draws a control the service would not, and the picture then shows a screen
 * nobody meets. So each is run here and held to the fields the page reads from
 * the real answer - and each is held to ?demo: none of them may answer for a
 * signed-in page.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const page = (f) => pageSource(path.join(REPO, 'src', 'dashboard', f));

test('the wizard: the resource groups of a subscription, with the name as the id, as the service gives them', () => {
  const demoApi = lift('wizard.html', 'demoApi');
  const d = demoApi('GET', 'scopes?subscriptionId=00000000-0000-0000-0000-000000000000');
  eq(d.resourceGroups.length, 4);
  ok(d.resourceGroups.every(g => g.id === g.name && /^rg-/.test(g.name)), 'id is the name, as Get-VmfFacadeResourceGroupList answers');
  eq(JSON.stringify(demoApi('POST', 'runs/x/plan')), '{}', 'every other call answers with nothing, as before');
});

test('the migration page: the series a rolled-back machine may take, in the fields fillRetrySeries and askRetrySeries read', () => {
  globalThis.planDoc = { entries: [{ vmId: '/s/vm/prd-lin-c', wave: 'billing-apps', path: 'A',
    target: { size: 'Standard_D4s_v6' }, policy: { targetGeneration: 'v6' } }] };
  globalThis.vmName = (id) => String(id).split('/').pop();
  const demoAnswer = lift('migrations.html', 'demoAnswer');
  const a = demoAnswer('runs/x/plan/target', { vmId: '/s/vm/prd-lin-c', preview: true, afterRollback: true });
  eq(a.Current, 'v6');
  eq(a.PlanVersion, 'demo', 'the version askRetrySeries quotes back');
  eq(JSON.stringify(a.Options.map(o => [o.option, o.targetSize, o.current])),
    JSON.stringify([['v5', 'Standard_D4s_v5', false], ['v6', 'Standard_D4s_v6', true], ['v7', 'Standard_D4s_v7', false]]));
  // The page offers the series that are supported, not current and have a size.
  const offered = lift('migrations.html', 'retrySeriesOptions')(a).map(o => o.option);
  eq(JSON.stringify(offered), JSON.stringify(['v5', 'v7']));
  eq(JSON.stringify(demoAnswer('runs/x/vms/resolve', { vmId: '/s/vm/prd-lin-c' })), '{}', 'any other action answers with nothing');
});

test('the reports page: a sample machine has its sizes before, as the target and now', () => {
  const demoSizes = lift('reports.html', 'demoSizes');
  const entry = { assessment: { sourceSize: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' } };
  const moved = demoSizes(entry, { state: 'MIGRATED' });
  eq(JSON.stringify([moved.before, moved.target, moved.now]), JSON.stringify([
    { size: 'Standard_D2s_v4', controller: 'SCSI' }, { size: 'Standard_D2s_v6', controller: 'NVMe' },
    { size: 'Standard_D2s_v6', controller: 'NVMe', basis: 'sample data' }]));
  eq(demoSizes(entry, { state: 'MIGRATED', restore: { sizeAfter: 'Standard_D2s_v4' } }).now.controller, 'SCSI', 'a restore puts it back');
  eq(demoSizes(entry, { state: 'FAILED_ROLLED_BACK' }).now.size, 'Standard_D2s_v4', 'a rolled-back machine is on its size before');
});

test('each sample answer is reached only with ?demo', () => {
  ok(/if \(DEMO_MODE\) \{ await new Promise\(r => setTimeout\(r, 350\)\); return demoApi\(method, path\); \}/.test(page('wizard.html')));
  ok(/if \(DEMO_MODE\) \{ await new Promise\(r => setTimeout\(r, 400\)\); return demoAnswer\(path, body\); \}/.test(page('migrations.html')));
  ok(/\.\.\.demoSizes\(/.test(page('reports.html')) && /function demoRecord\(run\)/.test(page('reports.html')));
  ok(/if \(DEMO_MODE\) \{ return demoRecord\(run\); \}/.test(page('reports.html')), 'the record is built from samples only with ?demo');
});

run('manual-sample-data');
