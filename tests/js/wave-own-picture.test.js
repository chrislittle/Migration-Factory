/* WAVE-OWN-PICTURE-1: the wave editor's list of the machines that have their
 * own value has a picture, and the sample page shows a save at once.
 *
 * 1. The manual described the list under the "?" of a setting, and its Reset,
 *    in words only: every picture of the wave editor showed the page as it
 *    first opens. tools/manual-shots.js now opens the list on the sample page
 *    (waves.html?demo) and takes a picture, and the section "Give a machine
 *    the value of its wave" shows it.
 * 2. On the sample page, a save kept the cards as they were sent and read
 *    nothing again, so a machine given the value of its wave still showed in
 *    the list until the page was loaded again. The real page reads the plan
 *    again after a save (reloadPlan). The sample now writes the save into its
 *    own plan by the rule the service uses (Get-VmfWaveSettingWrites, held to
 *    tests/fixtures/wave-own-settings.json here as the engine is in
 *    WaveLeverOverride.Tests.ps1), then reads it again the same way.
 *
 * RUN, not read: the sample page is booted and saved, and the save function
 * of the sample is called with the cases of the engine's fixture.
 */
'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { lift, liftAll, liftConst, test, eq, ok, run } = require('./_harness');

// ACCEPT-FIRST-MACHINE-1: the settings of a wave are read by the rule in
// help.js; waves.js names its parts (leverValue, keepsOwn, waveCard) as
// aliases of VmfHelp, so the page functions find them on the global object.
function waveRuleGlobal() { const r = require('./_at-once').waveRule; Object.assign(globalThis, { leverValue: r.leverValue, ownDecision: r.ownDecision, keepsOwn: r.keepsOwn, waveCard: r.waveCard }); return r; }
const { bootPage, settle } = require('./_dom');
const { atOnce } = require('./_at-once');

const REPO = path.join(__dirname, '..', '..');
const nameOf = (id) => String(id).split('/').pop();

// ---------------------------------------------------------------- 1. picture
const SHOTS_SRC = fs.readFileSync(path.join(REPO, 'tools', 'manual-shots.js'), 'utf8');
const SHOTS = (() => {
  const m = SHOTS_SRC.match(/\nconst SHOTS = (\[[\s\S]*?\n\]);/);
  if (!m) { throw new Error('could not read SHOTS'); }
  return eval(m[1]);   // eslint-disable-line no-eval
})();
const PICTURE = 'wave-own-value.png';
const shot = SHOTS.find(s => s.file === PICTURE);

test('the screenshot tool opens the list of the machines with their own value on the sample page', () => {
  ok(shot, `tools/manual-shots.js takes ${PICTURE}`);
  ok(/^waves\.html\?demo$/.test(shot.url), `the sample wave editor: ${shot.url}`);
  ok(/\[data-ownhelp="[^"]+\|[^"]+"\]/.test(shot.act) && /\.click\(\)/.test(shot.act), `the act selects the ? of a setting: ${shot.act}`);
  ok(/^\[data-ownreset="[^"]+"\]$/.test(shot.expect), `the picture is taken only when Reset shows: ${shot.expect}`);
  const opened = shot.act.match(/data-ownhelp="([^"]+)"/)[1];
  eq(shot.expect.match(/data-ownreset="([^"]+)"/)[1], opened, 'the Reset of the list that the act opens');
});

test('the list the picture opens holds a machine of the sample with Reset beside it', async () => {
  const key = shot.act.match(/data-ownhelp="([^"]+)"/)[1];
  const r = bootPage('waves.html');
  await settle(r);
  const out = JSON.parse(vm.runInContext(`(() => {
    const key = ${JSON.stringify(key)};
    const cut = key.lastIndexOf('|');
    const name = key.slice(0, cut), field = key.slice(cut + 1);
    const w = layout.get(name);
    if (!w) return JSON.stringify({ wave: false });
    ownHelp.add(key);
    const html = ownHint(name, w, field);
    ownHelp.delete(key);
    return JSON.stringify({ wave: true, own: ownOf(name, w, field).map(e => e.vmId), html });
  })()`, r.sandbox));
  ok(out.wave, `${key} names a wave of the sample`);
  eq(out.own.map(nameOf).join(', '), 'prd-win-b', 'the machine with its own value');
  ok(out.html.includes(`data-ownreset="${key}"`) && out.html.includes('prd-win-b'), 'the open list shows the machine with its button');
  // The picture shows a decision: the value, who accepted it, and the day.
  ok(/data-ownrow>prd-win-b: Continue - the files are deleted\. operator@example\.com accepted this for the machine on [^<]*2026\. <button/.test(out.html), out.html);
});

test('the section "Make a machine use the setting of its wave" shows the picture', () => {
  const page = fs.readFileSync(path.join(REPO, 'docs', 'manual', 'use', 'wave-settings.md'), 'utf8');
  const start = page.indexOf('### Make a machine use the setting of its wave');
  ok(start >= 0, 'the section is on the page');
  const rest = page.slice(start + 5);
  const end = rest.search(/\n#{2,3} |\n<!-- next:begin -->/);
  const section = end >= 0 ? rest.slice(0, end) : rest;
  ok(new RegExp(`!\\[[^\\]]+\\]\\(\\.\\./images/${PICTURE.replace('.', '\\.')}\\)`).test(section), `the section shows ${PICTURE}`);
  ok(fs.existsSync(path.join(REPO, 'docs', 'manual', 'images', PICTURE)), 'the picture is in docs/manual/images');
});

// ------------------------------------------------------- 2. the sample save
/** The sample page booted, with timers that run, so its save can finish. */
async function sample() {
  const r = bootPage('waves.html');
  await settle(r);
  vm.runInContext('setTimeout = (fn) => { Promise.resolve().then(fn); return 0; };', r.sandbox);
  return r;
}
const inPage = async (r, body) => JSON.parse(await vm.runInContext(`(async () => { ${body} })()`, r.sandbox));

test('on the sample page, Reset and Save take the machine out of the list at once, as the real page does after it reads the plan', async () => {
  const r = await sample();
  const out = await inPage(r, `
    const key = 'billing-apps|onDDataFound';
    const id = entries.find(e => e.vmId.endsWith('/prd-win-b')).vmId;
    const before = ownOf('billing-apps', layout.get('billing-apps'), 'onDDataFound').map(e => e.vmId);
    ownHelp.add(key);
    toggleReset('billing-apps', 'onDDataFound', id);
    await save();
    const e = entries.find(x => x.vmId === id);
    return JSON.stringify({
      before, after: ownOf('billing-apps', layout.get('billing-apps'), 'onDDataFound').map(x => x.vmId),
      value: e.policy.onDDataFound, decided: (e.decisions || []).some(d => d.setting === 'onDDataFound'),
      planValue: DEMO_PLAN.entries.find(x => x.vmId === id).policy.onDDataFound,
      dirty: dirty(), ok: document.querySelector('#ok').textContent,
      list: ownHint('billing-apps', layout.get('billing-apps'), 'onDDataFound'),
    });`);
  eq(out.before.map(nameOf).join(', '), 'prd-win-b', 'before the save');
  eq(out.after.join(', '), '', 'after the save, no machine has its own value');
  eq(out.value, 'stop', 'the machine has the value of its wave');
  eq(out.planValue, 'stop', 'the sample plan holds it');
  eq(out.decided, false, 'the record of the decision for that setting went');
  eq(out.dirty, false, 'nothing is left to save');
  ok(out.ok.includes('prd-win-b'), `the save names the machine it reset: ${out.ok}`);
  eq(out.list, '', 'the line "1 machine does not follow this setting." is gone');
});

test('on the sample page, a change saved on a card is in every machine of the wave, and the card shows it', async () => {
  const r = await sample();
  const out = await inPage(r, `
    layout.get('storefront-pilot').keepSnapshotDays = 14;
    await save();
    return JSON.stringify({
      card: layout.get('storefront-pilot').keepSnapshotDays,
      drawn: layout.get('storefront-pilot').drawn.keepSnapshotDays,
      values: membersOf('storefront-pilot').map(e => e.policy.keepSnapshotDays),
      other: membersOf('billing-apps').map(e => e.policy.keepSnapshotDays),
      dirty: dirty(),
    });`);
  eq(out.card, 14, 'the card');
  eq(out.drawn, 14, 'the card is drawn again from the plan');
  eq(out.values, [14, 14, 14], 'each machine of the wave');
  ok(out.other.every(v => v === 7), 'the other wave is not changed');
  eq(out.dirty, false, 'nothing is left to save');
});

test('on the sample page, a machine moved to another wave is in that wave after the save', async () => {
  const r = await sample();
  const out = await inPage(r, `
    const id = entries.find(e => e.vmId.endsWith('/prd-lin-c')).vmId;
    moveTo('storefront-pilot', [id]);
    await save();
    return JSON.stringify({ wave: entries.find(e => e.vmId === id).wave,
      inCard: layout.get('storefront-pilot').vmIds.includes(id), dirty: dirty(),
      none: entries.filter(e => !e.wave || e.wave === 'unscheduled').map(e => e.vmId.split('/').pop()).join(', ') });`);
  eq(out.wave, 'storefront-pilot', 'the plan entry');
  ok(out.inCard, 'the card');
  eq(out.dirty, false, 'nothing is left to save');
  // NOT-IN-WAVE-QUEUED-1: the sample keeps prd-lin-d in no wave on purpose; the save puts no other machine there.
  eq(out.none, 'prd-lin-d', 'only the machine the sample keeps in no wave is there');
});

/* The sample's save, lifted with the functions it reads. */
function sampleSave() {
  globalThis.VmfHelp = atOnce({ approvalRequired: lift('help.js', 'approvalRequired') });
  globalThis.WAVE_DEFAULTS = require('./_at-once').waveRule.waveSettingDefaults();
  globalThis.WAVE_WIDE = ['capacityGate', 'requireApproval', 'throttle'];
  return ({ ...waveRuleGlobal(), ...liftAll('waves.html', ['demoWritePlan']) });
}

/* The sample's save is held to the cases the engine is held to: which machine
 * a change on the card writes, and which keeps its own value. */
const FIXTURE = JSON.parse(fs.readFileSync(path.join(REPO, 'tests', 'fixtures', 'wave-own-settings.json'), 'utf8'));
for (const c of FIXTURE.cases) {
  test(`the sample save, as the engine: ${c.name}`, () => {
    const fns = sampleSave();

    const list = c.entries.map(e => ({ vmId: `/s/rg/vm/${e.name}`, wave: FIXTURE.wave, path: 'A',
      policy: JSON.parse(JSON.stringify(e.policy)), ...(e.decisions ? { decisions: JSON.parse(JSON.stringify(e.decisions)) } : {}) }));
    globalThis.entries = list;
    globalThis.DEMO_PLAN = { entries: list };
    const field = c.change.field;
    const before = list.map(e => JSON.stringify(e.policy[field]));
    const r = fns.demoWritePlan([{ name: FIXTURE.wave, vmIds: list.map(e => e.vmId), [field]: c.change.to, changed: { [field]: c.card[field] }, reset: {} }]);
    const written = list.filter((e, i) => JSON.stringify(e.policy[field]) !== before[i]).map(e => nameOf(e.vmId));
    eq(written.sort(), [...c.writes].sort(), 'the machines written');
    ok(list.filter(e => written.includes(nameOf(e.vmId))).every(e => e.policy[field] === c.change.to), 'each with the value of the card');
    eq((r.KeptOwnSettings ?? []).map(k => k.Machine).sort(), [...c.kept].sort(), 'the machines that keep their own value');
  });
}

test('the sample save gives a reset machine the value of its wave and removes its decision, as the engine does', () => {
  const fns = sampleSave();

  const decided = [{ setting: 'onDDataFound', by: 'operator@example.com', utc: 'x' }, { setting: 'keepSnapshotDays', by: 'operator@example.com', utc: 'y' }];
  const list = [
    { vmId: '/s/a', wave: 'w', path: 'A', policy: { onDDataFound: 'proceed', keepSnapshotDays: 7 }, decisions: decided },
    { vmId: '/s/b', wave: 'w', path: 'A', policy: { onDDataFound: 'stop', keepSnapshotDays: 14 } },
    { vmId: '/s/c', wave: 'w', path: 'A', policy: { onDDataFound: 'stop' } },
  ];
  globalThis.entries = list;
  globalThis.DEMO_PLAN = { entries: list };
  const r = fns.demoWritePlan([{ name: 'w', vmIds: ['/s/a', '/s/b', '/s/c'], onDDataFound: 'stop', keepSnapshotDays: 7, changed: {},
    reset: { onDDataFound: ['/s/a'], keepSnapshotDays: ['/s/a', '/s/b'] } }]);
  eq(list[0].policy.onDDataFound, 'stop', 'a has the value of the wave');
  eq(list[0].decisions.map(d => d.setting), [], 'and the records of its decisions for both settings went');
  eq(list[1].policy.keepSnapshotDays, 7, 'b has the value of the wave');
  eq(list[2].policy, { onDDataFound: 'stop' }, 'c was not reset and is not written');
  eq(r.ResetToWave.map(x => `${x.Machine}:${x.Setting}`).sort(), ['a:keepSnapshotDays', 'a:onDDataFound', 'b:keepSnapshotDays'],
    'each machine reset - a, whose value was already the wave\'s, because the record of its decision went');
});

test('the sample save writes only the setting changed on the card, as the page sends every setting of the wave', () => {
  const fns = sampleSave();
  const list = [
    { vmId: '/s/a', wave: 'w', path: 'A', policy: { onDDataFound: 'stop', keepSnapshotDays: 7 } },
    { vmId: '/s/b', wave: 'w', path: 'A', policy: { onDDataFound: 'proceed', keepSnapshotDays: 7 } },
  ];
  globalThis.entries = list;
  globalThis.DEMO_PLAN = { entries: list };
  const r = fns.demoWritePlan([{ name: 'w', vmIds: ['/s/a', '/s/b'], ...WAVE_DEFAULTS, keepSnapshotDays: 14,
    changed: { keepSnapshotDays: 7 }, reset: {} }]);
  eq(list.map(e => e.policy.keepSnapshotDays), [14, 14], 'the setting changed on the card');
  eq(list[1].policy.onDDataFound, 'proceed', 'a setting not changed is not written');
  eq(r.KeptOwnSettings, [], 'and no machine is said to keep its own value of a setting nobody changed');
});

test('the sample save moves each machine to the wave it was sent in, and keeps the order of the waves', () => {
  const fns = sampleSave();

  const list = [
    { vmId: '/s/a', wave: 'w1', path: 'A', policy: { keepSnapshotDays: 7 } },
    { vmId: '/s/b', wave: 'w2', path: 'A', policy: { keepSnapshotDays: 30 } },
  ];
  globalThis.entries = list;
  globalThis.DEMO_PLAN = { entries: list, waveOrder: ['w1', 'w2'] };
  // b joins w1 and takes its card; w2 is empty and goes from the order.
  fns.demoWritePlan([{ name: 'w1', vmIds: ['/s/a', '/s/b'], keepSnapshotDays: 7, changed: {}, reset: {} }]);
  eq(list[1].wave, 'w1', 'b moved');
  eq(list[1].policy.keepSnapshotDays, 7, 'a machine that joins a wave takes its card');
  eq(DEMO_PLAN.waveOrder, ['w1'], 'the order of the waves that hold a machine');
});

// --------------------------------------------- a real run is not changed
test('on a real run, a save reads the plan again from the service and never runs the sample save', async () => {
  let reloaded = 0;
  Object.assign(globalThis, {
    DEMO_MODE: false, layout: new Map(), planVersion: 'v1', original: '',
    waveMigrating: () => false, changedOf: () => ({}), resetOf: () => ({}), snapshot: () => 's',
    runSeg: () => 'r1', runBody: (b) => b,
    apiPost: async () => ({ ApprovalsInvalidated: ['x'] }),
    reloadPlan: async () => { reloaded++; },
    demoWritePlan: () => { throw new Error('the sample save ran on a real run'); },
  });
  const r = await lift('waves.html', 'writeLayout')();
  eq(reloaded, 1, 'the plan is read again');
  eq(r, { ApprovalsInvalidated: ['x'] }, 'the answer of the service, as it came');
});

test('on a real run, the plan is read from the store with its version; the sample reads its own plan', async () => {
  let asked = 0;
  Object.assign(globalThis, {
    DEMO_MODE: false, planVersion: '', cfg: { apiUrl: 'https://api.example.com' }, getToken: async () => 't', runPrefix: () => 'runs/r1',
    VmfHelp: { storeBlob: async () => { asked++; return { text: '{"entries":[]}', version: 'v9' }; } },
    DEMO_PLAN: { entries: [{ vmId: 'sample' }] },
  });
  const readPlan = lift('waves.html', 'readPlan');
  const real = await readPlan();
  eq(asked, 1, 'the store is read');
  eq(planVersion, 'v9', 'with the version the service issued');
  eq(real, { entries: [] });
  globalThis.DEMO_MODE = true;
  const own = await readPlan();
  eq(asked, 1, 'the sample asks the store nothing');
  eq(own.entries[0].vmId, 'sample', 'the sample plan');
});

run('wave-own-picture');
