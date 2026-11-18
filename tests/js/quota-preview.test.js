/* QUOTA-PREVIEW-1: Request an increase asks first, and the access is known at plan time.
 *
 * The first version had a box, "Show me what would be requested first", and
 * its purpose was not clear. And the missing access was found only at the
 * click, which is too late: the plan already tells the product, from the
 * start, whether it has the right access.
 *
 * The approved design:
 * - No box. Request an increase opens a confirmation (Cancel, Escape) that gets
 *   the engine's preview (the quotaPreview line in the run's activity log) and
 *   lists exactly what will be requested, one row per quota, with Azure's
 *   column names: Quota, Region, Usage, Current limit, New limit. Under each
 *   row, each wave's need and what the current limit leaves. Nothing is filed
 *   until Request.
 * - The quota check records whether the tool may request each quota
 *   (quota.requestAccess). With no access, the card has no request button: it
 *   says to give the tool access on the Admin page, and links there. Unknown
 *   says the tool could not read its access, and keeps the button.
 *
 * RUN, not read: the page's own functions, with the service stubbed.
 */
'use strict';
// QUOTA-CHECK-SPINNER-1: loadClaims counts its reads, so only the newest fills the page.
globalThis.claimsTurn = 0;
const { pageSource } = require('./_page-source');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
const quotaConfirmHtml = lift('waves.html', 'quotaConfirmHtml');
const quotaCardHtml = lift('waves.html', 'quotaCardHtml');
const quotaAccessFrom = lift('waves.html', 'quotaAccessFrom');
// REGIONAL-QUOTA-BOTH-PAGE-1: the page asks help.js whether a record is short of the region.
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
const claimRegionalShort = lift('help.js', 'claimRegionalShort');
// Lifted alone: each calls the stand-ins a test gives it.
const openQuotaConfirm = lift('waves.html', 'openQuotaConfirm');
const sendQuotaRequest = lift('waves.html', 'sendQuotaRequest');
const watchQuotaPreview = lift('waves.html', 'watchQuotaPreview');
const closers = liftAll('waves.html', ['closeQuotaConfirm', 'quotaConfirmKey']);

const SUB_A = '11111111-2222-3333-4444-555555555555';
const SUB_B = '00000000-0000-0000-0000-000000000000';
const ROWS = [
  { family: 'standardDDSv6Family', quotaName: 'Standard DDSv6 Family vCPUs', subscriptionId: SUB_A, region: 'centralus',
    usage: 30, currentLimit: 40, requestedLimit: 46, free: 10, access: 'granted', status: 'WHATIF',
    waves: [{ wave: 'wave-1', vcpus: 6 }, { wave: 'wave-2', vcpus: 10 }] },
  { family: 'standardEDSv6Family', quotaName: 'Standard EDSv6 Family vCPUs', subscriptionId: SUB_A, region: 'eastus2',
    usage: 20, currentLimit: 24, requestedLimit: 30, free: 4, access: 'granted', status: 'WHATIF',
    waves: [{ wave: 'wave-3', vcpus: 10 }] },
];

globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.subName = (id) => ({ [SUB_A]: 'Applications', [SUB_B]: 'Production' })[id] ?? id;

function el(extra = {}) { return { style: {}, textContent: '', disabled: false, ...extra }; }

function world({ watch = { preview: { step: 'quotaPreview', requests: ROWS } }, postFails = null } = {}) {
  const calls = [];
  const els = { '#ok': el(), '#err': el(), '#q-request': el() };
  globalThis.$ = (sel) => els[sel];
  globalThis.UX = UX;
  globalThis.runSeg = () => 'mig-1';
  globalThis.runBody = (b) => b;
  /* WAVES-API-1: the page's own poster. This stand-in was `api`, a helper the
   * page never had, so the tests passed against a page that threw. */
  globalThis.apiPost = async (p, b) => {
    calls.push(['POST', p, b]);
    if (postFails && b && b.whatIfOnly === postFails.whatIfOnly) { throw new Error(postFails.message); }
    return {};
  };
  globalThis.watchQuotaPreview = async (since, stillWanted) => { calls.push(['WATCH', since, stillWanted]); return watch; };
  globalThis.VmfHelp = { explainAction: (e) => e.message, explain: (e) => e.message };
  globalThis.quotaConfirm = null;
  globalThis.quotaConfirmTurn = 0;
  globalThis.drawQuotaConfirm = () => { calls.push(['DRAW', globalThis.quotaConfirm && { ...globalThis.quotaConfirm }]); };
  globalThis.closeQuotaConfirm = () => { calls.push(['CLOSE']); globalThis.quotaConfirm = null; globalThis.quotaConfirmTurn++; };
  globalThis.document = { addEventListener: (t, f) => calls.push(['LISTEN', t, f]), removeEventListener: (t, f) => calls.push(['UNLISTEN', t, f]) };
  globalThis.quotaConfirmKey = function quotaConfirmKey() { };
  return { calls, els };
}

/* ---- opening the confirmation ---- */

test('RUN: Request an increase opens the confirmation and asks for a PREVIEW - nothing is filed', async () => {
  const w = world();
  await openQuotaConfirm();
  const posts = w.calls.filter(c => c[0] === 'POST');
  eq(posts.length, 1, 'one request to the service');
  eq(posts[0][1], 'runs/mig-1/engine/quota', 'the engine quota operation');
  eq(posts[0][2].whatIfOnly, true, 'a preview only - nothing is filed before Request');
  ok(w.calls.some(c => c[0] === 'WATCH'), 'and the page waits for the answer');
  eq(globalThis.quotaConfirm, { phase: 'ready', rows: ROWS }, 'the rows the engine wrote are kept for the confirmation');
  eq(w.els['#ok'].textContent, '', 'no "filed" line for a preview');
});

test('RUN: the confirmation opens at once, saying it is reading, before the engine answers', async () => {
  const w = world();
  await openQuotaConfirm();
  const firstDraw = w.calls.find(c => c[0] === 'DRAW');
  eq(firstDraw[1], { phase: 'wait' }, 'drawn first in its waiting state');
  ok(w.calls.indexOf(firstDraw) < w.calls.findIndex(c => c[0] === 'POST'), 'before the request goes');
});

test('RUN: the watch opens before the request, so a fast engine line is not missed', async () => {
  const w = world();
  const before = Date.now();
  await openQuotaConfirm();
  const since = w.calls.find(c => c[0] === 'WATCH')[1];
  ok(since <= before, `the window opens at or before the press (since ${since}, press ${before})`);
});

test('RUN: opening adds an Escape listener (rule 11), once', async () => {
  const w = world();
  await openQuotaConfirm();
  const listens = w.calls.filter(c => c[0] === 'LISTEN' && c[1] === 'keydown');
  eq(listens.length, 1, 'one listener');
  ok(w.calls.findIndex(c => c[0] === 'UNLISTEN') < w.calls.findIndex(c => c[0] === 'LISTEN'), 'an earlier one is removed first (LEAK-2)');
});

test('RUN: an engine that failed says why in the confirmation, and offers no Request', async () => {
  const w = world({ watch: { failure: { step: 'engine:quota', outcome: 'fail', detail: 'No quota records found' } } });
  await openQuotaConfirm();
  eq(globalThis.quotaConfirm.phase, 'error');
  ok(/No quota records/.test(globalThis.quotaConfirm.error), `the reason, got: ${globalThis.quotaConfirm.error}`);
  ok(!w.calls.some(c => c[0] === 'POST' && c[2].whatIfOnly === false), 'nothing filed');
});

test('RUN: no answer in time is said, not shown as an empty list', async () => {
  world({ watch: null });
  await openQuotaConfirm();
  eq(globalThis.quotaConfirm, { phase: 'error', error: UX.quotaPreviewNoAnswer });
});

test('RUN: a service that refuses the preview says why in the confirmation', async () => {
  world({ postFails: { whatIfOnly: true, message: 'HTTP 403' } });
  await openQuotaConfirm();
  eq(globalThis.quotaConfirm, { phase: 'error', error: 'HTTP 403' });
});

test('RUN: a preview that arrives after Cancel is not shown, and the watch is told to stop', async () => {
  const w = world();
  let stillWanted = null;
  globalThis.watchQuotaPreview = async (since, wanted) => {
    stillWanted = wanted;
    // The person cancels while the engine works.
    globalThis.quotaConfirm = null; globalThis.quotaConfirmTurn++;
    return { preview: { requests: ROWS } };
  };
  await openQuotaConfirm();
  eq(globalThis.quotaConfirm, null, 'the late answer does not open the confirmation again');
  ok(typeof stillWanted === 'function' && stillWanted() === false, 'the watch can see it is no longer wanted');
  const afterOpen = w.calls.slice(w.calls.findIndex(c => c[0] === 'DRAW') + 1);
  ok(!afterOpen.some(c => c[0] === 'DRAW'), 'nothing drawn after the cancel');
});

test('RUN: a failure that arrives after Cancel is not shown either', async () => {
  world({ postFails: { whatIfOnly: true, message: 'HTTP 403' } });
  globalThis.apiPost = async () => { globalThis.quotaConfirm = null; globalThis.quotaConfirmTurn++; throw new Error('HTTP 403'); };
  await openQuotaConfirm();
  eq(globalThis.quotaConfirm, null);
});

test('RUN: a preview of one row stays a list', async () => {
  world({ watch: { preview: { requests: ROWS[0] } } });
  await openQuotaConfirm();
  eq(globalThis.quotaConfirm.rows, [ROWS[0]]);
});

/* ---- Request ---- */

/* QUOTA-FILED-WORDS-1: Request now waits for the engine's quotaResult line and
 * says "filed" only for the quotas Azure took. Its tests are in
 * quota-filed-words.test.js. */

/* ---- the watch ---- */

test('RUN: the watcher ends on the preview line, or on an engine failure - nothing else', async () => {
  let scan = null;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobLines = async () => [];
  globalThis.VmfHelp = { watchRun: async (o) => { scan = o.scan; return null; } };
  await watchQuotaPreview(0);
  const preview = { step: 'quotaPreview', outcome: 'info', requests: [] };
  const noSub = { step: 'quotaRequest', outcome: 'fail', detail: 'family=X: the quota record does not name a subscription' };
  const engineFail = { step: 'engine:quota', outcome: 'fail', detail: 'No quota records found' };
  const filed = { step: 'quotaRequest', outcome: 'ok', detail: 'family=X newLimit=12 status=PENDING' };
  const check = { step: 'capacity', outcome: 'ok', detail: 'claims=1 blocked=0 wave=wave-1' };
  eq(scan([noSub, preview]), { preview }, 'one family with no subscription does not end the wait - the preview does');
  eq(scan([engineFail]), { failure: engineFail }, 'the engine failing ends it');
  eq(scan([engineFail, preview]), { preview }, 'a preview line in the same read wins');
  eq(scan([filed, check, noSub]), null, 'a real request\'s line and a quota check are not the preview');
});

test('RUN: the watcher reads the run\'s activity log, from the press, and stops when nobody wants it', async () => {
  let opts = null;
  globalThis.runPrefix = () => 'p/mig-1';
  globalThis.blobLines = async (p) => { opts.read = p; return []; };
  globalThis.VmfHelp = { watchRun: async (o) => { opts = o; await o.readLines(); return null; } };
  let wanted = true;
  await watchQuotaPreview(1234, () => wanted);
  eq(opts.sinceMs, 1234);
  eq(opts.read, 'p/mig-1/logs/events.jsonl');
  eq(await opts.onTick(), null, 'still wanted: keep watching');
  wanted = false;
  eq(await opts.onTick(), { cancelled: true }, 'cancelled: stop polling');
});

/* ---- what the confirmation shows ---- */

test('RUN: the confirmation has the title, the subscription line, and its six columns', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: ROWS });
  eq(UX.quotaConfirmTitle, 'Request a quota increase?');
  ok(html.includes(`<h3 id="q-m-title">${UX.quotaConfirmTitle}</h3>`), 'the title, named by the dialog');
  ok(html.includes(esc(UX.quotaConfirmLine.replace('{name}', 'Applications'))), 'the line names the subscription by its name');
  // Since 2026-10-26: nobody "asks Azure"; you request a quota increase.
  // QUOTA-CHECK-SPINNER-1: the first pop-up was unclear.
  eq(UX.quotaConfirmLine, 'The product requests these quota increases on subscription {name}. Azure accepts or refuses each request. The answer can come after some days.');
  const heads = [...html.matchAll(/<th[^>]*>([^<]*)<\/th>/g)].map(m => m[1]);
  eq(heads, ['Quota', 'Region', 'Usage', 'Current limit', 'The waves need', 'New limit'], 'the column names, in this order, with what the waves need');
});

test('RUN: each quota is a row with its name, region, in use, current limit, what the waves need and new limit', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: ROWS });
  ok(/>Standard DDSv6 Family vCPUs<\/td><td>centralus<\/td><td class="num">30<\/td><td class="num">40<\/td><td class="num">16<\/td><td class="num">46<\/td>/.test(html), 'the first quota: the waves need 6 + 10');
  ok(/>Standard EDSv6 Family vCPUs<\/td><td>eastus2<\/td><td class="num">20<\/td><td class="num">24<\/td><td class="num">10<\/td><td class="num">30<\/td>/.test(html), 'the second quota');
});

test('RUN: under each quota, each wave\'s need, the vCPUs free now, and the new limit', () => {
  globalThis.UX = UX;
  eq(UX.quotaWaveLine, 'Wave {wave} needs {n} vCPUs of {quota} in {region}.');
  eq(UX.quotaFreeLine, '{free} vCPUs of this quota are free now.');
  eq(UX.quotaAskLine, 'The product requests a new limit of {limit} vCPUs.');
  const html = quotaConfirmHtml({ phase: 'ready', rows: ROWS });
  ok(html.includes('Wave wave-1 needs 6 vCPUs of Standard DDSv6 Family vCPUs in centralus.'), 'wave-1');
  ok(html.includes('Wave wave-2 needs 10 vCPUs of Standard DDSv6 Family vCPUs in centralus.'), 'wave-2');
  ok(html.includes('10 vCPUs of this quota are free now.') && html.includes('The product requests a new limit of 46 vCPUs.'), 'the first quota: 40 less 30 is free, and 46 is asked');
  ok(html.includes('Wave wave-3 needs 10 vCPUs of Standard EDSv6 Family vCPUs in eastus2.'), 'wave-3 under the second quota');
  ok(html.includes('4 vCPUs of this quota are free now.'), 'the second quota: 24 less 20');
  const first = html.indexOf('Standard DDSv6'), second = html.indexOf('Standard EDSv6');
  const w1 = html.indexOf('wave-1 needs'), w3 = html.indexOf('wave-3 needs');
  ok(first < w1 && w1 < second && second < w3, 'each wave line sits under its own quota');
});

test('RUN: a wave name with braces is shown as written, not read as a placeholder', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [{ ...ROWS[0], waves: [{ wave: 'w{n}', vcpus: 6 }] }] });
  ok(html.includes('Wave w{n} needs 6 vCPUs'), 'the wave name is not changed');
});

test('RUN: a record with no quota name shows its family', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [{ ...ROWS[0], quotaName: '' }] });
  ok(html.includes('>standardDDSv6Family</td>'));
});

test('RUN: two subscriptions each have their own line and table', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [ROWS[0], { ...ROWS[1], subscriptionId: SUB_B }] });
  ok(html.includes(esc(UX.quotaConfirmLine.replace('{name}', 'Applications'))));
  ok(html.includes(esc(UX.quotaConfirmLine.replace('{name}', 'Production'))));
  eq((html.match(/<table/g) || []).length, 2);
  ok(html.indexOf('Production') < html.indexOf('Standard EDSv6'), 'the second quota under its own subscription');
});

test('RUN: Cancel is always there; Request only when there is something to request', () => {
  globalThis.UX = UX;
  for (const c of [{ phase: 'wait' }, { phase: 'error', error: 'x' }, { phase: 'ready', rows: [] }, { phase: 'ready', rows: ROWS }]) {
    const html = quotaConfirmHtml(c);
    ok(/<button[^>]*id="q-cancel"[^>]*>/.test(html) && html.includes(UX.cancel), `Cancel in ${c.phase}`);
  }
  ok(!quotaConfirmHtml({ phase: 'wait' }).includes('id="q-request"'), 'no Request while it reads');
  ok(!quotaConfirmHtml({ phase: 'error', error: 'x' }).includes('id="q-request"'), 'no Request after a failure');
  ok(!quotaConfirmHtml({ phase: 'ready', rows: [] }).includes('id="q-request"'), 'no Request with nothing to request');
  ok(quotaConfirmHtml({ phase: 'ready', rows: ROWS }).includes(`id="q-request">${UX.quotaConfirmBtn}<`), 'Request with rows');
  eq(UX.quotaConfirmBtn, 'Request');
});

test('RUN: the waiting state says it is reading; the error state says why', () => {
  globalThis.UX = UX;
  ok(quotaConfirmHtml({ phase: 'wait' }).includes(UX.quotaConfirmWait));
  ok(quotaConfirmHtml({ phase: 'error', error: 'it broke <b>' }).includes('it broke &lt;b&gt;'), 'escaped');
});

test('RUN: an empty preview says nothing would be requested, with no empty table', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [] });
  ok(html.includes(UX.quotaPreviewNone));
  ok(!html.includes('<table'), 'no table with no rows');
});

test('RUN: a quota that cannot be requested is named, not put in the table', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [ROWS[0],
    { ...ROWS[1], family: 'standardFSv2Family', quotaName: '', status: 'FAILED', subscriptionId: '' },
    { ...ROWS[1], quotaName: 'Standard EDSv6 Family vCPUs', status: 'NOACCESS', subscriptionId: SUB_B }] });
  ok(!html.includes('<td>standardFSv2Family</td>') && !html.includes('<td>Standard EDSv6 Family vCPUs</td>'), 'not a row of any table');
  eq((html.match(/<table/g) || []).length, 1, 'and no table for the subscription with no access');
  ok(!html.includes(esc(UX.quotaConfirmLine.replace('{name}', 'Production'))), 'nor the line that says the product asks there');
  ok(html.includes(UX.quotaPreviewNoSub.replace('{families}', 'standardFSv2Family')), 'no subscription: named in its own sentence');
  ok(html.includes(esc(UX.quotaNoAccess.replace('{name}', 'Production'))), 'no access: said, with the subscription name');
  ok(!quotaConfirmHtml({ phase: 'ready', rows: [{ ...ROWS[0], status: 'NOACCESS' }] }).includes(UX.quotaPreviewNone), 'a quota that cannot be asked for is not "enough quota"');
});

test('RUN: what the engine wrote is escaped, and a missing figure says so', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [{ ...ROWS[0], quotaName: '<b>x</b>', currentLimit: null }] });
  ok(!html.includes('<b>x</b>') && html.includes('&lt;b&gt;'), 'no markup from the log');
  ok(!/null|undefined/.test(html), 'no null on the screen');
  ok(html.includes(UX.quotaNoFigure));
});

/* ---- the card: the access the quota check recorded ---- */

function card({ access = new Map(), short = true } = {}) {
  globalThis.UX = UX;
  globalThis.quotaShort = short;
  globalThis.unlistedWaves = new Set();
  globalThis.regionalShortRegions = new Set();
  globalThis.quotaChecked = true;
  // QUOTA-CHECK-SPINNER-1: the card's header and plan-wide table; no records here.
  Object.assign(globalThis, { checkingWaves: new Set(), lastChecked: new Map(), dirty: () => false, canEdit: true,
    planQuotaRows: () => [], agoHtml: (t) => t, waveNames: () => [], membersOf: () => [], capAnswers: new Map(), waveDocs: new Map(),
    quotaPlanState: lift('waves.html', 'quotaPlanState') });
  globalThis.quotaAccess = access;
  return quotaCardHtml();
}

test('RUN: the card has no box any more - one button', () => {
  const html = card();
  ok(!html.includes('type="checkbox"'), 'no checkbox');
  ok(!('quotaPreview' in UX), 'the box\'s words are gone');
  ok(/<button[^>]*id="q-go"[^>]*>Request an increase</.test(html), 'Request an increase');
});

test('RUN: with access, the card is as before: the button, and no access sentence', () => {
  const html = card({ access: new Map([[SUB_A, 'granted']]) });
  ok(html.includes('id="q-go"'));
  ok(!html.includes('access.html'), 'no Admin page link');
});

test('RUN: with no access, there is no button - the card says why and links to the Admin page', () => {
  const html = card({ access: new Map([[SUB_A, 'missing']]) });
  ok(!html.includes('id="q-go"'), 'no request button');
  // Approved 2026-10-26: Azure's terms, and "stop and resize the machines there", word for word.
  eq(UX.quotaNoAccess, 'The product cannot request a quota increase on subscription {name}. That needs the Assess and migrate role on the subscription, which also lets the product stop and resize the machines there. Give the role on the Admin page, or request a quota increase on the Quotas page of the Azure portal.');
  eq(UX.quotaTitle, 'Request a quota increase');
  // REGIONAL-QUOTA-REQUEST-1: Request an increase asks for the regional quota, so the line no longer sends anybody to the portal.
  ok(!/\bask Azure\b/i.test(UX.quotaRegional) && !/Azure portal/.test(UX.quotaRegional) && /Request an increase/.test(UX.quotaRegional), "the regional line names the button");
  ok(html.includes(esc(UX.quotaNoAccess.replace('{name}', 'Applications'))), 'the sentence, with the subscription name');
  ok(new RegExp(`<a[^>]*href="access\\.html[^"]*"[^>]*>${UX.quotaAdminLink}</a>`).test(html), 'Open the Admin page (rule 12)');
  eq(UX.quotaAdminLink, 'Open the Admin page');
});

test('RUN: unknown access is not shown as either - it says so, and keeps the button', () => {
  const html = card({ access: new Map([[SUB_A, 'unknown']]) });
  ok(html.includes('id="q-go"'), 'the button stays: Azure accepts or refuses the request');
  ok(html.includes(esc(UX.quotaAccessUnknown.replace('{name}', 'Applications'))), 'it says the product could not read its access');
  ok(!html.includes(esc(UX.quotaNoAccess.replace('{name}', 'Applications'))), 'not "no access"');
});

test('RUN: one subscription with access and one without - the button stays, and the one without is named', () => {
  const html = card({ access: new Map([[SUB_A, 'granted'], [SUB_B, 'missing']]) });
  ok(html.includes('id="q-go"'));
  ok(html.includes(esc(UX.quotaNoAccess.replace('{name}', 'Production'))));
  ok(!html.includes(esc(UX.quotaNoAccess.replace('{name}', 'Applications'))));
  ok(html.includes('access.html'), 'and the link to give it');
});

test('RUN: records from before the access was recorded say nothing about it, and keep the button', () => {
  const html = card({ access: new Map() });
  ok(html.includes('id="q-go"'));
  ok(!html.includes(esc(UX.quotaNoAccess.split('{name}')[0])), 'no access sentence');
});

test('RUN: a card with nothing too low shows no button and no access sentence', () => {
  const html = card({ short: false, access: new Map([[SUB_A, 'missing']]) });
  ok(!html.includes('id="q-go"'));
  ok(!html.includes('access.html'));
  ok(html.includes(UX.quotaNotChecked), 'the card says what it knows');
});

test('RUN: the access is read from the records too low, and the worst answer of a subscription wins', () => {
  globalThis.VmfHelp = { claimBlocked: (s) => s === 'BLOCKED' };
  const rec = (sub, access, extra = {}) => ({ subscriptionId: sub, state: 'BLOCKED', blockReason: 'quota-shortfall', quota: { requestAccess: access }, ...extra });
  const m = quotaAccessFrom([
    rec(SUB_A, 'granted'), rec(SUB_A, 'missing'), rec(SUB_A, 'unknown'),
    rec(SUB_B, 'granted'), rec(SUB_B, 'unknown'),
    rec('sub-c', 'missing', { blockReason: 'sku-restricted' }),
    rec('sub-d', 'missing', { state: 'QUOTA_REQUESTED' }),
    rec('sub-e', undefined),
  ]);
  eq(m.get(SUB_A), 'missing', 'missing beats unknown and granted');
  eq(m.get(SUB_B), 'unknown', 'unknown beats granted');
  eq(m.size, 2, 'only records blocked on quota-shortfall, with an answer, count');
  eq(quotaAccessFrom([rec(SUB_A.toUpperCase(), 'missing')]).get(SUB_A), 'missing', 'the subscription id is read without case');
});

/* REGIONAL-QUOTA-REQUEST-1: Request an increase asks for the Total Regional vCPUs quota too. */
test('RUN: a record blocked on the regional quota gives its access too', () => {
  globalThis.VmfHelp = { claimBlocked: (s) => s === 'BLOCKED' };
  const m = quotaAccessFrom([{ subscriptionId: SUB_A, state: 'BLOCKED', blockReason: 'regional-quota-shortfall', quota: { requestAccess: 'missing' } }]);
  eq(m.get(SUB_A), 'missing', 'a regional request needs the same access, at the same subscription');
});

test('RUN: a record blocked only on the regional quota shows Request an increase', async () => {
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  // The family fits: 100 free. The region does not.
  const docs = [{ wave: 'wave-1', subscriptionId: SUB_A, region: 'centralus', state: 'BLOCKED', blockReason: 'regional-quota-shortfall',
    demand: { instances: 1, reservableInstances: 1, vcpus: 4, regionalVcpus: 6 }, quota: { limit: 100, used: 0, regionalLimit: 10, regionalUsed: 8 } }];
  Object.assign(globalThis, { DEMO_MODE: false, runPrefix: () => 'p/mig-1', waveNoneReservable: () => false,
    blobList: async () => ['c0.json'], blobFetch: async () => docs[0],
    VmfHelp: { ...require('./_held').perFileHelp(), mapLimited: async (l, fn) => Promise.all(l.map(fn)), claimBlocked: (s) => s === 'BLOCKED', claimReservingStuck: () => false, claimRegionalShort },
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false, quotaShort: false, unlistedWaves: new Set(),
    lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map() });
  ok(await w.loadClaims(), 'the records are read');
  eq(globalThis.quotaShort, true, 'a quota is too low, so there is something to request');
  globalThis.UX = UX;
  Object.assign(globalThis, { checkingWaves: new Set(), lastChecked: new Map(), dirty: () => false, canEdit: true,
    planQuotaRows: () => [], agoHtml: (t) => t, waveNames: () => [], membersOf: () => [], capAnswers: new Map(),
    quotaPlanState: lift('waves.html', 'quotaPlanState') });
  const html = quotaCardHtml();
  ok(html.includes('id="q-go"'), 'the card offers Request an increase');
  ok(html.includes(esc(UX.quotaRegional.replace('{regions}', 'centralus'))), 'and names the region');
  docs[0] = { ...docs[0], state: 'QUOTA_VERIFIED', blockReason: null };
  await w.loadClaims();
  eq(globalThis.quotaShort, false, 'a region that fits asks for nothing');
});

test('RUN: a regional row with no subscription is named by its quota name, not its resource name', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [{ kind: 'regional', family: 'cores', quotaName: 'Total Regional vCPUs',
    subscriptionId: '', region: 'centralus', status: 'FAILED', waves: [] }] });
  ok(html.includes(UX.quotaPreviewNoSub.replace('{families}', 'Total Regional vCPUs')), `got: ${html}`);
});

test('RUN: a regional row is a row of the table, with no wave line', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [{ kind: 'regional', family: 'cores', quotaName: 'Total Regional vCPUs',
    subscriptionId: SUB_A, region: 'centralus', usage: 8, currentLimit: 10, requestedLimit: 14, free: 2, status: 'WHATIF', waves: [] }] });
  ok(html.includes('<td>Total Regional vCPUs</td>'), 'Azure\'s name in the Quota column');
  ok(html.includes('id="q-request"'), 'Request is offered');
  ok(!html.includes(' needs '), 'no wave line with a figure the record does not hold');
});

/* REGIONAL-QUOTA-WAVES-1: the engine now gives a regional row a line for each
 * wave, from the vCPUs that wave's machines add (demand.regionalAdds, v14). */
test('RUN: a regional row with wave lines shows each wave and what the current limit leaves', () => {
  globalThis.UX = UX;
  const html = quotaConfirmHtml({ phase: 'ready', rows: [{ kind: 'regional', family: 'cores', quotaName: 'Total Regional vCPUs',
    subscriptionId: SUB_A, region: 'centralus', usage: 8, currentLimit: 10, requestedLimit: 15, free: 2, status: 'WHATIF',
    waves: [{ wave: 'wave-1', vcpus: 2 }, { wave: 'wave-2', vcpus: 5 }] }] });
  for (const [wave, n] of [['wave-1', 2], ['wave-2', 5]]) {
    const line = UX.quotaWaveLine.replace('{wave}', wave).replace('{n}', String(n)).replace('{quota}', 'Total Regional vCPUs').replace('{region}', 'centralus');
    ok(html.includes(`<div class="hint">${esc(line)}</div>`), `the line for ${wave}: ${line}`);
  }
});
test('RUN: the page reads the access from the quota records it loads, and a failed read clears it', async () => {
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  const docs = [{ wave: 'wave-1', subscriptionId: SUB_A, region: 'centralus', state: 'BLOCKED', blockReason: 'quota-shortfall',
    demand: { instances: 1, reservableInstances: 1, vcpus: 4 }, quota: { limit: 10, used: 8, requestAccess: 'missing' } }];
  Object.assign(globalThis, { DEMO_MODE: false, runPrefix: () => 'p/mig-1', waveNoneReservable: () => false,
    blobList: async () => ['c0.json'], blobFetch: async () => docs[0],
    VmfHelp: { ...require('./_held').perFileHelp(), mapLimited: async (l, fn) => Promise.all(l.map(fn)), claimBlocked: (s) => s === 'BLOCKED', claimReservingStuck: () => false, claimRegionalShort },
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false, quotaShort: false, unlistedWaves: new Set(),
    lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map() });
  ok(await w.loadClaims(), 'the records are read');
  eq(globalThis.quotaAccess.get(SUB_A), 'missing', 'the card knows the product has no access there');
  globalThis.blobList = async () => { throw new Error('read failed'); };
  await w.loadClaims();
  eq(globalThis.quotaAccess.size, 0, 'an earlier answer does not stand after a failed read');
});
test('RUN: drawing the card wires Request an increase to the confirmation', () => {
  const drawQuotaCard = lift('waves.html', 'drawQuotaCard');
  const wired = [];
  const node = (id) => ({ id, innerHTML: '', addEventListener: (t, f) => wired.push([id, t, f]) });
  const els = { '#quota': node('quota'), '#q-go': node('q-go') };
  globalThis.$ = (s) => els[s];
  globalThis.quotaCardHtml = () => 'CARD';
  globalThis.openQuotaConfirm = function openQuotaConfirm() { };
  drawQuotaCard();
  eq(els['#quota'].innerHTML, 'CARD');
  ok(wired.some(w => w[0] === 'q-go' && w[1] === 'click' && w[2] === globalThis.openQuotaConfirm));
});

test('RUN: drawing the confirmation shows it and wires Cancel and Request; closed, it hides', () => {
  const drawQuotaConfirm = lift('waves.html', 'drawQuotaConfirm');
  const wired = [];
  const classes = new Set();
  const node = (id) => ({ id, innerHTML: '', addEventListener: (t, f) => wired.push([id, t, f]),
    classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) } });
  const els = { '#q-modal-back': node('q-modal-back'), '#q-modal': node('q-modal'), '#q-cancel': node('q-cancel'), '#q-request': node('q-request') };
  globalThis.$ = (s) => els[s];
  globalThis.quotaConfirmHtml = () => 'DIALOG';
  globalThis.closeQuotaConfirm = function closeQuotaConfirm() { };
  globalThis.sendQuotaRequest = function sendQuotaRequest() { };
  globalThis.quotaConfirm = { phase: 'ready', rows: ROWS };
  drawQuotaConfirm();
  ok(classes.has('open'), 'shown');
  eq(els['#q-modal'].innerHTML, 'DIALOG');
  ok(wired.some(w => w[0] === 'q-cancel' && w[2] === globalThis.closeQuotaConfirm), 'Cancel');
  ok(wired.some(w => w[0] === 'q-request' && w[2] === globalThis.sendQuotaRequest), 'Request');
  globalThis.quotaConfirm = null;
  drawQuotaConfirm();
  ok(!classes.has('open'), 'hidden when closed');
});

/* ---- the way back ---- */

test('RUN: Escape closes the confirmation and stops listening; another key does nothing', () => {
  const w = world();
  // The page's own close, lifted with its key handler.
  globalThis.quotaConfirm = { phase: 'ready', rows: ROWS };
  globalThis.quotaConfirmTurn = 3;
  closers.quotaConfirmKey({ key: 'Enter' });
  eq(globalThis.quotaConfirm, { phase: 'ready', rows: ROWS }, 'Enter leaves it open');
  closers.quotaConfirmKey({ key: 'Escape' });
  eq(globalThis.quotaConfirm, null, 'Escape closes it');
  eq(globalThis.quotaConfirmTurn, 4, 'and a preview still on its way is no longer wanted');
  ok(w.calls.some(c => c[0] === 'DRAW'), 'and it is drawn closed');
  ok(w.calls.some(c => c[0] === 'UNLISTEN' && c[1] === 'keydown'), 'and the listener goes (LEAK-2)');
  ok(!w.calls.some(c => c[0] === 'POST'), 'nothing filed');
});

test('RUN: the dialog is in the page, and a click outside it closes it', () => {
  const src = pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  ok(/<div id="q-modal-back"><div class="modal" id="q-modal" role="dialog" aria-modal="true" aria-labelledby="q-m-title"><\/div><\/div>/.test(src), 'the dialog markup');
  ok(src.includes("$('#q-modal-back').addEventListener('click', (e) => { if (e.target === e.currentTarget) closeQuotaConfirm(); });"), 'a click outside closes it');
});

/* ---- the activity log ---- */

test('RUN: the activity log shows the preview line as what it says - not "A quota increase was requested"', () => {
  const { stepText } = liftAll('migrations.html', ['stepText']);
  globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
  globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
  globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
  const said = 'The preview shows 2 quota increase requests. No request was filed.';
  eq(stepText({ step: 'quotaPreview', outcome: 'info', detail: said, requests: [] }), said);
  eq(stepText({ step: 'quotaPreview', outcome: 'info' }), globalThis.UX_STEP.quotaPreviewStep, 'with no detail, its own label');
  ok(globalThis.UX_STEP.quotaPreviewStep !== globalThis.UX_STEP.quotaStep, 'not the label of a real request');
});

run('quota-preview');
