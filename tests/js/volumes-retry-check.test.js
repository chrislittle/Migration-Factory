/* VOLUMES-RETRY-CHECK-1, lab findings (2026-11-14).
 *
 * (a) The check before a retry stopped the machine again, and the Activity
 * list showed only the label of Checking - the volumes it names were only in
 * the hover. The list now shows the sentence.
 * (b) Try this machine again said "The whole move runs again from the first
 * step" also where the retry first checks the volumes and may change nothing.
 *
 * RUN, not read: the page's own stepText and askResolve.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

globalThis.esc = (s) => String(s ?? '').replace(/</g, '&lt;');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.UX_STATE = liftConst('migrations.html', 'UX_STATE');
globalThis.UX_MISC = liftConst('migrations.html', 'UX_MISC');
globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
const UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_ACT = UX_ACT;
const page = liftAll('migrations.html', ['stepText', 'retryFacts', 'askResolve']);

const vmId = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1';
const stopLine = 'The product did not try this machine again. These volumes were mounted before the move and are not mounted now: /var/crash.';

test('(a) the stop of the check before a retry shows its sentence, not the label of Checking', () => {
  eq(page.stepText({ step: 'PRECHECK', outcome: 'ok', vmId, detail: stopLine }), stopLine);
});

test('(a) an ordinary Checking line keeps its label', () => {
  const plain = page.stepText({ step: 'PRECHECK', outcome: 'ok', vmId, detail: 'power=PowerState/running' });
  ok(plain !== 'power=PowerState/running', plain);
});

function world() {
  const w = { modal: null };
  globalThis.ago = () => '5m ago';
  globalThis.noteField = () => ({ id: 'note' });
  globalThis.runSeg = () => 'run-1';
  globalThis.apiFetch = async () => ({});
  globalThis.stopReasons = new Map([['volumesNotBack', { title: 'A volume is not mounted after the rollback or the restore' }]]);
  globalThis.openModal = (m) => { w.modal = m; };
  return w;
}
const stop = { tsUtc: '2026-11-14T10:00:00Z', state: 'FAILED_NEEDS_ATTENTION', outcome: 'fail', reasonCode: 'volumesNotBack', machineState: 'changed' };

test('(b) a retry that owes a check of the volumes says the check comes first', () => {
  const w = world();
  page.askResolve('vm1', { state: 'FAILED_NEEDS_ATTENTION', volumesCheckOwed: { reason: 'volumesNotBack', kind: 'rollback' }, history: [stop] });
  ok(w.modal.desc.includes(UX_ACT.resolveVolumesFirst), w.modal.desc);
  ok(!w.modal.desc.includes(UX_ACT.resolveDesc), w.modal.desc);
});

test('(b) the check that could not run says the same', () => {
  const w = world();
  page.askResolve('vm1', { state: 'FAILED_ROLLED_BACK', volumesCheckOwed: { reason: 'notChecked', kind: 'rollback' },
    history: [{ tsUtc: '2026-11-14T10:00:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', reasonCode: 'rolledBack', machineState: 'restored' }] });
  ok(w.modal.desc.includes(UX_ACT.resolveVolumesFirst), w.modal.desc);
});

test('(b) any other retry keeps the whole-move line', () => {
  const w = world();
  page.askResolve('vm1', { state: 'FAILED_ROLLED_BACK', history: [{ tsUtc: '2026-11-14T10:00:00Z', outcome: 'fail', reasonCode: 'rolledBack' }] });
  ok(w.modal.desc.includes(UX_ACT.resolveDesc), w.modal.desc);
  ok(!w.modal.desc.includes(UX_ACT.resolveVolumesFirst), w.modal.desc);
});

run('volumes-retry-check');
