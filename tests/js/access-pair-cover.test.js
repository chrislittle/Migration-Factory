/* ACCESS-PAIR-COVER-1, 2026-10-30. Filed by ACCESS-REMOVE-SHARED-1.
 *
 * The Admin page paired an engine grant with the web service assignment AT
 * THE SAME PLACE only. Azure role assignments are inherited, so a web service
 * assignment at a subscription also reads every resource group in it. A
 * resource group grant with no web service assignment of its own was marked
 * "The engine only" while its lists of machines worked - and removing the
 * subscription grant then took that read access away without a word.
 *
 * The rule now:
 *   - an engine grant with no web service assignment at its place is paired
 *     with one at a place that CONTAINS it, by Azure's own inheritance:
 *     management group > subscription > resource group (scopeIsUnder);
 *   - a management group whose subscriptions this page could not read is
 *     CANNOT TELL, never covered and never "The engine only";
 *   - the question before Remove names every place that loses the web
 *     service read access, and the removal still removes (never kept for
 *     them: each such place has its own "Give the web service access").
 *   - the pairing a Remove deletes is unchanged: only the web service
 *     assignment AT the row's own place, never the wider one.
 *
 * Every case is RUN: the page's own loadScopes, revokeScope and
 * revokeScopeNow, with Azure and the browser stubbed. Nothing reaches Azure.
 */
'use strict';
const { extract, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('access.html', 'UX');
const SUB = '/subscriptions/sub-1';
const RG = '/subscriptions/sub-1/resourceGroups/rg-app';
const RG2 = '/subscriptions/sub-1/resourceGroups/rg-data';
const RGX = '/subscriptions/sub-1/resourceGroups/rg-app-extra';
const MG = '/providers/Microsoft.Management/managementGroups/mg-root';
const MGCHILD = '/providers/Microsoft.Management/managementGroups/mg-child';
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

/* opts.engine / opts.service: what Azure lists for that identity.
 * opts.descendants: the management group's subscriptions, or 'fail'.
 * opts.pending: this tab's records of what it just did (SCOPE-LAG-1). */
function page(opts = {}) {
  const names = ['loadScopes', 'scopeRowsOnce', 'describeScope', 'vmfRoleId', 'productReach', 'scopeNormalize',
    'scopeRowsWithLag', 'scopeLagIds', 'scopeLagRead', 'scopeLagWrite', 'scopeLagNote',
    'scopeRowsWithCoverage', 'scopeCovers', 'scopeIsUnder', 'scopeReach', 'subscriptionIdOf',
    'isManagementGroupScope', 'scopeDescendants', 'revokeScope', 'revokeScopeNow',
    'repairHalfScope', 'repairPlan', 'scopeServiceInUse', 'scopeServiceStep', 'scopeOfAssignment']
    .concat(present(['scopeRowsWithServiceCover', 'scopeReadLosses', 'scopeServiceHeld']));
  const bodies = names.map(n => extract('access.html', n)).join('\n');
  const store = new Map();
  if (opts.pending) { store.set('vmf-scope-lag', JSON.stringify(opts.pending)); }
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
    // Azure's principalId filter: at, below and above the place listed.
    const at = url.split('/providers/Microsoft.Authorization/')[0].toLowerCase();
    return { value: (answer || []).filter(a => {
      const s = a.properties.scope.toLowerCase();
      return s === at || s.startsWith(at + '/') || at.startsWith(s + '/') || s.startsWith('/providers/microsoft.management/');
    }) };
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
          return { value: [{ subscriptionId: 'sub-1', displayName: 'Contoso Sub', state: 'Enabled' }] };
        }
        if (/\/resourcegroups\?/i.test(url)) { return { value: [{ name: 'rg-app' }, { name: 'rg-data' }, { name: 'rg-app-extra' }] }; }
        if (url.includes('/descendants?')) {
          const d = opts.descendants;
          if (d === 'fail') { throw Object.assign(new Error('refused'), { status: 403 }); }
          return { value: d || [] };
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
    return { loadScopes, scopeLagRead, scopeIsUnder, scopeReadLosses };
  })`)(env);
  return { ...api, host, calls, flashes, asked, buttons: () => drawn };
}

const rowsOf = (html) => (String(html).match(/<tr><td>[\s\S]*?<\/tr>/g) || []);
const rowFor = (pg, name) => rowsOf(pg.host.innerHTML).find(r => r.startsWith(`<tr><td>${name}`));
const deleted = (pg) => pg.calls.filter(c => c.method === 'DELETE').map(c => c.url.split('?')[0]);
const removeOf = (pg, id) => pg.buttons().find(b => b.dataset.revoke === id);
const viaWords = (place) => UX.scopeServiceVia.replace('{place}', place);
const blindWords = (place) => UX.scopeServiceBlind.replace('{place}', place);

const engSub = assignment(SUB, 'eng-sub', 'assess-guid');
const engRg = assignment(RG, 'eng-rg', 'assess-guid');
const engRg2 = assignment(RG2, 'eng-rg2', 'migrate-guid');
const svcSub = assignment(SUB, 'svc-sub', 'assess-guid');
const svcRg = assignment(RG, 'svc-rg', 'assess-guid');
const svcRgX = assignment(RGX, 'svc-rgx', 'assess-guid');
const engMg = assignment(MG, 'eng-mg', 'assess-guid');
const svcMg = assignment(MG, 'svc-mg', 'assess-guid');

// --- the mark -------------------------------------------------------------

test('a resource group grant under a web service grant at its subscription is not "The engine only"', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub] });
  await pg.loadScopes();
  const row = rowFor(pg, 'rg-app');
  ok(row, 'the resource group has a row');
  ok(!row.includes(UX.scopeHalfNote), 'not marked as the engine only: the web service reads it');
  ok(!row.includes('data-fixhalf'), 'no repair is offered for access it already has');
  ok(row.includes(viaWords('Contoso Sub')), 'the row names the grant the web service reads it through');
});

test('the same when the subscription has only the web service assignment', async () => {
  const pg = page({ engine: [engRg], service: [svcSub] });
  await pg.loadScopes();
  const row = rowFor(pg, 'rg-app');
  ok(row && !row.includes(UX.scopeHalfNote), 'not the engine only');
  ok(row.includes(viaWords('Contoso Sub')), 'read through the subscription');
});

test('its own web service assignment pairs as before, and no "through" mark is drawn', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub, svcRg] });
  await pg.loadScopes();
  const row = rowFor(pg, 'rg-app');
  ok(row && !row.includes(UX.scopeHalfNote), 'paired');
  ok(!row.includes(viaWords('Contoso Sub')), 'the pair at its place is the one it uses');
  eq(removeOf(pg, engRg.id).dataset.revoke2, svcRg.id, 'and its Remove carries that pair');
});

test('a resource group whose name starts with another one\'s is not inside it', async () => {
  // rg-app-extra is not under rg-app: the separator test, never a prefix.
  const pg = page({ engine: [assignment(RGX, 'eng-rgx', 'assess-guid')], service: [svcRg] });
  await pg.loadScopes();
  ok(rowFor(pg, 'rg-app-extra').includes(UX.scopeHalfNote), 'still the engine only');
});

test('a narrower web service grant does not cover a wider engine grant', async () => {
  const pg = page({ engine: [engSub], service: [svcRg] });
  await pg.loadScopes();
  ok(rowFor(pg, 'Contoso Sub').includes(UX.scopeHalfNote), 'the subscription is still the engine only');
});

test('a web service grant at a management group covers a subscription under it, when Azure says so', async () => {
  const pg = page({ engine: [engSub], service: [svcMg], descendants: [{ id: '/subscriptions/sub-1' }] });
  await pg.loadScopes();
  const row = rowFor(pg, 'Contoso Sub');
  ok(row && !row.includes(UX.scopeHalfNote), 'not the engine only');
  ok(row.includes(viaWords('mg-root')), 'read through the management group');
});

test('and a resource group two levels under it', async () => {
  const pg = page({ engine: [engRg], service: [svcMg], descendants: [{ id: '/subscriptions/sub-1' }] });
  await pg.loadScopes();
  ok(rowFor(pg, 'rg-app').includes(viaWords('mg-root')), 'read through the management group');
});

test('a management group whose subscriptions do not include this one does not cover it', async () => {
  const pg = page({ engine: [engSub], service: [svcMg], descendants: [{ id: '/subscriptions/sub-other' }] });
  await pg.loadScopes();
  ok(rowFor(pg, 'Contoso Sub').includes(UX.scopeHalfNote), 'the engine only');
});

test('a management group whose subscriptions cannot be read is cannot tell, never covered and never the engine only', async () => {
  const pg = page({ engine: [engSub], service: [svcMg], descendants: 'fail' });
  await pg.loadScopes();
  const row = rowFor(pg, 'Contoso Sub');
  ok(row, 'the row is drawn');
  ok(!row.includes(UX.scopeHalfNote), 'not said to be the engine only: it may be covered');
  ok(!row.includes(viaWords('mg-root')), 'not said to be covered: nobody proved it');
  ok(row.includes(blindWords('mg-root')), 'it says it cannot tell, and names the management group');
  ok(!row.includes('data-fixhalf'), 'and no repair is offered on a guess');
});

test('a proven cover wins over a management group that cannot be read', async () => {
  const pg = page({ engine: [engRg], service: [svcSub, svcMg], descendants: 'fail' });
  await pg.loadScopes();
  const row = rowFor(pg, 'rg-app');
  ok(row.includes(viaWords('Contoso Sub')), 'read through the subscription');
  ok(!row.includes(blindWords('mg-root')), 'nothing is unknown about it');
});

test('a management group under another one is inside it, when Azure lists it as a descendant', async () => {
  const pg = page({});
  const kids = new Map([[MG.toLowerCase(), new Set([MGCHILD.toLowerCase(), '/subscriptions/sub-1'])]]);
  ok(pg.scopeIsUnder(MGCHILD, MG, kids), 'the child group is under the root group');
  ok(!pg.scopeIsUnder(MG, MGCHILD, kids), 'and not the other way');
  ok(!pg.scopeIsUnder(MGCHILD, MG, new Map()), 'and nothing is proven without the list');
});

test('a grant the web service reads through a wider place is not "Already covered" because of that', async () => {
  // The engine's own grants decide "already covered" (SCOPE-COVER-1). A web
  // service read at the subscription gives the engine nothing.
  const pg = page({ engine: [engRg], service: [svcSub] });
  await pg.loadScopes();
  ok(!rowFor(pg, 'rg-app').includes(UX.scopeCoveredBy.split('{place}')[0]), 'it is not covered by an engine grant');
});

test('a removal this tab made: the place shows as the engine only at once, while Azure still lists the old grant', async () => {
  const pending = [{ action: 'removed', id: engSub.id, ids: [engSub.id, svcSub.id], atMs: Date.now() }];
  const pg = page({ engine: [engSub, engRg], service: [svcSub], pending });
  await pg.loadScopes();
  const row = rowFor(pg, 'rg-app');
  ok(row && row.includes(UX.scopeHalfNote), 'the removed web service read covers nothing');
  ok(row.includes('data-fixhalf'), 'and the way forward is offered');
});

// --- the question before Remove ------------------------------------------

test('Remove on the subscription names every resource group that loses the web service read access', async () => {
  const pg = page({ engine: [engSub, engRg, engRg2], service: [svcSub], decline: true });
  await pg.loadScopes();
  await removeOf(pg, engSub.id).click();
  eq(pg.asked.length, 1, 'asked once, in the row');
  ok(String(pg.asked[0].desc).includes(UX.scopeRemoveLosesRead), 'the question says that read access goes');
  eq(pg.asked[0].lines, ['rg-app (Contoso Sub)', 'rg-data (Contoso Sub)'], 'and names each place');
  eq(pg.asked[0].cancel, UX.cancel, 'with a way back');
  eq(deleted(pg), [], 'nothing is deleted before Yes');
});

test('Yes removes both halves at the subscription and nothing at the resource groups', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub] });
  await pg.loadScopes();
  await removeOf(pg, engSub.id).click();
  eq(deleted(pg), [engSub.id, svcSub.id], 'a removal removes');
});

test('a place with its own web service assignment is not named', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub, svcRg], decline: true });
  await pg.loadScopes();
  await removeOf(pg, engSub.id).click();
  ok(!String(pg.asked[0].desc).includes(UX.scopeRemoveLosesRead), 'nothing loses its read access');
  ok(!(pg.asked[0].lines || []).length, 'no place is named');
  eq(pg.asked[0].desc, UX.scopeRemoveDesc, 'the words are as before');
});

test('a place a management group also covers is not named', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub, svcMg],
    descendants: [{ id: '/subscriptions/sub-1' }], decline: true });
  await pg.loadScopes();
  await removeOf(pg, engSub.id).click();
  ok(!(pg.asked[0].lines || []).length, 'the management group still gives the read access');
});

test('a place only a management group that cannot be read may still cover is named, with that said', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub, svcMg], descendants: 'fail', decline: true });
  await pg.loadScopes();
  await removeOf(pg, engSub.id).click();
  eq(pg.asked[0].lines, [UX.scopeLosesMaybe.replace('{place}', 'rg-app (Contoso Sub)')], 'named, with the doubt said');
});

test('a shared subscription grant keeps the web service read access, so nothing is named', async () => {
  // Two engine grants on the subscription share its web service assignment
  // (ACCESS-REMOVE-SHARED-1): removing one keeps it.
  const engSubMig = assignment(SUB, 'eng-sub-mig', 'migrate-guid');
  const pg = page({ engine: [engSub, engSubMig, engRg], service: [svcSub], decline: true });
  await pg.loadScopes();
  await removeOf(pg, engSub.id).click();
  eq(pg.asked[0].desc, UX.scopeRemoveDescShared, 'the shared words, as before');
  ok(!(pg.asked[0].lines || []).length, 'no place loses anything');
});

test('Remove on a web service only row names the places that lose the read access', async () => {
  const pg = page({ engine: [engRg], service: [svcSub], decline: true });
  await pg.loadScopes();
  const b = pg.buttons().find(x => x.dataset.serviceonly === '1');
  ok(b && b.dataset.revoke === svcSub.id, 'the subscription is a web service only row');
  await b.click();
  ok(String(pg.asked[0].desc).startsWith(UX.scopeServiceRemoveDesc), 'the web service words first');
  ok(String(pg.asked[0].desc).includes(UX.scopeRemoveLosesRead), 'then what goes below it');
  eq(pg.asked[0].lines, ['rg-app (Contoso Sub)'], 'the resource group is named');
});

test('Remove on the covered resource group deletes its engine grant only, never the wider read access', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub] });
  await pg.loadScopes();
  const b = removeOf(pg, engRg.id);
  ok(!('revoke2' in b.dataset), 'the wider web service assignment is not this row\'s pair');
  await b.click();
  eq(deleted(pg), [engRg.id], 'only the engine grant');
  eq(pg.asked[0].desc, UX.scopeRemoveDesc, 'and the question names nothing that loses read access');
});

test('Remove on a management group names the subscription under it', async () => {
  const pg = page({ engine: [engMg, engSub], service: [svcMg], descendants: [{ id: '/subscriptions/sub-1' }], decline: true });
  await pg.loadScopes();
  await removeOf(pg, engMg.id).click();
  ok((pg.asked[0].lines || []).includes('Contoso Sub'), 'the subscription is named');
});

test('a place read through two wider grants names the outermost one', async () => {
  const pg = page({ engine: [engSub, engRg], service: [svcSub, svcMg], descendants: [{ id: '/subscriptions/sub-1' }] });
  await pg.loadScopes();
  ok(rowFor(pg, 'rg-app').includes(viaWords('mg-root')), 'the management group, not whichever Azure listed first');
});

test('a resource group that no longer exists is not named', async () => {
  const engGone = assignment('/subscriptions/sub-1/resourceGroups/rg-gone', 'eng-gone', 'assess-guid');
  const pg = page({ engine: [engSub, engGone, engRg], service: [svcSub], decline: true });
  await pg.loadScopes();
  ok(rowFor(pg, 'rg-gone').includes(UX.scopeGone), 'it is marked as gone');
  await removeOf(pg, engSub.id).click();
  eq(pg.asked[0].lines, ['rg-app (Contoso Sub)'], 'a deleted place has no machines to lose');
});

test('a place listed twice is named once', () => {
  // ACCESS-MG-ROW-TWICE-1: a management group grant comes back once for each
  // subscription under it.
  const pg = page({});
  const removing = { id: 'e-root', serviceId: 's-root', reach: 'full', scope: MG, name: 'mg-root' };
  const copy = { id: 'e-child', serviceId: null, reach: 'full', scope: MGCHILD, name: 'mg-child', serviceVia: ['s-root'] };
  eq(pg.scopeReadLosses(removing, [removing, copy, { ...copy }], false), ['mg-child'], 'one line');
});

run('an engine grant inside a wider web service grant');
