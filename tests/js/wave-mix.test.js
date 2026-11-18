/* ADVISOR-1: a wave can hold machines on several size series.
 *
 * Each machine has its own series, chosen before the waves. The acceptance
 * summary on the run page counts the wave's machines rather than reading the
 * series off the first one. (The wave editor's per-wave series control was
 * removed by WAVE-SERIES-GONE-1.)
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { test, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');

test('the acceptance summary counts the wave, not its first machine', () => {
  const src = pageSource(path.join(REPO, 'src', 'dashboard', 'migrations.html'));
  ok(src.includes('[UX_LEVER.targetGen, waveSeriesText(entries)]'), 'the row uses every entry');
  ok(!/\[UX_LEVER\.targetGen, [^\]]*lever\.targetGeneration/.test(src), 'not the first entry\'s lever');
});

test('the wave editor has no series control, and no series of its own', () => {
  const src = pageSource(path.join(REPO, 'src', 'dashboard', 'waves.html'));
  ok(!/data-gen=|data-genapply|function waveSeries|changeGeneration/.test(src), 'gone');
});

run('wave-mix');
