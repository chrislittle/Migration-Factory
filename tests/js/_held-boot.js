/* LOADING-LINE-1, TILE-COUNT-READING-1: boot a page OUTSIDE demo mode against
 * a stand-in service that holds every read until the test releases it - so a
 * test can see what the page shows while it reads, after the reads answer
 * (an empty store), and after the store refuses them (500 on every store
 * read). tests/js/_dom.js is the browser; its `parts` option lets the page
 * draw the shared list (VmfHelp.listMount). */
'use strict';
const { msalStandIn } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const API = 'https://api.example.com/api';
const CONFIG = { clientId: 'client-1', tenantId: 'tenant-1', apiAppId: 'api-app', apiUrl: API };

function answer(status, body) {
  const text = JSON.stringify(body ?? {});
  return { ok: status >= 200 && status < 300, status, json: () => Promise.resolve(JSON.parse(text)),
           text: () => Promise.resolve(text), headers: { get: () => null } };
}

/* The answer to each read once it is released: an empty store, and a
 * directory with the product's application and nobody in it. */
function emptyAnswer(url) {
  if (url.includes('graph.microsoft.com')) {
    if (/appRoleAssignedTo/.test(url)) { return answer(200, { value: [] }); }
    if (/servicePrincipals\(/.test(url)) { return answer(200, { id: 'sp-1', appRoles: [] }); }
    return answer(200, { value: [] });
  }
  const route = url.slice(API.length + 1);
  if (route.startsWith('store/docs')) { return answer(200, { names: [], folders: [], docs: [], truncated: false, complete: true }); }
  if (route.startsWith('store/list')) { return answer(200, { names: [], prefixes: [] }); }
  if (route.startsWith('scopes')) { return answer(200, { subscriptions: [], managementGroups: [] }); }
  if (route.startsWith('records')) { return answer(200, { records: [] }); }
  return answer(404, { error: 'not found' });
}

/** A service that holds every read until release(); after that it answers at once. */
function heldService(refuse) {
  const held = [];
  let open = false;
  // REVIEW (fix round): a refused read answers every store read with 500.
  const reply = (url) => (refuse && url.includes('/store/') ? answer(500, { error: 'refused' }) : emptyAnswer(url));
  const handle = (url) => {
    if (url === 'dashboard.config.json') { return answer(200, CONFIG); }
    const ours = url.startsWith(API + '/') || url.includes('graph.microsoft.com') || url.includes('management.azure.com');
    if (!ours) { return undefined; }   // the boot harness refuses it
    if (open) { return reply(url); }
    return new Promise((done) => held.push(() => done(reply(url))));
  };
  return { handle, held, release() { open = true; held.splice(0).forEach(go => go()); } };
}

async function turns(r, n) {
  for (let i = 0; i < n; i++) { await new Promise(done => setTimeout(done, 10)); await settle(r); }
}

async function bootHeld(p, refuse) {
  const svc = heldService(refuse);
  const msal = msalStandIn({ claims: { roles: ['Vmf.Admin'] } });
  const r = bootPage(p.page, { search: p.search || '?signed-in', fetch: svc.handle, globals: { msal },
                               storage: { 'vmf-disclaimer-seen': '1' }, parts: true });
  await turns(r, 10);
  return { r, svc };
}

module.exports = { bootHeld, turns, heldService, API };
