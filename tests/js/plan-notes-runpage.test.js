/* PLAN-NOTES-RUNPAGE-1: the acceptance on the Migrations page shows the plan
 * notes of each machine that moves.
 *
 * The plan writes notes for a machine that moves (planNotes): that the move
 * can download the MANA driver from download.microsoft.com (MANA-WIN-3), that
 * the size a rollback returns to retires soon (RETIRE-SCOPE-1), that a kernel
 * is not updated (MANA-LINUX-KERNEL-1), and any note the plan adds later. The
 * wizard's Run it step showed them under each machine (sizeRowsFor). The
 * dialog "Accept how this wave will run" on the Migrations page did not, so an
 * operator who accepted and started a wave there was never told.
 *
 * Now both pages read the notes by ONE rule in help.js (VmfHelp.planNotesOf),
 * every note whatever it says, and the dialog has a "Plan notes" row: each
 * machine with notes, by name, and its notes under it.
 *
 * RUN, not read: the pages' own functions, with the pages' own words.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');
require('./_at-once').install();

const pageText = (file) => pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', file));
const { planNotesOf } = liftAll('help.js', ['planNotesOf']);

// ---- the rule -----------------------------------------------------------------
test('the rule (help.js): every note of the entry, as text, in its order', () => {
  eq(JSON.stringify(planNotesOf({ planNotes: ['One.', 'Two.'] })), JSON.stringify(['One.', 'Two.']));
});

test('the rule: no notes, an empty list, an empty note and a value that is not a list give nothing', () => {
  for (const e of [{}, { planNotes: [] }, { planNotes: null }, { planNotes: 'A note.' }, null, undefined]) {
    eq(planNotesOf(e).length, 0, JSON.stringify(e));
  }
  eq(JSON.stringify(planNotesOf({ planNotes: ['', null, 'Kept.'] })), JSON.stringify(['Kept.']));
});

// ---- the acceptance on the Migrations page ------------------------------------
const DIALOG = liftConst('migrations.html', 'UX_LEVER');
let opened = null;
globalThis.DEMO_MODE = true;
globalThis.currentRun = 'run-1';
globalThis.openModal = (opts) => { opened = opts; };
globalThis.UX_LEVER = DIALOG;
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.leverKeepDays = lift('migrations.html', 'leverKeepDays');
globalThis.esc = (s) => String(s ?? '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.anTurnsOnNames = () => [];
globalThis.anDecidedNames = () => [];
globalThis.kernelUpdateNames = () => [];
globalThis.diskChangeTexts = () => [];
globalThis.VmfHelp = {
  planNotesOf,
  seriesLabel: lift('help.js', 'seriesLabel'),
  approvalRequired: lift('help.js', 'approvalRequired'),
  keepDaysText: lift('help.js', 'keepDaysText'),
  VmfRun: { link: (page) => page, routeSegment: (r) => r },
};
require('./_identity').help(globalThis.VmfHelp);
const askAcceptOptions = lift('migrations.html', 'askAcceptOptions');

const MANA = 'The move can download the MANA driver from download.microsoft.com. Make sure that the machine can connect to it over HTTPS.';
const RETIRE = 'The size that a rollback returns to retires soon.';
// PR #844 adds a note that says why a size with a temporary disk was not used.
// The dialog shows a note it has never seen, with no more code.
const NEW_KIND = 'A note of a kind that the page does not know.';
const entries = () => [
  { vmId: '/s/rg/vm/win-01', wave: 'w1', path: 'A', policy: {}, target: { size: 'Standard_D2ds_v6' }, planNotes: [MANA, RETIRE] },
  { vmId: '/s/rg/vm/lin-01', wave: 'w1', path: 'A', policy: {}, target: { size: 'Standard_D2s_v6' } },
  { vmId: '/s/rg/vm/lin-02', wave: 'w1', path: 'A', policy: {}, target: { size: 'Standard_D2s_v6' }, planNotes: [NEW_KIND] },
  { vmId: '/s/rg/vm/left-out', wave: 'w1', path: 'MANUAL', policy: {}, target: { size: null }, planNotes: ['A note of a machine that is not moved.'] },
  { vmId: '/s/rg/vm/other-wave', wave: 'w2', path: 'A', policy: {}, target: { size: 'Standard_D2s_v6' }, planNotes: ['A note of another wave.'] },
];
// The cell of the Plan notes row, as the dialog draws it.
function notesCell(html) {
  const label = `<tr><td class="muted">${globalThis.esc(DIALOG.planNotes)}</td><td>`;
  const at = html.indexOf(label);
  if (at < 0) { return null; }
  const from = at + label.length;
  return html.slice(from, html.indexOf('</td></tr>', from));
}

test('the dialog has a Plan notes row, named with the word of the migration record', () => {
  eq(DIALOG.planNotes, 'Plan notes');
  eq(DIALOG.planNotes, liftConst('reports.html', 'UX').rPlanNotes, 'one name for the notes on both pages');
});

test('THE DEFECT: each machine that moves, by name, with every note the plan wrote for it under it', async () => {
  globalThis.planDoc = { entries: entries() };
  await askAcceptOptions('w1');
  const cell = notesCell(opened.desc);
  ok(cell !== null, `the dialog has a Plan notes row: ${opened.desc}`);
  ok(cell.includes('win-01') && cell.includes(MANA) && cell.includes(RETIRE), cell);
  ok(cell.indexOf('win-01') < cell.indexOf(MANA) && cell.indexOf(MANA) < cell.indexOf(RETIRE), 'the notes under their machine, in order');
  ok(cell.includes('lin-02') && cell.includes(NEW_KIND), 'a note of any kind shows');
  ok(cell.indexOf(RETIRE) < cell.indexOf('lin-02'), 'each machine with its own notes');
});

test('a machine with no notes, a machine that is not moved and a machine of another wave are not named', async () => {
  globalThis.planDoc = { entries: entries() };
  await askAcceptOptions('w1');
  const cell = notesCell(opened.desc);
  ok(!cell.includes('lin-01'), 'no notes, no name');
  ok(!cell.includes('left-out') && !cell.includes('not moved'), 'the acceptance covers the machines that move');
  ok(!cell.includes('other-wave') && !cell.includes('another wave'), 'only this wave');
});

test('a wave with no notes says so, with the word the other rows use', async () => {
  globalThis.planDoc = { entries: entries().filter(e => !e.planNotes || e.path === 'MANUAL' || e.wave === 'w2') };
  await askAcceptOptions('w1');
  eq(notesCell(opened.desc), DIALOG.identityNone);
});

test('the Plan notes row is inside the settings table, after the settings', async () => {
  globalThis.planDoc = { entries: entries() };
  await askAcceptOptions('w1');
  const d = opened.desc;
  const at = d.indexOf(`<td class="muted">${DIALOG.planNotes}</td>`);
  ok(at > d.indexOf(`<td class="muted">${DIALOG.atOnce}</td>`), 'after the last setting');
  ok(at < d.indexOf('</tbody>'), 'in the table');
});

test('a note and a name go through esc: they are text from the plan', async () => {
  globalThis.planDoc = { entries: [
    { vmId: '/s/rg/vm/<b>vm', wave: 'w1', path: 'A', policy: {}, target: { size: 'Standard_D2s_v6' }, planNotes: ['<img src=x onerror=alert(1)>'] },
  ] };
  await askAcceptOptions('w1');
  const cell = notesCell(opened.desc);
  ok(!cell.includes('<img') && cell.includes('&lt;img'), cell);
  ok(!cell.includes('<b>') && cell.includes('&lt;b&gt;vm'), cell);
});

// ---- one rule, in one place ------------------------------------------------------
test('the rule is written once, in help.js, and both pages ask it', () => {
  for (const file of ['wizard.html', 'migrations.html']) {
    const text = pageText(file);
    ok(!/Array\.isArray\(e\.planNotes\)/.test(text), `${file} has its own copy of the rule`);
    ok(/VmfHelp\.planNotesOf\(/.test(text), `${file} asks help.js`);
  }
});

run('plan-notes-runpage');
