/* ATONCE-1, settled by MACHINES-AT-ONCE-RANGE-1: the same seven words, twice
 * on one screen, meaning two things.
 *
 * On a seven-wave demo estate, the Run it step asked how many machines at
 * once AFTER every wave already had that setting - it is set per wave.
 * ATONCE-1 kept the field and made it say "in this start", for the first
 * wave only. On 2026-11-04 the question was whether machines per wave and
 * machines in this start always match the wave settings - they did not have
 * to, and the screen could not show which
 * number a later wave used. So the field is gone (ruling, 2026-11-06):
 * the number is set in one place, the wave settings, and the Run it step
 * shows each wave's own and says where to change it.
 */
'use strict';
const path = require('path');
const { pageSource } = require('./_page-source');
const { test, ok, run, liftConst } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const UX = liftConst('wizard.html', 'UX');

test('the Run it step has no number field for one start', () => {
  const how = SRC.slice(SRC.indexOf('const howSection ='), SRC.indexOf('const ready = allAccepted && signed;'));
  ok(how.length > 100, 'the section that decides how the plan runs was found');
  ok(!/<input type="number"/.test(how), 'no number field');
  ok(!('throttle' in UX) && !('throttleFromWave' in UX), 'and none of its words');
});

test('it says where the number is set, in words that are not the wave setting itself', () => {
  const how = SRC.slice(SRC.indexOf('const howSection ='), SRC.indexOf('const ready = allAccepted && signed;'));
  ok(/UX\.atOnceWhere/.test(how), 'the sentence is in that section');
  ok(UX.atOnceWhere !== UX.lvAtOnce, 'it is not word for word the row of each wave');
  ok(/machines at once/.test(UX.atOnceWhere), 'it names the setting in the product\'s own words');
  ok(/settings/.test(UX.atOnceWhere), 'and says the settings of the wave hold it');
});

run('start-throttle');