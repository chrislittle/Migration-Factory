/* CONFIG-HOST-1: where the dashboard is allowed to send an access token.
 *
 * cfg.apiUrl decides that, and it comes from a file beside the pages. The
 * shipped sample of that file used to pre-fill it with an example address on a
 * host nobody owned - while every other field was an obvious row of zeroes. It
 * was the one field that looked already filled in.
 *
 * The sample is empty now. This is the other half: a token must not leave over
 * a connection that is not encrypted, and a refused address must leave the app
 * in its existing read-only state rather than half-working.
 *
 * What this CANNOT check, and no code can: whether the address is the RIGHT
 * one. The facade belongs to the customer and only they know its name.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const tokenMayGoTo = lift('help.js', 'tokenMayGoTo');
const checkedConfig = lift('help.js', 'checkedConfig');

// The lifted functions reach for the page's own location and a module-level
// note the harness cannot see.
global.location = { href: 'https://dash.example.com/migrations.html' };
global.configRefusal = null;
global.tokenMayGoTo = tokenMayGoTo;

const cfgWith = (apiUrl) => ({ tenantId: 't', clientId: 'c', apiAppId: 'a', refreshSeconds: 15, apiUrl });

test('https is where a token may go', () => {
  ok(tokenMayGoTo('https://vmf-facade-prod.azurewebsites.net/api'), 'a real facade');
  ok(tokenMayGoTo('https://api.contoso.com/vmf'), 'a custom name');
});

test('plain http is not, wherever it points', () => {
  eq(tokenMayGoTo('http://vmf-facade-prod.azurewebsites.net/api'), false, 'a host on the internet');
  eq(tokenMayGoTo('http://10.0.0.4/api'), false, 'a private address is still cleartext on the wire');
});

test('http on the operator own machine is allowed', () => {
  /* The one carve-out, and it is the browser's own rule: a page served from
   * localhost counts as a secure context. Refusing it would break running the
   * service beside the pages while somebody works on it, with no way to say
   * why. */
  ok(tokenMayGoTo('http://localhost:7071/api'), 'localhost');
  ok(tokenMayGoTo('http://127.0.0.1:7071/api'), 'by number');
});

test('anything that is not a web address at all is refused', () => {
  for (const bad of ['', null, undefined, 'file:///c:/api', 'javascript:alert(1)', 'ftp://host/api', '::::']) {
    eq(tokenMayGoTo(bad), false, `refused: ${String(bad)}`);
  }
});

test('an address that is not written out in full is refused', () => {
  /* The facade is always named in full. Judging a half-written address
   * against the page's own instead turns every piece of rubbish into a
   * same-origin path that passes - an empty string becomes the page itself,
   * and the word "null" becomes a page called null. */
  for (const half of ['/api', 'api', '//vmf-facade-prod.azurewebsites.net/api', 'null']) {
    eq(tokenMayGoTo(half), false, `refused: ${half}`);
  }
});

test('a refused address is EMPTIED, not corrected', () => {
  /* Repairing it would mean guessing what the operator meant, and the guess
   * is a host that receives a token. The pages already draw no action controls
   * without an address, so emptying lands them in a state they already have. */
  const out = checkedConfig(cfgWith('http://vmf-facade-prod.azurewebsites.net/api'));
  eq(out.apiUrl, '', 'the address is gone');
  eq(out.apiAppId, 'a', 'and the rest of the configuration is untouched');
  eq(out.tenantId, 't', 'including what sign-in needs');
});

test('a good address is passed through unchanged', () => {
  const cfg = cfgWith('https://vmf-facade-prod.azurewebsites.net/api');
  eq(checkedConfig(cfg).apiUrl, 'https://vmf-facade-prod.azurewebsites.net/api', 'kept');
});

test('an empty address is left empty, and says nothing extra', () => {
  // The supported state when no service is deployed. It is not a refusal, so
  // it must not be reported as one.
  global.configRefusal = 'stale';
  const out = checkedConfig(cfgWith(''));
  eq(out.apiUrl, '', 'still empty');
  eq(global.configRefusal, null, 'and nothing is claimed about it');
});

test('the refusal says which one it was, and is cleared by a later good read', () => {
  checkedConfig(cfgWith('http://elsewhere/api'));
  ok(String(global.configRefusal).includes('https'), 'it names the reason');
  checkedConfig(cfgWith('https://good/api'));
  eq(global.configRefusal, null, 'a later good configuration does not keep reporting the old one');
});

test('no configuration at all does not throw', () => {
  eq(checkedConfig(null), null, 'null');
  eq(checkedConfig(undefined), undefined, 'undefined');
});

test('the SHIPPED sample names no host at all', () => {
  /* The defect itself. A sample that pre-fills a hostname hands anybody who
   * registers that name an access token for the customer's own service - and
   * the name in there was not registered. Nothing we ship may carry one. */
  const sample = JSON.parse(pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'dashboard.sample.config.json')));
  eq(sample.apiUrl, '', 'the address is a blank to fill in');
  const text = JSON.stringify(sample);
  eq(/azurewebsites\.net/.test(text), false, 'and no azure host is named anywhere in it');
  eq(/https?:\/\//.test(text.replace(/"comment":"[^"]*"/, '')), false,
    'nor any other address outside the note that explains the file');
});

run('config-host');
