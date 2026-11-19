/* LOG-SAYS-WHY-1, 2026-09-21. Found while watching a live run.
 *
 * TWO RED ROWS, NEITHER OF THEM HONEST.
 *
 * The first said "this failed" for a capacity gate REFUSING a wave that had
 * no reserved capacity - which is the gate working, not a failure. A row
 * that says "failed" for that is wrong.
 *
 * The second said, in full:
 *
 *     Planning and assessment
 *
 * and nothing else. stepText maps a step to a generic label - `capacity`
 * shares one with `plan` and `assessment` - and the label REPLACED the
 * detail. The refusal it was reporting, which names the wave, the reason and
 * the control to press, was discarded one line later.
 *
 * THE RULE, NOT THE INSTANCE: a label is a convenience for a step nobody has
 * to act on. A step that FAILED or was REFUSED is the one the reader opened
 * the log for, so it says what it says.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const { stepText } = liftAll('migrations.html', ['stepText']);

// stepText falls back to the page's label table for a step that needs no
// action. The harness lifts functions, not tables, so the two it reads are
// supplied here. They resolve through the scope chain at call time.
// Deliberately minimal: these tests are about WHICH branch runs, and the real
// labels are checked by the UX strings gate.
global.STEP_MAP = [[/^(assessment|plan|capacity)$/, 'planStep']];
global.UX_STEP = { planStep: 'Planning and assessment' };
// STEP-WORDS-1: the REAL map, not a fixture. stepText now asks it first, and
// a fixture here could say capacity says what it says when the page does
// not - which is the kind of disagreement a fixture cannot have with itself.
global.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');

const ev = (o) => Object.assign({ step: 'capacity', outcome: 'ok', detail: '' }, o);

test('a REFUSED step shows its reason, not a generic label', () => {
  const said = stepText(ev({
    outcome: 'refused',
    detail: "Wave 'wave-1' is set to On-demand capacity reservation, and no capacity has been reserved for it.",
  }));
  ok(said.includes('On-demand capacity reservation'), 'the reason must survive');
  ok(!said.includes('Planning and assessment'), 'the label must not replace it');
});

test('a FAILED step shows its reason too', () => {
  const said = stepText(ev({ outcome: 'fail', detail: 'Azure refused the reservation.' }));
  eq(said, 'Azure refused the reservation.');
});

test('and the label still serves a step that went well', () => {
  // The whole point of the labels. A successful quota check should not
  // spill engine text into the feed.
  // QUOTA-TRUTH-1: not the "claims=" summary - that one is now translated
  // into its result (step-words.test.js). Any other engine text keeps the label.
  const said = stepText(ev({ outcome: 'ok', detail: 'size=Standard_D2s_v6 region=centralus' }));
  ok(!said.includes('size='), 'an ordinary step keeps its friendly label');
});

test('a failure with NO detail still says something', () => {
  // The old behaviour is the fallback, not the rule. A failure that carries
  // no reason must not render as an empty cell.
  const said = stepText(ev({ outcome: 'fail', detail: '' }));
  ok(said.length > 0, 'it must not be blank');
});

test('the rule is FIRST, so no later case can take it back', () => {
  // `wave` and `restore` both return their own label regardless of outcome.
  // A failed one of those must still say why.
  eq(stepText({ step: 'wave', outcome: 'fail', detail: 'the wave stopped: Azure said no' }),
     'the wave stopped: Azure said no');
  eq(stepText({ step: 'restore', outcome: 'fail', detail: 'the disk could not be swapped back' }),
     'the disk could not be swapped back');
});

test('a refusal is not a failure, and reads differently', () => {
  // Same detail, two outcomes. Both show the reason; the caller picks the
  // badge from the outcome, so what matters here is that neither is dropped.
  const detail = 'no quota records for this wave';
  eq(stepText(ev({ outcome: 'refused', detail })), detail);
  eq(stepText(ev({ outcome: 'fail', detail })), detail);
});

run();
