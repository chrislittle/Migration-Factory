/* ACTFEED-1, 2026-09-18. The page follows an action through instead of asking
 * somebody to wait for it.
 *
 * WHAT HAPPENED. A user approved a wave. The dialog did its job: the button
 * disabled, said "Working...", the banner said it was done. Then the row
 * underneath still read "Waiting for approval" for ten to fifteen seconds, and
 * only a full refresh showed it approved.
 *
 * A user could think the approval did not take, because it took 10 to 15
 * seconds and a full refresh to show.
 *
 * THE BUTTON WAS NEVER THE PROBLEM. The page refreshed once, IMMEDIATELY, and
 * read a store the service had not finished writing - so the refresh was real
 * and the answer was stale. After that nothing happened until the fifteen-
 * second tick.
 *
 * So the page said two things at once: a banner saying it worked, and a row
 * saying it had not. That is the same disagreement as a machine count that
 * contradicts the table above it - and the message APOLOGISED for it: "It can
 * take a few seconds to appear in the view."
 *
 * A product that knows its view is behind should catch up, not apologise.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

const followThrough = lift('migrations.html', 'followThrough');

/* THE PAGE'S OWN SCHEDULE, read from the page rather than written down again.
 * followThrough falls back to it, so a test that supplied its own would be
 * measuring the test - and the schedule IS the behaviour here. */
globalThis.FOLLOW_THROUGH_MS = JSON.parse(
  '[' + PAGE.match(/const FOLLOW_THROUGH_MS = \[([^\]]*)\]/)[1] + ']');

/** A clock we control, so nothing here waits in real time. */
function fakeClock() {
  const timers = [];
  let now = 0;
  globalThis.setTimeout = (fn, ms) => { timers.push({ at: now + ms, fn, id: timers.length + 1 }); return timers.length; };
  globalThis.clearTimeout = (id) => { const t = timers.find(x => x.id === id); if (t) { t.cancelled = true; } };
  return {
    run(ms) {
      now += ms;
      for (const t of timers) {
        if (!t.cancelled && !t.fired && t.at <= now) { t.fired = true; t.fn(); }
      }
    },
    pending: () => timers.filter(t => !t.cancelled && !t.fired).length,
  };
}

function setup() {
  const clock = fakeClock();
  let reads = 0;
  globalThis.refresh = () => { reads++; };
  globalThis.followTimers = [];
  return { clock, reads: () => reads };
}

test('it reads once immediately, so a fast service shows straight away', () => {
  const { clock, reads } = setup();
  followThrough();
  clock.run(0);
  eq(reads(), 1, 'the first read happens now, not after a delay');
});

test('THE REGRESSION: it keeps reading across the lag that was measured', () => {
  /* Ten to fifteen seconds was the lag measured. One read at zero - which is
   * what the page used to do - lands before the service has written. */
  const { clock, reads } = setup();
  followThrough();
  clock.run(12000);
  ok(reads() >= 3, `it reads more than once over the lag (got ${reads()})`);
});

test('and then it STOPS, rather than becoming a loop', () => {
  /* An action that never lands - the engine refused it - must not leave the
   * page reading the store for ever. The ordinary tick takes over. */
  const { clock, reads } = setup();
  followThrough();
  clock.run(60000);
  const afterAMinute = reads();
  clock.run(600000);
  eq(reads(), afterAMinute, 'nothing more after the schedule is spent');
  eq(clock.pending(), 0, 'and no timer is left armed');
});

test('two actions in a row do not stack their reads', () => {
  /* Approve then Start, a few seconds apart, would otherwise run two schedules
   * at once and read the store eight times for no reason. */
  const { clock, reads } = setup();
  followThrough();
  clock.run(500);
  const afterFirst = reads();
  eq(afterFirst, 1, 'only the immediate read of the first action has fired');
  followThrough();
  clock.run(12000);
  /* EXACTLY the second schedule, and nothing of the first. A loose bound here
   * let the stacked case through: with both running this is 1 + 4 + 3 = 8, and
   * "fewer than 9" is true of 8. Mutation found that. */
  eq(reads(), 1 + FOLLOW_THROUGH_MS.length,
     'the first schedule was cancelled, not run alongside the second');
  eq(clock.pending(), 0);
});

test('the schedule is bounded and starts at zero', () => {
  /* Read from the page, so the test cannot drift from what ships. */
  const m = PAGE.match(/const FOLLOW_THROUGH_MS = \[([^\]]*)\]/);
  ok(m, 'the schedule is declared');
  const ms = m[1].split(',').map(x => Number(x.trim()));
  eq(ms[0], 0, 'the first read is immediate');
  ok(ms.length >= 3 && ms.length <= 6, 'a handful of reads, not a poll');
  ok(Math.max(...ms) <= 20000, 'and it is over within twenty seconds');
  for (let i = 1; i < ms.length; i++) { ok(ms[i] > ms[i - 1], 'each read is later than the last'); }
});

test('the action path uses it, rather than a single refresh', () => {
  /* The wiring, which is the whole defect: a correct helper nothing calls. */
  ok(/closeModal\(\);[\s\S]{0,400}?followThrough\(\);/.test(PAGE),
     'a confirmed action follows through');
});

test('and the message no longer apologises for the page being behind', () => {
  const done = PAGE.match(/  done: *'([^']*)'/)[1];
  ok(!/take a few seconds/.test(done), `the old apology is gone (now: "${done}")`);
});

run('follow through');
