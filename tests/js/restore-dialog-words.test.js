/* RESTORE-DIALOG-WORDS-1, 2026-10-25: the Restore this machine dialog asks
 * two plain questions in the product's and Azure's own words.
 *
 * The dialog, as opened in the lab: a paragraph about shared disks,
 * Premium SSD v2 and Ultra Disk, then two long answers to "Which copy?" and two
 * to "What should happen to the current disks?". Built for a coder, not for a
 * person. And a read of the code found the words false in places: a restore
 * does not "replace" a disk - it MAKES a new managed disk from each snapshot
 * and SWAPS it onto the machine, and the current disk stays, detached, unless
 * the operator chose to delete it. "So this can be undone" promised an action
 * the product does not have.
 *
 * RUN, not read: the page's own askRestore and the functions it asks, with the
 * page's own UX_ACT. The side panel's restore card is run too
 * (restoredNoteHtml), and the dialog's (?) helper (modalFieldHtml,
 * toggleModalHelp, closeModalHelp).
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));

globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.UX_STEP = liftConst('migrations.html', 'UX_STEP');
globalThis.esc = (s) => String(s ?? '');
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.noteField = () => ({ id: 'note', label: 'Why?', type: 'textarea' });
globalThis.runSeg = () => 'run-1';
globalThis.agoSpan = (s) => `<span data-ago="${s}">ago</span>`;

const page = liftAll('migrations.html', ['restoreShapes', 'shapeWords', 'restoreCopyField',
  'restoreExceptions', 'restoreKeepInstantNote', 'restoreDiskNames', 'putBackRetireNote', 'askRestore', 'restoredNoteHtml', 'restoreEarlierDisks',
  'modalFieldHtml', 'modalHelpHtml', 'modalHelpText', 'toggleModalHelp', 'closeModalHelp',
  // REBUILD-ACCEPT-1: the Site Recovery line of the restore dialog.
  'restoreSiteRecoveryWords']);

const VM = '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/virtualMachines/vm1';

/** Open the dialog and keep what it declared, without drawing it. */
function openWith(doc) {
  let captured = null;
  globalThis.openModal = (opts) => { captured = opts; };
  page.askRestore(VM, doc);
  return captured;
}
async function confirmWith(doc, answers) {
  const opts = openWith(doc);
  let sent = null;
  globalThis.apiFetch = async (p, body) => { sent = { path: p, body }; };
  await opts.onConfirm(answers);
  return sent;
}
const field = (opts, id) => opts.fields.find(f => f && f.id === id);
const option = (opts, id, value) => field(opts, id).options.find(o => o.value === value);

/* A machine moved from D2s_v4 on SCSI to D2ds_v6 on NVMe, verified. Each test
 * data value is different, so a page that reads the wrong field shows it. */
const base = (extra = {}) => ({
  vmId: VM,
  state: 'MIGRATED',
  captured: {
    vmConfig: { size: 'Standard_D2s_v4', controller: 'SCSI', capturedUtc: '2026-10-20T10:00:00Z',
      osDisk: { name: 'vm1-os' }, dataDisks: [{ lun: 0, name: 'vm1-d0', skuName: 'Premium_LRS' }] },
    original: { vmConfig: { size: 'Standard_D2s_v4', controller: 'SCSI' } },
    startedTarget: { path: 'A', size: 'Standard_D2ds_v6', controller: 'NVMe' },
  },
  history: [
    { tsUtc: '2026-10-20T10:01:00Z', state: 'PRECHECK', outcome: 'ok' },
    { tsUtc: '2026-10-20T10:20:00Z', state: 'CONVERTING', outcome: 'ok' },
    { tsUtc: '2026-10-20T10:30:00Z', state: 'VALIDATING', outcome: 'ok' },
  ],
  safety: { pristineSnapshotId: '/snap/vm1-pristine', snapshotId: '/snap/vm1',
    pristineDataCopies: [{ lun: 0, snapshotId: '/snap/d0-p' }], dataCopies: [{ lun: 0, snapshotId: '/snap/d0' }] },
  ...extra,
});

// ---- the title, the one line and the button -------------------------------
test('the title names the machine', () => {
  eq(openWith(base()).title, 'Restore vm1 from a safety copy');
});

test('the one line says what the product does: a new managed disk from each snapshot, swapped on', () => {
  const desc = openWith(base()).desc;
  ok(desc.startsWith(UX_ACT.restoreDesc), desc);
  ok(/makes a new managed disk from each snapshot/.test(UX_ACT.restoreDesc), UX_ACT.restoreDesc);
  ok(/swaps it onto the machine/.test(UX_ACT.restoreDesc), UX_ACT.restoreDesc);
  ok(/do not have data written after the snapshot/.test(UX_ACT.restoreDesc), UX_ACT.restoreDesc);
});

test('the button says Restore, not Confirm', () => {
  eq(openWith(base()).confirmLabel, 'Restore');
  eq(UX_ACT.restoreBtn, 'Restore');
});

test('the note box is kept', () => {
  ok(field(openWith(base()), 'note'), 'a note');
});

// ---- which safety copy -----------------------------------------------------
test('two copies: two short options, each with the size and disk controller from the record', () => {
  const opts = openWith(base());
  const f = field(opts, 'diskSource');
  eq(f.label, 'Which safety copy?');
  eq(f.options.map(o => o.value), ['pristine', 'prepared']);
  eq(option(opts, 'diskSource', 'pristine').label, 'Before the migration');
  eq(option(opts, 'diskSource', 'pristine').sub, 'D2s_v4, SCSI disk controller', 'the ORIGINAL size and controller');
  eq(option(opts, 'diskSource', 'prepared').label, 'Just before the resize');
  eq(option(opts, 'diskSource', 'prepared').sub, 'D2ds_v6, NVMe disk controller', 'the CURRENT size and controller');
});

test('the first copy says the original size from the FIRST capture, not this attempt', () => {
  const d = base();
  d.captured.vmConfig.size = 'Standard_D2ds_v6';   // a retry captured the machine on the target size
  d.captured.vmConfig.controller = 'NVMe';
  d.captured.vmConfig.capturedUtc = '2026-10-19T10:00:00Z';
  eq(option(openWith(d), 'diskSource', 'pristine').sub, 'D2s_v4, SCSI disk controller');
});

test('the first copy helper says accelerated networking goes back', () => {
  const opts = openWith(base());
  ok(/Accelerated networking also returns to how it was/.test(option(opts, 'diskSource', 'pristine').help), option(opts, 'diskSource', 'pristine').help);
  eq(option(opts, 'diskSource', 'pristine').help, UX_ACT.restorePristineHelp, 'the helper offers no rebuild');
  ok(!opts.fields.some(x => x && x.id === 'identityLoss'), 'and no box accepts the loss of an identity');
});

test('only the first copy: that one option, the same short form, and pristine is sent', async () => {
  const d = base({ safety: { pristineSnapshotId: '/snap/vm1-pristine', snapshotId: null } });
  const opts = openWith(d);
  const f = field(opts, 'diskSource');
  eq(f.options.map(o => o.value), ['pristine']);
  eq(f.label, UX_ACT.restoreOnlyCopy);
  eq(f.options[0].label, 'Before the migration');
  eq(f.options[0].sub, 'D2s_v4, SCSI disk controller');
  const sent = await confirmWith(d, { diskSource: 'pristine', diskNaming: 'new', note: 'n' });
  eq(sent.body.diskSource, 'pristine');
  eq(Object.prototype.hasOwnProperty.call(sent.body, 'acceptIdentityLoss'), false, 'no acceptance is sent');
});


test('only the second copy: that one option, and nothing is sent for it - the engine default is that copy', async () => {
  const d = base({ safety: { snapshotId: '/snap/vm1' } });
  const f = field(openWith(d), 'diskSource');
  eq(f.options.map(o => o.value), ['prepared']);
  eq(f.label, UX_ACT.restoreOnlyCopy);
  eq(f.options[0].sub, 'D2ds_v6, NVMe disk controller');
  const sent = await confirmWith(d, { diskSource: 'prepared', diskNaming: 'new', note: 'n' });
  eq(Object.prototype.hasOwnProperty.call(sent.body, 'diskSource'), false);
});

test('two copies send the chosen one', async () => {
  eq((await confirmWith(base(), { diskSource: 'prepared', diskNaming: 'new', note: 'n' })).body.diskSource, 'prepared');
  eq((await confirmWith(base(), { diskSource: 'pristine', diskNaming: 'new', note: 'n' })).body.diskSource, 'pristine');
});

// ---- the sizes, read from the record and never invented ---------------------
test('no capture: no size at all', () => {
  const d = base();
  delete d.captured;
  const opts = openWith(d);
  eq(option(opts, 'diskSource', 'pristine').sub, '');
  eq(option(opts, 'diskSource', 'prepared').sub, '');
});

test('OLD-STATE-READERS-PAGE-1: a capture with no first capture beside it is not one this version writes - no size is said, never the size of this attempt', () => {
  const d = base();
  delete d.captured.original;
  const opts = openWith(d);
  eq(option(opts, 'diskSource', 'pristine').sub, '');
  eq(option(opts, 'diskSource', 'prepared').sub, '');
});

test('a Generation 1 machine has no disk controller on record: the size alone', () => {
  const d = base();
  d.captured.original.vmConfig.controller = null;
  eq(option(openWith(d), 'diskSource', 'pristine').sub, 'D2s_v4');
});

test('the current size after a rollback is the original', () => {
  const d = base({ state: 'FAILED_ROLLED_BACK', rollback: { rolledBackUtc: '2026-10-20T10:40:00Z', path: 'A' } });
  eq(option(openWith(d), 'diskSource', 'prepared').sub, 'D2s_v4, SCSI disk controller');
});

test('a rollback before the move did not change the size', () => {
  const d = base({ state: 'FAILED_ROLLED_BACK', rollback: { rolledBackUtc: '2026-10-20T10:15:00Z', path: 'disks' } });
  d.history = [{ tsUtc: '2026-10-20T10:01:00Z', state: 'PRECHECK', outcome: 'ok' }];
  d.captured.vmConfig.size = 'Standard_D4s_v4';
  eq(option(openWith(d), 'diskSource', 'prepared').sub, 'D4s_v4, SCSI disk controller');
});

test('the current size after an earlier restore: its size, and the controller of the copy it used', () => {
  const pristine = base({ restore: { restoredUtc: '2026-10-21T09:00:00Z', fromCopy: 'pristine', sizeAfter: 'Standard_D2s_v4' } });
  eq(option(openWith(pristine), 'diskSource', 'prepared').sub, 'D2s_v4, SCSI disk controller');
  const prepared = base({ restore: { restoredUtc: '2026-10-21T09:00:00Z', fromCopy: 'prepared', sizeAfter: 'Standard_D2ds_v6' } });
  eq(option(openWith(prepared), 'diskSource', 'prepared').sub, 'D2ds_v6, NVMe disk controller');
});


test('a move that stopped during the resize, with nothing after it: the current size is not known, so none is shown', () => {
  const d = base({ state: 'FAILED_NEEDS_ATTENTION' });
  d.history = [{ tsUtc: '2026-10-20T10:01:00Z', state: 'PRECHECK', outcome: 'ok' },
    { tsUtc: '2026-10-20T10:20:00Z', state: 'CONVERTING', outcome: 'fail' }];
  eq(option(openWith(d), 'diskSource', 'prepared').sub, '');
});

test('a record older than this attempt says nothing about now', () => {
  const d = base({ rollback: { rolledBackUtc: '2026-10-19T10:00:00Z', path: 'A' } });
  eq(option(openWith(d), 'diskSource', 'prepared').sub, 'D2ds_v6, NVMe disk controller', 'the move of this attempt');
  // No resize in this attempt yet: the capture of the attempt, not an older restore.
  const early = base({ state: 'NEEDS_DECISION', restore: { restoredUtc: '2026-10-19T09:00:00Z', fromCopy: 'prepared', sizeAfter: 'Standard_E2s_v5' } });
  early.history = [{ tsUtc: '2026-10-20T10:01:00Z', state: 'PRECHECK', outcome: 'ok' }];
  eq(option(openWith(early), 'diskSource', 'prepared').sub, 'D2s_v4, SCSI disk controller');
});

// ---- the current managed disks ---------------------------------------------
test('keep the current managed disks is the question, and yes is the default', () => {
  const f = field(openWith(base()), 'diskNaming');
  eq(f.label, 'Keep its current managed disks?');
  eq(f.options[0].value, 'new', 'the first option is the one checked');
  ok(/^Yes\. Keep them, detached, in Azure\./.test(f.options[0].label), f.options[0].label);
  ok(/recommended/i.test(f.options[0].label), 'and it says it is the recommended one');
  eq(f.options[1].value, 'preserve');
  eq(f.options[1].label, 'No. Delete them, and give the new disks their names. Data written after the snapshot is lost.');
});

test('the delete option has a helper that says why and what is not copied', () => {
  const help = option(openWith(base()), 'diskNaming', 'preserve').help;
  ok(/name or resource ID/.test(help), help);
  ok(/tags, role assignments or backup/.test(help), help);
  ok(/daily cleanup deletes them when the retention of the wave ends/.test(help), help);
});

test('the delete still needs the checkbox, which names each disk', async () => {
  const opts = openWith(base());
  const accept = field(opts, 'accept');
  eq(accept.showWhen, { id: 'diskNaming', value: 'preserve' });
  eq(accept.options[0].label, `${UX_ACT.restoreRisk} vm1-os, vm1-d0`);
  let refused = null;
  try { await confirmWith(base(), { diskNaming: 'preserve', diskSource: 'pristine', note: 'n', accept: [] }); } catch (e) { refused = e.message; }
  eq(refused, UX_ACT.restoreRiskMissing);
  eq((await confirmWith(base(), { diskNaming: 'preserve', diskSource: 'pristine', note: 'n', accept: ['yes'] })).body.acceptPreserveRisk, true);
});

// ---- the exceptions, only for a machine that has them ----------------------
test('a plain machine is told no exception', () => {
  const desc = openWith(base()).desc;
  ok(!desc.includes(UX_ACT.restoreShared), desc);
  ok(!desc.includes(UX_ACT.restoreInstant), desc);
});

test('a machine with a shared disk is told it stays as it is', () => {
  const d = base();
  d.captured.vmConfig.dataDisks.push({ lun: 1, name: 'vm1-shared', skuName: 'Premium_LRS', maxShares: 2 });
  const desc = openWith(d).desc;
  ok(desc.includes(UX_ACT.restoreShared), desc);
  ok(!desc.includes(UX_ACT.restoreInstant), desc);
});

test('a machine with a Premium SSD v2 or an Ultra Disk is told the restore stops before it changes the machine', () => {
  // Audit: the dialog said such a disk "stays as it is" when Azure cannot use
  // its copy. The restore stops before it changes the machine
  // (Assert-VmfDataDisksAllBack): every disk goes back, or nothing changes.
  for (const sku of ['PremiumV2_LRS', 'UltraSSD_LRS']) {
    const d = base();
    d.captured.vmConfig.dataDisks.push({ lun: 1, name: 'vm1-fast', skuName: sku, maxShares: 1 });
    const desc = openWith(d).desc;
    ok(desc.includes(UX_ACT.restoreInstant), `${sku}: ${desc}`);
    ok(!desc.includes(UX_ACT.restoreShared), desc);
  }
  ok(/stops before it changes the machine/.test(UX_ACT.restoreInstant), UX_ACT.restoreInstant);
  ok(!/stays as it is/.test(UX_ACT.restoreInstant), UX_ACT.restoreInstant);
});

// RESTORE-DELETE-EXCEPTION-1: "No. Delete them" named every current managed
// disk, but the engine does not delete a Premium SSD v2 or Ultra Disk while an
// instant access snapshot of it is not complete (Get-VmfOperatorDataRestorePlan
// leaves that LUN as it is). The delete choice says so, for a machine whose
// record has such a disk with a copy - the copies the engine reads
// (Get-VmfInstantAccessCopyReadiness -Kind all, earlier attempts too).
const fastDisk = (sku, where = 'attempt', copyField = 'pristineDataCopies') => {
  const d = base();
  const disk = { lun: 1, name: 'vm1-fast', skuName: sku, maxShares: 1 };
  if (where === 'attempt') { d.captured.vmConfig.dataDisks.push(disk); }
  else { d.captured.original.vmConfig.dataDisks = [disk]; }
  if (copyField === 'earlier') { d.safety.earlierCopies = [{ dataCopies: [{ lun: 1, snapshotId: '/snap/d1-a1' }] }]; }
  else if (copyField) { d.safety[copyField] = [...d.safety[copyField], { lun: 1, snapshotId: '/snap/d1' }]; }
  return d;
};
const keepSub = (doc) => option(openWith(doc), 'diskNaming', 'preserve').sub;

test('a plain machine: the delete choice says nothing more', () => {
  eq(keepSub(base()), undefined);
  eq(option(openWith(base()), 'diskNaming', 'new').sub, undefined, 'the keep choice neither');
});

test('a Premium SSD v2 or Ultra Disk with a copy: the delete choice says that disk is not deleted while its instant access snapshot is not complete', () => {
  for (const sku of ['PremiumV2_LRS', 'UltraSSD_LRS', 'ultrassd_lrs']) {
    for (const copyField of ['pristineDataCopies', 'dataCopies', 'earlier']) {
      const opts = openWith(fastDisk(sku, 'attempt', copyField));
      eq(option(opts, 'diskNaming', 'preserve').sub, UX_ACT.restoreKeepInstant, `${sku} ${copyField}`);
      eq(option(opts, 'diskNaming', 'new').sub, undefined, 'only on the delete choice');
      ok(!opts.desc.includes(String(UX_ACT.restoreKeepInstant)), 'on the choice, not in the description');
    }
  }
  const words = String(UX_ACT.restoreKeepInstant);
  ok(/Premium SSD v2 or Ultra Disk/.test(words), words);
  ok(/does not delete/.test(words), words);
  ok(/instant access snapshot/.test(words), words);
  ok(/stays as it is/.test(words), words);
});

test('the disk on such a type in the first capture only counts too', () => {
  const sub = keepSub(fastDisk('PremiumV2_LRS', 'original'));
  ok(sub, 'said');
  eq(sub, UX_ACT.restoreKeepInstant);
});

test('such a disk with no copy on record: the delete choice says nothing more', () => {
  eq(keepSub(fastDisk('PremiumV2_LRS', 'attempt', null)), undefined);
  // A copy of another LUN is not a copy of this disk.
  const d = fastDisk('UltraSSD_LRS', 'attempt', null);
  d.safety.dataCopies.push({ lun: 4, snapshotId: '/snap/d4' });
  eq(keepSub(d), undefined);
  // A copy row with no snapshot is no copy.
  const e = fastDisk('UltraSSD_LRS', 'attempt', null);
  e.safety.dataCopies.push({ lun: 1 });
  eq(keepSub(e), undefined);
});

test('a Premium SSD disk with a copy: the delete choice says nothing more', () => {
  eq(keepSub(fastDisk('Premium_LRS')), undefined);
});

test('the retirement note still comes where the first copy can be chosen', () => {
  const d = base();
  d.captured.putBackRetirement = { size: 'Standard_D2s_v3', retiresUtc: '2099-11-15', warnFromUtc: '2000-01-01' };
  ok(/Microsoft retires D2s_v3/.test(openWith(d).desc), openWith(d).desc);
  const second = base({ safety: { snapshotId: '/snap/vm1' } });
  second.captured.putBackRetirement = d.captured.putBackRetirement;
  ok(!/Microsoft retires/.test(openWith(second).desc), 'not for the second copy alone');
});

// ---- the words, against the project's word rules ---------------------------
const RESTORE_KEYS = Object.keys(UX_ACT).filter(k => /^(restore|restored)/.test(k));
test('no restore word says a disk is replaced, or that it can be undone', () => {
  ok(RESTORE_KEYS.length > 20, `restore keys found: ${RESTORE_KEYS.length}`);
  for (const k of RESTORE_KEYS) {
    ok(!/replac/i.test(UX_ACT[k]), `${k}: ${UX_ACT[k]}`);
    ok(!/undo|undone/i.test(UX_ACT[k]), `${k}: ${UX_ACT[k]}`);
  }
});

test('data is lost only where the operator chose to delete the current managed disks', () => {
  const lost = RESTORE_KEYS.filter(k => /\blost\b/.test(UX_ACT[k]));
  // RESTORE-EARLIER-DELETE-1: and the confirmation of Delete these disks, which deletes them.
  eq(lost.sort(), ['restoreKeep', 'restoredEarlierDeleteAsk', 'restoredEarlierDeleteAskOne'], 'only these say lost');
});

test('the restore says the machine starts only when every disk is attached', () => {
  ok(/every disk is attached/.test(UX_ACT.puttingBackTip), UX_ACT.puttingBackTip);
  ok(!/restart on its own/.test(UX_ACT.puttingBackTip), UX_ACT.puttingBackTip);
  ok(!/restarts on the way/.test(UX_ACT.restoreDone), UX_ACT.restoreDone);
});

// ---- the side panel after a restore ----------------------------------------
const restored = (extra = {}) => ({
  restoredUtc: '2026-10-21T09:00:00Z', restoredBy: 'operator@example.com', note: 'did not boot', fromCopy: 'pristine',
  diskNaming: 'new', diskIdChanged: true, previousDiskName: 'vm1-os', newDiskName: 'vm1-os-restored-202610210900',
  retainedDiskId: '/subscriptions/s/resourceGroups/rg/providers/Microsoft.Compute/disks/vm1-os',
  dataDisks: [{ lun: 0, previousDiskId: '/s/disks/vm1-d0', previousDiskName: 'vm1-d0', newDiskId: '/s/disks/vm1-d0-r', newDiskName: 'vm1-d0-d0-restored-202610210900' },
    { lun: 3, previousDiskId: '/s/disks/vm1-d3', previousDiskName: 'vm1-d3', newDiskId: '/s/disks/vm1-d3-r', newDiskName: 'vm1-d3-d3-restored-202610210900' }],
  dataDisksKept: [], ...extra,
});

test('the panel says which copy, when, by whom', () => {
  const html = page.restoredNoteHtml(restored());
  ok(html.includes(UX_ACT.restoredFrom), html);
  ok(html.includes(UX_ACT.restoredFromPristine), 'which copy');
  ok(html.includes('operator@example.com'), 'by whom');
  ok(page.restoredNoteHtml(restored({ fromCopy: 'prepared' })).includes(UX_ACT.restoredFromPrepared), 'the other copy');
});

test('new names: the panel lists its earlier managed disks, OS and each LUN, by name', () => {
  const html = page.restoredNoteHtml(restored());
  ok(html.includes(UX_ACT.restoredEarlier), html);
  ok(html.includes(UX_ACT.restoredEarlierWhat), html);
  ok(/Each costs money until you delete it/.test(UX_ACT.restoredEarlierWhat), UX_ACT.restoredEarlierWhat);
  ok(/detached and kept in Azure/.test(UX_ACT.restoredEarlierWhat), UX_ACT.restoredEarlierWhat);
  ok(html.includes(`${UX_ACT.restoredEarlierOs}</td><td class="mono">vm1-os</td>`), html);
  ok(html.includes(`LUN 0</td><td class="mono">vm1-d0</td>`), html);
  ok(html.includes(`LUN 3</td><td class="mono">vm1-d3</td>`), html);
});

test('names kept: no earlier disks are listed - the restore deleted them - and the panel says what was not copied', () => {
  const html = page.restoredNoteHtml(restored({ diskNaming: 'preserve', diskIdChanged: false, retainedDiskId: null,
    newDiskName: 'vm1-os', dataDisks: [{ lun: 0, previousDiskId: '/s/disks/vm1-d0', previousDiskName: 'vm1-d0', newDiskId: '/s/disks/vm1-d0', newDiskName: 'vm1-d0' }] }));
  ok(!html.includes(UX_ACT.restoredEarlier), html);
  ok(html.includes(UX_ACT.restoredIdSame), html);
  ok(html.includes(UX_ACT.restoredDataIdSame), html);
  ok(/name and resource ID/.test(UX_ACT.restoredIdSame) && /tags, role assignments or backup/.test(UX_ACT.restoredIdSame), UX_ACT.restoredIdSame);
  ok(/names and resource IDs/.test(UX_ACT.restoredDataIdSame) && /tags, role assignments or backup/.test(UX_ACT.restoredDataIdSame), UX_ACT.restoredDataIdSame);
  ok(!/needs changing/.test(UX_ACT.restoredIdSame + UX_ACT.restoredDataIdSame), 'no promise that nothing needs changing');
});

test('names kept, and Azure spells the resource group in another case: still no earlier disk is listed', () => {
  const html = page.restoredNoteHtml(restored({ diskNaming: 'preserve', diskIdChanged: false, retainedDiskId: null, newDiskName: 'vm1-os',
    dataDisks: [{ lun: 0, previousDiskId: '/s/RG/disks/vm1-d0', previousDiskName: 'vm1-d0', newDiskId: '/s/rg/disks/vm1-d0', newDiskName: 'vm1-d0' }] }));
  ok(!html.includes(UX_ACT.restoredEarlier), html);
});

test('a record with no earlier disk names shows no empty list', () => {
  const html = page.restoredNoteHtml(restored({ retainedDiskId: null, previousDiskName: null, dataDisks: [] }));
  ok(!html.includes(UX_ACT.restoredEarlier), html);
});

test('no restore record, no card', () => {
  eq(page.restoredNoteHtml(null), '');
  eq(page.restoredNoteHtml(undefined), '');
});

// ---- the (?) helper of an option: one button, two states, and Escape -------
test('an option with a sub line and a helper paints both, the helper closed', () => {
  const html = page.modalFieldHtml({ id: 'diskNaming', label: 'Q', type: 'radio', options: [
    { value: 'new', label: 'Yes.' }, { value: 'preserve', label: 'No.', sub: 'D2s_v4', help: 'Why it is so.' }] });
  ok(html.includes('<span class="sub">D2s_v4</span>'), html);
  ok(/<button type="button" class="btn small ghost m-help" data-mhelp="mf-diskNaming-help-1" aria-expanded="false" aria-controls="mf-diskNaming-help-1"[^>]*>\?<\/button>/.test(html), html);
  ok(html.includes('<span class="m-help-text" id="mf-diskNaming-help-1" hidden>Why it is so.</span>'), html);
  ok(!html.includes('mf-diskNaming-help-0'), 'no helper for an option without one');
  ok(/value="new" checked/.test(html), 'the first option is checked');
});

function helpPair() {
  const text = { hidden: true };
  const btn = {
    dataset: { mhelp: 'mf-x-help-0' }, textContent: '?', attrs: { 'aria-expanded': 'false' },
    setAttribute(k, v) { this.attrs[k] = String(v); }, getAttribute(k) { return this.attrs[k]; },
  };
  return { btn, text };
}

test('the helper opens to Close and closes to ?', () => {
  const { btn, text } = helpPair();
  globalThis.document = { getElementById: (id) => (id === 'mf-x-help-0' ? text : null), querySelectorAll: () => [btn] };
  page.toggleModalHelp(btn);
  eq(text.hidden, false, 'open');
  eq(btn.textContent, UX_ACT.close, 'the button says Close');
  eq(btn.attrs['aria-expanded'], 'true');
  page.toggleModalHelp(btn);
  eq(text.hidden, true, 'closed');
  eq(btn.textContent, '?');
  eq(btn.attrs['aria-expanded'], 'false');
});

test('Escape closes an open helper first, and says it did', () => {
  const { btn, text } = helpPair();
  globalThis.document = { getElementById: (id) => (id === 'mf-x-help-0' ? text : null), querySelectorAll: () => [btn] };
  eq(page.closeModalHelp(), false, 'nothing open, nothing closed');
  page.toggleModalHelp(btn);
  eq(page.closeModalHelp(), true, 'it closed one');
  eq(text.hidden, true);
  eq(btn.textContent, '?');
});

test('the page Escape handler asks the helper before it closes the dialog', () => {
  const m = PAGE.match(/if \(e\.key !== 'Escape'\) return;\s*\n\s*if \(\$\('#modal-back'\)\.classList\.contains\('open'\)\) \{ if \(closeModalHelp\(\)\) return; closeModal\(\); return; \}/);
  ok(m, 'the Escape handler');
});

test('a failed Restore keeps its own button label', () => {
  ok(PAGE.includes('confirmBtn.disabled = false; confirmBtn.textContent = confirmLabel ?? UX_ACT.confirm;'), 'the catch restores the label the dialog was given');
});

// ---- the activity labels of a restore --------------------------------------
const STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
const label = (step) => { const hit = STEP_MAP.find(([re]) => re.test(step)); return hit ? hit[1] : null; };

test('deleting the current disk to use its name again has its own words', () => {
  eq(label('azureops:restore:removeOriginal'), 'deleteCurrentDisk');
  eq(label('azureops:restore:removeOriginalData'), 'deleteCurrentDisk');
  ok(/Deleting the current disk to use its name again/.test(UX_STEP.deleteCurrentDisk), UX_STEP.deleteCurrentDisk);
});

test('the temporary disk has its own words', () => {
  eq(label('azureops:restore:removeTemp'), 'deleteTempDisk');
  eq(label('azureops:restore:removeTempData'), 'deleteTempDisk');
  ok(/temporary disk/.test(UX_STEP.deleteTempDisk), UX_STEP.deleteTempDisk);
  // RESTORE-ORIGINAL-DELETE-RESTART-1: the original OS disk goes back - its own words, not the generic swap's.
  eq(label('azureops:restore:swapDiskBack'), 'swapOriginalBack');
  eq(UX_STEP.swapOriginalBack, 'Putting the original OS disk back on the machine');
  eq(label('azureops:restore:swapDisk'), 'swapBackDisk');
});

test('OLD-REBUILD-RESTORE-READERS-1: no step words of a rebuild; a rollback disk nothing used is unchanged', () => {
  for (const k of ['restoreRemoveVm', 'removeOldVm', 'rebuildVm', 'recreateVm', 'verifyDisks']) { ok(!(k in UX_STEP), `${k} is gone`); }
  eq(label('azureops:rollback:deleteRollbackDisksBeforeMove'), 'tidyDisk', 'a rollback disk nothing used is unchanged');
});

run('restore-dialog-words');
