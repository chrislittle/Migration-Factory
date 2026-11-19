/* WAVE-WORDS-3: one name for each wave setting, and for each of its values,
 * on every screen that shows it.
 *
 * A person sets a wave in the wave editor, and accepts it at Run it in the
 * wizard or in the acceptance dialog on the Migrations page. The three said
 * the same settings under other words: "sign off" and "approve", "Capacity
 * reservation for this wave" and "How this wave gets its hardware", and the
 * no-reservation value was "Pay as you go", "None - standard allocation" and
 * "None" in three places. A person accepted in one place what they set in
 * another, under words that did not match.
 *
 * The editor's words are the names. These tests read the three pages' own
 * string tables, never a copy of them, so a page that drifts fails here.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const editor = liftConst('waves.html', 'UX');
const wizard = liftConst('wizard.html', 'UX');
const dialog = liftConst('migrations.html', 'UX_LEVER');
const pageText = (file) => pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', file));

// [what it is, editor key, wizard key, dialog key]. A null editor key is a
// row the editor does not show (it is not a choice there).
const SAME = [
  ['capacity setting',      'capLabel',        'lvCapacity',        'capacityGate'],
  ['no reservation',        'capOnDemand',     'lvCapOnDemand',     'capOnDemand'],
  ['reservation',           'capReserved',     'lvCapReserved',     'capReserved'],
  ['sign-off setting',      'approvalOn',      'lvApproval',        'requireApproval'],
  ['temporary disk setting','dataLabel',       'lvData',            'onDDataFound'],
  ['temporary disk: stop',  'dataStop',        'lvDataStop',        'dataStop'],
  ['temporary disk: go on', 'dataProceed',     'lvDataProceed',     'dataProceed'],
  // WAVE-KERNEL-LINE-1: no wave kernel setting; its one row on all three.

  ['retention setting',     'keepLabel',       'lvKeep',            'keepDays'],
  ['retention: none',       null,              'lvKeepNever',       'keepDaysNever'],
  ['retention: one day',    null,              'lvKeepOne',         'keepDayOne'],
  ['retention: days',       null,              'lvKeepMany',        'keepDaysMany'],
  ['at once setting',       'atOnceLabel',     'lvAtOnce',          'atOnce'],
  ['safety copy row',       null,              'lvCopy',            'safetyCopy'],
  ['safety copy value',     null,              'lvCopyAlways',      'safetyCopyAlways'],
  ['accelerated networking row', null,         'lvAn',              'anMachines'],
  ['move decides row',      null,              'lvAnDecides',       'anDecidesMachines'],
  ['kernel row',            'kernelLabel',     'lvKernel',          'kernelMachines'],
  ['disk type row',         null,              'lvDisks',           'diskMachines'],
  ['disk type change',      null,              'lvDiskMachine',     'diskMachine'],
  ['no machines',           'kernelNone',      'lvNone',            'identityNone'],
  ['yes',                   null,              'lvYes',             'yes'],
  ['no',                    null,              'lvNo',              'no'],
];

test('THE DEFECT: each setting and each value has one name on the three screens', () => {
  const bad = [];
  for (const [what, e, w, d] of SAME) {
    const names = [e ? editor[e] : undefined, wizard[w], dialog[d]].filter(v => v !== undefined);
    ok(names.length === (e ? 3 : 2), `${what}: a key is missing (${e}, ${w}, ${d})`);
    if (new Set(names).size !== 1) { bad.push(`${what}: ${names.map(n => JSON.stringify(n)).join(' / ')}`); }
  }
  eq(bad, [], 'names that differ');
});

test('the capacity setting is named by Azure, and its values are No and Yes', () => {
  // Rule 10: Azure calls the thing the Reserved mode makes an on-demand
  // capacity reservation. Pay as you go is a way Azure BILLS, and a machine
  // on a reservation is billed pay as you go as well, so it named nothing.
  // Since 2026-11-13: the setting is On-demand capacity reservation for this wave, with No and Yes.
  eq(editor.capLabel, 'On-demand capacity reservation for this wave', 'the setting');
  eq(editor.capReserved, 'Yes', 'the reservation');
  eq(editor.capOnDemand, 'No', 'no reservation');
});

test('no page keeps one of the old names', () => {
  // WAVE-WORDS-4 added the last two: the capacity card called a wave set to
  // None "None requested", and the step words, the card hints and the report
  // said "reserved capacity" for the on-demand capacity reservation.
  const gone = ['Pay as you go', 'standard allocation',
                'How this wave gets its hardware', 'must approve before this wave runs',
                'None requested', 'reserved capacity'];
  const found = [];
  const tables = [['waves.html', editor], ['wizard.html', wizard], ['migrations.html', dialog],
                  ...['UX_ACT', 'UX_STEP', 'UX_MISC', 'UX_CAP', 'UX_STATE', 'UX_COPIES'].map(n => ['migrations.html', liftConst('migrations.html', n)]),
                  ['reports.html', liftConst('reports.html', 'UX')]];
  for (const [file, table] of tables) {
    for (const [k, v] of Object.entries(table)) {
      for (const g of gone) { if (typeof v === 'string' && v.toLowerCase().includes(g.toLowerCase())) { found.push(`${file} ${k}: ${g}`); } }
      if (typeof v === 'string' && /^Reserved capacity(\.|$)/.test(v)) { found.push(`${file} ${k}: Reserved capacity`); }
    }
  }
  eq(found, [], 'old names');
});

// ---- the acceptance dialog, run with the page's own words -----------------
let opened = null;
global.DEMO_MODE = true;
global.currentRun = 'run-1';
global.esc = (s) => String(s ?? '');
global.vmName = (id) => String(id).split('/').pop();
global.openModal = (opts) => { opened = opts; };
global.UX_LEVER = dialog;
global.UX_ACT = liftConst('migrations.html', 'UX_ACT');
// A rule that is not in help.js fails the tests that need it, not the file.
const helpNames = ['seriesLabel', 'approvalRequired', 'keepDaysText', 'anOutcomeRow', 'anOutcomeNames',
  'runParse', 'runStorePath', 'runRouteSegment', 'runWithProject', 'runLink'];
let help;
try { help = liftAll('help.js', helpNames); } catch (e) { help = { missing: e.message }; }
const needHelp = () => { if (help.missing) { throw new Error(help.missing); } };
global.VmfHelp = {
  seriesLabel: help.seriesLabel, approvalRequired: help.approvalRequired,
  keepDaysText: help.keepDaysText,
  anOutcomeRow: help.anOutcomeRow, anOutcomeNames: help.anOutcomeNames,
  VmfRun: { parse: help.runParse, storePath: help.runStorePath, routeSegment: help.runRouteSegment,
            withProject: help.runWithProject, link: help.runLink },
};
// The real help.js rules the pages draw with.
require('./_identity').help(global.VmfHelp);
require('./_identity').pageGlobals();
const m = liftAll('migrations.html', ['leverKeepDays']);
global.leverKeepDays = m.leverKeepDays;
const askAcceptOptions = lift('migrations.html', 'askAcceptOptions');
// The page's own one-line rules, taken as written.
const PAGE = pageText('migrations.html');
for (const name of ['anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames']) {
  const line = PAGE.match(new RegExp(`\\nconst ${name} = [\\s\\S]*?;\\n`));
  ok(line, `the page has ${name}`);
  // eslint-disable-next-line no-eval
  global[name] = eval(line[0].replace(`const ${name} = `, '(').replace(/;\n$/, ')'));
}// WAVE-OPTIONS-DISKS-1: the disk row is not what this file tests.
global.diskChangeTexts = () => [];


/** label -> [the value, the helper text under it] */
function dialogRows(html) {
  const out = {};
  for (const r of html.matchAll(/<tr><td class="muted">([^<]*)<\/td><td>([^<]*)(?:<div class="muted hint"[^>]*>([^<]*)<\/div>)?<\/td><\/tr>/g)) {
    out[r[1]] = [r[2], r[3] ?? ''];
  }
  return out;
}
const entry = (name, policy, extra = {}) => ({ vmId: `/s/${name}`, wave: 'w1', path: 'A', assessment: {}, policy, ...extra });

test('the dialog shows the value by its name, and the longer answer only as helper text', async () => {
  needHelp();
  global.planDoc = { entries: [entry('a', { capacityGate: 'Reserved', onDDataFound: 'stop', requireApproval: true })] };
  await askAcceptOptions('w1');
  const rows = dialogRows(opened.desc);
  const [value, hint] = rows[editor.capLabel] ?? [];
  eq(value, editor.capReserved, 'the capacity value is the editor name');
  ok(hint && hint !== value, 'and its longer answer is helper text under it');
  eq(rows[editor.dataLabel][0], editor.dataStop, 'the temporary disk value');
  eq(rows[editor.approvalOn][0], 'Yes', 'the sign-off row, by the editor name');
  global.planDoc = { entries: [entry('a', { capacityGate: 'BestEffort' })] };
  await askAcceptOptions('w1');
  eq(dialogRows(opened.desc)[editor.capLabel][0], 'No', 'no reservation');
});

// ---- no screen names a setting or a row for a new identity ----------------
// REBUILD-REMOVE-ACCEPT-1: no move rebuilds a machine, so none gets a new
// system-assigned identity: the setting, its values and the row of machines
// are gone from the editor, Run it and the dialog, and help.js has no rule.
test('no page has the identity setting or the row of machines that get a new identity', () => {
  for (const k of ['identityLabel', 'identityStop', 'identityProceed', 'identityTag', 'identityTip']) eq(editor[k], undefined, `editor ${k}`);
  for (const k of ['lvIdentity', 'lvIdentityStop', 'lvIdentityProceed', 'lvIdentityMachines', 'lvIdentityMeans']) eq(wizard[k], undefined, `wizard ${k}`);
  for (const k of ['onSystemAssignedIdentity', 'identityStop', 'identityProceed', 'identityMachines']) eq(dialog[k], undefined, `dialog ${k}`);
  for (const file of ['waves.html', 'wizard.html', 'migrations.html']) {
    ok(!/VmfHelp\.(getsNewIdentity|newIdentityNames)\(/.test(pageText(file)), `${file} asks no identity rule`);
  }
});

test('RUN: Run it shows no identity row, even for an older plan with a rebuilt machine', () => {
  needHelp();
  const w = liftAll('wizard.html', ['leverRowsFor', 'anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames', 'previewText']);
  global.UX = wizard;
  global.anTurnsOnNames = w.anTurnsOnNames;
  global.anDecidedNames = w.anDecidedNames;
  global.kernelUpdateNames = w.kernelUpdateNames;
  global.plan = { entries: [entry('rebuilt-sys', {}, { path: 'B', assessment: { identityType: 'SystemAssigned' } })] };
  const html = w.leverRowsFor('w1');
  ok(!/identity/i.test(html), html);
});
test('the retention reads the same at Run it and in the dialog, for every number', () => {
  needHelp();
  const w = liftAll('wizard.html', ['leverRowsFor', 'anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames', 'previewText']);
  global.UX = wizard;
  global.anTurnsOnNames = w.anTurnsOnNames;
  global.anDecidedNames = w.anDecidedNames;
  global.kernelUpdateNames = w.kernelUpdateNames;
  for (const days of [0, 1, 7, 30, undefined]) {
    global.plan = { entries: [entry('a', days === undefined ? {} : { keepSnapshotDays: days })] };
    const row = w.leverRowsFor('w1').match(new RegExp(`<td class="muted">${wizard.lvKeep}</td><td>([^<]*)</td>`));
    ok(row, 'the retention row');
    eq(row[1], m.leverKeepDays(days), `${days} days`);
  }
  eq(m.leverKeepDays(0), dialog.keepDaysNever, 'zero says what zero means');
  eq(m.leverKeepDays(1), '1 day after the machine is migrated', 'one day');
  eq(m.leverKeepDays(undefined), '7 days after the machine is migrated', 'the default');
});

// ---- the restore dialog says its confirmation once ------------------------
test('THE DEFECT: the restore confirmation is not also the label of its field', () => {
  global.noteField = () => ({ id: 'note' });
  global.restoreCopyField = () => null;
  global.restoreDiskNames = () => ['vm1-os'];
  global.putBackRetireNote = () => '';
  global.restoreExceptions = () => [];
  global.restoreKeepInstantNote = () => ({});
  global.vmName = (id) => id;
  const askRestore = lift('migrations.html', 'askRestore');
  askRestore('/s/vm1', { safety: { pristineSnapshotId: '/snap' , snapshotId: '/snap2' } });
  const accept = opened.fields.find(f => f.id === 'accept');
  ok(accept.options[0].label.includes('vm1-os'), 'the box names the disks');
  ok(!accept.label, 'and the field has no label that repeats it');
});

test('and the dialog draws no label for a field that has none', () => {
  // RESTORE-DIALOG-WORDS-1: the field markup moved out of openModal into modalFieldHtml.
  const open = PAGE.slice(PAGE.indexOf('function modalFieldHtml('), PAGE.indexOf('function modalFieldHtml(') + 2500);
  ok(PAGE.includes('fields.map(modalFieldHtml)'), 'openModal draws each field with it');
  ok(open.includes("else if (f.type === 'checks') inner = (f.label ? `<label>${esc(f.label)}</label>` : '')"), 'the checks field label is drawn only when there is one');
});

test('the same for the acknowledgement: its statement is said once', () => {
  const ack = PAGE.slice(PAGE.indexOf('function askAcknowledge('), PAGE.indexOf('function askAcknowledge(') + 400);
  ok(/\{ id: 'accept', type: 'checks',/.test(ack), 'the acknowledgement box has no repeated label');
});

// ROLLBACK-CAPACITY-1, FILTER-DRIVER-READ-1 and DISK-PATH-READ-1
// (2026-11-14): the acceptance shows the same lines as Run it, by the one rule
// of help.js, in the page's own words - only for a wave they are true of.
test('RUN: the acceptance shows the capacity and NVMe lines under the table, only when true', async () => {
  needHelp();
  const risk = () => [...opened.desc.matchAll(/<p[^>]*data-waverisk[^>]*>([^<]*)<\/p>/g)].map(m => m[1]);
  global.planDoc = { entries: [entry('a', {}, { assessment: { sourceCapacityRestricted: true }, target: { controller: 'NVMe' } })] };
  await askAcceptOptions('w1');
  eq(risk(), [dialog.capacityNoGuarantee, dialog.nvmeThirdParty, dialog.nvmeThirdPartyWhat, dialog.nvmeDiskPaths], 'both, capacity first');
  ok(/<\/table><\/div><p data-waverisk/.test(opened.desc), 'under the settings table');
  global.planDoc = { entries: [entry('a', {}, { assessment: { sourceCapacityRestricted: null }, target: { controller: 'SCSI' } }),
    entry('m', {}, { path: 'MANUAL', assessment: { sourceCapacityRestricted: true }, target: { controller: 'NVMe' } })] };
  await askAcceptOptions('w1');
  eq(risk(), [], 'not known, SCSI, and a machine that does not move: none');
});
run('wave-words');
