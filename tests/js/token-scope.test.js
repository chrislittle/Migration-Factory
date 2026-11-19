/* TOKEN-SCOPE-1: every token a page asks for names the service's scope.
 *
 * The wizard and the wave editor read the run store through
 * VmfHelp.storeBlob(() => getToken(), ...) - with NO scope. MSAL v2 answered
 * that with the service's token. MSAL v5 (DEPS-CURRENT-1) answers it with a
 * sign-in token, the service refuses it with 401, and the page says "Your
 * sign-in was not accepted". Found on the first install that ran v5, at the
 * wizard's "What we found" step.
 *
 * Run, not read: each page's own getToken() is lifted and called the way its
 * store reads call it, against the shared stand-in for the library
 * (MSAL-FAKE-STRICT-1, _harness.js). Like the library, the stand-in gives a
 * request with no scope a sign-in token, not an error, and gives each scope
 * its own token - so a page that asks for the wrong scope gets the wrong
 * token here too.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { extract, test, eq, ok, run, msalStandIn, msalToken } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const read = (f) => pageSource(path.join(DASH, f));
const API_SCOPE = ['api://api-app/access_as_user'];

// Every page that calls its getToken() with no argument. Found, not listed.
const PAGES = fs.readdirSync(DASH)
  .filter(f => f.endsWith('.html'))
  .filter(f => /async function getToken\(/.test(read(f)) && /getToken\(\)/.test(read(f)))
  .sort();

function storage() {
  const map = new Map();
  return { getItem: (k) => (map.has(k) ? map.get(k) : null), setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k) };
}

function realTokenOrRedirect(ctx) {
  const body = extract('help.js', 'tokenOrRedirect').replace(/^async function \w+/, 'async function');
  return vm.runInContext(`(${body})`, ctx);
}

const ACCOUNT = { username: 'someone@example.com', homeAccountId: 'home-1' };
const asked = (lib) => lib.log.requests.map(r => ({ call: r.call, scopes: r.scopes }));

test('found the pages whose store reads ask for a token with no argument', () => {
  ok(PAGES.includes('wizard.html'), `pages: ${PAGES.join(', ')}`);
  ok(PAGES.includes('waves.html'), `pages: ${PAGES.join(', ')}`);
});

for (const page of PAGES) {
  test(`${page}: getToken() with no argument asks for the service's scope`, async () => {
    const lib = msalStandIn();
    const ctx = vm.createContext({ sessionStorage: storage(), INTERACTIVE_TRIED: 'vmf-tried',
      cfg: { apiAppId: 'api-app' }, account: ACCOUNT, msalApp: lib.ready() });
    ctx.VmfHelp = { tokenOrRedirect: realTokenOrRedirect(ctx) };
    const getToken = vm.runInContext(`(${extract(page, 'getToken').replace(/^async function \w+/, 'async function')})`, ctx);
    const token = await getToken();
    eq(token, msalToken(API_SCOPE), 'the token: the service token, not a sign-in token');
    eq(asked(lib), [{ call: 'acquireTokenSilent', scopes: API_SCOPE }], 'what the library was asked for');
  });
}

test('tokenOrRedirect refuses a request with no scope, and the library never sees it', async () => {
  for (const req of [{ account: ACCOUNT }, { scopes: undefined, account: ACCOUNT }, { scopes: [], account: ACCOUNT }]) {
    const lib = msalStandIn();
    const ctx = vm.createContext({ sessionStorage: storage(), INTERACTIVE_TRIED: 'vmf-tried' });
    const tokenOrRedirect = realTokenOrRedirect(ctx);
    let failure = null;
    let token = null;
    try { token = await tokenOrRedirect(lib.ready(), req); } catch (e) { failure = e; }
    eq(token, null, 'a token handed back');
    ok(failure && /^vmf_no_scope/.test(failure.message), `refused ${JSON.stringify(req)}: ${failure && failure.message}`);
    eq(asked(lib), [], 'calls the library saw');
    eq(ctx.sessionStorage.getItem('vmf-tried'), null, 'no sign-in attempt recorded');
  }
});

test('tokenOrRedirect passes a request with a scope to the library unchanged', async () => {
  const lib = msalStandIn();
  const ctx = vm.createContext({ sessionStorage: storage(), INTERACTIVE_TRIED: 'vmf-tried' });
  const token = await realTokenOrRedirect(ctx)(lib.ready(), { scopes: API_SCOPE, account: ACCOUNT });
  eq(token, msalToken(API_SCOPE), 'the token');
  eq(asked(lib), [{ call: 'acquireTokenSilent', scopes: API_SCOPE }], 'what the library saw');
});

test('VmfHelp.myRoles reads the roles from the service token, asked for with the service scope', async () => {
  // The role gate on every page. A token for another scope has no roles in
  // it, and the stand-in gives one only to the service scope.
  const lib = msalStandIn({ claims: { roles: ['Vmf.Operator'] } });
  const ctx = vm.createContext({ atob: (s) => Buffer.from(s, 'base64').toString('binary') });
  const myRoles = vm.runInContext(`(${extract('help.js', 'myRoles').replace(/^async function \w+/, 'async function')})`, ctx);
  const getToken = async () => { throw new Error('the page getToken is not used when the library is handed over'); };
  const answer = await myRoles({ apiAppId: 'api-app' }, getToken, lib.ready());
  eq(answer, { checked: true, roles: ['Vmf.Operator'] }, 'the answer');
  eq(asked(lib), [{ call: 'acquireTokenSilent', scopes: API_SCOPE }], 'what the library was asked for');
});

run('token-scope');
