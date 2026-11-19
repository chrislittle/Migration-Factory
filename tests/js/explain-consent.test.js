/* CONSENT-UX-1: what a person is told when the directory refuses.
 *
 * The Admin page asks Microsoft Entra to read the directory and to give and
 * remove roles. Entra reserves those for a directory administrator - no user
 * can approve them for themselves, in any tenant. Somebody who cannot get that
 * approval saw the bare word `access_denied` in a red bar and nothing else,
 * with no way of knowing that every other page still worked.
 *
 * THE RULES ARE TAKEN FROM help.js ITSELF rather than copied here. FAILURES is
 * an array of regular expressions and sentences, not a function, so `lift`
 * cannot reach it: the slice of source that defines it is evaluated instead.
 * A copy would be a second set of rules that agrees with the first until
 * somebody edits one.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));

const START = 'const ROLE_WORDS';
const END = 'function explainAction(err) { return explainWith(err, true); }';
const from = HELP.indexOf(START);
const to = HELP.indexOf(END);
const slice = (from >= 0 && to > from) ? HELP.slice(from, to + END.length) : '';

// eslint-disable-next-line no-eval
const rules = slice ? eval(`(function () { ${slice}; return { explain, explainAction }; })()`) : null;

test('the rules were found in help.js, or nothing below proves anything', () => {
  ok(from >= 0, 'the start marker moved');
  ok(to > from, 'the end marker moved');
  ok(slice.length > 500, 'the slice is too small to be the rules');
  ok(rules && typeof rules.explain === 'function', 'explain was not produced');
});

test('a directory refusal says what it is and that it is one page', () => {
  // THE BUG: this returned the string "access_denied" and stopped.
  const said = rules.explain(new Error('access_denied'));
  ok(!/access_denied/.test(said), 'the raw code must not be what a person reads');
  ok(/administrator/i.test(said), 'it names who can fix it');
  ok(/other page/i.test(said), 'and says the rest of the product still works');
});

test('the other shapes Entra uses for the same refusal are covered', () => {
  for (const code of ['consent_required', 'AADSTS65001', 'AADSTS90094']) {
    const said = rules.explain(new Error(`${code}: something`));
    ok(/administrator/i.test(said), `${code} should reach the consent answer`);
  }
});

test('it does not claim which cause, because access_denied has two', () => {
  // A person who closes the sign-in window without finishing gets the same
  // code. The wording has to hold for both.
  const said = rules.explain(new Error('access_denied'));
  ok(/try again/i.test(said), 'the closed-sign-in case is covered too');
});

test('asking twice in one session is explained, not left silent', () => {
  // The one-ask guard stops a refused redirect bouncing for ever. Without a
  // sentence, the second press of the button did nothing visible.
  const said = rules.explain(new Error('vmf_asked_already: asked once already in this session'));
  ok(!/vmf_asked_already/.test(said), 'the raw marker must not reach a person');
  ok(/already asked|already/i.test(said), 'it says the question was asked');
  ok(/sign out/i.test(said), 'and how to try again');
});

test('a page that is not a registered sign-in address says so', () => {
  const said = rules.explain(new Error('AADSTS50011: The redirect URI specified does not match'));
  // MANUAL-REVIEW-1: in the words of Microsoft Entra ID, with no guessed cause.
  ok(/does not accept this page as a sign-in address/i.test(said), 'it names the real problem');
  ok(/install/i.test(said), 'and what fixes it');
  ok(!/AADSTS/.test(said), 'not the Azure code');
});

test('the role refusal still wins for a role-shaped answer', () => {
  // The consent rules are FIRST in the list. This proves they did not swallow
  // the one that was already there.
  const said = rules.explainAction(new Error('403: requires one of [Vmf.Operator], holds [Vmf.Viewer]'));
  ok(/Operator/.test(said), 'it still names the role needed');
  ok(/Viewer/.test(said), 'and the role held');
});

test('SIGN-IN-MSG-1: a 401 on a READ says sign in, not "you have no role"', () => {
  // THE BUG: the role rule matched `HTTP 40[13]`, which includes 401, and sat
  // ABOVE the 401 rule - whose own comment said it should come first. So a
  // rejected sign-in was reported as a missing role, on every page.
  const said = rules.explain(new Error('HTTP 401'));
  ok(/sign in again/i.test(said), 'it is a sign-in');
  ok(!/have not been given a role/i.test(said), 'and NOT a role');
});

test('SIGN-IN-MSG-1: a 403 on a read still says role', () => {
  const said = rules.explain(new Error('HTTP 403'));
  ok(/have not been given a role/i.test(said), 'that rule still works');
});

test('SIGN-IN-MSG-1: the front door refusing is neither of those', () => {
  // App Service refuses before any product code runs and answers in its own
  // words. Reading that as a role refusal sent an administrator holding
  // Vmf.Admin looking for a role he already had, for hours.
  const said = rules.explain(new Error('You do not have permission to view this directory or page.'));
  ok(/refused this call before/i.test(said), 'it names what happened');
  ok(/not about your role/i.test(said), 'and says what it is not');
  // HELP-JS-RULE12-1: it said to run a tool script, and every action is
  // reachable from the app (hard rule 12). The measured cause is the sign-in
  // settings on the service (EASYAUTH-403-1), and the install sets them.
  ok(/sign-in settings on the service/i.test(said), 'it names the cause');
  ok(/install the product again/i.test(said), 'and the action that sets them');
  ok(!/\.ps1|-Vmf/.test(said), 'and sends nobody to a script or a command');
});

test('an expired sign-in still says sign in again', () => {
  const said = rules.explain(new Error('401 Unauthorized'));
  ok(/sign in again/i.test(said), 'order through the list is unchanged');
});

test('something nobody has a rule for is still passed through', () => {
  // The fall-through is what let `access_denied` reach the screen. It is still
  // right for anything genuinely unknown - a raw message beats a wrong guess.
  const said = rules.explain(new Error('a thing nobody planned for'));
  eq(said, 'a thing nobody planned for', 'unchanged');
});

run('explain-consent');
