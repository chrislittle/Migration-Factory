/* MACHINES-AT-ONCE-RANGE-1: four choices, each saying what it means, and one
 * setting per wave.
 *
 * Decided 2026-11-06: Pilot 5, Standard 15 (the default), Large 30, Maximum 60
 * - each choice must make clear what it means in machines at once. So
 * each choice says its number, and the number of engine containers it runs,
 * and the wave editor says what the chosen one means. Every writer writes a
 * choice (ATONCE-EARLIER-1), so another number has no words, and the editor
 * selects no choice for it.
 *
 * And the number is set in ONE place. The Run it step had "How many machines
 * at once in this start" for the first wave only, and the start dialog had
 * its own field: the same seven words as the wave setting, with another
 * value. Both now show the wave's own number, and a start sends none.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { pageSource } = require('./_page-source');
const { liftAll, test, eq, ok, run } = require('./_harness');

const HELP = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'), 'utf8');
const { waveAtOnce, atOnceChoice } = liftAll('help.js', ['waveAtOnce', 'atOnceChoice']);

// The four choices and the words, as help.js declares them - never a copy.
// eslint-disable-next-line no-eval
const TIERS = eval(HELP.match(/const WAVE_TIERS = (\[[\s\S]*?\]);/)[1]);
const textOf = (key) => {
  const m = HELP.match(new RegExp(`\\n\\s+${key}: '([^']*)'`));
  if (!m) { throw new Error(`help.js TEXT has no ${key}`); }
  return m[1];
};
const objectOf = (key) => {
  const m = HELP.match(new RegExp(`\\n\\s+${key}: (\\{[^}]*\\})`));
  if (!m) { throw new Error(`help.js TEXT has no ${key}`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[1]})`);
};
const T = {
  atOnceName: objectOf('atOnceName'),
  atOnceMeaning: objectOf('atOnceMeaning'),
  atOnceLabelOne: textOf('atOnceLabelOne'),
  atOnceLabelMany: textOf('atOnceLabelMany'),
};

test('the four choices are Pilot 5, Standard 15, Large 30 and Maximum 60', () => {
  eq(TIERS.map(t => `${t.id}=${t.machines}`), ['pilot=5', 'standard=15', 'large=30', 'maximum=60'], 'tiers');
  for (const t of TIERS) {
    ok(T.atOnceName[t.id], `a name for ${t.id}`);
    ok(T.atOnceMeaning[t.id], `a meaning for ${t.id}`);
  }
});

test('each choice says its number of machines at once and its engine containers', () => {
  eq(atOnceChoice(5, T, TIERS, 15).label, 'Pilot: 5 machines at once, 1 engine container', 'pilot');
  eq(atOnceChoice(15, T, TIERS, 15).label, 'Standard: 15 machines at once, 1 engine container', 'standard');
  eq(atOnceChoice(30, T, TIERS, 15).label, 'Large: 30 machines at once, 2 engine containers', 'large');
  eq(atOnceChoice(60, T, TIERS, 15).label, 'Maximum: 60 machines at once, 4 engine containers', 'maximum');
  eq(atOnceChoice('30', T, TIERS, 15).tier, 'large', 'a number in text is the same choice');
});

test('and what it means', () => {
  eq(atOnceChoice(15, T, TIERS, 15).meaning, T.atOnceMeaning.standard, 'standard');
  ok(/default/i.test(T.atOnceMeaning.standard), 'Standard says it is the default');
  ok(/one container/.test(T.atOnceMeaning.standard), 'Standard says one container');
  ok(/two containers/.test(T.atOnceMeaning.large), 'Large says two containers');
  ok(/four containers/.test(T.atOnceMeaning.maximum), 'Maximum says four containers');
  ok(/cores/.test(T.atOnceMeaning.maximum), 'Maximum says the cores are checked');
});

test('ATONCE-EARLIER-1: a number that is not a choice has no words and no choice - no writer of this version gives one', () => {
  ok(!/atOnceEarlier/.test(HELP), 'the words for a number set before the choices are gone');
  const c = atOnceChoice(7, T, TIERS, 15);
  eq(c.tier, null, 'never a guess of a choice');
  eq([c.label, c.meaning], ['', ''], 'and no words');
});

test('a wave reads the first machine with a number, and the default when none has one', () => {
  eq(waveAtOnce([{ policy: {} }, { policy: { throttle: 30 } }, { policy: { throttle: 5 } }], 15), 30, 'first with a number');
  eq(waveAtOnce([{ policy: {} }], 15), 15, 'none: the default');
  eq(waveAtOnce([], 15), 15, 'no machines: the default');
  eq(waveAtOnce([{ policy: { throttle: 0 } }, { policy: { throttle: 'x' } }], 15), 15, 'nonsense is not a number');
  ok(/const WAVE_DEFAULT_WORKERS = 15;/.test(HELP), 'the default is Standard');
});

const WIZ = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'wizard.html'));
const MIG = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'migrations.html'));
const WAV = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));

test('the Run it step sets no second number', () => {
  ok(!/id="f-thr"/.test(WIZ), 'no number field');
  ok(!/throttleTouched/.test(WIZ), 'no number of its own for this start');
  const go = WIZ.slice(WIZ.indexOf("$('#go5')?.addEventListener"), WIZ.indexOf('// CLAIM-AT-PLAN-1: the last start of a wave'));
  ok(go.length > 100, 'the start handler was found');
  ok(!/throttle/.test(go), 'the start and the schedules send no number');
});

test('the Run it step shows each wave\'s own choice, and where to change it', () => {
  const rows = WIZ.slice(WIZ.indexOf('function leverRowsFor('), WIZ.indexOf('function renderStep5('));
  ok(/VmfHelp\.atOnceChoice\(VmfHelp\.waveAtOnce\(moving\)\)/.test(rows), 'the wave row reads the choice by the one rule');
  ok(/UX\.atOnceWhere/.test(WIZ), 'the step says where the number is set');
});

test('the start dialog shows the wave\'s choice and sends no number', () => {
  const ask = MIG.slice(MIG.indexOf('function askStartWave('), MIG.indexOf('function askCancelSchedule('));
  ok(ask.length > 100, 'the dialog was found');
  ok(!/throttle/.test(ask), 'no field, and nothing sent');
  ok(/VmfHelp\.atOnceChoice\(/.test(ask), 'it says the choice');
});

test('the wave editor offers the four choices from help.js, and says what the chosen one means', () => {
  ok(/<select data-thr=/.test(WAV), 'a choice, not a number field');
  ok(/VmfHelp\.WAVE_TIERS\.map\(/.test(WAV), 'the options come from the one list');
  ok(/VmfHelp\.atOnceChoice\(/.test(WAV), 'each option and the hint say what it means');
  ok(!/<option value="\$\{esc\(w\.throttle\)\}"/.test(WAV), 'ATONCE-EARLIER-1: no option for a number that is not a choice');
  ok(/atOnceChoice\(w\.throttle\)\.tier \? '' : '<option value="" selected disabled hidden><\/option>'/.test(WAV),
    'another number selects an empty option, never a choice it does not hold');
  ok(/throttle: VmfHelp\.WAVE_DEFAULT_WORKERS/.test(WAV), 'a new wave starts at the default');
  ok(!/throttle: 3\b/.test(WAV), 'nothing starts at the old number');
});

run('machines-at-once');
