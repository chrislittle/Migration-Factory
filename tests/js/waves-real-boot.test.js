/* WAVES-API-1: the wave editor starts on a REAL install, not only in demo mode.
 *
 * Found on the lab install, 2026-10-31: the wave editor showed the error
 * "api is not defined" and nothing else, for every migration. The page start
 * called `api('GET', 'scopes')` - a helper three OTHER pages define - and the
 * quota preview and request called `api('POST', ...)` too. This page has
 * apiGet and apiPost.
 *
 * WHY NOTHING SAW IT. pages-boot.test.js boots every page in DEMO mode, and
 * the call sat inside `if (!DEMO_MODE)`. quota-preview.test.js gave the lifted
 * functions its OWN `api`, so it proved the test's helper, not the page's.
 *
 * So this boots waves.html OUTSIDE demo mode: the page's whole script, with
 * a stand-in for MSAL and a stand-in service, and the store holding the demo
 * plan. It asks what the operator sees: the editor, and no error banner.
 */
'use strict';
const vm = require('vm');
const { test, eq, ok, run, msalStandIn } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const API = 'https://api.example.com/api';
const CONFIG = { clientId: 'client-1', tenantId: 'tenant-1', apiAppId: 'api-app', apiUrl: API };
const SUB = '00000000-0000-0000-0000-000000000000';

/** The plan the demo shows, as the store would hold it. */
function demoPlanText() {
  const demo = bootPage('waves.html');
  return vm.runInContext('JSON.stringify(DEMO_PLAN)', demo.sandbox);
}

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

/** A stand-in service. Every request is recorded; what it does not know is a 404. */
function service(planText) {
  const calls = [];
  const handle = (url, init) => {
    const method = (init && init.method) || 'GET';
    if (url === 'dashboard.config.json') { return answer(200, CONFIG); }
    if (!url.startsWith(API + '/')) { return undefined; }   // the boot harness refuses it
    const route = url.slice(API.length + 1);
    calls.push({ method, route, body: init && init.body ? JSON.parse(init.body) : null });
    if (route.startsWith('store/list')) { return answer(200, { names: [] }); }
    if (route.startsWith('store/blob')) {
      const at = decodeURIComponent(new URL(url).searchParams.get('path') || '');
      if (at === 'mig-1/plan.json') { return answer(200, planText, { 'x-vmf-document-version': 'v-1' }); }
      return answer(404, { error: 'not found' });
    }
    if (route === 'scopes' && method === 'GET') { return answer(200, { subscriptions: [{ id: SUB, name: 'Applications' }] }); }
    if (route === 'runs/mig-1/engine/quota' && method === 'POST') { return answer(202, { accepted: true }); }
    return answer(404, { error: `no route ${route}` });
  };
  return { calls, handle };
}

/** Boot the editor outside demo mode, and wait for MSAL's initialize and the reads. */
async function bootReal() {
  const svc = service(demoPlanText());
  const msal = msalStandIn({ claims: { roles: ['Vmf.Operator'] } });
  /* An operator who saw the notice before (DISCLAIMER-1). Its first-visit
   * dialog wires buttons inside markup it just drew, which the boot DOM does
   * not parse (tests/js/_dom.js says why); DISCLAIMER-1's own tests run it. */
  const storage = { 'vmf-disclaimer-seen': '1' };
  const r = bootPage('waves.html', { search: '?run=mig-1', fetch: svc.handle, globals: { msal }, storage });
  for (let i = 0; i < 10; i++) {
    await new Promise(done => setTimeout(done, 10));   // MSAL's initialize ends on a later turn
    await settle(r);
  }
  return { r, svc };
}

const banner = (r) => {
  const err = r.byId.get('err');
  return err && err.style.display === 'block' ? String(err.textContent) : '';
};

test('RUN, not in demo mode: the wave editor starts and shows no error banner', async () => {
  const { r } = await bootReal();
  eq(r.errors, [], 'nothing thrown while the scripts ran');
  eq(banner(r), '', 'the error banner');
  eq(r.byId.get('app').style.display, 'block', 'the editor is shown');
});

test('RUN, not in demo mode: the start reads the plan, and the subscription names from scopes', async () => {
  const { r, svc } = await bootReal();
  ok(svc.calls.some(c => c.method === 'GET' && /^store\/blob\?path=mig-1%2Fplan\.json$/.test(c.route)), 'the plan is read from the store');
  ok(svc.calls.some(c => c.method === 'GET' && c.route === 'scopes'), 'the subscription names are read from scopes');
  // The answer arrives: the quota card names the subscription, not only its id.
  eq(vm.runInContext(`subName('${SUB}')`, r.sandbox), 'Applications', 'the subscription name');
});

test('RUN, not in demo mode: the quota preview posts a what-if to engine/quota', async () => {
  const { r, svc } = await bootReal();
  const before = svc.calls.length;
  r.sandbox.openQuotaConfirm();
  for (let i = 0; i < 5; i++) { await settle(r); }
  const posts = svc.calls.slice(before).filter(c => c.method === 'POST' && c.route === 'runs/mig-1/engine/quota');
  eq(posts.length, 1, 'one post to engine/quota');
  eq(posts[0].body.whatIfOnly, true, 'it asks for the preview only - nothing is filed');
  const shown = vm.runInContext('quotaConfirm && quotaConfirm.phase', r.sandbox);
  eq(shown, 'wait', 'the confirmation waits for the engine, it is not an error');
});

/* QUOTA-FILED-WORDS-1: Request no longer closes the confirmation and says
 * "filed" when the service accepts the post. It waits for the engine's
 * quotaResult line. Nothing polls in a boot (the boot DOM's setTimeout never
 * fires), so this is not awaited: it asks what the page shows while it waits.
 * quota-filed-words.test.js runs the answer. */
test('RUN, not in demo mode: Request posts the request to engine/quota and waits for the engine, saying nothing is filed yet', async () => {
  const { r, svc } = await bootReal();
  vm.runInContext("quotaConfirm = { phase: 'ready', rows: [] }; drawQuotaConfirm();", r.sandbox);
  const before = svc.calls.length;
  r.sandbox.sendQuotaRequest();
  for (let i = 0; i < 5; i++) { await settle(r); }
  const posts = svc.calls.slice(before).filter(c => c.method === 'POST' && c.route === 'runs/mig-1/engine/quota');
  eq(posts.length, 1, 'one post to engine/quota');
  eq(posts[0].body.whatIfOnly, false, 'the request is sent');
  eq(vm.runInContext('quotaConfirm && quotaConfirm.phase', r.sandbox), 'sending', 'the confirmation stays open and waits for the engine');
  eq(banner(r), '', 'the error banner');
  ok(r.byId.get('ok').style.display !== 'block', 'no "filed" before Azure is asked');
});

run('waves-real-boot');
