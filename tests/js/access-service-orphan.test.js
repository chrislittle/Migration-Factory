/* ACCESS-SERVICE-ORPHAN-1, 2026-10-25. Filed by ACCESS-REMOVE-SHARED-1.
 *
 * The Admin page drew one row for each ENGINE grant. The web service's VMF
 * Assessment assignments were read only to pair them with an engine row at
 * the same place. So a web service assignment with no engine grant at its
 * place had no row: the product could still read those machines, and nobody
 * could see that access or remove it from the app.
 *
 * It happens three ways: a removal that could not read the other grants keeps
 * the web service assignment (ACCESS-REMOVE-SHARED-1); an engine grant is
 * removed outside the app; and two tabs remove the two engine grants of one
 * place at the same time, each keeping its record in its own storage.
 *
 * The rule now: each such assignment draws its own row, marked as the web
 * service only, with a Remove that deletes that one assignment as the
 * signed-in user. The pairing stays AT THE SAME PLACE (scopeNormalize).
 *
 * Every case is RUN: the page's own loadScopes, revokeScope and
 * revokeScopeNow, with Azure and the browser stubbed. Nothing reaches Azure.
 */
'use strict';
const { extract, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('access.html', 'UX');
const SUB = '/subscriptions/sub-1';
const SUB2 = '/subscriptions/sub-2';
const RG = '/subscriptions/sub-1/resourceGroups/rg-orphan';
const MG = '/providers/Microsoft.Management/managementGroups/mg-root';
const AUTH = '/providers/Microsoft.Authorization/roleAssignments/';

function present(names) {
  return names.filter(n => { try { extract('access.html', n); return true; } catch { return false; } });
}

const assignment = (scope, guid, role) => ({
  id: `${scope}${AUTH}${guid}`,
  properties: { scope, roleDefinitionId: `/providers/Microsoft.Authorization/roleDefinitions/${role}` },
});

/* Buttons the page drew, read back from its markup so a click runs the
 * page's own handler. Only the button tags: nothing else is parsed. */
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
      // The page's handler does not return the removal's promise, so the
      // click waits for the work it started to settle.
      click: async () => {
        await Promise.all(handlers.map(fn => fn()));
        for (let i = 0; i < 50; i++) { await new Promise(r => setImmediate(r)); }
      } });
  }
  return found;
}

/* opts.engine / opts.service: what Azure lists for that identity, or 'fail'.
 * opts.pending: this tab's records of what it just did (SCOPE-LAG-1). */
function page(opts = {}) {
  const names = ['loadScopes', 'scopeRowsOnce', 'describeScope', 'vmfRoleId', 'productReach', 'scopeNormalize',
    'scopeRowsWithLag', 'scopeLagIds', 'scopeLagRead', 'scopeLagWrite', 'scopeLagNote',
    'scopeRowsWithCoverage', 'scopeCovers', 'scopeIsUnder', 'scopeReach', 'subscriptionIdOf',
    'isManagementGroupScope', 'scopeDescendants', 'revokeScope', 'revokeScopeNow',
    'repairHalfScope', 'repairPlan']
    .concat(present(['scopeServiceInUse', 'scopeServiceStep', 'scopeOfAssignment',
      'scopeRowsWithServiceCover', 'scopeReadLosses', 'scopeServiceHeld']));
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
    if (answer === 'fail') { throw Object.assign(new Error('refused'), { status: 403 }); }
    if (who === 'service' && opts.serviceFailsIn && url.startsWith(opts.serviceFailsIn + '/')) {
      throw Object.assign(new Error('refused'), { status: 403 });
    }
    const sub = (url.match(/^\/subscriptions\/[^/]+/) || [])[0];
    // A subscription list returns what is at, below and above it (Azure's
    // principalId filter); a list at a place returns everything the identity
    // holds, and the page picks the place.
    const atSub = /^\/subscriptions\/[^/]+\/providers\//.test(url);
    return { value: (answer || []).filter(a => !atSub || a.properties.scope.toLowerCase().startsWith(sub.toLowerCase()) ||
      a.properties.scope.startsWith('/providers/Microsoft.Management/')) };
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
            { subscriptionId: 'sub-2', displayName: 'Fabrikam Sub', state: 'Enabled' }] };
        }
        if (/\/resourcegroups\?/i.test(url)) { return { value: [{ name: 'rg-orphan' }] }; }
        if (url.includes('/descendants?')) { return { value: opts.descendants || [] }; }
        if (url.includes("'svc-1'")) { return listFor('service', url); }
        if (url.includes("'eng-1'")) { return listFor('engine', url); }
        return { value: [] };
      }
      if (method === 'DELETE' && opts.deleteStatus) {
        throw Object.assign(new Error('refused'), { status: opts.deleteStatus });
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
    return { loadScopes, scopeLagRead, scopeRowsWithCoverage };
  })`)(env);
  return { ...api, host, calls, flashes, asked, buttons: () => drawn };
}

const rowsOf = (html) => (String(html).match(/<tr><td>[\s\S]*?<\/tr>/g) || []);
const deleted = (pg) => pg.calls.filter(c => c.method === 'DELETE').map(c => c.url.split('?')[0]);
const serviceOnlyButtons = (pg) => pg.buttons().filter(b => b.dataset.serviceonly === '1');

const engAssess = assignment(SUB, 'eng-assess', 'assess-guid');
const svcSub = assignment(SUB, 'svc-sub', 'assess-guid');
const svcRg = assignment(RG, 'svc-rg', 'assess-guid');

test('a web service assignment with no engine grant at its place draws a row', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg] });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 2, 'the engine grant, and the web service assignment that has no engine grant');
  const orphan = rows.find(r => r.includes('rg-orphan'));
  ok(orphan, 'the resource group the web service alone can read has a row');
  ok(orphan.includes(UX.scopeServiceOnlyNote), 'marked as the web service only');
  ok(!rows.find(r => !r.includes('rg-orphan')).includes(UX.scopeServiceOnlyNote), 'the paired row is not marked');
  ok(pg.host.innerHTML.includes(UX.scopeServiceOnlyWhy), 'and the card says what the mark means');
});

test('an engine grant above the place: the row never says flatly that the tool cannot scan or migrate there', async () => {
  // The engine at the subscription still reaches the resource group below it,
  // so a flat "cannot scan or migrate" would be false. Review finding.
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg] });
  await pg.loadScopes();
  const orphan = rowsOf(pg.host.innerHTML).find(r => r.includes('rg-orphan'));
  ok(orphan && !/cannot scan|cannot migrate|cannot assess/i.test(orphan), 'the mark says only what is true: no engine grant at this place');
  const why = pg.host.innerHTML.split('</table>')[1] || '';
  ok(/cannot scan or migrate/.test(why), 'the explanation names what is lost');
  ok(/If no wider grant covers it, the product cannot scan or migrate/.test(why), 'only with its condition');
});
test('a subscription where the engine holds nothing still shows the web service assignment', async () => {
  // The page stopped reading a subscription as soon as the engine list was
  // empty, so this assignment was never even looked at.
  const pg = page({ engine: [], service: [assignment(SUB2, 'svc-two', 'assess-guid')] });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'one row');
  ok(rows[0].includes('Fabrikam Sub') && rows[0].includes(UX.scopeServiceOnlyNote), 'the web service only, on that subscription');
});

test('the row offers Remove for that one assignment, and no repair and no second id', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg] });
  await pg.loadScopes();
  const b = serviceOnlyButtons(pg);
  eq(b.length, 1, 'one Remove for the web service only row');
  eq(b[0].dataset.revoke, svcRg.id, 'it names the web service assignment');
  ok(!('revoke2' in b[0].dataset), 'there is nothing paired with it to remove');
  ok(!('shared' in b[0].dataset), 'and no engine grant shares it');
  ok(!pg.buttons().some(x => 'fixhalf' in x.dataset), 'no repair: the engine half is added with the form');
});

test('a web service assignment paired with an engine grant at its place draws no second row', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub] });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 1, 'one row, as before');
  ok(!pg.host.innerHTML.includes(UX.scopeServiceOnlyNote), 'no web service only mark');
  ok(!pg.host.innerHTML.includes(UX.scopeServiceOnlyWhy), 'and no explanation of a mark that is not there');
});

test('the pairing stays at the same place, in any spelling', async () => {
  // A trailing slash or another case is the same place (scopeNormalize).
  const spelled = { ...svcSub, properties: { ...svcSub.properties, scope: SUB.toUpperCase().replace('SUBSCRIPTIONS', 'subscriptions') + '/' } };
  const pg = page({ engine: [engAssess], service: [spelled] });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 1, 'paired');
});

test('a role that is not ours on the web service draws nothing', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub, assignment(RG, 'svc-reader', 'acdd72a7-reader')] });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 1, 'only VMF roles are this page\'s to show');
});

test('a pending removal record hides it while Azure still lists it', async () => {
  // This tab removed it seconds ago; Azure's list lags the delete.
  const pending = [{ action: 'removed', id: svcRg.id, ids: [svcRg.id], atMs: Date.now() }];
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg], pending });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 1, 'the removed assignment does not come back');
  ok(pg.host.innerHTML.includes(UX.scopeLagWhy), 'and the card says why Azure still lists it');
});

test('a grant this tab just made, not listed whole yet, draws one row and no web service only row', async () => {
  // Azure lists the web service half already and not the engine half. The
  // record draws the grant; the half Azure listed is part of it.
  const engNew = `${RG}${AUTH}eng-new`;
  const pending = [{ action: 'added', id: engNew, ids: [engNew, svcRg.id], atMs: Date.now(),
    row: { name: 'rg-orphan (Contoso Sub)', level: UX.scopeLevelNameRg, what: UX.scopeLook, mode: 'assess', scope: RG, reach: 'full' } }];
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg], pending });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 2, 'the subscription, and the grant just made');
  ok(!pg.host.innerHTML.includes(UX.scopeServiceOnlyNote), 'not drawn a second time as the web service only');
});

test('and the same when the record carries no web service id: the place pairs them', async () => {
  // A grant whose web service PUT got 409 names the engine assignment alone,
  // and the web service assignment it relies on is the one at its place.
  const engNew = `${RG}${AUTH}eng-new`;
  const pending = [{ action: 'added', id: engNew, ids: [engNew], atMs: Date.now(),
    row: { name: 'rg-orphan (Contoso Sub)', level: UX.scopeLevelNameRg, what: UX.scopeLook, mode: 'assess', scope: RG, reach: 'full' } }];
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg], pending });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 2, 'one row for the place');
  ok(!pg.host.innerHTML.includes(UX.scopeServiceOnlyNote), 'no web service only row');
});

test('two tabs removed the two grants of one place: once Azure drops both, the kept assignment shows', async () => {
  // Each tab kept the web service assignment, because each still saw the
  // other's grant. Neither tab removed it, so a row must show it.
  const pending = [{ action: 'removed', id: engAssess.id, ids: [engAssess.id], atMs: Date.now() }];
  const pg = page({ engine: [], service: [svcSub], pending });
  await pg.loadScopes();
  const rows = rowsOf(pg.host.innerHTML);
  eq(rows.length, 1, 'the web service assignment nobody removed');
  ok(rows[0].includes(UX.scopeServiceOnlyNote), 'marked');
});

test('the web service list cannot be read: no web service only row, and the card says it cannot tell', async () => {
  const pg = page({ engine: [engAssess], service: 'fail' });
  await pg.loadScopes();
  eq(rowsOf(pg.host.innerHTML).length, 1, 'the engine grant');
  ok(!pg.host.innerHTML.includes(UX.scopeServiceOnlyNote), 'cannot tell is never drawn as a row');
  ok(pg.host.innerHTML.includes(UX.scopeHalfUnknown), 'said once');
});

test('the web service list cannot be read in a subscription where the engine holds nothing: still cannot tell', async () => {
  // That subscription may hold a web service assignment with no engine grant.
  const pg = page({ engine: [engAssess], service: [svcSub], serviceFailsIn: SUB2 });
  await pg.loadScopes();
  ok(pg.host.innerHTML.includes(UX.scopeHalfUnknown), 'the card says it cannot tell');
});

test('a web service only row on a deleted resource group is marked, like an engine grant', async () => {
  const gone = assignment('/subscriptions/sub-1/resourceGroups/rg-deleted', 'svc-gone', 'assess-guid');
  const pg = page({ engine: [engAssess], service: [svcSub, gone] });
  await pg.loadScopes();
  const row = rowsOf(pg.host.innerHTML).find(r => r.includes('rg-deleted'));
  ok(row && row.includes(UX.scopeGone), 'the resource groups are read for it, and it is marked');
});

test('two web service assignments at one place: Remove deletes the one on its row', async () => {
  // Never "the one at this place": that could be the other one.
  const svcRgMig = assignment(RG, 'svc-rg-mig', 'migrate-guid');
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg, svcRgMig] });
  await pg.loadScopes();
  const b = serviceOnlyButtons(pg).find(x => x.dataset.revoke === svcRgMig.id);
  ok(b, 'each has its own row');
  await b.click();
  eq(deleted(pg), [svcRgMig.id], 'the one on the row');
});

test('a web service only row neither covers an engine grant nor is covered', async () => {
  // A web service read at a management group gives the engine nothing, so
  // the engine's subscription grant still adds something.
  const pg = page({ engine: [engAssess], service: [svcSub, assignment(MG, 'svc-mg', 'assess-guid')],
    descendants: [{ id: '/subscriptions/sub-1' }] });
  await pg.loadScopes();
  ok(!pg.host.innerHTML.includes(UX.scopeCoveredBy.split('{place}')[0]), 'no row is marked as already covered');
  const cover = pg.scopeRowsWithCoverage([
    { name: 'Contoso Sub', scope: SUB, mode: 'assess', reach: 'full' },
    { name: 'rg-orphan', scope: RG, mode: 'assess', reach: 'service-only' },
  ], new Map());
  ok(!cover[1].coveredBy, 'and an engine grant does not cover the web service only row: removing it still takes access away');
});

test('Remove asks first, with a Cancel, and says what goes', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg], decline: true });
  await pg.loadScopes();
  await serviceOnlyButtons(pg)[0].click();
  eq(pg.asked.length, 1, 'asked in the row');
  eq(pg.asked[0].desc, UX.scopeServiceRemoveDesc, 'the words for the web service read access');
  eq(pg.asked[0].cancel, UX.cancel, 'with a way back');
  eq(deleted(pg), [], 'nothing is deleted before Yes');
});

test('Remove deletes that one assignment as the signed-in user, and records it', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg] });
  await pg.loadScopes();
  await serviceOnlyButtons(pg)[0].click();
  eq(deleted(pg), [svcRg.id], 'only the web service assignment');
  eq(pg.flashes.map(f => f.msg), [UX.scopeServiceRemoved], 'and the page says so');
  eq(pg.scopeLagRead().map(r => r.ids), [[svcRg.id]], 'the record hides it while Azure still lists it');
  const gets = pg.calls.filter(c => c.method === 'GET' && c.url.startsWith(`${RG}/providers/`));
  ok(gets.length >= 1, 'the page asked Azure about the place at the moment of the removal');
});

test('an engine grant now on the place keeps the assignment, and says why', async () => {
  // Somebody gave the engine access here after the table was read. The web
  // service assignment then belongs to that grant (ACCESS-REMOVE-SHARED-1),
  // so the page asks Azure at the moment of the removal, not the old table.
  const azure = { engine: [engAssess], service: [svcSub, svcRg] };
  const pg = page(azure);
  await pg.loadScopes();
  const b = serviceOnlyButtons(pg)[0];
  azure.engine = [engAssess, assignment(RG, 'eng-late', 'assess-guid')];
  await b.click();
  eq(deleted(pg), [], 'nothing is deleted');
  eq(pg.flashes.map(f => f.msg), [UX.scopeServiceKeptEngine], 'and the page says an engine grant uses it');
  eq(pg.scopeLagRead(), [], 'and nothing is recorded as removed');
});

test('the engine list cannot be read at the moment of the removal: kept, and said', async () => {
  const azure = { engine: [engAssess], service: [svcSub, svcRg] };
  const pg = page(azure);
  await pg.loadScopes();
  const b = serviceOnlyButtons(pg)[0];
  azure.engine = 'fail';
  await b.click();
  eq(deleted(pg), [], 'never guessed: nothing is deleted');
  eq(pg.flashes.map(f => f.msg), [UX.scopeServiceKeptUnread], 'the reason is shown');
});
test('a refused delete says the account cannot change access, and gives the button back', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub, svcRg], deleteStatus: 403 });
  await pg.loadScopes();
  const b = serviceOnlyButtons(pg)[0];
  await b.click();
  eq(pg.flashes.map(f => f.msg), [UX.scopeNoPerm], 'the plain answer');
  eq(b.disabled, false, 'the button works again');
});

test('an engine row\'s Remove is unchanged: both halves, as ACCESS-REMOVE-SHARED-1 left it', async () => {
  const pg = page({ engine: [engAssess], service: [svcSub] });
  await pg.loadScopes();
  const b = pg.buttons().find(x => x.dataset.revoke === engAssess.id);
  ok(b && b.dataset.revoke2 === svcSub.id, 'the engine row carries its pair');
  await b.click();
  eq(deleted(pg), [engAssess.id, svcSub.id], 'both go');
  eq(pg.asked[0].desc, UX.scopeRemoveDesc, 'with the engine words');
});

run('a web service read with no engine grant is shown and can be removed');
