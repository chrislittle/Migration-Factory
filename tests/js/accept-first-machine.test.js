/* ACCEPT-FIRST-MACHINE-1: the acceptance shows the settings of the WAVE, and
 * names each machine that does not follow one.
 *
 * Review & accept options on the Migrations page, and the Run it step of the
 * wizard, read every setting from the FIRST machine of the wave. A machine can
 * hold another value for a setting - a decision for that one machine, for
 * example Continue when files are found on its temporary disk. When that
 * machine was first, the dialog said Continue for the whole wave; when it was
 * not, the dialog said Stop and ask and named no machine. Either way the
 * person accepted a sentence that was not true for every machine.
 *
 * Now both read the wave by the wave editor's rule (help.js waveCard, held to
 * the service by tests/fixtures/wave-own-settings.json), and under each
 * setting list each machine that does not follow it in the wave editor's
 * words (help.js ownRowText) - with no button: the dialog changes nothing.
 *
 * RUN, not read: the page functions, with the page's own string tables and the
 * real rule of help.js (tests/js/_at-once.js lifts it from help.js).
 */
'use strict';
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
require('./_at-once').install();
const { OWN_TEXT } = require('./_at-once');

const askAcceptOptions = lift('migrations.html', 'askAcceptOptions');
const UX_LEVER = liftConst('migrations.html', 'UX_LEVER');
const WIZ = liftConst('wizard.html', 'UX');
const WAVES = liftConst('waves.html', 'UX');

// ---- the page around the function -----------------------------------------
let opened = null, planText = null;
global.DEMO_MODE = false;
global.currentRun = 'run-1';
global.planDoc = null;
global.UX_LEVER = UX_LEVER;
global.UX_ACT = { acceptOptionsTitle: 'Accept', acceptOptionsDesc: 'desc', acceptOptionsEdit: 'edit',
  acceptOptionsConfirm: 'Accept', acceptOptionsStale: 'stale' };
global.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
global.vmName = (id) => String(id).split('/').pop();
global.runSeg = () => 'run-1';
global.anTurnsOnNames = () => [];
global.anDecidedNames = () => [];
global.kernelUpdateNames = (es) => es.filter(e => e.policy?.onDriverBelowFloor === 'updateKernel').map(e => vmName(e.vmId));
global.diskChangeTexts = () => [];
global.leverKeepDays = (n) => `${n} days kept`;
global.openModal = (o) => { opened = o; };
global.apiFetch = async () => ({});
global.source = { readVersioned: async () => ({ text: planText, version: 'v1' }) };
global.$ = () => ({ style: {} });
global.VmfHelp = {
  seriesLabel: lift('help.js', 'seriesLabel'),
  approvalRequired: lift('help.js', 'approvalRequired'),
  keepDaysText: lift('help.js', 'keepDaysText'),
  // ROLLBACK-CAPACITY-1: the lines under the table, by the one rule.
  // SQL-TEMPDB-SIGNOFF-1: with the SQL Server rule it asks.
  signOffRiskLines: liftAll('help.js', ['signOffRiskLines', 'sqlTempdbEntries', 'sqlTempdbRisk']).signOffRiskLines,
  explainAction: (e) => e.message,
  planNotesOf: () => [],
  VmfRun: { link: () => 'waves.html' },
};

const DAY = (iso) => new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
const DECIDED = '2026-11-02T09:40:00Z';
const mk = (name, policy = {}, decisions) => ({ vmId: `/s/${name}`, wave: 'w1', path: 'A', assessment: {},
  policy: Object.assign({ capacityGate: 'BestEffort', requireApproval: true, onDDataFound: 'stop', onDriverBelowFloor: 'stop',
    keepSnapshotDays: 7, throttle: 15, targetGeneration: 'v6' }, policy), ...(decisions ? { decisions } : {}) });
// The FIRST machine continues past files on its temporary disk, by a decision
// for it alone; it also keeps its snapshots 14 days. The other two follow the
// wave. Then a fourth updates its kernel.
const FIRST_OWN = () => [
  mk('first', { onDDataFound: 'proceed', keepSnapshotDays: 14 }, [{ setting: 'onDDataFound', by: 'approver@example.com', utc: DECIDED }]),
  mk('second'), mk('third'),
  mk('lin', { onDriverBelowFloor: 'updateKernel' }),
];
/** One row of the dialog's table: the cell after the setting's label. */
function rowOf(desc, label) {
  const row = desc.split('<tr>').find(r => r.includes(`<td class="muted">${esc(label)}</td>`));
  if (!row) { throw new Error(`no row ${label}`); }
  return row;
}
/** The machines a row names, in the wave editor's words. */
const ownRows = (row) => [...row.matchAll(/<div class="hint" data-ownrow[^>]*>([^<]*)<\/div>/g)].map(m => m[1]);
async function dialog(entries) {
  opened = null;
  planText = JSON.stringify({ entries });
  await askAcceptOptions('w1');
  ok(opened, 'the dialog opened');
  return opened.desc;
}

test('a wave whose FIRST machine continues: the row says the wave\'s Stop and ask, and names that machine with its value and who accepted it', async () => {
  const desc = await dialog(FIRST_OWN());
  const row = rowOf(desc, UX_LEVER.onDDataFound);
  ok(row.includes(`<td>${esc(UX_LEVER.dataStop)}`), `the wave's value, not the first machine's: ${row}`);
  ok(!row.includes(`<td>${esc(UX_LEVER.dataProceed)}`), 'not Continue for the whole wave');
  ok(row.includes(esc('1 machine does not follow this setting.')), 'the count, in the wave editor\'s words');
  eq(ownRows(row), [esc(`first: Continue - the files are deleted. approver@example.com accepted this for the machine on ${DAY(DECIDED)}.`)]);
});

test('the same wave with that machine LAST says the same: the order of the machines changes nothing', async () => {
  const entries = FIRST_OWN();
  const first = await dialog(entries);
  const last = await dialog([entries[1], entries[2], entries[3], entries[0]]);
  eq(ownRows(rowOf(last, UX_LEVER.onDDataFound)), ownRows(rowOf(first, UX_LEVER.onDDataFound)));
  ok(rowOf(last, UX_LEVER.onDDataFound).includes(`<td>${esc(UX_LEVER.dataStop)}`), 'Stop and ask');
});

test('a value set with no decision is named with the value only; the wave\'s value is shown', async () => {
  const row = rowOf(await dialog(FIRST_OWN()), UX_LEVER.keepDays);
  ok(row.includes('<td>7 days kept'), `the wave keeps 7 days, not the first machine's 14: ${row}`);
  eq(ownRows(row), [esc('first: 14 days.')]);
});

test('WAVE-KERNEL-LINE-1: Update the kernel is named on its own row, and no machine is said not to follow a kernel setting', async () => {
  const desc = await dialog(FIRST_OWN());
  ok(!desc.includes('If the kernel is below the minimum version'), 'no kernel setting of the wave');
  const row = rowOf(desc, UX_LEVER.kernelMachines);
  ok(row.includes('<td>lin</td>'), row);
  eq(ownRows(row), [], 'no "does not follow" line for the kernel');
});

test('two machines that do not follow a setting: the count says 2, and each is named', async () => {
  const entries = FIRST_OWN();
  entries[2] = mk('third', { onDDataFound: 'proceed' }, [{ setting: 'onDDataFound', by: 'approver@example.com', utc: 'not a day' }]);
  const row = rowOf(await dialog(entries), UX_LEVER.onDDataFound);
  ok(row.includes(esc('2 machines do not follow this setting.')), row);
  eq(ownRows(row).length, 2);
  ok(ownRows(row).includes(esc('third: Continue - the files are deleted. approver@example.com accepted this for the machine.')), 'no readable day: who accepted it');
});

test('the wave-wide settings name no machine, and a wave where every machine follows names none', async () => {
  const desc = await dialog([mk('a'), mk('b')]);
  eq(ownRows(desc), [], 'no machine is named');
  ok(!desc.includes('does not follow') && !desc.includes('do not follow'), 'and no count');
  const own = await dialog(FIRST_OWN());
  for (const label of [UX_LEVER.capacityGate, UX_LEVER.requireApproval, UX_LEVER.atOnce]) { eq(ownRows(rowOf(own, label)), [], label); }
});

test('the dialog offers no button for a machine: it shows, it changes nothing', async () => {
  const desc = await dialog(FIRST_OWN());
  ok(!/data-ownreset|data-resetvm|<button/.test(desc), desc);
  ok(!desc.includes(esc(WAVES.ownReset)), 'no Use the wave\'s setting');
});

test('the capacity gate is read as the wave editor reads it, whatever case the plan holds', async () => {
  const row = rowOf(await dialog([mk('a', { capacityGate: 'reserved' }), mk('b', { capacityGate: 'reserved' })]), UX_LEVER.capacityGate);
  ok(row.includes(`<td>${esc(UX_LEVER.capReserved)}`), row);
});

test('one day is said in the singular, and a count of days with its number', () => {
  const r = require('./_at-once').waveRule;
  eq(r.ownValueText('keepSnapshotDays', 1), '1 day');
  eq(r.ownValueText('keepSnapshotDays', 14), '14 days');
  eq(r.ownValueText('keepSnapshotDays', 0), '0 days');
});

test('the words of a value are the labels of each page\'s own control', () => {
  eq(OWN_TEXT.ownDataStop, UX_LEVER.dataStop, 'the acceptance');
  eq(OWN_TEXT.ownDataProceed, UX_LEVER.dataProceed, 'the acceptance');
  eq(OWN_TEXT.ownDataStop, WAVES.dataStop, 'the wave editor');
  eq(OWN_TEXT.ownDataProceed, WAVES.dataProceed, 'the wave editor');
  eq(OWN_TEXT.ownDataStop, WIZ.lvDataStop, 'the Run it step');
  eq(OWN_TEXT.ownDataProceed, WIZ.lvDataProceed, 'the Run it step');
});

// ---- the Run it step of the wizard: the same rule, the same words ---------
test('Run it: a wave whose FIRST machine continues shows the wave\'s Stop and ask, and names the machine', () => {
  global.UX = WIZ;
  global.previewText = () => WIZ.lvNone;
  global.anTurnsOnNames = () => [];
  global.anDecidedNames = () => [];
  global.kernelUpdateNames = () => [];
  global.diskChangeTexts = () => [];
  global.plan = { entries: FIRST_OWN() };
  const rows = lift('wizard.html', 'leverRowsFor')('w1');
  const data = rows.split('<tr>').find(r => r.includes(`<td class="muted">${esc(WIZ.lvData)}</td>`));
  ok(data && data.includes(`<td>${esc(WIZ.lvDataStop)}`), `the wave's value: ${data}`);
  eq(ownRows(data), [esc(`first: Continue - the files are deleted. approver@example.com accepted this for the machine on ${DAY(DECIDED)}.`)]);
  const keep = rows.split('<tr>').find(r => r.includes(`<td class="muted">${esc(WIZ.lvKeep)}</td>`));
  ok(keep.includes(esc(WIZ.lvKeepMany.replace('{n}', '7'))), `the wave keeps 7 days: ${keep}`);
  eq(ownRows(keep), [esc('first: 14 days.')]);
  ok(!/<button/.test(rows), 'no button');
});

run('accept-first-machine');
