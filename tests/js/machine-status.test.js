/* STATUS-WORDS-1: one status per machine, and it says what the machine is now.
 *
 * Seen on a lab install, 2026-11-04 and 2026-11-05. The status column, the
 * badges, the panel, the counters, the progress bar and the timeline each
 * answered "what is this machine now" on their own, and they disagreed:
 *
 *   - 23: "Verifying" for the whole rollback, the step that failed;
 *   - 42: "Preparing, 13m ago" while the activity moved every minute;
 *   - 47: "Shutting down took 765s" for 13 minutes of checks on a running
 *         machine - the deallocate took 36 s;
 *   - 49: "Migrated" and "Restoring" side by side, and still counted Migrated;
 *   - 51: "Waiting on people" for a wave that ended with one rolled back;
 *   - 53: a full green bar on a restored machine, an empty one on a rolled
 *         back one, and "Migrated 26m ago" after the restore;
 *   - 61: "Restored from its safety copy" while the restore waited for Finish;
 *   - 69: "Needs attention" after a restore that worked;
 *   - 20: a failure line that starts a rollback did not say so.
 *
 * RUN, not read: help.js's own rule over the shared fixture, and the page's own
 * functions that draw from it.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const ws = HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/);
if (!ws) { throw new Error('WORKING_STATES is not declared in help.js'); }
// eslint-disable-next-line no-eval
globalThis.WORKING_STATES = eval(ws[1]);
const help = liftAll('help.js', ['machineOutcome', 'machineStatus']);

const CASES = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', 'fixtures', 'machine-status.json'), 'utf8')).cases;

test('RUN: every shared case gives its status, its times and its bar', () => {
  ok(CASES.length >= 25, 'the fixture loaded');
  for (const c of CASES) {
    const st = help.machineStatus(c.doc, c.live);
    const why = `${c.name} - ${c.why}`;
    eq(st.key, c.status, `status: ${why}`);
    if ('step' in c) { eq(st.step, c.step, `step: ${why}`); }
    if ('finishes' in c) { eq(st.finishes, c.finishes, `finishes: ${why}`); }
    if ('since' in c) { eq(st.since, c.since, `since: ${why}`); }
    eq(st.at, c.at, `at: ${why}`);
    eq(st.bar, c.bar, `bar: ${why}`);
  }
});

test('RUN: every shared case gives the end result the service counts', () => {
  for (const c of CASES) {
    eq(help.machineOutcome(c.doc), c.outcome, `${c.name} - ${c.why}`);
  }
});

test('RUN: the status takes only the lines it is given, in any order', () => {
  // POSITION IS NOT TIME: several workers append to the log at once.
  const c = CASES.find(x => x.name === 'the activity is ahead of the state document');
  const shuffled = { events: [...c.live.events].reverse() };
  const st = help.machineStatus(c.doc, shuffled);
  eq(st.step, 'CONVERTING', 'the newest start wins by its time, not its place');
  eq(st.at, '2026-11-04T16:52:00Z', 'the newest line by its time');
  const none = help.machineStatus(c.doc, null);
  eq(none.step, 'GUEST_PREP', 'no lines: the state document');
});

/* ---------------- the page ---------------- */
globalThis.esc = (s) => String(s ?? '').replace(/[&<>"']/g, ch => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[ch]));
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_RAN = liftConst('migrations.html', 'UX_RAN');
globalThis.STATE_SEQ = ['PLANNED', 'PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'STOPPED', 'SAFETY_COPY', 'CONVERTING', 'STARTING', 'VALIDATING', 'MIGRATED'];
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'NEEDS_DECISION'];
globalThis.ago = (iso) => `AGO(${iso})`;
globalThis.statePill = (state, opts) => `<state:${state}${opts && opts.active ? ':active' : ''}>`;
const page = liftAll('migrations.html', ['restoredPill', 'statusWord', 'statusPill', 'statusLastChange', 'statusBar',
  'statusCounts', 'waveStatus', 'waveRolledBackLine']);
globalThis.RUNNING_STATUS = liftConst('migrations.html', 'RUNNING_STATUS');
globalThis.WAITING_STATUS = liftConst('migrations.html', 'WAITING_STATUS');
globalThis.ENDED_STATUS = liftConst('migrations.html', 'ENDED_STATUS');
const S = (name) => help.machineStatus(CASES.find(c => c.name === name).doc, CASES.find(c => c.name === name).live);

test('RUN: the pill during a rollback says Rolling back, never the step that failed (23)', () => {
  const p = page.statusPill(S('rolling back after Verifying failed'), {});
  ok(p.includes(`>${UX_MISC.statusRollingBack}</span>`), p);
  ok(!p.includes('VALIDATING') && !p.includes(UX_STATE.VALIDATING[0]), `not Verifying: ${p}`);
  ok(p.includes('class="spin"'), 'it is working');
});

test('RUN: the pill follows the step the activity says runs now (42)', () => {
  eq(page.statusPill(S('the activity is ahead of the state document'), {}), '<state:CONVERTING:active>', 'Moving, not Preparing');
});

test('RUN: a machine being restored has ONE pill, Restoring (49)', () => {
  const p = page.statusPill(S('restoring a migrated machine'), {});
  ok(p.includes(`>${UX_ACT.puttingBack}</span>`), p);
  ok(!p.includes('<state:MIGRATED'), `no Migrated beside it: ${p}`);
  eq((p.match(/class="pill/g) || []).length, 1, 'one pill');
});

test('RUN: each status has its own words', () => {
  const word = (name) => page.statusWord(S(name));
  eq(word('restored after it needed attention'), UX_ACT.wasRestored, '69: Restored, not Needs attention');
  eq(word('a restore that did not finish'), UX_ACT.finishPill, '61');
  eq(word('a rollback that did not finish'), UX_MISC.statusFinishRollback, 'finish the rollback');
  eq(word('finishing a restore'), UX_MISC.statusFinishingRestore, 'finishing a restore');
  eq(word('finishing a rollback, from its checkpoint'), UX_MISC.statusFinishingRollback, 'finishing a rollback');
  eq(word('rolled back'), UX_STATE.FAILED_ROLLED_BACK[0], 'rolled back');
  eq(word('migrated'), UX_STATE.MIGRATED[0], 'migrated');
  eq(word('a step runs, and its activity moves'), UX_STATE.GUEST_PREP[0], 'the step');
  eq(word('a decision'), UX_STATE.NEEDS_DECISION[0], 'decision');
  eq(word('needs attention'), UX_STATE.FAILED_NEEDS_ATTENTION[0], 'attention');
  eq(word('left out'), UX_STATE.SKIPPED[0], 'left out');
  eq(word('no record'), UX_STATE.PLANNED[0], 'queued');
  eq(word('a state this version does not know'), 'SOMETHING_NEW', 'unknown says its state');
});

test('RUN: every status the rule gives has words and a pill', () => {
  for (const c of CASES) {
    const st = help.machineStatus(c.doc, c.live);
    ok(page.statusWord(st), `${c.name}: a word`);
    ok(page.statusPill(st, {}).length > 0, `${c.name}: a pill`);
    ok([...RUNNING_STATUS, ...WAITING_STATUS, ...ENDED_STATUS, 'queued', 'unknown'].includes(st.key), `${c.name}: ${st.key} is in one group`);
  }
});

test('RUN: the last change is the word and the time of the newest line (42, 53)', () => {
  const moving = page.statusLastChange(S('a step runs, and its activity moves'));
  ok(moving.includes(UX_STATE.GUEST_PREP[0]) && moving.includes('AGO(2026-11-04T16:51:30Z)'), moving);
  const restored = page.statusLastChange(S('restored by a person'));
  ok(restored.includes(UX_ACT.wasRestored) && restored.includes('AGO(2026-11-04T17:45:00Z)'), `the restore, not Migrated: ${restored}`);
  ok(!restored.includes(UX_STATE.MIGRATED[0]), restored);
  ok(page.statusLastChange(S('no record')).includes('not started'), 'a queued machine');
});

test('RUN: the bar shows how far the move got only while it runs (53)', () => {
  const runBar = page.statusBar(S('the activity is ahead of the state document'));
  ok(/mini-meter /.test(runBar) && !/mini-meter done/.test(runBar), runBar);
  ok(runBar.includes(`width:${Math.round(STATE_SEQ.indexOf('CONVERTING') / (STATE_SEQ.length - 1) * 100)}%`), `the step of the activity: ${runBar}`);
  const done = page.statusBar(S('migrated'));
  ok(/mini-meter done/.test(done) && done.includes('width:100%'), `green and full only for Migrated: ${done}`);
  const back = page.statusBar(S('rolled back'));
  const restored = page.statusBar(S('restored by a person'));
  ok(!/mini-meter/.test(back) && !/mini-meter/.test(restored), 'no bar on a machine back as it was');
  eq(back.replace(/title="[^"]*"/, ''), restored.replace(/title="[^"]*"/, ''), 'the same neutral mark for rolled back and restored');
  ok(!/mini-meter/.test(page.statusBar(S('rolling back after Verifying failed'))), 'no forward bar during a rollback');
});

test('RUN: the counters count each machine once, by its status (49, 51)', () => {
  const sts = [S('restoring a migrated machine'), S('migrated'), S('rolled back'), S('restored by a person'),
               S('needs attention'), S('rolling back after Verifying failed'), S('restored after it needed attention')];
  const n = page.statusCounts(sts);
  eq(n.migrated, 1, 'a machine being restored is not migrated');
  eq(n.restored, 2, 'restored, the one that needed attention included');
  eq(n.moving, 2, 'restoring and rolling back are work in progress');
  eq(n.waiting, 1, 'only the machine that needs a person');
  eq(n.rolledBack, 1, 'rolled back is its own count, not waiting on people');
});

test('RUN: the status filter puts a restore at work under In progress, and a restored stop under Finished', () => {
  globalThis.NOT_STARTED_STATE = 'PLANNED';
  globalThis.notMovedReasons = () => null;
  globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { machineOutcome: help.machineOutcome, outcomeWaitsOnPerson: lift('help.js', 'outcomeWaitsOnPerson') });
  const cat = liftAll('migrations.html', ['waitsOnPerson', 'vmCategory']).vmCategory;
  const c = (name) => CASES.find(x => x.name === name);
  eq(cat('MIGRATED', {}, c('restoring a migrated machine').doc, S('restoring a migrated machine')), 'moving', 'restoring');
  eq(cat('FAILED_NEEDS_ATTENTION', {}, c('restored after it needed attention').doc, S('restored after it needed attention')), 'done', '69: restored');
  eq(cat('FAILED_NEEDS_ATTENTION', {}, c('needs attention').doc, S('needs attention')), 'attention', 'a real stop');
});

test('RUN: a wave that ended with a machine rolled back says Finished, not Waiting on people (51)', () => {
  const [label, cls] = page.waveStatus([S('migrated'), S('rolled back')], false);
  eq(label, UX_MISC.waveFinishedRolledBack.replace('{n}', '1'), label);
  eq(cls, 'warn', 'amber');
  eq(page.waveStatus([S('migrated'), S('restored by a person'), S('left out')], false)[0], 'Complete', 'all ended well');
  eq(page.waveStatus([S('migrated'), S('needs attention')], false)[0], 'Waiting on people', 'a real wait');
  eq(page.waveStatus([S('migrated'), S('restored after it needed attention')], false)[0], 'Complete', '69: a restored machine waits for nobody');
  eq(page.waveStatus([S('migrated'), S('restoring a migrated machine')], false)[0], 'In progress', 'a restore is work');
  eq(page.waveStatus([S('rolled back'), S('rolling back after Verifying failed')], false)[0], 'In progress', 'not finished while one rolls back');
  eq(page.waveStatus([S('no record')], true)[0], 'Paused', 'the brake');
  eq(page.waveStatus([S('no record')], false)[0], 'Waiting to start', 'nothing yet');
});

test('RUN: the wave names the machines that rolled back, and what to do (51)', () => {
  const line = page.waveRolledBackLine([{ name: 'app-1', st: S('rolled back') }, { name: 'app-2', st: S('migrated') }, { name: 'app-3', st: S('rolled back') }]);
  ok(line.includes('app-1') && line.includes('app-3') && !line.includes('app-2'), line);
  eq(page.waveRolledBackLine([{ name: 'app-2', st: S('migrated') }]), '', 'none rolled back: no line');
});

/* The timeline (RESTORE-PANEL-TIMELINE-1): the machine's lines of the run
 * history. The closing line of a step carries the time THAT step took. */
globalThis.newIdentityOf = () => '';
const PAGE_SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
globalThis.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE_SRC.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
const machineTimeline = liftAll('migrations.html', ['machineTimeline', 'activityLines', 'timelineLine', 'stepText', 'foldedCallLines',
  'rollbackFollows', 'stepRetried', 'retriedText']).machineTimeline;

test('RUN: the timeline names the work a duration measures (47)', () => {
  const doc = { vmId: 'a', state: 'SAFETY_COPY', history: [] };
  const L = (ts, step, outcome, durationSec) => ({ tsUtc: `2026-11-04T21:${ts}:00Z`, vmId: 'a', step, outcome, durationSec });
  const t = machineTimeline(doc, [L('30', 'PRECHECK', 'start'), L('31', 'PRECHECK', 'ok', 60),
    L('32', 'GUEST_PREP', 'start'), L('45', 'GUEST_PREP', 'ok', 765),
    L('45', 'STOPPED', 'start'), L('46', 'STOPPED', 'ok', 36)]);
  const prep = t.find(h => h.step === 'GUEST_PREP');
  eq(prep.ran, 'GUEST_PREP', 'the 765 s are the checks and the preparation, on their own line');
  eq(t.find(h => h.step === 'STOPPED').ran, 'STOPPED', 'the 36 s are the shutdown');
  ok(/check/i.test(UX_RAN.GUEST_PREP) && /prepar/i.test(UX_RAN.GUEST_PREP), UX_RAN.GUEST_PREP);
  ok(!/shut/i.test(UX_RAN.GUEST_PREP), 'not Shutting down');
  const timelineDuration = lift('migrations.html', 'timelineDuration');
  const line = timelineDuration(prep);
  ok(line.includes(esc(UX_MISC.tookStep.replace('{step}', UX_RAN.GUEST_PREP).replace('{n}', '765'))), `the line: ${line}`);
  ok(!line.includes(UX_RAN.STOPPED), `never Shutting down took 765 s: ${line}`);
  ok(timelineDuration(t.find(h => h.step === 'STOPPED')).includes(UX_RAN.STOPPED), 'the 36 s say Shutting down');
  eq(timelineDuration({ durationSec: 0.01, ran: 'PLANNED' }), '', 'the wait for a turn is no step of the move');
  eq(timelineDuration({ ran: 'GUEST_PREP' }), '', 'no duration, no text');
});

test('RUN: the timeline says a restore did not finish while it waits for Finish (61)', () => {
  // Restore-VmfVm ends a restore that left a data disk swap with a fail line.
  const c = CASES.find(x => x.name === 'a restore that did not finish');
  const left = { tsUtc: '2026-11-04T17:41:00Z', vmId: 'a', step: 'restore', outcome: 'fail', detail: 'Azure did not swap the data disk on LUN 0.' };
  const top = machineTimeline({ vmId: 'a', ...c.doc }, [left])[0];
  eq(top.label, UX_ACT.restoreNotDone, top.label);
  ok(!top.desc.includes(UX_ACT.restoredFromPristine), 'no claim that it is back');
  const ended = { tsUtc: '2026-11-04T17:45:00Z', vmId: 'a', step: 'restore', outcome: 'ok', detail: 'The machine is back.' };
  const done = machineTimeline({ vmId: 'a', ...CASES.find(x => x.name === 'restored by a person').doc }, [ended])[0];
  eq(done.label, UX_ACT.restoredStep, 'a restore that finished says so');
});
globalThis.agoSpan = (iso) => `AGO(${iso})`;
// RESTORE-EARLIER-DELETE-1: the card lists the earlier disks by the page's own rule.
globalThis.restoreEarlierDisks = lift('migrations.html', 'restoreEarlierDisks');
const restoredNoteHtml = lift('migrations.html', 'restoredNoteHtml');
test('RUN: the restore box says the restore did not finish while it waits for Finish (61)', () => {
  const c = CASES.find(x => x.name === 'a restore that did not finish');
  const r = { ...c.doc.restore, fromCopy: 'pristine', newDiskName: 'osdisk-new' };
  const waiting = restoredNoteHtml(r, c.doc);
  ok(waiting.includes(esc(UX_ACT.restoreNotDone)), waiting);
  ok(!waiting.includes(`<b>${esc(UX_ACT.restoredFrom)}</b>`), 'not titled Restored');
  ok(!waiting.includes(esc(UX_ACT.restoredFromPristine)), 'no claim that it is back on its original size');
  const done = restoredNoteHtml(r, { state: 'MIGRATED', restore: r });
  ok(done.includes(`<b>${esc(UX_ACT.restoredFrom)}</b>`) && done.includes(esc(UX_ACT.restoredFromPristine)), 'a finished restore keeps its box');
});

/* 20: a failure line that starts an automatic rollback says so. */
const rollbackFollows = lift('migrations.html', 'rollbackFollows');
globalThis.VmfHelp = { idKey: (v) => String(v ?? '').toLowerCase() };
test('RUN: the failure line that a rollback follows says the product rolls the machine back (20)', () => {
  const ev = [
    { tsUtc: '2026-11-04T17:00:00Z', vmId: '/X/A', step: 'VALIDATING', outcome: 'fail', detail: 'The Instance Metadata Service answered before the move and does not answer now.' },
    { tsUtc: '2026-11-04T17:00:05Z', vmId: '/x/a', step: 'rollback', outcome: 'start' },
    { tsUtc: '2026-11-04T17:01:00Z', vmId: '/x/b', step: 'CONVERTING', outcome: 'fail', detail: 'no rollback started for this one' },
    { tsUtc: '2026-11-04T17:02:00Z', vmId: '/x/c', step: 'GUEST_PREP', outcome: 'fail', detail: 'a step before the move' },
    { tsUtc: '2026-11-04T17:02:30Z', vmId: '/x/c', step: 'rollback', outcome: 'start' },
    { tsUtc: '2026-11-04T16:00:00Z', vmId: '/x/d', step: 'rollback', outcome: 'start' },
    { tsUtc: '2026-11-04T17:03:00Z', vmId: '/x/d', step: 'STARTING', outcome: 'fail' },
    { tsUtc: '2026-11-04T17:04:00Z', vmId: '/x/e', step: 'VALIDATING', outcome: 'retry' },
    { tsUtc: '2026-11-04T17:04:30Z', vmId: '/x/e', step: 'rollback', outcome: 'start' }];
  const s = rollbackFollows(ev);
  ok(s.has(0), 'the Verifying failure, in any letter case of the machine');
  ok(!s.has(2), 'no rollback started: no promise');
  ok(s.has(3), 'a preparation that is rolled back too');
  ok(!s.has(6), 'a rollback before the failure is not its rollback');
  ok(!s.has(7), 'an attempt the engine tries again is not the failure');
  ok(/rolls the machine back/.test(UX_STEP.rollsBackNote) && /do not need to do anything/.test(UX_STEP.rollsBackNote), UX_STEP.rollsBackNote);
});

/* Wiring: the readers use the rule. Checked on the code, so a comment that
 * names a function does not count. */
const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const code = PAGE.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/.*$/gm, '$1');
test('the row, the panel, the counters and the wave read the one status', () => {
  ok(/function machineStatusOf\(vmId, doc\)[\s\S]*?VmfHelp\.machineStatus\(/.test(code), 'machineStatusOf asks help.js');
  ok(/machinePill\(doc, st, \{/.test(code), 'the row passes its status');
  ok(/machinePill\(doc, machineStatusOf\(vmId, doc\), \{ awaits:/.test(code), 'the panel asks the status');
  ok(/statusLastChange\(st\)/.test(code), 'the last change column');
  ok(/statusBar\(st\)/.test(code), 'the progress column');
  ok(/statusCounts\(vms\.map\(v => machineStatusOf\(v\.vmId, v\)\)\)/.test(code), 'the tiles');
  ok(/waveStatus\(sts, halted[,)]/.test(code), 'the wave pill');
  ok(!/restoredTag/.test(code), 'no second Restoring or Restored pill in the row');
  ok(/restoredNoteHtml\(doc\.restore, doc\)/.test(code), 'the restore box reads the swap');
  ok(/rollbackFollows\(events\)/.test(code), 'the activity list');
});

run('machine-status');
