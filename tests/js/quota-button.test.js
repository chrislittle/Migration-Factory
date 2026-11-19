/* QUOTA-BUTTON-1: "Check the quota" said "not enough" in a second, having asked
 * nobody.
 *
 * It called only the READ of the wave's stored quota records. Saving the waves
 * clears those, so on a plan somebody had just arranged the read found none,
 * and the page printed the red "not enough" for a check that never happened.
 *
 * RUN, not read: the page's own checkCapacity, with the service stubbed.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
// Lifted SEPARATELY: lifted together they share a scope, and checkCapacity would
// call the real watcher instead of the stand-in each test gives it.
const page = { checkCapacity: lift('waves.html', 'checkCapacity'), ...liftAll('waves.html', ['quotaCheckDone', 'watchQuotaCheck']) };
const DONE = 'claims=1 blocked=0 wave=wave-1 machines=1 moving=1';
// RESERVE-COVER-1: the page's own sentence for machines with no quota record.
const uncoveredText = lift('waves.html', 'uncoveredText');

function world({ operator = true, gate, unlisted = false, regional = false, watch = { done: { detail: DONE } }, unsaved = false } = {}) {
  const calls = [];
  globalThis.dirty = () => unsaved;
  globalThis.writeLayout = async () => { calls.push(['SAVE']); unsaved = false; return {}; };
  const bar = { style: {}, textContent: '' };
  globalThis.$ = () => bar;
  // QUOTA-CHECK-SPINNER-1: the answer is kept per wave (capAnswers) and the row
  // is drawn from it. `answer` reads it back the way the old tests read the DOM.
  globalThis.capAnswers = new Map();
  globalThis.checkingWaves = new Set();
  const rows = [];
  globalThis.drawQuotaRow = (wv) => { rows.push([wv, globalThis.checkingWaves.has(wv)]); };
  const answer = {
    get textContent() { return globalThis.capAnswers.get('wave-1')?.text ?? ''; },
    get className() { return globalThis.capAnswers.get('wave-1')?.cls ?? ''; },
    get title() { return globalThis.capAnswers.get('wave-1')?.title ?? ''; },
  };
  globalThis.UX = UX;
  globalThis.DEMO_MODE = false;
  globalThis.canEdit = operator;
  globalThis.layout = new Map();
  globalThis.cssEscape = (s) => s;
  globalThis.esc = (s) => String(s);
  globalThis.ago = () => '1m ago';
  globalThis.lastChecked = new Map();
  globalThis.runSeg = () => 'mig-1';
  globalThis.runQuery = () => '';
  globalThis.runBody = (b) => b;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobLines = async () => [];
  globalThis.apiPost = async (p, b) => { calls.push(['POST', p, b]); return {}; };
  globalThis.apiGet = async (p) => { calls.push(['GET', p]); return gate; };
  globalThis.loadClaims = async () => {
    globalThis.unlistedWaves = new Set(unlisted ? ['wave-1'] : []);
    globalThis.regionalShortWaves = new Set(regional ? ['wave-1'] : []);
  };
  globalThis.unlistedWaves = new Set();
  globalThis.regionalShortWaves = new Set();
  globalThis.watchQuotaCheck = async () => watch;
  globalThis.VmfHelp = { explainAction: (e) => e.message, explain: (e) => e.message };
  globalThis.uncoveredText = uncoveredText;
  // CLICKS-LOST-1: the plan-wide quota panel is drawn again with the records.
  globalThis.drawQuotaCard = () => {};
  const btn = 'unused';
  return { calls, answer, btn, rows };
}

test('RUN: an operator\'s press ASKS AZURE first, then reads the answer', async () => {
  const w = world({ gate: { Pass: true, Detail: 'all 1 claims satisfy BestEffort' } });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.calls[0][0] + ' ' + w.calls[0][1], 'POST runs/mig-1/engine/quotacheck', 'the engine is asked to check');
  eq(w.calls[0][2].wave, 'wave-1', 'for this wave');
  eq(w.calls[1][0], 'GET', 'and only then is the gate read');
  eq(w.answer.textContent, '', 'QUOTA-CHECK-SPINNER-1: short or enough is said by the lines of the wave, from the records; no answer is kept');
});

test('RUN: no records is "not checked yet" - not the red "not enough"', async () => {
  const w = world({ operator: false, gate: { Pass: false, Detail: "no quota records for wave 'wave-1' yet" } });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.calls.length, 1, 'a viewer cannot start engine work, so only the read');
  eq(w.answer.textContent, UX.capNotChecked);
  ok(!/bad/.test(w.answer.className), 'and it is not painted as a failure');
});

test('RUN: a real shortfall is still "not enough", in red', async () => {
  const w = world({ gate: { Pass: false, Detail: '1 claim(s) below the BestEffort gate: Standard_D2ds_v6@centralus [BLOCKED]' } });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.answer.textContent, '', 'QUOTA-CHECK-SPINNER-1: short or enough is said by the lines of the wave, from the records; no answer is kept');
});

test('REGIONAL-VCPU-QUOTA-1 RUN: a wave blocked on the regional quota names that quota, in red', async () => {
  const w = world({ gate: { Pass: false, Detail: '1 claim(s) below the BestEffort gate: Standard_D2ds_v6@centralus [BLOCKED]' }, regional: true });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.answer.textContent, '', 'QUOTA-CHECK-SPINNER-1: short or enough is said by the lines of the wave, from the records; no answer is kept');
});

test('RUN: a pass with no figure from Azure does not claim "enough"', async () => {
  // The s-suffix v6 sizes: Azure lists no quota for their family, so the
  // engine records them verified with no limit. Nothing was measured.
  const w = world({ gate: { Pass: true, Detail: 'all 1 claims satisfy BestEffort' }, unlisted: true });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.answer.textContent, '', 'QUOTA-CHECK-SPINNER-1: short or enough is said by the lines of the wave, from the records; no answer is kept');
});

test('RUN: an engine that could not run the check says so, and the gate is not read', async () => {
  const w = world({ gate: { Pass: true }, watch: { failure: { detail: 'the engine could not start' } } });
  await page.checkCapacity('wave-1', w.btn);
  ok(/could not start/.test(w.answer.textContent), `the failure is shown, got: ${w.answer.textContent}`);
  ok(!w.calls.some(c => c[0] === 'GET'), 'an old record is not read as if it were the answer');
  // QUOTA-CHECK-SPINNER-1: the row is drawn again with the wave no longer checking, so its button is usable.
  eq(w.rows[w.rows.length - 1], ['wave-1', false], 'and the button is usable again');
});

test('RUN: zero records straight after a check is an answer, not "not checked yet"', async () => {
  // QUOTA-TRUTH-1: the first Azure test. The check ran and found nothing to
  // count, the gate then said "no records", and the page printed "Not checked
  // yet" for a check that had just finished.
  const w = world({ gate: { Pass: false, Detail: 'no quota records' },
    watch: { done: { detail: 'claims=0 blocked=0 wave=wave-1 machines=0 moving=0' } } });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.answer.textContent, UX.capNothing);
  // QUOTA-CHECK-SPINNER-1: engine text is not kept for a hover any more.
  eq(w.answer.title, '', 'no engine text on the answer');
  ok(!/bad/.test(w.answer.className), 'and it is not painted as a failure');
});

test('RUN: with unsaved changes a wave check does NOT save - Check the quota on the card saves once, first (checkPlan)', async () => {
  // QUOTA-TRUTH-1, measured against Azure: pressed before the save, the engine
  // checked the saved plan, where the new wave had no machines, and said zero.
  // Save cannot come first by hand - inside the flow it moves on to the next step.
  const w = world({ gate: { Pass: true, Detail: 'all 2 claims satisfy BestEffort' }, unsaved: true });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.calls.map(c => c[0] + (c[1] ? ' ' + c[1] : '')).join(' | '),
     'POST runs/mig-1/engine/quotacheck | GET runs/mig-1/waves/wave-1/capacity?gate=BestEffort', 'checked, then read; two wave checks at once would save twice');
});

test('RUN: with nothing unsaved the check does not write the plan', async () => {
  // A needless write bumps the plan version and asks for every acceptance again.
  const w = world({ gate: { Pass: true, Detail: 'all 1 claims satisfy BestEffort' } });
  await page.checkCapacity('wave-1', w.btn);
  ok(!w.calls.some(c => c[0] === 'SAVE'), 'no save');
});

test('RUN: a wave just checked is drawn again, and an answer it keeps belongs to that check', async () => {
  const w = world({ gate: { Pass: false, Detail: "no quota records for wave 'wave-1' yet" } });
  globalThis.loadClaims = async () => { globalThis.lastChecked = new Map([['wave-1', '2026-09-24T10:00:00Z']]); };
  await page.checkCapacity('wave-1', w.btn);
  eq(w.rows[w.rows.length - 1], ['wave-1', false], 'the row is drawn again after the check');
  eq(capAnswers.get('wave-1').at, '2026-09-24T10:00:00Z', 'the answer belongs to that check');
});

test('RUN: the watcher ends on THIS wave\'s summary line, or a failure', async () => {
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobLines = async () => [];
  let scan = null;
  globalThis.VmfHelp = { watchRun: async (o) => { scan = o.scan; return null; } };
  await page.watchQuotaCheck(0, 'wave-2');
  const mine = { step: 'capacity', outcome: 'warn', detail: 'claims=2 blocked=1 wave=wave-2 machines=2 moving=2' };
  eq(JSON.stringify(scan([mine])), JSON.stringify({ done: mine }), 'a finished check');
  // QUOTA-TRUTH-1: two checks started together read each other's answer.
  eq(scan([{ step: 'capacity', outcome: 'ok', detail: 'claims=1 blocked=0 wave=wave-1 machines=1 moving=1' }]), null,
     'another wave\'s answer is not this one');
  eq(scan([{ step: 'capacity', outcome: 'ok', detail: 'claims=1 blocked=0 wave=wave-22 machines=1 moving=1' }]), null,
     'nor is a wave whose name only starts the same');
  eq(scan([{ step: 'capacity', outcome: 'info', detail: 'kept the RESERVED record' }]), null, 'a note is not the end');
  ok(scan([{ step: 'engine', outcome: 'fail', detail: 'x' }]).failure, 'an engine failure ends it');
});

test('RUN: RESERVE-COVER-1 - a Reserved wave with machines that have no quota record names them, not "not enough"', async () => {
  // The shape Test-VmfQuotaAndReservation returns: Uncovered, each a name and a size.
  const w = world({ gate: { Pass: false, Gate: 'Reserved',
    Detail: 'the Reserved gate is not met: 2 machine(s) of the wave have no quota record: app-2 (Standard_E2s_v6), ha-1 (Standard_D4s_v6) - check the quota again',
    Uncovered: [{ Name: 'app-2', Size: 'Standard_E2s_v6', Region: 'centralus' }, { Name: 'ha-1', Size: 'Standard_D4s_v6', Region: 'centralus' }] } });
  layout.set('wave-1', { capacityGate: 'Reserved' });
  await page.checkCapacity('wave-1', w.btn);
  eq(w.answer.textContent, UX.capUncovered.replace('{machines}', 'app-2 (Standard_E2s_v6), ha-1 (Standard_D4s_v6)'));
  ok(/bad/.test(w.answer.className), 'the wave cannot start, so it is painted as a failure');
  eq(w.answer.title, '', 'QUOTA-CHECK-SPINNER-1: no engine text in a hover');
  ok(w.calls.some(c => c[0] === 'GET' && /gate=Reserved/.test(c[1])), 'the gate asked is the wave setting');
});

test('RUN: RESERVE-COVER-1 - no machines named is the old answer, and a pass never shows the names', async () => {
  const w = world({ gate: { Pass: false, Detail: '1 claim(s) below the Reserved gate: Standard_D2s_v6@centralus [QUOTA_VERIFIED]', Uncovered: [] } });
  await page.checkCapacity('wave-1', w.btn);
  // QUOTA-CHECK-SPINNER-1: a Reserved gate that fails with every machine covered is a reservation answer,
  // said on the reservation row; the quota lines come from the records.
  eq(w.answer.textContent, '', 'no quota answer is kept');
  const p = world({ gate: { Pass: true, Detail: 'all 2 claims satisfy Reserved', Uncovered: [{ Name: 'x', Size: 'y' }] } });
  await page.checkCapacity('wave-1', p.btn);
  eq(p.answer.textContent, '', 'and a pass never shows the names');
});

test('RUN: RESERVE-COVER-2 - a gate that could not read the plan says so, never "not enough"', async () => {
  // Independent review: since RESERVE-COVER-2 a gate with no reservation (None) with no
  // plan to read is not a pass, and the page said the quota was too small.
  // Nothing was measured, so it is not painted as a quota answer.
  for (const gate of ['BestEffort', 'Reserved']) {
    const w = world({ gate: { Pass: false, Gate: gate, Uncovered: [],
      Detail: `the ${gate} gate is not met: the plan could not be read to confirm that every machine of the wave has a quota record` } });
    layout.set('wave-1', { capacityGate: gate });
    await page.checkCapacity('wave-1', w.btn);
    eq(w.answer.textContent, UX.capNoPlan, gate);
    ok(!/good|bad/.test(w.answer.className), `${gate}: neither a pass nor a quota failure`);
    eq(w.answer.title, '', `${gate}: QUOTA-CHECK-SPINNER-1: no engine text in a hover`);
  }
});

test('uncoveredText: one machine as an object, a missing size, and nothing at all', () => {
  globalThis.UX = UX;
  eq(uncoveredText({ Name: 'app-2', Size: 'Standard_E2s_v6' }), UX.capUncoveredOne.replace('{machines}', 'app-2 (Standard_E2s_v6)'),
     'PowerShell can send one item as an object, not a list - and one machine is said as one');
  eq(uncoveredText([{ Name: 'app-2' }]), UX.capUncoveredOne.replace('{machines}', 'app-2'));
  eq(uncoveredText(undefined), '');
  eq(uncoveredText([]), '');
  eq(uncoveredText([{ Size: 'no name' }]), '');
});

run('quota-button');
