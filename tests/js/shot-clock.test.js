/* SHOT-CLOCK-1: the manual's pictures, taken twice, are the same picture.
 *
 * Before this, a picture taken again differed by the time it showed: the
 * sample pages build their dates from the clock, and the Migrations header
 * line "Updated ... next in ...s" appeared only after the page's one-second
 * timer ran, so it was in some pictures and not in others. SAMPLE-COUNTS-1
 * took six pictures again and five differed only by that.
 *
 * Now tools/manual-shots.js gives every page one fixed date and time (and one
 * time zone and locale) before the page's own script runs, lets each
 * repeating timer run its first pass once and then hold, and waits for every
 * first pass before each picture. This runs the parts: the script the page
 * gets, the calls that install it, and the wait.
 *
 * RUN, not read: the functions are lifted out of tools/manual-shots.js and
 * called. The file starts Edge when it is run, so it is not required. The
 * order of the calls in main() is held by tests/unit/ManualShotsClock.Tests.ps1,
 * which reads the code without its comments.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { test, eq, ok, run } = require('./_harness');

const SRC = fs.readFileSync(path.join(__dirname, '..', '..', 'tools', 'manual-shots.js'), 'utf8');
const lift = (name) => {
  const m = SRC.match(new RegExp(`(?:^|\\n)(?:async )?function ${name}\\s*\\([\\s\\S]*?\\n\\}`));
  if (!m) { throw new Error(`could not lift ${name}`); }
  return eval(`(${m[0].trim()})`);   // eslint-disable-line no-eval
};
const SHOT_CLOCK = (() => {
  const m = SRC.match(/\nconst SHOT_CLOCK = (\{[\s\S]*?\});/);
  if (!m) { throw new Error('could not read SHOT_CLOCK'); }
  return eval(`(${m[1]})`);   // eslint-disable-line no-eval
})();
const shotClockScript = lift('shotClockScript');
const installShotClock = lift('installShotClock');
const waitForTimerPass = lift('waitForTimerPass');

const AT = '2026-11-06T15:00:00.000Z';

/** A page: a fresh context with the real Date and timers whose passes the
 *  test runs by hand, with the clock script run in it first. */
function page(at) {
  const timers = new Map();
  let next = 1;
  const ctx = {
    Date,
    setTimeout: (fn, ms, ...a) => { const n = next++; timers.set(n, { fn, ms, a }); return n; },
    clearTimeout: (n) => { timers.delete(n); },
    setInterval: () => { throw new Error('the page used the setInterval it had before the clock'); },
    clearInterval: () => { throw new Error('the page used the clearInterval it had before the clock'); },
  };
  ctx.globalThis = ctx;
  ctx.window = ctx;
  vm.createContext(ctx);
  vm.runInContext(shotClockScript(at), ctx);
  const runAll = () => { for (const [n, t] of [...timers]) { timers.delete(n); t.fn(...t.a); } };
  return { ctx, timers, runAll, js: (code) => vm.runInContext(code, ctx) };
}

test('the page reads one fixed date and time, from Date.now, new Date() and Date()', () => {
  const p1 = page(AT);
  eq(p1.js('Date.now()'), Date.parse(AT));
  eq(p1.js('new Date().toISOString()'), AT);
  eq(p1.js('new Date().getTime()'), Date.parse(AT));
  eq(p1.js('Date()'), new Date(Date.parse(AT)).toString(), 'Date() called as a function says the fixed time');
  // A second read, later, is the same instant: a picture must not depend on
  // how long the page took.
  eq(p1.js('Date.now() - new Date().getTime()'), 0);
});

test('a date the page gives is that date, and every other part of Date still works', () => {
  const p1 = page(AT);
  eq(p1.js("new Date('2026-09-24T18:00:00Z').toISOString()"), '2026-09-24T18:00:00.000Z');
  eq(p1.js('new Date(0).getTime()'), 0);
  eq(p1.js('new Date(2026, 0, 2).getFullYear()'), 2026);
  eq(p1.js("Date.parse('2026-11-06T10:00:00Z')"), Date.parse('2026-11-06T10:00:00Z'));
  eq(p1.js('Date.UTC(2026, 10, 6)'), Date.UTC(2026, 10, 6));
  ok(p1.js('new Date() instanceof Date'), 'a date made on the page is a Date');
  // "... ago" texts subtract a sample time from now: built from the fixed
  // clock, a sample time 5 minutes ago is 5 minutes ago in every picture.
  eq(p1.js('Date.now() - Date.parse(new Date(Date.now() - 300000).toISOString())'), 300000);
});

test('a bad date for the clock fails, rather than giving the page an invalid date', () => {
  let threw = false;
  try { shotClockScript('not a date'); } catch { threw = true; }
  ok(threw, 'an invalid date is refused');
});

test('a repeating timer runs its first pass once, then holds, and the page says how many passes are still to run', () => {
  const p1 = page(AT);
  eq(p1.js('__vmfShotClock.pending'), 0);
  p1.js('globalThis.ticks = 0; globalThis.id = setInterval((n) => { ticks += n; }, 1000, 1)');
  eq(p1.js('__vmfShotClock.pending'), 1, 'one first pass is still to run');
  eq(p1.timers.get(p1.js('id')).ms, 1000, 'the pass runs after the period the page asked for');
  p1.runAll();
  eq(p1.js('ticks'), 1, 'the first pass ran, with its arguments');
  eq(p1.js('__vmfShotClock.pending'), 0, 'nothing is still to run');
  p1.runAll();
  eq(p1.js('ticks'), 1, 'and it does not run again: the picture shows the first pass');
});

test('a repeating timer cleared before its first pass is not waited for', () => {
  const p1 = page(AT);
  p1.js('globalThis.ran = false; globalThis.a = setInterval(() => { ran = true; }, 6000); globalThis.b = setInterval(() => { ran = true; }, 6000)');
  eq(p1.js('__vmfShotClock.pending'), 2);
  p1.js('clearInterval(a)');
  eq(p1.js('__vmfShotClock.pending'), 1, 'clearInterval takes it off the count');
  p1.js('clearTimeout(b)');
  eq(p1.js('__vmfShotClock.pending'), 0, 'and so does clearTimeout, which also clears an interval');
  p1.runAll();
  eq(p1.js('ran'), false, 'a cleared timer never runs');
  p1.js('clearInterval(a)');
  eq(p1.js('__vmfShotClock.pending'), 0, 'clearing it twice does not count it twice');
});

test('a first pass that throws is still off the count', () => {
  const p1 = page(AT);
  p1.js("setInterval(() => { throw new Error('page fault'); }, 1000)");
  let threw = false;
  try { p1.runAll(); } catch { threw = true; }
  ok(threw, 'the error reaches the page as before');
  eq(p1.js('__vmfShotClock.pending'), 0);
});

test('the clock is one fixed date, time zone and locale for every picture', () => {
  ok(!Number.isNaN(Date.parse(SHOT_CLOCK.at)), 'a valid date');
  ok(/Z$/.test(SHOT_CLOCK.at), 'a date in UTC, the same on every computer');
  ok(typeof SHOT_CLOCK.timezone === 'string' && SHOT_CLOCK.timezone.length > 0, 'a time zone');
  ok(typeof SHOT_CLOCK.locale === 'string' && SHOT_CLOCK.locale.length > 0, 'a locale');
  // The sample data has fixed times up to 2026-11-06 10:05 (the record of a
  // machine left out). The clock is after them, so none of them is in the future.
  ok(Date.parse(SHOT_CLOCK.at) > Date.parse('2026-11-06T10:05:00Z'), 'after every fixed time in the sample data');
});

test('installing the clock gives the page the script before its own, and the time zone and locale', async () => {
  const calls = [];
  await installShotClock(async (method, params) => { calls.push([method, params]); return { result: {} }; },
    { at: AT, timezone: 'UTC', locale: 'en-US' });
  eq(JSON.stringify(calls.map(c => c[0])), JSON.stringify(['Page.addScriptToEvaluateOnNewDocument', 'Emulation.setTimezoneOverride', 'Emulation.setLocaleOverride']));
  eq(calls[0][1].source, shotClockScript(AT), 'the script is the fixed clock');
  eq(calls[1][1].timezoneId, 'UTC');
  eq(calls[2][1].locale, 'en-US');
});

test('a browser that refuses a part of the clock fails the run', async () => {
  for (const refused of ['Page.addScriptToEvaluateOnNewDocument', 'Emulation.setTimezoneOverride', 'Emulation.setLocaleOverride']) {
    let msg = '';
    try {
      await installShotClock(async (method) => (method === refused ? { error: { message: 'not supported' } } : { result: {} }),
        { at: AT, timezone: 'UTC', locale: 'en-US' });
    } catch (e) { msg = String(e.message); }
    ok(msg.includes(refused) && msg.includes('not supported'), `${refused} refused fails the run (${msg})`);
  }
});

test('the wait asks the page until every first pass ran', async () => {
  const answers = [2, 1, 0];
  let asked = 0, slept = 0;
  await waitForTimerPass(async (method, params) => {
    eq(method, 'Runtime.evaluate');
    ok(String(params.expression).includes('__vmfShotClock'), 'it asks the clock on the page');
    return { result: { result: { value: answers[asked++] } } };
  }, async () => { slept += 1; }, 1000);
  eq(asked, 3, 'it asked until nothing was still to run');
  eq(slept, 2);
});

test('the wait fails on a page with no fixed clock, and on a pass that never runs', async () => {
  let msg = '';
  try { await waitForTimerPass(async () => ({ result: { result: { value: -1 } } }), async () => {}, 1000); } catch (e) { msg = String(e.message); }
  ok(msg.includes('fixed clock'), `a page with no fixed clock fails (${msg})`);
  msg = '';
  try { await waitForTimerPass(async () => ({ result: { result: { value: 1 } } }), async () => {}, 1000); } catch (e) { msg = String(e.message); }
  ok(msg.includes('first pass'), `a pass that never runs fails (${msg})`);
});

/* The page's other clock is its animations. The tool asks for reduced motion,
 * and MEASURED 2026-11-07: migration-run.png, taken twice on the fixed clock,
 * still differed in 79 pixels - the turning circle in the "Moving" label. Its
 * rule (.p-migrations .pill .spin) is more specific than the reduced-motion
 * rule (.spin), so it never stopped, for a person who asks for less motion
 * too. The same held for the spinner of the Overview and of the wizard, and
 * for the header mark (.brand .logo .vmf-mark-wait beats .brand .logo svg *).
 * So: every rule that runs an animation is stopped under reduced motion by a
 * rule with the SAME selector, later in the file - equal weight, and the later
 * rule wins. */
function cssRules(css) {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, ' ');
  const rules = [];
  let i = 0;
  const block = (from) => {   // the index after the } that closes the { at `from`
    let depth = 0;
    for (let k = from; k < text.length; k++) {
      if (text[k] === '{') depth++;
      else if (text[k] === '}') { depth--; if (depth === 0) return k + 1; }
    }
    throw new Error('a { in app.css is never closed');
  };
  const read = (start, end, media) => {
    let k = start;
    while (k < end) {
      const open = text.indexOf('{', k);
      if (open < 0 || open >= end) break;
      const head = text.slice(k, open).trim();
      const close = block(open);
      if (/^@media/.test(head)) { read(open + 1, close - 1, head); }
      else if (!/^@/.test(head)) {
        rules.push({ at: open, media, selectors: head.split(',').map(s => s.trim().replace(/\s+/g, ' ')), body: text.slice(open + 1, close - 1) });
      }
      k = close;
    }
  };
  read(i, text.length, null);
  return rules;
}

test('every animation in the dashboard stops under reduced motion, so no picture holds a frame of one', () => {
  const css = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'), 'utf8');
  const rules = cssRules(css);
  const animated = rules.filter(r => !r.media && /(^|;|\s)animation(-name)?\s*:\s*(?!none\b)[^;]+/.test(r.body));
  ok(animated.length >= 5, `the animations are found (${animated.length})`);
  const stops = rules.filter(r => r.media && /prefers-reduced-motion:\s*reduce/.test(r.media) && /animation\s*:\s*none\b/.test(r.body));
  for (const r of animated) {
    for (const sel of r.selectors) {
      const stop = stops.find(s => s.selectors.includes(sel) && s.at > r.at);
      ok(Boolean(stop), `${sel} is stopped under reduced motion by a rule with the same selector, after it`);
    }
  }
});

run('shot-clock');
