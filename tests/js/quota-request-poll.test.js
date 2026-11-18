/* QUOTA-REQUEST-POLL-1: the page says the answer of Azure to each filed
 * quota increase request.
 *
 * A request Azure took with HTTP 202 showed "Filed. Azure has not answered
 * yet." for ever: nothing read it again, so nobody could tell when it was done,
 * or whether it was. Now the engine reads each filed request for 2
 * minutes and writes one quotaAnswer line with the request ID and the answer:
 * APPROVED, REFUSED (with Azure's code), WAITING or NOTREAD. The page waits
 * for those lines after the quotaResult line and shows, for each request, the
 * answer in the State column and what to do next under the table - in the
 * confirmation, or on the page when the confirmation was closed.
 *
 * RUN, not read: the page's own functions, with the service stubbed.
 */
'use strict';
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
const SUB = '11111111-2222-3333-4444-555555555555';
const GUID = '00000000-0000-4000-8000-0000000000aa';
const ID = `/subscriptions/${SUB}/providers/Microsoft.Compute/locations/centralus/providers/Microsoft.Quota/quotaRequests/${GUID}`;
const FILED = { family: 'standardDASv5Family', quotaName: 'Standard DASv5 Family vCPUs', subscriptionId: SUB, region: 'centralus',
  requestedLimit: 4, status: 'PENDING', reason: null, requestId: ID };
const AT_ONCE = { ...FILED, quotaName: 'Total Regional vCPUs', family: 'cores', status: 'APPROVED', requestId: null, requestedLimit: 20 };
const NOT_FILED = { ...FILED, quotaName: 'Standard FSv2 Family vCPUs', status: 'FAILED', requestId: null, reason: 'Azure answered HTTP 400.' };

globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.subName = (id) => id;

function names() {
  globalThis.UX = UX;
  for (const n of ['quotaAnswerKey', 'quotaRowsToRead', 'quotaUnanswered', 'mergeQuotaAnswers', 'quotaAnswerLines',
    'quotaRequestStateText', 'quotaResultLines', 'showQuotaResult', 'quotaAnswerLineHtml']) {
    globalThis[n] = lift('waves.html', n);
  }
  globalThis.QUOTA_HELP = liftConst('waves.html', 'QUOTA_HELP');
  globalThis.VmfHelp = { explain: (e) => e.message, explainAction: (e) => e.message, isLearnLink: lift('help.js', 'isLearnLink') };
}
names();
const answer = (a, code = null) => ({ step: 'quotaAnswer', requestId: ID, answer: a, code });
const merged = (a, code) => mergeQuotaAnswers([FILED], new Map([[GUID, answer(a, code)]]))[0];

/* ---- the words, verbatim as approved ---- */

test('RUN: the words', () => {
  eq(UX.quotaStateApproved, 'Azure accepted the request.');
  eq(UX.quotaStateRefusedCode, 'Azure refused the request, with the code {code}.');
  eq(UX.quotaStateRefused, 'Azure refused the request.');
  eq(UX.quotaStateFiled, 'The product filed the request. Azure did not answer yet.');
  eq(UX.quotaStateReading, 'The product filed the request. The product reads the answer of Azure.');
  eq(UX.quotaStateNotRead, 'The product filed the request. The product could not read the answer of Azure.');
  eq(UX.quotaNextApproved, 'Azure accepted the quota increase request for {quota} in {region}. Select Check the quota on the card Request a quota increase.');
  eq(UX.quotaNextRefused, 'Azure refused the quota increase request for {quota} in {region}.');
  eq(UX.quotaNextRefusedCode, 'Azure refused the quota increase request for {quota} in {region}, with the code {code}.');
  eq(UX.quotaNextSupport, 'To open an Azure support request for the increase, follow the steps in {page} from Microsoft.');
  eq(UX.quotaNextStepsFamily, 'On the Quotas page of the Azure portal, select Compute. Select the Information icon beside the quota, then select Create a support request.');
  eq(UX.quotaNextStepsRegional, 'On the Quotas page of the Azure portal, select Compute. Select the quota, then select New Quota Request. If Azure does not give the increase, the portal shows a link to open a support request.');
  eq(UX.quotaNextLimit, 'Ask for the new limit of {limit} vCPUs.');
  eq(UX.quotaHelpFamily, 'Increase VM-family vCPU quotas', 'the title of Microsoft\'s page, as it is');
  eq(UX.quotaHelpRegional, 'Increase regional vCPU quotas', 'the title of Microsoft\'s page, as it is');
  eq(QUOTA_HELP, { family: 'per-vm-quota-requests', regional: 'regional-quota-requests' }, 'pages in learn.microsoft.com/azure/quotas');
  eq(UX.quotaNextWaiting, 'Azure did not answer the quota increase request for {quota} in {region} in 2 minutes. Look again later on the Quotas page of the Azure portal.');
  eq(UX.quotaNextNotRead, 'The product could not read the answer of Azure for {quota} in {region}. Look again later on the Quotas page of the Azure portal.');
  // Since 2026-11-17: a request ID is not part of Microsoft's support flow, so no sentence asks the operator to give it.
  ok(!Object.entries(UX).filter(([k]) => k.startsWith('quotaNext')).some(([, v]) => /request ID|\{id\}/i.test(v)), 'no next step names the request ID');
  ok(!/ticket/i.test(Object.values(UX).join(' ')), 'never "ticket": Azure says support request');
});

/* ---- the State column ---- */

test('RUN: the State column says the answer the engine read', () => {
  eq(quotaRequestStateText(merged('APPROVED')), 'Azure accepted the request.');
  eq(quotaRequestStateText(merged('REFUSED', 'QuotaNotAvailableForResource')), 'Azure refused the request, with the code QuotaNotAvailableForResource.');
  eq(quotaRequestStateText(merged('REFUSED', null)), 'Azure refused the request.');
  eq(quotaRequestStateText(merged('WAITING')), UX.quotaStateFiled);
  eq(quotaRequestStateText(merged('NOTREAD')), UX.quotaStateNotRead);
  eq(quotaRequestStateText({ ...FILED, reading: true }), UX.quotaStateReading, 'while the product reads');
  eq(quotaRequestStateText(FILED), UX.quotaStateFiled);
  eq(quotaRequestStateText(AT_ONCE), UX.quotaStateApproved, 'approved at once, as before');
  eq(quotaRequestStateText(NOT_FILED), UX.quotaStateNotFiled);
  eq(quotaRequestStateText({ ...NOT_FILED, answer: 'APPROVED' }), UX.quotaStateNotFiled, 'an answer never makes a request that was not filed look filed');
});

test('RUN: a code with $& in it is shown as written', () => {
  eq(quotaRequestStateText(merged('REFUSED', 'A$&B')), 'Azure refused the request, with the code A$&B.');
});

/* ---- the answers are matched by request ID ---- */

test('RUN: only a PENDING request with an ID is read', () => {
  eq(quotaRowsToRead([FILED, AT_ONCE, NOT_FILED, { ...FILED, requestId: null }]).length, 1);
});

test('RUN: an answer line is matched by the GUID of the request ID, in any case and in any form of the ID', () => {
  eq(quotaAnswerKey(ID), GUID);
  eq(quotaAnswerKey(GUID.toUpperCase()), GUID);
  const m = mergeQuotaAnswers([FILED], new Map([[GUID, { requestId: GUID.toUpperCase(), answer: 'APPROVED' }]]));
  eq(m[0].answer, 'APPROVED');
});

test('RUN: a request read and no line came for: Azure did not answer; an answer Microsoft does not list is not a yes or a no', () => {
  eq(mergeQuotaAnswers([FILED], new Map())[0].answer, 'WAITING');
  eq(merged('MAYBE').answer, 'WAITING');
  eq(mergeQuotaAnswers([AT_ONCE, NOT_FILED], new Map()), [AT_ONCE, NOT_FILED], 'other rows are left as they are');
});

/* ---- what to do next ---- */

test('RUN: approved: select Check the quota again', () => {
  const lines = quotaAnswerLines([merged('APPROVED')]);
  eq(lines, [{ text: 'Azure accepted the quota increase request for Standard DASv5 Family vCPUs in centralus. Select Check the quota on the card Request a quota increase.', bad: false }]);
  eq(quotaAnswerLines([AT_ONCE]).length, 1, 'approved at once says the same');
});

test('RUN: refused: the quota, region and code, then Microsoft\'s steps for a size family and the new limit', () => {
  const lines = quotaAnswerLines([merged('REFUSED', 'QuotaNotAvailableForResource')]);
  eq(lines.length, 1);
  eq(lines[0].bad, true);
  eq(lines[0].text, 'Azure refused the quota increase request for Standard DASv5 Family vCPUs in centralus, with the code QuotaNotAvailableForResource. '
    + 'To open an Azure support request for the increase, follow the steps in Increase VM-family vCPU quotas from Microsoft. '
    + 'On the Quotas page of the Azure portal, select Compute. Select the Information icon beside the quota, then select Create a support request. '
    + 'Ask for the new limit of 4 vCPUs.');
  eq(lines[0].help, { title: 'Increase VM-family vCPU quotas', page: 'per-vm-quota-requests' });
  ok(!lines[0].text.includes(GUID), 'the request ID is not a step');
  eq(quotaAnswerLines([merged('REFUSED', null)])[0].text.split('. ')[0], 'Azure refused the quota increase request for Standard DASv5 Family vCPUs in centralus', 'no code when Azure gave none');
  ok(!quotaAnswerLines([{ ...merged('REFUSED', 'X'), requestedLimit: null }])[0].text.includes('new limit'), 'no limit sentence with no figure');
});

test('RUN: refused on the Total Regional vCPUs quota: Microsoft\'s regional page and its steps', () => {
  const regional = { ...FILED, kind: 'regional', family: 'cores', quotaName: 'Total Regional vCPUs', requestedLimit: 20, answer: 'REFUSED', answerCode: 'X' };
  const line = quotaAnswerLines([regional])[0];
  ok(line.text.includes('follow the steps in Increase regional vCPU quotas from Microsoft.'), line.text);
  ok(line.text.includes('Select the quota, then select New Quota Request.'), line.text);
  ok(line.text.endsWith('Ask for the new limit of 20 vCPUs.'), line.text);
  eq(line.help.page, 'regional-quota-requests');
  eq(quotaAnswerLines([{ ...regional, kind: undefined }])[0].help.page, 'regional-quota-requests', 'cores is the regional quota');
});

test('both Microsoft pages are pinned in the drift baseline, so a change to their steps is caught', () => {
  const base = JSON.parse(require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'docs', 'upstream-docs.json'), 'utf8'));
  for (const name of Object.values(QUOTA_HELP)) {
    const learnPath = `azure/quotas/${name}`;
    const folder = learnPath.slice(0, learnPath.lastIndexOf('/'));
    const page = learnPath.slice(learnPath.lastIndexOf('/') + 1);
    const f = base.folders.find(x => x.path === folder);
    ok(f && f.pages.some(pg => pg.name === page && /^[0-9a-f]{64}$/.test(pg.sha256)), `${learnPath} is pinned`);
    ok(require('fs').existsSync(require('path').join(__dirname, '..', '..', 'docs', 'upstream-docs', `${learnPath}.md`)), `${learnPath} text is stored`);
  }
});
test('RUN: the page title is a link to Microsoft\'s page, in a new tab with noopener; any other address is no link', () => {
  const line = quotaAnswerLines([merged('REFUSED', 'X')])[0];
  const html = quotaAnswerLineHtml(line);
  ok(html.includes('<a href="https://learn.microsoft.com/azure/quotas/per-vm-quota-requests" target="_blank" rel="noopener noreferrer">Increase VM-family vCPU quotas</a>'), html);
  eq(html.replace(/<[^>]+>/g, ''), esc(line.text), 'the same words');
  const bad = quotaAnswerLineHtml({ ...line, help: { title: line.help.title, page: 'x/../../evil' } });
  ok(!bad.includes('<a '), bad);
  eq(quotaAnswerLineHtml({ text: 'a <b>', bad: false }), 'a &lt;b&gt;', 'escaped');
});

test('RUN: no answer in the time: look again later on the Quotas page', () => {
  eq(quotaAnswerLines([merged('WAITING')]), [{ text: 'Azure did not answer the quota increase request for Standard DASv5 Family vCPUs in centralus in 2 minutes. Look again later on the Quotas page of the Azure portal.', bad: false }]);
  const notRead = quotaAnswerLines([merged('NOTREAD')]);
  eq(notRead[0].bad, true);
  ok(notRead[0].text.endsWith('Look again later on the Quotas page of the Azure portal.') && !notRead[0].text.includes(GUID), notRead[0].text);
});

test('RUN: a request not filed, or filed and not read yet, has no answer line', () => {
  eq(quotaAnswerLines([NOT_FILED, FILED, { ...FILED, reading: true }]), []);
});

/* ---- the confirmation ---- */

function dialog(c) {
  names();
  return lift('waves.html', 'quotaConfirmHtml')(c);
}

test('RUN: while the product reads, the confirmation shows the spinner and each request as read now', () => {
  const html = dialog({ phase: 'done', rows: [FILED], reading: true });
  ok(html.includes(`<span class="spin"></span>${esc(UX.quotaReading)}`), html);
  ok(html.includes(`<td>${esc(UX.quotaStateReading)}</td>`), html);
  ok(!html.includes(esc(UX.quotaDoneNext)), 'no "it can take days" while it reads');
});

test('RUN: with the answers, the State column and the next step for each, and no spinner', () => {
  const html = dialog({ phase: 'done', rows: [merged('REFUSED', 'QuotaNotAvailableForResource'), AT_ONCE, NOT_FILED], reading: false });
  ok(html.includes(`<td>${esc('Azure refused the request, with the code QuotaNotAvailableForResource.')}</td><td class="mono q-id">${GUID}</td>`), html);
  ok(html.includes(`<p class="err-inline">${esc('Azure refused the quota increase request for Standard DASv5 Family vCPUs in centralus, with the code QuotaNotAvailableForResource.')}`), html);
  ok(html.includes('target="_blank" rel="noopener noreferrer">Increase VM-family vCPU quotas</a>'), html);
  ok(html.includes(esc('Azure accepted the quota increase request for Total Regional vCPUs in centralus. Select Check the quota on the card Request a quota increase.')), html);
  ok(html.includes('Azure answered HTTP 400.'), 'a quota not filed still says why');
  ok(!html.includes('class="spin"'), 'no spinner');
  ok(!html.includes(esc(UX.quotaDoneNext)), 'every filed request has its answer');
});

/* QUOTA-CONFIRM-ID-OVERFLOW-1: the request ID is what the operator gives in a
 * support request. It did not wrap (td.mono nowrap), and with an answer in the
 * State column the table ran past the 680 px dialog box and cut the ID off. */
test('RUN: the request ID cell is its own class, and only that cell wraps', () => {
  const html = dialog({ phase: 'done', rows: [merged('REFUSED', 'QuotaNotAvailableForResource')], reading: false });
  ok(html.includes(`<td class="mono q-id">${GUID}</td>`), html);
  const css = require('fs').readFileSync(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'app.css'), 'utf8');
  const rule = css.match(/\.p-waves \.modal td\.mono\.q-id\s*\{([^}]*)\}/);
  ok(rule, 'a rule for the request ID cell of the quota confirmation');
  ok(/overflow-wrap:\s*anywhere/.test(rule[1]), rule[1]);
  ok(/white-space:\s*normal/.test(rule[1]), rule[1]);
  ok(/\.p-waves \.modal td\.mono\s*\{\s*white-space:\s*nowrap;?\s*\}/.test(css), 'other IDs in a dialog stay on one line');
});

/* ---- Request, then the answers ---- */

function el() { return { style: {}, textContent: '', disabled: false }; }

function world({ result = [FILED], answers = new Map([[GUID, answer('REFUSED', 'QuotaNotAvailableForResource')]]), onAnswers = null } = {}) {
  const calls = [];
  const els = { '#ok': el(), '#err': el(), '#q-request': el() };
  names();
  Object.assign(globalThis, {
    $: (s) => els[s], runSeg: () => 'mig-1', runBody: (b) => b,
    apiPost: async () => ({}),
    watchQuotaRequest: async () => ({ result: { step: 'quotaResult', requests: result } }),
    watchQuotaAnswers: async (since, ids) => { calls.push(['ANSWERS', since, ids]); if (onAnswers) { onAnswers(); } return answers; },
    quotaConfirm: { phase: 'ready', rows: [] }, quotaConfirmTurn: 1,
    drawQuotaConfirm: () => { calls.push(['DRAW', globalThis.quotaConfirm && JSON.parse(JSON.stringify(globalThis.quotaConfirm))]); },
    closeQuotaConfirm: () => { globalThis.quotaConfirm = null; globalThis.quotaConfirmTurn++; },
    loadClaims: async () => true, drawEditorWhenFree: () => {},
  });
  return { calls, els };
}
const sendQuotaRequest = lift('waves.html', 'sendQuotaRequest');

test('RUN: after the result line, the confirmation says "filed" with the spinner, then shows the answer', async () => {
  const w = world();
  await sendQuotaRequest();
  const draws = w.calls.filter(c => c[0] === 'DRAW').map(c => c[1]);
  const reading = draws.find(d => d.phase === 'done' && d.reading === true);
  ok(reading, 'drawn while it reads');
  const last = draws.pop();
  eq(last.reading, false);
  eq(last.rows[0].answer, 'REFUSED');
  eq(last.rows[0].answerCode, 'QuotaNotAvailableForResource');
  const watch = w.calls.find(c => c[0] === 'ANSWERS');
  eq(watch[2], [ID], 'it waits for the line of each filed request');
  ok(watch[1] <= Date.now(), 'from the same window as the result');
});

test('RUN: nothing to read (approved at once, or not filed): no wait for answers', async () => {
  const w = world({ result: [AT_ONCE, NOT_FILED] });
  await sendQuotaRequest();
  ok(!w.calls.some(c => c[0] === 'ANSWERS'));
  eq(globalThis.quotaConfirm.reading, undefined);
});

test('RUN: closed while the product reads: the answer goes onto the page', async () => {
  const w = world({ onAnswers: () => globalThis.closeQuotaConfirm() });
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, null, 'not opened again');
  ok(w.els['#err'].textContent.includes('Azure refused the quota increase request for Standard DASv5 Family vCPUs in centralus, with the code QuotaNotAvailableForResource.'), w.els['#err'].textContent);
  ok(w.els['#err'].textContent.includes('Increase VM-family vCPU quotas'), w.els['#err'].textContent);
  eq(w.els['#err'].style.display, 'block');
});

test('RUN: closed before the result line: the page says "filed" and that the answer shows here, then the answer', async () => {
  const w = world({ answers: new Map([[GUID, answer('APPROVED')]]) });
  globalThis.watchQuotaRequest = async () => { globalThis.closeQuotaConfirm(); return { result: { requests: [FILED] } }; };
  const seen = [];
  globalThis.watchQuotaAnswers = async () => { seen.push(w.els['#ok'].textContent); return new Map([[GUID, answer('APPROVED')]]); };
  await sendQuotaRequest();
  ok(seen[0].includes(UX.quotaFiled.replace('{quotas}', 'Standard DASv5 Family vCPUs in centralus')), seen[0]);
  ok(seen[0].includes(UX.quotaReadingPage), seen[0]);
  eq(w.els['#ok'].textContent, 'Azure accepted the quota increase request for Standard DASv5 Family vCPUs in centralus. Select Check the quota on the card Request a quota increase.');
  eq(w.els['#err'].style.display, 'none');
});

test('RUN: opened again while the product reads: the answer goes onto the page, not into the new confirmation', async () => {
  const w = world({ onAnswers: () => { globalThis.quotaConfirm = { phase: 'wait' }; globalThis.quotaConfirmTurn++; } });
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, { phase: 'wait' });
  ok(w.els['#err'].textContent.includes('Azure refused'), w.els['#err'].textContent);
});

test('RUN: the wait for answers that throws leaves each request as not answered, never as approved', async () => {
  const w = world();
  globalThis.watchQuotaAnswers = async () => { throw new Error('read failed'); };
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm.rows[0].answer, 'WAITING');
  eq(globalThis.quotaConfirm.reading, false);
  ok(w.calls.length >= 0);
});

/* ---- the watch ---- */

test('RUN: the watcher collects the quotaAnswer line of each request, and ends when each has one', async () => {
  const watchQuotaAnswers = lift('waves.html', 'watchQuotaAnswers');
  globalThis.quotaAnswerKey = lift('waves.html', 'quotaAnswerKey');
  let opts = null;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobLines = async (p) => { opts.read = p; return []; };
  const other = '00000000-0000-4000-8000-0000000000bb';
  const lines = [answer('REFUSED', 'X'), { step: 'quotaAnswer', requestId: other, answer: 'APPROVED' }, { step: 'quotaResult', requestId: ID }];
  globalThis.VmfHelp = { watchRun: async (o) => { opts = o; await o.readLines(); return o.scan(lines); } };
  const got = await watchQuotaAnswers(1234, [ID]);
  eq(opts.sinceMs, 1234);
  eq(opts.read, 'p/mig-1/logs/events.jsonl');
  ok(opts.timeoutMs >= 180000, 'longer than the 2 minutes the engine reads');
  eq([...got.keys()], [GUID], 'only the lines of the requests it waits for');
  eq(got.get(GUID).answer, 'REFUSED');
  globalThis.VmfHelp = { watchRun: async (o) => { opts = o; return null; } };
  const none = await watchQuotaAnswers(1234, [ID]);
  eq(opts.scan([{ step: 'quotaResult', requestId: ID }]), null, 'no answer line yet: it goes on');
  eq(none.size, 0, 'the time ended with no line: nothing is said as an answer');
});

/* ---- the activity log ---- */

test('RUN: the activity log shows each answer line as what it says', () => {
  const { stepText } = { stepText: lift('migrations.html', 'stepText') };
  globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
  globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
  globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
  const said = `Azure refused the quota increase request ${GUID} for Standard DASv5 Family vCPUs in centralus, with the code QuotaNotAvailableForResource.`;
  eq(stepText({ step: 'quotaAnswer', outcome: 'warn', detail: said }), said);
  eq(stepText({ step: 'quotaAnswer', outcome: 'ok' }), globalThis.UX_STEP.quotaAnswerStep);
});

run('quota-request-poll');
