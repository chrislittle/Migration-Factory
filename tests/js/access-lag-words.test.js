/* ACCESS-LAG-WORDS-1, 2026-10-23. The owner gave the tool "Assess and
 * migrate" on a subscription from the Admin page. The row read "Assess",
 * marked "just added", until Azure listed the grant.
 *
 * Two causes, both driven here by RUNNING the page's own functions:
 *
 *  1. The grant wrote its pending record from the SCOPE LEVEL ('sub', 'rg',
 *     'mg') where it meant the MODE ('assess', 'migrate'). So every pending
 *     row said "Assess", whatever the person chose.
 *  2. A grant is two role assignments - the engine's and the web service's -
 *     and the page remembered only the engine's. While Azure listed the
 *     engine's and not yet the web service's, the row was drawn from that
 *     part, with the "engine only" warning, and its Remove button could take
 *     away only half of the grant.
 *
 * The rule now: one record per grant or removal, naming every assignment in
 * it, and the record draws the row until Azure lists ALL of them.
 */
'use strict';
const { extract, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const { scopeRowsWithLag } = liftAll('access.html', ['scopeRowsWithLag'].concat(present(['scopeLagIds'])));
const UX = liftConst('access.html', 'UX');

// A helper the fixed page has and the old page did not. Lifted when it is
// there, so the tests below fail on what the page DOES, not on a missing name.
function present(names) {
  return names.filter(n => { try { extract('access.html', n); return true; } catch { return false; } });
}

/* The grant and the removal, run as the page runs them, with Azure and the
 * browser stubbed. Nothing here reaches Azure. */
function page(choice, opts = {}) {
  const names = ['grantScope', 'grantScopeNow', 'grantPlan', 'describeScope', 'vmfRoleId',
    'scopeLagRead', 'scopeLagWrite', 'scopeLagNote', 'revokeScopeNow']
    .concat(present(['scopeLagIds', 'scopeNormalize', 'scopeOfAssignment', 'scopeServiceInUse', 'scopeServiceStep']));
  const bodies = names.map(n => extract('access.html', n)).join('\n');
  const store = new Map();
  const calls = [];
  let n = 0;
  const env = {
    UX,
    cfg: { enginePrincipalId: 'eng-1', webServicePrincipalId: opts.noService ? undefined : 'svc-1',
      assessRoleId: '/roles/assess', migrateRoleId: '/roles/migrate' },
    subs: [{ subscriptionId: 'sub-1', displayName: 'Contoso Sub' }],
    $: (s) => ({ '#scope-btn': { disabled: false, textContent: '' },
      '#scope-pick': { value: 'sub-1' }, '#scope-rg': { value: '' }, '#scope-mg': { value: '' } }[s] || { value: '' }),
    document: { querySelector: (s) => (s.includes('scope-mode') ? { value: choice } : null) },
    scopeLevel: () => 'sub',
    vmfRoleDefinition: async (mode) => ({ id: mode === 'migrate' ? '/roles/migrate' : '/roles/assess', properties: {} }),
    scopeIsCovered: async () => true,
    widenScopes: () => ({ scopes: [] }),
    placeName: (s) => s,
    VmfHelp: { confirmInPlace: (b, o, yes) => yes() },
    crypto: { randomUUID: () => `ra-${++n}` },
    sessionStorage: { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, v) },
    arm: async (method, url, body) => {
      calls.push({ method, url, body });
      if (method === 'PUT') {
        if (opts.serviceFails && body.properties.principalId === 'svc-1') {
          throw Object.assign(new Error('refused'), { status: 500 });
        }
        const id = url.split('?')[0];
        return { id, properties: { scope: id.split('/providers/Microsoft.Authorization')[0], ...body.properties } };
      }
      return {};
    },
    flash: () => { }, fail: (e) => { throw e; }, loadScopes: async () => { },
  };
  const api = eval(`(function (env) {
    const { UX, cfg, subs, $, document, scopeLevel, vmfRoleDefinition, scopeIsCovered, widenScopes,
            placeName, VmfHelp, crypto, sessionStorage, arm, flash, fail, loadScopes } = env;
    const SCOPE_LAG_KEY = 'vmf-scope-lag';
    const SCOPE_LAG_MS = 600000;
    ${bodies}
    return { grantScope, revokeScopeNow, scopeLagRead, scopeLagNote };
  })`)(env);
  return { ...api, store, calls };
}

const grantIds = (calls) => calls.filter(c => c.method === 'PUT').map(c => c.url.split('?')[0]);
// What Azure lists for the engine at a subscription: one row per assignment.
const listedEngine = (id, serviceId) => ({
  id, name: 'Contoso Sub', level: 'Subscription', what: UX.scopeChange, mode: 'migrate', stale: false,
  scope: '/subscriptions/sub-1', reach: serviceId ? 'full' : 'engine-only', serviceId: serviceId || null,
});

test('a grant of Assess and migrate is remembered as Assess and migrate, not Assess', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const records = pg.scopeLagRead();
  eq(records.length, 1, 'ONE record for the grant');
  eq(records[0].row.what, UX.scopeChange, 'the words the person chose');
  eq(records[0].row.mode, 'migrate', 'and the mode, which ranks it');
});

test('and a grant of Assess is remembered as Assess', async () => {
  const pg = page('assess');
  await pg.grantScope();
  const records = pg.scopeLagRead();
  eq(records[0].row.what, UX.scopeLook, 'Assess');
  eq(records[0].row.mode, 'assess', 'assess');
});

test('the one record names BOTH assignments the grant made, engine first', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const made = grantIds(pg.calls);
  eq(made.length, 2, 'the page made two assignments');
  eq(pg.scopeLagRead()[0].ids, made, 'and the record names both of them');
});

test('Azure lists neither: the row says Assess and migrate, just added', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const out = scopeRowsWithLag([], pg.scopeLagRead(), []);
  eq(out.rows.length, 1, 'one row');
  eq(out.rows[0].what, UX.scopeChange, 'Assess and migrate');
  eq(out.rows[0].justAdded, true, 'just added');
});

test('Azure lists only the engine assignment: still Assess and migrate, still from the record', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const [eng] = grantIds(pg.calls);
  const out = scopeRowsWithLag([listedEngine(eng, null)], pg.scopeLagRead(), []);
  eq(out.rows.length, 1, 'never doubled');
  eq(out.rows[0].what, UX.scopeChange, 'Assess and migrate');
  eq(out.rows[0].justAdded, true, 'still just added, because Azure has listed only part of it');
  ok(out.rows[0].reach !== 'engine-only', 'not the engine-only warning for a grant the page made whole');
  eq(out.acting.length, 1, 'and the reason line shows');
});

test('Azure lists only the web service assignment: still Assess and migrate', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const [, svc] = grantIds(pg.calls);
  const out = scopeRowsWithLag([], pg.scopeLagRead(), [svc]);
  eq(out.rows.length, 1, 'one row');
  eq(out.rows[0].what, UX.scopeChange, 'Assess and migrate');
  eq(out.rows[0].justAdded, true, 'just added');
});

test('a row drawn from the record can remove the whole grant', async () => {
  // Remove on a just-added row used to carry the engine id alone, so the web
  // service kept its role. A removal must remove.
  const pg = page('migrate');
  await pg.grantScope();
  const [eng, svc] = grantIds(pg.calls);
  const out = scopeRowsWithLag([listedEngine(eng, null)], pg.scopeLagRead(), []);
  eq(out.rows[0].id, eng, 'Remove takes the engine assignment');
  eq(out.rows[0].serviceId, svc, 'and the web service assignment');
});

test('Azure lists both: the row is Azure\'s, unmarked, and the record is kept', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const [eng, svc] = grantIds(pg.calls);
  const out = scopeRowsWithLag([listedEngine(eng, svc)], pg.scopeLagRead(), [svc]);
  eq(out.rows.length, 1, 'one row');
  eq(out.rows[0].justAdded, undefined, 'unmarked');
  eq(out.rows[0].what, UX.scopeChange, 'Assess and migrate');
  eq(out.acting.length, 0, 'nothing pending on screen');
  eq(out.keep.length, 1, 'kept to its cap (LAG-FLAP-1)');
});

test('a later read that loses one of them goes back to the record, never to part of it', async () => {
  const pg = page('migrate');
  await pg.grantScope();
  const [eng, svc] = grantIds(pg.calls);
  const both = scopeRowsWithLag([listedEngine(eng, svc)], pg.scopeLagRead(), [svc]);
  const flap = scopeRowsWithLag([listedEngine(eng, null)], both.keep, []);
  eq(flap.rows.length, 1, 'one row');
  eq(flap.rows[0].justAdded, true, 'from the record again');
  ok(flap.rows[0].reach !== 'engine-only', 'not shown as half a grant');
});

test('a grant whose web service half failed is drawn as the engine only', async () => {
  const pg = page('migrate', { serviceFails: true });
  await pg.grantScope();
  const records = pg.scopeLagRead();
  eq(records[0].ids.length, 1, 'only the assignment Azure made');
  const out = scopeRowsWithLag([], records, []);
  eq(out.rows[0].reach, 'engine-only', 'the half the page could not make is said');
});

test('an install that does not name the web service draws the half as cannot tell', async () => {
  const pg = page('migrate', { noService: true });
  await pg.grantScope();
  const records = pg.scopeLagRead();
  eq(records[0].ids.length, 1, 'one assignment');
  eq(scopeRowsWithLag([], records, []).rows[0].reach, 'unknown', 'never drawn as covered');
});

test('a removal names both assignments it took away', async () => {
  const pg = page('migrate');
  await pg.revokeScopeNow('/subscriptions/sub-1/ra/eng', { disabled: false, textContent: '' }, '/subscriptions/sub-1/ra/svc');
  const records = pg.scopeLagRead();
  eq(records.length, 1, 'one record');
  eq(records[0].action, 'removed', 'a removal');
  eq(records[0].ids, ['/subscriptions/sub-1/ra/eng', '/subscriptions/sub-1/ra/svc'], 'naming both');
});

test('removed, and Azure still lists the engine assignment: no row, not Assess', () => {
  const pending = [{ action: 'removed', id: '/e', ids: ['/e', '/s'], atMs: Date.now() }];
  const out = scopeRowsWithLag([listedEngine('/e', null)], pending, []);
  eq(out.rows.length, 0, 'the removed grant is not shown');
  eq(out.acting.length, 1, 'and the reason line says why');
});

test('removed, and Azure still lists the web service assignment: no half row', () => {
  const pending = [{ action: 'removed', id: '/e', ids: ['/e', '/s'], atMs: Date.now() }];
  const out = scopeRowsWithLag([], pending, ['/s']);
  eq(out.rows.length, 0, 'nothing is drawn from the part Azure still lists');
});

test('a grant removed again before Azure listed it is not shown', () => {
  const pending = [
    { action: 'added', id: '/e', ids: ['/e', '/s'], atMs: Date.now(), row: { name: 'X', what: UX.scopeChange } },
    { action: 'removed', id: '/e', ids: ['/e', '/s'], atMs: Date.now() },
  ];
  const out = scopeRowsWithLag([listedEngine('/e', '/s')], pending, ['/s']);
  eq(out.rows.length, 0, 'the removal is the later word');
  eq(out.keep.map(k => k.action), ['removed'], 'and the removal alone is kept');
});

test('when the web service list cannot be read, the engine assignment decides', () => {
  // Cannot tell is never yes and never no: the page goes back to what it
  // could see, the engine row, instead of insisting for ten minutes.
  const pending = [{ action: 'added', id: '/e', ids: ['/e', '/s'], atMs: Date.now(), row: { name: 'X', what: UX.scopeChange } }];
  const out = scopeRowsWithLag([{ ...listedEngine('/e', null), reach: 'unknown' }], pending, null);
  eq(out.rows.length, 1, 'one row');
  eq(out.rows[0].justAdded, undefined, 'Azure\'s row, unmarked');
});

test('a record an older page left, with one id, still works', () => {
  const old = { action: 'added', id: '/new', atMs: Date.now(), row: { name: 'X', what: UX.scopeChange } };
  const ahead = scopeRowsWithLag([], [old], []);
  eq(ahead.rows.length, 1, 'shown until Azure lists it');
  eq(ahead.rows[0].justAdded, true, 'marked');
  const caught = scopeRowsWithLag([listedEngine('/new', null)], [old], []);
  eq(caught.rows[0].justAdded, undefined, 'Azure\'s once listed');
});

test('stored records an older page left, or junk, do not break the page', () => {
  const pg = page('migrate');
  pg.store.set('vmf-scope-lag', JSON.stringify([
    null, 7, { action: 'added' }, { action: 'other', id: '/x' },
    { action: 'removed', id: '/old', atMs: Date.now() },
  ]));
  const read = pg.scopeLagRead();
  eq(read.length, 1, 'the old record is read, and the junk is left out');
  eq(read[0].id, '/old', 'the old record');
  pg.store.set('vmf-scope-lag', '{not json');
  eq(pg.scopeLagRead(), [], 'unreadable storage reads as nothing');
  pg.store.set('vmf-scope-lag', JSON.stringify({ action: 'added' }));
  eq(pg.scopeLagRead(), [], 'not a list reads as nothing');
});

test('a new record replaces an older page\'s record for the same assignment', () => {
  const pg = page('migrate');
  pg.store.set('vmf-scope-lag', JSON.stringify([{ action: 'added', id: '/e', atMs: Date.now(), row: { name: 'X' } }]));
  pg.scopeLagNote('removed', ['/e', '/s']);
  const read = pg.scopeLagRead();
  eq(read.length, 1, 'one record');
  eq(read[0].action, 'removed', 'the later word');
});

run('a pending grant shows everything the person chose');
