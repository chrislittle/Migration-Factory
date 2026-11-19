/* BRAKE-WAIT-WORDS-1: a retry that the wave safety brake holds says it waits
 * for Resume, not for the service.
 *
 * Lab, 2026-11-08, the lab installation. A wave of three machines all rolled
 * back, and the wave safety brake paused the migration. A person selected Try
 * this machine again on each machine. For more than 20 minutes each row said
 * "Waits for the service's next check", and What happens next said "The
 * service starts it again within about 5 minutes". Nothing did: the service's
 * timer returns at once for a halted run (Invoke-VmfFacadeResumeStalledWaves),
 * and a worker takes no new machine of one (Get-VmfNextWaveVm). Only Resume
 * starts it.
 *
 * The page knows the brake already: the refresh's `halted`, which the Wave
 * safety brake card shows. Each place that said the wait asks that value too.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
globalThis.esc = (s) => String(s ?? '');
globalThis.canOperate = () => true;
globalThis.isUnplannedWave = () => false;
globalThis.planRunStatus = null;
globalThis.soonHelpOpen = new Set();
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['waveOrder', 'idKey', 'machineHold', 'machineAtWork', 'waveHold', 'machineOutcome']));
globalThis.leaseOf = () => undefined;
globalThis.planRunOrder = lift('migrations.html', 'planRunOrder');
globalThis.planFollowText = lift('migrations.html', 'planFollowText');
const card = liftAll('migrations.html', ['settledAll', 'vmStateOf', 'startsSoonHtml', 'waveStartHtml']);
const statePill = liftAll('migrations.html', ['statePill']).statePill;
const nextStepSaid = lift('migrations.html', 'nextStepSaid');
const M = globalThis.UX_MISC;
const A = globalThis.UX_ACT;

// ---- The words ----

test('the words name the brake, Resume and the card, and promise no time', () => {
  eq(M.waitsResume, 'Waits for Resume');
  ok(/wave safety brake/i.test(M.waitsResumeTip) && /Resume/.test(M.waitsResumeTip), M.waitsResumeTip);
  eq(A.nextWaitsResume, 'The wave safety brake paused this migration. Nothing starts until an operator selects Resume on the Wave safety brake card.');
  for (const s of [M.waitsResume, M.waitsResumeTip, A.nextWaitsResume]) {
    ok(!/minute|next check/i.test(s), `no time and no check of the service: ${s}`);
  }
  // The card the words send a person to, and the button on it.
  ok(PAGE.includes('<div class="label">Wave safety brake</div>'), 'the card is named Wave safety brake');
  eq(A.resume, 'Resume', 'the button on the card is Resume');
});

// ---- The machine row and the machine panel ----

test('RUN: a machine that waits for the service says Waits for Resume while the brake holds the migration', () => {
  const held = statePill('PRECHECK', { active: true, awaits: true, braked: true });
  ok(held.includes(M.waitsResume), held);
  ok(held.includes(M.waitsResumeTip), `the hover says why: ${held}`);
  ok(!held.includes(M.waitsCheck), `not the service's next check: ${held}`);
  ok(!held.includes('class="spin"'), 'and nothing spins');
  const free = statePill('PRECHECK', { active: true, awaits: true, braked: false });
  ok(free.includes(M.waitsCheck) && !free.includes(M.waitsResume), `no brake: the service's next check, as before: ${free}`);
});

test('RUN: the brake alone does not change a machine that does not wait', () => {
  const working = statePill('PRECHECK', { active: true, braked: true });
  ok(working.includes('Checking') && !working.includes(M.waitsResume), `a machine at work says its step: ${working}`);
  const done = statePill('MIGRATED', { braked: true });
  ok(!done.includes(M.waitsResume), done);
});

test('the row and the panel give the pill the page\'s one brake value', () => {
  ok(/machinePill\(doc, st, \{ since: st\.key === 'step' \? st\.since : null, stuck, awaits, hold, braked: halted, doing \}\)/.test(PAGE),
    'the row, from renderWaves(halted)');
  ok(PAGE.includes('<p>${machinePill(doc, machineStatusOf(vmId, doc), { awaits: awaitsServiceCheck(doc, latestEvents), hold: retryHoldOf(doc, entry?.wave, latestEvents), braked: latestHalted })} '),
    'the panel, from the value the refresh keeps');
  ok(/const halted = Boolean\(status\?\.breaker\?\.halted\) \|\| Boolean\(haltFlag\);\s+latestHalted = halted;/.test(PAGE),
    'the value the Wave safety brake card shows');
});

// ---- What happens next ----

test('RUN: What happens next names the brake when the only machines at work wait, and the brake holds', () => {
  eq(nextStepSaid({ ran: false, inFlight: true, onlyWaiting: true, starting: false, begun: true, halted: true }), A.nextWaitsResume);
  eq(nextStepSaid({ ran: false, inFlight: true, onlyWaiting: true, starting: false, begun: true, halted: false }), A.nextWaitsCheck,
    'no brake: the service\'s next check, as before');
});

test('RUN: a start on its way while the brake holds says the brake, not "within about 5 minutes"', () => {
  eq(nextStepSaid({ ran: false, inFlight: false, onlyWaiting: false, starting: true, begun: false, halted: true }), A.nextWaitsResume);
  eq(nextStepSaid({ ran: false, inFlight: false, onlyWaiting: false, starting: true, begun: false, halted: false }), A.nextStarting);
});

test('RUN: the brake does not change the other lines', () => {
  eq(nextStepSaid({ ran: false, inFlight: true, onlyWaiting: false, starting: false, begun: true, halted: true }), A.nextRunning,
    'a machine moves now: it finishes its step');
  eq(nextStepSaid({ ran: true, inFlight: false, onlyWaiting: false, starting: false, begun: true, halted: true }), A.nextAllRan);
  eq(nextStepSaid({ endedHoldOnly: true, ran: false, inFlight: true, halted: true }), A.nextEndedHold);
});

test('What happens next is given the page\'s one brake value', () => {
  ok(/const said = nextStepSaid\(\{[^}]*\bhalted: latestHalted,/.test(PAGE), 'the banner');
  const refresh = PAGE.slice(PAGE.indexOf('latestHalted = halted;'));
  ok(refresh.indexOf('latestHalted = halted;') < refresh.indexOf('renderNextStep(events);'), 'set before the banner is drawn');
});

// ---- The wave card ----

const W1 = [{ vmId: '/s/rg/vm/l26-w3', wave: 'w1', path: 'A' }];
const W2 = [{ vmId: '/s/rg/vm/l26-w4', wave: 'w2', path: 'A' }];
const PLAN = { waveOrder: ['w1', 'w2'], entries: [...W1, ...W2] };
const signed = { planCovers: true, waveWorking: false, waveDone: false, halted: false, sched: null, startBlockedBy: null };

test('RUN: a wave the plan starts on its own says Waits for Resume while the brake holds, not "Starts within about 5 minutes"', () => {
  globalThis.planDoc = PLAN;
  globalThis.allVms = [{ vmId: '/s/rg/vm/l26-w3', state: 'MIGRATED' }];
  const free = card.waveStartHtml('w2', W2, signed);
  ok(free.includes(M.startsSoon), `no brake: it starts soon, as before: ${free}`);
  const held = card.waveStartHtml('w2', W2, Object.assign({}, signed, { halted: true }));
  ok(held.includes(M.waitsResume), held);
  ok(!held.includes(M.startsSoon) && !held.includes('data-start'), `no time and no Start: ${held}`);
  globalThis.allVms = [];
});

test('RUN: a wave that waits for the wave before it also says Waits for Resume while the brake holds', () => {
  globalThis.planDoc = PLAN;
  globalThis.allVms = [{ vmId: '/s/rg/vm/l26-w3', state: 'CONVERTING' }];
  const held = card.waveStartHtml('w2', W2, Object.assign({}, signed, { halted: true }));
  ok(held.includes(M.waitsResume), held);
  globalThis.allVms = [];
});

test('RUN: with the brake on, a working wave says nothing of the service\'s check, and a finished wave nothing at all', () => {
  globalThis.planDoc = PLAN;
  globalThis.allVms = [{ vmId: '/s/rg/vm/l26-w3', state: 'PRECHECK' }];
  const working = card.waveStartHtml('w1', W1, Object.assign({}, signed, { halted: true, waveWorking: true, startBlockedBy: M.waitsCheck }));
  ok(!working.includes(M.waitsCheck) && !working.includes('data-start'), working);
  globalThis.allVms = [{ vmId: '/s/rg/vm/l26-w3', state: 'MIGRATED' }];
  eq(card.waveStartHtml('w1', W1, Object.assign({}, signed, { halted: true, waveDone: true })), '', 'a finished wave');
  globalThis.allVms = [];
});

run('brake-wait-words');
