/* WAVE-AN-NAMES-1: the wave settings name every machine whose move turns
 * accelerated networking on.
 *
 * The acceptance on the Migrations page and the Run it step of the wizard
 * built the row "Machines that get accelerated networking turned on" from the
 * entry's own setting, ensureOn - which the planner writes only where the
 * target size requires it. In the lab run of 2026-10-11 two Bsv2 moves turned
 * it on and the row said None.
 *
 * Now the engine records the answer on each entry that moves
 * (acceleratedNetworkingOutcome, plan-entry v20), and both pages read the
 * record by ONE rule in help.js (VmfHelp.anOutcomeRow). A machine whose move
 * decides - a Linux kernel with no MANA driver keeps it off (AN-KEEP-1) - is
 * named on its own row. The cases are tests/fixtures/an-outcome.json, which
 * tests/unit/WaveAnNames.Tests.ps1 holds the engine to.
 *
 * RUN, not read: the pages' own functions, with the pages' own words.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'an-outcome.json'), 'utf8'));
const pageText = (file) => pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', file));
const help = liftAll('help.js', ['anOutcomeRow', 'anOutcomeNames', 'seriesLabel', 'approvalRequired', 'keepDaysText', 'previewNames']);

// An entry of wave w1, as the plan stores it: with the engine's record when
// the case is recorded, and without one for an entry that does not move.
const entryOf = (c, i, extra = {}) => {
  const e = Object.assign(JSON.parse(JSON.stringify(c.entry)), { vmId: `/s/rg/vm/m${i}`, wave: 'w1' }, extra);
  if (c.recorded) e.acceleratedNetworkingOutcome = c.outcome;
  return e;
};
const want = (row) => FIXTURE.cases.map((c, i) => [c, i]).filter(([c]) => c.row === row).map(([, i]) => `m${i}`).join(', ');

globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.VmfHelp = {
  anOutcomeRow: help.anOutcomeRow, anOutcomeNames: help.anOutcomeNames, seriesLabel: help.seriesLabel,
  approvalRequired: help.approvalRequired,
  keepDaysText: help.keepDaysText,
  VmfRun: { link: (page) => page, routeSegment: (r) => r },
};
// The real help.js rules the pages draw with (REBUILD-REMOVE-ACCEPT-1: no identity rule).
require('./_identity').help(globalThis.VmfHelp);
require('./_identity').pageGlobals();

// ---- the rule ---------------------------------------------------------------
for (const [i, c] of FIXTURE.cases.entries()) {
  test(`the rule (help.js): ${c.name} -> ${c.row}`, () => {
    eq(help.anOutcomeRow(entryOf(c, i)), c.row);
  });
}

test('the fixture names a machine on each row, and entries with no record', () => {
  for (const row of ['on', 'decides', 'none']) { ok(FIXTURE.cases.some(c => c.recorded && c.row === row), `a recorded case on ${row}`); }
  // OLD-VERSION-READERS-REMOVE-6: an entry with no record is none, whatever its own setting.
  ok(FIXTURE.cases.some(c => !c.recorded && c.entry.policy.acceleratedNetworking === 'ensureOn'), 'an entry with no record that sets ensureOn');
  ok(FIXTURE.cases.filter(c => !c.recorded).every(c => c.row === 'none'), 'every entry with no record is none');
});

test('THE DEFECT: a record that says it turns on wins over an entry with no setting', () => {
  eq(help.anOutcomeRow({ path: 'A', policy: {}, acceleratedNetworkingOutcome: { turnsOn: true, unknownWhy: null } }), 'on');
});

test('the record is read before the setting: a record that says no is no, whatever the setting', () => {
  eq(help.anOutcomeRow({ policy: { acceleratedNetworking: 'ensureOn' }, acceleratedNetworkingOutcome: { turnsOn: false, unknownWhy: null } }), 'none');
});

test('a record that does not say yes or no is the move deciding - never a yes or a no', () => {
  for (const o of [{ turnsOn: null, unknownWhy: 'kernel' }, { turnsOn: null, unknownWhy: 'nics' }, {}, { turnsOn: 'true' }, { turnsOn: 1 }]) {
    eq(help.anOutcomeRow({ policy: { acceleratedNetworking: 'ensureOn' }, acceleratedNetworkingOutcome: o }), 'decides', JSON.stringify(o));
  }
});

test('OLD-VERSION-READERS-REMOVE-6: an entry with no record is none - its own setting is never read in place of the record', () => {
  for (const set of ['ensureOn', 'preserve', 'ensureOff', undefined]) {
    eq(help.anOutcomeRow({ path: 'A', policy: { acceleratedNetworking: set } }), 'none', String(set));
  }
  eq(help.anOutcomeRow({ policy: null }), 'none');
  eq(help.anOutcomeRow(undefined), 'none');
});

// ---- Run it, in the wizard --------------------------------------------------
const WIZ = liftConst('wizard.html', 'UX');
function runItRows(entries) {
  const w = liftAll('wizard.html', ['leverRowsFor', 'anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames', 'previewText']);
  globalThis.UX = WIZ;
  globalThis.plan = { entries };
  const rows = {};
  for (const r of w.leverRowsFor('w1').matchAll(/<tr><td class="muted">([^<]*)<\/td><td>([^<]*)<\/td><\/tr>/g)) { rows[r[1]] = r[2]; }
  return rows;
}

test('THE DEFECT, Run it: every machine the move turns it on for is named, and the ones the move decides on their own row', () => {
  const rows = runItRows(FIXTURE.cases.map((c, i) => entryOf(c, i)));
  eq(rows[WIZ.lvAn], want('on'), 'turned on');
  eq(rows[WIZ.lvAnDecides], want('decides'), 'the move decides');
});

test('Run it: a machine that does not move is named on neither row', () => {
  const c = FIXTURE.cases.find(x => x.recorded && x.row === 'on');
  const d = FIXTURE.cases.find(x => x.recorded && x.row === 'decides');
  const rows = runItRows([entryOf(c, 1, { path: 'MANUAL' }), entryOf(d, 2, { path: 'EXCLUDED' }), entryOf(c, 3, { wave: 'w2' })]);
  eq(rows[WIZ.lvAn], WIZ.lvNone);
  eq(rows[WIZ.lvAnDecides], WIZ.lvNone);
});

// ---- the acceptance on the Migrations page ----------------------------------
const MIG = pageText('migrations.html');
const DIALOG = liftConst('migrations.html', 'UX_LEVER');
let opened = null;
globalThis.DEMO_MODE = true;
globalThis.currentRun = 'run-1';
globalThis.openModal = (opts) => { opened = opts; };
globalThis.UX_LEVER = DIALOG;
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.leverKeepDays = lift('migrations.html', 'leverKeepDays');

// The page's own one-line rules, taken as written.
for (const name of ['anTurnsOnNames', 'anDecidedNames', 'kernelUpdateNames']) {
  const line = MIG.match(new RegExp(`\\nconst ${name} = [\\s\\S]*?;\\n`));
  ok(line, `the page has ${name}`);
  // eslint-disable-next-line no-eval
  globalThis[name] = eval(line[0].replace(`const ${name} = `, '(').replace(/;\n$/, ')'));
}// WAVE-OPTIONS-DISKS-1: the disk row is not what this file tests.
globalThis.diskChangeTexts = () => [];

const askAcceptOptions = lift('migrations.html', 'askAcceptOptions');
function dialogRows(html) {
  const out = {};
  for (const r of html.matchAll(/<tr><td class="muted">([^<]*)<\/td><td>([^<]*)(?:<div class="muted hint"[^>]*>([^<]*)<\/div>)?<\/td><\/tr>/g)) {
    out[r[1]] = [r[2], r[3] ?? ''];
  }
  return out;
}

test('THE DEFECT, the acceptance: the same machines on the same rows as Run it', async () => {
  globalThis.planDoc = { entries: FIXTURE.cases.map((c, i) => entryOf(c, i)) };
  await askAcceptOptions('w1');
  const rows = dialogRows(opened.desc);
  eq(rows[DIALOG.anMachines][0], want('on'), 'turned on');
  eq(rows[DIALOG.anDecidesMachines][0], want('decides'), 'the move decides');
  ok(rows[DIALOG.anDecidesMachines][1] === DIALOG.anDecidesHint && DIALOG.anDecidesHint, 'and it says why, under the names');
});

test('the acceptance: a wave with neither says so on both rows, with no sentence under None', async () => {
  const none = FIXTURE.cases.find(x => x.recorded && x.row === 'none');
  globalThis.planDoc = { entries: [entryOf(none, 0)] };
  await askAcceptOptions('w1');
  const rows = dialogRows(opened.desc);
  eq(rows[DIALOG.anMachines][0], DIALOG.identityNone);
  eq(rows[DIALOG.anDecidesMachines][0], DIALOG.identityNone);
  eq(rows[DIALOG.anDecidesMachines][1], '', 'the sentence explains names, so it goes with them');
});

// ---- one rule, in one place ---------------------------------------------------
test('the rule is written once, in help.js, and both pages ask it', () => {
  for (const file of ['wizard.html', 'migrations.html']) {
    const text = pageText(file);
    ok(!/acceleratedNetworking === 'ensureOn'/.test(text), `${file} has its own copy of the rule`);
    ok(/VmfHelp\.anOutcomeNames\(/.test(text), `${file} asks help.js`);
  }
});

test('the two pages name the rows with the same words', () => {
  eq(WIZ.lvAn, DIALOG.anMachines);
  eq(WIZ.lvAnDecides, DIALOG.anDecidesMachines);
  eq(WIZ.lvAn, 'Machines that get accelerated networking turned on', 'the owner kept these words');
});

run('wave-an-names');
