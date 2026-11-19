/* POWER-ONLY-CHANGED-1, 2026-11-06. A stop that Azure would not let put a
 * machine back to the power state Checking found was shown as "This machine
 * is NOT as it was", with Try this machine again held until a restore - and
 * a stop at Checking has no copy to restore. Its disks, size, controller and
 * network are as they were. The engine now names the power state on the
 * stop (powerNotPutBack), and the retry puts it back first.
 *
 * RUN, not read: the page's own powerOwed, retryHeld, stopControls and
 * whyStoppedCard.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const table = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'stop-reasons.json'), 'utf8'));
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/const PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
const U = globalThis.UX_ACT;
globalThis.esc = (s) => String(s ?? '');
globalThis.canApprove = () => true;
globalThis.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
globalThis.retryLines = table.retryLines;
const page = liftAll('migrations.html', ['powerOwed', 'retryHeld', 'stopControls', 'attemptStop', 'currentStop', 'whyStoppedCard', 'skipMachineState', 'powerName', 'askPowerBack', 'askSkipVm']);

const stop = (extra) => ({ tsUtc: '2026-11-06T10:00:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'ok',
  reasonCode: 'rollbackDisksBeforeMoveNotMade', machineState: 'changed', detail: 'd', ...extra });

test('the panel says only the power state is not as it was, and that the retry puts it back', () => {
  const doc = { state: 'FAILED_NEEDS_ATTENTION', history: [stop({ powerNotPutBack: 'PowerState/deallocated' })] };
  const html = page.whyStoppedCard(doc);
  ok(html.includes(U.whyPowerNotBack), html);
  ok(!html.includes(U.whyNotBack), 'not the line for a machine to restore');
  ok(html.includes(U.whyPowerDo) && /Try this machine again/.test(U.whyPowerDo), U.whyPowerDo);
});

test('a machine changed in another way keeps the line for a machine that is not as it was', () => {
  const doc = { state: 'FAILED_NEEDS_ATTENTION', history: [stop({ reasonCode: 'rollbackFailed' })] };
  const html = page.whyStoppedCard(doc);
  ok(html.includes(U.whyNotBack), html);
  ok(!html.includes(U.whyPowerNotBack), 'no power line');
});

test('a power state this build does not know is not a power state to put back', () => {
  const doc = { state: 'FAILED_NEEDS_ATTENTION', history: [stop({ powerNotPutBack: 'PowerState/starting' })] };
  eq(page.powerOwed(doc), null, 'unknown');
  eq(page.powerOwed({ history: [stop({ powerNotPutBack: 'PowerState/running' })] }), 'PowerState/running', 'Running: a machine the move stopped');
  ok(page.whyStoppedCard(doc).includes(U.whyNotBack), 'the cautious line');
  eq(page.retryHeld(doc), true, 'held');
});

test('powerOwed: the line of a put-back that worked ends it', () => {
  const doc = { state: 'PRECHECK', history: [stop({ powerNotPutBack: 'PowerState/stopped' }),
    { tsUtc: '2026-11-06T11:00:00Z', state: 'PRECHECK', outcome: 'ok' }] };
  eq(page.powerOwed(doc), 'PowerState/stopped', 'owed');
  doc.history.push({ tsUtc: '2026-11-06T11:01:00Z', state: 'PRECHECK', outcome: 'ok', machineState: 'untouched' });
  eq(page.powerOwed(doc), null, 'put back');
  const restored = { state: 'FAILED_ROLLED_BACK', history: [stop({ machineState: 'restored', powerNotPutBack: 'PowerState/stopped' })] };
  eq(page.powerOwed(restored), null, 'only a changed stop names a power state owed');
});

test('the retry is offered for a power state not put back, also on a stop whose retry is otherwise not offered (a cluster node)', () => {
  const node = stopReasons.get('clusterNode');
  eq(node.retry, 'outOfScope', 'the cluster node stop is out of scope');
  eq(page.stopControls('NEEDS_DECISION', node, true, true, false).retry, false, 'no retry, as before');
  eq(page.stopControls('NEEDS_DECISION', node, true, true, true).retry, true, 'the retry puts the power state back');
  eq(page.stopControls('NEEDS_DECISION', node, false, true, true).retry, false, 'still only for an operator');
});

test('the drill passes the power state to stopControls', () => {
  ok(PAGE.includes('const offer = stopControls(doc.state, lastGuidance, canOperate(), canApprove(), !!powerOwed(doc));'), 'the drill asks powerOwed');
});

test('a cluster node owed its power state: the card says the retry returns the power state, and none of the words of the reason that are not true of it', () => {
  const node = stopReasons.get('clusterNode');
  const doc = { state: 'NEEDS_DECISION', history: [stop({ state: 'NEEDS_DECISION', reasonCode: 'clusterNode', powerNotPutBack: 'PowerState/deallocated' })] };
  const html = page.whyStoppedCard(doc);
  ok(html.includes(U.whyPowerMeaning), 'the power meaning');
  ok(html.includes(U.whyPowerDo), 'the power what to do');
  ok(!html.includes(retryLines.outOfScope), `not "${retryLines.outOfScope}"`);
  ok(!html.includes(node.meaning), 'not the meaning of the reason');
  ok(!html.includes(node.whatToDo), 'not the what to do of the reason');
  ok(/Leave this machine out also returns/.test(U.whyPowerDo), U.whyPowerDo);
  ok(html.includes(node.title), 'the title of the reason stays');
});

test('the same stop after the product returned the power state: the reason as it is, and nothing changed', () => {
  const node = stopReasons.get('clusterNode');
  const doc = { state: 'NEEDS_DECISION', history: [stop({ state: 'NEEDS_DECISION', reasonCode: 'clusterNode', powerNotPutBack: 'PowerState/deallocated' }),
    { tsUtc: '2026-11-06T11:00:00Z', state: 'NEEDS_DECISION', outcome: 'ok', machineState: 'untouched' }] };
  const html = page.whyStoppedCard(doc);
  ok(html.includes(node.meaning), 'the meaning of the reason');
  ok(html.includes(U.whyUntouched), 'nothing changed');
  ok(!html.includes(U.whyPowerMeaning), 'no power words');
});

test('skipMachineState: a power state returned since the stop is untouched (held to skip-machine-state.json too)', () => {
  const owed = { state: 'NEEDS_DECISION', history: [stop({ state: 'NEEDS_DECISION', reasonCode: 'clusterNode', powerNotPutBack: 'PowerState/stopped' })] };
  eq(page.skipMachineState(owed), 'changed', 'owed');
  owed.history.push({ tsUtc: '2026-11-06T11:00:00Z', state: 'NEEDS_DECISION', outcome: 'ok', machineState: 'untouched' });
  eq(page.skipMachineState(owed), 'untouched', 'returned');
});

test('Return to the power state posts the engine operation powerback for the machine, with the note', async () => {
  let opened = null; let posted = null;
  globalThis.openModal = (o) => { opened = o; };
  globalThis.noteField = () => ({ id: 'note', required: true });
  globalThis.runSeg = () => 'run-1';
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  const doc = { state: 'SKIPPED', history: [stop({ state: 'SKIPPED', powerNotPutBack: 'PowerState/stopped' })] };
  page.askPowerBack('vm-1', doc);
  ok(opened.desc.includes('Stopped'), opened.desc);
  eq(opened.confirmLabel, U.powerBack, 'the button says what it does');
  await opened.onConfirm({ note: 'left out' });
  eq(posted[0], 'runs/run-1/engine/powerback', 'the route');
  eq(JSON.stringify(posted[1]), JSON.stringify({ vmId: 'vm-1', note: 'left out' }), 'the body');
  eq(page.powerName('PowerState/deallocated'), U.powerDeallocated, 'the portal name');
});

test('the panel shows the line and the button while the power state is owed and no job works on the machine', () => {
  ok(PAGE.includes("const owedPower = (powerOwed(doc) && !VmfHelp.machineAtWork(doc.state)) ? powerOwed(doc) : null;"), 'the rule');
  ok(PAGE.includes("$('#powerback-btn')?.addEventListener('click', () => panelDialog(vmId, () => askPowerBack(vmId, doc)));"), 'wired');
  ok(PAGE.includes('${powerBackLine}'), 'the line is painted');
});
test('Leave this machine out says the product returns a machine owed its power state, and that it is then free', () => {
  let opened = null;
  globalThis.openModal = (o) => { opened = o; };
  const doc = { state: 'FAILED_NEEDS_ATTENTION', history: [stop({ powerNotPutBack: 'PowerState/deallocated' })] };
  page.askSkipVm('vm-1', doc);
  ok(opened.desc.includes(U.skipPowerBack.replace('{power}', U.powerDeallocated)), opened.desc);
  ok(!opened.desc.includes(U.skipClaimKept), 'not the words of a machine to restore');
  ok(opened.desc.startsWith(U.skipDescPower), 'the description that does not say nothing in Azure changes');
  ok(!opened.desc.includes(U.skipDesc), 'not: Nothing in Azure changes for it');
  const changed = { state: 'FAILED_NEEDS_ATTENTION', history: [stop({ reasonCode: 'rollbackFailed' })] };
  page.askSkipVm('vm-1', changed);
  ok(opened.desc.includes(U.skipClaimKept), 'a machine changed in another way keeps its words');
  ok(opened.desc.startsWith(U.skipDesc), 'and the description that nothing in Azure changes');
  ok(!/no machine is touched, started or stopped/.test(U.stopRunDesc) && /returns the machine to that power state/.test(U.stopRunDesc), U.stopRunDesc);
});
run('power-only-changed');
