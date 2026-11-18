/* STOP-STATE-SHOWN-1 (lab walk of DELETE-UNSTARTED-WAVE-1, 2026-11-17).
 *
 * A migration with wave-1 done and wave-2 scheduled and not started. A person
 * selected Stop this migration with a note. Nothing on the page showed that
 * it was stopped. Both waves read Complete, What happens next
 * said every wave had run, the Wave safety brake card turned red with
 * "paused after repeated failures" and Resume, and wave-2 still showed its
 * scheduled start with Cancel the scheduled start.
 *
 * The engine now records the stop (stopped.json). The page reads it:
 *  - the top card says Stopped, who, when and the note, and What happens next
 *    says no wave starts and Delete this migration removes it;
 *  - a wave the stop ended before it started says so, and one it ended part
 *    way says Stopped - neither says Complete;
 *  - the brake card says Stopped, not failures, and offers no Resume or Pause:
 *    every machine the stop closed out stays closed, so Resume starts nothing;
 *  - no scheduled start or Cancel the scheduled start.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.RUNNING_STATUS = liftConst('migrations.html', 'RUNNING_STATUS');
globalThis.WAITING_STATUS = liftConst('migrations.html', 'WAITING_STATUS');
globalThis.ENDED_STATUS = liftConst('migrations.html', 'ENDED_STATUS');
// eslint-disable-next-line no-eval
globalThis.SETTLED_STATES = eval(PAGE.match(/const SETTLED_STATES = (\[[^\]]+\]);/)[1]);
globalThis.NOT_STARTED_STATE = 'PLANNED';
globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
// eslint-disable-next-line no-eval
const idKey = eval(`(${HELP.match(/function idKey\(id\) \{[^\n]*\}/)[0]})`);
const machineStatus = require('./_status').statusRule();
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { idKey, machineStatus });
const st = (doc) => machineStatus(doc, {});

const page = liftAll('migrations.html', ['statusCounts', 'waveStatus', 'stopOfWave', 'stoppedLine', 'scheduleTimeText', 'waveScheduleHtml']);
const nextStepSaid = lift('migrations.html', 'nextStepSaid');

const SUB = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/';
const STOP = {
  schemaVersion: 1, runId: 'run-x', stoppedUtc: '2026-11-17T01:12:40Z', stoppedBy: 'operator@example.com',
  note: 'The second wave is not needed.', wavesNotStarted: ['wave-2'],
  machines: [SUB + 'st-b', SUB + 'st-d'], schedulesRemoved: ['wave-2'],
};
const skipped = (n) => ({ vmId: SUB + n, state: 'SKIPPED' });
const migrated = (n) => ({ vmId: SUB + n, state: 'MIGRATED' });

// ---------- which waves the stop ended ----------

test('RUN: a wave the stop ended before it started, one it ended part way, and one it did not touch', () => {
  eq(page.stopOfWave('wave-2', [{ vmId: SUB + 'st-b' }], STOP), 'notStarted');
  eq(page.stopOfWave('wave-3', [{ vmId: SUB + 'st-c' }, { vmId: SUB + 'ST-D' }], STOP), 'closed', 'found in any letter case');
  eq(page.stopOfWave('wave-1', [{ vmId: SUB + 'st-a' }], STOP), null, 'wave-1 finished before the stop');
  eq(page.stopOfWave('wave-2', [{ vmId: SUB + 'st-b' }], null), null, 'no stop, no stopped wave');
});

test('RUN: the wave pill says Stopped before it started, or Stopped - never Complete', () => {
  eq(page.waveStatus([st(skipped('st-b'))], true, 'notStarted'), [UX_MISC.waveStoppedBeforeStart, 'quiet']);
  eq(page.waveStatus([st(migrated('st-c')), st(skipped('st-d'))], true, 'closed'), [UX_MISC.waveStopped, 'quiet']);
  eq(page.waveStatus([st(migrated('st-a'))], true, null), ['Complete', 'good'], 'a wave that finished before the stop is Complete');
  eq(page.waveStatus([st(skipped('st-b'))], false)[0], 'Complete', 'with no stop, as before');
});

test('RUN: a machine of a stopped wave that waits for a person still says so first', () => {
  eq(page.waveStatus([st({ vmId: SUB + 'x', state: 'FAILED_NEEDS_ATTENTION' })], true, 'closed')[0], 'Waiting on people');
});

// ---------- the top card ----------

test('RUN: the stop line says who, when and the note', () => {
  const said = page.stoppedLine(STOP);
  ok(said.startsWith(UX_ACT.stoppedBy.replace('{who}', 'operator@example.com').replace('{when}', new Date(STOP.stoppedUtc).toLocaleString())), said);
  ok(said.endsWith(UX_ACT.stoppedNote.replace('{note}', 'The second wave is not needed.')), said);
  ok(!page.stoppedLine({ ...STOP, note: '' }).includes(UX_ACT.stoppedNote.replace('{note}', '')), 'no empty note sentence');
});

test('RUN: What happens next says the migration is stopped, before every other answer', () => {
  eq(nextStepSaid({ stopped: true, ran: true }), UX_ACT.nextStopped, 'not "every wave has run"');
  eq(nextStepSaid({ stopped: true, endedHoldOnly: true }), UX_ACT.nextStopped);
  eq(nextStepSaid({ stopped: false, ran: true }), UX_ACT.nextAllRan, 'with no stop, as before');
});

test('RUN: the top card of a stopped migration shows Stopped, the stop line and What happens next', () => {
  const renderNextStep = liftAll('migrations.html', ['lastEngineFailure', 'engineOperationName', 'splitFailure', 'settledAll', 'wavesInFlight', 'nextWaveButton',
    'awaitsServiceCheck', 'awaitsSince', 'serviceHoldLine', 'retryHoldOf', 'waitingHold', 'holdWords', 'waitingOnlyForCheck', 'waveStartRequested',
    'nextStepSaid', 'stoppedLine', 'renderNextStep']).renderNextStep;
  const box = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#nextstep' ? box : null);
  globalThis.planDoc = { entries: [{ vmId: SUB + 'st-a', wave: 'wave-1', path: 'A' }, { vmId: SUB + 'st-b', wave: 'wave-2', path: 'A' }] };
  globalThis.allVms = [migrated('st-a'), skipped('st-b')];
  globalThis.latestEvents = [];
  globalThis.latestHalted = true;
  globalThis.leaseOf = () => null;
  Object.assign(globalThis.VmfHelp, liftAll('help.js', ['machineStarted', 'machineHold', 'machineAtWork', 'waveHold']));
  globalThis.VmfHelp.VmfRun = { link: () => 'waves.html' };
  globalThis.scheduledFirstWave = () => null;
  globalThis.planSignoff = null; globalThis.planSignoffCurrent = false;
  globalThis.runAcknowledged = () => true;
  globalThis.schedules = new Map(); globalThis.approvals = new Map(); globalThis.acceptances = new Map();
  globalThis.canOperate = () => true;
  globalThis.failShown = false;
  globalThis.runStop = STOP;
  renderNextStep([]);
  ok(box.innerHTML.includes(`>${UX_ACT.stoppedTitle}<`), box.innerHTML);
  ok(box.innerHTML.includes(esc(page.stoppedLine(STOP))), 'the stop line');
  ok(box.innerHTML.includes(UX_ACT.nextStopped), 'what happens next');
  ok(!box.innerHTML.includes(UX_ACT.nextAllRan), 'not "every wave has run"');
  // A reader with no operator role reads that it was stopped too.
  globalThis.canOperate = () => false;
  renderNextStep([]);
  ok(box.innerHTML.includes(`>${UX_ACT.stoppedTitle}<`), 'a reader sees Stopped');
  globalThis.runStop = null;
  globalThis.canOperate = () => true;
  renderNextStep([]);
  ok(!box.innerHTML.includes(`>${UX_ACT.stoppedTitle}<`), 'no stop, no Stopped card');
});

// ---------- the Wave safety brake card ----------

test('RUN: the brake card of a stopped migration says Stopped, claims no failure, and offers no Resume or Pause', () => {
  const renderKpis = lift('migrations.html', 'renderKpis');
  const box = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#kpis' ? box : null);
  globalThis.machinesInRun = (vms) => vms.length;
  globalThis.planDoc = null;
  globalThis.canOperate = () => true;
  globalThis.renderRunActions = () => {};
  globalThis.statusCounts = page.statusCounts;
  globalThis.machineStatusOf = (id, doc) => st(doc);
  globalThis.askResume = () => {}; globalThis.askHalt = () => {};
  renderKpis([migrated('st-a'), skipped('st-b')], true, STOP);
  ok(box.innerHTML.includes(`<div class="label">Wave safety brake</div><div class="val" style="font-size:19px">${UX_MISC.brakeStopped}</div><div class="sub">${UX_MISC.brakeStoppedSub}</div>`), box.innerHTML);
  ok(!/repeated failures/.test(box.innerHTML), 'no failure is claimed');
  ok(!box.innerHTML.includes('id="halt-btn"'), 'no Resume and no Pause new work: Resume starts nothing after a stop');
  ok(!/kpi alert"><div class="ic">[^<]*<\/div><div class="label">Wave safety brake/.test(box.innerHTML), 'not red');
  renderKpis([migrated('st-a')], true, null);
  ok(box.innerHTML.includes('paused after repeated failures'), 'the brake paused, with no stop: as before');
  ok(box.innerHTML.includes(`>${UX_ACT.resume}<`), 'and Resume');
});

// ---------- the scheduled start ----------

test('RUN: a stopped migration shows no scheduled start and no Cancel the scheduled start', () => {
  const sched = { wave: 'wave-2', runAtUtc: '2026-11-18T01:00:00Z', scheduledBy: 'lead@example.com', state: 'pending' };
  eq(page.waveScheduleHtml('wave-2', sched, true, true), { chip: '', cancel: '' });
  ok(page.waveScheduleHtml('wave-2', sched, true, false).cancel.includes(UX_ACT.cancelSchedule), 'with no stop, as before');
});

test('the page reads the stop record, and passes it to the cards', () => {
  ok(/doc\('stopped\.json'\)/.test(PAGE), 'read with the other run documents');
  ok(/runStop = stopDoc && stopDoc\.stoppedUtc \? stopDoc : null;/.test(PAGE), 'kept for the cards, and a record with no time is no stop');
  ok(/renderKpis\(allVms, halted, runStop\)/.test(PAGE), 'the brake card');
  ok(/waveStatus\(sts, halted, stopOfWave\(wave, info\.entries, runStop\)\)/.test(PAGE), 'each wave');
  ok(PAGE.includes('waveScheduleHtml(wave, sched, canOperate(), Boolean(runStop))'), 'the scheduled start');
});

run('stop-state-shown');
