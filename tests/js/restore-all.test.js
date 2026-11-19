/* RESTORE-ALL-1: a restore that keeps the disk names deletes every disk it
 * replaces, so the confirmation names each one - "the current disks" is not
 * something a person can check. The names are the disks on the machine NOW,
 * as its record knows them: a rollback or an earlier restore gave some new
 * names, and the newer record wins.
 */
'use strict';
const { lift, test, eq, run } = require('./_harness');

const restoreDiskNames = lift('migrations.html', 'restoreDiskNames');

// The dialog around it: the confirmation a person ticks carries the names.
let opened = null;
global.UX_ACT = new Proxy({}, { get: (_, k) => String(k) });
global.openModal = (opts) => { opened = opts; };
global.noteField = () => ({ id: 'note' });
global.restoreCopyField = () => null;
global.restoreDiskNames = restoreDiskNames;
// RESTORE-DIALOG-WORDS-1: the title names the machine, and the exceptions are its own rule.
global.vmName = (id) => String(id).split('/').pop();
global.restoreExceptions = () => [];
// RESTORE-DELETE-EXCEPTION-1: the sentence under the delete choice, its own rule.
global.restoreKeepInstantNote = () => ({});
// IDENTITY-LOSS-1: what a restore that rebuilds does to the identity (none here).
global.restoreIdentityWords = () => [];
// REBUILD-ACCEPT-1: the Site Recovery line of the restore dialog, not under test here.
global.restoreSiteRecoveryWords = () => [];
const askRestore = lift('migrations.html', 'askRestore');

const captured = {
  osDisk: { name: 'vm1-os' },
  dataDisks: [
    { lun: 0, name: 'vm1-d0', skuName: 'Premium_LRS' },
    { lun: 1, name: 'vm1-d1', skuName: 'Premium_LRS' },
    { lun: 2, name: 'vm1-ultra', skuName: 'UltraSSD_LRS' },
    { lun: 3, name: 'vm1-nocopy', skuName: 'Premium_LRS' }],
};
const copies = [0, 1].map(lun => ({ lun, snapshotId: `/snap/${lun}` }));
const doc = (extra = {}) => ({ captured: { vmConfig: captured }, safety: { pristineDataCopies: copies }, ...extra });

// SAFETY-ULTRA-1 changed this on purpose: a disk on Ultra Disk or Premium SSD
// v2 is restored now, so a restore that keeps the names can delete it, and the
// confirmation names it. A disk with no copy is still not named.
test('every disk with a copy is named, Ultra Disk too; a disk with no copy is not', () => {
  const withUltra = { captured: { vmConfig: captured }, safety: { pristineDataCopies: [...copies, { lun: 2, snapshotId: '/snap/2' }] } };
  eq(restoreDiskNames(withUltra), ['vm1-os', 'vm1-d0', 'vm1-d1', 'vm1-ultra'], 'names');
});

test('a rollback made new disks: those are the disks there now', () => {
  const rb = { rolledBackUtc: '2026-09-29T18:00:00Z', osDisk: { name: 'vm1-os-asitwas' }, dataDisks: [{ lun: 1, diskName: 'vm1-d1-asitwas' }] };
  eq(restoreDiskNames(doc({ rollback: rb })), ['vm1-os-asitwas', 'vm1-d0', 'vm1-d1-asitwas'], 'names');
});

test('the NEWER record wins, whichever it is', () => {
  const rb = { rolledBackUtc: '2026-09-29T18:00:00Z', osDisk: { name: 'rb-os' }, dataDisks: [{ lun: 0, diskName: 'rb-d0' }] };
  const rsNewer = { restoredUtc: '2026-09-30T09:00:00Z', newDiskName: 'rs-os', dataDisks: [{ lun: 0, newDiskName: 'rs-d0' }] };
  eq(restoreDiskNames(doc({ rollback: rb, restore: rsNewer })), ['rs-os', 'rs-d0', 'vm1-d1'], 'restore after rollback');
  const rsOlder = { restoredUtc: '2026-09-28T09:00:00Z', newDiskName: 'rs-os', dataDisks: [{ lun: 0, newDiskName: 'rs-d0' }] };
  eq(restoreDiskNames(doc({ rollback: rb, restore: rsOlder })), ['rb-os', 'rb-d0', 'vm1-d1'], 'rollback after restore');
});

test('a machine with the second copies only names those disks', () => {
  eq(restoreDiskNames({ captured: { vmConfig: captured }, safety: { dataCopies: [{ lun: 1, snapshotId: '/s' }] } }), ['vm1-os', 'vm1-d1'], 'names');
});

test('a machine with no record names nothing, rather than failing', () => {
  eq(restoreDiskNames({}), [], 'names');
});

test('the confirmation a person ticks names each disk the restore deletes', () => {
  askRestore('/s/vm1', doc());
  const accept = opened.fields.find(f => f.id === 'accept');
  eq(accept.options[0].label, 'restoreRisk vm1-os, vm1-d0, vm1-d1', 'the box names the disks');
  eq(accept.showWhen, { id: 'diskNaming', value: 'preserve' }, 'only when the names are kept');
});

run('restore-all');
