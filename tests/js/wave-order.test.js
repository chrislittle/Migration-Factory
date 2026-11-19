/* WAVE-ORDER-1: every page shows the waves in the order they run.
 *
 * RUN: the shared rule (help.js waveOrder) and the editor's moveWave, then each
 * page is checked to use them.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const DASH = path.join(__dirname, '..', '..', 'src', 'dashboard');
const read = (f) => pageSource(path.join(DASH, f));
const { waveOrder } = liftAll('help.js', ['waveOrder']);
const { moveWave } = liftAll('waves.html', ['moveWave']);
const e = (vm, wave) => ({ vmId: vm, wave });
const plan = (order) => ({ entries: [e('g1', 'gen1-wave'), e('lin', 'gen2-wave'), e('win', 'gen2-wave'), e('x', 'unscheduled')], waveOrder: order });

test('the plan\'s own order decides', () => {
  eq(waveOrder(plan(['gen2-wave', 'gen1-wave'])).join(','), 'gen2-wave,gen1-wave');
});

test('with no order, the order waves first appear, as before', () => {
  eq(waveOrder(plan(undefined)).join(','), 'gen1-wave,gen2-wave');
});

test('a named wave that is gone is ignored; a wave the order misses comes after; unscheduled is not a wave', () => {
  eq(waveOrder(plan(['gone', 'gen2-wave'])).join(','), 'gen2-wave,gen1-wave');
});

test('Move up and Move down swap neighbours, and the ends stay put', () => {
  const m = new Map([['a', 1], ['b', 2], ['c', 3]]);
  eq([...moveWave(m, 'b', -1).keys()].join(','), 'b,a,c');
  eq([...moveWave(m, 'b', 1).keys()].join(','), 'a,c,b');
  eq([...moveWave(m, 'a', -1).keys()].join(','), 'a,b,c');
  eq([...moveWave(m, 'c', 1).keys()].join(','), 'a,b,c');
  eq(moveWave(m, 'b', 1).get('b'), 2, 'the wave keeps its settings');
});

test('each page uses the one rule', () => {
  ok(read('wizard.html').includes('const rank = VmfHelp.waveOrder(plan);'), 'the wizard - its first wave is the one "Run it" starts');
  // NOT-IN-WAVE-QUEUED-1: the run page's waves are built in waveGroups(plan, docs).
  ok(read('migrations.html').includes('const rank = VmfHelp.waveOrder(plan);'), 'the run page');
  ok(!/const waves = \[\.\.\.byWave\.entries\(\)\]\.sort\(\(a, b\) =>\s*a\[0\]\.localeCompare/.test(read('migrations.html')), 'no longer sorted by name');
  ok(read('waves.html').includes('VmfHelp.waveOrder({ entries, waveOrder: planWaveOrder })'), 'the wave editor');
});

run('wave-order');
