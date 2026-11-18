/* PLAN-WRITE-RACE-1: the wave editor's save quotes the plan version it read,
 * and a conflict is said in the engine's words.
 *
 * The page sends every wave's settings on every save. A save built from a page
 * read before a decision wrote the page's old value over that decision, and
 * the engine's own check could not see it - it compared against its own read.
 *
 * RUN, not read: the page's own writeLayout, and help.js's rules evaluated from
 * the file itself (the same way explain-consent.test.js takes them).
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftConst, lift, test, eq, ok, run } = require('./_harness');
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const writeLayout = lift('waves.html', 'writeLayout');

// WAVE-LEVER-OVERRIDE-1: writeLayout lists the settings changed on each card
// (changedOf) and draws each card again after a save (WAVE_DEFAULTS).
globalThis.changedOf = () => ({});
// WAVE-LEVER-RESET-1: and the machines reset to the value of the wave (resetOf).
globalThis.resetOf = () => ({});
globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
test('the save sends the plan version the page read', async () => {
  let sent = null;
  globalThis.layout = new Map([['w1', { vmIds: ['a'], capacityGate: 'BestEffort', requireApproval: true }]]);
  globalThis.waveMigrating = () => false;
  globalThis.apiPost = async (_p, body) => { sent = body; return {}; };
  globalThis.runSeg = () => 'run-1';
  globalThis.runBody = (b) => b;
  globalThis.snapshot = () => 's';
  globalThis.original = '';
  // WAVE-OWN-PICTURE-1: the save of a real run, which reads the plan again.
  globalThis.DEMO_MODE = false;
  globalThis.reloadPlan = async () => {};
  globalThis.planVersion = 'ver-read-by-the-page';
  await writeLayout();
  eq(sent.planVersion, 'ver-read-by-the-page');
});

const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
const START = 'const ROLE_WORDS';
const END = 'function explainAction(err) { return explainWith(err, true); }';
const from = HELP.indexOf(START);
const to = HELP.indexOf(END);
const slice = (from >= 0 && to > from) ? HELP.slice(from, to + END.length) : '';
// eslint-disable-next-line no-eval
const rules = slice ? eval(`(function () { ${slice}; return { explain, explainAction }; })()`) : null;

test('a conflict shows the engine sentence, without the code', () => {
  ok(rules, 'the rules were not found in help.js');
  const said = rules.explainAction(new Error('409: Somebody changed the plan at the same time, so the product did not save this change. Load the page again, then make the change again.'));
  eq(said, 'Somebody changed the plan at the same time, so the product did not save this change. Load the page again, then make the change again.');
});

test('a 404 is still a 404, not a conflict', () => {
  ok(!/^Somebody/.test(rules.explainAction(new Error('HTTP 404'))));
});

run('plan-write-race');
