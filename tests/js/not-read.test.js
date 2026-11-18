/* REPORT-GAP-1: a report must say what the scan could not read.
 *
 * A scan that carries on with less than it asked for is CORRECT - it must not
 * guess, and it must not turn a machine away over something it could not read.
 * What was wrong is that it then said nothing: the value was dropped, a line
 * went into the run log, and the report simply omitted the subject. A customer
 * read an assessment with a hole in it and no way to know the hole was there.
 *
 * Same defect as the drift checker that reported "changed" when it meant "I
 * could not look" - a result presented without saying what it could not
 * measure.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const notReadHtml = lift('assessment-report.js', 'notReadHtml');

// The lifted function closes over the module's strings, its style guard and
// its escaper.
global.T = {
  couldNotRead: 'What this scan could not read',
  couldNotReadWhy: 'The scan finished without these. Everything else here is not affected.',
  notReadUnknown: 'The scan could not read this: {subject}',
};
global.NOT_READ_WORDS = {
  acceleratedNetworking: 'Accelerated networking. This report does not say whether it is on for any machine.',
};
global.ensureStyles = () => {};
global.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => (
  { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

test('a scan that read everything says nothing at all', () => {
  /* Empty string, not an empty heading: a section titled "what this scan could
   * not read" with nothing under it makes a clean scan look suspicious. */
  eq(notReadHtml([]), '', 'empty list');
  eq(notReadHtml(null), '', 'no field at all - an older assessment');
  eq(notReadHtml(undefined), '', 'undefined');
});

test('a known subject is named in the page own words, not the log own words', () => {
  const html = notReadHtml([{ subject: 'acceleratedNetworking', detail: 'HTTP 403 from the network provider' }]);
  ok(html.indexOf('What this scan could not read') >= 0, 'the heading');
  ok(html.indexOf('Accelerated networking') >= 0, 'the subject in readable words');
  ok(html.indexOf('403') < 0, 'the engine exception is NOT put in front of a customer');
});

test('an unknown subject still says something true', () => {
  // A subject added to the engine with no wording here must not vanish - a
  // silent omission is the whole defect being fixed.
  const html = notReadHtml([{ subject: 'somethingNew' }]);
  ok(html.indexOf('somethingNew') >= 0, 'the subject is named');
  ok(html.indexOf('could not read this') >= 0, 'and framed');
});

test('a subject that names a prototype member does not leak a function', () => {
  /* A bare NOT_READ_WORDS[key] returns Object.prototype members for
   * `constructor` and `__proto__`, which are truthy - the page would render a
   * function definition into a customer report. */
  for (const key of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
    const html = notReadHtml([{ subject: key }]);
    ok(html.indexOf('function') < 0, `${key} did not leak a function`);
    ok(html.indexOf('could not read this') >= 0, `${key} fell back to the unknown wording`);
  }
});

test('the subject is escaped before it reaches the page', () => {
  const html = notReadHtml([{ subject: '<img src=x onerror=alert(1)>' }]);
  ok(html.indexOf('<img') < 0, 'no raw tag');
  ok(html.indexOf('&lt;img') >= 0, 'escaped instead');
});

test('rubbish entries are dropped rather than rendered blank', () => {
  eq(notReadHtml([null, undefined, {}, { detail: 'no subject' }]), '', 'nothing worth showing');
  const html = notReadHtml([null, { subject: 'acceleratedNetworking' }]);
  ok(html.indexOf('Accelerated networking') >= 0, 'and a good entry beside rubbish still shows');
});

test('several subjects all appear', () => {
  const html = notReadHtml([{ subject: 'acceleratedNetworking' }, { subject: 'somethingNew' }]);
  ok(html.indexOf('Accelerated networking') >= 0, 'first');
  ok(html.indexOf('somethingNew') >= 0, 'second');
});

run('not-read');
