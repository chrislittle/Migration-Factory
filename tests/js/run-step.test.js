/* The last step of the wizard - "Run it".
 *
 * RUNSTEP-1 fixed its wording for a model where the product started ONE wave
 * and the rest waited for a person. PLANRUN-1 replaced the model, as the owner
 * asked: "we should just be signing off & go, and we are not starting JUST
 * wave 2 its 8 waves."
 *
 * And START-TWICE-1: one button slot did two jobs in turn - "Approve wave-2",
 * then "Start wave-2" in the same place - so it had to be pressed twice. The
 * agreed design: sign-off sits in its own section, Start stays at the bottom
 * and comes alive once the plan is signed off, and each says why it waits.
 *
 * RUN, not read: the wizard's own renderStep5 is driven, and the markup it
 * paints is what is measured.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, eq, run, liftConst, lift, liftAll } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const UX = liftConst('wizard.html', 'UX');
const renderStep5 = lift('wizard.html', 'renderStep5');

const helpBtn = lift('wizard.html', 'tHelpBtn');
// DECIDE-ROLE-1: the accept controls are drawn by two functions of their own.
const acceptControlFn = lift('wizard.html', 'acceptControl');
const acceptAllControlFn = lift('wizard.html', 'acceptAllControl');
// WAVE-APPROVE-1: each wave's own sign-off state.
const waveSignStateFn = lift('wizard.html', 'waveSignState');
// WIZARD-START-ROLE-1: Start the plan is drawn by a function of its own.
const startControlFn = lift('wizard.html', 'startControl');

function paint({ accepted = ['w1', 'w2', 'w3'], signoff = null, current = true, approver = true, operator = true, how = 'all', times = {}, help = [], approved = [], acked = true, entries = null } = {}) {
  const waves = [['w1', { n: 2 }], ['w2', { n: 1 }], ['w3', { n: 4 }]];
  const node = () => ({ addEventListener() {}, style: {}, value: '', textContent: '', querySelectorAll: () => [] });
  globalThis.UX = UX;
  globalThis.planWaves = () => waves;
  globalThis.plan = { entries: entries ?? [{ wave: 'w1', policy: { throttle: 5 } }] };
  // REBUILD-REMOVE-ACCEPT-1: no box for a rebuild or an identity any more.
  globalThis.runForm = { note: '', throttle: 3, throttleTouched: false, ack: false, how, times };
  globalThis.acceptances = new Map(accepted.map(w => [w, { acceptedBy: 'operator@example.com' }]));
  globalThis.planSignoff = signoff;
  globalThis.planSignoffCurrent = current;
  globalThis.approvals = new Map(approved.map(w => [w, { wave: w, approvedBy: { identity: 'approver@example.com' } }]));
  globalThis.waveSignState = waveSignStateFn;
  globalThis.canApprove = approver;
  globalThis.canOperate = operator;
  globalThis.acceptControl = acceptControlFn;
  globalThis.acceptAllControl = acceptAllControlFn;
  globalThis.startControl = startControlFn;
  globalThis.acknowledged = acked;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.card = (t, b, inner) => `<h2>${t}</h2><p>${b}</p>${inner}`;
  globalThis.leverRowsFor = () => '';
  globalThis.tempSections = () => '';
  // RUN-IT-1: the size rows (their own test is run-it-sizes).
  globalThis.sizeRowsFor = () => '';
  globalThis.runHref = (p) => p;
  globalThis.VmfHelp = require('./_identity').help({ WAVE_MAX_WORKERS: 60, waveEstimate: () => '' });

  globalThis.$ = () => node();
  globalThis.document = { querySelectorAll: () => [], querySelector: () => node() };
  // PRICE-EXPORT-1: the (?) beside the export, and which of them are open.
  globalThis.tHelpBtn = helpBtn;
  globalThis.helpWire = () => {};
  globalThis.exportPlan = () => {};
// CLAIM-AT-PLAN-1: the step reads the last start's result from the log; none here.
globalThis.paintStartFailure = () => {};
  globalThis.tHelp = new Set(help);
  const el = { innerHTML: '', querySelectorAll: () => [], querySelector: () => null };
  renderStep5(el);
  return el.innerHTML;
}
const button = (html, id) => (html.match(new RegExp(`<button[^>]*id="${id}"[^>]*>`)) || [null])[0];

test('RUN: one control, one job - there is no per-wave Approve in the Start slot any more', () => {
  const html = paint();
  ok(!/id="ap"/.test(html), 'the approve-then-start slot is gone');
  ok(button(html, 'go5'), 'Start is at the bottom');
  ok(html.includes(UX.startPlanBtn), 'and it starts the PLAN, not one wave');
});

test('RUN: nothing accepted yet - Start waits, and says why on the screen', () => {
  const html = paint({ accepted: ['w1'] });
  ok(/disabled/.test(button(html, 'go5')), 'Start is not live');
  ok(/id="go5-why"[^>]*>[^<]*Accept the settings/.test(html), 'the reason is shown, not hidden in a title');
  ok(/disabled/.test(button(html, 'signoff')), 'and signing off waits for the settings too');
});

test('RUN: accepted but not signed off - one sign-off for all the waves, then Start', () => {
  const html = paint();
  ok(!/disabled/.test(button(html, 'signoff')), 'an approver can sign off');
  ok(html.includes(UX.signBtn.replace('{n}', '3')), 'and the button says how many waves it covers');
  ok(/disabled/.test(button(html, 'go5')), 'Start waits for the sign-off');
  ok(html.includes(UX.signFirst), 'and says so');
});

test('RUN: signed off for this plan - Start comes alive, and the sign-off says who', () => {
  const html = paint({ signoff: { approvedBy: { identity: 'approver@example.com' } } });
  ok(!/disabled/.test(button(html, 'go5')), 'Start is live');
  ok(!/id="go5-why"/.test(html), 'with no reason to wait');
  ok(html.includes(UX.signedBy.replace('{who}', 'approver@example.com')), 'the signature is shown');
  ok(!button(html, 'signoff'), 'and it cannot be signed twice');
});

test('RUN: a sign-off for an EARLIER version of the plan does not count', () => {
  // WAVE-APPROVE-1: a sign-off from before wrote no wave approvals, so every
  // wave asks again - and the line names them.
  const html = paint({ signoff: { approvedBy: { identity: 'approver@example.com' } }, current: false });
  ok(html.includes(UX.signStale.replace('{waves}', 'w1, w2, w3')), 'it says which waves changed');
  ok(/disabled/.test(button(html, 'go5')), 'and Start waits');
});

test('WAVE-APPROVE-1: RUN: a change to one wave after the sign-off asks again for that wave only', () => {
  const html = paint({ signoff: { schemaVersion: 3, approvedBy: { identity: 'approver@example.com' } }, current: false, approved: ['w1', 'w3'] });
  eq(html.split(UX.waveSignStale).length - 1, 1, 'one wave says it needs a sign-off again');
  ok(html.includes(UX.signStale.replace('{waves}', 'w2')), 'the sign-off section names only w2');
  eq(html.split(UX.waveApprovedBy.replace('{who}', 'approver@example.com')).length - 1, 2, 'w1 and w3 keep their approval, and say so');
  ok(button(html, 'signoff') && !/disabled/.test(button(html, 'signoff')), 'an approver can sign off again');
  ok(/disabled/.test(button(html, 'go5')), 'and Start waits for it');
});

test('WAVE-APPROVE-1: RUN: every wave approved on its own counts as signed, whatever the plan version', () => {
  const html = paint({ signoff: { schemaVersion: 3, approvedBy: { identity: 'approver@example.com' } }, current: false, approved: ['w1', 'w2', 'w3'] });
  ok(!/disabled/.test(button(html, 'go5')), 'Start is live');
  ok(html.includes(UX.signedBy.replace('{who}', 'approver@example.com')), 'the signature is shown');
  ok(!html.includes(UX.waveSignStale), 'and no wave asks again');
});

test('WAVE-APPROVE-1: RUN: every wave approved one by one, but no sign-off - not signed, because nothing consents to run on', () => {
  // The review: the engine starts each next wave only with a sign-off's
  // consent (Test-VmfPlanRunConsent). Approvals alone showed Signed off and a
  // live Start, and the second wave would never start.
  const html = paint({ signoff: null, approved: ['w1', 'w2', 'w3'] });
  ok(/disabled/.test(button(html, 'go5')), 'Start waits');
  ok(button(html, 'signoff'), 'the sign-off is offered');
  ok(!html.includes(UX.signedBy.replace('{who}', 'approver@example.com')), 'and nobody is named as having signed it off');
});

test('MIGRATIONS-PAGE-OLD-READERS-1: the step reads the sign-off with no version - Approve-VmfPlan writes only v4', () => {
  ok(!/planSignoff\.schemaVersion/.test(PAGE), 'the consent reads no schemaVersion');
  const html = paint({ signoff: { approvedBy: { identity: 'approver@example.com' } }, current: false, approved: ['w1', 'w2', 'w3'] });
  ok(!/disabled/.test(button(html, 'go5')), 'a sign-off of an earlier plan version, with every wave approved, is the consent');
});

test('WAVE-APPROVE-1: RUN: waveSignState', () => {
  const a = new Map([['w1', { wave: 'w1' }]]);
  eq(waveSignStateFn('w1', a, null, false), 'signed', 'its own approval');
  eq(waveSignStateFn('w2', a, null, false), 'none', 'nothing signed yet');
  eq(waveSignStateFn('w2', a, { schemaVersion: 3 }, false), 'asks', 'signed off, then changed');
  eq(waveSignStateFn('w2', a, { schemaVersion: 3 }, true), 'signed', 'a sign-off of this very plan');
});

test('RUN: somebody who cannot sign is told who can, not shown a button that is refused', () => {
  const html = paint({ approver: false });
  ok(!button(html, 'signoff'), 'no button');
  ok(html.includes(UX.signNeedsApprover), 'and the sentence');
});

test('WIZARD-START-ROLE-1: RUN: an approver who is not an operator signs off, and gets no Start the plan', () => {
  // The service starts a wave, records the acknowledgement and sets the start
  // times only for an operator or an administrator.
  const signedOff = { schemaVersion: 3, approvedBy: { identity: 'approver@example.com' } };
  const other = paint({ operator: false, signoff: signedOff, acked: false });
  ok(!button(other, 'go5'), 'no Start the plan the service would refuse');
  ok(other.includes(UX.startNeedsOperator), 'the reason is ON the screen');
  // IAC-NOTE-LIST-1: the note is a list the page builds in this holder.
  ok(other.includes('id="iac-note"'), 'the approver still reads the note before signing off');
  ok(!other.includes('id="f-ack"'), 'and has nothing to tick: only the start records it');
  ok(other.includes(UX.signedBy.replace('{who}', 'approver@example.com')), 'the sign-off part of the step is still theirs');
  const op = paint({ operator: true, signoff: signedOff, acked: false });
  ok(button(op, 'go5') && !/disabled/.test(button(op, 'go5')), 'an operator gets it, ready');
  ok(op.includes('id="f-ack"'), 'with the acknowledgement');
  ok(!op.includes(UX.startNeedsOperator), 'and no reason, because nothing is missing');
});
test('WIZARD-ROLES-2: RUN: the start times and the number at once take no input from a non-operator', () => {
  const other = paint({ operator: false, how: 'times' });
  const inputs = other.match(/<input[^>]*(name="how"|data-time=|id="f-thr")[^>]*>/g) || [];
  ok(inputs.length >= 5, `found the run inputs, got ${inputs.length}`);
  for (const i of inputs) { ok(/disabled/.test(i), `read-only for a non-operator: ${i.slice(0, 60)}`); }
  const op = paint({ operator: true, how: 'times' });
  for (const i of (op.match(/<input[^>]*(name="how"|data-time=|id="f-thr")[^>]*>/g) || [])) { ok(!/disabled/.test(i), 'an operator can set them'); }
});
test('DECIDE-ROLE-1: only an operator is offered Accept these settings, and anybody else is told who accepts them', () => {
  // The service accepts a wave's settings only from an operator or an
  // administrator. The step drew the button for everybody.
  const op = paint({ accepted: [] });
  ok((op.match(/data-accept="/g) || []).length === 3, 'an operator gets one button per wave');
  ok(/data-accept-all="1"/.test(op), 'and the one for all of them');
  const other = paint({ accepted: [], operator: false });
  ok(!/data-accept=/.test(other), 'no button the service would refuse');
  ok(!/data-accept-all/.test(other), 'not the bulk one either');
  ok((other.match(new RegExp(UX.acceptNeedsOperator, 'g')) || []).length === 3, 'each wave says who accepts its settings');
});

test('RUN: "Give some waves a start time" shows each wave, and what starts it', () => {
  const html = paint({ how: 'times', times: { w3: '2026-10-01T22:00' } });
  ok(/id="how-times"/.test(html) && !/id="how-times"[^>]*display:none/.test(html), 'the list is shown');
  ok(!/data-timecell style="display:none"/.test(html), 'with a time field for each wave');
  ok(html.includes(UX.startsNow), 'the first wave without a time starts now');
  ok(html.includes(UX.followsLine.replace('{wave}', 'w1')), 'the next follows the one before');
  ok(/data-time="w3" value="2026-10-01T22:00"/.test(html), 'a typed time is kept');
});

test('RUN: "Run all waves in order" says the order too', () => {
  // RUN-ORDER-1, the owner on the first Azure test: the page did not say which
  // wave starts first. The order was shown only with the start times; this
  // encoded that as "reveals nothing further". Only the time field hides now.
  const plain = paint({ how: 'all' });
  ok(!/id="how-times"[^>]*display:none/.test(plain), 'the order is shown');
  ok(/1\. w1/.test(plain) && plain.includes(UX.startsNow), 'the first wave, and that it starts now');
  ok(plain.includes(UX.followsLine.replace('{wave}', 'w1')), 'and what each after it follows');
  ok(/data-timecell style="display:none"/.test(plain), 'with no time fields');
});

test('the sign-off posts the plan version it was shown', () => {
  const at = PAGE.indexOf("$('#signoff')?.addEventListener");
  const h = PAGE.slice(at, PAGE.indexOf("$('#go5')?.addEventListener", at));
  ok(/body\.planHash = pv\.version/.test(h), 'the version');
  ok(/runs\/\$\{runSeg\(\)\}\/approve-plan/.test(h), 'to the plan sign-off');
});

test('Start sets the start times BEFORE it starts the first wave, and no start carries a number of its own', () => {
  const at = PAGE.indexOf("$('#go5')?.addEventListener");
  const h = PAGE.slice(at, PAGE.indexOf('// The engine may refuse after', at));
  ok(h.indexOf('/schedule`') >= 0 && h.indexOf('/schedule`') < h.indexOf('engine/wave'), 'schedules first');
  // MACHINES-AT-ONCE-RANGE-1: every wave runs at its own number, which the
  // service reads from the plan. The typed number for the first wave is gone.
  ok(!/throttle/.test(h), 'no number goes with a start or a schedule');
  ok(/if \(!firstTimed\) \{\s*await api\('POST', `runs\/\$\{runSeg\(\)\}\/engine\/wave`/.test(h),
    'the first wave starts now only when it has no time');
});

test('RUN-GO-1: once it has started, the page goes to the run', () => {
  ok(/verdict\.started\) \{ watch\.textContent = UX\.watchingStarted; location\.href = runHref\('migrations\.html'\)/.test(PAGE),
    'no second click on "Open the run"');
});

// PRICE-EXPORT-1 (issue 423): the plan exists here, so the file can say which
// wave each machine is in. The file itself is tested in pricing-export.
test('RUN: the Run it step offers Export for pricing, live whatever has been signed, with its (?)', () => {
  for (const html of [paint(), paint({ accepted: ['w1'] }), paint({ signoff: { approvedBy: { identity: 'approver@example.com' } } })]) {
    const b = button(html, 'r-export');
    ok(b && !/disabled/.test(b), 'the button, never turned off');
    ok(html.includes(`${UX.tExport}</button>`), 'with the same words as on the targets step');
    ok(html.includes('aria-controls="t-help-run-export"'), 'and a (?) that names the text it opens');
  }
  ok(!paint().includes(UX.rExportHelp), 'the text waits behind the (?)');
  const open = paint({ help: ['run-export'] });
  ok(/id="t-help-run-export"[^>]*>[^<]*/.test(open) && open.includes(UX.rExportHelp), 'open: the text says what the file holds');
  ok(open.includes(`${UX.tClose}</button>`), 'and the (?) is now a visible Close (rule 11)');
});

// ROLLBACK-CAPACITY-1, FILTER-DRIVER-READ-1 and DISK-PATH-READ-1 (owner,
// 2026-11-14): Run it shows the lines under the settings of the wave they are
// true of, by the one rule of help.js, in the wizard's own words.
const sec = (html, w) => html.split('<div class="sec">').find(s => s.includes(`<span class="mono">${w}</span>`)) ?? '';
const riskOf = (s) => [...s.matchAll(/<p[^>]*data-waverisk[^>]*>([^<]*)<\/p>/g)].map(m => m[1]);
test('RUN: the capacity and NVMe lines show under the wave they are true of, and no other', () => {
  const html = paint({ entries: [
    { vmId: '/s/a', wave: 'w1', path: 'A', assessment: { sourceCapacityRestricted: true }, target: { controller: 'SCSI' } },
    { vmId: '/s/b', wave: 'w2', path: 'A', assessment: { sourceCapacityRestricted: false }, target: { controller: 'NVMe' } },
    { vmId: '/s/c', wave: 'w3', path: 'A', assessment: { sourceCapacityRestricted: false }, target: { controller: 'SCSI' } },
    { vmId: '/s/d', wave: 'w3', path: 'MANUAL', assessment: { sourceCapacityRestricted: true }, target: { controller: 'NVMe' } }] });
  eq(riskOf(sec(html, 'w1')), [UX.lvCapacityNoGuarantee], 'w1: a restricted original size');
  eq(riskOf(sec(html, 'w2')), [UX.lvNvmeThirdParty, UX.lvNvmeThirdPartyWhat, UX.lvNvmeDiskPaths], 'w2: a move to NVMe');
  eq(riskOf(sec(html, 'w3')), [], 'w3: SCSI, and a machine that does not move counts for nothing');
  ok(/<table class="facts"><\/table>\s*<p class="muted" data-waverisk/.test(sec(html, 'w1')), 'under the settings table');
});
run('run-step');
