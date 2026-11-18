/* WATCH-1: the polling loop three pages used to keep a copy of each.
 *
 * These rules are invisible in the shape of the code, which is exactly why they
 * needed extracting to one place - and why that place needs behavioural cover.
 * The load-bearing one is that A READ FAILURE KEEPS WATCHING: the run store is
 * the same place the answer comes from, so one bad read proves nothing. Treat a
 * thrown read as a verdict and a slow blob write reports itself as a failure.
 */
'use strict';
const { lift, test, eq, ok, run } = require('./_harness');

const watchRun = lift('help.js', 'watchRun');
const at = (ms) => new Date(ms).toISOString();
const ev = (ms, o) => Object.assign({ tsUtc: at(ms) }, o);

test('a throwing read does not end the watch', async () => {
  let reads = 0;
  const verdict = await watchRun({
    pollMs: 1, timeoutMs: 400,
    readLines: async () => {
      reads++;
      if (reads < 3) { throw new Error('502 from the store'); }
      return [ev(Date.now(), { step: 'engine', outcome: 'fail', detail: 'boom' })];
    },
    scan: (events) => events.find(e => e.outcome === 'fail') || null,
  });
  eq(verdict && verdict.detail, 'boom', 'verdict after two failed reads');
});

test('events from BEFORE the window are somebody else s news', async () => {
  const now = Date.now();
  const verdict = await watchRun({
    pollMs: 1, timeoutMs: 60, sinceMs: now,
    readLines: async () => [ev(now - 60000, { step: 'engine', outcome: 'fail', detail: 'yesterday' })],
    scan: (events) => events[0] || null,
  });
  eq(verdict, null, 'an old failure must not be reported as this attempt');
});

test('...and events inside it are', async () => {
  const now = Date.now();
  const verdict = await watchRun({
    pollMs: 1, timeoutMs: 400, sinceMs: now,
    readLines: async () => [ev(now + 10, { step: 'engine', outcome: 'fail', detail: 'now' })],
    scan: (events) => events[0] || null,
  });
  eq(verdict && verdict.detail, 'now');
});

test('the deadline fires, so a page that is never answered says so', async () => {
  const t0 = Date.now();
  const verdict = await watchRun({
    pollMs: 5, timeoutMs: 80, readLines: async () => [], scan: () => null,
  });
  eq(verdict, null);
  ok(Date.now() - t0 < 600, 'stopped near the deadline rather than spinning');
});

test('onTick answers before the log is read', async () => {
  // The waves page: the capacity CLAIM is the real answer and the event log is
  // only ever a faster way to hear bad news.
  const verdict = await watchRun({
    pollMs: 1, timeoutMs: 400,
    onTick: async () => ({ claim: 'held' }),
    readLines: async () => { throw new Error('must not be read when onTick answered'); },
    scan: () => null,
  });
  eq(verdict, { claim: 'held' });
});

test('scan sees every event in the tick, so a page keeps its own precedence', async () => {
  // A page keeps its own precedence between two answers in one tick; the wizard
  // prefers a failure over "it started". The loop must not decide for them.
  // AVSET-RESERVE-1: the first event is the shape the engine REALLY writes for
  // "nothing to reserve" - a code and the wave. The page's own reading of it is
  // run against the engine's events in reserve-nothing.test.js.
  const now = Date.now();
  const verdict = await watchRun({
    pollMs: 1, timeoutMs: 400,
    readLines: async () => [
      ev(now, { step: 'odcr', outcome: 'info', code: 'nothingReservable', wave: 'wave-1' }),
      ev(now, { step: 'odcr', outcome: 'fail', detail: 'quota' }),
    ],
    scan: (events) => {
      let failure = null, nothing = null;
      for (const e of events) {
        if (e.outcome === 'fail') { failure = e; }
        if (e.code === 'nothingReservable') { nothing = e; }
      }
      return (nothing && !failure) ? { nothing: true } : (failure ? { failure: failure.detail } : null);
    },
  });
  eq(verdict, { failure: 'quota' }, 'the page decided, not the loop');
});

run('watch-run');
