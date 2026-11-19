/* MANUAL-SHOT-RESTORE-1: the picture of the Restore dialog for a machine with
 * only its first safety copy.
 *
 * A machine has only the first copy when a step failed before the second copy
 * and the rollback could not finish (PREP-ROLLBACK-1). The panel then offers
 * Restore this machine, and the dialog shows one copy, Before the migration.
 * No sample machine is in that state - adding one would change the count and
 * the Safety copies card on every other picture of the sample migration - so
 * the shot gives the page's own openDrill that record, as machine-power-owed
 * does, and clicks the panel's own Restore this machine.
 *
 * A picture that shows a dialog the product does not draw for that machine is
 * worse than no picture. So this RUNS the shot's act against stubs, takes the
 * record it hands the panel, and asks the page's own rules: the panel offers
 * Restore for it, the dialog has one copy and it is the first one, and the
 * shot's expect holds the picture to exactly that. And the put-back page of
 * the manual shows the picture.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const SRC = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
const SHOTS = (() => {
  const m = SRC.match(/\nconst SHOTS = (\[[\s\S]*?\n\]);/);
  if (!m) { throw new Error('could not read SHOTS'); }
  return eval(m[1]);   // eslint-disable-line no-eval
})();
const FILE = 'machine-restore-first-copy.png';
const shot = SHOTS.find(s => s.file === FILE);

// The page's own rules, with help.js's machineAtWork.
const HELP_SRC = pageSource(path.join(REPO, 'src', 'dashboard', 'help.js'));
const HELP = liftAll('help.js', ['machineHold', 'machineAtWork']);
// eslint-disable-next-line no-eval
const idKey = eval('(' + HELP_SRC.match(/function idKey\(id\) \{[^\n]*\}/)[0] + ')');
globalThis.VmfHelp = Object.assign(globalThis.VmfHelp ?? {}, { machineAtWork: HELP.machineAtWork, idKey });
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.noteField = () => ({ id: 'note', label: 'Why?' });
globalThis.runSeg = () => 'migration-1';
const page = liftAll('migrations.html', ['restoreCopiesThere', 'restoreOffered',
  'restoreCopyField', 'restoreDiskNames', 'restoreKeepInstantNote', 'putBackRetireNote', 'askRestore',
  'restoreExceptions', 'restoreShapes', 'shapeWords', 'restoreSiteRecoveryWords']);

/** Run the shot's act against stubs: what it hands openDrill, and what it clicks. */
async function runAct() {
  const seen = { drill: null, clicked: [] };
  const stubDocument = { querySelector: (sel) => ({ click: () => seen.clicked.push(sel) }) };
  const stubDrill = async (doc, entry, vmId) => { seen.drill = { doc, entry, vmId }; };
  const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
  const timer = (fn) => { fn(); return 0; };
  await new AsyncFunction('openDrill', 'document', 'setTimeout', shot.act)(stubDrill, stubDocument, timer);
  return seen;
}

test('the tool has a shot of the first-copy-only Restore dialog, clipped to the dialog', () => {
  ok(shot, `tools/manual-shots.js has a shot named ${FILE}`);
  ok(/[?&]demo\b/.test(shot.url) && /^migrations\.html/.test(shot.url), 'it is taken on the sample migration page');
  eq(shot.clip, '#modal-back .modal');
});

test('RUN the act: the panel is drawn from a record, then its own Restore this machine is clicked', async () => {
  const seen = await runAct();
  ok(seen.drill && seen.drill.doc, 'the act hands the panel a record');
  eq(seen.clicked[seen.clicked.length - 1], '#restore-btn');
  eq(String(seen.drill.doc.vmId ?? seen.drill.vmId).split('/').pop(), String(seen.drill.vmId).split('/').pop());
});

test('the page\'s own rules: the panel offers Restore for that record, and the dialog shows only the first copy', async () => {
  const { doc, vmId } = (await runAct()).drill;
  ok(page.restoreCopiesThere(doc, true), 'the record has a copy to restore from');
  ok(page.restoreOffered(doc, true), 'the panel offers Restore this machine for it');
  ok(!doc.safety?.snapshotId, 'the record has no second copy');
  ok(doc.safety?.pristineSnapshotId, 'the record has the first copy');
  let opts = null;
  globalThis.openModal = (o) => { opts = o; };
  page.askRestore(vmId, doc);
  const copy = opts.fields.find(f => f.id === 'diskSource');
  ok(copy, 'the dialog asks about the copy');
  eq(JSON.stringify(copy.options.map(o => o.value)), JSON.stringify(['pristine']));
  eq(copy.label, UX_ACT.restoreOnlyCopy);
  // The option says the size and the disk controller the machine returns to.
  ok(copy.options[0].sub, 'the copy shows the size and the disk controller from the record');
  // Nothing in the dialog's description that this machine does not have.
  eq(opts.desc, UX_ACT.restoreDesc);
});

test('the shot\'s expect holds the picture to one copy, the first one', () => {
  ok(/diskSource/.test(shot.expect) && /only-child/.test(shot.expect) && /pristine/.test(shot.expect),
    `the expect requires a lone first-copy option: ${shot.expect}`);
});

test('the put-back page shows the picture', () => {
  const md = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'use', 'put-back.md'), 'utf8');
  ok(md.includes(`](../images/${FILE})`), `use/put-back.md shows ${FILE}`);
});

run('manual-shot-restore');
