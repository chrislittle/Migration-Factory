/* PROGRESS-1: what the wizard says while a scan runs.
 *
 * The wizard watches with NO deadline, deliberately: a scan is a few Resource
 * Graph queries whatever the estate holds - a thousand machines is assessed in
 * minutes - so a long wait does not mean a big estate, it means something is
 * wrong. A spinner cannot tell those apart, and neither can the person
 * watching it.
 *
 * The engine already writes what is needed into the run log. This decides what
 * to show from it, and it is pure so every combination is RUN rather than
 * reasoned about.
 */
'use strict';
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const scanProgress = lift('wizard.html', 'scanProgress');

const ev = (outcome, extra) => Object.assign({ step: 'assessment', outcome }, extra || {});

test('nothing yet - the spinner keeps its own words', () => {
  eq(scanProgress([]), null, 'no events');
  eq(scanProgress([ev('start', { detail: 'subscriptions=a' })]), null, 'only a start marker');
});

test('once machines are found, say how many', () => {
  const r = scanProgress([ev('start'), ev('info', { discovered: 312 })]);
  eq(r.kind, 'found', 'kind');
  eq(r.count, 312, 'count');
});

test('A FAILURE BEATS EVERYTHING, because nothing else on screen is true after it', () => {
  const r = scanProgress([
    ev('info', { discovered: 312 }),
    ev('fail', { detail: 'AVD session-host membership could not be verified' }),
  ]);
  eq(r.kind, 'failed', 'kind');
  ok(r.detail.indexOf('AVD') >= 0, 'the reason is carried through');
});

test('and a failure that arrives BEFORE the count still wins', () => {
  // Order in the log must not decide this. The scan has stopped either way.
  const r = scanProgress([
    ev('fail', { detail: 'platform-managed groups could not be verified' }),
    ev('info', { discovered: 8 }),
  ]);
  eq(r.kind, 'failed', 'a later info does not revive a stopped scan');
});

test('A WARNING DOES NOT APPEAR HERE, and does not disturb the count', () => {
  /* The engine emits one non-fatal warning: it could not read the
   * accelerated-networking state, so the report will not mention it rather
   * than guess. That is a gap in the REPORT and it matters - but a person
   * watching a spinner wants to know the scan is alive, and a paragraph of
   * engine wording under it reads as a fault when nothing is wrong.
   *
   * So it is not shown here, AND it must not change what is. Report
   * completeness belongs where the report is read. */
  const r = scanProgress([
    ev('info', { discovered: 40 }),
    ev('warn', { detail: 'could not read accelerated-networking state' }),
  ]);
  eq(r.kind, 'found', 'still a count');
  eq(r.count, 40, 'count');
  eq(r.note, undefined, 'no note is produced at all');
});

test('the newest count wins', () => {
  const r = scanProgress([
    ev('info', { discovered: 10 }),
    ev('warn', { detail: 'first' }),
    ev('info', { discovered: 300 }),
  ]);
  eq(r.count, 300, 'the later count');
});

test('events from other steps are ignored', () => {
  // The run log carries every step. A plan failure is not a scan failure, and
  // showing it under the scan spinner would be a lie about what stopped.
  const r = scanProgress([
    { step: 'plan', outcome: 'fail', detail: 'something about the plan' },
    ev('info', { discovered: 5 }),
  ]);
  eq(r.kind, 'found', 'the plan event did not take over');
  eq(r.count, 5, 'count');
});

test('a count that is not a number is not a count', () => {
  /* The field is read instead of parsing "discovered 312 VMs" out of the
   * sentence, so the guard is that it really is a number - otherwise the
   * screen would say "Found undefined machines". */
  eq(scanProgress([ev('info', { discovered: '312' })]), null, 'a string');
  eq(scanProgress([ev('info', {})]), null, 'missing');
  eq(scanProgress([ev('info', { discovered: null })]), null, 'null');
});

test('rubbish in the log does not throw', () => {
  // The log is append-only text; a half-written line parses to anything.
  eq(scanProgress(null), null, 'no list at all');
  eq(scanProgress([null, undefined, {}, { step: 'assessment' }]), null, 'junk entries');
});

/* SCAN-FAIL-SHOWN-1: an error the scan does not catch is written by the engine
 * entrypoint under the step engine:assess, and a job that stopped with no line
 * at all gets the same line from the service's five-minute pass. The lab
 * sweep's scan waited for ever on "Looking for machines" because this read
 * only the step assessment. */
const eng = (outcome, extra) => Object.assign({ step: 'engine:assess', outcome }, extra || {});
const hosted = () => ({ step: 'engine', outcome: 'start', operation: 'assess', detail: 'hosted assess started by operator@example.com (execution exec-2)' });

test('SCAN-FAIL-SHOWN-1: an engine:assess fail line stops the wait, with its reason', () => {
  const r = scanProgress([ev('start'), eng('fail', { detail: 'The engine job execution exec-1 has the status Failed in Azure.' })]);
  eq(r.kind, 'failed', 'kind');
  ok(r.detail.indexOf('exec-1') >= 0, 'the reason is carried through');
});

test('SCAN-FAIL-SHOWN-1: an engine:assess refusal is an answer too', () => {
  eq(scanProgress([eng('refused', { detail: 'no scope' })]).kind, 'failed', 'refused');
});

test('SCAN-FAIL-SHOWN-1: the engine version line of engine:assess is not a failure', () => {
  eq(scanProgress([eng('info', { detail: 'Engine version 1 started the assess operation.' })]), null, 'info only');
  eq(scanProgress([eng('info'), ev('info', { discovered: 4 })]).kind, 'found', 'and the count still shows');
});

test('SCAN-FAIL-SHOWN-1: the engine line of another operation is not a scan line', () => {
  eq(scanProgress([{ step: 'engine:plan', outcome: 'fail', detail: 'x' }, { step: 'engine:advise', outcome: 'fail', detail: 'y' }]), null, 'plan and advise');
});

test('SCAN-FAIL-SHOWN-1: a scan started again in the same run forgets the earlier failure', () => {
  // Back, then Start looking, starts the scan again in the same run, and the
  // log keeps the first scan's fail line. Only lines after the newest start count.
  eq(scanProgress([eng('fail', { detail: 'old' }), hosted()]), null, 'the new scan has not answered yet');
  eq(scanProgress([ev('fail', { detail: 'old' }), ev('info', { discovered: 9 }), hosted()]), null, 'the old count goes too');
  const r = scanProgress([eng('fail', { detail: 'old' }), hosted(), ev('info', { discovered: 3 })]);
  eq(r.kind, 'found', 'the new count shows');
  eq(scanProgress([eng('fail', { detail: 'old' }), hosted(), eng('fail', { detail: 'new' })]).detail, 'new', 'the new failure shows');
});

test('SCAN-FAIL-SHOWN-1: the start line of another operation does not reset the scan', () => {
  const other = { step: 'engine', outcome: 'start', operation: 'plan', detail: 'hosted plan started by operator@example.com (execution exec-3)' };
  eq(scanProgress([eng('fail', { detail: 'kept' }), other]).kind, 'failed', 'a plan start is not a scan start');
});

const scanStoppedHtml = (() => {
  global.UX = { scanFailed: 'The scan stopped. {reason}', scanAgain: 'AGAIN', back: 'Back' };
  global.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  return lift('wizard.html', 'scanStoppedHtml');
})();

test('SCAN-FAIL-SHOWN-1: the stopped scan says why, says what to do, and offers Back', () => {
  const h = scanStoppedHtml('exec-1 has the status Failed <b>');
  ok(h.indexOf('The scan stopped. exec-1 has the status Failed &lt;b&gt;') >= 0, 'the reason, escaped: ' + h);
  ok(h.indexOf('AGAIN') >= 0, 'what to do');
  ok(/<button[^>]*id="scan-back"[^>]*>Back<\/button>/.test(h), 'a Back button');
  ok(h.indexOf('class="spin"') < 0, 'no spinner once it has stopped');
});

test('SCAN-FAIL-SHOWN-1: a reason with $& in it is shown as written', () => {
  ok(scanStoppedHtml('cost $& more').indexOf('cost $&amp; more') >= 0, 'no replacement pattern');
});

/* SCAN-FAIL-SHOWN-1 review: the stopped view is STATE. renderStep2 drew the
 * spinner again on any later render() of the step, with the poll already
 * cleared, so the page looked alive and never moved. */
const { extract } = require('./_harness');
const scanWait = (() => {
  global.UX.s2Working = 'Looking for machines.';
  return liftAll('wizard.html', ['scanStoppedHtml', 'scanWaitHtml']).scanWaitHtml;
})();

test('SCAN-FAIL-SHOWN-1 review: the wait shows the spinner until the scan stopped, then the stopped view', () => {
  const running = scanWait(null);
  ok(running.indexOf('class="spin"') >= 0 && running.indexOf('Looking for machines.') >= 0, 'running: ' + running);
  ok(running.indexOf('id="wait"') >= 0, 'the poll finds #wait');
  const stopped = scanWait('exec-1 has the status Failed');
  ok(stopped.indexOf('class="spin"') < 0, 'no spinner once stopped');
  ok(stopped.indexOf('The scan stopped. exec-1 has the status Failed') >= 0, 'the reason');
  ok(stopped.indexOf('id="scan-back"') >= 0 && stopped.indexOf('id="wait"') >= 0, 'Back, inside #wait');
  ok(scanWait('').indexOf('class="spin"') < 0, 'an empty reason is still a stop');
});

test('SCAN-FAIL-SHOWN-1 review: renderStep2 draws the wait from the state, paint keeps the state, a new start clears it', () => {
  const render2 = extract('wizard.html', 'renderStep2');
  ok(/scanWaitHtml\(scanStopped\)/.test(render2), 'renderStep2 reads scanStopped');
  ok(render2.indexOf('UX.s2Working') < 0, 'and has no spinner of its own');
  ok(/wireScanBack\(\)/.test(render2), 'and wires Back');
  const paint = extract('wizard.html', 'paintScanProgress');
  ok(/scanStopped = p\.detail;/.test(paint), 'the paint keeps the reason as state');
  const start = extract('wizard.html', 'startScan');
  ok(/scanStopped = null;/.test(start), 'a new start waits again');
});

run('scan-progress');
