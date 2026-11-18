/* WAVE-ORDER-START-1: the Migrations page offered Start on the wrong wave.
 *
 * Lab Session A, 2026-11-04, twice. The waves were made in the wave editor:
 * new-wave first, then new-wave-2. The wizard's Run it page said "1. new-wave
 * starts now, 2. new-wave-2 starts when new-wave finishes", and the engine ran
 * new-wave first. The Migrations page showed Start this wave on new-wave-2,
 * and new-wave as "Starts when new-wave-2 finishes". A person who pressed it
 * ran the waves in the wrong order.
 *
 * THE CAUSE: the page drew its waves in the plan's order (VmfHelp.waveOrder -
 * the plan's own waveOrder, WAVE-ORDER-1), and decided their START LINES from
 * a second rule of its own (planRunOrder), which read the order the machines
 * first appear in. The machines are sorted by name, so a wave whose machine
 * sorts first was "first" there. One page, two orders.
 *
 * And the lines around it (findings 11, 17, 24, 40):
 *   - right after Start, the first wave offered Start again, and the timer said
 *     "the first wave starts when somebody starts it";
 *   - after a decision, the machine said Checking and the page "A wave is
 *     running now" for the four minutes until the service's next check;
 *   - the note named the check, not what a person waits for.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const WUX = liftConst('wizard.html', 'UX');
globalThis.esc = (s) => String(s ?? '');
globalThis.canOperate = () => true;
globalThis.isUnplannedWave = () => false;
globalThis.planRunStatus = null;
globalThis.soonHelpOpen = new Set();
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['waveOrder', 'idKey', 'machineHold', 'machineAtWork', 'waveHold']));
// WAVE-RUNNING-LEASE-1: no machine of these runs has a lease.
globalThis.leaseOf = () => undefined;
globalThis.planRunOrder = lift('migrations.html', 'planRunOrder');
globalThis.planFollowText = lift('migrations.html', 'planFollowText');
const card = liftAll('migrations.html', ['settledAll', 'vmStateOf', 'startsSoonHtml', 'waveStartHtml']);
const M = globalThis.UX_MISC;
const A = globalThis.UX_ACT;

// The lab plan's shape: the editor made new-wave first, and new-wave-2's
// machine sorts BEFORE new-wave's machines, so it comes first in the entries.
const W1 = [{ vmId: '/s/rg/vm/l26-w3', wave: 'new-wave', path: 'A' }, { vmId: '/s/rg/vm/l26-w4', wave: 'new-wave', path: 'A' }];
const W2 = [{ vmId: '/s/rg/vm/l26-a1', wave: 'new-wave-2', path: 'A' }];
const LAB = { waveOrder: ['new-wave', 'new-wave-2'], entries: [...W2, ...W1] };
const signed = { planCovers: true, waveWorking: false, waveDone: false, halted: false, sched: null, startBlockedBy: null };
const startBtn = 'data-start="new-wave"';

test('RUN: the start lines use the plan\'s wave order - the order the page draws and the engine runs', () => {
  eq(planRunOrder(LAB).join(','), 'new-wave,new-wave-2', 'the editor\'s order, not the order of the machines');
  eq(planRunOrder(LAB).join(','), VmfHelp.waveOrder(LAB).join(','), 'one order for the cards and their lines');
});

test('RUN: a plan with no waveOrder still runs in the order its waves first appear', () => {
  const plan = { entries: [{ vmId: 'z1', wave: 'zulu', path: 'A' }, { vmId: 'a1', wave: 'alpha', path: 'A' },
    { vmId: 'x1', wave: 'unscheduled', path: 'A' }, { vmId: 'q1', wave: 'manual', path: 'MANUAL' }] };
  eq(planRunOrder(plan).join(','), 'zulu,alpha', 'unscheduled and MANUAL waves never run');
});

test('RUN: a wave in the waveOrder with no machine the engine moves is not in the run order', () => {
  const plan = { waveOrder: ['manual', 'w1'], entries: [{ vmId: 'q1', wave: 'manual', path: 'MANUAL' }, { vmId: 'a', wave: 'w1', path: 'A' }] };
  eq(planRunOrder(plan).join(','), 'w1', 'the engine\'s Get-VmfPlanWaveOrder counts paths A and B only');
});

test('RUN: queued, the two-wave plan offers Start on new-wave and says new-wave-2 waits for it', () => {
  globalThis.planDoc = LAB;
  globalThis.allVms = [];
  globalThis.latestEvents = [];
  const first = card.waveStartHtml('new-wave', W1, signed);
  ok(first.includes(startBtn), `new-wave has the Start button: ${first}`);
  const second = card.waveStartHtml('new-wave-2', W2, signed);
  ok(!second.includes('data-start'), `no Start on new-wave-2: ${second}`);
  ok(second.includes(M.startsAfter.replace('{wave}', 'new-wave')), `new-wave-2 starts when new-wave finishes: ${second}`);
});

test('RUN: while new-wave runs, new-wave-2 says it starts when new-wave finishes - as the line between the waves does', () => {
  globalThis.planDoc = LAB;
  globalThis.allVms = [{ vmId: '/s/rg/vm/l26-w3', state: 'CONVERTING' }];
  const second = card.waveStartHtml('new-wave-2', W2, signed);
  ok(second.includes(M.startsAfter.replace('{wave}', 'new-wave')), second);
  ok(!second.includes(M.startsSoon), 'not "starts soon" while the wave before it runs');
  ok(/Each wave starts when the wave before it in the plan finishes/.test(M.gateTextPlan), 'the line between the waves says the same rule');
  globalThis.allVms = [];
});

// ---- After Start: the wave starts, and the page says so (finding 11) ----

const waveStartRequested = lift('migrations.html', 'waveStartRequested');
const NOW = Date.parse('2026-11-04T16:30:00Z');
const at = (min) => new Date(NOW - min * 60000).toISOString();
const startLine = (wave, min, extra) => Object.assign({ tsUtc: at(min), step: 'engine', outcome: 'start', operation: 'wave', wave,
  detail: 'hosted wave started by operator@example.com (execution exec-1)' }, extra);

test('RUN: a start of the wave that the service took a minute ago is a start on its way', () => {
  eq(waveStartRequested('new-wave', [startLine('new-wave', 1)], NOW), true);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 1, { outcome: 'warn' })], NOW), true, 'a part start also starts');
});

test('RUN: a start of another wave, of another operation, or with no wave is not this wave\'s', () => {
  eq(waveStartRequested('new-wave', [startLine('new-wave-2', 1)], NOW), false);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 1, { operation: 'restore' })], NOW), false);
  eq(waveStartRequested('new-wave', [startLine(undefined, 1)], NOW), false, 'a line from before this item names no wave');
});

test('RUN: a start that the engine refused, or that ended, is not on its way', () => {
  eq(waveStartRequested('new-wave', [startLine('new-wave', 3), { tsUtc: at(2), step: 'engine', outcome: 'fail', detail: 'refused' }], NOW), false);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 3), { tsUtc: at(2), step: 'wave', outcome: 'fail', wave: 'new-wave' }], NOW), false);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 3), { tsUtc: at(2), step: 'capacity', outcome: 'refused', wave: 'new-wave' }], NOW), false);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 3), { tsUtc: at(2), step: 'wave', outcome: 'ok', wave: 'new-wave' }], NOW), false);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 3), { tsUtc: at(2), step: 'wave', outcome: 'start', wave: 'new-wave' }], NOW), true,
    'the engine began the wave and has not taken a machine yet: still on its way');
  eq(waveStartRequested('new-wave', [{ tsUtc: at(4), step: 'engine', outcome: 'fail' }, startLine('new-wave', 3)], NOW), true,
    'a refusal BEFORE the start does not end it');
});

test('RUN: a start older than ten minutes is no longer said to be on its way - Start comes back', () => {
  eq(waveStartRequested('new-wave', [startLine('new-wave', 9)], NOW), true);
  eq(waveStartRequested('new-wave', [startLine('new-wave', 11)], NOW), false);
});

test('RUN: after Start, the wave says it starts, and offers no second Start', () => {
  globalThis.planDoc = LAB;
  globalThis.allVms = [];
  const html = card.waveStartHtml('new-wave', W1, Object.assign({}, signed, { starting: true }));
  ok(!html.includes('data-start'), `no second Start: ${html}`);
  ok(html.includes(M.startsSoon), html);
  const unsigned = card.waveStartHtml('new-wave', W1, Object.assign({}, signed, { planCovers: false, starting: true }));
  ok(!unsigned.includes('data-start') && unsigned.includes(M.startsSoon), `a wave started by hand on a plan nobody signed: ${unsigned}`);
  const later = card.waveStartHtml('new-wave', W1, signed);
  ok(later.includes(startBtn), 'and without a start on its way, Start is there');
});

test('the wave card asks it of the events, for each wave', () => {
  ok(/const starting = waveStartRequested\(wave, latestEvents, Date\.now\(\)\);/.test(PAGE), 'asked per wave');
  ok(/waveStartHtml\(wave, info\.entries, \{[^}]*\bstarting\b/.test(PAGE), 'and handed to the start control');
});

// ---- The words (finding 24) ----

test('the line says when a wave starts, and the note says it can take longer', () => {
  eq(M.startsSoon, 'Starts within about 5 minutes');
  ok(/When many migrations wait, it can take longer\./.test(M.startsSoonHelp), M.startsSoonHelp);
  ok(!/one check does not get to all of them/.test(M.startsSoonHelp), 'not the service\'s inner workings');
});

test('the wizard says the same as the Migrations page', () => {
  eq(WUX.howCheckHelp, M.startsSoonHelp, 'the (?) beside "Run it all now"');
  ok(/within about 5 minutes/.test(WUX.howAllHint), WUX.howAllHint);
  ok(WIZ.length > 0);
});

// ---- After a decision: waits for the service's next check (finding 17) ----

const awaitsServiceCheck = liftAll('migrations.html', ['awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords']).awaitsServiceCheck;
const VM = '/s/rg/vm/l26-w3';
const rearmed = (state) => ({ vmId: VM, state, history: [
  { tsUtc: at(10), state: 'NEEDS_DECISION', outcome: 'fail' },
  { tsUtc: at(3), state, outcome: 'ok', detail: 'Decision resolved by operator@example.com: go on. The machine goes back to Checking.' }] });
const decided = (state, min = 3) => ({ tsUtc: at(min), step: 'decision', outcome: 'ok', vmId: VM, returnTo: state, detail: 'resolved' });

test('RUN: a machine a decision sent back to Checking, that no engine took yet, waits for the service', () => {
  eq(awaitsServiceCheck(rearmed('PRECHECK'), [decided('PRECHECK')]), true);
  eq(awaitsServiceCheck(rearmed('VALIDATING'), [decided('VALIDATING')]), true, 'and back to Verifying');
});

test('RUN: once a worker takes it, or anything of the engine acts on it, it is at work', () => {
  eq(awaitsServiceCheck(rearmed('PRECHECK'), [decided('PRECHECK'), { tsUtc: at(1), step: 'worker', outcome: 'info', vmId: VM, detail: 'leased by worker-1' }]), false);
  eq(awaitsServiceCheck(rearmed('PRECHECK'), [decided('PRECHECK'), { tsUtc: at(1), step: 'resume', outcome: 'warn', vmId: VM }]), false);
  eq(awaitsServiceCheck(rearmed('PRECHECK'), [decided('PRECHECK'), { tsUtc: at(1), step: 'worker', outcome: 'info', vmId: VM.toUpperCase() }]), false,
    'in any letter case of the ID');
});

test('RUN: a machine with no decision line, a later step, or another state is not waiting for the service', () => {
  eq(awaitsServiceCheck(rearmed('PRECHECK'), []), false, 'no decision line: the page says what it said before');
  eq(awaitsServiceCheck(rearmed('PRECHECK'), [decided('VALIDATING')]), false, 'the decision sent it elsewhere');
  eq(awaitsServiceCheck(rearmed('PRECHECK'), [decided('PRECHECK', 20)]), false, 'an older decision, before this step');
  eq(awaitsServiceCheck(Object.assign(rearmed('PRECHECK'), { state: 'SAFETY_PRISTINE' }), [decided('PRECHECK')]), false, 'the move went on');
  eq(awaitsServiceCheck(null, [decided('PRECHECK')]), false);
});

test('RUN: only Checking and Verifying are states a decision sends a machine back to', () => {
  const stopped = { vmId: VM, state: 'STOPPED', history: [{ tsUtc: at(3), state: 'STOPPED', outcome: 'ok' }] };
  eq(awaitsServiceCheck(stopped, [decided('STOPPED')]), false);
});

test('RUN: the state must be the one the last step of its history wrote', () => {
  const unwritten = { vmId: VM, state: 'PRECHECK', history: [{ tsUtc: at(3), state: 'NEEDS_DECISION', outcome: 'fail' }] };
  eq(awaitsServiceCheck(unwritten, [decided('PRECHECK')]), false);
});

const waitingOnlyForCheck = liftAll('migrations.html', ['awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck']).waitingOnlyForCheck;

test('RUN: a wave waits for the service only when every machine at work in it waits', () => {
  const other = { vmId: '/s/rg/vm/l26-w4', state: 'CONVERTING', history: [{ tsUtc: at(1), state: 'CONVERTING', outcome: 'ok' }] };
  const done = { vmId: '/s/rg/vm/l26-w4', state: 'MIGRATED', history: [{ tsUtc: at(30), state: 'MIGRATED', outcome: 'ok' }] };
  const docs = (...d) => (id) => d.find(x => x.vmId === id);
  eq(waitingOnlyForCheck(W1, docs(rearmed('PRECHECK'), done), [decided('PRECHECK')]), true, 'the other machine finished');
  eq(waitingOnlyForCheck(W1, docs(rearmed('PRECHECK'), other), [decided('PRECHECK')]), false, 'the other machine moves now: the wave runs');
  eq(waitingOnlyForCheck(W1, docs(done), [decided('PRECHECK')]), false, 'no machine at work: nothing waits');
  eq(waitingOnlyForCheck(W1, docs(), []), false, 'no machine has a state yet');
});

const statePill = liftAll('migrations.html', ['statePill']).statePill;
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
globalThis.ago = () => '1m';

test('RUN: the machine says it waits for the service\'s next check, not Checking', () => {
  const html = statePill('PRECHECK', { active: true, awaits: true });
  ok(html.includes(M.waitsCheck), html);
  ok(!html.includes('>Checking<'), 'not Checking');
  ok(!html.includes('class="spin"'), 'and nothing spins: nothing runs');
  ok(statePill('PRECHECK', { active: true }).includes('Checking'), 'at work, it says Checking as before');
});

const nextStepSaid = lift('migrations.html', 'nextStepSaid');

test('RUN: what happens next says the wave waits for the service, not that it runs', () => {
  eq(nextStepSaid({ ran: false, inFlight: true, onlyWaiting: true, starting: false, begun: true }), A.nextWaitsCheck);
  eq(nextStepSaid({ ran: false, inFlight: true, onlyWaiting: false, starting: false, begun: true }), A.nextRunning);
  eq(nextStepSaid({ ran: false, inFlight: false, onlyWaiting: false, starting: true, begun: false }), A.nextStarting, 'after Start: it starts');
  eq(nextStepSaid({ ran: false, inFlight: false, onlyWaiting: false, starting: false, begun: false }), A.nextPlanned);
  eq(nextStepSaid({ ran: false, inFlight: false, onlyWaiting: false, starting: false, begun: true }), A.nextBetween);
  eq(nextStepSaid({ ran: true, inFlight: false, onlyWaiting: false, starting: false, begun: true }), A.nextAllRan);
});

test('the words of the wait name the service\'s check, and a machine wait promises no time (RETRY-WAIT-WORDS-1)', () => {
  ok(/next check/.test(M.waitsCheck), M.waitsCheck);
  ok(/next check/.test(A.nextWaitsCheck) && !/minute/.test(A.nextWaitsCheck), A.nextWaitsCheck);
  ok(/within about 5 minutes/.test(A.nextStarting), A.nextStarting);
});

test('the rows, the panel, the wave and the banner ask the same rule', () => {
  // STATUS-WORDS-1: the row passes its status, and still the wait.
  ok(/machinePill\(doc, st, \{ since: st\.key === 'step' \? st\.since : null, stuck, awaits, hold, braked: halted, doing \}\)/.test(PAGE), 'the row');
  ok(/const awaits = awaitsServiceCheck\(doc, latestEvents\);/.test(PAGE), 'from the events');
  // WAVE-RUNNING-LEASE-1: through waveRunningSaid, which asks waitingOnlyForCheck.
  ok(PAGE.includes('? waveRunningSaid(info.entries, storedStateOf, (id) => allVms.find(v => v.vmId === id), latestEvents)'),
    'the wave card says the wait in place of "This wave is running now"');
  ok(PAGE.includes('if (!waitingOnlyForCheck(entries, docOf, events, leaseFor)) { return UX_ACT.startAlreadyRunning; }'), 'waveRunningSaid asks the wait');
  // RETRY-WAIT-SAYS-WHY-1: and says what the service said holds the wave, else the next check.
  ok(PAGE.includes('return holdWords(waitingHold(entries, docOf, events, leaseFor))?.pill ?? UX_MISC.waitsCheck;'), 'waveRunningSaid says the hold');
  ok(PAGE.includes('onlyWaiting: waitingOnlyForCheck(waved, (id) => allVms.find(v => v.vmId === id), latestEvents),'), 'the banner');
  ok(PAGE.includes('starting: [...new Set(waved.map(e => e.wave))].some(w => waveStartRequested(w, latestEvents, now)),'), 'the banner asks each wave for a start on its way');
  ok(PAGE.includes('<p>${machinePill(doc, machineStatusOf(vmId, doc), { awaits: awaitsServiceCheck(doc, latestEvents), hold: retryHoldOf(doc, entry?.wave, latestEvents), braked: latestHalted })} '), 'the panel');
});

run('wave-order-start');
