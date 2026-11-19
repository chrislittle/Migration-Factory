/* QUOTA-PLACE-1: the plan-wide answer, two pages below the plan.
 *
 * Seen on an estate of eight waves: the quota statement sat two pages of
 * scrolling below the waves, so it was easy to miss.
 *
 * "Ask Azure to raise the quota" is appended AFTER every wave card. On one
 * wave that reads as a footnote beside the per-wave check; on eight it is two
 * pages down, and the one thing it says - whether the estate can run at all -
 * is the thing nobody sees.
 *
 * The comment beside it argued for the placement: plan-wide, so "under the
 * waves ... but beside the per-wave quota check that finds the shortfall".
 * That reasoning holds at one wave and fails at eight.
 *
 * A quota increase takes Azure a day or two. If this plan needs one, that is
 * the first thing to know, not the last.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));

test('the plan-wide card is drawn BEFORE the waves', () => {
  // THE DEFECT. `+=` after the wave cards put it at the bottom of however
  // many there were.
  const card = PAGE.indexOf('UX.quotaTitle');
  ok(card >= 0, 'the card must be on the page');
  const appended = PAGE.slice(Math.max(0, card - 400), card);
  ok(!/\$\('#waves'\)\.innerHTML \+=/.test(appended),
    'it must not be appended after the waves');
});

test('and it has a place of its own, not the end of the wave list', () => {
  ok(/id="quota"/.test(PAGE), 'the page needs a slot for it');
  const body = PAGE.slice(PAGE.indexOf('<div id="app"'), PAGE.indexOf('</main>'));
  const quotaAt = body.indexOf('id="quota"');
  const wavesAt = body.indexOf('id="waves"');
  ok(quotaAt >= 0 && wavesAt >= 0, 'both must be in the page');
  ok(quotaAt < wavesAt, 'and the plan-wide one comes first');
});

test('WAVES-COL-1: the two-column grid still has exactly TWO children', () => {
  /* WHAT THE CHECK ABOVE COULD NOT SEE, and a look at the page could: the
   * change broke the wave menu.
   *
   * `.cols` is `grid-template-columns: 340px 1fr`. Putting the quota card in
   * as a THIRD child gave it the right-hand column and wrapped every wave
   * underneath the machine picker, in a 340px lane. The markup order was
   * still right - quota before waves - so the check above passed while the
   * page was unusable.
   *
   * I had measured the card's y position and declared it fixed. Measuring the
   * property under test is not looking at the page. */
  const cols = PAGE.slice(PAGE.indexOf('<div class="cols">'), PAGE.indexOf('</main>'));
  const depth = [];
  let open = 0;
  for (const m of cols.matchAll(/<div\b[^>]*>|<\/div>/g)) {
    if (m[0] === '</div>') { open -= 1; if (open === 0) { break; } }
    else { if (open === 1) { depth.push(m[0]); } open += 1; }
  }
  ok(depth.length === 2,
    `the grid has two columns, so it takes two children - found ${depth.length}: ${depth.join(' ')}`);
  ok(/id="quota"/.test(cols.slice(cols.indexOf(depth[1]))),
    'and the quota card sits inside the second of them, above the waves');
});

test('a plan with nothing to request does not shout about it', () => {
  /* It still says so - "Every size family has enough quota" is worth
   * knowing, and silence would read as "not checked". But a card that needs
   * no action must not sit above the work looking like one. */
  /* READ where it is PAINTED, not where it is declared. A check for the
   * name anywhere in the page passes on the string's own declaration, so
   * deleting the branch that shows it changes nothing - which mutation
   * proved. Fifth instance of that shape in one day. */
  // QUOTA-CHECK-SPINNER-1: the card first returns its checking state; the result is after it.
  // The good case is the plan-wide sentence in its success color, painted beside the danger one.
  const fn = PAGE.slice(PAGE.indexOf('function quotaPlanState'));
  const body = fn.slice(0, fn.indexOf('\n}'));
  ok(/cls: 'ok-inline', text: UX\.capPlanEnough/.test(body), 'the good case must be shown, not only declared');
  ok(/rows\.some\(r => r\.short\)/.test(body), 'and the card tells the two cases apart');
  ok(/quotaPlanState\(rows\)/.test(PAGE), 'the card paints it');
});

test('the shortfall case is the one that gets the card', () => {
  // A quota increase takes Azure a day or two, so a plan that needs one must
  // say it before somebody arranges eight waves.
  // QUOTA-CHECK-SPINNER-1: the card is longer now (the plan-wide table), so read its whole function.
  const fn = PAGE.slice(PAGE.indexOf('function quotaCardHtml'));
  const render = fn.slice(0, fn.indexOf('\n}'));
  ok(/quotaBtn/.test(render), 'the request control belongs with it');
  ok(/\$\{quotaShort\s*\?/.test(render), 'and is offered only when something is actually short');
});

run('quota-place');
