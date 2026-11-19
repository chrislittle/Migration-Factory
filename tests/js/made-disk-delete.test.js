/* MADE-DISK-DELETE-1 (decision of 2026-11-08: a person may remove these disks
 * in the app if they choose; the slide-out design A was approved).
 *
 * Under Managed disks made from the safety copies on the machine's panel, a
 * quiet text link, Delete these disks now. Click 1 slides open, in place, a
 * short warning ("This deletes {n} disks. A deleted disk cannot be put
 * back."), a red Delete {n} disks and Cancel. Cancel and Escape close it
 * (rule 11; Escape closes it before the panel). Click 2 starts the engine
 * operation deletemade. No pop-up dialog. Nothing shows until clicked.
 *
 * The delete under Its earlier managed disks (RESTORE-EARLIER-DELETE-1) is the
 * same control now, from the same helper, with its approved warning words.
 *
 * RUN, not read: the page's diskDeleteHtml, toggleDiskDelete,
 * closeDiskDelete, confirmDiskDelete, madeDisksHtml and madeDiskRows.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const CSS = fs.readFileSync(path.join(REPO, 'src', 'dashboard', 'app.css'), 'utf8');
const U = liftConst('migrations.html', 'UX_ACT');
const C = liftConst('migrations.html', 'UX_COPIES');
let refreshed = 0;
const okBox = { textContent: '', style: { display: 'none' } };
const errBox = { style: { display: 'block' } };
let followed = 0;
Object.assign(globalThis, {
  UX_ACT: U, UX_COPIES: C,
  esc: (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])),
  agoSpan: (s) => `<span data-ago="${s}">ago</span>`,
  runSeg: () => 'run-1',
  refreshDrill: () => { refreshed++; return true; },
  followThrough: () => { followed++; },
  $: (sel) => (sel === '#ok' ? okBox : sel === '#err' ? errBox : null),
  VmfHelp: { explainAction: (e) => `explained: ${e.message}` },
  madeHelpOpen: new Set(),
  diskDelete: null,
});
globalThis.DISK_DELETE = liftConst('migrations.html', 'DISK_DELETE');
const page = liftAll('migrations.html', ['diskDeleteHtml', 'toggleDiskDelete', 'closeDiskDelete', 'confirmDiskDelete',
  'recordedMachineDiskIds', 'madeDiskRows', 'madeDisksHtml']);

const D = (n) => `/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-app/providers/Microsoft.Compute/disks/${n}`;

test('the two deletes share one helper: each names its engine operation and its own approved words', () => {
  eq(DISK_DELETE.made.op, 'deletemade', 'Delete these disks now');
  eq(DISK_DELETE.earlier.op, 'deleteearlier', 'Delete these disks (RESTORE-EARLIER-DELETE-1)');
  eq(U[DISK_DELETE.made.label], 'Delete these disks now', 'the approved link');
  eq(U[DISK_DELETE.earlier.label], 'Delete these disks', 'the approved link of the earlier disks');
  eq(U[DISK_DELETE.made.ask], 'This deletes {n} disks. It cannot be undone.', 'the approved warning');
  eq(U[DISK_DELETE.made.askOne], 'This deletes 1 disk. It cannot be undone.', 'one disk');
  eq(U[DISK_DELETE.earlier.ask], 'This deletes {n} managed disks. What the machine wrote after the move is lost. The machine and its new disks are not touched.', 'kept: the approved warning of the earlier disks');
  eq(U[DISK_DELETE.earlier.askOne], 'This deletes 1 managed disk. What the machine wrote after the move is lost. The machine and its new disks are not touched.', 'kept: one disk');
  eq(U.diskDeleteGo, 'Delete {n} disks', 'the red button');
  eq(U.diskDeleteGoOne, 'Delete 1 disk', 'one disk');
});

test('closed: only the quiet text link with a chevron, nothing of the warning (nothing shows until clicked)', () => {
  globalThis.diskDelete = null;
  const html = page.diskDeleteHtml('made', 'vm-1', 3);
  ok(/<button type="button" class="linkbtn diskdel-link" id="madedelete-btn" aria-expanded="false" aria-controls="madedelete-slide">Delete these disks now <span class="chev" aria-hidden="true">&rsaquo;<\/span><\/button>/.test(html), html);
  ok(!html.includes('This deletes') && !html.includes('madedelete-go') && !html.includes('id="madedelete-slide"'), 'no warning, no red button');
  ok(!/danger zone/i.test(PAGE), 'nothing is labelled danger zone');
});

test('click 1 slides open, in place, the warning, the red Delete {n} disks and Cancel - no pop-up dialog', () => {
  globalThis.diskDelete = null;
  refreshed = 0;
  page.toggleDiskDelete('vm-1', 'made');
  eq(refreshed, 1, 'the panel draws again');
  const html = page.diskDeleteHtml('made', 'vm-1', 3);
  ok(html.includes('aria-expanded="true"'), 'the link says it is open');
  ok(html.includes('class="askrow inrow askblock diskdel-slide" id="madedelete-slide" role="group"'), 'the in-page question row of the product (POPUP-1), in place');
  ok(html.includes('<span class="ask">This deletes 3 disks. It cannot be undone.</span>'), html);
  ok(/<button type="button" class="btn small danger-fill" id="madedelete-go">Delete 3 disks<\/button>/.test(html), 'the red primary button names what it deletes');
  ok(/<button type="button" class="btn small ghost" id="madedelete-cancel">Cancel<\/button>/.test(html), 'Cancel: the choice is not saved (CLOSE-NOT-CANCEL-1)');
  const one = page.diskDeleteHtml('made', 'vm-1', 1);
  ok(one.includes('This deletes 1 disk. It cannot be undone.') && one.includes('>Delete 1 disk</button>'), 'one disk');
  ok(!page.diskDeleteHtml('made', 'vm-2', 3).includes('id="madedelete-slide"'), 'only on the machine it was opened for');
  ok(!page.diskDeleteHtml('earlier', 'vm-1', 3).includes('id="earlierdelete-slide"'), 'only the delete that was clicked');
  ok(!PAGE.includes('openModal({ title: UX_ACT.restoredEarlierDeleteTitle'), 'the earlier delete opens no dialog now');
});

test('the earlier disks use the same control with their approved warning', () => {
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'earlier', sending: false, err: '' };
  const html = page.diskDeleteHtml('earlier', 'vm-1', 2);
  ok(html.includes('id="earlierdelete-btn"') && html.includes('>Delete these disks <span class="chev"'), html);
  ok(html.includes('This deletes 2 managed disks. What the machine wrote after the move is lost.'), html);
  ok(html.includes('id="earlierdelete-go">Delete 2 disks</button>'), html);
});

test('Cancel and click 1 again close it; nothing is sent', async () => {
  let posted = null;
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  globalThis.diskDelete = null;
  page.toggleDiskDelete('vm-1', 'made');
  page.closeDiskDelete();
  eq(globalThis.diskDelete, null, 'Cancel closes it');
  page.toggleDiskDelete('vm-1', 'made');
  page.toggleDiskDelete('vm-1', 'made');
  eq(globalThis.diskDelete, null, 'the link closes it again (one control, two states)');
  eq(posted, null, 'nothing was sent');
});

test('rule 11: Escape closes the open slide-out first, before the help and before the panel', () => {
  const esc = PAGE.match(/if \(e\.key !== 'Escape'\) return;[\s\S]*?closeDrill\(\); return; \}/);
  ok(esc, 'the page has one Escape handler');
  const body = esc[0];
  const slide = body.indexOf("if ($('#drill').classList.contains('open') && $('#drill-body .diskdel-slide')) { closeDiskDelete(); return; }");
  ok(slide > 0, 'Escape closes the slide-out');
  ok(slide > body.indexOf("$('#modal-back').classList.contains('open')"), 'after a dialog');
  ok(slide < body.indexOf('madeHelpOpen.has(drillVmId)'), 'before the (?)');
  ok(slide < body.indexOf("if ($('#drill').classList.contains('open')) { closeDrill(); return; }"), 'before the panel');
});

test('click 2 posts the machine to the engine operation, closes the slide-out and says what happens', async () => {
  let posted = null;
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'made', sending: false, err: '' };
  followed = 0;
  await page.confirmDiskDelete('vm-1', 'made');
  eq(posted[0], 'runs/run-1/engine/deletemade', 'the engine route');
  eq(JSON.stringify(posted[1]), JSON.stringify({ vmId: 'vm-1' }), 'only the machine: the engine reads the disks from the record');
  eq(globalThis.diskDelete, null, 'closed');
  eq(okBox.textContent, U.madeDeleteDone, 'what happens now');
  eq(okBox.style.display, 'block', 'shown');
  eq(errBox.style.display, 'none', 'an old error goes');
  eq(followed, 1, 'the page follows the job');
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'earlier', sending: false, err: '' };
  await page.confirmDiskDelete('vm-1', 'earlier');
  eq(posted[0], 'runs/run-1/engine/deleteearlier', 'the earlier disks go to their own operation');
  eq(okBox.textContent, U.restoredEarlierDeleteDone, 'with their own words');
});

test('while it sends, the button says Working and cannot be pressed twice; a refusal stays in the slide-out', async () => {
  let release;
  let calls = 0;
  globalThis.apiFetch = () => { calls++; return new Promise((res, rej) => { release = rej; }); };
  globalThis.diskDelete = { vmId: 'vm-1', kind: 'made', sending: false, err: '' };
  const going = page.confirmDiskDelete('vm-1', 'made');
  const busy = page.diskDeleteHtml('made', 'vm-1', 2);
  ok(/id="madedelete-go" disabled aria-busy="true">Working\.\.\.<\/button>/.test(busy), busy);
  await page.confirmDiskDelete('vm-1', 'made');
  eq(calls, 1, 'a second press sends nothing');
  release(new Error('The move of \'vm-1\' has not ended. <b>x</b> $&'));
  await going;
  ok(globalThis.diskDelete && !globalThis.diskDelete.sending, 'the slide-out stays open');
  const html = page.diskDeleteHtml('made', 'vm-1', 2);
  ok(html.includes('role="alert">explained: The move of &#39;vm-1&#39; has not ended. &lt;b&gt;x&lt;/b&gt; $&amp;</span>'), html);
  ok(html.includes('id="madedelete-go">Delete 2 disks</button>'), 'the button is back');
});

test('a press for a slide-out that is not open sends nothing', async () => {
  let posted = null;
  globalThis.apiFetch = async (p, b) => { posted = [p, b]; };
  globalThis.diskDelete = null;
  await page.confirmDiskDelete('vm-1', 'made');
  globalThis.diskDelete = { vmId: 'vm-2', kind: 'made', sending: false, err: '' };
  await page.confirmDiskDelete('vm-1', 'made');
  eq(posted, null, 'nothing');
});

test('the box puts the link under its table, and the panel offers it only where the engine deletes', () => {
  const html = page.madeDisksHtml({ vmId: 'vm-1', state: 'FAILED_NEEDS_ATTENTION', rollbackDisksDuringRollback: [{ diskId: D('x'), diskName: 'x', lun: 0, madeUtc: 'x' }] }, false);
  ok(/<\/table>\s*<span id="madedelete-slot"><\/span>\s*<div style="margin-top:6px"><b>/.test(html), 'right under the table');
  ok(PAGE.includes('const diskDeleteFree = () => !doc.swapPending && canOperate() && !putBack.busy && !VmfHelp.machineAtWork(doc.state);'),
    'for an operator, while no job works on the machine and no refused swap waits');
  ok(PAGE.includes("const madeDeleteBtn = (madeRows.length && ['due', 'waits'].includes(madeRows[0].status) && diskDeleteFree()) ? diskDeleteHtml('made', vmId, madeRows.length) : '';"),
    'not while a restore or a finish holds the disks (the engine refuses then)');
  ok(PAGE.includes("const madeDisks = madeDisksHtml(doc, madeHelpOpen.has(vmId)).replace('<span id=\"madedelete-slot\"></span>', () => madeDeleteBtn);"), 'the panel fills the slot');
  ok(PAGE.includes("const earlierDeleteBtn = (earlierN && diskDeleteFree()) ? diskDeleteHtml('earlier', vmId, earlierN) : '';"), 'the earlier disks by the same rule as before');
  ok(PAGE.includes("for (const kind of ['earlier', 'made', 'original']) {"), 'every delete of disks is wired by one loop (ROLLBACK-ORIGINALS-LEFT-1: the original disks too)');
  ok(PAGE.includes("$(`#${kind}delete-btn`)?.addEventListener('click', () => toggleDiskDelete(vmId, kind));"), 'click 1');
  ok(PAGE.includes("$(`#${kind}delete-cancel`)?.addEventListener('click', () => closeDiskDelete());"), 'Cancel');
  ok(PAGE.includes("$(`#${kind}delete-go`)?.addEventListener('click', () => confirmDiskDelete(vmId, kind));"), 'click 2');
});

test('the red button has its own fill in both themes, and the slide-out slides', () => {
  ok(/\.btn\.danger-fill \{[^}]*background:var\(--bad-fill\);[^}]*color:var\(--on-fill\)/.test(CSS), 'a red fill with white on it');
  const fills = CSS.match(/--bad-fill:\s*#[0-9a-f]{6}/gi) || [];
  eq(fills.length, 2, 'light and dark');
  ok(/\.diskdel-slide \{[^}]*animation:\s*vmf-slide-open/.test(CSS) && /@keyframes vmf-slide-open/.test(CSS), 'it slides open');
  ok(/prefers-reduced-motion: reduce\)[^{]*\{[^}]*\.diskdel-slide \{ animation:\s*none/.test(CSS.replace(/\n/g, ' ')), 'and not for a person who asks for less motion');
  ok(/\.linkbtn \{/.test(CSS), 'the quiet text link');
});

test('the words: STE, lost only where a disk is deleted, and the Activity line says itself', () => {
  ok(!/replac/i.test(U.madeDeleteAsk + U.madeDeleteDone + U.madeHelp), 'a put-back swaps, it does not replace');
  ok(/attached to a machine/.test(U.madeDeleteDone), U.madeDeleteDone);
  ok(/Delete these disks now/.test(U.madeHelp), 'the (?) says the person can delete them now');
  const says = liftConst('migrations.html', 'SAYS_ITSELF');
  const steps = liftConst('migrations.html', 'UX_STEP');
  eq(says.madeDelete, 'madeDisksDeleted', 'the step the engine writes (Write-VmfStepLine -Step madeDelete)');
  ok(steps.madeDisksDeleted, 'and a fallback that is not the raw engine word');
  eq(U.restoredEarlierDeleteTitle, undefined, 'the dialog title is gone with the dialog');
  eq(U.restoredEarlierDeleteConfirm, undefined, 'and its button word');
});

test('review: closing the panel forgets the open slide-out and the open (?); a new open of a machine starts closed', () => {
  // The page's own closeDrill and openDrill, run over a small DOM.
  const drill = { classList: { open: true, remove(c) { if (c === 'open') { this.open = false; } } } };
  const saved$ = globalThis.$;
  globalThis.$ = (sel) => (sel === '#drill' ? drill : saved$(sel));
  try {
    const { closeDrill } = liftAll('migrations.html', ['closeDrill']);
    for (const kind of ['made', 'earlier']) {
      globalThis.diskDelete = { vmId: 'vm-1', kind, sending: false, err: '' };
      globalThis.madeHelpOpen.add('vm-1');
      closeDrill();
      eq(globalThis.diskDelete, null, `${kind}: the x button, Escape and a run change close the slide-out with the panel`);
      eq(globalThis.madeHelpOpen.size, 0, `${kind}: and the (?)`);
      ok(!page.diskDeleteHtml(kind, 'vm-1', 2).includes('id="' + kind + 'delete-slide"'), `${kind}: opened again, the panel shows only the link`);
    }
  } finally { globalThis.$ = saved$; }
  // A machine selected in the list (not the refresh's redraw) starts with nothing open.
  const open = PAGE.match(/async function openDrill\(doc, entry, vmId, opts\) \{\s*const name = vmName\(vmId\);\s*const keep = Boolean\(opts && opts\.keep\);\s*([^\n]*)\n([^\n]*)/);
  ok(open && /if \(!keep\) \{ diskDelete = null; madeHelpOpen\.clear\(\); \}/.test(open[1] + open[2]), 'openDrill forgets them on a new open');
});
test('review: the manual quotes what the warning really says', () => {
  const manual = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'use', 'put-back.md'), 'utf8');
  const said = U.madeDeleteAsk.split('. ').pop();
  eq(said, 'It cannot be undone.', 'the last sentence of the warning');
  ok(manual.includes(`"${said}"`), 'put-back.md quotes it word for word');
});
run('made-disk-delete');
