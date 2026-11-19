/* STEP-WORDS-1, 2026-09-22. Found by a census while fixing one heading in
 * BLOCKED-NAME-1, and the census was the point: fixing one heading fixes an
 * instance.
 *
 * TWELVE STEPS REACHED THE ACTIVITY LOG AS THE RAW ENGINE WORD - "rearm",
 * "claim", "acknowledgement", "driverCheck". stepText is the ONLY text in an
 * activity row; e.detail reaches a person nowhere but the tooltip. So a row
 * said, in full:
 *
 *     approval
 *
 * while the sentence the engine wrote beside it - "wave prod-1 approved by
 * <person>: <their note>" - was one line away and never shown.
 *
 * THE FIX IS NOT TWELVE LABELS. A label REPLACES the detail, so "An operator
 * approved a wave" would still throw away who approved it and what they said.
 * Every one of these steps records what a PERSON did, and the engine already
 * writes a whole sentence saying who and why. The driver check's own contract
 * says it in as many words: `Detail = <plain language>`.
 *
 * So they say what they say - the same rule LOG-SAYS-WHY-1 applied to a
 * refusal: a label is a convenience for a step nobody has to act on, and an
 * audit trail that hides who did something behind a generic heading is worse
 * than no heading at all.
 *
 * The labels below are the fallback for an event that carries no detail, so
 * the raw engine word can never come back.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const { stepText } = liftAll('migrations.html', ['stepText']);
global.STEP_MAP      = liftConst('migrations.html', 'STEP_MAP');
global.UX_STEP       = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE      = liftConst('migrations.html', 'UX_STATE');
global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
global.SAYS_ITSELF   = liftConst('migrations.html', 'SAYS_ITSELF');

// What the engine really writes, taken from the calls in its own source.
const REAL = [
  ['acceptance',      "wave 'prod-1' options accepted by <operator> (3 machine(s))"],
  ['acknowledgement', 'infrastructure-as-code drift acknowledged by <operator>'],
  ['approval',        'wave prod-1 approved by <operator>: <their note>'],
  ['claim',           "released from the run 'run-7' by <operator>: <their reason>"],
  ['driverCheck',     'INFO: this machine has no accelerated network adapter'],
  ['precheck',        'This machine shares an availability set with 3 other machines'],
  ['rearm',           'The next attempt starts again at Moving. Earlier attempts are not counted against it.'],
  ['retention',       'The daily cleanup deleted the 2 safety copies of this machine. It was migrated 8 days ago, and its wave keeps copies for 7 days.'],
  ['run',             'run stopped by <operator>: <their reason> (4 machines closed out)'],
  ['schedule',        'wave prod-1 scheduled for 2026-09-23 22:00:00Z by <operator>'],
];

test('the page tables really were lifted, so this cannot pass by reading nothing', () => {
  ok(Object.keys(global.UX_STEP).length > 20, 'UX_STEP');
  ok(Object.keys(global.SAYS_ITSELF).length >= 11, 'SAYS_ITSELF');
});

test('<step> says what the engine wrote, not its own name', () => {
  for (const [step, detail] of REAL) {
    const said = stepText({ step, outcome: 'ok', detail });
    ok(said !== step, `${step} still reads as the raw engine word`);
    eq(said, detail, step);
  }
});

test('so who did it survives, which is the whole point of an audit trail', () => {
  // The placeholders are deliberate. CLAUDE.md rule 13: invented but
  // real-looking prose feels most natural exactly where it is worst - an
  // approval, an audit trail, a who-did-what record - and this fixture is
  // all three.
  const said = stepText({ step: 'approval', outcome: 'ok',
                          detail: 'wave prod-1 approved by <operator>: <their note>' });
  ok(/approved by <operator>/.test(said), 'the person must survive');
  ok(/<their note>/.test(said), 'their note must survive');
});

test('and an event with no detail still never shows the engine word', () => {
  // The fallback. Without it, an event that carried no sentence would put the
  // raw name straight back in the feed.
  for (const [step] of REAL) {
    for (const nothing of ['', null, undefined]) {
      const said = stepText({ step, outcome: 'ok', detail: nothing });
      ok(said !== step, `${step} with no detail fell back to its own name`);
      ok(said && said !== 'undefined', `${step} with no detail rendered as '${said}'`);
      ok(/\s/.test(said), `${step} fell back to one token: '${said}'`);
    }
  }
});

test('a failure still shows its reason, as LOG-SAYS-WHY-1 requires', () => {
  const said = stepText({ step: 'retention', outcome: 'fail',
                          detail: 'the cleanup did not complete: the disk was not found' });
  ok(/the disk was not found/.test(said), 'the reason must survive a failure too');
});

test('and the steps that already had a heading keep it', () => {
  // This must not become "show the detail for everything". Engine text is
  // what a heading is for - but QUOTA-TRUTH-1: a finished quota check is
  // TRANSLATED into its result, because the heading hid a check that counted
  // nothing. Any other capacity line keeps the heading.
  eq(stepText({ step: 'capacity', outcome: 'ok', detail: 'claims=2 blocked=0' }),
     'Quota check for the whole plan: 2 sizes checked, and each has enough quota.');
  eq(stepText({ step: 'capacity', outcome: 'ok', detail: 'claims=0 blocked=0 wave=dev-wave machines=0 moving=0' }),
     'Quota check for wave dev-wave: the saved plan has no machine here that changes size.');
  eq(stepText({ step: 'capacity', outcome: 'warn', detail: 'claims=3 blocked=1 wave=w1 machines=3 moving=3' }),
     'Quota check for wave w1: 1 of 3 sizes do not have enough quota.');
  eq(stepText({ step: 'capacity', outcome: 'ok', detail: 'engine text' }), 'Quota and capacity');
  eq(stepText({ step: 'plan', outcome: 'ok', detail: 'x' }), 'Planning and assessment');
});

test('a quota NOTE shows its sentence, not the heading', () => {
  // PLAIN-LOG-1, 2026-09-25: the line read only "Quota and capacity",
  // and what it meant was behind a hover.
  const said = 'The waves changed, so the earlier quota check for wave w1 no longer matched them and was removed.';
  eq(stepText({ step: 'capacity', outcome: 'warn', detail: said }), said);
});

test('the engine writes that note in the product\'s words, not its internal names', () => {
  // "unscheduled" is the internal name for machines not in a wave yet.
  const fs = require('fs'), path = require('path');
  const src = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Public', 'Set-VmfWavePlan.ps1'), 'utf8');
  // Anchored on this note's own sentence: the save writes another capacity
  // warning too (PLAN-WRITE-RACE-1).
  const at = src.indexOf('no longer matched them and was removed');
  const block = src.slice(src.lastIndexOf('$named = ', at), at + 400);
  ok(/'the machines not in a wave'/.test(block), 'the internal wave name is said in words');
  ok(!/quota checks cleared/.test(block), 'the old engine wording is gone');
});

test('every fallback label the map points at is one the page declares', () => {
  for (const id of Object.values(global.SAYS_ITSELF)) {
    ok(Object.prototype.hasOwnProperty.call(global.UX_STEP, id), `UX_STEP is missing '${id}'`);
  }
});

run('step-words');
