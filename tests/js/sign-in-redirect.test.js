/* POPUP-3: signing in by redirect, and the guard that stops it looping.
 *
 * The Pester gate beside this proves no page CALLS a popup any more. It cannot
 * prove the redirect behaves, and the first round of mutation testing said so:
 * deleting the loop guard entirely left every Pester assertion green, because
 * they checked that words appeared in the file rather than what the code did.
 *
 * WHY THE GUARD IS THE DANGEROUS PART. A popup that fails leaves the page
 * standing. A redirect that fails comes BACK to the page - and a page that asks
 * again as it loads leaves again, for ever, on a permission that may never be
 * grantable. The Admin page asks for directory permissions only an
 * administrator can approve, so that loop is not hypothetical.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run, msalStandIn, msalToken } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));

// The key is READ FROM THE SOURCE rather than repeated here, so the test
// cannot go on passing against a name the code no longer uses.
const KEY = (HELP.match(/const INTERACTIVE_TRIED = '([^']+)'/) || [])[1];
globalThis.INTERACTIVE_TRIED = KEY;

const tokenOrRedirect = lift('help.js', 'tokenOrRedirect');
const accountsAfterReturn = lift('help.js', 'accountsAfterReturn');

function store(seed) {
  const map = new Map(seed ? Object.entries(seed) : []);
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    has: (k) => map.has(k),
  };
}

/* The shared stand-in for the library (MSAL-FAKE-STRICT-1, _harness.js), ready
 * to use. `calls` counts what it was asked. Like the library, it refuses a
 * silent request with no account, so every request below names one. */
const ACCOUNT = { username: 'someone@example.com', homeAccountId: 'home-1' };
function fakeMsal(opts) {
  const lib = msalStandIn(opts);
  const app = lib.ready();
  const count = (name) => lib.log.calls.filter(c => c === name).length;
  Object.defineProperty(app, 'calls', { get: () => ({ tokenRedirect: count('acquireTokenRedirect') }) });
  return app;
}
test('the key name was read out of the source', () => {
  ok(KEY && KEY.length > 3, 'without it every test below drives the wrong key');
});

test('a silent token is returned, and clears any earlier refusal', () => {
  const s = store({ [KEY]: '1' });
  globalThis.sessionStorage = s;
  return tokenOrRedirect(fakeMsal({}), { scopes: ['x'], account: ACCOUNT }).then((tok) => {
    eq(tok, msalToken(['x']), 'the token');
    ok(!s.has(KEY), 'a working session is not still marked as refused');
  });
});

test('no silent token: it leaves for the directory, once', async () => {
  const s = store();
  globalThis.sessionStorage = s;
  const app = fakeMsal({ silentFails: 'interaction_required' });
  let threw = null;
  try { await tokenOrRedirect(app, { scopes: ['x'], account: ACCOUNT }); } catch (e) { threw = e; }
  eq(app.calls.tokenRedirect, 1, 'one redirect');
  ok(s.has(KEY), 'the attempt is remembered');
  // It must not return a promise that never settles: the browser is
  // navigating away, and a caller awaiting for ever would hang the page.
  ok(threw, 'the original failure is handed back');
});

test('THE LOOP GUARD: a second failure does not leave again', async () => {
  // This is the mutation that survived the first round. Deleting the guard
  // makes this fail, and nothing else did.
  const s = store({ [KEY]: '1' });
  globalThis.sessionStorage = s;
  const app = fakeMsal({ silentFails: 'interaction_required' });
  let threw = null;
  try { await tokenOrRedirect(app, { scopes: ['x'], account: ACCOUNT }); } catch (e) { threw = e; }
  eq(app.calls.tokenRedirect, 0, 'it must NOT redirect a second time');
  ok(threw, 'it fails instead, so the page can say why');
  // CONSENT-STUCK-1: and it SAYS which failure this is. Rethrowing the
  // original left a button that appeared to do nothing at all.
  ok(/vmf_asked_already/.test(threw.message), 'the refusal names itself');
  ok(threw.cause, 'and keeps the original failure');
});

test('a refused return REMEMBERS the attempt, so the next load does not ask', async () => {
  // The other survivor. Clearing the key here is the subtler way to build the
  // same loop: the page comes back refused, forgets, and asks again.
  const s = store();
  globalThis.sessionStorage = s;
  let threw = null;
  try { await accountsAfterReturn(fakeMsal({ returnFails: 'access_denied' })); } catch (e) { threw = e; }
  ok(threw, 'the refusal reaches the page');
  ok(s.has(KEY), 'and is remembered, or the page asks again on every load');
});

test('a successful return hands back the account it brought', async () => {
  const s = store({ [KEY]: '1' });
  globalThis.sessionStorage = s;
  const account = { username: 'someone@example.com' };
  const got = await accountsAfterReturn(fakeMsal({ returned: { account } }));
  eq(got.length, 1, 'one account');
  eq(got[0].username, account.username, 'the one the redirect brought');
  ok(!s.has(KEY), 'a completed sign-in is not still marked as refused');
});

test('an ordinary load falls back to the accounts already cached', async () => {
  globalThis.sessionStorage = store();
  const cached = [{ username: 'cached@example.com' }];
  const got = await accountsAfterReturn(fakeMsal({ accounts: cached }));
  eq(got.length, 1, 'the cached account');
  eq(got[0].username, 'cached@example.com', 'unchanged');
});

run('sign-in-redirect');
