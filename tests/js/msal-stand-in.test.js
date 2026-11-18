/* MSAL-FAKE-STRICT-1: the shared stand-in for MSAL for the browser v5 keeps
 * the library's rules.
 *
 * WHY. TOKEN-SCOPE-1 shipped because each sign-in test built its own stand-in
 * that returned `{ accessToken }` for ANY request. The wizard asked for a
 * token with no scope, the stand-in gave one, 17 tests passed, and the
 * service refused the real token with 401 on the next install.
 *
 * So the stand-in in _harness.js is tested here on its own: each rule it
 * copies from the library is proved to hold, or every test that leans on it
 * proves nothing. The rules and the Microsoft pages they come from are in the
 * comment above msalStandIn() in _harness.js.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { extract, test, eq, ok, run, msalStandIn, msalToken, tokenClaims, OIDC_SCOPES } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const LIBRARY = pageSource(path.join(DASH, 'msal-browser.min.js'));
const API = ['api://api-app/access_as_user'];
const ACCOUNT = { username: 'someone@example.com', homeAccountId: 'home-1' };

async function refusal(fn) {
  try { await fn(); } catch (e) { return e; }
  return null;
}

/* ---------- the stand-in copies the PINNED library ---------- */

test('the pinned library is MSAL for the browser v5, the version these rules were read from', () => {
  const version = (LIBRARY.match(/@azure\/msal-browser v(\d+)\.\d+\.\d+/) || [])[1];
  // A new major version can change any rule below. Read them again from its
  // source and its pages, then change this number.
  eq(version, '5', 'the major version of src/dashboard/msal-browser.min.js');
});

test('the pinned library still has each refusal the stand-in copies', () => {
  for (const code of ['uninitialized_public_client_application', 'no_account_error']) {
    ok(LIBRARY.includes(`"${code}"`), `the library's error code ${code}`);
  }
  // A request with no scope is NOT refused: the library puts the OIDC scopes
  // in its place. This is the spelling in v5's own token lookup.
  ok(/scopes:\w+\.scopes\?\.length\?\w+\.scopes:\[\.\.\.\w+\]/.test(LIBRARY), 'empty scopes become the OIDC scopes');
});

/* ---------- rule 1: initialize() first ---------- */

test('a call before initialize() has finished is refused, and recorded', async () => {
  const lib = msalStandIn();
  const app = new lib.PublicClientApplication({});
  app.initialize();                                   // not waited for
  let threw = null;
  try { app.getAllAccounts(); } catch (e) { threw = e; }
  eq(threw && threw.errorCode, 'uninitialized_public_client_application', 'a synchronous call throws');
  const silent = await refusal(() => app.acquireTokenSilent({ scopes: API, account: ACCOUNT }));
  eq(silent && silent.errorCode, 'uninitialized_public_client_application', 'a token request is refused');
  const back = await refusal(() => app.handleRedirectPromise());
  eq(back && back.errorCode, 'uninitialized_public_client_application', 'the redirect answer is refused');
  eq(lib.log.early, ['getAllAccounts', 'acquireTokenSilent', 'handleRedirectPromise'], 'the early calls');
});

test('initialize() finishes on a later turn, so a page that does not wait for it is caught', async () => {
  const lib = msalStandIn();
  const app = new lib.PublicClientApplication({});
  const done = app.initialize();
  await Promise.resolve();
  let threw = false;
  try { app.getAllAccounts(); } catch { threw = true; }
  ok(threw, 'a call one microtask later is still early');
  await done;
  eq(app.getAllAccounts().length, 1, 'after the wait, the call works');
  eq(lib.log.early, ['getAllAccounts'], 'only the early call is recorded');
});

test('ready() gives an application that has finished initialize()', async () => {
  const lib = msalStandIn();
  const app = lib.ready();
  eq(app.getAllAccounts().length, 1, 'one account');
  eq(lib.log.early, [], 'no early calls');
});

/* ---------- rule 2: a silent request needs an account ---------- */

test('a silent request with no account, and no active account, is refused with no_account_error', async () => {
  const lib = msalStandIn();
  const app = lib.ready();
  for (const req of [{ scopes: API }, { scopes: API, account: null }]) {
    const e = await refusal(() => app.acquireTokenSilent(req));
    eq(e && e.errorCode, 'no_account_error', `refused ${JSON.stringify(req)}`);
  }
});

test('a silent request with no account uses the active account, as the library does', async () => {
  const lib = msalStandIn();
  const app = lib.ready();
  app.setActiveAccount(ACCOUNT);
  const r = await app.acquireTokenSilent({ scopes: API });
  eq(r.account.username, ACCOUNT.username, 'the active account');
});

/* ---------- rule 3: the token is for the scope asked for ---------- */

test('each scope gets its own token, and the token says which scope it was for', async () => {
  const lib = msalStandIn();
  const app = lib.ready();
  const graph = ['https://graph.microsoft.com/Application.Read.All'];
  const arm = ['https://management.azure.com/user_impersonation'];
  const tokens = [];
  for (const scopes of [API, graph, arm]) {
    const r = await app.acquireTokenSilent({ scopes, account: ACCOUNT });
    eq(r.accessToken, msalToken(scopes), `the token for ${scopes[0]}`);
    eq(tokenClaims(r.accessToken).scp, scopes[0], 'the scope the token names');
    tokens.push(r.accessToken);
  }
  eq(new Set(tokens).size, 3, 'three different tokens');
  eq(tokenClaims(msalToken(API)).aud, 'api://api-app', 'the audience of the service token');
});

test('a request with no scope is NOT refused: it gets a sign-in token, not the service token', async () => {
  // This is the TOKEN-SCOPE-1 fault, as the library behaves: no error, and a
  // token for the OIDC scopes that the service refuses with 401.
  const lib = msalStandIn();
  const app = lib.ready();
  for (const req of [{ account: ACCOUNT }, { scopes: undefined, account: ACCOUNT }, { scopes: [], account: ACCOUNT },
    { scopes: ['openid', 'profile'], account: ACCOUNT }]) {
    const r = await app.acquireTokenSilent(req);
    ok(r.accessToken !== msalToken(API), `not the service token for ${JSON.stringify(req)}`);
    eq(tokenClaims(r.accessToken).scp, OIDC_SCOPES.join(' '), 'a token for the OIDC scopes');
    eq(r.scopes, OIDC_SCOPES, 'the scopes the answer names');
  }
});

test('the stand-in records every request, with its scopes and account', async () => {
  const lib = msalStandIn();
  const app = lib.ready();
  await app.acquireTokenSilent({ scopes: API, account: ACCOUNT });
  await app.acquireTokenRedirect({ scopes: API, account: ACCOUNT });
  await app.loginRedirect({ scopes: API, prompt: 'select_account' });
  eq(lib.log.requests.map(r => [r.call, r.scopes]), [['acquireTokenSilent', API], ['acquireTokenRedirect', API],
    ['loginRedirect', API]], 'the requests');
});

test('a silent failure the test asks for is refused with that code', async () => {
  const lib = msalStandIn({ silentFails: 'interaction_required' });
  const e = await refusal(() => lib.ready().acquireTokenSilent({ scopes: API, account: ACCOUNT }));
  eq(e && e.errorCode, 'interaction_required', 'the code');
});

/* ---------- the proof the item asked for ---------- */

test('a page store read that asks with no scope fails through the stand-in, even with no guard in help.js', async () => {
  // waves.html's getToken, lifted, with the scope default taken out and the
  // library called directly - the shape the page had before TOKEN-SCOPE-1.
  const lib = msalStandIn();
  const ctx = vm.createContext({ cfg: { apiAppId: 'api-app' }, account: ACCOUNT, msalApp: lib.ready() });
  const unguarded = extract('waves.html', 'getToken')
    .replace(/^async function \w+/, 'async function')
    .replace(/scopes \|\| \[`api:\/\/\$\{cfg\.apiAppId\}\/access_as_user`\]/, 'scopes')
    .replace(/return VmfHelp\.tokenOrRedirect\(msalApp, req\);/, 'return (await msalApp.acquireTokenSilent(req)).accessToken;');
  ok(!/tokenOrRedirect|access_as_user/.test(unguarded), 'the scope default and the guard are both gone');
  const getToken = vm.runInContext(`(${unguarded})`, ctx);
  const token = await getToken();
  ok(token !== msalToken(API), 'the store read did NOT get the service token');
});

/* ---------- one stand-in, not one per file ---------- */

test('no other test file builds its own stand-in for the library', () => {
  // A stand-in of its own is how TOKEN-SCOPE-1 passed: it gave a token to
  // anything. A method DEFINED in a test is a stand-in: `name: ...`, a quoted
  // key `'name': ...`, `name(...) {`, or an assignment `x.name = ...` or
  // `const name = ...` (the review of MSAL-FAKE-STRICT-1 found the last three
  // got past the first version). A call (`.name(`) is not.
  const DIR = __dirname;
  const NAMES = 'acquireTokenSilent|acquireTokenRedirect|acquireTokenPopup|loginRedirect|loginPopup|logoutPopup|logoutRedirect|getAllAccounts|getAccount|getActiveAccount|setActiveAccount|handleRedirectPromise|ssoSilent';
  const defined = new RegExp(`(?<![.\\w$])(?:async\\s+)?['"]?(${NAMES})['"]?\\s*(?::|\\([^)]*\\)\\s*\\{)`);
  const assigned = new RegExp(`(?<![\\w$])(${NAMES})\\s*=(?![=>])`);
  const found = [];
  for (const file of fs.readdirSync(DIR).filter(f => f.endsWith('.js') && f !== '_harness.js')) {
    fs.readFileSync(path.join(DIR, file), 'utf8').split('\n').forEach((line, i) => {
      const m = line.match(defined) || line.match(assigned);
      if (m) { found.push(`${file}:${i + 1} ${m[1]}`); }
    });
  }
  eq(found, [], 'library methods defined outside _harness.js');
});

run('msal-stand-in');
