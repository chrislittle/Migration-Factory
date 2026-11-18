/* WAVE-GATE-1: two buttons on the run page that cannot work.
 *
 * Seen during a migration run, with wave-2 showing "In progress" and three
 * machines mid-shutdown: the wave was running, but Start this wave was not
 * blocked.
 *
 * And the group holding two machines the planner could not place looked like
 * a random leftover: every machine was added by resource group in the plan,
 * yet two sat in no wave, as if they had slipped through.
 *
 * They did not slip through. `New-VmfPlan` gives a wave only to a machine
 * with an executable path, and everything else it parks in the wave
 * `'unscheduled'` - which is correct, and is what "Manual review" means in the
 * table. What is wrong is what the page then offers.
 *
 * BOTH ARE THE SAME DEFECT, one gate apart, and it is the one written in the
 * comment beside this code: gate on what the ENGINE gates on, and say why the
 * button is not there. It was pointed at acceptance, then at approval, then at
 * the acknowledgement. It was never pointed at:
 *
 *   1. A WAVE ALREADY RUNNING. `startBlockedBy` asks three questions and never
 *      asks whether the wave is working right now. `waveDone` only hides Start
 *      once every machine has FINISHED, so a wave in flight falls between the
 *      two. Pressing it starts a second engine container: machine leases are
 *      exclusive so nothing is corrupted, but it picks up the machines not yet
 *      started and runs more at once than the wave was set to.
 *
 *   2. A WAVE NOBODY CAN RUN. Every guard on the group reads
 *      `wave !== 'unplanned'`. The planner's word is `'unscheduled'`. Two
 *      spellings of the same idea and the guards know only one - so Accept,
 *      Approve and Start were all offered on machines that can never run.
 *      `waveLabel` knew both spellings all along, which is why the group is
 *      LABELLED correctly and gated wrongly.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, eq, run } = require('./_harness');

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));

test('one function decides what "not in a wave" means', () => {
  /* The label knew `unscheduled` and `unplanned`; every guard knew only one of
   * them. Two readings of the same question is how they come to disagree, so
   * there is one now and both callers use it. */
  const at = PAGE.search(/(?:const|function) isUnplannedWave/);
  ok(at >= 0, 'there must be one test for "this is not a real wave"');
  // The DEFINITION, not the first mention - the callers appear earlier in the
  // file than it does.
  const fn = PAGE.slice(at, at + 260);
  ok(/unscheduled/.test(fn) && /unplanned/.test(fn),
    'and it must know BOTH words the product writes');
});

test('and no guard spells it out for itself any more', () => {
  // THE DEFECT ITSELF. A guard that hardcodes one word is a guard that misses
  // the other.
  ok(!/wave !== 'unplanned'/.test(PAGE),
    'no button may test one spelling of it by hand');
});

test('a wave nobody can run offers no Accept, Approve or Start', () => {
  // Bounded from the first button to the end of the block that draws them.
  // `// RUNPAGE-1` also appears EARLIER in the file, so the end marker is
  // searched from the start point rather than from zero - a slice that ran
  // backwards came out empty and the check reported the buttons missing.
  const from = PAGE.indexOf('const acceptBtn =');
  const opts = PAGE.slice(from, PAGE.indexOf('// RUNPAGE-1', from));
  ok(opts.length > 200, 'the block that draws the wave buttons must be found');
  for (const which of ['acceptBtn', 'approveBtn']) {
    const at = opts.indexOf(`const ${which} =`);
    ok(at >= 0, `${which} must be on this page`);
    ok(/isUnplannedWave/.test(opts.slice(at, at + 420)),
      `${which} must be withheld from a wave nobody can run`);
  }
  /* START HAS TWO BRANCHES - the button, and the muted line that replaces it
   * when a gate is unsatisfied - and BOTH must be withheld from a group
   * nobody can run. Found by mutation: dropping the guard from the button
   * left it on the other branch, near enough for a window to match, and the
   * check passed while the button was back.
   * LAB-UX-1: the card's start control is waveStartHtml now, so it is RUN
   * for both branches rather than read. */
  ok(/const startBtn = waveStartHtml\(wave, info\.entries, \{/.test(opts), 'the card asks waveStartHtml');
  const lift2 = require('./_harness').liftAll;
  Object.assign(globalThis, { allVms: [], NOT_STARTED_STATE: 'PLANNED', planDoc: { entries: [] }, planRunStatus: null,
    SETTLED_STATES: ['MIGRATED', 'SKIPPED', 'NEEDS_DECISION', 'FAILED_ROLLED_BACK', 'FAILED_NEEDS_ATTENTION'],
    planFollowText: () => null, canOperate: () => true, esc: (s) => String(s ?? ''),
    UX_ACT: { startWave: 'Start' } });
  const s = lift2('migrations.html', ['settledAll', 'vmStateOf', 'waveStartHtml']);
  const e = [{ vmId: 'u1', wave: 'unplanned', path: 'A' }];
  const base = { planCovers: false, waveWorking: false, waveDone: false, halted: false, sched: null };
  globalThis.isUnplannedWave = (w) => w === 'unplanned';
  eq(s.waveStartHtml('unplanned', e, Object.assign({ startBlockedBy: null }, base)), '', 'no Start button');
  eq(s.waveStartHtml('unplanned', e, Object.assign({ startBlockedBy: 'a gate' }, base)), '', 'and no reason line');
  ok(s.waveStartHtml('w1', [{ vmId: 'x', wave: 'w1', path: 'A' }], Object.assign({ startBlockedBy: null }, base)).includes('data-start'), 'a real wave still has Start');
});

test('and it says what it IS, rather than that something is missing', () => {
  /* "Not in a wave yet" reads as an oversight - as if two machines had
   * slipped through. Nothing slipped: the planner parked them because
   * no migration path could be chosen. The card says that now, and it does
   * not wear chips that name steps which would not help: no acceptance chip,
   * no "waiting for approval", and no status pill saying it is waiting to
   * start, because it is not. */
  const m = PAGE.match(/notInAWave: *'([^']*)'/);
  ok(m, 'the group needs a name');
  ok(!/wave/i.test(m[1]), 'which does not call it a wave that is missing one');
  ok(/notInAWaveWhy/.test(PAGE), 'and a sentence saying why it is there');
  // From the header, then forward to ITS closing tag. Searching for the end
  // marker from zero finds an earlier one and the slice comes out empty -
  // which is a check that reads nothing and reports a failure it never
  // measured. Second time in this file; the first was the button block.
  const hAt = PAGE.indexOf('<h2>${esc(waveLabel(wave))}');
  ok(hAt >= 0, 'the wave header must be found');
  const head = PAGE.slice(hAt, PAGE.indexOf('</h2>', hAt));
  ok(/isUnplannedWave\(wave\)/.test(head), 'the header must tell the two kinds apart');
  const chip = PAGE.slice(PAGE.indexOf('const apprChip ='), PAGE.indexOf('const waveDone'));
  ok(/isUnplannedWave\(wave\)/.test(chip),
    'a group nobody can run is not waiting for an approval');
});

test('a wave that is already running offers no Start', () => {
  const expr = PAGE.match(/const startBlockedBy =[\s\S]*?;/)[0];
  ok(/waveWorking|waveIsWorking/.test(expr),
    'the page must ask whether this wave is working right now');
});

test('and it says so FIRST, because nothing earlier can be unsatisfied', () => {
  /* ACK-GATE-1's rule is that gates are named in the order the engine checks
   * them, so nobody is sent to fix the wrong thing. "Already running" is not a
   * gate you go and satisfy - and a wave cannot be running unless every gate
   * before it already passed, so naming it first cannot mislead. */
  const expr = PAGE.match(/const startBlockedBy =[\s\S]*?;/)[0];
  const workingAt = expr.search(/waveWorking|waveIsWorking/);
  const ackAt = expr.indexOf('runAcknowledged');
  ok(workingAt >= 0 && ackAt > workingAt,
    'the wave being in flight is named before the gates it has already passed');
});

test('the words say it is running, not that something is missing', () => {
  // The other three sentences tell a person what to go and do. This one is a
  // state to wait out, and saying "review and accept" for it would send
  // somebody to fix a thing that is not broken.
  const m = PAGE.match(/startAlreadyRunning: *'([^']*)'/);
  ok(m, 'it needs words of its own');
  ok(!/accept|approve|sign off/i.test(m[1]),
    'it must not read as a gate somebody has to satisfy');
});

test('the bucket for machines with no plan entry is FILLED, not just made', () => {
  /* Found reading it, not reported: the loop that collects machines with a
   * state record and no plan entry creates the bucket and never pushes the
   * machine into it. So it can draw an empty "Not in a wave yet" card. */
  // NOT-IN-WAVE-QUEUED-1: the loop is in waveGroups now, over the documents it
  // is given; tests/js/not-in-wave-queued.test.js runs it.
  const from = PAGE.indexOf('for (const v of docOf.values())');
  ok(from >= 0, 'the loop over the state documents is found');
  const loop = PAGE.slice(from, PAGE.indexOf('const rank = VmfHelp.waveOrder(plan);', from));
  ok(/\.entries\.push\(/.test(loop),
    'a machine with no plan entry must go INTO the bucket that was made for it');
});

run('wave gate');
