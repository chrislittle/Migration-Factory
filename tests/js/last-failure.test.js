/* FAILSHOW-1, 2026-09-18. The page says when the last thing somebody asked for
 * did not work.
 *
 * THE DEFECT, on a live install. Two operations failed within the hour - a wave
 * that could not start because the run was never acknowledged, and a put-back
 * Azure refused for a missing permission - and in BOTH cases the banner whose
 * whole job is to say what happens next read:
 *
 *   "The plan is ready. Review the waves below, then approve and start the
 *    first one."
 *
 * It told the operator to do the thing that had just failed.
 *
 * renderNextStep had branches for not-scanned, not-planned, working and
 * planned. It had none for the one state where a person actually needs telling.
 *
 * AND THE REASON WAS ALREADY ON THE PAGE. The engine writes it into the run's
 * event log and the activity feed renders it - at the bottom of a long page,
 * under a banner giving confident, wrong advice. The owner read container logs
 * instead, twice, because nothing brought it up.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, liftAll, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

function pageString(name) {
  const m = PAGE.match(new RegExp(name + ": *'([^']*)'"));
  if (!m) { throw new Error('could not read UX_ACT.' + name + ' from the page'); }
  return m[1];
}

globalThis.UX_ACT = {
  nextFailedTitle: pageString('nextFailedTitle'),
  nextFailed: pageString('nextFailed'),
  nextFailedWave: pageString('nextFailedWave'),
  nextFailedRestore: pageString('nextFailedRestore'),
  nextFailedPlan: pageString('nextFailedPlan'),
  nextFailedAssess: pageString('nextFailedAssess'),
  nextFailedOther: pageString('nextFailedOther'),
  nextTitle: pageString('nextTitle'),
  nextPlanned: pageString('nextPlanned'),
  nextAllRan: pageString('nextAllRan'),
  nextRunning: pageString('nextRunning'),
  nextBetween: pageString('nextBetween'),
  nextNoPlan: pageString('nextNoPlan'),
  nextWorking: pageString('nextWorking'),
  nextNoRun: pageString('nextNoRun'),
  newRun: 'New migration',
  buildPlan: 'Build the plan',
  arrangeWaves: 'Arrange the waves',
  nextNoAccess: 'no access',
  nextFailedShow: pageString('nextFailedShow'),
  nextFailedHide: pageString('nextFailedHide'),
};

// MIGRATIONS-WORDS-LAB-1: renderNextStep asks scheduledFirstWave about a
// signed-off first wave with a start time; no wave here has a schedule.
globalThis.scheduledFirstWave = () => null;
// STOP-STATE-SHOWN-1: renderNextStep reads the record of a stop; none here.
globalThis.runStop = null;
globalThis.schedules = new Map(); globalThis.approvals = new Map(); globalThis.acceptances = new Map();
globalThis.planSignoff = null; globalThis.planSignoffCurrent = false; globalThis.runAcknowledged = () => true;
const banner = liftAll('migrations.html',
  // LAB-UX-1: renderNextStep asks settledAll whether every wave has run.
  ['lastEngineFailure', 'engineOperationName', 'splitFailure', 'settledAll', 'wavesInFlight', 'nextWaveButton', 'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck', 'waveStartRequested', 'nextStepSaid', 'renderNextStep']);
const splitFailure = lift('migrations.html', 'splitFailure');
const lastEngineFailure = lift('migrations.html', 'lastEngineFailure');

const at = (mins) => new Date(Date.now() - mins * 60000).toISOString();
const ev = (step, outcome, detail, mins) =>
  ({ step, outcome, detail, tsUtc: at(mins ?? 1) });

/** Draw the banner and return what it painted. */
function draw(events, opts) {
  const el = { innerHTML: '' };
  const wired = {};
  globalThis.failShown = Boolean(opts && opts.open);
  globalThis.$ = (sel) => (sel === '#nextstep' ? el
    : { addEventListener: (_, fn) => { wired[sel] = fn; } });
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.canOperate = () => true;
  globalThis.currentRun = 'proj/migration-1';
  globalThis.planDoc = (opts && opts.planned) ? { entries: [{ vmId: '/s/vm1' }] } : null;
  globalThis.VmfHelp = { VmfRun: { link: (p) => p }, ...liftAll('help.js', ['machineStarted', 'machineHold', 'machineAtWork', 'waveHold', 'idKey']) };
  // WAVE-RUNNING-LEASE-1: no machine of these runs has a lease.
  globalThis.leaseOf = () => undefined;
  globalThis.latestEvents = events;
  globalThis.latestHalted = false;   // BRAKE-WAIT-WORDS-1
  globalThis.allVms = [];
  globalThis.SETTLED_STATES = ['MIGRATED', 'SKIPPED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION'];
  globalThis.NOT_STARTED_STATE = 'PLANNED';
  banner.renderNextStep(events);
  return el.innerHTML;
}

/* ---- which failure counts --------------------------------------------- */

test('a wave that failed is the failure to report', () => {
  const f = lastEngineFailure([ev('engine:wave', 'fail', 'This run has not been acknowledged')]);
  ok(f, 'a failure was found');
  eq(f.step, 'engine:wave');
});

test('a wave that failed and was then started is NOT a failure any more', () => {
  /* The same defect pointing the other way: a page that kept shouting about a
   * failure somebody had already dealt with. Only the LATEST event of each
   * operation counts. */
  eq(lastEngineFailure([
    ev('engine:wave', 'fail', 'not acknowledged', 30),
    ev('engine:wave', 'ok', 'wave finished', 5),
  ]), null);
});

test('the newest failure wins when two different operations failed', () => {
  const f = lastEngineFailure([
    ev('engine:wave', 'fail', 'not acknowledged', 40),
    ev('engine:restore', 'fail', 'LinkedAuthorizationFailed', 3),
  ]);
  eq(f.step, 'engine:restore');
});

test('an operation that failed stays reported while a DIFFERENT one succeeds', () => {
  /* A restore that failed is still broken after a wave runs fine. Grouping by
   * operation is what makes that true. */
  const f = lastEngineFailure([
    ev('engine:restore', 'fail', 'LinkedAuthorizationFailed', 30),
    ev('engine:wave', 'ok', 'wave finished', 2),
  ]);
  eq(f.step, 'engine:restore');
});

test('a failure with no reason is not reported, because there is nothing to say', () => {
  eq(lastEngineFailure([ev('engine:wave', 'fail', '')]), null);
  eq(lastEngineFailure([ev('engine:wave', 'fail', null)]), null);
});

test('nothing, no events and rubbish all read as no failure', () => {
  eq(lastEngineFailure([]), null);
  eq(lastEngineFailure(null), null);
  eq(lastEngineFailure([ev('SAFETY_COPY', 'fail', 'not an engine step')]), null);
  eq(lastEngineFailure([null, undefined, {}]), null);
});

/* ---- what the operator is told ---------------------------------------- */

test('THE REGRESSION: a failed wave no longer reads as ready to start', () => {
  const html = draw([ev('engine:wave', 'fail', 'This run has not been acknowledged')],
                    { planned: true });
  ok(html.includes(UX_ACT.nextFailedTitle), 'it says the last action did not work');
  ok(!html.includes(UX_ACT.nextPlanned),
     'and no longer tells somebody to start the wave that just failed');
});

test('the reason the engine gave is shown, word for word', () => {
  /* It was already in the run log and rendered at the bottom of the page. What
   * was missing was anything bringing it up. */
  const why = 'This run has not been acknowledged: someone has to accept that first';
  const html = draw([ev('engine:wave', 'fail', why)], { planned: true });
  ok(html.includes(why), 'the engine sentence, not a summary of it');
});

test('the operation is named, because "it failed" is what they can already see', () => {
  const wave = draw([ev('engine:wave', 'fail', 'x')], { planned: true });
  const rest = draw([ev('engine:restore', 'fail', 'x')], { planned: true });
  ok(wave.includes(UX_ACT.nextFailedWave), 'a wave says so');
  ok(rest.includes(UX_ACT.nextFailedRestore), 'a put-back says so');
  ok(wave !== rest, 'and they do not read the same');
});

test('an operation with no name of its own still reads as a sentence', () => {
  const html = draw([ev('engine:retention', 'fail', 'x')], { planned: true });
  ok(html.includes(UX_ACT.nextFailedOther), 'a fallback, never the raw step name');
  ok(!html.includes('engine:retention'), 'the internal name is not shown');
});

test('the banner is marked as an alert, so it does not read as ordinary advice', () => {
  const html = draw([ev('engine:wave', 'fail', 'x')], { planned: true });
  ok(html.includes('alert'), 'it looks different from the usual next-step card');
});

test('with nothing failed, the page gives its normal advice', () => {
  /* The other half. A guard that swallowed the normal path would pass every
   * test above and leave the page blank in the ordinary case. */
  const html = draw([ev('engine:wave', 'ok', 'wave finished')], { planned: true });
  ok(html.includes(UX_ACT.nextPlanned), 'the usual guidance is still there');
  ok(!html.includes(UX_ACT.nextFailedTitle));
});

/* ---- FAILBRIEF-1: a wall of Azure output reads as a sentence ------------ */

/* The put-back refusal, as it actually arrived on a live install. Azure repeats
 * its own message in a second field, so the same three hundred characters
 * appear twice, with two client ids and an operation id between them. The ids
 * are redacted to placeholders (HEAD-SCRUB-1); the shape and length are kept. */
const REAL = "The restore did not complete: The client 'cccc0c0c-0000-0000-0000-000000000001' "
  + "with object id '11111111-2222-3333-4444-555555555555' has permission to perform action "
  + "'Microsoft.Compute/disks/write' on scope '/subscriptions/x/disks/y-restored'; however, it "
  + "does not have permission to perform action(s) 'Microsoft.Compute/disks/beginGetAccess/action' "
  + "on the linked scope(s) '/subscriptions/x/snapshots/z-prist' (respectively) or the linked "
  + "scope(s) are invalid. ErrorCode: LinkedAuthorizationFailed ErrorMessage: The client "
  + "'cccc0c0c-0000-0000-0000-000000000001' ... StatusCode: 403 ReasonPhrase: Forbidden "
  + "OperationID : 00000000. The machine has been restarted and is running on disk 'y'.";

test('THE REGRESSION: the banner shows a sentence, not the whole dump', () => {
  const html = draw([ev('engine:restore', 'fail', REAL)], { planned: true });
  ok(html.includes('The restore did not complete'), 'the summary is there');
  ok(!html.includes('ReasonPhrase'), 'and the machine detail is not in the first read');
  ok(html.length < 1200, `the banner is readable, not a wall (${html.length} characters)`);
});

test('nothing is dropped - the rest is one button away', () => {
  const shut = draw([ev('engine:restore', 'fail', REAL)], { planned: true });
  ok(shut.includes(UX_ACT.nextFailedShow), 'it offers the whole reason');
  const open = draw([ev('engine:restore', 'fail', REAL)], { planned: true, open: true });
  ok(open.includes('ReasonPhrase'), 'and shows it when asked');
  ok(open.includes('LinkedAuthorizationFailed'), 'all of it');
});

test('and the button says how to put it away again', () => {
  /* Rule 11: anything that opens offers a way back. One button, two states. */
  const open = draw([ev('engine:restore', 'fail', REAL)], { planned: true, open: true });
  ok(open.includes(UX_ACT.nextFailedHide), 'the same button closes it');
  ok(!open.includes(UX_ACT.nextFailedShow));
});

test('a reason that IS one sentence offers no button at all', () => {
  /* The acknowledgement refusal reads perfectly as written. A "show more" for
   * nothing is noise. */
  const oneLine = 'This run has not been acknowledged: someone has to accept it first';
  const html = draw([ev('engine:wave', 'fail', oneLine)], { planned: true });
  ok(html.includes(oneLine), 'the whole thing is shown');
  ok(!html.includes(UX_ACT.nextFailedShow), 'and nothing is hidden');
});

test('the split is about English, not about any error format', () => {
  eq(splitFailure('One thing failed. Then the detail.').first, 'One thing failed.');
  eq(splitFailure('One thing failed. Then the detail.').rest, 'Then the detail.');
  // Not cut at an early full stop that leaves no sentence.
  eq(splitFailure('v1.2.3 of the engine could not start the wave. Here is why.').first,
     'v1.2.3 of the engine could not start the wave.');
  // Nothing to split.
  eq(splitFailure('It failed.').rest, '');
  eq(splitFailure('').first, '');
  eq(splitFailure(null).first, '');
  eq(splitFailure(undefined).rest, '');
});

run('last failure');
