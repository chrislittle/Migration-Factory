/* CODE-NOTE-ACK-SAVED-1: the ticked note about machines defined in code was
 * lost when the plan was signed off without a start.
 *
 * Found in the final lab on a new install (2026-11-13). On the wizard's Run it
 * step the operator ticked "I understand, and I will reconcile our definitions
 * after the migration." and signed the plan off. Only Start the plan sent the
 * tick to the service, so nothing was saved: the Run step showed the box
 * unticked again, and the Migrations page said no wave could start until
 * somebody accepted the note. A wave the plan's timer made due was refused by
 * the engine for the same missing file.
 *
 * RUN, not read, where a function can be run: saveIacAck is the page's own.
 * The handlers' order is read from their bodies, as note-error-clears does.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const saveIacAck = lift('wizard.html', 'saveIacAck');
const ackGiven = lift('wizard.html', 'ackGiven');

function setUp({ acked = false, operator = true, ticked = true } = {}) {
  const calls = [];
  globalThis.acknowledged = acked;
  globalThis.canOperate = operator;
  globalThis.runForm = { ack: ticked };
  globalThis.runSeg = () => 'r1';
  globalThis.runBody = (b) => Object.assign({ store: 's' }, b);
  globalThis.api = async (method, url, body) => { calls.push([method, url, body]); return {}; };
  return calls;
}

test('a ticked box is saved, through the endpoint the Start handler used', async () => {
  const calls = setUp();
  eq(await saveIacAck(), true, 'it says it saved');
  eq(calls, [['POST', 'runs/r1/acknowledge', { store: 's', topic: 'infrastructure-as-code' }]], 'one acknowledgement, the same topic');
  eq(globalThis.acknowledged, true, 'and the page knows the note is accepted');
});

test('an unticked box saves nothing', async () => {
  const calls = setUp({ ticked: false });
  eq(await saveIacAck(), false, 'nothing saved');
  eq(calls.length, 0, 'no call');
  eq(globalThis.acknowledged, false, 'still not accepted');
});

test('a note already accepted is not written again', async () => {
  // The store keeps the person who accepted it first, and when.
  const calls = setUp({ acked: true });
  eq(await saveIacAck(), false, 'nothing saved');
  eq(calls.length, 0, 'no call');
});

test('somebody who is not an operator saves nothing (the service would refuse it)', async () => {
  const calls = setUp({ operator: false });
  eq(await saveIacAck(), false, 'nothing saved');
  eq(calls.length, 0, 'no call');
});

test('a refused save leaves the note not accepted, and says why', async () => {
  setUp();
  globalThis.api = async () => { throw new Error('403: no'); };
  let caught = null;
  try { await saveIacAck(); } catch (e) { caught = e; }
  ok(caught && /403/.test(caught.message), 'the error reaches the handler');
  eq(globalThis.acknowledged, false, 'not marked accepted');
});

// The stored document counts by the Migrations page's rule: it names a person.
test('the stored acknowledgement counts only when it names who accepted it', () => {
  eq(ackGiven({ acknowledgedBy: 'operator@example.com' }), true, 'named');
  eq(ackGiven({ acknowledgedBy: '' }), false, 'nobody named');
  eq(ackGiven({}), false, 'no name');
  eq(ackGiven(null), false, 'no document');
});

const handler = (id) => {
  const at = WIZ.indexOf(`$('#${id}')?.addEventListener('click'`);
  ok(at > 0, `${id} handler found`);
  return WIZ.slice(at, WIZ.indexOf('\n  });', at));
};

test('Sign off saves the ticked note, after the sign-off and before the page reads the run again', () => {
  const h = handler('signoff');
  const sign = h.indexOf('/approve-plan`');
  const save = h.indexOf('await saveIacAck()');
  const reread = h.indexOf('await readRun()');
  ok(sign > 0, 'the sign-off call is in the handler');
  ok(save > sign, 'the note is saved after the sign-off is accepted');
  ok(reread > save, 'and before the step is drawn again from the store');
});

test('Start the plan saves it the same way, before any start time or start', () => {
  const h = handler('go5');
  const save = h.indexOf('await saveIacAck()');
  const sched = h.indexOf('/schedule`');
  const start = h.indexOf('/engine/wave`');
  ok(save > 0 && sched > save && start > save, 'saved first');
  ok(!/runs\/\$\{runSeg\(\)\}\/acknowledge/.test(h), 'one way to save it, not two');
});

test('the Run step reads the stored acknowledgement with the run', () => {
  const reads = WIZ.match(/const RUN_READS = \[[^\]]*\]/)[0];
  ok(reads.includes("'acknowledgements/infrastructure-as-code.json'"), 'asked for in the one store call');
  const at = WIZ.indexOf('async function readRun()');
  const body = WIZ.slice(at, WIZ.indexOf('\n}\n', at));
  ok(/readDoc\(`\$\{pre\}\/acknowledgements\/infrastructure-as-code\.json`, held\)/.test(body), 'read by readRun');
  ok(/acknowledged = ackGiven\(/.test(body), 'and decides whether the note is asked for');
});

run('code-note-ack-saved');
