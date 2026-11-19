// RESTORE-LABELS-1: the restore choices name the disk controller, not a "disk type".
//
// Restore this machine offers two copies. From the first, the product puts
// back the original size AND disk controller (Restore-VmfVm, Set-Vmf-
// VmSizeAndController with the captured controller). The labels said "disk
// type" - a vague word for a thing the product and Azure already name. On
// v6 and v7 "disk type" also reads as the disk's own type (Premium SSD, and so
// on), which a restore does not change.
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, eq, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const page = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const manual = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'use', 'put-back.md'), 'utf8');
const copies = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'understand', 'safety-copies.md'), 'utf8');
const label = (key) => {
  const m = page.match(new RegExp(`\\b${key}:\\s*'([^']*)'`));
  if (!m) { throw new Error(`no label ${key}`); }
  return m[1];
};

// IAC-NOTE-LIST-1: ONE sentence may say it, because there it means the disk's
// own type - the meaning above that this rule keeps the word for. The note
// about machines defined in code uses the words approved on
// 2026-11-08, and a move does change the disk to Standard SSD or Premium SSD.
// Only that exact sentence is taken out; any other "disk type" still fails.
const DISK_TYPE_NOTE = "'A move can change the disk type to Standard SSD or Premium SSD.'";
test('no word on the run page says "disk type"', () => {
  ok(page.includes(DISK_TYPE_NOTE), 'the note sentence is where this test expects it');
  ok(!/disk type/i.test(page.split(DISK_TYPE_NOTE).join('')), 'the run page still says disk type');
});

// RESTORE-DIALOG-WORDS-1 changed the keys on purpose: each copy is a short
// option, its size and disk controller come from the record (restoreShape),
// and what the first copy also does is behind its ? helper.
test('each restore label names the disk controller', () => {
  for (const key of ['restoreShape', 'restorePristineHelp', 'restoredFromPristine', 'restoredFromPrepared']) {
    ok(/disk controller/.test(label(key)), `${key}: ${label(key)}`);
  }
});

test('the first copy puts the controller BACK; the second KEEPS the current one', () => {
  ok(/returns to this size and disk controller/.test(label('restorePristineHelp')), label('restorePristineHelp'));
  ok(/original size and disk controller/.test(label('restoredFromPristine')), label('restoredFromPristine'));
  ok(/current size and disk controller/.test(label('restoredFromPrepared')), label('restoredFromPrepared'));
});

test('the dialog says the restore makes a new managed disk from each snapshot and swaps it on (RESTORE-ALL-1)', () => {
  ok(/makes a new managed disk from each snapshot, swaps it onto the machine/.test(label('restoreDesc')), label('restoreDesc'));
  // SAFETY-ULTRA-1, RESTORE-DIALOG-WORDS-1: a shared disk stays; a Premium SSD
  // v2 or Ultra Disk whose copy Azure cannot use stops the restore.
  ok(/^A shared disk stays as it is\.$/.test(label('restoreShared')), label('restoreShared'));
  ok(/Premium SSD v2 or Ultra Disk now, the restore stops before it changes the machine\./.test(label('restoreInstant')), label('restoreInstant'));
  ok(!/data disks stay as they are/.test(page), 'the page still says the data disks stay');
  ok(/current managed disks/.test(label('restoreNaming')), label('restoreNaming'));
  ok(/operating system disk/.test(label('restoredDisk')), label('restoredDisk'));
  ok(/data disks/.test(label('restoredDataDisks')), label('restoredDataDisks'));
});

test('a machine with ONE copy is told so, and the delete words name the current managed disks', () => {
  ok(/only one safety copy/.test(label('restoreOnlyCopy')), label('restoreOnlyCopy'));
  ok(/current managed disks/.test(label('restoreRiskMissing')), label('restoreRiskMissing'));
  ok(/deletes these managed disks/.test(label('restoreRisk')), label('restoreRisk'));
});
// REBUILD-REMOVE-RECOVER-1: Rebuild this machine is gone (RECOVER-ALL-DISKS-1
// gave its copy choice these words), and so are its labels.
test('Rebuild this machine has no labels left', () => {
  for (const k of ['rebuildFromCopy', 'rebuildFromDisks', 'rebuildAsTarget', 'rebuildAsOriginal']) {
    ok(!new RegExp(`\\b${k}:`).test(page), `no label ${k}`);
  }
});

test('the manual says it the same way', () => {
  ok(!/disk type/i.test(manual), 'put-back.md still says disk type');
  eq((manual.match(/disk controller/g) || []).length >= 3, true, 'the choices name the disk controller');
  ok(!/new size and disk controller/.test(manual + copies), 'a copy that keeps the hardware keeps the CURRENT size');
  // RESTORE-DIALOG-WORDS-1: a restore makes a new managed disk from each
  // snapshot and swaps it on; the current disk stays unless it is deleted.
  ok(/makes a new managed disk from each snapshot/.test(copies), 'the Safety copies page says what a restore makes');
  ok(/makes a new managed disk from each snapshot/.test(manual), 'the Restore page says what a restore makes');
  ok(/operating system disk and each data disk/.test(manual) && /operating system disk and each data disk/.test(copies), 'both name every disk');
  ok(!/(Its|The) data disks stay as they are/.test(manual + copies), 'no page still says the data disks stay');
});

test('the manual never says a restore or a rollback replaces a disk, can be undone, or loses data the operator did not delete', () => {
  const moves = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'understand', 'how-a-machine-moves.md'), 'utf8');
  const words = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'understand', 'words.md'), 'utf8');
  for (const [name, text] of [['put-back.md', manual], ['safety-copies.md', copies], ['how-a-machine-moves.md', moves]]) {
    ok(!/\breplac/i.test(text), `${name} says replace`);
    // MADE-DISK-DELETE-1: the manual quotes the warning of Delete these disks
    // now, which says a delete cannot be undone - the opposite of a promise.
    const quoted = text.split('"It cannot be undone."').join(' ');
    ok(!/\bundone\b|\bundo\b/i.test(quoted), `${name} promises an undo`);
    ok(!/only versions/i.test(text), `${name} says only versions`);
    for (const sentence of text.split(/(?<=\.)\s+/).filter(x => /\blost\b/.test(x))) {
      ok(/delete|access given to the old ID/i.test(sentence), `${name}: ${sentence}`);
    }
  }
  const restoreRow = words.split('\n').find(l => l.startsWith('| Restore |'));
  ok(restoreRow && !/replac/i.test(restoreRow) && /new managed disk/.test(restoreRow), `words.md: ${restoreRow}`);
});
run('restore-labels');
