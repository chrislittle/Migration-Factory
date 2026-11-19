/* DECIDE-KEEP-1: a wave the engine refused for changed settings offers to
 * accept again. RUN: the page's own acceptanceRefused, against log lines shaped
 * like the engine's.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { liftAll, test, eq, ok, run } = require('./_harness');

const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const { acceptanceRefused } = liftAll('migrations.html', ['acceptanceRefused']);
const acc = { wave: 'gen1-wave', acceptedUtc: '2026-09-27T11:25:27Z' };
const refused = (ts, extra) => Object.assign({ tsUtc: ts, step: 'acceptance', outcome: 'refused', code: 'optionsChanged', wave: 'gen1-wave' }, extra || {});

test('a refusal after the acceptance makes it out of date', () => {
  eq(acceptanceRefused(acc, [refused('2026-09-27T11:35:37Z')], 'gen1-wave'), true);
});

test('a refusal before it, of another wave, or of another kind does not', () => {
  eq(acceptanceRefused(acc, [refused('2026-09-27T11:20:00Z')], 'gen1-wave'), false, 'older');
  eq(acceptanceRefused(acc, [refused('2026-09-27T11:35:37Z', { wave: 'gen2-wave' })], 'gen1-wave'), false, 'another wave');
  eq(acceptanceRefused(acc, [refused('2026-09-27T11:35:37Z', { code: 'other' })], 'gen1-wave'), false, 'another code');
  eq(acceptanceRefused(null, [refused('2026-09-27T11:35:37Z')], 'gen1-wave'), false, 'nothing accepted is a different chip');
});

test('an amendment after the refusal answers it', () => {
  const amended = Object.assign({}, acc, { amendments: [{ utc: '2026-09-27T11:40:00Z' }] });
  eq(acceptanceRefused(amended, [refused('2026-09-27T11:35:37Z')], 'gen1-wave'), false);
});

test('the chip and the Accept button both follow it', () => {
  ok(SRC.includes('const accStale = acceptanceRefused(acc, latestEvents, wave);'), 'computed per wave');
  ok(SRC.includes('((!acc || accStale) && canOperate()'), 'Accept is offered again');
  ok(SRC.includes('accStale ? UX_MISC.optionsChanged : UX_MISC.optionsNotAccepted'), 'and says why');
});

run('decide-keep');
