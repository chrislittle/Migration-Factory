/* SQL-TEMPDB-SIGNOFF-1 (2026-11-16): the plan sign-off names
 * each machine where the scan found SQL Server and whose move takes it from a
 * SCSI temporary disk to an NVMe temporary disk or none, and asks the approver
 * to tick that they checked where tempdb is. On such a size, SQL Server can
 * fail to start when tempdb is on the temporary disk (Microsoft, "Fix SQL
 * Server on Azure VM deployment and startup failures").
 *
 * This shows ONLY when the scan finds SQL Server. A machine with no SQL
 * Server finding gets nothing - no line, no box, no words - whatever its
 * target; a SQL Server machine whose target keeps a SCSI temporary disk (a v5
 * d size) gets nothing; a plan with no such machine shows no box.
 *
 * RUN, not read: help.js's rule, the Run it step (renderStep5) and its Sign
 * off handler, and the targets step's tag are the pages' own.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const UX = liftConst('wizard.html', 'UX');
const LEVER = liftConst('migrations.html', 'UX_LEVER');
const H = liftAll('help.js', ['signOffRiskLines', 'sqlTempdbRisk', 'sqlTempdbEntries']);
const TABLE = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'sql-tempdb-risk.json'), 'utf8'));

const id = (n) => `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-db/providers/Microsoft.Compute/virtualMachines/${n}`;
const nameOf = (v) => v.split('/').pop();
// A plan entry: by default the case - SQL Server found, SCSI temporary disk to NVMe.
const entry = (n, { sql = true, from = 'scsi-temp', to = 'nvme-temp', wave = 'w1', p = 'A' } = {}) => ({
  vmId: id(n), wave, path: p,
  assessment: { sqlServerDetected: sql, sourceDiskArch: from, sourceCapacityRestricted: false },
  target: { size: 'Standard_E2ds_v6', diskArch: to, controller: to === 'scsi-temp' ? 'SCSI' : 'NVMe' } });

// ---- the rule -------------------------------------------------------------

test('every case of the shared table - the engine reads the same file', () => {
  ok(TABLE.cases.length > 10, 'the table is there');
  for (const c of TABLE.cases) { eq(H.sqlTempdbRisk(c.entry), c.risk, c.name); }
  eq(H.sqlTempdbRisk(null), false, 'no entry');
});

test('the targets step reads the finding from the scan\'s own warning, by the ID in any letter case', () => {
  const tSqlFound = lift('wizard.html', 'tSqlFound');
  globalThis.assessment = { vms: [{ vmId: id('DB-01'), warnings: ['sql-server-agree-downtime'] }, { vmId: id('app-01'), warnings: ['os-disk-standard-hdd'] }, { vmId: id('x-01') }] };
  eq(tSqlFound(id('db-01')), true, 'found, in another letter case');
  eq(tSqlFound(id('app-01')), false, 'another warning');
  eq(tSqlFound(id('x-01')), false, 'no warnings');
  eq(tSqlFound(id('none')), false, 'not in the scan');
  globalThis.assessment = null;
  eq(tSqlFound(id('db-01')), false, 'no assessment read');
});

// ---- the line under the settings of a wave ---------------------------------

const WIZ_WORDS = { capacity: UX.lvCapacityNoGuarantee, nvme: [UX.lvNvmeThirdParty, UX.lvNvmeThirdPartyWhat, UX.lvNvmeDiskPaths], sql: UX.lvSqlTempdb };
const sqlLine = (names) => UX.lvSqlTempdb.replace('{names}', names);

test('the words are the same on both pages', () => {
  eq(UX.lvSqlTempdb, LEVER.sqlTempdb);
});

test('THE CASE: the wave line names each SQL Server machine whose target has an NVMe temporary disk or none, last', () => {
  const lines = H.signOffRiskLines([entry('sql-01'), entry('sql-02', { to: 'diskless' }), entry('app-01', { sql: false })], WIZ_WORDS, nameOf);
  eq(lines[lines.length - 1], sqlLine('sql-01, sql-02'));
  eq(lines.filter(t => /SQL Server/.test(t)).length, 1, 'one line for the wave');
});

test('OWNER (1): no SQL Server found and an NVMe target - no SQL Server line', () => {
  const lines = H.signOffRiskLines([entry('app-01', { sql: false }), entry('app-02', { sql: false, to: 'diskless' })], WIZ_WORDS, nameOf);
  ok(!lines.some(t => /SQL Server|tempdb/.test(t)), 'nothing about SQL Server');
  eq(lines, [UX.lvNvmeThirdParty, UX.lvNvmeThirdPartyWhat, UX.lvNvmeDiskPaths], 'only the NVMe lines it had before');
});

test('OWNER (2): SQL Server found and a SCSI temporary disk target (v5 d) - nothing', () => {
  eq(H.signOffRiskLines([entry('sql-v5', { to: 'scsi-temp' })], WIZ_WORDS, nameOf), []);
});

test('a machine that does not move, and a page that gives no words for it, show no line', () => {
  eq(H.signOffRiskLines([entry('sql-m', { p: 'MANUAL' })], WIZ_WORDS, nameOf).filter(t => /tempdb/.test(t)), []);
  const noSql = { capacity: 'C', nvme: ['N'] };
  eq(H.signOffRiskLines([entry('sql-01')], noSql), ['N'], 'the old call works as before');
});

test('each page passes its words and its machine names', () => {
  const wiz = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'wizard.js'), 'utf8');
  ok(/sql: UX\.lvSqlTempdb \}, \(id\) => machineNameOf\(id\)\)/.test(wiz), 'Run it');
  const mig = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'migrations.js'), 'utf8');
  ok(/sql: UX_LEVER\.sqlTempdb \}, vmName\)/.test(mig), 'Review & accept options');
});

// ---- the Run it step -------------------------------------------------------

const renderStep5 = lift('wizard.html', 'renderStep5');
const sqlNoteNodes = lift('wizard.html', 'sqlNoteNodes');
const waveSignStateFn = lift('wizard.html', 'waveSignState');
const startControlFn = lift('wizard.html', 'startControl');
const acceptControlFn = lift('wizard.html', 'acceptControl');
const acceptAllControlFn = lift('wizard.html', 'acceptAllControl');
const helpBtn = lift('wizard.html', 'tHelpBtn');

/* Paint Run it with a plan of these entries, every wave accepted. Returns the
 * markup and the click handlers the step wired, by selector. */
function paint(entries, { signoff = null, approver = true, sqlChecked = false } = {}) {
  const handlers = {};
  const nodes = {};
  const node = (sel) => nodes[sel] ?? (nodes[sel] = { sel, value: sel === '#f-note' ? 'reviewed' : '', disabled: false, textContent: '', style: {},
    addEventListener(ev, fn) { handlers[`${sel}:${ev}`] = fn; }, querySelectorAll: () => [] });
  const waves = [...new Set(entries.map(e => e.wave))].map(w => [w, { n: entries.filter(e => e.wave === w).length }]);
  globalThis.UX = UX;
  globalThis.planWaves = () => waves;
  globalThis.plan = { entries };
  globalThis.runForm = { note: '', ack: false, sqlChecked, how: 'all', times: {} };
  globalThis.acceptances = new Map(waves.map(([w]) => [w, { acceptedBy: 'operator@example.com' }]));
  globalThis.planSignoff = signoff;
  globalThis.planSignoffCurrent = true;
  globalThis.approvals = new Map(signoff ? waves.map(([w]) => [w, { wave: w, approvedBy: { identity: 'approver@example.com' } }]) : []);
  globalThis.waveSignState = waveSignStateFn;
  globalThis.canApprove = approver;
  globalThis.canOperate = true;
  globalThis.acceptControl = acceptControlFn;
  globalThis.acceptAllControl = acceptAllControlFn;
  globalThis.startControl = startControlFn;
  globalThis.acknowledged = true;
  globalThis.esc = (v) => String(v == null ? '' : v);
  globalThis.card = (t, b, inner) => `<h2>${t}</h2><p>${b}</p>${inner}`;
  globalThis.leverRowsFor = () => '';
  globalThis.tempSections = () => '';
  globalThis.sizeRowsFor = () => '';
  globalThis.runHref = (p) => p;
  globalThis.machineNameOf = nameOf;
  globalThis.sqlNoteNodes = sqlNoteNodes;
  globalThis.VmfHelp = require('./_identity').help({ WAVE_MAX_WORKERS: 60, waveEstimate: () => '' });
  globalThis.$ = (sel) => node(sel);
  globalThis.document = { querySelectorAll: () => [], querySelector: () => null,
    createElement: (tag) => ({ tag, textContent: '', children: [], appendChild(c) { this.children.push(c); } }) };
  globalThis.tHelpBtn = helpBtn;
  globalThis.helpWire = () => {};
  globalThis.exportPlan = () => {};
  globalThis.paintStartFailure = () => {};
  globalThis.tHelp = new Set();
  let noteNodes = null;
  const el = { innerHTML: '', querySelectorAll: () => [],
    // As a real page: the note exists only when the step drew it.
    querySelector: (sel) => sel === '#sql-note' && el.innerHTML.includes('id="sql-note"') ? { replaceChildren: (...n) => { noteNodes = n; } } : null };
  renderStep5(el);
  return { html: el.innerHTML, handlers, nodes, noteNodes: () => noteNodes };
}

test('THE CASE: Run it lists the machines by name, says what to check, and offers the box', () => {
  const r = paint([entry('sql-01'), entry('app-01', { sql: false })]);
  ok(r.html.includes(UX.sqlTitle), 'the section');
  ok(/<input type="checkbox" id="f-sql" aria-describedby="f-sql-err">/.test(r.html), 'the box, not ticked');
  ok(/<p class="f-err" id="f-sql-err" role="alert" hidden><\/p>/.test(r.html), 'with the place for its error');
  ok(r.html.includes(UX.sqlAccept), 'with its words');
  const [lead, list, after] = r.noteNodes();
  eq(lead.textContent, UX.sqlLead);
  eq(list.children.map(c => c.textContent), ['sql-01'], 'only the SQL Server machine, by name');
  eq(after.textContent, UX.sqlAfter);
  ok(r.html.includes(sqlLine('sql-01')), 'and the wave line');
});

test('OWNER (1): no SQL Server found and an NVMe target - no section, no box, no words', () => {
  const r = paint([entry('app-01', { sql: false }), entry('app-02', { sql: false, to: 'diskless' })]);
  ok(!r.html.includes(UX.sqlTitle), 'no section');
  ok(!/id="f-sql"/.test(r.html), 'no box');
  ok(!/tempdb/.test(r.html), 'no word about tempdb');
  eq(r.noteNodes(), null, 'nothing drawn into a note');
});

test('OWNER (2): SQL Server found and a SCSI temporary disk target (v5 d) - no section, no box, no words', () => {
  const r = paint([entry('sql-v5', { to: 'scsi-temp' })]);
  ok(!r.html.includes(UX.sqlTitle), 'no section');
  ok(!/id="f-sql"/.test(r.html), 'no box');
  ok(!/tempdb/.test(r.html), 'no word about tempdb');
});

test('a person who cannot approve reads the list, and gets no box', () => {
  const r = paint([entry('sql-01')], { approver: false });
  ok(r.html.includes(UX.sqlTitle), 'the section');
  ok(!/id="f-sql"/.test(r.html), 'no box');
});

test('once the plan is signed off, the section is not shown again (the sign-off recorded the box)', () => {
  const r = paint([entry('sql-01')], { signoff: { approvedBy: { identity: 'approver@example.com' } } });
  ok(!r.html.includes(UX.sqlTitle), 'no section');
});

test('a ticked box survives a redraw', () => {
  const r = paint([entry('sql-01')], { sqlChecked: true });
  ok(/<input type="checkbox" id="f-sql" aria-describedby="f-sql-err" checked>/.test(r.html));
});

/* The Sign off handler, run. */
async function signOff(entries, { ticked }) {
  const r = paint(entries, { sqlChecked: ticked });
  const calls = [];
  let failed = null;
  globalThis.DEMO_MODE = false;
  globalThis.blobVersioned = async () => ({ version: 'v-plan' });
  globalThis.runPrefix = () => 'runs/r1';
  globalThis.runSeg = () => 'r1';
  globalThis.runBody = (b) => b;
  globalThis.api = async (m, url, body) => { calls.push([m, url, body]); return {}; };
  globalThis.fail = (e) => { failed = e; };
  // WIZARD-START-ERROR-OUT-OF-VIEW-1: a field's error is said under that field.
  globalThis.failField = (input, msg) => { failed = new Error(msg); failed.field = input && input.sel; };
  globalThis.clearErr = () => {};
  globalThis.failAction = (e) => { failed = e; };
  globalThis.saveIacAck = async () => false;
  globalThis.readRun = async () => {};
  globalThis.render = () => {};
  await r.handlers['#signoff:click']();
  return { calls, failed };
}

test('THE CASE: Sign off waits for the box, and says so', async () => {
  const { calls, failed } = await signOff([entry('sql-01')], { ticked: false });
  eq(calls.length, 0, 'nothing is sent');
  eq(failed && failed.message, UX.sqlMissing);
  eq(failed.field, '#f-sql', 'said under the box');
});

test('with the box ticked, the sign-off names the machines', async () => {
  const { calls, failed } = await signOff([entry('sql-01'), entry('sql-02', { to: 'diskless', wave: 'w2' }), entry('app-01', { sql: false })], { ticked: true });
  eq(failed, null);
  eq(calls, [['POST', 'runs/r1/approve-plan', { note: 'reviewed', planHash: 'v-plan', sqlTempdbChecked: [id('sql-01'), id('sql-02')] }]]);
});

test('OWNER (1) and (2): a plan with no such machine signs off as before - no box asked, no names sent', async () => {
  for (const entries of [[entry('app-01', { sql: false })], [entry('sql-v5', { to: 'scsi-temp' })]]) {
    const { calls, failed } = await signOff(entries, { ticked: false });
    eq(failed, null, 'not blocked');
    eq(calls, [['POST', 'runs/r1/approve-plan', { note: 'reviewed', planHash: 'v-plan' }]], 'the body it always sent');
  }
});

// ---- the targets step ------------------------------------------------------

const tSqlRisk = lift('wizard.html', 'tSqlRisk');
const tempLost = lift('wizard.html', 'tempLost');
const sizeOf = lift('wizard.html', 'sizeOf');
const tSqlFoundFn = lift('wizard.html', 'tSqlFound');

function advice({ sql = true, from = 1, move = 'nvme-conversion', to = 1 } = {}) {
  globalThis.assessment = { vms: [{ vmId: id('db-01').toUpperCase(), warnings: sql ? ['sql-server-agree-downtime'] : [] }] };
  globalThis.tSqlFound = tSqlFoundFn;
  globalThis.tempLost = tempLost;
  globalThis.sizeOf = sizeOf;
  return { vmId: id('db-01'), options: [{ option: 'v6', move, tempDisksFrom: from, tempDisksTo: to, targetSize: 'Standard_E2ds_v6', sizeChoices: [] }] };
}

test('THE CASE: the targets step tags a SQL Server machine on a size with an NVMe temporary disk, or none', () => {
  eq(tSqlRisk(advice(), 'v6', new Map()), true, 'v6 d: NVMe temporary disk');
  eq(tSqlRisk(advice({ to: 0 }), 'v6', new Map()), true, 'v6: none');
  eq(tSqlRisk(advice({ move: 'scsi-resize', to: 0 }), 'v6', new Map()), true, 'v5 with no temporary disk');
});

test('OWNER: no tag without the SQL Server finding, or on a size that keeps a SCSI temporary disk', () => {
  eq(tSqlRisk(advice({ sql: false }), 'v6', new Map()), false, 'no SQL Server found');
  eq(tSqlRisk(advice({ move: 'scsi-resize', to: 1 }), 'v6', new Map()), false, 'v5 d keeps a SCSI temporary disk');
  eq(tSqlRisk(advice({ from: 0 }), 'v6', new Map()), false, 'no temporary disk now');
  eq(tSqlRisk(advice({ from: null }), 'v6', new Map()), false, 'not known now');
  eq(tSqlRisk(advice({ move: 'scsi-resize', to: null }), 'v6', new Map()), false, 'a size not known is no tag');
  eq(tSqlRisk(advice({ move: 'scsi-reversion', to: 0 }), 'v6', new Map()), false, 'from NVMe');
  eq(tSqlRisk(advice(), null, new Map()), false, 'no option');
});

test('the tag is drawn under the size, with its words', () => {
  const wiz = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'wizard.js'), 'utf8');
  ok(/if \(tSqlRisk\(m, pick, tSizes\)\) sizeCell \+= `<div class="t-ttag"><span class="pill warn">\$\{esc\(UX\.tSqlTag\)\}<\/span><\/div>`;/.test(wiz));
});

run('sql-tempdb-signoff');
