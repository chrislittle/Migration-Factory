/* WAVE-LEVER-RESET-1: the wave editor gives a machine back the value of its
 * wave.
 *
 * WAVE-LEVER-OVERRIDE-1 made a machine keep its own value for a setting - a
 * decision for it, or a value set by hand - when its wave's card changes. The
 * only way back to the wave's value was to plan the machine again. Now the ?
 * helper of a setting lists each machine with its own value, with a Reset
 * beside it. Reset becomes Cancel (one button, two states), the helper's own
 * Cancel and Escape cancel every reset not saved (rule 11), and a save sends
 * the machines reset per setting (`reset`), which the engine writes
 * (tests/unit/WaveLeverReset.Tests.ps1).
 *
 * RUN, not read: the page's own functions.
 */
'use strict';
const { pageSource } = require('./_page-source');
const fs = require('fs');
const path = require('path');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// ACCEPT-FIRST-MACHINE-1: the settings of a wave are read by the rule in
// help.js; waves.js names its parts (leverValue, keepsOwn, waveCard) as
// aliases of VmfHelp, so the page functions find them on the global object.
function waveRuleGlobal() { const r = require('./_at-once').waveRule; Object.assign(globalThis, { leverValue: r.leverValue, ownDecision: r.ownDecision, keepsOwn: r.keepsOwn, waveCard: r.waveCard }); return r; }
// MACHINES-AT-ONCE-RANGE-1: the page functions draw a wave's machines at once.
require('./_at-once').install();

const UX = liftConst('waves.html', 'UX');
globalThis.UX = UX;
globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
globalThis.WAVE_WIDE = ['capacityGate', 'requireApproval', 'throttle'];
const approvalRequired = lift('help.js', 'approvalRequired');
globalThis.VmfHelp = { approvalRequired };
const page = ({ ...waveRuleGlobal(), ...liftAll('waves.html', ['ownOf', 'ownHint', 'ownRow', 'resetOf', 'resetPending', 'toggleReset', 'clearResets', 'resetLocked', 'toggleOwnHelp', 'changedOf', 'snapshot']) });
Object.assign(globalThis, page);
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.vmName = (id) => String(id).split('/').pop();
globalThis.membersOf = (name) => entries.filter(e => layout.get(name).vmIds.includes(e.vmId));
const SRC = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));

// Wave w: a decided Continue for a, b by hand 14 days, c plain, and k that
// updates its kernel. The card shows the defaults.
function setUp({ edit = true, signOff = true, running = false } = {}) {
  globalThis.entries = [
    { vmId: '/s/a', wave: 'w', policy: { onDDataFound: 'proceed' }, decisions: [{ setting: 'onDDataFound', by: 'x', utc: 'y' }] },
    { vmId: '/s/b', wave: 'w', policy: { keepSnapshotDays: 14 } },
    { vmId: '/s/c', wave: 'w', policy: {} },
    { vmId: '/s/k', wave: 'w', policy: { onDriverBelowFloor: 'updateKernel' } },
  ];
  const w = { ...WAVE_DEFAULTS, vmIds: entries.map(e => e.vmId), drawn: { ...WAVE_DEFAULTS } };
  globalThis.layout = new Map([['w', w]]);
  globalThis.ownHelp = new Set();
  globalThis.idHelp = new Set();
  globalThis.canEdit = edit;
  globalThis.canSignOff = signOff;
  globalThis.waveMigrating = () => running;
  return w;
}

test('the open ? lists each machine with its own value, with a Reset beside it', () => {
  const w = setUp();
  eq(ownHint('w', w, 'onDDataFound').includes('data-ownreset'), false, 'a closed helper offers no Reset');
  ownHelp.add('w|onDDataFound');
  const open = ownHint('w', w, 'onDDataFound');
  // WAVE-OWN-PICTURE-1: each row says the value and its cause (tests/js/wave-own-words.test.js).
  ok(open.includes('data-ownrow>a: '), open);
  ok(open.includes('data-ownreset="w|onDDataFound"') && open.includes('data-resetvm="/s/a"'), 'a Reset for machine a');
  ok(open.includes(`>${esc(UX.ownReset)}</button>`) && open.includes('aria-pressed="false"'), open);
  ownHelp.add('w|keepSnapshotDays');
  const keep = ownHint('w', w, 'keepSnapshotDays');
  ok(keep.includes('data-resetvm="/s/b"') && !keep.includes('data-resetvm="/s/c"'), 'only the machine with its own value');
});

test('Reset becomes Cancel and says what a save does; Cancel puts it back', () => {
  const w = setUp();
  ownHelp.add('w|onDDataFound');
  toggleReset('w', 'onDDataFound', '/s/a');
  eq(resetPending(w, 'onDDataFound', '/s/a'), true);
  const pending = ownHint('w', w, 'onDDataFound');
  ok(pending.includes(esc(UX.ownResetPending.replace('{name}', 'a'))), pending);
  ok(pending.includes(`>${UX.cancel}</button>`) && pending.includes('aria-pressed="true"'), 'the Reset is now Cancel');
  eq(resetOf(w), { onDDataFound: ['/s/a'] });
  toggleReset('w', 'onDDataFound', '/s/a');
  eq(resetPending(w, 'onDDataFound', '/s/a'), false);
  eq(resetOf(w), {}, 'Cancel takes the reset away');
});

test('what a save sends: no setting of the wave, no machine that left the wave', () => {
  const w = setUp();
  w.reset = { onDDataFound: ['/s/a', '/s/gone'], throttle: ['/s/c'], keepSnapshotDays: [] };
  eq(resetOf(w), { onDDataFound: ['/s/a'] });
  eq(resetOf({ vmIds: ['/s/a'] }), {}, 'a wave with no reset sends none');
});

test('a reset not saved makes the page changed, so Save writes it', () => {
  const w = setUp();
  const before = snapshot();
  toggleReset('w', 'onDDataFound', '/s/a');
  ok(snapshot() !== before, 'the snapshot changed');
  toggleReset('w', 'onDDataFound', '/s/a');
  eq(snapshot(), before, 'and is the same again after Cancel');
});

test('the helper\'s Cancel closes it and cancels its resets; another helper keeps its own', () => {
  const w = setUp();
  globalThis.render = () => {};
  toggleOwnHelp('w|onDDataFound');
  toggleOwnHelp('w|keepSnapshotDays');
  toggleReset('w', 'onDDataFound', '/s/a');
  toggleReset('w', 'keepSnapshotDays', '/s/b');
  toggleOwnHelp('w|onDDataFound');
  eq(ownHelp.has('w|onDDataFound'), false, 'the helper is closed');
  eq(resetOf(w), { keepSnapshotDays: ['/s/b'] }, 'its reset is cancelled; the other stays');
});

test('Escape closes every helper and cancels every reset not saved', () => {
  const w = setUp();
  let rendered = 0;
  globalThis.render = () => { rendered++; };
  globalThis.closeChange = () => {};
  globalThis.change = { vmId: null };
  ownHelp.add('w|onDDataFound');
  toggleReset('w', 'onDDataFound', '/s/a');
  const onEscape = lift('waves.html', 'onEscape');
  onEscape({ key: 'Enter' });
  eq(resetOf(w), { onDDataFound: ['/s/a'] }, 'another key does nothing');
  onEscape({ key: 'Escape' });
  eq(ownHelp.size, 0);
  eq(resetOf(w), {}, 'the reset is cancelled');
  eq(rendered, 1);
});

test('no Reset for a person who cannot change waves, or on a running wave', () => {
  for (const opts of [{ edit: false }, { running: true }]) {
    const w = setUp(opts);
    ownHelp.add('w|onDDataFound');
    const open = ownHint('w', w, 'onDDataFound');
    ok(!open.includes('data-ownreset'), JSON.stringify(opts));
    ok(open.includes('data-ownrow>a: '), 'the machine is still named');
  }
});

test('DECIDE-2: a Reset to Continue needs an approver; a Reset to Stop and ask does not', () => {
  const w = setUp({ signOff: false });
  ownHelp.add('w|onDDataFound');
  ok(!ownHint('w', w, 'onDDataFound').includes(' disabled'), 'a back to Stop and ask: an operator may');
  // The card shows Continue, and c holds Stop and ask by hand.
  w.onDDataFound = 'proceed'; w.drawn.onDDataFound = 'proceed';
  entries[0].decisions = []; entries[0].policy = { onDDataFound: 'proceed' };
  entries[1].policy.onDDataFound = 'proceed';
  const locked = ownHint('w', w, 'onDDataFound');
  ok(/data-resetvm="\/s\/c"[^>]* disabled/.test(locked) && locked.includes(esc(UX.ownResetLocked)), locked);
  globalThis.canSignOff = true;
  ok(!/data-resetvm="\/s\/c"[^>]* disabled/.test(ownHint('w', w, 'onDDataFound')), 'an approver may');
});

test('WAVE-KERNEL-LINE-1: a machine that updates its kernel is not one that does not follow its wave, so it has no Reset', () => {
  const w = setUp();
  ownHelp.add('w|onDriverBelowFloor');
  eq(ownHint('w', w, 'onDriverBelowFloor'), '', 'no wave kernel setting, so no list and no Reset');
  ownHelp.add('w|onDDataFound');
  ok(!ownHint('w', w, 'onDDataFound').includes('data-resetvm="/s/k"'), 'k follows every setting of its wave');
});

test('a save sends the resets of each wave, a running wave sends none, and the next save sends none again', async () => {
  const lever = { ...WAVE_DEFAULTS };
  globalThis.layout = new Map([
    ['w1', { ...lever, vmIds: ['a'], drawn: { ...lever }, reset: { onDDataFound: ['a'] } }],
    ['w2', { ...lever, vmIds: ['b'], drawn: { ...lever }, reset: { keepSnapshotDays: ['b'] } }],
  ]);
  globalThis.waveMigrating = (n) => n === 'w1';
  const sent = [];
  globalThis.apiPost = async (_p, body) => { sent.push(body); return {}; };
  globalThis.runSeg = () => 'r1';
  globalThis.runBody = (b) => b;
  globalThis.original = '';
  // WAVE-OWN-PICTURE-1: the save of a real run, which reads the plan again.
  globalThis.DEMO_MODE = false;
  globalThis.reloadPlan = async () => {};
  globalThis.planVersion = 'v1';
  const writeLayout = lift('waves.html', 'writeLayout');
  await writeLayout();
  eq(Object.keys(sent[0].waves.find(w => w.name === 'w1')).sort(), ['name', 'vmIds'], 'a running wave sends no reset');
  eq(sent[0].waves.find(w => w.name === 'w2').reset, { keepSnapshotDays: ['b'] });
  await writeLayout();
  eq(sent[1].waves.find(w => w.name === 'w2').reset, {}, 'a reset saved is not sent twice');
});

test('the Reset is wired, and the save result names the machines reset', () => {
  ok(SRC.includes("document.querySelectorAll('[data-ownreset]')"), 'the Reset button is wired');
  ok(/toggleOwnHelp\(b\.dataset\.ownhelp\)/.test(SRC), 'the ? button closes through toggleOwnHelp, which cancels the resets');
  ok(SRC.includes('r?.ResetToWave'), 'the page reads what the save reset');
  ok(UX.savedReset.includes('{names}'));
});

run('wave-lever-reset');
