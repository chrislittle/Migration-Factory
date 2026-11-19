/* SCALE-UX-1, MANUAL-REVIEW-1: the sentence beside the number of machines at
 * once. Decided 2026-11-13: no wave time in words on a page. The
 * engine's own estimate (Get-VmfWaveDurationEstimate) stays, for the change
 * window. What the page still says is why a number above the wave's machines
 * changes nothing - or the field looks dead.
 */
'use strict';
const { pageSource } = require('./_page-source');
const { lift, test, eq, ok, run } = require('./_harness');

const waveEstimate = lift('help.js', 'waveEstimate');
const T = {
  estAllAtOnce: 'This wave has only {machines} machines, so all of them run at once.',
  estAllAtOnceOne: 'This wave has only 1 machine, so a larger number changes nothing.',
};

test('no machines, no sentence', () => {
  eq(waveEstimate(0, 3, T), null, 'zero');
  eq(waveEstimate('', 3, T), null, 'blank');
});

test('a number within the wave says nothing: no time, no figure', () => {
  eq(waveEstimate(6, 3, T), null, 'six machines, three at a time');
  eq(waveEstimate(6, 6, T), null, 'as many as the machines');
  eq(waveEstimate(300, 20, T), null, 'a long wave');
  eq(waveEstimate(2, 0, T), null, 'zero workers reads as one');
  eq(waveEstimate(2, 'x', T), null, 'nonsense reads as one');
});

test('a number above the wave says that all machines run at once', () => {
  eq(waveEstimate(2, 20, T), 'This wave has only 2 machines, so all of them run at once.');
});

// LAB-UX-1: one machine is said in the singular.
test('one machine is said in the singular', () => {
  eq(waveEstimate(1, 3, T), 'This wave has only 1 machine, so a larger number changes nothing.');
  eq(waveEstimate(1, 1, T), null, 'one machine, one worker');
});

test('no page declares a wave time in words, and every page that calls it declares both sentences', () => {
  const path = require('path');
  const fs = require('fs');
  for (const page of ['wizard.html', 'migrations.html', 'waves.html']) {
    const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', page));
    ok(!/\b(estimate|estMinutes|estHours|estDays|estimateOne):\s*'/.test(src), `${page}: no estimate strings`);
    ok(/estAllAtOnce: +'This wave has only \{machines\} machines, so all of them run at once\.'/.test(src), `${page} estAllAtOnce`);
    ok(/estAllAtOnceOne: '[^']*1 machine,/.test(src), `${page} estAllAtOnceOne`);
  }
  const help = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'), 'utf8');
  ok(!/WAVE_MINUTES_PER_MACHINE|WAVE_SAFETY_FACTOR/.test(help), 'no minutes-per-machine constant on a page');
});

run('wave-estimate');
