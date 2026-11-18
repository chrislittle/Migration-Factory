/* QUOTA-CHECK-SPINNER-1: the quota of the plan, its check and the request
 * confirmation say what they do, and what is short.
 *
 * Final lab: the row showed only "The quota is not enough" and
 * "Checked 5s ago", and the age never moved. Its hover was engine text:
 * "1 claim(s) below the BestEffort gate: Standard_D2as_v5@centralus [BLOCKED]".
 * The confirmation sat for 35 seconds on one line with no spinner and nothing
 * that said what it was doing. After Request, the title stayed a
 * question, and nothing said when it was done.
 *
 * Lab walk 2026-11-17, with a mock-up: the quota belongs to the plan.
 * - The Request a quota increase card: Checked <time> and Check the quota in
 *   its header (one check covers every wave), the state of the plan, a table
 *   of every quota the plan uses (QUOTA / REGION / LIMIT / IN USE / ALL WAVES
 *   NEED / SHORT BY, rows with a problem first, "Enough" in a row with room),
 *   a note, then the request when a quota is short. While a check runs: the
 *   spinner, and nothing from a result.
 * - Each wave: one line for each quota family it uses, short or enough; the
 *   sizes Azure refused; while a check runs, the spinner. No table, no button.
 * - Every time moves (data-ago).
 * - The confirmation reads with a spinner, has a column for what the waves
 *   need and a sentence per wave, a title that is not a question after
 *   Request, a spinner while it sends, and a table of each request.
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
// QUOTA-CHECK-SPINNER-1: loadClaims counts its reads, so only the newest fills the page.
globalThis.claimsTurn = 0;
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const UX = liftConst('waves.html', 'UX');
// The page asks help.js whether a record is short of the region; those rules call claimBlocked.
globalThis.claimBlocked = lift('help.js', 'claimBlocked');
const claimRegionalShort = lift('help.js', 'claimRegionalShort');
const claimRegionalRequested = lift('help.js', 'claimRegionalRequested');
const SUB = '11111111-2222-3333-4444-555555555555';
const T1 = '2026-11-16T10:00:00.000Z';
const T0 = '2026-11-15T10:00:00.000Z';

globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.cssEscape = (s) => String(s);
globalThis.ago = (iso) => (iso ? `AGO(${iso})` : '');

function setWorld({ docs = {}, checking = [], answers = new Map(), unlisted = [] } = {}) {
  globalThis.UX = UX;
  globalThis.VmfHelp = { claimBlocked: (s) => String(s).toUpperCase() === 'BLOCKED', claimRegionalShort, claimRegionalRequested };
  globalThis.waveDocs = new Map(Object.entries(docs));
  globalThis.checkingWaves = new Set(checking);
  globalThis.capAnswers = answers;
  globalThis.unlistedWaves = new Set(unlisted);
  const last = new Map();
  for (const [w, list] of Object.entries(docs)) {
    for (const d of list) {
      const at = d.quota?.checkedUtc;
      if (at && (!last.has(w) || Date.parse(at) > Date.parse(last.get(w)))) { last.set(w, at); }
    }
  }
  globalThis.lastChecked = last;
  globalThis.dirty = () => false;
  globalThis.canEdit = true;
  globalThis.subName = (id) => (id === SUB ? 'Applications' : String(id ?? ''));
}

// One record of the capacity folder (capacity-claim v15), as the engine writes it.
function rec(extra = {}) {
  return {
    wave: 'q1', subscriptionId: SUB, region: 'centralus', size: 'Standard_D2as_v5', vmFamily: 'standardDASv5Family',
    state: 'QUOTA_VERIFIED', blockReason: null, regionalShort: false,
    demand: { instances: 1, reservableInstances: 1, vcpus: 2, familyVcpus: 4, regionalVcpus: 2, regionalAdds: 2 },
    quota: { limit: 10, used: 4, regionalLimit: 100, regionalUsed: 20, name: 'Standard DASv5 Family vCPUs', checkedUtc: T1 },
    ...extra,
  };
}
// Short: all waves need 8, and 10 - 8 = 2 are free, so the plan is short by 6.
const SHORT = (extra = {}) => rec({ state: 'BLOCKED', blockReason: 'quota-shortfall',
  demand: { instances: 1, reservableInstances: 1, vcpus: 2, familyVcpus: 8, regionalVcpus: 2, regionalAdds: 2 },
  quota: { limit: 10, used: 8, regionalLimit: 100, regionalUsed: 20, name: 'Standard DASv5 Family vCPUs', checkedUtc: T1 }, ...extra });

const ROWFNS = ['quotaShortFamily', 'quotaShortRegion', 'quotaGroups', 'planQuotaRows', 'waveQuotaLines', 'waveRefusedText', 'quotaStateHtml', 'quotaControl', 'agoHtml'];
const page = () => liftAll('waves.html', ROWFNS);
const lineOf = (text, v) => text.replace(/\{(n|quota|region|s)\}/g, (_, k) => String(v[k]));

/* ---- the quotas of the plan ---- */

test('RUN: the plan has one row for each quota family and region, and one for the Total Regional vCPUs of each region', () => {
  setWorld({ docs: { q1: [SHORT(), SHORT({ size: 'Standard_D4as_v5', demand: { instances: 1, vcpus: 4, familyVcpus: 8, regionalVcpus: 6, regionalAdds: 4 } })],
    q2: [rec({ wave: 'q2', vmFamily: 'standardEASv5Family', quota: { ...rec().quota, name: 'Standard EASv5 Family vCPUs' } })] } });
  const rows = page().planQuotaRows();
  eq(rows.map(r => r.quota), ['Standard DASv5 Family vCPUs', 'Standard EASv5 Family vCPUs', 'Total Regional vCPUs'], 'the row with a problem first');
  const d = rows[0];
  eq([d.region, d.limit, d.used, d.planNeed, d.short, d.shortBy], ['centralus', 10, 8, 8, true, 6], 'the engine said short; all waves need 8; 2 free');
  eq([rows[1].short, rows[1].shortBy], [false, 0], 'a quota with room is not short');
  eq(rows[2].regional, true);
});

test('RUN: a size Azure refused, a refused reservation, and a released record do not make a quota short', () => {
  setWorld({ docs: { q1: [rec({ state: 'BLOCKED', blockReason: 'sku-restricted', vmFamily: 'standardFXFamily' }), rec({ state: 'BLOCKED', blockReason: 'reservation-failed' }),
    rec({ state: 'RELEASED', blockReason: 'quota-shortfall', vmFamily: 'standardOldFamily' })] } });
  const rows = page().planQuotaRows();
  eq(rows.map(r => r.quota), ['Standard DASv5 Family vCPUs', 'Total Regional vCPUs']);
  ok(rows.every(r => !r.short), 'nothing short');
});

test('RUN: a quota whose increase request waits is still short - a request is not more quota', () => {
  setWorld({ docs: { q1: [SHORT({ state: 'QUOTA_REQUESTED' })] } });
  eq(page().planQuotaRows()[0].short, true);
});

test('RUN: the Total Regional vCPUs quota is short when the engine says so, or while its request waits', () => {
  setWorld({ docs: { q1: [rec({ state: 'BLOCKED', blockReason: 'regional-quota-shortfall',
    demand: { instances: 1, vcpus: 2, familyVcpus: 2, regionalVcpus: 12, regionalAdds: 2 },
    quota: { limit: 100, used: 0, regionalLimit: 20, regionalUsed: 16, name: 'Standard DASv5 Family vCPUs', checkedUtc: T1 } })] } });
  const rows = page().planQuotaRows();
  eq(rows[0].quota, UX.capRegionalName, 'first: it is the short one');
  eq(UX.capRegionalName, 'Total Regional vCPUs', 'Azure\'s own name');
  eq([rows[0].limit, rows[0].used, rows[0].planNeed, rows[0].short, rows[0].shortBy], [20, 16, 12, true, 8]);
  eq(rows[1].short, false, 'the family has room');
});

test('RUN: the Total Regional vCPUs quota whose increase request waits is still short', () => {
  setWorld({ docs: { q1: [rec({ state: 'QUOTA_REQUESTED', blockReason: 'regional-quota-shortfall',
    demand: { instances: 1, vcpus: 2, familyVcpus: 2, regionalVcpus: 12, regionalAdds: 2 },
    quota: { limit: 100, used: 0, regionalLimit: 20, regionalUsed: 16, name: 'Standard DASv5 Family vCPUs', checkedUtc: T1 } })] } });
  const r = page().planQuotaRows().find(x => x.regional);
  eq([r.short, r.shortBy], [true, 8], 'a request is not more quota');
});

test('RUN: only the newest check of a quota counts', () => {
  setWorld({ docs: { q1: [SHORT({ quota: { limit: 4, used: 4, name: 'Standard DASv5 Family vCPUs', checkedUtc: T0 } }), rec()] } });
  const r = page().planQuotaRows()[0];
  eq([r.limit, r.used, r.short], [10, 4, false], 'the older short reading does not count');
});

test('RUN: a missing figure is null, never 0 or a wrong shortfall', () => {
  setWorld({ docs: { q1: [rec({ quota: { limit: null, used: null, name: null, checkedUtc: T1 }, demand: { instances: 1, vcpus: 2, familyVcpus: null } })] } });
  const r = page().planQuotaRows().find(x => !x.regional);
  eq(r.quota, 'standardDASv5Family', 'no Azure name: the family');
  eq([r.limit, r.shortBy], [null, null]);
});

/* ---- each wave: one line for each quota ---- */

test('RUN: a wave whose quota is short says what it needs, by how much the plan is short, and where to go', () => {
  setWorld({ docs: { q1: [SHORT()] } });
  eq(UX.capLineShort, 'This wave needs {n} vCPUs of {quota} in {region}. The plan is short by {s}. See Request a quota increase.');
  eq(page().waveQuotaLines('q1'), [{ text: lineOf(UX.capLineShort, { n: 2, quota: 'Standard DASv5 Family vCPUs', region: 'centralus', s: 6 }), cls: 'bad' }]);
});

test('RUN: a wave whose quota is enough says what it needs and that the quota is enough for all waves', () => {
  setWorld({ docs: { q1: [rec(), rec({ size: 'Standard_D4as_v5', demand: { instances: 1, vcpus: 4, familyVcpus: 6, regionalAdds: 4 } })] } });
  eq(UX.capLineEnough, 'This wave needs {n} vCPUs of {quota} in {region}. The quota is enough for all waves.');
  eq(page().waveQuotaLines('q1'), [{ text: lineOf(UX.capLineEnough, { n: 6, quota: 'Standard DASv5 Family vCPUs', region: 'centralus' }), cls: 'good' }],
    'one line for the family, whatever the number of sizes: 2 + 4; no line for a region with room');
});

test('RUN: a wave short of the Total Regional vCPUs quota gets that line too', () => {
  setWorld({ docs: { q1: [SHORT({ regionalShort: true, quota: { limit: 10, used: 8, regionalLimit: 20, regionalUsed: 19, name: 'Standard DASv5 Family vCPUs', checkedUtc: T1 },
    demand: { instances: 1, vcpus: 2, familyVcpus: 8, regionalVcpus: 4, regionalAdds: 2 } })] } });
  eq(page().waveQuotaLines('q1').map(l => l.text), [
    lineOf(UX.capLineShort, { n: 2, quota: 'Standard DASv5 Family vCPUs', region: 'centralus', s: 6 }),
    lineOf(UX.capLineShort, { n: 2, quota: 'Total Regional vCPUs', region: 'centralus', s: 3 })], 'the family first');
});

test('RUN: a quota Azure does not list says so, and is neither short nor enough', () => {
  setWorld({ docs: { q1: [rec({ quota: { limit: null, used: null, name: 'Standard DDSv6 Family vCPUs', checkedUtc: T1 } })] } });
  eq(page().waveQuotaLines('q1'), [{ text: lineOf(UX.capLineUnlisted, { n: 2, quota: 'Standard DDSv6 Family vCPUs', region: 'centralus' }), cls: '' }]);
});

test('RUN: another wave\'s records are not this wave\'s lines', () => {
  setWorld({ docs: { q2: [SHORT({ wave: 'q2' })] } });
  eq(page().waveQuotaLines('q1'), []);
});

test('RUN: the sizes Azure refused stay on their wave: size, subscription by name, region, then what to do, once', () => {
  const refusedSay = (size, sub, region) => `The size ${size} is not available to subscription ${sub} in region ${region}.`;
  const doSay = 'Select Change target on the machine. Then choose another size.';
  setWorld({ docs: { q1: [rec({ state: 'BLOCKED', blockReason: 'sku-restricted', size: 'Standard_D4as_v5', region: 'eastus2' }), rec({ state: 'BLOCKED', blockReason: 'size-missing' })] } });
  eq(page().waveRefusedText('q1'), `${refusedSay('Standard_D2as_v5', 'Applications', 'centralus')} ${refusedSay('Standard_D4as_v5', 'Applications', 'eastus2')} ${doSay}`);
  setWorld({ docs: { q1: [rec({ state: 'BLOCKED', blockReason: 'sku-restricted', subscriptionId: '' })] } });
  eq(page().waveRefusedText('q1'), `The size Standard_D2as_v5 is not available in region centralus. ${doSay}`, 'a record with no subscription says no subscription');
  setWorld({ docs: { q2: [rec({ wave: 'q2', state: 'BLOCKED', blockReason: 'sku-restricted' })] } });
  eq(page().waveRefusedText('q1'), '', 'only on its own wave');
});

/* ---- the wave row ---- */

test('RUN: while a check runs, the wave shows the spinner and "The product checks the quota." - nothing old', () => {
  setWorld({ docs: { q1: [SHORT()] }, checking: ['q1'] });
  const html = page().quotaStateHtml('q1');
  eq(UX.capWaveChecking, 'The product checks the quota.');
  eq(html, `<span class="cap-answer working"><span class="spin"></span>${esc(UX.capWaveChecking)}</span>`);
});

test('RUN: the wave row: the refused sizes, then the lines, each in its color; no table, no button, no time', () => {
  setWorld({ docs: { q1: [SHORT(), rec({ state: 'BLOCKED', blockReason: 'size-missing', size: 'Standard_D8as_v5', vmFamily: null })] } });
  const html = page().quotaControl('q1');
  ok(html.includes('The size Standard_D8as_v5 is not available'), 'the refused size is on the row');
  ok(html.indexOf('The size Standard_D8as_v5') < html.indexOf('This wave needs'), html);
  ok(html.includes(`<span class="cap-answer bad">${esc(lineOf(UX.capLineShort, { n: 2, quota: 'Standard DASv5 Family vCPUs', region: 'centralus', s: 6 }))}</span>`), html);
  ok(!/<table|<button|data-ago|data-capcheck/.test(html), 'no table, no Check again, no time on the wave');
  ok(!/<label/.test(html), 'not a label');
  ok(!/claim\(s\)|BestEffort gate|\[BLOCKED\]/.test(html), 'no engine words');
});

test('RUN: with no records and no answer, the wave says "Not checked yet"', () => {
  setWorld();
  eq(page().quotaStateHtml('q1'), `<span class="cap-answer">${esc(UX.capNotChecked)}</span>`);
});

test('RUN: the answer of a check that is not about the figures is kept for its check, and gives way when the records change', () => {
  const said = UX.capUncoveredOne.replace('{machines}', 'app-2');
  const answers = new Map([['q1', { text: said, cls: 'bad', at: T1 }]]);
  setWorld({ docs: { q1: [rec()] }, answers });
  ok(page().quotaStateHtml('q1').includes(esc(said)), 'the answer of the check');
  setWorld({ docs: { q1: [rec({ quota: { ...rec().quota, checkedUtc: '2026-11-16T11:00:00.000Z' } })] }, answers });
  ok(!page().quotaStateHtml('q1').includes(esc(said)), 'a newer check: only its records speak');
  setWorld({ answers });
  eq(page().quotaStateHtml('q1'), `<span class="cap-answer">${esc(UX.capNotChecked)}</span>`, 'records cleared by a save: not the old answer');
});

/* ---- the time moves ---- */

test('RUN: the page updates each time span, and starts doing so once', () => {
  const tickAgo = lift('waves.html', 'tickAgo');
  const spans = [{ dataset: { ago: T1 }, textContent: 'old' }, { dataset: { ago: T0 }, textContent: 'old' }];
  globalThis.document = { querySelectorAll: (s) => (s === '[data-ago]' ? spans : []) };
  tickAgo();
  eq(spans.map(s => s.textContent), [`AGO(${T1})`, `AGO(${T0})`]);
  const src = require('./_page-source').pageSource(require('path').join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  eq((src.match(/setInterval\(tickAgo, 1000\)/g) || []).length, 1, 'one timer, every second, as the Migrations page');
});

/* ---- the card ---- */

function cardWorld(opts = {}) {
  setWorld(opts);
  Object.assign(globalThis, page(), { quotaAccess: new Map(), quotaShort: opts.short ?? false, regionalShortRegions: new Set(),
    quotaPlanState: lift('waves.html', 'quotaPlanState'), waveNames: () => opts.waves ?? Object.keys(opts.docs ?? {}), membersOf: () => [{}] });
  return lift('waves.html', 'quotaCardHtml');
}

test('RUN: the card header has the time of the newest check and Check the quota', () => {
  const card = cardWorld({ docs: { q1: [rec({ quota: { ...rec().quota, checkedUtc: T0 } })], q2: [rec({ wave: 'q2' })] } });
  const html = card();
  ok(html.includes(`<span class="hint">${esc(UX.capLast.split('{when}')[0])}<span data-ago="${T1}">AGO(${T1})</span></span>`), html);
  ok(/<button class="btn small ghost" id="q-check">Check the quota<\/button>/.test(html), html);
  eq(UX.capCheck, 'Check the quota');
});

test('RUN: a plan with a short quota: the danger sentence, the table with the short row first, the note, and Request an increase', () => {
  const card = cardWorld({ short: true, docs: { q1: [SHORT()], q2: [rec({ wave: 'q2', vmFamily: 'standardEASv5Family', quota: { ...rec().quota, name: 'Standard EASv5 Family vCPUs' } })] } });
  const html = card();
  eq(UX.capPlanShort, 'The quota is not enough for all waves of this plan.');
  ok(html.includes(`<p class="err-inline">${esc(UX.capPlanShort)}</p>`), html);
  const heads = [...html.matchAll(/<th[^>]*>([^<]*)<\/th>/g)].map(m => m[1]);
  eq(heads, ['Quota', 'Region', 'Limit', 'Usage', 'All waves need', 'Short by']);
  ok(/<tr class="short"><td>Standard DASv5 Family vCPUs<\/td><td>centralus<\/td><td class="num">10<\/td><td class="num">8<\/td><td class="num">8<\/td><td class="num">6<\/td><\/tr>/.test(html), html);
  ok(/<tr><td>Standard EASv5 Family vCPUs<\/td><td>centralus<\/td><td class="num">10<\/td><td class="num">4<\/td><td class="num">4<\/td><td class="num">Enough<\/td><\/tr>/.test(html), 'a row with room says Enough');
  ok(html.indexOf('Standard DASv5') < html.indexOf('Standard EASv5'), 'the short row first');
  eq(UX.capPlanWhy, 'All numbers are vCPUs. Each machine keeps its new size after its wave, so the check adds the vCPUs that all waves need.');
  ok(html.includes(esc(UX.capPlanWhy)), 'the note');
  ok(html.indexOf(esc(UX.capPlanWhy)) < html.indexOf('id="q-go"'), 'then the request');
});

test('RUN: a plan with enough quota: the success sentence, Enough in each row, and no Request an increase', () => {
  const card = cardWorld({ docs: { q1: [rec()] } });
  const html = card();
  eq(UX.capPlanEnough, 'The quota is enough for all waves of this plan.');
  ok(html.includes(`<p class="ok-inline">${esc(UX.capPlanEnough)}</p>`), html);
  ok(!html.includes('<tr class="short">') && !html.includes('id="q-go"'), html);
  eq((html.match(/>Enough<\/td>/g) || []).length, 2, 'the family and the region');
});

test('RUN: a plan with no check: the not-checked sentence, no table, no time', () => {
  const card = cardWorld();
  const html = card();
  eq(UX.quotaNotChecked, 'The product did not check the quota of this plan yet. Select Check the quota.');
  ok(html.includes(esc(UX.quotaNotChecked)) && !html.includes('<table') && !html.includes('data-ago'), html);
  ok(html.includes('id="q-check"'), 'and the button to check');
});

test('RUN: a row Azure does not list says Not listed, not Enough', () => {
  const card = cardWorld({ docs: { q1: [rec({ quota: { limit: null, used: null, regionalLimit: 100, regionalUsed: 20, name: 'Standard DDSv6 Family vCPUs', checkedUtc: T1 } })] }, unlisted: ['q1'] });
  ok(/<td>Standard DDSv6 Family vCPUs<\/td><td>centralus<\/td><td class="num">Not listed<\/td><td class="num">Not listed<\/td><td class="num">4<\/td><td class="num">Not listed<\/td>/.test(card()), card());
});

test('RUN: while any check runs, the card shows the spinner and offers nothing from a result, and its button is off', () => {
  const card = cardWorld({ short: true, docs: { q1: [SHORT()] }, checking: ['q1'] });
  const html = card();
  eq(UX.quotaCardChecking, 'The product checks the quota. The result shows here when the check is complete.');
  ok(html.includes(`<span class="spin"></span>${esc(UX.quotaCardChecking)}`), html);
  ok(!html.includes('id="q-go"') && !html.includes('<table') && !html.includes('data-ago'), 'no request, no table, no time');
  ok(/id="q-check"[^>]*disabled/.test(html), 'Check the quota cannot be pressed again');
  globalThis.checkingWaves = new Set();
  ok(card().includes('id="q-go"'), 'the request after');
});

test('RUN: drawing the card wires Check the quota and Request an increase', () => {
  const drawQuotaCard = lift('waves.html', 'drawQuotaCard');
  const wired = [];
  const node = (id) => ({ id, innerHTML: '', addEventListener: (t, f) => wired.push([id, t, f]) });
  const els = { '#quota': node('quota'), '#q-go': node('q-go'), '#q-check': node('q-check') };
  globalThis.$ = (s) => els[s];
  globalThis.quotaCardHtml = () => 'CARD';
  globalThis.openQuotaConfirm = function openQuotaConfirm() { };
  globalThis.checkPlan = function checkPlan() { };
  drawQuotaCard();
  ok(wired.some(w => w[0] === 'q-check' && w[1] === 'click' && w[2] === globalThis.checkPlan), 'Check the quota checks the plan');
  ok(wired.some(w => w[0] === 'q-go' && w[2] === globalThis.openQuotaConfirm));
});

/* ---- the card says only what is true of the whole plan (review) ---- */

test('RUN: after a check that failed on one wave, the card is not green: it names the wave with no result', () => {
  const card = cardWorld({ docs: { q1: [rec()] }, waves: ['q1', 'q2'],
    answers: new Map([['q2', { text: UX.capNoAnswer, cls: 'bad', at: null }]]) });
  const html = card();
  eq(UX.capPlanNoResult, 'The product has no quota result for these waves: {waves}. Select Check the quota again.');
  ok(html.includes(`<p class="err-inline">${esc(UX.capPlanNoResult.replace('{waves}', 'q2'))}</p>`), html);
  ok(!html.includes(esc(UX.capPlanEnough)), 'not green');
});

test('RUN: after a partial check (a wave with machines and no records), the card is not green', () => {
  const card = cardWorld({ docs: { q1: [rec()] }, waves: ['q1', 'q2', 'q3'] });
  const html = card();
  ok(html.includes(esc(UX.capPlanNoResult.replace('{waves}', 'q2, q3'))), html);
  ok(!html.includes(esc(UX.capPlanEnough)), 'not green');
});

test('RUN: a wave whose check found machines with no record is a wave with no result', () => {
  const card = cardWorld({ docs: { q1: [rec()], q2: [rec({ wave: 'q2' })] }, waves: ['q1', 'q2'],
    answers: new Map([['q2', { text: UX.capUncoveredOne.replace('{machines}', 'app-2'), cls: 'bad', at: T1 }]]) });
  ok(card().includes(esc(UX.capPlanNoResult.replace('{waves}', 'q2'))));
});

test('RUN: a wave in which no machine changes size is a result, so the plan can be green', () => {
  const card = cardWorld({ docs: { q1: [rec()] }, waves: ['q1', 'q2'], answers: new Map([['q2', { text: UX.capNothing, cls: '', at: null }]]) });
  ok(card().includes(`<p class="ok-inline">${esc(UX.capPlanEnough)}</p>`), card());
});

test('RUN: short and a wave with no result are both said', () => {
  const card = cardWorld({ short: true, docs: { q1: [SHORT()] }, waves: ['q1', 'q2'] });
  const html = card();
  ok(html.includes(esc(UX.capPlanShort)) && html.includes(esc(UX.capPlanNoResult.replace('{waves}', 'q2'))), html);
});

test('RUN: a quota with no figure is not green: the card says Azure does not list it, and the row says Not listed', () => {
  const card = cardWorld({ docs: { q1: [rec({ quota: { limit: null, used: null, regionalLimit: 100, regionalUsed: 20, name: 'Standard DDSv6 Family vCPUs', checkedUtc: T1 } })] } });
  const html = card();
  eq(UX.quotaUnlisted, 'Azure does not list the quota of some sizes of this plan. The product cannot check that quota before the wave starts.');
  ok(html.includes(`<p class="muted">${esc(UX.quotaUnlisted)}</p>`), html);
  ok(!html.includes(esc(UX.capPlanEnough)), 'not green');
});

test('RUN: a limit with a missing In use or All waves need figure says Not listed, not Enough', () => {
  const card = cardWorld({ docs: { q1: [rec({ quota: { ...rec().quota, used: null } })] } });
  const html = card();
  ok(/<td>Standard DASv5 Family vCPUs<\/td><td>centralus<\/td><td class="num">10<\/td><td class="num">Not listed<\/td><td class="num">4<\/td><td class="num">Not listed<\/td>/.test(html), html);
  ok(!html.includes(esc(UX.capPlanEnough)), 'and not green');
});

/* ---- overlapping reads (review) ---- */

function readWorld(docsFor) {
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  Object.assign(globalThis, { DEMO_MODE: false, runPrefix: () => 'p/mig-1', waveNoneReservable: () => false,
    VmfHelp: { ...require('./_held').perFileHelp(), mapLimited: async (l, fn) => Promise.all(l.map(fn)), claimBlocked: (s) => s === 'BLOCKED', claimReservingStuck: () => false, claimRegionalShort },
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false, quotaShort: false, unlistedWaves: new Set(),
    lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map(), claimsTurn: 0 });
  globalThis.blobList = async () => ['c0.json'];
  globalThis.blobFetch = async () => docsFor();
  return w;
}

test('RUN: two reads at once count each machine once in generalByWave', async () => {
  // 3 machines, 1 a reservation can hold: 2 move on general capacity.
  const doc = rec({ demand: { instances: 3, reservableInstances: 1, ownGroupVmIds: [], vcpus: 6, familyVcpus: 6, regionalVcpus: 6, regionalAdds: 6 } });
  const w = readWorld(() => doc);
  await Promise.all([w.loadClaims(), w.loadClaims()]);
  eq(globalThis.generalByWave.get('q1'), 2, 'not 4');
});

test('RUN: an older read that fails after a newer one succeeded does not wipe the newer result', async () => {
  let releaseOld;
  const oldGate = new Promise(r => { releaseOld = r; });
  let call = 0;
  const w = readWorld(() => rec());
  globalThis.blobList = async () => { call += 1; if (call === 1) { await oldGate; throw new Error('read failed'); } return ['c0.json']; };
  const older = w.loadClaims();
  await new Promise(r => setImmediate(r));
  ok(await w.loadClaims(), 'the newer read completes');
  eq(globalThis.waveDocs.get('q1'), [rec()], 'the newer records');
  releaseOld();
  eq(await older, false, 'the older read fails');
  eq(globalThis.waveDocs.get('q1'), [rec()], 'and the newer result stays');
  eq(globalThis.lastChecked.get('q1'), T1);
});

test('RUN: the newest read that fails empties the result, as one read alone does', async () => {
  const w = readWorld(() => rec());
  ok(await w.loadClaims());
  globalThis.blobList = async () => { throw new Error('read failed'); };
  eq(await w.loadClaims(), false);
  eq(globalThis.waveDocs.size, 0, 'a failed read keeps no records');
});

/* ---- one check for the plan ---- */

function planWorld({ unsaved = false, saveFails = false } = {}) {
  const calls = [];
  setWorld();
  const bar = () => ({ style: {}, textContent: '' });
  const els = { '#ok': bar(), '#err': bar() };
  Object.assign(globalThis, {
    DEMO_MODE: false, layout: new Map([['q1', {}], ['q2', {}], ['empty', {}]]),
    waveNames: () => ['q1', 'q2', 'empty'], membersOf: (n) => (n === 'empty' ? [] : [{}]),
    dirty: () => unsaved, writeLayout: async () => { calls.push(['SAVE']); if (saveFails) { throw new Error('HTTP 409'); } return {}; },
    checkCapacity: async (w) => { calls.push(['CHECK', w]); },
    drawQuotaRow: () => {}, drawQuotaCard: () => {},
    $: (s) => els[s],
  });
  globalThis.VmfHelp = { ...globalThis.VmfHelp, explainAction: (e) => e.message };
  return { calls, els };
}

test('RUN: Check the quota checks every wave that has machines, at once', async () => {
  const w = planWorld();
  await lift('waves.html', 'checkPlan')();
  eq(w.calls, [['CHECK', 'q1'], ['CHECK', 'q2']], 'a wave with no machine needs no check');
});

test('RUN: with changes not saved, the plan is saved once, first', async () => {
  const w = planWorld({ unsaved: true });
  await lift('waves.html', 'checkPlan')();
  eq(w.calls, [['SAVE'], ['CHECK', 'q1'], ['CHECK', 'q2']]);
  eq(w.els['#ok'].textContent, UX.capSavedFirst);
});

test('RUN: a save that fails says why, and checks nothing', async () => {
  const w = planWorld({ unsaved: true, saveFails: true });
  await lift('waves.html', 'checkPlan')();
  eq(w.calls, [['SAVE']]);
  eq(w.els['#err'].textContent, 'HTTP 409');
});

test('RUN: two checks at once where the older read is dropped: every row is drawn again from the newest records', async () => {
  const w = planWorld();
  // The DOM of the rows: drawQuotaRow writes each wave's row here.
  const rows = new Map();
  globalThis.document = { querySelector: (s) => { const m = /data-caprow="([^"]+)"/.exec(s); return m ? { set outerHTML(v) { rows.set(m[1], v); } } : null; } };
  Object.assign(globalThis, page(), { drawQuotaRow: lift('waves.html', 'drawQuotaRow'), drawQuotaCard: () => w.calls.push(['CARD']) });
  globalThis.capAnswers = new Map();
  // q1's check ends first and draws its row from the records it saw (none:
  // its read was dropped). q2's read is the newest, and it fills both waves.
  globalThis.checkCapacity = async (wave) => {
    if (wave === 'q1') { drawQuotaRow('q1'); return; }
    await new Promise(r => setImmediate(r));
    globalThis.waveDocs = new Map([['q1', [rec()]], ['q2', [rec({ wave: 'q2' })]]]);
    globalThis.lastChecked = new Map([['q1', T1], ['q2', T1]]);
    drawQuotaRow('q2');
  };
  await lift('waves.html', 'checkPlan')();
  const line = esc(lineOf(UX.capLineEnough, { n: 2, quota: 'Standard DASv5 Family vCPUs', region: 'centralus' }));
  ok(rows.get('q1').includes(line), `the first wave shows its line, not "Not checked yet": ${rows.get('q1')}`);
  ok(rows.get('q2').includes(line), 'and the second');
  ok(w.calls.some(c => c[0] === 'CARD'), 'and the card is drawn again');
});

test('RUN: a press while a check runs starts nothing', async () => {
  const w = planWorld();
  globalThis.checkingWaves = new Set(['q1']);
  await lift('waves.html', 'checkPlan')();
  eq(w.calls, []);
});

/* ---- one wave's check ---- */

function pressWorld({ gate = { Pass: false, Detail: '1 claim(s) below the BestEffort gate: Standard_D2as_v5@centralus [BLOCKED]' }, watch = { done: { detail: 'claims=1 blocked=1 wave=q1' } } } = {}) {
  const calls = [];
  setWorld();
  Object.assign(globalThis, {
    DEMO_MODE: false, layout: new Map(),
    runSeg: () => 'mig-1', runQuery: () => '', runBody: (b) => b,
    apiPost: async (p) => { calls.push(['POST', p, [...checkingWaves]]); return {}; },
    apiGet: async (p) => { calls.push(['GET', p]); return gate; },
    loadClaims: async () => { calls.push(['LOAD']); globalThis.lastChecked = new Map([['q1', T1]]); return true; },
    watchQuotaCheck: async () => watch,
    drawQuotaRow: (w) => calls.push(['ROW', w, checkingWaves.has(w)]),
    drawQuotaCard: () => calls.push(['CARD', checkingWaves.size]),
    uncoveredText: (l) => ([].concat(l ?? []).length ? UX.capUncoveredOne.replace('{machines}', 'app-2') : ''),
    $: () => ({ style: {}, textContent: '' }),
  });
  globalThis.VmfHelp = { ...globalThis.VmfHelp, explainAction: (e) => e.message, explain: (e) => e.message };
  return calls;
}

test('RUN: a wave\'s check draws its row and the card in their checking state before the engine is asked', async () => {
  const calls = pressWorld();
  await lift('waves.html', 'checkCapacity')('q1');
  const firstRow = calls.findIndex(c => c[0] === 'ROW');
  ok(calls[firstRow][2] === true, 'drawn as checking');
  ok(firstRow < calls.findIndex(c => c[0] === 'POST'), 'before the post');
  ok(calls.some(c => c[0] === 'CARD' && c[1] === 1), 'and the card too');
  eq(calls.find(c => c[0] === 'POST')[2], ['q1'], 'the wave is checking while the engine works');
});

test('RUN: after a check that is about the figures, no answer is kept: the lines say it', async () => {
  const calls = pressWorld();
  await lift('waves.html', 'checkCapacity')('q1');
  eq(checkingWaves.size, 0);
  eq(calls.filter(c => c[0] === 'ROW').pop()[2], false, 'drawn after the check');
  eq(capAnswers.has('q1'), false, 'short or enough is said by the lines, from the records');
  ok(calls.filter(c => c[0] === 'CARD').pop()[1] === 0, 'the card drawn after too');
  pressWorld({ gate: { Pass: true, Detail: 'all 1 claims satisfy BestEffort' } });
  await lift('waves.html', 'checkCapacity')('q1');
  eq(capAnswers.has('q1'), false, 'a pass too');
});

test('RUN: a check with machines that have no record keeps that answer, for its check', async () => {
  pressWorld({ gate: { Pass: false, Detail: 'x', Uncovered: [{ Name: 'app-2' }] } });
  await lift('waves.html', 'checkCapacity')('q1');
  eq(capAnswers.get('q1'), { text: UX.capUncoveredOne.replace('{machines}', 'app-2'), cls: 'bad', at: T1 });
});

test('RUN: a check that fails still ends the checking state, and keeps its error', async () => {
  pressWorld({ watch: null });
  await lift('waves.html', 'checkCapacity')('q1');
  eq(checkingWaves.size, 0);
  eq(capAnswers.get('q1').text, UX.capNoAnswer);
  eq(capAnswers.get('q1').cls, 'bad');
});

test('RUN: "no machine changes size" is kept, and shown', async () => {
  pressWorld({ watch: { done: { detail: 'claims=0 blocked=0 wave=q1 machines=0 moving=0' } } });
  await lift('waves.html', 'checkCapacity')('q1');
  eq(capAnswers.get('q1').text, UX.capNothing);
  ok(page().quotaStateHtml('q1').includes(esc(UX.capNothing)));
});

test('RUN: a wave\'s check does not save: the plan check saves once, before all of them', async () => {
  const calls = pressWorld();
  globalThis.dirty = () => true;
  globalThis.writeLayout = async () => { calls.push(['SAVE']); return {}; };
  await lift('waves.html', 'checkCapacity')('q1');
  ok(!calls.some(c => c[0] === 'SAVE'), 'two wave checks at once would write the plan twice');
});

/* ---- the records ---- */

test('RUN: the page keeps each wave\'s records as it reads them, and a failed read keeps none', async () => {
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  const docs = [SHORT(), rec({ wave: 'q2' })];
  Object.assign(globalThis, { DEMO_MODE: false, runPrefix: () => 'p/mig-1', waveNoneReservable: () => false,
    blobList: async () => ['c0.json', 'c1.json'], blobFetch: async (n) => docs[n.endsWith('c0.json') ? 0 : 1],
    VmfHelp: { ...require('./_held').perFileHelp(), mapLimited: async (l, fn) => Promise.all(l.map(fn)), claimBlocked: (s) => s === 'BLOCKED', claimReservingStuck: () => false, claimRegionalShort },
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false, quotaShort: false, unlistedWaves: new Set(),
    lastChecked: new Map(), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: new Map() });
  ok(await w.loadClaims(), 'the records are read');
  eq(globalThis.waveDocs.get('q1'), [docs[0]], 'wave q1 has its record');
  eq(globalThis.waveDocs.get('q2'), [docs[1]], 'and q2 its own');
  globalThis.blobList = async () => { throw new Error('read failed'); };
  await w.loadClaims();
  eq(globalThis.waveDocs.size, 0, 'an earlier read does not stand after a failed read');
  // A read that fails part of the way keeps none either: the row would show half a wave.
  globalThis.blobList = async () => ['c0.json', 'c1.json'];
  globalThis.VmfHelp.claimReservingStuck = (d) => { if (d.wave === 'q2') { throw new Error('bad record'); } return false; };
  eq(await w.loadClaims(), false, 'the read fails on the second record');
  eq(globalThis.waveDocs.size, 0, 'and the first record is not kept');
});

test('RUN: while a read waits, the rows keep the records and times they had, so a second check does not blank them', async () => {
  const w = liftAll('waves.html', ['loadClaims', 'heldOrFetch', 'claimCount', 'quotaAccessFrom']);
  const before = new Map([['q1', [SHORT({ quota: { ...SHORT().quota, checkedUtc: T0 } })]]]);
  let release;
  const gate = new Promise(r => { release = r; });
  Object.assign(globalThis, { DEMO_MODE: false, runPrefix: () => 'p/mig-1', waveNoneReservable: () => false,
    blobList: async () => { await gate; return ['c0.json']; }, blobFetch: async () => rec(),
    VmfHelp: { ...require('./_held').perFileHelp(), mapLimited: async (l, fn) => Promise.all(l.map(fn)), claimBlocked: (s) => s === 'BLOCKED', claimReservingStuck: () => false, claimRegionalShort },
    claims: new Map(), billingWaves: new Set(), generalByWave: new Map(), quotaChecked: false, quotaShort: false, unlistedWaves: new Set(),
    lastChecked: new Map([['q1', T0]]), regionalShortWaves: new Set(), regionalShortRegions: new Set(), quotaAccess: new Map(), waveDocs: before });
  const reading = w.loadClaims();
  await new Promise(r => setImmediate(r));
  eq(globalThis.waveDocs, before, 'the records stay while the read waits');
  eq(globalThis.lastChecked.get('q1'), T0, 'and so does the time');
  release();
  ok(await reading, 'the read completes');
  eq(globalThis.waveDocs.get('q1'), [rec()], 'then the new records replace them');
  eq(globalThis.lastChecked.get('q1'), T1, 'and the new time');
  globalThis.blobList = async () => { throw new Error('read failed'); };
  await w.loadClaims();
  eq(globalThis.lastChecked.size, 0, 'a failed read keeps no time, so no time shows with no records');
});

/* ---- the confirmation ---- */

const ROWS = [
  { family: 'standardDASv5Family', quotaName: 'Standard DASv5 Family vCPUs', subscriptionId: SUB, region: 'centralus',
    usage: 8, currentLimit: 10, requestedLimit: 12, free: 2, access: 'granted', status: 'WHATIF', waves: [{ wave: 'q1', vcpus: 4 }] },
];

function dialog(c) {
  globalThis.UX = UX;
  globalThis.subName = () => 'Applications';
  globalThis.quotaResultLines = lift('waves.html', 'quotaResultLines');
  globalThis.quotaRequestStateText = lift('waves.html', 'quotaRequestStateText');
  // QUOTA-REQUEST-POLL-1: the answers of Azure under the table.
  for (const n of ['quotaAnswerLines', 'quotaUnanswered', 'quotaAnswerKey', 'quotaAnswerLineHtml']) { globalThis[n] = lift('waves.html', n); }
  globalThis.QUOTA_HELP = liftConst('waves.html', 'QUOTA_HELP');
  globalThis.VmfHelp = { explain: (e) => e.message, isLearnLink: lift('help.js', 'isLearnLink') };
  return lift('waves.html', 'quotaConfirmHtml')(c);
}

test('RUN: while it reads, the confirmation shows the spinner and says what it reads and how long', () => {
  const html = dialog({ phase: 'wait' });
  ok(html.includes(`<span class="spin"></span>${esc(UX.quotaConfirmWait)}`), html);
  eq(UX.quotaConfirmWait, 'The product reads the last quota check and calculates the new limits. This step can take up to 1 minute.');
});

test('RUN: the table has a column for what the waves need, and plain sentences under each quota', () => {
  const html = dialog({ phase: 'ready', rows: ROWS });
  const heads = [...html.matchAll(/<th[^>]*>([^<]*)<\/th>/g)].map(m => m[1]);
  eq(heads, [UX.quotaColQuota, UX.quotaColRegion, UX.quotaColUsed, UX.quotaColLimit, UX.quotaColNeed, UX.quotaColNew]);
  eq(heads, ['Quota', 'Region', 'Usage', 'Current limit', 'The waves need', 'New limit']);
  ok(/<td>Standard DASv5 Family vCPUs<\/td><td>centralus<\/td><td class="num">8<\/td><td class="num">10<\/td><td class="num">4<\/td><td class="num">12<\/td>/.test(html), html);
  ok(html.includes(esc('Wave q1 needs 4 vCPUs of Standard DASv5 Family vCPUs in centralus.')), html);
  ok(html.includes(esc('2 vCPUs of this quota are free now.')), html);
  ok(html.includes(esc('The product requests a new limit of 12 vCPUs.')), html);
});

test('RUN: the waves column adds every wave of the quota; a missing figure says so', () => {
  const html = dialog({ phase: 'ready', rows: [{ ...ROWS[0], free: null, requestedLimit: null, waves: [{ wave: 'q1', vcpus: 4 }, { wave: 'q2', vcpus: 6 }] }] });
  ok(/<td class="num">10<\/td><td class="num">10<\/td><td class="num">Not listed<\/td>/.test(html), 'limit 10, the waves need 4 + 6 = 10, new limit not listed');
  ok(!html.includes('are free now') && !html.includes('new limit of'), 'no sentence with a figure the engine did not give');
});

test('RUN: the title is a question only before Request', () => {
  const title = (c) => dialog(c).match(/<h3 id="q-m-title">([^<]*)<\/h3>/)[1];
  eq(title({ phase: 'wait' }), UX.quotaConfirmTitle);
  eq(title({ phase: 'ready', rows: ROWS }), UX.quotaConfirmTitle);
  eq(title({ phase: 'error', error: 'x' }), UX.quotaConfirmTitle);
  eq(title({ phase: 'sending' }), UX.quotaSentTitle);
  eq(title({ phase: 'done', rows: [] }), UX.quotaSentTitle);
  eq(title({ phase: 'error', error: 'x', sent: true }), UX.quotaSentTitle, 'a failure after Request is not a question either');
  ok(!UX.quotaSentTitle.endsWith('?'));
});

test('RUN: while it sends, the spinner and what happens', () => {
  const html = dialog({ phase: 'sending' });
  ok(html.includes(`<span class="spin"></span>${esc(UX.quotaSending)}`), html);
});

test('RUN: after Request, a table of each request: quota, region, new limit, state, request ID', () => {
  const filed = { family: 'standardDASv5Family', quotaName: 'Standard DASv5 Family vCPUs', subscriptionId: SUB, region: 'centralus',
    requestedLimit: 12, status: 'PENDING', reason: null,
    requestId: '/subscriptions/00000000-0000-0000-0000-000000000000/providers/Microsoft.Quota/quotaRequests/00000000-0000-0000-0000-0000000000aa' };
  const approved = { ...filed, quotaName: 'Total Regional vCPUs', status: 'APPROVED', requestId: null };
  const refused = { ...filed, quotaName: 'Standard FSv2 Family vCPUs', status: 'FAILED', requestId: null, reason: 'Azure answered HTTP 400.' };
  const html = dialog({ phase: 'done', rows: [filed, approved, refused] });
  const heads = [...html.matchAll(/<th[^>]*>([^<]*)<\/th>/g)].map(m => m[1]);
  eq(heads, ['Quota', 'Region', 'New limit', 'State', 'Request ID']);
  ok(html.includes(`<td>Standard DASv5 Family vCPUs</td><td>centralus</td><td class="num">12</td><td>${esc(UX.quotaStateFiled)}</td><td class="mono q-id">00000000-0000-0000-0000-0000000000aa</td>`), html);
  eq(UX.quotaStateFiled, 'The product filed the request. Azure did not answer yet.');
  ok(html.includes(`<td>${esc(UX.quotaStateApproved)}</td><td class="mono q-id">${esc(UX.quotaNoId)}</td>`), html);
  ok(html.includes(`<td>${esc(UX.quotaStateNotFiled)}</td>`), html);
  ok(html.includes('Azure answered HTTP 400.'), 'the reason of a quota not filed is still said');
  ok(html.includes(esc(UX.quotaDoneNext)), 'and what to do next');
});

test('RUN: the state of a request comes from one function, the place an answer from Azure goes', () => {
  globalThis.UX = UX;
  const quotaRequestStateText = lift('waves.html', 'quotaRequestStateText');
  eq(quotaRequestStateText({ status: 'PENDING' }), UX.quotaStateFiled);
  eq(quotaRequestStateText({ status: 'APPROVED' }), UX.quotaStateApproved);
  eq(quotaRequestStateText({ status: 'FAILED' }), UX.quotaStateNotFiled);
  eq(quotaRequestStateText({ status: 'NOACCESS' }), UX.quotaStateNotFiled);
});

test('RUN: a failure after Request is kept as sent, so its title is not a question', async () => {
  const sendQuotaRequest = lift('waves.html', 'sendQuotaRequest');
  Object.assign(globalThis, { UX, quotaConfirm: { phase: 'ready', rows: [] }, quotaConfirmTurn: 1,
    $: () => ({ style: {}, textContent: '', disabled: false }), runSeg: () => 'mig-1', runBody: (b) => b,
    apiPost: async () => { throw new Error('HTTP 500'); }, drawQuotaConfirm: () => {},
    loadClaims: async () => true, drawEditorWhenFree: () => {} });
  globalThis.VmfHelp = { explainAction: (e) => e.message, explain: (e) => e.message };
  await sendQuotaRequest();
  eq(globalThis.quotaConfirm, { phase: 'error', error: 'HTTP 500', sent: true });
});

run('quota-check-spinner');
