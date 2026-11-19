/* SCHEDULE-START-SHOWN-1: the Migrations page showed a schedule whose start
 * was on record as still scheduled.
 *
 * SCHEDULE-START-ONCE-1 keeps the start in the schedule document (state
 * 'starting' or 'started') until the service's schedule pass removes it - at
 * once, or on the next pass. The page showed every schedule document as
 * "Scheduled for" with "Cancel the scheduled start", and a cancel then got the
 * service's refusal (409): the wave started, or is starting
 * (Get-VmfScheduleStartRefusal refuses a cancel for 'starting' and 'started').
 *
 * The page now asks the state (schemas/wave-schedule.schema.json): a pending
 * schedule - or one written before the state field - shows "Scheduled for"
 * and the cancel; a start on record shows that the wave is starting, with no
 * cancel.
 *
 * RUN, not read: the page's own function.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
const A = globalThis.UX_ACT;
// MIGRATIONS-WORDS-LAB-1: the card's time comes from scheduleTimeText.
const html = liftAll('migrations.html', ['scheduleTimeText', 'waveScheduleHtml']).waveScheduleHtml;

const base = { schemaVersion: 1, wave: 'w1', runAtUtc: '2026-11-07T02:00:00Z', scheduledUtc: '2026-11-06T20:00:00Z',
  scheduledBy: 'operator@example.com', note: 'change window', windowMinutes: null };
const pending = Object.assign({}, base, { state: 'pending' });
const starting = Object.assign({}, base, { state: 'starting', startId: '0123456789abcdef0123456789abcdef',
  startingUtc: '2026-11-07T02:01:00Z', executions: [], startedUtc: null });
const started = Object.assign({}, starting, { state: 'started', executions: ['vmf-engine-abc12'], startedUtc: '2026-11-07T02:02:00Z' });
const cancelAttr = 'data-cancelsched="w1"';

test('RUN: no schedule shows nothing', () => {
  const r = html('w1', null, true);
  eq(r.chip, '', 'no chip');
  eq(r.cancel, '', 'no cancel');
});

test('RUN: a pending schedule shows Scheduled for, the time and who set it, and the cancel', () => {
  const r = html('w1', pending, true);
  ok(r.chip.includes(A.scheduledFor), `chip says Scheduled for: ${r.chip}`);
  ok(r.chip.includes('operator@example.com'), 'chip names who set it');
  ok(!r.chip.includes(A.scheduleStarting), 'a pending schedule does not say the wave is starting');
  ok(r.cancel.includes(cancelAttr), `cancel offered: ${r.cancel}`);
  ok(r.cancel.includes(A.cancelSchedule), 'the cancel has its words');
});

test('RUN: a schedule written before the state field is pending - the service lets a cancel through', () => {
  const r = html('w1', base, true);
  ok(r.chip.includes(A.scheduledFor), 'chip says Scheduled for');
  ok(r.cancel.includes(cancelAttr), 'cancel offered');
});

test('RUN: a starting schedule says the wave is starting, and offers no cancel the service refuses', () => {
  const r = html('w1', starting, true);
  ok(r.chip.includes(A.scheduleStarting), `chip says the wave is starting: ${r.chip}`);
  ok(!r.chip.startsWith(`<span class="pill warn" title="change window">${A.scheduledFor}`), 'not shown as a schedule that waits');
  eq(r.cancel, '', 'no cancel while a start is on record');
});

test('RUN: a started schedule says the wave is starting, and offers no cancel', () => {
  const r = html('w1', started, true);
  ok(r.chip.includes(A.scheduleStarting), `chip says the wave is starting: ${r.chip}`);
  eq(r.cancel, '', 'no cancel while a start is on record');
});

// SCHEDULE-STARTING-STUCK-1: a start record a check stopped is put back to
// pending by the service (Reset-VmfScheduleStartRecord). The fixture is that
// document, held to the service's write by WaveScheduleContract.Tests.ps1.
test('RUN: a schedule the service put back after a check stopped its start shows the cancel again', () => {
  const putBack = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, '..', 'fixtures', 'wave-schedule-put-back.json'), 'utf8'));
  const r = html('w1', putBack, true);
  ok(r.chip.includes(A.scheduledFor), `chip says Scheduled for: ${r.chip}`);
  ok(!r.chip.includes(A.scheduleStarting), 'it does not say the wave is starting');
  ok(r.cancel.includes(cancelAttr), `cancel offered: ${r.cancel}`);
});

test('RUN: a person who cannot operate sees the schedule and no cancel', () => {
  const r = html('w1', pending, false);
  ok(r.chip.includes(A.scheduledFor), 'chip shown');
  eq(r.cancel, '', 'no cancel without the operator role');
});

test('the starting words are a sentence of their own, in the product\'s words for a wave that is starting', () => {
  eq(A.scheduleStarting, 'The wave is starting.', 'the words the page already uses after Start (doneWave)');
  ok(A.doneWave.startsWith(A.scheduleStarting), 'one phrase for one thing');
});

run('schedule-start-shown');
