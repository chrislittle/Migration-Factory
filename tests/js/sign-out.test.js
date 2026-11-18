/* SIGNOUT-1: Sign out must end the session, including on the no-role gate.
 *
 * signOut() reached MSAL only through `adapter`, which install() sets. On
 * migrations.html, reports.html and wizard.html, gateOnRole() runs BEFORE
 * install() and returns early for somebody with no role - so on exactly the
 * screen whose Sign out button is the documented way back out, `adapter` was
 * null, `app` was falsy, the logout branch was skipped, NO exception was
 * raised, and therefore the sessionStorage fallback in the catch never ran
 * either. The page reloaded into the same gate, still signed in.
 *
 * That is a shared-computer problem: almost everybody who lands on that gate
 * is signed in as the wrong account - it is the whole reason to have a second
 * identity - and the token cache plus the Entra session cookie both survived
 * for the next person at that browser.
 *
 * NO-POPUPS-SIGNOUT-1: sign-out leaves the page by REDIRECT, the way POPUP-3
 * took sign-in and every token request. It used logoutPopup, the last window
 * the product opened; where the browser blocks windows it failed, and only
 * the local token cache was cleared - the Entra session stayed open.
 *
 * A redirect does not return to the code that started it. The library's
 * promise settles while the browser is already leaving, so a reload after it
 * would stop the trip to Microsoft. These RUN it.
 */
'use strict';
const { lift, test, eq, ok, run, msalStandIn } = require('./_harness');

const signOut = lift('help.js', 'signOut');

/* The shared stand-in for the library (MSAL-FAKE-STRICT-1, _harness.js), ready
 * to use. `calls` is each request sign-out sent to logoutRedirect, and
 * `popups` each call to any pop-up. */
function fakeApp(accounts, more) {
  const lib = msalStandIn({ accounts, ...(more || {}) });
  const app = lib.ready();
  Object.defineProperty(app, 'calls', { get: () => lib.log.requests.filter(r => r.call === 'logoutRedirect').map(r => r.request) });
  Object.defineProperty(app, 'popups', { get: () => lib.log.requests.filter(r => /Popup$/.test(r.call)) });
  return app;
}

/** Install the globals signOut closes over, and record what it did. */
function install({ adapter = null, gateMsal = null } = {}) {
  const state = { cleared: 0, reloaded: 0 };
  global.adapter = adapter;
  global.gateMsal = gateMsal;
  global.sessionStorage = { clear() { state.cleared++; } };
  global.location = { origin: 'https://dash.example.com', pathname: '/migrations.html', reload() { state.reloaded++; } };
  return state;
}

test('the gate screen signs out through the app gateOnRole was handed', async () => {
  // adapter is null here: this is the page that gated before it installed.
  const app = fakeApp([{ username: 'wrong@contoso.com' }]);
  install({ adapter: null, gateMsal: app });
  await signOut();
  eq(app.calls.length, 1, 'logoutRedirect calls');
  eq(app.calls[0].account.username, 'wrong@contoso.com', 'the account signed out');
});

test('sign-out leaves by redirect, and opens no window', async () => {
  const app = fakeApp([{ username: 'a@contoso.com' }]);
  install({ adapter: { getMsal: () => app } });
  await signOut();
  eq(app.calls.length, 1, 'logoutRedirect calls');
  eq(app.popups.length, 0, 'pop-up calls');
});

test('a sign-out that leaves for Microsoft does not reload the page behind it', async () => {
  /* A reload after the redirect call stops the navigation to Microsoft, and
   * the Entra session survives - the defect this item removes, by another
   * road. */
  const app = fakeApp([{ username: 'a@contoso.com' }]);
  const state = install({ adapter: { getMsal: () => app } });
  await signOut();
  eq(state.reloaded, 0, 'page reloads');
  eq(state.cleared, 0, 'the local fallback is not needed: the library clears its own cache first');
});

test('WITH NO MSAL AT ALL, the token cache is still dropped', async () => {
  /* The exact defect. Before the fix this path raised no exception, so the
   * catch never ran, so nothing was cleared and the person stayed signed in
   * while the page told them nothing. */
  const state = install({ adapter: null, gateMsal: null });
  await signOut();
  eq(state.cleared, 1, 'sessionStorage cleared');
  eq(state.reloaded, 1, 'page reloads');
});

test('a sign-out the library refuses before it leaves still drops the token cache', async () => {
  const app = fakeApp([{ username: 'a@contoso.com' }], { redirectFails: 'interaction_in_progress' });
  const state = install({ adapter: { getMsal: () => app } });
  await signOut();
  eq(state.cleared, 1, 'sessionStorage cleared after a refusal');
  eq(state.reloaded, 1, 'page reloads');
});

test('an app with no signed-in account still drops the token cache', async () => {
  const app = fakeApp([]);
  const state = install({ adapter: { getMsal: () => app } });
  await signOut();
  eq(app.calls.length, 0, 'nothing to log out');
  eq(state.cleared, 1, 'sessionStorage cleared anyway');
  eq(state.reloaded, 1, 'page reloads');
});

test('the installed adapter wins over the gate app when both exist', async () => {
  const installed = fakeApp([{ username: 'installed@contoso.com' }]);
  const gate = fakeApp([{ username: 'gate@contoso.com' }]);
  install({ adapter: { getMsal: () => installed }, gateMsal: gate });
  await signOut();
  eq(installed.calls.length, 1, 'installed adapter used');
  eq(gate.calls.length, 0, 'gate app not used');
});

test('sign out never throws, whatever the browser refuses', async () => {
  // A dead Sign out button is the trap this whole control exists to avoid.
  const state = install({ adapter: null, gateMsal: null });
  global.sessionStorage = { clear() { throw new Error('storage disabled'); } };
  let threw = false;
  try { await signOut(); } catch { threw = true; }
  eq(threw, false, 'signOut threw');
  ok(state.reloaded === 1, 'page still reloads when storage is unavailable');
});

run('sign-out');
