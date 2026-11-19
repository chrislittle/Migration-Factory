/* ACCESS-MG-ROW-TWICE-1, 2026-11-03. Filed by ACCESS-SERVICE-ORPHAN-1.
 *
 * loadScopes on the Admin page lists the role assignments of the engine and
 * of the web service once for each subscription, with
 * `$filter=principalId eq '<id>'`. Microsoft's "Role Assignments - List For
 * Scope" page (api-version 2022-04-01) says that filter returns "all role
 * assignments at, above or below the scope for the specified principal". So
 * an assignment at a management group comes back in EVERY subscription under
 * it, and the page drew one row each time: one grant shown as several.
 *
 * The rule now: one row for each role assignment, by its id, at the place it
 * is really at. Remove on that row deletes that one assignment once.
 *
 * Every case is RUN: the page's own loadScopes, revokeScope and
 * revokeScopeNow, with Azure and the browser stubbed. The stub answers a
 * subscription's list the way the page above says Azure does: what is at or
 * below the subscription, and every management group assignment. Nothing
 * reaches Azure.
 */
'use strict';
const { extract, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('access.html', 'UX');
const SUB = '/subscriptions/sub-1';
const SUB2 = '/subscriptions/sub-2';
const RG = '/subscriptions/sub-1/resourceGroups/rg-app';
const MG = '/providers/Microsoft.Management/managementGroups/mg-root';
const AUTH = '/providers/Microsoft.Authorization/roleAssignments/';

function present(names) {
  return names.filter(n => { try { extract('access.html', n); return true; } catch { return false; } });
}

const assignment = (scope, guid, role) => ({
  id: `${scope}${AUTH}${guid}`,
  properties: { scope, roleDefinitionId: `/providers/Microsoft.Authorization/roleDefinitions/${role}` },
});

function buttonsIn(html) {
  const found = [];
  for (const m of String(html).matchAll(/<button\b([^>]*)>([^<]*)</g)) {
    const dataset = {};
    for (const a of m[1].matchAll(/data-([a-z0-9-]+)="([^"]*)"/g)) {
      dataset[a[1].replace(/-([a-z])/g, (_, c) => c.toUpperCase())] =
        a[2].replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
    }
    const handlers = [];
    found.push({ dataset, label: m[2], disabled: false, textContent: m[2],
      addEventListener: (ev, fn) => { if (ev === 'click') { handlers.push(fn); } },
      click: async () => {
        await Promise.all(handlers.map(fn => fn()));
        for (let i = 0; i < 50; i++) { await new Promise(r => setImmediate(r)); }
      } });
  }
  return found;
}

/* opts.engine / opts.service: what the identity holds, or 'fail'.
 * opts.serviceFailsIn / opts.engineMissesIn: a subscription whose list of
 * that identity cannot be read, or does not carry a management group
 * assignment yet (Azure's list is eventually consistent, SCOPE-LAG-1).
 * opts.serviceMissesIn: the subscriptions whose web service list does not
 * carry it yet. */
function page(opts = {}) {
  const names = ['loadScopes', 'describeScope', 'vmfRoleId', 'productReach', 'scopeNormalize',
    'scopeRowsWithLag', 'scopeLagIds', 'scopeLagRead', 'scopeLagWrite', 'scopeLagNote',
    'scopeRowsWithCoverage', 'scopeCovers', 'scopeIsUnder', 'scopeReach', 'subscriptionIdOf',
    'isManagementGroupScope', 'scopeDescendants', 'revokeScope', 'revokeScopeNow',
    'repairHalfScope', 'repairPlan', 'scopeServiceInUse', 'scopeServiceStep', 'scopeOfAssignment',
    'scopeRowsWithServiceCover', 'scopeReadLosses', 'scopeServiceHeld']
    .concat(present(['scopeRowsOnce']));
  const bodies = names.map(n => extract('access.html', n)).join('\n');
  const store = new Map();
  const calls = [];
  const flashes = [];
  const asked = [];
  let drawn = [];
  const host = {
    textContent: '',
    _html: '',
    get innerHTML() { return this._html; },
    set innerHTML(v) { this._html = String(v); drawn = buttonsIn(this._html); },
    querySelectorAll: (sel) => {
      const want = (sel.match(/data-([a-z0-9-]+)/) || [])[1];
      const key = want ? want.replace(/-([a-z])/g, (_, c) => c.toUpperCase()) : null;
      return drawn.filter(b => key && key in b.dataset);
    },
  };
  const els = { '#scope-list': host };
  const el = (s) => (els[s] = els[s] || { style: {}, value: s === '#scope-pick' ? 'sub-1' : '', innerHTML: '', textContent: '' });
  const listFor = (who, url) => {
    const answer = opts[who];
    if (answer === 'fail') { throw Object.assign(new Error('refused'), { status: 403 }); }
    if (who === 'service' && opts.serviceFailsIn && url.startsWith(opts.serviceFailsIn + '/')) {
      throw Object.assign(new Error('refused'), { status: 403 });
    }
    const sub = (url.match(/^\/subscriptions\/[^/]+/) || [])[0];
    const atSub = /^\/subscriptions\/[^/]+\/providers\//.test(url);
    const isMg = (a) => a.properties.scope.startsWith('/providers/Microsoft.Management/');
    const missing = (who === 'engine' && opts.engineMissesIn && url.startsWith(opts.engineMissesIn + '/')) ||
      (who === 'service' && (opts.serviceMissesIn || []).some(s => url.startsWith(s + '/')));
    return { value: (answer || []).filter(a => !atSub ||
      a.properties.scope.toLowerCase().startsWith(sub.toLowerCase()) || (isMg(a) && !missing)) };
  };
  const env = {
    UX,
    cfg: { enginePrincipalId: 'eng-1', webServicePrincipalId: 'svc-1',
      assessRoleId: '/roles/assess-guid', migrateRoleId: '/roles/migrate-guid' },
    $: el,
    esc: (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
    VmfHelp: {
      mapLimited: (items, fn) => Promise.all(items.map(fn)),
      explain: (e) => String(e && e.message),
      confirmInPlace: (b, o, yes) => { asked.push(o); return opts.decline ? undefined : yes(); },
    },
    sessionStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) },
    arm: async (method, url) => {
      calls.push({ method, url });
      if (method === 'GET') {
        if (url.startsWith('/subscriptions?')) {
          return { value: [{ subscriptionId: 'sub-1', displayName: 'Contoso Sub', state: 'Enabled' },
            { subscriptionId: 'sub-2', displayName: 'Fabrikam Sub', state: 'Enabled' },
            { subscriptionId: 'sub-3', displayName: 'Tailspin Sub', state: 'Enabled' }] };
        }
        if (/\/resourcegroups\?/i.test(url)) { return { value: [{ name: 'rg-app' }] }; }
        if (url.includes('/descendants?')) {
          return { value: opts.descendants || [{ id: SUB }, { id: SUB2 }, { id: '/subscriptions/sub-3' }] };
        }
        if (url.includes("'svc-1'")) { return listFor('service', url); }
        if (url.includes("'eng-1'")) { return listFor('engine', url); }
        return { value: [] };
      }
      return {};
    },
    flash: (where, msg) => flashes.push({ where, msg }),
    fail: (e) => { throw e; },
    loadResourceGroups: async () => { },
    crypto: { randomUUID: () => 'new-guid' },
  };
  const api = eval(`(function (env) {
    const { UX, cfg, $, esc, VmfHelp, sessionStorage, arm, flash, fail, loadResourceGroups, crypto } = env;
    let subs = [];
    const SCOPE_LAG_KEY = 'vmf-scope-lag';
    const SCOPE_LAG_MS = 600000;
    ${bodies}
    return { loadScopes, scopeLagRead };
  })`)(env);
  return { ...api, host, calls, flashes, asked, buttons: () => drawn };
}

const rowsOf = (html) => (String(html).match(/<tr><td>[\s\S]*?<\/tr>/g) || []);
const rowsAt = (pg, name) => rowsOf(pg.host.innerHTML).filter(r => r.startsWith(`<tr><td>${name}`));
const deleted = (pg) => pg.calls.filter(c => c.method === 'DELETE').map(c => c.url.split('?')[0]);
const removesOf = (pg, id) => pg.buttons().filter(b => b.dataset.revoke === id);

const engMg = assignment(MG, 'eng-mg', 'assess-guid');
const svcMg = assignment(MG, 'svc-mg', 'assess-guid');
const engSub = assignment(SUB, 'eng-sub', 'assess-guid');
const svcSub = assignment(SUB, 'svc-sub', 'assess-guid');
const engRg = assignment(RG, 'eng-rg', 'migrate-guid');
const svcRg = assignment(RG, 'svc-rg', 'assess-guid');

test('a management group grant listed in three subscriptions draws one row', async () => {
  const pg = page({ engine: [engMg], service: [svcMg] });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one grant, one row');
  ok(rows[0].startsWith('<tr><td>mg-root'), 'named as the management group');
  ok(rows[0].includes(UX.scopeLevelNameMg), 'at the management group level, the place it is really at');
  eq(removesOf(pg, engMg.id).length, 1, 'one Remove for it');
});

test('its Remove deletes the engine and the web service assignment once each', async () => {
  const pg = page({ engine: [engMg], service: [svcMg] });
  await pg.loadScopes();
  const b = removesOf(pg, engMg.id)[0];
  eq(b.dataset.revoke2, svcMg.id, 'paired with the web service assignment at the management group');
  ok(!('shared' in b.dataset), 'its own copy in another subscription is not another grant that uses it');
  await b.click();
  eq(deleted(pg), [engMg.id, svcMg.id], 'each assignment once, by its own id');
  eq(pg.asked[0].desc, UX.scopeRemoveDesc, 'and the question does not say the read access is kept');
});

test('the other rows are as before, beside the management group row', async () => {
  const pg = page({ engine: [engMg, engSub, engRg], service: [svcMg, svcSub, svcRg] });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 3, 'the management group, the subscription and the resource group');
  eq(rowsAt(pg, 'mg-root').length, 1, 'the management group once');
  eq(rowsAt(pg, 'Contoso Sub').length, 1, 'the subscription once');
  eq(rowsAt(pg, 'rg-app').length, 1, 'the resource group once');
});

test('a web service only assignment at a management group draws one row', async () => {
  const pg = page({ engine: [], service: [svcMg] });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one row');
  ok(rows[0].includes(UX.scopeServiceOnlyNote), 'marked as the web service only');
  const b = removesOf(pg, svcMg.id);
  eq(b.length, 1, 'one Remove');
  await b[0].click();
  eq(deleted(pg), [svcMg.id], 'it deletes that one assignment once');
});

test('a subscription whose web service list cannot be read does not decide the row', async () => {
  // The copy from that subscription says cannot tell; the copy from another
  // subscription read the web service assignment. Both are the one grant.
  const pg = page({ engine: [engMg], service: [svcMg], serviceFailsIn: SUB });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one row');
  eq(removesOf(pg, engMg.id)[0].dataset.revoke2, svcMg.id, 'the copy that read its pair is the one kept');
});

test('a subscription whose engine list does not carry the grant yet does not make it a web service only row', async () => {
  // In that subscription the web service assignment has no engine grant at its
  // place. In the others it does. It is one assignment, and it is paired.
  const pg = page({ engine: [engMg], service: [svcMg], engineMissesIn: SUB2 });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one row, for the engine grant');
  ok(!pg.host.innerHTML.includes(UX.scopeServiceOnlyNote), 'no web service only row for an assignment that is paired');
  eq(removesOf(pg, svcMg.id).length, 0, 'and no second Remove for it');
});

test('a subscription whose web service list does not carry the pair yet does not decide the row', async () => {
  // The first copy says the engine only; another subscription read the pair.
  const pg = page({ engine: [engMg], service: [svcMg], serviceMissesIn: [SUB] });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one row');
  ok(!rows[0].includes(UX.scopeHalfNote), 'not marked as the engine only');
  eq(removesOf(pg, engMg.id)[0].dataset.revoke2, svcMg.id, 'the copy that read its pair is the one kept');
});

test('a list that says no beats a list that could not be read', async () => {
  // One subscription cannot read the web service list; the other two read it
  // and found no pair. The answer that was read is the one shown.
  const pg = page({ engine: [engMg], service: [svcMg], serviceFailsIn: SUB, serviceMissesIn: [SUB2, '/subscriptions/sub-3'] });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one row');
  ok(rows[0].includes(UX.scopeHalfNote), 'marked as the engine only, the answer two lists gave');
  eq(pg.buttons().filter(b => 'fixhalf' in b.dataset).length, 1, 'with the one repair');
});

test('two assignments at one management group are still two rows', async () => {
  // One row for each ASSIGNMENT, not for each place.
  const engMgMig = assignment(MG, 'eng-mg-mig', 'migrate-guid');
  const pg = page({ engine: [engMg, engMgMig], service: [svcMg] });
  await pg.loadScopes();
  eq(rowsAt(pg, 'mg-root').length, 2, 'Assess, and Assess and migrate');
  eq(removesOf(pg, engMg.id).length, 1, 'each once');
  eq(removesOf(pg, engMgMig.id).length, 1, 'each once');
});

test('an id in another case is the same assignment', async () => {
  const shouted = { ...engMg, id: engMg.id.replace('managementGroups', 'MANAGEMENTGROUPS') };
  const pg = page({ engine: [engMg, shouted], service: [svcMg] });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 1, 'one row, whatever the case of the id');
});

run('a management group grant shows one row');
