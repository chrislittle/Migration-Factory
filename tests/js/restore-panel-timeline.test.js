/* RESTORE-PANEL-TIMELINE-1, from the final lab, 2026-11-16 and 2026-11-17.
 *
 * The machine panel must always show the machine's true state and activity.
 * After Restore this machine on three machines (restores
 * that worked), the machine panel's "What happened, newest first" listed only
 * the steps of the migration. The steps of the restore - "Building a disk from
 * the safety copy", "Changing the machine back to the size it started on", the
 * names of the restored data disks - were only in the Activity table of the
 * page. And while a restore ran, the main block of the panel still showed the
 * "What to do" of the stop before it.
 *
 * THE CAUSE: the panel built its list from the state document's history, and a
 * restore writes no history - only lines in the run history, which is what the
 * Activity table reads. machineTimeline took those lines as an argument and
 * never read them.
 *
 * RUN, not read: the page's own openDrill, machineTimeline, renderEvents's line
 * rule, stepText, the stop box and help.js's status rule, against stand-ins for
 * the DOM only.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { extract, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const table = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));

/* ---- the page's own tables and words ------------------------------------ */
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/const PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
globalThis.TERMINAL_STATES = ['MIGRATED', 'SKIPPED', ...globalThis.PROBLEM_STATES];
// eslint-disable-next-line no-eval
globalThis.UX_PATH = eval(`(${PAGE.match(/const UX_PATH = (\{[^}]+\});/)[1]})`);
for (const n of ['UX_ACT', 'UX_STATE', 'UX_STATE_DONE', 'UX_MISC', 'UX_STEP', 'UX_RAN', 'CHECKPOINT_TEXT', 'SAYS_ITSELF', 'STEP_MAP']) {
  globalThis[n] = liftConst('migrations.html', n);
}
// eslint-disable-next-line no-eval
globalThis.RESTORE_ENDS = eval(PAGE.match(/const RESTORE_ENDS = (\[[^\]]+\]);/)[1]);
// eslint-disable-next-line no-eval
globalThis.PUTBACK_HOLD_MS = eval(PAGE.match(/const PUTBACK_HOLD_MS = ([^;]+);/)[1]);
globalThis.STOP_CHECK = liftConst('migrations.html', 'STOP_CHECK');
globalThis.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
globalThis.retryLines = table.retryLines;

/* ---- what the panel reads that is not under test ------------------------ */
globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const unesc = (s) => String(s).replace(/&quot;/g, '"').replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.techText = (s) => String(s ?? '');
globalThis.guestRunPill = () => '';
globalThis.ago = () => 'a moment ago';
globalThis.notMovedReasons = () => null;
globalThis.notMovedHtml = () => '';
globalThis.latestClaims = [];
globalThis.latestHalted = false;
globalThis.canOperate = () => true;
globalThis.canApprove = () => true;
globalThis.restoreWaitsForMove = () => false;
globalThis.restoreOffered = () => false;
globalThis.madeHelpOpen = new Set();
globalThis.diskDelete = null;
globalThis.currentRun = 'run-1';
globalThis.planDoc = { entries: [] };
globalThis.allVms = [];
globalThis.VmfHelp = { idKey: (id) => String(id == null ? '' : id).toLowerCase(),
  machineAtWork: (s) => globalThis.WORKING_STATES.includes(s) };
globalThis.VmfHelp.machineStatus = require('./_status').statusRule();
globalThis.VmfHelp.machineOutcome = require('./_harness').liftAll('help.js', ['machineOutcome']).machineOutcome;
globalThis.isPutBack = (d) => VmfHelp.machineOutcome(d) === 'putBack';
for (const n of ['askResolve', 'askDecide', 'askRestore', 'askFinish', 'askSkipVm', 'askPowerBack', 'fillRetrySeries',
  'refocusDrill', 'revealDiskDelete', 'markDialogStale', 'toggleDiskDelete', 'closeDiskDelete', 'confirmDiskDelete', 'toggleMadeHelp']) {
  globalThis[n] = () => false;
}
globalThis.panelDialog = (id, open) => open();
let drawn = '';
globalThis.drawDrill = (html) => { drawn = String(html); return true; };
globalThis.$ = (sel) => (sel === '#drill-body' ? { querySelectorAll: () => [] } : null);

// The helpers this item adds are lifted when the page has them, so a test
// fails on what the page DOES before the change, not on a missing name.
const maybe = ['activityLines', 'timelineLine', 'restoreEndAfter', 'restoreEndCard'].filter(n => { try { extract('migrations.html', n); return true; } catch { return false; } });
const page = liftAll('migrations.html', ['openDrill', 'capacityLine', 'agoSpan', 'drillKey', 'machineTimeline',
  'attemptStop', 'currentStop', 'whyStoppedCard', 'stopControls', 'powerOwed', 'volumesCheckOffer', 'volumesCheckStarted', 'volumesStartedLine', 'powerName', 'lastStopEntry', 'sizeRefusedStop', 'retryHeld', 'decisionWaiting',
  'putBackControls', 'finishOffered', 'machinePill', 'shownState', 'restoredPill', 'statePill', 'checkpointLine',
  'restoredNoteHtml', 'restoreEarlierDisks', 'recordedMachineDiskIds', 'madeDiskRows', 'madeDisksHtml', 'recordDiskIdsInUse',
  'rollbackOriginalDisks', 'rollbackOriginalsHtml', 'machineStatusOf', 'statusWord', 'statusPill', 'timelineDuration',
  'awaitsServiceCheck', 'awaitsSince', 'retryHoldOf', 'waitingHold', 'serviceHoldLine', 'holdWords',
  'stepText', 'foldedCallLines', 'rollbackFollows', 'stepRetried', 'retriedText', 'restoreIndex', 'restoreInFlight', 'restoreRecordEnds',
  'rollbackDoing', 'stopCheckSentence', ...maybe]);

/* ---- the machine and its run history ------------------------------------ */
const VM = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-lab/providers/Microsoft.Compute/virtualMachines/st-a';
const entry = { vmId: VM, wave: 'w1', path: 'A' };
const at = (h, m, s) => `2026-11-17T${String(h).padStart(2, '0')}:${String(m).padStart(2, '0')}:${String(s ?? 0).padStart(2, '0')}Z`;
const L = (ts, step, outcome, extra) => Object.assign({ tsUtc: ts, step, outcome, vmId: VM }, extra);

/** The lines a move writes, step by step (Invoke-VmfStateMachine), from h:00. */
function moveLines(h) {
  const steps = ['PRECHECK', 'SAFETY_PRISTINE', 'GUEST_PREP', 'STOPPED', 'SAFETY_COPY', 'CONVERTING', 'STARTING', 'VALIDATING'];
  return steps.flatMap((s, i) => [L(at(h, i * 2), s, 'start'), L(at(h, i * 2 + 1), s, 'ok', { durationSec: 60 })]);
}
const migratedHistory = (h) => [
  { tsUtc: at(h, 1), state: 'SAFETY_PRISTINE', outcome: 'ok' },
  { tsUtc: at(h, 15), state: 'MIGRATED', outcome: 'ok', durationSec: 60 },
];
const DISKS = 'Restored the data disks st-a-data0-restored and st-a-data1-restored from the safety copy.';
/** A restore that worked (Restore-VmfVm), from h:30. */
function restoreLines(h, op) {
  return [
    L(at(h, 30), 'restore', 'start', { correlationId: op, detail: 'Restoring st-a from the copy taken before the migration' }),
    L(at(h, 31), 'azureops:restore:stop', 'ok'),
    L(at(h, 32), 'azureops:restore:createDisk', 'ok'),
    L(at(h, 33), 'azureops:restore:revertHardware', 'ok'),
    L(at(h, 34), 'azureops:restore:swapDisk', 'ok'),
    L(at(h, 35), 'restore', 'info', { detail: DISKS }),
    L(at(h, 36), 'azureops:restore:start', 'ok'),
  ];
}
const DONE_LINE = 'The machine is back on Standard_D2s_v4, on the disks made from the copy taken before the migration.';

/** Draw the panel as the refresh does: the run history, the restores it finds running, the machine. */
async function panelFor(doc, events) {
  globalThis.latestEvents = events;
  globalThis.restoresInFlight = page.restoreIndex(events);
  globalThis.allVms = [doc];
  drawn = '';
  await page.openDrill(doc, entry, VM);
  const cut = drawn.indexOf('What happened, newest first');
  ok(cut > 0, 'the panel draws its list');
  const end = drawn.indexOf('Work done inside the machine');
  return { main: unesc(drawn.slice(0, cut)), list: unesc(drawn.slice(cut, end)), html: drawn };
}

/* ---- a restore that worked ---------------------------------------------- */
test('a restore that worked: every step of the restore is in "What happened"', async () => {
  const doc = { vmId: VM, state: 'MIGRATED', history: migratedHistory(10),
    restore: { restoredUtc: at(10, 37), restoredBy: 'operator@example.com', fromCopy: 'pristine', newDiskName: 'st-a-os-restored' } };
  const events = [...moveLines(10), ...restoreLines(10, 'op-1'), L(at(10, 37), 'restore', 'ok', { detail: DONE_LINE })];
  const { list } = await panelFor(doc, events);
  ok(list.includes(UX_STEP.makeDiskFromCopy), `Building a disk from the safety copy: ${list}`);
  ok(list.includes(UX_STEP.revertSize), 'Changing the machine back to the size it started on');
  ok(list.includes(UX_STEP.swapBackDisk), 'the swap of the operating system disk');
  ok(list.includes(DISKS), 'the names of the restored data disks');
  ok(list.includes(UX_ACT.restoredStep), 'the end of the restore, in the panel words');
  ok(list.includes(DONE_LINE), 'and what the restore said at its end');
  ok(list.includes(UX_STATE.MIGRATED[0]), 'the migration is still on the list');
  // Newest first: the end of the restore above its first step, above the migration.
  ok(list.indexOf(UX_ACT.restoredStep) < list.indexOf(UX_STEP.makeDiskFromCopy), 'the end of the restore is above its steps');
  ok(list.indexOf(UX_STEP.makeDiskFromCopy) < list.indexOf(UX_STATE.MIGRATED[0]), 'the restore is above the migration');
});

test('the list has the lines the Activity table has for the machine, and no line of another machine', async () => {
  const doc = { vmId: VM, state: 'MIGRATED', history: migratedHistory(10) };
  const other = { tsUtc: at(10, 40), step: 'restore', outcome: 'info', vmId: VM.replace('st-a', 'st-b'), detail: 'A line of st-b.' };
  const { list } = await panelFor(doc, [...moveLines(10), other]);
  ok(!list.includes('A line of st-b.'), 'another machine');
  ok(list.includes(UX_STATE.CONVERTING[1]), `the closing line of a step of the move, in the words of the Activity table: ${list}`);
});

test('the id of the machine is matched without case, as the restore spells it', async () => {
  const doc = { vmId: VM, state: 'MIGRATED', history: migratedHistory(10) };
  const { list } = await panelFor(doc, [...moveLines(10), L(at(10, 35), 'restore', 'info', { vmId: VM.toUpperCase(), detail: DISKS })]);
  ok(list.includes(DISKS), list);
});

/* ---- while a restore runs ----------------------------------------------- */
const rbFailed = (h) => [
  { tsUtc: at(h, 1), state: 'SAFETY_PRISTINE', outcome: 'ok' },
  { tsUtc: at(h, 20), state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'rollbackFailed', machineState: 'changed',
    detail: 'Something failed, and the rollback also failed.' },
];
const rbTitle = stopReasons.get('rollbackFailed').title;

test('while a restore runs, the header says Restoring and the old stop is not the main message', async () => {
  const doc = { vmId: VM, state: 'FAILED_NEEDS_ATTENTION', history: rbFailed(9) };
  const before = await panelFor(doc, [...moveLines(9)]);
  ok(before.main.includes(rbTitle), 'before the restore, the stop is the main message');
  const { main, list } = await panelFor(doc, [...moveLines(9), ...restoreLines(10, 'op-2')]);
  ok(main.includes(UX_ACT.puttingBack), `the header says Restoring: ${main}`);
  ok(!main.includes(rbTitle), `no stop box of the earlier stop: ${main}`);
  ok(!main.includes(stopReasons.get('rollbackFailed').whatToDo), 'and not its What to do');
  ok(list.includes(UX_STEP.makeDiskFromCopy) && list.includes(DISKS), 'the steps of the restore so far are in the list');
});

/* ---- a restore that failed ---------------------------------------------- */
test('a restore that failed: the main block says the restore did not finish, with its reason', async () => {
  const doc = { vmId: VM, state: 'FAILED_NEEDS_ATTENTION', history: rbFailed(9) };
  const why = 'Azure refused the size Standard_D2s_v4: the quota of the family is used up.';
  const events = [...moveLines(9),
    L(at(10, 30), 'restore', 'start', { correlationId: 'op-3' }),
    L(at(10, 31), 'azureops:restore:revertHardware', 'fail', { detail: why }),
    L(at(10, 32), 'restore', 'warn', { detail: why }),
    L(at(10, 33), 'engine:restore', 'fail', { correlationId: 'op-3', detail: why })];
  const { main, list } = await panelFor(doc, events);
  ok(main.includes(UX_ACT.restoreNotDone), `the main block says the restore did not finish: ${main}`);
  ok(main.includes(UX_STEP.restoreWarn), 'and where it left the machine');
  ok(main.includes(why), 'and why');
  eq(main.split(why).length - 1, 1, 'each thing one time');
  ok(!main.includes(rbTitle), 'the earlier stop is not the main message');
  ok(!main.includes(UX_ACT.puttingBack), 'the header no longer says Restoring');
  ok(list.includes(UX_ACT.restoreNotDone) && list.includes(why), `the end is in the list: ${list}`);
});

test('a restore that failed and could not restart the machine says so', async () => {
  const doc = { vmId: VM, state: 'FAILED_NEEDS_ATTENTION', history: rbFailed(9) };
  const words = 'The restore failed, and Azure did not start the machine again.';
  const { main } = await panelFor(doc, [...moveLines(9), L(at(10, 30), 'restore', 'start', { correlationId: 'op-4' }),
    L(at(10, 32), 'restore', 'fail', { detail: words })]);
  ok(main.includes(UX_ACT.restoreNotDone) && main.includes(words), main);
});

test('a restore that worked after one that failed: no card of the failure', async () => {
  const doc = { vmId: VM, state: 'FAILED_NEEDS_ATTENTION', history: rbFailed(9),
    restore: { restoredUtc: at(11, 37), fromCopy: 'pristine', newDiskName: 'st-a-os-restored' } };
  const events = [...moveLines(9), L(at(10, 30), 'restore', 'start', { correlationId: 'op-5' }),
    L(at(10, 32), 'restore', 'warn', { detail: 'refused' }),
    ...restoreLines(11, 'op-6'), L(at(11, 37), 'restore', 'ok', { detail: DONE_LINE })];
  const { main, list } = await panelFor(doc, events);
  ok(!main.includes(UX_STEP.restoreWarn), `the failure is history: ${main}`);
  ok(main.includes(UX_ACT.wasRestored), 'the header says Restored');
  ok(list.includes(UX_STEP.restoreWarn) && list.includes(UX_ACT.restoredStep), 'both restores are in the list');
});

/* ---- a retry ------------------------------------------------------------ */
test('a retry: the list shows the earlier attempt, its outcome, the retry and the new steps', async () => {
  const failWhy = 'The Instance Metadata Service answered before the move and does not answer now.';
  const stop = 'The Verifying step failed, and the product rolled the machine back to how it was: ' + failWhy;
  const doc = { vmId: VM, state: 'GUEST_PREP', history: [
    { tsUtc: at(9, 1), state: 'SAFETY_PRISTINE', outcome: 'ok' },
    { tsUtc: at(9, 30), state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'validationFailedAfterConversion', machineState: 'restored', detail: stop },
    { tsUtc: at(10, 1), state: 'PRECHECK', outcome: 'ok', detail: 'Re-armed at PRECHECK.' },
    { tsUtc: at(10, 3), state: 'GUEST_PREP', outcome: 'ok' }] };
  const events = [
    ...moveLines(9).slice(0, 15),
    L(at(9, 20), 'VALIDATING', 'fail', { detail: failWhy, durationSec: 300 }),
    L(at(9, 21), 'rollback', 'start', { detail: 'Rolling the machine back: Standard_D2s_v4/SCSI' }),
    L(at(9, 25), 'rollback', 'ok', { detail: 'The rollback returned the machine to Standard_D2s_v4/SCSI, and started it.' }),
    L(at(10, 0), 'decision', 'ok', { choice: 'retry', detail: 'retry by operator@example.com' }),
    L(at(10, 0, 30), 'rearm', 'info', { detail: 'Re-armed at PRECHECK.' }),
    L(at(10, 1), 'PRECHECK', 'start'), L(at(10, 2), 'PRECHECK', 'ok', { durationSec: 60 }),
    L(at(10, 3), 'SAFETY_PRISTINE', 'start'), L(at(10, 3, 30), 'SAFETY_PRISTINE', 'ok', { durationSec: 30, detail: 'already taken' }),
    L(at(10, 4), 'GUEST_PREP', 'start')];
  const { main, list } = await panelFor(doc, events);
  ok(!main.includes(stopReasons.get('validationFailedAfterConversion').title), `the stop of the earlier attempt is not the main message: ${main}`);
  ok(list.includes(UX_STEP.decisionRetry), `the retry: ${list}`);
  ok(list.includes(UX_STEP.pristineAlready), 'a step of the new attempt');
  ok(list.includes(failWhy), 'the failure of the earlier attempt');
  ok(list.includes(UX_STEP.rollsBackNote), 'that a rollback followed it');
  ok(list.includes('The rollback returned the machine to Standard_D2s_v4/SCSI'), 'the rollback');
  ok(list.includes(UX_STATE.FAILED_ROLLED_BACK[0]), 'the outcome of the earlier attempt');
  ok(list.indexOf(UX_STEP.pristineAlready) < list.indexOf(UX_STEP.decisionRetry), 'the new attempt is above the retry');
  ok(list.indexOf(UX_STEP.decisionRetry) < list.indexOf(UX_STATE.FAILED_ROLLED_BACK[0]), 'the retry is above the earlier outcome');
});

/* ---- Stop this migration, and Leave this machine out ---------------------- */
test('Stop this migration: the list says the machine is not migrated, and why', async () => {
  // Stop-VmfRun writes the stop in the state document only: no line names the machine.
  const why = 'run stopped by operator@example.com: change window over';
  const doc = { vmId: VM, state: 'SKIPPED', history: [
    { tsUtc: at(9, 1), state: 'SAFETY_PRISTINE', outcome: 'ok' },
    { tsUtc: at(9, 5), state: 'SKIPPED', outcome: 'skip', machineState: 'untouched', detail: why }] };
  const { list } = await panelFor(doc, [...moveLines(9).slice(0, 4)]);
  ok(list.includes(UX_STATE.SKIPPED[0]) && list.includes(why), list);
});

test('Leave this machine out: the reason is in the list one time', async () => {
  const why = 'left out by operator@example.com: later';
  const doc = { vmId: VM, state: 'SKIPPED', history: [
    { tsUtc: at(9, 1), state: 'SAFETY_PRISTINE', outcome: 'ok' },
    { tsUtc: at(9, 30), state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'rolledBack', machineState: 'restored', detail: 'rolled back' },
    { tsUtc: at(10, 0), state: 'SKIPPED', outcome: 'skip', detail: why }] };
  const { list } = await panelFor(doc, [...moveLines(9).slice(0, 4), L(at(10, 0, 1), 'skip', 'skip', { detail: why })]);
  ok(list.includes(UX_STATE.SKIPPED[0]), list);
  eq(list.replace(/title="[^"]*"/g, '').split(why).length - 1, 1, `the reason one time: ${list}`);
});

/* ---- a rollback ---------------------------------------------------------- */
test('a rollback: the failure, the steps of the rollback and the outcome are in the list, newest first', async () => {
  const failWhy = 'Guest validation FAILED: a data disk is not mounted.';
  const doc = { vmId: VM, state: 'FAILED_ROLLED_BACK', history: [
    { tsUtc: at(9, 1), state: 'SAFETY_PRISTINE', outcome: 'ok' },
    { tsUtc: at(9, 30), state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'validationFailedAfterConversion', machineState: 'restored',
      detail: 'The Verifying step failed, and the product rolled the machine back to how it was: ' + failWhy, evidenceRef: 'bootdiag-st-a-abc.json' }] };
  const events = [...moveLines(9).slice(0, 15),
    L(at(9, 20), 'VALIDATING', 'fail', { detail: failWhy }),
    L(at(9, 21), 'rollback', 'start', { detail: 'Rolling the machine back' }),
    L(at(9, 22), 'azureops:rollback:revertSize', 'ok'),
    L(at(9, 25), 'rollback', 'ok', { detail: 'The rollback returned the machine to Standard_D2s_v4/SCSI, and started it.' })];
  const { list, html } = await panelFor(doc, events);
  ok(list.includes(UX_STEP.revertSize), `a step of the rollback: ${list}`);
  ok(list.indexOf(UX_STATE.FAILED_ROLLED_BACK[0]) < list.indexOf(UX_STEP.revertSize), 'the outcome is above the rollback');
  ok(list.includes(`<div class="muted">${failWhy} ${UX_STEP.rollsBackNote}</div>`), `the failure says that a rollback follows: ${list}`);
  ok(list.indexOf(UX_STEP.revertSize) < list.indexOf(`${failWhy} ${UX_STEP.rollsBackNote}`), 'the rollback is above the failure');
  ok(html.includes('data-ev="evidence/bootdiag-st-a-abc.json"'), 'the captured evidence of the stop is still linked');
  // The failure once on its line and once in the sentence of the stop - never again as the line's detail.
  eq(list.replace(/title="[^"]*"/g, '').split(failWhy).length - 1, 2, `the reason, not repeated: ${list}`);
});

test('a stop at Checking: the reason is said one time, and the stop is above the line that led to it', async () => {
  // Invoke-VmfStateMachine writes the closing line of Checking and the stop with the same detail.
  const why = 'The identity has no Microsoft.Compute/virtualMachines/write.';
  const doc = { vmId: VM, state: 'NEEDS_DECISION', history: [
    { tsUtc: at(9, 1), state: 'NEEDS_DECISION', outcome: 'ok', reasonCode: 'permissionsMissing', machineState: 'untouched', detail: why }] };
  const { list } = await panelFor(doc, [L(at(9, 0), 'PRECHECK', 'start'), L(at(9, 1), 'PRECHECK', 'ok', { durationSec: 60, detail: why })]);
  eq(list.replace(/title="[^"]*"/g, '').split(why).length - 1, 1, `the reason one time: ${list}`);
  ok(list.includes(`<b>${UX_STATE.PRECHECK[0]}</b>`), 'the line of Checking is there');
  ok(list.indexOf(UX_STATE.NEEDS_DECISION[0]) < list.indexOf(`<b>${UX_STATE.PRECHECK[0]}</b>`), 'the stop is above it, at the same time');
});

test('a step that failed one time and then worked is not red, and says so', async () => {
  const doc = { vmId: VM, state: 'SAFETY_COPY', history: [] };
  const { list } = await panelFor(doc, [L(at(9, 1), 'azureops:deallocate', 'fail', { detail: 'throttled' }),
    L(at(9, 2), 'azureops:deallocate', 'ok')]);
  ok(list.includes(UX_STEP.recoveredNote), `the note: ${list}`);
  ok(!list.includes('<li class="fail">'), 'no red line');
});

/* ---- the end of a restore, on its own ------------------------------------- */
test('restoreEndAfter: only the newest restore, only when it did not finish, and only when nothing came after', () => {
  const doc = { vmId: VM, state: 'FAILED_NEEDS_ATTENTION', history: rbFailed(9) };
  const start = (h, op) => L(at(h, 30), 'restore', 'start', { correlationId: op });
  const warn = (h) => L(at(h, 32), 'restore', 'warn', { detail: 'refused' });
  const okEnd = (h) => L(at(h, 32), 'restore', 'ok', { detail: DONE_LINE });
  ok(page.restoreEndAfter(doc, [start(10, 'a'), warn(10)]), 'a restore that did not finish');
  eq(page.restoreEndAfter(doc, [start(10, 'a')]), null, 'one that runs');
  eq(page.restoreEndAfter(doc, [start(10, 'a'), okEnd(10)]), null, 'one that worked, before its record is read');
  ok(page.restoreEndAfter(doc, [start(10, 'a'), okEnd(10), start(11, 'b'), warn(11)]), 'the newest restore decides');
  eq(page.restoreEndAfter(doc, [start(10, 'a'), L(at(10, 31), 'engine:restore', 'refused', { correlationId: 'b' })]), null,
    'the refusal of ANOTHER restore does not end this one');
  const engineOnly = page.restoreEndAfter(doc, [start(10, 'a'), L(at(10, 31), 'engine:restore', 'fail', { correlationId: 'a', detail: 'The job stopped.' })]);
  ok(engineOnly && engineOnly.lines.length === 1, 'the engine fail line of the same operation ends it');
  eq(page.restoreEndAfter({ ...doc, history: [...rbFailed(9), { tsUtc: at(11, 0), state: 'PRECHECK', outcome: 'ok' }] }, [start(10, 'a'), warn(10)]), null,
    'a retry after it: the machine shows the retry');
  eq(page.restoreEndAfter({ ...doc, restore: { restoredUtc: at(10, 33) } }, [start(10, 'a'), L(at(10, 32), 'restore', 'fail', { detail: 'swap left' })]), null,
    'a record as new as it: the restore box says it (a swap that waits for Finish)');
});

test('a restore whose job stopped with no end line of its own: the engine line is the reason', async () => {
  const doc = { vmId: VM, state: 'FAILED_NEEDS_ATTENTION', history: rbFailed(9) };
  const { main } = await panelFor(doc, [...moveLines(9), L(at(10, 30), 'restore', 'start', { correlationId: 'op-7' }),
    L(at(10, 31), 'engine:restore', 'fail', { correlationId: 'op-7', detail: 'The engine job stopped: out of memory.' })]);
  ok(main.includes(UX_ACT.restoreNotDone) && main.includes('The engine job stopped: out of memory.'), main);
  ok(!main.includes(rbTitle), 'not the earlier stop');
});

test('a restore that waits for Finish the restore: one box says it did not finish', async () => {
  const doc = { vmId: VM, state: 'MIGRATED', history: migratedHistory(9),
    restore: { restoredUtc: at(10, 36), fromCopy: 'pristine', newDiskName: 'st-a-os-restored' },
    swapPending: { kind: 'restore', leftUtc: at(10, 36), error: 'x', swaps: [{ lun: 0 }], swapped: [] } };
  const { main } = await panelFor(doc, [...moveLines(9), ...restoreLines(10, 'op-8'), L(at(10, 36), 'restore', 'fail', { detail: 'Azure did not swap the data disk on LUN 0.' })]);
  eq(main.split(UX_ACT.restoreNotDone).length - 1, 1, `one box: ${main}`);
});

test('a retry after a restore that failed: the main block shows the new attempt, not the restore', async () => {
  const doc = { vmId: VM, state: 'GUEST_PREP', history: [...rbFailed(9), { tsUtc: at(11, 0), state: 'PRECHECK', outcome: 'ok' }] };
  const { main } = await panelFor(doc, [...moveLines(9), L(at(10, 30), 'restore', 'start', { correlationId: 'op-9' }),
    L(at(10, 32), 'restore', 'warn', { detail: 'refused' }), L(at(11, 1), 'GUEST_PREP', 'start')]);
  ok(!main.includes(UX_ACT.restoreNotDone), `no box of the restore: ${main}`);
  ok(main.includes(UX_STATE.GUEST_PREP[0]), 'the header says the step that runs');
});

test('a step that the engine tried again says which attempt, and its cause', async () => {
  const cause = 'Connection reset by peer.';
  const doc = { vmId: VM, state: 'STOPPED', history: migratedHistory(9).slice(0, 1) };
  const { list } = await panelFor(doc, [L(at(9, 1), 'STOPPED', 'start'),
    L(at(9, 2), 'STOPPED', 'retry', { detail: cause, attempt: 1, maxAttempts: 2 }), L(at(9, 3), 'STOPPED', 'start')]);
  ok(list.includes(UX_STEP.retriedNote.replace('{n}', '1').replace('{max}', '2')), list);
  ok(list.includes(cause), 'the cause');
});

/* ---- the duration names the step it measures (STATUS-WORDS-1) ------------ */
test('the duration on a line is the time of its own step', async () => {
  const doc = { vmId: VM, state: 'SAFETY_COPY', history: migratedHistory(9).slice(0, 1) };
  const { list } = await panelFor(doc, [L(at(9, 1), 'STOPPED', 'start'), L(at(9, 2), 'STOPPED', 'ok', { durationSec: 36 })]);
  ok(list.includes(UX_MISC.tookStep.replace('{step}', UX_RAN.STOPPED).replace('{n}', '36')), list);
  ok(list.includes(`<b>${UX_STATE.STOPPED[0]}</b>`), 'a step of the move keeps its name as the heading');
});

test('the list has every line of the machine, not only the 30 that the Activity table shows', async () => {
  const doc = { vmId: VM, state: 'MIGRATED', history: migratedHistory(10) };
  const many = Array.from({ length: 40 }, (_, i) => L(at(11, i), 'restore', 'info', { detail: `Restored data disk number ${i}.` }));
  const { list } = await panelFor(doc, many);
  ok(list.includes('Restored data disk number 0.') && list.includes('Restored data disk number 39.'), list.slice(0, 300));
});

/* The sample run of the demo page (and the manual's pictures of the panel):
 * its log has the closing line of each step its histories record. */
test('the demo log gets the closing line of each sample step, and a step fails only into a stop', () => {
  const m = PAGE.match(/\/\/ RESTORE-PANEL-TIMELINE-1: the machine panel lists[\s\S]*?\n(\(\(\) => \{[\s\S]*?\n\}\)\(\);)/);
  ok(m, 'the page builds the demo lines');
  const DEMO = {
    'logs/events.jsonl': [{ tsUtc: at(8, 0), step: 'wave', outcome: 'ok' }, { tsUtc: at(10, 0), step: 'odcr', outcome: 'ok' }],
    'state/x.json': { vmId: 'x', history: [
      { tsUtc: at(9, 0), state: 'PRECHECK', outcome: 'ok' }, { tsUtc: at(9, 5), state: 'STARTING', outcome: 'ok' },
      { tsUtc: at(9, 6), state: 'VALIDATING', outcome: 'fail' },
      { tsUtc: at(9, 9), state: 'FAILED_ROLLED_BACK', outcome: 'fail' }] },
  };
  // eslint-disable-next-line no-new-func
  new Function('DEMO', 'UX_RAN', 'TERMINAL_STATES', m[1])(DEMO, UX_RAN, TERMINAL_STATES);
  const lines = DEMO['logs/events.jsonl'];
  eq(lines.map(e => `${e.step}:${e.outcome}`), ['wave:ok', 'PRECHECK:ok', 'STARTING:ok', 'VALIDATING:fail', 'odcr:ok'], `in time order: ${JSON.stringify(lines)}`);
  eq(lines[3].tsUtc, at(9, 9), 'at the time of the entry that follows the step');
  eq(lines[3].vmId, 'x', 'the machine');
});

run('restore panel timeline');
