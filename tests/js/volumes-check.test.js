/* VOLUMES-RESTORE-MIGRATED-1, 2026-11-15. Restore this machine on a migrated
 * machine can leave a volume not mounted: the record owes a check of the
 * volumes (volumesCheckOwed), and the machine stays MIGRATED, where Try this
 * machine again is not offered. Check the volumes on the machine panel starts
 * the engine operation checkvolumes, which runs the check of the retry with no
 * move. openModal gives the dialog Cancel and Escape (hard rule 11).
 *
 * RUN, not read: the page's own volumesCheckOffer and askVolumesCheck.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const U = globalThis.UX_ACT;
globalThis.VmfHelp = { machineAtWork: (s) => !['MIGRATED', 'SKIPPED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION', 'PLANNED'].includes(s) };
const page = liftAll('migrations.html', ['volumesCheckOffer', 'volumesCheckStarted', 'volumesStartedLine', 'powerName', 'askVolumesCheck']);
for (const k of ['volumesCheckStarted', 'powerName']) { globalThis[k] = page[k]; }

const owed = (reason, state = 'MIGRATED', extra = {}) => ({ state, volumesCheckOwed: { reason, kind: 'restore', tsUtc: '2026-11-15T10:00:00Z' }, history: [], ...extra });

test('a migrated machine that owes the check: the button for an operator, and the line that says what to do', () => {
  const o = page.volumesCheckOffer(owed('volumesNotBack'), true, false);
  eq(o.button, true, 'the button');
  eq(o.line, U.volumesCheckLineMissing, 'the line for a volume found not mounted');
  eq(page.volumesCheckOffer(owed('notChecked'), true, false).line, U.volumesCheckLineUnknown, 'the line for a check that did not run');
});

test('no button for a viewer, while a job works on the machine, with a data disk swap left, or with nothing owed', () => {
  eq(page.volumesCheckOffer(owed('volumesNotBack'), false, false).button, false, 'a viewer');
  eq(page.volumesCheckOffer(owed('volumesNotBack'), true, true).button, false, 'a restore or a finish runs');
  eq(page.volumesCheckOffer(owed('volumesNotBack', 'CONVERTING'), true, false).button, false, 'a wave works on it');
  eq(page.volumesCheckOffer(owed('volumesNotBack', 'MIGRATED', { swapPending: { kind: 'restore' } }), true, false).button, false, 'a swap is left');
  eq(page.volumesCheckOffer({ state: 'MIGRATED', history: [] }, true, false).button, false, 'nothing owed');
  eq(page.volumesCheckOffer({ state: 'MIGRATED', history: [] }, true, false).line, '', 'and no line');
});

test('a stopped machine shows the button, and its stop card says what to do, so no second line', () => {
  const o = page.volumesCheckOffer(owed('volumesNotBack', 'FAILED_NEEDS_ATTENTION'), true, false);
  eq(o.button, true, 'the button');
  eq(o.line, '', 'the stop card already says it');
});

test('Check the volumes posts the engine operation checkvolumes for the machine', async () => {
  let opened = null; let posted = null;
  globalThis.openModal = (o) => { opened = o; };
  globalThis.runSeg = () => 'run-1';
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  page.askVolumesCheck('vm-1');
  eq(opened.title, U.volumesCheckTitle, 'the title');
  eq(opened.desc, U.volumesCheckDesc, 'the words');
  eq(opened.confirmLabel, U.volumesCheck, 'the button says what it does');
  eq(opened.doneMessage, U.volumesCheckDone, 'what happens next');
  await opened.onConfirm({});
  eq(posted[0], 'runs/run-1/engine/checkvolumes', 'the route');
  eq(JSON.stringify(posted[1]), JSON.stringify({ vmId: 'vm-1' }), 'the body');
});

test('the panel paints the line and the button, and wires the button to the dialog', () => {
  ok(PAGE.includes('${volumesCheckLine}'), 'the line is painted');
  ok(PAGE.includes("$('#volumescheck-btn')?.addEventListener('click', () => panelDialog(vmId, () => askVolumesCheck(vmId)));"), 'wired');
});

/* VOLUMES-CHECK-JOB-STOP-1: a job of Check the volumes that stopped after it
 * started a machine that was turned off. */
const started = (extra = {}) => ({ state: 'MIGRATED', history: [], volumesCheckOwed: { reason: 'volumesNotBack', kind: 'restore', tsUtc: '2026-11-15T10:00:00Z' },
  captured: { volumesCheckPower: { power: 'PowerState/deallocated', status: 'started', tsUtc: '2026-11-15T10:00:00Z', ...extra } } });

test('a start for the check that the service found with no job: the panel says the machine runs, and its power state before', () => {
  const line = page.volumesStartedLine(started({ stoppedUtc: '2026-11-15T10:20:00Z', resumes: 1 }));
  eq(line, U.volumesStartedStopped.replace('{power}', U.powerDeallocated), 'the line');
});

test('at the limit the line says to select Check the volumes, and the button is there', () => {
  const doc = started({ stoppedUtc: '2026-11-15T10:20:00Z', resumes: 3, gaveUp: true });
  eq(page.volumesStartedLine(doc), U.volumesStartedGaveUp.replace('{power}', U.powerDeallocated), 'the line');
  eq(page.volumesCheckOffer(doc, true, false).button, true, 'the button');
  delete doc.volumesCheckOwed;
  eq(page.volumesCheckOffer(doc, true, false).button, true, 'also with nothing owed: the check returns the machine');
});

test('no line while a check can run (not found stopped), after the return, or while a job works on the machine', () => {
  eq(page.volumesStartedLine(started()), '', 'no stoppedUtc: a check runs now');
  eq(page.volumesStartedLine(started({ stoppedUtc: 'x', status: 'putBack' })), '', 'returned');
  const atWork = started({ stoppedUtc: 'x' }); atWork.state = 'PRECHECK';
  eq(page.volumesStartedLine(atWork), '', 'a wave works on it');
});
run('volumes-check');
