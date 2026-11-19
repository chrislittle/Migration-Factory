/* STORE-READ-2: the store fan-out must be PACED, not truncated.
 *
 * Every dashboard page did `Promise.all(names.map(read))` over a folder
 * listing. The facade pages a listing up to 50 x 5,000, so that is one
 * authenticated request per machine in the run, all at once, from one tab -
 * and on the migrations console the whole fan-out repeats every refresh tick.
 *
 * The two properties that matter, and that a reader of the code cannot check
 * by eye:
 *
 *   1. never more than the limit in flight  - the actual fix
 *   2. every item still processed, in order - NOT hiding half a fleet from the
 *      console that migrates it, which would be a worse defect than the one
 *      being fixed
 *
 * Both are tested by counting live calls, because the obvious wrong
 * implementations (slice to the limit, or fire everything and await later)
 * each satisfy one and break the other.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const mapLimited = lift('help.js', 'mapLimited');

/* The lifted function closes over a module-level constant the harness cannot
 * see. Read the REAL value out of the source rather than hard-coding one here:
 * a literal 8 in this file would keep passing after somebody changed the
 * limit, which is the shape of a test that cannot fail. */
const HELP_SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const LIMIT_MATCH = HELP_SRC.match(/const STORE_READ_LIMIT = (\d+);/);
if (!LIMIT_MATCH) { throw new Error('STORE_READ_LIMIT is not declared in help.js'); }
global.STORE_READ_LIMIT = Number(LIMIT_MATCH[1]);

/** A fake worker that records how many calls are in flight at their peak. */
function tracker(delayMs = 1) {
  const state = { live: 0, peak: 0, calls: [] };
  const fn = async (item) => {
    state.live++;
    state.peak = Math.max(state.peak, state.live);
    state.calls.push(item);
    await new Promise(r => setTimeout(r, delayMs));
    state.live--;
    return `done:${item}`;
  };
  return { state, fn };
}

test('never runs more than the limit at once', async () => {
  const items = Array.from({ length: 50 }, (_, i) => i);
  const { state, fn } = tracker();
  await mapLimited(items, fn, 8);
  ok(state.peak <= 8, `peak concurrency was ${state.peak}, limit was 8`);
});

test('actually uses the limit - it is not accidentally serial', async () => {
  /* A one-at-a-time loop passes the test above and would make a page with a
   * hundred documents unusably slow. */
  const items = Array.from({ length: 50 }, (_, i) => i);
  const { state, fn } = tracker();
  await mapLimited(items, fn, 8);
  eq(state.peak, 8, 'peak concurrency');
});

test('processes EVERY item - nothing is dropped', async () => {
  const items = Array.from({ length: 50 }, (_, i) => i);
  const { state, fn } = tracker();
  const out = await mapLimited(items, fn, 8);
  eq(state.calls.length, 50, 'calls made');
  eq(out.length, 50, 'results returned');
  eq(new Set(state.calls).size, 50, 'distinct items seen');
});

test('keeps input order even though completion order differs', async () => {
  /* Workers finish out of order by design; the caller indexes into the result
   * as if it were a plain map, so the order has to be restored. Earlier items
   * are made SLOWER so completion order is genuinely reversed. */
  const items = [0, 1, 2, 3, 4, 5, 6, 7];
  const out = await mapLimited(items, async (n) => {
    await new Promise(r => setTimeout(r, (8 - n) * 4));
    return `v${n}`;
  }, 8);
  eq(out, ['v0', 'v1', 'v2', 'v3', 'v4', 'v5', 'v6', 'v7'], 'results in input order');
});

test('an empty list does no work and returns nothing', async () => {
  const { state, fn } = tracker();
  const out = await mapLimited([], fn, 8);
  eq(out.length, 0, 'results');
  eq(state.calls.length, 0, 'calls');
});

test('a list shorter than the limit does not spin idle workers', async () => {
  const { state, fn } = tracker();
  await mapLimited([1, 2], fn, 8);
  eq(state.peak, 2, 'peak concurrency for a 2-item list');
});

test('falls back to the shared limit when none is given', async () => {
  const items = Array.from({ length: 40 }, (_, i) => i);
  const { state, fn } = tracker();
  await mapLimited(items, fn);
  eq(state.peak, global.STORE_READ_LIMIT, 'default peak concurrency');
  eq(state.calls.length, 40, 'still processes everything');
});

test('the shared limit is a small number - a cap that is not a cap is not one', () => {
  /* Pins the intent, not the exact value: 8 may become 6 or 12 on evidence,
   * but a limit of 500 would be the original defect wearing a helper. */
  ok(global.STORE_READ_LIMIT >= 2, 'limit must allow some parallelism');
  ok(global.STORE_READ_LIMIT <= 32, `limit ${global.STORE_READ_LIMIT} is not a meaningful cap`);
});

test('a null or undefined list is not a crash', async () => {
  eq((await mapLimited(null, async () => 1)).length, 0, 'null');
  eq((await mapLimited(undefined, async () => 1)).length, 0, 'undefined');
});

/* WAIT-1: the fan-out tells a page after each result lands, so the page can
 * draw what it has instead of holding it all back for the slowest. Three pages
 * read the whole store through this, so a mistake here is a mistake on all of
 * them. */

test('WAIT-1: says so after each one lands, with what has landed so far', async () => {
  const seen = [];
  await mapLimited([1, 2, 3], async (n) => n * 10, 1, (sofar, done, total) => {
    seen.push(`${done}/${total}:${sofar.join(',')}`);
  });
  eq(seen.join(' | '), '1/3:10 | 2/3:10,20 | 3/3:10,20,30', 'what the page was told');
});

test('WAIT-1: never hands over a hole where a slot has not finished', async () => {
  // Eight in flight at once, finishing out of order. A page draws what is
  // there; it must never be handed undefined to render.
  const order = [3, 1, 2, 0];
  const gates = order.map(() => { let go; const until = new Promise(r => { go = r; }); return { until, go }; });
  const handed = [];
  const all = mapLimited([0, 1, 2, 3], async (n) => { await gates[n].until; return n; }, 4,
    (sofar) => { handed.push(sofar.slice()); });
  for (const n of order) { gates[n].go(); await new Promise(r => setTimeout(r, 0)); }
  await all;
  for (const batch of handed) {
    eq(batch.includes(undefined), false, 'a hole reached the page');
  }
  eq(handed.length, 4, 'one call per result');
});

test('WAIT-1: a page that throws while drawing does not lose the read', async () => {
  // Drawing is not reading. The fan-out here is every run in the store, and
  // losing it because a render threw would turn a cosmetic fault into an empty
  // page that looks like an empty estate.
  const out = await mapLimited([1, 2, 3], async (n) => n, 2, () => { throw new Error('render blew up'); });
  eq(out.join(','), '1,2,3', 'the results survived');
});

test('WAIT-1: no callback is the old behaviour, unchanged', async () => {
  const out = await mapLimited([1, 2, 3], async (n) => n * 2);
  eq(out.join(','), '2,4,6', 'results');
});
run('map-limited');
