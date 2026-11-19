/* WAVE-OWN-PICTURE-1 (2026-11-12): the box under a wave setting says
 * WHAT each machine's value is and WHY.
 *
 * The box said "1 machine has its own value." and, opened, a paragraph about
 * "own values" that never said what the machine's value was or where it came
 * from. In the manual picture, the statement made no sense. Now the closed line says
 * how many machines do not follow the setting, and each row states the
 * machine's value with the label the setting's own control shows, and the
 * cause where the plan records one:
 *   - a decision for the machine: who accepted it, and on which day;
 *   - Update the kernel: chosen on the Choose each target step (no button);
 *   - anything else: the value only - nothing is invented about why.
 * The button is "Use the wave's setting". What a reset does is unchanged.
 *
 * RUN, not read: the page's own functions. The words are pinned as literals,
 * so a change of the string table cannot pass by changing both sides.
 */
'use strict';
const { pageSource } = require('./_page-source');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// ACCEPT-FIRST-MACHINE-1: the settings of a wave are read by the rule in
// help.js; waves.js names its parts (leverValue, keepsOwn, waveCard) as
// aliases of VmfHelp, so the page functions find them on the global object.
function waveRuleGlobal() { const r = require('./_at-once').waveRule; Object.assign(globalThis, { leverValue: r.leverValue, ownDecision: r.ownDecision, keepsOwn: r.keepsOwn, waveCard: r.waveCard }); return r; }
require('./_at-once').install();

const UX = liftConst('waves.html', 'UX');
globalThis.UX = UX;
globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
globalThis.WAVE_WIDE = ['capacityGate', 'requireApproval', 'throttle'];
const approvalRequired = lift('help.js', 'approvalRequired');
globalThis.VmfHelp = { approvalRequired };
const page = ({ ...waveRuleGlobal(), ...liftAll('waves.html', ['ownOf', 'ownHint', 'ownRow', 'resetPending', 'toggleReset', 'clearResets', 'resetLocked', 'toggleOwnHelp']) });
Object.assign(globalThis, page);
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.membersOf = (name) => entries.filter(e => layout.get(name).vmIds.includes(e.vmId));
const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));

const DAY = (iso) => new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
const USE = esc("Use the wave's setting");

// Wave w, card at the defaults: a has Continue from a decision (two records,
// the newer one counts), b has 14 days with no decision, c holds Stop and ask
// with no decision while the card may show Continue, k updates its kernel.
function setUp({ edit = true, signOff = true, running = false } = {}) {
  globalThis.entries = [
    { vmId: '/s/a', wave: 'w', policy: { onDDataFound: 'proceed' }, decisions: [
      { setting: 'onDDataFound', by: 'old@example.com', utc: '2026-10-01T08:00:00Z' },
      { setting: 'keepSnapshotDays', by: 'other@example.com', utc: '2026-11-05T08:00:00Z' },
      { setting: 'onDDataFound', by: 'approver@example.com', utc: '2026-11-02T09:40:00Z' },
    ] },
    { vmId: '/s/b', wave: 'w', policy: { keepSnapshotDays: 14 } },
    { vmId: '/s/c', wave: 'w', policy: {} },
    { vmId: '/s/k', wave: 'w', policy: { onDriverBelowFloor: 'updateKernel' } },
  ];
  const w = { ...WAVE_DEFAULTS, vmIds: entries.map(e => e.vmId), drawn: { ...WAVE_DEFAULTS } };
  globalThis.layout = new Map([['w', w]]);
  globalThis.ownHelp = new Set();
  globalThis.canEdit = edit;
  globalThis.canSignOff = signOff;
  globalThis.waveMigrating = () => running;
  return w;
}
/** The text of each row of an open box, tags and the button taken out. */
function rows(html) {
  return [...html.matchAll(/<span class="hint" data-ownrow>(.*?)(?: <button[\s\S]*?<\/button>(?: <span class="hint">[^<]*<\/span>)?)?<\/span>/g)].map(m => m[1]);
}

test('the closed line says how many machines do not follow the setting, with ? to open', () => {
  const w = setUp();
  const one = ownHint('w', w, 'onDDataFound');
  ok(one.includes('>1 machine does not follow this setting. <button'), one);
  ok(one.includes('>?</button>') && one.includes('aria-expanded="false"'), one);
  eq(rows(one), [], 'a closed box shows no machine');
  ok(one.includes('title="Show the machines that do not follow this setting">?</button>'), 'the closed ? says what it shows');
  ownHelp.add('w|onDDataFound');
  ok(ownHint('w', w, 'onDDataFound').includes('aria-label="Close" title="Close">Close</button>'), 'the open button says Close, in its tip too');
  ownHelp.clear();
  const many = ownHint('w', { ...w, drawn: { ...WAVE_DEFAULTS, keepSnapshotDays: 30 } }, 'keepSnapshotDays');
  ok(many.includes('>4 machines do not follow this setting. <button'), many);
});

test('case 1: a decision - the value, who accepted it and the day, from the newest decision for that setting', () => {
  const w = setUp();
  ownHelp.add('w|onDDataFound');
  const open = ownHint('w', w, 'onDDataFound');
  eq(rows(open), [esc(`a: Continue - the files are deleted. approver@example.com accepted this for the machine on ${DAY('2026-11-02T09:40:00Z')}.`)]);
  ok(!open.includes('old@example.com') && !open.includes('other@example.com'), 'only the newest decision for this setting');
  ok(open.includes(`data-resetvm="/s/a"`) && open.includes(`>${USE}</button>`), 'the button says Use the wave\'s setting');
  ok(DAY('2026-11-02T09:40:00Z').includes('2026'), 'the day has its year');
});

test('case 1 without a readable day names who accepted it, and nothing else', () => {
  const w = setUp();
  entries[0].decisions = [{ setting: 'onDDataFound', by: 'approver@example.com', utc: 'not a day' }];
  ownHelp.add('w|onDDataFound');
  eq(rows(ownHint('w', w, 'onDDataFound')), [esc('a: Continue - the files are deleted. approver@example.com accepted this for the machine.')]);
  entries[0].decisions = [{ setting: 'onDDataFound', by: '', utc: 'not a day' }];
  eq(rows(ownHint('w', w, 'onDDataFound')), [esc('a: Continue - the files are deleted.')], 'no name: the value only');
});

test('case 2: no decision - the value only, with the label the setting shows', () => {
  const w = setUp();
  ownHelp.add('w|keepSnapshotDays');
  // a holds a decision for this setting too, at the value of the wave: it is named with its cause.
  eq(rows(ownHint('w', w, 'keepSnapshotDays')), [esc(`a: 7 days. other@example.com accepted this for the machine on ${DAY('2026-11-05T08:00:00Z')}.`), esc('b: 14 days.')]);
  // The card shows Continue; c holds Stop and ask by hand.
  w.drawn.onDDataFound = 'proceed'; w.onDDataFound = 'proceed';
  entries[0].decisions = []; entries[1].policy.onDDataFound = 'proceed';
  ownHelp.add('w|onDDataFound');
  const open = ownHint('w', w, 'onDDataFound');
  eq(rows(open), [esc('c: Stop and ask.'), esc('k: Stop and ask.')]);
  ok(!/accepted|chose/i.test(rows(open).join(' ')), 'nothing is said about why');
});

// WAVE-KERNEL-LINE-1 (2026-11-14): Update the kernel is not a value of
// a wave setting, so the machine is never listed as one that does not follow
// its wave. The wave card names it on its own row (wave-kernel-line.test.js).
test('case 3: Update the kernel - no wave kernel setting, so no line and no button', () => {
  const w = setUp();
  ownHelp.add('w|onDriverBelowFloor');
  eq(ownHint('w', w, 'onDriverBelowFloor'), '');
});

test('the value label is the label of the setting\'s own control', () => {
  eq(ownValueText('onDDataFound', 'stop'), UX.dataStop);
  eq(ownValueText('onDDataFound', 'proceed'), UX.dataProceed);
  eq(ownValueText('keepSnapshotDays', 30), `30 ${UX.keepDays}`);
});

test('pending: the row says what the save does, the button and the box say Cancel', () => {
  const w = setUp();
  ownHelp.add('w|onDDataFound');
  toggleReset('w', 'onDDataFound', '/s/a');
  const pending = ownHint('w', w, 'onDDataFound');
  eq(rows(pending), [esc("a uses the wave's setting when you save.")]);
  ok(pending.includes(`>${UX.cancel}</button>`) && pending.includes('aria-pressed="true"'), 'the button says Cancel');
  ok(/data-ownhelp="w\|onDDataFound"[^>]*>Cancel<\/button>/.test(pending), 'the box button says Cancel while a reset is not saved');
  toggleReset('w', 'onDDataFound', '/s/a');
  ok(/data-ownhelp="w\|onDDataFound"[^>]*>Close<\/button>/.test(ownHint('w', w, 'onDDataFound')), 'and Close again');
});

test('locked: an operator cannot give a machine Continue; the row still says the value', () => {
  const w = setUp({ signOff: false });
  w.onDDataFound = 'proceed'; w.drawn.onDDataFound = 'proceed';
  entries[0].decisions = []; entries[1].policy.onDDataFound = 'proceed';
  ownHelp.add('w|onDDataFound');
  const locked = ownHint('w', w, 'onDDataFound');
  ok(/data-resetvm="\/s\/c"[^>]* disabled[^>]*>Use the wave&#39;s setting<\/button>/.test(locked), locked);
  ok(locked.includes(`<span class="hint">${esc('Only an approver can give this machine the value Continue.')}</span>`), locked);
  eq(rows(locked)[0], esc('c: Stop and ask.'));
});

test('a person who cannot change waves, or a running wave: each row still says the value and why, with no button', () => {
  for (const opts of [{ edit: false }, { running: true }]) {
    const w = setUp(opts);
    ownHelp.add('w|onDDataFound');
    const open = ownHint('w', w, 'onDDataFound');
    ok(!open.includes('data-ownreset'), JSON.stringify(opts));
    eq(rows(open), [esc(`a: Continue - the files are deleted. approver@example.com accepted this for the machine on ${DAY('2026-11-02T09:40:00Z')}.`)]);
  }
});

test('the explanation paragraph and the "own value" words are gone', () => {
  for (const key of ['ownHelp', 'ownResetHow', 'ownResetTip']) eq(UX[key], undefined, `UX.${key} is removed`);
  const w = setUp();
  for (const field of ['onDDataFound', 'keepSnapshotDays']) {
    ownHelp.add(`w|${field}`);
    const open = ownHint('w', w, field);
    ok(!/own value|value of the wave|Reset/.test(open), `${field}: ${open}`);
  }
  ok(!SRC.includes('gives it its own value'), 'the paragraph is not in the page');
});

run('wave-own-words');
