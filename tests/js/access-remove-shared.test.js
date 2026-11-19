/* ACCESS-REMOVE-SHARED-1, 2026-10-24. Filed by ACCESS-LAG-WORDS-1 from
 * reading the code.
 *
 * The web service holds ONE VMF Assessment assignment for each place
 * (ACCESS-HALF-1). Azure refuses a second identical one, so a second engine
 * grant on the same place - "Assess" and then "Assess and migrate" - shares
 * it. The page pairs an engine row with the web service assignment AT THE
 * SAME SCOPE (scopeNormalize, exact), so both rows carried the same id, and
 * Remove on either deleted it. The row that stayed then said "The engine
 * only", and every list of machines in that place was empty.
 *
 * The rule now: Remove deletes the web service assignment only when no other
 * engine grant on that place still uses it - listed by Azure, or added by
 * this page and not listed yet. Cannot tell is never yes: when the page cannot
 * read the grants, the web service half stays and the page says why. The
 * engine half is removed either way.
 *
 * Every case is RUN: the page's own revokeScope and revokeScopeNow, with
 * Azure and the browser stubbed. Nothing here reaches Azure.
 */
'use strict';
const { extract, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('access.html', 'UX');
const SUB = '/subscriptions/sub-1';
const RG = '/subscriptions/sub-1/resourceGroups/rg-app';
const AUTH = '/providers/Microsoft.Authorization/roleAssignments/';

// A helper the fixed page has and the old page did not. Lifted when it is
// there, so the tests below fail on what the page DOES, not on a missing name.
function present(names) {
  return names.filter(n => { try { extract('access.html', n); return true; } catch { return false; } });
}

const assignment = (scope, guid, role) => ({
  id: `${scope}${AUTH}${guid}`,
  properties: { scope, roleDefinitionId: `/providers/Microsoft.Authorization/roleDefinitions/${role}` },
});

/* opts.engine / opts.service: what Azure lists for that identity at the
 * place, or 'fail' when the read is refused. opts.pending: the page's own
 * records of what it just did (SCOPE-LAG-1). */
function page(opts = {}) {
  const names = ['revokeScope', 'revokeScopeNow', 'scopeLagIds', 'scopeLagRead', 'scopeLagWrite',
    'scopeLagNote', 'scopeNormalize', 'vmfRoleId']
    .concat(present(['scopeServiceInUse', 'scopeServiceStep', 'scopeOfAssignment']));
  const bodies = names.map(n => extract('access.html', n)).join('\n');
  const store = new Map();
  if (opts.pending) { store.set('vmf-scope-lag', JSON.stringify(opts.pending)); }
  const calls = [];
  const flashes = [];
  const asked = [];
  const env = {
    UX,
    cfg: { enginePrincipalId: 'eng-1', webServicePrincipalId: opts.noService ? undefined : 'svc-1',
      assessRoleId: '/roles/assess-guid', migrateRoleId: '/roles/migrate-guid' },
    VmfHelp: { confirmInPlace: (b, o, yes) => { asked.push(o); return yes(); } },
    sessionStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) },
    arm: async (method, url) => {
      calls.push({ method, url });
      if (method === 'GET') {
        const who = url.includes("'svc-1'") ? 'service' : url.includes("'eng-1'") ? 'engine' : 'other';
        const answer = opts[who];
        if (answer === 'fail') { throw Object.assign(new Error('refused'), { status: 403 }); }
        return { value: answer || [] };
      }
      if (method === 'DELETE' && (opts.gone || []).includes(url.split('?')[0])) {
        throw Object.assign(new Error('gone'), { status: 404 });
      }
      return {};
    },
    flash: (el, msg) => flashes.push({ el, msg }),
    fail: (e) => { throw e; },
    loadScopes: async () => { },
  };
  const api = eval(`(function (env) {
    const { UX, cfg, VmfHelp, sessionStorage, arm, flash, fail, loadScopes } = env;
    const SCOPE_LAG_KEY = 'vmf-scope-lag';
    const SCOPE_LAG_MS = 600000;
    ${bodies}
    return { revokeScope, revokeScopeNow, scopeLagRead,
             scopeServiceInUse: typeof scopeServiceInUse === 'function' ? scopeServiceInUse : null };
  })`)(env);
  return { ...api, store, calls, flashes, asked };
}

const btn = () => ({ disabled: false, textContent: '' });
const deleted = (pg) => pg.calls.filter(c => c.method === 'DELETE').map(c => c.url.split('?')[0]);

// Two engine grants on one subscription, and the ONE web service assignment
// they share.
const assess = assignment(SUB, 'eng-assess', 'assess-guid');
const migrate = assignment(SUB, 'eng-migrate', 'migrate-guid');
const svc = assignment(SUB, 'svc-read', 'assess-guid');

test('two grants on one place: removing one keeps the web service assignment', async () => {
  // Azure still lists the one being removed: the list lags the delete.
  const pg = page({ engine: [assess, migrate], service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id], 'only the engine assignment is deleted');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemovedShared], 'and the page says the web service access stays, and why');
});

test('and the removal record does not name the web service assignment it kept', async () => {
  // A record that named it would hide it as removed, and drop the record of
  // the other grant that names it too (scopeRowsWithLag).
  const pg = page({ engine: [assess, migrate], service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  const records = pg.scopeLagRead();
  eq(records.length, 1, 'one record');
  eq(records[0].ids, [assess.id], 'naming the engine assignment alone');
});

test('removing the last grant then removes the web service assignment', async () => {
  const pg = page({ engine: [migrate], service: [svc] });
  await pg.revokeScopeNow(migrate.id, btn(), svc.id);
  eq(deleted(pg), [migrate.id, svc.id], 'both halves go: a removal must remove');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemoved], 'the plain message');
  eq(pg.scopeLagRead()[0].ids, [migrate.id, svc.id], 'and the record names both');
});

test('the last grant, while Azure still lists the first one removed', async () => {
  // The first removal was seconds ago and Azure has not dropped it. The page's
  // own record says it is gone, so it relies on nothing.
  const pending = [{ action: 'removed', id: assess.id, ids: [assess.id], atMs: Date.now() }];
  const pg = page({ engine: [assess, migrate], service: [svc], pending });
  await pg.revokeScopeNow(migrate.id, btn(), svc.id);
  eq(deleted(pg), [migrate.id, svc.id], 'no orphan web service assignment is left');
});

test('a grant the page just made, and Azure does not list yet, keeps the web service assignment', async () => {
  // The second grant's web service PUT got 409, so its record names the
  // engine assignment alone - but it is on the same place.
  const pending = [{ action: 'added', id: migrate.id, ids: [migrate.id], atMs: Date.now(),
    row: { name: 'Contoso Sub', mode: 'migrate', scope: SUB, reach: 'full' } }];
  const pg = page({ engine: [assess], service: [svc], pending });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id], 'the pending grant still needs it');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemovedShared], 'said');
});

test('a grant that was added and then removed again relies on nothing', async () => {
  const pending = [
    { action: 'added', id: migrate.id, ids: [migrate.id], atMs: Date.now(), row: { scope: SUB } },
    { action: 'removed', id: migrate.id, ids: [migrate.id], atMs: Date.now() },
  ];
  const pg = page({ engine: [assess], service: [svc], pending });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id, svc.id], 'both halves go');
});

test('a single grant: both assignments are removed, as before', async () => {
  const pg = page({ engine: [assess], service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id, svc.id], 'both');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemoved], 'the plain message');
});

test('a grant on a resource group inside the place does not use its web service assignment', async () => {
  // The page pairs an engine row with the web service assignment AT ITS OWN
  // scope, and a grant on a resource group made here has its own.
  const inner = assignment(RG, 'eng-rg', 'migrate-guid');
  const pg = page({ engine: [assess, inner], service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id, svc.id], 'both halves of the subscription grant go');
});

test('another role on the same place, not one of ours, uses nothing of ours', async () => {
  const other = assignment(SUB, 'eng-reader', 'acdd72a7-reader');
  const pg = page({ engine: [assess, other], service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id, svc.id], 'both');
});

test('the engine list cannot be read: the engine half goes, the web service half stays, and the page says why', async () => {
  const pg = page({ engine: 'fail', service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id], 'never guessed: the shared half is kept');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemovedServiceUnread], 'and the reason is shown');
  eq(pg.scopeLagRead()[0].ids, [assess.id], 'the record names only what went');
});

test('the row carried no web service id: the page finds it at the place, and removes it when nothing uses it', async () => {
  // A row drawn from a record whose web service PUT got 409 carries none.
  const pg = page({ engine: [assess], service: [assignment(RG, 'svc-rg', 'assess-guid'), svc] });
  await pg.revokeScopeNow(assess.id, btn(), null);
  eq(deleted(pg), [assess.id, svc.id], 'the one AT this place, not the one below it');
});

test('the row carried no web service id and the web service list cannot be read: kept, and said', async () => {
  const pg = page({ engine: [assess], service: 'fail' });
  await pg.revokeScopeNow(assess.id, btn(), null);
  eq(deleted(pg), [assess.id], 'the engine half alone');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemovedServiceUnread], 'with the reason');
});

test('an install that does not name the web service removes the engine half, as before', async () => {
  const pg = page({ noService: true, engine: [assess] });
  await pg.revokeScopeNow(assess.id, btn(), null);
  eq(deleted(pg), [assess.id], 'the engine half');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemoved], 'nothing more to say');
});

test('an engine assignment already gone still lets the web service half go', async () => {
  // It used to stop at the 404 and record both as removed, leaving the web
  // service assignment in Azure with no row to remove it from.
  const pg = page({ engine: [], service: [svc], gone: [assess.id] });
  await pg.revokeScopeNow(assess.id, btn(), svc.id);
  eq(deleted(pg), [assess.id, svc.id], 'the web service half is deleted too');
  eq(pg.flashes.map(f => f.msg), [UX.scopeRemoved], 'already gone is the outcome asked for');
});

test('every read and delete is made as the signed-in user, at the place itself', async () => {
  const pg = page({ engine: [assess, migrate], service: [svc] });
  await pg.revokeScopeNow(assess.id, btn(), null);
  const gets = pg.calls.filter(c => c.method === 'GET').map(c => c.url);
  ok(gets.length >= 1, 'the page reads the grants before it decides');
  ok(gets.every(u => u.startsWith(`${SUB}/providers/Microsoft.Authorization/roleAssignments?`)), 'at the place');
  ok(gets.every(u => !u.includes('&$select')), 'one filter per call');
});

test('the question before Remove says the web service access stays when another grant uses it', async () => {
  const pg = page({ engine: [assess, migrate], service: [svc] });
  await pg.revokeScope(assess.id, btn(), svc.id, true);
  eq(pg.asked[0].desc, UX.scopeRemoveDescShared, 'the shared words');
  const lone = page({ engine: [assess], service: [svc] });
  await lone.revokeScope(assess.id, btn(), svc.id, false);
  eq(lone.asked[0].desc, UX.scopeRemoveDesc, 'the plain words for a single grant');
});

/* The rule the table and the removal share, driven directly. */
test('the rule: same web service id, or same place, and not removed', () => {
  const pg = page();
  ok(typeof pg.scopeServiceInUse === 'function', 'the page has the rule');
  const me = { id: '/a', scope: SUB, serviceId: '/s' };
  eq(pg.scopeServiceInUse(me, [me], []), false, 'a row alone uses nothing else');
  eq(pg.scopeServiceInUse(me, [me, { id: '/b', scope: SUB + '/', serviceId: null }], []), true, 'same place, any spelling');
  eq(pg.scopeServiceInUse(me, [me, { id: '/b', scope: RG, serviceId: '/s' }], []), true, 'the same web service id');
  eq(pg.scopeServiceInUse(me, [me, { id: '/b', scope: RG, serviceId: null }], []), false, 'a place below is not the same place');
  eq(pg.scopeServiceInUse(me, null, []), null, 'a list that could not be read is cannot tell');
  eq(pg.scopeServiceInUse(me, [me, { id: '/b', scope: SUB }],
    [{ action: 'removed', id: '/b', ids: ['/b'], atMs: Date.now() }]), false, 'a grant removed here relies on nothing');
});

test('the table marks a row whose web service assignment another row uses', () => {
  // Read from the page's render, so the question matches the outcome.
  // Comments stripped, so a comment naming the rule cannot pass this.
  const src = extract('access.html', 'loadScopes')
    .replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:])\/\/.*$/gm, '$1');
  ok(/scopeServiceInUse\(/.test(src), 'the table asks the same rule');
  ok(/data-shared/.test(src), 'and passes it to Remove');
});

run('removing one grant keeps what another grant still uses');
