/* WAVE-CASE-1: two waves whose names differ only in letter case.
 *
 * The engine compares wave names without letter case, and blob names keep it.
 * So the wave editor refuses, as the name is typed, a wave name that the
 * engine cannot tell apart from another wave name - by the rule the service
 * asks at save (Find-VmfWaveNameClash), held to ONE fixture:
 * tests/fixtures/wave-name-clash.json.
 *
 * RUN, not read: the page's own functions and its own words.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { liftAll, liftConst, test, eq, ok, run } = require('./_harness');

const CASES = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'wave-name-clash.json'), 'utf8')).cases;
globalThis.UX = liftConst('waves.html', 'UX');
const { findWaveNameClash, waveNameClashFor, waveNameClashNote } =
  liftAll('waves.html', ['findWaveNameClash', 'waveNameClashFor', 'waveNameClashNote']);

test('the fixture has cases to answer', () => {
  ok(CASES.length > 8, 'more than eight cases');
});

test('findWaveNameClash gives every case the answer the service gives', () => {
  for (const c of CASES) {
    eq(findWaveNameClash(c.layout, c.stored), c.clash, c.why);
  }
});

test('a rename to the name of another wave in another letter case is refused', () => {
  const clash = waveNameClashFor('Prod', ['prod', 'wave-2'], ['wave-1', 'wave-2']);
  eq(clash, { name: 'Prod', other: 'prod', kind: 'case' }, 'the other wave is named');
  eq(waveNameClashNote(clash, 'Prod'),
    'The names "Prod" and "prod" are different only in letter case. The engine reads them as one wave. Use a different name.',
    'the editor says why');
});

test('a rename to the exact name of another wave is refused, and the editor says why', () => {
  const clash = waveNameClashFor('wave-2', ['wave-2'], ['wave-1', 'wave-2']);
  eq(clash && clash.kind, 'same', 'one name, two waves');
  eq(waveNameClashNote(clash, 'wave-2'), 'Another wave has the name "wave-2". Use a different name.', 'the words');
});

test('a rename that changes only the letter case of a saved wave is refused', () => {
  const clash = waveNameClashFor('Wave-1', ['wave-2'], ['wave-1', 'wave-2']);
  eq(clash, { name: 'Wave-1', other: 'wave-1', kind: 'stored' }, 'the saved wave is named');
  eq(waveNameClashNote(clash, 'Wave-1'),
    'The name "Wave-1" is different from the saved wave "wave-1" only in letter case. The product cannot change only the letter case of a wave name. Use a different name.',
    'the words');
});

test('a new name, and a wave that was never saved, are usable', () => {
  eq(waveNameClashFor('prod', ['wave-2'], ['wave-1', 'wave-2']), null, 'a new name');
  eq(waveNameClashFor('New-Wave', [], ['wave-1']), null, 'a wave made on this page and not saved');
  eq(waveNameClashNote(null, 'prod'), '', 'no clash, no words');
});

test('a clash between two other waves does not stop a rename of a third', () => {
  // Only the typed name is judged, so the editor cannot be stuck by a plan
  // that holds such names.
  eq(waveNameClashFor('prod', ['A', 'a'], []), null, 'the typed name is usable');
});

run();
