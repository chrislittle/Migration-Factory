/* GATE-WORDS-1: a refused wave start says what is missing where the page shows it.
 *
 * Start-VmfWave refuses a wave that fails a start gate with the gate's own two
 * sentences (tests/unit/GateWords.Tests.ps1 holds the engine to that). The
 * migration's page shows the FIRST sentence of the last failure under "The
 * start of a wave did not work" and puts the rest behind Show (FAILBRIEF-1).
 * The first version led with "Wave w1 cannot start.", so the banner said that
 * and nothing about what was missing.
 *
 * RUN, not read: the page's own splitFailure, against every reason in
 * src/VmMigrationFactory/data/start-gates.json.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { lift, test, eq, ok, run } = require('./_harness');

const WORDS = JSON.parse(fs.readFileSync(
  path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'data', 'start-gates.json'), 'utf8'));
const splitFailure = lift('migrations.html', 'splitFailure');
// RESERVE-COVER-1: the capacity gate names machines and their sizes.
const fill = (s) => s.replace(/\{wave\}/g, 'w1').replace(/\{by\}/g, 'operator@example.com')
  .replace(/\{machines\}/g, "machine 'app-2' (Standard_E2s_v6)");
const codes = Object.keys(WORDS.reasons);

test('the file has reasons to check', () => {
  ok(codes.length >= 6, `only ${codes.length} reasons`);
});

for (const code of codes) {
  test(`${code}: the banner's first sentence is what is missing, and Show holds what to do`, () => {
    const r = WORDS.reasons[code];
    const said = splitFailure(fill(`${r.missing} ${r.toDo}`));
    eq(said.first, fill(r.missing));
    eq(said.rest, fill(r.toDo));
  });
}

run('gate-words');
