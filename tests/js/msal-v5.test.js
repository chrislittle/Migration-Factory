/* DEPS-CURRENT-1: the sign-in library is MSAL for the browser v5.
 *
 * TWO RULES MOVED WITH THE LIBRARY, AND BOTH ARE RUN HERE, NOT READ.
 *
 * 1. FROM v3, A PAGE WAITS FOR initialize() BEFORE ANY OTHER CALL. Every
 *    other call made earlier throws uninitialized_public_client_application.
 *    The fake below behaves the same way, and its initialize() finishes on a
 *    LATER turn of the event loop, so a page that calls initialize() and does
 *    not wait for it is caught: the next call arrives before it is ready.
 *    Each page's own boot() is lifted out and run, with the page's real
 *    shared helpers where they touch the library.
 *
 * 2. A REDIRECT RETURNS ONLY TO A REGISTERED ADDRESS. Entra sends the browser
 *    back only to an address the app registration lists - each page, with no
 *    query (infra/identity.bicep). NO-POPUPS-SIGNOUT-1 took sign-out to a
 *    redirect (logoutRedirect), so it is held to the same address as sign-in.
 *    The library's pop-up and its redirect bridge are gone with it: from v4
 *    "Redirect-based flows (acquireTokenRedirect / loginRedirect) will still
 *    complete" with no bridge, and for logoutRedirect the bridge is optional
 *    (lib/msal-browser/docs/v4-migration.md, Microsoft's library repository).
 *
 * Neither proves a sign-in works. Only a real install can, and that test is
 * owed (the item says so); these prove the page keeps the library's rules.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { extract, lift, test, eq, ok, run, msalStandIn } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const read = (f) => pageSource(path.join(DASH, f));
const HELP = read('help.js');

// Every page that builds the library's application object. Found, not listed,
// so a new page that signs in is held to the same rule.
const PAGES = fs.readdirSync(DASH)
  .filter(f => f.endsWith('.html'))
  .filter(f => /new msal\.PublicClientApplication\(/.test(read(f)))
  .sort();

/* The library is the shared stand-in (MSAL-FAKE-STRICT-1, _harness.js): it
 * refuses every call made before initialize() has finished, a silent request
 * with no account, and gives a token only for the scope asked for. */

/* A stand-in for anything the boot touches that is not the library: callable,
 * and every property is another stand-in. Not a promise: `then` is absent. */
function anything() {
  const target = function () { };
  const proxy = new Proxy(target, {
    get: (t, key) => {
      if (key === 'then') { return undefined; }
      if (key === Symbol.toPrimitive) { return () => ''; }
      if (key === 'length') { return 0; }
      return proxy;
    },
    set: () => true,
    apply: () => proxy,
    construct: () => proxy,
  });
  return proxy;
}

function store() {
  const map = new Map();
  return {
    getItem: (k) => (map.has(k) ? map.get(k) : null),
    setItem: (k, v) => map.set(k, String(v)),
    removeItem: (k) => map.delete(k),
    clear: () => map.clear(),
  };
}

/** Run one page's boot() as a signed-in load, and say what the library saw. */
async function bootLive(page) {
  const lib = msalStandIn();
  const log = lib.log;
  const key = (HELP.match(/const INTERACTIVE_TRIED = '([^']+)'/) || [])[1];
  const sandbox = {
    console,
    setTimeout, clearTimeout,
    DEMO_MODE: false,
    INTERACTIVE_TRIED: key,
    cfg: null, msalApp: null, account: null,
    msal: lib,
    sessionStorage: store(),
    localStorage: store(),
    location: { origin: 'https://dash.example.com', pathname: `/${page}`, search: '', hash: '',
      href: `https://dash.example.com/${page}`, reload() { }, assign() { }, replace() { } },
    fetch: async () => ({ ok: true, status: 200,
      json: async () => ({ clientId: 'client', tenantId: 'tenant', apiAppId: 'api', apiBaseUrl: 'https://api.example.com' }) }),
  };
  sandbox.window = sandbox;
  const ctx = vm.createContext(sandbox);
  // The real shared helpers the boot hands the library to.
  const accountsAfterReturn = vm.runInContext(`(${extract('help.js', 'accountsAfterReturn').replace(/^async function \w+/, 'async function')})`, ctx);
  const signInRedirect = vm.runInContext(`(${extract('help.js', 'signInRedirect').replace(/^async function \w+/, 'async function')})`, ctx);
  sandbox.VmfHelp = new Proxy({ checkedConfig: (c) => c, accountsAfterReturn, signInRedirect }, {
    get: (t, k) => (k in t ? t[k] : anything()),
  });
  const bootText = extract(page, 'boot');
  // Every other name the boot reads is a stand-in, unless the context already
  // has it (a JavaScript built-in) or it is set above.
  for (const name of new Set(bootText.match(/(?<![\w$.])[A-Za-z_$][\w$]*/g))) {
    if (!(name in sandbox) && vm.runInContext(`typeof globalThis[${JSON.stringify(name)}]`, ctx) === 'undefined') {
      sandbox[name] = anything();
    }
  }
  const boot = vm.runInContext(`(${bootText.replace(/^async function \w+/, 'async function')})`, ctx);
  let failure = null;
  try { await boot(); } catch (e) { failure = e; }
  await new Promise(r => setTimeout(r, 20));
  return { log, failure };
}

test('found the pages that sign in', () => {
  ok(PAGES.length >= 8, `pages that build the library object: ${PAGES.join(', ')}`);
});

for (const page of PAGES) {
  test(`${page}: waits for initialize() before any other call to the library`, async () => {
    const { log, failure } = await bootLive(page);
    eq(log.calls.slice(0, 2), ['construct', 'initialize'], 'the first two things the library sees');
    eq(log.early, [], 'calls made before initialize() had finished');
    ok(log.calls.includes('handleRedirectPromise'), 'the boot went on to take the account a redirect brings back');
    ok(!failure || !/uninitialized/.test(String(failure.message)), `the boot failed: ${failure && failure.message}`);
  });
}

// The stand-in's own refusals are proved in msal-stand-in.test.js.

/* ---------- sign-out returns to a registered address ---------- */

test('sign-out sends the browser back to this page with no query, which is a registered address', async () => {
  // Left to the library, the address after sign-out is the full current
  // address, query and all, and Entra returns only to an address the app
  // registration lists - each page, with no query (infra/identity.bicep).
  const signOut = lift('help.js', 'signOut');
  const lib = msalStandIn({ accounts: [{ username: 'a@example.com', homeAccountId: 'home-a' }] });
  const app = lib.ready();
  global.adapter = { getMsal: () => app };
  global.gateMsal = null;
  global.sessionStorage = { clear() { } };
  global.location = { origin: 'https://dash.example.com', pathname: '/waves.html', search: '?run=p%2Fr', href: 'https://dash.example.com/waves.html?run=p%2Fr', reload() { } };
  await signOut();
  const calls = lib.log.requests.filter(r => r.call === 'logoutRedirect').map(r => r.request);
  eq(calls.length, 1, 'logoutRedirect calls');
  eq(calls[0].postLogoutRedirectUri, 'https://dash.example.com/waves.html', 'the address the browser returns to');
  eq(calls[0].account.username, 'a@example.com', 'the account signed out');
});

test('no page and no shared script asks for the library\'s pop-up window, or the bridge that answered it', () => {
  // The pop-up's helper and its line are gone with the pop-up.
  ok(!/function relaySignInWindow/.test(HELP), 'help.js still has relaySignInWindow');
  ok(!/signOutWindow:/.test(HELP), 'help.js still declares the pop-up line');
  for (const page of PAGES) {
    ok(!/relaySignInWindow|msalRedirectBridge/.test(read(page)), `${page} still asks the pop-up helper or the bridge`);
  }
});

run('msal-v5');