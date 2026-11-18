/* TESTPLAN-1 layer 1: every page boots and paints, with no install.
 *
 * WHY. Every defect of this shape has been found by the owner opening the
 * product: a page that threw before it drew anything, a page that drew nothing
 * and swallowed the reason, a page reaching for a service it should not need.
 * 2,900 unit tests caught none of them, because nothing here had ever loaded a
 * page.
 *
 * This runs each page's whole script in demo mode - no subscription, no
 * network, no browser - and asks four things:
 *
 *   1. it runs to the end without throwing
 *   2. it paints something
 *   3. it does not reach the network, because demo mode means it needs none
 *   4. nothing it painted says `undefined` or `[object Object]`
 *
 * The fourth catches a value read from the wrong object where it is drawn
 * RAW - `esc()` is null-safe and renders an absent value as empty, which is
 * the product being careful rather than this being clever.
 *
 * WHAT IT CANNOT SEE is in tests/js/_dom.js, and the limit is deliberate.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { test, eq, ok, run } = require('./_harness');
const { bootPage, settle } = require('./_dom');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const PAGES = fs.readdirSync(DASH).filter(f => f.endsWith('.html')).sort();

/** Everything the page painted, as one piece of text. */
const allPaint = (r) => r.painted.map(p => p.html).join('\n');

test('there are pages to boot, so this cannot pass by finding none', () => {
  ok(PAGES.length > 5, `only found ${PAGES.length} page(s)`);
});

for (const page of PAGES) {
  test(`${page} boots with nothing thrown`, async () => {
    const r = await settle(bootPage(page));
    eq(r.errors.length, 0, `${page}: ${r.errors.slice(0, 3).join(' | ')}`);
  });

  test(`${page} paints something`, async () => {
    // A page that renders nothing is the defect the owner reported as an
    // empty grey card - and three pages did exactly that against the first
    // version of the DOM, silently, because each caught its own failure.
    const r = await settle(bootPage(page));
    const painted = r.painted.filter(p => p.html && p.html.trim().length > 20);
    ok(painted.length > 0, `${page} painted nothing`);
  });

  test(`${page} needs no service in demo mode`, async () => {
    // Demo mode exists so the product can be shown with no install. A page
    // that calls the API anyway is broken for the one case demo mode is for.
    const r = await settle(bootPage(page));
    const reached = r.errors.filter(e => e.startsWith('reached the network'));
    eq(reached.length, 0, `${page}: ${reached.join(' | ')}`);
  });

  test(`${page} paints no undefined value`, async () => {
    // A value read from the wrong object is undefined at runtime and the page
    // shows the WORD. No error, no clue, and it has happened here.
    //
    // SCOPE, measured rather than assumed: `esc()` is null-safe, so anything
    // drawn through it renders EMPTY rather than "undefined". This catches the
    // RAW interpolations - `${thing.field}` straight into a template - which
    // is where the word actually reaches a screen. Confirmed both ways: an
    // absent field through esc does not trip it, and the same field raw does.
    const r = await settle(bootPage(page));
    const text = allPaint(r);
    for (const bad of ['undefined', 'NaN', '[object Object]']) {
      ok(!text.includes(`>${bad}<`), `${page} painted ${bad} as content`);
      ok(!text.includes(`: ${bad}`), `${page} painted ${bad} after a label`);
    }
  });
}

run('pages-boot');
