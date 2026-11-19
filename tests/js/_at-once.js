/* MACHINES-AT-ONCE-RANGE-1: the "machines at once" functions a page function
 * calls, for a test that lifts that function alone - the REAL ones from
 * help.js, with help.js's own choices and words, never a copy that could
 * answer differently.
 *
 *   atOnce(obj)  adds them to a VmfHelp stand-in (made when there is none),
 *                and returns it
 *                (and the settings of a wave: waveCard, ownRowText - help.js)
 *   install()    makes every VmfHelp stand-in this file assigns later carry
 *                them too, for a test whose page functions draw a wave's
 *                settings - a stand-in it names itself still wins
 */
'use strict';
const fs = require('fs');
const path = require('path');
const { extract, liftAll } = require('./_harness');

const SRC = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'), 'utf8');
const constOf = (name) => {
  const m = SRC.match(new RegExp(`const ${name} = ([^;]*);`));
  if (!m) { throw new Error(`help.js has no const ${name}`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[1]})`);
};
const textOf = (key) => {
  const m = SRC.match(new RegExp(`\\n\\s+${key}:\\s+('[^']*'|\\{[^}]*\\})`));
  if (!m) { throw new Error(`help.js TEXT has no ${key}`); }
  // eslint-disable-next-line no-eval
  return eval(`(${m[1]})`);
};

const TIERS = constOf('WAVE_TIERS');
const DEFAULT = constOf('WAVE_DEFAULT_WORKERS');
const PER = constOf('WAVE_PER_CONTAINER');
const T = {};
for (const k of ['atOnceName', 'atOnceMeaning', 'atOnceLabelOne', 'atOnceLabelMany']) { T[k] = textOf(k); }
const fns = liftAll('help.js', ['waveAtOnce', 'atOnceChoice', 'waveEstimate']);

/* ACCEPT-FIRST-MACHINE-1: the settings of a wave, by the ONE rule in help.js
 * (waveCard and the words of a machine that does not follow a setting). Lifted
 * into a scope that holds help.js's own words and the two rules it calls, so a
 * page function that asks VmfHelp gets the real answer. */
const WAVE_RULE_NAMES = ['waveSettingDefaults', 'waveWideSettings', 'leverValue', 'ownDecision', 'keepsOwn', 'waveWideValue',
  'waveCard', 'ownValueText', 'ownDecisionOf', 'dayText', 'ownCountText', 'ownRowText'];
const OWN_TEXT = {};
for (const k of ['ownOne', 'ownMany', 'ownRowValue', 'ownRowDecided', 'ownRowDecidedNoDate', 'ownDataStop', 'ownDataProceed',
  'ownDayOne', 'ownDays']) { OWN_TEXT[k] = textOf(k); }
const waveRule = (function (TEXT, WAVE_DEFAULT_WORKERS) {
  const approvalRequired = liftAll('help.js', ['approvalRequired']).approvalRequired;
  const waveAtOnce = (entries) => fns.waveAtOnce(entries, WAVE_DEFAULT_WORKERS);
  // eslint-disable-next-line no-eval
  return eval(`(function () { ${WAVE_RULE_NAMES.map(n => extract('help.js', n)).join('\n')}\nreturn { ${WAVE_RULE_NAMES.join(', ')} }; })()`);
})(OWN_TEXT, DEFAULT);

function atOnce(obj) {
  const target = obj ?? globalThis.VmfHelp ?? {};
  Object.assign(target, waveRule, {
    WAVE_TIERS: TIERS, WAVE_DEFAULT_WORKERS: DEFAULT, WAVE_PER_CONTAINER: PER, WAVE_MAX_WORKERS: constOf('WAVE_MAX_WORKERS'),
    waveAtOnce: (entries, fallback = DEFAULT) => fns.waveAtOnce(entries, fallback),
    atOnceChoice: (n) => fns.atOnceChoice(n, T, TIERS, PER),
    waveEstimate: target.waveEstimate ?? fns.waveEstimate,
  });
  return target;
}

// A test assigns its own stand-in (`globalThis.VmfHelp = { ... }`), often
// more than once. install() keeps that assignment as written and adds only
// the functions it does not name, so a page function that draws "How many
// machines at once" finds the real rule whichever stand-in is current.
function install() {
  const desc = Object.getOwnPropertyDescriptor(globalThis, 'VmfHelp');
  if (desc && desc.get && desc.get.atOnceInstalled) { return; }
  let current = atOnceMissing(globalThis.VmfHelp ?? {});
  const get = () => current;
  get.atOnceInstalled = true;
  Object.defineProperty(globalThis, 'VmfHelp', { configurable: true, enumerable: true, get, set: (v) => { current = atOnceMissing(v ?? {}); } });
}
function atOnceMissing(obj) {
  const all = atOnce({});
  for (const [k, v] of Object.entries(all)) { if (!(k in obj)) { obj[k] = v; } }
  return obj;
}

module.exports = { atOnce, install, waveRule, OWN_TEXT };
