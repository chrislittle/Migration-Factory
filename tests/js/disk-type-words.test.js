/* DISK-TYPE-WORDS-1: the activity said "Premium SSD" for every disk type change.
 *
 * The page mapped every `diskType` step to the fixed words "Changing a disk to
 * Premium SSD". HDD-OS-1 added a change of a Standard HDD OS disk to Standard
 * SSD, and the lab test on 2026-10-26 showed those words for it: the operator
 * read a type that the move did not set.
 *
 * The engine now puts the type a disk type change sets on the Azure operation's
 * line (skuName), and the page names it with Azure's own name. An event with
 * no skuName (a run from before this change) gets words that are true for every
 * type. The engine's own summary line says itself, in Azure's names.
 *
 * RUN: the page's own stepText with its own tables, driven with the events the
 * engine writes; and the engine source, so the skuName cannot be dropped.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const ENGINE = path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Private', 'engine');
const DISK_TYPE = fs.readFileSync(path.join(ENGINE, 'DiskType.ps1'), 'utf8');

global.STEP_MAP      = liftConst('migrations.html', 'STEP_MAP');
global.UX_STEP       = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE      = liftConst('migrations.html', 'UX_STATE');
global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
global.SAYS_ITSELF   = liftConst('migrations.html', 'SAYS_ITSELF');
const { stepText } = liftAll('migrations.html', ['stepText']);

const ev = (step, outcome, more) => Object.assign({ tsUtc: '2026-10-26T16:00:00Z', vmId: '/x/vm1', step, outcome }, more || {});

test('RUN: a change to Standard SSD says Standard SSD, not Premium SSD', () => {
  const text = stepText(ev('azureops:diskType', 'ok', { attempt: 1, skuName: 'StandardSSD_LRS' }));
  eq(text, 'Changing a disk to Standard SSD');
  ok(!/Premium/.test(text), text);
});

test('RUN: a change to Premium SSD says Premium SSD', () => {
  eq(stepText(ev('azureops:diskType', 'ok', { attempt: 1, skuName: 'Premium_LRS' })), 'Changing a disk to Premium SSD');
  eq(stepText(ev('azureops:diskType', 'ok', { attempt: 1, skuName: 'Premium_ZRS' })), 'Changing a disk to Premium SSD (zone-redundant)');
});

test('an event with no type, or a type the page does not know, gets words true for every type', () => {
  for (const more of [{ attempt: 1 }, { attempt: 1, skuName: 'NotAType_LRS' }, { attempt: 1, skuName: '' }]) {
    const text = stepText(ev('azureops:diskType', 'ok', more));
    eq(text, 'Changing the type of a disk', JSON.stringify(more));
  }
});

test('the way back names the type the disk goes back to, or says it had one', () => {
  eq(stepText(ev('azureops:rollback:diskType', 'ok', { skuName: 'Standard_LRS' })), 'Setting a disk back to Standard HDD');
  eq(stepText(ev('azureops:restore:diskType', 'ok', { skuName: 'StandardSSD_LRS' })), 'Setting a disk back to Standard SSD');
  eq(stepText(ev('azureops:rollback:diskType', 'ok')), 'Setting a disk back to the type it had');
});

test('the read stays a read, for every way', () => {
  for (const s of ['azureops:diskTypeRead', 'azureops:rollback:diskTypeRead', 'azureops:restore:diskTypeRead']) {
    eq(stepText(ev(s, 'ok', { skuName: 'Premium_LRS' })), UX_STEP.readDiskType, s);
  }
});

test('the engine summary line says itself, and with no detail it names no type', () => {
  const done = "The disk types are changed: 'vm1-os' Standard HDD to Standard SSD.";
  eq(stepText(ev('diskType', 'ok', { detail: done })), done);
  const shared = "The disk 'vm1-data0' keeps the type Standard SSD. It is a shared disk (maxShares 2), and other machines use it.";
  eq(stepText(ev('diskType', 'warn', { detail: shared })), shared);
  ok(!/Premium/.test(stepText(ev('diskType', 'ok'))), 'no detail: no type named');
});

test('no disk type words on the page name one type for every change', () => {
  for (const k of ['setDiskType', 'setDiskTypeBack', 'readDiskType']) {
    ok(!/Premium|Standard|HDD/.test(UX_STEP[k]), `${k}: ${UX_STEP[k]}`);
  }
});

test('the engine puts the type it sets on each disk type change it makes', () => {
  ok(/-Name 'diskType'[^\n]*-EventData @\{ skuName = \$c\.to \}/.test(DISK_TYPE), 'the move names the type it sets');
  ok(/-Name "\$\(\$Kind\):diskType"[^\n]*-EventData @\{ skuName = \[string\]\$last\.from \}/.test(DISK_TYPE), 'the way back names the type it sets back');
});

run('disk-type-words');
