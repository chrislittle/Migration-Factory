/* BLOCKED-NAME-1, the label half. Scoped 2026-09-21.
 *
 * A QUOTA CHECK REPORTED ITSELF AS PLANNING.
 *
 * The engine writes every quota and capacity event under the step name
 * `capacity`, and the page mapped that step to the label it shares with
 * `plan` and `assessment`:
 *
 *     [/^(assessment|plan|capacity)$/, 'planStep']   ->  "Planning and assessment"
 *
 * So a wave whose quota was checked, whose stale quota records were cleared,
 * or whose capacity gate refused it, all filed themselves in the activity log
 * under a heading about planning. Not fatal - LOG-SAYS-WHY-1 already made a
 * refusal show its own reason - but every quota event that went WELL still
 * reads as something it is not, and those are the ones that keep the label.
 *
 * THESE TESTS READ THE PAGE'S OWN TABLES. An earlier test of this same
 * function supplied its own two-entry copy, which was right for what it was
 * asking (which branch runs) and would never have caught this: a fixture
 * cannot disagree with itself.
 */
'use strict';
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const { stepText } = liftAll('migrations.html', ['stepText']);

// The real tables, as the page wrote them.
global.STEP_MAP = liftConst('migrations.html', 'STEP_MAP');
global.UX_STEP  = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE = {};
global.SAYS_ITSELF = liftConst('migrations.html', 'SAYS_ITSELF');   // STEP-WORDS-1

const ev = (o) => Object.assign({ step: 'capacity', outcome: 'ok', detail: '' }, o);

test('the tables really were lifted, so this cannot pass by reading nothing', () => {
  ok(Array.isArray(global.STEP_MAP) && global.STEP_MAP.length > 20, 'STEP_MAP');
  ok(Object.keys(global.UX_STEP).length > 20, 'UX_STEP');
});

test('a quota check no longer reports itself as planning', () => {
  // THE DEFECT.
  const said = stepText(ev({ outcome: 'ok', detail: 'claims=2 blocked=0' }));
  ok(!/Planning and assessment/.test(said), `capacity still reads as planning: ${said}`);
});

test('and it says what it actually is', () => {
  const said = stepText(ev({ outcome: 'ok', detail: 'claims=2 blocked=0' }));
  // The raw step name is the word "capacity", so a test that only asked for
  // that word PASSED when the pattern stopped matching and the feed fell
  // through to showing the step name. Found by mutating this file's own
  // check. Ask for a label, which means: not the step name, and words.
  ok(said !== 'capacity', 'the feed must not fall through to the raw step name');
  ok(/\s/.test(said), `a label is words, not one engine token: ${said}`);
  ok(/quota|capacity/i.test(said), `a quota event must name quota or capacity: ${said}`);
});

test('the engine detail is still kept out of the feed for a step that went well', () => {
  // The reason the label exists at all.
  const said = stepText(ev({ outcome: 'ok', detail: 'claims=2 blocked=0' }));
  ok(!said.includes('claims=2'), 'an ordinary step keeps its label');
});

test('planning and assessment keep the label that is theirs', () => {
  // The other direction. Taking `capacity` out of that pattern must not take
  // the pattern out with it.
  for (const step of ['plan', 'assessment']) {
    eq(stepText(ev({ step, outcome: 'ok' })), 'Planning and assessment', step);
  }
});

test('a refused capacity gate still shows its reason, not either label', () => {
  // LOG-SAYS-WHY-1 must survive this change.
  const said = stepText(ev({
    outcome: 'refused',
    detail: "Wave 'wave-1' is set to On-demand capacity reservation, and no capacity has been reserved for it.",
  }));
  ok(said.includes('On-demand capacity reservation'), 'the reason must survive');
  ok(!/Planning and assessment/.test(said), 'no generic label may replace it');
});

test('every label the step table points at is one the page declares', () => {
  // The strings gate says this for the page as a whole; this says it for the
  // table this item edits, where a typo would render as "undefined".
  for (const [, id] of global.STEP_MAP) {
    if (id === null) { continue; }
    ok(Object.prototype.hasOwnProperty.call(global.UX_STEP, id), `UX_STEP is missing '${id}'`);
  }
});

run('quota-label');
