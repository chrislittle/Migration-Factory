/* TARGET-OPTIONS-WAIT-1: the wait for the target options, on the wizard's
 * Choose the machines and Choose each target steps.
 *
 * Seen in the final lab (2026-11-17, build 36206b7): after the approval, the
 * step said "The product is making the target options." for about 40 seconds,
 * then "The target options are not made yet for this assessment." with Make
 * the target options - while the engine's advise operation still ran or had
 * just written its file. Seconds later the page went to the machine list by
 * itself. Two reads gave the wrong "not made yet":
 *   - the log said the options were written, but the read of the file in the
 *     same refresh came first - and "written, not read here" was taken for a
 *     file made by an earlier version;
 *   - a log read that failed came back as no lines, taken for "never started".
 *
 * RUN, not read: the page's own paintAdviceProgress is driven with a log the
 * way the store gives it (parts, a part that fails), and the step's markup and
 * the Make button are what is measured.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const fs = require('fs');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
globalThis.UX = liftConst('wizard.html', 'UX');
globalThis.esc = eval('(' + WIZ.match(/^const esc = (.*);\r?$/m)[1] + ')');   // eslint-disable-line no-eval
globalThis.LOG_PARTS_MAX = 200;
const logFns = liftAll('help.js', ['nextLogPart', 'readLogParts', 'readLogEvents']);
const fns = liftAll('wizard.html', ['adviceProgress', 'adviceWaitView', 'paintAdviceView', 'paintAdviceProgress']);

// The two elements the wait draws into, as the page's static markup has them
// after renderAdviceWait: the spinner and words, and Make (hidden at first).
function stage() {
  const w = { innerHTML: `<span class="spin"></span>${esc(UX.tWaiting)}`, textContent: '', style: { color: '' } };
  // textContent replaces the markup, as a browser does.
  let text = '';
  Object.defineProperty(w, 'textContent', { get() { return text; }, set(v) { text = String(v); this.innerHTML = esc(text); } });
  const make = { style: { display: 'none' }, disabled: false };
  globalThis.$ = (s) => (s === '#t-wait' ? w : s === '#t-make' ? make : null);
  return { w, make };
}
// The run's log in the store, part by part. A part named in `failing` is a read
// the store did not answer.
function store(parts, failing) {
  globalThis.DEMO_MODE = false;
  globalThis.cfg = { apiUrl: 'https://api.example.com' };
  globalThis.getToken = async () => 't';
  globalThis.runPrefix = () => 'alpha/scan-1';
  globalThis.VmfHelp = {
    readLogEvents: logFns.readLogEvents,
    storeBlob: async (gt, api, p) => {
      if ((failing ?? []).includes(p)) { throw new Error('HTTP 503 read ' + p); }
      return Object.prototype.hasOwnProperty.call(parts, p) ? parts[p] : null;
    },
  };
}
const line = (o) => JSON.stringify(o);
const LOG = 'alpha/scan-1/logs/events.jsonl';
const LOG2 = 'alpha/scan-1/logs/events-2.jsonl';
const scan = [line({ step: 'engine', outcome: 'start', detail: 'hosted assess started by approver@example.com (execution e0)' }),
  line({ step: 'assessment', outcome: 'ok', detail: 'Assessed 4 VMs.' })];
const start = line({ step: 'engine', outcome: 'start', detail: 'hosted advise started by approver@example.com (execution e1)' });
const engineUp = line({ step: 'engine:advise', outcome: 'info', detail: 'Engine version 1.0.0 started the advise operation.' });
const written = line({ step: 'advice', outcome: 'ok', detail: 'Wrote the target options for 4 machine(s). 4 have a supported target.' });
const failed = (why) => line({ step: 'engine:advise', outcome: 'fail', detail: why });
const shows = {
  wait: (s) => { ok(s.w.innerHTML.includes('<span class="spin"></span>'), 'the spinner shows: ' + s.w.innerHTML); ok(s.w.innerHTML.includes(esc(UX.tWaiting)), 'the making words show'); eq(s.make.style.display, 'none', 'Make is hidden'); },
  make: (s) => { eq(s.w.textContent, UX.tNotStarted); ok(!s.w.innerHTML.includes('spin'), 'no spinner'); eq(s.make.style.display, '', 'Make shows'); eq(s.make.disabled, false, 'Make can be pressed'); },
};

test('the rule: running and written-not-read wait; failed says why; never started and an earlier version offer Make', () => {
  eq(fns.adviceWaitView({ kind: 'running' }, false), { show: 'wait' });
  eq(fns.adviceWaitView({ kind: 'running' }, true), { show: 'wait' }, 'a new advise over an old file still runs');
  eq(fns.adviceWaitView({ kind: 'done' }, false), { show: 'wait' }, 'written, and the next refresh reads the file');
  eq(fns.adviceWaitView({ kind: 'done' }, true), { show: 'make' }, 'a file an earlier version made: make them again');
  eq(fns.adviceWaitView({ kind: 'failed', detail: 'boom' }, false), { show: 'failed', detail: 'boom' });
  eq(fns.adviceWaitView({ kind: 'none' }, false), { show: 'make' });
});

test('RUN: while the advise operation runs, the spinner and the making words, and no Make', async () => {
  for (const log of [[...scan, start], [...scan, start, engineUp]]) {
    const s = stage(); s.make.style.display = '';   // shown by an earlier paint
    globalThis.adviceOld = false; store({ [LOG]: log.join('\n') });
    await fns.paintAdviceProgress();
    shows.wait(s);
  }
});

test('RUN: the lab case - the log says written, the file is not read yet: still waiting, no Make', async () => {
  const s = stage();
  globalThis.adviceOld = false; store({ [LOG]: [...scan, start, engineUp, written].join('\n') });
  await fns.paintAdviceProgress();
  shows.wait(s);
});

test('RUN: a log read that fails is no answer - the step keeps the spinner and offers no Make', async () => {
  const s = stage();
  globalThis.adviceOld = false; store({}, [LOG]);
  await fns.paintAdviceProgress();
  shows.wait(s);
  // And a later part that fails: the advise lines can be in that part.
  const s2 = stage();
  store({ [LOG]: scan.join('\n') }, [LOG2]);
  await fns.paintAdviceProgress();
  shows.wait(s2);
});

test('RUN: the log in two parts is read to its end', async () => {
  const s = stage();
  globalThis.adviceOld = false; store({ [LOG]: [...scan, start].join('\n'), [LOG2]: failed('The catalog could not be read.') });
  await fns.paintAdviceProgress();
  eq(s.w.textContent, UX.tFailed.replace('{reason}', 'The catalog could not be read.'));
});

test('RUN: a failed advise says why, as text, and offers Make again', async () => {
  const s = stage(); s.make.disabled = true;   // pressed once before
  globalThis.adviceOld = false; store({ [LOG]: [...scan, start, engineUp, failed('<b>AuthorizationFailed</b> $& $1')].join('\n') });
  await fns.paintAdviceProgress();
  eq(s.w.textContent, 'The target options could not be made: <b>AuthorizationFailed</b> $& $1', 'the reason is kept as written');
  ok(!s.w.innerHTML.includes('<b>'), 'the engine words are never markup');
  eq(s.w.style.color, 'var(--bad)');
  eq(s.make.style.display, '', 'Make shows'); eq(s.make.disabled, false, 'and can be pressed');
});

test('RUN: never started - the words and Make', async () => {
  const s = stage();
  globalThis.adviceOld = false; store({ [LOG]: scan.join('\n') });
  await fns.paintAdviceProgress();
  shows.make(s);
});

test('RUN: options an earlier version made - the words and Make', async () => {
  const s = stage();
  globalThis.adviceOld = true; store({ [LOG]: [...scan, start, written].join('\n') });
  await fns.paintAdviceProgress();
  shows.make(s);
});

test('RUN: a failure, then Make pressed again: the new start waits again, in the colour of the words', async () => {
  const s = stage();
  globalThis.adviceOld = false; store({ [LOG]: [...scan, start, failed('x'), start].join('\n') });
  s.w.style.color = 'var(--bad)';
  await fns.paintAdviceProgress();
  shows.wait(s);
  eq(s.w.style.color, '', 'the failure colour is gone');
});

test('finished: the options read, the waiting step is drawn again as the machine list', () => {
  ok(WIZ.includes("else if (targetAdvice && step === STEP.migrate.choose && !$('#m-continue') && !$('#m-continue-why')) { render(); clearInterval(poll); poll = null; }"),
    'the poll draws the machines step once the options are read');
  ok(/function renderChoose\([^)]*\) \{\s*if \(!targetAdvice\) \{ renderAdviceWait\(/.test(WIZ), 'the machines step waits only while no options are read');
  ok(/adviceOld = Boolean\(onAssessment && av && av\.doc\?\.schemaVersion !== TARGET_ADVICE_VERSION\);/.test(WIZ), 'an earlier version is known from the file itself');
});

test('Make while one runs: the page shows the service refusal, and the step waits again on success', () => {
  const from = WIZ.indexOf('function renderAdviceWait(');
  const body = WIZ.slice(from, WIZ.indexOf('\n}\n', from));
  ok(body.includes("paintAdviceView({ show: 'wait' });"), 'a start that worked shows the wait');
  ok(body.includes('catch (e) { failAction(e); $(\'#t-make\').disabled = false; }'), 'a refusal is shown, and Make can be pressed again');
});

// No spinner showed in the lab. The wait's markup is the wizard's own
// spinner, the one the scan and plan waits use, and the stylesheet draws it on
// this page: a 15 px ring, in a flex row the page does not hide.
test('the running state is the wizard spinner, and the stylesheet draws it on this page', async () => {
  const s = stage();
  globalThis.adviceOld = false; store({ [LOG]: [...scan, start].join('\n') });
  await fns.paintAdviceProgress();
  ok(s.w.innerHTML.startsWith('<span class="spin"></span>'), 'the spinner element comes first: ' + s.w.innerHTML);
  const from = WIZ.indexOf('function renderAdviceWait(');
  const wait = WIZ.slice(from, WIZ.indexOf('\n}\n', from));
  ok(wait.includes('<div class="working" id="t-wait"><span class="spin"></span>${esc(UX.tWaiting)}</div>'), 'the first draw has the spinner too');
  ok(WIZ.includes('<div class="working" id="wait"><span class="spin"></span>${esc(UX.s2Working)}</div>'), 'the same markup as the scan wait');
  ok(/<body class="p-wizard">/.test(fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'wizard.html'), 'utf8')), 'the page is p-wizard');
  const css = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'app.css'), 'utf8');
  const rule = (sel) => { const at = css.indexOf(sel + ' {'); return at < 0 ? '' : css.slice(at, css.indexOf('}', at)); };
  const spin = rule('.p-wizard .spin');
  ok(spin.includes('width:15px') && spin.includes('height:15px') && spin.includes('border:2px solid var(--brand)') && spin.includes('animation:sp '), 'the ring and its turn: ' + spin);
  ok(rule('.p-wizard .working').includes('display:flex'), 'the row is a flex row, so the empty span keeps its size');
  ok(!/display:\s*none|visibility:\s*hidden/.test(rule('.p-wizard .working') + spin), 'nothing hides it');
  ok(/@keyframes sp\s*\{/.test(css), 'the turn is defined');
});

run('target-options-wait');
