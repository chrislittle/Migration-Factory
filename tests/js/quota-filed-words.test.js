/* QUOTA-FILED-WORDS-1: Request says "filed" only for the quotas Azure took.
 *
 * Request (sendQuotaRequest) posted runs/{id}/engine/quota and, when the
 * service answered 202 - the engine job STARTED - closed the confirmation and
 * printed "The quota increase request is filed". Nothing had been asked of
 * Azure then, and a request Azure refused was said only in the activity log.
 *
 * Now, as the preview does (QUOTA-PREVIEW-1), the page waits for the engine's
 * own line: ONE quotaResult line in the run's activity log, with each quota,
 * its status and, for a quota not filed, the reason. "Filed" is said only for
 * APPROVED and PENDING; each other quota is named with its reason.
 *
 * RUN, not read: the page's own functions, with the service stubbed.
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
const quotaConfirmHtml = lift('waves.html', 'quotaConfirmHtml');
const quotaResultLines = lift('waves.html', 'quotaResultLines');
// Lifted alone: each calls the stand-ins a test gives it.
const sendQuotaRequest = lift('waves.html', 'sendQuotaRequest');
const watchQuotaRequest = lift('waves.html', 'watchQuotaRequest');
const showQuotaResult = lift('waves.html', 'showQuotaResult');

const SUB_A = '11111111-2222-3333-4444-555555555555';
const FILED = { family: 'standardDDSv6Family', quotaName: 'Standard DDSv6 Family vCPUs', subscriptionId: SUB_A, region: 'centralus',
  requestedLimit: 46, status: 'PENDING', reason: null };
const APPROVED = { family: 'standardEDSv6Family', quotaName: 'Standard EDSv6 Family vCPUs', subscriptionId: SUB_A, region: 'eastus2',
  requestedLimit: 30, status: 'APPROVED', reason: null };
const REFUSED = { family: 'standardFSv2Family', quotaName: 'Standard FSv2 Family vCPUs', subscriptionId: SUB_A, region: 'westus3',
  requestedLimit: 20, status: 'FAILED', reason: 'Azure answered HTTP 400 QuotaNotAvailable: The quota is not available.' };
const NOACCESS = { family: 'cores', quotaName: 'Total Regional vCPUs', subscriptionId: SUB_A, region: 'centralus',
  requestedLimit: 60, status: 'NOACCESS', reason: 'The product cannot request a quota increase on subscription x.' };

globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.subName = (id) => id;

function el(extra = {}) { return { style: {}, textContent: '', disabled: false, ...extra }; }

function world({ watch = { result: { step: 'quotaResult', requests: [FILED] } }, postFails = null } = {}) {
  const calls = [];
  const els = { '#ok': el(), '#err': el(), '#q-request': el() };
  globalThis.$ = (sel) => els[sel];
  globalThis.UX = UX;
  globalThis.runSeg = () => 'mig-1';
  globalThis.runBody = (b) => b;
  globalThis.apiPost = async (p, b) => {
    calls.push(['POST', p, b]);
    if (postFails) { throw new Error(postFails); }
    return {};
  };
  globalThis.watchQuotaRequest = async (since) => { calls.push(['WATCH', since]); return watch; };
  globalThis.VmfHelp = { explainAction: (e) => e.message, explain: (e) => e.message };
  globalThis.quotaConfirm = { phase: 'ready', rows: [] };
  globalThis.quotaConfirmTurn = 1;
  globalThis.drawQuotaConfirm = () => { calls.push(['DRAW', globalThis.quotaConfirm && { ...globalThis.quotaConfirm }]); };
  globalThis.closeQuotaConfirm = () => { calls.push(['CLOSE']); globalThis.quotaConfirm = null; globalThis.quotaConfirmTurn++; };
  globalThis.loadClaims = async () => { calls.push(['LOAD']); return true; };
  globalThis.render = () => { calls.push(['RENDER']); };
  // CLICKS-LOST-1: the editor is drawn again when no control in it is held.
  globalThis.drawEditorWhenFree = () => { calls.push(['RENDER']); };
  globalThis.quotaResultLines = quotaResultLines;
  globalThis.showQuotaResult = showQuotaResult;
  // QUOTA-REQUEST-POLL-1: the answers of Azure, in the confirmation and on the page.
  for (const n of ['quotaAnswerLines', 'quotaUnanswered', 'quotaAnswerKey', 'quotaRowsToRead', 'quotaRequestStateText', 'quotaAnswerLineHtml']) { globalThis[n] = lift('waves.html', n); }
  globalThis.QUOTA_HELP = liftConst('waves.html', 'QUOTA_HELP');
  return { calls, els };
}

/* ---- Request waits for the engine ---- */

test('RUN: Request files the request and waits for the engine - it does not say "filed" when the job starts', async () => {
  const w = world();
  let saidAtPost = null;
  globalThis.apiPost = async (p, b) => { w.calls.push(['POST', p, b]); saidAtPost = w.els['#ok'].textContent; return {}; };
  await sendQuotaRequest();
  const post = w.calls.find(c => c[0] === 'POST');
  eq(post[1], 'runs/mig-1/engine/quota');
  eq(post[2].whatIfOnly, false, 'a real request');
  eq(saidAtPost, '', 'nothing is said when the job starts');
  ok(w.calls.findIndex(c => c[0] === 'WATCH') > w.calls.findIndex(c => c[0] === 'POST'), 'and the page waits for the engine');
});

test('RUN: the confirmation says it sends the requests, before the request goes', async () => {
  const w = world();
  await sendQuotaRequest();
  const first = w.calls.find(c => c[0] === 'DRAW');
  eq(first[1], { phase: 'sending' });
  ok(w.calls.indexOf(first) < w.calls.findIndex(c => c[0] === 'POST'), 'drawn before the request');
});

test('RUN: the watch window opens before the request, so a fast engine line is not missed', async () => {
  const w = world();
  const before = Date.now();
  await sendQuotaRequest();
  const since = w.calls.find(c => c[0] === 'WATCH')[1];
  ok(since <= before, `the window opens at or before the press (since ${since}, press ${before})`);
});

test('RUN: Request cannot be pressed twice while it is sent', async () => {
  const w = world();
  let during = null;
  globalThis.apiPost = async () => { during = w.els['#q-request'].disabled; return {}; };
  await sendQuotaRequest();
  eq(during, true);
});

test('RUN: the engine answer goes into the confirmation, which stays open to show it', async () => {
  const w = world({ watch: { result: { step: 'quotaResult', requests: [FILED, REFUSED] } } });
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, { phase: 'done', rows: [FILED, REFUSED] });
  ok(!w.calls.some(c => c[0] === 'CLOSE'), 'not closed: the answer is in it');
  eq(w.calls.filter(c => c[0] === 'DRAW').pop()[1], { phase: 'done', rows: [FILED, REFUSED] }, 'and drawn');
});

test('RUN: a result of one row stays a list', async () => {
  world({ watch: { result: { requests: FILED } } });
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm.rows, [FILED]);
});

test('RUN: the quota records are read again after the answer, so the card shows what changed', async () => {
  const w = world();
  await sendQuotaRequest();
  ok(w.calls.findIndex(c => c[0] === 'LOAD') > w.calls.findIndex(c => c[0] === 'WATCH'), 'read after the answer');
  ok(w.calls.some(c => c[0] === 'RENDER'));
});

test('RUN: a failed read of the records after the answer does not hide the answer', async () => {
  world({ watch: { result: { requests: [FILED] } } });
  globalThis.loadClaims = async () => { throw new Error('read failed'); };
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, { phase: 'done', rows: [FILED] });
});

test('RUN: an engine that stopped says so, with its reason, and says nothing is known to be filed', async () => {
  world({ watch: { failure: { step: 'engine:quota', outcome: 'fail', detail: 'No quota records found' } } });
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm.phase, 'error');
  eq(globalThis.quotaConfirm.error, UX.quotaRequestStopped.replace('{reason}', 'No quota records found'));
});

test('RUN: a reason with $& in it is shown as written', async () => {
  world({ watch: { failure: { step: 'engine:quota', outcome: 'fail', detail: 'cost $& more' } } });
  await sendQuotaRequest();
  ok(globalThis.quotaConfirm.error.includes('cost $& more'), globalThis.quotaConfirm.error);
});

test('RUN: no answer in time is said, not "filed"', async () => {
  const w = world({ watch: null });
  await sendQuotaRequest();
  // QUOTA-CHECK-SPINNER-1: sent, so its title is not a question.
  eq(globalThis.quotaConfirm, { phase: 'error', error: UX.quotaRequestNoAnswer, sent: true });
  eq(w.els['#ok'].textContent, '');
});

test('RUN: a service that refuses the request says why in the confirmation, and waits for nothing', async () => {
  const w = world({ postFails: 'HTTP 500' });
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, { phase: 'error', error: 'HTTP 500', sent: true });
  ok(!w.calls.some(c => c[0] === 'WATCH'), 'no engine to wait for');
  eq(w.els['#ok'].textContent, '');
});

test('RUN: closed while it waits, the answer is shown on the page, and the confirmation is not opened again', async () => {
  const w = world({ watch: { result: { requests: [FILED, REFUSED] } } });
  globalThis.watchQuotaRequest = async () => { globalThis.closeQuotaConfirm(); return { result: { requests: [FILED, REFUSED] } }; };
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, null, 'not opened again');
  const said = quotaResultLines([FILED, REFUSED]);
  // QUOTA-REQUEST-POLL-1: a filed request with no request ID cannot be read, so the page says what to do.
  eq(w.els['#ok'].textContent, `${said.filed} ${UX.quotaDoneNext}`);
  eq(w.els['#ok'].style.display, 'block');
  eq(w.els['#err'].textContent, said.notFiled.join(' '));
  eq(w.els['#err'].style.display, 'block');
});

test('RUN: closed while it waits, a failure is shown on the page', async () => {
  const w = world();
  globalThis.apiPost = async () => { globalThis.closeQuotaConfirm(); throw new Error('HTTP 500'); };
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, null);
  eq(w.els['#err'].textContent, 'HTTP 500');
  eq(w.els['#err'].style.display, 'block');
  eq(w.els['#ok'].style.display, 'none', 'and no "filed" beside it');
});

test('RUN: opened again while it waits, the first answer goes to the page, not into the new confirmation', async () => {
  const w = world();
  globalThis.watchQuotaRequest = async () => {
    globalThis.quotaConfirm = { phase: 'wait' }; globalThis.quotaConfirmTurn++;
    return { result: { requests: [FILED] } };
  };
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, { phase: 'wait' }, 'the new confirmation is untouched');
  eq(w.els['#ok'].textContent, `${quotaResultLines([FILED]).filed} ${UX.quotaDoneNext}`);
});

/* ---- what is said ---- */

test('RUN: "filed" names only the quotas Azure took - APPROVED and PENDING', () => {
  globalThis.UX = UX;
  const s = quotaResultLines([FILED, APPROVED, REFUSED, NOACCESS]);
  eq(s.filed, UX.quotaFiled.replace('{quotas}', 'Standard DDSv6 Family vCPUs in centralus, Standard EDSv6 Family vCPUs in eastus2'));
  ok(!s.filed.includes('FSv2') && !s.filed.includes('Total Regional'), 'a quota not filed is never in the filed line');
});

test('RUN: each quota not filed is named, with its region and the reason the engine wrote', () => {
  globalThis.UX = UX;
  const s = quotaResultLines([FILED, REFUSED, NOACCESS]);
  eq(s.notFiled, [
    UX.quotaNotFiled.replace('{quota}', 'Standard FSv2 Family vCPUs').replace('{region}', 'westus3').replace('{reason}', REFUSED.reason),
    UX.quotaNotFiled.replace('{quota}', 'Total Regional vCPUs').replace('{region}', 'centralus').replace('{reason}', NOACCESS.reason),
  ]);
});

test('RUN: nothing filed has no filed line; a row with no quota name shows its family; a missing reason says so', () => {
  globalThis.UX = UX;
  const s = quotaResultLines([{ ...REFUSED, quotaName: '', reason: null }]);
  eq(s.filed, '');
  ok(s.notFiled[0].includes('standardFSv2Family'), s.notFiled[0]);
  ok(!/null|undefined/.test(s.notFiled[0]), 'no null on the screen');
  ok(s.notFiled[0].includes(UX.quotaNoReason), s.notFiled[0]);
});

test('RUN: a name or reason with braces or $& is shown as written', () => {
  globalThis.UX = UX;
  const s = quotaResultLines([{ ...REFUSED, quotaName: 'q{region}$&', reason: 'r{quota}$&' }]);
  ok(s.notFiled[0].includes('q{region}$&') && s.notFiled[0].includes('r{quota}$&'), s.notFiled[0]);
});

test('RUN: an empty result says nothing was too low', () => {
  globalThis.UX = UX;
  const s = quotaResultLines([]);
  eq(s, { filed: '', notFiled: [], none: UX.quotaPreviewNone });
});

test('RUN: the confirmation shows the answer: each request in a table, then each quota not filed, escaped', () => {
  globalThis.UX = UX;
  globalThis.quotaResultLines = quotaResultLines;
  globalThis.quotaRequestStateText = lift('waves.html', 'quotaRequestStateText');
  const html = quotaConfirmHtml({ phase: 'done', rows: [FILED, { ...REFUSED, reason: 'bad <b>' }] });
  // QUOTA-CHECK-SPINNER-1: a table with the state of each request, and what to do next.
  ok(html.includes(`<td>Standard DDSv6 Family vCPUs</td><td>centralus</td><td class="num">46</td><td>${esc(UX.quotaStateFiled)}</td>`), 'the filed request');
  ok(html.includes(`<p class="desc">${esc(UX.quotaDoneNext)}</p>`), 'what to do next');
  ok(html.includes('<p class="err-inline">') && html.includes('bad &lt;b&gt;'), 'the quota not filed, escaped');
  ok(!html.includes('<b>'), 'no markup from the log');
  ok(!html.includes('id="q-request"'), 'no Request: it is done');
  ok(new RegExp(`<button[^>]*id="q-cancel"[^>]*>${UX.quotaClose}</button>`).test(html), 'Close (rule 11)');
});

test('RUN: the confirmation while it sends: it says so, offers Close, and no Request', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'sending' });
  ok(html.includes(esc(UX.quotaSending)));
  ok(!html.includes('id="q-request"'));
  ok(new RegExp(`<button[^>]*id="q-cancel"[^>]*>${UX.quotaClose}</button>`).test(html), 'Close, not Cancel: the request is not taken back');
});

test('RUN: an empty answer in the confirmation says nothing was too low', () => {
  globalThis.UX = UX;
  globalThis.quotaRequestStateText = lift('waves.html', 'quotaRequestStateText');
  globalThis.quotaResultLines = quotaResultLines;
  ok(quotaConfirmHtml({ phase: 'done', rows: [] }).includes(UX.quotaPreviewNone));
});

test('RUN: the words', () => {
  eq(UX.quotaFiled, 'The product filed the quota increase request for {quotas}. Azure accepts or refuses each request. The answer can come after some days.');
  eq(UX.quotaNotFiled, 'The product did not file the quota increase request for {quota} in {region}. {reason}');
  ok(!('quotaDone' in UX), 'the line said when the job started is gone');
});

/* ---- the watch ---- */

test('RUN: the watcher ends on the result line, or on an engine failure - nothing else', async () => {
  let opts = null;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobLines = async (p) => { opts.read = p; return []; };
  globalThis.VmfHelp = { watchRun: async (o) => { opts = o; await o.readLines(); return null; } };
  await watchQuotaRequest(1234);
  eq(opts.sinceMs, 1234);
  eq(opts.read, 'p/mig-1/logs/events.jsonl');
  eq(opts.timeoutMs, 600000, '10 minutes, as UX.quotaRequestNoAnswer says');
  ok(/10 minutes/.test(UX.quotaRequestNoAnswer));
  eq(opts.onTick, undefined, 'closing the confirmation does not stop the wait: the answer still goes to the page');
  const result = { step: 'quotaResult', outcome: 'warn', requests: [] };
  const preview = { step: 'quotaPreview', outcome: 'info', requests: [] };
  const oneFail = { step: 'quotaRequest', outcome: 'fail', detail: 'family=X HTTP 400' };
  const oneOk = { step: 'quotaRequest', outcome: 'ok', detail: 'family=X newLimit=12 status=PENDING' };
  const engineFail = { step: 'engine:quota', outcome: 'fail', detail: 'boom' };
  const refused = { step: 'engine', outcome: 'refused', detail: 'no' };
  eq(opts.scan([oneFail, oneOk, result]), { result }, 'the result line ends it');
  eq(opts.scan([preview, oneFail, oneOk]), null, 'a preview, or one quota\'s line, is not the answer');
  eq(opts.scan([engineFail]), { failure: engineFail });
  eq(opts.scan([refused]), { failure: refused });
  eq(opts.scan([engineFail, result]), { result }, 'a result in the same read wins');
});

/* ---- the activity log ---- */

test('RUN: the activity log shows the result line as what it says', () => {
  const { stepText } = liftAll('migrations.html', ['stepText']);
  globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
  globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
  globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
  const said = 'The engine filed 1 of 2 quota increase requests.';
  eq(stepText({ step: 'quotaResult', outcome: 'warn', detail: said, requests: [] }), said);
  eq(stepText({ step: 'quotaResult', outcome: 'ok' }), globalThis.UX_STEP.quotaResultStep, 'with no detail, its own label');
  ok(globalThis.UX_STEP.quotaResultStep !== globalThis.UX_STEP.quotaStep);
});

run('quota-filed-words');
