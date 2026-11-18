/* ROLLBACK-ORIGINALS-LEFT-1 (in 1.0 since 2026-11-08). A rollback
 * puts the machine on new disks made from the first safety copy, and the
 * disks it had before the migration stay in Azure, detached, costing money.
 * The machine's panel now names them, under Restore this machine, in the
 * approved words, with the two-step slide-out delete of the panel
 * (MADE-DISK-DELETE-1): the engine operation deleteearlier, with diskSet
 * rollback.
 *
 * RUN, not read: the page's own rollbackOriginalDisks (one rule with the
 * engine, held to tests/fixtures/rollback-originals.json), recordDiskIdsInUse,
 * rollbackOriginalsHtml, and the shared slide-out.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const U = liftConst('migrations.html', 'UX_ACT');
const okBox = { textContent: '', style: { display: 'none' } };
const errBox = { style: { display: 'block' } };
Object.assign(globalThis, {
  UX_ACT: U,
  esc: (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  agoSpan: (s) => `<span data-ago="${s}">ago</span>`,
  runSeg: () => 'run-1',
  refreshDrill: () => true,
  followThrough: () => {},
  $: (sel) => (sel === '#ok' ? okBox : sel === '#err' ? errBox : null),
  VmfHelp: { explainAction: (e) => `explained: ${e.message}` },
  diskDelete: null,
});
globalThis.DISK_DELETE = liftConst('migrations.html', 'DISK_DELETE');
const page = liftAll('migrations.html', ['recordDiskIdsInUse', 'rollbackOriginalDisks', 'rollbackOriginalsHtml',
  'diskDeleteHtml', 'confirmDiskDelete', 'recordedMachineDiskIds']);
const fixture = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'rollback-originals.json'), 'utf8'));

test('rollbackOriginalDisks gives each case of the fixture the engine is held to', () => {
  ok(fixture.cases.length > 7, `cases: ${fixture.cases.length}`);
  for (const c of fixture.cases) {
    eq(page.rollbackOriginalDisks(c.doc), c.disks, c.why);
  }
});

const recorded = fixture.cases[1].doc;

test('the part: the approved heading, the text with the machine name, the columns, one row for each disk, and what happens next', () => {
  const html = page.rollbackOriginalsHtml(recorded, 'app-01');
  ok(html.includes('<b>Original disks, not in use</b>'), html);
  ok(html.includes('These are the disks app-01 had before the migration. The rollback did not put them back. It put the machine on new disks, made from the snapshot taken before the migration changed anything. These disks are detached, and each costs money until you delete it.'), 'the approved text, word for word');
  ok(/<thead><tr><th>Disk<\/th><th>Used as<\/th><th>Detached<\/th><\/tr><\/thead>/.test(html), 'the columns');
  ok(html.includes('<tr><td class="mono">vm1-os</td><td>Operating system disk</td><td><span data-ago="2026-11-08T09:58:00Z">ago</span></td></tr>'), 'the OS disk');
  ok(html.includes('<tr><td class="mono">vm1-d3</td><td>LUN 3</td><td><span data-ago="2026-11-08T09:59:30Z">ago</span></td></tr>'), 'a data disk by its LUN');
  ok(/<\/table>\s*<span id="originaldelete-slot"><\/span>\s*<div style="margin-top:6px"><b>What happens next:<\/b> Kept until you delete them\.<\/div>/.test(html), 'the delete right under the table, then what happens next');
  ok(!/costs money until it is deleted/.test(html), 'not the words of the made disks');
});

test('the name is escaped, and the part is not there with no disk', () => {
  const html = page.rollbackOriginalsHtml(recorded, '<b>$&</b>');
  ok(html.includes('These are the disks &lt;b&gt;$&amp;&lt;/b&gt; had before'), html);
  eq(page.rollbackOriginalsHtml(fixture.cases[0].doc, 'app-01'), '', 'no rollback: nothing');
  const gone = JSON.parse(JSON.stringify(recorded));
  for (const e of gone.rollbackOriginals) { e.deletedUtc = '2026-11-08T11:00:00Z'; }
  eq(page.rollbackOriginalsHtml(gone, 'app-01'), '', 'every disk deleted: the part goes');
});

test('the slide-out: the approved warning with the count and the machine name, Cancel, and the red Delete {n} disks', () => {
  const k = DISK_DELETE.original;
  eq(k.op, 'deleteearlier', 'the engine operation that deletes the earlier disks of a restore');
  eq(k.set, 'rollback', 'with the original disks of a rollback');
  eq(U[k.label], 'Delete these disks', 'the approved button');
  eq(U[k.ask], 'This deletes {n} disks. It cannot be undone. The disks {vm} uses now are not touched.', 'the approved warning');
  eq(U[k.askOne], 'This deletes 1 disk. It cannot be undone. The disks {vm} uses now are not touched.', 'one disk');
  eq(U[k.done], U.restoredEarlierDeleteDone, 'after the delete: the existing restore line');
  globalThis.diskDelete = null;
  const closed = page.diskDeleteHtml('original', 'vm-1', 3, 'app-01');
  ok(closed.includes('id="originaldelete-btn"') && !closed.includes('This deletes'), 'closed: only the link');
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'original', sending: false, err: '' };
  const html = page.diskDeleteHtml('original', 'vm-1', 3, 'app-01');
  ok(html.includes('<span class="ask">This deletes 3 disks. It cannot be undone. The disks app-01 uses now are not touched.</span>'), html);
  ok(html.includes('id="originaldelete-go">Delete 3 disks</button>'), 'the existing diskDeleteGo words');
  ok(html.includes('id="originaldelete-cancel">Cancel</button>'), 'Cancel (rule 11)');
  const one = page.diskDeleteHtml('original', 'vm-1', 1, '$&');
  ok(one.includes('This deletes 1 disk. It cannot be undone. The disks $&amp; uses now are not touched.') && one.includes('>Delete 1 disk</button>'), one);
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'made', sending: false, err: '' };
  ok(page.diskDeleteHtml('made', 'vm-1', 2, 'app-01').includes('This deletes 2 disks. It cannot be undone.</span>'), 'the other deletes keep their words');
});

test('click 2 posts the machine and the set of disks to deleteearlier, and says what happens', async () => {
  let posted = null;
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'original', sending: false, err: '' };
  await page.confirmDiskDelete('vm-1', 'original');
  eq(posted[0], 'runs/run-1/engine/deleteearlier', 'the engine route');
  eq(JSON.stringify(posted[1]), JSON.stringify({ vmId: 'vm-1', diskSet: 'rollback' }), 'the machine and which disks; the engine reads the disks from the record');
  eq(okBox.textContent, U.restoredEarlierDeleteDone, 'the existing restore line');
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'earlier', sending: false, err: '' };
  await page.confirmDiskDelete('vm-1', 'earlier');
  eq(JSON.stringify(posted[1]), JSON.stringify({ vmId: 'vm-1' }), 'a restore\'s earlier disks: as before');
});

test('the panel: the part sits under the restore box, offered where the engine deletes, and is wired with the others', () => {
  ok(PAGE.includes('const originalRows = rollbackOriginalDisks(doc);'), 'the rows by the one rule');
  ok(PAGE.includes("const originalDeleteBtn = (originalRows.length && diskDeleteFree()) ? diskDeleteHtml('original', vmId, originalRows.length, name) : '';"),
    'for an operator, while no job works on the machine and no refused swap waits');
  ok(PAGE.includes("const originalDisks = rollbackOriginalsHtml(doc, name).replace('<span id=\"originaldelete-slot\"></span>', () => originalDeleteBtn);"), 'the panel fills the slot');
  ok(/\$\{restoredNote\}\s*\$\{originalDisks\}\s*\$\{madeDisks\}/.test(PAGE), 'under the restore box, where a restore lists its earlier disks');
  ok(PAGE.includes("for (const kind of ['earlier', 'made', 'original']) {"), 'click 1, Cancel and click 2, by the one loop');
  ok(PAGE.includes("if ($('#drill').classList.contains('open') && $('#drill-body .diskdel-slide')) { closeDiskDelete(); return; }"), 'Escape closes any slide-out (rule 11)');
});

test('the cleanup twin: every original disk is a disk of the machine', () => {
  const ids = page.recordedMachineDiskIds({ rollbackOriginals: [{ diskId: 'D1', diskName: 'd1', lun: null, detachedUtc: 'x' }] });
  ok(ids.includes('D1'), JSON.stringify(ids));
});

test('the Activity line of the delete has its own heading', () => {
  const says = liftConst('migrations.html', 'SAYS_ITSELF');
  const steps = liftConst('migrations.html', 'UX_STEP');
  eq(says.originalDelete, 'originalDisksDeleted', 'the step the engine writes (Write-VmfStepLine -Step originalDelete)');
  ok(steps.originalDisksDeleted && !/restore/.test(steps.originalDisksDeleted), steps.originalDisksDeleted);
});

test('the manual quotes the approved words', () => {
  const manual = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'use', 'put-back.md'), 'utf8');
  ok(manual.includes('Original disks, not in use'), 'the heading');
  ok(manual.includes('Delete these disks') && manual.includes('and "It cannot be undone." It also says that the disks the machine uses now do not change.'), 'the warning');
});
run('rollback-originals');
