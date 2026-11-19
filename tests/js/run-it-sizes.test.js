/* RUN-IT-1: the last screen before Start says what each machine becomes.
 *
 * The owner, on "Run it" during the ADVISOR-1 end-to-end run: should it
 * summarise the size chosen for each machine? It did not - the targets were on
 * the first step, four screens back.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, ok, run } = require('./_harness');

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
global.esc = (s) => String(s ?? '');
global.vmName = (id) => String(id).split('/').pop();
// PLAN-NOTES-RUNPAGE-1: the notes are read by the one rule in help.js.
global.VmfHelp = liftAll('help.js', ['planNotesOf']);
const { sizeRowsFor } = liftAll('wizard.html', ['sizeRowsFor']);

test('each machine of the wave, with its size and the size it moves to', () => {
  global.plan = { entries: [
    { vmId: '/vm/vmf-e2e-lin', wave: 'gen2-wave', path: 'A', assessment: { sourceSize: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v7' } },
    { vmId: '/vm/vmf-e2e-win', wave: 'gen2-wave', path: 'A', assessment: { sourceSize: 'Standard_D2ds_v4' }, target: { size: 'Standard_D2ds_v6' } },
    { vmId: '/vm/vmf-e2e-g1', wave: 'gen1-wave', path: 'A', assessment: { sourceSize: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v5' } },
    { vmId: '/vm/left-out', wave: 'gen2-wave', path: 'MANUAL', assessment: { sourceSize: 'Standard_D2s_v3' }, target: { size: null } },
  ] };
  const rows = sizeRowsFor('gen2-wave');
  ok(rows.includes('vmf-e2e-lin') && rows.includes('D2s_v4  →  D2s_v7'), rows);
  ok(rows.includes('vmf-e2e-win') && rows.includes('D2ds_v4  →  D2ds_v6'), rows);
  ok(!rows.includes('vmf-e2e-g1'), 'another wave is not listed');
  ok(!rows.includes('left-out'), 'a machine that is not moved is not listed');
});

test('each wave section on Run it carries it, and the wait line shows it is working', () => {
  ok(WIZ.includes('<table class="facts" style="margin-bottom:12px">${sizeRowsFor(w)}</table>'), 'in each wave');
  ok(WIZ.includes('<p class="muted working" id="s5-watch"><span class="spin"></span>${esc(UX.watching)}</p>'), 'a spinner');
});

// MANA-WIN-3: the notes of the plan for a machine that moves are said under
// it - the engine writes them (planNotes), for example that the move can
// download the MANA driver from download.microsoft.com. Before this, a plan
// note of a machine that moves showed only in the migration record, after it.
test('the notes of the plan for a machine that moves are under its row; a machine that is not moved says none', () => {
  const note = 'Make sure that the machine can connect to download.microsoft.com over HTTPS.';
  global.plan = { entries: [
    { vmId: '/vm/win-01', wave: 'w1', path: 'A', assessment: { sourceSize: 'Standard_D2ds_v4' }, target: { size: 'Standard_D2ds_v6' }, planNotes: [note, 'A second note.'] },
    { vmId: '/vm/lin-01', wave: 'w1', path: 'A', assessment: { sourceSize: 'Standard_D2s_v4' }, target: { size: 'Standard_D2s_v6' } },
    { vmId: '/vm/left-out', wave: 'w1', path: 'MANUAL', assessment: { sourceSize: 'Standard_D2s_v3' }, target: { size: null }, planNotes: ['Not moved note.'] },
  ] };
  const rows = sizeRowsFor('w1');
  ok(rows.includes(note) && rows.includes('A second note.'), rows);
  ok(rows.indexOf('win-01') < rows.indexOf(note) && rows.indexOf(note) < rows.indexOf('lin-01'), 'under its own machine');
  ok(!rows.includes('Not moved note.'), 'a machine that is not moved is not listed');
  ok(/<tr><td colspan="2" class="muted">[^<]*download\.microsoft\.com/.test(rows), 'one row across the table for each note');
});

test('a note goes through esc: it is text from the plan', () => {
  const was = global.esc;
  global.esc = (s) => String(s ?? '').replace(/</g, '&lt;');
  try {
    global.plan = { entries: [{ vmId: '/vm/x', wave: 'w1', path: 'A', target: { size: 'Standard_D2s_v6' }, planNotes: ['<b>bold</b>'] }] };
    const rows = sizeRowsFor('w1');
    ok(rows.includes('&lt;b>bold') && !rows.includes('<b>bold'), rows);
  } finally { global.esc = was; }
});

run('run-it-sizes');
