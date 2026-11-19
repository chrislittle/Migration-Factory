/* SKIP-CHANGED-FREED-1: a machine left out while it is changed stays claimed
 * by its migration.
 *
 * Leave this machine out released the claim whatever the stop left, so a
 * machine whose rollback did not finish was free for another migration, whose
 * first safety copy took the changed machine as "as it was". The engine now
 * keeps that claim (Skip-VmfVm, Test-VmfMachineLeftChanged) until a restore
 * mends the machine. The dialog says so, and only for that machine; and a
 * machine that was left out still offers Restore this machine, so the claim
 * always has a control that ends it (rules 11 and 12). REBUILD-REMOVE-RECOVER-1:
 * Rebuild this machine is gone, also for a machine an earlier version left
 * with no definition.
 *
 * RUN, not read, and not in demo mode: the page boots with a stand-in service
 * whose store holds one machine, its panel opens as a row click does, and the
 * dialog or the buttons are read from what the page drew.
 */
'use strict';
const vm = require('vm');
const { test, eq, ok, run, msalStandIn } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const API = 'https://api.example.com/api';
const CONFIG = { clientId: 'client-1', tenantId: 'tenant-1', apiAppId: 'api-app', apiUrl: API };
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute';
const VM = `${SUB}/virtualMachines/app-1`;
const ENTRY = { vmId: VM, wave: 'wave-1', path: 'B', source: { size: 'Standard_D2ds_v4' }, target: { size: 'Standard_D2ds_v6' } };

function answer(status, body, headers) {
  const text = typeof body === 'string' ? body : JSON.stringify(body ?? {});
  const h = headers || {};
  return {
    ok: status >= 200 && status < 300, status,
    json: () => Promise.resolve(JSON.parse(text)),
    text: () => Promise.resolve(text),
    headers: { get: (k) => h[String(k).toLowerCase()] ?? null },
  };
}

function service(blobs) {
  return (url, init) => {
    if (url === 'dashboard.config.json') { return answer(200, CONFIG); }
    if (!url.startsWith(API + '/')) { return undefined; }
    const route = url.slice(API.length + 1);
    const q = new URL(url).searchParams;
    if (route.startsWith('store/list')) {
      const prefix = q.get('prefix') || '';
      const under = Object.keys(blobs).filter(n => n.startsWith(prefix));
      if (!q.get('delimiter')) { return answer(200, { names: under }); }
      const rest = under.map(n => n.slice(prefix.length));
      return answer(200, {
        names: under.filter(n => !n.slice(prefix.length).includes('/')),
        prefixes: [...new Set(rest.filter(n => n.includes('/')).map(n => prefix + n.split('/')[0]))],
      });
    }
    if (route.startsWith('store/blob')) {
      const at = q.get('path');
      return at in blobs ? answer(200, blobs[at], { 'x-vmf-document-version': 'v-1' }) : answer(404, { error: 'not found' });
    }
    if (route === 'runs/mig-1/vms/skip' && (init && init.method) === 'POST') { return answer(200, { skipped: true }); }
    return answer(404, { error: `no route ${route}` });
  };
}

async function turns(r, n) {
  for (let i = 0; i < n; i++) { await new Promise(done => setTimeout(done, 10)); await settle(r); }
}

async function openPanel(stateDoc) {
  const blobs = {
    'mig-1/plan.json': { schemaVersion: 1, entries: [ENTRY] },
    'mig-1/state/app-1.json': Object.assign({ vmId: VM }, stateDoc),
  };
  const msal = msalStandIn({ claims: { roles: ['Vmf.Operator'] } });
  const r = bootPage('migrations.html', { search: '?run=mig-1', fetch: service(blobs), globals: { msal },
    storage: { 'vmf-disclaimer-seen': '1' } });
  await turns(r, 15);
  vm.runInContext(`openDrill(allVms.find(v => v.vmId === ${JSON.stringify(VM)}),
    planDoc.entries.find(e => e.vmId === ${JSON.stringify(VM)}), ${JSON.stringify(VM)})`, r.sandbox);
  await turns(r, 3);
  eq(r.errors, [], 'nothing thrown while the scripts ran');
  return r;
}

/* What the panel painted. The stand-in document gives an element for any id
 * selector, so a button is proven by the markup the page wrote. */
function panelHtml(r) {
  const body = r.byId.get('drill-body');
  ok(body, 'the page has the panel body');
  return String(body.innerHTML);
}

async function dialogWords(stateDoc) {
  const r = await openPanel(stateDoc);
  const btn = r.sandbox.document.querySelector('#skip-btn');
  ok(btn, 'the panel draws Leave this machine out');
  btn.click();
  await turns(r, 2);
  eq(r.errors, [], 'nothing thrown while the dialog opened');
  return { words: r.byId.get('m-desc').textContent, ux: vm.runInContext('UX_ACT', r.sandbox) };
}

const changedStop = { tsUtc: '2026-10-31T10:08:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', machineState: 'changed' };
const rollbackFailed = { state: 'FAILED_NEEDS_ATTENTION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:03:00Z', state: 'GUEST_PREP', outcome: 'ok' }, changedStop] };
const rolledBack = { state: 'FAILED_ROLLED_BACK', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:20:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'bootFailedAfterConversion', machineState: 'restored' }] };
const atPrecheck = { state: 'NEEDS_DECISION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'targetTooFewNics', machineState: 'untouched' }] };

/* A machine left out after a Path B rollback that deleted the definition and
 * did not rebuild it: the record holds the capture and the safety copy. */
function leftOutStranded() {
  return {
    state: 'SKIPPED', pathCheckpoint: 'B:shellDeleted',
    safety: { snapshotId: `${SUB}/snapshots/app-1-snap` },
    captured: { vmConfig: { name: 'app-1', osType: 'Windows', size: 'Standard_D2ds_v4', controller: 'SCSI',
      osDisk: { name: 'app-1-os', managedDiskId: `${SUB}/disks/app-1-os` }, dataDisks: [], nics: [] } },
    history: [
      { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
      changedStop,
      { tsUtc: '2026-10-31T10:30:00Z', state: 'SKIPPED', outcome: 'skip', detail: 'left out by operator@example.com: later' }],
  };
}

test('RUN: a machine the rollback left changed - the dialog says no other migration can take it until a restore', async () => {
  const { words, ux } = await dialogWords(rollbackFailed);
  eq(words, `${ux.skipDesc} ${ux.skipChanged} ${ux.skipClaimKept}`, 'the words');
  ok(/No other migration can take this machine/.test(words), words);
  ok(/until you restore it\./.test(words), words);
  ok(!/rebuild/i.test(ux.skipClaimKept), 'no action that is gone');
});

test('RUN: a data disk swap that is left is a changed machine - the dialog says the claim stays', async () => {
  const doc = JSON.parse(JSON.stringify(rolledBack));
  doc.state = 'FAILED_NEEDS_ATTENTION';
  doc.swapPending = { kind: 'rollback', swaps: [] };
  const { words, ux } = await dialogWords(doc);
  eq(words, `${ux.skipDesc} ${ux.skipChanged} ${ux.skipClaimKept}`, 'the words');
});

test('RUN: a machine with nothing changed, one the product rolled back, and one restored after the stop - no word about the claim', async () => {
  for (const doc of [atPrecheck, rolledBack, Object.assign(JSON.parse(JSON.stringify(rollbackFailed)), { restore: { restoredUtc: '2026-10-31T12:00:00Z' } })]) {
    const { words, ux } = await dialogWords(doc);
    ok(!words.includes(ux.skipClaimKept), words);
  }
});

test('RUN: a changed machine that was left out with no virtual machine still offers Restore this machine, and no rebuild', async () => {
  const html = panelHtml(await openPanel(leftOutStranded()));
  ok(!html.includes('id="rebuild-btn"'), 'REBUILD-REMOVE-RECOVER-1: Rebuild this machine is gone');
  ok(html.includes('id="restore-btn"'), 'Restore this machine is drawn: it is the control that ends the kept claim');
  ok(!html.includes('id="skip-btn"'), 'it is left out already');
});

test('RUN: a machine left out before it started offers no rebuild', async () => {
  const html = panelHtml(await openPanel({ state: 'SKIPPED', history: [
    { tsUtc: '2026-10-31T10:00:00Z', state: 'SKIPPED', outcome: 'skip', detail: 'left out' }] }));
  ok(html.length > 0, 'the panel drew');
  ok(!html.includes('id="rebuild-btn"'), 'nothing to rebuild');
});

test('the words: one sentence, said only of the claim', async () => {
  const { ux } = await dialogWords(atPrecheck);
  ok(typeof ux.skipClaimKept === 'string' && ux.skipClaimKept.length > 0, 'declared');
  ok(ux.skipClaimKept.split(/\s+/).length <= 25, ux.skipClaimKept);
});

run('skip-changed-freed-real');
