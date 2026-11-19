/* REBUILD-REMOVE-DOCS-1: the samples and the words of the pages say that
 * every move is in place.
 *
 * The owner removed the rebuild around the same disks (Path B) on 2026-11-07.
 * No plan, no target option and no restore rebuilds a machine any more, and
 * the custom role no longer holds the right to delete or create one
 * (REBUILD-REMOVE-ROLE-1). But the sample behind migrations.html?demo and
 * waves.html?demo still held four and two machines planned on Path B - which
 * the manual's pictures are taken from - and five strings still said the
 * product rebuilds a machine. These tests read the samples the pages hold and
 * the strings they declare, so a sample or a word that brings the rebuild
 * back fails here.
 */
'use strict';
const { migrationsDemo, copy } = require('./_sample-run');
const { bootPage } = require('./_dom');
const { liftConst, test, eq, ok, run } = require('./_harness');

const nameOf = (id) => String(id).split('/').pop();

/* The sample of the Migrations page, as sample-counts.test.js reads it.
 * WAVE-SAMPLE-RUN-1: its plan is VmfHelp.sampleRun (help.js), and the wave
 * editor shows the same plan, so the tests of the wave editor's sample below
 * read the page booted in demo mode (wave-sample-run.test.js holds the two
 * equal). */
function wavesSample() {
  return copy(bootPage('waves.html').sandbox, 'DEMO_PLAN');
}

const MIG = migrationsDemo();
const PLAN = MIG['plan.json'];
const WAVES = wavesSample();

test('no machine of the Migrations sample is planned on the rebuild', () => {
  const rebuilt = PLAN.entries.filter(e => e.path === 'B').map(e => nameOf(e.vmId));
  eq(rebuilt.join(', '), '', 'machines planned with path B');
  ok(PLAN.entries.filter(e => e.path === 'A').length >= 8, 'the sample still moves its machines');
});

test('a Windows machine of the Migrations sample that changes its temporary disk moves by the in-place upgrade (Preview)', () => {
  // D2ds_v4, D4ds_v4 and E2bds_v5 have a SCSI temporary disk, D2ds_v6, D4ds_v6
  // and E2bds_v6 an NVMe one: Get-VmfMoveMethod gives preview, and the plan
  // records it.
  for (const n of ['can-win-a', 'prd-win-a', 'prd-win-b', 'prd-ebs-a', 'prd-tmp-a']) {
    const e = PLAN.entries.find(x => nameOf(x.vmId) === n);
    ok(e, `${n} is in the sample plan`);
    eq(e.path, 'A', `${n} path`);
    eq(e.target?.choice?.method, 'preview', `${n} method`);
  }
});

test('no machine of the Migrations sample carries the fields of a rebuild', () => {
  for (const e of PLAN.entries) {
    ok(!('rebuildLinks' in (e.assessment ?? {})), `${nameOf(e.vmId)} has no rebuildLinks`);
    for (const note of e.planNotes ?? []) { ok(!/rebuil/i.test(note), `${nameOf(e.vmId)} note: ${note}`); }
  }
});

test('no state document of the Migrations sample is at a checkpoint of the rebuild', () => {
  for (const [file, doc] of Object.entries(MIG)) {
    if (!file.startsWith('state/')) continue;
    ok(!/^B:/.test(String(doc.pathCheckpoint ?? '')), `${file} checkpoint ${doc.pathCheckpoint}`);
  }
});

test('the encrypted machine of the Migrations sample gives the reason the plan writes now', () => {
  const e = PLAN.entries.find(x => nameOf(x.vmId) === 'old-enc-a');
  eq(e.path, 'MANUAL', 'old-enc-a path');
  ok((e.planNotes ?? []).some(n => /Azure Disk Encryption/.test(n) && /in-place upgrade \(Preview\)/.test(n)),
    'the note names Azure Disk Encryption and the in-place upgrade (Preview)');
});

test('no machine of the wave editor sample is planned on the rebuild', () => {
  const rebuilt = WAVES.entries.filter(e => e.path === 'B').map(e => nameOf(e.vmId));
  eq(rebuilt.join(', '), '', 'machines planned with path B');
});

test('the Windows machines of the wave editor sample that change their temporary disk move by the in-place upgrade (Preview)', () => {
  // WAVE-SAMPLE-RUN-1: the sample plan of the Migrations page, shown by the
  // wave editor. D2ds_v4, D4ds_v4 and E2bds_v5 have a SCSI temporary disk.
  for (const n of ['can-win-a', 'prd-win-a', 'prd-win-b', 'prd-ebs-a', 'prd-tmp-a']) {
    const e = WAVES.entries.find(x => nameOf(x.vmId) === n);
    ok(e, `${n} is in the sample plan`);
    eq(e.path, 'A', `${n} path`);
    eq(e.assessment.os, 'Windows', `${n} operating system`);
    eq(e.target?.choice?.method, 'preview', `${n} method`);
  }
  // The machines that move by the plain in-place upgrade record no Preview:
  // a Linux machine.
  for (const n of ['can-lin-a', 'prd-lin-c']) {
    const e = WAVES.entries.find(x => nameOf(x.vmId) === n);
    ok(e, `${n} is in the sample plan`);
    ok(e.target?.choice?.method !== 'preview', `${n} is not a Preview move`);
  }
});

test('the strings that say what the product may do to a machine say stop and resize, not rebuild', () => {
  const access = liftConst('access.html', 'UX');
  const waves = liftConst('waves.html', 'UX');
  for (const [where, s] of [['access scopeMigrate', access.scopeMigrate], ['waves quotaNoAccess', waves.quotaNoAccess]]) {
    ok(typeof s === 'string' && s.length > 0, `${where} is declared`);
    ok(!/rebuil/i.test(s), `${where}: ${s}`);
    ok(/resize/.test(s), `${where} still says resize`);
  }
});

test('OLD-REBUILD-RESTORE-READERS-1: no status of a rebuild', () => {
  const misc = liftConst('migrations.html', 'UX_MISC');
  ok(!('statusRebuilding' in misc) && !('statusRebuildingTip' in misc), 'no Rebuilding');
});

test('the strings about disks and records do not say that a machine is rebuilt now', () => {
  const copies = liftConst('migrations.html', 'UX_COPIES');
  const act = liftConst('migrations.html', 'UX_ACT');
  const reports = liftConst('reports.html', 'UX');
  for (const [where, s] of [['statusRestoreRuns', copies.statusRestoreRuns], ['statusRestoreStopped', copies.statusRestoreStopped],
    ['discardCopies', act.discardCopies], ['recordsNone', reports.recordsNone]]) {
    ok(typeof s === 'string' && s.length > 0, `${where} is declared`);
    ok(!/rebuil/i.test(s), `${where}: ${s}`);
  }
});

run('rebuild-remove-docs');
