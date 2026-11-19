/* WAVE-LEVER-OVERRIDE-1: the wave editor no longer writes a wave card over a
 * machine's own answer.
 *
 * The card was drawn from the FIRST machine of a wave and every save sent all
 * seven settings for every wave, so a decision for one machine was written
 * over on the next save - or spread to the whole wave when that machine was
 * first. Now the card shows what most machines without a decision hold, says
 * how many keep their own value, and a save sends only the settings the person
 * changed, with the value the card showed.
 *
 * RUN, not read: the page's own functions, held to the same fixture as the
 * engine (tests/fixtures/wave-own-settings.json).
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

const FIXTURE = JSON.parse(fs.readFileSync(path.join(__dirname, '..', 'fixtures', 'wave-own-settings.json'), 'utf8'));
const UX = liftConst('waves.html', 'UX');
globalThis.UX = UX;
globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
globalThis.WAVE_WIDE = ['capacityGate', 'requireApproval', 'throttle'];
// SIGNOFF-NULL-1: the card reads the sign-off by the one rule in help.js.
const approvalRequired = lift('help.js', 'approvalRequired');
globalThis.VmfHelp = { approvalRequired };
const card = ({ ...waveRuleGlobal(), ...liftAll('waves.html', ['ownOf', 'changedOf', 'ownHint']) });
globalThis.esc = (v) => String(v ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
globalThis.vmName = (id) => String(id).split('/').pop();

const members = (c, wave) => c.entries.map(e => ({ vmId: e.name, wave, policy: e.policy, decisions: e.decisions }));

for (const c of FIXTURE.cases) {
  test(`fixture: ${c.name}`, () => {
    const { values, own } = card.waveCard(members(c, FIXTURE.wave));
    for (const [field, want] of Object.entries(c.card)) { eq(values[field], want, `the card shows ${field}`); }
    for (const [field, want] of Object.entries(c.own)) { eq(own[field], want, `the machines that keep their own ${field}`); }
  });
}

test('the card is not drawn from the first machine when that machine holds a decision', () => {
  globalThis.entries = [
    { vmId: 'a', wave: 'w', policy: { onDDataFound: 'proceed' }, decisions: [{ setting: 'onDDataFound', by: 'approver@example.com', utc: 'x' }] },
    { vmId: 'b', wave: 'w', policy: { onDDataFound: 'stop' } },
    { vmId: 'c', wave: 'v', policy: { throttle: 5 } },
  ];
  globalThis.planWaveOrder = ['w', 'v'];
  globalThis.VmfHelp = { waveOrder: () => ['w', 'v'], approvalRequired };
  globalThis.membersOf = (name) => entries.filter(e => layout.get(name).vmIds.includes(e.vmId));
  globalThis.waveCard = card.waveCard;
  globalThis.snapshot = () => 'drawn';
  globalThis.layout = new Map();
  globalThis.original = '';
  lift('waves.html', 'buildLayoutFromPlan')();
  eq(layout.get('w').onDDataFound, 'stop', 'the card shows what b holds, not the answer a decision gave a');
  eq(layout.get('w').drawn.onDDataFound, 'stop', 'what the card showed is kept beside it');
  eq(layout.get('v').throttle, 5);
  eq(original, 'drawn');
});

test('only the settings changed on the card are listed, each with the value the card showed', () => {
  const w = { capacityGate: 'BestEffort', requireApproval: true, onDDataFound: 'proceed', onDriverBelowFloor: 'stop',
    keepSnapshotDays: 7, throttle: 4 };
  w.drawn = { ...w, onDDataFound: 'stop', throttle: 3 };
  eq(card.changedOf(w), { onDDataFound: 'stop', throttle: 3 });
  eq(card.changedOf({ ...w, drawn: { ...w } }), {}, 'a card nobody changed lists nothing');
  const fresh = { ...w }; delete fresh.drawn;
  eq(card.changedOf(fresh), {}, 'a new wave has no drawn card: every machine joins it and takes the card');
});

test('a save sends the changed settings, a running wave sends none, and the next save compares with what was saved', async () => {
  const lever = { capacityGate: 'BestEffort', requireApproval: true, onDDataFound: 'stop', onDriverBelowFloor: 'stop',
    keepSnapshotDays: 7, throttle: 3 };
  globalThis.layout = new Map([
    ['w1', { ...lever, vmIds: ['a'], drawn: { ...lever } }],
    ['w2', { ...lever, keepSnapshotDays: 14, vmIds: ['b'], drawn: { ...lever } }],
  ]);
  globalThis.waveMigrating = (n) => n === 'w1';
  const sent = [];
  globalThis.apiPost = async (_p, body) => { sent.push(body); return {}; };
  globalThis.runSeg = () => 'r1';
  globalThis.runBody = (b) => b;
  globalThis.snapshot = () => 's';
  globalThis.original = '';
  // WAVE-OWN-PICTURE-1: the save of a real run, which reads the plan again.
  globalThis.DEMO_MODE = false;
  globalThis.reloadPlan = async () => {};
  globalThis.planVersion = 'v1';
  globalThis.changedOf = card.changedOf;
  globalThis.resetOf = () => ({});   // WAVE-LEVER-RESET-1: no machine reset here
  const writeLayout = lift('waves.html', 'writeLayout');
  await writeLayout();
  const w1 = sent[0].waves.find(w => w.name === 'w1');
  const w2 = sent[0].waves.find(w => w.name === 'w2');
  eq(Object.keys(w1).sort(), ['name', 'vmIds'], 'a running wave sends its machines and no setting');
  eq(w2.changed, { keepSnapshotDays: 7 }, 'only the snapshot days changed, from the 7 the card showed');
  eq(w2.keepSnapshotDays, 14);
  await writeLayout();
  eq(sent[1].waves.find(w => w.name === 'w2').changed, {}, 'after the save the card is drawn again, so nothing is listed twice');
});

test('the card names how many machines do not follow a setting, and the ? opens which ones and why', () => {
  globalThis.entries = [
    { vmId: '/s/a', wave: 'w', policy: { onDDataFound: 'proceed' }, decisions: [{ setting: 'onDDataFound', by: 'x', utc: 'y' }] },
    { vmId: '/s/b', wave: 'w', policy: { keepSnapshotDays: 14 } },
    { vmId: '/s/c', wave: 'w', policy: {} },
    { vmId: '/s/d', wave: 'old', policy: { keepSnapshotDays: 30 } },
  ];
  const w = { vmIds: ['/s/a', '/s/b', '/s/c', '/s/d'], drawn: { ...WAVE_DEFAULTS } };
  globalThis.layout = new Map([['w', w]]);
  globalThis.membersOf = (name) => entries.filter(e => layout.get(name).vmIds.includes(e.vmId));
  globalThis.ownOf = card.ownOf;
  globalThis.ownHelp = new Set();
  // WAVE-LEVER-RESET-1: the open helper lists each machine, with a Reset for a
  // person who can change the wave (tests/js/wave-lever-reset.test.js).
  Object.assign(globalThis, ({ ...waveRuleGlobal(), ...liftAll('waves.html', ['ownRow', 'resetPending', 'resetLocked']) }));
  globalThis.leverValue = card.leverValue;
  globalThis.canEdit = false;
  globalThis.waveMigrating = () => false;
  const data = card.ownHint('w', w, 'onDDataFound');
  ok(data.includes('1 machine does not follow this setting.') && data.includes('>?</button>') && data.includes(`aria-expanded="false"`), data);
  // d is joining the wave: it takes the card, so it does not keep its 30.
  eq(card.ownOf('w', w, 'keepSnapshotDays').map(e => e.vmId), ['/s/b'], 'b stays and holds 14; d joins and takes the card');
  eq(card.ownHint('w', w, 'throttle'), '', 'no machine keeps its own value: nothing is said');
  // A setting of the wave: no machine keeps its own, even one that differs.
  entries[1].policy.throttle = 9;
  eq(card.ownOf('w', w, 'throttle').length, 0, 'how many at once is one value for the wave');
  delete entries[1].policy.throttle;
  ownHelp.add('w|onDDataFound');
  const open = card.ownHint('w', w, 'onDDataFound');
  ok(open.includes(`>${UX.close}</button>`) && open.includes('aria-expanded="true"'), 'the open ? becomes Close');
  // WAVE-OWN-PICTURE-1: each machine on its own line, with its value and the cause.
  ok(open.includes('<span class="hint" data-ownrow>a: Continue - the files are deleted. x accepted this for the machine.</span>'), open);
  // Three stay and differ from a card that showed 30: a and c (no value, so 7)
  // and b (14 by hand). d joins, so it takes the card.
  const many = card.ownHint('w', { ...w, drawn: { ...WAVE_DEFAULTS, keepSnapshotDays: 30 } }, 'keepSnapshotDays');
  ok(many.includes('3 machines do not follow this setting.'), many);
});

test('Escape closes an open ? helper, and the size series panel first', () => {
  let rendered = 0, closed = 0;
  globalThis.render = () => { rendered++; };
  globalThis.closeChange = () => { closed++; };
  globalThis.change = { vmId: null };
  globalThis.ownHelp = new Set(['w|throttle']);
  // WAVE-LEVER-RESET-1: Escape also cancels the resets not saved.
  globalThis.clearResets = () => {};
  // IDENTITY-LOSS-1: Escape closes the ? helper of a New identity pill too.
  globalThis.idHelp = new Set();
  const onEscape = lift('waves.html', 'onEscape');
  onEscape({ key: 'Enter' });
  eq(ownHelp.size, 1, 'another key does nothing');
  onEscape({ key: 'Escape' });
  eq(ownHelp.size, 0);
  eq(rendered, 1);
  globalThis.change = { vmId: 'x' };
  ownHelp.add('w|throttle');
  onEscape({ key: 'Escape' });
  eq(closed, 1);
  eq(ownHelp.size, 1, 'one Escape closes one thing');
});

test('every setting on the card carries its hint, and the ? is wired', () => {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  // The three settings of the wave have no hint: no machine keeps its own value of one.
  for (const field of Object.keys(WAVE_DEFAULTS).filter(f => !WAVE_WIDE.includes(f))) { ok(src.includes(`\${ownHint(name, w, '${field}')}`), `the card shows the hint for ${field}`); }
  ok(src.includes("document.querySelectorAll('[data-ownhelp]')"), 'the ? button is wired');
  ok(src.includes("document.addEventListener('keydown', onEscape);"), 'Escape is wired');
});

test('the page knows the same three settings of the wave as the engine', () => {
  const src = pageSource(path.join(__dirname, '..', '..', 'src', 'dashboard', 'waves.html'));
  // ACCEPT-FIRST-MACHINE-1: the table is in help.js, and the page reads it from there.
  ok(src.includes('const WAVE_WIDE = VmfHelp.waveWideSettings();'), 'the page reads the table of help.js');
  const help = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'dashboard', 'help.js'), 'utf8');
  ok(help.includes("function waveWideSettings() { return ['capacityGate', 'requireApproval', 'throttle']; }"), 'the table');
  const ps = fs.readFileSync(path.join(__dirname, '..', '..', 'src', 'VmMigrationFactory', 'Private', 'plan', 'WaveSettings.ps1'), 'utf8');
  ok(ps.includes("$script:VmfWaveWideFields = @('capacityGate', 'requireApproval', 'throttle')"), 'the engine table');
  for (const f of WAVE_WIDE) { ok(!src.includes(`\${ownHint(name, w, '${f}')}`), `no hint for ${f}`); }
});

test('DECIDE-ROLE-1: a value saved in another case is read as its own value, and anything else as the default', () => {
  // A plan saved before the service compared these exactly can hold
  // 'PROCEED'. The card showed no option and every wave save sent it back,
  // which the service now refuses - so no wave could be saved.
  const m = (policy) => [{ vmId: 'a', wave: 'w', policy }];
  eq(card.waveCard(m({ onDDataFound: 'PROCEED' })).values.onDDataFound, 'proceed', 'PROCEED');
  eq(card.waveCard(m({ onDDataFound: 'Proceed' })).values.onDDataFound, 'proceed', 'Proceed');
  // WAVE-KERNEL-LINE-1: no wave has a kernel setting to read.
  eq(card.waveCard(m({ onDriverBelowFloor: 'STOP' })).values.onDriverBelowFloor, undefined, 'no kernel setting');
  eq(card.waveCard(m({ capacityGate: 'reserved' })).values.capacityGate, 'Reserved', 'the capacity gate too');
  eq(card.waveCard(m({ onDDataFound: 'pro\u200Bceed' })).values.onDDataFound, 'stop',
    'a value that is not one of its own, even by case, is the safe default');
  eq(card.waveCard(m({ onDDataFound: ['proceed'] })).values.onDDataFound, 'stop', 'and so is a list');
  eq(card.waveCard(m({ onDDataFound: 'proceed' })).values.onDDataFound, 'proceed', 'a correct value is unchanged');

});

run('wave-lever-override');