/* PUTBACK-COUNT-1 (page half): a machine put back still counted as migrated.
 *
 * Seen in use: 6 migrated and 1 put back is 5 migrated now, but the page
 * did not track the put-back.
 *
 * A restore keeps the state MIGRATED and adds `restore`. Every count asked
 * only "is it MIGRATED", so the run said "6 - verified on new hardware" with
 * one machine back on its old size, and the wave said "2 of 2 migrated".
 *
 * RUN, not read: the page's own helpers are driven with real-shaped docs.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift: liftFn, liftAll, liftConst, test, ok, run } = require('./_harness');

// COUNT-TRUTH-1: the page's helpers now ask help.js's one definition. Give
// them the real one, lifted from help.js, not a copy written here.
const HELP = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'));
// eslint-disable-next-line no-eval
global.WORKING_STATES = eval(HELP.match(/const WORKING_STATES = (\[[^\]]+\]);/)[1]);
global.VmfHelp = { machineOutcome: liftFn('help.js', 'machineOutcome') };

const PAGE = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const lift = (name) => {
  const m = PAGE.match(new RegExp(`const ${name} = ([^;]+);`));
  if (!m) { throw new Error('could not lift ' + name); }
  // eslint-disable-next-line no-eval
  return eval('(' + m[1] + ')');
};
const isPutBack = lift('isPutBack');
/* STATUS-WORDS-1: the tile and the wave count by the status of each machine
 * (statusCounts), whose end results are help.js's one definition. */
const machineStatus = require('./_status').statusRule();
globalThis.RUNNING_STATUS = liftConst('migrations.html', 'RUNNING_STATUS');
globalThis.WAITING_STATUS = liftConst('migrations.html', 'WAITING_STATUS');
const { statusCounts } = liftAll('migrations.html', ['statusCounts']);
const count = (docs) => statusCounts(docs.map(d => machineStatus(d, {})));

const migrated = { state: 'MIGRATED' };
const putBack = { state: 'MIGRATED', restore: { restoredUtc: '2026-09-23T22:00:00Z' } };

test('RUN: a machine that was put back is not "migrated right now"', () => {
  ok(count([migrated]).migrated === 1, 'a migrated machine counts');
  ok(count([putBack]).migrated === 0, 'a put-back machine does not');
  ok(count([null]).migrated === 0, 'and nothing is not a machine');
});

test('RUN: and it IS counted, as a put-back', () => {
  ok(count([putBack]).restored === 1, 'the put-back is counted on its own');
  ok(count([migrated]).restored === 0, 'a machine never put back is not');
  ok(isPutBack(putBack) === true && isPutBack(migrated) === false, 'the progress point asks the same');
});

test('the tile and the wave use the SAME definition', () => {
  // Two places counting the same thing is how they come to disagree.
  const kpi = PAGE.slice(PAGE.indexOf('function renderKpis'), PAGE.indexOf('function renderKpis') + 900);
  ok(/statusCounts\(vms\.map\(v => machineStatusOf\(v\.vmId, v\)\)\)/.test(kpi), 'the tile counts with the shared helper');
  ok(!/v\.state === 'MIGRATED'/.test(kpi), 'and not with its own test');
  ok(/const waveCounts = statusCounts\(sts\);\s*const migrated = waveCounts\.migrated;/.test(PAGE),
    'the wave counts with it too');
});

test('the put-backs are SHOWN, not only counted', () => {
  /* On the CONDITION that draws them, not on the words. Found by mutation:
   * `${false && putBack ? ...}` left the string `putBackCount.replace` in the
   * file, so a check for it passed while the number could never appear - the
   * seventh time in one day that a check matched a definition, not a use. */
  // PUTBACK-TILE-1: its own tile now, not a clause under Migrated.
  ok(/<\/div>\$\{putBack \? `\s*<div class="kpi b6">/.test(PAGE),
    'a Put back tile appears whenever there is one');
  ok(/<div class="val">\$\{putBack\}<\/div>/.test(PAGE), 'and it shows the number');
  ok(!/verified on the new size\$\{putBack/.test(PAGE), 'not as grey text under Migrated');
  ok(/verified on the new size<\/div>/.test(PAGE), 'the grey text under Migrated is there, so the check above can fail');
  ok(/migrated\$\{putBackHere \?/.test(PAGE),
    'and so does each wave');
});

run('putback-count');
