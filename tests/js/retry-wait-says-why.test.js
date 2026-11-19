/* RETRY-WAIT-SAYS-WHY-1: a machine that waits for the service says why, when
 * the service said why.
 *
 * Final lab, 2026-11-16. A person selected Try this machine again on a
 * machine of the finished wave W1 while wave W2 ran. For 22 minutes the row
 * said "Waits for the service's next check", and What happens next said "The
 * service starts it again within about 5 minutes". The service's restart
 * starts nothing while a worker of another wave or a restore holds the run,
 * nor a wave that fails a start gate, and it wrote no line. The machine
 * started about 6 minutes after W2 finished.
 *
 * The service now writes one 'resume' line per cause, with the wave as data
 * and code 'held' (Write-VmfResumeHoldLine, RetryWaitSaysWhy.Tests.ps1). The
 * page shows that cause on the machines of the wave that wait for its check,
 * on the wave card and in What happens next. With no such line, it says what
 * it said before.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
globalThis.esc = (s) => String(s ?? '');
globalThis.ago = () => '1m';
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, liftAll('help.js', ['idKey', 'machineHold', 'machineAtWork', 'waveHold']));
globalThis.leaseOf = () => undefined;
const M = globalThis.UX_MISC;
const A = globalThis.UX_ACT;

const page = liftAll('migrations.html', ['awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords',
  'waitingOnlyForCheck', 'waveRunningSaid', 'statePill', 'nextStepSaid']);
const stepText = liftAll('migrations.html', ['stepText']).stepText;

const NOW = Date.now();
const at = (min) => new Date(NOW - min * 60000).toISOString();
const VM = '/s/rg/vm/f-w25';
const VM2 = '/s/rg/vm/f-w26';
const W1 = [{ vmId: VM, wave: 'W1', path: 'A' }, { vmId: VM2, wave: 'W1', path: 'A' }];
// A machine Try this machine again sent back to Checking 10 minutes ago.
const retried = (vmId = VM, min = 10) => ({ vmId, state: 'PRECHECK', history: [
  { tsUtc: at(30), state: 'FAILED_ROLLED_BACK', outcome: 'fail' },
  { tsUtc: at(min), state: 'PRECHECK', outcome: 'ok', detail: 'Decision resolved.' }] });
const decided = (vmId = VM, min = 10) => ({ tsUtc: at(min), step: 'decision', outcome: 'ok', vmId, returnTo: 'PRECHECK', choice: 'retry' });
const settled = { vmId: VM2, state: 'MIGRATED', history: [{ tsUtc: at(40), state: 'MIGRATED', outcome: 'ok' }] };
// The service's lines, as Write-VmfResumeHoldLine and the restart write them.
const heldBy = (fields, min = 5) => Object.assign({ tsUtc: at(min), step: 'resume', outcome: 'info', wave: 'W1', code: 'held', holdBy: 'wave', holdWave: 'W2', gate: '', reason: '',
  detail: 'A machine in wave W1 waits for wave W2 to finish. Then the service starts wave W1 again.' }, fields);
const resumed = (min = 2) => ({ tsUtc: at(min), step: 'resume', outcome: 'warn', wave: 'W1', code: 'resumed', detail: 'The run stopped before wave W1 finished.' });
const GATE = 'Nobody approved wave W1. An approver must select Approve on wave W1.';

// ---- The words ----

test('the words name the wave, the restore or the gate, and keep the time the service then takes', () => {
  eq(M.waitsWave, 'Waits for wave {wave} to finish');
  eq(M.waitsWaveTip, 'Nothing works on this machine now. When wave {wave} finishes, the service starts this machine again at its next check.');
  eq(M.waitsAnyWave, 'Waits for a running wave to finish');
  eq(M.waitsRestore, 'Waits for a restore to finish');
  eq(M.waitsGate, 'Wave {wave} cannot start yet');
  eq(A.nextWaitsWave, 'A machine waits for wave {wave} to finish. Then the service starts it again at its next check. This page updates itself, so you can keep it open.');
  eq(A.nextWaitsGate, 'A machine waits, because wave {wave} cannot start yet. {reason}');
  for (const s of [M.waitsWave, M.waitsAnyWave, M.waitsRestore, M.waitsGate]) {
    ok(!/next check/i.test(s), `not the service's next check: ${s}`);
  }
});

// ---- Which line holds the machine ----

test('RUN: a held line of the wave written after the retry holds the machine', () => {
  const line = page.serviceHoldLine('W1', Date.parse(at(10)), [decided(), heldBy({})]);
  eq(line?.holdWave, 'W2');
});

test('RUN: a held line written before the retry does not - the service says it again for the retry', () => {
  eq(page.serviceHoldLine('W1', Date.parse(at(10)), [heldBy({}, 20), decided()]), null);
});

test('RUN: the service started the wave after the line - nothing holds it', () => {
  eq(page.serviceHoldLine('W1', Date.parse(at(10)), [heldBy({}, 5), resumed(2)]), null);
  eq(page.serviceHoldLine('W1', Date.parse(at(10)), [resumed(6), heldBy({}, 5)])?.holdWave, 'W2', 'a hold after a start holds again');
});

test('RUN: the line of another wave, or a line of a machine, does not hold this wave', () => {
  eq(page.serviceHoldLine('W1', Date.parse(at(10)), [heldBy({ wave: 'W3' })]), null);
  eq(page.serviceHoldLine('W1', Date.parse(at(10)), [heldBy({ vmId: VM })]), null);
  eq(page.serviceHoldLine('w1', Date.parse(at(10)), [heldBy({})])?.holdWave, 'W2', 'in any letter case of the wave');
});

test('RUN: the last of two held lines is the cause now', () => {
  const later = heldBy({ holdBy: 'restore', holdWave: '' }, 3);
  eq(page.serviceHoldLine('W1', Date.parse(at(10)), [heldBy({}, 5), later])?.holdBy, 'restore');
});

test('RUN: a machine that does not wait for the service has no hold, whatever the service said', () => {
  const working = Object.assign(retried(), {});
  eq(page.retryHoldOf(working, 'W1', [decided(), heldBy({}), { tsUtc: at(4), step: 'worker', outcome: 'info', vmId: VM }]), null);
  eq(page.retryHoldOf(retried(), 'W1', [decided(), heldBy({})])?.holdWave, 'W2');
  eq(page.retryHoldOf(retried(), 'W1', [decided()]), null, 'no line: no hold');
});

// ---- The words of a hold ----

test('RUN: each cause has its words, with the wave and the gate filled in', () => {
  const w = page.holdWords(heldBy({}));
  eq(w.pill, 'Waits for wave W2 to finish');
  eq(w.tip, 'Nothing works on this machine now. When wave W2 finishes, the service starts this machine again at its next check.');
  eq(w.next, 'A machine waits for wave W2 to finish. Then the service starts it again at its next check. This page updates itself, so you can keep it open.');
  eq(page.holdWords(heldBy({ holdWave: '' })).pill, M.waitsAnyWave, 'a wave the line does not name: a running wave');
  eq(page.holdWords(heldBy({ holdBy: 'restore', holdWave: '' })).next, A.nextWaitsRestore);
  const g = page.holdWords(heldBy({ holdBy: 'gate', holdWave: '', gate: 'notApproved', reason: GATE }));
  eq(g.pill, 'Wave W1 cannot start yet');
  eq(g.tip, `${GATE} Then the service starts this machine again at its next check.`);
  eq(g.next, `A machine waits, because wave W1 cannot start yet. ${GATE}`);
  eq(page.holdWords(heldBy({ holdBy: 'gate', reason: '' })), null, 'a gate with no words: the page says the next check');
  eq(page.holdWords(heldBy({ holdBy: 'other' })), null, 'a cause the page does not know');
  eq(page.holdWords(heldBy({ holdWave: '$&' })).pill, 'Waits for wave $& to finish', 'a wave name is put in as written');
});

// ---- The machine row and panel ----

test('RUN: the pill names the wave that holds the machine, and its hover says when it starts', () => {
  const html = page.statePill('PRECHECK', { active: true, awaits: true, hold: heldBy({}) });
  ok(html.includes('>Waits for wave W2 to finish<'), html);
  ok(html.includes('When wave W2 finishes, the service starts this machine again at its next check. (PRECHECK)'), html);
  ok(!html.includes(M.waitsCheck), `not the service's next check: ${html}`);
  ok(!html.includes('class="spin"'), 'nothing spins');
});

test('RUN: no hold recorded - the pill says the next check, as before', () => {
  const html = page.statePill('PRECHECK', { active: true, awaits: true, hold: null });
  ok(html.includes(M.waitsCheck) && html.includes(M.waitsCheckTip), html);
});

test('RUN: the wave safety brake comes first - only Resume starts the machine then', () => {
  const html = page.statePill('PRECHECK', { active: true, awaits: true, braked: true, hold: heldBy({}) });
  ok(html.includes(M.waitsResume) && !html.includes('W2'), html);
});

test('the row and the panel give the pill the hold of the machine\'s wave', () => {
  ok(PAGE.includes('const hold = awaits ? retryHoldOf(doc, v.entry.wave, latestEvents) : null;'), 'the row');
  ok(PAGE.includes('stuck, awaits, hold, braked: halted, doing })'), 'the row passes it');
  ok(PAGE.includes('{ awaits: awaitsServiceCheck(doc, latestEvents), hold: retryHoldOf(doc, entry?.wave, latestEvents), braked: latestHalted })'), 'the panel');
});

// ---- The wave card ----

test('RUN: the wave card says the hold when every machine that waits has it, else the next check', () => {
  const docs = (...d) => (id) => d.find(x => x.vmId === id);
  eq(page.waveRunningSaid(W1, () => 'PRECHECK', docs(retried(), settled), [decided(), heldBy({})]), 'Waits for wave W2 to finish');
  eq(page.waveRunningSaid(W1, () => 'PRECHECK', docs(retried(), settled), [decided()]), M.waitsCheck, 'no hold recorded');
  // A second retry after the line: the service has not said why for it yet.
  eq(page.waveRunningSaid(W1, () => 'PRECHECK', docs(retried(), retried(VM2, 3)), [decided(), heldBy({}), decided(VM2, 3)]), M.waitsCheck);
});

test('RUN: waitingHold is the hold of every machine that waits, or nothing', () => {
  const docs = (...d) => (id) => d.find(x => x.vmId === id);
  eq(page.waitingHold(W1, docs(retried(), retried(VM2, 8)), [decided(), decided(VM2, 8), heldBy({})])?.holdWave, 'W2');
  eq(page.waitingHold(W1, docs(settled), [heldBy({})]), null, 'nothing waits');
});

// ---- What happens next ----

test('RUN: What happens next names the wave that holds the machine', () => {
  const o = { ran: false, inFlight: true, onlyWaiting: true, starting: false, begun: true, halted: false };
  eq(page.nextStepSaid({ ...o, hold: heldBy({}) }), 'A machine waits for wave W2 to finish. Then the service starts it again at its next check. This page updates itself, so you can keep it open.');
  eq(page.nextStepSaid({ ...o, hold: null }), A.nextWaitsCheck, 'no hold recorded: as before');
  eq(page.nextStepSaid({ ...o, hold: heldBy({}), halted: true }), A.nextWaitsResume, 'the brake first');
  eq(page.nextStepSaid({ ...o, onlyWaiting: false, hold: heldBy({}) }), A.nextRunning, 'a machine moves now');
});

test('What happens next is given the hold of the machines that wait', () => {
  ok(PAGE.includes('hold: waitingHold(waved, (id) => allVms.find(v => v.vmId === id), latestEvents),'), 'the banner');
});

// ---- The activity ----

test('RUN: the activity shows the service\'s sentence, not "The engine was started again"', () => {
  eq(stepText(heldBy({})), 'A machine in wave W1 waits for wave W2 to finish. Then the service starts wave W1 again.');
  eq(stepText({ tsUtc: at(1), step: 'resume', outcome: 'warn', wave: 'W1', code: 'resumed', detail: 'x' }), globalThis.UX_STEP.waveRestarted,
    'the start keeps its words');
});

run('retry-wait-says-why');

test('no machine wait line promises a time the service does not keep (RETRY-WAIT-WORDS-1)', () => {
  for (const k of ['waitsCheckTip', 'waitsWaveTip', 'waitsAnyWaveTip', 'waitsRestoreTip', 'waitsGateTip']) {
    ok(!/minute/.test(M[k]), `${k}: ${M[k]}`);
  }
  for (const k of ['nextWaitsCheck', 'nextWaitsWave', 'nextWaitsAnyWave', 'nextWaitsRestore']) {
    ok(!/minute/.test(A[k]), `${k}: ${A[k]}`);
  }
});