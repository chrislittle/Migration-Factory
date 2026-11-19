/* POLL-1: the wizard's watch must not run two ticks at once.
 *
 * `setInterval` does not wait for an async callback. The wizard's tick does
 *
 *     await readRun()
 *
 * and readRun issues one request per machine in the run. So on exactly the
 * fleet sizes where a tick takes longer than the 6-second interval, the next
 * tick started anyway and the work in flight grew with elapsed time instead of
 * staying flat.
 *
 * `clearInterval` at the top of startPolling does NOT prevent this - it stops a
 * second INTERVAL being created, not two ticks of the same interval
 * overlapping. That distinction is invisible when reading the code, which is
 * why this drives the callback instead.
 *
 * The interval is 6 seconds, so the tick is captured and called directly
 * rather than waited for.
 */
'use strict';
const { lift, test, eq, run } = require('./_harness');

const startPolling = lift('wizard.html', 'startPolling');

/** Install what the lifted function closes over; return the captured tick. */
function install() {
  const state = { readRuns: 0, release: null, cleared: 0 };
  global.poll = null;
  global.pollBusy = false;
  global.clearInterval = () => { state.cleared++; };
  global.step = 1;
  global.STEP = { assess: { findings: 3 }, migrate: { group: 2, waves: 3 } };
  global.assessment = null;
  global.plan = null;
  global.render = () => {};
  global.deriveStep = () => global.step;
  // A readRun that does not finish until the test says so.
  global.readRun = () => {
    state.readRuns++;
    return new Promise(resolve => { state.release = resolve; });
  };
  let tick = null;
  global.setInterval = (fn) => { tick = fn; return 99; };
  startPolling();
  return { state, tick: () => tick() };
}

test('a second tick does NOT start while the first is still running', async () => {
  const h = install();
  h.tick();                       // first tick: readRun starts and hangs
  eq(h.state.readRuns, 1, 'reads after the first tick');
  h.tick();                       // would have overlapped before the fix
  h.tick();
  eq(h.state.readRuns, 1, 'reads after three ticks with the first still running');
});

test('and once it finishes, the next tick runs normally', async () => {
  const h = install();
  h.tick();
  h.state.release();              // the first read completes
  await new Promise(r => setImmediate(r));
  h.tick();
  eq(h.state.readRuns, 2, 'the watch keeps watching');
});

test('a tick that THROWS still releases the guard', async () => {
  /* The dangerous way to write this: set the flag, and clear it only on the
   * happy path. One failed read would then stop the watch for ever, and the
   * wizard would sit on a step that never advances - a worse fault than the
   * one being fixed, and silent. */
  const h = install();
  global.readRun = () => { throw new Error('the facade is asleep'); };
  h.tick();
  global.readRun = () => { h.state.readRuns++; return Promise.resolve(); };
  h.tick();
  eq(h.state.readRuns, 1, 'the watch recovered after a failed read');
});

test('starting the watch again clears any previous interval', async () => {
  const h = install();
  global.poll = 99;
  startPolling();
  eq(h.state.cleared >= 1, true, 'the old interval is cleared');
});

test('the guard is released before the next interval, not left set', async () => {
  // Belt and braces: after a completed tick the flag must be false, or the
  // watch is dead and nothing says so.
  const h = install();
  h.tick();
  h.state.release();
  await new Promise(r => setImmediate(r));
  eq(global.pollBusy, false, 'pollBusy after a completed tick');
});

run('wizard-poll');
