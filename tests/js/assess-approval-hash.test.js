/* ASSESS-APPROVAL-HASH-1: an assessment approval names the scan the person
 * read, by the version the service issued for it (PLANVER-2).
 *
 * Before this, both pages that approve an assessment (the Assessments page's
 * report and the wizard's review step) sent only a note, and the approval
 * recorded the hash of whatever assessment.json held when the request
 * landed. Planning never compared it. The service now refuses an approval
 * without the version, or with another one (409), and planning holds to the
 * scan an approval names.
 *
 * The pages read their documents in one call that gives no version
 * (VmfHelp.storeDocs). So each page reads assessment.json again, WITH the
 * version, while nobody has approved it, draws the findings from that text,
 * and sends that version with the approval. RUN, not read: the page's own
 * functions are driven here.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const ASSESS = pageSource(path.join(REPO, 'src', 'dashboard', 'assessments.html'));
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));

/* ---- the Assessments page ------------------------------------------------ */

function reportWorld(row) {
  const calls = [];
  const note = { value: 'typed while it read' };
  Object.assign(globalThis, {
    DEMO_MODE: false, cfg: { apiUrl: 'https://api.example.com' }, getToken: async () => 't',
    rows: [row], openReportId: row.id,
    openReport: (id, redraw) => { calls.push(redraw ? ['open', id, true] : ['open', id]); note.value = ''; return true; },
    document: { getElementById: (id) => (id === 'approve-note' ? note : null) },
    $: () => ({ style: {}, textContent: '' }),
  });
  return { calls, note };
}

test('the report of an assessment nobody approved reads the scan again with its version, and draws it again from that text', async () => {
  const { loadReportVersion } = liftAll('assessments.html', ['loadReportVersion']);
  const row = { id: 'p/a1', approval: null, vms: [{ vmId: 'old' }], machines: 1, notRead: [] };
  const w = reportWorld(row);
  const asked = [];
  globalThis.VmfHelp = { storeBlob: async (getToken, api, p, opts) => {
    asked.push([p, opts]);
    return { text: JSON.stringify({ vms: [{ vmId: 'x' }, { vmId: 'y' }], notRead: ['sub-1'] }), version: 'v-scan' };
  } };
  await loadReportVersion('p/a1');
  eq(asked, [['p/a1/assessment.json', { asVersioned: true }]], 'one read, with the version the service issued');
  eq([row.version, row.vms.map(v => v.vmId), row.machines, row.notRead], ['v-scan', ['x', 'y'], 2, ['sub-1']], 'the row holds that scan');
  eq(w.calls, [['open', 'p/a1', true]], 'the report is drawn again from it, as a redraw');
  eq(w.note.value, 'typed while it read', 'the note typed meanwhile is kept');
});

test('a report closed meanwhile, or approved meanwhile, is not drawn again; a read that fails says so and keeps Approve off', async () => {
  const { loadReportVersion } = liftAll('assessments.html', ['loadReportVersion']);
  globalThis.VmfHelp = { storeBlob: async () => ({ text: '{"vms":[]}', version: 'v2' }), explainAction: (e) => 'said: ' + e.message };
  let row = { id: 'p/a1', approval: null, vms: [] };
  let w = reportWorld(row);
  globalThis.openReportId = null;
  await loadReportVersion('p/a1');
  eq([row.version, w.calls], ['v2', []], 'closed: kept, not drawn');
  row = { id: 'p/a1', approval: { approvedUtc: 'x' }, vms: [] };
  w = reportWorld(row);
  await loadReportVersion('p/a1');
  eq(w.calls, [], 'approved meanwhile: the report already says Reviewed');
  row = { id: 'p/a1', approval: null, vms: [] };
  w = reportWorld(row);
  const err = { style: {}, textContent: '' };
  globalThis.$ = () => err;
  globalThis.VmfHelp.storeBlob = async () => { throw new Error('read refused'); };
  await loadReportVersion('p/a1');
  eq([row.version, row.versionFailed, w.calls, err.textContent, err.style.display],
    [undefined, true, [['open', 'p/a1', true]], 'said: read refused', 'block'], 'drawn again, with the reason, and no second read');
  row = { id: 'p/a1', approval: null, vms: [] };
  w = reportWorld(row);
  globalThis.VmfHelp.storeBlob = async () => ({ text: '{"vms":[]}', version: '' });
  await loadReportVersion('p/a1');
  eq([row.version, row.versionFailed], [undefined, true], 'a document with no version is a failed read');
});

test('the reason I have reviewed this is off is beside it: while the scan is read, and after the read failed', () => {
  const { approveWhy } = liftAll('assessments.html', ['approveWhy']);
  globalThis.esc = (v) => String(v);
  globalThis.UX = { reviewReading: 'reading', reviewReadFailed: 'failed' };
  globalThis.DEMO_MODE = false;
  ok(approveWhy({}).includes('id="approve-why"') && approveWhy({}).includes('>reading<'), 'while it reads');
  ok(approveWhy({ versionFailed: true }).includes('>failed<'), 'after a failed read');
  eq(approveWhy({ version: 'v' }), '', 'on: no reason');
  globalThis.DEMO_MODE = true;
  eq(approveWhy({}), '', 'the demo');
  globalThis.DEMO_MODE = false;
  ok(/\$\{esc\(UX\.reviewBtn\)\}<\/button>\$\{approveWhy\(row\)\}/.test(ASSESS), 'reportHtml draws it beside the button');
});

test('a person who opens the report reads again after a failed read; the redraw after the read does not read', () => {
  const { openReport } = liftAll('assessments.html', ['openReport']);
  const asked = [];
  const row = { id: 'p/a1', approval: null, versionFailed: true };
  Object.assign(globalThis, { rows: [row], DEMO_MODE: false, openReportId: null, openReportVersion: '',
    reportHtml: () => '', loadReportVersion: (id) => asked.push(id), reportClosed: () => {},
    window: { VmfReport: { closePanel() {}, openPanel: () => ({ querySelector: () => null }) } } });
  openReport('p/a1', true);
  eq([asked, row.versionFailed], [[], true], 'the redraw: no read, the reason stays');
  openReport('p/a1');
  eq([asked, row.versionFailed], [['p/a1'], false], 'a person opens it: read again');
  row.version = 'v-scan';
  openReport('p/a1', true);
  eq(globalThis.openReportVersion, 'v-scan', 'the panel holds the version of what it shows');
});

test('Clear up old scans makes new rows; the approval still quotes the version of the scan the open panel shows', async () => {
  const { approve } = liftAll('assessments.html', ['approve']);
  const sent = [];
  Object.assign(globalThis, {
    document: { getElementById: () => ({ value: '' }) }, openReportId: 'p/a1', openReportVersion: 'v-shown',
    rows: [{ id: 'p/a1', approval: null }],    // the reload's new row, with no version
    api: async (m, route, body) => { sent.push(body.assessmentHash); return {}; },
    loadAssessments: async () => {}, renderTable: () => {}, openReport: () => true,
    VmfHelp: { VmfRun: { routeSegment: (id) => id.split('/').pop(), withProject: (b) => b } },
  });
  await approve('p/a1', { textContent: 'x', disabled: false });
  eq(sent, ['v-shown']);
});

test('Approve is off in the report until the version is read, and the version goes with the approval', () => {
  // The markup of the button, as reportHtml writes it.
  const m = ASSESS.match(/<button type="button" class="btn" data-approve="\$\{esc\(row\.id\)\}"\$\{([^}]*)\}>/);
  ok(m, 'the button');
  // eslint-disable-next-line no-eval
  const attr = (row, demo) => eval(`(function (row, DEMO_MODE) { return ${m[1]}; })`)(row, demo);
  eq(attr({}, false), ' disabled', 'no version yet');
  eq(attr({ version: 'v' }, false), '', 'the version is read');
  eq(attr({}, true), '', 'the demo has nothing to read');
  ok(/if \(!redraw && !data\.approval && !data\.version && !DEMO_MODE\) \{ loadReportVersion\(id\); \}/.test(ASSESS), 'openReport asks for it');
});

/* ---- the wizard's review step --------------------------------------------- */

test('the review step reads an assessment nobody approved again with its version, and shows that text', async () => {
  const { reviewedScan } = liftAll('wizard.html', ['reviewedScan']);
  const asked = [];
  globalThis.readVersionedDoc = async (p) => { asked.push(p); return { doc: { vms: ['read again'] }, version: 'v-scan' }; };
  const held = { vms: ['one call'] };
  eq(await reviewedScan(true, null, held, 'p/a1/assessment.json'), { doc: { vms: ['read again'] }, version: 'v-scan' });
  eq(asked, ['p/a1/assessment.json']);
  asked.length = 0;
  eq(await reviewedScan(true, { approvedUtc: 'x' }, held, 'p/a1/assessment.json'), { doc: held, version: '' }, 'approved: no read');
  eq(await reviewedScan(false, null, held, 'p/m1/assessment.json'), { doc: held, version: '' }, 'a migration: no read');
  eq(await reviewedScan(true, null, null, 'p/a1/assessment.json'), { doc: null, version: '' }, 'no scan yet: no read');
  eq(asked, [], 'none of the three reads anything');
  globalThis.readVersionedDoc = async () => null;
  eq(await reviewedScan(true, null, held, 'p/a1/assessment.json'), { doc: held, version: '' }, 'a read that fails keeps the one call\'s copy, with no version');
});

test('the review step offers no I have reviewed this without the version, and says why', () => {
  const { reviewAction, roleAction } = liftAll('wizard.html', ['reviewAction', 'roleAction']);
  globalThis.roleAction = roleAction;
  globalThis.esc = (v) => String(v);
  globalThis.UX = { aReviewBtn: 'I have reviewed this', aReviewNoVersion: 'no version', reviewNeedsApprover: 'needs approver' };
  ok(reviewAction(true, 'v').includes('<button class="btn" id="rev">'), 'an approver, with the version');
  eq(reviewAction(true, ''), '<span class="muted" id="rev-why">no version</span>', 'the read failed: the reason');
  eq(reviewAction(false, 'v'), '<span class="muted" id="rev-why">needs approver</span>', 'no approver role');
  ok(WIZ.includes('${reviewAction(canApprove, assessmentVersion)}'), 'the step draws it');
});

test('the wizard reads the run with it, and its approval sends that version', () => {
  ok(WIZ.includes('reviewedScan(onAssessment, appr, asmt, `${pre}/assessment.json`),'), 'readRun asks for it');
  ok(WIZ.includes('assessment = rv.doc; assessmentVersion = rv.version;'), 'and shows that text');
  ok(WIZ.includes('runBody({ note, assessmentHash: assessmentVersion })'), 'the approval sends it');
});

run('assess-approval-hash');
