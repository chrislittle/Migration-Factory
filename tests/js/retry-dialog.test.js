/* SAFETY-RETRY-1: Try this machine again says when the machine stopped and
 * why, before what a retry does - so a retry days later reads as days later.
 *
 * RUN, not read: the page's own retryFacts and askResolve.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const UX_ACT = liftConst('migrations.html', 'UX_ACT');
const page = liftAll('migrations.html', ['retryFacts', 'askResolve']);

function world() {
  const w = { modal: null };
  globalThis.UX_ACT = UX_ACT;
  globalThis.esc = (s) => String(s ?? '').replace(/</g, '&lt;');
  globalThis.ago = () => '5d ago';
  globalThis.noteField = () => ({ id: 'note' });
  globalThis.runSeg = () => 'run-1';
  globalThis.apiFetch = async () => ({});
  globalThis.stopReasons = new Map([['dataOnTempDrive', { title: 'Files were found on the temporary disk' }]]);
  globalThis.openModal = (m) => { w.modal = m; };
  return w;
}
const stopped = {
  state: 'NEEDS_DECISION',
  history: [
    // An earlier stop, a week before: the dialog names the LAST one.
    { state: 'NEEDS_DECISION', tsUtc: '2026-09-14T09:05:00Z', outcome: 'ok', reasonCode: 'driverBelowFloor' },
    { state: 'PRECHECK', tsUtc: '2026-09-21T09:00:00Z', outcome: 'ok' },
    { state: 'NEEDS_DECISION', tsUtc: '2026-09-21T09:05:00Z', outcome: 'ok', reasonCode: 'dataOnTempDrive' },
  ],
};

test('the facts are the stop itself: its time and its reason in the product words', () => {
  world();
  const f = page.retryFacts(stopped);
  eq(f.when, '2026-09-21T09:05:00Z');
  eq(f.reason, 'Files were found on the temporary disk');
  eq(page.retryFacts({ history: [] }), null);
});

test('the dialog shows when and why first, then that the whole move runs again with new safety copies', () => {
  const w = world();
  page.askResolve('vm-1', stopped);
  ok(w.modal.rawDesc === true, 'markup, escaped part by part');
  const d = w.modal.desc;
  ok(d.includes(UX_ACT.resolveStopped) && d.includes('5d ago'), d);
  ok(d.includes('Files were found on the temporary disk'), d);
  ok(d.indexOf(UX_ACT.resolveStopped) < d.indexOf(UX_ACT.resolveDesc), 'the facts come first');
  ok(/new safety copies/.test(UX_ACT.resolveDesc), UX_ACT.resolveDesc);
});

test('a reason is escaped', () => {
  const w = world();
  globalThis.stopReasons = new Map([['x', { title: '<script>' }]]);
  page.askResolve('vm-1', { history: [{ tsUtc: '2026-09-21T09:05:00Z', reasonCode: 'x', outcome: 'fail' }] });
  ok(!w.modal.desc.includes('<script>'), w.modal.desc);
});

run('retry-dialog');
