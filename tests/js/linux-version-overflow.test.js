/* LINUX-VERSION-OVERFLOW-1: the assessment page names a machine whose facts
 * the scan could not read, says what the product said, and says what to do.
 *
 * The scan holds such a machine (machine-not-read) and records a notRead
 * entry with subject 'machine': the machine's resource ID in scope, and what
 * the product said in detail. The strings are the page's own table, read from
 * the page, so the test proves what an operator reads.
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

const { notReadHtml } = liftAll('assessment-report.js', ['sizesNotReadHtml', 'machineNotReadHtml', 'notReadHtml']);

const machine = {
  subject: 'machine', machineCount: 1,
  scope: '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/virtualMachines/vm-bad',
  detail: 'Value was either too large or too small for an <Int32>.',
};

test('WHICH: the machine is named by its name, and it is held', () => {
  const html = notReadHtml([machine]);
  ok(html.indexOf('Machine vm-bad.') >= 0, 'the machine name, from its resource ID');
  ok(html.indexOf('so the machine is held') >= 0, 'it is held');
  ok(html.indexOf('rg-app') < 0, 'the name, not the whole resource ID');
});

test('WHY: what the product said is shown, escaped', () => {
  const html = notReadHtml([machine]);
  ok(html.indexOf('The product said: Value was either too large') >= 0, 'the words');
  ok(html.indexOf('<Int32>') < 0 && html.indexOf('&lt;Int32&gt;') >= 0, 'escaped');
  ok(notReadHtml([{ ...machine, detail: '' }]).indexOf('The product said') < 0, 'no empty quote');
});

test('HOW TO FIX: a new assessment', () => {
  ok(notReadHtml([machine]).indexOf('Start a new assessment.') >= 0, 'then scan again');
});

test('the line above the list says a machine is held, never that nothing else is affected', () => {
  const html = notReadHtml([machine]);
  ok(html.indexOf('not affected') < 0, 'a held machine IS affected');
  ok(html.indexOf('A machine in this list is held until a new assessment reads it.') >= 0, 'says it is held');
  const both = notReadHtml([machine, { subject: 'sizes', subscriptionId: 's', location: 'centralus', reason: 'other', machineCount: 2 }]);
  ok(both.indexOf('machines of a subscription in this list') >= 0, 'the sizes line when a subscription is in the list too');
  ok(notReadHtml([{ subject: 'clusterHints' }]).indexOf('not affected') >= 0, 'the old line for the old subjects');
});

run('linux-version-overflow');
