/* STOP-HEADLINE-CHECK-1, 2026-11-06 (lab Session A, finding 45). A machine
 * that rolled back after a check on its new size failed showed the title
 * "The machine started but did not pass its health checks", the general
 * meaning, and then the check that failed in muted small print at the
 * bottom of the stop box. The check is the one fact a person acts on.
 *
 * A reason whose stop names the failed check (detailFirst in
 * stop-reasons.json) puts the check's own sentence directly under the title,
 * in normal text - no guessed cause, no code. Only a sentence written for an
 * operator moves (stopCheckSentence): the engine writes the stop as one
 * string, and its why can be raw text ("Guest validation FAILED: ...") or an
 * error of Azure. Those keep the old layout: the whole detail at the bottom.
 *
 * Fix round 1: every stop here is the string the engine writes. Each part is
 * held to the engine's source, so a change of wording there fails this file.
 *
 * RUN, not read: the page's own stopCheckSentence and whyStoppedCard, with the
 * engine's own table.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const PAGE = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
const read = (...p) => fs.readFileSync(path.join(REPO, ...p), 'utf8');
const SM = read('src', 'VmMigrationFactory', 'Private', 'engine', 'StateMachine.ps1');
const IMDS_SRC = read('src', 'VmMigrationFactory', 'Private', 'validate', 'ImdsCheck.ps1');
const ANW_SRC = read('src', 'VmMigrationFactory', 'Private', 'engine', 'AnAdapterWait.ps1');
const table = JSON.parse(read('src', 'VmMigrationFactory', 'data', 'stop-reasons.json'));
// eslint-disable-next-line no-eval
globalThis.PROBLEM_STATES = eval(PAGE.match(/const PROBLEM_STATES = (\[[^\]]+\]);/)[1]);
globalThis.UX_ACT = liftConst('migrations.html', 'UX_ACT');
globalThis.esc = (s) => String(s ?? '');
globalThis.canApprove = () => true;
globalThis.stopReasons = new Map(table.reasons.map(r => [r.code, r]));
globalThis.retryLines = table.retryLines;
globalThis.STOP_CHECK = liftConst('migrations.html', 'STOP_CHECK');
const card = liftAll('migrations.html', ['powerOwed', 'attemptStop', 'currentStop', 'stopCheckSentence', 'whyStoppedCard']);

// The engine's own strings. Complete-VmfRollback writes the stop of a full
// rollback as "The $stepWord step failed, and the product rolled the machine back
// to how it was: $why$powerNote$keptNote" (MANUAL-REVIEW-1: the step as the pages name it).
const WRAP = 'The Verifying step failed, and the product rolled the machine back to how it was: ';
const wrap = (why, notes = '') => WRAP + why + notes;
// Test-VmfImdsOutcome: the two failures.
const IMDS = 'The Instance Metadata Service answered before the move and does not answer now. It answers only on the primary network interface, so that interface does not work as it did before the move.';
const SIZE = "The machine reports the size Standard_D4s_v5, and the plan's target is Standard_D4s_v6.";
// AN-AMDV7-VF-GAP-1: Wait-VmfAcceleratedAdapter, when the wait for the adapter ran out.
const ANW = 'The accelerated networking adapter did not become ready in 15 minutes. The product checked it 32 times, and found no MANA interface and no SR-IOV virtual function.';
// AN-TRAFFIC-VERIFY-1: Wait-VmfAcceleratedAdapter, when the adapter was present and carried no traffic for the whole wait.
const ANT = 'The accelerated networking adapter is present, but its packet counters showed no traffic in 15 minutes. The product checked it 31 times.';
// Invoke-VmfStepValidating: raw throws that are not written for an operator.
const GUEST = 'These checks inside the machine failed: nvme-boot, fstab-nofail.';
const BUS = "The checks inside the machine report the boot disk on 'SCSI', and the disk controller of the target is NVMe.";
// An error of Azure thrown in VALIDATING (the names are contoso placeholders).
const AZURE = "(ResourceNotFound) The Resource 'Microsoft.Compute/virtualMachines/contoso-vm' under resource group 'contoso-rg' was not found.";
// Complete-VmfRollback's notes.
const POWER = ' The start after the rollback failed (Operation timed out) - the machine is stopped (deallocated).';
const KEPT = " The rollback did not restore these data disks, and each keeps the disk it had: LUN 0 'data0': Azure refused the attach.";

test('each string here is the engine\'s own', () => {
  ok(SM.includes('"The $stepWord step failed, and the product rolled the machine back to how it was: $why$powerNote$keptNote"'), 'the stop of a full rollback');
  ok(SM.includes("VALIDATING = 'Verifying'"), 'the step word of VALIDATING');
  ok(SM.includes("elseif ($state -eq 'VALIDATING') { 'validationFailedAfterConversion' }"), 'a failure of VALIDATING is this reason');
  ok(IMDS_SRC.includes(`Detail = '${IMDS}'`), 'the IMDS sentence');
  ok(IMDS_SRC.includes('Detail = "The machine reports the size $($After.vmSize), and the plan\'s target is $TargetSize."'), 'the size sentence');
  ok(ANW_SRC.includes('throw "The accelerated networking adapter did not become ready in $minutes minutes. The product checked it $($wait.reads) times, and found no MANA interface and no SR-IOV virtual function."'), 'the adapter wait sentence');
  ok(ANW_SRC.includes('throw "The accelerated networking adapter is present, but its packet counters showed no traffic in $minutes minutes. The product checked it $($wait.reads) times."'), 'the no-traffic sentence');
  ok(SM.includes('Wait-VmfAcceleratedAdapter -Context $Context'), 'VALIDATING waits for the adapter');
  ok(SM.includes('throw "These checks inside the machine failed: $failed."'), 'the guest throw');
  ok(SM.includes("throw \"The checks inside the machine report the boot disk on '$($busCheck.detail)', and the disk controller of the target is $($Context.Plan.target.controller).\""), 'the boot bus throw');
  ok(SM.includes('$powerNote = " The start after the rollback failed ($($_.Exception.Message)) - $($restore.Detail)."'), 'the power note');
  ok(SM.includes('" The rollback did not restore these data disks, and each keeps the disk it had: $('), 'the data disk note');
  eq(globalThis.STOP_CHECK.prefix, WRAP, 'the page reads the same prefix');
});

const rolledBack = (code, detail) => ({ state: 'FAILED_ROLLED_BACK', history: [
  { tsUtc: '2026-11-06T10:00:00Z', state: 'VALIDATING', outcome: 'fail' },
  { tsUtc: '2026-11-06T10:05:00Z', state: 'FAILED_ROLLED_BACK', outcome: 'fail', machineState: 'restored', reasonCode: code, detail }] });
// The parts of the stop box, in order: each innermost b, p or div whose text a
// person reads (the card and its body hold the others, so they are skipped).
const parts = (html) => [...html.matchAll(/<(b|p|div)\b([^>]*)>((?:(?!<div|<p\b)[\s\S])*?)<\/\1>/g)]
  .map(m => ({ tag: m[1], attrs: m[2], text: m[3].replace(/<[^>]*>/g, '').trim() }))
  .filter(x => x.text);
const g = () => stopReasons.get('validationFailedAfterConversion');
const underTitle = (html) => { const l = parts(html); const at = l.findIndex(x => x.text === g().title); return l[at + 1]; };
const last = (html) => { const l = parts(html); return l[l.length - 1]; };

test('stopCheckSentence: the operator sentence of each IMDS failure, and the notes after it', () => {
  eq(JSON.stringify(card.stopCheckSentence(wrap(IMDS))), JSON.stringify({ check: IMDS, rest: '' }));
  eq(JSON.stringify(card.stopCheckSentence(wrap(SIZE))), JSON.stringify({ check: SIZE, rest: '' }));
  eq(JSON.stringify(card.stopCheckSentence(wrap(ANW))), JSON.stringify({ check: ANW, rest: '' }));
  eq(JSON.stringify(card.stopCheckSentence(wrap(ANW, POWER))), JSON.stringify({ check: ANW, rest: POWER.trim() }));
  eq(JSON.stringify(card.stopCheckSentence(wrap(IMDS, POWER + KEPT))), JSON.stringify({ check: IMDS, rest: (POWER + KEPT).trim() }));
});

test('stopCheckSentence: raw text, an error of Azure and anything not known give null', () => {
  for (const d of [wrap(GUEST), wrap(BUS), wrap(AZURE), wrap(GUEST, POWER), IMDS, '', undefined, null,
    'The Starting up step failed, and the product rolled the machine back to how it was: ' + IMDS,
    'The Verifying step failed after the preparation changed the machine. The product rolled the machine back from the first safety copy: ' + IMDS,
    // Another text of the same length as the prefix, and a known sentence inside raw text.
    'x'.repeat(WRAP.length) + IMDS, wrap('These checks inside the machine failed: ' + SIZE), wrap('Error: ' + IMDS)]) {
    eq(card.stopCheckSentence(d), null, String(d));
  }
});

test('the failed IMDS check: its sentence comes directly under the title, in normal text, before the meaning', () => {
  const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', wrap(IMDS)));
  const next = underTitle(html);
  eq(next.text, IMDS, 'the check is the next thing a person reads');
  eq(next.tag, 'p', 'a paragraph of its own');
  ok(!/muted/.test(next.attrs), `normal text, not small print: ${next.attrs}`);
  const l = parts(html);
  ok(l.findIndex(x => x.text === g().meaning) > l.findIndex(x => x.text === IMDS), 'the meaning comes after the check');
  eq(html.split(IMDS).length - 1, 1, 'said once');
  ok(!html.includes(WRAP.trim()), 'the engine\'s wrapper is not shown: the title and the state line say it');
});

test('AN-AMDV7-VF-GAP-1: the wait for the adapter that ran out comes directly under the title, in normal text', () => {
  const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', wrap(ANW, POWER)));
  const next = underTitle(html);
  eq(next.text, ANW, 'the wait is the next thing a person reads');
  ok(!/muted/.test(next.attrs), `normal text: ${next.attrs}`);
  eq(html.split(ANW).length - 1, 1, 'said once');
  eq(last(html).text, POWER.trim(), 'the note stays at the bottom');
});
test('AN-TRAFFIC-VERIFY-1: an adapter that carried no traffic comes directly under the title, in normal text', () => {
  eq(JSON.stringify(card.stopCheckSentence(wrap(ANT))), JSON.stringify({ check: ANT, rest: '' }));
  eq(JSON.stringify(card.stopCheckSentence(wrap(ANT, POWER))), JSON.stringify({ check: ANT, rest: POWER.trim() }));
  const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', wrap(ANT, POWER)));
  const next = underTitle(html);
  eq(next.text, ANT, 'the no-traffic stop is the next thing a person reads');
  ok(!/muted/.test(next.attrs), `normal text: ${next.attrs}`);
  eq(html.split(ANT).length - 1, 1, 'said once');
  eq(last(html).text, POWER.trim(), 'the note stays at the bottom');
});
test('the notes on the power state and the data disks stay at the bottom, in small print', () => {
  const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', wrap(IMDS, POWER + KEPT)));
  eq(underTitle(html).text, IMDS);
  const end = last(html);
  eq(end.text, (POWER + KEPT).trim(), 'the notes');
  ok(/muted/.test(end.attrs), 'small print');
  eq(html.split(IMDS).length - 1, 1, 'the check is not in the notes');
});

for (const [name, why] of [['a check inside the machine', GUEST], ['the boot bus', BUS], ['an error of Azure', AZURE]]) {
  test(`${name}: nothing moves under the title, and the whole detail stays at the bottom in small print`, () => {
    const detail = wrap(why, POWER);
    const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', detail));
    eq(underTitle(html).text, g().meaning, 'the meaning is under the title, as before');
    const end = last(html);
    eq(end.text, detail, 'the whole detail');
    ok(/muted/.test(end.attrs), 'small print');
  });
}

test('no guessed cause and no code in the text a person reads', () => {
  const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', wrap(IMDS)));
  const visible = html.replace(/<[^>]*>/g, ' ');
  ok(!/often causes this/i.test(visible), visible);
  ok(!visible.includes('validationFailedAfterConversion'), visible);
  ok(html.includes('title="validationFailedAfterConversion"'), 'the code stays on the title, for the technical record');
});

test('a stop with no detail draws no empty line', () => {
  const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', undefined));
  ok(!/<(p|div)\b[^>]*>\s*<\/\1>/.test(html), html);
  eq(underTitle(html).text, g().meaning);
});

test('the check and the notes are escaped where they are drawn', () => {
  const seen = [];
  const before = globalThis.esc;
  globalThis.esc = (s) => { seen.push(String(s ?? '')); return String(s ?? '').replace(/</g, '&lt;'); };
  try {
    const html = card.whyStoppedCard(rolledBack('validationFailedAfterConversion', wrap(IMDS, ' <img src=x>')));
    ok(!html.includes('<img'), html);
    ok(seen.includes(IMDS) && seen.includes('<img src=x>'), 'both went through esc');
  } finally { globalThis.esc = before; }
});

test('a reason that does not name the failed check keeps its detail at the bottom, also with an IMDS sentence in it', () => {
  const detail = 'STARTING failed; the machine was rolled back to how it was: ' + IMDS;
  const html = card.whyStoppedCard(rolledBack('bootFailedAfterConversion', detail));
  const end = last(html);
  eq(end.text, detail, 'the last line');
  ok(/muted/.test(end.attrs), 'small print, as before');
  const html2 = card.whyStoppedCard(rolledBack('rolledBack', wrap(IMDS)));
  eq(last(html2).text, wrap(IMDS), 'no detailFirst: as before');
});

test('the table: each reason whose meaning says that the stop names the check carries detailFirst, and only those', () => {
  const names = table.reasons.filter(r => /the stop names that check/i.test(r.meaning)).map(r => r.code).sort();
  const flagged = table.reasons.filter(r => r.detailFirst === true).map(r => r.code).sort();
  ok(names.includes('validationFailedAfterConversion'), 'the health check reason says so');
  eq(JSON.stringify(flagged), JSON.stringify(names));
  ok(table.reasons.every(r => r.detailFirst === undefined || r.detailFirst === true), 'true or absent');
  ok(typeof table.detailFirstWhy === 'string' && table.detailFirstWhy.length > 0, 'the table says why');
});

test('the sample machine prd-lin-c carries the stop as the engine writes it', () => {
  ok(PAGE.includes(`detail: '${wrap(IMDS)}'`), 'the demo detail is the wrapped string');
});

run('stop-headline-check');
