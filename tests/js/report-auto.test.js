/* REPORT-AUTO-1: the report is written by itself, one kind, and the person's
 * theme is honoured in what they download.
 *
 * Decided 2026-10-02:
 *   - no "Produce the report" button and no "Who is it for?" dialog - the
 *     engine writes the report when a wave finishes and when a machine is
 *     restored or rebuilt;
 *   - no "Download the data" - it was the same record, as data;
 *   - "Download the record" stays, for administrators only, marked with the
 *     theme the person sees when they save it;
 *   - every fact the old appendix held is in the record (v3), and the
 *     downloaded record shows it, through the report's stylesheet only.
 *
 * RUN, not read: the pages' own functions, lifted.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// DISCLAIMER-1: the record ends with the short line, which the page reads from
// help.js (VmfHelp.disclaimerLine). tests/js/disclaimer.test.js holds the words.
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { disclaimerLine: 'The short line.' });

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const MIGRATIONS = pageSource(path.join(DASH, 'migrations.html'));
const REPORTS = pageSource(path.join(DASH, 'reports.html'));

/* Code only - a name in a comment that explains why it went is not the thing
 * itself (CLAUDE.md, "a test that reads a whole file matches its own
 * comments"). Strings stay: a route or a label is in a string. */
function codeOnly(text) {
  let out = '', i = 0, quote = null;
  while (i < text.length) {
    const c = text[i], n = text[i + 1];
    if (quote) {
      out += c;
      if (c === '\\') { out += n ?? ''; i += 2; continue; }
      if (c === quote) { quote = null; }
      i++; continue;
    }
    if (c === '/' && n === '*') { const end = text.indexOf('*/', i + 2); i = end < 0 ? text.length : end + 2; continue; }
    if (c === '/' && n === '/' && text[i - 1] !== ':' && text[i - 1] !== '\\') { const end = text.indexOf('\n', i); i = end < 0 ? text.length : end; continue; }
    if (c === '<' && text.startsWith('<!--', i)) { const end = text.indexOf('-->', i + 4); i = end < 0 ? text.length : end + 3; continue; }
    if (c === '\'' || c === '"' || c === '`') { quote = c; }
    out += c; i++;
  }
  return out;
}
const MIG_CODE = codeOnly(MIGRATIONS);
const REP_CODE = codeOnly(REPORTS);

// ---------- the Migrations page: no button, no dialog, no route ----------

const UX_ACT = liftConst('migrations.html', 'UX_ACT');

test('THE POINT: the Migrations page has no report button, no dialog and no words for them', () => {
  for (const k of ['reportBtn', 'reportTitle', 'reportDesc', 'reportForWhom', 'reportOps', 'reportCust', 'reportSignOff', 'reportDone']) {
    ok(!(k in UX_ACT), `UX_ACT.${k} is gone`);
  }
  ok(!/function askReport\b/.test(MIG_CODE), 'no dialog to open');
  ok(!/report-btn/.test(MIG_CODE), 'no button');
  ok(!/engine\/report/.test(MIG_CODE), 'no route from the page to a report operation');
  ok(!/reportAudience|signOffNote/.test(MIG_CODE), 'nothing the dialog sent');
  ok(!/Who is it for|Our own record|Produce the report/i.test(MIG_CODE), 'no sentence of it anywhere in the page');
});

const actionsPage = liftAll('migrations.html', ['renderRunActions']);
function drawActions({ operator = true, approver = false, working = false, acked = true }) {
  const host = { innerHTML: '' };
  globalThis.$ = (sel) => (sel === '#run-actions' ? host : { addEventListener: () => {} });
  globalThis.UX_ACT = UX_ACT;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.currentRun = 'estate/migration-1';
  globalThis.canOperate = () => operator;
  globalThis.canApprove = () => approver;
  globalThis.runIsWorking = () => working;
  globalThis.runAcknowledged = () => acked;
  globalThis.askStopRun = () => {};
  globalThis.askDiscardRun = () => {};
  globalThis.askAcknowledge = () => {};
  // DISCARD-ENGINE-1: the row also reads whether a delete is running.
  globalThis.discardInFlight = null;
  globalThis.ago = () => '';
  try { actionsPage.renderRunActions(); } finally { globalThis.esc = escHtml; }
  return host.innerHTML;
}

test('DRAWN: the run actions an operator sees carry no report button', () => {
  const html = drawActions({});
  ok(!/report/i.test(html), html);
  ok(html.includes(UX_ACT.discardRun), 'the other run actions are still there');
});

test('DRAWN: an approver with nothing to press is shown no empty row', () => {
  // The report button was the one thing on this row for an approver. With it
  // gone, the row has nothing for them, so nothing is drawn.
  eq(drawActions({ operator: false, approver: true }), '', 'no row');
});

test('the activity line for a report the engine could not write says what it says', () => {
  const stepText = lift('migrations.html', 'stepText');
  // The page's own tables, read as written.
  globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
  globalThis.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
  globalThis.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');
  globalThis.UX_STATE = {}; globalThis.UX_STATE_DONE = {};
  const why = 'The report could not be written after this wave: the store refused it. The next wave or restore writes it again.';
  eq(stepText({ step: 'report', outcome: 'warn', detail: why }), why, 'the warning is the line');
  eq(stepText({ step: 'record', outcome: 'warn', detail: 'The migration record could not be written.' }), 'The migration record could not be written.', 'and the record warning too');
  eq(stepText({ step: 'report', outcome: 'ok', detail: 'azblob://acct/runs/mig-1/customer-report.html' }), UX_STEP.reportStep, 'a report that was written uses the plain label, not the file name');
  // REPORT-RECORD-LINE-1: keeping the record leaves an ok line too, whose detail is its address.
  eq(stepText({ step: 'record', outcome: 'ok', detail: 'https://acct.blob.core.windows.net/vmf-runs/vmf-records/estate--mig-1.json' }), UX_STEP.recordStep, 'a record that was kept uses the plain label, not its storage address');
  eq(stepText({ step: 'record', outcome: 'ok' }), UX_STEP.recordStep, 'and with no detail');
});

// ---------- the Reports page: one download, administrators only ----------

globalThis.UX = liftConst('reports.html', 'UX');
const escHtml = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
// The page's own escaping. drawActions above swaps in a plain one and puts this back.
globalThis.esc = escHtml;

test('THE POINT: "Download the data" is gone - its words, its button and its file', () => {
  ok(!('recData' in UX), 'no words for it');
  ok(!/Download the data/.test(REP_CODE), 'not in the page');
  ok(!/recordFileName\(rec, 'json'\)|JSON\.stringify\(rec\b/.test(REP_CODE), 'no data file is saved');
  ok(!/kind === 'data'|data-kind/.test(REP_CODE), 'no second kind of download');
});

test('DRAWN: one button, "Download the record"', () => {
  const recordButton = lift('reports.html', 'recordButton');
  const html = recordButton('data-record', 'estate/mig-1');
  eq((html.match(/<button/g) || []).length, 1, 'one button');
  ok(html.includes(UX.recRead), 'Download the record');
  ok(html.includes('data-record="estate/mig-1"'), 'for that migration');
});

test('"Download the record" is still offered to administrators only', () => {
  ok(/\$\{isAdmin \? recordButton\('data-record', run\) : ''\}/.test(REP_CODE), 'the run detail offers it to an administrator only');
  ok(/if \(!isAdmin\) \{ return \[\]; \}/.test(REP_CODE), 'and so does the records tab (PAGE-SCALE-REPORTS-1)');
});

test('the record says why it was written, for the two new reasons too', () => {
  ok(UX.recWhy.putBack && UX.recWhy.stopped && UX.recWhy.dailyCheck, 'a restore, a stop and the daily check have words');
  ok(!('rebuilt' in UX.recWhy), 'OLD-REBUILD-RESTORE-READERS-1: no reason rebuilt');
  ok(UX.recordsNone.includes('restored'), 'and the empty-table sentence names them');
});

// ---------- the download follows the theme the person sees ----------

const downloadRecord = lift('reports.html', 'downloadRecord');
const REC = {
  schemaVersion: 3, runId: 'mig-1', project: 'estate', fromAssessment: 'scan-1',
  generatedUtc: '2026-10-02T10:00:00Z', generatedBy: 'admin@example.com', reason: 'waveClosed', keepUntilUtc: '2026-12-31T10:00:00Z',
  summary: { migrated: 1 }, decisions: [], runActivity: [],
  assessment: { machines: 3, byClassification: { ReadyAfterPrep: 2, Blocked: 1 }, notInMigration: 4 },
  quotaRecords: [{ wave: 'w1', region: 'centralus', zone: '2', size: 'Standard_D4ds_v6', family: 'standardDDSv6Family',
    vcpus: 4, quotaUsed: 12, quotaLimit: 40, state: 'QUOTA_VERIFIED', notes: ['family read from the usage list'] }],
  machines: [{ vmId: '/x/web', name: 'web', wave: 'w1', path: 'B', state: 'MIGRATED', outcome: 'migrated',
    before: { size: 'Standard_D4ds_v4' }, target: { size: 'Standard_D4ds_v6' }, now: { size: 'Standard_D4ds_v6', basis: 'the plan target' },
    assessment: { classification: 'ReadyAfterPrep', generation: 'V2', diskArchitecture: 'scsi-temp', issues: ['stornvme', 'pagefile'] },
    sizeAlternates: ['Standard_D4ads_v6'], planNotes: ['<b>rebuilt</b> around the same disks'], pathCheckpoint: 'B:recreated',
    steps: [], guestScripts: [], putBack: null, activity: [] }],
};
const LOOK = { stylesheet: ':root,:root[data-theme="light"]{--bg:#f8f9fa}:root[data-theme="dark"]{--bg:#222222}', logo: '' };

async function downloaded(themeApi) {
  const saved = [];
  globalThis.window = themeApi === undefined ? {} : { VmfTheme: themeApi };
  globalThis.saveFile = (name, text, type) => saved.push({ name, text, type });
  globalThis.reportLook = async () => LOOK;
  globalThis.recordHtml = lift('reports.html', 'recordHtml');
  globalThis.recordFileName = (rec, ext) => `migration-record.${ext}`;
  globalThis.$ = () => ({ textContent: '', style: {} });
  globalThis.VmfHelp = { explain: (e) => String(e), explainAction: (e) => String(e) };
  // RECORD-DELETE-1: the page-level message the last download left.
  globalThis.recordRefusal = '';
  const btn = { textContent: UX.recRead, disabled: false };
  await downloadRecord(async () => REC, btn);
  return saved;
}

test('THE POINT: a dark dashboard saves a record marked dark', async () => {
  const saved = await downloaded({ current: () => 'dark', choice: () => 'system' });
  eq(saved.length, 1, 'one file');
  eq(saved[0].type, 'text/html', 'the readable record');
  ok(saved[0].text.includes('<html lang="en" data-theme="dark">'), saved[0].text.slice(0, 80));
});

test('a light dashboard saves it marked light', async () => {
  const saved = await downloaded({ current: () => 'light', choice: () => 'light' });
  ok(saved[0].text.includes('<html lang="en" data-theme="light">'), 'light');
});

test('only one of two words is ever written - anything else is light', async () => {
  for (const odd of ['system', '', null, '"><script>alert(1)</script>', 'DARK']) {
    const saved = await downloaded({ current: () => odd });
    ok(saved[0].text.includes('<html lang="en" data-theme="light">'), `for ${JSON.stringify(odd)}`);
    ok(!saved[0].text.includes('<script>'), 'never the value it was given');
  }
  const none = await downloaded(undefined);
  ok(none[0].text.includes('<html lang="en" data-theme="light">'), 'a page with no theme control saves light');
});

// ---------- the record shows every fact the appendix held ----------

test('THE POINT: the downloaded record shows the facts that moved from the appendix', () => {
  const html = lift('reports.html', 'recordHtml')(REC, LOOK, 'light');
  for (const fact of ['ReadyAfterPrep', 'V2', 'scsi-temp', 'stornvme, pagefile', 'Standard_D4ads_v6', 'B:recreated',
                      'standardDDSv6Family', 'centralus', '12 / 40', 'QUOTA_VERIFIED', 'family read from the usage list']) {
    ok(html.includes(fact), `shows ${fact}`);
  }
  ok(html.includes(esc(UX.rAssessment)) && html.includes(esc(UX.rQuota)), 'under their own headings');
  ok(html.includes(esc(UX.rScanned.replace('{n}', '3'))), 'the number of machines scanned');
  ok(html.includes('&lt;b&gt;rebuilt&lt;/b&gt;'), 'a plan note is escaped like everything else');
});

test('and adds no style of its own to do it: no inline style, no colour literal', () => {
  const html = lift('reports.html', 'recordHtml')(REC, LOOK, 'dark').replace(LOOK.stylesheet, '');
  ok(!/style="/i.test(html), 'no inline style');
  ok(!/#[0-9a-f]{3,8}\b|rgba?\(|hsla?\(|font-family/i.test(html), 'no colour or font');
  // DISCLAIMER-1: disclaimer is the report stylesheet's class for the short line.
  ok(!/class="(?!box|sheet|cover|brandline|meta|mono|muted|os|key|disclaimer)[^"]*"/.test(html), 'only the report stylesheet classes');
});

// MACHINE-PICK-1: the record shows how many scanned machines are not in this
// migration, in the words the Migrations page uses for them.
test('the record shows the machines not in this migration, beside the scan counts', () => {
  const html = lift('reports.html', 'recordHtml')(REC, LOOK, 'light');
  const scan = html.slice(html.indexOf(esc(UX.rAssessment)), html.indexOf(esc(UX.rQuota)));
  ok(scan.includes(`<td>${esc(UX.rNotChosen)}</td><td>4</td>`), scan);
  // OLD-VERSION-READERS-REMOVE-6: the record writer always writes the count
  // (migration-record v3 and later require it), so the row is always drawn.
  const none = JSON.parse(JSON.stringify(REC));
  none.assessment.notInMigration = 0;
  const zero = lift('reports.html', 'recordHtml')(none, LOOK, 'light');
  ok(zero.includes(`<td>${esc(UX.rNotChosen)}</td><td>0</td>`), 'a count of 0 is a row too');
  delete none.assessment.notInMigration;
  const gone = lift('reports.html', 'recordHtml')(none, LOOK, 'light');
  ok(gone.includes(`<td>${esc(UX.rNotChosen)}</td><td>0</td>`), 'the row is not left out for a record that holds no count');
  const MIG = liftConst('migrations.html', 'UX_FOUND');
  eq(UX.rNotChosen, MIG.NotChosen[0], 'the same words as the Migrations page');
});

test('one machine scanned is said in the singular', () => {
  const one = JSON.parse(JSON.stringify(REC));
  one.assessment.machines = 1;
  const html = lift('reports.html', 'recordHtml')(one, LOOK, 'light');
  ok(html.includes(esc(UX.rScannedOne)), 'one machine');
  ok(!html.includes('1 machines'), 'never "1 machines"');
});

test('a record written before v3 is still drawn, with nothing for the facts it does not hold', () => {
  const old = JSON.parse(JSON.stringify(REC));
  old.schemaVersion = 2;
  delete old.assessment; delete old.quotaRecords;
  for (const m of old.machines) { delete m.assessment; delete m.sizeAlternates; delete m.planNotes; delete m.pathCheckpoint; }
  const html = lift('reports.html', 'recordHtml')(old, LOOK, 'light');
  ok(html.includes('Standard_D4ds_v6'), 'the record is there');
  ok(!html.includes(esc(UX.rQuota)), 'no empty quota heading');
  ok(!html.includes('undefined') && !html.includes('null'), 'no missing field printed as a word');
});

// RECORD-UNMOVED-1: a machine the plan does not move is "Not moved", as the
// run page says (MANUAL-WHY-1) - never "Not started", in the summary or its heading.
test('a machine the plan does not move reads Not moved in the summary and its heading', () => {
  const rec = JSON.parse(JSON.stringify(REC));
  rec.schemaVersion = 4;
  rec.summary = { migrated: 1, putBack: 0, rolledBack: 0, attention: 0, leftOut: 0, working: 0, notStarted: 0, notMoved: 1, unknown: 0 };
  rec.machines.push({ vmId: '/x/app', name: 'app', wave: 'unscheduled', path: 'MANUAL', state: 'PLANNED', outcome: 'notMoved',
    before: { size: 'Standard_D2s_v4' }, target: { size: null }, now: { size: 'Standard_D2s_v4', basis: 'not changed by this migration' },
    steps: [], guestScripts: [], putBack: null, activity: [] });
  const html = lift('reports.html', 'recordHtml')(rec, LOOK, 'light');
  eq(UX.outcomeWords.notMoved, 'Not moved', 'the run page word');
  ok(html.includes('<h3>app &middot; Not moved</h3>'), 'the heading of the machine');
  ok(html.includes('<td>Not moved</td><td>1</td>'), 'the summary row');
  ok(!html.includes('Not started'), 'no machine is called not started');
});

run('report-auto');
