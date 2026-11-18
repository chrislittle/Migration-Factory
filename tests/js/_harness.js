/* A zero-dependency test harness for the dashboard's JavaScript.
 *
 * WHY THIS EXISTS. The dashboard is several thousand lines of JavaScript and
 * every test of it was a GREP - does this page contain that string. Those
 * catch a control that was deleted; they cannot catch one that is wired
 * wrongly, and this project has now shipped three defects of exactly that
 * shape: a key read from the wrong object (undefined at runtime, no error), a
 * gate that read the first truthy field of an MSAL error and so never saw the
 * code that mattered, and a page-hiding block that reported hidden:true while
 * the computed style stayed display:block.
 *
 * Reading source tells you what you meant. Only running it tells you what
 * happens.
 *
 * NO DEPENDENCIES AND NO INSTALL. Node is already on both CI runner images, so
 * this costs one step and nothing else. Functions are lifted out of the page
 * with a regex and eval'd - crude, and the honest alternative was a build step
 * for a product that deliberately has none.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');

const REPO = path.join(__dirname, '..', '..');
let passed = 0;
const failures = [];

/** The text of a named function, as the page wrote it. */
function extract(file, name) {
  const src = pageSource(path.join(REPO, 'src', 'dashboard', file));
  // Matches `async function name(...) {` or `function name(...) {` and takes
  // everything to the closing brace at the same indentation.
  const re = new RegExp(
    `(?:^|\\n)(\\s*)(?:async\\s+)?function ${name}\\s*\\([\\s\\S]*?\\n\\1\\}`);
  const m = src.match(re);
  if (!m) { throw new Error(`could not lift ${name} from ${file}`); }
  return m[0].trim();
}

/** Lift a named function out of a dashboard file so it can be called. */
function lift(file, name) {
  const body = extract(file, name);
  const isAsync = /^async\b/.test(body);
  const arrowless = body.replace(/^(async\s+)?function\s+\w+/, isAsync ? 'async function' : 'function');
  // eslint-disable-next-line no-eval
  return eval(`(${arrowless})`);
}

/* Lift several functions into ONE scope, so the ones that call each other
 * still can. `lift` evaluates a function alone, which is right for a function
 * that stands alone and wrong for a small family of them - and a family is
 * exactly what a rule written down once looks like. */
function liftAll(file, names) {
  const bodies = names.map(n => extract(file, n)).join('\n');
  // eslint-disable-next-line no-eval
  return eval(`(function () { ${bodies}\nreturn { ${names.join(', ')} }; })()`);
}

/* The VALUE of a top-level `const NAME = ...;`, evaluated.
 *
 * BLOCKED-NAME-1: a label test that supplies its own copy of the label table
 * proves the test's table, not the page's - and the page is what an operator
 * reads. The two tables that decide what the activity feed says are plain
 * literals at column 0, so they can be taken as written and evaluated beside
 * the function that reads them. */
function liftConst(file, name) {
  const src = pageSource(path.join(REPO, 'src', 'dashboard', file));
  const re = new RegExp(`(?:^|\\n)const ${name} = ([\\s\\S]*?\\n(?:\\]|\\}));`);
  const m = src.match(re);
  if (!m) { throw new Error(`could not lift const ${name} from ${file}`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[1]})`);
}

/* TEST-JS-TIMER-HANG-1: A TEST HAS A TIME LIMIT, AND THE FAILURE NAMES IT. The
 * beforeExit guard below comes only when node has nothing left to do; a test
 * that waits forever while a timer repeats (a page's poll, a setInterval)
 * keeps node busy and never gets there. So each test races a timer, and a test
 * past it fails with "did not end in N seconds" and the run goes on. A test
 * that ends after that is not counted again: the race already settled.
 * The timer is unref'd: it never keeps node running by itself, so a test with
 * nothing left to wait for still ends at once through beforeExit.
 * Measured 2026-11-07: the slowest test took about 1 second. The runner's
 * limit for a whole file (tools/Invoke-VmfJsTests.ps1) is longer, so this line,
 * which names the test, comes first. testLimit(seconds) sets it for a file. */
let testLimitMs = 60 * 1000;
function testLimit(seconds) { testLimitMs = seconds * 1000; }
// Node's own timers: several files put a fake setTimeout on the global object
// to control a page's clock, and the limit must not run on that clock.
const nodeTimers = require('timers');

function test(name, fn) {
  const run = async () => {
    const limit = testLimitMs;
    let timer = null;
    const late = new Promise((resolve, reject) => {
      timer = nodeTimers.setTimeout(() => reject(new Error(`did not end in ${limit / 1000} seconds`)), limit);
      timer.unref();
    });
    try {
      await Promise.race([Promise.resolve().then(fn), late]);
      passed++;
    } catch (e) {
      failures.push({ name, message: e && e.message ? e.message : String(e) });
    } finally {
      nodeTimers.clearTimeout(timer);
    }
  };
  run.testName = name;
  pending.push(run);
}

const pending = [];

function eq(got, want, what) {
  const g = JSON.stringify(got), w = JSON.stringify(want);
  if (g !== w) { throw new Error(`${what || 'value'}: got ${g}, wanted ${w}`); }
}

function ok(value, what) {
  if (!value) { throw new Error(`${what || 'value'} was falsy`); }
}

/* TEST-JS-HANG-1: A TEST THAT NEVER FINISHES IS A FAILURE. A test that awaits
 * a promise that never settles, with nothing else waiting (no timer, no
 * socket), leaves node with nothing to do, and node ends with exit code 0
 * before run() prints a word - every failure recorded before it lost. Found by
 * PERF-ONE-LIMIT-1 (a read waiting for a slot nobody gave back) and by
 * QUOTA-FILED-WORDS-1 (a send waiting for a timer the test DOM never fired).
 * So the harness keeps the name of the test running, and 'beforeExit' before
 * run() reached its end says which one and exits 1. A file that never calls
 * run() ran none of its tests, and fails the same way. */
let running = null;
let runLabel = '';
let runCalled = false;
let runEnded = false;

process.on('beforeExit', () => {
  if (runEnded) { return; }
  const total = passed + failures.length;
  if (!runCalled) {
    console.log(`\nthis file never called run(), so none of its ${pending.length} test(s) ran`);
  } else {
    console.log(`\n${runLabel}: the test "${running}" did not finish - node ran out of work while it waited (${passed}/${total} passed before it)`);
  }
  for (const f of failures) { console.log(`  FAIL  ${f.name}\n        ${f.message}`); }
  if (runCalled) { console.log(`  FAIL  ${running}\n        did not finish`); }
  process.exit(1);
});

async function run(label) {
  runCalled = true;
  runLabel = label;
  for (const p of pending) { running = p.testName; await p(); }
  running = null;
  runEnded = true;
  const total = passed + failures.length;
  if (failures.length) {
    console.log(`\n${label}: ${passed}/${total} passed, ${failures.length} FAILED`);
    for (const f of failures) { console.log(`  FAIL  ${f.name}\n        ${f.message}`); }
    process.exit(1);
  }
  console.log(`${label}: ${passed}/${total} passed`);
}

/* ---------- MSAL-FAKE-STRICT-1: ONE stand-in for MSAL for the browser v5 ----------
 *
 * Every test that touches sign-in uses this, and none builds its own. Each
 * test file used to have a stand-in that returned a token for ANY request, so
 * TOKEN-SCOPE-1 (a page asking for a token with no scope) passed every test
 * and failed on an install with 401.
 *
 * It copies the library's rules, read from the pinned library
 * (src/dashboard/msal-browser.min.js, @azure/msal-browser v5.26.0, checked
 * again on v5.28.0 by MSAL-5-28-1 and on v5.29.0 by DRIFT-PINS-2026-11-07) and from Microsoft's pages. msal-stand-in.test.js proves each rule holds.
 *
 * 1. NOTHING BUT initialize() UNTIL initialize() HAS FINISHED.
 *    "The initialize function is asynchronous and must resolve before
 *    invoking other MSAL.js APIs" -
 *    https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/initialization.md
 *    The library refuses with uninitialized_public_client_application
 *    (BrowserAuthError). Its token, redirect, pop-up and sign-out calls
 *    check this and REJECT. Its account reads (getAllAccounts and the
 *    others) do not check, but read a cache that initialize() has not loaded
 *    yet, so the stand-in holds them to the page's rule above and THROWS.
 *    initialize() finishes on a LATER turn of the event loop, so a page that
 *    does not wait for it is caught.
 *
 * 2. A SILENT REQUEST NEEDS AN ACCOUNT. "An application must choose an
 *    account to acquire tokens silently" -
 *    https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/accounts.md
 *    The library takes request.account, else the active account, and with
 *    neither refuses with no_account_error (BrowserAuthError).
 *
 * 3. A REQUEST WITH NO SCOPE IS NOT REFUSED, AND THAT IS THE TRAP. Microsoft's
 *    page says "Scopes are required for all acquireToken* calls" -
 *    https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/acquire-token.md
 *    - but the v5 library does not enforce it. "By default MSAL.js will add
 *    the openid, profile and offline_access scopes to every request" -
 *    https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/resources-and-scopes.md
 *    - and with no other scope its own lookup uses those alone
 *    (`scopes: e.scopes?.length ? e.scopes : [...OIDC]`). "If you request the
 *    OpenID Connect scopes and a token, you get a token to call the UserInfo
 *    endpoint" - https://learn.microsoft.com/en-us/entra/identity-platform/scopes-oidc
 *    That token is for Microsoft Graph, and the service refuses it with 401.
 *    So the stand-in returns a token for the OIDC scopes, the same as the
 *    library: a test sees the wrong token, not an error the real page never
 *    meets.
 *
 * 4. A TOKEN IS FOR THE SCOPE ASKED FOR. Entra issues a token for one
 *    resource, the first one asked for (resources-and-scopes.md, above). The
 *    stand-in gives a DIFFERENT token for each scope, with `aud` and `scp` in
 *    its payload, so a test can see which scope a page asked for
 *    (tokenClaims, msalToken).
 */
const OIDC_SCOPES = ['openid', 'profile', 'offline_access'];
const GRAPH_RESOURCE = 'https://graph.microsoft.com';

function base64Url(obj) {
  return Buffer.from(JSON.stringify(obj)).toString('base64')
    .replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

/** The scopes of a request that name a resource, OIDC scopes left out. */
function resourceScopes(scopes) {
  return (Array.isArray(scopes) ? scopes : [])
    .filter(s => typeof s === 'string' && s.trim() !== '')
    .map(s => s.trim())
    .filter(s => !OIDC_SCOPES.includes(s.toLowerCase()));
}

/** The resource a scope belongs to. A scope with no resource is Graph's. */
function scopeResource(scope) {
  const at = scope.lastIndexOf('/');
  return at > 0 && /^(api:\/\/|https?:\/\/)/.test(scope) ? scope.slice(0, at) : GRAPH_RESOURCE;
}

/** The token the stand-in issues for these scopes: one per resource scope set. */
function msalToken(scopes, claims) {
  const asked = resourceScopes(scopes);
  const aud = asked.length ? scopeResource(asked[0]) : GRAPH_RESOURCE;
  const scp = asked.length ? asked.filter(s => scopeResource(s) === aud).join(' ') : OIDC_SCOPES.join(' ');
  return `${base64Url({ typ: 'JWT', alg: 'none' })}.${base64Url({ aud, scp, ...(claims || {}) })}.stand-in`;
}

/** The payload of a token, as a page would read it. */
function tokenClaims(token) {
  const part = String(token).split('.')[1] || '';
  return JSON.parse(Buffer.from(part.replace(/-/g, '+').replace(/_/g, '/'), 'base64').toString('utf8'));
}

function msalError(code, name) {
  const e = new Error(`${code}: refused by the MSAL stand-in`);
  e.errorCode = code;
  e.name = name || 'BrowserAuthError';
  return e;
}

const STAND_IN_ACCOUNT = { username: 'someone@example.com', homeAccountId: 'home-1', tenantId: 'tenant' };

/* The stand-in. Options:
 *   accounts     the cached accounts (default: one at example.com)
 *   silentFails  an error code every acquireTokenSilent is refused with
 *   returned     what handleRedirectPromise answers (default null)
 *   returnFails  an error code handleRedirectPromise is refused with
 *   popupFails   an error code the pop-up calls are refused with (a blocked
 *                pop-up is popup_window_error in the pinned library)
 *   redirectFails an error code the calls that leave the page by redirect
 *                are refused with, BEFORE they leave (NO-POPUPS-SIGNOUT-1:
 *                for example interaction_in_progress)
 *   claims       more claims for every token's payload (for example roles)
 * Returns { PublicClientApplication, log, ready }. `log` holds `calls` (each
 * method name), `early` (calls before initialize() finished) and `requests`
 * (each request: call, scopes, account, and the request itself). ready(config) is an application
 * that has finished initialize(). */
function msalStandIn(opts) {
  const o = opts || {};
  const accounts = o.accounts !== undefined ? o.accounts : [STAND_IN_ACCOUNT];
  const log = { calls: [], early: [], requests: [] };

  class PublicClientApplication {
    constructor(config) { this.config = config; this.ready = false; this.active = null; log.calls.push('construct'); }
    initialize() {
      log.calls.push('initialize');
      return new Promise(resolve => setTimeout(() => { this.ready = true; resolve(); }, 5));
    }
  }

  const answers = {
    getAllAccounts() { return accounts.slice(); },
    getAccount(filter) {
      const f = filter || {};
      return accounts.find(a => Object.keys(f).every(k => a[k] === f[k])) || null;
    },
    getActiveAccount() { return this.active; },
    setActiveAccount(account) { this.active = account || null; },
    async handleRedirectPromise() {
      if (o.returnFails) { throw msalError(o.returnFails, 'ServerError'); }
      return o.returned || null;
    },
    async acquireTokenSilent(req) {
      const account = req.account || this.active;
      log.requests.push({ call: 'acquireTokenSilent', scopes: req.scopes, account: req.account, request: req });
      if (!account) { throw msalError('no_account_error'); }
      if (o.silentFails) { throw msalError(o.silentFails, 'InteractionRequiredAuthError'); }
      const asked = resourceScopes(req.scopes);
      return { accessToken: msalToken(req.scopes, o.claims), account, scopes: asked.length ? asked : OIDC_SCOPES.slice() };
    },
  };
  // Calls that leave the page. They record the request and settle.
  for (const name of ['acquireTokenRedirect', 'loginRedirect', 'logoutRedirect', 'logoutPopup',
    'acquireTokenPopup', 'loginPopup', 'ssoSilent']) {
    answers[name] = async function (req) {
      log.requests.push({ call: name, scopes: req && req.scopes, account: req && req.account, request: req });
      if (o.popupFails && /Popup$/.test(name)) { throw msalError(o.popupFails, 'BrowserAuthError'); }
      if (o.redirectFails && /Redirect$/.test(name)) { throw msalError(o.redirectFails, 'BrowserAuthError'); }
    };
  }
  const syncCalls = new Set(['getAllAccounts', 'getAccount', 'getActiveAccount', 'setActiveAccount']);
  for (const name of Object.keys(answers)) {
    PublicClientApplication.prototype[name] = function (...callArgs) {
      log.calls.push(name);
      if (!this.ready) {
        log.early.push(name);
        const e = msalError('uninitialized_public_client_application');
        if (syncCalls.has(name)) { throw e; }
        return Promise.reject(e);
      }
      return answers[name].apply(this, callArgs);
    };
  }

  function ready(config) {
    const app = new PublicClientApplication(config || {});
    app.ready = true;
    return app;
  }
  return { PublicClientApplication, log, ready };
}

module.exports = { extract, lift, liftAll, liftConst, test, testLimit, eq, ok, run,
  msalStandIn, msalToken, tokenClaims, OIDC_SCOPES };
