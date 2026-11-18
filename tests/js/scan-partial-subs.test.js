/* SCAN-PARTIAL-SUBS-1: the assessment page says which subscription was not
 * read, WHY (Azure's words), and HOW TO FIX it.
 *
 * Since 2026-11-08 the page shows the user why the read failed and how to
 * fix it. The engine records a notRead entry with subject 'sizes' for
 * each subscription and region whose size list it could not read; this page
 * draws it. The strings are the page's own table, read from the page, so the
 * test proves what an operator reads.
 */
'use strict';
const path = require('path');
const { liftAll, test, ok, run } = require('./_harness');
const { pageSource } = require('./_page-source');

const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'assessment-report.js'));
const m = src.match(/\n {2}const T = (\{[\s\S]*?\n {2}\});/);
if (!m) { throw new Error('could not read the string table T from assessment-report.js'); }
// eslint-disable-next-line no-eval
global.T = eval(`(${m[1]})`);
global.NOT_READ_WORDS = {};
global.ensureStyles = () => {};
global.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

const { notReadHtml } = liftAll('assessment-report.js', ['sizesNotReadHtml', 'notReadHtml']);

const SUB = '11111111-2222-3333-4444-555555555555';
const refused = {
  subject: 'sizes', subscriptionId: SUB, location: 'centralus', reason: 'permission',
  statusCode: 403, errorCode: 'AuthorizationFailed', machineCount: 2,
  detail: "The client '<placeholder>' does not have authorization to perform action 'Microsoft.Compute/skus/read'",
  requiredRole: 'VMF Assessment', requiredAction: 'Microsoft.Compute/skus/read', scope: `/subscriptions/${SUB}`,
};

test('WHICH: the subscription and the region are named, with the machines held', () => {
  const html = notReadHtml([refused]);
  ok(html.indexOf(SUB) >= 0, 'the subscription');
  ok(html.indexOf('centralus') >= 0, 'the region');
  ok(html.indexOf('2 machines are held') >= 0, 'how many machines are held');
  ok(notReadHtml([{ ...refused, machineCount: 1 }]).indexOf('1 machine is held') >= 0, 'one machine');
});

test('WHY: Azure own code and words are shown, escaped', () => {
  const html = notReadHtml([refused]);
  ok(html.indexOf('AuthorizationFailed') >= 0, 'the error code');
  ok(html.indexOf('does not have authorization') >= 0, 'Azure words');
  ok(html.indexOf('<placeholder>') < 0 && html.indexOf('&lt;placeholder&gt;') >= 0, 'escaped');
  const twice = notReadHtml([{ ...refused, detail: 'HTTP 403 AuthorizationFailed - no access' }]);
  ok(twice.split('AuthorizationFailed').length === 2, 'a code already in Azure words is said once');
});

test('HOW TO FIX: a refusal names the role and the action from the record, then a new assessment', () => {
  const html = notReadHtml([refused]);
  ok(html.indexOf('VMF Assessment') >= 0, 'the role');
  ok(html.indexOf('Microsoft.Compute/skus/read') >= 0, 'the action');
  ok(html.indexOf('Admin page') >= 0, 'where to give it');
  ok(html.indexOf('new assessment') >= 0, 'then scan again');
  const other = notReadHtml([{ ...refused, requiredRole: 'Another Role' }]);
  ok(other.indexOf('Another Role') >= 0, 'the role comes from the record, not from the page');
});

test('a subscription Azure cannot find, and any other failure, get their own fix - never the role', () => {
  const nf = notReadHtml([{ ...refused, reason: 'subscriptionNotFound', errorCode: 'SubscriptionNotFound' }]);
  ok(nf.indexOf('cannot find this subscription') >= 0, 'not found');
  ok(nf.indexOf('VMF Assessment') < 0, 'no role advice for a subscription that is not there');
  const other = notReadHtml([{ ...refused, reason: 'other', errorCode: null, statusCode: 503, detail: 'HTTP 503 - Service Unavailable' }]);
  ok(other.indexOf('temporary') >= 0, 'says the read was tried again');
  ok(other.indexOf('HTTP 503') >= 0, 'with Azure words');
  ok(other.indexOf('VMF Assessment') < 0, 'never guessed to be a permission');
});

test('the line above the list does not say everything else is not affected when machines are held', () => {
  const held = notReadHtml([refused]);
  ok(held.indexOf('not affected') < 0, 'held machines ARE affected');
  ok(held.indexOf('held until a new assessment') >= 0, 'says they are held');
  const plain = notReadHtml([{ subject: 'clusterHints' }]);
  ok(plain.indexOf('not affected') >= 0, 'the old line for the old subjects');
});

run('scan-partial-subs');
