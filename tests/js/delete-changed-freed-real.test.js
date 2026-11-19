/* DELETE-CHANGED-FREED-1 (ruling 2026-11-06): Delete this migration
 * stays allowed, but a machine of it that is left changed is named in the
 * dialog, which says that machine is not as it was and that its safety copies
 * stay. The engine keeps them whichever choice is made (Test-VmfRunDiscardable).
 *
 * The rule is machineLeftChanged, held with the engine's
 * Test-VmfMachineLeftChanged to tests/fixtures/machine-left-changed.json.
 *
 * RUN, not read, and not in demo mode: the page boots with a stand-in service
 * whose store holds the machines given, and the dialog is opened as the
 * button opens it.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, run, msalStandIn } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const API = 'https://api.example.com/api';
const CONFIG = { clientId: 'client-1', tenantId: 'tenant-1', apiAppId: 'api-app', apiUrl: API };
const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute';
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'machine-left-changed.json'), 'utf8')).cases;

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
  return (url) => {
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
    return answer(404, { error: `no route ${route}` });
  };
}

async function turns(r, n) {
  for (let i = 0; i < n; i++) { await new Promise(done => setTimeout(done, 10)); await settle(r); }
}

/* A migration with these machines (name -> state document), opened, and its
 * dialog Delete this migration opened. */
async function dialogWords(machines) {
  const blobs = { 'mig-1/plan.json': { schemaVersion: 1, entries: Object.keys(machines).map(n => (
    { vmId: `${SUB}/virtualMachines/${n}`, wave: 'wave-1', path: 'A', source: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' } })) } };
  for (const [n, doc] of Object.entries(machines)) {
    blobs[`mig-1/state/${n}.json`] = Object.assign({ vmId: `${SUB}/virtualMachines/${n}` }, doc);
  }
  const msal = msalStandIn({ claims: { roles: ['Vmf.Operator'] } });
  const r = bootPage('migrations.html', { search: '?run=mig-1', fetch: service(blobs), globals: { msal },
    storage: { 'vmf-disclaimer-seen': '1' } });
  await turns(r, 15);
  eq(vm.runInContext('allVms.length', r.sandbox), Object.keys(machines).length, 'the page read every machine');
  vm.runInContext('askDiscardRun()', r.sandbox);
  await turns(r, 2);
  eq(r.errors, [], 'nothing thrown while the dialog opened');
  return { words: r.byId.get('m-desc').textContent, ux: vm.runInContext('UX_ACT', r.sandbox), r };
}

const changedDoc = { state: 'FAILED_NEEDS_ATTENTION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:08:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', machineState: 'changed' }] };
const leftOutChanged = { state: 'SKIPPED', history: [...changedDoc.history,
  { tsUtc: '2026-10-31T10:30:00Z', state: 'SKIPPED', outcome: 'skip', detail: 'left out' }] };
const migratedDoc = { state: 'MIGRATED', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:30:00Z', state: 'MIGRATED', outcome: 'ok' }] };
const rolledBack = { state: 'FAILED_ROLLED_BACK', history: [
  { tsUtc: '2026-10-31T10:20:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'bootFailedAfterConversion', machineState: 'restored' }] };

test('the rule: machineLeftChanged gives the answer of every case in the fixture the engine is held to', async () => {
  const { r } = await dialogWords({ 'app-1': migratedDoc });
  ok(CASES.length >= 12, `${CASES.length} cases`);
  for (const c of CASES) {
    const got = vm.runInContext(`machineLeftChanged(${JSON.stringify(c.doc)})`, r.sandbox);
    eq(got, c.expected, c.why);
  }
});

test('RUN: a migration with a machine left changed, and one left out changed - the dialog names both and says the copies stay', async () => {
  const { words, ux } = await dialogWords({ 'app-1': changedDoc, 'app-2': migratedDoc, 'app-3': leftOutChanged });
  eq(words, `${ux.discardRunDesc} ${ux.discardChanged.replace('{names}', 'app-1, app-3')}`, 'the words');
  ok(/not as they were before the move: app-1, app-3\./.test(words), words);
  ok(/keeps their safety copies, also if you select Delete the copies as well/.test(words), words);
});

test('RUN: a migration with no machine left changed - no word about it', async () => {
  const { words, ux } = await dialogWords({ 'app-1': migratedDoc, 'app-2': rolledBack });
  eq(words, ux.discardRunDesc, 'the words');
});

test('the words: two sentences, each 25 words or fewer', async () => {
  const { ux } = await dialogWords({ 'app-1': migratedDoc });
  const sentences = ux.discardChanged.split(/(?<=\.)\s+/);
  eq(sentences.length, 2, ux.discardChanged);
  for (const s of sentences) { ok(s.split(/\s+/).length <= 25, s); }
});

run('delete-changed-freed-real');
