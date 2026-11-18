/* MIGRATIONS-WORDS-LAB-1: What happens next names a signed-off wave that waits
 * for its scheduled start.
 *
 * Final lab, 2026-11-13. An operator signed off the plan, and the first wave
 * got a start time. The wave card said "Scheduled for ..." with Cancel the
 * scheduled start, and What happens next still said "The plan is ready.
 * Review the waves below, then approve and start the first one." Nothing was
 * left to approve, and the card showed no Start this wave: the card hides it
 * while a schedule waits (waveStartHtml asks !o.sched).
 *
 * The approved words, exact:
 *   "{wave} is signed off. It starts by itself at {time}. To start it now,
 *    select Cancel the scheduled start, then select Start this wave."
 * {time} is the time the wave card shows (scheduleTimeText, from the same
 * schedule document), and "signed off" is what the card's approval chip says:
 * the wave's own approval, or a sign-off of the plan version on screen.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['waveOrder']));
globalThis.planRunOrder = lift('migrations.html', 'planRunOrder');
globalThis.acceptanceRefused = lift('migrations.html', 'acceptanceRefused');
const fns = liftAll('migrations.html', ['scheduleTimeText', 'waveScheduleHtml', 'scheduledFirstWave', 'nextStepSaid']);
const A = globalThis.UX_ACT;

const WORDS = '{wave} is signed off. It starts by itself at {time}. To start it now, select Cancel the scheduled start, then select Start this wave.';
const RUN_AT = '2026-11-14T02:00:00Z';
const plan = { waveOrder: ['wave-1', 'wave-2'], entries: [
  { vmId: '/subscriptions/x/vm/a', wave: 'wave-1', path: 'A' },
  { vmId: '/subscriptions/x/vm/b', wave: 'wave-2', path: 'A' },
] };
const pending = { wave: 'wave-1', runAtUtc: RUN_AT, scheduledBy: 'operator@example.com', state: 'pending' };
const acc = { wave: 'wave-1', acceptedBy: 'operator@example.com', acceptedUtc: '2026-11-13T10:00:00Z' };
const appr = { approvedBy: { identity: 'approver@example.com' }, approvedUtc: '2026-11-13T11:00:00Z' };
const base = () => ({
  plan,
  schedules: new Map([['wave-1', pending]]),
  approvals: new Map(),
  acceptances: new Map([['wave-1', acc]]),
  planCovers: true,
  acknowledged: true,
  halted: false,
  events: [],
});
const said = (o, extra) => fns.nextStepSaid(Object.assign({ ran: false, inFlight: false, onlyWaiting: false, starting: false, begun: false, halted: false }, extra, { scheduled: fns.scheduledFirstWave(o) }));
const expected = WORDS.replace('{wave}', 'wave-1').replace('{time}', new Date(RUN_AT).toLocaleString());

// ---- The words ----

test('the words are the approved text, exact, and name the real buttons', () => {
  eq(A.nextScheduled, WORDS);
  ok(A.nextScheduled.includes(`select ${A.cancelSchedule},`), 'the button on the wave card: Cancel the scheduled start');
  ok(A.nextScheduled.includes(`select ${A.startWave}.`), 'the button that comes after it: Start this wave');
  eq(A.cancelSchedule, 'Cancel the scheduled start');
  eq(A.startWave, 'Start this wave');
});

test('the old line stays for a plan that is not signed off', () => {
  eq(A.nextPlanned, 'The plan is ready. Review the waves below, then approve and start the first one.');
});

// ---- The time: the card's own ----

test('RUN: the time is the one the wave card shows', () => {
  eq(fns.scheduleTimeText(pending), new Date(RUN_AT).toLocaleString());
  const chip = fns.waveScheduleHtml('wave-1', pending, true).chip;
  ok(chip.includes(fns.scheduleTimeText(pending)), `the card shows the same time: ${chip}`);
});

// ---- When it is said ----

test('RUN: a signed-off plan whose first wave waits for its scheduled start says so', () => {
  eq(said(base()), expected);
});

test('RUN: the wave\'s own approval is a sign-off too', () => {
  const o = Object.assign(base(), { planCovers: false, approvals: new Map([['wave-1', appr]]) });
  eq(said(o), expected);
});

test('RUN: a plan not signed off and a wave not approved keeps the old line', () => {
  const o = Object.assign(base(), { planCovers: false });
  eq(fns.scheduledFirstWave(o), null);
  eq(said(o), A.nextPlanned);
});

test('RUN: no schedule keeps the old line', () => {
  const o = Object.assign(base(), { schedules: new Map() });
  eq(said(o), A.nextPlanned);
});

test('RUN: a schedule of a later wave is not the first wave\'s', () => {
  const o = Object.assign(base(), { schedules: new Map([['wave-2', Object.assign({}, pending, { wave: 'wave-2' })]]),
    acceptances: new Map([['wave-1', acc], ['wave-2', Object.assign({}, acc, { wave: 'wave-2' })]]) });
  eq(fns.scheduledFirstWave(o), null);
});

test('RUN: the first wave is the plan\'s wave order, not the order of the schedules', () => {
  const both = new Map([['wave-1', pending], ['wave-2', Object.assign({}, pending, { wave: 'wave-2' })]]);
  const accs = new Map([['wave-1', acc], ['wave-2', Object.assign({}, acc, { wave: 'wave-2' })]]);
  const o = Object.assign(base(), { schedules: both, acceptances: accs, plan: Object.assign({}, plan, { waveOrder: ['wave-2', 'wave-1'] }) });
  eq(fns.scheduledFirstWave(o).wave, 'wave-2');
});

test('RUN: a schedule whose start is on record does not wait any more', () => {
  for (const state of ['starting', 'started']) {
    const o = Object.assign(base(), { schedules: new Map([['wave-1', Object.assign({}, pending, { state })]]) });
    eq(fns.scheduledFirstWave(o), null, state);
  }
  // A schedule written before the state field waits, as the card says.
  // A schedule with no time gives no time to say.
  const noTime = Object.assign({}, pending); delete noTime.runAtUtc;
  eq(fns.scheduledFirstWave(Object.assign(base(), { schedules: new Map([['wave-1', noTime]]) })), null, 'no time');
  const old = Object.assign({}, pending); delete old.state;
  eq(said(Object.assign(base(), { schedules: new Map([['wave-1', old]]) })), expected);
});

test('RUN: a start the engine refuses is not promised - no acceptance, a refused one, no acknowledgement, the brake', () => {
  eq(fns.scheduledFirstWave(Object.assign(base(), { acceptances: new Map() })), null, 'no acceptance');
  const refused = [{ step: 'acceptance', outcome: 'refused', code: 'optionsChanged', wave: 'wave-1', tsUtc: '2026-11-13T12:00:00Z' }];
  eq(fns.scheduledFirstWave(Object.assign(base(), { events: refused })), null, 'acceptance refused');
  eq(fns.scheduledFirstWave(Object.assign(base(), { acknowledged: false })), null, 'not acknowledged');
  eq(fns.scheduledFirstWave(Object.assign(base(), { halted: true })), null, 'the wave safety brake');
});

test('RUN: a schedule with a window is not promised - the service holds a wave that does not fit, and the page cannot judge the fit', () => {
  // The service's scheduled start asks Test-VmfWaveWindow when windowMinutes
  // is set (FacadeCore), and holds the wave when it will not fit.
  const windowed = Object.assign({}, pending, { windowMinutes: 120 });
  const o = Object.assign(base(), { schedules: new Map([['wave-1', windowed]]) });
  eq(fns.scheduledFirstWave(o), null, 'a window');
  eq(said(o), A.nextPlanned, 'the old line');
  // No window - null or 0, as the service reads it - is still promised.
  for (const w of [null, 0]) {
    eq(said(Object.assign(base(), { schedules: new Map([['wave-1', Object.assign({}, pending, { windowMinutes: w })]]) })), expected, String(w));
  }
});

test('RUN: once anything has begun, or a wave runs or starts, the line is the one for that', () => {
  eq(said(base(), { begun: true }), A.nextBetween);
  eq(said(base(), { inFlight: true }), A.nextRunning);
  eq(said(base(), { starting: true }), A.nextStarting);
  eq(said(base(), { ran: true }), A.nextAllRan);
});

// ---- The banner gives it the page's own documents ----

test('the banner gives scheduledFirstWave the documents the wave cards read', () => {
  const m = PAGE.match(/scheduled: scheduledFirstWave\(\{([^}]*)\}\)/);
  ok(m, 'renderNextStep passes scheduled: scheduledFirstWave({...})');
  for (const part of ['plan: planDoc', 'schedules', 'approvals', 'acceptances', 'acknowledged: runAcknowledged()', 'halted: latestHalted', 'events: latestEvents',
    'planCovers: Boolean(planSignoff && planSignoffCurrent)']) {
    ok(m[1].includes(part), `passes ${part}: ${m[1]}`);
  }
  ok(/function waveScheduleHtml[\s\S]*?scheduleTimeText\(sched\)/.test(PAGE), 'the wave card uses the same time');
});

run('migrations-words-lab');
