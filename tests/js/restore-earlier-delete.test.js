/* RESTORE-EARLIER-DELETE-1 (approved design, 2026-10-25). A restore
 * with "Yes. Keep them, detached, in Azure" keeps each managed disk the
 * machine had, and the machine's panel lists them under Its earlier managed
 * disks - each costs money, and only the Azure portal could delete them.
 *
 * Now, under the list, Delete these disks, for an operator, opens the approved
 * confirmation ("This deletes {n} managed disks. ...") with Cancel and Escape
 * (hard rule 11) and Delete, which starts the engine operation deleteearlier
 * through the service's engine route. MADE-DISK-DELETE-1 (2026-11-08): the
 * confirmation slides open in place under the link, the shared slide-out of
 * both deletes of disks on the panel, with the same words.
 *
 * RUN, not read: the page's own restoreEarlierDisks (one rule with the engine,
 * held to tests/fixtures/restore-earlier-disks.json), restoredNoteHtml,
 * and the shared slide-out (diskDeleteHtml, toggleDiskDelete, confirmDiskDelete).
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const U = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_ACT = U;
globalThis.esc = (s) => String(s ?? '');
globalThis.agoSpan = (s) => `<span data-ago="${s}">ago</span>`;
globalThis.runSeg = () => 'run-1';

const page = liftAll('migrations.html', ['restoreEarlierDisks', 'restoredNoteHtml']);
const fixture = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'restore-earlier-disks.json'), 'utf8'));

const D = (n) => `/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/${n}`;
const restore = (extra = {}) => ({
  operationId: 'op-1', restoredUtc: '2026-11-06T09:00:00Z', restoredBy: 'operator@example.com', fromCopy: 'prepared',
  diskNaming: 'new', diskIdChanged: true, previousDiskName: 'vm1-os', newDiskId: D('vm1-os-r'), newDiskName: 'vm1-os-r', retainedDiskId: D('vm1-os'),
  dataDisks: [{ lun: 0, previousDiskId: D('vm1-d0'), previousDiskName: 'vm1-d0', newDiskId: D('vm1-d0-r'), newDiskName: 'vm1-d0-r' },
    { lun: 2, previousDiskId: D('vm1-d2'), previousDiskName: 'vm1-d2', newDiskId: D('vm1-d2-r'), newDiskName: 'vm1-d2-r' }],
  dataDisksKept: [], ...extra,
});

test('restoreEarlierDisks gives each case of the fixture the engine is held to', () => {
  ok(fixture.cases.length > 8, `cases: ${fixture.cases.length}`);
  for (const c of fixture.cases) {
    eq(page.restoreEarlierDisks(c.restore), c.disks, c.why);
  }
});

test('the panel lists the earlier disks by the rule, and a deleted disk leaves the list', () => {
  const all = page.restoredNoteHtml(restore());
  ok(all.includes(`${U.restoredEarlierOs}</td><td class="mono">vm1-os</td>`), all);
  ok(all.includes('LUN 2</td><td class="mono">vm1-d2</td>'), all);
  const some = page.restoredNoteHtml(restore({ earlierDisksDeleted: [{ diskId: D('vm1-os'), deletedUtc: 'x' }, { diskId: D('VM1-D0'), deletedUtc: 'x' }] }));
  ok(!some.includes('<td class="mono">vm1-os</td>') && !some.includes('<td class="mono">vm1-d0</td>'), some);
  ok(some.includes('LUN 2</td><td class="mono">vm1-d2</td>'), 'the disk that is left');
  const none = page.restoredNoteHtml(restore({ earlierDisksDeleted: [D('vm1-os'), D('vm1-d0'), D('vm1-d2')].map(diskId => ({ diskId, deletedUtc: 'x' })) }));
  ok(!none.includes(U.restoredEarlier), 'every disk deleted: the list is gone');
  ok(!none.includes('earlierdelete-slot'), 'and no place for the button');
});

test('the delete goes under the list, and not while a refused swap holds the restore', () => {
  ok(page.restoredNoteHtml(restore()).includes('<span id="earlierdelete-slot"></span>'), 'the place for Delete these disks');
  const left = page.restoredNoteHtml(restore(), { swapPending: { kind: 'restore' } });
  ok(!left.includes('earlierdelete-slot'), 'Finish the restore first');
  ok(PAGE.includes("const restoredNote = restoredNoteHtml(doc.restore, doc).replace('<span id=\"earlierdelete-slot\"></span>', () => earlierDeleteBtn);"), 'the panel fills it');
  ok(PAGE.includes('const diskDeleteFree = () => !doc.swapPending && canOperate() && !putBack.busy && !VmfHelp.machineAtWork(doc.state);'),
    'for an operator, while no job works on the machine');
  ok(PAGE.includes("const earlierDeleteBtn = (earlierN && diskDeleteFree()) ? diskDeleteHtml('earlier', vmId, earlierN) : '';"), 'the shared slide-out (MADE-DISK-DELETE-1)');
  ok(PAGE.includes('const earlierN = restoreEarlierDisks(doc.restore).length;'), 'counted by the rule');
  eq(U.restoredEarlierDelete, 'Delete these disks', 'the approved words');
});

test('MADE-DISK-DELETE-1: the confirmation is the approved text in the slide-out, and its red button posts the machine to deleteearlier', async () => {
  globalThis.DISK_DELETE = liftConst('migrations.html', 'DISK_DELETE');
  globalThis.refreshDrill = () => true;
  globalThis.followThrough = () => { };
  const boxes = { '#ok': { textContent: '', style: {} }, '#err': { style: {} } };
  globalThis.$ = (s) => boxes[s] ?? null;
  globalThis.diskDelete = null;
  const slide = liftAll('migrations.html', ['diskDeleteHtml', 'toggleDiskDelete', 'confirmDiskDelete']);
  slide.toggleDiskDelete('vm-1', 'earlier');
  const html = slide.diskDeleteHtml('earlier', 'vm-1', page.restoreEarlierDisks(restore()).length);
  ok(html.includes('This deletes 3 managed disks. What the machine wrote after the move is lost. The machine and its new disks are not touched.'), 'the approved words');
  ok(html.includes('id="earlierdelete-go">Delete 3 disks</button>'), 'the button says what it does');
  ok(slide.diskDeleteHtml('earlier', 'vm-1', 1).includes('This deletes 1 managed disk. What the machine wrote after the move is lost.'), 'one disk');
  let posted = null;
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  await slide.confirmDiskDelete('vm-1', 'earlier');
  eq(posted[0], 'runs/run-1/engine/deleteearlier', 'the engine route');
  eq(JSON.stringify(posted[1]), JSON.stringify({ vmId: 'vm-1' }), 'only the machine: the engine reads the disks from the record');
  eq(boxes['#ok'].textContent, U.restoredEarlierDeleteDone, 'what happens now');
});

test('rule 11: Cancel and Escape close the slide-out with nothing sent (MADE-DISK-DELETE-1)', () => {
  ok(PAGE.includes("$(`#${kind}delete-cancel`)?.addEventListener('click', () => closeDiskDelete());"), 'Cancel closes it');
  ok(PAGE.includes("if ($('#drill').classList.contains('open') && $('#drill-body .diskdel-slide')) { closeDiskDelete(); return; }"), 'Escape closes it');
  eq(U.cancel, 'Cancel', 'Cancel: closing it throws the choice away (CLOSE-NOT-CANCEL-1)');
});
test('the words: STE nouns, and lost only where a disk is deleted', () => {
  ok(/managed disk/.test(U.restoredEarlierDeleteAsk) && /\{n\}/.test(U.restoredEarlierDeleteAsk), U.restoredEarlierDeleteAsk);
  ok(!/replac/i.test(U.restoredEarlierDeleteDone + U.restoredEarlierDeleteAsk), 'a restore swaps, it does not replace');
  ok(/attached to a machine/.test(U.restoredEarlierDeleteDone), U.restoredEarlierDeleteDone);
});

test('the Activity line of the engine says itself: each disk, each disk skipped and why, and who asked', () => {
  const says = liftConst('migrations.html', 'SAYS_ITSELF');
  const steps = liftConst('migrations.html', 'UX_STEP');
  eq(says.earlierDelete, 'earlierDisksDeleted', 'the step the engine writes (Write-VmfStepLine -Step earlierDelete)');
  ok(steps.earlierDisksDeleted, 'and a fallback that is not the raw engine word');
});

run('restore-earlier-delete');
