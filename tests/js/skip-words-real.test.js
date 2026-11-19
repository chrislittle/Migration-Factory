/* SKIP-PREPARED-WORDS-1: "Leave this machine out" says where the stop left
 * the machine, and only that.
 *
 * The dialog said "Its operating system was already prepared for the new
 * hardware, so it is not exactly as it was." whenever the machine's history
 * held GUEST_PREP. On the lab walk (2026-10-31) it opened on a
 * machine that had ROLLED BACK: the rollback put the first safety copy back,
 * so the sentence was false. History says a step ran, not what it left. The
 * engine records what it left on every stop (machineState, FAIL-1), and the
 * page now reads that, from the stop that still describes the machine
 * (currentStop, PANEL-OLD-STOP-1).
 *
 * RUN, not read, and not in demo mode: the page boots with a stand-in service
 * whose store holds one machine, its panel opens as a row click does, and
 * "Leave this machine out" is pressed. The rule itself is held to
 * tests/fixtures/skip-machine-state.json, the list the engine is held to.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, run, msalStandIn } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const API = 'https://api.example.com/api';
const CONFIG = { clientId: 'client-1', tenantId: 'tenant-1', apiAppId: 'api-app', apiUrl: API };
const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-1';
const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'skip-machine-state.json'), 'utf8')).cases;

const V6 = { vmId: VM, wave: 'wave-1', path: 'A', source: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' } };
const V5 = { vmId: VM, wave: 'wave-1', path: 'A', source: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v5' } };

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

/** A stand-in service over a store with one machine. */
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

async function boot(stateDoc, entry) {
  const blobs = {
    'mig-1/plan.json': { schemaVersion: 1, entries: [entry || V6] },
    'mig-1/state/app-1.json': Object.assign({ vmId: VM }, stateDoc),
  };
  const msal = msalStandIn({ claims: { roles: ['Vmf.Operator'] } });
  const r = bootPage('migrations.html', { search: '?run=mig-1', fetch: service(blobs), globals: { msal },
    storage: { 'vmf-disclaimer-seen': '1' } });
  await turns(r, 15);
  return r;
}

/** The words of the Leave this machine out dialog, for a machine with this state document. */
async function dialogWords(stateDoc, entry) {
  const r = await boot(stateDoc, entry);
  vm.runInContext(`openDrill(allVms.find(v => v.vmId === ${JSON.stringify(VM)}),
    planDoc.entries.find(e => e.vmId === ${JSON.stringify(VM)}), ${JSON.stringify(VM)})`, r.sandbox);
  await turns(r, 3);
  const btn = r.sandbox.document.querySelector('#skip-btn');
  ok(btn, 'the panel draws Leave this machine out');
  btn.click();
  await turns(r, 2);
  eq(r.errors, [], 'nothing thrown while the scripts ran');
  const ux = vm.runInContext('UX_ACT', r.sandbox);
  return { words: r.byId.get('m-desc').textContent, ux };
}

const atPrecheck = { state: 'NEEDS_DECISION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:01:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'targetTooFewNics', machineState: 'untouched' }] };
const prepNothingChanged = { state: 'NEEDS_DECISION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:02:00Z', state: 'SAFETY_PRISTINE', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:03:00Z', state: 'GUEST_PREP', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:04:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'driverBelowFloor', machineState: 'untouched' }] };
const prepRolledBackDecision = { state: 'NEEDS_DECISION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:03:00Z', state: 'GUEST_PREP', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:09:00Z', state: 'NEEDS_DECISION', outcome: 'fail', reasonCode: 'driverBelowFloor', machineState: 'restored' }] };
const rolledBack = { state: 'FAILED_ROLLED_BACK', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:03:00Z', state: 'GUEST_PREP', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:05:00Z', state: 'STOPPED', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:07:00Z', state: 'CONVERTING', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:20:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'bootFailedAfterConversion', machineState: 'restored' }] };
const rollbackFailed = { state: 'FAILED_NEEDS_ATTENTION', history: [
  { tsUtc: '2026-10-31T10:00:00Z', state: 'PRECHECK', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:03:00Z', state: 'GUEST_PREP', outcome: 'ok' },
  { tsUtc: '2026-10-31T10:08:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', machineState: 'changed' }] };

const PREPARED = /prepared/i;
/* RETRY-LATER-WORDS-1 (ruled 2026-11-04): a later change window is a
 * NEW migration. "You can migrate it later" did not say how, and a person
 * who wanted to come back to the machine looked for a later wave of this
 * migration. Leave this machine out is the choice for that, and it says so. */
const LATER = /To move this machine in a later change window, plan it again in a new migration\./;
const VAGUE = /migrate (it|this machine) later/i;
const DESC = 'This machine does not migrate in this run. Nothing in Azure changes for it, and the rest of the wave goes on.';
const NEW_MIGRATION = 'To move this machine in a later change window, plan it again in a new migration.';

test('RUN: the rule is the one the engine is held to - every case in tests/fixtures/skip-machine-state.json', async () => {
  ok(CASES.length >= 12, `${CASES.length} cases`);
  const r = await boot(atPrecheck);
  for (const c of CASES) {
    const got = vm.runInContext(`skipMachineState(${JSON.stringify(c.doc)})`, r.sandbox);
    eq(got, c.expected, c.why);
  }
});

test('RUN: a machine that ROLLED BACK after its preparation runs as it was - the dialog never says prepared', async () => {
  const { words, ux } = await dialogWords(rolledBack);
  eq(words, `${ux.skipDesc} ${ux.skipRunsAsBefore} ${ux.skipLater}`, 'the words');
  // RETRY-LATER-WORDS-1: the whole text, as an operator reads it.
  eq(words, `${DESC} This machine runs as it was before the move. ${NEW_MIGRATION}`, 'the words, in full');
  ok(/runs as it was before the move/.test(words), words);
  ok(!PREPARED.test(words), words);
  ok(LATER.test(words), words);
  ok(!VAGUE.test(words), words);
});

test('RUN: a machine whose rollback after the preparation failed is said to be changed, and leaving it out does not put it back', async () => {
  const { words, ux } = await dialogWords(rollbackFailed);
  // SKIP-CHANGED-FREED-1: a changed machine keeps its claim, and the dialog
  // says so after the sentence about the machine.
  eq(words, `${ux.skipDesc} ${ux.skipChanged} ${ux.skipClaimKept}`, 'the words');
  ok(/is not as it was before the move/.test(words), words);
  ok(/Why it stopped/.test(words), words);
  ok(!LATER.test(words), 'no promise that it can migrate later as it is: ' + words);
  // RETRY-LATER-WORDS-1: once mended, it moves in a NEW migration too.
  ok(/before you plan it again in a new migration\./.test(words), words);
  ok(!VAGUE.test(words), words);
});

test('RUN: a data disk swap that is left is a changed machine, whatever the last stop says', async () => {
  const doc = JSON.parse(JSON.stringify(rolledBack));
  doc.state = 'FAILED_NEEDS_ATTENTION';
  doc.swapPending = { kind: 'rollback', swaps: [] };
  const { words, ux } = await dialogWords(doc);
  eq(words, `${ux.skipDesc} ${ux.skipChanged} ${ux.skipClaimKept}`, 'the words (SKIP-CHANGED-FREED-1: the claim stays)');
});

test('RUN: a decision at PRECHECK, before the preparation - nothing on the machine was changed', async () => {
  const { words, ux } = await dialogWords(atPrecheck);
  eq(words, `${ux.skipDesc} ${ux.skipUntouched} ${ux.skipLater}`, 'the words');
  eq(words, `${DESC} Nothing on this machine was changed. ${NEW_MIGRATION}`, 'the words, in full');
  ok(/Nothing on this machine was changed/.test(words), words);
  ok(!PREPARED.test(words), words);
});

test('RUN: a decision in the preparation that changed nothing - never said as prepared', async () => {
  const { words, ux } = await dialogWords(prepNothingChanged);
  eq(words, `${ux.skipDesc} ${ux.skipUntouched} ${ux.skipLater}`, 'the words');
  ok(!PREPARED.test(words), words);
});

test('RUN: a decision after the preparation changed the guest - it rolled back first, so it runs as it was', async () => {
  const { words, ux } = await dialogWords(prepRolledBackDecision);
  eq(words, `${ux.skipDesc} ${ux.skipRunsAsBefore} ${ux.skipLater}`, 'the words');
});

test('RUN: a SCSI resize to v5 that rolled back is said the same way - the recorded state decides, not the move kind', async () => {
  const { words, ux } = await dialogWords(rolledBack, V5);
  eq(words, `${ux.skipDesc} ${ux.skipRunsAsBefore} ${ux.skipLater}`, 'the words');
});

test('RUN: a changed machine restored after its stop - no claim about the machine', async () => {
  const doc = JSON.parse(JSON.stringify(rollbackFailed));
  doc.restore = { restoredUtc: '2026-10-31T12:00:00Z' };
  const { words, ux } = await dialogWords(doc);
  eq(words, `${ux.skipDesc} ${ux.skipLater}`, 'the words');
  eq(words, `${DESC} ${NEW_MIGRATION}`, 'the words, in full');
});

test('the words: Azure is not changed by leaving it out, and each case says one true thing', async () => {
  const { ux } = await dialogWords(atPrecheck);
  ok(/Nothing in Azure changes for it/.test(ux.skipDesc), ux.skipDesc);
  ok(!LATER.test(ux.skipDesc), 'the promise of a later migration is said per case, not for every machine');
  ok(!('skipPrepared' in ux), 'the sentence that read history is gone');
  ok(LATER.test(ux.skipLater), 'later, where it is true: a new migration');
  ok(!LATER.test(ux.skipUntouched) && !LATER.test(ux.skipRunsAsBefore), 'said once, by skipLater, after the sentence about the machine');
  for (const k of Object.keys(ux).filter(n => n.startsWith('skip'))) {
    ok(!VAGUE.test(ux[k]), `${k} never says only "migrate it later": ${ux[k]}`);
  }
  ok(!PREPARED.test(ux.skipChanged), 'changed is not said as prepared: a stop can leave a machine changed in other ways');
});

run('skip-words-real');
