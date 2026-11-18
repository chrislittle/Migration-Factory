/* AVSET-WAIT-1: one machine moving, the rest queued, and no reason given.
 *
 * Owner, watching a wave of two with the throttle set higher than two:
 *
 *   "I think this is the AV Set. its doing it properly 1 by 1. great. but it
 *    doesn't show a label of why only 1 is running at a time visually."
 *
 * He read it correctly and the code says so in as many words. `Orchestrator`:
 * "Availability-set serialization: one conversion per AvSet at a time." The
 * worker takes a `group-avset/<id>` lease before it touches a machine, and
 * every other machine in that availability set is passed over until the lease
 * is released. That is what stops both halves of an availability set being
 * down at once.
 *
 * THE PRODUCT IS DOING THE RIGHT THING AND TELLING NOBODY. The second machine
 * shows a bare "Queued", the wave says it runs three at a time, and one
 * machine is moving - so it reads as stalled.
 *
 * The words already exist one screen back: the wave editor tags these
 * machines "moves with its pair". The run page has the same fact on the plan
 * entry and said nothing with it.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run, liftConst } = require('./_harness');

const dash = (f) => pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', f));
const PAGE = dash('migrations.html');
const WAVES = dash('waves.html');
const UX_MISC = liftConst('migrations.html', 'UX_MISC');

test('the run page works out which availability sets are busy', () => {
  // Per WAVE, because the lock is taken per wave run. A machine whose pair is
  // migrating in another wave is not what holds this one up.
  ok(/avsetBusy/.test(PAGE), 'the page must know which sets are in flight');
  // From where the availability set is READ, not from where the set of busy
  // ones is built - the helper that reads it sits above.
  const at = PAGE.indexOf('const avsetOf');
  ok(at >= 0, 'and work it out for itself');
  const fn = PAGE.slice(at, at + 600);
  ok(/avsetBusy/.test(fn), 'the two belong together');
  ok(/availabilitySetId/.test(fn), 'from the availability set on the plan entry');
  ok(/SETTLED_STATES|NOT_STARTED_STATE/.test(fn),
    'and from which machines are actually working');
});

test('a machine held behind its pair says so', () => {
  ok(/pairWaitTag/.test(PAGE), 'the row needs a tag of its own');
  const row = PAGE.slice(PAGE.indexOf('const pairWaitTag'), PAGE.indexOf('<td>${statePill'));
  ok(/avsetBusy/.test(row), 'shown only when that set is genuinely busy');
  ok(/NOT_STARTED_STATE|PLANNED/.test(row),
    'and only on a machine that has not started - one already moving is not waiting');
});

test('and the tag is DRAWN, not only built', () => {
  // Four times in one day a check passed on a value that was made and never
  // painted.
  const cell = PAGE.slice(PAGE.indexOf('<td>${notMoved ? notMovedPill'), PAGE.indexOf('<td>${notMoved ? notMovedPill') + 200);
  ok(/pairWaitTag/.test(cell), 'it must be in the status cell with the other tags');
});

test('it uses the words the wave editor already uses', () => {
  /* The same fact was already named one screen back. Two names for one thing
   * is how a person stops believing either of them. */
  const editorTag = WAVES.match(/avsetTag: *'([^']*)'/);
  ok(editorTag, 'the editor must still name it');
  /* The noun the editor uses, required here too.
   *
   * The first shape of this asked for the editor's whole phrase OR for the
   * word "pair" in the EDITOR's own string - and the editor always contains
   * it, so that leg could never fail. A check with a branch that is always
   * true is not a check. Mutation walked straight past it. */
  const noun = editorTag[1].split(/\s+/).pop();
  ok(UX_MISC.pairWait.includes(noun),
    `the run page must use the editor's word for it ("${noun}")`);
  ok(/wait/i.test(UX_MISC.pairWait),
    'and this one says it is WAITING, which is the part the editor does not');
});

run('avset-wait');
