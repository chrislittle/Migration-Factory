/* BLOCKED-NAME-1, the half that stops this happening again.
 *
 * Fixing one label is fixing an instance. The RULE is that every step the
 * engine writes must reach an operator as words, and nothing enforced it -
 * so `capacity` sat mislabelled for as long as it did, and a census run while
 * fixing it found TWELVE MORE steps that reach the activity feed as the raw
 * engine word: "rearm", "claim", "acknowledgement", "driverCheck".
 *
 * MEASURED, not read: each step name is taken from the engine's own source
 * and put through the page's real stepText with the page's real tables. A
 * step whose label is missing comes back as its own name, and that is the
 * test.
 *
 * A step may be listed as KNOWN below, with the item that owns it. "Not done
 * yet" is not a reason - the entry has to name where the work went.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const { stepText } = liftAll('migrations.html', ['stepText']);
global.STEP_MAP      = liftConst('migrations.html', 'STEP_MAP');
global.UX_STEP       = liftConst('migrations.html', 'UX_STEP');
global.UX_STATE      = liftConst('migrations.html', 'UX_STATE');
global.UX_STATE_DONE = liftConst('migrations.html', 'UX_STATE_DONE');
global.SAYS_ITSELF   = liftConst('migrations.html', 'SAYS_ITSELF');

/* Steps that still render as their own name. Each names the item that owns
 * it, and "not done yet" is not a reason.
 *
 * STEP-WORDS-1 emptied this list of the eleven it was filed for. The one
 * left is not reachable: the feed SKIPS an engine:memory event without
 * peakWorkerMB (`a reading, not news`), and one WITH it takes the `^engine:`
 * branch above the table, which has words for it. It is listed rather than
 * quietly excused, because a step nothing can produce is still a step
 * somebody could start producing. */
const KNOWN = {
  'engine:memory': 'STEP-WORDS-1 - the feed drops this event unless it carries peakWorkerMB, and one that does is handled above the table',
};

/** Every literal step name the engine writes. */
function enginesteps() {
  const root = path.join(REPO, 'src', 'VmMigrationFactory');
  const found = new Set();
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) { walk(full); continue; }
      if (!entry.name.endsWith('.ps1')) { continue; }
      const src = fs.readFileSync(full, 'utf8');
      for (const m of src.matchAll(/-Step\s+'([^']+)'/g)) {
        if (!m[1].includes('$')) { found.add(m[1]); }
      }
    }
  };
  walk(root);
  return [...found].sort();
}

const STEPS = enginesteps();

test('the engine steps really were found, so this cannot pass by reading nothing', () => {
  ok(STEPS.length > 25, `found only ${STEPS.length} step names`);
  ok(STEPS.includes('capacity'), 'the step this item fixed must be among them');
});

test('every step the engine writes reaches an operator as words', () => {
  const raw = STEPS.filter((s) => stepText({ step: s, outcome: 'ok', detail: 'engine detail' }) === s);
  const unlisted = raw.filter((s) => !KNOWN[s]);
  ok(unlisted.length === 0,
    `these steps render as the raw engine word and no item owns them: ${unlisted.join(', ')}`);
});

test('and the known list does not outlive what it describes', () => {
  // A name that gained a label must leave this list, or the list becomes a
  // record of work somebody already did and nobody can tell what is left.
  const stale = Object.keys(KNOWN).filter(
    (s) => stepText({ step: s, outcome: 'ok', detail: 'engine detail' }) !== s);
  ok(stale.length === 0, `these now have labels and must come off the list: ${stale.join(', ')}`);
});

test('quota and capacity is not on that list, because this item labelled it', () => {
  ok(!KNOWN.capacity, 'capacity must not be excused');
  const said = stepText({ step: 'capacity', outcome: 'ok', detail: 'claims=2 blocked=0' });
  ok(said !== 'capacity' && /quota|capacity/i.test(said), `capacity reads as: ${said}`);
});

run('step-census');
