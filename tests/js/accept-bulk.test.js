/* ACCEPT-BULK-1: seven waves, seven clicks, five seconds each.
 *
 * Found on a 27-machine estate: accepting the settings of large waves took
 * a long time. Seven waves needed seven accepts of about 3-5 seconds each,
 * and after the first one the button did not change color to show it was
 * doing anything.
 *
 * Two separate things, both only visible once there is more than one wave:
 *
 *   1. NOTHING SAYS IT IS WORKING. The handler disables the button and reads
 *      the plan from the store - three to five seconds of a button that looks
 *      the same as it did before the click.
 *   2. EVERY WAVE IS A SEPARATE CLICK. An estate shaped by resource group has
 *      one wave per group, so the demo preset is seven.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));

/* Take a handler by its OWN two ends, not by a character budget.
 *
 * The first shape of this test allowed 1400 characters between the listener
 * and its closing brace, and the comments explaining why the handler names the
 * plan version are longer than that - so it read nothing and reported the
 * handler missing. A budget measures how much prose sits in the middle, which
 * is not what any of these checks are about. Both closers sit at the page's
 * two-space top level, and everything nested is indented further, so the first
 * one after the listener is the handler's own. */
function handlerAt(marker, closer) {
  const from = SRC.indexOf(marker);
  ok(from >= 0, `could not find ${marker}`);
  const to = SRC.indexOf(closer, from);
  ok(to >= 0, `could not find the end of the handler at ${marker}`);
  return SRC.slice(from, to + closer.length);
}
const ONE = () => handlerAt("el.querySelectorAll('[data-accept]').forEach", '\n  }));');
const ALL = () => handlerAt("el.querySelector('[data-accept-all]')", '\n  });');

test('the accept button says it is working', () => {
  // A disabled button that still reads "Accept these settings" is a button
  // that looks broken for five seconds.
  ok(/acceptBusy/.test(ONE()), 'it must say it is accepting');
});

test('and puts its words back if it fails, so it can be pressed again', () => {
  ok(/btn\.textContent = was|textContent = UX\.acceptBtn/.test(ONE()),
    'a failed accept must restore the button');
});

test('more than one outstanding wave offers to accept them all', () => {
  ok(/data-accept-all/.test(SRC), 'there must be an accept-all control');
  ok(/acceptAllBtn/.test(SRC), 'and it must have words of its own');
});

test('the all-at-once path reads the plan ONCE, not once per wave', () => {
  // The three to five seconds is the store read. Doing it seven times is the
  // whole complaint.
  const all = ALL();
  ok((all.match(/blobVersioned/g) || []).length === 1,
    'the plan is read once for the whole sweep');
  // COUNTING THE READ IS NOT ENOUGH, and this is how the first shape of this
  // check passed a mutation: a read moved INSIDE the loop is still one read in
  // the text, and seven reads at run time - the exact defect. So the read must
  // sit before the loop opens.
  const readAt = all.indexOf('blobVersioned');
  const loopAt = all.indexOf('for (let i = 0');
  ok(loopAt >= 0, 'the sweep must loop over the outstanding waves');
  ok(readAt < loopAt, 'the plan is read before the loop, not inside it');
});

test('and it still names the plan version on every wave it accepts', () => {
  // PLANHASH-1: a bulk accept that forgot this would fail seven times instead
  // of once.
  ok(/planHash/.test(ALL()), 'each accept must name the plan it agrees to');
});

test('it says which wave it is on, because seven takes a while', () => {
  ok(/acceptAllBusy/.test(SRC), 'progress must be shown');
});

run('accept-bulk');
