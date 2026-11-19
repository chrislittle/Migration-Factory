/* COUNT-1: a count read from the store is not a number until it is made one.
 *
 * Every string on the Reports page goes through esc(). The counts deliberately
 * do not, on the reasoning that arithmetic yields a number. It does not:
 *
 *   - `??` replaces only null and undefined, so a STRING survives it
 *   - `'<img ...>' + 0` is concatenation, not addition
 *
 * so a stateCounts value that is not a number reached
 * `<td class="num">${x.migrated}</td>` as markup, on a page whose CSP allows
 * inline script and where the access token lives in sessionStorage. Nothing on
 * the way in enforces the schema - run-status.schema.json says these are
 * integers and the browser never checks.
 *
 * This is the scan's F28, which the usage limit stopped the panel from ever
 * judging, and which a second researcher raised independently.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const num = lift('reports.html', 'num');

test('a hostile string becomes a number, not markup', () => {
  eq(num('<img src=x onerror=alert(1)>'), 0, 'script payload');
  eq(num('</td><script>x()</script>'), 0, 'tag-breaking payload');
});

test('and the arithmetic that follows cannot concatenate', () => {
  /* The actual defect was `(counts.MIGRATED ?? 0) + (counts.SKIPPED ?? 0)`.
   * With one side a string that is addition in name only. */
  const hostile = '<img src=x onerror=alert(1)>';
  eq((hostile ?? 0) + 0, hostile + '0', 'the old expression really did concatenate');
  eq(num(hostile) + num(0), 0, 'the new one cannot');
});

test('real counts still count', () => {
  eq(num(0), 0, 'zero');
  eq(num(7), 7, 'a number');
  eq(num('7'), 7, 'a numeric string, which the store may legitimately hold');
  eq(num(12) + num(3), 15, 'addition is still addition');
});

test('the empty cases a store document really produces are zero, not NaN', () => {
  /* NaN would render the word "NaN" in a column an operator reads as a count
   * of machines - wrong in a quieter way than markup, and just as misleading. */
  eq(num(undefined), 0, 'missing key');
  eq(num(null), 0, 'null');
  eq(num(''), 0, 'empty string');
  eq(num('not a number'), 0, 'text');
  eq(num({}), 0, 'an object');
  eq(num([1, 2]), 0, 'an array of several');
});

test('infinities are not counts either', () => {
  eq(num(Infinity), 0, 'Infinity');
  eq(num(-Infinity), 0, '-Infinity');
  eq(num('1e400'), 0, 'a number too large to represent');
});

test('a negative count is passed through rather than invented away', () => {
  /* Not clamped on purpose. A negative here means the ENGINE wrote something
   * wrong, and showing -1 is how somebody finds that out; silently rendering 0
   * would hide a real fault in the state store. */
  eq(num(-3), -3, 'negative');
});

run('report-counts');
