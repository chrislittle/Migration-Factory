/* CLIENT-ERR-1, 2026-09-09. Owner, after finding two defects by using the
 * Admin page: "why don't we have app insights on my web app?"
 *
 * The answer was that browser telemetry would be data nobody reads - the
 * dashboard is static pages in the CUSTOMER'S subscription, an operator sees
 * the error on screen, and a customer is not going to open Application
 * Insights. Sign-in and every API call are already recorded at the facade.
 *
 * But something WAS missing. A defect in the page produced a browser error
 * that existed only on one screen, and "Report a problem" would not have
 * carried it: the support bundle held everything about the MIGRATION and
 * nothing about the PAGE.
 *
 * So the page remembers its own errors and offers them in the bundle the
 * person already chooses to send and can edit first. These tests are about
 * the rules that make that safe to send.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const recordClientError = lift('help.js', 'recordClientError');

test('records what support needs: when, where and what', () => {
  const list = [];
  recordClientError(list, 25, 'access.html', 'error', 'Boom', 'https://x/y/app.js', 12, 7, 'at f\nat g');
  eq(list.length, 1);
  eq(list[0].kind, 'error');
  eq(list[0].page, 'access.html');
  eq(list[0].message, 'Boom');
  eq(list[0].line, 12);
  eq(list[0].column, 7);
  ok(list[0].atUtc, 'the time it happened');
});

test('the SOURCE is the file, never the address', () => {
  // A page address can carry a run id or a query string. Support needs the
  // file it broke in, not where the person was.
  const list = [];
  recordClientError(list, 25, 'watch.html', 'error', 'x',
    'https://dash.example.com/app.js?run=abc-123-secret', 1, 1, null);
  eq(list[0].source, 'app.js');
});

test('a page left open all day does not grow without end', () => {
  const list = [];
  for (let i = 0; i < 60; i++) {
    recordClientError(list, 25, 'p.html', 'error', 'e' + i, null, null, null, null);
  }
  eq(list.length, 25);
  // The NEWEST are the ones that explain what somebody is reporting.
  eq(list[list.length - 1].message, 'e59');
  eq(list[0].message, 'e35');
});

test('a long message and a long stack are both cut', () => {
  const list = [];
  const long = 'x'.repeat(5000);
  const deep = Array.from({ length: 40 }, (_, i) => 'at frame' + i).join('\n');
  recordClientError(list, 25, 'p.html', 'error', long, null, null, null, deep);
  ok(list[0].message.length <= 500, 'message capped');
  eq(list[0].stack.split('\n').length, 6);
});

test('line 0 is a line number, not a missing one', () => {
  // `col || null` would turn column 0 into null and lose it.
  const list = [];
  recordClientError(list, 25, 'p.html', 'error', 'x', 'a.js', 0, 0, null);
  eq(list[0].line, 0);
  eq(list[0].column, 0);
});

test('nothing to report reads as nothing, not as undefined', () => {
  const list = [];
  recordClientError(list, 25, 'p.html', 'unhandledrejection', null, null, null, null, null);
  eq(list[0].message, '');
  eq(list[0].source, null);
  eq(list[0].stack, null);
  eq(list[0].line, null);
});

run('client-errors');
