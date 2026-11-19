/* SKIP-ONE-RUNBODY-1: "Leave this machine out" posts on a REAL install.
 *
 * askSkipVm sent `runBody({ vmId, note })` - a helper of waves.html, which
 * migrations.html never declared. So the confirm threw a ReferenceError on
 * every install since SKIP-ONE-1 (2026-09-23), runs/<run>/vms/skip was never
 * called, and the machine stayed stopped at its decision. Found by the
 * WAVES-API-1 gate (tests/js/_page-calls.js), the first time it read the page.
 *
 * This boots migrations.html OUTSIDE demo mode with a stand-in service whose
 * store holds one machine parked at its decision, opens its panel as a row
 * click does, presses "Leave this machine out", types the note and confirms.
 * The service's skip endpoint takes { vmId, note } (src/facade/app/PostSkipVm),
 * and apiFetch adds the project itself (PROJECT-4).
 */
'use strict';
const vm = require('vm');
const { test, eq, ok, run, msalStandIn } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const API = 'https://api.example.com/api';
const CONFIG = { clientId: 'client-1', tenantId: 'tenant-1', apiAppId: 'api-app', apiUrl: API };
const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/app-1';
const BLOBS = {
  'mig-1/plan.json': { schemaVersion: 1, entries: [{ vmId: VM, wave: 'wave-1', path: 'A',
    source: { size: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' } }] },
  'mig-1/state/app-1.json': { vmId: VM, state: 'NEEDS_DECISION', history: [
    { state: 'PRECHECK', tsUtc: '2026-10-31T10:00:00Z' },
    { state: 'NEEDS_DECISION', tsUtc: '2026-10-31T10:05:00Z' }] },
};

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

/** A stand-in service over a small store. Every request is recorded. */
function service() {
  const calls = [];
  const handle = (url, init) => {
    const method = (init && init.method) || 'GET';
    if (url === 'dashboard.config.json') { return answer(200, CONFIG); }
    if (!url.startsWith(API + '/')) { return undefined; }   // the boot harness refuses it
    const route = url.slice(API.length + 1);
    calls.push({ method, route, body: init && init.body ? JSON.parse(init.body) : null });
    const q = new URL(url).searchParams;
    if (route.startsWith('store/list')) {
      const prefix = q.get('prefix') || '';
      const under = Object.keys(BLOBS).filter(n => n.startsWith(prefix));
      if (!q.get('delimiter')) { return answer(200, { names: under }); }
      const rest = under.map(n => n.slice(prefix.length));
      return answer(200, {
        names: under.filter(n => !n.slice(prefix.length).includes('/')),
        prefixes: [...new Set(rest.filter(n => n.includes('/')).map(n => prefix + n.split('/')[0]))],
      });
    }
    if (route.startsWith('store/blob')) {
      const at = q.get('path');
      return at in BLOBS ? answer(200, BLOBS[at], { 'x-vmf-document-version': 'v-1' }) : answer(404, { error: 'not found' });
    }
    if (route === 'runs/mig-1/vms/skip' && method === 'POST') { return answer(200, { skipped: true }); }
    return answer(404, { error: `no route ${route}` });
  };
  return { calls, handle };
}

async function turns(r, n) {
  for (let i = 0; i < n; i++) { await new Promise(done => setTimeout(done, 10)); await settle(r); }
}

/** Boot the page, open the parked machine as a row click does, and press the button. */
async function leaveOut(note) {
  const svc = service();
  const msal = msalStandIn({ claims: { roles: ['Vmf.Operator'] } });
  // An operator who saw the notice before (DISCLAIMER-1; see waves-real-boot.test.js).
  const r = bootPage('migrations.html', { search: '?run=mig-1', fetch: svc.handle, globals: { msal },
    storage: { 'vmf-disclaimer-seen': '1' } });
  await turns(r, 15);
  const vmIds = vm.runInContext('allVms.map(v => v.vmId + " " + v.state)', r.sandbox);
  vm.runInContext(`openDrill(allVms.find(v => v.vmId === ${JSON.stringify(VM)}),
    planDoc.entries.find(e => e.vmId === ${JSON.stringify(VM)}), ${JSON.stringify(VM)})`, r.sandbox);
  await turns(r, 3);
  const panel = r.painted.filter(p => p.html.includes('id="skip-btn"')).map(p => p.html).join('');
  const doc = r.sandbox.document;
  doc.querySelector('#skip-btn').click();
  await turns(r, 2);
  doc.querySelector('#mf-note').value = note;
  const before = svc.calls.length;
  await r.byId.get('m-confirm').onclick();
  await turns(r, 2);
  return { r, svc, vmIds, panel, posts: svc.calls.slice(before).filter(c => c.method === 'POST') };
}

test('RUN, not in demo mode: the store holds one machine parked at its decision, and its panel offers Leave this machine out', async () => {
  const { r, vmIds, panel } = await leaveOut('Out of scope for this run.');
  eq(r.errors, [], 'nothing thrown while the scripts ran');
  eq(vmIds, [`${VM} NEEDS_DECISION`], 'the machines the page read');
  ok(panel.length > 0, 'the panel draws the Leave this machine out button');
});

test('RUN, not in demo mode: Leave it out posts the machine and the note to vms/skip, with no error', async () => {
  const { r, posts } = await leaveOut('Out of scope for this run.');
  eq(r.byId.get('m-err').style.display === 'block' ? r.byId.get('m-err').textContent : '', '', 'the dialog error');
  eq(posts.length, 1, 'one post');
  eq(posts[0].route, 'runs/mig-1/vms/skip', 'the skip route');
  eq(posts[0].body.vmId, VM, 'the machine');
  eq(posts[0].body.note, 'Out of scope for this run.', 'the note');
  const err = r.byId.get('err');
  eq(err.style.display === 'block' ? err.textContent : '', '', 'the error banner');
  eq(r.byId.get('ok').style.display, 'block', 'the page says it is done');
});

run('skip-one-real');
