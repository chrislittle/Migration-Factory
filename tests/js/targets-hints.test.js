/* TARGETS-HINTS-1: the hint under each default lifecycle stage on Choose each
 * target says what that default gives.
 *
 * The approved hints were "v6 or v7 where the machine supports it" and "v5".
 * Neither said that a B v1 machine starts on Bsv2 under both (BSV2-TARGET-1),
 * and "v6 or v7" did not say the order, or that v5 is the last choice of
 * Current. The page now builds both hints from ONE order, T_START_ORDER, which
 * is held here to the order the engine starts a machine on
 * (Get-VmfTargetAdvice in Private/plan/Advice.ps1), and the Bsv2
 * sentence is held to data/target-families.json.
 *
 * RUN, not read: the page's own function and constants, lifted out of wizard.html.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftConst, test, eq, ok, run } = require('./_harness');

const REPO = path.join(__dirname, '..', '..');
const WIZ = pageSource(path.join(REPO, 'src', 'dashboard', 'wizard.html'));
const ADVICE = fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'Private', 'plan', 'Advice.ps1'), 'utf8');
const FAMILIES = JSON.parse(fs.readFileSync(path.join(REPO, 'src', 'VmMigrationFactory', 'data', 'target-families.json'), 'utf8'));

const UX = globalThis.UX = liftConst('wizard.html', 'UX');
const ORDER = globalThis.T_START_ORDER = liftConst('wizard.html', 'T_START_ORDER');
globalThis.fill = (s, v) => String(s).replace(/\{(\w+)\}/g, (_, k) => (v[k] ?? ''));
const tStartHint = lift('wizard.html', 'tStartHint');

// The engine's order, from the line that sets it - a code line, never a comment.
const engineOrder = (name) => {
  const line = ADVICE.split(/\r?\n/).map(l => l.trim()).find(l => l.startsWith(`$${name} = @(`));
  ok(line, `Advice.ps1 sets $${name}`);
  return [...line.matchAll(/'(v\d)'/g)].map(m => m[1]);
};

test('1: the order of each default is the order the engine starts a machine on', () => {
  eq(JSON.stringify(ORDER.current), JSON.stringify(engineOrder('currentOrder')), 'Current');
  eq(JSON.stringify(ORDER.extended), JSON.stringify(engineOrder('extendedOrder')), 'Extended');
  eq(ORDER.current.length, 3, 'three options');
});

test('2: each order holds every target series of target-families.json, once', () => {
  const series = Object.keys(FAMILIES.seriesByGeneration).sort();
  for (const def of ['current', 'extended']) eq(JSON.stringify([...ORDER[def]].sort()), JSON.stringify(series), def);
});

// STAGE-HINT-WORDS-1 (approved words, 2026-11-13): the hint text "the first of
// v6, v7 and v5" under Current read as if v5 were in the Current stage. The Current
// hint now says that v5 is the last choice, and that v5 is in Extended.
test('3: the hint of each default names its order, first to last', () => {
  eq(tStartHint('current'), 'Each machine starts on v6, or on v7 when v6 does not fit. A machine that can take neither starts on v5, in the Extended stage. A B v1 machine starts on Bsv2 when a Bsv2 size fits it.');
  eq(tStartHint('extended'), 'Each machine starts on the first of v5, v6 and v7 that it can take. A B v1 machine starts on Bsv2 when a Bsv2 size fits it.');
});

test('4: the hint follows the order - it is built from it, not written twice', () => {
  const savedCurrent = ORDER.current;
  const savedExtended = ORDER.extended;
  try {
    ORDER.current = ['v7', 'v5', 'v6'];
    ORDER.extended = ['v6', 'v7', 'v5'];
    ok(tStartHint('current').startsWith('Each machine starts on v7, or on v5 when v7 does not fit. A machine that can take neither starts on v6, '), tStartHint('current'));
    ok(tStartHint('extended').startsWith('Each machine starts on the first of v6, v7 and v5 '), tStartHint('extended'));
  } finally { ORDER.current = savedCurrent; ORDER.extended = savedExtended; }
});

test('4b: the last choice of Current is in the Extended stage, as the Current hint says, and the first two are Current', () => {
  ok(/starts on \{c\}, in the Extended stage\./.test(UX.tStartCurrent), UX.tStartCurrent);
  const [a, b, c] = ORDER.current;
  const stagesOf = (gen) => [...new Set(FAMILIES.lifecycle.bySeries
    .filter(r => r.generations.includes(gen) && FAMILIES.seriesByGeneration[gen]).map(r => r.stage))];
  eq(JSON.stringify(stagesOf(c)), JSON.stringify(['Extended']), `${c} is Extended in target-families.json`);
  eq(JSON.stringify(stagesOf(a)), JSON.stringify(['Current']), `${a} is Current`);
  eq(JSON.stringify(stagesOf(b)), JSON.stringify(['Current']), `${b} is Current`);
});

test('4c: the Current hint no longer reads "the first of", which put v5 in a list of Current series', () => {
  ok(!tStartHint('current').includes('the first of'), tStartHint('current'));
  ok(tStartHint('extended').includes('the first of'), tStartHint('extended'));
});

test('5: the Bsv2 sentence names the burstable target and its source family from target-families.json', () => {
  const targets = FAMILIES.burstableTargets.series.map(s => s.series);
  eq(JSON.stringify(targets), JSON.stringify(['Bsv2']), 'one burstable target');
  ok(UX.tStartBsv2.includes(targets[0]), UX.tStartBsv2);
  eq(JSON.stringify(FAMILIES.burstableFamilies), JSON.stringify(['B']), 'the burstable family');
  ok(UX.tStartBsv2.startsWith(`A ${FAMILIES.burstableFamilies[0]} v1 machine `), UX.tStartBsv2);
  // Only a machine on a B v1 size is offered Bsv2, and only when a size fits it.
  const v1 = FAMILIES.lifecycle.bySeries.find(r => r.family === 'B' && r.generations.includes('v1'));
  ok(v1, 'B v1 is a family the data names');
  ok(/when a Bsv2 size fits it\.$/.test(UX.tStartBsv2), 'says when');
});

test('6: the stage radio buttons show the built hint, and the old fixed hints are gone', () => {
  ok(WIZ.includes("esc(tStartHint('current'))"), 'Current shows its hint');
  ok(WIZ.includes("esc(tStartHint('extended'))"), 'Extended shows its hint');
  eq(UX.tCurrentHint, undefined, 'no fixed Current hint');
  eq(UX.tExtendedHint, undefined, 'no fixed Extended hint');
});

test('7: the series of each default, which the counts compare with, is the first of its order', () => {
  const lines = WIZ.split(/\r?\n/).map(l => l.trim());
  eq(lines.filter(l => l.startsWith("const defSeries = def === 'extended' ? 'v5' : 'v6';")).length, 0, 'not written twice');
  eq(lines.filter(l => l.startsWith('const defSeries = tDefSeries(def);')).length, 2, 'both counts read it');
  const tDefSeries = lift('wizard.html', 'tDefSeries');
  eq(tDefSeries('current'), ORDER.current[0]);
  eq(tDefSeries('extended'), ORDER.extended[0]);
  eq(tDefSeries('anything'), ORDER.current[0], 'anything else reads as Current, as the saved default does');
});

run('targets-hints');
